//! LFM3 (`lfm3`) hybrid decoder schema binder.
//!
//! LFM3 interleaves two mixers behind one pre-mixer RMSNorm and one SwiGLU
//! FFN per layer:
//!   - gated short convolution: in_proj -> (B, C, X), depthwise causal conv of
//!     B*X over `shortconv.l_cache` taps with a rolling per-layer state, C gate,
//!     out_proj;
//!   - grouped-query attention with per-head Q/K RMSNorm, NeoX RoPE and a
//!     per-head sigmoid output gate. Sliding-window layers use their own RoPE
//!     base; full layers scale RoPE frequencies by the shared `rope_freqs`.
//! The schedule is metadata, not a formula: a per-layer KV head count of zero
//! marks a convolution layer and `attention.sliding_window_pattern` marks the
//! windowed attention layers. Optional post-mixer/post-FFN "sandwich" norms are
//! bound when present (both or neither).
//!
//! Tensor names and shapes follow llama.cpp's lfm3 loader, read directly from
//! LiquidAI's LFM3-Audio-2B GGUF. Product names never reach generic storage.

const math = @import("sig_math");
const mem = @import("sig_mem");
const gguf = @import("gguf");

pub const MAX_LAYERS: usize = 64;
pub const MAX_CONV_KERNEL: usize = 16;
pub const INVALID_TENSOR: u16 = math.maxInt(u16);
pub const INVALID_SLOT: u8 = math.maxInt(u8);

pub const Error = error{
    UnsupportedArchitecture,
    InvalidConfiguration,
    InvalidLayerSchedule,
    StorageFailure,
    TensorCapacity,
    UnknownTensor,
    DuplicateTensor,
    MissingTensor,
    UnexpectedTensor,
    InvalidTensorShape,
    UnsupportedTensorType,
};

pub const TensorRef = struct {
    index: u16 = INVALID_TENSOR,
    pub fn present(self: TensorRef) bool {
        return self.index != INVALID_TENSOR;
    }
};

pub const LayerKind = enum(u8) { short_conv, attention };

pub const Layer = struct {
    kind: LayerKind = .short_conv,
    sliding_window: bool = false,
    kv_head_count: u16 = 0,
    /// Index among layers of the same kind: the conv-state row block for
    /// short_conv layers, the KV-cache block for attention layers.
    slot: u8 = INVALID_SLOT,
    attn_norm: TensorRef = .{}, // pre-mixer RMSNorm (both kinds)
    post_attention_norm: TensorRef = .{}, // optional post-mixer RMSNorm
    ffn_norm: TensorRef = .{},
    post_ffw_norm: TensorRef = .{}, // optional post-FFN RMSNorm
    ffn_gate: TensorRef = .{},
    ffn_up: TensorRef = .{},
    ffn_down: TensorRef = .{},
    // ── short convolution ──
    conv: TensorRef = .{}, // depthwise taps [l_cache, hidden], f32
    in_proj: TensorRef = .{}, // [hidden, 3*hidden] -> B, C, X
    out_proj: TensorRef = .{}, // [hidden, hidden]
    // ── attention ──
    attn_q: TensorRef = .{},
    attn_k: TensorRef = .{},
    attn_v: TensorRef = .{},
    attn_q_norm: TensorRef = .{},
    attn_k_norm: TensorRef = .{},
    attn_gate: TensorRef = .{}, // [hidden, head_count]: one sigmoid gate per head
    attn_output: TensorRef = .{},
};

pub const Plan = struct {
    token_embedding: TensorRef = .{},
    output_norm: TensorRef = .{},
    output: TensorRef = .{},
    output_is_tied: bool = false,
    rope_factors: TensorRef = .{}, // optional [head_size/2] divisor for full layers
    layers: [MAX_LAYERS]Layer = @splat(.{}),
    layer_count: u8 = 0,
    conv_layer_count: u8 = 0,
    attention_layer_count: u8 = 0,
    hidden_size: u32 = 0,
    feed_forward_size: u32 = 0,
    head_count: u16 = 0,
    max_kv_head_count: u16 = 0,
    head_size: u16 = 0,
    vocabulary_size: u32 = 0,
    rope_frequency_base: f32 = 0,
    rope_frequency_base_swa: f32 = 0,
    rope_dimension_count: u16 = 0,
    rms_norm_epsilon: f32 = 0,
    sliding_window: u32 = 0,
    conv_kernel: u16 = 0,
    sandwich_norms: bool = false,

    pub fn queryWidth(self: *const Plan) usize {
        return @as(usize, self.head_count) * self.head_size;
    }
};

/// The per-layer mixer chosen by a KV head count, exactly llama.cpp's
/// `is_recr = n_head_kv(il) == 0`.
pub fn layerKind(kv_head_count: u32) LayerKind {
    return if (kv_head_count == 0) .short_conv else .attention;
}

/// Positions a query at `query_position` may read. Sliding-window layers drop
/// keys whose distance reaches the window (llama.cpp LLAMA_SWA_TYPE_STANDARD);
/// full layers read the whole causal prefix.
pub fn firstVisiblePosition(sliding_window: bool, window: u32, query_position: usize) usize {
    if (!sliding_window or query_position < window) return 0;
    return query_position - window + 1;
}

pub fn build(comptime tensor_capacity: usize, source: gguf.Source, index: *const gguf.Index(tensor_capacity), out: *Plan) Error!void {
    out.* = .{};
    if (!mem.eql(u8, index.summary.architectureSlice(), "lfm3")) return error.UnsupportedArchitecture;
    if (tensor_capacity > INVALID_TENSOR or index.tensor_count > INVALID_TENSOR) return error.TensorCapacity;

    const s = &index.summary;
    if (s.embedding_length == 0 or s.embedding_length > math.maxInt(u32) or
        s.block_count == 0 or s.block_count > MAX_LAYERS or
        s.head_count == 0 or s.head_count > math.maxInt(u16) or
        s.feed_forward_length == 0 or s.feed_forward_length > math.maxInt(u32) or
        s.shortconv_l_cache < 2 or s.shortconv_l_cache > MAX_CONV_KERNEL or
        s.sliding_window == 0 or s.sliding_window > math.maxInt(u32) or
        !math.isFinite(s.rope_frequency_base) or s.rope_frequency_base <= 0 or
        !math.isFinite(s.rope_frequency_base_swa) or s.rope_frequency_base_swa <= 0 or
        !math.isFinite(s.rms_norm_epsilon) or s.rms_norm_epsilon <= 0)
        return error.InvalidConfiguration;

    const head_size = if (s.attention_key_length != 0) s.attention_key_length else s.embedding_length / s.head_count;
    if (head_size == 0 or head_size % 2 != 0 or head_size > math.maxInt(u16) or
        (s.attention_value_length != 0 and s.attention_value_length != head_size)) return error.InvalidConfiguration;
    const rope_dimensions = if (s.rope_dimension_count != 0) s.rope_dimension_count else head_size;
    if (rope_dimensions != head_size) return error.InvalidConfiguration;

    out.layer_count = @intCast(s.block_count);
    out.hidden_size = @intCast(s.embedding_length);
    out.feed_forward_size = @intCast(s.feed_forward_length);
    out.head_count = @intCast(s.head_count);
    out.head_size = @intCast(head_size);
    out.rope_frequency_base = s.rope_frequency_base;
    out.rope_frequency_base_swa = s.rope_frequency_base_swa;
    out.rope_dimension_count = @intCast(rope_dimensions);
    out.rms_norm_epsilon = s.rms_norm_epsilon;
    out.sliding_window = @intCast(s.sliding_window);
    out.conv_kernel = @intCast(s.shortconv_l_cache);

    const vocab = if (s.vocab_size != 0) s.vocab_size else s.tokenizer_tokens.count;
    if (vocab == 0 or vocab > math.maxInt(u32)) return error.InvalidConfiguration;
    out.vocabulary_size = @intCast(vocab);

    try readSchedule(source, s, out);

    for (index.tensors[0..index.tensor_count], 0..) |tensor, tensor_index| {
        const name = tensor.nameSlice();
        if (mem.eql(u8, name, "token_embd.weight")) {
            try bind(&out.token_embedding, tensor_index);
        } else if (mem.eql(u8, name, "output_norm.weight")) {
            try bind(&out.output_norm, tensor_index);
        } else if (mem.eql(u8, name, "output.weight")) {
            try bind(&out.output, tensor_index);
        } else if (mem.eql(u8, name, "rope_freqs.weight")) {
            try bind(&out.rope_factors, tensor_index);
        } else if (parseLayerName(name)) |parsed| {
            if (parsed.layer >= out.layer_count) return error.UnknownTensor;
            try bindLayerTensor(&out.layers[parsed.layer], parsed.suffix, tensor_index);
        } else return error.UnknownTensor;
    }
    if (!out.output.present()) {
        out.output = out.token_embedding;
        out.output_is_tied = true;
    }
    try validate(tensor_capacity, index, out);
}

fn readSchedule(source: gguf.Source, s: *const gguf.Summary, out: *Plan) Error!void {
    const counts = s.head_count_kv_layers;
    const pattern = s.sliding_window_pattern;
    if (!counts.present or counts.count != s.block_count or (counts.element_type != 4 and counts.element_type != 5) or
        !pattern.present or pattern.count != s.block_count or pattern.element_type != 7) return error.InvalidLayerSchedule;
    var any_window = false;
    for (out.layers[0..out.layer_count], 0..) |*layer, layer_index| {
        var raw: [4]u8 = undefined;
        if (!source.read(counts.data_offset + layer_index * 4, &raw)) return error.StorageFailure;
        const signed: i64 = if (counts.element_type == 5) mem.readInt(i32, &raw, .little) else mem.readInt(u32, &raw, .little);
        if (signed < 0 or signed > out.head_count or (signed != 0 and out.head_count % @as(u32, @intCast(signed)) != 0))
            return error.InvalidLayerSchedule;
        var flag: [1]u8 = undefined;
        if (!source.read(pattern.data_offset + layer_index, &flag)) return error.StorageFailure;
        if (flag[0] > 1) return error.InvalidLayerSchedule;

        layer.kv_head_count = @intCast(signed);
        layer.kind = layerKind(layer.kv_head_count);
        layer.sliding_window = flag[0] == 1;
        switch (layer.kind) {
            .short_conv => {
                if (layer.sliding_window) return error.InvalidLayerSchedule;
                layer.slot = out.conv_layer_count;
                out.conv_layer_count += 1;
            },
            .attention => {
                layer.slot = out.attention_layer_count;
                out.attention_layer_count += 1;
                out.max_kv_head_count = @max(out.max_kv_head_count, layer.kv_head_count);
                any_window = any_window or layer.sliding_window;
            },
        }
    }
    // llama.cpp refuses an lfm3 file without sliding layers; so do we.
    if (out.attention_layer_count == 0 or !any_window) return error.InvalidLayerSchedule;
}

fn validate(comptime tensor_capacity: usize, index: *const gguf.Index(tensor_capacity), plan: *Plan) Error!void {
    const hidden: u64 = plan.hidden_size;
    const head: u64 = plan.head_size;
    const query: u64 = plan.queryWidth();
    try expectMatrix(index, plan.token_embedding, hidden, plan.vocabulary_size);
    try expectMatrix(index, plan.output, hidden, plan.vocabulary_size);
    try expectVector(index, plan.output_norm, hidden);
    var has_full = false;
    var sandwich: ?bool = null;
    for (plan.layers[0..plan.layer_count]) |*layer| {
        try expectVector(index, layer.attn_norm, hidden);
        try expectVector(index, layer.ffn_norm, hidden);
        try expectMatrix(index, layer.ffn_gate, hidden, plan.feed_forward_size);
        try expectMatrix(index, layer.ffn_up, hidden, plan.feed_forward_size);
        try expectMatrix(index, layer.ffn_down, plan.feed_forward_size, hidden);
        if (layer.post_attention_norm.present() != layer.post_ffw_norm.present()) return error.MissingTensor;
        const has_sandwich = layer.post_attention_norm.present();
        if (sandwich) |expected| {
            if (expected != has_sandwich) return error.MissingTensor;
        } else sandwich = has_sandwich;
        if (has_sandwich) {
            try expectVector(index, layer.post_attention_norm, hidden);
            try expectVector(index, layer.post_ffw_norm, hidden);
        }
        switch (layer.kind) {
            .short_conv => {
                for ([_]TensorRef{ layer.attn_q, layer.attn_k, layer.attn_v, layer.attn_q_norm, layer.attn_k_norm, layer.attn_gate, layer.attn_output }) |reference|
                    if (reference.present()) return error.UnexpectedTensor;
                try expectF32(index, layer.conv, plan.conv_kernel, hidden);
                try expectMatrix(index, layer.in_proj, hidden, 3 * hidden);
                try expectMatrix(index, layer.out_proj, hidden, hidden);
            },
            .attention => {
                for ([_]TensorRef{ layer.conv, layer.in_proj, layer.out_proj }) |reference|
                    if (reference.present()) return error.UnexpectedTensor;
                const key_value = @as(u64, layer.kv_head_count) * head;
                try expectMatrix(index, layer.attn_q, hidden, query);
                try expectMatrix(index, layer.attn_k, hidden, key_value);
                try expectMatrix(index, layer.attn_v, hidden, key_value);
                try expectVector(index, layer.attn_q_norm, head);
                try expectVector(index, layer.attn_k_norm, head);
                try expectMatrix(index, layer.attn_gate, hidden, plan.head_count);
                try expectMatrix(index, layer.attn_output, query, hidden);
                has_full = has_full or !layer.sliding_window;
            },
        }
    }
    plan.sandwich_norms = sandwich orelse false;
    // llama.cpp requires the frequency factors once any full layer exists.
    if (plan.rope_factors.present()) {
        try expectVector(index, plan.rope_factors, head / 2);
    } else if (has_full) return error.MissingTensor;
}

fn expectVector(index: anytype, reference: TensorRef, length: u64) Error!void {
    try expectF32(index, reference, length, null);
}

fn expectF32(index: anytype, reference: TensorRef, inner: u64, outer: ?u64) Error!void {
    if (!reference.present()) return error.MissingTensor;
    const tensor = &index.tensors[reference.index];
    if (tensor.ggml_type != 0) return error.UnsupportedTensorType;
    const dimensions: u8 = if (outer == null) 1 else 2;
    if (tensor.dimension_count != dimensions or tensor.dimensions[0] != inner or
        (outer != null and tensor.dimensions[1] != outer.?)) return error.InvalidTensorShape;
}

/// Matrices are stored GGML-style as [input, output]: one quantized row per
/// output feature. The executor's integer kernels cover Q4_K and Q6_K.
fn expectMatrix(index: anytype, reference: TensorRef, input: u64, output: u64) Error!void {
    if (!reference.present()) return error.MissingTensor;
    const tensor = &index.tensors[reference.index];
    if (tensor.ggml_type != 12 and tensor.ggml_type != 14) return error.UnsupportedTensorType;
    if (tensor.dimension_count != 2 or tensor.dimensions[0] != input or tensor.dimensions[1] != output)
        return error.InvalidTensorShape;
}

fn bindLayerTensor(layer: *Layer, suffix: []const u8, tensor_index: usize) Error!void {
    const names = .{
        .{ "attn_norm.weight", "attn_norm" },
        .{ "post_attention_norm.weight", "post_attention_norm" },
        .{ "ffn_norm.weight", "ffn_norm" },
        .{ "post_ffw_norm.weight", "post_ffw_norm" },
        .{ "ffn_gate.weight", "ffn_gate" },
        .{ "ffn_up.weight", "ffn_up" },
        .{ "ffn_down.weight", "ffn_down" },
        .{ "shortconv.conv.weight", "conv" },
        .{ "shortconv.in_proj.weight", "in_proj" },
        .{ "shortconv.out_proj.weight", "out_proj" },
        .{ "attn_q.weight", "attn_q" },
        .{ "attn_k.weight", "attn_k" },
        .{ "attn_v.weight", "attn_v" },
        .{ "attn_q_norm.weight", "attn_q_norm" },
        .{ "attn_k_norm.weight", "attn_k_norm" },
        .{ "attn_gate.weight", "attn_gate" },
        .{ "attn_output.weight", "attn_output" },
    };
    inline for (names) |entry| {
        if (mem.eql(u8, suffix, entry[0])) return bind(&@field(layer, entry[1]), tensor_index);
    }
    return error.UnknownTensor;
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
    while (position < name.len and name[position] >= '0' and name[position] <= '9' and digits < 4) : (position += 1) {
        layer = layer * 10 + (name[position] - '0');
        digits += 1;
    }
    if (digits == 0 or position >= name.len or name[position] != '.' or position + 1 == name.len) return null;
    return .{ .layer = layer, .suffix = name[position + 1 ..] };
}
