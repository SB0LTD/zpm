//! Qwen3-TTS-12Hz-0.6B Talker architecture constants, tensor references, and
//! execution-plan types.
//!
//! This is the storage-neutral schema shared by both the authenticated
//! SafeTensors import binder (`talker_plan_safetensors`) and the native SB0M
//! binder (`talker_native_plan`). It holds only the pinned architecture facts
//! and the plan struct that the executor and synth runtimes consume; it has no
//! model-container or SafeTensors dependency of its own, so the native runtime
//! never links a reference-import codepath.

const std = @import("std");

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

/// Multiply-accumulates for one decoder pass at the given vocabulary width.
/// Depends only on the architecture constants above (no model container).
pub fn decoderMacs(layers: usize, vocabulary: usize) Error!u64 {
    const projections = try add(try multiply(HIDDEN, QUERY), try multiply(2 * HIDDEN, KEY_VALUE));
    const attention_output = try multiply(HIDDEN, QUERY);
    const feed_forward = try multiply(3 * HIDDEN, FEED_FORWARD);
    const per_layer = try add(try add(projections, attention_output), feed_forward);
    return add(try multiply(layers, per_layer), try multiply(HIDDEN, vocabulary));
}

pub fn add(left: anytype, right: anytype) Error!u64 {
    const result = @addWithOverflow(@as(u64, @intCast(left)), @as(u64, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

pub fn multiply(left: anytype, right: anytype) Error!u64 {
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
