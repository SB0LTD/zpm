// QUIC Key Derivation — RFC 9001 §5
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Derives Initial secrets from the Destination Connection ID (DCID),
// and provides QUIC-specific key/IV/HP derivation per RFC 9001 §5.1-5.2.
//
// QUIC Initial keys use a well-known salt (not secret) so that
// both client and server can derive them from the DCID alone.

const sha256 = @import("sha256");
const hkdf = @import("hkdf");

/// QUIC v1 Initial salt (RFC 9001 §5.2).
/// This is a publicly known constant — Initial packets are NOT confidential,
/// they only provide integrity protection during the handshake bootstrap.
pub const INITIAL_SALT_V1: [20]u8 = .{
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
    0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
    0xcc, 0xbb, 0x7f, 0x0a,
};

/// QUIC v2 Initial salt (RFC 9369 §5.2).
pub const INITIAL_SALT_V2: [20]u8 = .{
    0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb,
    0x81, 0x93, 0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb,
    0xf9, 0xbd, 0x2e, 0xd9,
};

/// A complete set of QUIC traffic keys for one direction.
pub const TrafficKeys = struct {
    key: [16]u8,
    iv: [12]u8,
    hp: [16]u8,
};

/// Both directions of Initial keys.
pub const InitialKeys = struct {
    client: TrafficKeys,
    server: TrafficKeys,
};

/// Derive QUIC Initial secrets and keys from the Destination Connection ID.
/// This is done by both client and server before any TLS messages are exchanged.
///
/// initial_secret = HKDF-Extract(initial_salt, client_dst_connection_id)
/// client_initial_secret = Derive-Secret(initial_secret, "client in", "")
/// server_initial_secret = Derive-Secret(initial_secret, "server in", "")
pub fn deriveInitialKeys(dcid: []const u8) InitialKeys {
    // Extract initial secret
    const initial_secret = hkdf.extract(&INITIAL_SALT_V1, dcid);

    // Derive client and server initial secrets
    const empty_hash = sha256.hash("");
    var client_secret: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;
    hkdf.deriveSecret(&initial_secret, "client in", &empty_hash, &client_secret);
    hkdf.deriveSecret(&initial_secret, "server in", &empty_hash, &server_secret);

    // Derive traffic keys from secrets
    return .{
        .client = deriveTrafficKeys(&client_secret),
        .server = deriveTrafficKeys(&server_secret),
    };
}

/// Derive QUIC traffic keys (key, IV, HP key) from a traffic secret.
/// Per RFC 9001 §5.1:
///   quic_key = HKDF-Expand-Label(secret, "quic key", "", 16)
///   quic_iv  = HKDF-Expand-Label(secret, "quic iv", "", 12)
///   quic_hp  = HKDF-Expand-Label(secret, "quic hp", "", 16)
pub fn deriveTrafficKeys(secret: *const [32]u8) TrafficKeys {
    var keys: TrafficKeys = undefined;
    _ = hkdf.expandLabel(secret, "quic key", "", &keys.key, 16);
    _ = hkdf.expandLabel(secret, "quic iv", "", &keys.iv, 12);
    _ = hkdf.expandLabel(secret, "quic hp", "", &keys.hp, 16);
    return keys;
}

/// Derive the QUIC packet number (PN) XOR mask for header protection.
/// Uses AES-ECB to encrypt a sample from the packet payload.
/// The mask is used to protect the packet number field.
///
/// For AES-128-based header protection:
///   mask = AES-ECB(hp_key, sample)
/// where sample is 16 bytes from the payload at a specific offset.
pub fn headerProtectionMask(hp_key: *const [16]u8, sample: *const [16]u8) [5]u8 {
    const aes = @import("aes");
    const cipher = aes.Aes128.init(hp_key);
    var block: [16]u8 = sample.*;
    cipher.encryptBlock(&block);
    return .{ block[0], block[1], block[2], block[3], block[4] };
}

/// Construct the nonce for AEAD encryption/decryption.
/// Per RFC 9001 §5.3:
///   nonce = iv XOR (packet_number padded to iv length, left-padded with zeros)
pub fn constructNonce(iv: *const [12]u8, pkt_number: u64) [12]u8 {
    var nonce: [12]u8 = iv.*;
    // XOR packet number into the rightmost bytes of the IV
    nonce[4] ^= @intCast((pkt_number >> 56) & 0xFF);
    nonce[5] ^= @intCast((pkt_number >> 48) & 0xFF);
    nonce[6] ^= @intCast((pkt_number >> 40) & 0xFF);
    nonce[7] ^= @intCast((pkt_number >> 32) & 0xFF);
    nonce[8] ^= @intCast((pkt_number >> 24) & 0xFF);
    nonce[9] ^= @intCast((pkt_number >> 16) & 0xFF);
    nonce[10] ^= @intCast((pkt_number >> 8) & 0xFF);
    nonce[11] ^= @intCast(pkt_number & 0xFF);
    return nonce;
}

/// Derive handshake traffic keys from TLS handshake secrets.
/// Called after ServerHello is processed and the handshake secret is established.
pub fn deriveHandshakeKeys(
    client_hs_secret: *const [32]u8,
    server_hs_secret: *const [32]u8,
) struct { client: TrafficKeys, server: TrafficKeys } {
    return .{
        .client = deriveTrafficKeys(client_hs_secret),
        .server = deriveTrafficKeys(server_hs_secret),
    };
}

/// Key update (RFC 9001 §6, RFC 8446 §7.2):
/// application_traffic_secret_N+1 = HKDF-Expand-Label(
///     application_traffic_secret_N, "traffic upd", "", 32)
pub fn updateTrafficSecret(current_secret: *const [32]u8, new_secret: *[32]u8) void {
    _ = hkdf.expandLabel(current_secret, "traffic upd", "", new_secret, 32);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "quic_keys: Initial keys from RFC 9001 Appendix A" {
    // RFC 9001 §A.1: Initial Packet Protection
    // Client Destination Connection ID: 0x8394c8f03e515708
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };

    const keys = deriveInitialKeys(&dcid);

    // RFC 9001 §A.1 expected client initial key:
    // client key: 1f369613dd76d5467730efcbe3b1a22d
    const expected_client_key = [16]u8{
        0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
        0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d,
    };
    for (0..16) |i| {
        if (keys.client.key[i] != expected_client_key[i]) return error.TestUnexpectedResult;
    }

    // client iv: fa044b2f42a3fd3b46fb255c
    const expected_client_iv = [12]u8{
        0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b,
        0x46, 0xfb, 0x25, 0x5c,
    };
    for (0..12) |i| {
        if (keys.client.iv[i] != expected_client_iv[i]) return error.TestUnexpectedResult;
    }

    // client hp: 9f50449e04a0e810283a1e9933adedd2
    const expected_client_hp = [16]u8{
        0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
        0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2,
    };
    for (0..16) |i| {
        if (keys.client.hp[i] != expected_client_hp[i]) return error.TestUnexpectedResult;
    }

    // server key: cf3a5331653c364c88f0f379b6067e37
    const expected_server_key = [16]u8{
        0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c,
        0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37,
    };
    for (0..16) |i| {
        if (keys.server.key[i] != expected_server_key[i]) return error.TestUnexpectedResult;
    }

    // server iv: 0ac1493ca1905853b0bba03e
    const expected_server_iv = [12]u8{
        0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53,
        0xb0, 0xbb, 0xa0, 0x3e,
    };
    for (0..12) |i| {
        if (keys.server.iv[i] != expected_server_iv[i]) return error.TestUnexpectedResult;
    }

    // server hp: c206b8d9b9f0f37644430b490eeaa314
    const expected_server_hp = [16]u8{
        0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76,
        0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14,
    };
    for (0..16) |i| {
        if (keys.server.hp[i] != expected_server_hp[i]) return error.TestUnexpectedResult;
    }
}

test "quic_keys: nonce construction" {
    const iv = [12]u8{ 0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c };
    const nonce = constructNonce(&iv, 0);
    // With PN=0, nonce should equal the IV
    for (0..12) |i| {
        if (nonce[i] != iv[i]) return error.TestUnexpectedResult;
    }

    // With PN=1
    const nonce1 = constructNonce(&iv, 1);
    // Only the last byte should differ (XOR with 1)
    for (0..11) |i| {
        if (nonce1[i] != iv[i]) return error.TestUnexpectedResult;
    }
    if (nonce1[11] != (iv[11] ^ 1)) return error.TestUnexpectedResult;
}

test "quic_keys: traffic key update produces different secret" {
    const secret = [32]u8{0xAA} ** 32;
    var new_secret: [32]u8 = undefined;
    updateTrafficSecret(&secret, &new_secret);

    var same = true;
    for (0..32) |i| {
        if (secret[i] != new_secret[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;
}

test "quic_keys: header protection mask is deterministic" {
    const hp_key = [16]u8{ 0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10, 0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2 };
    const sample = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };

    const mask1 = headerProtectionMask(&hp_key, &sample);
    const mask2 = headerProtectionMask(&hp_key, &sample);
    for (0..5) |i| {
        if (mask1[i] != mask2[i]) return error.TestUnexpectedResult;
    }
}
