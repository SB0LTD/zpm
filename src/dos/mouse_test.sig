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

var pic: [720 * 400]u32 = undefined;

test "mouse: the cursor over the picture (mode 13h's arrow, hot spot, masks; text cells)" {
    mem.clear();
    mem.wrB(0x40, 0x49, 0x13);
    var st: mouse.State = .{};
    var r = Regs{};
    call(&st, &r, 0x0000);
    const grey: u32 = 0x00808080;
    @memset(pic[0 .. 320 * 200], grey);
    // Hidden after a reset: nothing drawn.
    mouse.overlay(&st, &mem, false, &pic, 320, 320, 200);
    try t.expectEqual(grey, pic[100 * 320 + 160]);
    call(&st, &r, 0x0001);
    mouse.overlay(&st, &mem, false, &pic, 320, 320, 200);
    // (320, 100) virtual is pixel (160, 100): the arrow's tip is outline
    // (black), inside it white, past its edge the picture.
    try t.expectEqual(@as(u32, 0), pic[100 * 320 + 160]);
    try t.expectEqual(@as(u32, 0x00FFFFFF), pic[102 * 320 + 161]);
    try t.expectEqual(grey, pic[100 * 320 + 170]);
    // 09h: a 16x16 block of "invert" with the hot spot at its centre.
    const at: u32 = 0x5000;
    for (0..16) |i| {
        mem.wr16(at + @as(u32, @intCast(i * 2)), 0xFFFF);
        mem.wr16(at + 32 + @as(u32, @intCast(i * 2)), 0xFFFF);
    }
    r.setSeg(regs.ES, 0x0500);
    r.setBx(8);
    r.setCx(8);
    r.setDx(0);
    call(&st, &r, 0x0009);
    @memset(pic[0 .. 320 * 200], grey);
    mouse.overlay(&st, &mem, false, &pic, 320, 320, 200);
    try t.expectEqual(grey ^ 0x00FFFFFF, pic[92 * 320 + 152]);
    try t.expectEqual(grey ^ 0x00FFFFFF, pic[107 * 320 + 167]);
    try t.expectEqual(grey, pic[108 * 320 + 168]);
    try t.expectEqual(grey, pic[91 * 320 + 152]);
    // Hidden again (02h): the picture as it was.
    call(&st, &r, 0x0002);
    @memset(pic[0 .. 320 * 200], grey);
    mouse.overlay(&st, &mem, false, &pic, 320, 320, 200);
    try t.expectEqual(grey, pic[100 * 320 + 160]);

    // Text mode 3, 80x25 at 720x400: the cell under the cursor inverted.
    mem.wrB(0x40, 0x49, 0x03);
    mem.wrW(0x40, 0x4A, 80);
    mem.wrB(0x40, 0x84, 24);
    call(&st, &r, 0x0000);
    call(&st, &r, 0x0001);
    r.setCx(16); // column 2
    r.setDx(24); // row 3
    call(&st, &r, 0x0004);
    @memset(&pic, 0);
    mouse.overlay(&st, &mem, false, &pic, 720, 720, 400);
    try t.expectEqual(@as(u32, 0x00FFFFFF), pic[(3 * 16) * 720 + 2 * 9]);
    try t.expectEqual(@as(u32, 0x00FFFFFF), pic[(3 * 16 + 15) * 720 + 2 * 9 + 8]);
    try t.expectEqual(@as(u32, 0), pic[(3 * 16) * 720 + 3 * 9]);
    try t.expectEqual(@as(u32, 0), pic[(4 * 16) * 720 + 2 * 9]);
}
