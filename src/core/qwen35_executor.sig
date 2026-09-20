//! qwen35 GPU-streaming executor.
//!
//! Runs the Qwen3.5 / Qwen3-Next (qwen35) GDN-hybrid decoder one token at a
//! time. Quantized weights are uploaded to VRAM ONCE (2.78 GB fits an 8 GB
//! 5070) and every projection is a fused on-GPU dequant+matvec
//! (qwen35_kernels.matvecFused) — no cuBLAS, no F32 weight materialization.
//! The small per-head math (GDN recurrence, gated attention, RMSNorm, RoPE,
//! SwiGLU, argmax) runs on the host against the validated pure references
//! (qwen35_gdn, qwen35_attn). Depthwise causal conv1d (kernel 4) and the GDN
//! recurrent state / conv state / KV cache live in caller-owned storage.
//!
//! No allocator: the caller owns the Model (device handles) and Work (host
//! activations + states). All caps are comptime-sized for the 4B distill.

const math = @import("sig_math");
const gguf = @import("gguf");
const plan_mod = @import("qwen35_plan");
const kernels = @import("qwen35_kernels");
const cuda = @import("matmul_cuda");
const gdn = @import("qwen35_gdn");
const attn = @import("qwen35_attn");
const quantized = @import("quantized_linear");

pub const Error = error{
    GpuUnavailable,
    KernelCompile,
    UploadFailed,
    MatvecFailed,
    DequantFailed,
    Sync,
    Download,
    InvalidPlan,
    Capacity,
    NonFinite,
};

// ── Model dimensions (4B distill; validated from GGUF) ──
pub const HIDDEN: usize = 2560;
pub const FFN: usize = 9216;
pub const QKV_DIM: usize = 8192; // GDN attn_qkv output (Q2048|K2048|V4096)
pub const GDN_Z: usize = 4096; // GDN gate z
pub const GDN_KQ: usize = 2048; // GDN Q or K width (16*128)
pub const GDN_V: usize = 4096; // GDN V width (32*128)
pub const ATTN_QG: usize = 8192; // full-attn attn_q output (Q4096|gate4096)
pub const ATTN_Q: usize = 4096; // full-attn Q width (16*256)
pub const ATTN_KV: usize = 1024; // full-attn K or V width (4*256)
pub const SSM_PROJ: usize = 32; // alpha/beta projection dim (= v_heads)
pub const CONV_W: usize = 8192; // conv channels (= QKV_DIM)
pub const CONV_K: usize = 4; // conv kernel width
pub const MAX_TENSORS: usize = 512;
pub const MAX_VOCAB: usize = 262_144;
pub const MAX_CONTEXT: usize = attn.MAX_CONTEXT;

pub const gdn_dims = gdn.GdnDims{ .kq_heads = 16, .v_heads = 32, .head_dim = 128 };
pub const attn_dims = attn.AttnDims{ .head_count = 16, .kv_head_count = 4, .head_dim = 256, .rope_dim = 64 };

/// Per-tensor device residency: one VRAM pointer per plan tensor index.
pub const Model = struct {
    dptr: [MAX_TENSORS]cuda.CUdeviceptr = @splat(0),
    ty: [MAX_TENSORS]kernels.GgmlType = @splat(.f32),
    n: [MAX_TENSORS]u32 = @splat(0), // rows (output dim)
    k: [MAX_TENSORS]u32 = @splat(0), // cols (input dim) for 2-D weights
    count: usize = 0,
    // Persistent device scratch for one matvec (reused across all projections).
    d_in: cuda.CUdeviceptr = 0,
    d_out: cuda.CUdeviceptr = 0,
    kern: kernels.DequantKernels = undefined,
    gdn_kern: kernels.GdnKernel = undefined,
    ready: bool = false,
};

/// Full-attention KV cache: one region per full-attn layer. 8 layers.
pub const AttnKv = struct {
    // 2 (K,V) * kv_heads(4) * context * head_dim(256) per layer.
    data: []f32, // caller-provided, len >= 8 * attn_dims.kvElements(context)
};

/// GDN persistent states across tokens: recurrent state + conv state per GDN layer.
pub const GdnState = struct {
    recurrent: []f32, // 25 layers * gdn_dims.stateElements() (32*128*128)
    conv: []f32, // 25 layers * CONV_W * CONV_K (ring of last 4 inputs per channel)
};

/// Host activation scratch (one token). All fixed arrays.
pub const Work = struct {
    hidden: [HIDDEN]f32 = @splat(0),
    normed: [HIDDEN]f32 = @splat(0),
    tmp_hidden: [HIDDEN]f32 = @splat(0),
    // GDN
    qkv: [QKV_DIM]f32 = @splat(0),
    z: [GDN_Z]f32 = @splat(0),
    conv_out: [CONV_W]f32 = @splat(0),
    a_raw: [SSM_PROJ]f32 = @splat(0),
    b_raw: [SSM_PROJ]f32 = @splat(0),
    gdn_o: [GDN_V]f32 = @splat(0),
    // full-attn
    q: [ATTN_QG]f32 = @splat(0), // Q + gate fused
    k: [ATTN_KV]f32 = @splat(0),
    v: [ATTN_KV]f32 = @splat(0),
    attn_o: [ATTN_Q]f32 = @splat(0),
    // FFN
    gate: [FFN]f32 = @splat(0),
    up: [FFN]f32 = @splat(0),
    // weight-vector scratch (for f32 vectors read from GGUF)
    wvec: [HIDDEN]f32 = @splat(0),
    // logits
    logits: [MAX_VOCAB]f32 = @splat(0),
};

// ── Init: compile kernels, upload all quantized 2-D weights to VRAM ──

fn tyOf(ggml_type: u32) ?kernels.GgmlType {
    return switch (ggml_type) {
        0 => .f32,
        12 => .q4_k,
        14 => .q6_k,
        else => null,
    };
}

/// Upload one tensor's raw bytes to VRAM and record its metadata. 2-D weights
/// get n/k recorded (row-major [n][k]); 1-D vectors (norms) are left in the
/// file and read to host on demand, so we only upload 2-D quantized weights.
fn uploadTensor(model: *Model, source: gguf.Source, t: *const gguf.TensorInfo, idx: usize) Error!void {
    if (idx >= MAX_TENSORS) return error.Capacity;
    const ty = tyOf(t.ggml_type) orelse return error.InvalidPlan;
    model.ty[idx] = ty;
    if (t.dimension_count == 2) {
        model.k[idx] = @intCast(t.dimensions[0]);
        model.n[idx] = @intCast(t.dimensions[1]);
        const bytes = source.view(t.file_offset, @intCast(t.byte_size), 1) orelse return error.UploadFailed;
        const d = cuda.gpuAlloc(@intCast(t.byte_size));
        if (d == 0) return error.UploadFailed;
        if (!cuda.uploadToGpu(d, bytes.ptr, @intCast(t.byte_size))) return error.UploadFailed;
        model.dptr[idx] = d;
    } else {
        // 1-D vector (f32 norm / ssm_a / dt_bias): keep resident too for speed.
        model.k[idx] = @intCast(t.dimensions[0]);
        model.n[idx] = 1;
        const d = cuda.gpuAlloc(@intCast(t.byte_size));
        if (d != 0) {
            const bytes = source.view(t.file_offset, @intCast(t.byte_size), 1);
            if (bytes) |b| {
                if (cuda.uploadToGpu(d, b.ptr, @intCast(t.byte_size))) model.dptr[idx] = d;
            }
        }
    }
}

/// Initialize the model: compile GPU kernels, allocate matvec scratch, and
/// upload every plan-referenced tensor to VRAM. `image`/`log` are caller
/// scratch for NVRTC (image ~256 KB).
pub fn init(
    comptime tensor_capacity: usize,
    model: *Model,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const plan_mod.Plan,
    image: []u8,
    log: []u8,
) Error!void {
    if (!cuda.init()) return error.GpuUnavailable;
    if (!cuda.kernelsAvailable()) return error.GpuUnavailable;
    model.kern = kernels.compile(image, log) orelse return error.KernelCompile;
    model.gdn_kern = kernels.compileGdn(image, log) orelse return error.KernelCompile;

    model.count = index.tensor_count;
    if (index.tensor_count > MAX_TENSORS) return error.Capacity;
    for (index.tensors[0..index.tensor_count], 0..) |*t, i| try uploadTensor(model, source, t, i);

    // Matvec scratch: input up to the largest k (FFN=9216 -> but ssm_out k=4096,
    // ffn_down k=9216, lm_head k=2560); output up to the largest n (vocab).
    model.d_in = cuda.gpuAlloc(@as(usize, @max(FFN, HIDDEN)) * @sizeOf(f32));
    model.d_out = cuda.gpuAlloc(@as(usize, MAX_VOCAB) * @sizeOf(f32));
    if (model.d_in == 0 or model.d_out == 0) return error.UploadFailed;
    _ = plan;
    model.ready = true;
}

/// GPU fused matvec for a plan tensor: out[n] = W[n,k] @ in[k].
/// Uploads `in`, launches matvecFused straight from the resident quantized
/// weight, downloads `out`. n/k come from the recorded tensor metadata.
fn gpuMatvec(model: *Model, ref: plan_mod.TensorRef, in: []const f32, out: []f32) Error!void {
    if (!ref.present()) return error.InvalidPlan;
    const idx = ref.index;
    const n = model.n[idx];
    const k = model.k[idx];
    if (in.len != k or out.len != n) return error.Capacity; // dim mismatch (distinct from missing ref)
    if (!cuda.uploadToGpu(model.d_in, in.ptr, in.len * @sizeOf(f32))) return error.UploadFailed;
    if (!kernels.matvecFused(model.kern, model.ty[idx], model.dptr[idx], model.d_in, model.d_out, n, k))
        return error.MatvecFailed;
    if (!cuda.syncActiveStream()) return error.Sync;
    if (!cuda.downloadFromGpu(out.ptr, model.d_out, out.len * @sizeOf(f32))) return error.Download;
    for (out) |x| if (!math.isFinite(x)) return error.NonFinite;
}

// Module-static host buffers for per-layer small f32 tensors (avoid stack).
var conv1d_w_buf: [CONV_K * CONV_W]f32 = @splat(0);
var a_log_buf: [SSM_PROJ]f32 = @splat(0);
var dt_bias_buf: [SSM_PROJ]f32 = @splat(0);
var ssm_norm_buf: [attn.MAX_HEAD_DIM]f32 = @splat(0);
var qnorm_buf: [attn.MAX_HEAD_DIM]f32 = @splat(0);
var knorm_buf: [attn.MAX_HEAD_DIM]f32 = @splat(0);
var q_contig_buf: [ATTN_Q]f32 = @splat(0);
var gate_contig_buf: [ATTN_Q]f32 = @splat(0);

// ── Host helpers ──

/// Read a 1-D f32 vector tensor (norm weights, ssm_a, dt_bias) from the GGUF
/// source into `out`. These are small and read straight from the mmap.
fn readVec(source: gguf.Source, t: *const gguf.TensorInfo, out: []f32) Error!void {
    if (t.ggml_type != 0 or t.dimensions[0] != out.len) return error.InvalidPlan;
    const bytes = source.view(t.file_offset, out.len * @sizeOf(f32), 1) orelse return error.UploadFailed;
    for (out, 0..) |*d, i| {
        const o = i * 4;
        const bits = @as(u32, bytes[o]) | (@as(u32, bytes[o + 1]) << 8) |
            (@as(u32, bytes[o + 2]) << 16) | (@as(u32, bytes[o + 3]) << 24);
        d.* = @bitCast(bits);
    }
}

fn rmsNorm(in: []const f32, w: []const f32, out: []f32, eps: f32) void {
    var ss: f32 = 0;
    for (in) |x| ss += x * x;
    const inv = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(in.len)) + eps);
    for (out, in, w) |*o, x, wi| o.* = x * inv * wi;
}

fn silu(x: f32) f32 {
    return x / (1.0 + @exp(-x));
}

/// Depthwise causal conv1d (kernel CONV_K) + SiLU over the CONV_W channels of
/// `x`, using a per-channel ring of the last CONV_K inputs in `conv_state`
/// (layout channel*CONV_K + tap; tap CONV_K-1 is the newest). Writes conv_out.
/// conv1d_w is [CONV_K, CONV_W] (dimensions[0]=CONV_K fastest? GGUF dims=[4,8192]
/// -> dimensions[0]=4=tap, dimensions[1]=8192=channel; row-major [channel][tap]).
fn conv1dSilu(x: []const f32, conv1d_w: []const f32, conv_state: []f32, conv_out: []f32) void {
    // Shift each channel's ring left by one and append the new input.
    for (0..CONV_W) |c| {
        const rb = c * CONV_K;
        var t: usize = 0;
        while (t < CONV_K - 1) : (t += 1) conv_state[rb + t] = conv_state[rb + t + 1];
        conv_state[rb + CONV_K - 1] = x[c];
        // Causal conv: sum_tap w[c][tap] * ring[tap]. Weight row-major [channel][tap].
        var acc: f32 = 0;
        for (0..CONV_K) |tap| acc += conv1d_w[c * CONV_K + tap] * conv_state[rb + tap];
        conv_out[c] = silu(acc);
    }
}

/// Read any f32 tensor (1-D or 2-D) fully into `out` from the GGUF source.
fn readF32Tensor(source: gguf.Source, t: *const gguf.TensorInfo, out: []f32) Error!void {
    if (t.ggml_type != 0) return error.InvalidPlan;
    const bytes = source.view(t.file_offset, out.len * @sizeOf(f32), 1) orelse return error.UploadFailed;
    for (out, 0..) |*d, i| {
        const o = i * 4;
        const bits = @as(u32, bytes[o]) | (@as(u32, bytes[o + 1]) << 8) |
            (@as(u32, bytes[o + 2]) << 16) | (@as(u32, bytes[o + 3]) << 24);
        d.* = @bitCast(bits);
    }
}

fn tref(index: anytype, ref: plan_mod.TensorRef) *const gguf.TensorInfo {
    return &index.tensors[ref.index];
}

/// One GDN mixer layer (writes result added into work.hidden).
fn gdnLayer(
    comptime tensor_capacity: usize,
    model: *Model,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const plan_mod.Plan,
    layer: *const plan_mod.Layer,
    gdn_layer_idx: usize,
    work: *Work,
    st: GdnState,
) Error!void {
    // 1. pre-mixer RMSNorm
    try readVec(source, tref(index, layer.attn_norm), work.wvec[0..HIDDEN]);
    rmsNorm(work.hidden[0..HIDDEN], work.wvec[0..HIDDEN], work.normed[0..HIDDEN], plan.rms_norm_epsilon);
    // 2. projections (GPU): qkv[8192], z[4096], a_raw[32], b_raw[32]
    try gpuMatvec(model, layer.attn_qkv, work.normed[0..HIDDEN], work.qkv[0..QKV_DIM]);
    try gpuMatvec(model, layer.attn_gate, work.normed[0..HIDDEN], work.z[0..GDN_Z]);
    try gpuMatvec(model, layer.ssm_alpha, work.normed[0..HIDDEN], work.a_raw[0..SSM_PROJ]);
    try gpuMatvec(model, layer.ssm_beta, work.normed[0..HIDDEN], work.b_raw[0..SSM_PROJ]);
    // 3. depthwise causal conv1d + SiLU over the 8192 qkv channels (host).
    const conv_base = gdn_layer_idx * CONV_W * CONV_K;
    // conv1d weight is small f32; read into up[] scratch (reused, >= 4*8192? no).
    // Use a dedicated static buffer.
    try readF32Tensor(source, tref(index, layer.ssm_conv1d), conv1d_w_buf[0 .. CONV_K * CONV_W]);
    conv1dSilu(work.qkv[0..CONV_W], conv1d_w_buf[0 .. CONV_K * CONV_W], st.conv[conv_base..][0 .. CONV_W * CONV_K], work.conv_out[0..CONV_W]);
    // 4. split conv_out into Q[2048], K[2048], V[4096]
    const q = work.conv_out[0..GDN_KQ];
    const k = work.conv_out[GDN_KQ..][0..GDN_KQ];
    const v = work.conv_out[GDN_KQ * 2 ..][0..GDN_V];
    // 5. gates need ssm_a (A_log) and ssm_dt.bias vectors (host).
    try readVec(source, tref(index, layer.ssm_a), a_log_buf[0..SSM_PROJ]);
    try readVec(source, tref(index, layer.ssm_dt_bias), dt_bias_buf[0..SSM_PROJ]);
    try readVec(source, tref(index, layer.ssm_norm), ssm_norm_buf[0..gdn_dims.head_dim]);
    // 6. GDN recurrence (host reference) mutating this layer's recurrent state.
    const rec_base = gdn_layer_idx * gdn_dims.stateElements();
    gdn.step(gdn_dims, q, k, v, work.z[0..GDN_Z], work.a_raw[0..SSM_PROJ], work.b_raw[0..SSM_PROJ], a_log_buf[0..SSM_PROJ], dt_bias_buf[0..SSM_PROJ], ssm_norm_buf[0..gdn_dims.head_dim], plan.rms_norm_epsilon, st.recurrent[rec_base..][0..gdn_dims.stateElements()], work.gdn_o[0..GDN_V]) catch return error.InvalidPlan;
    // 7. output projection ssm_out[4096->2560] (GPU) into tmp_hidden, add residual.
    try gpuMatvec(model, layer.ssm_out, work.gdn_o[0..GDN_V], work.tmp_hidden[0..HIDDEN]);
    for (work.hidden[0..HIDDEN], work.tmp_hidden[0..HIDDEN]) |*h, o| h.* += o;
}

/// One full-attention layer (writes result added into work.hidden).
fn attnLayer(
    comptime tensor_capacity: usize,
    model: *Model,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const plan_mod.Plan,
    layer: *const plan_mod.Layer,
    attn_layer_idx: usize,
    work: *Work,
    kv: AttnKv,
    context: usize,
    position: usize,
) Error!void {
    try readVec(source, tref(index, layer.attn_norm), work.wvec[0..HIDDEN]);
    rmsNorm(work.hidden[0..HIDDEN], work.wvec[0..HIDDEN], work.normed[0..HIDDEN], plan.rms_norm_epsilon);
    // Projections (GPU). attn_q is query+gate fused [8192]; k,v [1024].
    try gpuMatvec(model, layer.attn_q, work.normed[0..HIDDEN], work.q[0..ATTN_QG]);
    try gpuMatvec(model, layer.attn_k, work.normed[0..HIDDEN], work.k[0..ATTN_KV]);
    try gpuMatvec(model, layer.attn_v, work.normed[0..HIDDEN], work.v[0..ATTN_KV]);
    // attn_q is PER-HEAD interleaved [q_h0(hd), gate_h0(hd), q_h1(hd), ...]
    // (HF q_proj -> view(-1, head_dim*2).chunk(2)). De-interleave into
    // contiguous Q[4096] and gate[4096].
    const hd = attn_dims.head_dim;
    for (0..attn_dims.head_count) |h| {
        @memcpy(q_contig_buf[h * hd ..][0..hd], work.q[h * 2 * hd ..][0..hd]);
        @memcpy(gate_contig_buf[h * hd ..][0..hd], work.q[h * 2 * hd + hd ..][0..hd]);
    }
    const q = q_contig_buf[0..ATTN_Q];
    const gate = gate_contig_buf[0..ATTN_Q];
    try readVec(source, tref(index, layer.attn_q_norm), qnorm_buf[0..attn_dims.head_dim]);
    try readVec(source, tref(index, layer.attn_k_norm), knorm_buf[0..attn_dims.head_dim]);
    // Attention (host) into attn_o; this layer's KV slice.
    const kv_layer_elems = attn_dims.kvElements(context);
    const kv_slice = kv.data[attn_layer_idx * kv_layer_elems ..][0..kv_layer_elems];
    attn.step(attn_dims, q, work.k[0..ATTN_KV], work.v[0..ATTN_KV], gate, qnorm_buf[0..attn_dims.head_dim], knorm_buf[0..attn_dims.head_dim], plan.rms_norm_epsilon, plan.rope_frequency_base, kv_slice, context, position, work.attn_o[0..ATTN_Q]) catch return error.InvalidPlan;
    // Output projection [4096->2560] (GPU), add residual.
    try gpuMatvec(model, layer.attn_output, work.attn_o[0..ATTN_Q], work.tmp_hidden[0..HIDDEN]);
    for (work.hidden[0..HIDDEN], work.tmp_hidden[0..HIDDEN]) |*h, o| h.* += o;
}

/// SwiGLU FFN (both layer kinds): post_attention_norm -> gate/up -> silu(gate)*up -> down.
fn ffnLayer(
    comptime tensor_capacity: usize,
    model: *Model,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const plan_mod.Plan,
    layer: *const plan_mod.Layer,
    work: *Work,
) Error!void {
    try readVec(source, tref(index, layer.post_attention_norm), work.wvec[0..HIDDEN]);
    rmsNorm(work.hidden[0..HIDDEN], work.wvec[0..HIDDEN], work.normed[0..HIDDEN], plan.rms_norm_epsilon);
    try gpuMatvec(model, layer.ffn_gate, work.normed[0..HIDDEN], work.gate[0..FFN]);
    try gpuMatvec(model, layer.ffn_up, work.normed[0..HIDDEN], work.up[0..FFN]);
    for (work.gate[0..FFN], work.up[0..FFN]) |*g, u| g.* = silu(g.*) * u;
    try gpuMatvec(model, layer.ffn_down, work.gate[0..FFN], work.tmp_hidden[0..HIDDEN]);
    for (work.hidden[0..HIDDEN], work.tmp_hidden[0..HIDDEN]) |*h, o| h.* += o;
}

/// Embedding lookup: dequantize row `token` of token_embd into work.hidden.
fn embedding(
    comptime tensor_capacity: usize,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const plan_mod.Plan,
    token: u32,
    work: *Work,
) Error!void {
    const t = tref(index, plan.token_embedding);
    if (t.dimensions[0] != HIDDEN or token >= t.dimensions[1]) return error.InvalidPlan;
    const row_bytes: usize = @intCast(t.byte_size / t.dimensions[1]);
    const off = t.file_offset + @as(u64, token) * row_bytes;
    const bytes = source.view(off, row_bytes, 1) orelse return error.UploadFailed;
    switch (t.ggml_type) {
        12 => quantized.dequantizeQ4K(work.hidden[0..HIDDEN], bytes) catch return error.DequantFailed,
        14 => quantized.dequantizeQ6K(work.hidden[0..HIDDEN], bytes) catch return error.DequantFailed,
        else => return error.InvalidPlan,
    }
}

/// Debug bisect switches (dev only): make a mixer a no-op residual pass-through.
pub var dbg_skip_gdn: bool = false;
pub var dbg_skip_attn: bool = false;

/// Run one token through the whole decoder and return the greedy argmax token.
/// `position` is the 0-based sequence index (must be < context).
pub fn forward(
    comptime tensor_capacity: usize,
    model: *Model,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const plan_mod.Plan,
    work: *Work,
    kv: AttnKv,
    st: GdnState,
    context: usize,
    token: u32,
    position: usize,
    produce_logits: bool,
) Error!u32 {
    if (!model.ready) return error.GpuUnavailable;
    if (position >= context) return error.Capacity;

    try embedding(tensor_capacity, source, index, plan, token, work);

    var attn_idx: usize = 0;
    var gdn_idx: usize = 0;
    for (0..plan.layer_count) |li| {
        const layer = &plan.layers[li];
        if (layer.kind == .full_attention) {
            if (!dbg_skip_attn) try attnLayer(tensor_capacity, model, source, index, plan, layer, attn_idx, work, kv, context, position);
            attn_idx += 1;
        } else {
            if (!dbg_skip_gdn) try gdnLayer(tensor_capacity, model, source, index, plan, layer, gdn_idx, work, st);
            gdn_idx += 1;
        }
        try ffnLayer(tensor_capacity, model, source, index, plan, layer, work);
    }

    // Intermediate prefill positions don't need logits — skip the huge lm_head.
    if (!produce_logits) return 0;

    // Final norm + lm_head.
    try readVec(source, tref(index, plan.output_norm), work.wvec[0..HIDDEN]);
    rmsNorm(work.hidden[0..HIDDEN], work.wvec[0..HIDDEN], work.normed[0..HIDDEN], plan.rms_norm_epsilon);
    try gpuMatvec(model, plan.output, work.normed[0..HIDDEN], work.logits[0..plan.vocabulary_size]);

    var best: u32 = 0;
    var best_v: f32 = work.logits[0];
    for (work.logits[1..plan.vocabulary_size], 1..) |lv, i| {
        if (lv > best_v) {
            best_v = lv;
            best = @intCast(i);
        }
    }
    return best;
}
