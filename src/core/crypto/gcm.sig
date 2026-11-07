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

// Constant-time: AES is the bitsliced aes.sig core, and GHASH is
// std.crypto.onetimeauth.Ghash, which uses PMULL/PCLMUL when the target has
// them and otherwise a branch-free, table-free carry-less multiply (integer
// multiplies with masked "holes"). Neither indexes memory by H or the data.

const std = @import("std");
const aes = @import("aes");
const Ghash = std.crypto.onetimeauth.Ghash;

/// Authentication tag length in bytes.
pub const TAG_LEN = 16;

/// Nonce length in bytes (96-bit IV per NIST recommendation).
pub const NONCE_LEN = 12;

/// Key length in bytes.
pub const KEY_LEN = 16;

/// GCM over AES-128 (TLS_AES_128_GCM_SHA256, QUIC).
pub const Gcm = GcmWith(aes.Aes128, KEY_LEN);

/// AES-256-GCM key length in bytes.
pub const KEY_LEN_256 = 32;

/// GCM over AES-256 (TLS_AES_256_GCM_SHA384): the same GHASH, J0, CTR
/// offset (counter = 2) and tag construction with a 256-bit key.
pub const Gcm256 = GcmWith(aes.Aes256, KEY_LEN_256);

/// GCM context with pre-computed powers of H for GHASH.
fn GcmWith(comptime Cipher: type, comptime key_len: usize) type {
    return struct {
        const Self = @This();

        cipher: Cipher,
        ghash: Ghash, // keyed with H = AES_K(0^128); copied per message

        /// Initialize GCM with the cipher's key.
        pub fn init(key: *const [key_len]u8) Self {
            const cipher = Cipher.init(key);

            // Compute H = E(K, 0^128)
            var h: [16]u8 = @splat(0);
            cipher.encryptBlock(&h);
            const ghash = Ghash.init(&h);
            std.crypto.secureZero(u8, &h);

            return .{
                .cipher = cipher,
                .ghash = ghash,
            };
        }

        /// Authenticated encryption (seal).
        /// Encrypts `plaintext` in place, appends 16-byte tag to `tag_out`.
        /// nonce must be exactly 12 bytes.
        pub fn seal(
            self: *const Self,
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
            var ghash_state: [16]u8 = undefined;
            self.ghashAll(aad, plaintext, &ghash_state);

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
            self: *const Self,
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
            var ghash_state: [16]u8 = undefined;
            self.ghashAll(aad, ciphertext, &ghash_state);

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

        /// GHASH_H(A || pad || C || pad || len(A) || len(C)), lengths in bits as
        /// 64-bit big-endian.
        fn ghashAll(self: *const Self, aad: []const u8, ct: []const u8, out: *[16]u8) void {
            var st = self.ghash;
            st.update(aad);
            st.pad();
            st.update(ct);
            st.pad();

            var len_block: [16]u8 = undefined;
            putU64BE(len_block[0..8], @as(u64, @intCast(aad.len)) * 8);
            putU64BE(len_block[8..16], @as(u64, @intCast(ct.len)) * 8);
            st.update(&len_block);
            st.final(out); // also zeroes the copied state
        }
    };
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

test "gcm: NIST test case 4 - 60 byte plaintext with AAD" {
    // Key: feffe9928665731c6d6a8f9467308308, IV: cafebabefacedbaddecaf888
    const key = [16]u8{ 0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c, 0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08 };
    const nonce = [12]u8{ 0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce, 0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88 };
    const aad = [20]u8{
        0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef, 0xfe, 0xed,
        0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef, 0xab, 0xad, 0xda, 0xd2,
    };
    const pt = [60]u8{
        0xd9, 0x31, 0x32, 0x25, 0xf8, 0x84, 0x06, 0xe5, 0xa5, 0x59, 0x09, 0xc5, 0xaf, 0xf5, 0x26, 0x9a,
        0x86, 0xa7, 0xa9, 0x53, 0x15, 0x34, 0xf7, 0xda, 0x2e, 0x4c, 0x30, 0x3d, 0x8a, 0x31, 0x8a, 0x72,
        0x1c, 0x3c, 0x0c, 0x95, 0x95, 0x68, 0x09, 0x53, 0x2f, 0xcf, 0x0e, 0x24, 0x49, 0xa6, 0xb5, 0x25,
        0xb1, 0x6a, 0xed, 0xf5, 0xaa, 0x0d, 0xe6, 0x57, 0xba, 0x63, 0x7b, 0x39,
    };
    const expected_ct = [60]u8{
        0x42, 0x83, 0x1e, 0xc2, 0x21, 0x77, 0x74, 0x24, 0x4b, 0x72, 0x21, 0xb7, 0x84, 0xd0, 0xd4, 0x9c,
        0xe3, 0xaa, 0x21, 0x2f, 0x2c, 0x02, 0xa4, 0xe0, 0x35, 0xc1, 0x7e, 0x23, 0x29, 0xac, 0xa1, 0x2e,
        0x21, 0xd5, 0x14, 0xb2, 0x54, 0x66, 0x93, 0x1c, 0x7d, 0x8f, 0x6a, 0x5a, 0xac, 0x84, 0xaa, 0x05,
        0x1b, 0xa3, 0x0b, 0x39, 0x6a, 0x0a, 0xac, 0x97, 0x3d, 0x58, 0xe0, 0x91,
    };
    const expected_tag = [16]u8{
        0x5b, 0xc9, 0x4f, 0xbc, 0x32, 0x21, 0xa5, 0xdb, 0x94, 0xfa, 0xe9, 0x5a, 0xe7, 0x12, 0x1a, 0x47,
    };

    const gcm = Gcm.init(&key);
    var data = pt;
    var tag: [16]u8 = undefined;
    gcm.seal(&nonce, &data, &aad, &tag);
    try std.testing.expectEqualSlices(u8, &expected_ct, &data);
    try std.testing.expectEqualSlices(u8, &expected_tag, &tag);

    try std.testing.expect(gcm.open(&nonce, &data, &aad, &tag));
    try std.testing.expectEqualSlices(u8, &pt, &data);
}

test "gcm: cross-check seal/open against std.crypto.aead.aes_gcm on random inputs" {
    const StdGcm = std.crypto.aead.aes_gcm.Aes128Gcm;
    var prng = std.Random.DefaultPrng.init(0x67636d5f78636865);
    const rnd = prng.random();

    var pt_buf: [6000]u8 = undefined;
    var aad_buf: [300]u8 = undefined;
    var ours: [6000]u8 = undefined;
    var theirs: [6000]u8 = undefined;
    for (0..300) |iter| {
        var key: [16]u8 = undefined;
        var nonce: [12]u8 = undefined;
        rnd.bytes(&key);
        rnd.bytes(&nonce);
        // Cover empty, sub-block, exact-block and multi-block (incl. the
        // 4/8/16-block aggregated GHASH paths) lengths.
        const pt_len = if (iter < 40) iter else rnd.uintLessThan(usize, pt_buf.len + 1);
        const aad_len = if (iter % 7 == 0) 0 else rnd.uintLessThan(usize, aad_buf.len + 1);
        const pt = pt_buf[0..pt_len];
        const aad = aad_buf[0..aad_len];
        rnd.bytes(pt);
        rnd.bytes(aad);

        var want_tag: [16]u8 = undefined;
        StdGcm.encrypt(theirs[0..pt_len], &want_tag, pt, aad, nonce, key);

        const gcm = Gcm.init(&key);
        var tag: [16]u8 = undefined;
        @memcpy(ours[0..pt_len], pt);
        gcm.seal(&nonce, ours[0..pt_len], aad, &tag);
        try std.testing.expectEqualSlices(u8, theirs[0..pt_len], ours[0..pt_len]);
        try std.testing.expectEqualSlices(u8, &want_tag, &tag);

        try std.testing.expect(gcm.open(&nonce, ours[0..pt_len], aad, &tag));
        try std.testing.expectEqualSlices(u8, pt, ours[0..pt_len]);

        // A one-bit flip anywhere in ciphertext, AAD or tag must be rejected,
        // matching std.
        @memcpy(ours[0..pt_len], theirs[0..pt_len]);
        var bad_tag = tag;
        const where = rnd.uintLessThan(usize, 3);
        if (where == 0 and pt_len > 0) {
            ours[rnd.uintLessThan(usize, pt_len)] ^= @as(u8, 1) << rnd.int(u3);
        } else if (where == 1 and aad_len > 0) {
            aad[rnd.uintLessThan(usize, aad_len)] ^= @as(u8, 1) << rnd.int(u3);
        } else {
            bad_tag[rnd.uintLessThan(usize, 16)] ^= @as(u8, 1) << rnd.int(u3);
        }
        var std_out: [6000]u8 = undefined;
        const std_ok = if (StdGcm.decrypt(std_out[0..pt_len], ours[0..pt_len], bad_tag, aad, nonce, key)) |_| true else |_| false;
        try std.testing.expect(!std_ok);
        try std.testing.expect(!gcm.open(&nonce, ours[0..pt_len], aad, &bad_tag));
    }
}

test "gcm256: NIST round-trip AES-256-GCM" {
    // AES-256-GCM: encrypt then open recovers plaintext; tamper fails.
    const key: [32]u8 = .{
        0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c, 0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08,
        0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c, 0x6d, 0x6a, 0x8f, 0x94, 0x67, 0x30, 0x83, 0x08,
    };
    const nonce: [12]u8 = .{ 0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce, 0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88 };
    const aad = [_]u8{ 0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef };
    var pt = [_]u8{ 0xd9, 0x31, 0x32, 0x25, 0xf8, 0x84, 0x06, 0xe5, 0xa5, 0x59, 0x09, 0xc5, 0xaf, 0xf5, 0x26, 0x9a };
    const orig = pt;
    const g = Gcm256.init(&key);
    var tag: [16]u8 = undefined;
    g.seal(&nonce, &pt, &aad, &tag);
    // ciphertext differs from plaintext
    var changed = false;
    for (0..pt.len) |i| { if (pt[i] != orig[i]) { changed = true; break; } }
    if (!changed) return error.TestUnexpectedResult;
    // open recovers plaintext
    const ok = g.open(&nonce, &pt, &aad, &tag);
    if (!ok) return error.TestUnexpectedResult;
    for (0..pt.len) |i| { if (pt[i] != orig[i]) return error.TestUnexpectedResult; }
}

test "gcm256: tampered tag rejected" {
    const key: [32]u8 = @splat(0);
    const nonce: [12]u8 = @splat(0);
    const g = Gcm256.init(&key);
    var pt = [_]u8{ 1, 2, 3, 4, 5 };
    var tag: [16]u8 = undefined;
    g.seal(&nonce, &pt, "", &tag);
    tag[0] ^= 0xFF; // corrupt
    const ok = g.open(&nonce, &pt, "", &tag);
    if (ok) return error.TestUnexpectedResult;
}
