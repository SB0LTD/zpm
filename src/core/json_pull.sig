//! JSON without allocation: a pull tokenizer that reports byte offsets (so
//! callers can slice raw values out and echo them back verbatim), value
//! skipping, full string unescaping (including \u surrogate pairs → UTF-8),
//! and a fixed-buffer writer with correct escaping and automatic commas.
//! Layer 0: pure computation, freestanding.
//!
//! Reader: `next()` yields structural tokens, strings (offsets exclude the
//! quotes; the raw text may contain escapes), numbers and literals, and skips
//! whitespace, ':' and ','. Inside an object, tokens alternate key, value.

pub const Kind = enum { begin_object, end_object, begin_array, end_array, string, number, true_, false_, null_, end, err };

pub const Token = struct {
    kind: Kind,
    /// Byte range in the source. For strings: the contents between the
    /// quotes (still escaped). For containers: the bracket itself.
    start: usize,
    end: usize,
};

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Reader {
        return .{ .src = src };
    }

    fn skipSpace(r: *Reader) void {
        while (r.pos < r.src.len) : (r.pos += 1) {
            switch (r.src[r.pos]) {
                ' ', '\t', '\r', '\n', ':', ',' => {},
                else => return,
            }
        }
    }

    pub fn next(r: *Reader) Token {
        r.skipSpace();
        if (r.pos >= r.src.len) return .{ .kind = .end, .start = r.pos, .end = r.pos };
        const c = r.src[r.pos];
        const at = r.pos;
        switch (c) {
            '{' => {
                r.pos += 1;
                return .{ .kind = .begin_object, .start = at, .end = at + 1 };
            },
            '}' => {
                r.pos += 1;
                return .{ .kind = .end_object, .start = at, .end = at + 1 };
            },
            '[' => {
                r.pos += 1;
                return .{ .kind = .begin_array, .start = at, .end = at + 1 };
            },
            ']' => {
                r.pos += 1;
                return .{ .kind = .end_array, .start = at, .end = at + 1 };
            },
            '"' => {
                var i = at + 1;
                while (i < r.src.len) : (i += 1) {
                    if (r.src[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (r.src[i] == '"') break;
                }
                if (i >= r.src.len) {
                    r.pos = r.src.len;
                    return .{ .kind = .err, .start = at, .end = r.src.len };
                }
                r.pos = i + 1;
                return .{ .kind = .string, .start = at + 1, .end = i };
            },
            't', 'f', 'n' => {
                const lit: []const u8 = if (c == 't') "true" else if (c == 'f') "false" else "null";
                if (at + lit.len <= r.src.len and eql(r.src[at..][0..lit.len], lit)) {
                    r.pos = at + lit.len;
                    return .{ .kind = if (c == 't') .true_ else if (c == 'f') .false_ else .null_, .start = at, .end = r.pos };
                }
                r.pos = r.src.len;
                return .{ .kind = .err, .start = at, .end = at };
            },
            '-', '0'...'9' => {
                var i = at + 1;
                while (i < r.src.len) : (i += 1) {
                    switch (r.src[i]) {
                        '0'...'9', '.', 'e', 'E', '+', '-' => {},
                        else => break,
                    }
                }
                r.pos = i;
                return .{ .kind = .number, .start = at, .end = i };
            },
            else => {
                r.pos = r.src.len;
                return .{ .kind = .err, .start = at, .end = at };
            },
        }
    }

    /// Skip the rest of the value that `first` began. Returns the byte just
    /// past it (so `src[first.start..end]` is the raw value for containers;
    /// for strings use the quote-inclusive `first.start - 1 .. end`).
    pub fn skip(r: *Reader, first: Token) ?usize {
        switch (first.kind) {
            .begin_object, .begin_array => {
                var depth: usize = 1;
                while (depth > 0) {
                    const t = r.next();
                    switch (t.kind) {
                        .begin_object, .begin_array => depth += 1,
                        .end_object, .end_array => depth -= 1,
                        .end, .err => return null,
                        else => {},
                    }
                }
                return r.pos;
            },
            .string => return first.end + 1,
            .end_object, .end_array, .end, .err => return null,
            else => return first.end,
        }
    }

    /// Raw source of a value token (strings include their quotes).
    pub fn raw(r: *Reader, first: Token) ?[]const u8 {
        const end = r.skip(first) orelse return null;
        const start = if (first.kind == .string) first.start - 1 else first.start;
        return r.src[start..end];
    }

    /// Inside an object (just after begin_object): advance to the value of
    /// `key`, returning its first token; other members are skipped. The
    /// reader ends positioned after that token.
    pub fn findKey(r: *Reader, key: []const u8) ?Token {
        while (true) {
            const k = r.next();
            if (k.kind != .string) return null;
            const v = r.next();
            if (eql(r.src[k.start..k.end], key)) return v;
            _ = r.skip(v) orelse return null;
        }
    }

    pub fn str(r: *const Reader, t: Token) []const u8 {
        return r.src[t.start..t.end];
    }
};

/// Decode a raw (escaped) JSON string into `out`. Returns the UTF-8 bytes,
/// or null if the escape syntax is invalid or `out` is too small.
pub fn unescape(raw_text: []const u8, out: []u8) ?[]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw_text.len) {
        const c = raw_text[i];
        if (c != '\\') {
            if (n >= out.len) return null;
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= raw_text.len) return null;
        const e = raw_text[i + 1];
        i += 2;
        const simple: ?u8 = switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => null,
        };
        if (simple) |ch| {
            if (n >= out.len) return null;
            out[n] = ch;
            n += 1;
            continue;
        }
        if (e != 'u') return null;
        var cp: u32 = hex4(raw_text, i) orelse return null;
        i += 4;
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            // High surrogate: must pair with \uDC00..\uDFFF.
            if (i + 6 > raw_text.len or raw_text[i] != '\\' or raw_text[i + 1] != 'u') return null;
            const lo = hex4(raw_text, i + 2) orelse return null;
            if (lo < 0xDC00 or lo > 0xDFFF) return null;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            i += 6;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) return null;
        const len = utf8Len(cp);
        if (n + len > out.len) return null;
        encodeUtf8(cp, out[n..][0..len]);
        n += len;
    }
    return out[0..n];
}

fn hex4(s: []const u8, at: usize) ?u32 {
    if (at + 4 > s.len) return null;
    var v: u32 = 0;
    for (s[at..][0..4]) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = v * 16 + d;
    }
    return v;
}

fn utf8Len(cp: u32) usize {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

fn encodeUtf8(cp: u32, out: []u8) void {
    switch (out.len) {
        1 => out[0] = @intCast(cp),
        2 => {
            out[0] = @intCast(0xC0 | (cp >> 6));
            out[1] = @intCast(0x80 | (cp & 0x3F));
        },
        3 => {
            out[0] = @intCast(0xE0 | (cp >> 12));
            out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[2] = @intCast(0x80 | (cp & 0x3F));
        },
        else => {
            out[0] = @intCast(0xF0 | (cp >> 18));
            out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[3] = @intCast(0x80 | (cp & 0x3F));
        },
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// ── Writer ──────────────────────────────────────────────────────────────────

/// Builds JSON into a caller buffer. Commas are inserted automatically;
/// `overflow` latches if anything did not fit (check it before sending).
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,
    /// Per nesting level: a value has been written at this level.
    written: [32]bool = [_]bool{false} ** 32,
    depth: u8 = 0,
    after_key: bool = false,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }

    fn put(w: *Writer, s: []const u8) void {
        if (w.len + s.len > w.buf.len) {
            w.overflow = true;
            return;
        }
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
    }

    fn putByte(w: *Writer, c: u8) void {
        if (w.len >= w.buf.len) {
            w.overflow = true;
            return;
        }
        w.buf[w.len] = c;
        w.len += 1;
    }

    /// Separator before a value (or key) at the current level.
    fn sep(w: *Writer) void {
        if (w.after_key) {
            w.after_key = false;
            return;
        }
        if (w.written[w.depth]) w.putByte(',');
        w.written[w.depth] = true;
    }

    fn open(w: *Writer, c: u8) void {
        w.sep();
        w.putByte(c);
        if (w.depth + 1 >= w.written.len) {
            w.overflow = true;
            return;
        }
        w.depth += 1;
        w.written[w.depth] = false;
    }

    fn close(w: *Writer, c: u8) void {
        w.putByte(c);
        if (w.depth > 0) w.depth -= 1;
    }

    pub fn beginObject(w: *Writer) void {
        w.open('{');
    }
    pub fn endObject(w: *Writer) void {
        w.close('}');
    }
    pub fn beginArray(w: *Writer) void {
        w.open('[');
    }
    pub fn endArray(w: *Writer) void {
        w.close(']');
    }

    pub fn key(w: *Writer, k: []const u8) void {
        w.sep();
        w.quoted(k);
        w.putByte(':');
        w.after_key = true;
    }

    pub fn string(w: *Writer, s: []const u8) void {
        w.sep();
        w.quoted(s);
    }

    pub fn int(w: *Writer, v: i64) void {
        w.sep();
        var tmp: [24]u8 = undefined;
        var n: usize = 0;
        var x: u64 = if (v < 0) @intCast(-(v + 1)) else @intCast(v);
        if (v < 0) x += 1;
        if (x == 0) {
            tmp[0] = '0';
            n = 1;
        }
        while (x > 0) : (x /= 10) {
            tmp[n] = @intCast('0' + x % 10);
            n += 1;
        }
        if (v < 0) w.putByte('-');
        while (n > 0) {
            n -= 1;
            w.putByte(tmp[n]);
        }
    }

    pub fn boolean(w: *Writer, b: bool) void {
        w.sep();
        w.put(if (b) "true" else "false");
    }

    pub fn null_(w: *Writer) void {
        w.sep();
        w.put("null");
    }

    /// Insert pre-built JSON as a value (e.g. an echoed functionCall part).
    pub fn raw(w: *Writer, json: []const u8) void {
        w.sep();
        w.put(json);
    }

    /// Shorthand: "k": "v".
    pub fn field(w: *Writer, k: []const u8, v: []const u8) void {
        w.key(k);
        w.string(v);
    }

    fn quoted(w: *Writer, s: []const u8) void {
        w.putByte('"');
        for (s) |c| {
            switch (c) {
                '"' => w.put("\\\""),
                '\\' => w.put("\\\\"),
                '\n' => w.put("\\n"),
                '\r' => w.put("\\r"),
                '\t' => w.put("\\t"),
                0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    const hexd = "0123456789abcdef";
                    w.put("\\u00");
                    w.putByte(hexd[c >> 4]);
                    w.putByte(hexd[c & 0xf]);
                },
                else => w.putByte(c),
            }
        }
        w.putByte('"');
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "json_pull: walk a Gemini stream chunk, slice a functionCall part raw" {
    const chunk =
        \\{"candidates": [{"content": {"parts": [{"text": "Hi \"Ari\" — ok\n"},
        \\ {"functionCall": {"name": "show_card", "args": {"title": "Zoom", "n": 2}}, "thoughtSignature": "abc=="}],
        \\ "role": "model"}, "finishReason": "STOP"}], "usageMetadata": {"totalTokenCount": 42}}
    ;
    var r = Reader.init(chunk);
    try testing.expectEqual(Kind.begin_object, r.next().kind);
    const cands = r.findKey("candidates") orelse return error.NoCandidates;
    try testing.expectEqual(Kind.begin_array, cands.kind);
    try testing.expectEqual(Kind.begin_object, r.next().kind);
    try testing.expectEqual(Kind.begin_object, (r.findKey("content") orelse return error.NoContent).kind);
    try testing.expectEqual(Kind.begin_array, (r.findKey("parts") orelse return error.NoParts).kind);

    // Part 1: text with escapes.
    try testing.expectEqual(Kind.begin_object, r.next().kind);
    const txt = r.findKey("text") orelse return error.NoText;
    var buf: [64]u8 = undefined;
    const decoded = unescape(r.str(txt), &buf) orelse return error.Bad;
    try testing.expectEqualStrings("Hi \"Ari\" \u{2014} ok\n", decoded);
    try testing.expectEqual(Kind.end_object, r.next().kind);

    // Part 2: the whole part, raw, for echoing back.
    const part = r.next();
    try testing.expectEqual(Kind.begin_object, part.kind);
    const raw_part = r.raw(part) orelse return error.Bad;
    try testing.expect(raw_part[0] == '{' and raw_part[raw_part.len - 1] == '}');
    var inner = Reader.init(raw_part);
    _ = inner.next();
    const fc = inner.findKey("functionCall") orelse return error.NoCall;
    try testing.expectEqual(Kind.begin_object, fc.kind);
    const name = inner.findKey("name") orelse return error.NoName;
    try testing.expectEqualStrings("show_card", inner.str(name));
}

test "json_pull: surrogate pairs and invalid escapes" {
    var buf: [16]u8 = undefined;
    const emoji = unescape("\\ud83d\\udc4b", &buf) orelse return error.Bad;
    try testing.expectEqualStrings("\u{1F44B}", emoji);
    try testing.expect(unescape("\\ud83d", &buf) == null); // lone high surrogate
    try testing.expect(unescape("\\x41", &buf) == null);
    try testing.expect(unescape("abcdefghijklmnopq", &buf) == null); // too long
}

test "json_pull: writer escapes and places commas" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    w.beginObject();
    w.field("text", "say \"hi\"\n\tok");
    w.key("n");
    w.int(-42);
    w.key("list");
    w.beginArray();
    w.int(1);
    w.boolean(true);
    w.raw("{\"a\":1}");
    w.endArray();
    w.endObject();
    try testing.expect(!w.overflow);
    try testing.expectEqualStrings("{\"text\":\"say \\\"hi\\\"\\n\\tok\",\"n\":-42,\"list\":[1,true,{\"a\":1}]}", w.bytes());
    // Round trip through the reader.
    var r = Reader.init(w.bytes());
    _ = r.next();
    const t = r.findKey("text") orelse return error.Bad;
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("say \"hi\"\n\tok", unescape(r.str(t), &out) orelse return error.Bad);
    var small: [4]u8 = undefined;
    var w2 = Writer.init(&small);
    w2.field("toolong", "x");
    try testing.expect(w2.overflow);
}
