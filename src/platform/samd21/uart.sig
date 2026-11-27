//! SERCOM2 PA12/PA13, 57600 8N1. OpenRB handles TTL direction in hardware.
const hw = @import("board.sig");
const p = @import("../../core/device/dynamixel2.sig");
const xl = @import("../../core/device/xl330.sig");
const base = 0x42001000;
pub const Uart = struct {
    poll: *const fn () void,
    fn sync() void {
        while (hw.read(base + 0x1c) != 0) hw.cycles();
    }
    pub fn init(poll: *const fn () void) Uart {
        hw.write(0x40000420, hw.read(0x40000420) | (1 << 4));
        hw.peripheralClock(22);
        hw.mux(12, 2, false);
        hw.mux(13, 2, true);
        hw.write(base, 1);
        sync();
        hw.write(base, (1 << 2) | (1 << 20) | (1 << 30));
        hw.write16(base + 0xc, 64278);
        hw.write(base + 4, (1 << 16) | (1 << 17));
        sync();
        hw.write(base, hw.read(base) | 2);
        sync();
        return .{ .poll = poll };
    }
    fn flush() void {
        while (hw.read8(base + 0x18) & 4 != 0) _ = hw.read16(base + 0x28);
        hw.write16(base + 0x1a, 7);
        hw.write8(base + 0x18, 128);
    }
    fn timed(self: *Uart, start: u32, limit: u32) xl.Error!void {
        self.poll();
        if (hw.millis() -% start > limit) return error.Timeout;
    }
    fn exchange(ctx: *anyopaque, bytes: []const u8, expected: u8, status: *p.Status) xl.Error!void {
        const self: *Uart = @ptrCast(@alignCast(ctx));
        flush();
        hw.write(base + 4, 1 << 16);
        sync();
        defer {
            hw.write(base + 4, (1 << 16) | (1 << 17));
            sync();
        }
        hw.write8(base + 0x18, 2);
        const start = hw.millis();
        for (bytes) |byte| {
            while (hw.read8(base + 0x18) & 1 == 0) try self.timed(start, 80);
            hw.write16(base + 0x28, byte);
        }
        while (hw.read8(base + 0x18) & 2 == 0) try self.timed(start, 80);
        flush();
        hw.write(base + 4, (1 << 16) | (1 << 17));
        sync();
        if (expected == 254) return;
        var receiver: p.Receiver = .{};
        const begun = hw.millis();
        while (true) {
            try self.timed(begun, 40);
            if (hw.read16(base + 0x1a) & 7 != 0) {
                flush();
                return error.Transport;
            }
            if (hw.read8(base + 0x18) & 4 == 0) continue;
            if (receiver.feed(@truncate(hw.read16(base + 0x28)))) |packet| {
                try p.decode(packet, status);
                if (status.id != expected) return error.WrongId;
                return;
            }
        }
    }
    pub fn bus(self: *Uart) xl.Bus {
        return .{ .context = self, .exchange = exchange };
    }
};
