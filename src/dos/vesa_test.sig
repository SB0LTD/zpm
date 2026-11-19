//! VESA (vesa.sig, vesa_bios.sig): the controller and mode info blocks,
//! mode sets, window A through int 10h and the far window function, the
//! linear frame buffer on the bus, scan line length and display start,
//! the DAC's width and palette data, save/restore, and exact pixels of
//! 8, 15, 16, 24 and 32-bit modes; then back to the VGA.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const machine = @import("machine.sig");
const TestHost = @import("test_host.sig").TestHost;
const regs = @import("regs.sig");
const vesa = @import("vesa.sig");
const vb = @import("vesa_bios.sig");
const Memory = @import("mem.sig").Memory;

var m: machine.Machine = .{};
var th: TestHost = .{};
var px: [1280 * 1024]u32 = undefined;

fn boot() void {
    th = .{};
    m.init(th.host(), "");
    // (as a DOS extender has it: the LFB's addresses have bit 20 set)
    m.mem.a20 = true;
}

/// int 10h through the machine's service (the CPU's registers).
fn call(ax: u16, bx: u16, cx: u16, dx: u16) *regs.Regs {
    const r = &m.cpu.regs;
    r.setAx(ax);
    r.setBx(bx);
    r.setCx(cx);
    r.setDx(dx);
    r.setSeg(regs.ES, 0x2000);
    r.setDi(0);
    r.setSeg(regs.SS, 0x3000);
    r.set16(regs.ESP, 0x0100);
    _ = m.hle(&m.cpu, 0x10);
    return r;
}

const BUF: u32 = 0x20000;

fn rd16(a: u32) u16 {
    return m.mem.rd16(a);
}
fn rd32(a: u32) u32 {
    return m.mem.rd32(a);
}

fn frame() machine.Size {
    return m.frame(&px, 1280, .{ .w = 1280, .h = 1024 });
}

test "vesa: 4F00 answers VBE 2.0, with the 2.0 fields only when asked with VBE2" {
    boot();
    // A VBE 1.x caller: 256 bytes, the rest of its buffer untouched.
    @memset(m.mem.ram[BUF..][0..512], 0xEE);
    var r = call(0x4F00, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expectEqualStrings("VESA", m.mem.ram[BUF..][0..4]);
    try t.expectEqual(@as(u16, 0x0200), rd16(BUF + 4));
    try t.expectEqual(@as(u32, 1), rd32(BUF + 10) & 1); // DAC to 8 bits
    try t.expectEqual(@as(u16, 64), rd16(BUF + 18)); // 4 MiB
    try t.expectEqual(@as(u8, 0xEE), m.mem.ram[BUF + 256]);
    // The OEM string and the mode list (far pointers into the ROM).
    const oem = Memory.lin(rd16(BUF + 8), rd16(BUF + 6));
    var sb: [40]u8 = undefined;
    try t.expect(std.mem.startsWith(u8, m.mem.cstr(oem, &sb), "zpm dos SVGA"));
    var list = Memory.lin(rd16(BUF + 16), rd16(BUF + 14));
    var n: u32 = 0;
    var has101 = false;
    var has141 = false;
    while (rd16(list) != 0xFFFF and n < 100) : (list += 2) {
        if (rd16(list) == 0x101) has101 = true;
        if (rd16(list) == 0x141) has141 = true;
        n += 1;
    }
    try t.expect(has101 and has141);
    try t.expectEqual(@as(u32, vesa.modes.len), n);

    // "VBE2": 512 bytes with the OEM fields.
    @memset(m.mem.ram[BUF..][0..512], 0xEE);
    @memcpy(m.mem.ram[BUF..][0..4], "VBE2");
    r = call(0x4F00, 0, 0, 0);
    try t.expectEqualStrings("VESA", m.mem.ram[BUF..][0..4]);
    try t.expectEqual(@as(u8, 0x00), m.mem.ram[BUF + 300]);
    const vendor = Memory.lin(rd16(BUF + 24), rd16(BUF + 22));
    try t.expectEqualStrings("zpm", m.mem.cstr(vendor, &sb));
    const product = Memory.lin(rd16(BUF + 28), rd16(BUF + 26));
    try t.expect(std.mem.startsWith(u8, m.mem.cstr(product, &sb), "Sig SVGA"));
}

test "vesa: 4F01's mode info for 8, 16 and 32-bit modes" {
    boot();
    var r = call(0x4F01, 0, 0x101, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expectEqual(@as(u16, 0x9B), rd16(BUF)); // supported, colour, graphics, LFB
    try t.expectEqual(@as(u8, 0x07), m.mem.ram[BUF + 2]);
    try t.expectEqual(@as(u8, 0x00), m.mem.ram[BUF + 3]);
    try t.expectEqual(@as(u16, 64), rd16(BUF + 4));
    try t.expectEqual(@as(u16, 64), rd16(BUF + 6));
    try t.expectEqual(@as(u16, 0xA000), rd16(BUF + 8));
    try t.expectEqual(@as(u32, 0xC000_0000 | @as(u32, vb.WIN_FUNC)), rd32(BUF + 12));
    try t.expectEqual(@as(u16, 640), rd16(BUF + 16));
    try t.expectEqual(@as(u16, 640), rd16(BUF + 18));
    try t.expectEqual(@as(u16, 480), rd16(BUF + 20));
    try t.expectEqual(@as(u8, 8), m.mem.ram[BUF + 25]);
    try t.expectEqual(@as(u8, 4), m.mem.ram[BUF + 27]); // packed pixel
    try t.expectEqual(@as(u8, 12), m.mem.ram[BUF + 29]); // 13 pages
    try t.expectEqual(vesa.LFB_BASE, rd32(BUF + 40));
    try t.expectEqual(@as(u16, 640), rd16(BUF + 50));

    r = call(0x4F01, 0, 0x111, 0);
    try t.expectEqual(@as(u16, 1280), rd16(BUF + 16));
    try t.expectEqual(@as(u8, 16), m.mem.ram[BUF + 25]);
    try t.expectEqual(@as(u8, 6), m.mem.ram[BUF + 27]); // direct colour
    try t.expectEqualSlices(u8, &.{ 5, 11, 6, 5, 5, 0, 0, 0 }, m.mem.ram[BUF + 31 ..][0..8]);

    r = call(0x4F01, 0, 0x141, 0);
    try t.expectEqual(@as(u16, 2560), rd16(BUF + 16));
    try t.expectEqual(@as(u8, 32), m.mem.ram[BUF + 25]);
    try t.expectEqualSlices(u8, &.{ 8, 16, 8, 8, 8, 0, 8, 24 }, m.mem.ram[BUF + 31 ..][0..8]);

    // No such mode.
    r = call(0x4F01, 0, 0x1FF, 0);
    try t.expectEqual(@as(u16, 0x014F), r.ax());
}

/// A real-mode program at 1000:0000 run until it parks at its JMP $.
fn runCode(code: []const u8) void {
    m.mem.copyIn(0x10000, code);
    const r = &m.cpu.regs;
    r.setSeg(regs.CS, 0x1000);
    r.eip = 0;
    r.setSeg(regs.SS, 0x3000);
    r.set16(regs.ESP, 0x0200);
    r.setSeg(regs.DS, 0x1000);
    _ = m.run(2000);
}

test "vesa: 101h, banked writes through A000 by 4F05 and the far window function" {
    boot();
    const code = [_]u8{
        0xB8, 0x02, 0x4F, // mov ax,4F02h
        0xBB, 0x01, 0x01, // mov bx,0101h
        0xCD, 0x10, // int 10h
        0xB8, 0x00, 0xA0, // mov ax,A000h
        0x8E, 0xC0, // mov es,ax
        0x26, 0xC6, 0x06, 0x00, 0x00, 0x11, // mov byte [es:0],11h
        0xB8, 0x05, 0x4F, // mov ax,4F05h
        0x31, 0xDB, // xor bx,bx
        0xBA, 0x01, 0x00, // mov dx,1
        0xCD, 0x10, // int 10h
        0x26, 0xC6, 0x06, 0x00, 0x00, 0x22, // mov byte [es:0],22h
        0x31, 0xDB, // xor bx,bx
        0xBA, 0x02, 0x00, // mov dx,2
        0xB8, 0x34, 0x12, // mov ax,1234h
        0x2E, 0xFF, 0x1E, 0x80, 0x00, // call far [cs:0080h]
        0x26, 0xC7, 0x06, 0x10, 0x00, 0x44, 0x33, // mov word [es:10h],3344h
        0x66, 0x26, 0xC7, 0x06, 0xFC, 0xFF, 0x78, 0x56, 0x34, 0x12, // mov dword [es:FFFCh],12345678h
        0xA3, 0x90, 0x00, // mov [0090h],ax
        0xEB, 0xFE, // jmp $
    };
    var prog: [0xA0]u8 = @splat(0x90);
    @memcpy(prog[0..code.len], &code);
    std.mem.writeInt(u32, prog[0x80..0x84], 0xC000_0000 | @as(u32, vb.WIN_FUNC), .little);
    runCode(&prog);
    const s = &m.vga.svga;
    try t.expect(s.active);
    try t.expectEqual(@as(u16, 640), s.w);
    try t.expectEqual(@as(u8, 0x11), s.mem[0]);
    try t.expectEqual(@as(u8, 0x22), s.mem[0x10000]);
    try t.expectEqual(@as(u8, 0x44), s.mem[0x20010]);
    try t.expectEqual(@as(u8, 0x33), s.mem[0x20011]);
    try t.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, s.mem[0x2FFFC..][0..4], .little));
    // The far call kept AX.
    try t.expectEqual(@as(u16, 0x1234), m.mem.rd16(0x10090));
    // 4F05 BH=01h reads the window's position back; window B is none.
    var r = call(0x4F05, 0x0100, 0, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expectEqual(@as(u16, 2), r.dx());
    r = call(0x4F05, 0x0001, 0, 0);
    try t.expectEqual(@as(u16, 0x014F), r.ax());
    // Reads through the window, and 4F03.
    try t.expectEqual(@as(u8, 0x44), m.rd8(0xA0010));
    try t.expectEqual(@as(u16, 0x3344), m.rd16(0xA0010));
    r = call(0x4F03, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x0101), r.bx());
}

test "vesa: the linear frame buffer on the bus, 4F02's LFB and keep bits" {
    boot();
    var r = call(0x4F02, 0x4101, 0, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    const s = &m.vga.svga;
    try t.expect(s.linear);
    m.wr8(vesa.LFB_BASE + 5, 0xA5);
    m.wr16(vesa.LFB_BASE + 640 * 479 + 638, 0xBEEF);
    m.wr32(vesa.LFB_BASE + 0x3FFFFC, 0xCAFEF00D);
    try t.expectEqual(@as(u8, 0xA5), s.mem[5]);
    try t.expectEqual(@as(u16, 0xBEEF), m.rd16(vesa.LFB_BASE + 640 * 479 + 638));
    try t.expectEqual(@as(u32, 0xCAFEF00D), m.rd32(vesa.LFB_BASE + 0x3FFFFC));
    // (straddling the end: the last byte is memory, the next is nothing)
    try t.expectEqual(@as(u16, 0xFFCA), m.rd16(vesa.LFB_BASE + 0x3FFFFF));
    try t.expectEqual(@as(u8, 0xFF), m.rd8(vesa.LFB_BASE + vesa.VRAM));
    try t.expectEqual(@as(u8, 0xFF), m.rd8(0x0100_0000)); // past the RAM
    // The same memory through window A.
    try t.expectEqual(@as(u8, 0xA5), m.rd8(0xA0005));
    r = call(0x4F03, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x4101), r.bx());
    // Bit 15: the memory stays; without it, cleared.
    r = call(0x4F02, 0xC101, 0, 0);
    try t.expectEqual(@as(u8, 0xA5), s.mem[5]);
    r = call(0x4F03, 0, 0, 0);
    try t.expectEqual(@as(u16, 0xC101), r.bx());
    r = call(0x4F02, 0x0101, 0, 0);
    try t.expectEqual(@as(u8, 0x00), s.mem[5]);
    // A mode that is not there.
    r = call(0x4F02, 0x01FE, 0, 0);
    try t.expectEqual(@as(u16, 0x014F), r.ax());
}

test "vesa: 4F06 scan line length and 4F07 display start show in the picture" {
    boot();
    _ = call(0x4F02, 0x4101, 0, 0);
    const s = &m.vga.svga;
    var r = call(0x4F06, 0x0000, 1024, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expectEqual(@as(u16, 1024), r.bx());
    try t.expectEqual(@as(u16, 1024), r.cx());
    try t.expectEqual(@as(u16, 4096), r.dx());
    r = call(0x4F06, 0x0002, 2048, 0);
    try t.expectEqual(@as(u16, 2048), r.bx());
    r = call(0x4F06, 0x0001, 0, 0);
    try t.expectEqual(@as(u16, 2048), r.bx());
    r = call(0x4F06, 0x0003, 0, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expectEqual(@as(u16, vesa.VRAM / 480), r.bx());
    // Too long for the memory.
    r = call(0x4F06, 0x0002, 0xFFFF, 0);
    try t.expectEqual(@as(u16, 0x024F), r.ax());
    try t.expectEqual(@as(u32, 2048), s.pitch);

    // Line y at y*2048: colour 1 at (0,0) of the picture from line 10,
    // pixel 8; colour 2 at its (3,1).
    _ = call(0x4F06, 0x0000, 1024, 0);
    m.wr8(vesa.LFB_BASE + 10 * 1024 + 8, 1);
    m.wr8(vesa.LFB_BASE + 11 * 1024 + 11, 2);
    r = call(0x4F07, 0x0000, 8, 10);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    r = call(0x4F07, 0x0001, 0, 0);
    try t.expectEqual(@as(u16, 8), r.cx());
    try t.expectEqual(@as(u16, 10), r.dx());
    const sz = frame();
    try t.expectEqual(@as(u16, 640), sz.w);
    try t.expectEqual(@as(u16, 480), sz.h);
    try t.expectEqual(m.vga.dac_rgb[1], px[0]);
    try t.expectEqual(m.vga.dac_rgb[2], px[1280 + 3]);
    try t.expectEqual(m.vga.dac_rgb[0], px[1]);
    // During retrace (80h), and VBE 3.0's byte address (02h).
    r = call(0x4F07, 0x0080, 0, 11);
    try t.expectEqual(@as(u32, 11 * 1024), s.start);
    m.cpu.regs.r[regs.ECX] = 12345;
    r = call(0x4F07, 0x0002, @truncate(12345), 0);
    try t.expectEqual(@as(u32, 12345), s.start);
}

test "vesa: 4F08 DAC width and 4F09 palette data through the picture" {
    boot();
    _ = call(0x4F02, 0x0101, 0, 0);
    m.wr8(vesa.LFB_BASE, 5);
    // 6 bits: 4F09 takes 6-bit components (blue, green, red, 0).
    @memcpy(m.mem.ram[BUF..][0..4], &[_]u8{ 0x00, 0x20, 0x3F, 0 });
    var r = call(0x4F09, 0x0000, 1, 5);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    _ = frame();
    try t.expectEqual(@as(u32, 0xFF8200), px[0]);
    // 8 bits.
    r = call(0x4F08, 0x0800, 0, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expectEqual(@as(u8, 8), r.bh());
    r = call(0x4F08, 0x0001, 0, 0);
    try t.expectEqual(@as(u8, 8), r.bh());
    // (the colour stays as it looked)
    _ = frame();
    try t.expectEqual(@as(u32, 0xFF8200), px[0]);
    @memcpy(m.mem.ram[BUF..][0..8], &[_]u8{ 0x10, 0x80, 0xFF, 0, 0x01, 0x02, 0x03, 0 });
    r = call(0x4F09, 0x0000, 2, 5);
    _ = frame();
    try t.expectEqual(@as(u32, 0xFF8010), px[0]);
    // The port side is 8 bits too.
    m.out8(0x3C7, 6);
    try t.expectEqual(@as(u8, 0x03), m.in8(0x3C9));
    // Read back.
    @memset(m.mem.ram[BUF..][0..8], 0);
    r = call(0x4F09, 0x0001, 2, 5);
    try t.expectEqualSlices(u8, &.{ 0x10, 0x80, 0xFF, 0, 0x01, 0x02, 0x03, 0 }, m.mem.ram[BUF..][0..8]);
    // Secondary: kept apart from the picture.
    @memcpy(m.mem.ram[BUF..][0..4], &[_]u8{ 1, 2, 3, 4 });
    r = call(0x4F09, 0x0002, 1, 7);
    @memset(m.mem.ram[BUF..][0..4], 0);
    r = call(0x4F09, 0x0003, 1, 7);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, m.mem.ram[BUF..][0..4]);
    // Past the 256 entries.
    r = call(0x4F09, 0x0000, 2, 255);
    try t.expectEqual(@as(u16, 0x014F), r.ax());
    // A mode set: 6 bits again.
    _ = call(0x4F02, 0x0101, 0, 0);
    r = call(0x4F08, 0x0001, 0, 0);
    try t.expectEqual(@as(u8, 6), r.bh());
}

test "vesa: 15, 16, 24 and 32-bit modes' exact pixels" {
    boot();
    const s = &m.vga.svga;
    // 16 bits, 5:6:5.
    _ = call(0x4F02, 0x4111, 0, 0);
    m.wr16(vesa.LFB_BASE + 0, 0xF800);
    m.wr16(vesa.LFB_BASE + 2, 0x07E0);
    m.wr16(vesa.LFB_BASE + 4, 0x001F);
    m.wr16(vesa.LFB_BASE + 1280 * 2 + 6, 0x8410);
    var sz = frame();
    try t.expectEqual(@as(u16, 640), sz.w);
    try t.expectEqual(@as(u32, 0xFF0000), px[0]);
    try t.expectEqual(@as(u32, 0x00FF00), px[1]);
    try t.expectEqual(@as(u32, 0x0000FF), px[2]);
    try t.expectEqual(@as(u32, 0x848284), px[2 * 1280 + 3]);
    // 15 bits, 1:5:5:5.
    _ = call(0x4F02, 0x4110, 0, 0);
    m.wr16(vesa.LFB_BASE + 0, 0x7C00);
    m.wr16(vesa.LFB_BASE + 2, 0x03E0);
    m.wr16(vesa.LFB_BASE + 4, 0x801F);
    _ = frame();
    try t.expectEqual(@as(u32, 0xFF0000), px[0]);
    try t.expectEqual(@as(u32, 0x00FF00), px[1]);
    try t.expectEqual(@as(u32, 0x0000FF), px[2]);
    // 24 bits, B G R.
    _ = call(0x4F02, 0x4112, 0, 0);
    try t.expectEqual(@as(u32, 1920), s.pitch);
    m.wr8(vesa.LFB_BASE + 1920 + 9, 0x33);
    m.wr8(vesa.LFB_BASE + 1920 + 10, 0x22);
    m.wr8(vesa.LFB_BASE + 1920 + 11, 0x11);
    _ = frame();
    try t.expectEqual(@as(u32, 0x112233), px[1280 + 3]);
    // 32 bits, B G R X: the top byte is not colour.
    _ = call(0x4F02, 0x4141, 0, 0);
    m.wr32(vesa.LFB_BASE + 2 * 2560 + 3 * 4, 0x99AABBCC);
    sz = frame();
    try t.expectEqual(@as(u16, 480), sz.h);
    try t.expectEqual(@as(u32, 0xAABBCC), px[2 * 1280 + 3]);
    // The largest: 1280x1024 at 16 bits, clipped to what the host asks.
    _ = call(0x4F02, 0x411A, 0, 0);
    sz = frame();
    try t.expectEqual(@as(u16, 1280), sz.w);
    try t.expectEqual(@as(u16, 1024), sz.h);
    sz = m.frame(&px, 800, .{ .w = 800, .h = 600 });
    try t.expectEqual(@as(u16, 800), sz.w);
    try t.expectEqual(@as(u16, 600), sz.h);
}

test "vesa: 4F04 saves and restores the state" {
    boot();
    _ = call(0x4F02, 0x4101, 0, 0);
    _ = call(0x4F07, 0x0000, 0, 7);
    m.vga.setDac(9, 1, 2, 3);
    var r = call(0x4F04, 0, 0x000F, 0x0000);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    const blocks = r.bx();
    try t.expectEqual(@as(u16, 17), blocks);
    r = call(0x4F04, 0x0000, 0x000F, 0x0001);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    // Something else, then back.
    _ = call(0x0003, 0, 0, 0);
    try t.expect(!m.vga.svga.active);
    r = call(0x4F04, 0x0000, 0x000F, 0x0002);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expect(m.vga.svga.active);
    try t.expectEqual(@as(u16, 0x101), m.vga.svga.mode);
    try t.expectEqual(@as(u32, 7 * 640), m.vga.svga.start);
    try t.expectEqual(@as([3]u8, .{ 1, 2, 3 }), m.vga.dac[9]);
    try t.expectEqual(@as(u8, 0x13), m.mem.rdB(0x40, 0x49));
}

test "vesa: back to text mode 3 and the VGA's picture and window" {
    boot();
    _ = call(0x4F02, 0x0101, 0, 0);
    m.wr8(0xA0000, 0x5A);
    try t.expectEqual(@as(u8, 0x5A), m.vga.svga.mem[0]);
    // int 10h AH=00h.
    _ = call(0x0003, 0, 0, 0);
    try t.expect(!m.vga.svga.active);
    var sz = frame();
    try t.expectEqual(@as(u16, 720), sz.w);
    try t.expectEqual(@as(u16, 400), sz.h);
    // A0000 is the VGA's again (mode 3: B8000 is its text).
    m.wr8(0xB8000, 'A');
    try t.expectEqual(@as(u8, 'A'), @as(u8, @truncate(m.vga.vram[0])));
    // Through 4F02, to mode 13h.
    _ = call(0x4F02, 0x0101, 0, 0);
    const r = call(0x4F02, 0x0013, 0, 0);
    try t.expectEqual(@as(u16, 0x004F), r.ax());
    try t.expect(!m.vga.svga.active);
    sz = frame();
    try t.expectEqual(@as(u16, 320), sz.w);
    try t.expectEqual(@as(u16, 200), sz.h);
    m.wr8(0xA0000 + 1, 4);
    _ = m.frame(&px, 1280, .{ .w = 1280, .h = 1024 });
    try t.expectEqual(m.vga.dac_rgb[4], px[1]);
    // 4F03 says 13h; window calls are not for VGA modes.
    var r2 = call(0x4F03, 0, 0, 0);
    try t.expectEqual(@as(u16, 0x0013), r2.bx());
    r2 = call(0x4F05, 0, 0, 1);
    try t.expectEqual(@as(u16, 0x034F), r2.ax());
}

fn monoNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "vesa: a 1280x1024 frame at 8, 16 and 32 bits renders fast" {
    boot();
    const modes = [_]u16{ 0x107, 0x11A, 0x143 };
    var us: [3]u64 = undefined;
    for (modes, 0..) |mode, k| {
        _ = call(0x4F02, 0x4000 | mode, 0, 0);
        for (m.vga.svga.mem[0..0x200000], 0..) |*b, i| b.* = @truncate(i * 7);
        const n = 20;
        const t0 = monoNs();
        var i: u32 = 0;
        while (i < n) : (i += 1) _ = frame();
        us[k] = (monoNs() - t0) / n / 1000;
    }
    std.debug.print("vesa render: 1280x1024x8 {d} us, 1280x1024x16 {d} us, 1024x768x32 {d} us a frame\n", .{ us[0], us[1], us[2] });
    if (builtin.mode != .debug) try t.expect(us[0] < 20_000);
}
