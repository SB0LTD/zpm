// Layer 1 — QUIC packet parsing and serialization.
//
// Pure parsing logic per RFC 9000 §16-19, RFC 9221 §4, RFC 9369 §3.1.
// No I/O, no crypto, no connection state. Operates on byte slices.
// Zero allocator usage.

// ── QUIC Versions ──

pub const Version = enum(u32) {
    quic_v1 = 0x00000001,
    quic_v2 = 0x6b3343cf,
    negotiation = 0x00000000,
};

// ── Packet Types ──

pub const PacketType = enum(u2) {
    initial = 0,
    zero_rtt = 1,
    handshake = 2,
    retry = 3,
};

// ── Connection ID ──

pub const max_cid_len = 20;

pub const ConnectionId = struct {
    buf: [max_cid_len]u8 = [_]u8{0} ** max_cid_len,
    len: u8 = 0,

    pub fn slice(self: *const ConnectionId) []const u8 {
        return self.buf[0..self.len];
    }
};

// ── Packet Header ──

pub const PacketHeader = struct {
    is_long: bool = false,
    version: u32 = 0,
    pkt_type: PacketType = .initial,
    dst_cid: ConnectionId = .{},
    src_cid: ConnectionId = .{},
    pkt_number: u32 = 0,
    pkt_number_len: u2 = 0,
    token: [256]u8 = [_]u8{0} ** 256,
    token_len: u16 = 0,
    payload_offset: u16 = 0,
    payload_len: u16 = 0,
};

// ── Frame Types ──

pub const FrameType = enum(u8) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream_base = 0x08,
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close = 0x1c,
    connection_close_app = 0x1d,
    handshake_done = 0x1e,
    datagram = 0x30,
    datagram_len = 0x31,
};

pub const max_ack_ranges = 64;

pub const AckRange = struct {
    gap: u64 = 0,
    length: u64 = 0,
};

pub const Frame = union(enum) {
    padding: void,
    ping: void,
    ack: struct {
        largest_acked: u64 = 0,
        ack_delay: u64 = 0,
        range_count: u16 = 0,
        first_range: u64 = 0,
        ranges: [max_ack_ranges]AckRange = [_]AckRange{.{}} ** max_ack_ranges,
    },
    reset_stream: struct { stream_id: u64 = 0, error_code: u64 = 0, final_size: u64 = 0 },
    stop_sending: struct { stream_id: u64 = 0, error_code: u64 = 0 },
    crypto: struct { offset: u64 = 0, data_offset: u16 = 0, data_len: u16 = 0 },
    new_token: struct { token_len: u16 = 0, token_offset: u16 = 0 },
    stream: struct { stream_id: u64 = 0, offset: u64 = 0, data_offset: u16 = 0, data_len: u16 = 0, fin: bool = false },
    max_data: struct { max: u64 = 0 },
    max_stream_data: struct { stream_id: u64 = 0, max: u64 = 0 },
    max_streams_bidi: struct { max: u64 = 0 },
    max_streams_uni: struct { max: u64 = 0 },
    data_blocked: struct { limit: u64 = 0 },
    stream_data_blocked: struct { stream_id: u64 = 0, limit: u64 = 0 },
    streams_blocked_bidi: struct { limit: u64 = 0 },
    streams_blocked_uni: struct { limit: u64 = 0 },
    new_connection_id: struct {
        seq: u64 = 0,
        retire_prior_to: u64 = 0,
        cid: ConnectionId = .{},
        stateless_reset_token: [16]u8 = [_]u8{0} ** 16,
    },
    retire_connection_id: struct { seq: u64 = 0 },
    path_challenge: struct { data: [8]u8 = [_]u8{0} ** 8 },
    path_response: struct { data: [8]u8 = [_]u8{0} ** 8 },
    connection_close: struct { error_code: u64 = 0, frame_type: u64 = 0, reason_offset: u16 = 0, reason_len: u16 = 0 },
    handshake_done: void,
    datagram: struct { data_offset: u16 = 0, data_len: u16 = 0 },
};

// ── Parse Error ──

pub const ParseError = enum(u8) {
    none,
    truncated,
    invalid_type,
    oversized_cid,
    invalid_varint,
    malformed_frame,
};

// ── Variable-Length Integer (RFC 9000 §16) ──

pub fn encodeVarint(val: u64, out: []u8) u8 {
    if (val <= 63) {
        if (out.len < 1) return 0;
        out[0] = @truncate(val);
        return 1;
    } else if (val <= 16383) {
        if (out.len < 2) return 0;
        out[0] = @as(u8, 0x40) | @as(u8, @truncate(val >> 8));
        out[1] = @truncate(val);
        return 2;
    } else if (val <= 1073741823) {
        if (out.len < 4) return 0;
        out[0] = @as(u8, 0x80) | @as(u8, @truncate(val >> 24));
        out[1] = @truncate(val >> 16);
        out[2] = @truncate(val >> 8);
        out[3] = @truncate(val);
        return 4;
    } else if (val <= 4611686018427387903) {
        if (out.len < 8) return 0;
        out[0] = @as(u8, 0xC0) | @as(u8, @truncate(val >> 56));
        out[1] = @truncate(val >> 48);
        out[2] = @truncate(val >> 40);
        out[3] = @truncate(val >> 32);
        out[4] = @truncate(val >> 24);
        out[5] = @truncate(val >> 16);
        out[6] = @truncate(val >> 8);
        out[7] = @truncate(val);
        return 8;
    }
    return 0; // value too large (> 2^62-1)
}

pub const VarintResult = struct { val: u64, len: u8, err: ParseError };

pub fn decodeVarint(buf: []const u8) VarintResult {
    if (buf.len == 0) return .{ .val = 0, .len = 0, .err = .truncated };
    const prefix = buf[0] >> 6;
    const needed: u8 = @as(u8, 1) << @intCast(prefix);
    if (buf.len < needed) return .{ .val = 0, .len = 0, .err = .truncated };
    var val: u64 = buf[0] & 0x3F;
    for (1..needed) |i| {
        val = (val << 8) | buf[i];
    }
    return .{ .val = val, .len = needed, .err = .none };
}

// ── QUIC v2 Packet Type Swapping (RFC 9369 §3.1) ──

fn swapV2Type(pkt_type: PacketType) PacketType {
    return switch (pkt_type) {
        .initial => .retry,    // 0 ↔ 3
        .retry => .initial,
        .handshake => .zero_rtt, // 2 ↔ 1
        .zero_rtt => .handshake,
    };
}

// ── Packet Header Parsing ──

pub const default_short_cid_len: u8 = 8;

pub const HeaderResult = struct { header: PacketHeader, err: ParseError };

pub fn parseHeader(buf: []const u8) HeaderResult {
    var h = PacketHeader{};
    if (buf.len == 0) return .{ .header = h, .err = .truncated };

    h.is_long = (buf[0] & 0x80) != 0;

    if (h.is_long) {
        return parseLongHeader(buf, &h);
    } else {
        return parseShortHeader(buf, &h);
    }
}

fn parseLongHeader(buf: []const u8, h: *PacketHeader) HeaderResult {
    if (buf.len < 5) return .{ .header = h.*, .err = .truncated };

    // Version (bytes 1-4)
    h.version = @as(u32, buf[1]) << 24 | @as(u32, buf[2]) << 16 | @as(u32, buf[3]) << 8 | buf[4];

    // Raw type bits from first byte
    const raw_type: u2 = @truncate((buf[0] >> 4) & 0x03);
    var pkt_type: PacketType = @enumFromInt(raw_type);

    // QUIC v2 type swapping
    if (h.version == @intFromEnum(Version.quic_v2)) {
        pkt_type = swapV2Type(pkt_type);
    }
    h.pkt_type = pkt_type;

    var pos: usize = 5;

    // DCID
    if (pos >= buf.len) return .{ .header = h.*, .err = .truncated };
    const dcid_len = buf[pos];
    pos += 1;
    if (dcid_len > max_cid_len) return .{ .header = h.*, .err = .oversized_cid };
    if (pos + dcid_len > buf.len) return .{ .header = h.*, .err = .truncated };
    @memcpy(h.dst_cid.buf[0..dcid_len], buf[pos .. pos + dcid_len]);
    h.dst_cid.len = dcid_len;
    pos += dcid_len;

    // SCID
    if (pos >= buf.len) return .{ .header = h.*, .err = .truncated };
    const scid_len = buf[pos];
    pos += 1;
    if (scid_len > max_cid_len) return .{ .header = h.*, .err = .oversized_cid };
    if (pos + scid_len > buf.len) return .{ .header = h.*, .err = .truncated };
    @memcpy(h.src_cid.buf[0..scid_len], buf[pos .. pos + scid_len]);
    h.src_cid.len = scid_len;
    pos += scid_len;

    // Token (Initial packets only)
    if (pkt_type == .initial) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .header = h.*, .err = vr.err };
        pos += vr.len;
        const tlen: u16 = @intCast(vr.val);
        if (pos + tlen > buf.len) return .{ .header = h.*, .err = .truncated };
        if (tlen > 256) return .{ .header = h.*, .err = .malformed_frame };
        @memcpy(h.token[0..tlen], buf[pos .. pos + tlen]);
        h.token_len = tlen;
        pos += tlen;
    }

    // Length (varint) — for Initial, Handshake, 0-RTT (not Retry)
    if (pkt_type != .retry) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .header = h.*, .err = vr.err };
        pos += vr.len;
        h.payload_len = @intCast(vr.val);
    }

    h.payload_offset = @intCast(pos);
    return .{ .header = h.*, .err = .none };
}

fn parseShortHeader(buf: []const u8, h: *PacketHeader) HeaderResult {
    var pos: usize = 1;
    // DCID (fixed length, default 8)
    const cid_len = default_short_cid_len;
    if (pos + cid_len > buf.len) return .{ .header = h.*, .err = .truncated };
    @memcpy(h.dst_cid.buf[0..cid_len], buf[pos .. pos + cid_len]);
    h.dst_cid.len = cid_len;
    pos += cid_len;

    h.payload_offset = @intCast(pos);
    if (buf.len > pos) {
        h.payload_len = @intCast(buf.len - pos);
    }
    return .{ .header = h.*, .err = .none };
}

// ── Packet Header Serialization ──

pub const SerializeResult = struct { len: u16, err: ParseError };

pub fn serializeHeader(header: *const PacketHeader, out: []u8) SerializeResult {
    if (header.is_long) {
        return serializeLongHeader(header, out);
    } else {
        return serializeShortHeader(header, out);
    }
}

fn serializeLongHeader(h: *const PacketHeader, out: []u8) SerializeResult {
    var pos: usize = 0;

    // Determine wire type bits (apply v2 swap if needed)
    var wire_type = h.pkt_type;
    if (h.version == @intFromEnum(Version.quic_v2)) {
        wire_type = swapV2Type(wire_type);
    }

    // First byte: 1 (long) | 1 (fixed) | type(2) | reserved(4)
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[pos] = 0xC0 | (@as(u8, @intFromEnum(wire_type)) << 4);
    pos += 1;

    // Version (4 bytes)
    if (pos + 4 > out.len) return .{ .len = 0, .err = .truncated };
    out[pos] = @truncate(h.version >> 24);
    out[pos + 1] = @truncate(h.version >> 16);
    out[pos + 2] = @truncate(h.version >> 8);
    out[pos + 3] = @truncate(h.version);
    pos += 4;

    // DCID
    if (pos + 1 + h.dst_cid.len > out.len) return .{ .len = 0, .err = .truncated };
    out[pos] = h.dst_cid.len;
    pos += 1;
    @memcpy(out[pos .. pos + h.dst_cid.len], h.dst_cid.buf[0..h.dst_cid.len]);
    pos += h.dst_cid.len;

    // SCID
    if (pos + 1 + h.src_cid.len > out.len) return .{ .len = 0, .err = .truncated };
    out[pos] = h.src_cid.len;
    pos += 1;
    @memcpy(out[pos .. pos + h.src_cid.len], h.src_cid.buf[0..h.src_cid.len]);
    pos += h.src_cid.len;

    // Token (Initial only)
    if (h.pkt_type == .initial) {
        const vlen = encodeVarint(h.token_len, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
        if (pos + h.token_len > out.len) return .{ .len = 0, .err = .truncated };
        @memcpy(out[pos .. pos + h.token_len], h.token[0..h.token_len]);
        pos += h.token_len;
    }

    // Length (varint) — for non-Retry
    if (h.pkt_type != .retry) {
        const vlen = encodeVarint(h.payload_len, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
    }

    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeShortHeader(h: *const PacketHeader, out: []u8) SerializeResult {
    var pos: usize = 0;
    // First byte: 0 (short) | 1 (fixed) | reserved(6)
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[pos] = 0x40;
    pos += 1;

    // DCID
    if (pos + h.dst_cid.len > out.len) return .{ .len = 0, .err = .truncated };
    @memcpy(out[pos .. pos + h.dst_cid.len], h.dst_cid.buf[0..h.dst_cid.len]);
    pos += h.dst_cid.len;

    return .{ .len = @intCast(pos), .err = .none };
}

// ── Frame Parsing (RFC 9000 §19) ──

pub const FrameResult = struct { frame: Frame, consumed: u16, err: ParseError };

pub fn parseFrame(buf: []const u8, offset: u16) FrameResult {
    const off: usize = offset;
    if (off >= buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };

    const type_byte = buf[off];
    var pos: usize = off + 1;

    // PADDING (0x00)
    if (type_byte == 0x00) {
        return .{ .frame = .{ .padding = {} }, .consumed = @intCast(pos - off), .err = .none };
    }

    // PING (0x01)
    if (type_byte == 0x01) {
        return .{ .frame = .{ .ping = {} }, .consumed = @intCast(pos - off), .err = .none };
    }

    // ACK (0x02 / 0x03)
    if (type_byte == 0x02 or type_byte == 0x03) {
        return parseAckFrame(buf, off, pos);
    }

    // RESET_STREAM (0x04)
    if (type_byte == 0x04) {
        return parseResetStreamFrame(buf, off, pos);
    }

    // STOP_SENDING (0x05)
    if (type_byte == 0x05) {
        return parseStopSendingFrame(buf, off, pos);
    }

    // CRYPTO (0x06)
    if (type_byte == 0x06) {
        return parseCryptoFrame(buf, off, pos);
    }

    // NEW_TOKEN (0x07)
    if (type_byte == 0x07) {
        return parseNewTokenFrame(buf, off, pos);
    }

    // STREAM (0x08-0x0f)
    if (type_byte >= 0x08 and type_byte <= 0x0f) {
        return parseStreamFrame(buf, off, pos, type_byte);
    }

    // MAX_DATA (0x10)
    if (type_byte == 0x10) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .max_data = .{ .max = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // MAX_STREAM_DATA (0x11)
    if (type_byte == 0x11) {
        return parseMaxStreamDataFrame(buf, off, pos);
    }

    // MAX_STREAMS_BIDI (0x12)
    if (type_byte == 0x12) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .max_streams_bidi = .{ .max = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // MAX_STREAMS_UNI (0x13)
    if (type_byte == 0x13) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .max_streams_uni = .{ .max = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // DATA_BLOCKED (0x14)
    if (type_byte == 0x14) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .data_blocked = .{ .limit = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // STREAM_DATA_BLOCKED (0x15)
    if (type_byte == 0x15) {
        return parseStreamDataBlockedFrame(buf, off, pos);
    }

    // STREAMS_BLOCKED_BIDI (0x16)
    if (type_byte == 0x16) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .streams_blocked_bidi = .{ .limit = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // STREAMS_BLOCKED_UNI (0x17)
    if (type_byte == 0x17) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .streams_blocked_uni = .{ .limit = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // NEW_CONNECTION_ID (0x18)
    if (type_byte == 0x18) {
        return parseNewConnectionIdFrame(buf, off, pos);
    }

    // RETIRE_CONNECTION_ID (0x19)
    if (type_byte == 0x19) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        return .{ .frame = .{ .retire_connection_id = .{ .seq = vr.val } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // PATH_CHALLENGE (0x1a)
    if (type_byte == 0x1a) {
        if (pos + 8 > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
        var data: [8]u8 = undefined;
        @memcpy(&data, buf[pos .. pos + 8]);
        pos += 8;
        return .{ .frame = .{ .path_challenge = .{ .data = data } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // PATH_RESPONSE (0x1b)
    if (type_byte == 0x1b) {
        if (pos + 8 > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
        var data: [8]u8 = undefined;
        @memcpy(&data, buf[pos .. pos + 8]);
        pos += 8;
        return .{ .frame = .{ .path_response = .{ .data = data } }, .consumed = @intCast(pos - off), .err = .none };
    }

    // CONNECTION_CLOSE (0x1c / 0x1d)
    if (type_byte == 0x1c or type_byte == 0x1d) {
        return parseConnectionCloseFrame(buf, off, pos, type_byte);
    }

    // HANDSHAKE_DONE (0x1e)
    if (type_byte == 0x1e) {
        return .{ .frame = .{ .handshake_done = {} }, .consumed = @intCast(pos - off), .err = .none };
    }

    // DATAGRAM (0x30 / 0x31)
    if (type_byte == 0x30 or type_byte == 0x31) {
        return parseDatagramFrame(buf, off, pos, type_byte);
    }

    // Unknown frame type
    return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .malformed_frame };
}

fn parseAckFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    // largest_acked
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const largest_acked = vr.val;
    pos += vr.len;
    // ack_delay
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const ack_delay = vr.val;
    pos += vr.len;
    // range_count
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const range_count: u16 = @intCast(vr.val);
    pos += vr.len;
    // first_range
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const first_range = vr.val;
    pos += vr.len;

    var ranges: [max_ack_ranges]AckRange = [_]AckRange{.{}} ** max_ack_ranges;
    const count = @min(range_count, max_ack_ranges);
    for (0..count) |i| {
        // gap
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        ranges[i].gap = vr.val;
        pos += vr.len;
        // length
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        ranges[i].length = vr.val;
        pos += vr.len;
    }
    // Skip any ranges beyond max_ack_ranges
    for (count..range_count) |_| {
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        pos += vr.len;
    }

    return .{
        .frame = .{ .ack = .{
            .largest_acked = largest_acked,
            .ack_delay = ack_delay,
            .range_count = count,
            .first_range = first_range,
            .ranges = ranges,
        } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseResetStreamFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const stream_id = vr.val;
    pos += vr.len;
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const error_code = vr.val;
    pos += vr.len;
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const final_size = vr.val;
    pos += vr.len;
    return .{
        .frame = .{ .reset_stream = .{ .stream_id = stream_id, .error_code = error_code, .final_size = final_size } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseStopSendingFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const stream_id = vr.val;
    pos += vr.len;
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const error_code = vr.val;
    pos += vr.len;
    return .{
        .frame = .{ .stop_sending = .{ .stream_id = stream_id, .error_code = error_code } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseCryptoFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const crypto_offset = vr.val;
    pos += vr.len;
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const data_len: u16 = @intCast(vr.val);
    pos += vr.len;
    const data_offset: u16 = @intCast(pos);
    if (pos + data_len > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    pos += data_len;
    return .{
        .frame = .{ .crypto = .{ .offset = crypto_offset, .data_offset = data_offset, .data_len = data_len } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseNewTokenFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    const vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const token_len: u16 = @intCast(vr.val);
    pos += vr.len;
    const token_offset: u16 = @intCast(pos);
    if (pos + token_len > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    pos += token_len;
    return .{
        .frame = .{ .new_token = .{ .token_len = token_len, .token_offset = token_offset } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseStreamFrame(buf: []const u8, off: usize, start: usize, type_byte: u8) FrameResult {
    var pos = start;
    const fin = (type_byte & 0x01) != 0;
    const has_len = (type_byte & 0x02) != 0;
    const has_off = (type_byte & 0x04) != 0;

    // stream_id
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const stream_id = vr.val;
    pos += vr.len;

    // offset (optional)
    var stream_offset: u64 = 0;
    if (has_off) {
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        stream_offset = vr.val;
        pos += vr.len;
    }

    // length (optional)
    var data_len: u16 = undefined;
    if (has_len) {
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        data_len = @intCast(vr.val);
        pos += vr.len;
    } else {
        // No length field — data extends to end of buffer
        if (buf.len < pos) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
        data_len = @intCast(buf.len - pos);
    }

    const data_offset: u16 = @intCast(pos);
    if (pos + data_len > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    pos += data_len;

    return .{
        .frame = .{ .stream = .{
            .stream_id = stream_id,
            .offset = stream_offset,
            .data_offset = data_offset,
            .data_len = data_len,
            .fin = fin,
        } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseMaxStreamDataFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const stream_id = vr.val;
    pos += vr.len;
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const max = vr.val;
    pos += vr.len;
    return .{
        .frame = .{ .max_stream_data = .{ .stream_id = stream_id, .max = max } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseStreamDataBlockedFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const stream_id = vr.val;
    pos += vr.len;
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const limit = vr.val;
    pos += vr.len;
    return .{
        .frame = .{ .stream_data_blocked = .{ .stream_id = stream_id, .limit = limit } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseNewConnectionIdFrame(buf: []const u8, off: usize, start: usize) FrameResult {
    var pos = start;
    // seq
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const seq = vr.val;
    pos += vr.len;
    // retire_prior_to
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const retire_prior_to = vr.val;
    pos += vr.len;
    // CID length (1 byte, not varint)
    if (pos >= buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    const cid_len = buf[pos];
    pos += 1;
    if (cid_len > max_cid_len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .malformed_frame };
    if (pos + cid_len > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    var cid = ConnectionId{};
    @memcpy(cid.buf[0..cid_len], buf[pos .. pos + cid_len]);
    cid.len = cid_len;
    pos += cid_len;
    // 16-byte stateless reset token
    if (pos + 16 > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    var token: [16]u8 = undefined;
    @memcpy(&token, buf[pos .. pos + 16]);
    pos += 16;
    return .{
        .frame = .{ .new_connection_id = .{
            .seq = seq,
            .retire_prior_to = retire_prior_to,
            .cid = cid,
            .stateless_reset_token = token,
        } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseConnectionCloseFrame(buf: []const u8, off: usize, start: usize, type_byte: u8) FrameResult {
    var pos = start;
    // error_code
    var vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const error_code = vr.val;
    pos += vr.len;
    // frame_type (only for 0x1c, not 0x1d)
    var frame_type: u64 = 0;
    if (type_byte == 0x1c) {
        vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        frame_type = vr.val;
        pos += vr.len;
    }
    // reason_len
    vr = decodeVarint(buf[pos..]);
    if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
    const reason_len: u16 = @intCast(vr.val);
    pos += vr.len;
    const reason_offset: u16 = @intCast(pos);
    if (pos + reason_len > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    pos += reason_len;
    return .{
        .frame = .{ .connection_close = .{
            .error_code = error_code,
            .frame_type = frame_type,
            .reason_offset = reason_offset,
            .reason_len = reason_len,
        } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

fn parseDatagramFrame(buf: []const u8, off: usize, start: usize, type_byte: u8) FrameResult {
    var pos = start;
    const has_len = (type_byte == 0x31);
    var data_len: u16 = undefined;
    if (has_len) {
        const vr = decodeVarint(buf[pos..]);
        if (vr.err != .none) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = vr.err };
        data_len = @intCast(vr.val);
        pos += vr.len;
    } else {
        // No length field — data extends to end of buffer
        if (buf.len < pos) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
        data_len = @intCast(buf.len - pos);
    }
    const data_offset: u16 = @intCast(pos);
    if (pos + data_len > buf.len) return .{ .frame = .{ .padding = {} }, .consumed = 0, .err = .truncated };
    pos += data_len;
    return .{
        .frame = .{ .datagram = .{ .data_offset = data_offset, .data_len = data_len } },
        .consumed = @intCast(pos - off),
        .err = .none,
    };
}

// ── Frame Serialization (RFC 9000 §19) ──

pub fn serializeFrame(frame: *const Frame, out: []u8) SerializeResult {
    return switch (frame.*) {
        .padding => serializeSingleByte(0x00, out),
        .ping => serializeSingleByte(0x01, out),
        .ack => |a| serializeAckFrame(&a, out),
        .reset_stream => |r| serializeResetStreamFrame(&r, out),
        .stop_sending => |s| serializeStopSendingFrame(&s, out),
        .crypto => |c| serializeCryptoFrame(&c, out),
        .new_token => |t| serializeNewTokenFrame(&t, out),
        .stream => |s| serializeStreamFrameData(&s, out),
        .max_data => |m| serializeOneVarintFrame(0x10, m.max, out),
        .max_stream_data => |m| serializeTwoVarintFrame(0x11, m.stream_id, m.max, out),
        .max_streams_bidi => |m| serializeOneVarintFrame(0x12, m.max, out),
        .max_streams_uni => |m| serializeOneVarintFrame(0x13, m.max, out),
        .data_blocked => |d| serializeOneVarintFrame(0x14, d.limit, out),
        .stream_data_blocked => |d| serializeTwoVarintFrame(0x15, d.stream_id, d.limit, out),
        .streams_blocked_bidi => |s| serializeOneVarintFrame(0x16, s.limit, out),
        .streams_blocked_uni => |s| serializeOneVarintFrame(0x17, s.limit, out),
        .new_connection_id => |n| serializeNewConnectionIdFrame(&n, out),
        .retire_connection_id => |r| serializeOneVarintFrame(0x19, r.seq, out),
        .path_challenge => |p| serializePathFrame(0x1a, &p.data, out),
        .path_response => |p| serializePathFrame(0x1b, &p.data, out),
        .connection_close => |c| serializeConnectionCloseFrame(&c, out),
        .handshake_done => serializeSingleByte(0x1e, out),
        .datagram => |d| serializeDatagramFrame(&d, out),
    };
}

fn serializeSingleByte(type_byte: u8, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = type_byte;
    return .{ .len = 1, .err = .none };
}

fn serializeOneVarintFrame(type_byte: u8, val: u64, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = type_byte;
    var pos: usize = 1;
    const vlen = encodeVarint(val, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeTwoVarintFrame(type_byte: u8, val1: u64, val2: u64, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = type_byte;
    var pos: usize = 1;
    var vlen = encodeVarint(val1, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(val2, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeAckFrame(a: anytype, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x02; // ACK (no ECN)
    var pos: usize = 1;
    var vlen = encodeVarint(a.largest_acked, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(a.ack_delay, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(a.range_count, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(a.first_range, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    for (0..a.range_count) |i| {
        vlen = encodeVarint(a.ranges[i].gap, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
        vlen = encodeVarint(a.ranges[i].length, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
    }
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeResetStreamFrame(r: anytype, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x04;
    var pos: usize = 1;
    var vlen = encodeVarint(r.stream_id, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(r.error_code, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(r.final_size, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeStopSendingFrame(s: anytype, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x05;
    var pos: usize = 1;
    var vlen = encodeVarint(s.stream_id, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(s.error_code, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeCryptoFrame(c: anytype, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x06;
    var pos: usize = 1;
    var vlen = encodeVarint(c.offset, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(c.data_len, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    // Note: data_offset refers to the original buffer; serialization writes
    // only the frame header (type + offset + length). The caller is responsible
    // for copying the actual crypto data after this header.
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeNewTokenFrame(t: anytype, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x07;
    var pos: usize = 1;
    const vlen = encodeVarint(t.token_len, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    // token_offset refers to the original buffer; caller copies token data.
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeStreamFrameData(s: anytype, out: []u8) SerializeResult {
    // Build type byte: 0x08 base | OFF(bit2) | LEN(bit1) | FIN(bit0)
    var type_byte: u8 = 0x08;
    if (s.fin) type_byte |= 0x01;
    if (s.data_len > 0 or s.offset > 0) type_byte |= 0x02; // always include LEN when we have data
    if (s.offset > 0) type_byte |= 0x04;

    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = type_byte;
    var pos: usize = 1;

    // stream_id
    var vlen = encodeVarint(s.stream_id, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;

    // offset (if present)
    if (s.offset > 0) {
        vlen = encodeVarint(s.offset, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
    }

    // length (if LEN bit set)
    if ((type_byte & 0x02) != 0) {
        vlen = encodeVarint(s.data_len, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
    }

    // data_offset refers to the original buffer; caller copies stream data.
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeNewConnectionIdFrame(n: anytype, out: []u8) SerializeResult {
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x18;
    var pos: usize = 1;
    var vlen = encodeVarint(n.seq, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    vlen = encodeVarint(n.retire_prior_to, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    // CID length (1 byte, not varint)
    if (pos >= out.len) return .{ .len = 0, .err = .truncated };
    out[pos] = n.cid.len;
    pos += 1;
    // CID bytes
    if (pos + n.cid.len > out.len) return .{ .len = 0, .err = .truncated };
    @memcpy(out[pos .. pos + n.cid.len], n.cid.buf[0..n.cid.len]);
    pos += n.cid.len;
    // 16-byte stateless reset token
    if (pos + 16 > out.len) return .{ .len = 0, .err = .truncated };
    @memcpy(out[pos .. pos + 16], &n.stateless_reset_token);
    pos += 16;
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializePathFrame(type_byte: u8, data: *const [8]u8, out: []u8) SerializeResult {
    if (out.len < 9) return .{ .len = 0, .err = .truncated };
    out[0] = type_byte;
    @memcpy(out[1..9], data);
    return .{ .len = 9, .err = .none };
}

fn serializeConnectionCloseFrame(c: anytype, out: []u8) SerializeResult {
    // Use 0x1c if frame_type is set (transport error), 0x1d for app error
    const is_transport = (c.frame_type != 0 or c.reason_len > 0 or c.error_code != 0);
    const type_byte: u8 = if (is_transport) 0x1c else 0x1d;

    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = type_byte;
    var pos: usize = 1;

    var vlen = encodeVarint(c.error_code, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;

    if (type_byte == 0x1c) {
        vlen = encodeVarint(c.frame_type, out[pos..]);
        if (vlen == 0) return .{ .len = 0, .err = .truncated };
        pos += vlen;
    }

    vlen = encodeVarint(c.reason_len, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;

    // reason_offset refers to the original buffer; caller copies reason data.
    return .{ .len = @intCast(pos), .err = .none };
}

fn serializeDatagramFrame(d: anytype, out: []u8) SerializeResult {
    // Always use 0x31 (with length) for serialization — safer for framing
    if (out.len < 1) return .{ .len = 0, .err = .truncated };
    out[0] = 0x31;
    var pos: usize = 1;
    const vlen = encodeVarint(d.data_len, out[pos..]);
    if (vlen == 0) return .{ .len = 0, .err = .truncated };
    pos += vlen;
    // data_offset refers to the original buffer; caller copies datagram data.
    return .{ .len = @intCast(pos), .err = .none };
}

// ── Unit Tests ──

const testing = @import("std").testing;

// ── 5.6: Variable-Length Integer Round-Trip Tests ──

test "varint round-trip boundary values" {
    const boundary_values = [_]u64{
        0,                    // 1-byte min
        63,                   // 1-byte max
        64,                   // 2-byte min
        16383,                // 2-byte max
        16384,                // 4-byte min
        1073741823,           // 4-byte max
        1073741824,           // 8-byte min
        4611686018427387903,  // 8-byte max (2^62-1)
    };
    const expected_lens = [_]u8{ 1, 1, 2, 2, 4, 4, 8, 8 };

    for (boundary_values, expected_lens) |val, exp_len| {
        var buf: [8]u8 = undefined;
        const written = encodeVarint(val, &buf);
        try testing.expectEqual(exp_len, written);

        const result = decodeVarint(buf[0..written]);
        try testing.expectEqual(ParseError.none, result.err);
        try testing.expectEqual(val, result.val);
        try testing.expectEqual(exp_len, result.len);
    }
}

test "varint overflow returns 0" {
    var buf: [8]u8 = undefined;
    // 2^62 is too large
    const written = encodeVarint(4611686018427387904, &buf);
    try testing.expectEqual(@as(u8, 0), written);
    // max u64 is too large
    const written2 = encodeVarint(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqual(@as(u8, 0), written2);
}

test "varint decode empty buffer returns truncated" {
    const empty: []const u8 = &.{};
    const result = decodeVarint(empty);
    try testing.expectEqual(ParseError.truncated, result.err);
}

test "varint decode truncated buffer returns truncated" {
    // Encode a 2-byte varint, then try to decode from only 1 byte
    var buf: [8]u8 = undefined;
    const written = encodeVarint(64, &buf); // 2-byte encoding
    try testing.expectEqual(@as(u8, 2), written);
    const result = decodeVarint(buf[0..1]);
    try testing.expectEqual(ParseError.truncated, result.err);

    // Encode a 4-byte varint, try to decode from 2 bytes
    const written4 = encodeVarint(16384, &buf);
    try testing.expectEqual(@as(u8, 4), written4);
    const result4 = decodeVarint(buf[0..2]);
    try testing.expectEqual(ParseError.truncated, result4.err);

    // Encode an 8-byte varint, try to decode from 4 bytes
    const written8 = encodeVarint(1073741824, &buf);
    try testing.expectEqual(@as(u8, 8), written8);
    const result8 = decodeVarint(buf[0..4]);
    try testing.expectEqual(ParseError.truncated, result8.err);
}

test "varint encode into too-small buffer returns 0" {
    var tiny: [0]u8 = undefined;
    try testing.expectEqual(@as(u8, 0), encodeVarint(0, &tiny));

    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(u8, 0), encodeVarint(64, &one)); // needs 2 bytes
}

// ── 5.7: Packet Header Round-Trip Tests ──

fn makeCid(len: u8) ConnectionId {
    var cid = ConnectionId{};
    cid.len = len;
    for (0..len) |i| {
        cid.buf[i] = @truncate(i + 0xA0);
    }
    return cid;
}

test "long header round-trip: Initial" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .initial;
    h.dst_cid = makeCid(8);
    h.src_cid = makeCid(8);
    h.token_len = 0;
    h.payload_len = 100;

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);
    try testing.expect(sr.len > 0);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expect(pr.header.is_long);
    try testing.expectEqual(h.version, pr.header.version);
    try testing.expectEqual(PacketType.initial, pr.header.pkt_type);
    try testing.expectEqualSlices(u8, h.dst_cid.buf[0..h.dst_cid.len], pr.header.dst_cid.buf[0..pr.header.dst_cid.len]);
    try testing.expectEqualSlices(u8, h.src_cid.buf[0..h.src_cid.len], pr.header.src_cid.buf[0..pr.header.src_cid.len]);
    try testing.expectEqual(h.payload_len, pr.header.payload_len);
}

test "long header round-trip: Handshake" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .handshake;
    h.dst_cid = makeCid(8);
    h.src_cid = makeCid(8);
    h.payload_len = 50;

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(PacketType.handshake, pr.header.pkt_type);
    try testing.expectEqual(h.payload_len, pr.header.payload_len);
}

test "long header round-trip: 0-RTT" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .zero_rtt;
    h.dst_cid = makeCid(8);
    h.src_cid = makeCid(8);
    h.payload_len = 200;

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(PacketType.zero_rtt, pr.header.pkt_type);
}

test "long header round-trip: Retry" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .retry;
    h.dst_cid = makeCid(8);
    h.src_cid = makeCid(8);
    // Retry has no payload_len field

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(PacketType.retry, pr.header.pkt_type);
}

test "short header round-trip: 1-RTT" {
    var h = PacketHeader{};
    h.is_long = false;
    h.dst_cid = makeCid(default_short_cid_len);

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);
    try testing.expectEqual(@as(u16, 1 + default_short_cid_len), sr.len);

    // Parse needs at least 1 + default_short_cid_len bytes
    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expect(!pr.header.is_long);
    try testing.expectEqualSlices(u8, h.dst_cid.buf[0..h.dst_cid.len], pr.header.dst_cid.buf[0..pr.header.dst_cid.len]);
}

test "header round-trip: CID length 0" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .handshake;
    h.dst_cid = makeCid(0);
    h.src_cid = makeCid(0);
    h.payload_len = 10;

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u8, 0), pr.header.dst_cid.len);
    try testing.expectEqual(@as(u8, 0), pr.header.src_cid.len);
}

test "header round-trip: CID length 20" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .handshake;
    h.dst_cid = makeCid(20);
    h.src_cid = makeCid(20);
    h.payload_len = 10;

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u8, 20), pr.header.dst_cid.len);
    try testing.expectEqual(@as(u8, 20), pr.header.src_cid.len);
    try testing.expectEqualSlices(u8, h.dst_cid.buf[0..20], pr.header.dst_cid.buf[0..20]);
    try testing.expectEqualSlices(u8, h.src_cid.buf[0..20], pr.header.src_cid.buf[0..20]);
}

test "header round-trip: Initial with token" {
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v1);
    h.pkt_type = .initial;
    h.dst_cid = makeCid(8);
    h.src_cid = makeCid(8);
    h.token_len = 16;
    for (0..16) |i| {
        h.token[i] = @truncate(i + 0x10);
    }
    h.payload_len = 100;

    var buf: [256]u8 = undefined;
    const sr = serializeHeader(&h, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseHeader(buf[0..sr.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u16, 16), pr.header.token_len);
    try testing.expectEqualSlices(u8, h.token[0..16], pr.header.token[0..16]);
}

test "header error: truncated buffer" {
    const pr = parseHeader(&.{});
    try testing.expectEqual(ParseError.truncated, pr.err);

    // Long header with only 3 bytes (need at least 5 for version)
    const pr2 = parseHeader(&[_]u8{ 0xC0, 0x00, 0x00 });
    try testing.expectEqual(ParseError.truncated, pr2.err);

    // Short header with only 2 bytes (need 1 + 8 for default CID)
    const pr3 = parseHeader(&[_]u8{ 0x40, 0x01 });
    try testing.expectEqual(ParseError.truncated, pr3.err);
}

test "header error: oversized CID" {
    // Craft a long header with DCID length = 21 (> max_cid_len)
    var buf: [64]u8 = [_]u8{0} ** 64;
    buf[0] = 0xC0; // long header, Initial type
    buf[1] = 0x00;
    buf[2] = 0x00;
    buf[3] = 0x00;
    buf[4] = 0x01; // version = quic_v1
    buf[5] = 21; // DCID length = 21 (too large)

    const pr = parseHeader(&buf);
    try testing.expectEqual(ParseError.oversized_cid, pr.err);
}

test "header QUIC v2 packet type swapping" {
    // Serialize a v2 Initial
    var h = PacketHeader{};
    h.is_long = true;
    h.version = @intFromEnum(Version.quic_v2);
    h.pkt_type = .initial;
    h.dst_cid = makeCid(8);
    h.src_cid = makeCid(8);
    h.token_len = 0;
    h.payload_len = 50;

    var buf_v2: [256]u8 = undefined;
    const sr_v2 = serializeHeader(&h, &buf_v2);
    try testing.expectEqual(ParseError.none, sr_v2.err);

    // Serialize a v1 Initial with same fields
    h.version = @intFromEnum(Version.quic_v1);
    var buf_v1: [256]u8 = undefined;
    const sr_v1 = serializeHeader(&h, &buf_v1);
    try testing.expectEqual(ParseError.none, sr_v1.err);

    // The type bits in the first byte should differ (v2 swaps Initial↔Retry)
    const v2_type_bits = (buf_v2[0] >> 4) & 0x03;
    const v1_type_bits = (buf_v1[0] >> 4) & 0x03;
    try testing.expect(v2_type_bits != v1_type_bits);

    // Parse the v2 packet back — should recover .initial
    h.version = @intFromEnum(Version.quic_v2);
    const pr = parseHeader(buf_v2[0..sr_v2.len]);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(PacketType.initial, pr.header.pkt_type);
    try testing.expectEqual(@intFromEnum(Version.quic_v2), pr.header.version);
}

// ── 5.8: Frame Round-Trip Tests ──

test "frame round-trip: PADDING" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .padding = {} };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);
    try testing.expectEqual(@as(u16, 1), sr.len);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u16, 1), pr.consumed);
    try testing.expect(pr.frame == .padding);
}

test "frame round-trip: PING" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .ping = {} };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expect(pr.frame == .ping);
}

test "frame round-trip: ACK with 0 ranges" {
    var buf: [256]u8 = undefined;
    const frame = Frame{ .ack = .{
        .largest_acked = 100,
        .ack_delay = 25000,
        .range_count = 0,
        .first_range = 10,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const ack = pr.frame.ack;
    try testing.expectEqual(@as(u64, 100), ack.largest_acked);
    try testing.expectEqual(@as(u64, 25000), ack.ack_delay);
    try testing.expectEqual(@as(u16, 0), ack.range_count);
    try testing.expectEqual(@as(u64, 10), ack.first_range);
}

test "frame round-trip: ACK with 1 range" {
    var buf: [256]u8 = undefined;
    var frame = Frame{ .ack = .{
        .largest_acked = 200,
        .ack_delay = 5000,
        .range_count = 1,
        .first_range = 5,
    } };
    frame.ack.ranges[0] = .{ .gap = 2, .length = 3 };

    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const ack = pr.frame.ack;
    try testing.expectEqual(@as(u16, 1), ack.range_count);
    try testing.expectEqual(@as(u64, 2), ack.ranges[0].gap);
    try testing.expectEqual(@as(u64, 3), ack.ranges[0].length);
}

test "frame round-trip: ACK with 64 ranges" {
    var buf: [2048]u8 = undefined;
    var frame = Frame{ .ack = .{
        .largest_acked = 1000,
        .ack_delay = 100,
        .range_count = 64,
        .first_range = 1,
    } };
    for (0..64) |i| {
        frame.ack.ranges[i] = .{ .gap = @intCast(i), .length = @intCast(i + 1) };
    }

    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const ack = pr.frame.ack;
    try testing.expectEqual(@as(u16, 64), ack.range_count);
    for (0..64) |i| {
        try testing.expectEqual(@as(u64, @intCast(i)), ack.ranges[i].gap);
        try testing.expectEqual(@as(u64, @intCast(i + 1)), ack.ranges[i].length);
    }
}

test "frame round-trip: RESET_STREAM" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .reset_stream = .{ .stream_id = 4, .error_code = 0x0A, .final_size = 1024 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const rs = pr.frame.reset_stream;
    try testing.expectEqual(@as(u64, 4), rs.stream_id);
    try testing.expectEqual(@as(u64, 0x0A), rs.error_code);
    try testing.expectEqual(@as(u64, 1024), rs.final_size);
}

test "frame round-trip: STOP_SENDING" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .stop_sending = .{ .stream_id = 8, .error_code = 0x0B } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const ss = pr.frame.stop_sending;
    try testing.expectEqual(@as(u64, 8), ss.stream_id);
    try testing.expectEqual(@as(u64, 0x0B), ss.error_code);
}

test "frame round-trip: CRYPTO" {
    var buf: [64]u8 = undefined;
    // Serialization writes type + offset + data_len (no actual data bytes)
    const frame = Frame{ .crypto = .{ .offset = 0, .data_offset = 0, .data_len = 32 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // Append dummy data bytes so parser can consume them
    const header_len = sr.len;
    for (0..32) |i| {
        buf[header_len + i] = @truncate(i);
    }
    const total_len = header_len + 32;

    const pr = parseFrame(buf[0..total_len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const c = pr.frame.crypto;
    try testing.expectEqual(@as(u64, 0), c.offset);
    try testing.expectEqual(@as(u16, 32), c.data_len);
    // data_offset will point into the serialized buffer (differs from original)
}

test "frame round-trip: NEW_TOKEN" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .new_token = .{ .token_len = 16, .token_offset = 0 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // Append dummy token bytes
    const header_len = sr.len;
    for (0..16) |i| {
        buf[header_len + i] = @truncate(i + 0x50);
    }
    const total_len = header_len + 16;

    const pr = parseFrame(buf[0..total_len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const nt = pr.frame.new_token;
    try testing.expectEqual(@as(u16, 16), nt.token_len);
}

test "frame round-trip: STREAM with offset and length and FIN" {
    var buf: [64]u8 = undefined;
    // offset > 0 and data_len > 0 → serializer sets OFF and LEN bits
    const frame = Frame{ .stream = .{
        .stream_id = 4,
        .offset = 100,
        .data_offset = 0,
        .data_len = 10,
        .fin = true,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // Append dummy stream data
    const header_len = sr.len;
    for (0..10) |i| {
        buf[header_len + i] = @truncate(i);
    }
    const total_len = header_len + 10;

    const pr = parseFrame(buf[0..total_len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const s = pr.frame.stream;
    try testing.expectEqual(@as(u64, 4), s.stream_id);
    try testing.expectEqual(@as(u64, 100), s.offset);
    try testing.expectEqual(@as(u16, 10), s.data_len);
    try testing.expect(s.fin);
}

test "frame round-trip: STREAM without offset, with data, no FIN" {
    var buf: [64]u8 = undefined;
    // offset = 0, data_len > 0 → serializer sets LEN bit but not OFF bit
    const frame = Frame{ .stream = .{
        .stream_id = 12,
        .offset = 0,
        .data_offset = 0,
        .data_len = 5,
        .fin = false,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // Append dummy stream data
    const header_len = sr.len;
    for (0..5) |i| {
        buf[header_len + i] = @truncate(i);
    }
    const total_len = header_len + 5;

    const pr = parseFrame(buf[0..total_len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const s = pr.frame.stream;
    try testing.expectEqual(@as(u64, 12), s.stream_id);
    try testing.expectEqual(@as(u64, 0), s.offset);
    try testing.expectEqual(@as(u16, 5), s.data_len);
    try testing.expect(!s.fin);
}

test "frame round-trip: STREAM FIN-only (no data, no offset)" {
    var buf: [64]u8 = undefined;
    // data_len = 0, offset = 0 → serializer does NOT set LEN or OFF bits, just FIN
    const frame = Frame{ .stream = .{
        .stream_id = 4,
        .offset = 0,
        .data_offset = 0,
        .data_len = 0,
        .fin = true,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // No LEN bit → parser reads data to end of buffer, so pass exact serialized length
    const pr = parseFrame(buf[0..sr.len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const s = pr.frame.stream;
    try testing.expectEqual(@as(u64, 4), s.stream_id);
    try testing.expect(s.fin);
    try testing.expectEqual(@as(u16, 0), s.data_len);
}

test "frame round-trip: MAX_DATA" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .max_data = .{ .max = 1048576 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 1048576), pr.frame.max_data.max);
}

test "frame round-trip: MAX_STREAM_DATA" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .max_stream_data = .{ .stream_id = 4, .max = 65536 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 4), pr.frame.max_stream_data.stream_id);
    try testing.expectEqual(@as(u64, 65536), pr.frame.max_stream_data.max);
}

test "frame round-trip: MAX_STREAMS_BIDI" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .max_streams_bidi = .{ .max = 100 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 100), pr.frame.max_streams_bidi.max);
}

test "frame round-trip: MAX_STREAMS_UNI" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .max_streams_uni = .{ .max = 50 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 50), pr.frame.max_streams_uni.max);
}

test "frame round-trip: DATA_BLOCKED" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .data_blocked = .{ .limit = 999 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 999), pr.frame.data_blocked.limit);
}

test "frame round-trip: STREAM_DATA_BLOCKED" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .stream_data_blocked = .{ .stream_id = 8, .limit = 4096 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 8), pr.frame.stream_data_blocked.stream_id);
    try testing.expectEqual(@as(u64, 4096), pr.frame.stream_data_blocked.limit);
}

test "frame round-trip: STREAMS_BLOCKED_BIDI" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .streams_blocked_bidi = .{ .limit = 10 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 10), pr.frame.streams_blocked_bidi.limit);
}

test "frame round-trip: STREAMS_BLOCKED_UNI" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .streams_blocked_uni = .{ .limit = 20 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 20), pr.frame.streams_blocked_uni.limit);
}

test "frame round-trip: NEW_CONNECTION_ID" {
    var buf: [128]u8 = undefined;
    var cid = ConnectionId{};
    cid.len = 8;
    for (0..8) |i| {
        cid.buf[i] = @truncate(i + 0xC0);
    }
    var token: [16]u8 = undefined;
    for (0..16) |i| {
        token[i] = @truncate(i + 0xD0);
    }
    const frame = Frame{ .new_connection_id = .{
        .seq = 1,
        .retire_prior_to = 0,
        .cid = cid,
        .stateless_reset_token = token,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const nc = pr.frame.new_connection_id;
    try testing.expectEqual(@as(u64, 1), nc.seq);
    try testing.expectEqual(@as(u64, 0), nc.retire_prior_to);
    try testing.expectEqual(@as(u8, 8), nc.cid.len);
    try testing.expectEqualSlices(u8, cid.buf[0..8], nc.cid.buf[0..8]);
    try testing.expectEqualSlices(u8, &token, &nc.stateless_reset_token);
}

test "frame round-trip: RETIRE_CONNECTION_ID" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .retire_connection_id = .{ .seq = 3 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u64, 3), pr.frame.retire_connection_id.seq);
}

test "frame round-trip: PATH_CHALLENGE" {
    var buf: [64]u8 = undefined;
    const data = [8]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const frame = Frame{ .path_challenge = .{ .data = data } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqualSlices(u8, &data, &pr.frame.path_challenge.data);
}

test "frame round-trip: PATH_RESPONSE" {
    var buf: [64]u8 = undefined;
    const data = [8]u8{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8 };
    const frame = Frame{ .path_response = .{ .data = data } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqualSlices(u8, &data, &pr.frame.path_response.data);
}

test "frame round-trip: CONNECTION_CLOSE with reason" {
    var buf: [64]u8 = undefined;
    // error_code != 0 → serializer uses 0x1c (transport), includes frame_type field
    const frame = Frame{ .connection_close = .{
        .error_code = 0x0A,
        .frame_type = 0x06,
        .reason_offset = 0,
        .reason_len = 5,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // Append dummy reason bytes
    const header_len = sr.len;
    @memcpy(buf[header_len .. header_len + 5], "hello");
    const total_len = header_len + 5;

    const pr = parseFrame(buf[0..total_len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const cc = pr.frame.connection_close;
    try testing.expectEqual(@as(u64, 0x0A), cc.error_code);
    try testing.expectEqual(@as(u64, 0x06), cc.frame_type);
    try testing.expectEqual(@as(u16, 5), cc.reason_len);
}

test "frame round-trip: CONNECTION_CLOSE without reason (app error)" {
    var buf: [64]u8 = undefined;
    // All zeros → serializer uses 0x1d (app close), no frame_type field
    const frame = Frame{ .connection_close = .{
        .error_code = 0,
        .frame_type = 0,
        .reason_offset = 0,
        .reason_len = 0,
    } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(buf[0..sr.len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    const cc = pr.frame.connection_close;
    try testing.expectEqual(@as(u64, 0), cc.error_code);
    try testing.expectEqual(@as(u16, 0), cc.reason_len);
}

test "frame round-trip: HANDSHAKE_DONE" {
    var buf: [64]u8 = undefined;
    const frame = Frame{ .handshake_done = {} };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expect(pr.frame == .handshake_done);
}

test "frame round-trip: DATAGRAM with length" {
    var buf: [64]u8 = undefined;
    // Serializer always uses 0x31 (with length)
    const frame = Frame{ .datagram = .{ .data_offset = 0, .data_len = 10 } };
    const sr = serializeFrame(&frame, &buf);
    try testing.expectEqual(ParseError.none, sr.err);

    // Append dummy datagram data
    const header_len = sr.len;
    for (0..10) |i| {
        buf[header_len + i] = @truncate(i + 0x30);
    }
    const total_len = header_len + 10;

    const pr = parseFrame(buf[0..total_len], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u16, 10), pr.frame.datagram.data_len);
}

test "frame round-trip: DATAGRAM without length (parse 0x30)" {
    // Manually craft a 0x30 datagram frame (no length field, data to end of buffer)
    var buf: [16]u8 = undefined;
    buf[0] = 0x30; // datagram without length
    for (1..11) |i| {
        buf[i] = @truncate(i);
    }

    const pr = parseFrame(buf[0..11], 0);
    try testing.expectEqual(ParseError.none, pr.err);
    try testing.expectEqual(@as(u16, 10), pr.frame.datagram.data_len);
}

test "frame error: truncated frame data" {
    // ACK frame with only the type byte, no fields
    var buf = [_]u8{0x02};
    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.truncated, pr.err);

    // PATH_CHALLENGE with only 4 bytes of data (needs 8)
    var buf2: [5]u8 = undefined;
    buf2[0] = 0x1a;
    const pr2 = parseFrame(&buf2, 0);
    try testing.expectEqual(ParseError.truncated, pr2.err);
}

test "frame error: unknown frame type returns malformed_frame" {
    var buf = [_]u8{0xFF};
    const pr = parseFrame(&buf, 0);
    try testing.expectEqual(ParseError.malformed_frame, pr.err);

    var buf2 = [_]u8{0x20}; // not a valid frame type
    const pr2 = parseFrame(&buf2, 0);
    try testing.expectEqual(ParseError.malformed_frame, pr2.err);
}
