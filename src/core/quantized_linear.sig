//! @zpm/quantized-linear — allocation-free GGML linear algebra kernels.
//!
//! These kernels operate on caller-provided slices and contain no model,
//! storage, thread, or device policy. The Q4_K and Q6_K layouts match the
//! canonical GGML block ABI. Matrix rows must contain complete blocks.

pub const Error = error{
    InvalidDimensions,
    BufferTooSmall,
};

pub const QK_K: usize = 256;
pub const Q4_K_BLOCK_BYTES: usize = 144;
pub const Q6_K_BLOCK_BYTES: usize = 210;

/// SB0-native symmetric four-bit row block.  A 32-element block is small
/// enough to divide every linear dimension in the first-class SmolVLM2
/// profiles (576, 768, 960, 1536, 2560, 3072, and 12288), while retaining one independent
/// scale per cache-line-sized activation span.  The canonical byte layout is:
///
///   scale: little-endian IEEE f16
///   quants: 16 bytes, low nibble first, signed two's-complement i4
///
/// This is deliberately not a GGML layout.  It is the compact matrix payload
/// used by the SB0 tensor-program ABI and can be decoded without allocating an
/// intermediate row.
pub const SB0_Q4_ELEMENTS: usize = 32;
pub const SB0_Q4_BLOCK_BYTES: usize = 18;

pub fn f16ToF32(value: u16) f32 {
    const sign: u32 = (@as(u32, value) >> 15) << 31;
    var exponent: u32 = (@as(u32, value) >> 10) & 0x1f;
    var mantissa: u32 = @as(u32, value) & 0x3ff;
    if (exponent == 0) {
        if (mantissa == 0) return @bitCast(sign);
        var shift: u32 = 0;
        while ((mantissa & 0x400) == 0) : (shift += 1) mantissa <<= 1;
        // After normalization the implicit leading bit is at position 10.
        // Half subnormals therefore use exponent (1 - bias - shift), not
        // (0 - bias - shift). The latter silently halves every subnormal.
        return @bitCast(sign | ((127 - 14 - shift) << 23) | ((mantissa & 0x3ff) << 13));
    }
    if (exponent == 31) return @bitCast(sign | 0x7f800000 | (mantissa << 13));
    exponent += 127 - 15;
    return @bitCast(sign | (exponent << 23) | (mantissa << 13));
}

pub fn dotF32(weight_bytes: []const u8, input: []const f32) Error!f32 {
    if (weight_bytes.len < input.len * @sizeOf(f32)) return error.BufferTooSmall;
    var sum: f32 = 0;
    for (input, 0..) |value, index| {
        const offset = index * 4;
        const bits = @as(u32, weight_bytes[offset]) |
            (@as(u32, weight_bytes[offset + 1]) << 8) |
            (@as(u32, weight_bytes[offset + 2]) << 16) |
            (@as(u32, weight_bytes[offset + 3]) << 24);
        sum += @as(f32, @bitCast(bits)) * value;
    }
    return sum;
}

pub fn dotF16(weight_bytes: []const u8, input: []const f32) Error!f32 {
    if (weight_bytes.len < input.len * @sizeOf(u16)) return error.BufferTooSmall;
    var sum: f32 = 0;
    for (input, 0..) |value, index| {
        const offset = index * 2;
        const half = @as(u16, weight_bytes[offset]) | (@as(u16, weight_bytes[offset + 1]) << 8);
        sum += f16ToF32(half) * value;
    }
    return sum;
}

/// Fused SB0-Q4 dequantization and dot product.
pub fn dotSb0Q4(weight_bytes: []const u8, input: []const f32) Error!f32 {
    if (input.len == 0 or input.len % SB0_Q4_ELEMENTS != 0)
        return error.InvalidDimensions;
    const block_count = input.len / SB0_Q4_ELEMENTS;
    if (weight_bytes.len < block_count * SB0_Q4_BLOCK_BYTES)
        return error.BufferTooSmall;
    var result: f32 = 0;
    for (0..block_count) |block_index| result += dotSb0Q4Block(
        weight_bytes[block_index * SB0_Q4_BLOCK_BYTES ..][0..SB0_Q4_BLOCK_BYTES],
        input[block_index * SB0_Q4_ELEMENTS ..][0..SB0_Q4_ELEMENTS],
    );
    return result;
}

/// Expand SB0-Q4 into caller-owned storage for embedding lookup and exact
/// scalar differential tests.
pub fn dequantizeSb0Q4(output: []f32, weight_bytes: []const u8) Error!void {
    if (output.len == 0 or output.len % SB0_Q4_ELEMENTS != 0)
        return error.InvalidDimensions;
    const block_count = output.len / SB0_Q4_ELEMENTS;
    if (weight_bytes.len < block_count * SB0_Q4_BLOCK_BYTES)
        return error.BufferTooSmall;
    for (0..block_count) |block_index| dequantizeSb0Q4Block(
        output[block_index * SB0_Q4_ELEMENTS ..][0..SB0_Q4_ELEMENTS],
        weight_bytes[block_index * SB0_Q4_BLOCK_BYTES ..][0..SB0_Q4_BLOCK_BYTES],
    );
}

pub fn matvecSb0Q4(output: []f32, weight_bytes: []const u8, input: []const f32) Error!void {
    if (output.len == 0 or input.len == 0 or input.len % SB0_Q4_ELEMENTS != 0)
        return error.InvalidDimensions;
    const row_bytes = (input.len / SB0_Q4_ELEMENTS) * SB0_Q4_BLOCK_BYTES;
    const required = @mulWithOverflow(output.len, row_bytes);
    if (required[1] != 0) return error.InvalidDimensions;
    if (weight_bytes.len < required[0]) return error.BufferTooSmall;
    for (output, 0..) |*value, row| value.* = try dotSb0Q4(
        weight_bytes[row * row_bytes ..][0..row_bytes],
        input,
    );
}

/// Quantize one activation row once for reuse across every output row. Each
/// 32-lane block carries an independent f32 scale; the immutable weights keep
/// their canonical f16 scales. This is caller-owned ephemeral scratch, not a
/// new model encoding.
pub fn quantizeSb0Q8Activations(input: []const f32, values: []i8, scales: []f32) Error!void {
    if (input.len == 0 or input.len % SB0_Q4_ELEMENTS != 0 or values.len < input.len or
        scales.len < input.len / SB0_Q4_ELEMENTS) return error.InvalidDimensions;
    for (0..input.len / SB0_Q4_ELEMENTS) |block| {
        const source = input[block * SB0_Q4_ELEMENTS ..][0..SB0_Q4_ELEMENTS];
        var maximum: f32 = 0;
        for (source) |value| maximum = @max(maximum, @abs(value));
        const scale = if (maximum == 0) @as(f32, 0) else maximum / 127.0;
        scales[block] = scale;
        const inverse = if (scale == 0) @as(f32, 0) else 1.0 / scale;
        for (source, values[block * SB0_Q4_ELEMENTS ..][0..SB0_Q4_ELEMENTS]) |value, *quantized| {
            const rounded: i32 = @intFromFloat(@round(value * inverse));
            quantized.* = @intCast(@max(@as(i32, -127), @min(@as(i32, 127), rounded)));
        }
    }
}

/// Fused native Q4 x ephemeral Q8 dot product. On first-class AArch64 SB0
/// targets this shape lowers to integer dot-product instructions, replacing
/// 32 per-lane float conversions and multiplies with fixed vector reductions.
pub fn dotSb0Q4Q8(weight_bytes: []const u8, values: []const i8, scales: []const f32) Error!f32 {
    if (values.len == 0 or values.len % SB0_Q4_ELEMENTS != 0 or
        scales.len < values.len / SB0_Q4_ELEMENTS) return error.InvalidDimensions;
    const block_count = values.len / SB0_Q4_ELEMENTS;
    if (weight_bytes.len < block_count * SB0_Q4_BLOCK_BYTES) return error.BufferTooSmall;
    var result: f32 = 0;
    for (0..block_count) |block| {
        const weight = weight_bytes[block * SB0_Q4_BLOCK_BYTES ..][0..SB0_Q4_BLOCK_BYTES];
        const weight_scale = f16ToF32(readU16(weight, 0));
        result += weight_scale * scales[block] * integerDotSb0Q4(
            weight[2..SB0_Q4_BLOCK_BYTES],
            values[block * SB0_Q4_ELEMENTS ..][0..SB0_Q4_ELEMENTS],
        );
    }
    return result;
}

/// Host-side canonical encoder.  It owns no storage and writes exactly one
/// block, allowing model packers to stream arbitrarily large tensors.
pub fn quantizeSb0Q4Block(input: []const f32, output: []u8) Error!void {
    if (input.len != SB0_Q4_ELEMENTS) return error.InvalidDimensions;
    if (output.len < SB0_Q4_BLOCK_BYTES) return error.BufferTooSmall;

    var maximum: f32 = 0;
    for (input) |value| {
        const magnitude = @abs(value);
        if (magnitude > maximum) maximum = magnitude;
    }
    const requested_scale = if (maximum == 0) @as(f32, 0) else maximum / 7.0;
    const scale_bits: u16 = @bitCast(@as(f16, @floatCast(requested_scale)));
    output[0] = @truncate(scale_bits);
    output[1] = @truncate(scale_bits >> 8);
    @memset(output[2..SB0_Q4_BLOCK_BYTES], 0);
    const scale = f16ToF32(scale_bits);
    if (scale == 0) return;

    for (input, 0..) |value, index| {
        const rounded: i32 = @intFromFloat(@round(value / scale));
        const bounded = @max(@as(i32, -7), @min(@as(i32, 7), rounded));
        const nibble: u8 = @as(u8, @bitCast(@as(i8, @intCast(bounded)))) & 0x0f;
        const byte_index = 2 + index / 2;
        if (index & 1 == 0)
            output[byte_index] = nibble
        else
            output[byte_index] |= nibble << 4;
    }
}

/// Fused Q4_K dequantization and dot product. Each 256-element block is read
/// once and no intermediate f32 weight row is materialized.
pub fn dotQ4K(weight_bytes: []const u8, input: []const f32) Error!f32 {
    if (input.len == 0 or input.len % QK_K != 0) return error.InvalidDimensions;
    const block_count = input.len / QK_K;
    if (weight_bytes.len < block_count * Q4_K_BLOCK_BYTES) return error.BufferTooSmall;
    var result: f32 = 0;
    for (0..block_count) |block_index| {
        result += dotQ4KBlock(
            weight_bytes[block_index * Q4_K_BLOCK_BYTES ..][0..Q4_K_BLOCK_BYTES],
            input[block_index * QK_K ..][0..QK_K],
        );
    }
    return result;
}

/// Fused Q6_K dequantization and dot product.
pub fn dotQ6K(weight_bytes: []const u8, input: []const f32) Error!f32 {
    if (input.len == 0 or input.len % QK_K != 0) return error.InvalidDimensions;
    const block_count = input.len / QK_K;
    if (weight_bytes.len < block_count * Q6_K_BLOCK_BYTES) return error.BufferTooSmall;
    var result: f32 = 0;
    for (0..block_count) |block_index| {
        result += dotQ6KBlock(
            weight_bytes[block_index * Q6_K_BLOCK_BYTES ..][0..Q6_K_BLOCK_BYTES],
            input[block_index * QK_K ..][0..QK_K],
        );
    }
    return result;
}

/// Expand a complete Q4_K row into caller-owned f32 storage. Embedding lookup
/// needs the row itself rather than a dot product; keeping this beside the
/// fused kernels guarantees both paths share the canonical GGML layout.
pub fn dequantizeQ4K(output: []f32, weight_bytes: []const u8) Error!void {
    if (output.len == 0 or output.len % QK_K != 0) return error.InvalidDimensions;
    const block_count = output.len / QK_K;
    if (weight_bytes.len < block_count * Q4_K_BLOCK_BYTES) return error.BufferTooSmall;
    for (0..block_count) |block_index| dequantizeQ4KBlock(
        output[block_index * QK_K ..][0..QK_K],
        weight_bytes[block_index * Q4_K_BLOCK_BYTES ..][0..Q4_K_BLOCK_BYTES],
    );
}

/// Expand a complete Q6_K row into caller-owned f32 storage.
pub fn dequantizeQ6K(output: []f32, weight_bytes: []const u8) Error!void {
    if (output.len == 0 or output.len % QK_K != 0) return error.InvalidDimensions;
    const block_count = output.len / QK_K;
    if (weight_bytes.len < block_count * Q6_K_BLOCK_BYTES) return error.BufferTooSmall;
    for (0..block_count) |block_index| dequantizeQ6KBlock(
        output[block_index * QK_K ..][0..QK_K],
        weight_bytes[block_index * Q6_K_BLOCK_BYTES ..][0..Q6_K_BLOCK_BYTES],
    );
}

pub fn matvecQ4K(output: []f32, weight_bytes: []const u8, input: []const f32) Error!void {
    try validateMatrix(output, weight_bytes, input, Q4_K_BLOCK_BYTES);
    const row_bytes = (input.len / QK_K) * Q4_K_BLOCK_BYTES;
    for (output, 0..) |*value, row| value.* = try dotQ4K(weight_bytes[row * row_bytes ..][0..row_bytes], input);
}

pub fn matvecQ6K(output: []f32, weight_bytes: []const u8, input: []const f32) Error!void {
    try validateMatrix(output, weight_bytes, input, Q6_K_BLOCK_BYTES);
    const row_bytes = (input.len / QK_K) * Q6_K_BLOCK_BYTES;
    for (output, 0..) |*value, row| value.* = try dotQ6K(weight_bytes[row * row_bytes ..][0..row_bytes], input);
}

fn validateMatrix(output: []f32, weight_bytes: []const u8, input: []const f32, block_bytes: usize) Error!void {
    if (output.len == 0 or input.len == 0 or input.len % QK_K != 0) return error.InvalidDimensions;
    const row_bytes = (input.len / QK_K) * block_bytes;
    const required = @mulWithOverflow(output.len, row_bytes);
    if (required[1] != 0) return error.InvalidDimensions;
    if (weight_bytes.len < required[0]) return error.BufferTooSmall;
}

fn dotSb0Q4Block(block: []const u8, input: []const f32) f32 {
    const scale = f16ToF32(readU16(block, 0));
    const quants = block[2..SB0_Q4_BLOCK_BYTES];
    const Packed = @Vector(16, u8);
    const Wide = @Vector(32, u8);
    const Signed = @Vector(32, i8);
    const Values = @Vector(32, f32);
    const encoded: Packed = quants[0..16].*;
    const low = encoded & @as(Packed, @splat(0x0f));
    const high = encoded >> @as(Packed, @splat(4));
    const interleave_mask: @Vector(32, i32) = .{
        0, -1, 1, -2,  2,  -3,  3,  -4,  4,  -5,  5,  -6,  6,  -7,  7,  -8,
        8, -9, 9, -10, 10, -11, 11, -12, 12, -13, 13, -14, 14, -15, 15, -16,
    };
    const interleaved: Wide = @shuffle(u8, low, high, interleave_mask);
    // Move bit 3 into the sign bit, then arithmetic-shift it back.  This maps
    // the canonical two's-complement i4 lanes to vector i8 without branches.
    const sign_bits: Signed = @bitCast(interleaved << @as(Wide, @splat(4)));
    const signed = sign_bits >> @as(Signed, @splat(4));
    const values: Values = @floatFromInt(signed);
    const activations: Values = input[0..SB0_Q4_ELEMENTS].*;
    return scale * @reduce(.Add, values * activations);
}

inline fn integerDotSb0Q4(quants: []const u8, activations: []const i8) f32 {
    const Packed = @Vector(16, u8);
    const Wide = @Vector(32, u8);
    const Signed = @Vector(32, i8);
    const Sum = @Vector(32, i32);
    const encoded: Packed = quants[0..16].*;
    const low = encoded & @as(Packed, @splat(0x0f));
    const high = encoded >> @as(Packed, @splat(4));
    const interleave_mask: @Vector(32, i32) = .{
        0, -1, 1, -2,  2,  -3,  3,  -4,  4,  -5,  5,  -6,  6,  -7,  7,  -8,
        8, -9, 9, -10, 10, -11, 11, -12, 12, -13, 13, -14, 14, -15, 15, -16,
    };
    const interleaved: Wide = @shuffle(u8, low, high, interleave_mask);
    const sign_bits: Signed = @bitCast(interleaved << @as(Wide, @splat(4)));
    const weights = sign_bits >> @as(Signed, @splat(4));
    const activation_vector: Signed = activations[0..SB0_Q4_ELEMENTS].*;
    const wide_weights: Sum = weights;
    const wide_activations: Sum = activation_vector;
    return @floatFromInt(@reduce(.Add, wide_weights * wide_activations));
}

fn dequantizeSb0Q4Block(output: []f32, block: []const u8) void {
    const scale = f16ToF32(readU16(block, 0));
    const quants = block[2..SB0_Q4_BLOCK_BYTES];
    for (output, 0..) |*value, index| {
        const quant_byte = quants[index / 2];
        const nibble = if (index & 1 == 0) quant_byte & 0x0f else quant_byte >> 4;
        value.* = scale * @as(f32, @floatFromInt(signedNibble(nibble)));
    }
}

inline fn signedNibble(value: u8) i8 {
    return if (value & 0x08 == 0)
        @intCast(value)
    else
        @intCast(@as(i16, value) - 16);
}

const ScaleMin = struct { scale: u8, minimum: u8 };

inline fn scaleMinQ4K(group: usize, scales: []const u8) ScaleMin {
    if (group < 4) return .{ .scale = scales[group] & 63, .minimum = scales[group + 4] & 63 };
    return .{
        .scale = (scales[group + 4] & 0x0f) | ((scales[group - 4] >> 6) << 4),
        .minimum = (scales[group + 4] >> 4) | ((scales[group] >> 6) << 4),
    };
}

fn dotQ4KBlock(block: []const u8, input: []const f32) f32 {
    const d = f16ToF32(readU16(block, 0));
    const dmin = f16ToF32(readU16(block, 2));
    const scales = block[4..16];
    const quants = block[16..144];
    const Vector = @Vector(8, f32);
    var vector_sum: Vector = @splat(0);

    for (0..4) |pair| {
        const low = scaleMinQ4K(pair * 2, scales);
        const high = scaleMinQ4K(pair * 2 + 1, scales);
        const low_scale: Vector = @splat(d * @as(f32, @floatFromInt(low.scale)));
        const low_minimum: Vector = @splat(dmin * @as(f32, @floatFromInt(low.minimum)));
        const high_scale: Vector = @splat(d * @as(f32, @floatFromInt(high.scale)));
        const high_minimum: Vector = @splat(dmin * @as(f32, @floatFromInt(high.minimum)));
        const quant_offset = pair * 32;
        const input_offset = pair * 64;

        inline for (0..4) |chunk| {
            const offset = chunk * 8;
            const quant: Vector = .{
                @floatFromInt(quants[quant_offset + offset + 0] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 1] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 2] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 3] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 4] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 5] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 6] & 0x0f),
                @floatFromInt(quants[quant_offset + offset + 7] & 0x0f),
            };
            const activation: Vector = input[input_offset + offset ..][0..8].*;
            vector_sum += (low_scale * quant - low_minimum) * activation;
        }
        inline for (0..4) |chunk| {
            const offset = chunk * 8;
            const quant: Vector = .{
                @floatFromInt(quants[quant_offset + offset + 0] >> 4),
                @floatFromInt(quants[quant_offset + offset + 1] >> 4),
                @floatFromInt(quants[quant_offset + offset + 2] >> 4),
                @floatFromInt(quants[quant_offset + offset + 3] >> 4),
                @floatFromInt(quants[quant_offset + offset + 4] >> 4),
                @floatFromInt(quants[quant_offset + offset + 5] >> 4),
                @floatFromInt(quants[quant_offset + offset + 6] >> 4),
                @floatFromInt(quants[quant_offset + offset + 7] >> 4),
            };
            const activation: Vector = input[input_offset + 32 + offset ..][0..8].*;
            vector_sum += (high_scale * quant - high_minimum) * activation;
        }
    }
    return @reduce(.Add, vector_sum);
}

fn dequantizeQ4KBlock(output: []f32, block: []const u8) void {
    const d = f16ToF32(readU16(block, 0));
    const dmin = f16ToF32(readU16(block, 2));
    const scales = block[4..16];
    const quants = block[16..144];
    for (0..4) |pair| {
        const low = scaleMinQ4K(pair * 2, scales);
        const high = scaleMinQ4K(pair * 2 + 1, scales);
        const low_scale = d * @as(f32, @floatFromInt(low.scale));
        const low_minimum = dmin * @as(f32, @floatFromInt(low.minimum));
        const high_scale = d * @as(f32, @floatFromInt(high.scale));
        const high_minimum = dmin * @as(f32, @floatFromInt(high.minimum));
        const quant_offset = pair * 32;
        const output_offset = pair * 64;
        for (0..32) |lane| {
            const quant_byte = quants[quant_offset + lane];
            output[output_offset + lane] = low_scale *
                @as(f32, @floatFromInt(quant_byte & 0x0f)) - low_minimum;
            output[output_offset + 32 + lane] = high_scale *
                @as(f32, @floatFromInt(quant_byte >> 4)) - high_minimum;
        }
    }
}

fn dotQ6KBlock(block: []const u8, input: []const f32) f32 {
    const ql = block[0..128];
    const qh = block[128..192];
    const scales = block[192..208];
    const d = f16ToF32(readU16(block, 208));
    const Vector = @Vector(8, f32);
    var vector_sum: Vector = @splat(0);
    for (0..2) |half| {
        const ql_offset = half * 64;
        const qh_offset = half * 32;
        const scale_offset = half * 8;
        const input_offset = half * 128;
        inline for (0..4) |chunk| {
            const lane = chunk * 8;
            const scale_lane = lane / 16;
            var q1: Vector = undefined;
            var q2: Vector = undefined;
            var q3: Vector = undefined;
            var q4: Vector = undefined;
            inline for (0..8) |index| {
                const high = qh[qh_offset + lane + index];
                q1[index] = @floatFromInt(signedQ6(
                    (ql[ql_offset + lane + index] & 0x0f) | (((high >> 0) & 3) << 4),
                ));
                q2[index] = @floatFromInt(signedQ6(
                    (ql[ql_offset + 32 + lane + index] & 0x0f) | (((high >> 2) & 3) << 4),
                ));
                q3[index] = @floatFromInt(signedQ6(
                    (ql[ql_offset + lane + index] >> 4) | (((high >> 4) & 3) << 4),
                ));
                q4[index] = @floatFromInt(signedQ6(
                    (ql[ql_offset + 32 + lane + index] >> 4) | (((high >> 6) & 3) << 4),
                ));
            }
            const s1: Vector = @splat(d * scaleF32(scales[scale_offset + scale_lane + 0]));
            const s2: Vector = @splat(d * scaleF32(scales[scale_offset + scale_lane + 2]));
            const s3: Vector = @splat(d * scaleF32(scales[scale_offset + scale_lane + 4]));
            const s4: Vector = @splat(d * scaleF32(scales[scale_offset + scale_lane + 6]));
            vector_sum += s1 * q1 * input[input_offset + lane + 0 ..][0..8].*;
            vector_sum += s2 * q2 * input[input_offset + lane + 32 ..][0..8].*;
            vector_sum += s3 * q3 * input[input_offset + lane + 64 ..][0..8].*;
            vector_sum += s4 * q4 * input[input_offset + lane + 96 ..][0..8].*;
        }
    }
    return @reduce(.Add, vector_sum);
}

fn dequantizeQ6KBlock(output: []f32, block: []const u8) void {
    const ql = block[0..128];
    const qh = block[128..192];
    const scales = block[192..208];
    const d = f16ToF32(readU16(block, 208));
    for (0..2) |half| {
        const ql_offset = half * 64;
        const qh_offset = half * 32;
        const scale_offset = half * 8;
        const output_offset = half * 128;
        for (0..32) |lane| {
            const scale_lane = lane / 16;
            const high = qh[qh_offset + lane];
            output[output_offset + lane + 0] = scaledQ6(d, scales[scale_offset + scale_lane + 0], signedQ6((ql[ql_offset + lane] & 0x0f) | (((high >> 0) & 3) << 4)));
            output[output_offset + lane + 32] = scaledQ6(d, scales[scale_offset + scale_lane + 2], signedQ6((ql[ql_offset + 32 + lane] & 0x0f) | (((high >> 2) & 3) << 4)));
            output[output_offset + lane + 64] = scaledQ6(d, scales[scale_offset + scale_lane + 4], signedQ6((ql[ql_offset + lane] >> 4) | (((high >> 4) & 3) << 4)));
            output[output_offset + lane + 96] = scaledQ6(d, scales[scale_offset + scale_lane + 6], signedQ6((ql[ql_offset + 32 + lane] >> 4) | (((high >> 6) & 3) << 4)));
        }
    }
}

inline fn signedQ6(value: u8) i8 {
    return @intCast(@as(i16, value) - 32);
}

inline fn scaledQ6(d: f32, scale_bits: u8, quant: i8) f32 {
    return d * scaleF32(scale_bits) * @as(f32, @floatFromInt(quant));
}

inline fn scaleF32(scale_bits: u8) f32 {
    return @floatFromInt(@as(i8, @bitCast(scale_bits)));
}

inline fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}


fn q4OnesBlock(scale_half: u16) [Q4_K_BLOCK_BYTES]u8 {
    var block: [Q4_K_BLOCK_BYTES]u8 = @splat(0);
    block[0] = @truncate(scale_half);
    block[1] = @truncate(scale_half >> 8);
    block[4..16].* = .{ 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1 };
    @memset(block[16..144], 0x21);
    return block;
}

fn q6OnesBlock(scale_half: u16) [Q6_K_BLOCK_BYTES]u8 {
    var block: [Q6_K_BLOCK_BYTES]u8 = @splat(0);
    @memset(block[0..128], 0x11);
    @memset(block[128..192], 0xaa);
    @memset(block[192..208], 1);
    block[208] = @truncate(scale_half);
    block[209] = @truncate(scale_half >> 8);
    return block;
}


// Tests

test "f16 conversion round-trip" {
    const val: f32 = 1.5;
    const bits = @as(u16, @bitCast(@as(f16, @floatCast(val))));
    const restored = f16ToF32(bits);
    if (@abs(restored - val) > 0.001) return error.TestUnexpectedResult;
}

test "Q4_K dot product smoke" {
    // Minimal: verify the function signature compiles and accepts valid dims
    var block: [Q4_K_BLOCK_BYTES]u8 = @splat(0);
    var input: [QK_K]f32 = @splat(0);
    const result = try dotQ4K(&block, &input);
    if (result != 0) return error.TestUnexpectedResult; // zero weights * zero input = 0
}

