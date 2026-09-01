// Layer 2 — HTTP/3 framing (RFC 9114).
//
// Implements the HTTP/3 wire format over QUIC streams. Handles frame
// parsing/serialization, QPACK static-table header compression, and the
// control/request stream lifecycle.
//
// Zero allocator usage. All buffers are caller-provided or stack-local.
//
// Stream mapping (RFC 9114 s6):
//   - Control stream (unidirectional, type 0x00): settings, goaway
//   - Request streams (client-initiated bidirectional): one per HTTP transaction
//   - QPACK encoder/decoder streams (unidirectional, types 0x02/0x03)
//
// This module is intentionally minimal: no QPACK dynamic table, no server push,
// no prioritization beyond what QUIC streams provide natively. These omissions
// are deliberate — dynamic QPACK requires unbounded state, server push is
// deprecated (RFC 9218), and QUIC stream priority (RFC 9218) subsumes H2-style
// priority trees.

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

/// HTTP/3 frame types (RFC 9114 s7.2).
pub const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0D,
};

/// HTTP/3 error codes (RFC 9114 s8.1).
pub const ErrorCode = enum(u64) {
    no_error = 0x0100,
    general_protocol_error = 0x0101,
    internal_error = 0x0102,
    stream_creation_error = 0x0103,
    closed_critical_stream = 0x0104,
    frame_unexpected = 0x0105,
    frame_error = 0x0106,
    excessive_load = 0x0107,
    id_error = 0x0108,
    settings_error = 0x0109,
    missing_settings = 0x010A,
    request_rejected = 0x010B,
    request_cancelled = 0x010C,
    request_incomplete = 0x010D,
    message_error = 0x010E,
    connect_error = 0x010F,
    version_fallback = 0x0110,
};

/// HTTP/3 settings parameters (RFC 9114 s7.2.4.1).
pub const SettingsId = enum(u64) {
    max_field_section_size = 0x06,
    qpack_max_table_capacity = 0x01,
    qpack_blocked_streams = 0x07,
};

/// Unidirectional stream types (RFC 9114 s6.2).
pub const UniStreamType = enum(u64) {
    control = 0x00,
    push = 0x01,
    qpack_encoder = 0x02,
    qpack_decoder = 0x03,
};

// ══════════════════════════════════════════════════════════════════════════════
// Variable-Length Integer (RFC 9000 s16) — shared with QUIC
// ══════════════════════════════════════════════════════════════════════════════

/// Decode a QUIC variable-length integer. Returns value and bytes consumed.
pub fn decodeVarInt(buf: []const u8) ?struct { value: u64, len: usize } {
    if (buf.len == 0) return null;
    const prefix = buf[0] >> 6;
    const length: usize = @as(usize, 1) << @intCast(prefix);
    if (buf.len < length) return null;

    var value: u64 = buf[0] & 0x3F;
    for (1..length) |i| {
        value = (value << 8) | buf[i];
    }
    return .{ .value = value, .len = length };
}

/// Encode a QUIC variable-length integer. Returns bytes written.
pub fn encodeVarInt(value: u64, buf: []u8) usize {
    if (value <= 63) {
        if (buf.len < 1) return 0;
        buf[0] = @intCast(value);
        return 1;
    } else if (value <= 16383) {
        if (buf.len < 2) return 0;
        buf[0] = @intCast(0x40 | (value >> 8));
        buf[1] = @intCast(value & 0xFF);
        return 2;
    } else if (value <= 1073741823) {
        if (buf.len < 4) return 0;
        buf[0] = @intCast(0x80 | (value >> 24));
        buf[1] = @intCast((value >> 16) & 0xFF);
        buf[2] = @intCast((value >> 8) & 0xFF);
        buf[3] = @intCast(value & 0xFF);
        return 4;
    } else {
        if (buf.len < 8) return 0;
        buf[0] = @intCast(0xC0 | (value >> 56));
        buf[1] = @intCast((value >> 48) & 0xFF);
        buf[2] = @intCast((value >> 40) & 0xFF);
        buf[3] = @intCast((value >> 32) & 0xFF);
        buf[4] = @intCast((value >> 24) & 0xFF);
        buf[5] = @intCast((value >> 16) & 0xFF);
        buf[6] = @intCast((value >> 8) & 0xFF);
        buf[7] = @intCast(value & 0xFF);
        return 8;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Frame Parsing
// ══════════════════════════════════════════════════════════════════════════════

/// Parsed H3 frame header (type + length). Payload follows immediately.
pub const FrameHeader = struct {
    frame_type: u64,
    payload_len: u64,
    header_len: usize, // bytes consumed by the frame header itself
};

/// Parse an H3 frame header from a byte slice.
/// Returns null if insufficient data.
pub fn parseFrameHeader(buf: []const u8) ?FrameHeader {
    const type_result = decodeVarInt(buf) orelse return null;
    const remaining = buf[type_result.len..];
    const len_result = decodeVarInt(remaining) orelse return null;
    return .{
        .frame_type = type_result.value,
        .payload_len = len_result.value,
        .header_len = type_result.len + len_result.len,
    };
}

/// Serialize an H3 frame header (type + length) into buf. Returns bytes written.
pub fn serializeFrameHeader(frame_type: u64, payload_len: u64, buf: []u8) usize {
    var off: usize = 0;
    off += encodeVarInt(frame_type, buf[off..]);
    off += encodeVarInt(payload_len, buf[off..]);
    return off;
}

// ══════════════════════════════════════════════════════════════════════════════
// Settings Frame
// ══════════════════════════════════════════════════════════════════════════════

/// Server/client settings. Sane defaults per RFC 9114.
pub const Settings = struct {
    max_field_section_size: u64 = 65536, // 64KB header limit
    qpack_max_table_capacity: u64 = 0, // no dynamic table
    qpack_blocked_streams: u64 = 0, // no blocked streams
};

/// Serialize a SETTINGS frame into buf. Returns total bytes (header + payload).
pub fn serializeSettings(settings: Settings, buf: []u8) usize {
    // Build payload first
    var payload: [64]u8 = undefined;
    var plen: usize = 0;

    // Only emit non-default values
    if (settings.max_field_section_size != 0) {
        plen += encodeVarInt(@intFromEnum(SettingsId.max_field_section_size), payload[plen..]);
        plen += encodeVarInt(settings.max_field_section_size, payload[plen..]);
    }
    if (settings.qpack_max_table_capacity != 0) {
        plen += encodeVarInt(@intFromEnum(SettingsId.qpack_max_table_capacity), payload[plen..]);
        plen += encodeVarInt(settings.qpack_max_table_capacity, payload[plen..]);
    }
    if (settings.qpack_blocked_streams != 0) {
        plen += encodeVarInt(@intFromEnum(SettingsId.qpack_blocked_streams), payload[plen..]);
        plen += encodeVarInt(settings.qpack_blocked_streams, payload[plen..]);
    }

    // Frame header + payload
    var off: usize = 0;
    off += serializeFrameHeader(@intFromEnum(FrameType.settings), plen, buf[off..]);
    @memcpy(buf[off..][0..plen], payload[0..plen]);
    off += plen;
    return off;
}

/// Parse a SETTINGS frame payload. Returns parsed Settings.
pub fn parseSettings(payload: []const u8) Settings {
    var s = Settings{};
    var off: usize = 0;
    while (off < payload.len) {
        const id_r = decodeVarInt(payload[off..]) orelse break;
        off += id_r.len;
        const val_r = decodeVarInt(payload[off..]) orelse break;
        off += val_r.len;

        if (id_r.value == @intFromEnum(SettingsId.max_field_section_size)) {
            s.max_field_section_size = val_r.value;
        } else if (id_r.value == @intFromEnum(SettingsId.qpack_max_table_capacity)) {
            s.qpack_max_table_capacity = val_r.value;
        } else if (id_r.value == @intFromEnum(SettingsId.qpack_blocked_streams)) {
            s.qpack_blocked_streams = val_r.value;
        }
        // Unknown settings are ignored per RFC 9114 s7.2.4
    }
    return s;
}

// ══════════════════════════════════════════════════════════════════════════════
// QPACK Static Table — Header Field Encoding (RFC 9204 s3.1)
// ══════════════════════════════════════════════════════════════════════════════
// We use ONLY the static table (no dynamic table). This is a valid and
// compliant choice — the encoder simply never references dynamic entries,
// and the decoder ignores encoder stream instructions.

/// Static table entry.
pub const StaticEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// QPACK static table (RFC 9204 Appendix A). First 61 entries.
pub const static_table = [_]StaticEntry{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":path", .value = "/" },
    .{ .name = "age", .value = "0" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-length", .value = "0" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = ":method", .value = "CONNECT" },
    .{ .name = ":method", .value = "DELETE" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "HEAD" },
    .{ .name = ":method", .value = "OPTIONS" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":method", .value = "PUT" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "103" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "503" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "accept", .value = "application/dns-message" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "access-control-allow-headers", .value = "cache-control" },
    .{ .name = "access-control-allow-headers", .value = "content-type" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "cache-control", .value = "max-age=0" },
    .{ .name = "cache-control", .value = "max-age=2592000" },
    .{ .name = "cache-control", .value = "max-age=604800" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "cache-control", .value = "no-store" },
    .{ .name = "cache-control", .value = "public, max-age=31536000" },
    .{ .name = "content-encoding", .value = "br" },
    .{ .name = "content-encoding", .value = "gzip" },
    .{ .name = "content-type", .value = "application/dns-message" },
    .{ .name = "content-type", .value = "application/javascript" },
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    .{ .name = "content-type", .value = "image/gif" },
    .{ .name = "content-type", .value = "image/jpeg" },
    .{ .name = "content-type", .value = "image/png" },
    .{ .name = "content-type", .value = "text/css" },
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "content-type", .value = "text/plain" },
    .{ .name = "content-type", .value = "text/plain;charset=utf-8" },
    .{ .name = "range", .value = "bytes=0-" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains; preload" },
    .{ .name = "vary", .value = "accept-encoding" },
    .{ .name = "vary", .value = "origin" },
};

// ══════════════════════════════════════════════════════════════════════════════
// QPACK Header Encoding (static-only, RFC 9204 s4.5)
// ══════════════════════════════════════════════════════════════════════════════

/// Encode a header field using QPACK static-only encoding.
/// Returns bytes written to buf.
pub fn encodeHeader(name: []const u8, value: []const u8, buf: []u8) usize {
    // Try static table index match (name + value)
    for (static_table, 0..) |entry, idx| {
        if (strEql(entry.name, name) and strEql(entry.value, value)) {
            // Indexed field line (s4.5.2): 1xxxxxxx with T=1 (static)
            return encodeIndexed(@intCast(idx), buf);
        }
    }
    // Try name-only match
    for (static_table, 0..) |entry, idx| {
        if (strEql(entry.name, name)) {
            // Literal with name reference (s4.5.4): 01NTxxxx
            return encodeLiteralNameRef(@intCast(idx), value, buf);
        }
    }
    // Literal without name reference (s4.5.6): 001xxxxx
    return encodeLiteralBoth(name, value, buf);
}

/// Encode a HEADERS frame (required insert count = 0, delta base = 0, then fields).
pub fn encodeHeadersFrame(headers: []const [2][]const u8, buf: []u8) usize {
    // QPACK-encoded header block prefix: required insert count = 0, delta base = 0
    var block: [4096]u8 = undefined;
    var blen: usize = 0;
    block[blen] = 0x00; blen += 1; // required insert count = 0
    block[blen] = 0x00; blen += 1; // S=0, delta base = 0

    for (headers) |h| {
        blen += encodeHeader(h[0], h[1], block[blen..]);
    }

    // Wrap in HEADERS frame
    var off: usize = 0;
    off += serializeFrameHeader(@intFromEnum(FrameType.headers), blen, buf[off..]);
    @memcpy(buf[off..][0..blen], block[0..blen]);
    off += blen;
    return off;
}

/// Encode a DATA frame header (caller writes payload separately).
pub fn encodeDataFrameHeader(payload_len: u64, buf: []u8) usize {
    return serializeFrameHeader(@intFromEnum(FrameType.data), payload_len, buf);
}

// ══════════════════════════════════════════════════════════════════════════════
// QPACK Encoding Primitives
// ══════════════════════════════════════════════════════════════════════════════

fn encodeIndexed(index: u8, buf: []u8) usize {
    // Indexed field line: 1 T(1) index(6-bit prefix), T=1 for static.
    return encodePrefixInt(index, 6, 0xC0, buf);
}

fn encodeLiteralNameRef(name_idx: u8, value: []const u8, buf: []u8) usize {
    // Literal with name reference: 01 N(1) T(1) name_idx(4+), T=1.
    const name_len = encodePrefixInt(name_idx, 4, 0x50, buf);
    if (name_len == 0) return 0;
    const value_len = encodeStringLiteral(value, buf[name_len..]);
    if (value_len == 0) return 0;
    return name_len + value_len;
}

fn encodeLiteralBoth(name: []const u8, value: []const u8, buf: []u8) usize {
    // Literal without name reference: 001 N H name_len(3+) + name + value.
    const name_prefix = encodePrefixInt(name.len, 3, 0x20, buf);
    if (name_prefix == 0 or buf.len - name_prefix < name.len) return 0;
    @memcpy(buf[name_prefix..][0..name.len], name);
    const value_off = name_prefix + name.len;
    const value_len = encodeStringLiteral(value, buf[value_off..]);
    if (value_len == 0) return 0;
    return value_off + value_len;
}

fn encodeStringLiteral(s: []const u8, buf: []u8) usize {
    // String literal: H(1) length(7+) + data. H=0 (no Huffman).
    const prefix_len = encodePrefixInt(s.len, 7, 0, buf);
    if (prefix_len == 0 or buf.len - prefix_len < s.len) return 0;
    @memcpy(buf[prefix_len..][0..s.len], s);
    return prefix_len + s.len;
}

fn encodePrefixInt(value: usize, comptime prefix_bits: u3, first_bits: u8, buf: []u8) usize {
    if (buf.len == 0) return 0;
    const prefix_max: usize = (@as(usize, 1) << prefix_bits) - 1;
    if (value < prefix_max) {
        buf[0] = first_bits | @as(u8, @intCast(value));
        return 1;
    }

    buf[0] = first_bits | @as(u8, @intCast(prefix_max));
    var remaining = value - prefix_max;
    var off: usize = 1;
    while (remaining >= 128) {
        if (off >= buf.len) return 0;
        buf[off] = @as(u8, @intCast(remaining & 0x7f)) | 0x80;
        remaining >>= 7;
        off += 1;
    }
    if (off >= buf.len) return 0;
    buf[off] = @intCast(remaining);
    return off + 1;
}

const PrefixInt = struct { value: usize, consumed: usize };

fn decodePrefixInt(buf: []const u8, comptime prefix_bits: u3) ?PrefixInt {
    if (buf.len == 0) return null;
    const prefix_max: usize = (@as(usize, 1) << prefix_bits) - 1;
    var value: usize = buf[0] & @as(u8, @intCast(prefix_max));
    if (value < prefix_max) return .{ .value = value, .consumed = 1 };

    var shift: usize = 0;
    var off: usize = 1;
    while (off < buf.len and shift < @bitSizeOf(usize)) : (off += 1) {
        const byte = buf[off];
        value += @as(usize, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return .{ .value = value, .consumed = off + 1 };
        if (shift > @bitSizeOf(usize) - 8) return null;
        shift += 7;
    }
    return null;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// QPACK Header Decoding (static-only)
// ══════════════════════════════════════════════════════════════════════════════

/// Decoded header field.
pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,
};

/// Decode QPACK-encoded header block into caller-provided array.
/// Returns number of headers decoded.
pub fn decodeHeaders(block: []const u8, out: []HeaderField) usize {
    if (block.len < 2) return 0;
    // Skip prefix (required insert count + delta base)
    var off: usize = 2; // both are 0 for static-only
    var count: usize = 0;

    while (off < block.len and count < out.len) {
        const byte = block[off];
        if (byte & 0xC0 == 0xC0) {
            // Indexed field line (static): 11Txxxxx
            const idx = decodePrefixInt(block[off..], 6) orelse break;
            if (idx.value < static_table.len) {
                out[count] = .{ .name = static_table[idx.value].name, .value = static_table[idx.value].value };
                count += 1;
            }
            off += idx.consumed;
        } else if (byte & 0xF0 == 0x50) {
            // Literal with name reference (static): 0101xxxx
            const name_idx = decodePrefixInt(block[off..], 4) orelse break;
            off += name_idx.consumed;
            const val = decodeStringLiteral(block[off..]) orelse break;
            if (name_idx.value < static_table.len) {
                out[count] = .{ .name = static_table[name_idx.value].name, .value = val.str };
                count += 1;
            }
            off += val.consumed;
        } else if (byte & 0xE0 == 0x20) {
            // Literal without name reference: 001xxxxx
            if (byte & 0x08 != 0) break; // Huffman names are intentionally unsupported.
            const name_len = decodePrefixInt(block[off..], 3) orelse break;
            off += name_len.consumed;
            if (block.len - off < name_len.value) break;
            const name = block[off..][0..name_len.value];
            off += name_len.value;
            const val_r = decodeStringLiteral(block[off..]) orelse break;
            off += val_r.consumed;
            out[count] = .{ .name = name, .value = val_r.str };
            count += 1;
        } else {
            // Unknown or unsupported encoding — skip
            break;
        }
    }
    return count;
}

const StringDecodeResult = struct {
    str: []const u8,
    consumed: usize,
};

fn decodeStringLiteral(buf: []const u8) ?StringDecodeResult {
    if (buf.len == 0) return null;
    if (buf[0] & 0x80 != 0) return null; // Huffman is outside this bounded profile.
    const decoded = decodePrefixInt(buf, 7) orelse return null;
    if (buf.len - decoded.consumed < decoded.value) return null;
    return .{
        .str = buf[decoded.consumed..][0..decoded.value],
        .consumed = decoded.consumed + decoded.value,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// GOAWAY Frame
// ══════════════════════════════════════════════════════════════════════════════

/// Serialize a GOAWAY frame (graceful shutdown). stream_id = last accepted stream.
pub fn serializeGoaway(stream_id: u64, buf: []u8) usize {
    var payload: [8]u8 = undefined;
    const plen = encodeVarInt(stream_id, &payload);
    var off: usize = 0;
    off += serializeFrameHeader(@intFromEnum(FrameType.goaway), plen, buf[off..]);
    @memcpy(buf[off..][0..plen], payload[0..plen]);
    off += plen;
    return off;
}

// ══════════════════════════════════════════════════════════════════════════════
// Incremental request-stream decoding
// ══════════════════════════════════════════════════════════════════════════════

pub const max_request_headers: usize = 64;
pub const max_header_block_bytes: usize = 4096;

pub const BodySink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, bytes: []const u8) bool,
};

pub const StreamResult = enum {
    progress,
    complete,
    malformed,
    headers_too_large,
    body_too_large,
    body_rejected,
};

const DecodePhase = enum { frame_type, frame_length, payload };

/// Bounded, allocation-free HTTP/3 request decoder. Frame headers and payloads
/// may be split across arbitrary QUIC reads. DATA bytes are forwarded to a
/// caller-owned sink as they arrive instead of being retained in this object.
pub const RequestStreamDecoder = struct {
    phase: DecodePhase = .frame_type,
    varint_bytes: [8]u8 = @splat(0),
    varint_len: u4 = 0,
    varint_need: u4 = 0,
    current_type: u64 = 0,
    payload_remaining: u64 = 0,
    first_headers: bool = true,
    saw_headers: bool = false,
    saw_data: bool = false,
    finished: bool = false,
    header_block: [max_header_block_bytes]u8 = @splat(0),
    header_block_len: usize = 0,
    headers: [max_request_headers]HeaderField = undefined,
    header_count: usize = 0,
    body_bytes: u64 = 0,
    max_body_bytes: u64,

    pub fn init(max_body_bytes: u64) RequestStreamDecoder {
        return .{ .max_body_bytes = max_body_bytes };
    }

    pub fn reset(self: *RequestStreamDecoder) void {
        const limit = self.max_body_bytes;
        self.* = init(limit);
    }

    pub fn decodedHeaders(self: *const RequestStreamDecoder) []const HeaderField {
        return self.headers[0..self.header_count];
    }

    pub fn method(self: *const RequestStreamDecoder) []const u8 {
        return self.headerValue(":method") orelse "GET";
    }

    pub fn path(self: *const RequestStreamDecoder) []const u8 {
        return self.headerValue(":path") orelse "/";
    }

    pub fn headerValue(self: *const RequestStreamDecoder, name: []const u8) ?[]const u8 {
        for (self.decodedHeaders()) |header| {
            if (strEql(header.name, name)) return header.value;
        }
        return null;
    }

    pub fn feed(
        self: *RequestStreamDecoder,
        bytes: []const u8,
        fin: bool,
        sink: BodySink,
    ) StreamResult {
        if (self.finished) return .complete;
        var off: usize = 0;
        while (off < bytes.len) {
            switch (self.phase) {
                .frame_type, .frame_length => {
                    const byte = bytes[off];
                    off += 1;
                    const decoded = self.pushVarInt(byte) orelse continue;
                    if (self.phase == .frame_type) {
                        self.current_type = decoded;
                        self.phase = .frame_length;
                    } else {
                        self.payload_remaining = decoded;
                        self.phase = .payload;
                        if (decoded == 0) {
                            const result = self.finishFrame();
                            if (result != .progress) return result;
                        }
                    }
                },
                .payload => {
                    const available: u64 = bytes.len - off;
                    const take_u64 = @min(self.payload_remaining, available);
                    const take: usize = @intCast(take_u64);
                    const part = bytes[off .. off + take];

                    if (self.current_type == @intFromEnum(FrameType.headers)) {
                        if (self.first_headers) {
                            if (self.header_block_len + take > self.header_block.len)
                                return .headers_too_large;
                            @memcpy(self.header_block[self.header_block_len..][0..take], part);
                            self.header_block_len += take;
                        }
                    } else if (self.current_type == @intFromEnum(FrameType.data)) {
                        if (!self.saw_headers) return .malformed;
                        if (self.body_bytes + take_u64 > self.max_body_bytes)
                            return .body_too_large;
                        if (take != 0 and !sink.write(sink.context, part))
                            return .body_rejected;
                        self.body_bytes += take_u64;
                        self.saw_data = true;
                    }

                    off += take;
                    self.payload_remaining -= take_u64;
                    if (self.payload_remaining == 0) {
                        const result = self.finishFrame();
                        if (result != .progress) return result;
                    }
                },
            }
        }

        if (!fin) return .progress;
        if (self.phase != .frame_type or self.varint_len != 0 or !self.saw_headers)
            return .malformed;
        self.finished = true;
        return .complete;
    }

    fn pushVarInt(self: *RequestStreamDecoder, byte: u8) ?u64 {
        if (self.varint_len == 0) self.varint_need = @as(u4, 1) << @intCast(byte >> 6);
        if (self.varint_len >= self.varint_bytes.len) return null;
        self.varint_bytes[self.varint_len] = byte;
        self.varint_len += 1;
        if (self.varint_len != self.varint_need) return null;
        const decoded = decodeVarInt(self.varint_bytes[0..self.varint_len]) orelse return null;
        self.varint_len = 0;
        self.varint_need = 0;
        return decoded.value;
    }

    fn finishFrame(self: *RequestStreamDecoder) StreamResult {
        if (self.current_type == @intFromEnum(FrameType.headers) and self.first_headers) {
            self.header_count = decodeHeaders(self.header_block[0..self.header_block_len], &self.headers);
            if (self.header_count == 0) return .malformed;
            self.saw_headers = true;
            self.first_headers = false;
        }
        self.phase = .frame_type;
        self.current_type = 0;
        return .progress;
    }
};

const TestBody = struct {
    bytes: [64]u8 = @splat(0),
    len: usize = 0,

    fn write(context: *anyopaque, part: []const u8) bool {
        const self: *TestBody = @ptrCast(@alignCast(context));
        if (self.len + part.len > self.bytes.len) return false;
        @memcpy(self.bytes[self.len..][0..part.len], part);
        self.len += part.len;
        return true;
    }
};

test "qpack static name references preserve indices above fifteen" {
    var encoded: [256]u8 = undefined;
    const headers = [_][2][]const u8{
        .{ ":method", "POST" },
        .{ ":path", "/api/sync" },
        .{ "content-type", "application/problem+json" },
    };
    const encoded_len = encodeHeadersFrame(&headers, &encoded);
    if (encoded_len == 0) return error.TestUnexpectedResult;
    const frame = parseFrameHeader(encoded[0..encoded_len]) orelse return error.TestUnexpectedResult;
    var decoded: [8]HeaderField = undefined;
    const count = decodeHeaders(
        encoded[frame.header_len .. frame.header_len + @as(usize, @intCast(frame.payload_len))],
        &decoded,
    );
    if (count != headers.len) return error.TestUnexpectedResult;
    for (headers, decoded[0..count]) |expected, actual| {
        if (!strEql(expected[0], actual.name) or !strEql(expected[1], actual.value))
            return error.TestUnexpectedResult;
    }
}

test "request decoder streams fragmented DATA frames to caller storage" {
    var wire: [512]u8 = undefined;
    const headers = [_][2][]const u8{
        .{ ":method", "POST" },
        .{ ":path", "/api/sync" },
    };
    var wire_len = encodeHeadersFrame(&headers, &wire);
    wire_len += encodeDataFrameHeader(6, wire[wire_len..]);
    @memcpy(wire[wire_len..][0..6], "hello ");
    wire_len += 6;
    wire_len += encodeDataFrameHeader(5, wire[wire_len..]);
    @memcpy(wire[wire_len..][0..5], "world");
    wire_len += 5;

    var body = TestBody{};
    var decoder = RequestStreamDecoder.init(64);
    var i: usize = 0;
    while (i < wire_len) : (i += 1) {
        const result = decoder.feed(wire[i .. i + 1], i + 1 == wire_len, .{
            .context = &body,
            .write = TestBody.write,
        });
        if (i + 1 == wire_len) {
            if (result != .complete) return error.TestUnexpectedResult;
        } else if (result != .progress) return error.TestUnexpectedResult;
    }
    if (!strEql(decoder.method(), "POST") or !strEql(decoder.path(), "/api/sync"))
        return error.TestUnexpectedResult;
    if (!strEql(body.bytes[0..body.len], "hello world")) return error.TestUnexpectedResult;
}

test "request decoder enforces caller body limit" {
    var wire: [128]u8 = undefined;
    const headers = [_][2][]const u8{.{ ":method", "POST" }};
    var wire_len = encodeHeadersFrame(&headers, &wire);
    wire_len += encodeDataFrameHeader(5, wire[wire_len..]);
    @memcpy(wire[wire_len..][0..5], "12345");
    wire_len += 5;
    var body = TestBody{};
    var decoder = RequestStreamDecoder.init(4);
    const result = decoder.feed(wire[0..wire_len], true, .{
        .context = &body,
        .write = TestBody.write,
    });
    if (result != .body_too_large) return error.TestUnexpectedResult;
}
