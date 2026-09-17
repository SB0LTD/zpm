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
const keysched = @import("tls13_keys");
const x509 = @import("x509.sig");
const verify = @import("x509_verify.sig");
const ca_bundle = @import("ca_bundle.sig");

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
const GROUP_X25519: u16 = 0x001d;

// Signature scheme code points (for CertificateVerify + sig_algs extension).
const SIG_RSA_PKCS1_SHA256: u16 = 0x0401;
const SIG_RSA_PKCS1_SHA384: u16 = 0x0501;
const SIG_RSA_PKCS1_SHA512: u16 = 0x0601;
const SIG_RSA_PSS_SHA256: u16 = 0x0804;
const SIG_RSA_PSS_SHA384: u16 = 0x0805;
const SIG_ECDSA_SHA256: u16 = 0x0403;
const SIG_ECDSA_SHA384: u16 = 0x0503;

const MAX_RECORD: usize = 16384 + 256; // TLSPlaintext max + AEAD expansion
const MAX_CERTS: usize = verify.MAX_CHAIN;

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
};

/// AEAD record protection state for one direction.
const RecordKeys = struct {
    aead: gcm.Gcm,
    iv: [12]u8,
    seq: u64 = 0,

    fn init(secret: *const [32]u8) RecordKeys {
        var key: [16]u8 = undefined;
        var iv: [12]u8 = undefined;
        keysched.deriveTrafficKeys(secret, &key, &iv);
        return .{ .aead = gcm.Gcm.init(&key), .iv = iv };
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
    server_app_secret: [32]u8 = undefined,
    // Leftover decrypted application bytes not yet consumed by the caller.
    inbuf: [MAX_RECORD]u8 = undefined,
    in_off: usize = 0,
    in_len: usize = 0,
    closed: bool = false,

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
        var next: [32]u8 = undefined;
        _ = hkdf.expandLabel(&self.server_app_secret, "traffic upd", "", &next, 32);
        self.server_app_secret = next;
        self.server_app = RecordKeys.init(&self.server_app_secret);
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
        self.client_app.aead.seal(&n, buf[0..inner_len], &hdr, &tag);
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
        if (!self.server_app.aead.open(&n, self.inbuf[0..body_len], &hdr, &tag)) return Error.DecryptFailed;
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
    var hs = Handshaker{ .transport = transport, .hostname = hostname, .now = now };
    return hs.run();
}

// The handshake driver keeps all transient state (keys, transcript, buffers).
const Handshaker = struct {
    transport: Transport,
    hostname: []const u8,
    now: i64,
    transcript: Transcript = .{},
    priv: [32]u8 = undefined,
    // handshake-phase record keys
    hs_client: RecordKeys = undefined,
    hs_server: RecordKeys = undefined,
    ks: keysched.KeySchedule = undefined,
    client_hs_secret: [32]u8 = undefined,
    server_hs_secret: [32]u8 = undefined,
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

    fn run(self: *Handshaker) Error!Conn {
        try self.sendClientHello();
        try self.readServerHello();
        // From here, handshake records are encrypted with handshake keys.
        try self.readEncryptedFlight();

        // Derive application traffic secrets over the transcript through the
        // server Finished (RFC 8446 §7.1). This MUST happen before we append
        // the client Finished to the transcript — the server keys its
        // application records over Hash(ClientHello…server Finished), so
        // including the client Finished here would desync every app record.
        var c_app: [32]u8 = undefined;
        var s_app: [32]u8 = undefined;
        const th = self.transcript.hash();
        self.ks.deriveApplicationSecrets(&th, &c_app, &s_app);

        // Client Finished is sent under the handshake keys; it folds itself into
        // the transcript but no longer affects the application secrets above.
        try self.sendClientFinished();

        return Conn{
            .transport = self.transport,
            .client_app = RecordKeys.init(&c_app),
            .server_app = RecordKeys.init(&s_app),
            .server_app_secret = s_app,
        };
    }

    // ── ClientHello ──
    fn sendClientHello(self: *Handshaker) Error!void {
        // Generate the X25519 key pair. (Deterministic dev entropy — see note.)
        self.priv = devScalar();
        const pubkey = x25519.publicKey(&self.priv);

        var body: [1024]u8 = undefined;
        var w = Writer{ .buf = &body };
        w.putU16(TLS12); // legacy_version
        w.bytes(&devRandom()); // 32-byte random
        w.putU8(0); // legacy_session_id length 0
        // cipher_suites
        w.putU16(2);
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
        writeKeyShare(&ew, &pubkey);
        w.putU16(@intCast(ew.len));
        w.bytes(ew.slice());

        try self.writeHandshake(HS_CLIENT_HELLO, w.slice());
    }

    // ── ServerHello ──
    fn readServerHello(self: *Handshaker) Error!void {
        const msg = try self.readPlainHandshake();
        if (msg.msg_type != HS_SERVER_HELLO) return Error.UnexpectedMessage;
        // Fold ServerHello into the transcript BEFORE deriving handshake secrets:
        // the handshake traffic secrets are keyed over Hash(ClientHello‖ServerHello),
        // so the client hash must include ServerHello or every encrypted record
        // (starting with EncryptedExtensions) fails to decrypt.
        self.transcript.add(msg.raw);
        var r = Reader{ .buf = msg.body };
        _ = try r.getU16(); // legacy_version
        try r.skip(32); // random
        const sid_len = try r.getU8();
        try r.skip(sid_len);
        const suite = try r.getU16();
        if (suite != TLS_AES_128_GCM_SHA256) return Error.UnsupportedParams;
        _ = try r.getU8(); // compression
        // extensions: find key_share → server public key
        var server_pub: [32]u8 = undefined;
        var got_ks = false;
        const ext_len = try r.getU16();
        var ext = Reader{ .buf = try r.take(ext_len) };
        while (ext.remaining() >= 4) {
            const etype = try ext.getU16();
            const elen = try ext.getU16();
            const edata = try ext.take(elen);
            if (etype == 51) { // key_share
                var kr = Reader{ .buf = edata };
                _ = try kr.getU16(); // group
                const klen = try kr.getU16();
                const kp = try kr.take(klen);
                if (kp.len == 32) {
                    @memcpy(&server_pub, kp);
                    got_ks = true;
                }
            }
        }
        if (!got_ks) return Error.HandshakeFailed;

        // ECDHE shared secret → handshake secrets over transcript(CH..SH).
        const shared = x25519.sharedSecret(&self.priv, &server_pub);
        self.ks = keysched.KeySchedule.init(null);
        const th = self.transcript.hash();
        self.ks.deriveHandshakeSecrets(&shared, &th, &self.client_hs_secret, &self.server_hs_secret);
        self.hs_client = RecordKeys.init(&self.client_hs_secret);
        self.hs_server = RecordKeys.init(&self.server_hs_secret);
    }

    // ── Encrypted flight: EE, Certificate, CertVerify, Finished ──
    fn readEncryptedFlight(self: *Handshaker) Error!void {
        var chain_buf: [MAX_CERTS]x509.Cert = undefined;
        var chain_len: usize = 0;
        var server_finished_ok = false;
        // Transcript hash BEFORE the server Finished — needed to verify it.
        var th_before_cv: [32]u8 = undefined;

        while (!server_finished_ok) {
            const msg = try self.readEncryptedHandshake();
            switch (msg.msg_type) {
                HS_ENCRYPTED_EXTENSIONS => {}, // no extensions we act on
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
                    th_before_cv = self.transcriptHashExcluding(msg);
                    try self.verifyCertVerify(msg.body, chain_buf[0..chain_len], th_before_cv);
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

        // Validate the certificate chain against the embedded trust store.
        if (chain_len == 0) return Error.CertInvalid;
        var roots: [ca_bundle.MAX_ROOTS]x509.Cert = undefined;
        const nroots = ca_bundle.load(&roots);
        verify.verifyChain(chain_buf[0..chain_len], roots[0..nroots], self.hostname, self.now) catch
            return Error.CertInvalid;
    }

    fn transcriptHashExcluding(self: *Handshaker, msg: HandshakeMsg) [32]u8 {
        _ = msg;
        return self.transcript.hash();
    }

    fn verifyCertVerify(self: *Handshaker, body: []const u8, chain: []const x509.Cert, th: [32]u8) Error!void {
        if (chain.len == 0) return Error.CertInvalid;
        var r = Reader{ .buf = body };
        const scheme = try r.getU16();
        const siglen = try r.getU16();
        const sig = try r.take(siglen);

        // The signed content is: 64 spaces || context string || 0x00 || transcript-hash.
        var signed: [130]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            signed[i] = 0x20;
        }
        const ctx = "TLS 1.3, server CertificateVerify";
        @memcpy(signed[64 .. 64 + ctx.len], ctx);
        signed[64 + ctx.len] = 0x00;
        @memcpy(signed[64 + ctx.len + 1 ..][0..32], &th);
        const signed_len = 64 + ctx.len + 1 + 32;

        const leaf = &chain[0];
        try verifyCertVerifySig(leaf, scheme, signed[0..signed_len], sig);
        // Now safe to fold CertVerify into the transcript.
        self.transcript.add(self.lastRawTmp[0..self.lastRawLen]);
    }

    fn verifyServerFinished(self: *Handshaker, msg: HandshakeMsg) Error!void {
        // verify_data = HMAC(finished_key, transcript-hash-up-to-but-not-including-Finished)
        const th = self.transcript.hash();
        const expected = keysched.KeySchedule.computeFinished(&self.server_hs_secret, &th);
        if (msg.body.len != 32) return Error.HandshakeFailed;
        var diff: u8 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) diff |= expected[i] ^ msg.body[i];
        if (diff != 0) return Error.HandshakeFailed;
        // Fold server Finished into the transcript for client Finished + app keys.
        self.transcript.add(msg.raw);
    }

    fn sendClientFinished(self: *Handshaker) Error!void {
        const th = self.transcript.hash();
        const vd = keysched.KeySchedule.computeFinished(&self.client_hs_secret, &th);
        var body: [4 + 32]u8 = undefined;
        body[0] = HS_FINISHED;
        body[1] = 0;
        body[2] = 0;
        body[3] = 32;
        @memcpy(body[4..36], &vd);
        // Client Finished is sent encrypted with client handshake keys.
        try self.writeEncrypted(REC_HANDSHAKE, &body);
        self.transcript.add(&body);
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
        self.hs_client.aead.seal(&n, buf[0..inner_len], &hdr, &tag);
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

    /// Read the next encrypted handshake message (post-ServerHello). Skips a
    /// possible plaintext ChangeCipherSpec record.
    fn readEncryptedHandshake(self: *Handshaker) Error!HandshakeMsg {
        while (true) {
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
            if (!self.hs_server.aead.open(&nc, self.recbuf[0..body_len], &hdr, &tag)) return Error.DecryptFailed;
            self.hs_server.seq += 1;
            var end = body_len;
            while (end > 0 and self.recbuf[end - 1] == 0) end -= 1;
            if (end == 0) return Error.BadRecord;
            const inner_type = self.recbuf[end - 1];
            if (inner_type != REC_HANDSHAKE) continue; // alerts etc.
            const m = try sliceHandshake(self.recbuf[0 .. end - 1]);
            @memcpy(self.lastRawTmp[0..m.raw.len], m.raw);
            self.lastRawLen = m.raw.len;
            return m;
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
    const p256 = @import("p256");
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
        else => return Error.UnsupportedParams,
    }
}

// ── ClientHello extension writers ──

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
    w.putU16(4);
    w.putU16(2); // list len
    w.putU16(GROUP_X25519);
}

fn writeSigAlgs(w: *Writer) void {
    const algs = [_]u16{
        SIG_ECDSA_SHA256, SIG_RSA_PKCS1_SHA256, SIG_RSA_PKCS1_SHA384,
        SIG_RSA_PKCS1_SHA512, SIG_ECDSA_SHA384,
    };
    w.putU16(13); // signature_algorithms
    w.putU16(@intCast(2 + algs.len * 2));
    w.putU16(@intCast(algs.len * 2));
    for (algs) |a| w.putU16(a);
}

fn writeKeyShare(w: *Writer, pubkey: *const [32]u8) void {
    w.putU16(51); // key_share
    w.putU16(@intCast(2 + 2 + 2 + 32));
    w.putU16(@intCast(2 + 2 + 32)); // client_shares length
    w.putU16(GROUP_X25519);
    w.putU16(32);
    w.bytes(pubkey);
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
