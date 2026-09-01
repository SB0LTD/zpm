// HMAC-SHA-256 — RFC 2104 / FIPS 198-1
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Provides keyed-hash message authentication using SHA-256 as the
// underlying hash function. Used by HKDF (RFC 5869) and TLS 1.3 Finished.

const sha256 = @import("sha256");

/// HMAC-SHA-256 output length in bytes (same as SHA-256 digest).
pub const MAC_LEN = 32;

/// Block size of SHA-256 (the underlying hash).
const BLOCK_SIZE = 64;

/// Streaming HMAC-SHA-256. All state in struct fields — zero allocation.
pub const Hmac = struct {
    inner: sha256.Sha256,
    outer_key_pad: [BLOCK_SIZE]u8,

    /// Initialize HMAC with the given key.
    /// Keys longer than 64 bytes are hashed first (RFC 2104 §2).
    pub fn init(key: []const u8) Hmac {
        var key_block: [BLOCK_SIZE]u8 = @splat(0);

        if (key.len > BLOCK_SIZE) {
            // Hash the key if it's longer than the block size
            const hashed = sha256.hash(key);
            @memcpy(key_block[0..32], &hashed);
        } else {
            @memcpy(key_block[0..key.len], key);
        }

        // Compute inner and outer padded keys
        var ipad: [BLOCK_SIZE]u8 = undefined;
        var opad: [BLOCK_SIZE]u8 = undefined;
        for (0..BLOCK_SIZE) |i| {
            ipad[i] = key_block[i] ^ 0x36;
            opad[i] = key_block[i] ^ 0x5c;
        }

        // Start inner hash with ipad
        var inner = sha256.Sha256.init();
        inner.update(&ipad);

        return .{
            .inner = inner,
            .outer_key_pad = opad,
        };
    }

    /// Feed data into the HMAC computation.
    pub fn update(self: *Hmac, data: []const u8) void {
        self.inner.update(data);
    }

    /// Finalize and return the 32-byte MAC.
    /// HMAC(K, m) = H((K ^ opad) || H((K ^ ipad) || m))
    pub fn final(self: *Hmac) [MAC_LEN]u8 {
        // Finalize inner hash
        const inner_digest = self.inner.final();

        // Compute outer hash: H(opad || inner_digest)
        var outer = sha256.Sha256.init();
        outer.update(&self.outer_key_pad);
        outer.update(&inner_digest);
        return outer.final();
    }
};

/// One-shot HMAC-SHA-256.
pub fn mac(key: []const u8, data: []const u8) [MAC_LEN]u8 {
    var h = Hmac.init(key);
    h.update(data);
    return h.final();
}

/// One-shot HMAC-SHA-256 with two data segments (avoids concatenation).
pub fn mac2(key: []const u8, data1: []const u8, data2: []const u8) [MAC_LEN]u8 {
    var h = Hmac.init(key);
    h.update(data1);
    h.update(data2);
    return h.final();
}

// ── Tests ──

test "hmac-sha256: RFC 4231 Test Case 1" {
    // Key = 0x0b repeated 20 times
    // Data = "Hi There"
    const key: [20]u8 = @splat(0x0b);
    const data = "Hi There";
    const expected = [_]u8{
        0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53,
        0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b, 0xf1, 0x2b,
        0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7,
        0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7,
    };
    const result = mac(&key, data);
    for (0..32) |i| {
        if (result[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "hmac-sha256: RFC 4231 Test Case 2" {
    // Key = "Jefe"
    // Data = "what do ya want for nothing?"
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected = [_]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
        0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    };
    const result = mac(key, data);
    for (0..32) |i| {
        if (result[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "hmac-sha256: RFC 4231 Test Case 3" {
    // Key = 0xaa repeated 20 times
    // Data = 0xdd repeated 50 times
    const key: [20]u8 = @splat(0xaa);
    const data: [50]u8 = @splat(0xdd);
    const expected = [_]u8{
        0x77, 0x3e, 0xa9, 0x1e, 0x36, 0x80, 0x0e, 0x46,
        0x85, 0x4d, 0xb8, 0xeb, 0xd0, 0x91, 0x81, 0xa7,
        0x29, 0x59, 0x09, 0x8b, 0x3e, 0xf8, 0xc1, 0x22,
        0xd9, 0x63, 0x55, 0x14, 0xce, 0xd5, 0x65, 0xfe,
    };
    const result = mac(&key, &data);
    for (0..32) |i| {
        if (result[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "hmac-sha256: long key (> 64 bytes) is hashed" {
    // Key = 0xaa repeated 131 bytes (RFC 4231 Test Case 6)
    // Data = "Test Using Larger Than Block-Size Key - Hash Key First"
    const key: [131]u8 = @splat(0xaa);
    const data = "Test Using Larger Than Block-Size Key - Hash Key First";
    const expected = [_]u8{
        0x60, 0xe4, 0x31, 0x59, 0x1e, 0xe0, 0xb6, 0x7f,
        0x0d, 0x8a, 0x26, 0xaa, 0xcb, 0xf5, 0xb7, 0x7f,
        0x8e, 0x0b, 0xc6, 0x21, 0x37, 0x28, 0xc5, 0x14,
        0x05, 0x46, 0x04, 0x0f, 0x0e, 0xe3, 0x7f, 0x54,
    };
    const result = mac(&key, data);
    for (0..32) |i| {
        if (result[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "hmac-sha256: streaming matches one-shot" {
    const key = "my secret key";
    const data = "Hello, World! This is a longer message for streaming test.";
    const one_shot = mac(key, data);

    var h = Hmac.init(key);
    h.update(data[0..13]);
    h.update(data[13..30]);
    h.update(data[30..]);
    const streamed = h.final();

    for (0..32) |i| {
        if (streamed[i] != one_shot[i]) return error.TestUnexpectedResult;
    }
}

test "hmac-sha256: mac2 matches concatenated" {
    const key = "test-key";
    const part1 = "first part ";
    const part2 = "second part";
    const combined = "first part second part";

    const result_combined = mac(key, combined);
    const result_split = mac2(key, part1, part2);

    for (0..32) |i| {
        if (result_combined[i] != result_split[i]) return error.TestUnexpectedResult;
    }
}
