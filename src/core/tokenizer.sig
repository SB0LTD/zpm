//! Allocation-free Qwen byte-level BPE codec over an authenticated GGUF.
//!
//! Token text remains in model storage. Encoding uses caller-owned token
//! storage and the bounded vocabulary/merge indexes; decoding writes raw UTF-8
//! bytes directly into a caller-owned destination. No host tokenizer, heap,
//! locale, or operating-system service participates in the result.

const math = @import("sig_math.sig");
const mem = @import("sig_mem.sig");
const gguf = @import("gguf.sig");

pub const Error = error{
    TokenCapacity,
    UnknownByteToken,
    InvalidTokenEncoding,
    OutputCapacity,
    MissingSpecialToken,
} || @import("sb0_gguf_tokenizer_index").Error;

pub const DecodedToken = struct {
    bytes_written: usize,
    control: bool,
};

/// Encode Qwen's ASCII-compatible pre-tokenization expression. Non-ASCII
/// UTF-8 is retained as one bounded run, then passed through the same byte
/// alphabet and BPE machinery; it is never normalized or locale-folded.
pub fn encodeText(
    source: gguf.Source,
    vocabulary: anytype,
    merges: anytype,
    text: []const u8,
    tokens: []u32,
) Error!usize {
    var count: usize = 0;
    var position: usize = 0;
    while (position < text.len) {
        const length = nextPiece(text[position..]);
        if (length == 0 or length > text.len - position) return error.InvalidTokenEncoding;
        count = try encodePiece(source, vocabulary, merges, text[position..][0..length], tokens, count);
        position += length;
    }
    return count;
}

/// Encode one system/user turn using Qwen3's published generation template.
/// `thinking=false` emits the model's exact empty-think prefix, preventing an
/// unbounded reasoning prelude in the latency-bounded ephemeral UI profile.
pub fn encodeChatTurn(
    source: gguf.Source,
    vocabulary: anytype,
    merges: anytype,
    system_prompt: []const u8,
    user_prompt: []const u8,
    thinking: bool,
    tokens: []u32,
) Error!usize {
    var count: usize = 0;
    if (system_prompt.len != 0) {
        count = try appendExact(source, vocabulary, "<|im_start|>", tokens, count);
        count = try encodeTextFrom(source, vocabulary, merges, "system\n", tokens, count);
        count = try encodeTextFrom(source, vocabulary, merges, system_prompt, tokens, count);
        count = try appendExact(source, vocabulary, "<|im_end|>", tokens, count);
        count = try encodeTextFrom(source, vocabulary, merges, "\n", tokens, count);
    }
    count = try appendExact(source, vocabulary, "<|im_start|>", tokens, count);
    count = try encodeTextFrom(source, vocabulary, merges, "user\n", tokens, count);
    count = try encodeTextFrom(source, vocabulary, merges, user_prompt, tokens, count);
    count = try appendExact(source, vocabulary, "<|im_end|>", tokens, count);
    count = try encodeTextFrom(source, vocabulary, merges, "\n", tokens, count);
    count = try appendExact(source, vocabulary, "<|im_start|>", tokens, count);
    count = try encodeTextFrom(source, vocabulary, merges, "assistant\n", tokens, count);
    if (!thinking) {
        count = try appendExact(source, vocabulary, "<think>", tokens, count);
        count = try encodeTextFrom(source, vocabulary, merges, "\n\n", tokens, count);
        count = try appendExact(source, vocabulary, "</think>", tokens, count);
        count = try encodeTextFrom(source, vocabulary, merges, "\n\n", tokens, count);
    }
    return count;
}

fn encodeTextFrom(
    source: gguf.Source,
    vocabulary: anytype,
    merges: anytype,
    text: []const u8,
    tokens: []u32,
    initial_count: usize,
) Error!usize {
    if (initial_count > tokens.len) return error.TokenCapacity;
    const added = try encodeText(source, vocabulary, merges, text, tokens[initial_count..]);
    return initial_count + added;
}

fn appendExact(source: gguf.Source, vocabulary: anytype, text: []const u8, tokens: []u32, count: usize) Error!usize {
    if (count >= tokens.len) return error.TokenCapacity;
    tokens[count] = vocabulary.lookup(source, text) orelse return error.MissingSpecialToken;
    return count + 1;
}

/// Encode one pre-tokenized byte span. This is public so an executor with a
/// richer Unicode segmenter can retain exactly the same bounded BPE core.
pub fn encodePiece(
    source: gguf.Source,
    vocabulary: anytype,
    merges: anytype,
    piece: []const u8,
    tokens: []u32,
    initial_count: usize,
) Error!usize {
    if (initial_count > tokens.len or piece.len > tokens.len - initial_count)
        return error.TokenCapacity;
    var count = initial_count;
    for (piece) |byte| {
        var encoded: [2]u8 = undefined;
        const encoded_length = encodeByte(byte, &encoded);
        tokens[count] = vocabulary.lookup(source, encoded[0..encoded_length]) orelse
            return error.UnknownByteToken;
        count += 1;
    }

    const piece_start = initial_count;
    while (count - piece_start >= 2) {
        var best_rank: u32 = math.maxInt(u32);
        var best_left: u32 = 0;
        var best_right: u32 = 0;
        var best_result: u32 = 0;
        var found = false;
        var index = piece_start;
        while (index + 1 < count) : (index += 1) {
            const merge = merges.find(tokens[index], tokens[index + 1]) orelse continue;
            if (!found or merge.rank < best_rank) {
                found = true;
                best_rank = merge.rank;
                best_left = tokens[index];
                best_right = tokens[index + 1];
                best_result = merge.result_token;
            }
        }
        if (!found) break;

        // GPT/Qwen BPE replaces every non-overlapping occurrence of the
        // selected pair left-to-right before selecting the next rank.
        var read = piece_start;
        var write = piece_start;
        while (read < count) {
            if (read + 1 < count and tokens[read] == best_left and tokens[read + 1] == best_right) {
                tokens[write] = best_result;
                write += 1;
                read += 2;
            } else {
                tokens[write] = tokens[read];
                write += 1;
                read += 1;
            }
        }
        count = write;
    }
    return count;
}

/// Decode one token. Qwen control tokens are reported but not copied into the
/// user-visible byte stream. The scratch buffer bounds model-token length.
pub fn decodeToken(
    source: gguf.Source,
    vocabulary: anytype,
    token: u32,
    scratch: []u8,
    destination: []u8,
) Error!DecodedToken {
    const length = try vocabulary.copyToken(source, token, scratch);
    const encoded = scratch[0..length];
    if (encoded.len >= 4 and mem.startsWith(u8, encoded, "<|") and
        mem.endsWith(u8, encoded, "|>")) return .{ .bytes_written = 0, .control = true };

    var input: usize = 0;
    var output: usize = 0;
    while (input < encoded.len) {
        const decoded = try decodeCodepoint(encoded[input..]);
        const byte = inverseByte(decoded.codepoint) orelse return error.InvalidTokenEncoding;
        if (output == destination.len) return error.OutputCapacity;
        destination[output] = byte;
        output += 1;
        input += decoded.length;
    }
    return .{ .bytes_written = output, .control = false };
}

const DecodedCodepoint = struct { codepoint: u16, length: u8 };

fn decodeCodepoint(bytes: []const u8) Error!DecodedCodepoint {
    if (bytes.len == 0) return error.InvalidTokenEncoding;
    if (bytes[0] < 0x80) return .{ .codepoint = bytes[0], .length = 1 };
    if (bytes.len < 2 or bytes[0] < 0xc2 or bytes[0] > 0xc5 or
        (bytes[1] & 0xc0) != 0x80) return error.InvalidTokenEncoding;
    const codepoint = (@as(u16, bytes[0] & 0x1f) << 6) | (bytes[1] & 0x3f);
    if (codepoint > 323) return error.InvalidTokenEncoding;
    return .{ .codepoint = codepoint, .length = 2 };
}

fn encodeByte(byte: u8, destination: *[2]u8) usize {
    const codepoint: u16 = if (byteIncluded(byte)) byte else 256 + excludedIndex(byte);
    if (codepoint < 0x80) {
        destination[0] = @intCast(codepoint);
        return 1;
    }
    destination[0] = 0xc0 | @as(u8, @intCast(codepoint >> 6));
    destination[1] = 0x80 | @as(u8, @intCast(codepoint & 0x3f));
    return 2;
}

fn inverseByte(codepoint: u16) ?u8 {
    if (codepoint <= 255) {
        const byte: u8 = @intCast(codepoint);
        return if (byteIncluded(byte)) byte else null;
    }
    if (codepoint > 323) return null;
    const index = codepoint - 256;
    if (index <= 32) return @intCast(index);
    if (index <= 66) return @intCast(127 + index - 33);
    if (index == 67) return 173;
    return null;
}

fn byteIncluded(byte: u8) bool {
    return (byte >= 33 and byte <= 126) or
        (byte >= 161 and byte <= 172) or
        (byte >= 174);
}

fn excludedIndex(byte: u8) u16 {
    if (byte <= 32) return byte;
    if (byte >= 127 and byte <= 160) return 33 + @as(u16, byte - 127);
    if (!(byte == 173)) unreachable;
    return 67;
}

fn nextPiece(text: []const u8) usize {
    if (text.len == 0) return 0;
    if (contractionLength(text)) |length| return length;

    const first = text[0];
    if (isAsciiLetter(first)) return letterRun(text, 0);
    if (isAsciiDigit(first)) return @min(digitRun(text), 3);

    // The Qwen expression attaches one non-letter/non-number prefix (normally
    // a space) to the following letter run.
    if (first != '\r' and first != '\n' and !isAsciiLetter(first) and
        !isAsciiDigit(first) and text.len > 1 and isAsciiLetter(text[1]))
        return letterRun(text, 1);

    if (isHorizontalWhitespace(first)) {
        var run: usize = 1;
        while (run < text.len and isHorizontalWhitespace(text[run])) : (run += 1) {}
        // Preserve the final space as the prefix of a following word.
        if (run < text.len and isAsciiLetter(text[run]) and run > 1) return run - 1;
        return run;
    }

    if (first == '\r' or first == '\n') {
        var run: usize = 1;
        while (run < text.len and (text[run] == '\r' or text[run] == '\n')) : (run += 1) {}
        return run;
    }

    if (first >= 0x80) {
        var run = utf8ScalarLength(text) orelse 1;
        while (run < text.len and text[run] >= 0x80) {
            const scalar = utf8ScalarLength(text[run..]) orelse break;
            run += scalar;
        }
        return run;
    }

    // Punctuation/symbol span, optionally followed by line endings.
    var run: usize = 1;
    while (run < text.len and !isWhitespace(text[run]) and
        !isAsciiLetter(text[run]) and !isAsciiDigit(text[run]) and text[run] < 0x80) : (run += 1) {}
    while (run < text.len and (text[run] == '\r' or text[run] == '\n')) : (run += 1) {}
    return run;
}

fn contractionLength(text: []const u8) ?usize {
    if (text.len < 2 or text[0] != '\'') return null;
    const second = asciiLower(text[1]);
    if (second == 's' or second == 'd' or second == 'm' or second == 't') return 2;
    if (text.len < 3) return null;
    const third = asciiLower(text[2]);
    if ((second == 'l' and third == 'l') or
        (second == 'v' and third == 'e') or
        (second == 'r' and third == 'e')) return 3;
    return null;
}

fn letterRun(text: []const u8, prefix: usize) usize {
    var run = prefix;
    while (run < text.len and isAsciiLetter(text[run])) : (run += 1) {}
    return run;
}

fn digitRun(text: []const u8) usize {
    var run: usize = 0;
    while (run < text.len and isAsciiDigit(text[run])) : (run += 1) {}
    return run;
}

fn utf8ScalarLength(text: []const u8) ?usize {
    if (text.len == 0) return null;
    const length: usize = if (text[0] < 0x80) 1 else if (text[0] < 0xe0) 2 else if (text[0] < 0xf0) 3 else 4;
    if (length > text.len) return null;
    var index: usize = 1;
    while (index < length) : (index += 1) if ((text[index] & 0xc0) != 0x80) return null;
    return length;
}

fn isAsciiLetter(byte: u8) bool {
    const lower = asciiLower(byte);
    return lower >= 'a' and lower <= 'z';
}

fn isAsciiDigit(byte: u8) bool { return byte >= '0' and byte <= '9'; }
fn isHorizontalWhitespace(byte: u8) bool { return byte == ' ' or byte == '\t' or byte == 0x0b or byte == 0x0c; }
fn isWhitespace(byte: u8) bool { return isHorizontalWhitespace(byte) or byte == '\r' or byte == '\n'; }
fn asciiLower(byte: u8) u8 { return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte; }

const tokenizer_index = @import("tokenizer_index.sig");

const SliceSource = struct {
    bytes: []const u8,

    fn readAt(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const SliceSource = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start > self.bytes.len or destination.len > self.bytes.len - start) return false;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return true;
    }

    fn source(self: *const SliceSource) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = readAt };
    }
};

