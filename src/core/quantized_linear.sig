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
            output[output_offset + lane + 0] = scaledQ6(d,
                scales[scale_offset + scale_lane + 0],
                signedQ6((ql[ql_offset + lane] & 0x0f) | (((high >> 0) & 3) << 4)));
            output[output_offset + lane + 32] = scaledQ6(d,
                scales[scale_offset + scale_lane + 2],
                signedQ6((ql[ql_offset + 32 + lane] & 0x0f) | (((high >> 2) & 3) << 4)));
            output[output_offset + lane + 64] = scaledQ6(d,
                scales[scale_offset + scale_lane + 4],
                signedQ6((ql[ql_offset + lane] >> 4) | (((high >> 4) & 3) << 4)));
            output[output_offset + lane + 96] = scaledQ6(d,
                scales[scale_offset + scale_lane + 6],
                signedQ6((ql[ql_offset + 32 + lane] >> 4) | (((high >> 6) & 3) << 4)));
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

const testing = @import("std").testing;

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

test "Q4_K fused dot matches canonical sub-block layout" {
    const block = q4OnesBlock(0x3c00); // f16 1.0
    const input: [QK_K]f32 = @splat(1);
    // Four groups, each with 32 values of 1 and 32 values of 2.
    try testing.expectApproxEqAbs(@as(f32, 384), try dotQ4K(&block, &input), 0.0001);
}

test "f16 conversion preserves the smallest subnormal" {
    try testing.expectEqual(@as(f32, 0x1p-24), f16ToF32(0x0001));
    try testing.expectEqual(@as(f32, -0x1p-24), f16ToF32(0x8001));
}

test "Q6_K fused dot reconstructs signed six-bit lanes" {
    const block = q6OnesBlock(0x3c00); // every dequantized value is 1
    const input: [QK_K]f32 = @splat(1);
    try testing.expectApproxEqAbs(@as(f32, 256), try dotQ6K(&block, &input), 0.0001);
}

test "Q4_K and Q6_K matvecs preserve row boundaries" {
    const input: [QK_K]f32 = @splat(1);
    const q4_rows = q4OnesBlock(0x3c00) ++ q4OnesBlock(0x4000);
    const q6_rows = q6OnesBlock(0x3c00) ++ q6OnesBlock(0x4000);
    var output: [2]f32 = undefined;
    try matvecQ4K(&output, &q4_rows, &input);
    try testing.expectApproxEqAbs(@as(f32, 384), output[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 768), output[1], 0.0001);
    try matvecQ6K(&output, &q6_rows, &input);
    try testing.expectApproxEqAbs(@as(f32, 256), output[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 512), output[1], 0.0001);
}

test "embedding row dequantization matches fused dot kernels" {
    const q4 = q4OnesBlock(0x3c00);
    const q6 = q6OnesBlock(0x3c00);
    const input: [QK_K]f32 = @splat(1);
    var expanded: [QK_K]f32 = undefined;
    try dequantizeQ4K(&expanded, &q4);
    var sum: f32 = 0;
    for (expanded) |value| sum += value;
    try testing.expectApproxEqAbs(try dotQ4K(&q4, &input), sum, 0.0001);
    try dequantizeQ6K(&expanded, &q6);
    for (expanded) |value| try testing.expectEqual(@as(f32, 1), value);
    sum = 0;
    for (expanded) |value| sum += value;
    try testing.expectApproxEqAbs(try dotQ6K(&q6, &input), sum, 0.0001);
}

test "blocked kernels reject partial rows and truncated storage" {
    var input: [255]f32 = @splat(1);
    var block = q4OnesBlock(0x3c00);
    try testing.expectError(error.InvalidDimensions, dotQ4K(&block, &input));
    const full_input: [QK_K]f32 = @splat(1);
    try testing.expectError(error.BufferTooSmall, dotQ4K(block[0..143], &full_input));
}
