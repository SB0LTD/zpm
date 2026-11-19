//! A host for tests: a folder of files held in fixed buffers (no
//! allocator), a clock that says what it is told, and a log the test can
//! read. Paths are matched exactly (the DOS side does the case folding).

const std = @import("std");
const host_mod = @import("host.sig");
const builtin = @import("builtin");

pub const MAX_FILES = 32;
pub const MAX_SIZE = 512 * 1024;
const MAX_OPEN = 16;

pub const File = struct {
    used: bool = false,
    dir: bool = false,
    name_len: u8 = 0,
    name: [96]u8 = undefined,
    size: usize = 0,
    data: [MAX_SIZE]u8 = undefined,
    pub fn path(self: *const File) []const u8 {
        return self.name[0..self.name_len];
    }
};

const Open = struct { file: ?usize = null, pos: usize = 0, write: bool = false };
const Dir = struct { used: bool = false, prefix_len: u8 = 0, prefix: [96]u8 = undefined, next: usize = 0 };

pub const TestHost = struct {
    files: [MAX_FILES]File = [_]File{.{}} ** MAX_FILES,
    open: [MAX_OPEN]Open = [_]Open{.{}} ** MAX_OPEN,
    dirs: [4]Dir = [_]Dir{.{}} ** 4,
    time: host_mod.Time = .{ .year = 1994, .month = 11, .day = 11, .weekday = 5, .hour = 12, .minute = 0, .second = 0, .hundredths = 0 },
    log_buf: [8192]u8 = undefined,
    log_len: usize = 0,
    /// Executable memory for the CPU's translator (Linux only: the JIT's
    /// tests turn it on; one region for the whole test run).
    jit: bool = false,

    pub fn host(self: *TestHost) host_mod.Host {
        return .{ .ctx = self, .vt = &vtable };
    }

    /// Puts a file (or, with `data` null, a folder) at `path`.
    pub fn put(self: *TestHost, path: []const u8, data: ?[]const u8) void {
        for (&self.files) |*f| if (!f.used) {
            f.used = true;
            f.dir = data == null;
            f.name_len = @intCast(path.len);
            @memcpy(f.name[0..path.len], path);
            if (data) |d| {
                @memcpy(f.data[0..d.len], d);
                f.size = d.len;
            }
            return;
        };
        @panic("test host: no room for another file");
    }
    pub fn find(self: *TestHost, path: []const u8) ?usize {
        for (&self.files, 0..) |*f, i| if (f.used and std.mem.eql(u8, f.path(), path)) return i;
        return null;
    }
    pub fn logged(self: *const TestHost) []const u8 {
        return self.log_buf[0..self.log_len];
    }

    fn me(ctx: *anyopaque) *TestHost {
        return @ptrCast(@alignCast(ctx));
    }

    fn openF(ctx: *anyopaque, path: []const u8, how: host_mod.Open) i32 {
        const s = me(ctx);
        var idx = s.find(path);
        if (idx == null) {
            if (!how.create) return -@intFromEnum(host_mod.Err.not_found);
            s.put(path, "");
            idx = s.find(path);
        }
        if (s.files[idx.?].dir) return -@intFromEnum(host_mod.Err.access_denied);
        if (how.truncate) s.files[idx.?].size = 0;
        for (&s.open, 0..) |*o, i| if (o.file == null) {
            o.* = .{ .file = idx, .pos = 0, .write = how.write };
            return @intCast(i);
        };
        return -@intFromEnum(host_mod.Err.too_many_open);
    }
    fn closeF(ctx: *anyopaque, h: i32) void {
        if (h >= 0 and h < MAX_OPEN) me(ctx).open[@intCast(h)].file = null;
    }
    fn readF(ctx: *anyopaque, h: i32, buf: []u8) i32 {
        const s = me(ctx);
        if (h < 0 or h >= MAX_OPEN) return -@intFromEnum(host_mod.Err.bad_handle);
        const o = &s.open[@intCast(h)];
        const f = &s.files[o.file orelse return -@intFromEnum(host_mod.Err.bad_handle)];
        const n = @min(buf.len, f.size -| o.pos);
        @memcpy(buf[0..n], f.data[o.pos..][0..n]);
        o.pos += n;
        return @intCast(n);
    }
    fn writeF(ctx: *anyopaque, h: i32, buf: []const u8) i32 {
        const s = me(ctx);
        if (h < 0 or h >= MAX_OPEN) return -@intFromEnum(host_mod.Err.bad_handle);
        const o = &s.open[@intCast(h)];
        const f = &s.files[o.file orelse return -@intFromEnum(host_mod.Err.bad_handle)];
        if (!o.write) return -@intFromEnum(host_mod.Err.access_denied);
        const n = @min(buf.len, MAX_SIZE -| o.pos);
        @memcpy(f.data[o.pos..][0..n], buf[0..n]);
        o.pos += n;
        f.size = @max(f.size, o.pos);
        return @intCast(n);
    }
    fn seekF(ctx: *anyopaque, h: i32, off: i64, whence: host_mod.Whence) i64 {
        const s = me(ctx);
        if (h < 0 or h >= MAX_OPEN) return -@intFromEnum(host_mod.Err.bad_handle);
        const o = &s.open[@intCast(h)];
        const f = &s.files[o.file orelse return -@intFromEnum(host_mod.Err.bad_handle)];
        const base: i64 = switch (whence) {
            .set => 0,
            .cur => @intCast(o.pos),
            .end => @intCast(f.size),
        };
        const p = base + off;
        if (p < 0) return -@intFromEnum(host_mod.Err.io);
        o.pos = @intCast(p);
        return p;
    }
    fn statF(ctx: *anyopaque, path: []const u8, out: *host_mod.Stat) bool {
        const s = me(ctx);
        if (path.len == 0) {
            out.* = .{ .dir = true };
            return true;
        }
        const i = s.find(path) orelse return false;
        out.* = .{ .size = s.files[i].size, .dir = s.files[i].dir, .mtime = 784_555_200 };
        return true;
    }
    fn truncateF(ctx: *anyopaque, h: i32, size: u64) bool {
        const s = me(ctx);
        if (h < 0 or h >= MAX_OPEN) return false;
        const f = &s.files[s.open[@intCast(h)].file orelse return false];
        f.size = @intCast(@min(size, MAX_SIZE));
        return true;
    }
    fn mkdirF(ctx: *anyopaque, path: []const u8) i32 {
        const s = me(ctx);
        if (s.find(path) != null) return -@intFromEnum(host_mod.Err.exists);
        s.put(path, null);
        return 0;
    }
    fn removeF(ctx: *anyopaque, path: []const u8) i32 {
        const s = me(ctx);
        const i = s.find(path) orelse return -@intFromEnum(host_mod.Err.not_found);
        s.files[i].used = false;
        return 0;
    }
    fn renameF(ctx: *anyopaque, from: []const u8, to: []const u8) i32 {
        const s = me(ctx);
        const i = s.find(from) orelse return -@intFromEnum(host_mod.Err.not_found);
        if (s.find(to) != null) return -@intFromEnum(host_mod.Err.exists);
        s.files[i].name_len = @intCast(to.len);
        @memcpy(s.files[i].name[0..to.len], to);
        return 0;
    }
    /// A folder's entries: the files whose path is `path` + "/" + a name
    /// without another '/' ("" is the root).
    fn dirOpenF(ctx: *anyopaque, path: []const u8) i32 {
        const s = me(ctx);
        for (&s.dirs, 0..) |*d, i| if (!d.used) {
            d.used = true;
            d.next = 0;
            d.prefix_len = @intCast(path.len);
            @memcpy(d.prefix[0..path.len], path);
            return @intCast(i);
        };
        return -@intFromEnum(host_mod.Err.too_many_open);
    }
    fn dirNextF(ctx: *anyopaque, h: i32, out: *host_mod.DirEntry) bool {
        const s = me(ctx);
        const d = &s.dirs[@intCast(h)];
        const pre = d.prefix[0..d.prefix_len];
        while (d.next < MAX_FILES) {
            const f = &s.files[d.next];
            d.next += 1;
            if (!f.used) continue;
            const p = f.path();
            var rest: []const u8 = undefined;
            if (pre.len == 0) {
                rest = p;
            } else {
                if (p.len <= pre.len + 1 or !std.mem.startsWith(u8, p, pre) or p[pre.len] != '/') continue;
                rest = p[pre.len + 1 ..];
            }
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            out.name_len = @intCast(rest.len);
            @memcpy(out.name[0..rest.len], rest);
            out.dir = f.dir;
            return true;
        }
        return false;
    }
    fn dirCloseF(ctx: *anyopaque, h: i32) void {
        me(ctx).dirs[@intCast(h)].used = false;
    }
    fn nowF(ctx: *anyopaque) host_mod.Time {
        return me(ctx).time;
    }
    fn logF(ctx: *anyopaque, line: []const u8) void {
        const s = me(ctx);
        const n = @min(line.len, s.log_buf.len - s.log_len -| 1);
        @memcpy(s.log_buf[s.log_len..][0..n], line[0..n]);
        s.log_len += n;
        if (s.log_len < s.log_buf.len) {
            s.log_buf[s.log_len] = '\n';
            s.log_len += 1;
        }
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
        .rmdir = removeF,
        .unlink = removeF,
        .rename = renameF,
        .dir_open = dirOpenF,
        .dir_next = dirNextF,
        .dir_close = dirCloseF,
        .now = nowF,
        .log = logF,
        .code_mem = codeMemF,
    };

    fn codeMemF(ctx: *anyopaque, len: usize) ?host_mod.CodeMem {
        if (!me(ctx).jit or builtin.os.tag != .linux) return null;
        // (AArch64's tests run under QEMU's user mode: one mapping)
        if (code_region == null) code_region = @import("host_linux.sig").mapCode(len, builtin.cpu.arch == .aarch64);
        const c = code_region orelse return null;
        return if (c.len >= len) c else null;
    }
};

var code_region: ?host_mod.CodeMem = null;
