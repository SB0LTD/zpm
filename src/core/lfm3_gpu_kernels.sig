//! @zpm/lfm3-gpu-kernels — LFM3's compute kernels for the Adreno a7xx, in
//! ir3 assembly (see the adreno module), and how each is launched.
//!
//! Quantized matrices multiply exactly as zpm's CPU kernels
//! (quantized_linear) do: the same eight four-element lanes per weight
//! block, the same integer sums (dp4acc: signed activation bytes times
//! unsigned weight bytes), the same float epilogue per block and the lanes
//! added in the same order. Given the same Q8_K activations, the results
//! are the CPU's to the bit wherever the GPU rounds f32 like IEEE (the
//! bring-up self-test checks that on the hardware).
//!
//! Activations live as three arrays per row of tokens, where the CPU has
//! one Q8KBlock per 256 lanes: `aq` (the i8 values), `ad` (one f32 scale per
//! block) and `abs` (the sixteen i16 sums per block).
//!
//! Q8_0 (LFM3-Audio's encoder, depthformer and codec) has `aq` and `ad` only
//! (one scale per 32 lanes). Its integer sums are the CPU's; its float
//! epilogue is the CPU's fused multiply-add only where the GPU's mad.f32 is
//! fused (the bring-up self-test tells), and otherwise rounds twice.

const std = @import("std");
const adreno = @import("adreno");

const ir3 = adreno.ir3;
const ir3_asm = adreno.ir3_asm;

pub const QK_K = 256;
pub const Q4_K_BLOCK = 144;
pub const Q6_K_BLOCK = 210;
/// Rows per workgroup of the matrix kernels (8 fibers per row, 64 per wave).
pub const MATRIX_ROWS_PER_GROUP = 8;
pub const MAX_TOKENS = 8;

/// Register `n` (scalar index) in ir3 syntax: r(5) = "r1.y".
fn r(comptime n: comptime_int) []const u8 {
    return std.fmt.comptimePrint("r{d}.{c}", .{ n / 4, "xyzw"[n % 4] });
}

/// The half register holding the low (hi = false) or high half of r(n).
fn hr(comptime n: comptime_int, comptime hi: bool) []const u8 {
    const h: comptime_int = n * 2 + (if (hi) 1 else 0);
    return std.fmt.comptimePrint("hr{d}.{c}", .{ h / 4, "xyzw"[h % 4] });
}

fn line(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.comptimePrint(fmt ++ "\n", args);
}

/// Constants of the matrix kernels (vec4 c0..c3).
pub const MatrixConsts = struct {
    weights: u64,
    act_q: u64,
    act_d: u64,
    act_sums: u64,
    out: u64,
    row_bytes: u32,
    blocks: u32,
    rows: u32,

    pub fn dwords(m: MatrixConsts) [16]u32 {
        return .{
            @truncate(m.weights),  @truncate(m.weights >> 32),  @truncate(m.act_q),    @truncate(m.act_q >> 32),
            @truncate(m.act_d),    @truncate(m.act_d >> 32),    @truncate(m.act_sums), @truncate(m.act_sums >> 32),
            @truncate(m.out),      @truncate(m.out >> 32),      m.row_bytes,           m.blocks,
            m.blocks * QK_K, m.blocks * 4, m.blocks * 32, m.rows * 4,
        };
    }
};

// Register plan shared by the matrix kernels:
//   0..2   local id            4 lane (0..7)    5 row in group    6 row
//   7      lane * 4            8 row byte offset  10 row bytes (gpr)
//   11     block byte offset   12 block counter   13 block * 256
//   14     block * 4           15 block * 32
//   16..23 weight words        24..27 unpacked scale words
//   28..30 masks 0x0f/0x3f/0x03   31 scratch address
//   32     min byte shift      33 min word select  34 this lane's min
//   35     scratch             36..43 the 8 sub-block scales
//   44,45  d, dmin (f32)       46 scratch          47 zero
//   48..55 unpacked weight bytes per sub-block
//   64 + 16 t  per token t: A0..A7 activations (8), ad, bsums, I, M, S,
//              activation / scale / sums base offsets
const TOK = 64;
fn tk(comptime t: comptime_int, comptime k: comptime_int) comptime_int {
    return TOK + 16 * t + k;
}
const T_AD = 8;
const T_BS = 9;
const T_I = 10;
const T_M = 11;
const T_S = 12;
const T_A = 13;
const T_D = 14;
const T_SB = 15;

fn matrixPrologue(comptime tokens: comptime_int) []const u8 {
    comptime {
        var s: []const u8 =
            \\@localsize 64, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 4
            \\
        ;
        s = s ++ line("and.b {s}, r0.x, 7", .{r(4)});
        s = s ++ line("shr.b {s}, r0.x, 3", .{r(5)});
        s = s ++ line("shl.b {s}, r48.x, 3", .{r(6)});
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(5) });
        s = s ++ line("mov.u32u32 {s}, c2.z", .{r(10)});
        // row * row_bytes in 32 bits: lo*lo + (lo(row)*hi(rb) + lo(rb)*hi(row)) << 16
        s = s ++ line("mull.u {s}, {s}, {s}", .{ r(8), r(6), r(10) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(8), r(6), r(10), r(8) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(8), r(10), r(6), r(8) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(7), r(4) });
        s = s ++ line("mov.u32u32 {s}, 0x0f0f0f0f", .{r(28)});
        s = s ++ line("mov.u32u32 {s}, 0x3f3f3f3f", .{r(29)});
        s = s ++ line("mov.u32u32 {s}, 0x03030303", .{r(30)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(47)});
        for (0..tokens) |t| {
            s = s ++ line("mul.u24 {s}, c3.x, {d}", .{ r(tk(t, T_A)), t });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(tk(t, T_A)), r(tk(t, T_A)), r(7) });
            s = s ++ line("mul.u24 {s}, c3.y, {d}", .{ r(tk(t, T_D)), t });
            s = s ++ line("mul.u24 {s}, c3.z, {d}", .{ r(tk(t, T_SB)), t });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(tk(t, T_SB)), r(tk(t, T_SB)), r(7) });
            s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(tk(t, T_S))});
        }
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(11), r(8) });
        s = s ++ line("mov.u32u32 {s}, 0", .{r(12)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(13)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(14)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(15)});
        return s;
    }
}

/// Load each token's 8 activation words of this block, its scale and the
/// lane's two 16-lane sums (as one word).
fn loadActivations(comptime tokens: comptime_int) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (0..tokens) |t| {
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(46), r(tk(t, T_A)), r(13) });
            for (0..8) |j| s = s ++ line("ldg.a.u32 {s}, g[c0.z+{s}+{d}], 1", .{ r(tk(t, j)), r(46), 32 * j });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(35), r(tk(t, T_D)), r(14) });
            s = s ++ line("ldg.a.f32 {s}, g[c1.x+{s}+0], 1", .{ r(tk(t, T_AD)), r(35) });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(31), r(tk(t, T_SB)), r(15) });
            s = s ++ line("ldg.a.u32 {s}, g[c1.z+{s}+0], 1", .{ r(tk(t, T_BS)), r(31) });
        }
        return s;
    }
}

/// The lanes' sums added in order (s0 + s1 + ... + s7, as the CPU's
/// @reduce does), stored by lane 0 of each row.
fn matrixEpilogue(comptime tokens: comptime_int) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (0..tokens) |t| {
            s = s ++ line("mov.f32f32 {s}, {s}", .{ r(tk(t, T_I)), r(tk(t, T_S)) });
            for (1..8) |k| {
                s = s ++ line("shfl.down.u32 {s}, {s}, {d}", .{ r(tk(t, T_AD)), r(tk(t, T_S)), k });
                s = s ++ line("add.f {s}, {s}, {s}", .{ r(tk(t, T_I)), r(tk(t, T_I)), r(tk(t, T_AD)) });
            }
        }
        s = s ++ line("cmps.u.eq p0.x, {s}, 0", .{r(4)});
        s = s ++ "br !p0.x, #done\n";
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(35), r(6) });
        for (0..tokens) |t| {
            s = s ++ line("mul.u24 {s}, c3.w, {d}", .{ r(46), t });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(46), r(46), r(35) });
            s = s ++ line("stg.a.f32 g[c2.x+{s}+0], {s}, 1", .{ r(46), r(tk(t, T_I)) });
        }
        s = s ++ "done:\nend\n";
        return s;
    }
}

/// out[t][row] = Q4_K row . Q8_K activations of token t, for `tokens`
/// tokens (1 for decode, up to MAX_TOKENS per pass for prefill). One
/// workgroup per 8 rows.
pub fn q4kMatrixSource(comptime tokens: comptime_int) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        if (tokens < 1 or tokens > MAX_TOKENS) @compileError("tokens");
        var s: []const u8 = matrixPrologue(tokens);
        s = s ++ "loop:\n";
        s = s ++ line("ldg.a.u32 {s}, g[c0.x+{s}+0], 4", .{ r(16), r(11) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(31), r(11), r(7) });
        for (0..4) |p| s = s ++ line("ldg.a.u32 {s}, g[c0.x+{s}+{d}], 1", .{ r(20 + p), r(31), 16 + 32 * p });
        s = s ++ loadActivations(tokens);
        // The 6-bit scales and minimums (GGML's mask sequence).
        s = s ++ line("and.b {s}, {s}, {s}", .{ r(24), r(17), r(29) });
        s = s ++ line("shrm {s}, 6, {s}, {s}", .{ r(35), r(17), r(30) });
        s = s ++ line("shl.b {s}, {s}, 4", .{ r(35), r(35) });
        s = s ++ line("andg {s}, {s}, {s}, {s}", .{ r(25), r(28), r(19), r(35) });
        s = s ++ line("and.b {s}, {s}, {s}", .{ r(26), r(18), r(29) });
        s = s ++ line("shrm {s}, 6, {s}, {s}", .{ r(35), r(18), r(30) });
        s = s ++ line("shl.b {s}, {s}, 4", .{ r(35), r(35) });
        s = s ++ line("shrm {s}, 4, {s}, {s}", .{ r(46), r(19), r(28) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(27), r(46), r(35) });
        for (0..8) |j| {
            const word = if (j < 4) 24 else 25;
            const sh = 8 * (j % 4);
            if (sh == 24) {
                s = s ++ line("shr.b {s}, {s}, 24", .{ r(36 + j), r(word) });
            } else {
                s = s ++ line("shrm {s}, {d}, {s}, 255", .{ r(36 + j), sh, r(word) });
            }
        }
        s = s ++ line("and.b {s}, {s}, 3", .{ r(32), r(4) });
        s = s ++ line("shl.b {s}, {s}, 3", .{ r(32), r(32) });
        s = s ++ line("shr.b {s}, {s}, 2", .{ r(33), r(4) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(34), r(27), r(33), r(26) });
        s = s ++ line("shrm {s}, {s}, {s}, 255", .{ r(34), r(32), r(34) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(44), hr(16, false) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(45), hr(16, true) });
        // Weight nibbles: sub-block 2p is the low, 2p+1 the high nibbles of pair p.
        for (0..4) |p| {
            s = s ++ line("and.b {s}, {s}, {s}", .{ r(48 + 2 * p), r(20 + p), r(28) });
            s = s ++ line("shrm {s}, 4, {s}, {s}", .{ r(49 + 2 * p), r(20 + p), r(28) });
        }
        for (0..tokens) |t| {
            const I = r(tk(t, T_I));
            const M = r(tk(t, T_M));
            for (0..8) |j| {
                s = s ++ line("dp4acc.mixed.low {s}, {s}, {s}, {s}", .{ M, r(tk(t, j)), r(48 + j), r(47) });
                if (j == 0) {
                    s = s ++ line("mul.s24 {s}, {s}, {s}", .{ I, M, r(36) });
                } else {
                    s = s ++ line("mad.s24 {s}, {s}, {s}, {s}", .{ I, M, r(36 + j), I });
                }
            }
            // minimum: min[lane] * (bsums[2 lane] + bsums[2 lane + 1])
            const BS = r(tk(t, T_BS));
            s = s ++ line("shl.b {s}, {s}, 16", .{ M, BS });
            s = s ++ line("ashr.b {s}, {s}, 16", .{ M, M });
            s = s ++ line("ashr.b {s}, {s}, 16", .{ r(46), BS });
            s = s ++ line("add.s {s}, {s}, {s}", .{ M, M, r(46) });
            s = s ++ line("mul.s24 {s}, {s}, {s}", .{ M, M, r(34) });
            // sums += (d * ad) * float(I) - (dmin * ad) * float(M)
            const AD = r(tk(t, T_AD));
            s = s ++ line("cov.s32f32 {s}, {s}", .{ r(46), I });
            s = s ++ line("cov.s32f32 {s}, {s}", .{ M, M });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ I, r(44), AD });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ AD, r(45), AD });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ I, I, r(46) });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ AD, AD, M });
            s = s ++ line("add.f {s}, {s}, (neg){s}", .{ I, I, AD });
            s = s ++ line("add.f {s}, {s}, {s}", .{ r(tk(t, T_S)), r(tk(t, T_S)), I });
        }
        s = s ++ line("add.u {s}, {s}, 144", .{ r(11), r(11) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(13), r(13) });
        s = s ++ line("add.u {s}, {s}, 4", .{ r(14), r(14) });
        s = s ++ line("add.u {s}, {s}, 32", .{ r(15), r(15) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(12), r(12) });
        s = s ++ "cmps.u.lt p0.x, " ++ r(12) ++ ", c2.w\n";
        s = s ++ "br p0.x, #loop\n";
        s = s ++ matrixEpilogue(tokens);
        return s;
    }
}

/// out[t][row] = Q6_K row . Q8_K activations of token t. Q6_K blocks are
/// 210 bytes, so every other one sits two bytes off a word boundary: words
/// are loaded as pairs of u16 into the two halves of a full register (in
/// the merged register file hr(2n) and hr(2n+1) are r(n)'s halves).
pub fn q6kMatrixSource(comptime tokens: comptime_int) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        if (tokens < 1 or tokens > MAX_TOKENS) @compileError("tokens");
        var s: []const u8 = matrixPrologue(tokens);
        s = s ++ line("mov.u32u32 {s}, 0x30303030", .{r(29)});
        s = s ++ line("mov.f32f32 {s}, (32.0)", .{r(30)});
        // scale byte shifts: (h, q) uses byte 2(q%2) + hi of its word, hi = lane >= 4
        s = s ++ line("shr.b {s}, {s}, 2", .{ r(33), r(4) });
        s = s ++ line("shl.b {s}, {s}, 3", .{ r(33), r(33) });
        s = s ++ line("sub.u {s}, 24, {s}", .{ r(32), r(33) }); // shift for even quarters
        s = s ++ line("sub.u {s}, 8, {s}", .{ r(33), r(33) }); // odd quarters
        // offset scales 2 lane, 2 lane + 1: word lane / 2, shifts 24 - 16 (lane & 1), and 8 less
        s = s ++ line("and.b {s}, {s}, 1", .{ r(56), r(4) });
        s = s ++ line("shl.b {s}, {s}, 4", .{ r(56), r(56) });
        s = s ++ line("sub.u {s}, 24, {s}", .{ r(57), r(56) });
        s = s ++ line("sub.u {s}, 16, {s}", .{ r(58), r(56) });
        s = s ++ line("shr.b {s}, {s}, 1", .{ r(59), r(4) });
        s = s ++ line("and.b {s}, {s}, 1", .{ r(59), r(59) });
        s = s ++ line("shr.b {s}, {s}, 2", .{ r(60), r(4) });
        s = s ++ line("and.b {s}, {s}, 1", .{ r(60), r(60) });
        s = s ++ "loop:\n";
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(31), r(11), r(7) });
        for (0..2) |h| {
            s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+{d}], 2", .{ hr(16 + 3 * h, false), r(31), h * 64 });
            s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+{d}], 2", .{ hr(17 + 3 * h, false), r(31), h * 64 + 32 });
            s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+{d}], 2", .{ hr(18 + 3 * h, false), r(31), 128 + h * 32 });
        }
        s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+192], 4", .{ hr(22, false), r(11) });
        s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+200], 4", .{ hr(24, false), r(11) });
        s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+208], 1", .{ hr(26, false), r(11) });
        s = s ++ loadActivations(tokens);
        // the eight quarter scales of this lane
        for (0..2) |h| for (0..4) |q| {
            const word = 22 + h * 2 + q / 2;
            s = s ++ line("shl.b {s}, {s}, {s}", .{ r(36 + h * 4 + q), r(word), r(if (q % 2 == 0) 32 else 33) });
            s = s ++ line("ashr.b {s}, {s}, 24", .{ r(36 + h * 4 + q), r(36 + h * 4 + q) });
        };
        // the two offset scales of this lane: word lane / 2
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(61), r(23), r(59), r(22) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(62), r(25), r(59), r(24) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(61), r(62), r(60), r(61) });
        s = s ++ line("shl.b {s}, {s}, {s}", .{ r(62), r(61), r(57) });
        s = s ++ line("ashr.b {s}, {s}, 24", .{ r(62), r(62) });
        s = s ++ line("shl.b {s}, {s}, {s}", .{ r(63), r(61), r(58) });
        s = s ++ line("ashr.b {s}, {s}, 24", .{ r(63), r(63) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(44), hr(26, false) });
        // the 6-bit values of the four quarters of each half
        for (0..2) |h| {
            const L = r(16 + 3 * h);
            const N = r(17 + 3 * h);
            const H = r(18 + 3 * h);
            const q = 48 + 4 * h;
            s = s ++ line("shlm {s}, 4, {s}, {s}", .{ r(35), H, r(29) });
            s = s ++ line("andg {s}, {s}, {s}, {s}", .{ r(q), r(28), L, r(35) });
            s = s ++ line("shlm {s}, 2, {s}, {s}", .{ r(35), H, r(29) });
            s = s ++ line("andg {s}, {s}, {s}, {s}", .{ r(q + 1), r(28), N, r(35) });
            s = s ++ line("shrm {s}, 4, {s}, {s}", .{ r(35), L, r(28) });
            s = s ++ line("andg {s}, {s}, {s}, {s}", .{ r(q + 2), r(29), H, r(35) });
            s = s ++ line("shrm {s}, 2, {s}, {s}", .{ r(35), H, r(29) });
            s = s ++ line("shrm {s}, 4, {s}, {s}", .{ r(46), N, r(28) });
            s = s ++ line("or.b {s}, {s}, {s}", .{ r(q + 3), r(46), r(35) });
        }
        for (0..tokens) |t| {
            const I = r(tk(t, T_I));
            const M = r(tk(t, T_M));
            for (0..8) |j| {
                s = s ++ line("dp4acc.mixed.low {s}, {s}, {s}, {s}", .{ M, r(tk(t, j)), r(48 + j), r(47) });
                if (j == 0) {
                    s = s ++ line("mul.s24 {s}, {s}, {s}", .{ I, M, r(36) });
                } else {
                    s = s ++ line("mad.s24 {s}, {s}, {s}, {s}", .{ I, M, r(36 + j), I });
                }
            }
            // offset: bsums[2 lane] * scale[2 lane] + bsums[2 lane + 1] * scale[2 lane + 1]
            const BS = r(tk(t, T_BS));
            s = s ++ line("shl.b {s}, {s}, 16", .{ M, BS });
            s = s ++ line("ashr.b {s}, {s}, 16", .{ M, M });
            s = s ++ line("ashr.b {s}, {s}, 16", .{ r(46), BS });
            s = s ++ line("mul.s24 {s}, {s}, {s}", .{ M, M, r(62) });
            s = s ++ line("mad.s24 {s}, {s}, {s}, {s}", .{ M, r(46), r(63), M });
            // sums += (d * ad) * (float(I) - 32 * float(offset))
            const AD = r(tk(t, T_AD));
            s = s ++ line("cov.s32f32 {s}, {s}", .{ I, I });
            s = s ++ line("cov.s32f32 {s}, {s}", .{ M, M });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ M, M, r(30) });
            s = s ++ line("add.f {s}, {s}, (neg){s}", .{ I, I, M });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ AD, r(44), AD });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ I, AD, I });
            s = s ++ line("add.f {s}, {s}, {s}", .{ r(tk(t, T_S)), r(tk(t, T_S)), I });
        }
        s = s ++ line("add.u {s}, {s}, 210", .{ r(11), r(11) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(13), r(13) });
        s = s ++ line("add.u {s}, {s}, 4", .{ r(14), r(14) });
        s = s ++ line("add.u {s}, {s}, 32", .{ r(15), r(15) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(12), r(12) });
        s = s ++ "cmps.u.lt p0.x, " ++ r(12) ++ ", c2.w\n";
        s = s ++ "br p0.x, #loop\n";
        s = s ++ matrixEpilogue(tokens);
        return s;
    }
}

/// dst = a / b for normal f32 bit patterns in registers, correctly rounded
/// (IEEE division, as the CPU's `/`): the 24-bit mantissas long-divided in
/// 25 steps, rounded to nearest even. Wave-uniform; t is 8 scratch regs
/// (t[7] must hold 0x800000 on entry and keeps it).
fn fdivAsm(comptime dst: comptime_int, comptime a: comptime_int, comptime b: comptime_int, comptime t: [8]comptime_int, comptime label: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "";
        s = s ++ line("xor.b {s}, {s}, {s}", .{ r(t[0]), r(a), r(b) });
        s = s ++ line("shr.b {s}, {s}, 31", .{ r(t[0]), r(t[0]) });
        s = s ++ line("shl.b {s}, {s}, 31", .{ r(t[0]), r(t[0]) }); // sign
        s = s ++ line("shrm {s}, 23, {s}, 255", .{ r(t[1]), r(a) });
        s = s ++ line("shrm {s}, 23, {s}, 255", .{ r(t[2]), r(b) });
        s = s ++ line("sub.u {s}, {s}, {s}", .{ r(t[1]), r(t[1]), r(t[2]) });
        s = s ++ line("add.u {s}, {s}, 127", .{ r(t[1]), r(t[1]) }); // exponent
        s = s ++ line("shl.b {s}, {s}, 9", .{ r(t[2]), r(a) });
        s = s ++ line("shr.b {s}, {s}, 9", .{ r(t[2]), r(t[2]) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(t[2]), r(t[2]), r(t[7]) }); // dividend mantissa
        s = s ++ line("shl.b {s}, {s}, 9", .{ r(t[3]), r(b) });
        s = s ++ line("shr.b {s}, {s}, 9", .{ r(t[3]), r(t[3]) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(t[3]), r(t[3]), r(t[7]) }); // divisor mantissa
        s = s ++ line("cmps.u.lt {s}, {s}, {s}", .{ r(t[4]), r(t[2]), r(t[3]) });
        s = s ++ line("shl.b {s}, {s}, {s}", .{ r(t[2]), r(t[2]), r(t[4]) });
        s = s ++ line("sub.u {s}, {s}, {s}", .{ r(t[1]), r(t[1]), r(t[4]) });
        s = s ++ line("mov.u32u32 {s}, 0", .{r(dst)});
        s = s ++ line("mov.u32u32 {s}, 25", .{r(t[6])});
        s = s ++ label ++ ":\n";
        s = s ++ line("shl.b {s}, {s}, 1", .{ r(dst), r(dst) });
        s = s ++ line("cmps.u.ge {s}, {s}, {s}", .{ r(t[4]), r(t[2]), r(t[3]) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(dst), r(dst), r(t[4]) });
        s = s ++ line("mul.u24 {s}, {s}, {s}", .{ r(t[5]), r(t[4]), r(t[3]) });
        s = s ++ line("sub.u {s}, {s}, {s}", .{ r(t[2]), r(t[2]), r(t[5]) });
        s = s ++ line("shl.b {s}, {s}, 1", .{ r(t[2]), r(t[2]) });
        s = s ++ line("sub.u {s}, {s}, 1", .{ r(t[6]), r(t[6]) });
        s = s ++ line("cmps.u.ne p0.x, {s}, 0", .{r(t[6])});
        s = s ++ "br p0.x, #" ++ label ++ "\n";
        // 25 bits: guard bit last; the remainder is the sticky bit
        s = s ++ line("and.b {s}, {s}, 1", .{ r(t[4]), r(dst) });
        s = s ++ line("shr.b {s}, {s}, 1", .{ r(dst), r(dst) });
        s = s ++ line("cmps.u.ne {s}, {s}, 0", .{ r(t[5]), r(t[2]) });
        s = s ++ line("and.b {s}, {s}, 1", .{ r(t[6]), r(dst) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(t[5]), r(t[5]), r(t[6]) });
        s = s ++ line("and.b {s}, {s}, {s}", .{ r(t[4]), r(t[4]), r(t[5]) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(dst), r(dst), r(t[4]) });
        // a carry out of the mantissa: one more exponent step
        s = s ++ line("shr.b {s}, {s}, 24", .{ r(t[5]), r(dst) });
        s = s ++ line("shr.b {s}, {s}, {s}", .{ r(dst), r(dst), r(t[5]) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(t[1]), r(t[1]), r(t[5]) });
        s = s ++ line("shl.b {s}, {s}, 9", .{ r(dst), r(dst) });
        s = s ++ line("shr.b {s}, {s}, 9", .{ r(dst), r(dst) });
        s = s ++ line("shlg {s}, 23, {s}, {s}", .{ r(dst), r(t[1]), r(dst) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(dst), r(dst), r(t[0]) });
        return s;
    }
}

/// Constants of the quantization kernels (vec4 c0..c3).
pub const QuantConsts = struct {
    x: u64,
    norm_weight: u64 = 0,
    normalized: u64 = 0,
    act_q: u64,
    act_d: u64,
    act_sums: u64,
    k: u32,
    epsilon: f32 = 0,

    pub fn dwords(q: QuantConsts) [16]u32 {
        const inv_k: f32 = 1.0 / @as(f32, @floatFromInt(q.k));
        return .{
            @truncate(q.x),     @truncate(q.x >> 32),     @truncate(q.norm_weight), @truncate(q.norm_weight >> 32),
            @truncate(q.normalized), @truncate(q.normalized >> 32), @truncate(q.act_q), @truncate(q.act_q >> 32),
            @truncate(q.act_d), @truncate(q.act_d >> 32), @truncate(q.act_sums), @truncate(q.act_sums >> 32),
            q.k, @bitCast(q.epsilon), @bitCast(inv_k), q.k / QK_K,
        };
    }
};

/// Rows of f32 into Q8_K activations, as quantized_linear.quantizeQ8K does
/// (the first element of largest magnitude sets the scale; -127/max and its
/// reciprocal divided exactly; round to nearest even). One wave per 256-lane
/// block. With `norm`, each workgroup is one row of `waves` blocks: RMSNorm
/// first (f32 sums of squares; the CPU sums in f64, so the norm is a float
/// path), the normalized row written out, then quantized. Without, the grid
/// is (blocks, tokens) of single waves.
pub fn quantSource(comptime norm: bool, comptime waves: comptime_int) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var s: []const u8 = rowSetup(norm, waves);
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 4", .{ r(12), r(8) }); // x0..x3 in r3
        if (norm) {
            s = s ++ rmsNorm(waves);
            s = s ++ line("stg.a.f32 g[c1.x+{s}+0], {s}, 4", .{ r(8), r(12) });
        }
        s = s ++ quantTail();
        s = s ++ "done:\nend\n";
        return s;
    }
}

/// hidden[t] += rmsnorm(block[t]) * weight (`postnorm`, LFM3's sandwich
/// norms) or hidden[t] += block[t], as the CPU's ResidualTask. Constants as
/// QuantConsts: x = the block, norm_weight, normalized = hidden. Grid (1, T).
pub fn residualSource(comptime postnorm: bool, comptime waves: comptime_int) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var s: []const u8 = rowSetup(true, waves);
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 4", .{ r(12), r(8) });
        if (postnorm) s = s ++ rmsNorm(waves);
        s = s ++ line("ldg.a.f32 {s}, g[c1.x+{s}+0], 4", .{ r(20), r(8) });
        for (0..4) |i| s = s ++ line("add.f {s}, {s}, {s}", .{ r(20 + i), r(20 + i), r(12 + i) });
        s = s ++ line("stg.a.f32 g[c1.x+{s}+0], {s}, 4", .{ r(8), r(20) });
        s = s ++ "end\n";
        return s;
    }
}

/// silu(gate) * up, quantized for ffn_down, as the CPU's SwiGluQuantizeTask:
/// (g / (1 + exp(-g))) * u. Constants as QuantConsts with x = gate and
/// norm_weight = up. Grid (blocks, T). (exp and the division go through the
/// SFU: a float path.)
pub fn swigluSource() []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var s: []const u8 = rowSetup(false, 1);
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 4", .{ r(12), r(8) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.z+{s}+0], 4", .{ r(20), r(8) });
        s = s ++ line("mov.f32f32 {s}, (-1.44269504)", .{r(24)}); // -log2(e)
        for (0..4) |i| {
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(25), r(12 + i), r(24) });
            s = s ++ line("exp2 {s}, {s}", .{ r(25), r(25) });
            s = s ++ line("add.f {s}, {s}, (1.0)", .{ r(25), r(25) });
            s = s ++ line("rcp {s}, {s}", .{ r(25), r(25) });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(12 + i), r(12 + i), r(25) });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(12 + i), r(12 + i), r(20 + i) });
        }
        s = s ++ quantTail();
        s = s ++ "done:\nend\n";
        return s;
    }
}

/// The row kernels' header and per-fiber addressing: r4 wave, r5 lane,
/// r6 block, r7 element index (token * K + block * 256 + lane * 4), r8 its
/// f32 byte offset, r9 lane * 4; r39 = 0x800000, r50 = 0.
fn rowSetup(comptime one_row_per_group: bool, comptime waves: comptime_int) []const u8 {
    comptime {
        var s: []const u8 = std.fmt.comptimePrint(
            \\@localsize {d}, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 4
            \\@shared 64
            \\
        , .{64 * waves});
        s = s ++ line("shr.b {s}, r0.x, 6", .{r(4)});
        s = s ++ line("and.b {s}, r0.x, 63", .{r(5)});
        s = s ++ (if (one_row_per_group) line("mov.u32u32 {s}, {s}", .{ r(6), r(4) }) else line("mov.u32u32 {s}, r48.x", .{r(6)}));
        // (the workgroup's y through a register first: a cat2 instruction
        // reads at most one source from the const/shared file. With r48.y
        // and c3.x together the GPU hands c3.x to both: k * k, 16 MiB past
        // `hidden` for k = 2048, the adreno1 boot's fault.)
        s = s ++ line("mov.u32u32 {s}, r48.y", .{r(7)});
        s = s ++ line("mul.u24 {s}, {s}, c3.x", .{ r(7), r(7) });
        s = s ++ line("shl.b {s}, {s}, 8", .{ r(9), r(6) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(7), r(7), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(9), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(7), r(7), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(8), r(7) });
        s = s ++ line("mov.u32u32 {s}, 0x800000", .{r(39)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(50)});
        return s;
    }
}

/// RMSNorm of the row in r12..r15 (one wave per block, `waves` of them),
/// in place, times the weights at c0.zw.
fn rmsNorm(comptime waves: comptime_int) []const u8 {
    comptime {
        var s: []const u8 = "";
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(16), r(12), r(12) });
        for (1..4) |i| s = s ++ line("mad.f32 {s}, {s}, {s}, {s}", .{ r(16), r(12 + i), r(12 + i), r(16) });
        for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(17), r(16), m });
            s = s ++ line("add.f {s}, {s}, {s}", .{ r(16), r(16), r(17) });
        }
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(18), r(4) });
        s = s ++ line("cmps.u.eq p0.x, {s}, 0", .{r(5)});
        s = s ++ "br !p0.x, #partial\n";
        s = s ++ line("stl.f32 l[{s}], {s}, 1", .{ r(18), r(16) });
        s = s ++ "partial:\nbar\nfence.l.r.w\n";
        s = s ++ line("mov.u32u32 {s}, 0", .{r(18)});
        s = s ++ line("ldl.f32 {s}, l[{s}], 1", .{ r(16), r(18) });
        for (1..waves) |wv| s = s ++ line("ldl.f32 {s}, l[{s}+{d}], 1", .{ r(17), r(18), 4 * wv }) ++ line("add.f {s}, {s}, {s}", .{ r(16), r(16), r(17) });
        // inverse = 1 / sqrt(mean + eps)
        s = s ++ line("mul.f {s}, {s}, c3.z", .{ r(16), r(16) });
        s = s ++ line("add.f {s}, {s}, c3.y", .{ r(16), r(16) });
        s = s ++ line("rsq {s}, {s}", .{ r(16), r(16) });
        // the weights of these four elements: byte offset block * 1024 + lane * 16
        s = s ++ line("shl.b {s}, {s}, 10", .{ r(24), r(6) });
        s = s ++ line("shl.b {s}, {s}, 4", .{ r(25), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(24), r(24), r(25) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.z+{s}+0], 4", .{ r(20), r(24) });
        for (0..4) |i| {
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(12 + i), r(12 + i), r(16) });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(12 + i), r(12 + i), r(20 + i) });
        }
        return s;
    }
}

/// Q8_K quantization of the 256-lane block whose four elements this fiber
/// holds in r12..r15 (rowSetup's registers), stores included.
fn quantTail() []const u8 {
    comptime {
        var s: []const u8 = "";
        // |x| (as bits: they order like unsigned integers) and the wave max
        for (0..4) |i| s = s ++ line("absneg.f {s}, (abs){s}", .{ r(28 + i), r(12 + i) });
        s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(28), r(29) });
        s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(32), r(30) });
        s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(32), r(31) });
        for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(33), r(32), m });
            s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(32), r(33) });
        }
        // the first element with that magnitude: key = index << 1 | sign, wave min
        s = s ++ line("mov.u32u32 {s}, 0xffffffff", .{r(34)});
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            s = s ++ line("shl.b {s}, {s}, 2", .{ r(35), r(5) });
            s = s ++ line("add.u {s}, {s}, {d}", .{ r(35), r(35), i });
            s = s ++ line("shl.b {s}, {s}, 1", .{ r(35), r(35) });
            s = s ++ line("shr.b {s}, {s}, 31", .{ r(36), r(12 + i) });
            s = s ++ line("or.b {s}, {s}, {s}", .{ r(35), r(35), r(36) });
            s = s ++ line("cmps.u.eq {s}, {s}, {s}", .{ r(36), r(28 + i), r(32) });
            s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(34), r(35), r(36), r(34) });
        }
        for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(33), r(34), m });
            s = s ++ line("min.u {s}, {s}, {s}", .{ r(34), r(34), r(33) });
        }
        // maximum = sign | magnitude; inverse = -127 / maximum; d = 1 / inverse
        s = s ++ line("shl.b {s}, {s}, 31", .{ r(34), r(34) });
        s = s ++ line("or.b {s}, {s}, {s}", .{ r(37), r(32), r(34) });
        s = s ++ line("mov.u32u32 {s}, 0xc2fe0000", .{r(38)}); // -127.0
        s = s ++ fdivAsm(40, 38, 37, .{ 41, 42, 43, 44, 45, 46, 47, 39 }, "div1");
        s = s ++ line("mov.u32u32 {s}, 0x3f800000", .{r(38)}); // 1.0
        s = s ++ fdivAsm(36, 38, 40, .{ 41, 42, 43, 44, 45, 46, 47, 39 }, "div2");
        // q = min(127, nearest(inverse * x)); zero blocks stay zero
        s = s ++ line("cmps.u.ne {s}, {s}, 0", .{ r(33), r(32) });
        for (0..4) |k| {
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(20 + k), r(40), r(12 + k) });
            s = s ++ line("rndne.f {s}, {s}", .{ r(20 + k), r(20 + k) });
            s = s ++ line("cov.f32s32 {s}, {s}", .{ r(20 + k), r(20 + k) });
            s = s ++ line("min.s {s}, {s}, 127", .{ r(20 + k), r(20 + k) });
            s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(20 + k), r(20 + k), r(33), r(50) });
        }
        // pack four bytes
        s = s ++ line("and.b {s}, {s}, 255", .{ r(24), r(20) });
        s = s ++ line("and.b {s}, {s}, 255", .{ r(25), r(21) });
        s = s ++ line("shlg {s}, 8, {s}, {s}", .{ r(24), r(25), r(24) });
        s = s ++ line("and.b {s}, {s}, 255", .{ r(25), r(22) });
        s = s ++ line("shlg {s}, 16, {s}, {s}", .{ r(24), r(25), r(24) });
        s = s ++ line("shlg {s}, 24, {s}, {s}", .{ r(24), r(23), r(24) });
        s = s ++ line("stg.a.u32 g[c1.z+{s}+0], {s}, 1", .{ r(7), r(24) });
        // sums of 16: four fibers' four values
        s = s ++ line("add.s {s}, {s}, {s}", .{ r(26), r(20), r(21) });
        s = s ++ line("add.s {s}, {s}, {s}", .{ r(26), r(26), r(22) });
        s = s ++ line("add.s {s}, {s}, {s}", .{ r(26), r(26), r(23) });
        s = s ++ line("shfl.xor.u32 {s}, {s}, 1", .{ r(27), r(26) });
        s = s ++ line("add.s {s}, {s}, {s}", .{ r(26), r(26), r(27) });
        s = s ++ line("shfl.xor.u32 {s}, {s}, 2", .{ r(27), r(26) });
        s = s ++ line("add.s {s}, {s}, {s}", .{ r(26), r(26), r(27) });
        // block number in the row of tokens: t * blocks + block (r48.y
        // through a register: one const/shared source per cat2 instruction)
        s = s ++ line("mov.u32u32 {s}, r48.y", .{r(28)});
        s = s ++ line("mul.u24 {s}, {s}, c3.w", .{ r(28), r(28) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(28), r(28), r(6) });
        s = s ++ line("and.b {s}, {s}, 3", .{ r(29), r(5) });
        s = s ++ line("cmps.u.eq p0.x, {s}, 0", .{r(29)});
        s = s ++ "br !p0.x, #nosum\n";
        s = s ++ line("shl.b {s}, {s}, 5", .{ r(30), r(28) });
        s = s ++ line("shr.b {s}, {s}, 1", .{ r(31), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(30), r(30), r(31) });
        s = s ++ line("cov.s32s16 {s}, {s}", .{ hr(27, false), r(26) });
        s = s ++ line("stg.a.s16 g[c2.z+{s}+0], {s}, 1", .{ r(30), hr(27, false) });
        s = s ++ "nosum:\n";
        s = s ++ line("cmps.u.eq p0.x, {s}, 0", .{r(5)});
        s = s ++ "br !p0.x, #done\n";
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(30), r(28) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(36), r(36), r(33), r(50) });
        s = s ++ line("stg.a.u32 g[c2.x+{s}+0], {s}, 1", .{ r(30), r(36) });
        return s;
    }
}

// ── Q8_0 (LFM3-Audio's encoder, depthformer and codec) ───────────────────────

pub const QK8_0 = 32;
pub const Q8_0_BLOCK = 34;

/// Constants of the Q8_0 matrix kernel (vec4 c0..c3).
pub const Q80MatrixConsts = struct {
    weights: u64,
    act_q: u64,
    act_d: u64,
    out: u64,
    row_bytes: u32,
    blocks: u32,
    rows: u32,

    pub fn dwords(m: Q80MatrixConsts) [16]u32 {
        return .{
            @truncate(m.weights), @truncate(m.weights >> 32), @truncate(m.act_q), @truncate(m.act_q >> 32),
            @truncate(m.act_d),   @truncate(m.act_d >> 32),   @truncate(m.out),   @truncate(m.out >> 32),
            m.row_bytes,          m.blocks,                   m.blocks * QK8_0,   m.blocks * 4,
            m.rows * 4,           m.rows,                     0,                  0,
        };
    }
};

// Register plan of the Q8_0 matrix kernel:
//   4 lane (0..7)   5 row in group   6 row   7 lane * 4   8 row byte offset
//   9 rows - 1, then the row loads use   10 row bytes   11 block byte offset
//   12 block counter   13 block * 32   14 block * 4   15 row < rows
//   16 0x80808080   17 0x01010101   18 zero   20 weight word (hr40, hr41)
//   21 scale (hr42)   22 d (f32)   23 address   24 address   25 shuffled
//   32 + 8 t  per token t: A, D, S, I, X, A base, D base
const Q80_TOK = 32;
fn q8reg(comptime t: comptime_int, comptime k: comptime_int) []const u8 {
    return r(Q80_TOK + 8 * t + k);
}

/// out[t][row] = Q8_0 row . Q8_0 activations of token t, as quantized_linear's
/// dotQ80Q80 does: lane l of a row holds bytes 4l..4l+3 of every 32-byte
/// block, its integer sum times d_w * d_x added in with mad.f32 (the CPU's
/// fused multiply-add: bit-exact where the GPU's mad is fused, two roundings
/// otherwise), then the lanes added pairwise (4, 2, 1 apart) as GGML's AVX
/// reduction does. Weights are signed: w ^ 0x80 is the unsigned w + 128 that
/// dp4acc takes, and 128 * the lane's activation sum comes back off. Blocks
/// are 34 bytes, so the four weight bytes are two u16 loads. Rows in eights
/// per workgroup; a last group past `rows` loads the last row and stores
/// nothing.
pub fn q80MatrixSource(comptime tokens: comptime_int) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        if (tokens < 1 or tokens > MAX_TOKENS) @compileError("tokens");
        var s: []const u8 =
            \\@localsize 64, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 4
            \\
        ;
        s = s ++ line("and.b {s}, r0.x, 7", .{r(4)});
        s = s ++ line("shr.b {s}, r0.x, 3", .{r(5)});
        s = s ++ line("shl.b {s}, r48.x, 3", .{r(6)});
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(5) });
        s = s ++ line("mov.u32u32 {s}, c3.y", .{r(9)});
        s = s ++ line("cmps.u.lt {s}, {s}, {s}", .{ r(15), r(6), r(9) });
        s = s ++ line("sub.u {s}, {s}, 1", .{ r(9), r(9) });
        s = s ++ line("min.u {s}, {s}, {s}", .{ r(9), r(6), r(9) });
        s = s ++ line("mov.u32u32 {s}, c2.x", .{r(10)});
        // row * row_bytes in 32 bits (as matrixPrologue)
        s = s ++ line("mull.u {s}, {s}, {s}", .{ r(8), r(9), r(10) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(8), r(9), r(10), r(8) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(8), r(10), r(9), r(8) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(7), r(4) });
        s = s ++ line("mov.u32u32 {s}, 0x80808080", .{r(16)});
        s = s ++ line("mov.u32u32 {s}, 0x01010101", .{r(17)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(18)});
        for (0..tokens) |t| {
            s = s ++ line("mul.u24 {s}, c2.z, {d}", .{ q8reg(t, 5), t });
            s = s ++ line("add.u {s}, {s}, {s}", .{ q8reg(t, 5), q8reg(t, 5), r(7) });
            s = s ++ line("mul.u24 {s}, c2.w, {d}", .{ q8reg(t, 6), t });
            s = s ++ line("mov.f32f32 {s}, (0.0)", .{q8reg(t, 2)});
        }
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(11), r(8) });
        s = s ++ line("mov.u32u32 {s}, 0", .{r(12)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(13)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(14)});
        s = s ++ "loop:\n";
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(23), r(11), r(7) });
        s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+2], 2", .{ hr(20, false), r(23) });
        s = s ++ line("ldg.a.u16 {s}, g[c0.x+{s}+0], 1", .{ hr(21, false), r(11) });
        for (0..tokens) |t| {
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(23), q8reg(t, 5), r(13) });
            s = s ++ line("ldg.a.u32 {s}, g[c0.z+{s}+0], 1", .{ q8reg(t, 0), r(23) });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(24), q8reg(t, 6), r(14) });
            s = s ++ line("ldg.a.f32 {s}, g[c1.x+{s}+0], 1", .{ q8reg(t, 1), r(24) });
        }
        s = s ++ line("xor.b {s}, {s}, {s}", .{ r(20), r(20), r(16) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(22), hr(21, false) });
        for (0..tokens) |t| {
            s = s ++ line("dp4acc.mixed.low {s}, {s}, {s}, {s}", .{ q8reg(t, 3), q8reg(t, 0), r(20), r(18) });
            s = s ++ line("dp4acc.mixed.low {s}, {s}, {s}, {s}", .{ q8reg(t, 4), q8reg(t, 0), r(17), r(18) });
            s = s ++ line("shl.b {s}, {s}, 7", .{ q8reg(t, 4), q8reg(t, 4) });
            s = s ++ line("sub.u {s}, {s}, {s}", .{ q8reg(t, 3), q8reg(t, 3), q8reg(t, 4) });
            s = s ++ line("cov.s32f32 {s}, {s}", .{ q8reg(t, 3), q8reg(t, 3) });
            s = s ++ line("mul.f {s}, {s}, {s}", .{ q8reg(t, 1), r(22), q8reg(t, 1) });
            s = s ++ line("mad.f32 {s}, {s}, {s}, {s}", .{ q8reg(t, 2), q8reg(t, 1), q8reg(t, 3), q8reg(t, 2) });
        }
        s = s ++ line("add.u {s}, {s}, {d}", .{ r(11), r(11), Q8_0_BLOCK });
        s = s ++ line("add.u {s}, {s}, {d}", .{ r(13), r(13), QK8_0 });
        s = s ++ line("add.u {s}, {s}, 4", .{ r(14), r(14) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(12), r(12) });
        s = s ++ "cmps.u.lt p0.x, " ++ r(12) ++ ", c2.y\n";
        s = s ++ "br p0.x, #loop\n";
        // (l + l^4), then 2 apart, then 1: GGML's hi + lo, even + odd
        for (0..tokens) |t| {
            for ([_]u32{ 4, 2, 1 }) |m| {
                s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(25), q8reg(t, 2), m });
                s = s ++ line("add.f {s}, {s}, {s}", .{ q8reg(t, 2), q8reg(t, 2), r(25) });
            }
        }
        s = s ++ line("cmps.u.eq {s}, {s}, 0", .{ r(24), r(4) });
        s = s ++ line("and.b {s}, {s}, {s}", .{ r(24), r(24), r(15) });
        s = s ++ line("cmps.u.ne p0.x, {s}, 0", .{r(24)});
        s = s ++ "br !p0.x, #done\n";
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(23), r(6) });
        for (0..tokens) |t| {
            s = s ++ line("mul.u24 {s}, c3.x, {d}", .{ r(24), t });
            s = s ++ line("add.u {s}, {s}, {s}", .{ r(24), r(24), r(23) });
            s = s ++ line("stg.a.f32 g[c1.z+{s}+0], {s}, 1", .{ r(24), q8reg(t, 2) });
        }
        s = s ++ "done:\nend\n";
        return s;
    }
}

/// Constants of the Q8_0 activation quantization (vec4 c0..c1).
pub const Q80QuantConsts = struct {
    x: u64,
    act_q: u64,
    act_d: u64,
    k: u32,

    pub fn dwords(q: Q80QuantConsts) [8]u32 {
        return .{
            @truncate(q.x),     @truncate(q.x >> 32),     @truncate(q.act_q), @truncate(q.act_q >> 32),
            @truncate(q.act_d), @truncate(q.act_d >> 32), q.k,                q.k / QK8_0,
        };
    }
};

/// Rows of f32 into Q8_0 activations, as quantized_linear.quantizeQ80 does
/// (GGML's x86 rule): d = amax / 127 rounded to f16, the values times
/// 127 / amax rounded to nearest even and held to [-127, 127]; both
/// quotients divided exactly; a zero block stays zero. Eight fibers per
/// 32-lane block, eight blocks per workgroup; the grid is (blocks / 8
/// rounded up, tokens), a last group past the row's blocks stores nothing.
/// `aq` holds the i8 values (k per token), `ad` the f32 scales (k / 32).
/// Magnitudes are normal floats or zero.
pub fn q80QuantSource() []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var s: []const u8 =
            \\@localsize 64, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 2
            \\
        ;
        // r4 lane, r5 block (clamped into the row; r18: it is the row's),
        // r6 element index t * k + block * 32 + lane * 4, r7 its f32 bytes
        s = s ++ line("and.b {s}, r0.x, 7", .{r(4)});
        s = s ++ line("shr.b {s}, r0.x, 3", .{r(5)});
        s = s ++ line("shl.b {s}, r48.x, 3", .{r(9)});
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(5), r(5), r(9) });
        s = s ++ line("mov.u32u32 {s}, c1.w", .{r(9)});
        s = s ++ line("cmps.u.lt {s}, {s}, {s}", .{ r(18), r(5), r(9) });
        s = s ++ line("sub.u {s}, {s}, 1", .{ r(9), r(9) });
        s = s ++ line("min.u {s}, {s}, {s}", .{ r(5), r(5), r(9) });
        // (r48.y through a register: one const/shared source per cat2 instruction)
        s = s ++ line("mov.u32u32 {s}, r48.y", .{r(6)});
        s = s ++ line("mul.u24 {s}, {s}, c1.z", .{ r(6), r(6) });
        s = s ++ line("shl.b {s}, {s}, 5", .{ r(9), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(9), r(4) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(7), r(6) });
        s = s ++ line("mov.u32u32 {s}, 0x800000", .{r(39)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(50)});
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 4", .{ r(12), r(7) });
        // the block's magnitude (|x| bits order as unsigned integers)
        for (0..4) |i| s = s ++ line("absneg.f {s}, (abs){s}", .{ r(28 + i), r(12 + i) });
        s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(28), r(29) });
        s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(32), r(30) });
        s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(32), r(31) });
        for ([_]u32{ 1, 2, 4 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(33), r(32), m });
            s = s ++ line("max.u {s}, {s}, {s}", .{ r(32), r(32), r(33) });
        }
        // d = f16(amax / 127) as f32; inverse = 127 / amax (0 for a zero block)
        s = s ++ line("mov.u32u32 {s}, 0x42fe0000", .{r(38)}); // 127.0
        s = s ++ line("cmps.u.ne {s}, {s}, 0", .{ r(33), r(32) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(37), r(32), r(33), r(38) }); // (a zero block divides 127 by 127)
        s = s ++ fdivAsm(40, 37, 38, .{ 41, 42, 43, 44, 45, 46, 47, 39 }, "div1");
        s = s ++ fdivAsm(36, 38, 37, .{ 41, 42, 43, 44, 45, 46, 47, 39 }, "div2");
        s = s ++ line("cov.f32f16 (even){s}, {s}", .{ hr(34, false), r(40) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(40), hr(34, false) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(40), r(40), r(33), r(50) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(36), r(36), r(33), r(50) });
        // q = clamp(nearest(x * inverse), -127, 127)
        for (0..4) |k| {
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(20 + k), r(12 + k), r(36) });
            s = s ++ line("rndne.f {s}, {s}", .{ r(20 + k), r(20 + k) });
            s = s ++ line("cov.f32s32 {s}, {s}", .{ r(20 + k), r(20 + k) });
            s = s ++ line("min.s {s}, {s}, 127", .{ r(20 + k), r(20 + k) });
            s = s ++ line("max.s {s}, {s}, -127", .{ r(20 + k), r(20 + k) });
        }
        s = s ++ line("cmps.u.ne p0.x, {s}, 0", .{r(18)});
        s = s ++ "br !p0.x, #done\n";
        s = s ++ line("and.b {s}, {s}, 255", .{ r(24), r(20) });
        s = s ++ line("and.b {s}, {s}, 255", .{ r(25), r(21) });
        s = s ++ line("shlg {s}, 8, {s}, {s}", .{ r(24), r(25), r(24) });
        s = s ++ line("and.b {s}, {s}, 255", .{ r(25), r(22) });
        s = s ++ line("shlg {s}, 16, {s}, {s}", .{ r(24), r(25), r(24) });
        s = s ++ line("shlg {s}, 24, {s}, {s}", .{ r(24), r(23), r(24) });
        s = s ++ line("stg.a.u32 g[c0.z+{s}+0], {s}, 1", .{ r(6), r(24) });
        s = s ++ line("cmps.u.eq p0.x, {s}, 0", .{r(4)});
        s = s ++ "br !p0.x, #done\n";
        // the scale: (t * blocks + block) * 4
        s = s ++ line("mov.u32u32 {s}, r48.y", .{r(26)});
        s = s ++ line("mul.u24 {s}, {s}, c1.w", .{ r(26), r(26) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(26), r(26), r(5) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(26), r(26) });
        s = s ++ line("stg.a.u32 g[c1.x+{s}+0], {s}, 1", .{ r(26), r(40) });
        s = s ++ "done:\nend\n";
        return s;
    }
}

/// Constants of the short convolution (vec4 c0..c2).
pub const ConvConsts = struct {
    mixed: u64,
    taps: u64,
    state: u64,
    out: u64,
    hidden: u32,
    tokens: u32,

    pub fn dwords(c: ConvConsts) [12]u32 {
        return .{
            @truncate(c.mixed), @truncate(c.mixed >> 32), @truncate(c.taps), @truncate(c.taps >> 32),
            @truncate(c.state), @truncate(c.state >> 32), @truncate(c.out),  @truncate(c.out >> 32),
            c.hidden,           c.tokens,                 c.hidden * 4,      c.hidden * 12,
        };
    }
};

/// LFM3's gated short convolution, as lfm3_executor.shortConvChannels: one
/// fiber per channel, the tokens in order; window = the `taps - 1` rows of
/// state then B*X, sum oldest tap first from 0, out = C * sum, and the
/// last `taps - 1` inputs left in the state. Separate multiplies and adds,
/// as the CPU: the same floats. Grid (hidden / 64).
pub fn convSource(comptime taps: comptime_int) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        if (taps < 2 or taps > 8) @compileError("taps");
        const hist = taps - 1;
        var s: []const u8 =
            \\@localsize 64, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 3
            \\
        ;
        // 4 channel, 5 channel * 4, 6 taps offset, 7 scratch
        // 8.. weights, 16.. window (hist + 1), 32 t, 33 mixed offset, 34 out offset
        s = s ++ line("shl.b {s}, r48.x, 6", .{r(4)});
        s = s ++ line("add.u {s}, {s}, r0.x", .{ r(4), r(4) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(5), r(4) });
        s = s ++ line("mul.u24 {s}, {s}, {d}", .{ r(6), r(4), taps * 4 });
        for (0..taps) |j| s = s ++ line("ldg.a.f32 {s}, g[c0.z+{s}+{d}], 1", .{ r(8 + j), r(6), 4 * j });
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(7), r(5) });
        for (0..hist) |row| {
            s = s ++ line("ldg.a.f32 {s}, g[c1.x+{s}+0], 1", .{ r(16 + row), r(7) });
            s = s ++ line("add.u {s}, {s}, c2.z", .{ r(7), r(7) });
        }
        s = s ++ line("mov.u32u32 {s}, 0", .{r(32)});
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(33), r(5) });
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(34), r(5) });
        s = s ++ "loop:\n";
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(36), r(33) }); // B
        s = s ++ line("add.u {s}, {s}, c2.z", .{ r(37), r(33) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(38), r(37) }); // C
        s = s ++ line("add.u {s}, {s}, c2.z", .{ r(37), r(37) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(39), r(37) }); // X
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(16 + hist), r(36), r(39) });
        s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(40)});
        for (0..taps) |j| {
            s = s ++ line("mul.f {s}, {s}, {s}", .{ r(41), r(16 + j), r(8 + j) });
            s = s ++ line("add.f {s}, {s}, {s}", .{ r(40), r(40), r(41) });
        }
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(40), r(38), r(40) });
        s = s ++ line("stg.a.f32 g[c1.z+{s}+0], {s}, 1", .{ r(34), r(40) });
        for (0..hist) |j| s = s ++ line("mov.u32u32 {s}, {s}", .{ r(16 + j), r(17 + j) });
        s = s ++ line("add.u {s}, {s}, c2.w", .{ r(33), r(33) });
        s = s ++ line("add.u {s}, {s}, c2.z", .{ r(34), r(34) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(32), r(32) });
        s = s ++ "cmps.u.lt p0.x, " ++ r(32) ++ ", c2.y\n";
        s = s ++ "br p0.x, #loop\n";
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(7), r(5) });
        for (0..hist) |row| {
            s = s ++ line("stg.a.f32 g[c1.x+{s}+0], {s}, 1", .{ r(7), r(16 + row) });
            s = s ++ line("add.u {s}, {s}, c2.z", .{ r(7), r(7) });
        }
        s = s ++ "end\n";
        return s;
    }
}

/// Constants of the attention kernels (vec4 c0..c5).
pub const AttnConsts = struct {
    query: u64,
    key: u64 = 0,
    value: u64 = 0,
    query_norm: u64 = 0,
    key_norm: u64 = 0,
    rope: u64 = 0,
    gate: u64 = 0,
    out: u64 = 0,
    kv: u64,
    heads: u32,
    kv_heads: u32,
    head_size: u32,
    context: u32,
    slot: u32,
    max_kv_heads: u32,
    first_position: u32,
    epsilon: f32 = 0,
    window: u32 = 0,

    pub fn dwords(a: AttnConsts) [24]u32 {
        const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(a.head_size)));
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(a.head_size));
        return .{
            @truncate(a.query),      @truncate(a.query >> 32),      @truncate(a.key),      @truncate(a.key >> 32),
            @truncate(a.value),      @truncate(a.value >> 32),      @truncate(a.query_norm), @truncate(a.query_norm >> 32),
            @truncate(a.key_norm),   @truncate(a.key_norm >> 32),   @truncate(a.rope),     @truncate(a.rope >> 32),
            @truncate(a.kv),         @truncate(a.kv >> 32),         a.heads,               a.kv_heads,
            a.context * a.head_size * 2, a.slot,                    a.max_kv_heads,        a.first_position,
            @bitCast(a.epsilon),     @bitCast(inv),                 @bitCast(scale),       a.window,
        };
    }

    /// The attention kernel's c6/c7: gate logits, the output, log2 of the
    /// query heads per KV head.
    pub fn outDwords(a: AttnConsts) [8]u32 {
        const group = a.heads / a.kv_heads;
        return .{ @truncate(a.gate), @truncate(a.gate >> 32), @truncate(a.out), @truncate(a.out >> 32), std.math.log2_int(u32, group), 0, 0, 0 };
    }
};

/// Longest attention span one workgroup handles (local memory: the query,
/// then a score per position and 64 spare).
pub const MAX_ATTENTION_SPAN = 4096;

/// One (query head, token) per wave, as the CPU's AttentionTask: scores
/// q . k over the visible keys (q and k through f16; eight lane sums, in
/// order, as dotHalf), times 1/sqrt(head size); softmax (exp through the
/// SFU, the sum in f32 where the CPU sums in f64: a float path); weights
/// rounded to f16, times the f16 values, summed in position order; then the
/// head's sigmoid gate. Constants: AttnConsts.dwords then outDwords.
/// Grid (heads, tokens).
pub fn attentionSource() []const u8 {
    comptime {
        @setEvalBranchQuota(20_000_000);
        var s: []const u8 = std.fmt.comptimePrint(
            \\@localsize 64, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 8
            \\@shared {d}
            \\
        , .{512 + (MAX_ATTENTION_SPAN + 64) * 4});
        // 4 h, 5 t, 6 j, 7 pos, 8 visible, 9 L, 10 kv head, 11 key block, 12 value block
        s = s ++ line("mov.u32u32 {s}, r48.x", .{r(4)});
        s = s ++ line("mov.u32u32 {s}, r48.y", .{r(5)});
        s = s ++ line("mov.u32u32 {s}, r0.x", .{r(6)});
        s = s ++ line("add.u {s}, c4.w, {s}", .{ r(7), r(5) });
        // visible: window and pos >= window ? pos - window + 1 : 0
        s = s ++ line("cmps.u.ge {s}, {s}, c5.w", .{ r(13), r(7) });
        s = s ++ line("cmps.u.ne {s}, c5.w, 0", .{r(14)});
        s = s ++ line("and.b {s}, {s}, {s}", .{ r(13), r(13), r(14) });
        s = s ++ line("sub.u {s}, {s}, c5.w", .{ r(8), r(7) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(8), r(8) });
        s = s ++ line("mov.u32u32 {s}, 0", .{r(15)});
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(8), r(8), r(13), r(15) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(9), r(7) });
        s = s ++ line("sub.u {s}, {s}, {s}", .{ r(9), r(9), r(8) });
        s = s ++ line("shr.b {s}, {s}, c7.x", .{ r(10), r(4) });
        // key block ((slot * 2) * max_kv + kv head) * block bytes; values one max_kv on
        s = s ++ line("shl.b {s}, c4.y, 1", .{r(13)});
        s = s ++ line("mul.u24 {s}, {s}, c4.z", .{ r(13), r(13) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(13), r(13), r(10) });
        s = s ++ line("mov.u32u32 {s}, c4.x", .{r(14)});
        s = s ++ line("mull.u {s}, {s}, {s}", .{ r(11), r(13), r(14) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(11), r(13), r(14), r(11) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(11), r(14), r(13), r(11) });
        s = s ++ line("add.u {s}, {s}, c4.z", .{ r(13), r(13) });
        s = s ++ line("mull.u {s}, {s}, {s}", .{ r(12), r(13), r(14) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(12), r(13), r(14), r(12) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(12), r(14), r(13), r(12) });
        // the query into local memory
        s = s ++ line("mul.u24 {s}, {s}, c3.z", .{ r(13), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(13), r(13), r(4) });
        s = s ++ line("shl.b {s}, {s}, 9", .{ r(13), r(13) }); // query row bytes
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(14), r(6) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(15), r(13), r(14) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(58), r(15) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(16), r(15) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(17), r(58) });
        s = s ++ line("stl.f32 l[{s}], {s}, 1", .{ r(14), r(16) });
        s = s ++ line("stl.f32 l[{s}+256], {s}, 1", .{ r(14), r(17) });
        s = s ++ "bar\nfence.l.r.w\n";
        // passes over the span: ceil(L / 64)
        s = s ++ line("add.u {s}, {s}, 63", .{ r(18), r(9) });
        s = s ++ line("shr.b {s}, {s}, 6", .{ r(18), r(18) });
        s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(57)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(19)});
        s = s ++ "scores:\n";
        // p_rel = pass * 64 + j; valid = p_rel < L; key row (visible + p_rel, or visible)
        s = s ++ line("shl.b {s}, {s}, 6", .{ r(20), r(19) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(20), r(20), r(6) });
        s = s ++ line("cmps.u.lt {s}, {s}, {s}", .{ r(21), r(20), r(9) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(22), r(8), r(20) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(22), r(22), r(21), r(8) });
        s = s ++ line("shl.b {s}, {s}, 8", .{ r(22), r(22) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(22), r(22), r(11) });
        for (0..8) |l| s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(40 + l)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(23)});
        for (0..16) |i| {
            s = s ++ line("ldl.f32 {s}, l[{s}+{d}], 4", .{ r(32), r(23), 32 * i });
            s = s ++ line("ldl.f32 {s}, l[{s}+{d}], 4", .{ r(36), r(23), 32 * i + 16 });
            s = s ++ line("ldg.a.u16 {s}, g[c3.x+{s}+{d}], 4", .{ hr(24, false), r(22), 16 * i });
            s = s ++ line("ldg.a.u16 {s}, g[c3.x+{s}+{d}], 4", .{ hr(26, false), r(22), 16 * i + 8 });
            for (0..8) |l| {
                s = s ++ line("cov.f16f32 {s}, {s}", .{ r(48 + l), hr(24 + l / 2, l % 2 == 1) });
                s = s ++ line("mul.f {s}, {s}, {s}", .{ r(48 + l), r(32 + l), r(48 + l) });
                s = s ++ line("add.f {s}, {s}, {s}", .{ r(40 + l), r(40 + l), r(48 + l) });
            }
        }
        s = s ++ line("mov.f32f32 {s}, {s}", .{ r(56), r(40) });
        for (1..8) |l| s = s ++ line("add.f {s}, {s}, {s}", .{ r(56), r(56), r(40 + l) });
        s = s ++ line("mul.f {s}, {s}, c5.z", .{ r(56), r(56) });
        // store at 512 + 4 p_rel, or in the spare slots past L
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(23), r(9), r(6) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(23), r(20), r(21), r(23) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(23), r(23) });
        s = s ++ line("stl.f32 l[{s}+512], {s}, 1", .{ r(23), r(56) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(19), r(19) });
        s = s ++ line("cmps.u.lt p0.x, {s}, {s}", .{ r(19), r(18) });
        s = s ++ "br p0.x, #scores\n";
        s = s ++ "bar\nfence.l.r.w\n";
        // the maximum
        s = s ++ line("mov.u32u32 {s}, 0xff800000", .{r(24)}); // -inf
        s = s ++ line("mov.u32u32 {s}, 0", .{r(19)});
        s = s ++ "maxloop:\n";
        s = s ++ line("shl.b {s}, {s}, 6", .{ r(20), r(19) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(20), r(20), r(6) });
        s = s ++ line("cmps.u.lt {s}, {s}, {s}", .{ r(21), r(20), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(23), r(20) });
        s = s ++ line("ldl.f32 {s}, l[{s}+512], 1", .{ r(25), r(23) });
        s = s ++ line("max.f {s}, {s}, {s}", .{ r(26), r(24), r(25) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(24), r(26), r(21), r(24) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(19), r(19) });
        s = s ++ line("cmps.u.lt p0.x, {s}, {s}", .{ r(19), r(18) });
        s = s ++ "br p0.x, #maxloop\n";
        for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(25), r(24), m });
            s = s ++ line("max.f {s}, {s}, {s}", .{ r(24), r(24), r(25) });
        }
        // e = exp(score - max) in place, and the total
        s = s ++ line("mov.f32f32 {s}, (1.44269504)", .{r(27)});
        s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(28)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(19)});
        s = s ++ "exploop:\n";
        s = s ++ line("shl.b {s}, {s}, 6", .{ r(20), r(19) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(20), r(20), r(6) });
        s = s ++ line("cmps.u.lt {s}, {s}, {s}", .{ r(21), r(20), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(23), r(20) });
        s = s ++ line("ldl.f32 {s}, l[{s}+512], 1", .{ r(25), r(23) });
        s = s ++ line("add.f {s}, {s}, (neg){s}", .{ r(25), r(25), r(24) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(25), r(25), r(27) });
        s = s ++ line("exp2 {s}, {s}", .{ r(25), r(25) });
        s = s ++ line("stl.f32 l[{s}+512], {s}, 1", .{ r(23), r(25) });
        s = s ++ line("sel.b32 {s}, {s}, {s}, {s}", .{ r(25), r(25), r(21), r(57) });
        s = s ++ line("add.f {s}, {s}, {s}", .{ r(28), r(28), r(25) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(19), r(19) });
        s = s ++ line("cmps.u.lt p0.x, {s}, {s}", .{ r(19), r(18) });
        s = s ++ "br p0.x, #exploop\n";
        for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(25), r(28), m });
            s = s ++ line("add.f {s}, {s}, {s}", .{ r(28), r(28), r(25) });
        }
        s = s ++ line("rcp {s}, {s}", .{ r(28), r(28) });
        s = s ++ "bar\nfence.l.r.w\n";
        // out = sum over positions of f16(e * inverse) * f16 value, then the gate
        s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(29)});
        s = s ++ line("mov.f32f32 {s}, (0.0)", .{r(30)});
        s = s ++ line("shl.b {s}, {s}, 8", .{ r(31), r(8) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(31), r(31), r(12) });
        s = s ++ line("shl.b {s}, {s}, 1", .{ r(23), r(6) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(31), r(31), r(23) }); // value row of `visible`, element j
        s = s ++ line("mov.u32u32 {s}, 0", .{r(19)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(20)});
        s = s ++ "outloop:\n";
        s = s ++ line("ldl.f32 {s}, l[{s}+512], 1", .{ r(25), r(20) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(25), r(25), r(28) });
        s = s ++ line("cov.f32f16 (even){s}, {s}", .{ hr(26, false), r(25) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(25), hr(26, false) });
        s = s ++ line("ldg.a.u16 {s}, g[c3.x+{s}+0], 1", .{ hr(32, false), r(31) });
        s = s ++ line("ldg.a.u16 {s}, g[c3.x+{s}+128], 1", .{ hr(32, true), r(31) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(33), hr(32, false) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(34), hr(32, true) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(33), r(25), r(33) });
        s = s ++ line("add.f {s}, {s}, {s}", .{ r(29), r(29), r(33) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(34), r(25), r(34) });
        s = s ++ line("add.f {s}, {s}, {s}", .{ r(30), r(30), r(34) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(31), r(31) });
        s = s ++ line("add.u {s}, {s}, 4", .{ r(20), r(20) });
        s = s ++ line("add.u {s}, {s}, 1", .{ r(19), r(19) });
        s = s ++ line("cmps.u.lt p0.x, {s}, {s}", .{ r(19), r(9) });
        s = s ++ "br p0.x, #outloop\n";
        // gate = 1 / (1 + exp(-logit))
        s = s ++ line("mul.u24 {s}, {s}, c3.z", .{ r(35), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(35), r(35), r(4) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(35), r(35) });
        s = s ++ line("ldg.a.f32 {s}, g[c6.x+{s}+0], 1", .{ r(36), r(35) });
        s = s ++ line("mul.f {s}, {s}, (neg){s}", .{ r(36), r(36), r(27) });
        s = s ++ line("exp2 {s}, {s}", .{ r(36), r(36) });
        s = s ++ line("add.f {s}, {s}, (1.0)", .{ r(36), r(36) });
        s = s ++ line("rcp {s}, {s}", .{ r(36), r(36) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(29), r(29), r(36) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(30), r(30), r(36) });
        s = s ++ line("stg.a.f32 g[c6.z+{s}+0], {s}, 1", .{ r(15), r(29) });
        s = s ++ line("stg.a.f32 g[c6.z+{s}+0], {s}, 1", .{ r(58), r(30) });
        s = s ++ "end\n";
        return s;
    }
}

/// Per token, as the CPU's PrepareTask: RMSNorm of each query and key head
/// (f32 sums: a float path), NeoX RoPE with cosines and sines the host
/// computed exactly as lfm3_executor.ropeNeox does (`rope`: per token, per
/// lane pair, cos then sin), the query rounded through f16, and the key
/// and value rows written to the f16 KV cache in the CPU's layout. One wave
/// per head of 128 (fiber j holds elements j and j + 64, a RoPE pair). Grid
/// (heads + 2 kv_heads, tokens).
pub fn prepareSource() []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var s: []const u8 =
            \\@localsize 64, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 6
            \\
        ;
        // 4 head kind offsets, 5 token, 6 row byte offset, 8 j*4
        s = s ++ line("mov.u32u32 {s}, r48.y", .{r(5)});
        s = s ++ line("shl.b {s}, r0.x, 2", .{r(8)});
        s = s ++ line("mov.u32u32 {s}, c3.z", .{r(9)}); // heads
        // kind: 0 query, 1 key, 2 value; local head index
        s = s ++ line("cmps.u.lt p0.x, r48.x, {s}", .{r(9)});
        s = s ++ "br !p0.x, #notq\n";
        // query: row (t * heads + h) * 512 bytes, the norm, rope, f16, back in place
        s = s ++ line("mul.u24 {s}, {s}, c3.z", .{ r(6), r(5) });
        s = s ++ line("add.u {s}, {s}, r48.x", .{ r(6), r(6) });
        s = s ++ line("shl.b {s}, {s}, 9", .{ r(6), r(6) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(8) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(7), r(6) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(12), r(6) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 1", .{ r(13), r(7) });
        s = s ++ headNorm("c1.z");
        s = s ++ rope();
        s = s ++ line("cov.f32f16 (even){s}, {s}", .{ hr(20, false), r(12) });
        s = s ++ line("cov.f32f16 (even){s}, {s}", .{ hr(20, true), r(13) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(12), hr(20, false) });
        s = s ++ line("cov.f16f32 {s}, {s}", .{ r(13), hr(20, true) });
        s = s ++ line("stg.a.f32 g[c0.x+{s}+0], {s}, 1", .{ r(6), r(12) });
        s = s ++ line("stg.a.f32 g[c0.x+{s}+0], {s}, 1", .{ r(7), r(13) });
        s = s ++ "end\n";
        s = s ++ "notq:\n";
        // key or value (r16 = 1): local head kh, row (t * kv_heads + kh) * 512 bytes
        s = s ++ line("sub.u {s}, r48.x, {s}", .{ r(11), r(9) });
        s = s ++ line("cmps.u.ge {s}, {s}, c3.w", .{ r(16), r(11) });
        s = s ++ line("mul.u24 {s}, {s}, c3.w", .{ r(14), r(16) });
        s = s ++ line("sub.u {s}, {s}, {s}", .{ r(11), r(11), r(14) });
        s = s ++ line("cmps.u.eq p0.y, {s}, 0", .{r(16)});
        s = s ++ line("mul.u24 {s}, {s}, c3.w", .{ r(6), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(11) });
        s = s ++ line("shl.b {s}, {s}, 9", .{ r(6), r(6) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(6), r(6), r(8) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(7), r(6) });
        // cache row: (((slot * 2 + is_value) * max_kv + kh) * context + position) * head_size
        s = s ++ line("add.u {s}, c4.w, {s}", .{ r(15), r(5) }); // position
        s = s ++ "br !p0.y, #value\n";
        s = s ++ line("ldg.a.f32 {s}, g[c0.z+{s}+0], 1", .{ r(12), r(6) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.z+{s}+0], 1", .{ r(13), r(7) });
        s = s ++ headNorm("c2.x");
        s = s ++ rope();
        s = s ++ "jump #store\n";
        s = s ++ "value:\n";
        s = s ++ line("ldg.a.f32 {s}, g[c1.x+{s}+0], 1", .{ r(12), r(6) });
        s = s ++ line("ldg.a.f32 {s}, g[c1.x+{s}+0], 1", .{ r(13), r(7) });
        s = s ++ "store:\n";
        s = s ++ line("shl.b {s}, c4.y, 1", .{r(17)}); // slot * 2
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(17), r(17), r(16) });
        s = s ++ line("mul.u24 {s}, {s}, c4.z", .{ r(17), r(17) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(17), r(17), r(11) });
        // (block) * context * head_size * 2 + position * 256 + j * 2
        s = s ++ line("mov.u32u32 {s}, c4.x", .{r(18)});
        s = s ++ line("mull.u {s}, {s}, {s}", .{ r(19), r(17), r(18) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(19), r(17), r(18), r(19) });
        s = s ++ line("madsh.m16 {s}, {s}, {s}, {s}", .{ r(19), r(18), r(17), r(19) });
        s = s ++ line("shl.b {s}, {s}, 8", .{ r(17), r(15) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(19), r(19), r(17) });
        s = s ++ line("shl.b {s}, r0.x, 1", .{r(17)});
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(19), r(19), r(17) });
        s = s ++ line("cov.f32f16 (even){s}, {s}", .{ hr(20, false), r(12) });
        s = s ++ line("cov.f32f16 (even){s}, {s}", .{ hr(20, true), r(13) });
        s = s ++ line("stg.a.u16 g[c3.x+{s}+0], {s}, 1", .{ r(19), hr(20, false) });
        s = s ++ line("add.u {s}, {s}, 128", .{ r(19), r(19) });
        s = s ++ line("stg.a.u16 g[c3.x+{s}+0], {s}, 1", .{ r(19), hr(20, true) });
        s = s ++ "end\n";
        return s;
    }
}

/// RMSNorm of the head in r12 (element j) and r13 (element j + 64), the
/// weights at `w` (a const register pair holding the address).
fn headNorm(comptime w: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "";
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(24), r(12), r(12) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(25), r(13), r(13) });
        s = s ++ line("add.f {s}, {s}, {s}", .{ r(24), r(24), r(25) });
        for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| {
            s = s ++ line("shfl.xor.u32 {s}, {s}, {d}", .{ r(25), r(24), m });
            s = s ++ line("add.f {s}, {s}, {s}", .{ r(24), r(24), r(25) });
        }
        s = s ++ line("mul.f {s}, {s}, c5.y", .{ r(24), r(24) });
        s = s ++ line("add.f {s}, {s}, c5.x", .{ r(24), r(24) });
        s = s ++ line("rsq {s}, {s}", .{ r(24), r(24) });
        s = s ++ line("add.u {s}, {s}, 256", .{ r(36), r(8) });
        s = s ++ line("ldg.a.f32 {s}, g[{s}+{s}+0], 1", .{ r(26), w, r(8) });
        s = s ++ line("ldg.a.f32 {s}, g[{s}+{s}+0], 1", .{ r(27), w, r(36) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(12), r(12), r(24) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(13), r(13), r(24) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(12), r(12), r(26) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(13), r(13), r(27) });
        return s;
    }
}

/// NeoX rotation of the pair (r12, r13) by the host's cos/sin of lane j.
fn rope() []const u8 {
    comptime {
        var s: []const u8 = "";
        // rope[(t * 64 + j) * 2]: cos, sin
        s = s ++ line("shl.b {s}, {s}, 6", .{ r(28), r(5) });
        s = s ++ line("add.u {s}, {s}, r0.x", .{ r(28), r(28) });
        s = s ++ line("shl.b {s}, {s}, 3", .{ r(28), r(28) });
        s = s ++ line("ldg.a.f32 {s}, g[c2.z+{s}+0], 2", .{ r(29), r(28) });
        // low' = low cos - high sin; high' = low sin + high cos
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(31), r(12), r(29) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(32), r(13), r(30) });
        s = s ++ line("add.f {s}, {s}, (neg){s}", .{ r(31), r(31), r(32) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(33), r(12), r(30) });
        s = s ++ line("mul.f {s}, {s}, {s}", .{ r(34), r(13), r(29) });
        s = s ++ line("add.f {s}, {s}, {s}", .{ r(13), r(33), r(34) });
        s = s ++ line("mov.u32u32 {s}, {s}", .{ r(12), r(31) });
        return s;
    }
}

/// The cosines and sines the prepare kernel rotates by, for `tokens`
/// positions from `first_position`: exactly lfm3_executor.ropeNeox's angles
/// (theta from the position, times base^(-2/d) per lane pair, divided by
/// the optional factors) and its f32 @cos/@sin. out[(t * half + lane) * 2]
/// is the cosine, + 1 the sine.
pub fn ropeTable(out: []f32, first_position: usize, tokens: usize, head_size: usize, base: f32, factors: ?[]const f32) void {
    const half = head_size / 2;
    const exponent = -2.0 / @as(f64, @floatFromInt(head_size));
    const theta_scale: f32 = @floatCast(@exp(exponent * @log(@as(f64, base))));
    for (0..tokens) |t| {
        var theta: f32 = @floatFromInt(first_position + t);
        for (0..half) |lane| {
            const angle = if (factors) |divisors| theta / divisors[lane] else theta;
            out[(t * half + lane) * 2] = @cos(angle);
            out[(t * half + lane) * 2 + 1] = @sin(angle);
            theta *= theta_scale;
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const quantized = @import("quantized_linear");
const device = adreno.device;

const TestRig = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    /// The GPU's own memory: a missing toDevice/fromDevice shows.
    var gpu_view: [24 << 20]u8 align(4096) = undefined;
    var emu: device.EmuDevice = undefined;
    var asm_work: ir3_asm.Work = .{};
};

/// Run a stream with every buffer handed to the GPU first and fetched back
/// after (these tests check the kernels' arithmetic; the Backend's own
/// hand-overs are checked by tests/test_lfm3_gpu.sig).
fn runSynced(d: device.Device, ib: device.Buffer, dwords: u32) !void {
    const T = TestRig;
    T.emu.cpuToGpu(@intFromPtr(&T.arena), T.emu.used);
    try d.run(ib, dwords, 1_000_000);
    T.emu.gpuToCpu(@intFromPtr(&T.arena), T.emu.used);
}

fn emuFailure(e: anyerror) anyerror {
    const T = TestRig;
    var buf: [512]u8 = undefined;
    std.debug.print("emulated GPU: {s}\n", .{T.emu.describe(null, &buf)});
    return e;
}

test "every kernel keeps ir3's operand rules, its constlen and its register footprint" {
    const T = TestRig;
    var code: [ir3_asm.MAX_INSTRS + 16]u64 = undefined;
    const sources = comptime blk: {
        var list: []const []const u8 = &.{};
        for (1..MAX_TOKENS + 1) |t| list = list ++ &[_][]const u8{ q4kMatrixSource(t), q6kMatrixSource(t), q80MatrixSource(t) };
        for ([_]comptime_int{ 1, 2, 4, 8, 16 }) |w| list = list ++ &[_][]const u8{ quantSource(true, w), residualSource(true, w), residualSource(false, w) };
        for (2..9) |taps| list = list ++ &[_][]const u8{convSource(taps)};
        list = list ++ &[_][]const u8{ quantSource(false, 1), swigluSource(), prepareSource(), attentionSource(), q80QuantSource() };
        break :blk list;
    };
    for (sources, 0..) |src, i| {
        const k = ir3_asm.assemble(ir3.A7XX, src, &T.asm_work, &code) catch |e| {
            std.debug.print("kernel {d}: assemble: line {d}: {s}\n", .{ i, T.asm_work.err_line, @errorName(e) });
            return e;
        };
        if (device.checkKernel(&k)) |bad| {
            var buf: [160]u8 = undefined;
            const in = try ir3.decode(ir3.A7XX, k.code[bad.pc]);
            std.debug.print("kernel {d}, instruction {d}: {s}: {s}\n", .{ i, bad.pc, ir3.format(ir3.A7XX, &in, &buf) catch "?", bad.rule });
            return error.TestUnexpectedResult;
        }
    }
}

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

/// GPU activation arrays from CPU Q8K blocks.
fn splitActivations(blocks: []const quantized.Q8KBlock, aq: []i8, ad: []f32, abs: []i16) void {
    for (blocks, 0..) |b, i| {
        @memcpy(aq[i * QK_K ..][0..QK_K], &b.qs);
        ad[i] = b.d;
        @memcpy(abs[i * 16 ..][0..16], &b.bsums);
    }
}

fn runMatrix(comptime tokens: comptime_int, comptime q4: bool, rows: u32, blocks: u32) !void {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena, .gpu_view = &T.gpu_view };
    const d = T.emu.device();
    const k_cols = blocks * QK_K;
    const block_bytes: u32 = if (q4) Q4_K_BLOCK else Q6_K_BLOCK;
    const row_bytes = blocks * block_bytes;
    const w = try d.alloc(rows * row_bytes);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    const abs = try d.alloc(tokens * blocks * 32);
    const out = try d.alloc(tokens * rows * 4);
    const code = try d.alloc(64 * 1024);
    const ib = try d.alloc(64 * 1024);
    var seed: u32 = 99;
    for (w.cpu, 0..) |*b, i| b.* = @truncate(lcg(&seed) >> 13 ^ i);
    // sane f16 scales: d in [2^-10, 2^-6), dmin likewise
    const bb: usize = block_bytes;
    for (0..rows * blocks) |blk| {
        const base = blk * bb;
        const at = if (q4) base else base + 208;
        const v0: u16 = @intCast(0x1400 + (lcg(&seed) >> 22));
        std.mem.writeInt(u16, w.cpu[at..][0..2], v0, .little);
        if (q4) std.mem.writeInt(u16, w.cpu[base + 2 ..][0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
    }
    var x: [MAX_TOKENS * 7680]f32 = undefined;
    for (x[0 .. tokens * k_cols]) |*v| v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 3.0;
    var q8: [MAX_TOKENS * 30]quantized.Q8KBlock = undefined;
    try quantized.quantizeQ8K(x[0 .. tokens * k_cols], q8[0 .. tokens * blocks]);
    splitActivations(q8[0 .. tokens * blocks], std.mem.bytesAsSlice(i8, aq.cpu), @alignCast(std.mem.bytesAsSlice(f32, ad.cpu)), @alignCast(std.mem.bytesAsSlice(i16, abs.cpu)));
    const src = comptime if (q4) q4kMatrixSource(tokens) else q6kMatrixSource(tokens);
    const k = ir3_asm.assemble(ir3.A7XX, src, &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("assemble: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    var s = adreno.a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code.va);
    const consts = (MatrixConsts{ .weights = w.va, .act_q = aq.va, .act_d = ad.va, .act_sums = abs.va, .out = out.va, .row_bytes = row_bytes, .blocks = blocks, .rows = rows }).dwords();
    s.constants(0, &consts);
    s.dispatch(&k, .{ rows / MATRIX_ROWS_PER_GROUP, 1, 1 });
    try s.check();
    try runSynced(d, ib, @intCast(s.len));
    const got: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, out.cpu));
    var mismatches: usize = 0;
    for (0..rows) |row| {
        const wrow = w.cpu[row * row_bytes ..][0..row_bytes];
        for (0..tokens) |t| {
            const acts = [1][*]const quantized.Q8KBlock{q8[t * blocks ..].ptr};
            const want = if (q4) quantized.dotQ4KQ8KTile(1, wrow, acts, blocks)[0] else quantized.dotQ6KQ8KTile(1, wrow, acts, blocks)[0];
            const g = got[t * rows + row];
            if (@as(u32, @bitCast(g)) != @as(u32, @bitCast(want))) {
                if (mismatches < 5) std.debug.print("row {d} token {d}: {d} want {d}\n", .{ row, t, g, want });
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "Q4_K x Q8_K: one token, bit-exact with the CPU kernel" {
    try runMatrix(1, true, 32, 8);
}

test "Q4_K x Q8_K: four tokens, a 7680-wide row" {
    try runMatrix(4, true, 16, 30);
}

test "Q6_K x Q8_K: one token, bit-exact with the CPU kernel (odd blocks two bytes off)" {
    try runMatrix(1, false, 24, 8);
}

test "Q6_K x Q8_K: eight tokens" {
    try runMatrix(8, false, 16, 9);
}

/// quantized_linear's Q8_0 dot with mul then add (two roundings) in place of
/// its fused multiply-add, the lanes and the pairwise sum as there: what a
/// GPU whose mad.f32 rounds twice gives (the emulator's does).
fn dotQ80Unfused(wrow: []const u8, acts: []const quantized.Q80Block) f32 {
    var lanes: [8]f32 = @splat(0);
    for (acts, 0..) |a, b| {
        const blk = wrow[b * Q8_0_BLOCK ..][0..Q8_0_BLOCK];
        const d: f32 = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, blk[0..2], .little))));
        const scale = d * a.d;
        for (0..8) |l| {
            var sum: i32 = 0;
            for (0..4) |j| sum += @as(i32, @as(i8, @bitCast(blk[2 + 4 * l + j]))) * a.qs[4 * l + j];
            const p = scale * @as(f32, @floatFromInt(sum));
            lanes[l] = lanes[l] + p;
        }
    }
    const q = [4]f32{ lanes[4] + lanes[0], lanes[5] + lanes[1], lanes[6] + lanes[2], lanes[7] + lanes[3] };
    return (q[0] + q[2]) + (q[1] + q[3]);
}

fn runQ80Matrix(comptime tokens: comptime_int, rows: u32, blocks: u32) !void {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena, .gpu_view = &T.gpu_view };
    const d = T.emu.device();
    const k_cols = blocks * QK8_0;
    const row_bytes = blocks * Q8_0_BLOCK;
    const w = try d.alloc(rows * row_bytes);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    const out = try d.alloc(tokens * rows * 4);
    const code = try d.alloc(64 * 1024);
    const ib = try d.alloc(64 * 1024);
    var seed: u32 = 7;
    for (0..rows * blocks) |blk| {
        const b = w.cpu[blk * Q8_0_BLOCK ..][0..Q8_0_BLOCK];
        // d of either sign, |d| in [2^-10, 2^-6); quants in [-127, 127]
        const sign: u32 = (lcg(&seed) >> 7) & 1;
        const h: u16 = @intCast((0x1400 + (lcg(&seed) >> 22)) | (sign << 15));
        std.mem.writeInt(u16, b[0..2], h, .little);
        for (b[2..]) |*q| q.* = @bitCast(@as(i8, @intCast(@as(i32, @intCast((lcg(&seed) >> 8) % 255)) - 127)));
    }
    var x: [MAX_TOKENS * 4096]f32 = undefined;
    for (x[0 .. tokens * k_cols]) |*v| v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 3.0;
    var q8: [MAX_TOKENS * 128]quantized.Q80Block = undefined;
    try quantized.quantizeQ80(x[0 .. tokens * k_cols], q8[0 .. tokens * blocks]);
    const gq = std.mem.bytesAsSlice(i8, aq.cpu);
    const gd: []f32 = @alignCast(std.mem.bytesAsSlice(f32, ad.cpu));
    for (q8[0 .. tokens * blocks], 0..) |b, i| {
        @memcpy(gq[i * QK8_0 ..][0..QK8_0], &b.qs);
        gd[i] = b.d;
    }
    const src = comptime q80MatrixSource(tokens);
    const k = ir3_asm.assemble(ir3.A7XX, src, &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("assemble: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    var s = adreno.a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code.va);
    s.constants(0, &(Q80MatrixConsts{ .weights = w.va, .act_q = aq.va, .act_d = ad.va, .out = out.va, .row_bytes = row_bytes, .blocks = blocks, .rows = rows }).dwords());
    s.dispatch(&k, .{ (rows + MATRIX_ROWS_PER_GROUP - 1) / MATRIX_ROWS_PER_GROUP, 1, 1 });
    try s.check();
    runSynced(d, ib, @intCast(s.len)) catch |e| return emuFailure(e);
    const got: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, out.cpu));
    var mismatches: usize = 0;
    var unfused_hits: usize = 0;
    for (0..rows) |row| {
        const wrow = w.cpu[row * row_bytes ..][0..row_bytes];
        for (0..tokens) |t| {
            const acts = q8[t * blocks ..][0..blocks];
            const fused = quantized.dotQ80Q80Tile(1, wrow, .{acts.ptr}, blocks)[0];
            const unfused = dotQ80Unfused(wrow, acts);
            const g = got[t * rows + row];
            // (the two roundings stay within a few ulps of the sum's terms)
            try std.testing.expect(@abs(fused - unfused) <= 1e-5 * @max(@abs(fused), 1.0));
            const bits: u32 = @bitCast(g);
            if (bits == @as(u32, @bitCast(unfused)) and bits != @as(u32, @bitCast(fused))) unfused_hits += 1;
            if (bits != @as(u32, @bitCast(fused)) and bits != @as(u32, @bitCast(unfused))) {
                if (mismatches < 5) std.debug.print("row {d} token {d}: {d} want {d} (fused) or {d}\n", .{ row, t, g, fused, unfused });
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    // (the emulated mad rounds twice: it is that reference it follows)
    try std.testing.expect(unfused_hits > 0 or rows * tokens < 8);
}

test "Q8_0 x Q8_0: one token, rows and blocks not in eights, the CPU's sums to the bit" {
    try runQ80Matrix(1, 21, 37);
}

test "Q8_0 x Q8_0: eight tokens, 4096-wide rows" {
    try runQ80Matrix(8, 16, 128);
}

fn runQ80Quant(tokens: u32, k_cols: u32) !void {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena, .gpu_view = &T.gpu_view };
    const d = T.emu.device();
    const blocks = k_cols / QK8_0;
    const xb = try d.alloc(tokens * k_cols * 4);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    const code = try d.alloc(64 * 1024);
    const ib = try d.alloc(64 * 1024);
    var seed: u32 = 11;
    const x: []f32 = @alignCast(std.mem.bytesAsSlice(f32, xb.cpu));
    for (x, 0..) |*v, i| {
        v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 6.0;
        // a block of zeros, magnitude ties of either sign, values on the half steps
        if (i / QK8_0 == 2) v.* = 0;
        if (i % 331 == 5) v.* = 9.0;
        if (i % 331 == 9) v.* = -9.0;
        if (i % 331 == 13) v.* = 9.0 * 2.5 / 127.0;
    }
    const k = ir3_asm.assemble(ir3.A7XX, comptime q80QuantSource(), &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("assemble: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    var s = adreno.a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code.va);
    s.constants(0, &(Q80QuantConsts{ .x = xb.va, .act_q = aq.va, .act_d = ad.va, .k = k_cols }).dwords());
    s.dispatch(&k, .{ (blocks + 7) / 8, tokens, 1 });
    try s.check();
    runSynced(d, ib, @intCast(s.len)) catch |e| return emuFailure(e);
    var cpu: [3 * 64]quantized.Q80Block = undefined;
    try quantized.quantizeQ80(x[0 .. tokens * k_cols], cpu[0 .. tokens * blocks]);
    const gq = std.mem.bytesAsSlice(i8, aq.cpu);
    const gd: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, ad.cpu));
    for (cpu[0 .. tokens * blocks], 0..) |b, i| {
        if (@as(u32, @bitCast(b.d)) != @as(u32, @bitCast(gd[i]))) {
            std.debug.print("block {d}: d {e} want {e}\n", .{ i, gd[i], b.d });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualSlices(i8, &b.qs, gq[i * QK8_0 ..][0..QK8_0]);
    }
}

test "Q8_0 quantization: bit-exact with quantizeQ80 (a zero block, ties, a last partial group)" {
    try runQ80Quant(3, 32 * 37);
}

fn runQuant(comptime norm: bool, tokens: u32, comptime k_cols: u32) !void {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena, .gpu_view = &T.gpu_view };
    const d = T.emu.device();
    const blocks = k_cols / QK_K;
    const xb = try d.alloc(tokens * k_cols * 4);
    const wb = try d.alloc(k_cols * 4);
    const yb = try d.alloc(tokens * k_cols * 4);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    const abs = try d.alloc(tokens * blocks * 32);
    const code = try d.alloc(64 * 1024);
    const ib = try d.alloc(64 * 1024);
    var seed: u32 = 5;
    const x: []f32 = @alignCast(std.mem.bytesAsSlice(f32, xb.cpu));
    const w: []f32 = @alignCast(std.mem.bytesAsSlice(f32, wb.cpu));
    for (x, 0..) |*v, i| {
        v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 6.0;
        // a block of zeros, and ties of magnitude
        if (i / QK_K == 3) v.* = 0;
        if (i % 997 == 5) v.* = 9.0;
        if (i % 997 == 9) v.* = -9.0;
    }
    for (w) |*v| v.* = 0.5 + @as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0;
    const src = comptime quantSource(norm, if (norm) k_cols / QK_K else 1);
    const k = ir3_asm.assemble(ir3.A7XX, src, &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("assemble: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    var s = adreno.a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code.va);
    const consts = (QuantConsts{ .x = xb.va, .norm_weight = wb.va, .normalized = yb.va, .act_q = aq.va, .act_d = ad.va, .act_sums = abs.va, .k = k_cols, .epsilon = 1e-5 }).dwords();
    s.constants(0, &consts);
    s.dispatch(&k, if (norm) .{ 1, tokens, 1 } else .{ blocks, tokens, 1 });
    try s.check();
    runSynced(d, ib, @intCast(s.len)) catch |e| return emuFailure(e);
    // what was quantized: x, or the GPU's normalized rows
    const y: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, yb.cpu));
    const q_in = if (norm) y else x;
    if (norm) {
        var worst: f64 = 0;
        for (0..tokens) |t| {
            var squares: f64 = 0;
            for (x[t * k_cols ..][0..k_cols]) |v| squares += @as(f64, v) * v;
            const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(k_cols)));
            const inverse = 1.0 / @sqrt(mean + 1e-5);
            for (0..k_cols) |i| {
                const want = x[t * k_cols + i] * inverse * w[i];
                const got = y[t * k_cols + i];
                worst = @max(worst, @abs(@as(f64, got) - want) / @max(@abs(@as(f64, want)), 1e-3));
            }
        }
        try std.testing.expect(worst < 2e-6);
    }
    var cpu: [64 * 30]quantized.Q8KBlock = undefined;
    try quantized.quantizeQ8K(q_in[0 .. tokens * k_cols], cpu[0 .. tokens * blocks]);
    const gq = std.mem.bytesAsSlice(i8, aq.cpu);
    const gd: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, ad.cpu));
    const gs: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, abs.cpu));
    for (cpu[0 .. tokens * blocks], 0..) |b, i| {
        if (@as(u32, @bitCast(b.d)) != @as(u32, @bitCast(gd[i]))) {
            std.debug.print("block {d}: d {e} want {e}\n", .{ i, gd[i], b.d });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualSlices(i8, &b.qs, gq[i * QK_K ..][0..QK_K]);
        try std.testing.expectEqualSlices(i16, &b.bsums, gs[i * 16 ..][0..16]);
    }
}

test "Q8_K quantization: bit-exact with quantizeQ8K (zero block, magnitude ties)" {
    try runQuant(false, 3, 7680);
}

test "RMSNorm then Q8_K: the norm within 2e-6, the quantization bit-exact" {
    try runQuant(true, 2, 2048);
}

// CPU references: lfm3_executor's arithmetic, step for step.
const ref = struct {
    fn rmsNormRow(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
        var squares: f64 = 0;
        for (input) |value| squares += @as(f64, value) * value;
        const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
        const inverse = 1.0 / @sqrt(mean + epsilon);
        for (input, weight, output[0..input.len]) |value, scale, *destination| destination.* = value * inverse * scale;
    }

    fn f16r(v: f32) f32 {
        return @floatCast(@as(f16, @floatCast(v)));
    }

    fn ropeNeox(values: []f32, heads: usize, head_size: usize, position: usize, base: f32) void {
        const half = head_size / 2;
        const exponent = -2.0 / @as(f64, @floatFromInt(head_size));
        const theta_scale: f32 = @floatCast(@exp(exponent * @log(@as(f64, base))));
        var theta: f32 = @floatFromInt(position);
        for (0..half) |lane| {
            const cosine = @cos(theta);
            const sine = @sin(theta);
            for (0..heads) |head| {
                const row = values[head * head_size ..][0..head_size];
                const low = row[lane];
                const high = row[lane + half];
                row[lane] = low * cosine - high * sine;
                row[lane + half] = low * sine + high * cosine;
            }
            theta *= theta_scale;
        }
    }

    fn shortConv(kernel: usize, hidden: usize, taps: []const f32, state: []f32, mixed: []const f32, tokens: usize, output: []f32) void {
        var window: [16]f32 = undefined;
        const history = kernel - 1;
        for (0..hidden) |channel| {
            for (0..history) |row| window[row] = state[row * hidden + channel];
            const weights = taps[channel * kernel ..][0..kernel];
            for (0..tokens) |slot| {
                const row = mixed[slot * 3 * hidden ..][0 .. 3 * hidden];
                window[history] = row[channel] * row[2 * hidden + channel];
                var sum: f32 = 0;
                for (window[0..kernel], weights) |input, weight| sum += input * weight;
                output[slot * hidden + channel] = row[hidden + channel] * sum;
                for (0..history) |shift| window[shift] = window[shift + 1];
            }
            for (0..history) |row| state[row * hidden + channel] = window[row];
        }
    }
};

fn fillRandom(b: []u8, seed: *u32, scale: f32, bias: f32) []f32 {
    const v: []f32 = @alignCast(std.mem.bytesAsSlice(f32, b));
    for (v) |*x| x.* = (@as(f32, @floatFromInt(lcg(seed) >> 8)) / 16777216.0 - 0.5) * scale + bias;
    return v;
}

test "short convolution: the CPU's floats exactly, state carried" {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena, .gpu_view = &T.gpu_view };
    const d = T.emu.device();
    const hidden = 256;
    const tokens = 5;
    const taps = 3;
    const mixed = try d.alloc(tokens * 3 * hidden * 4);
    const tw = try d.alloc(hidden * taps * 4);
    const state = try d.alloc(2 * hidden * 4);
    const out = try d.alloc(tokens * hidden * 4);
    const code = try d.alloc(64 * 1024);
    const ib = try d.alloc(64 * 1024);
    var seed: u32 = 31;
    const m = fillRandom(mixed.cpu, &seed, 2.0, 0);
    const w = fillRandom(tw.cpu, &seed, 2.0, 0);
    const st = fillRandom(state.cpu, &seed, 2.0, 0);
    var cpu_state: [2 * hidden]f32 = undefined;
    @memcpy(&cpu_state, st);
    var cpu_out: [tokens * hidden]f32 = undefined;
    ref.shortConv(taps, hidden, w, &cpu_state, m, tokens, &cpu_out);
    const k = ir3_asm.assemble(ir3.A7XX, comptime convSource(taps), &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("assemble conv: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    var s = adreno.a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code.va);
    s.constants(0, &(ConvConsts{ .mixed = mixed.va, .taps = tw.va, .state = state.va, .out = out.va, .hidden = hidden, .tokens = tokens }).dwords());
    s.dispatch(&k, .{ hidden / 64, 1, 1 });
    try s.check();
    runSynced(d, ib, @intCast(s.len)) catch |e| return emuFailure(e);
    const got: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, out.cpu));
    for (cpu_out, got) |a, b| try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
    for (cpu_state, st) |a, b| try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
}

test "attention: prepare (norms, RoPE, f16 KV) then scores, softmax, values, gate" {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena, .gpu_view = &T.gpu_view };
    const d = T.emu.device();
    const heads = 8;
    const kvh = 2;
    const hd = 128;
    const context = 64;
    const tokens = 3;
    const first = 37;
    const max_kv = kvh;
    const slot = 1;
    const q = try d.alloc(tokens * heads * hd * 4);
    const kb = try d.alloc(tokens * kvh * hd * 4);
    const vb = try d.alloc(tokens * kvh * hd * 4);
    const qn = try d.alloc(hd * 4);
    const kn = try d.alloc(hd * 4);
    const rope_b = try d.alloc(tokens * 64 * 2 * 4);
    const gate = try d.alloc(tokens * heads * 4);
    const out = try d.alloc(tokens * heads * hd * 4);
    const kv = try d.alloc(2 * 2 * max_kv * context * hd * 2);
    const code = try d.alloc(64 * 1024);
    const code2 = try d.alloc(64 * 1024);
    const ib = try d.alloc(64 * 1024);
    var seed: u32 = 77;
    const qv = fillRandom(q.cpu, &seed, 4.0, 0);
    const kv_in = fillRandom(kb.cpu, &seed, 4.0, 0);
    const vv = fillRandom(vb.cpu, &seed, 2.0, 0);
    const qw = fillRandom(qn.cpu, &seed, 0.5, 1.0);
    const kw = fillRandom(kn.cpu, &seed, 0.5, 1.0);
    const gv = fillRandom(gate.cpu, &seed, 4.0, 0);
    // earlier positions of the cache: random f16 keys and values
    const cache: []u16 = @alignCast(std.mem.bytesAsSlice(u16, kv.cpu));
    for (cache) |*c| c.* = @bitCast(@as(f16, @floatCast((@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 2.0)));
    const base: f32 = 10000.0;
    ropeTable(@alignCast(std.mem.bytesAsSlice(f32, rope_b.cpu)), first, tokens, hd, base, null);
    // CPU: prepare, then attend, as the executor's tasks
    var cq: [tokens * heads * hd]f32 = undefined;
    @memcpy(&cq, qv);
    var ck: [tokens * kvh * hd]f32 = undefined;
    @memcpy(&ck, kv_in);
    var ccache: [2 * 2 * max_kv * context * hd]u16 = undefined;
    @memcpy(&ccache, cache);
    const row = struct {
        fn at(v: bool, head: usize, position: usize) usize {
            return ((((slot * 2 + @as(usize, @intFromBool(v))) * max_kv + head) * context) + position) * hd;
        }
    }.at;
    for (0..tokens) |t| {
        const pos = first + t;
        for (0..heads) |h| ref.rmsNormRow(cq[(t * heads + h) * hd ..][0..hd], qw, cq[(t * heads + h) * hd ..][0..hd], 1e-5);
        for (0..kvh) |h| ref.rmsNormRow(ck[(t * kvh + h) * hd ..][0..hd], kw, ck[(t * kvh + h) * hd ..][0..hd], 1e-5);
        ref.ropeNeox(cq[t * heads * hd ..][0 .. heads * hd], heads, hd, pos, base);
        ref.ropeNeox(ck[t * kvh * hd ..][0 .. kvh * hd], kvh, hd, pos, base);
        for (cq[t * heads * hd ..][0 .. heads * hd]) |*e| e.* = ref.f16r(e.*);
        for (0..kvh) |h| for (0..hd) |e| {
            ccache[row(false, h, pos) + e] = @bitCast(@as(f16, @floatCast(ck[(t * kvh + h) * hd + e])));
            ccache[row(true, h, pos) + e] = @bitCast(@as(f16, @floatCast(vv[(t * kvh + h) * hd + e])));
        };
    }
    var cout: [tokens * heads * hd]f32 = undefined;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
    for (0..tokens) |t| for (0..heads) |h| {
        const pos = first + t;
        const kh = h / (heads / kvh);
        const query = cq[(t * heads + h) * hd ..][0..hd];
        var scores: [context]f32 = undefined;
        var maximum: f32 = -std.math.inf(f32);
        for (0..pos + 1) |p| {
            var lanes = [_]f32{0} ** 8;
            for (0..hd / 8) |i| for (0..8) |l| {
                lanes[l] += query[8 * i + l] * @as(f32, @floatCast(@as(f16, @bitCast(ccache[row(false, kh, p) + 8 * i + l]))));
            };
            var sum = lanes[0];
            for (1..8) |l| sum += lanes[l];
            scores[p] = sum * scale;
            maximum = @max(maximum, scores[p]);
        }
        var total: f64 = 0;
        for (scores[0 .. pos + 1]) |*sc| {
            sc.* = @exp(sc.* - maximum);
            total += sc.*;
        }
        const inverse: f32 = @floatCast(1.0 / total);
        const dst = cout[(t * heads + h) * hd ..][0..hd];
        @memset(dst, 0);
        for (scores[0 .. pos + 1], 0..) |sc, p| {
            const wgt = ref.f16r(sc * inverse);
            for (dst, 0..) |*acc, e| acc.* += wgt * @as(f32, @floatCast(@as(f16, @bitCast(ccache[row(true, kh, p) + e]))));
        }
        const g = 1.0 / (1.0 + @exp(-gv[t * heads + h]));
        for (dst) |*e| e.* *= g;
    };
    // GPU
    const ac = AttnConsts{ .query = q.va, .key = kb.va, .value = vb.va, .query_norm = qn.va, .key_norm = kn.va, .rope = rope_b.va, .gate = gate.va, .out = out.va, .kv = kv.va, .heads = heads, .kv_heads = kvh, .head_size = hd, .context = context, .slot = slot, .max_kv_heads = max_kv, .first_position = first, .epsilon = 1e-5 };
    const kp = ir3_asm.assemble(ir3.A7XX, comptime prepareSource(), &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("assemble prepare: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    const ka = ir3_asm.assemble(ir3.A7XX, comptime attentionSource(), &T.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code2.cpu))) catch |e| {
        std.debug.print("assemble attention: line {d}: {s}\n", .{ T.asm_work.err_line, @errorName(e) });
        return e;
    };
    var s = adreno.a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&kp, code.va);
    s.constants(0, &ac.dwords());
    s.dispatch(&kp, .{ heads + 2 * kvh, tokens, 1 });
    s.waitForIdle();
    try s.program(&ka, code2.va);
    s.constants(0, &ac.dwords());
    s.constants(6, &ac.outDwords());
    s.dispatch(&ka, .{ heads, tokens, 1 });
    try s.check();
    runSynced(d, ib, @intCast(s.len)) catch |e| return emuFailure(e);
    // the cache rows and the output: float paths, close
    for (ccache, cache, 0..) |a, b, i| {
        const fa: f32 = @floatCast(@as(f16, @bitCast(a)));
        const fb: f32 = @floatCast(@as(f16, @bitCast(b)));
        if (@abs(fa - fb) > 2e-3 * @max(@abs(fa), 1.0)) {
            std.debug.print("cache {d}: {d} want {d}\n", .{ i, fb, fa });
            return error.TestUnexpectedResult;
        }
    }
    const got: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, out.cpu));
    var worst: f64 = 0;
    for (cout, got) |a, b| worst = @max(worst, @abs(@as(f64, a) - b) / @max(@abs(@as(f64, a)), 0.05));
    if (worst > 5e-3) {
        std.debug.print("attention worst relative error {e}\n", .{worst});
        return error.TestUnexpectedResult;
    }
}
