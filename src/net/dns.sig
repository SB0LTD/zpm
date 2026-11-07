//! DNS Resolver (RFC 1035)
//!
//! Minimal DNS client for A record lookups. Sends queries over UDP to a
//! configured DNS server, parses responses, and maintains a simple cache.
//!
//! Zero allocation — static cache, static query/response buffers.
//! Only supports A (IPv4 address) record type.
//!
//! Anti-spoofing: one query is outstanding at a time. The caller picks a
//! random transaction ID and source port (from its CSPRNG) per query, and a
//! response is accepted only when it comes from the server the query went
//! to, from port 53, to that port, with that ID and that question name.
//! Everything else is dropped. Cached answers live at most MAX_TTL.
//!
//! Host tests: `sig build test-net-dns` in zpm, or directly (from zpm/src/net):
//!   sig test --dep net_udp --dep net_ipv4 -Mroot=dns.sig \
//!     --dep net_ipv4 --dep net_checksum -Mnet_udp=udp.sig \
//!     --dep net_checksum -Mnet_ipv4=ipv4.sig -Mnet_checksum=checksum.sig

const std = @import("std");
const udp = @import("net_udp");
const ipv4 = @import("net_ipv4");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

const DNS_PORT: u16 = 53;
const MAX_QUERY_SIZE: usize = 128; // Enough for short hostnames
const MAX_RESPONSE_SIZE: usize = 512; // Standard DNS UDP limit

// Record types
const TYPE_A: u16 = 1; // IPv4 address
const CLASS_IN: u16 = 1; // Internet

// Header flags
const FLAG_QR: u16 = 0x8000; // Response
const FLAG_RD: u16 = 0x0100; // Recursion Desired
const FLAG_RA: u16 = 0x0080; // Recursion Available
const RCODE_MASK: u16 = 0x000F;

// ══════════════════════════════════════════════════════════════════════════════
// DNS Cache
// ══════════════════════════════════════════════════════════════════════════════

const CACHE_SIZE: usize = 8;
const MAX_NAME_LEN: usize = 64;

/// Cap on how long an answer stays cached (seconds), whatever its TTL says:
/// a poisoned or stale entry cannot outlive this.
pub const MAX_TTL: u32 = 3600;
/// Floor on a cached answer's lifetime (seconds), so TTL 0 still serves the
/// lookup that asked for it.
pub const MIN_TTL: u32 = 30;

const CacheEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    ip: [4]u8,
    ttl: u32, // Remaining TTL in seconds
    valid: bool,
};

var cache: [CACHE_SIZE]CacheEntry = blk: {
    var c: [CACHE_SIZE]CacheEntry = undefined;
    for (&c) |*e| {
        e.name = @splat(0);
        e.name_len = 0;
        e.ip = .{ 0, 0, 0, 0 };
        e.ttl = 0;
        e.valid = false;
    }
    break :blk c;
};

/// The one outstanding query: what a response must match to be accepted.
const Pending = struct {
    active: bool = false,
    name: [MAX_NAME_LEN]u8 = @splat(0),
    name_len: u8 = 0,
    txid: u16 = 0,
    port: u16 = 0,
    server: [4]u8 = .{ 0, 0, 0, 0 },
};

var pending: Pending = .{};

// ══════════════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════════════

/// Look up a hostname in the cache (case-insensitive). Returns IP if
/// cached and TTL > 0.
pub fn cacheLookup(name: []const u8) ?[4]u8 {
    for (&cache) |*e| {
        if (e.valid and e.name_len == name.len and
            std.ascii.eqlIgnoreCase(e.name[0..e.name_len], name))
        {
            return e.ip;
        }
    }
    return null;
}

/// Build a DNS query packet (UDP payload) for an A record with transaction
/// ID `txid`. Returns the query length, or null if name too long or buffer
/// too small.
pub fn buildQuery(name: []const u8, txid: u16, buf: []u8) ?usize {
    if (name.len > MAX_NAME_LEN) return null;
    if (buf.len < MAX_QUERY_SIZE) return null;

    // DNS Header (12 bytes)
    // Transaction ID
    buf[0] = @intCast(txid >> 8);
    buf[1] = @intCast(txid & 0xFF);
    // Flags: standard query, recursion desired
    buf[2] = @intCast(FLAG_RD >> 8);
    buf[3] = @intCast(FLAG_RD & 0xFF);
    // QDCOUNT = 1
    buf[4] = 0; buf[5] = 1;
    // ANCOUNT = 0
    buf[6] = 0; buf[7] = 0;
    // NSCOUNT = 0
    buf[8] = 0; buf[9] = 0;
    // ARCOUNT = 0
    buf[10] = 0; buf[11] = 0;

    // Question section: encode domain name
    var offset: usize = 12;
    var name_start: usize = 0;

    // Convert "metadata.google.internal" → "\x08metadata\x06google\x08internal\x00"
    while (name_start <= name.len) {
        // Find next dot or end of string
        var dot_pos: usize = name_start;
        while (dot_pos < name.len and name[dot_pos] != '.') : (dot_pos += 1) {}

        const label_len = dot_pos - name_start;
        if (label_len == 0) {
            if (name_start == name.len) break; // trailing dot
            return null; // empty label
        }
        if (label_len > 63) return null; // label too long
        if (offset + 1 + label_len >= buf.len) return null;

        buf[offset] = @intCast(label_len);
        offset += 1;
        @memcpy(buf[offset..][0..label_len], name[name_start..][0..label_len]);
        offset += label_len;

        name_start = dot_pos + 1;
    }

    // Terminating zero-length label
    if (offset >= buf.len) return null;
    buf[offset] = 0;
    offset += 1;

    // QTYPE = A (1)
    if (offset + 4 > buf.len) return null;
    buf[offset] = 0; buf[offset + 1] = 1; // TYPE_A
    offset += 2;
    // QCLASS = IN (1)
    buf[offset] = 0; buf[offset + 1] = 1; // CLASS_IN
    offset += 2;

    return offset;
}

/// Build a complete UDP packet containing a DNS query, and make it the
/// pending query (replacing any earlier one). `txid` and `src_port` must be
/// unpredictable (fresh CSPRNG output per query).
/// Returns total IPv4 packet length, or null on error.
pub fn buildQueryPacket(
    name: []const u8,
    src_ip: [4]u8,
    dns_server: [4]u8,
    src_port: u16,
    txid: u16,
    pkt_buf: []u8,
) ?usize {
    // Build DNS query payload into a temp area
    var query_buf: [MAX_QUERY_SIZE]u8 = undefined;
    const query_len = buildQuery(name, txid, &query_buf) orelse return null;

    // Build IPv4+UDP packet
    const n = udp.buildPacket(pkt_buf, src_ip, dns_server, src_port, DNS_PORT, query_buf[0..query_len]) orelse return null;
    beginQuery(name, txid, src_port, dns_server);
    return n;
}

/// Record the pending query a response must match (buildQueryPacket does
/// this; exposed for callers that build their own packets).
pub fn beginQuery(name: []const u8, txid: u16, src_port: u16, dns_server: [4]u8) void {
    var n = name.len;
    if (n > 0 and name[n - 1] == '.') n -= 1; // "a.b." asks for "a.b"
    if (n > MAX_NAME_LEN) {
        pending.active = false;
        return;
    }
    for (name[0..n], 0..) |c, i| pending.name[i] = std.ascii.toLower(c);
    pending.name_len = @intCast(n);
    pending.txid = txid;
    pending.port = src_port;
    pending.server = dns_server;
    pending.active = true;
}

/// Forget the pending query: no response is accepted until the next one.
pub fn cancelQuery() void {
    pending.active = false;
}

/// Whether a query is outstanding.
pub fn queryPending() bool {
    return pending.active;
}

/// A UDP datagram that may be the answer to the pending query. Accepted
/// (cached, and the IP returned) only when it comes from the server the
/// query went to, from port 53, to the query's source port, with its
/// transaction ID and question name. Everything else returns null and
/// changes nothing.
pub fn acceptResponse(src_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) ?[4]u8 {
    if (!pending.active) return null;
    if (src_port != DNS_PORT or dst_port != pending.port) return null;
    if (!std.mem.eql(u8, &src_ip, &pending.server)) return null;
    return parseResponse(data);
}

/// Parse a DNS response (UDP payload) to the pending query: its transaction
/// ID and (single) question must match. If it contains an A record answer,
/// updates the cache and returns the IP address. Addressing is not checked
/// here; network input goes through acceptResponse.
pub fn parseResponse(data: []const u8) ?[4]u8 {
    if (data.len < 12) return null;
    if (!pending.active) return null;

    // Transaction ID must be the pending query's.
    const txid = @as(u16, data[0]) << 8 | data[1];
    if (txid != pending.txid) return null;

    // Check flags: must be a response
    const flags = @as(u16, data[2]) << 8 | data[3];
    if (flags & FLAG_QR == 0) return null; // Not a response

    // Check RCODE
    if (flags & RCODE_MASK != 0) return null; // Error

    const qdcount = @as(u16, data[4]) << 8 | data[5];
    const ancount = @as(u16, data[6]) << 8 | data[7];

    // Exactly our one question, for our name (case-insensitively: servers
    // echo the case we sent, but 0x20 randomization may be added later).
    if (qdcount != 1) return null;
    var qname_buf: [MAX_NAME_LEN]u8 = undefined;
    const qname_len = decodeName(data, 12, &qname_buf) orelse return null;
    if (!std.mem.eql(u8, qname_buf[0..qname_len], pending.name[0..pending.name_len])) return null;

    // A matching answer settles the query, whether or not it has an address.
    pending.active = false;
    if (ancount == 0) return null; // No answers

    // Skip question section
    var offset: usize = 12;
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        offset = skipName(data, offset) orelse return null;
        if (offset + 4 > data.len) return null;
        const qtype = @as(u16, data[offset]) << 8 | data[offset + 1];
        const qclass = @as(u16, data[offset + 2]) << 8 | data[offset + 3];
        if (qtype != TYPE_A or qclass != CLASS_IN) return null;
        offset += 4; // QTYPE + QCLASS
    }

    // Parse answers — find first A record
    var a: u16 = 0;
    while (a < ancount) : (a += 1) {
        // Skip name (may be compressed pointer)
        offset = skipName(data, offset) orelse return null;
        if (offset + 10 > data.len) return null;

        const rtype = @as(u16, data[offset]) << 8 | data[offset + 1];
        const rclass = @as(u16, data[offset + 2]) << 8 | data[offset + 3];
        const ttl = @as(u32, data[offset + 4]) << 24 |
            @as(u32, data[offset + 5]) << 16 |
            @as(u32, data[offset + 6]) << 8 |
            data[offset + 7];
        const rdlength = @as(u16, data[offset + 8]) << 8 | data[offset + 9];
        offset += 10;

        if (offset + rdlength > data.len) return null;

        if (rtype == TYPE_A and rclass == CLASS_IN and rdlength == 4) {
            const ip = data[offset..][0..4].*;
            // Cache under the queried name (so cacheLookup finds it). TTL is
            // clamped to [MIN_TTL, MAX_TTL].
            cacheStore(qname_buf[0..qname_len], ip, std.math.clamp(ttl, MIN_TTL, MAX_TTL));
            return ip;
        }

        offset += rdlength;
    }

    return null;
}

/// Decrement TTL on all cache entries. Call once per second.
/// Entries with TTL=0 are invalidated.
pub fn tickCache() void {
    for (&cache) |*e| {
        if (e.valid) {
            if (e.ttl > 0) {
                e.ttl -= 1;
            } else {
                e.valid = false;
            }
        }
    }
}

/// Clear the DNS cache.
pub fn clearCache() void {
    for (&cache) |*e| {
        e.valid = false;
    }
}

/// The network changed (another interface, a new lease or DNS server):
/// drop every cached answer and the pending query.
pub fn reset() void {
    clearCache();
    cancelQuery();
}

// ══════════════════════════════════════════════════════════════════════════════
// Internal
// ══════════════════════════════════════════════════════════════════════════════

/// Decode an uncompressed name (the question section) as "a.b.c",
/// lower-cased. Returns the length, or null if it does not fit.
fn decodeName(data: []const u8, start: usize, out: []u8) ?usize {
    var offset = start;
    var n: usize = 0;
    while (offset < data.len) {
        const len: usize = data[offset];
        if (len == 0) return n;
        if (len & 0xC0 != 0) return null; // compressed: not in questions
        if (offset + 1 + len > data.len) return null;
        if (n != 0) {
            if (n >= out.len) return null;
            out[n] = '.';
            n += 1;
        }
        if (n + len > out.len) return null;
        for (data[offset + 1 .. offset + 1 + len], 0..) |c, i| out[n + i] = std.ascii.toLower(c);
        n += len;
        offset += 1 + len;
    }
    return null;
}

/// Store a name+IP in cache explicitly (used by net_stack after resolve).
pub fn cacheStore(name: []const u8, ip: [4]u8, ttl_in: u32) void {
    if (name.len > MAX_NAME_LEN) return;
    const ttl = @min(ttl_in, MAX_TTL);

    // Update existing
    for (&cache) |*e| {
        if (e.valid and e.name_len == name.len and std.ascii.eqlIgnoreCase(e.name[0..e.name_len], name)) {
            e.ip = ip;
            e.ttl = ttl;
            return;
        }
    }

    // Find empty or LRU slot
    var slot: usize = 0;
    var min_ttl: u32 = 0xFFFFFFFF;
    for (&cache, 0..) |*e, idx| {
        if (!e.valid) { slot = idx; break; }
        if (e.ttl < min_ttl) { min_ttl = e.ttl; slot = idx; }
    }
    @memcpy(cache[slot].name[0..name.len], name);
    cache[slot].name_len = @intCast(name.len);
    cache[slot].ip = ip;
    cache[slot].ttl = ttl;
    cache[slot].valid = true;
}

fn skipName(data: []const u8, start: usize) ?usize {
    var offset = start;
    while (offset < data.len) {
        const len = data[offset];
        if (len == 0) {
            return offset + 1; // Zero-length label = end
        }
        if (len & 0xC0 == 0xC0) {
            // Compression pointer (2 bytes)
            return offset + 2;
        }
        offset += 1 + @as(usize, len);
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const test_server = [4]u8{ 10, 0, 2, 3 };
const test_port: u16 = 54321;
const test_txid: u16 = 0x1234;

/// A response for "API.Example.com" A → 1.2.3.4 with TTL `ttl` (the answer's
/// name is a compression pointer to the question).
fn testResponse(txid: u16, ttl: u32) [49]u8 {
    var r = [_]u8{
        0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        3, 'A', 'P', 'I', 7, 'E', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0,
        0x00, 0x01, 0x00, 0x01,
        0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 1, 2, 3, 4,
    };
    r[0] = @intCast(txid >> 8);
    r[1] = @intCast(txid & 0xFF);
    std.mem.writeInt(u32, r[39..43], ttl, .big);
    return r;
}

fn testBegin(name: []const u8) void {
    reset();
    beginQuery(name, test_txid, test_port, test_server);
}

test "dns: an A answer is cached under the queried name" {
    testBegin("api.example.com");
    const resp = testResponse(test_txid, 300);
    const ip = acceptResponse(test_server, 53, test_port, &resp) orelse return error.NoAnswer;
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, ip);
    const hit = cacheLookup("api.example.com") orelse return error.NotCached;
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, hit);
    try std.testing.expect(cacheLookup("API.example.COM") != null);
    // The query is settled: a replay is not accepted again.
    try std.testing.expect(!queryPending());
    try std.testing.expect(acceptResponse(test_server, 53, test_port, &resp) == null);
}

test "dns: a wrong transaction ID is ignored" {
    testBegin("api.example.com");
    const resp = testResponse(test_txid ^ 1, 300);
    try std.testing.expect(acceptResponse(test_server, 53, test_port, &resp) == null);
    try std.testing.expect(cacheLookup("api.example.com") == null);
    try std.testing.expect(queryPending()); // the real answer can still come
}

test "dns: an answer for a different name is ignored" {
    testBegin("bank.example.org");
    const resp = testResponse(test_txid, 300); // answers api.example.com
    try std.testing.expect(acceptResponse(test_server, 53, test_port, &resp) == null);
    try std.testing.expect(cacheLookup("api.example.com") == null);
    try std.testing.expect(cacheLookup("bank.example.org") == null);
}

test "dns: a response from a host other than the server is ignored" {
    testBegin("api.example.com");
    const resp = testResponse(test_txid, 300);
    try std.testing.expect(acceptResponse(.{ 10, 0, 2, 99 }, 53, test_port, &resp) == null);
    try std.testing.expect(acceptResponse(test_server, 5353, test_port, &resp) == null);
    try std.testing.expect(acceptResponse(test_server, 53, test_port + 1, &resp) == null);
    try std.testing.expect(cacheLookup("api.example.com") == null);
    // ... and the genuine one still lands afterwards.
    try std.testing.expect(acceptResponse(test_server, 53, test_port, &resp) != null);
}

test "dns: an unsolicited response is ignored" {
    reset();
    const resp = testResponse(test_txid, 300);
    try std.testing.expect(acceptResponse(test_server, 53, test_port, &resp) == null);
    try std.testing.expect(parseResponse(&resp) == null);
    try std.testing.expect(cacheLookup("api.example.com") == null);
}

test "dns: the cached TTL is capped at an hour, and reset flushes" {
    testBegin("api.example.com");
    const resp = testResponse(test_txid, 7 * 86400);
    _ = acceptResponse(test_server, 53, test_port, &resp) orelse return error.NoAnswer;
    var t: u32 = 0;
    while (t <= MAX_TTL) : (t += 1) tickCache();
    try std.testing.expect(cacheLookup("api.example.com") == null);

    testBegin("api.example.com");
    _ = acceptResponse(test_server, 53, test_port, &resp) orelse return error.NoAnswer;
    reset();
    try std.testing.expect(cacheLookup("api.example.com") == null);
}

test "dns: the query carries the transaction ID it is matched on" {
    var buf: [MAX_QUERY_SIZE]u8 = undefined;
    const n = buildQuery("api.example.com", 0xBEEF, &buf) orelse return error.Build;
    try std.testing.expect(n > 12);
    try std.testing.expectEqual(@as(u8, 0xBE), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xEF), buf[1]);
}
