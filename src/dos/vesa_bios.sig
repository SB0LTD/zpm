//! VESA BIOS Extensions 2.0 (int 10h AH=4Fh) on the SVGA (vesa.sig), as
//! a mid-1990s card's BIOS offered them:
//!
//!   4F00  controller info: "VESA" 2.0 (the 2.0 fields when the caller
//!         asked with "VBE2"), DAC switchable to 8 bits, 4 MiB, the modes
//!   4F01  mode info: window A at A000 (64 KiB, granularity 64 KiB, the
//!         far window function), the linear frame buffer at LFB_BASE,
//!         packed or direct colour with its masks; VBE 3.0's linear fields
//!   4F02  set mode (bit 14 linear, bit 15 keep memory; VGA modes too)
//!   4F03  current mode      4F04  save/restore state (VGA registers,
//!   BIOS data, DAC, SVGA)   4F05  window A's position (and the far
//!   call at C000:WIN_FUNC)  4F06  scan line length (pixels, bytes, max)
//!   4F07  display start (and during retrace; VBE 3.0's byte address)
//!   4F08  DAC width 6/8     4F09  palette data, primary and secondary
//!   4F0Ah (protected-mode interface), 4F15h (DDC) and the rest: 014Fh
//!   (failed), so programs use the real-mode calls.
//!
//! Clean room, from VESA's VBE 2.0 and 3.0 specifications (the blocks'
//! layouts and the functions' registers).
//!
//! The tables live in the video ROM (C000:3000 on, past the fonts):
//! the window function's stub (`FE 39 02 CB`: machine.sig's trap 102h,
//! then RETF), the OEM strings and the mode list.

const std = @import("std");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const Vga = @import("vga.sig").Vga;
const vesa = @import("vesa.sig");
const video_bios = @import("video_bios.sig");

pub const ROM_SEG: u16 = 0xC000;
/// The far window function: FE 39 02 (trap 102h), RETF.
pub const WIN_FUNC: u16 = 0x3000;
pub const WIN_TRAP: u8 = 0x02;
const OEM_STR: u16 = 0x3010;
const VENDOR: u16 = 0x3040;
const PRODUCT: u16 = 0x3050;
const REVISION: u16 = 0x3070;
const MODE_LIST: u16 = 0x3080;

const BDA: u16 = 0x40;

/// AX's answers: done, failed, not in this mode.
const OK: u16 = 0x004F;
const FAIL: u16 = 0x014F;
const BAD_MODE: u16 = 0x034F;

/// The video ROM's VESA tables (video_bios.boot calls this).
pub fn boot(mem: *Memory) void {
    const rom = Memory.lin(ROM_SEG, 0);
    mem.copyIn(rom + WIN_FUNC, &.{ 0xFE, 0x39, WIN_TRAP, 0xCB });
    mem.copyIn(rom + OEM_STR, "zpm dos SVGA in Sig\x00");
    mem.copyIn(rom + VENDOR, "zpm\x00");
    mem.copyIn(rom + PRODUCT, "Sig SVGA 4 MB\x00");
    mem.copyIn(rom + REVISION, "1.0\x00");
    var at: u32 = rom + MODE_LIST;
    for (vesa.modes) |m| {
        mem.wr16(at, m.n);
        at += 2;
    }
    mem.wr16(at, 0xFFFF);
}

fn esDi(r: *const Regs) u32 {
    return r.base[regs.ES] +% r.di();
}

inline fn put16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
inline fn put32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
inline fn far(seg: u16, off: u16) u32 {
    return (@as(u32, seg) << 16) | off;
}

/// int 10h, AH=4Fh.
pub fn int10(r: *Regs, mem: *Memory, vga: *Vga) void {
    switch (r.al()) {
        0x00 => info(r, mem),
        0x01 => modeInfo(r, mem),
        0x02 => setMode(r, mem, vga),
        0x03 => {
            const s = &vga.svga;
            if (s.active) {
                r.setBx(s.mode | (if (s.linear) @as(u16, 0x4000) else 0) | (if (s.kept) @as(u16, 0x8000) else 0));
            } else r.setBx(mem.rdB(BDA, 0x49) & 0x7F);
            r.setAx(OK);
        },
        0x04 => saveRestore(r, mem, vga),
        0x05 => r.setAx(window(r, vga)),
        0x06 => scanLine(r, vga),
        0x07 => displayStart(r, vga),
        0x08 => dacWidth(r, vga),
        0x09 => paletteData(r, mem, vga),
        else => r.setAx(FAIL),
    }
}

/// The far window function (WinFuncPtr): 4F05's registers, AX kept.
pub fn winFunc(r: *Regs, vga: *Vga) void {
    const ax = r.ax();
    _ = window(r, vga);
    r.setAx(ax);
}

// ── 4F00, 4F01 ───────────────────────────────────────────────────────────

fn info(r: *Regs, mem: *Memory) void {
    const a = esDi(r);
    const vbe2 = mem.rd32(a) == std.mem.readInt(u32, "VBE2", .little);
    var b: [512]u8 = @splat(0);
    @memcpy(b[0..4], "VESA");
    put16(&b, 4, 0x0200);
    put32(&b, 6, far(ROM_SEG, OEM_STR));
    // Capabilities: the DAC switches to 8 bits; VGA compatible; the
    // RAMDAC needs no blank bit.
    put32(&b, 10, 0x0000_0001);
    put32(&b, 14, far(ROM_SEG, MODE_LIST));
    put16(&b, 18, @intCast(vesa.VRAM / 0x10000));
    if (vbe2) {
        put16(&b, 20, 0x0100);
        put32(&b, 22, far(ROM_SEG, VENDOR));
        put32(&b, 26, far(ROM_SEG, PRODUCT));
        put32(&b, 30, far(ROM_SEG, REVISION));
    }
    // (a VBE 1.x caller's block is 256 bytes)
    mem.copyIn(a, if (vbe2) b[0..512] else b[0..256]);
    r.setAx(OK);
}

fn modeInfo(r: *Regs, mem: *Memory) void {
    const md = vesa.modeOf(r.cx()) orelse {
        r.setAx(FAIL);
        return;
    };
    var b: [256]u8 = @splat(0);
    const pitch = md.pitch();
    const pages: u32 = vesa.VRAM / (pitch * md.h);
    const img: u8 = @intCast(@min(pages - 1, 255));
    // Supported, extended information, colour, graphics, windowed and
    // linear (no BIOS text output in these modes).
    put16(&b, 0, 0x009B);
    b[2] = 0x07; // window A: there, readable, writable
    b[3] = 0x00; // no window B
    put16(&b, 4, @intCast(vesa.WIN_SIZE / 1024));
    put16(&b, 6, @intCast(vesa.WIN_SIZE / 1024));
    put16(&b, 8, vesa.WIN_SEG);
    put16(&b, 10, 0);
    put32(&b, 12, far(ROM_SEG, WIN_FUNC));
    put16(&b, 16, @intCast(pitch));
    put16(&b, 18, md.w);
    put16(&b, 20, md.h);
    b[22] = 8;
    b[23] = 16;
    b[24] = 1; // planes
    b[25] = md.bpp;
    b[26] = 1; // banks
    b[27] = if (md.bpp == 8) 4 else 6; // packed pixel, direct colour
    b[28] = 0;
    b[29] = img;
    b[30] = 1;
    const masks: [8]u8 = switch (md.bpp) {
        15 => .{ 5, 10, 5, 5, 5, 0, 1, 15 },
        16 => .{ 5, 11, 6, 5, 5, 0, 0, 0 },
        24 => .{ 8, 16, 8, 8, 8, 0, 0, 0 },
        32 => .{ 8, 16, 8, 8, 8, 0, 8, 24 },
        else => @splat(0),
    };
    @memcpy(b[31..39], &masks);
    // The reserved bits are the program's to use (15 and 32 bits).
    b[39] = if (masks[6] != 0) 0x02 else 0x00;
    put32(&b, 40, vesa.LFB_BASE);
    put32(&b, 44, 0);
    put16(&b, 48, 0);
    // VBE 3.0: the linear mode's line, pages and masks; the pixel clock.
    put16(&b, 50, @intCast(pitch));
    b[52] = img;
    b[53] = img;
    @memcpy(b[54..62], &masks);
    put32(&b, 62, 135_000_000);
    mem.copyIn(esDi(r), &b);
    r.setAx(OK);
}

// ── 4F02 ─────────────────────────────────────────────────────────────────

fn setMode(r: *Regs, mem: *Memory, vga: *Vga) void {
    const bx = r.bx();
    const n: u16 = bx & 0x1FF;
    const keep = bx & 0x8000 != 0;
    if (n < 0x100) {
        // A VGA mode through VBE.
        if (video_bios.modeOf(@intCast(n)) == null) {
            r.setAx(FAIL);
            return;
        }
        video_bios.setMode(vga, mem, @as(u8, @intCast(n)) | (if (keep) @as(u8, 0x80) else 0));
        r.setAx(OK);
        return;
    }
    const md = vesa.modeOf(n) orelse {
        r.setAx(FAIL);
        return;
    };
    // The VGA as mode 13h underneath (its DAC with the 256 colours, its
    // retrace), then the SVGA's mode over it.
    video_bios.setMode(vga, mem, 0x13 | (if (keep) @as(u8, 0x80) else 0));
    vga.svga.set(md, bx & 0x4000 != 0, keep);
    r.setAx(OK);
}

// ── 4F04 ─────────────────────────────────────────────────────────────────

/// The state's parts (CX bits 0-3) and their sizes in 64-byte blocks.
const part_blocks = [4]u32{ 2, 1, 13, 1 };

fn saveRestore(r: *Regs, mem: *Memory, vga: *Vga) void {
    const want: u16 = r.cx() & 0xF;
    switch (r.dl()) {
        0x00 => {
            var n: u32 = 0;
            for (part_blocks, 0..) |bl, i| {
                if (want & (@as(u16, 1) << @intCast(i)) != 0) n += bl;
            }
            r.setBx(@intCast(n));
        },
        0x01, 0x02 => {
            const save = r.dl() == 0x01;
            var a: u32 = r.base[regs.ES] +% r.bx();
            for (part_blocks, 0..) |bl, i| {
                if (want & (@as(u16, 1) << @intCast(i)) == 0) continue;
                var b: [13 * 64]u8 = @splat(0);
                const blk = b[0 .. bl * 64];
                if (save) {
                    savePart(i, blk, mem, vga);
                    mem.copyIn(a, blk);
                } else {
                    mem.copyOut(a, blk);
                    restorePart(i, blk, mem, vga);
                }
                a +%= bl * 64;
            }
        },
        else => {
            r.setAx(FAIL);
            return;
        },
    }
    r.setAx(OK);
}

fn savePart(part: usize, b: []u8, mem: *const Memory, vga: *const Vga) void {
    switch (part) {
        0 => {
            b[0] = vga.misc;
            b[1] = vga.fcr;
            b[2] = vga.seq_i;
            b[3] = vga.crtc_i;
            b[4] = vga.gc_i;
            b[5] = vga.ac_i;
            b[6] = vga.dac_mask;
            @memcpy(b[8..13], vga.seq[0..5]);
            @memcpy(b[16..41], &vga.crtc);
            @memcpy(b[48..57], &vga.gc);
            @memcpy(b[64..85], &vga.ac);
        },
        1 => {
            mem.copyOut(Memory.lin(BDA, 0x49), b[0..30]);
            mem.copyOut(Memory.lin(BDA, 0x84), b[32..39]);
        },
        2 => {
            b[0] = if (vga.dac8) 8 else 6;
            b[1] = vga.dac_w;
            for (vga.dac, 0..) |c, i| @memcpy(b[4 + i * 3 ..][0..3], &c);
        },
        else => {
            const s = &vga.svga;
            b[0] = @intFromBool(s.active);
            b[1] = @intFromBool(s.linear);
            b[2] = @intFromBool(s.kept);
            put16(b, 4, s.mode);
            put32(b, 8, s.pitch);
            put32(b, 12, s.start);
            put32(b, 16, s.bank_off);
        },
    }
}

fn restorePart(part: usize, b: []const u8, mem: *Memory, vga: *Vga) void {
    switch (part) {
        0 => {
            vga.misc = b[0];
            vga.fcr = b[1];
            vga.seq_i = b[2];
            vga.crtc_i = b[3];
            vga.gc_i = b[4];
            vga.ac_i = b[5];
            vga.dac_mask = b[6];
            @memcpy(vga.seq[0..5], b[8..13]);
            @memcpy(&vga.crtc, b[16..41]);
            @memcpy(&vga.gc, b[48..57]);
            @memcpy(&vga.ac, b[64..85]);
            vga.changed(true);
        },
        1 => {
            mem.copyIn(Memory.lin(BDA, 0x49), b[0..30]);
            mem.copyIn(Memory.lin(BDA, 0x84), b[32..39]);
        },
        2 => {
            vga.setDacWidth(b[0] == 8);
            vga.dac_w = b[1];
            for (0..256) |i| vga.setDac(@intCast(i), b[4 + i * 3], b[5 + i * 3], b[6 + i * 3]);
        },
        else => {
            const s = &vga.svga;
            const mode = std.mem.readInt(u16, b[4..6], .little);
            if (b[0] == 0) {
                s.active = false;
                return;
            }
            const md = vesa.modeOf(mode) orelse return;
            s.set(md, b[1] != 0, true);
            s.kept = b[2] != 0;
            const pitch = std.mem.readInt(u32, b[8..12], .little);
            if (pitch != 0 and pitch * md.h <= vesa.VRAM) s.pitch = pitch;
            s.start = std.mem.readInt(u32, b[12..16], .little) & (vesa.VRAM - 1);
            const bank = std.mem.readInt(u32, b[16..20], .little);
            if (bank < vesa.VRAM) s.bank_off = bank & ~(vesa.WIN_SIZE - 1);
        },
    }
}

// ── 4F05-4F09 ────────────────────────────────────────────────────────────

/// 4F05: BH=00h set window BL to DX (granularity units), 01h get it.
fn window(r: *Regs, vga: *Vga) u16 {
    const s = &vga.svga;
    if (!s.active) return BAD_MODE;
    // (window A only)
    if (r.bl() != 0) return FAIL;
    switch (r.bh()) {
        0x00 => {
            if (r.dx() >= vesa.BANKS) return FAIL;
            s.bank_off = @as(u32, r.dx()) * vesa.WIN_SIZE;
        },
        0x01 => r.setDx(@intCast(s.bank_off / vesa.WIN_SIZE)),
        else => return FAIL,
    }
    return OK;
}

/// The largest scan line, in bytes, for the mode's height.
fn maxPitch(s: *const vesa.Svga) u32 {
    const m: u32 = @min(vesa.VRAM / @max(@as(u32, s.h), 1), 0xFFFF);
    return m - m % s.bytes;
}

fn scanLine(r: *Regs, vga: *Vga) void {
    const s = &vga.svga;
    if (!s.active) return r.setAx(BAD_MODE);
    switch (r.bl()) {
        0x00, 0x02 => {
            const want: u32 = if (r.bl() == 0) @as(u32, r.cx()) * s.bytes else r.cx();
            // (whole pixels: rounded up)
            const bytes: u32 = (want + s.bytes - 1) / s.bytes * s.bytes;
            if (bytes == 0 or bytes > maxPitch(s)) return r.setAx(0x024F);
            s.pitch = bytes;
        },
        0x01 => {},
        0x03 => {
            const m = maxPitch(s);
            r.setBx(@intCast(m));
            r.setCx(@intCast(m / s.bytes));
            r.setDx(@intCast(@min(vesa.VRAM / m, 0xFFFF)));
            return r.setAx(OK);
        },
        else => return r.setAx(FAIL),
    }
    r.setBx(@intCast(s.pitch));
    r.setCx(@intCast(s.pitch / s.bytes));
    r.setDx(@intCast(@min(vesa.VRAM / s.pitch, 0xFFFF)));
    r.setAx(OK);
}

fn displayStart(r: *Regs, vga: *Vga) void {
    const s = &vga.svga;
    if (!s.active) return r.setAx(BAD_MODE);
    switch (r.bl()) {
        // Now, or "during vertical retrace" (the picture is taken whole
        // when the host asks, so now is the same).
        0x00, 0x80 => {
            const at: u64 = @as(u64, r.dx()) * s.pitch + @as(u64, r.cx()) * s.bytes;
            if (at >= vesa.VRAM) return r.setAx(FAIL);
            s.start = @intCast(at);
        },
        0x01 => {
            r.setBh(0);
            r.setCx(@intCast((s.start % s.pitch) / s.bytes));
            r.setDx(@intCast(s.start / s.pitch));
        },
        // VBE 3.0: schedule a start (ECX: its byte address); its status
        // (CX: non-zero, the flip has happened).
        0x02, 0x82 => {
            const at = r.r[regs.ECX];
            if (at >= vesa.VRAM) return r.setAx(FAIL);
            s.start = at;
        },
        0x03 => r.setCx(1),
        else => return r.setAx(FAIL),
    }
    r.setAx(OK);
}

fn dacWidth(r: *Regs, vga: *Vga) void {
    const s = &vga.svga;
    switch (r.bl()) {
        0x00 => {
            if (s.active and s.bpp != 8) return r.setAx(BAD_MODE);
            vga.setDacWidth(r.bh() >= 8);
        },
        0x01 => {},
        else => return r.setAx(FAIL),
    }
    r.setBh(if (vga.dac8) 8 else 6);
    r.setAx(OK);
}

/// 4F09: CX entries from DX, at ES:DI as blue, green, red, 0 (in the
/// DAC's width).
fn paletteData(r: *Regs, mem: *Memory, vga: *Vga) void {
    const first: u32 = r.dx();
    const n: u32 = r.cx();
    if (first + n > 256) return r.setAx(FAIL);
    const a = esDi(r);
    var i: u32 = 0;
    switch (r.bl()) {
        0x00, 0x80 => while (i < n) : (i += 1) {
            const e = a +% i * 4;
            vga.setDac(@intCast(first + i), mem.rd8(e + 2), mem.rd8(e + 1), mem.rd8(e));
        },
        0x01 => while (i < n) : (i += 1) {
            const c = vga.dac[first + i];
            mem.copyIn(a +% i * 4, &.{ c[2], c[1], c[0], 0 });
        },
        0x02 => while (i < n) : (i += 1) {
            vga.svga.pal2[first + i] = mem.rd32(a +% i * 4);
        },
        0x03 => while (i < n) : (i += 1) {
            mem.wr32(a +% i * 4, vga.svga.pal2[first + i]);
        },
        else => return r.setAx(FAIL),
    }
    r.setAx(OK);
}
