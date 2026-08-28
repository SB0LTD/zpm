// @zpm/asr — Audio Encoder Module
// Implements Qwen3-ASR encoder: Conv2D stem + transformer encoder + projection.
//
// Architecture (1.7B variant):
//   Conv2D Stem: 3 layers (in=1, out=480, k=3, s=2, pad=1) + GELU
//     Input: [1, 128, T_frames] → Output after 3 convs: [480, 16, T/8]
//     Reshape: [T/8, 7680] → Linear(7680, 1024) = [T/8, 1024]
//   Sinusoidal PE: per-chunk (100 frames → 13 tokens per chunk)
//   Transformer: 24 layers, d=1024, heads=16, head_dim=64, FFN=4096
//     LayerNorm (with bias), full bidirectional attention
//     Windowed: 104 tokens per attention window
//   Projection: LayerNorm → Linear(1024, 1024) + GELU → Linear(1024, 2048)
//
// CRITICAL: Conv2D is applied per-chunk (100 mel frames at a time).
//   Each chunk of 100 mel frames → 13 encoder tokens.
//
// Weight format: BF16 safetensors (mmap'd at runtime).
// Zero heap allocations — all scratch is comptime-sized statics.

const math = @import("std").math;

// ── Model configuration ──
pub const Config = struct {
    d_model: usize, // 1024 for 1.7B, 896 for 0.6B
    n_layers: usize, // 24 for 1.7B, 18 for 0.6B
    n_heads: usize, // 16 for 1.7B, 14 for 0.6B
    head_dim: usize, // 64 for both
    ffn_dim: usize, // 4096 for 1.7B, 3584 for 0.6B
    output_dim: usize, // 2048 for 1.7B, 1024 for 0.6B
    conv_channels: usize, // 480
    mel_bins: usize, // 128
    chunk_frames: usize, // 100 (mel frames per chunk)
    tokens_per_chunk: usize, // 13 (output tokens per 100-frame chunk)
    window_size: usize, // 104 tokens (attention window)
};

pub const CONFIG_1_7B = Config{
    .d_model = 1024,
    .n_layers = 24,
    .n_heads = 16,
    .head_dim = 64,
    .ffn_dim = 4096,
    .output_dim = 2048,
    .conv_channels = 480,
    .mel_bins = 128,
    .chunk_frames = 100,
    .tokens_per_chunk = 13,
    .window_size = 104,
};

pub const CONFIG_0_6B = Config{
    .d_model = 896,
    .n_layers = 18,
    .n_heads = 14,
    .head_dim = 64,
    .ffn_dim = 3584,
    .output_dim = 1024,
    .conv_channels = 480,
    .mel_bins = 128,
    .chunk_frames = 100,
    .tokens_per_chunk = 13,
    .window_size = 104,
};

// ── Weight pointers ──
// These point into mmap'd safetensors/GGUF data. Set by the model loader.
pub const EncoderWeights = struct {
    // Conv2D stem (BF16 → f32 at load time or on-the-fly)
    conv1_w: [*]const f32, // [480, 1, 3, 3] = 4320 f32
    conv1_b: [*]const f32, // [480]
    conv2_w: [*]const f32, // [480, 480, 3, 3] = 2073600 f32
    conv2_b: [*]const f32, // [480]
    conv3_w: [*]const f32, // [480, 480, 3, 3] = 2073600 f32
    conv3_b: [*]const f32, // [480]

    // Conv output projection (7680 → d_model, no bias)
    conv_out_w: [*]const f32, // [d_model, 7680]

    // Transformer layers
    layers: [*]const LayerWeights,

    // Post-encoder LayerNorm
    ln_post_w: [*]const f32, // [d_model]
    ln_post_b: [*]const f32, // [d_model]

    // Projection
    proj1_w: [*]const f32, // [d_model, d_model]
    proj1_b: [*]const f32, // [d_model]
    proj2_w: [*]const f32, // [output_dim, d_model]
    proj2_b: [*]const f32, // [output_dim]
};

pub const LayerWeights = struct {
    // Self-attention
    q_w: [*]const f32, // [d_model, d_model]
    q_b: [*]const f32, // [d_model]
    k_w: [*]const f32, // [d_model, d_model]
    k_b: [*]const f32, // [d_model]
    v_w: [*]const f32, // [d_model, d_model]
    v_b: [*]const f32, // [d_model]
    out_w: [*]const f32, // [d_model, d_model]
    out_b: [*]const f32, // [d_model]
    // Self-attention LayerNorm
    attn_norm_w: [*]const f32, // [d_model]
    attn_norm_b: [*]const f32, // [d_model]
    // FFN
    fc1_w: [*]const f32, // [ffn_dim, d_model]
    fc1_b: [*]const f32, // [ffn_dim]
    fc2_w: [*]const f32, // [d_model, ffn_dim]
    fc2_b: [*]const f32, // [d_model]
    // FFN LayerNorm
    ffn_norm_w: [*]const f32, // [d_model]
    ffn_norm_b: [*]const f32, // [d_model]
};

// ── Scratch buffers (static, comptime-sized for 1.7B) ──
// Max tokens in a single encode call: 8 seconds of audio = ~104 tokens
const MAX_ENC_TOKENS: usize = 512;
const MAX_D: usize = 1024;
const MAX_FF: usize = 4096;
const MAX_CONV_CH: usize = 480;
const CONV_FLAT: usize = 7680; // 480 * 16 (channels * freq_bins_after_conv)

// Conv2D intermediate buffers
// After each conv: [channels, freq/2, time/2]
// Max size per conv output: 480 * 64 * (100/2) = 480*64*50 per chunk... 
// Actually per chunk of 100 frames:
//   After conv1: [480, 64, 50] = 1,536,000 f32
//   After conv2: [480, 32, 25] = 384,000 f32
//   After conv3: [480, 16, 13] = 99,840 f32 (the 13 tokens!)
// This is too large for stack. Use file-scope statics.
var conv_buf1: [MAX_CONV_CH * 64 * 50]f32 = undefined;
var conv_buf2: [MAX_CONV_CH * 32 * 25]f32 = undefined;
var conv_buf3: [MAX_CONV_CH * 16 * 13]f32 = undefined;

// Encoder token buffer (after conv projection): [MAX_ENC_TOKENS, MAX_D]
var enc_tokens: [MAX_ENC_TOKENS * MAX_D]f32 = undefined;

// Transformer scratch
var attn_q: [MAX_ENC_TOKENS * MAX_D]f32 = undefined;
var attn_k: [MAX_ENC_TOKENS * MAX_D]f32 = undefined;
var attn_v: [MAX_ENC_TOKENS * MAX_D]f32 = undefined;
var attn_out_buf: [MAX_ENC_TOKENS * MAX_D]f32 = undefined;
var ffn_buf: [MAX_ENC_TOKENS * MAX_FF]f32 = undefined;
var norm_buf: [MAX_ENC_TOKENS * MAX_D]f32 = undefined;

// Output buffer (after projection): [MAX_ENC_TOKENS, output_dim]
var enc_output: [MAX_ENC_TOKENS * 2048]f32 = undefined;

// ── Core Operations ──

/// GELU activation (exact formula)
fn gelu(x: f32) f32 {
    // GELU(x) = x * 0.5 * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
    const c = 0.7978845608; // sqrt(2/pi)
    const inner = c * (x + 0.044715 * x * x * x);
    return x * 0.5 * (1.0 + math.tanh(inner));
}

/// LayerNorm with weight and bias (encoder uses full LN, not RMS)
fn layerNorm(input: [*]f32, output: [*]f32, w: [*]const f32, b: [*]const f32, dim: usize, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = i * dim;
        // Compute mean
        var mean: f32 = 0.0;
        var j: usize = 0;
        while (j < dim) : (j += 1) mean += input[base + j];
        mean /= @as(f32, @floatFromInt(dim));
        // Compute variance
        var variance: f32 = 0.0;
        j = 0;
        while (j < dim) : (j += 1) {
            const d = input[base + j] - mean;
            variance += d * d;
        }
        variance /= @as(f32, @floatFromInt(dim));
        const inv_std = 1.0 / @sqrt(variance + 1e-5);
        // Normalize, scale, shift
        j = 0;
        while (j < dim) : (j += 1) {
            output[base + j] = (input[base + j] - mean) * inv_std * w[j] + b[j];
        }
    }
}

/// Matrix multiply: C[m,n] = A[m,k] @ B^T[n,k] (weight layout: [out, in])
/// This is the hot path — on Windows/CUDA we'd dispatch to cuBLAS.
/// For now: naive triple loop (placeholder for cuBLAS integration).
fn matmulTransB(c_out: [*]f32, a: [*]const f32, b: [*]const f32, m: usize, k: usize, n: usize) void {
    var i: usize = 0;
    while (i < m) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            var sum: f32 = 0.0;
            var l: usize = 0;
            while (l < k) : (l += 1) {
                sum += a[i * k + l] * b[j * k + l];
            }
            c_out[i * n + j] = sum;
        }
    }
}

/// Add bias to each row of matrix [m, n]
fn addBias(data: [*]f32, bias: [*]const f32, m: usize, n: usize) void {
    var i: usize = 0;
    while (i < m) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            data[i * n + j] += bias[j];
        }
    }
}

/// Apply GELU to all elements
fn applyGelu(data: [*]f32, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) data[i] = gelu(data[i]);
}

// ── Conv2D (3×3, stride 2, padding 1) ──
// Operates on [channels_in, height, width] → [channels_out, height/2, width/2]
fn conv2d3x3s2(
    input: [*]const f32, // [c_in, h, w]
    output: [*]f32, // [c_out, h/2, w/2]
    weight: [*]const f32, // [c_out, c_in, 3, 3]
    bias: [*]const f32, // [c_out]
    c_in: usize, c_out: usize, h: usize, w: usize,
) void {
    const h_out = h / 2;
    const w_out = w / 2;

    var oc: usize = 0;
    while (oc < c_out) : (oc += 1) {
        var oh: usize = 0;
        while (oh < h_out) : (oh += 1) {
            var ow: usize = 0;
            while (ow < w_out) : (ow += 1) {
                var sum: f32 = bias[oc];
                // 3x3 kernel with stride 2
                const ih_base: isize = @as(isize, @intCast(oh * 2)) - 1; // padding=1
                const iw_base: isize = @as(isize, @intCast(ow * 2)) - 1;

                var ic: usize = 0;
                while (ic < c_in) : (ic += 1) {
                    var kh: usize = 0;
                    while (kh < 3) : (kh += 1) {
                        var kw: usize = 0;
                        while (kw < 3) : (kw += 1) {
                            const ih = ih_base + @as(isize, @intCast(kh));
                            const iw = iw_base + @as(isize, @intCast(kw));
                            if (ih >= 0 and ih < @as(isize, @intCast(h)) and
                                iw >= 0 and iw < @as(isize, @intCast(w)))
                            {
                                const ih_u: usize = @intCast(ih);
                                const iw_u: usize = @intCast(iw);
                                const input_idx = ic * h * w + ih_u * w + iw_u;
                                const weight_idx = oc * c_in * 9 + ic * 9 + kh * 3 + kw;
                                sum += input[input_idx] * weight[weight_idx];
                            }
                        }
                    }
                }
                output[oc * h_out * w_out + oh * w_out + ow] = sum;
            }
        }
    }
}

// ── Sinusoidal Positional Encoding ──
fn addSinusoidalPE(tokens: [*]f32, n_tokens: usize, d_model: usize) void {
    const log_timescale = math.log(f32, math.e, 10000.0) / @as(f32, @floatFromInt(d_model / 2 - 1));
    var pos: usize = 0;
    while (pos < n_tokens) : (pos += 1) {
        var i: usize = 0;
        while (i < d_model / 2) : (i += 1) {
            const inv_ts = @exp(-@as(f32, @floatFromInt(i)) * log_timescale);
            const angle = @as(f32, @floatFromInt(pos)) * inv_ts;
            tokens[pos * d_model + i] += @sin(angle);
            tokens[pos * d_model + d_model / 2 + i] += @cos(angle);
        }
    }
}

// ── Bidirectional Multi-Head Attention (windowed) ──
fn selfAttention(
    input: [*]f32, // [n_tokens, d_model]
    output: [*]f32, // [n_tokens, d_model]
    layer: *const LayerWeights,
    cfg: *const Config,
    n_tokens: usize,
) void {
    const d = cfg.d_model;
    const nh = cfg.n_heads;
    const hd = cfg.head_dim;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));

    // Q = input @ Wq + bq
    matmulTransB(&attn_q, input, layer.q_w, n_tokens, d, d);
    addBias(&attn_q, layer.q_b, n_tokens, d);
    // K = input @ Wk + bk
    matmulTransB(&attn_k, input, layer.k_w, n_tokens, d, d);
    addBias(&attn_k, layer.k_b, n_tokens, d);
    // V = input @ Wv + bv
    matmulTransB(&attn_v, input, layer.v_w, n_tokens, d, d);
    addBias(&attn_v, layer.v_b, n_tokens, d);

    // Multi-head attention (bidirectional, windowed)
    // For simplicity: full attention within window_size blocks
    const win = cfg.window_size;

    var h: usize = 0;
    while (h < nh) : (h += 1) {
        // Process each attention window
        var win_start: usize = 0;
        while (win_start < n_tokens) : (win_start += win) {
            const win_end = @min(win_start + win, n_tokens);
            const win_len = win_end - win_start;

            // For each query position in this window
            var qi: usize = win_start;
            while (qi < win_end) : (qi += 1) {
                // Compute attention scores for all keys in window
                var max_score: f32 = -math.inf(f32);
                var ki: usize = win_start;
                while (ki < win_end) : (ki += 1) {
                    // dot product of Q[qi, h] . K[ki, h]
                    var dot: f32 = 0.0;
                    var di: usize = 0;
                    while (di < hd) : (di += 1) {
                        dot += attn_q[qi * d + h * hd + di] * attn_k[ki * d + h * hd + di];
                    }
                    dot *= scale;
                    // Store in a temp (reuse part of attn_out_buf)
                    attn_out_buf[(qi - win_start) * win_len + (ki - win_start)] = dot;
                    if (dot > max_score) max_score = dot;
                }

                // Softmax
                var sum_exp: f32 = 0.0;
                ki = 0;
                while (ki < win_len) : (ki += 1) {
                    const idx = (qi - win_start) * win_len + ki;
                    attn_out_buf[idx] = @exp(attn_out_buf[idx] - max_score);
                    sum_exp += attn_out_buf[idx];
                }
                ki = 0;
                while (ki < win_len) : (ki += 1) {
                    attn_out_buf[(qi - win_start) * win_len + ki] /= sum_exp;
                }

                // Weighted sum of values
                var di: usize = 0;
                while (di < hd) : (di += 1) {
                    var val: f32 = 0.0;
                    ki = 0;
                    while (ki < win_len) : (ki += 1) {
                        val += attn_out_buf[(qi - win_start) * win_len + ki] *
                            attn_v[(win_start + ki) * d + h * hd + di];
                    }
                    output[qi * d + h * hd + di] = val;
                }
            }
        }
    }

    // Output projection: attn_out @ Wo + bo
    // Copy output to temp, then matmul back
    const n = n_tokens * d;
    var i: usize = 0;
    while (i < n) : (i += 1) norm_buf[i] = output[i];
    matmulTransB(output, &norm_buf, layer.out_w, n_tokens, d, d);
    addBias(output, layer.out_b, n_tokens, d);
}

// ── Encoder Forward Pass ──

/// Run the full encoder on mel spectrogram data.
/// Input: mel frames [n_frames, 128] stored as [*]const f32
/// Output: encoder output tokens [n_enc_tokens, output_dim] in enc_output
/// Returns: number of encoder tokens produced.
pub fn encode(
    mel: [*]const f32,
    n_frames: usize,
    weights: *const EncoderWeights,
    cfg: *const Config,
) usize {
    // Number of chunks (100 mel frames each)
    const n_chunks = (n_frames + cfg.chunk_frames - 1) / cfg.chunk_frames;
    const n_enc_tokens = n_chunks * cfg.tokens_per_chunk;

    if (n_enc_tokens > MAX_ENC_TOKENS) return 0; // Safety

    // Process each chunk through Conv2D stem
    var chunk: usize = 0;
    while (chunk < n_chunks) : (chunk += 1) {
        const frame_start = chunk * cfg.chunk_frames;
        const frame_end = @min(frame_start + cfg.chunk_frames, n_frames);
        const chunk_frames = frame_end - frame_start;

        // Conv2D stem on this chunk
        // Input layout: [1, 128, chunk_frames] (channel=1, freq=128, time=chunk_frames)
        // We need to rearrange mel from [frames, 128] to [1, 128, frames]
        // (it's the same data, just interpreted differently)
        const mel_chunk = mel + frame_start * 128;

        // Conv1: [1, 128, T] → [480, 64, T/2]
        conv2d3x3s2(mel_chunk, &conv_buf1, weights.conv1_w, weights.conv1_b,
            1, cfg.conv_channels, 128, chunk_frames);
        applyGelu(&conv_buf1, cfg.conv_channels * 64 * (chunk_frames / 2));

        // Conv2: [480, 64, T/2] → [480, 32, T/4]
        const t2 = chunk_frames / 2;
        conv2d3x3s2(&conv_buf1, &conv_buf2, weights.conv2_w, weights.conv2_b,
            cfg.conv_channels, cfg.conv_channels, 64, t2);
        applyGelu(&conv_buf2, cfg.conv_channels * 32 * (t2 / 2));

        // Conv3: [480, 32, T/4] → [480, 16, T/8]
        const t4 = t2 / 2;
        conv2d3x3s2(&conv_buf2, &conv_buf3, weights.conv3_w, weights.conv3_b,
            cfg.conv_channels, cfg.conv_channels, 32, t4);
        applyGelu(&conv_buf3, cfg.conv_channels * 16 * (t4 / 2));

        // Reshape [480, 16, T/8] → [T/8, 480*16] = [tokens_per_chunk, 7680]
        // Then linear projection: [tokens_per_chunk, 7680] → [tokens_per_chunk, d_model]
        const t8 = t4 / 2; // = tokens_per_chunk (should be 13 for chunk of 100)
        const token_base = chunk * cfg.tokens_per_chunk;

        var t: usize = 0;
        while (t < t8) : (t += 1) {
            // Gather [480, 16] at time position t into a flat 7680 vector
            var flat: [CONV_FLAT]f32 = undefined;
            var c: usize = 0;
            while (c < cfg.conv_channels) : (c += 1) {
                var f: usize = 0;
                while (f < 16) : (f += 1) {
                    flat[c * 16 + f] = conv_buf3[c * 16 * t8 + f * t8 + t];
                }
            }
            // Linear projection: flat[7680] @ conv_out_w^T → enc_tokens[token, d_model]
            const out_base = (token_base + t) * cfg.d_model;
            var d: usize = 0;
            while (d < cfg.d_model) : (d += 1) {
                var sum: f32 = 0.0;
                var k: usize = 0;
                while (k < CONV_FLAT) : (k += 1) {
                    sum += flat[k] * weights.conv_out_w[d * CONV_FLAT + k];
                }
                enc_tokens[out_base + d] = sum;
            }
        }

        // Add sinusoidal PE (per-chunk, positions start from 0)
        addSinusoidalPE(enc_tokens[token_base * cfg.d_model ..].ptr, t8, cfg.d_model);
    }

    // Transformer encoder layers
    var layer: usize = 0;
    while (layer < cfg.n_layers) : (layer += 1) {
        const lw = &weights.layers[layer];
        const d = cfg.d_model;

        // Pre-attention LayerNorm
        layerNorm(&enc_tokens, &norm_buf, lw.attn_norm_w, lw.attn_norm_b, d, n_enc_tokens);

        // Self-attention (bidirectional, windowed)
        selfAttention(&norm_buf, &attn_out_buf, lw, cfg, n_enc_tokens);

        // Residual connection
        var i: usize = 0;
        while (i < n_enc_tokens * d) : (i += 1) enc_tokens[i] += attn_out_buf[i];

        // Pre-FFN LayerNorm
        layerNorm(&enc_tokens, &norm_buf, lw.ffn_norm_w, lw.ffn_norm_b, d, n_enc_tokens);

        // FFN: GELU(x @ W_fc1 + b_fc1) @ W_fc2 + b_fc2
        matmulTransB(&ffn_buf, &norm_buf, lw.fc1_w, n_enc_tokens, d, cfg.ffn_dim);
        addBias(&ffn_buf, lw.fc1_b, n_enc_tokens, cfg.ffn_dim);
        applyGelu(&ffn_buf, n_enc_tokens * cfg.ffn_dim);
        matmulTransB(&attn_out_buf, &ffn_buf, lw.fc2_w, n_enc_tokens, cfg.ffn_dim, d);
        addBias(&attn_out_buf, lw.fc2_b, n_enc_tokens, d);

        // Residual
        i = 0;
        while (i < n_enc_tokens * d) : (i += 1) enc_tokens[i] += attn_out_buf[i];
    }

    // Post-encoder LayerNorm
    layerNorm(&enc_tokens, &norm_buf, weights.ln_post_w, weights.ln_post_b, cfg.d_model, n_enc_tokens);

    // Projection: GELU(norm @ proj1 + b1) @ proj2 + b2
    matmulTransB(&enc_tokens, &norm_buf, weights.proj1_w, n_enc_tokens, cfg.d_model, cfg.d_model);
    addBias(&enc_tokens, weights.proj1_b, n_enc_tokens, cfg.d_model);
    applyGelu(&enc_tokens, n_enc_tokens * cfg.d_model);
    matmulTransB(&enc_output, &enc_tokens, weights.proj2_w, n_enc_tokens, cfg.d_model, cfg.output_dim);
    addBias(&enc_output, weights.proj2_b, n_enc_tokens, cfg.output_dim);

    return n_enc_tokens;
}

/// Get pointer to encoder output buffer
pub fn getOutput() [*]f32 {
    return &enc_output;
}
