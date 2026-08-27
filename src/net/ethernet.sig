//! Ethernet II Frame Layer
//!
//! Construction, parsing, and constants for IEEE 802.3 Ethernet II frames.
//! Zero allocation — all operations use caller-provided buffers.
//!
//! Frame format (no VLAN):
//!   [6] Destination MAC | [6] Source MAC | [2] EtherType | [46-1500] Payload
//!   Total: 64–1518 bytes (without FCS, handled by NIC hardware)

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const HEADER_SIZE: usize = 14;
pub const MIN_FRAME_SIZE: usize = 64; // Including FCS (NIC pads if needed)
pub const MAX_FRAME_SIZE: usize = 1514; // Without FCS
pub const MIN_PAYLOAD: usize = 46;
pub const MAX_PAYLOAD: usize = 1500;
pub const MAC_SIZE: usize = 6;

// EtherType constants (big-endian on wire)
pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;
pub const ETHERTYPE_IPV6: u16 = 0x86DD;
pub const ETHERTYPE_VLAN: u16 = 0x8100;

/// Broadcast MAC address (FF:FF:FF:FF:FF:FF)
pub const BROADCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/// Zero MAC (used as "unset" sentinel)
pub const ZERO_MAC: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };

// ══════════════════════════════════════════════════════════════════════════════
// Frame Header
// ══════════════════════════════════════════════════════════════════════════════

pub const Header = struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16, // Host byte order

    /// Parse an Ethernet header from the first 14 bytes of a frame.
    /// Returns null if frame is too short.
    pub fn parse(frame: []const u8) ?Header {
        if (frame.len < HEADER_SIZE) return null;
        return .{
            .dst_mac = frame[0..6].*,
            .src_mac = frame[6..12].*,
            .ethertype = @as(u16, frame[12]) << 8 | @as(u16, frame[13]),
        };
    }

    /// Get the payload portion of the frame (everything after the 14-byte header).
    pub fn payload(frame: []const u8) ?[]const u8 {
        if (frame.len <= HEADER_SIZE) return null;
        return frame[HEADER_SIZE..];
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Frame Construction
// ══════════════════════════════════════════════════════════════════════════════

/// Build an Ethernet II frame in `buf`.
/// Returns the total frame length written, or null if buffer too small or payload too large.
///
/// Parameters:
///   buf       — output buffer (must be at least HEADER_SIZE + payload.len)
///   dst_mac   — destination MAC address
///   src_mac   — source (our) MAC address
///   ethertype — EtherType value (e.g., ETHERTYPE_IPV4)
///   payload_data — frame payload (will be copied after header)
pub fn buildFrame(
    buf: []u8,
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,
    payload_data: []const u8,
) ?usize {
    const total = HEADER_SIZE + payload_data.len;
    if (total > buf.len) return null;
    if (payload_data.len > MAX_PAYLOAD) return null;

    // Destination MAC
    @memcpy(buf[0..6], &dst_mac);
    // Source MAC
    @memcpy(buf[6..12], &src_mac);
    // EtherType (big-endian on wire)
    buf[12] = @intCast(ethertype >> 8);
    buf[13] = @intCast(ethertype & 0xFF);
    // Payload
    @memcpy(buf[HEADER_SIZE..][0..payload_data.len], payload_data);

    return total;
}

/// Write only the Ethernet header into `buf` (14 bytes).
/// Caller fills payload separately. Returns false if buf too small.
pub fn writeHeader(
    buf: []u8,
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,
) bool {
    if (buf.len < HEADER_SIZE) return false;
    @memcpy(buf[0..6], &dst_mac);
    @memcpy(buf[6..12], &src_mac);
    buf[12] = @intCast(ethertype >> 8);
    buf[13] = @intCast(ethertype & 0xFF);
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// MAC Address Utilities
// ══════════════════════════════════════════════════════════════════════════════

/// Check if a MAC address is the broadcast address.
pub fn isBroadcast(mac: [6]u8) bool {
    return mac[0] == 0xFF and mac[1] == 0xFF and mac[2] == 0xFF and
        mac[3] == 0xFF and mac[4] == 0xFF and mac[5] == 0xFF;
}

/// Check if a MAC address is a multicast address (bit 0 of first octet set).
pub fn isMulticast(mac: [6]u8) bool {
    return (mac[0] & 0x01) != 0;
}

/// Check if a MAC address is unicast (not broadcast or multicast).
pub fn isUnicast(mac: [6]u8) bool {
    return !isMulticast(mac);
}

/// Check if a MAC address is the zero/unset address.
pub fn isZero(mac: [6]u8) bool {
    return mac[0] == 0 and mac[1] == 0 and mac[2] == 0 and
        mac[3] == 0 and mac[4] == 0 and mac[5] == 0;
}

/// Compare two MAC addresses for equality.
pub fn macEqual(a: [6]u8, b: [6]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and
        a[3] == b[3] and a[4] == b[4] and a[5] == b[5];
}

/// Check if a frame is addressed to us (unicast match or broadcast/multicast).
pub fn isForUs(frame: []const u8, our_mac: [6]u8) bool {
    if (frame.len < HEADER_SIZE) return false;
    const dst = frame[0..6].*;
    if (macEqual(dst, our_mac)) return true;
    if (isBroadcast(dst)) return true;
    return false;
}
