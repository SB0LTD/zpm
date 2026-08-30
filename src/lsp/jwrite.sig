//! Allocator-free JSON writer for LSP responses — Layer 0 (pure, no I/O).
//!
//! The zpm json module reads JSON; this writer emits it. It is a minimal
//! streaming writer over a caller-provided fixed buffer with correct string
//! escaping, reporting overflow via error rather than allocating. Callers frame
//! and write the resulting bytes.

const std = @import("std");

pub const WriteError = error{Overflow};

pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf, .len = 0 };
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    fn putByte(self: *Writer, c: u8) WriteError!void {
        if (self.len >= self.buf.len) return error.Overflow;
        self.buf[self.len] = c;
        self.len += 1;
    }

    pub fn raw(self: *Writer, s: []const u8) WriteError!void {
        if (self.len + s.len > self.buf.len) return error.Overflow;
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    pub fn string(self: *Writer, s: []const u8) WriteError!void {
        try self.putByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.raw("\\\""),
                '\\' => try self.raw("\\\\"),
                '\n' => try self.raw("\\n"),
                '\r' => try self.raw("\\r"),
                '\t' => try self.raw("\\t"),
                8 => try self.raw("\\b"),
                12 => try self.raw("\\f"),
                else => {
                    if (c < 0x20) {
                        try self.raw("\\u00");
                        const hex = "0123456789abcdef";
                        try self.putByte(hex[(c >> 4) & 0xF]);
                        try self.putByte(hex[c & 0xF]);
                    } else {
                        try self.putByte(c);
                    }
                },
            }
        }
        try self.putByte('"');
    }

    pub fn int(self: *Writer, value: i64) WriteError!void {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.Overflow;
        try self.raw(s);
    }

    pub fn boolean(self: *Writer, value: bool) WriteError!void {
        try self.raw(if (value) "true" else "false");
    }

    pub fn nullValue(self: *Writer) WriteError!void {
        try self.raw("null");
    }

    pub fn key(self: *Writer, name: []const u8) WriteError!void {
        try self.string(name);
        try self.putByte(':');
    }

    pub fn beginObject(self: *Writer) WriteError!void {
        try self.putByte('{');
    }
    pub fn endObject(self: *Writer) WriteError!void {
        try self.putByte('}');
    }
    pub fn beginArray(self: *Writer) WriteError!void {
        try self.putByte('[');
    }
    pub fn endArray(self: *Writer) WriteError!void {
        try self.putByte(']');
    }
    pub fn comma(self: *Writer) WriteError!void {
        try self.putByte(',');
    }
};

test "writer emits escaped object" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.key("jsonrpc");
    try w.string("2.0");
    try w.comma();
    try w.key("id");
    try w.int(7);
    try w.comma();
    try w.key("msg");
    try w.string("a\"b\nc");
    try w.endObject();
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"msg\":\"a\\\"b\\nc\"}",
        w.bytes(),
    );
}

test "writer reports overflow instead of allocating" {
    var buf: [4]u8 = undefined;
    var w = Writer.init(&buf);
    try std.testing.expectError(error.Overflow, w.string("too long"));
}
