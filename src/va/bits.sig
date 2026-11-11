//! @zpm/va bits — the bit writer the encoder's headers are written with:
//! fixed-width fields, Exp-Golomb codes (ue(v), se(v)), the RBSP's trailing
//! bits, and a NAL unit's emulation prevention (H.264 7.4.1, HEVC 7.4.2:
//! 0x03 after two zero bytes before a byte of 0..3). AV1's OBUs use the
//! same writer for their fields and `leb128` for their sizes.
//!
//! Into caller storage; no allocator. A write past the end sets
//! `overflow` and is dropped (the caller checks it once).

const std = @import("std");

pub const Writer = struct {
    buf: []u8,
    /// bits written
    bits: usize = 0,
    overflow: bool = false,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// `n` (at most 32) bits of `v`, most significant first.
    pub fn u(w: *Writer, n: u6, v: u32) void {
        std.debug.assert(n <= 32);
        var k: u6 = n;
        while (k > 0) {
            k -= 1;
            w.bit(@intCast((v >> @intCast(k)) & 1));
        }
    }

    pub fn flag(w: *Writer, b: bool) void {
        w.bit(@intFromBool(b));
    }

    pub fn bit(w: *Writer, b: u1) void {
        const at = w.bits / 8;
        if (at >= w.buf.len) {
            w.overflow = true;
            return;
        }
        const shift: u3 = @intCast(7 - w.bits % 8);
        if (w.bits % 8 == 0) w.buf[at] = 0;
        w.buf[at] |= @as(u8, b) << shift;
        w.bits += 1;
    }

    /// ue(v): unsigned Exp-Golomb.
    pub fn ue(w: *Writer, v: u32) void {
        const x: u64 = @as(u64, v) + 1;
        const len: u6 = @intCast(64 - @clz(x));
        // len - 1 zeros, then x in len bits
        var z: u6 = len - 1;
        while (z > 0) : (z -= 1) w.bit(0);
        var k: u6 = len;
        while (k > 0) {
            k -= 1;
            w.bit(@intCast((x >> k) & 1));
        }
    }

    /// se(v): signed Exp-Golomb (k > 0: 2k - 1, else -2k).
    pub fn se(w: *Writer, v: i32) void {
        const m: u32 = if (v > 0) @as(u32, @intCast(v)) * 2 - 1 else @as(u32, @intCast(-@as(i64, v))) * 2;
        w.ue(m);
    }

    /// rbsp_trailing_bits(): a one, then zeros to the byte.
    pub fn trailing(w: *Writer) void {
        w.bit(1);
        w.alignZero();
    }

    pub fn alignZero(w: *Writer) void {
        while (w.bits % 8 != 0) w.bit(0);
    }

    pub fn byteAligned(w: *const Writer) bool {
        return w.bits % 8 == 0;
    }

    /// The bytes so far (whole bytes; the caller aligned).
    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf[0 .. (w.bits + 7) / 8];
    }

    /// leb128() of `v` (AV1 4.10.5), byte aligned.
    pub fn leb128(w: *Writer, v: u64) void {
        var x = v;
        while (true) {
            const b: u8 = @truncate(x & 0x7f);
            x >>= 7;
            w.u(8, if (x != 0) b | 0x80 else b);
            if (x == 0) break;
        }
    }
};

/// A NAL unit into `out`: a 4-byte start code, then `rbsp` with emulation
/// prevention bytes, the first `header` bytes (the NAL unit header) left
/// as they are. Its length, or null when `out` is too small.
pub fn nal(out: []u8, rbsp: []const u8, header: usize) ?usize {
    var n: usize = 0;
    const start = [_]u8{ 0, 0, 0, 1 };
    if (out.len < start.len + header) return null;
    @memcpy(out[0..4], &start);
    n = 4;
    @memcpy(out[n..][0..header], rbsp[0..header]);
    n += header;
    var zeros: usize = 0;
    for (rbsp[header..]) |b| {
        if (zeros >= 2 and b <= 3) {
            if (n >= out.len) return null;
            out[n] = 3;
            n += 1;
            zeros = 0;
        }
        if (n >= out.len) return null;
        out[n] = b;
        n += 1;
        zeros = if (b == 0) zeros + 1 else 0;
    }
    return n;
}

/// The bytes needed for the largest leb128 of `v`.
pub fn leb128Len(v: u64) usize {
    var x = v;
    var n: usize = 1;
    while (x >= 0x80) : (x >>= 7) n += 1;
    return n;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bits: fixed fields, Exp-Golomb, trailing bits" {
    var buf: [16]u8 = undefined;
    var w = Writer.init(&buf);
    w.u(3, 5); // 101
    w.ue(0); // 1
    w.ue(1); // 010
    w.ue(4); // 00101
    w.se(-1); // ue(2) 011
    w.se(2); // ue(3) 00100
    w.trailing();
    // 101 1 010 00101 011 00100 1 + 3 zero bits
    // 10110100 01010110 01001000
    try testing.expectEqualSlices(u8, &.{ 0xb4, 0x56, 0x48 }, w.bytes());
    try testing.expect(!w.overflow);
    var small: [1]u8 = undefined;
    var s = Writer.init(&small);
    s.u(16, 0xffff);
    try testing.expect(s.overflow);
    var lb: [4]u8 = undefined;
    var l = Writer.init(&lb);
    l.leb128(300);
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, l.bytes());
    try testing.expectEqual(@as(usize, 2), leb128Len(300));
}

test "bits: a NAL unit's emulation prevention" {
    const rbsp = [_]u8{ 0x67, 0, 0, 1, 0, 0, 0, 0, 0, 3, 0x80 };
    var out: [32]u8 = undefined;
    const n = nal(&out, &rbsp, 1).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 0, 0, 3, 1, 0, 0, 3, 0, 0, 3, 0, 3, 0x80 }, out[0..n]);
    var tiny: [6]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), nal(&tiny, &rbsp, 1));
}
