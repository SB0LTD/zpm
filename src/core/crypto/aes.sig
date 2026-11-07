// AES (Advanced Encryption Standard) — FIPS 197
// Layer 0: Pure computation, no platform deps, no allocator.
//
// Software implementation of AES-128 and AES-256. Provides:
// - Key expansion (key schedule generation)
// - Single-block encrypt/decrypt (ECB mode, 16-byte blocks)
// - Counter mode (AES-CTR) for GCM's encryption layer
//
// Constant-time: no table lookup, branch or memory address depends on key or
// data. The state is one u128 (byte i at bits 8i..8i+7). SubBytes is the
// Boyar-Peralta bitsliced S-box circuit run on all 16 bytes at once (bit b of
// every byte forms one plane), MixColumns is SWAR xtime, and ShiftRows is a
// fixed byte permutation. The kernel target is -mcpu=baseline (no +aes), so
// this path is what runs there; the S-box tables below are test references.

const std = @import("std");

/// AES block size in bytes.
pub const BLOCK_SIZE = 16;

/// AES-128 key size.
pub const KEY_128 = 16;

/// AES-256 key size.
pub const KEY_256 = 32;

/// AES-128 expanded key: 11 round keys * 16 bytes = 176 bytes.
pub const EXPANDED_128 = 176;

/// AES-256 expanded key: 15 round keys * 16 bytes = 240 bytes.
pub const EXPANDED_256 = 240;

// ── Round Constants ──────────────────────────────────────────────────────

const RCON: [10]u8 = .{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 };

// ── Lane masks ───────────────────────────────────────────────────────────

/// Bit 0 of every byte.
const LSB_MASK: u128 = 0x01010101010101010101010101010101;
/// Bits 0..6 of every byte.
const LOW7_MASK: u128 = 0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
/// Low three bytes of every 32-bit column.
const COL_LOW3: u128 = 0x00ffffff00ffffff00ffffff00ffffff;
/// Top byte of every 32-bit column.
const COL_TOP1: u128 = 0xff000000ff000000ff000000ff000000;

inline fn load(block: *const [16]u8) u128 {
    return std.mem.readInt(u128, block, .little);
}

inline fn store(block: *[16]u8, s: u128) void {
    std.mem.writeInt(u128, block, s, .little);
}

// ── AES Context ─────────────────────────────────────────────────────────

pub const Aes128 = struct {
    round_keys: [11]u128,

    /// Expand a 16-byte key into 11 round keys.
    pub fn init(key: *const [16]u8) Aes128 {
        var rk: [176]u8 = undefined;
        @memcpy(rk[0..16], key);

        var i: usize = 16;
        var rcon_idx: usize = 0;
        while (i < 176) : (i += 4) {
            var tmp: [4]u8 = .{ rk[i - 4], rk[i - 3], rk[i - 2], rk[i - 1] };

            if (i % 16 == 0) {
                // RotWord + SubWord + Rcon
                tmp = subWord(.{ tmp[1], tmp[2], tmp[3], tmp[0] });
                tmp[0] ^= RCON[rcon_idx];
                rcon_idx += 1;
            }

            rk[i + 0] = rk[i - 16] ^ tmp[0];
            rk[i + 1] = rk[i - 15] ^ tmp[1];
            rk[i + 2] = rk[i - 14] ^ tmp[2];
            rk[i + 3] = rk[i - 13] ^ tmp[3];
        }

        var out: Aes128 = .{ .round_keys = undefined };
        for (0..11) |r| out.round_keys[r] = load(rk[r * 16 ..][0..16]);
        std.crypto.secureZero(u8, &rk);
        return out;
    }

    /// Encrypt a single 16-byte block in place.
    pub fn encryptBlock(self: *const Aes128, block: *[16]u8) void {
        store(block, encryptState(&self.round_keys, load(block)));
    }

    /// Decrypt a single 16-byte block in place.
    pub fn decryptBlock(self: *const Aes128, block: *[16]u8) void {
        store(block, decryptState(&self.round_keys, load(block)));
    }

    /// AES-CTR: encrypt/decrypt `data` in place using the given nonce and starting counter.
    /// The counter is a 32-bit big-endian value in bytes [12..16] of the counter block.
    pub fn ctr(self: *const Aes128, nonce: *const [12]u8, counter_start: u32, data: []u8) void {
        ctrGeneric(&self.round_keys, nonce, counter_start, data);
    }
};

pub const Aes256 = struct {
    round_keys: [15]u128,

    /// Expand a 32-byte key into 15 round keys.
    pub fn init(key: *const [32]u8) Aes256 {
        var rk: [240]u8 = undefined;
        @memcpy(rk[0..32], key);

        var i: usize = 32;
        var rcon_idx: usize = 0;
        while (i < 240) : (i += 4) {
            var tmp: [4]u8 = .{ rk[i - 4], rk[i - 3], rk[i - 2], rk[i - 1] };

            if (i % 32 == 0) {
                // RotWord + SubWord + Rcon
                tmp = subWord(.{ tmp[1], tmp[2], tmp[3], tmp[0] });
                tmp[0] ^= RCON[rcon_idx];
                rcon_idx += 1;
            } else if (i % 32 == 16) {
                // SubWord only (AES-256 extra step)
                tmp = subWord(tmp);
            }

            rk[i + 0] = rk[i - 32] ^ tmp[0];
            rk[i + 1] = rk[i - 31] ^ tmp[1];
            rk[i + 2] = rk[i - 30] ^ tmp[2];
            rk[i + 3] = rk[i - 29] ^ tmp[3];
        }

        var out: Aes256 = .{ .round_keys = undefined };
        for (0..15) |r| out.round_keys[r] = load(rk[r * 16 ..][0..16]);
        std.crypto.secureZero(u8, &rk);
        return out;
    }

    /// Encrypt a single 16-byte block in place.
    pub fn encryptBlock(self: *const Aes256, block: *[16]u8) void {
        store(block, encryptState(&self.round_keys, load(block)));
    }

    /// Decrypt a single 16-byte block in place.
    pub fn decryptBlock(self: *const Aes256, block: *[16]u8) void {
        store(block, decryptState(&self.round_keys, load(block)));
    }

    /// AES-CTR: encrypt/decrypt `data` in place.
    pub fn ctr(self: *const Aes256, nonce: *const [12]u8, counter_start: u32, data: []u8) void {
        ctrGeneric(&self.round_keys, nonce, counter_start, data);
    }
};

/// SubWord for the key schedule: the bitsliced S-box on the low 4 bytes.
fn subWord(w: [4]u8) [4]u8 {
    const x: u128 = @as(u128, std.mem.readInt(u32, &w, .little));
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, @truncate(subBytes(x)), .little);
    return out;
}

// ── Generic encrypt/decrypt (shared by AES-128 and AES-256) ─────────────
// `round_keys.len - 1` is the round count (10 or 14), a public constant.

fn encryptState(round_keys: []const u128, input: u128) u128 {
    const rounds = round_keys.len - 1;
    var s = input ^ round_keys[0];

    var round: usize = 1;
    while (round < rounds) : (round += 1) {
        s = mixColumns(shiftRows(subBytes(s))) ^ round_keys[round];
    }

    // Final round (no MixColumns)
    return shiftRows(subBytes(s)) ^ round_keys[rounds];
}

fn decryptState(round_keys: []const u128, input: u128) u128 {
    const rounds = round_keys.len - 1;
    var s = input ^ round_keys[rounds];

    var round: usize = rounds - 1;
    while (round >= 1) : (round -= 1) {
        s = invMixColumns(invSubBytes(invShiftRows(s)) ^ round_keys[round]);
    }

    // Final round (no InvMixColumns)
    return invSubBytes(invShiftRows(s)) ^ round_keys[0];
}

fn ctrGeneric(round_keys: []const u128, nonce: *const [12]u8, counter_start: u32, data: []u8) void {
    var counter = counter_start;
    var offset: usize = 0;

    while (offset < data.len) {
        // Build counter block: nonce[12] || counter[4] (big-endian)
        var ctr_block: [16]u8 = undefined;
        @memcpy(ctr_block[0..12], nonce);
        std.mem.writeInt(u32, ctr_block[12..16], counter, .big);

        // Encrypt counter block to get keystream
        store(&ctr_block, encryptState(round_keys, load(&ctr_block)));

        // XOR keystream with data
        const remaining = data.len - offset;
        const chunk = @min(remaining, 16);
        for (0..chunk) |i| {
            data[offset + i] ^= ctr_block[i];
        }

        offset += chunk;
        counter +%= 1;
    }
}

// ── SubBytes (bitsliced, Boyar-Peralta) ──────────────────────────────────
// J. Boyar and R. Peralta, "A depth-16 circuit for the AES S-box" (2011),
// in the form used by BearSSL's aes_ct. Plane b holds bit b of every byte in
// that byte's bit 0, so the 113 gates act on all 16 bytes in parallel. NOT
// gates dirty the other bit positions; they are masked off on reassembly.

fn subBytes(s: u128) u128 {
    const x0 = (s >> 7) & LSB_MASK;
    const x1 = (s >> 6) & LSB_MASK;
    const x2 = (s >> 5) & LSB_MASK;
    const x3 = (s >> 4) & LSB_MASK;
    const x4 = (s >> 3) & LSB_MASK;
    const x5 = (s >> 2) & LSB_MASK;
    const x6 = (s >> 1) & LSB_MASK;
    const x7 = s & LSB_MASK;

    // Top linear transformation.
    const y14 = x3 ^ x5;
    const y13 = x0 ^ x6;
    const y9 = x0 ^ x3;
    const y8 = x0 ^ x5;
    const t0 = x1 ^ x2;
    const y1 = t0 ^ x7;
    const y4 = y1 ^ x3;
    const y12 = y13 ^ y14;
    const y2 = y1 ^ x0;
    const y5 = y1 ^ x6;
    const y3 = y5 ^ y8;
    const t1 = x4 ^ y12;
    const y15 = t1 ^ x5;
    const y20 = t1 ^ x1;
    const y6 = y15 ^ x7;
    const y10 = y15 ^ t0;
    const y11 = y20 ^ y9;
    const y7 = x7 ^ y11;
    const y17 = y10 ^ y11;
    const y19 = y10 ^ y8;
    const y16 = t0 ^ y11;
    const y21 = y13 ^ y16;
    const y18 = x0 ^ y16;

    // Non-linear section.
    const t2 = y12 & y15;
    const t3 = y3 & y6;
    const t4 = t3 ^ t2;
    const t5 = y4 & x7;
    const t6 = t5 ^ t2;
    const t7 = y13 & y16;
    const t8 = y5 & y1;
    const t9 = t8 ^ t7;
    const t10 = y2 & y7;
    const t11 = t10 ^ t7;
    const t12 = y9 & y11;
    const t13 = y14 & y17;
    const t14 = t13 ^ t12;
    const t15 = y8 & y10;
    const t16 = t15 ^ t12;
    const t17 = t4 ^ t14;
    const t18 = t6 ^ t16;
    const t19 = t9 ^ t14;
    const t20 = t11 ^ t16;
    const t21 = t17 ^ y20;
    const t22 = t18 ^ y19;
    const t23 = t19 ^ y21;
    const t24 = t20 ^ y18;

    const t25 = t21 ^ t22;
    const t26 = t21 & t23;
    const t27 = t24 ^ t26;
    const t28 = t25 & t27;
    const t29 = t28 ^ t22;
    const t30 = t23 ^ t24;
    const t31 = t22 ^ t26;
    const t32 = t31 & t30;
    const t33 = t32 ^ t24;
    const t34 = t23 ^ t33;
    const t35 = t27 ^ t33;
    const t36 = t24 & t35;
    const t37 = t36 ^ t34;
    const t38 = t27 ^ t36;
    const t39 = t29 & t38;
    const t40 = t25 ^ t39;

    const t41 = t40 ^ t37;
    const t42 = t29 ^ t33;
    const t43 = t29 ^ t40;
    const t44 = t33 ^ t37;
    const t45 = t42 ^ t41;
    const z0 = t44 & y15;
    const z1 = t37 & y6;
    const z2 = t33 & x7;
    const z3 = t43 & y16;
    const z4 = t40 & y1;
    const z5 = t29 & y7;
    const z6 = t42 & y11;
    const z7 = t45 & y17;
    const z8 = t41 & y10;
    const z9 = t44 & y12;
    const z10 = t37 & y3;
    const z11 = t33 & y4;
    const z12 = t43 & y13;
    const z13 = t40 & y5;
    const z14 = t29 & y2;
    const z15 = t42 & y9;
    const z16 = t45 & y14;
    const z17 = t41 & y8;

    // Bottom linear transformation.
    const t46 = z15 ^ z16;
    const t47 = z10 ^ z11;
    const t48 = z5 ^ z13;
    const t49 = z9 ^ z10;
    const t50 = z2 ^ z12;
    const t51 = z2 ^ z5;
    const t52 = z7 ^ z8;
    const t53 = z0 ^ z3;
    const t54 = z6 ^ z7;
    const t55 = z16 ^ z17;
    const t56 = z12 ^ t48;
    const t57 = t50 ^ t53;
    const t58 = z4 ^ t46;
    const t59 = z3 ^ t54;
    const t60 = t46 ^ t57;
    const t61 = z14 ^ t57;
    const t62 = t52 ^ t58;
    const t63 = t49 ^ t58;
    const t64 = z4 ^ t59;
    const t65 = t61 ^ t62;
    const t66 = z1 ^ t63;
    const s0 = t59 ^ t63;
    const s6 = t56 ^ ~t62;
    const s7 = t48 ^ ~t60;
    const t67 = t64 ^ t65;
    const s3 = t53 ^ t66;
    const s4 = t51 ^ t66;
    const s5 = t47 ^ t65;
    const s1 = t64 ^ ~s3;
    const s2 = t55 ^ ~t67;

    return ((s0 & LSB_MASK) << 7) | ((s1 & LSB_MASK) << 6) |
        ((s2 & LSB_MASK) << 5) | ((s3 & LSB_MASK) << 4) |
        ((s4 & LSB_MASK) << 3) | ((s5 & LSB_MASK) << 2) |
        ((s6 & LSB_MASK) << 1) | (s7 & LSB_MASK);
}

/// Linear part of the inverse affine map, per byte: rotl1 ^ rotl3 ^ rotl6.
inline fn invAffineLinear(s: u128) u128 {
    return rotlBytes(s, 1) ^ rotlBytes(s, 3) ^ rotlBytes(s, 6);
}

/// Rotate every byte of `s` left by `n` bits.
inline fn rotlBytes(s: u128, comptime n: u7) u128 {
    const keep: u128 = LSB_MASK * ((@as(u128, 1) << (8 - n)) - 1);
    return ((s & keep) << n) | ((s >> (8 - n)) & (LSB_MASK * ((@as(u128, 1) << n) - 1)));
}

/// InvSubBytes from the forward circuit. With S(x) = M(x^-1) ^ 0x63 and
/// L = M^-1 (invAffineLinear): x^-1 = L(S(x) ^ 0x63), so
/// InvS(y) = (L(y ^ 0x63))^-1 = L(S(L(y) ^ 0x05) ^ 0x63).
fn invSubBytes(s: u128) u128 {
    const c05: u128 = LSB_MASK * 0x05;
    const c63: u128 = LSB_MASK * 0x63;
    return invAffineLinear(subBytes(invAffineLinear(s) ^ c05) ^ c63);
}

// ── ShiftRows ────────────────────────────────────────────────────────────
// Byte index = col * 4 + row. Row r rotates left by r columns.

fn permuteBytes(s: u128, comptime src: [16]u8) u128 {
    var out: u128 = 0;
    inline for (0..16) |i| {
        out |= ((s >> (@as(u7, src[i]) * 8)) & 0xff) << (i * 8);
    }
    return out;
}

const SHIFT_ROWS_SRC: [16]u8 = blk: {
    var p: [16]u8 = undefined;
    for (0..4) |col| {
        for (0..4) |row| p[col * 4 + row] = ((col + row) % 4) * 4 + row;
    }
    break :blk p;
};

const INV_SHIFT_ROWS_SRC: [16]u8 = blk: {
    var p: [16]u8 = undefined;
    for (0..4) |col| {
        for (0..4) |row| p[col * 4 + row] = ((col + 4 - row) % 4) * 4 + row;
    }
    break :blk p;
};

fn shiftRows(s: u128) u128 {
    return permuteBytes(s, SHIFT_ROWS_SRC);
}

fn invShiftRows(s: u128) u128 {
    return permuteBytes(s, INV_SHIFT_ROWS_SRC);
}

// ── MixColumns ───────────────────────────────────────────────────────────

/// Multiply every byte by 2 in GF(2^8) (x^8 + x^4 + x^3 + x + 1), branch-free.
inline fn xtime(s: u128) u128 {
    return ((s & LOW7_MASK) << 1) ^ (((s >> 7) & LSB_MASK) * 0x1b);
}

/// Rotate every 32-bit column down by one byte: byte i takes byte i+1.
inline fn rotCol(s: u128) u128 {
    return ((s >> 8) & COL_LOW3) | ((s << 24) & COL_TOP1);
}

/// out_i = 2*a_i ^ 3*a_{i+1} ^ a_{i+2} ^ a_{i+3} = xtime(a_i ^ a_{i+1}) ^ a_{i+1} ^ a_{i+2} ^ a_{i+3}.
fn mixColumns(s: u128) u128 {
    const r1 = rotCol(s);
    const r2 = rotCol(r1);
    const r3 = rotCol(r2);
    return xtime(s ^ r1) ^ r1 ^ r2 ^ r3;
}

/// InvMixColumns = MixColumns after multiplying each column by
/// 4x^2 + 5 (the standard decomposition): a_i ^= 4 * (a_i ^ a_{i+2}).
fn invMixColumns(s: u128) u128 {
    const u = xtime(xtime(s ^ rotCol(rotCol(s))));
    return mixColumns(s ^ u);
}

// ── Tests ────────────────────────────────────────────────────────────────

// FIPS 197 §5.1.1 / §5.3.2 tables, used only to check the circuit.
const SBOX_REF: [256]u8 = .{
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
};

const INV_SBOX_REF: [256]u8 = .{
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
};


test "aes128: NIST FIPS 197 Appendix B" {
    // Key: 2b7e151628aed2a6abf7158809cf4f3c
    // Plaintext: 3243f6a8885a308d313198a2e0370734
    // Ciphertext: 3925841d02dc09fbdc118597196a0b32
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    const plaintext = [16]u8{
        0x32, 0x43, 0xf6, 0xa8, 0x88, 0x5a, 0x30, 0x8d,
        0x31, 0x31, 0x98, 0xa2, 0xe0, 0x37, 0x07, 0x34,
    };
    const expected = [16]u8{
        0x39, 0x25, 0x84, 0x1d, 0x02, 0xdc, 0x09, 0xfb,
        0xdc, 0x11, 0x85, 0x97, 0x19, 0x6a, 0x0b, 0x32,
    };

    const ctx = Aes128.init(&key);
    var block = plaintext;
    ctx.encryptBlock(&block);

    for (0..16) |i| {
        if (block[i] != expected[i]) return error.TestUnexpectedResult;
    }

    // Decrypt should recover plaintext
    ctx.decryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != plaintext[i]) return error.TestUnexpectedResult;
    }
}

test "aes128: NIST SP 800-38A F.1.1 ECB-AES128 Encrypt" {
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    // Block 1
    var block = [16]u8{
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
    };
    const expected = [16]u8{
        0x3a, 0xd7, 0x7b, 0xb4, 0x0d, 0x7a, 0x36, 0x60,
        0xa8, 0x9e, 0xca, 0xf3, 0x24, 0x66, 0xef, 0x97,
    };

    const ctx = Aes128.init(&key);
    ctx.encryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != expected[i]) return error.TestUnexpectedResult;
    }
}

test "aes256: NIST FIPS 197 Appendix C.3" {
    const key = [32]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };
    const plaintext = [16]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    const expected = [16]u8{
        0x8e, 0xa2, 0xb7, 0xca, 0x51, 0x67, 0x45, 0xbf,
        0xea, 0xfc, 0x49, 0x90, 0x4b, 0x49, 0x60, 0x89,
    };

    const ctx = Aes256.init(&key);
    var block = plaintext;
    ctx.encryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != expected[i]) return error.TestUnexpectedResult;
    }

    ctx.decryptBlock(&block);
    for (0..16) |i| {
        if (block[i] != plaintext[i]) return error.TestUnexpectedResult;
    }
}

test "aes128: CTR mode basic" {
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    const nonce = [12]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb };
    const ctx = Aes128.init(&key);

    // Encrypt then decrypt should yield original
    var data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A };
    const original = data;

    ctx.ctr(&nonce, 1, &data);
    // Encrypted should differ from original
    var same = true;
    for (0..data.len) |i| {
        if (data[i] != original[i]) { same = false; break; }
    }
    if (same) return error.TestUnexpectedResult;

    // Decrypt (CTR is symmetric)
    ctx.ctr(&nonce, 1, &data);
    for (0..data.len) |i| {
        if (data[i] != original[i]) return error.TestUnexpectedResult;
    }
}

test "aes128: encrypt/decrypt round trip multiple blocks" {
    const key = [16]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const ctx = Aes128.init(&key);

    var block: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    const original = block;

    ctx.encryptBlock(&block);
    ctx.decryptBlock(&block);

    for (0..16) |i| {
        if (block[i] != original[i]) return error.TestUnexpectedResult;
    }
}

test "aes: bitsliced S-box matches FIPS 197 table for all 256 inputs" {
    var v: usize = 0;
    while (v < 256) : (v += 16) {
        var in: [16]u8 = undefined;
        for (0..16) |i| in[i] = @intCast(v + i);
        var fwd: [16]u8 = undefined;
        var inv: [16]u8 = undefined;
        store(&fwd, subBytes(load(&in)));
        store(&inv, invSubBytes(load(&in)));
        for (0..16) |i| {
            try std.testing.expectEqual(SBOX_REF[v + i], fwd[i]);
            try std.testing.expectEqual(INV_SBOX_REF[v + i], inv[i]);
        }
    }
}

test "aes: cross-check against std.crypto.core.aes on random keys and blocks" {
    const std_aes = std.crypto.core.aes;
    var prng = std.Random.DefaultPrng.init(0x6165735f63726f73);
    const rnd = prng.random();
    for (0..200) |_| {
        var k128: [16]u8 = undefined;
        var k256: [32]u8 = undefined;
        var pt: [16]u8 = undefined;
        rnd.bytes(&k128);
        rnd.bytes(&k256);
        rnd.bytes(&pt);

        var want: [16]u8 = undefined;
        var block = pt;
        const a = Aes128.init(&k128);
        std_aes.Aes128.initEnc(k128).encrypt(&want, &pt);
        a.encryptBlock(&block);
        try std.testing.expectEqualSlices(u8, &want, &block);
        a.decryptBlock(&block);
        try std.testing.expectEqualSlices(u8, &pt, &block);

        block = pt;
        const b = Aes256.init(&k256);
        std_aes.Aes256.initEnc(k256).encrypt(&want, &pt);
        b.encryptBlock(&block);
        try std.testing.expectEqualSlices(u8, &want, &block);
        std_aes.Aes256.initDec(k256).decrypt(&want, &pt);
        block = pt;
        b.decryptBlock(&block);
        try std.testing.expectEqualSlices(u8, &want, &block);
    }
}

test "aes128: NIST SP 800-38A F.5.1 CTR-AES128 keystream" {
    const key = [16]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    // Initial counter f0f1...fcfdfeff: nonce f0..fb, counter 0xfcfdfeff, so
    // block 2 also checks the 32-bit counter wrap to 0xfcfdff00.
    const nonce = [12]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb };
    var data = [32]u8{
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
        0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c, 0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
    };
    const expected = [32]u8{
        0x87, 0x4d, 0x61, 0x91, 0xb6, 0x20, 0xe3, 0x26, 0x1b, 0xef, 0x68, 0x64, 0x99, 0x0d, 0xb6, 0xce,
        0x98, 0x06, 0xf6, 0x6b, 0x79, 0x70, 0xfd, 0xff, 0x86, 0x17, 0x18, 0x7b, 0xb9, 0xff, 0xfd, 0xff,
    };
    Aes128.init(&key).ctr(&nonce, 0xfcfdfeff, &data);
    try std.testing.expectEqualSlices(u8, &expected, &data);
}
