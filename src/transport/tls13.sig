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
    wait_client_hello,
    wait_client_finished,
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
    /// Whether the handshake is now complete.
    complete: bool = false,
    /// Error, if any.
    err: HandshakeError = .none,
    /// Negotiated ALPN protocol.
    alpn: [32]u8 = [_]u8{0} ** 32,
    alpn_len: u8 = 0,
    /// Derived key material for QUIC packet protection.
    handshake_keys_available: bool = false,
    application_keys_available: bool = false,
};

/// QUIC encryption keys derived during handshake.
pub const QuicKeys = struct {
    key: [AES_KEY_LEN]u8 = [_]u8{0} ** AES_KEY_LEN,
    iv: [IV_LEN]u8 = [_]u8{0} ** IV_LEN,
    hp_key: [AES_KEY_LEN]u8 = [_]u8{0} ** AES_KEY_LEN,
    valid: bool = false,
};

/// Complete TLS 1.3 handshake engine for QUIC server role.
/// Fixed-size, zero-alloc. All buffers are embedded.
pub const Tls13Engine = struct {
    state: HandshakeState = .idle,
    is_server: bool = true,

    // ── Key Exchange ──
    eph_private: [X25519_KEY_LEN]u8 = [_]u8{0} ** X25519_KEY_LEN,
    eph_public: [X25519_KEY_LEN]u8 = [_]u8{0} ** X25519_KEY_LEN,
    shared_secret: [X25519_KEY_LEN]u8 = [_]u8{0} ** X25519_KEY_LEN,

    // ── Transcript Hash ──
    transcript: Sha256 = Sha256.init(.{}),

    // ── Derived Secrets ──
    early_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    handshake_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    client_hs_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    server_hs_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    master_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    client_app_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    server_app_secret: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,

    // ── Derived QUIC Keys ──
    client_handshake_keys: QuicKeys = .{},
    server_handshake_keys: QuicKeys = .{},
    client_app_keys: QuicKeys = .{},
    server_app_keys: QuicKeys = .{},

    // ── Certificate (PEM-decoded DER) ──
    cert_der: [4096]u8 = [_]u8{0} ** 4096,
    cert_der_len: u16 = 0,
    private_key: [32]u8 = [_]u8{0} ** 32,
    private_key_loaded: bool = false,

    // ── ALPN ──
    alpn_list: [64]u8 = [_]u8{0} ** 64,
    alpn_list_len: u8 = 0,

    // ── QUIC Transport Parameters (server's, pre-encoded) ──
    transport_params: [512]u8 = [_]u8{0} ** 512,
    transport_params_len: u16 = 0,

    // ── Client's key share (parsed from ClientHello) ──
    client_key_share: [X25519_KEY_LEN]u8 = [_]u8{0} ** X25519_KEY_LEN,
    client_key_share_valid: bool = false,

    // ── Output buffer (handshake messages to send as CRYPTO frames) ──
    output_buf: [8192]u8 = [_]u8{0} ** 8192,
    output_len: u16 = 0,

    // ── Client random ──
    client_random: [32]u8 = [_]u8{0} ** 32,

    // ══════════════════════════════════════════════════════════════════════
    // Public API
    // ══════════════════════════════════════════════════════════════════════

    /// Initialize as a QUIC server.
    pub fn initServer() Tls13Engine {
        var e = Tls13Engine{};
        e.state = .wait_client_hello;
        e.is_server = true;

        // Generate server ephemeral X25519 keypair
        const kp = X25519.KeyPair.generate();
        e.eph_private = kp.secret_key;
        e.eph_public = kp.public_key;

        return e;
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
        if (!self.private_key_loaded) return .cert_not_loaded;

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

        // 1. ServerHello
        const sh_err = self.writeServerHello(&out_pos);
        if (sh_err != .none) return sh_err;

        // Update transcript with ServerHello
        self.transcript.update(self.output_buf[0..out_pos]);

        // 2. Derive handshake secrets (RFC 8446 §7.1)
        self.deriveHandshakeSecrets();

        // 3. Encrypted flight (sent at Handshake encryption level)
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
        crypto.random.bytes(buf[p..][0..32]);
        p += 32;

        // legacy_session_id_echo (empty)
        if (p + 1 > buf.len) return .buffer_overflow;
        buf[p] = 0;
        p += 1;

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
        const sig_der = signature.toDer();
        const sig_len: u16 = sig_der.len;

        const hdr_start = p;
        p += 4;

        if (p + 2 + 2 + sig_len > buf.len) return .buffer_overflow;
        writeU16(buf[p..][0..2], SigScheme.ecdsa_secp256r1_sha256);
        p += 2;
        writeU16(buf[p..][0..2], sig_len);
        p += 2;
        @memcpy(buf[p..][0..sig_len], sig_der.data[0..sig_len]);
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

        const transcript_hash = self.transcript.finalResult();

        var expected: [HASH_LEN]u8 = undefined;
        Hmac.create(&expected, &transcript_hash, &finished_key);

        const received = data[4..][0..HASH_LEN];
        if (!constTimeEql(&expected, received)) return .verify_failed;

        self.transcript.update(data[0 .. 4 + HASH_LEN]);
        self.state = .connected;
        return .none;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Key Derivation (RFC 8446 §7.1)
    // ══════════════════════════════════════════════════════════════════════

    fn deriveHandshakeSecrets(self: *Tls13Engine) void {
        const zero_psk: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN;
        const zero_salt: [1]u8 = [_]u8{0};
        Hmac.create(&self.early_secret, &zero_psk, &zero_salt);

        var derived_secret: [HASH_LEN]u8 = undefined;
        const empty_hash = Sha256.hash(&.{}, .{});
        hkdfExpandLabel(&self.early_secret, "derived", &empty_hash, &derived_secret);

        Hmac.create(&self.handshake_secret, &self.shared_secret, &derived_secret);

        const hs_transcript = self.transcript.finalResult();

        hkdfExpandLabel(&self.handshake_secret, "c hs traffic", &hs_transcript, &self.client_hs_secret);
        hkdfExpandLabel(&self.handshake_secret, "s hs traffic", &hs_transcript, &self.server_hs_secret);

        self.client_handshake_keys = deriveQuicKeysFromSecret(&self.client_hs_secret);
        self.server_handshake_keys = deriveQuicKeysFromSecret(&self.server_hs_secret);
    }

    fn deriveApplicationSecrets(self: *Tls13Engine) void {
        var derived_secret: [HASH_LEN]u8 = undefined;
        const empty_hash = Sha256.hash(&.{}, .{});
        hkdfExpandLabel(&self.handshake_secret, "derived", &empty_hash, &derived_secret);

        const zero_ikm: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN;
        Hmac.create(&self.master_secret, &zero_ikm, &derived_secret);

        const app_transcript = self.transcript.finalResult();

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

fn constTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}
