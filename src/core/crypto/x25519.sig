// X25519 — RFC 7748 Diffie-Hellman key exchange on Curve25519
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Provides X25519 scalar multiplication for ECDH key agreement.
// Used in TLS 1.3 key exchange (KeyShare extension).
//
// All arithmetic is in GF(2^255 - 19) using 5 limbs of 51 bits each.
// Montgomery ladder implementation (constant-time).

/// Size of a scalar or u-coordinate in bytes.
pub const KEY_LEN = 32;

/// The basepoint (generator) u-coordinate: u = 9.
pub const BASEPOINT: [32]u8 = .{ 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

/// Field element: 5 limbs, each up to 51 bits.
const Fe = [5]u64;

const ZERO: Fe = .{ 0, 0, 0, 0, 0 };
const ONE: Fe = .{ 1, 0, 0, 0, 0 };

/// Perform X25519 scalar multiplication: result = scalar * point.
/// Both scalar and point are 32 bytes. Returns the 32-byte result.
pub fn scalarmult(scalar: *const [32]u8, point: *const [32]u8) [32]u8 {
    // Clamp scalar per RFC 7748 §5
    var e: [32]u8 = scalar.*;
    e[0] &= 248;
    e[31] &= 127;
    e[31] |= 64;

    // Decode u-coordinate
    const u = feFromBytes(point);

    // Montgomery ladder
    const x_1 = u;
    var x_2 = ONE;
    var z_2 = ZERO;
    var x_3 = u;
    var z_3 = ONE;
    var swap: u64 = 0;

    var pos: i16 = 254;
    while (pos >= 0) : (pos -= 1) {
        const byte_idx: usize = @intCast(@divFloor(pos, 8));
        const bit_idx: u3 = @intCast(@as(u16, @intCast(pos)) % 8);
        const bit: u64 = (@as(u64, e[byte_idx]) >> bit_idx) & 1;

        swap ^= bit;
        cswap(&x_2, &x_3, swap);
        cswap(&z_2, &z_3, swap);
        swap = bit;

        const a = feAdd(x_2, z_2);
        const aa = feSq(a);
        const b = feSub(x_2, z_2);
        const bb = feSq(b);
        const e_val = feSub(aa, bb);
        const c = feAdd(x_3, z_3);
        const d = feSub(x_3, z_3);
        const da = feMul(d, a);
        const cb = feMul(c, b);
        x_3 = feSq(feAdd(da, cb));
        z_3 = feMul(x_1, feSq(feSub(da, cb)));
        x_2 = feMul(aa, bb);
        z_2 = feMul(e_val, feAdd(aa, feMulA24(e_val)));
    }

    cswap(&x_2, &x_3, swap);
    cswap(&z_2, &z_3, swap);

    // result = x_2 * z_2^(p-2) (modular inversion via Fermat's little theorem)
    const z_inv = feInvert(z_2);
    const result = feMul(x_2, z_inv);

    return feToBytes(result);
}

/// Generate a public key from a private key: pub = scalar * basepoint.
pub fn publicKey(private_key: *const [32]u8) [32]u8 {
    return scalarmult(private_key, &BASEPOINT);
}

/// Perform X25519 shared secret computation.
pub fn sharedSecret(my_private: *const [32]u8, their_public: *const [32]u8) [32]u8 {
    return scalarmult(my_private, their_public);
}

// ── Field Arithmetic (GF(2^255 - 19), 5×51-bit limbs) ──────────────────

fn feFromBytes(s: *const [32]u8) Fe {
    var h: Fe = undefined;
    h[0] = load51(s, 0);
    h[1] = load51(s, 6) >> 3;
    h[2] = load51(s, 12) >> 6;
    h[3] = load51(s, 19) >> 1;
    h[4] = load51(s, 24) >> 12;
    // Mask to 51 bits
    h[0] &= 0x7FFFFFFFFFFFF;
    h[1] &= 0x7FFFFFFFFFFFF;
    h[2] &= 0x7FFFFFFFFFFFF;
    h[3] &= 0x7FFFFFFFFFFFF;
    h[4] &= 0x7FFFFFFFFFFFF;
    return h;
}

fn feToBytes(h: Fe) [32]u8 {
    // Reduce modulo p = 2^255 - 19
    const t = feReduce(h);

    var s: [32]u8 = @splat(0);
    for (t, 0..) |limb, limb_index| {
        const bit_offset = limb_index * 51;
        var byte_index = bit_offset / 8;
        const initial_shift: usize = bit_offset % 8;
        var value = limb;
        s[byte_index] |= @truncate(value << @intCast(initial_shift));
        value >>= @intCast(8 - initial_shift);
        byte_index += 1;
        while (value != 0 and byte_index < s.len) : (byte_index += 1) {
            s[byte_index] |= @truncate(value);
            value >>= 8;
        }
    }
    // Clear top bit (ensure < 2^255)
    s[31] &= 127;
    return s;
}

fn feReduce(h: Fe) Fe {
    var t = h;
    // Carry propagation
    t[1] += t[0] >> 51; t[0] &= 0x7FFFFFFFFFFFF;
    t[2] += t[1] >> 51; t[1] &= 0x7FFFFFFFFFFFF;
    t[3] += t[2] >> 51; t[2] &= 0x7FFFFFFFFFFFF;
    t[4] += t[3] >> 51; t[3] &= 0x7FFFFFFFFFFFF;
    t[0] += (t[4] >> 51) * 19; t[4] &= 0x7FFFFFFFFFFFF;
    // Second pass
    t[1] += t[0] >> 51; t[0] &= 0x7FFFFFFFFFFFF;
    t[2] += t[1] >> 51; t[1] &= 0x7FFFFFFFFFFFF;
    t[3] += t[2] >> 51; t[2] &= 0x7FFFFFFFFFFFF;
    t[4] += t[3] >> 51; t[3] &= 0x7FFFFFFFFFFFF;
    t[0] += (t[4] >> 51) * 19; t[4] &= 0x7FFFFFFFFFFFF;

    // Conditional subtract p
    var c: u64 = (t[0] + 19) >> 51;
    c = (t[1] + c) >> 51;
    c = (t[2] + c) >> 51;
    c = (t[3] + c) >> 51;
    c = (t[4] + c) >> 51;
    t[0] += 19 * c;
    const mask = (c -% 1); // 0 if c=1 (subtract p), all-ones if c=0
    _ = mask;
    t[1] += t[0] >> 51; t[0] &= 0x7FFFFFFFFFFFF;
    t[2] += t[1] >> 51; t[1] &= 0x7FFFFFFFFFFFF;
    t[3] += t[2] >> 51; t[2] &= 0x7FFFFFFFFFFFF;
    t[4] += t[3] >> 51; t[3] &= 0x7FFFFFFFFFFFF;
    t[4] &= 0x7FFFFFFFFFFFF;

    return t;
}

inline fn feAdd(a: Fe, b: Fe) Fe {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3], a[4] + b[4] };
}

inline fn feSub(a: Fe, b: Fe) Fe {
    // Add 2*p to avoid underflow before subtraction
    return .{
        (a[0] + 0xFFFFFFFFFFFDA) - b[0],
        (a[1] + 0xFFFFFFFFFFFFE) - b[1],
        (a[2] + 0xFFFFFFFFFFFFE) - b[2],
        (a[3] + 0xFFFFFFFFFFFFE) - b[3],
        (a[4] + 0xFFFFFFFFFFFFE) - b[4],
    };
}

fn feMul(a: Fe, b: Fe) Fe {
    // Schoolbook multiplication with lazy reduction
    const m: u128 = 0x7FFFFFFFFFFFF;

    var t: [5]u128 = undefined;
    t[0] = @as(u128, a[0]) * b[0] + @as(u128, a[1]) * b[4] * 19 + @as(u128, a[2]) * b[3] * 19 + @as(u128, a[3]) * b[2] * 19 + @as(u128, a[4]) * b[1] * 19;
    t[1] = @as(u128, a[0]) * b[1] + @as(u128, a[1]) * b[0] + @as(u128, a[2]) * b[4] * 19 + @as(u128, a[3]) * b[3] * 19 + @as(u128, a[4]) * b[2] * 19;
    t[2] = @as(u128, a[0]) * b[2] + @as(u128, a[1]) * b[1] + @as(u128, a[2]) * b[0] + @as(u128, a[3]) * b[4] * 19 + @as(u128, a[4]) * b[3] * 19;
    t[3] = @as(u128, a[0]) * b[3] + @as(u128, a[1]) * b[2] + @as(u128, a[2]) * b[1] + @as(u128, a[3]) * b[0] + @as(u128, a[4]) * b[4] * 19;
    t[4] = @as(u128, a[0]) * b[4] + @as(u128, a[1]) * b[3] + @as(u128, a[2]) * b[2] + @as(u128, a[3]) * b[1] + @as(u128, a[4]) * b[0];

    // Carry propagation
    var r: Fe = undefined;
    t[1] += t[0] >> 51; r[0] = @intCast(t[0] & m);
    t[2] += t[1] >> 51; r[1] = @intCast(t[1] & m);
    t[3] += t[2] >> 51; r[2] = @intCast(t[2] & m);
    t[4] += t[3] >> 51; r[3] = @intCast(t[3] & m);
    const carry: u64 = @intCast(t[4] >> 51);
    r[4] = @intCast(t[4] & m);
    r[0] += carry * 19;
    r[1] += r[0] >> 51; r[0] &= 0x7FFFFFFFFFFFF;

    return r;
}

fn feSq(a: Fe) Fe {
    return feMul(a, a);
}

/// Multiply by a24 = (486662 - 2) / 4, as specified by RFC 7748.
fn feMulA24(a: Fe) Fe {
    const c: u64 = 121665;
    const m: u128 = 0x7FFFFFFFFFFFF;

    var t: [5]u128 = undefined;
    t[0] = @as(u128, a[0]) * c;
    t[1] = @as(u128, a[1]) * c;
    t[2] = @as(u128, a[2]) * c;
    t[3] = @as(u128, a[3]) * c;
    t[4] = @as(u128, a[4]) * c;

    var r: Fe = undefined;
    t[1] += t[0] >> 51; r[0] = @intCast(t[0] & m);
    t[2] += t[1] >> 51; r[1] = @intCast(t[1] & m);
    t[3] += t[2] >> 51; r[2] = @intCast(t[2] & m);
    t[4] += t[3] >> 51; r[3] = @intCast(t[3] & m);
    const carry: u64 = @intCast(t[4] >> 51);
    r[4] = @intCast(t[4] & m);
    r[0] += carry * 19;
    r[1] += r[0] >> 51; r[0] &= 0x7FFFFFFFFFFFF;

    return r;
}

/// Modular inversion via Fermat's little theorem: a^(p-2) mod p.
/// Uses an addition chain for p-2 = 2^255 - 21.
fn feInvert(z: Fe) Fe {
    // Compute z^(2^255-21) using repeated squaring
    var t0 = feSq(z);           // z^2
    var t1 = feSq(t0);          // z^4
    t1 = feSq(t1);              // z^8
    t1 = feMul(z, t1);          // z^9
    t0 = feMul(t0, t1);         // z^11
    var t2 = feSq(t0);          // z^22
    t1 = feMul(t1, t2);         // z^(2^5-1) = z^31

    t2 = feSq(t1);
    for (0..4) |_| t2 = feSq(t2);
    t1 = feMul(t1, t2);         // z^(2^10-1)

    t2 = feSq(t1);
    for (0..9) |_| t2 = feSq(t2);
    t2 = feMul(t1, t2);         // z^(2^20-1)

    var t3 = feSq(t2);
    for (0..19) |_| t3 = feSq(t3);
    t2 = feMul(t2, t3);         // z^(2^40-1)

    t2 = feSq(t2);
    for (0..9) |_| t2 = feSq(t2);
    t1 = feMul(t1, t2);         // z^(2^50-1)

    t2 = feSq(t1);
    for (0..49) |_| t2 = feSq(t2);
    t2 = feMul(t1, t2);         // z^(2^100-1)

    t3 = feSq(t2);
    for (0..99) |_| t3 = feSq(t3);
    t2 = feMul(t2, t3);         // z^(2^200-1)

    t2 = feSq(t2);
    for (0..49) |_| t2 = feSq(t2);
    t1 = feMul(t1, t2);         // z^(2^250-1)

    t1 = feSq(t1);
    t1 = feSq(t1);              // z^(2^252-4)
    t1 = feMul(t1, feSq(feSq(feSq(z))));  // This isn't quite right...

    // Simpler approach: z^(2^255-21)
    // t1 = z^(2^250-1) from above
    // Need: z^(2^255-21) = z^(2^250-1) * z^(2^5) * ... 
    // Actually let's just use the standard 255-bit exponentiation chain:
    // Reset and use a well-known chain
    t1 = feSq(z);               // 2
    t2 = feSq(feSq(t1));        // 8
    t2 = feMul(t2, z);          // 9
    t1 = feMul(t1, t2);         // 11
    t1 = feSq(t1);              // 22
    t1 = feMul(t2, t1);         // 2^5 - 1

    t2 = feSq(t1);
    for (0..4) |_| t2 = feSq(t2);
    t1 = feMul(t2, t1);         // 2^10 - 1

    t2 = feSq(t1);
    for (0..9) |_| t2 = feSq(t2);
    t2 = feMul(t2, t1);         // 2^20 - 1

    t3 = feSq(t2);
    for (0..19) |_| t3 = feSq(t3);
    t2 = feMul(t3, t2);         // 2^40 - 1

    t2 = feSq(t2);
    for (0..9) |_| t2 = feSq(t2);
    t1 = feMul(t2, t1);         // 2^50 - 1

    t2 = feSq(t1);
    for (0..49) |_| t2 = feSq(t2);
    t2 = feMul(t2, t1);         // 2^100 - 1

    t3 = feSq(t2);
    for (0..99) |_| t3 = feSq(t3);
    t2 = feMul(t3, t2);         // 2^200 - 1

    t2 = feSq(t2);
    for (0..49) |_| t2 = feSq(t2);
    t1 = feMul(t2, t1);         // 2^250 - 1

    t1 = feSq(t1);              // 2^251 - 2
    t1 = feSq(t1);              // 2^252 - 4
    t1 = feSq(t1);              // 2^253 - 8
    t1 = feSq(t1);              // 2^254 - 16
    t1 = feSq(t1);              // 2^255 - 32
    return feMul(t1, t0);       // 2^255 - 32 + 11 = 2^255 - 21
}

/// Constant-time conditional swap.
fn cswap(a: *Fe, b: *Fe, swap_bit: u64) void {
    const mask = @as(u64, 0) -% (swap_bit & 1); // all-ones if swap, all-zeros otherwise
    for (0..5) |i| {
        const t = mask & (a[i] ^ b[i]);
        a[i] ^= t;
        b[i] ^= t;
    }
}

// ── Byte loading/storing for 51-bit limbs ───────────────────────────────

fn load51(s: *const [32]u8, offset: usize) u64 {
    var r: u64 = 0;
    const end = @min(offset + 8, 32);
    var i: usize = offset;
    var shift: usize = 0;
    while (i < end) : ({ i += 1; shift += 8; }) {
        r |= @as(u64, s[i]) << @intCast(shift);
    }
    return r;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "x25519: RFC 7748 §6.1 test vector 1" {
    // Alice's private key
    const scalar = [32]u8{
        0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
        0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
        0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
        0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
    };
    // Bob's public key (u-coordinate)
    const point = [32]u8{
        0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb,
        0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c,
        0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b,
        0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c,
    };
    const expected = [32]u8{
        0xc3, 0xda, 0x55, 0x37, 0x9d, 0xe9, 0xc6, 0x90,
        0x8e, 0x94, 0xea, 0x4d, 0xf2, 0x8d, 0x08, 0x4f,
        0x32, 0xec, 0xcf, 0x03, 0x49, 0x1c, 0x71, 0xf7,
        0x54, 0xb4, 0x07, 0x55, 0x77, 0xa2, 0x85, 0x52,
    };

    const result = scalarmult(&scalar, &point);
    for (0..32) |i| {
        if (result[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "x25519: RFC 7748 §6.1 test vector 2" {
    const scalar = [32]u8{
        0x4b, 0x66, 0xe9, 0xd4, 0xd1, 0xb4, 0x67, 0x3c,
        0x5a, 0xd2, 0x26, 0x91, 0x95, 0x7d, 0x6a, 0xf5,
        0xc1, 0x1b, 0x64, 0x21, 0xe0, 0xea, 0x01, 0xd4,
        0x2c, 0xa4, 0x16, 0x9e, 0x79, 0x18, 0xba, 0x0d,
    };
    const point = [32]u8{
        0xe5, 0x21, 0x0f, 0x12, 0x78, 0x68, 0x11, 0xd3,
        0xf4, 0xb7, 0x95, 0x9d, 0x05, 0x38, 0xae, 0x2c,
        0x31, 0xdb, 0xe7, 0x10, 0x6f, 0xc0, 0x3c, 0x3e,
        0xfc, 0x4c, 0xd5, 0x49, 0xc7, 0x15, 0xa4, 0x93,
    };
    const expected = [32]u8{
        0x95, 0xcb, 0xde, 0x94, 0x76, 0xe8, 0x90, 0x7d,
        0x7a, 0xad, 0xe4, 0x5c, 0xb4, 0xb8, 0x73, 0xf8,
        0x8b, 0x59, 0x5a, 0x68, 0x79, 0x9f, 0xa1, 0x52,
        0xe6, 0xf8, 0xf7, 0x64, 0x7a, 0xac, 0x79, 0x57,
    };

    const result = scalarmult(&scalar, &point);
    for (0..32) |i| {
        if (result[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "x25519: basepoint multiplication" {
    // RFC 7748 §6.1: scalar * 9 (basepoint)
    const scalar = [32]u8{
        0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
        0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
        0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
        0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
    };

    const pub_key = publicKey(&scalar);
    // Should be non-zero
    var all_zero = true;
    for (pub_key) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    if (all_zero) return error.TestUnexpectedResult;
}

test "x25519: DH key agreement symmetry" {
    // Alice and Bob compute the same shared secret
    const alice_sk = [32]u8{
        0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d,
        0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
        0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
        0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
    };
    const bob_sk = [32]u8{
        0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b,
        0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
        0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd,
        0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
    };

    const alice_pk = publicKey(&alice_sk);
    const bob_pk = publicKey(&bob_sk);

    const alice_shared = sharedSecret(&alice_sk, &bob_pk);
    const bob_shared = sharedSecret(&bob_sk, &alice_pk);

    for (0..32) |i| {
        if (alice_shared[i] != bob_shared[i]) return error.TestUnexpectedResult;
    }
}
