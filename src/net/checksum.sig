//! Internet Checksum (RFC 1071)
//!
//! One's complement sum over 16-bit words. Used by IPv4, ICMP, TCP, UDP.
//! Zero allocation. All functions operate on caller-provided slices.
//!
//! Reference: RFC 1071 — Computing the Internet Checksum

// ══════════════════════════════════════════════════════════════════════════════
// Core Checksum Computation
// ══════════════════════════════════════════════════════════════════════════════

/// Compute the Internet checksum (one's complement of one's complement sum)
/// over `data`. Returns the 16-bit checksum in network byte order (big-endian).
pub fn compute(data: []const u8) u16 {
    return fold(sum(data));
}

/// Accumulate one's complement sum without folding. Use this to combine
/// multiple regions (e.g., pseudo-header + TCP header + payload) before
/// a single fold at the end.
pub fn sum(data: []const u8) u32 {
    var acc: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        acc += @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
    }

    // Handle odd trailing byte
    if (i < data.len) {
        acc += @as(u32, data[i]) << 8;
    }

    return acc;
}

/// Fold a 32-bit accumulator down to 16-bit one's complement and invert.
/// Returns the final checksum value ready to be placed in a header.
pub fn fold(acc: u32) u16 {
    var s = acc;
    // Fold carry bits until we fit in 16 bits
    while (s > 0xFFFF) {
        s = (s & 0xFFFF) + (s >> 16);
    }
    return @intCast(~s & 0xFFFF);
}

/// Combine two partial sums. Useful for building checksum from disjoint regions.
pub fn combine(a: u32, b: u32) u32 {
    return a + b;
}

// ══════════════════════════════════════════════════════════════════════════════
// Pseudo-Header Checksum (for TCP/UDP)
// ══════════════════════════════════════════════════════════════════════════════

/// Compute the IPv4 pseudo-header partial sum for TCP or UDP checksum.
/// Parameters:
///   src_ip   — source IPv4 address (4 bytes, network order)
///   dst_ip   — destination IPv4 address (4 bytes, network order)
///   protocol — IP protocol number (6=TCP, 17=UDP)
///   length   — length of the L4 segment (header + payload) in bytes
pub fn pseudoHeaderSum(src_ip: [4]u8, dst_ip: [4]u8, protocol: u8, length: u16) u32 {
    var acc: u32 = 0;
    // Source IP (2 × 16-bit words)
    acc += @as(u32, src_ip[0]) << 8 | @as(u32, src_ip[1]);
    acc += @as(u32, src_ip[2]) << 8 | @as(u32, src_ip[3]);
    // Destination IP (2 × 16-bit words)
    acc += @as(u32, dst_ip[0]) << 8 | @as(u32, dst_ip[1]);
    acc += @as(u32, dst_ip[2]) << 8 | @as(u32, dst_ip[3]);
    // Zero + Protocol
    acc += @as(u32, protocol);
    // L4 length
    acc += @as(u32, length);
    return acc;
}

// ══════════════════════════════════════════════════════════════════════════════
// Incremental Update (RFC 1624)
// ══════════════════════════════════════════════════════════════════════════════

/// Incrementally update a checksum when a 16-bit field changes.
/// `old_checksum` is the current checksum (network byte order value).
/// `old_value` and `new_value` are the 16-bit values being replaced.
/// Returns the updated checksum.
///
/// Per RFC 1624:  HC' = ~(~HC + ~m + m')
pub fn incrementalUpdate(old_checksum: u16, old_value: u16, new_value: u16) u16 {
    // Work in one's complement arithmetic
    var acc: u32 = @as(u32, ~old_checksum & 0xFFFF);
    acc += @as(u32, ~old_value & 0xFFFF);
    acc += @as(u32, new_value);
    // Fold
    while (acc > 0xFFFF) {
        acc = (acc & 0xFFFF) + (acc >> 16);
    }
    return @intCast(~acc & 0xFFFF);
}

/// Incrementally update a checksum when a 32-bit field changes (e.g., IP address).
/// Treats the 32-bit field as two consecutive 16-bit words.
pub fn incrementalUpdate32(old_checksum: u16, old_value: u32, new_value: u32) u16 {
    const old_hi: u16 = @intCast(old_value >> 16);
    const old_lo: u16 = @intCast(old_value & 0xFFFF);
    const new_hi: u16 = @intCast(new_value >> 16);
    const new_lo: u16 = @intCast(new_value & 0xFFFF);
    const intermediate = incrementalUpdate(old_checksum, old_hi, new_hi);
    return incrementalUpdate(intermediate, old_lo, new_lo);
}

// ══════════════════════════════════════════════════════════════════════════════
// Verification
// ══════════════════════════════════════════════════════════════════════════════

/// Verify a checksum over a region that includes the checksum field.
/// If valid, computing the checksum over the entire region yields 0.
pub fn verify(data: []const u8) bool {
    return fold(sum(data)) == 0;
}


// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "RFC 1071 example" {
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    const result = compute(&data);
    if (result != 0x220d) return error.TestUnexpectedResult;
}

test "zero data produces 0xFFFF" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    if (compute(&data) != 0xFFFF) return error.TestUnexpectedResult;
}

test "all ones produces 0x0000" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    if (compute(&data) != 0x0000) return error.TestUnexpectedResult;
}

test "odd length byte" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    if (compute(&data) != 0xFBFD) return error.TestUnexpectedResult;
}

test "verify valid header" {
    var hdr = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xAC, 0x10, 0x0A, 0x63, 0xAC, 0x10, 0x0A, 0x0C };
    const cksum = compute(&hdr);
    hdr[10] = @intCast(cksum >> 8);
    hdr[11] = @intCast(cksum & 0xFF);
    if (!verify(&hdr)) return error.TestUnexpectedResult;
}

test "pseudo-header sum" {
    const src = [4]u8{ 192, 168, 1, 1 };
    const dst = [4]u8{ 192, 168, 1, 2 };
    const acc = pseudoHeaderSum(src, dst, 17, 20);
    const expected: u32 = 0xC0A8 + 0x0101 + 0xC0A8 + 0x0102 + 0x0011 + 0x0014;
    if (acc != expected) return error.TestUnexpectedResult;
}

test "incremental update correctness" {
    const data = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x00, 0x00 };
    const original = compute(&data);
    const updated = incrementalUpdate(original, 0x4500, 0x4400);
    var modified = data;
    modified[0] = 0x44;
    if (updated != compute(&modified)) return error.TestUnexpectedResult;
}
