// @zpm/llm — GPU-Resident Inference Engine
// Full transformer forward pass on GPU: all matmuls via cuBLAS with device pointers.
//
// Memory layout (all in VRAM):
//   d_hidden[hidden_size]        — current hidden state (persists across layers)
//   d_kv_k[n_layers][max_seq][kv_dim]  — K cache on GPU
//   d_kv_v[n_layers][max_seq][kv_dim]  — V cache on GPU
//   d_weight[max_weight_elements] — scratch for one weight matrix (reused per-layer)
//   d_scratch[hidden_size]       — intermediate computation buffer
//   d_q/k/v[max_dim]            — Q/K/V projection outputs
//   d_attn_out[max_dim]         — attention output
//   d_mlp_gate/up[intermediate] — MLP intermediates
//
// Flow per token:
//   1. embedToken: dequant embedding row on CPU, upload to d_hidden
//   2. For each layer:
//      a. Download d_hidden → CPU for RMSNorm (small, fast)
//      b. Dequant Q weight → upload d_weight → cublasSgemm(d_weight, d_hidden, d_q)
//      c. Same for K, V, O, gate, up, down projections
//      d. Attention: dot products + softmax on CPU (seq_len is small during decode)
//      e. Upload results back to d_hidden
//   3. Final norm + logits: row-by-row on CPU (vocab is huge, one-time)
//
// Optimization: during single-token decode (prefill done), seq_len is small
// so attention is cheap on CPU. The expensive part is the 7 matmuls per layer
// which are fully on GPU via cuBLAS.
//
// For Qwen3-VL-2B on RTX 5070:
//   hidden=2048, intermediate=6144, 28 layers
//   Largest matmul: 6144×2048 = 12.5M elements = 48MB per weight upload
//   cuBLAS TF32 throughput on Blackwell: ~200 TFLOPS
//   Expected: ~2ms per layer → ~56ms per token → ~14 tokens/sec

const std = @import("std");
const decoder = @import("decoder.sig");
const gguf_loader = @import("gguf_loader.sig");
const quantize = @import("quantize.sig");
const cuda = @import("../matmul/cuda.sig");

// ── GPU memory state ──
const CUdeviceptr = cuda.CUdeviceptr;

// Device buffers (persistent across tokens)
var d_hidden: CUdeviceptr = 0; // [hidden_size] f32
var d_norm_out: CUdeviceptr = 0; // [hidden_size] f32
var d_q: CUdeviceptr = 0; // [n_heads * head_dim] f32
var d_k: CUdeviceptr = 0; // [kv_dim] f32
var d_v: CUdeviceptr = 0; // [kv_dim] f32
var d_attn_out: CUdeviceptr = 0; // [hidden_size] f32
var d_mlp_gate: CUdeviceptr = 0; // [intermediate] f32
var d_mlp_up: CUdeviceptr = 0; // [intermediate] f32
var d_mlp_out: CUdeviceptr = 0; // [hidden_size] f32

// Weight upload buffer (reused for each weight matrix)
var d_weight: CUdeviceptr = 0; // [max_weight_elements] f32

// Norm weight buffer (small, uploaded per-layer)
var d_norm_w: CUdeviceptr = 0; // [hidden_size] f32

// CPU-side staging buffers for dequant
const MAX_WEIGHT_ELEMENTS: usize = 6144 * 2048; // 12.5M floats = 48MB
const MAX_HIDDEN: usize = 16384;
const MAX_INTERMEDIATE: usize = 65536;

// CPU staging (VirtualAlloc)
var h_weight_staging: ?[*]f32 = null; // dequant target, then upload
var h_hidden: [MAX_HIDDEN]f32 = @splat(0.0); // download hidden for norm/attention
var h_norm_out: [MAX_HIDDEN]f32 = @splat(0.0);
var h_q: [MAX_HIDDEN]f32 = @splat(0.0);
var h_k: [MAX_HIDDEN]f32 = @splat(0.0);
var h_v: [MAX_HIDDEN]f32 = @splat(0.0);
var h_attn_scores: [decoder.MAX_SEQ]f32 = @splat(0.0);
var h_attn_out: [MAX_HIDDEN]f32 = @splat(0.0);
var h_norm_w: [MAX_HIDDEN]f32 = @splat(0.0);
var h_emb_row: [MAX_HIDDEN]f32 = @splat(0.0);
var h_logit_row: [MAX_HIDDEN]f32 = @splat(0.0);

// ── Persistent dequanted weight cache ──
// Strategy: dequant Q4_K → f32 on CPU, upload ONCE to GPU VRAM.
// Then per-token inference just references device pointers — ZERO PCIe during compute.
// Memory: ~5.2 GB VRAM for 28 layers × 7 projections (f32).
// After whisper finishes (frees ~1.6 GB VRAM), we have enough on 8 GB card.
// Using F32 (not F16) for correctness — cuBLAS Sgemm is proven and no precision issues.
const MAX_LAYERS: usize = 64;
const N_PROJ: usize = 7; // q, k, v, o, gate, up, down

// GPU-RESIDENT weight buffers (allocated once, never freed during inference)
var d_layer_weights: [MAX_LAYERS][N_PROJ]CUdeviceptr = @splat(@splat(0));
var d_layer_weight_sizes: [MAX_LAYERS][N_PROJ]usize = @splat(@splat(0));
var weights_preloaded: bool = false;

// CPU staging for f16 conversion (reused, max 12.5M × 2 bytes = 25 MB)
var h_f16_staging: ?[*]u16 = null;

// Static buffers for gpuForwardLayer (too large for stack, reused per-layer)
var s_gate: [MAX_INTERMEDIATE]f32 = @splat(0.0);
var s_up: [MAX_INTERMEDIATE]f32 = @splat(0.0);
var s_residual: [MAX_HIDDEN]f32 = @splat(0.0);
// Static buffers for computeAttention (8192 seq × 256 kv_dim = 8MB each — must NOT be on stack)
var s_kv_k_buf: [8192 * 256]f32 = @splat(0.0);
var s_kv_v_buf: [8192 * 256]f32 = @splat(0.0);

// KV cache on GPU
var d_kv_k: CUdeviceptr = 0; // [n_layers * max_seq * kv_dim] f32
var d_kv_v: CUdeviceptr = 0; // same
var kv_seq_len: usize = 0;
var kv_n_layers: usize = 0;
var kv_max_seq: usize = 0;
var kv_dim: usize = 0;

var gpu_initialized: bool = false;

// Win32 for CPU staging buffer
extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) ?[*]u8;
extern "kernel32" fn VirtualFree(?*anyopaque, usize, u32) c_int;
extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn GetFileSize(?*anyopaque, ?*u32) u32;
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn CreateFileMappingA(?*anyopaque, ?*anyopaque, u32, u32, u32, ?[*:0]const u8) ?*anyopaque;
extern "kernel32" fn MapViewOfFile(?*anyopaque, u32, u32, u32, usize) ?[*]u8;
extern "kernel32" fn UnmapViewOfFile([*]const u8) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

/// Initialize GPU inference engine. Allocates all device buffers.
/// Call after CUDA context is ready.
pub fn init(cfg: decoder.DecoderConfig) bool {
    if (gpu_initialized) return true;
    if (!cuda.isAvailable()) return false;

    const hidden = cfg.hidden_size;
    const kv_d = cfg.kvDim();
    const intermediate = cfg.intermediate_size;
    const n_layers = cfg.n_layers;
    const max_seq = cfg.max_seq_len;

    // Allocate device buffers
    d_hidden = cuda.gpuAlloc(hidden * 4);
    d_norm_out = cuda.gpuAlloc(hidden * 4);
    d_q = cuda.gpuAlloc(hidden * 4); // n_heads * head_dim = hidden
    d_k = cuda.gpuAlloc(kv_d * 4);
    d_v = cuda.gpuAlloc(kv_d * 4);
    d_attn_out = cuda.gpuAlloc(hidden * 4);
    d_mlp_gate = cuda.gpuAlloc(intermediate * 4);
    d_mlp_up = cuda.gpuAlloc(intermediate * 4);
    d_mlp_out = cuda.gpuAlloc(hidden * 4);
    d_weight = cuda.gpuAlloc(MAX_WEIGHT_ELEMENTS * 4);
    d_norm_w = cuda.gpuAlloc(hidden * 4);

    // KV cache on GPU
    const kv_layer_bytes = max_seq * kv_d * 4;
    d_kv_k = cuda.gpuAlloc(n_layers * kv_layer_bytes);
    d_kv_v = cuda.gpuAlloc(n_layers * kv_layer_bytes);

    // Verify all allocations
    if (d_hidden == 0 or d_norm_out == 0 or d_q == 0 or d_k == 0 or d_v == 0 or
        d_attn_out == 0 or d_mlp_gate == 0 or d_mlp_up == 0 or d_mlp_out == 0 or
        d_weight == 0 or d_norm_w == 0 or d_kv_k == 0 or d_kv_v == 0)
    {
        deinit();
        return false;
    }

    // CPU staging buffer for weight dequant
    const staging_mem = VirtualAlloc(null, MAX_WEIGHT_ELEMENTS * 4, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (staging_mem) |m| {
        h_weight_staging = @ptrCast(@alignCast(m));
    } else {
        deinit();
        return false;
    }

    kv_seq_len = 0;
    kv_n_layers = n_layers;
    kv_max_seq = max_seq;
    kv_dim = kv_d;
    gpu_initialized = true;
    return true;
}

/// Free all GPU resources.
pub fn deinit() void {
    cuda.gpuFree(d_hidden); d_hidden = 0;
    cuda.gpuFree(d_norm_out); d_norm_out = 0;
    cuda.gpuFree(d_q); d_q = 0;
    cuda.gpuFree(d_k); d_k = 0;
    cuda.gpuFree(d_v); d_v = 0;
    cuda.gpuFree(d_attn_out); d_attn_out = 0;
    cuda.gpuFree(d_mlp_gate); d_mlp_gate = 0;
    cuda.gpuFree(d_mlp_up); d_mlp_up = 0;
    cuda.gpuFree(d_mlp_out); d_mlp_out = 0;
    cuda.gpuFree(d_weight); d_weight = 0;
    cuda.gpuFree(d_norm_w); d_norm_w = 0;
    cuda.gpuFree(d_kv_k); d_kv_k = 0;
    cuda.gpuFree(d_kv_v); d_kv_v = 0;
    if (h_weight_staging) |s| {
        _ = VirtualFree(@ptrCast(s), 0, MEM_RELEASE);
        h_weight_staging = null;
    }
    gpu_initialized = false;
}

/// Reset KV cache for new generation.
pub fn resetKV() void {
    kv_seq_len = 0;
}

/// Check if GPU inference is available.
pub fn isReady() bool {
    return gpu_initialized;
}

/// GPU matvec: out_device = weight_device @ in_device
/// Uses cuBLAS cublasSgemm with device pointers.
/// beta=0 (overwrite, not accumulate) for projection matmuls.
fn gpuMatvec(d_out: CUdeviceptr, d_w: CUdeviceptr, d_in: CUdeviceptr, n: usize, k: usize) void {
    // cublasSgemm: C = alpha * op(A) * op(B) + beta * C
    // We want: out[N] = W[N,K] @ in[K] (matvec, M=1)
    // In cuBLAS column-major: C[1×N] = in[1×K] @ W^T[K×N]
    // So: transa=N, transb=T, m=N, n=1, k=K
    const alpha: f32 = 1.0;
    const beta: f32 = 0.0;

    if (cuda.fn_cublasSgemm) |sgemm| {
        _ = sgemm(
            cuda.cublas_handle.?,
            .N, .T,
            @intCast(n), 1, @intCast(k),
            &alpha,
            // B = W[N,K] not transposed in cuBLAS col-major = W^T in row-major
            @ptrFromInt(d_w), @intCast(k),
            // A = in[1,K]
            @ptrFromInt(d_in), @intCast(k),
            &beta,
            @ptrFromInt(d_out), @intCast(n),
        );
    }
}

/// GPU matvec with resident weight matrix (F32 on GPU).
/// Uses cublasSgemm — proven, correct, no mixed-precision edge cases.
/// Synchronizes stream after dispatch to ensure results are ready for download.
fn gpuMatvecResident(d_out: CUdeviceptr, d_w: CUdeviceptr, d_in: CUdeviceptr, n: usize, k: usize) void {
    const alpha: f32 = 1.0;
    const beta: f32 = 0.0;

    if (cuda.fn_cublasSgemm) |sgemm| {
        // out[N] = W[N,K] @ in[K]
        // W uploaded in row-major [N,K] layout.
        // cuBLAS is column-major, so W looks like a [K,N] matrix to cuBLAS.
        // We want C[N,1] = W[N,K] * x[K,1] in row-major.
        // In cuBLAS col-major: C = A^T * B where A=[K,N] (our row-major W), A^T=[N,K]
        // m=N, n=1, k=K, transa=T, transb=N
        // lda = K (leading dim of A which is stored as [K rows, N cols] in col-major)
        // ldb = K (leading dim of B which is [K,1])
        // ldc = N (leading dim of C which is [N,1])
        const status = sgemm(
            cuda.cublas_handle.?,
            .T, .N,
            @intCast(n), 1, @intCast(k),
            &alpha,
            @ptrFromInt(d_w), @intCast(k),
            @ptrFromInt(d_in), @intCast(k),
            &beta,
            @ptrFromInt(d_out), @intCast(n),
        );
        if (status != cuda.CUBLAS_STATUS_SUCCESS) {
            // Log error to stderr for diagnostics
            const err_handle = GetStdHandle(STD_ERROR_HANDLE);
            const msg = "cuBLAS Sgemm FAILED\n";
            _ = WriteFile(err_handle, msg.ptr, @intCast(msg.len), null, null);
        }
    }
    cuda.syncStream();
}

/// Upload f32 data from CPU to GPU device pointer.
fn upload(dst: CUdeviceptr, src: [*]const f32, n_floats: usize) void {
    _ = cuda.uploadToGpu(dst, @ptrCast(src), n_floats * 4);
}

/// Download f32 data from GPU to CPU.
fn download(dst: [*]f32, src: CUdeviceptr, n_floats: usize) void {
    _ = cuda.downloadFromGpu(@ptrCast(dst), src, n_floats * 4);
}

/// Dequant a weight matrix to CPU staging, then upload to d_weight.
fn dequantAndUpload(
    src: ?[*]const u8,
    qtype: gguf_loader.GGMLType,
    n_elements: usize,
) void {
    const staging = h_weight_staging orelse return;
    if (src == null) {
        @memset(staging[0..n_elements], 0.0);
    } else {
        dequantInto(src.?, qtype, n_elements, staging);
    }
    upload(d_weight, staging, n_elements);
}

/// Use GPU-resident weight for matmul — ZERO PCIe transfer during inference.
/// If weights are preloaded, returns the device pointer directly.
/// Otherwise falls back to dequant+upload (slow path).
fn getWeightDevicePtr(layer: usize, proj_idx: usize, src: ?[*]const u8, qtype: gguf_loader.GGMLType, n_elements: usize) CUdeviceptr {
    if (weights_preloaded and d_layer_weights[layer][proj_idx] != 0) {
        return d_layer_weights[layer][proj_idx];
    }
    // Fallback: dequant to staging, upload to d_weight scratch
    dequantAndUpload(src, qtype, n_elements);
    return d_weight;
}

/// Pre-dequant all layer weights to F32, upload ONCE to GPU VRAM.
/// Called once after model load. After this, inference is pure GPU compute.
/// Supports F32 disk cache (.gotliv/weights_f32.bin) to skip dequant on repeat runs.
pub fn preloadWeights(model: *const gguf_loader.LoadedModel, cfg: decoder.DecoderConfig) bool {
    if (weights_preloaded) return true;
    const hidden = cfg.hidden_size;
    const kv_d = cfg.kvDim();
    const n_heads = cfg.n_heads;
    const head_dim = cfg.head_dim;
    const intermediate = cfg.intermediate_size;

    // Compute total F32 bytes for all weight matrices
    const layer_sizes = [N_PROJ]usize{
        n_heads * head_dim * hidden, // q
        kv_d * hidden, // k
        kv_d * hidden, // v
        hidden * n_heads * head_dim, // o
        intermediate * hidden, // gate
        intermediate * hidden, // up
        hidden * intermediate, // down
    };
    var total_f32_bytes: usize = 0;
    for (layer_sizes) |s| total_f32_bytes += s * 4;
    total_f32_bytes *= cfg.n_layers;

    // Try to mmap the F32 weight cache
    const CACHE_PATH = ".gotliv\\weights_f32.bin\x00";
    const INVALID_HV: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    const cache_h = CreateFileA(@ptrCast(CACHE_PATH), 0x80000000, 1, null, 3, 0x80, null); // GENERIC_READ, OPEN_EXISTING

    var cache_base: ?[*]u8 = null;
    var cache_mapping: ?*anyopaque = null;
    var using_cache = false;

    if (cache_h != INVALID_HV and cache_h != null) {
        // Verify file size matches expected
        var size_high: u32 = 0;
        const size_low = GetFileSize(cache_h.?, &size_high);
        const file_size = (@as(usize, size_high) << 32) | @as(usize, size_low);
        if (file_size == total_f32_bytes) {
            // Mmap the cache file
            cache_mapping = CreateFileMappingA(cache_h.?, null, 0x02, 0, 0, null); // PAGE_READONLY
            if (cache_mapping != null) {
                cache_base = @ptrCast(MapViewOfFile(cache_mapping.?, 0x0004, 0, 0, 0)); // FILE_MAP_READ
                if (cache_base != null) {
                    using_cache = true;
                    const oh = GetStdHandle(STD_ERROR_HANDLE);
                    const msg = "  Weight cache: mmap'd from disk\n";
                    _ = WriteFile(oh, msg.ptr, @intCast(msg.len), null, null);
                }
            }
        }
        if (!using_cache) _ = CloseHandle(cache_h.?);
    }

    // Allocate CPU staging (only needed if no cache)
    if (!using_cache) {
        if (h_weight_staging == null) {
            const f32_mem = VirtualAlloc(null, MAX_WEIGHT_ELEMENTS * 4, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (f32_mem == null) return false;
            h_weight_staging = @ptrCast(@alignCast(f32_mem.?));
        }
    }

    // Also allocate a write buffer for saving cache (only on first run)
    var cache_write_h: ?*anyopaque = null;
    if (!using_cache) {
        cache_write_h = CreateFileA(@ptrCast(CACHE_PATH), 0x40000000, 0, null, 2, 0x80, null); // GENERIC_WRITE, CREATE_ALWAYS
        if (cache_write_h == INVALID_HV) cache_write_h = null;
    }

    var cache_offset: usize = 0;

    for (0..cfg.n_layers) |li| {
        const lw = &model.weights.layers[li];
        const srcs = [N_PROJ]?[*]const u8{ lw.q_proj, lw.k_proj, lw.v_proj, lw.o_proj, lw.gate_proj, lw.up_proj, lw.down_proj };
        const qtypes = [N_PROJ]gguf_loader.GGMLType{ lw.q_proj_type, lw.k_proj_type, lw.v_proj_type, lw.o_proj_type, lw.gate_proj_type, lw.up_proj_type, lw.down_proj_type };

        for (0..N_PROJ) |pi| {
            const n_el = layer_sizes[pi];
            const gpu_bytes = n_el * 4;

            const dptr = cuda.gpuAlloc(gpu_bytes);
            if (dptr == 0) return false;

            if (using_cache) {
                // Upload directly from mmap'd cache
                if (!cuda.uploadToGpu(dptr, @ptrCast(cache_base.? + cache_offset), gpu_bytes)) return false;
            } else {
                // Dequant to staging, upload, and write to cache file
                const f32_buf = h_weight_staging.?;
                if (srcs[pi]) |src_ptr| {
                    dequantInto(src_ptr, qtypes[pi], n_el, f32_buf);
                } else {
                    @memset(f32_buf[0..n_el], 0.0);
                }
                if (!cuda.uploadToGpu(dptr, @ptrCast(f32_buf), gpu_bytes)) return false;
                // Write to cache file
                if (cache_write_h) |wh| {
                    _ = WriteFile(wh, @ptrCast(f32_buf), @intCast(gpu_bytes), null, null);
                }
            }
            cuda.syncStream();

            // Verify first matrix upload
            if (li == 0 and pi == 0) {
                var verify_buf: [4]f32 = .{ 0, 0, 0, 0 };
                _ = cuda.downloadFromGpu(@ptrCast(&verify_buf), dptr, 16);
                cuda.syncStream();
                if (verify_buf[0] == 0.0 and verify_buf[1] == 0.0 and verify_buf[2] == 0.0 and verify_buf[3] == 0.0) {
                    const err_handle = GetStdHandle(STD_ERROR_HANDLE);
                    const msg2 = "GPU weight upload verification FAILED (zeros)\n";
                    _ = WriteFile(err_handle, msg2.ptr, @intCast(msg2.len), null, null);
                    weights_preloaded = false;
                    return false;
                }
            }

            d_layer_weights[li][pi] = dptr;
            d_layer_weight_sizes[li][pi] = n_el;
            cache_offset += gpu_bytes;
        }
    }

    // Cleanup
    if (cache_write_h) |wh| _ = CloseHandle(wh);
    if (using_cache) {
        if (cache_base) |b| _ = UnmapViewOfFile(b);
        if (cache_mapping) |m| _ = CloseHandle(m);
        _ = CloseHandle(cache_h.?);
    }

    weights_preloaded = true;
    return true;
}

/// Dequant into a CPU buffer.
fn dequantInto(src: [*]const u8, qtype: gguf_loader.GGMLType, n_elements: usize, dst: [*]f32) void {
    switch (qtype) {
        .f32 => {
            const f32_ptr: [*]const f32 = @ptrCast(@alignCast(src));
            @memcpy(dst[0..n_elements], f32_ptr[0..n_elements]);
        },
        .f16 => {
            for (0..n_elements) |i| {
                const h: u16 = @as(u16, src[i * 2]) | (@as(u16, src[i * 2 + 1]) << 8);
                dst[i] = quantize.f16ToF32(h);
            }
        },
        .q8_0 => quantize.dequantQ8_0(src, dst, n_elements),
        .q4_k => quantize.dequantQ4_K(src, dst, n_elements),
        else => @memset(dst[0..n_elements], 0.0),
    }
}

/// Full forward pass on GPU: token_id → next_token_id (greedy).
/// Matmuls on GPU (cuBLAS F16), attention + norms on CPU.
/// KV cache stays on CPU to avoid PCIe bottleneck during attention.
pub fn forward(
    token_id: u32,
    model: *const gguf_loader.LoadedModel,
    kv: *decoder.KVCache,
    cfg: decoder.DecoderConfig,
) u32 {
    if (!gpu_initialized) return 0;
    const hidden_size = cfg.hidden_size;
    const pos = kv.seq_len;

    // 1. Embed token: dequant row → upload to d_hidden
    embedTokenGpu(token_id, model, cfg);

    // Diagnostic: verify embedding uploaded correctly (first call only)
    if (pos == 0) {
        download(&h_hidden, d_hidden, hidden_size);
        if (h_hidden[0] == 0.0 and h_hidden[1] == 0.0 and h_hidden[2] == 0.0) {
            return 0;
        }
        // Diagnostic: test argmax directly on embedding (skip layers)
        // If this produces a non-! token, embedding + argmax work correctly
        dequantNormTo(model.weights.output_norm, hidden_size, &h_norm_w);
        decoder.rmsNorm(&h_hidden, &h_norm_out, &h_norm_w, hidden_size, cfg.rms_eps);
        const diag_token = computeArgmaxCpu(&h_norm_out, model, cfg);
        // Print the diagnostic token ID as decimal
        const oh = GetStdHandle(STD_ERROR_HANDLE);
        const msg1 = "  [GPU diag] embed->argmax token=";
        _ = WriteFile(oh, msg1.ptr, @intCast(msg1.len), null, null);
        var tbuf: [10]u8 = undefined;
        var tval: u32 = diag_token;
        var tlen: usize = 0;
        if (tval == 0) { tbuf[0] = '0'; tlen = 1; } else {
            while (tval > 0) : (tlen += 1) { tbuf[tlen] = @intCast((tval % 10) + '0'); tval /= 10; }
            // reverse
            var lo: usize = 0;
            var hi: usize = tlen - 1;
            while (lo < hi) { const tmp = tbuf[lo]; tbuf[lo] = tbuf[hi]; tbuf[hi] = tmp; lo += 1; hi -= 1; }
        }
        _ = WriteFile(oh, &tbuf, @intCast(tlen), null, null);
        const nl = "\n";
        _ = WriteFile(oh, nl.ptr, 1, null, null);
    }

    // 2. Forward through all layers (GPU matmul + CPU attention)
    for (0..cfg.n_layers) |layer_idx| {
        gpuForwardLayer(layer_idx, pos, model, kv, cfg);
    }

    // 3. Advance KV cache position
    kv.advance();

    // 4. Output norm (on CPU — small vector op)
    download(&h_hidden, d_hidden, hidden_size);
    dequantNormTo(model.weights.output_norm, hidden_size, &h_norm_w);
    decoder.rmsNorm(&h_hidden, &h_norm_out, &h_norm_w, hidden_size, cfg.rms_eps);

    // 5. Argmax
    const result_token = computeArgmaxCpu(&h_norm_out, model, cfg);

    // Diagnostic: print post-layer argmax on first token only
    if (pos == 0) {
        const oh2 = GetStdHandle(STD_ERROR_HANDLE);
        const msg2 = "  [GPU diag] post-layers token=";
        _ = WriteFile(oh2, msg2.ptr, @intCast(msg2.len), null, null);
        var tbuf2: [10]u8 = undefined;
        var tv2: u32 = result_token;
        var tl2: usize = 0;
        if (tv2 == 0) { tbuf2[0] = '0'; tl2 = 1; } else {
            while (tv2 > 0) : (tl2 += 1) { tbuf2[tl2] = @intCast((tv2 % 10) + '0'); tv2 /= 10; }
            var a: usize = 0; var b: usize = tl2 - 1;
            while (a < b) { const t = tbuf2[a]; tbuf2[a] = tbuf2[b]; tbuf2[b] = t; a += 1; b -= 1; }
        }
        _ = WriteFile(oh2, &tbuf2, @intCast(tl2), null, null);
        _ = WriteFile(oh2, "\n".ptr, 1, null, null);
    }

    return result_token;
}

/// Embed token: dequant one row from embedding matrix, upload to GPU.
fn embedTokenGpu(token_id: u32, model: *const gguf_loader.LoadedModel, cfg: decoder.DecoderConfig) void {
    const hidden_size = cfg.hidden_size;
    const emb_ptr = model.weights.token_embd orelse return;
    const emb_type = model.weights.token_embd_type;

    const be = emb_type.blockElems();
    const bb = emb_type.blockBytes();
    const row_bytes = if (be > 0) ((hidden_size + be - 1) / be) * bb else hidden_size * 4;
    const offset = @as(usize, token_id) * row_bytes;

    dequantInto(emb_ptr + offset, emb_type, hidden_size, &h_emb_row);
    upload(d_hidden, &h_emb_row, hidden_size);
}

/// Dequant a norm weight vector into CPU buffer.
fn dequantNormTo(src: ?[*]const u8, n: usize, dst: [*]f32) void {
    if (src == null) {
        for (0..n) |i| dst[i] = 1.0;
        return;
    }
    const f32_ptr: [*]const f32 = @ptrCast(@alignCast(src.?));
    @memcpy(dst[0..n], f32_ptr[0..n]);
}

/// Argmax over vocab logits using fused quantized matvec.
/// Instead of row-by-row dequant (151K iterations), compute all logits at once
/// via the fused Q4_K matvec (AVX2 SIMD). Then find the max.
/// Uses a static buffer for the logits (151936 × 4 = ~592 KB).
var s_logits: [152000]f32 = @splat(0.0); // slightly oversized for alignment

fn computeArgmaxCpu(
    normed: [*]const f32,
    model: *const gguf_loader.LoadedModel,
    cfg: decoder.DecoderConfig,
) u32 {
    const hidden_size = cfg.hidden_size;
    const vocab_size = cfg.vocab_size;
    const out_ptr = model.weights.output_w orelse return 0;
    const out_type = model.weights.output_w_type;

    // Compute logits via row-by-row dequant + dot product.
    // For each vocab token v: logit[v] = output_w[v, :] · normed[:]
    // This avoids the broken fused Q4_K path and uses proven dequantInto.
    const be = out_type.blockElems();
    const bb = out_type.blockBytes();
    const row_blocks = if (be > 0) ((hidden_size + be - 1) / be) else hidden_size;
    const row_bytes = row_blocks * bb;

    // Dequant buffer for one row (hidden_size floats ≤ 16K × 4 = 64KB stack)
    var row_buf: [MAX_HIDDEN]f32 = undefined;

    var best_token: u32 = 0;
    var best_score: f32 = -1.0e30;

    for (0..vocab_size) |v| {
        const row_ptr = out_ptr + v * row_bytes;
        dequantInto(row_ptr, out_type, hidden_size, &row_buf);

        // Dot product
        var dot: f32 = 0.0;
        for (0..hidden_size) |i| {
            dot += row_buf[i] * normed[i];
        }

        if (dot > best_score) {
            best_score = dot;
            best_token = @intCast(v);
        }
    }
    return best_token;
}

/// Forward one layer on GPU.
/// Pattern: GPU matmul for projections, CPU for attention + norms.
/// KV cache is CPU-resident (avoids PCIe round-trip per attention step).
fn gpuForwardLayer(
    layer_idx: usize,
    pos: usize,
    model: *const gguf_loader.LoadedModel,
    kv: *decoder.KVCache,
    cfg: decoder.DecoderConfig,
) void {
    const lw = &model.weights.layers[layer_idx];
    const hidden_size = cfg.hidden_size;
    const n_heads = cfg.n_heads;
    const n_kv_heads = cfg.n_kv_heads;
    const head_dim = cfg.head_dim;
    const kv_d = cfg.kvDim();
    const intermediate = cfg.intermediate_size;
    const gqa_ratio = n_heads / n_kv_heads;

    // ── 1. Input LayerNorm (CPU — fast for 2048 elements) ──
    download(&h_hidden, d_hidden, hidden_size);
    dequantNormTo(lw.attn_norm, hidden_size, &h_norm_w);
    decoder.rmsNorm(&h_hidden, &h_norm_out, &h_norm_w, hidden_size, cfg.rms_eps);
    upload(d_norm_out, &h_norm_out, hidden_size);

    // ── 2. Q projection: d_q = W_q @ d_norm_out (GPU) ──
    {
        const w_ptr = getWeightDevicePtr(layer_idx, 0, lw.q_proj, lw.q_proj_type, n_heads * head_dim * hidden_size);
        gpuMatvecResident(d_q, w_ptr, d_norm_out, n_heads * head_dim, hidden_size);
    }

    // ── 3. K projection: d_k = W_k @ d_norm_out (GPU) ──
    {
        const w_ptr = getWeightDevicePtr(layer_idx, 1, lw.k_proj, lw.k_proj_type, kv_d * hidden_size);
        gpuMatvecResident(d_k, w_ptr, d_norm_out, kv_d, hidden_size);
    }

    // ── 4. V projection: d_v = W_v @ d_norm_out (GPU) ──
    {
        const w_ptr = getWeightDevicePtr(layer_idx, 2, lw.v_proj, lw.v_proj_type, kv_d * hidden_size);
        gpuMatvecResident(d_v, w_ptr, d_norm_out, kv_d, hidden_size);
    }

    // ── 5. Download Q/K/V for attention (CPU — seq_len is small during decode) ──
    download(&h_q, d_q, n_heads * head_dim);
    download(&h_k, d_k, kv_d);
    download(&h_v, d_v, kv_d);

    // ── 6. Per-head Q/K RMSNorm (Qwen3) ──
    if (cfg.has_qk_norm) {
        if (lw.q_norm) |qn| {
            var qn_w: [256]f32 = undefined; // head_dim max 256
            dequantNormTo(qn, head_dim, &qn_w);
            for (0..n_heads) |h| {
                const off = h * head_dim;
                decoder.rmsNorm(h_q[off..].ptr, h_q[off..].ptr, &qn_w, head_dim, cfg.rms_eps);
            }
        }
        if (lw.k_norm) |kn| {
            var kn_w: [256]f32 = undefined;
            dequantNormTo(kn, head_dim, &kn_w);
            for (0..n_kv_heads) |h| {
                const off = h * head_dim;
                decoder.rmsNorm(h_k[off..].ptr, h_k[off..].ptr, &kn_w, head_dim, cfg.rms_eps);
            }
        }
    }

    // ── 7. RoPE ──
    applyRoPE(&h_q, pos, n_heads, head_dim, cfg.rope_theta);
    applyRoPE(&h_k, pos, n_kv_heads, head_dim, cfg.rope_theta);

    // ── 8. Store K/V in CPU KV cache (no GPU round-trip!) ──
    kv.storeK(layer_idx, &h_k);
    kv.storeV(layer_idx, &h_v);

    // ── 9. Attention on CPU (uses CPU-resident KV cache directly) ──
    {
        const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
        @memset(h_attn_out[0 .. n_heads * head_dim], 0.0);

        for (0..n_heads) |h| {
            const kv_head = h / gqa_ratio;
            const q_ptr = h_q[h * head_dim ..].ptr;

            // Score all past positions (dot product with cached K)
            for (0..pos + 1) |p| {
                h_attn_scores[p] = kv.dotK(layer_idx, p, kv_head, q_ptr, head_dim) * scale;
            }
            softmax(h_attn_scores[0 .. pos + 1]);

            // Weighted sum of V
            const out_ptr = h_attn_out[h * head_dim ..].ptr;
            for (0..pos + 1) |p| {
                kv.accumV(layer_idx, p, kv_head, h_attn_scores[p], out_ptr, head_dim);
            }
        }
    }

    // ── 10. O projection: attn_out → hidden residual (GPU) ──
    upload(d_attn_out, &h_attn_out, n_heads * head_dim);
    {
        const w_ptr = getWeightDevicePtr(layer_idx, 3, lw.o_proj, lw.o_proj_type, hidden_size * n_heads * head_dim);
        gpuMatvecResident(d_mlp_out, w_ptr, d_attn_out, hidden_size, n_heads * head_dim);
    }

    // Add residual: d_hidden += d_mlp_out (download, add on CPU, re-upload)
    download(&h_hidden, d_hidden, hidden_size);
    download(&s_residual, d_mlp_out, hidden_size);
    for (0..hidden_size) |i| h_hidden[i] += s_residual[i];
    upload(d_hidden, &h_hidden, hidden_size);

    // ── 11. Post-attention LayerNorm (CPU) ──
    dequantNormTo(lw.post_norm, hidden_size, &h_norm_w);
    decoder.rmsNorm(&h_hidden, &h_norm_out, &h_norm_w, hidden_size, cfg.rms_eps);
    upload(d_norm_out, &h_norm_out, hidden_size);

    // ── 12. MLP: gate + up projections (GPU) ──
    {
        const w_ptr = getWeightDevicePtr(layer_idx, 4, lw.gate_proj, lw.gate_proj_type, intermediate * hidden_size);
        gpuMatvecResident(d_mlp_gate, w_ptr, d_norm_out, intermediate, hidden_size);
    }

    {
        const w_ptr = getWeightDevicePtr(layer_idx, 5, lw.up_proj, lw.up_proj_type, intermediate * hidden_size);
        gpuMatvecResident(d_mlp_up, w_ptr, d_norm_out, intermediate, hidden_size);
    }

    // ── 13. SiLU(gate) * up (CPU — 6144 elements, fast) ──
    download(&s_gate, d_mlp_gate, intermediate);
    download(&s_up, d_mlp_up, intermediate);
    for (0..intermediate) |i| {
        s_gate[i] = decoder.silu(s_gate[i]) * s_up[i];
    }
    upload(d_mlp_gate, &s_gate, intermediate); // reuse d_mlp_gate as SiLU*up result

    // ── 14. Down projection (GPU) ──
    {
        const w_ptr = getWeightDevicePtr(layer_idx, 6, lw.down_proj, lw.down_proj_type, hidden_size * intermediate);
        gpuMatvecResident(d_mlp_out, w_ptr, d_mlp_gate, hidden_size, intermediate);
    }

    // ── 15. Residual: d_hidden += d_mlp_out ──
    download(&h_hidden, d_hidden, hidden_size);
    download(&s_residual, d_mlp_out, hidden_size);
    for (0..hidden_size) |i| h_hidden[i] += s_residual[i];
    upload(d_hidden, &h_hidden, hidden_size);
}

// ── Attention (CPU, seq_len is small during decode) ──

/// Store K/V in the GPU KV cache (upload from CPU).
fn storeKV(layer: usize, pos: usize, k_vec: [*]const f32, v_vec: [*]const f32, kv_d: usize) void {
    const k_off = (layer * kv_max_seq + pos) * kv_d * 4;
    const v_off = (layer * kv_max_seq + pos) * kv_d * 4;
    _ = cuda.uploadToGpu(d_kv_k + k_off, @ptrCast(k_vec), kv_d * 4);
    _ = cuda.uploadToGpu(d_kv_v + v_off, @ptrCast(v_vec), kv_d * 4);
}

/// Compute multi-head attention on CPU (seq_len is small during single-token decode).
fn computeAttention(
    layer: usize,
    pos: usize,
    q_buf: [*]const f32,
    n_heads: usize,
    _: usize, // n_kv_heads (used via gqa_ratio)
    head_dim: usize,
    gqa_ratio: usize,
    kv_d: usize,
) void {
    const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(head_dim)));
    const seq_len = pos + 1;

    // Download all cached K/V for this layer up to current pos
    const kv_bytes = seq_len * kv_d * 4;
    const k_layer_off = layer * kv_max_seq * kv_d * 4;
    const v_layer_off = layer * kv_max_seq * kv_d * 4;
    _ = cuda.downloadFromGpu(@ptrCast(&s_kv_k_buf), d_kv_k + k_layer_off, kv_bytes);
    _ = cuda.downloadFromGpu(@ptrCast(&s_kv_v_buf), d_kv_v + v_layer_off, kv_bytes);

    @memset(h_attn_out[0 .. n_heads * head_dim], 0.0);

    for (0..n_heads) |h| {
        const kv_head = h / gqa_ratio;
        const q_ptr = q_buf + h * head_dim;

        // Dot Q with all cached K
        for (0..seq_len) |p| {
            var dot: f32 = 0.0;
            const k_ptr = s_kv_k_buf[p * kv_d + kv_head * head_dim ..].ptr;
            for (0..head_dim) |i| dot += q_ptr[i] * k_ptr[i];
            h_attn_scores[p] = dot * scale;
        }

        // Softmax
        softmax(h_attn_scores[0..seq_len]);

        // Weighted sum of V
        const out_ptr = h_attn_out[h * head_dim ..].ptr;
        for (0..seq_len) |p| {
            const w = h_attn_scores[p];
            if (w == 0.0) continue;
            const v_ptr = s_kv_v_buf[p * kv_d + kv_head * head_dim ..].ptr;
            for (0..head_dim) |i| out_ptr[i] += w * v_ptr[i];
        }
    }
}

fn softmax(data: []f32) void {
    var max_val: f32 = data[0];
    for (1..data.len) |i| if (data[i] > max_val) { max_val = data[i]; };
    var sum: f32 = 0.0;
    for (0..data.len) |i| {
        data[i] = @exp(data[i] - max_val);
        sum += data[i];
    }
    const inv = 1.0 / sum;
    for (0..data.len) |i| data[i] *= inv;
}

/// NeoX RoPE.
fn applyRoPE(data: [*]f32, pos: usize, n_heads: usize, head_dim: usize, theta: f32) void {
    const math = std.math;
    const half = head_dim / 2;
    for (0..n_heads) |h| {
        const base = h * head_dim;
        for (0..half) |i| {
            const freq = 1.0 / math.pow(f32, theta, @as(f32, @floatFromInt(2 * i)) / @as(f32, @floatFromInt(head_dim)));
            const angle = @as(f32, @floatFromInt(pos)) * freq;
            const cos_v = @cos(angle);
            const sin_v = @sin(angle);
            const x0 = data[base + i];
            const x1 = data[base + half + i];
            data[base + i] = x0 * cos_v - x1 * sin_v;
            data[base + half + i] = x0 * sin_v + x1 * cos_v;
        }
    }
}

/// Generate tokens autoregressively until EOS or max.
pub fn generate(
    prompt_ids: []const u32,
    model: *const gguf_loader.LoadedModel,
    cfg: decoder.DecoderConfig,
    eos_token: u32,
    max_new: usize,
    out_ids: [*]u32,
) usize {
    resetKV();
    // Prefill
    for (0..prompt_ids.len) |i| {
        _ = forward(prompt_ids[i], model, cfg);
    }
    // Generate
    var count: usize = 0;
    var last = if (prompt_ids.len > 0) prompt_ids[prompt_ids.len - 1] else @as(u32, 0);
    while (count < max_new) {
        const next = forward(last, model, cfg);
        if (next == eos_token or next == 151643) break;
        out_ids[count] = next;
        count += 1;
        last = next;
    }
    return count;
}
