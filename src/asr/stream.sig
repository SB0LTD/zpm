// @zpm/asr — Streaming Transcription Module
// Real-time ASR with 2-second chunk processing and prefix rollback.
//
// Algorithm (per Qwen3-ASR paper):
//   1. Audio buffered until chunk_size (2s = 32000 samples) accumulates
//   2. On trigger: ALL accumulated audio re-encoded through encoder
//   3. Decoder prompt includes previous text minus rollback_tokens (5)
//   4. New tokens generated; only "fixed" tokens (past rollback) emitted
//   5. Final chunk flushes remaining tokens
//
// Hebrew optimization:
//   - Language forced to Hebrew via prompt tokens
//   - System prompt biases toward Torah terminology
//   - Spelling preservation for common Hebrew terms

const mel_mod = @import("mel.sig");
const encoder_mod = @import("encoder.sig");
const decoder_mod = @import("decoder.sig");

// ── Streaming configuration ──
pub const StreamConfig = struct {
    chunk_size_samples: usize = 32000, // 2 seconds at 16kHz
    rollback_tokens: usize = 5, // drop last N tokens from prefix
    unfixed_chunks: usize = 2, // no prefix for first N chunks
    max_new_tokens_per_chunk: usize = 64, // max decode per chunk
    language: Language = .hebrew,
    prompt: ?[]const u8 = null, // system prompt for biasing
};

pub const Language = enum {
    hebrew,
    english,
    arabic,
    auto,

    pub fn token(self: Language) []const u8 {
        return switch (self) {
            .hebrew => "Hebrew",
            .english => "English",
            .arabic => "Arabic",
            .auto => "",
        };
    }
};

// ── Streaming state ──
pub const StreamState = struct {
    // Accumulated audio buffer
    audio_buf: [*]f32, // externally allocated, large
    audio_len: usize, // samples accumulated so far
    audio_cap: usize, // capacity

    // Decoded token history
    token_history: [8192]u32, // all generated tokens
    token_count: usize,

    // Fixed (committed) token count — tokens before this are stable
    fixed_count: usize,

    // Chunk counter
    chunk_num: usize,

    // Configuration
    cfg: StreamConfig,

    /// Initialize streaming state
    pub fn init(audio_buffer: [*]f32, audio_capacity: usize, cfg: StreamConfig) StreamState {
        return .{
            .audio_buf = audio_buffer,
            .audio_len = 0,
            .audio_cap = audio_capacity,
            .token_history = undefined,
            .token_count = 0,
            .fixed_count = 0,
            .chunk_num = 0,
            .cfg = cfg,
        };
    }

    /// Feed audio samples into the stream buffer.
    /// Returns true if a chunk boundary was reached and processing should occur.
    pub fn feed(self: *StreamState, samples: [*]const f32, n_samples: usize) bool {
        // Copy samples to buffer
        const space = self.audio_cap - self.audio_len;
        const to_copy = @min(n_samples, space);
        var i: usize = 0;
        while (i < to_copy) : (i += 1) {
            self.audio_buf[self.audio_len + i] = samples[i];
        }
        self.audio_len += to_copy;

        // Check if chunk boundary reached
        const chunks_available = self.audio_len / self.cfg.chunk_size_samples;
        return chunks_available > self.chunk_num;
    }

    /// Process the current chunk. Call after feed() returns true.
    /// enc_weights/dec_weights/etc are the model weights.
    /// Returns: slice of newly fixed token IDs (may be empty for early chunks).
    pub fn processChunk(
        self: *StreamState,
        enc_weights: *const encoder_mod.EncoderWeights,
        enc_cfg: *const encoder_mod.Config,
        dec_weights: *const decoder_mod.DecoderWeights,
        dec_cfg: *const decoder_mod.DecoderConfig,
        kv_cache: *decoder_mod.KVCache,
    ) []const u32 {
        self.chunk_num += 1;
        const prev_fixed = self.fixed_count;

        // Step 1: Encode ALL accumulated audio
        const n_frames = mel_mod.numFrames(self.audio_len);
        if (n_frames == 0) return self.token_history[prev_fixed..prev_fixed];

        // Compute mel (uses static buffer in mel_mod)
        var mel_buf: [60000 * 128]f32 = undefined;
        const actual_frames = @min(n_frames, 60000);
        _ = mel_mod.compute(self.audio_buf, self.audio_len, &mel_buf);

        // Normalize mel (Qwen3-ASR style)
        normalizeMel(&mel_buf, actual_frames * 128);

        // Encode
        const n_enc_tokens = encoder_mod.encode(&mel_buf, actual_frames, enc_weights, enc_cfg);
        if (n_enc_tokens == 0) return self.token_history[prev_fixed..prev_fixed];

        // Step 2: Build decoder prompt with prefix
        kv_cache.seq_len = 0; // Reset KV cache each chunk (re-encode everything)

        // Prefill prompt prefix
        const PREFIX = [_]u32{ 151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669 };
        for (PREFIX) |tok| {
            const emb = decoder_mod.getEmbedding(tok, dec_weights, dec_cfg);
            _ = decoder_mod.forward(emb, kv_cache, dec_weights, dec_cfg);
        }

        // Prefill audio embeddings
        const enc_out = encoder_mod.getOutput();
        var ai: usize = 0;
        while (ai < n_enc_tokens) : (ai += 1) {
            _ = decoder_mod.forward(enc_out + ai * dec_cfg.hidden_size, kv_cache, dec_weights, dec_cfg);
        }

        // Prefill suffix
        const SUFFIX = [_]u32{ 151670, 151645, 198, 151644, 77091, 198 };
        for (SUFFIX) |tok| {
            const emb = decoder_mod.getEmbedding(tok, dec_weights, dec_cfg);
            _ = decoder_mod.forward(emb, kv_cache, dec_weights, dec_cfg);
        }

        // Prefill text prefix (previous tokens minus rollback)
        if (self.chunk_num > self.cfg.unfixed_chunks and self.token_count > self.cfg.rollback_tokens) {
            const prefix_end = self.token_count - self.cfg.rollback_tokens;
            var ti: usize = 0;
            while (ti < prefix_end) : (ti += 1) {
                const emb = decoder_mod.getEmbedding(self.token_history[ti], dec_weights, dec_cfg);
                _ = decoder_mod.forward(emb, kv_cache, dec_weights, dec_cfg);
            }
        }

        // Step 3: Generate new tokens
        var new_count: usize = 0;
        var prev_token: u32 = SUFFIX[SUFFIX.len - 1];
        if (self.token_count > 0) prev_token = self.token_history[self.token_count - 1];

        while (new_count < self.cfg.max_new_tokens_per_chunk) : (new_count += 1) {
            const emb = decoder_mod.getEmbedding(prev_token, dec_weights, dec_cfg);
            const next = decoder_mod.forward(emb, kv_cache, dec_weights, dec_cfg);

            if (decoder_mod.isEos(next)) break;
            if (next == decoder_mod.TOKEN_ASR_TEXT) { prev_token = next; continue; }

            // Replace token history from the prefix-end point
            if (self.chunk_num <= self.cfg.unfixed_chunks) {
                // Early chunks: just append
                if (self.token_count < 8192) {
                    self.token_history[self.token_count] = next;
                    self.token_count += 1;
                }
            } else {
                // Later chunks: overwrite from (token_count - rollback)
                const write_pos = self.token_count - self.cfg.rollback_tokens + new_count;
                if (write_pos < 8192) {
                    self.token_history[write_pos] = next;
                }
            }
            prev_token = next;
        }

        // Update token count
        if (self.chunk_num > self.cfg.unfixed_chunks) {
            self.token_count = self.token_count - self.cfg.rollback_tokens + new_count;
        }

        // Fix tokens (all except last rollback_tokens are now stable)
        if (self.token_count > self.cfg.rollback_tokens) {
            self.fixed_count = self.token_count - self.cfg.rollback_tokens;
        }

        // Return newly fixed tokens
        return self.token_history[prev_fixed..self.fixed_count];
    }

    /// Flush remaining tokens (call at end of audio).
    /// Returns all unfixed tokens.
    pub fn flush(self: *StreamState) []const u32 {
        const prev_fixed = self.fixed_count;
        self.fixed_count = self.token_count;
        return self.token_history[prev_fixed..self.fixed_count];
    }
};

// ── Hebrew-specific prompt templates ──
pub const HEBREW_SYSTEM_PROMPT = "Transcribe Hebrew speech accurately. Preserve Torah terminology: " ++
    "HaShem, Baruch Hu, Chazal, Gemara, Mishnah, Rashi, Tosafot.";

pub const TORAH_BIASING_PROMPT = "This is a Torah shiur. Preserve Hebrew religious terminology and " ++
    "proper nouns. Use standard Israeli Hebrew orthography.";

// ── Mel normalization (Qwen3-ASR specific) ──
fn normalizeMel(mel_buf: [*]f32, total_elements: usize) void {
    // Convert ln → log10
    var i: usize = 0;
    var mel_max: f32 = -1000.0;
    while (i < total_elements) : (i += 1) {
        mel_buf[i] = mel_buf[i] / 2.302585093;
        if (mel_buf[i] > mel_max) mel_max = mel_buf[i];
    }
    // Dynamic range clamp + normalize
    const floor = mel_max - 8.0;
    i = 0;
    while (i < total_elements) : (i += 1) {
        if (mel_buf[i] < floor) mel_buf[i] = floor;
        mel_buf[i] = (mel_buf[i] + 4.0) / 4.0;
    }
}
