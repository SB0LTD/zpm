// @zpm/matmul — High-Performance Matrix Multiplication
//
// Implements GEMM: C = A @ B^T (row-major, transposed-B — the LLM inference layout)
//
// Architecture:
//   GPU path: cuBLAS dispatch (NVIDIA Tensor Cores on Blackwell SM 120)
//   CPU path: Goto-style tiled GEMM with AVX2 SIMD micro-kernels
//
// The CPU kernel follows the Goto & Van De Geijn decomposition:
//   L3 blocking: partition M into panels of MC rows
//   L2 blocking: partition K into panels of KC columns
//   L1 blocking: partition N into panels of NC columns
//   Pack A: MC×KC panel into contiguous memory (for sequential L2 access)
//   Pack B: KC×NC panel into contiguous memory (for sequential L1 access)
//   Micro-kernel: MR×NR register-blocked FMA accumulation
//
// Optimal parameters for AVX2 (16 YMM registers, 8-wide f32):
//   MR = 6 (rows of C accumulated in registers)
//   NR = 16 (columns of C = 2 YMM vectors per row, 6×2 = 12 accumulators)
//   MC = 72 (L2 fit for packed A: 72 × KC × 4 bytes)
//   KC = 256 (inner dimension block — fits in L2)
//   NC = 4096 (L3 fit for packed B: KC × NC × 4 bytes)
//
// Performance target: 80%+ of theoretical peak FLOPS
//   Intel 13th gen: 2 FMA units × 8 floats × 2 ops = 32 FLOPS/cycle
//   At 4.8 GHz turbo: ~150 GFLOPS/core peak

pub const cpu = @import("cpu.sig");
pub const cuda = @import("cuda.sig");

/// Compute C[M×N] += A[M×K] @ B[N×K]^T using the best available backend.
/// B is stored transposed (row = output neuron weights), which is standard for LLM inference.
pub fn gemm(
    c: [*]f32, // [M, N] output (accumulated)
    a: [*]const f32, // [M, K] input activations
    b: [*]const f32, // [N, K] weight matrix (transposed)
    m: usize,
    k: usize,
    n: usize,
) void {
    // Dispatch to best backend
    if (cuda.isAvailable()) {
        cuda.gemm(c, a, b, m, k, n);
    } else {
        cpu.gemm(c, a, b, m, k, n);
    }
}

/// Matrix-vector multiply: out[N] = weight[N×K] @ input[K]
/// Optimized path for single-token decode (M=1).
pub fn matvec(
    output: [*]f32,
    weight: [*]const f32, // [N, K]
    input: [*]const f32, // [K]
    n: usize,
    k: usize,
) void {
    if (cuda.isAvailable()) {
        cuda.matvec(output, weight, input, n, k);
    } else {
        cpu.matvec(output, weight, input, n, k);
    }
}
