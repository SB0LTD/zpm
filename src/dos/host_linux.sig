//! The host on Linux system calls (Galaxy's, or a Linux computer's): files
//! are the paths the DOS side gives (drive C: is a folder), folders are
//! read with getdents64, the clock is the real-time clock (UTC: Galaxy
//! keeps no time zone for DOS yet), the log goes to standard error with a
//! prefix. No libc, no allocator: galaxy-dos and the `dosrun` tool share it.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const host_mod = @import("host.sig");

const MAX_DIRS = 8;

const Dir = struct {
    fd: i32 = -1,
    buf: [4096]u8 align(8) = undefined,
    len: usize = 0,
    pos: usize = 0,
};

pub const LinuxHost = struct {
    dirs: [MAX_DIRS]Dir = [_]Dir{.{}} ** MAX_DIRS,
    /// The log's prefix ("[galaxy-dos] ").
    prefix: []const u8 = "[dos] ",
    /// Quiet: the log is kept to lines that say a program stopped.
    quiet: bool = false,
    /// Executable memory for the CPU's translator (false: none; the CPU
    /// interprets everything, e.g. galaxy-dos's GALAXY_DOS_JIT=0).
    jit: bool = true,

    pub fn host(self: *LinuxHost) host_mod.Host {
        return .{ .ctx = self, .vt = &vtable };
    }
    fn me(ctx: *anyopaque) *LinuxHost {
        return @ptrCast(@alignCast(ctx));
    }

    fn failed(r: usize) bool {
        return r > std.math.maxInt(usize) - 4096;
    }
    fn errOf(r: usize) i32 {
        const e: u16 = @intCast(0 -% r);
        return switch (e) {
            2 => -@intFromEnum(host_mod.Err.not_found),
            20 => -@intFromEnum(host_mod.Err.path_not_found),
            1, 13, 21, 30 => -@intFromEnum(host_mod.Err.access_denied),
            23, 24 => -@intFromEnum(host_mod.Err.too_many_open),
            9 => -@intFromEnum(host_mod.Err.bad_handle),
            17 => -@intFromEnum(host_mod.Err.exists),
            else => -@intFromEnum(host_mod.Err.io),
        };
    }
    fn zpath(buf: []u8, path: []const u8) ?[*:0]const u8 {
        if (path.len + 1 > buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return @ptrCast(buf.ptr);
    }

    fn openF(_: *anyopaque, path: []const u8, how: host_mod.Open) i32 {
        var pb: [1024]u8 = undefined;
        const p = zpath(&pb, path) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        var fl: linux.O = .{ .CLOEXEC = true };
        fl.ACCMODE = if (how.write and how.read) .RDWR else if (how.write) .WRONLY else .RDONLY;
        fl.CREAT = how.create;
        fl.TRUNC = how.truncate;
        const r = linux.openat(linux.AT.FDCWD, p, fl, 0o644);
        return if (failed(r)) errOf(r) else @intCast(r);
    }
    fn closeF(_: *anyopaque, h: i32) void {
        _ = linux.close(h);
    }
    fn readF(_: *anyopaque, h: i32, buf: []u8) i32 {
        const r = linux.read(h, buf.ptr, buf.len);
        return if (failed(r)) errOf(r) else @intCast(r);
    }
    fn writeF(_: *anyopaque, h: i32, buf: []const u8) i32 {
        const r = linux.write(h, buf.ptr, buf.len);
        return if (failed(r)) errOf(r) else @intCast(r);
    }
    fn seekF(_: *anyopaque, h: i32, off: i64, whence: host_mod.Whence) i64 {
        const r = linux.lseek(h, off, @intFromEnum(whence));
        return if (failed(r)) errOf(r) else @intCast(r);
    }
    fn statF(_: *anyopaque, path: []const u8, out: *host_mod.Stat) bool {
        var pb: [1024]u8 = undefined;
        const p = zpath(&pb, if (path.len == 0) "." else path) orelse return false;
        var sx: linux.Statx = undefined;
        if (failed(linux.statx(linux.AT.FDCWD, p, 0, .{ .TYPE = true, .MODE = true, .MTIME = true, .SIZE = true }, &sx))) return false;
        out.* = .{
            .size = sx.size,
            .dir = sx.mode & 0o170000 == 0o040000,
            .readonly = sx.mode & 0o200 == 0,
            .mtime = sx.mtime.sec,
        };
        return true;
    }
    fn truncateF(_: *anyopaque, h: i32, size: u64) bool {
        return !failed(linux.ftruncate(h, @intCast(size)));
    }
    fn mkdirF(_: *anyopaque, path: []const u8) i32 {
        var pb: [1024]u8 = undefined;
        const p = zpath(&pb, path) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        const r = linux.mkdirat(linux.AT.FDCWD, p, 0o755);
        return if (failed(r)) errOf(r) else 0;
    }
    fn rmdirF(_: *anyopaque, path: []const u8) i32 {
        var pb: [1024]u8 = undefined;
        const p = zpath(&pb, path) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        const r = linux.unlinkat(linux.AT.FDCWD, p, linux.AT.REMOVEDIR);
        return if (failed(r)) errOf(r) else 0;
    }
    fn unlinkF(_: *anyopaque, path: []const u8) i32 {
        var pb: [1024]u8 = undefined;
        const p = zpath(&pb, path) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        const r = linux.unlinkat(linux.AT.FDCWD, p, 0);
        return if (failed(r)) errOf(r) else 0;
    }
    fn renameF(_: *anyopaque, from: []const u8, to: []const u8) i32 {
        var ab: [1024]u8 = undefined;
        var bb: [1024]u8 = undefined;
        const a = zpath(&ab, from) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        const b = zpath(&bb, to) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        const r = linux.renameat(linux.AT.FDCWD, a, linux.AT.FDCWD, b);
        return if (failed(r)) errOf(r) else 0;
    }
    fn dirOpenF(ctx: *anyopaque, path: []const u8) i32 {
        const s = me(ctx);
        var pb: [1024]u8 = undefined;
        const p = zpath(&pb, if (path.len == 0) "." else path) orelse return -@intFromEnum(host_mod.Err.path_not_found);
        for (&s.dirs, 0..) |*d, i| if (d.fd < 0) {
            const r = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (failed(r)) return errOf(r);
            d.* = .{ .fd = @intCast(r) };
            return @intCast(i);
        };
        return -@intFromEnum(host_mod.Err.too_many_open);
    }
    fn dirNextF(ctx: *anyopaque, h: i32, out: *host_mod.DirEntry) bool {
        const s = me(ctx);
        if (h < 0 or h >= MAX_DIRS) return false;
        const d = &s.dirs[@intCast(h)];
        if (d.fd < 0) return false;
        while (true) {
            if (d.pos >= d.len) {
                const r = linux.getdents64(d.fd, &d.buf, d.buf.len);
                if (failed(r) or r == 0) return false;
                d.len = r;
                d.pos = 0;
            }
            const rec = d.buf[d.pos..];
            const reclen = std.mem.readInt(u16, rec[16..18], builtin.cpu.arch.endian());
            const kind = rec[18];
            const name = std.mem.sliceTo(rec[19..reclen], 0);
            d.pos += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name.len > out.name.len) continue;
            out.name_len = @intCast(name.len);
            @memcpy(out.name[0..name.len], name);
            out.dir = kind == 4; // DT_DIR
            return true;
        }
    }
    fn dirCloseF(ctx: *anyopaque, h: i32) void {
        const s = me(ctx);
        if (h < 0 or h >= MAX_DIRS) return;
        const d = &s.dirs[@intCast(h)];
        if (d.fd >= 0) _ = linux.close(d.fd);
        d.fd = -1;
    }
    fn nowF(_: *anyopaque) host_mod.Time {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return .{
            .year = yd.year,
            .month = md.month.numeric(),
            .day = md.day_index + 1,
            .weekday = @intCast((day.day + 4) % 7), // (1970-01-01: a Thursday)
            .hour = ds.getHoursIntoDay(),
            .minute = ds.getMinutesIntoHour(),
            .second = ds.getSecondsIntoMinute(),
            .hundredths = @intCast(@divTrunc(ts.nsec, 10_000_000)),
        };
    }
    fn logF(ctx: *anyopaque, line: []const u8) void {
        const s = me(ctx);
        var b: [400]u8 = undefined;
        const n = @min(s.prefix.len, 40);
        @memcpy(b[0..n], s.prefix[0..n]);
        const m = @min(line.len, b.len - n - 1);
        @memcpy(b[n..][0..m], line[0..m]);
        b[n + m] = '\n';
        _ = linux.write(2, &b, n + m + 1);
    }

    const vtable = host_mod.VTable{
        .open = openF,
        .close = closeF,
        .read = readF,
        .write = writeF,
        .seek = seekF,
        .stat = statF,
        .truncate = truncateF,
        .mkdir = mkdirF,
        .rmdir = rmdirF,
        .unlink = unlinkF,
        .rename = renameF,
        .dir_open = dirOpenF,
        .dir_next = dirNextF,
        .dir_close = dirCloseF,
        .now = nowF,
        .log = logF,
        .code_mem = codeMemF,
    };

    fn codeMemF(ctx: *anyopaque, len: usize) ?host_mod.CodeMem {
        if (!me(ctx).jit) return null;
        return mapCode(len);
    }
};

// ── Executable memory (the translator's code) ──────────────────────────

/// The flipping provider's region (one per process).
var flip_at: [*]u8 = undefined;
var flip_len: usize = 0;
var flip_ctx: u8 = 0;

fn flipRw(_: *anyopaque) void {
    _ = linux.mprotect(flip_at, flip_len, .{ .READ = true, .WRITE = true });
}
fn flipRx(_: *anyopaque) void {
    _ = linux.mprotect(flip_at, flip_len, .{ .READ = true, .EXEC = true });
}

/// `len` bytes of code memory: a memfd mapped twice, writable at one
/// address and executable at another (never both at one: W^X), else
/// private memory whose protection flips between writable and
/// executable around the translator's writes. Null if neither works.
pub fn mapCode(len: usize) ?host_mod.CodeMem {
    const r = linux.memfd_create("dos-jit", linux.MFD.CLOEXEC);
    if (!failedR(r)) {
        const fd: i32 = @intCast(r);
        defer _ = linux.close(fd);
        if (!failedR(linux.ftruncate(fd, @intCast(len)))) {
            const rw = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            if (!failedR(rw)) {
                const rx = linux.mmap(null, len, .{ .READ = true, .EXEC = true }, .{ .TYPE = .SHARED }, fd, 0);
                if (!failedR(rx)) return .{ .rw = @ptrFromInt(rw), .rx = @ptrFromInt(rx), .len = len, .ctx = &flip_ctx };
                _ = linux.munmap(@ptrFromInt(rw), len);
            }
        }
    }
    const a = linux.mmap(null, len, .{ .READ = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (failedR(a)) return null;
    flip_at = @ptrFromInt(a);
    flip_len = len;
    return .{ .rw = flip_at, .rx = flip_at, .len = len, .ctx = &flip_ctx, .unlock = flipRw, .lock = flipRx };
}

fn failedR(r: usize) bool {
    return r > std.math.maxInt(usize) - 4096;
}

/// The program's folder (drive C:) and its DOS path, from a host path:
/// "/winapps/games/aladdin/aladdin.exe" → "/winapps/games/aladdin",
/// "C:\ALADDIN.EXE".
pub fn splitProgram(path: []const u8, dir_buf: []u8, dos_buf: []u8) ?struct { dir: []const u8, dos_path: []const u8, name: []const u8 } {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const dir = if (slash) |s| (if (s == 0) "/" else path[0..s]) else ".";
    const name = if (slash) |s| path[s + 1 ..] else path;
    if (dir.len > dir_buf.len or name.len + 3 > dos_buf.len) return null;
    @memcpy(dir_buf[0..dir.len], dir);
    @memcpy(dos_buf[0..3], "C:\\");
    for (name, 0..) |c, i| dos_buf[3 + i] = std.ascii.toUpper(c);
    return .{ .dir = dir_buf[0..dir.len], .dos_path = dos_buf[0 .. 3 + name.len], .name = name };
}

test "host_linux: a program's folder and its DOS path" {
    var db: [64]u8 = undefined;
    var pb: [64]u8 = undefined;
    const p = splitProgram("/winapps/games/aladdin/aladdin.exe", &db, &pb).?;
    try std.testing.expectEqualStrings("/winapps/games/aladdin", p.dir);
    try std.testing.expectEqualStrings("C:\\ALADDIN.EXE", p.dos_path);
}
