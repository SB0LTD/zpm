//! UDP Layer (RFC 768)
//!
//! Encapsulation, decapsulation, port binding table, and dispatch.
//! Zero allocation — static port table, caller-provided buffers.
//!
//! UDP header: src_port(2) + dst_port(2) + length(2) + checksum(2) = 8 bytes

const checksum = @import("checksum.sig");
const ipv4 = @import("ipv4.sig");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const HEADER_SIZE: usize = 8;
pub const MAX_PAYLOAD: usize = ipv4.MAX_PACKET_SIZE - ipv4.HEADER_SIZE - HEADER_SIZE; // 1472

// ══════════════════════════════════════════════════════════════════════════════
// UDP Header
// ══════════════════════════════════════════════════════════════════════════════

pub const Header = struct {
    src_port: u16,
    dst_port: u16,
    length: u16, // Header + payload
    checksum_val: u16,

    /// Parse a UDP header from the IP payload.
    pub fn parse(data: []const u8) ?Header {
        if (data.len < HEADER_SIZE) return null;
        return .{
            .src_port = @as(u16, data[0]) << 8 | data[1],
            .dst_port = @as(u16, data[2]) << 8 | data[3],
            .length = @as(u16, data[4]) << 8 | data[5],
            .checksum_val = @as(u16, data[6]) << 8 | data[7],
        };
    }

    /// Get the UDP payload (data after the 8-byte header).
    pub fn payload(self: *const Header, data: []const u8) ?[]const u8 {
        if (data.len < self.length) return null;
        if (self.length <= HEADER_SIZE) return null;
        return data[HEADER_SIZE..self.length];
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Datagram Parsing with Checksum Verification
// ══════════════════════════════════════════════════════════════════════════════

/// Parsed UDP datagram with metadata.
pub const Datagram = struct {
    src_port: u16,
    dst_port: u16,
    payload_data: []const u8,
};

/// Parse and verify a UDP datagram from an IPv4 payload.
/// Validates the UDP checksum using the IPv4 pseudo-header.
/// Returns the parsed datagram, or null if invalid.
pub fn parseDatagram(
    udp_data: []const u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
) ?Datagram {
    const hdr = Header.parse(udp_data) orelse return null;

    if (hdr.length < HEADER_SIZE) return null;
    if (hdr.length > udp_data.len) return null;

    // Verify checksum (if non-zero; zero means "no checksum")
    if (hdr.checksum_val != 0) {
        var acc = checksum.pseudoHeaderSum(src_ip, dst_ip, ipv4.PROTO_UDP, hdr.length);
        acc = checksum.combine(acc, checksum.sum(udp_data[0..hdr.length]));
        if (checksum.fold(acc) != 0) return null;
    }

    const payload_len = hdr.length - HEADER_SIZE;
    return .{
        .src_port = hdr.src_port,
        .dst_port = hdr.dst_port,
        .payload_data = udp_data[HEADER_SIZE..][0..payload_len],
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Datagram Construction
// ══════════════════════════════════════════════════════════════════════════════

/// Build a UDP datagram (header + payload) in `buf`.
/// Computes the UDP checksum using the IPv4 pseudo-header.
/// Returns the total UDP segment length (header + payload), or null on error.
///
/// NOTE: This writes only the UDP portion. Caller wraps with IPv4 + Ethernet.
pub fn buildDatagram(
    buf: []u8,
    src_port: u16,
    dst_port: u16,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    payload_data: []const u8,
) ?usize {
    const udp_len = HEADER_SIZE + payload_data.len;
    if (udp_len > buf.len) return null;
    if (payload_data.len > MAX_PAYLOAD) return null;

    const length: u16 = @intCast(udp_len);

    // Source port
    buf[0] = @intCast(src_port >> 8);
    buf[1] = @intCast(src_port & 0xFF);
    // Destination port
    buf[2] = @intCast(dst_port >> 8);
    buf[3] = @intCast(dst_port & 0xFF);
    // Length
    buf[4] = @intCast(length >> 8);
    buf[5] = @intCast(length & 0xFF);
    // Checksum (zeroed for computation)
    buf[6] = 0;
    buf[7] = 0;
    // Payload
    @memcpy(buf[HEADER_SIZE..][0..payload_data.len], payload_data);

    // Compute UDP checksum with pseudo-header
    var acc = checksum.pseudoHeaderSum(src_ip, dst_ip, ipv4.PROTO_UDP, length);
    acc = checksum.combine(acc, checksum.sum(buf[0..udp_len]));
    const cksum = checksum.fold(acc);
    // RFC 768: if computed checksum is 0, transmit as 0xFFFF
    const final_cksum: u16 = if (cksum == 0) 0xFFFF else cksum;
    buf[6] = @intCast(final_cksum >> 8);
    buf[7] = @intCast(final_cksum & 0xFF);

    return udp_len;
}

/// Build a complete IPv4+UDP packet in `buf`.
/// Returns total packet length (IPv4 header + UDP header + payload), or null on error.
pub fn buildPacket(
    buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    payload_data: []const u8,
) ?usize {
    const udp_len = HEADER_SIZE + payload_data.len;
    const total_len = ipv4.HEADER_SIZE + udp_len;
    if (total_len > buf.len) return null;
    if (payload_data.len > MAX_PAYLOAD) return null;

    // Build UDP datagram at IPv4 payload offset
    _ = buildDatagram(
        buf[ipv4.HEADER_SIZE..],
        src_port,
        dst_port,
        src_ip,
        dst_ip,
        payload_data,
    ) orelse return null;

    // Write IPv4 header
    _ = ipv4.writeHeader(buf, src_ip, dst_ip, ipv4.PROTO_UDP, @intCast(udp_len)) orelse return null;

    return total_len;
}

// ══════════════════════════════════════════════════════════════════════════════
// Port Binding Table
// ══════════════════════════════════════════════════════════════════════════════

const MAX_BINDINGS: usize = 16;

/// Callback type for received UDP datagrams.
pub const RecvHandler = *const fn (src_ip: [4]u8, src_port: u16, payload: []const u8) void;

const PortBinding = struct {
    port: u16,
    handler: RecvHandler,
    active: bool,
};

var bindings: [MAX_BINDINGS]PortBinding = blk: {
    var b: [MAX_BINDINGS]PortBinding = undefined;
    for (&b) |*entry| {
        entry.port = 0;
        entry.handler = undefined;
        entry.active = false;
    }
    break :blk b;
};

/// Bind a handler to a UDP port. Returns true on success, false if table full.
pub fn bind(port: u16, handler: RecvHandler) bool {
    // Check for existing binding on same port
    for (&bindings) |*entry| {
        if (entry.active and entry.port == port) {
            entry.handler = handler; // Replace
            return true;
        }
    }
    // Find empty slot
    for (&bindings) |*entry| {
        if (!entry.active) {
            entry.port = port;
            entry.handler = handler;
            entry.active = true;
            return true;
        }
    }
    return false; // Table full
}

/// Unbind a port. Returns true if the port was bound.
pub fn unbind(port: u16) bool {
    for (&bindings) |*entry| {
        if (entry.active and entry.port == port) {
            entry.active = false;
            return true;
        }
    }
    return false;
}

/// Check if a port is bound.
pub fn isBound(port: u16) bool {
    for (&bindings) |*entry| {
        if (entry.active and entry.port == port) return true;
    }
    return false;
}

/// Dispatch an incoming UDP datagram to the appropriate bound handler.
/// Returns true if a handler was found and called, false otherwise.
pub fn dispatch(src_ip: [4]u8, datagram: Datagram) bool {
    for (&bindings) |*entry| {
        if (entry.active and entry.port == datagram.dst_port) {
            entry.handler(src_ip, datagram.src_port, datagram.payload_data);
            return true;
        }
    }
    return false;
}


// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "build and parse round-trip" {
    const src_ip = [4]u8{ 10, 0, 0, 1 };
    const dst_ip = [4]u8{ 10, 0, 0, 2 };
    const payload = "UDP payload";
    var buf: [1500]u8 = undefined;
    const udp_len = buildDatagram(&buf, 12345, 80, src_ip, dst_ip, payload) orelse return error.TestUnexpectedResult;
    if (udp_len != 8 + payload.len) return error.TestUnexpectedResult;
    const dgram = parseDatagram(buf[0..udp_len], src_ip, dst_ip) orelse return error.TestUnexpectedResult;
    if (dgram.src_port != 12345) return error.TestUnexpectedResult;
    if (dgram.dst_port != 80) return error.TestUnexpectedResult;
    if (dgram.payload_data.len != payload.len) return error.TestUnexpectedResult;
}

test "corrupted checksum detected" {
    const src_ip = [4]u8{ 10, 0, 0, 1 };
    const dst_ip = [4]u8{ 10, 0, 0, 2 };
    var buf: [1500]u8 = undefined;
    const udp_len = buildDatagram(&buf, 1000, 2000, src_ip, dst_ip, "test") orelse return error.TestUnexpectedResult;
    buf[8] ^= 0xFF; // Corrupt payload
    if (parseDatagram(buf[0..udp_len], src_ip, dst_ip) != null) return error.TestUnexpectedResult;
}

test "port binding" {
    const handler = struct {
        fn h(_: [4]u8, _: u16, _: []const u8) void {}
    }.h;
    if (!bind(9999, handler)) return error.TestUnexpectedResult;
    if (!isBound(9999)) return error.TestUnexpectedResult;
    if (!unbind(9999)) return error.TestUnexpectedResult;
    if (isBound(9999)) return error.TestUnexpectedResult;
}

test "buildPacket produces valid IPv4+UDP" {
    var buf: [1500]u8 = undefined;
    const len = buildPacket(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, 5000, 80, "GET /") orelse return error.TestUnexpectedResult;
    if (len != 20 + 8 + 5) return error.TestUnexpectedResult;
}
