//! @zpm/lfm3-kir — LFM3's kernels in KIR, the GPU-neutral kernel IR of the
//! gpu module: written once here, compiled for any GPU by its backend
//! (ir3 on the Surface's Adreno, sm_120 on the Legion's RTX, the reference
//! interpreter in tests). The generalization of lfm3_gpu_kernels.sig (ir3
//! text) and lfm3_nv_matrix.sig + lfm3_nv_ops.sig (sm_120 text).
//!
//! # The kernels
//!
//! | builder              | computes                                              |
//! |----------------------|-------------------------------------------------------|
//! | `matrix(.q4_k, T)`   | out[t][row] = Q4_K row . Q8_K activations t, T = 1..8 |
//! | `matrix(.q6_k, T)`   | out[t][row] = Q6_K row . Q8_K activations t           |
//! | `matrix(.q8_0, T)`   | out[t][row] = Q8_0 row . Q8_0 activations t           |
//! | `quant(.plain)`      | rows of f32 to Q8_K (quantizeQ8K)                     |
//! | `quant(.norm)`       | RMSNorm, the normalized rows out, then Q8_K           |
//! | `quant(.swiglu)`     | silu(gate) * up, then Q8_K (SwiGluQuantizeTask)       |
//! | `q80Quant()`         | rows of f32 to Q8_0 (quantizeQ80)                     |
//! | `residual(postnorm)` | hidden += rmsnorm(block) * w, or += block             |
//! | `conv(taps)`         | LFM3's gated short convolution, its state carried     |
//! | `prepare()`          | per-head RMSNorm, NeoX RoPE, f16 query, f16 KV rows   |
//! | `attnScores(HG, TT)` | q . k * scale for a 64-position chunk of keys         |
//! | `attnSoftmax()`      | a row's maximum, exp, total, f16 weights in place     |
//! | `attnValues(HG, TT)` | f16 weights times f16 values over a chunk             |
//! | `attnCombine()`      | the chunks' partial outputs summed, times the gate    |
//! | `copy()`             | 16-byte words from one buffer to another              |
//!
//! Each builder writes a `kir.Kernel` into caller-owned `kir.Storage` and
//! returns it; `gpu.compile` makes it a Binary for the Device's target. Each
//! kernel's bindings and parameter words are listed with its builder.
//!
//! # Exactness (the CPU's bits)
//!
//! KIR's fadd, fsub, fmul, fdiv and fsqrt are correctly rounded on every
//! backend, and these kernels use nothing else where the CPU's floats are to
//! be met:
//!
//! - The matrices keep quantized_linear's eight lanes per row (lane l holds
//!   elements 4l..4l+3 of every 32), the same integer sums (dot4), the same
//!   float epilogue per block in the CPU's order, and the lanes added in the
//!   CPU's order: Q4_K and Q6_K are the CPU's to the bit under any Caps.
//!   Q8_0's epilogue is the CPU's fused multiply-add: ffma where
//!   Caps.fused_fma, otherwise an exact emulation (Builder.fma): the CPU's
//!   bits either way.
//! - The quantizations (Q8_K, Q8_0) divide exactly (fdiv) and round to
//!   nearest even: the CPU's bits for the same input.
//! - RMSNorm: the CPU sums squares in f64. Here each square is split exactly
//!   (Dekker's product, or ffma) and summed as a double-f32 (hi, lo) pair by
//!   a fixed xor tree, then rounded once: the CPU's mean in all but about one
//!   row in 2^18, and with fsqrt and fdiv exact, its inverse and normalized
//!   values with it. The tree's shape does not depend on the subgroup width
//!   (steps wider than a subgroup go through shared memory), so every GPU
//!   gets the same bits.
//! - The short convolution, RoPE (given the host's tables), the f16
//!   roundings and the residual: exact.
//! - exp (SwiGLU, softmax, the attention gate) is not KIR's approximate
//!   fexp2 but `expCpu`: the CPU's own expf (compiler_rt's, musl's f32
//!   algorithm: f32 multiplies and adds, one division, scalbn) in exact
//!   KIR ops, so the CPU's bits on every GPU. With it attention is the
//!   CPU's: its scores (dotHalf's lanes), maximum, exps, the total (double-
//!   f32 for its f64, rounded once), the f16 weights and the value sums in
//!   position order, bit for bit when a row's span is one value chunk;
//!   longer spans add the chunks' partial sums in order (the only
//!   association the CPU does not have).
//!
//! So a whole forward pass gives the CPU executor's logits to the bit
//! (tests/test_lfm3_any.sig), but for the rare rows (about one in 2^18)
//! where the double-f32 square sum and the CPU's f64 one round apart, and
//! for attention spans over VALUE_CHUNK positions.
//!
//! # Long context
//!
//! Attention is split by keys (flash-decoding): attnScores writes each
//! row's scores (a row is one query head at one token) into a scratch
//! buffer, attnSoftmax turns them into the CPU's f16 weights, attnValues
//! sums weights times values over chunks of `CV` positions into partial
//! outputs, and attnCombine adds the partials in order and gates them. Any
//! span the scratch holds runs on the GPU (lfm3_any sizes it: 8192 by
//! default). Workgroups take `HG` query heads of one KV head and `TT`
//! tokens (the tiled prefill path: each key and value row is read once for
//! HG * TT rows).
//!
//! Allocation-free: kernels are built into the caller's Storage.

const std = @import("std");
const gpu = @import("gpu");

pub const kir = gpu.kir;
pub const Caps = gpu.Caps;

const V = kir.V;
const Arg = kir.Arg;
const Ty = kir.Ty;
const Op = kir.Op;

pub const QK_K = 256;
pub const Q4_K_BLOCK = 144;
pub const Q6_K_BLOCK = 210;
pub const QK8_0 = 32;
pub const Q8_0_BLOCK = 34;
/// Tokens one matrix pass multiplies (variants 1..MAX_TOKENS).
pub const MAX_TOKENS = 8;
pub const HEAD_SIZE = 128;
/// Positions one attnScores workgroup scores (one a thread).
pub const SCORE_CHUNK = 64;
/// Positions one attnValues workgroup sums.
pub const VALUE_CHUNK = 256;
/// Rows (heads x tokens) one attention workgroup takes at most.
pub const MAX_ROWS = 8;
/// Threads of the row kernels (norms, quantization, residual).
pub const ROW_THREADS = 256;

pub const Error = kir.Error || error{
    /// A shape the kernels do not build (more tokens than MAX_TOKENS, too
    /// many attention rows, conv taps out of range, a group too small).
    Unsupported,
};

pub const Format = enum { q4_k, q6_k, q8_0 };

/// How a matrix kernel maps the CPU's eight lanes of a row onto threads:
/// `lanes` a thread (1: eight threads a row, as the Adreno hand kernel; 4:
/// two a row with 128-bit loads, as the sm_120 one).
pub const Layout = struct {
    lanes: u32,
    threads: u32 = 64,

    pub fn of(caps: Caps) Layout {
        if (caps.target == .ir3_a7xx) return .{ .lanes = 1 };
        return .{ .lanes = 4 };
    }

    pub fn threadsPerRow(l: Layout) u32 {
        return 8 / l.lanes;
    }

    pub fn rowsPerGroup(l: Layout) u32 {
        return l.threads / l.threadsPerRow();
    }
};

// ── The builder ─────────────────────────────────────────────────────────────

pub fn R(v: V) Arg {
    return .{ .reg = v };
}
pub fn U(x: u32) Arg {
    return .{ .imm = x };
}
pub fn F(x: f32) Arg {
    return .{ .imm = @bitCast(x) };
}
pub fn I(x: i32) Arg {
    return .{ .imm = @bitCast(x) };
}
pub const NO: Arg = kir.no;

/// The `i`th register of a vector `v` (Kernel.vec).
pub fn at(v: V, i: usize) V {
    return @enumFromInt(@intFromEnum(v) + @as(u16, @intCast(i)));
}

fn isInt(t: Ty) bool {
    return t == .u32 or t == .i32;
}

pub fn log2(x: u32) u5 {
    return @intCast(std.math.log2_int(u32, x));
}

/// A double-f32: hi + lo, |lo| <= ulp(hi) / 2.
pub const DD = struct { hi: V, lo: V };

/// Kernel text the way these kernels write it: SSA values (a fresh register
/// each), `set` for what a loop carries. Public, with R, U, F, I, NO, at,
/// begin and expGgml: other kernel files (lfm3_kir_codec) build with it.
pub const Builder = struct {
    k: *kir.Kernel,
    caps: Caps,
    /// Threads of the workgroup (x).
    threads: u32,
    /// Shared bytes from which the xor exchange keeps a word a thread (two
    /// for double-f32 steps); none when every step fits a subgroup.
    xchg: ?u32 = null,

    pub fn init(k: *kir.Kernel, caps: Caps) Builder {
        return .{ .k = k, .caps = caps, .threads = k.group[0] };
    }

    /// Reserve the xor exchange's shared memory (when `span` threads exceed
    /// a subgroup).
    pub fn needExchange(b: *Builder, span: u32) void {
        if (span <= b.caps.subgroup or b.xchg != null) return;
        b.xchg = b.k.shared_bytes;
        b.k.shared_bytes += b.threads * 8;
    }

    pub fn reg(b: *Builder, ty: Ty) V {
        return b.k.reg(ty);
    }

    pub fn emit(b: *Builder, op: Op, ty: Ty, dst: V, a: Arg, x: Arg, c: Arg, aux: u32) void {
        b.k.emit(.{ .op = op, .ty = ty, .dst = dst, .a = a, .b = x, .c = c, .aux = aux });
    }

    pub fn op1(b: *Builder, op: Op, ty: Ty, a: Arg) V {
        const d = b.reg(ty);
        b.emit(op, ty, d, a, NO, NO, 0);
        return d;
    }
    pub fn op2(b: *Builder, op: Op, ty: Ty, a: Arg, x: Arg) V {
        const d = b.reg(ty);
        b.emit(op, ty, d, a, x, NO, 0);
        return d;
    }
    pub fn op3(b: *Builder, op: Op, ty: Ty, a: Arg, x: Arg, c: Arg) V {
        const d = b.reg(ty);
        b.emit(op, ty, d, a, x, c, 0);
        return d;
    }
    /// dst = op(a, x, c), dst an existing register (what a loop carries).
    pub fn set(b: *Builder, dst: V, op: Op, ty: Ty, a: Arg, x: Arg, c: Arg) void {
        b.emit(op, ty, dst, a, x, c, 0);
    }

    pub fn mov(b: *Builder, ty: Ty, a: Arg) V {
        return b.op1(.mov, ty, a);
    }
    /// The same 32 bits as another type.
    pub fn as(b: *Builder, ty: Ty, v: V) V {
        const have = b.k.tys[@intFromEnum(v)];
        if (have == ty or (isInt(have) and isInt(ty))) return v;
        return b.op1(.mov, ty, R(v));
    }

    // integers (u32 unless named)
    pub fn add(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.iadd, .u32, a, x);
    }
    pub fn sub(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.isub, .u32, a, x);
    }
    pub fn mul(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.imul, .u32, a, x);
    }
    pub fn shl(b: *Builder, a: Arg, n: u32) V {
        if (n == 0) return b.mov(.u32, a);
        return b.op2(.shl, .u32, a, U(n));
    }
    pub fn shr(b: *Builder, a: Arg, n: u32) V {
        return b.op2(.shr, .u32, a, U(n));
    }
    pub fn band(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.@"and", .u32, a, x);
    }
    pub fn bor(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.@"or", .u32, a, x);
    }
    pub fn umin(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.imin, .u32, a, x);
    }
    pub fn umax(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.imax, .u32, a, x);
    }
    pub fn bfeU(b: *Builder, a: Arg, off: Arg, len: u32) V {
        return b.op3(.bfe, .u32, a, off, U(len));
    }
    pub fn bfeS(b: *Builder, a: Arg, off: Arg, len: u32) V {
        return b.op3(.bfe, .i32, a, off, U(len));
    }
    pub fn iaddS(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.iadd, .i32, a, x);
    }
    pub fn imulS(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.imul, .i32, a, x);
    }
    pub fn imadS(b: *Builder, a: Arg, x: Arg, c: Arg) V {
        return b.op3(.imad, .i32, a, x, c);
    }
    pub fn dot4(b: *Builder, kind: kir.Dot4, a: Arg, x: Arg, c: Arg) V {
        const d = b.reg(.i32);
        b.emit(.dot4, .i32, d, a, x, c, @intFromEnum(kind));
        return d;
    }

    // predicates
    pub fn icmp(b: *Builder, ty: Ty, c: kir.Cmp, a: Arg, x: Arg) V {
        const d = b.reg(.pred);
        b.emit(.icmp, ty, d, a, x, NO, @intFromEnum(c));
        return d;
    }
    pub fn fcmp(b: *Builder, c: kir.Cmp, a: Arg, x: Arg) V {
        const d = b.reg(.pred);
        b.emit(.fcmp, .f32, d, a, x, NO, @intFromEnum(c));
        return d;
    }
    pub fn pand(b: *Builder, a: V, x: V) V {
        return b.op2(.pand, .pred, R(a), R(x));
    }
    /// p ? a : x
    pub fn sel(b: *Builder, ty: Ty, p: V, a: Arg, x: Arg) V {
        return b.op3(.sel, ty, a, x, R(p));
    }

    // f32
    pub fn fadd(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.fadd, .f32, a, x);
    }
    pub fn fsub(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.fsub, .f32, a, x);
    }
    pub fn fmul(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.fmul, .f32, a, x);
    }
    pub fn fdiv(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.fdiv, .f32, a, x);
    }
    pub fn fsqrt(b: *Builder, a: Arg) V {
        return b.op1(.fsqrt, .f32, a);
    }
    pub fn fmax(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.fmax, .f32, a, x);
    }
    pub fn fmin(b: *Builder, a: Arg, x: Arg) V {
        return b.op2(.fmin, .f32, a, x);
    }
    pub fn fabs(b: *Builder, a: Arg) V {
        return b.op1(.fabs, .f32, a);
    }
    pub fn fneg(b: *Builder, a: Arg) V {
        return b.op1(.fneg, .f32, a);
    }
    pub fn frne(b: *Builder, a: Arg) V {
        return b.op1(.frne, .f32, a);
    }
    pub fn cvt(b: *Builder, from: Ty, to: Ty, round: kir.Round, a: Arg) V {
        const d = b.reg(to);
        b.emit(.cvt, to, d, a, NO, NO, @bitCast(kir.Cvt{ .from = from, .to = to, .round = round }));
        return d;
    }
    /// An integer (|x| < 2^24) as f32.
    pub fn i2f(b: *Builder, a: V) V {
        return b.cvt(.i32, .f32, .rne, R(a));
    }

    // halves
    /// The f16 in the low (hi = false) or high half of `word`, as f32.
    pub fn half(b: *Builder, word: V, hi: bool) V {
        const bits = if (hi) b.shr(R(word), 16) else b.band(R(word), U(0xffff));
        return b.cvt(.f16, .f32, .rne, R(b.as(.f16, bits)));
    }
    /// x rounded to f16 (nearest even), its 16 bits in a u32.
    pub fn halfBits(b: *Builder, x: V) V {
        const h = b.cvt(.f32, .f16, .rne, R(x));
        return b.band(R(b.as(.u32, h)), U(0xffff));
    }
    /// x rounded through f16 and back.
    pub fn f16r(b: *Builder, x: V) V {
        const h = b.cvt(.f32, .f16, .rne, R(x));
        return b.cvt(.f16, .f32, .rne, R(h));
    }

    // ids and parameters
    pub fn tid(b: *Builder, axis: u32) V {
        const d = b.reg(.u32);
        b.emit(.tid, .u32, d, NO, NO, NO, axis);
        return d;
    }
    pub fn gid(b: *Builder, axis: u32) V {
        const d = b.reg(.u32);
        b.emit(.gid, .u32, d, NO, NO, NO, axis);
        return d;
    }
    pub fn param(b: *Builder, word: u32) V {
        const d = b.reg(.u32);
        b.emit(.param, .u32, d, NO, NO, NO, word);
        return d;
    }

    // memory
    pub fn mem(binding: u8, space: kir.Space, width_log2: u3, signed: bool, imm: u32) u32 {
        return @bitCast(kir.Mem{ .binding = binding, .space = space, .width_log2 = width_log2, .signed = signed, .imm = @intCast(imm) });
    }
    /// One 8, 16 or 32-bit load (zero-extended unless `ty` is i32).
    pub fn ld(b: *Builder, binding: u8, ty: Ty, addr: Arg, imm: u32, width_log2: u3) V {
        const d = b.reg(ty);
        b.emit(.ld, ty, d, addr, NO, NO, mem(binding, .global, width_log2, ty == .i32 and width_log2 < 5, imm));
        return d;
    }
    /// `n` consecutive 32-bit words (n = 1, 2 or 4) from one load.
    pub fn ldv(b: *Builder, binding: u8, ty: Ty, addr: Arg, imm: u32, n: u32) V {
        if (n == 1) return b.ld(binding, ty, addr, imm, 5);
        const d = b.k.vec(ty, @intCast(n));
        b.emit(.ld, ty, d, addr, NO, NO, mem(binding, .global, @intCast(5 + @as(u32, log2(n))), false, imm));
        return d;
    }
    pub fn st(b: *Builder, binding: u8, addr: Arg, imm: u32, width_log2: u3, src: V) void {
        b.emit(.st, b.k.tys[@intFromEnum(src)], .none, addr, R(src), NO, mem(binding, .global, width_log2, false, imm));
    }
    pub fn lds(b: *Builder, ty: Ty, addr: Arg, imm: u32, n: u32) V {
        const d = if (n == 1) b.reg(ty) else b.k.vec(ty, @intCast(n));
        b.emit(.ld, ty, d, addr, NO, NO, mem(0, .shared, @intCast(5 + @as(u32, log2(n))), false, imm));
        return d;
    }
    pub fn sts(b: *Builder, addr: Arg, imm: u32, src: V, n: u32) void {
        b.emit(.st, b.k.tys[@intFromEnum(src)], .none, addr, R(src), NO, mem(0, .shared, @intCast(5 + @as(u32, log2(n))), false, imm));
    }
    pub fn barrier(b: *Builder) void {
        b.emit(.barrier, .u32, .none, NO, NO, NO, 0);
    }
    pub fn shfl(b: *Builder, mode: kir.Shfl, v: V, lane_arg: Arg) V {
        const ty = b.k.tys[@intFromEnum(v)];
        const d = b.reg(ty);
        b.emit(.shfl, ty, d, R(v), lane_arg, NO, @intFromEnum(mode));
        return d;
    }

    // structured control flow
    pub fn if_(b: *Builder, p: V) void {
        b.emit(.@"if", .pred, .none, R(p), NO, NO, 0);
    }
    pub fn else_(b: *Builder) void {
        b.emit(.@"else", .pred, .none, NO, NO, NO, 0);
    }
    pub fn endif(b: *Builder) void {
        b.emit(.endif, .pred, .none, NO, NO, NO, 0);
    }
    pub fn loop(b: *Builder) void {
        b.emit(.loop, .pred, .none, NO, NO, NO, 0);
    }
    pub fn brk(b: *Builder, p: V) void {
        b.emit(.brk, .pred, .none, R(p), NO, NO, 0);
    }
    pub fn endloop(b: *Builder) void {
        b.emit(.endloop, .pred, .none, NO, NO, NO, 0);
    }

    // ── reductions ──

    /// v from the thread `m` apart (tid ^ m) in the workgroup: a shuffle
    /// within a subgroup, else through shared memory. Uniform control flow
    /// only (it may hold a barrier).
    pub fn xorPartner(b: *Builder, v: V, m: u32, t: V) V {
        if (m < b.caps.subgroup) return b.shfl(.xor, v, U(m));
        const base = b.xchg.?;
        const ty = b.k.tys[@intFromEnum(v)];
        const mine = b.shl(R(t), 2);
        const theirs = b.shl(R(b.op2(.xor, .u32, R(t), U(m))), 2);
        b.sts(R(mine), base, v, 1);
        b.barrier();
        const r = b.lds(ty, R(theirs), base, 1);
        b.barrier();
        return r;
    }

    /// v combined over each aligned group of `span` threads by a butterfly
    /// (masks 1, 2, .. span / 2): the same value in every thread when `op`
    /// is commutative.
    pub fn xorReduce(b: *Builder, op: Op, ty: Ty, v: V, span: u32, t: V) V {
        var acc = v;
        var m: u32 = 1;
        while (m < span) : (m *= 2) acc = b.op2(op, ty, R(acc), R(b.xorPartner(acc, m, t)));
        return acc;
    }

    pub fn xorReduceDD(b: *Builder, v: DD, span: u32, t: V) DD {
        var acc = v;
        var m: u32 = 1;
        while (m < span) : (m *= 2) acc = b.ddAdd(acc, .{ .hi = b.xorPartner(acc.hi, m, t), .lo = b.xorPartner(acc.lo, m, t) });
        return acc;
    }

    // ── exact arithmetic helpers ──

    /// x * x as an exact double-f32 (no overflow: |x| < 2^60).
    pub fn square(b: *Builder, x: V) DD {
        const p = b.fmul(R(x), R(x));
        if (b.caps.fused_fma) {
            const e = b.op3(.ffma, .f32, R(x), R(x), R(b.fneg(R(p))));
            return .{ .hi = p, .lo = e };
        }
        // Veltkamp's split (2^12 + 1), then Dekker's exact error
        const c = b.fmul(F(4097.0), R(x));
        const xh = b.fsub(R(c), R(b.fsub(R(c), R(x))));
        const xl = b.fsub(R(x), R(xh));
        const t1 = b.fsub(R(b.fmul(R(xh), R(xh))), R(p));
        const t2 = b.fmul(R(b.fmul(R(xh), R(xl))), F(2.0));
        const e = b.fadd(R(b.fadd(R(t1), R(t2))), R(b.fmul(R(xl), R(xl))));
        return .{ .hi = p, .lo = e };
    }

    /// a * c's rounding error, exactly (a * c = p + e).
    pub fn prodErr(b: *Builder, a: V, c: V, p: V) V {
        if (b.caps.fused_fma) return b.op3(.ffma, .f32, R(a), R(c), R(b.fneg(R(p))));
        const ca = b.fmul(F(4097.0), R(a));
        const ah = b.fsub(R(ca), R(b.fsub(R(ca), R(a))));
        const al = b.fsub(R(a), R(ah));
        const cc = b.fmul(F(4097.0), R(c));
        const ch = b.fsub(R(cc), R(b.fsub(R(cc), R(c))));
        const cl = b.fsub(R(c), R(ch));
        const t1 = b.fsub(R(b.fmul(R(ah), R(ch))), R(p));
        const t2 = b.fadd(R(t1), R(b.fmul(R(ah), R(cl))));
        const t3 = b.fadd(R(t2), R(b.fmul(R(al), R(ch))));
        return b.fadd(R(t3), R(b.fmul(R(al), R(cl))));
    }

    pub fn toReg(b: *Builder, a: Arg) V {
        return switch (a) {
            .reg => |v| v,
            .imm => b.mov(.f32, a),
        };
    }

    /// a * x + c rounded once, as the CPU's @mulAdd: ffma where the GPU
    /// fuses; elsewhere emulated exactly from correctly rounded multiplies
    /// and adds (Boldo and Melquiond's: the product split exactly (Dekker),
    /// c + its high part by TwoSum, the two low parts added with rounding
    /// to odd, then one rounding to nearest). Exact but for overflow and
    /// underflow; about 35 operations.
    pub fn fma(b: *Builder, a: Arg, x: Arg, c: Arg) V {
        if (b.caps.fused_fma) return b.op3(.ffma, .f32, a, x, c);
        const av = b.toReg(a);
        const xv = b.toReg(x);
        const cv = b.toReg(c);
        const ph = b.fmul(R(av), R(xv));
        const pl = b.prodErr(av, xv, ph);
        // (th, tl) = TwoSum(c, ph)
        const th = b.fadd(R(cv), R(ph));
        const t1 = b.fsub(R(th), R(cv));
        const tl = b.fadd(R(b.fsub(R(cv), R(b.fsub(R(th), R(t1))))), R(b.fsub(R(ph), R(t1))));
        // v = RO(tl + pl): the nearest sum, moved one ulp toward the exact one
        // when it was inexact and came out even
        const sn = b.fadd(R(tl), R(pl));
        const s1 = b.fsub(R(sn), R(tl));
        const err = b.fadd(R(b.fsub(R(tl), R(b.fsub(R(sn), R(s1))))), R(b.fsub(R(pl), R(s1))));
        const sb = b.as(.u32, sn);
        const even = b.icmp(.u32, .eq, R(b.band(R(sb), U(1))), U(0));
        const inexact = b.fcmp(.ne, R(err), F(0));
        const same = b.icmp(.u32, .eq, R(b.shr(R(b.op2(.xor, .u32, R(b.as(.u32, err)), R(sb))), 31)), U(0));
        const moved = b.sel(.u32, same, R(b.add(R(sb), U(1))), R(b.sub(R(sb), U(1))));
        const v = b.as(.f32, b.sel(.u32, b.pand(even, inexact), R(moved), R(sb)));
        return b.fadd(R(th), R(v));
    }

    /// a + c as a double-f32, symmetric in a and c (the butterfly's
    /// partners get the same bits).
    pub fn ddAdd(b: *Builder, a: DD, c: DD) DD {
        const s = b.fadd(R(a.hi), R(c.hi));
        const bb = b.fsub(R(s), R(a.hi));
        const err = b.fadd(R(b.fsub(R(a.hi), R(b.fsub(R(s), R(bb))))), R(b.fsub(R(c.hi), R(bb))));
        const lo = b.fadd(R(err), R(b.fadd(R(a.lo), R(c.lo))));
        const hi = b.fadd(R(s), R(lo));
        return .{ .hi = hi, .lo = b.fsub(R(lo), R(b.fsub(R(hi), R(s)))) };
    }

    pub fn ddZero(b: *Builder) DD {
        return .{ .hi = b.mov(.f32, F(0)), .lo = b.mov(.f32, F(0)) };
    }

    /// acc += v (loop-carried: acc's registers are written).
    pub fn ddAccumulate(b: *Builder, acc: DD, v: DD) void {
        const r = b.ddAdd(acc, v);
        b.set(acc.hi, .mov, .f32, R(r.hi), NO, NO);
        b.set(acc.lo, .mov, .f32, R(r.lo), NO, NO);
    }

    /// 1 / (hi + lo), correctly rounded but for ties of the pair.
    pub fn ddRecip(b: *Builder, s: DD) V {
        const q = b.fdiv(F(1.0), R(s.hi));
        const p = b.fmul(R(q), R(s.hi));
        const e = b.prodErr(q, s.hi, p);
        // r = 1 - q * (hi + lo): 1 - p is exact (p is within an ulp of 1)
        const r = b.fsub(R(b.fsub(R(b.fsub(F(1.0), R(p))), R(e))), R(b.fmul(R(q), R(s.lo))));
        return b.fadd(R(q), R(b.fmul(R(q), R(r))));
    }

    /// RMSNorm's 1 / sqrt(mean + eps) from the row's square sum, as
    /// lfm3_executor.rmsNormRow (mean = sum / n rounded once).
    pub fn normInverse(b: *Builder, sum: DD, n: Arg, epsilon: Arg) V {
        const mean = b.ddDiv(sum, n);
        return b.fdiv(F(1.0), R(b.fsqrt(R(b.fadd(R(mean), epsilon)))));
    }

    /// (hi + lo) / n rounded once (but for ties of the pair): q = hi / n,
    /// then the remainder hi - q n (exact) + lo divided again.
    pub fn ddDiv(b: *Builder, s: DD, n: Arg) V {
        const nv = switch (n) {
            .reg => |v| v,
            .imm => b.mov(.f32, n),
        };
        const q = b.fdiv(R(s.hi), R(nv));
        const p = b.fmul(R(q), R(nv));
        const e = b.prodErr(q, nv, p);
        const r = b.fadd(R(b.fsub(R(b.fsub(R(s.hi), R(p))), R(e))), R(s.lo));
        return b.fadd(R(q), R(b.fdiv(R(r), R(nv))));
    }

    /// e^x exactly as the CPU's @exp: compiler_rt's expf (musl's f32
    /// expf: k = trunc(x / ln 2 + 1/2), Cody-Waite in two parts, the
    /// rational step with its division, scalbn), in correctly rounded f32
    /// operations only, so the CPU's bits on every GPU. Branch-free: every
    /// path computed, the right one selected.
    pub fn expCpu(b: *Builder, x: V) V {
        const bits = b.as(.u32, x);
        const sign = b.shr(R(bits), 31);
        const hx = b.band(R(bits), U(0x7fffffff));
        const negative = b.icmp(.u32, .ne, R(sign), U(0));
        // |x| > 1.5 ln 2: k = trunc(invln2 * x + (+-1/2)), else +-1
        const big = b.icmp(.u32, .gt, R(hx), U(0x3F851592));
        const halfs = b.sel(.f32, negative, F(-0.5), F(0.5));
        const kb = b.cvt(.f32, .i32, .rz, R(b.fadd(R(b.fmul(F(1.4426950216e+0), R(x))), R(halfs))));
        const ks = b.op2(.isub, .i32, I(1), R(b.shl(R(sign), 1)));
        // |x| > 0.5 ln 2: reduced; else k = 0 and x itself
        const mid = b.icmp(.u32, .gt, R(hx), U(0x3EB17218));
        const k = b.sel(.i32, mid, R(b.sel(.i32, big, R(kb), R(ks))), I(0));
        const fk = b.cvt(.i32, .f32, .rne, R(k));
        const hi = b.sel(.f32, mid, R(b.fsub(R(x), R(b.fmul(R(fk), F(6.9314575195e-1))))), R(x));
        const lo = b.sel(.f32, mid, R(b.fmul(R(fk), F(1.4286067653e-6))), F(0));
        const xr = b.sel(.f32, mid, R(b.fsub(R(hi), R(lo))), R(x));
        // y = 1 + (x c / (2 - c) - lo + hi), c = x - xx (P1 + xx P2)
        const xx = b.fmul(R(xr), R(xr));
        const poly = b.fadd(F(1.6666625440e-1), R(b.fmul(R(xx), F(-2.7667332906e-3))));
        const c = b.fsub(R(xr), R(b.fmul(R(xx), R(poly))));
        const q = b.fdiv(R(b.fmul(R(xr), R(c))), R(b.fsub(F(2.0), R(c))));
        const y = b.fadd(F(1.0), R(b.fadd(R(b.fsub(R(q), R(lo))), R(hi))));
        // scalbn(y, k): y * 2^k in at most two exact steps, the last rounded
        const over = b.icmp(.i32, .gt, R(k), I(127));
        const under = b.icmp(.i32, .lt, R(k), I(-126));
        const first = b.sel(.f32, over, F(0x1.0p127), R(b.sel(.f32, under, F(0x1.0p-102), F(1.0))));
        const k2 = b.op2(.isub, .i32, R(k), R(b.sel(.i32, over, I(127), R(b.sel(.i32, under, I(-102), I(0))))));
        const scale = b.as(.f32, b.op2(.shl, .i32, R(b.iaddS(R(k2), I(127))), U(23)));
        var r = b.fmul(R(b.fmul(R(y), R(first))), R(scale));
        // |x| <= 2^-14: 1 + x
        r = b.sel(.f32, b.icmp(.u32, .gt, R(hx), U(0x39000000)), R(r), R(b.fadd(F(1.0), R(x))));
        // x >= 88.722839: x * 2^127 (inf); x <= -103.972084: 0; NaN: x
        const overflow = b.pand(b.icmp(.u32, .ge, R(hx), U(0x42b17218)), b.op1(.pnot, .pred, R(negative)));
        r = b.sel(.f32, overflow, R(b.fmul(R(x), F(0x1.0p127))), R(r));
        const underflow = b.pand(b.icmp(.u32, .ge, R(hx), U(0x42CFF1B5)), negative);
        r = b.sel(.f32, underflow, F(0), R(r));
        return b.sel(.f32, b.icmp(.u32, .gt, R(hx), U(0x7f800000)), R(x), R(r));
    }

    /// x / (1 + e^-x), as the CPU's silu (exact division).
    pub fn silu(b: *Builder, x: V) V {
        return b.fdiv(R(x), R(b.fadd(F(1.0), R(b.expCpu(b.fneg(R(x)))))));
    }

    /// 1 / (1 + e^-x).
    pub fn sigmoid(b: *Builder, x: V) V {
        return b.fdiv(F(1.0), R(b.fadd(F(1.0), R(b.expCpu(b.fneg(R(x)))))));
    }
};

pub fn begin(s: kir.Storage, name: []const u8, threads: u32) kir.Kernel {
    return kir.Kernel.init(s, name, .{ threads, 1, 1 });
}

// ── Matrices ────────────────────────────────────────────────────────────────

/// The matrix kernels' bindings, in order.
pub const MatrixBinding = enum(u8) { weights, act_q, act_d, act_sums, out };

/// The matrix kernels' parameter words.
pub const MatrixParams = struct {
    /// Bytes from one weight row to the next.
    row_bytes: u32,
    /// Blocks a row (K / 256 for Q8_K activations, K / 32 for Q8_0).
    blocks: u32,
    rows: u32,
    /// Bytes from token t's results to t + 1's.
    out_stride: u32,
    /// Byte offsets in the bindings: the matrix's first row, the first
    /// token's activations (its values, scales, sums), its first result.
    weights: u32 = 0,
    act_q: u32 = 0,
    act_d: u32 = 0,
    act_sums: u32 = 0,
    out: u32 = 0,

    pub const WORDS = 12;

    pub fn words(p: MatrixParams, format: Format) [WORDS]u32 {
        const per_token: u32 = if (format == .q8_0) p.blocks * QK8_0 else p.blocks * QK_K;
        return .{ p.row_bytes, p.blocks, p.rows, p.out_stride, per_token, p.blocks * 4, p.blocks * 32, p.weights, p.act_q, p.act_d, p.act_sums, p.out };
    }
};

/// Workgroups of a matrix launch.
pub fn matrixGroups(caps: Caps, rows: u32) [3]u32 {
    return matrixGroupsWith(Layout.of(caps), rows);
}

pub fn matrixGroupsWith(lay: Layout, rows: u32) [3]u32 {
    const rpg = lay.rowsPerGroup();
    return .{ (rows + rpg - 1) / rpg, 1, 1 };
}

/// out[t][row] = W[row] . activations[t] for `tokens` tokens (1..8), in
/// the target's layout (Layout.of).
pub fn matrix(s: kir.Storage, caps: Caps, format: Format, tokens: u32) Error!kir.Kernel {
    return matrixWith(s, caps, Layout.of(caps), format, tokens);
}

/// out[t][row] = W[row] . activations[t] for `tokens` tokens (1..8).
/// Bindings: MatrixBinding. Params: MatrixParams.words. Rows past `rows`
/// in the last workgroup read the last row and store nothing. Weights:
/// Q4_K rows 16-byte aligned (GGUF's alignment and 144-byte blocks give it),
/// Q6_K and Q8_0 rows 2-byte aligned (their blocks are read in halves).
pub fn matrixWith(s: kir.Storage, caps: Caps, lay: Layout, format: Format, tokens: u32) Error!kir.Kernel {
    if (tokens < 1 or tokens > MAX_TOKENS) return error.Unsupported;
    if (lay.lanes != 1 and lay.lanes != 2 and lay.lanes != 4) return error.Unsupported;
    if (caps.subgroup < lay.threadsPerRow()) return error.Unsupported;
    var k = begin(s, switch (format) {
        .q4_k => "lfm3_q4k",
        .q6_k => "lfm3_q6k",
        .q8_0 => "lfm3_q80",
    }, lay.threads);
    var b = Builder.init(&k, caps);
    const W = k.binding();
    const AQ = k.binding();
    const AD = k.binding();
    const AS = k.binding();
    const OUT = k.binding();
    k.param_words = MatrixParams.WORDS;
    const lpt = lay.lanes;
    const tpr = lay.threadsPerRow();

    const t = b.tid(0);
    const lt = b.band(R(t), U(tpr - 1));
    const row = b.add(R(b.mul(R(b.gid(0)), U(lay.rowsPerGroup()))), R(b.shr(R(t), log2(tpr))));
    const row_bytes = b.param(0);
    const blocks = b.param(1);
    const rows = b.param(2);
    const valid = b.icmp(.u32, .lt, R(row), R(rows));
    const rowc = b.umin(R(row), R(b.sub(R(rows), U(1))));
    const wrow = b.add(R(b.param(7)), R(b.mul(R(rowc), R(row_bytes))));
    const l0 = b.shl(R(lt), log2(lpt));
    const l0x4 = b.shl(R(l0), 2);
    // per token: the activation bases (this thread's lanes included)
    var aq_t: [MAX_TOKENS]V = undefined;
    var ad_t: [MAX_TOKENS]V = undefined;
    var as_t: [MAX_TOKENS]V = undefined;
    const aq0 = b.add(R(b.param(8)), R(l0x4));
    const ad0 = b.param(9);
    const as0 = b.add(R(b.param(10)), R(l0x4));
    for (0..tokens) |ti| {
        const tw: u32 = @intCast(ti);
        aq_t[ti] = if (tw == 0) aq0 else b.add(R(b.mul(R(b.param(4)), U(tw))), R(aq0));
        ad_t[ti] = if (tw == 0) ad0 else b.add(R(b.mul(R(b.param(5)), U(tw))), R(ad0));
        as_t[ti] = if (tw == 0) as0 else b.add(R(b.mul(R(b.param(6)), U(tw))), R(as0));
    }
    // the lanes' float sums
    var acc: [MAX_TOKENS][4]V = undefined;
    for (0..tokens) |ti| for (0..lpt) |j| {
        acc[ti][j] = b.mov(.f32, F(0));
    };
    const boff = b.mov(.u32, R(wrow));
    const blk = b.mov(.u32, U(0));

    switch (format) {
        .q4_k => q4kBody(&b, .{ .W = W, .AQ = AQ, .AD = AD, .AS = AS }, lpt, tokens, l0, l0x4, boff, blk, blocks, &aq_t, &ad_t, &as_t, &acc),
        .q6_k => q6kBody(&b, .{ .W = W, .AQ = AQ, .AD = AD, .AS = AS }, lpt, tokens, l0, l0x4, boff, blk, blocks, &aq_t, &ad_t, &as_t, &acc),
        .q8_0 => q80Body(&b, .{ .W = W, .AQ = AQ, .AD = AD, .AS = AS }, lpt, tokens, l0x4, boff, blk, blocks, &aq_t, &ad_t, &acc),
    }

    // Each token's lanes to the row's first thread (xor k from it is the
    // row's thread k), added as the CPU adds them.
    const store = b.pand(b.icmp(.u32, .eq, R(lt), U(0)), valid);
    const row4 = b.add(R(b.param(11)), R(b.shl(R(row), 2)));
    for (0..tokens) |ti| {
        var lane: [8]V = undefined;
        for (0..8) |l| {
            const owner: u32 = @intCast(l / lpt);
            const v = acc[ti][l % lpt];
            lane[l] = if (owner == 0) v else b.shfl(.xor, v, U(owner));
        }
        const total = if (format == .q8_0) avx: {
            // GGML's AVX reduction: (l + l^4), then the halves, then the two
            var q: [4]V = undefined;
            for (0..4) |i| q[i] = b.fadd(R(lane[i + 4]), R(lane[i]));
            const h0 = b.fadd(R(q[0]), R(q[2]));
            const h1 = b.fadd(R(q[1]), R(q[3]));
            break :avx b.fadd(R(h0), R(h1));
        } else seq: {
            var sum = lane[0];
            for (1..8) |l| sum = b.fadd(R(sum), R(lane[l]));
            break :seq sum;
        };
        const addr = if (ti == 0) row4 else b.add(R(b.mul(R(b.param(3)), U(@intCast(ti)))), R(row4));
        b.if_(store);
        b.st(OUT, R(addr), 0, 5, total);
        b.endif();
    }
    try k.finish();
    return k;
}

const MB = struct { W: u8, AQ: u8, AD: u8, AS: u8 };

/// The block loop's end: next block, and out when all are done.
fn nextBlock(b: *Builder, boff: V, blk: V, blocks: V, block_bytes: u32) void {
    b.set(boff, .iadd, .u32, R(boff), U(block_bytes), NO);
    b.set(blk, .iadd, .u32, R(blk), U(1), NO);
    b.brk(b.icmp(.u32, .ge, R(blk), R(blocks)));
}

fn q4kBody(b: *Builder, m: MB, lpt: u32, tokens: u32, l0: V, l0x4: V, boff: V, blk: V, blocks: V, aq_t: []const V, ad_t: []const V, as_t: []const V, acc: *[MAX_TOKENS][4]V) void {
    // this thread's lanes in the minimums: their half and byte shifts
    const hi_half = b.icmp(.u32, .ge, R(l0), U(4));
    const mshift0 = b.shl(R(b.band(R(l0), U(3))), 3);
    var mshift: [4]V = undefined;
    for (0..lpt) |j| mshift[j] = if (j == 0) mshift0 else b.add(R(mshift0), U(@intCast(8 * j)));
    b.loop();
    const hdr = b.ldv(m.W, .u32, R(boff), 0, 4);
    const h0 = at(hdr, 0);
    const h1 = at(hdr, 1);
    const h2 = at(hdr, 2);
    const h3 = at(hdr, 3);
    const d = b.half(h0, false);
    const dmin = b.half(h0, true);
    // GGML's four-word mask sequence (quantized_linear.unpackScalesQ4K)
    const sc_lo = b.band(R(h1), U(0x3f3f3f3f));
    const sc_hi = b.bor(R(b.band(R(h3), U(0x0f0f0f0f))), R(b.shl(R(b.band(R(b.shr(R(h1), 6)), U(0x03030303))), 4)));
    const mn_lo = b.band(R(h2), U(0x3f3f3f3f));
    const mn_hi = b.bor(R(b.band(R(b.shr(R(h3), 4)), U(0x0f0f0f0f))), R(b.shl(R(b.band(R(b.shr(R(h2), 6)), U(0x03030303))), 4)));
    var scale: [8]V = undefined;
    for (0..8) |j| scale[j] = b.as(.i32, b.bfeU(R(if (j < 4) sc_lo else sc_hi), U(@intCast(8 * (j % 4))), 8));
    const mnw = b.sel(.u32, hi_half, R(mn_hi), R(mn_lo));
    var minimum: [4]V = undefined;
    for (0..lpt) |j| minimum[j] = b.as(.i32, b.bfeU(R(mnw), R(mshift[j]), 8));
    // the weight nibbles: sub-block 2p the low, 2p + 1 the high nibbles of pair p
    const qaddr = b.add(R(boff), R(l0x4));
    var wq: [8][4]V = undefined;
    for (0..4) |p| {
        const w = b.ldv(m.W, .u32, R(qaddr), @intCast(16 + 32 * p), lpt);
        for (0..lpt) |j| {
            wq[2 * p][j] = b.band(R(at(w, j)), U(0x0f0f0f0f));
            wq[2 * p + 1][j] = b.band(R(b.shr(R(at(w, j)), 4)), U(0x0f0f0f0f));
        }
    }
    const a_off = b.shl(R(blk), 8);
    const d_off = b.shl(R(blk), 2);
    const s_off = b.shl(R(blk), 5);
    for (0..tokens) |ti| {
        const aa = b.add(R(aq_t[ti]), R(a_off));
        var aw: [8]V = undefined;
        for (0..8) |j| aw[j] = b.ldv(m.AQ, .u32, R(aa), @intCast(32 * j), lpt);
        const ad = b.ld(m.AD, .f32, R(b.add(R(ad_t[ti]), R(d_off))), 0, 5);
        const bs = b.ldv(m.AS, .u32, R(b.add(R(as_t[ti]), R(s_off))), 0, lpt);
        const da = b.fmul(R(d), R(ad));
        const dm = b.fmul(R(dmin), R(ad));
        for (0..lpt) |j| {
            var sum: V = undefined;
            for (0..8) |sb| {
                const dot = b.dot4(.s8u8, R(at(aw[sb], j)), R(wq[sb][j]), I(0));
                sum = if (sb == 0) b.imulS(R(dot), R(scale[0])) else b.imadS(R(dot), R(scale[sb]), R(sum));
            }
            // the minimum: min[lane] * (bsums[2 lane] + bsums[2 lane + 1])
            const bsw = b.as(.i32, at(bs, j));
            const pair = b.iaddS(R(b.bfeS(R(bsw), U(0), 16)), R(b.bfeS(R(bsw), U(16), 16)));
            const mm = b.imulS(R(pair), R(minimum[j]));
            // sums += (d * ad) * I - (dmin * ad) * M
            const x = b.fmul(R(da), R(b.i2f(sum)));
            const y = b.fmul(R(dm), R(b.i2f(mm)));
            b.set(acc[ti][j], .fadd, .f32, R(acc[ti][j]), R(b.fsub(R(x), R(y))), NO);
        }
    }
    nextBlock(b, boff, blk, blocks, Q4_K_BLOCK);
    b.endloop();
}

/// A little-endian u32 at a 2-byte aligned address, from two halves.
fn word16(b: *Builder, binding: u8, addr: V, imm: u32) V {
    const lo = b.ld(binding, .u32, R(addr), imm, 4);
    const hi = b.ld(binding, .u32, R(addr), imm + 2, 4);
    return b.bor(R(lo), R(b.shl(R(hi), 16)));
}

fn q6kBody(b: *Builder, m: MB, lpt: u32, tokens: u32, l0: V, l0x4: V, boff: V, blk: V, blocks: V, aq_t: []const V, ad_t: []const V, as_t: []const V, acc: *[MAX_TOKENS][4]V) void {
    // the quarter scales of this thread's lanes: byte 2 (q % 2) + hs of
    // word 2h + q / 2 (hs: lanes 4..7 take a block's odd scales)
    const hs = b.shr(R(l0), 2);
    const sh_even = b.shl(R(hs), 3);
    const sh_odd = b.add(R(sh_even), U(16));
    // the offset scales 2L and 2L + 1 of lane L: word L / 2, shift 16 (L % 2)
    var ow0: [4]V = undefined; // word index bit 0 / bit 1 per lane
    var ow1: [4]V = undefined;
    var osh: [4]Arg = undefined;
    for (0..lpt) |j| {
        const lane = if (j == 0) l0 else b.add(R(l0), U(@intCast(j)));
        const widx = b.shr(R(lane), 1);
        ow0[j] = b.icmp(.u32, .ne, R(b.band(R(widx), U(1))), U(0));
        ow1[j] = b.icmp(.u32, .ne, R(b.band(R(widx), U(2))), U(0));
        osh[j] = if (lpt == 1) R(b.shl(R(b.band(R(l0), U(1))), 4)) else U(@intCast(16 * (j % 2)));
    }
    b.loop();
    const qaddr = b.add(R(boff), R(l0x4));
    // per lane: ql (low, next) and qh (high) words of each half
    var low: [2][4]V = undefined;
    var next: [2][4]V = undefined;
    var high: [2][4]V = undefined;
    for (0..2) |h| for (0..lpt) |j| {
        const o: u32 = @intCast(4 * j);
        low[h][j] = word16(b, m.W, qaddr, @intCast(h * 64 + o));
        next[h][j] = word16(b, m.W, qaddr, @intCast(h * 64 + 32 + o));
        high[h][j] = word16(b, m.W, qaddr, @intCast(128 + h * 32 + o));
    };
    var sw: [4]V = undefined;
    for (0..4) |i| sw[i] = word16(b, m.W, boff, @intCast(192 + 4 * i));
    const d = b.half(b.ld(m.W, .u32, R(boff), 208, 4), false);
    var scale: [2][4]V = undefined;
    for (0..2) |h| for (0..4) |q| {
        scale[h][q] = b.bfeS(R(b.as(.i32, sw[2 * h + q / 2])), R(if (q % 2 == 0) sh_even else sh_odd), 8);
    };
    var osc0: [4]V = undefined;
    var osc1: [4]V = undefined;
    for (0..lpt) |j| {
        const w = b.sel(.u32, ow1[j], R(b.sel(.u32, ow0[j], R(sw[3]), R(sw[2]))), R(b.sel(.u32, ow0[j], R(sw[1]), R(sw[0]))));
        const wi = b.as(.i32, w);
        osc0[j] = b.bfeS(R(wi), osh[j], 8);
        osc1[j] = b.bfeS(R(wi), if (lpt == 1) R(b.add(R(osh[j].reg), U(8))) else U(osh[j].imm + 8), 8);
    }
    // the 6-bit values of each half's four quarters
    var quarter: [2][4][4]V = undefined;
    for (0..2) |h| for (0..lpt) |j| {
        const L = low[h][j];
        const N = next[h][j];
        const H = high[h][j];
        const nib = U(0x0f0f0f0f);
        const three = U(0x03030303);
        quarter[h][0][j] = b.bor(R(b.band(R(L), nib)), R(b.shl(R(b.band(R(H), three)), 4)));
        quarter[h][1][j] = b.bor(R(b.band(R(N), nib)), R(b.shl(R(b.band(R(b.shr(R(H), 2)), three)), 4)));
        quarter[h][2][j] = b.bor(R(b.band(R(b.shr(R(L), 4)), nib)), R(b.shl(R(b.band(R(b.shr(R(H), 4)), three)), 4)));
        quarter[h][3][j] = b.bor(R(b.band(R(b.shr(R(N), 4)), nib)), R(b.shl(R(b.band(R(b.shr(R(H), 6)), three)), 4)));
    };
    const a_off = b.shl(R(blk), 8);
    const d_off = b.shl(R(blk), 2);
    const s_off = b.shl(R(blk), 5);
    for (0..tokens) |ti| {
        const aa = b.add(R(aq_t[ti]), R(a_off));
        var aw: [2][4]V = undefined;
        for (0..2) |h| for (0..4) |q| {
            aw[h][q] = b.ldv(m.AQ, .u32, R(aa), @intCast(h * 128 + q * 32), lpt);
        };
        const ad = b.ld(m.AD, .f32, R(b.add(R(ad_t[ti]), R(d_off))), 0, 5);
        const bs = b.ldv(m.AS, .u32, R(b.add(R(as_t[ti]), R(s_off))), 0, lpt);
        const ds = b.fmul(R(d), R(ad));
        for (0..lpt) |j| {
            var sum: V = undefined;
            var first = true;
            for (0..2) |h| for (0..4) |q| {
                const dot = b.dot4(.s8u8, R(at(aw[h][q], j)), R(quarter[h][q][j]), I(0));
                sum = if (first) b.imulS(R(dot), R(scale[h][q])) else b.imadS(R(dot), R(scale[h][q]), R(sum));
                first = false;
            };
            // offset: bsums[2L] * scale[2L] + bsums[2L + 1] * scale[2L + 1]
            const bsw = b.as(.i32, at(bs, j));
            const off = b.imadS(R(b.bfeS(R(bsw), U(16), 16)), R(osc1[j]), R(b.imulS(R(b.bfeS(R(bsw), U(0), 16)), R(osc0[j]))));
            // sums += (d * ad) * (I - 32 offset)
            const z = b.fsub(R(b.i2f(sum)), R(b.fmul(F(32.0), R(b.i2f(off)))));
            b.set(acc[ti][j], .fadd, .f32, R(acc[ti][j]), R(b.fmul(R(ds), R(z))), NO);
        }
    }
    nextBlock(b, boff, blk, blocks, Q6_K_BLOCK);
    b.endloop();
}

fn q80Body(b: *Builder, m: MB, lpt: u32, tokens: u32, l0x4: V, boff: V, blk: V, blocks: V, aq_t: []const V, ad_t: []const V, acc: *[MAX_TOKENS][4]V) void {
    b.loop();
    const qaddr = b.add(R(boff), R(l0x4));
    var w: [4]V = undefined;
    for (0..lpt) |j| w[j] = word16(b, m.W, qaddr, @intCast(2 + 4 * j));
    const d = b.half(b.ld(m.W, .u32, R(boff), 0, 4), false);
    const a_off = b.shl(R(blk), 5);
    const d_off = b.shl(R(blk), 2);
    for (0..tokens) |ti| {
        const aw = b.ldv(m.AQ, .u32, R(b.add(R(aq_t[ti]), R(a_off))), 0, lpt);
        const ad = b.ld(m.AD, .f32, R(b.add(R(ad_t[ti]), R(d_off))), 0, 5);
        const da = b.fmul(R(d), R(ad));
        for (0..lpt) |j| {
            const dot = b.dot4(.s8s8, R(at(aw, j)), R(w[j]), I(0));
            // the CPU's @mulAdd: fused where the GPU fuses
            b.set(acc[ti][j], .mov, .f32, R(b.fma(R(da), R(b.i2f(dot)), R(acc[ti][j]))), NO, NO);
        }
    }
    nextBlock(b, boff, blk, blocks, Q8_0_BLOCK);
    b.endloop();
}

// ── Q8_K quantization ───────────────────────────────────────────────────────

pub const QuantMode = enum { plain, norm, swiglu };

/// The quantization kernels' bindings: x (plain, norm) or gate (swiglu);
/// weight (norm: RMSNorm's) or up (swiglu), unused by plain; normalized
/// (norm: the normalized rows written out), unused otherwise; the
/// activation arrays.
pub const QuantBinding = enum(u8) { x, weight, normalized, act_q, act_d, act_sums };

/// Parameter words: K (the row's width), K / 256, epsilon's bits (norm);
/// byte offsets of the first row in x, of the weights (norm's) or up
/// (swiglu's), of the first normalized row.
pub fn quantParams(k: u32, epsilon: f32, x: u32, weight: u32, normalized: u32) [6]u32 {
    return .{ k, k / QK_K, @bitCast(epsilon), x, weight, normalized };
}

/// Threads of the row kernels on a device: ROW_THREADS, or the device's
/// largest group when that is smaller.
pub fn rowThreads(caps: Caps) u32 {
    return @min(ROW_THREADS, caps.max_group);
}

/// Workgroups: (1, T) with the norm (a workgroup a row), else (K / 256
/// blocks over the blocks a workgroup quantizes, rounded up; T).
pub fn quantGroups(caps: Caps, mode: QuantMode, k: u32, tokens: u32) [3]u32 {
    if (mode == .norm) return .{ 1, tokens, 1 };
    const blocks = k / QK_K;
    const per = rowThreads(caps) / 32;
    return .{ (blocks + per - 1) / per, tokens, 1 };
}

/// Q8_K of the 256-lane block whose elements 8i .. 8i + 7 thread `i` (of its
/// 32) holds in `x`, as quantized_linear.quantizeQ8K: the first element of
/// largest magnitude sets the scale, -127 / max and its reciprocal divided
/// exactly, rounded to nearest even; a zero block is zeros. `index` is the
/// block's number in the activation arrays; `ok`: store (else only compute).
fn quantQ8K(b: *Builder, x: [8]V, i: V, t: V, index: V, ok: V, AQ: u8, AD: u8, AS: u8) void {
    var a: [8]V = undefined;
    for (0..8) |j| a[j] = b.as(.u32, b.fabs(R(x[j])));
    var mag = a[0];
    for (1..8) |j| mag = b.umax(R(mag), R(a[j]));
    mag = b.xorReduce(.imax, .u32, mag, 32, t);
    // the first element of that magnitude: key = index << 1 | sign, least wins
    var key = b.mov(.u32, U(0xffffffff));
    const base = b.shl(R(i), 4);
    var j: usize = 8;
    while (j > 0) {
        j -= 1;
        const kj = b.bor(R(b.add(R(base), U(@intCast(2 * j)))), R(b.shr(R(b.as(.u32, x[j])), 31)));
        key = b.sel(.u32, b.icmp(.u32, .eq, R(a[j]), R(mag)), R(kj), R(key));
    }
    key = b.xorReduce(.imin, .u32, key, 32, t);
    const maximum = b.as(.f32, b.bor(R(mag), R(b.shl(R(key), 31))));
    const zero = b.icmp(.u32, .eq, R(mag), U(0));
    const inverse = b.fdiv(F(-127.0), R(maximum));
    const d = b.sel(.f32, zero, F(0), R(b.fdiv(F(1.0), R(inverse))));
    var q: [8]V = undefined;
    for (0..8) |e| {
        const n = b.cvt(.f32, .i32, .rz, R(b.frne(R(b.fmul(R(inverse), R(x[e]))))));
        q[e] = b.sel(.i32, zero, I(0), R(b.op2(.imin, .i32, R(n), I(127))));
    }
    // the bytes, two words
    const packed_words = b.k.vec(.u32, 2);
    for (0..2) |w| {
        var acc = b.band(R(b.as(.u32, q[4 * w])), U(0xff));
        for (1..4) |e| acc = b.bor(R(acc), R(b.shl(R(b.band(R(b.as(.u32, q[4 * w + e])), U(0xff))), @intCast(8 * e))));
        b.set(at(packed_words, w), .mov, .u32, R(acc), NO, NO);
    }
    // sums of 16: this thread's eight and its neighbour's
    var s8 = q[0];
    for (1..8) |e| s8 = b.iaddS(R(s8), R(q[e]));
    const s16 = b.iaddS(R(s8), R(b.xorPartner(s8, 1, t)));
    b.if_(ok);
    b.st(AQ, R(b.add(R(b.shl(R(index), 8)), R(b.shl(R(i), 3)))), 0, 6, packed_words);
    const even = b.icmp(.u32, .eq, R(b.band(R(i), U(1))), U(0));
    b.if_(even);
    b.st(AS, R(b.add(R(b.shl(R(index), 5)), R(i))), 0, 4, s16);
    b.endif();
    b.if_(b.icmp(.u32, .eq, R(i), U(0)));
    b.st(AD, R(b.shl(R(index), 2)), 0, 5, d);
    b.endif();
    b.endif();
}

/// Rows of f32 to Q8_K activations (`.plain`), with RMSNorm first and the
/// normalized rows written out (`.norm`, lfm3_executor's NormQuantizeTask),
/// or of silu(gate) * up (`.swiglu`, SwiGluQuantizeTask). ROW_THREADS
/// threads: eight blocks at a time, 32 threads a block, 8 elements a thread.
/// Bindings: QuantBinding. Params: quantParams. Groups: quantGroups. Rows
/// 16-byte aligned (K a multiple of 256).
pub fn quant(s: kir.Storage, caps: Caps, mode: QuantMode) Error!kir.Kernel {
    const threads: u32 = rowThreads(caps);
    if (threads < 32) return error.Unsupported;
    var k = begin(s, switch (mode) {
        .plain => "lfm3_quant",
        .norm => "lfm3_norm_quant",
        .swiglu => "lfm3_swiglu_quant",
    }, threads);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const WB = k.binding();
    const NB = k.binding();
    const AQ = k.binding();
    const AD = k.binding();
    const AS = k.binding();
    k.param_words = 6;
    b.needExchange(if (mode == .norm) threads else 32);
    const per_pass = threads / 32;
    const t = b.tid(0);
    const i = b.band(R(t), U(31));
    const bin = b.shr(R(t), 5);
    const width = b.param(0);
    const blocks = b.param(1);
    const tok = b.gid(1);
    const row_blocks = b.mul(R(tok), R(blocks));
    const row_bytes = b.shl(R(b.mul(R(tok), R(width))), 2);
    const last = b.sub(R(blocks), U(1));
    const lane_bytes = b.shl(R(i), 5);
    const x_base = b.add(R(b.param(3)), R(row_bytes));
    const w_base = b.param(4);

    if (mode != .norm) {
        const bl = b.add(R(b.mul(R(b.gid(0)), U(per_pass))), R(bin));
        const ok = b.icmp(.u32, .lt, R(bl), R(blocks));
        const blc = b.umin(R(bl), R(last));
        const col = b.add(R(b.shl(R(blc), 10)), R(lane_bytes));
        const off = b.add(R(x_base), R(col));
        var x: [8]V = undefined;
        const x0 = b.ldv(X, .f32, R(off), 0, 4);
        const x1 = b.ldv(X, .f32, R(off), 16, 4);
        for (0..4) |e| {
            x[e] = at(x0, e);
            x[4 + e] = at(x1, e);
        }
        if (mode == .swiglu) {
            const uoff = b.add(R(b.add(R(w_base), R(row_bytes))), R(col));
            const up0 = b.ldv(WB, .f32, R(uoff), 0, 4);
            const up1 = b.ldv(WB, .f32, R(uoff), 16, 4);
            // (g / (1 + exp(-g))) * u
            for (0..8) |e| x[e] = b.fmul(R(b.silu(x[e])), R(at(if (e < 4) up0 else up1, e % 4)));
        }
        quantQ8K(&b, x, i, t, b.add(R(row_blocks), R(blc)), ok, AQ, AD, AS);
        try k.finish();
        return k;
    }

    // RMSNorm: the row's square sum (double-f32), then each pass of eight
    // blocks normalized, written out and quantized.
    const passes = b.shr(R(b.add(R(blocks), U(per_pass - 1))), log2(per_pass));
    const sum = b.ddZero();
    const p = b.mov(.u32, U(0));
    b.loop();
    {
        const bl = b.add(R(b.mul(R(p), U(per_pass))), R(bin));
        const ok = b.icmp(.u32, .lt, R(bl), R(blocks));
        const off = b.add(R(x_base), R(b.add(R(b.shl(R(b.umin(R(bl), R(last))), 10)), R(lane_bytes))));
        const x0 = b.ldv(X, .f32, R(off), 0, 4);
        const x1 = b.ldv(X, .f32, R(off), 16, 4);
        for (0..8) |e| {
            const v = b.sel(.f32, ok, R(at(if (e < 4) x0 else x1, e % 4)), F(0));
            b.ddAccumulate(sum, b.square(v));
        }
        b.set(p, .iadd, .u32, R(p), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(p), R(passes)));
    }
    b.endloop();
    const total = b.xorReduceDD(sum, threads, t);
    const inverse = b.normInverse(total, R(b.cvt(.u32, .f32, .rne, R(width))), R(b.as(.f32, b.param(2))));
    b.set(p, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const bl = b.add(R(b.mul(R(p), U(per_pass))), R(bin));
        const ok = b.icmp(.u32, .lt, R(bl), R(blocks));
        const blc = b.umin(R(bl), R(last));
        const col = b.add(R(b.shl(R(blc), 10)), R(lane_bytes));
        const off = b.add(R(x_base), R(col));
        const noff = b.add(R(b.add(R(b.param(5)), R(row_bytes))), R(col));
        const wo = b.add(R(w_base), R(col));
        const x0 = b.ldv(X, .f32, R(off), 0, 4);
        const x1 = b.ldv(X, .f32, R(off), 16, 4);
        const w0 = b.ldv(WB, .f32, R(wo), 0, 4);
        const w1 = b.ldv(WB, .f32, R(wo), 16, 4);
        const y0 = b.k.vec(.f32, 4);
        const y1 = b.k.vec(.f32, 4);
        var y: [8]V = undefined;
        for (0..8) |e| {
            const dst = at(if (e < 4) y0 else y1, e % 4);
            // value * inverse * weight
            const v = b.fmul(R(b.fmul(R(at(if (e < 4) x0 else x1, e % 4)), R(inverse))), R(at(if (e < 4) w0 else w1, e % 4)));
            b.set(dst, .mov, .f32, R(v), NO, NO);
            y[e] = dst;
        }
        b.if_(ok);
        b.st(NB, R(noff), 0, 7, y0);
        b.st(NB, R(noff), 16, 7, y1);
        b.endif();
        quantQ8K(&b, y, i, t, b.add(R(row_blocks), R(blc)), ok, AQ, AD, AS);
        b.set(p, .iadd, .u32, R(p), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(p), R(passes)));
    }
    b.endloop();
    try k.finish();
    return k;
}

// ── Q8_0 quantization ───────────────────────────────────────────────────────

/// Bindings: x, act_q, act_d. Params: K, K / 32, x's first row (bytes).
/// Groups: (K / 2048 rounded up, T).
pub fn q80Groups(k: u32, tokens: u32) [3]u32 {
    const blocks = k / QK8_0;
    return .{ (blocks + 63) / 64, tokens, 1 };
}

/// Rows of f32 to Q8_0 activations as quantized_linear.quantizeQ80 (GGML's
/// x86 rule): d = amax / 127 rounded to f16, values times 127 / amax
/// rounded to nearest even and held to [-127, 127]; both quotients exact; a
/// zero block stays zero. 256 threads: 64 blocks of 32 a workgroup, four
/// threads a block, eight elements a thread.
pub fn q80Quant(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3_q80_quant", 256);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const AQ = k.binding();
    const AD = k.binding();
    k.param_words = 3;
    b.needExchange(4);
    const t = b.tid(0);
    const i = b.band(R(t), U(3));
    const blocks = b.param(1);
    const bl = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.shr(R(t), 2)));
    const ok = b.icmp(.u32, .lt, R(bl), R(blocks));
    const blc = b.umin(R(bl), R(b.sub(R(blocks), U(1))));
    const index = b.add(R(b.mul(R(b.gid(1)), R(blocks))), R(blc));
    const off = b.add(R(b.param(2)), R(b.add(R(b.shl(R(index), 7)), R(b.shl(R(i), 5)))));
    const x0 = b.ldv(X, .f32, R(off), 0, 4);
    const x1 = b.ldv(X, .f32, R(off), 16, 4);
    var x: [8]V = undefined;
    for (0..4) |e| {
        x[e] = at(x0, e);
        x[4 + e] = at(x1, e);
    }
    var mag = b.fabs(R(x[0]));
    for (1..8) |e| mag = b.fmax(R(mag), R(b.fabs(R(x[e]))));
    mag = b.xorReduce(.fmax, .f32, mag, 4, t);
    const nonzero = b.fcmp(.ne, R(mag), F(0));
    const d = b.f16r(b.fdiv(R(mag), F(127.0)));
    const inverse = b.sel(.f32, nonzero, R(b.fdiv(F(127.0), R(mag))), F(0));
    const words = b.k.vec(.u32, 2);
    for (0..2) |w| {
        var acc: V = undefined;
        for (0..4) |e| {
            const n = b.cvt(.f32, .i32, .rz, R(b.frne(R(b.fmul(R(x[4 * w + e]), R(inverse))))));
            const c = b.op2(.imax, .i32, R(b.op2(.imin, .i32, R(n), I(127))), I(-127));
            const byte = b.band(R(b.as(.u32, c)), U(0xff));
            acc = if (e == 0) byte else b.bor(R(acc), R(b.shl(R(byte), @intCast(8 * e))));
        }
        b.set(at(words, w), .mov, .u32, R(acc), NO, NO);
    }
    b.if_(ok);
    b.st(AQ, R(b.add(R(b.shl(R(index), 5)), R(b.shl(R(i), 3)))), 0, 6, words);
    b.if_(b.icmp(.u32, .eq, R(i), U(0)));
    b.st(AD, R(b.shl(R(index), 2)), 0, 5, d);
    b.endif();
    b.endif();
    try k.finish();
    return k;
}

// ── Residual ────────────────────────────────────────────────────────────────

/// Bindings: hidden (f32 [T][K], updated), block (f32 [T][K]), weight (the
/// post-norm's, f32 [K]; unused without it). Params: K, epsilon's bits,
/// the weights' byte offset. Groups (1, T).
pub const ResidualBinding = enum(u8) { hidden, block, weight };

/// hidden[t] += rmsnorm(block[t]) * weight (`postnorm`: LFM3's sandwich
/// norms) or += block[t], as lfm3_executor's ResidualTask. K a multiple of
/// ROW_THREADS.
pub fn residual(s: kir.Storage, caps: Caps, postnorm: bool) Error!kir.Kernel {
    const threads: u32 = rowThreads(caps);
    var k = begin(s, if (postnorm) "lfm3_residual_norm" else "lfm3_residual", threads);
    var b = Builder.init(&k, caps);
    const HID = k.binding();
    const BLK = k.binding();
    const WB = k.binding();
    k.param_words = 3;
    if (postnorm) b.needExchange(threads);
    const t = b.tid(0);
    const width = b.param(0);
    const row = b.shl(R(b.mul(R(b.gid(1)), R(width))), 2);
    const chunks = b.shr(R(width), log2(threads));
    const t4 = b.shl(R(t), 2);
    var inverse: V = undefined;
    const c = b.mov(.u32, U(0));
    if (postnorm) {
        const sum = b.ddZero();
        b.loop();
        const off = b.add(R(row), R(b.add(R(b.shl(R(c), log2(threads) + 2)), R(t4))));
        b.ddAccumulate(sum, b.square(b.ld(BLK, .f32, R(off), 0, 5)));
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
        b.endloop();
        inverse = b.normInverse(b.xorReduceDD(sum, threads, t), R(b.cvt(.u32, .f32, .rne, R(width))), R(b.as(.f32, b.param(1))));
        b.set(c, .mov, .u32, U(0), NO, NO);
    }
    b.loop();
    const col = b.add(R(b.shl(R(c), log2(threads) + 2)), R(t4));
    const off = b.add(R(row), R(col));
    var x = b.ld(BLK, .f32, R(off), 0, 5);
    if (postnorm) x = b.fmul(R(b.fmul(R(x), R(inverse))), R(b.ld(WB, .f32, R(b.add(R(b.param(2)), R(col))), 0, 5)));
    b.st(HID, R(off), 0, 5, b.fadd(R(b.ld(HID, .f32, R(off), 0, 5)), R(x)));
    b.set(c, .iadd, .u32, R(c), U(1), NO);
    b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
    b.endloop();
    try k.finish();
    return k;
}

// ── Short convolution ───────────────────────────────────────────────────────

pub const MIN_TAPS = 2;
pub const MAX_TAPS = 8;

/// Bindings: mixed (f32 [T][B | C | X]), taps (f32 [hidden][taps]), state
/// (f32 [taps - 1][hidden], the oldest row first; updated), out (f32
/// [T][hidden]). Params: hidden, T, the taps' and the state's byte offsets.
/// Groups (hidden / 64 rounded up).
pub const ConvBinding = enum(u8) { mixed, taps, state, out };

pub fn convGroups(hidden: u32) [3]u32 {
    return .{ (hidden + 63) / 64, 1, 1 };
}

/// LFM3's gated short convolution, as lfm3_executor.shortConvChannels: a
/// thread a channel, the tokens in order; the window is the state's rows
/// then B * X, summed oldest tap first from 0; out = C * sum; the last
/// `taps - 1` inputs left in the state. Separate multiplies and adds: the
/// CPU's floats.
pub fn conv(s: kir.Storage, caps: Caps, taps: u32) Error!kir.Kernel {
    if (taps < MIN_TAPS or taps > MAX_TAPS) return error.Unsupported;
    var k = begin(s, "lfm3_conv", 64);
    var b = Builder.init(&k, caps);
    const MIX = k.binding();
    const TAP = k.binding();
    const STATE = k.binding();
    const OUT = k.binding();
    k.param_words = 4;
    const hist = taps - 1;
    const hidden = b.param(0);
    const tokens = b.param(1);
    const ch = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    const ok = b.icmp(.u32, .lt, R(ch), R(hidden));
    const chc = b.umin(R(ch), R(b.sub(R(hidden), U(1))));
    const c4 = b.shl(R(chc), 2);
    const h4 = b.shl(R(hidden), 2);
    const sc4 = b.add(R(b.param(3)), R(c4));
    var w: [MAX_TAPS]V = undefined;
    const toff = b.add(R(b.param(2)), R(b.mul(R(chc), U(taps * 4))));
    for (0..taps) |j| w[j] = b.ld(TAP, .f32, R(toff), @intCast(4 * j), 5);
    var win: [MAX_TAPS]V = undefined;
    for (0..hist) |r| win[r] = b.mov(.f32, R(b.ld(STATE, .f32, R(b.add(R(b.mul(R(h4), U(@intCast(r)))), R(sc4))), 0, 5)));
    win[hist] = b.mov(.f32, F(0));
    const tok = b.mov(.u32, U(0));
    const moff = b.mov(.u32, R(c4));
    const ooff = b.mov(.u32, R(c4));
    const m3 = b.mul(R(h4), U(3));
    b.loop();
    {
        const bv = b.ld(MIX, .f32, R(moff), 0, 5);
        const cv = b.ld(MIX, .f32, R(b.add(R(moff), R(h4))), 0, 5);
        const xv = b.ld(MIX, .f32, R(b.add(R(moff), R(b.shl(R(h4), 1)))), 0, 5);
        b.set(win[hist], .fmul, .f32, R(bv), R(xv), NO);
        var sum = b.mov(.f32, F(0));
        for (0..taps) |j| sum = b.fadd(R(sum), R(b.fmul(R(win[j]), R(w[j]))));
        b.if_(ok);
        b.st(OUT, R(ooff), 0, 5, b.fmul(R(cv), R(sum)));
        b.endif();
        for (0..hist) |j| b.set(win[j], .mov, .f32, R(win[j + 1]), NO, NO);
        b.set(moff, .iadd, .u32, R(moff), R(m3), NO);
        b.set(ooff, .iadd, .u32, R(ooff), R(h4), NO);
        b.set(tok, .iadd, .u32, R(tok), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(tok), R(tokens)));
    }
    b.endloop();
    b.if_(ok);
    for (0..hist) |r| b.st(STATE, R(b.add(R(b.mul(R(h4), U(@intCast(r)))), R(sc4))), 0, 5, win[r]);
    b.endif();
    try k.finish();
    return k;
}

// ── Attention ───────────────────────────────────────────────────────────────

/// Bindings of prepare: query (f32 [T][heads][128], normed, rotated and
/// rounded through f16 in place), key and value (f32 [T][kv_heads][128]),
/// the query and key norms' weights (f32 [128]), rope (f32 [T][64][2]: cos,
/// sin), kv (the f16 cache, lfm3_executor's layout).
pub const PrepareBinding = enum(u8) { query, key, value, query_norm, key_norm, rope, kv };

/// Prepare's params: heads, kv_heads, epsilon's bits, the first token's
/// position, the cache's context, the layer's slot, max_kv_heads, the
/// norms' byte offsets.
pub const PrepareParams = struct {
    heads: u32,
    kv_heads: u32,
    epsilon: f32,
    first_position: u32,
    context: u32,
    slot: u32,
    max_kv_heads: u32,
    query_norm: u32 = 0,
    key_norm: u32 = 0,

    pub fn words(p: PrepareParams) [9]u32 {
        return .{ p.heads, p.kv_heads, @bitCast(p.epsilon), p.first_position, p.context, p.slot, p.max_kv_heads, p.query_norm, p.key_norm };
    }
};

pub fn prepareGroups(heads: u32, kv_heads: u32, tokens: u32) [3]u32 {
    return .{ heads + 2 * kv_heads, tokens, 1 };
}

/// lfm3_executor's PrepareTask per (head, token): a workgroup a head, 64
/// threads, thread j holding elements j and j + 64 (a RoPE pair). Query
/// heads: RMSNorm, RoPE (the host's cos and sin, as ropeNeox has them),
/// rounded through f16, back in place. Key heads: RMSNorm, RoPE, f16 into
/// the cache. Value heads: f16 into the cache. Groups: prepareGroups.
pub fn prepare(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3_prepare", 64);
    var b = Builder.init(&k, caps);
    const Q = k.binding();
    const K = k.binding();
    const VB = k.binding();
    const QN = k.binding();
    const KN = k.binding();
    const ROPE = k.binding();
    const KV = k.binding();
    k.param_words = 9;
    b.needExchange(64);
    const t = b.tid(0);
    const heads = b.param(0);
    const kv_heads = b.param(1);
    const tok = b.gid(1);
    const g = b.gid(0);
    const is_q = b.icmp(.u32, .lt, R(g), R(heads));
    const kg = b.sub(R(g), R(heads));
    const is_v = b.icmp(.u32, .ge, R(kg), R(kv_heads));
    const kh = b.sel(.u32, is_v, R(b.sub(R(kg), R(kv_heads))), R(kg));
    const t4 = b.shl(R(t), 2);
    const qoff = b.add(R(b.shl(R(b.add(R(b.mul(R(tok), R(heads))), R(g))), 9)), R(t4));
    const koff = b.add(R(b.shl(R(b.add(R(b.mul(R(tok), R(kv_heads))), R(kh))), 9)), R(t4));
    const lo = b.mov(.f32, F(0));
    const hi = b.mov(.f32, F(0));
    b.if_(is_q);
    b.set(lo, .mov, .f32, R(b.ld(Q, .f32, R(qoff), 0, 5)), NO, NO);
    b.set(hi, .mov, .f32, R(b.ld(Q, .f32, R(qoff), 256, 5)), NO, NO);
    b.else_();
    b.if_(is_v);
    b.set(lo, .mov, .f32, R(b.ld(VB, .f32, R(koff), 0, 5)), NO, NO);
    b.set(hi, .mov, .f32, R(b.ld(VB, .f32, R(koff), 256, 5)), NO, NO);
    b.else_();
    b.set(lo, .mov, .f32, R(b.ld(K, .f32, R(koff), 0, 5)), NO, NO);
    b.set(hi, .mov, .f32, R(b.ld(K, .f32, R(koff), 256, 5)), NO, NO);
    b.endif();
    b.endif();
    // the head's RMSNorm (every workgroup computes it: uniform reductions)
    const total = b.xorReduceDD(b.ddAdd(b.square(lo), b.square(hi)), 64, t);
    const inverse = b.normInverse(total, F(128.0), R(b.as(.f32, b.param(2))));
    const nlo = b.mov(.f32, F(0));
    const nhi = b.mov(.f32, F(0));
    b.if_(is_q);
    const qn = b.add(R(b.param(7)), R(t4));
    b.set(nlo, .mov, .f32, R(b.ld(QN, .f32, R(qn), 0, 5)), NO, NO);
    b.set(nhi, .mov, .f32, R(b.ld(QN, .f32, R(qn), 256, 5)), NO, NO);
    b.else_();
    const kn = b.add(R(b.param(8)), R(t4));
    b.set(nlo, .mov, .f32, R(b.ld(KN, .f32, R(kn), 0, 5)), NO, NO);
    b.set(nhi, .mov, .f32, R(b.ld(KN, .f32, R(kn), 256, 5)), NO, NO);
    b.endif();
    const a = b.fmul(R(b.fmul(R(lo), R(inverse))), R(nlo));
    const c = b.fmul(R(b.fmul(R(hi), R(inverse))), R(nhi));
    // NeoX RoPE: rope[(t * 64 + j) * 2] = cos, sin
    const cs = b.ldv(ROPE, .f32, R(b.shl(R(b.add(R(b.shl(R(tok), 6)), R(t))), 3)), 0, 2);
    const cosv = at(cs, 0);
    const sinv = at(cs, 1);
    const rlo = b.fsub(R(b.fmul(R(a), R(cosv))), R(b.fmul(R(c), R(sinv))));
    const rhi = b.fadd(R(b.fmul(R(a), R(sinv))), R(b.fmul(R(c), R(cosv))));
    b.if_(is_q);
    b.st(Q, R(qoff), 0, 5, b.f16r(rlo));
    b.st(Q, R(qoff), 256, 5, b.f16r(rhi));
    b.else_();
    // cache row (((slot * 2 + is_value) * max_kv + kh) * context + position) * 256 bytes
    const v01 = b.sel(.u32, is_v, U(1), U(0));
    const blkn = b.add(R(b.mul(R(b.add(R(b.shl(R(b.param(5)), 1)), R(v01))), R(b.param(6)))), R(kh));
    const pos = b.add(R(b.param(3)), R(tok));
    const crow = b.add(R(b.mul(R(blkn), R(b.param(4)))), R(pos));
    const coff = b.add(R(b.shl(R(crow), 8)), R(b.shl(R(t), 1)));
    const vlo = b.sel(.f32, is_v, R(lo), R(rlo));
    const vhi = b.sel(.f32, is_v, R(hi), R(rhi));
    b.st(KV, R(coff), 0, 4, b.halfBits(vlo));
    b.st(KV, R(coff), 128, 4, b.halfBits(vhi));
    b.endif();
    try k.finish();
    return k;
}

/// The attention kernels' bindings (each takes the ones it reads):
/// query (f32 [T][heads][128], prepared), kv (the f16 cache), scores (f32
/// [T][heads][span]: scores, then weights), partial (f32
/// [T][heads][chunks][128]), gate (f32 [T][heads]: logits), out (f32
/// [T][heads][128]).
pub const AttnParams = struct {
    heads: u32,
    kv_heads: u32,
    /// The position of this launch's first token.
    first_position: u32,
    tokens: u32,
    /// The sliding window (0: full attention).
    window: u32,
    context: u32,
    slot: u32,
    max_kv_heads: u32,
    /// Scores a row (the scratch's stride, elements).
    span: u32,
    /// Partial outputs a row (the partial scratch's stride, chunks).
    chunks: u32,
    /// Byte offsets of this launch's first token's query rows, gate logits
    /// and output rows.
    query: u32 = 0,
    gate: u32 = 0,
    out: u32 = 0,

    pub const WORDS = 15;

    pub fn words(p: AttnParams) [WORDS]u32 {
        const group = p.heads / p.kv_heads;
        const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(HEAD_SIZE)));
        return .{ p.heads, p.kv_heads, p.first_position, p.tokens, p.window, p.context, p.slot, p.max_kv_heads, p.span, p.chunks, std.math.log2_int(u32, group), @bitCast(scale), p.query, p.gate, p.out };
    }

    /// The first position row `t` sees.
    pub fn visible(p: AttnParams, t: u32) u32 {
        const pos = p.first_position + t;
        return if (p.window != 0 and pos >= p.window) pos - p.window + 1 else 0;
    }

    /// Positions row `t` reads.
    pub fn span_of(p: AttnParams, t: u32) u32 {
        return p.first_position + t + 1 - p.visible(t);
    }

    /// Chunks of `chunk` positions (aligned) a tile of `tt` tokens covers at most.
    pub fn tileChunks(p: AttnParams, tt: u32, chunk: u32) u32 {
        var most: u32 = 0;
        var t0: u32 = 0;
        while (t0 < p.tokens) : (t0 += tt) {
            const last = @min(t0 + tt, p.tokens) - 1;
            const first_chunk = p.visible(t0) / chunk;
            const last_chunk = (p.first_position + last) / chunk;
            most = @max(most, last_chunk - first_chunk + 1);
        }
        return most;
    }
};

pub fn scoreGroups(p: AttnParams, hg: u32, tt: u32) [3]u32 {
    return .{ p.heads / hg, (p.tokens + tt - 1) / tt, p.tileChunks(tt, SCORE_CHUNK) };
}
pub fn softmaxGroups(p: AttnParams) [3]u32 {
    return .{ p.heads, p.tokens, 1 };
}
pub fn valueGroups(p: AttnParams, hg: u32, tt: u32) [3]u32 {
    return .{ p.heads / hg, (p.tokens + tt - 1) / tt, p.tileChunks(tt, VALUE_CHUNK) };
}
pub fn combineGroups(p: AttnParams) [3]u32 {
    return .{ p.heads, p.tokens, 1 };
}

/// What every attention kernel works out of its params for row (t, h).
const Row = struct {
    pos: V,
    first: V,
    ok: V,
};

fn attnRow(b: *Builder, t: V, tokens: V, window: V, first_position: V) Row {
    const pos = b.add(R(first_position), R(t));
    const windowed = b.pand(b.icmp(.u32, .ne, R(window), U(0)), b.icmp(.u32, .ge, R(pos), R(window)));
    const first = b.sel(.u32, windowed, R(b.add(R(b.sub(R(pos), R(window))), U(1))), U(0));
    return .{ .pos = pos, .first = first, .ok = b.icmp(.u32, .lt, R(t), R(tokens)) };
}

/// The tile's rows: `hg` heads from h0 (one KV head), `tt` tokens from t0.
const Tile = struct {
    rows: [MAX_ROWS]Row,
    head: [MAX_ROWS]V,
    token: [MAX_ROWS]V,
    n: usize,
    /// The first position any row sees, the last one any reads.
    base: V,
    end: V,
    kvh: V,
};

fn attnTile(b: *Builder, hg: u32, tt: u32) Tile {
    var tile: Tile = undefined;
    const tokens = b.param(3);
    const window = b.param(4);
    const first_position = b.param(2);
    const h0 = b.mul(R(b.gid(0)), U(hg));
    const t0 = b.mul(R(b.gid(1)), U(tt));
    tile.kvh = b.op2(.shr, .u32, R(h0), R(b.param(10)));
    tile.n = hg * tt;
    for (0..tt) |ti| {
        const tok = if (ti == 0) t0 else b.add(R(t0), U(@intCast(ti)));
        const row = attnRow(b, tok, tokens, window, first_position);
        for (0..hg) |hi| {
            const r = ti * hg + hi;
            tile.rows[r] = row;
            tile.token[r] = tok;
            tile.head[r] = if (hi == 0) h0 else b.add(R(h0), U(@intCast(hi)));
        }
    }
    tile.base = tile.rows[0].first;
    // the last valid token of the tile
    const last_t = b.umin(R(b.add(R(t0), U(tt - 1))), R(b.sub(R(tokens), U(1))));
    tile.end = b.add(R(first_position), R(last_t));
    return tile;
}

/// The cache's byte offset of (keys or values, kv head) at position 0.
fn kvBlock(b: *Builder, values: bool, kvh: V) V {
    const slot2 = b.add(R(b.shl(R(b.param(6)), 1)), U(if (values) 1 else 0));
    const blkn = b.add(R(b.mul(R(slot2), R(b.param(7)))), R(kvh));
    return b.shl(R(b.mul(R(blkn), R(b.param(5)))), 8);
}

/// A row's offset in an [T][heads] array of `stride` bytes a row.
fn rowOffset(b: *Builder, t: V, h: V, stride: V) V {
    return b.mul(R(b.add(R(b.mul(R(t), R(b.param(0)))), R(h))), R(stride));
}

pub const AttnBinding = struct {
    pub const scores = enum(u8) { query, kv, scores };
    pub const softmax = enum(u8) { scores };
    pub const values = enum(u8) { kv, scores, partial };
    pub const combine = enum(u8) { partial, gate, out };
};

/// Scores q . k * scale (lfm3_executor's dotHalf: eight lanes over the f16
/// keys, added in order) for one chunk of SCORE_CHUNK positions (a thread
/// each) of a tile of `hg` heads by `tt` tokens; each row's visible ones
/// stored at scores[row][position - first]. Groups: scoreGroups.
pub fn attnScores(s: kir.Storage, caps: Caps, hg: u32, tt: u32) Error!kir.Kernel {
    if (hg * tt == 0 or hg * tt > MAX_ROWS) return error.Unsupported;
    var k = begin(s, "lfm3_attn_scores", SCORE_CHUNK);
    var b = Builder.init(&k, caps);
    const Q = k.binding();
    const KV = k.binding();
    const S = k.binding();
    k.param_words = AttnParams.WORDS;
    const tile = attnTile(&b, hg, tt);
    const n = tile.n;
    k.shared_bytes = @intCast(n * HEAD_SIZE * 4);
    const t = b.tid(0);
    const t4 = b.shl(R(t), 2);
    // the tile's queries into shared memory: row r at r * 512
    const row_bytes = b.mov(.u32, U(HEAD_SIZE * 4));
    for (0..n) |r| {
        const tc = b.umin(R(tile.token[r]), R(b.sub(R(b.param(3)), U(1))));
        const qo = b.add(R(b.add(R(b.param(12)), R(rowOffset(&b, tc, tile.head[r], row_bytes)))), R(t4));
        const sa = b.add(R(t4), U(@intCast(r * HEAD_SIZE * 4)));
        b.sts(R(sa), 0, b.ld(Q, .f32, R(qo), 0, 5), 1);
        b.sts(R(sa), 256, b.ld(Q, .f32, R(qo), 256, 5), 1);
    }
    b.barrier();
    const p = b.add(R(b.mul(R(b.add(R(b.op2(.shr, .u32, R(tile.base), U(log2(SCORE_CHUNK)))), R(b.gid(2)))), U(SCORE_CHUNK))), R(t));
    const pc = b.umin(R(p), R(tile.end));
    const kaddr = b.add(R(kvBlock(&b, false, tile.kvh)), R(b.shl(R(pc), 8)));
    var lanes: [MAX_ROWS][8]V = undefined;
    for (0..n) |r| for (0..8) |l| {
        lanes[r][l] = b.mov(.f32, F(0));
    };
    const i = b.mov(.u32, U(0));
    b.loop();
    {
        const ko = b.add(R(kaddr), R(b.shl(R(i), 4)));
        const kw = b.ldv(KV, .u32, R(ko), 0, 4);
        var kf: [8]V = undefined;
        for (0..8) |l| kf[l] = b.half(at(kw, l / 2), l % 2 == 1);
        const qa = b.shl(R(i), 5);
        for (0..n) |r| {
            const q0 = b.lds(.f32, R(qa), @intCast(r * HEAD_SIZE * 4), 4);
            const q1 = b.lds(.f32, R(qa), @intCast(r * HEAD_SIZE * 4 + 16), 4);
            for (0..8) |l| {
                const qv = at(if (l < 4) q0 else q1, l % 4);
                b.set(lanes[r][l], .fadd, .f32, R(lanes[r][l]), R(b.fmul(R(qv), R(kf[l]))), NO);
            }
        }
        b.set(i, .iadd, .u32, R(i), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(i), U(HEAD_SIZE / 8)));
    }
    b.endloop();
    const scale = b.as(.f32, b.param(11));
    const span4 = b.shl(R(b.param(8)), 2);
    for (0..n) |r| {
        var sum = lanes[r][0];
        for (1..8) |l| sum = b.fadd(R(sum), R(lanes[r][l]));
        const score = b.fmul(R(sum), R(scale));
        const row = tile.rows[r];
        const in = b.pand(b.pand(row.ok, b.icmp(.u32, .ge, R(p), R(row.first))), b.icmp(.u32, .le, R(p), R(row.pos)));
        b.if_(in);
        const so = b.add(R(rowOffset(&b, tile.token[r], tile.head[r], span4)), R(b.shl(R(b.sub(R(p), R(row.first))), 2)));
        b.st(S, R(so), 0, 5, score);
        b.endif();
    }
    try k.finish();
    return k;
}

/// A row's softmax in place, as lfm3_executor's AttentionTask: the maximum,
/// e = exp(score - maximum), the total (double-f32 where the CPU sums in
/// f64), its inverse, then weights f16(e * inverse). 64 threads a row.
/// Groups: softmaxGroups.
pub fn attnSoftmax(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3_attn_softmax", 64);
    var b = Builder.init(&k, caps);
    const S = k.binding();
    k.param_words = AttnParams.WORDS;
    b.needExchange(64);
    const t = b.tid(0);
    const h = b.gid(0);
    const tok = b.gid(1);
    const row = attnRow(&b, tok, b.param(3), b.param(4), b.param(2));
    const len = b.sub(R(b.add(R(row.pos), U(1))), R(row.first));
    const passes = b.shr(R(b.add(R(len), U(63))), 6);
    const base = rowOffset(&b, tok, h, b.shl(R(b.param(8)), 2));
    const last = b.sub(R(len), U(1));
    const c = b.mov(.u32, U(0));
    // the maximum
    const maximum = b.mov(.f32, F(-std.math.inf(f32)));
    b.loop();
    {
        const e = b.add(R(b.shl(R(c), 6)), R(t));
        const ok = b.icmp(.u32, .lt, R(e), R(len));
        const v = b.ld(S, .f32, R(b.add(R(base), R(b.shl(R(b.umin(R(e), R(last))), 2)))), 0, 5);
        b.set(maximum, .sel, .f32, R(b.fmax(R(maximum), R(v))), R(maximum), R(ok));
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(passes)));
    }
    b.endloop();
    const top = b.xorReduce(.fmax, .f32, maximum, 64, t);
    // e = exp(score - maximum) in place, and the total
    const sum = b.ddZero();
    const zero = b.mov(.f32, F(0));
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const e = b.add(R(b.shl(R(c), 6)), R(t));
        const ok = b.icmp(.u32, .lt, R(e), R(len));
        const off = b.add(R(base), R(b.shl(R(b.umin(R(e), R(last))), 2)));
        const v = b.expCpu(b.fsub(R(b.ld(S, .f32, R(off), 0, 5)), R(top)));
        b.if_(ok);
        b.st(S, R(off), 0, 5, v);
        b.endif();
        b.ddAccumulate(sum, .{ .hi = b.sel(.f32, ok, R(v), R(zero)), .lo = zero });
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(passes)));
    }
    b.endloop();
    const inverse = b.ddRecip(b.xorReduceDD(sum, 64, t));
    // the weights: f16(e * inverse)
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const e = b.add(R(b.shl(R(c), 6)), R(t));
        const ok = b.icmp(.u32, .lt, R(e), R(len));
        const off = b.add(R(base), R(b.shl(R(b.umin(R(e), R(last))), 2)));
        const w = b.f16r(b.fmul(R(b.ld(S, .f32, R(off), 0, 5)), R(inverse)));
        b.if_(ok);
        b.st(S, R(off), 0, 5, w);
        b.endif();
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(passes)));
    }
    b.endloop();
    try k.finish();
    return k;
}

/// Sums weight * f16 value in position order over one chunk of
/// VALUE_CHUNK positions (aligned) for a tile of `hg` heads by `tt` tokens:
/// thread j has elements j and j + 64 of every row. Each row's partial for
/// the chunk goes to partial[row][chunk - first chunk]. Groups:
/// valueGroups.
pub fn attnValues(s: kir.Storage, caps: Caps, hg: u32, tt: u32) Error!kir.Kernel {
    if (hg * tt == 0 or hg * tt > MAX_ROWS) return error.Unsupported;
    var k = begin(s, "lfm3_attn_values", 64);
    var b = Builder.init(&k, caps);
    const KV = k.binding();
    const S = k.binding();
    const P = k.binding();
    k.param_words = AttnParams.WORDS;
    const tile = attnTile(&b, hg, tt);
    const n = tile.n;
    const t = b.tid(0);
    const cshift = log2(VALUE_CHUNK);
    const chunk = b.add(R(b.shr(R(tile.base), cshift)), R(b.gid(2)));
    const cs = b.shl(R(chunk), cshift);
    const ce = b.umin(R(b.add(R(cs), U(VALUE_CHUNK - 1))), R(tile.end));
    const span4 = b.shl(R(b.param(8)), 2);
    var acc: [MAX_ROWS][2]V = undefined;
    var srow: [MAX_ROWS]V = undefined;
    const last_token = b.sub(R(b.param(3)), U(1));
    for (0..n) |r| {
        acc[r] = .{ b.mov(.f32, F(0)), b.mov(.f32, F(0)) };
        srow[r] = rowOffset(&b, b.umin(R(tile.token[r]), R(last_token)), tile.head[r], span4);
    }
    b.if_(b.icmp(.u32, .le, R(cs), R(tile.end)));
    {
        const vaddr = b.add(R(kvBlock(&b, true, tile.kvh)), R(b.shl(R(t), 1)));
        const p = b.mov(.u32, R(cs));
        b.loop();
        {
            const vo = b.add(R(vaddr), R(b.shl(R(p), 8)));
            const v0 = b.half(b.ld(KV, .u32, R(vo), 0, 4), false);
            const v1 = b.half(b.ld(KV, .u32, R(vo), 128, 4), false);
            for (0..n) |r| {
                const row = tile.rows[r];
                const in = b.pand(b.pand(row.ok, b.icmp(.u32, .ge, R(p), R(row.first))), b.icmp(.u32, .le, R(p), R(row.pos)));
                const rel = b.sel(.u32, in, R(b.sub(R(p), R(row.first))), U(0));
                const w = b.ld(S, .f32, R(b.add(R(srow[r]), R(b.shl(R(rel), 2)))), 0, 5);
                b.set(acc[r][0], .sel, .f32, R(b.fadd(R(acc[r][0]), R(b.fmul(R(w), R(v0))))), R(acc[r][0]), R(in));
                b.set(acc[r][1], .sel, .f32, R(b.fadd(R(acc[r][1]), R(b.fmul(R(w), R(v1))))), R(acc[r][1]), R(in));
            }
            b.set(p, .iadd, .u32, R(p), U(1), NO);
            b.brk(b.icmp(.u32, .gt, R(p), R(ce)));
        }
        b.endloop();
        // each row's partial, where the chunk meets the row's span
        const chunks_bytes = b.shl(R(b.param(9)), 9);
        for (0..n) |r| {
            const row = tile.rows[r];
            const first_chunk = b.shr(R(row.first), cshift);
            const meets = b.pand(b.pand(row.ok, b.icmp(.u32, .ge, R(chunk), R(first_chunk))), b.icmp(.u32, .le, R(cs), R(row.pos)));
            b.if_(meets);
            const po = b.add(R(b.add(R(rowOffset(&b, tile.token[r], tile.head[r], chunks_bytes)), R(b.shl(R(b.sub(R(chunk), R(first_chunk))), 9)))), R(b.shl(R(t), 2)));
            b.st(P, R(po), 0, 5, acc[r][0]);
            b.st(P, R(po), 256, 5, acc[r][1]);
            b.endif();
        }
    }
    b.endif();
    try k.finish();
    return k;
}

/// out = the row's partials added in chunk order, times the head's sigmoid
/// gate 1 / (1 + exp(-logit)). 64 threads, two elements each. Groups:
/// combineGroups.
pub fn attnCombine(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3_attn_combine", 64);
    var b = Builder.init(&k, caps);
    const P = k.binding();
    const G = k.binding();
    const OUT = k.binding();
    k.param_words = AttnParams.WORDS;
    const t = b.tid(0);
    const h = b.gid(0);
    const tok = b.gid(1);
    const row = attnRow(&b, tok, b.param(3), b.param(4), b.param(2));
    const cshift = log2(VALUE_CHUNK);
    const count = b.add(R(b.sub(R(b.shr(R(row.pos), cshift)), R(b.shr(R(row.first), cshift)))), U(1));
    const base = b.add(R(rowOffset(&b, tok, h, b.shl(R(b.param(9)), 9))), R(b.shl(R(t), 2)));
    const o0 = b.mov(.f32, R(b.ld(P, .f32, R(base), 0, 5)));
    const o1 = b.mov(.f32, R(b.ld(P, .f32, R(base), 256, 5)));
    const c = b.mov(.u32, U(1));
    b.if_(b.icmp(.u32, .gt, R(count), U(1)));
    b.loop();
    {
        const off = b.add(R(base), R(b.shl(R(c), 9)));
        b.set(o0, .fadd, .f32, R(o0), R(b.ld(P, .f32, R(off), 0, 5)), NO);
        b.set(o1, .fadd, .f32, R(o1), R(b.ld(P, .f32, R(off), 256, 5)), NO);
        b.set(c, .iadd, .u32, R(c), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(count)));
    }
    b.endloop();
    b.endif();
    const gate = b.sigmoid(b.ld(G, .f32, R(b.add(R(b.param(13)), R(rowOffset(&b, tok, h, b.mov(.u32, U(4)))))), 0, 5));
    const oo = b.add(R(b.add(R(b.param(14)), R(rowOffset(&b, tok, h, b.mov(.u32, U(HEAD_SIZE * 4)))))), R(b.shl(R(t), 2)));
    b.st(OUT, R(oo), 0, 5, b.fmul(R(o0), R(gate)));
    b.st(OUT, R(oo), 256, 5, b.fmul(R(o1), R(gate)));
    try k.finish();
    return k;
}

// ── Copy ────────────────────────────────────────────────────────────────────

/// Bindings: from, to. Params: 16-byte words, the byte offsets in from and
/// in to. Groups (words / 64 rounded up).
pub fn copyGroups(words16: u32) [3]u32 {
    return .{ (words16 + 63) / 64, 1, 1 };
}

/// 16 bytes a thread, from `from` to `to` (both 16-byte aligned).
pub fn copy(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3_copy", 64);
    var b = Builder.init(&k, caps);
    const FROM = k.binding();
    const TO = k.binding();
    k.param_words = 3;
    const w = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    b.if_(b.icmp(.u32, .lt, R(w), R(b.param(0))));
    const off = b.shl(R(w), 4);
    b.st(TO, R(b.add(R(b.param(2)), R(off))), 0, 7, b.ldv(FROM, .u32, R(b.add(R(b.param(1)), R(off))), 0, 4));
    b.endif();
    try k.finish();
    return k;
}

// ── LFM3-Audio (the depthformer, as lfm3_audio_gen and lfm3_audio_ops) ──────
//
// The audio networks are ggml's CPU graph (lfm3_audio_ops): its RMSNorm
// rounds each square to f32 before the f64 sum, its exp (ggml_v_expf) and
// its dot products (ggml_vec_dot_f32) are built of fused multiply-adds, as
// is the Q8_0 matrices' epilogue. Each fused step is ffma where the GPU
// fuses and Builder.fma's exact emulation where it does not: the CPU's bits
// on every GPU.

/// a * b + c, as the CPU's @mulAdd where the GPU fuses.
pub fn mulAdd(b: *Builder, a: Arg, x: Arg, c: Arg) V {
    return b.fma(a, x, c);
}

/// ggml_v_expf (lfm3_audio_ops.expGgml), op for op, branch-free.
pub fn expGgml(b: *Builder, x: V) V {
    const r = F(0x1.8p23);
    const z = mulAdd(b, R(x), F(0x1.715476p+0), r);
    const n = b.fsub(R(z), r);
    const nn = b.fneg(R(n));
    const bb = mulAdd(b, R(nn), F(0x1.7f7d1cp-20), R(mulAdd(b, R(nn), F(0x1.62e4p-1), R(x))));
    const e = b.shl(R(b.as(.u32, z)), 23);
    const k = b.as(.f32, b.add(R(e), U(@bitCast(@as(f32, 1.0)))));
    const u = b.fmul(R(bb), R(bb));
    const inner = mulAdd(b, R(mulAdd(b, F(0x1.0e4020p-7), R(bb), F(0x1.573e2ep-5))), R(u), R(mulAdd(b, F(0x1.555e66p-3), R(bb), F(0x1.fffdb6p-2))));
    const j = mulAdd(b, R(inner), R(u), R(b.fmul(F(0x1.ffffecp-1), R(bb))));
    const normal = mulAdd(b, R(j), R(k), R(k));
    const an = b.fabs(R(n));
    const g = b.sel(.u32, b.fcmp(.le, R(n), F(0)), U(0x82000000), U(0));
    const s1 = b.as(.f32, b.add(R(g), U(0x7f000000)));
    const s2 = b.as(.f32, b.sub(R(e), R(g)));
    const huge = b.fmul(R(s1), R(s1));
    const scaled = b.fmul(R(mulAdd(b, R(s2), R(j), R(s2))), R(s1));
    const far = b.sel(.f32, b.fcmp(.gt, R(an), F(192)), R(huge), R(scaled));
    // !(|n| > 126): the normal path (NaN included, as the CPU's test)
    return b.sel(.f32, b.fcmp(.gt, R(an), F(126)), R(far), R(normal));
}

/// The host's twin of expGgml with the twice-rounded mad an unfused GPU
/// has (fused: lfm3_audio_ops.expGgml itself).
pub fn expGgmlUnfused(x: f32) f32 {
    const M = struct {
        fn mad(a: f32, c: f32, d: f32) f32 {
            return a * c + d;
        }
    };
    const r: f32 = 0x1.8p23;
    const z = M.mad(x, 0x1.715476p+0, r);
    const n = z - r;
    const bb = M.mad(-n, 0x1.7f7d1cp-20, M.mad(-n, 0x1.62e4p-1, x));
    const e: u32 = @as(u32, @bitCast(z)) << 23;
    const k: f32 = @bitCast(e +% @as(u32, @bitCast(@as(f32, 1.0))));
    const u = bb * bb;
    const j = M.mad(M.mad(M.mad(0x1.0e4020p-7, bb, 0x1.573e2ep-5), u, M.mad(0x1.555e66p-3, bb, 0x1.fffdb6p-2)), u, 0x1.ffffecp-1 * bb);
    if (!(@abs(n) > 126)) return M.mad(j, k, k);
    const g: u32 = if (n <= 0) 0x82000000 else 0;
    const s1: f32 = @bitCast(g +% 0x7f000000);
    const s2: f32 = @bitCast(e -% g);
    if (@abs(n) > 192) return s1 * s1;
    return M.mad(s2, j, s2) * s1;
}

/// RMSNorm of rows as lfm3_audio_ops.rmsNorm (each square rounded to f32,
/// the squares summed as the CPU's f64 does, mean = sum / width rounded
/// once), and with `twice` a second one over the result (the depthformer's
/// output norm then its codebook's head norm). Bindings: x, weight, out.
/// Params: width, epsilon's bits, x's first row (bytes), the weights'
/// offset and stride between rows (0: one vector), out's first row, the
/// second weights' offset and stride. Groups (1, rows).
pub fn normRows(s: kir.Storage, caps: Caps, twice: bool) Error!kir.Kernel {
    const threads = rowThreads(caps);
    var k = begin(s, if (twice) "lfm3a_norm2" else "lfm3a_norm", threads);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 8;
    b.needExchange(threads);
    const t = b.tid(0);
    const row = b.gid(1);
    const width = b.param(0);
    const eps = b.as(.f32, b.param(1));
    const nf = b.cvt(.u32, .f32, .rne, R(width));
    const row_bytes = b.shl(R(b.mul(R(row), R(width))), 2);
    const x_base = b.add(R(b.param(2)), R(row_bytes));
    const o_base = b.add(R(b.param(5)), R(row_bytes));
    const chunks = b.shr(R(b.add(R(width), U(threads - 1))), log2(threads));
    const t4 = b.shl(R(t), 2);
    const step = threads * 4;
    for (0..@as(usize, if (twice) 2 else 1)) |pass| {
        const src = if (pass == 0) X else OUT;
        const src_base = if (pass == 0) x_base else o_base;
        const w_base = b.add(R(b.param(if (pass == 0) 3 else 6)), R(b.mul(R(row), R(b.param(if (pass == 0) 4 else 7)))));
        const sum = b.ddZero();
        const c = b.mov(.u32, U(0));
        b.loop();
        {
            const col = b.add(R(b.mul(R(c), U(step))), R(t4));
            const ok = b.icmp(.u32, .lt, R(col), R(b.shl(R(width), 2)));
            const v = b.ld(src, .f32, R(b.add(R(src_base), R(b.sel(.u32, ok, R(col), U(0))))), 0, 5);
            const sq = b.sel(.f32, ok, R(b.fmul(R(v), R(v))), F(0));
            b.ddAccumulate(sum, .{ .hi = sq, .lo = b.mov(.f32, F(0)) });
            b.set(c, .iadd, .u32, R(c), U(1), NO);
            b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
        }
        b.endloop();
        const inverse = b.normInverse(b.xorReduceDD(sum, threads, t), R(nf), R(eps));
        b.set(c, .mov, .u32, U(0), NO, NO);
        b.loop();
        {
            const col = b.add(R(b.mul(R(c), U(step))), R(t4));
            const ok = b.icmp(.u32, .lt, R(col), R(b.shl(R(width), 2)));
            b.if_(ok);
            const v = b.ld(src, .f32, R(b.add(R(src_base), R(col))), 0, 5);
            const w = b.ld(WB, .f32, R(b.add(R(w_base), R(col))), 0, 5);
            b.st(OUT, R(b.add(R(o_base), R(col))), 0, 5, b.fmul(R(b.fmul(R(v), R(inverse))), R(w)));
            b.endif();
            b.set(c, .iadd, .u32, R(c), U(1), NO);
            b.brk(b.icmp(.u32, .ge, R(c), R(chunks)));
        }
        b.endloop();
    }
    try k.finish();
    return k;
}

/// A small head's RMSNorm (f32 squares) then NeoX RoPE by the host's table,
/// in place, as lfm3_audio_gen's attention prepares queries and keys. A
/// workgroup of head_size / 2 threads a (head, position), thread j holding
/// elements j and j + head_size / 2. Bindings: x (f32 [T][heads][head]),
/// weight (head f32), rope (f32 [T][head / 2][2]). Params: heads, epsilon's
/// bits, x's offset, the weights' offset. Groups (heads, T).
pub fn headNormRope(s: kir.Storage, caps: Caps, head_size: u32) Error!kir.Kernel {
    if (head_size < 2 or head_size > 256 or !std.math.isPowerOfTwo(head_size)) return error.Unsupported;
    const half = head_size / 2;
    var k = begin(s, "lfm3a_head", half);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const WB = k.binding();
    const ROPE = k.binding();
    k.param_words = 4;
    b.needExchange(half);
    const t = b.tid(0);
    const h = b.gid(0);
    const tok = b.gid(1);
    const heads = b.param(0);
    const row = b.add(R(b.param(2)), R(b.mul(R(b.add(R(b.mul(R(tok), R(heads))), R(h))), U(head_size * 4))));
    const t4 = b.shl(R(t), 2);
    const lo = b.ld(X, .f32, R(b.add(R(row), R(t4))), 0, 5);
    const hi = b.ld(X, .f32, R(b.add(R(row), R(t4))), half * 4, 5);
    const sq = b.ddAdd(.{ .hi = b.fmul(R(lo), R(lo)), .lo = b.mov(.f32, F(0)) }, .{ .hi = b.fmul(R(hi), R(hi)), .lo = b.mov(.f32, F(0)) });
    const inverse = b.normInverse(b.xorReduceDD(sq, half, t), F(@floatFromInt(head_size)), R(b.as(.f32, b.param(1))));
    const wo = b.add(R(b.param(3)), R(t4));
    const a = b.fmul(R(b.fmul(R(lo), R(inverse))), R(b.ld(WB, .f32, R(wo), 0, 5)));
    const c = b.fmul(R(b.fmul(R(hi), R(inverse))), R(b.ld(WB, .f32, R(wo), half * 4, 5)));
    const cs = b.ldv(ROPE, .f32, R(b.shl(R(b.add(R(b.mul(R(tok), U(half))), R(t))), 3)), 0, 2);
    const cosv = at(cs, 0);
    const sinv = at(cs, 1);
    b.st(X, R(b.add(R(row), R(t4))), 0, 5, b.fsub(R(b.fmul(R(a), R(cosv))), R(b.fmul(R(c), R(sinv)))));
    b.st(X, R(b.add(R(row), R(t4))), half * 4, 5, b.fadd(R(b.fmul(R(a), R(sinv))), R(b.fmul(R(c), R(cosv)))));
    try k.finish();
    return k;
}

/// The depthformer's attention, as lfm3_audio_ops.attendHeadGgml with every
/// key visible: a workgroup a (query head, position), 32 threads (thread j
/// key j, then element j). Scores by ggml_vec_dot_f32's tree, scaled, + 0;
/// the maximum; exps by ggml_v_expf over whole groups of eight keys and the
/// CPU's expf over the rest; the total (groups of eight summed in f32 as
/// ggml does, then all in the CPU's f64 order); weights times the inverse;
/// each element the fused sum over the keys in order; then the head's
/// sigmoid gate (`gated`). Up to 31 keys, heads of 32. Bindings: query
/// (f32 [T][heads][32]), key and value ([T][kv_heads][32]), gate
/// ([T][heads]), out ([T][heads][32]). Params: heads, kv_heads' log2 group,
/// T (the keys), the scale's bits. Groups (heads, T).
pub fn attendGgml(s: kir.Storage, caps: Caps, gated: bool) Error!kir.Kernel {
    const hs = 32;
    var k = begin(s, "lfm3a_attend", 32);
    var b = Builder.init(&k, caps);
    const Q = k.binding();
    const KB = k.binding();
    const VB = k.binding();
    const G = k.binding();
    const OUT = k.binding();
    k.param_words = 4;
    const wbase = k.shared_bytes;
    k.shared_bytes += 32 * 4;
    b.needExchange(32);
    const t = b.tid(0);
    const h = b.gid(0);
    const pos = b.gid(1);
    const heads = b.param(0);
    const n = b.param(2);
    const kvh = b.op2(.shr, .u32, R(h), R(b.param(1)));
    const kv_heads = b.op2(.shr, .u32, R(heads), R(b.param(1)));
    const qrow = b.mul(R(b.add(R(b.mul(R(pos), R(heads))), R(h))), U(hs * 4));
    const valid = b.icmp(.u32, .lt, R(t), R(n));
    const key = b.sel(.u32, valid, R(t), U(0));
    const krow = b.mul(R(b.add(R(b.mul(R(key), R(kv_heads))), R(kvh))), U(hs * 4));
    // ggml_vec_dot_f32(key, query) over one 32-wide step: four 8-lane
    // products, (0 + 2), (1 + 3), (0 + 1), the halves, then pairs
    var p: [32]V = undefined;
    for (0..32) |i| {
        const kv = b.ld(KB, .f32, R(krow), @intCast(4 * i), 5);
        const qv = b.ld(Q, .f32, R(qrow), @intCast(4 * i), 5);
        p[i] = b.fadd(R(b.fmul(R(kv), R(qv))), F(0));
    }
    var s0: [8]V = undefined;
    for (0..8) |l| {
        const a0 = b.fadd(R(p[l]), R(p[16 + l]));
        const a1 = b.fadd(R(p[8 + l]), R(p[24 + l]));
        s0[l] = b.fadd(R(a0), R(a1));
    }
    var t0: [4]V = undefined;
    for (0..4) |i| t0[i] = b.fadd(R(s0[i]), R(s0[i + 4]));
    const dot = b.fadd(R(b.fadd(R(t0[0]), R(t0[1]))), R(b.fadd(R(t0[2]), R(t0[3]))));
    const score = b.fadd(R(b.fmul(R(dot), R(b.as(.f32, b.param(3))))), F(0));
    const ninf = F(-std.math.inf(f32));
    const maximum = b.xorReduce(.fmax, .f32, b.sel(.f32, valid, R(score), ninf), 32, t);
    // exps: ggml's over whole groups of eight keys, expf over the rest
    const d = b.fsub(R(score), R(maximum));
    const grouped = b.icmp(.u32, .lt, R(t), R(b.band(R(n), U(0xfffffff8))));
    const e = b.sel(.f32, valid, R(b.sel(.f32, grouped, R(expGgml(&b, d)), R(b.expCpu(d)))), F(0));
    // the total: every thread gathers the 32 exps (the same order everywhere)
    var ev: [32]V = undefined;
    for (0..32) |i| ev[i] = b.shfl(.idx, e, U(@intCast(i)));
    const groups = b.shr(R(n), 3);
    var total = b.ddZero();
    for (0..4) |g| {
        var q: [4]V = undefined;
        for (0..4) |i| q[i] = b.fadd(R(ev[8 * g + i + 4]), R(ev[8 * g + i]));
        const gsum = b.fadd(R(b.fadd(R(q[0]), R(q[2]))), R(b.fadd(R(q[1]), R(q[3]))));
        const in = b.icmp(.u32, .lt, U(@intCast(g)), R(groups));
        total = b.ddAdd(total, .{ .hi = b.sel(.f32, in, R(gsum), F(0)), .lo = b.mov(.f32, F(0)) });
    }
    // (the tail: the keys past the groups, in order)
    for (0..32) |i| {
        const tail = b.pand(b.icmp(.u32, .ge, U(@intCast(i)), R(b.shl(R(groups), 3))), b.icmp(.u32, .lt, U(@intCast(i)), R(n)));
        total = b.ddAdd(total, .{ .hi = b.sel(.f32, tail, R(ev[i]), F(0)), .lo = b.mov(.f32, F(0)) });
    }
    const inverse = b.ddRecip(total);
    const w = b.fmul(R(e), R(inverse));
    b.sts(R(b.shl(R(t), 2)), wbase, w, 1);
    b.barrier();
    // element t: ggml_vec_dot_f32(column, weights) for fewer than 32 keys:
    // (0 + 0) + (0 + 0), then fused products in key order
    const acc = b.mov(.f32, F(0));
    const kk = b.mov(.u32, U(0));
    b.if_(b.icmp(.u32, .ne, R(n), U(0)));
    b.loop();
    {
        const vrow = b.mul(R(b.add(R(b.mul(R(kk), R(kv_heads))), R(kvh))), U(hs * 4));
        const v = b.ld(VB, .f32, R(b.add(R(vrow), R(b.shl(R(t), 2)))), 0, 5);
        const wk = b.lds(.f32, R(b.shl(R(kk), 2)), wbase, 1);
        b.set(acc, .mov, .f32, R(b.fma(R(v), R(wk), R(acc))), NO, NO);
        b.set(kk, .iadd, .u32, R(kk), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(kk), R(n)));
    }
    b.endloop();
    b.endif();
    var out = acc;
    if (gated) {
        const g = b.ld(G, .f32, R(b.shl(R(b.add(R(b.mul(R(pos), R(heads))), R(h))), 2)), 0, 5);
        out = b.fmul(R(out), R(b.sigmoid(g)));
    }
    b.st(OUT, R(b.add(R(qrow), R(b.shl(R(t), 2)))), 0, 5, out);
    try k.finish();
    return k;
}

/// gate = silu(gate) * up elementwise with ggml's silu (x / (1 +
/// ggml_v_expf(0 - x))), as lfm3_audio_gen's FFN. Bindings: gate (updated),
/// up. Params: count. Groups (count / 64 rounded up).
pub fn gluGgml(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3a_glu", 64);
    var b = Builder.init(&k, caps);
    const GB = k.binding();
    const UB = k.binding();
    k.param_words = 1;
    const i = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    b.if_(b.icmp(.u32, .lt, R(i), R(b.param(0))));
    const off = b.shl(R(i), 2);
    const g = b.ld(GB, .f32, R(off), 0, 5);
    const silu = b.fdiv(R(g), R(b.fadd(F(1.0), R(expGgml(&b, b.fsub(F(0), R(g)))))));
    b.st(GB, R(off), 0, 5, b.fmul(R(silu), R(b.ld(UB, .f32, R(off), 0, 5))));
    b.endif();
    try k.finish();
    return k;
}

/// The depthformer's input rows: row `book` = the projected state's row +
/// the code's embedding (a Q8_0 row of the table, dequantized: d * q) or
/// the mask embedding when the code is -1. Bindings: projected (f32 [12][d]),
/// weights (the model: table and mask), out (f32 [12][d]). Params: d, the
/// table's offset, its row bytes, the vocabulary, the mask's offset, then
/// the twelve codes (i32 bits). Groups (d / 64 rounded up, 12).
pub fn depthInput(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3a_input", 64);
    var b = Builder.init(&k, caps);
    const P = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 5 + 12;
    const e = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    const book = b.gid(1);
    const d = b.param(0);
    b.if_(b.icmp(.u32, .lt, R(e), R(d)));
    // the book's code: params 5 + book (selected: a param's word is static)
    var code = b.mov(.u32, R(b.param(5)));
    for (1..12) |i| code = b.sel(.u32, b.icmp(.u32, .eq, R(book), U(@intCast(i))), R(b.param(@intCast(5 + i))), R(code));
    const masked = b.icmp(.i32, .lt, R(code), I(0));
    const off = b.shl(R(b.add(R(b.mul(R(book), R(d))), R(e))), 2);
    const base = b.ld(P, .f32, R(off), 0, 5);
    const mask = b.ld(WB, .f32, R(b.add(R(b.param(4)), R(b.shl(R(e), 2)))), 0, 5);
    // the table row (book * vocabulary + code), block e / 32, quant e % 32
    const trow = b.add(R(b.mul(R(book), R(b.param(3)))), R(b.sel(.u32, masked, U(0), R(code))));
    const blk = b.add(R(b.add(R(b.param(1)), R(b.mul(R(trow), R(b.param(2)))))), R(b.mul(R(b.shr(R(e), 5)), U(Q8_0_BLOCK))));
    const dh = b.half(b.ld(WB, .u32, R(blk), 0, 4), false);
    const q = b.ld(WB, .i32, R(b.add(R(blk), R(b.add(R(b.band(R(e), U(31))), U(2))))), 0, 3);
    const emb = b.fmul(R(dh), R(b.cvt(.i32, .f32, .rne, R(q))));
    b.st(OUT, R(off), 0, 5, b.fadd(R(base), R(b.sel(.f32, masked, R(mask), R(emb)))));
    b.endif();
    try k.finish();
    return k;
}

/// out[t][i] += v[i] (a bias). Bindings: out, v. Params: width, v's
/// offset. Groups (width / 64 rounded up, T).
pub fn addBias(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3a_bias", 64);
    var b = Builder.init(&k, caps);
    const OUT = k.binding();
    const VB = k.binding();
    k.param_words = 2;
    const i = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    const width = b.param(0);
    b.if_(b.icmp(.u32, .lt, R(i), R(width)));
    const off = b.shl(R(b.add(R(b.mul(R(b.gid(1)), R(width))), R(i))), 2);
    const v = b.ld(VB, .f32, R(b.add(R(b.param(1)), R(b.shl(R(i), 2)))), 0, 5);
    b.st(OUT, R(off), 0, 5, b.fadd(R(b.ld(OUT, .f32, R(off), 0, 5)), R(v)));
    b.endif();
    try k.finish();
    return k;
}

// ── Host helpers ────────────────────────────────────────────────────────────

/// The cosines and sines prepare rotates by, for `tokens` positions from
/// `first_position`: exactly lfm3_executor.ropeNeox's angles and its f32
/// @cos and @sin. out[(t * half + lane) * 2] is the cosine, + 1 the sine.
pub fn ropeTable(out: []f32, first_position: usize, tokens: usize, head_size: usize, base: f32, factors: ?[]const f32) void {
    const half_size = head_size / 2;
    const exponent = -2.0 / @as(f64, @floatFromInt(head_size));
    const theta_scale: f32 = @floatCast(@exp(exponent * @log(@as(f64, base))));
    for (0..tokens) |t| {
        var theta: f32 = @floatFromInt(first_position + t);
        for (0..half_size) |lane| {
            const angle = if (factors) |divisors| theta / divisors[lane] else theta;
            out[(t * half_size + lane) * 2] = @cos(angle);
            out[(t * half_size + lane) * 2 + 1] = @sin(angle);
            theta *= theta_scale;
        }
    }
}

/// The host's twin of the kernels' exp (Builder.expCpu): compiler_rt's
/// expf (musl's), line for line, for tests and for hosts without it.
pub fn expRef(x_in: f32) f32 {
    const half = [_]f32{ 0.5, -0.5 };
    var x = x_in;
    var hx: u32 = @bitCast(x);
    const sign: i32 = @intCast(hx >> 31);
    hx &= 0x7FFFFFFF;
    if (std.math.isNan(x)) return x;
    if (hx >= 0x42AEAC50) {
        if (hx > 0x7F800000) return x;
        if (hx >= 0x42b17218 and sign == 0) return x * 0x1.0p127;
        if (sign != 0 and hx >= 0x42CFF1B5) return 0;
    }
    var k: i32 = undefined;
    var hi: f32 = undefined;
    var lo: f32 = undefined;
    if (hx > 0x3EB17218) {
        if (hx > 0x3F851592) {
            k = @intFromFloat(@as(f32, 1.4426950216e+0) * x + half[@intCast(sign)]);
        } else {
            k = 1 - sign - sign;
        }
        const fk: f32 = @floatFromInt(k);
        hi = x - fk * @as(f32, 6.9314575195e-1);
        lo = fk * @as(f32, 1.4286067653e-6);
        x = hi - lo;
    } else if (hx > 0x39000000) {
        k = 0;
        hi = x;
        lo = 0;
    } else {
        return 1 + x;
    }
    const xx = x * x;
    const c = x - xx * (@as(f32, 1.6666625440e-1) + xx * @as(f32, -2.7667332906e-3));
    const y = 1 + (x * c / (2 - c) - lo + hi);
    if (k == 0) return y;
    return std.math.scalbn(y, k);
}

// ── Tests (on the reference interpreter, against the CPU's kernels) ─────────

const quantized = @import("quantized_linear");
const interp = gpu.interp;

const TestRig = struct {
    var insts: [16384]kir.Inst = undefined;
    var tys: [16384]Ty = undefined;
    var work: [24 << 20]u8 align(64) = undefined;
    var a: [1 << 20]u8 align(16) = undefined;
    var b: [1 << 20]u8 align(16) = undefined;
    var c: [1 << 20]u8 align(16) = undefined;
    var d: [1 << 20]u8 align(16) = undefined;
    var e: [4 << 20]u8 align(16) = undefined;
    var f: [1 << 20]u8 align(16) = undefined;
    var g: [1 << 20]u8 align(16) = undefined;
    var x: [MAX_TOKENS * 7680]f32 = undefined;
    var q8k: [MAX_TOKENS * 30]quantized.Q8KBlock = undefined;
    var q80: [MAX_TOKENS * 240]quantized.Q80Block = undefined;
    var ccache: [2 * 2 * 4 * 1100 * HEAD_SIZE]u16 = undefined;
};

fn testStorage() kir.Storage {
    return .{ .insts = &TestRig.insts, .tys = &TestRig.tys };
}

fn runOn(k: *const kir.Kernel, caps: Caps, groups: [3]u32, bindings: []const []u8, params: []const u32) !interp.Stats {
    var w = gpu.Work.init(&TestRig.work);
    var trap: interp.Trap = .{};
    return interp.runKernel(k, caps, groups, bindings, params, &w, &trap) catch |e| {
        std.debug.print("{s}: {s}, trap {s} at {d} ({s}), group {any}, thread {d}, binding {d}, offset {d}\n", .{
            k.name, @errorName(e), @tagName(trap.what), trap.pc, if (trap.pc < k.n) @tagName(k.insts[trap.pc].op) else "-", trap.group, trap.thread, trap.binding, trap.offset,
        });
        return e;
    };
}

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn unit(seed: *u32) f32 {
    return @as(f32, @floatFromInt(lcg(seed) >> 8)) / 16777216.0 - 0.5;
}

fn f32s(bytes: []u8) []f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, bytes));
}

/// Q8_K blocks as the kernels' three arrays.
fn splitQ8K(blocks: []const quantized.Q8KBlock, aq: []u8, ad: []u8, as_: []u8) void {
    for (blocks, 0..) |blk, i| {
        @memcpy(aq[i * QK_K ..][0..QK_K], std.mem.asBytes(&blk.qs));
        @memcpy(ad[i * 4 ..][0..4], std.mem.asBytes(&blk.d));
        @memcpy(as_[i * 32 ..][0..32], std.mem.asBytes(&blk.bsums));
    }
}

fn caps32(fused: bool, subgroup: u32) Caps {
    var c = gpu.interp_caps;
    c.fused_fma = fused;
    c.mad = if (fused) .fused else .unfused;
    c.subgroup = subgroup;
    return c;
}

fn testMatrix(caps: Caps, lay: Layout, format: Format, tokens: u32, rows: u32, blocks: u32) !void {
    const T = TestRig;
    const k_cols: u32 = blocks * (if (format == .q8_0) @as(u32, QK8_0) else QK_K);
    const block_bytes: u32 = switch (format) {
        .q4_k => Q4_K_BLOCK,
        .q6_k => Q6_K_BLOCK,
        .q8_0 => Q8_0_BLOCK,
    };
    const row_bytes = blocks * block_bytes;
    // (weights and results away from their bindings' starts: the offsets)
    const w_off: u32 = 48;
    const out_off: u32 = 32;
    const w = T.a[w_off..][0 .. rows * row_bytes];
    var seed: u32 = 99 + rows + blocks * 7 + tokens;
    for (w, 0..) |*byte, i| byte.* = @truncate(lcg(&seed) >> 13 ^ i);
    for (0..rows * blocks) |blk| {
        const base = blk * block_bytes;
        switch (format) {
            .q4_k => {
                std.mem.writeInt(u16, w[base..][0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
                std.mem.writeInt(u16, w[base + 2 ..][0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
            },
            .q6_k => std.mem.writeInt(u16, w[base + 208 ..][0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little),
            .q8_0 => {
                const sign: u32 = (lcg(&seed) >> 7) & 1;
                std.mem.writeInt(u16, w[base..][0..2], @intCast((0x1400 + (lcg(&seed) >> 22)) | (sign << 15)), .little);
                for (w[base + 2 .. base + 34]) |*q| q.* = @bitCast(@as(i8, @intCast(@as(i32, @intCast((lcg(&seed) >> 8) % 255)) - 127)));
            },
        }
    }
    const x = &T.x;
    for (x[0 .. tokens * k_cols]) |*v| v.* = unit(&seed) * 3.0;
    const q8k = &T.q8k;
    const q80 = &T.q80;
    if (format == .q8_0) {
        try quantized.quantizeQ80(x[0 .. tokens * k_cols], q80[0 .. tokens * blocks]);
        for (q80[0 .. tokens * blocks], 0..) |blk, i| {
            @memcpy(T.b[i * QK8_0 ..][0..QK8_0], std.mem.asBytes(&blk.qs));
            @memcpy(T.c[i * 4 ..][0..4], std.mem.asBytes(&blk.d));
        }
    } else {
        try quantized.quantizeQ8K(x[0 .. tokens * k_cols], q8k[0 .. tokens * blocks]);
        splitQ8K(q8k[0 .. tokens * blocks], &T.b, &T.c, &T.d);
    }
    var k = try matrixWith(testStorage(), caps, lay, format, tokens);
    const p = MatrixParams{ .row_bytes = row_bytes, .blocks = blocks, .rows = rows, .out_stride = rows * 4, .weights = w_off, .out = out_off };
    _ = try runOn(&k, caps, matrixGroupsWith(lay, rows), &.{ T.a[0 .. w_off + rows * row_bytes], T.b[0 .. tokens * k_cols], T.c[0 .. tokens * blocks * 4], T.d[0 .. tokens * blocks * 32 + 4], T.e[0 .. out_off + tokens * rows * 4] }, &p.words(format));
    const got = f32s(T.e[out_off..][0 .. tokens * rows * 4]);
    var mismatches: usize = 0;
    for (0..rows) |row| {
        const wrow = w[row * row_bytes ..][0..row_bytes];
        for (0..tokens) |t| {
            const want = switch (format) {
                .q4_k => quantized.dotQ4KQ8KTile(1, wrow, .{q8k[t * blocks ..].ptr}, blocks)[0],
                .q6_k => quantized.dotQ6KQ8KTile(1, wrow, .{q8k[t * blocks ..].ptr}, blocks)[0],
                .q8_0 => quantized.dotQ80Q80Tile(1, wrow, .{q80[t * blocks ..].ptr}, blocks)[0],
            };
            const g = got[t * rows + row];
            if (@as(u32, @bitCast(g)) != @as(u32, @bitCast(want))) {
                if (mismatches < 5) std.debug.print("{s} lanes {d} x{d}: row {d} token {d}: {e} want {e}\n", .{ @tagName(format), lay.lanes, tokens, row, t, g, want });
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "Q4_K x Q8_K: the CPU's bits, every layout, 1 to 8 tokens, rows not in whole groups" {
    for ([_]u32{ 1, 2, 4 }) |lanes| {
        try testMatrix(caps32(true, 32), .{ .lanes = lanes }, .q4_k, 1, 21, 3);
        try testMatrix(caps32(false, 64), .{ .lanes = lanes }, .q4_k, 3, 16, 2);
    }
    try testMatrix(caps32(true, 32), .{ .lanes = 4 }, .q4_k, 8, 40, 2);
    try testMatrix(caps32(true, 128), .{ .lanes = 1 }, .q4_k, 5, 8, 30);
}

test "Q6_K x Q8_K: the CPU's bits, odd blocks two bytes off, odd block counts" {
    for ([_]u32{ 1, 2, 4 }) |lanes| {
        try testMatrix(caps32(true, 32), .{ .lanes = lanes }, .q6_k, 1, 21, 3);
        try testMatrix(caps32(false, 64), .{ .lanes = lanes }, .q6_k, 2, 9, 30);
    }
    try testMatrix(caps32(true, 32), .{ .lanes = 4 }, .q6_k, 8, 33, 1);
}

test "Q8_0 x Q8_0: the CPU's fused bits, ffma where the GPU fuses, the exact emulation where not" {
    for ([_]u32{ 1, 4 }) |lanes| {
        try testMatrix(caps32(true, 32), .{ .lanes = lanes }, .q8_0, 1, 21, 37);
        try testMatrix(caps32(false, 32), .{ .lanes = lanes }, .q8_0, 8, 16, 24);
    }
}

fn quantInput(x: []f32, seed: *u32) void {
    for (x, 0..) |*v, i| {
        v.* = unit(seed) * 6.0;
        // a block of zeros, ties of magnitude of either sign
        if (i / QK_K == 3) v.* = 0;
        if (i % 997 == 5) v.* = 9.0;
        if (i % 997 == 9) v.* = -9.0;
        if (i % 331 == 7) v.* = -9.0;
    }
}

fn expectQ8K(cpu: []const quantized.Q8KBlock, aq: []const u8, ad: []const u8, as_: []const u8) !void {
    for (cpu, 0..) |blk, i| {
        const d: f32 = @bitCast(std.mem.readInt(u32, ad[i * 4 ..][0..4], .little));
        if (@as(u32, @bitCast(blk.d)) != @as(u32, @bitCast(d))) {
            std.debug.print("block {d}: d {e} want {e}\n", .{ i, d, blk.d });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&blk.qs), aq[i * QK_K ..][0..QK_K]);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&blk.bsums), as_[i * 32 ..][0..32]);
    }
}

test "fma: the emulation where the GPU does not fuse is the CPU's @mulAdd, on 4 million triples" {
    const T = TestRig;
    const caps = caps32(false, 32);
    var k = begin(testStorage(), "fma", 64);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const Y = k.binding();
    const ix4 = b.shl(R(b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)))), 2);
    const o12 = b.mul(R(ix4), U(3));
    const r = b.fma(R(b.ld(X, .f32, R(o12), 0, 5)), R(b.ld(X, .f32, R(o12), 4, 5)), R(b.ld(X, .f32, R(o12), 8, 5)));
    b.st(Y, R(ix4), 0, 5, r);
    try k.finish();
    const n = 1 << 16;
    const xs = f32s(T.a[0 .. 3 * n * 4]);
    const ys = f32s(T.b[0 .. n * 4]);
    var seed: u32 = 12;
    var mismatches: usize = 0;
    for (0..64) |round| {
        for (0..n) |i| {
            // products near the addend (cancellation), moderate exponents
            const a = unit(&seed) * @as(f32, @floatFromInt(1 + (lcg(&seed) >> 20)));
            const c2 = unit(&seed) * 3;
            xs[3 * i] = a;
            xs[3 * i + 1] = c2;
            xs[3 * i + 2] = if (round % 2 == 0) -(a * c2) * (1 + unit(&seed) * 1e-6) else unit(&seed) * 100;
        }
        _ = try runOn(&k, caps, .{ n / 64, 1, 1 }, &.{ T.a[0 .. 3 * n * 4], T.b[0 .. n * 4] }, &.{});
        for (0..n) |i| {
            const want = @mulAdd(f32, xs[3 * i], xs[3 * i + 1], xs[3 * i + 2]);
            if (@as(u32, @bitCast(want)) != @as(u32, @bitCast(ys[i]))) {
                if (mismatches < 4) std.debug.print("fma({e}, {e}, {e}) = {e}, want {e}\n", .{ xs[3 * i], xs[3 * i + 1], xs[3 * i + 2], ys[i], want });
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "Q8_K quantization: quantizeQ8K's bits (a zero block, magnitude ties), any subgroup" {
    const T = TestRig;
    for ([_]u32{ 8, 32, 64 }) |sg| {
        var caps = caps32(false, sg);
        // (groups of 64 on the narrow one: two blocks a workgroup)
        if (sg == 8) caps.max_group = 64;
        const tokens = 3;
        const k_cols = 7680;
        const blocks = k_cols / QK_K;
        var seed: u32 = 5;
        const x = f32s(T.a[64..][0 .. tokens * k_cols * 4]);
        quantInput(x, &seed);
        var k = try quant(testStorage(), caps, .plain);
        _ = try runOn(&k, caps, quantGroups(caps, .plain, k_cols, tokens), &.{ T.a[0 .. 64 + tokens * k_cols * 4], T.a[0..16], T.a[0..16], T.b[0 .. tokens * k_cols], T.c[0 .. tokens * blocks * 4], T.d[0 .. tokens * blocks * 32] }, &quantParams(k_cols, 0, 64, 0, 0));
        var cpu: [tokens * blocks]quantized.Q8KBlock = undefined;
        try quantized.quantizeQ8K(x, &cpu);
        try expectQ8K(&cpu, &T.b, &T.c, &T.d);
    }
}

/// lfm3_executor's rmsNormRow.
fn rmsNormRow(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
    var squares: f64 = 0;
    for (input) |value| squares += @as(f64, value) * value;
    const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(mean + epsilon);
    for (input, weight, output[0..input.len]) |value, scale, *destination| destination.* = value * inverse * scale;
}

test "RMSNorm then Q8_K: the CPU's normalized rows (its f64 sums met by double-f32), then quantizeQ8K's bits" {
    const T = TestRig;
    for ([_]u32{ 8, 32, 128 }) |sg| for ([_]bool{ false, true }) |fused| {
        var caps = caps32(fused, sg);
        if (sg == 8 and fused) caps.max_group = 64;
        const tokens = 4;
        const k_cols = 2048 + 256;
        const blocks = k_cols / QK_K;
        var seed: u32 = 17 + sg;
        const x = f32s(T.a[0 .. tokens * k_cols * 4]);
        quantInput(x, &seed);
        const wv = f32s(T.e[32..][0 .. k_cols * 4]);
        for (wv) |*v| v.* = 0.5 + unit(&seed) + 0.5;
        var k = try quant(testStorage(), caps, .norm);
        _ = try runOn(&k, caps, quantGroups(caps, .norm, k_cols, tokens), &.{ T.a[0 .. tokens * k_cols * 4], T.e[0 .. 32 + k_cols * 4], T.f[0 .. 16 + tokens * k_cols * 4], T.b[0 .. tokens * k_cols], T.c[0 .. tokens * blocks * 4], T.d[0 .. tokens * blocks * 32] }, &quantParams(k_cols, 1e-5, 0, 32, 16));
        const y = f32s(T.f[16..][0 .. tokens * k_cols * 4]);
        var want: [tokens * k_cols]f32 = undefined;
        var mismatches: usize = 0;
        for (0..tokens) |t| {
            rmsNormRow(x[t * k_cols ..][0..k_cols], wv, want[t * k_cols ..][0..k_cols], 1e-5);
            // (the zero block's row: the CPU's too)
        }
        for (want, y) |a, b| {
            if (@as(u32, @bitCast(a)) != @as(u32, @bitCast(b))) mismatches += 1;
        }
        if (mismatches != 0) std.debug.print("norm: {d} of {d} values differ from the CPU's\n", .{ mismatches, want.len });
        try std.testing.expectEqual(@as(usize, 0), mismatches);
        var cpu: [tokens * blocks]quantized.Q8KBlock = undefined;
        try quantized.quantizeQ8K(y, &cpu);
        try expectQ8K(&cpu, &T.b, &T.c, &T.d);
    };
}

test "exp: the CPU's @exp is compiler_rt's expf (expRef's bits); the kernels' too, so SwiGLU then Q8_K exact" {
    // the host twin against the CPU's @exp, everywhere it matters
    var mismatches: usize = 0;
    var x: f32 = -110.0;
    while (x < 92.0) : (x += 0.000731) {
        if (@as(u32, @bitCast(expRef(x))) != @as(u32, @bitCast(@exp(x)))) mismatches += 1;
    }
    var sweep: u32 = 1;
    for (0..2_000_000) |_| {
        const bits = (lcg(&sweep) & 0x7fffffff) % 0x42d00000 | (lcg(&sweep) & 0x80000000);
        const v: f32 = @bitCast(bits);
        if (@as(u32, @bitCast(expRef(v))) != @as(u32, @bitCast(@exp(v)))) mismatches += 1;
    }
    if (mismatches != 0) std.debug.print("expRef differs from @exp {d} times\n", .{mismatches});
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    // SwiGLU in the kernel against the CPU's formula
    const T = TestRig;
    const caps = caps32(false, 32);
    const tokens = 2;
    const k_cols = 1024 + 512;
    const blocks = k_cols / QK_K;
    var seed: u32 = 23;
    const g = f32s(T.a[0 .. tokens * k_cols * 4]);
    const u = f32s(T.e[0 .. tokens * k_cols * 4]);
    for (g, u, 0..) |*gv, *uv, i| {
        gv.* = unit(&seed) * 24.0;
        uv.* = unit(&seed) * 4.0;
        if (i == 77) gv.* = -95.0;
        if (i == 78) gv.* = 90.0;
    }
    var k = try quant(testStorage(), caps, .swiglu);
    _ = try runOn(&k, caps, quantGroups(caps, .swiglu, k_cols, tokens), &.{ T.a[0 .. tokens * k_cols * 4], T.e[0 .. tokens * k_cols * 4], T.a[0..16], T.b[0 .. tokens * k_cols], T.c[0 .. tokens * blocks * 4], T.d[0 .. tokens * blocks * 32] }, &quantParams(k_cols, 0, 0, 0, 0));
    var v: [tokens * k_cols]f32 = undefined;
    for (&v, g, u) |*o, gv, uv| o.* = (gv / (1.0 + @exp(-gv))) * uv;
    var cpu: [tokens * blocks]quantized.Q8KBlock = undefined;
    try quantized.quantizeQ8K(&v, &cpu);
    try expectQ8K(&cpu, &T.b, &T.c, &T.d);
}

test "expCpu in KIR: expRef's bits on 4 million arguments, specials included" {
    const T = TestRig;
    const caps = caps32(false, 32);
    var k = begin(testStorage(), "exp", 64);
    var b = Builder.init(&k, caps);
    const X = k.binding();
    const Y = k.binding();
    const off = b.shl(R(b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)))), 2);
    b.st(Y, R(off), 0, 5, b.expCpu(b.ld(X, .f32, R(off), 0, 5)));
    try k.finish();
    const n = 1 << 18;
    const xs = f32s(T.a[0 .. n * 4]);
    const ys = f32s(T.b[0 .. n * 4]);
    var seed: u32 = 3;
    for (0..16) |round| {
        for (xs, 0..) |*v, i| {
            const bits = if (round < 12) ((lcg(&seed) & 0x7fffffff) % 0x42d80000) | (lcg(&seed) & 0x80000000) else lcg(&seed);
            v.* = @bitCast(bits);
            if (round == 15 and i < 8) v.* = ([8]f32{ 0, -0.0, std.math.inf(f32), -std.math.inf(f32), 88.72, -103.98, 1e-30, std.math.nan(f32) })[i];
        }
        _ = try runOn(&k, caps, .{ n / 64, 1, 1 }, &.{ T.a[0 .. n * 4], T.b[0 .. n * 4] }, &.{});
        for (xs, ys) |v, got| {
            const want = expRef(v);
            if (std.math.isNan(want)) {
                try std.testing.expect(std.math.isNan(got));
                continue;
            }
            if (@as(u32, @bitCast(want)) != @as(u32, @bitCast(got))) {
                std.debug.print("exp({e}) = {e}, want {e}\n", .{ v, got, want });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "Q8_0 quantization: quantizeQ80's bits (a zero block, ties, a last partial group)" {
    const T = TestRig;
    const caps = caps32(false, 32);
    const tokens = 3;
    const k_cols = 32 * 37;
    const blocks = k_cols / QK8_0;
    var seed: u32 = 11;
    const x = f32s(T.a[16..][0 .. tokens * k_cols * 4]);
    for (x, 0..) |*v, i| {
        v.* = unit(&seed) * 6.0;
        if (i / QK8_0 == 2) v.* = 0;
        if (i % 331 == 5) v.* = 9.0;
        if (i % 331 == 9) v.* = -9.0;
        if (i % 331 == 13) v.* = 9.0 * 2.5 / 127.0;
    }
    var k = try q80Quant(testStorage(), caps);
    _ = try runOn(&k, caps, q80Groups(k_cols, tokens), &.{ T.a[0 .. 16 + tokens * k_cols * 4], T.b[0 .. tokens * k_cols], T.c[0 .. tokens * blocks * 4] }, &.{ k_cols, blocks, 16 });
    var cpu: [tokens * blocks]quantized.Q80Block = undefined;
    try quantized.quantizeQ80(x, &cpu);
    for (cpu, 0..) |blk, i| {
        const d: f32 = @bitCast(std.mem.readInt(u32, T.c[i * 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, @bitCast(blk.d)), @as(u32, @bitCast(d)));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&blk.qs), T.b[i * QK8_0 ..][0..QK8_0]);
    }
}

test "residual: hidden += rmsnorm(block) * w, and += block, the CPU's bits" {
    const T = TestRig;
    for ([_]bool{ true, false }) |postnorm| {
        const caps = caps32(true, 32);
        const tokens = 3;
        const width = 1024 + 256;
        var seed: u32 = 31;
        const hid = f32s(T.a[0 .. tokens * width * 4]);
        const blk = f32s(T.b[0 .. tokens * width * 4]);
        const wv = f32s(T.c[64..][0 .. width * 4]);
        for (hid) |*v| v.* = unit(&seed) * 8;
        for (blk) |*v| v.* = unit(&seed) * 3;
        for (wv) |*v| v.* = 0.75 + unit(&seed);
        var want: [tokens * width]f32 = undefined;
        for (0..tokens) |t| {
            var row: [width]f32 = undefined;
            @memcpy(&row, blk[t * width ..][0..width]);
            if (postnorm) rmsNormRow(&row, wv, &row, 1e-5);
            for (want[t * width ..][0..width], hid[t * width ..][0..width], row) |*o, h, r| o.* = h + r;
        }
        var k = try residual(testStorage(), caps, postnorm);
        _ = try runOn(&k, caps, .{ 1, tokens, 1 }, &.{ T.a[0 .. tokens * width * 4], T.b[0 .. tokens * width * 4], T.c[0 .. 64 + width * 4] }, &.{ width, @as(u32, @bitCast(@as(f32, 1e-5))), 64 });
        for (want, hid) |a, b| try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
    }
}

test "short convolution: the CPU's floats exactly, the state carried" {
    const T = TestRig;
    const caps = caps32(true, 32);
    const hidden = 320;
    const tokens = 5;
    const taps = 3;
    var seed: u32 = 31;
    const mixed = f32s(T.a[0 .. tokens * 3 * hidden * 4]);
    const tw = f32s(T.b[32..][0 .. hidden * taps * 4]);
    const state = f32s(T.c[64..][0 .. 2 * hidden * 4]);
    for (mixed) |*v| v.* = unit(&seed) * 2;
    for (tw) |*v| v.* = unit(&seed) * 2;
    for (state) |*v| v.* = unit(&seed) * 2;
    var cpu_state: [2 * hidden]f32 = undefined;
    @memcpy(&cpu_state, state);
    var cpu_out: [tokens * hidden]f32 = undefined;
    // lfm3_executor.shortConvChannels
    var window: [16]f32 = undefined;
    for (0..hidden) |channel| {
        for (0..taps - 1) |row| window[row] = cpu_state[row * hidden + channel];
        const weights = tw[channel * taps ..][0..taps];
        for (0..tokens) |slot| {
            const row = mixed[slot * 3 * hidden ..][0 .. 3 * hidden];
            window[taps - 1] = row[channel] * row[2 * hidden + channel];
            var sum: f32 = 0;
            for (window[0..taps], weights) |input, weight| sum += input * weight;
            cpu_out[slot * hidden + channel] = row[hidden + channel] * sum;
            for (0..taps - 1) |shift| window[shift] = window[shift + 1];
        }
        for (0..taps - 1) |row| cpu_state[row * hidden + channel] = window[row];
    }
    var k = try conv(testStorage(), caps, taps);
    _ = try runOn(&k, caps, convGroups(hidden), &.{ T.a[0 .. tokens * 3 * hidden * 4], T.b[0 .. 32 + hidden * taps * 4], T.c[0 .. 64 + 2 * hidden * 4], T.d[0 .. tokens * hidden * 4] }, &.{ hidden, tokens, 32, 64 });
    const got = f32s(T.d[0 .. tokens * hidden * 4]);
    for (cpu_out, got) |a, b| try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
    for (cpu_state, state) |a, b| try std.testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
}

fn f16r(v: f32) f32 {
    return @floatCast(@as(f16, @floatCast(v)));
}

fn halfOf(bits: u16) f32 {
    return @floatCast(@as(f16, @bitCast(bits)));
}

/// lfm3_executor's PrepareTask then AttentionTask,
/// against prepare, scores, softmax, values and combine.
fn testAttention(caps: Caps, heads: u32, kv_heads: u32, context: u32, tokens: u32, first: u32, window: u32, hg: u32, tt: u32) !f64 {
    const T = TestRig;
    const hd = HEAD_SIZE;
    const max_kv = kv_heads;
    const slot = 1;
    const span: u32 = 1024;
    const chunks: u32 = span / VALUE_CHUNK + 2;
    var seed: u32 = 77 + first;
    const q = f32s(T.a[0 .. tokens * heads * hd * 4]);
    const kb = f32s(T.b[0 .. tokens * kv_heads * hd * 4]);
    const vb = f32s(T.b[tokens * kv_heads * hd * 4 ..][0 .. tokens * kv_heads * hd * 4]);
    const norms = f32s(T.c[0 .. 2 * hd * 4]);
    const rope_t = f32s(T.c[2 * hd * 4 ..][0 .. tokens * 64 * 2 * 4]);
    const gate = f32s(T.d[0 .. tokens * heads * 4]);
    const kv_bytes = 2 * 2 * max_kv * context * hd * 2;
    const cache: []u16 = @alignCast(std.mem.bytesAsSlice(u16, T.e[0..kv_bytes]));
    for (q) |*v| v.* = unit(&seed) * 4;
    for (kb) |*v| v.* = unit(&seed) * 4;
    for (vb) |*v| v.* = unit(&seed) * 2;
    for (norms) |*v| v.* = 1.0 + unit(&seed) * 0.5;
    for (gate) |*v| v.* = unit(&seed) * 4;
    for (cache) |*c| c.* = @bitCast(@as(f16, @floatCast(unit(&seed) * 2.0)));
    ropeTable(rope_t, first, tokens, hd, 10000.0, null);
    // CPU
    var cq: [8 * 8 * HEAD_SIZE]f32 = undefined;
    @memcpy(cq[0..q.len], q);
    var ck: [8 * 8 * HEAD_SIZE]f32 = undefined;
    @memcpy(ck[0..kb.len], kb);
    const ccache = &T.ccache;
    @memcpy(ccache[0..cache.len], cache);
    const CacheRow = struct {
        fn at(ctx: u32, mkv: u32, v: bool, head: usize, position: usize) usize {
            return ((((slot * 2 + @as(usize, @intFromBool(v))) * mkv + head) * ctx) + position) * HEAD_SIZE;
        }
    };
    for (0..tokens) |t| {
        const pos = first + t;
        for (0..heads) |h| rmsNormRow(cq[(t * heads + h) * hd ..][0..hd], norms[0..hd], cq[(t * heads + h) * hd ..][0..hd], 1e-5);
        for (0..kv_heads) |h| rmsNormRow(ck[(t * kv_heads + h) * hd ..][0..hd], norms[hd..], ck[(t * kv_heads + h) * hd ..][0..hd], 1e-5);
        for ([2]bool{ false, true }) |is_k| {
            const n = if (is_k) kv_heads else heads;
            const vals = if (is_k) ck[t * kv_heads * hd ..][0 .. n * hd] else cq[t * heads * hd ..][0 .. n * hd];
            for (0..hd / 2) |lane| {
                const cosv = rope_t[(t * 64 + lane) * 2];
                const sinv = rope_t[(t * 64 + lane) * 2 + 1];
                for (0..n) |head| {
                    const row = vals[head * hd ..][0..hd];
                    const low = row[lane];
                    const high = row[lane + hd / 2];
                    row[lane] = low * cosv - high * sinv;
                    row[lane + hd / 2] = low * sinv + high * cosv;
                }
            }
        }
        for (cq[t * heads * hd ..][0 .. heads * hd]) |*e| e.* = f16r(e.*);
        for (0..kv_heads) |h| for (0..hd) |e| {
            ccache[CacheRow.at(context, max_kv, false, h, pos) + e] = @bitCast(@as(f16, @floatCast(ck[(t * kv_heads + h) * hd + e])));
            ccache[CacheRow.at(context, max_kv, true, h, pos) + e] = @bitCast(@as(f16, @floatCast(vb[(t * kv_heads + h) * hd + e])));
        };
    }
    var cout: [8 * 8 * HEAD_SIZE]f32 = undefined;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
    for (0..tokens) |t| for (0..heads) |h| {
        const pos = first + t;
        const visible: usize = if (window != 0 and pos >= window) pos - window + 1 else 0;
        const kh = h / (heads / kv_heads);
        const query = cq[(t * heads + h) * hd ..][0..hd];
        var scores: [1100]f32 = undefined;
        var maximum: f32 = -std.math.inf(f32);
        for (visible..pos + 1) |p| {
            var lanes = [_]f32{0} ** 8;
            for (0..hd / 8) |i| for (0..8) |l| {
                lanes[l] += query[8 * i + l] * halfOf(ccache[CacheRow.at(context, max_kv, false, kh, p) + 8 * i + l]);
            };
            var sum = lanes[0];
            for (1..8) |l| sum += lanes[l];
            scores[p - visible] = sum * scale;
            maximum = @max(maximum, scores[p - visible]);
        }
        const length = pos + 1 - visible;
        var total: f64 = 0;
        for (scores[0..length]) |*sc| {
            sc.* = @exp(sc.* - maximum);
            total += sc.*;
        }
        const inverse: f32 = @floatCast(1.0 / total);
        const dst = cout[(t * heads + h) * hd ..][0..hd];
        @memset(dst, 0);
        for (scores[0..length], visible..) |sc, p| {
            const wgt = f16r(sc * inverse);
            for (dst, 0..) |*acc, e| acc.* += wgt * halfOf(ccache[CacheRow.at(context, max_kv, true, kh, p) + e]);
        }
        const g = 1.0 / (1.0 + @exp(-gate[t * heads + h]));
        for (dst) |*e| e.* *= g;
    };
    // GPU
    const pp = PrepareParams{ .heads = heads, .kv_heads = kv_heads, .epsilon = 1e-5, .first_position = first, .context = context, .slot = slot, .max_kv_heads = max_kv, .query_norm = 0, .key_norm = hd * 4 };
    var k = try prepare(testStorage(), caps);
    _ = try runOn(&k, caps, prepareGroups(heads, kv_heads, tokens), &.{ T.a[0 .. tokens * heads * hd * 4], T.b[0 .. tokens * kv_heads * hd * 4], T.b[tokens * kv_heads * hd * 4 ..][0 .. tokens * kv_heads * hd * 4], T.c[0 .. 2 * hd * 4], T.c[0 .. 2 * hd * 4], T.c[2 * hd * 4 ..][0 .. tokens * 64 * 2 * 4], T.e[0..kv_bytes] }, &pp.words());
    // the prepared queries and the cache: the CPU's (norms within an ulp, w.h.p. exact)
    var q_diff: usize = 0;
    for (cq[0..q.len], q) |a, b| {
        if (@as(u32, @bitCast(a)) != @as(u32, @bitCast(b))) q_diff += 1;
    }
    var kv_diff: usize = 0;
    for (ccache[0..cache.len], cache) |a, b| {
        if (a != b) kv_diff += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), q_diff);
    try std.testing.expectEqual(@as(usize, 0), kv_diff);
    const ap = AttnParams{ .heads = heads, .kv_heads = kv_heads, .first_position = first, .tokens = tokens, .window = window, .context = context, .slot = slot, .max_kv_heads = max_kv, .span = span, .chunks = chunks, .query = 0, .gate = 0, .out = 0 };
    const words = ap.words();
    const sbuf = T.f[0 .. tokens * heads * span * 4];
    const pbuf = T.g[0 .. tokens * heads * chunks * HEAD_SIZE * 4];
    const obuf = T.d[4096..][0 .. tokens * heads * hd * 4];
    k = try attnScores(testStorage(), caps, hg, tt);
    _ = try runOn(&k, caps, scoreGroups(ap, hg, tt), &.{ T.a[0 .. tokens * heads * hd * 4], T.e[0..kv_bytes], sbuf }, &words);
    k = try attnSoftmax(testStorage(), caps);
    _ = try runOn(&k, caps, softmaxGroups(ap), &.{sbuf}, &words);
    k = try attnValues(testStorage(), caps, hg, tt);
    _ = try runOn(&k, caps, valueGroups(ap, hg, tt), &.{ T.e[0..kv_bytes], sbuf, pbuf }, &words);
    k = try attnCombine(testStorage(), caps);
    _ = try runOn(&k, caps, combineGroups(ap), &.{ pbuf, T.d[0 .. tokens * heads * 4], obuf }, &words);
    const got = f32s(obuf);
    var worst: f64 = 0;
    var exact: usize = 0;
    for (cout[0..got.len], got) |a, b| {
        worst = @max(worst, @abs(@as(f64, a) - b) / @max(@abs(@as(f64, a)), 0.05));
        if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b))) exact += 1;
    }
    std.debug.print("attention ({d} heads, {d} kv, {d} tokens from {d}, window {d}, {d}x{d} a workgroup): worst {e}, {d} of {d} the CPU's bits\n", .{ heads, kv_heads, tokens, first, window, hg, tt, worst, exact, got.len });
    return worst;
}

test "attention: prepare, then scores, softmax, values and combine, against the executor's tasks" {
    const caps = caps32(false, 32);
    // one value chunk: the CPU's operations in its order
    try std.testing.expect(try testAttention(caps, 8, 2, 300, 3, 37, 0, 4, 2) < 1e-6);
    // spans over several chunks, decode and tiles, a sliding window, GQA groups of 2
    try std.testing.expect(try testAttention(caps, 8, 2, 1100, 1, 1000, 0, 4, 1) < 1e-5);
    try std.testing.expect(try testAttention(caps, 4, 2, 1100, 5, 700, 0, 2, 4) < 1e-5);
    try std.testing.expect(try testAttention(caps32(true, 64), 8, 2, 1100, 4, 1050, 64, 1, 1) < 1e-5);
}

test "copy: 16-byte words between offsets" {
    const T = TestRig;
    const caps = caps32(true, 32);
    for (T.a[0..4096], 0..) |*x, i| x.* = @truncate(i * 7 + 3);
    @memset(T.b[0..4096], 0);
    var k = try copy(testStorage(), caps);
    _ = try runOn(&k, caps, copyGroups(100), &.{ T.a[0..4096], T.b[0..4096] }, &.{ 100, 32, 64 });
    try std.testing.expectEqualSlices(u8, T.a[32..][0..1600], T.b[64..][0..1600]);
    try std.testing.expect(T.b[63] == 0 and T.b[64 + 1600] == 0);
}
