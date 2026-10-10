//! Fixed-storage SB0M tensor kernels for the native 12 Hz speech decoder.
//!
//! Regular dense and convolution rows use fused SB0-Q4 x Q8 dots.  Exact
//! short rows (notably depthwise 7-tap kernels) stay f16.  No tensor or full
//! precision model copy is allocated.

const std = @import("std");
const sb0m = @import("tts_model_container");
const quantized = @import("quantized_linear");
const gpu = @import("tts_gpu");

pub const Source = sb0m.Source;
pub const Tensor = sb0m.Tensor;
pub const MAX_ROW_ELEMENTS: usize = 12_288;
pub const MAX_ROW_BYTES: usize = MAX_ROW_ELEMENTS * 2;

pub const Error = quantized.Error || error{
    InvalidTensor,
    InvalidRange,
    StorageFailure,
    ArithmeticOverflow,
    NonFinite,
};

pub const Scratch = struct {
    bytes: [MAX_ROW_BYTES]u8 = @splat(0),
    row: [MAX_ROW_ELEMENTS]f32 = @splat(0),
    q8_values: [MAX_ROW_ELEMENTS]i8 = @splat(0),
    q8_scales: [MAX_ROW_ELEMENTS / quantized.SB0_Q4_ELEMENTS]f32 = @splat(0),
    activation_elements: usize = 0,
    activation_ready: bool = false,
};

pub fn readVector(source: Source, tensor: *const Tensor, output: []f32, scratch: *Scratch) Error!void {
    if (tensor.rank != 1 or tensor.element_count != output.len or tensor.encoding != .f16)
        return error.InvalidTensor;
    try readF16(source, tensor.data_offset, output, scratch);
}

pub fn readElement(source: Source, tensor: *const Tensor, element: usize, scratch: *Scratch) Error!f32 {
    if (tensor.encoding != .f16 or element >= tensor.element_count) return error.InvalidTensor;
    var bytes: [2]u8 = undefined;
    if (!source.read(try add(tensor.data_offset, try multiply(element, 2)), &bytes)) return error.StorageFailure;
    _ = scratch;
    const value = quantized.f16ToF32(@as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8));
    if (!std.math.isFinite(value)) return error.NonFinite;
    return value;
}

pub fn readRow(source: Source, tensor: *const Tensor, row_index: usize, output: []f32, scratch: *Scratch) Error!void {
    if (tensor.rank < 2 or row_index >= tensor.rows() or output.len != tensor.rowElements() or
        output.len > MAX_ROW_ELEMENTS) return error.InvalidTensor;
    const row_bytes: usize = @intCast(tensor.data_bytes / tensor.rows());
    const offset = try add(tensor.data_offset, try multiply(row_index, row_bytes));
    switch (tensor.encoding) {
        .sb0_q4 => {
            const bytes = try readSpan(source, offset, row_bytes, scratch.bytes[0..]);
            try quantized.dequantizeSb0Q4(output, bytes);
        },
        .f16 => try readF16(source, offset, output, scratch),
        .raw_u8 => return error.InvalidTensor,
    }
    for (output) |value| if (!std.math.isFinite(value)) return error.NonFinite;
}

pub fn prepare(source_values: []const f32, scratch: *Scratch) Error!void {
    if (source_values.len == 0 or source_values.len > MAX_ROW_ELEMENTS or
        source_values.len % quantized.SB0_Q4_ELEMENTS != 0) return error.InvalidTensor;
    try quantized.quantizeSb0Q8Activations(
        source_values,
        scratch.q8_values[0..source_values.len],
        scratch.q8_scales[0 .. source_values.len / quantized.SB0_Q4_ELEMENTS],
    );
    scratch.activation_elements = source_values.len;
    scratch.activation_ready = true;
}

pub fn matvec(
    source: Source,
    tensor: *const Tensor,
    input: []const f32,
    output: []f32,
    bias: ?[]const f32,
    scratch: *Scratch,
) Error!void {
    if (tensor.rank < 2 or tensor.rows() != output.len or tensor.rowElements() != input.len or
        input.len > MAX_ROW_ELEMENTS) return error.InvalidTensor;
    if (bias) |values| if (values.len != output.len) return error.InvalidTensor;
    // GPU fast path for resident rank-2 weight matrices (transformer + linear
    // projections). Rank-3 convolution weights are not cached and fall through.
    if (tensor.rank == 2 and gpu.matvec(tensor, input, output, bias)) {
        for (output) |v| if (!std.math.isFinite(v)) return error.NonFinite;
        return;
    }
    const row_bytes: usize = @intCast(tensor.data_bytes / tensor.rows());
    if (tensor.encoding == .sb0_q4) try prepare(input, scratch);
    for (output, 0..) |*destination, row_index| {
        const offset = try add(tensor.data_offset, try multiply(row_index, row_bytes));
        destination.* = switch (tensor.encoding) {
            .sb0_q4 => blk: {
                if (!scratch.activation_ready or scratch.activation_elements != input.len) return error.InvalidTensor;
                const bytes = try readSpan(source, offset, row_bytes, scratch.bytes[0..]);
                break :blk try quantized.dotSb0Q4Q8(
                    bytes,
                    scratch.q8_values[0..input.len],
                    scratch.q8_scales[0 .. input.len / quantized.SB0_Q4_ELEMENTS],
                );
            },
            .f16 => blk: {
                try readF16(source, offset, scratch.row[0..input.len], scratch);
                break :blk dot(scratch.row[0..input.len], input);
            },
            .raw_u8 => return error.InvalidTensor,
        } + if (bias) |values| values[row_index] else 0;
        if (!std.math.isFinite(destination.*)) return error.NonFinite;
    }
}

pub fn dot(left: []const f32, right: []const f32) f32 {
    if (left.len != right.len) unreachable;
    const Vector = @Vector(8, f32);
    var lanes: Vector = @splat(0);
    var index: usize = 0;
    while (index + 8 <= left.len) : (index += 8) {
        const a: Vector = left[index..][0..8].*;
        const b: Vector = right[index..][0..8].*;
        lanes += a * b;
    }
    var total: f32 = @reduce(.Add, lanes);
    while (index < left.len) : (index += 1) total += left[index] * right[index];
    return total;
}

fn readF16(source: Source, offset: u64, output: []f32, scratch: *Scratch) Error!void {
    const bytes = try readSpan(source, offset, output.len * 2, scratch.bytes[0..]);
    for (output, 0..) |*destination, index| {
        const bits = @as(u16, bytes[index * 2]) | (@as(u16, bytes[index * 2 + 1]) << 8);
        destination.* = quantized.f16ToF32(bits);
        if (!std.math.isFinite(destination.*)) return error.NonFinite;
    }
}

fn readSpan(source: Source, offset: u64, length: usize, storage: []u8) Error![]const u8 {
    if (source.map(offset, length, 1)) |pointer| return pointer[0..length];
    if (length > storage.len) return error.InvalidRange;
    if (!source.read(offset, storage[0..length])) return error.StorageFailure;
    return storage[0..length];
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

test "codec backend capacity covers the widest exact persisted row" {
    try std.testing.expectEqual(@as(usize, 12_288), MAX_ROW_ELEMENTS);
    try std.testing.expect(MAX_ROW_ELEMENTS % quantized.SB0_Q4_ELEMENTS == 0);
    try std.testing.expect(@sizeOf(Scratch) < 96 * 1024);
}

test "eight-lane dot retains scalar tail" {
    const a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const b = [_]f32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 165), dot(&a, &b), 0.0001);
}
