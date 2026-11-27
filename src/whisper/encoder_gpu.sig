//! Resident F16 Whisper encoder. The caller's existing GPU scratch is reused
//! according to activation lifetimes; no allocation occurs here. Host storage
//! is touched only for the input, final output, and an explicit debug observer.
const std = @import("std");
const kernels = @import("kernels.sig");
const model = @import("model.sig");
const cuda = kernels.cuda;
const Error = kernels.Error;

pub fn supported(encoder: anytype) bool {
    const h = encoder.hparams;
    if (h.n_audio_ctx > 1500 or h.n_audio_state > 1280 or h.n_mels > 128 or h.n_mels * 2 > h.n_audio_state) return false;
    inline for (.{ "conv1_w", "conv2_w" }) |field| if (@field(encoder, field).encoding != .f16) return false;
    inline for (.{ "conv1_b", "conv2_b", "positional", "ln_w", "ln_b" }) |field| if (@field(encoder, field).encoding != .f32) return false;
    for (encoder.layers[0..h.n_audio_layer]) |layer| {
        inline for (.{ "query_w", "key_w", "value_w", "out_w", "fc1_w", "fc2_w" }) |field| if (@field(layer, field).encoding != .f16) return false;
        inline for (.{ "attn_norm_w", "attn_norm_b", "query_b", "value_b", "out_b", "mlp_norm_w", "mlp_norm_b", "fc1_b", "fc2_b" }) |field| if (@field(layer, field).encoding != .f32) return false;
    }
    return true;
}

const Buffers = struct {
    x: u64,
    norm: u64,
    q: u64,
    k: u64,
    v: u64,
    context: u64,
    ff: u64,
    scores: u64,
    probabilities: u64,
    fn init(gpu: *kernels.Gpu, ctx: usize, dim: usize) Error!Buffers {
        const elements = ctx * dim;
        var cursor: usize = 0;
        const result: Buffers = .{
            .x = region(gpu.scratch, &cursor, elements * 4),
            .norm = region(gpu.scratch, &cursor, elements * 4),
            .q = region(gpu.scratch, &cursor, elements * 2),
            .k = region(gpu.scratch, &cursor, elements * 2),
            .v = region(gpu.scratch, &cursor, elements * 2),
            .context = region(gpu.scratch, &cursor, elements * 2),
            .ff = region(gpu.scratch, &cursor, elements * 8),
            .scores = region(gpu.scratch, &cursor, ctx * ctx * 4),
            .probabilities = region(gpu.scratch, &cursor, ctx * ctx * 2),
        };
        if (cursor > gpu.scratch_bytes) return error.Capacity;
        return result;
    }
};

fn region(base: u64, cursor: *usize, bytes: usize) u64 {
    cursor.* = std.mem.alignForward(usize, cursor.*, 256);
    const pointer = base + cursor.*;
    cursor.* += bytes;
    return pointer;
}

pub fn run(gpu: *kernels.Gpu, encoder: anytype, mel: []const f32, work: anytype) Error![]const f32 {
    const h = encoder.hparams;
    const ctx: usize = h.n_audio_ctx;
    const dim: usize = h.n_audio_state;
    const frames = ctx * 2;
    const b = try Buffers.init(gpu, ctx, dim);
    // Conv1: FF memory temporarily stores the source mel then the F32 output.
    // Q/K/V's contiguous region stores each convolution's im2col half matrix.
    if (!cuda.uploadToGpu(b.ff, mel.ptr, mel.len * 4)) return error.GpuFailure;
    try columns(gpu, b.ff, b.q, frames, h.n_mels, frames, 1, true);
    try linear(gpu, encoder.conv1_w, b.q, b.norm, frames, h.n_mels * 3, dim);
    try element(gpu, b.norm, encoder.conv1_b, b.ff, 0, frames * dim, dim, 1 | 4);
    if (encoder.observer != null) {
        if (!cuda.downloadFromGpu(work.conv.ptr, b.ff, frames * dim * 4)) return error.GpuFailure;
        encoder.observe(.conv1, 0, work.conv, frames, dim);
    }
    try columns(gpu, b.ff, b.q, frames, dim, ctx, 2, false);
    try linear(gpu, encoder.conv2_w, b.q, b.context, ctx, dim * 3, dim);
    const positional = try gpu.tensor(encoder.positional);
    try element(gpu, b.context, encoder.conv2_b, b.x, 0, ctx * dim, dim, 1 | 4);
    if (encoder.observer != null) {
        if (!cuda.downloadFromGpu(work.x.ptr, b.x, ctx * dim * 4)) return error.GpuFailure;
        encoder.observe(.conv2, 0, work.x, ctx, dim);
    }
    try element(gpu, b.x, null, b.x, positional, ctx * dim, dim, 0);
    for (encoder.layers[0..h.n_audio_layer], 0..) |layer, index| {
        try norm(gpu, b.x, b.norm, layer.attn_norm_w, layer.attn_norm_b, ctx, dim, true);
        try linear(gpu, layer.query_w, b.norm, b.q, ctx, dim, dim);
        try element(gpu, b.q, layer.query_b, b.q, 0, ctx * dim, dim, 1 | 2);
        try linear(gpu, layer.key_w, b.norm, b.k, ctx, dim, dim);
        try linear(gpu, layer.value_w, b.norm, b.v, ctx, dim, dim);
        try element(gpu, b.v, layer.value_b, b.v, 0, ctx * dim, dim, 1 | 2);
        try attention(gpu, b, ctx, dim, h.n_audio_head);
        try linear(gpu, layer.out_w, b.context, b.norm, ctx, dim, dim);
        try element(gpu, b.norm, layer.out_b, b.x, b.x, ctx * dim, dim, 1);
        try norm(gpu, b.x, b.norm, layer.mlp_norm_w, layer.mlp_norm_b, ctx, dim, true);
        try linear(gpu, layer.fc1_w, b.norm, b.ff, ctx, dim, dim * 4);
        try element(gpu, b.ff, layer.fc1_b, b.ff, 0, ctx * dim * 4, dim * 4, 1 | 2 | 4);
        try linear(gpu, layer.fc2_w, b.ff, b.norm, ctx, dim * 4, dim);
        try element(gpu, b.norm, layer.fc2_b, b.x, b.x, ctx * dim, dim, 1);
        if (encoder.observer != null) {
            if (!cuda.downloadFromGpu(work.x.ptr, b.x, ctx * dim * 4)) return error.GpuFailure;
            encoder.observe(.layer, index, work.x, ctx, dim);
        }
    }
    try norm(gpu, b.x, b.norm, encoder.ln_w, encoder.ln_b, ctx, dim, false);
    if (!cuda.downloadFromGpu(work.norm.ptr, b.norm, ctx * dim * 4)) return error.GpuFailure;
    encoder.observe(.final, 0, work.norm, ctx, dim);
    return work.norm;
}

fn linear(gpu: *kernels.Gpu, weight: *const model.Tensor, input: u64, output: u64, rows: usize, in_dim: usize, out_dim: usize) Error!void {
    const w = try gpu.tensor(weight);
    const one: f16 = 1;
    const zero: f16 = 0;
    const result = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .T, .N, @intCast(out_dim), @intCast(rows), @intCast(in_dim), &one, @ptrFromInt(w), 2, @intCast(in_dim), @ptrFromInt(input), 2, @intCast(in_dim), &zero, @ptrFromInt(output), 2, @intCast(out_dim), 64, -1);
    if (result != 0) return error.GpuFailure;
}

fn norm(gpu: *kernels.Gpu, input: u64, output: u64, weight: *const model.Tensor, bias: *const model.Tensor, rows: usize, width: usize, half: bool) Error!void {
    var src = input;
    var w = try gpu.tensor(weight);
    var bias_arg = try gpu.tensor(bias);
    var dst = output;
    var dim: u32 = @intCast(width);
    var half_arg: u32 = @intFromBool(half);
    var args = [_]?*anyopaque{ &src, &w, &bias_arg, &dst, &dim, &half_arg };
    if (!cuda.launchKernel(gpu.encoder_norm, @intCast(rows), 256, 0, &args)) return error.GpuFailure;
}

fn element(gpu: *kernels.Gpu, input: u64, bias: ?*const model.Tensor, output: u64, addend: u64, count: usize, width: usize, flags: u32) Error!void {
    var src = input;
    var bias_arg = if (bias) |tensor| try gpu.tensor(tensor) else @as(u64, 0);
    var dst = output;
    var add = addend;
    var n: u32 = @intCast(count);
    var dim: u32 = @intCast(width);
    var flags_arg = flags;
    var args = [_]?*anyopaque{ &src, &bias_arg, &dst, &add, &n, &dim, &flags_arg };
    if (!cuda.launchKernel(gpu.encoder_element, @intCast((count + 255) / 256), 256, 0, &args)) return error.GpuFailure;
}

fn columns(gpu: *kernels.Gpu, input: u64, output: u64, frames: usize, channels: usize, out_frames: usize, stride: usize, channel_major: bool) Error!void {
    var src = input;
    var dst = output;
    var frames_arg: u32 = @intCast(frames);
    var channels_arg: u32 = @intCast(channels);
    var out_arg: u32 = @intCast(out_frames);
    var stride_arg: u32 = @intCast(stride);
    var layout_arg: u32 = @intFromBool(channel_major);
    var args = [_]?*anyopaque{ &src, &dst, &frames_arg, &channels_arg, &out_arg, &stride_arg, &layout_arg };
    if (!cuda.launchKernel(gpu.encoder_columns, @intCast((out_frames * channels * 3 + 255) / 256), 256, 0, &args)) return error.GpuFailure;
}

fn attention(gpu: *kernels.Gpu, b: Buffers, ctx: usize, dim: usize, heads: usize) Error!void {
    const hd = dim / heads;
    const one: f16 = 1;
    const zero: f16 = 0;
    const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
    for (0..heads) |h| {
        const offset = h * hd * 2;
        // F16 score output follows the independent GGML CUDA numerical oracle.
        const status = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .T, .N, @intCast(ctx), @intCast(ctx), @intCast(hd), &one, @ptrFromInt(b.k + offset), 2, @intCast(dim), @ptrFromInt(b.q + offset), 2, @intCast(dim), &zero, @ptrFromInt(b.probabilities), 2, @intCast(ctx), 64, -1);
        if (status != 0) return error.GpuFailure;
        var from = b.probabilities;
        var to = b.scores;
        var count: u32 = @intCast(ctx * ctx);
        var scale_arg = scale;
        var expand_args = [_]?*anyopaque{ &from, &to, &count, &scale_arg };
        if (!cuda.launchKernel(gpu.encoder_expand, @intCast((ctx * ctx + 255) / 256), 256, 0, &expand_args)) return error.GpuFailure;
        var cols: u32 = @intCast(ctx);
        var rows: u32 = @intCast(ctx);
        var unrestricted: u32 = std.math.maxInt(u32);
        var softmax_args = [_]?*anyopaque{ &to, &cols, &rows, &unrestricted };
        if (!cuda.launchKernel(gpu.softmax, @intCast(ctx), 128, 0, &softmax_args)) return error.GpuFailure;
        var convert_args = [_]?*anyopaque{ &to, &from, &count };
        if (!cuda.launchKernel(gpu.convert, @intCast((ctx * ctx + 255) / 256), 256, 0, &convert_args)) return error.GpuFailure;
        const result = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .N, .N, @intCast(hd), @intCast(ctx), @intCast(ctx), &one, @ptrFromInt(b.v + offset), 2, @intCast(dim), @ptrFromInt(b.probabilities), 2, @intCast(ctx), &zero, @ptrFromInt(b.context + offset), 2, @intCast(dim), 64, -1);
        if (result != 0) return error.GpuFailure;
    }
}

/// Test-only access preserves private kernel helpers without a production ABI.
pub const test_support = if (@import("builtin").is_test) struct {
    pub fn residentContracts() !void {
        if (!cuda.init()) return error.SkipZigTest;
        defer cuda.deinit();
        const arena = cuda.gpuAlloc(1024 * 1024);
        if (arena == 0) return error.GpuFailure;
        defer cuda.gpuFree(arena);
        const scratch = cuda.gpuAlloc(1024 * 1024);
        if (scratch == 0) return error.GpuFailure;
        defer cuda.gpuFree(scratch);
        var entries: [8]kernels.CacheEntry = undefined;
        var gpu = try kernels.Gpu.init(arena, 1024 * 1024, &entries, scratch, 1024 * 1024);
        defer gpu.deinit();
        const weights = [_]f32{ 0.5, 1.25, 2, 0.75, -0.5 };
        const biases = [_]f32{ -0.2, 0.3, 0.5, -0.7, 0.125 };
        const w: model.Tensor = .{ .name = "w", .rank = 1, .encoding = .f32, .dimensions = .{ 5, 1, 1, 1 }, .data = std.mem.sliceAsBytes(&weights) };
        const b: model.Tensor = .{ .name = "b", .rank = 1, .encoding = .f32, .dimensions = .{ 5, 1, 1, 1 }, .data = std.mem.sliceAsBytes(&biases) };
        const input = [_]f32{ -2, -1, 0, 1, 2, -0.5, 0.125, 2.25, 1.5, -3 };
        var expected: [10]f32 = undefined;
        var actual: [10]f32 = undefined;
        if (!cuda.uploadToGpu(scratch, &input, input.len * 4)) return error.GpuFailure;
        try norm(&gpu, scratch, scratch + 4096, &w, &b, 2, 5, false);
        if (!cuda.downloadFromGpu(&actual, scratch + 4096, actual.len * 4)) return error.GpuFailure;
        try kernels.layerNorm(&input, &expected, &w, &b, 2, 1e-5);
        for (actual, expected) |a, e| try std.testing.expectApproxEqAbs(e, a, 1e-6);
        try norm(&gpu, scratch, scratch + 4096, &w, &b, 2, 5, true);
        var half_result: [10]f16 = undefined;
        if (!cuda.downloadFromGpu(&half_result, scratch + 4096, half_result.len * 2)) return error.GpuFailure;
        for (half_result, expected) |a, e| try std.testing.expectEqual(@as(f16, @floatCast(e)), a);
        var half_input: [10]f16 = undefined;
        for (input, 0..) |x, i| {
            half_input[i] = @floatCast(x);
            expected[i] = @floatCast(half_input[i]);
            expected[i] += biases[i % 5];
        }
        kernels.gelu(&expected);
        for (&expected, input) |*e, residual| e.* += residual;
        if (!cuda.uploadToGpu(scratch + 2048, &half_input, half_input.len * 2)) return error.GpuFailure;
        try element(&gpu, scratch + 2048, &b, scratch + 4096, scratch, 10, 5, 1 | 4);
        if (!cuda.downloadFromGpu(&actual, scratch + 4096, actual.len * 4)) return error.GpuFailure;
        for (actual, expected) |a, e| try std.testing.expectApproxEqAbs(e, a, 1e-6);
        const convolution_input = [_]f32{ 1, 10, 100, 2, 20, 200, 3, 30, 300, 4, 40, 400, 5, 50, 500 };
        if (!cuda.uploadToGpu(scratch, &convolution_input, convolution_input.len * 4)) return error.GpuFailure;
        try columns(&gpu, scratch, scratch + 4096, 5, 3, 3, 2, false);
        var converted: [27]f16 = undefined;
        if (!cuda.downloadFromGpu(&converted, scratch + 4096, converted.len * 2)) return error.GpuFailure;
        const expected_columns = [_]f16{ 0, 1, 2, 0, 10, 20, 0, 100, 200, 2, 3, 4, 20, 30, 40, 200, 300, 400, 4, 5, 0, 40, 50, 0, 400, 500, 0 };
        try std.testing.expectEqualSlices(f16, &expected_columns, &converted);
        // An undersized caller arena is rejected before any kernel can write it.
        gpu.scratch_bytes = 1024;
        try std.testing.expectError(error.Capacity, Buffers.init(&gpu, 1500, 1280));
    }
} else struct {};
