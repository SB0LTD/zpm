//! The mouse driver on its own: a Regs and a static Memory.

const std = @import("std");
const t = std.testing;
const mouse = @import("mouse.sig");
const regs = @import("regs.sig");
const Regs = regs.Regs;
const Memory = @import("mem.sig").Memory;

var mem: Memory = .{};

fn call(st: *mouse.State, r: *Regs, ax: u16) void {
    r.setAx(ax);
    mouse.int33(st, r, &mem);
}

test "mouse: reset, motion, ranges, buttons" {
    mem.clear();
    mem.wrB(0x40, 0x49, 0x13);
    var st: mouse.State = .{};
    var r = Regs{};
    call(&st, &r, 0x0000);
    try t.expectEqual(@as(u16, 0xFFFF), r.ax());
    try t.expectEqual(@as(u16, 2), r.bx());
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 320), r.cx());
    try t.expectEqual(@as(u16, 100), r.dx());
    // 10 mickeys right: 10 pixels; 10 down: 5 (16 per 8 vertically).
    st.move(10, 10);
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 330), r.cx());
    try t.expectEqual(@as(u16, 105), r.dx());
    call(&st, &r, 0x000B);
    try t.expectEqual(@as(u16, 10), r.cx());
    try t.expectEqual(@as(u16, 10), r.dx());
    call(&st, &r, 0x000B);
    try t.expectEqual(@as(u16, 0), r.cx());
    // A range clamps the position.
    r.setCx(400);
    r.setDx(100);
    call(&st, &r, 0x0007);
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 330), r.cx());
    r.setCx(0);
    r.setDx(50);
    call(&st, &r, 0x0008);
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 50), r.dx());
    // Left pressed and released: counts and positions.
    st.buttons(1);
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 1), r.bx());
    st.buttons(0);
    r.setBx(0);
    call(&st, &r, 0x0005);
    try t.expectEqual(@as(u16, 1), r.bx());
    try t.expectEqual(@as(u16, 330), r.cx());
    r.setBx(0);
    call(&st, &r, 0x0005);
    try t.expectEqual(@as(u16, 0), r.bx());
    r.setBx(0);
    call(&st, &r, 0x0006);
    try t.expectEqual(@as(u16, 1), r.bx());
    // Set position (x kept in the 100-400 range).
    r.setCx(10);
    r.setDx(20);
    call(&st, &r, 0x0004);
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 100), r.cx());
    try t.expectEqual(@as(u16, 20), r.dx());
}

test "mouse: the user handler is queued with its events" {
    mem.clear();
    mem.wrB(0x40, 0x49, 0x03);
    var st: mouse.State = .{};
    var r = Regs{};
    call(&st, &r, 0x0000);
    try t.expect(st.userCall() == null);
    r.setSeg(regs.ES, 0x1234);
    r.setDx(0x0056);
    r.setCx(mouse.LEFT_DOWN | mouse.RIGHT_UP);
    call(&st, &r, 0x000C);
    st.move(3, 0); // (not in the mask)
    try t.expect(st.userCall() == null);
    st.buttons(1);
    const c = st.userCall().?;
    try t.expectEqual(@as(u16, 0x1234), c.seg);
    try t.expectEqual(@as(u16, 0x0056), c.off);
    try t.expectEqual(mouse.LEFT_DOWN, c.mask);
    var h = Regs{};
    st.handlerRegs(&h, c.mask);
    try t.expectEqual(@as(u16, 1), h.bx());
    try t.expect(st.userCall() == null);
    // 14h swaps in a new one and returns the old.
    r.setSeg(regs.ES, 0x2000);
    r.setDx(0x0010);
    r.setCx(mouse.MOVED);
    call(&st, &r, 0x0014);
    try t.expectEqual(@as(u16, 0x1234), r.seg[regs.ES]);
    try t.expectEqual(@as(u16, 0x0056), r.dx());
    st.move(0, 16);
    try t.expectEqual(mouse.MOVED, st.userCall().?.mask);
    // Text mode: positions are cell corners.
    r.setCx(13);
    r.setDx(21);
    call(&st, &r, 0x0004);
    call(&st, &r, 0x0003);
    try t.expectEqual(@as(u16, 8), r.cx());
    try t.expectEqual(@as(u16, 16), r.dx());
    // Save, change, restore.
    call(&st, &r, 0x0015);
    try t.expect(r.bx() > 0);
    r.setSeg(regs.ES, 0x0300);
    r.setDx(0);
    call(&st, &r, 0x0016);
    r.setCx(100);
    r.setDx(100);
    call(&st, &r, 0x0004);
    r.setSeg(regs.ES, 0x0300);
    r.setDx(0);
    call(&st, &r, 0x0017);
    try t.expectEqual(@as(i16, 13), st.x);
    call(&st, &r, 0x0024);
    try t.expectEqual(@as(u16, 0x0626), r.bx());
}
