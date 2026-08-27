//! DNS Resolver (RFC 1035)
//!
//! Minimal DNS client for A record lookups. Sends queries over UDP to a
//! configured DNS server, parses responses, and maintains a simple cache.
//!
//! Zero allocation — static cache, static query/response buffers.
//! Only supports A (IPv4 address) record type.

const udp = @import("udp.sig");
const ipv4 = @import("ipv4.sig");

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

/// Transaction ID counter
var next_txid: u16 = 0xD500;

// ══════════════════════════════════════════════════════════════════════════════
// Public API
// ══════════════════════════════════════════════════════════════════════════════

/// Look up a hostname in the cache. Returns IP if cached and TTL > 0.
pub fn cacheLookup(name: []const u8) ?[4]u8 {
    for (&cache) |*e| {
        if (e.valid and e.name_len == name.len and
            strEqual(e.name[0..e.name_len], name))
        {
            return e.ip;
        }
    }
    return null;
}

/// Build a DNS query packet (UDP payload) for an A record.
/// Returns the query length, or null if name too long or buffer too small.
pub fn buildQuery(name: []const u8, buf: []u8) ?usize {
    if (name.len > MAX_NAME_LEN) return null;
    if (buf.len < MAX_QUERY_SIZE) return null;

    next_txid +%= 1;
    const txid = next_txid;

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

/// Build a complete UDP packet containing a DNS query.
/// Returns total IPv4 packet length, or null on error.
pub fn buildQueryPacket(
    name: []const u8,
    src_ip: [4]u8,
    dns_server: [4]u8,
    src_port: u16,
    pkt_buf: []u8,
) ?usize {
    // Build DNS query payload into a temp area
    var query_buf: [MAX_QUERY_SIZE]u8 = undefined;
    const query_len = buildQuery(name, &query_buf) orelse return null;

    // Build IPv4+UDP packet
    return udp.buildPacket(pkt_buf, src_ip, dns_server, src_port, DNS_PORT, query_buf[0..query_len]);
}

/// Parse a DNS response (UDP payload). If it contains an A record answer,
/// updates the cache and returns the IP address.
pub fn parseResponse(data: []const u8) ?[4]u8 {
    if (data.len < 12) return null;

    // Check flags: must be a response
    const flags = @as(u16, data[2]) << 8 | data[3];
    if (flags & FLAG_QR == 0) return null; // Not a response

    // Check RCODE
    if (flags & RCODE_MASK != 0) return null; // Error

    const qdcount = @as(u16, data[4]) << 8 | data[5];
    const ancount = @as(u16, data[6]) << 8 | data[7];

    if (ancount == 0) return null; // No answers

    // Skip question section
    var offset: usize = 12;
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        offset = skipName(data, offset) orelse return null;
        offset += 4; // QTYPE + QCLASS
        if (offset > data.len) return null;
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
            // Cache the result
            cacheInsert(ip, ttl);
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

// ══════════════════════════════════════════════════════════════════════════════
// Internal
// ══════════════════════════════════════════════════════════════════════════════

fn cacheInsert(ip: [4]u8, ttl: u32) void {
    // Find empty or oldest slot
    var slot: usize = 0;
    var min_ttl: u32 = 0xFFFFFFFF;
    for (&cache, 0..) |*e, idx| {
        if (!e.valid) { slot = idx; break; }
        if (e.ttl < min_ttl) { min_ttl = e.ttl; slot = idx; }
    }
    cache[slot].ip = ip;
    cache[slot].ttl = ttl;
    cache[slot].valid = true;
    // Name is set by the caller context (we don't have it here in parseResponse)
    // The net_stack integration handles name→cache binding at a higher level.
}

/// Store a name+IP in cache explicitly (used by net_stack after resolve).
pub fn cacheStore(name: []const u8, ip: [4]u8, ttl: u32) void {
    if (name.len > MAX_NAME_LEN) return;

    // Update existing
    for (&cache) |*e| {
        if (e.valid and e.name_len == name.len and strEqual(e.name[0..e.name_len], name)) {
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

fn strEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
