// @zpm/llm — Transformer Decoder
// Shared decoder implementation supporting Qwen3, Gemma4, LLaMA architectures.
// Extracted from metalforge/src/infer.sig with multi-architecture support.
//
// Key features:
//   - RMSNorm with configurable eps
//   - GQA (Grouped Query Attention) with per-head Q/K norm (Qwen3)
//   - NeoX split-half RoPE
//   - SwiGLU MLP
//   - KV cache with concrete allocation (VirtualAlloc or cuMemAlloc)
//   - Quantized weight dequantization (Q4_K, Q6_K, Q8_0)
//
// This is the hot path — all matmuls dispatch to the compute backend
// (cuBLAS on CUDA, Accelerate on macOS, or naive CPU fallback).
//
// KV Cache sizing for Qwen3-VL-2B:
//   28 layers × 2048 max_seq × 256 kv_dim × 4 bytes × 2 (K+V)
//   = 28 × 2048 × 256 × 4 × 2 = 117,440,512 bytes ≈ 112 MB
//
// For ASR decoder (Qwen3-ASR, same architecture):
//   32 layers × 4096 max_seq × 256 kv_dim × 4 bytes × 2
//   = 32 × 4096 × 256 × 4 × 2 = 268,435,456 bytes ≈ 256 MB

const std = @import("std");
const math = std.math;

pub const MAX_SEQ: usize = 8192;
pub const MAX_LAYERS: usize = 64;
pub const MAX_DIM: usize = 16384; // max hidden_size for scratch buffers

// Win32 VirtualAlloc for CPU-side KV
extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) ?[*]u8;
extern "kernel32" fn VirtualFree(?*anyopaque, usize, u32) c_int;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

/// Compute backend dispatch
pub const ComputeBackend = enum {
    cpu_naive, // Triple-loop matmul (fallback)
    cublas, // NVIDIA cuBLAS (Windows/Linux CUDA)
    accelerate, // Apple Accelerate (macOS AMX)
};

/// Decoder configuration (populated from GGUF metadata)
pub const DecoderConfig = struct {
    hidden_size: usize = 2048,
    n_layers: usize = 28,
    n_heads: usize = 16,
    n_kv_heads: usize = 8,
    head_dim: usize = 128,
    intermediate_size: usize = 6144,
    vocab_size: usize = 151936,
    max_seq_len: usize = 2048, // actual max for KV allocation
    rope_theta: f32 = 1000000.0,
    rms_eps: f32 = 1e-6,
    // Architecture flags
    has_qk_norm: bool = true, // Qwen3: per-head Q/K RMSNorm
    rope_neox: bool = true, // NeoX interleaved RoPE

    /// KV dimension per layer = n_kv_heads * head_dim
    pub fn kvDim(self: DecoderConfig) usize {
        return self.n_kv_heads * self.head_dim;
    }

    /// Total KV cache size in bytes for all layers (K + V)
    pub fn kvCacheSizeBytes(self: DecoderConfig) usize {
        return self.n_layers * self.max_seq_len * self.kvDim() * 4 * 2;
    }
};

/// Preset: Qwen3-VL-2B-Instruct
pub const QWEN3_VL_2B = DecoderConfig{
    .hidden_size = 2048,
    .n_layers = 28,
    .n_heads = 16,
    .n_kv_heads = 8,
    .head_dim = 128,
    .intermediate_size = 6144,
    .vocab_size = 151936,
    .max_seq_len = 2048,
    .rope_theta = 1000000.0,
    .rms_eps = 1e-6,
    .has_qk_norm = true,
    .rope_neox = true,
};

/// Preset: Qwen3-4B-Instruct-2507
pub const QWEN3_4B = DecoderConfig{
    .hidden_size = 2560,
    .n_layers = 36,
    .n_heads = 32,
    .n_kv_heads = 8,
    .head_dim = 80,
    .intermediate_size = 9216,
    .vocab_size = 151936,
    .max_seq_len = 4096,
    .rope_theta = 1000000.0,
    .rms_eps = 1e-6,
    .has_qk_norm = true,
    .rope_neox = true,
};

/// Preset: Qwen3-ASR decoder (used by @zpm/asr)
pub const QWEN3_ASR = DecoderConfig{
    .hidden_size = 3584,
    .n_layers = 32,
    .n_heads = 28,
    .n_kv_heads = 4,
    .head_dim = 128,
    .intermediate_size = 18944,
    .vocab_size = 151936,
    .max_seq_len = 4096,
    .rope_theta = 1000000.0,
    .rms_eps = 1e-6,
    .has_qk_norm = true,
    .rope_neox = true,
};

// ── KV Cache ──

/// KV Cache: contiguous allocation for all layers.
/// Layout: layers × max_seq × kv_dim, stored as f32.
/// K and V are separate contiguous blocks.
pub const KVCache = struct {
    k_base: ?[*]f32 = null, // [n_layers, max_seq, kv_dim]
    v_base: ?[*]f32 = null, // [n_layers, max_seq, kv_dim]
    seq_len: usize = 0, // current sequence position
    n_layers: usize = 0,
    max_seq: usize = 0,
    kv_dim: usize = 0,
    // Memory management
    alloc_bytes: usize = 0, // total bytes allocated (for free)
    is_gpu: bool = false, // true if allocated on GPU via cuMemAlloc

    /// Allocate KV cache via VirtualAlloc (CPU-resident).
    /// For CPU inference or when GPU memory is tight.
    pub fn allocCPU(cfg: DecoderConfig) KVCache {
        const kv_dim = cfg.kvDim();
        const layer_size = cfg.max_seq_len * kv_dim; // elements per layer
        const total_elements = cfg.n_layers * layer_size;
        const total_bytes = total_elements * 4; // f32

        // Allocate K block
        const k_mem = VirtualAlloc(
            null, total_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE,
        );
        // Allocate V block
        const v_mem = VirtualAlloc(
            null, total_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE,
        );

        return .{
            .k_base = if (k_mem) |m| @ptrCast(@alignCast(m)) else null,
            .v_base = if (v_mem) |m| @ptrCast(@alignCast(m)) else null,
            .seq_len = 0,
            .n_layers = cfg.n_layers,
            .max_seq = cfg.max_seq_len,
            .kv_dim = kv_dim,
            .alloc_bytes = total_bytes,
            .is_gpu = false,
        };
    }

    /// Free KV cache memory.
    pub fn free(self: *KVCache) void {
        if (!self.is_gpu) {
            if (self.k_base) |k| _ = VirtualFree(@ptrCast(k), 0, MEM_RELEASE);
            if (self.v_base) |v| _ = VirtualFree(@ptrCast(v), 0, MEM_RELEASE);
        }
        // GPU free is handled by cuda_ctx.gpuFree() externally
        self.k_base = null;
        self.v_base = null;
        self.seq_len = 0;
    }

    /// Reset sequence position (reuse allocation for new generation).
    pub fn reset(self: *KVCache) void {
        self.seq_len = 0;
    }

    /// Check if allocation succeeded.
    pub fn isValid(self: *const KVCache) bool {
        return self.k_base != null and self.v_base != null;
    }

    /// Get K pointer for a specific layer and position.
    /// Returns pointer to kv_dim floats.
    pub fn getK(self: *const KVCache, layer: usize, pos: usize) [*]f32 {
        const offset = layer * self.max_seq * self.kv_dim + pos * self.kv_dim;
        return self.k_base.? + offset;
    }

    /// Get V pointer for a specific layer and position.
    pub fn getV(self: *const KVCache, layer: usize, pos: usize) [*]f32 {
        const offset = layer * self.max_seq * self.kv_dim + pos * self.kv_dim;
        return self.v_base.? + offset;
    }

    /// Store K vector for current position.
    pub fn storeK(self: *KVCache, layer: usize, k_vec: [*]const f32) void {
        const dst = self.getK(layer, self.seq_len);
        @memcpy(dst[0..self.kv_dim], k_vec[0..self.kv_dim]);
    }

    /// Store V vector for current position.
    pub fn storeV(self: *KVCache, layer: usize, v_vec: [*]const f32) void {
        const dst = self.getV(layer, self.seq_len);
        @memcpy(dst[0..self.kv_dim], v_vec[0..self.kv_dim]);
    }

    /// Advance position after storing K/V for all layers.
    pub fn advance(self: *KVCache) void {
        if (self.seq_len < self.max_seq - 1) {
            self.seq_len += 1;
        }
        // If we hit max, oldest entries are implicitly overwritten (circular)
    }

    /// Dot product: q[head_dim] dot K[pos, kv_head*head_dim .. +head_dim]
    pub fn dotK(self: *const KVCache, layer: usize, pos: usize, kv_head: usize, q: [*]const f32, head_dim: usize) f32 {
        const k_ptr = self.getK(layer, pos);
        const offset = kv_head * head_dim;
        var dot: f32 = 0.0;
        for (0..head_dim) |i| dot += q[i] * k_ptr[offset + i];
        return dot;
    }

    /// Weighted accumulate: out[head_dim] += weight * V[pos, kv_head*head_dim..]
    pub fn accumV(self: *const KVCache, layer: usize, pos: usize, kv_head: usize, weight: f32, out: [*]f32, head_dim: usize) void {
        if (weight == 0.0) return;
        const v_ptr = self.getV(layer, pos);
        const offset = kv_head * head_dim;
        for (0..head_dim) |i| out[i] += weight * v_ptr[offset + i];
    }
};

// ── Scratch buffers (comptime-fixed, static — avoid stack overflow) ──
// These are used during forwardLayer. Module-level to keep them off the stack.
var scratch_norm: [MAX_DIM]f32 = @splat(0.0);
var scratch_q: [MAX_DIM]f32 = @splat(0.0);
var scratch_k: [MAX_DIM]f32 = @splat(0.0);
var scratch_v: [MAX_DIM]f32 = @splat(0.0);
var scratch_attn: [MAX_SEQ]f32 = @splat(0.0);
var scratch_head_out: [MAX_DIM]f32 = @splat(0.0);
var scratch_mlp_gate: [MAX_DIM]f32 = @splat(0.0);
var scratch_mlp_up: [MAX_DIM]f32 = @splat(0.0);
var scratch_o: [MAX_DIM]f32 = @splat(0.0);

// Additional static scratch (moved from local to avoid stack overflow)
var scratch_attn_out: [MAX_DIM]f32 = @splat(0.0);
var scratch_mlp_out: [MAX_DIM]f32 = @splat(0.0);
var scratch_hidden: [MAX_DIM]f32 = @splat(0.0);
var scratch_normed: [MAX_DIM]f32 = @splat(0.0);

/// Forward one token through a single decoder layer.
/// hidden is mutated in place (residual connection).
pub fn forwardLayer(
    hidden: [*]f32, // [hidden_size] — mutated in place
    layer_idx: usize,
    pos: usize,
    kv: *KVCache,
    // Weight pointers (raw bytes — caller handles dequant or f32 cast)
    input_norm_w: [*]const f32,
    q_proj_w: [*]const f32,
    k_proj_w: [*]const f32,
    v_proj_w: [*]const f32,
    o_proj_w: [*]const f32,
    q_norm_w: ?[*]const f32, // null for non-Qwen3
    k_norm_w: ?[*]const f32,
    post_norm_w: [*]const f32,
    gate_w: [*]const f32,
    up_w: [*]const f32,
    down_w: [*]const f32,
    // Config
    cfg: DecoderConfig,
) void {
    const hidden_size = cfg.hidden_size;
    const n_heads = cfg.n_heads;
    const n_kv_heads = cfg.n_kv_heads;
    const head_dim = cfg.head_dim;
    const kv_dim = cfg.kvDim();
    const intermediate = cfg.intermediate_size;
    const gqa_ratio = n_heads / n_kv_heads;

    // 1. Input LayerNorm
    rmsNorm(hidden, &scratch_norm, input_norm_w, hidden_size, cfg.rms_eps);

    // 2. Q/K/V projections (matmul: [hidden] @ [proj, hidden]^T)
    matvec(&scratch_q, q_proj_w, &scratch_norm, n_heads * head_dim, hidden_size);
    matvec(&scratch_k, k_proj_w, &scratch_norm, kv_dim, hidden_size);
    matvec(&scratch_v, v_proj_w, &scratch_norm, kv_dim, hidden_size);

    // 3. Per-head Q/K RMSNorm (Qwen3 specific)
    if (cfg.has_qk_norm) {
        if (q_norm_w) |qn| {
            // Apply RMSNorm per head to Q
            for (0..n_heads) |h| {
                const off = h * head_dim;
                rmsNormInPlace(scratch_q[off .. off + head_dim], qn, head_dim, cfg.rms_eps);
            }
        }
        if (k_norm_w) |kn| {
            // Apply RMSNorm per head to K
            for (0..n_kv_heads) |h| {
                const off = h * head_dim;
                rmsNormInPlace(scratch_k[off .. off + head_dim], kn, head_dim, cfg.rms_eps);
            }
        }
    }

    // 4. RoPE (Rotary Position Embedding)
    applyRoPE(&scratch_q, pos, n_heads, head_dim, cfg.rope_theta);
    applyRoPE(&scratch_k, pos, n_kv_heads, head_dim, cfg.rope_theta);

    // 5. Store K, V in cache
    kv.storeK(layer_idx, &scratch_k);
    kv.storeV(layer_idx, &scratch_v);

    // 6. Attention: for each Q head, dot with all cached K, softmax, accumulate V
    @memset(scratch_o[0 .. n_heads * head_dim], 0.0);
    const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

    for (0..n_heads) |h| {
        const kv_head = h / gqa_ratio;
        const q_ptr = scratch_q[h * head_dim ..][0..head_dim];

        // Compute attention scores for all positions up to current
        for (0..pos + 1) |p| {
            scratch_attn[p] = kv.dotK(layer_idx, p, kv_head, q_ptr.ptr, head_dim) * scale;
        }

        // Softmax over [0..pos+1]
        softmax(scratch_attn[0 .. pos + 1]);

        // Weighted sum of V
        const head_out = scratch_head_out[h * head_dim ..][0..head_dim];
        @memset(head_out, 0.0);
        for (0..pos + 1) |p| {
            kv.accumV(layer_idx, p, kv_head, scratch_attn[p], head_out.ptr, head_dim);
        }
    }

    // 7. Output projection: o_proj @ concat(head_outputs)
    // scratch_o already holds concatenated head outputs via scratch_head_out layout
    matvec(&scratch_attn_out, o_proj_w, &scratch_head_out, hidden_size, n_heads * head_dim);

    // 8. Residual connection
    for (0..hidden_size) |i| hidden[i] += scratch_attn_out[i];

    // 9. Post-attention LayerNorm
    rmsNorm(hidden, &scratch_norm, post_norm_w, hidden_size, cfg.rms_eps);

    // 10. MLP (SwiGLU): gate and up projections
    matvec(&scratch_mlp_gate, gate_w, &scratch_norm, intermediate, hidden_size);
    matvec(&scratch_mlp_up, up_w, &scratch_norm, intermediate, hidden_size);

    // SiLU(gate) * up
    for (0..intermediate) |i| {
        scratch_mlp_gate[i] = silu(scratch_mlp_gate[i]) * scratch_mlp_up[i];
    }

    // Down projection
    matvec(&scratch_mlp_out, down_w, &scratch_mlp_gate, hidden_size, intermediate);

    // 11. Residual connection
    for (0..hidden_size) |i| hidden[i] += scratch_mlp_out[i];
}

// ── Core math primitives ──

/// RMSNorm: output = input * rsqrt(mean(x^2) + eps) * weight
pub fn rmsNorm(input: [*]const f32, output: [*]f32, weight: [*]const f32, dim: usize, eps: f32) void {
    var ss: f32 = 0.0;
    for (0..dim) |i| ss += input[i] * input[i];
    ss = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(dim)) + eps);
    for (0..dim) |i| output[i] = input[i] * ss * weight[i];
}

/// RMSNorm in place (for per-head normalization)
fn rmsNormInPlace(data: []f32, weight: [*]const f32, dim: usize, eps: f32) void {
    var ss: f32 = 0.0;
    for (0..dim) |i| ss += data[i] * data[i];
    ss = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(dim)) + eps);
    for (0..dim) |i| data[i] = data[i] * ss * weight[i];
}

/// SiLU activation: x * sigmoid(x)
pub fn silu(x: f32) f32 {
    return x / (1.0 + @exp(-x));
}

/// Softmax in place over a slice
fn softmax(data: []f32) void {
    // Find max for numerical stability
    var max_val: f32 = data[0];
    for (1..data.len) |i| if (data[i] > max_val) { max_val = data[i]; };
    // Exp and sum
    var sum: f32 = 0.0;
    for (0..data.len) |i| {
        data[i] = @exp(data[i] - max_val);
        sum += data[i];
    }
    // Normalize
    const inv_sum = 1.0 / sum;
    for (0..data.len) |i| data[i] *= inv_sum;
}

/// RoPE: Rotary Position Embedding (NeoX interleaved layout)
/// Applies to pairs: (x[2i], x[2i+1]) rotated by theta^(2i/dim) * pos
fn applyRoPE(data: [*]f32, pos: usize, n_heads: usize, head_dim: usize, theta: f32) void {
    const half_dim = head_dim / 2;
    for (0..n_heads) |h| {
        const base = h * head_dim;
        for (0..half_dim) |i| {
            const freq = 1.0 / math.pow(f32, theta, @as(f32, @floatFromInt(2 * i)) / @as(f32, @floatFromInt(head_dim)));
            const angle = @as(f32, @floatFromInt(pos)) * freq;
            const cos_val = @cos(angle);
            const sin_val = @sin(angle);

            // NeoX layout: first half and second half
            const x0 = data[base + i];
            const x1 = data[base + half_dim + i];
            data[base + i] = x0 * cos_val - x1 * sin_val;
            data[base + half_dim + i] = x0 * sin_val + x1 * cos_val;
        }
    }
}

/// Matrix-vector multiply dispatch.
/// Set to cuBLAS-backed implementation during init for GPU acceleration.
pub const MatvecFn = *const fn ([*]f32, [*]const f32, [*]const f32, usize, usize) void;

/// The active matvec function. Defaults to naive CPU. 
/// Set via `setMatvecFn()` to route through cuBLAS.
var active_matvec: MatvecFn = &matvecCpu;

/// Set the matvec dispatch function (called by infer.sig during GPU init).
pub fn setMatvecFn(f: MatvecFn) void {
    active_matvec = f;
}

/// CPU fallback: out[N] = W[N, K] @ in[K]
fn matvecCpu(output: [*]f32, weight: [*]const f32, input: [*]const f32, n: usize, k: usize) void {
    for (0..n) |row| {
        var acc: f32 = 0.0;
        const w_row = weight + row * k;
        for (0..k) |col| acc += w_row[col] * input[col];
        output[row] = acc;
    }
}

/// Dispatched matvec (calls cuBLAS if set, else CPU).
fn matvec(output: [*]f32, weight: [*]const f32, input: [*]const f32, n: usize, k: usize) void {
    active_matvec(output, weight, input, n, k);
}

// ── Full forward pass (all layers + output head) ──

/// Run the full decoder: embed token → all layers → logits.
/// Returns the argmax token ID (greedy decoding).
pub fn forward(
    token_id: u32,
    kv: *KVCache,
    token_embd: [*]const f32, // [vocab, hidden]
    output_norm_w: [*]const f32, // [hidden]
    output_w: [*]const f32, // [vocab, hidden]
    // Per-layer weights (arrays of pointers)
    layer_norms: [*]const [*]const f32,
    q_projs: [*]const [*]const f32,
    k_projs: [*]const [*]const f32,
    v_projs: [*]const [*]const f32,
    o_projs: [*]const [*]const f32,
    q_norms: [*]const ?[*]const f32,
    k_norms: [*]const ?[*]const f32,
    post_norms: [*]const [*]const f32,
    gates: [*]const [*]const f32,
    ups: [*]const [*]const f32,
    downs: [*]const [*]const f32,
    cfg: DecoderConfig,
) u32 {
    const pos = kv.seq_len;

    // Token embedding lookup
    const emb_offset = @as(usize, token_id) * cfg.hidden_size;
    @memcpy(scratch_hidden[0..cfg.hidden_size], token_embd[emb_offset .. emb_offset + cfg.hidden_size]);

    // Forward through all layers
    for (0..cfg.n_layers) |l| {
        forwardLayer(
            &scratch_hidden, l, pos, kv,
            layer_norms[l], q_projs[l], k_projs[l], v_projs[l], o_projs[l],
            q_norms[l], k_norms[l],
            post_norms[l], gates[l], ups[l], downs[l],
            cfg,
        );
    }

    // Advance KV cache position
    kv.advance();

    // Output norm
    rmsNorm(&scratch_hidden, &scratch_normed, output_norm_w, cfg.hidden_size, cfg.rms_eps);

    // Logits: output_w[vocab, hidden] @ normed[hidden]
    // Find argmax directly (no need to store all logits)
    var best_token: u32 = 0;
    var best_score: f32 = -math.inf(f32);

    for (0..cfg.vocab_size) |v| {
        var score: f32 = 0.0;
        const w_row = output_w + v * cfg.hidden_size;
        for (0..cfg.hidden_size) |i| score += w_row[i] * scratch_normed[i];
        if (score > best_score) {
            best_score = score;
            best_token = @intCast(v);
        }
    }

    return best_token;
}
