//! GPIO mapping, pin ownership, ADC, six independent PWM outputs, EXTI and buzzer.
const hw = @import("board.sig");
const t = @import("../../core/sig_testing.sig");
const mapping = [_]u8{
    0x27, 0x26, 0x66, 0x14, 0x67, 0x08, 0x02, 0x21, 0x22, 0x03, 0x19, 0x1f, 0x1e, 0x09, 0x17, 0x18,
    0x00, 0x5a, 0x59, 0x58, 0x57, 0x56, 0x6c, 0x45, 0x44, 0x6a, 0x6b, 0x46, 0x04, 0x20, 0x23, 0x5e,
    0x5f, 0x6e, 0x63, 0x2c, 0x69, 0x05, 0x06, 0x15, 0x10, 0x28, 0x07, 0x25, 0x11, 0x24, 0x3a, 0xff,
    0xff, 0xff, 0x1a, 0x1b, 0x2d, 0x32, 0x43, 0x62, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51,
    0x52, 0x38, 0x54, 0x39, 0xff, 0xff, 0x5c, 0x5b, 0x55, 0x49, 0x48, 0x53, 0xff, 0xff, 0xff, 0xff,
    0x36, 0x35, 0x40, 0x41, 0x29,
};
pub fn pin(number: usize) hw.Error!hw.Pin {
    if (number >= mapping.len or mapping[number] == 0xff) return error.Range;
    return .{ .port = @intCast(mapping[number] >> 4), .bit = @truncate(mapping[number]) };
}
pub const Owner = enum { free, gpio, adc, pwm, spi, i2c, uart, can, fixture, imu, usb };
pub const Mux = struct {
    owners: [7][16]Owner = @splat(@splat(.free)),
    pub fn claim(self: *Mux, pins: []const hw.Pin, owner: Owner) hw.Error!void {
        if (owner == .free) return error.Range;
        for (pins) |p| if (self.owners[p.port][p.bit] != .free and self.owners[p.port][p.bit] != owner) return error.Busy;
        for (pins) |p| self.owners[p.port][p.bit] = owner;
    }
    pub fn release(self: *Mux, pins: []const hw.Pin, owner: Owner) void {
        for (pins) |p| if (self.owners[p.port][p.bit] == owner) {
            self.owners[p.port][p.bit] = .free;
        };
    }
};
pub const Analog = struct { pin: hw.Pin, base: usize = 0x40012200, channel: u5 };
pub fn analog(number: usize) hw.Error!Analog {
    const channel: u5 = switch (number) {
        16 => 0,
        17 => 8,
        18 => 7,
        19 => 6,
        20 => 5,
        21 => 4,
        29 => 10,
        30 => 13,
        42 => 7,
        45 => 14,
        72 => 15,
        75 => 9,
        else => return error.Range,
    };
    return .{ .pin = try pin(number), .base = if (number == 42 or number == 45) 0x40012000 else 0x40012200, .channel = channel };
}
pub fn adc(number: usize, poll: hw.Poll) hw.Error!u12 {
    const a = try analog(number);
    a.pin.mode(3, 0, 0, false);
    hw.bits(hw.rcc + 0x44, 0, (1 << 8) | (1 << 10));
    hw.bits(0x40012304, 3 << 16, 1 << 16); // ADC clock 27 MHz, 12-bit.
    hw.write(a.base + 4, 0);
    hw.write(a.base + 8, 1 | (1 << 10));
    const smpr: usize = if (a.channel < 10) 0x10 else 0xc;
    const shift: u5 = @intCast((a.channel % 10) * 3);
    hw.bits(a.base + smpr, @as(u32, 7) << shift, @as(u32, 7) << shift);
    hw.write(a.base + 0x2c, 0);
    hw.write(a.base + 0x34, a.channel);
    hw.write(a.base, 0);
    hw.delay(1, poll);
    hw.bits(a.base + 8, 0, 1 << 30);
    try hw.wait(a.base, 2, 2, hw.millis(), 10, poll);
    return @truncate(hw.read(a.base + 0x4c));
}
pub fn inputMillivolts(raw: u12, reference_mv: u32) u32 {
    return (@as(u32, raw) * reference_mv * 57) / (4095 * 10);
}
pub const PwmMap = struct { number: u8, base: usize, channel: u2, af: u4, fast: bool, clock_bit: u5 };
pub const pwm_map = [_]PwmMap{
    .{ .number = 3, .base = 0x40000400, .channel = 0, .af = 2, .fast = false, .clock_bit = 1 },
    .{ .number = 5, .base = 0x40010000, .channel = 0, .af = 1, .fast = true, .clock_bit = 0 },
    .{ .number = 6, .base = 0x40000000, .channel = 2, .af = 1, .fast = false, .clock_bit = 0 },
    .{ .number = 9, .base = 0x40014000, .channel = 1, .af = 3, .fast = true, .clock_bit = 16 },
    .{ .number = 10, .base = 0x40014800, .channel = 0, .af = 3, .fast = true, .clock_bit = 18 },
    .{ .number = 11, .base = 0x40001800, .channel = 1, .af = 9, .fast = false, .clock_bit = 6 },
};
pub const Timing = struct { prescaler: u16, period: u16, actual_hz: u32 };
pub fn pwmTiming(clock: u32, hz: u32) hw.Error!Timing {
    if (hz == 0 or hz > 20_000) return error.Range;
    const divisor = (clock / hz + 65535) / 65536;
    const counts = clock / divisor / hz;
    if (divisor == 0 or divisor > 65536 or counts == 0 or counts > 65536) return error.Range;
    return .{ .prescaler = @intCast(divisor - 1), .period = @intCast(counts - 1), .actual_hz = clock / divisor / counts };
}
pub fn pwm(index: usize, hz: u32, duty_per_mille: u16) hw.Error!void {
    if (index >= pwm_map.len or duty_per_mille > 1000) return error.Range;
    const m = pwm_map[index];
    const timing = try pwmTiming(if (m.fast) 216_000_000 else 108_000_000, hz);
    (try pin(m.number)).mode(2, 0, m.af, false);
    hw.bits(hw.rcc + if (m.fast) @as(usize, 0x44) else 0x40, 0, @as(u32, 1) << m.clock_bit);
    hw.write(m.base, 0);
    hw.write(m.base + 0x28, timing.prescaler);
    hw.write(m.base + 0x2c, timing.period);
    const shift: u5 = @as(u5, m.channel % 2) * 8;
    hw.bits(m.base + 0x18 + @as(usize, m.channel / 2) * 4, @as(u32, 255) << shift, @as(u32, (6 << 4) | 8) << shift);
    const compare = (@as(u32, timing.period) + 1) * duty_per_mille / 1000;
    // At ARR=65535, 100% uses forced-active output to avoid a 16-bit CCR overflow.
    if (duty_per_mille == 1000) hw.bits(m.base + 0x18 + @as(usize, m.channel / 2) * 4, @as(u32, 7) << (shift + 4), @as(u32, 5) << (shift + 4));
    hw.write(m.base + 0x34 + @as(usize, m.channel) * 4, @min(compare, 65535));
    hw.bits(m.base + 0x20, @as(u32, 15) << (@as(u5, m.channel) * 4), @as(u32, 1) << (@as(u5, m.channel) * 4));
    if (m.base == 0x40010000) hw.write(m.base + 0x44, 1 << 15);
    hw.write(m.base + 0x14, 1);
    hw.write(m.base, 129);
}
pub fn pwmStop(index: usize) hw.Error!void {
    if (index >= pwm_map.len) return error.Range;
    const m = pwm_map[index];
    hw.write(m.base, 0);
    hw.write(m.base + 0x20, 0);
    (try pin(m.number)).output(false);
}
pub fn edge(p: hw.Pin, rising: bool, falling: bool) void {
    hw.bits(hw.rcc + 0x44, 0, 1 << 14);
    const shift: u5 = @as(u5, p.bit % 4) * 4;
    hw.bits(0x40013808 + @as(usize, p.bit / 4) * 4, @as(u32, 15) << shift, @as(u32, p.port) << shift);
    const mask = @as(u32, 1) << p.bit;
    hw.bits(0x40013c08, mask, if (rising) mask else 0);
    hw.bits(0x40013c0c, mask, if (falling) mask else 0);
    hw.write(0x40013c14, mask); // PR polled, NVIC remains disabled.
}
pub fn takeEdge(p: hw.Pin) bool {
    const mask = @as(u32, 1) << p.bit;
    if (hw.read(0x40013c14) & mask == 0) return false;
    hw.write(0x40013c14, mask);
    return true;
}
pub const Buzzer = struct {
    until: u32 = 0,
    next: u32 = 0,
    half_period: u32 = 0,
    high: bool = false,
    pub fn start(self: *Buzzer, hz: u16, duration_ms: u16) hw.Error!void {
        if (hz < 50 or hz > 4000 or duration_ms > 2000) return error.Range;
        (hw.Pin{ .port = 5, .bit = 14 }).output(false);
        self.* = .{ .until = hw.millis() +% duration_ms, .next = hw.micros(), .half_period = 500_000 / @as(u32, hz) };
    }
    pub fn stop(self: *Buzzer) void {
        (hw.Pin{ .port = 5, .bit = 14 }).output(false);
        self.half_period = 0;
    }
    pub fn tick(self: *Buzzer) void {
        if (self.half_period == 0) return;
        if (@as(i32, @bitCast(hw.millis() -% self.until)) >= 0) {
            self.stop();
            return;
        }
        if (@as(i32, @bitCast(hw.micros() -% self.next)) >= 0) {
            self.high = !self.high;
            (hw.Pin{ .port = 5, .bit = 14 }).value(self.high);
            self.next = hw.micros() +% self.half_period;
        }
    }
};
test "OpenCR pin ownership rejects collisions atomically including SPI PWM sharing" {
    var mux: Mux = .{};
    const a = try pin(11);
    const b = try pin(13);
    try mux.claim(&.{a}, .pwm);
    try t.expectError(error.Busy, mux.claim(&.{ b, a }, .spi));
    try t.expect(mux.owners[b.port][b.bit] == .free);
    mux.release(&.{a}, .pwm);
    try mux.claim(&.{ b, a }, .spi);
    try t.expectError(error.Range, pin(48));
    try t.expect((try pin(84)).bit == 9 and (try pin(56)).port == 4);
}
test "OpenCR timer divider and ADC divider use actual board clocks" {
    const timing = try pwmTiming(216_000_000, 50);
    try t.expect(timing.actual_hz >= 50 and timing.actual_hz <= 51);
    try t.expect(inputMillivolts(4095, 3300) == 18810);
    try t.expectError(error.Range, pwmTiming(108_000_000, 0));
}
