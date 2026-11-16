//! @zpm/gfxapi blocklinear — NVIDIA's block-linear layout in KIR: where
//! byte (x, y) of a block-linear plane is, computed in a kernel, so a
//! shader samples a video decoder's picture where the decoder wrote it
//! (texture.sig) and a compute kernel converts one (zpm src/va
//! gpu_convert.sig), with no copy in between.
//!
//! The layout is zpm src/va tiling.sig's (its CPU reference, tested byte
//! for byte against this in tests/test_gfxapi_draw.sig and
//! gpu_convert.sig): a plane `pitch` bytes wide (whole 64-byte GOBs) is
//! cut into blocks one GOB wide and 2^h GOBs tall (8 rows a GOB), blocks
//! row by row across the plane; inside a 512-byte GOB the bytes are
//! swizzled, by GPU generation and texel size (the modifier's sector
//! layout):
//!
//!   0  Turing2D   (x/32)*256 + (y/4)*128 + ((x%32)/16)*64 + (y%4)*16 + x%16
//!                 Turing..Ada, and Blackwell's 32-bit and wider texels
//!   1  Blackwell8 (x/8)*64 + y*8 + x%8          GB20x, 8-bit texels
//!   2  Blackwell16 (x/32)*256 + ((x%32)/16)*128 + y*16 + x%16
//!                                               GB20x, 16-bit texels
//!
//! Every swizzle keeps a texel of up to 8 bytes whole and aligned (runs of
//! 8 or 16 bytes), so a texel's bytes are one aligned word as in a linear
//! image.
//!
//! The DRM format modifiers (drm_fourcc.h DRM_FORMAT_MOD_NVIDIA_BLOCK_LINEAR_2D)
//! that name these: `parseModifier`.

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const V = kir.V;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;

pub const Swizzle = enum(u2) { turing2d = 0, blackwell8 = 1, blackwell16 = 2 };

/// What an image's memory is laid out as (engine.Image's `layout`).
pub const Layout = packed struct(u8) {
    /// block linear (else pitch linear: the rest unused)
    block: bool = false,
    swizzle: Swizzle = .turing2d,
    /// log2 of a block's height in GOBs (0..5)
    gobs_log2: u3 = 0,
    _pad: u2 = 0,

    pub fn linear(l: Layout) bool {
        return !l.block;
    }
};

// ── DRM format modifiers ────────────────────────────────────────────────────

pub const MOD_LINEAR: u64 = 0;
pub const MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;
const VENDOR_NVIDIA: u64 = 0x03;
/// drm_fourcc.h's GOB kind generation for Turing and later (Blackwell too)
pub const GOB_KIND_TURING: u64 = 2;
/// NV_MMU_PTE_KIND_GENERIC_MEMORY: uncompressed block-linear colour on
/// Turing+, as NVK and NVIDIA's driver name it
pub const PAGE_KIND_GENERIC: u8 = 0x06;

/// DRM_FORMAT_MOD_NVIDIA_BLOCK_LINEAR_2D(c, s, g, k, h).
pub fn modifier(c: u3, s: u3, g: u2, k: u8, h: u4) u64 {
    return VENDOR_NVIDIA << 56 | 0x10 | @as(u64, h) | @as(u64, k) << 12 | @as(u64, g) << 20 |
        @as(u64, s & 1) << 22 | @as(u64, s & 6) << 25 | @as(u64, c) << 23;
}

/// A sector layout as the swizzle (drm_fourcc.h: 1 pre-GB20x and GB20x
/// 32+ bpp, 2 GB20x 8 bpp, 3 GB20x 16 bpp).
pub fn swizzleOf(sector_layout: u64) ?Swizzle {
    return switch (sector_layout) {
        1 => .turing2d,
        2 => .blackwell8,
        3 => .blackwell16,
        else => null,
    };
}

/// The block-linear modifier of a plane laid out `l`, page kind generic.
pub fn modifierOf(l: Layout) u64 {
    if (!l.block) return MOD_LINEAR;
    const s: u3 = switch (l.swizzle) {
        .turing2d => 1,
        .blackwell8 => 2,
        .blackwell16 => 3,
    };
    return modifier(0, s, GOB_KIND_TURING, PAGE_KIND_GENERIC, l.gobs_log2);
}

/// A modifier as the layout it names: linear, or NVIDIA's uncompressed 2D
/// block-linear (Turing+ GOB kind, any page kind: on Turing+ the kind only
/// says compression, refused here). Null: neither.
pub fn parseModifier(m: u64) ?Layout {
    if (m == MOD_LINEAR) return .{};
    if (m >> 56 != VENDOR_NVIDIA or m & 0x10 == 0) return null;
    // (reserved bits 5..11 and 28..55; compression; the GOB generation)
    if (m & 0x0000_0000_0000_0fe0 != 0 or m & 0x00ff_ffff_f000_0000 != 0) return null;
    if ((m >> 23) & 7 != 0) return null;
    if ((m >> 20) & 3 != GOB_KIND_TURING) return null;
    const h = m & 0xf;
    if (h > 5) return null;
    const sw = swizzleOf(((m >> 22) & 1) | ((m >> 25) & 6)) orelse return null;
    return .{ .block = true, .swizzle = sw, .gobs_log2 = @intCast(h) };
}

/// The bytes a block-linear plane of `rows` rows and `pitch` bytes takes
/// (whole blocks).
pub fn planeBytes(pitch: u32, rows: u32, gobs_log2: u3) u64 {
    const block_rows = @as(u32, 8) << gobs_log2;
    const blocks_down = (rows + block_rows - 1) / block_rows;
    return @as(u64, pitch / 64) * blocks_down * (@as(u64, 512) << gobs_log2);
}

// ── In KIR ──────────────────────────────────────────────────────────────────

/// Where byte (ix, iy) of a GOB is (ix < 64, iy < 8; u32), swizzled as
/// `swz` says (a u32: Swizzle's codes): each layout's closed form, picked.
pub fn gobOffset(k: *kir.Kernel, swz: Arg, ix: V, iy: V) V {
    const x32 = k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(ix), u(5))), u(8)); // (x/32)*256
    const x16 = k.op3(.bfe, .u32, r(ix), u(4), u(1)); // (x%32)/16
    const xlo = k.op2(.@"and", .u32, r(ix), u(15)); // x%16
    // Turing2D: + (y/4)*128 + x16*64 + (y%4)*16
    var t = k.op2(.@"or", .u32, r(x32), r(k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(iy), u(2))), u(7))));
    t = k.op2(.@"or", .u32, r(t), r(k.op2(.shl, .u32, r(x16), u(6))));
    t = k.op2(.@"or", .u32, r(t), r(k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(iy), u(3))), u(4))));
    t = k.op2(.@"or", .u32, r(t), r(xlo));
    // Blackwell16: + x16*128 + y*16
    var b16 = k.op2(.@"or", .u32, r(x32), r(k.op2(.shl, .u32, r(x16), u(7))));
    b16 = k.op2(.@"or", .u32, r(b16), r(k.op2(.shl, .u32, r(iy), u(4))));
    b16 = k.op2(.@"or", .u32, r(b16), r(xlo));
    // Blackwell8: (x/8)*64 + y*8 + x%8
    var b8 = k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(ix), u(3))), u(6));
    b8 = k.op2(.@"or", .u32, r(b8), r(k.op2(.shl, .u32, r(iy), u(3))));
    b8 = k.op2(.@"or", .u32, r(b8), r(k.op2(.@"and", .u32, r(ix), u(7))));
    const is8 = k.cmp(.u32, .eq, swz, u(@intFromEnum(Swizzle.blackwell8)));
    const is16 = k.cmp(.u32, .eq, swz, u(@intFromEnum(Swizzle.blackwell16)));
    return k.sel(.u32, r(is8), r(b8), r(k.sel(.u32, r(is16), r(b16), r(t))));
}

/// Where byte `xb` of row `y` (u32s) of a block-linear plane is, from its
/// first byte: `pitch` bytes across (whole GOBs), blocks of 2^`gobs_log2`
/// GOBs (u32s), swizzled `swz`.
pub fn address(k: *kir.Kernel, pitch: Arg, gobs_log2: Arg, swz: Arg, xb: Arg, y: Arg) V {
    const across = k.op2(.shr, .u32, pitch, u(6));
    const block_shift = k.op2(.iadd, .u32, gobs_log2, u(3)); // log2 of a block's rows
    const by = k.op2(.shr, .u32, y, r(block_shift));
    const block = k.op3(.imad, .u32, r(by), r(across), r(k.op2(.shr, .u32, xb, u(6))));
    const gob_mask = k.op2(.isub, .u32, r(k.op2(.shl, .u32, u(1), gobs_log2)), u(1));
    const gob = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, y, u(3))), r(gob_mask));
    const block_bytes_shift = k.op2(.iadd, .u32, gobs_log2, u(9));
    const base = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(block), r(block_bytes_shift))), r(k.op2(.shl, .u32, r(gob), u(9))));
    const ix = k.op2(.@"and", .u32, xb, u(63));
    const iy = k.op2(.@"and", .u32, y, u(7));
    return k.op2(.iadd, .u32, r(base), r(gobOffset(k, swz, ix, iy)));
}

/// The same on the CPU (the reference the kernels are tested against).
pub fn addressCpu(pitch: u32, gobs_log2: u3, swz: Swizzle, xb: u32, y: u32) u32 {
    const block_rows_log2: u5 = @as(u5, gobs_log2) + 3;
    const block = (y >> block_rows_log2) * (pitch / 64) + xb / 64;
    const gob = (y >> 3) & ((@as(u32, 1) << gobs_log2) - 1);
    const ix = xb % 64;
    const iy = y % 8;
    const inner = switch (swz) {
        .turing2d => (ix / 32) * 256 + (iy / 4) * 128 + ((ix % 32) / 16) * 64 + (iy % 4) * 16 + ix % 16,
        .blackwell16 => (ix / 32) * 256 + ((ix % 32) / 16) * 128 + iy * 16 + ix % 16,
        .blackwell8 => (ix / 8) * 64 + iy * 8 + ix % 8,
    };
    return (block << (@as(u5, gobs_log2) + 9)) + gob * 512 + inner;
}

test "blocklinear: modifiers parsed, made, refused" {
    const T = std.testing;
    // nouveau's Turing GOB_2 modifier; GB20x's 8 and 16 bpp
    try T.expectEqual(Layout{ .block = true, .swizzle = .turing2d, .gobs_log2 = 1 }, parseModifier(0x0300_0000_0060_6011).?);
    try T.expectEqual(Layout{ .block = true, .swizzle = .blackwell8, .gobs_log2 = 1 }, parseModifier(0x0300_0000_0420_6011).?);
    try T.expectEqual(Layout{ .block = true, .swizzle = .blackwell16, .gobs_log2 = 1 }, parseModifier(0x0300_0000_0460_6011).?);
    try T.expectEqual(Layout{}, parseModifier(MOD_LINEAR).?);
    for ([_]Layout{ .{ .block = true, .swizzle = .blackwell8, .gobs_log2 = 4 }, .{ .block = true, .swizzle = .turing2d, .gobs_log2 = 0 } }) |l| {
        try T.expectEqual(l, parseModifier(modifierOf(l)).?);
    }
    // (an old page kind: the same layout on Turing+)
    try T.expect(parseModifier(modifier(0, 1, 2, 0xfe, 1)) != null);
    try T.expect(parseModifier(MOD_INVALID) == null);
    try T.expect(parseModifier(modifier(1, 1, 2, 0x06, 1)) == null); // compressed
    try T.expect(parseModifier(modifier(0, 1, 0, 0xfe, 1)) == null); // Fermi..Volta's kinds
    try T.expect(parseModifier(modifier(0, 0, 2, 0x06, 1)) == null); // Tegra's sectors
    try T.expect(parseModifier(modifier(0, 1, 2, 0x06, 6)) == null);
    try T.expect(parseModifier(0x0300_0000_0000_0001) == null); // 16Bx2 without bit 4
    try T.expectEqual(@as(u64, 2 * 3 * 1024), planeBytes(128, 33, 1));
}
