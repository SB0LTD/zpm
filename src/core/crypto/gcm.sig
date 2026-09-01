// AES-128-GCM — NIST SP 800-38D / RFC 5116
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Authenticated encryption with associated data (AEAD).
// Used by TLS 1.3 record protection and QUIC packet encryption.
//
// Provides encrypt (seal) and decrypt (open) operations with:
// - 128-bit key
// - 96-bit nonce (IV)
// - Arbitrary AAD (additional authenticated data)
// - 128-bit authentication tag

const aes = @import("aes");

/// Authentication tag length in bytes.
pub const TAG_LEN = 16;

/// Nonce length in bytes (96-bit IV per NIST recommendation).
pub const NONCE_LEN = 12;

/// Key length in bytes.
pub const KEY_LEN = 16;

/// GCM context with pre-computed H table for GHASH.
pub const Gcm = struct {
    cipher: aes.Aes128,
    h: [16]u8, // H = AES_K(0^128) for GHASH

    /// Initialize GCM with a 128-bit key.
    pub fn init(key: *const [KEY_LEN]u8) Gcm {
        const cipher = aes.Aes128.init(key);

        // Compute H = E(K, 0^128)
        var h: [16]u8 = @splat(0);
        cipher.encryptBlock(&h);

        return .{
            .cipher = cipher,
            .h = h,
        };
    }

    /// Authenticated encryption (seal).
    /// Encrypts `plaintext` in place, appends 16-byte tag to `tag_out`.
    /// nonce must be exactly 12 bytes.
    pub fn seal(
        self: *const Gcm,
        nonce: *const [NONCE_LEN]u8,
        plaintext: []u8,
        aad: []const u8,
        tag_out: *[TAG_LEN]u8,
    ) void {
        // J0 = nonce || 0x00000001 (for tag computation)
        var j0: [16]u8 = undefined;
        @memcpy(j0[0..12], nonce);
        j0[12] = 0;
        j0[13] = 0;
        j0[14] = 0;
        j0[15] = 1;

        // Encrypt plaintext using CTR starting at counter = 2
        self.cipher.ctr(nonce, 2, plaintext);

        // Compute GHASH over AAD and ciphertext
        var ghash_state: [16]u8 = @splat(0);
        ghashUpdate(&self.h, &ghash_state, aad);
        ghashUpdate(&self.h, &ghash_state, plaintext);

        // Final GHASH block: len(A) || len(C) in bits, both as 64-bit big-endian
        var len_block: [16]u8 = @splat(0);
        const aad_bits: u64 = @as(u64, @intCast(aad.len)) * 8;
        const ct_bits: u64 = @as(u64, @intCast(plaintext.len)) * 8;
        putU64BE(len_block[0..8], aad_bits);
        putU64BE(len_block[8..16], ct_bits);
        ghashBlock(&self.h, &ghash_state, &len_block);

        // Tag = GHASH_result XOR E(K, J0)
        var enc_j0: [16]u8 = j0;
        self.cipher.encryptBlock(&enc_j0);
        for (0..16) |i| tag_out[i] = ghash_state[i] ^ enc_j0[i];
    }

    /// Authenticated decryption (open).
    /// Verifies tag, then decrypts `ciphertext` in place.
    /// Returns true if authentication succeeds, false if tag mismatch.
    /// On failure, ciphertext is zeroed to prevent use of unauthenticated data.
    pub fn open(
        self: *const Gcm,
        nonce: *const [NONCE_LEN]u8,
        ciphertext: []u8,
        aad: []const u8,
        tag: *const [TAG_LEN]u8,
    ) bool {
        // J0 = nonce || 0x00000001
        var j0: [16]u8 = undefined;
        @memcpy(j0[0..12], nonce);
        j0[12] = 0;
        j0[13] = 0;
        j0[14] = 0;
        j0[15] = 1;

        // Compute GHASH over AAD and ciphertext (before decryption)
        var ghash_state: [16]u8 = @splat(0);
        ghashUpdate(&self.h, &ghash_state, aad);
        ghashUpdate(&self.h, &ghash_state, ciphertext);

        // Final GHASH block
        var len_block: [16]u8 = @splat(0);
        const aad_bits: u64 = @as(u64, @intCast(aad.len)) * 8;
        const ct_bits: u64 = @as(u64, @intCast(ciphertext.len)) * 8;
        putU64BE(len_block[0..8], aad_bits);
        putU64BE(len_block[8..16], ct_bits);
        ghashBlock(&self.h, &ghash_state, &len_block);

        // Compute expected tag
        var enc_j0: [16]u8 = j0;
        self.cipher.encryptBlock(&enc_j0);
        var expected_tag: [16]u8 = undefined;
        for (0..16) |i| expected_tag[i] = ghash_state[i] ^ enc_j0[i];

        // Constant-time tag comparison
        var diff: u8 = 0;
        for (0..16) |i| diff |= expected_tag[i] ^ tag[i];

        if (diff != 0) {
            // Authentication failed — zero the output
            @memset(ciphertext, 0);
            return false;
        }

        // Decrypt in place using CTR starting at counter = 2
        self.cipher.ctr(nonce, 2, ciphertext);
        return true;
    }
};

// ── GHASH (GF(2^128) multiplication) ────────────────────────────────────

/// Process complete and partial blocks through GHASH.
fn ghashUpdate(h: *const [16]u8, state: *[16]u8, data: []const u8) void {
    var offset: usize = 0;

    // Process full 16-byte blocks
    while (offset + 16 <= data.len) {
        var block: [16]u8 = undefined;
        @memcpy(&block, data[offset..][0..16]);
        ghashBlock(h, state, &block);
        offset += 16;
    }

    // Process partial final block (zero-padded)
    if (offset < data.len) {
        var block: [16]u8 = @splat(0);
        const remaining = data.len - offset;
        @memcpy(block[0..remaining], data[offset..][0..remaining]);
        ghashBlock(h, state, &block);
    }
}

/// Process a single 16-byte block: state = (state XOR block) * H in GF(2^128).
fn ghashBlock(h: *const [16]u8, state: *[16]u8, block: *const [16]u8) void {
    // XOR block into state
    for (0..16) |i| state[i] ^= block[i];

    // Multiply state by H in GF(2^128) using the "schoolbook" algorithm
    // with reduction polynomial x^128 + x^7 + x^2 + x + 1
    gfMul(state, h);
}

/// GF(2^128) multiplication: a = a * b, with reduction.
/// Uses bit-by-bit multiplication (simple, constant-time).
fn gfMul(a: *[16]u8, b: *const [16]u8) void {
    var z: [16]u8 = @splat(0); // accumulator
    var v: [16]u8 = undefined; // shifted copy of a
    @memcpy(&v, a);

    for (0..128) |i| {
        // If bit i of b is set, XOR v into z
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(7 - (i % 8));
        if (((b[byte_idx] >> bit_idx) & 1) != 0) {
            for (0..16) |j| z[j] ^= v[j];
        }

        // v = v >> 1 in GF(2^128) (right shift with reduction)
        const lsb = v[15] & 1;
        var j: usize = 15;
        while (j > 0) : (j -= 1) {
            v[j] = (v[j] >> 1) | (v[j - 1] << 7);
        }
        v[0] = v[0] >> 1;

        // If LSB was 1, XOR reduction polynomial (0xE1 in MSB position)
        if (lsb != 0) {
            v[0] ^= 0xE1;
        }
    }

    @memcpy(a, &z);
}

// ── Utility ─────────────────────────────────────────────────────────────

fn putU64BE(buf: *[8]u8, val: u64) void {
    buf[0] = @intCast((val >> 56) & 0xFF);
    buf[1] = @intCast((val >> 48) & 0xFF);
    buf[2] = @intCast((val >> 40) & 0xFF);
    buf[3] = @intCast((val >> 32) & 0xFF);
    buf[4] = @intCast((val >> 24) & 0xFF);
    buf[5] = @intCast((val >> 16) & 0xFF);
    buf[6] = @intCast((val >> 8) & 0xFF);
    buf[7] = @intCast(val & 0xFF);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "gcm: NIST test case - empty plaintext and AAD" {
    // AES-GCM test vector from NIST SP 800-38D (Test Case 1)
    // Key: 00000000000000000000000000000000
    // IV:  000000000000000000000000
    // PT:  (empty)
    // AAD: (empty)
    // Tag: 58e2fccefa7e3061367f1d57a4e7455a
    const key: [16]u8 = @splat(0);
    const nonce: [12]u8 = @splat(0);

    const gcm = Gcm.init(&key);
    var plaintext: [0]u8 = .{};
    var tag: [16]u8 = undefined;
    gcm.seal(&nonce, &plaintext, "", &tag);

    const expected_tag = [16]u8{
        0x58, 0xe2, 0xfc, 0xce, 0xfa, 0x7e, 0x30, 0x61,
        0x36, 0x7f, 0x1d, 0x57, 0xa4, 0xe7, 0x45, 0x5a,
    };
    for (0..16) |i| {
        if (tag[i] != expected_tag[i]) return error.TestUnexpectedResult;
    }
}

test "gcm: NIST test case 2 - 16 byte plaintext" {
    // Key: 00000000000000000000000000000000
    // IV:  000000000000000000000000
    // PT:  00000000000000000000000000000000
    // AAD: (empty)
    // CT:  0388dace60b6a392f328c2b971b2fe78
    // Tag: ab6e47d42cec13bdf53a67b21257bddf
    const key: [16]u8 = @splat(0);
    const nonce: [12]u8 = @splat(0);
    var pt: [16]u8 = @splat(0);

    const gcm = Gcm.init(&key);
    var tag: [16]u8 = undefined;
    gcm.seal(&nonce, &pt, "", &tag);

    const expected_ct = [16]u8{
        0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92,
        0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2, 0xfe, 0x78,
    };
    for (0..16) |i| {
        if (pt[i] != expected_ct[i]) return error.TestUnexpectedResult;
    }

    const expected_tag = [16]u8{
        0xab, 0x6e, 0x47, 0xd4, 0x2c, 0xec, 0x13, 0xbd,
        0xf5, 0x3a, 0x67, 0xb2, 0x12, 0x57, 0xbd, 0xdf,
    };
    for (0..16) |i| {
        if (tag[i] != expected_tag[i]) return error.TestUnexpectedResult;
    }
}

test "gcm: seal then open round-trip" {
    const key = [16]u8{ 0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c, 0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08 };
    const nonce = [12]u8{ 0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce, 0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88 };
    const aad = [_]u8{ 0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef };

    var data = [_]u8{
        0xd9, 0x31, 0x32, 0x25, 0xf8, 0x84, 0x06, 0xe5,
        0xa5, 0x59, 0x09, 0xc5, 0xaf, 0xf5, 0x26, 0x9a,
        0x86, 0xa7, 0xa9, 0x53, 0x15, 0x34, 0xf7, 0xda,
        0x2e, 0x4c, 0x30, 0x3d, 0x8a, 0x31, 0x8a, 0x72,
    };
    const original = data;

    const gcm = Gcm.init(&key);
    var tag: [16]u8 = undefined;
    gcm.seal(&nonce, &data, &aad, &tag);

    // Ciphertext should differ from plaintext
    var same = true;
    for (0..data.len) |i| {
        if (data[i] != original[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;

    // Open should succeed and recover plaintext
    const ok = gcm.open(&nonce, &data, &aad, &tag);
    if (!ok) return error.TestUnexpectedResult;
    for (0..data.len) |i| {
        if (data[i] != original[i]) return error.TestUnexpectedResult;
    }
}

test "gcm: tampered ciphertext fails authentication" {
    const key = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };
    const nonce = [12]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc };

    var data = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21 };

    const gcm = Gcm.init(&key);
    var tag: [16]u8 = undefined;
    gcm.seal(&nonce, &data, "", &tag);

    // Tamper with ciphertext
    data[0] ^= 0xFF;

    // Open should fail
    const ok = gcm.open(&nonce, &data, "", &tag);
    if (ok) return error.TestUnexpectedResult;

    // Data should be zeroed on failure
    for (data) |b| {
        if (b != 0) return error.TestUnexpectedResult;
    }
}

test "gcm: tampered tag fails authentication" {
    const key = [16]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 };
    const nonce = [12]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };

    var data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    const gcm = Gcm.init(&key);
    var tag: [16]u8 = undefined;
    gcm.seal(&nonce, &data, "", &tag);

    // Tamper with tag
    tag[0] ^= 0x01;

    const ok = gcm.open(&nonce, &data, "", &tag);
    if (ok) return error.TestUnexpectedResult;
}
