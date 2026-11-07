//! Executable fragmented stream/framing/transport failure contracts.
const std = @import("std");
const streams = @import("stream_server");
const Database = struct { requests: usize = 0 };
const Protocol = struct {
    const Reply = struct { consumed: usize = 0, written: usize = 0, close: bool = false };
    pub fn responseCapacity() usize {
        return 8;
    }
    pub fn handle(_: *@This(), database: *Database, input: []const u8, output: []u8) !Reply {
        if (input.len == 0) return .{};
        if (input[0] == 0) return .{ .consumed = 1, .close = true };
        const size: usize = input[0];
        if (size + 1 > input.len) return .{};
        if (size > output.len) return error.BufferTooSmall;
        @memcpy(output[0..size], input[1..][0..size]);
        database.requests += 1;
        return .{ .consumed = size + 1, .written = size };
    }
};
const Stream = streams.Server(Database, Protocol, 16);
const Io = struct {
    input: []const u8,
    at: usize = 0,
    chunk: usize = 1,
    output: [128]u8 = undefined,
    used: usize = 0,
    fail_read: bool = false,
    fail_write: bool = false,
    invalid_read: bool = false,
    pub fn read(self: *@This(), output: []u8) !usize {
        if (self.fail_read) return error.ReadFailure;
        if (self.invalid_read) return output.len + 1;
        const size = @min(@min(output.len, self.input.len - self.at), self.chunk);
        @memcpy(output[0..size], self.input[self.at..][0..size]);
        self.at += size;
        return size;
    }
    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        if (self.fail_write) return error.WriteFailure;
        if (bytes.len > self.output.len - self.used) return error.OutputFull;
        @memcpy(self.output[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
};
var assertions: usize = 0;
fn check(condition: bool) !void {
    assertions += 1;
    if (!condition) return error.StreamContractFailed;
}
pub fn main() !void {
    for (1..17) |chunk| {
        var stream: Stream = .{};
        var protocol: Protocol = .{};
        var database: Database = .{};
        var io: Io = .{ .input = "\x03one\x03two\x05three\x00ignored", .chunk = chunk };
        try stream.run(&io, &database, &protocol);
        try check(database.requests == 3);
        try check(std.mem.eql(u8, io.output[0..io.used], "onetwothree"));
    }
    var stream: Stream = .{};
    var protocol: Protocol = .{};
    var database: Database = .{};
    var empty: Io = .{ .input = "" };
    try stream.run(&empty, &database, &protocol);
    try check(database.requests == 0);
    var truncated: Io = .{ .input = "\x03ab" };
    if (stream.run(&truncated, &database, &protocol)) |_| return error.ExpectedFailure else |err| try check(err == error.UnexpectedEndOfStream);
    var overflow: Io = .{ .input = "\x20abcdefghijklmnopq", .chunk = 16 };
    if (stream.run(&overflow, &database, &protocol)) |_| return error.ExpectedFailure else |err| try check(err == error.RequestTooLarge);
    var bad_read: Io = .{ .input = "", .invalid_read = true };
    if (stream.run(&bad_read, &database, &protocol)) |_| return error.ExpectedFailure else |err| try check(err == error.InvalidReadCount);
    var failed_read: Io = .{ .input = "", .fail_read = true };
    if (stream.run(&failed_read, &database, &protocol)) |_| return error.ExpectedFailure else |err| try check(err == error.ReadFailure);
    var failed_write: Io = .{ .input = "\x01a", .fail_write = true };
    if (stream.run(&failed_write, &database, &protocol)) |_| return error.ExpectedFailure else |err| try check(err == error.WriteFailure);
    // The same caller-owned buffers can serve another connection after failure.
    var next: Io = .{ .input = "\x03new" };
    try stream.run(&next, &database, &protocol);
    try check(std.mem.eql(u8, next.output[0..next.used], "new"));
    std.debug.print("{{\"suite\":\"db-stream\",\"assertions\":{d}}}\n", .{assertions});
}
