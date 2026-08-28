// @zpm/llm — BPE Tokenizer
// Byte-level BPE (GPT-2 / Qwen / LLaMA style).
// Loads vocab + merge rules from GGUF metadata (via gguf_loader).
//
// Zero heap allocation: uses fixed-size lookup tables and stack buffers.
//
// Encoding algorithm (greedy BPE):
//   1. Convert UTF-8 input to byte-level tokens (each byte → vocab entry)
//   2. Iteratively find the highest-priority merge pair
//   3. Merge until no more merges apply
//   Result: sequence of token IDs
//
// Decoding algorithm:
//   1. Look up each token ID in vocab → byte sequence
//   2. Concatenate all byte sequences
//   3. Result is UTF-8 text
//
// Qwen tokenizer specifics:
//   - 151,936 vocab entries
//   - Byte fallback tokens: <0x00> through <0xFF>
//   - Special tokens: <|im_start|>, <|im_end|>, <|endoftext|>, etc.

pub const MAX_VOCAB: usize = 256000;
pub const MAX_TOKEN_LEN: usize = 128;
pub const MAX_ENCODE_LEN: usize = 32768; // max input bytes for encode
pub const MAX_TOKENS_OUT: usize = 16384; // max output token count

pub const TokenEntry = struct {
    text: [MAX_TOKEN_LEN]u8,
    len: u8,
    score: f32, // merge priority (lower = merged earlier)
    token_type: u8, // 1=normal, 2=control, 3=byte_fallback
};

/// Merge rule: merging token A + token B produces token C
/// Priority is determined by order in the merges list (earlier = higher priority).
pub const MergeRule = struct {
    a: u32, // left token ID
    b: u32, // right token ID
    result: u32, // merged token ID
};

pub const MAX_MERGES: usize = 256000;

pub const MergeCand = struct { id: u32, score: f32 };

pub const Tokenizer = struct {
    vocab: [MAX_VOCAB]TokenEntry,
    vocab_size: usize,
    // Merge rules sorted by priority (index 0 = highest priority)
    merges: [MAX_MERGES]MergeRule,
    n_merges: usize,
    // Byte fallback token IDs: byte_tokens[0x41] = token_id for byte 0x41
    byte_tokens: [256]u32,
    // Special tokens
    bos_id: u32,
    eos_id: u32,
    pad_id: u32,

    /// Initialize from GGUF loader's tokenizer data.
    /// Call after gguf_loader.load() has populated the TokenizerData.
    /// Operates directly on self pointer to avoid 37MB stack copy.
    pub fn initFromGGUF(
        self: *Tokenizer,
        vocab_entries: [*]const GGUFTokenEntry,
        n_vocab: usize,
    ) void {
        self.vocab_size = @min(n_vocab, MAX_VOCAB);
        self.n_merges = 0;
        self.bos_id = 151643; // Qwen: <|endoftext|>
        self.eos_id = 151645; // Qwen: <|im_end|>
        self.pad_id = 151643;
        @memset(&self.byte_tokens, 0);

        // Copy vocab entries
        for (0..self.vocab_size) |i| {
            const src = &vocab_entries[i];
            @memcpy(self.vocab[i].text[0..src.len], src.text[0..src.len]);
            self.vocab[i].len = src.len;
            self.vocab[i].score = src.score;
            self.vocab[i].token_type = src.token_type;

            // Detect byte fallback tokens: "<0xHH>" pattern
            if (src.len == 6 and src.text[0] == '<' and src.text[1] == '0' and src.text[2] == 'x' and src.text[5] == '>') {
                const hi = hexVal(src.text[3]);
                const lo = hexVal(src.text[4]);
                if (hi <= 15 and lo <= 15) {
                    const byte_val = hi * 16 + lo;
                    self.byte_tokens[byte_val] = @intCast(i);
                }
            }
        }

        // Merges are loaded separately via loadMergesFromGGUF after vocab is populated.
        self.n_merges = 0;
    }

    /// Load BPE merge rules from GGUF merge strings.
    /// Each merge string is "token_a token_b" — we split on the first space,
    /// look up each half in the vocab, and the merged result is also looked up
    /// (concatenation of both halves). The merge priority is the index order
    /// (index 0 = highest priority, applied first).
    ///
    /// This is called by the pipeline after initFromGGUF has populated vocab.
    pub fn loadMergesFromGGUF(
        self: *Tokenizer,
        merge_strs: [*]const GGUFMergeEntry,
        n_merge_strs: usize,
    ) void {
        self.n_merges = 0;
        const max = @min(n_merge_strs, MAX_MERGES);

        for (0..max) |mi| {
            const entry = &merge_strs[mi];
            const text = entry.text[0..entry.len];

            // Find the space separator between token_a and token_b
            var space_pos: usize = 0;
            var found_space = false;
            for (0..text.len) |i| {
                if (text[i] == ' ') {
                    space_pos = i;
                    found_space = true;
                    break;
                }
            }
            if (!found_space) continue;
            if (space_pos == 0 or space_pos >= text.len - 1) continue;

            const left_text = text[0..space_pos];
            const right_text = text[space_pos + 1 ..];

            // Look up both halves in the vocab
            const left_id = self.findToken(left_text) orelse continue;
            const right_id = self.findToken(right_text) orelse continue;

            // The merged result is the concatenation of both halves
            var merged_buf: [MAX_TOKEN_LEN]u8 = undefined;
            const merged_len = left_text.len + right_text.len;
            if (merged_len >= MAX_TOKEN_LEN) continue;
            @memcpy(merged_buf[0..left_text.len], left_text);
            @memcpy(merged_buf[left_text.len..merged_len], right_text);

            const result_id = self.findToken(merged_buf[0..merged_len]) orelse continue;

            self.merges[self.n_merges] = .{
                .a = left_id,
                .b = right_id,
                .result = result_id,
            };
            self.n_merges += 1;
        }
    }

    /// Decode a single token ID to UTF-8 bytes.
    /// Returns number of bytes written to buf.
    pub fn decode(self: *const Tokenizer, token_id: u32, buf: *[MAX_TOKEN_LEN]u8) u8 {
        if (token_id >= self.vocab_size) return 0;
        const entry = &self.vocab[token_id];

        // Byte fallback token: "<0xHH>" → single byte
        if (entry.token_type == 3 or
            (entry.len == 6 and entry.text[0] == '<' and entry.text[1] == '0' and entry.text[2] == 'x'))
        {
            const hi = hexVal(entry.text[3]);
            const lo = hexVal(entry.text[4]);
            buf[0] = @intCast(hi * 16 + lo);
            return 1;
        }

        // Control token: return empty (don't emit special tokens as text)
        if (entry.token_type == 2) return 0;

        // Normal token: copy text directly (already UTF-8 in Qwen tokenizer)
        const len = entry.len;
        @memcpy(buf[0..len], entry.text[0..len]);
        return len;
    }

    /// Decode a sequence of token IDs to UTF-8 text.
    /// Returns number of bytes written.
    pub fn decodeSequence(
        self: *const Tokenizer,
        token_ids: [*]const u32,
        n_tokens: usize,
        out_buf: [*]u8,
        out_cap: usize,
    ) usize {
        var out_len: usize = 0;
        var tok_buf: [MAX_TOKEN_LEN]u8 = undefined;

        for (0..n_tokens) |i| {
            const n = self.decode(token_ids[i], &tok_buf);
            if (out_len + n > out_cap) break;
            @memcpy(out_buf[out_len .. out_len + n], tok_buf[0..n]);
            out_len += n;
        }
        return out_len;
    }

    /// Encode UTF-8 text to token IDs using BPE.
    /// Returns number of tokens produced.
    pub fn encode(
        self: *const Tokenizer,
        text: []const u8,
        out_ids: [*]u32,
        max_tokens: usize,
    ) usize {
        if (text.len == 0) return 0;
        const input_len = @min(text.len, MAX_ENCODE_LEN);

        // Step 1: Initialize with one token per byte (byte fallback)
        // We use a linked-list-in-array structure for efficient merging.
        var tokens: [MAX_ENCODE_LEN]u32 = undefined;
        var next: [MAX_ENCODE_LEN]i32 = undefined; // next[i] = index of next token, -1 = end
        var n_active: usize = input_len;

        for (0..input_len) |i| {
            // Look up single-byte token
            tokens[i] = self.byte_tokens[text[i]];
            next[i] = if (i + 1 < input_len) @intCast(i + 1) else -1;
        }

        // Step 2: Iteratively apply BPE merges (greedy, highest priority first)
        // For each merge rule (in priority order), scan and merge all occurrences.
        // This is O(n_merges * sequence_length) — acceptable for <32K tokens.
        var changed = true;
        while (changed) {
            changed = false;
            var best_merge_idx: usize = MAX_MERGES; // no merge found
            var best_pos: i32 = -1;
            var best_priority: usize = MAX_MERGES;

            // Find the highest-priority applicable merge
            var pos: i32 = 0;
            while (pos >= 0) {
                const pos_u: usize = @intCast(pos);
                const next_pos = next[pos_u];
                if (next_pos < 0) break;
                const next_u: usize = @intCast(next_pos);

                const pair_a = tokens[pos_u];
                const pair_b = tokens[next_u];

                // Look up this pair in merges (linear scan — could be hash table)
                const merge_idx = self.findMerge(pair_a, pair_b);
                if (merge_idx < best_priority) {
                    best_priority = merge_idx;
                    best_merge_idx = merge_idx;
                    best_pos = pos;
                }

                pos = next_pos;
            }

            // Apply the best merge found
            if (best_merge_idx < MAX_MERGES and best_pos >= 0) {
                const bp: usize = @intCast(best_pos);
                const merge = &self.merges[best_merge_idx];

                // Apply ALL occurrences of this merge in one pass
                pos = 0;
                while (pos >= 0) {
                    const pos_u2: usize = @intCast(pos);
                    const next_pos2 = next[pos_u2];
                    if (next_pos2 < 0) break;
                    const next_u2: usize = @intCast(next_pos2);

                    if (tokens[pos_u2] == merge.a and tokens[next_u2] == merge.b) {
                        // Merge: replace token at pos with result, skip next
                        tokens[pos_u2] = merge.result;
                        next[pos_u2] = next[next_u2];
                        n_active -= 1;
                        changed = true;
                        // Don't advance pos — check if new token can merge with next
                    } else {
                        pos = next_pos2;
                    }
                }

                _ = bp;
            }
        }

        // Step 3: Collect active tokens into output
        var count: usize = 0;
        var pos2: i32 = 0;
        while (pos2 >= 0 and count < max_tokens) {
            const pos_u3: usize = @intCast(pos2);
            out_ids[count] = tokens[pos_u3];
            count += 1;
            pos2 = next[pos_u3];
        }

        return count;
    }

    /// Find a merge rule for pair (a, b). Returns merge index (priority) or MAX_MERGES if not found.
    fn findMerge(self: *const Tokenizer, a: u32, b: u32) usize {
        // Linear scan of merge rules (sorted by priority).
        // For production: replace with hash map for O(1) lookup.
        for (0..self.n_merges) |i| {
            if (self.merges[i].a == a and self.merges[i].b == b) return i;
        }
        return MAX_MERGES;
    }

    /// Find a token ID by its text. Returns null if not in vocab.
    pub fn findToken(self: *const Tokenizer, text: []const u8) ?u32 {
        if (text.len == 0 or text.len >= MAX_TOKEN_LEN) return null;
        for (0..self.vocab_size) |i| {
            const entry = &self.vocab[i];
            if (entry.len == text.len) {
                var match = true;
                for (0..text.len) |j| {
                    if (entry.text[j] != text[j]) { match = false; break; }
                }
                if (match) return @intCast(i);
            }
        }
        return null;
    }
};

// ── Helper types for initFromGGUF ──

pub const GGUFTokenEntry = struct {
    text: [MAX_TOKEN_LEN]u8,
    len: u8,
    score: f32,
    token_type: u8,
};

pub const GGUFMergeEntry = struct {
    text: [256]u8,
    len: u8,
};

// ── Utility functions ──

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 255;
}
