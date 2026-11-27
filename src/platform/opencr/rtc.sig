//! Battery-backed LSE RTC and backup registers. Never implicitly erase backup state.
const hw = @import("board.sig");
const t = @import("../../core/sig_testing.sig");
pub const DateTime = struct { year: u16, month: u8, day: u8, weekday: u8, hour: u8, minute: u8, second: u8 };
pub fn valid(d: DateTime) bool {
    if (d.year < 2000 or d.year > 2099 or d.month < 1 or d.month > 12 or d.weekday < 1 or d.weekday > 7 or d.hour > 23 or d.minute > 59 or d.second > 59 or d.day == 0) return false;
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d.day <= days[d.month - 1] + @as(u8, if (d.month == 2 and d.year % 4 == 0) 1 else 0);
}
fn bcd(n: u8) u32 {
    return @as(u32, n / 10) * 16 + n % 10;
}
fn decimal(n: u32) u8 {
    return @intCast(((n >> 4) & 15) * 10 + (n & 15));
}
fn unlock() void {
    hw.write(0x40002824, 0xca);
    hw.write(0x40002824, 0x53);
}
fn lock() void {
    hw.write(0x40002824, 0xff);
}
pub fn init(poll: hw.Poll) hw.Error!void {
    hw.bits(hw.rcc + 0x40, 0, 1 << 28);
    hw.bits(0x40007000, 0, 1 << 8);
    const selected = (hw.read(hw.rcc + 0x70) >> 8) & 3;
    if (selected != 0 and selected != 1) return error.Busy;
    hw.bits(hw.rcc + 0x70, 0, 1);
    try hw.wait(hw.rcc + 0x70, 2, 2, hw.millis(), 3000, poll);
    hw.bits(hw.rcc + 0x70, 0, (1 << 8) | (1 << 15));
    unlock();
    defer lock();
    if (hw.read(0x4000280c) & 16 == 0) {
        hw.bits(0x4000280c, 0, 128);
        try hw.wait(0x4000280c, 64, 64, hw.millis(), 50, poll);
        hw.write(0x40002810, (127 << 16) | 255);
        hw.bits(0x40002808, 64, 0);
        hw.bits(0x4000280c, 128, 0);
    }
    hw.bits(0x4000280c, 32, 0);
    try hw.wait(0x4000280c, 32, 32, hw.millis(), 50, poll);
}
pub fn read() hw.Error!DateTime {
    if (hw.read(0x4000280c) & 16 == 0) return error.Busy;
    const time = hw.read(0x40002800);
    const date = hw.read(0x40002804);
    const d: DateTime = .{ .year = 2000 + @as(u16, decimal(date >> 16)), .month = decimal((date >> 8) & 31), .day = decimal(date & 63), .weekday = @intCast((date >> 13) & 7), .hour = decimal((time >> 16) & 63), .minute = decimal((time >> 8) & 127), .second = decimal(time & 127) };
    if (!valid(d)) return error.Range;
    return d;
}
pub fn set(d: DateTime, poll: hw.Poll) hw.Error!void {
    if (!valid(d)) return error.Range;
    unlock();
    defer lock();
    hw.bits(0x4000280c, 0, 128);
    defer hw.bits(0x4000280c, 128, 0);
    try hw.wait(0x4000280c, 64, 64, hw.millis(), 50, poll);
    hw.write(0x40002800, bcd(d.second) | (bcd(d.minute) << 8) | (bcd(d.hour) << 16));
    hw.write(0x40002804, bcd(d.day) | (bcd(d.month) << 8) | (@as(u32, d.weekday) << 13) | (bcd(@intCast(d.year - 2000)) << 16));
}
pub fn backup(index: u8) hw.Error!u32 {
    if (index >= 32) return error.Range;
    return hw.read(0x40002850 + @as(usize, index) * 4);
}
pub fn writeBackup(index: u8, value: u32) hw.Error!void {
    if (index >= 32) return error.Range;
    hw.write(0x40002850 + @as(usize, index) * 4, value);
}
test "RTC rejects invalid dates and handles leap years" {
    try t.expect(valid(.{ .year = 2024, .month = 2, .day = 29, .weekday = 4, .hour = 23, .minute = 59, .second = 59 }));
    try t.expect(!valid(.{ .year = 2023, .month = 2, .day = 29, .weekday = 4, .hour = 0, .minute = 0, .second = 0 }));
}
