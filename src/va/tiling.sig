//! @zpm/va tiling — the decoder's pictures in memory, and their copy to
//! pitch-linear NV12 on the CPU.
//!
//! NVDEC writes a picture block linear (nvdec_h264_pic_s tileFormat 1,
//! KBL: the GPU's own block-linear layout). Each plane is cut into GOBs,
//! 64 bytes wide and 8 rows tall (512 bytes); GOBs stack into blocks, one
//! GOB wide and 2 GOBs (16 rows) tall here: NVK forces that for video
//! (nil's tiling.rs: the firmware writes GOB_2 whatever the size, so
//! gob_height 0); blocks go row by row across the plane. Inside a GOB the
//! bytes are swizzled, and how is the GPU's: Turing to Ada lay every
//! format out one way (nil's TuringColor2D); Blackwell has one layout for
//! 8-bit formats (Blackwell8Bit: the luma plane) and another for 16-bit
//! ones (Blackwell16Bit: the chroma plane's UV pairs). THE RISK: which of
//! these GB206's NVDEC writes is not public. The Blackwell layouts are
//! assumed (the GPU's texture unit must read NVDEC's pictures as R8 and
//! RG8); GALAXY_VA_GOB=turing switches to Turing's for a boot that shows
//! scrambled 64x8 tiles.
//!
//! Firefox wants pitch-linear NV12, so each surface has a linear copy that
//! the CPU makes here once a decode is done (detile). Copying on the GPU
//! (a copy-engine pass) is the later step.
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

    pub fn luma(g: Gob) Swizzle {
        return if (g == .blackwell) .blackwell8 else .turing2d;
    }
    pub fn chroma(g: Gob) Swizzle {
        return if (g == .blackwell) .blackwell16 else .turing2d;
    }
};

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

/// A decode target: an NV12 picture's two block-linear planes in one
/// buffer, the chroma plane (interleaved UV) after the luma plane, both
/// for the macroblock-aligned picture.
pub const Nv12 = struct {
    luma: Plane,
    chroma: Plane,
    chroma_offset: u64,
    bytes: u64,

    pub fn of(width: u32, height: u32) Nv12 {
        const w = std.mem.alignForward(u32, width, 16);
        const h = std.mem.alignForward(u32, height, 16);
        const luma = Plane.of(w, h);
        const chroma = Plane.of(w, h / 2);
        const at = std.mem.alignForward(u64, luma.bytes(), 4096);
        return .{ .luma = luma, .chroma = chroma, .chroma_offset = at, .bytes = at + chroma.bytes() };
    }
};

/// A pitch-linear NV12 picture: Y rows, then UV rows, `pitch` apart.
pub const Linear = struct {
    pitch: u32,
    /// where the UV rows start
    uv_offset: u32,
    bytes: u32,

    pub fn of(width: u32, height: u32) Linear {
        const pitch = std.mem.alignForward(u32, width, 64);
        const rows = std.mem.alignForward(u32, height, 16);
        return .{ .pitch = pitch, .uv_offset = pitch * rows, .bytes = pitch * rows + pitch * (rows / 2) };
    }
};

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
    const lw = comptime s.lineBytes();
    const across = plane.pitch / GOB_WIDTH;
    std.debug.assert(width <= plane.pitch and rows <= plane.rows);
    std.debug.assert(rows == 0 or dst.len >= (rows - 1) * dst_pitch + width);
    for (0..rows) |y| {
        const row_lines = &lines[y % GOB_ROWS];
        const gob = (y % BLOCK_ROWS) / GOB_ROWS;
        const first_block = (y / BLOCK_ROWS) * across;
        const out = dst[y * dst_pitch ..];
        var x: usize = 0;
        var col: usize = 0;
        while (x < width) : (col += 1) {
            const base = (first_block + col) * BLOCK_BYTES + gob * GOB_BYTES;
            for (row_lines) |off| {
                if (x >= width) break;
                const n = @min(lw, width - x);
                @memcpy(out[x..][0..n], src[base + off ..][0..n]);
                x += n;
            }
        }
    }
}

/// The inverse (a picture into a block-linear plane), for tests and fakes:
/// byte by byte through `offsetOf`.
pub fn tile(dst: []u8, plane: Plane, s: Swizzle, src: []const u8, src_pitch: usize, width: usize, rows: usize) void {
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
