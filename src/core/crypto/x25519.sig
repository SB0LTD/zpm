// @zpm/crypto/x25519 — Freestanding X25519 Diffie-Hellman (RFC 7748).
// Constant-time Montgomery ladder over GF(2^255-19).
// Zero allocator. Pure computation. No std dependency.

/// Compute shared secret: q = n * p (scalar multiplication on Curve25519).
pub fn scalarmult(q: *[32]u8, n: *const [32]u8, p: *const [32]u8) void {
    var z: [32]u8 = n.*;
    z[31] = (n[31] & 127) | 64;
    z[0] &= 248;

    var x: Gf = undefined;
    unpack(&x, p);
    var a: Gf = @splat(0);
    var b: Gf = x;
    var c: Gf = @splat(0);
    var d: Gf = @splat(0);
    var e: Gf = undefined;
    var f: Gf = undefined;
    a[0] = 1;
    d[0] = 1;

    var i: i32 = 254;
    while (i >= 0) : (i -= 1) {
        const r: i64 = (@as(i64, z[@intCast(@divTrunc(i, 8))]) >> @intCast(@mod(i, 8))) & 1;
        sel(&a, &b, r);
        sel(&c, &d, r);
        add(&e, &a, &c);
        sub(&a, &a, &c);
        add(&c, &b, &d);
        sub(&b, &b, &d);
        sq(&d, &e);
        sq(&f, &a);
        mul(&a, &c, &a);
        mul(&c, &b, &e);
        add(&e, &a, &c);
        sub(&a, &a, &c);
        sq(&b, &a);
        sub(&c, &d, &f);
        mul(&a, &c, &C121665);
        add(&a, &a, &d);
        mul(&c, &c, &a);
        mul(&a, &d, &f);
        mul(&d, &b, &x);
        sq(&b, &e);
        sel(&a, &b, r);
        sel(&c, &d, r);
    }
    inv(&c, &c);
    mul(&a, &a, &c);
    pack(q, &a);
}

/// X25519 base point (generator).
pub const BASEPOINT: [32]u8 = blk: {
    var bp: [32]u8 = @splat(0);
    bp[0] = 9;
    break :blk bp;
};

// ══════════════════════════════════════════════════════════════════════════════
// GF(2^255-19) arithmetic (16 limbs of 16 bits each)
// ══════════════════════════════════════════════════════════════════════════════

const Gf = [16]i64;
const C121665 = Gf{ 0xDB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

fn car(o: *Gf) void {
    for (0..16) |i| {
        o[i] += 1 << 16;
        const c = o[i] >> 16;
        if (i < 15) o[i + 1] += c - 1 else o[0] += 38 * (c - 1);
        o[i] -= c << 16;
    }
}

fn sel(p: *Gf, q: *Gf, b: i64) void {
    const c: i64 = ~(b - 1);
    for (0..16) |i| {
        const t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

fn add(o: *Gf, a: *const Gf, b: *const Gf) void {
    for (0..16) |i| o[i] = a[i] + b[i];
}
fn sub(o: *Gf, a: *const Gf, b: *const Gf) void {
    for (0..16) |i| o[i] = a[i] - b[i];
}
fn mul(o: *Gf, a: *const Gf, b: *const Gf) void {
    var t: [31]i64 = @splat(0);
    for (0..16) |i| {
        for (0..16) |j| {
            t[i + j] += a[i] * b[j];
        }
    }
    for (0..15) |i| {
        t[i] += 38 * t[i + 16];
    }
    for (0..16) |i| o[i] = t[i];
    car(o);
    car(o);
}
fn sq(o: *Gf, a: *const Gf) void { mul(o, a, a); }

fn inv(o: *Gf, inp: *const Gf) void {
    var c: Gf = inp.*;
    var a: i32 = 253;
    while (a >= 0) : (a -= 1) {
        sq(&c, &c);
        if (a != 2 and a != 4) mul(&c, &c, inp);
    }
    o.* = c;
}

fn unpack(o: *Gf, n: *const [32]u8) void {
    for (0..16) |i| o[i] = @as(i64, n[2 * i]) + (@as(i64, n[2 * i + 1]) << 8);
    o[15] &= 0x7fff;
}

fn pack(o: *[32]u8, n: *const Gf) void {
    var t: Gf = n.*;
    car(&t);
    car(&t);
    car(&t);
    for (0..2) |_| {
        var m: Gf = undefined;
        m[0] = t[0] - 0xffed;
        for (1..15) |i| {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        const b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        sel(&t, &m, 1 - b);
    }
    for (0..16) |i| {
        o[2 * i] = @intCast(t[i] & 0xff);
        o[2 * i + 1] = @intCast((t[i] >> 8) & 0xff);
    }
}
