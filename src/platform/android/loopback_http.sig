//! Local-test transport only: fixed 127.0.0.1 endpoint, bounded buffers/timeouts.
//! No DNS, redirects, TLS fallback, external endpoint or allocator.
const std = @import("std");
pub const Error = error{ Socket, Io, Timeout, Capacity, Protocol };
const Address = extern struct { family: u16 = 2, port: u16, address: [4]u8 = .{ 127, 0, 0, 1 }, zero: [8]u8 = @splat(0) };
const Time = extern struct { seconds: i64 = 2, micros: i64 = 0 };
extern "c" fn socket(c_int, c_int, c_int) c_int;
extern "c" fn connect(c_int, *const Address, u32) c_int;
extern "c" fn setsockopt(c_int, c_int, c_int, *const Time, u32) c_int;
extern "c" fn send(c_int, [*]const u8, usize, c_int) isize;
extern "c" fn recv(c_int, [*]u8, usize, c_int) isize;
extern "c" fn close(c_int) c_int;
pub fn Client(comptime port: u16) type {
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
