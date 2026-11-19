//! The BIOS on its own: a Regs and a static Memory, no machine.

const std = @import("std");
const t = std.testing;
const bios = @import("bios.sig");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;
const TestHost = @import("test_host.sig").TestHost;

var mem: Memory = .{};
var th: TestHost = .{};

fn fresh(st: *bios.State) void {
    mem.clear();
    st.reset();
    bios.boot(st, &mem, 640, 15 * 1024);
}

fn keys(st: *bios.State, codes: []const u8) void {
    for (codes) |c| bios.keyIrq(st, &mem, c);
}

test "bios: the data area at boot" {
    var st: bios.State = .{};
    fresh(&st);
    var r = Regs{};
    bios.int11(&r, &mem);
    try t.expectEqual(@as(u16, 0x0022), r.ax());
    bios.int12(&r, &mem);
    try t.expectEqual(@as(u16, 640), r.ax());
    try t.expectEqual(@as(u16, 0x1E), mem.rdW(0x40, 0x1A));
    try t.expectEqual(@as(u16, 0x1E), mem.rdW(0x40, 0x1C));
    try t.expectEqual(@as(u16, 0x3E), mem.rdW(0x40, 0x82));
    try t.expectEqual(@as(u8, 0x10), mem.rdB(0x40, 0x96));
    // The configuration table int 15h/C0h points at.
    r.setAh(0xC0);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, @import("dos_bus.sig").MemBus{ .mem = &mem });
    try t.expect(!r.flag(regs.CF));
    try t.expectEqual(@as(u16, 0xF000), r.seg[regs.ES]);
    try t.expectEqual(@as(u16, 0xE6F5), r.bx());
    try t.expectEqual(@as(u8, 0xFC), mem.rdB(0xF000, 0xE6F7));
}

test "bios: scan codes become the buffer's keys" {
    var st: bios.State = .{};
    fresh(&st);
    var r = Regs{};
    // a, Shift+a, Enter, grey Up, F1, Ctrl+C, Alt+X
    keys(&st, &.{ 0x1E, 0x9E, 0x2A, 0x1E, 0x9E, 0xAA, 0x1C, 0x9C, 0xE0, 0x48, 0xE0, 0xC8, 0x3B, 0xBB });
    keys(&st, &.{ 0x1D, 0x2E, 0xAE, 0x9D, 0x38, 0x2D, 0xAD, 0xB8 });
    const want = [_]u16{ 0x1E61, 0x1E41, 0x1C0D, 0x4800, 0x3B00, 0x2E03, 0x2D00 };
    for (want) |w| {
        r.setAh(0x01);
        try t.expect(bios.int16(&st, &r, &mem));
        try t.expect(!r.flag(regs.ZF));
        try t.expectEqual(w, r.ax());
        r.setAh(0x00);
        try t.expect(bios.int16(&st, &r, &mem));
        try t.expectEqual(w, r.ax());
    }
    // Empty: 01h sets ZF, 00h waits.
    r.setAh(0x01);
    _ = bios.int16(&st, &r, &mem);
    try t.expect(r.flag(regs.ZF));
    r.setAh(0x00);
    try t.expect(!bios.int16(&st, &r, &mem));
}

test "bios: enhanced codes, CapsLock, the keypad and Alt+numpad" {
    var st: bios.State = .{};
    fresh(&st);
    var r = Regs{};
    // Grey Up through 10h keeps E0; F11 is only there.
    keys(&st, &.{ 0xE0, 0x48, 0xE0, 0xC8, 0x57, 0xD7 });
    r.setAh(0x10);
    _ = bios.int16(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0x48E0), r.ax());
    r.setAh(0x10);
    _ = bios.int16(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0x8500), r.ax());
    // F11 through 00h is dropped.
    keys(&st, &.{ 0x57, 0xD7, 0x30, 0xB0 });
    r.setAh(0x00);
    _ = bios.int16(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0x3062), r.ax());
    // CapsLock: letters upper, digits not; Shift inverts letters.
    keys(&st, &.{ 0x3A, 0xBA, 0x1E, 0x9E, 0x02, 0x82, 0x2A, 0x1E, 0x9E, 0xAA });
    try t.expect(mem.rdB(0x40, 0x17) & 0x40 != 0);
    try t.expectEqual(@as(u8, 4), mem.rdB(0x40, 0x97));
    for ([_]u16{ 0x1E41, 0x0231, 0x1E61 }) |w| {
        r.setAh(0x00);
        _ = bios.int16(&st, &r, &mem);
        try t.expectEqual(w, r.ax());
    }
    // NumLock: keypad 8 is a digit; without, an arrow.
    keys(&st, &.{ 0x48, 0xC8, 0x45, 0xC5, 0x48, 0xC8 });
    for ([_]u16{ 0x4800, 0x4838 }) |w| {
        r.setAh(0x00);
        _ = bios.int16(&st, &r, &mem);
        try t.expectEqual(w, r.ax());
    }
    // Alt + keypad 6, 5: 'A' when Alt is released.
    keys(&st, &.{ 0x38, 0x4D, 0xCD, 0x4C, 0xCC, 0xB8 });
    r.setAh(0x00);
    _ = bios.int16(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0x0041), r.ax());
    // Shift flags: Right Ctrl held shows in 12h's AH.
    keys(&st, &.{ 0xE0, 0x1D });
    r.setAh(0x12);
    _ = bios.int16(&st, &r, &mem);
    try t.expect(r.al() & 0x04 != 0);
    try t.expect(r.ah() & 0x04 != 0);
    keys(&st, &.{ 0xE0, 0x9D });
    r.setAh(0x02);
    _ = bios.int16(&st, &r, &mem);
    try t.expect(r.al() & 0x04 == 0);
}

test "bios: the buffer holds 15 keys; 05h stores one" {
    var st: bios.State = .{};
    fresh(&st);
    var r = Regs{};
    var i: u32 = 0;
    while (i < 20) : (i += 1) keys(&st, &.{ 0x1E, 0x9E });
    var n: u32 = 0;
    while (true) : (n += 1) {
        r.setAh(0x00);
        if (!bios.int16(&st, &r, &mem)) break;
    }
    try t.expectEqual(@as(u32, 15), n);
    r.setAh(0x05);
    r.setCx(0x1234);
    _ = bios.int16(&st, &r, &mem);
    try t.expectEqual(@as(u8, 0), r.al());
    r.setAh(0x00);
    _ = bios.int16(&st, &r, &mem);
    try t.expectEqual(@as(u16, 0x1234), r.ax());
}

test "bios: ticks, midnight, int 1Ah" {
    var st: bios.State = .{};
    fresh(&st);
    th = .{};
    bios.setClock(&mem, th.time);
    // 12:00:00 is half a day of ticks.
    try t.expect(bios.ticks(&mem) >= 0x1800B0 / 2 and bios.ticks(&mem) < 0x1800B0 / 2 + 16);
    var r = Regs{};
    r.setAh(0x01);
    r.setCx(0x0018);
    r.setDx(0x00AF);
    bios.int1a(&st, &r, &mem, th.host());
    bios.timerTick(&st, &mem);
    r.setAh(0x00);
    bios.int1a(&st, &r, &mem, th.host());
    try t.expectEqual(@as(u16, 0), r.cx());
    try t.expectEqual(@as(u16, 0), r.dx());
    try t.expectEqual(@as(u8, 1), r.al());
    r.setAh(0x00);
    bios.int1a(&st, &r, &mem, th.host());
    try t.expectEqual(@as(u8, 0), r.al());
    r.setAh(0x02);
    bios.int1a(&st, &r, &mem, th.host());
    try t.expectEqual(@as(u8, 0x12), r.ch());
    r.setAh(0x04);
    bios.int1a(&st, &r, &mem, th.host());
    try t.expectEqual(@as(u16, 0x1994), r.cx());
    try t.expectEqual(@as(u16, 0x1111), r.dx());
}

test "bios: int 15h A20, 88h, E801h, the block move, the wait" {
    var st: bios.State = .{};
    fresh(&st);
    const MemBus = @import("dos_bus.sig").MemBus;
    var r = Regs{};
    r.setAx(0x2401);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expect(mem.a20);
    r.setAx(0x2402);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expectEqual(@as(u8, 1), r.al());
    r.setAx(0x2400);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expect(!mem.a20);
    r.setAh(0x88);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expectEqual(@as(u16, 0), r.ax());
    r.setAx(0xE801);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expectEqual(@as(u16, 15 * 1024), r.ax());
    // 87h: 4 words from 0x2000 to 0x200000 (GDT at 0100:0000).
    mem.copyIn(0x2000, "ABCDEFGH");
    const gdt: u32 = 0x1000;
    mem.wr16(gdt + 0x12, 0x2000);
    mem.wr8(gdt + 0x14, 0x00);
    mem.wr16(gdt + 0x1A, 0x0000);
    mem.wr8(gdt + 0x1C, 0x20);
    r.setSeg(regs.ES, 0x0100);
    r.setSi(0);
    r.setAh(0x87);
    r.setCx(4);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expect(!r.flag(regs.CF));
    try t.expect(!mem.a20);
    try t.expectEqualStrings("ABCDEFGH", mem.ram[0x200000..][0..8]);
    // 86h: two ticks' wait.
    r.setAh(0x86);
    r.setCx(0x0001);
    r.setDx(0xADB0); // 110000 us
    try t.expect(!bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem }));
    bios.timerTick(&st, &mem);
    try t.expect(!bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem }));
    bios.timerTick(&st, &mem);
    try t.expect(bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem }));
    // 4Fh: CF set, the key processed.
    r.setAx(0x4F1E);
    _ = bios.int15Wait(&st, &r, &mem, &mem.a20, MemBus{ .mem = &mem });
    try t.expect(r.flag(regs.CF));
    try t.expectEqual(@as(u8, 0x1E), r.al());
}
