//! The SVGA side of the adapter: 4 MiB of video memory, the VESA modes
//! (VBE 2.0's 100h-11Bh that fit, and a few OEM numbers for 32-bit colour
//! and the low resolutions games liked), and the picture of a VESA mode.
//! The VGA (vga.sig) holds one `Svga` and hands render to it while a VESA
//! mode is set; vesa_bios.sig is int 10h's 4Fxx on top of it.
//!
//! Clean room, from VESA's VBE 2.0 and 3.0 specifications.
//!
//! Memory: `mem` is the card's frame buffer, one byte array; pixels are
//! packed (8 bits: a DAC index) or direct colour (15/16 bits 5:5:5 and
//! 5:6:5, 24 bits B,G,R, 32 bits B,G,R,X), lines `pitch` bytes apart. The
//! CPU reaches it two ways (machine.sig routes both):
//!   window A   0xA0000-0xAFFFF, 64 KiB of it at `bank` * 64 KiB
//!   the LFB    LFB_BASE .. LFB_BASE + VRAM, all of it, above the RAM
//!              where a PCI card's aperture would be
//! The display starts at byte `start` (4F07) and shows `w` x `h`.

const std = @import("std");

pub const Size = struct { w: u16 = 0, h: u16 = 0 };

/// Video memory: 4 MiB, as a good 1995 card had.
pub const VRAM: u32 = 4 << 20;
/// The linear frame buffer's physical address (above the 16 MiB of RAM,
/// at the top of the 32-bit space as PCI put apertures).
pub const LFB_BASE: u32 = 0xE000_0000;
/// Window A: where, how big, and its granularity.
pub const WIN_SEG: u16 = 0xA000;
pub const WIN_SIZE: u32 = 0x10000;
pub const BANKS: u32 = VRAM / WIN_SIZE;

pub const ModeDesc = struct {
    n: u16,
    w: u16,
    h: u16,
    /// 8, 15, 16, 24 or 32.
    bpp: u8,

    pub fn bytesPP(m: ModeDesc) u32 {
        return (@as(u32, m.bpp) + 7) / 8;
    }
    pub fn pitch(m: ModeDesc) u32 {
        return @as(u32, m.w) * m.bytesPP();
    }
};

/// Every mode the card has (all of them fit in VRAM).
const all_modes = [_]ModeDesc{
    // VBE's standard numbers.
    .{ .n = 0x100, .w = 640, .h = 400, .bpp = 8 },
    .{ .n = 0x101, .w = 640, .h = 480, .bpp = 8 },
    .{ .n = 0x103, .w = 800, .h = 600, .bpp = 8 },
    .{ .n = 0x105, .w = 1024, .h = 768, .bpp = 8 },
    .{ .n = 0x107, .w = 1280, .h = 1024, .bpp = 8 },
    .{ .n = 0x10D, .w = 320, .h = 200, .bpp = 15 },
    .{ .n = 0x10E, .w = 320, .h = 200, .bpp = 16 },
    .{ .n = 0x10F, .w = 320, .h = 200, .bpp = 24 },
    .{ .n = 0x110, .w = 640, .h = 480, .bpp = 15 },
    .{ .n = 0x111, .w = 640, .h = 480, .bpp = 16 },
    .{ .n = 0x112, .w = 640, .h = 480, .bpp = 24 },
    .{ .n = 0x113, .w = 800, .h = 600, .bpp = 15 },
    .{ .n = 0x114, .w = 800, .h = 600, .bpp = 16 },
    .{ .n = 0x115, .w = 800, .h = 600, .bpp = 24 },
    .{ .n = 0x116, .w = 1024, .h = 768, .bpp = 15 },
    .{ .n = 0x117, .w = 1024, .h = 768, .bpp = 16 },
    .{ .n = 0x118, .w = 1024, .h = 768, .bpp = 24 },
    .{ .n = 0x119, .w = 1280, .h = 1024, .bpp = 15 },
    .{ .n = 0x11A, .w = 1280, .h = 1024, .bpp = 16 },
    .{ .n = 0x11B, .w = 1280, .h = 1024, .bpp = 24 },
    // OEM numbers: the low resolutions, 1600x1200, and 32-bit colour.
    .{ .n = 0x130, .w = 320, .h = 200, .bpp = 8 },
    .{ .n = 0x131, .w = 320, .h = 240, .bpp = 8 },
    .{ .n = 0x132, .w = 320, .h = 400, .bpp = 8 },
    .{ .n = 0x133, .w = 400, .h = 300, .bpp = 8 },
    .{ .n = 0x134, .w = 512, .h = 384, .bpp = 8 },
    .{ .n = 0x135, .w = 320, .h = 240, .bpp = 16 },
    .{ .n = 0x136, .w = 400, .h = 300, .bpp = 16 },
    .{ .n = 0x120, .w = 1600, .h = 1200, .bpp = 8 },
    .{ .n = 0x121, .w = 1600, .h = 1200, .bpp = 16 },
    .{ .n = 0x140, .w = 320, .h = 200, .bpp = 32 },
    .{ .n = 0x141, .w = 640, .h = 480, .bpp = 32 },
    .{ .n = 0x142, .w = 800, .h = 600, .bpp = 32 },
    .{ .n = 0x143, .w = 1024, .h = 768, .bpp = 32 },
};

pub const modes = blk: {
    var n = 0;
    for (all_modes) |m| {
        if (m.pitch() * m.h <= VRAM) n += 1;
    }
    var t: [n]ModeDesc = undefined;
    var i = 0;
    for (all_modes) |m| {
        if (m.pitch() * m.h <= VRAM) {
            t[i] = m;
            i += 1;
        }
    }
    break :blk t;
};

pub fn modeOf(n: u16) ?*const ModeDesc {
    for (&modes) |*m| if (m.n == n & 0x1FF) return m;
    return null;
}

/// The widest picture `render` makes.
pub const MAX_W: u32 = 1600;
pub const MAX_H: u32 = 1200;

pub const Svga = struct {
    mem: [VRAM]u8 align(4096) = undefined,
    /// A VESA mode is set (the VGA's own picture and window are off).
    active: bool = false,
    /// Its number, whether it was set with the LFB bit (14) and the
    /// don't-clear bit (15).
    mode: u16 = 0,
    linear: bool = false,
    kept: bool = false,
    w: u16 = 0,
    h: u16 = 0,
    bpp: u8 = 8,
    /// Bytes per pixel and per scan line.
    bytes: u8 = 1,
    pitch: u32 = 0,
    /// The display start, in bytes.
    start: u32 = 0,
    /// Window A's position (64 KiB units) as a byte offset into `mem`.
    bank_off: u32 = 0,
    /// The secondary palette (4F09 BL=02h/03h), as the caller wrote it.
    pal2: [256]u32 = @splat(0),

    pub fn reset(self: *Svga) void {
        self.* = .{};
        @memset(&self.mem, 0);
    }

    /// A VESA mode: its geometry, window and start at 0.
    pub fn set(self: *Svga, md: *const ModeDesc, linear: bool, keep: bool) void {
        self.active = true;
        self.mode = md.n;
        self.linear = linear;
        self.kept = keep;
        self.w = md.w;
        self.h = md.h;
        self.bpp = md.bpp;
        self.bytes = @intCast(md.bytesPP());
        self.pitch = md.pitch();
        self.start = 0;
        self.bank_off = 0;
        if (!keep) @memset(&self.mem, 0);
    }

    /// The image pages the memory holds at this pitch (4F01's count is
    /// this less one).
    pub fn pages(self: *const Svga) u32 {
        const page = self.pitch * self.h;
        return if (page == 0) 1 else VRAM / page;
    }

    // ── The CPU's side (machine.sig's bus) ──────────────────────────────

    /// Window A's byte `off` (< WIN_SIZE) in `mem`, or null past its end.
    pub inline fn winAt(self: *const Svga, off: u32) ?u32 {
        const o = self.bank_off + off;
        return if (o < VRAM) o else null;
    }
    pub inline fn winRead(self: *const Svga, off: u32) u8 {
        const o = self.winAt(off) orelse return 0xFF;
        return self.mem[o];
    }
    pub inline fn winWrite(self: *Svga, off: u32, v: u8) void {
        const o = self.winAt(off) orelse return;
        self.mem[o] = v;
    }

    // ── The picture ──────────────────────────────────────────────────────

    pub fn displaySize(self: *const Svga) Size {
        return .{ .w = self.w, .h = self.h };
    }

    /// The mode's picture into `out` (XRGB8888, `stride` pixels a row, at
    /// most `max`), from the display start, one scan line every `pitch`
    /// bytes; 8 bits go through `lut` (the DAC, its mask applied).
    pub fn render(self: *const Svga, lut: *const [256]u32, out: []u32, stride: u32, max: Size) Size {
        if (stride == 0) return .{};
        const w: u32 = @min(@min(@as(u32, self.w), max.w), stride);
        const h: u32 = @min(@min(@as(u32, self.h), max.h), @as(u32, @intCast(out.len / stride)));
        const bpl: u32 = w * self.bytes;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const dst = out[y * stride ..][0..w];
            const at: u32 = (self.start + y * self.pitch) & (VRAM - 1);
            if (at + bpl <= VRAM) {
                self.line(dst, self.mem[at..][0..bpl], lut);
            } else {
                // (the line wraps at the memory's end)
                var tmp: [MAX_W * 4]u8 = undefined;
                for (tmp[0..bpl], 0..) |*b, i| b.* = self.mem[(at + @as(u32, @intCast(i))) & (VRAM - 1)];
                self.line(dst, tmp[0..bpl], lut);
            }
        }
        return .{ .w = @intCast(w), .h = @intCast(h) };
    }

    fn line(self: *const Svga, dst: []u32, src: []const u8, lut: *const [256]u32) void {
        switch (self.bpp) {
            8 => for (dst, src) |*d, s| {
                d.* = lut[s];
            },
            15 => for (dst, 0..) |*d, i| {
                const c: u32 = std.mem.readInt(u16, src[i * 2 ..][0..2], .little);
                d.* = (x5(c >> 10) << 16) | (x5(c >> 5) << 8) | x5(c);
            },
            16 => for (dst, 0..) |*d, i| {
                const c: u32 = std.mem.readInt(u16, src[i * 2 ..][0..2], .little);
                d.* = (x5(c >> 11) << 16) | (x6(c >> 5) << 8) | x5(c);
            },
            24 => for (dst, 0..) |*d, i| {
                const p = src[i * 3 ..][0..3];
                d.* = (@as(u32, p[2]) << 16) | (@as(u32, p[1]) << 8) | p[0];
            },
            else => for (dst, 0..) |*d, i| {
                d.* = std.mem.readInt(u32, src[i * 4 ..][0..4], .little) & 0xFFFFFF;
            },
        }
    }
};

/// 5 and 6 bits of colour as 8 (the top bits repeated below).
inline fn x5(c: u32) u32 {
    const v = c & 0x1F;
    return (v << 3) | (v >> 2);
}
inline fn x6(c: u32) u32 {
    const v = c & 0x3F;
    return (v << 2) | (v >> 4);
}

test "vesa: the mode table fits the memory and has the standard numbers" {
    try std.testing.expect(modeOf(0x101) != null);
    try std.testing.expect(modeOf(0x11B) != null); // 1280x1024x24: 3.75 MiB
    for (modes) |m| try std.testing.expect(m.pitch() * m.h <= VRAM);
    try std.testing.expectEqual(@as(u16, 0x101), modeOf(0x4101).?.n);
}
