// @zpm/diffusion — GPU dequantization kernels (NVRTC-compiled).
//
// Dequantizes GGML quantized weight blocks directly in VRAM: quantized bytes in
// → f32 out, entirely on the GPU. This is what makes the diffusion forward
// efficient — the quantized model is uploaded to VRAM ONCE, and every GEMM's
// weight is expanded VRAM→VRAM by these kernels instead of being dequantized on
// the CPU and re-uploaded each step.
//
// The block layouts mirror ggml (and the CPU path in llm/quantize.sig):
//   Q4_K: 144 bytes / 256 elems (d,dmin f16 + 12 scale bytes + 128 quant bytes)
//   Q6_K: 210 bytes / 256 elems (128 ql + 64 qh + 16 i8 scales + d f16)
//   Q8_0:  34 bytes /  32 elems (f16 scale + 32 i8)
//   BF16:   2 bytes /   1 elem  (upper 16 bits of the f32)
//   F16 :   2 bytes /   1 elem
//   F32 :   4 bytes /   1 elem  (device-to-device copy)

const cuda = @import("cuda");

// One __global__ per type. Each writes `n` f32 outputs from the packed source.
// grid-stride loops so a modest grid covers any n. All match ggml exactly.
const KERNEL_SRC =
    \\extern "C" {
    \\
    \\// IEEE half → float, pure integer bit ops (no cuda_fp16.h dependency so
    \\// NVRTC needs no header include path).
    \\__device__ __forceinline__ float h2f(unsigned short h){
    \\  unsigned int sign = (unsigned int)(h & 0x8000) << 16;
    \\  unsigned int exp  = (h >> 10) & 0x1F;
    \\  unsigned int mant = h & 0x3FF;
    \\  unsigned int out;
    \\  if (exp == 0){
    \\    if (mant == 0){ out = sign; }
    \\    else {
    \\      int e = -1;
    \\      unsigned int m = mant;
    \\      do { m <<= 1; e++; } while ((m & 0x400) == 0);
    \\      m &= 0x3FF;
    \\      out = sign | ((unsigned int)(127 - 15 - e) << 23) | (m << 13);
    \\    }
    \\  } else if (exp == 0x1F){
    \\    out = sign | 0x7F800000u | (mant << 13);
    \\  } else {
    \\    out = sign | ((exp + 112u) << 23) | (mant << 13);
    \\  }
    \\  return __int_as_float((int)out);
    \\}
    \\
    \\__global__ void deq_f32(const float* src, float* dst, int n){
    \\  int i = blockIdx.x*blockDim.x + threadIdx.x;
    \\  if (i < n) dst[i] = src[i];
    \\}
    \\
    \\__global__ void deq_f16(const unsigned short* src, float* dst, int n){
    \\  int i = blockIdx.x*blockDim.x + threadIdx.x;
    \\  if (i < n) dst[i] = h2f(src[i]);
    \\}
    \\
    \\__global__ void deq_bf16(const unsigned short* src, float* dst, int n){
    \\  int i = blockIdx.x*blockDim.x + threadIdx.x;
    \\  if (i < n){ unsigned int b = ((unsigned int)src[i]) << 16; dst[i] = __int_as_float((int)b); }
    \\}
    \\
    \\// Q8_0: 32 elems/block, 34 bytes/block (f16 d + 32 int8).
    \\__global__ void deq_q8_0(const unsigned char* src, float* dst, int n){
    \\  int blk = blockIdx.x*blockDim.x + threadIdx.x;         // one thread per block
    \\  int nb = n / 32;
    \\  if (blk >= nb) return;
    \\  const unsigned char* p = src + blk*34;
    \\  unsigned short dh = (unsigned short)p[0] | ((unsigned short)p[1]<<8);
    \\  float d = h2f(dh);
    \\  for (int j=0;j<32;j++){ signed char q = (signed char)p[2+j]; dst[blk*32+j] = d*(float)q; }
    \\}
    \\
    \\// Q4_K: 256 elems/block, 144 bytes/block (d,dmin f16 + 12 scale + 128 quant).
    \\__global__ void deq_q4_k(const unsigned char* src, float* dst, int n){
    \\  int blk = blockIdx.x*blockDim.x + threadIdx.x;
    \\  int nb = n / 256;
    \\  if (blk >= nb) return;
    \\  const unsigned char* b = src + blk*144;
    \\  unsigned short dh = (unsigned short)b[0] | ((unsigned short)b[1]<<8);
    \\  unsigned short mh = (unsigned short)b[2] | ((unsigned short)b[3]<<8);
    \\  float d = h2f(dh);
    \\  float dmin = h2f(mh);
    \\  const unsigned char* scales = b + 4;      // 12 bytes
    \\  const unsigned char* q = b + 16;          // 128 bytes
    \\  int out = blk*256;
    \\  int is=0, qoff=0, yoff=0;
    \\  for(; is<8 && qoff+32<=128; is+=2, qoff+=32, yoff+=64){
    \\    unsigned char sc1,m1,sc2,m2;
    \\    if(is<4){ sc1=scales[is]&63; } else { sc1=(scales[is+4]&0xF)|((scales[is-4]>>6)<<4); }
    \\    if(is<4){ m1=scales[is+4]&63; } else { m1=(scales[is+4]>>4)|((scales[is]>>6)<<4); }
    \\    int is2=is+1;
    \\    if(is2<4){ sc2=scales[is2]&63; } else { sc2=(scales[is2+4]&0xF)|((scales[is2-4]>>6)<<4); }
    \\    if(is2<4){ m2=scales[is2+4]&63; } else { m2=(scales[is2+4]>>4)|((scales[is2]>>6)<<4); }
    \\    float d1=d*(float)sc1, min1=dmin*(float)m1;
    \\    float d2=d*(float)sc2, min2=dmin*(float)m2;
    \\    for(int l=0;l<32;l++){
    \\      unsigned char qb=q[qoff+l];
    \\      dst[out+yoff+l]      = d1*(float)(qb&0xF)-min1;
    \\      dst[out+yoff+32+l]   = d2*(float)(qb>>4)-min2;
    \\    }
    \\  }
    \\}
    \\
    \\// Q6_K: 256 elems/block, 210 bytes/block (128 ql + 64 qh + 16 i8 scales + f16 d).
    \\__global__ void deq_q6_k(const unsigned char* src, float* dst, int n){
    \\  int blk = blockIdx.x*blockDim.x + threadIdx.x;
    \\  int nb = n / 256;
    \\  if (blk >= nb) return;
    \\  const unsigned char* b = src + blk*210;
    \\  const unsigned char* ql = b;
    \\  const unsigned char* qh = b + 128;
    \\  const signed char* sc = (const signed char*)(b + 192);
    \\  unsigned short dh = (unsigned short)b[208] | ((unsigned short)b[209]<<8);
    \\  float d = h2f(dh);
    \\  int out = blk*256;
    \\  for(int n0=0;n0<256;n0+=128){
    \\    for(int l=0;l<32;l++){
    \\      int is=l/16;
    \\      const unsigned char* qlp = ql + n0/2;
    \\      const unsigned char* qhp = qh + n0/4;
    \\      int q1=(int)((qlp[l]&0xF)|(((qhp[l]>>0)&3)<<4))-32;
    \\      int q2=(int)((qlp[l+32]&0xF)|(((qhp[l]>>2)&3)<<4))-32;
    \\      int q3=(int)((qlp[l]>>4)|(((qhp[l]>>4)&3)<<4))-32;
    \\      int q4=(int)((qlp[l+32]>>4)|(((qhp[l]>>6)&3)<<4))-32;
    \\      int scb=(n0/128)*8+is;
    \\      dst[out+n0+l]    = d*(float)sc[scb+0]*(float)q1;
    \\      dst[out+n0+l+32] = d*(float)sc[scb+2]*(float)q2;
    \\      dst[out+n0+l+64] = d*(float)sc[scb+4]*(float)q3;
    \\      dst[out+n0+l+96] = d*(float)sc[scb+6]*(float)q4;
    \\    }
    \\  }
    \\}
    \\
    \\
    \\// ── Activation kernels (keep everything GPU-resident) ──
    \\// Constants must match the Sig side: HIDDEN=4096, HEADS=32, HEAD_DIM=128.
    \\
    \\// Per-head RMS norm: x[tokens*HIDDEN], gain[HEAD_DIM] applied per head.
    \\// One thread per (token,head).
    \\__global__ void rmsnorm_head(float* x, const float* gain, int tokens){
    \\  int idx = blockIdx.x*blockDim.x + threadIdx.x;   // token*HEADS + head
    \\  int total = tokens*32;
    \\  if (idx >= total) return;
    \\  int base = (idx/32)*4096 + (idx%32)*128;
    \\  float ss = 0.f;
    \\  for(int d=0;d<128;d++){ float v=x[base+d]; ss+=v*v; }
    \\  float inv = rsqrtf(ss/128.f + 1e-6f);
    \\  for(int d=0;d<128;d++){ x[base+d] = x[base+d]*inv*gain[d]; }
    \\}
    \\
    \\// SwiGLU: gate[i] = silu(gate[i]) * up[i]  over n elements.
    \\__global__ void swiglu(float* gate, const float* up, int n){
    \\  int i = blockIdx.x*blockDim.x + threadIdx.x;
    \\  if (i < n){ float g=gate[i]; float s=g/(1.f+__expf(-g)); gate[i]=s*up[i]; }
    \\}
    \\
    \\// Residual: x[i] += gate_scale * delta[i].
    \\__global__ void add_scaled(float* x, const float* delta, float scale, int n){
    \\  int i = blockIdx.x*blockDim.x + threadIdx.x;
    \\  if (i < n) x[i] += scale*delta[i];
    \\}
    \\
    \\// Multi-head scaled dot-product attention, one thread per (query,head).
    \\//   q,k,v,out : [tokens*HIDDEN], HEADS=32, HEAD_DIM=128, scale=1/sqrt(128).
    \\// Online softmax so no per-key scratch is needed.
    \\__global__ void attention(const float* q, const float* k, const float* v,
    \\                          float* out, int tokens){
    \\  int idx = blockIdx.x*blockDim.x + threadIdx.x;   // query*HEADS + head
    \\  int total = tokens*32;
    \\  if (idx >= total) return;
    \\  int qtok = idx/32; int h = idx%32; int hoff = h*128;
    \\  const float* qp = q + qtok*4096 + hoff;
    \\  const float scale = 0.088388f; // 1/sqrt(128)
    \\  float acc[128];
    \\  for(int d=0;d<128;d++) acc[d]=0.f;
    \\  float m = -3.0e38f, l = 0.f;
    \\  for(int kt=0; kt<tokens; kt++){
    \\    const float* kp = k + kt*4096 + hoff;
    \\    float dot=0.f;
    \\    for(int d=0;d<128;d++) dot += qp[d]*kp[d];
    \\    dot *= scale;
    \\    float mnew = fmaxf(m, dot);
    \\    float corr = __expf(m - mnew);
    \\    float p = __expf(dot - mnew);
    \\    l = l*corr + p;
    \\    const float* vp = v + kt*4096 + hoff;
    \\    for(int d=0;d<128;d++) acc[d] = acc[d]*corr + p*vp[d];
    \\    m = mnew;
    \\  }
    \\  float* op = out + qtok*4096 + hoff;
    \\  float inv = 1.f/l;
    \\  for(int d=0;d<128;d++) op[d] = acc[d]*inv;
    \\}
    \\
    \\} // extern C
;

var g_module: ?cuda.CUmodule = null;
var g_ready = false;
var g_tried = false;
var fn_f32: ?cuda.CUfunction = null;
var fn_f16: ?cuda.CUfunction = null;
var fn_bf16: ?cuda.CUfunction = null;
var fn_q8_0: ?cuda.CUfunction = null;
var fn_q4_k: ?cuda.CUfunction = null;
var fn_q6_k: ?cuda.CUfunction = null;
var fn_rmsnorm: ?cuda.CUfunction = null;
var fn_swiglu: ?cuda.CUfunction = null;
var fn_add_scaled: ?cuda.CUfunction = null;
var fn_attention: ?cuda.CUfunction = null;

/// Compile + load the dequant kernels once. Returns false if the GPU kernel
/// pipeline isn't available (caller then uses the CPU dequant path).
pub fn ensure(log_out: ?[]u8) bool {
    if (g_ready) return true;
    if (g_tried) return false;
    g_tried = true;
    if (!cuda.init() or !cuda.kernelsAvailable()) return false;

    var image: [512 * 1024]u8 = undefined;
    var log: [8 * 1024]u8 = @splat(0);
    const len = cuda.compile(KERNEL_SRC, "sm_120", .cubin, &image, &log) orelse {
        if (log_out) |dst| {
            const n = @min(dst.len, log.len);
            @memcpy(dst[0..n], log[0..n]);
        }
        return false;
    };
    if (len == 0) return false;
    const module = cuda.loadModule(&image) orelse return false;
    g_module = module;
    fn_f32 = cuda.getFunction(module, "deq_f32");
    fn_f16 = cuda.getFunction(module, "deq_f16");
    fn_bf16 = cuda.getFunction(module, "deq_bf16");
    fn_q8_0 = cuda.getFunction(module, "deq_q8_0");
    fn_q4_k = cuda.getFunction(module, "deq_q4_k");
    fn_q6_k = cuda.getFunction(module, "deq_q6_k");
    fn_rmsnorm = cuda.getFunction(module, "rmsnorm_head");
    fn_swiglu = cuda.getFunction(module, "swiglu");
    fn_add_scaled = cuda.getFunction(module, "add_scaled");
    fn_attention = cuda.getFunction(module, "attention");
    g_ready = fn_bf16 != null and fn_q4_k != null and fn_q6_k != null and
        fn_rmsnorm != null and fn_swiglu != null and fn_add_scaled != null and fn_attention != null;
    return g_ready;
}

// ── Activation kernel launchers (all operate on GPU-resident buffers) ──

pub fn rmsNormHead(d_x: cuda.CUdeviceptr, d_gain: cuda.CUdeviceptr, tokens: usize) bool {
    const f = fn_rmsnorm orelse return false;
    var x = d_x;
    var g = d_gain;
    var tk: c_int = @intCast(tokens);
    var params = [_]?*anyopaque{ &x, &g, &tk };
    return launch1D(f, tokens * 32, &params);
}

pub fn swiglu(d_gate: cuda.CUdeviceptr, d_up: cuda.CUdeviceptr, n: usize) bool {
    const f = fn_swiglu orelse return false;
    var gate = d_gate;
    var up = d_up;
    var nn: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &gate, &up, &nn };
    return launch1D(f, n, &params);
}

pub fn addScaled(d_x: cuda.CUdeviceptr, d_delta: cuda.CUdeviceptr, scale: f32, n: usize) bool {
    const f = fn_add_scaled orelse return false;
    var x = d_x;
    var delta = d_delta;
    var sc: f32 = scale;
    var nn: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &x, &delta, &sc, &nn };
    return launch1D(f, n, &params);
}

pub fn attention(d_q: cuda.CUdeviceptr, d_k: cuda.CUdeviceptr, d_v: cuda.CUdeviceptr, d_out: cuda.CUdeviceptr, tokens: usize) bool {
    const f = fn_attention orelse return false;
    var q = d_q;
    var k = d_k;
    var v = d_v;
    var o = d_out;
    var tk: c_int = @intCast(tokens);
    var params = [_]?*anyopaque{ &q, &k, &v, &o, &tk };
    return launch1D(f, tokens * 32, &params);
}

fn launch1D(f: cuda.CUfunction, threads: usize, params: []?*anyopaque) bool {
    const block: u32 = 256;
    const grid: u32 = @intCast((threads + block - 1) / block);
    if (!cuda.launchKernel(f, grid, block, 0, params)) return false;
    return cuda.syncActiveStream();
}

pub fn ready() bool {
    return g_ready;
}

/// Dequantize `n` elements of a `type_code` weight from device buffer
/// `d_src` (quantized bytes) into device buffer `d_dst` (f32), on the GPU.
/// Returns false if the type is unsupported or the launch failed.
pub fn dequant(type_code: u32, d_src: cuda.CUdeviceptr, d_dst: cuda.CUdeviceptr, n: usize) bool {
    if (!g_ready) return false;
    // Element-per-thread kernels (f32/f16/bf16) launch n threads; block-per-
    // thread kernels (q8_0/q4_k/q6_k) launch one thread per quant block.
    var threads: usize = n;
    var func: ?cuda.CUfunction = null;
    switch (type_code) {
        0 => func = fn_f32,
        1 => func = fn_f16,
        30 => func = fn_bf16,
        8 => {
            func = fn_q8_0;
            threads = n / 32;
        },
        12 => {
            func = fn_q4_k;
            threads = n / 256;
        },
        14 => {
            func = fn_q6_k;
            threads = n / 256;
        },
        else => return false,
    }
    const f = func orelse return false;
    var src = d_src;
    var dst = d_dst;
    var n_arg: c_int = @intCast(n);
    var params = [_]?*anyopaque{ &src, &dst, &n_arg };
    const block: u32 = 256;
    const grid: u32 = @intCast((threads + block - 1) / block);
    if (!cuda.launchKernel(f, grid, block, 0, &params)) return false;
    return cuda.syncActiveStream();
}
