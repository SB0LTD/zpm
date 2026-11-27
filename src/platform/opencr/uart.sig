//! OpenCR UART6/header, USART2/BT1, USART3/Dynamixel, UART8/BT2.
const hw = @import("board.sig");
const p = @import("../../core/device/dynamixel2.sig");
const xl = @import("../../core/device/xl330.sig");
pub const Channel = enum { header, bt1, dynamixel, bt2 };
pub const Uart = struct {
    base: usize,
    poll: hw.Poll,
    pub fn init(channel: Channel, baud: u32, poll: hw.Poll) hw.Error!Uart {
        const fast = channel == .header;
        const clock: u32 = if (fast) 108_000_000 else 54_000_000;
        if (baud < 1200 or baud > 3_000_000) return error.Range;
        var tx: hw.Pin = undefined;
        var rx: hw.Pin = undefined;
        var af: u4 = 7;
        const base: usize = switch (channel) {
            .header => blk: {
                tx = .{ .port = 2, .bit = 6 };
                rx = .{ .port = 2, .bit = 7 };
                af = 8;
                hw.bits(hw.rcc + 0x44, 0, 1 << 5);
                break :blk 0x40011400;
            },
            .bt1 => blk: {
                tx = .{ .port = 3, .bit = 5 };
                rx = .{ .port = 3, .bit = 6 };
                hw.bits(hw.rcc + 0x40, 0, 1 << 17);
                break :blk 0x40004400;
            },
            .dynamixel => blk: {
                tx = .{ .port = 2, .bit = 10 };
                rx = .{ .port = 2, .bit = 11 };
                hw.bits(hw.rcc + 0x40, 0, 1 << 18);
                break :blk 0x40004800;
            },
            .bt2 => blk: {
                tx = .{ .port = 4, .bit = 1 };
                rx = .{ .port = 4, .bit = 0 };
                af = 8;
                hw.bits(hw.rcc + 0x40, 0, 1 << 31);
                break :blk 0x40007c00;
            },
        };
        tx.mode(2, 1, af, false);
        rx.mode(2, 1, af, false);
        hw.write(base, 0);
        hw.write(base + 4, 0);
        hw.write(base + 8, 0);
        hw.write(base + 0xc, (clock + baud / 2) / baud);
        hw.write(base + 0x20, 0xffffffff);
        hw.write(base, 1 | 4 | 8);
        return .{ .base = base, .poll = poll };
    }
    pub fn receive(self: *Uart) hw.Error!?u8 {
        const flags = hw.read(self.base + 0x1c);
        if (flags & 15 != 0) {
            hw.write(self.base + 0x20, 15);
            return error.Transport;
        }
        if (flags & 32 == 0) return null;
        return @truncate(hw.read(self.base + 0x24));
    }
    pub fn write(self: *Uart, bytes: []const u8) hw.Error!void {
        const start = hw.millis();
        for (bytes) |byte| {
            try hw.wait(self.base + 0x1c, 128, 128, start, 100, self.poll);
            hw.write(self.base + 0x28, byte);
        }
        try hw.wait(self.base + 0x1c, 64, 64, start, 100, self.poll);
    }
    pub fn read(self: *Uart, out: []u8, timeout_ms: u32) hw.Error!usize {
        const start = hw.millis();
        var n: usize = 0;
        while (n < out.len) {
            if (try self.receive()) |byte| {
                out[n] = byte;
                n += 1;
            } else {
                self.poll();
                if (hw.millis() -% start >= timeout_ms) break;
            }
        }
        return n;
    }
    pub fn flush(self: *Uart) void {
        while (hw.read(self.base + 0x1c) & 32 != 0) _ = hw.read(self.base + 0x24);
        hw.write(self.base + 0x20, 15);
    }
};
pub const Dxl = struct {
    uart: Uart,
    pub fn init(poll: hw.Poll) Dxl {
        hw.direction.output(false);
        return .{ .uart = Uart.init(.dynamixel, 57600, poll) catch unreachable };
    }
    fn exchange(ctx: *anyopaque, bytes: []const u8, expected: u8, status: *p.Status) xl.Error!void {
        const self: *Dxl = @ptrCast(@alignCast(ctx));
        self.uart.flush();
        hw.bits(self.uart.base, 4, 0);
        hw.direction.value(true);
        defer {
            hw.direction.value(false);
            hw.bits(self.uart.base, 0, 4);
        }
        self.uart.write(bytes) catch |err| return if (err == error.Timeout) error.Timeout else error.Transport;
        self.uart.flush();
        hw.bits(self.uart.base, 0, 4);
        hw.direction.value(false);
        if (expected == 254) return;
        var receiver: p.Receiver = .{};
        const start = hw.millis();
        while (hw.millis() -% start < 40) {
            self.uart.poll();
            if (self.uart.receive() catch return error.Transport) |byte| {
                if (receiver.feed(byte)) |packet| {
                    try p.decode(packet, status);
                    if (status.id != expected) return error.WrongId;
                    return;
                }
            }
        }
        return error.Timeout;
    }
    pub fn bus(self: *Dxl) xl.Bus {
        return .{ .context = self, .exchange = exchange };
    }
};
