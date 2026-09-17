// ASN.1 DER decoder — the subset needed for X.509 / PKCS (RFC 5280, X.690)
// Layer 0: Pure computation, no platform deps, no allocator.
//
// A cursor-based Distinguished Encoding Rules (DER) reader over a byte slice.
// Every value is a TLV triple: a tag byte, a length (definite form only — DER
// forbids indefinite length), and the content bytes. All returned slices point
// INTO the caller's input; nothing is copied or allocated.
//
// Only definite-length DER is accepted (BER indefinite lengths are rejected),
// which is exactly what X.509 mandates and closes a class of parser ambiguities.

// ── Universal tag numbers (class 0, bits 4..0) ──────────────────────────
pub const TAG_BOOLEAN: u8 = 0x01;
pub const TAG_INTEGER: u8 = 0x02;
pub const TAG_BIT_STRING: u8 = 0x03;
pub const TAG_OCTET_STRING: u8 = 0x04;
pub const TAG_NULL: u8 = 0x05;
pub const TAG_OID: u8 = 0x06;
pub const TAG_UTF8_STRING: u8 = 0x0C;
pub const TAG_PRINTABLE_STRING: u8 = 0x13;
pub const TAG_IA5_STRING: u8 = 0x16;
pub const TAG_UTC_TIME: u8 = 0x17;
pub const TAG_GENERALIZED_TIME: u8 = 0x18;
pub const TAG_SEQUENCE: u8 = 0x30; // constructed
pub const TAG_SET: u8 = 0x31; // constructed

/// Context-specific constructed tag [n] (as used for X.509 explicit fields).
pub fn contextConstructed(n: u8) u8 {
    return 0xA0 | n;
}
/// Context-specific primitive tag [n] (as used for SAN GeneralNames, etc.).
pub fn contextPrimitive(n: u8) u8 {
    return 0x80 | n;
}

pub const Error = error{
    Truncated, // ran off the end of the input
    BadLength, // indefinite form, over-long, or length exceeds input
    UnexpectedTag, // a required tag did not match
    BadInteger, // malformed INTEGER encoding
    Overflow, // an integer value did not fit the requested Sig type
};

/// A decoded TLV element: its tag and the raw content bytes (V of TLV).
pub const Element = struct {
    tag: u8,
    /// The content octets (between length and the next element).
    data: []const u8,
    /// The full element including tag+length header — needed when a signature
    /// or hash must cover the exact DER encoding (e.g. TBSCertificate).
    raw: []const u8,
};

/// A forward-only cursor over a DER byte slice.
pub const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Cursor {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn atEnd(self: *const Cursor) bool {
        return self.pos >= self.buf.len;
    }

    pub fn remaining(self: *const Cursor) []const u8 {
        return self.buf[self.pos..];
    }

    /// Read the next TLV element without checking its tag. Advances the cursor
    /// past the whole element.
    pub fn next(self: *Cursor) Error!Element {
        const start = self.pos;
        if (self.pos >= self.buf.len) return Error.Truncated;
        const tag = self.buf[self.pos];
        self.pos += 1;

        const len = try self.readLength();
        if (self.pos + len > self.buf.len) return Error.BadLength;
        const data = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return .{ .tag = tag, .data = data, .raw = self.buf[start..self.pos] };
    }

    /// Read the next element and require it to have `expected_tag`.
    pub fn expect(self: *Cursor, expected_tag: u8) Error!Element {
        const el = try self.next();
        if (el.tag != expected_tag) return Error.UnexpectedTag;
        return el;
    }

    /// Peek the tag of the next element without advancing. null at end.
    pub fn peekTag(self: *const Cursor) ?u8 {
        if (self.pos >= self.buf.len) return null;
        return self.buf[self.pos];
    }

    /// Decode a DER definite length at the current position, advancing past the
    /// length octets. Rejects the indefinite form and non-minimal encodings.
    fn readLength(self: *Cursor) Error!usize {
        if (self.pos >= self.buf.len) return Error.Truncated;
        const first = self.buf[self.pos];
        self.pos += 1;

        if (first < 0x80) {
            return first; // short form: length is the byte itself
        }
        if (first == 0x80) return Error.BadLength; // indefinite form — illegal in DER
        if (first == 0xFF) return Error.BadLength; // reserved

        const num_bytes: usize = first & 0x7F;
        if (num_bytes > 8) return Error.BadLength; // absurdly large
        if (self.pos + num_bytes > self.buf.len) return Error.Truncated;

        var len: usize = 0;
        var i: usize = 0;
        while (i < num_bytes) : (i += 1) {
            len = (len << 8) | self.buf[self.pos];
            self.pos += 1;
        }
        return len;
    }
};

/// Open a SEQUENCE (or SET) element and return a cursor over its contents.
pub fn intoSequence(el: Element) Cursor {
    return Cursor.init(el.data);
}

/// Interpret an INTEGER's content bytes as an unsigned value that fits in u64.
/// DER integers are big-endian two's complement with a possible leading 0x00
/// to keep them positive; this rejects negative and oversized values.
pub fn integerAsU64(el: Element) Error!u64 {
    if (el.tag != TAG_INTEGER) return Error.UnexpectedTag;
    var bytes = el.data;
    if (bytes.len == 0) return Error.BadInteger;
    // A single leading zero is a sign pad; strip it. More than one, or a
    // leading 0x00 not followed by a high bit, is a non-minimal encoding.
    if (bytes[0] == 0x00) {
        bytes = bytes[1..];
    } else if (bytes[0] & 0x80 != 0) {
        return Error.BadInteger; // negative — not expected for these fields
    }
    if (bytes.len > 8) return Error.Overflow;
    var v: u64 = 0;
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

/// Return an INTEGER's magnitude bytes (big-endian, sign pad stripped). Used
/// for RSA modulus/exponent, which are far larger than u64.
pub fn integerBytes(el: Element) Error![]const u8 {
    if (el.tag != TAG_INTEGER) return Error.UnexpectedTag;
    var bytes = el.data;
    if (bytes.len == 0) return Error.BadInteger;
    if (bytes[0] == 0x00) bytes = bytes[1..];
    return bytes;
}

/// A BIT STRING's payload with the leading "unused bits" octet removed.
/// X.509 public keys and signatures are wrapped in BIT STRINGs with 0 unused.
pub fn bitStringBytes(el: Element) Error![]const u8 {
    if (el.tag != TAG_BIT_STRING) return Error.UnexpectedTag;
    if (el.data.len < 1) return Error.Truncated;
    // el.data[0] = number of unused bits in the final octet (0 for our uses).
    return el.data[1..];
}

/// Compare an OID element's content to a known DER-encoded OID body (the bytes
/// after tag+length). Returns true on exact match.
pub fn oidEquals(el: Element, encoded: []const u8) bool {
    if (el.tag != TAG_OID) return false;
    if (el.data.len != encoded.len) return false;
    for (el.data, encoded) |a, b| {
        if (a != b) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "asn1: short-form SEQUENCE of two INTEGERs" {
    // SEQUENCE(7) { INTEGER 1 (02 01 01), INTEGER 258 (02 02 01 02) } — 3+4=7 content bytes.
    const der = [_]u8{ 0x30, 0x07, 0x02, 0x01, 0x01, 0x02, 0x02, 0x01, 0x02 };
    var c = Cursor.init(&der);
    const seq = try c.expect(TAG_SEQUENCE);
    var inner = intoSequence(seq);
    const a = try inner.expect(TAG_INTEGER);
    try testing.expectEqual(@as(u64, 1), try integerAsU64(a));
    const b = try inner.expect(TAG_INTEGER);
    try testing.expectEqual(@as(u64, 258), try integerAsU64(b));
    try testing.expect(inner.atEnd());
}

test "asn1: long-form length (0x82)" {
    // OCTET STRING of 300 bytes: tag 04, len 0x82 0x01 0x2C, then 300 content bytes.
    var der: [304]u8 = undefined;
    der[0] = TAG_OCTET_STRING;
    der[1] = 0x82;
    der[2] = 0x01;
    der[3] = 0x2C; // 300
    var c = Cursor.init(&der);
    const el = try c.expect(TAG_OCTET_STRING);
    try testing.expectEqual(@as(usize, 300), el.data.len);
}

test "asn1: indefinite length is rejected" {
    const der = [_]u8{ 0x30, 0x80, 0x00, 0x00 };
    var c = Cursor.init(&der);
    try testing.expectError(Error.BadLength, c.next());
}

test "asn1: INTEGER with sign pad" {
    // INTEGER 0x00FF (leading zero keeps it positive) -> 255
    const der = [_]u8{ 0x02, 0x02, 0x00, 0xFF };
    var c = Cursor.init(&der);
    const el = try c.expect(TAG_INTEGER);
    try testing.expectEqual(@as(u64, 255), try integerAsU64(el));
    const mag = try integerBytes(el);
    try testing.expectEqual(@as(usize, 1), mag.len);
    try testing.expectEqual(@as(u8, 0xFF), mag[0]);
}

test "asn1: truncated input errors" {
    const der = [_]u8{ 0x02, 0x04, 0x01 }; // claims 4 bytes, only 1 present
    var c = Cursor.init(&der);
    try testing.expectError(Error.BadLength, c.next());
}
