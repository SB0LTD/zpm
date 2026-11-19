//! DOS on its own: a Regs, a static Memory, the test host; no machine.

const std = @import("std");
const t = std.testing;
const dos = @import("dos21.sig");
const bios = @import("bios.sig");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const TestHost = @import("test_host.sig").TestHost;
const mcb = @import("dos_mem.sig");
const S = @import("dos_state.sig");

var mem: Memory = .{};
var th: TestHost = .{};
var st: dos.State = .{};
var bst: bios.State = .{};

fn boot() void {
    mem.clear();
    th = .{};
    st.reset();
    bst.reset();
    bios.boot(&bst, &mem, 640, 15 * 1024);
    dos.boot(&st, &mem, th.host(), "", 0x0070, 0x9FFF);
}

fn call(r: *Regs, ax: u16) bool {
    r.setAx(ax);
    return dos.int21(&st, r, &mem, th.host());
}

/// A string at seg:off (NUL-terminated), DS:DX pointing at it.
fn strAt(r: *Regs, seg: u16, off: u16, s: []const u8) void {
    mem.copyIn(Memory.lin(seg, off), s);
    mem.wr8(Memory.lin(seg, off) + @as(u32, @intCast(s.len)), 0);
    r.setSeg(regs.DS, seg);
    r.setDx(off);
}

/// A COM program that is just a RET, started; its PSP.
fn startCom(r: *Regs) u16 {
    th.put("prog.com", &.{0xC3});
    try_start(r, "C:\\PROG.COM", "");
    return st.psp;
}
fn try_start(r: *Regs, p: []const u8, tail: []const u8) void {
    if (dos.start(&st, r, &mem, th.host(), p, tail)) |e| std.debug.panic("start failed: {d}", .{e});
}

/// A small MZ: a 32-byte header (one relocation), 32 bytes of image with
/// a word at 10h to relocate, 256 paragraphs of extra memory.
fn tinyMz(buf: *[64]u8) []const u8 {
    @memset(buf, 0);
    const w = struct {
        fn f(b: *[64]u8, at: usize, v: u16) void {
            std.mem.writeInt(u16, b[at..][0..2], v, .little);
        }
    }.f;
    w(buf, 0x00, 0x5A4D);
    w(buf, 0x02, 64); // bytes in the last page
    w(buf, 0x04, 1); // pages
    w(buf, 0x06, 1); // relocations
    w(buf, 0x08, 2); // header paragraphs
    w(buf, 0x0A, 0x100); // min extra
    w(buf, 0x0C, 0xFFFF); // max extra
    w(buf, 0x0E, 0x0002); // SS
    w(buf, 0x10, 0x0100); // SP
    w(buf, 0x14, 0x0004); // IP
    w(buf, 0x16, 0x0000); // CS
    w(buf, 0x18, 0x001C); // the relocation table
    w(buf, 0x1C, 0x0010); // relocation: 0000:0010
    w(buf, 0x1E, 0x0000);
    w(buf, 0x20 + 0x10, 0x0001); // the word to relocate
    buf[0x20] = 0xB8; // (mov ax, ...; it never runs here)
    return buf;
}

test "dos: boot leaves a chain, a shell and DOS's tables" {
    boot();
    try t.expectEqual(@as(u8, 'M'), mem.rdB(0x0070, 0));
    try t.expectEqual(@as(u16, 8), mem.rdW(0x0070, 1));
    // The chain ends with a 'Z' at 9FFF's end.
    var m: u16 = 0x0070;
    var n: u32 = 0;
    while (mem.rdB(m, 0) == 'M') : (n += 1) m = m + mem.rdW(m, 3) + 1;
    try t.expectEqual(@as(u8, 'Z'), mem.rdB(m, 0));
    try t.expectEqual(@as(u16, 0xA000), m + mem.rdW(m, 3) + 1);
    try t.expect(n >= 3);
    var r = Regs{};
    // The list of lists: the first MCB at ES:BX-2, NUL at +22h.
    _ = call(&r, 0x5200);
    const lol = Memory.lin(r.seg[regs.ES], r.bx());
    try t.expectEqual(@as(u16, 0x0070), mem.rd16(lol - 2));
    try t.expectEqualStrings("NUL     ", mem.ram[lol + 0x22 + 10 ..][0..8]);
    // Version 5.0, the current drive C:.
    _ = call(&r, 0x3000);
    try t.expectEqual(@as(u16, 0x0005), r.ax());
    _ = call(&r, 0x1900);
    try t.expectEqual(@as(u8, 2), r.al());
    // XMS through int 2Fh.
    r.setAx(0x4300);
    dos.int2f(&st, &r, &mem);
    try t.expectEqual(@as(u8, 0x80), r.al());
    r.setAx(0x4310);
    dos.int2f(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0xF000), r.seg[regs.ES]);
    try t.expectEqual(@as(u16, 0x0F00), r.bx());
    r.setAx(0x1687);
    dos.int2f(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0x1687), r.ax());
}

test "dos: memory blocks: allocate, resize, free" {
    boot();
    var r = Regs{};
    _ = startCom(&r);
    // The COM program has all memory: shrink it first.
    r.setSeg(regs.ES, st.psp);
    r.setBx(0x1000);
    _ = call(&r, 0x4A00);
    try t.expect(!r.flag(regs.CF));
    r.setBx(0xFFFF);
    _ = call(&r, 0x4800);
    try t.expect(r.flag(regs.CF));
    try t.expectEqual(@as(u16, 8), r.ax());
    const big = r.bx();
    try t.expect(big > 0x7000);
    r.setBx(0x100);
    _ = call(&r, 0x4800);
    try t.expect(!r.flag(regs.CF));
    const a = r.ax();
    r.setBx(0x10);
    _ = call(&r, 0x4800);
    const b = r.ax();
    try t.expectEqual(a + 0x101, b);
    try t.expectEqual(st.psp, mem.rdW(a - 1, 1));
    // A can't grow past B; it shrinks; B freed, A grows.
    r.setSeg(regs.ES, a);
    r.setBx(0x200);
    _ = call(&r, 0x4A00);
    try t.expect(r.flag(regs.CF));
    try t.expectEqual(@as(u16, 0x100), r.bx());
    r.setSeg(regs.ES, b);
    _ = call(&r, 0x4900);
    try t.expect(!r.flag(regs.CF));
    r.setSeg(regs.ES, a);
    r.setBx(0x200);
    _ = call(&r, 0x4A00);
    try t.expect(!r.flag(regs.CF));
    r.setSeg(regs.ES, a);
    _ = call(&r, 0x4900);
    r.setBx(0xFFFF);
    _ = call(&r, 0x4800);
    try t.expectEqual(big, r.bx());
    // A bad block.
    r.setSeg(regs.ES, 0x5000);
    _ = call(&r, 0x4900);
    try t.expect(r.flag(regs.CF));
    try t.expectEqual(@as(u16, 9), r.ax());
    // Last fit puts the block at the top.
    r.setBx(2);
    _ = call(&r, 0x5801);
    r.setBx(0x10);
    _ = call(&r, 0x4800);
    try t.expectEqual(@as(u16, 0xA000 - 0x10), r.ax());
}

test "dos: an MZ program's PSP, environment and relocations" {
    boot();
    var img: [64]u8 = undefined;
    th.put("aladdin.exe", tinyMz(&img));
    var r = Regs{};
    try_start(&r, "C:\\ALADDIN.EXE", "/s");
    const psp = st.psp;
    const load = psp + 0x10;
    try t.expectEqual(load, r.seg[regs.CS]);
    try t.expectEqual(@as(u32, 4), r.eip);
    try t.expectEqual(load + 2, r.seg[regs.SS]);
    try t.expectEqual(@as(u16, 0x100), r.sp());
    try t.expectEqual(psp, r.seg[regs.DS]);
    try t.expectEqual(psp, r.seg[regs.ES]);
    try t.expect(r.flag(regs.IF));
    // The relocated word, the image's first byte.
    try t.expectEqual(@as(u16, 1 + load), mem.rdW(load, 0x10));
    try t.expectEqual(@as(u8, 0xB8), mem.rdB(load, 0));
    // The PSP.
    try t.expectEqual(@as(u16, 0x20CD), mem.rdW(psp, 0));
    try t.expectEqual(@as(u8, 0xCD), mem.rdB(psp, 0x50));
    try t.expectEqual(@as(u8, 0x21), mem.rdB(psp, 0x51));
    try t.expectEqual(@as(u8, 0xCB), mem.rdB(psp, 0x52));
    try t.expectEqual(st.shell, mem.rdW(psp, 0x16));
    try t.expectEqual(@as(u8, 3), mem.rdB(psp, 0x80));
    try t.expectEqualStrings(" /s\r", mem.ram[Memory.lin(psp, 0x81)..][0..4]);
    try t.expectEqual(@as(u8, 1), mem.rdB(psp, 0x18)); // stdin: CON
    try t.expectEqual(@as(u8, 0xFF), mem.rdB(psp, 0x18 + 5));
    try t.expectEqual(@as(u16, 20), mem.rdW(psp, 0x32));
    // Its block: owned, named, sized by the header (image + 100h + PSP).
    try t.expectEqual(psp, mem.rdW(psp - 1, 1));
    try t.expectEqualStrings("ALADDIN\x00", mem.ram[Memory.lin(psp - 1, 8)..][0..8]);
    // The environment: the strings, then 1 and the program's path.
    const env = mem.rdW(psp, 0x2C);
    const e = mem.ram[Memory.lin(env, 0)..][0..256];
    try t.expect(std.mem.indexOf(u8, e, "COMSPEC=C:\\COMMAND.COM\x00") != null);
    try t.expect(std.mem.indexOf(u8, e, "BLASTER=A220 I5 D1 H5 T6\x00") != null);
    const end = std.mem.indexOf(u8, e, "\x00\x00").?;
    try t.expectEqual(@as(u8, 1), e[end + 2]);
    try t.expectEqualStrings("C:\\ALADDIN.EXE\x00", e[end + 4 ..][0..15]);
    try t.expectEqual(psp, mem.rdW(env - 1, 1));
    // 62h, 51h: the PSP.
    _ = call(&r, 0x6200);
    try t.expectEqual(psp, r.bx());
}

test "dos: files through handles, case folded, in folders" {
    boot();
    th.put("DATA", null);
    th.put("DATA/Level1.dat", "0123456789");
    var r = Regs{};
    _ = startCom(&r);
    const seg: u16 = 0x2000;
    strAt(&r, seg, 0, "c:\\data\\LEVEL1.dat");
    _ = call(&r, 0x3D00);
    try t.expect(!r.flag(regs.CF));
    const h = r.ax();
    try t.expectEqual(@as(u16, 5), h);
    // Read 4 at 2000:0100.
    r.setBx(h);
    r.setCx(4);
    r.setSeg(regs.DS, seg);
    r.setDx(0x100);
    _ = call(&r, 0x3F00);
    try t.expectEqual(@as(u16, 4), r.ax());
    try t.expectEqualStrings("0123", mem.ram[0x20100..][0..4]);
    // Seek to 7 from the start, read 5 (3 there).
    r.setBx(h);
    r.setCx(0);
    r.setDx(7);
    _ = call(&r, 0x4200);
    try t.expectEqual(@as(u16, 7), r.ax());
    r.setBx(h);
    r.setCx(5);
    r.setDx(0x200);
    _ = call(&r, 0x3F00);
    try t.expectEqual(@as(u16, 3), r.ax());
    try t.expectEqualStrings("789", mem.ram[0x20200..][0..3]);
    // The end: 10.
    r.setBx(h);
    r.setCx(0);
    r.setDx(0);
    _ = call(&r, 0x4202);
    try t.expectEqual(@as(u16, 10), r.ax());
    try t.expectEqual(@as(u16, 0), r.dx());
    // Its device information: a file on C:, not written.
    r.setBx(h);
    _ = call(&r, 0x4400);
    try t.expectEqual(@as(u16, 0x0042), r.dx());
    // A second handle, both closed.
    r.setBx(h);
    _ = call(&r, 0x4500);
    const h2 = r.ax();
    try t.expect(h2 != h);
    r.setBx(h);
    _ = call(&r, 0x3E00);
    try t.expect(!r.flag(regs.CF));
    r.setBx(h2);
    _ = call(&r, 0x3E00);
    try t.expect(!r.flag(regs.CF));
    r.setBx(h2);
    _ = call(&r, 0x3E00);
    try t.expectEqual(@as(u16, 6), r.ax());
    // Create, write, close; the host has it, its name upper case.
    strAt(&r, seg, 0, "data\\new.txt");
    r.setCx(0);
    _ = call(&r, 0x3C00);
    try t.expect(!r.flag(regs.CF));
    const w = r.ax();
    mem.copyIn(0x20300, "hello");
    r.setBx(w);
    r.setCx(5);
    r.setSeg(regs.DS, seg);
    r.setDx(0x300);
    _ = call(&r, 0x4000);
    try t.expectEqual(@as(u16, 5), r.ax());
    r.setBx(w);
    _ = call(&r, 0x3E00);
    const f = th.find("DATA/NEW.TXT").?;
    try t.expectEqualStrings("hello", th.files[f].data[0..th.files[f].size]);
    // Missing: file not found; a missing folder: path not found.
    strAt(&r, seg, 0, "C:\\DATA\\NOPE.DAT");
    _ = call(&r, 0x3D00);
    try t.expectEqual(@as(u16, 2), r.ax());
    strAt(&r, seg, 0, "C:\\NOPE\\X.DAT");
    _ = call(&r, 0x3D00);
    try t.expectEqual(@as(u16, 3), r.ax());
    // stdout is CON; NUL opens anywhere.
    r.setBx(1);
    _ = call(&r, 0x4400);
    try t.expectEqual(@as(u16, 0x80D3), r.dx());
    strAt(&r, seg, 0, "\\DEV\\NUL");
    _ = call(&r, 0x3D02);
    try t.expect(!r.flag(regs.CF));
    // EMMXXXX0 opens as EMM386's does; IOCTL 4400h says a device.
    strAt(&r, seg, 0, "EMMXXXX0");
    _ = call(&r, 0x3D00);
    try t.expect(!r.flag(regs.CF));
    r.setBx(r.ax());
    _ = call(&r, 0x4400);
    try t.expect(r.dx() & 0x80 != 0);
    // chdir, getcwd, a relative open.
    strAt(&r, seg, 0, "\\data");
    _ = call(&r, 0x3B00);
    try t.expect(!r.flag(regs.CF));
    r.setSeg(regs.DS, seg);
    r.setSi(0x400);
    r.setDl(0);
    _ = call(&r, 0x4700);
    try t.expectEqualStrings("DATA\x00", mem.ram[0x20400..][0..5]);
    strAt(&r, seg, 0, "level1.dat");
    _ = call(&r, 0x3D00);
    try t.expect(!r.flag(regs.CF));
    // Delete, rename.
    strAt(&r, seg, 0, "NEW.TXT");
    mem.copyIn(0x20500, "OLD.TXT\x00");
    r.setSeg(regs.ES, seg);
    r.setDi(0x500);
    _ = call(&r, 0x5600);
    try t.expect(!r.flag(regs.CF));
    try t.expect(th.find("DATA/OLD.TXT") != null);
    strAt(&r, seg, 0, "old.txt");
    _ = call(&r, 0x4100);
    try t.expect(!r.flag(regs.CF));
    try t.expect(th.find("DATA/OLD.TXT") == null);
}

test "dos: find first/next with wildcards, folders and long names" {
    boot();
    th.put("A.TXT", "a");
    th.put("b.txt", "bb");
    th.put("C.DAT", "ccc");
    th.put("SUB", null);
    th.put("LongFileName.text", "first");
    th.put("LongFileOther.text", "second");
    var r = Regs{};
    _ = startCom(&r);
    const dta = Memory.lin(st.dta_seg, st.dta_off);
    strAt(&r, 0x2000, 0, "*.TXT");
    r.setCx(0);
    _ = call(&r, 0x4E00);
    try t.expect(!r.flag(regs.CF));
    try t.expectEqualStrings("A.TXT\x00", mem.ram[dta + 0x1E ..][0..6]);
    try t.expectEqual(@as(u32, 1), mem.rd32(dta + 0x1A));
    _ = call(&r, 0x4F00);
    try t.expect(!r.flag(regs.CF));
    try t.expectEqualStrings("B.TXT\x00", mem.ram[dta + 0x1E ..][0..6]);
    try t.expectEqual(@as(u32, 2), mem.rd32(dta + 0x1A));
    _ = call(&r, 0x4F00);
    try t.expect(r.flag(regs.CF));
    try t.expectEqual(@as(u16, 0x12), r.ax());
    // Folders only when asked for.
    var names: [8][13]u8 = undefined;
    var n: usize = 0;
    strAt(&r, 0x2000, 0, "C:\\*.*");
    r.setCx(0x10);
    _ = call(&r, 0x4E00);
    while (!r.flag(regs.CF)) : (_ = call(&r, 0x4F00)) {
        @memcpy(&names[n], mem.ram[dta + 0x1E ..][0..13]);
        n += 1;
    }
    try t.expectEqual(@as(usize, 7), n);
    var saw_sub = false;
    var saw_l1 = false;
    var saw_l2 = false;
    for (names[0..n]) |nm| {
        const s = std.mem.sliceTo(&nm, 0);
        if (std.mem.eql(u8, s, "SUB")) saw_sub = true;
        if (std.mem.eql(u8, s, "LONGFI~1.TEX")) saw_l1 = true;
        if (std.mem.eql(u8, s, "LONGFI~2.TEX")) saw_l2 = true;
    }
    try t.expect(saw_sub and saw_l1 and saw_l2);
    // An alias opens its file.
    strAt(&r, 0x2000, 0, "longfi~2.tex");
    _ = call(&r, 0x3D00);
    try t.expect(!r.flag(regs.CF));
    r.setBx(r.ax());
    r.setCx(16);
    r.setSeg(regs.DS, 0x2000);
    r.setDx(0x100);
    _ = call(&r, 0x3F00);
    try t.expectEqualStrings("second", mem.ram[0x20100..][0..r.ax()]);
    // A subfolder shows "." and "..".
    strAt(&r, 0x2000, 0, "SUB\\*.*");
    r.setCx(0x10);
    _ = call(&r, 0x4E00);
    try t.expectEqualStrings(".\x00", mem.ram[dta + 0x1E ..][0..2]);
    try t.expectEqual(@as(u8, 0x10), mem.rd8(dta + 0x15));
    _ = call(&r, 0x4F00);
    try t.expectEqualStrings("..\x00", mem.ram[dta + 0x1E ..][0..3]);
    _ = call(&r, 0x4F00);
    try t.expect(r.flag(regs.CF));
    // Nothing matches: file not found.
    strAt(&r, 0x2000, 0, "*.ZZZ");
    r.setCx(0);
    _ = call(&r, 0x4E00);
    try t.expect(r.flag(regs.CF));
}

test "dos: exec runs a child; its exit returns to the parent" {
    boot();
    var r = Regs{};
    const parent = startCom(&r);
    th.put("CHILD.COM", &.{ 0xB4, 0x4C, 0xCD, 0x21 });
    // The parent shrinks itself, then calls exec from its code at
    // 1234:0010 with its stack at parent:FF00 (INT 21h's frame there).
    r.setSeg(regs.ES, parent);
    r.setBx(0x1000);
    _ = call(&r, 0x4A00);
    try t.expect(!r.flag(regs.CF));
    r.setSeg(regs.SS, parent);
    r.set16(regs.ESP, 0xFF00);
    mem.wrW(parent, 0xFF00, 0x0010);
    mem.wrW(parent, 0xFF02, 0x1234);
    mem.wrW(parent, 0xFF04, 0x0202);
    r.setSi(0x5151);
    // The parameter block at parent:0200, the tail at parent:0300.
    mem.wrW(parent, 0x200, 0);
    mem.wrW(parent, 0x202, 0x300);
    mem.wrW(parent, 0x204, parent);
    mem.wr32(Memory.lin(parent, 0x206), 0xFFFF_FFFF);
    mem.wr32(Memory.lin(parent, 0x20A), 0xFFFF_FFFF);
    mem.copyIn(Memory.lin(parent, 0x300), "\x03 hi\r");
    strAt(&r, parent, 0x400, "child.com");
    r.setSeg(regs.ES, parent);
    r.setBx(0x200);
    _ = call(&r, 0x4B00);
    try t.expect(!r.flag(regs.CF));
    const child = st.psp;
    try t.expect(child != parent);
    try t.expectEqual(parent, mem.rdW(child, 0x16));
    try t.expectEqualStrings("\x03 hi\r", mem.ram[Memory.lin(child, 0x80)..][0..5]);
    try t.expectEqual(@as(u8, 0xB4), mem.rdB(child, 0x100));
    // The IRET frame starts it: child:0100, interrupts on.
    try t.expectEqual(child, r.seg[regs.SS]);
    const frame = r.base[regs.SS] + r.sp();
    try t.expectEqual(@as(u16, 0x0100), mem.rd16(frame));
    try t.expectEqual(child, mem.rd16(frame + 2));
    try t.expect(mem.rd16(frame + 4) & 0x0200 != 0);
    try t.expectEqual(child, r.seg[regs.DS]);
    // Its return address is the parent's.
    try t.expectEqual(@as(u16, 0x1234), mem.rdW(child, 0x0C));
    // The child ends with code 7 (from its own stack, somewhere else).
    r.setSi(0);
    r.set16(regs.ESP, 0xFFF0);
    _ = call(&r, 0x4C07);
    try t.expect(!st.exited);
    try t.expectEqual(parent, st.psp);
    try t.expectEqual(parent, r.seg[regs.SS]);
    try t.expectEqual(@as(u16, 0xFF00), r.sp());
    try t.expectEqual(@as(u16, 0x5151), r.si());
    try t.expectEqual(@as(u16, 0x0010), mem.rdW(parent, 0xFF00));
    try t.expectEqual(@as(u16, 0x1234), mem.rdW(parent, 0xFF02));
    _ = call(&r, 0x4D00);
    try t.expectEqual(@as(u16, 0x0007), r.ax());
    // The child's memory is free again; the parent's exit ends it all.
    try t.expect(mcb.owner(&mem, child - 1) == 0);
    _ = call(&r, 0x4C03);
    try t.expect(st.exited);
    try t.expectEqual(@as(u8, 3), st.exit_code);
}

test "dos: console output into text memory and the log; input waits" {
    boot();
    mem.wrB(0x40, 0x49, 0x03);
    mem.wrW(0x40, 0x4A, 80);
    mem.wrB(0x40, 0x84, 24);
    var r = Regs{};
    _ = startCom(&r);
    strAt(&r, 0x2000, 0, "Hi$");
    _ = call(&r, 0x0900);
    try t.expectEqual(@as(u8, 'H'), mem.ram[0xB8000]);
    try t.expectEqual(@as(u8, 'i'), mem.ram[0xB8002]);
    try t.expectEqual(@as(u8, 2), mem.rdB(0x40, 0x50));
    r.setDl('\r');
    _ = call(&r, 0x0200);
    r.setDl('\n');
    _ = call(&r, 0x0200);
    try t.expectEqual(@as(u8, 1), mem.rdB(0x40, 0x51));
    try t.expect(std.mem.indexOf(u8, th.logged(), "dos: con: Hi") != null);
    // Write to stdout (handle 1).
    mem.copyIn(0x20100, "ok");
    r.setBx(1);
    r.setCx(2);
    r.setSeg(regs.DS, 0x2000);
    r.setDx(0x100);
    _ = call(&r, 0x4000);
    try t.expectEqual(@as(u16, 2), r.ax());
    try t.expectEqual(@as(u8, 'o'), mem.ram[0xB8000 + 160]);
    // No key: 01h waits, 06h says none, 0Bh says none.
    try t.expect(!call(&r, 0x0100));
    r.setDl(0xFF);
    _ = call(&r, 0x0600);
    try t.expect(r.flag(regs.ZF));
    _ = call(&r, 0x0B00);
    try t.expectEqual(@as(u8, 0), r.al());
    // A key: 08h gets it; an arrow: 00h then its scan code.
    _ = bios.keyStore(&mem, 0x1E61);
    _ = bios.keyStore(&mem, 0x48E0);
    try t.expect(call(&r, 0x0800));
    try t.expectEqual(@as(u8, 'a'), r.al());
    try t.expect(call(&r, 0x0700));
    try t.expectEqual(@as(u8, 0), r.al());
    try t.expect(call(&r, 0x0700));
    try t.expectEqual(@as(u8, 0x48), r.al());
    // 0Ah: a line, edited, waits until Enter.
    mem.wr8(0x20200, 10);
    r.setSeg(regs.DS, 0x2000);
    r.setDx(0x200);
    _ = bios.keyStore(&mem, 0x2364); // d
    _ = bios.keyStore(&mem, 0x1F78); // x
    _ = bios.keyStore(&mem, 0x0E08); // backspace
    try t.expect(!call(&r, 0x0A00));
    _ = bios.keyStore(&mem, 0x1F73); // s
    _ = bios.keyStore(&mem, 0x1C0D); // Enter
    r.setSeg(regs.DS, 0x2000);
    r.setDx(0x200);
    try t.expect(call(&r, 0x0A00));
    try t.expectEqual(@as(u8, 2), mem.ram[0x20201]);
    try t.expectEqualStrings("ds\r", mem.ram[0x20202..][0..3]);
}

test "dos: FCBs and 29h" {
    boot();
    th.put("SAVE.DAT", "ABCDEFGHIJ");
    var r = Regs{};
    _ = startCom(&r);
    // Parse "c:save.dat" into an FCB at 2000:0100.
    mem.copyIn(0x20000, "c:save.dat\x00");
    r.setSeg(regs.DS, 0x2000);
    r.setSi(0);
    r.setSeg(regs.ES, 0x2000);
    r.setDi(0x100);
    _ = call(&r, 0x2901);
    try t.expectEqual(@as(u8, 0), r.al());
    try t.expectEqual(@as(u16, 10), r.si());
    try t.expectEqual(@as(u8, 3), mem.ram[0x20100]);
    try t.expectEqualStrings("SAVE    DAT", mem.ram[0x20101..][0..11]);
    // Open it, read a 4-byte record sequentially into the DTA at 2000:0400.
    r.setSeg(regs.DS, 0x2000);
    r.setDx(0x400);
    _ = call(&r, 0x1A00);
    r.setDx(0x100);
    _ = call(&r, 0x0F00);
    try t.expectEqual(@as(u8, 0), r.al());
    try t.expectEqual(@as(u32, 10), mem.rd32(0x20110));
    mem.wr16(0x2010E, 4);
    mem.wr8(0x20120, 0);
    _ = call(&r, 0x1400);
    try t.expectEqual(@as(u8, 0), r.al());
    try t.expectEqualStrings("ABCD", mem.ram[0x20400..][0..4]);
    _ = call(&r, 0x1400);
    _ = call(&r, 0x1400);
    try t.expectEqual(@as(u8, 3), r.al()); // "IJ" and two zeroes
    try t.expectEqualStrings("IJ\x00\x00", mem.ram[0x20400..][0..4]);
    // Random record 1.
    mem.wr32(0x20121, 1);
    _ = call(&r, 0x2100);
    try t.expectEqualStrings("EFGH", mem.ram[0x20400..][0..4]);
    _ = call(&r, 0x1000);
    try t.expectEqual(@as(u8, 0), r.al());
    // A wildcard parse.
    mem.copyIn(0x20000, "*.DAT\x00");
    r.setSi(0);
    _ = call(&r, 0x2900);
    try t.expectEqual(@as(u8, 1), r.al());
    try t.expectEqualStrings("????????DAT", mem.ram[0x20101..][0..11]);
}

/// A bus with its own video memory at A0000-AFFFF (as the VGA would be).
const VgaBus = struct {
    mem: *Memory,
    vram: *[0x10000]u8,
    pub fn rd8(b: VgaBus, a: u32) u8 {
        if (a >= 0xA0000 and a < 0xB0000) return b.vram[a - 0xA0000];
        return b.mem.rd8(a);
    }
    pub fn wr8(b: VgaBus, a: u32, v: u8) void {
        if (a >= 0xA0000 and a < 0xB0000) {
            b.vram[a - 0xA0000] = v;
        } else b.mem.wr8(a, v);
    }
};
var vram: [0x10000]u8 = undefined;

test "dos: a read into A000:0 goes through the bus" {
    boot();
    th.put("PIC.RAW", "pixels!");
    var r = Regs{};
    _ = startCom(&r);
    @memset(&vram, 0);
    const bus = VgaBus{ .mem = &mem, .vram = &vram };
    strAt(&r, 0x2000, 0, "PIC.RAW");
    r.setAx(0x3D00);
    _ = dos.int21Bus(&st, &r, &mem, th.host(), bus);
    r.setBx(r.ax());
    r.setCx(7);
    r.setSeg(regs.DS, 0xA000);
    r.setDx(0x0010);
    r.setAx(0x3F00);
    _ = dos.int21Bus(&st, &r, &mem, th.host(), bus);
    try t.expectEqual(@as(u16, 7), r.ax());
    try t.expectEqualStrings("pixels!", vram[0x10..][0..7]);
    try t.expectEqual(@as(u8, 0), mem.ram[0xA0010]);
}
