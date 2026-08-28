// @zpm/matmul — CUDA Backend (cuBLAS dispatch)
// Uses NVIDIA cuBLAS for GPU-accelerated GEMM on Blackwell Tensor Cores.
//
// cuBLAS on SM 120 (RTX 5070) automatically uses:
//   - 5th-gen Tensor Cores (tcgen05)
//   - TMA (Tensor Memory Accelerator) for async global→shared copy
//   - UTCMMA (Unified Tensor Core MMA) instructions
//   - Mixed precision paths (TF32 for f32 inputs → near-f32 accuracy at f16 speed)
//
// We use the legacy cublasSgemm interface (f32) which internally uses TF32 on Blackwell.
// For BF16/F16 models, cublasGemmEx with CUBLAS_COMPUTE_16F is even faster.
//
// Dynamic loading strategy:
//   1. LoadLibraryA("cublas64_12.dll") — CUDA 12.x (RTX 5070 ships with this)
//      Fallback: "cublas64_11.dll" for older installs
//   2. GetProcAddress for cublasCreate_v2, cublasDestroy_v2, cublasSgemm_v2,
//      cublasSetStream
//   3. Also load nvcuda.dll for cuCtxCreate_v2, cuCtxSetCurrent, cuMemAlloc_v2, etc.
//
// All CUDA driver API + cuBLAS calls go through these function pointers.
// If loading fails, isAvailable() returns false and matmul/root.sig falls back to CPU.

const std = @import("std");

// ── Win32 FFI ──
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hModule: *anyopaque) c_int;

// ── cuBLAS types ──
pub const CublasHandle = *anyopaque;
pub const CublasStatus = c_int;
pub const CublasOperation = enum(c_int) {
    N = 0, // No transpose
    T = 1, // Transpose
    C = 2, // Conjugate transpose
};

pub const CUBLAS_STATUS_SUCCESS: c_int = 0;

// ── CUDA Driver API types ──
pub const CUcontext = *anyopaque;
pub const CUdevice = c_int;
pub const CUdeviceptr = u64; // GPU pointer (64-bit)
pub const CUresult = c_int;
pub const CUstream = ?*anyopaque;

pub const CUDA_SUCCESS: c_int = 0;

// ── Function pointer types ──

// cuBLAS
const CublasCreateFn = *const fn (*CublasHandle) callconv(.c) CublasStatus;
const CublasDestroyFn = *const fn (CublasHandle) callconv(.c) CublasStatus;
const CublasSgemmFn = *const fn (
    CublasHandle,
    CublasOperation,
    CublasOperation,
    c_int,
    c_int,
    c_int, // m, n, k
    *const f32, // alpha
    [*]const f32,
    c_int, // A, lda
    [*]const f32,
    c_int, // B, ldb
    *const f32, // beta
    [*]f32,
    c_int, // C, ldc
) callconv(.c) CublasStatus;
const CublasSetStreamFn = *const fn (CublasHandle, CUstream) callconv(.c) CublasStatus;
const CublasGemmExFn = *const fn (
    CublasHandle, // handle
    CublasOperation, // transa
    CublasOperation, // transb
    c_int, // m
    c_int, // n
    c_int, // k
    *const anyopaque, // alpha
    *const anyopaque, // A
    c_int, // Atype (cudaDataType)
    c_int, // lda
    *const anyopaque, // B
    c_int, // Btype
    c_int, // ldb
    *const anyopaque, // beta
    *anyopaque, // C
    c_int, // Ctype
    c_int, // ldc
    c_int, // computeType
    c_int, // algo (CUBLAS_GEMM_DEFAULT = -1)
) callconv(.c) CublasStatus;

// CUDA Driver API
const CuInitFn = *const fn (c_uint) callconv(.c) CUresult;
const CuDeviceGetFn = *const fn (*CUdevice, c_int) callconv(.c) CUresult;
const CuCtxCreateFn = *const fn (*CUcontext, c_uint, CUdevice) callconv(.c) CUresult;
const CuCtxSetCurrentFn = *const fn (CUcontext) callconv(.c) CUresult;
const CuCtxGetCurrentFn = *const fn (*CUcontext) callconv(.c) CUresult;
const CuCtxDestroyFn = *const fn (CUcontext) callconv(.c) CUresult;
const CuMemAllocFn = *const fn (*CUdeviceptr, usize) callconv(.c) CUresult;
const CuMemFreeFn = *const fn (CUdeviceptr) callconv(.c) CUresult;
const CuMemcpyHtoDFn = *const fn (CUdeviceptr, *const anyopaque, usize) callconv(.c) CUresult;
const CuMemcpyDtoHFn = *const fn (*anyopaque, CUdeviceptr, usize) callconv(.c) CUresult;
const CuStreamCreateFn = *const fn (*CUstream, c_uint) callconv(.c) CUresult;
const CuStreamSyncFn = *const fn (CUstream) callconv(.c) CUresult;
const CuStreamDestroyFn = *const fn (CUstream) callconv(.c) CUresult;

// ── Module state ──
pub var cublas_handle: ?CublasHandle = null;
var cublas_loaded: bool = false;
var cuda_loaded: bool = false;
var cublas_dll: ?*anyopaque = null;
var nvcuda_dll: ?*anyopaque = null;

// cuBLAS function pointers
pub var fn_cublasCreate: ?CublasCreateFn = null;
pub var fn_cublasDestroy: ?CublasDestroyFn = null;
pub var fn_cublasSgemm: ?CublasSgemmFn = null;
pub var fn_cublasSetStream: ?CublasSetStreamFn = null;
pub var fn_cublasGemmEx: ?CublasGemmExFn = null;

// CUDA Driver function pointers
pub var fn_cuInit: ?CuInitFn = null;
pub var fn_cuDeviceGet: ?CuDeviceGetFn = null;
pub var fn_cuCtxCreate: ?CuCtxCreateFn = null;
pub var fn_cuCtxSetCurrent: ?CuCtxSetCurrentFn = null;
pub var fn_cuCtxGetCurrent: ?CuCtxGetCurrentFn = null;
pub var fn_cuCtxDestroy: ?CuCtxDestroyFn = null;
pub var fn_cuMemAlloc: ?CuMemAllocFn = null;
pub var fn_cuMemFree: ?CuMemFreeFn = null;
pub var fn_cuMemcpyHtoD: ?CuMemcpyHtoDFn = null;
pub var fn_cuMemcpyDtoH: ?CuMemcpyDtoHFn = null;
pub var fn_cuStreamCreate: ?CuStreamCreateFn = null;
pub var fn_cuStreamSync: ?CuStreamSyncFn = null;
pub var fn_cuStreamDestroy: ?CuStreamDestroyFn = null;

// Shared CUDA context (set by cuda_ctx.sig)
pub var shared_context: ?CUcontext = null;
pub var shared_stream: ?CUstream = null;

/// Check if CUDA/cuBLAS is available and initialized
pub fn isAvailable() bool {
    return cublas_loaded and cublas_handle != null;
}

/// Check if CUDA driver API is loaded (for memory management)
pub fn isCudaDriverLoaded() bool {
    return cuda_loaded;
}

/// Initialize cuBLAS — loads DLLs, resolves symbols, creates handle.
/// Call once at startup. Returns true on success.
pub fn init() bool {
    if (cublas_loaded) return true;

    // Step 1: Load CUDA driver (nvcuda.dll)
    if (!loadCudaDriver()) return false;

    // Step 2: Load cuBLAS
    if (!loadCublas()) return false;

    // Step 3: Initialize CUDA driver
    if (fn_cuInit) |cuInit| {
        const res = cuInit(0);
        if (res != CUDA_SUCCESS) return false;
    } else return false;

    // Step 4: Create cuBLAS handle
    if (fn_cublasCreate) |cublasCreate| {
        var handle: CublasHandle = undefined;
        const status = cublasCreate(&handle);
        if (status != CUBLAS_STATUS_SUCCESS) return false;
        cublas_handle = handle;
    } else return false;

    cublas_loaded = true;
    return true;
}

/// Initialize with an externally-created CUDA context (from cuda_ctx.sig).
/// Use this when sharing a context between ASR and LLM.
pub fn initWithContext(ctx: CUcontext, stream: ?CUstream) bool {
    if (cublas_loaded) return true;

    // Load DLLs if not already loaded
    if (!cuda_loaded) {
        if (!loadCudaDriver()) return false;
    }
    if (cublas_dll == null) {
        if (!loadCublas()) return false;
    }

    // Set the provided context as current
    if (fn_cuCtxSetCurrent) |setCurrent| {
        const res = setCurrent(ctx);
        if (res != CUDA_SUCCESS) return false;
    } else return false;

    shared_context = ctx;
    shared_stream = stream;

    // Create cuBLAS handle (uses current context)
    if (fn_cublasCreate) |cublasCreate| {
        var handle: CublasHandle = undefined;
        const status = cublasCreate(&handle);
        if (status != CUBLAS_STATUS_SUCCESS) return false;
        cublas_handle = handle;
    } else return false;

    // Bind cuBLAS to the provided stream
    if (stream) |s| {
        if (fn_cublasSetStream) |setStream| {
            _ = setStream(cublas_handle.?, s);
        }
    }

    cublas_loaded = true;
    return true;
}

/// Shutdown cuBLAS and release resources.
pub fn deinit() void {
    if (cublas_handle) |h| {
        if (fn_cublasDestroy) |destroy| _ = destroy(h);
        cublas_handle = null;
    }
    cublas_loaded = false;

    if (cublas_dll) |dll| {
        _ = FreeLibrary(dll);
        cublas_dll = null;
    }
    // Don't free nvcuda.dll — CUDA context may still be alive
}

/// GEMM via cuBLAS: C[M×N] += A[M×K] @ B[N×K]^T
/// cuBLAS is column-major, so we compute C^T = B @ A^T which gives us C = A @ B^T in row-major.
pub fn gemm(c: [*]f32, a: [*]const f32, b: [*]const f32, m: usize, k: usize, n: usize) void {
    if (!isAvailable()) return;

    const alpha: f32 = 1.0;
    const beta: f32 = 1.0; // accumulate

    // Row-major trick: swap A and B, swap M and N
    // C[M×N] = A[M×K] @ B^T[K×N]  (row-major)
    // becomes: C^T[N×M] = B[N×K] @ A^T[K×M]  (column-major for cuBLAS)
    _ = fn_cublasSgemm.?(
        cublas_handle.?,
        .N,
        .T, // B not transposed, A transposed (in cuBLAS column-major view)
        @intCast(n),
        @intCast(m),
        @intCast(k),
        &alpha,
        b,
        @intCast(k), // B[N×K] with ldb=K
        a,
        @intCast(k), // A[M×K] with lda=K (transposed in cuBLAS view)
        &beta,
        c,
        @intCast(n), // C[M×N] with ldc=N
    );
}

/// Matrix-vector multiply via cuBLAS: out[N] = weight[N×K] @ input[K]
pub fn matvec(output: [*]f32, weight: [*]const f32, input: [*]const f32, n: usize, k: usize) void {
    // matvec is GEMM with M=1
    gemm(output, input, weight, 1, k, n);
}

/// Allocate GPU memory. Returns device pointer (0 on failure).
pub fn gpuAlloc(size_bytes: usize) CUdeviceptr {
    if (fn_cuMemAlloc) |memAlloc| {
        var dptr: CUdeviceptr = 0;
        const res = memAlloc(&dptr, size_bytes);
        if (res == CUDA_SUCCESS) return dptr;
    }
    return 0;
}

/// Free GPU memory.
pub fn gpuFree(dptr: CUdeviceptr) void {
    if (dptr == 0) return;
    if (fn_cuMemFree) |memFree| {
        _ = memFree(dptr);
    }
}

/// Copy host → device.
pub fn uploadToGpu(dst: CUdeviceptr, src: *const anyopaque, size_bytes: usize) bool {
    if (fn_cuMemcpyHtoD) |htod| {
        return htod(dst, src, size_bytes) == CUDA_SUCCESS;
    }
    return false;
}

/// Copy device → host.
pub fn downloadFromGpu(dst: *anyopaque, src: CUdeviceptr, size_bytes: usize) bool {
    if (fn_cuMemcpyDtoH) |dtoh| {
        return dtoh(dst, src, size_bytes) == CUDA_SUCCESS;
    }
    return false;
}

/// Synchronize the compute stream.
pub fn syncStream() void {
    if (shared_stream) |s| {
        if (fn_cuStreamSync) |sync| _ = sync(s);
    }
}

// ── Internal: DLL loading ──

fn loadCudaDriver() bool {
    if (cuda_loaded) return true;

    nvcuda_dll = LoadLibraryA("nvcuda.dll");
    if (nvcuda_dll == null) return false;

    const dll = nvcuda_dll.?;
    fn_cuInit = @ptrCast(GetProcAddress(dll, "cuInit"));
    fn_cuDeviceGet = @ptrCast(GetProcAddress(dll, "cuDeviceGet"));
    fn_cuCtxCreate = @ptrCast(GetProcAddress(dll, "cuCtxCreate_v2"));
    fn_cuCtxSetCurrent = @ptrCast(GetProcAddress(dll, "cuCtxSetCurrent"));
    fn_cuCtxGetCurrent = @ptrCast(GetProcAddress(dll, "cuCtxGetCurrent"));
    fn_cuCtxDestroy = @ptrCast(GetProcAddress(dll, "cuCtxDestroy_v2"));
    fn_cuMemAlloc = @ptrCast(GetProcAddress(dll, "cuMemAlloc_v2"));
    fn_cuMemFree = @ptrCast(GetProcAddress(dll, "cuMemFree_v2"));
    fn_cuMemcpyHtoD = @ptrCast(GetProcAddress(dll, "cuMemcpyHtoD_v2"));
    fn_cuMemcpyDtoH = @ptrCast(GetProcAddress(dll, "cuMemcpyDtoH_v2"));
    fn_cuStreamCreate = @ptrCast(GetProcAddress(dll, "cuStreamCreate"));
    fn_cuStreamSync = @ptrCast(GetProcAddress(dll, "cuStreamSynchronize"));
    fn_cuStreamDestroy = @ptrCast(GetProcAddress(dll, "cuStreamDestroy_v2"));

    // Minimum required: cuInit + cuCtxCreate + cuMemAlloc
    if (fn_cuInit == null or fn_cuCtxCreate == null or fn_cuMemAlloc == null) return false;

    cuda_loaded = true;
    return true;
}

fn loadCublas() bool {
    // Try CUDA 13.x first (RTX 5070 with CUDA 13.3)
    cublas_dll = LoadLibraryA("cublas64_13.dll");
    if (cublas_dll == null) {
        // Try full path to CUDA 13.3 toolkit
        cublas_dll = LoadLibraryA("C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v13.3\\bin\\x64\\cublas64_13.dll");
    }
    if (cublas_dll == null) {
        // Try short path (avoids space issues)
        cublas_dll = LoadLibraryA("C:\\PROGRA~1\\NVIDIA~2\\CUDA\\v13.3\\bin\\x64\\cublas64_13.dll");
    }
    if (cublas_dll == null) {
        // Fallback: CUDA 12.x
        cublas_dll = LoadLibraryA("cublas64_12.dll");
    }
    if (cublas_dll == null) return false;

    const dll = cublas_dll.?;
    fn_cublasCreate = @ptrCast(GetProcAddress(dll, "cublasCreate_v2"));
    fn_cublasDestroy = @ptrCast(GetProcAddress(dll, "cublasDestroy_v2"));
    fn_cublasSgemm = @ptrCast(GetProcAddress(dll, "cublasSgemm_v2"));
    fn_cublasSetStream = @ptrCast(GetProcAddress(dll, "cublasSetStream_v2"));
    fn_cublasGemmEx = @ptrCast(GetProcAddress(dll, "cublasGemmEx"));

    // Minimum required: create + sgemm
    if (fn_cublasCreate == null or fn_cublasSgemm == null) return false;

    return true;
}
