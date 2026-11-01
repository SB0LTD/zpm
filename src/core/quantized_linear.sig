//! @zpm/quantized-linear — allocation-free GGML linear algebra kernels.
//!
//! These kernels operate on caller-provided slices and contain no model,
//! storage, thread, or device policy. The Q4_K and Q6_K layouts match the
//! canonical GGML block ABI. Matrix rows must contain complete blocks.

const std = @import("std");
const builtin = @import("builtin");

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

/// GGML Q8_K activation block: one f32 scale, 256 signed bytes and the sixteen
/// 16-lane sums that fold Q4_K minimums into one multiply. Activations are
/// quantized once per matrix input and reused across every weight row, which
/// is both the integer fast path and the exact numerics of GGML's CPU backend.
pub const Q8KBlock = struct {
    d: f32 = 0,
    qs: [QK_K]i8 = @splat(0),
    bsums: [QK_K / 16]i16 = @splat(0),
};

/// Quantize complete 256-lane blocks exactly as GGML's quantize_row_q8_K_ref:
/// the scale follows the signed maximum magnitude and rounding is to nearest,
/// ties to even.
pub fn quantizeQ8K(input: []const f32, output: []Q8KBlock) Error!void {
    if (input.len == 0 or input.len % QK_K != 0) return error.InvalidDimensions;
    if (output.len < input.len / QK_K) return error.BufferTooSmall;
    for (output[0 .. input.len / QK_K], 0..) |*block, block_index| {
        const source = input[block_index * QK_K ..][0..QK_K];
        var maximum: f32 = 0;
        var magnitude: f32 = 0;
        for (source) |value| {
            if (@abs(value) > magnitude) {
                magnitude = @abs(value);
                maximum = value;
            }
        }
        if (magnitude == 0) {
            block.* = .{};
            continue;
        }
        const inverse = -127.0 / maximum;
        for (source, &block.qs) |value, *quantized| quantized.* = @intCast(@min(127, nearestInt(inverse * value)));
        for (&block.bsums, 0..) |*sum, group| {
            var total: i16 = 0;
            for (block.qs[group * 16 ..][0..16]) |quantized| total += quantized;
            sum.* = total;
        }
        block.d = 1.0 / inverse;
    }
}

/// Q4_K weight row x Q8_K activations, GGML's ggml_vec_dot_q4_K_q8_K.
pub fn dotQ4KQ8K(weight_bytes: []const u8, activations: []const Q8KBlock) Error!f32 {
    if (activations.len == 0) return error.InvalidDimensions;
    if (weight_bytes.len < activations.len * Q4_K_BLOCK_BYTES) return error.BufferTooSmall;
    return dotQ4KQ8KTile(1, weight_bytes, .{activations.ptr}, activations.len)[0];
}

/// Q6_K weight row x Q8_K activations, GGML's ggml_vec_dot_q6_K_q8_K.
pub fn dotQ6KQ8K(weight_bytes: []const u8, activations: []const Q8KBlock) Error!f32 {
    if (activations.len == 0) return error.InvalidDimensions;
    if (weight_bytes.len < activations.len * Q6_K_BLOCK_BYTES) return error.BufferTooSmall;
    return dotQ6KQ8KTile(1, weight_bytes, .{activations.ptr}, activations.len)[0];
}

pub const MAX_TILE: usize = 4;

/// One weight row against up to MAX_TILE activation rows of `blocks` blocks:
/// each weight block is unpacked once and reused, which is what makes batched
/// prefill cheaper per token than decode. Callers guarantee that the weight
/// row and every activation row hold `blocks` complete blocks.
pub fn dotQ4KQ8KTile(comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count]f32 {
    var sums: [count]F32x8 = @splat(@splat(0));
    for (0..blocks) |block_index| {
        const block = weight_bytes[block_index * Q4_K_BLOCK_BYTES ..][0..Q4_K_BLOCK_BYTES];
        const unpacked = unpackScalesQ4K(block[4..16]);
        const scales: @Vector(8, i16) = unpacked[0];
        const mins: @Vector(8, i16) = unpacked[1];
        var integer: [count]I32x8 = @splat(@splat(0));
        inline for (0..4) |pair| {
            const quants: Bytes32 = block[16 + pair * 32 ..][0..32].*;
            const low = quants & @as(Bytes32, @splat(0x0f));
            const high = quants >> @as(Bytes32, @splat(4));
            const low_scale: Words16 = @splat(scales[pair * 2]);
            const high_scale: Words16 = @splat(scales[pair * 2 + 1]);
            inline for (0..count) |row| {
                const qs = &activations[row][block_index].qs;
                integer[row] += mulAddWords(mulAddPairs(low, qs[pair * 64 ..][0..32].*), low_scale) +
                    mulAddWords(mulAddPairs(high, qs[pair * 64 + 32 ..][0..32].*), high_scale);
            }
        }
        // Each minimum covers two 16-lane bsums.
        const min_pairs: Words16 = @shuffle(i16, mins, undefined, [16]i32{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 });
        const d = f16ToF32(readU16(block, 0));
        const dmin = f16ToF32(readU16(block, 2));
        inline for (0..count) |row| {
            const activation = &activations[row][block_index];
            const bsums: Words16 = activation.bsums;
            const minimum: F32x8 = @floatFromInt(mulAddWords(bsums, min_pairs));
            sums[row] += @as(F32x8, @splat(d * activation.d)) * @as(F32x8, @floatFromInt(integer[row])) -
                @as(F32x8, @splat(dmin * activation.d)) * minimum;
        }
    }
    var result: [count]f32 = undefined;
    inline for (0..count) |row| result[row] = @reduce(.Add, sums[row]);
    return result;
}

/// The eight 6-bit scales and eight 6-bit minimums of a Q4_K block, unpacked
/// with GGML's four-word mask sequence instead of eight per-group branches.
inline fn unpackScalesQ4K(packed_scales: *const [12]u8) [2][8]i16 {
    const mask_low: u32 = 0x3f3f3f3f;
    const mask_nibble: u32 = 0x0f0f0f0f;
    const mask_top: u32 = 0x03030303;
    var words: [4]u32 = undefined;
    for (0..3) |index| words[index] = @as(u32, packed_scales[index * 4]) | (@as(u32, packed_scales[index * 4 + 1]) << 8) |
        (@as(u32, packed_scales[index * 4 + 2]) << 16) | (@as(u32, packed_scales[index * 4 + 3]) << 24);
    words[3] = ((words[2] >> 4) & mask_nibble) | (((words[1] >> 6) & mask_top) << 4);
    const minimums_low = words[1] & mask_low;
    words[1] = (words[2] & mask_nibble) | (((words[0] >> 6) & mask_top) << 4);
    words[2] = minimums_low;
    words[0] &= mask_low;
    const bytes: [16]u8 = @bitCast(words);
    const scales: @Vector(8, u8) = bytes[0..8].*;
    const minimums: @Vector(8, u8) = bytes[8..16].*;
    return .{ @as(@Vector(8, i16), scales), @as(@Vector(8, i16), minimums) };
}

/// Q6_K counterpart of dotQ4KQ8KTile. Quants enter the multiply unsigned
/// (0..63); the -32 offset is applied once per block through the bsums.
pub fn dotQ6KQ8KTile(comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count]f32 {
    var sums: [count]F32x8 = @splat(@splat(0));
    const nibble: Bytes32 = @splat(0x0f);
    const three: Bytes32 = @splat(3);
    for (0..blocks) |block_index| {
        const block = weight_bytes[block_index * Q6_K_BLOCK_BYTES ..][0..Q6_K_BLOCK_BYTES];
        const scale_bytes: @Vector(16, i8) = @bitCast(block[192..208].*);
        const scales: Words16 = scale_bytes;
        var integer: [count]I32x8 = @splat(@splat(0));
        inline for (0..2) |half| {
            const low: Bytes32 = block[half * 64 ..][0..32].*;
            const next: Bytes32 = block[half * 64 + 32 ..][0..32].*;
            const high: Bytes32 = block[128 + half * 32 ..][0..32].*;
            const quarters = [4]Bytes32{
                (low & nibble) | ((high & three) << @as(Bytes32, @splat(4))),
                (next & nibble) | (((high >> @as(Bytes32, @splat(2))) & three) << @as(Bytes32, @splat(4))),
                (low >> @as(Bytes32, @splat(4))) | (((high >> @as(Bytes32, @splat(4))) & three) << @as(Bytes32, @splat(4))),
                (next >> @as(Bytes32, @splat(4))) | ((high >> @as(Bytes32, @splat(6))) << @as(Bytes32, @splat(4))),
            };
            inline for (quarters, 0..) |quants, quarter| {
                // Sixteen elements per scale: the first eight pair sums use
                // one scale, the last eight the next.
                const index = half * 8 + quarter * 2;
                const scale_pair = @Vector(2, i16){ scales[index], scales[index + 1] };
                const lane_scales: Words16 = @shuffle(i16, scale_pair, undefined, [16]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 });
                inline for (0..count) |row| {
                    const qs = &activations[row][block_index].qs;
                    integer[row] += mulAddWords(mulAddPairs(quants, qs[half * 128 + quarter * 32 ..][0..32].*), lane_scales);
                }
            }
        }
        const d = f16ToF32(readU16(block, 208));
        inline for (0..count) |row| {
            const activation = &activations[row][block_index];
            const bsums: Words16 = activation.bsums;
            const scale = d * activation.d;
            const offset: F32x8 = @floatFromInt(mulAddWords(bsums, scales));
            sums[row] += @as(F32x8, @splat(scale)) * (@as(F32x8, @floatFromInt(integer[row])) - @as(F32x8, @splat(32.0)) * offset);
        }
    }
    var result: [count]f32 = undefined;
    inline for (0..count) |row| result[row] = @reduce(.Add, sums[row]);
    return result;
}

/// Round to nearest with ties to even through the f32 mantissa, bit-exact with
/// GGML's nearest_int for the |value| <= 2^22 range quantizers produce.
inline fn nearestInt(value: f32) i32 {
    const bits: u32 = @bitCast(value + 12582912.0);
    return @as(i32, @intCast(bits & 0x007fffff)) - 0x00400000;
}

const Bytes32 = @Vector(32, u8);
const Signed32 = @Vector(32, i8);
const Words16 = @Vector(16, i16);
const I32x8 = @Vector(8, i32);
const I32x16 = @Vector(16, i32);
const F32x8 = @Vector(8, f32);

fn alternateLanes(comptime count: usize, comptime first: i32) [count]i32 {
    var result: [count]i32 = undefined;
    for (&result, 0..) |*lane, index| lane.* = first + 2 * @as(i32, @intCast(index));
    return result;
}

const even16 = alternateLanes(16, 0);
const odd16 = alternateLanes(16, 1);
const even8 = alternateLanes(8, 0);
const odd8 = alternateLanes(8, 1);

/// Unsigned x signed byte products summed in adjacent pairs: the shape LLVM
/// lowers to x86 vpmaddubsw. Callers keep pair sums below 2^15 (weights <= 63,
/// activations within +-127), so the clamp never engages.
inline fn mulAddPairs(raw_weights: Bytes32, activations: Signed32) Words16 {
    const weights = opaqueBytes(raw_weights);
    const weight_even: I32x16 = @shuffle(u8, weights, undefined, even16);
    const weight_odd: I32x16 = @shuffle(u8, weights, undefined, odd16);
    const activation_even: I32x16 = @shuffle(i8, activations, undefined, even16);
    const activation_odd: I32x16 = @shuffle(i8, activations, undefined, odd16);
    const sum = weight_even * activation_even + weight_odd * activation_odd;
    return @intCast(@min(@max(sum, @as(I32x16, @splat(-32768))), @as(I32x16, @splat(32767))));
}

const avx2 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Hide the operand's known bits. Nibble masks prove the weights small, and
/// LLVM then narrows the products to vpmullw instead of matching vpmaddubsw.
inline fn opaqueBytes(value: Bytes32) Bytes32 {
    if (!avx2) return value;
    return asm ("" : [ret] "=x" (-> Bytes32) : [value] "0" (value));
}

/// Word products summed in adjacent pairs: the shape LLVM lowers to vpmaddwd.
inline fn mulAddWords(values: Words16, scales: Words16) I32x8 {
    const product = @as(I32x16, values) * @as(I32x16, scales);
    return @as(I32x8, @shuffle(i32, product, undefined, even8)) +
        @as(I32x8, @shuffle(i32, product, undefined, odd8));
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

fn patternedBlock(comptime size: usize, seed: u32) [size]u8 {
    var block: [size]u8 = undefined;
    var state = seed;
    for (&block) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 24);
    }
    return block;
}

fn patternedInput(seed: u32) [2 * QK_K]f32 {
    var input: [2 * QK_K]f32 = undefined;
    var state = seed;
    for (&input) |*value| {
        state = state *% 1664525 +% 1013904223;
        value.* = (@as(f32, @floatFromInt(state >> 8)) / 16777216.0 - 0.5) * 3.0;
    }
    return input;
}

test "Q8_K quantization matches the GGML reference rule" {
    // A signed maximum of -127/64 makes the scale exactly 64, so 0.5 and 1.5
    // are exact ties: GGML rounds them to even (0 and 2), not away from zero.
    var input: [QK_K]f32 = @splat(0);
    input[3] = -1.984375;
    input[7] = 1.0;
    input[9] = 0.5 / 64.0;
    input[10] = 1.5 / 64.0;
    var blocks: [1]Q8KBlock = undefined;
    try quantizeQ8K(&input, &blocks);
    const qs = blocks[0].qs;
    if (qs[3] != -127 or qs[7] != 64 or qs[9] != 0 or qs[10] != 2) return error.TestUnexpectedResult;
    if (blocks[0].d != 1.0 / 64.0 or blocks[0].bsums[0] != -127 + 64 + 2) return error.TestUnexpectedResult;
}

test "Q4_K and Q6_K integer dots equal the dequantized products" {
    const input = patternedInput(7);
    var activations: [2]Q8KBlock = undefined;
    try quantizeQ8K(&input, &activations);
    var restored: [2 * QK_K]f32 = undefined;
    for (activations, 0..) |block, index| {
        for (block.qs, 0..) |quantized, lane| restored[index * QK_K + lane] = block.d * @as(f32, @floatFromInt(quantized));
    }
    var q4: [2 * Q4_K_BLOCK_BYTES]u8 = undefined;
    q4[0..Q4_K_BLOCK_BYTES].* = patternedBlock(Q4_K_BLOCK_BYTES, 11);
    q4[Q4_K_BLOCK_BYTES..].* = patternedBlock(Q4_K_BLOCK_BYTES, 12);
    for ([_]usize{ 0, Q4_K_BLOCK_BYTES }) |offset| { q4[offset + 1] &= 0x3b; q4[offset + 3] &= 0x3b; }
    var q6: [2 * Q6_K_BLOCK_BYTES]u8 = undefined;
    q6[0..Q6_K_BLOCK_BYTES].* = patternedBlock(Q6_K_BLOCK_BYTES, 13);
    q6[Q6_K_BLOCK_BYTES..].* = patternedBlock(Q6_K_BLOCK_BYTES, 14);
    for ([_]usize{ 0, Q6_K_BLOCK_BYTES }) |offset| q6[offset + 209] &= 0x3b;
    var weights: [2 * QK_K]f32 = undefined;
    inline for (.{ .{ q4[0..], dequantizeQ4K, dotQ4KQ8K }, .{ q6[0..], dequantizeQ6K, dotQ6KQ8K } }) |case| {
        try case[1](&weights, case[0]);
        var expected: f64 = 0;
        var magnitude: f64 = 0;
        for (weights, restored) |w, a| {
            expected += @as(f64, w) * a;
            magnitude += @abs(@as(f64, w) * a);
        }
        const actual = try case[2](case[0], &activations);
        if (@abs(actual - expected) > 1e-5 * magnitude) return error.TestUnexpectedResult;
    }
}

test "tiled Q8_K dots equal one row at a time" {
    var activations: [4][2]Q8KBlock = undefined;
    for (&activations, 0..) |*row, index| {
        const input = patternedInput(@intCast(20 + index));
        try quantizeQ8K(&input, row);
    }
    var q4: [2 * Q4_K_BLOCK_BYTES]u8 = undefined;
    q4[0..Q4_K_BLOCK_BYTES].* = patternedBlock(Q4_K_BLOCK_BYTES, 31);
    q4[Q4_K_BLOCK_BYTES..].* = patternedBlock(Q4_K_BLOCK_BYTES, 32);
    var q6: [2 * Q6_K_BLOCK_BYTES]u8 = undefined;
    q6[0..Q6_K_BLOCK_BYTES].* = patternedBlock(Q6_K_BLOCK_BYTES, 33);
    q6[Q6_K_BLOCK_BYTES..].* = patternedBlock(Q6_K_BLOCK_BYTES, 34);
    for ([_]usize{ 0, Q4_K_BLOCK_BYTES }) |offset| { q4[offset + 1] &= 0x3b; q4[offset + 3] &= 0x3b; }
    for ([_]usize{ 0, Q6_K_BLOCK_BYTES }) |offset| q6[offset + 209] &= 0x3b;
    const pointers = [4][*]const Q8KBlock{ &activations[0], &activations[1], &activations[2], &activations[3] };
    const q4_tile = dotQ4KQ8KTile(4, &q4, pointers, 2);
    const q6_tile = dotQ6KQ8KTile(4, &q6, pointers, 2);
    for (0..4) |row| {
        if (q4_tile[row] != try dotQ4KQ8K(&q4, &activations[row])) return error.TestUnexpectedResult;
        if (q6_tile[row] != try dotQ6KQ8K(&q6, &activations[row])) return error.TestUnexpectedResult;
    }
}

test "Q4_K dot product smoke" {
    // Minimal: verify the function signature compiles and accepts valid dims
    var block: [Q4_K_BLOCK_BYTES]u8 = @splat(0);
    var input: [QK_K]f32 = @splat(0);
    const result = try dotQ4K(&block, &input);
    if (result != 0) return error.TestUnexpectedResult; // zero weights * zero input = 0
}

