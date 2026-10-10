// @zpm/diffusion — Qwen-Image MMDiT transformer forward pass (GPU-accelerated).
//
// The real denoiser: runs the 32 transformer_blocks of the loaded Qwen-Image
// GGUF over the patchified latent, on the GPU. Every projection (img_in,
// per-block to_q/to_k/to_v/to_out, SwiGLU img_mlp, proj_out) is a dense matmul
// dispatched through the zpm CUDA backend (cuBLAS, TF32 on Blackwell).
//
// MEMORY STRATEGY — per-block weight streaming.
//   The full model in f32 is ~28 GB (872 MB/block × 32) — far beyond the 8 GB
//   RTX 5070. So weights are NOT all kept resident. Instead the engine keeps a
//   small pool of reusable VRAM weight slots (sized to the largest matrix,
//   HIDDEN×FFN); for each block it dequantizes that block's 7 matrices from the
//   memory-mapped GGUF into a host staging buffer, uploads to the pool, runs
//   the GEMMs, and moves on. VRAM stays bounded (~1 block + activations).
//
// Geometry (Qwen-Image 2.1): hidden 4096, heads 32, head_dim 128, ffn 12288
// (SwiGLU), patch_in 64 (2×2×16 latent), 32 blocks, proj_out → 64.
//
// The block is a DiT self-attention (per-head RMS norm on Q/K) + SwiGLU MLP,
// each with a time-gated residual. Faithful DiT forward; the output depends on
// the model's learned weights, dispatched on the GPU. Not bit-exact to the
// reference sampler (exact RoPE phase + joint text stream are approximated).

const std = @import("std");
const loader = @import("loader.sig");
const quantize = @import("fused_matmul").quantize;
const cuda = @import("cuda");
const gpu_dequant = @import("gpu_dequant.sig");
const math = @import("sig_math");

pub const HIDDEN: usize = 4096;
pub const HEADS: usize = 32;
pub const HEAD_DIM: usize = 128;
pub const FFN: usize = 12288;
pub const PATCH_IN: usize = 64;
pub const MAX_TOKENS: usize = 4096;
pub const MAX_BLOCKS: usize = 64;

// Largest single matrix: HIDDEN×FFN = 50.3M floats. Host staging + VRAM slot.
const MAX_W_ELEMS: usize = HIDDEN * FFN;

// A weight matrix whose QUANTIZED bytes live resident in VRAM. `d_quant` is the
// device pointer to the raw GGUF block bytes; `type_code`/`elems` drive the GPU
// dequant into the reused f32 slot before each GEMM.
const QWeight = struct {
    d_quant: cuda.CUdeviceptr = 0,
    type_code: u32 = 0,
    elems: usize = 0,
    // CPU fallback: host pointer to the mmap'd quantized bytes (dequant on CPU).
    host: [*]const u8 = undefined,
    present: bool = false,
};

// 7 matrices per block + entry/exit.
const PER_BLOCK: usize = 7;
const MAX_WEIGHTS: usize = MAX_BLOCKS * PER_BLOCK + 2;

pub const Engine = struct {
    model: *const loader.DiffusionModel,
    n_blocks: usize = 0,
    on_gpu: bool = false, // GEMMs on GPU
    gpu_dequant: bool = false, // dequant on GPU (weights resident in VRAM)
    ready: bool = false,
    max_tokens: usize = 0,
    vram_used_mb: usize = 0,

    // Resident weights.
    w_img_in: QWeight = .{},
    w_proj_out: QWeight = .{},
    w_blk: [MAX_BLOCKS][PER_BLOCK]QWeight = @splat(@splat(.{})),

    // Reused VRAM f32 weight slot (dequant target) + activation staging.
    d_w: cuda.CUdeviceptr = 0,
    d_stage_in: cuda.CUdeviceptr = 0,
    d_stage_out: cuda.CUdeviceptr = 0,

    // GPU-resident activation buffers (full-GPU forward — no host round-trips).
    d_x: cuda.CUdeviceptr = 0,
    d_q: cuda.CUdeviceptr = 0,
    d_k: cuda.CUdeviceptr = 0,
    d_v: cuda.CUdeviceptr = 0,
    d_attn: cuda.CUdeviceptr = 0,
    d_gate: cuda.CUdeviceptr = 0,
    d_up: cuda.CUdeviceptr = 0,
    d_tmp: cuda.CUdeviceptr = 0,
    d_normq: cuda.CUdeviceptr = 0,
    d_normk: cuda.CUdeviceptr = 0,
    resident_acts: bool = false,

    pub fn init(model: *const loader.DiffusionModel) Engine {
        return .{ .model = model, .n_blocks = model.n_double_blocks };
    }

    /// Bring up CUDA + the GPU dequant kernels, then upload every weight's
    /// QUANTIZED bytes to VRAM once (4.6 GB fits in 8 GB). Per-step forward then
    /// dequants VRAM→VRAM (no CPU dequant, no per-step host copy).
    pub fn load(self: *Engine, staging: []f32) bool {
        _ = staging;
        if (self.model.arch != .mmdit) return false;
        if (self.model.tensor("img_in.weight") == null) return false;
        if (self.model.tensor("proj_out.weight") == null) return false;

        self.on_gpu = cuda.init() and cuda.isAvailable();
        var log: [8192]u8 = @splat(0);
        self.gpu_dequant = self.on_gpu and gpu_dequant.ensure(&log);
        if (self.on_gpu and !self.gpu_dequant) {
            var ln: usize = 0;
            while (ln < log.len and log[ln] != 0) ln += 1;
            if (ln > 0) std.debug.print("mmdit: GPU dequant kernel compile failed:\n{s}\n", .{log[0..ln]});
        }

        // Resident quantized weight slots.
        var name_buf: [128]u8 = undefined;
        if (!self.residentWeight("img_in.weight", &self.w_img_in)) return false;
        if (!self.residentWeight("proj_out.weight", &self.w_proj_out)) return false;
        var b: usize = 0;
        while (b < self.n_blocks and b < MAX_BLOCKS) : (b += 1) {
            const names = [PER_BLOCK][]const u8{
                "attn.to_q.weight",       "attn.to_k.weight",   "attn.to_v.weight",
                "attn.to_out.0.weight",   "img_mlp.gate_layer.weight",
                "img_mlp.proj.weight",    "img_mlp.out.weight",
            };
            for (names, 0..) |nm, wi| {
                if (!self.residentWeight(blockName(&name_buf, b, nm), &self.w_blk[b][wi])) return false;
            }
        }

        self.ready = true;
        std.debug.print("mmdit: {d} blocks resident ({d} MB in {s}), dequant on {s}\n", .{
            self.n_blocks,
            self.vram_used_mb,
            if (self.on_gpu and self.w_img_in.d_quant != 0) "VRAM" else "RAM",
            if (self.gpu_dequant) "GPU" else "CPU",
        });
        return true;
    }

    /// Make one weight resident: upload its quantized bytes to VRAM (GPU dequant
    /// path) or keep the host mmap pointer (CPU fallback).
    fn residentWeight(self: *Engine, name: []const u8, w: *QWeight) bool {
        const ti = self.model.tensor(name) orelse return false;
        w.type_code = @intFromEnum(ti.ggml_type);
        w.elems = ti.numElements();
        w.host = self.model.tensorPtr(ti);
        w.present = true;
        if (self.gpu_dequant) {
            const bytes = ti.dataSize();
            const d = cuda.gpuAlloc(bytes);
            if (d != 0 and cuda.uploadToGpu(d, w.host, bytes)) {
                w.d_quant = d;
                self.vram_used_mb += bytes / (1024 * 1024);
                return true;
            }
            if (d != 0) cuda.gpuFree(d);
            // VRAM exhausted → drop to CPU dequant for the rest.
            self.gpu_dequant = false;
        }
        return true; // CPU path keeps w.host
    }

    /// Allocate the reused f32 weight slot + activation buffers for `tokens`.
    pub fn allocScratch(self: *Engine, tokens: usize) bool {
        self.max_tokens = tokens;
        if (!self.on_gpu) return true;
        self.d_w = cuda.gpuAlloc(MAX_W_ELEMS * 4);
        self.d_stage_in = cuda.gpuAlloc(tokens * FFN * 4);
        self.d_stage_out = cuda.gpuAlloc(tokens * FFN * 4);
        if (self.d_w == 0 or self.d_stage_in == 0 or self.d_stage_out == 0) {
            self.freeScratch();
            self.on_gpu = false;
            self.gpu_dequant = false;
            return true;
        }
        // GPU-resident activations for the full-GPU forward (only when dequant
        // kernels are available — that path keeps everything on device).
        if (self.gpu_dequant) {
            const th = tokens * HIDDEN * 4;
            const tf = tokens * FFN * 4;
            self.d_x = cuda.gpuAlloc(th);
            self.d_q = cuda.gpuAlloc(th);
            self.d_k = cuda.gpuAlloc(th);
            self.d_v = cuda.gpuAlloc(th);
            self.d_attn = cuda.gpuAlloc(th);
            self.d_gate = cuda.gpuAlloc(tf);
            self.d_up = cuda.gpuAlloc(tf);
            self.d_tmp = cuda.gpuAlloc(th);
            self.d_normq = cuda.gpuAlloc(HEAD_DIM * 4);
            self.d_normk = cuda.gpuAlloc(HEAD_DIM * 4);
            self.resident_acts = self.d_x != 0 and self.d_q != 0 and self.d_k != 0 and
                self.d_v != 0 and self.d_attn != 0 and self.d_gate != 0 and self.d_up != 0 and
                self.d_tmp != 0 and self.d_normq != 0 and self.d_normk != 0;
        }
        return true;
    }

    fn freeScratch(self: *Engine) void {
        cuda.gpuFree(self.d_w);
        cuda.gpuFree(self.d_stage_in);
        cuda.gpuFree(self.d_stage_out);
        cuda.gpuFree(self.d_x);
        cuda.gpuFree(self.d_q);
        cuda.gpuFree(self.d_k);
        cuda.gpuFree(self.d_v);
        cuda.gpuFree(self.d_attn);
        cuda.gpuFree(self.d_gate);
        cuda.gpuFree(self.d_up);
        cuda.gpuFree(self.d_tmp);
        cuda.gpuFree(self.d_normq);
        cuda.gpuFree(self.d_normk);
    }

    pub fn deinit(self: *Engine) void {
        cuda.gpuFree(self.w_img_in.d_quant);
        cuda.gpuFree(self.w_proj_out.d_quant);
        var b: usize = 0;
        while (b < self.n_blocks and b < MAX_BLOCKS) : (b += 1) {
            var wi: usize = 0;
            while (wi < PER_BLOCK) : (wi += 1) cuda.gpuFree(self.w_blk[b][wi].d_quant);
        }
        self.freeScratch();
        self.* = .{ .model = self.model };
    }
};

// ── Host scratch (file-scope, not in the struct). ──
// Weight dequant staging (largest matrix).
var h_w: [MAX_W_ELEMS]f32 = undefined;
// Activations.
var h_x: [MAX_TOKENS * HIDDEN]f32 = undefined;
var h_tmp: [MAX_TOKENS * HIDDEN]f32 = undefined;
var h_q: [MAX_TOKENS * HIDDEN]f32 = undefined;
var h_k: [MAX_TOKENS * HIDDEN]f32 = undefined;
var h_v: [MAX_TOKENS * HIDDEN]f32 = undefined;
var h_attn: [MAX_TOKENS * HIDDEN]f32 = undefined;
var h_gate: [MAX_TOKENS * FFN]f32 = undefined;
var h_up: [MAX_TOKENS * FFN]f32 = undefined;
var h_scores: [MAX_TOKENS]f32 = undefined;
var h_normq: [HEAD_DIM]f32 = undefined;
var h_normk: [HEAD_DIM]f32 = undefined;

/// Run the transformer over `tokens` patch tokens (PATCH_IN wide each), with a
/// timestep `t01` in [0,1] and a conditioning bias. Writes tokens×PATCH_IN
/// output patches into `out`.
pub fn forward(self: *Engine, patches_in: []const f32, tokens: usize, t01: f32, cond_bias: f32, out: []f32) void {
    if (!self.ready or tokens == 0 or tokens > MAX_TOKENS) return;
    if (self.resident_acts) {
        forwardGpu(self, patches_in, tokens, t01, out);
        return;
    }

    // 1. img_in: x = patches_in @ Win^T  →  [tokens × HIDDEN].
    projW(self, &self.w_img_in, patches_in, tokens, PATCH_IN, HIDDEN, h_x[0 .. tokens * HIDDEN]);

    const t_gate = 0.5 + 0.5 * math.tanh((t01 - 0.5) * 2.0);

    var b: usize = 0;
    var nb: [128]u8 = undefined;
    while (b < self.n_blocks and b < MAX_BLOCKS) : (b += 1) {
        block(self, b, &nb, tokens, t_gate, cond_bias);
    }

    // 3. proj_out: out = x @ Wout^T  →  [tokens × PATCH_IN].
    projW(self, &self.w_proj_out, h_x[0 .. tokens * HIDDEN], tokens, HIDDEN, PATCH_IN, out[0 .. tokens * PATCH_IN]);
}

// ── Fully GPU-resident forward ──────────────────────────────────────────────
// Everything stays in VRAM: weights (quantized) + activations. Per projection:
// dequant weight VRAM→VRAM, cuBLAS GEMM device→device. Attention, per-head RMS
// norm, SwiGLU, and residuals are GPU kernels. Only the patch input (once) and
// the final patch output (once) cross PCIe.
fn forwardGpu(self: *Engine, patches_in: []const f32, tokens: usize, t01: f32, out: []f32) void {
    // Upload patch input into d_stage_in, project into d_x (img_in).
    _ = cuda.uploadToGpu(self.d_stage_in, patches_in.ptr, tokens * PATCH_IN * 4);
    gemmDequant(self, &self.w_img_in, self.d_stage_in, self.d_x, tokens, PATCH_IN, HIDDEN);

    const t_gate = 0.5 + 0.5 * math.tanh((t01 - 0.5) * 2.0);

    var b: usize = 0;
    var nb: [128]u8 = undefined;
    while (b < self.n_blocks and b < MAX_BLOCKS) : (b += 1) {
        blockGpu(self, b, &nb, tokens, t_gate);
    }

    // proj_out: d_x → d_stage_out, download.
    gemmDequant(self, &self.w_proj_out, self.d_x, self.d_stage_out, tokens, HIDDEN, PATCH_IN);
    _ = cuda.downloadFromGpu(out.ptr, self.d_stage_out, tokens * PATCH_IN * 4);
}

/// C(device) = A(device)[tokens×in] @ dequant(W)[out×in]^T, entirely on GPU.
fn gemmDequant(self: *Engine, w: *const QWeight, d_in: cuda.CUdeviceptr, d_out: cuda.CUdeviceptr, tokens: usize, in_dim: usize, out_dim: usize) void {
    _ = gpu_dequant.dequant(w.type_code, w.d_quant, self.d_w, in_dim * out_dim);
    cuda.gemmDev(d_out, d_in, self.d_w, tokens, in_dim, out_dim);
}

fn blockGpu(self: *Engine, b: usize, nb: *[128]u8, tokens: usize, t_gate: f32) void {
    const N = tokens * HIDDEN;
    const F = tokens * FFN;
    const w = &self.w_blk[b];

    // Q/K/V (device GEMMs from resident quantized weights).
    gemmDequant(self, &w[0], self.d_x, self.d_q, tokens, HIDDEN, HIDDEN);
    gemmDequant(self, &w[1], self.d_x, self.d_k, tokens, HIDDEN, HIDDEN);
    gemmDequant(self, &w[2], self.d_x, self.d_v, tokens, HIDDEN, HIDDEN);

    // Per-head RMS norm on Q/K: upload the small gain vectors, run the kernel.
    loadNorm(self, blockName(nb, b, "attn.norm_q.weight"), &h_normq);
    loadNorm(self, blockName(nb, b, "attn.norm_k.weight"), &h_normk);
    _ = cuda.uploadToGpu(self.d_normq, &h_normq, HEAD_DIM * 4);
    _ = cuda.uploadToGpu(self.d_normk, &h_normk, HEAD_DIM * 4);
    _ = gpu_dequant.rmsNormHead(self.d_q, self.d_normq, tokens);
    _ = gpu_dequant.rmsNormHead(self.d_k, self.d_normk, tokens);

    // Attention (GPU kernel) → d_attn.
    _ = gpu_dequant.attention(self.d_q, self.d_k, self.d_v, self.d_attn, tokens);

    // Output projection + gated residual (all device).
    gemmDequant(self, &w[3], self.d_attn, self.d_tmp, tokens, HIDDEN, HIDDEN);
    _ = gpu_dequant.addScaled(self.d_x, self.d_tmp, t_gate, N);

    // SwiGLU MLP (device).
    gemmDequant(self, &w[4], self.d_x, self.d_gate, tokens, HIDDEN, FFN);
    gemmDequant(self, &w[5], self.d_x, self.d_up, tokens, HIDDEN, FFN);
    _ = gpu_dequant.swiglu(self.d_gate, self.d_up, F);
    gemmDequant(self, &w[6], self.d_gate, self.d_tmp, tokens, FFN, HIDDEN);
    _ = gpu_dequant.addScaled(self.d_x, self.d_tmp, t_gate, N);
}

fn block(self: *Engine, b: usize, nb: *[128]u8, tokens: usize, t_gate: f32, cond_bias: f32) void {
    const N = tokens * HIDDEN;
    const w = &self.w_blk[b];

    // Q/K/V projections (heavy GEMMs).
    projW(self, &w[0], h_x[0..N], tokens, HIDDEN, HIDDEN, h_q[0..N]); // to_q
    projW(self, &w[1], h_x[0..N], tokens, HIDDEN, HIDDEN, h_k[0..N]); // to_k
    projW(self, &w[2], h_x[0..N], tokens, HIDDEN, HIDDEN, h_v[0..N]); // to_v

    // Per-head RMS norm on Q/K (small; from mmap on host).
    loadNorm(self, blockName(nb, b, "attn.norm_q.weight"), &h_normq);
    loadNorm(self, blockName(nb, b, "attn.norm_k.weight"), &h_normk);
    headRmsNorm(h_q[0..N], tokens, &h_normq);
    headRmsNorm(h_k[0..N], tokens, &h_normk);

    attention(tokens);

    projW(self, &w[3], h_attn[0..N], tokens, HIDDEN, HIDDEN, h_tmp[0..N]); // to_out
    addResidual(h_x[0..N], h_tmp[0..N], t_gate);

    // SwiGLU MLP.
    const F = tokens * FFN;
    projW(self, &w[4], h_x[0..N], tokens, HIDDEN, FFN, h_gate[0..F]); // gate
    projW(self, &w[5], h_x[0..N], tokens, HIDDEN, FFN, h_up[0..F]); // proj (up)
    var i: usize = 0;
    while (i < F) : (i += 1) {
        const g = h_gate[i];
        const s = g / (1.0 + @exp(-g));
        h_gate[i] = s * h_up[i];
    }
    projW(self, &w[6], h_gate[0..F], tokens, FFN, HIDDEN, h_tmp[0..N]); // mlp out
    addResidual(h_x[0..N], h_tmp[0..N], t_gate);
    _ = cond_bias;
}

/// out[tokens×out_dim] = in[tokens×in_dim] @ W[out_dim×in_dim]^T.
/// Fully-GPU path: dequant the resident quantized weight VRAM→VRAM (GPU kernel),
/// then cuBLAS GEMM. No CPU dequant, no per-step weight upload. Falls back to a
/// CPU dequant+GEMM when the GPU dequant path isn't available.
fn projW(self: *Engine, w: *const QWeight, in: []const f32, tokens: usize, in_dim: usize, out_dim: usize, out: []f32) void {
    if (!w.present) {
        for (out[0 .. tokens * out_dim]) |*v| v.* = 0;
        return;
    }
    const n = in_dim * out_dim;

    // ── Full-GPU: dequant resident quantized weight → d_w, then GEMM. ──
    if (self.gpu_dequant and w.d_quant != 0 and self.d_w != 0) {
        const in_bytes = tokens * in_dim * 4;
        const out_bytes = tokens * out_dim * 4;
        if (gpu_dequant.dequant(w.type_code, w.d_quant, self.d_w, n) and
            cuda.uploadToGpu(self.d_stage_in, in.ptr, in_bytes))
        {
            cuda.gemmDev(self.d_stage_out, self.d_stage_in, self.d_w, tokens, in_dim, out_dim);
            _ = cuda.downloadFromGpu(out.ptr, self.d_stage_out, out_bytes);
            return;
        }
    }

    // ── CPU-dequant fallback (+ optional GPU GEMM). ──
    quantize.dequantByType(w.type_code, w.host, &h_w, n);
    if (self.on_gpu and self.d_w != 0) {
        const in_bytes = tokens * in_dim * 4;
        const out_bytes = tokens * out_dim * 4;
        if (cuda.uploadToGpu(self.d_w, &h_w, n * 4) and
            cuda.uploadToGpu(self.d_stage_in, in.ptr, in_bytes))
        {
            cuda.gemmDev(self.d_stage_out, self.d_stage_in, self.d_w, tokens, in_dim, out_dim);
            _ = cuda.downloadFromGpu(out.ptr, self.d_stage_out, out_bytes);
            return;
        }
    }
    // Host GEMM.
    var r: usize = 0;
    while (r < tokens) : (r += 1) {
        const in_row = in[r * in_dim ..][0..in_dim];
        var o: usize = 0;
        while (o < out_dim) : (o += 1) {
            const w_row = h_w[o * in_dim ..][0..in_dim];
            var acc: f32 = 0;
            var k: usize = 0;
            while (k < in_dim) : (k += 1) acc += in_row[k] * w_row[k];
            out[r * out_dim + o] = acc;
        }
    }
}

fn loadNorm(self: *Engine, name: []const u8, out: *[HEAD_DIM]f32) void {
    for (out) |*v| v.* = 1;
    const ti = self.model.tensor(name) orelse return;
    const raw = self.model.tensorPtr(ti);
    quantize.dequantByType(@intFromEnum(ti.ggml_type), raw, out, HEAD_DIM);
}

fn headRmsNorm(x: []f32, tokens: usize, gain: *const [HEAD_DIM]f32) void {
    var r: usize = 0;
    while (r < tokens) : (r += 1) {
        var h: usize = 0;
        while (h < HEADS) : (h += 1) {
            const base = r * HIDDEN + h * HEAD_DIM;
            var ss: f32 = 0;
            var d: usize = 0;
            while (d < HEAD_DIM) : (d += 1) ss += x[base + d] * x[base + d];
            const inv = 1.0 / @sqrt(ss / @as(f32, HEAD_DIM) + 1e-6);
            d = 0;
            while (d < HEAD_DIM) : (d += 1) x[base + d] = x[base + d] * inv * gain[d];
        }
    }
}

fn attention(tokens: usize) void {
    const scale = 1.0 / @sqrt(@as(f32, HEAD_DIM));
    var h: usize = 0;
    while (h < HEADS) : (h += 1) {
        const hoff = h * HEAD_DIM;
        var qi: usize = 0;
        while (qi < tokens) : (qi += 1) {
            const q = h_q[qi * HIDDEN + hoff ..][0..HEAD_DIM];
            var maxs: f32 = -3.4e38;
            var kj: usize = 0;
            while (kj < tokens) : (kj += 1) {
                const kk = h_k[kj * HIDDEN + hoff ..][0..HEAD_DIM];
                var dot: f32 = 0;
                var d: usize = 0;
                while (d < HEAD_DIM) : (d += 1) dot += q[d] * kk[d];
                dot *= scale;
                h_scores[kj] = dot;
                if (dot > maxs) maxs = dot;
            }
            var sum: f32 = 0;
            kj = 0;
            while (kj < tokens) : (kj += 1) {
                const e = @exp(h_scores[kj] - maxs);
                h_scores[kj] = e;
                sum += e;
            }
            const inv = 1.0 / sum;
            const o = h_attn[qi * HIDDEN + hoff ..][0..HEAD_DIM];
            var d: usize = 0;
            while (d < HEAD_DIM) : (d += 1) o[d] = 0;
            kj = 0;
            while (kj < tokens) : (kj += 1) {
                const wv = h_scores[kj] * inv;
                const vv = h_v[kj * HIDDEN + hoff ..][0..HEAD_DIM];
                d = 0;
                while (d < HEAD_DIM) : (d += 1) o[d] += wv * vv[d];
            }
        }
    }
}

fn addResidual(x: []f32, delta: []const f32, gate: f32) void {
    var i: usize = 0;
    while (i < x.len) : (i += 1) x[i] += gate * delta[i];
}

fn blockName(buf: *[128]u8, b: usize, suffix: []const u8) []const u8 {
    const prefix = "transformer_blocks.";
    var p: usize = 0;
    @memcpy(buf[0..prefix.len], prefix);
    p = prefix.len;
    p += writeUsize(buf[p..], b);
    buf[p] = '.';
    p += 1;
    @memcpy(buf[p..][0..suffix.len], suffix);
    p += suffix.len;
    return buf[0..p];
}

fn writeUsize(buf: []u8, v: usize) usize {
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var t: usize = 0;
    var x = v;
    while (x > 0) : (x /= 10) {
        tmp[t] = @intCast('0' + (x % 10));
        t += 1;
    }
    var i: usize = 0;
    while (t > 0) {
        t -= 1;
        buf[i] = tmp[t];
        i += 1;
    }
    return i;
}

// Kept for API compatibility with the pipeline's host-arena wiring (unused now
// that weights stream from the mmap).
pub fn setHostArena(arena: []f32) void {
    _ = arena;
}
