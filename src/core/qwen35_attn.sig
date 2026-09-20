//! qwen35 full-attention step — pure host reference (Layer 0).
//!
//! The 8 full-attention layers of the qwen35 hybrid use gated attention with
//! partial RoPE and per-head Q/K RMSNorm, over a grouped-query KV cache. This
//! module implements ONE decode token given already-projected Q/K/V/gate,
//! mutating the caller-owned KV cache and producing the pre-output-projection
//! attention result (already multiplied by the sigmoid gate).
//!
//! Shapes (4B distill, confirmed from GGUF): head_dim=256, head_count=16,
//! kv_head_count=4 (GQA group=4), rope_dimension_count=64 (partial: rotate the
//! first 64 of 256 dims), rope_base=1e7. `attn_q` is query+gate FUSED
//! [hidden, 2*16*256=8192] -> Q[4096] then gate[4096]; `attn_output` consumes
//! head_count*head_dim = 4096.
//!
//! No I/O, no allocation, no matmuls (projections are separate validated
//! matvec kernels). Pure per-token attention math — the numerical oracle for
//! any later GPU port and a usable CPU path in the executor.

const math = @import("sig_math");

pub const Error = error{ InvalidDimensions, KvCapacity };

/// Debug: disable RoPE to test whether the partial-RoPE impl is the fault.
pub var dbg_disable_rope: bool = false;

pub const MAX_HEADS: usize = 32;
pub const MAX_HEAD_DIM: usize = 256;
pub const MAX_CONTEXT: usize = 4096;

pub const AttnDims = struct {
    head_count: usize, // query heads (16)
    kv_head_count: usize, // key/value heads (4)
    head_dim: usize, // per-head dim (256)
    rope_dim: usize, // rotated width (64), <= head_dim, even

    pub fn valid(self: AttnDims) bool {
        return self.head_count != 0 and self.kv_head_count != 0 and self.head_dim != 0 and
            self.head_count <= MAX_HEADS and self.head_dim <= MAX_HEAD_DIM and
            self.head_count % self.kv_head_count == 0 and
            self.rope_dim <= self.head_dim and self.rope_dim % 2 == 0;
    }
    pub fn qDim(self: AttnDims) usize {
        return self.head_count * self.head_dim;
    }
    pub fn kvDim(self: AttnDims) usize {
        return self.kv_head_count * self.head_dim;
    }
    /// f32 elements of KV cache for one full-attn layer at `context` positions:
    /// 2 (K,V) * kv_head_count * context * head_dim.
    pub fn kvElements(self: AttnDims, context: usize) usize {
        return 2 * self.kv_head_count * context * self.head_dim;
    }
};

/// Per-head RMSNorm over head_dim, in place, with a shared weight vector.
fn rmsNormHead(v: []f32, w: []const f32, eps: f32) void {
    var ss: f32 = 0;
    for (v) |x| ss += x * x;
    const inv = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(v.len)) + eps);
    for (v, 0..) |*x, i| x.* = x.* * inv * w[i];
}

/// Partial NeoX-style RoPE: rotate the first `rope_dim` dims of each head using
/// the split-half convention over those dims; leave the rest untouched.
fn ropePartial(values: []f32, heads: usize, head_dim: usize, rope_dim: usize, position: u64, base: f32) void {
    const half = rope_dim / 2;
    for (0..heads) |h| {
        const b = h * head_dim;
        for (0..half) |lane| {
            const exponent = @as(f32, @floatFromInt(2 * lane)) / @as(f32, @floatFromInt(rope_dim));
            const freq = 1.0 / math.pow(base, exponent);
            const angle = @as(f32, @floatFromInt(position)) * freq;
            const c = @cos(angle);
            const s = @sin(angle);
            const lo = values[b + lane];
            const hi = values[b + half + lane];
            values[b + lane] = lo * c - hi * s;
            values[b + half + lane] = hi * c + lo * s;
        }
    }
}

/// One full-attention decode step (reference).
/// - q: [head_count*head_dim] (mutated: RMSNorm + RoPE applied)
/// - k: [kv_head_count*head_dim] (mutated)
/// - v: [kv_head_count*head_dim]
/// - gate: [head_count*head_dim] (output gate, pre-sigmoid)
/// - q_norm_w, k_norm_w: [head_dim]
/// - kv_cache: [2 * kv_head_count * context * head_dim] f32; K at [0..half),
///   V at [half..). Layout per (kv_head, pos, dim). Mutated at `position`.
/// - out: [head_count*head_dim] gated attention output (pre output projection).
pub fn step(
    dims: AttnDims,
    q: []f32,
    k: []f32,
    v: []const f32,
    gate: []const f32,
    q_norm_w: []const f32,
    k_norm_w: []const f32,
    rms_eps: f32,
    rope_base: f32,
    kv_cache: []f32,
    context: usize,
    position: usize,
    out: []f32,
) Error!void {
    if (!dims.valid()) return error.InvalidDimensions;
    const hd = dims.head_dim;
    const hc = dims.head_count;
    const kvc = dims.kv_head_count;
    const group = hc / kvc;
    if (q.len != dims.qDim() or k.len != dims.kvDim() or v.len != dims.kvDim() or
        gate.len != dims.qDim() or out.len != dims.qDim() or
        q_norm_w.len != hd or k_norm_w.len != hd) return error.InvalidDimensions;
    if (position >= context or context > MAX_CONTEXT) return error.KvCapacity;
    if (kv_cache.len < dims.kvElements(context)) return error.KvCapacity;

    // Per-head Q/K RMSNorm.
    for (0..hc) |h| rmsNormHead(q[h * hd ..][0..hd], q_norm_w, rms_eps);
    for (0..kvc) |h| rmsNormHead(k[h * hd ..][0..hd], k_norm_w, rms_eps);
    // Partial RoPE.
    if (!dbg_disable_rope) {
        ropePartial(q, hc, hd, dims.rope_dim, position, rope_base);
        ropePartial(k, kvc, hd, dims.rope_dim, position, rope_base);
    }

    // Store K,V for this position into the cache.
    const half = kvc * context * hd; // K region size; V starts at `half`.
    for (0..kvc) |h| {
        const dst_k = h * context * hd + position * hd;
        const dst_v = half + h * context * hd + position * hd;
        @memcpy(kv_cache[dst_k..][0..hd], k[h * hd ..][0..hd]);
        @memcpy(kv_cache[dst_v..][0..hd], v[h * hd ..][0..hd]);
    }

    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
    const ctx_len = position + 1;
    var scores: [MAX_CONTEXT]f32 = undefined;

    for (0..hc) |h| {
        const kvh = h / group;
        const qh = q[h * hd ..][0..hd];
        // scores[t] = scale * dot(qh, K[kvh][t])
        for (0..ctx_len) |t| {
            const kt = kv_cache[kvh * context * hd + t * hd ..][0..hd];
            var acc: f32 = 0;
            for (0..hd) |d| acc += qh[d] * kt[d];
            scores[t] = acc * scale;
        }
        // softmax over scores[0..ctx_len]
        var mx = scores[0];
        for (scores[1..ctx_len]) |sv| mx = @max(mx, sv);
        var sum: f32 = 0;
        for (scores[0..ctx_len]) |*sv| {
            sv.* = @exp(sv.* - mx);
            sum += sv.*;
        }
        const inv = 1.0 / sum;
        // out[h] = sum_t softmax[t] * V[kvh][t]; then * sigmoid(gate[h])
        const oh = out[h * hd ..][0..hd];
        for (0..hd) |d| oh[d] = 0;
        for (0..ctx_len) |t| {
            const w = scores[t] * inv;
            const vt = kv_cache[half + kvh * context * hd + t * hd ..][0..hd];
            for (0..hd) |d| oh[d] += w * vt[d];
        }
        // Gated attention: multiply the head output by sigmoid(gate) elementwise.
        const gh = gate[h * hd ..][0..hd];
        for (0..hd) |d| oh[d] *= 1.0 / (1.0 + @exp(-gh[d]));
    }
}

// Tests

test "attn dims" {
    const d = AttnDims{ .head_count = 16, .kv_head_count = 4, .head_dim = 256, .rope_dim = 64 };
    if (!d.valid()) return error.TestUnexpectedResult;
    if (d.qDim() != 4096 or d.kvDim() != 1024) return error.TestUnexpectedResult;
    if (d.kvElements(8) != 2 * 4 * 8 * 256) return error.TestUnexpectedResult;
}

test "attn step runs finite, first position" {
    const d = AttnDims{ .head_count = 2, .kv_head_count = 1, .head_dim = 4, .rope_dim = 2 };
    var q = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 };
    var k = [_]f32{ 0.2, 0.1, 0.4, 0.3 };
    const v = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const gate = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }; // sigmoid(0)=0.5
    const qn = [_]f32{ 1, 1, 1, 1 };
    const kn = [_]f32{ 1, 1, 1, 1 };
    var kv: [2 * 1 * 4 * 4]f32 = @splat(0);
    var out: [8]f32 = @splat(0);
    try step(d, &q, &k, &v, &gate, &qn, &kn, 1.0e-6, 1.0e7, &kv, 4, 0, &out);
    for (out) |x| if (!math.isFinite(x)) return error.TestUnexpectedResult;
    // At position 0, softmax is trivially 1, so out[h] = 0.5 * v[kvh] (gate=0.5).
    // head0 and head1 both map to kvh 0, so out should equal 0.5*v.
    for (0..4) |i| {
        if (@abs(out[i] - 0.5 * v[i]) > 1e-4) return error.TestUnexpectedResult;
        if (@abs(out[4 + i] - 0.5 * v[i]) > 1e-4) return error.TestUnexpectedResult;
    }
}
