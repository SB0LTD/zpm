// @zpm/asr — Model Integration Module
// Full ASR pipeline: WAV → mel → encode → decode → text
//
// Public API:
//   Model.init(model_dir) — load weights from safetensors
//   Model.transcribe(audio_samples, n_samples, language) — full transcription
//
// Prompt template (Qwen3-ASR chat format):
//   <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>
//   <|audio_pad|>×N_audio_tokens
//   <|audio_end|><|im_end|>\n<|im_start|>assistant\n
//
// Decode: generate tokens until EOS, parse after <asr_text>

const mel = @import("mel.sig");
const encoder = @import("encoder.sig");
const decoder = @import("decoder.sig");

// ── Prompt token sequences ──
// PREFIX: <|im_start|> system \n <|im_end|> \n <|im_start|> user \n <|audio_start|>
const PROMPT_PREFIX = [_]u32{ 151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669 };
// SUFFIX: <|audio_end|> <|im_end|> \n <|im_start|> assistant \n
const PROMPT_SUFFIX = [_]u32{ 151670, 151645, 198, 151644, 77091, 198 };

// ── Model state ──
pub const Model = struct {
    enc_weights: encoder.EncoderWeights,
    dec_weights: decoder.DecoderWeights,
    enc_cfg: encoder.Config,
    dec_cfg: decoder.DecoderConfig,
    kv_cache: decoder.KVCache,
    loaded: bool,

    /// Initialize an empty model (weights not yet loaded)
    pub fn empty(variant: Variant) Model {
        return .{
            .enc_weights = undefined,
            .dec_weights = undefined,
            .enc_cfg = switch (variant) {
                .v1_7b => encoder.CONFIG_1_7B,
                .v0_6b => encoder.CONFIG_0_6B,
            },
            .dec_cfg = switch (variant) {
                .v1_7b => decoder.DECODER_1_7B,
                .v0_6b => decoder.DECODER_0_6B,
            },
            .kv_cache = undefined,
            .loaded = false,
        };
    }

    /// Transcribe audio samples to text.
    /// audio: pointer to f32 samples at 16kHz mono
    /// n_samples: number of samples
    /// out_text: buffer to write UTF-8 text into
    /// Returns: number of bytes written to out_text
    pub fn transcribe(
        self: *Model,
        audio: [*]const f32,
        n_samples: usize,
        out_text: [*]u8,
        out_cap: usize,
    ) usize {
        if (!self.loaded) return 0;

        // Step 1: Compute mel spectrogram
        const n_frames = mel.numFrames(n_samples);
        if (n_frames == 0) return 0;

        // Allocate mel buffer (n_frames * 128 f32)
        // For 91 min audio: ~550K frames × 128 = 70M floats = 280MB
        // This needs external allocation. For now use a bounded static.
        const max_mel_frames: usize = 60000; // ~10 min of audio
        var mel_buf: [max_mel_frames * mel.N_MELS]f32 = undefined;
        const actual_frames = @min(n_frames, max_mel_frames);
        _ = mel.compute(audio, @min(n_samples, actual_frames * mel.HOP_LENGTH + mel.N_FFT), &mel_buf);

        // Apply Qwen3-ASR mel normalization:
        // log_spec = log10(clamp(mel_spec, min=1e-10))
        // log_spec = max(log_spec, log_spec.max() - 8.0)
        // log_spec = (log_spec + 4.0) / 4.0
        var mel_max: f32 = -1000.0;
        var mi: usize = 0;
        while (mi < actual_frames * mel.N_MELS) : (mi += 1) {
            // Convert from ln to log10: log10(x) = ln(x) / ln(10)
            mel_buf[mi] = mel_buf[mi] / 2.302585093; // our mel.sig outputs ln, convert to log10
            if (mel_buf[mi] > mel_max) mel_max = mel_buf[mi];
        }
        const floor = mel_max - 8.0;
        mi = 0;
        while (mi < actual_frames * mel.N_MELS) : (mi += 1) {
            if (mel_buf[mi] < floor) mel_buf[mi] = floor;
            mel_buf[mi] = (mel_buf[mi] + 4.0) / 4.0;
        }

        // Step 2: Run encoder
        const n_enc_tokens = encoder.encode(&mel_buf, actual_frames, &self.enc_weights, &self.enc_cfg);
        if (n_enc_tokens == 0) return 0;
        const enc_out = encoder.getOutput();

        // Step 3: Build prompt and prefill decoder
        self.kv_cache.seq_len = 0;

        // Prefill PREFIX tokens
        for (PROMPT_PREFIX) |tok_id| {
            const emb = decoder.getEmbedding(tok_id, &self.dec_weights, &self.dec_cfg);
            _ = decoder.forward(emb, &self.kv_cache, &self.dec_weights, &self.dec_cfg);
        }

        // Prefill AUDIO tokens (replace audio_pad embeddings with encoder output)
        var ai: usize = 0;
        while (ai < n_enc_tokens) : (ai += 1) {
            const audio_emb = enc_out + ai * self.dec_cfg.hidden_size;
            _ = decoder.forward(audio_emb, &self.kv_cache, &self.dec_weights, &self.dec_cfg);
        }

        // Prefill SUFFIX tokens
        for (PROMPT_SUFFIX) |tok_id| {
            const emb = decoder.getEmbedding(tok_id, &self.dec_weights, &self.dec_cfg);
            _ = decoder.forward(emb, &self.kv_cache, &self.dec_weights, &self.dec_cfg);
        }

        // Step 4: Autoregressive decoding
        var text_len: usize = 0;
        var past_asr_text = false;
        const max_new_tokens: usize = 4096;
        var gen: usize = 0;

        // Generate from last suffix token
        var prev_token: u32 = PROMPT_SUFFIX[PROMPT_SUFFIX.len - 1];

        while (gen < max_new_tokens) : (gen += 1) {
            const emb = decoder.getEmbedding(prev_token, &self.dec_weights, &self.dec_cfg);
            const next_token = decoder.forward(emb, &self.kv_cache, &self.dec_weights, &self.dec_cfg);

            if (decoder.isEos(next_token)) break;

            // Track <asr_text> marker
            if (next_token == decoder.TOKEN_ASR_TEXT) {
                past_asr_text = true;
                prev_token = next_token;
                continue;
            }

            // Only output text after <asr_text> token
            if (past_asr_text) {
                // Decode token to text (simplified — would use full BPE decode)
                // For now: store token IDs; proper tokenizer decode happens externally
                if (text_len + 4 < out_cap) {
                    // Store as raw token ID (4 bytes LE) for external decode
                    out_text[text_len] = @intCast(next_token & 0xFF);
                    out_text[text_len + 1] = @intCast((next_token >> 8) & 0xFF);
                    out_text[text_len + 2] = @intCast((next_token >> 16) & 0xFF);
                    out_text[text_len + 3] = @intCast((next_token >> 24) & 0xFF);
                    text_len += 4;
                }
            }

            prev_token = next_token;
        }

        return text_len;
    }
};

pub const Variant = enum { v1_7b, v0_6b };
