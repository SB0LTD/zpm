const std = @import("std");
pub const Kind = enum { begin_object, end_object, begin_array, end_array, string, number, true_, false_, null_, end, err };
pub const Token = struct { kind: Kind, start: usize, end: usize };
pub const Reader = struct {
    buf: []const u8, pos: usize = 0,
    pub fn init(buf: []const u8) Reader { return .{ .buf = buf }; }
    fn ws(r: *Reader) void { while (r.pos < r.buf.len and std.mem.indexOfScalar(u8, " \n\r\t", r.buf[r.pos]) != null) : (r.pos += 1) {} }
    fn literal(r: *Reader, at: usize, s: []const u8, kind: Kind) Token {
        if (r.buf.len - r.pos < s.len or !std.mem.eql(u8, r.buf[r.pos..][0..s.len], s)) { r.pos += 1; return .{ .kind = .err, .start = at, .end = r.pos }; }
        r.pos += s.len; return .{ .kind = kind, .start = at, .end = r.pos };
    }
    pub fn next(r: *Reader) Token {
        r.ws(); if (r.pos == r.buf.len) return .{ .kind = .end, .start = r.pos, .end = r.pos };
        const at = r.pos;
        switch (r.buf[r.pos]) {
            '{' => { r.pos += 1; return .{ .kind = .begin_object, .start = at, .end = r.pos }; },
            '}' => { r.pos += 1; return .{ .kind = .end_object, .start = at, .end = r.pos }; },
            '[' => { r.pos += 1; return .{ .kind = .begin_array, .start = at, .end = r.pos }; },
            ']' => { r.pos += 1; return .{ .kind = .end_array, .start = at, .end = r.pos }; },
            ',', ':' => { r.pos += 1; return r.next(); },
            '"' => {
                r.pos += 1;
                while (r.pos < r.buf.len) : (r.pos += 1) {
                    const c = r.buf[r.pos];
                    if (c == '"') { r.pos += 1; return .{ .kind = .string, .start = at, .end = r.pos }; }
                    if (c == '\\') { r.pos += 1; if (r.pos == r.buf.len) break; }
                    else if (c < 0x20) return .{ .kind = .err, .start = at, .end = r.pos };
                }
                return .{ .kind = .err, .start = at, .end = r.pos };
            },
            't' => return r.literal(at, "true", .true_), 'f' => return r.literal(at, "false", .false_), 'n' => return r.literal(at, "null", .null_),
            else => {},
        }
        const c = r.buf[r.pos];
        if (c == '-' or std.ascii.isDigit(c)) {
            r.pos += 1;
            while (r.pos < r.buf.len and (std.ascii.isAlphanumeric(r.buf[r.pos]) or std.mem.indexOfScalar(u8, "+-.", r.buf[r.pos]) != null)) : (r.pos += 1) {}
            return .{ .kind = .number, .start = at, .end = r.pos };
        }
        r.pos += 1; return .{ .kind = .err, .start = at, .end = r.pos };
    }
    pub fn str(r: *const Reader, t: Token) []const u8 { if (t.kind != .string or t.end < t.start + 2) return ""; return r.buf[t.start + 1 .. t.end - 1]; }
    pub fn skip(r: *Reader, t: Token) ?usize {
        if (t.kind == .err or t.kind == .end) return null;
        if (t.kind != .begin_object and t.kind != .begin_array) return t.end;
        var depth: usize = 1;
        while (depth > 0) { const n = r.next(); switch (n.kind) {
            .begin_object, .begin_array => depth += 1, .end_object, .end_array => depth -= 1, .end, .err => return null, else => {},
        } }
        return r.pos;
    }
    pub fn raw(r: *Reader, t: Token) ?[]const u8 { const end = r.skip(t) orelse return null; return r.buf[t.start..end]; }
    pub fn findKey(r: *Reader, wanted: []const u8) ?Token {
        while (true) { const k = r.next(); if (k.kind != .string) return null; const v = r.next(); if (v.kind == .err or v.kind == .end) return null;
            if (std.mem.eql(u8, r.str(k), wanted)) return v;
            _ = r.skip(v) orelse return null;
        }
    }
};
pub fn unescape(src: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0; var n: usize = 0;
    while (i < src.len) {
        if (src[i] >= 0x80) {
            const width = std.unicode.utf8ByteSequenceLength(src[i]) catch return null;
            if (i + width > src.len) return null;
            _ = std.unicode.utf8Decode(src[i..][0..width]) catch return null;
            if (n + width > out.len) return null;
            @memcpy(out[n..][0..width], src[i..][0..width]);
            n += width; i += width; continue;
        }
        if (src[i] < 0x20) return null;
        var cp: u21 = src[i];
        if (src[i] == '\\') {
            i += 1; if (i >= src.len) return null;
            switch (src[i]) {
                '"', '\\', '/' => cp = src[i], 'b' => cp = 8, 'f' => cp = 12, 'n' => cp = 10, 'r' => cp = 13, 't' => cp = 9,
                'u' => {
                    if (i + 4 >= src.len) return null;
                    cp = 0; for (1..5) |j| cp = cp * 16 + (std.fmt.charToDigit(src[i + j], 16) catch return null);
                    i += 4;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (i + 6 >= src.len or src[i + 1] != '\\' or src[i + 2] != 'u') return null;
                        var low: u21 = 0; for (3..7) |j| low = low * 16 + (std.fmt.charToDigit(src[i + j], 16) catch return null);
                        if (low < 0xDC00 or low > 0xDFFF) return null;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + low - 0xDC00; i += 6;
                    } else if (cp >= 0xDC00 and cp <= 0xDFFF) return null;
                }, else => return null,
            }
        }
        var encoded: [4]u8 = undefined; const len = std.unicode.utf8Encode(cp, &encoded) catch return null;
        if (n + len > out.len) return null;
        @memcpy(out[n..][0..len], encoded[0..len]); n += len; i += 1;
    }
    return out[0..n];
}
const Frame = struct { kind: Kind, first: bool = true, need_value: bool = false };
pub const Writer = struct {
    out: []u8, len: usize = 0, overflow: bool = false, stack: [32]Frame = undefined, depth: usize = 0,
    pub fn init(out: []u8) Writer { return .{ .out = out }; }
    pub fn bytes(w: *const Writer) []const u8 { return w.out[0..w.len]; }
    fn put(w: *Writer, b: u8) void { if (w.len == w.out.len) { w.overflow = true; return; } w.out[w.len] = b; w.len += 1; }
    fn append(w: *Writer, s: []const u8) void { for (s) |b| w.put(b); }
    fn before(w: *Writer) void {
        if (w.depth == 0) return;
        const f = &w.stack[w.depth - 1];
        if (f.kind == .begin_array) { if (!f.first) w.put(','); f.first = false; }
        else { if (!f.need_value) { w.overflow = true; return; } f.need_value = false; }
    }
    fn valueDone(w: *Writer) void { if (w.depth > 0 and w.stack[w.depth - 1].kind == .begin_object) w.stack[w.depth - 1].need_value = false; }
    fn quoted(w: *Writer, s: []const u8) void {
        w.put('"'); for (s) |c| switch (c) {
            '"' => w.append("\\\""), '\\' => w.append("\\\\"), '\n' => w.append("\\n"), '\r' => w.append("\\r"), '\t' => w.append("\\t"),
            0...8, 11, 14...0x1f => { const hex = "0123456789abcdef"; w.append("\\u00"); w.put(hex[c >> 4]); w.put(hex[c & 15]); }, else => w.put(c),
        }; w.put('"');
    }
    pub fn beginObject(w: *Writer) void { w.before(); w.put('{'); if (w.depth == w.stack.len) { w.overflow = true; return; } w.stack[w.depth] = .{ .kind = .begin_object }; w.depth += 1; }
    pub fn endObject(w: *Writer) void { if (w.depth == 0 or w.stack[w.depth - 1].kind != .begin_object or w.stack[w.depth - 1].need_value) { w.overflow = true; return; } w.depth -= 1; w.put('}'); w.valueDone(); }
    pub fn beginArray(w: *Writer) void { w.before(); w.put('['); if (w.depth == w.stack.len) { w.overflow = true; return; } w.stack[w.depth] = .{ .kind = .begin_array }; w.depth += 1; }
    pub fn endArray(w: *Writer) void { if (w.depth == 0 or w.stack[w.depth - 1].kind != .begin_array) { w.overflow = true; return; } w.depth -= 1; w.put(']'); w.valueDone(); }
    pub fn key(w: *Writer, k: []const u8) void { if (w.depth == 0 or w.stack[w.depth - 1].kind != .begin_object or w.stack[w.depth - 1].need_value) { w.overflow = true; return; } const f = &w.stack[w.depth - 1]; if (!f.first) w.put(','); f.first = false; w.quoted(k); w.put(':'); f.need_value = true; }
    pub fn string(w: *Writer, s: []const u8) void { w.before(); w.quoted(s); w.valueDone(); }
    pub fn field(w: *Writer, k: []const u8, v: []const u8) void { w.key(k); w.quoted(v); w.valueDone(); }
    pub fn boolean(w: *Writer, v: bool) void { w.before(); w.append(if (v) "true" else "false"); w.valueDone(); }
    pub fn int(w: *Writer, v: i128) void { w.before(); w.print("{d}", .{v}) catch {}; w.valueDone(); }
    pub fn raw(w: *Writer, s: []const u8) void { w.before(); w.append(s); w.valueDone(); }
    pub fn writeAll(w: *Writer, s: []const u8) error{NoSpaceLeft}!void { w.append(s); if (w.overflow) return error.NoSpaceLeft; }
    pub fn print(w: *Writer, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!void { var tmp: [4096]u8 = undefined; const s = std.fmt.bufPrint(&tmp, fmt, args) catch return error.NoSpaceLeft; w.append(s); if (w.overflow) return error.NoSpaceLeft; }
};