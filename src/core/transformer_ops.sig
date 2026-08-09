//! @zpm/transformer-ops — allocation-free decoder primitives.
//!
//! Every operation receives caller-owned storage. Shapes and capacity are
//! validated at the boundary; model architecture and scheduling stay above.

const std = @import("std");

pub const Error = error{
    InvalidShape,
    BufferTooSmall,
    NonFinite,
};

pub fn rmsNorm(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) Error!void {
    if (input.len == 0 or weight.len != input.len or output.len < input.len or
        !std.math.isFinite(epsilon) or epsilon <= 0) return error.InvalidShape;
    var squares: f64 = 0;
    for (input) |value| {
        if (!std.math.isFinite(value)) return error.NonFinite;
        squares += @as(f64, value) * value;
    }
    const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(mean + epsilon);
    for (input, weight, output[0..input.len]) |value, scale, *destination| {
        destination.* = value * inverse * scale;
    }
}

/// Qwen-family split-half rotary embedding, in place for all heads.
pub fn ropeSplitHalf(values: []f32, head_count: usize, head_size: usize, position: u64, frequency_base: f32) Error!void {
    if (head_count == 0 or head_size == 0 or head_size % 2 != 0 or
        values.len != head_count * head_size or !std.math.isFinite(frequency_base) or frequency_base <= 0)
        return error.InvalidShape;
    const half = head_size / 2;
    for (0..head_count) |head| {
        const base = head * head_size;
        for (0..half) |lane| {
            const exponent = @as(f32, @floatFromInt(2 * lane)) / @as(f32, @floatFromInt(head_size));
            const frequency = 1.0 / std.math.pow(f32, frequency_base, exponent);
            const angle = @as(f32, @floatFromInt(position)) * frequency;
            const cosine = @cos(angle);
            const sine = @sin(angle);
            const low = values[base + lane];
            const high = values[base + half + lane];
            values[base + lane] = low * cosine - high * sine;
            values[base + half + lane] = high * cosine + low * sine;
        }
    }
}

pub fn softmax(values: []f32) Error!void {
    if (values.len == 0) return error.InvalidShape;
    var maximum = values[0];
    if (!std.math.isFinite(maximum)) return error.NonFinite;
    for (values[1..]) |value| {
        if (!std.math.isFinite(value)) return error.NonFinite;
        maximum = @max(maximum, value);
    }
    var sum: f64 = 0;
    for (values) |*value| {
        value.* = @exp(value.* - maximum);
        sum += value.*;
    }
    if (!std.math.isFinite(sum) or sum <= 0) return error.NonFinite;
    const inverse: f32 = @floatCast(1.0 / sum);
    for (values) |*value| value.* *= inverse;
}

/// One causal attention head over flattened `[context, head_size]` K/V.
pub fn attentionHead(
    query: []const f32,
    keys: []const f32,
    values: []const f32,
    context_length: usize,
    scores: []f32,
    output: []f32,
) Error!void {
    const head_size = query.len;
    if (head_size == 0 or context_length == 0 or
        keys.len < context_length * head_size or values.len < context_length * head_size or
        scores.len < context_length or output.len < head_size) return error.InvalidShape;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_size)));
    for (scores[0..context_length], 0..) |*score, position| {
        score.* = dot(query, keys[position * head_size ..][0..head_size]) * scale;
    }
    try softmax(scores[0..context_length]);
    @memset(output[0..head_size], 0);
    for (scores[0..context_length], 0..) |score, position| {
        const value = values[position * head_size ..][0..head_size];
        for (output[0..head_size], value) |*destination, element| destination.* += score * element;
    }
}

pub fn siluGate(gate: []f32, up: []const f32) Error!void {
    if (gate.len != up.len) return error.InvalidShape;
    for (gate, up) |*gate_value, up_value| {
        gate_value.* = (gate_value.* / (1.0 + @exp(-gate_value.*))) * up_value;
    }
}

pub fn argmax(values: []const f32) Error!usize {
    if (values.len == 0) return error.InvalidShape;
    var best_index: usize = 0;
    var best = values[0];
    if (!std.math.isFinite(best)) return error.NonFinite;
    for (values[1..], 1..) |value, index| {
        if (!std.math.isFinite(value)) return error.NonFinite;
        if (value > best) {
            best = value;
            best_index = index;
        }
    }
    return best_index;
}

pub inline fn f32ToF16Bits(value: f32) u16 {
    const half: f16 = @floatCast(value);
    return @bitCast(half);
}

pub inline fn f16BitsToF32(value: u16) f32 {
    const half: f16 = @bitCast(value);
    return @floatCast(half);
}

fn dot(left: []const f32, right: []const f32) f32 {
    var sum: f32 = 0;
    for (left, right) |a, b| sum += a * b;
    return sum;
}

const testing = std.testing;

test "RMSNorm gives unit mean square for unit weights" {
    const input = [_]f32{ 1, 2, 3, 4 };
    const weight: [4]f32 = @splat(1);
    var output: [4]f32 = undefined;
    try rmsNorm(&input, &weight, &output, 1e-6);
    var mean_square: f32 = 0;
    for (output) |value| mean_square += value * value;
    mean_square /= output.len;
    try testing.expectApproxEqAbs(@as(f32, 1), mean_square, 0.00001);
}

test "softmax is stable and normalized" {
    var values = [_]f32{ 10_000, 10_001, 9_999 };
    try softmax(&values);
    try testing.expectApproxEqAbs(@as(f32, 1), values[0] + values[1] + values[2], 0.000001);
    try testing.expect(values[1] > values[0] and values[0] > values[2]);
}

test "split-half RoPE is identity at position zero" {
    var values = [_]f32{ 1, 2, 3, 4 };
    try ropeSplitHalf(&values, 1, 4, 0, 1_000_000);
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &values);
}

test "single-token attention returns its value" {
    const query = [_]f32{ 1, 0 };
    const keys = [_]f32{ 0.5, 0.5 };
    const values = [_]f32{ 7, -3 };
    var scores: [1]f32 = undefined;
    var output: [2]f32 = undefined;
    try attentionHead(&query, &keys, &values, 1, &scores, &output);
    try testing.expectEqualSlices(f32, &values, &output);
}

test "f16 KV conversion preserves normal and subnormal values" {
    for ([_]f32{ 0, 1, -2, 0x1p-20 }) |value| {
        const restored = f16BitsToF32(f32ToF16Bits(value));
        try testing.expectApproxEqAbs(value, restored, @max(@abs(value) * 0.001, 0x1p-24));
    }
}
