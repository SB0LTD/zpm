//! App-private fixed-size seed and transaction journal files. No key export.
const std = @import("std");
const builtin = @import("builtin");
const nofollow: c_int = if (builtin.cpu.arch == .aarch64) 0x8000 else 0x20000;
const directory_flag: c_int = if (builtin.cpu.arch == .aarch64) 0x4000 else 0x10000;
pub const Error = error{ Io, Capacity, Corrupt, Entropy };
extern "c" fn open([*:0]const u8, c_int, ...) c_int;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn close(c_int) c_int;
extern "c" fn fsync(c_int) c_int;
extern "c" fn rename([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn getrandom([*]u8, usize, c_uint) isize;
extern "c" fn __errno() *c_int;
fn path(directory: []const u8, name: []const u8, buffer: *[512]u8) Error![:0]const u8 {
    const value = std.fmt.bufPrint(buffer[0 .. buffer.len - 1], "{s}/{s}", .{ directory, name }) catch return error.Capacity;
    buffer[value.len] = 0;
    return buffer[0..value.len :0];
}
pub fn load(directory: []const u8, name: []const u8, output: []u8) Error!?usize {
    var buffer: [512]u8 = undefined;
    const filename = try path(directory, name, &buffer);
    const fd = open(filename, nofollow | 0x80000);
    if (fd < 0) {
        if (__errno().* == 2) return null;
        return error.Io;
    }
    defer _ = close(fd);
    var pos: usize = 0;
    while (pos < output.len) {
        const n = read(fd, output[pos..].ptr, output.len - pos);
        if (n < 0) return error.Io;
        if (n == 0) return pos;
        pos += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    const n = read(fd, &extra, 1);
    if (n != 0) return error.Corrupt;
    return pos;
}
pub fn save(directory: []const u8, name: []const u8, data: []const u8) Error!void {
    var destination: [512]u8 = undefined;
    var temporary: [512]u8 = undefined;
    var temp_name: [128]u8 = undefined;
    const suffix = std.fmt.bufPrint(&temp_name, "{s}.pending", .{name}) catch return error.Capacity;
    const final = try path(directory, name, &destination);
    const temp = try path(directory, suffix, &temporary);
    const fd = open(temp, 1 | 64 | 512 | nofollow | 0x80000, @as(c_uint, 0o600));
    if (fd < 0) return error.Io;
    defer _ = close(fd);
    var pos: usize = 0;
    while (pos < data.len) {
        const n = write(fd, data[pos..].ptr, data.len - pos);
        if (n <= 0) return error.Io;
        pos += @intCast(n);
    }
    if (fsync(fd) != 0 or rename(temp, final) != 0) return error.Io;
    var folder: [512]u8 = undefined;
    if (directory.len >= folder.len) return error.Capacity;
    @memcpy(folder[0..directory.len], directory);
    folder[directory.len] = 0;
    const directory_z = folder[0..directory.len :0];
    const dir_fd = open(directory_z, directory_flag | 0x80000);
    if (dir_fd < 0) return error.Io;
    defer _ = close(dir_fd);
    if (fsync(dir_fd) != 0) return error.Io;
}
pub fn removeJournal(directory: []const u8) Error!void {
    var buffer: [512]u8 = undefined;
    const filename = try path(directory, "ledger-pending.bin", &buffer);
    if (unlink(filename) != 0 and __errno().* != 2) return error.Io;
}
pub fn seed(directory: []const u8, output: *[32]u8) Error!void {
    if (try load(directory, "local-test-wallet.seed", output)) |length| {
        if (length != 32) return error.Corrupt;
        return;
    }
    var pos: usize = 0;
    while (pos < output.len) {
        const n = getrandom(output[pos..].ptr, output.len - pos, 0);
        if (n <= 0) return error.Entropy;
        pos += @intCast(n);
    }
    try save(directory, "local-test-wallet.seed", output);
}
