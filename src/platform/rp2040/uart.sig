//! UART0 TTL half-duplex with an active-low OE buffer on GPIO2.
const hw = @import("board.sig");
const p = @import("../../core/device/dynamixel2.sig");
const xl = @import("../../core/device/xl330.sig");
const uart = 0x40034000;
pub const Uart = struct {
    poll: *const fn () void,
    pub fn init(poll: *const fn () void) Uart {
        hw.gpioOutput(2, true);
        hw.gpioFunction(0, 2);
        hw.gpioFunction(1, 2);
        // 125 MHz / (16 * 57600) = 135 + 41/64; default XL330 baud.
        hw.write(uart + 0x30, 0);
        hw.write(uart + 0x24, 135);
        hw.write(uart + 0x28, 41);
        hw.write(uart + 0x2c, (3 << 5) | (1 << 4));
        hw.write(uart + 0x30, (1 << 9) | (1 << 8) | 1);
        return .{ .poll = poll };
    }
    fn flush() void {
        while (hw.read(uart + 0x18) & (1 << 4) == 0) _ = hw.read(uart);
        hw.write(uart + 4, 0);
    }
    fn timed(self: *Uart, start: u32, limit: u32) xl.Error!void {
        self.poll();
        if (hw.micros() -% start > limit) return error.Timeout;
    }
    fn exchange(context: *anyopaque, bytes: []const u8, expected: u8, status: *p.Status) xl.Error!void {
        const self: *Uart = @ptrCast(@alignCast(context));
        flush();
        hw.gpioSet(2, false);
        defer hw.gpioSet(2, true);
        const start = hw.micros();
        for (bytes) |b| {
            while (hw.read(uart + 0x18) & (1 << 5) != 0) try self.timed(start, 50_000);
            hw.write(uart, b);
        }
        while (hw.read(uart + 0x18) & (1 << 3) != 0) try self.timed(start, 50_000);
        // Receiver sees our TX echo. Discard it before enabling servo responses.
        flush();
        hw.gpioSet(2, true);
        if (expected == 254) return;
        var receiver: p.Receiver = .{};
        const response_start = hw.micros();
        while (true) {
            try self.timed(response_start, 30_000);
            if (hw.read(uart + 0x18) & (1 << 4) != 0) continue;
            const word = hw.read(uart);
            if (word & 0xf00 != 0) {
                hw.write(uart + 4, 0);
                return error.Transport;
            }
            if (receiver.feed(@truncate(word))) |packet| {
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
