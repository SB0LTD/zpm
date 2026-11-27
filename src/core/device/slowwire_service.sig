//! Shared commissioning and gait service for embedded controllers and direct USB adapters.
const p = @import("dynamixel2.sig");
const xl = @import("xl330.sig");
const wire = @import("slowwire_link.sig");
const fixture = @import("slowwire.sig");
pub const Clock = struct { context: *anyopaque, now: *const fn (*anyopaque) u32, delay: *const fn (*anyopaque, u32) void, power: ?*const fn (*anyopaque, bool) void = null };
pub const Service = struct {
    bus: xl.Bus,
    clock: Clock,
    controller: fixture.Controller = .{},
    powered: bool = true,
    next_axis: usize = 0,
    last_sample: u32 = 0,
    pub fn ensurePower(self: *Service) xl.Error!void {
        if (self.powered) return;
        if (self.clock.power) |power| {
            power(self.clock.context, true);
            self.clock.delay(self.clock.context, 300);
            self.powered = true;
            try xl.torqueOffAll(self.bus);
        } else return error.Transport;
    }
    fn servo(index: usize) xl.Servo {
        return .{ .id = @intCast(index + 1) };
    }
    pub fn stop(self: *Service, latch: bool) void {
        if (latch) self.controller.trip() else self.controller.stop();
        xl.torqueOffAll(self.bus) catch {};
        if (self.clock.power) |power| {
            power(self.clock.context, false);
            self.powered = false;
            for (&self.controller.axes) |*a| {
                a.configured = false;
                a.seen = false;
            }
        }
    }
    pub fn refresh(self: *Service, index: usize) xl.Error!void {
        if (!self.powered) return error.Transport;
        const s = servo(index);
        const sample = try s.telemetry(self.bus);
        const err = try s.fault(self.bus);
        self.controller.update(index, sample, err, self.clock.now(self.clock.context));
    }
    fn goals(self: *Service) xl.Error!void {
        var records: [15]u8 = undefined;
        for (self.controller.targets, 0..) |goal, i| {
            records[i * 5] = @intCast(i + 1);
            p.put32(records[i * 5 + 1 ..][0..4], goal);
        }
        var packet: p.Packet = .{};
        var ignored: p.Status = .{};
        try p.syncWrite(&packet, xl.Register.goal_position, 4, &records);
        try self.bus.exchange(self.bus.context, packet.slice(), 254, &ignored);
    }
    pub fn execute(self: *Service, f: *const wire.Frame, r: *wire.Frame) !void {
        switch (f.op) {
            .hello => {
                if (f.len != 0) return error.Length;
                r.payload[1..7].* = .{ 1, 3, 0xb0, 4, 1, 0 };
                r.len = 7;
            },
            .heartbeat => {
                if (f.len != 0) return error.Length;
                self.controller.heartbeat(self.clock.now(self.clock.context));
            },
            .stop => {
                if (f.len != 0) return error.Length;
                self.stop(false);
            },
            .identify => {
                if (f.len != 1 or f.payload[0] >= 3) return error.Range;
                try self.ensurePower();
                r.payload[1] = try servo(f.payload[0]).identify(self.bus);
                r.len = 2;
            },
            .configure => {
                if (f.len != 3 or f.payload[0] >= 3) return error.Range;
                if (self.controller.state == .armed or self.controller.state == .running) return error.Busy;
                const index = f.payload[0];
                const limit = p.get16(f.payload[1..3]);
                try self.ensurePower();
                try servo(index).configure(self.bus, limit);
                self.controller.axes[index].configured = true;
                self.controller.axes[index].current_limit = limit;
                try self.refresh(index);
            },
            .telemetry => {
                if (f.len != 1 or f.payload[0] >= 3) return error.Range;
                const index = f.payload[0];
                try self.refresh(index);
                const a = self.controller.axes[index];
                r.payload[1] = index;
                p.put16(r.payload[2..4], @bitCast(a.sample.current_ma));
                p.put32(r.payload[4..8], @bitCast(a.sample.velocity));
                p.put32(r.payload[8..12], @bitCast(a.sample.position));
                p.put16(r.payload[12..14], a.sample.voltage_mv);
                r.payload[14] = a.sample.temperature_c;
                r.payload[15] = a.fault;
                r.payload[16] = @backingInt(self.controller.state);
                r.len = 17;
            },
            .calibrate => {
                if (f.len != 9 or f.payload[0] >= 3) return error.Range;
                try self.controller.calibrate(f.payload[0], .{ .low = p.get16(f.payload[1..3]), .high = p.get16(f.payload[3..5]), .released = p.get16(f.payload[5..7]), .engaged = p.get16(f.payload[7..9]) });
            },
            .arm => {
                if (f.len != 0) return error.Length;
                for (0..3) |i| try self.refresh(i);
                try self.controller.arm(self.clock.now(self.clock.context));
                try self.goals();
                for (0..3) |i| try servo(i).torque(self.bus, true);
            },
            .jog => {
                if (f.len != 3) return error.Length;
                try self.controller.jog(f.payload[0], p.get16(f.payload[1..3]));
                try self.goals();
            },
            .run => {
                if (f.len != 1) return error.Length;
                try self.controller.run(f.payload[0], self.clock.now(self.clock.context));
                try self.goals();
            },
            .provision => {
                if (f.len != 1 or f.payload[0] < 1 or f.payload[0] > 3) return error.Range;
                if (self.controller.state != .disarmed) return error.Busy;
                for (self.controller.axes) |a| if (a.configured) return error.Busy;
                // Physically connect only ONE factory-default servo for this operation.
                try self.ensurePower();
                _ = try (xl.Servo{ .id = 1 }).identify(self.bus);
                try (xl.Servo{ .id = 1 }).torque(self.bus, false);
                var packet: p.Packet = .{};
                var ignored: p.Status = .{};
                try p.write(&packet, 254, xl.Register.id, f.payload[0..1]);
                try self.bus.exchange(self.bus.context, packet.slice(), 254, &ignored);
                self.clock.delay(self.clock.context, 50);
                _ = try (xl.Servo{ .id = f.payload[0] }).identify(self.bus);
            },
            else => return error.Unsupported,
        }
    }

    pub fn tick(self: *Service) void {
        const now = self.clock.now(self.clock.context);
        if (now -% self.last_sample >= 20) {
            self.last_sample = now;
            if (self.controller.axes[self.next_axis].configured) self.refresh(self.next_axis) catch {
                self.stop(true);
            };
            self.next_axis = (self.next_axis + 1) % 3;
        }
        const before = self.controller.state;
        const changed = self.controller.tick(self.clock.now(self.clock.context));
        if (changed) self.goals() catch {
            self.stop(true);
        };
        if (before != .fault and self.controller.state == .fault) self.stop(true);
    }
};

const t = @import("../sig_testing.sig");
const Mock = struct {
    time: u32 = 10,
    on: bool = false,
    fail: bool = false,
    broadcasts: usize = 0,
    memory: [3][160]u8 = @splat(@splat(0)),
    fn get(ctx: *anyopaque) *Mock {
        return @ptrCast(@alignCast(ctx));
    }
    fn now(ctx: *anyopaque) u32 {
        return get(ctx).time;
    }
    fn delay(ctx: *anyopaque, ms: u32) void {
        get(ctx).time +%= ms;
    }
    fn power(ctx: *anyopaque, on: bool) void {
        get(ctx).on = on;
    }
    fn exchange(ctx: *anyopaque, bytes: []const u8, id: u8, out: *p.Status) xl.Error!void {
        const self = get(ctx);
        if (self.fail) return error.Transport;
        if (id == 254) {
            self.broadcasts += 1;
            if (bytes[7] == 3 and p.get16(bytes[8..10]) == xl.Register.torque)
                for (&self.memory) |*m| {
                    m[xl.Register.torque] = bytes[10];
                };
            return;
        }
        if (id < 1 or id > 3) return error.WrongId;
        out.* = .{ .id = id };
        switch (bytes[7]) {
            1 => {
                out.len = 3;
                p.put16(out.data[0..2], xl.model_number);
                out.data[2] = 46;
            },
            2 => {
                const addr = p.get16(bytes[8..10]);
                const n = p.get16(bytes[10..12]);
                if (addr + n > 160) return error.Range;
                out.len = n;
                @memcpy(out.data[0..n], self.memory[id - 1][addr..][0..n]);
            },
            3 => {
                const addr = p.get16(bytes[8..10]);
                const n = bytes.len - 12;
                if (addr + n > 160) return error.Range;
                @memcpy(self.memory[id - 1][addr..][0..n], bytes[10..][0..n]);
            },
            else => return error.Instruction,
        }
    }
    fn service(self: *Mock, switched: bool) Service {
        for (&self.memory) |*m| {
            p.put32(m[132..136], 2000);
            p.put16(m[144..146], 50);
            m[146] = 30;
        }
        return .{ .bus = .{ .context = self, .exchange = exchange }, .clock = .{ .context = self, .now = now, .delay = delay, .power = if (switched) power else null }, .powered = !switched };
    }
    fn configured(self: *Mock, switched: bool) !Service {
        var s = self.service(switched);
        var reply: wire.Frame = .{};
        for (0..3) |i| {
            var request: wire.Frame = .{ .op = .configure, .len = 3 };
            request.payload[0] = @intCast(i);
            p.put16(request.payload[1..3], 100);
            try s.execute(&request, &reply);
            try s.controller.calibrate(i, .{ .low = 1800, .high = 2200, .released = 1900, .engaged = 2100 });
        }
        s.controller.heartbeat(self.time);
        try s.execute(&.{ .op = .arm }, &reply);
        return s;
    }
};
test "OpenRB service starts powered off and watchdog cuts power and invalidates configuration" {
    var mock: Mock = .{};
    var s = mock.service(true);
    try t.expect(!s.powered and !mock.on and s.controller.state == .disarmed);
    s = try mock.configured(true);
    try t.expect(s.powered and mock.on and mock.memory[0][64] == 1);
    mock.time += 501;
    s.tick();
    try t.expect(s.controller.state == .fault and !s.powered and !mock.on);
    for (s.controller.axes) |a| try t.expect(!a.configured and !a.seen);
}
test "OpenRB power cut survives broken bus and re-enable remains disarmed" {
    var mock: Mock = .{};
    var s = try mock.configured(true);
    mock.fail = true;
    mock.time += 30;
    s.tick();
    try t.expect(s.controller.state == .fault and !mock.on);
    mock.fail = false;
    s.stop(false);
    try s.ensurePower();
    try t.expect(mock.on and s.controller.state == .disarmed and mock.memory[0][64] == 0);
    try t.expect(mock.broadcasts >= 3);
    var reply: wire.Frame = .{};
    try t.expectError(error.Unconfigured, s.execute(&.{ .op = .arm }, &reply));
}
test "U2D2 shared service sends torque-off on lost heartbeat without a power callback" {
    var mock: Mock = .{};
    var s = try mock.configured(false);
    const prior = mock.broadcasts;
    mock.time += 501;
    s.tick();
    try t.expect(s.controller.state == .fault and mock.broadcasts == prior + 1);
}
test "measured servo overtemperature reaches shared service fault handling" {
    var mock: Mock = .{};
    var s = try mock.configured(true);
    mock.memory[0][146] = 55;
    mock.time += 30;
    s.tick();
    try t.expect(s.controller.state == .fault and !mock.on);
}
