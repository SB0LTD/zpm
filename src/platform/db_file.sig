//! Single-writer durable database files for Windows, Linux and macOS, no heap.
//! All operations are synchronous; a handle belongs to one reactor/thread.
//! Windows share modes and POSIX flock exclude cooperating writer processes.
//! Every append/sync failure poisons this handle until it is closed and recovered.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const darwin = std.c;
const windows = builtin.os.tag == .windows;
const Handle = if (windows) ?*anyopaque else linux.fd_t;
const invalid: Handle = if (windows) @ptrFromInt(~@as(usize, 0)) else -1;
pub const Error = error{ UnsupportedPlatform, InvalidPath, PathTooLong, FileOpenFailed, DataDirectoryBusy, FileReadFailed, FileWriteFailed, FileSyncFailed, FileSeekFailed, FileTruncateFailed, FileRenameFailed, FileRemoveFailed, WriterPoisoned };
const Win = struct {
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn ReadFile(?*anyopaque, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn FlushFileBuffers(?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn SetFilePointerEx(?*anyopaque, i64, ?*i64, u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetEndOfFile(?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) c_int;
    extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.winapi) c_int;
};
const path_capacity = 4096;
fn validatePath(path: []const u8) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len >= path_capacity) return error.PathTooLong;
    for (path) |byte| if (byte == 0) return error.InvalidPath;
}
fn widePath(path: []const u8, out: *[path_capacity]u16) Error![:0]const u16 {
    try validatePath(path);
    const len = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], path) catch return error.InvalidPath;
    out[len] = 0;
    return out[0..len :0];
}
fn narrowPath(path: []const u8, out: *[path_capacity]u8) Error![:0]const u8 {
    try validatePath(path);
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return out[0..path.len :0];
}

pub const File = struct {
    handle: Handle = invalid,
    poisoned: bool = false,

    /// Creates if absent, preserving existing bytes. Hold until server shutdown.
    pub fn open(path: []const u8) Error!File {
        return openImpl(path, false, true);
    }
    /// Open and lock a required source; never create a missing database.
    pub fn openExisting(path: []const u8) Error!File {
        return openImpl(path, false, false);
    }
    /// Snapshot temporary files must be new; never truncate an existing file.
    pub fn createExclusive(path: []const u8) Error!File {
        return openImpl(path, true, true);
    }
    /// Read-only, shared and unlocked (resource files such as TZif zone
    /// data); follows symbolic links, never creates. Only readAt/length/close
    /// are meaningful on the handle.
    pub fn openReadOnly(path: []const u8) Error!File {
        var file: File = .{};
        if (windows) {
            var path_buf: [path_capacity]u16 = undefined;
            const z = try widePath(path, &path_buf);
            // GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING.
            file.handle = Win.CreateFileW(z.ptr, 0x80000000, 3, null, 3, 0x80, null);
            if (file.handle == invalid) return error.FileOpenFailed;
        } else if (builtin.os.tag == .linux) {
            var path_buf: [path_capacity]u8 = undefined;
            const z = try narrowPath(path, &path_buf);
            const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
            const rc = linux.openat(linux.AT.FDCWD, z.ptr, flags, 0);
            if (linux.errno(rc) != .SUCCESS) return error.FileOpenFailed;
            file.handle = @intCast(rc);
        } else if (builtin.os.tag == .macos) {
            var path_buf: [path_capacity]u8 = undefined;
            const z = try narrowPath(path, &path_buf);
            const flags: darwin.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
            const fd = darwin.open(z.ptr, flags, @as(c_uint, 0));
            if (fd < 0) return error.FileOpenFailed;
            file.handle = fd;
        } else return error.UnsupportedPlatform;
        return file;
    }
    fn openImpl(path: []const u8, exclusive: bool, create: bool) Error!File {
        var file: File = .{};
        if (windows) {
            var path_buf: [path_capacity]u16 = undefined;
            const z = try widePath(path, &path_buf);
            file.handle = Win.CreateFileW(z.ptr, 0xc0000000, 1, null, if (exclusive) 1 else if (create) 4 else 3, 0x80, null);
            if (file.handle == invalid) {
                if (Win.GetLastError() == 32) return error.DataDirectoryBusy;
                return error.FileOpenFailed;
            }
        } else if (builtin.os.tag == .linux) {
            var path_buf: [path_capacity]u8 = undefined;
            const z = try narrowPath(path, &path_buf);
            const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = create, .CLOEXEC = true, .NOFOLLOW = true, .EXCL = exclusive };
            const rc = linux.openat(linux.AT.FDCWD, z.ptr, flags, 0o600);
            if (linux.errno(rc) != .SUCCESS) return error.FileOpenFailed;
            file.handle = @intCast(rc);
            if (linux.errno(linux.flock(file.handle, 2 | 4)) != .SUCCESS) { // LOCK_EX | LOCK_NB
                file.close();
                return error.DataDirectoryBusy;
            }
        } else if (builtin.os.tag == .macos) {
            var path_buf: [path_capacity]u8 = undefined;
            const z = try narrowPath(path, &path_buf);
            const flags: darwin.O = .{ .ACCMODE = .RDWR, .CREAT = create, .CLOEXEC = true, .NOFOLLOW = true, .EXCL = exclusive };
            const fd = darwin.open(z.ptr, flags, @as(c_uint, 0o600));
            if (fd < 0) return error.FileOpenFailed;
            file.handle = fd;
            while (darwin.flock(file.handle, darwin.LOCK.EX | darwin.LOCK.NB) != 0) {
                if (darwin.errno(@as(c_int, -1)) == .INTR) continue;
                file.close();
                return error.DataDirectoryBusy;
            }
        } else return error.UnsupportedPlatform;
        errdefer file.close();
        // Sync directory entries before any durable transaction can be promised.
        try syncParent(path);
        return file;
    }
    pub fn close(self: *File) void {
        if (self.handle == invalid) return;
        if (windows) {
            _ = Win.CloseHandle(self.handle);
        } else if (builtin.os.tag == .linux) {
            _ = linux.close(self.handle);
        } else if (builtin.os.tag == .macos) {
            _ = darwin.close(self.handle);
        }
        self.handle = invalid;
    }
    fn seek(self: *File, offset: u64, whence: u32) Error!u64 {
        if (offset > 0x7fffffffffffffff) return error.FileSeekFailed;
        if (windows) {
            var position: i64 = 0;
            if (Win.SetFilePointerEx(self.handle, @intCast(offset), &position, whence) == 0 or position < 0) return error.FileSeekFailed;
            return @intCast(position);
        } else if (builtin.os.tag == .linux) {
            const rc = linux.lseek(self.handle, @intCast(offset), whence);
            if (linux.errno(@intCast(rc)) != .SUCCESS) return error.FileSeekFailed;
            return rc;
        } else if (builtin.os.tag == .macos) {
            while (true) {
                const rc = darwin.lseek(self.handle, @intCast(offset), @intCast(whence));
                if (rc >= 0) return @intCast(rc);
                if (darwin.errno(rc) != .INTR) return error.FileSeekFailed;
            }
        } else return error.UnsupportedPlatform;
    }
    pub fn length(self: *File) Error!u64 {
        return self.seek(0, 2);
    }
    pub fn readAt(self: *File, offset: u64, buffer: []u8) Error!usize {
        if (buffer.len == 0) return 0;
        if (offset > 0x7fffffffffffffff) return error.FileSeekFailed;
        if (windows) {
            _ = try self.seek(offset, 0);
            var read: u32 = 0;
            if (Win.ReadFile(self.handle, buffer.ptr, @intCast(@min(buffer.len, 0x7fffffff)), &read, null) == 0) return error.FileReadFailed;
            return read;
        } else if (builtin.os.tag == .linux) {
            while (true) {
                const rc = linux.pread(self.handle, buffer.ptr, buffer.len, @intCast(offset));
                switch (linux.errno(rc)) {
                    .SUCCESS => return rc,
                    .INTR => continue,
                    else => return error.FileReadFailed,
                }
            }
        } else if (builtin.os.tag == .macos) {
            while (true) {
                const rc = darwin.pread(self.handle, buffer.ptr, buffer.len, @intCast(offset));
                if (rc >= 0) return @intCast(rc);
                if (darwin.errno(rc) != .INTR) return error.FileReadFailed;
            }
        } else return error.UnsupportedPlatform;
    }
    pub fn appendAll(self: *File, bytes: []const u8) Error!void {
        if (self.poisoned) return error.WriterPoisoned;
        errdefer self.poisoned = true;
        _ = try self.seek(0, 2);
        var done: usize = 0;
        while (done < bytes.len) {
            var count: usize = 0;
            if (windows) {
                var written: u32 = 0;
                if (Win.WriteFile(self.handle, bytes[done..].ptr, @intCast(@min(bytes.len - done, 0x7fffffff)), &written, null) == 0) return error.FileWriteFailed;
                count = written;
            } else if (builtin.os.tag == .linux) {
                const rc = linux.write(self.handle, bytes[done..].ptr, bytes.len - done);
                switch (linux.errno(rc)) {
                    .SUCCESS => count = rc,
                    .INTR => continue,
                    else => return error.FileWriteFailed,
                }
            } else if (builtin.os.tag == .macos) {
                const rc = darwin.write(self.handle, bytes[done..].ptr, bytes.len - done);
                if (rc < 0) {
                    if (darwin.errno(rc) == .INTR) continue;
                    return error.FileWriteFailed;
                }
                count = @intCast(rc);
            } else return error.UnsupportedPlatform;
            if (count == 0 or count > bytes.len - done) return error.FileWriteFailed;
            done += count;
        }
    }
    pub fn sync(self: *File) Error!void {
        if (self.poisoned) return error.WriterPoisoned;
        errdefer self.poisoned = true;
        if (windows) {
            if (Win.FlushFileBuffers(self.handle) == 0) return error.FileSyncFailed;
        } else if (builtin.os.tag == .linux) {
            while (true) {
                switch (linux.errno(linux.fsync(self.handle))) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => return error.FileSyncFailed,
                }
            }
        } else if (builtin.os.tag == .macos) {
            // Apple documents fsync as insufficient for ordered database
            // commits: F_FULLFSYNC also flushes the device's write cache.
            // Fail closed on unsupported storage instead of weakening durability.
            while (darwin.fcntl(self.handle, darwin.F.FULLFSYNC, @as(c_int, 0)) != 0) {
                if (darwin.errno(@as(c_int, -1)) != .INTR) return error.FileSyncFailed;
            }
        } else return error.UnsupportedPlatform;
    }
    pub fn truncate(self: *File, size: u64) Error!void {
        if (self.poisoned) return error.WriterPoisoned;
        errdefer self.poisoned = true;
        if (size > 0x7fffffffffffffff) return error.FileTruncateFailed;
        if (windows) {
            _ = try self.seek(size, 0);
            if (Win.SetEndOfFile(self.handle) == 0) return error.FileTruncateFailed;
        } else if (builtin.os.tag == .linux) {
            while (true) {
                switch (linux.errno(linux.ftruncate(self.handle, @intCast(size)))) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => return error.FileTruncateFailed,
                }
            }
        } else if (builtin.os.tag == .macos) {
            while (darwin.ftruncate(self.handle, @intCast(size)) != 0) {
                if (darwin.errno(@as(c_int, -1)) != .INTR) return error.FileTruncateFailed;
            }
        } else return error.UnsupportedPlatform;
    }
};

/// Call after temporary.sync() and temporary.close(). Caller must hold a
/// SEPARATE database lock for the whole checkpoint protocol: replacing a file
/// does not transfer its inode/handle lock. WAL itself must never be replaced.
/// temporary and target must reside on the same filesystem. Keeps old target on
/// failure before rename; after rename failure to sync means outcome is uncertain.
pub fn replaceAtomic(temporary: []const u8, target: []const u8) Error!void {
    if (windows) {
        var a: [path_capacity]u16 = undefined;
        var b: [path_capacity]u16 = undefined;
        const az = try widePath(temporary, &a);
        const bz = try widePath(target, &b);
        if (Win.MoveFileExW(az.ptr, bz.ptr, 1 | 8) == 0) return error.FileRenameFailed;
    } else if (builtin.os.tag == .linux) {
        var a: [path_capacity]u8 = undefined;
        var b: [path_capacity]u8 = undefined;
        const az = try narrowPath(temporary, &a);
        const bz = try narrowPath(target, &b);
        if (linux.errno(linux.renameat(linux.AT.FDCWD, az.ptr, linux.AT.FDCWD, bz.ptr)) != .SUCCESS) return error.FileRenameFailed;
        try syncParent(target);
        // Also persist removal of the source name when directories differ.
        try syncParent(temporary);
    } else if (builtin.os.tag == .macos) {
        var a: [path_capacity]u8 = undefined;
        var b: [path_capacity]u8 = undefined;
        const az = try narrowPath(temporary, &a);
        const bz = try narrowPath(target, &b);
        if (darwin.renameat(darwin.AT.FDCWD, az.ptr, darwin.AT.FDCWD, bz.ptr) != 0) return error.FileRenameFailed;
        try syncParent(target);
        try syncParent(temporary);
        try syncDarwinPublished(target);
    } else return error.UnsupportedPlatform;
}

/// Publish a fully synced, closed temporary file atomically at a NEW target.
/// Never replaces any existing destination (including symlinks). Source and
/// target must be on one filesystem. A failure after rename but during directory
/// sync has an uncertain outcome; callers must inspect rather than overwrite.
pub fn publishNew(temporary: []const u8, target: []const u8) Error!void {
    if (windows) {
        var a: [path_capacity]u16 = undefined;
        var b: [path_capacity]u16 = undefined;
        const az = try widePath(temporary, &a);
        const bz = try widePath(target, &b);
        if (Win.MoveFileExW(az.ptr, bz.ptr, 8) == 0) return error.FileRenameFailed;
    } else if (builtin.os.tag == .linux) {
        var a: [path_capacity]u8 = undefined;
        var b: [path_capacity]u8 = undefined;
        const az = try narrowPath(temporary, &a);
        const bz = try narrowPath(target, &b);
        const renamed = linux.errno(linux.renameat2(linux.AT.FDCWD, az.ptr, linux.AT.FDCWD, bz.ptr, .{ .NOREPLACE = true }));
        if (renamed != .SUCCESS) {
            // DrvFS and older filesystems may not implement RENAME_NOREPLACE.
            // linkat still atomically refuses any existing target; persist its
            // new name before retiring the temporary. Never use plain rename.
            if (renamed != .INVAL and renamed != .NOSYS and renamed != .OPNOTSUPP) return error.FileRenameFailed;
            if (linux.errno(linux.linkat(linux.AT.FDCWD, az.ptr, linux.AT.FDCWD, bz.ptr, 0)) != .SUCCESS) return error.FileRenameFailed;
            try syncParent(target);
            if (linux.errno(linux.unlinkat(linux.AT.FDCWD, az.ptr, 0)) != .SUCCESS) return error.FileRenameFailed;
        }
        try syncParent(target);
        try syncParent(temporary);
    } else if (builtin.os.tag == .macos) {
        var a: [path_capacity]u8 = undefined;
        var b: [path_capacity]u8 = undefined;
        const az = try narrowPath(temporary, &a);
        const bz = try narrowPath(target, &b);
        // Native RENAME_EXCL atomically refuses files, directories and symlinks.
        const rc = darwin.renameatx_np(darwin.AT.FDCWD, az.ptr, darwin.AT.FDCWD, bz.ptr, .{ .EXCL = true });
        if (rc != 0) {
            const err = darwin.errno(rc);
            if (err != .INVAL and err != .OPNOTSUPP and err != .NOSYS) return error.FileRenameFailed;
            // Filesystems without RENAME_EXCL can atomically publish a hard
            // link. Sync that name before retiring the source; never plain rename.
            if (darwin.linkat(darwin.AT.FDCWD, az.ptr, darwin.AT.FDCWD, bz.ptr, 0) != 0) return error.FileRenameFailed;
            try syncParent(target);
            if (darwin.unlinkat(darwin.AT.FDCWD, az.ptr, 0) != 0) return error.FileRenameFailed;
        }
        try syncParent(target);
        try syncParent(temporary);
        try syncDarwinPublished(target);
    } else return error.UnsupportedPlatform;
}

/// A directory fsync pushes its metadata to the device; Darwin's subsequent
/// full-sync of the published file also orders the device-cache flush. The
/// existing inode is opened read-only, without following a substituted symlink.
fn syncDarwinPublished(path: []const u8) Error!void {
    if (builtin.os.tag != .macos) return;
    var buf: [path_capacity]u8 = undefined;
    const z = try narrowPath(path, &buf);
    const fd = darwin.open(z.ptr, .{ .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return error.FileSyncFailed;
    defer _ = darwin.close(fd);
    while (darwin.fcntl(fd, darwin.F.FULLFSYNC, @as(c_int, 0)) != 0) {
        if (darwin.errno(@as(c_int, -1)) != .INTR) return error.FileSyncFailed;
    }
}

fn syncParent(path: []const u8) Error!void {
    if (windows) return; // MoveFileEx WRITE_THROUGH; file FlushFileBuffers on commits.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var end: usize = 0;
    for (path, 0..) |byte, i| if (byte == '/') {
        end = if (i == 0) 1 else i;
    };
    const parent = if (end == 0) "." else path[0..end];
    var buf: [path_capacity]u8 = undefined;
    const z = try narrowPath(parent, &buf);
    if (builtin.os.tag == .macos) {
        const fd = darwin.open(z.ptr, .{ .DIRECTORY = true, .CLOEXEC = true });
        if (fd < 0) return error.FileSyncFailed;
        defer _ = darwin.close(fd);
        while (darwin.fsync(fd) != 0) {
            if (darwin.errno(@as(c_int, -1)) != .INTR) return error.FileSyncFailed;
        }
    } else {
        const rc = linux.openat(linux.AT.FDCWD, z.ptr, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.FileSyncFailed;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        while (true) {
            switch (linux.errno(linux.fsync(fd))) {
                .SUCCESS => return,
                .INTR => continue,
                else => return error.FileSyncFailed,
            }
        }
    }
}

/// Intended for caller-owned retired snapshots/test artifacts; never active WAL.
pub fn remove(path: []const u8) Error!void {
    if (windows) {
        var buf: [path_capacity]u16 = undefined;
        const z = try widePath(path, &buf);
        if (Win.DeleteFileW(z.ptr) == 0) return error.FileRemoveFailed;
    } else if (builtin.os.tag == .linux) {
        var buf: [path_capacity]u8 = undefined;
        const z = try narrowPath(path, &buf);
        if (linux.errno(linux.unlinkat(linux.AT.FDCWD, z.ptr, 0)) != .SUCCESS) return error.FileRemoveFailed;
        try syncParent(path);
    } else if (builtin.os.tag == .macos) {
        var buf: [path_capacity]u8 = undefined;
        const z = try narrowPath(path, &buf);
        if (darwin.unlinkat(darwin.AT.FDCWD, z.ptr, 0) != 0) return error.FileRemoveFailed;
        try syncParent(path);
    } else return error.UnsupportedPlatform;
}
