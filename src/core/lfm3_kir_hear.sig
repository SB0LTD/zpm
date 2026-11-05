//! @zpm/lfm3-kir-hear — the kernels LFM3-Audio's hearing encoder adds to
//! lfm3_kir's, in KIR, built with lfm3_kir's Builder (any GPU: ir3, sm_120,
//! the interpreter). lfm3_any_hear runs them with lfm3_kir's Q8_0 matrices,
//! Q8_0 quantization, RMSNorm rows, short convolution, SwiGLU, residual,
//! bias and copy.
//!
//! | builder              | computes (lfm3_audio_encoder's)                       |
//! |----------------------|-------------------------------------------------------|
//! | `conv0()`            | the full 3x3 stride-2 conv of the mel image, SiLU     |
//! | `dwpw(c)`            | depthwise 3x3 stride 2 + pointwise c -> c, SiLU       |
//! | `headNormRope(hs)`   | per-head RMSNorm then NeoX RoPE, any even head size   |
//! | `attendWindow(hs)`   | the causal sliding-window attention, f16 keys/values  |
//! | `rmsLayerNorm()`     | the final RMSNorm, then the projector's LayerNorm     |
//! | `gelu()`             | GELU with the CPU's f64 erf series, in place          |
//!
//! # Exactness
//!
//! As lfm3_kir's header: only correctly rounded KIR ops (fadd, fsub, fmul,
//! fdiv, fsqrt) where the CPU rounds in f32, each in the CPU's order; the
//! CPU's fused multiply-adds through Builder.fma (ffma, or its exact
//! emulation where the GPU does not fuse); exp as the CPU has it (expCpu
//! for its expf, lfm3_kir.expGgml for ggml_v_expf); its f64 sums as
//! double-f32 rounded once. Per kernel:
//!
//! - conv0: ggml's f16 im2col: patch and kernel rounded to f16, the nine
//!   products exact in f32, their f64 sum carried as three f32s by TwoSum
//!   (exact) and rounded once (Boldo and Melquiond's correctly rounded sum
//!   of three, by rounding to odd): the CPU's bits whenever its f64 sum is
//!   exact, which for nine 22-bit products is always but for exponents 31
//!   bits apart.
//! - dwpw: the depthwise taps summed in f32 in the CPU's order (kh, then
//!   kw, the padding skipped); the pointwise row as the CPU's eight
//!   @mulAdd lanes (lane j takes inputs j, j + 8, ...), reduced in lane
//!   order (LLVM's ordered vector.reduce.fadd), then bias and ggml's SiLU:
//!   exact.
//! - headNormRope, rmsLayerNorm: the f64 sums as double-f32 (the CPU's
//!   rounded mean but for about one row in 2^18, as lfm3_kir's norms).
//! - attendWindow: ops.attendHead with half_kv: scores summed lane by lane
//!   in f32 against f16 keys, expf, the f64 total as a double-f32, weights
//!   times f16 values in key order: exact but for the total's rare rounding.
//! - gelu: the CPU's erf is an f64 series (ops.erf). Here the same series
//!   and exp(-x^2) run in double-f32 (about 1e-13 relative), rounded to f32
//!   as the CPU rounds its f64: the CPU's bits but for about one value in
//!   2^16 (an f64 erf within 1e-13 of an f32 rounding midpoint), which the
//!   Q8_0 quantization of the next matrix absorbs but for about 2^-17 of
//!   those.
//!
//! Allocation-free: kernels are built into the caller's Storage.

const std = @import("std");
const gpu = @import("gpu");
const lk = @import("lfm3_kir");

pub const kir = gpu.kir;
pub const Caps = gpu.Caps;
pub const Error = lk.Error;

const Builder = lk.Builder;
const DD = lk.DD;
const V = kir.V;
const Arg = kir.Arg;
const NO: Arg = kir.no;

fn R(v: V) Arg {
    return .{ .reg = v };
}
fn U(x: u32) Arg {
    return .{ .imm = x };
}
fn F(x: f32) Arg {
    return .{ .imm = @bitCast(x) };
}
fn I(x: i32) Arg {
    return .{ .imm = @bitCast(x) };
}

/// The `i`th register of a vector `v` (Kernel.vec).
fn vecAt(v: V, i: usize) V {
    return @enumFromInt(@intFromEnum(v) + @as(u16, @intCast(i)));
}

fn begin(s: kir.Storage, name: []const u8, threads: u32) kir.Kernel {
    return kir.Kernel.init(s, name, .{ threads, 1, 1 });
}

// ── Exact arithmetic ────────────────────────────────────────────────────────

/// a + c = hi + lo exactly (Knuth's TwoSum).
fn twoSum(b: *Builder, a: V, c: V) DD {
    const s = b.fadd(R(a), R(c));
    const bb = b.fsub(R(s), R(a));
    const e = b.fadd(R(b.fsub(R(a), R(b.fsub(R(s), R(bb))))), R(b.fsub(R(c), R(bb))));
    return .{ .hi = s, .lo = e };
}

/// hi + lo renormalized (|lo| <= |hi|'s ulp / 2 before, or nearly).
fn fastTwoSum(b: *Builder, hi: V, lo: V) DD {
    const s = b.fadd(R(hi), R(lo));
    return .{ .hi = s, .lo = b.fsub(R(lo), R(b.fsub(R(s), R(hi)))) };
}

/// x + y rounded to odd: the nearest sum, moved one ulp toward the exact
/// one when it was inexact and came out even (as Builder.fma's step).
fn addOdd(b: *Builder, x: V, y: V) V {
    const t = twoSum(b, x, y);
    const sb = b.as(.u32, t.hi);
    const even = b.icmp(.u32, .eq, R(b.band(R(sb), U(1))), U(0));
    const inexact = b.fcmp(.ne, R(t.lo), F(0));
    const same = b.icmp(.u32, .eq, R(b.shr(R(b.op2(.xor, .u32, R(b.as(.u32, t.lo)), R(sb))), 31)), U(0));
    const moved = b.sel(.u32, same, R(b.add(R(sb), U(1))), R(b.sub(R(sb), U(1))));
    return b.as(.f32, b.sel(.u32, b.pand(even, inexact), R(moved), R(sb)));
}

/// A sum carried exactly as three f32s (h + m + l).
const Sum3 = struct { h: V, m: V, l: V };

fn sum3Add(b: *Builder, acc: Sum3, p: V) Sum3 {
    const t1 = twoSum(b, acc.h, p);
    const t2 = twoSum(b, acc.m, t1.lo);
    return .{ .h = t1.hi, .m = t2.hi, .l = b.fadd(R(acc.l), R(t2.lo)) };
}

/// h + m + l rounded once (Boldo and Melquiond's correctly rounded sum of
/// three: TwoSum twice, the low parts added rounding to odd, one rounding).
fn sum3Round(b: *Builder, acc: Sum3) V {
    const u_ = twoSum(b, acc.m, acc.l);
    const t = twoSum(b, acc.h, u_.hi);
    return b.fadd(R(t.hi), R(addOdd(b, t.lo, u_.lo)));
}

/// ggml's SiLU (ops.silu): x / (1 + ggml_v_expf(0 - x)).
fn silu(b: *Builder, x: V) V {
    return b.fdiv(R(x), R(b.fadd(F(1.0), R(lk.expGgml(b, b.fsub(F(0), R(x)))))));
}

/// a * c as a double-f32.
fn ddMul(b: *Builder, a: DD, c: DD) DD {
    const p = b.fmul(R(a.hi), R(c.hi));
    const e = b.prodErr(a.hi, c.hi, p);
    const cross = b.fadd(R(b.fmul(R(a.hi), R(c.lo))), R(b.fmul(R(a.lo), R(c.hi))));
    return fastTwoSum(b, p, b.fadd(R(e), R(cross)));
}

/// a / d as a double-f32 (d an f32): q = hi / d, then the remainder
/// hi - q d (exact) + lo divided again.
fn ddDivF(b: *Builder, a: DD, d: V) DD {
    const q = b.fdiv(R(a.hi), R(d));
    const p = b.fmul(R(q), R(d));
    const e = b.prodErr(q, d, p);
    const r = b.fadd(R(b.fsub(R(b.fsub(R(a.hi), R(p))), R(e))), R(a.lo));
    return fastTwoSum(b, q, b.fdiv(R(r), R(d)));
}

/// An f64 constant as a double-f32 (registers).
fn ddConst(b: *Builder, x: f64) DD {
    const hi: f32 = @floatCast(x);
    const lo: f32 = @floatCast(x - @as(f64, hi));
    return .{ .hi = b.mov(.f32, F(hi)), .lo = b.mov(.f32, F(lo)) };
}

/// ln 2 in three parts: the first with 15 significant bits (k L1 exact for
/// |k| < 2^9), the second an f32, the third what is left.
const LN2: f64 = 0.693147180559945309417232121458176568;
const LN2_1: f32 = @bitCast(@as(u32, 0x3F317200));
const LN2_2: f32 = @floatCast(LN2 - @as(f64, LN2_1));
const LN2_3: f32 = @floatCast(LN2 - @as(f64, LN2_1) - @as(f64, LN2_2));
/// Taylor terms of exp for |r| <= ln 2 / 2 to 2^-50.
const EXP_TERMS = 12;

/// e^v as a double-f32, for v in [-88, 0] (the CPU's @exp(-x^2) in f64):
/// v = k ln 2 + r with k = round(v / ln 2) and r exact to double-f32, e^r by
/// its Taylor series (Horner, double-f32), times 2^k.
fn ddExpNeg(b: *Builder, v: DD) DD {
    const k = b.cvt(.f32, .i32, .rne, R(b.frne(R(b.fmul(R(v.hi), F(@floatCast(1.0 / LN2)))))));
    const kf = b.i2f(k);
    // r = v - k ln 2: v.hi - k L1 exact (Sterbenz), then the rest in double-f32
    var r: DD = .{ .hi = b.fsub(R(v.hi), R(b.fmul(R(kf), F(LN2_1)))), .lo = b.mov(.f32, F(0)) };
    r = b.ddAdd(r, .{ .hi = v.lo, .lo = b.mov(.f32, F(0)) });
    const p2 = b.fmul(R(kf), F(LN2_2));
    const e2 = b.prodErr(kf, b.mov(.f32, F(LN2_2)), p2);
    r = b.ddAdd(r, .{ .hi = b.fneg(R(p2)), .lo = b.fneg(R(e2)) });
    r = b.ddAdd(r, .{ .hi = b.fneg(R(b.fmul(R(kf), F(LN2_3)))), .lo = b.mov(.f32, F(0)) });
    // Horner over 1 / i!
    var inv: [EXP_TERMS + 1]f64 = undefined;
    inv[0] = 1;
    for (1..EXP_TERMS + 1) |i| inv[i] = inv[i - 1] / @as(f64, @floatFromInt(i));
    var p = ddConst(b, inv[EXP_TERMS]);
    var i: usize = EXP_TERMS;
    while (i > 0) {
        i -= 1;
        p = b.ddAdd(ddMul(b, p, r), ddConst(b, inv[i]));
    }
    // times 2^k (k >= -127 here: exact)
    const scale = b.as(.f32, b.op2(.shl, .i32, R(b.iaddS(R(k), I(127))), U(23)));
    return .{ .hi = b.fmul(R(p.hi), R(scale)), .lo = b.fmul(R(p.lo), R(scale)) };
}

// ── conv0: the mel image's full 3x3 convolution ─────────────────────────────

/// Bindings of conv0: mel (f32 [columns][bins], the chunk's frames), left
/// (f32 [bins], the column before them), weights (the model: the kernels
/// f32 [c][3][3] and the bias f32 [c]), out (f32 [out columns][bins / 2][c]).
pub const Conv0Binding = enum(u8) { mel, left, weights, out };

/// conv0's params: bins, the chunk's columns, the kernels' and the bias's
/// byte offsets, c, mel's, left's and out's byte offsets.
pub fn conv0Params(bins: u32, columns: u32, kernels_off: u32, bias_off: u32, c: u32, mel_off: u32, left_off: u32, out_off: u32) [8]u32 {
    return .{ bins, columns, kernels_off, bias_off, c, mel_off, left_off, out_off };
}

pub fn conv0Groups(c: u32, bins: u32, out_columns: u32) [3]u32 {
    return .{ (c + 63) / 64, bins / 2, out_columns };
}

/// The encoder's Conv0Task: output (t, oh, channel) = SiLU(the nine taps
/// over columns 2t .. 2t + 2 (column 0 the left one, past the chunk zero)
/// and bins 2 oh - 1 .. 2 oh + 1 (zero padded), each patch value and kernel
/// rounded to f16, the products summed exactly and rounded once, + bias).
/// A thread a channel. Groups: conv0Groups.
pub fn conv0(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3h_conv0", 64);
    var b = Builder.init(&k, caps);
    const MEL = k.binding();
    const LEFT = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 8;
    const ch = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    const oh = b.gid(1);
    const t = b.gid(2);
    const bins = b.param(0);
    const columns = b.param(1);
    const c = b.param(4);
    b.if_(b.icmp(.u32, .lt, R(ch), R(c)));
    var patch: [9]V = undefined;
    for (0..3) |kh| {
        // bin 2 oh + kh - 1 (below 0 wraps, out of range)
        const bin = b.sub(R(b.add(R(b.shl(R(oh), 1)), U(@intCast(kh)))), U(1));
        const bin_ok = b.icmp(.u32, .lt, R(bin), R(bins));
        const binc = b.sel(.u32, bin_ok, R(bin), U(0));
        const bin4 = b.shl(R(binc), 2);
        for (0..3) |kw| {
            const col = b.add(R(b.shl(R(t), 1)), U(@intCast(kw)));
            const from_left = b.icmp(.u32, .eq, R(col), U(0));
            const in_chunk = b.pand(b.op1(.pnot, .pred, R(from_left)), b.icmp(.u32, .le, R(col), R(columns)));
            const row = b.sel(.u32, in_chunk, R(b.sub(R(col), U(1))), U(0));
            const vm = b.ld(MEL, .f32, R(b.add(R(b.param(5)), R(b.add(R(b.shl(R(b.mul(R(row), R(bins))), 2)), R(bin4))))), 0, 5);
            const vl = b.ld(LEFT, .f32, R(b.add(R(b.param(6)), R(bin4))), 0, 5);
            const v = b.sel(.f32, from_left, R(vl), R(b.sel(.f32, in_chunk, R(vm), F(0))));
            patch[kh * 3 + kw] = b.f16r(b.sel(.f32, bin_ok, R(v), F(0)));
        }
    }
    const wbase = b.add(R(b.param(2)), R(b.mul(R(ch), U(36))));
    var acc: Sum3 = .{ .h = b.mov(.f32, F(0)), .m = b.mov(.f32, F(0)), .l = b.mov(.f32, F(0)) };
    for (0..9) |tap| {
        const w = b.f16r(b.ld(WB, .f32, R(wbase), @intCast(4 * tap), 5));
        acc = sum3Add(&b, acc, b.fmul(R(w), R(patch[tap])));
    }
    const product = sum3Round(&b, acc);
    const bias = b.ld(WB, .f32, R(b.add(R(b.param(3)), R(b.shl(R(ch), 2)))), 0, 5);
    const y = silu(&b, b.fadd(R(product), R(bias)));
    const cell = b.add(R(b.mul(R(t), R(b.shr(R(bins), 1)))), R(oh));
    b.st(OUT, R(b.add(R(b.param(7)), R(b.shl(R(b.add(R(b.mul(R(cell), R(c))), R(ch))), 2)))), 0, 5, y);
    b.endif();
    try k.finish();
    return k;
}

// ── dwpw: a depthwise + pointwise downsampling stage ────────────────────────

/// Bindings of dwpw: x (f32 [columns][bins][c], the stage's input), left
/// (f32 [bins][c], the column before it), weights (the model), out.
pub const DwpwBinding = enum(u8) { x, left, weights, out };

/// dwpw's params.
pub const DwpwParams = struct {
    /// The input's bins (the output has half) and columns.
    bins: u32,
    columns: u32,
    c: u32,
    /// Byte offsets in the model: the depthwise kernels (f32 [c][3][3]) and
    /// bias, the pointwise matrix (f32 [c][c], out-channel rows) and bias.
    dw: u32,
    dw_bias: u32,
    pw: u32,
    pw_bias: u32,
    /// Byte offsets of x's first column, of left, of out's first value.
    x: u32 = 0,
    left: u32 = 0,
    out: u32 = 0,
    /// out's byte strides: per output column, per output bin, per channel
    /// ([t][bin][c] or the features' [t][c][bin]).
    out_column: u32,
    out_bin: u32,
    out_channel: u32,

    pub fn words(p: DwpwParams) [13]u32 {
        return .{ p.bins, p.columns, p.c, p.dw, p.dw_bias, p.pw, p.pw_bias, p.x, p.left, p.out, p.out_column, p.out_bin, p.out_channel };
    }
};

pub fn dwpwGroups(bins: u32, columns: u32) [3]u32 {
    return .{ bins / 2, (columns + 1) / 2, 1 };
}

/// The encoder's downsample stage for one output cell (t, oh) a workgroup,
/// a thread a channel (c threads): the depthwise 3x3 stride-2 tap sum (f32,
/// kh then kw, padding skipped) + bias into shared memory; then output
/// channel `thread` as PointwiseTask: eight fused lanes over the inputs,
/// reduced in lane order, + bias, SiLU. Groups: dwpwGroups.
pub fn dwpw(s: kir.Storage, caps: Caps, c: u32) Error!kir.Kernel {
    if (c == 0 or c % 8 != 0 or c > caps.max_group or c > 1024 or c * 4 > caps.shared_bytes) return error.Unsupported;
    var k = begin(s, "lfm3h_dwpw", c);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const LEFT = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 13;
    const xs = k.shared_bytes;
    k.shared_bytes += c * 4;
    const ch = b.tid(0);
    const oh = b.gid(0);
    const t = b.gid(1);
    const bins = b.param(0);
    const columns = b.param(1);
    const cw = b.param(2);
    const ch4 = b.shl(R(ch), 2);
    const col_bytes = b.shl(R(b.mul(R(bins), R(cw))), 2);
    const sum = b.mov(.f32, F(0));
    const wbase = b.add(R(b.param(3)), R(b.mul(R(ch), U(36))));
    for (0..3) |kh| {
        const bin = b.sub(R(b.add(R(b.shl(R(oh), 1)), U(@intCast(kh)))), U(1));
        const bin_ok = b.icmp(.u32, .lt, R(bin), R(bins));
        const binc = b.sel(.u32, bin_ok, R(bin), U(0));
        const in_col = b.add(R(b.shl(R(b.mul(R(binc), R(cw))), 2)), R(ch4));
        for (0..3) |kw| {
            const col = b.add(R(b.shl(R(t), 1)), U(@intCast(kw)));
            const from_left = b.icmp(.u32, .eq, R(col), U(0));
            const in_chunk = b.pand(b.op1(.pnot, .pred, R(from_left)), b.icmp(.u32, .le, R(col), R(columns)));
            const row = b.sel(.u32, in_chunk, R(b.sub(R(col), U(1))), U(0));
            const vx = b.ld(X, .f32, R(b.add(R(b.param(7)), R(b.add(R(b.mul(R(row), R(col_bytes))), R(in_col))))), 0, 5);
            const vl = b.ld(LEFT, .f32, R(b.add(R(b.param(8)), R(in_col))), 0, 5);
            const v = b.sel(.f32, from_left, R(vl), R(vx));
            // (a tap outside the image is skipped, as the CPU's `continue`)
            const use = b.pand(bin_ok, b.op2(.por, .pred, R(from_left), R(in_chunk)));
            const w = b.ld(WB, .f32, R(wbase), @intCast(4 * (kh * 3 + kw)), 5);
            b.set(sum, .sel, .f32, R(b.fadd(R(sum), R(b.fmul(R(w), R(v))))), R(sum), R(use));
        }
    }
    const xv = b.fadd(R(sum), R(b.ld(WB, .f32, R(b.add(R(b.param(4)), R(ch4))), 0, 5)));
    b.sts(R(ch4), xs, xv, 1);
    b.barrier();
    // pointwise: output channel `ch`, lanes j over inputs 8i + j
    var lanes: [8]V = undefined;
    for (&lanes) |*l| l.* = b.mov(.f32, F(0));
    const wrow = b.add(R(b.param(5)), R(b.mul(R(ch), R(b.shl(R(cw), 2)))));
    const groups8 = b.shr(R(cw), 3);
    const i = b.mov(.u32, U(0));
    b.loop();
    {
        const off = b.shl(R(i), 5);
        const x0 = b.lds(.f32, R(off), xs, 4);
        const x1 = b.lds(.f32, R(off), xs + 16, 4);
        const wo = b.add(R(wrow), R(off));
        const w0 = b.ldv(WB, .f32, R(wo), 0, 4);
        const w1 = b.ldv(WB, .f32, R(wo), 16, 4);
        for (0..8) |j| {
            const wj = vecAt(if (j < 4) w0 else w1, j % 4);
            const xj = vecAt(if (j < 4) x0 else x1, j % 4);
            b.set(lanes[j], .mov, .f32, R(b.fma(R(wj), R(xj), R(lanes[j]))), NO, NO);
        }
        b.set(i, .iadd, .u32, R(i), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(i), R(groups8)));
    }
    b.endloop();
    var total = lanes[0];
    for (1..8) |j| total = b.fadd(R(total), R(lanes[j]));
    const y = silu(&b, b.fadd(R(total), R(b.ld(WB, .f32, R(b.add(R(b.param(6)), R(ch4))), 0, 5))));
    const o = b.add(R(b.param(9)), R(b.add(R(b.mul(R(t), R(b.param(10)))), R(b.add(R(b.mul(R(oh), R(b.param(11)))), R(b.mul(R(ch), R(b.param(12)))))))));
    b.st(OUT, R(o), 0, 5, y);
    try k.finish();
    return k;
}

// ── Per-head RMSNorm and RoPE, any even head size ───────────────────────────

/// Bindings of headNormRope: x (f32: token t's heads at x + t * stride,
/// normed and rotated in place), weight (the model: f32 [head]), rope (f32
/// [T][head / 2][2]: cos, sin, lfm3_kir.ropeTable's).
pub const HeadBinding = enum(u8) { x, weights, rope };

/// headNormRope's params: heads, epsilon's bits, x's byte offset, the
/// weights' byte offset, the bytes from one token's heads to the next's.
pub fn headParams(heads: u32, epsilon: f32, x_off: u32, weight_off: u32, stride: u32) [5]u32 {
    return .{ heads, @bitCast(epsilon), x_off, weight_off, stride };
}

/// The encoder's PrepareTask for one (head, token) a workgroup: RMSNorm of
/// the head (f32 squares, their sum as the CPU's f64), then NeoX RoPE by
/// the host's table; thread j holds elements j and j + head / 2 (the
/// threads a power of two, those past head / 2 idle). Groups (heads, T).
pub fn headNormRope(s: kir.Storage, caps: Caps, head_size: u32) Error!kir.Kernel {
    if (head_size < 2 or head_size % 2 != 0 or head_size > 2048) return error.Unsupported;
    const half = head_size / 2;
    const threads = std.math.ceilPowerOfTwo(u32, half) catch return error.Unsupported;
    if (threads > caps.max_group) return error.Unsupported;
    var k = begin(s, "lfm3h_head", threads);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const WB = k.binding();
    const ROPE = k.binding();
    k.param_words = 5;
    b.needExchange(threads);
    const t = b.tid(0);
    const h = b.gid(0);
    const tok = b.gid(1);
    const on = b.icmp(.u32, .lt, R(t), U(half));
    const tc = b.sel(.u32, on, R(t), U(0));
    const t4 = b.shl(R(tc), 2);
    const row = b.add(R(b.add(R(b.param(2)), R(b.mul(R(tok), R(b.param(4)))))), R(b.mul(R(h), U(head_size * 4))));
    const lo = b.ld(X, .f32, R(b.add(R(row), R(t4))), 0, 5);
    const hi = b.ld(X, .f32, R(b.add(R(row), R(t4))), half * 4, 5);
    const zero = b.mov(.f32, F(0));
    const sq = b.ddAdd(
        .{ .hi = b.sel(.f32, on, R(b.fmul(R(lo), R(lo))), F(0)), .lo = zero },
        .{ .hi = b.sel(.f32, on, R(b.fmul(R(hi), R(hi))), F(0)), .lo = zero },
    );
    const inverse = b.normInverse(b.xorReduceDD(sq, threads, t), F(@floatFromInt(head_size)), R(b.as(.f32, b.param(1))));
    const wo = b.add(R(b.param(3)), R(t4));
    const a = b.fmul(R(b.fmul(R(lo), R(inverse))), R(b.ld(WB, .f32, R(wo), 0, 5)));
    const c = b.fmul(R(b.fmul(R(hi), R(inverse))), R(b.ld(WB, .f32, R(wo), half * 4, 5)));
    const cs = b.ldv(ROPE, .f32, R(b.shl(R(b.add(R(b.mul(R(tok), U(half))), R(tc))), 3)), 0, 2);
    const cosv = vecAt(cs, 0);
    const sinv = vecAt(cs, 1);
    b.if_(on);
    b.st(X, R(b.add(R(row), R(t4))), 0, 5, b.fsub(R(b.fmul(R(a), R(cosv))), R(b.fmul(R(c), R(sinv)))));
    b.st(X, R(b.add(R(row), R(t4))), half * 4, 5, b.fadd(R(b.fmul(R(a), R(sinv))), R(b.fmul(R(c), R(cosv)))));
    b.endif();
    try k.finish();
    return k;
}

// ── The sliding-window attention ────────────────────────────────────────────

/// Bindings of attendWindow: query (f32 [T][heads][head]), kv (rows of
/// [keys | values], the window's `prefix` rows then the chunk's T),
/// out (f32 [T][heads][head]).
pub const AttendBinding = enum(u8) { query, kv, out };

/// attendWindow's params.
pub const AttendParams = struct {
    heads: u32,
    /// log2(heads / kv_heads)
    group_log2: u32,
    /// The stream's position before the chunk (keys before the clip's
    /// start are not visible).
    base: u32,
    /// window - 1: the rows the window carries.
    prefix: u32,
    scale: f32,
    /// Bytes a kv row; the values' byte offset in a row; the layer's first
    /// row (bytes).
    row_bytes: u32,
    values: u32,
    kv: u32,

    pub fn words(p: AttendParams) [8]u32 {
        return .{ p.heads, p.group_log2, p.base, p.prefix, @bitCast(p.scale), p.row_bytes, p.values, p.kv };
    }
};

/// The most keys a query sees (the threads of attendWindow).
pub const MAX_WINDOW = 32;

/// The encoder's AttendTask for one (head, position t) a workgroup, 32
/// threads (thread j key j, then elements j, j + 32, ...): keys
/// max(t, earliest) .. prefix + t of [window | chunk]; each score the f32
/// sum of q * f16(k) lane by lane, times the scale; the maximum; expf; the
/// total in key order as the CPU's f64 (double-f32); weights e * (1 /
/// total); each element the f32 sum of weight * f16(v) in key order.
/// Groups (heads, T). Head sizes a multiple of 32.
pub fn attendWindow(s: kir.Storage, caps: Caps, head_size: u32) Error!kir.Kernel {
    if (head_size == 0 or head_size % 32 != 0 or head_size > 512) return error.Unsupported;
    var k = begin(s, "lfm3h_attend", MAX_WINDOW);
    var b = Builder.init(&k, caps);
    const Q = k.binding();
    const KV = k.binding();
    const OUT = k.binding();
    k.param_words = 8;
    const ebase = k.shared_bytes;
    k.shared_bytes += MAX_WINDOW * 4;
    const wbase = k.shared_bytes;
    k.shared_bytes += MAX_WINDOW * 4;
    b.needExchange(MAX_WINDOW);
    const t = b.tid(0);
    const h = b.gid(0);
    const pos = b.gid(1);
    const heads = b.param(0);
    const base = b.param(2);
    const prefix = b.param(3);
    const row_bytes = b.param(5);
    const kv0 = b.param(7);
    const kvh = b.op2(.shr, .u32, R(h), R(b.param(1)));
    const last = b.add(R(prefix), R(pos));
    const earliest = b.sel(.u32, b.icmp(.u32, .lt, R(base), R(prefix)), R(b.sub(R(prefix), R(base))), U(0));
    const first = b.umax(R(pos), R(earliest));
    const n = b.add(R(b.sub(R(last), R(first))), U(1));
    const valid = b.icmp(.u32, .lt, R(t), R(n));
    const key = b.add(R(first), R(b.sel(.u32, valid, R(t), U(0))));
    const head_bytes = head_size * 4;
    const qrow = b.mul(R(b.add(R(b.mul(R(pos), R(heads))), R(h))), U(head_bytes));
    const kvh_off = b.mul(R(kvh), U(head_bytes));
    const krow = b.add(R(b.add(R(kv0), R(b.mul(R(key), R(row_bytes))))), R(kvh_off));
    // the score: q . f16(k), in lane order
    const sum = b.mov(.f32, F(0));
    const qo = b.mov(.u32, R(qrow));
    const ko = b.mov(.u32, R(krow));
    const qend = b.add(R(qrow), U(head_bytes));
    b.loop();
    {
        const qv = b.ldv(Q, .f32, R(qo), 0, 4);
        const kv = b.ldv(KV, .f32, R(ko), 0, 4);
        var acc = sum;
        for (0..4) |j| acc = b.fadd(R(acc), R(b.fmul(R(vecAt(qv, j)), R(b.f16r(vecAt(kv, j))))));
        b.set(sum, .mov, .f32, R(acc), NO, NO);
        b.set(qo, .iadd, .u32, R(qo), U(16), NO);
        b.set(ko, .iadd, .u32, R(ko), U(16), NO);
        b.brk(b.icmp(.u32, .ge, R(qo), R(qend)));
    }
    b.endloop();
    const score = b.fmul(R(sum), R(b.as(.f32, b.param(4))));
    const maximum = b.xorReduce(.fmax, .f32, b.sel(.f32, valid, R(score), F(-std.math.inf(f32))), MAX_WINDOW, t);
    const e = b.sel(.f32, valid, R(b.expCpu(b.fsub(R(score), R(maximum)))), F(0));
    const t4 = b.shl(R(t), 2);
    b.sts(R(t4), ebase, e, 1);
    b.barrier();
    // the total in key order (every thread the same sum)
    const total = b.ddZero();
    const j = b.mov(.u32, U(0));
    b.loop();
    {
        const ej = b.lds(.f32, R(b.shl(R(j), 2)), ebase, 1);
        b.ddAccumulate(total, .{ .hi = ej, .lo = b.mov(.f32, F(0)) });
        b.set(j, .iadd, .u32, R(j), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(j), R(n)));
    }
    b.endloop();
    const inverse = b.ddRecip(total);
    b.sts(R(t4), wbase, b.fmul(R(e), R(inverse)), 1);
    b.barrier();
    // element t + 32 r: the weighted f16 values in key order
    const vrow0 = b.add(R(b.add(R(kv0), R(b.mul(R(first), R(row_bytes))))), R(b.add(R(b.param(6)), R(kvh_off))));
    for (0..head_size / 32) |r| {
        const acc = b.mov(.f32, F(0));
        const kk = b.mov(.u32, U(0));
        const vo = b.add(R(vrow0), R(b.add(R(t4), U(@intCast(r * 128)))));
        const vp = b.mov(.u32, R(vo));
        b.loop();
        {
            const wk = b.lds(.f32, R(b.shl(R(kk), 2)), wbase, 1);
            const v = b.f16r(b.ld(KV, .f32, R(vp), 0, 5));
            b.set(acc, .mov, .f32, R(b.fadd(R(acc), R(b.fmul(R(wk), R(v))))), NO, NO);
            b.set(vp, .iadd, .u32, R(vp), R(row_bytes), NO);
            b.set(kk, .iadd, .u32, R(kk), U(1), NO);
            b.brk(b.icmp(.u32, .ge, R(kk), R(n)));
        }
        b.endloop();
        b.st(OUT, R(b.add(R(qrow), R(b.add(R(t4), U(@intCast(r * 128)))))), 0, 5, acc);
    }
    try k.finish();
    return k;
}

// ── The final norms ─────────────────────────────────────────────────────────

/// Bindings of rmsLayerNorm: x (f32 [T][width]), weights (the model), out.
pub const FinalBinding = enum(u8) { x, weights, out };

/// rmsLayerNorm's params: width, the RMSNorm's epsilon bits, the
/// LayerNorm's, the byte offsets of the RMSNorm's weight, the LayerNorm's
/// weight and bias, of x's first row and of out's.
pub fn finalParams(width: u32, rms_epsilon: f32, ln_epsilon: f32, rms_w: u32, ln_w: u32, ln_b: u32, x_off: u32, out_off: u32) [8]u32 {
    return .{ width, @bitCast(rms_epsilon), @bitCast(ln_epsilon), rms_w, ln_w, ln_b, x_off, out_off };
}

/// The encoder's last step a row: ops.rmsNorm (f32 squares, f64 sum) with
/// the post norm, then ops.layerNorm (f64 sum of the values; centered
/// values; f64 sum of their f32 squares; centered * inverse * weight +
/// bias). A workgroup a row, each thread its own columns in every pass
/// (`out` may be x). Groups (1, T).
pub fn rmsLayerNorm(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    const threads = lk.rowThreads(caps);
    var k = begin(s, "lfm3h_final_norm", threads);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 8;
    b.needExchange(threads);
    const t = b.tid(0);
    const width = b.param(0);
    const nf = b.cvt(.u32, .f32, .rne, R(width));
    const row_bytes = b.shl(R(b.mul(R(b.gid(1)), R(width))), 2);
    const x_base = b.add(R(b.param(6)), R(row_bytes));
    const o_base = b.add(R(b.param(7)), R(row_bytes));
    const chunks = b.shr(R(b.add(R(width), U(threads - 1))), @intCast(std.math.log2_int(u32, threads)));
    const t4 = b.shl(R(t), 2);
    const step = threads * 4;
    const end = b.shl(R(width), 2);
    const c = b.mov(.u32, U(0));

    // RMSNorm's square sum
    const sq = b.ddZero();
    b.loop();
    {
        const col = b.add(R(b.mul(R(c), U(step))), R(t4));
        const ok = b.icmp(.u32, .lt, R(col), R(end));
        const v = b.ld(X, .f32, R(b.add(R(x_base), R(b.sel(.u32, ok, R(col), U(0))))), 0, 5);
        b.ddAccumulate(sq, .{ .hi = b.sel(.f32, ok, R(b.fmul(R(v), R(v))), F(0)), .lo = b.mov(.f32, F(0)) });
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
    }
    b.endloop();
    const inv_rms = b.normInverse(b.xorReduceDD(sq, threads, t), R(nf), R(b.as(.f32, b.param(1))));
    // y = x * inverse * w, written out; the sum of y
    const sy = b.ddZero();
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const col = b.add(R(b.mul(R(c), U(step))), R(t4));
        const ok = b.icmp(.u32, .lt, R(col), R(end));
        const colc = b.sel(.u32, ok, R(col), U(0));
        const v = b.ld(X, .f32, R(b.add(R(x_base), R(colc))), 0, 5);
        const w = b.ld(WB, .f32, R(b.add(R(b.param(3)), R(colc))), 0, 5);
        const y = b.fmul(R(b.fmul(R(v), R(inv_rms))), R(w));
        b.if_(ok);
        b.st(OUT, R(b.add(R(o_base), R(col))), 0, 5, y);
        b.endif();
        b.ddAccumulate(sy, .{ .hi = b.sel(.f32, ok, R(y), F(0)), .lo = b.mov(.f32, F(0)) });
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
    }
    b.endloop();
    const mean = b.ddDiv(b.xorReduceDD(sy, threads, t), R(nf));
    // the centered values' square sum
    const sc = b.ddZero();
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const col = b.add(R(b.mul(R(c), U(step))), R(t4));
        const ok = b.icmp(.u32, .lt, R(col), R(end));
        const y = b.ld(OUT, .f32, R(b.add(R(o_base), R(b.sel(.u32, ok, R(col), U(0))))), 0, 5);
        const centered = b.fsub(R(y), R(mean));
        b.ddAccumulate(sc, .{ .hi = b.sel(.f32, ok, R(b.fmul(R(centered), R(centered))), F(0)), .lo = b.mov(.f32, F(0)) });
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
    }
    b.endloop();
    const inv_ln = b.normInverse(b.xorReduceDD(sc, threads, t), R(nf), R(b.as(.f32, b.param(2))));
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const col = b.add(R(b.mul(R(c), U(step))), R(t4));
        const ok = b.icmp(.u32, .lt, R(col), R(end));
        b.if_(ok);
        const y = b.ld(OUT, .f32, R(b.add(R(o_base), R(col))), 0, 5);
        const centered = b.fsub(R(y), R(mean));
        const w = b.ld(WB, .f32, R(b.add(R(b.param(4)), R(col))), 0, 5);
        const bias = b.ld(WB, .f32, R(b.add(R(b.param(5)), R(col))), 0, 5);
        b.st(OUT, R(b.add(R(o_base), R(col))), 0, 5, b.fadd(R(b.fmul(R(b.fmul(R(centered), R(inv_ln))), R(w))), R(bias)));
        b.endif();
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
    }
    b.endloop();
    try k.finish();
    return k;
}

// ── GELU (erf) ──────────────────────────────────────────────────────────────

/// Past this |x / sqrt 2| the CPU's erf rounds to +-1 in f32 (1 - erf(4.5)
/// is 2e-10, under a quarter of f32's last place below 1).
const ERF_ONE: f32 = 4.5;

/// Bindings of gelu: x (f32, in place). Params: the count, x's byte offset.
/// Groups (count / 64 rounded up).
pub fn geluGroups(count: u32) [3]u32 {
    return .{ (count + 63) / 64, 1, 1 };
}

/// ops.geluErf a value: 0.5 x (1 + e), e the f32 of ops.erf(x * 0.70710677)
/// — its series sum_n 2^n m^(2n+1) / (2n+1)!! (term *= 2 m^2 / (2n + 1),
/// until the term is under 1e-17 of the sum), times 2 / sqrt(pi) e^(-m^2),
/// in double-f32; zero and NaN themselves; past ERF_ONE +-1.
pub fn gelu(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3h_gelu", 64);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    k.param_words = 2;
    const idx = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    b.if_(b.icmp(.u32, .lt, R(idx), R(b.param(0))));
    const off = b.add(R(b.param(1)), R(b.shl(R(idx), 2)));
    const value = b.ld(X, .f32, R(off), 0, 5);
    const scaled = b.fmul(R(value), F(0.70710678118654752440));
    const m = b.fabs(R(scaled));
    // (the series on a value it converges for: NaN and big ones are selected away)
    const ms = b.fmin(R(m), F(ERF_ONE));
    const sq = b.square(ms);
    const two_sq: DD = .{ .hi = b.fmul(R(sq.hi), F(2)), .lo = b.fmul(R(sq.lo), F(2)) };
    const term: DD = .{ .hi = b.mov(.f32, R(ms)), .lo = b.mov(.f32, F(0)) };
    const sum: DD = .{ .hi = b.mov(.f32, R(ms)), .lo = b.mov(.f32, F(0)) };
    const nf = b.mov(.f32, F(0));
    b.loop();
    {
        b.set(nf, .fadd, .f32, R(nf), F(1), NO);
        const den = b.fadd(R(b.fmul(R(nf), F(2))), F(1));
        const next = ddMul(&b, term, ddDivF(&b, two_sq, den));
        const total = b.ddAdd(sum, next);
        b.set(term.hi, .mov, .f32, R(next.hi), NO, NO);
        b.set(term.lo, .mov, .f32, R(next.lo), NO, NO);
        b.set(sum.hi, .mov, .f32, R(total.hi), NO, NO);
        b.set(sum.lo, .mov, .f32, R(total.lo), NO, NO);
        const small = b.fcmp(.le, R(next.hi), R(b.fmul(R(total.hi), F(1e-17))));
        b.brk(b.op2(.por, .pred, R(small), R(b.fcmp(.gt, R(nf), F(200)))));
    }
    b.endloop();
    const ex = ddExpNeg(&b, .{ .hi = b.fneg(R(sq.hi)), .lo = b.fneg(R(sq.lo)) });
    const res = ddMul(&b, ddMul(&b, ddConst(&b, 1.1283791670955125739), ex), sum);
    var e = b.fadd(R(res.hi), R(res.lo));
    e = b.sel(.f32, b.fcmp(.ge, R(m), F(ERF_ONE)), F(1), R(e));
    e = b.sel(.f32, b.fcmp(.lt, R(scaled), F(0)), R(b.fneg(R(e))), R(e));
    // zero and NaN: x itself
    const keep = b.op2(.por, .pred, R(b.fcmp(.eq, R(m), F(0))), R(b.fcmp(.ne, R(m), R(m))));
    e = b.sel(.f32, keep, R(scaled), R(e));
    b.st(X, R(off), 0, 5, b.fmul(R(b.fmul(F(0.5), R(value))), R(b.fadd(F(1.0), R(e)))));
    b.endif();
    try k.finish();
    return k;
}
