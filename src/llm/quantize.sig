// @zpm/llm — Quantization support
// Dequantizes GGUF quantized weights on-the-fly during inference.
// Supports: Q4_K, Q5_K, Q6_K, Q8_0, BF16, F16, F32
//
// Pattern: weight blocks are dequantized one row at a time into a
// scratch buffer, then used for matmul. This keeps memory usage bounded
// while allowing quantized model files (3-4x smaller than F32).

pub const QuantType = enum(u8) {
    f32 = 0,
    f16 = 1,
    q4_0 = 2,
    q4_k = 12,
    q5_k = 13,
    q6_k = 14,
    q8_0 = 8,
    bf16 = 30,
};

/// Dequantize a block of Q8_0 data to f32.
/// Q8_0: 32 values per block, 1 f16 scale + 32 i8 quants = 34 bytes/block
pub fn dequantQ8_0(src: [*]const u8, dst: [*]f32, n_elements: usize) void {
    const block_size: usize = 32;
    const n_blocks = n_elements / block_size;
    var bi: usize = 0;
    while (bi < n_blocks) : (bi += 1) {
        const block = src + bi * 34; // 2 bytes scale + 32 bytes quants
        // Scale is f16 (first 2 bytes)
        const scale_bits = @as(u16, block[0]) | (@as(u16, block[1]) << 8);
        const scale = f16ToF32(scale_bits);
        // Dequantize 32 int8 values
        var qi: usize = 0;
        while (qi < block_size) : (qi += 1) {
            const quant: i8 = @bitCast(block[2 + qi]);
            dst[bi * block_size + qi] = @as(f32, @floatFromInt(quant)) * scale;
        }
    }
}

/// Dequantize a block of Q4_K data to f32.
/// Q4_K: 256 values per block, complex structure with scales and mins
pub fn dequantQ4_K(src: [*]const u8, dst: [*]f32, n_elements: usize) void {
    const block_size: usize = 256;
    const n_blocks = n_elements / block_size;
    // Q4_K block: 2 f16 (d, dmin) + 12 bytes (scales) + 128 bytes (quants) = 144 bytes
    var bi: usize = 0;
    while (bi < n_blocks) : (bi += 1) {
        const block = src + bi * 144;
        const d = f16ToF32(@as(u16, block[0]) | (@as(u16, block[1]) << 8));
        const dmin = f16ToF32(@as(u16, block[2]) | (@as(u16, block[3]) << 8));
        const scales = block[4..16];
        const quants = block[16..144];

        const out_base = bi * block_size;
        var is: usize = 0;
        var q_off: usize = 0;
        var y_off: usize = 0;

        while (is < 8 and q_off + 32 <= 128) : ({
            is += 2;
            q_off += 32;
            y_off += 64;
        }) {
            // Per-sub-block scale and min (same logic as fused_matmul.sig)
            const sc1: u8 = if (is < 4) scales[is] & 63 else (scales[is + 4] & 0xF) | ((scales[is - 4] >> 6) << 4);
            const m1: u8 = if (is < 4) scales[is + 4] & 63 else (scales[is + 4] >> 4) | ((scales[is] >> 6) << 4);
            const d1 = d * @as(f32, @floatFromInt(sc1));
            const min1 = dmin * @as(f32, @floatFromInt(m1));

            const is2 = is + 1;
            const sc2: u8 = if (is2 < 4) scales[is2] & 63 else (scales[is2 + 4] & 0xF) | ((scales[is2 - 4] >> 6) << 4);
            const m2: u8 = if (is2 < 4) scales[is2 + 4] & 63 else (scales[is2 + 4] >> 4) | ((scales[is2] >> 6) << 4);
            const d2 = d * @as(f32, @floatFromInt(sc2));
            const min2 = dmin * @as(f32, @floatFromInt(m2));

            // Dequant 64 elements (32 lo-nibbles + 32 hi-nibbles)
            var l: usize = 0;
            while (l < 32) : (l += 1) {
                const qbyte = quants[q_off + l];
                dst[out_base + y_off + l] = d1 * @as(f32, @floatFromInt(qbyte & 0xF)) - min1;
                dst[out_base + y_off + 32 + l] = d2 * @as(f32, @floatFromInt(qbyte >> 4)) - min2;
            }
        }
    }
}

/// Dequantize a block of Q6_K data to f32.
/// Q6_K: 256 values per block, 210 bytes:
///   ql[128] (low 4 bits) + qh[64] (high 2 bits) + scales[16] (i8) + d (f16).
/// Layout matches ggml's dequantize_row_q6_K.
pub fn dequantQ6_K(src: [*]const u8, dst: [*]f32, n_elements: usize) void {
    const QK_K: usize = 256;
    const n_blocks = n_elements / QK_K;
    var bi: usize = 0;
    while (bi < n_blocks) : (bi += 1) {
        const block = src + bi * 210;
        const ql = block; // 128 bytes
        const qh = block + 128; // 64 bytes
        const sc: [*]const i8 = @ptrCast(block + 192); // 16 signed scales
        const d = f16ToF32(@as(u16, block[208]) | (@as(u16, block[209]) << 8));
        const out_base = bi * QK_K;

        // ggml processes the 256 values in two 128-wide halves.
        var n: usize = 0;
        while (n < QK_K) : (n += 128) {
            var l: usize = 0;
            while (l < 32) : (l += 1) {
                const is = l / 16;
                const ql_ptr = ql + n / 2;
                const qh_ptr = qh + n / 4;
                const q1 = @as(i32, (ql_ptr[l] & 0xF) | (((qh_ptr[l] >> 0) & 3) << 4)) - 32;
                const q2 = @as(i32, (ql_ptr[l + 32] & 0xF) | (((qh_ptr[l] >> 2) & 3) << 4)) - 32;
                const q3 = @as(i32, (ql_ptr[l] >> 4) | (((qh_ptr[l] >> 4) & 3) << 4)) - 32;
                const q4 = @as(i32, (ql_ptr[l + 32] >> 4) | (((qh_ptr[l] >> 6) & 3) << 4)) - 32;
                const sc_base = (n / 128) * 8 + is;
                dst[out_base + n + l] = d * @as(f32, @floatFromInt(sc[sc_base + 0])) * @as(f32, @floatFromInt(q1));
                dst[out_base + n + l + 32] = d * @as(f32, @floatFromInt(sc[sc_base + 2])) * @as(f32, @floatFromInt(q2));
                dst[out_base + n + l + 64] = d * @as(f32, @floatFromInt(sc[sc_base + 4])) * @as(f32, @floatFromInt(q3));
                dst[out_base + n + l + 96] = d * @as(f32, @floatFromInt(sc[sc_base + 6])) * @as(f32, @floatFromInt(q4));
            }
        }
    }
}

/// Dispatch dequantization by GGML type code (the numeric value stored in the
/// GGUF tensor header). Handles the types Qwen-Image uses: F32(0), F16(1),
/// Q8_0(8), Q4_K(12), Q6_K(14), BF16(30). Unknown types zero-fill.
pub fn dequantByType(type_code: u32, src: [*]const u8, dst: [*]f32, n_elements: usize) void {
    switch (type_code) {
        0 => { // f32 — direct copy
            const s: [*]const f32 = @ptrCast(@alignCast(src));
            var i: usize = 0;
            while (i < n_elements) : (i += 1) dst[i] = s[i];
        },
        1 => { // f16
            const s: [*]const u16 = @ptrCast(@alignCast(src));
            var i: usize = 0;
            while (i < n_elements) : (i += 1) dst[i] = f16ToF32(s[i]);
        },
        8 => dequantQ8_0(src, dst, n_elements),
        12 => dequantQ4_K(src, dst, n_elements),
        14 => dequantQ6_K(src, dst, n_elements),
        30 => dequantBf16(@ptrCast(@alignCast(src)), dst, n_elements),
        else => {
            var i: usize = 0;
            while (i < n_elements) : (i += 1) dst[i] = 0;
        },
    }
}

/// Dequantize BF16 to F32
pub fn dequantBf16(src: [*]const u16, dst: [*]f32, n_elements: usize) void {
    var i: usize = 0;
    while (i < n_elements) : (i += 1) {
        dst[i] = bf16ToF32(src[i]);
    }
}

/// BF16 → F32 conversion
pub fn bf16ToF32(val: u16) f32 {
    const bits: u32 = @as(u32, val) << 16;
    return @bitCast(bits);
}

/// F16 → F32 conversion
pub fn f16ToF32(val: u16) f32 {
    const sign: u32 = (@as(u32, val) >> 15) << 31;
    const exp: u32 = (@as(u32, val) >> 10) & 0x1F;
    const mant: u32 = @as(u32, val) & 0x3FF;

    if (exp == 0) {
        if (mant == 0) return @bitCast(sign); // zero
        // Denormalized
        var m = mant;
        var e: u32 = 0;
        while ((m & 0x400) == 0) { m <<= 1; e += 1; }
        const result = sign | ((127 - 15 - e) << 23) | ((m & 0x3FF) << 13);
        return @bitCast(result);
    }
    if (exp == 31) {
        // Inf/NaN
        return @bitCast(sign | 0x7F800000 | (mant << 13));
    }
    // Normalized
    return @bitCast(sign | ((exp + 112) << 23) | (mant << 13));
}

/// F32 → F16 conversion
pub fn f32ToF16(val: f32) u16 {
    const bits: u32 = @bitCast(val);
    const sign: u16 = @intCast((bits >> 16) & 0x8000);
    const exp_f32: i32 = @intCast((bits >> 23) & 0xFF);
    const mant: u32 = bits & 0x7FFFFF;

    if (exp_f32 == 255) {
        // Inf/NaN
        if (mant == 0) return sign | 0x7C00; // Inf
        return sign | 0x7C01; // NaN
    }
    if (exp_f32 == 0) return sign; // zero/denorm → zero

    const exp_f16 = exp_f32 - 127 + 15;
    if (exp_f16 >= 31) return sign | 0x7C00; // overflow → Inf
    if (exp_f16 <= 0) return sign; // underflow → zero

    return sign | (@as(u16, @intCast(exp_f16)) << 10) | @as(u16, @intCast(mant >> 13));
}
