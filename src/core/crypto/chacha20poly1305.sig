// ChaCha20-Poly1305 AEAD — RFC 8439
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Implements the TLS 1.3 / RFC 8439 AEAD construction:
//   - ChaCha20 stream cipher (20 rounds, 256-bit key, 96-bit nonce, 32-bit counter)
//   - Poly1305 one-time authenticator (keyed from ChaCha20 block 0)
//   - seal/open over AAD || pad || ciphertext || pad || len64(AAD) || len64(CT)
//
// All buffers are caller-owned; encryption is in place. Verified against the
// RFC 8439 worked examples (Sections 2.3.2, 2.5.2, 2.8.2).

const std = @import("std");

pub const KEY_LEN = 32;
pub const NONCE_LEN = 12;
pub const TAG_LEN = 16;

// ── ChaCha20 (RFC 8439 Section 2.3) ──────────────────────────────────────────

inline fn rotl32(x: u32, comptime n: u5) u32 {
    return (x << n) | (x >> @as(u5, @intCast(32 - @as(u6, n))));
}

inline fn qr(s: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    s[a] +%= s[b]; s[d] ^= s[a]; s[d] = rotl32(s[d], 16);
    s[c] +%= s[d]; s[b] ^= s[c]; s[b] = rotl32(s[b], 12);
    s[a] +%= s[b]; s[d] ^= s[a]; s[d] = rotl32(s[d], 8);
    s[c] +%= s[d]; s[b] ^= s[c]; s[b] = rotl32(s[b], 7);
}

fn u32le(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

/// Produce one 64-byte ChaCha20 keystream block for the given counter.
fn chachaBlock(key: *const [32]u8, counter: u32, nonce: *const [12]u8, out: *[64]u8) void {
    const consts = [_]u32{ 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 };
    var state: [16]u32 = undefined;
    state[0] = consts[0]; state[1] = consts[1]; state[2] = consts[2]; state[3] = consts[3];
    var i: usize = 0;
    while (i < 8) : (i += 1) state[4 + i] = u32le(key[i * 4 ..][0..4]);
    state[12] = counter;
    state[13] = u32le(nonce[0..4]);
    state[14] = u32le(nonce[4..8]);
    state[15] = u32le(nonce[8..12]);

    var work: [16]u32 = state;
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        qr(&work, 0, 4, 8, 12);
        qr(&work, 1, 5, 9, 13);
        qr(&work, 2, 6, 10, 14);
        qr(&work, 3, 7, 11, 15);
        qr(&work, 0, 5, 10, 15);
        qr(&work, 1, 6, 11, 12);
        qr(&work, 2, 7, 8, 13);
        qr(&work, 3, 4, 9, 14);
    }
    i = 0;
    while (i < 16) : (i += 1) {
        const v = work[i] +% state[i];
        out[i * 4 + 0] = @intCast(v & 0xFF);
        out[i * 4 + 1] = @intCast((v >> 8) & 0xFF);
        out[i * 4 + 2] = @intCast((v >> 16) & 0xFF);
        out[i * 4 + 3] = @intCast((v >> 24) & 0xFF);
    }
}

/// ChaCha20 encrypt/decrypt (symmetric) in place, starting at `counter`.
fn chacha20Xor(key: *const [32]u8, counter: u32, nonce: *const [12]u8, data: []u8) void {
    var block: [64]u8 = undefined;
    var ctr = counter;
    var off: usize = 0;
    while (off < data.len) {
        chachaBlock(key, ctr, nonce, &block);
        const n = @min(@as(usize, 64), data.len - off);
        var j: usize = 0;
        while (j < n) : (j += 1) data[off + j] ^= block[j];
        off += n;
        ctr +%= 1;
    }
}

// ── Poly1305 (RFC 8439 Section 2.5) ──────────────────────────────────────────
//
// 5 x 26-bit limb implementation of the mod 2^130-5 accumulator.

const Poly1305 = struct {
    r: [5]u32 = @splat(0),
    h: [5]u32 = @splat(0),
    pad: [4]u32 = @splat(0),
    leftover: usize = 0,
    buffer: [16]u8 = @splat(0),

    fn init(key: *const [32]u8) Poly1305 {
        var p = Poly1305{};
        // r &= 0xffffffc0ffffffc0ffffffc0fffffff (clamp)
        const t0 = u32le(key[0..4]);
        const t1 = u32le(key[4..8]);
        const t2 = u32le(key[8..12]);
        const t3 = u32le(key[12..16]);
        p.r[0] = t0 & 0x3ffffff;
        p.r[1] = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03;
        p.r[2] = ((t1 >> 20) | (t2 << 12)) & 0x3ffc0ff;
        p.r[3] = ((t2 >> 14) | (t3 << 18)) & 0x3f03fff;
        p.r[4] = (t3 >> 8) & 0x00fffff;
        p.pad[0] = u32le(key[16..20]);
        p.pad[1] = u32le(key[20..24]);
        p.pad[2] = u32le(key[24..28]);
        p.pad[3] = u32le(key[28..32]);
        return p;
    }

    fn blocks(self: *Poly1305, data: []const u8, final: bool) void {
        const hibit: u32 = if (final) 0 else (1 << 24);
        const r0 = self.r[0]; const r1 = self.r[1]; const r2 = self.r[2]; const r3 = self.r[3]; const r4 = self.r[4];
        const s1 = r1 * 5; const s2 = r2 * 5; const s3 = r3 * 5; const s4 = r4 * 5;
        var h0 = self.h[0]; var h1 = self.h[1]; var h2 = self.h[2]; var h3 = self.h[3]; var h4 = self.h[4];
        var off: usize = 0;
        while (off + 16 <= data.len) : (off += 16) {
            const b = data[off..][0..16];
            h0 +%= u32le(b[0..4]) & 0x3ffffff;
            h1 +%= ((u32le(b[3..7]) >> 2)) & 0x3ffffff;
            h2 +%= ((u32le(b[6..10]) >> 4)) & 0x3ffffff;
            h3 +%= ((u32le(b[9..13]) >> 6)) & 0x3ffffff;
            h4 +%= (u32le(b[12..16]) >> 8) | hibit;
            mulReduce(&h0, &h1, &h2, &h3, &h4, r0, r1, r2, r3, r4, s1, s2, s3, s4);
        }
        self.h[0] = h0; self.h[1] = h1; self.h[2] = h2; self.h[3] = h3; self.h[4] = h4;
    }

    fn update(self: *Poly1305, data: []const u8) void {
        var d = data;
        if (self.leftover != 0) {
            const want = @min(16 - self.leftover, d.len);
            var k: usize = 0;
            while (k < want) : (k += 1) self.buffer[self.leftover + k] = d[k];
            self.leftover += want;
            d = d[want..];
            if (self.leftover < 16) return;
            self.blocks(self.buffer[0..16], false);
            self.leftover = 0;
        }
        const full = d.len - (d.len % 16);
        if (full != 0) self.blocks(d[0..full], false);
        d = d[full..];
        var k: usize = 0;
        while (k < d.len) : (k += 1) self.buffer[k] = d[k];
        self.leftover = d.len;
    }

    fn finish(self: *Poly1305, mac: *[16]u8) void {
        if (self.leftover != 0) {
            var i = self.leftover;
            self.buffer[i] = 1; i += 1;
            while (i < 16) : (i += 1) self.buffer[i] = 0;
            self.blocks(self.buffer[0..16], true);
        }
        finalize(self, mac);
    }
};

fn mulReduce(h0: *u32, h1: *u32, h2: *u32, h3: *u32, h4: *u32, r0: u32, r1: u32, r2: u32, r3: u32, r4: u32, s1: u32, s2: u32, s3: u32, s4: u32) void {
    const H0: u64 = h0.*; const H1: u64 = h1.*; const H2: u64 = h2.*; const H3: u64 = h3.*; const H4: u64 = h4.*;
    const d0: u64 = H0 * r0 + H1 * s4 + H2 * s3 + H3 * s2 + H4 * s1;
    var d1: u64 = H0 * r1 + H1 * r0 + H2 * s4 + H3 * s3 + H4 * s2;
    var d2: u64 = H0 * r2 + H1 * r1 + H2 * r0 + H3 * s4 + H4 * s3;
    var d3: u64 = H0 * r3 + H1 * r2 + H2 * r1 + H3 * r0 + H4 * s4;
    var d4: u64 = H0 * r4 + H1 * r3 + H2 * r2 + H3 * r1 + H4 * r0;
    var c: u64 = 0;
    c = d0 >> 26; const n0: u32 = @intCast(d0 & 0x3ffffff); d1 += c;
    c = d1 >> 26; const n1: u32 = @intCast(d1 & 0x3ffffff); d2 += c;
    c = d2 >> 26; const n2: u32 = @intCast(d2 & 0x3ffffff); d3 += c;
    c = d3 >> 26; const n3: u32 = @intCast(d3 & 0x3ffffff); d4 += c;
    c = d4 >> 26; const n4: u32 = @intCast(d4 & 0x3ffffff);
    var nn0: u32 = n0 + @as(u32, @intCast(c)) * 5;
    const cc = nn0 >> 26; nn0 &= 0x3ffffff;
    h0.* = nn0;
    h1.* = n1 + cc;
    h2.* = n2;
    h3.* = n3;
    h4.* = n4;
}

fn finalize(self: *Poly1305, mac: *[16]u8) void {
    var h0 = self.h[0]; var h1 = self.h[1]; var h2 = self.h[2]; var h3 = self.h[3]; var h4 = self.h[4];
    // fully carry h
    var c: u32 = h1 >> 26; h1 &= 0x3ffffff;
    h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
    h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
    h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
    h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
    h1 += c;
    // compute h + -p
    var g0 = h0 +% 5; c = g0 >> 26; g0 &= 0x3ffffff;
    var g1 = h1 +% c; c = g1 >> 26; g1 &= 0x3ffffff;
    var g2 = h2 +% c; c = g2 >> 26; g2 &= 0x3ffffff;
    var g3 = h3 +% c; c = g3 >> 26; g3 &= 0x3ffffff;
    const g4 = h4 +% c -% (1 << 26);
    // select h if h < p, else g (constant-time)
    var mask: u32 = (g4 >> 31) -% 1; // 0xffffffff if g4 did NOT borrow
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask;
    const g4m = g4 & mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0;
    h1 = (h1 & mask) | g1;
    h2 = (h2 & mask) | g2;
    h3 = (h3 & mask) | g3;
    h4 = (h4 & mask) | g4m;
    // h = h % 2^128
    var f0: u64 = (@as(u64, h0) | (@as(u64, h1) << 26)) & 0xffffffff;
    var f1: u64 = ((@as(u64, h1) >> 6) | (@as(u64, h2) << 20)) & 0xffffffff;
    var f2: u64 = ((@as(u64, h2) >> 12) | (@as(u64, h3) << 14)) & 0xffffffff;
    var f3: u64 = ((@as(u64, h3) >> 18) | (@as(u64, h4) << 8)) & 0xffffffff;
    // mac = (h + pad) % 2^128
    var fc: u64 = 0;
    f0 += @as(u64, self.pad[0]); fc = f0 >> 32; f0 &= 0xffffffff;
    f1 += @as(u64, self.pad[1]) + fc; fc = f1 >> 32; f1 &= 0xffffffff;
    f2 += @as(u64, self.pad[2]) + fc; fc = f2 >> 32; f2 &= 0xffffffff;
    f3 += @as(u64, self.pad[3]) + fc; f3 &= 0xffffffff;
    putU32le(mac[0..4], @intCast(f0));
    putU32le(mac[4..8], @intCast(f1));
    putU32le(mac[8..12], @intCast(f2));
    putU32le(mac[12..16], @intCast(f3));
}

fn putU32le(b: *[4]u8, v: u32) void {
    b[0] = @intCast(v & 0xFF);
    b[1] = @intCast((v >> 8) & 0xFF);
    b[2] = @intCast((v >> 16) & 0xFF);
    b[3] = @intCast((v >> 24) & 0xFF);
}

// ── AEAD (RFC 8439 Section 2.8) ──────────────────────────────────────────────

fn putU64le(b: *[8]u8, v: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) b[i] = @intCast((v >> @as(u6, @intCast(i * 8))) & 0xFF);
}

/// Compute the Poly1305 tag over the AEAD-framed (aad, ciphertext).
fn poly1305Mac(otk: *const [32]u8, aad: []const u8, ct: []const u8, tag: *[16]u8) void {
    var p = Poly1305.init(otk);
    p.update(aad);
    if (aad.len % 16 != 0) {
        const padlen = 16 - (aad.len % 16);
        const zeros: [16]u8 = @splat(0);
        p.update(zeros[0..padlen]);
    }
    p.update(ct);
    if (ct.len % 16 != 0) {
        const padlen = 16 - (ct.len % 16);
        const zeros: [16]u8 = @splat(0);
        p.update(zeros[0..padlen]);
    }
    var lens: [16]u8 = undefined;
    putU64le(lens[0..8], @intCast(aad.len));
    putU64le(lens[8..16], @intCast(ct.len));
    p.update(&lens);
    p.finish(tag);
}

/// Derive the Poly1305 one-time key from ChaCha20 block 0.
fn poly1305KeyGen(key: *const [32]u8, nonce: *const [12]u8, otk: *[32]u8) void {
    var block: [64]u8 = undefined;
    chachaBlock(key, 0, nonce, &block);
    @memcpy(otk, block[0..32]);
}

/// AEAD seal: encrypt `plaintext` in place (ChaCha20 from counter 1), write tag.
pub fn seal(key: *const [KEY_LEN]u8, nonce: *const [NONCE_LEN]u8, plaintext: []u8, aad: []const u8, tag_out: *[TAG_LEN]u8) void {
    var otk: [32]u8 = undefined;
    poly1305KeyGen(key, nonce, &otk);
    chacha20Xor(key, 1, nonce, plaintext);
    poly1305Mac(&otk, aad, plaintext, tag_out);
}

/// AEAD open: verify tag, then decrypt in place. Returns false on auth failure
/// (and zeroes the buffer).
pub fn open(key: *const [KEY_LEN]u8, nonce: *const [NONCE_LEN]u8, ciphertext: []u8, aad: []const u8, tag: *const [TAG_LEN]u8) bool {
    var otk: [32]u8 = undefined;
    poly1305KeyGen(key, nonce, &otk);
    var expected: [16]u8 = undefined;
    poly1305Mac(&otk, aad, ciphertext, &expected);
    var diff: u8 = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) diff |= expected[i] ^ tag[i];
    if (diff != 0) { @memset(ciphertext, 0); return false; }
    chacha20Xor(key, 1, nonce, ciphertext);
    return true;
}

// ── Tests (RFC 8439 vectors) ─────────────────────────────────────────────────
const testing = std.testing;

test "chacha20: RFC 8439 2.3.2 block function" {
    var key: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) key[i] = @intCast(i);
    const nonce = [12]u8{ 0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0 };
    var out: [64]u8 = undefined;
    chachaBlock(&key, 1, &nonce, &out);
    // First 4 bytes of the RFC 8439 2.3.2 keystream block: 10 f1 e7 e4
    try testing.expectEqual(@as(u8, 0x10), out[0]);
    try testing.expectEqual(@as(u8, 0xf1), out[1]);
    try testing.expectEqual(@as(u8, 0xe7), out[2]);
    try testing.expectEqual(@as(u8, 0xe4), out[3]);
}

test "chacha20: RFC 8439 2.4.2 encryption" {
    var key: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) key[i] = @intCast(i);
    const nonce = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0 };
    const plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var buf: [114]u8 = undefined;
    @memcpy(&buf, plaintext);
    chacha20Xor(&key, 1, &nonce, &buf);
    // RFC 8439 2.4.2 ciphertext first bytes: 6e 2e 35 9a
    try testing.expectEqual(@as(u8, 0x6e), buf[0]);
    try testing.expectEqual(@as(u8, 0x2e), buf[1]);
    try testing.expectEqual(@as(u8, 0x35), buf[2]);
    try testing.expectEqual(@as(u8, 0x9a), buf[3]);
    // round-trip
    chacha20Xor(&key, 1, &nonce, &buf);
    try testing.expectEqualSlices(u8, plaintext, &buf);
}

test "poly1305: RFC 8439 2.5.2 MAC" {
    const key = [32]u8{
        0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33, 0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8,
        0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd, 0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b,
    };
    const msg = "Cryptographic Forum Research Group";
    var p = Poly1305.init(&key);
    p.update(msg);
    var tag: [16]u8 = undefined;
    p.finish(&tag);
    const expected = [16]u8{
        0xa8, 0x06, 0x1d, 0xc1, 0x30, 0x51, 0x36, 0xc6, 0xc2, 0x2b, 0x8b, 0xaf, 0x0c, 0x01, 0x27, 0xa9,
    };
    try testing.expectEqualSlices(u8, &expected, &tag);
}

test "aead: RFC 8439 2.8.2 seal matches vector" {
    const key = [32]u8{
        0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
    };
    const nonce = [12]u8{ 0x07, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 };
    const aad = [_]u8{ 0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7 };
    const plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var buf: [114]u8 = undefined;
    @memcpy(&buf, plaintext);
    var tag: [16]u8 = undefined;
    seal(&key, &nonce, &buf, &aad, &tag);
    // RFC 8439 2.8.2 ciphertext starts d3 1a 8d 34; tag = 1a:e1:0b:59:... 06:91
    try testing.expectEqual(@as(u8, 0xd3), buf[0]);
    try testing.expectEqual(@as(u8, 0x1a), buf[1]);
    try testing.expectEqual(@as(u8, 0x8d), buf[2]);
    try testing.expectEqual(@as(u8, 0x34), buf[3]);
    const expected_tag = [16]u8{
        0x1a, 0xe1, 0x0b, 0x59, 0x4f, 0x09, 0xe2, 0x6a, 0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60, 0x06, 0x91,
    };
    try testing.expectEqualSlices(u8, &expected_tag, &tag);
}

test "aead: open round-trip and tamper rejection" {
    const key: [32]u8 = @splat(7);
    const nonce: [12]u8 = @splat(3);
    const aad = [_]u8{ 1, 2, 3, 4 };
    var buf = [_]u8{ 10, 20, 30, 40, 50, 60, 70 };
    const orig = buf;
    var tag: [16]u8 = undefined;
    seal(&key, &nonce, &buf, &aad, &tag);
    const ok = open(&key, &nonce, &buf, &aad, &tag);
    try testing.expect(ok);
    try testing.expectEqualSlices(u8, &orig, &buf);
    // tamper
    seal(&key, &nonce, &buf, &aad, &tag);
    tag[5] ^= 0x80;
    try testing.expect(!open(&key, &nonce, &buf, &aad, &tag));
}
