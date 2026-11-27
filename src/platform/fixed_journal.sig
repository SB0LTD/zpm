//! Bounded atomic durable records for standalone test nodes. No heap or secrets.
const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32");
const linux = std.os.linux;
const cwd: usize = @bitCast(@as(isize, -100));
const Error = error{ Io, Capacity, Corrupt };
extern "kernel32" fn FlushFileBuffers(w32.HANDLE) callconv(.c) i32;
extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.c) i32;
fn ok(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}
extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.c) i32;
pub fn remove(comptime path: []const u8) Error!void {
    if (builtin.os.tag == .windows) {
        if (DeleteFileW(std.unicode.utf8ToUtf16LeStringLiteral(path)) == 0 and w32.GetLastError() != 2) return error.Io;
    } else {
        const result = linux.syscall3(.unlinkat, cwd, @intFromPtr((path ++ "\x00").ptr), 0);
        if (!ok(result) and @as(isize, @bitCast(result)) != -2) return error.Io;
    }
}
pub fn load(comptime path: []const u8, out: []u8) Error!?usize {
    if (builtin.os.tag == .windows) {
        const handle = w32.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral(path), 0x80000000, 1, null, 3, 0x00200000, null);
        if (handle == w32.INVALID_HANDLE_VALUE) {
            if (w32.GetLastError() == 2) return null;
            return error.Io;
        }
        defer _ = w32.CloseHandle(handle);
        var size: u32 = 0;
        if (w32.ReadFile(handle, out.ptr, @intCast(out.len), &size, null) == 0) return error.Io;
        var extra: [1]u8 = undefined;
        var more: u32 = 0;
        if (w32.ReadFile(handle, &extra, 1, &more, null) == 0 or more != 0) return error.Corrupt;
        return size;
    } else {
        const flags: usize = 0x80000 | (if (builtin.cpu.arch == .aarch64) @as(usize, 0x8000) else 0x20000);
        const fd = linux.syscall4(.openat, cwd, @intFromPtr((path ++ "\x00").ptr), flags, 0);
        if (!ok(fd)) {
            if (@as(isize, @bitCast(fd)) == -2) return null;
            return error.Io;
        }
        defer _ = linux.syscall1(.close, fd);
        var pos: usize = 0;
        while (pos < out.len) {
            const n = linux.read(@intCast(fd), out[pos..].ptr, out.len - pos);
            if (!ok(n)) return error.Io;
            if (n == 0) return pos;
            pos += n;
        }
        var extra: [1]u8 = undefined;
        if (linux.read(@intCast(fd), &extra, 1) != 0) return error.Corrupt;
        return pos;
    }
}
const Unobserved = struct {
    pub fn beforeReplace() void {}
    pub fn afterReplace() void {}
};
pub fn save(comptime path: []const u8, data: []const u8) Error!void {
    return saveObserved(path, data, Unobserved);
}
/// Compile-time observer for crash-boundary tests. Normal save has no hooks.
/// Observers cannot report success to the application before durable replacement.
pub fn saveObserved(comptime path: []const u8, data: []const u8, comptime Observer: type) Error!void {
    if (builtin.os.tag == .windows) {
        const temporary = std.unicode.utf8ToUtf16LeStringLiteral(path ++ ".tmp");
        const handle = w32.CreateFileW(temporary, 0x40000000, 0, null, 2, 0x00200000, null);
        if (handle == w32.INVALID_HANDLE_VALUE) return error.Io;
        var written: u32 = 0;
        const success = w32.WriteFile(handle, data.ptr, @intCast(data.len), &written, null) != 0 and written == data.len and FlushFileBuffers(handle) != 0;
        _ = w32.CloseHandle(handle);
        if (!success) return error.Io;
        Observer.beforeReplace();
        if (MoveFileExW(temporary, std.unicode.utf8ToUtf16LeStringLiteral(path), 9) == 0) return error.Io;
        Observer.afterReplace();
    } else {
        const nofollow: usize = if (builtin.cpu.arch == .aarch64) 0x8000 else 0x20000;
        const fd = linux.syscall4(.openat, cwd, @intFromPtr((path ++ ".tmp\x00").ptr), 1 | 64 | 512 | 0x80000 | nofollow, 0o600);
        if (!ok(fd)) return error.Io;
        defer _ = linux.syscall1(.close, fd);
        var pos: usize = 0;
        while (pos < data.len) {
            const n = linux.write(@intCast(fd), data[pos..].ptr, data.len - pos);
            if (!ok(n) or n == 0) return error.Io;
            pos += n;
        }
        if (!ok(linux.syscall1(.fsync, fd))) return error.Io;
        Observer.beforeReplace();
        if (!ok(linux.syscall4(.renameat, cwd, @intFromPtr((path ++ ".tmp\x00").ptr), cwd, @intFromPtr((path ++ "\x00").ptr)))) return error.Io;
        const directory = comptime std.fs.path.dirname(path) orelse ".";
        const dirflag: usize = if (builtin.cpu.arch == .aarch64) 0x4000 else 0x10000;
        const dir = linux.syscall4(.openat, cwd, @intFromPtr((directory ++ "\x00").ptr), dirflag | 0x80000 | nofollow, 0);
        if (!ok(dir)) return error.Io;
        defer _ = linux.syscall1(.close, dir);
        if (!ok(linux.syscall1(.fsync, dir))) return error.Io;
        Observer.afterReplace();
    }
}
