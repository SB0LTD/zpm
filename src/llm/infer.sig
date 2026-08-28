// @zpm/llm — Inference Dispatch
// Bridges gguf_loader (quantized byte pointers) → dequant → decoder.forwardLayer.
//
// Strategy: dequantize weights on-the-fly, one row at a time.
// For matmul y = W @ x where W is [out_dim, in_dim]:
//   - Dequant row i of W into scratch buffer (in_dim floats)
//   - Compute dot(row_i, x) → y[i]
//   - Repeat for all rows
//
// This keeps peak RAM bounded: only one row of W is in f32 at a time.
// For Qwen3-VL-2B Q4_K_M: each weight row is 2048 floats = 8KB scratch.
//
// The full forward pass for one token:
//   1. Embed token → hidden[2048]
//   2. For each of 28 layers:
//      a. Dequant layer norms (small, always f32 in GGUF)
//      b. Dequant Q/K/V/O projections row-by-row for matvec
//      c. Run forwardLayer (attention + MLP)
//   3. Output norm + logit computation (vocab-sized)
//   4. Argmax → next token

const std = @import("std");
const decoder = @import("decoder.sig");
const gguf_loader = @import("gguf_loader.sig");
const quantize = @import("quantize.sig");
const fused = @import("fused_matmul.sig");

// Win32 VirtualAlloc for large scratch buffers
extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) ?[*]u8;
extern "kernel32" fn VirtualFree(?*anyopaque, usize, u32) c_int;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

// ── Scratch buffers for dequantized weights ──
// Largest single weight matrix in Qwen3-VL-2B:
//   intermediate_size × hidden_size = 6144 × 2048 = 12,582,912 floats = 48 MB
// We dequant row-by-row, so we only need one row at a time:
//   max(hidden_size, intermediate_size) = 6144 floats = 24 KB
// But for matmul we need the full matrix. Since we do matvec (one token),
// we can dequant row-by-row and accumulate the dot product.
//
// However, the decoder.forwardLayer expects full f32 weight pointers.
// Two options:
//   A) Dequant entire weight matrix into a big scratch (48 MB peak per layer)
//   B) Modify forwardLayer to accept a row-at-a-time callback
//
// We choose A for correctness first — can optimize to B later.
// Peak scratch: intermediate × hidden = 6144 × 2048 × 4 = 48 MB
// We allocate this once at startup and reuse for each layer.

const MAX_WEIGHT_ELEMENTS: usize = 6144 * 2048; // 12.5M floats
const MAX_NORM_ELEMENTS: usize = 16384; // max hidden_size

// Scratch for weight matrices (allocated once, reused per-layer)
var scratch_q_proj: ?[*]f32 = null; // [n_heads*head_dim, hidden]
var scratch_k_proj: ?[*]f32 = null; // [kv_dim, hidden]
var scratch_v_proj: ?[*]f32 = null; // [kv_dim, hidden]
var scratch_o_proj: ?[*]f32 = null; // [hidden, n_heads*head_dim]
var scratch_gate: ?[*]f32 = null; // [intermediate, hidden]
var scratch_up: ?[*]f32 = null; // [intermediate, hidden]
var scratch_down: ?[*]f32 = null; // [hidden, intermediate]

// Scratch for norms (small, reused)
var scratch_input_norm: [MAX_NORM_ELEMENTS]f32 = undefined;
var scratch_q_norm: [MAX_NORM_ELEMENTS]f32 = undefined;
var scratch_k_norm: [MAX_NORM_ELEMENTS]f32 = undefined;
var scratch_post_norm: [MAX_NORM_ELEMENTS]f32 = undefined;
var scratch_output_norm: [MAX_NORM_ELEMENTS]f32 = undefined;

// Hidden state
var hidden_state: [MAX_NORM_ELEMENTS]f32 = undefined;

// Embedding scratch (for token lookup with dequant)
var scratch_emb_row: [MAX_NORM_ELEMENTS]f32 = undefined;
var scratch_fwd_normed: [MAX_NORM_ELEMENTS]f32 = undefined;

var infer_initialized: bool = false;

/// Initialize inference engine. No large scratch buffers needed with fused path.
pub fn init() bool {
    if (infer_initialized) return true;
    infer_initialized = true;
    return true;
}

/// Enable GPU-accelerated matmul dispatch (unused with fused path but kept for API compat).
pub fn enableGpuMatvec(matvec_fn: decoder.MatvecFn) void {
    decoder.setMatvecFn(matvec_fn);
}

/// Free inference resources.
pub fn deinit() void {
    infer_initialized = false;
}

fn allocF32(bytes: usize) ?[*]f32 {
    const mem = VirtualAlloc(null, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (mem) |m| return @ptrCast(@alignCast(m));
    return null;
}

fn freeF32(ptr: *?[*]f32) void {
    if (ptr.*) |p| {
        _ = VirtualFree(@ptrCast(p), 0, MEM_RELEASE);
        ptr.* = null;
    }
}

/// Run one full forward pass: token_id → next_token_id (greedy).
/// This is the core inference function called by the agent.
pub fn forward(
    token_id: u32,
    model: *const gguf_loader.LoadedModel,
    kv: *decoder.KVCache,
    cfg: decoder.DecoderConfig,
) u32 {
    if (!infer_initialized) return 0;
    const pos = kv.seq_len;
    const hidden_size = cfg.hidden_size;

    // 1. Token embedding lookup
    embedToken(token_id, model, cfg);

    // 2. Forward through all decoder layers
    for (0..cfg.n_layers) |layer_idx| {
        forwardOneLayer(layer_idx, pos, model, kv, cfg);
    }

    // 3. Advance KV cache
    kv.advance();

    // 4. Output norm
    dequantNorm(model.weights.output_norm, hidden_size, &scratch_output_norm);
    decoder.rmsNorm(&hidden_state, &scratch_fwd_normed, &scratch_output_norm, hidden_size, cfg.rms_eps);

    // 5. Logits → argmax
    return computeArgmax(&scratch_fwd_normed, model, cfg);
}

/// Embed a token: look up row token_id from the embedding matrix.
fn embedToken(token_id: u32, model: *const gguf_loader.LoadedModel, cfg: decoder.DecoderConfig) void {
    const hidden_size = cfg.hidden_size;
    const emb_ptr = model.weights.token_embd orelse return;
    const emb_type = model.weights.token_embd_type;

    // Calculate byte offset for this token's row
    const row_elements = hidden_size;
    const be = emb_type.blockElems();
    const bb = emb_type.blockBytes();
    const row_bytes = if (be > 0) ((row_elements + be - 1) / be) * bb else row_elements * 4;
    const offset = @as(usize, token_id) * row_bytes;

    // Dequantize this single row
    dequantRow(emb_ptr + offset, emb_type, row_elements, &hidden_state);
}

/// Forward one decoder layer with FUSED dequant-matvec (zero scratch buffers).
fn forwardOneLayer(
    layer_idx: usize,
    pos: usize,
    model: *const gguf_loader.LoadedModel,
    kv: *decoder.KVCache,
    cfg: decoder.DecoderConfig,
) void {
    const lw = &model.weights.layers[layer_idx];
    const hidden_size = cfg.hidden_size;
    const n_heads = cfg.n_heads;
    const n_kv_heads = cfg.n_kv_heads;
    const head_dim = cfg.head_dim;
    const kv_dim = cfg.kvDim();
    const intermediate = cfg.intermediate_size;
    const gqa_ratio = n_heads / n_kv_heads;

    // 1. Input LayerNorm
    dequantNorm(lw.attn_norm, hidden_size, &scratch_input_norm);
    decoder.rmsNorm(&hidden_state, &scratch_fwd_normed, &scratch_input_norm, hidden_size, cfg.rms_eps);

    // 2. Q/K/V projections — FUSED quantized matvec (no scratch matrix!)
    if (lw.q_proj) |qw| fused.quantMatvec(&scratch_q_norm, qw, &scratch_fwd_normed, n_heads * head_dim, hidden_size, lw.q_proj_type);
    if (lw.k_proj) |kw| fused.quantMatvec(&scratch_k_norm, kw, &scratch_fwd_normed, kv_dim, hidden_size, lw.k_proj_type);
    if (lw.v_proj) |vw| fused.quantMatvec(&scratch_post_norm, vw, &scratch_fwd_normed, kv_dim, hidden_size, lw.v_proj_type);

    // 3. Per-head Q/K RMSNorm (Qwen3)
    if (cfg.has_qk_norm) {
        if (lw.q_norm) |qn| {
            var qn_w: [256]f32 = undefined;
            dequantNorm(qn, head_dim, &qn_w);
            for (0..n_heads) |h| {
                const off = h * head_dim;
                decoder.rmsNorm(scratch_q_norm[off..].ptr, scratch_q_norm[off..].ptr, &qn_w, head_dim, cfg.rms_eps);
            }
        }
        if (lw.k_norm) |kn| {
            var kn_w: [256]f32 = undefined;
            dequantNorm(kn, head_dim, &kn_w);
            for (0..n_kv_heads) |h| {
                const off = h * head_dim;
                decoder.rmsNorm(scratch_k_norm[off..].ptr, scratch_k_norm[off..].ptr, &kn_w, head_dim, cfg.rms_eps);
            }
        }
    }

    // 4. RoPE
    applyRoPE(&scratch_q_norm, pos, n_heads, head_dim, cfg.rope_theta);
    applyRoPE(&scratch_k_norm, pos, n_kv_heads, head_dim, cfg.rope_theta);

    // 5. Store K/V in cache (reusing scratch_k_norm for K, scratch_post_norm for V)
    kv.storeK(layer_idx, &scratch_k_norm);
    kv.storeV(layer_idx, &scratch_post_norm);

    // 6. Attention (GQA) — compute in scratch_output_norm as temp
    var attn_out: [MAX_NORM_ELEMENTS]f32 = @splat(0.0);
    const attn_scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));

    for (0..n_heads) |h| {
        const kv_head = h / gqa_ratio;
        const q_ptr = scratch_q_norm[h * head_dim ..][0..head_dim];
        // Score all past positions
        for (0..pos + 1) |p| {
            scratch_output_norm[p] = kv.dotK(layer_idx, p, kv_head, q_ptr.ptr, head_dim) * attn_scale;
        }
        softmax(scratch_output_norm[0 .. pos + 1]);
        // Weighted V sum
        const out_ptr = attn_out[h * head_dim ..].ptr;
        for (0..pos + 1) |p| {
            kv.accumV(layer_idx, p, kv_head, scratch_output_norm[p], out_ptr, head_dim);
        }
    }

    // 7. O projection — FUSED
    var o_out: [MAX_NORM_ELEMENTS]f32 = undefined;
    if (lw.o_proj) |ow| fused.quantMatvec(&o_out, ow, &attn_out, hidden_size, n_heads * head_dim, lw.o_proj_type);

    // 8. Residual
    for (0..hidden_size) |i| hidden_state[i] += o_out[i];

    // 9. Post-norm
    dequantNorm(lw.post_norm, hidden_size, &scratch_input_norm);
    decoder.rmsNorm(&hidden_state, &scratch_fwd_normed, &scratch_input_norm, hidden_size, cfg.rms_eps);

    // 10. MLP gate + up — FUSED
    var gate_buf: [MAX_NORM_ELEMENTS]f32 = undefined;
    var up_buf: [MAX_NORM_ELEMENTS]f32 = undefined;
    if (lw.gate_proj) |gw| fused.quantMatvec(&gate_buf, gw, &scratch_fwd_normed, intermediate, hidden_size, lw.gate_proj_type);
    if (lw.up_proj) |uw| fused.quantMatvec(&up_buf, uw, &scratch_fwd_normed, intermediate, hidden_size, lw.up_proj_type);

    // 11. SiLU(gate) * up
    for (0..intermediate) |i| gate_buf[i] = decoder.silu(gate_buf[i]) * up_buf[i];

    // 12. Down projection — FUSED
    var down_out: [MAX_NORM_ELEMENTS]f32 = undefined;
    if (lw.down_proj) |dw| fused.quantMatvec(&down_out, dw, &gate_buf, hidden_size, intermediate, lw.down_proj_type);

    // 13. Residual
    for (0..hidden_size) |i| hidden_state[i] += down_out[i];
}

/// Compute argmax over vocab logits using fused quantized matvec.
/// Computes all 151K logits in one call (AVX2 SIMD), then finds max.
var s_cpu_logits: [152000]f32 = @splat(0.0);

fn computeArgmax(
    normed: [*]const f32,
    model: *const gguf_loader.LoadedModel,
    cfg: decoder.DecoderConfig,
) u32 {
    const hidden_size = cfg.hidden_size;
    const vocab_size = cfg.vocab_size;
    const out_ptr = model.weights.output_w orelse return 0;
    const out_type = model.weights.output_w_type;

    // Fused matvec: logits[vocab] = output_w[vocab, hidden] @ normed[hidden]
    fused.quantMatvec(&s_cpu_logits, out_ptr, normed, vocab_size, hidden_size, out_type);

    // Argmax
    var best_token: u32 = 0;
    var best_score: f32 = s_cpu_logits[0];
    for (1..vocab_size) |v| {
        if (s_cpu_logits[v] > best_score) {
            best_score = s_cpu_logits[v];
            best_token = @intCast(v);
        }
    }
    return best_token;
}

// ── Dequantization helpers ──

/// Dequantize a norm vector (small, typically f32 or f16 in GGUF).
fn dequantNorm(src: ?[*]const u8, n_elements: usize, dst: [*]f32) void {
    if (src == null) {
        // If missing, fill with 1.0 (identity norm weight)
        for (0..n_elements) |i| dst[i] = 1.0;
        return;
    }
    // Norms are always stored as f32 in GGUF (type 0)
    const f32_ptr: [*]const f32 = @ptrCast(@alignCast(src.?));
    @memcpy(dst[0..n_elements], f32_ptr[0..n_elements]);
}

/// Dequantize a full weight matrix [rows × cols] into dst.
fn dequantMatrix(
    src: ?[*]const u8,
    qtype: gguf_loader.GGMLType,
    rows: usize,
    cols: usize,
    dst: [*]f32,
) void {
    if (src == null) {
        @memset(dst[0 .. rows * cols], 0.0);
        return;
    }

    const n_elements = rows * cols;
    const raw = src.?;

    switch (qtype) {
        .f32 => {
            const f32_ptr: [*]const f32 = @ptrCast(@alignCast(raw));
            @memcpy(dst[0..n_elements], f32_ptr[0..n_elements]);
        },
        .f16 => {
            for (0..n_elements) |i| {
                const h: u16 = @as(u16, raw[i * 2]) | (@as(u16, raw[i * 2 + 1]) << 8);
                dst[i] = quantize.f16ToF32(h);
            }
        },
        .q8_0 => {
            quantize.dequantQ8_0(raw, dst, n_elements);
        },
        .q4_k => {
            quantize.dequantQ4_K(raw, dst, n_elements);
        },
        else => {
            // Unsupported quant type — zero fill
            @memset(dst[0..n_elements], 0.0);
        },
    }
}

/// Dequantize a single row of n_elements from src into dst.
fn dequantRow(src: [*]const u8, qtype: gguf_loader.GGMLType, n_elements: usize, dst: [*]f32) void {
    switch (qtype) {
        .f32 => {
            const f32_ptr: [*]const f32 = @ptrCast(@alignCast(src));
            @memcpy(dst[0..n_elements], f32_ptr[0..n_elements]);
        },
        .f16 => {
            for (0..n_elements) |i| {
                const h: u16 = @as(u16, src[i * 2]) | (@as(u16, src[i * 2 + 1]) << 8);
                dst[i] = quantize.f16ToF32(h);
            }
        },
        .q8_0 => {
            quantize.dequantQ8_0(src, dst, n_elements);
        },
        .q4_k => {
            quantize.dequantQ4_K(src, dst, n_elements);
        },
        else => {
            @memset(dst[0..n_elements], 0.0);
        },
    }
}

/// Generate tokens autoregressively until EOS or max_tokens.
/// Returns number of tokens generated.
pub fn generate(
    prompt_ids: []const u32,
    model: *const gguf_loader.LoadedModel,
    kv: *decoder.KVCache,
    cfg: decoder.DecoderConfig,
    eos_token: u32,
    max_new_tokens: usize,
    out_ids: [*]u32,
) usize {
    // Prefill: run all prompt tokens through the model
    for (0..prompt_ids.len) |i| {
        _ = forward(prompt_ids[i], model, kv, cfg);
    }

    // Generate
    var count: usize = 0;
    const prev_token: u32 = if (prompt_ids.len > 0) prompt_ids[prompt_ids.len - 1] else 0;
    _ = prev_token;

    while (count < max_new_tokens) {
        // Get the last predicted token (from the last forward call)
        // For first iteration, we need to run forward on the last prompt token
        // which we already did in prefill. The argmax from that is our first gen token.
        // Actually: forward() returns the predicted NEXT token. So after prefill,
        // the last forward() call already gave us the first generated token.
        // Let's re-run from the last prompt token to get it.

        const next_token = forward(
            if (count == 0 and prompt_ids.len > 0)
                prompt_ids[prompt_ids.len - 1]
            else
                out_ids[count - 1],
            model,
            kv,
            cfg,
        );

        if (next_token == eos_token) break;
        out_ids[count] = next_token;
        count += 1;
    }

    return count;
}

fn softmax(data: []f32) void {
    var max_val: f32 = data[0];
    for (1..data.len) |i| if (data[i] > max_val) { max_val = data[i]; };
    var sum: f32 = 0.0;
    for (0..data.len) |i| { data[i] = @exp(data[i] - max_val); sum += data[i]; }
    const inv = 1.0 / sum;
    for (0..data.len) |i| data[i] *= inv;
}

fn applyRoPE(data: [*]f32, pos: usize, n_heads: usize, head_dim: usize, theta: f32) void {
    const math = std.math;
    const half = head_dim / 2;
    for (0..n_heads) |h| {
        const base = h * head_dim;
        for (0..half) |i| {
            const freq = 1.0 / math.pow(f32, theta, @as(f32, @floatFromInt(2 * i)) / @as(f32, @floatFromInt(head_dim)));
            const angle = @as(f32, @floatFromInt(pos)) * freq;
            const cos_v = @cos(angle);
            const sin_v = @sin(angle);
            const x0 = data[base + i];
            const x1 = data[base + half + i];
            data[base + i] = x0 * cos_v - x1 * sin_v;
            data[base + half + i] = x0 * sin_v + x1 * cos_v;
        }
    }
}
