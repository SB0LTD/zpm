//! Small Win32 transport for fixed-buffer commissioning tools. No CRT/libc/heap.
const cc: @import("std").builtin.CallingConvention = .c;
pub const Handle = *anyopaque;
extern "kernel32" fn GetCommandLineW() callconv(cc) [*:0]const u16;
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(cc) Handle;
extern "kernel32" fn CloseHandle(Handle) callconv(cc) i32;
extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(cc) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(cc) i32;
extern "kernel32" fn GetStdHandle(u32) callconv(cc) Handle;
extern "kernel32" fn GetTickCount() callconv(cc) u32;
extern "kernel32" fn Sleep(u32) callconv(cc) void;
extern "kernel32" fn GetConsoleMode(Handle, *u32) callconv(cc) i32;
extern "kernel32" fn SetConsoleMode(Handle, u32) callconv(cc) i32;
extern "kernel32" fn GetNumberOfConsoleInputEvents(Handle, *u32) callconv(cc) i32;
extern "kernel32" fn ReadConsoleInputW(Handle, *Input, u32, *u32) callconv(cc) i32;
extern "kernel32" fn SetCommState(Handle, *const Dcb) callconv(cc) i32;
extern "kernel32" fn SetCommTimeouts(Handle, *const Timeouts) callconv(cc) i32;
extern "kernel32" fn PurgeComm(Handle, u32) callconv(cc) i32;
const Input = extern struct { kind: u16, padding: u16, data: [16]u8 };
const Dcb = extern struct { length: u32 = 28, baud: u32 = 115200, flags: u32 = 0x1011, reserved: u16 = 0, xon_limit: u16 = 0, xoff_limit: u16 = 0, byte_size: u8 = 8, parity: u8 = 0, stop_bits: u8 = 0, xon: i8 = 17, xoff: i8 = 19, err: i8 = 0, eof: i8 = 0, event: i8 = 0, reserved1: u16 = 0 };
const Timeouts = extern struct { interval: u32 = 0xffffffff, multiplier: u32 = 0, constant: u32 = 0, write_multiplier: u32 = 0, write_constant: u32 = 500 };
pub const Error = error{ Path, Open, Read, Write, Serial, Args, Console };
pub const Args = struct {
    storage: [12][512]u8 = undefined,
    lens: [12]usize = @splat(0),
    count: usize = 0,
    pub fn get(self: *const Args, i: usize) []const u8 {
        return self.storage[i][0..self.lens[i]];
    }
    pub fn load() Error!Args {
        var result: Args = .{};
        const line = GetCommandLineW();
        var i: usize = 0;
        while (line[i] != 0) {
            while (line[i] == ' ' or line[i] == '\t') i += 1;
            if (line[i] == 0) break;
            if (result.count >= 12) return error.Args;
            var quoted = false;
            var n: usize = 0;
            while (line[i] != 0 and (quoted or (line[i] != ' ' and line[i] != '\t'))) : (i += 1) {
                const c = line[i];
                if (c == '"') {
                    quoted = !quoted;
                    continue;
                }
                if (c > 127 or n >= 512) return error.Args;
                result.storage[result.count][n] = @intCast(c);
                n += 1;
            }
            if (quoted) return error.Args;
            result.lens[result.count] = n;
            result.count += 1;
        }
        return result;
    }
};
pub fn open(path: []const u8, writable: bool) Error!Handle {
    var z: [600:0]u8 = @splat(0);
    if (path.len >= 600) return error.Path;
    @memcpy(z[0..path.len], path);
    const h = CreateFileA(&z, if (writable) 0x40000000 else 0x80000000, 0, null, if (writable) @as(u32, 2) else 3, 0, null);
    if (@intFromPtr(h) == ~@as(usize, 0)) return error.Open;
    return h;
}
pub fn serial(port: []const u8) Error!Handle {
    return serialBaud(port, 115200);
}
pub fn serialBaud(port: []const u8, baud: u32) Error!Handle {
    if (port.len < 4 or port.len > 12 or !equal(port[0..3], "COM")) return error.Path;
    for (port[3..]) |b| if (b < '0' or b > '9') return error.Path;
    var z: [32:0]u8 = @splat(0);
    @memcpy(z[0..4], "\\\\.\\");
    @memcpy(z[4..][0..port.len], port);
    const h = CreateFileA(&z, 0xc0000000, 0, null, 3, 0, null);
    if (@intFromPtr(h) == ~@as(usize, 0)) return error.Open;
    const d: Dcb = .{ .baud = baud };
    const timeout: Timeouts = .{};
    if (SetCommState(h, &d) == 0 or SetCommTimeouts(h, &timeout) == 0) {
        close(h);
        return error.Serial;
    }
    // Discard receive residue only; clearing TX here can drop a queued broadcast.
    _ = PurgeComm(h, 10);
    return h;
}
pub fn close(h: Handle) void {
    _ = CloseHandle(h);
}
pub fn read(h: Handle, out: []u8) Error!usize {
    var n: u32 = 0;
    if (ReadFile(h, out.ptr, @intCast(out.len), &n, null) == 0) return error.Read;
    return n;
}
pub fn write(h: Handle, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var n: u32 = 0;
        if (WriteFile(h, bytes[offset..].ptr, @intCast(bytes.len - offset), &n, null) == 0 or n == 0) return error.Write;
        offset += n;
    }
}
pub fn print(bytes: []const u8) void {
    write(GetStdHandle(0xfffffff5), bytes) catch {};
}
pub fn number(value: i64) void {
    var data: [24]u8 = undefined;
    var n: usize = 24;
    var v: u64 = @intCast(if (value < 0) -value else value);
    while (true) {
        n -= 1;
        data[n] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
        if (v == 0) break;
    }
    if (value < 0) {
        n -= 1;
        data[n] = '-';
    }
    print(data[n..]);
}
pub fn now() u32 {
    return GetTickCount();
}
pub fn sleep(ms: u32) void {
    Sleep(ms);
}
pub fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
/// Console events are polled without blocking the USB heartbeat.
pub fn key() Error!?u8 {
    const input = GetStdHandle(0xfffffff6);
    var available: u32 = 0;
    if (GetNumberOfConsoleInputEvents(input, &available) == 0) return error.Console;
    if (available == 0) return null;
    var event: Input = undefined;
    var count: u32 = 0;
    if (ReadConsoleInputW(input, &event, 1, &count) == 0) return error.Console;
    if (count == 0 or event.kind != 1 or event.data[0] == 0) return null;
    const ch = @as(u16, event.data[10]) | (@as(u16, event.data[11]) << 8);
    if (ch > 127 or ch == 0) return null;
    return @intCast(ch);
}

pub fn consoleStart() Error!u32 {
    const h = GetStdHandle(0xfffffff6);
    var mode: u32 = 0;
    if (GetConsoleMode(h, &mode) == 0) return error.Console;
    if (SetConsoleMode(h, (mode & ~@as(u32, 0x47)) | 0x80) == 0) return error.Console;
    return mode;
}
pub fn consoleRestore(mode: u32) void {
    _ = SetConsoleMode(GetStdHandle(0xfffffff6), mode);
}

pub fn purge(h: Handle) Error!void {
    if (PurgeComm(h, 10) == 0) return error.Serial;
}
