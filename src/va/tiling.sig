//! @zpm/va tiling — the decoder's pictures in memory: their block-linear
//! layout, the DRM format modifiers that name it, and the CPU's copy
//! between it and pitch-linear (tests, fakes, and the last resort when no
//! GPU converts: convert.sig).
//!
//! NVDEC writes a picture block linear (nvdec_h264_pic_s tileFormat 1,
//! KBL: the GPU's own block-linear layout). Each plane is cut into GOBs,
//! 64 bytes wide and 8 rows tall (512 bytes); GOBs stack into blocks, one
//! GOB wide and 2 GOBs (16 rows) tall here: NVK forces that for video
//! (nil's tiling.rs: the firmware writes GOB_2 whatever the size, so
//! gob_height 0); blocks go row by row across the plane. Inside a GOB the
//! bytes are swizzled, and how is the GPU's: Turing to Ada lay every
//! format out one way (nil's TuringColor2D); Blackwell has one layout for
//! 8-bit texels (Blackwell8Bit: NV12's luma plane), another for 16-bit
//! ones (Blackwell16Bit: NV12's UV pairs, P010's luma) and keeps Turing's
//! for 32-bit and wider (P010's UV pairs) — drm_fourcc.h's sector layouts
//! 2, 3 and 1 for GB20x. THE RISK: which of these GB206's NVDEC writes is
//! not public. The Blackwell layouts are assumed (the GPU's texture unit
//! must read NVDEC's pictures as R8/RG8 and R16/RG16);
//! GALAXY_VA_GOB=turing switches every plane to Turing's for a boot that
//! shows scrambled 64x8 tiles. The modifier a plane is exported with says
//! which (its sector layout), so the importer follows the switch.
//!
//! The pictures stay block linear end to end: the decoder writes them in
//! VRAM, they are exported as they are (`modifierOf`) and the GL driver
//! samples the GOBs in its shaders' address math (gfxapi texture.sig). A
//! CPU reader (vaGetImage, a derived image) gets a pitch-linear copy that
//! the GPU makes (convert.sig); `detile` below is the CPU's version.
//!
//! The copy works a GOB line at a time (16 or 8 bytes), from tables
//! transcribed from nil's copy.rs (`for_each_gob_line`); the tests check it
//! byte by byte against `offsetOf`, the layouts' closed forms.

const std = @import("std");

pub const GOB_WIDTH = 64;
pub const GOB_ROWS = 8;
pub const GOB_BYTES = 512;
/// GOBs per block, as a power of two (GOB_2: 16-row blocks).
pub const BLOCK_GOBS_LOG2 = 1;
/// nvdec_h264_pic_s gob_height for those blocks.
pub const GOB_HEIGHT_FIELD: u3 = BLOCK_GOBS_LOG2 - 1;
pub const BLOCK_ROWS = GOB_ROWS << BLOCK_GOBS_LOG2;
pub const BLOCK_BYTES = GOB_BYTES << BLOCK_GOBS_LOG2;

/// How a GPU swizzles bytes inside a GOB.
pub const Swizzle = enum {
    /// Turing..Ada, any format (nil's TuringColor2D)
    turing2d,
    /// Blackwell, 1-byte texels (nil's Blackwell8Bit)
    blackwell8,
    /// Blackwell, 2-byte texels (nil's Blackwell16Bit)
    blackwell16,

    /// The bytes one line of the swizzle holds (a run of a row).
    pub fn lineBytes(s: Swizzle) usize {
        return if (s == .blackwell8) 8 else 16;
    }
};

/// Which GPU generation's layouts the decoder writes.
pub const Gob = enum {
    turing,
    blackwell,

    /// The swizzle of a plane of `texel` bytes a texel (drm_fourcc.h's
    /// GB20x sector layouts: 8 bpp, 16 bpp, and 32+ bpp as before GB20x).
    pub fn forTexel(g: Gob, texel: u32) Swizzle {
        if (g == .turing) return .turing2d;
        return switch (texel) {
            1 => .blackwell8,
            2 => .blackwell16,
            else => .turing2d,
        };
    }
    /// NV12's planes: Y (R8), UV (GR88).
    pub fn luma(g: Gob) Swizzle {
        return g.forTexel(1);
    }
    pub fn chroma(g: Gob) Swizzle {
        return g.forTexel(2);
    }
};

// ── DRM format modifiers (drm_fourcc.h) ─────────────────────────────────────

pub const DRM_FORMAT_MOD_VENDOR_NVIDIA: u64 = 0x03;
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;

/// DRM_FORMAT_MOD_NVIDIA_BLOCK_LINEAR_2D(c, s, g, k, h): compression c
/// (bits 23..25), sector layout s (bit 22, and its bits 1..2 at 26..27),
/// GOB kind generation g (20..21), page kind k (12..19), log2 of the
/// block's height in GOBs h (0..3), bit 4 set (block linear).
pub fn nvidiaBlockLinear2d(c: u3, s: u3, g: u2, k: u8, h: u4) u64 {
    return DRM_FORMAT_MOD_VENDOR_NVIDIA << 56 | 0x10 | @as(u64, h) | @as(u64, k) << 12 | @as(u64, g) << 20 |
        @as(u64, s & 1) << 22 | @as(u64, s & 6) << 25 | @as(u64, c) << 23;
}

/// The modifier's fields, chosen for NVDEC's pictures on the RTX 5070
/// (GB206):
///
/// - c = 0: no compression. The decoder writes plain pixels (nothing
///   compressible is set up: no compression tags, kind generic).
/// - g = 2: "GOB height 8, Turing+ page kind mapping". GOBs are 64 x 8
///   from Fermi on; 2 is the generation for every GPU from Turing,
///   Blackwell included (3 is reserved).
/// - k = 0x06: the page kind. On Turing and later the page tables' kind
///   only says compression and memory type; uncompressed block-linear
///   colour is NV_MMU_PTE_KIND_GENERIC_MEMORY, 0x06, as NVK (nil) and
///   NVIDIA's own driver name it. (nv_drm maps Galaxy's VRAM with the
///   pitch kind; for uncompressed surfaces on Turing+ the layout is the
///   engines' address math alone, so the bytes are the same either way.)
/// - h = 1: blocks of two GOBs (16 rows): GOB_2, what the decoder writes
///   (nvdec gob_height 0) — BLOCK_GOBS_LOG2.
/// - s: the sector layout, which is the swizzle inside a GOB: 1 for
///   Turing's layout (and Blackwell's for 32-bit and wider texels: P010's
///   UV pairs), 2 for GB20x's 8-bit texels (NV12's Y), 3 for GB20x's
///   16-bit texels (NV12's UV pairs, P010's Y).
pub const PAGE_KIND_GENERIC: u8 = 0x06;
pub const GOB_KIND_TURING: u2 = 2;

pub fn sectorLayout(s: Swizzle) u3 {
    return switch (s) {
        .turing2d => 1,
        .blackwell8 => 2,
        .blackwell16 => 3,
    };
}

/// A plane of the decoder's, swizzled `s`, as a modifier.
pub fn modifierOf(s: Swizzle) u64 {
    return nvidiaBlockLinear2d(0, sectorLayout(s), GOB_KIND_TURING, PAGE_KIND_GENERIC, BLOCK_GOBS_LOG2);
}

/// What a modifier says, for an importer: block height (log2 of GOBs) and
/// swizzle. Null: not one of NVIDIA's uncompressed 2D block-linear ones.
pub const BlockLinear = struct { gobs_log2: u4, swizzle: Swizzle };

pub fn parseModifier(m: u64) ?BlockLinear {
    if (m >> 56 != DRM_FORMAT_MOD_VENDOR_NVIDIA or m & 0x10 == 0) return null;
    // (reserved bits 5..11 and 28..55 zero; no compression)
    if (m & 0x0000_0000_0000_0fe0 != 0 or m & 0x00ff_ffff_f000_0000 != 0) return null;
    if ((m >> 23) & 7 != 0) return null;
    if ((m >> 20) & 3 != GOB_KIND_TURING) return null;
    const s = ((m >> 22) & 1) | ((m >> 25) & 6);
    const h: u4 = @intCast(m & 0xf);
    if (h > 5) return null;
    return .{ .gobs_log2 = h, .swizzle = switch (s) {
        1 => .turing2d,
        2 => .blackwell8,
        3 => .blackwell16,
        else => return null,
    } };
}

/// Where byte (x, y) of a GOB is (x < 64, y < 8): the layouts' closed
/// forms.
pub fn gobOffset(s: Swizzle, x: usize, y: usize) usize {
    return switch (s) {
        .turing2d => (x / 32) * 256 + (y / 4) * 128 + ((x % 32) / 16) * 64 + (y % 4) * 16 + x % 16,
        .blackwell16 => (x / 32) * 256 + ((x % 32) / 16) * 128 + y * 16 + x % 16,
        .blackwell8 => (x / 8) * 64 + y * 8 + x % 8,
    };
}

/// A block-linear plane: `pitch` bytes wide (whole GOBs), `rows` tall
/// (whole blocks).
pub const Plane = struct {
    pitch: u32,
    rows: u32,

    pub fn of(width_bytes: u32, rows: u32) Plane {
        return .{
            .pitch = std.mem.alignForward(u32, @max(width_bytes, 1), GOB_WIDTH),
            .rows = std.mem.alignForward(u32, @max(rows, 1), BLOCK_ROWS),
        };
    }

    pub fn bytes(p: Plane) u64 {
        return @as(u64, p.pitch / GOB_WIDTH) * (p.rows / BLOCK_ROWS) * BLOCK_BYTES;
    }

    /// Where byte (x, y) of the plane is.
    pub fn offsetOf(p: Plane, s: Swizzle, x: usize, y: usize) usize {
        const block = (y / BLOCK_ROWS) * (p.pitch / GOB_WIDTH) + x / GOB_WIDTH;
        const gob = (y % BLOCK_ROWS) / GOB_ROWS;
        return block * BLOCK_BYTES + gob * GOB_BYTES + gobOffset(s, x % GOB_WIDTH, y % GOB_ROWS);
    }
};

/// A decode target: a 4:2:0 picture's two block-linear planes in one
/// buffer, the chroma plane (interleaved UV) after the luma plane, both
/// for the macroblock-aligned picture. NV12 (a byte a sample) or P010
/// (two bytes a sample, the 10 bits at the top: what NVDEC writes for a
/// 10-bit stream), `sample_bytes` says.
pub const Nv12 = struct {
    luma: Plane,
    chroma: Plane,
    chroma_offset: u64,
    bytes: u64,
    sample_bytes: u8 = 1,

    pub fn of(width: u32, height: u32) Nv12 {
        return ofDepth(width, height, 1);
    }

    /// P010's: Y R16, UV GR1616.
    pub fn p010(width: u32, height: u32) Nv12 {
        return ofDepth(width, height, 2);
    }

    pub fn ofDepth(width: u32, height: u32, sample_bytes: u8) Nv12 {
        const w = std.mem.alignForward(u32, width, 16) * sample_bytes;
        const h = std.mem.alignForward(u32, height, 16);
        const luma = Plane.of(w, h);
        const chroma = Plane.of(w, h / 2);
        const at = std.mem.alignForward(u64, luma.bytes(), 4096);
        return .{ .luma = luma, .chroma = chroma, .chroma_offset = at, .bytes = at + chroma.bytes(), .sample_bytes = sample_bytes };
    }

    /// The planes' swizzles (their texels: a sample, a UV pair).
    pub fn swizzles(n: Nv12, g: Gob) [2]Swizzle {
        return .{ g.forTexel(n.sample_bytes), g.forTexel(2 * @as(u32, n.sample_bytes)) };
    }
};

/// A pitch-linear 4:2:0 picture (NV12 or P010): Y rows, then UV rows,
/// `pitch` bytes apart.
pub const Linear = struct {
    pitch: u32,
    /// where the UV rows start
    uv_offset: u32,
    bytes: u32,
    sample_bytes: u8 = 1,

    pub fn of(width: u32, height: u32) Linear {
        return ofDepth(width, height, 1);
    }

    pub fn ofDepth(width: u32, height: u32, sample_bytes: u8) Linear {
        const pitch = std.mem.alignForward(u32, width * sample_bytes, 64);
        const rows = std.mem.alignForward(u32, height, 16);
        return .{ .pitch = pitch, .uv_offset = pitch * rows, .bytes = pitch * rows + pitch * (rows / 2), .sample_bytes = sample_bytes };
    }
};

/// A picture of `width` x `height` samples as its planes' bytes across and
/// rows: Y, then UV (whole pairs).
pub fn planeExtents(width: u32, height: u32, sample_bytes: u8) [2][2]u32 {
    return .{ .{ width * sample_bytes, height }, .{ 2 * ((width + 1) / 2) * sample_bytes, (height + 1) / 2 } };
}

/// Every plane of `pic` (layout `n`) between block linear and pitch
/// linear (`lin`), the CPU's way: `to_linear` detiles, else tiles.
pub fn convertPicture(n: Nv12, lin: Linear, g: Gob, tiled: []u8, linear: []u8, width: u32, height: u32, to_linear: bool) void {
    const ext = planeExtents(width, height, n.sample_bytes);
    const sw = n.swizzles(g);
    const planes = [2]Plane{ n.luma, n.chroma };
    const at = [2]usize{ 0, @intCast(n.chroma_offset) };
    const lat = [2]usize{ 0, lin.uv_offset };
    for (0..2) |p| {
        if (to_linear) {
            detile(linear[lat[p]..], lin.pitch, tiled[at[p]..], planes[p], sw[p], ext[p][0], ext[p][1]);
        } else {
            tile(tiled[at[p]..], planes[p], sw[p], linear[lat[p]..], lin.pitch, ext[p][0], ext[p][1]);
        }
    }
}

// ── The swizzles' lines (nil's copy.rs) ─────────────────────────────────────

/// A GOB's lines: for row y, line k (bytes k*lineBytes ..) is at
/// rows[y][k] in the GOB.
fn Lines(comptime s: Swizzle) type {
    const per_row = GOB_WIDTH / s.lineBytes();
    return [GOB_ROWS][per_row]u16;
}

/// nil's for_each_gob_line, as tables (f(offset, x, y) for each line).
fn linesOf(comptime s: Swizzle) Lines(s) {
    @setEvalBranchQuota(10_000);
    var t: Lines(s) = undefined;
    const lw = s.lineBytes();
    const Put = struct {
        fn f(tab: *Lines(s), off: u16, x: u16, y: u16) void {
            tab[y][x / lw] = off;
        }
    };
    switch (s) {
        .turing2d => for (0..2) |ii| {
            const i: u16 = @intCast(ii);
            Put.f(&t, i * 0x100 + 0x00, i * 32 + 0, 0);
            Put.f(&t, i * 0x100 + 0x10, i * 32 + 0, 1);
            Put.f(&t, i * 0x100 + 0x20, i * 32 + 0, 2);
            Put.f(&t, i * 0x100 + 0x30, i * 32 + 0, 3);
            Put.f(&t, i * 0x100 + 0x40, i * 32 + 16, 0);
            Put.f(&t, i * 0x100 + 0x50, i * 32 + 16, 1);
            Put.f(&t, i * 0x100 + 0x60, i * 32 + 16, 2);
            Put.f(&t, i * 0x100 + 0x70, i * 32 + 16, 3);
            Put.f(&t, i * 0x100 + 0x80, i * 32 + 0, 4);
            Put.f(&t, i * 0x100 + 0x90, i * 32 + 0, 5);
            Put.f(&t, i * 0x100 + 0xa0, i * 32 + 0, 6);
            Put.f(&t, i * 0x100 + 0xb0, i * 32 + 0, 7);
            Put.f(&t, i * 0x100 + 0xc0, i * 32 + 16, 4);
            Put.f(&t, i * 0x100 + 0xd0, i * 32 + 16, 5);
            Put.f(&t, i * 0x100 + 0xe0, i * 32 + 16, 6);
            Put.f(&t, i * 0x100 + 0xf0, i * 32 + 16, 7);
        },
        .blackwell16 => for (0..2) |ii| {
            const i: u16 = @intCast(ii);
            Put.f(&t, i * 0x100 + 0x00, i * 32 + 0, 0);
            Put.f(&t, i * 0x100 + 0x10, i * 32 + 0, 1);
            Put.f(&t, i * 0x100 + 0x20, i * 32 + 0, 2);
            Put.f(&t, i * 0x100 + 0x30, i * 32 + 0, 3);
            Put.f(&t, i * 0x100 + 0x80, i * 32 + 16, 0);
            Put.f(&t, i * 0x100 + 0x90, i * 32 + 16, 1);
            Put.f(&t, i * 0x100 + 0xa0, i * 32 + 16, 2);
            Put.f(&t, i * 0x100 + 0xb0, i * 32 + 16, 3);
            Put.f(&t, i * 0x100 + 0x40, i * 32 + 0, 4);
            Put.f(&t, i * 0x100 + 0x50, i * 32 + 0, 5);
            Put.f(&t, i * 0x100 + 0x60, i * 32 + 0, 6);
            Put.f(&t, i * 0x100 + 0x70, i * 32 + 0, 7);
            Put.f(&t, i * 0x100 + 0xc0, i * 32 + 16, 4);
            Put.f(&t, i * 0x100 + 0xd0, i * 32 + 16, 5);
            Put.f(&t, i * 0x100 + 0xe0, i * 32 + 16, 6);
            Put.f(&t, i * 0x100 + 0xf0, i * 32 + 16, 7);
        },
        .blackwell8 => for (0..8) |xx| {
            for (0..8) |yy| {
                const x: u16 = @intCast(xx);
                const y: u16 = @intCast(yy);
                Put.f(&t, x * 0x40 + y * 0x8, x * 0x8, y);
            }
        },
    }
    return t;
}

const turing2d_lines = linesOf(.turing2d);
const blackwell8_lines = linesOf(.blackwell8);
const blackwell16_lines = linesOf(.blackwell16);

/// Rows [0, rows) and bytes [0, width) of the block-linear plane `src`
/// (laid out as `plane`, swizzled as `s`) into `dst`, `dst_pitch` bytes a
/// row.
pub fn detile(dst: []u8, dst_pitch: usize, src: []const u8, plane: Plane, s: Swizzle, width: usize, rows: usize) void {
    switch (s) {
        .turing2d => detileWith(.turing2d, &turing2d_lines, dst, dst_pitch, src, plane, width, rows),
        .blackwell8 => detileWith(.blackwell8, &blackwell8_lines, dst, dst_pitch, src, plane, width, rows),
        .blackwell16 => detileWith(.blackwell16, &blackwell16_lines, dst, dst_pitch, src, plane, width, rows),
    }
}

fn detileWith(comptime s: Swizzle, lines: *const Lines(s), dst: []u8, dst_pitch: usize, src: []const u8, plane: Plane, width: usize, rows: usize) void {
    linesWith(s, lines, true, @constCast(src), dst, dst_pitch, plane, width, rows);
}

/// A GOB line at a time, either way: block linear `bl` to the pitch-linear
/// `lin` (`to_linear`), or back.
fn linesWith(comptime s: Swizzle, lines: *const Lines(s), comptime to_linear: bool, bl: []u8, lin: []u8, pitch: usize, plane: Plane, width: usize, rows: usize) void {
    const lw = comptime s.lineBytes();
    const across = plane.pitch / GOB_WIDTH;
    std.debug.assert(width <= plane.pitch and rows <= plane.rows);
    std.debug.assert(rows == 0 or lin.len >= (rows - 1) * pitch + width);
    for (0..rows) |y| {
        const row_lines = &lines[y % GOB_ROWS];
        const gob = (y % BLOCK_ROWS) / GOB_ROWS;
        const first_block = (y / BLOCK_ROWS) * across;
        const row = lin[y * pitch ..];
        var x: usize = 0;
        var col: usize = 0;
        while (x < width) : (col += 1) {
            const base = (first_block + col) * BLOCK_BYTES + gob * GOB_BYTES;
            for (row_lines) |off| {
                if (x >= width) break;
                const n = @min(lw, width - x);
                if (to_linear) @memcpy(row[x..][0..n], bl[base + off ..][0..n]) else @memcpy(bl[base + off ..][0..n], row[x..][0..n]);
                x += n;
            }
        }
    }
}

/// The inverse: rows [0, rows) and bytes [0, width) of the pitch-linear
/// `src` into the block-linear plane `dst`.
pub fn tile(dst: []u8, plane: Plane, s: Swizzle, src: []const u8, src_pitch: usize, width: usize, rows: usize) void {
    switch (s) {
        .turing2d => linesWith(.turing2d, &turing2d_lines, false, dst, @constCast(src), src_pitch, plane, width, rows),
        .blackwell8 => linesWith(.blackwell8, &blackwell8_lines, false, dst, @constCast(src), src_pitch, plane, width, rows),
        .blackwell16 => linesWith(.blackwell16, &blackwell16_lines, false, dst, @constCast(src), src_pitch, plane, width, rows),
    }
}

/// The same byte by byte through `offsetOf` (the tests' reference).
pub fn tileBytes(dst: []u8, plane: Plane, s: Swizzle, src: []const u8, src_pitch: usize, width: usize, rows: usize) void {
    for (0..rows) |y| {
        for (0..width) |x| dst[plane.offsetOf(s, x, y)] = src[y * src_pitch + x];
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tiling: each swizzle's table is a permutation of the GOB and matches its closed form" {
    inline for (.{ Swizzle.turing2d, Swizzle.blackwell8, Swizzle.blackwell16 }) |s| {
        const t = comptime linesOf(s);
        var seen = [_]bool{false} ** GOB_BYTES;
        for (0..GOB_ROWS) |y| {
            for (t[y], 0..) |off, k| {
                for (0..s.lineBytes()) |b| {
                    const x = k * s.lineBytes() + b;
                    try testing.expectEqual(gobOffset(s, x, y), off + b);
                    try testing.expect(!seen[off + b]);
                    seen[off + b] = true;
                }
            }
        }
    }
}

var test_src: [64 * 1024]u8 = undefined;
var test_dst: [64 * 1024]u8 = undefined;

test "tiling: detile against the block-linear formula, odd sizes" {
    const cases = [_][2]usize{ .{ 37, 21 }, .{ 1, 1 }, .{ 64, 16 }, .{ 65, 17 }, .{ 130, 33 }, .{ 200, 7 }, .{ 127, 50 } };
    inline for (.{ Swizzle.turing2d, Swizzle.blackwell8, Swizzle.blackwell16 }) |s| {
        for (cases) |c| {
            const width = c[0];
            const rows = c[1];
            const plane = Plane.of(@intCast(width), @intCast(rows));
            try testing.expect(plane.bytes() <= test_src.len);
            // every byte of the plane distinct-ish
            for (test_src[0..plane.bytes()], 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
            const pitch = width + 3; // (a pitch that is not the plane's)
            @memset(test_dst[0 .. pitch * rows], 0xee);
            detile(&test_dst, pitch, &test_src, plane, s, width, rows);
            for (0..rows) |y| {
                for (0..width) |x| {
                    // the straightforward address: block, GOB in block, byte in GOB
                    const block = (y / 16) * (plane.pitch / 64) + x / 64;
                    const addr = block * 1024 + ((y % 16) / 8) * 512 + gobOffset(s, x % 64, y % 8);
                    try testing.expectEqual(test_src[addr], test_dst[y * pitch + x]);
                }
                // nothing past the width
                for (width..pitch) |x| try testing.expectEqual(@as(u8, 0xee), test_dst[y * pitch + x]);
            }
        }
    }
}

test "tiling: the modifiers' bits (drm_fourcc.h), and what an importer reads back" {
    // nouveau's Turing modifiers for GOB_2 (0x300000000606011): the
    // DRM_FORMAT_MOD_NVIDIA_BLOCK_LINEAR_2D(0, 1, 2, 0x06, 1) every
    // Turing..Ada driver gives
    try testing.expectEqual(@as(u64, 0x0300_0000_0060_6011), modifierOf(.turing2d));
    // GB20x's: sector layout 2 (8 bpp) and 3 (16 bpp): s bit 0 at 22,
    // bits 1..2 at 26..27
    try testing.expectEqual(@as(u64, 0x0300_0000_0420_6011), modifierOf(.blackwell8));
    try testing.expectEqual(@as(u64, 0x0300_0000_0460_6011), modifierOf(.blackwell16));
    // field by field
    const m = nvidiaBlockLinear2d(5, 7, 3, 0xab, 0xc);
    try testing.expectEqual(@as(u64, 0x03), m >> 56);
    try testing.expectEqual(@as(u64, 0xc | 0x10), m & 0x1f);
    try testing.expectEqual(@as(u64, 0xab), (m >> 12) & 0xff);
    try testing.expectEqual(@as(u64, 3), (m >> 20) & 3);
    try testing.expectEqual(@as(u64, 1), (m >> 22) & 1);
    try testing.expectEqual(@as(u64, 5), (m >> 23) & 7);
    try testing.expectEqual(@as(u64, 3), (m >> 26) & 3);
    inline for (.{ Swizzle.turing2d, Swizzle.blackwell8, Swizzle.blackwell16 }) |s| {
        const p = parseModifier(modifierOf(s)).?;
        try testing.expectEqual(s, p.swizzle);
        try testing.expectEqual(@as(u4, BLOCK_GOBS_LOG2), p.gobs_log2);
    }
    // not block linear, compressed, another vendor, a reserved layout
    try testing.expect(parseModifier(DRM_FORMAT_MOD_LINEAR) == null);
    try testing.expect(parseModifier(DRM_FORMAT_MOD_INVALID) == null);
    try testing.expect(parseModifier(nvidiaBlockLinear2d(1, 1, 2, 0x06, 1)) == null);
    try testing.expect(parseModifier(nvidiaBlockLinear2d(0, 4, 2, 0x06, 1)) == null);
    try testing.expect(parseModifier(0x0100_0000_0060_6011) == null);
    // the planes' swizzles: NV12 Y 8 bpp, UV 16; P010 Y 16, UV 32
    try testing.expectEqual([2]Swizzle{ .blackwell8, .blackwell16 }, Nv12.of(64, 64).swizzles(.blackwell));
    try testing.expectEqual([2]Swizzle{ .blackwell16, .turing2d }, Nv12.p010(64, 64).swizzles(.blackwell));
    try testing.expectEqual([2]Swizzle{ .turing2d, .turing2d }, Nv12.p010(64, 64).swizzles(.turing));
}

test "tiling: the GOB-line tile against the byte-by-byte one; P010 layouts and their round trip" {
    inline for (.{ Swizzle.turing2d, Swizzle.blackwell8, Swizzle.blackwell16 }) |s| {
        const width = 131;
        const rows = 37;
        const plane = Plane.of(width, rows);
        var pic: [width * rows]u8 = undefined;
        for (&pic, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 9);
        @memset(test_src[0..plane.bytes()], 0);
        @memset(test_dst[0..plane.bytes()], 0);
        tile(&test_src, plane, s, &pic, width, width, rows);
        tileBytes(&test_dst, plane, s, &pic, width, width, rows);
        try testing.expectEqualSlices(u8, test_dst[0..plane.bytes()], test_src[0..plane.bytes()]);
    }
    const p = Nv12.p010(1920, 1080);
    try testing.expectEqual(@as(u32, 3840), p.luma.pitch);
    try testing.expectEqual(@as(u32, 3840), p.chroma.pitch);
    try testing.expectEqual(@as(u32, 1088), p.luma.rows);
    try testing.expectEqual(@as(u32, 544), p.chroma.rows);
    try testing.expectEqual(@as(u64, 3840 * 1088), p.chroma_offset);
    const pl = Linear.ofDepth(1920, 1080, 2);
    try testing.expectEqual(@as(u32, 3840), pl.pitch);
    try testing.expectEqual(@as(u32, 3840 * 1088), pl.uv_offset);
    // a P010 picture through both planes and back
    const w = 37;
    const h = 21;
    const n = Nv12.p010(w, h);
    const lin = Linear.ofDepth(w, h, 2);
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    try testing.expect(lin.bytes <= a.len and n.bytes <= test_src.len);
    for (a[0..lin.bytes], 0..) |*x, i| x.* = @truncate(i * 13 + 5);
    @memset(test_src[0..n.bytes], 0);
    convertPicture(n, lin, .blackwell, &test_src, &a, w, h, false);
    @memset(b[0..lin.bytes], 0);
    convertPicture(n, lin, .blackwell, &test_src, &b, w, h, true);
    const ext = planeExtents(w, h, 2);
    for (0..h) |y| try testing.expectEqualSlices(u8, a[y * lin.pitch ..][0..ext[0][0]], b[y * lin.pitch ..][0..ext[0][0]]);
    for (0..ext[1][1]) |y| try testing.expectEqualSlices(u8, a[lin.uv_offset + y * lin.pitch ..][0..ext[1][0]], b[lin.uv_offset + y * lin.pitch ..][0..ext[1][0]]);
    // the UV plane's bytes where Turing's 32-bit layout puts them
    try testing.expectEqual(a[lin.uv_offset + 3 * lin.pitch + 40], test_src[@as(usize, @intCast(n.chroma_offset)) + n.chroma.offsetOf(.turing2d, 40, 3)]);
}

test "tiling: tile then detile gives the picture back; NV12 layouts" {
    var pic: [50 * 30]u8 = undefined;
    for (&pic, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    const plane = Plane.of(50, 30);
    @memset(test_src[0..plane.bytes()], 0);
    tile(&test_src, plane, .blackwell16, &pic, 50, 50, 30);
    var back: [50 * 30]u8 = undefined;
    detile(&back, 50, &test_src, plane, .blackwell16, 50, 30);
    try testing.expectEqualSlices(u8, &pic, &back);
    const n = Nv12.of(1920, 1080);
    try testing.expectEqual(@as(u32, 1920), n.luma.pitch);
    try testing.expectEqual(@as(u32, 1088), n.luma.rows);
    try testing.expectEqual(@as(u32, 544), n.chroma.rows);
    try testing.expectEqual(@as(u64, 1920 * 1088), n.chroma_offset);
    try testing.expectEqual(@as(u64, 1920 * 1088 + 1920 * 544), n.bytes);
    const odd = Nv12.of(33, 17);
    try testing.expectEqual(@as(u32, 64), odd.luma.pitch);
    try testing.expectEqual(@as(u32, 32), odd.luma.rows);
    try testing.expectEqual(@as(u32, 16), odd.chroma.rows);
    try testing.expectEqual(@as(u64, 4096), odd.chroma_offset);
    const l = Linear.of(1920, 1080);
    try testing.expectEqual(@as(u32, 1920), l.pitch);
    try testing.expectEqual(@as(u32, 1920 * 1088), l.uv_offset);
}
