// TLS 1.3 client (RFC 8446) over a std.Io.net.Stream — pure Sig, no allocator.
// Layer 1: net/crypto (entry of the tls_client directory module for wss://).
//
// Implements what a client needs to talk to exchanges and the public web:
//   • cipher suites TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384 and
//     TLS_CHACHA20_POLY1305_SHA256 (SHA-256 or SHA-384 key schedule),
//   • X25519 and secp256r1 (P-256) key exchange, TLS 1.3 only
//     (supported_versions), HelloRetryRequest,
//   • full handshake: ClientHello → ServerHello → {EncryptedExtensions,
//     Certificate, CertificateVerify, Finished} → client Finished, enforced
//     as a strict sequence (each exactly once, in that order),
//   • real certificate chain validation against the embedded CA bundle (or a
//     caller-supplied trust store), right after the Certificate message,
//   • CertificateVerify signature check over the handshake transcript (with
//     the validated leaf's key; RSA-PSS or ECDSA, never PKCS#1 v1.5),
//   • ALPN (advertises http/1.1, records the server's choice),
//   • application_data record encrypt/decrypt with the per-record nonce,
//   • KeyUpdate handling (both directions) and close_notify.
//
// The caller provides a byte transport implementing readSlice/writeAll/flush.
// We keep it transport-agnostic (a small vtable) so the same code runs over any
// stream the host offers; websocket.sig sits on top of the returned Conn.

const std = @import("std");
const sha256 = @import("sha256");
const hkdf = @import("hkdf");
const gcm = @import("gcm");
const x25519 = @import("x25519");
const p256 = @import("p256");
const keysched = @import("tls13_keys");
const keysched384 = @import("keysched384.sig");
const chacha = @import("chacha20poly1305");
const x509 = @import("x509.sig");
const verify = @import("x509_verify.sig");
// NOTE: ca_bundle.sig (the embedded Mozilla trust store plus ca_roots_web.sig,
// the broad web store) is not imported at the top level: only the functions
// that read it (defaultRootsLoad, bundleRootsFor) import it, in their bodies.

const Sha384 = std.crypto.hash.sha2.Sha384;

pub const Error = error{
    Io,
    HandshakeFailed,
    BadRecord,
    UnexpectedMessage,
    DecryptFailed,
    UnsupportedParams,
    CertInvalid,
    BufferTooSmall,
    Closed,
    /// No fresh entropy was installed with setEntropy() for this handshake.
    NoEntropy,
};

// ── Wire constants ──────────────────────────────────────────────────────
const REC_HANDSHAKE: u8 = 22;
const REC_APPDATA: u8 = 23;
const REC_ALERT: u8 = 21;
const REC_CHANGE_CIPHER_SPEC: u8 = 20;

const HS_CLIENT_HELLO: u8 = 1;
const HS_SERVER_HELLO: u8 = 2;
const HS_ENCRYPTED_EXTENSIONS: u8 = 8;
const HS_CERTIFICATE: u8 = 11;
const HS_CERT_VERIFY: u8 = 15;
const HS_FINISHED: u8 = 20;
const HS_KEY_UPDATE: u8 = 24;
const HS_MESSAGE_HASH: u8 = 254;

const TLS12: u16 = 0x0303;
const TLS13: u16 = 0x0304;
const TLS_AES_128_GCM_SHA256: u16 = 0x1301;
const TLS_AES_256_GCM_SHA384: u16 = 0x1302;
const TLS_CHACHA20_POLY1305_SHA256: u16 = 0x1303;
const GROUP_X25519: u16 = 0x001d;
const GROUP_SECP256R1: u16 = 0x0017;
// SHA-256("HelloRetryRequest") — a ServerHello carrying this random IS an HRR.
const HRR_RANDOM = [32]u8{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};

// Signature scheme code points (for CertificateVerify + sig_algs extension).
const SIG_RSA_PKCS1_SHA256: u16 = 0x0401;
const SIG_RSA_PKCS1_SHA384: u16 = 0x0501;
const SIG_RSA_PKCS1_SHA512: u16 = 0x0601;
const SIG_RSA_PSS_SHA256: u16 = 0x0804;
const SIG_RSA_PSS_SHA384: u16 = 0x0805;
const SIG_RSA_PSS_SHA512: u16 = 0x0806;
const SIG_ECDSA_SHA256: u16 = 0x0403;
const SIG_ECDSA_SHA384: u16 = 0x0503;

const MAX_RECORD: usize = 16384 + 256; // TLSPlaintext max + AEAD expansion
const MAX_CERTS: usize = verify.MAX_CHAIN;
// Largest handshake message accepted (in practice the Certificate message: a
// leaf plus intermediates, which may span several records).
const MAX_HS_MSG: usize = 24 * 1024;

/// Upper bound on trust-anchor certificates a roots provider may return into
/// the handshake-local buffer. Sized for the embedded Mozilla snapshot (137
/// roots) with headroom; mirrors the ca_bundle.MAX_ROOTS contract without
/// forcing ca_bundle.sig into every caller's module graph.
pub const MAX_ROOTS: usize = 145;

/// Roots the default (embedded bundle) path parses per handshake: only those
/// whose subject names the issuer or subject of a certificate in the server's
/// chain (ca_bundle.loadFor), so a handshake holds a few anchors, not the store.
const MAX_CHAIN_ANCHORS: usize = 16;

/// Injectable trust-root provider. The handshake calls this to populate a
/// caller-supplied, stack-resident buffer of parsed trust anchors, then
/// validates the server chain against roots[0..returned]. Allocator-free: the
/// provider writes into `out` and returns how many anchors it produced.
///
/// Leave it null (the default) and the handshake uses the embedded CA bundle
/// (the Mozilla snapshot plus the web store, ca_bundle.loadFor). Supply your
/// own (e.g. an embedded-system kernel shipping a lean root list, or a test
/// PKI) to validate against exactly those anchors.
pub const RootsFn = *const fn (out: []x509.Cert) usize;

/// Re-export so callers injecting their own roots can name the anchor type and
/// use parseRootsDer without importing x509.sig directly.
pub const Cert = x509.Cert;

/// Parse a caller-supplied list of DER-encoded root certificates into `out`,
/// skipping any that fail to parse. Returns the count written. This is the
/// allocator-free building block a roots provider uses: hold your anchors as
/// raw DER (`[]const []const u8`) and call this from a RootsFn. It touches only
/// x509 (the parser), never ca_bundle.sig.
pub fn parseRootsDer(ders: []const []const u8, out: []x509.Cert) usize {
    var n: usize = 0;
    for (ders) |der| {
        if (n >= out.len) break;
        out[n] = x509.parse(der) catch continue;
        n += 1;
    }
    return n;
}

/// Parse the embedded Mozilla CA bundle (ca_bundle.load) into `out`. A ready
/// RootsFn for callers that want every embedded Mozilla root as anchors.
pub fn defaultRootsLoad(out: []x509.Cert) usize {
    const ca_bundle = @import("ca_bundle.sig");
    return ca_bundle.load(out);
}

/// The embedded roots (Mozilla snapshot and web store) that could anchor
/// `chain`: the default trust store of handshake().
fn bundleRootsFor(chain: []const x509.Cert, out: []x509.Cert) usize {
    const ca_bundle = @import("ca_bundle.sig");
    return ca_bundle.loadFor(chain, out);
}

/// A byte transport the TLS layer reads/writes through. The host wires this to
/// its socket (std.Io.net.Stream, WinHTTP raw socket, a test buffer, ...).
pub const Transport = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buf: []u8) Error!usize,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) Error!void,

    fn readSome(self: *const Transport, buf: []u8) Error!usize {
        return self.readFn(self.ctx, buf);
    }
    fn readExact(self: *const Transport, buf: []u8) Error!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.readSome(buf[off..]);
            if (n == 0) return Error.Io;
            off += n;
        }
    }
    fn writeAll(self: *const Transport, data: []const u8) Error!void {
        return self.writeFn(self.ctx, data);
    }
};

/// Running transcript hash over all handshake messages. The suite (and so the
/// hash) is only known from the ServerHello, after the ClientHello is already
/// in the transcript, so both SHA-256 and SHA-384 run side by side. The key
/// schedule needs the hash of successive prefixes, so hash()/hash384()
/// finalise a copy of the running state and leave the transcript open.
const Transcript = struct {
    state: sha256.Sha256 = sha256.Sha256.init(),
    state384: Sha384 = Sha384.init(.{}),

    fn add(self: *Transcript, data: []const u8) void {
        self.state.update(data);
        self.state384.update(data);
    }
    fn hash(self: *const Transcript) [32]u8 {
        var copy = self.state;
        return copy.final();
    }
    fn hash384(self: *const Transcript) [48]u8 {
        var copy = self.state384;
        var out: [48]u8 = undefined;
        copy.final(&out);
        return out;
    }
};

/// AEAD algorithm negotiated for the session.
const Aead = enum { aes128_gcm, aes256_gcm, chacha20_poly1305 };
const HashId = enum { sha256, sha384 };

/// Cipher-suite descriptor. The server selects one of these in ServerHello.
const Suite = struct {
    id: u16,
    hash: HashId,
    aead: Aead,
    key_len: usize,
    hash_len: usize,
};

const SUITE_AES128: Suite = .{ .id = TLS_AES_128_GCM_SHA256, .hash = .sha256, .aead = .aes128_gcm, .key_len = 16, .hash_len = 32 };
const SUITE_AES256: Suite = .{ .id = TLS_AES_256_GCM_SHA384, .hash = .sha384, .aead = .aes256_gcm, .key_len = 32, .hash_len = 48 };
const SUITE_CHACHA: Suite = .{ .id = TLS_CHACHA20_POLY1305_SHA256, .hash = .sha256, .aead = .chacha20_poly1305, .key_len = 32, .hash_len = 32 };

fn suiteById(id: u16) ?Suite {
    if (id == SUITE_AES128.id) return SUITE_AES128;
    if (id == SUITE_AES256.id) return SUITE_AES256;
    if (id == SUITE_CHACHA.id) return SUITE_CHACHA;
    return null;
}

/// AEAD record protection state for one direction. Holds whichever AEAD the
/// negotiated suite selected; the per-record nonce construction is identical
/// across all three (RFC 8446 Section 5.3).
const RecordKeys = struct {
    aead: Aead = .aes128_gcm,
    gcm128: gcm.Gcm = undefined,
    gcm256: gcm.Gcm256 = undefined,
    chacha_key: [32]u8 = undefined,
    iv: [12]u8 = @splat(0),
    seq: u64 = 0,

    /// AES-128-GCM-SHA256: derive the 16-byte key + 12-byte iv via the
    /// SHA-256 schedule and build AES-128-GCM.
    fn init(secret: *const [32]u8) RecordKeys {
        var key: [16]u8 = undefined;
        var iv: [12]u8 = undefined;
        keysched.deriveTrafficKeys(secret, &key, &iv);
        const rk: RecordKeys = .{ .aead = .aes128_gcm, .gcm128 = gcm.Gcm.init(&key), .iv = iv };
        std.crypto.secureZero(u8, &key);
        return rk;
    }

    /// Build record keys for an arbitrary suite from its traffic secret.
    /// `secret` is hash_len bytes (32 for SHA-256 suites, 48 for SHA-384).
    fn initSuite(suite: Suite, secret: []const u8) RecordKeys {
        var rk = RecordKeys{ .aead = suite.aead };
        switch (suite.hash) {
            .sha256 => {
                const s32 = secret[0..32];
                switch (suite.aead) {
                    .aes128_gcm => {
                        var key: [16]u8 = undefined;
                        keysched.deriveTrafficKeys(s32, &key, &rk.iv);
                        rk.gcm128 = gcm.Gcm.init(&key);
                        std.crypto.secureZero(u8, &key);
                    },
                    .chacha20_poly1305 => {
                        _ = hkdf.expandLabel(s32, "key", "", &rk.chacha_key, 32);
                        _ = hkdf.expandLabel(s32, "iv", "", &rk.iv, 12);
                    },
                    .aes256_gcm => unreachable, // AES-256 pairs with SHA-384
                }
            },
            .sha384 => {
                var key: [32]u8 = undefined;
                keysched384.deriveTrafficKeys(secret[0..48], &key, &rk.iv);
                rk.gcm256 = gcm.Gcm256.init(&key);
                std.crypto.secureZero(u8, &key);
            },
        }
        return rk;
    }

    /// Per-record nonce (RFC 8446 §5.3): the 64-bit sequence number, big-endian,
    /// is left-padded to the IV length and XORed with the static IV. So the
    /// sequence occupies the LAST 8 bytes: its LSB lands at n[11].
    fn nonce(self: *const RecordKeys) [12]u8 {
        var n = self.iv;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const shift: u6 = @intCast(i * 8); // i=0 → LSB
            n[11 - i] ^= @truncate(self.seq >> shift);
        }
        return n;
    }

    /// Seal plaintext in place and write the tag (dispatch on AEAD).
    fn seal(self: *const RecordKeys, n: *const [12]u8, pt: []u8, aad: []const u8, tag: *[16]u8) void {
        switch (self.aead) {
            .aes128_gcm => self.gcm128.seal(n, pt, aad, tag),
            .aes256_gcm => self.gcm256.seal(n, pt, aad, tag),
            .chacha20_poly1305 => chacha.seal(&self.chacha_key, n, pt, aad, tag),
        }
    }

    /// Open ciphertext in place; returns false on auth failure (dispatch on AEAD).
    fn open(self: *const RecordKeys, n: *const [12]u8, ct: []u8, aad: []const u8, tag: *const [16]u8) bool {
        return switch (self.aead) {
            .aes128_gcm => self.gcm128.open(n, ct, aad, tag),
            .aes256_gcm => self.gcm256.open(n, ct, aad, tag),
            .chacha20_poly1305 => chacha.open(&self.chacha_key, n, ct, aad, tag),
        };
    }
};

/// secret_{N+1} = HKDF-Expand-Label(secret_N, "traffic upd", "", Hash.length)
/// (RFC 8446 §7.2), in place over the suite's hash_len bytes of `secret`.
fn nextTrafficSecret(suite: Suite, secret: *[48]u8) void {
    var next: [48]u8 = undefined;
    if (suite.hash == .sha384) {
        keysched384.expandLabel(secret, "traffic upd", "", next[0..48]);
    } else {
        _ = hkdf.expandLabel(secret[0..32], "traffic upd", "", next[0..32], 32);
    }
    @memcpy(secret[0..suite.hash_len], next[0..suite.hash_len]);
    std.crypto.secureZero(u8, &next);
}

/// An established TLS connection. After handshake, use read()/write() for
/// application data; they transparently AEAD-protect TLS records.
pub const Conn = struct {
    transport: Transport,
    client_app: RecordKeys,
    server_app: RecordKeys,
    suite: Suite = SUITE_AES128,
    // Current server application_traffic_secret_N. Retained so a post-handshake
    // server KeyUpdate can derive secret_{N+1} and rekey the receive direction
    // in place (RFC 8446 §7.2) — otherwise every record after a KeyUpdate would
    // fail to decrypt. 48 bytes wide; suite.hash_len of them are in use.
    server_app_secret: [48]u8 = undefined,
    // Current client_application_traffic_secret_N, for our own KeyUpdate.
    client_app_secret: [48]u8 = undefined,
    /// The server asked us to update our keys (KeyUpdate update_requested);
    /// RFC 8446 §4.6.3: we MUST send our KeyUpdate before more app data.
    key_update_owed: bool = false,
    /// Diagnostics: KeyUpdates received / sent.
    key_updates_received: u32 = 0,
    key_updates_sent: u32 = 0,
    // Negotiated ALPN protocol (empty if the server did not select one).
    alpn: [32]u8 = @splat(0),
    alpn_len: u8 = 0,
    // Leftover decrypted application bytes not yet consumed by the caller.
    inbuf: [MAX_RECORD]u8 = undefined,
    in_off: usize = 0,
    in_len: usize = 0,
    closed: bool = false,

    /// Decrypted application bytes waiting to be read (no I/O).
    pub fn buffered(self: *const Conn) usize {
        return self.in_len - self.in_off;
    }

    /// The ALPN protocol the server selected (e.g. "http/1.1"), or empty.
    pub fn negotiatedAlpn(self: *const Conn) []const u8 {
        return self.alpn[0..self.alpn_len];
    }

    /// Write application data as one or more TLS 1.3 app_data records.
    pub fn write(self: *Conn, data: []const u8) Error!void {
        if (self.key_update_owed) try self.sendKeyUpdate();
        var off: usize = 0;
        while (off < data.len) {
            const chunk = @min(data.len - off, 16384);
            try self.writeRecord(REC_APPDATA, data[off .. off + chunk]);
            off += chunk;
        }
    }

    /// Read some application data into `out`. Returns bytes read (>0), or
    /// error.Closed when the peer sent close_notify.
    pub fn read(self: *Conn, out: []u8) Error!usize {
        if (self.in_off < self.in_len) {
            const n = @min(out.len, self.in_len - self.in_off);
            @memcpy(out[0..n], self.inbuf[self.in_off .. self.in_off + n]);
            self.in_off += n;
            return n;
        }
        if (self.closed) return Error.Closed;
        // Pull and decrypt the next app_data record (skipping post-handshake
        // control records like KeyUpdate/NewSessionTicket).
        while (true) {
            const rec = try self.readAndDecrypt();
            switch (rec.content_type) {
                REC_APPDATA => {
                    self.in_len = rec.len;
                    self.in_off = 0;
                    const n = @min(out.len, rec.len);
                    @memcpy(out[0..n], self.inbuf[0..n]);
                    self.in_off = n;
                    return n;
                },
                REC_ALERT => {
                    self.closed = true;
                    return Error.Closed;
                },
                REC_HANDSHAKE => {
                    // Post-handshake messages. The plaintext handshake message
                    // sits in inbuf[0..rec.len]: [msg_type][3-byte len][body].
                    // A KeyUpdate (24) means the server rotated its send keys;
                    // we MUST rekey our receive direction or the next record
                    // fails to decrypt. NewSessionTicket (4) is ignored.
                    if (rec.len >= 5 and self.inbuf[0] == HS_KEY_UPDATE) {
                        // Rekey the receive direction so we can keep
                        // decrypting; if the server set update_requested
                        // (inbuf[4] == 1) we owe it our own KeyUpdate before
                        // the next application record we send.
                        self.rekeyServer();
                        self.key_updates_received += 1;
                        if (self.inbuf[4] == 1) self.key_update_owed = true;
                    }
                    continue;
                },
                else => continue,
            }
        }
    }

    /// Advance the server (receive) application traffic secret one generation
    /// per RFC 8446 §7.2 and re-derive the receive key/IV. Sequence resets to 0.
    fn rekeyServer(self: *Conn) void {
        nextTrafficSecret(self.suite, &self.server_app_secret);
        self.server_app = RecordKeys.initSuite(self.suite, self.server_app_secret[0..self.suite.hash_len]);
    }

    /// Send KeyUpdate(update_not_requested) under the current client keys,
    /// then move our send direction to the next traffic secret.
    fn sendKeyUpdate(self: *Conn) Error!void {
        const msg = [_]u8{ HS_KEY_UPDATE, 0, 0, 1, 0 };
        try self.writeRecord(REC_HANDSHAKE, &msg);
        nextTrafficSecret(self.suite, &self.client_app_secret);
        self.client_app = RecordKeys.initSuite(self.suite, self.client_app_secret[0..self.suite.hash_len]);
        self.key_update_owed = false;
        self.key_updates_sent += 1;
    }

    pub fn close(self: *Conn) void {
        if (self.closed) return;
        self.closed = true;
        // Best-effort close_notify alert (level=warning=1, desc=close_notify=0).
        const alert = [_]u8{ 1, 0 };
        self.writeRecord(REC_ALERT, &alert) catch {};
    }

    // ── record I/O (post-handshake, application keys) ──

    fn writeRecord(self: *Conn, content_type: u8, plaintext: []const u8) Error!void {
        // TLS 1.3 wraps: inner = plaintext || content_type; encrypt; the outer
        // record type is application_data(23). AAD = record header.
        var buf: [MAX_RECORD]u8 = undefined;
        const inner_len = plaintext.len + 1;
        if (inner_len + gcm.TAG_LEN > buf.len) return Error.BufferTooSmall;
        @memcpy(buf[0..plaintext.len], plaintext);
        buf[plaintext.len] = content_type;

        const total = inner_len + gcm.TAG_LEN;
        var hdr: [5]u8 = .{ REC_APPDATA, 0x03, 0x03, @intCast(total >> 8), @intCast(total & 0xFF) };

        const n = self.client_app.nonce();
        var tag: [16]u8 = undefined;
        self.client_app.seal(&n, buf[0..inner_len], &hdr, &tag);
        self.client_app.seq += 1;

        try self.transport.writeAll(&hdr);
        try self.transport.writeAll(buf[0..inner_len]);
        try self.transport.writeAll(&tag);
    }

    const DecRec = struct { content_type: u8, len: usize };

    /// Read one TLS record and decrypt it IN PLACE inside self.inbuf, then strip
    /// the inner content type. Reading the ciphertext body directly into inbuf
    /// (rather than a separate stack buffer that is then copied) removes a
    /// 16 KB stack frame and a full-record memcpy from every app record.
    fn readAndDecrypt(self: *Conn) Error!DecRec {
        var hdr: [5]u8 = undefined;
        try self.transport.readExact(&hdr);
        const rec_len = (@as(usize, hdr[3]) << 8) | hdr[4];
        if (rec_len == 0 or rec_len > MAX_RECORD) return Error.BadRecord;

        // Decrypt in place: read the full ciphertext record straight into inbuf.
        try self.transport.readExact(self.inbuf[0..rec_len]);

        if (hdr[0] == REC_CHANGE_CIPHER_SPEC) {
            // Ignore a stray CCS; recurse for the next real record.
            return self.readAndDecrypt();
        }
        if (rec_len < gcm.TAG_LEN) return Error.BadRecord;
        const body_len = rec_len - gcm.TAG_LEN;
        var tag: [16]u8 = undefined;
        @memcpy(&tag, self.inbuf[body_len..rec_len]);

        const n = self.server_app.nonce();
        if (!self.server_app.open(&n, self.inbuf[0..body_len], &hdr, &tag)) return Error.DecryptFailed;
        self.server_app.seq += 1;

        // Strip trailing zero padding, then the 1-byte inner content type. The
        // plaintext already lives in inbuf (decrypted in place), so there is no
        // further copy — read() serves the caller straight from inbuf.
        var end = body_len;
        while (end > 0 and self.inbuf[end - 1] == 0) end -= 1;
        if (end == 0) return Error.BadRecord;
        const inner_type = self.inbuf[end - 1];
        const data_len = end - 1;
        return .{ .content_type = inner_type, .len = data_len };
    }
};

/// Perform a full TLS 1.3 handshake over `transport` for `hostname`, validating
/// the server certificate chain against the embedded CA bundle at time `now`
/// (Unix seconds). On success returns an established Conn.
///
/// Consumes the entropy installed by setEntropy(): every handshake needs its
/// own fresh setEntropy() call, or it fails with error.NoEntropy.
pub fn handshake(transport: Transport, hostname: []const u8, now: i64) Error!Conn {
    return handshakeWithRoots(transport, hostname, now, null);
}

/// As `handshake`, but with an injectable trust-root provider. When `roots_fn`
/// is null the embedded CA bundle is used, so this is a strict superset of
/// `handshake` with identical default behavior. Pass a provider to validate
/// against exactly your own anchors. Consumes the entropy like handshake().
pub fn handshakeWithRoots(transport: Transport, hostname: []const u8, now: i64, roots_fn: ?RootsFn) Error!Conn {
    var hs = Handshaker{ .transport = transport, .hostname = hostname, .now = now, .roots_fn = roots_fn };
    if (!takeEntropy(&hs.entropy)) return Error.NoEntropy;
    defer hs.wipe();
    return hs.run();
}

// The handshake driver keeps all transient state (keys, transcript, buffers).
const Handshaker = struct {
    transport: Transport,
    hostname: []const u8,
    now: i64,
    /// Injected trust-root provider; null selects the embedded CA bundle.
    roots_fn: ?RootsFn = null,
    transcript: Transcript = .{},
    /// This handshake's private copy of the entropy pool (see takeEntropy).
    entropy: [64]u8 = [_]u8{0} ** 64,
    suite: Suite = SUITE_AES128,
    priv: [32]u8 = undefined, // X25519 private scalar
    priv_p256: [32]u8 = undefined, // P-256 private scalar
    // Key shares carried by the latest ClientHello: the server's key_share
    // must name one of these groups.
    sent_x25519: bool = false,
    sent_p256: bool = false,
    hrr_done: bool = false,
    retry_group: u16 = 0,
    neg_alpn: [32]u8 = @splat(0),
    neg_alpn_len: u8 = 0,
    // handshake-phase record keys
    hs_client: RecordKeys = undefined,
    hs_server: RecordKeys = undefined,
    ks: keysched.KeySchedule = undefined, // SHA-256 schedule
    ks384: keysched384.KeySchedule384 = undefined, // SHA-384 schedule
    // Handshake traffic secrets, 48 bytes wide; the active length is
    // self.suite.hash_len (32 for SHA-256 suites, 48 for SHA-384).
    client_hs_secret: [48]u8 = undefined,
    server_hs_secret: [48]u8 = undefined,
    // Handshake byte stream. Servers commonly coalesce EncryptedExtensions,
    // Certificate, CertificateVerify and Finished into ONE record (Google,
    // Cloudflare, api.anthropic.com), and a large Certificate may span several
    // records, so messages are cut from this stream instead of one per record.
    // Records are read and decrypted in place at hs_end; a returned message
    // stays valid until the next readEncryptedHandshake call.
    hsbuf: [MAX_HS_MSG + MAX_RECORD]u8 = undefined,
    hs_start: usize = 0,
    hs_end: usize = 0,
    // Stable storage for the Certificate message. The parsed x509.Cert values
    // hold slices INTO this buffer, so it must outlive the rest of the flight
    // (later records reuse hsbuf and would otherwise clobber the cert bytes
    // before verifyChain runs).
    certbuf: [MAX_HS_MSG]u8 = undefined,
    certlen: usize = 0,
    // The server's Certificate passed chain validation, and its
    // CertificateVerify then proved possession of the leaf's private key.
    // verifyServerFinished refuses to run unless both are set.
    chain_ok: bool = false,
    cv_ok: bool = false,

    /// Scrub the key-exchange secrets once the handshake is over (either way).
    fn wipe(self: *Handshaker) void {
        std.crypto.secureZero(u8, &self.entropy);
        std.crypto.secureZero(u8, &self.priv);
        std.crypto.secureZero(u8, &self.priv_p256);
        std.crypto.secureZero(u8, &self.client_hs_secret);
        std.crypto.secureZero(u8, &self.server_hs_secret);
        std.crypto.secureZero(u8, std.mem.asBytes(&self.ks));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.ks384));
    }

    fn run(self: *Handshaker) Error!Conn {
        try self.sendClientHello(0);
        if (try self.readServerHello()) {
            // HelloRetryRequest: readServerHello replaced ClientHello1 in the
            // transcript with message_hash(Hash(CH1)) and appended the HRR.
            // Send CH2 with a key_share only for the requested group.
            try self.sendClientHello(self.retry_group);
            if (try self.readServerHello()) return Error.HandshakeFailed; // a second HRR is illegal
        }
        // From here, handshake records are encrypted with handshake keys.
        try self.readEncryptedFlight();

        // Derive application traffic secrets over the transcript through the
        // server Finished (RFC 8446 §7.1). This MUST happen before we append
        // the client Finished to the transcript — the server keys its
        // application records over Hash(ClientHello…server Finished), so
        // including the client Finished here would desync every app record.
        var c_app: [48]u8 = undefined;
        var s_app: [48]u8 = undefined;
        defer std.crypto.secureZero(u8, &c_app);
        defer std.crypto.secureZero(u8, &s_app);
        self.deriveApp(&c_app, &s_app);

        // Client Finished is sent under the handshake keys; it folds itself into
        // the transcript but no longer affects the application secrets above.
        try self.sendClientFinished();

        const hl = self.suite.hash_len;
        var conn = Conn{
            .transport = self.transport,
            .suite = self.suite,
            .client_app = RecordKeys.initSuite(self.suite, c_app[0..hl]),
            .server_app = RecordKeys.initSuite(self.suite, s_app[0..hl]),
            .server_app_secret = s_app,
            .client_app_secret = c_app,
        };
        @memcpy(conn.alpn[0..self.neg_alpn_len], self.neg_alpn[0..self.neg_alpn_len]);
        conn.alpn_len = self.neg_alpn_len;
        return conn;
    }

    // ── suite-aware handshake helpers (dispatch on self.suite.hash) ──

    /// Transcript hash into `out` (48-byte buffer); returns the active length.
    fn thash(self: *const Handshaker, out: *[48]u8) usize {
        if (self.suite.hash == .sha384) {
            out.* = self.transcript.hash384();
            return 48;
        }
        out[0..32].* = self.transcript.hash();
        return 32;
    }

    /// Derive handshake traffic secrets from the ECDHE shared secret and build
    /// the handshake-phase RecordKeys for the negotiated suite.
    fn deriveHandshake(self: *Handshaker, shared: *const [32]u8) void {
        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            self.ks384 = keysched384.KeySchedule384.init();
            self.ks384.deriveHandshakeSecrets(shared, th[0..48], &self.client_hs_secret, &self.server_hs_secret);
        } else {
            self.ks = keysched.KeySchedule.init(null);
            self.ks.deriveHandshakeSecrets(shared, th[0..32], self.client_hs_secret[0..32], self.server_hs_secret[0..32]);
        }
        const hl = self.suite.hash_len;
        self.hs_client = RecordKeys.initSuite(self.suite, self.client_hs_secret[0..hl]);
        self.hs_server = RecordKeys.initSuite(self.suite, self.server_hs_secret[0..hl]);
    }

    /// Derive application traffic secrets into 48-byte buffers (the first
    /// suite.hash_len bytes are meaningful).
    fn deriveApp(self: *Handshaker, c_app: *[48]u8, s_app: *[48]u8) void {
        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            self.ks384.deriveApplicationSecrets(th[0..48], c_app, s_app);
        } else {
            self.ks.deriveApplicationSecrets(th[0..32], c_app[0..32], s_app[0..32]);
        }
    }

    /// Finished verify_data for the given base secret over the transcript so
    /// far; writes into `out`, returns the active length (32 or 48).
    fn finishedData(self: *const Handshaker, base: *const [48]u8, out: *[48]u8) usize {
        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            out.* = keysched384.KeySchedule384.computeFinished(base, th[0..48]);
            return 48;
        }
        out[0..32].* = keysched.KeySchedule.computeFinished(base[0..32], th[0..32]);
        return 32;
    }

    // ── ClientHello ──
    // only_group: 0 = offer both key shares (CH1); otherwise send a key_share
    // only for the requested group (CH2 after a HelloRetryRequest).
    fn sendClientHello(self: *Handshaker, only_group: u16) Error!void {
        // Ephemeral keys come from this handshake's entropy, once (CH1); CH2
        // reuses them and the same random (RFC 8446 §4.1.2).
        if (!self.hrr_done) {
            self.priv = clampScalar(self.entropy[0..32]);
            self.priv_p256 = p256Scalar(&self.entropy);
        }
        const pubkey = x25519.publicKey(&self.priv);
        var pubkey_p256: [65]u8 = undefined;
        const have_p256 = p256.ecdhKeypair(&self.priv_p256, &pubkey_p256);

        var body: [1024]u8 = undefined;
        var w = Writer{ .buf = &body };
        w.putU16(TLS12); // legacy_version
        w.bytes(self.entropy[32..64]); // 32-byte random
        w.putU8(0); // legacy_session_id length 0
        // cipher_suites
        w.putU16(6);
        w.putU16(TLS_AES_256_GCM_SHA384);
        w.putU16(TLS_CHACHA20_POLY1305_SHA256);
        w.putU16(TLS_AES_128_GCM_SHA256);
        // compression_methods
        w.putU8(1);
        w.putU8(0);
        // extensions
        var ext: [512]u8 = undefined;
        var ew = Writer{ .buf = &ext };
        writeSni(&ew, self.hostname);
        writeSupportedVersions(&ew);
        writeSupportedGroups(&ew);
        writeSigAlgs(&ew);
        writeAlpn(&ew);
        if (only_group == 0) {
            writeKeyShare(&ew, &pubkey, &pubkey_p256, have_p256);
            self.sent_x25519 = true;
            self.sent_p256 = have_p256;
        } else if (only_group == GROUP_X25519) {
            writeKeyShareOne(&ew, GROUP_X25519, &pubkey);
            self.sent_x25519 = true;
            self.sent_p256 = false;
        } else if (only_group == GROUP_SECP256R1 and have_p256) {
            writeKeyShareOne(&ew, GROUP_SECP256R1, &pubkey_p256);
            self.sent_x25519 = false;
            self.sent_p256 = true;
        } else {
            return Error.HandshakeFailed; // server asked for a group we cannot offer
        }
        w.putU16(@intCast(ew.len));
        w.bytes(ew.slice());

        try self.writeHandshake(HS_CLIENT_HELLO, w.slice());
    }

    /// After a HelloRetryRequest (RFC 8446 §4.4.1): the transcript becomes
    /// message_hash(Hash(ClientHello1)) || HelloRetryRequest, Hash being the
    /// hash of the suite the HRR selected. The transcript holds exactly CH1
    /// at this point (the HRR has not been added).
    fn restartTranscriptForHrr(self: *Handshaker, hrr_raw: []const u8) void {
        var ch1: [48]u8 = undefined;
        const hl = self.thash(&ch1);
        self.transcript = .{};
        const synth = [4]u8{ HS_MESSAGE_HASH, 0, 0, @intCast(hl) };
        self.transcript.add(&synth);
        self.transcript.add(ch1[0..hl]);
        self.transcript.add(hrr_raw);
        self.hrr_done = true;
    }

    // ── ServerHello (returns true if the message was a HelloRetryRequest) ──
    fn readServerHello(self: *Handshaker) Error!bool {
        const msg = try self.readPlainHandshake();
        if (msg.msg_type != HS_SERVER_HELLO) return Error.UnexpectedMessage;
        var r = Reader{ .buf = msg.body };
        _ = try r.getU16(); // legacy_version
        const random = try r.take(32);
        const is_hrr = eqBytes32(random, &HRR_RANDOM);
        const sid_len = try r.getU8();
        try r.skip(sid_len);
        const suite = suiteById(try r.getU16()) orelse return Error.UnsupportedParams;
        // After an HRR the ServerHello must keep the HRR's suite (§4.1.4).
        if (self.hrr_done and suite.id != self.suite.id) return Error.HandshakeFailed;
        self.suite = suite;
        _ = try r.getU8(); // compression
        const ext_len = try r.getU16();
        var ext = Reader{ .buf = try r.take(ext_len) };

        if (is_hrr) {
            // HRR: the key_share extension carries just the selected group.
            var found = false;
            while (ext.remaining() >= 4) {
                const etype = try ext.getU16();
                const elen = try ext.getU16();
                const edata = try ext.take(elen);
                if (etype == 51) {
                    var kr = Reader{ .buf = edata };
                    self.retry_group = try kr.getU16();
                    found = true;
                }
            }
            if (!found) return Error.HandshakeFailed;
            self.restartTranscriptForHrr(msg.raw);
            return true;
        }

        // Fold ServerHello into the transcript BEFORE deriving handshake secrets:
        // the handshake traffic secrets are keyed over Hash(ClientHello‖ServerHello),
        // so the client hash must include ServerHello or every encrypted record
        // (starting with EncryptedExtensions) fails to decrypt.
        self.transcript.add(msg.raw);
        // extensions: find key_share → server group + public key
        var server_pub: [65]u8 = undefined;
        var server_pub_len: usize = 0;
        var server_group: u16 = 0;
        var got_ks = false;
        while (ext.remaining() >= 4) {
            const etype = try ext.getU16();
            const elen = try ext.getU16();
            const edata = try ext.take(elen);
            if (etype == 51) { // key_share
                var kr = Reader{ .buf = edata };
                server_group = try kr.getU16();
                const klen = try kr.getU16();
                const kp = try kr.take(klen);
                if (kp.len <= server_pub.len) {
                    @memcpy(server_pub[0..kp.len], kp);
                    server_pub_len = kp.len;
                    got_ks = true;
                }
            }
        }
        if (!got_ks) return Error.HandshakeFailed;

        // ECDHE shared secret → handshake secrets over transcript(CH..SH).
        var shared: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &shared);
        if (server_group == GROUP_X25519) {
            if (!self.sent_x25519 or server_pub_len != 32) return Error.HandshakeFailed;
            shared = x25519.sharedSecret(&self.priv, server_pub[0..32]);
            // RFC 8446 §7.4.2: abort on the all-zero X25519 output (a
            // small-order server point).
            var acc: u8 = 0;
            for (shared) |b| acc |= b;
            if (acc == 0) return Error.HandshakeFailed;
        } else if (server_group == GROUP_SECP256R1) {
            if (!self.sent_p256 or server_pub_len != 65) return Error.HandshakeFailed;
            if (!p256.ecdhShared(&self.priv_p256, server_pub[0..65], &shared)) return Error.HandshakeFailed;
        } else {
            return Error.UnsupportedParams;
        }
        self.deriveHandshake(&shared);
        return false;
    }

    /// Parse EncryptedExtensions, extracting the server-selected ALPN protocol
    /// (extension type 16) if present. Tolerant: unknown extensions ignored, and
    /// an absent ALPN is not an error.
    fn parseEncryptedExtensions(self: *Handshaker, body: []const u8) void {
        var r = Reader{ .buf = body };
        const ext_len = r.getU16() catch return;
        var ext = Reader{ .buf = r.take(ext_len) catch return };
        while (ext.remaining() >= 4) {
            const etype = ext.getU16() catch return;
            const elen = ext.getU16() catch return;
            const edata = ext.take(elen) catch return;
            if (etype == 16) { // ALPN
                var ar = Reader{ .buf = edata };
                _ = ar.getU16() catch return; // ProtocolNameList length
                const plen = ar.getU8() catch return;
                const proto = ar.take(plen) catch return;
                const n = @min(proto.len, self.neg_alpn.len);
                @memcpy(self.neg_alpn[0..n], proto[0..n]);
                self.neg_alpn_len = @intCast(n);
            }
        }
    }

    // ── Encrypted flight: EE, Certificate, CertVerify, Finished ──
    //
    // A strict sequence, not a loop over whatever arrives: each message must
    // come exactly once, in this order (RFC 8446 §2, no PSK, no
    // CertificateRequest). Anything else — a missing CertificateVerify, a
    // second Certificate, CertificateVerify before Certificate — is
    // UnexpectedMessage. The chain is validated as soon as Certificate
    // arrives, before CertificateVerify is checked against its leaf key, and
    // the server Finished is only accepted once both succeeded. Otherwise a
    // MITM could present a real site's chain without its private key.
    const FlightState = enum { encrypted_extensions, certificate, certificate_verify, finished };

    fn readEncryptedFlight(self: *Handshaker) Error!void {
        var chain_buf: [MAX_CERTS]x509.Cert = undefined;
        var chain_len: usize = 0;
        var state: FlightState = .encrypted_extensions;

        while (true) {
            const msg = try self.readEncryptedHandshake();
            switch (state) {
                .encrypted_extensions => {
                    if (msg.msg_type != HS_ENCRYPTED_EXTENSIONS) return Error.UnexpectedMessage;
                    self.parseEncryptedExtensions(msg.body);
                    self.transcript.add(msg.raw);
                    state = .certificate;
                },
                .certificate => {
                    if (msg.msg_type != HS_CERTIFICATE) return Error.UnexpectedMessage;
                    // Copy the Certificate body into stable storage before
                    // parsing: the resulting x509.Cert values slice into it and
                    // must survive the CertVerify/Finished records that reuse
                    // the handshake stream buffer.
                    if (msg.body.len > self.certbuf.len) return Error.BufferTooSmall;
                    @memcpy(self.certbuf[0..msg.body.len], msg.body);
                    self.certlen = msg.body.len;
                    chain_len = try parseCertificateMsg(self.certbuf[0..self.certlen], &chain_buf);
                    try self.verifyServerChain(chain_buf[0..chain_len]);
                    self.transcript.add(msg.raw);
                    state = .certificate_verify;
                },
                .certificate_verify => {
                    if (msg.msg_type != HS_CERT_VERIFY) return Error.UnexpectedMessage;
                    // Signed over Hash(ClientHello .. Certificate), i.e. the
                    // transcript so far; verifyCertVerify folds CV in after.
                    var th: [48]u8 = undefined;
                    const hl = self.thash(&th);
                    try self.verifyCertVerify(msg, chain_buf[0..chain_len], th[0..hl]);
                    state = .finished;
                },
                .finished => {
                    if (msg.msg_type != HS_FINISHED) return Error.UnexpectedMessage;
                    try self.verifyServerFinished(msg);
                    // The client's next flight is under new keys: no server
                    // handshake bytes may trail the Finished (RFC 8446 §5.1).
                    if (self.hs_start != self.hs_end) return Error.UnexpectedMessage;
                    return;
                },
            }
        }
    }

    /// Validate the server's certificate chain against the trust store: the
    /// injected provider's anchors when there is one, otherwise the embedded
    /// roots that could anchor this chain.
    fn verifyServerChain(self: *Handshaker, chain: []const x509.Cert) Error!void {
        if (chain.len == 0) return Error.CertInvalid;
        if (self.roots_fn) |rf| {
            try verifyChainWithProvider(chain, rf, self.hostname, self.now);
        } else {
            try verifyChainWithBundle(chain, self.hostname, self.now);
        }
        self.chain_ok = true;
    }

    fn verifyCertVerify(self: *Handshaker, msg: HandshakeMsg, chain: []const x509.Cert, th: []const u8) Error!void {
        if (!self.chain_ok or chain.len == 0) return Error.CertInvalid;
        var r = Reader{ .buf = msg.body };
        const scheme = try r.getU16();
        const siglen = try r.getU16();
        const sig = try r.take(siglen);
        if (r.remaining() != 0) return Error.BadRecord;

        // The signed content is: 64 spaces || context string || 0x00 || transcript-hash.
        var signed: [64 + 33 + 1 + 48]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            signed[i] = 0x20;
        }
        const ctx = "TLS 1.3, server CertificateVerify";
        @memcpy(signed[64 .. 64 + ctx.len], ctx);
        signed[64 + ctx.len] = 0x00;
        @memcpy(signed[64 + ctx.len + 1 ..][0..th.len], th);
        const signed_len = 64 + ctx.len + 1 + th.len;

        const leaf = &chain[0];
        try verifyCertVerifySig(leaf, scheme, signed[0..signed_len], sig);
        // Now safe to fold CertVerify into the transcript.
        self.transcript.add(msg.raw);
        self.cv_ok = true;
    }

    fn verifyServerFinished(self: *Handshaker, msg: HandshakeMsg) Error!void {
        // Never accept a Finished from a server that has not authenticated:
        // its MAC only proves knowledge of the (attacker-chosen) ECDHE secret.
        if (!self.chain_ok or !self.cv_ok) return Error.CertInvalid;
        // verify_data = HMAC(finished_key, transcript-hash-up-to-but-not-including-Finished)
        var expected: [48]u8 = undefined;
        const vl = self.finishedData(&self.server_hs_secret, &expected);
        if (msg.body.len != vl) return Error.HandshakeFailed;
        var diff: u8 = 0;
        var i: usize = 0;
        while (i < vl) : (i += 1) diff |= expected[i] ^ msg.body[i];
        if (diff != 0) return Error.HandshakeFailed;
        // Fold server Finished into the transcript for client Finished + app keys.
        self.transcript.add(msg.raw);
    }

    fn sendClientFinished(self: *Handshaker) Error!void {
        var vd: [48]u8 = undefined;
        const vl = self.finishedData(&self.client_hs_secret, &vd);
        var body: [4 + 48]u8 = undefined;
        body[0] = HS_FINISHED;
        body[1] = 0;
        body[2] = 0;
        body[3] = @intCast(vl);
        @memcpy(body[4 .. 4 + vl], vd[0..vl]);
        // Client Finished is sent encrypted with client handshake keys.
        try self.writeEncrypted(REC_HANDSHAKE, body[0 .. 4 + vl]);
        self.transcript.add(body[0 .. 4 + vl]);
    }

    // ── record helpers ──

    const HandshakeMsg = struct {
        msg_type: u8,
        body: []const u8, // the message body (after the 4-byte header)
        raw: []const u8, // the full 4-byte-header + body
    };

    fn writeHandshake(self: *Handshaker, msg_type: u8, body: []const u8) Error!void {
        var hdr: [4]u8 = .{ msg_type, @intCast(body.len >> 16), @intCast((body.len >> 8) & 0xFF), @intCast(body.len & 0xFF) };
        // Add to transcript, then send as a plaintext handshake record.
        self.transcript.add(&hdr);
        self.transcript.add(body);
        var rec: [5]u8 = .{ REC_HANDSHAKE, 0x03, 0x01, @intCast((body.len + 4) >> 8), @intCast((body.len + 4) & 0xFF) };
        try self.transport.writeAll(&rec);
        try self.transport.writeAll(&hdr);
        try self.transport.writeAll(body);
    }

    fn writeEncrypted(self: *Handshaker, content_type: u8, plaintext: []const u8) Error!void {
        var buf: [MAX_RECORD]u8 = undefined;
        const inner_len = plaintext.len + 1;
        @memcpy(buf[0..plaintext.len], plaintext);
        buf[plaintext.len] = content_type;
        const total = inner_len + gcm.TAG_LEN;
        var hdr: [5]u8 = .{ REC_APPDATA, 0x03, 0x03, @intCast(total >> 8), @intCast(total & 0xFF) };
        const n = self.hs_client.nonce();
        var tag: [16]u8 = undefined;
        self.hs_client.seal(&n, buf[0..inner_len], &hdr, &tag);
        self.hs_client.seq += 1;
        try self.transport.writeAll(&hdr);
        try self.transport.writeAll(buf[0..inner_len]);
        try self.transport.writeAll(&tag);
    }

    /// Read a plaintext handshake record (ServerHello phase) and return the
    /// contained handshake message. Skips the middlebox-compatibility
    /// ChangeCipherSpec a server may send after a HelloRetryRequest.
    fn readPlainHandshake(self: *Handshaker) Error!HandshakeMsg {
        while (true) {
            var hdr: [5]u8 = undefined;
            try self.transport.readExact(&hdr);
            const len = (@as(usize, hdr[3]) << 8) | hdr[4];
            if (len == 0 or len > MAX_RECORD) return Error.BadRecord;
            try self.transport.readExact(self.hsbuf[0..len]);
            if (hdr[0] == REC_CHANGE_CIPHER_SPEC and self.hrr_done) continue;
            if (hdr[0] == REC_ALERT) return Error.HandshakeFailed;
            if (hdr[0] != REC_HANDSHAKE) return Error.UnexpectedMessage;
            return sliceHandshake(self.hsbuf[0..len]);
        }
    }

    /// Return the next encrypted handshake message (post-ServerHello), reading
    /// and decrypting records until one is complete. Skips the compatibility
    /// ChangeCipherSpec record; an alert ends the handshake.
    fn readEncryptedHandshake(self: *Handshaker) Error!HandshakeMsg {
        while (true) {
            const pending = self.hsbuf[self.hs_start..self.hs_end];
            if (pending.len >= 4) {
                const mlen = (@as(usize, pending[1]) << 16) | (@as(usize, pending[2]) << 8) | pending[3];
                if (mlen > MAX_HS_MSG) return Error.BufferTooSmall;
                if (pending.len >= 4 + mlen) {
                    self.hs_start += 4 + mlen;
                    return .{ .msg_type = pending[0], .body = pending[4 .. 4 + mlen], .raw = pending[0 .. 4 + mlen] };
                }
            }
            // Need another record: move the partial message to the front.
            if (self.hs_start > 0) {
                std.mem.copyForwards(u8, self.hsbuf[0..pending.len], pending);
                self.hs_start = 0;
                self.hs_end = pending.len;
            }
            var hdr: [5]u8 = undefined;
            try self.transport.readExact(&hdr);
            const len = (@as(usize, hdr[3]) << 8) | hdr[4];
            if (len == 0 or len > MAX_RECORD) return Error.BadRecord;
            if (self.hs_end + len > self.hsbuf.len) return Error.BufferTooSmall;
            const rec = self.hsbuf[self.hs_end..][0..len];
            try self.transport.readExact(rec);
            if (hdr[0] == REC_CHANGE_CIPHER_SPEC) continue;
            if (hdr[0] == REC_ALERT) return Error.HandshakeFailed;
            if (hdr[0] != REC_APPDATA or len < gcm.TAG_LEN) return Error.BadRecord;
            const body_len = len - gcm.TAG_LEN;
            var tag: [16]u8 = undefined;
            @memcpy(&tag, rec[body_len..len]);
            const nc = self.hs_server.nonce();
            if (!self.hs_server.open(&nc, rec[0..body_len], &hdr, &tag)) return Error.DecryptFailed;
            self.hs_server.seq += 1;
            var end = body_len;
            while (end > 0 and rec[end - 1] == 0) end -= 1; // strip padding
            if (end == 0) return Error.BadRecord;
            switch (rec[end - 1]) {
                REC_HANDSHAKE => self.hs_end += end - 1,
                REC_ALERT => return Error.HandshakeFailed,
                else => return Error.UnexpectedMessage,
            }
        }
    }
};

/// Chain validation against a caller-provided trust store. Separate (and not
/// inlined) so the MAX_ROOTS-entry anchor buffer lives only in this frame,
/// never on the default path's stack.
noinline fn verifyChainWithProvider(chain: []const x509.Cert, rf: RootsFn, hostname: []const u8, now: i64) Error!void {
    var roots: [MAX_ROOTS]x509.Cert = undefined;
    const nroots = @min(rf(&roots), roots.len);
    verify.verifyChain(chain, roots[0..nroots], hostname, now) catch return Error.CertInvalid;
}

/// Chain validation against the embedded CA bundle: only the roots that could
/// anchor `chain` are parsed, into a small buffer.
noinline fn verifyChainWithBundle(chain: []const x509.Cert, hostname: []const u8, now: i64) Error!void {
    var roots: [MAX_CHAIN_ANCHORS]x509.Cert = undefined;
    const nroots = bundleRootsFor(chain, &roots);
    verify.verifyChain(chain, roots[0..nroots], hostname, now) catch return Error.CertInvalid;
}

fn sliceHandshake(buf: []const u8) Error!Handshaker.HandshakeMsg {
    if (buf.len < 4) return Error.BadRecord;
    const mtype = buf[0];
    const mlen = (@as(usize, buf[1]) << 16) | (@as(usize, buf[2]) << 8) | buf[3];
    if (4 + mlen > buf.len) return Error.BadRecord;
    return .{ .msg_type = mtype, .body = buf[4 .. 4 + mlen], .raw = buf[0 .. 4 + mlen] };
}

/// Parse the TLS 1.3 Certificate message into a chain of x509.Cert.
fn parseCertificateMsg(body: []const u8, out: *[MAX_CERTS]x509.Cert) Error!usize {
    var r = Reader{ .buf = body };
    // certificate_request_context: always empty in a server Certificate.
    if (try r.getU8() != 0) return Error.UnexpectedMessage;
    const list_len = try r.getU24();
    var list = Reader{ .buf = try r.take(list_len) };
    var n: usize = 0;
    while (list.remaining() >= 3 and n < MAX_CERTS) {
        const cert_len = try list.getU24();
        const cert_der = try list.take(cert_len);
        out[n] = x509.parse(cert_der) catch return Error.CertInvalid;
        n += 1;
        const ext_len = try list.getU16(); // per-cert extensions
        try list.skip(ext_len);
    }
    return n;
}

/// Verify the CertificateVerify signature with the leaf's public key.
/// RSASSA-PKCS1-v1_5 schemes are refused: RFC 8446 §4.4.3 forbids them in
/// CertificateVerify (they remain offered only for certificate signatures).
fn verifyCertVerifySig(leaf: *const x509.Cert, scheme: u16, signed: []const u8, sig: []const u8) Error!void {
    const rsa = @import("rsa.sig");
    switch (scheme) {
        SIG_RSA_PSS_SHA256 => {
            if (leaf.key_alg != .rsa) return Error.CertInvalid;
            const pk = rsa.publicKey(leaf.rsa_modulus, leaf.rsa_exponent) catch return Error.CertInvalid;
            if (!rsa.verifyPssSha256(&pk, signed, sig)) return Error.CertInvalid;
        },
        SIG_ECDSA_SHA256 => {
            // TLS 1.3 binds the scheme to the curve: ecdsa_secp256r1_sha256.
            if (leaf.key_alg != .ecdsa_p256) return Error.UnsupportedParams;
            const digest = sha256.hash(signed);
            verify.verifyEcdsa(leaf, &digest, sig) catch return Error.CertInvalid;
        },
        SIG_ECDSA_SHA384 => {
            // ecdsa_secp384r1_sha384.
            if (leaf.key_alg != .ecdsa_p384) return Error.UnsupportedParams;
            const digest = @import("sha512.sig").sha384(signed);
            verify.verifyEcdsa(leaf, &digest, sig) catch return Error.CertInvalid;
        },
        else => return Error.UnsupportedParams,
    }
}

// ── ClientHello extension writers ──

fn eqBytes32(a: []const u8, b: *const [32]u8) bool {
    if (a.len != 32) return false;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn writeSni(w: *Writer, host: []const u8) void {
    w.putU16(0); // server_name
    const inner = 2 + 1 + 2 + host.len; // list_len + name_type + name_len + name
    w.putU16(@intCast(inner));
    w.putU16(@intCast(1 + 2 + host.len)); // server_name_list length
    w.putU8(0); // host_name
    w.putU16(@intCast(host.len));
    w.bytes(host);
}

fn writeSupportedVersions(w: *Writer) void {
    w.putU16(43); // supported_versions
    w.putU16(3); // ext len
    w.putU8(2); // list len
    w.putU16(TLS13);
}

fn writeSupportedGroups(w: *Writer) void {
    w.putU16(10); // supported_groups
    w.putU16(6); // ext len = 2 (list len) + 2*2 (two groups)
    w.putU16(4); // list len
    w.putU16(GROUP_X25519); // preferred
    w.putU16(GROUP_SECP256R1);
}

/// ALPN extension advertising http/1.1 (extensible: add h2 for HTTP/2 later).
fn writeAlpn(w: *Writer) void {
    const proto = "http/1.1";
    // ext: type(16) len(2) | list_len(2) | [ proto_len(1) proto ]
    w.putU16(16); // application_layer_protocol_negotiation
    w.putU16(@intCast(2 + 1 + proto.len)); // ext body len
    w.putU16(@intCast(1 + proto.len)); // ProtocolNameList length
    w.putU8(@intCast(proto.len));
    w.bytes(proto);
}

fn writeSigAlgs(w: *Writer) void {
    // Only schemes this client can verify. TLS 1.3 servers with RSA keys must
    // sign CertificateVerify with RSA-PSS (RFC 8446 §4.2.3), so PSS has to be
    // offered; the PKCS#1 entries cover the certificate-chain signatures.
    // (rsa_pss_rsae_sha384/512 are not offered: rsa.sig verifies PSS with
    // SHA-256 only, and a server that picked them would fail the handshake.)
    const algs = [_]u16{
        SIG_ECDSA_SHA256,     SIG_ECDSA_SHA384,     SIG_RSA_PSS_SHA256,
        SIG_RSA_PKCS1_SHA256, SIG_RSA_PKCS1_SHA384, SIG_RSA_PKCS1_SHA512,
    };
    w.putU16(13); // signature_algorithms
    w.putU16(@intCast(2 + algs.len * 2));
    w.putU16(@intCast(algs.len * 2));
    for (algs) |a| w.putU16(a);
}

/// Write a key_share extension with a single group entry (used for CH2 after HRR).
fn writeKeyShareOne(w: *Writer, group: u16, key: []const u8) void {
    w.putU16(51); // key_share
    const entry = 2 + 2 + key.len;
    w.putU16(@intCast(2 + entry));
    w.putU16(@intCast(entry));
    w.putU16(group);
    w.putU16(@intCast(key.len));
    w.bytes(key);
}

fn writeKeyShare(w: *Writer, x25519_pub: *const [32]u8, p256_pub: *const [65]u8, have_p256: bool) void {
    w.putU16(51); // key_share
    // Each KeyShareEntry: group(2) + len(2) + key. X25519=32, P-256=65.
    const x_entry = 2 + 2 + 32;
    const p_entry: usize = if (have_p256) 2 + 2 + 65 else 0;
    const list_len = x_entry + p_entry;
    w.putU16(@intCast(2 + list_len)); // ext len = client_shares len prefix + entries
    w.putU16(@intCast(list_len)); // client_shares length
    // X25519 entry (listed first = our preference)
    w.putU16(GROUP_X25519);
    w.putU16(32);
    w.bytes(x25519_pub);
    if (have_p256) {
        w.putU16(GROUP_SECP256R1);
        w.putU16(65);
        w.bytes(p256_pub);
    }
}

// ── tiny buffer Writer/Reader ──

const Writer = struct {
    buf: []u8,
    len: usize = 0,
    fn putU8(self: *Writer, v: u8) void {
        self.buf[self.len] = v;
        self.len += 1;
    }
    fn putU16(self: *Writer, v: u16) void {
        self.buf[self.len] = @intCast(v >> 8);
        self.buf[self.len + 1] = @intCast(v & 0xFF);
        self.len += 2;
    }
    fn bytes(self: *Writer, b: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + b.len], b);
        self.len += b.len;
    }
    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }
    fn getU8(self: *Reader) Error!u8 {
        if (self.pos >= self.buf.len) return Error.BadRecord;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }
    fn getU16(self: *Reader) Error!u16 {
        if (self.pos + 2 > self.buf.len) return Error.BadRecord;
        const v = (@as(u16, self.buf[self.pos]) << 8) | self.buf[self.pos + 1];
        self.pos += 2;
        return v;
    }
    fn getU24(self: *Reader) Error!usize {
        if (self.pos + 3 > self.buf.len) return Error.BadRecord;
        const v = (@as(usize, self.buf[self.pos]) << 16) | (@as(usize, self.buf[self.pos + 1]) << 8) | self.buf[self.pos + 2];
        self.pos += 3;
        return v;
    }
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return Error.BadRecord;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn skip(self: *Reader, n: usize) Error!void {
        if (self.pos + n > self.buf.len) return Error.BadRecord;
        self.pos += n;
    }
};

// ── entropy ──
// The X25519 client scalar (first 32 bytes) and ClientHello.random (last 32)
// come from this pool; the P-256 scalar is derived from it (p256Scalar).
// Hosts MUST seed it from a CSPRNG right before every handshake via
// setEntropy() (galaxy_net.freshTlsEntropy, the browser's getrandom,
// winsock.fillEntropy). There is no built-in fallback: a handshake takes the
// pool, wipes it, and fails with error.NoEntropy if nothing fresh was
// installed, so a missing seed can never reuse a key share.
var g_entropy: [64]u8 = [_]u8{0} ** 64;
var g_entropy_set: bool = false;

/// Install real entropy (32 bytes for the X25519 scalar, 32 for CH.random)
/// for the next handshake.
pub fn setEntropy(e: *const [64]u8) void {
    g_entropy = e.*;
    g_entropy_set = true;
}

/// Move the installed entropy into `out` and wipe the pool. False when no
/// setEntropy() happened since the last handshake.
fn takeEntropy(out: *[64]u8) bool {
    if (!g_entropy_set) return false;
    out.* = g_entropy;
    std.crypto.secureZero(u8, &g_entropy);
    g_entropy_set = false;
    return true;
}

fn clampScalar(e: *const [32]u8) [32]u8 {
    var s = e.*;
    // X25519 scalar clamping.
    s[0] &= 248;
    s[31] &= 127;
    s[31] |= 64;
    return s;
}

/// The P-256 key-share scalar, derived from the handshake entropy with a
/// domain-separated HKDF so it is independent of the X25519 scalar (which is
/// the first half of the same pool).
fn p256Scalar(entropy: *const [64]u8) [32]u8 {
    var prk = hkdf.extract("zpm tls13 p256 key share", entropy);
    defer std.crypto.secureZero(u8, &prk);
    var out: [32]u8 = undefined;
    _ = hkdf.expand(&prk, "secp256r1 scalar", &out, 32);
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "tls: record nonce XORs sequence number" {
    var rk = RecordKeys{ .aead = undefined, .iv = [_]u8{0} ** 12, .seq = 0 };
    rk.iv[11] = 0x00;
    rk.seq = 0x0102;
    const n = rk.nonce();
    // Low two bytes of the sequence XOR into the last two nonce bytes.
    try testing.expectEqual(@as(u8, 0x01), n[10]);
    try testing.expectEqual(@as(u8, 0x02), n[11]);
}

test "tls: ClientHello writer produces a plausible structure" {
    var body: [1024]u8 = undefined;
    var w = Writer{ .buf = &body };
    w.putU16(TLS12);
    try testing.expectEqual(@as(usize, 2), w.len);
    try testing.expectEqual(@as(u8, 0x03), body[0]);
    try testing.expectEqual(@as(u8, 0x03), body[1]);
}

test "tls: AES-128 RecordKeys init is behavior-preserving (pinned)" {
    // A fixed traffic secret must always derive the same key+iv via the
    // SHA-256 schedule + AES-128 path. Pins the regression invariant.
    const secret: [32]u8 = @splat(0x5a);
    const rk = RecordKeys.init(&secret);
    try testing.expect(rk.aead == .aes128_gcm);
    // nonce at seq 0 equals the raw iv (XOR with zero seq)
    const n0 = rk.nonce();
    try testing.expectEqualSlices(u8, &rk.iv, &n0);
    // initSuite(SUITE_AES128, secret) must produce the identical key material
    const rk2 = RecordKeys.initSuite(SUITE_AES128, &secret);
    try testing.expectEqualSlices(u8, &rk.iv, &rk2.iv);
    try testing.expect(rk2.aead == .aes128_gcm);
}

test "tls: suite table maps the three cipher ids" {
    try testing.expect(suiteById(0x1301).?.aead == .aes128_gcm);
    try testing.expect(suiteById(0x1302).?.aead == .aes256_gcm);
    try testing.expect(suiteById(0x1303).?.aead == .chacha20_poly1305);
    try testing.expect(suiteById(0x1301).?.hash == .sha256);
    try testing.expect(suiteById(0x1302).?.hash == .sha384);
    try testing.expect(suiteById(0x9999) == null);
}

test "tls: ChaCha20-Poly1305 RecordKeys round-trip" {
    // Suite 0x1303: SHA-256 schedule + ChaCha20-Poly1305 AEAD.
    const secret: [32]u8 = @splat(0x3c);
    var sbuf: [48]u8 = undefined;
    @memcpy(sbuf[0..32], &secret);
    const rk = RecordKeys.initSuite(SUITE_CHACHA, sbuf[0..32]);
    try testing.expect(rk.aead == .chacha20_poly1305);
    const n = rk.nonce();
    var pt = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const orig = pt;
    const aad = [_]u8{ 0x17, 0x03, 0x03, 0x00, 0x18 };
    var tag: [16]u8 = undefined;
    rk.seal(&n, &pt, &aad, &tag);
    try testing.expect(!std.mem.eql(u8, &orig, &pt));
    try testing.expect(rk.open(&n, &pt, &aad, &tag));
    try testing.expectEqualSlices(u8, &orig, &pt);
}

test "tls: AES-256-GCM-SHA384 RecordKeys round-trip" {
    const secret48: [48]u8 = @splat(0x25);
    const rk = RecordKeys.initSuite(SUITE_AES256, &secret48);
    try testing.expect(rk.aead == .aes256_gcm);
    const n = rk.nonce();
    var pt = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    const orig = pt;
    var tag: [16]u8 = undefined;
    rk.seal(&n, &pt, "", &tag);
    try testing.expect(rk.open(&n, &pt, "", &tag));
    try testing.expectEqualSlices(u8, &orig, &pt);
}

test "tls: HRR sentinel random is recognized" {
    try testing.expect(eqBytes32(&HRR_RANDOM, &HRR_RANDOM));
    var not_hrr: [32]u8 = @splat(0x11);
    try testing.expect(!eqBytes32(&not_hrr, &HRR_RANDOM));
    // length guard
    const short = [_]u8{ 1, 2, 3 };
    try testing.expect(!eqBytes32(&short, &HRR_RANDOM));
}

test "tls: ALPN extension advertises http/1.1" {
    var buf: [64]u8 = undefined;
    var w = Writer{ .buf = &buf };
    writeAlpn(&w);
    const out = w.slice();
    // ext type 16 (0x00 0x10), then body. Body = ext_len(2) list_len(2) plen(1) proto.
    try testing.expectEqual(@as(u8, 0x00), out[0]);
    try testing.expectEqual(@as(u8, 0x10), out[1]);
    // the protocol string http/1.1 appears verbatim at the end
    const proto = "http/1.1";
    try testing.expectEqualSlices(u8, proto, out[out.len - proto.len ..]);
    // proto length byte precedes it
    try testing.expectEqual(@as(u8, proto.len), out[out.len - proto.len - 1]);
}

test "tls: parseEncryptedExtensions reads server ALPN selection" {
    var hs: Handshaker = .{ .transport = undefined, .hostname = "x", .now = 0 };
    // EncryptedExtensions body: ext_list_len(2) | ALPN ext (type 16):
    //   type(2)=0x0010 len(2) | list_len(2) plen(1) "h2"
    var b: [32]u8 = undefined;
    var ww = Writer{ .buf = &b };
    ww.putU16(2 + 2 + (2 + 1 + 2)); // extensions length
    ww.putU16(16); // ALPN
    ww.putU16(2 + 1 + 2); // ext body len
    ww.putU16(1 + 2); // list len
    ww.putU8(2); // proto len
    ww.bytes("h2");
    hs.parseEncryptedExtensions(ww.slice());
    try testing.expectEqualSlices(u8, "h2", hs.neg_alpn[0..hs.neg_alpn_len]);
}

test "tls: the P-256 key-share scalar is independent of the X25519 one" {
    const e = [_]u8{0x42} ** 32 ++ [_]u8{0x24} ** 32;
    const k = p256Scalar(&e);
    try testing.expect(!std.mem.eql(u8, &k, e[0..32]));
    try testing.expect(!std.mem.eql(u8, &k, &clampScalar(e[0..32])));
    // Deterministic for the same pool.
    try testing.expectEqualSlices(u8, &k, &p256Scalar(&e));
}

// ── Scripted-server handshake tests ─────────────────────────────────────
// FakeServer is an in-memory Transport that plays one server flight. It does
// the real server-side key exchange (its own X25519 or P-256 key, the same
// key schedule for the chosen suite), so every record decrypts and every
// Finished MAC is valid: only the message sequence and the authentication
// differ between cases. That is exactly what a MITM who terminates the ECDHE
// controls.

const pki = @import("testvec_pki.sig");
const PKI_HOST = "tls.galaxy.test";
const PKI_NOW: i64 = 1790812800; // 2026-10-01, inside the test PKI's window

const Step = enum {
    ee,
    ee_alpn, // EncryptedExtensions selecting ALPN "http/1.1"
    cert, // `chain`
    cert_alt, // `alt_chain` (a second Certificate)
    cv, // valid ECDSA-P256-SHA256 signature by the test leaf key
    cv_bad_sig, // same, with a flipped signature byte
    cv_pkcs1, // valid-looking but with the forbidden rsa_pkcs1_sha256 scheme
    fin,
    trailing_hs, // a stray handshake message after Finished, same record
};

const FakeServer = struct {
    steps: []const Step,
    chain: []const []const u8 = &.{ &pki.leaf_der, &pki.inter_der },
    alt_chain: []const []const u8 = &.{ &pki.leaf_client_der, &pki.inter_der },
    /// Cipher suite and key-share group of the ServerHello.
    suite: Suite = SUITE_AES128,
    group: u16 = GROUP_X25519,
    /// Nonzero: answer the first ClientHello with a HelloRetryRequest for
    /// this group, and send the ServerHello and flight after the second.
    hrr_group: u16 = 0,
    client_pub: [32]u8,
    client_pub_p256: [65]u8 = undefined,
    stage: u8 = 0,
    out: [24 * 1024]u8 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,
    cin: [8 * 1024]u8 = undefined,
    cin_len: usize = 0,
    ch1_len: usize = 0,
    transcript: Transcript = .{},
    c_hs: [48]u8 = undefined,
    s_hs: [48]u8 = undefined,
    s_keys: RecordKeys = undefined,
    pending: [MAX_RECORD]u8 = undefined,
    pending_len: usize = 0,

    fn transport(self: *FakeServer) Transport {
        return .{ .ctx = self, .readFn = readFn, .writeFn = writeFn };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) Error!void {
        const self: *FakeServer = @ptrCast(@alignCast(ctx));
        if (self.cin_len + data.len > self.cin.len) return Error.BufferTooSmall;
        @memcpy(self.cin[self.cin_len..][0..data.len], data);
        self.cin_len += data.len;
    }

    fn readFn(ctx: *anyopaque, buf: []u8) Error!usize {
        const self: *FakeServer = @ptrCast(@alignCast(ctx));
        if (self.out_pos == self.out_len) {
            if (self.stage == 0) {
                self.stage = 1;
                try self.build();
            } else if (self.stage == 1 and self.hrr_group != 0) {
                self.stage = 2;
                try self.buildAfterHrr();
            }
        }
        const n = @min(buf.len, self.out_len - self.out_pos);
        @memcpy(buf[0..n], self.out[self.out_pos..][0..n]);
        self.out_pos += n;
        return n; // 0 at the end → the client sees Error.Io
    }

    fn emit(self: *FakeServer, bytes: []const u8) void {
        @memcpy(self.out[self.out_len..][0..bytes.len], bytes);
        self.out_len += bytes.len;
    }

    /// The server-side transcript hash for the suite; returns its length.
    fn thash(self: *const FakeServer, out: *[48]u8) usize {
        if (self.suite.hash == .sha384) {
            out.* = self.transcript.hash384();
            return 48;
        }
        out[0..32].* = self.transcript.hash();
        return 32;
    }

    fn finished(self: *const FakeServer, base: *const [48]u8, out: *[48]u8) usize {
        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            out.* = keysched384.KeySchedule384.computeFinished(base, th[0..48]);
            return 48;
        }
        out[0..32].* = keysched.KeySchedule.computeFinished(base[0..32], th[0..32]);
        return 32;
    }

    /// Append a handshake message [type][u24 len][body] to the pending
    /// plaintext record and the server transcript.
    fn hsMsg(self: *FakeServer, msg_type: u8, body: []const u8) void {
        const hdr = [4]u8{ msg_type, @intCast(body.len >> 16), @intCast((body.len >> 8) & 0xFF), @intCast(body.len & 0xFF) };
        @memcpy(self.pending[self.pending_len..][0..4], &hdr);
        @memcpy(self.pending[self.pending_len + 4 ..][0..body.len], body);
        self.pending_len += 4 + body.len;
        self.transcript.add(&hdr);
        self.transcript.add(body);
    }

    /// Seal the pending handshake bytes into one encrypted record.
    fn flush(self: *FakeServer) void {
        const inner_len = self.pending_len + 1;
        self.pending[self.pending_len] = REC_HANDSHAKE;
        const total = inner_len + gcm.TAG_LEN;
        const hdr = [5]u8{ REC_APPDATA, 0x03, 0x03, @intCast(total >> 8), @intCast(total & 0xFF) };
        const n = self.s_keys.nonce();
        var tag: [16]u8 = undefined;
        self.s_keys.seal(&n, self.pending[0..inner_len], &hdr, &tag);
        self.s_keys.seq += 1;
        self.emit(&hdr);
        self.emit(self.pending[0..inner_len]);
        self.emit(&tag);
        self.pending_len = 0;
    }

    /// Emit a plaintext ServerHello-shaped message (a real ServerHello, or a
    /// HelloRetryRequest when `hrr`) and return its raw handshake bytes.
    fn serverHello(self: *FakeServer, hrr: bool, key_share: []const u8, scratch: *[256]u8) []const u8 {
        var w = Writer{ .buf = scratch[4..] };
        w.putU16(TLS12);
        w.bytes(if (hrr) &HRR_RANDOM else &([_]u8{0xA5} ** 32)); // random
        w.putU8(0); // legacy_session_id_echo
        w.putU16(self.suite.id);
        w.putU8(0);
        w.putU16(@intCast(6 + 4 + key_share.len)); // extensions
        w.putU16(43); // supported_versions
        w.putU16(2);
        w.putU16(TLS13);
        w.putU16(51); // key_share
        w.putU16(@intCast(key_share.len));
        w.bytes(key_share);
        const blen = w.len;
        scratch[0..4].* = .{ HS_SERVER_HELLO, 0, @intCast(blen >> 8), @intCast(blen & 0xFF) };
        const raw = scratch[0 .. 4 + blen];
        const rec = [5]u8{ REC_HANDSHAKE, 0x03, 0x03, @intCast(raw.len >> 8), @intCast(raw.len & 0xFF) };
        self.emit(&rec);
        self.emit(raw);
        return raw;
    }

    fn certBody(chain: []const []const u8, out: []u8) []const u8 {
        var w = Writer{ .buf = out };
        w.putU8(0); // certificate_request_context
        var list_len: usize = 0;
        for (chain) |der| list_len += 3 + der.len + 2;
        w.putU8(@intCast(list_len >> 16));
        w.putU16(@intCast(list_len & 0xFFFF));
        for (chain) |der| {
            w.putU8(@intCast(der.len >> 16));
            w.putU16(@intCast(der.len & 0xFFFF));
            w.bytes(der);
            w.putU16(0); // no per-certificate extensions
        }
        return w.slice();
    }

    fn cvBody(self: *FakeServer, scheme: u16, corrupt: bool, out: []u8) []const u8 {
        var signed: [64 + 33 + 1 + 48]u8 = undefined;
        @memset(signed[0..64], 0x20);
        const ctx = "TLS 1.3, server CertificateVerify";
        @memcpy(signed[64..][0..ctx.len], ctx);
        signed[64 + ctx.len] = 0;
        var th: [48]u8 = undefined;
        const hl = self.thash(&th);
        @memcpy(signed[64 + ctx.len + 1 ..][0..hl], th[0..hl]);
        const digest = sha256.hash(signed[0 .. 64 + ctx.len + 1 + hl]);
        var raw: [64]u8 = undefined;
        if (!p256.sign(&pki.leaf_priv, &digest, &raw)) unreachable;
        if (corrupt) raw[40] ^= 0x01;
        // DER ECDSA-Sig-Value: SEQUENCE { INTEGER r, INTEGER s }.
        var der: [72]u8 = undefined;
        var dl: usize = 2;
        for ([_][]const u8{ raw[0..32], raw[32..64] }) |half| {
            var h = half;
            while (h.len > 1 and h[0] == 0) h = h[1..];
            const pad: usize = if (h[0] & 0x80 != 0) 1 else 0;
            der[dl] = 0x02;
            der[dl + 1] = @intCast(h.len + pad);
            if (pad == 1) der[dl + 2] = 0;
            @memcpy(der[dl + 2 + pad ..][0..h.len], h);
            dl += 2 + pad + h.len;
        }
        der[0] = 0x30;
        der[1] = @intCast(dl - 2);
        var w = Writer{ .buf = out };
        w.putU16(scheme);
        w.putU16(@intCast(dl));
        w.bytes(der[0..dl]);
        return w.slice();
    }

    fn build(self: *FakeServer) Error!void {
        // The client's ClientHello is the one plaintext record written so far.
        if (self.cin_len < 9 or self.cin[0] != REC_HANDSHAKE) return Error.UnexpectedMessage;
        self.ch1_len = self.cin_len;
        self.transcript.add(self.cin[5..self.cin_len]);
        if (self.hrr_group != 0) {
            const ks = [2]u8{ @intCast(self.hrr_group >> 8), @intCast(self.hrr_group & 0xFF) };
            var scratch: [256]u8 = undefined;
            const raw = self.serverHello(true, &ks, &scratch);
            // RFC 8446 §4.4.1: message_hash(Hash(CH1)) || HRR.
            var ch1: [48]u8 = undefined;
            const hl = self.thash(&ch1);
            self.transcript = .{};
            self.transcript.add(&[4]u8{ HS_MESSAGE_HASH, 0, 0, @intCast(hl) });
            self.transcript.add(ch1[0..hl]);
            self.transcript.add(raw);
            // Middlebox-compatibility ChangeCipherSpec right after the HRR.
            self.emit(&[_]u8{ REC_CHANGE_CIPHER_SPEC, 0x03, 0x03, 0, 1, 1 });
            return;
        }
        try self.flight(true);
    }

    fn buildAfterHrr(self: *FakeServer) Error!void {
        // ClientHello2 is the plaintext record after ClientHello1.
        const ch2 = self.cin[self.ch1_len..self.cin_len];
        if (ch2.len < 9 or ch2[0] != REC_HANDSHAKE) return Error.UnexpectedMessage;
        self.transcript.add(ch2[5..]);
        try self.flight(false);
    }

    /// ServerHello for `group`, the handshake keys, then the encrypted flight.
    fn flight(self: *FakeServer, ccs: bool) Error!void {
        var ks_buf: [4 + 65]u8 = undefined;
        var shared: [32]u8 = undefined;
        var key_len: usize = 0;
        if (self.group == GROUP_X25519) {
            const server_priv = clampScalar(&([_]u8{0x5a} ** 32));
            ks_buf[4..36].* = x25519.publicKey(&server_priv);
            key_len = 32;
            shared = x25519.sharedSecret(&server_priv, &self.client_pub);
        } else {
            const server_priv = [_]u8{0x5a} ** 32; // < n
            if (!p256.ecdhKeypair(&server_priv, ks_buf[4..69])) unreachable;
            key_len = 65;
            if (!p256.ecdhShared(&server_priv, &self.client_pub_p256, &shared)) return Error.HandshakeFailed;
        }
        ks_buf[0..4].* = .{ @intCast(self.group >> 8), @intCast(self.group & 0xFF), 0, @intCast(key_len) };
        var scratch: [256]u8 = undefined;
        const raw = self.serverHello(false, ks_buf[0 .. 4 + key_len], &scratch);
        self.transcript.add(raw);

        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            var ks = keysched384.KeySchedule384.init();
            ks.deriveHandshakeSecrets(&shared, th[0..48], &self.c_hs, &self.s_hs);
        } else {
            var ks = keysched.KeySchedule.init(null);
            ks.deriveHandshakeSecrets(&shared, th[0..32], self.c_hs[0..32], self.s_hs[0..32]);
        }
        self.s_keys = RecordKeys.initSuite(self.suite, self.s_hs[0..self.suite.hash_len]);

        // Middlebox-compatibility ChangeCipherSpec, as real servers send.
        if (ccs) self.emit(&[_]u8{ REC_CHANGE_CIPHER_SPEC, 0x03, 0x03, 0, 1, 1 });

        var body: [MAX_HS_MSG]u8 = undefined;
        for (self.steps) |step| {
            switch (step) {
                .ee => self.hsMsg(HS_ENCRYPTED_EXTENSIONS, &.{ 0, 0 }),
                .ee_alpn => self.hsMsg(HS_ENCRYPTED_EXTENSIONS, &[_]u8{ 0, 15, 0, 16, 0, 11, 0, 9, 8 } ++ "http/1.1"),
                .cert => self.hsMsg(HS_CERTIFICATE, certBody(self.chain, &body)),
                .cert_alt => self.hsMsg(HS_CERTIFICATE, certBody(self.alt_chain, &body)),
                .cv => self.hsMsg(HS_CERT_VERIFY, self.cvBody(SIG_ECDSA_SHA256, false, &body)),
                .cv_bad_sig => self.hsMsg(HS_CERT_VERIFY, self.cvBody(SIG_ECDSA_SHA256, true, &body)),
                .cv_pkcs1 => self.hsMsg(HS_CERT_VERIFY, self.cvBody(SIG_RSA_PKCS1_SHA256, false, &body)),
                .fin => {
                    var vd: [48]u8 = undefined;
                    const vl = self.finished(&self.s_hs, &vd);
                    self.hsMsg(HS_FINISHED, vd[0..vl]);
                },
                .trailing_hs => {
                    // Must ride in the same record as Finished.
                    self.hsMsg(HS_ENCRYPTED_EXTENSIONS, &.{ 0, 0 });
                    continue;
                },
            }
            // One record per message, except a trailing message is coalesced
            // with the Finished before it.
            if (step == .fin and self.steps.len > 0 and self.steps[self.steps.len - 1] == .trailing_hs) continue;
            self.flush();
        }
        if (self.pending_len != 0) self.flush();
    }

    /// Decrypt the client's Finished (the record after its ClientHello(s))
    /// and check its MAC over the server-side transcript.
    fn clientFinishedOk(self: *FakeServer) bool {
        var pos: usize = 0;
        while (pos + 5 <= self.cin_len and self.cin[pos] == REC_HANDSHAKE)
            pos += 5 + ((@as(usize, self.cin[pos + 3]) << 8) | self.cin[pos + 4]);
        if (pos > self.cin_len) return false;
        const rec = self.cin[pos..self.cin_len];
        const hl = self.suite.hash_len;
        if (rec.len < 5 + 1 + 16) return false;
        const len = (@as(usize, rec[3]) << 8) | rec[4];
        if (rec[0] != REC_APPDATA or rec.len != 5 + len) return false;
        var body: [4 + 48 + 1]u8 = undefined;
        const body_len = len - 16;
        if (body_len != 4 + hl + 1) return false;
        @memcpy(body[0..body_len], rec[5..][0..body_len]);
        var tag: [16]u8 = undefined;
        @memcpy(&tag, rec[5 + body_len ..][0..16]);
        var keys = RecordKeys.initSuite(self.suite, self.c_hs[0..hl]);
        const n = keys.nonce();
        if (!keys.open(&n, body[0..body_len], rec[0..5], &tag)) return false;
        if (body[0] != HS_FINISHED or body[3] != hl or body[4 + hl] != REC_HANDSHAKE) return false;
        var expected: [48]u8 = undefined;
        _ = self.finished(&self.c_hs, &expected);
        return std.mem.eql(u8, body[4..][0..hl], expected[0..hl]);
    }
};

const TEST_ENTROPY = [_]u8{0x42} ** 32 ++ [_]u8{0x24} ** 32;

fn fakeServer(steps: []const Step) FakeServer {
    var fs = FakeServer{ .steps = steps, .client_pub = x25519.publicKey(&clampScalar(TEST_ENTROPY[0..32])) };
    if (!p256.ecdhKeypair(&p256Scalar(&TEST_ENTROPY), &fs.client_pub_p256)) unreachable;
    return fs;
}

/// RootsFn for the synthetic test PKI: its root is the only anchor.
fn pkiRoots(out: []x509.Cert) usize {
    return parseRootsDer(&.{&pki.root_der}, out);
}

fn pkiHandshake(fs: *FakeServer) Error!Conn {
    setEntropy(&TEST_ENTROPY);
    return handshakeWithRoots(fs.transport(), PKI_HOST, PKI_NOW, pkiRoots);
}

test "tls: scripted server EE,Cert,CV,Fin completes the handshake" {
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    const conn = try pkiHandshake(&fs);
    try testing.expect(fs.clientFinishedOk());
    try testing.expect(!conn.closed);
    try testing.expect(conn.suite.id == TLS_AES_128_GCM_SHA256);
    try testing.expectEqual(@as(usize, 0), conn.negotiatedAlpn().len);
}

test "tls: TLS_AES_256_GCM_SHA384 runs the SHA-384 schedule end to end" {
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    fs.suite = SUITE_AES256;
    const conn = try pkiHandshake(&fs);
    try testing.expect(fs.clientFinishedOk());
    try testing.expect(conn.suite.id == TLS_AES_256_GCM_SHA384);
    try testing.expect(conn.client_app.aead == .aes256_gcm);
}

test "tls: TLS_CHACHA20_POLY1305_SHA256 completes the handshake" {
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    fs.suite = SUITE_CHACHA;
    const conn = try pkiHandshake(&fs);
    try testing.expect(fs.clientFinishedOk());
    try testing.expect(conn.server_app.aead == .chacha20_poly1305);
}

test "tls: a server choosing secp256r1 completes the handshake" {
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    fs.group = GROUP_SECP256R1;
    _ = try pkiHandshake(&fs);
    try testing.expect(fs.clientFinishedOk());
}

test "tls: HelloRetryRequest to secp256r1 under SHA-384 completes the handshake" {
    // The transcript restarts with message_hash(SHA-384(CH1)), a 48-byte
    // hash: a SHA-256-only substitution would fail the Finished checks.
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    fs.suite = SUITE_AES256;
    fs.group = GROUP_SECP256R1;
    fs.hrr_group = GROUP_SECP256R1;
    _ = try pkiHandshake(&fs);
    try testing.expect(fs.clientFinishedOk());
}

test "tls: after a HelloRetryRequest the key share must be for the requested group" {
    // HRR asks for X25519, so ClientHello2 carries only an X25519 share; a
    // ServerHello answering with P-256 names a share the client never sent.
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    fs.group = GROUP_SECP256R1;
    fs.hrr_group = GROUP_X25519;
    try testing.expectError(Error.HandshakeFailed, pkiHandshake(&fs));
}

test "tls: the server's ALPN choice reaches the connection" {
    var fs = fakeServer(&.{ .ee_alpn, .cert, .cv, .fin });
    const conn = try pkiHandshake(&fs);
    try testing.expectEqualSlices(u8, "http/1.1", conn.negotiatedAlpn());
}

test "tls: MITM with a valid chain but no CertificateVerify is rejected" {
    // EE, Cert, Fin: the attacker owns the ECDHE secret, so its Finished MAC
    // is valid; without CertificateVerify it never proves the leaf key.
    var fs = fakeServer(&.{ .ee, .cert, .fin });
    try testing.expectError(Error.UnexpectedMessage, pkiHandshake(&fs));
}

test "tls: MITM replaying a real site's chain without CertificateVerify is rejected" {
    // The same attack with the REAL Binance chain against the embedded trust
    // store (the production path): chain validation passes, yet the
    // handshake must fail because no CertificateVerify follows.
    const tv = @import("testvec.sig");
    var fs = fakeServer(&.{ .ee, .cert, .fin });
    fs.chain = &.{ &tv.binance_leaf_der, &tv.binance_intermediate_der };
    setEntropy(&TEST_ENTROPY);
    try testing.expectError(Error.UnexpectedMessage, handshake(fs.transport(), "stream.binance.com", 1780272000));
}

test "tls: a second Certificate after CertificateVerify is rejected" {
    // Cert(attacker), CV(attacker), Cert(other), Fin: the checked chain must
    // not be swappable after the signature check.
    var fs = fakeServer(&.{ .ee, .cert, .cv, .cert_alt, .fin });
    try testing.expectError(Error.UnexpectedMessage, pkiHandshake(&fs));
}

test "tls: Cert(untrusted self key), CV, Cert(real), Fin is rejected" {
    // The first Certificate (the attacker's own, here a leaf with no path to
    // a trusted root) is validated before its CertificateVerify is accepted.
    var fs = fakeServer(&.{ .ee, .cert, .cv, .cert_alt, .fin });
    fs.chain = &.{&pki.leaf_der};
    fs.alt_chain = &.{ &pki.leaf_der, &pki.inter_der };
    try testing.expectError(Error.CertInvalid, pkiHandshake(&fs));
}

test "tls: CertificateVerify before Certificate is rejected" {
    var fs = fakeServer(&.{ .ee, .cv, .cert, .fin });
    try testing.expectError(Error.UnexpectedMessage, pkiHandshake(&fs));
}

test "tls: missing EncryptedExtensions and duplicate EE are rejected" {
    var fs1 = fakeServer(&.{ .cert, .cv, .fin });
    try testing.expectError(Error.UnexpectedMessage, pkiHandshake(&fs1));
    var fs2 = fakeServer(&.{ .ee, .ee, .cert, .cv, .fin });
    try testing.expectError(Error.UnexpectedMessage, pkiHandshake(&fs2));
}

test "tls: a CertificateVerify with a bad signature is rejected" {
    var fs = fakeServer(&.{ .ee, .cert, .cv_bad_sig, .fin });
    try testing.expectError(Error.CertInvalid, pkiHandshake(&fs));
}

test "tls: RSA PKCS#1 v1.5 CertificateVerify schemes are refused" {
    var fs = fakeServer(&.{ .ee, .cert, .cv_pkcs1, .fin });
    try testing.expectError(Error.UnsupportedParams, pkiHandshake(&fs));
}

test "tls: handshake bytes trailing the server Finished are rejected" {
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin, .trailing_hs });
    try testing.expectError(Error.UnexpectedMessage, pkiHandshake(&fs));
}

test "tls: leaf with EKU clientAuth only fails the handshake" {
    var fs = fakeServer(&.{ .ee, .cert, .cv, .fin });
    fs.chain = &.{ &pki.leaf_client_der, &pki.inter_der };
    setEntropy(&TEST_ENTROPY);
    try testing.expectError(Error.CertInvalid, handshakeWithRoots(fs.transport(), "client.galaxy.test", PKI_NOW, pkiRoots));
}

test "tls: each handshake consumes the entropy; a second one without setEntropy fails" {
    var fs1 = fakeServer(&.{ .ee, .cert, .cv, .fin });
    _ = try pkiHandshake(&fs1);
    // The pool was taken and wiped by the first handshake.
    try testing.expect(!g_entropy_set);
    try testing.expect(std.mem.allEqual(u8, &g_entropy, 0));
    var fs2 = fakeServer(&.{ .ee, .cert, .cv, .fin });
    try testing.expectError(Error.NoEntropy, handshakeWithRoots(fs2.transport(), PKI_HOST, PKI_NOW, pkiRoots));
    // Nothing was sent: no ClientHello goes out without fresh entropy.
    try testing.expectEqual(@as(usize, 0), fs2.cin_len);
}
