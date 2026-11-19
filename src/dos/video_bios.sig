//! The video BIOS: int 10h on the VGA (vga.sig): set mode (text 00h-03h
//! and 07h, CGA 04h-06h, EGA 0Dh-10h, VGA 11h-13h; bit 7 keeps memory),
//! cursor, scrolling, characters and pixels, palette and DAC functions
//! (AH=10h), fonts (AH=11h, the 8x8/8x14/8x16 font pointers), alternate
//! select (AH=12h), write string (AH=13h), display combination (AH=1Ah),
//! state (AH=1Bh), and VESA's VBE 2.0 (AH=4Fh: vesa_bios.sig, on the
//! SVGA's modes in vesa.sig: 8, 15, 16, 24 and 32 bits, banked and
//! linear). Setting a VGA mode (here or through 4F02) leaves a VESA one.
//! The BIOS data area's video fields stay in step (0x449-0x489).
//!
//! Clean room, from IBM's VGA technical reference (the modes' register
//! values), FreeVGA and the published int 10h interface (Ralf Brown's
//! Interrupt List as documentation).
//!
//! The video ROM at C000:0000 (RAM the machine treats as ROM): the option
//! ROM header, the static functionality table (C000:0040), the empty
//! 9-dot alternate tables, then the 8x8, 8x14 and 8x16 fonts (vga_font.sig),
//! then VESA's tables from C000:3000 (vesa_bios.sig).
//! The services work on the planes directly (as the BIOS's own code would
//! through the graphics controller), so they do not disturb a program's
//! register settings.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const vga_mod = @import("vga.sig");
const Vga = vga_mod.Vga;
const font = @import("vga_font.sig");
const vesa_bios = @import("vesa_bios.sig");

/// The video ROM's segment and where its tables are.
pub const ROM_SEG: u16 = 0xC000;
pub const STATIC_TABLE: u16 = 0x0040;
pub const ALT9X14: u16 = 0x0080;
pub const ALT9X16: u16 = 0x0082;
pub const FONT8: u16 = 0x0100;
pub const FONT14: u16 = FONT8 + 256 * 8;
pub const FONT16: u16 = FONT14 + 256 * 14;

const BDA: u16 = 0x40;

pub const Kind = enum { text, mono, cga4, cga2, planar, vga256 };

pub const Mode = struct {
    kind: Kind,
    cols: u8,
    rows: u8,
    /// Character height (the font's).
    ch: u8,
    w: u16 = 0,
    h: u16 = 0,
    page: u16,
    pages: u8,
    colours: u16,
    misc: u8,
    /// Sequencer 01h-04h.
    seq: [4]u8,
    crtc: [25]u8,
    gc: [9]u8,
    /// Attribute 00h-13h (colour select is 0).
    ac: [20]u8,
    /// The CGA mode control value the BDA keeps (0x465).
    cga_ctl: u8 = 0x29,
};

// The modes' registers (IBM's VGA BIOS tables, as its technical reference
// lists them).
const crtc_t40 = [25]u8{ 0x2D, 0x27, 0x28, 0x90, 0x2B, 0xA0, 0xBF, 0x1F, 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x14, 0x1F, 0x96, 0xB9, 0xA3, 0xFF };
const crtc_t80 = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F, 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3, 0xFF };
const crtc_mono = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F, 0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x28, 0x0F, 0x96, 0xB9, 0xA3, 0xFF };
const crtc_cga4 = [25]u8{ 0x2D, 0x27, 0x28, 0x90, 0x2B, 0x80, 0xBF, 0x1F, 0x00, 0xC1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x14, 0x00, 0x96, 0xB9, 0xA2, 0xFF };
const crtc_cga2 = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F, 0x00, 0xC1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x28, 0x00, 0x96, 0xB9, 0xC2, 0xFF };
const crtc_0d = [25]u8{ 0x2D, 0x27, 0x28, 0x90, 0x2B, 0x80, 0xBF, 0x1F, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x14, 0x00, 0x96, 0xB9, 0xE3, 0xFF };
const crtc_0e = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x28, 0x00, 0x96, 0xB9, 0xE3, 0xFF };
const crtc_350 = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x83, 0x85, 0x5D, 0x28, 0x0F, 0x63, 0xBA, 0xE3, 0xFF };
const crtc_480 = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0x0B, 0x3E, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xEA, 0x8C, 0xDF, 0x28, 0x00, 0xE7, 0x04, 0xE3, 0xFF };
const crtc_13 = [25]u8{ 0x5F, 0x4F, 0x50, 0x82, 0x54, 0x80, 0xBF, 0x1F, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9C, 0x8E, 0x8F, 0x28, 0x40, 0x96, 0xB9, 0xA3, 0xFF };

const gc_text = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x00, 0xFF };
const gc_mono = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0A, 0x00, 0xFF };
const gc_cga4 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x0F, 0x00, 0xFF };
const gc_cga2 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x00, 0xFF };
const gc_planar = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x0F, 0xFF };
const gc_0f = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x05, 0xFF };
const gc_13 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0F, 0xFF };

const pal_ega = [16]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F };
const pal_cga16 = [16]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 };

fn acOf(pal: [16]u8, mode: u8, cpe: u8, pan: u8) [20]u8 {
    var a: [20]u8 = undefined;
    @memcpy(a[0..16], &pal);
    a[16] = mode;
    a[17] = 0;
    a[18] = cpe;
    a[19] = pan;
    return a;
}

const ac_text = acOf(pal_ega, 0x0C, 0x0F, 0x08);
const ac_mono = acOf(.{ 0x00, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x10, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18 }, 0x0E, 0x0F, 0x08);
const ac_cga4 = acOf(.{ 0x00, 0x13, 0x15, 0x17, 0x02, 0x04, 0x06, 0x07, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 }, 0x01, 0x03, 0x00);
const ac_cga2 = acOf(.{ 0x00, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17 }, 0x01, 0x01, 0x00);
const ac_0d = acOf(pal_cga16, 0x01, 0x0F, 0x00);
const ac_0f = acOf(.{ 0x00, 0x08, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00 }, 0x0B, 0x05, 0x00);
const ac_ega = acOf(pal_ega, 0x01, 0x0F, 0x00);
const ac_11 = acOf(.{ 0x00, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F }, 0x01, 0x0F, 0x00);
const ac_13 = acOf(.{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F }, 0x41, 0x0F, 0x00);

const m_t40: Mode = .{ .kind = .text, .cols = 40, .rows = 25, .ch = 16, .page = 0x0800, .pages = 8, .colours = 16, .misc = 0x67, .seq = .{ 0x08, 0x03, 0x00, 0x02 }, .crtc = crtc_t40, .gc = gc_text, .ac = ac_text };
const m_t80: Mode = .{ .kind = .text, .cols = 80, .rows = 25, .ch = 16, .page = 0x1000, .pages = 8, .colours = 16, .misc = 0x67, .seq = .{ 0x00, 0x03, 0x00, 0x02 }, .crtc = crtc_t80, .gc = gc_text, .ac = ac_text };

fn withCtl(m: Mode, ctl: u8) Mode {
    var x = m;
    x.cga_ctl = ctl;
    return x;
}

const modes = [_]struct { n: u8, m: Mode }{
    .{ .n = 0x00, .m = withCtl(m_t40, 0x2C) },
    .{ .n = 0x01, .m = withCtl(m_t40, 0x28) },
    .{ .n = 0x02, .m = withCtl(m_t80, 0x2D) },
    .{ .n = 0x03, .m = withCtl(m_t80, 0x29) },
    .{ .n = 0x04, .m = .{ .kind = .cga4, .cols = 40, .rows = 25, .ch = 8, .w = 320, .h = 200, .page = 0x4000, .pages = 1, .colours = 4, .misc = 0x63, .seq = .{ 0x09, 0x03, 0x00, 0x02 }, .crtc = crtc_cga4, .gc = gc_cga4, .ac = ac_cga4, .cga_ctl = 0x2A } },
    .{ .n = 0x05, .m = .{ .kind = .cga4, .cols = 40, .rows = 25, .ch = 8, .w = 320, .h = 200, .page = 0x4000, .pages = 1, .colours = 4, .misc = 0x63, .seq = .{ 0x09, 0x03, 0x00, 0x02 }, .crtc = crtc_cga4, .gc = gc_cga4, .ac = ac_cga4, .cga_ctl = 0x2E } },
    .{ .n = 0x06, .m = .{ .kind = .cga2, .cols = 80, .rows = 25, .ch = 8, .w = 640, .h = 200, .page = 0x4000, .pages = 1, .colours = 2, .misc = 0x63, .seq = .{ 0x01, 0x01, 0x00, 0x06 }, .crtc = crtc_cga2, .gc = gc_cga2, .ac = ac_cga2, .cga_ctl = 0x1E } },
    .{ .n = 0x07, .m = .{ .kind = .mono, .cols = 80, .rows = 25, .ch = 16, .page = 0x1000, .pages = 8, .colours = 0, .misc = 0x66, .seq = .{ 0x00, 0x03, 0x00, 0x02 }, .crtc = crtc_mono, .gc = gc_mono, .ac = ac_mono } },
    .{ .n = 0x0D, .m = .{ .kind = .planar, .cols = 40, .rows = 25, .ch = 8, .w = 320, .h = 200, .page = 0x2000, .pages = 8, .colours = 16, .misc = 0x63, .seq = .{ 0x09, 0x0F, 0x00, 0x06 }, .crtc = crtc_0d, .gc = gc_planar, .ac = ac_0d } },
    .{ .n = 0x0E, .m = .{ .kind = .planar, .cols = 80, .rows = 25, .ch = 8, .w = 640, .h = 200, .page = 0x4000, .pages = 4, .colours = 16, .misc = 0x63, .seq = .{ 0x01, 0x0F, 0x00, 0x06 }, .crtc = crtc_0e, .gc = gc_planar, .ac = ac_0d } },
    .{ .n = 0x0F, .m = .{ .kind = .planar, .cols = 80, .rows = 25, .ch = 14, .w = 640, .h = 350, .page = 0x8000, .pages = 2, .colours = 0, .misc = 0xA2, .seq = .{ 0x01, 0x0F, 0x00, 0x06 }, .crtc = crtc_350, .gc = gc_0f, .ac = ac_0f } },
    .{ .n = 0x10, .m = .{ .kind = .planar, .cols = 80, .rows = 25, .ch = 14, .w = 640, .h = 350, .page = 0x8000, .pages = 2, .colours = 16, .misc = 0xA3, .seq = .{ 0x01, 0x0F, 0x00, 0x06 }, .crtc = crtc_350, .gc = gc_planar, .ac = ac_ega } },
    .{ .n = 0x11, .m = .{ .kind = .planar, .cols = 80, .rows = 30, .ch = 16, .w = 640, .h = 480, .page = 0xA000, .pages = 1, .colours = 2, .misc = 0xE3, .seq = .{ 0x01, 0x0F, 0x00, 0x06 }, .crtc = crtc_480, .gc = gc_planar, .ac = ac_11 } },
    .{ .n = 0x12, .m = .{ .kind = .planar, .cols = 80, .rows = 30, .ch = 16, .w = 640, .h = 480, .page = 0xA000, .pages = 1, .colours = 16, .misc = 0xE3, .seq = .{ 0x01, 0x0F, 0x00, 0x06 }, .crtc = crtc_480, .gc = gc_planar, .ac = ac_ega } },
    .{ .n = 0x13, .m = .{ .kind = .vga256, .cols = 40, .rows = 25, .ch = 8, .w = 320, .h = 200, .page = 0xFA00, .pages = 1, .colours = 256, .misc = 0x63, .seq = .{ 0x01, 0x0F, 0x00, 0x0E }, .crtc = crtc_13, .gc = gc_13, .ac = ac_13 } },
};

pub fn modeOf(n: u8) ?*const Mode {
    for (&modes) |*e| if (e.n == n) return &e.m;
    return null;
}

/// The mode the BDA says is set (mode 03h's shape if it is none of ours).
fn current(mem: *const Memory) *const Mode {
    return modeOf(mem.rdB(BDA, 0x49)) orelse modeOf(0x03).?;
}

// ── The DAC's default palettes ───────────────────────────────────────────

/// An EGA colour (rgbRGB) as 6-bit DAC components.
fn egaRgb(e: u8) [3]u8 {
    return .{
        ((e >> 2) & 1) * 42 + ((e >> 5) & 1) * 21,
        ((e >> 1) & 1) * 42 + ((e >> 4) & 1) * 21,
        (e & 1) * 42 + ((e >> 3) & 1) * 21,
    };
}

/// Mode 13h's palette: the 16 colours, 16 greys, then 24 hues at three
/// saturations and three intensities, then black (the published layout).
const default256: [256][3]u8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256][3]u8 = @splat(.{ 0, 0, 0 });
    for (0..16) |i| t[i] = egaRgb(pal_ega[i]);
    const greys = [16]u8{ 0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63 };
    for (0..16) |i| t[16 + i] = .{ greys[i], greys[i], greys[i] };
    const levels = [9][5]u8{
        .{ 0, 16, 31, 47, 63 }, .{ 31, 39, 47, 55, 63 }, .{ 45, 49, 54, 58, 63 },
        .{ 0, 7, 14, 21, 28 },  .{ 14, 17, 21, 24, 28 }, .{ 20, 22, 24, 26, 28 },
        .{ 0, 4, 8, 12, 16 },   .{ 8, 10, 12, 14, 16 },  .{ 11, 12, 13, 15, 16 },
    };
    // The hue wheel from blue, as (r, g, b) level numbers.
    const wheel = [24][3]u8{
        .{ 0, 0, 4 }, .{ 1, 0, 4 }, .{ 2, 0, 4 }, .{ 3, 0, 4 }, .{ 4, 0, 4 }, .{ 4, 0, 3 }, .{ 4, 0, 2 }, .{ 4, 0, 1 },
        .{ 4, 0, 0 }, .{ 4, 1, 0 }, .{ 4, 2, 0 }, .{ 4, 3, 0 }, .{ 4, 4, 0 }, .{ 3, 4, 0 }, .{ 2, 4, 0 }, .{ 1, 4, 0 },
        .{ 0, 4, 0 }, .{ 0, 4, 1 }, .{ 0, 4, 2 }, .{ 0, 4, 3 }, .{ 0, 4, 4 }, .{ 0, 3, 4 }, .{ 0, 2, 4 }, .{ 0, 1, 4 },
    };
    for (0..9) |b| {
        for (0..24) |h| {
            const l = levels[b];
            t[32 + b * 24 + h] = .{ l[wheel[h][0]], l[wheel[h][1]], l[wheel[h][2]] };
        }
    }
    break :blk t;
};

/// A 200-line mode's colour (CGA style: bit 4 intensity, bits 2-0 RGB,
/// colour 6 brown) as 6-bit DAC components.
fn cgaRgb(e: u8) [3]u8 {
    const i: u8 = ((e >> 4) & 1) * 21;
    var c: [3]u8 = .{ ((e >> 2) & 1) * 42 + i, ((e >> 1) & 1) * 42 + i, (e & 1) * 42 + i };
    if (e & 0x17 == 0x06) c[1] = 21;
    return c;
}

/// The monochrome modes' 64 entries: bit 3 video, bit 4 intensity.
fn monoRgb(e: u8) [3]u8 {
    const g: u8 = (if (e & 0x08 != 0) @as(u8, 42) else 0) + (if (e & 0x10 != 0) @as(u8, 21) else 0);
    return .{ g, g, g };
}

/// Which default DAC table a mode loads.
fn dacTable(md: *const Mode) enum { ega, cga, mono, vga256 } {
    if (md.kind == .vga256) return .vga256;
    if (md.kind == .mono or md.colours == 0) return .mono;
    // The 200-line modes: CGA's colours.
    if (md.kind == .cga4 or md.kind == .cga2 or md.ch == 8) return .cga;
    return .ega;
}

fn loadPalette(vga: *Vga, mem: *Memory, md: *const Mode) void {
    if (mem.rdB(BDA, 0x89) & 0x08 != 0) return; // (default palette loading off)
    const grey = mem.rdB(BDA, 0x89) & 0x02 != 0;
    switch (dacTable(md)) {
        .vga256 => for (0..256) |i| setDacMaybeGrey(vga, @intCast(i), default256[i], grey),
        .mono => for (0..64) |i| setDacMaybeGrey(vga, @intCast(i), monoRgb(@intCast(i)), false),
        .cga => for (0..64) |i| setDacMaybeGrey(vga, @intCast(i), cgaRgb(@intCast(i)), grey),
        .ega => for (0..64) |i| setDacMaybeGrey(vga, @intCast(i), egaRgb(@intCast(i)), grey),
    }
}

fn greyOf(c: [3]u8) u8 {
    const s: u32 = (@as(u32, c[0]) * 77 + @as(u32, c[1]) * 151 + @as(u32, c[2]) * 28 + 128) >> 8;
    return @intCast(@min(s, 63));
}

fn setDacMaybeGrey(vga: *Vga, i: u8, c: [3]u8, grey: bool) void {
    if (grey) {
        const g = greyOf(c);
        vga.setDac(i, g, g, g);
    } else vga.setDac(i, c[0], c[1], c[2]);
}

// ── Fonts ────────────────────────────────────────────────────────────────

/// Plane 2's offset of character map `n` (0-7).
fn fontBlock(n: u8) u32 {
    return @as(u32, n & 3) * 0x4000 + @as(u32, (n >> 2) & 1) * 0x2000;
}

/// `count` characters from `first` of `h`-byte glyphs into map `block`.
fn loadGlyphs(vga: *Vga, block: u8, first: u32, count: u32, h: u32, src: anytype) void {
    const base = fontBlock(block);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const c = (first + i) & 0xFF;
        var row: u32 = 0;
        while (row < 32) : (row += 1) {
            const b: u8 = if (row < h) src.byte(i * h + row) else 0;
            const pa = (base + c * 32 + row) & 0xFFFF;
            vga.vram[pa] = (vga.vram[pa] & 0xFF00FFFF) | (@as(u32, b) << 16);
        }
    }
}

const RomFont = struct {
    data: []const u8,
    fn byte(self: RomFont, i: u32) u8 {
        return if (i < self.data.len) self.data[i] else 0;
    }
};
const MemFont = struct {
    mem: *const Memory,
    at: u32,
    fn byte(self: MemFont, i: u32) u8 {
        return self.mem.rd8(self.at +% i);
    }
};

fn romFont(h: u8) []const u8 {
    return switch (h) {
        8 => &font.font8,
        14 => &font.font14,
        else => &font.font16,
    };
}
fn romFontOff(h: u8) u16 {
    return switch (h) {
        8 => FONT8,
        14 => FONT14,
        else => FONT16,
    };
}

fn setVector(mem: *Memory, v: u8, seg: u16, off: u16) void {
    mem.wrW(0, @as(u16, v) * 4, off);
    mem.wrW(0, @as(u16, v) * 4 + 2, seg);
}

/// Text modes: the character height `h` takes effect (rows, cursor,
/// display end), as AH=11h's 1xh functions do after loading a font.
fn applyCharHeight(vga: *Vga, mem: *Memory, h: u8) void {
    const md = current(mem);
    if (md.kind != .text and md.kind != .mono) return;
    const lines: u32 = blk: {
        const o = vga.crtc[7];
        const vd = (@as(u32, vga.crtc[0x12]) | (@as(u32, (o >> 1) & 1) << 8) | (@as(u32, (o >> 6) & 1) << 9)) + 1;
        break :blk if (vga.crtc[9] & 0x80 != 0) vd / 2 else vd;
    };
    const rows: u32 = @max(lines / h, 1);
    vga.crtc[9] = (vga.crtc[9] & 0xE0) | (h - 1);
    const cs: u8 = if (h > 8) h - 3 else h - 2;
    vga.crtc[0x0A] = (vga.crtc[0x0A] & 0xE0) | cs;
    vga.crtc[0x0B] = (vga.crtc[0x0B] & 0xE0) | (cs + 1);
    var vd: u32 = rows * h - 1;
    if (vga.crtc[9] & 0x80 != 0) vd = rows * h * 2 - 1;
    vga.crtc[0x12] = @truncate(vd);
    vga.crtc[7] = (vga.crtc[7] & ~@as(u8, 0x42)) | (@as(u8, @truncate((vd >> 8) & 1)) << 1) | (@as(u8, @truncate((vd >> 9) & 1)) << 6);
    if (md.kind == .mono) vga.crtc[0x14] = h - 1;
    vga.changed(false);
    mem.wrB(BDA, 0x84, @intCast(rows - 1));
    mem.wrW(BDA, 0x85, h);
    const cols: u32 = mem.rdW(BDA, 0x4A);
    mem.wrW(BDA, 0x4C, if (rows == 25) md.page else @intCast(rows * cols * 2));
}

// ── Boot and set mode ────────────────────────────────────────────────────

/// Sets up the adapter and the BIOS data area as the BIOS does at boot
/// (mode 03h), and puts the fonts where int 10h/1130h says they are
/// (`rom`: the video ROM's segment, 0xC000).
pub fn boot(vga: *Vga, mem: *Memory) void {
    const rom = Memory.lin(ROM_SEG, 0);
    // The option ROM header (32 KiB) and who made it.
    mem.copyIn(rom, &.{ 0x55, 0xAA, 0x40, 0xCB });
    mem.copyIn(rom + 0x10, "zpm dos VGA BIOS in Sig\x00");
    // The static functionality table (int 10h/1Bh points at it): modes
    // 00h-07h, 0Dh-0Fh, 10h-13h; 200/350/400 lines; 8 font blocks, 2
    // active; every misc function; blink/intensity and the DCC.
    mem.copyIn(rom + STATIC_TABLE, &.{ 0xFF, 0xE0, 0x0F, 0, 0, 0, 0, 0x07, 0x08, 0x02, 0xFF, 0x0C, 0, 0, 0, 0 });
    // The 9-dot alternates: none (each list ends at character 0).
    mem.wr8(rom + ALT9X14, 0);
    mem.wr8(rom + ALT9X16, 0);
    mem.copyIn(rom + FONT8, &font.font8);
    mem.copyIn(rom + FONT14, &font.font14);
    mem.copyIn(rom + FONT16, &font.font16);
    vesa_bios.boot(mem);
    // int 1Fh: the 8x8 font's upper half; int 43h: set by each mode.
    setVector(mem, 0x1F, ROM_SEG, FONT8 + 128 * 8);
    setVector(mem, 0x43, ROM_SEG, FONT8);
    // The equipment word's initial video mode: 80x25 colour.
    const eq = mem.rdW(BDA, 0x10);
    if (eq & 0x30 == 0) mem.wrW(BDA, 0x10, eq | 0x20);
    // VGA, 256 KiB, cursor emulation on; switches; 400 lines, VGA active.
    mem.wrB(BDA, 0x87, 0x60);
    mem.wrB(BDA, 0x88, 0xF9);
    mem.wrB(BDA, 0x89, 0x11);
    mem.wrB(BDA, 0x8A, 0x0B);
    setMode(vga, mem, 0x03);
}

/// int 10h/00h: mode `al` (bit 7: keep memory).
pub fn setMode(vga: *Vga, mem: *Memory, al: u8) void {
    const n = al & 0x7F;
    const keep = al & 0x80 != 0;
    const base = modeOf(n) orelse return;
    var md = base.*;
    // (a VESA mode ends; the DAC is 6 bits again)
    vga.svga.active = false;
    vga.setDacWidth(false);
    // Text modes: the scan lines AH=12h/BL=30h chose (0x489 bits 7 and 4).
    if (md.kind == .text or md.kind == .mono) {
        const sl = mem.rdB(BDA, 0x89) & 0x90;
        if (sl == 0x00) {
            // 350 lines, the 8x14 font.
            md.misc = (md.misc & 0x3F) | 0x80;
            for ([_]usize{ 6, 7, 0x10, 0x11, 0x12, 0x15, 0x16 }) |i| md.crtc[i] = crtc_350[i];
            md.crtc[9] = 0x4D;
            md.crtc[0x0A] = 0x0B;
            md.crtc[0x0B] = 0x0C;
            if (md.kind == .mono) md.crtc[0x14] = 0x0D;
            md.ch = 14;
        } else if (sl == 0x80 and md.kind == .text) {
            // 200 lines: the 8x8 font, double scanned, 8-dot characters.
            md.misc &= ~@as(u8, 0x0C);
            md.seq[0] |= 0x01;
            md.crtc[9] = 0xC7;
            md.crtc[0x0A] = 0x06;
            md.crtc[0x0B] = 0x07;
            md.ch = 8;
            md.ac = acOf(pal_cga16, 0x08, 0x0F, 0x00);
        }
    }

    // Screen off while the registers change.
    vga.seq[0] = 0x01;
    vga.misc = md.misc;
    vga.seq[1] = md.seq[0] | 0x20;
    vga.seq[2] = md.seq[1];
    vga.seq[3] = md.seq[2];
    vga.seq[4] = md.seq[3];
    vga.seq[0] = 0x03;
    @memcpy(vga.crtc[0..25], &md.crtc);
    @memcpy(vga.gc[0..9], &md.gc);
    for (md.ac, 0..) |v, i| vga.acWrite(@intCast(i), v);
    vga.acWrite(0x14, 0);
    vga.ac_i = 0x20;
    vga.ac_data = false;
    vga.dac_mask = 0xFF;
    vga.latch = 0;
    loadPalette(vga, mem, &md);

    switch (md.kind) {
        .text, .mono => {
            if (!keep) {
                for (0..0x8000) |pa| vga.vram[pa] = (vga.vram[pa] & 0xFFFF0000) | 0x0720;
            }
            loadGlyphs(vga, 0, 0, 256, md.ch, RomFont{ .data = romFont(md.ch) });
        },
        else => if (!keep) @memset(&vga.vram, 0),
    }
    vga.seq[1] = md.seq[0];
    vga.changed(true);

    // The BIOS data area.
    mem.wrB(BDA, 0x49, n);
    mem.wrW(BDA, 0x4A, md.cols);
    mem.wrW(BDA, 0x4C, md.page);
    mem.wrW(BDA, 0x4E, 0);
    for (0..8) |p| mem.wrW(BDA, @intCast(0x50 + 2 * p), 0);
    const text = md.kind == .text or md.kind == .mono;
    mem.wrW(BDA, 0x60, if (text) 0x0607 else 0);
    mem.wrB(BDA, 0x62, 0);
    mem.wrW(BDA, 0x63, if (md.misc & 1 != 0) 0x3D4 else 0x3B4);
    mem.wrB(BDA, 0x65, md.cga_ctl);
    mem.wrB(BDA, 0x66, if (n == 0x06) 0x3F else 0x30);
    mem.wrB(BDA, 0x84, md.rows - 1);
    mem.wrW(BDA, 0x85, md.ch);
    mem.wrB(BDA, 0x87, (mem.rdB(BDA, 0x87) & 0x7F) | (if (keep) @as(u8, 0x80) else 0));
    // int 43h: the graphics characters' font for this mode.
    setVector(mem, 0x43, ROM_SEG, romFontOff(if (text) 16 else md.ch));
}

// ── Text and pixels ──────────────────────────────────────────────────────

fn pageOff(mem: *const Memory, page: u8) u32 {
    return @as(u32, page) * mem.rdW(BDA, 0x4C);
}
fn rowsOf(mem: *const Memory) u32 {
    return @as(u32, mem.rdB(BDA, 0x84)) + 1;
}
fn colsOf(mem: *const Memory) u32 {
    return @max(mem.rdW(BDA, 0x4A), 1);
}
fn charH(mem: *const Memory) u32 {
    return @max(mem.rdW(BDA, 0x85), 1);
}
fn cursorOf(mem: *const Memory, page: u8) struct { row: u32, col: u32 } {
    const p = page & 7;
    return .{ .row = mem.rdB(BDA, 0x51 + 2 * @as(u16, p)), .col = mem.rdB(BDA, 0x50 + 2 * @as(u16, p)) };
}
fn setCursor(vga: *Vga, mem: *Memory, page: u8, row: u32, col: u32) void {
    const p = page & 7;
    mem.wrB(BDA, 0x50 + 2 * @as(u16, p), @truncate(col));
    mem.wrB(BDA, 0x51 + 2 * @as(u16, p), @truncate(row));
    if (p == mem.rdB(BDA, 0x62)) syncCursor(vga, mem);
}
/// The CRTC's cursor at the active page's cursor.
fn syncCursor(vga: *Vga, mem: *const Memory) void {
    const md = current(mem);
    if (md.kind != .text and md.kind != .mono) return;
    const page = mem.rdB(BDA, 0x62);
    const c = cursorOf(mem, page);
    const a: u32 = mem.rdW(BDA, 0x4E) / 2 + c.row * colsOf(mem) + c.col;
    vga.crtc[0x0E] = @truncate(a >> 8);
    vga.crtc[0x0F] = @truncate(a);
}

inline fn planeByte(vga: *const Vga, pa: u32, plane: u5) u8 {
    return @truncate(vga.vram[pa & 0xFFFF] >> (plane * 8));
}
inline fn setPlaneByte(vga: *Vga, pa: u32, plane: u5, b: u8) void {
    const i = pa & 0xFFFF;
    const sh: u5 = plane * 8;
    vga.vram[i] = (vga.vram[i] & ~(@as(u32, 0xFF) << sh)) | (@as(u32, b) << sh);
}

/// A text cell's plane address (character in plane 0, attribute in 1).
fn cellPa(mem: *const Memory, page: u8, row: u32, col: u32) u32 {
    return (pageOff(mem, page) + (row * colsOf(mem) + col) * 2) & 0xFFFF;
}

pub fn putPixel(vga: *Vga, md: *const Mode, page: u8, x: u32, y: u32, c: u8) void {
    const xor = c & 0x80 != 0 and md.kind != .vga256;
    switch (md.kind) {
        .vga256 => {
            const off = y * 320 + x;
            setPlaneByte(vga, off & ~@as(u32, 3), @intCast(off & 3), c);
        },
        .planar => {
            const pa = (@as(u32, page) * md.page + y * md.cols + x / 8) & 0xFFFF;
            const bit = (@as(u32, 0x80) >> @intCast(x & 7)) * 0x01010101;
            const cv = vga_mod.expand4[c & 0xF] & bit;
            if (xor) vga.vram[pa] ^= cv else vga.vram[pa] = (vga.vram[pa] & ~bit) | cv;
        },
        .cga4 => {
            const off = (y & 1) * 0x2000 + (y >> 1) * 80 + x / 4;
            const sh: u3 = @intCast(6 - 2 * (x & 3));
            const plane: u5 = @intCast(off & 1);
            const b = planeByte(vga, off & ~@as(u32, 1), plane);
            const cv: u8 = (c & 3) << sh;
            setPlaneByte(vga, off & ~@as(u32, 1), plane, if (xor) b ^ cv else (b & ~(@as(u8, 3) << sh)) | cv);
        },
        .cga2 => {
            const off = (y & 1) * 0x2000 + (y >> 1) * 80 + x / 8;
            const bit: u8 = @as(u8, 0x80) >> @intCast(x & 7);
            const b = planeByte(vga, off, 0);
            const cv: u8 = if (c & 1 != 0) bit else 0;
            setPlaneByte(vga, off, 0, if (xor) b ^ cv else (b & ~bit) | cv);
        },
        else => {},
    }
}

pub fn getPixel(vga: *const Vga, md: *const Mode, page: u8, x: u32, y: u32) u8 {
    return switch (md.kind) {
        .vga256 => blk: {
            const off = y * 320 + x;
            break :blk planeByte(vga, off & ~@as(u32, 3), @intCast(off & 3));
        },
        .planar => blk: {
            const pa = (@as(u32, page) * md.page + y * md.cols + x / 8) & 0xFFFF;
            const w = vga.vram[pa] >> @intCast(7 - (x & 7));
            break :blk @truncate((w & 1) | ((w >> 7) & 2) | ((w >> 14) & 4) | ((w >> 21) & 8));
        },
        .cga4 => blk: {
            const off = (y & 1) * 0x2000 + (y >> 1) * 80 + x / 4;
            const b = planeByte(vga, off & ~@as(u32, 1), @intCast(off & 1));
            break :blk (b >> @intCast(6 - 2 * (x & 3))) & 3;
        },
        .cga2 => blk: {
            const off = (y & 1) * 0x2000 + (y >> 1) * 80 + x / 8;
            break :blk (planeByte(vga, off, 0) >> @intCast(7 - (x & 7))) & 1;
        },
        else => 0,
    };
}

/// The glyph rows of character `c` for graphics modes (int 43h's font;
/// in the CGA modes the upper half from int 1Fh's).
fn glyphAt(mem: *const Memory, md: *const Mode, c: u8) u32 {
    const h = charH(mem);
    if ((md.kind == .cga4 or md.kind == .cga2) and c >= 128) {
        return Memory.lin(mem.rdW(0, 0x7E), mem.rdW(0, 0x7C)) + (@as(u32, c) - 128) * 8;
    }
    return Memory.lin(mem.rdW(0, 0x10E), mem.rdW(0, 0x10C)) + @as(u32, c) * h;
}

/// A character into a graphics mode's cell (foreground `colour`; bit 7
/// XORs except in 256-colour mode; the background is 0).
fn drawChar(vga: *Vga, mem: *const Memory, md: *const Mode, page: u8, row: u32, col: u32, c: u8, colour: u8) void {
    const h = charH(mem);
    if (col >= md.cols or (row + 1) * h > md.h) return;
    const g = glyphAt(mem, md, c);
    const xor = colour & 0x80 != 0 and md.kind != .vga256;
    var r: u32 = 0;
    while (r < h) : (r += 1) {
        const bits = mem.rd8(g + r);
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            const on = bits & (@as(u8, 0x80) >> @intCast(i)) != 0;
            const x = col * 8 + i;
            const y = row * h + r;
            if (xor) {
                if (on) putPixel(vga, md, page, x, y, colour);
            } else putPixel(vga, md, page, x, y, if (on) colour else 0);
        }
    }
}

/// The character in a graphics cell, by its shape (0 if none matches).
fn readCharGfx(vga: *const Vga, mem: *const Memory, md: *const Mode, page: u8, row: u32, col: u32) u8 {
    const h = charH(mem);
    if (col >= md.cols or (row + 1) * h > md.h) return 0;
    var cell: [32]u8 = @splat(0);
    var r: u32 = 0;
    while (r < h and r < 32) : (r += 1) {
        var b: u8 = 0;
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            if (getPixel(vga, md, page, col * 8 + i, row * h + r) != 0) b |= @as(u8, 0x80) >> @intCast(i);
        }
        cell[r] = b;
    }
    var c: u32 = 0;
    while (c < 256) : (c += 1) {
        const g = glyphAt(mem, md, @intCast(c));
        var same = true;
        r = 0;
        while (r < h and r < 32) : (r += 1) {
            if (mem.rd8(g + r) != cell[r]) {
                same = false;
                break;
            }
        }
        if (same) return @intCast(c);
    }
    return 0;
}

/// Writes `c` (with `attr` unless null) at the cursor, `count` times,
/// leaving the cursor (AH=09h and 0Ah).
fn writeChars(vga: *Vga, mem: *Memory, page: u8, c: u8, attr: ?u8, colour: u8, count: u32) void {
    const md = current(mem);
    const cur = cursorOf(mem, page);
    const cols = colsOf(mem);
    const rows = rowsOf(mem);
    var pos = cur.row * cols + cur.col;
    var n: u32 = 0;
    while (n < count and pos < rows * cols) : ({
        n += 1;
        pos += 1;
    }) {
        const row = pos / cols;
        const col = pos % cols;
        switch (md.kind) {
            .text, .mono => {
                const pa = cellPa(mem, page, row, col);
                setPlaneByte(vga, pa, 0, c);
                if (attr) |a| setPlaneByte(vga, pa, 1, a);
            },
            else => drawChar(vga, mem, md, page, row, col, c, colour),
        }
    }
}

/// Scrolls the window (r0,c0)-(r1,c1) of `page` up or down by `n` lines
/// (0: clears it), filling with `fill` (an attribute, or in graphics a
/// colour).
fn scroll(vga: *Vga, mem: *const Memory, page: u8, up: bool, n0: u32, r0: u32, c0: u32, r1_: u32, c1_: u32, fill: u8) void {
    const md = current(mem);
    const rows = rowsOf(mem);
    const cols = colsOf(mem);
    const r1 = @min(r1_, rows - 1);
    const c1 = @min(c1_, cols - 1);
    if (r0 > r1 or c0 > c1) return;
    const height = r1 - r0 + 1;
    const n = if (n0 == 0 or n0 > height) height else n0;
    const text = md.kind == .text or md.kind == .mono;
    const h: u32 = if (text) 1 else charH(mem);
    // Row by row: line `dst` takes line `src` (in the cell's pixel rows).
    var k: u32 = 0;
    while (k < height) : (k += 1) {
        const dr = if (up) r0 + k else r1 - k;
        const has_src = k + n < height;
        const sr = if (up) dr + n else dr -% n;
        var line: u32 = 0;
        while (line < h) : (line += 1) {
            var col = c0;
            while (col <= c1) : (col += 1) {
                if (text) {
                    const d = cellPa(mem, page, dr, col);
                    const v: u32 = if (has_src) vga.vram[cellPa(mem, page, sr, col)] & 0xFFFF else (@as(u32, fill) << 8) | 0x20;
                    vga.vram[d] = (vga.vram[d] & 0xFFFF0000) | v;
                } else {
                    const ds = cellSpan(md, page, col, dr * h + line);
                    if (has_src) {
                        const ss = cellSpan(md, page, col, sr * h + line);
                        var i: u32 = 0;
                        while (i < ds.n) : (i += 1) vga.vram[(ds.pa + i * ds.step) & 0xFFFF] = vga.vram[(ss.pa + i * ss.step) & 0xFFFF];
                    } else {
                        const fw = fillWord(md, fill);
                        var i: u32 = 0;
                        while (i < ds.n) : (i += 1) vga.vram[(ds.pa + i * ds.step) & 0xFFFF] = fw;
                    }
                }
            }
        }
    }
}

const Span = struct { pa: u32, n: u32, step: u32 };

/// The plane words holding one pixel row of a graphics character cell.
fn cellSpan(md: *const Mode, page: u8, col: u32, y: u32) Span {
    return switch (md.kind) {
        .vga256 => .{ .pa = y * 320 + col * 8, .n = 2, .step = 4 },
        .cga4 => .{ .pa = (y & 1) * 0x2000 + (y >> 1) * 80 + col * 2, .n = 1, .step = 1 },
        .cga2 => .{ .pa = (y & 1) * 0x2000 + (y >> 1) * 80 + col, .n = 1, .step = 1 },
        else => .{ .pa = @as(u32, page) * md.page + y * md.cols + col, .n = 1, .step = 1 },
    };
}

fn fillWord(md: *const Mode, c: u8) u32 {
    return switch (md.kind) {
        .vga256 => @as(u32, c) * 0x01010101,
        .cga4 => blk: {
            const b: u32 = @as(u32, c & 3) * 0x55;
            break :blk b | (b << 8);
        },
        .cga2 => if (c & 1 != 0) 0xFF else 0,
        else => vga_mod.expand4[c & 0xF],
    };
}

/// Teletype output of `c` on `page` (graphics: in `colour`).
fn teletype(vga: *Vga, mem: *Memory, page: u8, c: u8, colour: u8, attr: ?u8) void {
    const md = current(mem);
    const text = md.kind == .text or md.kind == .mono;
    const cols = colsOf(mem);
    const rows = rowsOf(mem);
    const cur = cursorOf(mem, page);
    var row = cur.row;
    var col = cur.col;
    switch (c) {
        0x07 => return,
        0x08 => {
            if (col > 0) col -= 1;
        },
        0x0A => row += 1,
        0x0D => col = 0,
        else => {
            if (text) {
                const pa = cellPa(mem, page, row, col);
                setPlaneByte(vga, pa, 0, c);
                if (attr) |a| setPlaneByte(vga, pa, 1, a);
            } else drawChar(vga, mem, md, page, row, col, c, colour);
            col += 1;
            if (col >= cols) {
                col = 0;
                row += 1;
            }
        },
    }
    if (row >= rows) {
        // Scroll up a line: text takes the attribute at the cursor.
        const fill: u8 = if (text) planeByte(vga, cellPa(mem, page, rows - 1, @min(col, cols - 1)), 1) else 0;
        scroll(vga, mem, page, true, 1, 0, 0, rows - 1, cols - 1, fill);
        row = rows - 1;
    }
    setCursor(vga, mem, page, row, col);
}

// ── int 10h ──────────────────────────────────────────────────────────────

fn esLin(r: *const Regs, off: u16) u32 {
    return Memory.lin(r.seg[regs.ES], off);
}
fn setEsBp(r: *Regs, seg: u16, off: u16) void {
    r.setSeg(regs.ES, seg);
    r.set16(regs.EBP, off);
}

/// int 10h.
pub fn int10(r: *Regs, mem: *Memory, vga: *Vga) void {
    switch (r.ah()) {
        0x00 => setMode(vga, mem, r.al()),
        0x01 => cursorShape(vga, mem, r.ch(), r.cl()),
        0x02 => setCursor(vga, mem, r.bh(), r.dh(), r.dl()),
        0x03 => {
            const c = cursorOf(mem, r.bh());
            r.setCx(mem.rdW(BDA, 0x60));
            r.setDh(@truncate(c.row));
            r.setDl(@truncate(c.col));
        },
        0x04 => r.setAh(0), // (no light pen)
        0x05 => selectPage(vga, mem, r.al()),
        0x06, 0x07 => scroll(vga, mem, mem.rdB(BDA, 0x62), r.ah() == 0x06, r.al(), r.ch(), r.cl(), r.dh(), r.dl(), r.bh()),
        0x08 => {
            const md = current(mem);
            const c = cursorOf(mem, r.bh());
            if (md.kind == .text or md.kind == .mono) {
                const pa = cellPa(mem, r.bh(), c.row, c.col);
                r.setAl(planeByte(vga, pa, 0));
                r.setAh(planeByte(vga, pa, 1));
            } else {
                r.setAl(readCharGfx(vga, mem, md, r.bh(), c.row, c.col));
                r.setAh(0);
            }
        },
        0x09 => writeChars(vga, mem, r.bh(), r.al(), r.bl(), r.bl(), r.cx()),
        0x0A => writeChars(vga, mem, r.bh(), r.al(), null, r.bl(), r.cx()),
        0x0B => cgaPalette(vga, mem, r.bh(), r.bl()),
        0x0C => {
            const md = current(mem);
            if (md.kind != .text and md.kind != .mono and r.cx() < md.w and r.dx() < md.h)
                putPixel(vga, md, r.bh(), r.cx(), r.dx(), r.al());
        },
        0x0D => {
            const md = current(mem);
            if (md.kind != .text and md.kind != .mono and r.cx() < md.w and r.dx() < md.h)
                r.setAl(getPixel(vga, md, r.bh(), r.cx(), r.dx()))
            else
                r.setAl(0);
        },
        0x0E => teletype(vga, mem, mem.rdB(BDA, 0x62), r.al(), r.bl(), null),
        0x0F => {
            r.setAl(mem.rdB(BDA, 0x49) | (mem.rdB(BDA, 0x87) & 0x80));
            r.setAh(@truncate(mem.rdW(BDA, 0x4A)));
            r.setBh(mem.rdB(BDA, 0x62));
        },
        0x10 => palette(r, mem, vga),
        0x11 => fonts(r, mem, vga),
        0x12 => alternate(r, mem, vga),
        0x13 => writeString(r, mem, vga),
        0x1A => if (r.al() <= 1) {
            if (r.al() == 0) {
                r.setBl(0x08); // VGA, colour analog display
                r.setBh(0x00);
            }
            r.setAl(0x1A);
        },
        0x1B => if (r.bx() == 0) state(r, mem, vga),
        0x4F => vesa_bios.int10(r, mem, vga),
        else => {},
    }
}

fn cursorShape(vga: *Vga, mem: *Memory, ch: u8, cl: u8) void {
    mem.wrB(BDA, 0x60, cl);
    mem.wrB(BDA, 0x61, ch);
    const md = current(mem);
    if (md.kind != .text and md.kind != .mono) return;
    if (ch & 0x60 == 0x20) {
        vga.crtc[0x0A] = (vga.crtc[0x0A] & 0xC0) | 0x20;
        return;
    }
    var s: u32 = ch & 0x1F;
    var e: u32 = cl & 0x1F;
    const h = charH(mem);
    // Cursor emulation (0x487 bit 0 clear): CGA's 8-line shapes scaled.
    if (mem.rdB(BDA, 0x87) & 0x01 == 0 and h > 8 and s <= 7 and e <= 7) {
        if (e >= 6 and s + 1 >= e) {
            s = h - 3;
            e = h - 2;
        } else {
            s = s * h / 8;
            e = @min((e + 1) * h / 8 - 1, h - 1);
        }
    }
    vga.crtc[0x0A] = (vga.crtc[0x0A] & 0xC0) | @as(u8, @truncate(s & 0x1F));
    vga.crtc[0x0B] = (vga.crtc[0x0B] & 0xE0) | @as(u8, @truncate(e & 0x1F));
}

fn selectPage(vga: *Vga, mem: *Memory, page: u8) void {
    const md = current(mem);
    if (page >= md.pages) return;
    mem.wrB(BDA, 0x62, page);
    const off: u32 = pageOff(mem, page);
    mem.wrW(BDA, 0x4E, @truncate(off));
    const text = md.kind == .text or md.kind == .mono;
    const start: u32 = if (text) off / 2 else off;
    vga.crtc[0x0C] = @truncate(start >> 8);
    vga.crtc[0x0D] = @truncate(start);
    syncCursor(vga, mem);
}

fn cgaPalette(vga: *Vga, mem: *Memory, bh: u8, bl: u8) void {
    const md = current(mem);
    var p = mem.rdB(BDA, 0x66);
    if (bh == 0) {
        // Background (graphics) or border (text), and the intensity.
        p = (p & 0xE0) | (bl & 0x1F);
        const v: u8 = (bl & 0x07) | (if (bl & 0x10 != 0) @as(u8, 0x10) else 0);
        vga.acWrite(0x11, v);
        if (md.kind == .cga4) vga.acWrite(0, v);
    } else {
        p = (p & ~@as(u8, 0x20)) | (if (bl & 1 != 0) @as(u8, 0x20) else 0);
    }
    mem.wrB(BDA, 0x66, p);
    if (md.kind == .cga4) {
        const bright: u8 = if (p & 0x10 != 0) 0x10 else 0;
        const set: [3]u8 = if (p & 0x20 != 0) .{ 3, 5, 7 } else .{ 2, 4, 6 };
        for (set, 1..) |v, i| vga.acWrite(@intCast(i), v | bright);
    }
}

fn palette(r: *Regs, mem: *Memory, vga: *Vga) void {
    switch (r.al()) {
        0x00 => if (r.bl() < 0x10) vga.acWrite(r.bl(), r.bh()),
        0x01 => vga.acWrite(0x11, r.bh()),
        0x02 => {
            const a = esLin(r, r.dx());
            for (0..16) |i| vga.acWrite(@intCast(i), mem.rd8(a + @as(u32, @intCast(i))));
            vga.acWrite(0x11, mem.rd8(a + 16));
        },
        0x03 => {
            const blink = r.bl() != 0;
            vga.acWrite(0x10, (vga.ac[0x10] & ~@as(u8, 0x08)) | (if (blink) @as(u8, 0x08) else 0));
            const ctl = mem.rdB(BDA, 0x65);
            mem.wrB(BDA, 0x65, (ctl & ~@as(u8, 0x20)) | (if (blink) @as(u8, 0x20) else 0));
        },
        0x07 => if (r.bl() < 0x15) r.setBh(vga.ac[r.bl()]),
        0x08 => r.setBh(vga.ac[0x11]),
        0x09 => {
            const a = esLin(r, r.dx());
            for (0..16) |i| mem.wr8(a + @as(u32, @intCast(i)), vga.ac[i]);
            mem.wr8(a + 16, vga.ac[0x11]);
        },
        0x10 => vga.setDac(@truncate(r.bx()), r.dh(), r.ch(), r.cl()),
        0x12 => {
            const a = esLin(r, r.dx());
            var i: u32 = 0;
            while (i < r.cx()) : (i += 1) {
                const at = a + i * 3;
                vga.setDac(@truncate(r.bx() +% i), mem.rd8(at), mem.rd8(at + 1), mem.rd8(at + 2));
            }
        },
        0x13 => {
            if (r.bl() == 0) {
                vga.acWrite(0x10, (vga.ac[0x10] & 0x7F) | (if (r.bh() & 1 != 0) @as(u8, 0x80) else 0));
            } else if (vga.ac[0x10] & 0x80 != 0) {
                vga.acWrite(0x14, r.bh() & 0x0F);
            } else {
                vga.acWrite(0x14, (r.bh() & 3) << 2);
            }
        },
        0x15 => {
            const c = vga.dac[r.bl()];
            r.setDh(c[0]);
            r.setCh(c[1]);
            r.setCl(c[2]);
        },
        0x17 => {
            const a = esLin(r, r.dx());
            var i: u32 = 0;
            while (i < r.cx()) : (i += 1) {
                const c = vga.dac[@as(u8, @truncate(r.bx() +% i))];
                mem.copyIn(a + i * 3, &c);
            }
        },
        0x18 => vga.dac_mask = r.bl(),
        0x19 => r.setBl(vga.dac_mask),
        0x1A => {
            const paging = vga.ac[0x10] & 0x80 != 0;
            r.setBl(if (paging) 1 else 0);
            r.setBh(if (paging) vga.ac[0x14] & 0x0F else (vga.ac[0x14] >> 2) & 3);
        },
        0x1B => {
            var i: u32 = 0;
            while (i < r.cx()) : (i += 1) {
                const idx: u8 = @truncate(r.bx() +% i);
                const g = greyOf(vga.dac[idx]);
                vga.setDac(idx, g, g, g);
            }
        },
        else => {},
    }
}

fn fonts(r: *Regs, mem: *Memory, vga: *Vga) void {
    const al = r.al();
    switch (al) {
        0x00, 0x10 => {
            const h = r.bh();
            loadGlyphs(vga, r.bl(), r.dx(), r.cx(), h, MemFont{ .mem = mem, .at = esLin(r, r.bp()) });
            if (al == 0x10) applyCharHeight(vga, mem, h);
        },
        0x01, 0x02, 0x04, 0x11, 0x12, 0x14 => {
            const h: u8 = switch (al & 0x0F) {
                0x01 => 14,
                0x02 => 8,
                else => 16,
            };
            loadGlyphs(vga, r.bl(), 0, 256, h, RomFont{ .data = romFont(h) });
            if (al >= 0x10) applyCharHeight(vga, mem, h);
        },
        0x03 => vga.seq[3] = r.bl(),
        0x20 => setVector(mem, 0x1F, r.seg[regs.ES], r.bp()),
        0x21, 0x22, 0x23, 0x24 => {
            const h: u16 = switch (al) {
                0x21 => r.cx(),
                0x22 => 14,
                0x23 => 8,
                else => 16,
            };
            if (al == 0x21) setVector(mem, 0x43, r.seg[regs.ES], r.bp()) else setVector(mem, 0x43, ROM_SEG, romFontOff(@intCast(h)));
            const rows: u16 = switch (r.bl()) {
                0 => @as(u16, r.dl()) + 1,
                1 => 14,
                2 => 25,
                else => 43,
            };
            mem.wrW(BDA, 0x85, h);
            mem.wrB(BDA, 0x84, @truncate(rows - 1));
        },
        0x30 => {
            switch (r.bh()) {
                0 => setEsBp(r, mem.rdW(0, 0x7E), mem.rdW(0, 0x7C)),
                1 => setEsBp(r, mem.rdW(0, 0x10E), mem.rdW(0, 0x10C)),
                2 => setEsBp(r, ROM_SEG, FONT14),
                3 => setEsBp(r, ROM_SEG, FONT8),
                4 => setEsBp(r, ROM_SEG, FONT8 + 128 * 8),
                5 => setEsBp(r, ROM_SEG, ALT9X14),
                6 => setEsBp(r, ROM_SEG, FONT16),
                7 => setEsBp(r, ROM_SEG, ALT9X16),
                else => {},
            }
            r.setCx(mem.rdW(BDA, 0x85));
            r.setDl(mem.rdB(BDA, 0x84));
        },
        else => {},
    }
}

fn alternate(r: *Regs, mem: *Memory, vga: *Vga) void {
    switch (r.bl()) {
        0x10 => {
            r.setBh(if (mem.rdW(BDA, 0x63) == 0x3B4) 1 else 0);
            r.setBl(0x03); // 256 KiB
            r.setCh(0x00);
            r.setCl(mem.rdB(BDA, 0x88) & 0x0F);
        },
        0x20 => r.setAl(0x12),
        0x30 => {
            // Scan lines for the next text mode: 200, 350, 400.
            const sl: ?u8 = switch (r.al()) {
                0 => 0x80,
                1 => 0x00,
                2 => 0x10,
                else => null,
            };
            if (sl) |v| {
                mem.wrB(BDA, 0x89, (mem.rdB(BDA, 0x89) & 0x6F) | v);
                r.setAl(0x12);
            } else r.setAl(0);
        },
        0x31 => {
            const off = r.al() != 0;
            mem.wrB(BDA, 0x89, (mem.rdB(BDA, 0x89) & ~@as(u8, 0x08)) | (if (off) @as(u8, 0x08) else 0));
            r.setAl(0x12);
        },
        0x32 => r.setAl(0x12),
        0x33 => {
            const on = r.al() == 0;
            mem.wrB(BDA, 0x89, (mem.rdB(BDA, 0x89) & ~@as(u8, 0x02)) | (if (on) @as(u8, 0x02) else 0));
            r.setAl(0x12);
        },
        0x34 => {
            const off = r.al() != 0;
            mem.wrB(BDA, 0x87, (mem.rdB(BDA, 0x87) & ~@as(u8, 0x01)) | (if (off) @as(u8, 0x01) else 0));
            r.setAl(0x12);
        },
        0x36 => {
            vga.seq[1] = (vga.seq[1] & ~@as(u8, 0x20)) | (if (r.al() != 0) @as(u8, 0x20) else 0);
            r.setAl(0x12);
        },
        else => {},
    }
}

fn writeString(r: *Regs, mem: *Memory, vga: *Vga) void {
    const mode = r.al();
    const page = r.bh();
    const saved = cursorOf(mem, page);
    setCursor(vga, mem, page, r.dh(), r.dl());
    var a = esLin(r, r.bp());
    var n: u32 = 0;
    var attr: u8 = r.bl();
    while (n < r.cx()) : (n += 1) {
        const c = mem.rd8(a);
        a +%= 1;
        if (mode & 2 != 0) {
            attr = mem.rd8(a);
            a +%= 1;
        }
        switch (c) {
            0x07, 0x08, 0x0A, 0x0D => teletype(vga, mem, page, c, attr, null),
            else => teletype(vga, mem, page, c, attr, attr),
        }
    }
    if (mode & 1 == 0) setCursor(vga, mem, page, saved.row, saved.col);
}

/// AH=1Bh: the video state into ES:DI's 64 bytes.
fn state(r: *Regs, mem: *Memory, vga: *Vga) void {
    const md = current(mem);
    const a = esLin(r, r.di());
    var b: [64]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], STATIC_TABLE, .little);
    std.mem.writeInt(u16, b[2..4], ROM_SEG, .little);
    b[4] = mem.rdB(BDA, 0x49);
    mem.copyOut(Memory.lin(BDA, 0x4A), b[5..0x1E]);
    mem.copyOut(Memory.lin(BDA, 0x63), b[0x1E..0x22]);
    b[0x22] = mem.rdB(BDA, 0x84) + 1;
    std.mem.writeInt(u16, b[0x23..0x25], mem.rdW(BDA, 0x85), .little);
    b[0x25] = 0x08;
    b[0x26] = 0x00;
    std.mem.writeInt(u16, b[0x27..0x29], md.colours, .little);
    b[0x29] = md.pages;
    const lines = vga.timing().vde;
    b[0x2A] = if (lines <= 200 or (lines == 400 and vga.crtc[9] & 0x80 != 0)) 0 else if (lines <= 350) 1 else if (lines <= 400) 2 else 3;
    const sm = vga.seq[3];
    b[0x2B] = (((sm >> 5) & 1) << 2) | ((sm >> 2) & 3);
    b[0x2C] = (((sm >> 4) & 1) << 2) | (sm & 3);
    const f89 = mem.rdB(BDA, 0x89);
    b[0x2D] = (f89 & 0x0A) | (if (mem.rdB(BDA, 0x87) & 0x01 == 0) @as(u8, 0x10) else 0) |
        (if (vga.ac[0x10] & 0x08 != 0) @as(u8, 0x20) else 0) | (if (md.kind == .mono) @as(u8, 0x04) else 0);
    b[0x31] = 0x03;
    mem.copyIn(a, &b);
    r.setAl(0x1B);
}
