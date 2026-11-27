//! XL330-M288-T typed control table and checked request/response operations.
const p = @import("dynamixel2.sig");
const t = @import("../sig_testing.sig");
pub const Error = p.Error || error{ Timeout, Transport, WrongId, Device, Model, Range, TorqueEnabled };
pub const model_number: u16 = 1200;
pub const Register = struct {
    pub const id = 7;
    pub const baud = 8;
    pub const mode = 11;
    pub const current_limit = 38;
    pub const torque = 64;
    pub const led = 65;
    pub const status_return = 68;
    pub const hardware_error = 70;
    pub const watchdog = 98;
    pub const goal_current = 102;
    pub const profile_acceleration = 108;
    pub const profile_velocity = 112;
    pub const goal_position = 116;
    pub const telemetry = 126;
};
pub const Bus = struct {
    context: *anyopaque,
    /// One half-duplex exchange; expected=254 means broadcast without response.
    exchange: *const fn (*anyopaque, []const u8, u8, *p.Status) Error!void,
};
pub const Telemetry = struct {
    current_ma: i16,
    velocity: i32,
    position: i32,
    voltage_mv: u16,
    temperature_c: u8,
    pub fn decode(bytes: []const u8) Error!Telemetry {
        if (bytes.len != 21) return error.Length;
        return .{ .current_ma = @bitCast(p.get16(bytes[0..2])), .velocity = @bitCast(p.get32(bytes[2..6])), .position = @bitCast(p.get32(bytes[6..10])), .voltage_mv = p.get16(bytes[18..20]) *| 100, .temperature_c = bytes[20] };
    }
};
pub const Servo = struct {
    id: u8,
    fn request(self: Servo, bus: Bus, packet: *const p.Packet, status: *p.Status) Error!void {
        if (self.id > 252) return error.Id;
        try bus.exchange(bus.context, packet.slice(), self.id, status);
        if (status.id != self.id) return error.WrongId;
        if (status.status_error != 0) return error.Device;
    }
    pub fn read(self: Servo, bus: Bus, address: u16, out: []u8) Error!void {
        var packet: p.Packet = .{};
        var status: p.Status = .{};
        try p.read(&packet, self.id, address, @intCast(out.len));
        try self.request(bus, &packet, &status);
        if (status.len != out.len) return error.Length;
        @memcpy(out, status.slice());
    }
    pub fn write(self: Servo, bus: Bus, address: u16, data: []const u8) Error!void {
        var packet: p.Packet = .{};
        var status: p.Status = .{};
        try p.write(&packet, self.id, address, data);
        try self.request(bus, &packet, &status);
        if (status.len != 0) return error.Length;
    }
    pub fn write16(self: Servo, bus: Bus, address: u16, value: u16) Error!void {
        var data: [2]u8 = undefined;
        p.put16(&data, value);
        try self.write(bus, address, &data);
    }
    pub fn write32(self: Servo, bus: Bus, address: u16, value: u32) Error!void {
        var data: [4]u8 = undefined;
        p.put32(&data, value);
        try self.write(bus, address, &data);
    }
    pub fn identify(self: Servo, bus: Bus) Error!u8 {
        var packet: p.Packet = .{};
        var status: p.Status = .{};
        try p.encode(&packet, self.id, 1, &.{});
        try self.request(bus, &packet, &status);
        if (status.len != 3) return error.Length;
        if (p.get16(status.data[0..2]) != model_number) return error.Model;
        return status.data[2];
    }
    pub fn torque(self: Servo, bus: Bus, enabled: bool) Error!void {
        try self.write(bus, Register.torque, &.{@intFromBool(enabled)});
    }
    /// EEPROM writes only while torque disabled. Read back each value.
    /// Current-based position mode ignores EEPROM position limits: caller MUST clamp goals.
    pub fn configure(self: Servo, bus: Bus, limit_ma: u16) Error!void {
        if (limit_ma == 0 or limit_ma > 150) return error.Range;
        _ = try self.identify(bus);
        try self.torque(bus, false);
        var b: [1]u8 = undefined;
        try self.read(bus, Register.torque, &b);
        if (b[0] != 0) return error.TorqueEnabled;
        try self.write(bus, Register.watchdog, &.{0});
        try self.write(bus, Register.mode, &.{5});
        try self.read(bus, Register.mode, &b);
        if (b[0] != 5) return error.Device;
        try self.write16(bus, Register.current_limit, limit_ma);
        var w: [2]u8 = undefined;
        try self.read(bus, Register.current_limit, &w);
        if (p.get16(&w) != limit_ma) return error.Device;
        try self.write16(bus, Register.goal_current, limit_ma);
        try self.write32(bus, Register.profile_acceleration, 10);
        try self.write32(bus, Register.profile_velocity, 20);
        // Hardware bus watchdog: 25 * 20 ms. Also supervised by host/controller watchdog.
        try self.write(bus, Register.watchdog, &.{25});
    }
    pub fn position(self: Servo, bus: Bus, goal: u16, low: u16, high: u16) Error!void {
        if (low > high or high > 4095 or goal < low or goal > high) return error.Range;
        try self.write32(bus, Register.goal_position, goal);
    }
    pub fn telemetry(self: Servo, bus: Bus) Error!Telemetry {
        var b: [21]u8 = undefined;
        try self.read(bus, Register.telemetry, &b);
        return Telemetry.decode(&b);
    }
    pub fn fault(self: Servo, bus: Bus) Error!u8 {
        var b: [1]u8 = undefined;
        try self.read(bus, Register.hardware_error, &b);
        return b[0];
    }
};
pub fn torqueOffAll(bus: Bus) Error!void {
    var packet: p.Packet = .{};
    var ignored: p.Status = .{};
    try p.write(&packet, 254, Register.torque, &.{0});
    try bus.exchange(bus.context, packet.slice(), 254, &ignored);
}
test "signed telemetry preserves negative current and position" {
    var b: [21]u8 = @splat(0);
    p.put16(b[0..2], @bitCast(@as(i16, -24)));
    p.put32(b[2..6], @bitCast(@as(i32, -17)));
    p.put32(b[6..10], @bitCast(@as(i32, -1)));
    p.put16(b[18..20], 50);
    b[20] = 35;
    const v = try Telemetry.decode(&b);
    try t.expect(v.current_ma == -24 and v.position == -1 and v.velocity == -17 and v.voltage_mv == 5000 and v.temperature_c == 35);
}
test "out of range motion is rejected before touching bus" {
    const Fake = struct {
        fn exchange(_: *anyopaque, _: []const u8, _: u8, _: *p.Status) Error!void {
            return error.Transport;
        }
    };
    var context: u8 = 0;
    const bus: Bus = .{ .context = &context, .exchange = Fake.exchange };
    try t.expectError(error.Range, (Servo{ .id = 1 }).position(bus, 1900, 2000, 2100));
    try t.expectError(error.Range, (Servo{ .id = 1 }).configure(bus, 151));
}

test "checked exchanges configure torque off and surface response faults" {
    const Mock = struct {
        table: [147]u8 = @splat(0),
        torque_off_seen: bool = false,
        writes: usize = 0,
        wrong_id: bool = false,
        device_error: bool = false,
        fn exchange(context: *anyopaque, bytes: []const u8, id: u8, status: *p.Status) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (p.crc(bytes[0 .. bytes.len - 2]) != p.get16(bytes[bytes.len - 2 ..])) return error.Crc;
            status.* = .{ .id = if (self.wrong_id) id + 1 else id, .status_error = if (self.device_error) @as(u8, 0x80) else 0 };
            if (bytes[7] == 1) {
                status.len = 3;
                p.put16(status.data[0..2], model_number);
                status.data[2] = 53;
                return;
            }
            const address = p.get16(bytes[8..10]);
            if (bytes[7] == 2) {
                const n = p.get16(bytes[10..12]);
                if (@as(usize, address) + n > self.table.len) return error.Range;
                status.len = n;
                @memcpy(status.data[0..n], self.table[address..][0..n]);
                return;
            }
            if (bytes[7] == 3) {
                const n = bytes.len - 12;
                if (@as(usize, address) + n > self.table.len) return error.Range;
                if (address == Register.torque and bytes[10] == 0) self.torque_off_seen = true;
                if (address < 64 and !self.torque_off_seen) return error.TorqueEnabled;
                @memcpy(self.table[address..][0..n], bytes[10..][0..n]);
                self.writes += 1;
                return;
            }
            return error.Instruction;
        }
    };
    var mock: Mock = .{};
    const bus: Bus = .{ .context = &mock, .exchange = Mock.exchange };
    const servo: Servo = .{ .id = 1 };
    try servo.configure(bus, 100);
    try t.expect(mock.torque_off_seen and mock.table[Register.mode] == 5 and p.get16(mock.table[Register.current_limit..][0..2]) == 100 and mock.table[Register.watchdog] == 25);
    try servo.position(bus, 2000, 1800, 2200);
    try t.expect(p.get32(mock.table[Register.goal_position..][0..4]) == 2000);
    mock.wrong_id = true;
    try t.expectError(error.WrongId, servo.identify(bus));
    mock.wrong_id = false;
    mock.device_error = true;
    try t.expectError(error.Device, servo.identify(bus));
}
