// @zpm/youtube/sabr/ump — UMP container parser + SABR part decoders
//
// Parses YouTube's UMP (Ultra Media Protocol) response stream — the body of a
// SABR `POST .../videoplayback?...&sabr=1` with Content-Type
// `application/vnd.yt-ump`. A UMP body is a sequence of parts; each part is:
//
//     varint part_type   (UMP varint, RFC8794-like)
//     varint part_size
//     part_size payload bytes
//
// Part-type numbers are the googlevideo `UMPPartId` enum
// (protos/video_streaming/ump_part_id.proto). The ones this loop dispatches:
//
//     MEDIA_HEADER              20
//     MEDIA                     21
//     MEDIA_END                 22
//     NEXT_REQUEST_POLICY       35
//     FORMAT_INITIALIZATION_METADATA 42
//     SABR_REDIRECT             43
//     SABR_ERROR                44   (googlevideo authoritative; the task draft
//                                      said 45 — corrected here, see findings)
//     SABR_CONTEXT_UPDATE       57
//     STREAM_PROTECTION_STATUS  58   (googlevideo authoritative; the task draft
//                                      said 23 — corrected here, see findings)
//
// Message field numbers are decoded via the generic @zpm/core/protobuf Reader
// against the googlevideo .proto field numbers (cited at each struct).
//
// UMP varint note (gsuberland/UMP_Format): UMP uses an RFC8794-like variable
// integer whose *first byte* encodes the total length in its high bits. This
// is NOT the base-128 LEB128 protobuf varint, so UMP framing varints are read
// by `readUmpVarint` here; the protobuf Reader is used only for the message
// payloads. Zero allocation: parser state + decoded structs are caller-owned.

const pb = @import("protobuf");

pub const PartType = struct {
    pub const MEDIA_HEADER: u64 = 20;
    pub const MEDIA: u64 = 21;
    pub const MEDIA_END: u64 = 22;
    pub const NEXT_REQUEST_POLICY: u64 = 35;
    pub const FORMAT_INITIALIZATION_METADATA: u64 = 42;
    pub const SABR_REDIRECT: u64 = 43;
    pub const SABR_ERROR: u64 = 44;
    pub const SABR_CONTEXT_UPDATE: u64 = 57;
    pub const STREAM_PROTECTION_STATUS: u64 = 58;
};

// ── UMP framing varint ──
//
// The lead byte's high bits select the byte count:
//   0xxxxxxx -> 1 byte  : value = b0 & 0x7F
//   10xxxxxx -> 2 bytes : value = (b0 & 0x3F)       | (b1 << 6)
//   110xxxxx -> 3 bytes : value = (b0 & 0x1F)       | (b1<<5) | (b2<<13)
//   1110xxxx -> 4 bytes : value = (b0 & 0x0F)       | (b1<<4) | (b2<<12) | (b3<<20)
//   1111xxxx -> 5 bytes : value = little-endian 32-bit from b1..b4 (lead byte's
//                         low nibble is ignored for the 5-byte case)

pub const UmpVarint = struct { value: u64, size: usize };

fn umpVarintSize(first: u8) usize {
    if (first & 0x80 == 0) return 1;
    if (first & 0x40 == 0) return 2;
    if (first & 0x20 == 0) return 3;
    if (first & 0x10 == 0) return 4;
    return 5;
}

/// Read a UMP framing varint at `buf[off..]`. Returns null if the buffer does
/// not hold the whole varint (caller treats this as "need more bytes").
pub fn readUmpVarint(buf: []const u8, off: usize) ?UmpVarint {
    if (off >= buf.len) return null;
    const first = buf[off];
    const n = umpVarintSize(first);
    if (off + n > buf.len) return null;
    var value: u64 = 0;
    switch (n) {
        1 => value = first & 0x7F,
        2 => value = @as(u64, first & 0x3F) | (@as(u64, buf[off + 1]) << 6),
        3 => value = @as(u64, first & 0x1F) | (@as(u64, buf[off + 1]) << 5) | (@as(u64, buf[off + 2]) << 13),
        4 => value = @as(u64, first & 0x0F) | (@as(u64, buf[off + 1]) << 4) | (@as(u64, buf[off + 2]) << 12) | (@as(u64, buf[off + 3]) << 20),
        5 => value = @as(u64, buf[off + 1]) | (@as(u64, buf[off + 2]) << 8) | (@as(u64, buf[off + 3]) << 16) | (@as(u64, buf[off + 4]) << 24),
        else => unreachable,
    }
    return .{ .value = value, .size = n };
}

// ── Decoded SABR part structs ──

/// MediaHeader (protos/video_streaming/media_header.proto): routes the MEDIA
/// bytes that follow to a format + segment. We keep the fields the loop needs.
pub const MediaHeader = struct {
    header_id: u32 = 0, // field 1
    itag: i32 = 0, // field 3
    lmt: u64 = 0, // field 4
    segment_byte_range_start: i64 = 0, // field 6
    is_init_segment: bool = false, // field 8
    segment_num: i32 = 0, // field 9
    start_ms: i64 = 0, // field 11
    duration_ms: i64 = 0, // field 12
    content_length: i64 = 0, // field 14 (segment_length_bytes)
};

/// FormatInitializationMetadata (format_initialization_metadata.proto).
pub const FormatInitMetadata = struct {
    itag: i32 = 0, // format_id (field 2) -> FormatId.itag (field 1)
    lmt: u64 = 0, // format_id (field 2) -> FormatId.last_modified (field 2)
    end_segment_num: i64 = 0, // field 4 (total segments)
    end_time_ms: i64 = 0, // field 3
    init_start: i32 = 0, // init_segment_range (field 6) -> Range.start (field 3)
    init_end: i32 = 0, // init_segment_range (field 6) -> Range.end (field 4)
    index_start: i32 = 0, // index_range (field 7) -> Range.start (field 3)
    index_end: i32 = 0, // index_range (field 7) -> Range.end (field 4)
};

/// SabrRedirect (sabr_redirect.proto): url (field 1).
pub const SabrRedirect = struct {
    url: []const u8 = "", // borrowed from the part payload
};

/// SabrError (sabr_error.proto): type (field 1), code (field 2).
pub const SabrError = struct {
    err_type: []const u8 = "",
    code: i32 = 0,
};

/// NextRequestPolicy (next_request_policy.proto) — the fields the loop uses to
/// pace the next POST. playback_cookie (field 7) is kept as a borrowed slice.
pub const NextRequestPolicy = struct {
    backoff_time_ms: i32 = 0, // field 4
    playback_cookie: []const u8 = "", // field 7 (opaque bytes to echo back)
    has_playback_cookie: bool = false,
};

/// StreamProtectionStatus (stream_protection_status.proto): status (field 1).
/// status == 1 OK, 2 attestation pending (cold-start acceptable), 3 wall.
pub const StreamProtectionStatus = struct {
    status: i32 = 0,
    max_retries: i32 = 0,
};

/// SabrContextUpdate (sabr_context_update.proto): the server hands the client a
/// context blob it MUST echo back inside StreamerContext on subsequent requests
/// so attestation/validation completes (otherwise the server holds the stream at
/// STREAM_PROTECTION_STATUS == 2). Fields: type (1, int), scope (2, enum),
/// value (3, bytes), send_by_default (4, bool). `value` is borrowed from the
/// part payload (copy before the next request overwrites the response buffer).
pub const SabrContextUpdate = struct {
    ctx_type: i32 = 0,
    scope: i32 = 0,
    value: []const u8 = "",
    send_by_default: bool = false,
    present: bool = false,
};

// ── FormatId (misc/common.proto): itag=1, last_modified=2, xtags=3 ──
const FormatId = struct { itag: i32 = 0, last_modified: u64 = 0 };

fn decodeFormatId(payload: []const u8) FormatId {
    var out = FormatId{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            1 => out.itag = readI32(&r, tag.wire),
            2 => out.last_modified = r.readVarint() catch 0,
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

const Range = struct { start: i32 = 0, end: i32 = 0 };

fn decodeRange(payload: []const u8) Range {
    var out = Range{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            3 => out.start = readI32(&r, tag.wire),
            4 => out.end = readI32(&r, tag.wire),
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

fn readI32(r: *pb.Reader, wire: pb.WireType) i32 {
    if (wire != .varint) {
        r.skipField(wire) catch {};
        return 0;
    }
    const v = r.readVarint() catch return 0;
    return @truncate(@as(i64, @bitCast(v)));
}

fn readI64(r: *pb.Reader, wire: pb.WireType) i64 {
    if (wire != .varint) {
        r.skipField(wire) catch {};
        return 0;
    }
    const v = r.readVarint() catch return 0;
    return @bitCast(v);
}

// ── Part decoders ──

pub fn decodeMediaHeader(payload: []const u8) MediaHeader {
    var out = MediaHeader{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            1 => out.header_id = @truncate(r.readVarint() catch 0),
            3 => out.itag = readI32(&r, tag.wire),
            4 => out.lmt = r.readVarint() catch 0,
            6 => out.segment_byte_range_start = readI64(&r, tag.wire),
            8 => out.is_init_segment = (r.readVarint() catch 0) != 0,
            9 => out.segment_num = readI32(&r, tag.wire),
            11 => out.start_ms = readI64(&r, tag.wire),
            12 => out.duration_ms = readI64(&r, tag.wire),
            13 => { // nested FormatId — fill itag/lmt if not already set
                const fp = r.readLenDelim() catch break;
                const fid = decodeFormatId(fp);
                if (out.itag == 0) out.itag = fid.itag;
                if (out.lmt == 0) out.lmt = fid.last_modified;
            },
            14 => out.content_length = readI64(&r, tag.wire),
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

pub fn decodeFormatInit(payload: []const u8) FormatInitMetadata {
    var out = FormatInitMetadata{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            2 => {
                const fp = r.readLenDelim() catch break;
                const fid = decodeFormatId(fp);
                out.itag = fid.itag;
                out.lmt = fid.last_modified;
            },
            3 => out.end_time_ms = readI64(&r, tag.wire),
            4 => out.end_segment_num = readI64(&r, tag.wire),
            6 => {
                const rp = r.readLenDelim() catch break;
                const rng = decodeRange(rp);
                out.init_start = rng.start;
                out.init_end = rng.end;
            },
            7 => {
                const rp = r.readLenDelim() catch break;
                const rng = decodeRange(rp);
                out.index_start = rng.start;
                out.index_end = rng.end;
            },
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

pub fn decodeSabrRedirect(payload: []const u8) SabrRedirect {
    var out = SabrRedirect{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            1 => out.url = r.readLenDelim() catch "",
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

pub fn decodeSabrError(payload: []const u8) SabrError {
    var out = SabrError{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            1 => out.err_type = r.readLenDelim() catch "",
            2 => out.code = readI32(&r, tag.wire),
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

pub fn decodeNextRequestPolicy(payload: []const u8) NextRequestPolicy {
    var out = NextRequestPolicy{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            4 => out.backoff_time_ms = readI32(&r, tag.wire),
            7 => {
                out.playback_cookie = r.readLenDelim() catch "";
                out.has_playback_cookie = out.playback_cookie.len > 0;
            },
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

pub fn decodeStreamProtectionStatus(payload: []const u8) StreamProtectionStatus {
    var out = StreamProtectionStatus{};
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            1 => out.status = readI32(&r, tag.wire),
            2 => out.max_retries = readI32(&r, tag.wire),
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

/// Decode a SABR_CONTEXT_UPDATE part. The `value` slice is borrowed from
/// `payload` (copy it before the next response overwrites the buffer).
pub fn decodeSabrContextUpdate(payload: []const u8) SabrContextUpdate {
    var out = SabrContextUpdate{ .present = true };
    var r = pb.Reader.init(payload);
    while (!r.atEnd()) {
        const tag = r.readTag() catch break;
        switch (tag.field) {
            1 => out.ctx_type = readI32(&r, tag.wire),
            2 => out.scope = readI32(&r, tag.wire),
            3 => out.value = r.readLenDelim() catch "",
            4 => out.send_by_default = (r.readVarint() catch 0) != 0,
            else => r.skipField(tag.wire) catch break,
        }
    }
    return out;
}

/// Strip the single varint `header_id` prefix a MEDIA(21) payload carries,
/// returning the raw media bytes that follow. The prefix is a UMP varint that
/// ties this MEDIA part to a preceding MEDIA_HEADER's `header_id`.
pub fn mediaBytes(payload: []const u8, header_id_out: *u32) []const u8 {
    const v = readUmpVarint(payload, 0) orelse {
        header_id_out.* = 0;
        return payload;
    };
    header_id_out.* = @truncate(v.value);
    return payload[v.size..];
}

// ── PartReader: iterate parts in a single UMP buffer ──

pub const Part = struct {
    part_type: u64,
    payload: []const u8,
};

/// Walks parts within one buffer. Cross-buffer continuation (a part whose
/// declared size exceeds what this buffer holds) is handled by `PartialState`.
pub const PartReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) PartReader {
        return .{ .buf = buf, .pos = 0 };
    }

    /// Return the next complete part, or null when the buffer is exhausted or a
    /// part header/payload is incomplete (the leftover is reported via
    /// `leftover()` so the caller can carry it into the next buffer).
    pub fn next(self: *PartReader) ?Part {
        if (self.pos >= self.buf.len) return null;
        const start = self.pos;
        const type_v = readUmpVarint(self.buf, self.pos) orelse {
            self.pos = start;
            return null;
        };
        const after_type = self.pos + type_v.size;
        const size_v = readUmpVarint(self.buf, after_type) orelse {
            self.pos = start;
            return null;
        };
        const payload_start = after_type + size_v.size;
        const payload_end = payload_start + @as(usize, @intCast(size_v.value));
        if (payload_end > self.buf.len) {
            // Part body not fully present in this buffer.
            self.pos = start;
            return null;
        }
        self.pos = payload_end;
        return .{ .part_type = type_v.value, .payload = self.buf[payload_start..payload_end] };
    }

    /// Bytes from the last incomplete part onward (to prepend to the next buffer).
    pub fn leftover(self: *const PartReader) []const u8 {
        return self.buf[self.pos..];
    }
};

/// Carries unconsumed bytes between successive SABR POST responses so a part
/// split across the HTTP boundary is stitched. The caller owns `buf`.
pub const PartialState = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) PartialState {
        return .{ .buf = buf, .len = 0 };
    }

    pub fn reset(self: *PartialState) void {
        self.len = 0;
    }

    /// Append `data` after any carried-over leftover. Returns the combined slice
    /// to parse, or null if it does not fit the caller buffer.
    pub fn combine(self: *PartialState, data: []const u8) ?[]const u8 {
        if (self.len + data.len > self.buf.len) return null;
        @memcpy(self.buf[self.len .. self.len + data.len], data);
        self.len += data.len;
        return self.buf[0..self.len];
    }

    /// Keep `leftover` (which must alias `self.buf`) for the next round.
    pub fn carry(self: *PartialState, leftover: []const u8) void {
        if (leftover.len == 0) {
            self.len = 0;
            return;
        }
        // leftover points into self.buf; move it to the front.
        const n = leftover.len;
        var i: usize = 0;
        while (i < n) : (i += 1) self.buf[i] = leftover[i];
        self.len = n;
    }
};

// ── Tests (inline, std.testing) ──

const std = @import("std");
const testing = std.testing;

// Build a UMP framing varint into `buf`, return bytes written.
fn writeUmpVarint(buf: []u8, value: u64) usize {
    if (value < 0x80) {
        buf[0] = @intCast(value);
        return 1;
    } else if (value < 0x4000) {
        buf[0] = @as(u8, 0x80) | @as(u8, @intCast(value & 0x3F));
        buf[1] = @intCast((value >> 6) & 0xFF);
        return 2;
    } else {
        // 5-byte form (lead nibble 0xF0), 32-bit LE value — always valid.
        buf[0] = 0xF0;
        buf[1] = @intCast(value & 0xFF);
        buf[2] = @intCast((value >> 8) & 0xFF);
        buf[3] = @intCast((value >> 16) & 0xFF);
        buf[4] = @intCast((value >> 24) & 0xFF);
        return 5;
    }
}

fn appendPart(buf: []u8, off: usize, ptype: u64, payload: []const u8) usize {
    var p = off;
    p += writeUmpVarint(buf[p..], ptype);
    p += writeUmpVarint(buf[p..], payload.len);
    @memcpy(buf[p .. p + payload.len], payload);
    return p + payload.len;
}

test "ump: readUmpVarint 1/2/5 byte forms" {
    var b: [8]u8 = undefined;
    _ = writeUmpVarint(&b, 21);
    try testing.expectEqual(@as(u64, 21), readUmpVarint(&b, 0).?.value);
    _ = writeUmpVarint(&b, 300);
    const v2 = readUmpVarint(&b, 0).?;
    try testing.expectEqual(@as(u64, 300), v2.value);
    try testing.expectEqual(@as(usize, 2), v2.size);
    _ = writeUmpVarint(&b, 1_000_000);
    const v5 = readUmpVarint(&b, 0).?;
    try testing.expectEqual(@as(u64, 1_000_000), v5.value);
    try testing.expectEqual(@as(usize, 5), v5.size);
}

test "ump: two synthetic parts decode with correct type/payload boundaries" {
    var buf: [64]u8 = undefined;
    var p: usize = 0;
    p = appendPart(&buf, p, PartType.STREAM_PROTECTION_STATUS, &.{ 0x08, 0x01 }); // status=1
    p = appendPart(&buf, p, PartType.MEDIA_END, &.{0x00});
    var pr = PartReader.init(buf[0..p]);
    const a = pr.next().?;
    try testing.expectEqual(PartType.STREAM_PROTECTION_STATUS, a.part_type);
    try testing.expectEqual(@as(usize, 2), a.payload.len);
    const b = pr.next().?;
    try testing.expectEqual(PartType.MEDIA_END, b.part_type);
    try testing.expectEqual(@as(usize, 1), b.payload.len);
    try testing.expect(pr.next() == null);
}

test "ump: MEDIA_HEADER decodes itag/lmt/content_length" {
    // Build a MediaHeader payload: itag(3)=251 varint, lmt(4)=123456 varint,
    // content_length(14)=5000 varint.
    var pbuf: [64]u8 = undefined;
    var w = pb.Writer.init(&pbuf);
    try w.writeVarintField(3, 251);
    try w.writeVarintField(4, 123456);
    try w.writeVarintField(14, 5000);
    const mh = decodeMediaHeader(w.bytes());
    try testing.expectEqual(@as(i32, 251), mh.itag);
    try testing.expectEqual(@as(u64, 123456), mh.lmt);
    try testing.expectEqual(@as(i64, 5000), mh.content_length);
}

test "ump: part larger than buffer is flagged partial then resumes" {
    // One MEDIA part of 10 payload bytes, but split so the first chunk lacks 4.
    var full: [64]u8 = undefined;
    const payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const total = appendPart(&full, 0, PartType.MEDIA, &payload);

    var state_buf: [128]u8 = undefined;
    var state = PartialState.init(&state_buf);

    // First chunk: everything but the last 4 bytes -> no complete part yet.
    const split = total - 4;
    const c1 = state.combine(full[0..split]).?;
    var pr1 = PartReader.init(c1);
    try testing.expect(pr1.next() == null);
    state.carry(pr1.leftover());
    try testing.expectEqual(@as(usize, split), state.len);

    // Second chunk: the remaining 4 bytes -> the part now completes.
    const c2 = state.combine(full[split..total]).?;
    var pr2 = PartReader.init(c2);
    const part = pr2.next().?;
    try testing.expectEqual(PartType.MEDIA, part.part_type);
    var hid: u32 = 0;
    const media = mediaBytes(part.payload, &hid);
    // payload[0] is the header-id prefix (0), the rest is media.
    try testing.expectEqualSlices(u8, payload[1..], media);
}

test "ump: MEDIA part strips header-id prefix" {
    var buf: [32]u8 = undefined;
    const payload = [_]u8{ 7, 0xAA, 0xBB, 0xCC }; // header_id=7, media=AA BB CC
    const n = appendPart(&buf, 0, PartType.MEDIA, &payload);
    var pr = PartReader.init(buf[0..n]);
    const part = pr.next().?;
    var hid: u32 = 0;
    const media = mediaBytes(part.payload, &hid);
    try testing.expectEqual(@as(u32, 7), hid);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, media);
}

test "ump: SABR_REDIRECT decodes url" {
    var pbuf: [64]u8 = undefined;
    var w = pb.Writer.init(&pbuf);
    try w.writeLenDelim(1, "https://rr5.googlevideo.com/videoplayback");
    const red = decodeSabrRedirect(w.bytes());
    try testing.expectEqualSlices(u8, "https://rr5.googlevideo.com/videoplayback", red.url);
}
