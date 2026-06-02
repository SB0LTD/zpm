// High-precision timer using Win32 QueryPerformanceCounter
// Layer 1: Platform

const w32 = @import("win32");

pub const Timer = struct {
    freq: i64,
    start: i64,

    pub fn init() Timer {
        var freq: w32.LARGE_INTEGER = .{};
        var start: w32.LARGE_INTEGER = .{};
        _ = w32.QueryPerformanceFrequency(&freq);
        _ = w32.QueryPerformanceCounter(&start);
        return .{ .freq = freq.QuadPart, .start = start.QuadPart };
    }

    pub fn elapsed(self: *const Timer) f64 {
        var now: w32.LARGE_INTEGER = .{};
        _ = w32.QueryPerformanceCounter(&now);
        return @as(f64, @floatFromInt(now.QuadPart - self.start)) / @as(f64, @floatFromInt(self.freq));
    }
};
