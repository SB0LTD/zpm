// @zpm/llm — Model orchestrator
// High-level API for multi-modal LLM inference.

pub const Modality = enum {
    text,
    image,
    audio,
    video,
};

pub const GenerateOptions = struct {
    max_tokens: usize = 256,
    temperature: f32 = 0.0, // 0 = greedy
    top_p: f32 = 1.0,
    stop_tokens: [8]u32 = undefined,
    stop_count: usize = 0,
    stream_callback: ?*const fn (token_id: u32, text: []const u8) void = null,
};

pub const ModelConfig = struct {
    arch: Architecture = .qwen3,
    hidden_size: usize = 2048,
    n_layers: usize = 28,
    n_heads: usize = 16,
    n_kv_heads: usize = 8,
    head_dim: usize = 128,
    intermediate_size: usize = 6144,
    vocab_size: usize = 151936,
    max_seq_len: usize = 8192,
    rope_theta: f32 = 1000000.0,
    // Vision encoder (for multi-modal)
    has_vision: bool = false,
    vision_hidden_size: usize = 1024,
    vision_layers: usize = 24,
    patch_size: usize = 14,
    image_size: usize = 448,
};

pub const Architecture = enum {
    qwen3, // Qwen3 family (including ASR decoder)
    gemma4, // Gemma 4 (metalforge primary target)
    llama, // LLaMA-compatible
};

pub const LLMModel = struct {
    config: ModelConfig,
    weights_ptr: ?*anyopaque, // opaque pointer to loaded weights
    loaded: bool,

    // Multi-modal input slots
    image_embeddings: ?[*]const f32,
    image_n_tokens: usize,
    audio_embeddings: ?[*]const f32,
    audio_n_tokens: usize,
    video_embeddings: ?[*]const f32,
    video_n_tokens: usize,

    pub fn init(config: ModelConfig) LLMModel {
        return .{
            .config = config,
            .weights_ptr = null,
            .loaded = false,
            .image_embeddings = null,
            .image_n_tokens = 0,
            .audio_embeddings = null,
            .audio_n_tokens = 0,
            .video_embeddings = null,
            .video_n_tokens = 0,
        };
    }

    /// Attach image embeddings (from vision encoder)
    pub fn addImage(self: *LLMModel, embeddings: [*]const f32, n_tokens: usize) void {
        self.image_embeddings = embeddings;
        self.image_n_tokens = n_tokens;
    }

    /// Attach audio embeddings (from @zpm/asr encoder)
    pub fn addAudio(self: *LLMModel, embeddings: [*]const f32, n_tokens: usize) void {
        self.audio_embeddings = embeddings;
        self.audio_n_tokens = n_tokens;
    }

    /// Attach video frame embeddings
    pub fn addVideo(self: *LLMModel, embeddings: [*]const f32, n_tokens: usize) void {
        self.video_embeddings = embeddings;
        self.video_n_tokens = n_tokens;
    }

    /// Clear all multi-modal inputs
    pub fn clearInputs(self: *LLMModel) void {
        self.image_embeddings = null;
        self.image_n_tokens = 0;
        self.audio_embeddings = null;
        self.audio_n_tokens = 0;
        self.video_embeddings = null;
        self.video_n_tokens = 0;
    }

    /// Generate text from prompt (with optional multi-modal context)
    pub fn generate(self: *LLMModel, prompt_tokens: []const u32, opts: GenerateOptions, out: [*]u32) usize {
        _ = self; _ = prompt_tokens; _ = opts;
        // Placeholder — actual implementation dispatches to decoder.sig
        out[0] = 0;
        return 0;
    }
};
