//! Bounded USB bench diagnostics. Mutating peripherals requires fixture disarmed/power off.
const hw = @import("board.sig");
const io = @import("io.sig");
const spi = @import("spi.sig");
const i2c = @import("i2c.sig");
const uart = @import("uart.sig");
const can = @import("can.sig");
const rtc = @import("rtc.sig");
const flash = @import("flash.sig");
const imu = @import("../../core/device/opencr_imu.sig");
const wire = @import("../../core/device/slowwire_link.sig");
const p = @import("../../core/device/dynamixel2.sig");
pub const Diagnostics = struct {
    poll: hw.Poll,
    mux: io.Mux = .{},
    buzzer: io.Buzzer = .{},
    pwm_active: [6]bool = @splat(false),
    imu_spi: spi.Spi = undefined,
    sensor: ?imu.Imu = null,
    can_bus: ?can.Can = null,
    pub fn init(poll: hw.Poll) Diagnostics {
        var self: Diagnostics = .{ .poll = poll };
        self.mux.claim(&.{ hw.fixture_power, hw.robot_power, hw.direction, .{ .port = 2, .bit = 10 }, .{ .port = 2, .bit = 11 } }, .fixture) catch unreachable;
        self.mux.claim(&.{ .{ .port = 0, .bit = 11 }, .{ .port = 0, .bit = 12 } }, .usb) catch unreachable;
        self.mux.claim(&hw.leds, .fixture) catch unreachable;
        self.mux.claim(&hw.buttons, .fixture) catch unreachable;
        self.mux.claim(&.{ .{ .port = 0, .bit = 4 }, .{ .port = 0, .bit = 5 }, .{ .port = 0, .bit = 6 }, .{ .port = 1, .bit = 5 } }, .imu) catch unreachable;
        self.mux.claim(&.{.{ .port = 5, .bit = 14 }}, .fixture) catch unreachable;
        return self;
    }
    pub fn stop(self: *Diagnostics) void {
        self.buzzer.stop();
        for (&self.pwm_active, 0..) |*active, i| if (active.*) {
            io.pwmStop(i) catch {};
            active.* = false;
        };
        for (self.mux.owners, 0..) |port, group| for (port, 0..) |owner, bit| if (owner == .gpio) (hw.Pin{ .port = @intCast(group), .bit = @intCast(bit) }).value(false);
    }
    fn get(ctx: *anyopaque) *Diagnostics {
        return @ptrCast(@alignCast(ctx));
    }
    fn imuTransfer(ctx: *anyopaque, tx: []const u8, rx: []u8) imu.Error!void {
        get(ctx).imu_spi.transfer(.{ .port = 0, .bit = 4 }, tx, rx) catch |err| return if (err == error.Timeout) error.Timeout else error.Transport;
    }
    fn imuDelay(ctx: *anyopaque, ms: u32) void {
        hw.delay(ms, get(ctx).poll);
    }
    pub fn execute(self: *Diagnostics, f: *const wire.Frame, r: *wire.Frame, safe: bool) !void {
        if (f.op == .board) {
            if (f.len != 0) return error.Length;
            r.payload[1..4].* = .{ 3, 1, if (self.sensor) |sensor| @backingInt(sensor.model) else 0 };
            p.put32(r.payload[4..8], 216_000_000);
            p.put32(r.payload[8..12], 0x0000ffff);
            r.len = 12;
            return;
        }
        if (f.op != .board_io or f.len == 0) return error.Unsupported;
        const b = f.payload[0..f.len];
        // Pin/bus reconfiguration is kept out of an armed fixture's timing and power path.
        if (!safe and b[0] != 1) return error.Busy;
        switch (b[0]) {
            1 => { // raw button/DIP levels, low means asserted on push buttons
                if (b.len != 1) return error.Length;
                var levels: u8 = 0;
                for (hw.buttons, 0..) |pin, i| if (pin.input()) {
                    levels |= @as(u8, 1) << @as(u3, @intCast(i));
                };
                r.payload[1] = levels;
                r.len = 2;
            },
            2 => {
                if (b.len != 3 or b[1] == 0 or b[1] > 3 or b[2] > 1) return error.Range;
                hw.leds[b[1]].value(b[2] == 0);
            },
            3 => {
                if (b.len != 2) return error.Length;
                const a = try io.analog(b[1]);
                try self.mux.claim(&.{a.pin}, .adc);
                p.put16(r.payload[1..3], try io.adc(b[1], self.poll));
                r.len = 3;
            },
            4 => {
                if (b.len != 6 or b[1] >= 6) return error.Range;
                const index = b[1];
                const hz = p.get16(b[2..4]);
                const duty = p.get16(b[4..6]);
                _ = try io.pwmTiming(if (io.pwm_map[index].fast) 216_000_000 else 108_000_000, hz);
                if (duty > 1000) return error.Range;
                try self.mux.claim(&.{try io.pin(io.pwm_map[index].number)}, .pwm);
                try io.pwm(index, hz, duty);
                self.pwm_active[index] = true;
            },
            5 => {
                if (b.len != 4 or b[2] > 2 or b[3] > 1) return error.Range;
                // Only exposed user pins. Internal power, USB, LEDs, IMU and DXL are reserved.
                if (!((b[1] <= 21) or (b[1] >= 50 and b[1] <= 67) or (b[1] >= 40 and b[1] <= 45) or (b[1] >= 70 and b[1] <= 75))) return error.Range;
                const pin = try io.pin(b[1]);
                try self.mux.claim(&.{pin}, .gpio);
                if (b[2] == 1) pin.output(b[3] != 0) else pin.mode(0, if (b[2] == 2) 1 else 0, 0, false);
                r.payload[1] = @intFromBool(pin.input());
                r.len = 2;
            },
            6 => {
                if (b.len != 1) return error.Length;
                if (self.sensor == null) {
                    self.imu_spi = spi.Spi.init(.imu, 3, 7, self.poll);
                    (hw.Pin{ .port = 0, .bit = 4 }).output(true);
                    hw.delay(100, self.poll);
                    self.sensor = try imu.Imu.detect(.{ .context = self, .transfer = imuTransfer, .delay = imuDelay });
                    errdefer self.sensor = null;
                    try self.sensor.?.configure();
                }
                const sample = try self.sensor.?.sample();
                r.payload[1] = @backingInt(self.sensor.?.model);
                for (sample.accel, 0..) |v, i| p.put16(r.payload[2 + i * 2 ..][0..2], @bitCast(v));
                for (sample.gyro, 0..) |v, i| p.put16(r.payload[8 + i * 2 ..][0..2], @bitCast(v));
                p.put16(r.payload[14..16], @bitCast(sample.temperature_raw));
                r.payload[16] = @intFromBool(sample.magnetic != null);
                if (sample.magnetic) |mag| for (mag, 0..) |v, i| {
                    p.put16(r.payload[17 + i * 2 ..][0..2], @bitCast(v));
                };
                r.len = if (sample.magnetic != null) 23 else 17;
            },
            7 => {
                if (b.len < 5 or b[1] > 1 or b[2] > 127 or b[3] > 32 or b[4] > 32 or b.len != 5 + @as(usize, b[3])) return error.Range;
                const pins: [2]hw.Pin = if (b[1] == 0) .{ .{ .port = 1, .bit = 7 }, .{ .port = 1, .bit = 8 } } else .{ .{ .port = 1, .bit = 10 }, .{ .port = 1, .bit = 11 } };
                try self.mux.claim(&pins, .i2c);
                var bus = i2c.I2c.init(b[1] == 1, self.poll);
                try bus.transfer(@intCast(b[2]), b[5..], r.payload[1..][0..b[4]]);
                r.len = 1 + @as(usize, b[4]);
            },
            8 => {
                if (b.len < 3 or b.len > 34 or b[1] > 1) return error.Range;
                const numbers: [4]u8 = if (b[1] == 0) .{ 13, 12, 11, 10 } else .{ 58, 59, 60, 57 };
                var pins: [4]hw.Pin = undefined;
                for (numbers, 0..) |n, i| pins[i] = try io.pin(n);
                try self.mux.claim(&pins, .spi);
                pins[3].output(true);
                var bus = spi.Spi.init(if (b[1] == 0) .header else .expansion, 0, 7, self.poll);
                try bus.transfer(pins[3], b[2..], r.payload[1..][0 .. b.len - 2]);
                r.len = b.len - 1;
            },
            9 => {
                if (b.len != 3 or b[1] > 3 or b[2] > 1) return error.Range;
                try self.mux.claim(&.{ .{ .port = 1, .bit = 12 }, .{ .port = 1, .bit = 13 } }, .can);
                const rates = [_]u32{ 125_000, 250_000, 500_000, 1_000_000 };
                self.can_bus = try can.Can.init(rates[b[1]], b[2] == 1, self.poll);
            },
            10 => {
                if (b.len < 7 or b[5] > 3 or b[6] > 8 or b.len != 7 + @as(usize, b[6])) return error.Range;
                var bus = self.can_bus orelse return error.Busy;
                const id = p.get32(b[1..5]);
                if (id > 0x1fffffff) return error.Range;
                var frame: can.Frame = .{ .id = @intCast(id), .extended = b[5] & 1 != 0, .remote = b[5] & 2 != 0, .len = @intCast(b[6]) };
                @memcpy(frame.data[0..frame.len], b[7..]);
                try bus.send(&frame);
            },
            11 => {
                if (b.len != 1) return error.Length;
                var bus = self.can_bus orelse return error.Busy;
                if (try bus.receive()) |frame| {
                    r.payload[1] = 1;
                    p.put32(r.payload[2..6], frame.id);
                    r.payload[6] = @intFromBool(frame.extended) | (@as(u8, @intFromBool(frame.remote)) << 1);
                    r.payload[7] = frame.len;
                    @memcpy(r.payload[8..][0..frame.len], frame.data[0..frame.len]);
                    r.len = 8 + @as(usize, frame.len);
                } else {
                    r.payload[1] = 0;
                    r.len = 2;
                }
            },
            12 => {
                if (b.len < 5 or b[1] > 2 or b[2] > 2 or b[3] > 32 or b[4] > 32 or b.len != 5 + @as(usize, b[3])) return error.Range;
                const numbers: [2]u8 = switch (b[1]) {
                    0 => .{ 0, 1 },
                    1 => .{ 80, 81 },
                    else => .{ 82, 83 },
                };
                try self.mux.claim(&.{ try io.pin(numbers[0]), try io.pin(numbers[1]) }, .uart);
                const rates = [_]u32{ 9600, 57600, 115200 };
                var bus = try uart.Uart.init(switch (b[1]) {
                    0 => .header,
                    1 => .bt1,
                    else => .bt2,
                }, rates[b[2]], self.poll);
                try bus.write(b[5..]);
                r.len = 1 + try bus.read(r.payload[1..][0..b[4]], 50);
            },
            13 => {
                if (b.len != 1) return error.Length;
                try rtc.init(self.poll);
                const d = try rtc.read();
                p.put16(r.payload[1..3], d.year);
                r.payload[3..9].* = .{ d.month, d.day, d.weekday, d.hour, d.minute, d.second };
                r.len = 9;
            },
            14 => {
                if (b.len != 6 or b[5] > 32) return error.Range;
                try flash.read(p.get32(b[1..5]), r.payload[1..][0..b[5]]);
                r.len = 1 + @as(usize, b[5]);
            },
            15 => {
                if (b.len != 1) return error.Length;
                p.put32(r.payload[1..5], io.inputMillivolts(try io.adc(29, self.poll), 3300));
                r.len = 5;
            },
            16 => {
                if (b.len != 5) return error.Length;
                try self.buzzer.start(p.get16(b[1..3]), p.get16(b[3..5]));
            },
            17 => {
                if (b.len != 9) return error.Length;
                const date: rtc.DateTime = .{ .year = p.get16(b[1..3]), .month = b[3], .day = b[4], .weekday = b[5], .hour = b[6], .minute = b[7], .second = b[8] };
                if (!rtc.valid(date)) return error.Range;
                try rtc.init(self.poll);
                try rtc.set(date, self.poll);
            },
            18 => {
                if ((b.len != 3 and b.len != 7) or b[1] >= 32 or b[2] > 1 or (b[2] == 0 and b.len != 3) or (b[2] == 1 and b.len != 7)) return error.Range;
                try rtc.init(self.poll);
                if (b[2] == 1) try rtc.writeBackup(b[1], p.get32(b[3..7]));
                p.put32(r.payload[1..5], try rtc.backup(b[1]));
                r.len = 5;
            },
            else => return error.Unsupported,
        }
    }
};

test "OpenCR diagnostics reject peripheral mutation while armed and protect power pins" {
    const t = @import("../../core/sig_testing.sig");
    var d = Diagnostics.init(hw.idle);
    var r: wire.Frame = .{ .len = 1 };
    var f: wire.Frame = .{ .op = .board_io, .len = 4 };
    f.payload[0..4].* = .{ 5, 56, 1, 1 };
    try t.expectError(error.Busy, d.execute(&f, &r, false));
    try t.expectError(error.Busy, d.execute(&f, &r, true));
    f.payload[0..4].* = .{ 5, 32, 1, 1 };
    try t.expectError(error.Range, d.execute(&f, &r, true));
    try d.execute(&.{ .op = .board }, &r, false);
    try t.expect(r.len == 12 and r.payload[1] == 3 and p.get32(r.payload[4..8]) == 216_000_000);
}
