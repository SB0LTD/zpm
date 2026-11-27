//! RP2040 single-core startup, 125 MHz system/peripheral clock, 48 MHz USB.
//! Register layout: Raspberry Pi RP2040 datasheet; no SDK/runtime linkage.
pub fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
pub fn read(address: usize) u32 {
    return reg(address).*;
}
pub fn write(address: usize, value: u32) void {
    reg(address).* = value;
}
pub fn set(address: usize, bits: u32) void {
    reg(address + 0x2000).* = bits;
}
pub fn clear(address: usize, bits: u32) void {
    reg(address + 0x3000).* = bits;
}
pub fn cycles() void {
    asm volatile ("nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop\n nop");
}
pub fn resetRelease(mask: u32) void {
    clear(0x4000c000, mask);
    while (read(0x4000c008) & mask != mask) cycles();
}
pub fn init() void {
    write(0x4002400c, 47);
    write(0x40024000, 0x00fabaa0);
    while (read(0x40024004) & 0x80000000 == 0) cycles();
    write(0x40008034, 256);
    write(0x40008030, 2);
    while (read(0x40008038) & 4 == 0) cycles();
    write(0x4000803c, 0);
    while (read(0x40008044) & 1 == 0) cycles();
    write(0x40008040, 256);
    // RP2040-E16: CPU must be faster than USB by at least 10%.
    resetRelease(1 << 12);
    write(0x40028000, 1);
    write(0x40028008, 125);
    clear(0x40028004, (1 << 0) | (1 << 5));
    while (read(0x40028000) & (1 << 31) == 0) cycles();
    write(0x4002800c, (6 << 16) | (2 << 12));
    clear(0x40028004, 1 << 3);
    write(0x4000803c, 1);
    while (read(0x40008044) & 2 == 0) cycles();
    write(0x40008048, 1 << 11);
    resetRelease((1 << 5) | (1 << 8) | (1 << 13) | (1 << 21) | (1 << 22) | (1 << 24));
    write(0x4002c000, 1);
    write(0x4002c008, 40);
    clear(0x4002c004, (1 << 0) | (1 << 5));
    while (read(0x4002c000) & (1 << 31) == 0) cycles();
    write(0x4002c00c, (5 << 16) | (2 << 12));
    clear(0x4002c004, 1 << 3);
    write(0x40008058, 256);
    write(0x40008054, 1 << 11);
    write(0x4005802c, (1 << 9) | 12);
    gpioOutput(25, true); // power-on diagnostic LED
}
pub fn micros() u32 {
    return read(0x40054028);
}
var last_micro: u32 = 0;
var elapsed_ms: u32 = 0;
var remainder: u32 = 0;
pub fn millis() u32 {
    const current = micros();
    const delta = current -% last_micro;
    last_micro = current;
    const sum = @as(u64, remainder) + delta;
    elapsed_ms +%= @intCast(sum / 1000);
    remainder = @intCast(sum % 1000);
    return elapsed_ms;
}
pub fn gpioFunction(pin: u5, function: u5) void {
    write(0x40014004 + @as(usize, pin) * 8, function);
}
pub fn gpioOutput(pin: u5, high: bool) void {
    gpioFunction(pin, 5);
    write(if (high) 0xd0000014 else 0xd0000018, @as(u32, 1) << pin);
    write(0xd0000024, @as(u32, 1) << pin);
}
pub fn gpioSet(pin: u5, high: bool) void {
    write(if (high) 0xd0000014 else 0xd0000018, @as(u32, 1) << pin);
}
