//! Local-test transport only: fixed 127.0.0.1 endpoint, bounded buffers/timeouts.
//! No DNS, redirects, TLS fallback, external endpoint or allocator.
const std = @import("std");
pub const Error = error{ Socket, Io, Timeout, Capacity, Protocol };
const Address = extern struct { family: u16 = 2, port: u16, address: [4]u8 = .{ 127, 0, 0, 1 }, zero: [8]u8 = @splat(0) };
const Time = extern struct { seconds: i64 = 2, micros: i64 = 0 };
const w32 = @import("win32");
extern "winhttp" fn WinHttpSetOption(?*anyopaque, u32, *const anyopaque, u32) callconv(.c) i32;
const linux = std.os.linux;
fn signed(rc: usize) isize {
    return @bitCast(rc);
}
fn socket(a: c_int, t: c_int, p: c_int) c_int {
    return @intCast(signed(linux.syscall3(.socket, @intCast(a), @intCast(t), @intCast(p))));
}
fn connect(fd: c_int, a: *const Address, len: u32) c_int {
    return @intCast(signed(linux.syscall3(.connect, @intCast(fd), @intFromPtr(a), len)));
}
fn setsockopt(fd: c_int, level: c_int, option: c_int, value: *const Time, len: u32) c_int {
    return @intCast(signed(linux.syscall5(.setsockopt, @intCast(fd), @intCast(level), @intCast(option), @intFromPtr(value), len)));
}
fn send(fd: c_int, data: [*]const u8, len: usize, flags: c_int) isize {
    return signed(linux.syscall6(.sendto, @intCast(fd), @intFromPtr(data), len, @intCast(flags), 0, 0));
}
fn recv(fd: c_int, data: [*]u8, len: usize, flags: c_int) isize {
    return signed(linux.syscall6(.recvfrom, @intCast(fd), @intFromPtr(data), len, @intCast(flags), 0, 0));
}
fn close(fd: c_int) c_int {
    return @intCast(signed(linux.syscall1(.close, @intCast(fd))));
}
pub fn Client(comptime port: u16) type {
    return if (@import("builtin").os.tag == .windows) WindowsClient(port) else RawClient(port);
}
fn RawClient(comptime port: u16) type {
    return struct {
        pub fn post(body: []const u8, response: []u8) Error![]const u8 {
            const fd = socket(2, 1 | 0x80000, 6);
            if (fd < 0) return error.Socket;
            defer _ = close(fd);
            const timeout: Time = .{};
            if (setsockopt(fd, 1, 20, &timeout, @sizeOf(Time)) != 0 or setsockopt(fd, 1, 21, &timeout, @sizeOf(Time)) != 0) return error.Socket;
            const address: Address = .{ .port = @byteSwap(port) };
            if (connect(fd, &address, @sizeOf(Address)) != 0) return error.Timeout;
            var headers: [256]u8 = undefined;
            const header = std.fmt.bufPrint(&headers, "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n", .{ port, body.len }) catch return error.Capacity;
            for ([_][]const u8{ header, body }) |part| {
                var pos: usize = 0;
                while (pos < part.len) {
                    const n = send(fd, part[pos..].ptr, part.len - pos, 0x4000);
                    if (n <= 0) return error.Io;
                    pos += @intCast(n);
                }
            }
            var used: usize = 0;
            var body_at: ?usize = null;
            var length: ?usize = null;
            while (true) {
                if (used == response.len) return error.Capacity;
                const n = recv(fd, response[used..].ptr, response.len - used, 0);
                if (n < 0) return error.Timeout;
                if (n == 0) break;
                used += @intCast(n);
                if (body_at == null) if (std.mem.indexOf(u8, response[0..used], "\r\n\r\n")) |at| {
                    const raw = response[0..at];
                    if (!std.mem.startsWith(u8, raw, "HTTP/1.1 200 ") and !std.mem.startsWith(u8, raw, "HTTP/1.0 200 ")) return error.Protocol;
                    var lines = std.mem.splitSequence(u8, raw, "\r\n");
                    _ = lines.next();
                    while (lines.next()) |line| {
                        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Protocol;
                        if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
                            if (length != null) return error.Protocol;
                            length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.Protocol;
                        }
                        if (std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) return error.Protocol;
                    }
                    body_at = at + 4;
                    const size = length orelse return error.Protocol;
                    if (size > response.len - body_at.?) return error.Capacity;
                };
                if (body_at) |at| if (used >= at + length.?) {
                    if (used != at + length.?) return error.Protocol;
                    return response[at..used];
                };
            }
            return error.Protocol;
        }
    };
}

fn WindowsClient(comptime port: u16) type {
    return struct {
        pub fn post(body: []const u8, response: []u8) Error![]const u8 {
            const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
            const session = w32.WinHttpOpen(null, 1, null, null, 0) orelse return error.Socket;
            defer _ = w32.WinHttpCloseHandle(session);
            if (w32.WinHttpSetTimeouts(session, 2000, 2000, 2000, 2000) == 0) return error.Socket;
            const connection = w32.WinHttpConnect(session, utf16("127.0.0.1"), port, 0) orelse return error.Socket;
            defer _ = w32.WinHttpCloseHandle(connection);
            const request = w32.WinHttpOpenRequest(connection, utf16("POST"), utf16("/"), null, null, null, 0) orelse return error.Socket;
            defer _ = w32.WinHttpCloseHandle(request);
            const redirect_never: u32 = 0;
            if (WinHttpSetOption(request, 88, &redirect_never, 4) == 0) return error.Protocol;
            const headers = utf16("Content-Type: application/json\r\n");
            if (w32.WinHttpSendRequest(request, headers, 0xffffffff, @ptrCast(@constCast(body.ptr)), @intCast(body.len), @intCast(body.len), 0) == 0 or w32.WinHttpReceiveResponse(request, null) == 0) return error.Io;
            var status: u32 = 0;
            var size: u32 = 4;
            if (w32.WinHttpQueryHeaders(request, 0x20000013, null, &status, &size, null) == 0 or status != 200) return error.Protocol;
            var used: usize = 0;
            while (used < response.len) {
                var got: u32 = 0;
                if (w32.WinHttpReadData(request, response[used..].ptr, @intCast(response.len - used), &got) == 0) return error.Io;
                if (got == 0) return response[0..used];
                used += got;
            }
            return error.Capacity;
        }
    };
}
