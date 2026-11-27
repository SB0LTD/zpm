//! Feedback-supervised three-axis fixture. Calibration is RAM-only; boot is disarmed.
const t = @import("../sig_testing.sig");
const xl = @import("xl330.sig");
pub const Error = error{ Range, Unconfigured, Uncalibrated, NotArmed, Busy, Stale, Fault };
pub const Calibration = struct { low: u16 = 0, high: u16 = 0, released: u16 = 0, engaged: u16 = 0, valid: bool = false };
pub const Axis = struct { calibration: Calibration = .{}, configured: bool = false, seen: bool = false, sample_ms: u32 = 0, current_limit: u16 = 100, sample: xl.Telemetry = .{ .current_ma = 0, .velocity = 0, .position = 0, .voltage_mv = 0, .temperature_c = 0 }, fault: u8 = 0 };
pub const State = enum { disarmed, armed, running, fault };
pub const Controller = struct {
    axes: [3]Axis = @splat(.{}),
    state: State = .disarmed,
    last_host_ms: u32 = 0,
    has_host: bool = false,
    targets: [3]u16 = @splat(0),
    phase: u8 = 0,
    phases_left: u8 = 0,
    phase_started: u32 = 0,
    settled_since: ?u32 = null,
    pub fn heartbeat(self: *Controller, now: u32) void {
        self.has_host = true;
        self.last_host_ms = now;
    }
    pub fn stop(self: *Controller) void {
        self.state = .disarmed;
        self.phases_left = 0;
        self.settled_since = null;
    }
    pub fn trip(self: *Controller) void {
        self.state = .fault;
        self.phases_left = 0;
        self.settled_since = null;
    }
    pub fn calibrate(self: *Controller, index: usize, c: Calibration) Error!void {
        if (index >= 3 or c.high > 4095 or c.low >= c.high or c.high - c.low > 512 or c.released < c.low or c.released > c.high or c.engaged < c.low or c.engaged > c.high or c.released == c.engaged) return error.Range;
        if (self.state == .armed or self.state == .running) return error.Busy;
        self.axes[index].calibration = c;
        self.axes[index].calibration.valid = true;
    }
    pub fn update(self: *Controller, index: usize, sample: xl.Telemetry, fault: u8, now: u32) void {
        self.axes[index].sample = sample;
        self.axes[index].sample_ms = now;
        self.axes[index].seen = true;
        self.axes[index].fault = fault;
    }
    pub fn healthy(self: *const Controller, now: u32) bool {
        if (!self.has_host or now -% self.last_host_ms > 500) return false;
        for (self.axes) |a| {
            if (!a.configured or !a.seen or now -% a.sample_ms > 250 or a.fault != 0 or a.sample.voltage_mv < 4500 or a.sample.voltage_mv > 5500 or a.sample.temperature_c >= 55) return false;
            const current: i32 = a.sample.current_ma;
            if (current > @as(i32, a.current_limit) + 25 or current < -@as(i32, a.current_limit) - 25) return false;
            if (a.calibration.valid and (a.sample.position < a.calibration.low or a.sample.position > a.calibration.high)) return false;
        }
        return true;
    }
    pub fn arm(self: *Controller, now: u32) Error!void {
        if (self.state == .running or self.state == .armed) return error.Busy;
        if (self.state == .fault) return error.Fault;
        for (self.axes) |a| {
            if (!a.configured) return error.Unconfigured;
            if (!a.calibration.valid) return error.Uncalibrated;
        }
        if (!self.healthy(now)) return error.Stale;
        // Enabling torque must not cause a jump. First goals match measured positions.
        for (self.axes, 0..) |a, i| self.targets[i] = @intCast(a.sample.position);
        self.state = .armed;
    }
    pub fn jog(self: *Controller, index: usize, position: u16) Error!void {
        if (self.state != .armed) return error.NotArmed;
        if (index >= 3 or position < self.axes[index].calibration.low or position > self.axes[index].calibration.high) return error.Range;
        self.targets[index] = position;
    }
    fn setPhase(self: *Controller) void {
        // Rear hold; arch; front hold; rear release; flatten; rear hold; front release.
        const poses = [_][3]bool{ .{ true, false, false }, .{ true, true, false }, .{ true, true, true }, .{ false, true, true }, .{ false, false, true }, .{ true, false, true }, .{ true, false, false } };
        for (self.axes, 0..) |a, i| self.targets[i] = if (poses[self.phase][i]) a.calibration.engaged else a.calibration.released;
    }
    pub fn run(self: *Controller, cycles: u8, now: u32) Error!void {
        if (self.state != .armed) return error.NotArmed;
        if (cycles == 0 or cycles > 2) return error.Range;
        self.phase = 0;
        self.phases_left = cycles * 7;
        self.phase_started = now;
        self.settled_since = null;
        self.state = .running;
        self.setPhase();
    }
    /// Call continuously, independently of incoming host commands. Returns true on new goals.
    pub fn tick(self: *Controller, now: u32) bool {
        if (self.state != .armed and self.state != .running) return false;
        if (!self.healthy(now)) {
            self.trip();
            return false;
        }
        if (self.state != .running) return false;
        if (now -% self.phase_started > 3000) {
            self.trip();
            return false;
        }
        var settled = true;
        for (self.axes, 0..) |a, i| {
            const difference = a.sample.position - @as(i32, self.targets[i]);
            if (difference > 16 or difference < -16 or a.sample.velocity > 5 or a.sample.velocity < -5) settled = false;
        }
        if (!settled) {
            self.settled_since = null;
            return false;
        }
        if (self.settled_since == null) self.settled_since = now;
        if (now -% self.settled_since.? < 150) return false;
        self.phases_left -= 1;
        if (self.phases_left == 0) {
            self.state = .armed;
            return false;
        }
        self.phase = (self.phase + 1) % 7;
        self.phase_started = now;
        self.settled_since = null;
        self.setPhase();
        return true;
    }
};
fn ready() Controller {
    var c: Controller = .{};
    c.heartbeat(10);
    for (&c.axes) |*a| {
        a.configured = true;
        a.calibration = .{ .low = 1800, .high = 2200, .released = 1900, .engaged = 2100, .valid = true };
        a.seen = true;
        a.sample_ms = 10;
        a.sample = .{ .current_ma = 30, .position = 2000, .velocity = 0, .voltage_mv = 5000, .temperature_c = 30 };
    }
    return c;
}
test "boot disabled calibration and arm from measured position" {
    var c: Controller = .{};
    try t.expect(c.state == .disarmed);
    try t.expectError(error.Unconfigured, c.arm(0));
    c = ready();
    try c.arm(10);
    try t.expect(c.targets[0] == 2000);
    try t.expectError(error.Range, c.jog(0, 2201));
}
test "host watchdog trips even when servo feedback continues including timer wrap" {
    var c = ready();
    try c.arm(10);
    for (&c.axes) |*a| a.sample_ms = 520;
    _ = c.tick(520);
    try t.expect(c.state == .fault);
    c = ready();
    c.last_host_ms = 0xfffffff0;
    for (&c.axes) |*a| a.sample_ms = 20;
    try c.arm(20);
    _ = c.tick(20);
    try t.expect(c.state == .armed);
}
test "stale feedback hardware fault and over temperature block arm" {
    var c = ready();
    c.axes[1].sample_ms = 0;
    try t.expectError(error.Stale, c.arm(251));
    c = ready();
    c.axes[2].fault = 32;
    try t.expectError(error.Stale, c.arm(10));
    c = ready();
    c.axes[0].sample.temperature_c = 55;
    try t.expectError(error.Stale, c.arm(10));
}
test "gait waits for feedback then advances and stall trips" {
    var c = ready();
    try c.arm(10);
    try c.run(1, 10);
    try t.expect(c.targets[0] == 2100 and c.targets[1] == 1900);
    _ = c.tick(10);
    try t.expect(c.phase == 0);
    for (&c.axes, 0..) |*a, i| {
        a.sample.position = c.targets[i];
        a.sample_ms = 20;
    }
    _ = c.tick(20);
    c.heartbeat(180);
    for (&c.axes) |*a| a.sample_ms = 180;
    try t.expect(c.tick(180));
    try t.expect(c.phase == 1 and c.targets[1] == 2100);
    c.heartbeat(4000);
    for (&c.axes) |*a| a.sample_ms = 4000;
    _ = c.tick(4000);
    try t.expect(c.state == .fault);
}

test "two gait cycles complete only after all measured targets settle" {
    var c = ready();
    try c.arm(10);
    try c.run(2, 10);
    var now: u32 = 20;
    var advances: usize = 0;
    while (c.state == .running and advances < 14) {
        c.heartbeat(now);
        for (&c.axes, 0..) |*a, i| {
            a.sample.position = c.targets[i];
            a.sample_ms = now;
        }
        _ = c.tick(now);
        now += 160;
        c.heartbeat(now);
        for (&c.axes) |*a| a.sample_ms = now;
        _ = c.tick(now);
        advances += 1;
        now += 10;
    }
    try t.expect(c.state == .armed and advances == 14 and c.phases_left == 0);
}
