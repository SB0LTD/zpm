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

pub fn main(init: std.process.Init.Minimal) !void {
    if (init.args.vector.len != 3) return error.TestArguments;
    const mode = std.mem.span(init.args.vector[1]);
    const expectation = std.mem.span(init.args.vector[2]);
    const alpn: ?tls.Alpn = if (std.mem.eql(u8, mode, "disabled"))
        null
    else if (std.mem.eql(u8, mode, "optional"))
        .{ .protocol = "postgresql" }
    else if (std.mem.eql(u8, mode, "required"))
        .{ .protocol = "postgresql", .required = true }
    else
        return error.TestArguments;
    const expected_alert: ?[]const u8 = if (std.mem.eql(u8, expectation, "mismatch"))
        &tls.no_application_protocol_alert
    else if (std.mem.eql(u8, expectation, "missing"))
        &tls.missing_alpn_extension_alert
    else
        null;
    const expect_selection = std.mem.eql(u8, expectation, "selected");
    var identity = try tls.Identity.init(&.{fixture.certificate}, &fixture.private_key);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&identity.key_pair));
    var receive: [transport.record_capacity]u8 = undefined;
    var send: [transport.record_capacity]u8 = undefined;
    var hello_buffer: [4096]u8 = undefined;
    var flight: [8192]u8 = undefined;
    var stream = try transport.Stream.initWithAlpn(&identity, .{
        .receive = &receive, .send = &send, .hello = &hello_buffer, .flight = &flight,
    }, alpn);
    defer stream.close();
    var observed: [expected.len]u8 = undefined;
    var length: usize = 0;
    while (length < observed.len) {
        switch (try stream.next()) {
            .need_input => try appendInput(&stream),
            .need_output => {
                if (expected_alert) |alert| {
                    if (!std.mem.eql(u8, stream.output(), alert)) return error.TestWrongAlert;
                    if (try stream.next() != .need_output or stream.selectedAlpn() != null) return error.TestWrongAlert;
                    try drain(&stream);
                    if (stream.next()) |_| {
                        return error.TestWrongAlert;
                    } else |err| if (err != error.Closed) return err;
                    return;
                }
                try drain(&stream);
            },
            .progress => {},
            .established => {
                const chosen = stream.selectedAlpn();
                if (expected_alert != null or (chosen != null) != expect_selection) return error.TestWrongSelection;
                if (chosen) |protocol| if (!std.mem.eql(u8, protocol, "postgresql")) return error.TestWrongSelection;
            },
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
