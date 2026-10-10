// ECDSA P-384 (secp384r1) signature verification — FIPS 186-4 / SEC 2.
// Layer 0: pure computation, no platform deps, no allocator.
//
// Verify-only: supports TLS cert chains whose intermediates/leaves are signed
// with ECDSA-P384-SHA384 (common on Google/Cloudflare/DigiCert chains). Field
// arithmetic uses 6x64-bit limbs with Montgomery CIOS multiplication, mirroring
// the proven p256.sig structure. Constants computed from the NIST parameters.

pub const SIG_LEN = 96;      // r(48) || s(48)
pub const PUBKEY_XY_LEN = 96; // X(48) || Y(48), no 0x04 prefix

const U384 = [6]u64;
const ZERO: U384 = .{ 0, 0, 0, 0, 0, 0 };
const ONE: U384 = .{ 1, 0, 0, 0, 0, 0 };

const P: U384 = .{ 0x00000000FFFFFFFF, 0xFFFFFFFF00000000, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
const N: U384 = .{ 0xECEC196ACCC52973, 0x581A0DB248B0A77A, 0xC7634D81F4372DDF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
const P_R2: U384 = .{ 0xFFFFFFFE00000001, 0x0000000200000000, 0xFFFFFFFE00000000, 0x0000000200000000, 0x0000000000000001, 0x0000000000000000 };
const N_R2: U384 = .{ 0x2D319B2419B409A9, 0xFF3D81E5DF1AA419, 0xBC3E483AFCB82947, 0xD40D49174AAB1CC5, 0x3FB05B7A28266895, 0x0C84EE012B39BF21 };
const P_N0: u64 = 0x0000000100000001;
const N_N0: u64 = 0x6ED46089E88FDC45;
const A: U384 = .{ 0x00000000FFFFFFFC, 0xFFFFFFFF00000000, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
const B: U384 = .{ 0x2A85C8EDD3EC2AEF, 0xC656398D8A2ED19D, 0x0314088F5013875A, 0x181D9C6EFE814112, 0x988E056BE3F82D19, 0xB3312FA7E23EE7E4 };
const GX: U384 = .{ 0x3A545E3872760AB7, 0x5502F25DBF55296C, 0x59F741E082542A38, 0x6E1D3B628BA79B98, 0x8EB1C71EF320AD74, 0xAA87CA22BE8B0537 };
const GY: U384 = .{ 0x7A431D7C90EA0E5F, 0x0A60B1CE1D7E819D, 0xE9DA3113B5F0B8C0, 0xF8F41DBD289A147C, 0x5D9E98BF9292DC29, 0x3617DE4A96262C6F };

const JacobianPoint = struct { x: U384, y: U384, z: U384 };
const INF = JacobianPoint{ .x = ONE, .y = ONE, .z = ZERO };

inline fn addc(a: u64, b: u64, carry: *u64) u64 {
    const s1 = @addWithOverflow(a, b);
    const s2 = @addWithOverflow(s1[0], carry.*);
    carry.* = @as(u64, s1[1]) + @as(u64, s2[1]);
    return s2[0];
}
inline fn subb(a: u64, b: u64, borrow: *u64) u64 {
    const d1 = @subWithOverflow(a, b);
    const d2 = @subWithOverflow(d1[0], borrow.*);
    borrow.* = @as(u64, d1[1]) + @as(u64, d2[1]);
    return d2[0];
}

fn isZero(a: *const U384) bool {
    for (a) |l| { if (l != 0) return false; }
    return true;
}
fn eq(a: U384, b: U384) bool {
    for (0..6) |i| { if (a[i] != b[i]) return false; }
    return true;
}
/// a >= b ?
fn geq(a: *const U384, b: *const U384) bool {
    var i: usize = 6;
    while (i > 0) { i -= 1; if (a[i] != b[i]) return a[i] > b[i]; }
    return true;
}
fn addRaw(a: U384, b: U384) struct { v: U384, carry: u64 } {
    var r: U384 = undefined; var c: u64 = 0;
    for (0..6) |i| r[i] = addc(a[i], b[i], &c);
    return .{ .v = r, .carry = c };
}
fn subRaw(a: U384, b: U384) struct { v: U384, borrow: u64 } {
    var r: U384 = undefined; var br: u64 = 0;
    for (0..6) |i| r[i] = subb(a[i], b[i], &br);
    return .{ .v = r, .borrow = br };
}
fn addMod(a: U384, b: U384, m: *const U384) U384 {
    const s = addRaw(a, b);
    if (s.carry != 0 or geq(&s.v, m)) {
        return subRaw(s.v, m.*).v;
    }
    return s.v;
}
fn subMod(a: U384, b: U384, m: *const U384) U384 {
    const d = subRaw(a, b);
    if (d.borrow != 0) return addRaw(d.v, m.*).v;
    return d.v;
}
fn addModP(a: U384, b: U384) U384 { return addMod(a, b, &P); }
fn subModP(a: U384, b: U384) U384 { return subMod(a, b, &P); }

/// Montgomery multiplication (CIOS): returns a*b*R^-1 mod modulus.
fn montMul(a: U384, b: U384, modulus: *const U384, n0: u64) U384 {
    var t: [7]u64 = .{ 0, 0, 0, 0, 0, 0, 0 };
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        // t += a[i] * b
        var carry: u64 = 0;
        var j: usize = 0;
        while (j < 6) : (j += 1) {
            const prod = @as(u128, a[i]) * @as(u128, b[j]) + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(prod);
            carry = @truncate(prod >> 64);
        }
        const hi = @addWithOverflow(t[6], carry);
        t[6] = hi[0];
        var extra: u64 = hi[1];
        // m = t[0]*n0 mod 2^64; t += m*modulus
        const mm = t[0] *% n0;
        carry = 0;
        j = 0;
        while (j < 6) : (j += 1) {
            const prod = @as(u128, mm) * @as(u128, modulus[j]) + @as(u128, t[j]) + @as(u128, carry);
            t[j] = @truncate(prod);
            carry = @truncate(prod >> 64);
        }
        const s = @addWithOverflow(t[6], carry);
        t[6] = s[0];
        extra += s[1];
        // shift down by one limb
        j = 0;
        while (j < 6) : (j += 1) t[j] = t[j + 1];
        t[6] = extra;
    }
    var r: U384 = undefined;
    for (0..6) |k| r[k] = t[k];
    // conditional subtract modulus if t >= modulus (t[6] holds overflow)
    if (t[6] != 0 or geq(&r, modulus)) {
        r = subRaw(r, modulus.*).v;
    }
    return r;
}

fn mulModP(a: U384, b: U384) U384 {
    const b_mont = montMul(b, P_R2, &P, P_N0);
    return montMul(a, b_mont, &P, P_N0);
}
fn mulModN(a: U384, b: U384) U384 {
    const b_mont = montMul(b, N_R2, &N, N_N0);
    return montMul(a, b_mont, &N, N_N0);
}

/// Modular inverse via Fermat: a^(m-2) mod m. `exp` is m-2.
fn powMod(a: U384, exp: U384, modulus: *const U384, n0: u64, r2: *const U384) U384 {
    // Montgomery-form exponentiation. one_mont = R mod m = montMul(1, R2).
    var result = montMul(ONE, r2.*, modulus, n0);
    var base = montMul(a, r2.*, modulus, n0);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var bits = exp[i];
        var b: usize = 0;
        while (b < 64) : (b += 1) {
            if ((bits & 1) != 0) result = montMul(result, base, modulus, n0);
            base = montMul(base, base, modulus, n0);
            bits >>= 1;
        }
    }
    // convert out of Montgomery form
    return montMul(result, ONE, modulus, n0);
}

fn invModP(a: U384) U384 {
    const e = subRaw(P, .{ 2, 0, 0, 0, 0, 0 }).v;
    return powMod(a, e, &P, P_N0, &P_R2);
}
fn invModN(a: U384) U384 {
    const e = subRaw(N, .{ 2, 0, 0, 0, 0, 0 }).v;
    return powMod(a, e, &N, N_N0, &N_R2);
}

fn pointDouble(p: JacobianPoint) JacobianPoint {
    if (isZero(&p.z)) return INF;
    const xx = mulModP(p.x, p.x);
    const yy = mulModP(p.y, p.y);
    const yyyy = mulModP(yy, yy);
    const zz = mulModP(p.z, p.z);
    const x_plus_yy = addModP(p.x, yy);
    const s_inner = subModP(subModP(mulModP(x_plus_yy, x_plus_yy), xx), yyyy);
    const s = addModP(s_inner, s_inner);
    const zzzz = mulModP(zz, zz);
    const xx_minus = subModP(xx, zzzz);
    const m = addModP(addModP(xx_minus, xx_minus), xx_minus);
    const mm = mulModP(m, m);
    const new_x = subModP(mm, addModP(s, s));
    const s_minus_x = subModP(s, new_x);
    const two_yyyy = addModP(yyyy, yyyy);
    const four_yyyy = addModP(two_yyyy, two_yyyy);
    const eight_yyyy = addModP(four_yyyy, four_yyyy);
    const new_y = subModP(mulModP(m, s_minus_x), eight_yyyy);
    const new_z = addModP(mulModP(p.y, p.z), mulModP(p.y, p.z));
    return .{ .x = new_x, .y = new_y, .z = new_z };
}

fn pointAdd(p: JacobianPoint, q: JacobianPoint) JacobianPoint {
    if (isZero(&p.z)) return q;
    if (isZero(&q.z)) return p;
    const z1z1 = mulModP(p.z, p.z);
    const z2z2 = mulModP(q.z, q.z);
    const pu1 = mulModP(p.x, z2z2);
    const pu2 = mulModP(q.x, z1z1);
    const s1 = mulModP(mulModP(p.y, q.z), z2z2);
    const s2 = mulModP(mulModP(q.y, p.z), z1z1);
    if (eq(pu1, pu2)) {
        if (eq(s1, s2)) return pointDouble(p);
        return INF;
    }
    const h = subModP(pu2, pu1);
    const rr = subModP(s2, s1);
    const hh = mulModP(h, h);
    const hhh = mulModP(hh, h);
    const u1hh = mulModP(pu1, hh);
    const rr2 = mulModP(rr, rr);
    const new_x = subModP(subModP(rr2, hhh), addModP(u1hh, u1hh));
    const new_y = subModP(mulModP(rr, subModP(u1hh, new_x)), mulModP(s1, hhh));
    const new_z = mulModP(mulModP(p.z, q.z), h);
    return .{ .x = new_x, .y = new_y, .z = new_z };
}

fn scalarMult(point: *const JacobianPoint, k: *const U384) JacobianPoint {
    var result = INF;
    var addend = point.*;
    for (0..6) |limb| {
        var bits = k[limb];
        var b: usize = 0;
        while (b < 64) : (b += 1) {
            if ((bits & 1) != 0) result = pointAdd(result, addend);
            addend = pointDouble(addend);
            bits >>= 1;
        }
    }
    return result;
}
fn scalarMultG(k: *const U384) JacobianPoint {
    const g = JacobianPoint{ .x = GX, .y = GY, .z = ONE };
    return scalarMult(&g, k);
}
fn toAffineX(p: *const JacobianPoint) U384 {
    const z_inv = invModP(p.z);
    const z_inv_sq = mulModP(z_inv, z_inv);
    return mulModP(p.x, z_inv_sq);
}

/// Big-endian 48 bytes -> U384 (little-endian limbs).
fn bytesToU384(b: *const [48]u8) U384 {
    var r: U384 = ZERO;
    for (0..6) |i| {
        var v: u64 = 0;
        for (0..8) |j| v = (v << 8) | b[i * 8 + j];
        r[5 - i] = v;
    }
    return r;
}
/// Reduce a U384 mod n (at most one subtraction needed for values < 2^384).
fn modN(a: U384) U384 {
    if (geq(&a, &N)) return subRaw(a, N).v;
    return a;
}

/// Verify an ECDSA-P384 signature. `pub_xy` = X(48)||Y(48); `hash` is the
/// message digest (SHA-384, 48 bytes); `sig` = r(48)||s(48). Returns true iff valid.
pub fn verify(pub_xy: *const [96]u8, hash: *const [48]u8, sig: *const [96]u8) bool {
    var rx: [48]u8 = undefined; @memcpy(&rx, sig[0..48]);
    var sx: [48]u8 = undefined; @memcpy(&sx, sig[48..96]);
    const r = bytesToU384(&rx);
    const s = bytesToU384(&sx);
    // r, s must be in [1, n-1]
    if (isZero(&r) or isZero(&s)) return false;
    if (geq(&r, &N) or geq(&s, &N)) return false;
    const z = modN(bytesToU384(hash));
    const w = invModN(s);
    const vu1 = mulModN(z, w);
    const vu2 = mulModN(r, w);
    var qx: [48]u8 = undefined; @memcpy(&qx, pub_xy[0..48]);
    var qy: [48]u8 = undefined; @memcpy(&qy, pub_xy[48..96]);
    const q = JacobianPoint{ .x = bytesToU384(&qx), .y = bytesToU384(&qy), .z = ONE };
    const p1 = scalarMultG(&vu1);
    const p2 = scalarMult(&q, &vu2);
    const sum = pointAdd(p1, p2);
    if (isZero(&sum.z)) return false;
    const x = modN(toAffineX(&sum));
    return eq(x, r);
}

// ── Tests ────────────────────────────────────────────────────────────────
const testing = @import("std").testing;

test "p384: verify ECDSA-SHA384 test vector" {
    // Generated from deterministic private key d=0x0123..cdef via Python cryptography.
    const pub_xy = [96]u8{
        0x5c, 0x86, 0xa4, 0x7f, 0x40, 0xf6, 0xed, 0xcd, 0x68, 0xca, 0x1e, 0x3d, 0x11, 0x25, 0x22, 0xdc,
        0x8a, 0xc9, 0x1c, 0xe4, 0xc1, 0x0b, 0x74, 0x3a, 0xd3, 0xe8, 0xe2, 0x53, 0x8f, 0x30, 0xbe, 0x48,
        0x8d, 0x50, 0x03, 0x7a, 0x01, 0xb9, 0x40, 0xdd, 0xc6, 0xdf, 0x8d, 0x74, 0x65, 0xae, 0x16, 0x26,
        0x78, 0x9e, 0x5c, 0xd6, 0x24, 0x4c, 0x79, 0xa8, 0x3b, 0xb7, 0xd3, 0xa3, 0xe7, 0x13, 0x8e, 0xb9,
        0xd1, 0xf2, 0x16, 0xaa, 0xfd, 0x21, 0x5b, 0x9d, 0xeb, 0xc8, 0x95, 0x0d, 0x86, 0xcc, 0x40, 0x1a,
        0x11, 0xeb, 0xc9, 0x29, 0xd0, 0x3e, 0x3a, 0xae, 0x32, 0x1f, 0x37, 0x56, 0x08, 0xaa, 0x31, 0x43,
    };
    const digest = [48]u8{
        0x88, 0x68, 0xd2, 0x06, 0x7c, 0xa8, 0xc1, 0x12, 0xee, 0x87, 0xd0, 0x32, 0xa7, 0x9a, 0xa1, 0x7d,
        0xcc, 0x63, 0x9b, 0xc0, 0x28, 0x65, 0x9d, 0x8f, 0x7a, 0x70, 0xfa, 0x37, 0x1a, 0x81, 0x86, 0x3e,
        0xdd, 0xa3, 0x86, 0x55, 0xda, 0x20, 0xfc, 0xbf, 0xbb, 0x83, 0x98, 0xaf, 0xe3, 0xbd, 0x34, 0xdc,
    };
    var sig: [96]u8 = undefined;
    @memcpy(sig[0..48], &[48]u8{
        0xd8, 0xe6, 0x86, 0x5b, 0xbe, 0x86, 0xe6, 0x0c, 0x64, 0xb3, 0x08, 0x86, 0x37, 0xca, 0x57, 0x11,
        0x8e, 0x51, 0x47, 0x6c, 0x33, 0x99, 0xec, 0xca, 0x85, 0xd7, 0x7b, 0x96, 0x07, 0xc4, 0xf1, 0xcc,
        0x0b, 0xbf, 0x27, 0xe5, 0x64, 0x1a, 0x98, 0x82, 0x2a, 0x70, 0xed, 0x74, 0x5e, 0x6e, 0x0b, 0x82,
    });
    @memcpy(sig[48..96], &[48]u8{
        0xe8, 0x93, 0x3e, 0x3b, 0x7d, 0x3c, 0x9c, 0x2b, 0x2c, 0x31, 0x91, 0xc6, 0xb3, 0xb2, 0x26, 0x7b,
        0xb6, 0x63, 0x82, 0x7e, 0x8a, 0x0e, 0x62, 0x82, 0x19, 0xcc, 0x4e, 0x02, 0x1f, 0x4e, 0x5a, 0xbb,
        0x57, 0x04, 0x71, 0x3c, 0x6e, 0xe1, 0x7e, 0xf5, 0x6c, 0x12, 0x10, 0x9f, 0xdc, 0x48, 0x7c, 0xa6,
    });
    try testing.expect(verify(&pub_xy, &digest, &sig));
}

test "p384: tampered signature rejected" {
    const pub_xy: [96]u8 = @splat(0);
    const digest: [48]u8 = @splat(0);
    var sig: [96]u8 = @splat(0);
    sig[0] = 1;
    try testing.expect(!verify(&pub_xy, &digest, &sig));
}
