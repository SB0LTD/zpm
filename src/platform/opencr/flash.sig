//! Explicit scratch storage in reserved sector 7. No bootloader/EEPROM writes.
//! Link applications below 0x080c0000; a firmware upload can erase scratch contents.
const hw = @import("board.sig");
const t = @import("../../core/sig_testing.sig");
pub const start: usize = 0x080c0000;
pub const size: usize = 256 * 1024;
pub fn address(offset: usize, n: usize) hw.Error!usize {
    if (offset > size or n > size - offset) return error.Range;
    return start + offset;
}
fn unlock() void {
    if (hw.read(0x40023c10) & (1 << 31) != 0) {
        hw.write(0x40023c04, 0x45670123);
        hw.write(0x40023c04, 0xcdef89ab);
    }
}
fn lock() void {
    hw.bits(0x40023c10, 0, 1 << 31);
}
// The STM32 stalls flash fetches while its single bank is busy. This complete
// operation runs from copied SRAM and feeds IWDG without calling flash code.
noinline fn operation(control: u32, target: usize, value: u32, erase_sector: bool) linksection(".ramfunc") bool {
    const cr: *volatile u32 = @ptrFromInt(0x40023c10);
    const sr: *volatile u32 = @ptrFromInt(0x40023c0c);
    const timer: *volatile u32 = @ptrFromInt(0x40000c24);
    const watchdog: *volatile u32 = @ptrFromInt(0x40003000);
    const begun = timer.*;
    cr.* = control;
    if (erase_sector) cr.* = control | (1 << 16) else {
        const dest: *volatile u32 = @ptrFromInt(target);
        dest.* = value;
    }
    while (sr.* & (1 << 16) != 0) {
        watchdog.* = 0xaaaa;
        if (timer.* -% begun > 5_000_000) return false;
    }
    cr.* = 0;
    return sr.* & 0xf2 == 0;
}
pub fn read(offset: usize, out: []u8) hw.Error!void {
    const a = try address(offset, out.len);
    const p: [*]const volatile u8 = @ptrFromInt(a);
    for (out, 0..) |*byte, i| byte.* = p[i];
}
fn ready(poll: hw.Poll, timeout: u32) hw.Error!void {
    try hw.wait(0x40023c0c, 1 << 16, 0, hw.millis(), timeout, poll);
    if (hw.read(0x40023c0c) & 0xf2 != 0) return error.Transport;
}
/// Explicit destructive operation on scratch only; call with actuator power OFF.
pub fn erase(poll: hw.Poll) hw.Error!void {
    try ready(poll, 2000);
    unlock();
    defer lock();
    hw.write(0x40023c0c, 0xf3);
    if (!operation((2 << 8) | (7 << 3) | 2, 0, 0, true)) return error.Transport;
}
pub fn program(offset: usize, bytes: []const u8, poll: hw.Poll) hw.Error!void {
    const a = try address(offset, bytes.len);
    if (offset % 4 != 0 or bytes.len % 4 != 0) return error.Range;
    // Preflight every word before writing: flash permits only 1 -> 0 transitions.
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) if (hw.read(a + i) & word(bytes[i..][0..4]) != word(bytes[i..][0..4])) return error.Range;
    try ready(poll, 2000);
    unlock();
    defer lock();
    hw.write(0x40023c0c, 0xf3);
    i = 0;
    while (i < bytes.len) : (i += 4) {
        if (!operation((2 << 8) | 1, a + i, word(bytes[i..][0..4]), false)) return error.Transport;
        if (hw.read(a + i) != word(bytes[i..][0..4])) return error.Transport;
    }
    hw.write(0x40023c10, 0);
}
fn word(b: *const [4]u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}
test "flash scratch bounds never include firmware bootloader EEPROM or overflow" {
    try t.expect(try address(0, 4) == 0x080c0000);
    try t.expectError(error.Range, address(size, 4));
    try t.expectError(error.Range, address(~@as(usize, 0), 4));
}
