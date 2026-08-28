// @zpm/asr — Root module
// Pure-Sig speech recognition engine for Qwen3-ASR (Caspi) models.
//
// Usage:
//   const asr = @import("asr");
//   var model = asr.Model.empty(.v1_7b);
//   // ... load weights ...
//   const text_len = model.transcribe(audio, n_samples, &out_buf, out_cap);
//
// Modules:
//   mel.sig         — Mel spectrogram computation
//   encoder.sig     — Audio encoder (Conv2D + transformer)
//   decoder.sig     — Qwen3 LLM decoder (GQA, RoPE, SwiGLU)
//   model.sig       — Full pipeline orchestration
//   safetensors.sig — Weight file format parser

pub const mel = @import("mel.sig");
pub const encoder = @import("encoder.sig");
pub const decoder = @import("decoder.sig");
pub const model = @import("model.sig");
pub const safetensors = @import("safetensors.sig");
pub const stream = @import("stream.sig");

// Re-export key types
pub const Model = model.Model;
pub const Variant = model.Variant;
pub const Config = encoder.Config;
pub const DecoderConfig = decoder.DecoderConfig;
pub const StreamState = stream.StreamState;
pub const StreamConfig = stream.StreamConfig;
pub const Language = stream.Language;
