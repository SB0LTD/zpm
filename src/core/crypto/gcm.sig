// @zpm/crypto/gcm — Freestanding AES-128-GCM AEAD (NIST SP 800-38D).
// Zero allocator. Pure computation. No std dependency.

const aes = @import("aes.sig");

/// AEAD seal: encrypts plaintext and appends 16-byte authentication tag.
/// `out` must have capacity for `pt.len + 16` bytes.
/// Returns total bytes written (plaintext_len + 16).
pub fn seal(
    key: *const [16]u8,
    nonce: *const [12]u8,
    aad: []const u8,
    pt: []const u8,
    out: []u8,
) usize {
    var rk: [176]u8 = undefined;
    aes.keyExpand(key, &rk);

    // H = AES(K, 0^128)
    var h: [16]u8 = undefined;
    const zeros: [16]u8 = @splat(0);
    aes.encryptBlock(&zeros, &rk, &h);

    // J0 = nonce || 0x00000001
    var j0: [16]u8 = @splat(0);
    @memcpy(j0[0..12], nonce);
    j0[15] = 1;

    // CTR encrypt (counter starts at J0 + 1)
    var ctr = j0;
    var off: usize = 0;
    while (off < pt.len) : (off += 16) {
        incrementCounter(&ctr);
        var ks: [16]u8 = undefined;
        aes.encryptBlock(&ctr, &rk, &ks);
        const m = @min(16, pt.len - off);
        for (0..m) |k| out[off + k] = pt[off + k] ^ ks[k];
    }

    // GHASH(H, AAD, ciphertext) → S
    var s: [16]u8 = undefined;
    ghash(&h, aad, out[0..pt.len], &s);

    // Tag = S XOR AES(K, J0)
    var ej: [16]u8 = undefined;
    aes.encryptBlock(&j0, &rk, &ej);
    for (0..16) |k| out[pt.len + k] = s[k] ^ ej[k];

    return pt.len + 16;
}

/// AEAD open: verifies tag and decrypts ciphertext.
/// `ct` must include the trailing 16-byte tag (total = plaintext_len + 16).
/// Returns plaintext length on success, 0 on tag mismatch.
pub fn open(
    key: *const [16]u8,
    nonce: *const [12]u8,
    aad: []const u8,
    ct: []const u8,
    out: []u8,
) usize {
    if (ct.len < 16) return 0;
    const clen = ct.len - 16;

    var rk: [176]u8 = undefined;
    aes.keyExpand(key, &rk);

    var h: [16]u8 = undefined;
    const zeros: [16]u8 = @splat(0);
    aes.encryptBlock(&zeros, &rk, &h);

    var j0: [16]u8 = @splat(0);
    @memcpy(j0[0..12], nonce);
    j0[15] = 1;

    // Verify tag BEFORE decrypting (constant-time comparison)
    var s: [16]u8 = undefined;
    ghash(&h, aad, ct[0..clen], &s);
    var ej: [16]u8 = undefined;
    aes.encryptBlock(&j0, &rk, &ej);

    var tag_diff: u8 = 0;
    for (0..16) |k| {
        tag_diff |= (s[k] ^ ej[k]) ^ ct[clen + k];
    }
    if (tag_diff != 0) return 0;

    // CTR decrypt
    var ctr = j0;
    var off: usize = 0;
    while (off < clen) : (off += 16) {
        incrementCounter(&ctr);
        var ks: [16]u8 = undefined;
        aes.encryptBlock(&ctr, &rk, &ks);
        const m = @min(16, clen - off);
        for (0..m) |k| out[off + k] = ct[off + k] ^ ks[k];
    }

    return clen;
}

// ── GHASH ────────────────────────────────────────────────────────

fn ghash(h: *const [16]u8, aad: []const u8, ct: []const u8, out: *[16]u8) void {
    var y: [16]u8 = @splat(0);
    // Process AAD blocks
    ghashBlocks(&y, h, aad);
    // Process ciphertext blocks
    ghashBlocks(&y, h, ct);
    // Length block: [AAD_bits_64BE || CT_bits_64BE]
    var len_blk: [16]u8 = @splat(0);
    const ab = @as(u64, aad.len) * 8;
    const cb = @as(u64, ct.len) * 8;
    for (0..8) |k| len_blk[k] = @intCast((ab >> @intCast((7 - k) * 8)) & 0xFF);
    for (0..8) |k| len_blk[8 + k] = @intCast((cb >> @intCast((7 - k) * 8)) & 0xFF);
    for (0..16) |k| {
        y[k] ^= len_blk[k];
    }
    ghashMul(&y, h);
    out.* = y;
}

fn ghashBlocks(y: *[16]u8, h: *const [16]u8, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        const n = @min(16, data.len - off);
        for (0..n) |k| y[k] ^= data[off + k];
        ghashMul(y, h);
    }
}

fn ghashMul(x: *[16]u8, h: *const [16]u8) void {
    var z: [16]u8 = @splat(0);
    var v: [16]u8 = h.*;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const bit = (x[i / 8] >> @intCast(7 - i % 8)) & 1;
        if (bit == 1) {
            for (0..16) |j| {
                z[j] ^= v[j];
            }
        }
        const lsb = v[15] & 1;
        var j: usize = 15;
        while (j > 0) : (j -= 1) v[j] = (v[j] >> 1) | (v[j - 1] << 7);
        v[0] >>= 1;
        if (lsb == 1) v[0] ^= 0xe1;
    }
    x.* = z;
}

fn incrementCounter(ctr: *[16]u8) void {
    var i: usize = 15;
    while (i >= 12) : (i -= 1) {
        ctr[i] +%= 1;
        if (ctr[i] != 0) break;
    }
}
