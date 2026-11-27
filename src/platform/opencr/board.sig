//! OpenCR 1.0 STM32F746: 216 MHz HSE PLL, 48 MHz USB, no DMA/caches.
pub const Error = error{ Timeout, Range, Busy, Transport, Nack, Arbitration, Overflow, Unsupported, Model };
pub const Poll = *const fn () void;
pub fn idle() void {
    asm volatile ("nop");
}
pub fn read(a: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(a);
    return p.*;
}
pub fn write(a: usize, v: u32) void {
    const p: *volatile u32 = @ptrFromInt(a);
    p.* = v;
}
pub fn read8(a: usize) u8 {
    const p: *volatile u8 = @ptrFromInt(a);
    return p.*;
}
pub fn write8(a: usize, v: u8) void {
    const p: *volatile u8 = @ptrFromInt(a);
    p.* = v;
}
pub fn bits(a: usize, clear: u32, set: u32) void {
    write(a, (read(a) & ~clear) | set);
}
pub const rcc = 0x40023800;
pub const Pin = struct {
    port: u3,
    bit: u4,
    pub fn base(self: Pin) usize {
        return 0x40020000 + @as(usize, self.port) * 0x400;
    }
    pub fn value(self: Pin, high: bool) void {
        write(self.base() + 0x18, @as(u32, 1) << (@as(u5, self.bit) + if (high) @as(u5, 0) else 16));
    }
    pub fn input(self: Pin) bool {
        return read(self.base() + 0x10) & (@as(u32, 1) << self.bit) != 0;
    }
    pub fn mode(self: Pin, mode_value: u2, pull: u2, af: u4, open_drain: bool) void {
        bits(rcc + 0x30, 0, @as(u32, 1) << self.port);
        _ = read(rcc + 0x30);
        const shift: u5 = @as(u5, self.bit) * 2;
        bits(self.base(), @as(u32, 3) << shift, @as(u32, mode_value) << shift);
        bits(self.base() + 4, @as(u32, 1) << self.bit, @as(u32, @intFromBool(open_drain)) << self.bit);
        bits(self.base() + 8, @as(u32, 3) << shift, @as(u32, 2) << shift);
        bits(self.base() + 0xc, @as(u32, 3) << shift, @as(u32, pull) << shift);
        const af_shift: u5 = @as(u5, self.bit & 7) * 4;
        bits(self.base() + 0x20 + @as(usize, self.bit / 8) * 4, @as(u32, 15) << af_shift, @as(u32, af) << af_shift);
    }
    pub fn output(self: Pin, high: bool) void {
        bits(rcc + 0x30, 0, @as(u32, 1) << self.port);
        _ = read(rcc + 0x30);
        self.value(high);
        self.mode(1, 0, 0, false);
    }
};
pub const robot_power: Pin = .{ .port = 5, .bit = 15 };
/// Expansion GPIO7/PE10 drives an EXTERNAL active-high 5 V high-side switch.
/// This does not change the voltage of the board's built-in Dynamixel rail.
pub const fixture_power: Pin = .{ .port = 4, .bit = 10 };
pub const direction: Pin = .{ .port = 2, .bit = 9 };
pub const leds = [_]Pin{ .{ .port = 6, .bit = 12 }, .{ .port = 4, .bit = 5 }, .{ .port = 4, .bit = 4 }, .{ .port = 6, .bit = 10 } };
pub const buttons = [_]Pin{ .{ .port = 6, .bit = 3 }, .{ .port = 2, .bit = 12 }, .{ .port = 6, .bit = 11 }, .{ .port = 4, .bit = 6 } };
pub fn power(on: bool) void {
    fixture_power.output(on);
    robot_power.output(false);
}
pub fn led(on: bool) void {
    leds[0].output(!on);
}
fn waitRaw(a: usize, mask: u32, expected: u32) void {
    var left: u32 = 40_000_000;
    while (read(a) & mask != expected) : (left -= 1) {
        if (left == 0) {
            power(false);
            while (true) idle();
        }
    }
}
pub fn quiesce() void {
    power(false);
    direction.output(false);
    // Interrupts are disabled by reset entry. Stop the previous USB controller/DMA.
    bits(rcc + 0x34, 0, 1 << 7);
    _ = read(rcc + 0x34);
    bits(0x50000804, 0, 2);
    bits(rcc + 0x14, 0, 1 << 7);
    bits(rcc + 0x14, 1 << 7, 0);
    // Clean every inherited D-cache line before disabling it; then invalidate I-cache.
    if (read(0xe000ed14) & (1 << 16) != 0) {
        write(0xe000ed84, 0);
        asm volatile ("dsb\n isb" ::: .{ .memory = true });
        const c = read(0xe000ed80);
        var set: u32 = (c >> 13) & 0x7fff;
        while (true) {
            var way: u32 = (c >> 3) & 0x3ff;
            while (true) {
                write(0xe000ef74, (set << 5) | (way << 30));
                if (way == 0) break;
                way -= 1;
            }
            if (set == 0) break;
            set -= 1;
        }
    }
    asm volatile ("dsb" ::: .{ .memory = true });
    bits(0xe000ed14, (1 << 16) | (1 << 17), 0);
    asm volatile ("dsb\n isb" ::: .{ .memory = true });
    write(0xe000ef50, 0);
    write(0xe000ed94, 0); // MPU disabled: own fixed SRAM, no inherited DMA attributes.
    asm volatile ("dsb\n isb" ::: .{ .memory = true });
    write(0xe000e010, 0);
}
pub fn init() void {
    write(0xe000ed08, 0x08040000);
    bits(rcc, 0, 1);
    waitRaw(rcc, 2, 2);
    bits(rcc + 8, 3, 0);
    waitRaw(rcc + 8, 12, 0);
    bits(rcc, 1 << 24, 0);
    waitRaw(rcc, 1 << 25, 0);
    bits(rcc + 0x40, 0, 1 << 28);
    bits(0x40007000, 3 << 14, 3 << 14);
    bits(rcc, 0, 1 << 16);
    waitRaw(rcc, 1 << 17, 1 << 17);
    write(rcc + 4, 25 | (432 << 6) | (1 << 22) | (9 << 24));
    bits(rcc, 0, 1 << 24);
    waitRaw(rcc, 1 << 25, 1 << 25);
    bits(0x40007000, 0, 1 << 16);
    waitRaw(0x40007004, 1 << 16, 1 << 16);
    bits(0x40007000, 0, 1 << 17);
    waitRaw(0x40007004, 1 << 17, 1 << 17);
    write(0x40023c00, 7); // 7 wait states before switching to 216 MHz.
    write(rcc + 8, (5 << 10) | (4 << 13) | 2);
    waitRaw(rcc + 8, 12, 8);
    write(rcc + 0x90, 0); // UART and I2C clocks use APB; USB uses PLLQ.
    // Independent 32-bit TIM5 at 1 MHz; APB1 timer clock is 108 MHz.
    bits(rcc + 0x40, 0, 1 << 3);
    write(0x40000c00, 0);
    write(0x40000c28, 107);
    write(0x40000c2c, 0xffffffff);
    write(0x40000c14, 1);
    write(0x40000c10, 0);
    write(0x40000c00, 1);
    for (leds) |pin| pin.output(true);
    for (buttons) |pin| pin.mode(0, 0, 0, false);
    // FPU enabled for callers; fixture itself uses integer arithmetic.
    bits(0xe000ed88, 0, 15 << 20);
    asm volatile ("dsb\n isb" ::: .{ .memory = true });
}
var previous: u32 = 0;
var milliseconds: u32 = 0;
var remainder: u32 = 0;
pub fn micros() u32 {
    return read(0x40000c24);
}
pub fn millis() u32 {
    const count = micros();
    const delta: u64 = @as(u64, count -% previous) + remainder;
    previous = count;
    milliseconds +%= @intCast(delta / 1000);
    remainder = @intCast(delta % 1000);
    return milliseconds;
}
pub fn wait(a: usize, mask: u32, expected: u32, start: u32, timeout: u32, poll: Poll) Error!void {
    while (read(a) & mask != expected) {
        poll();
        if (millis() -% start >= timeout) return error.Timeout;
    }
}
pub fn delay(ms: u32, poll: Poll) void {
    const start = millis();
    while (millis() -% start < ms) poll();
}
pub fn watchdogStart() void {
    // LSI independently clocks IWDG; approximately 1 second (frequency tolerance applies).
    bits(rcc + 0x74, 0, 1);
    waitRaw(rcc + 0x74, 2, 2);
    write(0x40003000, 0x5555);
    write(0x40003004, 6);
    write(0x40003008, 124);
    waitRaw(0x4000300c, 3, 0);
    write(0x40003000, 0xaaaa);
    write(0x40003000, 0xcccc);
}
pub fn watchdogFeed() void {
    write(0x40003000, 0xaaaa);
}
