//! Register-level MPU9250/AK8963 and ICM20648 drivers. Raw sensor axes, no fusion claims.
const t = @import("../sig_testing.sig");
pub const Error = error{ Timeout, Transport, Model, Length, Range };
pub const Bus = struct { context: *anyopaque, transfer: *const fn (*anyopaque, []const u8, []u8) Error!void, delay: *const fn (*anyopaque, u32) void };
pub const Model = enum(u8) { mpu9250 = 1, icm20648 = 2 };
pub const Sample = struct { accel: [3]i16, gyro: [3]i16, temperature_raw: i16, magnetic: ?[3]i16 = null };
pub const Imu = struct {
    bus: Bus,
    model: Model,
    mag_adjust: [3]u8 = @splat(128),
    pub fn detect(bus: Bus) Error!Imu {
        var self: Imu = .{ .bus = bus, .model = .mpu9250 };
        var id: [1]u8 = undefined;
        try self.readRegister(0x75, &id);
        if (id[0] == 0x71) return self;
        self.model = .icm20648;
        try self.readRegister(0, &id);
        if (id[0] != 0xe0) return error.Model;
        return self;
    }
    fn bank(self: *Imu, bank_index: u2) Error!void {
        var rx: [2]u8 = undefined;
        try self.bus.transfer(self.bus.context, &.{ 0x7f, @as(u8, bank_index) << 4 }, &rx);
    }
    pub fn readRegister(self: *Imu, address: u16, out: []u8) Error!void {
        if (out.len == 0 or out.len > 31 or address > 511) return error.Length;
        if (self.model == .icm20648) try self.bank(@intCast(address >> 7)) else if (address > 127) return error.Range;
        var tx: [32]u8 = @splat(0);
        var rx: [32]u8 = undefined;
        tx[0] = @as(u8, @intCast(address & 127)) | 128;
        try self.bus.transfer(self.bus.context, tx[0 .. out.len + 1], rx[0 .. out.len + 1]);
        @memcpy(out, rx[1 .. out.len + 1]);
    }
    pub fn writeRegister(self: *Imu, address: u16, value: u8) Error!void {
        if (address > 511) return error.Range;
        if (self.model == .icm20648) try self.bank(@intCast(address >> 7)) else if (address > 127) return error.Range;
        var rx: [2]u8 = undefined;
        try self.bus.transfer(self.bus.context, &.{ @intCast(address & 127), value }, &rx);
    }
    pub fn configure(self: *Imu) Error!void {
        if (self.model == .icm20648) {
            try self.writeRegister(6, 128);
            self.bus.delay(self.bus.context, 100);
            try self.writeRegister(6, 1);
            self.bus.delay(self.bus.context, 30);
            try self.writeRegister(3, 16);
            try self.writeRegister(7, 0);
            try self.writeRegister(0x101, 1); // Bank 2: +-250 dps, filtered.
            try self.writeRegister(0x114, 1); // +-2 g, filtered.
            try self.writeRegister(0x100, 10); // ~100 Hz gyro.
            try self.writeRegister(0x110, 0);
            try self.writeRegister(0x111, 10);
        } else {
            try self.writeRegister(0x6b, 128);
            self.bus.delay(self.bus.context, 100);
            try self.writeRegister(0x6b, 1);
            self.bus.delay(self.bus.context, 30);
            try self.writeRegister(0x6c, 0);
            try self.writeRegister(0x1a, 3);
            try self.writeRegister(0x19, 9);
            try self.writeRegister(0x1b, 0);
            try self.writeRegister(0x1c, 0);
            try self.writeRegister(0x1d, 3);
            try self.writeRegister(0x6a, 0x30);
            try self.writeRegister(0x24, 0x0d);
            try self.magWrite(0x0a, 0);
            self.bus.delay(self.bus.context, 1);
            try self.magWrite(0x0a, 0x0f);
            self.bus.delay(self.bus.context, 1);
            try self.magRead(0x10, &self.mag_adjust);
            for (self.mag_adjust) |adjust| if (adjust == 0 or adjust == 255) return error.Model;
            try self.magWrite(0x0a, 0);
            self.bus.delay(self.bus.context, 1);
            try self.magWrite(0x0a, 0x16);
            self.bus.delay(self.bus.context, 10);
            try self.writeRegister(0x25, 0x8c);
            try self.writeRegister(0x26, 2);
            try self.writeRegister(0x27, 0x88);
        }
    }
    fn magWrite(self: *Imu, reg: u8, value: u8) Error!void {
        try self.writeRegister(0x31, 0x0c);
        try self.writeRegister(0x32, reg);
        try self.writeRegister(0x33, value);
        try self.writeRegister(0x34, 128);
        var status: [1]u8 = undefined;
        for (0..20) |_| {
            try self.readRegister(0x36, &status);
            if (status[0] & 0x30 != 0) return error.Transport;
            if (status[0] & 64 != 0) return;
            self.bus.delay(self.bus.context, 1);
        }
        return error.Timeout;
    }
    fn magRead(self: *Imu, reg: u8, out: []u8) Error!void {
        try self.writeRegister(0x25, 0x8c);
        try self.writeRegister(0x26, reg);
        try self.writeRegister(0x27, 128 | @as(u8, @intCast(out.len)));
        self.bus.delay(self.bus.context, 10);
        try self.readRegister(0x49, out);
        try self.writeRegister(0x27, 0);
    }
    pub fn sample(self: *Imu) Error!Sample {
        var bytes: [14]u8 = undefined;
        try self.readRegister(if (self.model == .mpu9250) 0x3b else 0x2d, &bytes);
        var result = decode(self.model, &bytes);
        if (self.model == .mpu9250) {
            var mag: [8]u8 = undefined;
            try self.readRegister(0x49, &mag);
            if (mag[0] & 1 != 0 and mag[7] & 8 == 0) {
                var adjusted: [3]i16 = undefined;
                for (&adjusted, 0..) |*out, i| {
                    const raw: i16 = @bitCast(@as(u16, mag[1 + i * 2]) | (@as(u16, mag[2 + i * 2]) << 8));
                    const corrected = @as(i32, raw) * (@as(i32, self.mag_adjust[i]) + 128);
                    out.* = @intCast(@max(-32768, @min(32767, @divTrunc(corrected, 256))));
                }
                result.magnetic = adjusted;
            }
        }
        return result;
    }
};
fn signed(b: *const [2]u8) i16 {
    return @bitCast((@as(u16, b[0]) << 8) | b[1]);
}
pub fn decode(model: Model, b: *const [14]u8) Sample {
    var s: Sample = .{ .accel = undefined, .gyro = undefined, .temperature_raw = undefined };
    for (0..3) |i| {
        s.accel[i] = signed(b[i * 2 ..][0..2]);
        s.gyro[i] = signed(b[(if (model == .mpu9250) @as(usize, 8) else 6) + i * 2 ..][0..2]);
    }
    s.temperature_raw = signed(b[if (model == .mpu9250) @as(usize, 6) else 12..][0..2]);
    return s;
}
test "IMU revisions decode signed raw data with different temperature placement" {
    const data: [14]u8 = .{ 0xff, 0xfe, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7 };
    const m = decode(.mpu9250, &data);
    const i = decode(.icm20648, &data);
    try t.expect(m.accel[0] == -2 and m.temperature_raw == 4 and m.gyro[0] == 5);
    try t.expect(i.temperature_raw == 7 and i.gyro[0] == 4 and i.magnetic == null);
}
test "IMU rejects unknown WHOAMI rather than pretending revision compatibility" {
    const Mock = struct {
        fn transfer(_: *anyopaque, tx: []const u8, rx: []u8) Error!void {
            _ = tx;
            @memset(rx, 0);
        }
        fn delay(_: *anyopaque, _: u32) void {}
    };
    var ctx: u8 = 0;
    try t.expectError(error.Model, Imu.detect(.{ .context = &ctx, .transfer = Mock.transfer, .delay = Mock.delay }));
}

test "ICM banked configuration uses bank two and propagates SPI failure" {
    const Mock = struct {
        bank_index: u8 = 0,
        writes: u8 = 0,
        configured: bool = false,
        fail: bool = false,
        fn transfer(ctx: *anyopaque, tx: []const u8, rx: []u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fail) return error.Transport;
            @memset(rx, 0);
            if (tx[0] == 0x7f) {
                self.bank_index = tx[1] >> 4;
                return;
            }
            if (tx[0] == 0x80 and self.bank_index == 0) rx[1] = 0xe0;
            if (tx[0] & 128 == 0) {
                self.writes += 1;
                if (self.bank_index == 2 and tx[0] == 0x14 and tx[1] == 1) self.configured = true;
            }
        }
        fn delay(_: *anyopaque, _: u32) void {}
    };
    var ctx: Mock = .{};
    var imu = try Imu.detect(.{ .context = &ctx, .transfer = Mock.transfer, .delay = Mock.delay });
    try t.expect(imu.model == .icm20648);
    try imu.configure();
    try t.expect(ctx.configured and ctx.writes == 9);
    ctx.fail = true;
    try t.expectError(error.Transport, imu.sample());
}

test "MPU magnetic readiness overflow and signed fuse correction" {
    const Mock = struct {
        ready: u8 = 1,
        overflow: u8 = 0,
        fn transfer(ctx: *anyopaque, tx: []const u8, rx: []u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memset(rx, 0);
            if (tx[0] == 0xc9) {
                rx[1] = self.ready;
                rx[2] = 0;
                rx[3] = 0xff;
                rx[4] = 100;
                rx[8] = self.overflow;
            }
        }
        fn delay(_: *anyopaque, _: u32) void {}
    };
    var ctx: Mock = .{};
    var imu: Imu = .{ .bus = .{ .context = &ctx, .transfer = Mock.transfer, .delay = Mock.delay }, .model = .mpu9250, .mag_adjust = .{ 128, 192, 128 } };
    const first = try imu.sample();
    try t.expect(first.magnetic.?[0] == -256 and first.magnetic.?[1] == 125);
    ctx.overflow = 8;
    try t.expect((try imu.sample()).magnetic == null);
    ctx.overflow = 0;
    ctx.ready = 0;
    try t.expect((try imu.sample()).magnetic == null);
}
