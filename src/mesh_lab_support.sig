//! Bounded numeric arguments and wall clock for synthetic native test tools.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32");
pub fn option(init: std.process.Init, comptime name: []const u8, default: u64) !u64 {
    if (builtin.os.tag == .windows) {
        const marker = std.unicode.utf8ToUtf16LeStringLiteral("--" ++ name ++ "=");
        if (std.mem.indexOf(u16, init.minimal.args.vector, marker)) |start| {
            var value: u64 = 0;
            var found = false;
            for (init.minimal.args.vector[start + marker.len ..]) |digit| {
                if (digit < '0' or digit > '9') break;
                found = true;
                value = try std.math.mul(u64, value, 10);
                value = try std.math.add(u64, value, digit - '0');
            }
            if (!found) return error.BadArgument;
            return value;
        }
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        while (args.next()) |arg| if (std.mem.startsWith(u8, arg, "--" ++ name ++ "=")) return std.fmt.parseInt(u64, arg[name.len + 3 ..], 10);
    }
    return default;
}
pub fn nowMs() u64 {
    if (builtin.os.tag == .windows) {
        var value: w.FILETIME = .{};
        w.GetSystemTimeAsFileTime(&value);
        const ticks = (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
        return ticks / 10000 - 11644473600000;
    } else {
        var time: std.os.linux.timespec = undefined;
        _ = std.os.linux.syscall2(.clock_gettime, 0, @intFromPtr(&time));
        return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1000000;
    }
}
pub fn crash(code: u8) noreturn {
    if (builtin.os.tag == .windows) {
        const Kernel = struct {
            extern "kernel32" fn ExitProcess(u32) callconv(.c) noreturn;
        };
        Kernel.ExitProcess(code);
    } else {
        _ = std.os.linux.syscall1(.exit_group, code);
        unreachable;
    }
}
