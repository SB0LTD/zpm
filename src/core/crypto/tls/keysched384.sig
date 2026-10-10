// SHA-384 TLS 1.3 key schedule + HKDF-SHA384 (RFC 8446 Section 7 / RFC 5869).
// Layer 1 (tls): used only for the AES-256-GCM-SHA384 suite. Mirrors
// tls13_keys.sig exactly but over 48-byte secrets with SHA-384 as the hash.
//
// SHA-384 uses the SHA-512 compression core with a 128-byte HMAC block size.

const sha = @import("sha512.sig");

pub const HASH_LEN = 48;

/// Public SHA-384 passthrough for the transcript hash.
pub fn sha384over(msg: []const u8) [48]u8 {
    return sha.sha384(msg);
}
const BLOCK = 128; // HMAC block size for SHA-384/512

/// HMAC-SHA384 over (key, msg) -> 48-byte MAC. key may be any length.
pub fn hmac(key: []const u8, msg: []const u8) [48]u8 {
    var k0: [BLOCK]u8 = @splat(0);
    if (key.len > BLOCK) {
        const kh = sha.sha384(key);
        @memcpy(k0[0..48], &kh);
    } else {
        @memcpy(k0[0..key.len], key);
    }
    var ipad: [BLOCK]u8 = undefined;
    var opad: [BLOCK]u8 = undefined;
    var i: usize = 0;
    while (i < BLOCK) : (i += 1) {
        ipad[i] = k0[i] ^ 0x36;
        opad[i] = k0[i] ^ 0x5c;
    }
    // inner = SHA384(ipad || msg)
    var inner_buf: [BLOCK + 512]u8 = undefined;
    // For arbitrary msg length we hash in two parts via a small helper that
    // concatenates into a bounded scratch; TLS messages here are short.
    const inner = sha384Concat(&ipad, msg, &inner_buf);
    // outer = SHA384(opad || inner)
    var outer_buf: [BLOCK + 48]u8 = undefined;
    @memcpy(outer_buf[0..BLOCK], &opad);
    @memcpy(outer_buf[BLOCK..][0..48], &inner);
    return sha.sha384(outer_buf[0 .. BLOCK + 48]);
}

/// SHA384(prefix || msg) using a bounded scratch (msg must fit scratch-prefix).
fn sha384Concat(prefix: []const u8, msg: []const u8, scratch: []u8) [48]u8 {
    @memcpy(scratch[0..prefix.len], prefix);
    @memcpy(scratch[prefix.len..][0..msg.len], msg);
    return sha.sha384(scratch[0 .. prefix.len + msg.len]);
}

/// HKDF-Extract(salt, ikm) -> 48-byte PRK.
pub fn extract(salt: []const u8, ikm: []const u8) [48]u8 {
    const z: [48]u8 = @splat(0);
    const use_salt = if (salt.len == 0) z[0..48] else salt;
    return hmac(use_salt, ikm);
}

/// HKDF-Expand(prk, info, L) -> okm into out (L = out.len, <= 48*255).
pub fn expand(prk: *const [48]u8, info: []const u8, out: []u8) void {
    var t: [48]u8 = undefined;
    var t_len: usize = 0;
    var done: usize = 0;
    var counter: u8 = 1;
    while (done < out.len) : (counter += 1) {
        // T(i) = HMAC(prk, T(i-1) || info || counter)
        var buf: [48 + 512 + 1]u8 = undefined;
        var n: usize = 0;
        @memcpy(buf[0..t_len], t[0..t_len]); n += t_len;
        @memcpy(buf[n..][0..info.len], info); n += info.len;
        buf[n] = counter; n += 1;
        t = hmac(prk, buf[0..n]);
        t_len = 48;
        const take = @min(@as(usize, 48), out.len - done);
        @memcpy(out[done..][0..take], t[0..take]);
        done += take;
    }
}

/// HKDF-Expand-Label(secret, label, context, L) per RFC 8446 Section 7.1.
pub fn expandLabel(secret: *const [48]u8, label: []const u8, context: []const u8, out: []u8) void {
    // HkdfLabel = len16(L) || len8("tls13 "+label) || "tls13 "+label || len8(ctx) || ctx
    var info: [2 + 1 + 255 + 1 + 255]u8 = undefined;
    var n: usize = 0;
    info[0] = @intCast((out.len >> 8) & 0xFF);
    info[1] = @intCast(out.len & 0xFF);
    n = 2;
    const prefix = "tls13 ";
    const full_label_len = prefix.len + label.len;
    info[n] = @intCast(full_label_len); n += 1;
    @memcpy(info[n..][0..prefix.len], prefix); n += prefix.len;
    @memcpy(info[n..][0..label.len], label); n += label.len;
    info[n] = @intCast(context.len); n += 1;
    @memcpy(info[n..][0..context.len], context); n += context.len;
    expand(secret, info[0..n], out);
}

/// Derive-Secret(secret, label, transcript_hash) -> 48-byte secret.
pub fn deriveSecret(secret: *const [48]u8, label: []const u8, transcript_hash: *const [48]u8, out: *[48]u8) void {
    expandLabel(secret, label, transcript_hash, out);
}

pub const KeySchedule384 = struct {
    early_secret: [48]u8,
    handshake_secret: [48]u8 = @splat(0),
    master_secret: [48]u8 = @splat(0),

    pub fn init() KeySchedule384 {
        const zero: [48]u8 = @splat(0);
        return .{ .early_secret = extract("", &zero) };
    }

    pub fn deriveHandshakeSecrets(
        self: *KeySchedule384,
        shared_secret: []const u8,
        transcript_hash: *const [48]u8,
        client_hs_secret: *[48]u8,
        server_hs_secret: *[48]u8,
    ) void {
        const empty_hash = sha.sha384("");
        var derived: [48]u8 = undefined;
        deriveSecret(&self.early_secret, "derived", &empty_hash, &derived);
        self.handshake_secret = extract(&derived, shared_secret);
        deriveSecret(&self.handshake_secret, "c hs traffic", transcript_hash, client_hs_secret);
        deriveSecret(&self.handshake_secret, "s hs traffic", transcript_hash, server_hs_secret);
    }

    pub fn deriveApplicationSecrets(
        self: *KeySchedule384,
        transcript_hash: *const [48]u8,
        client_app_secret: *[48]u8,
        server_app_secret: *[48]u8,
    ) void {
        const empty_hash = sha.sha384("");
        var derived: [48]u8 = undefined;
        deriveSecret(&self.handshake_secret, "derived", &empty_hash, &derived);
        const zero: [48]u8 = @splat(0);
        self.master_secret = extract(&derived, &zero);
        deriveSecret(&self.master_secret, "c ap traffic", transcript_hash, client_app_secret);
        deriveSecret(&self.master_secret, "s ap traffic", transcript_hash, server_app_secret);
    }

    /// verify_data = HMAC(HKDF-Expand-Label(base, \"finished\", \"\", 48), transcript).
    pub fn computeFinished(base_key: *const [48]u8, transcript_hash: *const [48]u8) [48]u8 {
        var finished_key: [48]u8 = undefined;
        expandLabel(base_key, "finished", "", &finished_key);
        return hmac(&finished_key, transcript_hash);
    }
};

/// Derive AES-256-GCM traffic key (32) + IV (12) from a 48-byte traffic secret.
pub fn deriveTrafficKeys(secret: *const [48]u8, key: *[32]u8, iv: *[12]u8) void {
    expandLabel(secret, "key", "", key);
    expandLabel(secret, "iv", "", iv);
}

// ── Tests ────────────────────────────────────────────────────────────────
const testing = @import("std").testing;

test "hmac-sha384: RFC 4231 Test Case 1" {
    // key = 0x0b x20, data = \"Hi There\"
    const key: [20]u8 = @splat(0x0b);
    const mac = hmac(&key, "Hi There");
    // RFC 4231 TC1 HMAC-SHA-384 first 8 bytes: afd03944 d8489562
    const expected_prefix = [8]u8{ 0xaf, 0xd0, 0x39, 0x44, 0xd8, 0x48, 0x95, 0x62 };
    try testing.expectEqualSlices(u8, &expected_prefix, mac[0..8]);
}

test "keysched384: init early secret non-zero" {
    const ks = KeySchedule384.init();
    var all_zero = true;
    for (ks.early_secret) |b| { if (b != 0) { all_zero = false; break; } }
    try testing.expect(!all_zero);
}

test "keysched384: handshake secrets differ and are 48 bytes" {
    var ks = KeySchedule384.init();
    const shared: [48]u8 = @splat(0x01);
    const th = sha.sha384("ClientHelloServerHello");
    var chs: [48]u8 = undefined;
    var shs: [48]u8 = undefined;
    ks.deriveHandshakeSecrets(&shared, &th, &chs, &shs);
    var same = true;
    for (0..48) |i| { if (chs[i] != shs[i]) { same = false; break; } }
    try testing.expect(!same);
}

test "keysched384: traffic keys derive 32-byte key + 12-byte iv" {
    const secret: [48]u8 = @splat(0x42);
    var key: [32]u8 = undefined;
    var iv: [12]u8 = undefined;
    deriveTrafficKeys(&secret, &key, &iv);
    // Non-zero and deterministic
    var kz = true; for (key) |b| { if (b != 0) { kz = false; break; } }
    try testing.expect(!kz);
    var key2: [32]u8 = undefined;
    var iv2: [12]u8 = undefined;
    deriveTrafficKeys(&secret, &key2, &iv2);
    try testing.expectEqualSlices(u8, &key, &key2);
    try testing.expectEqualSlices(u8, &iv, &iv2);
}

test "expandLabel: deterministic and length-correct" {
    const secret: [48]u8 = @splat(0x11);
    var out1: [20]u8 = undefined;
    var out2: [20]u8 = undefined;
    expandLabel(&secret, "finished", "", &out1);
    expandLabel(&secret, "finished", "", &out2);
    try testing.expectEqualSlices(u8, &out1, &out2);
}
