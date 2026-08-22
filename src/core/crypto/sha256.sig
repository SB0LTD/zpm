// @zpm/crypto/sha256 — Freestanding SHA-256 (FIPS 180-4).
// Zero allocator. Pure computation. No std dependency.

pub const DIGEST_SIZE: usize = 32;
pub const BLOCK_SIZE: usize = 64;

/// One-shot hash.
pub fn hash(msg: []const u8, out: *[32]u8) void {
    var ctx = Context.init();
    ctx.update(msg);
    ctx.final(out);
}

/// Incremental hashing context.
pub const Context = struct {
    h: [8]u32 = IV,
    buf: [64]u8 = @splat(0),
    buf_len: u8 = 0,
    total_len: u64 = 0,

    const IV = [8]u32{
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };

    pub fn init() Context {
        return .{};
    }

    pub fn update(self: *Context, data: []const u8) void {
        var off: usize = 0;
        self.total_len += data.len;

        // Fill partial buffer
        if (self.buf_len > 0) {
            const space: usize = 64 - self.buf_len;
            const fill = @min(space, data.len);
            @memcpy(self.buf[self.buf_len..][0..fill], data[0..fill]);
            self.buf_len += @intCast(fill);
            off = fill;
            if (self.buf_len == 64) {
                compress(&self.buf, &self.h);
                self.buf_len = 0;
            }
        }

        // Process full blocks
        while (off + 64 <= data.len) : (off += 64) {
            compress(data[off..][0..64], &self.h);
        }

        // Buffer remainder
        const rem = data.len - off;
        if (rem > 0) {
            @memcpy(self.buf[0..rem], data[off..][0..rem]);
            self.buf_len = @intCast(rem);
        }
    }

    pub fn final(self: *Context, out: *[32]u8) void {
        // Padding: append 1 bit, zeros, then 64-bit big-endian length
        var pad: [128]u8 = @splat(0);
        const rem: usize = self.buf_len;
        @memcpy(pad[0..rem], self.buf[0..rem]);
        pad[rem] = 0x80;
        const blocks: usize = if (rem >= 56) 2 else 1;
        const bits = self.total_len * 8;
        const lp = blocks * 64 - 8;
        for (0..8) |i| pad[lp + i] = @intCast((bits >> @intCast((7 - i) * 8)) & 0xFF);
        for (0..blocks) |b| compress(pad[b * 64 ..][0..64], &self.h);

        // Output digest
        for (0..8) |i| for (0..4) |j| {
            out[i * 4 + j] = @intCast((self.h[i] >> @intCast((3 - j) * 8)) & 0xFF);
        };
    }
};

/// HMAC-SHA-256.
pub fn hmac(key: []const u8, msg: []const u8, out: *[32]u8) void {
    var k: [64]u8 = @splat(0);
    if (key.len > 64) {
        hash(key, k[0..32]);
    } else {
        @memcpy(k[0..key.len], key);
    }

    // Inner hash: SHA-256(ipad || msg)
    var inner = Context.init();
    var ipad: [64]u8 = undefined;
    for (0..64) |i| ipad[i] = k[i] ^ 0x36;
    inner.update(&ipad);
    inner.update(msg);
    var ih: [32]u8 = undefined;
    inner.final(&ih);

    // Outer hash: SHA-256(opad || inner_hash)
    var outer = Context.init();
    var opad: [64]u8 = undefined;
    for (0..64) |i| opad[i] = k[i] ^ 0x5c;
    outer.update(&opad);
    outer.update(&ih);
    outer.final(out);
}

// ══════════════════════════════════════════════════════════════════════════════
// Block compression
// ══════════════════════════════════════════════════════════════════════════════

const K = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

fn rotr(x: u32, n: u5) u32 {
    return (x >> n) | (x << @intCast(32 - @as(u6, n)));
}

fn compress(blk: *const [64]u8, state: *[8]u32) void {
    var w: [64]u32 = undefined;
    for (0..16) |i| {
        w[i] = (@as(u32, blk[i * 4]) << 24) | (@as(u32, blk[i * 4 + 1]) << 16) |
            (@as(u32, blk[i * 4 + 2]) << 8) | blk[i * 4 + 3];
    }
    for (16..64) |i| {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
    }
    var v = state.*;
    for (0..64) |i| {
        const S1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25);
        const ch = (v[4] & v[5]) ^ (~v[4] & v[6]);
        const t1 = v[7] +% S1 +% ch +% K[i] +% w[i];
        const S0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22);
        const maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
        const t2 = S0 +% maj;
        v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] +% t1;
        v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = t1 +% t2;
    }
    for (0..8) |i| state[i] +%= v[i];
}
