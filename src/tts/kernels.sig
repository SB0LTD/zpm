//! Custom CUDA kernels for the Qwen3-TTS neural decode pipeline.
//!
//! The vocoder and codec transformer spend most of their per-frame time in
//! elementwise / convolution work that the CPU path re-reads and recomputes
//! frame by frame. This module compiles a single CUDA-C source string to cubin
//! once at init (via the matmul_cuda NVRTC pipeline), resolves the kernel
//! handles, and exposes typed launch wrappers plus persistent device scratch.
//!
//! Numerics deliberately mirror the CPU references (vocoder.sig /
//! codec_transformer.sig) so the GPU and CPU paths agree bit-closely:
//!   - snakeBeta: v + sin(v*exp(alpha))^2 / (exp(beta) + 1e-9)
//!   - gelu:      0.5*v*(1 + erf(v/sqrt2)) with the same Abramowitz erf-poly
//!   - layerNorm: mean/var over channels, eps 1e-6
//!   - rmsNorm:   1/sqrt(mean(v^2)+eps) * weight
//!   - siluGate:  gate = silu(gate) * up
//!
//! Everything degrades gracefully: if the custom-kernel pipeline is not
//! available (no GPU, missing NVRTC), `ready()` is false and callers keep using
//! the exact CPU path.

const std = @import("std");
const cuda = @import("matmul_cuda");
const sb0m = @import("tts_model_container");
const quantized = @import("quantized_linear");

pub const CUdeviceptr = cuda.CUdeviceptr;
pub const Source = sb0m.Source;
pub const Tensor = sb0m.Tensor;

// One CUDA-C translation unit holding every kernel. Compiled to cubin (SASS)
// for the real SM target at init, so the driver never JITs PTX.
const KERNEL_SOURCE =
    \\extern "C" {
    \\
    \\// erf matching vocoder.sig's Abramowitz-Stegun 7.1.26 polynomial so GPU
    \\// gelu equals the CPU gelu to <1.5e-7.
    \\__device__ __forceinline__ float erf_poly(float value) {
    \\  float sign = value < 0.0f ? -1.0f : 1.0f;
    \\  float x = fabsf(value);
    \\  float t = 1.0f / (1.0f + 0.3275911f * x);
    \\  float p = (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t
    \\            - 0.284496736f) * t + 0.254829592f) * t;
    \\  return sign * (1.0f - p * expf(-(x * x)));
    \\}
    \\
    \\// dst[i] = src[i] — device-to-device copy.
    \\__global__ void k_copy(float* dst, const float* src, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) dst[i] = src[i];
    \\}
    \\
    \\// dst[i] = 0
    \\__global__ void k_zero(float* dst, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) dst[i] = 0.0f;
    \\}
    \\
    \\// y[i] = silu(x[i]) — plain elementwise (used by the self-test / talker).
    \\__global__ void k_silu(const float* x, float* y, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) { float v = x[i]; y[i] = v / (1.0f + expf(-v)); }
    \\}
    \\
    \\// gate[i] = (gate[i]/(1+e^-gate[i])) * up[i]  (in place on gate)
    \\__global__ void k_silu_gate(float* gate, const float* up, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) { float g = gate[i]; gate[i] = (g / (1.0f + expf(-g))) * up[i]; }
    \\}
    \\
    \\// gelu in place: x[i] = 0.5*x*(1+erf(x/sqrt2))
    \\__global__ void k_gelu(float* x, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) { float v = x[i]; x[i] = 0.5f * v * (1.0f + erf_poly(v * 0.7071067811865476f)); }
    \\}
    \\
    \\// dst[i] += src[i]
    \\__global__ void k_residual_add(float* dst, const float* src, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) dst[i] += src[i];
    \\}
    \\
    \\// x[f, c] += bias[c]  (per-channel bias broadcast over frames)
    \\__global__ void k_add_bias_rows(float* x, const float* bias, int frames, int channels) {
    \\  int idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\  int total = frames * channels;
    \\  if (idx < total) x[idx] += bias[idx % channels];
    \\}
    \\
    \\// dst[f, c] += scale[c] * src[f, c]  (per-channel scale broadcast over frames)
    \\__global__ void k_scale_add_rows(float* dst, const float* src, const float* scale,
    \\                                 int frames, int channels) {
    \\  int idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\  int total = frames * channels;
    \\  if (idx < total) dst[idx] += scale[idx % channels] * src[idx];
    \\}
    \\
    \\// Depthwise causal conv1d (groups == channels), kernel 7 dilation 1.
    \\// weight is [channels, 1, 7] row-major → wrow = weight + c*7.
    \\// out[f,c] = bias[c] + sum_{tap} wrow[tap] * X(f - (6-tap), c)
    \\// history is linear oldest..newest of the last 6 input frames.
    \\__global__ void k_depthwise7(const float* input, const float* weight,
    \\                             const float* bias, float* output,
    \\                             const float* history, int hist_count,
    \\                             int frames, int channels) {
    \\  int idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\  int total = frames * channels;
    \\  if (idx >= total) return;
    \\  int f = idx / channels;
    \\  int c = idx % channels;
    \\  const float* wrow = weight + (size_t)c * 7;
    \\  float acc = bias ? bias[c] : 0.0f;
    \\  for (int tap = 0; tap < 7; tap++) {
    \\    int lag = 6 - tap;
    \\    int src = f - lag;
    \\    float x;
    \\    if (src >= 0) x = input[(size_t)src * channels + c];
    \\    else { int h = hist_count + src; if (h >= 0 && h < hist_count) x = history[(size_t)h * channels + c]; else x = 0.0f; }
    \\    acc += wrow[tap] * x;
    \\  }
    \\  output[(size_t)f * channels + c] = acc;
    \\}
    \\
    \\// hidden[c] += delta[c] * scale[c]  (per-channel layer-scale residual)
    \\__global__ void k_scale_add(float* hidden, const float* delta, const float* scale, int n) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < n) hidden[i] += delta[i] * scale[i];
    \\}
    \\
    \\// SnakeBeta in place over [frames, channels] row-major.
    \\// v + sin(v*exp(alpha[c]))^2 / (exp(beta[c]) + 1e-9)
    \\__global__ void k_snake_beta(float* x, const float* alpha, const float* beta,
    \\                             int frames, int channels) {
    \\  int idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\  int total = frames * channels;
    \\  if (idx < total) {
    \\    int c = idx % channels;
    \\    float v = x[idx];
    \\    float a = expf(alpha[c]);
    \\    float b = expf(beta[c]);
    \\    float s = sinf(v * a);
    \\    x[idx] = v + s * s / (b + 1e-9f);
    \\  }
    \\}
    \\
    \\// LayerNorm over the channel axis, one block per frame. eps 1e-6.
    \\// x[frame, :] = (x - mean) / sqrt(var + eps) * weight + bias
    \\__global__ void k_layernorm(float* x, const float* weight, const float* bias,
    \\                            int frames, int channels) {
    \\  int frame = blockIdx.x;
    \\  if (frame >= frames) return;
    \\  float* row = x + (size_t)frame * channels;
    \\  // Single-thread reduction per row (channels are modest: 1024). Correct and
    \\  // simple; the win is not re-reading weights per frame from disk.
    \\  if (threadIdx.x == 0) {
    \\    double sum = 0.0;
    \\    for (int c = 0; c < channels; c++) sum += row[c];
    \\    float mean = (float)(sum / channels);
    \\    double sq = 0.0;
    \\    for (int c = 0; c < channels; c++) { double d = (double)row[c] - mean; sq += d * d; }
    \\    float inv = (float)(1.0 / sqrt(sq / channels + 1e-6));
    \\    for (int c = 0; c < channels; c++) row[c] = (row[c] - mean) * inv * weight[c] + bias[c];
    \\  }
    \\}
    \\
    \\// RMSNorm: out[c] = in[c] * (1/sqrt(mean(in^2)+eps)) * weight[c]
    \\// One block; single-thread f64 reduction to match the CPU exactly.
    \\__global__ void k_rmsnorm(const float* in, const float* weight, float* out,
    \\                          int n, float eps) {
    \\  if (threadIdx.x == 0 && blockIdx.x == 0) {
    \\    double sq = 0.0;
    \\    for (int c = 0; c < n; c++) sq += (double)in[c] * (double)in[c];
    \\    float inv = (float)(1.0 / sqrt(sq / (double)n + (double)eps));
    \\    for (int c = 0; c < n; c++) out[c] = in[c] * inv * weight[c];
    \\  }
    \\}
    \\
    \\// Per-head RMSNorm over a q/k vector of `heads` heads × head_dim, each head
    \\// normalized independently by the SAME `weight[head_dim]`. Matches the
    \\// codec/talker q_norm/k_norm. One thread per head.
    \\__global__ void k_head_rmsnorm(float* vec, const float* weight, int heads, int head_dim, float eps) {
    \\  int h = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (h >= heads) return;
    \\  float* v = vec + (size_t)h * head_dim;
    \\  double sq = 0.0;
    \\  for (int i = 0; i < head_dim; i++) sq += (double)v[i] * (double)v[i];
    \\  float inv = (float)(1.0 / sqrt(sq / (double)head_dim + (double)eps));
    \\  for (int i = 0; i < head_dim; i++) v[i] = v[i] * inv * weight[i];
    \\}
    \\
    \\// Split-half RoPE (Qwen): for each head, rotate pairs (i, i+head_dim/2) by
    \\// theta = position / 10000^(2i/head_dim). Matches codec_transformer.applyRope
    \\// and the talker's ropeSplitHalf (equal M-RoPE positions).
    \\__global__ void k_rope(float* vec, int heads, int head_dim, long long position, float theta_base) {
    \\  int h = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (h >= heads) return;
    \\  int half = head_dim / 2;
    \\  float* base = vec + (size_t)h * head_dim;
    \\  for (int pair = 0; pair < half; pair++) {
    \\    float exponent = (float)(pair * 2) / (float)head_dim;
    \\    float th = (float)position / powf(theta_base, exponent);
    \\    float c = cosf(th), s = sinf(th);
    \\    float a = base[pair];
    \\    float b = base[pair + half];
    \\    base[pair] = a * c - b * s;
    \\    base[pair + half] = b * c + a * s;
    \\  }
    \\}
    \\
    \\// Sliding-window attention with an f32 KV ring cache, matching
    \\// codec_transformer.attention. query[Q], keys/values[W*Q] f32 ring; position
    \\// is the current absolute step; count = min(position+1, W). One thread per
    \\// query head. scale = 1/sqrt(head_dim). Writes output[Q].
    \\__global__ void k_sliding_attention(const float* query, const float* keys, const float* values,
    \\                                    float* output, long long position, int heads, int head_dim, int window) {
    \\  int head = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (head >= heads) return;
    \\  int Q = heads * head_dim;
    \\  long long cnt = position + 1; if (cnt > window) cnt = window;
    \\  long long oldest = position + 1 - cnt;
    \\  float scale = 1.0f / sqrtf((float)head_dim);
    \\  int ho = head * head_dim;
    \\  // softmax over up to `window` scores held in registers via two passes.
    \\  float maxv = -3.4e38f;
    \\  // first pass: max
    \\  for (long long hh = 0; hh < cnt; hh++) {
    \\    long long absi = oldest + hh;
    \\    int slot = (int)(absi % window);
    \\    const float* k = keys + (size_t)slot * Q + ho;
    \\    float score = 0.0f;
    \\    for (int e = 0; e < head_dim; e++) score += query[ho + e] * k[e];
    \\    score *= scale;
    \\    if (score > maxv) maxv = score;
    \\  }
    \\  float sum = 0.0f;
    \\  for (int e = 0; e < head_dim; e++) output[ho + e] = 0.0f;
    \\  // second pass: exp + weighted sum
    \\  for (long long hh = 0; hh < cnt; hh++) {
    \\    long long absi = oldest + hh;
    \\    int slot = (int)(absi % window);
    \\    const float* k = keys + (size_t)slot * Q + ho;
    \\    const float* vv = values + (size_t)slot * Q + ho;
    \\    float score = 0.0f;
    \\    for (int e = 0; e < head_dim; e++) score += query[ho + e] * k[e];
    \\    float p = expf(score * scale - maxv);
    \\    sum += p;
    \\    for (int e = 0; e < head_dim; e++) output[ho + e] += p * vv[e];
    \\  }
    \\  float inv = 1.0f / sum;
    \\  for (int e = 0; e < head_dim; e++) output[ho + e] *= inv;
    \\}
    \\
    \\// Store a q/k/v vector into the KV ring at `slot` (f32).
    \\__global__ void k_store_kv(float* ring, const float* vec, int slot, int Q) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < Q) ring[(size_t)slot * Q + i] = vec[i];
    \\}
    \\
    \\// Grouped-query FULL causal attention over an f32 KV cache (no sliding
    \\// window). query[q_heads*head_dim], keys/values[cap*kv_dim] where
    \\// kv_dim = kv_heads*head_dim; each query head h attends with kv head
    \\// h/(q_heads/kv_heads). Attends positions [0, position]. One thread per
    \\// query head. scale = 1/sqrt(head_dim). Matches talker_executor.groupedAttention.
    \\__global__ void k_gqa_attention(const float* query, const float* keys, const float* values,
    \\                                float* output, int position, int q_heads, int kv_heads,
    \\                                int head_dim, int kv_dim) {
    \\  int qh = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (qh >= q_heads) return;
    \\  int group = q_heads / kv_heads;
    \\  int kvh = qh / group;
    \\  int qo = qh * head_dim;
    \\  int ko = kvh * head_dim;
    \\  int ctx = position + 1;
    \\  float scale = 1.0f / sqrtf((float)head_dim);
    \\  float maxv = -3.4e38f;
    \\  for (int t = 0; t < ctx; t++) {
    \\    const float* k = keys + (size_t)t * kv_dim + ko;
    \\    float score = 0.0f;
    \\    for (int e = 0; e < head_dim; e++) score += query[qo + e] * k[e];
    \\    score *= scale;
    \\    if (score > maxv) maxv = score;
    \\  }
    \\  float sum = 0.0f;
    \\  for (int e = 0; e < head_dim; e++) output[qo + e] = 0.0f;
    \\  for (int t = 0; t < ctx; t++) {
    \\    const float* k = keys + (size_t)t * kv_dim + ko;
    \\    const float* vv = values + (size_t)t * kv_dim + ko;
    \\    float score = 0.0f;
    \\    for (int e = 0; e < head_dim; e++) score += query[qo + e] * k[e];
    \\    float p = expf(score * scale - maxv);
    \\    sum += p;
    \\    for (int e = 0; e < head_dim; e++) output[qo + e] += p * vv[e];
    \\  }
    \\  float inv = 1.0f / sum;
    \\  for (int e = 0; e < head_dim; e++) output[qo + e] *= inv;
    \\}
    \\
    \\// Store a kv vector at absolute position `pos` in a linear f32 cache
    \\// [cap, kv_dim] (no ring; talker context <= cap).
    \\__global__ void k_store_kv_linear(float* cache, const float* vec, int pos, int kv_dim) {
    \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
    \\  if (i < kv_dim) cache[(size_t)pos * kv_dim + i] = vec[i];
    \\}
    \\
    \\// argmax over `n` logits -> writes the index into out_idx[0].
    \\__global__ void k_argmax(const float* logits, int* out_idx, int n) {
    \\  if (threadIdx.x == 0 && blockIdx.x == 0) {
    \\    int best = 0; float bv = logits[0];
    \\    for (int i = 1; i < n; i++) { if (logits[i] > bv) { bv = logits[i]; best = i; } }
    \\    out_idx[0] = best;
    \\  }
    \\}
    \\
    \\// Causal dilated conv1d over all frames at once, mirroring vocoder.sig's
    \\// causalConv. Weight is rank-3 [out_ch, in_ch, kernel] row-major. For output
    \\// (frame f, oc):
    \\//   out = bias[oc] + sum_{ic,tap} W[oc,ic,tap] * X(f, ic, tap)
    \\// where lagFrames = (kernel-1-tap)*dilation and the sampled input is:
    \\//   input[(f-lagFrames), ic]         if f-lagFrames >= 0
    \\//   history[(hist_count - (lagFrames-f)), ic]  if it exists (last `padding`
    \\//                                     input frames preceding frame 0)
    \\//   0                                otherwise
    \\// history layout is linear oldest..newest: hist[h*in_ch + ic], h in
    \\// [0, hist_count). padding = (kernel-1)*dilation.
    \\// One thread per (frame, out_channel).
    \\__global__ void k_causal_conv1d(const float* input, const float* weight,
    \\                                const float* bias, float* output,
    \\                                const float* history, int hist_count,
    \\                                int frames, int in_ch, int out_ch,
    \\                                int kernel, int dilation) {
    \\  int idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\  int total = frames * out_ch;
    \\  if (idx >= total) return;
    \\  int f = idx / out_ch;
    \\  int oc = idx % out_ch;
    \\  const float* wrow = weight + (size_t)oc * in_ch * kernel;
    \\  float acc = bias ? bias[oc] : 0.0f;
    \\  for (int ic = 0; ic < in_ch; ic++) {
    \\    const float* wk = wrow + ic * kernel;
    \\    for (int tap = 0; tap < kernel; tap++) {
    \\      int lag = (kernel - 1 - tap) * dilation;
    \\      int src = f - lag;             // in frame units
    \\      float x;
    \\      if (src >= 0) {
    \\        x = input[(size_t)src * in_ch + ic];
    \\      } else {
    \\        int h = hist_count + src;    // src negative -> index into history tail
    \\        if (h >= 0 && h < hist_count) x = history[(size_t)h * in_ch + ic];
    \\        else x = 0.0f;
    \\      }
    \\      acc += wk[tap] * x;
    \\    }
    \\  }
    \\  output[(size_t)f * out_ch + oc] = acc;
    \\}
    \\
    \\// Transposed (stride-up) conv1d over all frames, mirroring vocoder.sig's
    \\// `transposed`. Weight is rank-3 [in_ch, out_ch, kernel] row-major (PyTorch
    \\// ConvTranspose1d layout). Produces frames*stride output frames. With
    \\// kernel==stride there is no overlap; with kernel>stride each input frame
    \\// contributes to the current block (taps [0,stride)) and carries taps
    \\// [stride,kernel) into the NEXT block. We compute this exactly by, for each
    \\// output position (of*stride+phase, oc), summing over every input frame that
    \\// reaches it. Output position p = of*stride + phase. An input frame `if`
    \\// writes to output positions if*stride + t for t in [0,kernel). So input
    \\// frame `if` contributes to p iff t = p - if*stride is in [0,kernel).
    \\//   out[p, oc] = bias[oc] + carry_from_before(p) contributions handled by the
    \\//   same formula because carry is just input frames if<0 (history). We fold
    \\//   the previous-block carry via a history of the last input frame(s).
    \\// carry_frames = number of prior input frames whose window still overlaps
    \\// frame 0's block = ceil((kernel-stride)/stride) but since kernel<2*stride
    \\// for all our stages, carry spans exactly the single previous input frame.
    \\// history holds the last `carry_in` input frames [carry_in, in_ch].
    \\// One thread per (output_position, out_channel).
    \\__global__ void k_transposed_conv1d(const float* input, const float* weight,
    \\                                    const float* bias, float* output,
    \\                                    const float* history, int carry_in,
    \\                                    int frames, int in_ch, int out_ch,
    \\                                    int kernel, int stride) {
    \\  int idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\  int out_frames = frames * stride;
    \\  int total = out_frames * out_ch;
    \\  if (idx >= total) return;
    \\  int p = idx / out_ch;         // output frame position
    \\  int oc = idx % out_ch;
    \\  float acc = bias ? bias[oc] : 0.0f;
    \\  // Input frames whose window covers p satisfy t = p - ifr*stride in
    \\  // [0,kernel). The highest such ifr is p/stride; the span of contributing
    \\  // frames is at most ceil(kernel/stride)+1. Iterate down from if_hi and let
    \\  // the t-range guard reject the rest (works correctly for negative ifr,
    \\  // unlike C truncating division on a negative if_lo).
    \\  int if_hi = p / stride;
    \\  int span = (kernel + stride - 1) / stride + 1;
    \\  for (int ifr = if_hi; ifr > if_hi - span; ifr--) {
    \\    int t = p - ifr * stride;             // tap within kernel
    \\    if (t < 0 || t >= kernel) continue;
    \\    const float* xframe;
    \\    if (ifr >= 0 && ifr < frames) {
    \\      xframe = input + (size_t)ifr * in_ch;
    \\    } else {
    \\      int h = carry_in + ifr;             // ifr negative -> history tail
    \\      if (h < 0 || h >= carry_in) continue;
    \\      xframe = history + (size_t)h * in_ch;
    \\    }
    \\    for (int ic = 0; ic < in_ch; ic++) {
    \\      float w = weight[((size_t)ic * out_ch + oc) * kernel + t];
    \\      acc += xframe[ic] * w;
    \\    }
    \\  }
    \\  output[(size_t)p * out_ch + oc] = acc;
    \\}
    \\
    \\} // extern "C"
;

// ── Compiled module + kernel handles ──
var compiled: bool = false;
var compile_ok: bool = false;
var module: ?cuda.CUmodule = null;

var f_silu: ?cuda.CUfunction = null;
var f_silu_gate: ?cuda.CUfunction = null;
var f_gelu: ?cuda.CUfunction = null;
var f_residual_add: ?cuda.CUfunction = null;
var f_scale_add: ?cuda.CUfunction = null;
var f_snake_beta: ?cuda.CUfunction = null;
var f_layernorm: ?cuda.CUfunction = null;
var f_rmsnorm: ?cuda.CUfunction = null;
var f_causal_conv1d: ?cuda.CUfunction = null;
var f_transposed_conv1d: ?cuda.CUfunction = null;
var f_copy: ?cuda.CUfunction = null;
var f_zero: ?cuda.CUfunction = null;
var f_add_bias_rows: ?cuda.CUfunction = null;
var f_scale_add_rows: ?cuda.CUfunction = null;
var f_depthwise7: ?cuda.CUfunction = null;
var f_head_rmsnorm: ?cuda.CUfunction = null;
var f_rope: ?cuda.CUfunction = null;
var f_sliding_attention: ?cuda.CUfunction = null;
var f_store_kv: ?cuda.CUfunction = null;
var f_gqa_attention: ?cuda.CUfunction = null;
var f_store_kv_linear: ?cuda.CUfunction = null;
var f_argmax: ?cuda.CUfunction = null;

/// Compile the kernel module once and resolve all handles. Idempotent; returns
/// true only if the whole custom-kernel pipeline is usable and every kernel
/// resolved. Safe to call repeatedly and on GPU-less machines (returns false).
pub fn ready() bool {
    if (compiled) return compile_ok;
    compiled = true;
    compile_ok = false;

    if (!cuda.init()) return false;
    if (!cuda.kernelsAvailable()) return false;

    var image: [512 * 1024]u8 = undefined;
    var log: [8 * 1024]u8 = @splat(0);
    const len = cuda.compile(KERNEL_SOURCE, "sm_120", .cubin, &image, &log) orelse return false;
    if (len == 0) return false;
    module = cuda.loadModule(&image) orelse return false;
    const m = module.?;

    f_silu = cuda.getFunction(m, "k_silu");
    f_silu_gate = cuda.getFunction(m, "k_silu_gate");
    f_gelu = cuda.getFunction(m, "k_gelu");
    f_residual_add = cuda.getFunction(m, "k_residual_add");
    f_scale_add = cuda.getFunction(m, "k_scale_add");
    f_snake_beta = cuda.getFunction(m, "k_snake_beta");
    f_layernorm = cuda.getFunction(m, "k_layernorm");
    f_rmsnorm = cuda.getFunction(m, "k_rmsnorm");
    f_causal_conv1d = cuda.getFunction(m, "k_causal_conv1d");
    f_transposed_conv1d = cuda.getFunction(m, "k_transposed_conv1d");
    f_copy = cuda.getFunction(m, "k_copy");
    f_zero = cuda.getFunction(m, "k_zero");
    f_add_bias_rows = cuda.getFunction(m, "k_add_bias_rows");
    f_scale_add_rows = cuda.getFunction(m, "k_scale_add_rows");
    f_depthwise7 = cuda.getFunction(m, "k_depthwise7");
    f_head_rmsnorm = cuda.getFunction(m, "k_head_rmsnorm");
    f_rope = cuda.getFunction(m, "k_rope");
    f_sliding_attention = cuda.getFunction(m, "k_sliding_attention");
    f_store_kv = cuda.getFunction(m, "k_store_kv");
    f_gqa_attention = cuda.getFunction(m, "k_gqa_attention");
    f_store_kv_linear = cuda.getFunction(m, "k_store_kv_linear");
    f_argmax = cuda.getFunction(m, "k_argmax");

    if (f_silu == null or f_silu_gate == null or f_gelu == null or
        f_residual_add == null or f_scale_add == null or f_snake_beta == null or
        f_layernorm == null or f_rmsnorm == null or
        f_causal_conv1d == null or f_transposed_conv1d == null or
        f_copy == null or f_zero == null or f_add_bias_rows == null or
        f_scale_add_rows == null or f_depthwise7 == null or
        f_head_rmsnorm == null or f_rope == null or
        f_sliding_attention == null or f_store_kv == null or
        f_gqa_attention == null or f_store_kv_linear == null or f_argmax == null) return false;

    compile_ok = true;
    return true;
}

const BLOCK: u32 = 256;
fn grid1d(n: usize) u32 {
    return @intCast((n + BLOCK - 1) / BLOCK);
}

// ── Elementwise launch wrappers (device pointers in/out) ──

pub fn siluGate(gate: CUdeviceptr, up: CUdeviceptr, n: usize) bool {
    const f = f_silu_gate orelse return false;
    var p_gate = gate;
    var p_up = up;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_gate, &p_up, &n_arg };
    return cuda.launchKernel(f, grid1d(n), BLOCK, 0, &params);
}

pub fn copyDevice(dst: CUdeviceptr, src: CUdeviceptr, n: usize) bool {
    const f = f_copy orelse return false;
    var p_dst = dst;
    var p_src = src;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_dst, &p_src, &n_arg };
    return cuda.launchKernel(f, grid1d(n), BLOCK, 0, &params);
}

pub fn zeroDevice(dst: CUdeviceptr, n: usize) bool {
    const f = f_zero orelse return false;
    var p_dst = dst;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_dst, &n_arg };
    return cuda.launchKernel(f, grid1d(n), BLOCK, 0, &params);
}

pub fn gelu(x: CUdeviceptr, n: usize) bool {
    const f = f_gelu orelse return false;
    var p_x = x;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_x, &n_arg };
    return cuda.launchKernel(f, grid1d(n), BLOCK, 0, &params);
}

pub fn residualAdd(dst: CUdeviceptr, src: CUdeviceptr, n: usize) bool {
    const f = f_residual_add orelse return false;
    var p_dst = dst;
    var p_src = src;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_dst, &p_src, &n_arg };
    return cuda.launchKernel(f, grid1d(n), BLOCK, 0, &params);
}

pub fn scaleAdd(hidden: CUdeviceptr, delta: CUdeviceptr, scale: CUdeviceptr, n: usize) bool {
    const f = f_scale_add orelse return false;
    var p_h = hidden;
    var p_d = delta;
    var p_s = scale;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_h, &p_d, &p_s, &n_arg };
    return cuda.launchKernel(f, grid1d(n), BLOCK, 0, &params);
}

pub fn snakeBeta(x: CUdeviceptr, alpha: CUdeviceptr, beta: CUdeviceptr, frames: usize, channels: usize) bool {
    const f = f_snake_beta orelse return false;
    var p_x = x;
    var p_a = alpha;
    var p_b = beta;
    var frames_arg: c_int = @intCast(frames);
    var channels_arg: c_int = @intCast(channels);
    var params = [_]?*anyopaque{ &p_x, &p_a, &p_b, &frames_arg, &channels_arg };
    return cuda.launchKernel(f, grid1d(frames * channels), BLOCK, 0, &params);
}

pub fn layerNorm(x: CUdeviceptr, weight: CUdeviceptr, bias: CUdeviceptr, frames: usize, channels: usize) bool {
    const f = f_layernorm orelse return false;
    var p_x = x;
    var p_w = weight;
    var p_b = bias;
    var frames_arg: c_int = @intCast(frames);
    var channels_arg: c_int = @intCast(channels);
    var params = [_]?*anyopaque{ &p_x, &p_w, &p_b, &frames_arg, &channels_arg };
    // One block per frame.
    return cuda.launchKernel(f, @intCast(frames), BLOCK, 0, &params);
}

pub fn rmsNorm(in: CUdeviceptr, weight: CUdeviceptr, out: CUdeviceptr, n: usize, eps: f32) bool {
    const f = f_rmsnorm orelse return false;
    var p_in = in;
    var p_w = weight;
    var p_out = out;
    var n_arg: c_int = @intCast(n);
    var eps_arg: f32 = eps;
    var params = [_]?*anyopaque{ &p_in, &p_w, &p_out, &n_arg, &eps_arg };
    return cuda.launchKernel(f, 1, BLOCK, 0, &params);
}

/// Per-head RMSNorm (q_norm/k_norm): `heads` heads × head_dim, shared weight.
pub fn headRmsNorm(vec: CUdeviceptr, weight: CUdeviceptr, heads: usize, head_dim: usize, eps: f32) bool {
    const f = f_head_rmsnorm orelse return false;
    var p_v = vec;
    var p_w = weight;
    var heads_arg: c_int = @intCast(heads);
    var hd_arg: c_int = @intCast(head_dim);
    var eps_arg: f32 = eps;
    var params = [_]?*anyopaque{ &p_v, &p_w, &heads_arg, &hd_arg, &eps_arg };
    return cuda.launchKernel(f, grid1d(heads), BLOCK, 0, &params);
}

/// Split-half RoPE over `heads` heads × head_dim at absolute `position`.
pub fn rope(vec: CUdeviceptr, heads: usize, head_dim: usize, position: u64, theta_base: f32) bool {
    const f = f_rope orelse return false;
    var p_v = vec;
    var heads_arg: c_int = @intCast(heads);
    var hd_arg: c_int = @intCast(head_dim);
    var pos_arg: c_longlong = @intCast(position);
    var theta_arg: f32 = theta_base;
    var params = [_]?*anyopaque{ &p_v, &heads_arg, &hd_arg, &pos_arg, &theta_arg };
    return cuda.launchKernel(f, grid1d(heads), BLOCK, 0, &params);
}

/// Store a Q-wide vector into the KV ring at `slot` (f32 device ring).
pub fn storeKv(ring: CUdeviceptr, vec: CUdeviceptr, slot: usize, q: usize) bool {
    const f = f_store_kv orelse return false;
    var p_r = ring;
    var p_v = vec;
    var slot_arg: c_int = @intCast(slot);
    var q_arg: c_int = @intCast(q);
    var params = [_]?*anyopaque{ &p_r, &p_v, &slot_arg, &q_arg };
    return cuda.launchKernel(f, grid1d(q), BLOCK, 0, &params);
}

/// Sliding-window attention over an f32 KV ring. heads × head_dim = Q.
pub fn slidingAttention(query: CUdeviceptr, keys: CUdeviceptr, values: CUdeviceptr, output: CUdeviceptr, position: u64, heads: usize, head_dim: usize, window: usize) bool {
    const f = f_sliding_attention orelse return false;
    var p_q = query;
    var p_k = keys;
    var p_v = values;
    var p_o = output;
    var pos_arg: c_longlong = @intCast(position);
    var heads_arg: c_int = @intCast(heads);
    var hd_arg: c_int = @intCast(head_dim);
    var win_arg: c_int = @intCast(window);
    var params = [_]?*anyopaque{ &p_q, &p_k, &p_v, &p_o, &pos_arg, &heads_arg, &hd_arg, &win_arg };
    return cuda.launchKernel(f, grid1d(heads), BLOCK, 0, &params);
}

/// Grouped-query FULL causal attention over an f32 KV cache [cap, kv_dim].
pub fn gqaAttention(query: CUdeviceptr, keys: CUdeviceptr, values: CUdeviceptr, output: CUdeviceptr, position: usize, q_heads: usize, kv_heads: usize, head_dim: usize) bool {
    const f = f_gqa_attention orelse return false;
    var p_q = query;
    var p_k = keys;
    var p_v = values;
    var p_o = output;
    var pos_arg: c_int = @intCast(position);
    var qh_arg: c_int = @intCast(q_heads);
    var kvh_arg: c_int = @intCast(kv_heads);
    var hd_arg: c_int = @intCast(head_dim);
    var kvdim_arg: c_int = @intCast(kv_heads * head_dim);
    var params = [_]?*anyopaque{ &p_q, &p_k, &p_v, &p_o, &pos_arg, &qh_arg, &kvh_arg, &hd_arg, &kvdim_arg };
    return cuda.launchKernel(f, grid1d(q_heads), BLOCK, 0, &params);
}

/// Store a kv vector at absolute `pos` in a linear f32 cache [cap, kv_dim].
pub fn storeKvLinear(cache: CUdeviceptr, vec: CUdeviceptr, pos: usize, kv_dim: usize) bool {
    const f = f_store_kv_linear orelse return false;
    var p_c = cache;
    var p_v = vec;
    var pos_arg: c_int = @intCast(pos);
    var kvdim_arg: c_int = @intCast(kv_dim);
    var params = [_]?*anyopaque{ &p_c, &p_v, &pos_arg, &kvdim_arg };
    return cuda.launchKernel(f, grid1d(kv_dim), BLOCK, 0, &params);
}

/// argmax over `n` logits, writing the index into a device int buffer `out_idx`.
pub fn argmax(logits: CUdeviceptr, out_idx: CUdeviceptr, n: usize) bool {
    const f = f_argmax orelse return false;
    var p_l = logits;
    var p_o = out_idx;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &p_l, &p_o, &n_arg };
    return cuda.launchKernel(f, 1, BLOCK, 0, &params);
}

/// Allocate a device buffer of `count` i32 (bytes). Returns 0 on failure.
pub fn allocInt(count: usize) CUdeviceptr {
    return cuda.gpuAlloc(count * 4);
}
/// Download i32 values from a device buffer.
pub fn downloadInt(dst: []i32, dptr: CUdeviceptr) bool {
    return cuda.downloadFromGpu(@ptrCast(dst.ptr), dptr, dst.len * 4);
}

/// Causal dilated conv1d over all frames. `history` may be 0 (treated as no
/// prior context, hist_count 0). Weight is rank-3 [out_ch, in_ch, kernel].
pub fn causalConv1d(
    input: CUdeviceptr,
    weight: CUdeviceptr,
    bias: CUdeviceptr,
    output: CUdeviceptr,
    history: CUdeviceptr,
    hist_count: usize,
    frames: usize,
    in_ch: usize,
    out_ch: usize,
    kernel: usize,
    dilation: usize,
) bool {
    const f = f_causal_conv1d orelse return false;
    var p_in = input;
    var p_w = weight;
    var p_bias = bias;
    var p_out = output;
    var p_hist = history;
    var hist_arg: c_int = @intCast(hist_count);
    var frames_arg: c_int = @intCast(frames);
    var in_arg: c_int = @intCast(in_ch);
    var out_arg: c_int = @intCast(out_ch);
    var k_arg: c_int = @intCast(kernel);
    var d_arg: c_int = @intCast(dilation);
    var params = [_]?*anyopaque{
        &p_in, &p_w, &p_bias, &p_out, &p_hist, &hist_arg,
        &frames_arg, &in_arg, &out_arg, &k_arg, &d_arg,
    };
    return cuda.launchKernel(f, grid1d(frames * out_ch), BLOCK, 0, &params);
}

/// Transposed (upsampling) conv1d over all frames. Produces frames*stride
/// output frames. Weight is rank-3 [in_ch, out_ch, kernel] (PyTorch layout).
/// `history` holds `carry_in` prior input frames (may be 0 / carry_in 0).
pub fn transposedConv1d(
    input: CUdeviceptr,
    weight: CUdeviceptr,
    bias: CUdeviceptr,
    output: CUdeviceptr,
    history: CUdeviceptr,
    carry_in: usize,
    frames: usize,
    in_ch: usize,
    out_ch: usize,
    kernel: usize,
    stride: usize,
) bool {
    const f = f_transposed_conv1d orelse return false;
    var p_in = input;
    var p_w = weight;
    var p_bias = bias;
    var p_out = output;
    var p_hist = history;
    var carry_arg: c_int = @intCast(carry_in);
    var frames_arg: c_int = @intCast(frames);
    var in_arg: c_int = @intCast(in_ch);
    var out_arg: c_int = @intCast(out_ch);
    var k_arg: c_int = @intCast(kernel);
    var s_arg: c_int = @intCast(stride);
    var params = [_]?*anyopaque{
        &p_in, &p_w, &p_bias, &p_out, &p_hist, &carry_arg,
        &frames_arg, &in_arg, &out_arg, &k_arg, &s_arg,
    };
    return cuda.launchKernel(f, grid1d(frames * stride * out_ch), BLOCK, 0, &params);
}

pub fn addBiasRows(x: CUdeviceptr, bias: CUdeviceptr, frames: usize, channels: usize) bool {
    const f = f_add_bias_rows orelse return false;
    var p_x = x;
    var p_b = bias;
    var frames_arg: c_int = @intCast(frames);
    var channels_arg: c_int = @intCast(channels);
    var params = [_]?*anyopaque{ &p_x, &p_b, &frames_arg, &channels_arg };
    return cuda.launchKernel(f, grid1d(frames * channels), BLOCK, 0, &params);
}

pub fn scaleAddRows(dst: CUdeviceptr, src: CUdeviceptr, scale: CUdeviceptr, frames: usize, channels: usize) bool {
    const f = f_scale_add_rows orelse return false;
    var p_d = dst;
    var p_s = src;
    var p_sc = scale;
    var frames_arg: c_int = @intCast(frames);
    var channels_arg: c_int = @intCast(channels);
    var params = [_]?*anyopaque{ &p_d, &p_s, &p_sc, &frames_arg, &channels_arg };
    return cuda.launchKernel(f, grid1d(frames * channels), BLOCK, 0, &params);
}

/// Depthwise causal conv1d, kernel 7 dilation 1 (groups == channels). weight is
/// [channels, 1, 7]. history linear oldest..newest of last 6 input frames.
pub fn depthwiseConv1d(input: CUdeviceptr, weight: CUdeviceptr, bias: CUdeviceptr, output: CUdeviceptr,
    history: CUdeviceptr, hist_count: usize, frames: usize, channels: usize, kernel: usize) bool {
    _ = kernel; // fixed at 7 in the kernel
    const f = f_depthwise7 orelse return false;
    var p_in = input;
    var p_w = weight;
    var p_bias = bias;
    var p_out = output;
    var p_hist = history;
    var hist_arg: c_int = @intCast(hist_count);
    var frames_arg: c_int = @intCast(frames);
    var channels_arg: c_int = @intCast(channels);
    var params = [_]?*anyopaque{ &p_in, &p_w, &p_bias, &p_out, &p_hist, &hist_arg, &frames_arg, &channels_arg };
    return cuda.launchKernel(f, grid1d(frames * channels), BLOCK, 0, &params);
}

// ── Device weight residency (any-rank) + activation scratch ──
//
// Dequantize each tensor's full payload to f32 ONCE and keep it in VRAM, keyed
// by the tensor's data_offset. Activations stay resident in device buffers so a
// whole vocoder frame runs without host round-trips.

const MAX_WEIGHTS: usize = 2048;
const WeightEntry = struct { offset: u64, dptr: CUdeviceptr, elements: usize };
var weights: [MAX_WEIGHTS]WeightEntry = undefined;
var weight_count: usize = 0;

// Widest vocoder weight is the first decoder-stage transposed conv
// [1536, 768, 16] = 18.9M elements; allow headroom.
const MAX_WEIGHT_ELEMENTS: usize = 24 * 1024 * 1024;
var weight_staging: ?[*]f32 = null;

extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, alloc_type: u32, protect: u32) ?*anyopaque;
const MEM_COMMIT_RESERVE: u32 = 0x3000;
const PAGE_READWRITE: u32 = 0x04;

/// Look up a resident weight's device pointer by tensor offset, or 0.
pub fn weightPtr(offset: u64) CUdeviceptr {
    for (weights[0..weight_count]) |*e| if (e.offset == offset) return e.dptr;
    return 0;
}

/// Dequantize a tensor's full payload to f32 and upload it to VRAM once, keyed
/// by data_offset. Handles f16 and sb0_q4 (any rank, row-major). Idempotent.
pub fn preloadWeight(source: Source, tensor: *const Tensor) bool {
    if (!ready()) return false;
    if (weightPtr(tensor.data_offset) != 0) return true;
    if (weight_count >= MAX_WEIGHTS) return false;

    const total: usize = @intCast(tensor.element_count);
    if (total == 0 or total > MAX_WEIGHT_ELEMENTS) return false;

    if (weight_staging == null) {
        const p = VirtualAlloc(null, MAX_WEIGHT_ELEMENTS * @sizeOf(f32), MEM_COMMIT_RESERVE, PAGE_READWRITE) orelse return false;
        weight_staging = @ptrCast(@alignCast(p));
    }
    const staging = weight_staging.?;
    const dst = staging[0..total];

    var scratch_buf: [64 * 1024]u8 = undefined;
    switch (tensor.encoding) {
        .f16 => {
            var done: usize = 0;
            while (done < total) {
                const chunk = @min(total - done, scratch_buf.len / 2);
                const off = tensor.data_offset + @as(u64, @intCast(done)) * 2;
                if (!source.read(off, scratch_buf[0 .. chunk * 2])) return false;
                for (0..chunk) |i| {
                    const b = @as(u16, scratch_buf[i * 2]) | (@as(u16, scratch_buf[i * 2 + 1]) << 8);
                    dst[done + i] = quantized.f16ToF32(b);
                }
                done += chunk;
            }
        },
        .sb0_q4 => {
            const rows: usize = @intCast(tensor.rows());
            const cols: usize = @intCast(tensor.rowElements());
            if (rows * cols != total) return false;
            const row_bytes: usize = @intCast(tensor.data_bytes / tensor.rows());
            if (row_bytes > scratch_buf.len) return false;
            for (0..rows) |row| {
                const off = tensor.data_offset + @as(u64, @intCast(row)) * row_bytes;
                if (!source.read(off, scratch_buf[0..row_bytes])) return false;
                quantized.dequantizeSb0Q4(dst[row * cols ..][0..cols], scratch_buf[0..row_bytes]) catch return false;
            }
        },
        .raw_u8 => return false,
    }
    for (dst) |v| if (!std.math.isFinite(v)) return false;

    const dptr = cuda.gpuAlloc(total * @sizeOf(f32));
    if (dptr == 0) return false;
    if (!cuda.uploadToGpu(dptr, @ptrCast(staging), total * @sizeOf(f32))) {
        cuda.gpuFree(dptr);
        return false;
    }
    _ = cuda.syncActiveStream();
    weights[weight_count] = .{ .offset = tensor.data_offset, .dptr = dptr, .elements = total };
    weight_count += 1;
    return true;
}

/// `out[rows] = W[rows,cols] @ in[cols]` on device pointers via cuBLAS.
pub fn gemmDevice(w: CUdeviceptr, in: CUdeviceptr, out: CUdeviceptr, rows: usize, cols: usize) bool {
    const sgemm = cuda.fn_cublasSgemm orelse return false;
    const handle = cuda.cublas_handle orelse return false;
    const alpha: f32 = 1.0;
    const beta: f32 = 0.0;
    const status = sgemm(handle, .T, .N, @intCast(rows), 1, @intCast(cols), &alpha, @ptrFromInt(w), @intCast(cols), @ptrFromInt(in), @intCast(cols), &beta, @ptrFromInt(out), @intCast(rows));
    return status == cuda.CUBLAS_STATUS_SUCCESS;
}

/// Batched: `out[rows, n] = W[rows,cols] @ in[cols, n]` (row-major activations
/// in[frame, cols] == column-major [cols, n]). Used for per-frame pointwise.
pub fn gemmDeviceBatched(w: CUdeviceptr, in: CUdeviceptr, out: CUdeviceptr, rows: usize, cols: usize, n: usize) bool {
    const sgemm = cuda.fn_cublasSgemm orelse return false;
    const handle = cuda.cublas_handle orelse return false;
    const alpha: f32 = 1.0;
    const beta: f32 = 0.0;
    const status = sgemm(handle, .T, .N, @intCast(rows), @intCast(n), @intCast(cols), &alpha, @ptrFromInt(w), @intCast(cols), @ptrFromInt(in), @intCast(cols), &beta, @ptrFromInt(out), @intCast(rows));
    return status == cuda.CUBLAS_STATUS_SUCCESS;
}

/// Device buffer helpers (thin pass-throughs so callers don't import matmul_cuda).
pub fn alloc(elements: usize) CUdeviceptr {
    return cuda.gpuAlloc(elements * @sizeOf(f32));
}
pub fn free(dptr: CUdeviceptr) void {
    cuda.gpuFree(dptr);
}
pub fn upload(dptr: CUdeviceptr, src: []const f32) bool {
    return cuda.uploadToGpu(dptr, @ptrCast(src.ptr), src.len * @sizeOf(f32));
}
pub fn download(dst: []f32, dptr: CUdeviceptr) bool {
    return cuda.downloadFromGpu(@ptrCast(dst.ptr), dptr, dst.len * @sizeOf(f32));
}
pub fn sync() bool {
    return cuda.syncActiveStream();
}
