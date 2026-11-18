//! Linux wire adapter for the caller-buffered TLS stream contract.
const std = @import("std");
const fixture = @import("fixture");
const tls = @import("server.sig");
const transport = @import("stream.sig");

const expected = "ZPM TLS request\n";
const response = "ZPM TLS response\n";
const fragment_bytes = 7;

fn appendInput(stream: *transport.Stream) !void {
    const space = stream.input();
    if (space.len == 0) return error.TestInputTooLarge;
    while (true) {
        const rc = std.os.linux.read(0, space.ptr, @min(space.len, fragment_bytes));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    try stream.eof();
                    return error.TestUnexpectedEof;
                }
                return stream.received(rc);
            },
            .INTR => continue,
            else => return error.TestReadFailed,
        }
    }
}

fn drain(stream: *transport.Stream) !void {
    while (stream.output().len != 0) {
        const pending = stream.output();
        const rc = std.os.linux.write(1, pending.ptr, @min(pending.len, fragment_bytes));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TestWriteFailed;
                try stream.sent(rc);
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

pub fn main() !void {
    var identity = try tls.Identity.init(&.{fixture.certificate}, &fixture.private_key);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&identity.key_pair));
    var receive: [transport.record_capacity]u8 = undefined;
    var send: [transport.record_capacity]u8 = undefined;
    var hello_buffer: [4096]u8 = undefined;
    var flight: [8192]u8 = undefined;
    var stream = try transport.Stream.init(&identity, .{
        .receive = &receive, .send = &send, .hello = &hello_buffer, .flight = &flight,
    });
    defer stream.close();
    var observed: [expected.len]u8 = undefined;
    var length: usize = 0;
    while (length < observed.len) {
        switch (try stream.next()) {
            .need_input => try appendInput(&stream),
            .need_output => try drain(&stream),
            .progress, .established => {},
            .data => |bytes| {
                if (bytes.len > observed.len - length) return error.TestWrongPayload;
                @memcpy(observed[length..][0..bytes.len], bytes);
                length += bytes.len;
            },
            .close_notify => return error.TestUnexpectedEof,
        }
    }
    if (!std.mem.eql(u8, expected, &observed)) return error.TestWrongPayload;
    try stream.queueKeyUpdate(false);
    if (stream.queueData(response)) |_| {
        return error.TestMissingBackpressure;
    } else |err| if (err != error.OutputPending) return err;
    try drain(&stream);
    if (try stream.queueData(response) != response.len) return error.TestWrongPayload;
    try drain(&stream);
    try stream.queueAlert(0);
    try drain(&stream);
}
