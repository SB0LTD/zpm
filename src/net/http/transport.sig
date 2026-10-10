// Transport seam for the HTTP engine.
//
// The request serializer and response parser speak to the wire only through
// this `Transport` vtable (read-some / write-all / close), so the same engine
// drives three backings without knowing which:
//   - connTransport: a TLS 1.3 tlsc.Conn (https)
//   - PlainTransport: a raw tlsc.Socket (http, port 80)
//   - TestTransport: an in-memory script, for hermetic offline tests
//
// Shape mirrors websocket.Transport / wss.connTransport so the two network
// clients share one mental model. Allocation-free: all buffers are caller-owned.

const std = @import("std");
const tlsc = @import("tls_client");
const errors = @import("errors.sig");

pub const Error = errors.Error;

/// A byte transport the HTTP engine reads/writes through. readSome returns 0
/// at end-of-stream (peer close); writeAll must fully flush or error.
pub const Transport = struct {
    ctx: *anyopaque,
    readSomeFn: *const fn (ctx: *anyopaque, buf: []u8) Error!usize,
    writeAllFn: *const fn (ctx: *anyopaque, data: []const u8) Error!void,
    closeFn: *const fn (ctx: *anyopaque) void,

    pub fn readSome(self: *const Transport, buf: []u8) Error!usize {
        return self.readSomeFn(self.ctx, buf);
    }
    pub fn writeAll(self: *const Transport, data: []const u8) Error!void {
        return self.writeAllFn(self.ctx, data);
    }
    pub fn close(self: *const Transport) void {
        self.closeFn(self.ctx);
    }
};

// -- https: TLS Conn -> Transport (mirror of wss.connTransport) --

pub fn connTransport(conn: *tlsc.Conn) Transport {
    return .{
        .ctx = conn,
        .readSomeFn = connRead,
        .writeAllFn = connWrite,
        .closeFn = connClose,
    };
}

fn connRead(ctx: *anyopaque, buf: []u8) Error!usize {
    const conn: *tlsc.Conn = @ptrCast(@alignCast(ctx));
    return conn.read(buf) catch |err| switch (err) {
        error.Closed => return 0, // peer close_notify -> EOF
        else => return Error.RecvFailed,
    };
}

fn connWrite(ctx: *anyopaque, data: []const u8) Error!void {
    const conn: *tlsc.Conn = @ptrCast(@alignCast(ctx));
    conn.write(data) catch return Error.SendFailed;
}

fn connClose(ctx: *anyopaque) void {
    const conn: *tlsc.Conn = @ptrCast(@alignCast(ctx));
    conn.close();
}

// -- http: raw tlsc.Socket -> Transport (plaintext, port 80) --
//
// Wraps the socket's own read/write seam. The socket is pinned by the owning
// client (same ownership rule as wss), so `&self.sock` stays valid.
pub const PlainTransport = struct {
    sock: *tlsc.Socket,
    inner: tlsc.Transport,

    pub fn init(sock: *tlsc.Socket) PlainTransport {
        return .{ .sock = sock, .inner = sock.transport() };
    }

    pub fn transport(self: *PlainTransport) Transport {
        return .{
            .ctx = self,
            .readSomeFn = plainRead,
            .writeAllFn = plainWrite,
            .closeFn = plainClose,
        };
    }

    fn plainRead(ctx: *anyopaque, buf: []u8) Error!usize {
        const self: *PlainTransport = @ptrCast(@alignCast(ctx));
        return self.inner.readFn(self.inner.ctx, buf) catch return Error.RecvFailed;
    }

    fn plainWrite(ctx: *anyopaque, data: []const u8) Error!void {
        const self: *PlainTransport = @ptrCast(@alignCast(ctx));
        self.inner.writeFn(self.inner.ctx, data) catch return Error.SendFailed;
    }

    fn plainClose(ctx: *anyopaque) void {
        const self: *PlainTransport = @ptrCast(@alignCast(ctx));
        self.sock.close();
    }
};

// -- TestTransport: hermetic in-memory script (offline tests) --
//
// `inbox` is the server's scripted response bytes. readSome hands them out in
// chunks of at most `max_chunk` (0 = unlimited) so tests can force a parser to
// cope with split-across-reads framing. Written request bytes are captured into
// `outbox` for assertions. Zero allocation; caller owns outbox.
pub const TestTransport = struct {
    inbox: []const u8,
    in_off: usize = 0,
    max_chunk: usize = 0, // 0 => serve as much as fits in buf
    outbox: []u8,
    out_len: usize = 0,
    closed: bool = false,

    pub fn transport(self: *TestTransport) Transport {
        return .{
            .ctx = self,
            .readSomeFn = tRead,
            .writeAllFn = tWrite,
            .closeFn = tClose,
        };
    }

    /// Bytes written by the engine so far (the serialized request).
    pub fn written(self: *const TestTransport) []const u8 {
        return self.outbox[0..self.out_len];
    }

    fn tRead(ctx: *anyopaque, buf: []u8) Error!usize {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (self.in_off >= self.inbox.len) return 0; // EOF
        var avail = self.inbox.len - self.in_off;
        if (self.max_chunk != 0 and avail > self.max_chunk) avail = self.max_chunk;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.inbox[self.in_off .. self.in_off + n]);
        self.in_off += n;
        return n;
    }

    fn tWrite(ctx: *anyopaque, data: []const u8) Error!void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (self.out_len + data.len > self.outbox.len) return Error.BufferTooSmall;
        @memcpy(self.outbox[self.out_len .. self.out_len + data.len], data);
        self.out_len += data.len;
    }

    fn tClose(ctx: *anyopaque) void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

// Tests (inline, std.testing) -- TestTransport
const testing = std.testing;

test "TestTransport: write capture round-trips" {
    var out: [64]u8 = undefined;
    var tt = TestTransport{ .inbox = "", .outbox = &out };
    const tr = tt.transport();
    try tr.writeAll("GET / HTTP/1.1\r\n");
    try tr.writeAll("\r\n");
    try testing.expectEqualSlices(u8, "GET / HTTP/1.1\r\n\r\n", tt.written());
}

test "TestTransport: read serves whole inbox then EOF" {
    var out: [8]u8 = undefined;
    var tt = TestTransport{ .inbox = "hello", .outbox = &out };
    const tr = tt.transport();
    var buf: [16]u8 = undefined;
    const n = try tr.readSome(&buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, "hello", buf[0..n]);
    try testing.expectEqual(@as(usize, 0), try tr.readSome(&buf));
}

test "TestTransport: max_chunk forces split-across-reads" {
    var out: [8]u8 = undefined;
    var tt = TestTransport{ .inbox = "abcdef", .outbox = &out, .max_chunk = 2 };
    const tr = tt.transport();
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try tr.readSome(&buf));
    try testing.expectEqualSlices(u8, "ab", buf[0..2]);
    try testing.expectEqual(@as(usize, 2), try tr.readSome(&buf));
    try testing.expectEqualSlices(u8, "cd", buf[0..2]);
    try testing.expectEqual(@as(usize, 2), try tr.readSome(&buf));
    try testing.expectEqual(@as(usize, 0), try tr.readSome(&buf));
}

test "TestTransport: read respects small buffer" {
    var out: [8]u8 = undefined;
    var tt = TestTransport{ .inbox = "abcdef", .outbox = &out };
    const tr = tt.transport();
    var buf: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try tr.readSome(&buf));
    try testing.expectEqualSlices(u8, "abc", buf[0..3]);
}

test "TestTransport: write overflow signalled" {
    var out: [4]u8 = undefined;
    var tt = TestTransport{ .inbox = "", .outbox = &out };
    const tr = tt.transport();
    try testing.expectError(error.BufferTooSmall, tr.writeAll("toolong"));
}

test "TestTransport: close sets flag" {
    var out: [4]u8 = undefined;
    var tt = TestTransport{ .inbox = "", .outbox = &out };
    const tr = tt.transport();
    tr.close();
    try testing.expect(tt.closed);
}
