//! OpenRB-150 SAMD21G18A: crystal-referenced 48 MHz, GPIO, paired TC4/5 clock.
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
pub fn read16(a: usize) u16 {
    const p: *volatile u16 = @ptrFromInt(a);
    return p.*;
}
pub fn write16(a: usize, v: u16) void {
    const p: *volatile u16 = @ptrFromInt(a);
    p.* = v;
}
pub fn cycles() void {
    asm volatile ("nop");
}
pub fn output(group: usize, pin: u5, value: bool) void {
    const base = 0x41004400 + group * 0x80;
    write8(base + 0x40 + pin, 0);
    write(base + if (value) @as(usize, 0x18) else 0x14, @as(u32, 1) << pin);
    write(base + 8, @as(u32, 1) << pin);
}
pub fn mux(pin: u5, function: u4, input: bool) void {
    const a = 0x41004430 + @as(usize, pin / 2);
    const shift: u3 = if (pin & 1 == 0) 0 else 4;
    write8(a, (read8(a) & ~(@as(u8, 15) << shift)) | (@as(u8, function) << shift));
    write8(0x41004440 + @as(usize, pin), if (input) 3 else 1);
}
pub fn power(on: bool) void {
    output(0, 28, on);
}
pub fn led(on: bool) void {
    output(1, 8, on);
}
fn syncClock() void {
    while (read8(0x40000c01) & 128 != 0) cycles();
}
pub fn peripheralClock(id: u6) void {
    write16(0x40000c02, @as(u16, id) | (1 << 14));
    syncClock();
}
fn generator(id: u8, source: u8) void {
    write(0x40000c08, @as(u32, id) | (1 << 8));
    syncClock();
    write(0x40000c04, @as(u32, id) | (@as(u32, source) << 8) | (1 << 16) | (1 << 17));
    syncClock();
}
var last_count: u32 = 0;
var elapsed: u32 = 0;
var remainder: u32 = 0;
pub fn quiesce() void {
    // The factory USB bootloader may leave DMA active. Stop it before clearing SRAM.
    write(0x4000041c, read(0x4000041c) | (1 << 3));
    power(false);
    write16(0x41005008, 1);
    write8(0x41005000, 0);
    while (read8(0x41005002) & 2 != 0) cycles();
}
pub fn init() void {
    // Set power OFF before any clock wait. Preserve the factory bootloader at 0..0x1fff.
    write(0x4000041c, read(0x4000041c) | (1 << 3));
    power(false);
    led(false);
    write(0xe000ed08, 0x2000);
    for (0..4) |i| write8(0x40000408 + i, 0);
    write(0x41004004, (read(0x41004004) & ~@as(u32, 30)) | 2);
    // Safe temporary oscillator while replacing the bootloader's clock configuration.
    write(0x40000820, read(0x40000820) & ~@as(u32, 3 << 8));
    generator(0, 6);
    write16(0x40000814, 2 | 4 | 8 | (6 << 8));
    while (read(0x4000080c) & 2 == 0) cycles();
    generator(1, 5);
    write16(0x40000c02, (1 << 8) | (1 << 14));
    syncClock();
    write16(0x40000824, 2);
    while (read(0x4000080c) & 16 == 0) cycles();
    var coarse = (read(0x806024) >> 26) & 63;
    if (coarse == 63) coarse = 31;
    write(0x40000828, (coarse << 10) | 512);
    while (read(0x4000080c) & 16 == 0) cycles();
    write(0x4000082c, 1465 | (511 << 16) | (31 << 26));
    while (read(0x4000080c) & 16 == 0) cycles();
    write16(0x40000824, 2 | 4 | (1 << 9) | (1 << 11));
    while (read(0x4000080c) & 0xc0 != 0xc0) cycles();
    generator(0, 7);
    // 32-bit free-running pair; 48 MHz / 64 = approximately 750 ticks/ms.
    write(0x40000420, read(0x40000420) | (3 << 12));
    peripheralClock(28);
    write16(0x42003000, 1);
    while (read16(0x42003000) & 1 != 0) cycles();
    write16(0x42003000, (2 << 2) | (5 << 8));
    while (read8(0x4200300f) & 128 != 0) cycles();
    write16(0x42003002, (1 << 15) | (1 << 14) | 0x10);
    write16(0x42003000, (2 << 2) | (5 << 8) | 2);
    while (read8(0x4200300f) & 128 != 0) cycles();
    last_count = read(0x42003010);
}
pub fn millis() u32 {
    const count = read(0x42003010);
    const ticks: u64 = @as(u64, count -% last_count) + remainder;
    last_count = count;
    elapsed +%= @intCast(ticks / 750);
    remainder = @intCast(ticks % 750);
    return elapsed;
}
