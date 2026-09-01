// TLS 1.3 Key Schedule — RFC 8446 §7.1
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Implements the TLS 1.3 key derivation hierarchy:
//
//           0 (PSK or zeros)
//           |
//           v
// PSK ->  HKDF-Extract = Early Secret
//           |
//           +-> Derive-Secret(., "ext binder" | "res binder", "")
//           |                  = binder_key
//           +-> Derive-Secret(., "c e traffic", ClientHello)
//           |                  = client_early_traffic_secret
//           +-> Derive-Secret(., "e exp master", ClientHello)
//           |                  = early_exporter_master_secret
//           v
//     Derive-Secret(., "derived", "")
//           |
//           v
// (EC)DHE -> HKDF-Extract = Handshake Secret
//           |
//           +-> Derive-Secret(., "c hs traffic", ClientHello...ServerHello)
//           |                  = client_handshake_traffic_secret
//           +-> Derive-Secret(., "s hs traffic", ClientHello...ServerHello)
//           |                  = server_handshake_traffic_secret
//           v
//     Derive-Secret(., "derived", "")
//           |
//           v
// 0 -> HKDF-Extract = Master Secret
//           |
//           +-> Derive-Secret(., "c ap traffic", ClientHello...server Finished)
//           |                  = client_application_traffic_secret_0
//           +-> Derive-Secret(., "s ap traffic", ClientHello...server Finished)
//                              = server_application_traffic_secret_0

const sha256 = @import("sha256");
const hkdf = @import("hkdf");
const hmac = @import("hmac");

// ── Key Schedule State ──────────────────────────────────────────────────

pub const KeySchedule = struct {
    early_secret: [32]u8,
    handshake_secret: [32]u8,
    master_secret: [32]u8,
    current_stage: Stage,

    const Stage = enum(u8) {
        initial,
        early,
        handshake,
        application,
    };

    /// Initialize key schedule with optional PSK (or null for zero PSK).
    pub fn init(psk: ?*const [32]u8) KeySchedule {
        const zero: [32]u8 = @splat(0);
        const ikm = if (psk) |p| p.* else zero;
        const early_secret = hkdf.extract("", &ikm);

        return .{
            .early_secret = early_secret,
            .handshake_secret = @splat(0),
            .master_secret = @splat(0),
            .current_stage = .early,
        };
    }

    /// Derive handshake secrets from the shared ECDHE secret and transcript hash.
    /// `shared_secret` is the X25519 or ECDHE result (32 bytes).
    /// `transcript_hash` is SHA-256(ClientHello...ServerHello).
    pub fn deriveHandshakeSecrets(
        self: *KeySchedule,
        shared_secret: *const [32]u8,
        transcript_hash: *const [32]u8,
        client_hs_secret: *[32]u8,
        server_hs_secret: *[32]u8,
    ) void {
        // derived_secret = Derive-Secret(early_secret, "derived", "")
        const empty_hash = sha256.hash("");
        var derived: [32]u8 = undefined;
        hkdf.deriveSecret(&self.early_secret, "derived", &empty_hash, &derived);

        // handshake_secret = HKDF-Extract(derived_secret, shared_secret)
        self.handshake_secret = hkdf.extract(&derived, shared_secret);
        self.current_stage = .handshake;

        // client_handshake_traffic_secret
        hkdf.deriveSecret(&self.handshake_secret, "c hs traffic", transcript_hash, client_hs_secret);

        // server_handshake_traffic_secret
        hkdf.deriveSecret(&self.handshake_secret, "s hs traffic", transcript_hash, server_hs_secret);
    }

    /// Derive application traffic secrets from the master secret.
    /// `transcript_hash` is SHA-256(ClientHello...server Finished).
    pub fn deriveApplicationSecrets(
        self: *KeySchedule,
        transcript_hash: *const [32]u8,
        client_app_secret: *[32]u8,
        server_app_secret: *[32]u8,
    ) void {
        // derived_secret = Derive-Secret(handshake_secret, "derived", "")
        const empty_hash = sha256.hash("");
        var derived: [32]u8 = undefined;
        hkdf.deriveSecret(&self.handshake_secret, "derived", &empty_hash, &derived);

        // master_secret = HKDF-Extract(derived_secret, 0)
        const zero: [32]u8 = @splat(0);
        self.master_secret = hkdf.extract(&derived, &zero);
        self.current_stage = .application;

        // client_application_traffic_secret_0
        hkdf.deriveSecret(&self.master_secret, "c ap traffic", transcript_hash, client_app_secret);

        // server_application_traffic_secret_0
        hkdf.deriveSecret(&self.master_secret, "s ap traffic", transcript_hash, server_app_secret);
    }

    /// Compute the Finished verify_data for a given base key.
    /// finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
    /// verify_data = HMAC(finished_key, transcript_hash)
    pub fn computeFinished(base_key: *const [32]u8, transcript_hash: *const [32]u8) [32]u8 {
        var finished_key: [32]u8 = undefined;
        _ = hkdf.expandLabel(base_key, "finished", "", &finished_key, 32);
        return hmac.mac(&finished_key, transcript_hash);
    }
};

/// Derive traffic keys (write key + IV) from a traffic secret.
/// TLS 1.3 uses:
///   key = HKDF-Expand-Label(secret, "key", "", key_length)
///   iv  = HKDF-Expand-Label(secret, "iv", "", iv_length)
pub fn deriveTrafficKeys(
    secret: *const [32]u8,
    key: *[16]u8,
    iv: *[12]u8,
) void {
    _ = hkdf.expandLabel(secret, "key", "", key, 16);
    _ = hkdf.expandLabel(secret, "iv", "", iv, 12);
}

/// Derive the header protection key from a traffic secret.
/// hp_key = HKDF-Expand-Label(secret, "quic hp", "", 16)
pub fn deriveHpKey(secret: *const [32]u8, hp_key: *[16]u8) void {
    _ = hkdf.expandLabel(secret, "quic hp", "", hp_key, 16);
}

/// Derive QUIC traffic keys (key + IV + HP key) from a traffic secret.
/// Uses "quic key", "quic iv", "quic hp" labels per RFC 9001 §5.1.
pub fn deriveQuicTrafficKeys(
    secret: *const [32]u8,
    key: *[16]u8,
    iv: *[12]u8,
    hp_key: *[16]u8,
) void {
    _ = hkdf.expandLabel(secret, "quic key", "", key, 16);
    _ = hkdf.expandLabel(secret, "quic iv", "", iv, 12);
    _ = hkdf.expandLabel(secret, "quic hp", "", hp_key, 16);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "tls13_keys: key schedule init with zero PSK" {
    const ks = KeySchedule.init(null);
    // Early secret should be non-zero (HKDF-Extract with zero salt and zero IKM)
    var all_zero = true;
    for (ks.early_secret) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    if (all_zero) return error.TestUnexpectedResult;
}

test "tls13_keys: handshake secrets differ from each other" {
    var ks = KeySchedule.init(null);
    const shared_secret: [32]u8 = @splat(0x01);
    const transcript = sha256.hash("ClientHelloServerHello");

    var client_hs: [32]u8 = undefined;
    var server_hs: [32]u8 = undefined;
    ks.deriveHandshakeSecrets(&shared_secret, &transcript, &client_hs, &server_hs);

    // Client and server secrets must be different
    var same = true;
    for (0..32) |i| {
        if (client_hs[i] != server_hs[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;
}

test "tls13_keys: application secrets differ from handshake secrets" {
    var ks = KeySchedule.init(null);
    const shared_secret: [32]u8 = @splat(0xAB);
    const hs_transcript = sha256.hash("CH+SH");
    const app_transcript = sha256.hash("CH+SH+EE+CERT+CV+FIN");

    var client_hs: [32]u8 = undefined;
    var server_hs: [32]u8 = undefined;
    ks.deriveHandshakeSecrets(&shared_secret, &hs_transcript, &client_hs, &server_hs);

    var client_app: [32]u8 = undefined;
    var server_app: [32]u8 = undefined;
    ks.deriveApplicationSecrets(&app_transcript, &client_app, &server_app);

    // Handshake and application secrets must differ
    var same = true;
    for (0..32) |i| {
        if (client_hs[i] != client_app[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;
}

test "tls13_keys: traffic key derivation produces correct lengths" {
    const secret: [32]u8 = @splat(0x42);
    var key: [16]u8 = undefined;
    var iv: [12]u8 = undefined;
    deriveTrafficKeys(&secret, &key, &iv);

    // Key and IV should be non-zero
    var key_zero = true;
    for (key) |b| {
        if (b != 0) { key_zero = false; break; }
    }
    if (key_zero) return error.TestUnexpectedResult;

    var iv_zero = true;
    for (iv) |b| {
        if (b != 0) { iv_zero = false; break; }
    }
    if (iv_zero) return error.TestUnexpectedResult;
}

test "tls13_keys: Finished computation is deterministic" {
    const base_key: [32]u8 = @splat(0x11);
    const transcript = sha256.hash("some handshake data");

    const fin1 = KeySchedule.computeFinished(&base_key, &transcript);
    const fin2 = KeySchedule.computeFinished(&base_key, &transcript);

    for (0..32) |i| {
        if (fin1[i] != fin2[i]) return error.TestUnexpectedResult;
    }
}

test "tls13_keys: QUIC traffic keys differ from TLS traffic keys" {
    const secret: [32]u8 = @splat(0xDE);
    var tls_key: [16]u8 = undefined;
    var tls_iv: [12]u8 = undefined;
    deriveTrafficKeys(&secret, &tls_key, &tls_iv);

    var quic_key: [16]u8 = undefined;
    var quic_iv: [12]u8 = undefined;
    var quic_hp: [16]u8 = undefined;
    deriveQuicTrafficKeys(&secret, &quic_key, &quic_iv, &quic_hp);

    // QUIC uses different labels, so keys should differ
    var same = true;
    for (0..16) |i| {
        if (tls_key[i] != quic_key[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;
}
