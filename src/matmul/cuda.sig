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
const CuMemcpyHtoDAsyncFn = *const fn (CUdeviceptr, *const anyopaque, usize, CUstream) callconv(.c) CUresult;
const CuMemcpyDtoHAsyncFn = *const fn (*anyopaque, CUdeviceptr, usize, CUstream) callconv(.c) CUresult;
const CuStreamCreateFn = *const fn (*CUstream, c_uint) callconv(.c) CUresult;
const CuStreamSyncFn = *const fn (CUstream) callconv(.c) CUresult;
const CuStreamDestroyFn = *const fn (CUstream) callconv(.c) CUresult;
const CuDevicePrimaryCtxRetainFn = *const fn (*CUcontext, CUdevice) callconv(.c) CUresult;

// ── Custom-kernel (driver module + launch) types ──
// A loaded PTX/cubin module and a kernel function handle inside it.
pub const CUmodule = *anyopaque;
pub const CUfunction = *anyopaque;
const CuModuleLoadDataFn = *const fn (*CUmodule, *const anyopaque) callconv(.c) CUresult;
const CuModuleGetFunctionFn = *const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(.c) CUresult;
const CuModuleUnloadFn = *const fn (CUmodule) callconv(.c) CUresult;
const CuLaunchKernelFn = *const fn (
    CUfunction,
    c_uint, // gridDimX
    c_uint, // gridDimY
    c_uint, // gridDimZ
    c_uint, // blockDimX
    c_uint, // blockDimY
    c_uint, // blockDimZ
    c_uint, // sharedMemBytes
    CUstream, // stream
    ?[*]?*anyopaque, // kernelParams (array of pointers to each argument)
    ?[*]?*anyopaque, // extra
) callconv(.c) CUresult;

// ── NVRTC (runtime CUDA-C → PTX compilation) types ──
pub const NvrtcProgram = *anyopaque;
pub const NvrtcResult = c_int;
pub const NVRTC_SUCCESS: c_int = 0;
const NvrtcCreateProgramFn = *const fn (
    *NvrtcProgram,
    [*:0]const u8, // src
    ?[*:0]const u8, // name
    c_int, // numHeaders
    ?[*]const [*:0]const u8, // headers
    ?[*]const [*:0]const u8, // includeNames
) callconv(.c) NvrtcResult;
const NvrtcCompileProgramFn = *const fn (NvrtcProgram, c_int, ?[*]const [*:0]const u8) callconv(.c) NvrtcResult;
const NvrtcGetPtxSizeFn = *const fn (NvrtcProgram, *usize) callconv(.c) NvrtcResult;
const NvrtcGetPtxFn = *const fn (NvrtcProgram, [*]u8) callconv(.c) NvrtcResult;
const NvrtcGetProgramLogSizeFn = *const fn (NvrtcProgram, *usize) callconv(.c) NvrtcResult;
const NvrtcGetProgramLogFn = *const fn (NvrtcProgram, [*]u8) callconv(.c) NvrtcResult;
const NvrtcDestroyProgramFn = *const fn (*NvrtcProgram) callconv(.c) NvrtcResult;
const NvrtcGetCubinSizeFn = *const fn (NvrtcProgram, *usize) callconv(.c) NvrtcResult;
const NvrtcGetCubinFn = *const fn (NvrtcProgram, [*]u8) callconv(.c) NvrtcResult;

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
pub var fn_cuMemcpyHtoDAsync: ?CuMemcpyHtoDAsyncFn = null;
pub var fn_cuMemcpyDtoHAsync: ?CuMemcpyDtoHAsyncFn = null;
pub var fn_cuStreamCreate: ?CuStreamCreateFn = null;
pub var fn_cuStreamSync: ?CuStreamSyncFn = null;
pub var fn_cuStreamDestroy: ?CuStreamDestroyFn = null;
pub var fn_cuDevicePrimaryCtxRetain: ?CuDevicePrimaryCtxRetainFn = null;

// Custom-kernel driver function pointers (from nvcuda.dll)
pub var fn_cuModuleLoadData: ?CuModuleLoadDataFn = null;
pub var fn_cuModuleGetFunction: ?CuModuleGetFunctionFn = null;
pub var fn_cuModuleUnload: ?CuModuleUnloadFn = null;
pub var fn_cuLaunchKernel: ?CuLaunchKernelFn = null;

// NVRTC function pointers (from nvrtc64_*.dll)
var nvrtc_dll: ?*anyopaque = null;
var nvrtc_loaded: bool = false;
pub var fn_nvrtcCreateProgram: ?NvrtcCreateProgramFn = null;
pub var fn_nvrtcCompileProgram: ?NvrtcCompileProgramFn = null;
pub var fn_nvrtcGetPTXSize: ?NvrtcGetPtxSizeFn = null;
pub var fn_nvrtcGetPTX: ?NvrtcGetPtxFn = null;
pub var fn_nvrtcGetProgramLogSize: ?NvrtcGetProgramLogSizeFn = null;
pub var fn_nvrtcGetProgramLog: ?NvrtcGetProgramLogFn = null;
pub var fn_nvrtcDestroyProgram: ?NvrtcDestroyProgramFn = null;
pub var fn_nvrtcGetCUBINSize: ?NvrtcGetCubinSizeFn = null;
pub var fn_nvrtcGetCUBIN: ?NvrtcGetCubinFn = null;

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

/// Async host → device on the active stream (default stream when none is set).
/// Orders with cuBLAS calls on the same stream; does NOT block the host.
pub fn uploadAsync(dst: CUdeviceptr, src: *const anyopaque, size_bytes: usize) bool {
    if (fn_cuMemcpyHtoDAsync) |f| return f(dst, src, size_bytes, activeStream()) == CUDA_SUCCESS;
    return uploadToGpu(dst, src, size_bytes);
}

/// The active CUDA stream: the shared stream when set, else the default (null)
/// stream — cuBLAS uses the default stream too, so ordering holds.
fn activeStream() CUstream {
    return shared_stream orelse null;
}

/// Async device → host on the active stream. The copy is enqueued after any
/// pending cuBLAS work; call `syncActiveStream` before reading the destination.
pub fn downloadAsync(dst: *anyopaque, src: CUdeviceptr, size_bytes: usize) bool {
    if (fn_cuMemcpyDtoHAsync) |f| return f(dst, src, size_bytes, activeStream()) == CUDA_SUCCESS;
    return downloadFromGpu(dst, src, size_bytes);
}

/// True if async copy + explicit-sync is available (both async memcpy symbols
/// and the stream-sync symbol resolved).
pub fn asyncAvailable() bool {
    return fn_cuMemcpyHtoDAsync != null and fn_cuMemcpyDtoHAsync != null and fn_cuStreamSync != null;
}

/// Block the host until all work enqueued on the active stream completes. Works
/// for both an explicit shared stream and the default stream (0/null).
pub fn syncActiveStream() bool {
    if (fn_cuStreamSync) |sync| return sync(activeStream()) == CUDA_SUCCESS;
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
    fn_cuMemcpyHtoDAsync = @ptrCast(GetProcAddress(dll, "cuMemcpyHtoDAsync_v2"));
    fn_cuMemcpyDtoHAsync = @ptrCast(GetProcAddress(dll, "cuMemcpyDtoHAsync_v2"));
    fn_cuStreamCreate = @ptrCast(GetProcAddress(dll, "cuStreamCreate"));
    fn_cuStreamSync = @ptrCast(GetProcAddress(dll, "cuStreamSynchronize"));
    fn_cuStreamDestroy = @ptrCast(GetProcAddress(dll, "cuStreamDestroy_v2"));
    fn_cuDevicePrimaryCtxRetain = @ptrCast(GetProcAddress(dll, "cuDevicePrimaryCtxRetain"));

    // Custom-kernel launch (present on any modern driver; optional — a failure
    // to resolve simply leaves the custom-kernel path unavailable).
    fn_cuModuleLoadData = @ptrCast(GetProcAddress(dll, "cuModuleLoadData"));
    fn_cuModuleGetFunction = @ptrCast(GetProcAddress(dll, "cuModuleGetFunction"));
    fn_cuModuleUnload = @ptrCast(GetProcAddress(dll, "cuModuleUnload"));
    fn_cuLaunchKernel = @ptrCast(GetProcAddress(dll, "cuLaunchKernel"));

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

// ── Custom CUDA kernels: runtime NVRTC compile + module load + launch ──
//
// The driver-API launch symbols come from nvcuda.dll (loaded in
// loadCudaDriver). PTX is produced at runtime from CUDA-C source strings by
// NVRTC (nvrtc64_*.dll). Everything degrades gracefully: if any symbol or DLL
// is missing, `kernelsAvailable()` is false and callers stay on the CPU path.

// NVRTC DLL search order: bare name (on PATH via the toolkit bin), then the
// known CUDA v13.3 toolkit locations (full + 8.3 short path). Matches the
// cuBLAS loader's strategy.
fn loadNvrtc() bool {
    if (nvrtc_loaded) return true;
    nvrtc_dll = LoadLibraryA("nvrtc64_130_0.dll");
    if (nvrtc_dll == null)
        nvrtc_dll = LoadLibraryA("C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v13.3\\bin\\x64\\nvrtc64_130_0.dll");
    if (nvrtc_dll == null)
        nvrtc_dll = LoadLibraryA("C:\\PROGRA~1\\NVIDIA~2\\CUDA\\v13.3\\bin\\x64\\nvrtc64_130_0.dll");
    if (nvrtc_dll == null)
        nvrtc_dll = LoadLibraryA("nvrtc64_120_0.dll");
    if (nvrtc_dll == null) return false;

    const dll = nvrtc_dll.?;
    fn_nvrtcCreateProgram = @ptrCast(GetProcAddress(dll, "nvrtcCreateProgram"));
    fn_nvrtcCompileProgram = @ptrCast(GetProcAddress(dll, "nvrtcCompileProgram"));
    fn_nvrtcGetPTXSize = @ptrCast(GetProcAddress(dll, "nvrtcGetPTXSize"));
    fn_nvrtcGetPTX = @ptrCast(GetProcAddress(dll, "nvrtcGetPTX"));
    fn_nvrtcGetProgramLogSize = @ptrCast(GetProcAddress(dll, "nvrtcGetProgramLogSize"));
    fn_nvrtcGetProgramLog = @ptrCast(GetProcAddress(dll, "nvrtcGetProgramLog"));
    fn_nvrtcDestroyProgram = @ptrCast(GetProcAddress(dll, "nvrtcDestroyProgram"));
    fn_nvrtcGetCUBINSize = @ptrCast(GetProcAddress(dll, "nvrtcGetCUBINSize"));
    fn_nvrtcGetCUBIN = @ptrCast(GetProcAddress(dll, "nvrtcGetCUBIN"));

    if (fn_nvrtcCreateProgram == null or fn_nvrtcCompileProgram == null or
        fn_nvrtcGetPTXSize == null or fn_nvrtcGetPTX == null or
        fn_nvrtcDestroyProgram == null) return false;

    nvrtc_loaded = true;
    return true;
}

/// Ensure this thread has a current CUDA context. cuBLAS creates/binds a
/// primary context internally, but the raw driver API (cuModuleLoadData,
/// cuLaunchKernel) operates on the *thread's* current context — which may be
/// unset. If none is current, retain the primary context on device 0 and make
/// it current. Idempotent; returns true when a context is current afterward.
pub fn ensureContext() bool {
    // Fast path: a context is already current on this thread.
    if (fn_cuCtxGetCurrent) |getCurrent| {
        var ctx: CUcontext = undefined;
        if (getCurrent(&ctx) == CUDA_SUCCESS and @intFromPtr(ctx) != 0) return true;
    }
    // Retain + bind the device-0 primary context.
    const retain = fn_cuDevicePrimaryCtxRetain orelse return false;
    const setCurrent = fn_cuCtxSetCurrent orelse return false;
    const deviceGet = fn_cuDeviceGet orelse return false;
    var device: CUdevice = 0;
    if (deviceGet(&device, 0) != CUDA_SUCCESS) return false;
    var primary: CUcontext = undefined;
    if (retain(&primary, device) != CUDA_SUCCESS) return false;
    if (setCurrent(primary) != CUDA_SUCCESS) return false;
    shared_context = primary;
    return true;
}

/// True when the full custom-kernel pipeline is usable: driver launch symbols
/// resolved, a CUDA context is current, AND NVRTC is loaded. Callers gate their
/// GPU-kernel paths on this.
pub fn kernelsAvailable() bool {
    if (fn_cuModuleLoadData == null or fn_cuModuleGetFunction == null or fn_cuLaunchKernel == null)
        return false;
    if (!ensureContext()) return false;
    return loadNvrtc();
}

/// Compile a CUDA-C source string with NVRTC, targeting `arch`. When `arch` is
/// a real SM target ("sm_120") NVRTC produces a finished cubin (SASS) that the
/// driver loads directly — no PTX JIT, so it is immune to the
/// PTX-ISA-newer-than-driver problem (CUDA_ERROR_UNSUPPORTED_PTX_VERSION). When
/// `arch` is a virtual target ("compute_120") it produces PTX for JIT. `emit`
/// selects which artifact to fetch. Writes the artifact into `out` and returns
/// its byte length (PTX is NUL-terminated; cubin is a raw blob), or null. On a
/// compile error the NVRTC log is written into `log_out`.
pub const Artifact = enum { ptx, cubin };
pub fn compile(
    source: [*:0]const u8,
    arch: [*:0]const u8,
    emit: Artifact,
    out: []u8,
    log_out: []u8,
) ?usize {
    if (!loadNvrtc()) return null;
    const create = fn_nvrtcCreateProgram orelse return null;
    const compileProgram = fn_nvrtcCompileProgram orelse return null;
    const destroy = fn_nvrtcDestroyProgram orelse return null;

    var program: NvrtcProgram = undefined;
    if (create(&program, source, "sb0_kernel.cu", 0, null, null) != NVRTC_SUCCESS) return null;
    defer _ = destroy(&program);

    // --gpu-architecture selects the target; --use_fast_math is safe for the
    // elementwise / conv math we emit. Build the option string by hand (this
    // Sig std.fmt has no bufPrintZ).
    var arch_opt_buf: [64]u8 = undefined;
    const prefix = "--gpu-architecture=";
    @memcpy(arch_opt_buf[0..prefix.len], prefix);
    var w: usize = prefix.len;
    var a: usize = 0;
    while (arch[a] != 0 and w + 1 < arch_opt_buf.len) : (a += 1) {
        arch_opt_buf[w] = arch[a];
        w += 1;
    }
    arch_opt_buf[w] = 0;
    const arch_opt: [*:0]const u8 = @ptrCast(&arch_opt_buf);
    const options = [_][*:0]const u8{ arch_opt, "--use_fast_math" };
    const status = compileProgram(program, options.len, &options);
    if (status != NVRTC_SUCCESS) {
        if (fn_nvrtcGetProgramLogSize) |logSize| {
            if (fn_nvrtcGetProgramLog) |getLog| {
                var n: usize = 0;
                if (logSize(program, &n) == NVRTC_SUCCESS and n > 0 and log_out.len > 0) {
                    if (n > log_out.len) n = log_out.len;
                    _ = getLog(program, log_out.ptr);
                    log_out[@min(n, log_out.len - 1)] = 0;
                }
            }
        }
        return null;
    }

    switch (emit) {
        .ptx => {
            const ptxSize = fn_nvrtcGetPTXSize orelse return null;
            const getPtx = fn_nvrtcGetPTX orelse return null;
            var size: usize = 0;
            if (ptxSize(program, &size) != NVRTC_SUCCESS) return null;
            if (size == 0 or size > out.len) return null;
            if (getPtx(program, out.ptr) != NVRTC_SUCCESS) return null;
            return size;
        },
        .cubin => {
            const cubinSize = fn_nvrtcGetCUBINSize orelse return null;
            const getCubin = fn_nvrtcGetCUBIN orelse return null;
            var size: usize = 0;
            if (cubinSize(program, &size) != NVRTC_SUCCESS) return null;
            if (size == 0 or size > out.len) return null;
            if (getCubin(program, out.ptr) != NVRTC_SUCCESS) return null;
            return size;
        },
    }
}

/// Back-compat convenience: compile straight to PTX text.
pub fn compileToPtx(source: [*:0]const u8, arch: [*:0]const u8, ptx_out: []u8, log_out: []u8) ?usize {
    return compile(source, arch, .ptx, ptx_out, log_out);
}

/// The CUresult from the most recent loadModule call (for diagnostics).
pub var last_module_load_result: CUresult = 0;

/// Load a compiled PTX/cubin image into a CUDA module. `image` must be a
/// NUL-terminated PTX text (or a cubin blob). Returns the module or null.
pub fn loadModule(image: *const anyopaque) ?CUmodule {
    const load = fn_cuModuleLoadData orelse return null;
    var module: CUmodule = undefined;
    last_module_load_result = load(&module, image);
    if (last_module_load_result != CUDA_SUCCESS) return null;
    return module;
}

/// Resolve a `__global__` kernel by name inside a loaded module.
pub fn getFunction(module: CUmodule, name: [*:0]const u8) ?CUfunction {
    const get = fn_cuModuleGetFunction orelse return null;
    var function: CUfunction = undefined;
    if (get(&function, module, name) != CUDA_SUCCESS) return null;
    return function;
}

/// Unload a module (frees its device code). Safe to call with an already-freed
/// handle only once.
pub fn unloadModule(module: CUmodule) void {
    if (fn_cuModuleUnload) |unload| _ = unload(module);
}

/// Launch a kernel on the active stream. `params` is an array of pointers, one
/// per kernel argument (the driver copies argument bytes by dereferencing each
/// pointer). `shared_bytes` is dynamic shared memory. Returns true on a
/// successful *enqueue* (not completion — call syncActiveStream to wait).
pub fn launchKernel(
    function: CUfunction,
    grid_x: u32,
    block_x: u32,
    shared_bytes: u32,
    params: []?*anyopaque,
) bool {
    const launch = fn_cuLaunchKernel orelse return false;
    return launch(
        function,
        grid_x,
        1,
        1,
        block_x,
        1,
        1,
        shared_bytes,
        activeStream(),
        if (params.len == 0) null else params.ptr,
        null,
    ) == CUDA_SUCCESS;
}

/// End-to-end smoke test of the custom-kernel pipeline on the live GPU:
/// compile a SiLU kernel, upload a small vector, launch, download, and verify
/// the result against the CPU reference. Returns true only if every stage
/// succeeded AND the numbers match. Safe to call on a machine with no GPU
/// (returns false). Used by the kernel_probe harness, not in production decode.
pub fn selfTest() bool {
    return selfTestDiag(null) == 0;
}

/// Same as selfTest but returns a stage code so a harness can see WHERE it
/// failed: 0 = pass, 1 = init, 2 = kernelsAvailable, 3 = compile, 4 = loadModule,
/// 5 = getFunction, 6 = alloc, 7 = upload, 8 = launch, 9 = sync, 10 = download,
/// 11 = wrong result. When `log_out` is non-null it receives the NVRTC compile
/// log on a stage-3 failure.
pub fn selfTestDiag(log_out: ?[]u8) u32 {
    if (!init()) return 1;
    if (!kernelsAvailable()) return 2;

    const src =
        \\extern "C" __global__ void silu(const float* x, float* y, int n) {
        \\  int i = blockIdx.x * blockDim.x + threadIdx.x;
        \\  if (i < n) { float v = x[i]; y[i] = v / (1.0f + __expf(-v)); }
        \\}
    ;
    var image: [256 * 1024]u8 = undefined;
    var log: [8 * 1024]u8 = @splat(0);
    // Emit a finished cubin for the real SM target so the driver never has to
    // JIT PTX (dodges CUDA_ERROR_UNSUPPORTED_PTX_VERSION with a toolkit newer
    // than the installed driver).
    const image_len = compile(src, "sm_120", .cubin, &image, &log) orelse {
        if (log_out) |dst| {
            const n = @min(dst.len, log.len);
            @memcpy(dst[0..n], log[0..n]);
        }
        return 3;
    };
    if (image_len == 0) return 3;
    const module = loadModule(&image) orelse return 4;
    defer unloadModule(module);
    const function = getFunction(module, "silu") orelse return 5;

    const N: usize = 256;
    var host_in: [N]f32 = undefined;
    var host_out: [N]f32 = @splat(0);
    for (&host_in, 0..) |*v, i| v.* = (@as(f32, @floatFromInt(i)) - 128.0) * 0.05;

    const d_in = gpuAlloc(N * 4);
    const d_out = gpuAlloc(N * 4);
    if (d_in == 0 or d_out == 0) {
        gpuFree(d_in);
        gpuFree(d_out);
        return 6;
    }
    defer gpuFree(d_in);
    defer gpuFree(d_out);

    if (!uploadToGpu(d_in, &host_in, N * 4)) return 7;
    var n_arg: c_int = @intCast(N);
    var p_in: CUdeviceptr = d_in;
    var p_out: CUdeviceptr = d_out;
    var params = [_]?*anyopaque{ &p_in, &p_out, &n_arg };
    const block: u32 = 128;
    const grid: u32 = (@as(u32, N) + block - 1) / block;
    if (!launchKernel(function, grid, block, 0, &params)) return 8;
    if (!syncActiveStream()) return 9;
    if (!downloadFromGpu(&host_out, d_out, N * 4)) return 10;

    for (host_in, host_out) |x, got| {
        const want = x / (1.0 + @exp(-x));
        if (@abs(got - want) > 1e-3) return 11;
    }
    return 0;
}
