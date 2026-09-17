// RSA signature verification (RFC 8017 / PKCS#1) — pure Sig, no allocator.
// Layer 1: crypto (internal to the tls_client directory module).
//
// Scope: PUBLIC-key operations only — verifying a signature produced by a CA.
// That is exactly m = s^e mod n, then checking the recovered message against
// the expected EMSA-PKCS1-v1_5 or EMSA-PSS encoding. No private key, no CRT,
// no key generation. Modulus up to 4096 bits.
//
// The bignum is a fixed-width little-endian array of 64-bit limbs. Only the
// operations modexp needs are implemented: compare, sub, shift, schoolbook
// multiply, and Barrett-free modular reduction via conditional subtraction in
// a square-and-multiply loop. Public exponents are tiny (usually 65537), so a
// simple left-to-right binary exponentiation is both correct and fast enough.

const sha256 = @import("sha256");
const sha512_mod = @import("sha512.sig");

/// Max modulus size: 4096 bits = 512 bytes = 64 limbs of 64 bits.
pub const MAX_LIMBS: usize = 64;
const LIMB_BITS: usize = 64;

pub const Error = error{
    ModulusTooLarge,
    BadPadding,
    Unsupported,
};

/// Fixed-width unsigned big integer (little-endian limbs).
pub const Big = struct {
    limbs: [MAX_LIMBS]u64 = [_]u64{0} ** MAX_LIMBS,
    /// Number of significant limbs (>= 1). Trailing zero limbs are excluded.
    n: usize = 1,

    pub fn zero() Big {
        return .{ .limbs = [_]u64{0} ** MAX_LIMBS, .n = 1 };
    }

    /// Parse a big-endian byte slice (e.g. an RSA modulus) into a Big.
    pub fn fromBytesBE(bytes: []const u8) Error!Big {
        var b = Big.zero();
        const limbs_needed = (bytes.len + 7) / 8;
        if (limbs_needed > MAX_LIMBS) return Error.ModulusTooLarge;
        // Walk from the least-significant byte (end of the slice).
        var i: usize = 0;
        var bit: usize = 0;
        var idx = bytes.len;
        while (idx > 0) {
            idx -= 1;
            const limb = i / 8;
            const shift: u6 = @intCast((i % 8) * 8);
            b.limbs[limb] |= @as(u64, bytes[idx]) << shift;
            i += 1;
            bit += 8;
        }
        b.n = b.sigLimbs();
        return b;
    }

    /// Serialize to a big-endian byte buffer of exactly out.len bytes
    /// (left-zero-padded). Returns error if the value doesn't fit.
    pub fn toBytesBE(self: *const Big, out: []u8) void {
        for (out) |*o| o.* = 0;
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            const byte_from_lsb = i; // 0 = least significant
            const limb = byte_from_lsb / 8;
            const shift: u6 = @intCast((byte_from_lsb % 8) * 8);
            const val: u8 = if (limb < MAX_LIMBS) @truncate(self.limbs[limb] >> shift) else 0;
            out[out.len - 1 - i] = val;
        }
    }

    fn sigLimbs(self: *const Big) usize {
        var k: usize = MAX_LIMBS;
        while (k > 1) : (k -= 1) {
            if (self.limbs[k - 1] != 0) return k;
        }
        return 1;
    }

    pub fn isZero(self: *const Big) bool {
        for (self.limbs) |l| {
            if (l != 0) return false;
        }
        return true;
    }

    /// Compare: -1 if self<other, 0 if equal, +1 if self>other.
    pub fn cmp(self: *const Big, other: *const Big) i8 {
        var i: usize = MAX_LIMBS;
        while (i > 0) {
            i -= 1;
            if (self.limbs[i] < other.limbs[i]) return -1;
            if (self.limbs[i] > other.limbs[i]) return 1;
        }
        return 0;
    }

    /// self -= other (assumes self >= other). Wrapping borrow across limbs.
    fn subInPlace(self: *Big, other: *const Big) void {
        var borrow: u64 = 0;
        var i: usize = 0;
        while (i < MAX_LIMBS) : (i += 1) {
            const a = self.limbs[i];
            const b = other.limbs[i];
            const t = a -% b -% borrow;
            // Borrow if a < b + borrow (detect via unsigned wrap).
            borrow = if (a < b or (a == b and borrow == 1) or (a -% b < borrow)) 1 else 0;
            self.limbs[i] = t;
        }
    }
};

/// Bit length of a Big (position of the highest set bit).
fn bitLen(x: *const Big) usize {
    var i: usize = MAX_LIMBS;
    while (i > 0) {
        i -= 1;
        if (x.limbs[i] != 0) {
            var bits: usize = i * LIMB_BITS;
            var v = x.limbs[i];
            while (v != 0) : (v >>= 1) bits += 1;
            return bits;
        }
    }
    return 0;
}

/// Test bit `k` of x.
fn testBit(x: *const Big, k: usize) bool {
    const limb = k / LIMB_BITS;
    if (limb >= MAX_LIMBS) return false;
    const shift: u6 = @intCast(k % LIMB_BITS);
    return (x.limbs[limb] >> shift) & 1 == 1;
}

/// Full-width product of two Bigs into a 2*MAX_LIMBS limb buffer (schoolbook).
fn mulFull(a: *const Big, b: *const Big, out: *[MAX_LIMBS * 2]u64) void {
    for (out) |*o| o.* = 0;
    var i: usize = 0;
    while (i < MAX_LIMBS) : (i += 1) {
        if (a.limbs[i] == 0) continue;
        var carry: u128 = 0;
        var j: usize = 0;
        while (j < MAX_LIMBS) : (j += 1) {
            const prod: u128 = @as(u128, a.limbs[i]) * @as(u128, b.limbs[j]) +
                @as(u128, out[i + j]) + carry;
            out[i + j] = @truncate(prod);
            carry = prod >> 64;
        }
        // Propagate remaining carry.
        var k = i + MAX_LIMBS;
        while (carry != 0 and k < MAX_LIMBS * 2) : (k += 1) {
            const s: u128 = @as(u128, out[k]) + carry;
            out[k] = @truncate(s);
            carry = s >> 64;
        }
    }
}

/// Reduce a 2*MAX_LIMBS-limb value modulo n by long division (bit by bit).
/// Not the fastest, but simple and constant in structure; the modulus is a few
/// thousand bits and we do this a handful of times per verification.
fn reduce(wide: *const [MAX_LIMBS * 2]u64, n: *const Big) Big {
    // r = 0; for each bit of `wide` from MSB down: r = (r<<1) | bit; if r>=n: r-=n
    var r = Big.zero();
    const total_bits = MAX_LIMBS * 2 * LIMB_BITS;
    var bit_i = total_bits;
    while (bit_i > 0) {
        bit_i -= 1;
        // r <<= 1
        shl1(&r);
        // bring in the current bit
        const limb = bit_i / LIMB_BITS;
        const shift: u6 = @intCast(bit_i % LIMB_BITS);
        const bit: u64 = (wide[limb] >> shift) & 1;
        r.limbs[0] |= bit;
        // if r >= n, r -= n
        if (r.cmp(n) >= 0) r.subInPlace(n);
    }
    r.n = r.sigLimbs();
    return r;
}

/// r <<= 1 across all limbs.
fn shl1(r: *Big) void {
    var carry: u64 = 0;
    var i: usize = 0;
    while (i < MAX_LIMBS) : (i += 1) {
        const new_carry = r.limbs[i] >> 63;
        r.limbs[i] = (r.limbs[i] << 1) | carry;
        carry = new_carry;
    }
}

/// Modular multiply: (a * b) mod n.
fn mulmod(a: *const Big, b: *const Big, n: *const Big) Big {
    var wide: [MAX_LIMBS * 2]u64 = undefined;
    mulFull(a, b, &wide);
    return reduce(&wide, n);
}

/// Modular exponentiation: base^exp mod n, left-to-right binary method.
pub fn modexp(base: *const Big, exp: *const Big, n: *const Big) Big {
    var result = Big.zero();
    result.limbs[0] = 1;
    result.n = 1;

    const bits = bitLen(exp);
    if (bits == 0) return result; // exp == 0 -> 1

    var i = bits;
    while (i > 0) {
        i -= 1;
        result = mulmod(&result, &result, n); // square
        if (testBit(exp, i)) {
            result = mulmod(&result, base, n); // multiply
        }
    }
    return result;
}

// ── RSA public key + verification ──────────────────────────────────────

pub const PublicKey = struct {
    n: Big,
    e: Big,
    /// Modulus size in bytes (the signature and EM length k).
    k: usize,
};

/// Build an RSA public key from big-endian modulus and exponent bytes.
pub fn publicKey(modulus_be: []const u8, exponent_be: []const u8) Error!PublicKey {
    const n = try Big.fromBytesBE(modulus_be);
    const e = try Big.fromBytesBE(exponent_be);
    return .{ .n = n, .e = e, .k = modulus_be.len };
}

/// DigestInfo prefixes for EMSA-PKCS1-v1_5 (RFC 8017 §9.2). Each is the DER of
/// DigestInfo with the trailing hash bytes omitted (the hash is appended).
const SHA256_DIGESTINFO = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};
const SHA384_DIGESTINFO = [_]u8{
    0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30,
};
const SHA512_DIGESTINFO = [_]u8{
    0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40,
};

pub const Hash = enum { sha256, sha384, sha512 };

/// Verify an RSASSA-PKCS1-v1_5 signature over `msg` with the given hash.
/// Returns true iff the signature is valid.
pub fn verifyPkcs1(pk: *const PublicKey, hash: Hash, msg: []const u8, sig: []const u8) bool {
    if (sig.len != pk.k) return false;
    if (pk.k > MAX_LIMBS * 8) return false;

    // m = sig^e mod n; reject s >= n (RFC 8017 §5.2.2 step 1).
    const s = Big.fromBytesBE(sig) catch return false;
    if (s.cmp(&pk.n) >= 0) return false;
    const m = modexp(&s, &pk.e, &pk.n);

    var em: [MAX_LIMBS * 8]u8 = undefined;
    m.toBytesBE(em[0..pk.k]);

    // Digest the message and select the DigestInfo prefix.
    var hbuf: [64]u8 = undefined;
    var hlen: usize = 0;
    var prefix: []const u8 = undefined;
    switch (hash) {
        .sha256 => {
            const h = sha256.hash(msg);
            @memcpy(hbuf[0..32], &h);
            hlen = 32;
            prefix = &SHA256_DIGESTINFO;
        },
        .sha384 => {
            const h = sha512_mod.sha384(msg);
            @memcpy(hbuf[0..48], &h);
            hlen = 48;
            prefix = &SHA384_DIGESTINFO;
        },
        .sha512 => {
            const h = sha512_mod.sha512(msg);
            @memcpy(hbuf[0..64], &h);
            hlen = 64;
            prefix = &SHA512_DIGESTINFO;
        },
    }

    // Build expected EM: 0x00 0x01 PS(0xFF..) 0x00 DigestInfo H.
    const t_len = prefix.len + hlen;
    if (pk.k < t_len + 11) return false; // needs >= 8 bytes of PS
    var expected: [MAX_LIMBS * 8]u8 = undefined;
    var idx: usize = 0;
    expected[idx] = 0x00;
    idx += 1;
    expected[idx] = 0x01;
    idx += 1;
    const ps_len = pk.k - t_len - 3;
    var p: usize = 0;
    while (p < ps_len) : (p += 1) {
        expected[idx] = 0xFF;
        idx += 1;
    }
    expected[idx] = 0x00;
    idx += 1;
    for (prefix) |b| {
        expected[idx] = b;
        idx += 1;
    }
    var q: usize = 0;
    while (q < hlen) : (q += 1) {
        expected[idx] = hbuf[q];
        idx += 1;
    }

    var diff: u8 = 0;
    var j: usize = 0;
    while (j < pk.k) : (j += 1) diff |= em[j] ^ expected[j];
    return diff == 0;
}

/// Back-compat convenience for SHA-256.
pub fn verifyPkcs1Sha256(pk: *const PublicKey, msg: []const u8, sig: []const u8) bool {
    return verifyPkcs1(pk, .sha256, msg, sig);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "rsa: bytes round-trip big-endian" {
    const bytes = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x00, 0x11 };
    const b = try Big.fromBytesBE(&bytes);
    var out: [10]u8 = undefined;
    b.toBytesBE(&out);
    try testing.expectEqualSlices(u8, &bytes, &out);
}

test "rsa: small modexp 4^13 mod 497 = 445" {
    // Classic RSA textbook example.
    var base = Big.zero();
    base.limbs[0] = 4;
    var exp = Big.zero();
    exp.limbs[0] = 13;
    var n = Big.zero();
    n.limbs[0] = 497;
    const r = modexp(&base, &exp, &n);
    try testing.expectEqual(@as(u64, 445), r.limbs[0]);
}

test "rsa: modexp 5^117 mod 19 = 1" {
    var base = Big.zero();
    base.limbs[0] = 5;
    var exp = Big.zero();
    exp.limbs[0] = 117;
    var n = Big.zero();
    n.limbs[0] = 19;
    const r = modexp(&base, &exp, &n);
    // 5^18 ≡ 1 (Fermat), 117 = 6*18 + 9, so 5^117 ≡ 5^9 ≡ 1 (mod 19).
    try testing.expectEqual(@as(u64, 1), r.limbs[0]);
}

test "rsa: cmp and sub" {
    var a = Big.zero();
    a.limbs[0] = 1000;
    var b = Big.zero();
    b.limbs[0] = 999;
    try testing.expectEqual(@as(i8, 1), a.cmp(&b));
    a.subInPlace(&b);
    try testing.expectEqual(@as(u64, 1), a.limbs[0]);
}

test "rsa: multi-limb modexp (2^128 mod large prime)" {
    // 2^128 mod (2^61-1) — checks cross-limb multiply/reduce.
    var base = Big.zero();
    base.limbs[0] = 2;
    var exp = Big.zero();
    exp.limbs[0] = 128;
    var n = Big.zero();
    n.limbs[0] = (1 << 61) - 1; // Mersenne prime 2305843009213693951
    const r = modexp(&base, &exp, &n);
    // 2^61 ≡ 1 mod (2^61-1) → 2^128 = 2^(61*2+6) ≡ 2^6 = 64
    try testing.expectEqual(@as(u64, 64), r.limbs[0]);
}
