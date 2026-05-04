// Pure SHA-256 implementation — no platform deps, no allocator
// Layer 0: Core
//
// Implements NIST FIPS 180-4 SHA-256. All state lives in struct fields.
// Provides streaming (init/update/final) and one-shot (hash) interfaces.

const std = @import("std");

/// SHA-256 digest length in bytes.
pub const DIGEST_LEN = 32;

/// SHA-256 block size in bytes.
pub const BLOCK_SIZE = 64;

/// NIST FIPS 180-4 round constants (first 32 bits of the fractional parts
/// of the cube roots of the first 64 primes).
const K: [64]u32 = .{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

/// Initial hash values (first 32 bits of the fractional parts
/// of the square roots of the first 8 primes).
const H_INIT: [8]u32 = .{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

/// Right-rotate a 32-bit value.
inline fn rotr(x: u32, comptime n: u5) u32 {
    return (x >> n) | (x << @as(u5, 32 - @as(u6, n)));
}

/// SHA-256 Σ0 function.
inline fn sigma0(x: u32) u32 {
    return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
}

/// SHA-256 Σ1 function.
inline fn sigma1(x: u32) u32 {
    return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
}

/// SHA-256 σ0 (lowercase) for message schedule.
inline fn lsigma0(x: u32) u32 {
    return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
}

/// SHA-256 σ1 (lowercase) for message schedule.
inline fn lsigma1(x: u32) u32 {
    return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
}

/// SHA-256 Ch function.
inline fn ch(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (~x & z);
}

/// SHA-256 Maj function.
inline fn maj(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

/// Streaming SHA-256 hasher. All state in struct fields — zero allocation.
pub const Sha256 = struct {
    state: [8]u32,
    buf: [BLOCK_SIZE]u8,
    buf_len: usize,
    total_len: u64,

    /// Initialize a new SHA-256 hasher.
    pub fn init() Sha256 {
        return .{
            .state = H_INIT,
            .buf = std.mem.zeroes([BLOCK_SIZE]u8),
            .buf_len = 0,
            .total_len = 0,
        };
    }

    /// Feed data into the hasher.
    pub fn update(self: *Sha256, data: []const u8) void {
        var input = data;
        self.total_len += input.len;

        // If we have buffered data, try to fill the block first
        if (self.buf_len > 0) {
            const space = BLOCK_SIZE - self.buf_len;
            if (input.len >= space) {
                @memcpy(self.buf[self.buf_len..][0..space], input[0..space]);
                self.processBlock(&self.buf);
                input = input[space..];
                self.buf_len = 0;
            } else {
                @memcpy(self.buf[self.buf_len..][0..input.len], input);
                self.buf_len += input.len;
                return;
            }
        }

        // Process full blocks directly from input
        while (input.len >= BLOCK_SIZE) {
            self.processBlock(input[0..BLOCK_SIZE]);
            input = input[BLOCK_SIZE..];
        }

        // Buffer remaining bytes
        if (input.len > 0) {
            @memcpy(self.buf[0..input.len], input);
            self.buf_len = input.len;
        }
    }

    /// Finalize and return the 32-byte digest.
    pub fn final(self: *Sha256) [DIGEST_LEN]u8 {
        // Padding: append 1-bit, then zeros, then 64-bit big-endian length
        const total_bits: u64 = self.total_len * 8;

        // Append the 0x80 byte
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;

        // If not enough room for the 8-byte length, pad and process
        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..BLOCK_SIZE], 0);
            self.processBlock(&self.buf);
            self.buf_len = 0;
        }

        // Pad with zeros up to byte 56
        @memset(self.buf[self.buf_len..56], 0);

        // Append total length in bits as big-endian u64
        self.buf[56] = @intCast((total_bits >> 56) & 0xff);
        self.buf[57] = @intCast((total_bits >> 48) & 0xff);
        self.buf[58] = @intCast((total_bits >> 40) & 0xff);
        self.buf[59] = @intCast((total_bits >> 32) & 0xff);
        self.buf[60] = @intCast((total_bits >> 24) & 0xff);
        self.buf[61] = @intCast((total_bits >> 16) & 0xff);
        self.buf[62] = @intCast((total_bits >> 8) & 0xff);
        self.buf[63] = @intCast(total_bits & 0xff);

        self.processBlock(&self.buf);

        // Produce the digest as big-endian bytes
        var digest: [DIGEST_LEN]u8 = undefined;
        for (self.state, 0..) |word, i| {
            digest[i * 4 + 0] = @intCast((word >> 24) & 0xff);
            digest[i * 4 + 1] = @intCast((word >> 16) & 0xff);
            digest[i * 4 + 2] = @intCast((word >> 8) & 0xff);
            digest[i * 4 + 3] = @intCast(word & 0xff);
        }
        return digest;
    }

    /// Process a single 64-byte block.
    fn processBlock(self: *Sha256, block: *const [BLOCK_SIZE]u8) void {
        // Prepare message schedule
        var w: [64]u32 = undefined;
        for (0..16) |i| {
            w[i] = (@as(u32, block[i * 4]) << 24) |
                (@as(u32, block[i * 4 + 1]) << 16) |
                (@as(u32, block[i * 4 + 2]) << 8) |
                @as(u32, block[i * 4 + 3]);
        }
        for (16..64) |i| {
            w[i] = lsigma1(w[i - 2]) +% w[i - 7] +% lsigma0(w[i - 15]) +% w[i - 16];
        }

        // Working variables
        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        var d = self.state[3];
        var e = self.state[4];
        var f = self.state[5];
        var g = self.state[6];
        var h = self.state[7];

        // 64 rounds
        for (0..64) |i| {
            const t1 = h +% sigma1(e) +% ch(e, f, g) +% K[i] +% w[i];
            const t2 = sigma0(a) +% maj(a, b, c);
            h = g;
            g = f;
            f = e;
            e = d +% t1;
            d = c;
            c = b;
            b = a;
            a = t1 +% t2;
        }

        // Add compressed chunk to current hash value
        self.state[0] +%= a;
        self.state[1] +%= b;
        self.state[2] +%= c;
        self.state[3] +%= d;
        self.state[4] +%= e;
        self.state[5] +%= f;
        self.state[6] +%= g;
        self.state[7] +%= h;
    }
};

/// One-shot hash of a complete buffer.
pub fn hash(data: []const u8) [DIGEST_LEN]u8 {
    var h = Sha256.init();
    h.update(data);
    return h.final();
}

/// Format a 32-byte digest as a 64-char lowercase hex string.
pub fn hexDigest(digest: *const [DIGEST_LEN]u8, out: *[DIGEST_LEN * 2]u8) void {
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}

// ── Tests ──

const testing = std.testing;

test "sha256: empty string → NIST vector" {
    const digest = hash("");
    var hex: [64]u8 = undefined;
    hexDigest(&digest, &hex);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hex,
    );
}

test "sha256: 'abc' → NIST vector" {
    const digest = hash("abc");
    var hex: [64]u8 = undefined;
    hexDigest(&digest, &hex);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "sha256: 448-bit message → NIST vector" {
    // "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    const msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const digest = hash(msg);
    var hex: [64]u8 = undefined;
    hexDigest(&digest, &hex);
    try testing.expectEqualStrings(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        &hex,
    );
}

test "sha256: streaming matches one-shot" {
    const data = "The quick brown fox jumps over the lazy dog";
    const one_shot = hash(data);

    // Feed in chunks of varying sizes
    var streamed = Sha256.init();
    streamed.update(data[0..10]);
    streamed.update(data[10..20]);
    streamed.update(data[20..]);
    const streamed_digest = streamed.final();

    try testing.expectEqual(one_shot, streamed_digest);
}

test "sha256: single byte chunks" {
    const data = "hello";
    const one_shot = hash(data);

    var streamed = Sha256.init();
    for (data) |byte| {
        streamed.update(&[_]u8{byte});
    }
    const streamed_digest = streamed.final();

    try testing.expectEqual(one_shot, streamed_digest);
}

test "sha256: determinism — hashing twice yields same digest" {
    const data = "deterministic input";
    const d1 = hash(data);
    const d2 = hash(data);
    try testing.expectEqual(d1, d2);
}

test "sha256: hexDigest format" {
    const digest = hash("");
    var hex: [64]u8 = undefined;
    hexDigest(&digest, &hex);
    // Verify all chars are valid hex
    for (hex) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}
