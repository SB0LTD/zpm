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
//!   while (iter.next()) |token_bytes| { ... use UTF-8 bytes ... }
//!   session.reset(); // Ready for next generation
//!
//! Zero heap allocation. All storage via caller-provided AllocFn.

const std = @import("std");
const gguf = @import("gguf.sig");
const qwen3_plan = @import("qwen3_decoder_plan.sig");
const executor = @import("qwen3_executor.sig");
const tokenizer = @import("tokenizer.sig");
const tokenizer_index = @import("tokenizer_index.sig");
const sampling = @import("sampling.sig");
const kv_cache = @import("kv_cache.sig");

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
    max_context: u32 = 2048,
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
const MAX_TOKEN_BYTES = 128;

/// Maximum merge pairs for BPE.
const MERGE_HASH_CAPACITY = 262144;
const MAX_MERGE_BYTES = 256;

/// Token buffer for encoding prompts.
const MAX_PROMPT_TOKENS = 2048;

/// Decode scratch buffer (single token → UTF-8 bytes).
const DECODE_SCRATCH_SIZE = 256;

pub const Session = struct {
    // Model state
    source: gguf.Source,
    index: gguf.Index(TENSOR_CAPACITY),
    plan: qwen3_plan.Plan,

    // Tokenizer
    vocabulary: tokenizer_index.VocabularyIndex(VOCAB_HASH_CAPACITY, MAX_TOKEN_BYTES),
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
        error{ ModelNotSupported, GenerationFailed };

    /// Initialize a session from a GGUF model source.
    pub fn init(
        alloc_fn: kv_cache.AllocFn,
        source: gguf.Source,
        config: SessionConfig,
    ) Error!Session {
        var session: Session = undefined;
        session.source = source;
        session.alloc_fn = alloc_fn;
        session.config = config;
        session.position = 0;
        session.generated_count = 0;
        session.finished = false;
        session.prompt_len = 0;

        // 1. Parse GGUF index
        try gguf.parse(TENSOR_CAPACITY, source, &session.index);

        // 2. Build decoder plan
        try qwen3_plan.build(TENSOR_CAPACITY, &session.index, &session.plan);

        // 3. Build tokenizer vocabulary index
        try session.vocabulary.build(source, session.index.summary.tokenizer_tokens);

        // 4. Build merge index
        try session.merges.build(source, session.index.summary.tokenizer_merges, &session.vocabulary);

        // 5. Allocate KV cache
        session.cache = try kv_cache.KvCache.init(
            alloc_fn,
            @intCast(session.plan.layer_count),
            session.plan.kv_head_count,
            session.plan.head_size,
            config.max_context,
        );

        // 6. Resolve stop tokens
        session.eos_token = session.vocabulary.lookup(source, "<|endoftext|>") orelse 151643;
        session.eot_token = session.vocabulary.lookup(source, "<|im_end|>") orelse 151645;

        // 7. Zero working set
        session.work = .{};

        return session;
    }

    /// Encode a prompt and prepare for generation.
    /// Returns an iterator that yields UTF-8 byte slices per generated token.
    pub fn generate(self: *Session, user_prompt: []const u8, gen_config: GenerateConfig) Error!TokenIterator {
        self.position = 0;
        self.generated_count = 0;
        self.finished = false;
        self.rng = sampling.Rng.init(gen_config.seed);
        self.cache.reset();

        // Encode prompt with chat template
        self.prompt_len = @intCast(try tokenizer.encodeChatTurn(
            self.source,
            &self.vocabulary,
            &self.merges,
            gen_config.system_prompt,
            user_prompt,
            false, // no thinking block
            &self.token_buf,
        ));

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
        }

        return .{
            .session = self,
            .gen_config = gen_config,
        };
    }

    /// Reset the session for a new generation (reuse model, clear KV cache).
    pub fn reset(self: *Session) void {
        self.cache.reset();
        self.position = 0;
        self.generated_count = 0;
        self.finished = false;
    }

    /// Get the current context usage.
    pub fn contextUsed(self: *const Session) u32 {
        return self.position;
    }

    /// Get remaining context capacity.
    pub fn contextRemaining(self: *const Session) u32 {
        return self.config.max_context - self.position;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Token Iterator (streaming output)
// ══════════════════════════════════════════════════════════════════════════════

pub const TokenIterator = struct {
    session: *Session,
    gen_config: GenerateConfig,

    pub const Output = struct {
        bytes: []const u8,
        token_id: u32,
        is_control: bool,
    };

    /// Get the next generated token. Returns null when generation is complete
    /// (hit max_tokens, EOS, or context limit).
    pub fn next(self: *TokenIterator) ?Output {
        const s = self.session;
        if (s.finished) return null;
        if (s.generated_count >= self.gen_config.max_tokens) { s.finished = true; return null; }
        if (s.position >= s.config.max_context) { s.finished = true; return null; }

        // Sample from logits (left in work.logits from the last forward pass)
        const vocab_size: usize = s.plan.vocabulary_size;
        const token_id: u32 = @intCast(sampling.sample(
            s.work.logits[0..vocab_size],
            self.gen_config.sampling,
            &s.rng,
            s.token_buf[0..@min(s.position, MAX_PROMPT_TOKENS)],
        ));

        // Check stop conditions
        if (self.gen_config.stop_on_eos) {
            if (token_id == s.eos_token or token_id == s.eot_token) {
                s.finished = true;
                return null;
            }
        }

        // Decode token to UTF-8 bytes
        const decoded = tokenizer.decodeToken(
            s.source,
            &s.vocabulary,
            token_id,
            &s.decode_scratch,
            &s.decode_out,
        ) catch {
            s.finished = true;
            return null;
        };

        // Run forward pass for next position
        const progress = executor.Progress{
            .context = s.config.progress_ctx,
            .callback = s.config.progress_fn,
        };

        _ = executor.forward(
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
        ) catch {
            s.finished = true;
            return null;
        };

        s.position += 1;
        s.generated_count += 1;

        return .{
            .bytes = s.decode_out[0..decoded.bytes_written],
            .token_id = token_id,
            .is_control = decoded.control,
        };
    }

    /// Check if generation is complete.
    pub fn done(self: *const TokenIterator) bool {
        return self.session.finished;
    }

    /// Number of tokens generated so far.
    pub fn tokensGenerated(self: *const TokenIterator) u32 {
        return self.session.generated_count;
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
    while (iter.next()) |output| {
        if (output.is_control) continue;
        const remaining = output_buf.len - written;
        const to_copy = @min(output.bytes.len, remaining);
        @memcpy(output_buf[written..][0..to_copy], output.bytes[0..to_copy]);
        written += to_copy;
        if (to_copy < output.bytes.len) break; // Buffer full
    }
    return written;
}
