//! The VGA (vga.sig) and int 10h (video_bios.sig): registers, the memory
//! interface's read and write modes, chain-4 and unchained addressing,
//! the picture of text, mode 13h and mode X with scrolling and the split
//! screen, the retrace's timing, and the BIOS's mode set and teletype.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const vga_mod = @import("vga.sig");
const Vga = vga_mod.Vga;
const vb = @import("video_bios.sig");
const font = @import("vga_font.sig");
const Memory = @import("mem.sig").Memory;
const regs = @import("regs.sig");

var v: Vga = .{};
var mem: Memory = .{};
var px: [720 * 480]u32 = undefined;

fn boot() void {
    mem.clear();
    v.reset();
    vb.boot(&v, &mem);
}
fn int10(ax: u16, bx: u16, cx: u16, dx: u16) regs.Regs {
    var r = regs.Regs{};
    r.setAx(ax);
    r.setBx(bx);
    r.setCx(cx);
    r.setDx(dx);
    vb.int10(&r, &mem, &v);
    return r;
}
fn seqW(i: u8, x: u8) void {
    v.out8(0x3C4, i);
    v.out8(0x3C5, x);
}
fn crtcW(i: u8, x: u8) void {
    v.out8(0x3D4, i);
    v.out8(0x3D5, x);
}
fn gcW(i: u8, x: u8) void {
    v.out8(0x3CE, i);
    v.out8(0x3CF, x);
}
fn acW(i: u8, x: u8) void {
    _ = v.in8(0x3DA);
    v.out8(0x3C0, i);
    v.out8(0x3C0, x);
    v.out8(0x3C0, 0x20);
}
fn dacW(i: u8, r: u8, g: u8, b: u8) void {
    v.out8(0x3C8, i);
    v.out8(0x3C9, r);
    v.out8(0x3C9, g);
    v.out8(0x3C9, b);
}
fn render() vga_mod.Size {
    return v.render(&px, 720, .{ .w = 720, .h = 480 });
}
fn plane(pa: u32, p: u5) u8 {
    return @truncate(v.vram[pa] >> (p * 8));
}

test "vga: registers read back, the flip-flop, the DAC's three steps, protect" {
    v.reset();
    v.out8(0x3C2, 0x67);
    try t.expectEqual(@as(u8, 0x67), v.in8(0x3CC));
    seqW(2, 0x0A);
    try t.expectEqual(@as(u8, 0x0A), v.in8(0x3C5));
    crtcW(0x13, 0x28);
    try t.expectEqual(@as(u8, 0x28), v.in8(0x3D5));
    try t.expectEqual(@as(u8, 0xFF), v.in8(0x3B5)); // (colour: no mono CRTC)
    // Misc bit 0 clear: the CRTC answers at 3B4/3B5.
    v.out8(0x3C2, 0x66);
    v.out8(0x3B4, 0x13);
    try t.expectEqual(@as(u8, 0x28), v.in8(0x3B5));
    try t.expectEqual(@as(u8, 0xFF), v.in8(0x3D5));
    v.out8(0x3C2, 0x67);
    gcW(8, 0x55);
    try t.expectEqual(@as(u8, 0x55), v.in8(0x3CF));
    // The protect bit: 00h-07h locked, all but 07h's bit 4.
    crtcW(0x01, 0x4F);
    crtcW(0x11, 0x80);
    crtcW(0x01, 0x12);
    v.out8(0x3D4, 0x01);
    try t.expectEqual(@as(u8, 0x4F), v.in8(0x3D5));
    crtcW(0x07, 0xFF);
    v.out8(0x3D4, 0x07);
    try t.expectEqual(@as(u8, 0x10), v.in8(0x3D5));
    // The attribute controller: index, data, index ...; 3DA resets.
    _ = v.in8(0x3DA);
    v.out8(0x3C0, 0x05);
    v.out8(0x3C0, 0x2A);
    v.out8(0x3C0, 0x06);
    v.out8(0x3C0, 0x3B);
    v.out8(0x3C0, 0x25);
    try t.expectEqual(@as(u8, 0x25), v.in8(0x3C0));
    try t.expectEqual(@as(u8, 0x2A), v.in8(0x3C1));
    _ = v.in8(0x3DA);
    v.out8(0x3C0, 0x26);
    try t.expectEqual(@as(u8, 0x3B), v.in8(0x3C1));
    // The DAC: write index, R G B, auto-increment; 6 bits.
    v.out8(0x3C8, 10);
    for ([_]u8{ 1, 2, 3, 4, 5, 0xFF }) |c| v.out8(0x3C9, c);
    try t.expectEqual(@as(u8, 12), v.in8(0x3C8));
    v.out8(0x3C7, 10);
    try t.expectEqual(@as(u8, 3), v.in8(0x3C7));
    var got: [6]u8 = undefined;
    for (&got) |*g| g.* = v.in8(0x3C9);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 0x3F }, &got);
    try t.expectEqual(@as(u32, 0x04080C), v.dac_rgb[10]);
    try t.expectEqual(@as(u32, 0x1014FF), v.dac_rgb[11]);
}

test "vga: write modes 0-3, set/reset, rotate, function, bit mask, read mode 1" {
    boot();
    _ = int10(0x0012, 0, 0, 0);
    // Mode 0 with set/reset on every plane: planes 2-3 ones, 0-1 zeros,
    // only the bit mask's bits.
    gcW(0, 0x0C);
    gcW(1, 0x0F);
    gcW(8, 0xF0);
    _ = v.read(0);
    v.write(0, 0x00);
    try t.expectEqual(@as(u32, 0xF0F0_0000), v.vram[0]);
    // Mode 0, rotate 4 and XOR with the latches.
    gcW(1, 0x00);
    gcW(8, 0xFF);
    gcW(3, (3 << 3) | 4);
    _ = v.read(0);
    v.write(0, 0x0F);
    try t.expectEqual(@as(u32, 0x0000_F0F0), v.vram[0]);
    gcW(3, 0);
    // Mode 2: the value's low bits are the colour, the bit mask the pixels.
    gcW(5, 0x02);
    gcW(8, 0x81);
    _ = v.read(1);
    v.write(1, 0x05);
    try t.expectEqual(@as(u32, 0x0081_0081), v.vram[1]);
    // Mode 3: set/reset is the colour, the rotated value ANDs the mask.
    gcW(5, 0x03);
    gcW(0, 0x06);
    gcW(8, 0xFF);
    _ = v.read(2);
    v.write(2, 0x3C);
    try t.expectEqual(@as(u32, 0x003C_3C00), v.vram[2]);
    // The map mask: write mode 0, plain, plane 0 alone.
    gcW(5, 0x00);
    seqW(2, 0x01);
    v.write(3, 0xAA);
    try t.expectEqual(@as(u32, 0x0000_00AA), v.vram[3]);
    seqW(2, 0x0F);
    // Read mode 0 with the read map select, and read mode 1.
    v.vram[10] = 0x00F0_0FFF;
    gcW(4, 2);
    try t.expectEqual(@as(u8, 0xF0), v.read(10));
    gcW(5, 0x08);
    gcW(2, 0x03);
    gcW(7, 0x0F);
    try t.expectEqual(@as(u8, 0x0F), v.read(10));
    gcW(7, 0x01);
    try t.expectEqual(@as(u8, 0xFF), v.read(10));
    gcW(7, 0x00);
    try t.expectEqual(@as(u8, 0xFF), v.read(10));
}

test "vga: chain-4 and unchained addressing, latched copy" {
    boot();
    _ = int10(0x0013, 0, 0, 0);
    // Chain-4: address bits 0-1 pick the plane.
    v.write(5, 0x77);
    try t.expectEqual(@as(u8, 0x77), plane(4, 1));
    try t.expectEqual(@as(u8, 0x77), v.read(5));
    try t.expectEqual(@as(u8, 0), v.read(4));
    // Unchained: the map mask picks the planes, the address is the plane's.
    seqW(4, 0x06);
    seqW(2, 0x0F);
    v.write(5, 0x11);
    try t.expectEqual(@as(u32, 0x1111_1111), v.vram[5]);
    seqW(2, 0x04);
    v.write(6, 0x99);
    try t.expectEqual(@as(u32, 0x0099_0000), v.vram[6]);
    gcW(4, 2);
    try t.expectEqual(@as(u8, 0x99), v.read(6));
    // A latched copy: read loads all four planes, write mode 1 stores them.
    seqW(2, 0x0F);
    v.vram[100] = 0x4433_2211;
    _ = v.read(100);
    gcW(5, 0x41);
    v.write(200, 0x00);
    try t.expectEqual(@as(u32, 0x4433_2211), v.vram[200]);
    // The map mask still applies.
    seqW(2, 0x05);
    v.write(201, 0x00);
    try t.expectEqual(@as(u32, 0x0033_0011), v.vram[201]);
    gcW(5, 0x40);
    // Memory map select: mode 13h's window is A0000-AFFFF alone.
    try t.expectEqual(@as(u8, 0xFF), v.read(0x18000));
}

test "vga: mode 13h through the DAC, its mask, and mode X 320x240" {
    boot();
    _ = int10(0x0013, 0, 0, 0);
    dacW(1, 63, 0, 0);
    dacW(2, 0, 63, 0);
    v.write(0, 1);
    v.write(321, 2);
    v.write(199 * 320 + 319, 1);
    const s = render();
    try t.expectEqual(@as(u16, 320), s.w);
    try t.expectEqual(@as(u16, 200), s.h);
    try t.expectEqual(@as(u32, 0xFF0000), px[0] & 0xFFFFFF);
    try t.expectEqual(@as(u32, 0x00FF00), px[720 + 1]);
    try t.expectEqual(@as(u32, 0xFF0000), px[199 * 720 + 319]);
    try t.expectEqual(@as(u32, 0), px[2]);
    v.out8(0x3C6, 0x00);
    _ = render();
    try t.expectEqual(@as(u32, 0), px[0]);
    v.out8(0x3C6, 0xFF);

    // Mode X: unchained, 480 lines at 60 Hz, each row twice.
    seqW(4, 0x06);
    v.out8(0x3C2, 0xE3);
    crtcW(0x11, 0x0E);
    for ([_][2]u8{ .{ 0x06, 0x0D }, .{ 0x07, 0x3E }, .{ 0x09, 0x41 }, .{ 0x10, 0xEA }, .{ 0x11, 0xAC }, .{ 0x12, 0xDF }, .{ 0x14, 0x00 }, .{ 0x15, 0xE7 }, .{ 0x16, 0x06 }, .{ 0x17, 0xE3 } }) |p| crtcW(p[0], p[1]);
    seqW(2, 0x0F);
    var a: u32 = 0;
    while (a < 0x10000) : (a += 1) v.write(a, 0);
    // Pixel (x, y): plane x & 3, address y * 80 + x / 4.
    seqW(2, 1 << (5 & 3));
    v.write(239 * 80 + 5 / 4, 2);
    seqW(2, 1 << (318 & 3));
    v.write(0 * 80 + 318 / 4, 1);
    const sx = render();
    try t.expectEqual(@as(u16, 320), sx.w);
    try t.expectEqual(@as(u16, 240), sx.h);
    try t.expectEqual(@as(u32, 0x00FF00), px[239 * 720 + 5]);
    try t.expectEqual(@as(u32, 0xFF0000), px[318]);
    try t.expectEqual(@as(u32, 0), px[239 * 720 + 4]);
    const g = v.timing();
    const hz = 1_000_000_000_000 / g.frame_ns;
    try t.expect(hz >= 59_500 and hz <= 60_100);
}

test "vga: text mode shows a character with its attribute, blink and cursor" {
    boot();
    _ = int10(0x0941, 0x001E, 1, 0); // 'A', yellow on blue
    const s = render();
    try t.expectEqual(@as(u16, 720), s.w);
    try t.expectEqual(@as(u16, 400), s.h);
    const yellow: u32 = 0xFFFF55;
    const blue: u32 = 0x0000AA;
    var row: u32 = 0;
    while (row < 13) : (row += 1) {
        const bits = font.font16['A' * 16 + row];
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            const want = if (bits & (@as(u8, 0x80) >> @intCast(x)) != 0) yellow else blue;
            try t.expectEqual(want, px[row * 720 + x]);
        }
        try t.expectEqual(blue, px[row * 720 + 8]); // the ninth dot
    }
    // The cursor (rows 13-14 of the cell at 0,0) in the foreground.
    try t.expectEqual(yellow, px[13 * 720 + 3]);
    try t.expectEqual(yellow, px[14 * 720 + 3]);
    // Out of its blink phase it is gone.
    v.frames = 8;
    _ = render();
    try t.expectEqual(blue, px[14 * 720 + 3]);
    // Blinking characters: bit 7 is blink, the background loses bit 3.
    _ = int10(0x0942, 0x009E, 1, 0);
    v.frames = 0;
    _ = render();
    const bits_b = font.font16['B' * 16 + 4];
    const x_on: u32 = @clz(bits_b);
    try t.expectEqual(yellow, px[4 * 720 + x_on]);
    v.frames = 16;
    _ = render();
    try t.expectEqual(blue, px[4 * 720 + x_on]);
    // Blink off (AX=1003h BL=0): bit 7 is a bright background.
    _ = int10(0x1003, 0x0000, 0, 0);
    _ = render();
    try t.expectEqual(@as(u32, 0x5555FF), px[4 * 720 + 8]);
}

test "vga: start address scrolls, panning, line compare splits" {
    boot();
    _ = int10(0x0013, 0, 0, 0);
    var y: u32 = 0;
    while (y < 200) : (y += 1) {
        var x: u32 = 0;
        while (x < 320) : (x += 1) v.write(y * 320 + x, @intCast(y));
    }
    v.write(10 * 320 + 1, 77);
    // Start at row 10 (doubleword mode: 4 bytes an address).
    const st: u16 = 10 * 320 / 4;
    crtcW(0x0C, @intCast(st >> 8));
    crtcW(0x0D, @intCast(st & 0xFF));
    _ = render();
    try t.expectEqual(v.dac_rgb[10], px[0]);
    try t.expectEqual(v.dac_rgb[77], px[1]);
    try t.expectEqual(v.dac_rgb[11], px[720]);
    // Panning by one pixel (256 colours: the register's value / 2).
    acW(0x13, 2);
    _ = render();
    try t.expectEqual(v.dac_rgb[77], px[0]);
    // Line compare at scan line 199 (row 99 doubled): rows 100 on show
    // memory from address 0; with pixel panning mode, unpanned.
    crtcW(0x07, 0x0F); // (protected, but bit 4 goes through)
    crtcW(0x09, 0x01);
    crtcW(0x18, 199);
    acW(0x10, 0x41 | 0x20);
    _ = render();
    try t.expectEqual(v.dac_rgb[10 + 99], px[99 * 720 + 5]);
    try t.expectEqual(v.dac_rgb[0], px[100 * 720 + 5]);
    try t.expectEqual(v.dac_rgb[1], px[101 * 720 + 0]);
    try t.expectEqual(v.dac_rgb[77], px[0]);
    // The start address takes effect at the retrace, the frame's scroll
    // at its first line: once time runs, the render shows the frame on
    // show, not a start set since.
    crtcW(0x0C, 0);
    crtcW(0x0D, 0);
    var i: u32 = 0;
    while (i < 80) : (i += 1) v.advance(250);
    _ = render();
    try t.expectEqual(v.dac_rgb[0], px[5]);
    crtcW(0x0C, @intCast(st >> 8));
    crtcW(0x0D, @intCast(st & 0xFF));
    _ = render();
    try t.expectEqual(v.dac_rgb[0], px[5]);
    i = 0;
    while (i < 80) : (i += 1) v.advance(250);
    _ = render();
    try t.expectEqual(v.dac_rgb[10], px[5]);
}

test "vga: a page flip in mode X shows the whole page with its panning" {
    boot();
    _ = int10(0x0013, 0, 0, 0);
    seqW(4, 0x06);
    crtcW(0x14, 0x00);
    crtcW(0x17, 0xE3);
    seqW(2, 0x0F);
    // Page A (address 0) colour 1, page B (address 4000h) colour 2.
    var a: u32 = 0;
    while (a < 0x4000) : (a += 1) {
        v.write(a, 1);
        v.write(0x4000 + a, 2);
    }
    // (pixel 1 of page B: plane 1 at its first address)
    seqW(2, 0x02);
    v.write(0x4000, 5);
    seqW(2, 0x0F);
    // A frame of page A on show, then: the start to B during display,
    // the retrace, the panning in it.
    var i: u32 = 0;
    while (i < 80) : (i += 1) v.advance(250);
    while (v.in8(0x3DA) & 0x08 != 0) {}
    crtcW(0x0C, 0x40);
    crtcW(0x0D, 0x00);
    _ = v.frameDone();
    while (!v.frameDone()) v.advance(250);
    acW(0x13, 2);
    // Until the frame's first line the old frame is on show.
    _ = render();
    try t.expectEqual(v.dac_rgb[1], px[0]);
    i = 0;
    while (i < 8) : (i += 1) v.advance(250);
    // The game draws the hidden page A, and even scribbles on B: the
    // frame on show is B as it was, panned by its own panning.
    a = 0;
    while (a < 0x4000) : (a += 1) {
        v.write(a, 3);
        v.write(0x4000 + a, 4);
    }
    _ = render();
    try t.expectEqual(v.dac_rgb[5], px[0]);
    try t.expectEqual(v.dac_rgb[2], px[1]);
}

test "vga: retrace at 70 Hz in 400-line modes and 60 Hz in 480, seen by polling" {
    boot();
    var frames: u32 = 0;
    var edges: u32 = 0;
    var last: bool = false;
    var s: u32 = 0;
    while (s < 4000) : (s += 1) {
        v.advance(250);
        if (v.frameDone()) frames += 1;
        // A program waiting for retrace: many reads within the slice.
        var k: u32 = 0;
        while (k < 300) : (k += 1) {
            const on = v.in8(0x3DA) & 0x08 != 0;
            if (on and !last) edges += 1;
            last = on;
        }
    }
    try t.expect(frames >= 69 and frames <= 71);
    try t.expect(edges >= 69 and edges <= 71);
    // Display enable: blanking (bit 0) is seen within a line.
    v.advance(250);
    var blank: u32 = 0;
    var k: u32 = 0;
    while (k < 64) : (k += 1) blank += v.in8(0x3DA) & 1;
    try t.expect(blank > 0 and blank < 64);

    _ = int10(0x0012, 0, 0, 0);
    frames = 0;
    s = 0;
    while (s < 4000) : (s += 1) {
        v.advance(250);
        if (v.frameDone()) frames += 1;
    }
    try t.expect(frames >= 59 and frames <= 61);
}

test "video bios: set mode, teletype, scrolling, the BDA and info calls" {
    boot();
    try t.expectEqual(@as(u8, 0x03), mem.rdB(0x40, 0x49));
    try t.expectEqual(@as(u16, 80), mem.rdW(0x40, 0x4A));
    try t.expectEqual(@as(u8, 24), mem.rdB(0x40, 0x84));
    try t.expectEqual(@as(u16, 16), mem.rdW(0x40, 0x85));
    try t.expectEqual(@as(u16, 0x3D4), mem.rdW(0x40, 0x63));
    for ("Hi\r\nX") |c| _ = int10(0x0E00 | @as(u16, c), 0, 0, 0);
    try t.expectEqual(@as(u8, 'H'), plane(0, 0));
    try t.expectEqual(@as(u8, 0x07), plane(0, 1));
    try t.expectEqual(@as(u8, 'i'), plane(2, 0));
    try t.expectEqual(@as(u8, 'X'), plane(160, 0));
    try t.expectEqual(@as(u8, 1), mem.rdB(0x40, 0x50));
    try t.expectEqual(@as(u8, 1), mem.rdB(0x40, 0x51));
    try t.expectEqual(@as(u16, 81), v.cursorAddr());
    var r = int10(0x0300, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x0101), r.dx());
    try t.expectEqual(@as(u16, 0x0607), r.cx());
    // 24 line feeds: the screen scrolls, "Hi" goes, "X" is on row 0.
    var i: u32 = 0;
    while (i < 24) : (i += 1) _ = int10(0x0E0A, 0, 0, 0);
    try t.expectEqual(@as(u8, 24), mem.rdB(0x40, 0x51));
    try t.expectEqual(@as(u8, 'X'), plane(0, 0));
    try t.expectEqual(@as(u8, ' '), plane(160, 0));
    // Scroll a window down with an attribute (AH=07h).
    _ = int10(0x0701, 0x1F00, 0x0000, 0x0104);
    try t.expectEqual(@as(u8, ' '), plane(0, 0));
    try t.expectEqual(@as(u8, 0x1F), plane(0, 1));
    try t.expectEqual(@as(u8, 'X'), plane(160, 0));
    r = int10(0x0F00, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x5003), r.ax());
    // Write string with attributes (AH=13h, AL=3) at row 2.
    mem.copyIn(0x5000, &.{ 'O', 0x4E, 'K', 0x4E });
    var rs = regs.Regs{};
    rs.setAx(0x1303);
    rs.setBx(0);
    rs.setCx(2);
    rs.setDx(0x0200);
    rs.setSeg(regs.ES, 0x0500);
    rs.set16(regs.EBP, 0);
    vb.int10(&rs, &mem, &v);
    try t.expectEqual(@as(u8, 'K'), plane(2 * 160 + 2, 0));
    try t.expectEqual(@as(u8, 0x4E), plane(2 * 160 + 2, 1));
    try t.expectEqual(@as(u8, 2), mem.rdB(0x40, 0x50));
    // Information: display combination, EGA info, font pointers, VESA.
    r = int10(0x1A00, 0, 0, 0);
    try t.expectEqual(@as(u8, 0x1A), r.al());
    try t.expectEqual(@as(u16, 0x0008), r.bx());
    r = int10(0x1200, 0x0010, 0, 0);
    try t.expectEqual(@as(u16, 0x0003), r.bx());
    r = int10(0x1130, 0x0600, 0, 0);
    try t.expectEqual(vb.ROM_SEG, r.seg[regs.ES]);
    try t.expectEqual(vb.FONT16, r.bp());
    try t.expectEqual(@as(u16, 16), r.cx());
    try t.expectEqual(font.font16['A' * 16 + 5], mem.rd8(Memory.lin(vb.ROM_SEG, vb.FONT16) + 'A' * 16 + 5));
    r = int10(0x4F00, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x014F), r.ax());
    // The state (AH=1Bh): the static table's pointer, mode, columns.
    var rq = regs.Regs{};
    rq.setAx(0x1B00);
    rq.setSeg(regs.ES, 0x0700);
    rq.setDi(0);
    vb.int10(&rq, &mem, &v);
    try t.expectEqual(@as(u8, 0x1B), rq.al());
    try t.expectEqual(vb.STATIC_TABLE, mem.rdW(0x0700, 0));
    try t.expectEqual(vb.ROM_SEG, mem.rdW(0x0700, 2));
    try t.expectEqual(@as(u8, 3), mem.rdB(0x0700, 4));
    try t.expectEqual(@as(u16, 80), mem.rdW(0x0700, 5));
    try t.expectEqual(@as(u8, 25), mem.rdB(0x0700, 0x22));
    try t.expectEqual(@as(u8, 0xFF), mem.rdB(vb.ROM_SEG, vb.STATIC_TABLE));
    // 80x50: the 8x8 font (AX=1112h).
    _ = int10(0x1112, 0, 0, 0);
    try t.expectEqual(@as(u8, 49), mem.rdB(0x40, 0x84));
    try t.expectEqual(@as(u16, 8), mem.rdW(0x40, 0x85));
    try t.expectEqual(@as(u8, 7), v.crtc[9] & 0x1F);
    try t.expectEqual(@as(u8, font.font8['A' * 8 + 2]), plane(0x41 * 32 + 2, 2));

    // Mode 13h: memory cleared, the BDA, teletype draws pixels.
    _ = int10(0x0013, 0, 0, 0);
    try t.expectEqual(@as(u8, 0x13), mem.rdB(0x40, 0x49));
    r = int10(0x0F00, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x2813), r.ax());
    _ = int10(0x0E41, 0x000F, 0, 0);
    var lit: u32 = 0;
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            const off = y * 320 + x;
            if (plane(off & ~@as(u32, 3), @intCast(off & 3)) == 15) lit += 1;
        }
    }
    try t.expect(lit > 8);
    // Pixels: write and read back (AH=0Ch/0Dh).
    _ = int10(0x0C2A, 0, 100, 50);
    r = int10(0x0D00, 0, 100, 50);
    try t.expectEqual(@as(u8, 0x2A), r.al());
    // AH=08h reads the character back by its shape.
    _ = int10(0x0200, 0, 0, 0);
    r = int10(0x0800, 0, 0, 0);
    try t.expectEqual(@as(u8, 'A'), r.al());
    // Mode 12h's planar pixels.
    _ = int10(0x0012, 0, 0, 0);
    _ = int10(0x0C05, 0, 9, 3);
    r = int10(0x0D00, 0, 9, 3);
    try t.expectEqual(@as(u8, 5), r.al());
    try t.expectEqual(@as(u32, 0x0040_0040), v.vram[3 * 80 + 1]);
    // Bit 7: no clear.
    _ = int10(0x0092, 0, 0, 0);
    r = int10(0x0D00, 0, 9, 3);
    try t.expectEqual(@as(u8, 5), r.al());
    try t.expectEqual(@as(u8, 0x80), mem.rdB(0x40, 0x87) & 0x80);
    // DAC block set/get (AX=1012h/1017h).
    mem.copyIn(0x6000, &.{ 1, 2, 3, 4, 5, 6 });
    rs = regs.Regs{};
    rs.setAx(0x1012);
    rs.setBx(0x20);
    rs.setCx(2);
    rs.setDx(0);
    rs.setSeg(regs.ES, 0x0600);
    vb.int10(&rs, &mem, &v);
    try t.expectEqual(@as(u8, 6), v.dac[0x21][2]);
    rs.setAx(0x1017);
    rs.setDx(0x0010);
    vb.int10(&rs, &mem, &v);
    try t.expectEqual(@as(u8, 4), mem.rd8(0x6013));
}

test "vga: CGA, EGA and VGA planar modes and 40-column text render" {
    boot();
    _ = int10(0x0004, 0, 0, 0);
    _ = int10(0x0C03, 0, 1, 1);
    _ = int10(0x0C01, 0, 2, 0);
    var s = render();
    try t.expectEqual(@as(u16, 320), s.w);
    try t.expectEqual(@as(u16, 200), s.h);
    try t.expectEqual(@as(u32, 0xFFFFFF), px[720 + 1]);
    try t.expectEqual(@as(u32, 0x55FFFF), px[2]);
    try t.expectEqual(@as(u32, 0), px[0]);
    // The odd scan lines live 8 KiB up (CPU B8000 + 2000h + row * 80).
    try t.expectEqual(@as(u8, 0x30), plane(0x2000, 0));

    _ = int10(0x0006, 0, 0, 0);
    _ = int10(0x0C01, 0, 639, 199);
    s = render();
    try t.expectEqual(@as(u16, 640), s.w);
    try t.expectEqual(@as(u16, 200), s.h);
    try t.expectEqual(@as(u32, 0xFFFFFF), px[199 * 720 + 639]);
    try t.expectEqual(@as(u32, 0), px[199 * 720 + 638]);

    _ = int10(0x000D, 0, 0, 0);
    _ = int10(0x0C0C, 0, 319, 199);
    s = render();
    try t.expectEqual(@as(u16, 320), s.w);
    try t.expectEqual(@as(u16, 200), s.h);
    try t.expectEqual(@as(u32, 0xFF5555), px[199 * 720 + 319]);

    _ = int10(0x0012, 0, 0, 0);
    _ = int10(0x0C0E, 0, 639, 479);
    _ = int10(0x0C06, 0, 0, 0);
    s = render();
    try t.expectEqual(@as(u16, 640), s.w);
    try t.expectEqual(@as(u16, 480), s.h);
    try t.expectEqual(@as(u32, 0xFFFF55), px[479 * 720 + 639]);
    try t.expectEqual(@as(u32, 0xAA5500), px[0]);

    _ = int10(0x0001, 0, 0, 0);
    _ = int10(0x0941, 0x0007, 1, 0);
    s = render();
    try t.expectEqual(@as(u16, 360), s.w);
    try t.expectEqual(@as(u16, 400), s.h);
}

fn monoNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "vga: a frame of mode 13h and of mode X renders fast" {
    boot();
    _ = int10(0x0013, 0, 0, 0);
    var a: u32 = 0;
    while (a < 64000) : (a += 1) v.write(a, @truncate(a * 7));
    const n = 200;
    var i: u32 = 0;
    const t0 = monoNs();
    while (i < n) : (i += 1) _ = render();
    const t1 = monoNs();
    seqW(4, 0x06);
    crtcW(0x14, 0x00);
    crtcW(0x17, 0xE3);
    i = 0;
    while (i < n) : (i += 1) _ = render();
    const t2 = monoNs();
    _ = int10(0x0003, 0, 0, 0);
    i = 0;
    while (i < n) : (i += 1) _ = render();
    const t3 = monoNs();
    std.debug.print("vga render: mode 13h {d} us, mode X {d} us, text 80x25 {d} us a frame\n", .{ (t1 - t0) / n / 1000, (t2 - t1) / n / 1000, (t3 - t2) / n / 1000 });
    if (builtin.mode != .debug) try t.expect((t1 - t0) / n < 1_000_000);
}
