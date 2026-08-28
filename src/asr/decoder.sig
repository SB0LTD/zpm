// @zpm/asr — Qwen3 LLM Decoder Module
// Implements the decoder half of Qwen3-ASR: causal transformer with KV cache.
//
// Architecture (1.7B variant):
//   28 layers, hidden_size=2048, 16 heads, 8 KV heads (GQA 2:1)
//   head_dim=128, intermediate=6144
//   RMSNorm (eps=1e-6), no biases
//   Per-head Q/K RMSNorm (after projection, before RoPE)
//   NeoX split-half RoPE (theta=1e6)
//   SwiGLU MLP (gate + up + down)
//   Causal attention with KV cache
//   Tied embeddings: embed_tokens == lm_head (vocab=151936)
//
// Adapted from metalforge/src/infer.sig patterns.
// Zero heap allocations — all scratch is comptime-sized statics.

const math = @import("std").math;

// ── Configuration ──
pub const DecoderConfig = struct {
    hidden_size: usize, // 2048 for 1.7B, 1024 for 0.6B
    n_layers: usize, // 28 for both
    n_heads: usize, // 16 for both
    n_kv_heads: usize, // 8 for both
    head_dim: usize, // 128 for both
    intermediate_size: usize, // 6144 for 1.7B, 3072 for 0.6B
    vocab_size: usize, // 151936
    rope_theta: f32, // 1000000.0
    rms_norm_eps: f32, // 1e-6
    max_seq_len: usize, // 4096

    pub fn kvDim(self: DecoderConfig) usize {
        return self.n_kv_heads * self.head_dim; // 8 * 128 = 1024
    }
    pub fn gqaRatio(self: DecoderConfig) usize {
        return self.n_heads / self.n_kv_heads; // 2
    }
};

pub const DECODER_1_7B = DecoderConfig{
    .hidden_size = 2048,
    .n_layers = 28,
    .n_heads = 16,
    .n_kv_heads = 8,
    .head_dim = 128,
    .intermediate_size = 6144,
    .vocab_size = 151936,
    .rope_theta = 1000000.0,
    .rms_norm_eps = 1e-6,
    .max_seq_len = 4096,
};

pub const DECODER_0_6B = DecoderConfig{
    .hidden_size = 1024,
    .n_layers = 28,
    .n_heads = 16,
    .n_kv_heads = 8,
    .head_dim = 128,
    .intermediate_size = 3072,
    .vocab_size = 151936,
    .rope_theta = 1000000.0,
    .rms_norm_eps = 1e-6,
    .max_seq_len = 4096,
};

// ── Special token IDs ──
pub const TOKEN_EOS1: u32 = 151643; // <|endoftext|>
pub const TOKEN_EOS2: u32 = 151645; // <|im_end|>
pub const TOKEN_AUDIO_START: u32 = 151669;
pub const TOKEN_AUDIO_END: u32 = 151670;
pub const TOKEN_AUDIO_PAD: u32 = 151676;
pub const TOKEN_ASR_TEXT: u32 = 151704;
pub const TOKEN_IM_START: u32 = 151644;

// ── Weight pointers ──
pub const DecoderWeights = struct {
    embed_tokens: [*]const f32, // [vocab_size, hidden_size] — also used as lm_head
    norm_w: [*]const f32, // [hidden_size] — final RMSNorm
    layers: [*]const DecoderLayerWeights,
};

pub const DecoderLayerWeights = struct {
    // Input RMSNorm
    input_norm_w: [*]const f32, // [hidden_size]
    // QKV projections (no bias)
    q_proj_w: [*]const f32, // [n_heads*head_dim, hidden_size]
    k_proj_w: [*]const f32, // [n_kv_heads*head_dim, hidden_size]
    v_proj_w: [*]const f32, // [n_kv_heads*head_dim, hidden_size]
    o_proj_w: [*]const f32, // [hidden_size, n_heads*head_dim]
    // Per-head Q/K RMSNorm weights
    q_norm_w: [*]const f32, // [head_dim]
    k_norm_w: [*]const f32, // [head_dim]
    // Post-attention RMSNorm
    post_attn_norm_w: [*]const f32, // [hidden_size]
    // SwiGLU MLP (no bias)
    gate_proj_w: [*]const f32, // [intermediate, hidden_size]
    up_proj_w: [*]const f32, // [intermediate, hidden_size]
    down_proj_w: [*]const f32, // [hidden_size, intermediate]
};

// ── Scratch buffers ──
const MAX_SEQ: usize = 4096;
const MAX_HIDDEN: usize = 2048;
const MAX_FF: usize = 6144;
const MAX_HEADS: usize = 16;
const MAX_KV_HEADS: usize = 8;
const MAX_HD: usize = 128;
const MAX_VOCAB: usize = 151936;

var hidden: [MAX_HIDDEN]f32 = undefined; // current token hidden state
var norm_out: [MAX_HIDDEN]f32 = undefined;
var q_buf: [MAX_HEADS * MAX_HD]f32 = undefined; // 16*128 = 2048
var k_buf: [MAX_KV_HEADS * MAX_HD]f32 = undefined; // 8*128 = 1024
var v_buf: [MAX_KV_HEADS * MAX_HD]f32 = undefined;
var attn_scores: [MAX_SEQ]f32 = undefined;
var attn_result: [MAX_HIDDEN]f32 = undefined;
var gate_buf: [MAX_FF]f32 = undefined;
var up_buf: [MAX_FF]f32 = undefined;
var mlp_out: [MAX_HIDDEN]f32 = undefined;
var logits_buf: [MAX_VOCAB]f32 = undefined;

// ── KV Cache ──
// Per-layer: k[max_seq, kv_dim] and v[max_seq, kv_dim]
// For 1.7B: 28 layers × 4096 × 1024 × 2 (k+v) × 4 bytes = ~900MB
// This is large. Use f16 to halve it: 28 × 4096 × 1024 × 2 × 2 = ~450MB
// For now: f32, allocated via VirtualAlloc at runtime (not static).
pub const KVCache = struct {
    k: [*]f32, // [n_layers, max_seq, kv_dim]
    v: [*]f32, // [n_layers, max_seq, kv_dim]
    seq_len: usize, // current sequence position

    pub fn getK(self: *const KVCache, layer: usize, cfg: *const DecoderConfig) [*]f32 {
        return self.k + layer * cfg.max_seq_len * cfg.kvDim();
    }
    pub fn getV(self: *const KVCache, layer: usize, cfg: *const DecoderConfig) [*]f32 {
        return self.v + layer * cfg.max_seq_len * cfg.kvDim();
    }
};

// ── Core Operations ──

/// RMSNorm: x / sqrt(mean(x^2) + eps) * weight
fn rmsNorm(input: [*]const f32, output: [*]f32, weight: [*]const f32, dim: usize, eps: f32) void {
    var ss: f32 = 0.0;
    var i: usize = 0;
    while (i < dim) : (i += 1) ss += input[i] * input[i];
    ss = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(dim)) + eps);
    i = 0;
    while (i < dim) : (i += 1) output[i] = input[i] * ss * weight[i];
}

/// Per-head RMSNorm: normalize each head independently
fn perHeadRmsNorm(qk: [*]f32, weight: [*]const f32, n_heads: usize, head_dim: usize, eps: f32) void {
    var h: usize = 0;
    while (h < n_heads) : (h += 1) {
        const base = h * head_dim;
        var ss: f32 = 0.0;
        var i: usize = 0;
        while (i < head_dim) : (i += 1) ss += qk[base + i] * qk[base + i];
        ss = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(head_dim)) + eps);
        i = 0;
        while (i < head_dim) : (i += 1) qk[base + i] = qk[base + i] * ss * weight[i];
    }
}

/// NeoX split-half RoPE: rotate_half(x) = cat(-x[d/2:], x[:d/2])
/// Applied in-place to q[n_heads, head_dim] and k[n_kv_heads, head_dim]
fn applyRoPE(q: [*]f32, k: [*]f32, n_heads: usize, n_kv_heads: usize, head_dim: usize, pos: usize, theta: f32) void {
    const half = head_dim / 2;

    // Precompute cos/sin for this position
    var cos_cache: [MAX_HD]f32 = undefined;
    var sin_cache: [MAX_HD]f32 = undefined;
    var i: usize = 0;
    while (i < half) : (i += 1) {
        const freq = 1.0 / math.pow(f32, theta, @as(f32, @floatFromInt(i * 2)) / @as(f32, @floatFromInt(head_dim)));
        const angle = @as(f32, @floatFromInt(pos)) * freq;
        cos_cache[i] = @cos(angle);
        sin_cache[i] = @sin(angle);
        cos_cache[i + half] = cos_cache[i]; // duplicate for full head_dim
        sin_cache[i + half] = sin_cache[i];
    }

    // Apply to Q
    var h: usize = 0;
    while (h < n_heads) : (h += 1) {
        const base = h * head_dim;
        // rotate_half: result = x * cos + cat(-x[half:], x[:half]) * sin
        i = 0;
        while (i < half) : (i += 1) {
            const x0 = q[base + i];
            const x1 = q[base + half + i];
            q[base + i] = x0 * cos_cache[i] - x1 * sin_cache[i];
            q[base + half + i] = x1 * cos_cache[i] + x0 * sin_cache[i];
        }
    }

    // Apply to K
    h = 0;
    while (h < n_kv_heads) : (h += 1) {
        const base = h * head_dim;
        i = 0;
        while (i < half) : (i += 1) {
            const x0 = k[base + i];
            const x1 = k[base + half + i];
            k[base + i] = x0 * cos_cache[i] - x1 * sin_cache[i];
            k[base + half + i] = x1 * cos_cache[i] + x0 * sin_cache[i];
        }
    }
}

/// SiLU activation: x * sigmoid(x)
fn silu(x: f32) f32 {
    return x / (1.0 + @exp(-x));
}

/// Matrix-vector multiply: out[n] = weight[n, k] @ input[k]
fn matvec(output: [*]f32, weight: [*]const f32, input: [*]const f32, n: usize, k: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sum: f32 = 0.0;
        var j: usize = 0;
        while (j < k) : (j += 1) sum += weight[i * k + j] * input[j];
        output[i] = sum;
    }
}

// ── Decoder Forward (single token, autoregressive) ──

/// Process one token through the decoder.
/// For prefill: call repeatedly with each token embedding.
/// For generation: call with the embedding of the previously generated token.
/// Returns: next token ID (greedy argmax of logits).
pub fn forward(
    input_embed: [*]const f32, // [hidden_size] — token embedding or audio embedding
    kv: *KVCache,
    weights: *const DecoderWeights,
    cfg: *const DecoderConfig,
) u32 {
    const d = cfg.hidden_size;
    const pos = kv.seq_len;

    // Copy input embedding to hidden state
    var i: usize = 0;
    while (i < d) : (i += 1) hidden[i] = input_embed[i];

    // Process through all layers
    var layer: usize = 0;
    while (layer < cfg.n_layers) : (layer += 1) {
        const lw = &weights.layers[layer];

        // Input RMSNorm
        rmsNorm(&hidden, &norm_out, lw.input_norm_w, d, cfg.rms_norm_eps);

        // QKV projections
        matvec(&q_buf, lw.q_proj_w, &norm_out, cfg.n_heads * cfg.head_dim, d);
        matvec(&k_buf, lw.k_proj_w, &norm_out, cfg.n_kv_heads * cfg.head_dim, d);
        matvec(&v_buf, lw.v_proj_w, &norm_out, cfg.n_kv_heads * cfg.head_dim, d);

        // Per-head Q/K RMSNorm
        perHeadRmsNorm(&q_buf, lw.q_norm_w, cfg.n_heads, cfg.head_dim, cfg.rms_norm_eps);
        perHeadRmsNorm(&k_buf, lw.k_norm_w, cfg.n_kv_heads, cfg.head_dim, cfg.rms_norm_eps);

        // RoPE
        applyRoPE(&q_buf, &k_buf, cfg.n_heads, cfg.n_kv_heads, cfg.head_dim, pos, cfg.rope_theta);

        // Store K, V in cache
        const kv_dim = cfg.kvDim();
        const k_cache = kv.getK(layer, cfg);
        const v_cache = kv.getV(layer, cfg);
        i = 0;
        while (i < kv_dim) : (i += 1) {
            k_cache[pos * kv_dim + i] = k_buf[i];
            v_cache[pos * kv_dim + i] = v_buf[i];
        }

        // Grouped Query Attention (causal)
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(cfg.head_dim)));
        const gqa_ratio = cfg.gqaRatio();

        var h: usize = 0;
        while (h < cfg.n_heads) : (h += 1) {
            const kv_head = h / gqa_ratio;
            const q_offset = h * cfg.head_dim;

            // Compute attention scores for all cached positions
            var t: usize = 0;
            while (t <= pos) : (t += 1) {
                var dot: f32 = 0.0;
                var di: usize = 0;
                while (di < cfg.head_dim) : (di += 1) {
                    dot += q_buf[q_offset + di] * k_cache[t * kv_dim + kv_head * cfg.head_dim + di];
                }
                attn_scores[t] = dot * scale;
            }

            // Softmax over [0..pos]
            var max_s: f32 = attn_scores[0];
            t = 1;
            while (t <= pos) : (t += 1) { if (attn_scores[t] > max_s) max_s = attn_scores[t]; }
            var sum_exp: f32 = 0.0;
            t = 0;
            while (t <= pos) : (t += 1) { attn_scores[t] = @exp(attn_scores[t] - max_s); sum_exp += attn_scores[t]; }
            t = 0;
            while (t <= pos) : (t += 1) attn_scores[t] /= sum_exp;

            // Weighted sum of values
            var di: usize = 0;
            while (di < cfg.head_dim) : (di += 1) {
                var val: f32 = 0.0;
                t = 0;
                while (t <= pos) : (t += 1) {
                    val += attn_scores[t] * v_cache[t * kv_dim + kv_head * cfg.head_dim + di];
                }
                attn_result[q_offset + di] = val;
            }
        }

        // Output projection + residual
        matvec(&norm_out, lw.o_proj_w, &attn_result, d, d);
        i = 0;
        while (i < d) : (i += 1) hidden[i] += norm_out[i];

        // Post-attention RMSNorm
        rmsNorm(&hidden, &norm_out, lw.post_attn_norm_w, d, cfg.rms_norm_eps);

        // SwiGLU MLP
        matvec(&gate_buf, lw.gate_proj_w, &norm_out, cfg.intermediate_size, d);
        matvec(&up_buf, lw.up_proj_w, &norm_out, cfg.intermediate_size, d);
        // gate = silu(gate) * up
        i = 0;
        while (i < cfg.intermediate_size) : (i += 1) gate_buf[i] = silu(gate_buf[i]) * up_buf[i];
        // down projection + residual
        matvec(&mlp_out, lw.down_proj_w, &gate_buf, d, cfg.intermediate_size);
        i = 0;
        while (i < d) : (i += 1) hidden[i] += mlp_out[i];
    }

    // Final RMSNorm
    rmsNorm(&hidden, &norm_out, weights.norm_w, d, cfg.rms_norm_eps);

    // LM head (tied with embeddings): logits = norm_out @ embed_tokens^T
    // This is a matvec with transposed embed: out[v] = sum_d(norm_out[d] * embed[v, d])
    matvec(&logits_buf, weights.embed_tokens, &norm_out, cfg.vocab_size, d);

    // Greedy argmax
    var max_logit: f32 = logits_buf[0];
    var max_id: u32 = 0;
    i = 1;
    while (i < cfg.vocab_size) : (i += 1) {
        if (logits_buf[i] > max_logit) {
            max_logit = logits_buf[i];
            max_id = @intCast(i);
        }
    }

    // Advance sequence position
    kv.seq_len += 1;

    return max_id;
}

/// Get token embedding from the embedding table
pub fn getEmbedding(token_id: u32, weights: *const DecoderWeights, cfg: *const DecoderConfig) [*]const f32 {
    return weights.embed_tokens + @as(usize, token_id) * cfg.hidden_size;
}

/// Check if a token is an EOS token
pub fn isEos(token_id: u32) bool {
    return token_id == TOKEN_EOS1 or token_id == TOKEN_EOS2;
}
