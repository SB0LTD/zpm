//! Polled 8-bit full-duplex SPI, caller-selected CS. SPI1 is reserved for onboard IMU.
const hw = @import("board.sig");
pub const Channel = enum { imu, header, expansion };
pub const Spi = struct {
    base: usize,
    poll: hw.Poll,
    pub fn init(channel: Channel, mode: u2, divider: u3, poll: hw.Poll) Spi {
        var clk: hw.Pin = undefined;
        var miso: hw.Pin = undefined;
        var mosi: hw.Pin = undefined;
        const base: usize = switch (channel) {
            .imu => blk: {
                clk = .{ .port = 0, .bit = 5 };
                miso = .{ .port = 0, .bit = 6 };
                mosi = .{ .port = 1, .bit = 5 };
                hw.bits(hw.rcc + 0x44, 0, 1 << 12);
                break :blk 0x40013000;
            },
            .header => blk: {
                clk = .{ .port = 0, .bit = 9 };
                miso = .{ .port = 1, .bit = 14 };
                mosi = .{ .port = 1, .bit = 15 };
                hw.bits(hw.rcc + 0x40, 0, 1 << 14);
                break :blk 0x40003800;
            },
            .expansion => blk: {
                clk = .{ .port = 4, .bit = 12 };
                miso = .{ .port = 4, .bit = 13 };
                mosi = .{ .port = 4, .bit = 14 };
                hw.bits(hw.rcc + 0x44, 0, 1 << 13);
                break :blk 0x40013400;
            },
        };
        clk.mode(2, 0, 5, false);
        miso.mode(2, 0, 5, false);
        mosi.mode(2, 0, 5, false);
        hw.write(base, 0);
        hw.write(base + 4, (7 << 8) | (1 << 12));
        hw.write(base, @as(u32, mode) | 4 | (@as(u32, divider) << 3) | (1 << 8) | (1 << 9) | 64);
        return .{ .base = base, .poll = poll };
    }
    pub fn byte(self: *Spi, value: u8) hw.Error!u8 {
        const start = hw.millis();
        try hw.wait(self.base + 8, 2, 2, start, 20, self.poll);
        hw.write8(self.base + 0xc, value);
        try hw.wait(self.base + 8, 1, 1, start, 20, self.poll);
        return hw.read8(self.base + 0xc);
    }
    pub fn transfer(self: *Spi, cs: hw.Pin, tx: []const u8, rx: []u8) hw.Error!void {
        if (tx.len != rx.len or tx.len > 256) return error.Range;
        cs.output(false);
        defer cs.value(true);
        for (tx, rx) |value, *out| out.* = try self.byte(value);
        try hw.wait(self.base + 8, 128, 0, hw.millis(), 20, self.poll);
        if (hw.read(self.base + 8) & (1 << 6) != 0) {
            _ = hw.read(self.base + 0xc);
            _ = hw.read(self.base + 8);
            return error.Overflow;
        }
    }
};
