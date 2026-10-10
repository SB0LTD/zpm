//! @zpm/tts — native Qwen3-TTS-12Hz-0.6B speech synthesis.
//!
//! A complete, allocation-free, pure-Sig text-to-waveform stack for the
//! open-weight Qwen3-TTS-12Hz-0.6B Base architecture (Apache-2.0). No Python,
//! serving framework, or host speech engine participates; model state is fixed
//! caller-owned storage and every matrix phase is row-sliced so a scheduler can
//! interleave other work and cancel mid-decode.
//!
//! Topology (see the individual modules for the exact math):
//!
//!   Qwen BPE text
//!     -> 28-layer Talker + 5-layer code predictor      (talker_executor, synth)
//!     -> one 16-code acoustic frame                      (sampler)
//!     -> split residual vector quantizer + 8-layer,
//!        72-frame sliding transformer                    (codec_transformer)
//!     -> causal ConvNeXt upsample + SnakeBeta decoder    (vocoder)
//!     -> 1,920 f32 samples -> four 480-sample PCM16 20ms periods (codec)
//!     -> 24 kHz mono PCM                                 (PcmSink)
//!
//! Model artifacts are the pinned native SB0M containers produced by the
//! packer from the released SafeTensors checkpoint:
//!   - talker.sb0m  (402 tensors)  — Talker + code predictor + codec heads
//!   - codec.sb0m   (271 tensors)  — RVQ + transformer + vocoder decoder
//! plus the Qwen3 BPE tokenizer (a GGUF whose tokenizer metadata is reused).

// Model container ABI (SB0M): Source / Index / Tensor / parse.
pub const model_container = @import("tts_model_container");

// Talker (text -> acoustic codes).
pub const talker_plan = @import("tts_talker_plan");
pub const talker_native_plan = @import("tts_talker_native_plan");
pub const talker_backend = @import("tts_talker_backend");
pub const talker_executor = @import("tts_talker_executor");
pub const sampler = @import("tts_sampler");
pub const synth = @import("tts_synth");

// Codec + vocoder (acoustic codes -> 24 kHz PCM).
pub const codec_plan = @import("tts_codec_plan");
pub const codec_backend = @import("tts_codec_backend");
pub const codec_transformer = @import("tts_codec_transformer");
pub const vocoder = @import("tts_vocoder");
pub const codec = @import("tts_codec");

pub const SAMPLE_RATE = codec_plan.SAMPLE_RATE;
pub const PERIOD_SAMPLES = codec.PERIOD_SAMPLES;
pub const MAX_FRAMES = synth.MAX_FRAMES;
