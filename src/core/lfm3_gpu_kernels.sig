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
        const lsize = 64 * waves;
        var s: []const u8 = std.fmt.comptimePrint(
            \\@localsize {d}, 1, 1
            \\@invocationid(r0.x)
            \\@wgid(r48.x)
            \\@consts 4
            \\@shared 64
            \\
        , .{lsize});
        // 4 wave, 5 lane, 6 block, 7 element index, 8 byte offset (f32)
        s = s ++ line("shr.b {s}, r0.x, 6", .{r(4)});
        s = s ++ line("and.b {s}, r0.x, 63", .{r(5)});
        s = s ++ (if (norm) line("mov.u32u32 {s}, {s}", .{ r(6), r(4) }) else line("mov.u32u32 {s}, r48.x", .{r(6)}));
        s = s ++ line("mul.u24 {s}, r48.y, c3.x", .{r(7)});
        s = s ++ line("shl.b {s}, {s}, 8", .{ r(9), r(6) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(7), r(7), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(9), r(5) });
        s = s ++ line("add.u {s}, {s}, {s}", .{ r(7), r(7), r(9) });
        s = s ++ line("shl.b {s}, {s}, 2", .{ r(8), r(7) });
        s = s ++ line("ldg.a.f32 {s}, g[c0.x+{s}+0], 4", .{ r(12), r(8) }); // x0..x3 in r3
        s = s ++ line("mov.u32u32 {s}, 0x800000", .{r(39)});
        s = s ++ line("mov.u32u32 {s}, 0", .{r(50)});
        if (norm) {
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
            s = s ++ line("stg.a.f32 g[c1.x+{s}+0], {s}, 4", .{ r(8), r(12) });
        }
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
        // block number in the row of tokens: t * blocks + block
        s = s ++ line("mul.u24 {s}, r48.y, c3.w", .{r(28)});
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
        s = s ++ "done:\nend\n";
        return s;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const quantized = @import("quantized_linear");
const device = adreno.device;

const TestRig = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var emu: device.EmuDevice = undefined;
    var asm_work: ir3_asm.Work = .{};
};

fn emuFailure(e: anyerror) anyerror {
    const T = TestRig;
    var buf: [160]u8 = undefined;
    const at = T.emu.emu.err_pc;
    const text = ir3.format(ir3.A7XX, &T.emu.emu.code[at], &buf) catch "?";
    std.debug.print("emulated GPU: {s} at instruction {d}: {s}\n", .{ if (T.emu.last_error) |x| @errorName(x) else "?", at, text });
    return e;
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
    T.emu = .{ .arena = &T.arena };
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
    try d.run(ib, @intCast(s.len), 1_000_000);
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

fn runQuant(comptime norm: bool, tokens: u32, comptime k_cols: u32) !void {
    const T = TestRig;
    T.emu = .{ .arena = &T.arena };
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
    d.run(ib, @intCast(s.len), 1_000_000) catch |e| return emuFailure(e);
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
