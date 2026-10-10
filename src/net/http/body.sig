// HTTP/1.1 response body decoder.
//
// Picks the framing from the parsed head + request method/status and reads the
// body into the caller `body_buf`:
//   - no body: HEAD, 1xx, 204, 304 -> complete immediately
//   - Content-Length: read exactly N bytes
//   - Transfer-Encoding: chunked -> decode (hex size, ;ext skip, CRLFs, 0 end,
//     trailer discard)
//   - else, Connection: close -> read until EOF
// Overflow past body_buf -> BodyTooLarge, with as much as fit recorded; never
// overruns. Any leftover bytes already read past the header block are consumed
// first via `leftover` before touching the transport.

const std = @import("std");
const errors = @import("errors.sig");
const response = @import("response.sig");
const transport = @import("transport.sig");

pub const Error = errors.Error;
const Response = response.Response;
const Transport = transport.Transport;
const Method = errors.Method;

/// Reader that serves `leftover` bytes first, then pulls from the transport.
const Source = struct {
    tr: *const Transport,
    leftover: []const u8,
    lo_off: usize = 0,

    fn readSome(self: *Source, buf: []u8) Error!usize {
        if (self.lo_off < self.leftover.len) {
            const avail = self.leftover.len - self.lo_off;
            const n = @min(avail, buf.len);
            @memcpy(buf[0..n], self.leftover[self.lo_off .. self.lo_off + n]);
            self.lo_off += n;
            return n;
        }
        return self.tr.readSome(buf);
    }
};

fn bodyless(method: Method, status: u16) bool {
    if (method == .HEAD) return true;
    if (status >= 100 and status < 200) return true; // 1xx
    if (status == 204 or status == 304) return true;
    return false;
}

/// Decode the response body into `body_buf`, setting resp.body + resp.complete.
/// `leftover` is any bytes already read past the header terminator.
pub fn readBody(
    tr: *const Transport,
    resp: *Response,
    leftover: []const u8,
    body_buf: []u8,
    method: Method,
) Error!void {
    if (bodyless(method, resp.status)) {
        resp.body = body_buf[0..0];
        resp.complete = true;
        return;
    }
    var src = Source{ .tr = tr, .leftover = leftover };

    if (resp.header("transfer-encoding")) |te| {
        if (containsTokenCI(te, "chunked")) {
            try readChunked(&src, resp, body_buf);
            return;
        }
    }
    if (resp.header("content-length")) |cl| {
        const n = parseDecimal(cl) orelse return Error.BadResponse;
        try readExact(&src, resp, body_buf, n);
        return;
    }
    // No framing header: read until EOF (clean close).
    try readToEof(&src, resp, body_buf);
}

fn readExact(src: *Source, resp: *Response, body_buf: []u8, n: usize) Error!void {
    if (n > body_buf.len) {
        // Read as much as fits so we do not overrun, then signal overflow.
        _ = fill(src, body_buf) catch {};
        resp.body = body_buf[0..body_buf.len];
        return Error.BodyTooLarge;
    }
    const got = try fill(src, body_buf[0..n]);
    if (got < n) return Error.PrematureClose;
    resp.body = body_buf[0..n];
    resp.complete = true;
}

fn readToEof(src: *Source, resp: *Response, body_buf: []u8) Error!void {
    var w: usize = 0;
    while (true) {
        if (w >= body_buf.len) {
            // Buffer full; check if more bytes remain -> overflow.
            var probe: [1]u8 = undefined;
            const extra = try src.readSome(&probe);
            if (extra == 0) break;
            resp.body = body_buf[0..w];
            return Error.BodyTooLarge;
        }
        const n = try src.readSome(body_buf[w..]);
        if (n == 0) break; // EOF
        w += n;
    }
    resp.body = body_buf[0..w];
    resp.complete = true;
}

/// Read exactly buf.len bytes (or fewer on EOF). Returns bytes read.
fn fill(src: *Source, buf: []u8) Error!usize {
    var w: usize = 0;
    while (w < buf.len) {
        const n = try src.readSome(buf[w..]);
        if (n == 0) break;
        w += n;
    }
    return w;
}

/// A single-byte reader buffered over a Source. Keeps the chunked decoder
/// simple (hex sizes, CRLFs, trailers) without per-byte transport calls.
const ByteReader = struct {
    src: *Source,
    buf: [512]u8 = undefined,
    off: usize = 0,
    len: usize = 0,

    fn next(self: *ByteReader) Error!?u8 {
        if (self.off >= self.len) {
            const n = try self.src.readSome(&self.buf);
            if (n == 0) return null; // EOF
            self.off = 0;
            self.len = n;
        }
        const b = self.buf[self.off];
        self.off += 1;
        return b;
    }

    fn mustNext(self: *ByteReader) Error!u8 {
        return (try self.next()) orelse Error.PrematureClose;
    }
};

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn readChunked(src: *Source, resp: *Response, body_buf: []u8) Error!void {
    var br = ByteReader{ .src = src };
    var w: usize = 0;
    while (true) {
        // Parse chunk-size: hex digits, optionally followed by ;extension.
        var size: usize = 0;
        var saw_digit = false;
        var c = try br.mustNext();
        while (hexVal(c)) |hv| {
            size = size * 16 + hv;
            saw_digit = true;
            c = try br.mustNext();
        }
        if (!saw_digit) return Error.BadResponse;
        // Skip any ;extension up to CR.
        while (c != '\r') : (c = try br.mustNext()) {}
        if ((try br.mustNext()) != '\n') return Error.BadResponse; // after CR

        if (size == 0) {
            // Last chunk: consume trailer headers up to the blank line.
            try discardTrailers(&br);
            resp.body = body_buf[0..w];
            resp.complete = true;
            return;
        }

        // Copy `size` data bytes into body_buf.
        var remaining = size;
        while (remaining > 0) {
            const b = try br.mustNext();
            if (w >= body_buf.len) {
                resp.body = body_buf[0..w];
                return Error.BodyTooLarge;
            }
            body_buf[w] = b;
            w += 1;
            remaining -= 1;
        }
        // Trailing CRLF after chunk data.
        if ((try br.mustNext()) != '\r') return Error.BadResponse;
        if ((try br.mustNext()) != '\n') return Error.BadResponse;
    }
}

/// Consume trailer header lines after the terminating 0-chunk, up to and
/// including the final blank CRLF line.
fn discardTrailers(br: *ByteReader) Error!void {
    while (true) {
        // Read a line; empty line ends the trailers.
        const first = try br.next();
        if (first == null) return; // tolerant EOF after last chunk
        if (first.? == '\r') {
            if ((try br.mustNext()) != '\n') return Error.BadResponse;
            return; // blank line -> done
        }
        // Non-empty trailer line: consume to end of line.
        var c = first.?;
        while (c != '\r') : (c = try br.mustNext()) {}
        if ((try br.mustNext()) != '\n') return Error.BadResponse;
    }
}

fn parseDecimal(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + @as(usize, c - '0');
    }
    return v;
}

fn lowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn containsTokenCI(haystack: []const u8, token: []const u8) bool {
    if (token.len == 0 or haystack.len < token.len) return false;
    var i: usize = 0;
    while (i + token.len <= haystack.len) : (i += 1) {
        var m = true;
        for (0..token.len) |j| { if (lowerByte(haystack[i + j]) != lowerByte(token[j])) { m = false; break; } }
        if (m) return true;
    }
    return false;
}

// Tests (inline, std.testing) -- body decoding
const testing = std.testing;

// Build a Response with the given header block already parsed.
fn respWith(head: []const u8) Response {
    var r = Response{};
    response.parseHead(head, &r) catch unreachable;
    return r;
}

test "body: Content-Length exact read" {
    var r = respWith("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "hello", .outbox = &outbox };
    const tr = tt.transport();
    var body: [16]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expect(r.complete);
    try testing.expectEqualSlices(u8, "hello", r.body);
}

test "body: Content-Length served from leftover" {
    var r = respWith("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "", .outbox = &outbox };
    const tr = tt.transport();
    var body: [16]u8 = undefined;
    try readBody(&tr, &r, "abc", &body, .GET);
    try testing.expectEqualSlices(u8, "abc", r.body);
}

test "body: HEAD has no body" {
    var r = respWith("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "hello", .outbox = &outbox };
    const tr = tt.transport();
    var body: [16]u8 = undefined;
    try readBody(&tr, &r, "", &body, .HEAD);
    try testing.expect(r.complete);
    try testing.expectEqual(@as(usize, 0), r.body.len);
}

test "body: 204 has no body" {
    var r = respWith("HTTP/1.1 204 No Content\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "xxxx", .outbox = &outbox };
    const tr = tt.transport();
    var body: [16]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expectEqual(@as(usize, 0), r.body.len);
}

test "body: EOF-delimited on close" {
    var r = respWith("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "streamed body", .outbox = &outbox };
    const tr = tt.transport();
    var body: [64]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expectEqualSlices(u8, "streamed body", r.body);
}

test "body: chunked single chunk" {
    var r = respWith("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "5\r\nhello\r\n0\r\n\r\n", .outbox = &outbox };
    const tr = tt.transport();
    var body: [64]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expectEqualSlices(u8, "hello", r.body);
}

test "body: chunked multiple chunks" {
    var r = respWith("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", .outbox = &outbox };
    const tr = tt.transport();
    var body: [64]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expectEqualSlices(u8, "hello world", r.body);
}

test "body: chunked split across reads" {
    var r = respWith("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "5\r\nhello\r\n0\r\n\r\n", .outbox = &outbox, .max_chunk = 1 };
    const tr = tt.transport();
    var body: [64]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expectEqualSlices(u8, "hello", r.body);
}

test "body: chunked with extension and trailer" {
    var r = respWith("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "5;ext=1\r\nhello\r\n0\r\nX-Trailer: v\r\n\r\n", .outbox = &outbox };
    const tr = tt.transport();
    var body: [64]u8 = undefined;
    try readBody(&tr, &r, "", &body, .GET);
    try testing.expectEqualSlices(u8, "hello", r.body);
}

test "body: overflow signalled on Content-Length" {
    var r = respWith("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n");
    var outbox: [1]u8 = undefined;
    var tt = transport.TestTransport{ .inbox = "0123456789", .outbox = &outbox };
    const tr = tt.transport();
    var body: [4]u8 = undefined;
    try testing.expectError(error.BodyTooLarge, readBody(&tr, &r, "", &body, .GET));
}
