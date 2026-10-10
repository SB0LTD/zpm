// @zpm/diffusion — Pure-Sig latent diffusion image generation.
//
// A Layer-0/2 image-generation runtime that runs GGUF diffusion transformers
// locally, reusing the existing zpm GGUF + quantization + fused-matvec stack:
//   - src/core/gguf.sig        structural GGUF reader (arch/metadata/tensors)
//   - src/llm/gguf_loader.sig  mmap'd tensor mapping + GGMLType/dequant sizing
//   - src/llm/quantize.sig     block dequantization (Q4_K/Q5_K/Q6_K/Q8_0/F16)
//   - src/llm/fused_matmul.sig zero-alloc fused dequant-matvec
//
// The pipeline mirrors modern latent text-to-image models (Stable-Diffusion /
// Flux / Qwen-Image class MMDiT):
//
//   prompt ──▶ text encoder ──▶ conditioning tokens ─┐
//                                                     ▼
//   seed ──▶ init latent (Gaussian) ──▶ [ scheduler × N steps ]
//                                          │  denoiser (DiT) predicts velocity
//                                          │  scheduler integrates the ODE
//                                          ▼
//                              final latent ──▶ VAE decode ──▶ RGB image
//
// Design constraints match the rest of zpm: allocation-free public API (the
// caller owns every buffer), no product names baked into the loader (the
// architecture is *detected* from GGUF metadata), and each stage is a distinct
// module so it can be tested and swapped independently.
//
// Usage:
//   const diffusion = @import("diffusion");
//   var pipe: diffusion.Pipeline = undefined;
//   try pipe.load(.{
//       .diffusion_gguf = "models/qwen-image-2.1-UC-Q4_K_M.gguf",
//       .text_encoder   = "models/qwen3vl_8b_int8_convrot.safetensors",
//       .vae            = "models/qwen_image_2.1_vae_bf16.safetensors",
//   });
//   defer pipe.deinit();
//   const req = diffusion.Request{
//       .prompt = "a red fox in snow, cinematic",
//       .width = 1024, .height = 1024,
//       .steps = 20, .cfg_scale = 4.0, .seed = 42,
//   };
//   try pipe.generate(&req, rgba_out);   // rgba_out: []u8 of width*height*4

pub const loader = @import("loader.sig");
pub const scheduler = @import("scheduler.sig");
pub const denoiser = @import("denoiser.sig");
pub const vae = @import("vae.sig");
pub const text_encoder = @import("text_encoder.sig");
pub const pipeline = @import("pipeline.sig");

pub const Pipeline = pipeline.Pipeline;
pub const Request = pipeline.Request;
pub const PipelineConfig = pipeline.PipelineConfig;
pub const SchedulerKind = scheduler.Kind;
pub const DiffusionArch = loader.DiffusionArch;
pub const DiffusionModel = loader.DiffusionModel;
pub const Error = pipeline.Error;

test "diffusion root re-exports resolve" {
    const std = @import("std");
    try std.testing.expect(@hasDecl(pipeline, "Pipeline"));
    try std.testing.expect(@hasDecl(scheduler, "Kind"));
    try std.testing.expect(@hasDecl(loader, "DiffusionArch"));
}
