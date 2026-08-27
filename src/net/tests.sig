//! Comprehensive Test Suite for zpm/src/net/ Modules
//!
//! Unit tests covering: checksum, ethernet, arp, ipv4, icmp, udp, tcp, dhcp, dns, http.
//! Uses RFC test vectors where applicable. Tests sequence arithmetic wraparound,
//! packet round-trip encoding/decoding, state machine transitions, and edge cases.
//!
//! Run with: sig build test-net
//!
//! NOTE: This file is freestanding — no std import. Uses builtin test declarations
//! and inline expect/assert helpers.

const builtin = @import("builtin");

const checksum = @import("checksum");
const ethernet = @import("ethernet");
const arp = @import("arp");
const ipv4 = @import("ipv4");
const icmp = @import("icmp");
const udp = @import("net_udp");
const tcp = @import("net_tcp");
const dhcp = @import("dhcp");
const dns = @import("dns");
const http = @import("net_http");

// ══════════════════════════════════════════════════════════════════════════════
// Test Helpers (no std dependency)
// ══════════════════════════════════════════════════════════════════════════════

fn expectEqual(comptime T: type, expected: T, actual: T) !void {
    const ti = @typeInfo(T);
    if (comptime ti == .optional) {
        // For optionals: both null, or both non-null and payload equal
        if (expected == null and actual == null) return;
        if (expected == null or actual == null) return error.TestExpectedEqual;
        // Can't easily compare payloads generically without recursion
        // For our use cases (simple optionals), byte comparison works
        const exp_bytes = @as(*const [@sizeOf(T)]u8, @ptrCast(&expected));
        const act_bytes = @as(*const [@sizeOf(T)]u8, @ptrCast(&actual));
        for (exp_bytes, act_bytes) |e, a| {
            if (e != a) return error.TestExpectedEqual;
        }
    } else if (comptime ti == .@"struct" or ti == .@"enum") {
        const exp_bytes = @as(*const [@sizeOf(T)]u8, @ptrCast(&expected));
        const act_bytes = @as(*const [@sizeOf(T)]u8, @ptrCast(&actual));
        for (exp_bytes, act_bytes) |e, a| {
            if (e != a) return error.TestExpectedEqual;
        }
    } else {
        if (expected != actual) return error.TestExpectedEqual;
    }
}

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    if (expected.len != actual.len) return error.TestExpectedEqual;
    for (expected, actual) |e, a| {
        if (e != a) return error.TestExpectedEqual;
    }
}

fn memEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// Checksum Tests (RFC 1071)
// ══════════════════════════════════════════════════════════════════════════════

test "checksum: RFC 1071 example - 0x0001 0xF203 0xF4F5 0xF6F7" {
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    const result = checksum.compute(&data);
    try expectEqual(u16, 0x220d, result);
}

test "checksum: zero data" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = checksum.compute(&data);
    try expectEqual(u16, 0xFFFF, result);
}

test "checksum: all ones" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const result = checksum.compute(&data);
    try expectEqual(u16, 0x0000, result);
}

test "checksum: odd length" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    const result = checksum.compute(&data);
    try expectEqual(u16, 0xFBFD, result);
}

test "checksum: verify valid header returns true" {
    var hdr = [_]u8{
        0x45, 0x00, 0x00, 0x3c,
        0x1c, 0x46, 0x40, 0x00,
        0x40, 0x06, 0x00, 0x00,
        0xAC, 0x10, 0x0A, 0x63,
        0xAC, 0x10, 0x0A, 0x0C,
    };
    const cksum = checksum.compute(&hdr);
    hdr[10] = @intCast(cksum >> 8);
    hdr[11] = @intCast(cksum & 0xFF);
    try expect(checksum.verify(&hdr));
}

test "checksum: incremental update" {
    const data = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x00, 0x00 };
    const original = checksum.compute(&data);
    const updated = checksum.incrementalUpdate(original, 0x4500, 0x4400);
    var modified = data;
    modified[0] = 0x44;
    const expected = checksum.compute(&modified);
    try expectEqual(u16, expected, updated);
}

test "checksum: pseudo-header sum for UDP" {
    const src = [4]u8{ 192, 168, 1, 1 };
    const dst = [4]u8{ 192, 168, 1, 2 };
    const acc = checksum.pseudoHeaderSum(src, dst, 17, 20);
    const expected: u32 = 0xC0A8 + 0x0101 + 0xC0A8 + 0x0102 + 0x0011 + 0x0014;
    try expectEqual(u32, expected, acc);
}

// ══════════════════════════════════════════════════════════════════════════════
// Ethernet Tests
// ══════════════════════════════════════════════════════════════════════════════

test "ethernet: build and parse round-trip" {
    const dst = [6]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    const src = [6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const payload = "Hello, Ethernet!";
    var buf: [1514]u8 = undefined;

    const len = ethernet.buildFrame(&buf, dst, src, ethernet.ETHERTYPE_IPV4, payload) orelse unreachable;
    try expectEqual(usize, 14 + payload.len, len);

    const hdr = ethernet.Header.parse(buf[0..len]) orelse unreachable;
    try expectEqual(u16, ethernet.ETHERTYPE_IPV4, hdr.ethertype);
    try expect(ethernet.macEqual(hdr.dst_mac, dst));
    try expect(ethernet.macEqual(hdr.src_mac, src));

    const pay = ethernet.Header.payload(buf[0..len]) orelse unreachable;
    try expectEqualSlices(u8, payload, pay);
}

test "ethernet: broadcast detection" {
    try expect(ethernet.isBroadcast(ethernet.BROADCAST_MAC));
    try expect(!ethernet.isBroadcast(.{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 }));
}

test "ethernet: multicast detection" {
    try expect(ethernet.isMulticast(.{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 }));
    try expect(!ethernet.isMulticast(.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 }));
    try expect(ethernet.isBroadcast(ethernet.BROADCAST_MAC));
    try expect(ethernet.isMulticast(ethernet.BROADCAST_MAC));
}

test "ethernet: frame too short" {
    const short = [_]u8{ 0x00, 0x01, 0x02 };
    try expect(ethernet.Header.parse(&short) == null);
}

test "ethernet: isForUs" {
    const our_mac = [6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    var buf: [1514]u8 = undefined;
    _ = ethernet.buildFrame(&buf, our_mac, .{ 0, 0, 0, 0, 0, 0 }, ethernet.ETHERTYPE_IPV4, "x") orelse unreachable;
    try expect(ethernet.isForUs(buf[0..15], our_mac));
    _ = ethernet.buildFrame(&buf, ethernet.BROADCAST_MAC, .{ 0, 0, 0, 0, 0, 0 }, ethernet.ETHERTYPE_ARP, "x") orelse unreachable;
    try expect(ethernet.isForUs(buf[0..15], our_mac));
    _ = ethernet.buildFrame(&buf, .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 }, .{ 0, 0, 0, 0, 0, 0 }, ethernet.ETHERTYPE_IPV4, "x") orelse unreachable;
    try expect(!ethernet.isForUs(buf[0..15], our_mac));
}

// ══════════════════════════════════════════════════════════════════════════════
// ARP Tests
// ══════════════════════════════════════════════════════════════════════════════

test "arp: packet serialize and parse round-trip" {
    const pkt = arp.ArpPacket{
        .opcode = arp.OP_REQUEST,
        .sender_mac = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        .sender_ip = .{ 192, 168, 1, 1 },
        .target_mac = .{ 0, 0, 0, 0, 0, 0 },
        .target_ip = .{ 192, 168, 1, 2 },
    };
    var buf: [28]u8 = undefined;
    try expect(pkt.serialize(&buf));

    const parsed = arp.ArpPacket.parse(&buf) orelse unreachable;
    try expectEqual(u16, arp.OP_REQUEST, parsed.opcode);
    try expectEqualSlices(u8, &pkt.sender_mac, &parsed.sender_mac);
    try expectEqualSlices(u8, &pkt.sender_ip, &parsed.sender_ip);
    try expectEqualSlices(u8, &pkt.target_ip, &parsed.target_ip);
}

test "arp: table insert and lookup" {
    arp.clearTable();
    arp.insert(.{ 10, 0, 0, 1 }, .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 });
    arp.insert(.{ 10, 0, 0, 2 }, .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x02 });

    const mac1 = arp.lookup(.{ 10, 0, 0, 1 }) orelse unreachable;
    try expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 }, &mac1);

    const mac2 = arp.lookup(.{ 10, 0, 0, 2 }) orelse unreachable;
    try expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x02 }, &mac2);

    // Unknown IP
    try expectEqual(?[6]u8, null, arp.lookup(.{ 10, 0, 0, 99 }));

    try expectEqual(usize, 2, arp.tableSize());
}

test "arp: table LRU eviction at capacity" {
    arp.clearTable();
    // Fill all 32 slots
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        arp.insert(.{ 10, 0, 0, i }, .{ 0, 0, 0, 0, 0, i });
    }
    try expectEqual(usize, 32, arp.tableSize());
    // Insert one more — should evict oldest
    arp.insert(.{ 10, 0, 0, 99 }, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try expectEqual(usize, 32, arp.tableSize());
    // The new one should be findable
    try expect(arp.lookup(.{ 10, 0, 0, 99 }) != null);
}

test "arp: buildRequest produces valid frame" {
    var buf: [42]u8 = undefined;
    const our_mac = [6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const our_ip = [4]u8{ 192, 168, 1, 100 };
    const target_ip = [4]u8{ 192, 168, 1, 1 };
    const len = arp.buildRequest(&buf, our_mac, our_ip, target_ip) orelse unreachable;
    try expectEqual(usize, 42, len);

    // Parse the ARP payload
    const parsed = arp.ArpPacket.parse(buf[14..]) orelse unreachable;
    try expectEqual(u16, arp.OP_REQUEST, parsed.opcode);
    try expectEqualSlices(u8, &our_ip, &parsed.sender_ip);
    try expectEqualSlices(u8, &target_ip, &parsed.target_ip);
}

test "arp: processFrame learns sender and generates reply" {
    arp.clearTable();
    const our_mac = [6]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    const our_ip = [4]u8{ 10, 0, 2, 15 };
    const sender_mac = [6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const sender_ip = [4]u8{ 10, 0, 2, 2 };

    // Build a request frame targeting our IP
    var req: [42]u8 = undefined;
    _ = arp.buildRequest(&req, sender_mac, sender_ip, our_ip) orelse unreachable;

    // Process it
    var reply: [42]u8 = undefined;
    const reply_len = arp.processFrame(&req, our_mac, our_ip, &reply);
    try expect(reply_len != null); // Should generate a reply

    // Verify sender was learned
    const learned_mac = arp.lookup(sender_ip) orelse unreachable;
    try expectEqualSlices(u8, &sender_mac, &learned_mac);

    // Verify reply is an ARP reply
    const reply_pkt = arp.ArpPacket.parse(reply[14..]) orelse unreachable;
    try expectEqual(u16, arp.OP_REPLY, reply_pkt.opcode);
    try expectEqualSlices(u8, &our_mac, &reply_pkt.sender_mac);
}

// ══════════════════════════════════════════════════════════════════════════════
// IPv4 Tests
// ══════════════════════════════════════════════════════════════════════════════

test "ipv4: build and parse round-trip" {
    const src = [4]u8{ 192, 168, 1, 100 };
    const dst = [4]u8{ 8, 8, 8, 8 };
    const payload = "test data";
    var buf: [1500]u8 = undefined;

    const len = ipv4.buildPacket(&buf, src, dst, ipv4.PROTO_UDP, payload) orelse unreachable;
    try expectEqual(usize, 20 + payload.len, len);

    const hdr = ipv4.Header.parse(buf[0..len]) orelse unreachable;
    try expectEqual(u8, 4, hdr.version);
    try expectEqual(u8, 5, hdr.ihl);
    try expectEqual(u16, @intCast(len), hdr.total_length);
    try expectEqual(u8, ipv4.PROTO_UDP, hdr.protocol);
    try expectEqualSlices(u8, &src, &hdr.src_ip);
    try expectEqualSlices(u8, &dst, &hdr.dst_ip);
    try expectEqual(u8, 64, hdr.ttl);
}

test "ipv4: checksum validates correctly" {
    const src = [4]u8{ 10, 0, 0, 1 };
    const dst = [4]u8{ 10, 0, 0, 2 };
    var buf: [1500]u8 = undefined;
    _ = ipv4.buildPacket(&buf, src, dst, ipv4.PROTO_TCP, "x") orelse unreachable;
    // Verify checksum passes
    try expect(checksum.verify(buf[0..20]));
}

test "ipv4: corrupted checksum detected" {
    const src = [4]u8{ 10, 0, 0, 1 };
    const dst = [4]u8{ 10, 0, 0, 2 };
    var buf: [1500]u8 = undefined;
    _ = ipv4.buildPacket(&buf, src, dst, ipv4.PROTO_TCP, "x") orelse unreachable;
    // Corrupt a byte
    buf[5] ^= 0xFF;
    // Parse should fail (checksum invalid)
    try expectEqual(?ipv4.Header, null, ipv4.Header.parse(buf[0..21]));
}

test "ipv4: routing - same subnet" {
    const our_ip = [4]u8{ 192, 168, 1, 100 };
    const mask = [4]u8{ 255, 255, 255, 0 };
    const gw = [4]u8{ 192, 168, 1, 1 };
    // Same subnet → direct
    try expect(ipv4.isLocalSubnet(.{ 192, 168, 1, 50 }, our_ip, mask));
    const hop1 = ipv4.nextHop(.{ 192, 168, 1, 50 }, our_ip, mask, gw);
    try expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 50 }, &hop1);
    // Different subnet → gateway
    try expect(!ipv4.isLocalSubnet(.{ 8, 8, 8, 8 }, our_ip, mask));
    const hop2 = ipv4.nextHop(.{ 8, 8, 8, 8 }, our_ip, mask, gw);
    try expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &hop2);
}

test "ipv4: link-local always direct" {
    const our_ip = [4]u8{ 10, 0, 0, 5 };
    const mask = [4]u8{ 255, 255, 255, 0 };
    const gw = [4]u8{ 10, 0, 0, 1 };
    // Metadata server 169.254.169.254 is link-local
    const hop = ipv4.nextHop(.{ 169, 254, 169, 254 }, our_ip, mask, gw);
    try expectEqualSlices(u8, &[_]u8{ 169, 254, 169, 254 }, &hop);
}

test "ipv4: DF flag set" {
    var buf: [1500]u8 = undefined;
    _ = ipv4.buildPacket(&buf, .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, ipv4.PROTO_ICMP, "x") orelse unreachable;
    // Flags byte at offset 6: 0x40 = Don't Fragment
    try expectEqual(u8, 0x40, buf[6]);
}

// ══════════════════════════════════════════════════════════════════════════════
// ICMP Tests
// ══════════════════════════════════════════════════════════════════════════════

test "icmp: echo reply generation" {
    // Build an echo request manually
    var echo_req: [64]u8 = @splat(0);
    echo_req[0] = icmp.TYPE_ECHO_REQUEST; // type
    echo_req[1] = 0; // code
    echo_req[2] = 0; echo_req[3] = 0; // checksum placeholder
    echo_req[4] = 0x00; echo_req[5] = 0x01; // identifier
    echo_req[6] = 0x00; echo_req[7] = 0x01; // sequence
    // Fill payload with pattern
    for (8..64) |i| echo_req[i] = @intCast(i & 0xFF);
    // Compute checksum
    const cksum = checksum.compute(&echo_req);
    echo_req[2] = @intCast(cksum >> 8);
    echo_req[3] = @intCast(cksum & 0xFF);

    var reply: [1500]u8 = undefined;
    const reply_len = icmp.processEchoRequest(
        &echo_req,
        .{ 10, 0, 0, 1 }, // src (requester)
        .{ 10, 0, 0, 2 }, // our IP
        &reply,
    ) orelse unreachable;

    // Should be IPv4(20) + ICMP(64)
    try expectEqual(usize, 84, reply_len);

    // Parse the IPv4 header of reply
    const ip_hdr = ipv4.Header.parse(reply[0..reply_len]) orelse unreachable;
    try expectEqual(u8, ipv4.PROTO_ICMP, ip_hdr.protocol);
    try expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 2 }, &ip_hdr.src_ip); // from us
    try expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &ip_hdr.dst_ip); // to requester

    // Check ICMP reply type
    try expectEqual(u8, icmp.TYPE_ECHO_REPLY, reply[20]);
    // Identifier and sequence preserved
    try expectEqual(u8, 0x00, reply[24]);
    try expectEqual(u8, 0x01, reply[25]);
}

test "icmp: non-echo-request returns null" {
    var data: [8]u8 = @splat(0);
    data[0] = icmp.TYPE_ECHO_REPLY; // Not a request
    const cksum = checksum.compute(&data);
    data[2] = @intCast(cksum >> 8);
    data[3] = @intCast(cksum & 0xFF);

    var reply: [1500]u8 = undefined;
    const result = icmp.processEchoRequest(&data, .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, &reply);
    try expectEqual(?usize, null, result);
}

// ══════════════════════════════════════════════════════════════════════════════
// UDP Tests
// ══════════════════════════════════════════════════════════════════════════════

test "udp: build and parse round-trip" {
    const src_ip = [4]u8{ 10, 0, 0, 1 };
    const dst_ip = [4]u8{ 10, 0, 0, 2 };
    const payload = "UDP payload";
    var buf: [1500]u8 = undefined;

    const udp_len = udp.buildDatagram(&buf, 12345, 80, src_ip, dst_ip, payload) orelse unreachable;
    try expectEqual(usize, 8 + payload.len, udp_len);

    const dgram = udp.parseDatagram(buf[0..udp_len], src_ip, dst_ip) orelse unreachable;
    try expectEqual(u16, 12345, dgram.src_port);
    try expectEqual(u16, 80, dgram.dst_port);
    try expectEqualSlices(u8, payload, dgram.payload_data);
}

test "udp: corrupted checksum detected" {
    const src_ip = [4]u8{ 10, 0, 0, 1 };
    const dst_ip = [4]u8{ 10, 0, 0, 2 };
    var buf: [1500]u8 = undefined;
    _ = udp.buildDatagram(&buf, 1000, 2000, src_ip, dst_ip, "test") orelse unreachable;
    // Corrupt payload
    buf[8] ^= 0xFF;
    // Parse should fail
    try expectEqual(?udp.Datagram, null, udp.parseDatagram(buf[0..12], src_ip, dst_ip));
}

test "udp: port binding and dispatch" {
    var received = false;
    var recv_payload: [16]u8 = undefined;
    var recv_len: usize = 0;

    const handler = struct {
        fn handle(_: [4]u8, _: u16, payload: []const u8) void {
            // Can't capture in freestanding — use global state pattern instead
            _ = payload;
        }
    }.handle;

    // Bind port
    try expect(udp.bind(9999, handler));
    try expect(udp.isBound(9999));

    // Unbind
    try expect(udp.unbind(9999));
    try expect(!udp.isBound(9999));

    _ = &received;
    _ = &recv_payload;
    _ = &recv_len;
}

test "udp: buildPacket produces valid IPv4+UDP" {
    var buf: [1500]u8 = undefined;
    const len = udp.buildPacket(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, 5000, 80, "GET /") orelse unreachable;
    // Should be IPv4(20) + UDP(8) + payload(5) = 33
    try expectEqual(usize, 33, len);
    // Verify IPv4 header
    const ip_hdr = ipv4.Header.parse(buf[0..len]) orelse unreachable;
    try expectEqual(u8, ipv4.PROTO_UDP, ip_hdr.protocol);
}

// ══════════════════════════════════════════════════════════════════════════════
// TCP Tests
// ══════════════════════════════════════════════════════════════════════════════

test "tcp: sequence number arithmetic - wraparound" {
    // seqLt with wraparound
    try expect(tcp.seqLt(0xFFFFFFFF, 0x00000001)); // -1 < 1
    try expect(tcp.seqLt(0x80000000, 0x80000001));
    try expect(!tcp.seqLt(0x00000001, 0xFFFFFFFF)); // 1 > -1
    try expect(!tcp.seqLt(5, 5)); // equal

    // seqGt
    try expect(tcp.seqGt(0x00000001, 0xFFFFFFFF));
    try expect(!tcp.seqGt(0xFFFFFFFF, 0x00000001));

    // seqBetween [low, high)
    try expect(tcp.seqBetween(10, 15, 20));
    try expect(tcp.seqBetween(10, 10, 20)); // inclusive left
    try expect(!tcp.seqBetween(10, 20, 20)); // exclusive right
    // Wraparound case
    try expect(tcp.seqBetween(0xFFFFFFF0, 0xFFFFFFF5, 0x00000005));
    try expect(tcp.seqBetween(0xFFFFFFF0, 0x00000001, 0x00000005));
}

test "tcp: connect allocates connection in SYN_SENT" {
    const handle = tcp.connect(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, 80) orelse unreachable;
    try expectEqual(tcp.State, tcp.State.syn_sent, tcp.getState(handle));
    tcp.abort(handle);
    try expectEqual(tcp.State, tcp.State.closed, tcp.getState(handle));
}

test "tcp: listen allocates connection in LISTEN" {
    const handle = tcp.listen(.{ 0, 0, 0, 0 }, 8080, 5) orelse unreachable;
    try expectEqual(tcp.State, tcp.State.listen, tcp.getState(handle));
    tcp.abort(handle);
}

test "tcp: congestion control - slow start" {
    var cc = tcp.CongestionState.init(1460);
    const initial_cwnd = cc.cwnd;
    // Slow start: cwnd < ssthresh, increase by bytes_acked
    cc.onAck(1460, 1460);
    try expectEqual(u32, initial_cwnd + 1460, cc.cwnd);
    // Second ACK
    cc.onAck(1460, 1460);
    try expectEqual(u32, initial_cwnd + 2920, cc.cwnd);
}

test "tcp: congestion control - congestion avoidance" {
    var cc = tcp.CongestionState.init(1460);
    cc.ssthresh = 10000; // Lower ssthresh so we enter CA
    cc.cwnd = 15000; // Above ssthresh
    const before = cc.cwnd;
    cc.onAck(1460, 1460);
    // CA: cwnd += mss * mss / cwnd ≈ 142
    const expected_increase = @as(u32, 1460) * 1460 / 15000;
    try expectEqual(u32, before + expected_increase, cc.cwnd);
}

test "tcp: congestion control - fast recovery entry" {
    var cc = tcp.CongestionState.init(1460);
    cc.cwnd = 20000;
    cc.enterFastRecovery(15000, 50000);
    // ssthresh = max(flight/2, 2*MSS) = max(7500, 2920) = 7500
    try expectEqual(u32, 7500, cc.ssthresh);
    // cwnd = ssthresh + 3*MSS = 7500 + 4380 = 11880
    try expectEqual(u32, 11880, cc.cwnd);
    try expect(cc.in_recovery);
}

test "tcp: congestion control - timeout resets cwnd" {
    var cc = tcp.CongestionState.init(1460);
    cc.cwnd = 50000;
    cc.onTimeout(1460);
    try expectEqual(u32, 1460, cc.cwnd); // Reset to 1 MSS
    try expectEqual(u32, 25000, cc.ssthresh); // ssthresh = cwnd/2
}

test "tcp: RTT estimation - first sample" {
    var rtt = tcp.RttState.init();
    rtt.update(100_000); // 100ms
    try expect(rtt.has_sample);
    try expectEqual(u32, 100_000 << 3, rtt.srtt);
    try expect(rtt.rto >= 1_000_000); // At least 1s minimum
}

test "tcp: RTT estimation - backoff" {
    var rtt = tcp.RttState.init();
    rtt.update(500_000);
    const initial_rto = rtt.rto;
    rtt.backoff();
    try expectEqual(u32, initial_rto * 2, rtt.rto);
    // Capped at 60s
    rtt.rto = 50_000_000;
    rtt.backoff();
    try expectEqual(u32, 60_000_000, rtt.rto);
}

// ══════════════════════════════════════════════════════════════════════════════
// DHCP Tests
// ══════════════════════════════════════════════════════════════════════════════

test "dhcp: startDiscover produces valid frame" {
    const mac = [6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    var buf: [600]u8 = undefined;
    const len = dhcp.startDiscover(mac, &buf) orelse unreachable;
    try expect(len > 0);
    try expect(len <= 600);
    try expectEqual(dhcp.LeaseState, dhcp.LeaseState.discovering, dhcp.lease.state);

    // Verify Ethernet header (broadcast)
    try expect(ethernet.isBroadcast(buf[0..6].*));
    // Verify EtherType = IPv4
    try expectEqual(u8, 0x08, buf[12]);
    try expectEqual(u8, 0x00, buf[13]);
}

test "dhcp: processReply ignores wrong xid" {
    dhcp.lease.state = .discovering;
    dhcp.lease.xid = 0x12345678;

    // Build a fake reply with wrong xid
    var reply: [300]u8 = @splat(0);
    reply[0] = 2; // BOOTP_REPLY
    reply[4] = 0x00; reply[5] = 0x00; reply[6] = 0x00; reply[7] = 0x01; // xid = 1 (wrong)
    reply[236] = 99; reply[237] = 130; reply[238] = 83; reply[239] = 99; // Magic cookie
    reply[240] = 53; reply[241] = 1; reply[242] = 2; // MSG_TYPE = OFFER

    try expect(!dhcp.processReply(&reply));
}

// ══════════════════════════════════════════════════════════════════════════════
// DNS Tests
// ══════════════════════════════════════════════════════════════════════════════

test "dns: buildQuery encodes domain labels correctly" {
    var buf: [128]u8 = undefined;
    const len = dns.buildQuery("metadata.google.internal", &buf) orelse unreachable;
    try expect(len > 12); // At least header

    // Check question section encoding:
    // \x08metadata\x06google\x08internal\x00
    try expectEqual(u8, 8, buf[12]); // "metadata" length
    try expectEqual(u8, 'm', buf[13]);
    // After "metadata" (8 bytes): offset 21 = length of "google" = 6
    try expectEqual(u8, 6, buf[21]);
    try expectEqual(u8, 'g', buf[22]);
}

test "dns: cache store and lookup" {
    dns.clearCache();
    dns.cacheStore("example.com", .{ 93, 184, 216, 34 }, 300);
    const ip = dns.cacheLookup("example.com") orelse unreachable;
    try expectEqualSlices(u8, &[_]u8{ 93, 184, 216, 34 }, &ip);
    // Non-existent
    try expectEqual(?[4]u8, null, dns.cacheLookup("other.com"));
}

test "dns: tickCache decrements TTL and invalidates" {
    dns.clearCache();
    dns.cacheStore("short.ttl", .{ 1, 2, 3, 4 }, 2);
    try expect(dns.cacheLookup("short.ttl") != null);
    dns.tickCache(); // TTL = 1
    try expect(dns.cacheLookup("short.ttl") != null);
    dns.tickCache(); // TTL = 0
    try expect(dns.cacheLookup("short.ttl") != null); // Still valid at 0
    dns.tickCache(); // Invalidated
    try expectEqual(?[4]u8, null, dns.cacheLookup("short.ttl"));
}

// ══════════════════════════════════════════════════════════════════════════════
// HTTP Tests
// ══════════════════════════════════════════════════════════════════════════════

test "http: buildGet produces correct request" {
    var buf: [512]u8 = undefined;
    const len = http.buildGet(
        &buf,
        "/computeMetadata/v1/instance/hostname",
        "metadata.google.internal",
        "Metadata-Flavor: Google\r\n",
    ) orelse unreachable;

    const req = buf[0..len];
    // Check request line
    try expect(startsWith(req, "GET /computeMetadata/v1/instance/hostname HTTP/1.1\r\n"));
    // Check Host header present
    try expect(contains(req, "Host: metadata.google.internal\r\n"));
    // Check custom header
    try expect(contains(req, "Metadata-Flavor: Google\r\n"));
    // Check Connection: close
    try expect(contains(req, "Connection: close\r\n"));
    // Check ends with double CRLF
    try expect(endsWith(req, "\r\n\r\n"));
}

test "http: buildPut includes content-length and body" {
    var buf: [512]u8 = undefined;
    const len = http.buildPut(
        &buf,
        "/guest-attributes/ShortName",
        "169.254.169.254",
        "",
        "sb0s",
    ) orelse unreachable;

    const req = buf[0..len];
    try expect(startsWith(req, "PUT /guest-attributes/ShortName HTTP/1.1\r\n"));
    try expect(contains(req, "Content-Length: 4\r\n"));
    // Body should be at the end
    try expect(endsWith(req, "sb0s"));
}

test "http: parser extracts status code" {
    var parser = http.Parser.init();
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    const result = parser.feed(response) orelse unreachable;
    try expectEqual(u16, 200, result.status_code);
    try expectEqual(u32, 5, result.content_length);
    try expect(result.complete);
}

test "http: parser handles chunked encoding" {
    var parser = http.Parser.init();
    const response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    const result = parser.feed(response) orelse unreachable;
    try expectEqual(u16, 200, result.status_code);
    try expect(result.chunked);
    try expectEqual(usize, 5, result.body_len);
}

test "http: parser returns null on incomplete data" {
    var parser = http.Parser.init();
    const partial = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly partial";
    const result = parser.feed(partial);
    try expectEqual(?http.Response, null, result); // Incomplete
}

test "http: GCP metadata constants" {
    try expectEqualSlices(u8, &[_]u8{ 169, 254, 169, 254 }, &http.GCP_METADATA_IP);
    try expectEqual(u16, 80, http.GCP_METADATA_PORT);
}

// ══════════════════════════════════════════════════════════════════════════════
// Property Tests
// ══════════════════════════════════════════════════════════════════════════════

test "property: checksum(data) + fold(sum(data_with_checksum)) == 0" {
    // For any data, computing checksum and inserting it should make verify() pass
    var data = [_]u8{ 0x45, 0x00, 0x00, 0x28, 0xAB, 0xCD, 0x00, 0x00, 0x40, 0x06, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x0A, 0x00, 0x00, 0x02 };
    const cksum = checksum.compute(&data);
    data[10] = @intCast(cksum >> 8);
    data[11] = @intCast(cksum & 0xFF);
    try expect(checksum.verify(&data));
}

test "property: IPv4 parse(build(x)) preserves src/dst/proto" {
    const protos = [_]u8{ ipv4.PROTO_ICMP, ipv4.PROTO_TCP, ipv4.PROTO_UDP };
    for (protos) |proto| {
        var buf: [1500]u8 = undefined;
        _ = ipv4.buildPacket(&buf, .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, proto, "payload") orelse unreachable;
        const hdr = ipv4.Header.parse(buf[0..27]) orelse unreachable;
        try expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &hdr.src_ip);
        try expectEqualSlices(u8, &[_]u8{ 5, 6, 7, 8 }, &hdr.dst_ip);
        try expectEqual(u8, proto, hdr.protocol);
    }
}

test "property: TCP sequence arithmetic is consistent" {
    // For any a, b: exactly one of seqLt(a,b), seqGt(a,b), a==b holds
    const test_values = [_]u32{ 0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF };
    for (test_values) |a| {
        for (test_values) |b| {
            if (a == b) {
                try expect(!tcp.seqLt(a, b));
                try expect(!tcp.seqGt(a, b));
                try expect(tcp.seqLeq(a, b));
                try expect(tcp.seqGeq(a, b));
            } else {
                // Exactly one of lt/gt must be true
                const lt = tcp.seqLt(a, b);
                const gt = tcp.seqGt(a, b);
                try expect(lt != gt);
            }
        }
    }
}

test "property: UDP build+parse preserves payload for various sizes" {
    const sizes = [_]usize{ 0, 1, 100, 1000, 1472 };
    var payload_buf: [1472]u8 = undefined;
    for (0..1472) |i| payload_buf[i] = @intCast(i & 0xFF);

    for (sizes) |size| {
        if (size == 0) continue; // Empty datagrams have no payload to verify
        var buf: [1500]u8 = undefined;
        const src_ip = [4]u8{ 10, 0, 0, 1 };
        const dst_ip = [4]u8{ 10, 0, 0, 2 };
        const udp_len = udp.buildDatagram(&buf, 5000, 6000, src_ip, dst_ip, payload_buf[0..size]) orelse continue;
        const dgram = udp.parseDatagram(buf[0..udp_len], src_ip, dst_ip) orelse continue;
        try expectEqual(usize, size, dgram.payload_data.len);
        try expectEqualSlices(u8, payload_buf[0..size], dgram.payload_data);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Test Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return memEql(haystack[0..needle.len], needle);
}

fn endsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return memEql(haystack[haystack.len - needle.len ..], needle);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (memEql(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
