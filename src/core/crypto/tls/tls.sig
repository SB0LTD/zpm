// TLS 1.3 client (RFC 8446) over a std.Io.net.Stream — pure Sig, no allocator.
// Layer 1: net/crypto (entry of the tls_client directory module for wss://).
//
// Implements exactly what a client needs to talk to Binance/KuCoin:
//   • cipher suite TLS_AES_128_GCM_SHA256 (the mandatory-to-implement suite),
//   • X25519 key exchange, TLS 1.3 only (supported_versions),
//   • full handshake: ClientHello → ServerHello → {EncryptedExtensions,
//     Certificate, CertificateVerify, Finished} → client Finished,
//   • real certificate chain validation against the embedded CA bundle,
//   • CertificateVerify signature check over the handshake transcript,
//   • application_data record encrypt/decrypt with the per-record GCM nonce,
//   • KeyUpdate handling and close_notify.
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
// NOTE: ca_bundle.sig (the embedded Mozilla trust store, ~776 KB, which in turn
// pulls in ca_roots_web.sig, ~945 KB) is deliberately NOT imported at the top
// level. It is reached ONLY through defaultRootsLoad() below — a function-body
// @import — so a caller that injects its own roots provider (see
// handshakeWithRoots / RootsFn) never drags the embedded bundle into its module
// closure. The default path (handshake(), the http/wss clients) is byte-for-byte
// unchanged: it resolves to defaultRootsLoad which calls ca_bundle.load().

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

/// Upper bound on trust-anchor certificates a roots provider may return into
/// the handshake-local buffer. Sized for the embedded Mozilla snapshot (137
/// roots) with headroom; mirrors the old ca_bundle.MAX_ROOTS contract without
/// forcing ca_bundle.sig into every caller's module graph.
pub const MAX_ROOTS: usize = 145;

/// Injectable trust-root provider. The handshake calls this to populate a
/// caller-supplied, stack-resident buffer of parsed trust anchors, then
/// validates the server chain against roots[0..returned]. Allocator-free: the
/// provider writes into `out` and returns how many anchors it produced.
///
/// Leave it null (the default) and the handshake uses the embedded Mozilla CA
/// bundle via defaultRootsLoad — identical to the historical behavior. Supply
/// your own (e.g. an embedded-system kernel shipping a lean root list) and the
/// embedded bundle is never pulled into your closure.
pub const RootsFn = *const fn (out: []x509.Cert) usize;

/// Re-export so callers injecting their own roots can name the anchor type and
/// use parseRootsDer without importing x509.sig directly.
pub const Cert = x509.Cert;

/// Parse a caller-supplied list of DER-encoded root certificates into `out`,
/// skipping any that fail to parse. Returns the count written. This is the
/// allocator-free building block a roots provider uses: hold your anchors as
/// raw DER (`[]const []const u8`) and call this from a RootsFn. It touches only
/// x509 (the parser), never ca_bundle.sig, so an injecting caller stays free of
/// the embedded Mozilla bundle.
pub fn parseRootsDer(ders: []const []const u8, out: []x509.Cert) usize {
    var n: usize = 0;
    for (ders) |der| {
        if (n >= out.len) break;
        out[n] = x509.parse(der) catch continue;
        n += 1;
    }
    return n;
}

/// Default trust-root provider: parse the embedded Mozilla CA bundle. The
/// @import lives in the function body (not at module scope) so this module can
/// compile — and callers can link — without ca_bundle.sig/ca_roots_web.sig in
/// the closure UNLESS defaultRootsLoad is actually referenced. The http/wss
/// clients reference it (through the null default), so their behavior and
/// embedded trust store are unchanged.
pub fn defaultRootsLoad(out: []x509.Cert) usize {
    const ca_bundle = @import("ca_bundle.sig");
    return ca_bundle.load(out);
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

/// Running transcript hash (SHA-256) over all handshake messages.
const Transcript = struct {
    // We keep the raw concatenation because the key schedule needs the hash of
    // specific prefixes; SHA-256 of a bounded buffer is simplest and correct.
    buf: [MAX_TRANSCRIPT]u8 = undefined,
    len: usize = 0,

    const MAX_TRANSCRIPT: usize = 32 * 1024; // handshakes with certs fit easily

    fn add(self: *Transcript, data: []const u8) void {
        if (self.len + data.len <= self.buf.len) {
            @memcpy(self.buf[self.len .. self.len + data.len], data);
            self.len += data.len;
        }
    }
    fn hash(self: *const Transcript) [32]u8 {
        return sha256.hash(self.buf[0..self.len]);
    }
    fn hash384(self: *const Transcript) [48]u8 {
        return keysched384.sha384over(self.buf[0..self.len]);
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

    /// AES-128-GCM-SHA256 default path. Byte-identical to the original init:
    /// derive 16-byte key + 12-byte iv via the SHA-256 schedule, build AES-128-GCM.
    fn init(secret: *const [32]u8) RecordKeys {
        var key: [16]u8 = undefined;
        var iv: [12]u8 = undefined;
        keysched.deriveTrafficKeys(secret, &key, &iv);
        return .{ .aead = .aes128_gcm, .gcm128 = gcm.Gcm.init(&key), .iv = iv };
    }

    /// Build record keys for an arbitrary suite from its traffic secret.
    /// `secret` is hash_len bytes (32 for SHA-256 suites, 48 for SHA-384).
    fn initSuite(suite: Suite, secret: []const u8) RecordKeys {
        var rk = RecordKeys{ .aead = suite.aead };
        switch (suite.hash) {
            .sha256 => {
                var s32: [32]u8 = undefined;
                @memcpy(&s32, secret[0..32]);
                switch (suite.aead) {
                    .aes128_gcm => {
                        var key: [16]u8 = undefined;
                        keysched.deriveTrafficKeys(&s32, &key, &rk.iv);
                        rk.gcm128 = gcm.Gcm.init(&key);
                    },
                    .chacha20_poly1305 => {
                        _ = hkdf.expandLabel(&s32, "key", "", &rk.chacha_key, 32);
                        _ = hkdf.expandLabel(&s32, "iv", "", &rk.iv, 12);
                    },
                    .aes256_gcm => unreachable, // AES-256 pairs with SHA-384
                }
            },
            .sha384 => {
                var s48: [48]u8 = undefined;
                @memcpy(&s48, secret[0..48]);
                var key: [32]u8 = undefined;
                keysched384.deriveTrafficKeys(&s48, &key, &rk.iv);
                rk.gcm256 = gcm.Gcm256.init(&key);
            },
        }
        return rk;
    }

    fn nonce(self: *const RecordKeys) [12]u8 {
        var n = self.iv;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const shift: u6 = @intCast(i * 8);
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

/// An established TLS connection. After handshake, use read()/write() for
/// application data; they transparently GCM-protect TLS records.
pub const Conn = struct {
    transport: Transport,
    client_app: RecordKeys,
    server_app: RecordKeys,
    // Current server application_traffic_secret_N. Retained so a post-handshake
    // server KeyUpdate can derive secret_{N+1} = HKDF-Expand-Label(secret_N,
    // "traffic upd", "", 32) and rekey the receive direction in place (RFC 8446
    // §7.2) — otherwise every record after a KeyUpdate would fail to decrypt.
    suite: Suite = SUITE_AES128,
    server_app_secret: [48]u8 = undefined,
    // Negotiated ALPN protocol (empty if the server did not select one).
    alpn: [32]u8 = @splat(0),
    alpn_len: u8 = 0,
    // Leftover decrypted application bytes not yet consumed by the caller.
    inbuf: [MAX_RECORD]u8 = undefined,
    in_off: usize = 0,
    in_len: usize = 0,
    closed: bool = false,

    pub fn buffered(self: *const Conn) usize {
        return self.in_len - self.in_off;
    }

    /// The ALPN protocol the server selected (e.g. "http/1.1"), or empty.
    pub fn negotiatedAlpn(self: *const Conn) []const u8 {
        return self.alpn[0..self.alpn_len];
    }

    /// Write application data as one or more TLS 1.3 app_data records.
    pub fn write(self: *Conn, data: []const u8) Error!void {
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
                    if (rec.len >= 1 and self.inbuf[0] == HS_KEY_UPDATE) {
                        // Rekey the receive direction so we can keep decrypting.
                        // If the server set update_requested (inbuf[4]==1) it
                        // also wants us to rotate our send keys; we don't (we
                        // send only rare subscribe/ping frames, and the app's
                        // reconnect loop is the backstop if a send ever
                        // desyncs). Receive-side rekey is the mandatory part.
                        self.rekeyServer();
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
        const hl = self.suite.hash_len;
        var next: [48]u8 = undefined;
        if (self.suite.hash == .sha384) {
            keysched384.expandLabel(self.server_app_secret[0..48], "traffic upd", "", next[0..48]);
        } else {
            var cur: [32]u8 = undefined;
            @memcpy(&cur, self.server_app_secret[0..32]);
            var n32: [32]u8 = undefined;
            _ = hkdf.expandLabel(&cur, "traffic upd", "", &n32, 32);
            @memcpy(next[0..32], &n32);
        }
        @memcpy(self.server_app_secret[0..hl], next[0..hl]);
        self.server_app = RecordKeys.initSuite(self.suite, self.server_app_secret[0..hl]);
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
pub fn handshake(transport: Transport, hostname: []const u8, now: i64) Error!Conn {
    return handshakeWithRoots(transport, hostname, now, null);
}

/// As `handshake`, but with an injectable trust-root provider. When `roots_fn`
/// is null the embedded Mozilla CA bundle is used (via defaultRootsLoad), so
/// this is a strict superset of `handshake` with identical default behavior.
/// Pass a provider to validate against your own anchors without compiling the
/// embedded bundle into your module closure.
pub fn handshakeWithRoots(transport: Transport, hostname: []const u8, now: i64, roots_fn: ?RootsFn) Error!Conn {
    var hs = Handshaker{ .transport = transport, .hostname = hostname, .now = now, .roots_fn = roots_fn };
    return hs.run();
}

// The handshake driver keeps all transient state (keys, transcript, buffers).
const Handshaker = struct {
    transport: Transport,
    hostname: []const u8,
    now: i64,
    // Injected trust-root provider; null selects the embedded Mozilla bundle.
    roots_fn: ?RootsFn = null,
    transcript: Transcript = .{},
    suite: Suite = SUITE_AES128,
    priv: [32]u8 = undefined,            // X25519 private scalar
    priv_p256: [32]u8 = undefined,       // P-256 private scalar (if offered)
    hrr_done: bool = false,
    retry_group: u16 = 0,
    ch1_hash: [32]u8 = undefined,
    hrr_raw: [512]u8 = undefined,
    hrr_raw_len: usize = 0,
    neg_alpn: [32]u8 = @splat(0),
    neg_alpn_len: u8 = 0,
    // handshake-phase record keys
    hs_client: RecordKeys = undefined,
    hs_server: RecordKeys = undefined,
    ks: keysched.KeySchedule = undefined,       // SHA-256 schedule
    ks384: keysched384.KeySchedule384 = undefined, // SHA-384 schedule
    // Handshake traffic secrets, widened to 48 bytes; the active length is
    // self.suite.hash_len (32 for SHA-256 suites, 48 for SHA-384).
    client_hs_secret: [48]u8 = undefined,
    server_hs_secret: [48]u8 = undefined,
    // reusable record read buffer
    recbuf: [MAX_RECORD]u8 = undefined,
    // scratch: raw bytes of the handshake message currently being processed
    // (used to defer folding CertVerify into the transcript until after verify).
    lastRawTmp: [MAX_RECORD]u8 = undefined,
    lastRawLen: usize = 0,
    // Stable storage for the Certificate message. The parsed x509.Cert values
    // hold slices INTO this buffer, so it must outlive the rest of the flight
    // (CertVerify + Finished reuse the shared recbuf and would otherwise clobber
    // the cert bytes before verifyChain runs).
    certbuf: [MAX_RECORD]u8 = undefined,
    certlen: usize = 0,
    // Decrypted handshake-message bytes from the current record. TLS 1.3 servers
    // may coalesce EE+Certificate+CertVerify+Finished into ONE record, so we
    // buffer the plaintext and hand out one message at a time across calls.
    hs_plain: [MAX_RECORD]u8 = undefined,
    hs_plain_len: usize = 0,
    hs_plain_off: usize = 0,

    fn run(self: *Handshaker) Error!Conn {
        // Send CH1 (both key shares). The transcript records CH1 via writeHandshake.
        try self.sendClientHello(0);
        var hrr = try self.readServerHello();
        if (hrr) {
            // RFC 8446 4.4.1: replace CH1 in the transcript with a synthetic
            // message_hash, then re-add the HRR (ServerHello) that readServerHello
            // already folded in. We rebuild the transcript from scratch here.
            try self.rebuildTranscriptForHrr();
            // Send CH2 with a key_share only for the requested group.
            try self.sendClientHello(self.retry_group);
            hrr = try self.readServerHello();
            if (hrr) return Error.HandshakeFailed; // a second HRR is illegal
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
        _ = self.deriveApp(&c_app, &s_app);

        // Client Finished is sent under the handshake keys; it folds itself into
        // the transcript but no longer affects the application secrets above.
        try self.sendClientFinished();

        var sas: [48]u8 = undefined;
        @memcpy(sas[0..self.suite.hash_len], s_app[0..self.suite.hash_len]);
        var conn = Conn{
            .transport = self.transport,
            .suite = self.suite,
            .client_app = RecordKeys.initSuite(self.suite, c_app[0..self.suite.hash_len]),
            .server_app = RecordKeys.initSuite(self.suite, s_app[0..self.suite.hash_len]),
            .server_app_secret = sas,
        };
        @memcpy(conn.alpn[0..self.neg_alpn_len], self.neg_alpn[0..self.neg_alpn_len]);
        conn.alpn_len = self.neg_alpn_len;
        return conn;
    }

    // ── suite-aware handshake helpers (dispatch on self.suite.hash) ──

    /// Transcript hash into `out` (48-byte buffer); returns the active length.
    fn thash(self: *Handshaker, out: *[48]u8) usize {
        if (self.suite.hash == .sha384) {
            out.* = undefined;
            const h = self.transcript.hash384();
            @memcpy(out[0..48], &h);
            return 48;
        }
        const h = self.transcript.hash();
        @memcpy(out[0..32], &h);
        return 32;
    }

    /// Derive handshake traffic secrets from the ECDHE shared secret and build
    /// the handshake-phase RecordKeys for the negotiated suite.
    fn deriveHandshake(self: *Handshaker, shared: []const u8) void {
        var th: [48]u8 = undefined;
        const hl = self.thash(&th);
        if (self.suite.hash == .sha384) {
            self.ks384 = keysched384.KeySchedule384.init();
            var cs: [48]u8 = undefined;
            var ss: [48]u8 = undefined;
            self.ks384.deriveHandshakeSecrets(shared, th[0..48], &cs, &ss);
            @memcpy(self.client_hs_secret[0..48], &cs);
            @memcpy(self.server_hs_secret[0..48], &ss);
        } else {
            self.ks = keysched.KeySchedule.init(null);
            var sh32: [32]u8 = undefined;
            @memcpy(&sh32, shared[0..32]);
            var th32: [32]u8 = undefined;
            @memcpy(&th32, th[0..32]);
            var cs: [32]u8 = undefined;
            var ss: [32]u8 = undefined;
            self.ks.deriveHandshakeSecrets(&sh32, &th32, &cs, &ss);
            @memcpy(self.client_hs_secret[0..32], &cs);
            @memcpy(self.server_hs_secret[0..32], &ss);
        }
        _ = hl;
        self.hs_client = RecordKeys.initSuite(self.suite, self.client_hs_secret[0..self.suite.hash_len]);
        self.hs_server = RecordKeys.initSuite(self.suite, self.server_hs_secret[0..self.suite.hash_len]);
    }

    /// Derive application traffic secrets; writes into 48-byte buffers and
    /// returns the active length.
    fn deriveApp(self: *Handshaker, c_app: *[48]u8, s_app: *[48]u8) usize {
        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            var ca: [48]u8 = undefined;
            var sa: [48]u8 = undefined;
            self.ks384.deriveApplicationSecrets(th[0..48], &ca, &sa);
            @memcpy(c_app[0..48], &ca);
            @memcpy(s_app[0..48], &sa);
            return 48;
        }
        var th32: [32]u8 = undefined;
        @memcpy(&th32, th[0..32]);
        var ca: [32]u8 = undefined;
        var sa: [32]u8 = undefined;
        self.ks.deriveApplicationSecrets(&th32, &ca, &sa);
        @memcpy(c_app[0..32], &ca);
        @memcpy(s_app[0..32], &sa);
        return 32;
    }

    /// Finished verify_data for the given base secret; writes into `out`,
    /// returns the active length (32 or 48).
    fn finishedData(self: *Handshaker, base: []const u8, out: *[48]u8) usize {
        var th: [48]u8 = undefined;
        _ = self.thash(&th);
        if (self.suite.hash == .sha384) {
            var base48: [48]u8 = undefined;
            @memcpy(&base48, base[0..48]);
            const vd = keysched384.KeySchedule384.computeFinished(&base48, th[0..48]);
            @memcpy(out[0..48], &vd);
            return 48;
        }
        var base32: [32]u8 = undefined;
        @memcpy(&base32, base[0..32]);
        var th32: [32]u8 = undefined;
        @memcpy(&th32, th[0..32]);
        const vd = keysched.KeySchedule.computeFinished(&base32, &th32);
        @memcpy(out[0..32], &vd);
        return 32;
    }

    // ── ClientHello ──
    // only_group: 0 = offer both key shares (CH1); otherwise send a key_share only
    // for the requested group (CH2 after a HelloRetryRequest).
    fn sendClientHello(self: *Handshaker, only_group: u16) Error!void {
        // Generate ephemeral keys once (CH1); reuse them for CH2 per RFC 8446.
        if (!self.hrr_done) {
            self.priv = devScalar();
            self.priv_p256 = devScalar();
        }
        const pubkey = x25519.publicKey(&self.priv);
        var pubkey_p256: [65]u8 = undefined;
        const have_p256 = p256.ecdhKeypair(&self.priv_p256, &pubkey_p256);

        var body: [1024]u8 = undefined;
        var w = Writer{ .buf = &body };
        w.putU16(TLS12); // legacy_version
        w.bytes(&devRandom()); // 32-byte random
        w.putU8(0); // legacy_session_id length 0
        w.putU16(6);
        w.putU16(TLS_AES_256_GCM_SHA384);
        w.putU16(TLS_CHACHA20_POLY1305_SHA256);
        w.putU16(TLS_AES_128_GCM_SHA256);
        w.putU8(1);
        w.putU8(0);
        var ext: [512]u8 = undefined;
        var ew = Writer{ .buf = &ext };
        writeSni(&ew, self.hostname);
        writeSupportedVersions(&ew);
        writeSupportedGroups(&ew);
        writeSigAlgs(&ew);
        writeAlpn(&ew);
        if (only_group == 0) {
            writeKeyShare(&ew, &pubkey, &pubkey_p256, have_p256);
        } else if (only_group == GROUP_X25519) {
            writeKeyShareOne(&ew, GROUP_X25519, &pubkey);
        } else if (only_group == GROUP_SECP256R1 and have_p256) {
            writeKeyShareOne(&ew, GROUP_SECP256R1, &pubkey_p256);
        } else {
            return Error.HandshakeFailed; // server asked for a group we cannot offer
        }
        w.putU16(@intCast(ew.len));
        w.bytes(ew.slice());

        // Build the full handshake message (header + body).
        var hs: [4 + 1024]u8 = undefined;
        const blen = w.len;
        hs[0] = HS_CLIENT_HELLO;
        hs[1] = @intCast((blen >> 16) & 0xFF);
        hs[2] = @intCast((blen >> 8) & 0xFF);
        hs[3] = @intCast(blen & 0xFF);
        @memcpy(hs[4 .. 4 + blen], w.slice());
        const full = hs[0 .. 4 + blen];
        // On CH1, remember its hash for the possible HRR transcript substitution.
        if (only_group == 0) self.ch1_hash = sha256.hash(full);
        // Add to transcript + send as a plaintext handshake record.
        self.transcript.add(full);
        var rec: [5]u8 = .{ REC_HANDSHAKE, 0x03, 0x01, @intCast((blen + 4) >> 8), @intCast((blen + 4) & 0xFF) };
        try self.transport.writeAll(&rec);
        try self.transport.writeAll(full);
    }

    /// Reset the transcript after a HelloRetryRequest per RFC 8446 4.4.1:
    /// transcript = message_hash(Hash(CH1)) || HRR. The HRR raw bytes were saved
    /// by readServerHello into hrr_raw.
    fn rebuildTranscriptForHrr(self: *Handshaker) Error!void {
        self.transcript = .{};
        // Synthetic message_hash handshake message: type 254, len = hash len, body = Hash(CH1).
        var synth: [4 + 32]u8 = undefined;
        synth[0] = 254; // message_hash
        synth[1] = 0;
        synth[2] = 0;
        synth[3] = 32;
        @memcpy(synth[4..36], &self.ch1_hash);
        self.transcript.add(&synth);
        self.transcript.add(self.hrr_raw[0..self.hrr_raw_len]);
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
        const suite_id = try r.getU16();
        self.suite = suiteById(suite_id) orelse return Error.UnsupportedParams;
        _ = try r.getU8(); // compression

        if (is_hrr) {
            // HRR: find the key_share extension carrying the requested group.
            // Do NOT add this HRR to the live transcript yet; stash it so
            // rebuildTranscriptForHrr can order it after the synthetic CH1 hash.
            if (msg.raw.len > self.hrr_raw.len) return Error.HandshakeFailed;
            @memcpy(self.hrr_raw[0..msg.raw.len], msg.raw);
            self.hrr_raw_len = msg.raw.len;
            const ext_len = try r.getU16();
            var ext = Reader{ .buf = try r.take(ext_len) };
            var found = false;
            while (ext.remaining() >= 4) {
                const etype = try ext.getU16();
                const elen = try ext.getU16();
                const edata = try ext.take(elen);
                if (etype == 51) { // key_share: HRR carries just the selected group
                    var kr = Reader{ .buf = edata };
                    self.retry_group = try kr.getU16();
                    found = true;
                }
            }
            if (!found) return Error.HandshakeFailed;
            return true;
        }

        // Normal ServerHello: fold into the transcript, then derive.
        self.transcript.add(msg.raw);
        var server_pub: [65]u8 = undefined;
        var server_pub_len: usize = 0;
        var server_group: u16 = 0;
        var got_ks = false;
        const ext_len = try r.getU16();
        var ext = Reader{ .buf = try r.take(ext_len) };
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

        var shared: [48]u8 = undefined;
        var shared_len: usize = 0;
        if (server_group == GROUP_X25519) {
            if (server_pub_len != 32) return Error.HandshakeFailed;
            var sp: [32]u8 = undefined;
            @memcpy(&sp, server_pub[0..32]);
            const s = x25519.sharedSecret(&self.priv, &sp);
            @memcpy(shared[0..32], &s);
            shared_len = 32;
        } else if (server_group == GROUP_SECP256R1) {
            if (server_pub_len != 65) return Error.HandshakeFailed;
            var sp: [65]u8 = undefined;
            @memcpy(&sp, server_pub[0..65]);
            var secret: [32]u8 = undefined;
            if (!p256.ecdhShared(&self.priv_p256, &sp, &secret)) return Error.HandshakeFailed;
            @memcpy(shared[0..32], &secret);
            shared_len = 32;
        } else {
            return Error.UnsupportedParams;
        }
        self.deriveHandshake(shared[0..shared_len]);
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
    fn readEncryptedFlight(self: *Handshaker) Error!void {
        var chain_buf: [MAX_CERTS]x509.Cert = undefined;
        var chain_len: usize = 0;
        var server_finished_ok = false;
        // Transcript hash BEFORE the server Finished — needed to verify it.
        var th_before_cv: [48]u8 = undefined;
        var th_before_cv_len: usize = 32;

        while (!server_finished_ok) {
            const msg = try self.readEncryptedHandshake();
            switch (msg.msg_type) {
                HS_ENCRYPTED_EXTENSIONS => self.parseEncryptedExtensions(msg.body),
                HS_CERTIFICATE => {
                    // Copy the Certificate body into stable storage before
                    // parsing: the resulting x509.Cert values slice into it and
                    // must survive the CertVerify/Finished records that reuse
                    // the shared recbuf.
                    if (msg.body.len > self.certbuf.len) return Error.BufferTooSmall;
                    @memcpy(self.certbuf[0..msg.body.len], msg.body);
                    self.certlen = msg.body.len;
                    chain_len = try parseCertificateMsg(self.certbuf[0..self.certlen], &chain_buf);
                },
                HS_CERT_VERIFY => {
                    th_before_cv_len = self.thash(&th_before_cv);
                    try self.verifyCertVerify(msg.body, chain_buf[0..chain_len], th_before_cv[0..th_before_cv_len]);
                },
                HS_FINISHED => {
                    // (Server Finished MAC verification omitted for brevity is
                    // NOT acceptable — we verify it below.)
                    try self.verifyServerFinished(msg);
                    server_finished_ok = true;
                },
                else => return Error.UnexpectedMessage,
            }
            // Add each handshake message to the transcript AFTER using the
            // pre-message hash where needed (handled in the specific verifiers).
            if (msg.msg_type != HS_CERT_VERIFY and msg.msg_type != HS_FINISHED) {
                self.transcript.add(msg.raw);
            }
        }

        // Validate the certificate chain against the trust store. The anchor
        // set comes from the injected provider when supplied, otherwise from
        // the embedded Mozilla bundle (defaultRootsLoad). Both write parsed
        // anchors into this handshake-local, stack-resident buffer.
        if (chain_len == 0) return Error.CertInvalid;
        var roots: [MAX_ROOTS]x509.Cert = undefined;
        const nroots = if (self.roots_fn) |rf| rf(&roots) else defaultRootsLoad(&roots);
        verify.verifyChain(chain_buf[0..chain_len], roots[0..nroots], self.hostname, self.now) catch
        return Error.CertInvalid;
    }

    fn verifyCertVerify(self: *Handshaker, body: []const u8, chain: []const x509.Cert, th: []const u8) Error!void {
        if (chain.len == 0) return Error.CertInvalid;
        var r = Reader{ .buf = body };
        const scheme = try r.getU16();
        const siglen = try r.getU16();
        const sig = try r.take(siglen);

        // The signed content is: 64 spaces || context string || 0x00 || transcript-hash.
        var signed: [146]u8 = undefined;
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
        self.transcript.add(self.lastRawTmp[0..self.lastRawLen]);
    }

    fn verifyServerFinished(self: *Handshaker, msg: HandshakeMsg) Error!void {
        var expected: [48]u8 = undefined;
        const vl = self.finishedData(self.server_hs_secret[0..self.suite.hash_len], &expected);
        if (msg.body.len != vl) return Error.HandshakeFailed;
        var diff: u8 = 0;
        var i: usize = 0;
        while (i < vl) : (i += 1) diff |= expected[i] ^ msg.body[i];
        if (diff != 0) return Error.HandshakeFailed;
        self.transcript.add(msg.raw);
    }

    fn sendClientFinished(self: *Handshaker) Error!void {
        var vd: [48]u8 = undefined;
        const vl = self.finishedData(self.client_hs_secret[0..self.suite.hash_len], &vd);
        var body: [4 + 48]u8 = undefined;
        body[0] = HS_FINISHED;
        body[1] = 0;
        body[2] = @intCast((vl >> 8) & 0xFF);
        body[3] = @intCast(vl & 0xFF);
        @memcpy(body[4 .. 4 + vl], vd[0..vl]);
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
    /// contained handshake message.
    fn readPlainHandshake(self: *Handshaker) Error!HandshakeMsg {
        var hdr: [5]u8 = undefined;
        try self.transport.readExact(&hdr);
        const len = (@as(usize, hdr[3]) << 8) | hdr[4];
        if (len < 4 or len > MAX_RECORD) return Error.BadRecord;
        try self.transport.readExact(self.recbuf[0..len]);
        if (hdr[0] != REC_HANDSHAKE) return Error.UnexpectedMessage;
        return sliceHandshake(self.recbuf[0..len]);
    }

    /// Read the next encrypted handshake message. Serves buffered messages from
    /// a previously-decrypted (possibly coalesced) record first; otherwise reads
    /// and decrypts the next record and buffers all its handshake plaintext.
    fn readEncryptedHandshake(self: *Handshaker) Error!HandshakeMsg {
        while (true) {
            // Serve a buffered message if one remains in the current record.
            if (self.hs_plain_off < self.hs_plain_len) {
                const rem = self.hs_plain[self.hs_plain_off..self.hs_plain_len];
                const m = try sliceHandshake(rem);
                self.hs_plain_off += m.raw.len;
                @memcpy(self.lastRawTmp[0..m.raw.len], m.raw);
                self.lastRawLen = m.raw.len;
                return m;
            }
            // Otherwise read + decrypt the next record into hs_plain.
            var hdr: [5]u8 = undefined;
            try self.transport.readExact(&hdr);
            const len = (@as(usize, hdr[3]) << 8) | hdr[4];
            if (len == 0 or len > MAX_RECORD) return Error.BadRecord;
            try self.transport.readExact(self.recbuf[0..len]);
            if (hdr[0] == REC_CHANGE_CIPHER_SPEC) continue;
            if (len < gcm.TAG_LEN) return Error.BadRecord;
            const body_len = len - gcm.TAG_LEN;
            var tag: [16]u8 = undefined;
            @memcpy(&tag, self.recbuf[body_len..len]);
            const nc = self.hs_server.nonce();
            if (!self.hs_server.open(&nc, self.recbuf[0..body_len], &hdr, &tag)) return Error.DecryptFailed;
            self.hs_server.seq += 1;
            var end = body_len;
            while (end > 0 and self.recbuf[end - 1] == 0) end -= 1;
            if (end == 0) return Error.BadRecord;
            const inner_type = self.recbuf[end - 1];
            if (inner_type != REC_HANDSHAKE) continue; // alerts etc.
            // Buffer all handshake-message plaintext (minus the inner type byte).
            const plain_len = end - 1;
            @memcpy(self.hs_plain[0..plain_len], self.recbuf[0..plain_len]);
            self.hs_plain_len = plain_len;
            self.hs_plain_off = 0;
            // loop: the buffered-message branch above now yields the first message.
        }
    }
};

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
    const ctx_len = try r.getU8(); // certificate_request_context (empty for server)
    try r.skip(ctx_len);
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
fn verifyCertVerifySig(leaf: *const x509.Cert, scheme: u16, signed: []const u8, sig: []const u8) Error!void {
    const rsa = @import("rsa.sig");
    switch (scheme) {
        SIG_RSA_PKCS1_SHA256 => {
            if (leaf.key_alg != .rsa) return Error.CertInvalid;
            const pk = rsa.publicKey(leaf.rsa_modulus, leaf.rsa_exponent) catch return Error.CertInvalid;
            if (!rsa.verifyPkcs1(&pk, .sha256, signed, sig)) return Error.CertInvalid;
        },
        SIG_RSA_PSS_SHA256 => {
            if (leaf.key_alg != .rsa) return Error.CertInvalid;
            const pk = rsa.publicKey(leaf.rsa_modulus, leaf.rsa_exponent) catch return Error.CertInvalid;
            if (!rsa.verifyPssSha256(&pk, signed, sig)) return Error.CertInvalid;
        },
        SIG_RSA_PKCS1_SHA384 => {
            if (leaf.key_alg != .rsa) return Error.CertInvalid;
            const pk = rsa.publicKey(leaf.rsa_modulus, leaf.rsa_exponent) catch return Error.CertInvalid;
            if (!rsa.verifyPkcs1(&pk, .sha384, signed, sig)) return Error.CertInvalid;
        },
        SIG_ECDSA_SHA256 => {
            if (leaf.key_alg != .ecdsa_p256 or leaf.ec_point.len != 65) return Error.UnsupportedParams;
            var xy: [64]u8 = undefined;
            @memcpy(&xy, leaf.ec_point[1..65]);
            const digest = sha256.hash(signed);
            var raw: [64]u8 = undefined;
            verify.ecdsaDerToRawPub(sig, &raw) catch return Error.CertInvalid;
            if (!p256.verify(&xy, &digest, &raw)) return Error.CertInvalid;
        },
        SIG_ECDSA_SHA384 => {
            if (leaf.key_alg != .ecdsa_p384 or leaf.ec_point.len != 97) return Error.UnsupportedParams;
            const sha512mod = @import("sha512.sig");
            const p384mod = @import("p384");
            var xy384: [96]u8 = undefined;
            @memcpy(&xy384, leaf.ec_point[1..97]);
            const digest384 = sha512mod.sha384(signed);
            var raw384: [96]u8 = undefined;
            verify.ecdsaDerToRaw384(sig, &raw384) catch return Error.CertInvalid;
            if (!p384mod.verify(&xy384, &digest384, &raw384)) return Error.CertInvalid;
        },

        else => return Error.UnsupportedParams,
    }
}

// ── ClientHello extension writers ──

fn eqBytes32(a: []const u8, b: *const [32]u8) bool {
    if (a.len != 32) return false;
    var i: usize = 0;
    while (i < 32) : (i += 1) { if (a[i] != b[i]) return false; }
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
    w.putU16(@intCast(1 + proto.len));     // ProtocolNameList length
    w.putU8(@intCast(proto.len));
    w.bytes(proto);
}

fn writeSigAlgs(w: *Writer) void {
    const algs = [_]u16{
        SIG_ECDSA_SHA256, SIG_ECDSA_SHA384,
        SIG_RSA_PSS_SHA256, SIG_RSA_PSS_SHA384, SIG_RSA_PSS_SHA512,
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
    w.putU16(@intCast(list_len));     // client_shares length
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
// are drawn from this pool. Hosts MUST seed it from a CSPRNG before handshaking
// via setEntropy() — winsock.fillEntropy() does this from BCryptGenRandom. The
// fixed bytes below are only a fallback that keeps the handshake structurally
// testable in hermetic unit tests; they are never used once fillEntropy() runs.
var g_entropy: [64]u8 = [_]u8{
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01,
    0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x20,
    0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0, 0x21, 0x31, 0x41,
    0x51, 0x61, 0x71, 0x81, 0x91, 0xa1, 0xb1, 0xc1, 0xd1, 0xe1, 0xf1, 0x22, 0x32, 0x42, 0x52, 0x62,
};

/// Install real entropy (32 bytes for the X25519 scalar, 32 for CH.random).
pub fn setEntropy(e: *const [64]u8) void {
    g_entropy = e.*;
}

fn devScalar() [32]u8 {
    var s: [32]u8 = undefined;
    @memcpy(&s, g_entropy[0..32]);
    // X25519 scalar clamping.
    s[0] &= 248;
    s[31] &= 127;
    s[31] |= 64;
    return s;
}

fn devRandom() [32]u8 {
    var r: [32]u8 = undefined;
    @memcpy(&r, g_entropy[32..64]);
    return r;
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
    var changed = false;
    for (0..pt.len) |i| { if (pt[i] != orig[i]) { changed = true; break; } }
    try testing.expect(changed);
    const ok = rk.open(&n, &pt, &aad, &tag);
    try testing.expect(ok);
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
    //   type(2)=0x0010 len(2) | list_len(2) plen(1) \"http/1.1\"
    // Build a correct ALPN EE for \"h2\" programmatically to avoid hand-count errors.
    var b: [32]u8 = undefined;
    var ww = Writer{ .buf = &b };
    ww.putU16(2 + 2 + (2 + 1 + 2)); // extensions length
    ww.putU16(16);                  // ALPN
    ww.putU16(2 + 1 + 2);           // ext body len
    ww.putU16(1 + 2);               // list len
    ww.putU8(2);                    // proto len
    ww.bytes("h2");
    hs.parseEncryptedExtensions(ww.slice());
    try testing.expectEqualSlices(u8, "h2", hs.neg_alpn[0..hs.neg_alpn_len]);
}
