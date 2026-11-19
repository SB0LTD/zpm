//! The machine as a whole: boot, the vector table and the ROM's stubs,
//! and (as the parts arrive) small programs run end to end.

const std = @import("std");
const t = std.testing;
const machine = @import("machine.sig");
const TestHost = @import("test_host.sig").TestHost;
const regs = @import("regs.sig");

var m: machine.Machine = .{};
var th: TestHost = .{};

test "machine: every vector points at its stub in the ROM" {
    th = .{};
    m.init(th.host(), "");
    const v21 = m.mem.rdW(0, 0x21 * 4);
    try t.expectEqual(machine.ROM_SEG, m.mem.rdW(0, 0x21 * 4 + 2));
    const at = (@as(u32, machine.ROM_SEG) << 4) + v21;
    // STI; FE 38 21; IRET
    try t.expectEqual(@as(u8, 0xFB), m.mem.rd8(at));
    try t.expectEqual(@as(u8, 0xFE), m.mem.rd8(at + 1));
    try t.expectEqual(@as(u8, 0x38), m.mem.rd8(at + 2));
    try t.expectEqual(@as(u8, 0x21), m.mem.rd8(at + 3));
    try t.expectEqual(@as(u8, 0xCF), m.mem.rd8(at + 4));
    // int 08h: trap, int 1Ch, then a near jump to the EOI tail.
    const a8 = (@as(u32, machine.ROM_SEG) << 4) + m.mem.rdW(0, 0x08 * 4);
    try t.expectEqual(@as(u8, 0xCD), m.mem.rd8(a8 + 3));
    try t.expectEqual(@as(u8, 0x1C), m.mem.rd8(a8 + 4));
    try t.expectEqual(@as(u8, 0xE9), m.mem.rd8(a8 + 5));
    const rel: i16 = @bitCast(m.mem.rd16(a8 + 6));
    const tail: u32 = @intCast(@as(i64, a8 + 8) + rel);
    try t.expectEqual(@as(u8, 0x50), m.mem.rd8(tail)); // push ax
    try t.expectEqual(@as(u8, 0xCF), m.mem.rd8(tail + 6)); // iret
}

test "machine: the bus sends A0000-BFFFF to the VGA and keeps the ROM" {
    th = .{};
    m.init(th.host(), "");
    m.wr8(0x1234, 0x5A);
    try t.expectEqual(@as(u8, 0x5A), m.rd8(0x1234));
    const before = m.rd8(0xFFFF5);
    m.wr8(0xFFFF5, 0x00);
    try t.expectEqual(before, m.rd8(0xFFFF5));
    m.wr16(0x9FFFF, 0xABCD); // (straddles conventional memory's end)
    try t.expectEqual(@as(u8, 0xCD), m.mem.ram[0x9FFFF]);
}

test "machine: a service's carry goes back through the stacked flags" {
    th = .{};
    m.init(th.host(), "");
    const r = &m.cpu.regs;
    r.setSeg(regs.SS, 0x2000);
    r.set16(regs.ESP, 0x0100);
    // The stack as INT leaves it: IP, CS, FLAGS (carry clear).
    m.wr16(0x20100, 0x1111);
    m.wr16(0x20102, 0x2222);
    m.wr16(0x20104, 0x0202);
    r.setAh(0x01); // int 13h: no drive -> carry set
    _ = m.hle(&m.cpu, 0x13);
    try t.expect(m.rd16(0x20104) & 1 == 1);
}
