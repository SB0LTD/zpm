// Protocol seam + HTTP/1.1 implementation.
//
// The request/response model is version-agnostic: send a Request over a
// Transport, read a Response + body back. `Protocol` is the vtable a future
// HTTP/2 backend can also satisfy; `Http1` is the only impl today.
//
// Http1.send writes the serialized head then the body (two writeAlls). Http1.read
// accumulates header bytes into header_scratch until the blank line, parses the
// head, then hands any already-read overflow + the transport to the body decoder.

const std = @import("std");
const errors = @import("errors.sig");
const request = @import("request.sig");
const response = @import("response.sig");
const body = @import("body.sig");
const url_mod = @import("url.sig");
const transport = @import("transport.sig");

pub const Error = errors.Error;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Transport = transport.Transport;

/// Caller-owned buffers threaded through the engine (Req 2).
pub const Buffers = struct {
    body: []u8, // response body destination
    header_scratch: []u8, // response header bytes + parsed slices (>= 8 KiB)
    req_head: []u8, // serialized request head (>= MAX_REQUEST_HEADER)
};

/// Version-agnostic protocol vtable. HTTP/2 can implement the same shape later.
pub const Protocol = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, u: url_mod.Url, req: *const Request, tr: *const Transport, bufs: Buffers, keep_alive: bool) Error!void,
    readFn: *const fn (ctx: *anyopaque, tr: *const Transport, bufs: Buffers, method: errors.Method, resp: *Response) Error!void,

    pub fn send(self: *const Protocol, u: url_mod.Url, req: *const Request, tr: *const Transport, bufs: Buffers, keep_alive: bool) Error!void {
        return self.sendFn(self.ctx, u, req, tr, bufs, keep_alive);
    }
    pub fn read(self: *const Protocol, tr: *const Transport, bufs: Buffers, method: errors.Method, resp: *Response) Error!void {
        return self.readFn(self.ctx, tr, bufs, method, resp);
    }
};

/// HTTP/1.1 protocol implementation. Stateless; a single shared instance works.
pub const Http1 = struct {
    var inst: u8 = 0; // dummy ctx target

    pub fn protocol() Protocol {
        return .{ .ctx = &inst, .sendFn = sendImpl, .readFn = readImpl };
    }

    /// Serialize and write the request head, then the body.
    pub fn send(u: url_mod.Url, req: *const Request, tr: *const Transport, bufs: Buffers, keep_alive: bool) Error!void {
        const head = try request.serializeHead(bufs.req_head, u, req.*, keep_alive);
        try tr.writeAll(head);
        if (req.body.len > 0) try tr.writeAll(req.body);
    }

    /// Read + parse the response head into header_scratch, then decode the body.
    pub fn read(tr: *const Transport, bufs: Buffers, method: errors.Method, resp: *Response) Error!void {
        const scratch = bufs.header_scratch;
        var w: usize = 0;
        var head_end: usize = 0;
        while (true) {
            // Do we already have the full header block?
            if (response.headerEnd(scratch[0..w])) |he| { head_end = he; break; }
            if (w >= scratch.len) return Error.BufferTooSmall;
            const n = try tr.readSome(scratch[w..]);
            if (n == 0) {
                // EOF before headers complete.
                if (w == 0) return Error.PrematureClose;
                if (response.headerEnd(scratch[0..w])) |he| { head_end = he; break; }
                return Error.PrematureClose;
            }
            w += n;
        }
        try response.parseHead(scratch[0..head_end], resp);
        // Any bytes past the header terminator are the start of the body.
        const leftover = scratch[head_end..w];
        try body.readBody(tr, resp, leftover, bufs.body, method);
    }

    fn sendImpl(ctx: *anyopaque, u: url_mod.Url, req: *const Request, tr: *const Transport, bufs: Buffers, keep_alive: bool) Error!void {
        _ = ctx;
        return send(u, req, tr, bufs, keep_alive);
    }
    fn readImpl(ctx: *anyopaque, tr: *const Transport, bufs: Buffers, method: errors.Method, resp: *Response) Error!void {
        _ = ctx;
        return read(tr, bufs, method, resp);
    }
};

// Tests (inline, std.testing) -- HTTP/1.1 round-trip over TestTransport
const testing = std.testing;

fn parseUrl(raw: []const u8, hb: []u8) url_mod.Url {
    return url_mod.Url.parse(raw, hb) catch unreachable;
}

test "http1: full GET round-trip" {
    var hb: [256]u8 = undefined;
    const u = parseUrl("https://example.com/path", &hb);
    const req = Request{ .url = "https://example.com/path" };

    var outbox: [1024]u8 = undefined;
    const resp_bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    var tt = transport.TestTransport{ .inbox = resp_bytes, .outbox = &outbox };
    const tr = tt.transport();

    var body_buf: [64]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var head_buf: [8192]u8 = undefined;
    const bufs = Buffers{ .body = &body_buf, .header_scratch = &scratch, .req_head = &head_buf };

    try Http1.send(u, &req, &tr, bufs, false);
    // Request bytes captured by the transport.
    try testing.expect(std.mem.startsWith(u8, tt.written(), "GET /path HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, tt.written(), "Host: example.com\r\n") != null);

    var resp = Response{};
    try Http1.read(&tr, bufs, .GET, &resp);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expectEqualSlices(u8, "hi", resp.body);
    try testing.expect(resp.complete);
}

test "http1: POST body is written after head" {
    var hb: [256]u8 = undefined;
    const u = parseUrl("https://h/submit", &hb);
    const req = Request{ .url = "x", .method = .POST, .body = "name=1" };
    var outbox: [1024]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "HTTP/1.1 204 No Content\r\n\r\n", .outbox = &outbox };
    const tr = tt.transport();
    var body_buf: [16]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var head_buf: [8192]u8 = undefined;
    const bufs = Buffers{ .body = &body_buf, .header_scratch = &scratch, .req_head = &head_buf };
    try Http1.send(u, &req, &tr, bufs, false);
    try testing.expect(std.mem.endsWith(u8, tt.written(), "\r\n\r\nname=1"));
    var resp = Response{};
    try Http1.read(&tr, bufs, .POST, &resp);
    try testing.expectEqual(@as(u16, 204), resp.status);
}

test "http1: keep-alive flag threads to Connection header" {
    var hb: [256]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const req = Request{ .url = "x" };
    var outbox: [1024]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "", .outbox = &outbox };
    const tr = tt.transport();
    var body_buf: [1]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    var head_buf: [1024]u8 = undefined;
    const bufs = Buffers{ .body = &body_buf, .header_scratch = &scratch, .req_head = &head_buf };
    try Http1.send(u, &req, &tr, bufs, true);
    try testing.expect(std.mem.indexOf(u8, tt.written(), "Connection: keep-alive\r\n") != null);
}

test "http1: chunked response end-to-end" {
    var hb: [256]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const req = Request{ .url = "x" };
    var outbox: [512]u8 = undefined;
    const resp_bytes = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    var tt = transport.TestTransport{ .inbox = resp_bytes, .outbox = &outbox };
    const tr = tt.transport();
    var body_buf: [64]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var head_buf: [1024]u8 = undefined;
    const bufs = Buffers{ .body = &body_buf, .header_scratch = &scratch, .req_head = &head_buf };
    try Http1.send(u, &req, &tr, bufs, false);
    var resp = Response{};
    try Http1.read(&tr, bufs, .GET, &resp);
    try testing.expectEqualSlices(u8, "Wikipedia", resp.body);
}

test "http1: header block split across reads" {
    var hb: [256]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const req = Request{ .url = "x" };
    var outbox: [512]u8 = undefined;
    const resp_bytes = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc";
    var tt = transport.TestTransport{ .inbox = resp_bytes, .outbox = &outbox, .max_chunk = 1 };
    const tr = tt.transport();
    var body_buf: [16]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var head_buf: [1024]u8 = undefined;
    const bufs = Buffers{ .body = &body_buf, .header_scratch = &scratch, .req_head = &head_buf };
    try Http1.send(u, &req, &tr, bufs, false);
    var resp = Response{};
    try Http1.read(&tr, bufs, .GET, &resp);
    try testing.expectEqualSlices(u8, "abc", resp.body);
}
