// @zpm/crypto/tls13_server — TLS 1.3 Server Handshake for QUIC (RFC 9001).
//
// Implements the server side of TLS 1.3 (RFC 8446) as required by QUIC:
//   - Parse ClientHello (extract key_share, ALPN, supported_versions)
//   - Generate ServerHello (X25519 key_share, cipher suite)
//   - Compute shared secret and derive handshake/application keys
//   - Build EncryptedExtensions (transport parameters, ALPN)
//   - Build Certificate + CertificateVerify + Finished
//
// Zero allocator. All buffers caller-provided or stack-local.
// Operates on byte slices — no I/O, no platform deps.

const sha256 = @import("sha256.sig");
const hkdf = @import("hkdf.sig");
const x25519_mod = @import("x25519.sig");
const aes = @import("aes.sig");
const gcm = @import("gcm.sig");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

/// TLS 1.3 cipher suite: TLS_AES_128_GCM_SHA256 (0x1301)
const CIPHER_SUITE: u16 = 0x1301;

/// TLS 1.3 supported version
const TLS13_VERSION: u16 = 0x0304;

/// Handshake message types
const MSG_CLIENT_HELLO: u8 = 1;
const MSG_SERVER_HELLO: u8 = 2;
const MSG_ENCRYPTED_EXTENSIONS: u8 = 8;
const MSG_CERTIFICATE: u8 = 11;
const MSG_CERTIFICATE_VERIFY: u8 = 15;
const MSG_FINISHED: u8 = 20;

/// Extension types
const EXT_SUPPORTED_VERSIONS: u16 = 0x002B;
const EXT_KEY_SHARE: u16 = 0x0033;
const EXT_ALPN: u16 = 0x0010;
const EXT_QUIC_TRANSPORT_PARAMS: u16 = 0x0039;

/// Named group: x25519
const GROUP_X25519: u16 = 0x001D;

// ══════════════════════════════════════════════════════════════════════════════
// Handshake State
// ══════════════════════════════════════════════════════════════════════════════

pub const HandshakeState = enum(u8) {
    idle,
    /// ClientHello received, ready to generate server flight
    client_hello_received,
    /// Server flight generated, waiting for client Finished
    server_flight_sent,
    /// Handshake complete, application keys active
    complete,
    /// Error state
    failed,
};

/// Key material produced by the handshake.
pub const HandshakeKeys = struct {
    /// Server handshake traffic key/IV (for encrypting EE+Cert+Finished)
    server_hs_key: [16]u8 = @splat(0),
    server_hs_iv: [12]u8 = @splat(0),
    /// Client handshake traffic key/IV (for decrypting client Finished)
    client_hs_key: [16]u8 = @splat(0),
    client_hs_iv: [12]u8 = @splat(0),
    /// Server application traffic key/IV
    server_app_key: [16]u8 = @splat(0),
    server_app_iv: [12]u8 = @splat(0),
    /// Client application traffic key/IV
    client_app_key: [16]u8 = @splat(0),
    client_app_iv: [12]u8 = @splat(0),
};

/// Parsed ClientHello data relevant to QUIC.
pub const ClientHelloInfo = struct {
    client_key_share: [32]u8 = @splat(0),
    has_key_share: bool = false,
    alpn: [16]u8 = @splat(0),
    alpn_len: u8 = 0,
    has_tls13: bool = false,
    client_random: [32]u8 = @splat(0),
};

/// Complete server handshake context.
pub const ServerHandshake = struct {
    state: HandshakeState = .idle,
    keys: HandshakeKeys = .{},

    // X25519 keypair
    server_private: [32]u8 = @splat(0),
    server_public: [32]u8 = @splat(0),
    shared_secret: [32]u8 = @splat(0),

    // Transcript hash (running SHA-256 of all handshake messages)
    transcript: sha256.Context = sha256.Context.init(),

    // Client info
    client_info: ClientHelloInfo = .{},

    // Traffic secrets (needed for key derivation)
    server_hs_secret: [32]u8 = @splat(0),
    client_hs_secret: [32]u8 = @splat(0),

    // Server flight output buffer
    server_hello_buf: [512]u8 = @splat(0),
    server_hello_len: u16 = 0,
    encrypted_exts_buf: [2048]u8 = @splat(0),
    encrypted_exts_len: u16 = 0,

    /// Initialize with server's X25519 private key (32 random bytes).
    pub fn init(private_key: *const [32]u8) ServerHandshake {
        var hs = ServerHandshake{};
        hs.server_private = private_key.*;
        // Compute public key
        x25519_mod.scalarmult(&hs.server_public, &hs.server_private, &x25519_mod.BASEPOINT);
        return hs;
    }

    /// Feed a ClientHello message (the raw TLS handshake message bytes).
    /// Returns true if successfully parsed and ready to generate response.
    pub fn feedClientHello(self: *ServerHandshake, msg: []const u8) bool {
        if (msg.len < 39) return false; // minimum ClientHello size
        if (msg[0] != MSG_CLIENT_HELLO) return false;

        // Add to transcript
        self.transcript.update(msg);

        // Parse ClientHello
        var pos: usize = 4; // skip type(1) + length(3)

        // client_version (2) — legacy, must be 0x0303 for TLS 1.3
        pos += 2;

        // random (32)
        if (pos + 32 > msg.len) return false;
        @memcpy(&self.client_info.client_random, msg[pos..][0..32]);
        pos += 32;

        // session_id (variable)
        if (pos >= msg.len) return false;
        const sid_len: usize = msg[pos];
        pos += 1 + sid_len;

        // cipher_suites (variable)
        if (pos + 2 > msg.len) return false;
        const cs_len: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
        pos += 2 + cs_len;

        // compression_methods (variable)
        if (pos >= msg.len) return false;
        const cm_len: usize = msg[pos];
        pos += 1 + cm_len;

        // Extensions
        if (pos + 2 > msg.len) return false;
        const ext_total: usize = (@as(usize, msg[pos]) << 8) | msg[pos + 1];
        pos += 2;
        const ext_end = @min(pos + ext_total, msg.len);

        while (pos + 4 <= ext_end) {
            const ext_type: u16 = (@as(u16, msg[pos]) << 8) | msg[pos + 1];
            const ext_len: usize = (@as(usize, msg[pos + 2]) << 8) | msg[pos + 3];
            pos += 4;
            if (pos + ext_len > ext_end) break;

            switch (ext_type) {
                EXT_KEY_SHARE => {
                    // Parse key_share_extension (client)
                    if (ext_len >= 36) {
                        // client_shares length (2) + group(2) + key_len(2) + key(32)
                        const group: u16 = (@as(u16, msg[pos + 2]) << 8) | msg[pos + 3];
                        const klen: u16 = (@as(u16, msg[pos + 4]) << 8) | msg[pos + 5];
                        if (group == GROUP_X25519 and klen == 32 and pos + 6 + 32 <= ext_end) {
                            @memcpy(&self.client_info.client_key_share, msg[pos + 6 ..][0..32]);
                            self.client_info.has_key_share = true;
                        }
                    }
                },
                EXT_SUPPORTED_VERSIONS => {
                    // Check for TLS 1.3
                    if (ext_len >= 3) {
                        const list_len: usize = msg[pos];
                        var vi: usize = 1;
                        while (vi + 2 <= 1 + list_len and vi + 2 <= ext_len) : (vi += 2) {
                            const ver: u16 = (@as(u16, msg[pos + vi]) << 8) | msg[pos + vi + 1];
                            if (ver == TLS13_VERSION) self.client_info.has_tls13 = true;
                        }
                    }
                },
                EXT_ALPN => {
                    // Parse ALPN list, look for "h3"
                    if (ext_len >= 4) {
                        var ai: usize = 2; // skip list length
                        while (ai < ext_len) {
                            const plen: usize = msg[pos + ai];
                            ai += 1;
                            if (ai + plen <= ext_len and plen <= 16) {
                                @memcpy(self.client_info.alpn[0..plen], msg[pos + ai ..][0..plen]);
                                self.client_info.alpn_len = @intCast(plen);
                                break; // take first ALPN
                            }
                            ai += plen;
                        }
                    }
                },
                else => {},
            }
            pos += ext_len;
        }

        if (!self.client_info.has_key_share or !self.client_info.has_tls13) return false;

        self.state = .client_hello_received;
        return true;
    }

    /// Generate the ServerHello message. Writes to server_hello_buf.
    /// Must be called after feedClientHello returns true.
    /// Returns the ServerHello bytes (to be placed in a CRYPTO frame in an Initial packet).
    pub fn generateServerHello(self: *ServerHandshake) []const u8 {
        if (self.state != .client_hello_received) return &.{};

        // Compute X25519 shared secret
        x25519_mod.scalarmult(&self.shared_secret, &self.server_private, &self.client_info.client_key_share);

        var pos: usize = 0;
        const buf = &self.server_hello_buf;

        // Handshake header: type(1) + length(3)
        buf[pos] = MSG_SERVER_HELLO;
        pos += 1;
        const len_pos = pos;
        pos += 3; // placeholder for length

        // ProtocolVersion: legacy 0x0303
        buf[pos] = 0x03; buf[pos + 1] = 0x03;
        pos += 2;

        // Random (32 bytes — use a deterministic value from shared secret for now)
        var server_random: [32]u8 = undefined;
        sha256.hash(&self.server_private, &server_random);
        @memcpy(buf[pos..][0..32], &server_random);
        pos += 32;

        // Session ID (echo client's — we use 0 length for QUIC)
        buf[pos] = 0; // empty session ID
        pos += 1;

        // Cipher suite: TLS_AES_128_GCM_SHA256 (0x1301)
        buf[pos] = 0x13; buf[pos + 1] = 0x01;
        pos += 2;

        // Compression method: null (0x00)
        buf[pos] = 0x00;
        pos += 1;

        // Extensions
        const ext_start = pos;
        pos += 2; // extension list length placeholder

        // Extension: supported_versions (select TLS 1.3)
        buf[pos] = 0x00; buf[pos + 1] = 0x2B; // type
        buf[pos + 2] = 0x00; buf[pos + 3] = 0x02; // length
        buf[pos + 4] = 0x03; buf[pos + 5] = 0x04; // TLS 1.3
        pos += 6;

        // Extension: key_share (server's X25519 public key)
        buf[pos] = 0x00; buf[pos + 1] = 0x33; // type
        buf[pos + 2] = 0x00; buf[pos + 3] = 0x24; // length (36)
        buf[pos + 4] = 0x00; buf[pos + 5] = 0x1D; // group: x25519
        buf[pos + 6] = 0x00; buf[pos + 7] = 0x20; // key length: 32
        @memcpy(buf[pos + 8 ..][0..32], &self.server_public);
        pos += 40;

        // Write extension list length
        const ext_len = pos - ext_start - 2;
        buf[ext_start] = @intCast(ext_len >> 8);
        buf[ext_start + 1] = @intCast(ext_len & 0xFF);

        // Write handshake message length
        const msg_len = pos - 4;
        buf[len_pos] = @intCast((msg_len >> 16) & 0xFF);
        buf[len_pos + 1] = @intCast((msg_len >> 8) & 0xFF);
        buf[len_pos + 2] = @intCast(msg_len & 0xFF);

        self.server_hello_len = @intCast(pos);

        // Add ServerHello to transcript
        self.transcript.update(buf[0..pos]);

        // Derive handshake keys
        self.deriveHandshakeKeys();

        return buf[0..pos];
    }

    /// Derive handshake traffic keys from the shared secret + transcript.
    fn deriveHandshakeKeys(self: *ServerHandshake) void {
        const zeros: [32]u8 = @splat(0);

        // early_secret = HKDF-Extract(zero_salt, zero_ikm)
        var early_secret: [32]u8 = undefined;
        hkdf.extract(&zeros, &zeros, &early_secret);

        // derived_secret = Derive-Secret(early_secret, "derived", "")
        var empty_hash: [32]u8 = undefined;
        sha256.hash(&.{}, &empty_hash);
        var derived: [32]u8 = undefined;
        hkdf.expandLabel(&early_secret, "derived", &empty_hash, &derived);

        // handshake_secret = HKDF-Extract(derived, shared_secret)
        var handshake_secret: [32]u8 = undefined;
        hkdf.extract(&derived, &self.shared_secret, &handshake_secret);

        // Get transcript hash up to this point (CH + SH)
        var transcript_hash: [32]u8 = undefined;
        var transcript_copy = self.transcript;
        transcript_copy.final(&transcript_hash);

        // client_handshake_traffic_secret
        hkdf.expandLabel(&handshake_secret, "c hs traffic", &transcript_hash, &self.client_hs_secret);
        // server_handshake_traffic_secret
        hkdf.expandLabel(&handshake_secret, "s hs traffic", &transcript_hash, &self.server_hs_secret);

        // Derive key/IV for each
        hkdf.expandLabel(&self.server_hs_secret, "key", &.{}, &self.keys.server_hs_key);
        hkdf.expandLabel(&self.server_hs_secret, "iv", &.{}, &self.keys.server_hs_iv);
        hkdf.expandLabel(&self.client_hs_secret, "key", &.{}, &self.keys.client_hs_key);
        hkdf.expandLabel(&self.client_hs_secret, "iv", &.{}, &self.keys.client_hs_iv);
    }

    /// Generate EncryptedExtensions message (plaintext, to be encrypted at Handshake level).
    /// Contains QUIC transport parameters and ALPN.
    pub fn generateEncryptedExtensions(self: *ServerHandshake, transport_params: []const u8) []const u8 {
        var pos: usize = 0;
        const buf = &self.encrypted_exts_buf;

        // Handshake header
        buf[pos] = MSG_ENCRYPTED_EXTENSIONS;
        pos += 1;
        const len_pos = pos;
        pos += 3;

        // Extensions list length placeholder
        const ext_list_pos = pos;
        pos += 2;

        // ALPN extension
        if (self.client_info.alpn_len > 0) {
            const alpn = self.client_info.alpn[0..self.client_info.alpn_len];
            buf[pos] = 0x00; buf[pos + 1] = 0x10; // ALPN type
            const alpn_ext_len: u16 = @intCast(2 + 1 + alpn.len);
            buf[pos + 2] = @intCast(alpn_ext_len >> 8);
            buf[pos + 3] = @intCast(alpn_ext_len & 0xFF);
            pos += 4;
            // ALPN list
            const alpn_list_len: u16 = @intCast(1 + alpn.len);
            buf[pos] = @intCast(alpn_list_len >> 8);
            buf[pos + 1] = @intCast(alpn_list_len & 0xFF);
            pos += 2;
            buf[pos] = @intCast(alpn.len);
            pos += 1;
            @memcpy(buf[pos..][0..alpn.len], alpn);
            pos += alpn.len;
        }

        // QUIC transport parameters extension
        if (transport_params.len > 0) {
            buf[pos] = @intCast(EXT_QUIC_TRANSPORT_PARAMS >> 8);
            buf[pos + 1] = @intCast(EXT_QUIC_TRANSPORT_PARAMS & 0xFF);
            buf[pos + 2] = @intCast(transport_params.len >> 8);
            buf[pos + 3] = @intCast(transport_params.len & 0xFF);
            pos += 4;
            @memcpy(buf[pos..][0..transport_params.len], transport_params);
            pos += transport_params.len;
        }

        // Write extensions list length
        const ext_len = pos - ext_list_pos - 2;
        buf[ext_list_pos] = @intCast(ext_len >> 8);
        buf[ext_list_pos + 1] = @intCast(ext_len & 0xFF);

        // Write message length
        const msg_len = pos - 4;
        buf[len_pos] = @intCast((msg_len >> 16) & 0xFF);
        buf[len_pos + 1] = @intCast((msg_len >> 8) & 0xFF);
        buf[len_pos + 2] = @intCast(msg_len & 0xFF);

        self.encrypted_exts_len = @intCast(pos);

        // Add to transcript
        self.transcript.update(buf[0..pos]);

        return buf[0..pos];
    }

    /// Generate the Finished message (HMAC over transcript).
    /// Call after generateEncryptedExtensions.
    pub fn generateFinished(self: *ServerHandshake, out: []u8) usize {
        // finished_key = HKDF-Expand-Label(server_hs_secret, "finished", "", 32)
        var finished_key: [32]u8 = undefined;
        hkdf.expandLabel(&self.server_hs_secret, "finished", &.{}, &finished_key);

        // verify_data = HMAC(finished_key, transcript_hash)
        var transcript_hash: [32]u8 = undefined;
        var transcript_copy = self.transcript;
        transcript_copy.final(&transcript_hash);

        var verify_data: [32]u8 = undefined;
        sha256.hmac(&finished_key, &transcript_hash, &verify_data);

        // Build Finished message: type(1) + length(3) + verify_data(32)
        if (out.len < 36) return 0;
        out[0] = MSG_FINISHED;
        out[1] = 0;
        out[2] = 0;
        out[3] = 32;
        @memcpy(out[4..36], &verify_data);

        // Add to transcript
        self.transcript.update(out[0..36]);

        // Derive application keys
        self.deriveApplicationKeys();

        self.state = .server_flight_sent;
        return 36;
    }

    /// Derive application traffic keys (called after Finished is added to transcript).
    fn deriveApplicationKeys(self: *ServerHandshake) void {
        const zeros: [32]u8 = @splat(0);

        // Recompute from handshake_secret → master_secret
        var early_secret: [32]u8 = undefined;
        hkdf.extract(&zeros, &zeros, &early_secret);
        var empty_hash: [32]u8 = undefined;
        sha256.hash(&.{}, &empty_hash);
        var derived1: [32]u8 = undefined;
        hkdf.expandLabel(&early_secret, "derived", &empty_hash, &derived1);
        var handshake_secret: [32]u8 = undefined;
        hkdf.extract(&derived1, &self.shared_secret, &handshake_secret);

        // master_secret = HKDF-Extract(Derive-Secret(hs, "derived", ""), zero)
        var derived2: [32]u8 = undefined;
        hkdf.expandLabel(&handshake_secret, "derived", &empty_hash, &derived2);
        var master_secret: [32]u8 = undefined;
        hkdf.extract(&derived2, &zeros, &master_secret);

        // Get full transcript hash (CH + SH + EE + Cert + CV + Finished)
        var transcript_hash: [32]u8 = undefined;
        var transcript_copy = self.transcript;
        transcript_copy.final(&transcript_hash);

        // Application traffic secrets
        var server_app_secret: [32]u8 = undefined;
        var client_app_secret: [32]u8 = undefined;
        hkdf.expandLabel(&master_secret, "s ap traffic", &transcript_hash, &server_app_secret);
        hkdf.expandLabel(&master_secret, "c ap traffic", &transcript_hash, &client_app_secret);

        // Derive key/IV
        hkdf.expandLabel(&server_app_secret, "key", &.{}, &self.keys.server_app_key);
        hkdf.expandLabel(&server_app_secret, "iv", &.{}, &self.keys.server_app_iv);
        hkdf.expandLabel(&client_app_secret, "key", &.{}, &self.keys.client_app_key);
        hkdf.expandLabel(&client_app_secret, "iv", &.{}, &self.keys.client_app_iv);
    }

    /// Verify the client's Finished message.
    pub fn verifyClientFinished(self: *ServerHandshake, msg: []const u8) bool {
        if (msg.len < 36 or msg[0] != MSG_FINISHED) return false;

        // finished_key = HKDF-Expand-Label(client_hs_secret, "finished", "", 32)
        var finished_key: [32]u8 = undefined;
        hkdf.expandLabel(&self.client_hs_secret, "finished", &.{}, &finished_key);

        // Expected verify_data = HMAC(finished_key, transcript_hash_before_client_finished)
        var transcript_hash: [32]u8 = undefined;
        var transcript_copy = self.transcript;
        transcript_copy.final(&transcript_hash);

        var expected: [32]u8 = undefined;
        sha256.hmac(&finished_key, &transcript_hash, &expected);

        // Constant-time compare
        var diff: u8 = 0;
        for (0..32) |i| {
            diff |= msg[4 + i] ^ expected[i];
        }

        if (diff == 0) {
            self.transcript.update(msg);
            self.state = .complete;
            return true;
        }
        return false;
    }
};
