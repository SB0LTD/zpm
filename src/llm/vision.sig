// @zpm/llm — Vision Encoder (ViT)
// Processes images and video frames into embedding tokens for the LLM decoder.
//
// Architecture (Qwen-VL style):
//   Image → Patch embedding (14×14 patches) → ViT transformer → Projection → Tokens
//   Video → Per-frame ViT → Temporal pooling → Tokens
//
// Supports:
//   - Single image input (448×448 or dynamic resolution)
//   - Video frame sequence
//   - Multi-image (interleaved with text)

pub const VisionConfig = struct {
    hidden_size: usize = 1024,
    n_layers: usize = 24,
    n_heads: usize = 16,
    patch_size: usize = 14,
    image_size: usize = 448,
    output_dim: usize = 2048, // projection to LLM hidden size

    pub fn numPatches(self: VisionConfig) usize {
        const grid = self.image_size / self.patch_size;
        return grid * grid; // 32×32 = 1024 for 448/14
    }
};

pub const DEFAULT_VISION_CONFIG = VisionConfig{};

/// Image input (RGB, HWC layout)
pub const ImageInput = struct {
    pixels: [*]const u8, // [H, W, 3] RGB
    width: u32,
    height: u32,
};

/// Video input (sequence of frames)
pub const VideoInput = struct {
    frames: [*]const ImageInput,
    n_frames: usize,
    fps: f32,
};

/// Vision encoder output
pub const VisionOutput = struct {
    tokens: [*]f32, // [n_tokens, output_dim]
    n_tokens: usize,
};

/// Encode a single image into LLM-compatible embedding tokens.
/// Returns number of tokens produced (typically 1024 for 448×448 / 14×14 patches).
pub fn encodeImage(
    image: *const ImageInput,
    weights: *const VisionWeights,
    config: *const VisionConfig,
    output: [*]f32,
) usize {
    _ = image; _ = weights;
    // Placeholder — full implementation:
    // 1. Resize/normalize image to config.image_size
    // 2. Extract patches (patch_size × patch_size × 3)
    // 3. Linear patch embedding
    // 4. Add positional embedding
    // 5. ViT transformer (n_layers of self-attention + FFN)
    // 6. Project to output_dim
    output[0] = 0;
    return config.numPatches();
}

/// Encode video frames (temporal pooling over per-frame ViT outputs)
pub fn encodeVideo(
    video: *const VideoInput,
    weights: *const VisionWeights,
    config: *const VisionConfig,
    output: [*]f32,
) usize {
    _ = weights;
    output[0] = 0;
    // n_tokens = n_frames × patches_per_frame (or pooled)
    return video.n_frames * config.numPatches();
}

pub const VisionWeights = struct {
    patch_embed_w: ?[*]const f32, // patch embedding projection
    pos_embed: ?[*]const f32, // positional embeddings
    layers: ?*anyopaque, // transformer layer weights (opaque)
    proj_w: ?[*]const f32, // final projection to LLM dim
};
