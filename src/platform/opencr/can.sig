//! bxCAN2 with shared CAN1 filter block. Standard/extended/RTR frames, no heap.
const hw = @import("board.sig");
const t = @import("../../core/sig_testing.sig");
pub const Frame = struct { id: u29, extended: bool = false, remote: bool = false, len: u4 = 0, data: [8]u8 = @splat(0) };
pub fn identifier(f: *const Frame) hw.Error!u32 {
    if (f.len > 8 or (!f.extended and f.id > 2047)) return error.Range;
    return (if (f.extended) (@as(u32, f.id) << 3) | 4 else @as(u32, f.id) << 21) | (if (f.remote) @as(u32, 2) else 0);
}
fn pack(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}
pub const Can = struct {
    poll: hw.Poll,
    pub fn init(baud: u32, loopback: bool, poll: hw.Poll) hw.Error!Can {
        if (baud != 125_000 and baud != 250_000 and baud != 500_000 and baud != 1_000_000) return error.Range;
        hw.bits(hw.rcc + 0x40, 0, (1 << 25) | (1 << 26));
        (hw.Pin{ .port = 1, .bit = 12 }).mode(2, 1, 9, false);
        (hw.Pin{ .port = 1, .bit = 13 }).mode(2, 0, 9, false);
        hw.write(0x40006800, 1 | (1 << 6)); // Automatic bus-off recovery.
        try hw.wait(0x40006804, 1, 1, hw.millis(), 25, poll);
        hw.write(0x4000681c, (54_000_000 / baud / 18 - 1) | (12 << 16) | (3 << 20) | if (loopback) @as(u32, 1 << 30) else 0);
        // Bank 14 assigned to CAN2, 32-bit mask, accepts all IDs into FIFO0.
        hw.bits(0x40006600, 63 << 8, (14 << 8) | 1);
        hw.bits(0x4000661c, 1 << 14, 0);
        hw.bits(0x40006604, 1 << 14, 0);
        hw.bits(0x4000660c, 0, 1 << 14);
        hw.bits(0x40006614, 1 << 14, 0);
        hw.write(0x400066b0, 0);
        hw.write(0x400066b4, 0);
        hw.bits(0x4000661c, 0, 1 << 14);
        hw.bits(0x40006600, 1, 0);
        hw.bits(0x40006800, 1, 0);
        try hw.wait(0x40006804, 1, 0, hw.millis(), 25, poll);
        return .{ .poll = poll };
    }
    pub fn send(self: *Can, frame: *const Frame) hw.Error!void {
        const tir = try identifier(frame);
        if (hw.read(0x40006818) & 4 != 0) return error.Transport;
        const free = (hw.read(0x40006808) >> 26) & 7;
        if (free == 0) return error.Busy;
        const index: u2 = if (free & 1 != 0) 0 else if (free & 2 != 0) 1 else 2;
        const a = 0x40006980 + @as(usize, index) * 16;
        hw.write(a + 4, frame.len);
        hw.write(a + 8, pack(frame.data[0..4]));
        hw.write(a + 12, pack(frame.data[4..8]));
        hw.write(0x40006808, @as(u32, 1) << (@as(u5, index) * 8));
        hw.write(a, tir | 1);
        const shift: u5 = @as(u5, index) * 8;
        const start = hw.millis();
        hw.wait(0x40006808, @as(u32, 1) << shift, @as(u32, 1) << shift, start, 25, self.poll) catch |err| {
            hw.write(0x40006808, @as(u32, 128) << shift);
            return err;
        };
        const result = hw.read(0x40006808);
        hw.write(0x40006808, @as(u32, 1) << shift);
        if (result & (@as(u32, 2) << shift) == 0) return error.Transport;
    }
    pub fn receive(_: *Can) hw.Error!?Frame {
        const fifo = hw.read(0x4000680c);
        if (fifo & 16 != 0) {
            hw.write(0x4000680c, 16);
            return error.Overflow;
        }
        if (fifo & 3 == 0) return null;
        defer hw.write(0x4000680c, 32);
        const id = hw.read(0x400069b0);
        const len = hw.read(0x400069b4) & 15;
        if (len > 8) return error.Range;
        var f: Frame = .{ .id = @intCast(if (id & 4 != 0) id >> 3 else id >> 21), .extended = id & 4 != 0, .remote = id & 2 != 0, .len = @intCast(len) };
        const low = hw.read(0x400069b8);
        const high = hw.read(0x400069bc);
        for (&f.data, 0..) |*byte, i| byte.* = @truncate((if (i < 4) low else high) >> @as(u5, @intCast((i % 4) * 8)));
        return f;
    }
    pub fn errorState(_: *Can) u32 {
        return hw.read(0x40006818);
    }
};
test "CAN identifiers preserve extended RTR and reject invalid standard frame" {
    try t.expect(try identifier(&.{ .id = 0x123 }) == 0x24600000);
    try t.expect((try identifier(&.{ .id = 0x1fffffff, .extended = true, .remote = true }) & 6) == 6);
    try t.expectError(error.Range, identifier(&.{ .id = 2048 }));
    try t.expectError(error.Range, identifier(&.{ .id = 1, .len = 9 }));
}
