//! XMS and EMS on their own: a Regs and a static Memory, no machine.

const std = @import("std");
const t = std.testing;
const xms = @import("xms.sig");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const mem_mod = @import("mem.sig");
const Memory = mem_mod.Memory;

var mem: Memory = .{};
var st: xms.State = .{};

fn fresh() void {
    mem.clear();
    st.reset();
    xms.boot(&st, &mem, 0x110000, mem_mod.RAM, 0xF080);
}

fn call(r: *Regs, ax: u16) void {
    r.setAx(ax);
    xms.xms(&st, r, &mem);
}
fn ems(r: *Regs, ax: u16) void {
    r.setAx(ax);
    xms.int67(&st, r, &mem);
}

test "xms: version, the HMA, A20" {
    fresh();
    var r = Regs{};
    call(&r, 0x0000);
    try t.expectEqual(@as(u16, 0x0300), r.ax());
    try t.expectEqual(@as(u16, 1), r.dx());
    r.setDx(0xFFFF);
    call(&r, 0x0100);
    try t.expectEqual(@as(u16, 1), r.ax());
    call(&r, 0x0100);
    try t.expectEqual(@as(u16, 0), r.ax());
    try t.expectEqual(@as(u8, 0x91), r.bl());
    call(&r, 0x0200);
    try t.expectEqual(@as(u16, 1), r.ax());
    call(&r, 0x0500);
    try t.expect(mem.a20);
    call(&r, 0x0700);
    try t.expectEqual(@as(u16, 1), r.ax());
    call(&r, 0x0600);
    try t.expect(!mem.a20);
}

test "xms: allocate, move both ways, lock, resize, free" {
    fresh();
    var r = Regs{};
    call(&r, 0x0800);
    const free0 = r.dx();
    try t.expect(free0 > 15000);
    r.setDx(100); // KiB
    call(&r, 0x0900);
    try t.expectEqual(@as(u16, 1), r.ax());
    const h = r.dx();
    // Conventional 2000:0000 -> the block at offset 1000h.
    mem.copyIn(0x20000, "XMS moves bytes!");
    const mv: u32 = 0x3000; // the move structure at 0300:0000
    mem.wr32(mv, 16);
    mem.wr16(mv + 4, 0);
    mem.wr32(mv + 6, 0x2000_0000);
    mem.wr16(mv + 10, h);
    mem.wr32(mv + 12, 0x1000);
    r.setSeg(regs.DS, 0x0300);
    r.setSi(0);
    call(&r, 0x0B00);
    try t.expectEqual(@as(u16, 1), r.ax());
    // Lock: its linear address, where the bytes are.
    r.setDx(h);
    call(&r, 0x0C00);
    try t.expectEqual(@as(u16, 1), r.ax());
    const lin = (@as(u32, r.dx()) << 16) | r.bx();
    try t.expect(lin >= 0x110000);
    try t.expectEqualStrings("XMS moves bytes!", mem.ram[lin + 0x1000 ..][0..16]);
    // Locked: no free, no move-resize.
    r.setDx(h);
    call(&r, 0x0A00);
    try t.expectEqual(@as(u8, 0xAB), r.bl());
    r.setDx(h);
    call(&r, 0x0D00);
    try t.expectEqual(@as(u16, 1), r.ax());
    // And back to conventional 2100:0000.
    mem.wr16(mv + 4, h);
    mem.wr32(mv + 6, 0x1000);
    mem.wr16(mv + 10, 0);
    mem.wr32(mv + 12, 0x2100_0000);
    call(&r, 0x0B00);
    try t.expectEqual(@as(u16, 1), r.ax());
    try t.expectEqualStrings("XMS moves bytes!", mem.ram[0x21000..][0..16]);
    // An odd length and an offset past the block fail.
    mem.wr32(mv, 15);
    call(&r, 0x0B00);
    try t.expectEqual(@as(u8, 0xA7), r.bl());
    mem.wr32(mv, 16);
    mem.wr32(mv + 6, 200 * 1024);
    call(&r, 0x0B00);
    try t.expectEqual(@as(u8, 0xA4), r.bl());
    // A second block after it; growing the first moves it and its bytes.
    r.setDx(16);
    call(&r, 0x0900);
    const h2 = r.dx();
    r.setDx(h);
    r.setBx(400);
    call(&r, 0x0F00);
    try t.expectEqual(@as(u16, 1), r.ax());
    r.setDx(h);
    call(&r, 0x0E00);
    try t.expectEqual(@as(u16, 400), r.dx());
    r.setDx(h);
    call(&r, 0x0C00);
    const lin2 = (@as(u32, r.dx()) << 16) | r.bx();
    try t.expect(lin2 != lin);
    try t.expectEqualStrings("XMS moves bytes!", mem.ram[lin2 + 0x1000 ..][0..16]);
    r.setDx(h);
    call(&r, 0x0D00);
    r.setDx(h);
    call(&r, 0x0A00);
    try t.expectEqual(@as(u16, 1), r.ax());
    r.setDx(h2);
    call(&r, 0x0A00);
    r.setDx(h2);
    call(&r, 0x0A00);
    try t.expectEqual(@as(u8, 0xA2), r.bl());
    call(&r, 0x0800);
    try t.expectEqual(free0, r.dx());
    // 32-bit query.
    call(&r, 0x8800);
    try t.expectEqual(@as(u32, free0), r.r[regs.EDX]);
}

test "ems: allocate, map, the window, save and restore, free" {
    fresh();
    var r = Regs{};
    ems(&r, 0x4000);
    try t.expectEqual(@as(u8, 0), r.ah());
    ems(&r, 0x4100);
    try t.expectEqual(@as(u16, 0xE000), r.bx());
    ems(&r, 0x4600);
    try t.expectEqual(@as(u8, 0x40), r.al());
    ems(&r, 0x4200);
    const total = r.dx();
    const free0 = r.bx();
    try t.expectEqual(total, free0);
    // The device header and int 67h's vector.
    try t.expectEqualStrings("EMMXXXX0", mem.ram[0xF080A..][0..8]);
    const seg = mem.rdW(0, 0x67 * 4 + 2);
    try t.expectEqualStrings("EMMXXXX0", mem.ram[(@as(u32, seg) << 4) + 0x0A ..][0..8]);
    // Four pages.
    r.setBx(4);
    ems(&r, 0x4300);
    try t.expectEqual(@as(u8, 0), r.ah());
    const h = r.dx();
    try t.expect(h != 0);
    try t.expectEqual(@as(?u32, null), st.emsWindow(0));
    // Logical 2 at physical 0, logical 3 at physical 1.
    r.setDx(h);
    r.setBx(2);
    ems(&r, 0x4400);
    try t.expectEqual(@as(u8, 0), r.ah());
    r.setDx(h);
    r.setBx(3);
    ems(&r, 0x4401);
    const w0 = st.emsWindow(0x0010).?;
    const w1 = st.emsWindow(0x4010).?;
    try t.expect(w0 != w1);
    try t.expect(w0 >= 0x110000);
    mem.ram[w0] = 0x5A;
    // Map logical 2 at physical 3 too: the same bytes.
    r.setDx(h);
    r.setBx(2);
    ems(&r, 0x4403);
    try t.expectEqual(@as(u8, 0x5A), mem.ram[st.emsWindow(0xC010).?]);
    // Out of range.
    r.setDx(h);
    r.setBx(4);
    ems(&r, 0x4400);
    try t.expectEqual(@as(u8, 0x8A), r.ah());
    r.setDx(h);
    r.setBx(0);
    ems(&r, 0x4404);
    try t.expectEqual(@as(u8, 0x8B), r.ah());
    r.setDx(99);
    ems(&r, 0x4400);
    try t.expectEqual(@as(u8, 0x83), r.ah());
    // Save, unmap, restore.
    r.setDx(h);
    ems(&r, 0x4700);
    try t.expectEqual(@as(u8, 0), r.ah());
    r.setDx(h);
    r.setBx(0xFFFF);
    ems(&r, 0x4400);
    try t.expectEqual(@as(?u32, null), st.emsWindow(0x0010));
    r.setDx(h);
    ems(&r, 0x4800);
    try t.expectEqual(w0, st.emsWindow(0x0010).?);
    // Names.
    mem.copyIn(0x5000, "ALADDIN\x00");
    r.setSeg(regs.DS, 0x0500);
    r.setSi(0);
    r.setDx(h);
    ems(&r, 0x5301);
    try t.expectEqual(@as(u8, 0), r.ah());
    r.setDx(0);
    ems(&r, 0x5401);
    try t.expectEqual(@as(u8, 0), r.ah());
    try t.expectEqual(h, r.dx());
    // Map multiple by segment: logical 0 at E400h.
    mem.wr16(0x5100, 0);
    mem.wr16(0x5102, 0xE400);
    r.setSeg(regs.DS, 0x0510);
    r.setSi(0);
    r.setDx(h);
    r.setCx(1);
    ems(&r, 0x5001);
    try t.expectEqual(@as(u8, 0), r.ah());
    try t.expect(st.emsWindow(0x4000).? != w1);
    // Reallocate to 6, then 1 (unmapping what went).
    r.setDx(h);
    r.setBx(6);
    ems(&r, 0x5100);
    try t.expectEqual(@as(u16, 6), r.bx());
    r.setDx(h);
    r.setBx(1);
    ems(&r, 0x5100);
    try t.expectEqual(@as(?u32, null), st.emsWindow(0x0010));
    try t.expect(st.emsWindow(0x4000) != null);
    // Free: refused while a context is saved... none now; then gone.
    r.setDx(h);
    ems(&r, 0x4500);
    try t.expectEqual(@as(u8, 0), r.ah());
    ems(&r, 0x4200);
    try t.expectEqual(free0, r.bx());
    try t.expectEqual(@as(?u32, null), st.emsWindow(0x4000));
    r.setDx(h);
    ems(&r, 0x4C00);
    try t.expectEqual(@as(u8, 0x83), r.ah());
    // XMS and EMS share the pool.
    r.setBx(10);
    ems(&r, 0x4300);
    var x = Regs{};
    call(&x, 0x0800);
    try t.expectEqual(@as(u16, (free0 - 10) * 16), x.dx());
    // VCPI and 5Bh: refused.
    ems(&r, 0xDE00);
    try t.expectEqual(@as(u8, 0x84), r.ah());
    ems(&r, 0x5B00);
    try t.expectEqual(@as(u8, 0xA4), r.ah());
}

test "ems: 57h moves between conventional memory and pages, across pages" {
    fresh();
    var r = Regs{};
    r.setBx(2);
    ems(&r, 0x4300);
    const h = r.dx();
    mem.copyIn(0x30000, "across a page boundary");
    // Move 22 bytes from 3000:0000 to handle h page 0 offset 3FF0h.
    const p: u32 = 0x6000;
    mem.wr32(p, 22);
    mem.wr8(p + 4, 0);
    mem.wr16(p + 5, 0);
    mem.wr16(p + 7, 0);
    mem.wr16(p + 9, 0x3000);
    mem.wr8(p + 11, 1);
    mem.wr16(p + 12, h);
    mem.wr16(p + 14, 0x3FF0);
    mem.wr16(p + 16, 0);
    r.setSeg(regs.DS, 0x0600);
    r.setSi(0);
    ems(&r, 0x5700);
    try t.expectEqual(@as(u8, 0), r.ah());
    // Map both pages and read the bytes through the windows.
    r.setDx(h);
    r.setBx(0);
    ems(&r, 0x4400);
    r.setDx(h);
    r.setBx(1);
    ems(&r, 0x4401);
    var got: [22]u8 = undefined;
    for (&got, 0..) |*b, i| b.* = mem.ram[st.emsWindow(0x3FF0 + @as(u32, @intCast(i))).?];
    try t.expectEqualStrings("across a page boundary", &got);
    // Exchange it back with zeros at 3100:0000.
    mem.wr16(p + 9, 0x3100);
    r.setSeg(regs.DS, 0x0600);
    r.setSi(0);
    ems(&r, 0x5701);
    try t.expectEqual(@as(u8, 0), r.ah());
    try t.expectEqualStrings("across a page boundary", mem.ram[0x31000..][0..22]);
    try t.expectEqual(@as(u8, 0), mem.ram[st.emsWindow(0x3FF0).?]);
}
