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

const packet = @import("packet");

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
    // Indexed field line: 1 T(1) index(6-bit prefix)
    // T=1 for static table
    if (buf.len == 0) return 0;
    buf[0] = 0xC0 | (index & 0x3F); // 11xxxxxx
    return 1;
}

fn encodeLiteralNameRef(name_idx: u8, value: []const u8, buf: []u8) usize {
    // Literal with name reference: 01 N(1) T(1) name_idx(4-bit)
    // N=0 (allow huffman), T=1 (static)
    var off: usize = 0;
    if (buf.len < 3) return 0;
    buf[off] = 0x50 | (name_idx & 0x0F); // 0101xxxx (N=0, T=1)
    off += 1;
    off += encodeStringLiteral(value, buf[off..]);
    return off;
}

fn encodeLiteralBoth(name: []const u8, value: []const u8, buf: []u8) usize {
    // Literal without name reference: 001 N(1) name_len + name + value_len + value
    var off: usize = 0;
    if (buf.len < 4) return 0;
    buf[off] = 0x20; // 0010 N=0
    off += 1;
    off += encodeStringLiteral(name, buf[off..]);
    off += encodeStringLiteral(value, buf[off..]);
    return off;
}

fn encodeStringLiteral(s: []const u8, buf: []u8) usize {
    // String literal: H(1) length(7-bit prefix) + data
    // H=0 (no huffman — keeps it simple and fast)
    var off: usize = 0;
    const len: u8 = @intCast(@min(s.len, 127));
    if (buf.len < 1 + len) return 0;
    buf[off] = len; // H=0, length in 7-bit prefix
    off += 1;
    @memcpy(buf[off..][0..len], s[0..len]);
    off += len;
    return off;
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
            const idx = byte & 0x3F;
            if (idx < static_table.len) {
                out[count] = .{ .name = static_table[idx].name, .value = static_table[idx].value };
                count += 1;
            }
            off += 1;
        } else if (byte & 0xF0 == 0x50) {
            // Literal with name reference (static): 0101xxxx
            const name_idx = byte & 0x0F;
            off += 1;
            const val = decodeStringLiteral(block[off..]) orelse break;
            if (name_idx < static_table.len) {
                out[count] = .{ .name = static_table[name_idx].name, .value = val.str };
                count += 1;
            }
            off += val.consumed;
        } else if (byte & 0xE0 == 0x20) {
            // Literal without name reference: 001xxxxx
            off += 1;
            const name_r = decodeStringLiteral(block[off..]) orelse break;
            off += name_r.consumed;
            const val_r = decodeStringLiteral(block[off..]) orelse break;
            off += val_r.consumed;
            out[count] = .{ .name = name_r.str, .value = val_r.str };
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
    const len: usize = buf[0] & 0x7F; // H bit ignored (we don't do huffman)
    if (buf.len < 1 + len) return null;
    return .{ .str = buf[1..][0..len], .consumed = 1 + len };
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
