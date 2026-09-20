//! Qwen3.5 (`qwen35`) hybrid decoder schema binder.
//!
//! Qwen3.5 / Qwen3-Next is NOT a uniform Transformer: it interleaves
//! Gated-DeltaNet (GDN) linear-attention layers with full-attention layers.
//! `full_attention_interval` (=4 for the 4B distill) selects the type: a layer
//! is FULL ATTENTION when (layer_idx + 1) % interval == 0, otherwise GDN.
//!
//! This binder isolates the qwen35 tensor naming (kept out of the generic
//! storage/index code) exactly like qwen3_decoder_plan.sig does for plain
//! Qwen3, but with two layer shapes. See the "Qwen3.5 GDN Hybrid — zpm Port
//! Spec" for the algorithm; tensor names/shapes below are read directly from
//! the empero-ai Qwen3.8-4B-Distill GGUF.

const math = @import("sig_math");
const mem = @import("sig_mem");
const gguf = @import("gguf");

pub const MAX_LAYERS: usize = 64;
pub const INVALID_TENSOR: u16 = math.maxInt(u16);

pub const Error = error{
    UnsupportedArchitecture,
    InvalidConfiguration,
    TensorCapacity,
    UnknownTensor,
    DuplicateTensor,
    MissingTensor,
    InvalidTensorShape,
};

pub const TensorRef = struct {
    index: u16 = INVALID_TENSOR,
    pub fn present(self: TensorRef) bool {
        return self.index != INVALID_TENSOR;
    }
};

pub const LayerKind = enum(u8) { gdn, full_attention };

/// One decoder layer. Which fields are bound depends on `kind`. Both kinds share
/// `attn_norm` (pre-mixer RMSNorm), `post_attention_norm` (pre-FFN RMSNorm), and
/// the SwiGLU FFN triple.
pub const Layer = struct {
    kind: LayerKind = .gdn,
    attn_norm: TensorRef = .{}, // pre-mixer RMSNorm (both kinds)
    post_attention_norm: TensorRef = .{}, // pre-FFN RMSNorm (both kinds)
    // ── full-attention tensors ──
    attn_q: TensorRef = .{}, // query+gate FUSED [hidden, 2*n_head*head_dim]
    attn_k: TensorRef = .{},
    attn_v: TensorRef = .{},
    attn_q_norm: TensorRef = .{}, // per-head RMSNorm over head_dim
    attn_k_norm: TensorRef = .{},
    attn_output: TensorRef = .{},
    // ── GDN (Gated-DeltaNet) tensors ──
    attn_qkv: TensorRef = .{}, // fused q/k/v conv path [hidden, conv_width]
    attn_gate: TensorRef = .{}, // output gate z [hidden, inner]
    ssm_conv1d: TensorRef = .{}, // depthwise causal conv [kernel, conv_width]
    ssm_a: TensorRef = .{}, // A decay [time_step_rank]
    ssm_dt_bias: TensorRef = .{}, // dt bias [time_step_rank]
    ssm_alpha: TensorRef = .{}, // alpha proj [hidden, time_step_rank]
    ssm_beta: TensorRef = .{}, // beta proj [hidden, time_step_rank]
    ssm_norm: TensorRef = .{}, // gated RMSNorm over state_size
    ssm_out: TensorRef = .{}, // output proj [inner, hidden]
    // ── SwiGLU FFN (both kinds) ──
    ffn_gate: TensorRef = .{},
    ffn_up: TensorRef = .{},
    ffn_down: TensorRef = .{},
};

pub const Plan = struct {
    token_embedding: TensorRef = .{},
    output_norm: TensorRef = .{},
    output: TensorRef = .{},
    output_is_tied: bool = false,
    layers: [MAX_LAYERS]Layer = @splat(.{}),
    layer_count: u8 = 0,
    hidden_size: u32 = 0,
    feed_forward_size: u32 = 0,
    head_count: u16 = 0,
    kv_head_count: u16 = 0,
    head_size: u16 = 0,
    vocabulary_size: u32 = 0,
    rope_frequency_base: f32 = 0,
    rope_dimension_count: u16 = 0, // partial RoPE rotate width
    rms_norm_epsilon: f32 = 0,
    full_attention_interval: u8 = 0,
    // GDN params
    ssm_conv_kernel: u16 = 0,
    ssm_state_size: u16 = 0,
    ssm_head_count: u16 = 0, // group_count
    ssm_time_step_rank: u16 = 0,
    ssm_inner_size: u32 = 0,
};

pub fn isFullAttention(interval: u8, layer_idx: usize) bool {
    if (interval == 0) return true; // degenerate: all attention
    return (layer_idx + 1) % interval == 0;
}

pub fn build(comptime tensor_capacity: usize, index: *const gguf.Index(tensor_capacity), out: *Plan) Error!void {
    out.* = .{};
    if (!mem.eql(u8, index.summary.architectureSlice(), "qwen35")) return error.UnsupportedArchitecture;
    if (tensor_capacity > INVALID_TENSOR or index.tensor_count > INVALID_TENSOR) return error.TensorCapacity;

    const s = &index.summary;
    if (s.embedding_length == 0 or s.block_count == 0 or s.block_count > MAX_LAYERS or
        s.head_count == 0 or s.head_count_kv == 0 or s.head_count_kv > s.head_count or
        s.feed_forward_length == 0 or s.full_attention_interval == 0 or
        s.ssm_state_size == 0 or s.ssm_group_count == 0 or s.ssm_inner_size == 0 or
        !math.isFinite(s.rope_frequency_base) or s.rope_frequency_base <= 0 or
        !math.isFinite(s.rms_norm_epsilon) or s.rms_norm_epsilon <= 0)
        return error.InvalidConfiguration;

    const head_size = if (s.attention_key_length != 0) s.attention_key_length else s.embedding_length / s.head_count;
    if (head_size == 0 or head_size > math.maxInt(u16)) return error.InvalidConfiguration;

    out.layer_count = @intCast(s.block_count);
    out.hidden_size = @intCast(s.embedding_length);
    out.feed_forward_size = @intCast(s.feed_forward_length);
    out.head_count = @intCast(s.head_count);
    out.kv_head_count = @intCast(s.head_count_kv);
    out.head_size = @intCast(head_size);
    out.rope_frequency_base = s.rope_frequency_base;
    out.rope_dimension_count = @intCast(if (s.rope_dimension_count != 0) s.rope_dimension_count else head_size);
    out.rms_norm_epsilon = s.rms_norm_epsilon;
    out.full_attention_interval = @intCast(s.full_attention_interval);
    out.ssm_conv_kernel = @intCast(s.ssm_conv_kernel);
    out.ssm_state_size = @intCast(s.ssm_state_size);
    out.ssm_head_count = @intCast(s.ssm_group_count);
    out.ssm_time_step_rank = @intCast(s.ssm_time_step_rank);
    out.ssm_inner_size = @intCast(s.ssm_inner_size);

    const vocab = if (s.vocab_size != 0) s.vocab_size else s.tokenizer_tokens.count;
    if (vocab == 0 or vocab > math.maxInt(u32)) return error.InvalidConfiguration;
    out.vocabulary_size = @intCast(vocab);

    // Tag each layer's kind up front so the binder knows which tensors to expect.
    var li: usize = 0;
    while (li < out.layer_count) : (li += 1) {
        out.layers[li].kind = if (isFullAttention(out.full_attention_interval, li)) .full_attention else .gdn;
    }
    // The interval formula is the documented default, but the concrete GGUF is
    // authoritative — e.g. the final block of the 4B distill is full-attention
    // (and hosts the MTP head) even though (idx+1)%interval != 0. We therefore
    // bind every tensor first, then re-derive each layer's kind from which
    // mixer tensors are actually present (attn_qkv => GDN, attn_q => attention).

    for (index.tensors[0..index.tensor_count], 0..) |tensor, tensor_index| {
        const name = tensor.nameSlice();
        if (mem.eql(u8, name, "token_embd.weight")) {
            try bind(&out.token_embedding, tensor_index);
        } else if (mem.eql(u8, name, "output_norm.weight")) {
            try bind(&out.output_norm, tensor_index);
        } else if (mem.eql(u8, name, "output.weight")) {
            try bind(&out.output, tensor_index);
        } else if (parseLayerName(name)) |parsed| {
            // The qwen35 GGUF ships an extra Multi-Token-Prediction (MTP / NextN)
            // block after the main layers, plus `nextn.*` tensors. MTP is a
            // speculative-decoding head, not part of standard next-token decode,
            // so we skip it (its block index is >= layer_count) and any
            // `nextn.` tensor.
            if (parsed.layer >= out.layer_count) continue;
            if (mem.startsWith(u8, parsed.suffix, "nextn.")) continue;
            try bindLayerTensor(&out.layers[parsed.layer], parsed.suffix, tensor_index);
        } else return error.UnknownTensor;
    }

    // Re-derive layer kind from the tensors that actually bound.
    for (out.layers[0..out.layer_count]) |*layer| {
        if (layer.attn_q.present()) {
            layer.kind = .full_attention;
        } else if (layer.attn_qkv.present()) {
            layer.kind = .gdn;
        } else return error.MissingTensor;
    }

    if (!out.output.present()) {
        out.output = out.token_embedding;
        out.output_is_tied = true;
    }
}

fn bindLayerTensor(layer: *Layer, suffix: []const u8, tensor_index: usize) Error!void {
    const dst: *TensorRef = if (mem.eql(u8, suffix, "attn_norm.weight"))
        &layer.attn_norm
    else if (mem.eql(u8, suffix, "post_attention_norm.weight"))
        &layer.post_attention_norm
    else if (mem.eql(u8, suffix, "ffn_gate.weight"))
        &layer.ffn_gate
    else if (mem.eql(u8, suffix, "ffn_up.weight"))
        &layer.ffn_up
    else if (mem.eql(u8, suffix, "ffn_down.weight"))
        &layer.ffn_down
        // full-attention
    else if (mem.eql(u8, suffix, "attn_q.weight"))
        &layer.attn_q
    else if (mem.eql(u8, suffix, "attn_k.weight"))
        &layer.attn_k
    else if (mem.eql(u8, suffix, "attn_v.weight"))
        &layer.attn_v
    else if (mem.eql(u8, suffix, "attn_q_norm.weight"))
        &layer.attn_q_norm
    else if (mem.eql(u8, suffix, "attn_k_norm.weight"))
        &layer.attn_k_norm
    else if (mem.eql(u8, suffix, "attn_output.weight"))
        &layer.attn_output
        // GDN
    else if (mem.eql(u8, suffix, "attn_qkv.weight"))
        &layer.attn_qkv
    else if (mem.eql(u8, suffix, "attn_gate.weight"))
        &layer.attn_gate
    else if (mem.eql(u8, suffix, "ssm_conv1d.weight"))
        &layer.ssm_conv1d
    else if (mem.eql(u8, suffix, "ssm_a"))
        &layer.ssm_a
    else if (mem.eql(u8, suffix, "ssm_dt.bias"))
        &layer.ssm_dt_bias
    else if (mem.eql(u8, suffix, "ssm_alpha.weight"))
        &layer.ssm_alpha
    else if (mem.eql(u8, suffix, "ssm_beta.weight"))
        &layer.ssm_beta
    else if (mem.eql(u8, suffix, "ssm_norm.weight"))
        &layer.ssm_norm
    else if (mem.eql(u8, suffix, "ssm_out.weight"))
        &layer.ssm_out
    else
        return error.UnknownTensor;
    try bind(dst, tensor_index);
}

fn bind(destination: *TensorRef, index: usize) Error!void {
    if (destination.present()) return error.DuplicateTensor;
    destination.index = @intCast(index);
}

const ParsedLayer = struct { layer: usize, suffix: []const u8 };

fn parseLayerName(name: []const u8) ?ParsedLayer {
    if (!mem.startsWith(u8, name, "blk.")) return null;
    var position: usize = 4;
    var layer: usize = 0;
    var digits: usize = 0;
    while (position < name.len and name[position] >= '0' and name[position] <= '9') : (position += 1) {
        layer = layer * 10 + (name[position] - '0');
        digits += 1;
    }
    if (digits == 0 or position >= name.len or name[position] != '.' or position + 1 == name.len) return null;
    return .{ .layer = layer, .suffix = name[position + 1 ..] };
}
