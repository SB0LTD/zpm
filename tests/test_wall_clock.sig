//! Wall-clock contract: the platform clock is monotone enough for SQL
//! statement timestamps, within a plausible calendar range, and fails closed
//! (ClockUnavailable) on targets without one.
const std = @import("std");
const builtin = @import("builtin");
const wall_clock = @import("wall_clock");
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.WallClockContractFailed;
}
pub fn main(init: std.process.Init) !void {
    if (wall_clock.available) {
        // 2024-01-01 and 2100-01-01 in microseconds since 1970-01-01.
        const low: i64 = 1704067200 * 1000000;
        const high: i64 = 4102444800 * 1000000;
        var previous = try wall_clock.nowUs();
        try check(previous > low and previous < high);
        var advanced = false;
        for (0..2000) |_| {
            const current = try wall_clock.nowUs();
            try check(current > low and current < high);
            // Wall time may step backwards on clock adjustment; never by much
            // within this loop on a test host.
            try check(current + 1000000 > previous);
            if (current > previous) advanced = true;
            previous = current;
        }
        try check(advanced);
    } else {
        if (wall_clock.nowUs()) |_| return error.UnavailableClockAccepted else |err| try check(err == error.ClockUnavailable);
    }
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"wall_clock\",\"pass\":true,\"assertions\":{d},\"os\":\"{s}\"}}\n", .{ assertions, @tagName(builtin.os.tag) });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
