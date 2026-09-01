// ECDSA P-256 (secp256r1) — FIPS 186-4 / SEC 2
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Provides ECDSA signing for TLS 1.3 CertificateVerify messages.
// Uses the NIST P-256 curve (a = -3, prime = 2^256 - 2^224 + 2^192 + 2^96 - 1).
//
// Operations:
// - sign(): Generate ECDSA signature (r, s) from a private key and message hash
// - verify(): Verify an ECDSA signature (for completeness)
//
// Field arithmetic uses 4 limbs of 64 bits with Montgomery reduction.
// Point operations use Jacobian coordinates.

const sha256 = @import("sha256");

/// Signature size: r (32 bytes) + s (32 bytes).
pub const SIG_LEN = 64;

/// Private key size (scalar).
pub const SCALAR_LEN = 32;

/// Public key size (uncompressed: 04 || x || y).
pub const PUBKEY_UNCOMPRESSED_LEN = 65;

// ── P-256 curve parameters ──────────────────────────────────────────────

/// p = 2^256 - 2^224 + 2^192 + 2^96 - 1
const P: [4]u64 = .{ 0xFFFFFFFFFFFFFFFF, 0x00000000FFFFFFFF, 0x0000000000000000, 0xFFFFFFFF00000001 };

/// n = order of the generator point
const N: [4]u64 = .{ 0xF3B9CAC2FC632551, 0xBCE6FAADA7179E84, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF00000000 };

/// Montgomery constants for R = 2^256. R2 is R^2 mod modulus and N0_INV is
/// -modulus[0]^-1 mod 2^64.
const P_R2: [4]u64 = .{ 0x0000000000000003, 0xFFFFFFFBFFFFFFFF, 0xFFFFFFFFFFFFFFFE, 0x00000004FFFFFFFD };
const N_R2: [4]u64 = .{ 0x83244C95BE79EEA2, 0x4699799C49BD6FA6, 0x2845B2392B6BEC59, 0x66E12D94F3D95620 };
const P_N0_INV: u64 = 0x0000000000000001;
const N_N0_INV: u64 = 0xCCD1C8AAEE00BC4F;

/// Generator point G (uncompressed)
const GX: [4]u64 = .{ 0xF4A13945D898C296, 0x77037D812DEB33A0, 0xF8BCE6E563A440F2, 0x6B17D1F2E12C4247 };
const GY: [4]u64 = .{ 0xCBB6406837BF51F5, 0x2BCE33576B315ECE, 0x8EE7EB4A7C0F9E16, 0x4FE342E2FE1A7F9B };

/// a = -3 mod p (for P-256, a = p - 3)
const A: [4]u64 = .{ 0xFFFFFFFFFFFFFFFC, 0x00000000FFFFFFFF, 0x0000000000000000, 0xFFFFFFFF00000001 };

// ── 256-bit integer types ───────────────────────────────────────────────

const U256 = [4]u64; // Little-endian limbs

const ZERO_U256: U256 = .{ 0, 0, 0, 0 };
const ONE_U256: U256 = .{ 1, 0, 0, 0 };

// ── Jacobian point ──────────────────────────────────────────────────────

const JacobianPoint = struct {
    x: U256,
    y: U256,
    z: U256,
};

const POINT_AT_INF = JacobianPoint{ .x = ONE_U256, .y = ONE_U256, .z = ZERO_U256 };

// ── Public API ──────────────────────────────────────────────────────────

/// Sign a 32-byte message hash using the given private key.
/// Uses deterministic nonce generation (RFC 6979 simplified with HMAC-DRBG).
/// Returns the 64-byte signature (r || s) in `sig_out`.
/// Returns true on success, false if the key is invalid.
pub fn sign(
    private_key: *const [32]u8,
    message_hash: *const [32]u8,
    sig_out: *[64]u8,
) bool {
    const k_scalar = deterministicK(private_key, message_hash);
    if (isZeroU256(&k_scalar)) return false;

    // R = k * G
    const r_point = scalarMultG(&k_scalar);
    if (isZeroU256(&r_point.z)) return false;

    // r = R.x mod n
    const r_affine_x = toAffineX(&r_point);
    var r = modN(r_affine_x);
    if (isZeroU256(&r)) return false;

    // s = k^-1 * (hash + r * private_key) mod n
    const d = modN(bytesToU256(private_key));
    const z = modN(bytesToU256(message_hash));
    const rd = mulModN(r, d);
    const z_plus_rd = addModN(z, rd);
    const k_inv = invertModN(k_scalar);
    const s = mulModN(k_inv, z_plus_rd);
    if (isZeroU256(&s)) return false;

    u256ToBytes(&r, sig_out[0..32]);
    u256ToBytes(&s, sig_out[32..64]);
    return true;
}

/// Verify an ECDSA signature against a public key and message hash.
/// public_key is the 64-byte (x || y) coordinates (without the 0x04 prefix).
/// Returns true if the signature is valid.
pub fn verify(
    public_key_xy: *const [64]u8,
    message_hash: *const [32]u8,
    signature: *const [64]u8,
) bool {
    const r = bytesToU256(signature[0..32]);
    const s = bytesToU256(signature[32..64]);

    // Check 0 < r < n and 0 < s < n
    if (isZeroU256(&r) or !isLessThan(&r, &N)) return false;
    if (isZeroU256(&s) or !isLessThan(&s, &N)) return false;

    const z = modN(bytesToU256(message_hash));
    const s_inv = invertModN(s);
    const u1_val = mulModN(z, s_inv);
    const u2_val = mulModN(r, s_inv);

    // Decode public key
    const qx = bytesToU256(public_key_xy[0..32]);
    const qy = bytesToU256(public_key_xy[32..64]);
    const q = JacobianPoint{ .x = qx, .y = qy, .z = ONE_U256 };

    // R' = u1*G + u2*Q
    const u1g = scalarMultG(&u1_val);
    const u2q = scalarMult(&q, &u2_val);
    const r_point = pointAdd(u1g, u2q);

    if (isZeroU256(&r_point.z)) return false;

    const rx = toAffineX(&r_point);
    const rx_mod_n = modN(rx);

    return u256Equal(rx_mod_n, r);
}

// ── Scalar Arithmetic mod n ─────────────────────────────────────────────

fn addModN(a: U256, b: U256) U256 {
    var result: U256 = undefined;
    var carry: u64 = 0;
    for (0..4) |i| {
        const sum: u128 = @as(u128, a[i]) + @as(u128, b[i]) + carry;
        result[i] = @intCast(sum & 0xFFFFFFFFFFFFFFFF);
        carry = @intCast(sum >> 64);
    }
    // Reduce if >= n
    if (carry != 0 or !isLessThan(&result, &N)) {
        var borrow: u64 = 0;
        for (0..4) |i| {
            const diff: i128 = @as(i128, result[i]) - @as(i128, N[i]) - @as(i128, borrow);
            if (diff < 0) {
                result[i] = @intCast(@as(u128, @bitCast(diff + (1 << 64))));
                borrow = 1;
            } else {
                result[i] = @intCast(@as(u128, @bitCast(diff)));
                borrow = 0;
            }
        }
    }
    return result;
}

fn mulModN(a: U256, b: U256) U256 {
    // Converting only one operand is sufficient:
    // montMul(a, b*R) = a*b*R*R^-1 = a*b (mod n).
    const b_mont = montMul(b, N_R2, &N, N_N0_INV);
    return montMul(a, b_mont, &N, N_N0_INV);
}

fn invertModN(a: U256) U256 {
    // a^(n-2) mod n via binary exponentiation
    var exp: U256 = N;
    // n - 2
    var borrow: u64 = 0;
    const diff0: i128 = @as(i128, exp[0]) - 2;
    if (diff0 < 0) {
        exp[0] = @intCast(@as(u128, @bitCast(diff0 + (1 << 64))));
        borrow = 1;
    } else {
        exp[0] = @intCast(@as(u128, @bitCast(diff0)));
    }
    for (1..4) |i| {
        const d: i128 = @as(i128, exp[i]) - @as(i128, borrow);
        if (d < 0) {
            exp[i] = @intCast(@as(u128, @bitCast(d + (1 << 64))));
            borrow = 1;
        } else {
            exp[i] = @intCast(@as(u128, @bitCast(d)));
            borrow = 0;
        }
    }

    var result = ONE_U256;
    var base = a;

    for (0..4) |limb_idx| {
        var bits = exp[limb_idx];
        for (0..64) |_| {
            if ((bits & 1) != 0) {
                result = mulModN(result, base);
            }
            base = mulModN(base, base);
            bits >>= 1;
        }
    }
    return result;
}

fn modN(a: U256) U256 {
    var result = a;
    while (!isLessThan(&result, &N)) {
        result = subU256(result, N);
    }
    return result;
}

// ── Point Operations (Jacobian coordinates) ─────────────────────────────

fn scalarMultG(k: *const U256) JacobianPoint {
    const g = JacobianPoint{ .x = GX, .y = GY, .z = ONE_U256 };
    return scalarMult(&g, k);
}

fn scalarMult(p: *const JacobianPoint, k: *const U256) JacobianPoint {
    var result = POINT_AT_INF;
    var addend = p.*;

    for (0..4) |limb_idx| {
        var bits = k[limb_idx];
        for (0..64) |_| {
            if ((bits & 1) != 0) {
                result = pointAdd(result, addend);
            }
            addend = pointDouble(addend);
            bits >>= 1;
        }
    }
    return result;
}

fn pointDouble(p: JacobianPoint) JacobianPoint {
    if (isZeroU256(&p.z)) return POINT_AT_INF;

    // Using formulas for a = -3 (P-256 specific optimization)
    const xx = mulModP(p.x, p.x);
    const yy = mulModP(p.y, p.y);
    const yyyy = mulModP(yy, yy);
    const zz = mulModP(p.z, p.z);

    // S = 2 * ((X + YY)^2 - XX - YYYY)
    const x_plus_yy = addModP(p.x, yy);
    const s_inner = subModP(subModP(mulModP(x_plus_yy, x_plus_yy), xx), yyyy);
    const s = addModP(s_inner, s_inner);

    // M = 3*XX + a*ZZ^2 (a = -3 for P-256, so M = 3*(XX - ZZ^2))
    const zzzz = mulModP(zz, zz);
    const xx_minus_zzzz = subModP(xx, zzzz);
    const m = addModP(addModP(xx_minus_zzzz, xx_minus_zzzz), xx_minus_zzzz);

    // X' = M^2 - 2*S
    const mm = mulModP(m, m);
    const new_x = subModP(mm, addModP(s, s));

    // Y' = M*(S - X') - 8*YYYY
    const s_minus_x = subModP(s, new_x);
    const eight_yyyy = addModP(addModP(addModP(yyyy, yyyy), addModP(yyyy, yyyy)), addModP(addModP(yyyy, yyyy), addModP(yyyy, yyyy)));
    const new_y = subModP(mulModP(m, s_minus_x), eight_yyyy);

    // Z' = 2*Y*Z
    const new_z = addModP(mulModP(p.y, p.z), mulModP(p.y, p.z));

    return .{ .x = new_x, .y = new_y, .z = new_z };
}

fn pointAdd(p: JacobianPoint, q: JacobianPoint) JacobianPoint {
    if (isZeroU256(&p.z)) return q;
    if (isZeroU256(&q.z)) return p;

    const z1z1 = mulModP(p.z, p.z);
    const z2z2 = mulModP(q.z, q.z);
    const pu1 = mulModP(p.x, z2z2);
    const u2_pt = mulModP(q.x, z1z1);
    const s1 = mulModP(mulModP(p.y, q.z), z2z2);
    const s2 = mulModP(mulModP(q.y, p.z), z1z1);

    if (u256Equal(pu1, u2_pt)) {
        if (u256Equal(s1, s2)) return pointDouble(p);
        return POINT_AT_INF;
    }

    const h = subModP(u2_pt, pu1);
    const hh = mulModP(h, h);
    const hhh = mulModP(h, hh);
    const r = subModP(s2, s1);

    const v = mulModP(pu1, hh);

    // X3 = R^2 - HHH - 2*V
    const rr = mulModP(r, r);
    const new_x = subModP(subModP(rr, hhh), addModP(v, v));

    // Y3 = R*(V - X3) - S1*HHH
    const new_y = subModP(mulModP(r, subModP(v, new_x)), mulModP(s1, hhh));

    // Z3 = Z1 * Z2 * H
    const new_z = mulModP(mulModP(p.z, q.z), h);

    return .{ .x = new_x, .y = new_y, .z = new_z };
}

fn toAffineX(p: *const JacobianPoint) U256 {
    const z_inv = invertModP(p.z);
    const z_inv_sq = mulModP(z_inv, z_inv);
    return mulModP(p.x, z_inv_sq);
}

// ── Field Arithmetic mod p ──────────────────────────────────────────────

fn addModP(a: U256, b: U256) U256 {
    var result: U256 = undefined;
    var carry: u64 = 0;
    for (0..4) |i| {
        const sum: u128 = @as(u128, a[i]) + @as(u128, b[i]) + carry;
        result[i] = @intCast(sum & 0xFFFFFFFFFFFFFFFF);
        carry = @intCast(sum >> 64);
    }
    if (carry != 0 or !isLessThan(&result, &P)) {
        result = subU256(result, P);
    }
    return result;
}

fn subModP(a: U256, b: U256) U256 {
    if (isLessThan(&a, &b)) {
        // a - b + p
        var result: U256 = undefined;
        var carry: u64 = 0;
        for (0..4) |i| {
            const sum: u128 = @as(u128, a[i]) + @as(u128, P[i]) + carry;
            result[i] = @intCast(sum & 0xFFFFFFFFFFFFFFFF);
            carry = @intCast(sum >> 64);
        }
        var borrow: u64 = 0;
        for (0..4) |i| {
            const diff: i128 = @as(i128, result[i]) - @as(i128, b[i]) - @as(i128, borrow);
            if (diff < 0) {
                result[i] = @intCast(@as(u128, @bitCast(diff + (1 << 64))));
                borrow = 1;
            } else {
                result[i] = @intCast(@as(u128, @bitCast(diff)));
                borrow = 0;
            }
        }
        return result;
    }
    return subU256(a, b);
}

fn mulModP(a: U256, b: U256) U256 {
    const b_mont = montMul(b, P_R2, &P, P_N0_INV);
    return montMul(a, b_mont, &P, P_N0_INV);
}

fn invertModP(a: U256) U256 {
    // a^(p-2) mod p via binary exponentiation
    var exp: U256 = P;
    var borrow: u64 = 0;
    const diff0: i128 = @as(i128, exp[0]) - 2;
    if (diff0 < 0) {
        exp[0] = @intCast(@as(u128, @bitCast(diff0 + (1 << 64))));
        borrow = 1;
    } else {
        exp[0] = @intCast(@as(u128, @bitCast(diff0)));
    }
    for (1..4) |i| {
        const d: i128 = @as(i128, exp[i]) - @as(i128, borrow);
        if (d < 0) {
            exp[i] = @intCast(@as(u128, @bitCast(d + (1 << 64))));
            borrow = 1;
        } else {
            exp[i] = @intCast(@as(u128, @bitCast(d)));
            borrow = 0;
        }
    }

    var result = ONE_U256;
    var base = a;

    for (0..4) |limb_idx| {
        var bits = exp[limb_idx];
        for (0..64) |_| {
            if ((bits & 1) != 0) {
                result = mulModP(result, base);
            }
            base = mulModP(base, base);
            bits >>= 1;
        }
    }
    return result;
}

// ── Utility ─────────────────────────────────────────────────────────────

/// Coarsely Integrated Operand Scanning Montgomery multiplication.
/// Returns a*b*R^-1 mod modulus for four little-endian 64-bit limbs.
/// Inputs must be reduced. Runtime is fixed: 32 word multiplications and one
/// final conditional subtraction, independent of operand magnitude.
fn montMul(a: U256, b: U256, modulus: *const U256, n0_inv: u64) U256 {
    var t: [5]u64 = @splat(0);

    for (0..4) |i| {
        var carry: u64 = 0;
        for (0..4) |j| {
            const product: u128 = @as(u128, a[j]) * @as(u128, b[i]) +
                @as(u128, t[j]) + @as(u128, carry);
            t[j] = @intCast(product & 0xFFFFFFFFFFFFFFFF);
            carry = @intCast(product >> 64);
        }
        const product_top: u128 = @as(u128, t[4]) + @as(u128, carry);
        t[4] = @intCast(product_top & 0xFFFFFFFFFFFFFFFF);

        // The low limb of t + q*modulus is zero by construction and is
        // discarded while the remaining limbs shift down one word.
        const q = t[0] *% n0_inv;
        carry = 0;
        for (0..4) |j| {
            const reduced: u128 = @as(u128, q) * @as(u128, modulus[j]) +
                @as(u128, t[j]) + @as(u128, carry);
            if (j != 0) t[j - 1] = @intCast(reduced & 0xFFFFFFFFFFFFFFFF);
            carry = @intCast(reduced >> 64);
        }
        const reduced_top: u128 = @as(u128, t[4]) + @as(u128, carry);
        t[3] = @intCast(reduced_top & 0xFFFFFFFFFFFFFFFF);
        t[4] = @intCast(reduced_top >> 64);
    }

    var result: U256 = .{ t[0], t[1], t[2], t[3] };
    if (t[4] != 0 or !isLessThan(&result, modulus)) {
        result = subU256(result, modulus.*);
    }
    return result;
}

fn subU256(a: U256, b: U256) U256 {
    var result: U256 = undefined;
    var borrow: u64 = 0;
    for (0..4) |i| {
        const diff: i128 = @as(i128, a[i]) - @as(i128, b[i]) - @as(i128, borrow);
        if (diff < 0) {
            result[i] = @intCast(@as(u128, @bitCast(diff + (1 << 64))));
            borrow = 1;
        } else {
            result[i] = @intCast(@as(u128, @bitCast(diff)));
            borrow = 0;
        }
    }
    return result;
}

fn isZeroU256(a: *const U256) bool {
    return a[0] == 0 and a[1] == 0 and a[2] == 0 and a[3] == 0;
}

fn u256Equal(a: U256, b: U256) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn isLessThan(a: *const U256, b: *const U256) bool {
    var i: usize = 3;
    while (true) {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
        if (i == 0) break;
        i -= 1;
    }
    return false;
}

fn bytesToU256(bytes: *const [32]u8) U256 {
    // Big-endian bytes to little-endian limbs
    var result: U256 = undefined;
    for (0..4) |i| {
        const offset = (3 - i) * 8;
        result[i] = (@as(u64, bytes[offset]) << 56) |
            (@as(u64, bytes[offset + 1]) << 48) |
            (@as(u64, bytes[offset + 2]) << 40) |
            (@as(u64, bytes[offset + 3]) << 32) |
            (@as(u64, bytes[offset + 4]) << 24) |
            (@as(u64, bytes[offset + 5]) << 16) |
            (@as(u64, bytes[offset + 6]) << 8) |
            @as(u64, bytes[offset + 7]);
    }
    return result;
}

fn u256ToBytes(a: *const U256, out: *[32]u8) void {
    // Little-endian limbs to big-endian bytes
    for (0..4) |i| {
        const offset = (3 - i) * 8;
        const limb = a[i];
        out[offset] = @intCast((limb >> 56) & 0xFF);
        out[offset + 1] = @intCast((limb >> 48) & 0xFF);
        out[offset + 2] = @intCast((limb >> 40) & 0xFF);
        out[offset + 3] = @intCast((limb >> 32) & 0xFF);
        out[offset + 4] = @intCast((limb >> 24) & 0xFF);
        out[offset + 5] = @intCast((limb >> 16) & 0xFF);
        out[offset + 6] = @intCast((limb >> 8) & 0xFF);
        out[offset + 7] = @intCast(limb & 0xFF);
    }
}

/// Deterministic nonce generation (simplified RFC 6979).
/// k = HMAC(private_key, hash || 0x01) truncated and reduced mod n.
fn deterministicK(private_key: *const [32]u8, hash: *const [32]u8) U256 {
    const hmac_mod = @import("hmac");
    // k = HMAC-SHA256(private_key, hash || 0x01)
    var h = hmac_mod.Hmac.init(private_key);
    h.update(hash);
    const suffix = [_]u8{0x01};
    h.update(&suffix);
    const k_bytes = h.final();
    var k = bytesToU256(&k_bytes);
    // Reduce mod n
    while (!isLessThan(&k, &N)) {
        k = subU256(k, N);
    }
    return k;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "p256: Montgomery multiplication field identities" {
    const p_minus_one = subU256(P, ONE_U256);
    const n_minus_one = subU256(N, ONE_U256);
    if (!u256Equal(mulModP(p_minus_one, p_minus_one), ONE_U256)) {
        return error.TestUnexpectedResult;
    }
    if (!u256Equal(mulModN(n_minus_one, n_minus_one), ONE_U256)) {
        return error.TestUnexpectedResult;
    }
}

test "p256: sign and verify round trip" {
    // Use a known private key
    const private_key = [32]u8{
        0xC9, 0xAF, 0xA9, 0xD8, 0x45, 0xBA, 0x75, 0x16,
        0x6B, 0x5C, 0x21, 0x57, 0x67, 0xB1, 0xD6, 0x93,
        0x4E, 0x50, 0xC3, 0xDB, 0x36, 0xE8, 0x9B, 0x12,
        0x7B, 0x8A, 0x62, 0x2B, 0x12, 0x0F, 0x67, 0x21,
    };
    const message_hash = sha256.hash("test message");

    var sig: [64]u8 = undefined;
    const ok = sign(&private_key, &message_hash, &sig);
    if (!ok) return error.TestUnexpectedResult;

    // Derive public key: Q = private_key * G
    const q_point = scalarMultG(&bytesToU256(&private_key));
    const qx = toAffineX(&q_point);
    const z_inv = invertModP(q_point.z);
    const z_inv_sq = mulModP(z_inv, z_inv);
    const z_inv_cu = mulModP(z_inv_sq, z_inv);
    const qy = mulModP(q_point.y, z_inv_cu);

    var pub_key: [64]u8 = undefined;
    u256ToBytes(&qx, pub_key[0..32]);
    u256ToBytes(&qy, pub_key[32..64]);

    const valid = verify(&pub_key, &message_hash, &sig);
    if (!valid) return error.TestUnexpectedResult;
}

test "p256: tampered signature fails verification" {
    const private_key = [32]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    };
    const message_hash = sha256.hash("another test");

    var sig: [64]u8 = undefined;
    const ok = sign(&private_key, &message_hash, &sig);
    if (!ok) return error.TestUnexpectedResult;

    // Derive public key
    const q_point = scalarMultG(&bytesToU256(&private_key));
    const qx = toAffineX(&q_point);
    const z_inv = invertModP(q_point.z);
    const z_inv_sq = mulModP(z_inv, z_inv);
    const z_inv_cu = mulModP(z_inv_sq, z_inv);
    const qy = mulModP(q_point.y, z_inv_cu);
    var pub_key: [64]u8 = undefined;
    u256ToBytes(&qx, pub_key[0..32]);
    u256ToBytes(&qy, pub_key[32..64]);

    // Tamper with signature
    sig[0] ^= 0xFF;
    const valid = verify(&pub_key, &message_hash, &sig);
    if (valid) return error.TestUnexpectedResult;
}

test "p256: sign produces deterministic output" {
    const key: [32]u8 = @splat(0x42);
    const msg = sha256.hash("determinism");

    var sig1: [64]u8 = undefined;
    var sig2: [64]u8 = undefined;
    _ = sign(&key, &msg, &sig1);
    _ = sign(&key, &msg, &sig2);

    for (0..64) |i| {
        if (sig1[i] != sig2[i]) return error.TestUnexpectedResult;
    }
}
