//! IPv4 Layer (RFC 791)
//!
//! Header construction, parsing, validation, and checksum.
//! Supports basic routing decision (same-subnet vs gateway).
//! No fragmentation on TX (we never exceed MTU). RX fragmentation not supported
//! (GCP does not fragment within a VPC — all packets fit in MTU).
//!
//! Zero allocation — operates on caller-provided buffers.

const checksum = @import("checksum.sig");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const HEADER_SIZE: usize = 20; // Minimum IPv4 header (no options)
pub const MAX_PACKET_SIZE: usize = 1500; // Fits in Ethernet MTU
pub const VERSION: u8 = 4;
pub const DEFAULT_TTL: u8 = 64;

// Protocol numbers
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

// ══════════════════════════════════════════════════════════════════════════════
// IPv4 Header
// ══════════════════════════════════════════════════════════════════════════════

pub const Header = struct {
    version: u8, // Always 4
    ihl: u8, // Internet Header Length (in 32-bit words, min 5)
    dscp: u8, // Differentiated Services (TOS)
    total_length: u16, // Total packet length (header + payload)
    identification: u16,
    flags: u8, // [2:0] = Reserved, DF, MF
    fragment_offset: u16,
    ttl: u8,
    protocol: u8,
    header_checksum: u16,
    src_ip: [4]u8,
    dst_ip: [4]u8,

    /// Parse an IPv4 header from packet data.
    /// Validates version, IHL, and checksum.
    /// Returns null if invalid.
    pub fn parse(data: []const u8) ?Header {
        if (data.len < HEADER_SIZE) return null;

        const ver_ihl = data[0];
        const version: u8 = ver_ihl >> 4;
        const ihl: u8 = ver_ihl & 0x0F;

        if (version != VERSION) return null;
        if (ihl < 5) return null;

        const hdr_len: usize = @as(usize, ihl) * 4;
        if (data.len < hdr_len) return null;

        // Verify header checksum
        if (!checksum.verify(data[0..hdr_len])) return null;

        const total_length = @as(u16, data[2]) << 8 | data[3];
        const flags_frag = @as(u16, data[6]) << 8 | data[7];

        return .{
            .version = version,
            .ihl = ihl,
            .dscp = data[1],
            .total_length = total_length,
            .identification = @as(u16, data[4]) << 8 | data[5],
            .flags = @intCast(flags_frag >> 13),
            .fragment_offset = flags_frag & 0x1FFF,
            .ttl = data[8],
            .protocol = data[9],
            .header_checksum = @as(u16, data[10]) << 8 | data[11],
            .src_ip = data[12..16].*,
            .dst_ip = data[16..20].*,
        };
    }

    /// Get the header length in bytes.
    pub fn headerLen(self: *const Header) usize {
        return @as(usize, self.ihl) * 4;
    }

    /// Get the payload (data after header).
    pub fn payload(self: *const Header, data: []const u8) ?[]const u8 {
        const hdr_len = self.headerLen();
        const pkt_len: usize = self.total_length;
        if (data.len < pkt_len) return null;
        if (pkt_len <= hdr_len) return null;
        return data[hdr_len..pkt_len];
    }

    /// Check if this packet is fragmented (MF set or offset != 0).
    pub fn isFragment(self: *const Header) bool {
        return (self.flags & 0x1) != 0 or self.fragment_offset != 0;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Packet Construction
// ══════════════════════════════════════════════════════════════════════════════

/// Identification counter for outgoing packets.
var next_id: u16 = 1;

/// Build an IPv4 packet header + payload in `buf`.
/// Returns total packet length, or null if buffer too small.
///
/// The payload is NOT copied — caller must write payload starting at
/// buf[HEADER_SIZE..] before calling this, or use buildPacket() which copies.
///
/// Parameters:
///   buf      — output buffer (at least HEADER_SIZE + payload_len)
///   src_ip   — source IPv4 address
///   dst_ip   — destination IPv4 address
///   protocol — IP protocol (PROTO_TCP, PROTO_UDP, PROTO_ICMP)
///   payload_len — length of payload already placed at buf[20..]
pub fn writeHeader(
    buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload_len: u16,
) ?usize {
    const total_len = HEADER_SIZE + @as(usize, payload_len);
    if (buf.len < total_len) return null;
    if (total_len > MAX_PACKET_SIZE) return null;

    const total: u16 = @intCast(total_len);
    const id = next_id;
    next_id +%= 1;

    // Version(4) + IHL(5) = 0x45
    buf[0] = 0x45;
    // DSCP/ECN = 0
    buf[1] = 0;
    // Total length (BE16)
    buf[2] = @intCast(total >> 8);
    buf[3] = @intCast(total & 0xFF);
    // Identification
    buf[4] = @intCast(id >> 8);
    buf[5] = @intCast(id & 0xFF);
    // Flags (DF=1, no fragmentation) + Fragment Offset = 0
    buf[6] = 0x40; // Don't Fragment
    buf[7] = 0x00;
    // TTL
    buf[8] = DEFAULT_TTL;
    // Protocol
    buf[9] = protocol;
    // Header checksum (zeroed before computation)
    buf[10] = 0;
    buf[11] = 0;
    // Source IP
    @memcpy(buf[12..16], &src_ip);
    // Destination IP
    @memcpy(buf[16..20], &dst_ip);

    // Compute header checksum
    const cksum = checksum.compute(buf[0..HEADER_SIZE]);
    buf[10] = @intCast(cksum >> 8);
    buf[11] = @intCast(cksum & 0xFF);

    return total_len;
}

/// Build a complete IPv4 packet (header + payload copy) in `buf`.
/// Returns total packet length, or null on error.
pub fn buildPacket(
    buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload_data: []const u8,
) ?usize {
    const total_len = HEADER_SIZE + payload_data.len;
    if (total_len > buf.len) return null;
    if (payload_data.len > MAX_PACKET_SIZE - HEADER_SIZE) return null;

    // Copy payload first
    @memcpy(buf[HEADER_SIZE..][0..payload_data.len], payload_data);

    // Write header
    return writeHeader(buf, src_ip, dst_ip, protocol, @intCast(payload_data.len));
}

// ══════════════════════════════════════════════════════════════════════════════
// Routing
// ══════════════════════════════════════════════════════════════════════════════

/// Determine if a destination IP is on the same subnet as us.
/// If yes, ARP directly for that IP. If no, ARP for the gateway.
pub fn isLocalSubnet(dst_ip: [4]u8, our_ip: [4]u8, subnet_mask: [4]u8) bool {
    return (dst_ip[0] & subnet_mask[0]) == (our_ip[0] & subnet_mask[0]) and
        (dst_ip[1] & subnet_mask[1]) == (our_ip[1] & subnet_mask[1]) and
        (dst_ip[2] & subnet_mask[2]) == (our_ip[2] & subnet_mask[2]) and
        (dst_ip[3] & subnet_mask[3]) == (our_ip[3] & subnet_mask[3]);
}

/// Get the next-hop IP address for routing.
/// Returns dst_ip if on the same subnet, or gateway_ip otherwise.
/// Special case: link-local addresses (169.254.x.x) always route directly.
pub fn nextHop(dst_ip: [4]u8, our_ip: [4]u8, subnet_mask: [4]u8, gateway_ip: [4]u8) [4]u8 {
    // Link-local addresses (169.254.0.0/16) — always direct
    if (dst_ip[0] == 169 and dst_ip[1] == 254) return dst_ip;
    // Same subnet — direct
    if (isLocalSubnet(dst_ip, our_ip, subnet_mask)) return dst_ip;
    // Different subnet — via gateway
    return gateway_ip;
}

// ══════════════════════════════════════════════════════════════════════════════
// Utilities
// ══════════════════════════════════════════════════════════════════════════════

/// Compare two IPv4 addresses.
pub fn ipEqual(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

/// Check if an IP is the broadcast address for a subnet.
pub fn isBroadcast(ip: [4]u8, subnet_mask: [4]u8) bool {
    // Host portion is all 1s
    return (ip[0] | subnet_mask[0]) == 0xFF and
        (ip[1] | subnet_mask[1]) == 0xFF and
        (ip[2] | subnet_mask[2]) == 0xFF and
        (ip[3] | subnet_mask[3]) == 0xFF;
}

/// Check if an IP is 0.0.0.0 (unset/any).
pub fn isZero(ip: [4]u8) bool {
    return ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0;
}

/// Check if an IP is link-local (169.254.0.0/16).
pub fn isLinkLocal(ip: [4]u8) bool {
    return ip[0] == 169 and ip[1] == 254;
}

/// Apply subnet mask to get network address.
pub fn networkAddr(ip: [4]u8, mask: [4]u8) [4]u8 {
    return .{
        ip[0] & mask[0],
        ip[1] & mask[1],
        ip[2] & mask[2],
        ip[3] & mask[3],
    };
}


// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "build and parse round-trip" {
    const src = [4]u8{ 192, 168, 1, 100 };
    const dst = [4]u8{ 8, 8, 8, 8 };
    var buf: [1500]u8 = undefined;
    const len = buildPacket(&buf, src, dst, PROTO_UDP, "test data") orelse return error.TestUnexpectedResult;
    if (len != 20 + 9) return error.TestUnexpectedResult;
    const hdr = Header.parse(buf[0..len]) orelse return error.TestUnexpectedResult;
    if (hdr.version != 4) return error.TestUnexpectedResult;
    if (hdr.protocol != PROTO_UDP) return error.TestUnexpectedResult;
    if (!ipEqual(hdr.src_ip, src)) return error.TestUnexpectedResult;
    if (!ipEqual(hdr.dst_ip, dst)) return error.TestUnexpectedResult;
    if (hdr.ttl != 64) return error.TestUnexpectedResult;
}

test "checksum validates" {
    var buf: [1500]u8 = undefined;
    _ = buildPacket(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, PROTO_TCP, "x") orelse return error.TestUnexpectedResult;
    if (!checksum.verify(buf[0..20])) return error.TestUnexpectedResult;
}

test "routing: same subnet direct" {
    if (!isLocalSubnet(.{ 192, 168, 1, 50 }, .{ 192, 168, 1, 100 }, .{ 255, 255, 255, 0 })) return error.TestUnexpectedResult;
    const hop = nextHop(.{ 192, 168, 1, 50 }, .{ 192, 168, 1, 100 }, .{ 255, 255, 255, 0 }, .{ 192, 168, 1, 1 });
    if (!ipEqual(hop, .{ 192, 168, 1, 50 })) return error.TestUnexpectedResult;
}

test "routing: different subnet via gateway" {
    if (isLocalSubnet(.{ 8, 8, 8, 8 }, .{ 192, 168, 1, 100 }, .{ 255, 255, 255, 0 })) return error.TestUnexpectedResult;
    const hop = nextHop(.{ 8, 8, 8, 8 }, .{ 192, 168, 1, 100 }, .{ 255, 255, 255, 0 }, .{ 192, 168, 1, 1 });
    if (!ipEqual(hop, .{ 192, 168, 1, 1 })) return error.TestUnexpectedResult;
}

test "routing: link-local always direct" {
    const hop = nextHop(.{ 169, 254, 169, 254 }, .{ 10, 0, 0, 5 }, .{ 255, 255, 255, 0 }, .{ 10, 0, 0, 1 });
    if (!ipEqual(hop, .{ 169, 254, 169, 254 })) return error.TestUnexpectedResult;
}

test "DF flag set" {
    var buf: [1500]u8 = undefined;
    _ = buildPacket(&buf, .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, PROTO_ICMP, "x") orelse return error.TestUnexpectedResult;
    if (buf[6] != 0x40) return error.TestUnexpectedResult;
}
