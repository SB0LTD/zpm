//! Allocation-free LFM3 text codec over an authenticated GGUF.
//!
//! LFM3 ships a GPT-2 byte-level BPE vocabulary with the `lfm2` pre-tokenizer,
//! which llama.cpp runs as its LLAMA3 split with `ignore_merges`: a piece that
//! is already a vocabulary token is emitted whole, otherwise it goes through
//! ranked BPE. Encoding first partitions the text on special tokens (control
//! tokens only when requested, user-defined tokens always), then splits each
//! plain fragment exactly like llama.cpp's unicode_regex_split_custom_llama3
//! using the generated Unicode classes. The chat template renders the text
//! parts of the GGUF's Jinja template; the BOS appears there as text.
//!
//! Known divergence: llama.cpp replaces invalid UTF-8 bytes with U+FFFD before
//! splitting; this codec keeps the raw bytes. Valid UTF-8 tokenizes identically.

const mem = @import("sig_mem");
const gguf = @import("gguf");
const bpe = @import("tokenizer");
const unicode = @import("unicode_class");

pub const Error = bpe.Error || error{
    MissingTokenTypes,
    InvalidTokenTypes,
    SpecialCapacity,
    StorageFailure,
    TemplateCapacity,
};

pub const MAX_SPECIAL_TOKENS: usize = 512;
pub const MAX_SPECIAL_BYTES: usize = 48;

const TOKEN_TYPE_CONTROL: u32 = 3;
const TOKEN_TYPE_USER_DEFINED: u32 = 4;

/// Control and user-defined tokens with their text, longest first (the order
/// of llama.cpp's special-token cache).
pub const SpecialTokens = struct {
    ids: [MAX_SPECIAL_TOKENS]u32 = @splat(0),
    lengths: [MAX_SPECIAL_TOKENS]u8 = @splat(0),
    control: [MAX_SPECIAL_TOKENS]bool = @splat(false),
    text: [MAX_SPECIAL_TOKENS][MAX_SPECIAL_BYTES]u8 = @splat(@splat(0)),
    count: usize = 0,

    pub fn build(self: *SpecialTokens, source: gguf.Source, token_types: gguf.ArrayRef, vocabulary: anytype) Error!void {
        self.* = .{};
        if (!token_types.present) return error.MissingTokenTypes;
        if ((token_types.element_type != 4 and token_types.element_type != 5) or token_types.count != vocabulary.count)
            return error.InvalidTokenTypes;
        var token: u32 = 0;
        while (token < token_types.count) : (token += 1) {
            var raw: [4]u8 = undefined;
            if (!source.read(token_types.data_offset + @as(u64, token) * 4, &raw)) return error.StorageFailure;
            const kind = mem.readInt(u32, &raw, .little);
            if (kind != TOKEN_TYPE_CONTROL and kind != TOKEN_TYPE_USER_DEFINED) continue;
            if (self.count == MAX_SPECIAL_TOKENS) return error.SpecialCapacity;
            const length = try vocabulary.tokenLength(token);
            if (length == 0 or length > MAX_SPECIAL_BYTES) return error.SpecialCapacity;
            _ = try vocabulary.copyToken(source, token, &self.text[self.count]);
            self.ids[self.count] = token;
            self.lengths[self.count] = @intCast(length);
            self.control[self.count] = kind == TOKEN_TYPE_CONTROL;
            self.count += 1;
        }
        // Insertion sort by descending length keeps equal lengths in id order.
        var sorted: usize = 1;
        while (sorted < self.count) : (sorted += 1) {
            var position = sorted;
            while (position > 0 and self.lengths[position - 1] < self.lengths[position]) : (position -= 1) {
                inline for (.{ "ids", "lengths", "control", "text" }) |field| {
                    const saved = @field(self, field)[position];
                    @field(self, field)[position] = @field(self, field)[position - 1];
                    @field(self, field)[position - 1] = saved;
                }
            }
        }
    }

    /// The longest special token spelled at the start of `text`.
    pub fn match(self: *const SpecialTokens, text: []const u8, parse_control: bool) ?Match {
        for (0..self.count) |entry| {
            if (self.control[entry] and !parse_control) continue;
            const length = self.lengths[entry];
            if (length <= text.len and mem.eql(u8, text[0..length], self.text[entry][0..length]))
                return .{ .token = self.ids[entry], .length = length };
        }
        return null;
    }

    pub fn isControl(self: *const SpecialTokens, token: u32) bool {
        for (self.ids[0..self.count], self.control[0..self.count]) |id, control| if (id == token) return control;
        return false;
    }
};

pub const Match = struct { token: u32, length: usize };

/// Encode `text` into `tokens`, returning the count. With `parse_control` the
/// control tokens spelled in the text (as the chat template produces) become
/// their ids; user-defined tokens such as `<tool_call>` are always parsed.
pub fn encode(
    source: gguf.Source,
    vocabulary: anytype,
    merges: anytype,
    specials: *const SpecialTokens,
    text: []const u8,
    parse_control: bool,
    tokens: []u32,
) Error!usize {
    var count: usize = 0;
    var fragment: usize = 0;
    var position: usize = 0;
    while (position < text.len) {
        if (specials.match(text[position..], parse_control)) |special| {
            count = try encodePlain(source, vocabulary, merges, text[fragment..position], tokens, count);
            if (count == tokens.len) return error.TokenCapacity;
            tokens[count] = special.token;
            count += 1;
            position += special.length;
            fragment = position;
        } else position += 1;
    }
    return encodePlain(source, vocabulary, merges, text[fragment..], tokens, count);
}

fn encodePlain(source: gguf.Source, vocabulary: anytype, merges: anytype, text: []const u8, tokens: []u32, initial: usize) Error!usize {
    var count = initial;
    var position: usize = 0;
    var encoded: [1024]u8 = undefined;
    while (position < text.len) {
        const length = nextPiece(text[position..]);
        const piece = text[position..][0..length];
        position += length;
        if (piece.len * 2 <= encoded.len) {
            var written: usize = 0;
            for (piece) |byte| {
                var spelled: [2]u8 = undefined;
                const size = bpe.encodeByte(byte, &spelled);
                @memcpy(encoded[written..][0..size], spelled[0..size]);
                written += size;
            }
            if (vocabulary.lookup(source, encoded[0..written])) |whole| {
                if (count == tokens.len) return error.TokenCapacity;
                tokens[count] = whole;
                count += 1;
                continue;
            }
        }
        count = try bpe.encodePiece(source, vocabulary, merges, piece, tokens, count);
    }
    return count;
}

/// Byte length of the first LLAMA3 pre-token of non-empty `text`:
/// (?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\r\n\p{L}\p{N}]?\p{L}+|
/// \p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+
pub fn nextPiece(text: []const u8) usize {
    const first = scalarAt(text, 0) orelse return 0;
    const second = scalarAt(text, first.length);

    if (first.value == '\'' and second != null) {
        const next = second.?;
        const lower = asciiLower(next.value);
        if (lower == 's' or lower == 't' or lower == 'm' or lower == 'd') return first.length + next.length;
        if (scalarAt(text, first.length + next.length)) |third| {
            const lower_third = asciiLower(third.value);
            if ((lower == 'r' and lower_third == 'e') or (lower == 'v' and lower_third == 'e') or
                (lower == 'l' and lower_third == 'l')) return first.length + next.length + third.length;
        }
    }

    const kind = classOf(first);
    if (!(first.value == '\r' or first.value == '\n' or kind == .number)) {
        if (kind == .letter or (second != null and classOf(second.?) == .letter)) {
            var end = first.length;
            while (scalarAt(text, end)) |scalar| {
                if (classOf(scalar) != .letter) break;
                end += scalar.length;
            }
            return end;
        }
    }

    if (kind == .number) {
        var end: usize = 0;
        var digits: usize = 0;
        while (digits < 3) : (digits += 1) {
            const scalar = scalarAt(text, end) orelse break;
            if (classOf(scalar) != .number) break;
            end += scalar.length;
        }
        return end;
    }

    // ` ?[^\s\p{L}\p{N}]+[\r\n]*`: the optional space only joins symbols.
    const symbol_start: ?Scalar = if (first.value == ' ') second else first;
    const starts_symbols = if (symbol_start) |scalar| classOf(scalar) == .other and !unicode.isWhitespace(scalar.value) else first.value == ' ';
    if (starts_symbols) {
        var end: usize = if (first.value == ' ') first.length else 0;
        while (scalarAt(text, end)) |scalar| {
            if (unicode.isWhitespace(scalar.value) or classOf(scalar) != .other) break;
            end += scalar.length;
        }
        while (end < text.len and (text[end] == '\r' or text[end] == '\n')) end += 1;
        return end;
    }

    var end: usize = 0;
    var spaces: usize = 0;
    var last_line_end: usize = 0;
    var before_last: usize = 0;
    while (scalarAt(text, end)) |scalar| {
        if (!unicode.isWhitespace(scalar.value)) break;
        before_last = end;
        end += scalar.length;
        spaces += 1;
        if (scalar.value == '\r' or scalar.value == '\n') last_line_end = end;
    }
    if (last_line_end > 0) return last_line_end; // \s*[\r\n]+
    if (spaces > 1 and end < text.len) return before_last; // \s+(?!\S)
    if (spaces > 0) return end; // \s+
    return first.length;
}

const Scalar = struct { value: u32, length: usize };

/// One UTF-8 scalar at `offset`. Malformed bytes decode as themselves with a
/// length of one, so splitting always advances.
fn scalarAt(text: []const u8, offset: usize) ?Scalar {
    if (offset >= text.len) return null;
    const lead = text[offset];
    if (lead < 0x80) return .{ .value = lead, .length = 1 };
    const length: usize = if (lead >= 0xf0 and lead < 0xf8) 4 else if (lead >= 0xe0) 3 else if (lead >= 0xc2 and lead < 0xe0) 2 else 0;
    if (length == 0 or length > text.len - offset) return .{ .value = 0x110000 | @as(u32, lead), .length = 1 };
    var value: u32 = @as(u32, lead) & (@as(u32, 0x7f) >> @intCast(length));
    for (text[offset + 1 .. offset + length]) |byte| {
        if (byte & 0xc0 != 0x80) return .{ .value = 0x110000 | @as(u32, lead), .length = 1 };
        value = (value << 6) | (byte & 0x3f);
    }
    return .{ .value = value, .length = length };
}

fn classOf(scalar: Scalar) unicode.Class {
    return unicode.classify(scalar.value);
}

fn asciiLower(value: u32) u32 {
    return if (value >= 'A' and value <= 'Z') value + 32 else value;
}

pub const DecodedToken = bpe.DecodedToken;

/// Decode one token to UTF-8. Control tokens produce no bytes and report
/// `control`; user-defined tokens decode to their text.
pub fn decode(
    source: gguf.Source,
    vocabulary: anytype,
    specials: *const SpecialTokens,
    token: u32,
    scratch: []u8,
    destination: []u8,
) Error!DecodedToken {
    if (specials.isControl(token)) return .{ .bytes_written = 0, .control = true };
    return bpe.decodeToken(source, vocabulary, token, scratch, destination);
}

// ── Chat template ──

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ChatOptions = struct {
    /// Tool definitions, each already rendered as the template's JSON object
    /// line, e.g. {"name": "get_time", "description": "...", "parameters": {...}}.
    tools: []const []const u8 = &.{},
    add_generation_prompt: bool = true,
};

/// Render the string-content subset of LFM3's chat template into `output`
/// and return its length. Encode the result with `parse_control = true`.
pub fn renderChat(messages: []const Message, options: ChatOptions, output: []u8) Error!usize {
    var writer = Writer{ .buffer = output };
    try writer.put("<|startoftext|>");
    var rest = messages;
    var system: []const u8 = "";
    if (rest.len != 0 and rest[0].role == .system) {
        system = rest[0].content;
        rest = rest[1..];
    }
    if (system.len != 0 or options.tools.len != 0) {
        try writer.put("<|im_start|>system\n");
        try writer.put(system);
        if (options.tools.len != 0) {
            if (system.len != 0) try writer.put("\n\n");
            try writer.put("<tools>\n");
            for (options.tools, 0..) |tool, tool_index| {
                if (tool_index != 0) try writer.put("\n");
                try writer.put(tool);
            }
            try writer.put("\n</tools>");
        }
        try writer.put("<|im_end|>\n");
    }
    var last_user: ?usize = null;
    for (rest, 0..) |message, message_index| {
        if (message.role == .user) last_user = message_index;
    }
    for (rest, 0..) |message, message_index| {
        try writer.put("<|im_start|>");
        try writer.put(@tagName(message.role));
        try writer.put("\n");
        switch (message.role) {
            .assistant => {
                const keep_thinking = if (last_user) |user| message_index > user else true;
                var content = message.content;
                if (!keep_thinking) {
                    if (lastIndexOf(content, "</think>")) |at| content = trim(content[at + "</think>".len ..]);
                }
                try writer.put(content);
            },
            .tool => if (message.content.len != 0) {
                if (indexOf(message.content, "<tool_response>") != null) {
                    try writer.put(message.content);
                } else {
                    try writer.put("<tool_response>\n");
                    try writer.put(message.content);
                    try writer.put("\n</tool_response>");
                }
            },
            .system, .user => try writer.put(message.content),
        }
        try writer.put("<|im_end|>\n");
    }
    if (options.add_generation_prompt) try writer.put("<|im_start|>assistant\n");
    return writer.length;
}

const Writer = struct {
    buffer: []u8,
    length: usize = 0,

    fn put(self: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > self.buffer.len - self.length) return error.TemplateCapacity;
        @memcpy(self.buffer[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
};

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var position: usize = 0;
    while (position + needle.len <= haystack.len) : (position += 1) {
        if (mem.eql(u8, haystack[position..][0..needle.len], needle)) return position;
    }
    return null;
}

fn lastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var position = haystack.len - needle.len + 1;
    while (position > 0) {
        position -= 1;
        if (mem.eql(u8, haystack[position..][0..needle.len], needle)) return position;
    }
    return null;
}

/// Jinja `trim`: strip ASCII whitespace from both ends.
fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isAsciiSpace(text[start])) start += 1;
    while (end > start and isAsciiSpace(text[end - 1])) end -= 1;
    return text[start..end];
}

fn isAsciiSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}
