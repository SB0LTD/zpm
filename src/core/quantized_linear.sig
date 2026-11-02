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
pub const QK8_0: usize = 32;
pub const Q8_0_BLOCK_BYTES: usize = 34;

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

/// GGML Q8_0 activation block, the vec_dot_type of Q8_0 weights: the scale
/// is kept as the f32 value of its f16 rounding, so dots multiply what GGML
/// multiplies without converting per row.
pub const Q80Block = struct {
    d: f32 = 0,
    qs: [QK8_0]i8 = @splat(0),
};

/// Quantize complete 32-lane blocks as GGML's x86 quantize_row_q8_0 does:
/// d = amax / 127 rounded to f16, values multiplied by 127 / amax and rounded
/// to nearest, ties to even. (GGML's NEON path multiplies by 1 / d instead,
/// which can move a tie; the x86 rule is the parity reference.)
pub fn quantizeQ80(input: []const f32, output: []Q80Block) Error!void {
    if (input.len == 0 or input.len % QK8_0 != 0) return error.InvalidDimensions;
    if (output.len < input.len / QK8_0) return error.BufferTooSmall;
    for (output[0 .. input.len / QK8_0], 0..) |*block, block_index| {
        const source: @Vector(QK8_0, f32) = input[block_index * QK8_0 ..][0..QK8_0].*;
        const magnitude = @reduce(.Max, @abs(source));
        block.d = @floatCast(@as(f16, @floatCast(magnitude / 127.0)));
        const inverse: f32 = if (magnitude != 0) 127.0 / magnitude else 0;
        const scaled: [QK8_0]f32 = source * @as(@Vector(QK8_0, f32), @splat(inverse));
        for (&block.qs, 0..) |*quantized, lane| quantized.* = @intCast(@max(-127, @min(127, nearestInt(scaled[lane]))));
    }
}

/// Q8_0 weight row x Q8_0 activations, GGML's x86 ggml_vec_dot_q8_0_q8_0.
pub fn dotQ80Q80(weight_bytes: []const u8, activations: []const Q80Block) Error!f32 {
    if (activations.len == 0) return error.InvalidDimensions;
    if (weight_bytes.len < activations.len * Q8_0_BLOCK_BYTES) return error.BufferTooSmall;
    return dotQ80Q80Tile(1, weight_bytes, .{activations.ptr}, activations.len)[0];
}

/// One Q8_0 weight row against up to MAX_TILE activation rows. Per block the
/// eight four-product lane sums are scaled by d_w * d_x and fused into eight
/// f32 accumulators, then reduced pairwise (hi + lo, then even + odd) as
/// GGML's AVX2 kernel and llamafile's tinyBLAS do: x86 results are bit-equal.
pub fn dotQ80Q80Tile(comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q80Block, blocks: usize) [count]f32 {
    var sums: [count]F32x8 = @splat(@splat(0));
    for (0..blocks) |block_index| {
        const block = weight_bytes[block_index * Q8_0_BLOCK_BYTES ..][0..Q8_0_BLOCK_BYTES];
        const d = halfAt(block, 0);
        const quants: Signed32 = @bitCast(block[2..34].*);
        // |w| as unsigned bytes with w's sign moved onto the activations is
        // the operand shape of vpdpbusd and vpmaddubsw (Q8_0 never holds -128).
        const magnitude: Bytes32 = @bitCast(@abs(quants));
        const negative = quants < @as(Signed32, @splat(0));
        inline for (0..count) |row| {
            const activation = &activations[row][block_index];
            const values: Signed32 = activation.qs;
            const signed = @select(i8, negative, -%values, values);
            const integer = quadSums(magnitude, signed);
            sums[row] = @mulAdd(F32x8, @splat(d * activation.d), @floatFromInt(integer), sums[row]);
        }
    }
    var result: [count]f32 = undefined;
    inline for (0..count) |row| result[row] = reduceLikeAvx(sums[row]);
    return result;
}

/// The four-product lane sums of unsigned x signed bytes: vpdpbusd with
/// AVX-VNNI, sdot on AArch64 (operands stay below 128, so the signed reading
/// of `weights` is the same), vpmaddubsw + vpmaddwd otherwise.
inline fn quadSums(weights: Bytes32, activations: Signed32) I32x8 {
    if (quad_dots) return dotQuads(@splat(0), weights, activations);
    return mulAddWords(mulAddPairs(weights, activations), @splat(1));
}

/// _mm256_extractf128 + _mm_add_ps, then movehl + add, then movehdup + add_ss.
inline fn reduceLikeAvx(lanes: F32x8) f32 {
    const quarter = @shuffle(f32, lanes, undefined, [4]i32{ 4, 5, 6, 7 }) + @shuffle(f32, lanes, undefined, [4]i32{ 0, 1, 2, 3 });
    const half = @shuffle(f32, quarter, undefined, [2]i32{ 0, 1 }) + @shuffle(f32, quarter, undefined, [2]i32{ 2, 3 });
    return half[0] + half[1];
}

/// Rows of a Q8_0 matrix as f32 (ggml_get_rows of a Q8_0 table).
pub fn dequantizeQ80(output: []f32, weight_bytes: []const u8) Error!void {
    if (output.len % QK8_0 != 0) return error.InvalidDimensions;
    if (weight_bytes.len < output.len / QK8_0 * Q8_0_BLOCK_BYTES) return error.BufferTooSmall;
    for (0..output.len / QK8_0) |block_index| {
        const block = weight_bytes[block_index * Q8_0_BLOCK_BYTES ..][0..Q8_0_BLOCK_BYTES];
        const d = halfAt(block, 0);
        for (output[block_index * QK8_0 ..][0..QK8_0], block[2..34]) |*value, quant| value.* = d * @as(f32, @floatFromInt(@as(i8, @bitCast(quant))));
    }
}

/// One weight row against up to MAX_TILE activation rows of `blocks` blocks:
/// each weight block is unpacked once and reused, which is what makes batched
/// prefill cheaper per token than decode. Callers guarantee that the weight
/// row and every activation row hold `blocks` complete blocks.
pub fn dotQ4KQ8KTile(comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count]f32 {
    return dotQ4KQ8KTileWith(neon_dotprod, count, weight_bytes, activations, blocks);
}

/// `quads` selects dotQuads (AArch64 sdot) for the sub-block dots; x86 keeps
/// its vpmaddubsw row kernels. Both produce the same integers and floats.
fn dotQ4KQ8KTileWith(comptime quads: bool, comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count]f32 {
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
            if (quads) {
                // Lane l of a dotQuads sum covers the same four elements as
                // lane l of mulAddWords(mulAddPairs(..)): equal integers.
                const low_scale: I32x8 = @splat(scales[pair * 2]);
                const high_scale: I32x8 = @splat(scales[pair * 2 + 1]);
                inline for (0..count) |row| {
                    const qs = &activations[row][block_index].qs;
                    integer[row] += dotQuads(@splat(0), low, qs[pair * 64 ..][0..32].*) * low_scale +
                        dotQuads(@splat(0), high, qs[pair * 64 + 32 ..][0..32].*) * high_scale;
                }
            } else {
                const low_scale: Words16 = @splat(scales[pair * 2]);
                const high_scale: Words16 = @splat(scales[pair * 2 + 1]);
                inline for (0..count) |row| {
                    const qs = &activations[row][block_index].qs;
                    integer[row] += mulAddWords(mulAddPairs(low, qs[pair * 64 ..][0..32].*), low_scale) +
                        mulAddWords(mulAddPairs(high, qs[pair * 64 + 32 ..][0..32].*), high_scale);
                }
            }
        }
        // Each minimum covers two 16-lane bsums.
        const min_pairs: Words16 = @shuffle(i16, mins, undefined, [16]i32{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 });
        const d = halfAt(block, 0);
        const dmin = halfAt(block, 2);
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
    return dotQ6KQ8KTileWith(neon_dotprod, count, weight_bytes, activations, blocks);
}

fn dotQ6KQ8KTileWith(comptime quads: bool, comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count]f32 {
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
                if (quads) {
                    const lane_scales: I32x8 = @shuffle(i16, scale_pair, undefined, [8]i32{ 0, 0, 0, 0, 1, 1, 1, 1 });
                    inline for (0..count) |row| {
                        const qs = &activations[row][block_index].qs;
                        integer[row] += dotQuads(@splat(0), quants, qs[half * 128 + quarter * 32 ..][0..32].*) * lane_scales;
                    }
                } else {
                    const lane_scales: Words16 = @shuffle(i16, scale_pair, undefined, [16]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 });
                    inline for (0..count) |row| {
                        const qs = &activations[row][block_index].qs;
                        integer[row] += mulAddWords(mulAddPairs(quants, qs[half * 128 + quarter * 32 ..][0..32].*), lane_scales);
                    }
                }
            }
        }
        const d = halfAt(block, 208);
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

/// Rows interleaved by the packed layouts below. Prefill multiplies every
/// weight block by many tokens, so packing eight rows per block lets one
/// activation broadcast, one scale unpack and one float epilogue serve eight
/// outputs, and the eight results land in one vector with no horizontal sum.
pub const PACKED_ROWS: usize = 8;
/// Eight interleaved Q4_K blocks, the same 1152 bytes as the canonical eight:
///
///   d, dmin:  8 + 8 f16, one per row
///   scales:   the 6-bit scale and minimum of value v = sub * 8 + row: 64
///             bytes of low nibbles (scale | min << 4), then 32 bytes whose
///             byte j holds the top two bits of scale j, scale j + 32, min j
///             and min j + 32, lowest first
///   quants:   [pair 4][group 8][row 8][4 bytes]: the canonical bytes
///             qs[32 * pair + 4 * group ..][0..4] of each row, so one 32-byte
///             load holds four consecutive elements of sub-block 2 * pair (low
///             nibbles) and of sub-block 2 * pair + 1 (high nibbles) per row.
pub const Q4_K_X8_BLOCK_BYTES: usize = PACKED_ROWS * Q4_K_BLOCK_BYTES;

/// Interleave eight consecutive canonical Q4_K rows of `blocks` blocks into
/// `blocks` packed blocks. `output` must not alias `rows`.
pub fn packQ4KX8(output: []u8, rows: []const u8, blocks: usize) Error!void {
    if (blocks == 0) return error.InvalidDimensions;
    const row_bytes = blocks * Q4_K_BLOCK_BYTES;
    if (rows.len < PACKED_ROWS * row_bytes or output.len < PACKED_ROWS * row_bytes) return error.BufferTooSmall;
    for (0..blocks) |block_index| {
        const destination = output[block_index * Q4_K_X8_BLOCK_BYTES ..][0..Q4_K_X8_BLOCK_BYTES];
        var scales: [64]u8 = undefined;
        var minimums: [64]u8 = undefined;
        for (0..PACKED_ROWS) |row| {
            const block = rows[row * row_bytes + block_index * Q4_K_BLOCK_BYTES ..][0..Q4_K_BLOCK_BYTES];
            destination[row * 2 ..][0..2].* = block[0..2].*;
            destination[16 + row * 2 ..][0..2].* = block[2..4].*;
            for (0..8) |sub| {
                const pair = scaleMinQ4K(sub, block[4..16]);
                scales[sub * 8 + row] = pair.scale;
                minimums[sub * 8 + row] = pair.minimum;
            }
            for (0..4) |pair| for (0..8) |group| {
                destination[128 + ((pair * 8 + group) * 8 + row) * 4 ..][0..4].* = block[16 + pair * 32 + group * 4 ..][0..4].*;
            };
        }
        for (0..64) |value| destination[32 + value] = (scales[value] & 0x0f) | ((minimums[value] & 0x0f) << 4);
        for (0..32) |value| destination[96 + value] = (scales[value] >> 4) | ((scales[value + 32] >> 4) << 2) |
            ((minimums[value] >> 4) << 4) | ((minimums[value + 32] >> 4) << 6);
    }
}

/// Eight packed Q4_K rows against up to MAX_TILE activation rows of `blocks`
/// blocks; result[token][row]. Per row and token this is exactly
/// dotQ4KQ8K's integer arithmetic, summed in a different float order.
pub fn dotQ4KX8Q8KTile(comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count][PACKED_ROWS]f32 {
    return dotQ4KX8Q8KTileWith(quad_dots, count, weight_bytes, activations, blocks);
}

/// `quads` selects dotQuads sub-block dots (vpdpbusd, sdot) scaled with an
/// i32 multiply instead of vpmaddubsw pairs summed in i16; both produce the
/// same integers.
fn dotQ4KX8Q8KTileWith(comptime quads: bool, comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count][PACKED_ROWS]f32 {
    const nibble: Bytes32 = @splat(0x0f);
    var sums: [count]F32x8 = @splat(@splat(0));
    for (0..blocks) |block_index| {
        const block = weight_bytes[block_index * Q4_K_X8_BLOCK_BYTES ..][0..Q4_K_X8_BLOCK_BYTES];
        prefetchAhead(weight_bytes, block_index, Q4_K_X8_BLOCK_BYTES);
        const unpacked = unpackScalesQ4KX8(block[32..128], quads);
        var integer: [count]I32x8 = @splat(@splat(0));
        for (0..4) |pair| {
            if (quads) {
                // Both halves at once: up to eight independent dot chains.
                var halves: [2][count]I32x8 = @splat(@splat(@splat(0)));
                inline for (0..8) |group| {
                    const raw: Bytes32 = block[128 + (pair * 8 + group) * 32 ..][0..32].*;
                    const quants = [2]Bytes32{ raw & nibble, raw >> @as(Bytes32, @splat(4)) };
                    inline for (0..count) |row| inline for (0..2) |half| {
                        const lanes = broadcastQuad(&activations[row][block_index].qs, pair * 64 + half * 32 + group * 4);
                        halves[half][row] = dotQuads(halves[half][row], quants[half], lanes);
                    };
                }
                inline for (0..count) |row| integer[row] += halves[0][row] * unpacked.lanes[pair * 2] +
                    halves[1][row] * unpacked.lanes[pair * 2 + 1];
            } else inline for (0..2) |half| {
                // Eight four-lane groups of 32 elements: lane pairs stay below
                // 8 * 2 * 15 * 127 = 30480, so i16 sums cannot wrap.
                var partial: [count]Words16 = @splat(@splat(0));
                inline for (0..8) |group| {
                    const raw: Bytes32 = block[128 + (pair * 8 + group) * 32 ..][0..32].*;
                    const quants = opaqueBytes(if (half == 0) raw & nibble else raw >> @as(Bytes32, @splat(4)));
                    inline for (0..count) |row| {
                        const lanes = broadcastQuad(&activations[row][block_index].qs, pair * 64 + half * 32 + group * 4);
                        partial[row] +%= mulAddPairsOpaque(quants, lanes);
                    }
                }
                const scales = unpacked.scales[pair * 2 + half];
                inline for (0..count) |row| integer[row] += mulAddWords(partial[row], scales);
            }
        }
        const d = halvesX8(block[0..16]);
        const dmin = halvesX8(block[16..32]);
        inline for (0..count) |row| {
            const activation = &activations[row][block_index];
            const scale: F32x8 = @splat(activation.d);
            const minimum: F32x8 = @floatFromInt(minimumsQ4KX8(activation.bsums, unpacked.minimums));
            sums[row] += d * scale * @as(F32x8, @floatFromInt(integer[row])) - dmin * scale * minimum;
        }
    }
    var result: [count][PACKED_ROWS]f32 = undefined;
    inline for (0..count) |row| result[row] = sums[row];
    return result;
}

/// Eight interleaved Q6_K blocks, the same 1680 bytes as the canonical eight,
/// laid out in the order the kernel reads them. Quants are unsigned (0..63),
/// split into nibbles and two-bit tops; "group" g is elements 4g..4g+3 and
/// sub-block u is groups 4u..4u+3:
///
///   scales: [u 16][row 8] i8
///   quants: [u 16] of 96 bytes: two [row 8][4 bytes] nibble vectors, the
///           first holding groups 4u (low nibbles) and 4u + 1 (high), the
///           second 4u + 2 and 4u + 3, then one [row 8][4 bytes] vector whose
///           bits 2j..2j+1 are the tops of group 4u + j
///   d:      8 f16, one per row
pub const Q6_K_X8_BLOCK_BYTES: usize = PACKED_ROWS * Q6_K_BLOCK_BYTES;

/// Interleave eight consecutive canonical Q6_K rows of `blocks` blocks into
/// `blocks` packed blocks. `output` must not alias `rows`.
pub fn packQ6KX8(output: []u8, rows: []const u8, blocks: usize) Error!void {
    if (blocks == 0) return error.InvalidDimensions;
    const row_bytes = blocks * Q6_K_BLOCK_BYTES;
    if (rows.len < PACKED_ROWS * row_bytes or output.len < PACKED_ROWS * row_bytes) return error.BufferTooSmall;
    for (0..blocks) |block_index| {
        const destination = output[block_index * Q6_K_X8_BLOCK_BYTES ..][0..Q6_K_X8_BLOCK_BYTES];
        for (0..PACKED_ROWS) |row| {
            const block = rows[row * row_bytes + block_index * Q6_K_BLOCK_BYTES ..][0..Q6_K_BLOCK_BYTES];
            for (0..16) |sub| {
                for (0..4) |lane| {
                    var high: u8 = 0;
                    for (0..4) |j| high |= (quantQ6K(block, (sub * 4 + j) * 4 + lane) >> 4) << @intCast(2 * j);
                    destination[128 + sub * 96 + 64 + row * 4 + lane] = high;
                    for (0..2) |half| {
                        const group = sub * 4 + half * 2;
                        destination[128 + sub * 96 + half * 32 + row * 4 + lane] = (quantQ6K(block, group * 4 + lane) & 0x0f) |
                            ((quantQ6K(block, (group + 1) * 4 + lane) & 0x0f) << 4);
                    }
                }
                destination[sub * 8 + row] = block[192 + sub];
            }
            destination[1664 + row * 2 ..][0..2].* = block[208..210].*;
        }
    }
}

/// Unsigned quant (0..63) of element `element` of a canonical Q6_K block.
fn quantQ6K(block: *const [Q6_K_BLOCK_BYTES]u8, element: usize) u8 {
    const half = element / 128;
    const quarter = (element % 128) / 32;
    const lane = element % 32;
    const low = block[half * 64 + (quarter % 2) * 32 + lane];
    const nibble = if (quarter < 2) low & 0x0f else low >> 4;
    return nibble | (((block[128 + half * 32 + lane] >> @intCast(2 * quarter)) & 3) << 4);
}

/// Eight packed Q6_K rows against up to MAX_TILE activation rows of `blocks`
/// blocks; result[token][row]. Per row and token this is exactly
/// dotQ6KQ8K's integer arithmetic, summed in a different float order.
pub fn dotQ6KX8Q8KTile(comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count][PACKED_ROWS]f32 {
    return dotQ6KX8Q8KTileWith(quad_dots, count, weight_bytes, activations, blocks);
}

/// `quads` selects dotQuads sub-block dots (vpdpbusd, sdot) scaled with an
/// i32 multiply instead of vpmaddubsw pairs summed in i16; both produce the
/// same integers.
fn dotQ6KX8Q8KTileWith(comptime quads: bool, comptime count: usize, weight_bytes: []const u8, activations: [count][*]const Q8KBlock, blocks: usize) [count][PACKED_ROWS]f32 {
    const nibble: Bytes32 = @splat(0x0f);
    const top: Bytes32 = @splat(0x30);
    var sums: [count]F32x8 = @splat(@splat(0));
    for (0..blocks) |block_index| {
        const block = weight_bytes[block_index * Q6_K_X8_BLOCK_BYTES ..][0..Q6_K_X8_BLOCK_BYTES];
        prefetchAhead(weight_bytes, block_index, Q6_K_X8_BLOCK_BYTES);
        const scale_bytes = [4]@Vector(32, i8){
            @bitCast(block[0..32].*),  @bitCast(block[32..64].*),
            @bitCast(block[64..96].*), @bitCast(block[96..128].*),
        };
        var integer: [count]I32x8 = @splat(@splat(0));
        for (0..4) |quad| {
            inline for (0..4) |offset| {
                const sub = quad * 4 + offset;
                const low: Bytes32 = block[128 + sub * 96 ..][0..32].*;
                const next: Bytes32 = block[128 + sub * 96 + 32 ..][0..32].*;
                const high: Bytes32 = block[128 + sub * 96 + 64 ..][0..32].*;
                const raw = [4]Bytes32{
                    (low & nibble) | ((high << @as(Bytes32, @splat(4))) & top),
                    (low >> @as(Bytes32, @splat(4))) | ((high << @as(Bytes32, @splat(2))) & top),
                    (next & nibble) | (high & top),
                    (next >> @as(Bytes32, @splat(4))) | ((high >> @as(Bytes32, @splat(2))) & top),
                };
                if (quads) {
                    const scales: I32x8 = @shuffle(i8, scale_bytes[quad], undefined, lanesFrom(offset * 8));
                    inline for (0..count) |row| {
                        const qs = &activations[row][block_index].qs;
                        var dot: I32x8 = @splat(0);
                        inline for (0..4) |group| dot = dotQuads(dot, raw[group], broadcastQuad(qs, sub * 16 + group * 4));
                        integer[row] += dot * scales;
                    }
                } else {
                    const scales = opaqueWords(widenSignedPairs(scale_bytes[quad], offset * 8, offset * 8));
                    var quants: [4]Bytes32 = undefined;
                    inline for (0..4) |group| quants[group] = opaqueBytes(raw[group]);
                    inline for (0..count) |row| {
                        const qs = &activations[row][block_index].qs;
                        // Two four-lane groups per i16 sum: 4 * 63 * 127 = 32004.
                        inline for (0..2) |pair| {
                            const partial = mulAddPairsOpaque(quants[pair * 2], broadcastQuad(qs, sub * 16 + pair * 8)) +%
                                mulAddPairsOpaque(quants[pair * 2 + 1], broadcastQuad(qs, sub * 16 + pair * 8 + 4));
                            integer[row] += mulAddWords(partial, scales);
                        }
                    }
                }
            }
        }
        // Per row: sum over sub-blocks of scale * (sum of its 16 activations),
        // the quants' -32 offset.
        var pairs: [8]Words16 = undefined;
        inline for (0..8) |k| pairs[k] = opaqueWords(widenSignedPairs(scale_bytes[k / 2], (k % 2) * 16, (k % 2) * 16 + 8));
        const d = halvesX8(block[1664..1680]);
        inline for (0..count) |row| {
            const activation = &activations[row][block_index];
            const bsums: @Vector(8, u32) = @bitCast(@as(Words16, activation.bsums));
            var offset: I32x8 = @splat(0);
            inline for (0..8) |k| offset += mulAddWords(pairs[k], @bitCast(@as(@Vector(8, u32), @splat(bsums[k]))));
            const scale: F32x8 = @splat(activation.d);
            sums[row] += d * scale * (@as(F32x8, @floatFromInt(integer[row])) - @as(F32x8, @splat(32.0)) * @as(F32x8, @floatFromInt(offset)));
        }
    }
    var result: [count][PACKED_ROWS]f32 = undefined;
    inline for (0..count) |row| result[row] = sums[row];
    return result;
}

/// Decode streams packed weights faster than the hardware prefetcher ramps
/// up under shared memory bandwidth: request the block two ahead. Prefetches
/// never fault, so the last blocks of a row may point past it.
inline fn prefetchAhead(weight_bytes: []const u8, block_index: usize, comptime block_bytes: usize) void {
    const ahead = weight_bytes.ptr + (block_index + 2) * block_bytes;
    inline for (0..(block_bytes + 63) / 64) |line| @prefetch(ahead + line * 64, .{});
}

/// Shuffle mask selecting eight consecutive lanes from `first`.
fn lanesFrom(first: usize) [8]i32 {
    var mask: [8]i32 = undefined;
    for (&mask, 0..) |*lane, row| lane.* = @intCast(first + row);
    return mask;
}

/// widenPairs for signed bytes: word lanes 2 * row and 2 * row + 1 take
/// bytes `even + row` and `odd + row`, sign-extended.
inline fn widenSignedPairs(bytes: @Vector(32, i8), comptime even: usize, comptime odd: usize) Words16 {
    comptime var mask: [16]i32 = undefined;
    inline for (0..8) |row| {
        mask[row * 2] = even + row;
        mask[row * 2 + 1] = odd + row;
    }
    return @shuffle(i8, bytes, undefined, mask);
}

/// Only the scale form of the selected path (`scales` or `lanes`) is set.
const ScalesQ4KX8 = struct {
    /// Per sub-block: word lanes 2 * row and 2 * row + 1 both hold the scale.
    scales: [8]Words16,
    /// Per sub-block, for the dotQuads path: lane `row` holds the scale.
    lanes: [8]I32x8,
    /// Per sub-block pair q: word lanes 2 * row and 2 * row + 1 hold the
    /// minimums of sub-blocks 2 * q and 2 * q + 1.
    minimums: [4]Words16,
};

inline fn unpackScalesQ4KX8(packed_scales: *const [96]u8, comptime quads: bool) ScalesQ4KX8 {
    const nibble: Bytes32 = @splat(0x0f);
    const top_mask: Bytes32 = @splat(0x30);
    const low = [2]Bytes32{ packed_scales[0..32].*, packed_scales[32..64].* };
    const top: Bytes32 = packed_scales[64..96].*;
    // Values sub * 8 + row: [0] holds sub-blocks 0-3, [1] sub-blocks 4-7.
    const scales = [2]Bytes32{
        (low[0] & nibble) | ((top << @as(Bytes32, @splat(4))) & top_mask),
        (low[1] & nibble) | ((top << @as(Bytes32, @splat(2))) & top_mask),
    };
    const minimums = [2]Bytes32{
        (low[0] >> @as(Bytes32, @splat(4))) | (top & top_mask),
        (low[1] >> @as(Bytes32, @splat(4))) | ((top >> @as(Bytes32, @splat(2))) & top_mask),
    };
    var result: ScalesQ4KX8 = undefined;
    inline for (0..8) |sub| {
        if (quads) {
            result.lanes[sub] = widenLanes(scales[sub / 4], (sub % 4) * 8);
        } else {
            result.scales[sub] = opaqueWords(widenPairs(scales[sub / 4], (sub % 4) * 8, (sub % 4) * 8));
        }
    }
    inline for (0..4) |q| result.minimums[q] = opaqueWords(widenPairs(minimums[q / 2], (q % 2) * 16, (q % 2) * 16 + 8));
    return result;
}

/// Word lanes 2 * row and 2 * row + 1 take bytes `even + row` and `odd + row`
/// of `bytes`, zero-extended.
inline fn widenPairs(bytes: Bytes32, comptime even: usize, comptime odd: usize) Words16 {
    comptime var mask: [32]i32 = undefined;
    inline for (0..8) |row| {
        mask[row * 4] = even + row;
        mask[row * 4 + 1] = -1;
        mask[row * 4 + 2] = odd + row;
        mask[row * 4 + 3] = -1;
    }
    return @bitCast(@shuffle(u8, bytes, @as(Bytes32, @splat(0)), mask));
}

/// Lane `row` takes byte `first + row` of `bytes`, zero-extended.
inline fn widenLanes(bytes: Bytes32, comptime first: usize) I32x8 {
    comptime var mask: [32]i32 = @splat(-1);
    inline for (0..8) |row| mask[row * 4] = first + row;
    return @bitCast(@shuffle(u8, bytes, @as(Bytes32, @splat(0)), mask));
}

/// Per row: sum over sub-blocks of minimum * (sum of its 32 activations).
inline fn minimumsQ4KX8(bsums: [QK_K / 16]i16, minimums: [4]Words16) I32x8 {
    const sums: Words16 = bsums;
    const pairs: @Vector(8, i16) = @shuffle(i16, sums, undefined, even8) + @shuffle(i16, sums, undefined, odd8);
    const words: @Vector(4, u32) = @bitCast(pairs);
    var total: I32x8 = @splat(0);
    inline for (0..4) |q| total += mulAddWords(minimums[q], @bitCast(@as(@Vector(8, u32), @splat(words[q]))));
    return total;
}

/// Four activation bytes at `offset` repeated in every 32-bit lane.
inline fn broadcastQuad(qs: *const [QK_K]i8, offset: usize) Signed32 {
    const bytes: [4]u8 = @bitCast(qs[offset..][0..4].*);
    const word = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
    return @bitCast(@as(@Vector(8, u32), @splat(word)));
}

/// Eight little-endian f16 values through the target's conversion.
inline fn halvesX8(bytes: *const [16]u8) F32x8 {
    const halves: @Vector(8, f16) = @bitCast(@as(@Vector(16, u8), bytes.*));
    return @floatCast(halves);
}

/// Little-endian f16 at `offset` through the target's conversion (F16C on
/// x86, a compiler-rt routine elsewhere): exact, including subnormals.
inline fn halfAt(bytes: []const u8, offset: usize) f32 {
    return @floatCast(@as(f16, @bitCast(readU16(bytes, offset))));
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
    return mulAddPairsOpaque(opaqueBytes(raw_weights), activations);
}

/// mulAddPairs for weights already passed through opaqueBytes, so a vector
/// reused across tokens crosses the barrier once.
inline fn mulAddPairsOpaque(weights: Bytes32, activations: Signed32) Words16 {
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

/// opaqueBytes for word operands: zero-extended byte scales would otherwise
/// turn vpmaddwd into widening vpmulld.
inline fn opaqueWords(value: Words16) Words16 {
    if (!avx2) return value;
    return asm ("" : [ret] "=x" (-> Words16) : [value] "0" (value));
}

/// (LLVM's assembler only: the self-hosted x86 backend, which debug builds
/// on x86-64 Linux use, rejects the {vex} prefix; they take the vpmaddubsw
/// path, which gives the same sums)
const avx_vnni = avx2 and std.Target.x86.featureSetHas(builtin.cpu.features, .avxvnni) and builtin.zig_backend == .stage2_llvm;
const neon_dotprod = builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .dotprod);
/// One instruction per four-byte dot: AVX-VNNI vpdpbusd or AArch64 sdot.
const quad_dots = avx_vnni or neon_dotprod;

/// Each i32 lane adds the four products of its weight and activation bytes,
/// without the i16 saturation of vpmaddubsw. Weights are at most 63, so
/// sdot's signed weight bytes hold them unchanged.
inline fn dotQuads(accumulator: I32x8, weights: Bytes32, activations: Signed32) I32x8 {
    if (neon_dotprod) {
        const low = [4]i32{ 0, 1, 2, 3 };
        const high = [4]i32{ 4, 5, 6, 7 };
        const bytes_low = [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        const bytes_high = [16]i32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
        const signed: Signed32 = @bitCast(weights);
        return @shuffle(i32, dotQuadsNeon(@shuffle(i32, accumulator, undefined, low), @shuffle(i8, signed, undefined, bytes_low), @shuffle(i8, activations, undefined, bytes_low)),
            dotQuadsNeon(@shuffle(i32, accumulator, undefined, high), @shuffle(i8, signed, undefined, bytes_high), @shuffle(i8, activations, undefined, bytes_high)),
            [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 });
    }
    return asm ("{vex} vpdpbusd %[activations], %[weights], %[accumulator]"
        : [accumulator] "=x" (-> I32x8),
        : [weights] "x" (weights),
          [activations] "x" (activations),
          [input] "0" (accumulator),
    );
}

inline fn dotQuadsNeon(accumulator: @Vector(4, i32), weights: @Vector(16, i8), activations: @Vector(16, i8)) @Vector(4, i32) {
    return asm ("sdot %[accumulator].4s, %[weights].16b, %[activations].16b"
        : [accumulator] "=w" (-> @Vector(4, i32)),
        : [weights] "w" (weights),
          [activations] "w" (activations),
          [input] "0" (accumulator),
    );
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
    if (quad_dots) {
        // The dotQuads row kernels equal the portable ones bit for bit.
        const q4_quads = dotQ4KQ8KTileWith(true, 4, &q4, pointers, 2);
        const q6_quads = dotQ6KQ8KTileWith(true, 4, &q6, pointers, 2);
        const q4_portable = dotQ4KQ8KTileWith(false, 4, &q4, pointers, 2);
        const q6_portable = dotQ6KQ8KTileWith(false, 4, &q6, pointers, 2);
        for (0..4) |row| {
            if (q4_quads[row] != q4_portable[row] or q6_quads[row] != q6_portable[row]) return error.TestUnexpectedResult;
        }
    }
}

fn patternedActivations(comptime tokens: usize, seed: u32) ![tokens][2]Q8KBlock {
    var activations: [tokens][2]Q8KBlock = undefined;
    for (&activations, 0..) |*row, index| {
        const input = patternedInput(seed + @as(u32, @intCast(index)));
        try quantizeQ8K(&input, row);
    }
    return activations;
}

/// Eight rows of two patterned blocks each, with finite f16 scales.
fn patternedRows(comptime block_bytes: usize, seed: u32, comptime scale_offsets: []const usize) [PACKED_ROWS * 2 * block_bytes]u8 {
    var rows: [PACKED_ROWS * 2 * block_bytes]u8 = undefined;
    for (0..PACKED_ROWS * 2) |block| {
        rows[block * block_bytes ..][0..block_bytes].* = patternedBlock(block_bytes, seed + @as(u32, @intCast(block)));
        inline for (scale_offsets) |offset| rows[block * block_bytes + offset + 1] &= 0x3b;
    }
    return rows;
}

/// `actual` is within f32 summation error of the f64 product of the
/// dequantized row and the Q8_K-restored activations.
fn expectReferenceDot(comptime dequantize: anytype, row: []const u8, activations: *const [2]Q8KBlock, actual: f32) !void {
    var weights: [2 * QK_K]f32 = undefined;
    try dequantize(&weights, row);
    var expected: f64 = 0;
    var magnitude: f64 = 0;
    for (weights, 0..) |weight, element| {
        const block = &activations[element / QK_K];
        const product = @as(f64, weight) * block.d * @as(f64, @floatFromInt(block.qs[element % QK_K]));
        expected += product;
        magnitude += @abs(product);
    }
    if (@abs(actual - expected) > 1e-5 * magnitude) return error.TestUnexpectedResult;
}

test "packed Q4_K x8 tiles equal the row kernels" {
    const activations = try patternedActivations(4, 40);
    const rows = patternedRows(Q4_K_BLOCK_BYTES, 50, &.{ 0, 2 });
    var packed_rows: [rows.len]u8 = undefined;
    try packQ4KX8(&packed_rows, &rows, 2);
    const pointers = [4][*]const Q8KBlock{ &activations[0], &activations[1], &activations[2], &activations[3] };
    const tile = dotQ4KX8Q8KTile(4, &packed_rows, pointers, 2);
    for (0..4) |token| {
        // Fewer tokens per call change nothing for a given token.
        const single = dotQ4KX8Q8KTile(1, &packed_rows, .{pointers[token]}, 2);
        for (0..PACKED_ROWS) |row| {
            if (single[0][row] != tile[token][row]) return error.TestUnexpectedResult;
            try expectReferenceDot(dequantizeQ4K, rows[row * 2 * Q4_K_BLOCK_BYTES ..][0 .. 2 * Q4_K_BLOCK_BYTES], &activations[token], tile[token][row]);
        }
    }
    if (quad_dots) {
        const portable = dotQ4KX8Q8KTileWith(false, 4, &packed_rows, pointers, 2);
        for (0..4) |token| for (0..PACKED_ROWS) |row| {
            if (portable[token][row] != tile[token][row]) return error.TestUnexpectedResult;
        };
    }
    try std.testing.expectError(error.BufferTooSmall, packQ4KX8(packed_rows[0 .. rows.len - 1], &rows, 2));
}

test "packed Q6_K x8 tiles equal the row kernels" {
    const activations = try patternedActivations(4, 60);
    const rows = patternedRows(Q6_K_BLOCK_BYTES, 70, &.{208});
    var packed_rows: [rows.len]u8 = undefined;
    try packQ6KX8(&packed_rows, &rows, 2);
    const pointers = [4][*]const Q8KBlock{ &activations[0], &activations[1], &activations[2], &activations[3] };
    const tile = dotQ6KX8Q8KTile(4, &packed_rows, pointers, 2);
    for (0..4) |token| {
        const single = dotQ6KX8Q8KTile(1, &packed_rows, .{pointers[token]}, 2);
        for (0..PACKED_ROWS) |row| {
            if (single[0][row] != tile[token][row]) return error.TestUnexpectedResult;
            try expectReferenceDot(dequantizeQ6K, rows[row * 2 * Q6_K_BLOCK_BYTES ..][0 .. 2 * Q6_K_BLOCK_BYTES], &activations[token], tile[token][row]);
        }
    }
    // Every packed quant decodes back to its canonical value.
    for (0..PACKED_ROWS) |row| {
        const block = rows[row * 2 * Q6_K_BLOCK_BYTES ..][0..Q6_K_BLOCK_BYTES];
        var weights: [QK_K]f32 = undefined;
        try dequantizeQ6K(&weights, block);
        const d = halfAt(block, 208);
        for (0..QK_K) |element| {
            const group = element / 4;
            const sub = group / 4;
            const low = packed_rows[128 + sub * 96 + ((group % 4) / 2) * 32 + row * 4 + element % 4];
            const nibble = if (group % 2 == 0) low & 0x0f else low >> 4;
            const high = (packed_rows[128 + sub * 96 + 64 + row * 4 + element % 4] >> @intCast(2 * (group % 4))) & 3;
            const scale: f32 = @floatFromInt(@as(i8, @bitCast(packed_rows[sub * 8 + row])));
            const value = d * scale * @as(f32, @floatFromInt(@as(i16, nibble | (high << 4)) - 32));
            if (value != weights[element]) return error.TestUnexpectedResult;
        }
    }
    if (quad_dots) {
        const portable = dotQ6KX8Q8KTileWith(false, 4, &packed_rows, pointers, 2);
        for (0..4) |token| for (0..PACKED_ROWS) |row| {
            if (portable[token][row] != tile[token][row]) return error.TestUnexpectedResult;
        };
    }
    try std.testing.expectError(error.BufferTooSmall, packQ6KX8(packed_rows[0 .. rows.len - 1], &rows, 2));
}

test "Q8_0 quantization matches GGML's x86 rule" {
    // amax 127/64 makes 127/amax exactly 64: 0.5/64 and 1.5/64 are ties that
    // round to even, and d is amax/127 = 1/64 exactly.
    var input: [QK8_0]f32 = @splat(0);
    input[0] = -1.984375;
    input[1] = 1.0;
    input[2] = 0.5 / 64.0;
    input[3] = 1.5 / 64.0;
    input[4] = -2.5 / 64.0;
    var blocks: [1]Q80Block = undefined;
    try quantizeQ80(&input, &blocks);
    const qs = blocks[0].qs;
    if (qs[0] != -127 or qs[1] != 64 or qs[2] != 0 or qs[3] != 2 or qs[4] != -2) return error.TestUnexpectedResult;
    if (blocks[0].d != 1.0 / 64.0) return error.TestUnexpectedResult;
    // An all-zero block has a zero scale and zero quants.
    @memset(&input, 0);
    try quantizeQ80(&input, &blocks);
    if (blocks[0].d != 0 or blocks[0].qs[5] != 0) return error.TestUnexpectedResult;
    try std.testing.expectError(error.InvalidDimensions, quantizeQ80(input[0..31], &blocks));
}

fn patternedQ80Rows(comptime rows: usize, comptime blocks: usize, seed: u32) [rows * blocks * Q8_0_BLOCK_BYTES]u8 {
    var bytes: [rows * blocks * Q8_0_BLOCK_BYTES]u8 = undefined;
    var state = seed;
    for (0..rows * blocks) |block| {
        const out = bytes[block * Q8_0_BLOCK_BYTES ..][0..Q8_0_BLOCK_BYTES];
        state = state *% 1664525 +% 1013904223;
        const d: f16 = @floatCast(0.001 + @as(f32, @floatFromInt(state >> 24)) / 25600.0);
        std.mem.writeInt(u16, out[0..2], @bitCast(d), .little);
        for (out[2..]) |*quant| {
            state = state *% 1664525 +% 1013904223;
            quant.* = @bitCast(@as(i8, @intCast(@as(i32, @intCast((state >> 24) % 255)) - 127)));
        }
    }
    return bytes;
}

test "Q8_0 dots equal the dequantized products" {
    const blocks = 3;
    const input = patternedInput(9);
    var activations: [blocks]Q80Block = undefined;
    try quantizeQ80(input[0 .. blocks * QK8_0], &activations);
    const row = patternedQ80Rows(1, blocks, 5);
    var weights: [blocks * QK8_0]f32 = undefined;
    try dequantizeQ80(&weights, &row);
    var expected: f64 = 0;
    var magnitude: f64 = 0;
    for (weights, 0..) |weight, element| {
        const block = activations[element / QK8_0];
        const product = @as(f64, weight) * block.d * @as(f64, @floatFromInt(block.qs[element % QK8_0]));
        expected += product;
        magnitude += @abs(product);
    }
    const actual = try dotQ80Q80(&row, &activations);
    if (@abs(actual - expected) > 1e-5 * magnitude) return error.TestUnexpectedResult;
    try std.testing.expectError(error.BufferTooSmall, dotQ80Q80(row[0 .. row.len - 1], &activations));
}

test "tiled Q8_0 dots equal one row at a time" {
    const blocks = 4;
    var activations: [MAX_TILE][blocks]Q80Block = undefined;
    for (&activations, 0..) |*tokens, index| {
        const input = patternedInput(@intCast(80 + index));
        try quantizeQ80(input[0 .. blocks * QK8_0], tokens);
    }
    const row = patternedQ80Rows(1, blocks, 17);
    const pointers = [MAX_TILE][*]const Q80Block{ &activations[0], &activations[1], &activations[2], &activations[3] };
    const tile = dotQ80Q80Tile(MAX_TILE, &row, pointers, blocks);
    for (0..MAX_TILE) |token| {
        if (tile[token] != try dotQ80Q80(&row, &activations[token])) return error.TestUnexpectedResult;
        // The portable pair sums give the same integers as the quad dots.
        var portable: F32x8 = @splat(0);
        for (0..blocks) |block_index| {
            const block = row[block_index * Q8_0_BLOCK_BYTES ..][0..Q8_0_BLOCK_BYTES];
            const quants: Signed32 = @bitCast(block[2..34].*);
            const negative = quants < @as(Signed32, @splat(0));
            const values: Signed32 = activations[token][block_index].qs;
            const integer = mulAddWords(mulAddPairs(@bitCast(@abs(quants)), @select(i8, negative, -%values, values)), @splat(1));
            portable = @mulAdd(F32x8, @splat(halfAt(block, 0) * activations[token][block_index].d), @floatFromInt(integer), portable);
        }
        if (reduceLikeAvx(portable) != tile[token]) return error.TestUnexpectedResult;
    }
}

test "Q4_K dot product smoke" {
    // Minimal: verify the function signature compiles and accepts valid dims
    var block: [Q4_K_BLOCK_BYTES]u8 = @splat(0);
    var input: [QK_K]f32 = @splat(0);
    const result = try dotQ4K(&block, &input);
    if (result != 0) return error.TestUnexpectedResult; // zero weights * zero input = 0
}

