//! sig_mem — Pure memory/slice utilities for zpm modules.
//! No std dependency. Import as: const mem = @import("sig_mem.sig");

pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub fn startsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    if (needle.len > haystack.len) return false;
    return eql(T, haystack[0..needle.len], needle);
}

pub fn endsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    if (needle.len > haystack.len) return false;
    return eql(T, haystack[haystack.len - needle.len ..], needle);
}

pub fn indexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    for (slice, 0..) |item, i| {
        if (item == value) return i;
    }
    return null;
}

pub fn lastIndexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        if (slice[i] == value) return i;
    }
    return null;
}

pub fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8, endian: Endian) T {
    const size = @sizeOf(T);
    if (endian == .little) {
        var result: T = 0;
        inline for (0..size) |i| {
            result |= @as(T, bytes[i]) << @intCast(i * 8);
        }
        return result;
    } else {
        var result: T = 0;
        inline for (0..size) |i| {
            result |= @as(T, bytes[i]) << @intCast((size - 1 - i) * 8);
        }
        return result;
    }
}

pub fn writeInt(comptime T: type, buf: *[@sizeOf(T)]u8, value: T, endian: Endian) void {
    const size = @sizeOf(T);
    if (endian == .little) {
        inline for (0..size) |i| {
            buf[i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
        }
    } else {
        inline for (0..size) |i| {
            buf[i] = @intCast((value >> @intCast((size - 1 - i) * 8)) & 0xFF);
        }
    }
}

pub const Endian = enum { little, big };

pub fn alignForward(addr: u64, alignment: u64) u64 {
    return (addr + alignment - 1) & ~(alignment - 1);
}
