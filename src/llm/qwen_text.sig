// Bounded Qwen2-profile codec for Hebrew/Aramaic and ASCII lesson prompts.
// Reuses ZPM's zero-copy GGUF indexes and BPE kernel. Unsupported scripts fail
// explicitly; this is not a complete Unicode category implementation.
const std = @import("std");
const gguf = @import("gguf");
const index = @import("tokenizer_index");
const bpe = @import("tokenizer");
pub const Error = gguf.Error || index.Error || bpe.Error || error{ InvalidUtf8, UnsupportedScript, UnsupportedProfile };

pub const Codec = struct {
    bytes: []const u8,
    model: gguf.Index(1024),
    vocabulary: index.VocabularyIndex(256000, 524288),
    merges: index.MergeIndex(524288, 512),
    fn readAt(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Codec = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start > self.bytes.len or destination.len > self.bytes.len - start) return false;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return true;
    }
    fn mapAt(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const self: *const Codec = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start > self.bytes.len or length > self.bytes.len - start) return null;
        const ptr = self.bytes[start..].ptr;
        if (@intFromPtr(ptr) % alignment != 0) return null;
        return ptr;
    }
    pub fn source(self: *const Codec) gguf.Source { return .{ .context = self, .size = self.bytes.len, .read_at = readAt, .map_at = mapAt }; }
    // Self must stay pinned while source() is borrowed.
    pub fn init(self: *Codec, bytes: []const u8) Error!void {
        self.bytes = bytes;
        try gguf.parse(1024, self.source(), &self.model);
        if (!std.mem.eql(u8, self.model.summary.architectureSlice(), "qwen3")) return error.UnsupportedProfile;
        if (!std.mem.eql(u8, self.model.summary.tokenizerPreSlice(), "qwen2")) return error.UnsupportedProfile;
        try self.vocabulary.build(self.source(), self.model.summary.tokenizer_tokens);
        try self.merges.build(self.source(), self.model.summary.tokenizer_merges, &self.vocabulary);
    }
    pub fn encodeText(self: *const Codec, text_value: []const u8, out: []u32) Error!usize {
        try validateText(text_value);
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < text_value.len) {
            const n = pieceLength(text_value[pos..]);
            count = try bpe.encodePiece(self.source(), &self.vocabulary, &self.merges, text_value[pos..][0..n], out, count);
            pos += n;
        }
        return count;
    }
    fn text(self: *const Codec, value: []const u8, out: []u32, count: *usize) Error!void { count.* += try self.encodeText(value, out[count.*..]); }
    fn special(self: *const Codec, value: []const u8, out: []u32, count: *usize) Error!void {
        if (count.* == out.len) return error.TokenCapacity;
        out[count.*] = self.vocabulary.lookup(self.source(), value) orelse return error.MissingSpecialToken;
        count.* += 1;
    }
    pub fn encodeChat(self: *const Codec, system: []const u8, user: []const u8, empty_think: bool, out: []u32) Error!usize {
        var count: usize = 0;
        if (system.len != 0) {
            try self.special("<|im_start|>", out, &count);
            try self.text("system\n", out, &count); try self.text(system, out, &count);
            try self.special("<|im_end|>", out, &count); try self.text("\n", out, &count);
        }
        try self.special("<|im_start|>", out, &count);
        try self.text("user\n", out, &count); try self.text(user, out, &count);
        try self.special("<|im_end|>", out, &count); try self.text("\n", out, &count);
        try self.special("<|im_start|>", out, &count); try self.text("assistant\n", out, &count);
        if (empty_think) {
            try self.special("<think>", out, &count); try self.text("\n\n", out, &count);
            try self.special("</think>", out, &count); try self.text("\n\n", out, &count);
        }
        return count;
    }
    pub fn decode(self: *const Codec, tokens: []const u32, out: []u8) Error!usize {
        var pos: usize = 0;
        var scratch: [512]u8 = undefined;
        for (tokens) |token| {
            const decoded = try bpe.decodeToken(self.source(), &self.vocabulary, token, &scratch, out[pos..]);
            pos += decoded.bytes_written;
        }
        return pos;
    }
};
const Scalar = struct { cp: u21, len: usize };
fn scalar(text_value: []const u8) Scalar {
    const len = std.unicode.utf8ByteSequenceLength(text_value[0]) catch unreachable;
    return .{ .cp = std.unicode.utf8Decode(text_value[0..len]) catch unreachable, .len = len };
}
fn letter(cp: u21) bool { return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or (cp >= 0x5d0 and cp <= 0x5ea) or (cp >= 0x5f0 and cp <= 0x5f2); }
fn digit(cp: u21) bool { return cp >= '0' and cp <= '9'; }
fn whitespace(cp: u21) bool { return (cp >= 9 and cp <= 13) or cp == 32 or cp == 0x85 or cp == 0xa0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000; }
fn newline(cp: u21) bool { return cp == '\r' or cp == '\n'; }
fn punctuation(cp: u21) bool { return !letter(cp) and !digit(cp) and !whitespace(cp); }
pub fn validateText(text_value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text_value)) return error.InvalidUtf8;
    var pos: usize = 0;
    while (pos < text_value.len) {
        const s = scalar(text_value[pos..]);
        if (!(s.cp <= 127 or (s.cp >= 0x590 and s.cp <= 0x5ff) or
            (s.cp >= 0x2000 and s.cp <= 0x206f) or whitespace(s.cp) or s.cp == 0xad)) return error.UnsupportedScript;
        pos += s.len;
    }
}
// Qwen2 alternatives for the admitted character set. Hebrew points are marks
// (not L), unlike the newer Qwen3.5 L+M pretokenizer profile.
pub fn pieceLength(text_value: []const u8) usize {
    if (text_value.len == 0) return 0;
    if (text_value.len >= 2 and text_value[0] == '\'') {
        const second = std.ascii.toLower(text_value[1]);
        if (second == 's' or second == 't' or second == 'm' or second == 'd') return 2;
        if (text_value.len >= 3) {
            const third = std.ascii.toLower(text_value[2]);
            if ((second == 'r' and third == 'e') or (second == 'v' and third == 'e') or (second == 'l' and third == 'l')) return 3;
        }
    }
    const first = scalar(text_value);
    var pos: usize = 0;
    if (!newline(first.cp) and !letter(first.cp) and !digit(first.cp) and first.len < text_value.len and letter(scalar(text_value[first.len..]).cp)) pos = first.len;
    while (pos < text_value.len and letter(scalar(text_value[pos..]).cp)) pos += scalar(text_value[pos..]).len;
    if (pos > 0) return pos;
    if (digit(first.cp)) return first.len;
    pos = if (first.cp == ' ' and first.len < text_value.len and punctuation(scalar(text_value[first.len..]).cp)) first.len else 0;
    while (pos < text_value.len and punctuation(scalar(text_value[pos..]).cp)) pos += scalar(text_value[pos..]).len;
    if (pos > 0) {
        while (pos < text_value.len and newline(scalar(text_value[pos..]).cp)) pos += scalar(text_value[pos..]).len;
        return pos;
    }
    var last_newline: usize = 0;
    pos = 0;
    var previous: usize = 0;
    while (pos < text_value.len and whitespace(scalar(text_value[pos..]).cp)) {
        previous = pos;
        const s = scalar(text_value[pos..]);
        pos += s.len;
        if (newline(s.cp)) last_newline = pos;
    }
    if (last_newline != 0) return last_newline;
    if (pos > 0) return if (pos < text_value.len and previous != 0) previous else pos;
    unreachable;
}
test "Hebrew Qwen2 spaces numbers contractions and points" {
    const cases = [_]struct { text: []const u8, piece: []const u8 }{
        .{ .text = " שלום עולם", .piece = " שלום" }, .{ .text = "?שלום", .piece = "?שלום" },
        .{ .text = "123", .piece = "1" }, .{ .text = "'RE hello", .piece = "'RE" },
        .{ .text = "  שלום", .piece = " " }, .{ .text = " \t\n  שלום", .piece = " \t\n" },
        .{ .text = "בְּרֵאשִׁית", .piece = "ב" }, .{ .text = "!?\r\nhello", .piece = "!?\r\n" },
    };
    for (cases) |c| { try validateText(c.text); try std.testing.expectEqualStrings(c.piece, c.text[0..pieceLength(c.text)]); }
    try std.testing.expectError(error.InvalidUtf8, validateText("\xff"));
    try std.testing.expectError(error.UnsupportedScript, validateText("α"));
}
