//! Exact Qwen3-TTS-12Hz-0.6B Talker schema binder.
//!
//! The released Base checkpoint contains unrelated speaker-encoder tensors.
//! This plan selects only the text projection, 28-layer Talker, 5-layer code
//! predictor, and sixteen codec heads required for synthesis, validating every
//! dtype and dimension against the pinned architecture.

const std = @import("std");
const safe = @import("sb0_safetensors_v1");

pub const TALKER_LAYERS: usize = 28;
pub const PREDICTOR_LAYERS: usize = 5;
pub const CODE_GROUPS: usize = 16;
pub const HIDDEN: usize = 1024;
pub const TEXT_HIDDEN: usize = 2048;
pub const QUERY: usize = 2048;
pub const KEY_VALUE: usize = 1024;
pub const FEED_FORWARD: usize = 3072;
pub const HEADS: usize = 16;
pub const KV_HEADS: usize = 8;
pub const HEAD_DIM: usize = 128;
pub const TEXT_VOCABULARY: usize = 151_936;
pub const CODEC_VOCABULARY: usize = 3_072;
pub const ACOUSTIC_VOCABULARY: usize = 2_048;
pub const RMS_EPSILON: f32 = 1.0e-6;
pub const ROPE_THETA: f32 = 1_000_000.0;

pub const CODEC_PAD: u16 = 2148;
pub const CODEC_BOS: u16 = 2149;
pub const CODEC_EOS: u16 = 2150;
pub const CODEC_THINK: u16 = 2154;
pub const CODEC_NOTHINK: u16 = 2155;
pub const CODEC_THINK_BOS: u16 = 2156;
pub const CODEC_THINK_EOS: u16 = 2157;
pub const CODEC_ENGLISH: u16 = 2050;
pub const TEXT_TTS_PAD: u32 = 151_671;
pub const TEXT_TTS_BOS: u32 = 151_672;
pub const TEXT_TTS_EOS: u32 = 151_673;

pub const INVALID_TENSOR: u16 = std.math.maxInt(u16);

pub const Error = error{
    MissingTensor,
    InvalidTensorShape,
    InvalidTensorType,
    InvalidConfiguration,
    ArithmeticOverflow,
};

pub const TensorRef = struct {
    index: u16 = INVALID_TENSOR,

    pub fn present(self: TensorRef) bool {
        return self.index != INVALID_TENSOR;
    }
};

pub const Layer = struct {
    attention_norm: TensorRef = .{},
    query: TensorRef = .{},
    key: TensorRef = .{},
    value: TensorRef = .{},
    attention_output: TensorRef = .{},
    query_norm: TensorRef = .{},
    key_norm: TensorRef = .{},
    ffn_norm: TensorRef = .{},
    ffn_gate: TensorRef = .{},
    ffn_up: TensorRef = .{},
    ffn_down: TensorRef = .{},
};

pub const Decoder = struct {
    layers: [TALKER_LAYERS]Layer = @splat(.{}),
    layer_count: u8 = 0,
    output_norm: TensorRef = .{},
};

pub const Plan = struct {
    text_embedding: TensorRef = .{},
    text_projection_1: TensorRef = .{},
    text_projection_1_bias: TensorRef = .{},
    text_projection_2: TensorRef = .{},
    text_projection_2_bias: TensorRef = .{},
    codec_embedding: TensorRef = .{},
    codec_head: TensorRef = .{},
    talker: Decoder = .{},
    predictor: Decoder = .{},
    predictor_embeddings: [CODE_GROUPS - 1]TensorRef = @splat(.{}),
    predictor_heads: [CODE_GROUPS - 1]TensorRef = @splat(.{}),
    bound_tensors: u16 = 0,
    talker_macs_per_frame: u64 = 0,
    predictor_macs_per_frame: u64 = 0,
    kv_bytes_per_frame_bf16: u64 = 0,
};

pub fn build(comptime capacity: usize, index: *const safe.Index(capacity), output: *Plan) Error!void {
    output.* = .{};
    output.text_embedding = try required(index, "talker.model.text_embedding.weight");
    output.text_projection_1 = try required(index, "talker.text_projection.linear_fc1.weight");
    output.text_projection_1_bias = try required(index, "talker.text_projection.linear_fc1.bias");
    output.text_projection_2 = try required(index, "talker.text_projection.linear_fc2.weight");
    output.text_projection_2_bias = try required(index, "talker.text_projection.linear_fc2.bias");
    output.codec_embedding = try required(index, "talker.model.codec_embedding.weight");
    output.codec_head = try required(index, "talker.codec_head.weight");
    output.bound_tensors = 7;

    output.talker.layer_count = @intCast(TALKER_LAYERS);
    try bindDecoder(capacity, index, "talker.model.layers", &output.talker, TALKER_LAYERS, &output.bound_tensors);
    output.talker.output_norm = try required(index, "talker.model.norm.weight");
    output.bound_tensors += 1;

    output.predictor.layer_count = @intCast(PREDICTOR_LAYERS);
    try bindDecoder(capacity, index, "talker.code_predictor.model.layers", &output.predictor, PREDICTOR_LAYERS, &output.bound_tensors);
    output.predictor.output_norm = try required(index, "talker.code_predictor.model.norm.weight");
    output.bound_tensors += 1;
    var name: [160]u8 = undefined;
    for (0..CODE_GROUPS - 1) |group| {
        const embedding_name = std.fmt.bufPrint(
            &name,
            "talker.code_predictor.model.codec_embedding.{d}.weight",
            .{group},
        ) catch return error.InvalidConfiguration;
        output.predictor_embeddings[group] = try required(index, embedding_name);
        const head_name = std.fmt.bufPrint(
            &name,
            "talker.code_predictor.lm_head.{d}.weight",
            .{group},
        ) catch return error.InvalidConfiguration;
        output.predictor_heads[group] = try required(index, head_name);
        output.bound_tensors += 2;
    }
    try validate(capacity, index, output);
    output.talker_macs_per_frame = try decoderMacs(TALKER_LAYERS, CODEC_VOCABULARY);
    output.predictor_macs_per_frame = try multiply(try decoderMacs(PREDICTOR_LAYERS, ACOUSTIC_VOCABULARY), CODE_GROUPS - 1);
    output.kv_bytes_per_frame_bf16 = try multiply(
        try multiply(TALKER_LAYERS + PREDICTOR_LAYERS, 2 * KEY_VALUE),
        @sizeOf(u16),
    );
}

fn bindDecoder(
    comptime capacity: usize,
    index: *const safe.Index(capacity),
    prefix: []const u8,
    decoder: *Decoder,
    layer_count: usize,
    bound: *u16,
) Error!void {
    var name: [192]u8 = undefined;
    for (decoder.layers[0..layer_count], 0..) |*layer, layer_index| {
        layer.attention_norm = try layerTensor(index, &name, prefix, layer_index, "input_layernorm.weight");
        layer.query = try layerTensor(index, &name, prefix, layer_index, "self_attn.q_proj.weight");
        layer.key = try layerTensor(index, &name, prefix, layer_index, "self_attn.k_proj.weight");
        layer.value = try layerTensor(index, &name, prefix, layer_index, "self_attn.v_proj.weight");
        layer.attention_output = try layerTensor(index, &name, prefix, layer_index, "self_attn.o_proj.weight");
        layer.query_norm = try layerTensor(index, &name, prefix, layer_index, "self_attn.q_norm.weight");
        layer.key_norm = try layerTensor(index, &name, prefix, layer_index, "self_attn.k_norm.weight");
        layer.ffn_norm = try layerTensor(index, &name, prefix, layer_index, "post_attention_layernorm.weight");
        layer.ffn_gate = try layerTensor(index, &name, prefix, layer_index, "mlp.gate_proj.weight");
        layer.ffn_up = try layerTensor(index, &name, prefix, layer_index, "mlp.up_proj.weight");
        layer.ffn_down = try layerTensor(index, &name, prefix, layer_index, "mlp.down_proj.weight");
        bound.* += 11;
    }
}

fn layerTensor(
    index: anytype,
    name: []u8,
    prefix: []const u8,
    layer: usize,
    suffix: []const u8,
) Error!TensorRef {
    const rendered = std.fmt.bufPrint(name, "{s}.{d}.{s}", .{ prefix, layer, suffix }) catch
        return error.InvalidConfiguration;
    return required(index, rendered);
}

fn required(index: anytype, name: []const u8) Error!TensorRef {
    return .{ .index = index.find(name) orelse return error.MissingTensor };
}

fn validate(comptime capacity: usize, index: *const safe.Index(capacity), plan: *const Plan) Error!void {
    try matrix(index, plan.text_embedding, TEXT_VOCABULARY, TEXT_HIDDEN);
    try matrix(index, plan.text_projection_1, TEXT_HIDDEN, TEXT_HIDDEN);
    try vector(index, plan.text_projection_1_bias, TEXT_HIDDEN);
    try matrix(index, plan.text_projection_2, HIDDEN, TEXT_HIDDEN);
    try vector(index, plan.text_projection_2_bias, HIDDEN);
    try matrix(index, plan.codec_embedding, CODEC_VOCABULARY, HIDDEN);
    try matrix(index, plan.codec_head, CODEC_VOCABULARY, HIDDEN);
    try validateDecoder(index, &plan.talker, TALKER_LAYERS);
    try validateDecoder(index, &plan.predictor, PREDICTOR_LAYERS);
    for (plan.predictor_embeddings) |reference| try matrix(index, reference, ACOUSTIC_VOCABULARY, HIDDEN);
    for (plan.predictor_heads) |reference| try matrix(index, reference, ACOUSTIC_VOCABULARY, HIDDEN);
}

fn validateDecoder(index: anytype, decoder: *const Decoder, expected_layers: usize) Error!void {
    if (decoder.layer_count != expected_layers) return error.InvalidConfiguration;
    try vector(index, decoder.output_norm, HIDDEN);
    for (decoder.layers[0..decoder.layer_count]) |layer| {
        try vector(index, layer.attention_norm, HIDDEN);
        try matrix(index, layer.query, QUERY, HIDDEN);
        try matrix(index, layer.key, KEY_VALUE, HIDDEN);
        try matrix(index, layer.value, KEY_VALUE, HIDDEN);
        try matrix(index, layer.attention_output, HIDDEN, QUERY);
        try vector(index, layer.query_norm, HEAD_DIM);
        try vector(index, layer.key_norm, HEAD_DIM);
        try vector(index, layer.ffn_norm, HIDDEN);
        try matrix(index, layer.ffn_gate, FEED_FORWARD, HIDDEN);
        try matrix(index, layer.ffn_up, FEED_FORWARD, HIDDEN);
        try matrix(index, layer.ffn_down, HIDDEN, FEED_FORWARD);
    }
}

fn tensor(index: anytype, reference: TensorRef) *const safe.TensorInfo {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

fn vector(index: anytype, reference: TensorRef, elements: u64) Error!void {
    const value = tensor(index, reference);
    if (value.dtype != .bf16) return error.InvalidTensorType;
    if (value.dimension_count != 1 or value.dimensions[0] != elements) return error.InvalidTensorShape;
}

fn matrix(index: anytype, reference: TensorRef, rows: u64, columns: u64) Error!void {
    const value = tensor(index, reference);
    if (value.dtype != .bf16) return error.InvalidTensorType;
    if (value.dimension_count != 2 or value.dimensions[0] != rows or value.dimensions[1] != columns)
        return error.InvalidTensorShape;
}

fn decoderMacs(layers: usize, vocabulary: usize) Error!u64 {
    const projections = try add(try multiply(HIDDEN, QUERY), try multiply(2 * HIDDEN, KEY_VALUE));
    const attention_output = try multiply(HIDDEN, QUERY);
    const feed_forward = try multiply(3 * HIDDEN, FEED_FORWARD);
    const per_layer = try add(try add(projections, attention_output), feed_forward);
    return add(try multiply(layers, per_layer), try multiply(HIDDEN, vocabulary));
}

fn add(left: anytype, right: anytype) Error!u64 {
    const result = @addWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn multiply(left: anytype, right: anytype) Error!u64 {
    const result = @mulWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

test "released architecture constants are internally exact" {
    try std.testing.expectEqual(@as(usize, QUERY), HEADS * HEAD_DIM);
    try std.testing.expectEqual(@as(usize, KEY_VALUE), KV_HEADS * HEAD_DIM);
    try std.testing.expectEqual(@as(u64, 443_547_648), try decoderMacs(TALKER_LAYERS, CODEC_VOCABULARY));
    try std.testing.expectEqual(@as(u64, 1_211_105_280), try multiply(try decoderMacs(PREDICTOR_LAYERS, ACOUSTIC_VOCABULARY), CODE_GROUPS - 1));
}
