//! @zpm/tts-gpu — optional cuBLAS-resident weight cache for the Qwen3-TTS stack.
//!
//! The pure-Sig CPU backends decode every matrix row on demand (SB0-Q4 × Q8
//! fused dot). That is exact but ~644x slower than realtime. This module lifts
//! the matmul weights into VRAM once (dequantized to f32) and runs each matrix
//! multiply on the GPU through cuBLAS, keyed by the tensor's file offset — so
//! the executors and codec are unchanged, they just consult `matvec` first.
//!
//! It degrades cleanly: if there is no CUDA device, `init` returns false, the
//! cache stays disarmed, and every `matvec` returns `false` so the caller runs
//! the CPU path. This keeps the whole stack buildable and correct on machines
//! with no GPU while giving a large speedup where cuBLAS is present.
//!
//! Layout, following @zpm/llm's proven GPU inference pattern:
//!   - each weight matrix W[rows × cols] is dequantized to f32 and uploaded to
//!     a device buffer once (`preloadMatrix`); its device pointer is stored
//!     against the tensor's `data_offset` (a stable identity within one model).
//!   - `matvec` uploads the activation vector, runs `out = W @ in` via cuBLAS
//!     (cublasSgemm, TF32 on Blackwell), downloads the result, and adds bias on
//!     the CPU.

const std = @import("std");
const sb0m = @import("tts_model_container");
const quantized = @import("quantized_linear");
const cuda = @import("matmul_cuda");

pub const Tensor = sb0m.Tensor;
pub const Source = sb0m.Source;

/// Talker (402) + codec (271) leaves plenty of headroom; only matvec weight
/// matrices are cached (embedding tables are row-lookups and stay on the CPU).
const MAX_ENTRIES: usize = 1024;
/// Widest activation vectors across the stack: Talker feed-forward is 3072,
/// the vocoder's flattened conv input reaches input_channels×kernel = 12288.
const MAX_K: usize = 12_288;
const MAX_N: usize = 12_288;
/// One dequantized weight matrix staging buffer. The largest matvec weight is
/// the Talker codec head / text embedding projection (≤ 151,936 × 2,048 would
/// be huge, but those are embeddings we skip); real matvec weights peak at
/// vocabulary 3072 × hidden 1024 and ffn 3072 × 1024, ~3M elements. The output
/// projection lm_heads are 2048 × 1024. Cap staging at 16M f32 (64 MB).
const MAX_MATRIX_ELEMENTS: usize = 16 * 1024 * 1024;

const Entry = struct {
    offset: u64 = 0,
    dptr: cuda.CUdeviceptr = 0,
    rows: usize = 0,
    cols: usize = 0,
};

var entries: [MAX_ENTRIES]Entry = @splat(.{});
var entry_count: usize = 0;
var armed_flag: bool = false;

// Diagnostics: how many matvec calls the GPU handled vs declined, and the
// cumulative nanoseconds spent inside GPU matvec (upload+gemm+download).
pub var gpu_hits: u64 = 0;
pub var gpu_misses: u64 = 0;
pub var gpu_ns: u64 = 0;
pub var up_ns: u64 = 0;
pub var gemm_ns: u64 = 0;
pub var down_ns: u64 = 0;

extern "kernel32" fn QueryPerformanceCounter(*u64) c_int;
extern "kernel32" fn QueryPerformanceFrequency(*u64) c_int;
pub fn nowNs() u64 {
    var c: u64 = 0;
    var f: u64 = 0;
    _ = QueryPerformanceCounter(&c);
    _ = QueryPerformanceFrequency(&f);
    if (f == 0) return 0;
    // Split to avoid u64 overflow of c * 1e9 for large QPC counters.
    return (c / f) * 1_000_000_000 + (c % f) * 1_000_000_000 / f;
}

/// Number of weight matrices resident in VRAM.
pub fn entryCount() usize {
    return entry_count;
}

// Device scratch for one matvec (activation in, result out).
var d_in: cuda.CUdeviceptr = 0;
var d_out: cuda.CUdeviceptr = 0;

// CPU staging.
var h_in: [MAX_K]f32 = @splat(0);
var h_out: [MAX_N]f32 = @splat(0);

// Win32 VirtualAlloc for the large dequant staging buffer (off the BSS).
extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) ?[*]u8;
extern "kernel32" fn VirtualFree(?*anyopaque, usize, u32) c_int;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;
var h_staging: ?[*]f32 = null;

/// Attempt to bring up cuBLAS and the device scratch. Returns true when the GPU
/// path is usable. Safe to call more than once.
pub fn init() bool {
    if (armed_flag) return true;
    if (!cuda.init()) return false;
    if (!cuda.isAvailable()) return false;
    d_in = cuda.gpuAlloc(MAX_K * @sizeOf(f32));
    d_out = cuda.gpuAlloc(MAX_N * @sizeOf(f32));
    if (d_in == 0 or d_out == 0) return false;
    const mem = VirtualAlloc(null, MAX_MATRIX_ELEMENTS * @sizeOf(f32), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (mem == null) return false;
    h_staging = @ptrCast(@alignCast(mem.?));
    entry_count = 0;
    armed_flag = true;
    return true;
}

/// True once at least one weight has been uploaded and the GPU is ready.
pub fn armed() bool {
    return armed_flag and entry_count > 0;
}

/// Free device buffers and reset the cache.
pub fn deinit() void {
    for (entries[0..entry_count]) |*e| {
        if (e.dptr != 0) cuda.gpuFree(e.dptr);
        e.* = .{};
    }
    entry_count = 0;
    cuda.gpuFree(d_in);
    d_in = 0;
    cuda.gpuFree(d_out);
    d_out = 0;
    if (h_staging) |s| {
        _ = VirtualFree(@ptrCast(s), 0, MEM_RELEASE);
        h_staging = null;
    }
    armed_flag = false;
}

fn find(offset: u64) ?*Entry {
    for (entries[0..entry_count]) |*e| {
        if (e.offset == offset) return e;
    }
    return null;
}

/// Dequantize a 2-D weight matrix to f32 and upload it to VRAM once. No-op if
/// the GPU is not armed, the tensor is not a 2-D matrix, it is already cached,
/// the cache is full, or the matrix exceeds the staging cap. Returns true if
/// the matrix is resident afterward.
pub fn preloadMatrix(source: Source, tensor: *const Tensor) bool {
    if (!armed_flag) return false;
    if (tensor.rank != 2) return false;
    if (find(tensor.data_offset) != null) return true;
    if (entry_count >= MAX_ENTRIES) return false;

    const rows: usize = @intCast(tensor.rows());
    const cols: usize = @intCast(tensor.rowElements());
    const total = rows * cols;
    if (total == 0 or total > MAX_MATRIX_ELEMENTS) return false;
    const staging = h_staging orelse return false;

    // Dequantize row-by-row into the staging buffer (row-major [rows, cols]).
    const row_bytes: usize = @intCast(tensor.data_bytes / tensor.rows());
    var scratch: [MAX_K * 2]u8 = undefined;
    if (row_bytes > scratch.len) return false;
    for (0..rows) |row| {
        const offset = tensor.data_offset + @as(u64, @intCast(row)) * row_bytes;
        const dst = staging[row * cols ..][0..cols];
        if (!readRowF32(source, tensor.encoding, offset, row_bytes, dst, scratch[0..row_bytes])) return false;
    }

    const dptr = cuda.gpuAlloc(total * @sizeOf(f32));
    if (dptr == 0) return false;
    if (!cuda.uploadToGpu(dptr, @ptrCast(staging), total * @sizeOf(f32))) {
        cuda.gpuFree(dptr);
        return false;
    }
    cuda.syncStream();
    entries[entry_count] = .{ .offset = tensor.data_offset, .dptr = dptr, .rows = rows, .cols = cols };
    entry_count += 1;
    return true;
}

/// Upload every 2-D weight matrix in a parsed model index that is small enough
/// to be a matmul weight (the giant embedding tables exceed the staging cap and
/// are skipped automatically, so they stay CPU-side row lookups). Returns the
/// number of matrices resident afterward. Call once per model after parse.
pub fn preloadAllMatrices(comptime capacity: usize, source: Source, index: *const sb0m.Index(capacity)) usize {
    if (!armed_flag) return 0;
    for (index.tensors[0..index.tensor_count]) |*tensor| {
        _ = preloadMatrix(source, tensor);
    }
    return entry_count;
}

fn readRowF32(source: Source, encoding: sb0m.Encoding, offset: u64, row_bytes: usize, dst: []f32, scratch: []u8) bool {
    const bytes = blk: {
        if (source.map(offset, row_bytes, 1)) |p| break :blk p[0..row_bytes];
        if (!source.read(offset, scratch[0..row_bytes])) return false;
        break :blk scratch[0..row_bytes];
    };
    switch (encoding) {
        .sb0_q4 => quantized.dequantizeSb0Q4(dst, bytes) catch return false,
        .f16 => {
            if (row_bytes < dst.len * 2) return false;
            for (dst, 0..) |*d, i| {
                const b = @as(u16, bytes[i * 2]) | (@as(u16, bytes[i * 2 + 1]) << 8);
                d.* = quantized.f16ToF32(b);
            }
        },
        .raw_u8 => return false,
    }
    for (dst) |v| if (!std.math.isFinite(v)) return false;
    return true;
}

/// Run `output = W @ input (+ bias)` on the GPU if `tensor` is a resident
/// weight matrix. Returns true if the GPU handled it; false means the caller
/// should use its CPU path. `input.len` must equal the matrix column count and
/// `output.len` the row count.
pub fn matvec(tensor: *const Tensor, input: []const f32, output: []f32, bias: ?[]const f32) bool {
    if (!armed_flag) return false;
    const e = find(tensor.data_offset) orelse {
        gpu_misses += 1;
        return false;
    };
    if (e.cols != input.len or e.rows != output.len) return false;
    gpu_hits += 1;
    if (input.len > MAX_K or output.len > MAX_N) return false;
    const t0 = nowNs();
    defer gpu_ns += nowNs() - t0;

    @memcpy(h_in[0..input.len], input);
    const tu = nowNs();
    // Enqueue everything on one stream and sync once at the end — no host stall
    // between the upload, the gemm, and the download.
    if (!cuda.uploadAsync(d_in, @ptrCast(&h_in), input.len * @sizeOf(f32))) return false;
    up_ns += nowNs() - tu;
    const tg = nowNs();
    if (!enqueueGemm(e, 0)) return false;
    gemm_ns += nowNs() - tg;
    const td = nowNs();
    if (!cuda.downloadAsync(@ptrCast(&h_out), d_out, output.len * @sizeOf(f32))) return false;
    if (!cuda.syncActiveStream()) return false;
    down_ns += nowNs() - td;

    if (bias) |b| {
        if (b.len != output.len) return false;
        for (output, h_out[0..output.len], b) |*o, v, add| o.* = v + add;
    } else {
        @memcpy(output, h_out[0..output.len]);
    }
    return true;
}

/// Enqueue one resident-weight GEMV `d_out[out_off..] = W @ d_in` on the stream
/// (no download, no sync). `out_off` is an element offset into `d_out`.
fn enqueueGemm(e: *const Entry, out_off: usize) bool {
    const sgemm = cuda.fn_cublasSgemm orelse return false;
    const alpha: f32 = 1.0;
    const beta: f32 = 0.0;
    const out_ptr: cuda.CUdeviceptr = d_out + @as(cuda.CUdeviceptr, out_off) * @sizeOf(f32);
    // out[N] = W[N,K] @ in[K], W row-major → cuBLAS sees [K,N] (transa=.T).
    const status = sgemm(
        cuda.cublas_handle.?,
        .T,
        .N,
        @intCast(e.rows),
        1,
        @intCast(e.cols),
        &alpha,
        @ptrFromInt(e.dptr),
        @intCast(e.cols),
        @ptrFromInt(d_in),
        @intCast(e.cols),
        &beta,
        @ptrFromInt(out_ptr),
        @intCast(e.rows),
    );
    return status == cuda.CUBLAS_STATUS_SUCCESS;
}

/// Batched matvec: for weights that all read the SAME `input`, upload the input
/// once, enqueue every GEMV back-to-back into one contiguous device region,
/// then download the whole region in a SINGLE synchronizing copy and scatter to
/// the caller's outputs. This collapses N stream syncs into one — the dominant
/// cost of the per-call path. Returns true only if every tensor was resident
/// and dimensions matched; on false the caller runs its per-op path.
///
/// `tensors[i]` produces `outputs[i]` (rows = outputs[i].len); all share
/// `input` (cols). `count` ≤ MAX_BATCH.
pub const MAX_BATCH: usize = 4;
pub fn matvecBatch(
    tensors: []const *const Tensor,
    input: []const f32,
    outputs: []const []f32,
) bool {
    if (!armed_flag) return false;
    if (tensors.len == 0 or tensors.len > MAX_BATCH or tensors.len != outputs.len) return false;
    if (input.len > MAX_K) return false;

    var found: [MAX_BATCH]*Entry = undefined;
    var total_out: usize = 0;
    for (tensors, 0..) |t, i| {
        const e = find(t.data_offset) orelse {
            gpu_misses += 1;
            return false;
        };
        if (e.cols != input.len or e.rows != outputs[i].len) return false;
        found[i] = e;
        total_out += e.rows;
    }
    if (total_out > MAX_N) return false;
    gpu_hits += @intCast(tensors.len);

    const t0 = nowNs();
    defer gpu_ns += nowNs() - t0;

    @memcpy(h_in[0..input.len], input);
    const tu = nowNs();
    if (!cuda.uploadAsync(d_in, @ptrCast(&h_in), input.len * @sizeOf(f32))) return false;
    up_ns += nowNs() - tu;

    // Enqueue every GEMV into contiguous slots of d_out (no sync between them).
    const tg = nowNs();
    var off: usize = 0;
    for (found[0..tensors.len]) |e| {
        if (!enqueueGemm(e, off)) return false;
        off += e.rows;
    }
    gemm_ns += nowNs() - tg;

    // ONE async download of the whole region + ONE sync — the copy waits for
    // all enqueued gemms, and the host stalls exactly once for the batch.
    const td = nowNs();
    if (!cuda.downloadAsync(@ptrCast(&h_out), d_out, total_out * @sizeOf(f32))) return false;
    if (!cuda.syncActiveStream()) return false;
    down_ns += nowNs() - td;

    off = 0;
    for (outputs) |o| {
        @memcpy(o, h_out[off..][0..o.len]);
        off += o.len;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "matvec is a no-op (returns false) when the GPU is not armed" {
    // On a machine with no CUDA device init() returns false; matvec must then
    // decline so the caller falls back to the CPU. We don't assert GPU presence
    // here (CI has none) — only that the disarmed path is safe.
    armed_flag = false;
    var t: Tensor = .{};
    t.rank = 2;
    var in: [4]f32 = @splat(1);
    var out: [4]f32 = @splat(0);
    try std.testing.expect(!matvec(&t, &in, &out, null));
}

test "find returns null on an empty cache" {
    entry_count = 0;
    try std.testing.expect(find(123) == null);
}
