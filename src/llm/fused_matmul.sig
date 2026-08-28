// @zpm/llm — Fused Dequant-Matvec
// Performs quantized matrix-vector multiply WITHOUT intermediate buffers.
// Each output element is computed by streaming through the quantized weight row,
// dequanting block-by-block and accumulating the dot product inline.
//
// Memory profile per call: ZERO allocation. Only a 256-float stack buffer
// for one dequant block (~1KB). Total working set: input vector (8KB) + 1KB block.
// Both fit in L1 cache → maximum throughput.
//
// Performance (Qwen3-VL-2B, single token decode):
//   Largest matmul: gate_proj [6144 × 2048]
//   Per row: 2048 elements / 256 per block = 8 blocks × dequant+dot
//   Per matrix: 6144 rows × 8 blocks = 49,152 block operations
//   At ~2ns per element (AVX2 dot): 6144 × 2048 × 2ns = ~25ms
//   7 matrices × 28 layers: ~180ms per token → ~5.5 tok/s on single core
//   With 8-thread parallelism on rows: ~22ms per token → ~45 tok/s
//
// This is the hot inner loop. Every cycle matters.

const quantize = @import("quantize.sig");
const gguf_loader = @import("gguf_loader.sig");

/// Fused quantized matvec: output[N] = W_quant[N, K] @ input[K]
/// W is stored in quantized format (Q4_K, Q8_0, F16, F32).
/// No scratch buffer needed — processes row-by-row with inline dequant.
pub fn quantMatvec(
    output: [*]f32,
    weight: [*]const u8, // raw quantized weight data
    input: [*]const f32, // [K] input vector
    n_rows: usize, // N (output dimension)
    n_cols: usize, // K (input dimension)
    qtype: gguf_loader.GGMLType,
) void {
    switch (qtype) {
        .f32 => matvecF32(output, weight, input, n_rows, n_cols),
        .f16 => matvecF16(output, weight, input, n_rows, n_cols),
        .q8_0 => matvecQ8_0(output, weight, input, n_rows, n_cols),
        .q4_k => matvecQ4K(output, weight, input, n_rows, n_cols),
        else => {
            // Unsupported type — zero output
            for (0..n_rows) |i| output[i] = 0.0;
        },
    }
}

/// F32 matvec (no dequant needed, just dot products)
fn matvecF32(output: [*]f32, weight: [*]const u8, input: [*]const f32, n_rows: usize, n_cols: usize) void {
    const w: [*]const f32 = @ptrCast(@alignCast(weight));
    for (0..n_rows) |row| {
        var acc: f32 = 0.0;
        const row_ptr = w + row * n_cols;
        for (0..n_cols) |col| acc += row_ptr[col] * input[col];
        output[row] = acc;
    }
}

/// F16 matvec (inline f16→f32 conversion per element)
fn matvecF16(output: [*]f32, weight: [*]const u8, input: [*]const f32, n_rows: usize, n_cols: usize) void {
    const row_bytes = n_cols * 2; // 2 bytes per f16
    for (0..n_rows) |row| {
        var acc: f32 = 0.0;
        const row_ptr = weight + row * row_bytes;
        for (0..n_cols) |col| {
            const h: u16 = @as(u16, row_ptr[col * 2]) | (@as(u16, row_ptr[col * 2 + 1]) << 8);
            acc += quantize.f16ToF32(h) * input[col];
        }
        output[row] = acc;
    }
}

/// Q8_0 fused matvec: dequant each 32-element block and dot inline.
/// Q8_0 layout: [f16 scale][32 × i8] = 34 bytes per block of 32 elements.
fn matvecQ8_0(output: [*]f32, weight: [*]const u8, input: [*]const f32, n_rows: usize, n_cols: usize) void {
    const block_size: usize = 32;
    const block_bytes: usize = 34;
    const blocks_per_row = n_cols / block_size;
    const row_bytes = blocks_per_row * block_bytes;

    for (0..n_rows) |row| {
        var acc: f32 = 0.0;
        const row_ptr = weight + row * row_bytes;

        for (0..blocks_per_row) |bi| {
            const block = row_ptr + bi * block_bytes;
            const scale = quantize.f16ToF32(@as(u16, block[0]) | (@as(u16, block[1]) << 8));
            const input_off = bi * block_size;

            // Dot product: sum(quant[j] * scale * input[off+j])
            var block_acc: f32 = 0.0;
            for (0..block_size) |j| {
                const q: i8 = @bitCast(block[2 + j]);
                block_acc += @as(f32, @floatFromInt(q)) * input[input_off + j];
            }
            acc += block_acc * scale;
        }
        output[row] = acc;
    }
}

/// Q4_K fused matvec: the most complex but most common quantization.
/// Q4_K layout: 256 elements per block, 144 bytes per block.
///   [f16 d][f16 dmin][12 bytes scales][128 bytes quants]
/// Each block has 8 sub-blocks of 32 elements with individual scale/min.
///
/// SIMD strategy: process 8 elements at a time using @Vector(8, f32).
/// Each sub-block has 32 lo-nibble and 32 hi-nibble elements = 64 total.
/// We process each 32-element half in 4 iterations of 8 elements.
/// This gives ~4x throughput vs scalar on AVX2 hardware.
fn matvecQ4K(output: [*]f32, weight: [*]const u8, input: [*]const f32, n_rows: usize, n_cols: usize) void {
    const block_elems: usize = 256;
    const block_bytes: usize = 144;
    const blocks_per_row = (n_cols + block_elems - 1) / block_elems;
    const row_bytes = blocks_per_row * block_bytes;
    const Vec8 = @Vector(8, f32);

    for (0..n_rows) |row| {
        var acc_vec: Vec8 = @splat(0.0);
        var acc_scalar: f32 = 0.0;
        const row_ptr = weight + row * row_bytes;

        for (0..blocks_per_row) |bi| {
            const block = row_ptr + bi * block_bytes;
            const d = quantize.f16ToF32(@as(u16, block[0]) | (@as(u16, block[1]) << 8));
            const dmin = quantize.f16ToF32(@as(u16, block[2]) | (@as(u16, block[3]) << 8));
            const scales = block[4..16];
            const quants = block[16..144];

            const input_off = bi * block_elems;
            var is: usize = 0;
            var q_off: usize = 0;
            var y_off: usize = 0;

            while (is < 8 and q_off + 32 <= 128) : ({
                is += 2;
                q_off += 32;
                y_off += 64;
            }) {
                const sm1 = getScaleMinK4(is, scales);
                const d1 = d * @as(f32, @floatFromInt(sm1.sc));
                const m1 = dmin * @as(f32, @floatFromInt(sm1.m));
                const sm2 = getScaleMinK4(is + 1, scales);
                const d2 = d * @as(f32, @floatFromInt(sm2.sc));
                const m2 = dmin * @as(f32, @floatFromInt(sm2.m));

                const d1_vec: Vec8 = @splat(d1);
                const m1_vec: Vec8 = @splat(m1);
                const d2_vec: Vec8 = @splat(d2);
                const m2_vec: Vec8 = @splat(m2);

                // ── Lo nibbles: 32 elements in 4 × 8 SIMD passes ──
                const base_lo = input_off + y_off;
                if (base_lo + 32 <= n_cols) {
                    // Full 32-element sub-block — unroll 4 SIMD iterations
                    comptime var k: usize = 0;
                    inline while (k < 4) : (k += 1) {
                        const off = k * 8;
                        // Unpack 8 lo-nibbles from 8 quant bytes
                        const q_vals: Vec8 = .{
                            @as(f32, @floatFromInt(quants[q_off + off + 0] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 1] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 2] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 3] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 4] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 5] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 6] & 0xF)),
                            @as(f32, @floatFromInt(quants[q_off + off + 7] & 0xF)),
                        };
                        // dequant: d1 * q - m1
                        const dequant_lo = d1_vec * q_vals - m1_vec;
                        // Load 8 input elements (aligned to natural stride)
                        const in_lo: Vec8 = .{
                            input[base_lo + off + 0],
                            input[base_lo + off + 1],
                            input[base_lo + off + 2],
                            input[base_lo + off + 3],
                            input[base_lo + off + 4],
                            input[base_lo + off + 5],
                            input[base_lo + off + 6],
                            input[base_lo + off + 7],
                        };
                        // FMA: acc += dequant * input
                        acc_vec += dequant_lo * in_lo;
                    }
                } else {
                    // Tail: scalar fallback for partial sub-block
                    for (0..32) |l| {
                        const idx_lo = base_lo + l;
                        if (idx_lo >= n_cols) break;
                        const qbyte = quants[q_off + l];
                        acc_scalar += (d1 * @as(f32, @floatFromInt(qbyte & 0xF)) - m1) * input[idx_lo];
                    }
                }

                // ── Hi nibbles: 32 elements in 4 × 8 SIMD passes ──
                const base_hi = input_off + y_off + 32;
                if (base_hi + 32 <= n_cols) {
                    comptime var k: usize = 0;
                    inline while (k < 4) : (k += 1) {
                        const off = k * 8;
                        // Unpack 8 hi-nibbles from 8 quant bytes
                        const q_vals: Vec8 = .{
                            @as(f32, @floatFromInt(quants[q_off + off + 0] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 1] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 2] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 3] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 4] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 5] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 6] >> 4)),
                            @as(f32, @floatFromInt(quants[q_off + off + 7] >> 4)),
                        };
                        // dequant: d2 * q - m2
                        const dequant_hi = d2_vec * q_vals - m2_vec;
                        // Load 8 input elements
                        const in_hi: Vec8 = .{
                            input[base_hi + off + 0],
                            input[base_hi + off + 1],
                            input[base_hi + off + 2],
                            input[base_hi + off + 3],
                            input[base_hi + off + 4],
                            input[base_hi + off + 5],
                            input[base_hi + off + 6],
                            input[base_hi + off + 7],
                        };
                        // FMA: acc += dequant * input
                        acc_vec += dequant_hi * in_hi;
                    }
                } else {
                    // Tail: scalar fallback for partial sub-block
                    for (0..32) |l| {
                        const idx_hi = base_hi + l;
                        if (idx_hi >= n_cols) break;
                        const qbyte = quants[q_off + l];
                        acc_scalar += (d2 * @as(f32, @floatFromInt(qbyte >> 4)) - m2) * input[idx_hi];
                    }
                }
            }
        }
        // Horizontal sum of SIMD accumulator + scalar remainder
        output[row] = @reduce(.Add, acc_vec) + acc_scalar;
    }
}

const ScaleMin = struct { sc: u8, m: u8 };

fn getScaleMinK4(j: usize, scales: []const u8) ScaleMin {
    if (j < 4) {
        return .{ .sc = scales[j] & 63, .m = scales[j + 4] & 63 };
    } else {
        return .{
            .sc = (scales[j + 4] & 0xF) | ((scales[j - 4] >> 6) << 4),
            .m = (scales[j + 4] >> 4) | ((scales[j - 0] >> 6) << 4),
        };
    }
}
