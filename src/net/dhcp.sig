//! DHCP Client (RFC 2131)
//!
//! Implements DISCOVER → OFFER → REQUEST → ACK sequence.
//! Extracts assigned IP, subnet mask, gateway, DNS server, and lease time.
//!
//! Lease timers (RFC 2131 §4.4.5) run on the caller's monotonic clock in
//! seconds (`poll`): at T1 (option 58, default 50%) a REQUEST is unicast to
//! the server that gave the lease (RENEWING), at T2 (option 59, default
//! 87.5%) it is broadcast to any server (REBINDING), and at expiry the
//! lease is dropped and discovery starts over. `forceRenew` asks for a
//! renewal now (after a long sleep, when the network may have changed).
//!
//! Zero allocation — static buffers, operates over UDP port 67/68.
//! Uses the NetInterface abstraction for frame send/recv.
//!
//! Host tests: `sig build test-net-dhcp` in zpm, or directly (from zpm/src/net):
//!   sig test --dep net_ethernet --dep net_ipv4 --dep net_udp --dep net_checksum \
//!     -Mroot=dhcp.sig -Mnet_ethernet=ethernet.sig --dep net_checksum -Mnet_ipv4=ipv4.sig \
//!     --dep net_checksum --dep net_ipv4 -Mnet_udp=udp.sig -Mnet_checksum=checksum.sig

const std = @import("std");
const ethernet = @import("net_ethernet");
const ipv4 = @import("net_ipv4");
const udp = @import("net_udp");
const checksum = @import("net_checksum");

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
const OPT_RENEWAL_TIME: u8 = 58; // T1
const OPT_REBINDING_TIME: u8 = 59; // T2
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
    renewing, // T1 expired, sending REQUEST to renew (unicast to the server)
    rebinding, // T2 expired, sending REQUEST to any server (broadcast)
};

/// Lease seconds meaning "infinite" (RFC 2132 §9.2): never renewed.
pub const INFINITE: u32 = 0xFFFF_FFFF;

/// Shortest wait between retransmitted renew/rebind REQUESTs (seconds).
/// RFC 2131 says 60; short leases (a phone hotspot, the bench) need less.
pub const MIN_RETRY_S: u32 = 4;

/// What the lease timers want the caller to do now (`poll`).
pub const Action = enum {
    none,
    /// Send buildRenewPacket (unicast to the server).
    renew,
    /// Send buildRebindFrame (broadcast).
    rebind,
    /// The lease expired and was dropped: stop using the address and start
    /// discovery again.
    rediscover,
};

pub const Lease = struct {
    state: LeaseState,
    our_ip: [4]u8,
    subnet_mask: [4]u8,
    gateway_ip: [4]u8,
    dns_ip: [4]u8,
    server_ip: [4]u8, // DHCP server that gave us the lease
    lease_time: u32, // Lease duration in seconds
    t1_time: u32, // Renewal time (option 58, or lease_time / 2)
    t2_time: u32 = 0, // Rebinding time (option 59, or lease_time * 7/8)
    start_s: u64 = 0, // Caller clock (s) when the lease was granted
    next_send_s: u64 = 0, // When to retransmit a renew/rebind REQUEST
    force_renew: bool = false, // Renew at the next poll (after a sleep)
    elapsed_polls: u64, // Polls since lease acquired (legacy `tick`)
    xid: u32, // Transaction ID

    pub fn isValid(self: *const Lease) bool {
        return self.state == .bound or self.state == .renewing or self.state == .rebinding;
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
        self.t2_time = 0;
        self.start_s = 0;
        self.next_send_s = 0;
        self.force_renew = false;
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

// Transaction ID counter: each exchange takes the next value. `seedXid`
// starts it somewhere unpredictable so an off-LAN guess is useless.
var xid_counter: u32 = 0x5B305B30; // "SB0SB0" in hex-ish

/// Mix caller entropy into the transaction IDs (call once, before DHCP).
pub fn seedXid(seed: u32) void {
    xid_counter ^= seed;
}

fn nextXid() u32 {
    xid_counter = xid_counter *% 0x9E37_79B9 +% 0x7F4A_7C15;
    return xid_counter;
}

// ══════════════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════════════

/// Start DHCP discovery. Builds a DISCOVER frame into `frame_buf`.
/// Returns frame length to send, or null on error.
/// After sending, caller should poll for OFFER via processReply().
pub fn startDiscover(our_mac: [6]u8, frame_buf: []u8) ?usize {
    lease.reset();
    lease.xid = nextXid();
    lease.state = .discovering;

    return buildDhcpFrame(frame_buf, our_mac, MSG_DISCOVER, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
}

/// Send a DHCP REQUEST for the offered IP. Builds a REQUEST frame.
/// Returns frame length to send, or null on error.
pub fn sendRequest(our_mac: [6]u8, frame_buf: []u8) ?usize {
    lease.state = .requesting;
    return buildDhcpFrame(frame_buf, our_mac, MSG_REQUEST, lease.our_ip, lease.server_ip);
}

/// Send a renewal REQUEST as a broadcast Ethernet frame (legacy callers
/// that pair it with `tick`; galaxy_net uses `poll` and buildRenewPacket).
/// Returns frame length, or null on error.
pub fn sendRenewal(our_mac: [6]u8, frame_buf: []u8) ?usize {
    lease.state = .renewing;
    lease.xid = nextXid();
    return buildDhcpFrame(frame_buf, our_mac, MSG_REQUEST, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
}

/// RENEWING: an IPv4 packet (no Ethernet header; the caller routes it, so
/// the server's MAC comes from ARP) carrying a REQUEST from our address to
/// the server that granted the lease. Per RFC 2131 it carries ciaddr and
/// neither a requested-IP nor a server-ID option. `now_s` schedules the
/// retransmission.
pub fn buildRenewPacket(our_mac: [6]u8, now_s: u64, pkt_buf: []u8) ?usize {
    if (ipv4.isZero(lease.server_ip) or ipv4.isZero(lease.our_ip)) return null;
    lease.state = .renewing;
    lease.xid = nextXid();
    lease.force_renew = false;
    scheduleRetry(now_s, lease.t2_time);
    var bootp: [BOOTP_HEADER_SIZE + 4 + OPTIONS_LEN]u8 = undefined;
    const n = buildBootp(&bootp, our_mac, MSG_REQUEST, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, lease.our_ip, false);
    return udp.buildPacket(pkt_buf, lease.our_ip, lease.server_ip, DHCP_CLIENT_PORT, DHCP_SERVER_PORT, bootp[0..n]);
}

/// REBINDING: a broadcast Ethernet frame carrying a REQUEST from our
/// address to any server (the one that granted the lease did not answer).
pub fn buildRebindFrame(our_mac: [6]u8, now_s: u64, frame_buf: []u8) ?usize {
    if (ipv4.isZero(lease.our_ip)) return null;
    lease.state = .rebinding;
    lease.xid = nextXid();
    lease.force_renew = false;
    scheduleRetry(now_s, lease.lease_time);
    return buildFrame(frame_buf, our_mac, MSG_REQUEST, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, lease.our_ip, lease.our_ip, false);
}

/// Retransmit after half the time left until `deadline_rel` (seconds from
/// the lease start), but no sooner than MIN_RETRY_S (RFC 2131 §4.4.5).
fn scheduleRetry(now_s: u64, deadline_rel: u32) void {
    const deadline = lease.start_s + deadline_rel;
    const left = if (deadline > now_s) deadline - now_s else 0;
    lease.next_send_s = now_s + @max(left / 2, MIN_RETRY_S);
}

/// Ask for a renewal at the next poll (e.g. after a long sleep: the lease
/// may be gone, or the machine on another network).
pub fn forceRenew() void {
    if (lease.isValid()) lease.force_renew = true;
}

/// Run the lease timers at `now_s` (caller's monotonic seconds, the same
/// clock passed to processReplyAt). Returns what to send, if anything.
pub fn poll(now_s: u64) Action {
    if (!lease.isValid() or lease.lease_time == INFINITE) return .none;
    const t = now_s -| lease.start_s;
    if (t >= lease.lease_time) {
        lease.reset();
        return .rediscover;
    }
    switch (lease.state) {
        .bound => if (t >= lease.t2_time) return .rebind else if (t >= lease.t1_time or lease.force_renew) return .renew,
        .renewing => if (t >= lease.t2_time) return .rebind else if (now_s >= lease.next_send_s or lease.force_renew) return .renew,
        .rebinding => if (now_s >= lease.next_send_s or lease.force_renew) return .rebind,
        else => {},
    }
    return .none;
}

/// Process an incoming DHCP reply (UDP payload from port 67) with no clock
/// (legacy: lease timers then run from 0; use processReplyAt with `poll`).
pub fn processReply(udp_payload: []const u8) bool {
    return processReplyAt(udp_payload, 0);
}

/// Process an incoming DHCP reply (UDP payload from port 67) received at
/// `now_s`. Updates lease state. Returns true if lease state advanced.
pub fn processReplyAt(udp_payload: []const u8, now_s: u64) bool {
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
    var t1_opt: ?u32 = null;
    var t2_opt: ?u32 = null;

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
            OPT_RENEWAL_TIME => {
                if (opt_len >= 4) t1_opt = readBe32(opt_data, 0);
            },
            OPT_REBINDING_TIME => {
                if (opt_len >= 4) t2_opt = readBe32(opt_data, 0);
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
                setTimes(lease_time, t1_opt, t2_opt);
                return true; // Caller should now send REQUEST
            }
        },
        .requesting, .renewing, .rebinding => {
            if (msg_type == MSG_ACK) {
                if (ipv4.isZero(offered_ip)) return false;
                lease.our_ip = offered_ip;
                lease.subnet_mask = subnet;
                lease.gateway_ip = gateway;
                lease.dns_ip = dns;
                // (an ACK while rebinding may come from another server)
                if (!ipv4.isZero(server_id)) lease.server_ip = server_id;
                setTimes(lease_time, t1_opt, t2_opt);
                lease.start_s = now_s;
                lease.next_send_s = 0;
                lease.force_renew = false;
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

/// Lease, T1 and T2 from the reply's options, kept in order
/// (T1 <= T2 <= lease); RFC 2131 defaults where absent or inconsistent.
fn setTimes(lease_time: u32, t1_opt: ?u32, t2_opt: ?u32) void {
    const lt = @max(lease_time, 1);
    var t2 = t2_opt orelse @as(u32, @intCast(@as(u64, lt) * 7 / 8));
    if (t2 > lt) t2 = @intCast(@as(u64, lt) * 7 / 8);
    var t1 = t1_opt orelse lt / 2;
    if (t1 > t2) t1 = @min(lt / 2, t2);
    lease.lease_time = lt;
    lease.t1_time = t1;
    lease.t2_time = t2;
}

/// Tick the DHCP lease timer. Call this periodically (legacy; see `poll`).
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

const OPTIONS_LEN: usize = 32; // Enough for our options

fn buildDhcpFrame(
    frame_buf: []u8,
    our_mac: [6]u8,
    msg_type: u8,
    requested_ip: [4]u8,
    server_ip: [4]u8,
) ?usize {
    // Initial DISCOVER/REQUEST (and the legacy renewal): from 0.0.0.0, with
    // ciaddr only when renewing, asking for a broadcast reply.
    const ciaddr: [4]u8 = if (msg_type == MSG_REQUEST and lease.state == .renewing) lease.our_ip else .{ 0, 0, 0, 0 };
    return buildFrame(frame_buf, our_mac, msg_type, requested_ip, server_ip, ciaddr, .{ 0, 0, 0, 0 }, true);
}

/// The BOOTP/DHCP payload. Returns its length (always the full buffer).
fn buildBootp(
    bootp: *[BOOTP_HEADER_SIZE + 4 + OPTIONS_LEN]u8,
    our_mac: [6]u8,
    msg_type: u8,
    requested_ip: [4]u8,
    server_ip: [4]u8,
    ciaddr: [4]u8,
    broadcast_reply: bool,
) usize {
    @memset(bootp, 0);

    bootp[0] = BOOTP_REQUEST; // op
    bootp[1] = 1; // htype = Ethernet
    bootp[2] = 6; // hlen = 6 bytes MAC
    bootp[3] = 0; // hops
    // xid at offset 4 (BE32)
    writeBe32(bootp, 4, lease.xid);
    // secs at offset 8 = 0
    // flags at offset 10: broadcast flag (we cannot take unicast without an
    // address yet)
    if (broadcast_reply) bootp[10] = 0x80;
    // ciaddr at offset 12: our current IP (renewing / rebinding)
    @memcpy(bootp[12..16], &ciaddr);
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

    // Option 50: Requested IP (for REQUEST in SELECTING)
    if (msg_type == MSG_REQUEST and !ipv4.isZero(requested_ip)) {
        bootp[opt_idx] = OPT_REQUESTED_IP; opt_idx += 1;
        bootp[opt_idx] = 4; opt_idx += 1;
        @memcpy(bootp[opt_idx..][0..4], &requested_ip); opt_idx += 4;
    }

    // Option 54: Server Identifier (for REQUEST in SELECTING)
    if (msg_type == MSG_REQUEST and !ipv4.isZero(server_ip)) {
        bootp[opt_idx] = OPT_SERVER_ID; opt_idx += 1;
        bootp[opt_idx] = 4; opt_idx += 1;
        @memcpy(bootp[opt_idx..][0..4], &server_ip); opt_idx += 4;
    }

    // Option 55: Parameter Request List
    bootp[opt_idx] = OPT_PARAM_REQ; opt_idx += 1;
    bootp[opt_idx] = 6; opt_idx += 1;
    bootp[opt_idx] = OPT_SUBNET_MASK; opt_idx += 1;
    bootp[opt_idx] = OPT_ROUTER; opt_idx += 1;
    bootp[opt_idx] = OPT_DNS; opt_idx += 1;
    bootp[opt_idx] = OPT_LEASE_TIME; opt_idx += 1;
    bootp[opt_idx] = OPT_RENEWAL_TIME; opt_idx += 1;
    bootp[opt_idx] = OPT_REBINDING_TIME; opt_idx += 1;

    // End option
    bootp[opt_idx] = OPT_END;
    return bootp.len;
}

/// A broadcast Ethernet frame (to 255.255.255.255:67) from `src_ip`.
fn buildFrame(
    frame_buf: []u8,
    our_mac: [6]u8,
    msg_type: u8,
    requested_ip: [4]u8,
    server_ip: [4]u8,
    ciaddr: [4]u8,
    src_ip: [4]u8,
    broadcast_reply: bool,
) ?usize {
    // DHCP packet layout:
    //   Ethernet(14) + IPv4(20) + UDP(8) + BOOTP(236) + Magic(4) + Options(var)
    const bootp_len = BOOTP_HEADER_SIZE + 4 + OPTIONS_LEN; // 236 + 4 + 32 = 272
    const udp_len = udp.HEADER_SIZE + bootp_len; // 8 + 272 = 280
    const ip_len = ipv4.HEADER_SIZE + udp_len; // 20 + 280 = 300
    const frame_len = ethernet.HEADER_SIZE + ip_len; // 14 + 300 = 314

    if (frame_buf.len < frame_len) return null;

    // Build from inside out:
    // 1. BOOTP/DHCP payload
    const bootp_start = ethernet.HEADER_SIZE + ipv4.HEADER_SIZE + udp.HEADER_SIZE;
    _ = buildBootp(frame_buf[bootp_start..][0..bootp_len], our_mac, msg_type, requested_ip, server_ip, ciaddr, broadcast_reply);

    // 2. UDP header (broadcast: src_ip:68 → 255.255.255.255:67)
    const udp_start = ethernet.HEADER_SIZE + ipv4.HEADER_SIZE;
    const udp_buf = frame_buf[udp_start..][0..udp_len];
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

// ══════════════════════════════════════════════════════════════════════════════
// Tests (an injected clock)
// ══════════════════════════════════════════════════════════════════════════════

const test_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const test_server = [4]u8{ 10, 0, 2, 2 };
const test_ip = [4]u8{ 10, 0, 2, 15 };

/// A server reply (UDP payload) of type `msg` for the current xid.
fn testReply(msg: u8, lease_s: u32) [300]u8 {
    var r: [300]u8 = @splat(0);
    r[0] = BOOTP_REPLY;
    r[1] = 1;
    r[2] = 6;
    writeBe32(&r, 4, lease.xid);
    @memcpy(r[16..20], &test_ip);
    @memcpy(r[28..34], &test_mac);
    @memcpy(r[236..240], &DHCP_MAGIC);
    var i: usize = 240;
    for ([_]u8{ OPT_MSG_TYPE, 1, msg, OPT_SERVER_ID, 4 } ++ test_server ++ [_]u8{ OPT_SUBNET_MASK, 4, 255, 255, 255, 0, OPT_ROUTER, 4 } ++ test_server ++ [_]u8{ OPT_DNS, 4, 10, 0, 2, 3, OPT_LEASE_TIME, 4 }) |b| {
        r[i] = b;
        i += 1;
    }
    writeBe32(&r, i, lease_s);
    r[i + 4] = OPT_END;
    return r;
}

/// DISCOVER → OFFER → REQUEST → ACK at `now_s`, for a lease of `lease_s`.
fn testBind(now_s: u64, lease_s: u32) !void {
    var frame: [600]u8 = undefined;
    _ = startDiscover(test_mac, &frame) orelse return error.Build;
    const offer = testReply(MSG_OFFER, lease_s);
    try std.testing.expect(processReplyAt(&offer, now_s));
    _ = sendRequest(test_mac, &frame) orelse return error.Build;
    const ack = testReply(MSG_ACK, lease_s);
    try std.testing.expect(processReplyAt(&ack, now_s));
    try std.testing.expectEqual(LeaseState.bound, lease.state);
}

/// The message type option of a BOOTP payload.
fn testMsgType(bootp: []const u8) u8 {
    var i: usize = 240;
    while (i + 2 < bootp.len and bootp[i] != OPT_END) : (i += 2 + bootp[i + 1]) {
        if (bootp[i] == OPT_MSG_TYPE) return bootp[i + 2];
        if (bootp[i] == OPT_REQUESTED_IP or bootp[i] == OPT_SERVER_ID) return 0xFF; // not allowed when renewing
    }
    return 0;
}

test "dhcp: a 60 s lease renews by unicast at T1, rebinds at T2, rediscovers at expiry" {
    const t0: u64 = 1000;
    try testBind(t0, 60);
    try std.testing.expectEqual(@as(u32, 30), lease.t1_time);
    try std.testing.expectEqual(@as(u32, 52), lease.t2_time);

    try std.testing.expectEqual(Action.none, poll(t0 + 29));
    try std.testing.expectEqual(Action.renew, poll(t0 + 30));

    // RENEWING: a REQUEST from our address, unicast to the server, ciaddr set.
    var pkt: [600]u8 = undefined;
    const n = buildRenewPacket(test_mac, t0 + 30, &pkt) orelse return error.Build;
    const ip = ipv4.Header.parse(pkt[0..n]) orelse return error.Parse;
    try std.testing.expectEqualSlices(u8, &test_ip, &ip.src_ip);
    try std.testing.expectEqualSlices(u8, &test_server, &ip.dst_ip);
    const u = udp.Header.parse(pkt[ipv4.HEADER_SIZE..n]) orelse return error.Parse;
    try std.testing.expectEqual(DHCP_CLIENT_PORT, u.src_port);
    try std.testing.expectEqual(DHCP_SERVER_PORT, u.dst_port);
    const bootp = pkt[ipv4.HEADER_SIZE + udp.HEADER_SIZE .. n];
    try std.testing.expectEqual(MSG_REQUEST, testMsgType(bootp));
    try std.testing.expectEqualSlices(u8, &test_ip, bootp[12..16]);
    try std.testing.expectEqual(LeaseState.renewing, lease.state);

    // No answer: retried later, not on every poll; T2 broadcasts.
    try std.testing.expectEqual(Action.none, poll(t0 + 31));
    try std.testing.expectEqual(Action.renew, poll(t0 + 41));
    _ = buildRenewPacket(test_mac, t0 + 41, &pkt) orelse return error.Build;
    try std.testing.expectEqual(Action.rebind, poll(t0 + 52));
    var frame: [600]u8 = undefined;
    const fl = buildRebindFrame(test_mac, t0 + 52, &frame) orelse return error.Build;
    try std.testing.expectEqualSlices(u8, &ethernet.BROADCAST_MAC, frame[0..6]);
    const rb = frame[ethernet.HEADER_SIZE + ipv4.HEADER_SIZE + udp.HEADER_SIZE .. fl];
    try std.testing.expectEqual(MSG_REQUEST, testMsgType(rb));
    try std.testing.expectEqualSlices(u8, &test_ip, rb[12..16]);
    try std.testing.expectEqual(LeaseState.rebinding, lease.state);

    // Expiry: the lease is dropped.
    try std.testing.expectEqual(Action.none, poll(t0 + 53));
    try std.testing.expectEqual(Action.rediscover, poll(t0 + 60));
    try std.testing.expectEqual(LeaseState.idle, lease.state);
    try std.testing.expect(!lease.isValid());
}

test "dhcp: an ACK to the renewal restarts the lease timers" {
    const t0: u64 = 50;
    try testBind(t0, 60);
    try std.testing.expectEqual(Action.renew, poll(t0 + 30));
    var pkt: [600]u8 = undefined;
    _ = buildRenewPacket(test_mac, t0 + 30, &pkt) orelse return error.Build;
    const ack = testReply(MSG_ACK, 60);
    try std.testing.expect(processReplyAt(&ack, t0 + 31));
    try std.testing.expectEqual(LeaseState.bound, lease.state);
    try std.testing.expectEqual(Action.none, poll(t0 + 60)); // was the old expiry
    try std.testing.expectEqual(Action.renew, poll(t0 + 61));
}

test "dhcp: a NAK to the renewal drops the lease" {
    try testBind(0, 60);
    var pkt: [600]u8 = undefined;
    _ = buildRenewPacket(test_mac, 30, &pkt) orelse return error.Build;
    const nak = testReply(MSG_NAK, 60);
    try std.testing.expect(processReplyAt(&nak, 31));
    try std.testing.expect(!lease.isValid());
}

test "dhcp: forceRenew (after a sleep) renews before T1, and a long gap rediscovers" {
    try testBind(0, 3600);
    try std.testing.expectEqual(Action.none, poll(10));
    forceRenew();
    try std.testing.expectEqual(Action.renew, poll(11));
    try std.testing.expectEqual(Action.rediscover, poll(5000));
}

test "dhcp: a reply with another transaction ID is ignored" {
    try testBind(0, 60);
    var pkt: [600]u8 = undefined;
    _ = buildRenewPacket(test_mac, 30, &pkt) orelse return error.Build;
    var ack = testReply(MSG_ACK, 60);
    writeBe32(&ack, 4, lease.xid +% 1);
    try std.testing.expect(!processReplyAt(&ack, 31));
    try std.testing.expectEqual(LeaseState.renewing, lease.state);
}
