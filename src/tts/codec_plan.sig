//! Exact native execution plan for the Qwen3-TTS 12 Hz speech decoder.
//!
//! The plan binds every tensor used by codes-to-PCM decode once at admission.
//! It rejects architecture drift, shape changes, padded convolutions, and an
//! encoding that differs from the native no-padding Q4/f16 policy.

const std = @import("std");
const sb0m = @import("tts_model_container");

pub const CODE_GROUPS: usize = 16;
pub const REST_CODE_GROUPS: usize = 15;
pub const CODEBOOK_SIZE: usize = 2048;
pub const CODEBOOK_HIDDEN: usize = 256;
pub const CODEBOOK_DIM: usize = 512;
pub const LATENT: usize = 1024;
pub const TRANSFORMER_HIDDEN: usize = 512;
pub const TRANSFORMER_INTERMEDIATE: usize = 1024;
pub const TRANSFORMER_QUERY: usize = 1024;
pub const TRANSFORMER_LAYERS: usize = 8;
pub const TRANSFORMER_HEADS: usize = 16;
pub const HEAD_DIM: usize = 64;
pub const SLIDING_WINDOW: usize = 72;
pub const PRE_UPSAMPLE_STAGES: usize = 2;
pub const DECODER_STAGES: usize = 4;
pub const RESIDUAL_UNITS: usize = 3;
pub const SAMPLES_PER_FRAME: usize = 1920;
pub const SAMPLE_RATE: usize = 24_000;
pub const NATIVE_TENSORS: usize = 271;
pub const BOUND_TENSORS: usize = 269;

pub const TensorRef = struct {
    index: u16 = std.math.maxInt(u16),
    pub fn present(self: TensorRef) bool { return self.index != std.math.maxInt(u16); }
};

pub const Linear = struct { weight: TensorRef = .{}, bias: TensorRef = .{} };
pub const Conv = Linear;
pub const Snake = struct { alpha: TensorRef = .{}, beta: TensorRef = .{} };

pub const TransformerLayer = struct {
    input_norm: TensorRef = .{},
    query: TensorRef = .{},
    key: TensorRef = .{},
    value: TensorRef = .{},
    attention_output: TensorRef = .{},
    attention_scale: TensorRef = .{},
    post_attention_norm: TensorRef = .{},
    ffn_gate: TensorRef = .{},
    ffn_up: TensorRef = .{},
    ffn_down: TensorRef = .{},
    ffn_scale: TensorRef = .{},
};

pub const ConvNext = struct {
    depthwise: Conv = .{},
    norm_weight: TensorRef = .{},
    norm_bias: TensorRef = .{},
    pointwise_1: Linear = .{},
    pointwise_2: Linear = .{},
    gamma: TensorRef = .{},
};

pub const PreUpsample = struct {
    transposed: Conv = .{},
    conv_next: ConvNext = .{},
};

pub const ResidualUnit = struct {
    act_1: Snake = .{},
    conv_1: Conv = .{},
    act_2: Snake = .{},
    conv_2: Conv = .{},
};

pub const DecoderStage = struct {
    activation: Snake = .{},
    transposed: Conv = .{},
    residual: [RESIDUAL_UNITS]ResidualUnit = @splat(ResidualUnit{}),
};

pub const Plan = struct {
    first_cluster: TensorRef = .{},
    first_embedding: TensorRef = .{},
    first_output: TensorRef = .{},
    rest_cluster: [REST_CODE_GROUPS]TensorRef = @splat(TensorRef{}),
    rest_embedding: [REST_CODE_GROUPS]TensorRef = @splat(TensorRef{}),
    rest_output: TensorRef = .{},
    pre_conv: Conv = .{},
    transformer_input: Linear = .{},
    transformer_layers: [TRANSFORMER_LAYERS]TransformerLayer = @splat(TransformerLayer{}),
    transformer_norm: TensorRef = .{},
    transformer_output: Linear = .{},
    pre_upsample: [PRE_UPSAMPLE_STAGES]PreUpsample = @splat(PreUpsample{}),
    decoder_input: Conv = .{},
    decoder_stages: [DECODER_STAGES]DecoderStage = @splat(DecoderStage{}),
    output_activation: Snake = .{},
    output_conv: Conv = .{},
    bound_tensors: u16 = 0,
};

pub const Error = error{
    InvalidModelKind,
    MissingTensor,
    InvalidTensorShape,
    InvalidTensorEncoding,
    InvalidConfiguration,
};

pub fn build(comptime capacity: usize, index: *const sb0m.Index(capacity), output: *Plan) Error!void {
    if (index.header.model_kind != .qwen3_tts_12hz_codec or index.tensor_count != NATIVE_TENSORS)
        return error.InvalidModelKind;
    output.* = .{};
    output.first_cluster = try bind(index, output,
        "decoder.quantizer.rvq_first.vq.layers.0._codebook.cluster_usage");
    output.first_embedding = try bind(index, output,
        "decoder.quantizer.rvq_first.vq.layers.0._codebook.embedding_sum");
    output.first_output = try bind(index, output, "decoder.quantizer.rvq_first.output_proj.weight");
    output.rest_output = try bind(index, output, "decoder.quantizer.rvq_rest.output_proj.weight");
    var name: [192]u8 = undefined;
    for (0..REST_CODE_GROUPS) |group| {
        output.rest_cluster[group] = try bind(index, output, std.fmt.bufPrint(&name,
            "decoder.quantizer.rvq_rest.vq.layers.{d}._codebook.cluster_usage", .{group}) catch
            return error.InvalidConfiguration);
        output.rest_embedding[group] = try bind(index, output, std.fmt.bufPrint(&name,
            "decoder.quantizer.rvq_rest.vq.layers.{d}._codebook.embedding_sum", .{group}) catch
            return error.InvalidConfiguration);
    }
    output.pre_conv = try bindConv(index, output, "decoder.pre_conv.conv", &name);
    output.transformer_input = try bindLinear(index, output, "decoder.pre_transformer.input_proj", &name);
    for (&output.transformer_layers, 0..) |*layer, layer_index| {
        const prefix = std.fmt.bufPrint(&name, "decoder.pre_transformer.layers.{d}", .{layer_index}) catch
            return error.InvalidConfiguration;
        var layer_name: [192]u8 = undefined;
        layer.input_norm = try bindSuffix(index, output, prefix, "input_layernorm.weight", &layer_name);
        layer.query = try bindSuffix(index, output, prefix, "self_attn.q_proj.weight", &layer_name);
        layer.key = try bindSuffix(index, output, prefix, "self_attn.k_proj.weight", &layer_name);
        layer.value = try bindSuffix(index, output, prefix, "self_attn.v_proj.weight", &layer_name);
        layer.attention_output = try bindSuffix(index, output, prefix, "self_attn.o_proj.weight", &layer_name);
        layer.attention_scale = try bindSuffix(index, output, prefix, "self_attn_layer_scale.scale", &layer_name);
        layer.post_attention_norm = try bindSuffix(index, output, prefix, "post_attention_layernorm.weight", &layer_name);
        layer.ffn_gate = try bindSuffix(index, output, prefix, "mlp.gate_proj.weight", &layer_name);
        layer.ffn_up = try bindSuffix(index, output, prefix, "mlp.up_proj.weight", &layer_name);
        layer.ffn_down = try bindSuffix(index, output, prefix, "mlp.down_proj.weight", &layer_name);
        layer.ffn_scale = try bindSuffix(index, output, prefix, "mlp_layer_scale.scale", &layer_name);
    }
    output.transformer_norm = try bind(index, output, "decoder.pre_transformer.norm.weight");
    output.transformer_output = try bindLinear(index, output, "decoder.pre_transformer.output_proj", &name);
    for (&output.pre_upsample, 0..) |*stage, stage_index| {
        const prefix = std.fmt.bufPrint(&name, "decoder.upsample.{d}", .{stage_index}) catch
            return error.InvalidConfiguration;
        var child: [192]u8 = undefined;
        stage.transposed = try bindConv(index, output, std.fmt.bufPrint(&child, "{s}.0.conv", .{prefix}) catch
            return error.InvalidConfiguration, &name);
        const conv_next = std.fmt.bufPrint(&child, "{s}.1", .{prefix}) catch return error.InvalidConfiguration;
        var leaf: [192]u8 = undefined;
        stage.conv_next.depthwise = try bindConv(index, output, std.fmt.bufPrint(&leaf, "{s}.dwconv.conv", .{conv_next}) catch
            return error.InvalidConfiguration, &name);
        stage.conv_next.norm_weight = try bindSuffix(index, output, conv_next, "norm.weight", &leaf);
        stage.conv_next.norm_bias = try bindSuffix(index, output, conv_next, "norm.bias", &leaf);
        stage.conv_next.pointwise_1 = try bindLinear(index, output, std.fmt.bufPrint(&leaf, "{s}.pwconv1", .{conv_next}) catch
            return error.InvalidConfiguration, &name);
        stage.conv_next.pointwise_2 = try bindLinear(index, output, std.fmt.bufPrint(&leaf, "{s}.pwconv2", .{conv_next}) catch
            return error.InvalidConfiguration, &name);
        stage.conv_next.gamma = try bindSuffix(index, output, conv_next, "gamma", &leaf);
    }
    output.decoder_input = try bindConv(index, output, "decoder.decoder.0.conv", &name);
    for (&output.decoder_stages, 0..) |*stage, stage_index| {
        const prefix = std.fmt.bufPrint(&name, "decoder.decoder.{d}.block", .{stage_index + 1}) catch
            return error.InvalidConfiguration;
        var child: [192]u8 = undefined;
        stage.activation = try bindSnake(index, output, std.fmt.bufPrint(&child, "{s}.0", .{prefix}) catch
            return error.InvalidConfiguration, &name);
        stage.transposed = try bindConv(index, output, std.fmt.bufPrint(&child, "{s}.1.conv", .{prefix}) catch
            return error.InvalidConfiguration, &name);
        for (&stage.residual, 0..) |*unit, unit_index| {
            const unit_prefix = std.fmt.bufPrint(&child, "{s}.{d}", .{ prefix, unit_index + 2 }) catch
                return error.InvalidConfiguration;
            var leaf: [192]u8 = undefined;
            unit.act_1 = try bindSnake(index, output, std.fmt.bufPrint(&leaf, "{s}.act1", .{unit_prefix}) catch
                return error.InvalidConfiguration, &name);
            unit.conv_1 = try bindConv(index, output, std.fmt.bufPrint(&leaf, "{s}.conv1.conv", .{unit_prefix}) catch
                return error.InvalidConfiguration, &name);
            unit.act_2 = try bindSnake(index, output, std.fmt.bufPrint(&leaf, "{s}.act2", .{unit_prefix}) catch
                return error.InvalidConfiguration, &name);
            unit.conv_2 = try bindConv(index, output, std.fmt.bufPrint(&leaf, "{s}.conv2.conv", .{unit_prefix}) catch
                return error.InvalidConfiguration, &name);
        }
    }
    output.output_activation = try bindSnake(index, output, "decoder.decoder.5", &name);
    output.output_conv = try bindConv(index, output, "decoder.decoder.6.conv", &name);
    if (output.bound_tensors != BOUND_TENSORS) return error.InvalidConfiguration;
    try validate(index, output);
}

fn bind(index: anytype, plan: *Plan, name: []const u8) Error!TensorRef {
    for (index.tensors[0..index.tensor_count], 0..) |*candidate, tensor_index| {
        if (std.mem.eql(u8, candidate.name(), name)) {
            plan.bound_tensors += 1;
            return .{ .index = @intCast(tensor_index) };
        }
    }
    return error.MissingTensor;
}

fn bindSuffix(index: anytype, plan: *Plan, prefix: []const u8, suffix: []const u8, buffer: []u8) Error!TensorRef {
    return bind(index, plan, std.fmt.bufPrint(buffer, "{s}.{s}", .{ prefix, suffix }) catch
        return error.InvalidConfiguration);
}

fn bindLinear(index: anytype, plan: *Plan, prefix: []const u8, buffer: []u8) Error!Linear {
    return .{
        .weight = try bindSuffix(index, plan, prefix, "weight", buffer),
        .bias = try bindSuffix(index, plan, prefix, "bias", buffer),
    };
}

fn bindConv(index: anytype, plan: *Plan, prefix: []const u8, buffer: []u8) Error!Conv {
    return bindLinear(index, plan, prefix, buffer);
}

fn bindSnake(index: anytype, plan: *Plan, prefix: []const u8, buffer: []u8) Error!Snake {
    return .{
        .alpha = try bindSuffix(index, plan, prefix, "alpha", buffer),
        .beta = try bindSuffix(index, plan, prefix, "beta", buffer),
    };
}

fn tensor(index: anytype, reference: TensorRef) *const sb0m.Tensor {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

fn exact(index: anytype, reference: TensorRef, dimensions: []const u32) Error!void {
    const value = tensor(index, reference);
    if (value.rank != dimensions.len) return error.InvalidTensorShape;
    for (dimensions, 0..) |dimension, dimension_index|
        if (value.dimensions[dimension_index] != dimension) return error.InvalidTensorShape;
    var row_elements: u64 = 1;
    if (dimensions.len >= 2) {
        for (dimensions[1..]) |dimension| row_elements *= dimension;
    }
    const expected: sb0m.Encoding = if (dimensions.len >= 2 and row_elements % 32 == 0) .sb0_q4 else .f16;
    if (value.encoding != expected) return error.InvalidTensorEncoding;
}

fn validate(index: anytype, plan: *const Plan) Error!void {
    try exact(index, plan.first_cluster, &.{CODEBOOK_SIZE});
    try exact(index, plan.first_embedding, &.{ CODEBOOK_SIZE, CODEBOOK_HIDDEN });
    try exact(index, plan.first_output, &.{ CODEBOOK_DIM, CODEBOOK_HIDDEN, 1 });
    try exact(index, plan.rest_output, &.{ CODEBOOK_DIM, CODEBOOK_HIDDEN, 1 });
    for (plan.rest_cluster, plan.rest_embedding) |cluster, embedding| {
        try exact(index, cluster, &.{CODEBOOK_SIZE});
        try exact(index, embedding, &.{ CODEBOOK_SIZE, CODEBOOK_HIDDEN });
    }
    try validateConv(index, plan.pre_conv, LATENT, CODEBOOK_DIM, 3);
    try validateLinear(index, plan.transformer_input, TRANSFORMER_HIDDEN, LATENT);
    for (plan.transformer_layers) |layer| {
        try exact(index, layer.input_norm, &.{TRANSFORMER_HIDDEN});
        try exact(index, layer.query, &.{ TRANSFORMER_QUERY, TRANSFORMER_HIDDEN });
        try exact(index, layer.key, &.{ TRANSFORMER_QUERY, TRANSFORMER_HIDDEN });
        try exact(index, layer.value, &.{ TRANSFORMER_QUERY, TRANSFORMER_HIDDEN });
        try exact(index, layer.attention_output, &.{ TRANSFORMER_HIDDEN, TRANSFORMER_QUERY });
        try exact(index, layer.attention_scale, &.{TRANSFORMER_HIDDEN});
        try exact(index, layer.post_attention_norm, &.{TRANSFORMER_HIDDEN});
        try exact(index, layer.ffn_gate, &.{ TRANSFORMER_INTERMEDIATE, TRANSFORMER_HIDDEN });
        try exact(index, layer.ffn_up, &.{ TRANSFORMER_INTERMEDIATE, TRANSFORMER_HIDDEN });
        try exact(index, layer.ffn_down, &.{ TRANSFORMER_HIDDEN, TRANSFORMER_INTERMEDIATE });
        try exact(index, layer.ffn_scale, &.{TRANSFORMER_HIDDEN});
    }
    try exact(index, plan.transformer_norm, &.{TRANSFORMER_HIDDEN});
    try validateLinear(index, plan.transformer_output, LATENT, TRANSFORMER_HIDDEN);
    for (plan.pre_upsample) |stage| {
        try validateConv(index, stage.transposed, LATENT, LATENT, 2);
        try validateConv(index, stage.conv_next.depthwise, LATENT, 1, 7);
        try exact(index, stage.conv_next.norm_weight, &.{LATENT});
        try exact(index, stage.conv_next.norm_bias, &.{LATENT});
        try validateLinear(index, stage.conv_next.pointwise_1, 4 * LATENT, LATENT);
        try validateLinear(index, stage.conv_next.pointwise_2, LATENT, 4 * LATENT);
        try exact(index, stage.conv_next.gamma, &.{LATENT});
    }
    try validateConv(index, plan.decoder_input, 1536, LATENT, 7);
    const inputs = [_]u32{ 1536, 768, 384, 192 };
    const outputs = [_]u32{ 768, 384, 192, 96 };
    const kernels = [_]u32{ 16, 10, 8, 6 };
    for (plan.decoder_stages, inputs, outputs, kernels) |stage, input, output, kernel| {
        try validateSnake(index, stage.activation, input);
        try validateTransposedConv(index, stage.transposed, input, output, kernel);
        for (stage.residual) |unit| {
            try validateSnake(index, unit.act_1, output);
            try validateConv(index, unit.conv_1, output, output, 7);
            try validateSnake(index, unit.act_2, output);
            try validateConv(index, unit.conv_2, output, output, 1);
        }
    }
    try validateSnake(index, plan.output_activation, 96);
    try validateConv(index, plan.output_conv, 1, 96, 7);
}

fn validateLinear(index: anytype, linear: Linear, output: u32, input: u32) Error!void {
    try exact(index, linear.weight, &.{ output, input });
    try exact(index, linear.bias, &.{output});
}

fn validateConv(index: anytype, conv: Conv, output: u32, input: u32, kernel: u32) Error!void {
    try exact(index, conv.weight, &.{ output, input, kernel });
    try exact(index, conv.bias, &.{output});
}

fn validateTransposedConv(index: anytype, conv: Conv, input: u32, output: u32, kernel: u32) Error!void {
    // PyTorch persists ConvTranspose1d weights as [input, output, kernel].
    try exact(index, conv.weight, &.{ input, output, kernel });
    try exact(index, conv.bias, &.{output});
}

fn validateSnake(index: anytype, snake: Snake, channels: u32) Error!void {
    try exact(index, snake.alpha, &.{channels});
    try exact(index, snake.beta, &.{channels});
}

test "codec execution plan accounts for every decode tensor" {
    const quantizer = 4 + REST_CODE_GROUPS * 2;
    const transformer = 2 + TRANSFORMER_LAYERS * 11 + 1 + 2;
    const pre_upsample = PRE_UPSAMPLE_STAGES * 11;
    const decoder = 2 + DECODER_STAGES * (2 + 2 + RESIDUAL_UNITS * 8) + 2 + 2;
    try std.testing.expectEqual(@as(usize, BOUND_TENSORS), quantizer + 2 + transformer + pre_upsample + decoder);
    try std.testing.expectEqual(@as(usize, 1920), 2 * 2 * 8 * 5 * 4 * 3);
}
