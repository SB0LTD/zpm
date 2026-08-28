// @zpm/llm — Multi-Modal LLM Inference Engine
// Extracted from metalforge. Supports text, image, audio, and video inputs.
//
// Architecture:
//   - GGUF/safetensors weight loading (mmap'd)
//   - Qwen3 / Gemma decoder architectures
//   - Vision encoder (ViT) for image/video inputs
//   - Audio embeddings from @zpm/asr
//   - KV cache with GQA support
//   - CUDA (cuBLAS) + CPU (OpenBLAS/AMX) backends
//   - Quantized inference (Q4_K, Q6_K, Q8_0, BF16, F32)
//
// Usage:
//   const llm = @import("llm");
//   var model = llm.Model.load("path/to/model.gguf", .{});
//   const response = model.generate(prompt, .{ .max_tokens = 256 });
//
// Multi-modal:
//   model.addImage(image_data, width, height);
//   model.addAudio(audio_embeddings, n_tokens);
//   model.addVideo(frame_embeddings, n_frames);
//   const response = model.generate("Describe this image", .{});

pub const model = @import("model.sig");
pub const decoder = @import("decoder.sig");
pub const vision = @import("vision.sig");
pub const tokenizer = @import("tokenizer.sig");
pub const quantize = @import("quantize.sig");
pub const gguf_loader = @import("gguf_loader.sig");
pub const infer = @import("infer.sig");
pub const gpu_infer = @import("gpu_infer.sig");

pub const Model = model.LLMModel;
pub const GenerateOptions = model.GenerateOptions;
pub const Modality = model.Modality;
pub const LoadedModel = gguf_loader.LoadedModel;
