//! Linux test adapter. The harness attaches one loopback TCP connection to
//! stdin and stdout. The TLS library has no dependency on this adapter.
const std = @import("std");
const fixture = @import("fixture");
const record = @import("record.sig");
const tls = @import("server.sig");

const expected = "ZPM TLS request\n";
const response = "ZPM TLS response\n";

const Input = struct {
    bytes: [record.header_bytes + record.max_ciphertext_bytes]u8 = undefined,
    used: usize = 0,

    fn readNext(self: *Input) !void {
        const space = self.bytes[self.used..];
        if (space.len == 0) return error.TestInputTooLarge;
        while (true) {
            // Force short stream fragments through the real server entry point.
            const rc = std.os.linux.read(0, space.ptr, @min(space.len, 7));
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.TestUnexpectedEof;
                    self.used += rc;
                    return;
                },
                .INTR => continue,
                else => return error.TestReadFailed,
            }
        }
    }

    fn consume(self: *Input, count: usize) void {
        std.mem.copyForwards(u8, self.bytes[0 .. self.used - count], self.bytes[count..self.used]);
        self.used -= count;
    }
};

fn writeAll(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const rc = std.os.linux.write(1, remaining.ptr, remaining.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.TestWriteFailed;
                remaining = remaining[rc..];
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

pub fn main() !void {
    var identity = try tls.Identity.init(&.{fixture.certificate}, &fixture.private_key);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&identity.key_pair));
    var hello_buffer: [4096]u8 = undefined;
    var flight: [8192]u8 = undefined;
    var output: [9216]u8 = undefined;
    var server = tls.Server.init(&identity, &hello_buffer);
    defer server.close();
    var input: Input = .{};
    while (server.phase != .established) {
        switch (try server.receive(input.bytes[0..input.used])) {
            .need => try input.readNext(),
            .consumed => |count| input.consume(count),
        }
        if (server.phase == .server_flight) try writeAll(try server.emitFlight(&flight, &output));
    }
    var application = try server.takeApplication();
    defer application.close();
    var observed: [expected.len]u8 = undefined;
    var length: usize = 0;
    while (length < expected.len) {
        switch (try record.frame(input.bytes[0..input.used])) {
            .incomplete => try input.readNext(),
            .complete => |count| {
                switch (try application.open(input.bytes[0..count])) {
                    .data => |bytes| {
                        if (bytes.len > expected.len - length) return error.TestWrongPayload;
                        @memcpy(observed[length..][0..bytes.len], bytes);
                        length += bytes.len;
                    },
                    .handshake_fragment, .key_update, .user_canceled => {},
                    .close_notify => return error.TestWrongRecord,
                }
                input.consume(count);
            },
        }
    }
    if (!std.mem.eql(u8, expected, &observed)) return error.TestWrongPayload;
    try writeAll(try application.sealUpdate(&output, false));
    @memcpy(output[record.header_bytes..][0..response.len], response);
    try writeAll(try application.sealData(&output, response.len));
    try writeAll(try application.sealAlert(&output, 0));
}
