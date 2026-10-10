//! Exact schema binder for the native SB0M Qwen3-TTS Talker.
//!
//! It produces the same execution plan as the authenticated import binder but
//! additionally requires Q4 matrices, f16 vectors, the native model kind, and
//! exactly the 402 synthesis tensors selected by the pure-Sig packer.

const std = @import("std");
const sb0m = @import("tts_model_container");
const plan_module = @import("tts_talker_plan");

pub const Error = error{
    InvalidModelKind,
    MissingTensor,
    InvalidTensorShape,
    InvalidTensorEncoding,
    InvalidConfiguration,
};

pub fn build(comptime capacity: usize, index: *const sb0m.Index(capacity), output: *plan_module.Plan) Error!void {
    if (index.header.model_kind != .qwen3_tts_0_6b_talker or index.tensor_count != 402)
        return error.InvalidModelKind;
    output.* = .{};
    output.text_embedding = try required(index, "talker.model.text_embedding.weight");
    output.text_projection_1 = try required(index, "talker.text_projection.linear_fc1.weight");
    output.text_projection_1_bias = try required(index, "talker.text_projection.linear_fc1.bias");
    output.text_projection_2 = try required(index, "talker.text_projection.linear_fc2.weight");
    output.text_projection_2_bias = try required(index, "talker.text_projection.linear_fc2.bias");
    output.codec_embedding = try required(index, "talker.model.codec_embedding.weight");
    output.codec_head = try required(index, "talker.codec_head.weight");
    output.bound_tensors = 7;
    output.talker.layer_count = @intCast(plan_module.TALKER_LAYERS);
    try bindDecoder(index, "talker.model.layers", &output.talker, plan_module.TALKER_LAYERS, &output.bound_tensors);
    output.talker.output_norm = try required(index, "talker.model.norm.weight");
    output.bound_tensors += 1;
    output.predictor.layer_count = @intCast(plan_module.PREDICTOR_LAYERS);
    try bindDecoder(index, "talker.code_predictor.model.layers", &output.predictor, plan_module.PREDICTOR_LAYERS, &output.bound_tensors);
    output.predictor.output_norm = try required(index, "talker.code_predictor.model.norm.weight");
    output.bound_tensors += 1;
    var name: [160]u8 = undefined;
    for (0..plan_module.CODE_GROUPS - 1) |group| {
        const embedding_name = std.fmt.bufPrint(&name, "talker.code_predictor.model.codec_embedding.{d}.weight", .{group}) catch
            return error.InvalidConfiguration;
        output.predictor_embeddings[group] = try required(index, embedding_name);
        const head_name = std.fmt.bufPrint(&name, "talker.code_predictor.lm_head.{d}.weight", .{group}) catch
            return error.InvalidConfiguration;
        output.predictor_heads[group] = try required(index, head_name);
        output.bound_tensors += 2;
    }
    try validate(index, output);
    output.talker_macs_per_frame = 443_547_648;
    output.predictor_macs_per_frame = 1_211_105_280;
    output.kv_bytes_per_frame_bf16 = 135_168;
}

fn bindDecoder(
    index: anytype,
    prefix: []const u8,
    decoder: *plan_module.Decoder,
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

fn layerTensor(index: anytype, name: []u8, prefix: []const u8, layer: usize, suffix: []const u8) Error!plan_module.TensorRef {
    const rendered = std.fmt.bufPrint(name, "{s}.{d}.{s}", .{ prefix, layer, suffix }) catch
        return error.InvalidConfiguration;
    return required(index, rendered);
}

fn required(index: anytype, name: []const u8) Error!plan_module.TensorRef {
    for (index.tensors[0..index.tensor_count], 0..) |*candidate, tensor_index|
        if (std.mem.eql(u8, candidate.name(), name)) return .{ .index = @intCast(tensor_index) };
    return error.MissingTensor;
}

fn validate(index: anytype, plan: *const plan_module.Plan) Error!void {
    try matrix(index, plan.text_embedding, plan_module.TEXT_VOCABULARY, plan_module.TEXT_HIDDEN);
    try matrix(index, plan.text_projection_1, plan_module.TEXT_HIDDEN, plan_module.TEXT_HIDDEN);
    try vector(index, plan.text_projection_1_bias, plan_module.TEXT_HIDDEN);
    try matrix(index, plan.text_projection_2, plan_module.HIDDEN, plan_module.TEXT_HIDDEN);
    try vector(index, plan.text_projection_2_bias, plan_module.HIDDEN);
    try matrix(index, plan.codec_embedding, plan_module.CODEC_VOCABULARY, plan_module.HIDDEN);
    try matrix(index, plan.codec_head, plan_module.CODEC_VOCABULARY, plan_module.HIDDEN);
    try validateDecoder(index, &plan.talker, plan_module.TALKER_LAYERS);
    try validateDecoder(index, &plan.predictor, plan_module.PREDICTOR_LAYERS);
    for (plan.predictor_embeddings) |reference|
        try matrix(index, reference, plan_module.ACOUSTIC_VOCABULARY, plan_module.HIDDEN);
    for (plan.predictor_heads) |reference|
        try matrix(index, reference, plan_module.ACOUSTIC_VOCABULARY, plan_module.HIDDEN);
}

fn validateDecoder(index: anytype, decoder: *const plan_module.Decoder, expected_layers: usize) Error!void {
    if (decoder.layer_count != expected_layers) return error.InvalidConfiguration;
    try vector(index, decoder.output_norm, plan_module.HIDDEN);
    for (decoder.layers[0..decoder.layer_count]) |layer| {
        try vector(index, layer.attention_norm, plan_module.HIDDEN);
        try matrix(index, layer.query, plan_module.QUERY, plan_module.HIDDEN);
        try matrix(index, layer.key, plan_module.KEY_VALUE, plan_module.HIDDEN);
        try matrix(index, layer.value, plan_module.KEY_VALUE, plan_module.HIDDEN);
        try matrix(index, layer.attention_output, plan_module.HIDDEN, plan_module.QUERY);
        try vector(index, layer.query_norm, plan_module.HEAD_DIM);
        try vector(index, layer.key_norm, plan_module.HEAD_DIM);
        try vector(index, layer.ffn_norm, plan_module.HIDDEN);
        try matrix(index, layer.ffn_gate, plan_module.FEED_FORWARD, plan_module.HIDDEN);
        try matrix(index, layer.ffn_up, plan_module.FEED_FORWARD, plan_module.HIDDEN);
        try matrix(index, layer.ffn_down, plan_module.HIDDEN, plan_module.FEED_FORWARD);
    }
}

fn tensor(index: anytype, reference: plan_module.TensorRef) *const sb0m.Tensor {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

fn vector(index: anytype, reference: plan_module.TensorRef, elements: u64) Error!void {
    const value = tensor(index, reference);
    if (value.encoding != .f16) return error.InvalidTensorEncoding;
    if (value.rank != 1 or value.dimensions[0] != elements) return error.InvalidTensorShape;
}

fn matrix(index: anytype, reference: plan_module.TensorRef, rows: u64, columns: u64) Error!void {
    const value = tensor(index, reference);
    if (value.encoding != .sb0_q4) return error.InvalidTensorEncoding;
    if (value.rank != 2 or value.dimensions[0] != rows or value.dimensions[1] != columns)
        return error.InvalidTensorShape;
}

test "native plan keeps the exact import execution contract" {
    try std.testing.expectEqual(@as(usize, 402), 7 + plan_module.TALKER_LAYERS * 11 + 1 + plan_module.PREDICTOR_LAYERS * 11 + 1 + 30);
}
