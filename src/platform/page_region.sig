//! One caller-owned OS page reservation. No heap allocator, object allocation,
//! free list or hidden growth: callers define and validate their typed layout.
const std = @import("std");
const builtin = @import("builtin");
const Win = struct {
    extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualFree(?*anyopaque, usize, u32) callconv(.winapi) c_int;
};
const Darwin = struct {
    extern "c" fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
    extern "c" fn munmap(*anyopaque, usize) c_int;
};
pub const Error = error{ InvalidCapacity, UnsupportedPlatform, MemoryReservationFailed };
pub const Region = struct {
    bytes: []u8 = &.{},

    pub fn view(self: *const Region, comptime T: type, offset: usize, count: usize) Error![]T {
        if (offset > self.bytes.len or count > (self.bytes.len - offset) / @sizeOf(T)) return error.InvalidCapacity;
        const ptr = self.bytes.ptr + offset;
        if (@intFromPtr(ptr) % @alignOf(T) != 0) return error.InvalidCapacity;
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        return typed[0..count];
    }
    pub fn close(self: *Region) void {
        if (self.bytes.len == 0) return;
        if (builtin.os.tag == .windows) {
            _ = Win.VirtualFree(self.bytes.ptr, 0, 0x8000);
        } else if (builtin.os.tag == .linux) {
            _ = std.os.linux.munmap(self.bytes.ptr, self.bytes.len);
        } else if (builtin.os.tag == .macos) {
            _ = Darwin.munmap(self.bytes.ptr, self.bytes.len);
        }
        self.bytes = &.{};
    }
};

pub fn reserve(bytes: usize) Error!Region {
    if (bytes == 0) return error.InvalidCapacity;
    if (builtin.os.tag == .windows) {
        const ptr = Win.VirtualAlloc(null, bytes, 0x3000, 4) orelse return error.MemoryReservationFailed;
        return .{ .bytes = @as([*]u8, @ptrCast(ptr))[0..bytes] };
    } else if (builtin.os.tag == .linux) {
        const rc = std.os.linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.MemoryReservationFailed;
        return .{ .bytes = @as([*]u8, @ptrFromInt(rc))[0..bytes] };
    } else if (builtin.os.tag == .macos) {
        const ptr = Darwin.mmap(null, bytes, 3, 0x1002, -1, 0) orelse return error.MemoryReservationFailed;
        if (@intFromPtr(ptr) == ~@as(usize, 0)) return error.MemoryReservationFailed;
        return .{ .bytes = @as([*]u8, @ptrCast(ptr))[0..bytes] };
    } else return error.UnsupportedPlatform;
}
