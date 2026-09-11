//! Inference Session — high-level generate() API with streaming.
//!
//! Composes all inference components into a single coherent interface:
//!   GGUF loading → tokenizer init → KV cache → prompt encode →
//!   multi-token generation with sampling + stop detection → streaming output.
//!
//! This is the entry point that sig_build's smart capacity system (and any
//! other consumer) calls. A session owns its model state and produces tokens
//! one at a time via an iterator interface.
//!
//! Usage:
//!   var session = try Session.init(alloc_fn, model_source, config);
//!   var iter = try session.generate("What modules does this build graph need?", .{});
//!   while (try iter.next()) |token_bytes| { ... use UTF-8 bytes ... }
//!   session.reset(); // Ready for next generation
//!
//! Zero heap allocation. All storage via caller-provided AllocFn.


const gguf = @import("gguf");
const qwen3_plan = @import("qwen3_decoder_plan");
const executor = @import("qwen3_executor");
const tokenizer = @import("tokenizer");
const tokenizer_index = @import("tokenizer_index");
const sampling = @import("sampling");
const kv_cache = @import("kv_cache");

// ══════════════════════════════════════════════════════════════════════════════
// Configuration
// ══════════════════════════════════════════════════════════════════════════════

pub const GenerateConfig = struct {
    max_tokens: u32 = 512,
    sampling: sampling.Config = sampling.Config.BALANCED,
    system_prompt: []const u8 = "",
    stop_on_eos: bool = true,
    seed: u64 = 0xB0B0B0B0,
};

pub const SessionConfig = struct {
    max_context: u32 = executor.qwen3_0_6b_limits.context,
    /// Progress callback (optional). Return false to cancel.
    progress_fn: ?executor.ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
};

// ══════════════════════════════════════════════════════════════════════════════
// Session
// ══════════════════════════════════════════════════════════════════════════════

/// Comptime tensor capacity for the GGUF index. 1024 tensors covers all
/// Qwen3 variants up to 14B (which has ~500 tensors).
const TENSOR_CAPACITY = 1024;

/// Maximum vocabulary for the tokenizer hash table.
const VOCAB_HASH_CAPACITY = 262144; // 256K slots (75% load → ~192K tokens max)
const VOCABULARY_CAPACITY = executor.qwen3_0_6b_limits.vocabulary;

/// Maximum merge pairs for BPE.
const MERGE_HASH_CAPACITY = 262144;
const MAX_MERGE_BYTES = 256;

/// Token buffer for encoding prompts.
const MAX_PROMPT_TOKENS = executor.qwen3_0_6b_limits.context;

/// Decode scratch buffer (single token → UTF-8 bytes).
const DECODE_SCRATCH_SIZE = 256;

pub const Session = struct {
    // Model state
    source: gguf.Source,
    index: gguf.Index(TENSOR_CAPACITY),
    plan: qwen3_plan.Plan,

    // Tokenizer
    vocabulary: tokenizer_index.VocabularyIndex(VOCABULARY_CAPACITY, VOCAB_HASH_CAPACITY),
    merges: tokenizer_index.MergeIndex(MERGE_HASH_CAPACITY, MAX_MERGE_BYTES),

    // KV cache
    cache: kv_cache.KvCache,

    // Working set (comptime-sized for the target model)
    work: executor.WorkingSet(executor.qwen3_0_6b_limits),

    // Generation state
    position: u32,
    rng: sampling.Rng,
    generated_count: u32,
    finished: bool,
    generation: u64 = 0,

    // Token buffer for prompt encoding
    token_buf: [MAX_PROMPT_TOKENS]u32,
    prompt_len: u32,

    // Decode buffer
    decode_scratch: [DECODE_SCRATCH_SIZE]u8,
    decode_out: [DECODE_SCRATCH_SIZE]u8,

    // Stop tokens
    eos_token: u32,
    eot_token: u32, // <|im_end|>

    // Config
    config: SessionConfig,
    alloc_fn: kv_cache.AllocFn,

    pub const Error = gguf.Error || qwen3_plan.Error || executor.Error ||
        tokenizer.Error || tokenizer_index.Error || kv_cache.KvCache.Error ||
        error{ ModelNotSupported, GenerationFailed, StaleGeneration, InvalidSampling };

    /// Initialize a session from a GGUF model source.
    pub fn init(
        alloc_fn: kv_cache.AllocFn,
        source: gguf.Source,
        config: SessionConfig,
    ) Error!Session {
        try validateConfig(config);
        var session: Session = undefined;
        session.source = source;
        session.alloc_fn = alloc_fn;
        session.config = config;
        session.position = 0;
        session.generated_count = 0;
        session.finished = true;
        session.generation = 0;
        session.rng = sampling.Rng.init(0);
        session.prompt_len = 0;

        // 1. Parse GGUF index
        try gguf.parse(TENSOR_CAPACITY, source, &session.index);

        // 2. Build decoder plan
        try qwen3_plan.build(TENSOR_CAPACITY, &session.index, &session.plan);
        try validateModel(session.plan, session.index.summary, config);

        // 3. Build tokenizer vocabulary index
        try session.vocabulary.build(source, session.index.summary.tokenizer_tokens);

        // 4. Build merge index
        try session.merges.build(source, session.index.summary.tokenizer_merges, &session.vocabulary);

        // Resolve model-owned stop IDs before obtaining caller arena storage.
        session.eos_token = session.vocabulary.lookup(source, "<|endoftext|>") orelse
            return error.MissingSpecialToken;
        session.eot_token = session.vocabulary.lookup(source, "<|im_end|>") orelse
            return error.MissingSpecialToken;

        // 5. Allocate KV cache
        session.cache = try kv_cache.KvCache.init(
            alloc_fn,
            @intCast(session.plan.layer_count),
            session.plan.kv_head_count,
            session.plan.head_size,
            config.max_context,
        );

        // 7. Zero working set
        session.work = .{};

        return session;
    }

    /// Encode a prompt and prepare for generation.
    /// Returns an iterator that yields UTF-8 byte slices per generated token.
    pub fn generate(self: *Session, user_prompt: []const u8, gen_config: GenerateConfig) Error!TokenIterator {
        self.reset();
        if (self.generation == ~@as(u64, 0)) return error.GenerationFailed;
        try validateConfig(self.config);
        try validateSampling(gen_config.sampling);
        errdefer self.finished = true;
        self.rng = sampling.Rng.init(gen_config.seed);
        if (gen_config.max_tokens == 0) return .{
            .session = self, .gen_config = gen_config, .generation = self.generation,
        };

        // Encode prompt with chat template
        self.prompt_len = @intCast(try tokenizer.encodeChatTurn(
            self.source,
            &self.vocabulary,
            &self.merges,
            gen_config.system_prompt,
            user_prompt,
            false, // no thinking block
            self.token_buf[0..self.config.max_context],
        ));
        // Reserve at least one position for a generated token before prefill.
        if (self.prompt_len == 0 or self.prompt_len >= self.config.max_context)
            return error.ContextCapacity;

        // Prefill: run all prompt tokens through the model (no logits until last)
        const progress = executor.Progress{
            .context = self.config.progress_ctx,
            .callback = self.config.progress_fn,
        };

        var i: u32 = 0;
        while (i < self.prompt_len) : (i += 1) {
            const produce_logits = (i == self.prompt_len - 1);
            _ = try executor.forward(
                TENSOR_CAPACITY,
                executor.qwen3_0_6b_limits,
                self.source,
                &self.index,
                &self.plan,
                &self.work,
                self.cache.rawSlice(),
                self.config.max_context,
                self.token_buf[i],
                i,
                produce_logits,
                progress,
            );
            self.position = i + 1;
            self.cache.context_used = self.position;
        }
        self.finished = false;
        return .{
            .session = self,
            .gen_config = gen_config,
            .generation = self.generation,
        };
    }

    /// Reset the session for a new generation (reuse model, clear KV cache).
    pub fn reset(self: *Session) void {
        self.cache.reset();
        self.position = 0;
        self.generated_count = 0;
        self.prompt_len = 0;
        self.finished = true;
        self.generation +|= 1;
    }

    /// Get the current context usage.
    pub fn contextUsed(self: *const Session) u32 {
        return self.position;
    }

    /// Get remaining context capacity.
    pub fn contextRemaining(self: *const Session) u32 {
        return self.config.max_context -| self.position;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Token Iterator (streaming output)
// ══════════════════════════════════════════════════════════════════════════════

pub const TokenIterator = struct {
    session: *Session,
    gen_config: GenerateConfig,
    generation: u64,

    pub const Output = struct {
        bytes: []const u8,
        token_id: u32,
        is_control: bool,
    };

    /// Get the next generated token. Returns null when generation is complete
    /// (hit max_tokens, EOS, or context limit).
    /// Errors are distinct from normal EOS and permanently stop this turn.
    /// Token boundaries may split UTF-8; consumers join bytes before decoding.
    pub fn next(self: *TokenIterator) Session.Error!?Output {
        const s = self.session;
        if (self.generation != s.generation) return error.StaleGeneration;
        if (s.finished) return null;
        errdefer s.finished = true;
        if (s.generated_count >= self.gen_config.max_tokens) { s.finished = true; return null; }
        if (s.position >= s.config.max_context) { s.finished = true; return null; }

        // Sample from logits (left in work.logits from the last forward pass)
        const vocab_size: usize = s.plan.vocabulary_size;
        if (vocab_size == 0 or vocab_size > s.work.logits.len) return error.InvalidPlan;
        for (s.work.logits[0..vocab_size]) |logit|
            if (!finite(logit)) return error.GenerationFailed;
        const token_id: u32 = @intCast(sampling.sample(
            s.work.logits[0..vocab_size],
            self.gen_config.sampling,
            &s.rng,
            s.token_buf[0..s.position],
        ));

        // Check stop conditions
        if (self.gen_config.stop_on_eos) {
            if (token_id == s.eos_token or token_id == s.eot_token) {
                s.finished = true;
                return null;
            }
        }

        // Decode token to UTF-8 bytes
        const decoded = try tokenizer.decodeToken(
            s.source,
            &s.vocabulary,
            token_id,
            &s.decode_scratch,
            &s.decode_out,
        );

        // Run forward pass for next position
        const progress = executor.Progress{
            .context = s.config.progress_ctx,
            .callback = s.config.progress_fn,
        };

        _ = try executor.forward(
            TENSOR_CAPACITY,
            executor.qwen3_0_6b_limits,
            s.source,
            &s.index,
            &s.plan,
            &s.work,
            s.cache.rawSlice(),
            s.config.max_context,
            token_id,
            s.position,
            true, // always produce logits for the next sample
            progress,
        );

        s.token_buf[s.position] = token_id;
        s.position += 1;
        s.cache.context_used = s.position;
        s.generated_count += 1;
        if (s.generated_count >= self.gen_config.max_tokens or s.position == s.config.max_context)
            s.finished = true;

        return .{
            .bytes = s.decode_out[0..decoded.bytes_written],
            .token_id = token_id,
            .is_control = decoded.control,
        };
    }

    /// Check if generation is complete.
    pub fn done(self: *const TokenIterator) bool {
        return self.generation != self.session.generation or self.session.finished;
    }

    /// Number of tokens generated so far.
    pub fn tokensGenerated(self: *const TokenIterator) u32 {
        return if (self.generation == self.session.generation) self.session.generated_count else 0;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Convenience: Single-shot generation (non-streaming)
// ══════════════════════════════════════════════════════════════════════════════

/// Generate a complete response as a byte slice.
/// Writes output into `output_buf` and returns the number of bytes written.
pub fn generateComplete(
    session: *Session,
    user_prompt: []const u8,
    gen_config: GenerateConfig,
    output_buf: []u8,
) Session.Error!usize {
    var iter = try session.generate(user_prompt, gen_config);
    var written: usize = 0;
    errdefer session.finished = true;
    while (try iter.next()) |output| {
        if (output.is_control) continue;
        const remaining = output_buf.len - written;
        if (output.bytes.len > remaining) return error.OutputCapacity;
        @memcpy(output_buf[written..][0..output.bytes.len], output.bytes);
        written += output.bytes.len;
    }
    return written;
}

fn validateConfig(config: SessionConfig) Session.Error!void {
    if (config.max_context == 0 or config.max_context > executor.qwen3_0_6b_limits.context)
        return error.ContextCapacity;
    if (config.progress_fn != null and config.progress_ctx == null) return error.InvalidPlan;
}

fn validateModel(plan: qwen3_plan.Plan, summary: gguf.Summary, config: SessionConfig) Session.Error!void {
    const limits = executor.qwen3_0_6b_limits;
    if (plan.hidden_size > limits.hidden or plan.query_size > limits.query or
        plan.key_value_size > limits.key_value or plan.feed_forward_size > limits.feed_forward or
        plan.vocabulary_size > limits.vocabulary or
        summary.tokenizer_tokens.count != plan.vocabulary_size or
        (summary.context_length != 0 and config.max_context > summary.context_length))
        return error.ModelNotSupported;
}

fn finite(value: f32) bool {
    return @as(u32, @bitCast(value)) & 0x7f800000 != 0x7f800000;
}

fn validateSampling(config: sampling.Config) Session.Error!void {
    if (!finite(config.temperature) or config.temperature < 0 or
        !finite(config.top_p) or config.top_p < 0 or config.top_p > 1 or
        !finite(config.min_p) or config.min_p < 0 or config.min_p > 1 or
        !finite(config.repetition_penalty) or config.repetition_penalty <= 0 or
        !finite(config.frequency_penalty) or !finite(config.presence_penalty))
        return error.InvalidSampling;
}
