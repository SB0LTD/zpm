//! @zpm/gfxapi report — what the driver says of itself on the app's stderr
//! (on Galaxy, an app's stderr is the kernel log): the device it draws
//! with, and what would otherwise go unseen. That covers an entry point an
//! app asked for that the driver does not have, a program that does not
//! link, a pipeline the GPU does not take (its draws then run on the CPU),
//! the GPU lost, and the first GL errors. Each kind is said a few times at
//! most, so a busy app cannot flood the log.
//!
//! On in the Linux library (libgalaxy-gl.so); off in tests and on other
//! hosts, unless `sink` is set.
//!
//! Allocation-free: a line is formatted on the stack.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum(u3) { device, missing, link, pipeline, lost, gl_error };

/// How many lines of each kind a process says.
const LIMITS = [_]u8{ 4, 64, 16, 16, 4, 16 };

pub var sink: ?*const fn ([]const u8) void = if (builtin.os.tag == .linux and !builtin.is_test) &stderrLine else null;

var counts = [_]u8{0} ** LIMITS.len;

fn stderrLine(line: []const u8) void {
    _ = std.os.linux.write(2, line.ptr, line.len);
}

/// One line, "galaxy-gl: ..." (with the process's id where it has one), if
/// this kind has lines left.
pub fn say(kind: Kind, comptime fmt: []const u8, args: anytype) void {
    const s = sink orelse return;
    const i = @intFromEnum(kind);
    // (counted without a lock: two threads at the limit may say one more)
    if (counts[i] >= LIMITS[i]) return;
    counts[i] += 1;
    var buf: [640]u8 = undefined;
    const pid: i64 = if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
    const last = counts[i] == LIMITS[i];
    const line = std.fmt.bufPrint(&buf, "galaxy-gl[{d}]: " ++ fmt ++ "{s}\n", .{pid} ++ args ++ .{if (last) " (the last of these said)" else ""}) catch return;
    s(line);
}

/// A log's first line (what to say of a failed link).
pub fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \r\n");
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(end, 300)];
}

var test_buf: [1024]u8 = undefined;
var test_len: usize = 0;

fn testSink(line: []const u8) void {
    @memcpy(test_buf[test_len..][0..line.len], line);
    test_len += line.len;
}

test "report: a kind says its lines, then no more" {
    const old = sink;
    defer sink = old;
    sink = &testSink;
    counts = [_]u8{0} ** LIMITS.len;
    test_len = 0;
    for (0..6) |n| say(.lost, "the GPU is lost ({d})", .{n});
    const out = test_buf[0..test_len];
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "the GPU is lost"));
    try std.testing.expect(std.mem.indexOf(u8, out, "(3) (the last of these said)") != null);
    try std.testing.expectEqualStrings("0:3: error: x", firstLine("\n0:3: error: x\n0:4: more\n"));
}
