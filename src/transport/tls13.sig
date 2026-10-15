// TLS 1.3 Handshake Engine for QUIC (RFC 9001 + RFC 8446)
//
// Minimal, self-contained TLS 1.3 implementation targeting QUIC transport.
// Supports only TLS_AES_128_GCM_SHA256 with X25519 key exchange and
// ECDSA P-256 certificate authentication. Zero allocator usage.
//
// Inspired by Firedancer's fd_tls (minimal QUIC-TLS) and Cloudflare quiche.
// Implements only what's needed: 1-RTT handshake, no 0-RTT, no PSK resumption,
// no client authentication, no HelloRetryRequest.
//
// Standards: RFC 8446 (TLS 1.3), RFC 9001 (QUIC-TLS), RFC 7748 (X25519),
//            RFC 6979 (deterministic ECDSA).

const std = @import("std");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const Hmac = crypto.auth.hmac.sha2.HmacSha256;
const X25519 = crypto.dh.X25519;

const builtin = @import("builtin");

fn writeStdout(msg: []const u8) void {
    // Debug logging only; portable and crash-free on every target. On Linux it
    // writes to fd 1 via the raw syscall; elsewhere it is a no-op (the mesh is
    // driven cross-platform now, so this must never hit a Linux-only syscall on
    // Windows).
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.write(1, msg.ptr, msg.len);
    }
}

// Windows CSPRNG via bcrypt!BCryptGenRandom (bcrypt is already linked by
// win32.sig's extern decls and by the AEAD path). Direct OS call — safe under
// PIE (unlike std.crypto.random's thread-local CSPRNG).
const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x00000002;
extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pbBuffer: [*]u8, cbBuffer: u32, dwFlags: u32) callconv(.c) i32;

/// Fill `out` with cryptographically secure random bytes, portably across the
/// mesh's targets (Windows + Linux/Android). The tls13 engine is now driven on
/// both platforms (Option B), so this must never invoke a Linux-only syscall on
/// Windows. On Linux it uses the getrandom syscall; on Windows BCryptGenRandom.
fn fillRandom(out: []u8) void {
    switch (builtin.os.tag) {
        .windows => {
            _ = BCryptGenRandom(null, out.ptr, @intCast(out.len), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        },
        else => {
            _ = std.os.linux.getrandom(out.ptr, out.len, 0);
        },
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

/// TLS 1.3 protocol version (0x0304)
const TLS_13: u16 = 0x0304;

/// TLS record/legacy version
const TLS_12: u16 = 0x0303;

/// Cipher suite: TLS_AES_128_GCM_SHA256
const TLS_AES_128_GCM_SHA256: u16 = 0x1301;

/// Handshake message types (RFC 8446 §4)
const HsMsgType = struct {
    const client_hello: u8 = 1;
    const server_hello: u8 = 2;
    const encrypted_extensions: u8 = 8;
    const certificate: u8 = 11;
    const certificate_verify: u8 = 15;
    const finished: u8 = 20;
};

/// Extension types (RFC 8446 §4.2)
const ExtType = struct {
    const server_name: u16 = 0;
    const supported_groups: u16 = 10;
    const signature_algorithms: u16 = 13;
    const alpn: u16 = 16;
    const supported_versions: u16 = 43;
    const key_share: u16 = 51;
    const quic_transport_params: u16 = 57; // RFC 9001
};

/// Signature schemes
const SigScheme = struct {
    const ecdsa_secp256r1_sha256: u16 = 0x0403;
};

/// Named groups
const NamedGroup = struct {
    const x25519: u16 = 0x001d;
};

/// SHA-256 hash length
const HASH_LEN: usize = 32;

/// X25519 key size
const X25519_KEY_LEN: usize = 32;

/// AES-128-GCM key size
const AES_KEY_LEN: usize = 16;

/// AES-GCM IV size
const IV_LEN: usize = 12;

// ══════════════════════════════════════════════════════════════════════════════
// TLS 1.3 Handshake State Machine
// ══════════════════════════════════════════════════════════════════════════════

pub const HandshakeState = enum(u8) {
    idle,
    wait_client_hello, // server
    wait_client_finished, // server
    wait_server_hello, // client — awaiting ServerHello (Initial-level)
    wait_server_finished, // client — awaiting EE+Cert+CV+Finished (Handshake-level)
    connected,
    failed,
};

pub const HandshakeError = enum(u8) {
    none,
    decode_error,
    unsupported_version,
    no_shared_cipher,
    no_shared_group,
    missing_key_share,
    missing_extension,
    cert_not_loaded,
    signature_failed,
    verify_failed,
    buffer_overflow,
    internal_error,
};

/// Result from processing a handshake message.
pub const ProcessResult = struct {
    /// Bytes produced in the output buffer (CRYPTO frame data to send).
    output_len: u16 = 0,
    /// Offset where the Handshake-level data starts (ServerHello ends here).
    /// output_buf[0..server_hello_len] = Initial-level CRYPTO (ServerHello)
    /// output_buf[server_hello_len..output_len] = Handshake-level CRYPTO (EE+Cert+CV+Fin)
    server_hello_len: u16 = 0,
    /// Whether the handshake is now complete.
    complete: bool = false,
    /// Error, if any.
    err: HandshakeError = .none,
    /// Negotiated ALPN protocol.
    alpn: [64]u8 = @as([64]u8, @splat(0)),
    alpn_len: u8 = 0,
    /// Derived key material for QUIC packet protection.
    handshake_keys_available: bool = false,
    application_keys_available: bool = false,
    /// Peer's QUIC transport parameters, parsed from the peer's quic_transport_params
    /// (0x39) extension (ClientHello on the server, EncryptedExtensions on the client).
    peer_transport_params: [512]u8 = @as([512]u8, @splat(0)),
    peer_transport_params_len: u16 = 0,
};

/// QUIC encryption keys derived during handshake.
pub const QuicKeys = struct {
    key: [AES_KEY_LEN]u8 = @as([AES_KEY_LEN]u8, @splat(0)),
    iv: [IV_LEN]u8 = @as([IV_LEN]u8, @splat(0)),
    hp_key: [AES_KEY_LEN]u8 = @as([AES_KEY_LEN]u8, @splat(0)),
    valid: bool = false,
};

/// Complete TLS 1.3 handshake engine for QUIC server role.
/// Fixed-size, zero-alloc. All buffers are embedded.
pub const Tls13Engine = struct {
    state: HandshakeState = .idle,
    is_server: bool = true,

    // ── Key Exchange ──
    eph_private: [X25519_KEY_LEN]u8 = @as([X25519_KEY_LEN]u8, @splat(0)),
    eph_public: [X25519_KEY_LEN]u8 = @as([X25519_KEY_LEN]u8, @splat(0)),
    shared_secret: [X25519_KEY_LEN]u8 = @as([X25519_KEY_LEN]u8, @splat(0)),

    // ── Transcript Hash ──
    transcript: Sha256 = Sha256.init(.{}),

    // ── Derived Secrets ──
    early_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),
    handshake_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),
    client_hs_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),
    server_hs_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),
    master_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),
    client_app_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),
    server_app_secret: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0)),

    // ── Derived QUIC Keys ──
    client_handshake_keys: QuicKeys = .{},
    server_handshake_keys: QuicKeys = .{},
    client_app_keys: QuicKeys = .{},
    server_app_keys: QuicKeys = .{},

    // ── Certificate (PEM-decoded DER) ──
    cert_der: [4096]u8 = @as([4096]u8, @splat(0)),
    cert_der_len: u16 = 0,
    private_key: [32]u8 = @as([32]u8, @splat(0)),
    private_key_loaded: bool = false,

    // ── ALPN ──
    alpn_list: [64]u8 = @as([64]u8, @splat(0)),
    alpn_list_len: u8 = 0,

    // ── QUIC Transport Parameters (server's, pre-encoded) ──
    transport_params: [512]u8 = @as([512]u8, @splat(0)),
    transport_params_len: u16 = 0,

    // ── Peer's key share (server: parsed from ClientHello; client: from ServerHello) ──
    client_key_share: [X25519_KEY_LEN]u8 = @as([X25519_KEY_LEN]u8, @splat(0)),
    client_key_share_valid: bool = false,

    // ── Peer certificate DER (client role: parsed from the server's Certificate
    //    message; dedicated so it never overloads the server's own cert_der).
    //    Sized to match cert_der so a real X.509 server certificate fits. ──
    peer_cert_der: [4096]u8 = @as([4096]u8, @splat(0)),
    peer_cert_der_len: u16 = 0,

    // ── Peer's QUIC transport params (client: from EncryptedExtensions 0x39). ──
    peer_transport_params: [512]u8 = @as([512]u8, @splat(0)),
    peer_transport_params_len: u16 = 0,

    // ── Output buffer (handshake messages to send as CRYPTO frames) ──
    // Holds one full handshake flight (ServerHello / EE+Cert+CV+Finished, or
    // ClientHello / client Finished). 8 KB accommodates a real X.509 server
    // certificate chain, not just the loopback-trust test point.
    output_buf: [8192]u8 = @as([8192]u8, @splat(0)),
    output_len: u16 = 0,
    /// Bytes of ServerHello in output_buf (Initial-level). Remainder is Handshake-level.
    server_hello_len: u16 = 0,

    // ── Client random ──
    client_random: [32]u8 = @as([32]u8, @splat(0)),

    // ── Client legacy_session_id (echoed in ServerHello per RFC 8446 §4.1.3) ──
    client_session_id: [32]u8 = @as([32]u8, @splat(0)),
    client_session_id_len: u8 = 0,

    // ══════════════════════════════════════════════════════════════════════
    // Public API
    // ══════════════════════════════════════════════════════════════════════

    /// Initialize as a QUIC server (by value — for standalone/test use).
    pub fn initServer() Tls13Engine {
        var e = Tls13Engine{};
        e.initServerInPlace();
        return e;
    }

    /// Initialize as a QUIC server IN PLACE (avoids a multi-KB by-value
    /// temporary when embedded in a larger struct).
    pub fn initServerInPlace(self: *Tls13Engine) void {
        self.* = Tls13Engine{};
        self.state = .wait_client_hello;
        self.is_server = true;

        // Default ALPN to "h3" for HTTP/3 / WebTransport compatibility
        self.alpn_list[0] = 'h';
        self.alpn_list[1] = '3';
        self.alpn_list_len = 2;

        // Generate server ephemeral X25519 keypair
        var seed: [32]u8 = undefined;
        fillRandom(&seed);
        self.eph_private = seed;
        self.eph_public = X25519.recoverPublicKey(seed) catch @as([32]u8, @splat(0));
    }

    /// Initialize as a QUIC client. Mirrors initServer() in reverse: generates
    /// the client X25519 keypair, defaults ALPN to "zpm" (the mesh protocol, so
    /// client and server advertise the same string), and sets the client role.
    /// The caller must setTransportParams() before buildClientHello().
    pub fn initClient() Tls13Engine {
        var e = Tls13Engine{};
        e.initClientInPlace();
        return e;
    }

    /// Initialize as a QUIC client IN PLACE (avoids a multi-KB by-value
    /// temporary when embedded in a larger struct).
    pub fn initClientInPlace(self: *Tls13Engine) void {
        self.* = Tls13Engine{};
        self.state = .wait_server_hello;
        self.is_server = false;

        // Default ALPN to "zpm" for the mesh (must match the server's ALPN).
        self.alpn_list[0] = 'z';
        self.alpn_list[1] = 'p';
        self.alpn_list[2] = 'm';
        self.alpn_list_len = 3;

        // Generate client ephemeral X25519 keypair
        var seed: [32]u8 = undefined;
        fillRandom(&seed);
        self.eph_private = seed;
        self.eph_public = X25519.recoverPublicKey(seed) catch @as([32]u8, @splat(0));

        // Client random + legacy_session_id (32 random bytes, echoed back by the
        // server and validated in handleServerHello).
        fillRandom(&self.client_random);
        fillRandom(&self.client_session_id);
        self.client_session_id_len = 32;
    }

    /// Load a DER-encoded certificate and ECDSA P-256 private key (32-byte scalar).
    pub fn loadCertificate(self: *Tls13Engine, cert: []const u8, key_raw: []const u8) HandshakeError {
        if (cert.len > self.cert_der.len) return .buffer_overflow;
        if (key_raw.len != 32) return .internal_error;
        @memcpy(self.cert_der[0..cert.len], cert);
        self.cert_der_len = @intCast(cert.len);
        @memcpy(&self.private_key, key_raw);
        self.private_key_loaded = true;
        return .none;
    }

    /// Set ALPN protocol to negotiate (raw bytes, e.g., "zpm").
    pub fn setAlpn(self: *Tls13Engine, alpn_wire: []const u8) void {
        const copy_len = @min(alpn_wire.len, self.alpn_list.len);
        @memcpy(self.alpn_list[0..copy_len], alpn_wire[0..copy_len]);
        self.alpn_list_len = @intCast(copy_len);
    }

    /// Set QUIC transport parameters (already encoded per RFC 9000 §18).
    pub fn setTransportParams(self: *Tls13Engine, params: []const u8) void {
        const copy_len = @min(params.len, self.transport_params.len);
        @memcpy(self.transport_params[0..copy_len], params[0..copy_len]);
        self.transport_params_len = @intCast(copy_len);
    }

    /// Process received CRYPTO frame data (a TLS handshake message).
    pub fn processMessage(self: *Tls13Engine, data: []const u8) ProcessResult {
        var result = ProcessResult{};
        self.output_len = 0;

        switch (self.state) {
            .wait_client_hello => {
                const err = self.handleClientHello(data);
                if (err != .none) {
                    self.state = .failed;
                    result.err = err;
                    return result;
                }
                result.output_len = self.output_len;
                result.server_hello_len = self.server_hello_len;
                result.handshake_keys_available = true;
                result.alpn = self.alpn_list;
                result.alpn_len = self.alpn_list_len;
            },
            .wait_client_finished => {
                const err = self.handleClientFinished(data);
                if (err != .none) {
                    self.state = .failed;
                    result.err = err;
                    return result;
                }
                result.output_len = self.output_len;
                result.complete = true;
                result.application_keys_available = true;
            },
            .wait_server_hello => {
                // Client: incoming ServerHello (Initial-level CRYPTO). Produces
                // no output; handshake keys become available after this.
                const err = self.handleServerHello(data);
                if (err != .none) {
                    self.state = .failed;
                    result.err = err;
                    return result;
                }
                result.output_len = 0;
                result.handshake_keys_available = true;
                self.state = .wait_server_finished;
            },
            .wait_server_finished => {
                // Client: incoming EE + Certificate + CertificateVerify +
                // server Finished (Handshake-level CRYPTO). Emits the client
                // Finished and completes the handshake.
                const err = self.handleServerFlight(data);
                if (err != .none) {
                    self.state = .failed;
                    result.err = err;
                    return result;
                }
                result.output_len = self.output_len;
                result.complete = true;
                result.application_keys_available = true;
                result.alpn = self.alpn_list;
                result.alpn_len = self.alpn_list_len;
                if (self.peer_transport_params_len > 0) {
                    const n = @min(self.peer_transport_params_len, @as(u16, self.peer_transport_params.len));
                    @memcpy(result.peer_transport_params[0..n], self.peer_transport_params[0..n]);
                    result.peer_transport_params_len = n;
                }
            },
            else => {
                result.err = .internal_error;
            },
        }

        return result;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Server Handshake Logic
    // ══════════════════════════════════════════════════════════════════════

    fn handleClientHello(self: *Tls13Engine, data: []const u8) HandshakeError {
        if (data.len < 43) return .decode_error;
        if (data[0] != HsMsgType.client_hello) return .decode_error;
        const msg_len = readU24(data[1..4]);
        if (msg_len + 4 > data.len) return .decode_error;

        const body = data[4..][0..msg_len];
        var pos: usize = 0;

        // legacy_version (2)
        if (pos + 2 > body.len) return .decode_error;
        pos += 2;

        // random (32)
        if (pos + 32 > body.len) return .decode_error;
        @memcpy(&self.client_random, body[pos..][0..32]);
        pos += 32;

        // legacy_session_id
        if (pos + 1 > body.len) return .decode_error;
        const session_id_len: usize = body[pos];
        pos += 1;
        if (pos + session_id_len > body.len) return .decode_error;
        // Save for echoing in ServerHello (RFC 8446 §4.1.3)
        if (session_id_len <= 32) {
            @memcpy(self.client_session_id[0..session_id_len], body[pos..][0..session_id_len]);
            self.client_session_id_len = @intCast(session_id_len);
        }
        pos += session_id_len;

        // cipher_suites
        if (pos + 2 > body.len) return .decode_error;
        const cipher_len: usize = readU16(body[pos..][0..2]);
        pos += 2;
        if (pos + cipher_len > body.len) return .decode_error;

        var found_aes128 = false;
        var i: usize = 0;
        while (i + 2 <= cipher_len) : (i += 2) {
            const suite = readU16(body[pos + i ..][0..2]);
            if (suite == TLS_AES_128_GCM_SHA256) found_aes128 = true;
        }
        if (!found_aes128) return .no_shared_cipher;
        pos += cipher_len;

        // legacy_compression_methods
        if (pos + 1 > body.len) return .decode_error;
        const comp_len: usize = body[pos];
        pos += 1 + comp_len;

        // Extensions
        if (pos + 2 > body.len) return .decode_error;
        const ext_len: usize = readU16(body[pos..][0..2]);
        pos += 2;
        if (pos + ext_len > body.len) return .decode_error;

        const ext_end = pos + ext_len;
        var has_supported_versions = false;
        var has_key_share = false;

        while (pos + 4 <= ext_end) {
            const ext_type = readU16(body[pos..][0..2]);
            pos += 2;
            const ext_data_len: usize = readU16(body[pos..][0..2]);
            pos += 2;
            if (pos + ext_data_len > ext_end) return .decode_error;

            switch (ext_type) {
                ExtType.supported_versions => {
                    if (ext_data_len < 3) {
                        pos += ext_data_len;
                        continue;
                    }
                    const list_len: usize = body[pos];
                    var vi: usize = 1;
                    while (vi + 2 <= 1 + list_len) : (vi += 2) {
                        const ver = readU16(body[pos + vi ..][0..2]);
                        if (ver == TLS_13) has_supported_versions = true;
                    }
                },
                ExtType.key_share => {
                    if (ext_data_len < 2) {
                        pos += ext_data_len;
                        continue;
                    }
                    const ks_list_len: usize = readU16(body[pos..][0..2]);
                    var ki: usize = 2;
                    while (ki + 4 <= 2 + ks_list_len) {
                        const group = readU16(body[pos + ki ..][0..2]);
                        ki += 2;
                        const klen: usize = readU16(body[pos + ki ..][0..2]);
                        ki += 2;
                        if (ki + klen > 2 + ks_list_len) break;
                        if (group == NamedGroup.x25519 and klen == X25519_KEY_LEN) {
                            @memcpy(&self.client_key_share, body[pos + ki ..][0..X25519_KEY_LEN]);
                            self.client_key_share_valid = true;
                            has_key_share = true;
                        }
                        ki += klen;
                    }
                },
                else => {},
            }
            pos += ext_data_len;
        }

        if (!has_supported_versions) return .unsupported_version;
        if (!has_key_share) return .missing_key_share;
        if (!self.private_key_loaded) {
            writeStdout("TLS: private_key_loaded=false, rejecting ClientHello\n");
            return .cert_not_loaded;
        }

        // X25519 key exchange
        self.shared_secret = X25519.scalarmult(self.eph_private, self.client_key_share) catch
            return .internal_error;

        // Update transcript with ClientHello
        self.transcript.update(data[0 .. 4 + msg_len]);

        return self.buildServerFlight();
    }

    /// Build ServerHello + EncryptedExtensions + Certificate + CertificateVerify + Finished.
    fn buildServerFlight(self: *Tls13Engine) HandshakeError {
        var out_pos: u16 = 0;

        // 1. ServerHello (sent at Initial encryption level per RFC 9001 §4.1)
        const sh_err = self.writeServerHello(&out_pos);
        if (sh_err != .none) return sh_err;

        // Record ServerHello length — everything before this is Initial-level CRYPTO
        self.server_hello_len = out_pos;

        // Update transcript with ServerHello
        self.transcript.update(self.output_buf[0..out_pos]);

        // 2. Derive handshake secrets (RFC 8446 §7.1)
        self.deriveHandshakeSecrets();

        // 3. Encrypted flight (sent at Handshake encryption level per RFC 9001 §4.1)
        const ee_start = out_pos;

        const ee_err = self.writeEncryptedExtensions(&out_pos);
        if (ee_err != .none) return ee_err;

        const cert_err = self.writeCertificate(&out_pos);
        if (cert_err != .none) return cert_err;

        const cv_err = self.writeCertificateVerify(&out_pos, ee_start);
        if (cv_err != .none) return cv_err;

        const fin_err = self.writeFinished(&out_pos, ee_start);
        if (fin_err != .none) return fin_err;

        // Update transcript with encrypted flight
        self.transcript.update(self.output_buf[ee_start..out_pos]);

        // 4. Derive application secrets
        self.deriveApplicationSecrets();

        self.output_len = out_pos;
        self.state = .wait_client_finished;
        return .none;
    }

    fn writeServerHello(self: *Tls13Engine, pos: *u16) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = pos.*;
        const hdr_start = p;
        p += 4;

        // server_version (legacy)
        if (p + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], TLS_12);
        p += 2;

        // random (32 bytes)
        if (p + 32 > buf.len) return .buffer_overflow;
        fillRandom(buf[p..][0..32]);
        p += 32;

        // legacy_session_id_echo (RFC 8446 §4.1.3: MUST echo client's value)
        const sid_len: u8 = self.client_session_id_len;
        if (p + 1 + sid_len > buf.len) return .buffer_overflow;
        buf[p] = sid_len;
        p += 1;
        if (sid_len > 0) {
            @memcpy(buf[p..][0..sid_len], self.client_session_id[0..sid_len]);
            p += sid_len;
        }

        // cipher_suite
        if (p + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], TLS_AES_128_GCM_SHA256);
        p += 2;

        // legacy_compression_method
        if (p + 1 > buf.len) return .buffer_overflow;
        buf[p] = 0;
        p += 1;

        // Extensions
        const ext_len_pos = p;
        p += 2;

        // supported_versions
        if (p + 6 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], ExtType.supported_versions);
        p += 2;
        writeU16(buf[p..][0..2], 2);
        p += 2;
        writeU16(buf[p..][0..2], TLS_13);
        p += 2;

        // key_share (server's X25519 public key)
        if (p + 4 + 2 + 2 + X25519_KEY_LEN > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], ExtType.key_share);
        p += 2;
        writeU16(buf[p..][0..2], @intCast(2 + 2 + X25519_KEY_LEN));
        p += 2;
        writeU16(buf[p..][0..2], NamedGroup.x25519);
        p += 2;
        writeU16(buf[p..][0..2], X25519_KEY_LEN);
        p += 2;
        @memcpy(buf[p..][0..X25519_KEY_LEN], &self.eph_public);
        p += X25519_KEY_LEN;

        // Write extensions length
        writeU16(buf[ext_len_pos..][0..2], @intCast(p - ext_len_pos - 2));

        // Handshake header
        buf[hdr_start] = HsMsgType.server_hello;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        pos.* = @intCast(p);
        return .none;
    }

    fn writeEncryptedExtensions(self: *Tls13Engine, pos: *u16) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = pos.*;
        const hdr_start = p;
        p += 4;

        const ext_len_pos = p;
        p += 2;

        // ALPN extension
        if (self.alpn_list_len > 0) {
            if (p + 4 + 2 + 1 + self.alpn_list_len > buf.len) return .buffer_overflow;
            writeU16(buf[p..][0..2], ExtType.alpn);
            p += 2;
            const alpn_ext_len: u16 = 2 + 1 + @as(u16, self.alpn_list_len);
            writeU16(buf[p..][0..2], alpn_ext_len);
            p += 2;
            writeU16(buf[p..][0..2], 1 + @as(u16, self.alpn_list_len));
            p += 2;
            buf[p] = self.alpn_list_len;
            p += 1;
            @memcpy(buf[p..][0..self.alpn_list_len], self.alpn_list[0..self.alpn_list_len]);
            p += self.alpn_list_len;
        }

        // QUIC transport parameters extension
        if (self.transport_params_len > 0) {
            if (p + 4 + self.transport_params_len > buf.len) return .buffer_overflow;
            writeU16(buf[p..][0..2], ExtType.quic_transport_params);
            p += 2;
            writeU16(buf[p..][0..2], self.transport_params_len);
            p += 2;
            @memcpy(buf[p..][0..self.transport_params_len], self.transport_params[0..self.transport_params_len]);
            p += self.transport_params_len;
        }

        writeU16(buf[ext_len_pos..][0..2], @intCast(p - ext_len_pos - 2));

        buf[hdr_start] = HsMsgType.encrypted_extensions;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        pos.* = @intCast(p);
        return .none;
    }

    fn writeCertificate(self: *Tls13Engine, pos: *u16) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = pos.*;
        const hdr_start = p;
        p += 4;

        // certificate_request_context (empty)
        if (p + 1 > buf.len) return .buffer_overflow;
        buf[p] = 0;
        p += 1;

        // certificate_list length placeholder
        const list_len_pos = p;
        p += 3;

        // Single CertificateEntry
        const cert_len = self.cert_der_len;
        if (p + 3 + cert_len + 2 > buf.len) return .buffer_overflow;
        writeU24(buf[p..][0..3], @intCast(cert_len));
        p += 3;
        @memcpy(buf[p..][0..cert_len], self.cert_der[0..cert_len]);
        p += cert_len;
        writeU16(buf[p..][0..2], 0); // no per-cert extensions
        p += 2;

        writeU24(buf[list_len_pos..][0..3], @intCast(p - list_len_pos - 3));

        buf[hdr_start] = HsMsgType.certificate;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        pos.* = @intCast(p);
        return .none;
    }

    fn writeCertificateVerify(self: *Tls13Engine, pos: *u16, ee_start: u16) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = pos.*;

        // Transcript hash up to Certificate
        var hash_state = self.transcript;
        hash_state.update(self.output_buf[ee_start..p]);
        const transcript_hash = hash_state.finalResult();

        // Build content to sign (RFC 8446 §4.4.3)
        var sign_content: [130]u8 = undefined;
        @memset(sign_content[0..64], 0x20);
        const label = "TLS 1.3, server CertificateVerify";
        @memcpy(sign_content[64..][0..label.len], label);
        sign_content[64 + label.len] = 0x00;
        @memcpy(sign_content[64 + label.len + 1 ..][0..HASH_LEN], &transcript_hash);
        const sign_len: usize = 64 + label.len + 1 + HASH_LEN;

        // Sign with ECDSA P-256 SHA-256
        const EcdsaP256 = crypto.sign.ecdsa.EcdsaP256Sha256;
        const secret_key = EcdsaP256.SecretKey.fromBytes(self.private_key) catch
            return .signature_failed;
        const key_pair = EcdsaP256.KeyPair.fromSecretKey(secret_key) catch
            return .signature_failed;
        const signature = key_pair.sign(sign_content[0..sign_len], null) catch
            return .signature_failed;
        var sig_der_buf: [72]u8 = undefined;
        const sig_der = signature.toDer(&sig_der_buf);
        const sig_len: u16 = @intCast(sig_der.len);

        const hdr_start = p;
        p += 4;

        if (p + 2 + 2 + sig_len > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], SigScheme.ecdsa_secp256r1_sha256);
        p += 2;
        writeU16(buf[p..][0..2], sig_len);
        p += 2;
        @memcpy(buf[p..][0..sig_len], sig_der[0..sig_len]);
        p += sig_len;

        buf[hdr_start] = HsMsgType.certificate_verify;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        pos.* = @intCast(p);
        return .none;
    }

    fn writeFinished(self: *Tls13Engine, pos: *u16, ee_start: u16) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = pos.*;

        // Transcript hash including everything up to (but not including) Finished
        var hash_state = self.transcript;
        hash_state.update(self.output_buf[ee_start..p]);
        const transcript_hash = hash_state.finalResult();

        // finished_key = HKDF-Expand-Label(server_hs_secret, "finished", "", 32)
        var finished_key: [HASH_LEN]u8 = undefined;
        hkdfExpandLabel(&self.server_hs_secret, "finished", "", &finished_key);

        // verify_data = HMAC-SHA256(finished_key, transcript_hash)
        var verify_data: [HASH_LEN]u8 = undefined;
        Hmac.create(&verify_data, &transcript_hash, &finished_key);

        const hdr_start = p;
        p += 4;

        if (p + HASH_LEN > buf.len) return .buffer_overflow;
        @memcpy(buf[p..][0..HASH_LEN], &verify_data);
        p += HASH_LEN;

        buf[hdr_start] = HsMsgType.finished;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        pos.* = @intCast(p);
        return .none;
    }

    fn handleClientFinished(self: *Tls13Engine, data: []const u8) HandshakeError {
        if (data.len < 4 + HASH_LEN) return .decode_error;
        if (data[0] != HsMsgType.finished) return .decode_error;
        const msg_len = readU24(data[1..4]);
        if (msg_len != HASH_LEN) return .decode_error;

        var finished_key: [HASH_LEN]u8 = undefined;
        hkdfExpandLabel(&self.client_hs_secret, "finished", "", &finished_key);

        // Use peek() to get transcript hash WITHOUT destroying the hasher state.
        const transcript_hash = self.transcript.peek();

        var expected: [HASH_LEN]u8 = undefined;
        Hmac.create(&expected, &transcript_hash, &finished_key);

        const received = data[4..][0..HASH_LEN];
        if (!constTimeEql(&expected, received)) return .verify_failed;

        self.transcript.update(data[0 .. 4 + HASH_LEN]);
        self.state = .connected;
        return .none;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Client Handshake Logic (allocator-free, caller-owned, consistent with
    // the server engine above — same output_buf/transcript/scratch discipline)
    // ══════════════════════════════════════════════════════════════════════

    /// Build the ClientHello into output_buf and update the transcript.
    /// Advertises TLS_AES_128_GCM_SHA256, X25519, ECDSA-P256 signatures, the
    /// client key_share, ALPN (default "zpm"), and the QUIC transport params
    /// extension (0x39). No SNI is sent (the server ignores it).
    pub fn buildClientHello(self: *Tls13Engine) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = 0;
        const hdr_start = p;
        p += 4;

        // legacy_version
        if (p + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], TLS_12);
        p += 2;

        // random (32)
        if (p + 32 > buf.len) return .buffer_overflow;
        @memcpy(buf[p..][0..32], &self.client_random);
        p += 32;

        // legacy_session_id (32 bytes)
        const sid_len: u8 = self.client_session_id_len;
        if (p + 1 + sid_len > buf.len) return .buffer_overflow;
        buf[p] = sid_len;
        p += 1;
        if (sid_len > 0) {
            @memcpy(buf[p..][0..sid_len], self.client_session_id[0..sid_len]);
            p += sid_len;
        }

        // cipher_suites: [TLS_AES_128_GCM_SHA256]
        if (p + 2 + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], 2); // 1 suite × 2 bytes
        p += 2;
        writeU16(buf[p..][0..2], TLS_AES_128_GCM_SHA256);
        p += 2;

        // legacy_compression_methods: [0]
        if (p + 2 > buf.len) return .buffer_overflow;
        buf[p] = 1;
        buf[p + 1] = 0;
        p += 2;

        // Extensions
        const ext_len_pos = p;
        p += 2;

        // supported_versions: [TLS_13]
        if (p + 4 + 1 + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], ExtType.supported_versions);
        p += 2;
        writeU16(buf[p..][0..2], 3); // ext_data: 1-byte list_len + 2-byte version
        p += 2;
        buf[p] = 2; // list length (one 2-byte version)
        p += 1;
        writeU16(buf[p..][0..2], TLS_13);
        p += 2;

        // supported_groups: [x25519]
        if (p + 4 + 2 + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], ExtType.supported_groups);
        p += 2;
        writeU16(buf[p..][0..2], 4); // ext_data: 2-byte list_len + 2-byte group
        p += 2;
        writeU16(buf[p..][0..2], 2); // named_group_list length
        p += 2;
        writeU16(buf[p..][0..2], NamedGroup.x25519);
        p += 2;

        // signature_algorithms: [ecdsa_secp256r1_sha256]
        if (p + 4 + 2 + 2 > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], ExtType.signature_algorithms);
        p += 2;
        writeU16(buf[p..][0..2], 4); // ext_data: 2-byte list_len + 2-byte scheme
        p += 2;
        writeU16(buf[p..][0..2], 2); // supported_signature_algorithms length
        p += 2;
        writeU16(buf[p..][0..2], SigScheme.ecdsa_secp256r1_sha256);
        p += 2;

        // key_share: {x25519, eph_public}
        if (p + 4 + 2 + 2 + 2 + X25519_KEY_LEN > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], ExtType.key_share);
        p += 2;
        // ext_data = 2 (client_shares length) + 2 (group) + 2 (key_exchange len) + 32
        writeU16(buf[p..][0..2], @intCast(2 + 2 + 2 + X25519_KEY_LEN));
        p += 2;
        writeU16(buf[p..][0..2], @intCast(2 + 2 + X25519_KEY_LEN)); // client_shares list length
        p += 2;
        writeU16(buf[p..][0..2], NamedGroup.x25519);
        p += 2;
        writeU16(buf[p..][0..2], X25519_KEY_LEN);
        p += 2;
        @memcpy(buf[p..][0..X25519_KEY_LEN], &self.eph_public);
        p += X25519_KEY_LEN;

        // ALPN
        if (self.alpn_list_len > 0) {
            if (p + 4 + 2 + 1 + self.alpn_list_len > buf.len) return .buffer_overflow;
            writeU16(buf[p..][0..2], ExtType.alpn);
            p += 2;
            const alpn_ext_len: u16 = 2 + 1 + @as(u16, self.alpn_list_len);
            writeU16(buf[p..][0..2], alpn_ext_len);
            p += 2;
            writeU16(buf[p..][0..2], 1 + @as(u16, self.alpn_list_len)); // ProtocolNameList length
            p += 2;
            buf[p] = self.alpn_list_len;
            p += 1;
            @memcpy(buf[p..][0..self.alpn_list_len], self.alpn_list[0..self.alpn_list_len]);
            p += self.alpn_list_len;
        }

        // QUIC transport parameters (0x39)
        if (self.transport_params_len > 0) {
            if (p + 4 + self.transport_params_len > buf.len) return .buffer_overflow;
            writeU16(buf[p..][0..2], ExtType.quic_transport_params);
            p += 2;
            writeU16(buf[p..][0..2], self.transport_params_len);
            p += 2;
            @memcpy(buf[p..][0..self.transport_params_len], self.transport_params[0..self.transport_params_len]);
            p += self.transport_params_len;
        }

        // Extensions length
        writeU16(buf[ext_len_pos..][0..2], @intCast(p - ext_len_pos - 2));

        // Handshake header
        buf[hdr_start] = HsMsgType.client_hello;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        self.output_len = @intCast(p);

        // Transcript starts with the ClientHello.
        self.transcript.update(buf[0..p]);
        return .none;
    }

    /// Parse the ServerHello, run the X25519 exchange, and derive handshake
    /// secrets. The server's share is stored in client_key_share (peer share).
    fn handleServerHello(self: *Tls13Engine, data: []const u8) HandshakeError {
        if (data.len < 4) return .decode_error;
        if (data[0] != HsMsgType.server_hello) return .decode_error;
        const msg_len = readU24(data[1..4]);
        if (@as(usize, msg_len) + 4 > data.len) return .decode_error;

        const body = data[4..][0 .. msg_len];
        var pos: usize = 0;

        // legacy_version (2)
        if (pos + 2 > body.len) return .decode_error;
        pos += 2;

        // random (32)
        if (pos + 32 > body.len) return .decode_error;
        pos += 32;

        // legacy_session_id_echo
        if (pos + 1 > body.len) return .decode_error;
        const echo_len: usize = body[pos];
        pos += 1;
        if (pos + echo_len > body.len) return .decode_error;
        // Loose validation: echo must match the session id we sent.
        if (echo_len != self.client_session_id_len) return .decode_error;
        if (echo_len > 0) {
            if (!constTimeEql(body[pos..][0..echo_len], self.client_session_id[0..echo_len]))
                return .decode_error;
        }
        pos += echo_len;

        // cipher_suite
        if (pos + 2 > body.len) return .decode_error;
        const suite = readU16(body[pos..][0..2]);
        pos += 2;
        if (suite != TLS_AES_128_GCM_SHA256) return .no_shared_cipher;

        // legacy_compression_method
        if (pos + 1 > body.len) return .decode_error;
        pos += 1;

        // Extensions
        if (pos + 2 > body.len) return .decode_error;
        const ext_len: usize = readU16(body[pos..][0..2]);
        pos += 2;
        if (pos + ext_len > body.len) return .decode_error;

        const ext_end = pos + ext_len;
        var has_supported_versions = false;
        var has_key_share = false;

        while (pos + 4 <= ext_end) {
            const ext_type = readU16(body[pos..][0..2]);
            pos += 2;
            const ext_data_len: usize = readU16(body[pos..][0..2]);
            pos += 2;
            if (pos + ext_data_len > ext_end) return .decode_error;

            switch (ext_type) {
                ExtType.supported_versions => {
                    if (ext_data_len >= 2) {
                        const ver = readU16(body[pos..][0..2]);
                        if (ver == TLS_13) has_supported_versions = true;
                    }
                },
                ExtType.key_share => {
                    // ServerHello key_share: group (2) + key_exchange_len (2) + key
                    if (ext_data_len >= 4) {
                        const group = readU16(body[pos..][0..2]);
                        const klen: usize = readU16(body[pos + 2 ..][0..2]);
                        if (group == NamedGroup.x25519 and klen == X25519_KEY_LEN and
                            4 + klen <= ext_data_len)
                        {
                            @memcpy(&self.client_key_share, body[pos + 4 ..][0..X25519_KEY_LEN]);
                            self.client_key_share_valid = true;
                            has_key_share = true;
                        }
                    }
                },
                else => {},
            }
            pos += ext_data_len;
        }

        if (!has_supported_versions) return .unsupported_version;
        if (!has_key_share) return .missing_key_share;

        // X25519 shared secret from the server's public share.
        self.shared_secret = X25519.scalarmult(self.eph_private, self.client_key_share) catch
            return .internal_error;

        // Transcript: append the ServerHello, then derive handshake secrets.
        self.transcript.update(data[0 .. 4 + msg_len]);
        self.deriveHandshakeSecrets();

        return .none;
    }

    /// Parse the server's Handshake-level flight: EncryptedExtensions,
    /// Certificate, CertificateVerify, server Finished (in order, from one
    /// reassembled CRYPTO buffer). Verifies CV against the peer certificate's
    /// public key (loopback trust) and the Finished MAC, derives application
    /// secrets, and builds the client Finished into output_buf.
    fn handleServerFlight(self: *Tls13Engine, data: []const u8) HandshakeError {
        var pos: usize = 0;

        // ── EncryptedExtensions ──
        if (pos + 4 > data.len) return .decode_error;
        if (data[pos] != HsMsgType.encrypted_extensions) return .decode_error;
        const ee_len: usize = readU24(data[pos + 1 ..][0..3]);
        if (pos + 4 + ee_len > data.len) return .decode_error;
        {
            const ee_body = data[pos + 4 ..][0..ee_len];
            if (ee_body.len >= 2) {
                const elen: usize = readU16(ee_body[0..2]);
                var ep: usize = 2;
                const eend = @min(2 + elen, ee_body.len);
                while (ep + 4 <= eend) {
                    const et = readU16(ee_body[ep..][0..2]);
                    ep += 2;
                    const edl: usize = readU16(ee_body[ep..][0..2]);
                    ep += 2;
                    if (ep + edl > eend) break;
                    if (et == ExtType.quic_transport_params) {
                        const n = @min(edl, self.peer_transport_params.len);
                        @memcpy(self.peer_transport_params[0..n], ee_body[ep..][0..n]);
                        self.peer_transport_params_len = @intCast(n);
                    }
                    ep += edl;
                }
            }
        }
        self.transcript.update(data[pos .. pos + 4 + ee_len]);
        pos += 4 + ee_len;

        // ── Certificate ──
        if (pos + 4 > data.len) return .decode_error;
        if (data[pos] != HsMsgType.certificate) return .decode_error;
        const cert_msg_len: usize = readU24(data[pos + 1 ..][0..3]);
        if (pos + 4 + cert_msg_len > data.len) return .decode_error;
        {
            const cb = data[pos + 4 ..][0..cert_msg_len];
            var cp: usize = 0;
            // certificate_request_context
            if (cp + 1 > cb.len) return .decode_error;
            const ctx_len: usize = cb[cp];
            cp += 1 + ctx_len;
            // certificate_list length (3)
            if (cp + 3 > cb.len) return .decode_error;
            const list_len: usize = readU24(cb[cp..][0..3]);
            cp += 3;
            if (cp + list_len > cb.len) return .decode_error;
            // First CertificateEntry: cert_data length (3) + DER
            if (cp + 3 > cb.len) return .decode_error;
            const entry_len: usize = readU24(cb[cp..][0..3]);
            cp += 3;
            if (cp + entry_len > cb.len) return .decode_error;
            if (entry_len == 0 or entry_len > self.peer_cert_der.len) return .decode_error;
            @memcpy(self.peer_cert_der[0..entry_len], cb[cp..][0..entry_len]);
            self.peer_cert_der_len = @intCast(entry_len);
        }
        self.transcript.update(data[pos .. pos + 4 + cert_msg_len]);
        pos += 4 + cert_msg_len;

        // ── CertificateVerify ──
        // Transcript hash up to and including Certificate is the content signed.
        const cv_transcript_hash = self.transcript.peek();
        if (pos + 4 > data.len) return .decode_error;
        if (data[pos] != HsMsgType.certificate_verify) return .decode_error;
        const cv_len: usize = readU24(data[pos + 1 ..][0..3]);
        if (pos + 4 + cv_len > data.len) return .decode_error;
        {
            const cvb = data[pos + 4 ..][0..cv_len];
            if (cvb.len < 4) return .decode_error;
            const scheme = readU16(cvb[0..2]);
            if (scheme != SigScheme.ecdsa_secp256r1_sha256) return .signature_failed;
            const sig_len: usize = readU16(cvb[2..4]);
            if (4 + sig_len > cvb.len) return .decode_error;
            const sig_der = cvb[4..][0..sig_len];

            // Reconstruct the signed content (RFC 8446 §4.4.3), server context.
            var sign_content: [130]u8 = undefined;
            @memset(sign_content[0..64], 0x20);
            const label = "TLS 1.3, server CertificateVerify";
            @memcpy(sign_content[64..][0..label.len], label);
            sign_content[64 + label.len] = 0x00;
            @memcpy(sign_content[64 + label.len + 1 ..][0..HASH_LEN], &cv_transcript_hash);
            const sign_len: usize = 64 + label.len + 1 + HASH_LEN;

            // Loopback trust: verify the signature against the P256 public key
            // carried in the server's own certificate (no CA/PKI).
            const EcdsaP256 = crypto.sign.ecdsa.EcdsaP256Sha256;
            const pub_key = extractP256PublicKey(self.peer_cert_der[0..self.peer_cert_der_len]) orelse
                return .decode_error;
            const signature = EcdsaP256.Signature.fromDer(sig_der) catch return .signature_failed;
            signature.verify(sign_content[0..sign_len], pub_key) catch return .signature_failed;
        }
        self.transcript.update(data[pos .. pos + 4 + cv_len]);
        pos += 4 + cv_len;

        // ── server Finished ──
        // verify_data = HMAC(finished_key, transcript_hash up to CV).
        const fin_transcript_hash = self.transcript.peek();
        if (pos + 4 > data.len) return .decode_error;
        if (data[pos] != HsMsgType.finished) return .decode_error;
        const fin_len: usize = readU24(data[pos + 1 ..][0..3]);
        if (fin_len != HASH_LEN) return .decode_error;
        if (pos + 4 + fin_len > data.len) return .decode_error;
        {
            var finished_key: [HASH_LEN]u8 = undefined;
            hkdfExpandLabel(&self.server_hs_secret, "finished", "", &finished_key);
            var expected: [HASH_LEN]u8 = undefined;
            Hmac.create(&expected, &fin_transcript_hash, &finished_key);
            const received = data[pos + 4 ..][0..HASH_LEN];
            if (!constTimeEql(&expected, received)) return .verify_failed;
        }
        self.transcript.update(data[pos .. pos + 4 + fin_len]);
        pos += 4 + fin_len;

        // Application secrets are derived from the transcript through the
        // server Finished (RFC 8446 §7.1).
        self.deriveApplicationSecrets();

        // Build the client Finished (using the client handshake traffic secret)
        // over the transcript including the server Finished.
        self.output_len = 0;
        var out_pos: u16 = 0;
        const cf_err = self.buildClientFinished(&out_pos);
        if (cf_err != .none) return cf_err;
        self.output_len = out_pos;

        // Transcript now also covers the client Finished (not strictly required
        // for M1–M3, but keeps the hasher consistent for any later use).
        self.transcript.update(self.output_buf[0..out_pos]);

        self.state = .connected;
        return .none;
    }

    /// Build the client Finished message into output_buf[0..] starting at pos.
    fn buildClientFinished(self: *Tls13Engine, pos: *u16) HandshakeError {
        const buf = &self.output_buf;
        var p: usize = pos.*;

        const transcript_hash = self.transcript.peek();

        var finished_key: [HASH_LEN]u8 = undefined;
        hkdfExpandLabel(&self.client_hs_secret, "finished", "", &finished_key);

        var verify_data: [HASH_LEN]u8 = undefined;
        Hmac.create(&verify_data, &transcript_hash, &finished_key);

        const hdr_start = p;
        p += 4;
        if (p + HASH_LEN > buf.len) return .buffer_overflow;
        @memcpy(buf[p..][0..HASH_LEN], &verify_data);
        p += HASH_LEN;

        buf[hdr_start] = HsMsgType.finished;
        writeU24(buf[hdr_start + 1 ..][0..3], @intCast(p - hdr_start - 4));

        pos.* = @intCast(p);
        return .none;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Key Derivation (RFC 8446 §7.1)
    // ══════════════════════════════════════════════════════════════════════

    fn deriveHandshakeSecrets(self: *Tls13Engine) void {
        // Early Secret = HKDF-Extract(salt=0^HashLen, IKM=0^HashLen)  (no PSK)
        // HKDF-Extract(salt, IKM) = HMAC-SHA256(key=salt, data=IKM)
        const zero_ikm: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0));
        const zero_salt: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0));
        Hmac.create(&self.early_secret, &zero_ikm, &zero_salt);

        var derived_secret: [HASH_LEN]u8 = undefined;
        var empty_hash: [HASH_LEN]u8 = undefined;
        Sha256.hash("", &empty_hash, .{});
        hkdfExpandLabel(&self.early_secret, "derived", &empty_hash, &derived_secret);

        Hmac.create(&self.handshake_secret, &self.shared_secret, &derived_secret);

        // Use peek() to get transcript hash WITHOUT destroying the hasher state.
        // finalResult() is destructive — it would corrupt subsequent transcript updates.
        const hs_transcript = self.transcript.peek();

        hkdfExpandLabel(&self.handshake_secret, "c hs traffic", &hs_transcript, &self.client_hs_secret);
        hkdfExpandLabel(&self.handshake_secret, "s hs traffic", &hs_transcript, &self.server_hs_secret);

        self.client_handshake_keys = deriveQuicKeysFromSecret(&self.client_hs_secret);
        self.server_handshake_keys = deriveQuicKeysFromSecret(&self.server_hs_secret);
    }

    fn deriveApplicationSecrets(self: *Tls13Engine) void {
        var derived_secret: [HASH_LEN]u8 = undefined;
        var empty_hash: [HASH_LEN]u8 = undefined;
        Sha256.hash("", &empty_hash, .{});
        hkdfExpandLabel(&self.handshake_secret, "derived", &empty_hash, &derived_secret);

        const zero_ikm: [HASH_LEN]u8 = @as([HASH_LEN]u8, @splat(0));
        Hmac.create(&self.master_secret, &zero_ikm, &derived_secret);

        // Use peek() to get transcript hash WITHOUT destroying the hasher state.
        // finalResult() is destructive — it would corrupt subsequent transcript updates.
        const app_transcript = self.transcript.peek();

        hkdfExpandLabel(&self.master_secret, "c ap traffic", &app_transcript, &self.client_app_secret);
        hkdfExpandLabel(&self.master_secret, "s ap traffic", &app_transcript, &self.server_app_secret);

        self.client_app_keys = deriveQuicKeysFromSecret(&self.client_app_secret);
        self.server_app_keys = deriveQuicKeysFromSecret(&self.server_app_secret);
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// HKDF Utilities
// ══════════════════════════════════════════════════════════════════════════════

fn hkdfExpandLabel(secret: []const u8, label: []const u8, context: []const u8, out: []u8) void {
    const prefix = "tls13 ";
    var info: [2 + 1 + 6 + 255 + 1 + 255]u8 = undefined;
    var pos: usize = 0;

    const out_len: u16 = @intCast(out.len);
    info[pos] = @intCast(out_len >> 8);
    pos += 1;
    info[pos] = @intCast(out_len & 0xff);
    pos += 1;

    const full_label_len: u8 = @intCast(prefix.len + label.len);
    info[pos] = full_label_len;
    pos += 1;
    @memcpy(info[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(info[pos..][0..label.len], label);
    pos += label.len;

    info[pos] = @intCast(context.len);
    pos += 1;
    if (context.len > 0) {
        @memcpy(info[pos..][0..context.len], context);
        pos += context.len;
    }

    const Hkdf = crypto.kdf.hkdf.HkdfSha256;
    Hkdf.expand(out, info[0..pos], secret[0..HASH_LEN].*);
}

fn deriveQuicKeysFromSecret(secret: []const u8) QuicKeys {
    var keys = QuicKeys{};
    hkdfExpandLabel(secret, "quic key", "", &keys.key);
    hkdfExpandLabel(secret, "quic iv", "", &keys.iv);
    hkdfExpandLabel(secret, "quic hp", "", &keys.hp_key);
    keys.valid = true;
    return keys;
}

// ══════════════════════════════════════════════════════════════════════════════
// Wire Format Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn readU16(b: *const [2]u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

fn readU24(b: *const [3]u8) u24 {
    return (@as(u24, b[0]) << 16) | (@as(u24, b[1]) << 8) | b[2];
}

fn writeU16(b: *[2]u8, v: u16) void {
    b[0] = @intCast(v >> 8);
    b[1] = @intCast(v & 0xff);
}

fn writeU24(b: *[3]u8, v: u24) void {
    b[0] = @intCast(v >> 16);
    b[1] = @intCast((v >> 8) & 0xff);
    b[2] = @intCast(v & 0xff);
}

/// Extract an ECDSA P-256 public key from a certificate's DER bytes.
///
/// Loopback trust (Decision 3): this is NOT full X.509 parsing. A P-256
/// SubjectPublicKeyInfo embeds the public point as an uncompressed SEC1 octet
/// string: 0x04 || X(32) || Y(32). We scan the DER for the first 65-byte run
/// starting with 0x04 that decodes to a valid P-256 point via Sec1 import.
/// This also accepts a bare 65-byte SEC1 point as the "certificate" (the
/// loopback test may load the raw point as its cert DER).
fn extractP256PublicKey(der: []const u8) ?crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey {
    const PubKey = crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey;
    if (der.len < 65) return null;
    var i: usize = 0;
    while (i + 65 <= der.len) : (i += 1) {
        if (der[i] != 0x04) continue;
        const point = der[i..][0..65];
        if (PubKey.fromSec1(point)) |pk| {
            return pk;
        } else |_| {}
    }
    return null;
}

fn constTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests — in-process client ↔ server handshake (no sockets, no QUIC framing).
// Validates Decision 2/3: the client state machine drives a real ServerHello /
// EE / Cert / CertVerify / Finished flight and both engines derive identical
// application secrets.
// ══════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Build a loopback test certificate: a 32-byte ECDSA P-256 private scalar and
/// its SEC1 public point (65 bytes), used as the "certificate DER". Returns the
/// private scalar; writes the SEC1 point into `cert_out`.
fn makeTestCert(cert_out: *[65]u8) [32]u8 {
    const EcdsaP256 = crypto.sign.ecdsa.EcdsaP256Sha256;
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(0x31 + i);
    const kp = EcdsaP256.KeyPair.generateDeterministic(seed) catch unreachable;
    const scalar = kp.secret_key.toBytes();
    cert_out.* = kp.public_key.toUncompressedSec1();
    return scalar;
}

test "tls13 client+server: full in-process handshake derives matching app keys" {
    var server = Tls13Engine.initServer();
    var client = Tls13Engine.initClient();

    server.setAlpn("zpm");
    client.setAlpn("zpm");

    // Minimal (opaque) transport params on both sides.
    const sp = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const cp = [_]u8{ 0x05, 0x06, 0x07, 0x08 };
    server.setTransportParams(&sp);
    client.setTransportParams(&cp);

    // Server loads a test certificate (SEC1 point) + private scalar.
    var cert: [65]u8 = undefined;
    const scalar = makeTestCert(&cert);
    try testing.expectEqual(HandshakeError.none, server.loadCertificate(&cert, &scalar));

    // 1. Client builds ClientHello.
    try testing.expectEqual(HandshakeError.none, client.buildClientHello());
    var ch: [8192]u8 = undefined;
    const ch_len = client.output_len;
    @memcpy(ch[0..ch_len], client.output_buf[0..ch_len]);

    // 2. Server processes ClientHello → produces ServerHello (Initial) + flight.
    const sr = server.processMessage(ch[0..ch_len]);
    try testing.expectEqual(HandshakeError.none, sr.err);
    try testing.expect(sr.server_hello_len > 0);
    try testing.expect(sr.output_len > sr.server_hello_len);

    const sh_len = sr.server_hello_len;
    const flight_len = sr.output_len - sr.server_hello_len;
    var sh: [8192]u8 = undefined;
    var flight: [8192]u8 = undefined;
    @memcpy(sh[0..sh_len], server.output_buf[0..sh_len]);
    @memcpy(flight[0..flight_len], server.output_buf[sh_len..sr.output_len]);

    // 3. Client processes ServerHello.
    const cr1 = client.processMessage(sh[0..sh_len]);
    try testing.expectEqual(HandshakeError.none, cr1.err);
    try testing.expect(cr1.handshake_keys_available);
    try testing.expectEqual(HandshakeState.wait_server_finished, client.state);

    // 4. Client processes the EE+Cert+CV+Finished flight → emits client Finished.
    const cr2 = client.processMessage(flight[0..flight_len]);
    try testing.expectEqual(HandshakeError.none, cr2.err);
    try testing.expect(cr2.complete);
    try testing.expect(cr2.output_len > 0);
    try testing.expectEqual(HandshakeState.connected, client.state);
    // Peer transport params surfaced from EncryptedExtensions.
    try testing.expectEqual(@as(u16, sp.len), cr2.peer_transport_params_len);
    try testing.expectEqualSlices(u8, &sp, cr2.peer_transport_params[0..sp.len]);

    var cf: [8192]u8 = undefined;
    const cf_len = cr2.output_len;
    @memcpy(cf[0..cf_len], client.output_buf[0..cf_len]);

    // 5. Server processes the client Finished → complete.
    const sr2 = server.processMessage(cf[0..cf_len]);
    try testing.expectEqual(HandshakeError.none, sr2.err);
    try testing.expect(sr2.complete);
    try testing.expectEqual(HandshakeState.connected, server.state);

    // Both engines must agree on all application + handshake secrets/keys.
    try testing.expect(client.client_app_keys.valid and client.server_app_keys.valid);
    try testing.expect(server.client_app_keys.valid and server.server_app_keys.valid);
    try testing.expectEqualSlices(u8, &server.client_app_secret, &client.client_app_secret);
    try testing.expectEqualSlices(u8, &server.server_app_secret, &client.server_app_secret);
    try testing.expectEqualSlices(u8, &server.client_app_keys.key, &client.client_app_keys.key);
    try testing.expectEqualSlices(u8, &server.server_app_keys.key, &client.server_app_keys.key);
    try testing.expectEqualSlices(u8, &server.client_app_keys.iv, &client.client_app_keys.iv);
    try testing.expectEqualSlices(u8, &server.server_app_keys.iv, &client.server_app_keys.iv);
}

test "tls13 client: tampered server Finished fails verify" {
    var server = Tls13Engine.initServer();
    var client = Tls13Engine.initClient();
    server.setAlpn("zpm");
    client.setAlpn("zpm");
    var cert: [65]u8 = undefined;
    const scalar = makeTestCert(&cert);
    _ = server.loadCertificate(&cert, &scalar);

    _ = client.buildClientHello();
    var ch: [8192]u8 = undefined;
    const ch_len = client.output_len;
    @memcpy(ch[0..ch_len], client.output_buf[0..ch_len]);

    const sr = server.processMessage(ch[0..ch_len]);
    const sh_len = sr.server_hello_len;
    const flight_len = sr.output_len - sr.server_hello_len;
    var sh: [8192]u8 = undefined;
    var flight: [8192]u8 = undefined;
    @memcpy(sh[0..sh_len], server.output_buf[0..sh_len]);
    @memcpy(flight[0..flight_len], server.output_buf[sh_len..sr.output_len]);

    _ = client.processMessage(sh[0..sh_len]);

    // Flip the last byte of the server Finished verify_data.
    flight[flight_len - 1] ^= 0xFF;
    const cr2 = client.processMessage(flight[0..flight_len]);
    try testing.expectEqual(HandshakeError.verify_failed, cr2.err);
    try testing.expectEqual(HandshakeState.failed, client.state);
}
