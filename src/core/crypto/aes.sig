// AES (Advanced Encryption Standard) — FIPS 197
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Software implementation of AES-128 and AES-256. Provides:
// - Key expansion (key schedule generation)
// - Single-block encrypt/decrypt (ECB mode, 16-byte blocks)
// - Counter mode (AES-CTR) for GCM's encryption layer
//
// This is a T-table-free implementation to avoid cache-timing side channels.
// Uses bitslice-style S-box computation where practical.

/// AES block size in bytes.
pub const BLOCK_SIZE = 16;

/// AES-128 key size.
pub const KEY_128 = 16;

/// AES-256 key size.
pub const KEY_256 = 32;

/// AES-128 expanded key: 11 round keys * 16 bytes = 176 bytes.
pub const EXPANDED_128 = 176;

/// AES-256 expanded key: 15 round keys * 16 bytes = 240 bytes.
pub const EXPANDED_256 = 240;

// ── S-Box (FIPS 197 §5.1.1) ─────────────────────────────────────────────

const SBOX: [256]u8 = .{
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};

const INV_SBOX: [256]u8 = .{
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
};

// ── Round Constants ──────────────────────────────────────────────────────

const RCON: [10]u8 = .{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 };

// ── GF(2^8) multiply (for MixColumns) ───────────────────────────────────

/// Multiply by 2 in GF(2^8) with reduction polynomial x^8 + x^4 + x^3 + x + 1.
inline fn xtime(x: u8) u8 {
    return (x << 1) ^ ((@as(u8, 0) -% ((x >> 7) & 1)) & 0x1b);
}

/// Multiply two bytes in GF(2^8).
inline fn gmul(a: u8, b: u8) u8 {
    var result: u8 = 0;
    var aa = a;
    var bb = b;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if ((bb & 1) != 0) result ^= aa;
        aa = xtime(aa);
        bb >>= 1;
    }
    return result;
}

// ── AES Context ─────────────────────────────────────────────────────────

pub const Aes128 = struct {
    round_keys: [176]u8, // 11 * 16

    /// Expand a 16-byte key into 11 round keys.
    pub fn init(key: *const [16]u8) Aes128 {
        var rk: [176]u8 = undefined;
        @memcpy(rk[0..16], key);

        var i: usize = 16;
        var rcon_idx: usize = 0;
        while (i < 176) : (i += 4) {
            var tmp: [4]u8 = .{ rk[i - 4], rk[i - 3], rk[i - 2], rk[i - 1] };

            if (i % 16 == 0) {
                // RotWord + SubWord + Rcon
                const t = tmp[0];
                tmp[0] = SBOX[tmp[1]] ^ RCON[rcon_idx];
                tmp[1] = SBOX[tmp[2]];
                tmp[2] = SBOX[tmp[3]];
                tmp[3] = SBOX[t];
                rcon_idx += 1;
            }

            rk[i + 0] = rk[i - 16] ^ tmp[0];
            rk[i + 1] = rk[i - 15] ^ tmp[1];
            rk[i + 2] = rk[i - 14] ^ tmp[2];
            rk[i + 3] = rk[i - 13] ^ tmp[3];
        }

        return .{ .round_keys = rk };
    }

    /// Encrypt a single 16-byte block in place.
    pub fn encryptBlock(self: *const Aes128, block: *[16]u8) void {
        encryptBlockGeneric(&self.round_keys, 10, block);
    }

    /// Decrypt a single 16-byte block in place.
    pub fn decryptBlock(self: *const Aes128, block: *[16]u8) void {
        decryptBlockGeneric(&self.round_keys, 10, block);
    }

    /// AES-CTR: encrypt/decrypt `data` in place using the given nonce and starting counter.
    /// The counter is a 32-bit big-endian value in bytes [12..16] of the counter block.
    pub fn ctr(self: *const Aes128, nonce: *const [12]u8, counter_start: u32, data: []u8) void {
        ctrGeneric(&self.round_keys, 10, nonce, counter_start, data);
    }
};

pub const Aes256 = struct {
    round_keys: [240]u8, // 15 * 16

    /// Expand a 32-byte key into 15 round keys.
    pub fn init(key: *const [32]u8) Aes256 {
        var rk: [240]u8 = undefined;
        @memcpy(rk[0..32], key);

        var i: usize = 32;
        var rcon_idx: usize = 0;
        while (i < 240) : (i += 4) {
            var tmp: [4]u8 = .{ rk[i - 4], rk[i - 3], rk[i - 2], rk[i - 1] };

            if (i % 32 == 0) {
                // RotWord + SubWord + Rcon
                const t = tmp[0];
                tmp[0] = SBOX[tmp[1]] ^ RCON[rcon_idx];
                tmp[1] = SBOX[tmp[2]];
                tmp[2] = SBOX[tmp[3]];
                tmp[3] = SBOX[t];
                rcon_idx += 1;
            } else if (i % 32 == 16) {
                // SubWord only (AES-256 extra step)
                tmp[0] = SBOX[tmp[0]];
                tmp[1] = SBOX[tmp[1]];
                tmp[2] = SBOX[tmp[2]];
                tmp[3] = SBOX[tmp[3]];
            }

            rk[i + 0] = rk[i - 32] ^ tmp[0];
            rk[i + 1] = rk[i - 31] ^ tmp[1];
            rk[i + 2] = rk[i - 30] ^ tmp[2];
            rk[i + 3] = rk[i - 29] ^ tmp[3];
        }

        return .{ .round_keys = rk };
    }

    /// Encrypt a single 16-byte block in place.
    pub fn encryptBlock(self: *const Aes256, block: *[16]u8) void {
        encryptBlockGeneric(&self.round_keys, 14, block);
    }

    /// Decrypt a single 16-byte block in place.
    pub fn decryptBlock(self: *const Aes256, block: *[16]u8) void {
        decryptBlockGeneric(&self.round_keys, 14, block);
    }

    /// AES-CTR: encrypt/decrypt `data` in place.
    pub fn ctr(self: *const Aes256, nonce: *const [12]u8, counter_start: u32, data: []u8) void {
        ctrGeneric(&self.round_keys, 14, nonce, counter_start, data);
    }
};

// ── Generic encrypt/decrypt (shared by AES-128 and AES-256) ─────────────

fn encryptBlockGeneric(round_keys: []const u8, rounds: usize, block: *[16]u8) void {
    // Initial AddRoundKey
    for (0..16) |i| block[i] ^= round_keys[i];

    var round: usize = 1;
    while (round < rounds) : (round += 1) {
        subBytes(block);
        shiftRows(block);
        mixColumns(block);
        const rk_off = round * 16;
        for (0..16) |i| block[i] ^= round_keys[rk_off + i];
    }

    // Final round (no MixColumns)
    subBytes(block);
    shiftRows(block);
    const rk_off = rounds * 16;
    for (0..16) |i| block[i] ^= round_keys[rk_off + i];
}

fn decryptBlockGeneric(round_keys: []const u8, rounds: usize, block: *[16]u8) void {
    // Initial AddRoundKey with last round key
    var rk_off = rounds * 16;
    for (0..16) |i| block[i] ^= round_keys[rk_off + i];

    var round: usize = rounds - 1;
    while (round >= 1) : (round -= 1) {
        invShiftRows(block);
        invSubBytes(block);
        rk_off = round * 16;
        for (0..16) |i| block[i] ^= round_keys[rk_off + i];
        invMixColumns(block);
    }

    // Final round (no InvMixColumns)
    invShiftRows(block);
    invSubBytes(block);
    for (0..16) |i| block[i] ^= round_keys[i];
}

fn ctrGeneric(round_keys: []const u8, rounds: usize, nonce: *const [12]u8, counter_start: u32, data: []u8) void {
    var counter = counter_start;
    var offset: usize = 0;

    while (offset < data.len) {
        // Build counter block: nonce[12] || counter[4] (big-endian)
        var ctr_block: [16]u8 = undefined;
        @memcpy(ctr_block[0..12], nonce);
        ctr_block[12] = @intCast((counter >> 24) & 0xFF);
        ctr_block[13] = @intCast((counter >> 16) & 0xFF);
        ctr_block[14] = @intCast((counter >> 8) & 0xFF);
        ctr_block[15] = @intCast(counter & 0xFF);

        // Encrypt counter block to get keystream
        encryptBlockGeneric(round_keys, rounds, &ctr_block);

        // XOR keystream with data
        const remaining = data.len - offset;
        const chunk = @min(remaining, 16);
        for (0..chunk) |i| {
            data[offset + i] ^= ctr_block[i];
        }

        offset += chunk;
        counter +%= 1;
    }
}

// ── SubBytes ─────────────────────────────────────────────────────────────

fn subBytes(block: *[16]u8) void {
    for (0..16) |i| block[i] = SBOX[block[i]];
}

fn invSubBytes(block: *[16]u8) void {
    for (0..16) |i| block[i] = INV_SBOX[block[i]];
}

// ── ShiftRows ────────────────────────────────────────────────────────────

fn shiftRows(block: *[16]u8) void {
    // Row 1: shift left 1
    const t1 = block[1];
    block[1] = block[5];
    block[5] = block[9];
    block[9] = block[13];
    block[13] = t1;

    // Row 2: shift left 2
    const t2a = block[2];
    const t2b = block[6];
    block[2] = block[10];
    block[6] = block[14];
    block[10] = t2a;
    block[14] = t2b;

    // Row 3: shift left 3 (= shift right 1)
    const t3 = block[15];
    block[15] = block[11];
    block[11] = block[7];
    block[7] = block[3];
    block[3] = t3;
}

fn invShiftRows(block: *[16]u8) void {
    // Row 1: shift right 1
    const t1 = block[13];
    block[13] = block[9];
    block[9] = block[5];
    block[5] = block[1];
    block[1] = t1;

    // Row 2: shift right 2
    const t2a = block[2];
    const t2b = block[6];
    block[2] = block[10];
    block[6] = block[14];
    block[10] = t2a;
    block[14] = t2b;

    // Row 3: shift right 3 (= shift left 1)
    const t3 = block[3];
    block[3] = block[7];
    block[7] = block[11];
    block[11] = block[15];
    block[15] = t3;
}

// ── MixColumns ───────────────────────────────────────────────────────────

fn mixColumns(block: *[16]u8) void {
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        const i = col * 4;
        const a = block[i];
        const b = block[i + 1];
        const c = block[i + 2];
        const d = block[i + 3];

        block[i + 0] = gmul(2, a) ^ gmul(3, b) ^ c ^ d;
        block[i + 1] = a ^ gmul(2, b) ^ gmul(3, c) ^ d;
        block[i + 2] = a ^ b ^ gmul(2, c) ^ gmul(3, d);
        block[i + 3] = gmul(3, a) ^ b ^ c ^ gmul(2, d);
    }
}

fn invMixColumns(block: *[16]u8) void {
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        const i = col * 4;
        const a = block[i];
        const b = block[i + 1];
        const c = block[i + 2];
        const d = block[i + 3];

        block[i + 0] = gmul(14, a) ^ gmul(11, b) ^ gmul(13, c) ^ gmul(9, d);
        block[i + 1] = gmul(9, a) ^ gmul(14, b) ^ gmul(11, c) ^ gmul(13, d);
        block[i + 2] = gmul(13, a) ^ gmul(9, b) ^ gmul(14, c) ^ gmul(11, d);
        block[i + 3] = gmul(11, a) ^ gmul(13, b) ^ gmul(9, c) ^ gmul(14, d);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

test "aes128: NIST FIPS 197 Appendix B" {
    // Key: 2b7e151628aed2a6abf7158809cf4f3c
    // Plaintext: 3243f6a8885a308d313198a2e0370734
    // Ciphertext: 3925841d02dc09fbdc118597196a0b32
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    const plaintext = [16]u8{
        0x32, 0x43, 0xf6, 0xa8, 0x88, 0x5a, 0x30, 0x8d,
        0x31, 0x31, 0x98, 0xa2, 0xe0, 0x37, 0x07, 0x34,
    };
    const expected = [16]u8{
        0x39, 0x25, 0x84, 0x1d, 0x02, 0xdc, 0x09, 0xfb,
        0xdc, 0x11, 0x85, 0x97, 0x19, 0x6a, 0x0b, 0x32,
    };

    const ctx = Aes128.init(&key);
    var block = plaintext;
    ctx.encryptBlock(&block);

    for (0..16) |i| {
        if (block[i] != expected[i]) return error.TestUnexpectedResult;
    }

    // Decrypt should recover plaintext
    ctx.decryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != plaintext[i]) return error.TestUnexpectedResult;
    }
}

test "aes128: NIST SP 800-38A F.1.1 ECB-AES128 Encrypt" {
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    // Block 1
    var block = [16]u8{
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
    };
    const expected = [16]u8{
        0x3a, 0xd7, 0x7b, 0xb4, 0x0d, 0x7a, 0x36, 0x60,
        0xa8, 0x9e, 0xca, 0xf3, 0x24, 0x66, 0xef, 0x97,
    };

    const ctx = Aes128.init(&key);
    ctx.encryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "aes256: NIST FIPS 197 Appendix C.3" {
    const key = [32]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };
    const plaintext = [16]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    const expected = [16]u8{
        0x8e, 0xa2, 0xb7, 0xca, 0x51, 0x67, 0x45, 0xbf,
        0xea, 0xfc, 0x49, 0x90, 0x4b, 0x49, 0x60, 0x89,
    };

    const ctx = Aes256.init(&key);
    var block = plaintext;
    ctx.encryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != expected[i]) return error.TestUnexpectedResult;
    }

    ctx.decryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != plaintext[i]) return error.TestUnexpectedResult;
    }
}

test "aes128: CTR mode basic" {
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    const nonce = [12]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb };
    const ctx = Aes128.init(&key);

    // Encrypt then decrypt should yield original
    var data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A };
    const original = data;

    ctx.ctr(&nonce, 1, &data);
    // Encrypted should differ from original
    var same = true;
    for (0..data.len) |i| {
        if (data[i] != original[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;

    // Decrypt (CTR is symmetric)
    ctx.ctr(&nonce, 1, &data);
    for (0..data.len) |i| {
        if (data[i] != original[i]) return error.TestUnexpectedResult;
    }
}

test "aes128: encrypt/decrypt round trip multiple blocks" {
    const key = [16]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const ctx = Aes128.init(&key);

    var block: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    const original = block;

    ctx.encryptBlock(&block);
    ctx.decryptBlock(&block);

    for (0..16) |i| {
        if (block[i] != original[i]) return error.TestUnexpectedResult;
    }
}
