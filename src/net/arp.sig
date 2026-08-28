//! Address Resolution Protocol (RFC 826)
//!
//! ARP request/reply construction and parsing, static ARP table,
//! responder for incoming requests, and query with timeout.
//! Zero allocation — fixed-size table, caller-provided buffers.

const ethernet = @import("net_ethernet");
const net_iface = @import("net_interface");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const ARP_PACKET_SIZE: usize = 28; // ARP payload (no Ethernet header)
pub const ARP_FRAME_SIZE: usize = 42; // Ethernet header (14) + ARP payload (28)

// Hardware/protocol types
const HTYPE_ETHERNET: u16 = 1;
const PTYPE_IPV4: u16 = 0x0800;
const HLEN_ETHERNET: u8 = 6;
const PLEN_IPV4: u8 = 4;

// Opcodes
pub const OP_REQUEST: u16 = 1;
pub const OP_REPLY: u16 = 2;

// ══════════════════════════════════════════════════════════════════════════════
// ARP Packet
// ══════════════════════════════════════════════════════════════════════════════

pub const ArpPacket = struct {
    opcode: u16,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,

    /// Parse an ARP packet from the Ethernet payload (28 bytes).
    pub fn parse(data: []const u8) ?ArpPacket {
        if (data.len < ARP_PACKET_SIZE) return null;

        // Validate hardware/protocol types
        const htype = @as(u16, data[0]) << 8 | data[1];
        const ptype = @as(u16, data[2]) << 8 | data[3];
        if (htype != HTYPE_ETHERNET or ptype != PTYPE_IPV4) return null;
        if (data[4] != HLEN_ETHERNET or data[5] != PLEN_IPV4) return null;

        return .{
            .opcode = @as(u16, data[6]) << 8 | data[7],
            .sender_mac = data[8..14].*,
            .sender_ip = data[14..18].*,
            .target_mac = data[18..24].*,
            .target_ip = data[24..28].*,
        };
    }

    /// Serialize an ARP packet into a 28-byte buffer.
    pub fn serialize(self: *const ArpPacket, buf: []u8) bool {
        if (buf.len < ARP_PACKET_SIZE) return false;

        // Hardware type = Ethernet
        buf[0] = 0; buf[1] = 1;
        // Protocol type = IPv4
        buf[2] = 0x08; buf[3] = 0x00;
        // Lengths
        buf[4] = HLEN_ETHERNET;
        buf[5] = PLEN_IPV4;
        // Opcode
        buf[6] = @intCast(self.opcode >> 8);
        buf[7] = @intCast(self.opcode & 0xFF);
        // Sender hardware + protocol address
        @memcpy(buf[8..14], &self.sender_mac);
        @memcpy(buf[14..18], &self.sender_ip);
        // Target hardware + protocol address
        @memcpy(buf[18..24], &self.target_mac);
        @memcpy(buf[24..28], &self.target_ip);

        return true;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// ARP Table
// ══════════════════════════════════════════════════════════════════════════════

const TABLE_SIZE: usize = 32;

const ArpEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
    age: u32, // Incremented each lookup cycle for LRU eviction
};

var table: [TABLE_SIZE]ArpEntry = blk: {
    var t: [TABLE_SIZE]ArpEntry = undefined;
    for (&t) |*e| {
        e.ip = .{ 0, 0, 0, 0 };
        e.mac = .{ 0, 0, 0, 0, 0, 0 };
        e.valid = false;
        e.age = 0;
    }
    break :blk t;
};

var age_counter: u32 = 0;

/// Look up a MAC address by IP. Returns null if not in table.
pub fn lookup(ip: [4]u8) ?[6]u8 {
    for (&table) |*e| {
        if (e.valid and ipEqual(e.ip, ip)) {
            e.age = age_counter;
            return e.mac;
        }
    }
    return null;
}

/// Insert or update an entry in the ARP table.
pub fn insert(ip: [4]u8, mac: [6]u8) void {
    // Update existing entry
    for (&table) |*e| {
        if (e.valid and ipEqual(e.ip, ip)) {
            e.mac = mac;
            e.age = age_counter;
            return;
        }
    }
    // Find empty slot
    for (&table) |*e| {
        if (!e.valid) {
            e.ip = ip;
            e.mac = mac;
            e.valid = true;
            e.age = age_counter;
            return;
        }
    }
    // Evict LRU (oldest age)
    var oldest_idx: usize = 0;
    var oldest_age: u32 = table[0].age;
    for (table[1..], 1..) |e, idx| {
        if (e.age < oldest_age) {
            oldest_age = e.age;
            oldest_idx = idx;
        }
    }
    table[oldest_idx] = .{
        .ip = ip,
        .mac = mac,
        .valid = true,
        .age = age_counter,
    };
}

/// Clear the entire ARP table.
pub fn clearTable() void {
    for (&table) |*e| {
        e.valid = false;
    }
}

/// Get the number of valid entries in the table.
pub fn tableSize() usize {
    var count: usize = 0;
    for (&table) |*e| {
        if (e.valid) count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════════════════════════
// ARP Frame Construction
// ══════════════════════════════════════════════════════════════════════════════

/// Build a complete ARP request frame (42 bytes) asking "who has `target_ip`?"
/// Returns total frame length, or null if buffer too small.
pub fn buildRequest(
    buf: []u8,
    our_mac: [6]u8,
    our_ip: [4]u8,
    target_ip: [4]u8,
) ?usize {
    if (buf.len < ARP_FRAME_SIZE) return null;

    // Ethernet header: broadcast destination, ARP ethertype
    if (!ethernet.writeHeader(buf, ethernet.BROADCAST_MAC, our_mac, ethernet.ETHERTYPE_ARP))
        return null;

    // ARP payload
    const pkt = ArpPacket{
        .opcode = OP_REQUEST,
        .sender_mac = our_mac,
        .sender_ip = our_ip,
        .target_mac = .{ 0, 0, 0, 0, 0, 0 },
        .target_ip = target_ip,
    };
    if (!pkt.serialize(buf[ethernet.HEADER_SIZE..])) return null;

    return ARP_FRAME_SIZE;
}

/// Build a complete ARP reply frame (42 bytes).
/// Returns total frame length, or null if buffer too small.
pub fn buildReply(
    buf: []u8,
    our_mac: [6]u8,
    our_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
) ?usize {
    if (buf.len < ARP_FRAME_SIZE) return null;

    // Ethernet header: unicast to requester
    if (!ethernet.writeHeader(buf, target_mac, our_mac, ethernet.ETHERTYPE_ARP))
        return null;

    // ARP payload
    const pkt = ArpPacket{
        .opcode = OP_REPLY,
        .sender_mac = our_mac,
        .sender_ip = our_ip,
        .target_mac = target_mac,
        .target_ip = target_ip,
    };
    if (!pkt.serialize(buf[ethernet.HEADER_SIZE..])) return null;

    return ARP_FRAME_SIZE;
}

/// Build a gratuitous ARP announcement (broadcast, sender=target).
/// Used on link up to announce our presence and update peer caches.
pub fn buildGratuitous(
    buf: []u8,
    our_mac: [6]u8,
    our_ip: [4]u8,
) ?usize {
    return buildRequest(buf, our_mac, our_ip, our_ip);
}

// ══════════════════════════════════════════════════════════════════════════════
// ARP Processing (called from network stack on incoming ARP frames)
// ══════════════════════════════════════════════════════════════════════════════

/// Process an incoming ARP frame. Updates the table and optionally generates
/// a reply frame in `reply_buf`. Returns the reply frame length if a reply
/// is needed, or null if no reply should be sent.
///
/// Parameters:
///   frame      — complete Ethernet frame (14 + 28 bytes minimum)
///   our_mac    — our MAC address
///   our_ip     — our IPv4 address
///   reply_buf  — buffer for outgoing ARP reply (at least 42 bytes)
pub fn processFrame(
    frame: []const u8,
    our_mac: [6]u8,
    our_ip: [4]u8,
    reply_buf: []u8,
) ?usize {
    if (frame.len < ARP_FRAME_SIZE) return null;

    const pkt = ArpPacket.parse(frame[ethernet.HEADER_SIZE..]) orelse return null;

    // Always learn the sender's MAC→IP mapping (RFC 826: merge flag)
    age_counter +%= 1;
    insert(pkt.sender_ip, pkt.sender_mac);

    // If this is a request for our IP, generate a reply
    if (pkt.opcode == OP_REQUEST and ipEqual(pkt.target_ip, our_ip)) {
        return buildReply(reply_buf, our_mac, our_ip, pkt.sender_mac, pkt.sender_ip);
    }

    return null;
}

/// Resolve an IP to a MAC address with ARP query and polling.
/// Sends an ARP request via `iface`, then polls for a reply up to
/// `max_polls` iterations. Returns the MAC or null on timeout.
pub fn resolve(
    iface: *const net_iface.NetInterface,
    our_mac: [6]u8,
    our_ip: [4]u8,
    target_ip: [4]u8,
    max_polls: u32,
) ?[6]u8 {
    // Check cache first
    if (lookup(target_ip)) |mac| return mac;

    // Send ARP request
    var req_buf: [ARP_FRAME_SIZE]u8 = undefined;
    const req_len = buildRequest(&req_buf, our_mac, our_ip, target_ip) orelse return null;
    _ = iface.send(req_buf[0..req_len]);

    // Poll for reply
    var reply_buf: [ARP_FRAME_SIZE]u8 = undefined;
    var polls: u32 = 0;
    while (polls < max_polls) : (polls += 1) {
        const rx = iface.recv() orelse continue;
        if (rx.len < ARP_FRAME_SIZE) continue;

        // Check if it's an ARP frame
        const hdr = ethernet.Header.parse(rx) orelse continue;
        if (hdr.ethertype != ethernet.ETHERTYPE_ARP) continue;

        // Process it (updates table)
        _ = processFrame(rx, our_mac, our_ip, &reply_buf);

        // Check if we now have the answer
        if (lookup(target_ip)) |mac| return mac;
    }

    return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn ipEqual(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}
