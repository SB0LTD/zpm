//! Qwen3 text-decoder schema binder for the generic SB0 GGUF index.
//!
//! Architecture-specific tensor naming is isolated here. Storage, scheduling,
//! quantized math, conversation policy, and model catalog code remain generic.

const std = @import("std");
const gguf = @import("gguf.sig");

pub const MAX_LAYERS: usize = 64;
pub const INVALID_TENSOR: u16 = std.math.maxInt(u16);

pub const Error = error{
    UnsupportedArchitecture,
    InvalidConfiguration,
    TensorCapacity,
    UnknownTensor,
    DuplicateTensor,
    MissingTensor,
    InvalidTensorShape,
    InvalidTensorType,
};

pub const TensorRef = struct {
    index: u16 = INVALID_TENSOR,

    pub fn present(self: TensorRef) bool { return self.index != INVALID_TENSOR; }
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
    query_size: u32 = 0,
    key_value_size: u32 = 0,
    vocabulary_size: u32 = 0,
    rope_frequency_base: f32 = 0,
    rms_norm_epsilon: f32 = 0,
    macs_per_decode_token: u64 = 0,
    kv_bytes_per_token_f16: u64 = 0,
};

pub fn build(comptime tensor_capacity: usize, index: *const gguf.Index(tensor_capacity), out: *Plan) Error!void {
    out.* = .{};
    if (!std.mem.eql(u8, index.summary.architectureSlice(), "qwen3vl") and
        !std.mem.eql(u8, index.summary.architectureSlice(), "qwen3")) return error.UnsupportedArchitecture;
    if (tensor_capacity > INVALID_TENSOR or index.tensor_count > INVALID_TENSOR) return error.TensorCapacity;
    const summary = &index.summary;
    if (summary.embedding_length == 0 or summary.embedding_length > std.math.maxInt(u32) or
        summary.block_count == 0 or summary.block_count > MAX_LAYERS or
        summary.head_count == 0 or summary.head_count > std.math.maxInt(u16) or
        summary.head_count_kv == 0 or summary.head_count_kv > summary.head_count or
        summary.feed_forward_length == 0 or summary.feed_forward_length > std.math.maxInt(u32) or
        !std.math.isFinite(summary.rope_frequency_base) or summary.rope_frequency_base <= 0 or
        !std.math.isFinite(summary.rms_norm_epsilon) or summary.rms_norm_epsilon <= 0)
        return error.InvalidConfiguration;

    // Qwen3 records the projection head width explicitly. Small variants such
    // as 0.6B retain 128-wide heads while using a 1,024-wide residual stream,
    // so deriving this as embedding/head_count silently produces 64 and binds
    // the wrong tensor shapes. Older Qwen3-VL artifacts omit the keys only
    // when the residual width is evenly partitioned into the same head width.
    const inferred_head_size = if (summary.embedding_length % summary.head_count == 0)
        summary.embedding_length / summary.head_count
    else
        0;
    const key_length = if (summary.attention_key_length != 0)
        summary.attention_key_length
    else
        inferred_head_size;
    const value_length = if (summary.attention_value_length != 0)
        summary.attention_value_length
    else
        key_length;
    if (key_length == 0 or key_length > std.math.maxInt(u16) or
        value_length != key_length) return error.InvalidConfiguration;
    const query_size = @mulWithOverflow(summary.head_count, key_length);
    const key_value_size = @mulWithOverflow(summary.head_count_kv, key_length);
    if (query_size[1] != 0 or query_size[0] > std.math.maxInt(u32) or
        key_value_size[1] != 0 or key_value_size[0] > std.math.maxInt(u32))
        return error.InvalidConfiguration;

    out.layer_count = @intCast(summary.block_count);
    out.hidden_size = @intCast(summary.embedding_length);
    out.feed_forward_size = @intCast(summary.feed_forward_length);
    out.head_count = @intCast(summary.head_count);
    out.kv_head_count = @intCast(summary.head_count_kv);
    out.head_size = @intCast(key_length);
    out.query_size = @intCast(query_size[0]);
    out.key_value_size = @intCast(key_value_size[0]);
    out.rope_frequency_base = summary.rope_frequency_base;
    out.rms_norm_epsilon = summary.rms_norm_epsilon;
    const vocabulary_count = if (summary.vocab_size != 0) summary.vocab_size else summary.tokenizer_tokens.count;
    if (vocabulary_count == 0 or vocabulary_count > std.math.maxInt(u32)) return error.InvalidConfiguration;
    out.vocabulary_size = @intCast(vocabulary_count);

    for (index.tensors[0..index.tensor_count], 0..) |tensor, tensor_index| {
        const name = tensor.nameSlice();
        if (std.mem.eql(u8, name, "token_embd.weight")) {
            try bind(&out.token_embedding, tensor_index);
        } else if (std.mem.eql(u8, name, "output_norm.weight")) {
            try bind(&out.output_norm, tensor_index);
        } else if (std.mem.eql(u8, name, "output.weight")) {
            try bind(&out.output, tensor_index);
        } else if (parseLayerName(name)) |parsed| {
            if (parsed.layer >= out.layer_count) return error.UnknownTensor;
            const layer = &out.layers[parsed.layer];
            const destination: *TensorRef = if (std.mem.eql(u8, parsed.suffix, "attn_norm.weight"))
                &layer.attention_norm
            else if (std.mem.eql(u8, parsed.suffix, "attn_q.weight"))
                &layer.query
            else if (std.mem.eql(u8, parsed.suffix, "attn_k.weight"))
                &layer.key
            else if (std.mem.eql(u8, parsed.suffix, "attn_v.weight"))
                &layer.value
            else if (std.mem.eql(u8, parsed.suffix, "attn_output.weight"))
                &layer.attention_output
            else if (std.mem.eql(u8, parsed.suffix, "attn_q_norm.weight"))
                &layer.query_norm
            else if (std.mem.eql(u8, parsed.suffix, "attn_k_norm.weight"))
                &layer.key_norm
            else if (std.mem.eql(u8, parsed.suffix, "ffn_norm.weight"))
                &layer.ffn_norm
            else if (std.mem.eql(u8, parsed.suffix, "ffn_gate.weight"))
                &layer.ffn_gate
            else if (std.mem.eql(u8, parsed.suffix, "ffn_up.weight"))
                &layer.ffn_up
            else if (std.mem.eql(u8, parsed.suffix, "ffn_down.weight"))
                &layer.ffn_down
            else return error.UnknownTensor;
            try bind(destination, tensor_index);
        } else return error.UnknownTensor;
    }

    if (!out.output.present()) {
        out.output = out.token_embedding;
        out.output_is_tied = true;
    }
    try validatePlan(tensor_capacity, index, out);
    out.macs_per_decode_token = computeMacs(out.*) catch return error.InvalidConfiguration;
    const kv_elements = @as(u64, out.layer_count) * out.kv_head_count * out.head_size * 2;
    out.kv_bytes_per_token_f16 = kv_elements * @sizeOf(u16);
}

fn validatePlan(comptime tensor_capacity: usize, index: *const gguf.Index(tensor_capacity), plan: *const Plan) Error!void {
    try validateMatrix(index, plan.token_embedding, plan.hidden_size, plan.vocabulary_size);
    try validateVector(index, plan.output_norm, plan.hidden_size);
    try validateMatrix(index, plan.output, plan.hidden_size, plan.vocabulary_size);
    const kv_size = plan.key_value_size;
    for (plan.layers[0..plan.layer_count]) |layer| {
        try validateVector(index, layer.attention_norm, plan.hidden_size);
        try validateMatrix(index, layer.query, plan.hidden_size, plan.query_size);
        try validateMatrix(index, layer.key, plan.hidden_size, kv_size);
        try validateMatrix(index, layer.value, plan.hidden_size, kv_size);
        try validateMatrix(index, layer.attention_output, plan.query_size, plan.hidden_size);
        try validateVector(index, layer.query_norm, plan.head_size);
        try validateVector(index, layer.key_norm, plan.head_size);
        try validateVector(index, layer.ffn_norm, plan.hidden_size);
        try validateMatrix(index, layer.ffn_gate, plan.hidden_size, plan.feed_forward_size);
        try validateMatrix(index, layer.ffn_up, plan.hidden_size, plan.feed_forward_size);
        try validateMatrix(index, layer.ffn_down, plan.feed_forward_size, plan.hidden_size);
    }
}

fn validateVector(index: anytype, reference: TensorRef, elements: u64) Error!void {
    if (!reference.present()) return error.MissingTensor;
    const tensor = &index.tensors[reference.index];
    if (tensor.dimension_count != 1 or tensor.dimensions[0] != elements) return error.InvalidTensorShape;
    if (tensor.ggml_type != 0) return error.InvalidTensorType;
}

fn validateMatrix(index: anytype, reference: TensorRef, columns: u64, rows: u64) Error!void {
    if (!reference.present()) return error.MissingTensor;
    const tensor = &index.tensors[reference.index];
    if (tensor.dimension_count != 2 or tensor.dimensions[0] != columns or tensor.dimensions[1] != rows)
        return error.InvalidTensorShape;
    if (tensor.ggml_type != 0 and tensor.ggml_type != 12 and tensor.ggml_type != 14)
        return error.InvalidTensorType;
}

fn computeMacs(plan: Plan) !u64 {
    const hidden: u64 = plan.hidden_size;
    const query: u64 = plan.query_size;
    const kv: u64 = plan.key_value_size;
    const feed_forward: u64 = plan.feed_forward_size;
    const per_layer = try checkedAdd(
        try checkedAdd(try checkedMultiply(2, try checkedMultiply(hidden, query)), try checkedMultiply(2, try checkedMultiply(hidden, kv))),
        try checkedMultiply(3, try checkedMultiply(hidden, feed_forward)),
    );
    return checkedAdd(try checkedMultiply(plan.layer_count, per_layer), try checkedMultiply(plan.vocabulary_size, hidden));
}

fn checkedAdd(left: u64, right: u64) !u64 {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn checkedMultiply(left: u64, right: u64) !u64 {
    const result = @mulWithOverflow(left, right);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn bind(destination: *TensorRef, index: usize) Error!void {
    if (destination.present()) return error.DuplicateTensor;
    destination.index = @intCast(index);
}

const ParsedLayer = struct { layer: usize, suffix: []const u8 };

fn parseLayerName(name: []const u8) ?ParsedLayer {
    if (!std.mem.startsWith(u8, name, "blk.")) return null;
    var position: usize = 4;
    var layer: usize = 0;
    var digits: usize = 0;
    while (position < name.len and name[position] >= '0' and name[position] <= '9') : (position += 1) {
        const next = @mulWithOverflow(layer, 10);
        if (next[1] != 0) return null;
        const added = @addWithOverflow(next[0], name[position] - '0');
        if (added[1] != 0) return null;
        layer = added[0];
        digits += 1;
    }
    if (digits == 0 or position >= name.len or name[position] != '.' or position + 1 == name.len) return null;
    return .{ .layer = layer, .suffix = name[position + 1 ..] };
}

test "real Qwen3 tensor formula is exact" {
    const testing = std.testing;
    const plan = Plan{
        .layer_count = 28,
        .hidden_size = 2048,
        .feed_forward_size = 6144,
        .head_count = 16,
        .kv_head_count = 8,
        .head_size = 128,
        .query_size = 2048,
        .key_value_size = 1024,
        .vocabulary_size = 151936,
    };
    try testing.expectEqual(@as(u64, 1_720_451_072), try computeMacs(plan));
    const kv_elements = @as(u64, plan.layer_count) * plan.kv_head_count * plan.head_size * 2;
    try testing.expectEqual(@as(u64, 114_688), kv_elements * 2);
}

test "Qwen3 0.6B keeps explicit 128-wide attention heads" {
    const testing = std.testing;
    const plan = Plan{
        .layer_count = 28,
        .hidden_size = 1024,
        .feed_forward_size = 3072,
        .head_count = 16,
        .kv_head_count = 8,
        .head_size = 128,
        .query_size = 2048,
        .key_value_size = 1024,
        .vocabulary_size = 151936,
    };
    try testing.expectEqual(@as(u64, 595_984_384), try computeMacs(plan));
    try testing.expectEqual(@as(u64, 114_688),
        @as(u64, plan.layer_count) * plan.key_value_size * 2 * @sizeOf(u16));
}

test "layer-name parser rejects ambiguous names" {
    const testing = std.testing;
    const parsed = parseLayerName("blk.27.ffn_down.weight").?;
    try testing.expectEqual(@as(usize, 27), parsed.layer);
    try testing.expectEqualStrings("ffn_down.weight", parsed.suffix);
    try testing.expect(parseLayerName("blk..weight") == null);
    try testing.expect(parseLayerName("product.blk.0.weight") == null);
}
