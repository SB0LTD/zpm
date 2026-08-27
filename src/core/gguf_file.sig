//! GGUF File Source — file-backed random-access source for GGUF model loading.
//!
//! Provides a gguf.Source implementation backed by an OS file handle with
//! optional memory-mapping for zero-copy tensor access. Used by the inference
//! pipeline to load model weights from disk.
//!
//! Layer 1 (Platform): uses OS file APIs.
//!
//! Usage:
//!   var file_src = try GgufFile.open("~/.sig/models/qwen3-0.6b-q4k.gguf");
//!   const source = file_src.source();
//!   // Use source with gguf.parse, inference_session, etc.
//!   file_src.close();

const gguf = @import("gguf.sig");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

// ══════════════════════════════════════════════════════════════════════════════
// OS Primitives (minimal, platform-specific)
// ══════════════════════════════════════════════════════════════════════════════

// Windows
const win32 = if (native_os == .windows) struct {
    const HANDLE = *anyopaque;
    const BOOL = i32;
    const DWORD = u32;
    const LARGE_INTEGER = i64;
    const LPCWSTR = [*:0]const u16;
    const LPVOID = *anyopaque;
    const SIZE_T = usize;

    const GENERIC_READ: DWORD = 0x80000000;
    const FILE_SHARE_READ: DWORD = 1;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
    const PAGE_READONLY: DWORD = 0x02;
    const FILE_MAP_READ: DWORD = 0x04;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(~@as(usize, 0));

    extern "kernel32" fn CreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn SetFilePointerEx(hFile: HANDLE, liDistanceToMove: LARGE_INTEGER, lpNewFilePointer: ?*LARGE_INTEGER, dwMoveMethod: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetFileSize(hFile: HANDLE, lpFileSizeHigh: ?*DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileMappingW(hFile: HANDLE, lpAttributes: ?*anyopaque, flProtect: DWORD, dwMaximumSizeHigh: DWORD, dwMaximumSizeLow: DWORD, lpName: ?LPCWSTR) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(hFileMappingObject: HANDLE, dwDesiredAccess: DWORD, dwFileOffsetHigh: DWORD, dwFileOffsetLow: DWORD, dwNumberOfBytesToMap: SIZE_T) callconv(.winapi) ?[*]const u8;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: [*]const u8) callconv(.winapi) BOOL;
    extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: SIZE_T, flAllocationType: DWORD, flProtect: DWORD) callconv(.winapi) ?[*]u8;
    extern "kernel32" fn VirtualFree(lpAddress: *anyopaque, dwSize: SIZE_T, dwFreeType: DWORD) callconv(.winapi) BOOL;

    const MEM_COMMIT: DWORD = 0x1000;
    const MEM_RESERVE: DWORD = 0x2000;
    const MEM_RELEASE: DWORD = 0x8000;
    const PAGE_READWRITE: DWORD = 0x04;
} else struct {};

// POSIX
const posix = if (native_os != .windows) struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int;
    extern "c" fn close(fd: c_int) callconv(.c) c_int;
    extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) callconv(.c) isize;
    extern "c" fn fstat(fd: c_int, statbuf: *anyopaque) callconv(.c) c_int;
    extern "c" fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) callconv(.c) ?[*]const u8;
    extern "c" fn munmap(addr: *anyopaque, length: usize) callconv(.c) c_int;

    const O_RDONLY: c_int = 0;
    const O_CLOEXEC: c_int = 0o2000000;
    const PROT_READ: c_int = 1;
    const MAP_PRIVATE: c_int = 0x02;
    const MAP_FAILED: [*]const u8 = @ptrFromInt(~@as(usize, 0));
} else struct {};

// ══════════════════════════════════════════════════════════════════════════════
// UTF-8 → UTF-16 (Windows paths)
// ══════════════════════════════════════════════════════════════════════════════

fn utf8ToWide(utf8: []const u8, out: []u16) ?usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < utf8.len) {
        const byte = utf8[i];
        var cp: u32 = undefined;
        var seq: usize = undefined;
        if (byte < 0x80) { cp = byte; seq = 1; }
        else if (byte & 0xE0 == 0xC0) { if (i + 1 >= utf8.len) return null; cp = @as(u32, byte & 0x1F) << 6 | @as(u32, utf8[i+1] & 0x3F); seq = 2; }
        else if (byte & 0xF0 == 0xE0) { if (i + 2 >= utf8.len) return null; cp = @as(u32, byte & 0x0F) << 12 | @as(u32, utf8[i+1] & 0x3F) << 6 | @as(u32, utf8[i+2] & 0x3F); seq = 3; }
        else if (byte & 0xF8 == 0xF0) { if (i + 3 >= utf8.len) return null; cp = @as(u32, byte & 0x07) << 18 | @as(u32, utf8[i+1] & 0x3F) << 12 | @as(u32, utf8[i+2] & 0x3F) << 6 | @as(u32, utf8[i+3] & 0x3F); seq = 4; }
        else return null;
        i += seq;
        if (cp == '/') cp = '\\';
        if (cp <= 0xFFFF) { if (o >= out.len) return null; out[o] = @intCast(cp); o += 1; }
        else { if (o + 1 >= out.len) return null; const c = cp - 0x10000; out[o] = @intCast(0xD800 + (c >> 10)); out[o+1] = @intCast(0xDC00 + (c & 0x3FF)); o += 2; }
    }
    if (o >= out.len) return null;
    out[o] = 0;
    return o;
}

// ══════════════════════════════════════════════════════════════════════════════
// GgufFile — File-backed GGUF Source
// ══════════════════════════════════════════════════════════════════════════════

pub const GgufFile = struct {
    // Platform handle
    handle: if (native_os == .windows) win32.HANDLE else c_int,
    file_size: u64,
    // Memory-mapped view (optional, used for zero-copy tensor access)
    mmap_base: ?[*]const u8 = null,
    mmap_len: usize = 0,

    pub const OpenError = error{ FileNotFound, MmapFailed };

    /// Open a GGUF model file by path. Memory-maps the entire file for
    /// zero-copy tensor access.
    pub fn open(path: []const u8) OpenError!GgufFile {
        if (native_os == .windows) {
            return openWindows(path);
        } else {
            return openPosix(path);
        }
    }

    /// Get the gguf.Source interface for this file.
    pub fn source(self: *const GgufFile) gguf.Source {
        return .{
            .context = @ptrCast(self),
            .size = self.file_size,
            .read_at = &readAtCallback,
            .map_at = if (self.mmap_base != null) &mapAtCallback else null,
        };
    }

    /// Close the file and unmap memory.
    pub fn close(self: *GgufFile) void {
        if (native_os == .windows) {
            if (self.mmap_base) |base| _ = win32.UnmapViewOfFile(base);
            _ = win32.CloseHandle(self.handle);
        } else {
            if (self.mmap_base) |base| _ = posix.munmap(@ptrCast(@constCast(base)), self.mmap_len);
            _ = posix.close(self.handle);
        }
        self.mmap_base = null;
    }

    // ── Callbacks ────────────────────────────────────────────────────────

    fn readAtCallback(ctx: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const GgufFile = @ptrCast(@alignCast(ctx));

        // If memory-mapped, just memcpy from the map
        if (self.mmap_base) |base| {
            const off: usize = @intCast(offset);
            @memcpy(destination, base[off..][0..destination.len]);
            return true;
        }

        // Otherwise, read from file at offset
        if (native_os == .windows) {
            _ = win32.SetFilePointerEx(self.handle, @intCast(offset), null, 0);
            var bytes_read: win32.DWORD = 0;
            const ok = win32.ReadFile(self.handle, destination.ptr, @intCast(destination.len), &bytes_read, null);
            return ok != 0 and bytes_read == @as(win32.DWORD, @intCast(destination.len));
        } else {
            var total: usize = 0;
            while (total < destination.len) {
                const n = posix.pread(self.handle, destination.ptr + total, destination.len - total, @intCast(offset + total));
                if (n <= 0) return false;
                total += @intCast(n);
            }
            return true;
        }
    }

    fn mapAtCallback(ctx: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const self: *const GgufFile = @ptrCast(@alignCast(ctx));
        const base = self.mmap_base orelse return null;
        const ptr = base + @as(usize, @intCast(offset));
        // Verify alignment
        if (@intFromPtr(ptr) & (alignment - 1) != 0) return null;
        _ = length;
        return ptr;
    }

    // ── Platform open ────────────────────────────────────────────────────

    fn openWindows(path: []const u8) OpenError!GgufFile {
        var wide_buf: [32768]u16 = undefined;
        const len = utf8ToWide(path, &wide_buf) orelse return error.FileNotFound;
        _ = len;

        const handle = win32.CreateFileW(@ptrCast(&wide_buf), win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (@intFromPtr(handle) == @as(usize, @bitCast(@as(isize, -1)))) return error.FileNotFound;

        // Get file size
        var size_high: win32.DWORD = 0;
        const size_low = win32.GetFileSize(handle, &size_high);
        const file_size: u64 = @as(u64, size_high) << 32 | @as(u64, size_low);

        // Memory-map the file for zero-copy access
        var mmap_base: ?[*]const u8 = null;
        const mapping = win32.CreateFileMappingW(handle, null, win32.PAGE_READONLY, 0, 0, null);
        if (mapping) |m| {
            mmap_base = win32.MapViewOfFile(m, win32.FILE_MAP_READ, 0, 0, 0);
            _ = win32.CloseHandle(m); // mapping handle can be closed after MapViewOfFile
        }

        return .{
            .handle = handle,
            .file_size = file_size,
            .mmap_base = mmap_base,
            .mmap_len = @intCast(file_size),
        };
    }

    fn openPosix(path: []const u8) OpenError!GgufFile {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.FileNotFound;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];

        const fd = posix.open(path_z, posix.O_RDONLY | posix.O_CLOEXEC);
        if (fd < 0) return error.FileNotFound;

        // Get file size via fstat
        var stat_buf: [144]u8 = undefined; // Linux x86_64 stat is 144 bytes
        const stat_ok = posix.fstat(fd, @ptrCast(&stat_buf));
        var file_size: u64 = 0;
        if (stat_ok == 0) {
            // st_size is at offset 48 on Linux x86_64 (i64)
            const size_ptr: *const i64 = @ptrCast(@alignCast(stat_buf[48..56].ptr));
            file_size = @intCast(@max(size_ptr.*, 0));
        }

        // Memory-map the entire file
        var mmap_base: ?[*]const u8 = null;
        if (file_size > 0) {
            const result = posix.mmap(null, @intCast(file_size), posix.PROT_READ, posix.MAP_PRIVATE, fd, 0);
            if (result != posix.MAP_FAILED) {
                mmap_base = result;
            }
        }

        return .{
            .handle = fd,
            .file_size = file_size,
            .mmap_base = mmap_base,
            .mmap_len = @intCast(file_size),
        };
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Page Arena Allocator (for KV cache and working memory)
// ══════════════════════════════════════════════════════════════════════════════

/// A bump-pointer allocator backed by OS virtual memory.
/// Reserves a large virtual range and commits pages on demand.
/// Suitable for inference working memory (KV cache, activations).
pub const InferenceArena = struct {
    base: [*]u8,
    committed: usize,
    used: usize,
    capacity: usize,

    /// Default arena size: 1 GB virtual reservation.
    /// For Qwen3-0.6B with 2048 context: ~60 MB committed.
    const DEFAULT_CAPACITY: usize = 1024 * 1024 * 1024; // 1 GB
    const PAGE_SIZE: usize = 4096;

    /// Create an inference arena. Reserves virtual address space.
    pub fn init() ?InferenceArena {
        return initWithCapacity(DEFAULT_CAPACITY);
    }

    pub fn initWithCapacity(capacity: usize) ?InferenceArena {
        if (native_os == .windows) {
            const base = win32.VirtualAlloc(null, capacity, win32.MEM_RESERVE, win32.PAGE_READWRITE) orelse return null;
            return .{ .base = base, .committed = 0, .used = 0, .capacity = capacity };
        } else {
            const base = posix.mmap(null, capacity, 0, posix.MAP_PRIVATE | 0x20, -1, 0); // MAP_ANONYMOUS = 0x20
            if (base == posix.MAP_FAILED) return null;
            return .{ .base = @ptrCast(@constCast(base.?)), .committed = 0, .used = 0, .capacity = capacity };
        }
    }

    /// Allocate `byte_count` bytes with the given alignment from the arena.
    /// Commits physical pages as needed.
    pub fn alloc(self: *InferenceArena, byte_count: usize, alignment: usize) ?[*]u8 {
        // Align the current position
        const aligned_used = (self.used + alignment - 1) & ~(alignment - 1);
        const new_used = aligned_used + byte_count;
        if (new_used > self.capacity) return null;

        // Commit pages if needed
        if (new_used > self.committed) {
            const new_committed = (new_used + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
            const commit_size = new_committed - self.committed;
            if (native_os == .windows) {
                const commit_base = win32.VirtualAlloc(@ptrCast(self.base + self.committed), commit_size, win32.MEM_COMMIT, win32.PAGE_READWRITE) orelse return null;
                _ = commit_base;
            } else {
                // mmap with MAP_FIXED to commit specific range
                // Actually on Linux, MAP_ANONYMOUS + MAP_PRIVATE already gives committed-on-write.
                // We used PROT_NONE for reserve. Now mprotect to PROT_READ|PROT_WRITE.
                const mprotect = @extern(*const fn (*anyopaque, usize, c_int) callconv(.c) c_int, .{ .name = "mprotect", .library_name = "c" });
                _ = mprotect(@ptrCast(self.base + self.committed), commit_size, 1 | 2); // PROT_READ | PROT_WRITE
            }
            self.committed = new_committed;
        }

        self.used = new_used;
        return self.base + aligned_used;
    }

    /// The KV cache allocator function matching kv_cache.AllocFn signature.
    pub fn allocFn(self: *InferenceArena) *const fn (usize, usize) ?[*]u8 {
        // We need a closure-like pattern. Since Sig doesn't have closures,
        // use a global pointer (safe because inference is single-threaded
        // within the build host).
        global_arena = self;
        return &globalAllocFn;
    }

    var global_arena: ?*InferenceArena = null;

    fn globalAllocFn(byte_count: usize, alignment: usize) ?[*]u8 {
        const arena = global_arena orelse return null;
        return arena.alloc(byte_count, alignment);
    }

    /// Reset the arena for reuse (next generation). Does not decommit pages.
    pub fn reset(self: *InferenceArena) void {
        self.used = 0;
    }

    /// Release all memory back to the OS.
    pub fn deinit(self: *InferenceArena) void {
        if (native_os == .windows) {
            _ = win32.VirtualFree(@ptrCast(self.base), 0, win32.MEM_RELEASE);
        } else {
            _ = posix.munmap(@ptrCast(self.base), self.capacity);
        }
    }
};
