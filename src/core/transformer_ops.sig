//! @zpm/transformer-ops — allocation-free decoder primitives.
//!
//! Every operation receives caller-owned storage. Shapes and capacity are
//! validated at the boundary; model architecture and scheduling stay above.

const math = @import("sig_math");

pub const Error = error{
    InvalidShape,
    BufferTooSmall,
    NonFinite,
};

pub fn rmsNorm(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) Error!void {
    if (input.len == 0 or weight.len != input.len or output.len < input.len or
        !math.isFinite(epsilon) or epsilon <= 0) return error.InvalidShape;
    var squares: f64 = 0;
    for (input) |value| {
        if (!math.isFinite(value)) return error.NonFinite;
        squares += @as(f64, value) * value;
    }
    const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(mean + epsilon);
    for (input, weight, output[0..input.len]) |value, scale, *destination| {
        destination.* = value * inverse * scale;
    }
}

/// Affine layer normalization for vision encoders.  Mean and variance are
/// accumulated in f64 to keep the fixed-order scalar reference stable across
/// AArch64 and host differential tests; output storage remains f32.
pub fn layerNorm(
    input: []const f32,
    weight: []const f32,
    bias: []const f32,
    output: []f32,
    epsilon: f32,
) Error!void {
    if (input.len == 0 or weight.len != input.len or bias.len != input.len or
        output.len < input.len or !math.isFinite(epsilon) or epsilon <= 0)
        return error.InvalidShape;
    var sum: f64 = 0;
    for (input) |value| {
        if (!math.isFinite(value)) return error.NonFinite;
        sum += value;
    }
    const mean = sum / @as(f64, @floatFromInt(input.len));
    var squares: f64 = 0;
    for (input) |value| {
        const centered = @as(f64, value) - mean;
        squares += centered * centered;
    }
    const variance: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(variance + epsilon);
    const mean32: f32 = @floatCast(mean);
    for (input, weight, bias, output[0..input.len]) |value, scale, offset, *destination| {
        if (!math.isFinite(scale) or !math.isFinite(offset)) return error.NonFinite;
        destination.* = (value - mean32) * inverse * scale + offset;
    }
}

/// In-place GELU using the exact tanh approximation selected by SmolVLM's
/// `gelu_pytorch_tanh` activation.
pub fn geluTanh(values: []f32) Error!void {
    const coefficient: f32 = 0.7978845608028654; // sqrt(2 / pi)
    for (values) |*value| {
        const x = value.*;
        if (!math.isFinite(x)) return error.NonFinite;
        const inner = coefficient * (x + 0.044715 * x * x * x);
        value.* = 0.5 * x * (1.0 + math.tanh(inner));
    }
}

/// Qwen-family split-half rotary embedding, in place for all heads.
pub fn ropeSplitHalf(values: []f32, head_count: usize, head_size: usize, position: u64, frequency_base: f32) Error!void {
    if (head_count == 0 or head_size == 0 or head_size % 2 != 0 or
        values.len != head_count * head_size or !math.isFinite(frequency_base) or frequency_base <= 0)
        return error.InvalidShape;
    const half = head_size / 2;
    for (0..head_count) |head| {
        const base = head * head_size;
        for (0..half) |lane| {
            const exponent = @as(f32, @floatFromInt(2 * lane)) / @as(f32, @floatFromInt(head_size));
            const frequency = 1.0 / math.pow( frequency_base, exponent);
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
    if (!math.isFinite(maximum)) return error.NonFinite;
    for (values[1..]) |value| {
        if (!math.isFinite(value)) return error.NonFinite;
        maximum = @max(maximum, value);
    }
    var sum: f64 = 0;
    for (values) |*value| {
        value.* = @exp(value.* - maximum);
        sum += value.*;
    }
    if (!math.isFiniteF64(sum) or sum <= 0) return error.NonFinite;
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
    if (!math.isFinite(best)) return error.NonFinite;
    for (values[1..], 1..) |value, index| {
        if (!math.isFinite(value)) return error.NonFinite;
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



test "RMSNorm gives unit mean square for unit weights" {
    const input = [_]f32{ 1, 2, 3, 4 };
    const weight: [4]f32 = @splat(1);
    var output: [4]f32 = undefined;
    try rmsNorm(&input, &weight, &output, 1e-6);
    var mean_square: f32 = 0;
    for (output) |value| mean_square += value * value;
    mean_square /= output.len;
    if (@abs(mean_square - 1) > 0.00001) return error.TestUnexpectedResult;
}

test "softmax is stable and normalized" {
    var values = [_]f32{ 10_000, 10_001, 9_999 };
    try softmax(&values);
    if (@abs(values[0] + values[1] + values[2] - 1) > 0.000001) return error.TestUnexpectedResult;
    if (!(values[1] > values[0] and values[0] > values[2])) return error.TestUnexpectedResult;
}

test "affine layer norm has zero mean and unit variance" {
    const input = [_]f32{ 1, 2, 3, 4 };
    const weight: [4]f32 = @splat(1);
    const bias: [4]f32 = @splat(0);
    var output: [4]f32 = undefined;
    try layerNorm(&input, &weight, &bias, &output, 1e-6);
    var mean: f32 = 0;
    for (output) |value| mean += value;
    mean /= output.len;
    var variance: f32 = 0;
    for (output) |value| variance += value * value;
    variance /= output.len;
    if (@abs(mean - 0) > 0.000001) return error.TestUnexpectedResult;
    if (@abs(variance - 1) > 0.00001) return error.TestUnexpectedResult;
}

test "GELU tanh preserves zero and expected signs" {
    var values = [_]f32{ -1, 0, 1 };
    try geluTanh(&values);
    if (!(values[0] < 0 and values[2] > 0)) return error.TestUnexpectedResult;
    if (values[1] != @as(f32, 0)) return error.TestUnexpectedResult;
    if (@abs(values[2] - 0.841192) > 0.00001) return error.TestUnexpectedResult;
}

test "split-half RoPE is identity at position zero" {
    var values = [_]f32{ 1, 2, 3, 4 };
    try ropeSplitHalf(&values, 1, 4, 0, 1_000_000);
    const expected = [_]f32{ 1, 2, 3, 4 };
    for (expected, values) |a, b| if (a != b) return error.TestUnexpectedResult;
}

test "single-token attention returns its value" {
    const query = [_]f32{ 1, 0 };
    const keys = [_]f32{ 0.5, 0.5 };
    const values = [_]f32{ 7, -3 };
    var scores: [1]f32 = undefined;
    var output: [2]f32 = undefined;
    try attentionHead(&query, &keys, &values, 1, &scores, &output);
    { for (&values, &output) |a, b| { if (a != b) return error.TestUnexpectedResult; } }
}

test "f16 KV conversion preserves normal and subnormal values" {
    for ([_]f32{ 0, 1, -2, 0x1p-20 }) |value| {
        const restored = f16BitsToF32(f32ToF16Bits(value));
        if (@abs(restored - value) > @max(@abs(value) * 0.001, 0x1p-24)) return error.TestUnexpectedResult;
    }
}
