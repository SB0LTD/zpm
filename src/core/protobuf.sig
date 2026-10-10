// @zpm/core/protobuf — Protocol Buffers wire reader/writer (Layer 0)
//
// A general-purpose, allocator-free protobuf wire-format codec operating over
// caller-provided buffers. Zero heap: the `Reader` borrows a `[]const u8` and
// the `Writer` fills a caller `[]u8`, returning bytes written or an overflow
// error. This is Layer-0 pure computation (no platform deps beyond `std` for
// tests), reusable by any module that needs to encode/decode protobuf — the
// YouTube SABR stack is the first consumer (UMP part bodies +
// VideoPlaybackAbrRequest), but nothing here is YouTube-specific.
//
// Wire format (https://protobuf.dev/programming-guides/encoding/):
//   - A field is a varint `tag` = (field_number << 3) | wire_type, followed by
//     the field payload encoded per the wire type.
//   - Wire types used here:
//       0 VARINT        — base-128 LEB, little-endian groups, MSB=continuation
//       1 FIXED64       — 8 little-endian bytes
//       2 LEN           — varint length prefix then that many payload bytes
//       5 FIXED32       — 4 little-endian bytes
//   - Signed ints: `int64`/`int32` encode as plain (two's-complement) varints;
//     `sint32`/`sint64` use zig-zag. Helpers for both are provided.

const std = @import("std");

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    len = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

pub const Error = error{
    Truncated, // ran off the end of the input buffer
    Overflow, // output buffer too small, or varint > 64 bits
    BadWireType, // encountered a wire type we don't handle (groups)
};

pub const Tag = struct {
    field: u32,
    wire: WireType,
};

// ── Reader ──

/// Borrows a caller buffer and walks it field by field. No allocation; all
/// returned slices alias the input buffer.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    /// Read a base-128 varint (up to 10 bytes => 64 bits).
    pub fn readVarint(self: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var count: usize = 0;
        while (true) {
            if (self.pos >= self.buf.len) return Error.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            count += 1;
            // Up to 9 full 7-bit groups + a 10th byte contributing the top bit.
            if (count <= 9) {
                result |= @as(u64, b & 0x7F) << shift;
            } else {
                // 10th byte: only the lowest bit is meaningful for a 64-bit value.
                result |= @as(u64, b & 0x01) << 63;
            }
            if (b & 0x80 == 0) break;
            if (count >= 10) return Error.Overflow;
            shift += 7;
        }
        return result;
    }

    /// Read a field tag, splitting it into field number + wire type.
    pub fn readTag(self: *Reader) Error!Tag {
        const raw = try self.readVarint();
        const wire_bits: u3 = @intCast(raw & 0x07);
        const field: u32 = @intCast(raw >> 3);
        const wire: WireType = switch (wire_bits) {
            0 => .varint,
            1 => .fixed64,
            2 => .len,
            3 => .start_group,
            4 => .end_group,
            5 => .fixed32,
            // Wire types 6 and 7 are not defined by the protobuf spec; treat
            // them as a parse error by mapping to a group marker the caller's
            // skipField rejects (BadWireType).
            6, 7 => .end_group,
        };
        return .{ .field = field, .wire = wire };
    }

    /// Read a length-delimited payload (wire type 2), returning a borrowed slice.
    pub fn readLenDelim(self: *Reader) Error![]const u8 {
        const len = try self.readVarint();
        if (len > self.buf.len - self.pos) return Error.Truncated;
        const start = self.pos;
        self.pos += @intCast(len);
        return self.buf[start..self.pos];
    }

    /// Read a 4-byte little-endian fixed32.
    pub fn readFixed32(self: *Reader) Error!u32 {
        if (self.pos + 4 > self.buf.len) return Error.Truncated;
        const s = self.buf[self.pos .. self.pos + 4];
        self.pos += 4;
        return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24);
    }

    /// Read an 8-byte little-endian fixed64.
    pub fn readFixed64(self: *Reader) Error!u64 {
        if (self.pos + 8 > self.buf.len) return Error.Truncated;
        const s = self.buf[self.pos .. self.pos + 8];
        self.pos += 8;
        var v: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) v |= @as(u64, s[i]) << @intCast(i * 8);
        return v;
    }

    /// Skip the payload for a field of the given wire type.
    pub fn skipField(self: *Reader, wire: WireType) Error!void {
        switch (wire) {
            .varint => _ = try self.readVarint(),
            .fixed64 => _ = try self.readFixed64(),
            .fixed32 => _ = try self.readFixed32(),
            .len => _ = try self.readLenDelim(),
            .start_group, .end_group => return Error.BadWireType,
        }
    }
};

/// Decode a zig-zag encoded 64-bit value into a signed integer.
pub fn zigzagDecode(v: u64) i64 {
    return @bitCast((v >> 1) ^ (~(v & 1) +% 1));
}

/// Encode a signed 64-bit integer into zig-zag form.
pub fn zigzagEncode(v: i64) u64 {
    const u: u64 = @bitCast(v);
    return (u << 1) ^ (@as(u64, @bitCast(v >> 63)));
}

// ── Writer ──

/// Fills a caller buffer, tracking the write cursor. Every write returns an
/// error (never partially writes past the end) if the buffer would overflow.
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf[0..self.pos];
    }

    fn ensure(self: *const Writer, n: usize) Error!void {
        if (self.pos + n > self.buf.len) return Error.Overflow;
    }

    /// Write a base-128 varint.
    pub fn writeVarint(self: *Writer, value: u64) Error!void {
        var v = value;
        // Pre-measure so we never partially write on overflow.
        var tmp: [10]u8 = undefined;
        var n: usize = 0;
        while (true) {
            var byte: u8 = @intCast(v & 0x7F);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            tmp[n] = byte;
            n += 1;
            if (v == 0) break;
        }
        try self.ensure(n);
        @memcpy(self.buf[self.pos .. self.pos + n], tmp[0..n]);
        self.pos += n;
    }

    /// Write a field tag (field number + wire type).
    pub fn writeTag(self: *Writer, field: u32, wire: WireType) Error!void {
        const raw = (@as(u64, field) << 3) | @as(u64, @intFromEnum(wire));
        try self.writeVarint(raw);
    }

    /// Write a length-delimited field: tag, varint length, then the bytes.
    pub fn writeLenDelim(self: *Writer, field: u32, payload: []const u8) Error!void {
        try self.writeTag(field, .len);
        try self.writeVarint(@intCast(payload.len));
        try self.ensure(payload.len);
        @memcpy(self.buf[self.pos .. self.pos + payload.len], payload);
        self.pos += payload.len;
    }

    /// Write a varint field (tag + value).
    pub fn writeVarintField(self: *Writer, field: u32, value: u64) Error!void {
        try self.writeTag(field, .varint);
        try self.writeVarint(value);
    }

    /// Write a 4-byte little-endian fixed32.
    pub fn writeFixed32(self: *Writer, value: u32) Error!void {
        try self.ensure(4);
        self.buf[self.pos] = @intCast(value & 0xFF);
        self.buf[self.pos + 1] = @intCast((value >> 8) & 0xFF);
        self.buf[self.pos + 2] = @intCast((value >> 16) & 0xFF);
        self.buf[self.pos + 3] = @intCast((value >> 24) & 0xFF);
        self.pos += 4;
    }

    /// Write an 8-byte little-endian fixed64.
    pub fn writeFixed64(self: *Writer, value: u64) Error!void {
        try self.ensure(8);
        var i: usize = 0;
        while (i < 8) : (i += 1) self.buf[self.pos + i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
        self.pos += 8;
    }
};

// ── Tests (inline, std.testing) ──

const testing = std.testing;

test "protobuf: varint round-trip across sizes" {
    const values = [_]u64{ 0, 1, 127, 128, 300, 16384, 0xFFFFFFFF, 0x1_0000_0000, 0xFFFF_FFFF_FFFF_FFFF };
    for (values) |v| {
        var buf: [16]u8 = undefined;
        var w = Writer.init(&buf);
        try w.writeVarint(v);
        var r = Reader.init(w.bytes());
        try testing.expectEqual(v, try r.readVarint());
        try testing.expect(r.atEnd());
    }
}

test "protobuf: tag encode/decode" {
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeTag(19, .len);
    var r = Reader.init(w.bytes());
    const tag = try r.readTag();
    try testing.expectEqual(@as(u32, 19), tag.field);
    try testing.expectEqual(WireType.len, tag.wire);
}

test "protobuf: length-delimited round-trip" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeLenDelim(5, "hello sabr");
    var r = Reader.init(w.bytes());
    const tag = try r.readTag();
    try testing.expectEqual(@as(u32, 5), tag.field);
    try testing.expectEqual(WireType.len, tag.wire);
    const payload = try r.readLenDelim();
    try testing.expectEqualSlices(u8, "hello sabr", payload);
}

test "protobuf: fixed32/fixed64 round-trip" {
    var buf: [32]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeFixed32(0xDEADBEEF);
    try w.writeFixed64(0x0102030405060708);
    var r = Reader.init(w.bytes());
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try r.readFixed32());
    try testing.expectEqual(@as(u64, 0x0102030405060708), try r.readFixed64());
}

test "protobuf: writer overflow returns error" {
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    try testing.expectError(Error.Overflow, w.writeVarint(0xFFFF_FFFF));
    // Cursor must not have advanced past a partial write.
    try testing.expectEqual(@as(usize, 0), w.pos);
}

test "protobuf: reader truncated returns error" {
    const data = [_]u8{0x80}; // continuation bit set but no next byte
    var r = Reader.init(&data);
    try testing.expectError(Error.Truncated, r.readVarint());
}

test "protobuf: skipField advances past each wire type" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeVarintField(1, 42);
    try w.writeLenDelim(2, "abc");
    try w.writeTag(3, .fixed32);
    try w.writeFixed32(7);
    var r = Reader.init(w.bytes());
    // Skip all three fields, verify we land exactly at the end.
    var t = try r.readTag();
    try r.skipField(t.wire);
    t = try r.readTag();
    try r.skipField(t.wire);
    t = try r.readTag();
    try r.skipField(t.wire);
    try testing.expect(r.atEnd());
}

test "protobuf: zigzag round-trip" {
    const vals = [_]i64{ 0, -1, 1, -2, 2, -500, 500, std.math.minInt(i64), std.math.maxInt(i64) };
    for (vals) |v| try testing.expectEqual(v, zigzagDecode(zigzagEncode(v)));
}
