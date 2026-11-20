//! @zpm/gfxapi bc — Direct3D's block-compressed texture formats (BC1 to
//! BC5: DXT1, DXT3, DXT5, ATI1/RGTC1 and ATI2/RGTC2; GL's S3TC and RGTC)
//! decoded on the CPU into texels the engine stores and samples:
//!
//! - BC1, BC2, BC3: RGBA8 (an sRGB format's bytes as they are: the
//!   texture reads them as sRGB);
//! - BC4 and BC5 unsigned: R8 and RG8;
//! - BC4 and BC5 signed: R32F and RG32F (-1 to 1).
//!
//! A block is 4x4 texels: 8 bytes (BC1, BC4) or 16. Decoding follows the
//! Direct3D 11 functional specification's interpolation (each 8-bit
//! endpoint interpolated, rounded down as its reference decoder does).
//!
//! Not yet: BC6H, BC7.

const std = @import("std");

pub const Kind = enum {
    bc1,
    bc2,
    bc3,
    bc4u,
    bc4s,
    bc5u,
    bc5s,

    /// A block's bytes.
    pub fn blockBytes(k: Kind) u32 {
        return switch (k) {
            .bc1, .bc4u, .bc4s => 8,
            else => 16,
        };
    }

    /// A decoded texel's bytes (RGBA8 4, R8 1, RG8 2, R32F 4, RG32F 8).
    pub fn texelBytes(k: Kind) u32 {
        return switch (k) {
            .bc1, .bc2, .bc3 => 4,
            .bc4u => 1,
            .bc5u => 2,
            .bc4s => 4,
            .bc5s => 8,
        };
    }
};

/// Blocks across `w` texels (or down `h`).
pub fn blocks(n: u32) u32 {
    return (n + 3) / 4;
}

/// One block's 16 texels into `out`, rows `stride` bytes apart; only the
/// first `w` columns and `h` rows are written (a level smaller than a
/// block, or a texture's right and bottom edge).
pub fn decode(k: Kind, block: []const u8, out: []u8, stride: usize, w: u32, h: u32) void {
    var px: [16][4]u8 = undefined;
    var fl: [16][2]f32 = undefined;
    switch (k) {
        .bc1 => color(block[0..8], &px, true),
        .bc2 => {
            color(block[8..16], &px, false);
            const a = std.mem.readInt(u64, block[0..8], .little);
            for (0..16) |i| {
                const v: u8 = @truncate(a >> @intCast(4 * i) & 0xf);
                px[i][3] = v << 4 | v;
            }
        },
        .bc3 => {
            color(block[8..16], &px, false);
            var a: [16]u8 = undefined;
            alphaU(block[0..8], &a);
            for (0..16) |i| px[i][3] = a[i];
        },
        .bc4u, .bc5u => {
            var r: [16]u8 = undefined;
            alphaU(block[0..8], &r);
            for (0..16) |i| px[i][0] = r[i];
            if (k == .bc5u) {
                alphaU(block[8..16], &r);
                for (0..16) |i| px[i][1] = r[i];
            }
        },
        .bc4s, .bc5s => {
            var r: [16]f32 = undefined;
            alphaS(block[0..8], &r);
            for (0..16) |i| fl[i][0] = r[i];
            if (k == .bc5s) {
                alphaS(block[8..16], &r);
                for (0..16) |i| fl[i][1] = r[i];
            }
        },
    }
    const tb = k.texelBytes();
    for (0..@min(h, 4)) |y| {
        for (0..@min(w, 4)) |x| {
            const i = y * 4 + x;
            const d = out[y * stride + x * tb ..][0..tb];
            switch (k) {
                .bc1, .bc2, .bc3 => d[0..4].* = px[i],
                .bc4u => d[0] = px[i][0],
                .bc5u => d[0..2].* = .{ px[i][0], px[i][1] },
                .bc4s => std.mem.writeInt(u32, d[0..4], @bitCast(fl[i][0]), .little),
                .bc5s => {
                    std.mem.writeInt(u32, d[0..4], @bitCast(fl[i][0]), .little);
                    std.mem.writeInt(u32, d[4..8], @bitCast(fl[i][1]), .little);
                },
            }
        }
    }
}

/// A 5-, 6-bit channel to 8 bits (the top bits repeated).
fn expand(v: u32, bits: u5) u32 {
    return v << @intCast(8 - bits) | v >> @intCast(2 * bits - 8);
}

fn rgb565(v: u16) [3]u32 {
    return .{ expand(v >> 11, 5), expand(v >> 5 & 0x3f, 6), expand(v & 0x1f, 5) };
}

/// A BC1 colour block (BC2's and BC3's colours: always four colours).
fn color(b: *const [8]u8, out: *[16][4]u8, bc1: bool) void {
    const c0 = std.mem.readInt(u16, b[0..2], .little);
    const c1 = std.mem.readInt(u16, b[2..4], .little);
    const e0 = rgb565(c0);
    const e1 = rgb565(c1);
    var pal: [4][4]u8 = undefined;
    for (0..3) |c| {
        pal[0][c] = @intCast(e0[c]);
        pal[1][c] = @intCast(e1[c]);
    }
    pal[0][3] = 255;
    pal[1][3] = 255;
    if (c0 > c1 or !bc1) {
        for (0..3) |c| {
            pal[2][c] = @intCast((2 * e0[c] + e1[c]) / 3);
            pal[3][c] = @intCast((e0[c] + 2 * e1[c]) / 3);
        }
        pal[2][3] = 255;
        pal[3][3] = 255;
    } else {
        for (0..3) |c| pal[2][c] = @intCast((e0[c] + e1[c]) / 2);
        pal[2][3] = 255;
        pal[3] = .{ 0, 0, 0, 0 };
    }
    const idx = std.mem.readInt(u32, b[4..8], .little);
    for (0..16) |i| out[i] = pal[idx >> @intCast(2 * i) & 3];
}

/// A BC3 alpha block (BC4's and BC5's unsigned channels).
fn alphaU(b: *const [8]u8, out: *[16]u8) void {
    const a0: u32 = b[0];
    const a1: u32 = b[1];
    var pal: [8]u8 = undefined;
    pal[0] = b[0];
    pal[1] = b[1];
    if (a0 > a1) {
        for (1..7) |i| pal[i + 1] = @intCast(((7 - i) * a0 + i * a1) / 7);
    } else {
        for (1..5) |i| pal[i + 1] = @intCast(((5 - i) * a0 + i * a1) / 5);
        pal[6] = 0;
        pal[7] = 255;
    }
    const idx = std.mem.readInt(u48, b[2..8], .little);
    for (0..16) |i| out[i] = pal[@intCast(idx >> @intCast(3 * i) & 7)];
}

/// A signed BC4 block: values -1 to 1 (-128 reads as -127).
fn alphaS(b: *const [8]u8, out: *[16]f32) void {
    const a0: i32 = @max(@as(i8, @bitCast(b[0])), -127);
    const a1: i32 = @max(@as(i8, @bitCast(b[1])), -127);
    var pal: [8]f32 = undefined;
    pal[0] = @as(f32, @floatFromInt(a0)) / 127.0;
    pal[1] = @as(f32, @floatFromInt(a1)) / 127.0;
    if (a0 > a1) {
        for (1..7) |i| {
            const v = @divTrunc(@as(i32, @intCast(7 - i)) * a0 + @as(i32, @intCast(i)) * a1, 7);
            pal[i + 1] = @as(f32, @floatFromInt(v)) / 127.0;
        }
    } else {
        for (1..5) |i| {
            const v = @divTrunc(@as(i32, @intCast(5 - i)) * a0 + @as(i32, @intCast(i)) * a1, 5);
            pal[i + 1] = @as(f32, @floatFromInt(v)) / 127.0;
        }
        pal[6] = -1;
        pal[7] = 1;
    }
    const idx = std.mem.readInt(u48, b[2..8], .little);
    for (0..16) |i| out[i] = pal[@intCast(idx >> @intCast(3 * i) & 7)];
}

test "bc: BC1 four colours and three with transparent black" {
    // c0 pure red (0xf800) > c1 pure blue (0x001f): index 0, 1, 2, 3 in row 0
    const four = [8]u8{ 0x00, 0xf8, 0x1f, 0x00, 0b11_10_01_00, 0, 0, 0 };
    var out: [4 * 4 * 4]u8 = undefined;
    decode(.bc1, &four, &out, 16, 4, 4);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, out[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 170, 0, 85, 255 }, out[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 85, 0, 170, 255 }, out[12..16]);
    // row 1: all index 0
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out[16..20]);
    // c0 <= c1: index 2 the mean, index 3 transparent black
    const three = [8]u8{ 0x1f, 0x00, 0x00, 0xf8, 0b11_10_01_00, 0, 0, 0 };
    decode(.bc1, &three, &out, 16, 4, 4);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 127, 255 }, out[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[12..16]);
}

test "bc: BC3 alpha and BC4, BC5 channels" {
    // alpha 255 to 0, eight steps: index 2 is (6*255 + 0)/7
    const b3 = [16]u8{ 255, 0, 0b10_001_000, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };
    var out: [64]u8 = undefined;
    decode(.bc3, &b3, &out, 16, 4, 4);
    try std.testing.expectEqual(@as(u8, 255), out[3]);
    try std.testing.expectEqual(@as(u8, 0), out[7]);
    try std.testing.expectEqual(@as(u8, 218), out[11]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, out[0..3]);
    // BC4 unsigned, a0 <= a1: indices 6 and 7 are 0 and 255
    const b4 = [8]u8{ 10, 20, 0b111_110 << 0, 0, 0, 0, 0, 0 };
    var r: [16]u8 = undefined;
    decode(.bc4u, &b4, &r, 4, 4, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 10, 10 }, r[0..4]);
    // BC5 signed: -128 reads as -1, 127 as 1
    const b5 = [16]u8{ 0x80, 0x7f, 0, 0, 0, 0, 0, 0, 0x7f, 0x80, 0, 0, 0, 0, 0, 0 };
    var f: [16 * 8]u8 = undefined;
    decode(.bc5s, &b5, &f, 32, 4, 4);
    try std.testing.expectEqual(@as(f32, -1), @as(f32, @bitCast(std.mem.readInt(u32, f[0..4], .little))));
    try std.testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(std.mem.readInt(u32, f[4..8], .little))));
}

test "bc: a block wider than its level writes only the level's texels" {
    const blk = [8]u8{ 0x00, 0xf8, 0x1f, 0x00, 0, 0, 0, 0 };
    var out = [_]u8{0xaa} ** 8;
    decode(.bc1, &blk, &out, 8, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0xaa, 0xaa, 0xaa, 0xaa }, &out);
}
