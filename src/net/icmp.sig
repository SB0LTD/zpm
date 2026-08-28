//! ICMP (Internet Control Message Protocol) — RFC 792
//!
//! Echo reply responder and destination unreachable generation.
//! Zero allocation — operates on caller-provided buffers.
//!
//! Only implements the subset needed for a server:
//!   - Echo Reply (respond to pings)
//!   - Destination Unreachable (port unreachable for closed UDP ports)

const checksum = @import("net_checksum");
const ipv4 = @import("net_ipv4");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const HEADER_SIZE: usize = 8; // Type(1) + Code(1) + Checksum(2) + Rest(4)

// ICMP message types
pub const TYPE_ECHO_REPLY: u8 = 0;
pub const TYPE_DEST_UNREACHABLE: u8 = 3;
pub const TYPE_ECHO_REQUEST: u8 = 8;

// Destination Unreachable codes
pub const CODE_NET_UNREACHABLE: u8 = 0;
pub const CODE_HOST_UNREACHABLE: u8 = 1;
pub const CODE_PROTO_UNREACHABLE: u8 = 2;
pub const CODE_PORT_UNREACHABLE: u8 = 3;

// ══════════════════════════════════════════════════════════════════════════════
// ICMP Header
// ══════════════════════════════════════════════════════════════════════════════

pub const Header = struct {
    msg_type: u8,
    code: u8,
    checksum_val: u16,
    // Rest of header depends on type:
    // Echo: identifier(2) + sequence(2)
    // Dest Unreachable: unused(4)
    rest: [4]u8,

    pub fn parse(data: []const u8) ?Header {
        if (data.len < HEADER_SIZE) return null;

        // Verify checksum over entire ICMP message
        if (!checksum.verify(data)) return null;

        return .{
            .msg_type = data[0],
            .code = data[1],
            .checksum_val = @as(u16, data[2]) << 8 | data[3],
            .rest = data[4..8].*,
        };
    }

    /// For echo request/reply: get the identifier.
    pub fn echoId(self: *const Header) u16 {
        return @as(u16, self.rest[0]) << 8 | self.rest[1];
    }

    /// For echo request/reply: get the sequence number.
    pub fn echoSeq(self: *const Header) u16 {
        return @as(u16, self.rest[2]) << 8 | self.rest[3];
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Echo Reply
// ══════════════════════════════════════════════════════════════════════════════

/// Process an incoming ICMP Echo Request and generate an Echo Reply.
/// The reply is written as a complete IPv4 packet (header + ICMP) into `reply_buf`.
///
/// Parameters:
///   icmp_data  — the ICMP portion of the received packet (type + code + checksum + id + seq + payload)
///   src_ip     — the IP that sent the echo request (becomes our reply destination)
///   our_ip     — our IP address (becomes reply source)
///   reply_buf  — output buffer for the IPv4 reply packet
///
/// Returns the total reply packet length, or null if not an echo request or buffer too small.
pub fn processEchoRequest(
    icmp_data: []const u8,
    src_ip: [4]u8,
    our_ip: [4]u8,
    reply_buf: []u8,
) ?usize {
    if (icmp_data.len < HEADER_SIZE) return null;

    // Must be an Echo Request (type 8, code 0)
    if (icmp_data[0] != TYPE_ECHO_REQUEST) return null;

    // Verify incoming checksum
    if (!checksum.verify(icmp_data)) return null;

    const icmp_len = icmp_data.len;
    const total_len = ipv4.HEADER_SIZE + icmp_len;
    if (reply_buf.len < total_len) return null;

    // Build ICMP Echo Reply at offset 20 (after IPv4 header)
    const icmp_buf = reply_buf[ipv4.HEADER_SIZE..];

    // Copy the entire request (preserves id, seq, and payload data)
    @memcpy(icmp_buf[0..icmp_len], icmp_data);

    // Change type to Echo Reply (0) and code to 0
    icmp_buf[0] = TYPE_ECHO_REPLY;
    icmp_buf[1] = 0;

    // Zero checksum field before recomputation
    icmp_buf[2] = 0;
    icmp_buf[3] = 0;

    // Compute new ICMP checksum
    const cksum = checksum.compute(icmp_buf[0..icmp_len]);
    icmp_buf[2] = @intCast(cksum >> 8);
    icmp_buf[3] = @intCast(cksum & 0xFF);

    // Write IPv4 header (reply: our_ip → src_ip)
    _ = ipv4.writeHeader(reply_buf, our_ip, src_ip, ipv4.PROTO_ICMP, @intCast(icmp_len)) orelse return null;

    return total_len;
}

// ══════════════════════════════════════════════════════════════════════════════
// Destination Unreachable
// ══════════════════════════════════════════════════════════════════════════════

/// Build an ICMP Destination Unreachable message.
/// Per RFC 792, the payload contains the original IP header + first 8 bytes of original payload.
///
/// Parameters:
///   code           — unreachable code (e.g., CODE_PORT_UNREACHABLE)
///   original_ip_hdr — the original packet's IP header + first 8 bytes of data
///   our_ip         — our source IP for the ICMP error
///   dst_ip         — where to send the error (original packet's source IP)
///   reply_buf      — output buffer
///
/// Returns total IPv4 packet length, or null on error.
pub fn buildDestUnreachable(
    code: u8,
    original_ip_hdr: []const u8,
    our_ip: [4]u8,
    dst_ip: [4]u8,
    reply_buf: []u8,
) ?usize {
    // Include up to IP header (20) + 8 bytes of original payload = 28 bytes max
    const orig_len = if (original_ip_hdr.len > 28) @as(usize, 28) else original_ip_hdr.len;
    const icmp_len = HEADER_SIZE + orig_len;
    const total_len = ipv4.HEADER_SIZE + icmp_len;
    if (reply_buf.len < total_len) return null;

    const icmp_buf = reply_buf[ipv4.HEADER_SIZE..];

    // Type = Destination Unreachable
    icmp_buf[0] = TYPE_DEST_UNREACHABLE;
    // Code
    icmp_buf[1] = code;
    // Checksum (zeroed for computation)
    icmp_buf[2] = 0;
    icmp_buf[3] = 0;
    // Unused (4 bytes, must be zero)
    icmp_buf[4] = 0;
    icmp_buf[5] = 0;
    icmp_buf[6] = 0;
    icmp_buf[7] = 0;
    // Original IP header + 8 bytes data
    @memcpy(icmp_buf[HEADER_SIZE..][0..orig_len], original_ip_hdr[0..orig_len]);

    // Compute ICMP checksum
    const cksum = checksum.compute(icmp_buf[0..icmp_len]);
    icmp_buf[2] = @intCast(cksum >> 8);
    icmp_buf[3] = @intCast(cksum & 0xFF);

    // Write IPv4 header
    _ = ipv4.writeHeader(reply_buf, our_ip, dst_ip, ipv4.PROTO_ICMP, @intCast(icmp_len)) orelse return null;

    return total_len;
}
