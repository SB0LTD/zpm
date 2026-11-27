//! STM32F7 I2Cv2 7-bit master, 100 kHz, bounded repeated-start transfers.
const hw = @import("board.sig");
pub const I2c = struct {
    base: usize,
    poll: hw.Poll,
    pub fn init(second: bool, poll: hw.Poll) I2c {
        const base: usize = if (second) 0x40005800 else 0x40005400;
        hw.bits(hw.rcc + 0x40, 0, @as(u32, 1) << if (second) @as(u5, 22) else 21);
        const scl: hw.Pin = .{ .port = 1, .bit = if (second) 10 else 8 };
        const sda: hw.Pin = .{ .port = 1, .bit = if (second) 11 else 7 };
        scl.mode(2, 0, 4, true);
        sda.mode(2, 0, 4, true);
        hw.write(base, 0);
        // 54 MHz APB clock: prescaler /6, 9 MHz tick, ~100 kHz with rise/filter margin.
        hw.write(base + 0x10, (5 << 28) | (3 << 20) | (3 << 16) | (40 << 8) | 44);
        hw.write(base + 0x1c, 0x3f38);
        hw.write(base, 1);
        return .{ .base = base, .poll = poll };
    }
    fn awaitFlag(self: *I2c, mask: u32, begun: u32) hw.Error!void {
        while (true) {
            const flags = hw.read(self.base + 0x18);
            if (flags & 16 != 0) return error.Nack;
            if (flags & 256 != 0) return error.Transport;
            if (flags & 512 != 0) return error.Arbitration;
            if (flags & mask != 0) return;
            self.poll();
            if (hw.millis() -% begun > 25) return error.Timeout;
        }
    }
    fn start(self: *I2c, addr: u7, n: usize, input: bool, stop: bool) void {
        hw.write(self.base + 4, (@as(u32, addr) << 1) | (if (input) @as(u32, 1 << 10) else 0) | (@as(u32, @intCast(n)) << 16) | (if (stop) @as(u32, 1 << 25) else 0) | (1 << 13));
    }
    pub fn transfer(self: *I2c, addr: u7, tx: []const u8, rx: []u8) hw.Error!void {
        if (addr < 8 or addr > 119 or tx.len > 255 or rx.len > 255 or tx.len + rx.len == 0) return error.Range;
        const start_ms = hw.millis();
        try hw.wait(self.base + 0x18, 1 << 15, 0, start_ms, 25, self.poll);
        hw.write(self.base + 0x1c, 0x3f38);
        var complete = false;
        defer if (!complete) {
            hw.bits(self.base + 4, 0, 1 << 14);
            hw.write(self.base, 0);
            hw.write(self.base + 0x1c, 0x3f38);
            hw.write(self.base, 1);
        };
        if (tx.len != 0) {
            self.start(addr, tx.len, false, rx.len == 0);
            for (tx) |byte| {
                try self.awaitFlag(2, start_ms);
                hw.write8(self.base + 0x28, byte);
            }
            try self.awaitFlag(if (rx.len == 0) 32 else 64, start_ms);
        }
        if (rx.len != 0) {
            self.start(addr, rx.len, true, true);
            for (rx) |*byte| {
                try self.awaitFlag(4, start_ms);
                byte.* = hw.read8(self.base + 0x24);
            }
            try self.awaitFlag(32, start_ms);
        }
        hw.write(self.base + 0x1c, 32);
        complete = true;
    }
};
