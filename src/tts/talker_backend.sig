//! Native SB0M Q4/Q8 tensor backend for Qwen3-TTS.
//!
//! Matrices remain in SB0-Q4, activations are quantized once per matrix phase,
//! and each row executes through the fused integer dot kernel. Embeddings and
//! vectors decode into bounded caller storage; no converted model copy exists.

const std = @import("std");
const sb0m = @import("tts_model_container");
const quantized = @import("quantized_linear");
const gpu = @import("tts_gpu");

pub const Source = sb0m.Source;
pub const TensorInfo = sb0m.Tensor;
pub const Error = quantized.Error || error{
    InvalidTensor,
    InvalidRange,
    StorageFailure,
    ArithmeticOverflow,
    NonFinite,
};

pub fn Index(comptime capacity: usize) type {
    return sb0m.Index(capacity);
}

pub const MAX_ROW_ELEMENTS: usize = 3072;
pub const MAX_ROW_BYTES: usize = MAX_ROW_ELEMENTS * 2;

pub const Scratch = struct {
    row: [MAX_ROW_BYTES]u8 = @splat(0),
    q8_values: [MAX_ROW_ELEMENTS]i8 = @splat(0),
    q8_scales: [MAX_ROW_ELEMENTS / quantized.SB0_Q4_ELEMENTS]f32 = @splat(0),
    activation_elements: usize = 0,
    activation_ready: bool = false,
};

pub fn readVector(source: Source, info: *const TensorInfo, output: []f32, scratch: *Scratch) Error!void {
    if (info.rank != 1 or info.element_count != output.len or info.encoding != .f16)
        return error.InvalidTensor;
    const bytes = try readSpan(source, info.data_offset, output.len * 2, &scratch.row);
    for (output, 0..) |*destination, index| {
        const bits = @as(u16, bytes[index * 2]) | (@as(u16, bytes[index * 2 + 1]) << 8);
        destination.* = quantized.f16ToF32(bits);
        if (!std.math.isFinite(destination.*)) return error.NonFinite;
    }
}

pub fn readEmbedding(source: Source, info: *const TensorInfo, row_index: usize, output: []f32, scratch: *Scratch) Error!void {
    if (info.rank != 2 or info.dimensions[1] != output.len or row_index >= info.dimensions[0])
        return error.InvalidTensor;
    const row_bytes: usize = @intCast(info.data_bytes / info.rows());
    const offset = try add(info.data_offset, try multiply(row_index, row_bytes));
    const bytes = try readSpan(source, offset, row_bytes, &scratch.row);
    switch (info.encoding) {
        .sb0_q4 => try quantized.dequantizeSb0Q4(output, bytes),
        .f16 => {
            if (row_bytes != output.len * 2) return error.InvalidTensor;
            for (output, 0..) |*destination, index| {
                const bits = @as(u16, bytes[index * 2]) | (@as(u16, bytes[index * 2 + 1]) << 8);
                destination.* = quantized.f16ToF32(bits);
            }
        },
        .raw_u8 => return error.InvalidTensor,
    }
}

pub fn prepareMatvec(input: []const f32, scratch: *Scratch) Error!void {
    if (input.len == 0 or input.len > MAX_ROW_ELEMENTS or input.len % quantized.SB0_Q4_ELEMENTS != 0)
        return error.InvalidTensor;
    try quantized.quantizeSb0Q8Activations(
        input,
        scratch.q8_values[0..input.len],
        scratch.q8_scales[0 .. input.len / quantized.SB0_Q4_ELEMENTS],
    );
    scratch.activation_elements = input.len;
    scratch.activation_ready = true;
}

pub fn matrixRows(info: *const TensorInfo) ?usize {
    return if (info.rank == 2) @intCast(info.dimensions[0]) else null;
}

pub fn matrixColumns(info: *const TensorInfo) ?usize {
    return if (info.rank == 2) @intCast(info.dimensions[1]) else null;
}

pub fn matvecRows(
    source: Source,
    info: *const TensorInfo,
    input: []const f32,
    output: []f32,
    bias: ?[]const f32,
    first_row: usize,
    row_budget: usize,
    scratch: *Scratch,
) Error!usize {
    if (info.rank != 2 or info.encoding != .sb0_q4 or info.dimensions[0] != output.len or
        info.dimensions[1] != input.len or first_row > output.len or row_budget == 0 or
        !scratch.activation_ready or scratch.activation_elements != input.len)
        return error.InvalidTensor;
    if (bias) |values| if (values.len != output.len) return error.InvalidTensor;
    // GPU fast path: when the whole matrix is requested in one slice (the
    // executor's default, row_budget ≥ output rows) and the weight is resident
    // in VRAM, run it as one cuBLAS matvec instead of per-row CPU dots.
    if (first_row == 0 and row_budget >= output.len and gpu.matvec(info, input, output, bias)) {
        for (output) |v| if (!std.math.isFinite(v)) return error.NonFinite;
        return output.len;
    }
    const row_bytes: usize = @intCast(info.data_bytes / info.rows());
    if (row_bytes > scratch.row.len) return error.InvalidRange;
    const end = @min(output.len, first_row +| row_budget);
    for (first_row..end) |row_index| {
        const offset = try add(info.data_offset, try multiply(row_index, row_bytes));
        const bytes = try readSpan(source, offset, row_bytes, &scratch.row);
        output[row_index] = try quantized.dotSb0Q4Q8(
            bytes,
            scratch.q8_values[0..input.len],
            scratch.q8_scales[0 .. input.len / quantized.SB0_Q4_ELEMENTS],
        ) + if (bias) |values| values[row_index] else 0;
        if (!std.math.isFinite(output[row_index])) return error.NonFinite;
    }
    return end;
}

/// Compute several projections that share one `input` in a single batched GPU
/// dispatch (one upload + one synchronizing download for all of them), else run
/// them one at a time on the CPU. This is the big win for the attention Q/K/V
/// and the feed-forward gate/up, which each read the same normalized vector —
/// it collapses N GPU stream syncs into one. Up to `gpu.MAX_BATCH` tensors.
pub const MAX_MANY: usize = gpu.MAX_BATCH;
pub fn matvecMany(
    source: Source,
    infos: []const *const TensorInfo,
    input: []const f32,
    outputs: []const []f32,
    scratch: *Scratch,
) Error!void {
    if (infos.len != outputs.len or infos.len == 0) return error.InvalidTensor;
    for (infos, outputs) |info, output| {
        if (info.rank != 2 or info.encoding != .sb0_q4 or info.dimensions[0] != output.len or
            info.dimensions[1] != input.len) return error.InvalidTensor;
    }
    // GPU fast path: one upload + N enqueued gemms + one download.
    if (infos.len <= MAX_MANY and gpu.matvecBatch(infos, input, outputs)) {
        for (outputs) |output| for (output) |v| if (!std.math.isFinite(v)) return error.NonFinite;
        return;
    }
    // CPU fallback: quantize the shared activation once, then each projection.
    try prepareMatvec(input, scratch);
    for (infos, outputs) |info, output| {
        const done = try matvecRows(source, info, input, output, null, 0, output.len, scratch);
        if (done != output.len) return error.InvalidTensor;
    }
}

fn readSpan(source: Source, offset: u64, length: usize, scratch: []u8) Error![]const u8 {
    if (source.map(offset, length, 1)) |pointer| return pointer[0..length];
    if (length > scratch.len) return error.InvalidRange;
    if (!source.read(offset, scratch[0..length])) return error.StorageFailure;
    return scratch[0..length];
}

fn add(left: anytype, right: anytype) Error!u64 {
    const result = @addWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn multiply(left: anytype, right: anytype) Error!u64 {
    const result = @mulWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

test "native backend scratch is fixed and cache-line bounded" {
    try std.testing.expect(@sizeOf(Scratch) < 16 * 1024);
    try std.testing.expect(MAX_ROW_ELEMENTS % quantized.SB0_Q4_ELEMENTS == 0);
}
