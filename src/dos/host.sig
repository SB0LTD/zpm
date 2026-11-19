//! What the machine asks of the system it runs on: files (DOS's drives are
//! folders of the host's), the wall clock, and nothing else. Screen, sound
//! and input go the other way: the host pulls frames and samples from the
//! machine and pushes keys and the mouse into it (machine.sig).
//!
//! Paths given to the host are the host's own: '/'-separated, already
//! mapped from the DOS drive and already matched case-insensitively by
//! the DOS side (it lists folders through `dirOpen`/`dirNext` to find the
//! real spelling). A handle is the host's small integer; negative results
//! are errors (an `Err`'s negated value).

const std = @import("std");

pub const Err = enum(i32) {
    not_found = 2,
    path_not_found = 3,
    too_many_open = 4,
    access_denied = 5,
    bad_handle = 6,
    exists = 80,
    io = 31,
};

pub const Open = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
};

pub const Whence = enum(u2) { set = 0, cur = 1, end = 2 };

pub const Stat = struct {
    size: u64 = 0,
    dir: bool = false,
    readonly: bool = false,
    /// Seconds since 1970 (UTC; the DOS side turns it into local DOS time
    /// with `now`'s offset).
    mtime: i64 = 0,
};

pub const Time = struct {
    year: u16,
    month: u8,
    day: u8,
    weekday: u8, // 0 = Sunday
    hour: u8,
    minute: u8,
    second: u8,
    hundredths: u8,
};

pub const DirEntry = struct {
    name_len: u8 = 0,
    name: [255]u8 = undefined,
    dir: bool = false,
    pub fn str(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const VTable = struct {
    open: *const fn (ctx: *anyopaque, path: []const u8, how: Open) i32,
    close: *const fn (ctx: *anyopaque, h: i32) void,
    read: *const fn (ctx: *anyopaque, h: i32, buf: []u8) i32,
    write: *const fn (ctx: *anyopaque, h: i32, buf: []const u8) i32,
    seek: *const fn (ctx: *anyopaque, h: i32, off: i64, whence: Whence) i64,
    stat: *const fn (ctx: *anyopaque, path: []const u8, out: *Stat) bool,
    /// Set a file's size (DOS writes zero bytes to do it).
    truncate: *const fn (ctx: *anyopaque, h: i32, size: u64) bool,
    mkdir: *const fn (ctx: *anyopaque, path: []const u8) i32,
    rmdir: *const fn (ctx: *anyopaque, path: []const u8) i32,
    unlink: *const fn (ctx: *anyopaque, path: []const u8) i32,
    rename: *const fn (ctx: *anyopaque, from: []const u8, to: []const u8) i32,
    /// A folder's listing: a handle, then one entry a call (false: no more).
    dir_open: *const fn (ctx: *anyopaque, path: []const u8) i32,
    dir_next: *const fn (ctx: *anyopaque, h: i32, out: *DirEntry) bool,
    dir_close: *const fn (ctx: *anyopaque, h: i32) void,
    /// The local wall clock.
    now: *const fn (ctx: *anyopaque) Time,
    /// A line for the host's log (the machine's notices: an unknown
    /// service, a program's exit).
    log: *const fn (ctx: *anyopaque, line: []const u8) void,
};

pub const Host = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    pub fn open(h: Host, path: []const u8, how: Open) i32 {
        return h.vt.open(h.ctx, path, how);
    }
    pub fn close(h: Host, fd: i32) void {
        h.vt.close(h.ctx, fd);
    }
    pub fn read(h: Host, fd: i32, buf: []u8) i32 {
        return h.vt.read(h.ctx, fd, buf);
    }
    pub fn write(h: Host, fd: i32, buf: []const u8) i32 {
        return h.vt.write(h.ctx, fd, buf);
    }
    pub fn seek(h: Host, fd: i32, off: i64, whence: Whence) i64 {
        return h.vt.seek(h.ctx, fd, off, whence);
    }
    pub fn stat(h: Host, path: []const u8, out: *Stat) bool {
        return h.vt.stat(h.ctx, path, out);
    }
    pub fn truncate(h: Host, fd: i32, size: u64) bool {
        return h.vt.truncate(h.ctx, fd, size);
    }
    pub fn mkdir(h: Host, path: []const u8) i32 {
        return h.vt.mkdir(h.ctx, path);
    }
    pub fn rmdir(h: Host, path: []const u8) i32 {
        return h.vt.rmdir(h.ctx, path);
    }
    pub fn unlink(h: Host, path: []const u8) i32 {
        return h.vt.unlink(h.ctx, path);
    }
    pub fn rename(h: Host, from: []const u8, to: []const u8) i32 {
        return h.vt.rename(h.ctx, from, to);
    }
    pub fn dirOpen(h: Host, path: []const u8) i32 {
        return h.vt.dir_open(h.ctx, path);
    }
    pub fn dirNext(h: Host, d: i32, out: *DirEntry) bool {
        return h.vt.dir_next(h.ctx, d, out);
    }
    pub fn dirClose(h: Host, d: i32) void {
        h.vt.dir_close(h.ctx, d);
    }
    pub fn now(h: Host) Time {
        return h.vt.now(h.ctx);
    }
    pub fn log(h: Host, line: []const u8) void {
        h.vt.log(h.ctx, line);
    }
    /// A formatted log line (cut at 200 bytes).
    pub fn say(h: Host, comptime fmt: []const u8, args: anytype) void {
        var b: [200]u8 = undefined;
        const s = std.fmt.bufPrint(&b, fmt, args) catch b[0..];
        h.log(s);
    }
};
