//! TLS 1.3 record framing and protection for caller-owned stream buffers.
//! The TLS handshake and socket remain the caller's responsibility.
const std = @import("std");
const gcm = @import("gcm");
const chacha = @import("chacha20poly1305");
const hkdf = @import("hkdf");
const keysched = @import("tls13_keys");
const keysched384 = @import("keysched384.sig");

pub const header_bytes = 5;
pub const max_plaintext_bytes = 1 << 14;
pub const max_ciphertext_bytes = max_plaintext_bytes + 256;
const max_inner_bytes = max_plaintext_bytes + 1;
// RFC 9846 §4.7.3 limits the sending epoch. The session tracks updates.
pub const max_send_key_updates: u64 = (1 << 48) - 1;
// Conservatively below the 2^24.5 full-size record limit of RFC 9846 §5.5.
const aes_record_limit: u64 = 1 << 24;

pub const ContentType = enum(u8) { alert = 21, handshake = 22, application_data = 23 };

pub const Error = error{
    BadRecord, RecordOverflow, UnexpectedMessage, BufferTooSmall,
    UnsupportedCipherSuite, InvalidSecret, DecryptFailed, KeyUseLimit,
};

pub const Frame = union(enum) {
    /// Total bytes needed in the caller's retained prefix.
    incomplete: usize,
    /// Exact bytes occupied by the first record, including its header.
    complete: usize,
};

pub fn bodyLength(header: *const [header_bytes]u8) error{ BadRecord, RecordOverflow }!usize {
    const length = (@as(usize, header[3]) << 8) | header[4];
    if (length == 0) return error.BadRecord;
    if (length > max_ciphertext_bytes) return error.RecordOverflow;
    return length;
}

/// Inspect accumulated stream bytes without copying or consuming any input.
/// The handshake decides which record types it accepts in its current state.
pub fn frame(input: []const u8) error{ BadRecord, RecordOverflow }!Frame {
    if (input.len < header_bytes) return .{ .incomplete = header_bytes };
    const total = header_bytes + try bodyLength(input[0..header_bytes]);
    return if (input.len < total) .{ .incomplete = total } else .{ .complete = total };
}

const Inner = struct { content_type: u8, content: []const u8 };

pub fn decodeInner(plaintext: []const u8) error{BadRecord}!Inner {
    var end = plaintext.len;
    while (end > 0 and plaintext[end - 1] == 0) end -= 1;
    if (end == 0) return error.BadRecord;
    return .{ .content_type = plaintext[end - 1], .content = plaintext[0 .. end - 1] };
}

pub const Protected = struct { content_type: ContentType, content: []const u8 };

fn validContent(content_type: ContentType, length: usize) bool {
    return switch (content_type) {
        .alert => length == 2,
        .handshake => length != 0,
        .application_data => true,
    };
}

/// AEAD algorithm negotiated for the session.
pub const Aead = enum { aes128_gcm, aes256_gcm, chacha20_poly1305 };
pub const HashId = enum { sha256, sha384 };

/// Cipher-suite descriptor. The server selects one of these in ServerHello.
pub const Suite = struct {
    id: u16,
    hash: HashId,
    aead: Aead,
    key_len: usize,
    hash_len: usize,
};

pub const SUITE_AES128: Suite = .{ .id = 0x1301, .hash = .sha256, .aead = .aes128_gcm, .key_len = 16, .hash_len = 32 };
pub const SUITE_AES256: Suite = .{ .id = 0x1302, .hash = .sha384, .aead = .aes256_gcm, .key_len = 32, .hash_len = 48 };
pub const SUITE_CHACHA: Suite = .{ .id = 0x1303, .hash = .sha256, .aead = .chacha20_poly1305, .key_len = 32, .hash_len = 32 };

pub fn suiteById(id: u16) ?Suite {
    if (id == SUITE_AES128.id) return SUITE_AES128;
    if (id == SUITE_AES256.id) return SUITE_AES256;
    if (id == SUITE_CHACHA.id) return SUITE_CHACHA;
    return null;
}

/// Create the keys for one direction from the exact negotiated traffic secret.
pub fn keysForSuite(id: u16, secret: []const u8) Error!RecordKeys {
    const suite = suiteById(id) orelse return error.UnsupportedCipherSuite;
    if (secret.len != suite.hash_len) return error.InvalidSecret;
    return RecordKeys.initSuite(suite, secret);
}

/// AEAD record protection state for one direction. Holds whichever AEAD the
/// negotiated suite selected; the per-record nonce construction is identical
/// across all three (RFC 8446 Section 5.3).
pub const RecordKeys = struct {
    aead: Aead = .aes128_gcm,
    gcm128: gcm.Gcm = undefined,
    gcm256: gcm.Gcm256 = undefined,
    chacha_key: [32]u8 = undefined,
    iv: [12]u8 = @splat(0),
    seq: u64 = 0,

    /// AES-128-GCM-SHA256: derive the 16-byte key + 12-byte iv via the
    /// SHA-256 schedule and build AES-128-GCM.
    pub fn init(secret: *const [32]u8) RecordKeys {
        var key: [16]u8 = undefined;
        var iv: [12]u8 = undefined;
        keysched.deriveTrafficKeys(secret, &key, &iv);
        const rk: RecordKeys = .{ .aead = .aes128_gcm, .gcm128 = gcm.Gcm.init(&key), .iv = iv };
        std.crypto.secureZero(u8, &key);
        return rk;
    }

    /// Build record keys for an arbitrary suite from its traffic secret.
    /// `secret` is hash_len bytes (32 for SHA-256 suites, 48 for SHA-384).
    pub fn initSuite(suite: Suite, secret: []const u8) RecordKeys {
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
    pub fn nonce(self: *const RecordKeys) [12]u8 {
        var n = self.iv;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const shift: u6 = @intCast(i * 8); // i=0 → LSB
            n[11 - i] ^= @truncate(self.seq >> shift);
        }
        return n;
    }

    /// Seal plaintext in place and write the tag (dispatch on AEAD).
    pub fn seal(self: *const RecordKeys, n: *const [12]u8, pt: []u8, aad: []const u8, tag: *[16]u8) void {
        switch (self.aead) {
            .aes128_gcm => self.gcm128.seal(n, pt, aad, tag),
            .aes256_gcm => self.gcm256.seal(n, pt, aad, tag),
            .chacha20_poly1305 => chacha.seal(&self.chacha_key, n, pt, aad, tag),
        }
    }

    /// Open ciphertext in place; returns false on auth failure (dispatch on AEAD).
    pub fn open(self: *const RecordKeys, n: *const [12]u8, ct: []u8, aad: []const u8, tag: *const [16]u8) bool {
        return switch (self.aead) {
            .aes128_gcm => self.gcm128.open(n, ct, aad, tag),
            .aes256_gcm => self.gcm256.open(n, ct, aad, tag),
            .chacha20_poly1305 => chacha.open(&self.chacha_key, n, ct, aad, tag),
        };
    }

    /// The session may reserve its last send record for KeyUpdate or closure.
    pub fn remainingSendRecords(self: *const RecordKeys) u64 {
        const limit: u64 = switch (self.aead) {
            .aes128_gcm, .aes256_gcm => aes_record_limit,
            .chacha20_poly1305 => std.math.maxInt(u64),
        };
        return limit -| self.seq;
    }

    /// Protect content already written at offset header_bytes in caller storage.
    /// The returned prefix contains the header, encrypted body and tag.
    pub fn sealProtected(self: *RecordKeys, output: []u8, content_type: ContentType, content_len: usize, padding: usize) Error![]const u8 {
        if (self.remainingSendRecords() == 0) return error.KeyUseLimit;
        if (content_len > max_plaintext_bytes or padding > max_plaintext_bytes - content_len) return error.RecordOverflow;
        if (!validContent(content_type, content_len)) return error.UnexpectedMessage;
        const inner_len = content_len + 1 + padding;
        const body_len = inner_len + gcm.TAG_LEN;
        const total = header_bytes + body_len;
        if (output.len < total) return error.BufferTooSmall;

        const header: *[header_bytes]u8 = output[0..header_bytes];
        header.* = .{ @intFromEnum(ContentType.application_data), 0x03, 0x03, @intCast(body_len >> 8), @truncate(body_len) };
        const inner = output[header_bytes..][0..inner_len];
        inner[content_len] = @intFromEnum(content_type);
        @memset(inner[content_len + 1 ..], 0);
        const tag: *[gcm.TAG_LEN]u8 = output[header_bytes + inner_len ..][0..gcm.TAG_LEN];
        const n = self.nonce();
        self.seal(&n, inner, header, tag);
        self.seq += 1;
        return output[0..total];
    }

    /// Open exactly one complete record in place. The returned content borrows
    /// the input until the caller reuses it. The session closes on open errors.
    pub fn openProtected(self: *RecordKeys, input: []u8) Error!Protected {
        if (self.seq == std.math.maxInt(u64)) return error.KeyUseLimit;
        if (input.len < header_bytes) return error.BadRecord;
        const header = input[0..header_bytes];
        const body_len = try bodyLength(header);
        if (input.len != header_bytes + body_len or body_len <= gcm.TAG_LEN) return error.BadRecord;
        if (header[0] != @intFromEnum(ContentType.application_data)) return error.UnexpectedMessage;
        if (header[1] != 0x03 or header[2] != 0x03) return error.BadRecord;
        const inner_len = body_len - gcm.TAG_LEN;
        if (inner_len > max_inner_bytes) return error.RecordOverflow;
        const inner = input[header_bytes..][0..inner_len];
        const tag: *const [gcm.TAG_LEN]u8 = input[header_bytes + inner_len ..][0..gcm.TAG_LEN];
        const n = self.nonce();
        if (!self.open(&n, inner, header, tag)) return error.DecryptFailed;
        self.seq += 1;
        const decoded = decodeInner(inner) catch return error.UnexpectedMessage;
        const content_type: ContentType = switch (decoded.content_type) {
            @intFromEnum(ContentType.alert) => .alert,
            @intFromEnum(ContentType.handshake) => .handshake,
            @intFromEnum(ContentType.application_data) => .application_data,
            else => return error.UnexpectedMessage,
        };
        if (!validContent(content_type, decoded.content.len)) return error.UnexpectedMessage;
        return .{ .content_type = content_type, .content = decoded.content };
    }
};

/// secret_{N+1} = HKDF-Expand-Label(secret_N, "traffic upd", "", Hash.length)
/// (RFC 8446 §7.2), in place over the suite's hash_len bytes of `secret`.
pub fn nextTrafficSecret(suite: Suite, secret: *[48]u8) void {
    var next: [48]u8 = undefined;
    if (suite.hash == .sha384) {
        keysched384.expandLabel(secret, "traffic upd", "", next[0..48]);
    } else {
        _ = hkdf.expandLabel(secret[0..32], "traffic upd", "", next[0..32], 32);
    }
    @memcpy(secret[0..suite.hash_len], next[0..suite.hash_len]);
    std.crypto.secureZero(u8, &next);
}

test "record framing reports every partial prefix and the first coalesced record" {
    const testing = std.testing;
    const first = [_]u8{ 22, 3, 1, 0, 3, 1, 2, 3 };
    const both = first ++ [_]u8{ 20, 3, 3, 0, 1, 1 };
    for (0..first.len) |count| {
        const needed: usize = if (count < header_bytes) header_bytes else first.len;
        try testing.expectEqual(Frame{ .incomplete = needed }, try frame(first[0..count]));
    }
    try testing.expectEqual(Frame{ .complete = first.len }, try frame(&both));
    try testing.expectEqual(Frame{ .complete = 6 }, try frame(both[first.len..]));
    try testing.expectError(error.BadRecord, frame(&.{ 22, 3, 3, 0, 0 }));
    try testing.expectError(error.RecordOverflow, frame(&.{ 23, 3, 3, 0x41, 1 }));
    try testing.expectEqual(Frame{ .incomplete = max_ciphertext_bytes + header_bytes }, try frame(&.{ 23, 3, 3, 0x41, 0 }));
}

test "RFC 8448 simple 1-RTT application records match in both directions" {
    const testing = std.testing;
    // RFC 8448 §3. The server uses sequence 1 after its NewSessionTicket.
    const traces = [_]struct { seq: u64, secret: []const u8, ciphertext: []const u8 }{
        .{
            .seq = 0,
            .secret = "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5",
            .ciphertext = "1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab3f2b9819a8a5b46b395bd54a9a20441e2b62974e1f5a6292a2977014bd1e3deae63aeebb21694915e4",
        },
        .{
            .seq = 1,
            .secret = "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643",
            .ciphertext = "17030300432e937e11ef4ac740e538ad36005fc4a46932fc3225d05f82aa1b36e30efaf97d90e6dffc602dcb501a59a8fcc49c4bf2e5f0a21c0047c2abf332540dd032e167c2955d",
        },
    };
    var content: [50]u8 = undefined;
    for (&content, 0..) |*byte, index| byte.* = @intCast(index);
    for (traces) |trace| {
        var secret: [32]u8 = undefined;
        var ciphertext: [72]u8 = undefined;
        _ = try std.fmt.hexToBytes(&secret, trace.secret);
        _ = try std.fmt.hexToBytes(&ciphertext, trace.ciphertext);
        var sender = try keysForSuite(SUITE_AES128.id, &secret);
        sender.seq = trace.seq;
        var output: [72]u8 = undefined;
        @memcpy(output[header_bytes..][0..content.len], &content);
        try testing.expectEqualSlices(u8, &ciphertext, try sender.sealProtected(&output, .application_data, content.len, 0));
        try testing.expectEqual(trace.seq + 1, sender.seq);
        var receiver = try keysForSuite(SUITE_AES128.id, &secret);
        receiver.seq = trace.seq;
        const opened = try receiver.openProtected(&ciphertext);
        try testing.expectEqual(ContentType.application_data, opened.content_type);
        try testing.expectEqualSlices(u8, &content, opened.content);
        try testing.expectEqual(trace.seq + 1, receiver.seq);
    }
}

test "protected records authenticate before exposing padded application bytes" {
    const testing = std.testing;
    const secret: [32]u8 = @splat(0x59);
    var sender = try keysForSuite(SUITE_CHACHA.id, &secret);
    var receiver = try keysForSuite(SUITE_CHACHA.id, &secret);
    var buffer: [35]u8 = undefined;
    @memcpy(buffer[header_bytes..][0..2], "a\x00");
    const sealed = try sender.sealProtected(&buffer, .application_data, 2, 11);
    var tampered = buffer;
    tampered[sealed.len - 1] ^= 1;
    const original = tampered;
    try testing.expectError(error.DecryptFailed, receiver.openProtected(tampered[0..sealed.len]));
    try testing.expectEqualSlices(u8, &original, &tampered);
    try testing.expectEqual(@as(u64, 0), receiver.seq);
    const replay = buffer;
    const plaintext = try receiver.openProtected(buffer[0..sealed.len]);
    try testing.expectEqualSlices(u8, "a\x00", plaintext.content);
    var replayed = replay;
    try testing.expectError(error.DecryptFailed, receiver.openProtected(replayed[0..sealed.len]));
}

test "protected records enforce the exact frame and authenticated content shape" {
    const testing = std.testing;
    const secret: [32]u8 = @splat(0x26);
    const sender = try keysForSuite(SUITE_AES128.id, &secret);
    var receiver = try keysForSuite(SUITE_AES128.id, &secret);
    var record: [header_bytes + 2 + gcm.TAG_LEN]u8 = @splat(0);
    const header = record[0..header_bytes];
    header.* = .{ 23, 3, 3, 0, 2 + gcm.TAG_LEN };
    try testing.expectError(error.BadRecord, receiver.openProtected(record[0 .. record.len - 1]));
    try testing.expectEqual(@as(u64, 0), receiver.seq);
    const n = sender.nonce();
    sender.seal(&n, record[header_bytes..][0..2], header, record[header_bytes + 2 ..]);
    try testing.expectError(error.UnexpectedMessage, receiver.openProtected(&record));
    try testing.expectEqual(@as(u64, 1), receiver.seq);

    var max_sender = try keysForSuite(SUITE_AES128.id, &secret);
    var max_receiver = try keysForSuite(SUITE_AES128.id, &secret);
    var maximum: [header_bytes + max_inner_bytes + gcm.TAG_LEN]u8 = undefined;
    maximum[header_bytes] = 0x55;
    const sealed = try max_sender.sealProtected(&maximum, .application_data, 1, max_plaintext_bytes - 1);
    try testing.expectEqual(maximum.len, sealed.len);
    const opened = try max_receiver.openProtected(&maximum);
    try testing.expectEqualSlices(u8, &.{0x55}, opened.content);
}

test "record lengths, secrets and key-use boundaries fail before sealing" {
    const testing = std.testing;
    const secret: [48]u8 = @splat(0x6b);
    try testing.expectError(error.UnsupportedCipherSuite, keysForSuite(0, &secret));
    try testing.expectError(error.InvalidSecret, keysForSuite(SUITE_AES256.id, secret[0..32]));
    var sender = try keysForSuite(SUITE_AES256.id, &secret);
    var buffer: [24]u8 = @splat(0x5a);
    const original = buffer;
    try testing.expectError(error.RecordOverflow, sender.sealProtected(&buffer, .application_data, max_plaintext_bytes, 1));
    try testing.expectError(error.UnexpectedMessage, sender.sealProtected(&buffer, .handshake, 0, 0));
    try testing.expectError(error.UnexpectedMessage, sender.sealProtected(&buffer, .alert, 1, 0));
    try testing.expectError(error.BufferTooSmall, sender.sealProtected(buffer[0..21], .application_data, 0, 0));
    try testing.expectEqualSlices(u8, &original, &buffer);
    try testing.expectEqual(@as(u64, 0), sender.seq);

    sender.seq = aes_record_limit - 1;
    try testing.expectEqual(@as(u64, 1), sender.remainingSendRecords());
    _ = try sender.sealProtected(&buffer, .application_data, 0, 0);
    try testing.expectEqual(@as(u64, 0), sender.remainingSendRecords());
    const sealed = buffer;
    try testing.expectError(error.KeyUseLimit, sender.sealProtected(&buffer, .application_data, 0, 0));
    try testing.expectEqualSlices(u8, &sealed, &buffer);

    var chacha_sender = try keysForSuite(SUITE_CHACHA.id, secret[0..32]);
    chacha_sender.seq = std.math.maxInt(u64) - 1;
    _ = try chacha_sender.sealProtected(&buffer, .application_data, 0, 0);
    try testing.expectError(error.KeyUseLimit, chacha_sender.sealProtected(&buffer, .application_data, 0, 0));
    try testing.expectError(error.KeyUseLimit, chacha_sender.openProtected(buffer[0..22]));
}
