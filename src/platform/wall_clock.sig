//! Real-time (wall) clock in microseconds since the Unix epoch (Layer 1).
//! Per-OS structure follows entropy.sig: Windows uses
//! GetSystemTimePreciseAsFileTime and POSIX clock_gettime(CLOCK_REALTIME).
//! Linux libc uses the vDSO when available, retaining its syscall fallback.
//! Any other target (native
//! SB0 today) reports ClockUnavailable; callers fail statements that need the
//! clock (SQL now(), current_timestamp) instead of inventing a time.
const std = @import("std");
const builtin = @import("builtin");

const Win = struct {
    extern "kernel32" fn GetSystemTimePreciseAsFileTime(*u64) callconv(.c) void;
};
const Posix = struct {
    const Timespec = extern struct { sec: isize, nsec: isize };
    extern "c" fn clock_gettime(c_int, *Timespec) c_int;
};

pub const Error = error{ClockUnavailable};

/// Whether this target has a wall clock at all.
pub const available = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos;

/// 100 ns FILETIME ticks between 1601-01-01 and 1970-01-01.
const filetime_unix_offset: u64 = 116444736000000000;

/// Microseconds since 1970-01-01 00:00:00 UTC.
pub fn nowUs() Error!i64 {
    if (builtin.os.tag == .windows) {
        var ticks: u64 = 0;
        Win.GetSystemTimePreciseAsFileTime(&ticks);
        if (ticks < filetime_unix_offset) return error.ClockUnavailable;
        return @intCast((ticks - filetime_unix_offset) / 10);
    } else if (builtin.os.tag == .linux and !builtin.link_libc) {
        // Standard Linux vDSO lookup and syscall fallback require no libc/TLS
        // allocation. This keeps caller-owned native workers usable.
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.errno(std.os.linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return error.ClockUnavailable;
        return @as(i64, @intCast(ts.sec)) * 1000000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
    } else if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        var ts: Posix.Timespec = undefined;
        if (Posix.clock_gettime(0, &ts) != 0) return error.ClockUnavailable; // CLOCK_REALTIME
        return @as(i64, @intCast(ts.sec)) * 1000000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
    } else return error.ClockUnavailable;
}
