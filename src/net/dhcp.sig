//! DHCP Client (RFC 2131)
//!
//! Implements DISCOVER → OFFER → REQUEST → ACK sequence.
//! Extracts assigned IP, subnet mask, gateway, DNS server, and lease time.
//! Supports lease renewal at T1 (50% of lease).
//!
//! Zero allocation — static buffers, operates over UDP port 67/68.
//! Uses the NetInterface abstraction for frame send/recv.

const ethernet = @import("ethernet");
const ipv4 = @import("ipv4");
const udp = @import("udp");
const checksum = @import("checksum");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

const DHCP_SERVER_PORT: u16 = 67;
const DHCP_CLIENT_PORT: u16 = 68;

const BOOTP_REQUEST: u8 = 1;
const BOOTP_REPLY: u8 = 2;

// DHCP message types (option 53)
const MSG_DISCOVER: u8 = 1;
const MSG_OFFER: u8 = 2;
const MSG_REQUEST: u8 = 3;
const MSG_DECLINE: u8 = 4;
const MSG_ACK: u8 = 5;
const MSG_NAK: u8 = 6;
const MSG_RELEASE: u8 = 7;

// DHCP options
const OPT_SUBNET_MASK: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS: u8 = 6;
const OPT_HOSTNAME: u8 = 12;
const OPT_REQUESTED_IP: u8 = 50;
const OPT_LEASE_TIME: u8 = 51;
const OPT_MSG_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_PARAM_REQ: u8 = 55;
const OPT_END: u8 = 255;

const DHCP_MAGIC: [4]u8 = .{ 99, 130, 83, 99 }; // RFC 1497 magic cookie

// BOOTP/DHCP packet size (minimum 300 bytes for proper operation)
const BOOTP_HEADER_SIZE: usize = 236; // Fixed BOOTP fields before options
const MAX_DHCP_SIZE: usize = 576; // Minimum legal DHCP packet

// ══════════════════════════════════════════════════════════════════════════════
// DHCP Lease State
// ══════════════════════════════════════════════════════════════════════════════

pub const LeaseState = enum(u8) {
    idle, // No lease, not trying
    discovering, // DISCOVER sent, waiting for OFFER
    requesting, // REQUEST sent, waiting for ACK
    bound, // Lease active
    renewing, // T1 expired, sending REQUEST to renew
};

pub const Lease = struct {
    state: LeaseState,
    our_ip: [4]u8,
    subnet_mask: [4]u8,
    gateway_ip: [4]u8,
    dns_ip: [4]u8,
    server_ip: [4]u8, // DHCP server that gave us the lease
    lease_time: u32, // Lease duration in seconds
    t1_time: u32, // Renewal time (lease_time / 2)
    elapsed_polls: u64, // Polls since lease acquired (for T1 tracking)
    xid: u32, // Transaction ID

    pub fn isValid(self: *const Lease) bool {
        return self.state == .bound or self.state == .renewing;
    }

    pub fn reset(self: *Lease) void {
        self.state = .idle;
        self.our_ip = .{ 0, 0, 0, 0 };
        self.subnet_mask = .{ 0, 0, 0, 0 };
        self.gateway_ip = .{ 0, 0, 0, 0 };
        self.dns_ip = .{ 0, 0, 0, 0 };
        self.server_ip = .{ 0, 0, 0, 0 };
        self.lease_time = 0;
        self.t1_time = 0;
        self.elapsed_polls = 0;
        self.xid = 0;
    }
};

/// Global lease state (single interface).
pub var lease: Lease = .{
    .state = .idle,
    .our_ip = .{ 0, 0, 0, 0 },
    .subnet_mask = .{ 0, 0, 0, 0 },
    .gateway_ip = .{ 0, 0, 0, 0 },
    .dns_ip = .{ 0, 0, 0, 0 },
    .server_ip = .{ 0, 0, 0, 0 },
    .lease_time = 0,
    .t1_time = 0,
    .elapsed_polls = 0,
    .xid = 0,
};

// Transaction ID counter (simple, not security-critical on LAN)
var xid_counter: u32 = 0x5B305B30; // "SB0SB0" in hex-ish

// ══════════════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════════════

/// Start DHCP discovery. Builds a DISCOVER frame into `frame_buf`.
/// Returns frame length to send, or null on error.
/// After sending, caller should poll for OFFER via processReply().
pub fn startDiscover(our_mac: [6]u8, frame_buf: []u8) ?usize {
    xid_counter +%= 1;
    lease.xid = xid_counter;
    lease.state = .discovering;

    return buildDhcpFrame(frame_buf, our_mac, MSG_DISCOVER, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
}

/// Send a DHCP REQUEST for the offered IP. Builds a REQUEST frame.
/// Returns frame length to send, or null on error.
pub fn sendRequest(our_mac: [6]u8, frame_buf: []u8) ?usize {
    lease.state = .requesting;
    return buildDhcpFrame(frame_buf, our_mac, MSG_REQUEST, lease.our_ip, lease.server_ip);
}

/// Send a renewal REQUEST (unicast to DHCP server).
/// Returns frame length, or null on error.
pub fn sendRenewal(our_mac: [6]u8, frame_buf: []u8) ?usize {
    lease.state = .renewing;
    return buildDhcpFrame(frame_buf, our_mac, MSG_REQUEST, lease.our_ip, lease.server_ip);
}

/// Process an incoming DHCP reply (UDP payload from port 67).
/// Updates lease state. Returns true if lease state advanced.
pub fn processReply(udp_payload: []const u8) bool {
    if (udp_payload.len < BOOTP_HEADER_SIZE + 4) return false;

    // Verify it's a BOOTP reply
    if (udp_payload[0] != BOOTP_REPLY) return false;

    // Verify transaction ID matches
    const xid = readBe32(udp_payload, 4);
    if (xid != lease.xid) return false;

    // Extract your-IP (yiaddr) at offset 16
    const offered_ip = udp_payload[16..20].*;

    // Verify magic cookie
    if (udp_payload[236] != DHCP_MAGIC[0] or udp_payload[237] != DHCP_MAGIC[1] or
        udp_payload[238] != DHCP_MAGIC[2] or udp_payload[239] != DHCP_MAGIC[3])
        return false;

    // Parse options starting at offset 240
    var msg_type: u8 = 0;
    var subnet: [4]u8 = .{ 255, 255, 255, 0 };
    var gateway: [4]u8 = .{ 0, 0, 0, 0 };
    var dns: [4]u8 = .{ 0, 0, 0, 0 };
    var server_id: [4]u8 = .{ 0, 0, 0, 0 };
    var lease_time: u32 = 3600; // Default 1 hour

    var i: usize = 240;
    while (i < udp_payload.len) {
        const opt = udp_payload[i];
        if (opt == OPT_END) break;
        if (opt == 0) { i += 1; continue; } // Padding

        if (i + 1 >= udp_payload.len) break;
        const opt_len: usize = udp_payload[i + 1];
        const opt_data_start = i + 2;
        if (opt_data_start + opt_len > udp_payload.len) break;

        const opt_data = udp_payload[opt_data_start..][0..opt_len];

        switch (opt) {
            OPT_MSG_TYPE => {
                if (opt_len >= 1) msg_type = opt_data[0];
            },
            OPT_SUBNET_MASK => {
                if (opt_len >= 4) subnet = opt_data[0..4].*;
            },
            OPT_ROUTER => {
                if (opt_len >= 4) gateway = opt_data[0..4].*;
            },
            OPT_DNS => {
                if (opt_len >= 4) dns = opt_data[0..4].*;
            },
            OPT_SERVER_ID => {
                if (opt_len >= 4) server_id = opt_data[0..4].*;
            },
            OPT_LEASE_TIME => {
                if (opt_len >= 4) lease_time = readBe32(opt_data, 0);
            },
            else => {},
        }

        i = opt_data_start + opt_len;
    }

    // State machine
    switch (lease.state) {
        .discovering => {
            if (msg_type == MSG_OFFER) {
                lease.our_ip = offered_ip;
                lease.subnet_mask = subnet;
                lease.gateway_ip = gateway;
                lease.dns_ip = dns;
                lease.server_ip = server_id;
                lease.lease_time = lease_time;
                lease.t1_time = lease_time / 2;
                return true; // Caller should now send REQUEST
            }
        },
        .requesting, .renewing => {
            if (msg_type == MSG_ACK) {
                lease.our_ip = offered_ip;
                lease.subnet_mask = subnet;
                lease.gateway_ip = gateway;
                lease.dns_ip = dns;
                lease.server_ip = server_id;
                lease.lease_time = lease_time;
                lease.t1_time = lease_time / 2;
                lease.elapsed_polls = 0;
                lease.state = .bound;
                return true;
            }
            if (msg_type == MSG_NAK) {
                lease.reset();
                return true; // Caller should restart discovery
            }
        },
        else => {},
    }

    return false;
}

/// Tick the DHCP lease timer. Call this periodically.
/// `polls_per_second` tells us how many ticks equal one second.
/// Returns true if a renewal should be sent.
pub fn tick(polls_per_second: u32) bool {
    if (lease.state != .bound) return false;

    lease.elapsed_polls += 1;
    const elapsed_seconds = lease.elapsed_polls / polls_per_second;

    if (elapsed_seconds >= lease.t1_time) {
        return true; // Time to renew
    }
    return false;
}

// ══════════════════════════════════════════════════════════════════════════════
// Frame Construction
// ══════════════════════════════════════════════════════════════════════════════

fn buildDhcpFrame(
    frame_buf: []u8,
    our_mac: [6]u8,
    msg_type: u8,
    requested_ip: [4]u8,
    server_ip: [4]u8,
) ?usize {
    // DHCP packet layout:
    //   Ethernet(14) + IPv4(20) + UDP(8) + BOOTP(236) + Magic(4) + Options(var)
    const options_len: usize = 32; // Enough for our options
    const bootp_len = BOOTP_HEADER_SIZE + 4 + options_len; // 236 + 4 + 32 = 272
    const udp_len = udp.HEADER_SIZE + bootp_len; // 8 + 272 = 280
    const ip_len = ipv4.HEADER_SIZE + udp_len; // 20 + 280 = 300
    const frame_len = ethernet.HEADER_SIZE + ip_len; // 14 + 300 = 314

    if (frame_buf.len < frame_len) return null;

    // Build from inside out:
    // 1. BOOTP/DHCP payload
    const bootp_start = ethernet.HEADER_SIZE + ipv4.HEADER_SIZE + udp.HEADER_SIZE;
    const bootp = frame_buf[bootp_start..][0..bootp_len];
    @memset(bootp, 0);

    bootp[0] = BOOTP_REQUEST; // op
    bootp[1] = 1; // htype = Ethernet
    bootp[2] = 6; // hlen = 6 bytes MAC
    bootp[3] = 0; // hops
    // xid at offset 4 (BE32)
    writeBe32(bootp, 4, lease.xid);
    // secs at offset 8 = 0
    // flags at offset 10: broadcast flag
    bootp[10] = 0x80; bootp[11] = 0x00; // Broadcast
    // ciaddr at offset 12: our current IP (for renewal)
    if (msg_type == MSG_REQUEST and lease.state == .renewing) {
        @memcpy(bootp[12..16], &lease.our_ip);
    }
    // chaddr at offset 28: our MAC
    @memcpy(bootp[28..34], &our_mac);
    // Magic cookie at offset 236
    @memcpy(bootp[236..240], &DHCP_MAGIC);

    // Options starting at offset 240
    var opt_idx: usize = 240;
    // Option 53: DHCP Message Type
    bootp[opt_idx] = OPT_MSG_TYPE; opt_idx += 1;
    bootp[opt_idx] = 1; opt_idx += 1;
    bootp[opt_idx] = msg_type; opt_idx += 1;

    // Option 50: Requested IP (for REQUEST)
    if (msg_type == MSG_REQUEST and !ipv4.isZero(requested_ip)) {
        bootp[opt_idx] = OPT_REQUESTED_IP; opt_idx += 1;
        bootp[opt_idx] = 4; opt_idx += 1;
        @memcpy(bootp[opt_idx..][0..4], &requested_ip); opt_idx += 4;
    }

    // Option 54: Server Identifier (for REQUEST)
    if (msg_type == MSG_REQUEST and !ipv4.isZero(server_ip)) {
        bootp[opt_idx] = OPT_SERVER_ID; opt_idx += 1;
        bootp[opt_idx] = 4; opt_idx += 1;
        @memcpy(bootp[opt_idx..][0..4], &server_ip); opt_idx += 4;
    }

    // Option 55: Parameter Request List
    bootp[opt_idx] = OPT_PARAM_REQ; opt_idx += 1;
    bootp[opt_idx] = 4; opt_idx += 1;
    bootp[opt_idx] = OPT_SUBNET_MASK; opt_idx += 1;
    bootp[opt_idx] = OPT_ROUTER; opt_idx += 1;
    bootp[opt_idx] = OPT_DNS; opt_idx += 1;
    bootp[opt_idx] = OPT_LEASE_TIME; opt_idx += 1;

    // End option
    bootp[opt_idx] = OPT_END;

    // 2. UDP header (broadcast: 0.0.0.0:68 → 255.255.255.255:67)
    const udp_start = ethernet.HEADER_SIZE + ipv4.HEADER_SIZE;
    const udp_buf = frame_buf[udp_start..][0..udp_len];
    const src_ip = [4]u8{ 0, 0, 0, 0 };
    const dst_ip = [4]u8{ 255, 255, 255, 255 };

    // Source port
    udp_buf[0] = @intCast(DHCP_CLIENT_PORT >> 8);
    udp_buf[1] = @intCast(DHCP_CLIENT_PORT & 0xFF);
    // Destination port
    udp_buf[2] = @intCast(DHCP_SERVER_PORT >> 8);
    udp_buf[3] = @intCast(DHCP_SERVER_PORT & 0xFF);
    // Length
    const udp_total: u16 = @intCast(udp_len);
    udp_buf[4] = @intCast(udp_total >> 8);
    udp_buf[5] = @intCast(udp_total & 0xFF);
    // Checksum = 0 (optional for UDP over IPv4 broadcast)
    udp_buf[6] = 0;
    udp_buf[7] = 0;

    // 3. IPv4 header
    const ip_buf = frame_buf[ethernet.HEADER_SIZE..];
    _ = ipv4.writeHeader(ip_buf, src_ip, dst_ip, ipv4.PROTO_UDP, @intCast(udp_len)) orelse return null;

    // 4. Ethernet header (broadcast)
    if (!ethernet.writeHeader(frame_buf, ethernet.BROADCAST_MAC, our_mac, ethernet.ETHERTYPE_IPV4))
        return null;

    return frame_len;
}

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn readBe32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) << 24 |
        @as(u32, data[offset + 1]) << 16 |
        @as(u32, data[offset + 2]) << 8 |
        data[offset + 3];
}

fn writeBe32(buf: []u8, offset: usize, val: u32) void {
    buf[offset] = @intCast((val >> 24) & 0xFF);
    buf[offset + 1] = @intCast((val >> 16) & 0xFF);
    buf[offset + 2] = @intCast((val >> 8) & 0xFF);
    buf[offset + 3] = @intCast(val & 0xFF);
}
