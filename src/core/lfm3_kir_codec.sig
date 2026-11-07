//! @zpm/lfm3-kir-codec — the kernels of LFM3-Audio's speech codec that
//! lfm3_kir does not have, in KIR, built with lfm3_kir's Builder. With
//! lfm3_kir's matrices, quantization, norms, head norm and RoPE, short
//! convolution, SwiGLU, residual, bias and copy they make lfm3_any_codec:
//! the codec decoder (lfm3_audio_gen.decode) up to its polar spectrum.
//!
//! | builder               | computes                                             |
//! |-----------------------|------------------------------------------------------|
//! | `fsq()`               | FSQ decode of a frame's codes, its f32 projection    |
//! | `upsample()`          | the in-projection's bias, each frame repeated        |
//! | `attendWindow(hs, g)` | the codec's causal attention over its carried window |
//!
//! # Exactness (the CPU's bits)
//!
//! As lfm3_kir's: the operations of lfm3_audio_ops in its order. The FSQ
//! projection is ggml_mul_mat of an F32 tensor as linearF32 runs it (each
//! product rounded, then added, input by input, then the bias). The
//! attention is attendHeadGgml with a window: ggml_vec_dot_f32's 32 fused
//! accumulators and its reduction tree for the scores and the value sums,
//! ggml_v_expf over whole groups of eight keys and the CPU's expf over the
//! rest, the total in groups of eight summed in f32 then all in the CPU's
//! f64 order (a double-f32 here, rounded once), and the sigmoid gate with
//! the CPU's expf. Each fused step is ffma where the GPU fuses and
//! Builder.fma's exact emulation where it does not: the CPU's bits on every
//! GPU (but for the double-f32 sums' rare ties, as lfm3_kir's).
//!
//! Allocation-free: kernels are built into the caller's Storage.

const std = @import("std");
const gpu = @import("gpu");
const lk = @import("lfm3_kir");

pub const kir = gpu.kir;
pub const Caps = gpu.Caps;
pub const Error = lk.Error;

const V = kir.V;
const Builder = lk.Builder;
const R = lk.R;
const U = lk.U;
const F = lk.F;
const NO = lk.NO;
const begin = lk.begin;

/// Codes a frame has: one a codebook (lfm3_audio_gen.CODEBOOKS).
pub const CODEBOOKS = 12;
/// Keys one attendWindow row holds at most (lfm3_audio_gen's MAX_KEY_ROW:
/// the window and a call's positions).
pub const MAX_ROW = 256;

// ── FSQ decode ──────────────────────────────────────────────────────────────

/// Workgroups of an fsq launch: (width / 64 rounded up, frames).
pub fn fsqGroups(width: u32, frames: u32) [3]u32 {
    return .{ (width + 63) / 64, frames, 1 };
}

/// A frame's twelve codes to the codec's first rows, as lfm3_audio_gen's
/// decode: each code's row of the FSQ codebook (`levels` f32), the twelve
/// rows one vector of 12 * levels inputs, then out[o] = sum_i W[o][i] *
/// x[i] (each product rounded, then added, in input order: linearF32) +
/// bias[o]. A thread an output. Bindings: codes (i32 [F][12], valid codes
/// only), weights (the model: the codebook f32 [codes][levels], the
/// projection f32 [width][12 * levels], its bias f32 [width]), out (f32
/// [F][width]). Params: levels (1 or more), width, the codebook's, the
/// projection's and the bias's byte offsets. Groups: fsqGroups.
pub fn fsq(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3c_fsq", 64);
    var b = Builder.init(&k, caps);
    const CODES = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 5;
    const o = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    const frame = b.gid(1);
    const levels = b.param(0);
    const width = b.param(1);
    b.if_(b.icmp(.u32, .lt, R(o), R(width)));
    const inputs = b.mul(R(levels), U(CODEBOOKS));
    const level_bytes = b.shl(R(levels), 2);
    const waddr = b.mov(.u32, R(b.add(R(b.param(3)), R(b.shl(R(b.mul(R(o), R(inputs))), 2)))));
    const code_row = b.mul(R(frame), U(CODEBOOKS * 4));
    const sum = b.mov(.f32, F(0));
    for (0..CODEBOOKS) |book| {
        const code = b.ld(CODES, .u32, R(code_row), @intCast(4 * book), 5);
        const caddr = b.mov(.u32, R(b.add(R(b.param(2)), R(b.mul(R(code), R(level_bytes))))));
        const l = b.mov(.u32, U(0));
        b.loop();
        {
            const x = b.ld(WB, .f32, R(caddr), 0, 5);
            const w = b.ld(WB, .f32, R(waddr), 0, 5);
            b.set(sum, .fadd, .f32, R(sum), R(b.fmul(R(w), R(x))), NO);
            b.set(caddr, .iadd, .u32, R(caddr), U(4), NO);
            b.set(waddr, .iadd, .u32, R(waddr), U(4), NO);
            b.set(l, .iadd, .u32, R(l), U(1), NO);
            b.brk(b.icmp(.u32, .ge, R(l), R(levels)));
        }
        b.endloop();
    }
    const bias = b.ld(WB, .f32, R(b.add(R(b.param(4)), R(b.shl(R(o), 2)))), 0, 5);
    b.st(OUT, R(b.shl(R(b.add(R(b.mul(R(frame), R(width))), R(o))), 2)), 0, 5, b.fadd(R(sum), R(bias)));
    b.endif();
    try k.finish();
    return k;
}

// ── Upsampling ──────────────────────────────────────────────────────────────

/// Workgroups of an upsample launch: (width / 64 rounded up, stack, frames).
pub fn upsampleGroups(width: u32, stack: u32, frames: u32) [3]u32 {
    return .{ (width + 63) / 64, stack, frames };
}

/// out[f * stack + j][i] = in[f][i] + bias[i] for j < stack: the codec's
/// in-projection's bias (ops.linear's `result + bias`) and its nearest
/// upsampling (each frame `stack` positions). Bindings: in (f32
/// [F][width]), weights (the bias, f32 [width]), out (f32 [F * stack]
/// [width]). Params: width, stack, the bias's byte offset. Groups:
/// upsampleGroups.
pub fn upsample(s: kir.Storage, caps: Caps) Error!kir.Kernel {
    var k = begin(s, "lfm3c_upsample", 64);
    var b = Builder.init(&k, caps);
    const IN = k.binding();
    const WB = k.binding();
    const OUT = k.binding();
    k.param_words = 3;
    const i = b.add(R(b.shl(R(b.gid(0)), 6)), R(b.tid(0)));
    const j = b.gid(1);
    const frame = b.gid(2);
    const width = b.param(0);
    b.if_(b.icmp(.u32, .lt, R(i), R(width)));
    const x = b.ld(IN, .f32, R(b.shl(R(b.add(R(b.mul(R(frame), R(width))), R(i))), 2)), 0, 5);
    const bias = b.ld(WB, .f32, R(b.add(R(b.param(2)), R(b.shl(R(i), 2)))), 0, 5);
    const p = b.add(R(b.mul(R(frame), R(b.param(1)))), R(j));
    b.st(OUT, R(b.shl(R(b.add(R(b.mul(R(p), R(width))), R(i))), 2)), 0, 5, b.fadd(R(x), R(bias)));
    b.endif();
    try k.finish();
    return k;
}

// ── Attention over the carried window ───────────────────────────────────────

/// The attendWindow parameter words.
pub const WindowParams = struct {
    heads: u32,
    /// log2(heads / kv_heads)
    group_log2: u32,
    /// The call's positions (queries; the row's last keys).
    tokens: u32,
    /// The carried keys at the row's front (lfm3_audio_gen: CODEC_WINDOW - 1).
    prefix: u32,
    /// The first key a position may see at all: prefix - position when
    /// the stream is younger than the window, else 0.
    earliest: u32,
    scale: f32,

    pub fn words(p: WindowParams) [6]u32 {
        return .{ p.heads, p.group_log2, p.tokens, p.prefix, p.earliest, @bitCast(p.scale) };
    }
};

pub fn windowGroups(heads: u32, tokens: u32) [3]u32 {
    return .{ heads, tokens, 1 };
}

/// The ggml_vec_dot_f32 reduction of its 32 accumulators (four 8-lane
/// vectors): (0 + 2) + (1 + 3) lane by lane, the halves, then the pairs.
fn ggmlTree(b: *Builder, acc: *const [32]V) V {
    var s0: [8]V = undefined;
    for (0..8) |l| {
        const a0 = b.fadd(R(acc[l]), R(acc[16 + l]));
        const a1 = b.fadd(R(acc[8 + l]), R(acc[24 + l]));
        s0[l] = b.fadd(R(a0), R(a1));
    }
    var t0: [4]V = undefined;
    for (0..4) |i| t0[i] = b.fadd(R(s0[i]), R(s0[i + 4]));
    return b.fadd(R(b.fadd(R(t0[0]), R(t0[1]))), R(b.fadd(R(t0[2]), R(t0[3]))));
}

/// The codec's attention, as lfm3_audio_gen's AttendTask with a window
/// (lfm3_audio_ops.attendHeadGgml): query position t of a call sees keys
/// [max(t, earliest), prefix + t] of the row [the carried window (prefix
/// keys) | the call's keys], the rest masked (-inf). A workgroup a (query
/// head, position), head_size threads: thread j scores keys j, j + hs, ..
/// (ggml_vec_dot_f32(key, query): its fused accumulators and tree), scaled,
/// + 0; the maximum; the exps (ggml_v_expf over whole groups of eight keys
/// of the row, the CPU's expf over the rest; masked keys 0); the total
/// (each group of eight summed in f32 as ggml does, then all in order as
/// the CPU's f64 does); the weights times its inverse; then element j as
/// ggml_vec_dot_f32(value column, weights) over the whole row (fused
/// accumulators over whole 32-key steps, the tree, the rest fused in
/// order); then the head's sigmoid gate (`gated`). Up to MAX_ROW keys.
/// Bindings: query (f32 [T][heads][hs]), key and value (f32 [prefix +
/// T][kv_heads][hs]), gate (f32 [T][heads]), out (f32 [T][heads][hs]).
/// Params: WindowParams.words. Groups: windowGroups.
pub fn attendWindow(s: kir.Storage, caps: Caps, head_size: u32, gated: bool) Error!kir.Kernel {
    if (head_size < 32 or head_size > 128 or head_size % 32 != 0 or head_size > caps.max_group) return error.Unsupported;
    const hs = head_size;
    const nt = hs;
    var k = begin(s, if (gated) "lfm3c_attend_gated" else "lfm3c_attend", nt);
    var b = Builder.init(&k, caps);
    const Q = k.binding();
    const KB = k.binding();
    const VB = k.binding();
    const G = k.binding();
    const OUT = k.binding();
    k.param_words = 6;
    const wbase = k.shared_bytes;
    k.shared_bytes += MAX_ROW * 4;
    b.needExchange(nt);
    const t = b.tid(0);
    const h = b.gid(0);
    const pos = b.gid(1);
    const heads = b.param(0);
    const shift = b.param(1);
    const row = b.add(R(b.param(3)), R(b.param(2)));
    const first = b.umax(R(pos), R(b.param(4)));
    const last = b.add(R(b.param(3)), R(pos));
    const scale = b.as(.f32, b.param(5));
    const kvh = b.op2(.shr, .u32, R(h), R(shift));
    const kv_heads = b.op2(.shr, .u32, R(heads), R(shift));
    const key_bytes = b.mul(R(kv_heads), U(hs * 4));
    const head_bytes = b.mul(R(kvh), U(hs * 4));
    const qrow = b.mul(R(b.add(R(b.mul(R(pos), R(heads))), R(h))), U(hs * 4));
    const ninf = F(-std.math.inf(f32));
    var q: [128]V = undefined;
    for (0..hs) |e| q[e] = b.ld(Q, .f32, R(qrow), @intCast(4 * e), 5);

    // scores: thread t keys t, t + nt, ..; the masked ones -inf
    const maximum = b.mov(.f32, ninf);
    const c = b.mov(.u32, U(0));
    b.loop();
    {
        const key = b.add(R(c), R(t));
        const in_row = b.icmp(.u32, .lt, R(key), R(row));
        const keyc = b.umin(R(key), R(b.sub(R(row), U(1))));
        const krow = b.add(R(b.mul(R(keyc), R(key_bytes))), R(head_bytes));
        var lanes: [32]V = undefined;
        for (0..hs / 32) |step| for (0..32) |i| {
            const e = step * 32 + i;
            const kv = b.ld(KB, .f32, R(krow), @intCast(4 * e), 5);
            lanes[i] = b.fma(R(kv), R(q[e]), if (step == 0) F(0) else R(lanes[i]));
        };
        const score = b.fadd(R(b.fmul(R(ggmlTree(&b, &lanes)), R(scale))), F(0));
        const seen = b.pand(b.icmp(.u32, .ge, R(key), R(first)), b.icmp(.u32, .le, R(key), R(last)));
        const sv = b.sel(.f32, b.pand(in_row, seen), R(score), ninf);
        b.set(maximum, .fmax, .f32, R(maximum), R(sv), NO);
        b.if_(in_row);
        b.sts(R(b.shl(R(key), 2)), wbase, sv, 1);
        b.endif();
        b.set(c, .iadd, .u32, R(c), U(nt), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(row)));
    }
    b.endloop();
    const mx = b.xorReduce(.fmax, .f32, maximum, nt, t);
    b.barrier();

    // exps, in place: ggml's over the row's whole groups of eight, expf
    // after; a masked key's is the CPU's exp(-inf), 0 (selected: the fma
    // emulation is exact for finite values only)
    const grouped_end = b.band(R(row), U(0xfffffff8));
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const key = b.add(R(c), R(t));
        b.if_(b.icmp(.u32, .lt, R(key), R(row)));
        const addr = b.shl(R(key), 2);
        const seen = b.pand(b.icmp(.u32, .ge, R(key), R(first)), b.icmp(.u32, .le, R(key), R(last)));
        const d = b.sel(.f32, seen, R(b.fsub(R(b.lds(.f32, R(addr), wbase, 1)), R(mx))), F(0));
        const grouped = b.icmp(.u32, .lt, R(key), R(grouped_end));
        const e = b.sel(.f32, grouped, R(lk.expGgml(&b, d)), R(b.expCpu(d)));
        b.sts(R(addr), wbase, b.sel(.f32, seen, R(e), F(0)), 1);
        b.endif();
        b.set(c, .iadd, .u32, R(c), U(nt), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(row)));
    }
    b.endloop();
    b.barrier();

    // the total, in every thread: the groups' f32 sums, then the rest, in order
    const total = b.ddZero();
    const groups = b.shr(R(row), 3);
    const g = b.mov(.u32, U(0));
    b.if_(b.icmp(.u32, .ne, R(groups), U(0)));
    b.loop();
    {
        const base = b.shl(R(g), 5);
        var ev: [8]V = undefined;
        for (0..8) |i| ev[i] = b.lds(.f32, R(base), wbase + @as(u32, @intCast(4 * i)), 1);
        var qs: [4]V = undefined;
        for (0..4) |i| qs[i] = b.fadd(R(ev[i + 4]), R(ev[i]));
        const gsum = b.fadd(R(b.fadd(R(qs[0]), R(qs[2]))), R(b.fadd(R(qs[1]), R(qs[3]))));
        b.ddAccumulate(total, .{ .hi = gsum, .lo = b.mov(.f32, F(0)) });
        b.set(g, .iadd, .u32, R(g), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(g), R(groups)));
    }
    b.endloop();
    b.endif();
    const tail = b.mov(.u32, R(grouped_end));
    b.if_(b.icmp(.u32, .lt, R(tail), R(row)));
    b.loop();
    {
        b.ddAccumulate(total, .{ .hi = b.lds(.f32, R(b.shl(R(tail), 2)), wbase, 1), .lo = b.mov(.f32, F(0)) });
        b.set(tail, .iadd, .u32, R(tail), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(tail), R(row)));
    }
    b.endloop();
    b.endif();
    const inverse = b.ddRecip(total);
    b.barrier();

    // the weights: each times the inverse
    b.set(c, .mov, .u32, U(0), NO, NO);
    b.loop();
    {
        const key = b.add(R(c), R(t));
        b.if_(b.icmp(.u32, .lt, R(key), R(row)));
        const addr = b.shl(R(key), 2);
        b.sts(R(addr), wbase, b.fmul(R(b.lds(.f32, R(addr), wbase, 1)), R(inverse)), 1);
        b.endif();
        b.set(c, .iadd, .u32, R(c), U(nt), NO);
        b.brk(b.icmp(.u32, .ge, R(c), R(row)));
    }
    b.endloop();
    b.barrier();

    // element t: ggml_vec_dot_f32(value column, weights) over the row
    const vbase = b.add(R(head_bytes), R(b.shl(R(t), 2)));
    var acc: [32]V = undefined;
    for (&acc) |*a| a.* = b.mov(.f32, F(0));
    const steps = b.shr(R(row), 5);
    const st = b.mov(.u32, U(0));
    b.if_(b.icmp(.u32, .ne, R(steps), U(0)));
    b.loop();
    {
        const key0 = b.shl(R(st), 5);
        var vaddr = b.add(R(b.mul(R(key0), R(key_bytes))), R(vbase));
        const waddr = b.shl(R(key0), 2);
        for (0..32) |i| {
            if (i > 0) vaddr = b.add(R(vaddr), R(key_bytes));
            const v = b.ld(VB, .f32, R(vaddr), 0, 5);
            const w = b.lds(.f32, R(waddr), wbase + @as(u32, @intCast(4 * i)), 1);
            b.set(acc[i], .mov, .f32, R(b.fma(R(v), R(w), R(acc[i]))), NO, NO);
        }
        b.set(st, .iadd, .u32, R(st), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(st), R(steps)));
    }
    b.endloop();
    b.endif();
    const out = b.mov(.f32, R(ggmlTree(&b, &acc)));
    const kk = b.mov(.u32, R(b.shl(R(steps), 5)));
    b.if_(b.icmp(.u32, .lt, R(kk), R(row)));
    b.loop();
    {
        const v = b.ld(VB, .f32, R(b.add(R(b.mul(R(kk), R(key_bytes))), R(vbase))), 0, 5);
        const w = b.lds(.f32, R(b.shl(R(kk), 2)), wbase, 1);
        b.set(out, .mov, .f32, R(b.fma(R(v), R(w), R(out))), NO, NO);
        b.set(kk, .iadd, .u32, R(kk), U(1), NO);
        b.brk(b.icmp(.u32, .ge, R(kk), R(row)));
    }
    b.endloop();
    b.endif();
    var result = out;
    if (gated) {
        const gv = b.ld(G, .f32, R(b.shl(R(b.add(R(b.mul(R(pos), R(heads))), R(h))), 2)), 0, 5);
        result = b.fmul(R(out), R(b.sigmoid(gv)));
    }
    b.st(OUT, R(b.add(R(qrow), R(b.shl(R(t), 2)))), 0, 5, result);
    try k.finish();
    return k;
}
