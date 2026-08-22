// @zpm/crypto/quic — QUIC-specific key derivation and packet protection (RFC 9001).
// Builds on aes, gcm, sha256, hkdf. Zero allocator. Freestanding.

const aes = @import("aes.sig");
const gcm = @import("gcm.sig");
const sha256 = @import("sha256.sig");
const hkdf = @import("hkdf.sig");

// ══════════════════════════════════════════════════════════════════════════════
// Key Material
// ══════════════════════════════════════════════════════════════════════════════

/// A complete set of keys for one QUIC encryption level.
pub const KeySet = struct {
    key: [16]u8 = @splat(0),
    iv: [12]u8 = @splat(0),
    hp_key: [16]u8 = @splat(0),
    valid: bool = false,
};

/// QUIC encryption levels.
pub const Level = enum(u2) {
    initial = 0,
    handshake = 1,
    zero_rtt = 2,
    one_rtt = 3,
};

// ══════════════════════════════════════════════════════════════════════════════
// Initial Key Derivation (RFC 9001 §5.2)
// ══════════════════════════════════════════════════════════════════════════════

/// RFC 9001 QUIC v1 Initial salt.
const INITIAL_SALT_V1 = [20]u8{
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
    0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
};

/// Derive Initial client and server keys from the client's DCID.
pub fn deriveInitialKeys(dcid: []const u8) struct { client: KeySet, server: KeySet } {
    var initial_secret: [32]u8 = undefined;
    hkdf.extract(&INITIAL_SALT_V1, dcid, &initial_secret);

    var client_secret: [32]u8 = undefined;
    hkdf.expandLabel(&initial_secret, "client in", &.{}, &client_secret);

    var server_secret: [32]u8 = undefined;
    hkdf.expandLabel(&initial_secret, "server in", &.{}, &server_secret);

    return .{
        .client = keySetFromSecret(&client_secret),
        .server = keySetFromSecret(&server_secret),
    };
}

/// Derive key/IV/HP from a traffic secret.
pub fn keySetFromSecret(secret: *const [32]u8) KeySet {
    var ks = KeySet{ .valid = true };
    hkdf.expandLabel(secret, "quic key", &.{}, &ks.key);
    hkdf.expandLabel(secret, "quic iv", &.{}, &ks.iv);
    hkdf.expandLabel(secret, "quic hp", &.{}, &ks.hp_key);
    return ks;
}

// ══════════════════════════════════════════════════════════════════════════════
// Packet Payload Encryption / Decryption
// ══════════════════════════════════════════════════════════════════════════════

/// Encrypt QUIC packet payload. Operates on the packet buffer in-place.
/// AAD = buf[0..payload_start] (packet header).
/// Encrypts buf[payload_start..+payload_len], appends 16-byte tag.
/// Returns encrypted length (payload_len + 16) or 0 on error.
pub fn encryptPayload(
    keys: *const KeySet,
    pkt_number: u64,
    buf: []u8,
    payload_start: usize,
    payload_len: usize,
) usize {
    if (!keys.valid or payload_start + payload_len + 16 > buf.len) return 0;

    const nonce = buildNonce(&keys.iv, pkt_number);
    const header = buf[0..payload_start];
    const plaintext = buf[payload_start..][0..payload_len];

    // Seal into a scratch buffer then copy back
    var ct: [1500]u8 = undefined;
    const total = gcm.seal(&keys.key, &nonce, header, plaintext, &ct);
    if (total == 0 or total > buf.len - payload_start) return 0;

    @memcpy(buf[payload_start..][0..total], ct[0..total]);
    return total;
}

/// Decrypt QUIC packet payload. Operates on the packet buffer in-place.
/// AAD = buf[0..payload_start]. payload_len INCLUDES the 16-byte tag.
/// Returns plaintext length or 0 on tag failure.
pub fn decryptPayload(
    keys: *const KeySet,
    pkt_number: u64,
    buf: []u8,
    payload_start: usize,
    payload_len: usize,
) usize {
    if (!keys.valid or payload_len < 16) return 0;

    const nonce = buildNonce(&keys.iv, pkt_number);
    const header = buf[0..payload_start];
    const ciphertext = buf[payload_start..][0..payload_len];

    var pt: [1500]u8 = undefined;
    const pt_len = gcm.open(&keys.key, &nonce, header, ciphertext, &pt);
    if (pt_len == 0) return 0;

    @memcpy(buf[payload_start..][0..pt_len], pt[0..pt_len]);
    return pt_len;
}

// ══════════════════════════════════════════════════════════════════════════════
// Header Protection (RFC 9001 §5.4)
// ══════════════════════════════════════════════════════════════════════════════

/// Apply or remove header protection (same operation — XOR is self-inverse).
/// `pn_offset` = byte offset of the packet number in the buffer.
/// Call AFTER encryption (to protect) or BEFORE decryption (to unprotect).
pub fn toggleHeaderProtection(keys: *const KeySet, buf: []u8, pn_offset: usize) void {
    if (!keys.valid) return;
    const sample_offset = pn_offset + 4;
    if (sample_offset + 16 > buf.len) return;

    // AES-ECB encrypt the 16-byte sample to produce the 5-byte mask
    var rk: [176]u8 = undefined;
    aes.keyExpand(&keys.hp_key, &rk);
    var mask: [16]u8 = undefined;
    aes.encryptBlock(buf[sample_offset..][0..16], &rk, &mask);

    // Mask the first byte (4 bits for long header, 5 for short)
    if (buf[0] & 0x80 != 0) {
        buf[0] ^= mask[0] & 0x0F;
    } else {
        buf[0] ^= mask[0] & 0x1F;
    }

    // Mask packet number bytes (1-4 bytes, determined from first byte after unmasking)
    const pn_len: usize = (buf[0] & 0x03) + 1;
    for (0..pn_len) |i| buf[pn_offset + i] ^= mask[1 + i];
}

// ══════════════════════════════════════════════════════════════════════════════
// Nonce (RFC 9001 §5.3)
// ══════════════════════════════════════════════════════════════════════════════

fn buildNonce(iv: *const [12]u8, pkt_number: u64) [12]u8 {
    var nonce: [12]u8 = iv.*;
    for (0..8) |i| {
        nonce[11 - i] ^= @intCast((pkt_number >> @intCast(8 * i)) & 0xFF);
    }
    return nonce;
}


// ══════════════════════════════════════════════════════════════════════════════
// RFC 9001 Appendix A Test Vector (compile-time verification)
// ══════════════════════════════════════════════════════════════════════════════

comptime {
    @setEvalBranchQuota(100000);
    // DCID from RFC 9001 Appendix A
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };

    const keys = deriveInitialKeys(&dcid);

    // Expected client key from RFC 9001 §A.1
    const expected_client_key = [_]u8{
        0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
        0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d,
    };
    const expected_client_iv = [_]u8{
        0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b,
        0x46, 0xfb, 0x25, 0x5c,
    };

    for (0..16) |i| {
        if (keys.client.key[i] != expected_client_key[i])
            @compileError("QUIC Initial client key mismatch at byte " ++ &[_]u8{'0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10))});
    }
    for (0..12) |i| {
        if (keys.client.iv[i] != expected_client_iv[i])
            @compileError("QUIC Initial client IV mismatch");
    }
}
