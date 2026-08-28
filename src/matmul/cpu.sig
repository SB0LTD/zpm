// @zpm/matmul — CPU GEMM Kernel (Goto-style tiled, AVX2 SIMD)
//
// Implements C[M×N] += A[M×K] @ B[N×K]^T
//
// Decomposition (Goto & Van De Geijn 2008):
//   1. Partition M into panels of MC rows → "macro panel of A"
//   2. Partition K into strips of KC → "slice"
//   3. Pack A[MC×KC] into packed_a (contiguous, MR-aligned)
//   4. Pack B[KC×NC] into packed_b (contiguous, NR-aligned) 
//   5. For each MC×NC block of C:
//      - Call micro-kernel: MR×NR accumulation using FMA
//
// Micro-kernel: 6×16 (6 rows × 16 cols = 6 rows × 2 AVX2 vectors)
//   Uses 12 YMM accumulators (6 rows × 2 vectors) + 2 for A broadcast + 2 for B loads
//   = 16 YMM registers total (perfect fit for AVX2)
//
// SIMD: Zig/Sig @Vector(8, f32) maps to YMM registers.
// The compiler auto-vectorizes @Vector operations to AVX2 FMA instructions.

const Vec8 = @Vector(8, f32);

// ── Tiling parameters (tuned for Intel 13th gen Coffee Lake) ──
const MR: usize = 6; // micro-kernel rows
const NR: usize = 16; // micro-kernel cols (2 × 8-wide vectors)
const MC: usize = 72; // L2 panel height (multiple of MR)
const KC: usize = 256; // inner dimension block
const NC: usize = 4096; // L3 panel width (multiple of NR)

// ── Pack buffers (static — one GEMM at a time) ──
// packed_a: MC × KC = 72 × 256 = 18432 f32 = 72 KB (fits L2)
// packed_b: KC × NC = 256 × 4096 = 1048576 f32 = 4 MB (fits L3)
var packed_a: [MC * KC]f32 = undefined;
var packed_b: [KC * NC]f32 = undefined;

/// Main GEMM entry point: C[M×N] += A[M×K] @ B[N×K]^T
pub fn gemm(
    c: [*]f32,
    a: [*]const f32,
    b: [*]const f32,
    m: usize,
    k: usize,
    n: usize,
) void {
    // L3 loop: partition N into NC-wide panels
    var jc: usize = 0;
    while (jc < n) : (jc += NC) {
        const nc = @min(NC, n - jc);

        // L2 loop: partition K into KC-wide slices
        var pc: usize = 0;
        while (pc < k) : (pc += KC) {
            const kc = @min(KC, k - pc);

            // Pack B panel: B[jc..jc+nc, pc..pc+kc] into packed_b
            packB(b, n, jc, pc, nc, kc);

            // L1 loop: partition M into MC-tall panels
            var ic: usize = 0;
            while (ic < m) : (ic += MC) {
                const mc = @min(MC, m - ic);

                // Pack A panel: A[ic..ic+mc, pc..pc+kc] into packed_a
                packA(a, k, ic, pc, mc, kc);

                // Macro-kernel: compute C[ic..ic+mc, jc..jc+nc] += packed_a @ packed_b^T
                macroKernel(c, n, ic, jc, mc, nc, kc);
            }
        }
    }
}

// ── Pack A: reorder A[mc×kc] into MR-contiguous blocks ──
fn packA(a: [*]const f32, lda: usize, ic: usize, pc: usize, mc: usize, kc: usize) void {
    var dst: usize = 0;
    var i: usize = 0;
    while (i < mc) : (i += MR) {
        const mr = @min(MR, mc - i);
        // Pack MR rows of width KC contiguously
        var p: usize = 0;
        while (p < kc) : (p += 1) {
            var r: usize = 0;
            while (r < mr) : (r += 1) {
                packed_a[dst] = a[(ic + i + r) * lda + (pc + p)];
                dst += 1;
            }
            // Zero-pad if mr < MR
            while (r < MR) : (r += 1) {
                packed_a[dst] = 0;
                dst += 1;
            }
        }
    }
}

// ── Pack B: reorder B[nc×kc] into NR-contiguous blocks ──
// B is [N×K] (transposed layout: each row is a weight vector)
fn packB(b: [*]const f32, ldb: usize, jc: usize, pc: usize, nc: usize, kc: usize) void {
    var dst: usize = 0;
    var j: usize = 0;
    while (j < nc) : (j += NR) {
        const nr = @min(NR, nc - j);
        // Pack NR columns of width KC
        var p: usize = 0;
        while (p < kc) : (p += 1) {
            var c2: usize = 0;
            while (c2 < nr) : (c2 += 1) {
                packed_b[dst] = b[(jc + j + c2) * ldb + (pc + p)];
                dst += 1;
            }
            while (c2 < NR) : (c2 += 1) {
                packed_b[dst] = 0;
                dst += 1;
            }
        }
    }
}

// ── Macro-kernel: dispatches micro-kernel over MC×NC block ──
fn macroKernel(c: [*]f32, ldc: usize, ic: usize, jc: usize, mc: usize, nc: usize, kc: usize) void {
    var i: usize = 0;
    while (i < mc) : (i += MR) {
        const mr = @min(MR, mc - i);
        var j: usize = 0;
        while (j < nc) : (j += NR) {
            const nr = @min(NR, nc - j);
            // Micro-kernel: accumulate MR×NR block
            microKernel(c, ldc, ic + i, jc + j, mr, nr, kc, i, j);
        }
    }
}

// ── Micro-kernel: 6×16 FMA accumulation (the hot inner loop) ──
// Computes C[mr×nr] += packed_a[mr×kc]^T @ packed_b[kc×nr]
// Uses @Vector(8, f32) for SIMD — compiler maps to AVX2 vfmadd instructions.
fn microKernel(
    c: [*]f32, ldc: usize,
    ci: usize, cj: usize,
    mr: usize, nr: usize, kc: usize,
    ai_offset: usize, bj_offset: usize,
) void {
    // Accumulators: 6 rows × 2 vectors (16 columns)
    var acc: [MR][2]Vec8 = undefined;
    var r: usize = 0;
    while (r < MR) : (r += 1) {
        acc[r][0] = @splat(0.0);
        acc[r][1] = @splat(0.0);
    }

    // Packed A offset: ai_offset / MR * (MR * kc) — each MR-block is MR*kc contiguous
    const a_base = (ai_offset / MR) * (MR * kc);
    // Packed B offset: bj_offset / NR * (NR * kc)
    const b_base = (bj_offset / NR) * (NR * kc);

    // Inner loop over K dimension
    var p: usize = 0;
    while (p < kc) : (p += 1) {
        // Load NR values from packed_b (2 vectors of 8)
        const b_off = b_base + p * NR;
        const bv0: Vec8 = @as(*const Vec8, @ptrCast(@alignCast(&packed_b[b_off]))).*;
        const bv1: Vec8 = @as(*const Vec8, @ptrCast(@alignCast(&packed_b[b_off + 8]))).*;

        // For each row of MR: broadcast a[row, p] and FMA
        r = 0;
        while (r < mr) : (r += 1) {
            const a_val = packed_a[a_base + p * MR + r];
            const av: Vec8 = @splat(a_val);
            acc[r][0] = @mulAdd(Vec8, av, bv0, acc[r][0]);
            acc[r][1] = @mulAdd(Vec8, av, bv1, acc[r][1]);
        }
    }

    // Store accumulators back to C
    r = 0;
    while (r < mr) : (r += 1) {
        const c_row = (ci + r) * ldc + cj;
        // Load existing C values, add accumulator, store back
        if (nr >= 8) {
            const cv0: Vec8 = @as(*const Vec8, @ptrCast(@alignCast(c + c_row))).*;
            @as(*Vec8, @ptrCast(@alignCast(c + c_row))).* = cv0 + acc[r][0];
        }
        if (nr >= 16) {
            const cv1: Vec8 = @as(*const Vec8, @ptrCast(@alignCast(c + c_row + 8))).*;
            @as(*Vec8, @ptrCast(@alignCast(c + c_row + 8))).* = cv1 + acc[r][1];
        }
        // Handle remainder (nr < 16) with scalar
        if (nr < 16 and nr > 8) {
            var col: usize = 8;
            while (col < nr) : (col += 1) {
                c[c_row + col] += acc[r][1][col - 8];
            }
        }
        if (nr < 8) {
            var col: usize = 0;
            while (col < nr) : (col += 1) {
                c[c_row + col] += acc[r][0][col];
            }
        }
    }
}

/// Optimized matrix-vector multiply: out[N] = weight[N×K] @ input[K]
/// For M=1 (single token decode), uses dot-product vectorization.
pub fn matvec(output: [*]f32, weight: [*]const f32, input: [*]const f32, n: usize, k: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Vectorized dot product
        var sum: Vec8 = @splat(0.0);
        var j: usize = 0;
        const k_aligned = (k / 8) * 8;
        while (j < k_aligned) : (j += 8) {
            const wv: Vec8 = @as(*const Vec8, @ptrCast(@alignCast(weight + i * k + j))).*;
            const iv: Vec8 = @as(*const Vec8, @ptrCast(@alignCast(input + j))).*;
            sum = @mulAdd(Vec8, wv, iv, sum);
        }
        // Horizontal reduction
        var scalar_sum: f32 = 0;
        for (0..8) |s| scalar_sum += sum[s];
        // Remainder
        while (j < k) : (j += 1) scalar_sum += weight[i * k + j] * input[j];
        output[i] = scalar_sum;
    }
}
