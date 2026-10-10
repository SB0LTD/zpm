//! Stateful codes-to-latent front half of the native Qwen3-TTS codec.
//!
//! Sixteen codebook IDs become one 1024-wide latent frame through the exact
//! split RVQ and eight-layer sliding transformer.  The 72-frame KV window is
//! explicit f16 state, so it persists across emitted acoustic frames without
//! retaining a framework cache or allocating per frame.

const std = @import("std");
const sb0m = @import("tts_model_container");
const plan_module = @import("tts_codec_plan");
const backend = @import("tts_codec_backend");
const kernels = @import("tts_kernels");

const H = plan_module.TRANSFORMER_HIDDEN;
const Q = plan_module.TRANSFORMER_QUERY;
const F = plan_module.TRANSFORMER_INTERMEDIATE;
const W = plan_module.SLIDING_WINDOW;
const HEADS = plan_module.TRANSFORMER_HEADS;
const HEAD_DIM = plan_module.HEAD_DIM;
const RMS_EPS: f32 = 0.00001;
const ROPE_THETA: f32 = 10000.0;

pub const Error = backend.Error || error{
    InvalidCode,
    InvalidPlan,
    NonFinite,
    QuantizerReadFailure,
    QuantizerProjectionFailure,
    TransformerInputFailure,
    AttentionProjectionFailure,
    FeedForwardProjectionFailure,
    TransformerOutputFailure,
};

pub const State = struct {
    position: u64 = 0,
    pre_conv_history: [2 * plan_module.CODEBOOK_DIM]f32 = @splat(0),
    pre_conv_cursor: u2 = 0,
    pre_conv_count: u2 = 0,
    keys: [plan_module.TRANSFORMER_LAYERS][W * Q]f16 = @splat(@splat(0)),
    values: [plan_module.TRANSFORMER_LAYERS][W * Q]f16 = @splat(@splat(0)),

    pub fn reset(self: *State) void {
        self.position = 0;
        @memset(&self.pre_conv_history, 0);
        self.pre_conv_cursor = 0;
        self.pre_conv_count = 0;
        @memset(std.mem.asBytes(&self.keys), 0);
        @memset(std.mem.asBytes(&self.values), 0);
    }
};

pub const Workspace = struct {
    tensor: backend.Scratch = .{},
    code_row: [plan_module.CODEBOOK_HIDDEN]f32 = @splat(0),
    first_code: [plan_module.CODEBOOK_HIDDEN]f32 = @splat(0),
    rest_codes: [plan_module.CODEBOOK_HIDDEN]f32 = @splat(0),
    first_projected: [plan_module.CODEBOOK_DIM]f32 = @splat(0),
    codebook_hidden: [plan_module.CODEBOOK_DIM]f32 = @splat(0),
    pre_conv_input: [3 * plan_module.CODEBOOK_DIM]f32 = @splat(0),
    pre_conv_output: [plan_module.LATENT]f32 = @splat(0),
    hidden: [H]f32 = @splat(0),
    normalized: [H]f32 = @splat(0),
    query: [Q]f32 = @splat(0),
    key: [Q]f32 = @splat(0),
    value: [Q]f32 = @splat(0),
    attention: [Q]f32 = @splat(0),
    projection: [H]f32 = @splat(0),
    gate: [F]f32 = @splat(0),
    up: [F]f32 = @splat(0),
    down: [H]f32 = @splat(0),
    bias: [plan_module.LATENT]f32 = @splat(0),
    scale: [H]f32 = @splat(0),
    scores: [W]f32 = @splat(0),
};

pub fn decodeCodes(
    comptime capacity: usize,
    source: sb0m.Source,
    index: *const sb0m.Index(capacity),
    plan: *const plan_module.Plan,
    codes: *const [plan_module.CODE_GROUPS]u16,
    state: *State,
    workspace: *Workspace,
    latent: *[plan_module.LATENT]f32,
    use_gpu: bool,
) Error!void {
    if (plan.bound_tensors != plan_module.BOUND_TENSORS) return error.InvalidPlan;
    @memset(&workspace.first_code, 0);
    @memset(&workspace.rest_codes, 0);
    addCodebook(source, index, plan.first_embedding, plan.first_cluster, codes[0],
        &workspace.first_code, workspace) catch return error.QuantizerReadFailure;
    for (1..plan_module.CODE_GROUPS) |group|
        addCodebook(source, index, plan.rest_embedding[group - 1], plan.rest_cluster[group - 1],
            codes[group], &workspace.rest_codes, workspace) catch return error.QuantizerReadFailure;
    backend.matvec(source, tensor(index, plan.first_output), &workspace.first_code,
        &workspace.first_projected, null, &workspace.tensor) catch return error.QuantizerProjectionFailure;
    backend.matvec(source, tensor(index, plan.rest_output), &workspace.rest_codes,
        &workspace.codebook_hidden, null, &workspace.tensor) catch return error.QuantizerProjectionFailure;
    for (&workspace.codebook_hidden, workspace.first_projected) |*destination, first|
        destination.* += first;

    causalPreConv(source, index, plan.pre_conv, &workspace.codebook_hidden,
        state, workspace) catch return error.TransformerInputFailure;
    linear(source, index, plan.transformer_input, &workspace.pre_conv_output,
        &workspace.hidden, workspace) catch return error.TransformerInputFailure;

    // GPU path: run the 8-layer transformer + output projection on the device
    // (matmuls on cuBLAS, elementwise/attention as custom kernels, f32 KV ring),
    // then advance the shared position. The CPU KV state is left untouched — the
    // device holds its own ring — so callers must stay on the GPU path once
    // enabled (enforced by the codec Runtime).
    if (use_gpu) {
        transformerGpu(capacity, index, plan, &workspace.hidden, state.position, latent) catch
            return error.TransformerOutputFailure;
        state.position +%= 1;
        return;
    }

    const slot: usize = @intCast(state.position % W);
    for (plan.transformer_layers, 0..) |layer, layer_index| {
        rmsNorm(source, index, layer.input_norm, &workspace.hidden, &workspace.normalized, workspace) catch
            return error.AttentionProjectionFailure;
        matrix(source, index, layer.query, &workspace.normalized, &workspace.query, workspace) catch
            return error.AttentionProjectionFailure;
        matrix(source, index, layer.key, &workspace.normalized, &workspace.key, workspace) catch
            return error.AttentionProjectionFailure;
        matrix(source, index, layer.value, &workspace.normalized, &workspace.value, workspace) catch
            return error.AttentionProjectionFailure;
        applyRope(&workspace.query, state.position);
        applyRope(&workspace.key, state.position);
        storeKv(&state.keys[layer_index], slot, &workspace.key);
        storeKv(&state.values[layer_index], slot, &workspace.value);
        attention(
            &workspace.query,
            &state.keys[layer_index],
            &state.values[layer_index],
            state.position,
            &workspace.attention,
            &workspace.scores,
        );
        matrix(source, index, layer.attention_output, &workspace.attention, &workspace.projection, workspace) catch
            return error.AttentionProjectionFailure;
        backend.readVector(source, tensor(index, layer.attention_scale), &workspace.scale, &workspace.tensor) catch
            return error.AttentionProjectionFailure;
        for (&workspace.hidden, workspace.projection, workspace.scale) |*hidden, projected, scale|
            hidden.* += projected * scale;

        rmsNorm(source, index, layer.post_attention_norm, &workspace.hidden, &workspace.normalized, workspace) catch
            return error.FeedForwardProjectionFailure;
        matrix(source, index, layer.ffn_gate, &workspace.normalized, &workspace.gate, workspace) catch
            return error.FeedForwardProjectionFailure;
        matrix(source, index, layer.ffn_up, &workspace.normalized, &workspace.up, workspace) catch
            return error.FeedForwardProjectionFailure;
        for (&workspace.gate, workspace.up) |*gate, up| gate.* = silu(gate.*) * up;
        matrix(source, index, layer.ffn_down, &workspace.gate, &workspace.down, workspace) catch
            return error.FeedForwardProjectionFailure;
        backend.readVector(source, tensor(index, layer.ffn_scale), &workspace.scale, &workspace.tensor) catch
            return error.FeedForwardProjectionFailure;
        for (&workspace.hidden, workspace.down, workspace.scale) |*hidden, down, scale|
            hidden.* += down * scale;
    }
    rmsNorm(source, index, plan.transformer_norm, &workspace.hidden, &workspace.normalized, workspace) catch
        return error.TransformerOutputFailure;
    linear(source, index, plan.transformer_output, &workspace.normalized, latent, workspace) catch
        return error.TransformerOutputFailure;
    state.position +%= 1;
    for (latent.*) |value| if (!std.math.isFinite(value)) return error.NonFinite;
}

fn causalPreConv(source: sb0m.Source, index: anytype, conv: plan_module.Conv,
    input: *const [plan_module.CODEBOOK_DIM]f32, state: *State, workspace: *Workspace) backend.Error!void {
    const channels = plan_module.CODEBOOK_DIM;
    for (0..channels) |channel| {
        for (0..2) |tap| {
            const lag = 2 - tap;
            workspace.pre_conv_input[channel * 3 + tap] = if (state.pre_conv_count < lag) 0 else blk: {
                const slot = (state.pre_conv_cursor + 2 - lag) % 2;
                break :blk state.pre_conv_history[@as(usize, slot) * channels + channel];
            };
        }
        workspace.pre_conv_input[channel * 3 + 2] = input[channel];
    }
    try backend.readVector(source, tensor(index, conv.bias),
        workspace.bias[0..plan_module.LATENT], &workspace.tensor);
    try backend.matvec(source, tensor(index, conv.weight), &workspace.pre_conv_input,
        &workspace.pre_conv_output, workspace.bias[0..plan_module.LATENT], &workspace.tensor);
    const cursor: usize = state.pre_conv_cursor;
    @memcpy(state.pre_conv_history[cursor * channels ..][0..channels], input);
    state.pre_conv_cursor = @intCast((cursor + 1) % 2);
    state.pre_conv_count = @min(state.pre_conv_count + 1, 2);
}

fn addCodebook(
    source: sb0m.Source,
    index: anytype,
    embedding_ref: plan_module.TensorRef,
    cluster_ref: plan_module.TensorRef,
    code: u16,
    accumulator: *[plan_module.CODEBOOK_HIDDEN]f32,
    workspace: *Workspace,
) Error!void {
    if (code >= plan_module.CODEBOOK_SIZE) return error.InvalidCode;
    try backend.readRow(source, tensor(index, embedding_ref), code, &workspace.code_row, &workspace.tensor);
    const usage = try backend.readElement(source, tensor(index, cluster_ref), code, &workspace.tensor);
    const denominator = @max(usage, @as(f32, 0.00001));
    for (accumulator, workspace.code_row) |*destination, value| destination.* += value / denominator;
}

fn linear(source: sb0m.Source, index: anytype, value: plan_module.Linear, input: []const f32,
    output: []f32, workspace: *Workspace) Error!void {
    try backend.readVector(source, tensor(index, value.bias), workspace.bias[0..output.len], &workspace.tensor);
    try backend.matvec(source, tensor(index, value.weight), input, output,
        workspace.bias[0..output.len], &workspace.tensor);
}

fn matrix(source: sb0m.Source, index: anytype, reference: plan_module.TensorRef,
    input: []const f32, output: []f32, workspace: *Workspace) Error!void {
    try backend.matvec(source, tensor(index, reference), input, output, null, &workspace.tensor);
}

fn rmsNorm(source: sb0m.Source, index: anytype, reference: plan_module.TensorRef,
    input: *const [H]f32, output: *[H]f32, workspace: *Workspace) Error!void {
    try backend.readVector(source, tensor(index, reference), &workspace.scale, &workspace.tensor);
    var squares: f64 = 0;
    for (input.*) |value| squares += @as(f64, value) * value;
    const inverse: f32 = @floatCast(1.0 / @sqrt(squares / @as(f64, H) + 0.00001));
    for (output, input.*, workspace.scale) |*destination, value, weight|
        destination.* = value * inverse * weight;
}

fn applyRope(vector: *[Q]f32, position: u64) void {
    for (0..plan_module.TRANSFORMER_HEADS) |head| {
        const base = head * plan_module.HEAD_DIM;
        for (0..plan_module.HEAD_DIM / 2) |pair| {
            const exponent = @as(f32, @floatFromInt(pair * 2)) / @as(f32, plan_module.HEAD_DIM);
            const theta = @as(f32, @floatFromInt(position)) /
                std.math.pow(f32, 10_000.0, exponent);
            const cosine = @cos(theta);
            const sine = @sin(theta);
            const first = vector[base + pair];
            const second = vector[base + pair + plan_module.HEAD_DIM / 2];
            vector[base + pair] = first * cosine - second * sine;
            vector[base + pair + plan_module.HEAD_DIM / 2] = second * cosine + first * sine;
        }
    }
}

fn storeKv(storage: *[W * Q]f16, slot: usize, vector: *const [Q]f32) void {
    for (vector.*, 0..) |value, element| storage[slot * Q + element] = @floatCast(value);
}

fn attention(query: *const [Q]f32, keys: *const [W * Q]f16, values: *const [W * Q]f16,
    position: u64, output: *[Q]f32, scores: *[W]f32) void {
    @memset(output, 0);
    const count: usize = @intCast(@min(position + 1, W));
    const oldest = position + 1 - count;
    const scale: f32 = 1.0 / @sqrt(@as(f32, plan_module.HEAD_DIM));
    for (0..plan_module.TRANSFORMER_HEADS) |head| {
        const head_offset = head * plan_module.HEAD_DIM;
        var maximum: f32 = -std.math.floatMax(f32);
        for (0..count) |history| {
            const absolute = oldest + history;
            const slot: usize = @intCast(absolute % W);
            var score: f32 = 0;
            for (0..plan_module.HEAD_DIM) |element|
                score += query[head_offset + element] * @as(f32, @floatCast(keys[slot * Q + head_offset + element]));
            scores[history] = score * scale;
            maximum = @max(maximum, scores[history]);
        }
        var sum: f32 = 0;
        for (scores[0..count]) |*score| {
            score.* = @exp(score.* - maximum);
            sum += score.*;
        }
        const inverse = 1.0 / sum;
        for (0..count) |history| {
            const slot: usize = @intCast((oldest + history) % W);
            const probability = scores[history] * inverse;
            for (0..plan_module.HEAD_DIM) |element|
                output[head_offset + element] += probability *
                    @as(f32, @floatCast(values[slot * Q + head_offset + element]));
        }
    }
}

fn silu(value: f32) f32 { return value / (1.0 + @exp(-value)); }

fn tensor(index: anytype, reference: plan_module.TensorRef) *const sb0m.Tensor {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

test "codec transformer state is bounded to the official sliding window" {
    try std.testing.expectEqual(@as(usize, 72), W);
    try std.testing.expect(@sizeOf(State) < 3 * 1024 * 1024);
    try std.testing.expect(@sizeOf(Workspace) < 256 * 1024);
}

test "rotary transform preserves pair energy" {
    var vector: [Q]f32 = @splat(0);
    vector[0] = 3;
    vector[plan_module.HEAD_DIM / 2] = 4;
    applyRope(&vector, 7);
    try std.testing.expectApproxEqAbs(@as(f32, 25), vector[0] * vector[0] +
        vector[plan_module.HEAD_DIM / 2] * vector[plan_module.HEAD_DIM / 2], 0.0001);
}

// ═══════════════════════════════════════════════════════════════════════════
// GPU codec transformer — device-resident 8-layer sliding-window transformer.
//
// The quantizer front + pre-conv (cheap) stays on the CPU and produces the
// transformer input `hidden` (H=512). This path uploads it once, runs all 8
// layers GPU-resident (matmuls via cuBLAS on resident f32 weights, rmsNorm /
// RoPE / sliding attention / siluGate / scaled residual as custom kernels, an
// f32 KV ring on the device), and downloads the final latent (LATENT=1024).
// Full f32 (more faithful than the CPU Q4×Q8 path). No per-matmul host
// round-trip — the whole layer stack runs before the single download.
// ═══════════════════════════════════════════════════════════════════════════

const TDevice = struct {
    hidden: kernels.CUdeviceptr = 0,
    normalized: kernels.CUdeviceptr = 0,
    q: kernels.CUdeviceptr = 0,
    k: kernels.CUdeviceptr = 0,
    v: kernels.CUdeviceptr = 0,
    attn: kernels.CUdeviceptr = 0,
    proj: kernels.CUdeviceptr = 0,
    gate: kernels.CUdeviceptr = 0,
    up: kernels.CUdeviceptr = 0,
    down: kernels.CUdeviceptr = 0,
    latent: kernels.CUdeviceptr = 0,
    keys: [plan_module.TRANSFORMER_LAYERS]kernels.CUdeviceptr = @splat(0),
    values: [plan_module.TRANSFORMER_LAYERS]kernels.CUdeviceptr = @splat(0),
    ready: bool = false,
};
var tdev: TDevice = .{};
var t_hidden_host: [H]f32 = @splat(0);
var t_latent_host: [plan_module.LATENT]f32 = @splat(0);

pub fn gpuAvailable() bool {
    return kernels.ready();
}

pub fn gpuInit() bool {
    if (tdev.ready) return true;
    if (!kernels.ready()) return false;
    tdev.hidden = kernels.alloc(H);
    tdev.normalized = kernels.alloc(H);
    tdev.q = kernels.alloc(Q);
    tdev.k = kernels.alloc(Q);
    tdev.v = kernels.alloc(Q);
    tdev.attn = kernels.alloc(Q);
    tdev.proj = kernels.alloc(H);
    tdev.gate = kernels.alloc(F);
    tdev.up = kernels.alloc(F);
    tdev.down = kernels.alloc(H);
    tdev.latent = kernels.alloc(plan_module.LATENT);
    var ok = tdev.hidden != 0 and tdev.normalized != 0 and tdev.q != 0 and tdev.k != 0 and
        tdev.v != 0 and tdev.attn != 0 and tdev.proj != 0 and tdev.gate != 0 and tdev.up != 0 and
        tdev.down != 0 and tdev.latent != 0;
    for (0..plan_module.TRANSFORMER_LAYERS) |i| {
        tdev.keys[i] = kernels.alloc(W * Q);
        tdev.values[i] = kernels.alloc(W * Q);
        ok = ok and tdev.keys[i] != 0 and tdev.values[i] != 0;
    }
    if (!ok) {
        gpuDeinit();
        return false;
    }
    tdev.ready = true;
    return true;
}

pub fn gpuDeinit() void {
    kernels.free(tdev.hidden);
    kernels.free(tdev.normalized);
    kernels.free(tdev.q);
    kernels.free(tdev.k);
    kernels.free(tdev.v);
    kernels.free(tdev.attn);
    kernels.free(tdev.proj);
    kernels.free(tdev.gate);
    kernels.free(tdev.up);
    kernels.free(tdev.down);
    kernels.free(tdev.latent);
    for (0..plan_module.TRANSFORMER_LAYERS) |i| {
        kernels.free(tdev.keys[i]);
        kernels.free(tdev.values[i]);
    }
    tdev = .{};
}

/// Zero the device KV ring (call alongside State.reset between utterances).
pub fn gpuResetKv() void {
    if (!tdev.ready) return;
    for (0..plan_module.TRANSFORMER_LAYERS) |i| {
        _ = kernels.zeroDevice(tdev.keys[i], W * Q);
        _ = kernels.zeroDevice(tdev.values[i], W * Q);
    }
}

/// Preload every transformer-layer weight (+ transformer_output) into VRAM.
pub fn gpuPreload(comptime capacity: usize, source: sb0m.Source, index: *const sb0m.Index(capacity), plan: *const plan_module.Plan) bool {
    if (!gpuInit()) return false;
    var ok = true;
    for (plan.transformer_layers) |layer| {
        ok = ok and tpre(source, index, layer.input_norm);
        ok = ok and tpre(source, index, layer.query);
        ok = ok and tpre(source, index, layer.key);
        ok = ok and tpre(source, index, layer.value);
        ok = ok and tpre(source, index, layer.attention_output);
        ok = ok and tpre(source, index, layer.attention_scale);
        ok = ok and tpre(source, index, layer.post_attention_norm);
        ok = ok and tpre(source, index, layer.ffn_gate);
        ok = ok and tpre(source, index, layer.ffn_up);
        ok = ok and tpre(source, index, layer.ffn_down);
        ok = ok and tpre(source, index, layer.ffn_scale);
    }
    ok = ok and tpre(source, index, plan.transformer_norm);
    ok = ok and tpre(source, index, plan.transformer_output.weight);
    ok = ok and tpre(source, index, plan.transformer_output.bias);
    return ok;
}

fn tpre(source: sb0m.Source, index: anytype, ref: plan_module.TensorRef) bool {
    if (!ref.present() or ref.index >= index.tensor_count) return false;
    return kernels.preloadWeight(source, &index.tensors[ref.index]);
}

fn twp(index: anytype, ref: plan_module.TensorRef) kernels.CUdeviceptr {
    return kernels.weightPtr(index.tensors[ref.index].data_offset);
}

/// Run the 8-layer transformer + output projection on the GPU, starting from a
/// host `hidden` (H) and writing `latent` (LATENT). `position` is the current
/// absolute step (state.position). Mirrors the CPU layer loop exactly.
pub fn transformerGpu(
    comptime capacity: usize,
    index: *const sb0m.Index(capacity),
    plan: *const plan_module.Plan,
    hidden_in: *const [H]f32,
    position: u64,
    latent: *[plan_module.LATENT]f32,
) Error!void {
    if (!tdev.ready) return error.InvalidPlan;
    if (!kernels.upload(tdev.hidden, hidden_in[0..H])) return error.NonFinite;
    const slot: usize = @intCast(position % W);

    for (plan.transformer_layers, 0..) |layer, li| {
        // input rmsNorm -> normalized
        try trms(index, layer.input_norm, tdev.hidden, tdev.normalized);
        // q/k/v = W @ normalized
        try tgemm(index, layer.query, tdev.normalized, tdev.q, Q, H);
        try tgemm(index, layer.key, tdev.normalized, tdev.k, Q, H);
        try tgemm(index, layer.value, tdev.normalized, tdev.v, Q, H);
        // RoPE on q,k (codec has no q/k norm)
        if (!kernels.rope(tdev.q, HEADS, HEAD_DIM, position, ROPE_THETA)) return error.NonFinite;
        if (!kernels.rope(tdev.k, HEADS, HEAD_DIM, position, ROPE_THETA)) return error.NonFinite;
        // store k,v into the ring, attend
        if (!kernels.storeKv(tdev.keys[li], tdev.k, slot, Q)) return error.NonFinite;
        if (!kernels.storeKv(tdev.values[li], tdev.v, slot, Q)) return error.NonFinite;
        if (!kernels.slidingAttention(tdev.q, tdev.keys[li], tdev.values[li], tdev.attn, position, HEADS, HEAD_DIM, W)) return error.NonFinite;
        // o_proj -> proj, scaled residual: hidden += proj * attention_scale
        try tgemm(index, layer.attention_output, tdev.attn, tdev.proj, H, Q);
        if (!kernels.scaleAddRows(tdev.hidden, tdev.proj, twp(index, layer.attention_scale), 1, H)) return error.NonFinite;
        // post-attention rmsNorm
        try trms(index, layer.post_attention_norm, tdev.hidden, tdev.normalized);
        // ffn gate/up, siluGate, down, scaled residual
        try tgemm(index, layer.ffn_gate, tdev.normalized, tdev.gate, F, H);
        try tgemm(index, layer.ffn_up, tdev.normalized, tdev.up, F, H);
        if (!kernels.siluGate(tdev.gate, tdev.up, F)) return error.NonFinite;
        try tgemm(index, layer.ffn_down, tdev.gate, tdev.down, H, F);
        if (!kernels.scaleAddRows(tdev.hidden, tdev.down, twp(index, layer.ffn_scale), 1, H)) return error.NonFinite;
    }
    // final norm + output projection
    try trms(index, plan.transformer_norm, tdev.hidden, tdev.normalized);
    try tgemm(index, plan.transformer_output.weight, tdev.normalized, tdev.latent, plan_module.LATENT, H);
    if (!kernels.addBiasRows(tdev.latent, twp(index, plan.transformer_output.bias), 1, plan_module.LATENT)) return error.NonFinite;

    if (!kernels.sync()) return error.NonFinite;
    if (!kernels.download(latent[0..plan_module.LATENT], tdev.latent)) return error.NonFinite;
    for (latent.*) |value| if (!std.math.isFinite(value)) return error.NonFinite;
}

fn trms(index: anytype, ref: plan_module.TensorRef, in: kernels.CUdeviceptr, out: kernels.CUdeviceptr) Error!void {
    const w = twp(index, ref);
    if (w == 0) return error.InvalidPlan;
    if (!kernels.rmsNorm(in, w, out, H, RMS_EPS)) return error.NonFinite;
}

fn tgemm(index: anytype, ref: plan_module.TensorRef, in: kernels.CUdeviceptr, out: kernels.CUdeviceptr, rows: usize, cols: usize) Error!void {
    const w = twp(index, ref);
    if (w == 0) return error.InvalidPlan;
    if (!kernels.gemmDevice(w, in, out, rows, cols)) return error.NonFinite;
}

