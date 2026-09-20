//! qwen35 GPU kernels — CUDA-C source strings + a numerical self-test.
//!
//! These kernels are the GPU half of the quantized-resident executor: weights
//! stay Q4_K/Q6_K in VRAM and each kernel expands one weight tensor to F32 in a
//! reused device scratch buffer, which `cublasSgemm` then consumes. The bit
//! layout below MUST match `quantized_linear.sig` exactly (canonical GGML
//! Q4_K/Q6_K), so `selfTestDequant` cross-checks GPU output against the host
//! `dequantizeQ4K`/`dequantizeQ6K` on a caller-supplied real block.
//!
//! Nothing here allocates: the caller owns all device memory and host scratch.
//! Everything degrades — if `cuda.kernelsAvailable()` is false the self-test
//! returns a nonzero stage code and the executor refuses the GPU path.

const cuda = @import("matmul_cuda");
const quantized = @import("quantized_linear");

pub const QK_K: usize = quantized.QK_K; // 256 elements per super-block
pub const Q4_K_BLOCK_BYTES: usize = quantized.Q4_K_BLOCK_BYTES; // 144
pub const Q6_K_BLOCK_BYTES: usize = quantized.Q6_K_BLOCK_BYTES; // 210

/// CUDA-C source for both dequant kernels. One CUDA block per 256-element
/// GGML super-block; 256 threads per block, each thread writes one output
/// element. `nblocks` is the number of super-blocks in the tensor.
///
/// Q4_K super-block (144 B): d(f16)@0, dmin(f16)@2, scales[12]@4, quants[128]@16.
///   6-bit scale/min packing matches ggml's get_scale_min_k4.
///   value = d*scale*nibble - dmin*min.
/// Q6_K super-block (210 B): ql[128]@0, qh[64]@128, scales[16 i8]@192, d(f16)@208.
///   value = d * (i8)scale * ((6-bit)-32).
pub const dequant_src: [*:0]const u8 =
    \\// ---- half -> float (IEEE, matches quantized_linear.f16ToF32) ----
    \\__device__ __forceinline__ float f16f(unsigned short h){
    \\  unsigned int sign = (unsigned int)(h >> 15) << 31;
    \\  unsigned int exp  = (h >> 10) & 0x1f;
    \\  unsigned int man  = h & 0x3ff;
    \\  unsigned int bits;
    \\  if (exp == 0){
    \\    if (man == 0){ bits = sign; }
    \\    else {
    \\      int shift = 0;
    \\      while ((man & 0x400) == 0){ man <<= 1; shift++; }
    \\      bits = sign | ((unsigned)(127-14-shift) << 23) | ((man & 0x3ff) << 13);
    \\    }
    \\  } else if (exp == 31){
    \\    bits = sign | 0x7f800000u | (man << 13);
    \\  } else {
    \\    bits = sign | ((exp + (127-15)) << 23) | (man << 13);
    \\  }
    \\  return __int_as_float((int)bits);
    \\}
    \\
    \\// ggml Q4_K 6-bit scale/min unpack for one of 8 groups.
    \\__device__ __forceinline__ void q4k_scale_min(const unsigned char* s, int g, int* sc, int* mn){
    \\  if (g < 4){ *sc = s[g] & 63; *mn = s[g+4] & 63; }
    \\  else {
    \\    *sc = (s[g+4] & 0x0f) | ((s[g-4] >> 6) << 4);
    \\    *mn = (s[g+4] >> 4)  | ((s[g]   >> 6) << 4);
    \\  }
    \\}
    \\
    \\extern "C" __global__ void dequant_q4k(const unsigned char* __restrict__ blocks,
    \\                                       float* __restrict__ out, int nblocks){
    \\  int b = blockIdx.x;            // super-block index
    \\  if (b >= nblocks) return;
    \\  int lane = threadIdx.x;        // 0..255 output element within the block
    \\  const unsigned char* blk = blocks + (size_t)b * 144;
    \\  float d    = f16f(*(const unsigned short*)(blk + 0));
    \\  float dmin = f16f(*(const unsigned short*)(blk + 2));
    \\  const unsigned char* scales = blk + 4;
    \\  const unsigned char* quants = blk + 16;
    \\  // Element `lane` lives in pair = lane/64, half = (lane%64)>=32, within = lane%32.
    \\  int pair  = lane >> 6;         // 0..3
    \\  int rem   = lane & 63;
    \\  int high  = rem >> 5;          // 0 low-nibble half, 1 high-nibble half
    \\  int within= rem & 31;          // 0..31
    \\  int group = pair * 2 + high;   // 0..7
    \\  int sc, mn; q4k_scale_min(scales, group, &sc, &mn);
    \\  unsigned char qb = quants[pair * 32 + within];
    \\  int q = high ? (qb >> 4) : (qb & 0x0f);
    \\  out[(size_t)b * 256 + lane] = d * (float)sc * (float)q - dmin * (float)mn;
    \\}
    \\
    \\extern "C" __global__ void dequant_q6k(const unsigned char* __restrict__ blocks,
    \\                                       float* __restrict__ out, int nblocks){
    \\  int b = blockIdx.x;
    \\  if (b >= nblocks) return;
    \\  int lane = threadIdx.x;        // 0..255
    \\  const unsigned char* blk = blocks + (size_t)b * 210;
    \\  const unsigned char* ql = blk + 0;
    \\  const unsigned char* qh = blk + 128;
    \\  const signed char*   sc = (const signed char*)(blk + 192);
    \\  float d = f16f(*(const unsigned short*)(blk + 208));
    \\  // ggml Q6_K layout: two halves of 128 elems. Within a half, 4 sub-lanes
    \\  // (offsets 0,32,64,96) share ql/qh bytes; scale index = base + {0,2,4,6}.
    \\  int half   = lane >> 7;        // 0..1
    \\  int within = lane & 127;       // 0..127
    \\  int sub    = within >> 5;      // 0..3 -> which of the 4 packed values
    \\  int idx    = within & 31;      // 0..31 within the 32-wide lane group
    \\  int ql_off = half * 64;
    \\  int qh_off = half * 32;
    \\  int sc_off = half * 8;
    \\  int scale_lane = idx / 16;     // matches host: lane/16 over the 32-group
    \\  unsigned char hbyte = qh[qh_off + idx];
    \\  int qv;
    \\  if      (sub == 0) qv = (ql[ql_off + idx]      & 0x0f) | (((hbyte >> 0) & 3) << 4);
    \\  else if (sub == 1) qv = (ql[ql_off + 32 + idx] & 0x0f) | (((hbyte >> 2) & 3) << 4);
    \\  else if (sub == 2) qv = (ql[ql_off + idx]      >> 4)   | (((hbyte >> 4) & 3) << 4);
    \\  else               qv = (ql[ql_off + 32 + idx] >> 4)   | (((hbyte >> 6) & 3) << 4);
    \\  int scv = (int)sc[sc_off + scale_lane + sub * 2];
    \\  out[(size_t)b * 256 + lane] = d * (float)scv * (float)(qv - 32);
    \\}
    \\
    \\// ---- fused dequant + matvec: out[row] = sum_c W[row][c] * in[c] ----
    \\// One CUDA block per output row; blockDim.x = 256 threads cooperate over
    \\// the row's k elements (k must be a multiple of 256). Shared-mem reduction.
    \\// Weight is row-major: row `r` starts at r * (k/256) * block_bytes.
    \\__device__ __forceinline__ float q4k_elem(const unsigned char* blk, int lane){
    \\  float d    = f16f(*(const unsigned short*)(blk + 0));
    \\  float dmin = f16f(*(const unsigned short*)(blk + 2));
    \\  const unsigned char* scales = blk + 4;
    \\  const unsigned char* quants = blk + 16;
    \\  int pair = lane >> 6, rem = lane & 63, high = rem >> 5, within = rem & 31;
    \\  int group = pair * 2 + high;
    \\  int sc, mn; q4k_scale_min(scales, group, &sc, &mn);
    \\  unsigned char qb = quants[pair * 32 + within];
    \\  int q = high ? (qb >> 4) : (qb & 0x0f);
    \\  return d * (float)sc * (float)q - dmin * (float)mn;
    \\}
    \\extern "C" __global__ void matvec_q4k(const unsigned char* __restrict__ w,
    \\                                      const float* __restrict__ in,
    \\                                      float* __restrict__ out, int k){
    \\  int row = blockIdx.x;
    \\  int t   = threadIdx.x;          // 0..255
    \\  int nb  = k >> 8;               // blocks per row = k/256
    \\  const unsigned char* rowp = w + (size_t)row * nb * 144;
    \\  float acc = 0.0f;
    \\  for (int bk = 0; bk < nb; ++bk){
    \\    const unsigned char* blk = rowp + (size_t)bk * 144;
    \\    int col = bk * 256 + t;
    \\    acc += q4k_elem(blk, t) * in[col];
    \\  }
    \\  __shared__ float red[256];
    \\  red[t] = acc; __syncthreads();
    \\  for (int s = 128; s > 0; s >>= 1){ if (t < s) red[t] += red[t + s]; __syncthreads(); }
    \\  if (t == 0) out[row] = red[0];
    \\}
    \\
    \\__device__ __forceinline__ float q6k_elem(const unsigned char* blk, int lane){
    \\  const unsigned char* ql = blk + 0;
    \\  const unsigned char* qh = blk + 128;
    \\  const signed char*   sc = (const signed char*)(blk + 192);
    \\  float d = f16f(*(const unsigned short*)(blk + 208));
    \\  int half = lane >> 7, within = lane & 127, sub = within >> 5, idx = within & 31;
    \\  int ql_off = half * 64, qh_off = half * 32, sc_off = half * 8;
    \\  int scale_lane = idx / 16;
    \\  unsigned char hbyte = qh[qh_off + idx];
    \\  int qv;
    \\  if      (sub == 0) qv = (ql[ql_off + idx]      & 0x0f) | (((hbyte >> 0) & 3) << 4);
    \\  else if (sub == 1) qv = (ql[ql_off + 32 + idx] & 0x0f) | (((hbyte >> 2) & 3) << 4);
    \\  else if (sub == 2) qv = (ql[ql_off + idx]      >> 4)   | (((hbyte >> 4) & 3) << 4);
    \\  else               qv = (ql[ql_off + 32 + idx] >> 4)   | (((hbyte >> 6) & 3) << 4);
    \\  int scv = (int)sc[sc_off + scale_lane + sub * 2];
    \\  return d * (float)scv * (float)(qv - 32);
    \\}
    \\extern "C" __global__ void matvec_q6k(const unsigned char* __restrict__ w,
    \\                                      const float* __restrict__ in,
    \\                                      float* __restrict__ out, int k){
    \\  int row = blockIdx.x;
    \\  int t   = threadIdx.x;
    \\  int nb  = k >> 8;
    \\  const unsigned char* rowp = w + (size_t)row * nb * 210;
    \\  float acc = 0.0f;
    \\  for (int bk = 0; bk < nb; ++bk){
    \\    const unsigned char* blk = rowp + (size_t)bk * 210;
    \\    int col = bk * 256 + t;
    \\    acc += q6k_elem(blk, t) * in[col];
    \\  }
    \\  __shared__ float red[256];
    \\  red[t] = acc; __syncthreads();
    \\  for (int s = 128; s > 0; s >>= 1){ if (t < s) red[t] += red[t + s]; __syncthreads(); }
    \\  if (t == 0) out[row] = red[0];
    \\}
;

/// CUDA-C source for the fused GDN recurrent decode step. Mirrors
/// `qwen35_gdn.step` exactly. Launch: grid = v_heads, block = head_dim (<=256).
/// Each block owns one v-head; thread `dv` owns output column dv. The recurrent
/// state S lives in VRAM across tokens, layout state[head*hd*hd + dk*hd + dv].
///
/// Inputs (device pointers), all f32 unless noted:
///   q,k  [kq_heads*hd]   (raw, per-head L2-norm applied here)
///   v,z  [v_heads*hd]
///   a_raw,b_raw,a_log,dt_bias  [v_heads]
///   ssm_norm_w [hd]
///   state [v_heads*hd*hd] (mutated)
///   out   [v_heads*hd]
/// Scalars: hd, group (v_heads/kq_heads), rms_eps.
pub const gdn_src: [*:0]const u8 =
    \\extern "C" __global__ void gdn_step(
    \\    const float* __restrict__ q, const float* __restrict__ k,
    \\    const float* __restrict__ v, const float* __restrict__ z,
    \\    const float* __restrict__ a_raw, const float* __restrict__ b_raw,
    \\    const float* __restrict__ a_log, const float* __restrict__ dt_bias,
    \\    const float* __restrict__ ssm_norm_w,
    \\    float* __restrict__ state, float* __restrict__ out,
    \\    int hd, int group, float rms_eps){
    \\  int h  = blockIdx.x;            // v-head
    \\  int dv = threadIdx.x;           // output column, 0..hd-1
    \\  if (dv >= hd) return;
    \\  int nkq = gridDim.x / group;    // num_k_heads = v_heads / (v_heads/kq_heads)
    \\  int kq = h % nkq;               // qwen35 uses plain repeat (tile), so kq = h % num_k_heads
    \\  extern __shared__ float sh[];   // [0..hd) qn, [hd..2hd) kn, [2hd..3hd) red
    \\  float* qn  = sh;
    \\  float* kn  = sh + hd;
    \\  float* red = sh + 2*hd;
    \\  // Load q,k for this head; L2-norm via shared reduction.
    \\  qn[dv] = q[kq*hd + dv];
    \\  kn[dv] = k[kq*hd + dv];
    \\  __syncthreads();
    \\  red[dv] = qn[dv]*qn[dv]; __syncthreads();
    \\  for (int s = hd>>1; s > 0; s >>= 1){ if (dv < s) red[dv] += red[dv+s]; __syncthreads(); }
    \\  float qinv = rsqrtf(red[0] + 1e-6f); __syncthreads();
    \\  red[dv] = kn[dv]*kn[dv]; __syncthreads();
    \\  for (int s = hd>>1; s > 0; s >>= 1){ if (dv < s) red[dv] += red[dv+s]; __syncthreads(); }
    \\  float kinv = rsqrtf(red[0] + 1e-6f); __syncthreads();
    \\  qn[dv] *= qinv * rsqrtf((float)hd); kn[dv] *= kinv; // query scaled by 1/sqrt(hd)
    \\  __syncthreads();
    \\  // Gates (recomputed per thread; cheap and avoids extra sync).
    \\  float sp = (fabsf(a_raw[h]+dt_bias[h])>20.0f ? (a_raw[h]+dt_bias[h]>0?(a_raw[h]+dt_bias[h]):__expf(a_raw[h]+dt_bias[h])) : __logf(1.0f+__expf(a_raw[h]+dt_bias[h])));
    \\  float g    = __expf(a_log[h] * sp); // a_log carries ssm_a = -exp(A_log)
    \\  float beta = 1.0f/(1.0f+__expf(-b_raw[h]));
    \\  long base = (long)h*hd*hd;
    \\  float vv = v[h*hd + dv];
    \\  // Gated delta rule: decay S first, retrieve from decayed S, then update.
    \\  //   S = g*S ; retrieved = sum_dk k*S ; delta = (v-retrieved)*beta ;
    \\  //   S += k*delta ; o = sum_dk q*S
    \\  for (int dk = 0; dk < hd; ++dk) state[base + (long)dk*hd + dv] *= g;
    \\  float retrieved = 0.0f;
    \\  for (int dk = 0; dk < hd; ++dk) retrieved += kn[dk]*state[base + (long)dk*hd + dv];
    \\  float delta = (vv - retrieved) * beta;
    \\  float o = 0.0f;
    \\  for (int dk = 0; dk < hd; ++dk){
    \\    long idx = base + (long)dk*hd + dv;
    \\    float s = state[idx] + kn[dk]*delta;
    \\    state[idx] = s;
    \\    o += qn[dk]*s;
    \\  }
    \\  // Gated RMSNorm over o (across dv): rmsnorm(o)*silu(z).
    \\  __syncthreads();
    \\  red[dv] = o*o; __syncthreads();
    \\  for (int s = hd>>1; s > 0; s >>= 1){ if (dv < s) red[dv] += red[dv+s]; __syncthreads(); }
    \\  float inv = rsqrtf(red[0]/(float)hd + rms_eps);
    \\  float zz = z[h*hd + dv];
    \\  float sz = zz/(1.0f+__expf(-zz));
    \\  out[h*hd + dv] = (o*inv*ssm_norm_w[dv]) * sz;
    \\}
;

/// Compiled kernel handles. Compile once, reuse for every matmul.
/// `q4k`/`q6k` are element-parallel dequant-to-F32 kernels; `mv_q4k`/`mv_q6k`
/// are fused dequant+matvec kernels (one block per output row) used for the
/// single-token decode path — faster and zero-scratch vs dequant+cuBLAS.
pub const DequantKernels = struct {
    module: cuda.CUmodule,
    q4k: cuda.CUfunction,
    q6k: cuda.CUfunction,
    mv_q4k: cuda.CUfunction,
    mv_q6k: cuda.CUfunction,
};

/// Compile the dequant kernels to a finished cubin for the live GPU (sm_120)
/// and resolve both functions. `image`/`log` are caller-owned scratch (image
/// ~256 KB, log a few KB). Returns null on any failure; on a compile error the
/// NVRTC log is written into `log`.
pub fn compile(image: []u8, log: []u8) ?DequantKernels {
    if (!cuda.init()) return null;
    if (!cuda.kernelsAvailable()) return null;
    const image_len = cuda.compile(dequant_src, "sm_120", .cubin, image, log) orelse return null;
    if (image_len == 0) return null;
    const module = cuda.loadModule(image.ptr) orelse return null;
    const q4k = cuda.getFunction(module, "dequant_q4k") orelse {
        cuda.unloadModule(module);
        return null;
    };
    const q6k = cuda.getFunction(module, "dequant_q6k") orelse {
        cuda.unloadModule(module);
        return null;
    };
    const mv_q4k = cuda.getFunction(module, "matvec_q4k") orelse {
        cuda.unloadModule(module);
        return null;
    };
    const mv_q6k = cuda.getFunction(module, "matvec_q6k") orelse {
        cuda.unloadModule(module);
        return null;
    };
    return .{ .module = module, .q4k = q4k, .q6k = q6k, .mv_q4k = mv_q4k, .mv_q6k = mv_q6k };
}

/// Fused dequant+matvec: out[n] = W[n,k] @ in[k], W quantized-resident in VRAM.
/// One CUDA block per output row (grid=n), 256 threads/block. No F32 weight
/// scratch, no cuBLAS. `k` must be a multiple of 256. Enqueue only; caller syncs.
pub fn matvecFused(
    kern: DequantKernels,
    ty: GgmlType,
    d_weight_q: cuda.CUdeviceptr,
    d_input: cuda.CUdeviceptr,
    d_out: cuda.CUdeviceptr,
    n: usize,
    k: usize,
) bool {
    if (k % QK_K != 0 or n == 0) return false;
    const fnh = switch (ty) {
        .q4_k => kern.mv_q4k,
        .q6_k => kern.mv_q6k,
        .f32 => return false,
    };
    var wp = d_weight_q;
    var ip = d_input;
    var op = d_out;
    var kk: i32 = @intCast(k);
    var params = [_]?*anyopaque{ @ptrCast(&wp), @ptrCast(&ip), @ptrCast(&op), @ptrCast(&kk) };
    return cuda.launchKernel(fnh, @intCast(n), 256, 0, &params);
}

/// Launch dequant_q4k: expand `nblocks` Q4_K super-blocks (in device memory
/// `d_blocks`) to `nblocks*256` f32 in device memory `d_out`. Enqueue only;
/// caller syncs. One CUDA block per super-block, 256 threads each.
pub fn launchQ4K(k: DequantKernels, d_blocks: cuda.CUdeviceptr, d_out: cuda.CUdeviceptr, nblocks: u32) bool {
    var blocks_ptr = d_blocks;
    var out_ptr = d_out;
    var n = nblocks;
    var params = [_]?*anyopaque{ @ptrCast(&blocks_ptr), @ptrCast(&out_ptr), @ptrCast(&n) };
    return cuda.launchKernel(k.q4k, nblocks, 256, 0, &params);
}

/// Launch dequant_q6k (same contract as launchQ4K).
pub fn launchQ6K(k: DequantKernels, d_blocks: cuda.CUdeviceptr, d_out: cuda.CUdeviceptr, nblocks: u32) bool {
    var blocks_ptr = d_blocks;
    var out_ptr = d_out;
    var n = nblocks;
    var params = [_]?*anyopaque{ @ptrCast(&blocks_ptr), @ptrCast(&out_ptr), @ptrCast(&n) };
    return cuda.launchKernel(k.q6k, nblocks, 256, 0, &params);
}

/// Stage codes for selfTestDequant diagnostics.
pub const DequantStage = enum(u32) {
    pass = 0,
    compile = 1,
    alloc = 2,
    upload = 3,
    launch_q4k = 4,
    launch_q6k = 5,
    sync = 6,
    download = 7,
    mismatch_q4k = 8,
    mismatch_q6k = 9,
};

/// End-to-end numerical check on the live GPU for ONE Q4_K and ONE Q6_K
/// super-block supplied by the caller (e.g. the first block of a real GGUF
/// weight row). Dequantizes on the GPU and on the host, and requires every one
/// of the 256 lanes to agree within `tol`. Returns 0 (pass) or a stage code.
/// Caller owns all scratch; nothing is allocated here beyond fixed stack.
pub fn selfTestDequant(
    q4k_block: *const [Q4_K_BLOCK_BYTES]u8,
    q6k_block: *const [Q6_K_BLOCK_BYTES]u8,
    tol: f32,
) u32 {
    var image: [256 * 1024]u8 = undefined;
    var log: [4 * 1024]u8 = @splat(0);
    const kernels = compile(&image, &log) orelse return @intFromEnum(DequantStage.compile);
    defer cuda.unloadModule(kernels.module);

    // Device buffers: quantized inputs + f32 outputs (256 elems each).
    const d_q4_in = cuda.gpuAlloc(Q4_K_BLOCK_BYTES);
    const d_q6_in = cuda.gpuAlloc(Q6_K_BLOCK_BYTES);
    const d_q4_out = cuda.gpuAlloc(QK_K * @sizeOf(f32));
    const d_q6_out = cuda.gpuAlloc(QK_K * @sizeOf(f32));
    defer cuda.gpuFree(d_q4_in);
    defer cuda.gpuFree(d_q6_in);
    defer cuda.gpuFree(d_q4_out);
    defer cuda.gpuFree(d_q6_out);
    if (d_q4_in == 0 or d_q6_in == 0 or d_q4_out == 0 or d_q6_out == 0)
        return @intFromEnum(DequantStage.alloc);

    if (!cuda.uploadToGpu(d_q4_in, q4k_block, Q4_K_BLOCK_BYTES)) return @intFromEnum(DequantStage.upload);
    if (!cuda.uploadToGpu(d_q6_in, q6k_block, Q6_K_BLOCK_BYTES)) return @intFromEnum(DequantStage.upload);

    if (!launchQ4K(kernels, d_q4_in, d_q4_out, 1)) return @intFromEnum(DequantStage.launch_q4k);
    if (!launchQ6K(kernels, d_q6_in, d_q6_out, 1)) return @intFromEnum(DequantStage.launch_q6k);
    if (!cuda.syncActiveStream()) return @intFromEnum(DequantStage.sync);

    var gpu_q4: [QK_K]f32 = undefined;
    var gpu_q6: [QK_K]f32 = undefined;
    if (!cuda.downloadFromGpu(&gpu_q4, d_q4_out, QK_K * @sizeOf(f32))) return @intFromEnum(DequantStage.download);
    if (!cuda.downloadFromGpu(&gpu_q6, d_q6_out, QK_K * @sizeOf(f32))) return @intFromEnum(DequantStage.download);

    var host_q4: [QK_K]f32 = undefined;
    var host_q6: [QK_K]f32 = undefined;
    quantized.dequantizeQ4K(&host_q4, q4k_block) catch return @intFromEnum(DequantStage.mismatch_q4k);
    quantized.dequantizeQ6K(&host_q6, q6k_block) catch return @intFromEnum(DequantStage.mismatch_q6k);

    for (gpu_q4, host_q4) |g, h| if (@abs(g - h) > tol) return @intFromEnum(DequantStage.mismatch_q4k);
    for (gpu_q6, host_q6) |g, h| if (@abs(g - h) > tol) return @intFromEnum(DequantStage.mismatch_q6k);
    return @intFromEnum(DequantStage.pass);
}

// Tests — compile-time wiring only. The live-GPU numerical check runs in the
// end-to-end harness (selfTestDequant needs a real device + a real GGUF block).

test "dequant kernel source and API are well-formed" {
    // The CUDA-C source is a valid NUL-terminated comptime constant.
    if (dequant_src[0] == 0) return error.TestUnexpectedResult;
    // Block-size constants agree with quantized_linear.
    if (Q4_K_BLOCK_BYTES != 144 or Q6_K_BLOCK_BYTES != 210 or QK_K != 256)
        return error.TestUnexpectedResult;
    // Stage enum is stable (pass == 0 so callers can `== 0`).
    if (@intFromEnum(DequantStage.pass) != 0) return error.TestUnexpectedResult;
}

// ── GPU matmul path ──
//
// A weight tensor is stored row-major in VRAM as `n` rows of `k` columns, each
// row a sequence of GGML super-blocks. The single-token decode matvec uses the
// FUSED dequant+matvec kernel (`matvecFused`, one block per output row): it
// reads quantized bytes straight from VRAM, dequantizes per-element in-register,
// and reduces the dot product — no F32 weight materialization, no cuBLAS. K must
// be a multiple of QK_K (256), which every qwen35 2-D weight satisfies. The
// element-parallel `dequant` kernel remains for embedding-row lookup.

pub const GgmlType = enum(u32) { q4_k = 12, q6_k = 14, f32 = 0 };

/// Dequantize `nblocks` super-blocks of `ty` from `d_blocks` into `d_out`
/// (f32). Enqueue only. Returns false on unsupported type or launch failure.
pub fn dequant(k: DequantKernels, ty: GgmlType, d_blocks: cuda.CUdeviceptr, d_out: cuda.CUdeviceptr, nblocks: u32) bool {
    return switch (ty) {
        .q4_k => launchQ4K(k, d_blocks, d_out, nblocks),
        .q6_k => launchQ6K(k, d_blocks, d_out, nblocks),
        .f32 => false, // f32 weights need no dequant; caller uses them directly
    };
}

/// Stage codes for selfTestMatvec.
pub const MatvecStage = enum(u32) {
    pass = 0,
    compile = 1,
    alloc = 2,
    upload = 3,
    dequant = 4,
    sync = 5,
    download = 6,
    mismatch = 7,
};

/// Validate the GPU matvec against the host `quantized_linear.matvecQ4K` for a
/// caller-supplied Q4_K weight row block set. `weight` is `n` rows of
/// `k/256 * 144` bytes; `input` is `k` floats; `expected`/`out` are `n` floats.
/// The caller sizes everything; `d_wf32_bytes` must hold n*k f32. Returns 0
/// (pass) or a stage code. rel tolerance scaled by magnitude.
pub fn selfTestMatvecQ4K(
    weight: []const u8,
    input: []const f32,
    n: usize,
    k: usize,
    tol: f32,
) u32 {
    return selfTestMatvecQ4KDiag(weight, input, n, k, tol, null, null);
}

/// Same as selfTestMatvecQ4K but optionally copies the GPU and host output
/// vectors into caller buffers for diagnostics.
pub fn selfTestMatvecQ4KDiag(
    weight: []const u8,
    input: []const f32,
    n: usize,
    k: usize,
    tol: f32,
    gpu_dbg: ?[]f32,
    host_dbg: ?[]f32,
) u32 {
    var image: [256 * 1024]u8 = undefined;
    var log: [4 * 1024]u8 = @splat(0);
    const kern = compile(&image, &log) orelse return @intFromEnum(MatvecStage.compile);
    defer cuda.unloadModule(kern.module);

    // Fused path: no F32 weight scratch needed.
    const d_wq = cuda.gpuAlloc(weight.len);
    const d_in = cuda.gpuAlloc(k * @sizeOf(f32));
    const d_out = cuda.gpuAlloc(n * @sizeOf(f32));
    defer cuda.gpuFree(d_wq);
    defer cuda.gpuFree(d_in);
    defer cuda.gpuFree(d_out);
    if (d_wq == 0 or d_in == 0 or d_out == 0) return @intFromEnum(MatvecStage.alloc);

    if (!cuda.uploadToGpu(d_wq, weight.ptr, weight.len)) return @intFromEnum(MatvecStage.upload);
    if (!cuda.uploadToGpu(d_in, input.ptr, k * @sizeOf(f32))) return @intFromEnum(MatvecStage.upload);

    if (!matvecFused(kern, .q4_k, d_wq, d_in, d_out, n, k)) return @intFromEnum(MatvecStage.dequant);
    if (!cuda.syncActiveStream()) return @intFromEnum(MatvecStage.sync);

    var gpu_out: [4096]f32 = undefined;
    if (n > gpu_out.len) return @intFromEnum(MatvecStage.alloc);
    if (!cuda.downloadFromGpu(&gpu_out, d_out, n * @sizeOf(f32))) return @intFromEnum(MatvecStage.download);

    var host_out: [4096]f32 = undefined;
    quantized.matvecQ4K(host_out[0..n], weight, input) catch return @intFromEnum(MatvecStage.mismatch);
    if (gpu_dbg) |d| {
        const m = @min(d.len, n);
        @memcpy(d[0..m], gpu_out[0..m]);
    }
    if (host_dbg) |d| {
        const m = @min(d.len, n);
        @memcpy(d[0..m], host_out[0..m]);
    }
    for (gpu_out[0..n], host_out[0..n]) |g, h| {
        const scale = @max(@as(f32, 1.0), @abs(h));
        if (@abs(g - h) > tol * scale) return @intFromEnum(MatvecStage.mismatch);
    }
    return @intFromEnum(MatvecStage.pass);
}

// ── GDN recurrent step kernel: compile, launch, validate ──

const gdn = @import("qwen35_gdn");

// Static scratch for selfTestGdn (state matrix is ~2 MB — keep it off the stack).
var gdn_host_state: [gdn.MAX_STATE]f32 = undefined;
var gdn_gpu_out: [gdn.MAX_V_HEADS * gdn.MAX_HEAD_DIM]f32 = undefined;
var gdn_host_out: [gdn.MAX_V_HEADS * gdn.MAX_HEAD_DIM]f32 = undefined;

pub const GdnKernel = struct {
    module: cuda.CUmodule,
    step: cuda.CUfunction,
};

/// Compile the fused GDN step kernel to a cubin (sm_120) and resolve it.
pub fn compileGdn(image: []u8, log: []u8) ?GdnKernel {
    if (!cuda.init()) return null;
    if (!cuda.kernelsAvailable()) return null;
    const image_len = cuda.compile(gdn_src, "sm_120", .cubin, image, log) orelse return null;
    if (image_len == 0) return null;
    const module = cuda.loadModule(image.ptr) orelse return null;
    const step = cuda.getFunction(module, "gdn_step") orelse {
        cuda.unloadModule(module);
        return null;
    };
    return .{ .module = module, .step = step };
}

/// Launch the GDN step. grid = v_heads, block = head_dim, shared = 3*hd f32.
/// All pointers are device pointers; state is mutated. Enqueue only.
pub fn launchGdn(
    kern: GdnKernel,
    dims: gdn.GdnDims,
    d_q: cuda.CUdeviceptr,
    d_k: cuda.CUdeviceptr,
    d_v: cuda.CUdeviceptr,
    d_z: cuda.CUdeviceptr,
    d_a_raw: cuda.CUdeviceptr,
    d_b_raw: cuda.CUdeviceptr,
    d_a_log: cuda.CUdeviceptr,
    d_dt_bias: cuda.CUdeviceptr,
    d_ssm_norm: cuda.CUdeviceptr,
    d_state: cuda.CUdeviceptr,
    d_out: cuda.CUdeviceptr,
    rms_eps: f32,
) bool {
    var q = d_q;
    var k = d_k;
    var v = d_v;
    var z = d_z;
    var ar = d_a_raw;
    var br = d_b_raw;
    var al = d_a_log;
    var dt = d_dt_bias;
    var nw = d_ssm_norm;
    var st = d_state;
    var o = d_out;
    var hd: i32 = @intCast(dims.head_dim);
    var group: i32 = @intCast(dims.v_heads / dims.kq_heads);
    var eps = rms_eps;
    var params = [_]?*anyopaque{
        @ptrCast(&q),  @ptrCast(&k),  @ptrCast(&v),     @ptrCast(&z),
        @ptrCast(&ar), @ptrCast(&br), @ptrCast(&al),    @ptrCast(&dt),
        @ptrCast(&nw), @ptrCast(&st), @ptrCast(&o),     @ptrCast(&hd),
        @ptrCast(&group), @ptrCast(&eps),
    };
    const shared: u32 = @intCast(3 * dims.head_dim * @sizeOf(f32));
    return cuda.launchKernel(kern.step, @intCast(dims.v_heads), @intCast(dims.head_dim), shared, &params);
}

pub const GdnStage = enum(u32) {
    pass = 0,
    compile = 1,
    alloc = 2,
    upload = 3,
    launch = 4,
    sync = 5,
    download = 6,
    mismatch = 7,
    dims = 8,
};

/// Validate the GPU GDN step against the host `qwen35_gdn.step` on caller-
/// supplied inputs for ONE token from a given initial state. Runs both on the
/// same inputs (fresh copies of state) and requires the mixer output to agree
/// within `tol` (magnitude-scaled). Caller owns all host buffers. Fixed device
/// scratch; nothing allocated beyond stack + gpuAlloc.
pub fn selfTestGdn(
    dims: gdn.GdnDims,
    q_in: []const f32,
    k_in: []const f32,
    v: []const f32,
    z: []const f32,
    a_raw: []const f32,
    b_raw: []const f32,
    a_log: []const f32,
    dt_bias: []const f32,
    ssm_norm_w: []const f32,
    init_state: []const f32,
    rms_eps: f32,
    tol: f32,
) u32 {
    if (!dims.valid()) return @intFromEnum(GdnStage.dims);
    const vdim = dims.vDim();
    const qkdim = dims.qkDim();
    const st_elems = dims.stateElements();

    var image: [256 * 1024]u8 = undefined;
    var log: [4 * 1024]u8 = @splat(0);
    const kern = compileGdn(&image, &log) orelse return @intFromEnum(GdnStage.compile);
    defer cuda.unloadModule(kern.module);

    const d_q = cuda.gpuAlloc(qkdim * 4);
    const d_k = cuda.gpuAlloc(qkdim * 4);
    const d_v = cuda.gpuAlloc(vdim * 4);
    const d_z = cuda.gpuAlloc(vdim * 4);
    const d_ar = cuda.gpuAlloc(dims.v_heads * 4);
    const d_br = cuda.gpuAlloc(dims.v_heads * 4);
    const d_al = cuda.gpuAlloc(dims.v_heads * 4);
    const d_dt = cuda.gpuAlloc(dims.v_heads * 4);
    const d_nw = cuda.gpuAlloc(dims.head_dim * 4);
    const d_st = cuda.gpuAlloc(st_elems * 4);
    const d_out = cuda.gpuAlloc(vdim * 4);
    defer {
        cuda.gpuFree(d_q);
        cuda.gpuFree(d_k);
        cuda.gpuFree(d_v);
        cuda.gpuFree(d_z);
        cuda.gpuFree(d_ar);
        cuda.gpuFree(d_br);
        cuda.gpuFree(d_al);
        cuda.gpuFree(d_dt);
        cuda.gpuFree(d_nw);
        cuda.gpuFree(d_st);
        cuda.gpuFree(d_out);
    }
    if (d_q == 0 or d_k == 0 or d_v == 0 or d_z == 0 or d_ar == 0 or d_br == 0 or
        d_al == 0 or d_dt == 0 or d_nw == 0 or d_st == 0 or d_out == 0)
        return @intFromEnum(GdnStage.alloc);

    if (!cuda.uploadToGpu(d_q, q_in.ptr, qkdim * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_k, k_in.ptr, qkdim * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_v, v.ptr, vdim * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_z, z.ptr, vdim * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_ar, a_raw.ptr, dims.v_heads * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_br, b_raw.ptr, dims.v_heads * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_al, a_log.ptr, dims.v_heads * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_dt, dt_bias.ptr, dims.v_heads * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_nw, ssm_norm_w.ptr, dims.head_dim * 4)) return @intFromEnum(GdnStage.upload);
    if (!cuda.uploadToGpu(d_st, init_state.ptr, st_elems * 4)) return @intFromEnum(GdnStage.upload);

    if (!launchGdn(kern, dims, d_q, d_k, d_v, d_z, d_ar, d_br, d_al, d_dt, d_nw, d_st, d_out, rms_eps))
        return @intFromEnum(GdnStage.launch);
    if (!cuda.syncActiveStream()) return @intFromEnum(GdnStage.sync);

    if (!cuda.downloadFromGpu(&gdn_gpu_out, d_out, vdim * 4)) return @intFromEnum(GdnStage.download);

    // Host reference on a private copy of the state (static — the state is 2 MB).
    @memcpy(gdn_host_state[0..st_elems], init_state[0..st_elems]);
    gdn.step(dims, q_in, k_in, v, z, a_raw, b_raw, a_log, dt_bias, ssm_norm_w, rms_eps, gdn_host_state[0..st_elems], gdn_host_out[0..vdim]) catch return @intFromEnum(GdnStage.mismatch);

    for (gdn_gpu_out[0..vdim], gdn_host_out[0..vdim]) |gp, hs| {
        const scale = @max(@as(f32, 1.0), @abs(hs));
        if (@abs(gp - hs) > tol * scale) return @intFromEnum(GdnStage.mismatch);
    }
    return @intFromEnum(GdnStage.pass);
}
