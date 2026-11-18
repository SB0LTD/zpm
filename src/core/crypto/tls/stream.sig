//! Caller-driven TLS server stream framing, independent of sockets and clocks.
const std = @import("std");
const record = @import("record.sig");
const tls = @import("server.sig");

pub const Error = tls.Error || error{ InvalidProgress, OutputPending, TruncatedStream };
pub const record_capacity = record.header_bytes + record.max_ciphertext_bytes;

pub const Buffers = struct {
    receive: []u8,
    send: []u8,
    hello: []u8,
    flight: []u8,
};

pub const Event = union(enum) {
    need_input,
    need_output,
    progress,
    established,
    data: []const u8,
    close_notify,
};

pub const Stream = struct {
    handshake: tls.Server,
    application: ?tls.Application = null,
    buffers: Buffers,
    receive_start: usize = 0,
    receive_end: usize = 0,
    send_start: usize = 0,
    send_end: usize = 0,
    read_closed: bool = false,
    failed: bool = false,

    pub fn init(identity: *const tls.Identity, buffers: Buffers) Error!Stream {
        if (buffers.receive.len < record_capacity or
            buffers.send.len < @max(record_capacity, identity.flightOutputBytes()) or
            buffers.hello.len < 4 or buffers.flight.len < identity.flightScratchBytes())
            return error.BufferTooSmall;
        const spans = [_][]u8{ buffers.receive, buffers.send, buffers.hello, buffers.flight };
        for (spans, 0..) |span, index| {
            for (spans[index + 1 ..]) |other| {
                if (overlaps(span, other)) return error.BadRecord;
            }
            if (overlaps(span, std.mem.asBytes(identity)) or
                overlaps(span, std.mem.sliceAsBytes(identity.chain))) return error.BadRecord;
            for (identity.chain) |der| if (overlaps(span, der)) return error.BadRecord;
        }
        var bounded = buffers;
        bounded.receive = buffers.receive[0..record_capacity];
        return .{ .handshake = tls.Server.init(identity, bounded.hello), .buffers = bounded };
    }

    /// The transport writes into this tail, then reports the exact byte count.
    pub fn input(self: *Stream) []u8 {
        if (self.read_closed or self.failed) return self.buffers.receive[0..0];
        if (self.receive_end == self.buffers.receive.len and self.receive_start != 0) {
            const span = self.buffers.receive[self.receive_start..self.receive_end];
            std.mem.copyForwards(u8, self.buffers.receive[0..span.len], span);
            self.receive_start = 0;
            self.receive_end = span.len;
        }
        return self.buffers.receive[self.receive_end..];
    }

    pub fn received(self: *Stream, count: usize) Error!void {
        if (self.failed or self.read_closed) return error.Closed;
        if (count > self.buffers.receive.len - self.receive_end) return error.InvalidProgress;
        self.receive_end += count;
    }

    pub fn output(self: *const Stream) []const u8 {
        return self.buffers.send[self.send_start..self.send_end];
    }

    pub fn sent(self: *Stream, count: usize) Error!void {
        if (count > self.send_end - self.send_start) return error.InvalidProgress;
        self.send_start += count;
        if (self.send_start == self.send_end) {
            self.send_start = 0;
            self.send_end = 0;
        }
    }

    fn consumed(self: *Stream, count: usize) void {
        self.receive_start += count;
        if (self.receive_start == self.receive_end) {
            self.receive_start = 0;
            self.receive_end = 0;
        }
    }

    /// Advance one TLS record. Data borrows the input until the next mutation.
    pub fn next(self: *Stream) Error!Event {
        if (self.failed) return error.Closed;
        if (self.output().len != 0) return .need_output;
        if (self.read_closed) return .close_notify;
        errdefer self.failed = true;
        const bytes = self.buffers.receive[self.receive_start..self.receive_end];
        if (self.application) |*application| {
            const length = switch (try record.frame(bytes)) {
                .incomplete => return .need_input,
                .complete => |count| count,
            };
            const result = try application.open(bytes[0..length]);
            self.consumed(length);
            return switch (result) {
                .data => |data| .{ .data = data },
                .key_update, .handshake_fragment, .user_canceled => .progress,
                .close_notify => closed: {
                    self.read_closed = true;
                    self.receive_start = 0;
                    self.receive_end = 0;
                    break :closed .close_notify;
                },
            };
        }
        switch (try self.handshake.receive(bytes)) {
            .need => return .need_input,
            .consumed => |count| self.consumed(count),
        }
        switch (self.handshake.phase) {
            .server_flight => {
                self.send_end = (try self.handshake.emitFlight(self.buffers.flight, self.buffers.send)).len;
                return .need_output;
            },
            .established => {
                self.application = try self.handshake.takeApplication();
                return .established;
            },
            else => return .progress,
        }
    }

    /// Return the plaintext bytes accepted. A zero with pending output means
    /// a required KeyUpdate was queued first. Drain output before retrying.
    pub fn queueData(self: *Stream, data: []const u8) Error!usize {
        if (self.failed) return error.Closed;
        if (self.output().len != 0) return error.OutputPending;
        if (self.application) |*application| {
            if (application.needsUpdateBeforeData()) {
                try self.queueKeyUpdate(false);
                return 0;
            }
            const count = @min(data.len, record.max_plaintext_bytes);
            if (count == 0) return 0;
            const content = self.buffers.send[record.header_bytes..][0..count];
            if (overlaps(content, data[0..count])) return error.BadRecord;
            @memcpy(content, data[0..count]);
            self.send_end = (try application.sealData(self.buffers.send, count)).len;
            return count;
        }
        return error.UnexpectedMessage;
    }

    pub fn queueKeyUpdate(self: *Stream, request_peer: bool) Error!void {
        if (self.failed) return error.Closed;
        if (self.output().len != 0) return error.OutputPending;
        if (self.application) |*application| {
            self.send_end = (try application.sealUpdate(self.buffers.send, request_peer)).len;
            return;
        }
        return error.UnexpectedMessage;
    }

    pub fn queueAlert(self: *Stream, description: u8) Error!void {
        if (self.failed and (description == 0 or description == 90)) return error.Closed;
        if (self.output().len != 0) return error.OutputPending;
        if (self.application) |*application| {
            self.send_end = (try application.sealAlert(self.buffers.send, description)).len;
            if (description != 0 and description != 90) self.failed = true;
            return;
        }
        return error.UnexpectedMessage;
    }

    pub fn eof(self: *Stream) Error!void {
        if (self.read_closed) return;
        self.close();
        return error.TruncatedStream;
    }

    pub fn close(self: *Stream) void {
        self.handshake.close();
        if (self.application) |*application| application.close();
        self.application = null;
        std.crypto.secureZero(u8, self.buffers.receive[0..record_capacity]);
        std.crypto.secureZero(u8, self.buffers.send[0..record_capacity]);
        self.failed = true;
        self.receive_start = 0;
        self.receive_end = 0;
        self.send_start = 0;
        self.send_end = 0;
    }
};

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ai = @intFromPtr(a.ptr);
    const bi = @intFromPtr(b.ptr);
    return if (ai <= bi) bi - ai < a.len else ai - bi < b.len;
}
