// HTTP/1.1 response status-line + header parser.
//
// Header bytes are accumulated by the engine into a caller `header_scratch`
// buffer; once the terminating CRLFCRLF arrives, parseHead slices the status
// line and headers in place (no copies). The parser is tolerant of being fed
// across multiple reads: the engine appends to scratch and retries until
// headerEnd finds the blank line or the scratch fills (BufferTooSmall).
//
// HeaderSet gives bounded, case-insensitive lookup; convenience accessors pull
// out the framing-relevant headers the body/redirect/cookie layers need.

const std = @import("std");
const errors = @import("errors.sig");
const cookie = @import("cookie.sig");

pub const Error = errors.Error;

pub const MAX_RESP_HEADERS: usize = 48;

const Pair = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

/// Bounded set of response headers. Slices point into the caller header_scratch
/// buffer and are valid until the next request reuses that buffer.
pub const HeaderSet = struct {
    items: [MAX_RESP_HEADERS]Pair = [_]Pair{.{}} ** MAX_RESP_HEADERS,
    len: usize = 0,

    fn add(self: *HeaderSet, name: []const u8, value: []const u8) Error!void {
        if (self.len >= MAX_RESP_HEADERS) return Error.BufferTooSmall;
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    /// Case-insensitive lookup; returns the first matching value.
    pub fn get(self: *const HeaderSet, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |p| {
            if (eqCI(p.name, name)) return p.value;
        }
        return null;
    }

    /// Iterate values for a repeated header (e.g. Set-Cookie). Returns the i-th
    /// match or null when exhausted.
    pub fn getNth(self: *const HeaderSet, name: []const u8, nth: usize) ?[]const u8 {
        var seen: usize = 0;
        for (self.items[0..self.len]) |p| {
            if (eqCI(p.name, name)) {
                if (seen == nth) return p.value;
                seen += 1;
            }
        }
        return null;
    }
};

/// A parsed response head. `body` is filled later by body.sig; header name/
/// value slices point into the caller header_scratch buffer.
pub const Response = struct {
    status: u16 = 0,
    reason: []const u8 = "",
    headers: HeaderSet = .{},
    body: []const u8 = "",
    complete: bool = false,
    keep_alive: bool = false,

    pub fn ok(self: *const Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Absorb Set-Cookie headers from this response into `jar` (Req 8.3).
    pub fn absorbCookies(self: *const Response, jar: *cookie.CookieJar) void {
        var i: usize = 0;
        while (self.headers.getNth("set-cookie", i)) |v| : (i += 1) {
            // Reuse the jar's own name=value split by handing it a synthetic
            // single-line raw header. Cheap and keeps one parse path.
            var line: [1024]u8 = undefined;
            const prefix = "Set-Cookie: ";
            if (prefix.len + v.len + 2 > line.len) continue;
            @memcpy(line[0..prefix.len], prefix);
            @memcpy(line[prefix.len..][0..v.len], v);
            line[prefix.len + v.len] = '\r';
            line[prefix.len + v.len + 1] = '\n';
            jar.absorbRawHeaders(line[0 .. prefix.len + v.len + 2]);
        }
    }
};

/// Locate the end of the header block (index just past the CRLFCRLF). Returns
/// null when the terminator has not arrived yet (feed more bytes).
pub fn headerEnd(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

/// Parse a complete header block (status line + headers, ending at the blank
/// line) sitting in `head`. Fills `resp.status`, `resp.reason`, `resp.headers`,
/// and derives `keep_alive`. Malformed input -> BadResponse; too many headers
/// -> BufferTooSmall. `head` must include the terminating CRLFCRLF.
pub fn parseHead(head: []const u8, resp: *Response) Error!void {
    var line_start: usize = 0;
    const first_eol = findCRLF(head, 0) orelse return Error.BadResponse;
    try parseStatusLine(head[0..first_eol], resp);
    line_start = first_eol + 2;

    while (line_start < head.len) {
        const eol = findCRLF(head, line_start) orelse return Error.BadResponse;
        if (eol == line_start) break; // blank line -> end of headers
        const line = head[line_start..eol];
        const colon = indexOfByte(line, ':') orelse return Error.BadResponse;
        const name = line[0..colon];
        if (name.len == 0) return Error.BadResponse;
        var value = line[colon + 1 ..];
        value = trimOWS(value);
        try resp.headers.add(name, value);
        line_start = eol + 2;
    }

    // Derive keep-alive: HTTP/1.1 defaults to keep-alive unless Connection: close.
    resp.keep_alive = true;
    if (resp.headers.get("connection")) |c| {
        if (containsTokenCI(c, "close")) resp.keep_alive = false;
    }
}

fn parseStatusLine(line: []const u8, resp: *Response) Error!void {
    // Form: HTTP/1.x SP 3DIGIT SP reason
    if (line.len < 12) return Error.BadResponse;
    if (!startsWith(line, "HTTP/1.")) return Error.BadResponse;
    // byte 7 is the minor version digit, byte 8 must be space
    if (line[8] != ' ') return Error.BadResponse;
    const code_slice = line[9..12];
    var code: u16 = 0;
    for (code_slice) |c| {
        if (c < '0' or c > '9') return Error.BadResponse;
        code = code * 10 + @as(u16, c - '0');
    }
    resp.status = code;
    // Optional SP + reason phrase.
    if (line.len > 12 and line[12] == ' ') {
        resp.reason = line[13..];
    } else {
        resp.reason = "";
    }
}

fn findCRLF(buf: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n') return i;
    }
    return null;
}

fn indexOfByte(s: []const u8, b: u8) ?usize {
    for (s, 0..) |c, i| if (c == b) return i;
    return null;
}

fn trimOWS(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) : (a += 1) {}
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) : (b -= 1) {}
    return s[a..b];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (0..prefix.len) |i| if (s[i] != prefix[i]) return false;
    return true;
}

fn lowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqCI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (lowerByte(a[i]) != lowerByte(b[i])) return false;
    return true;
}

/// True if `haystack` contains `token` (case-insensitive), used for comma-
/// separated Connection tokens.
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

// Tests (inline, std.testing) -- response parser
const testing = std.testing;

test "response: well-formed status + headers" {
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\n";
    var r = Response{};
    try parseHead(head, &r);
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqualSlices(u8, "OK", r.reason);
    try testing.expect(r.ok());
    try testing.expectEqualSlices(u8, "5", r.header("Content-Length").?);
}

test "response: header lookup is case-insensitive" {
    const head = "HTTP/1.1 204 No Content\r\nX-Custom: hi\r\n\r\n";
    var r = Response{};
    try parseHead(head, &r);
    try testing.expectEqualSlices(u8, "hi", r.header("x-custom").?);
    try testing.expectEqualSlices(u8, "hi", r.header("X-CUSTOM").?);
    try testing.expect(r.header("absent") == null);
}

test "response: value OWS trimmed" {
    const head = "HTTP/1.1 200 OK\r\nLocation:   https://x/   \r\n\r\n";
    var r = Response{};
    try parseHead(head, &r);
    try testing.expectEqualSlices(u8, "https://x/", r.header("Location").?);
}

test "response: repeated Set-Cookie via getNth" {
    const head = "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n";
    var r = Response{};
    try parseHead(head, &r);
    try testing.expectEqualSlices(u8, "a=1", r.headers.getNth("set-cookie", 0).?);
    try testing.expectEqualSlices(u8, "b=2", r.headers.getNth("set-cookie", 1).?);
    try testing.expect(r.headers.getNth("set-cookie", 2) == null);
}

test "response: absorbCookies into jar" {
    const head = "HTTP/1.1 200 OK\r\nSet-Cookie: SID=xyz; Path=/\r\nSet-Cookie: YSC=q\r\n\r\n";
    var r = Response{};
    try parseHead(head, &r);
    var jar = cookie.CookieJar.init();
    r.absorbCookies(&jar);
    try testing.expectEqualSlices(u8, "xyz", jar.get("SID").?);
    try testing.expectEqualSlices(u8, "q", jar.get("YSC").?);
}

test "response: keep-alive default true, close respected" {
    var r1 = Response{};
    try parseHead("HTTP/1.1 200 OK\r\n\r\n", &r1);
    try testing.expect(r1.keep_alive);
    var r2 = Response{};
    try parseHead("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", &r2);
    try testing.expect(!r2.keep_alive);
}

test "response: malformed status line rejected" {
    var r = Response{};
    try testing.expectError(error.BadResponse, parseHead("GARBAGE\r\n\r\n", &r));
}

test "response: non-numeric status rejected" {
    var r = Response{};
    try testing.expectError(error.BadResponse, parseHead("HTTP/1.1 2X0 Bad\r\n\r\n", &r));
}

test "response: header line without colon rejected" {
    var r = Response{};
    try testing.expectError(error.BadResponse, parseHead("HTTP/1.1 200 OK\r\nBadHeaderLine\r\n\r\n", &r));
}

test "response: headerEnd detects terminator incrementally" {
    try testing.expect(headerEnd("HTTP/1.1 200 OK\r\n") == null);
    const full = "HTTP/1.1 200 OK\r\n\r\n";
    try testing.expectEqual(full.len, headerEnd(full).?);
}

test "response: too many headers overflow signalled" {
    // Build a head with MAX_RESP_HEADERS + 1 headers.
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const sl = "HTTP/1.1 200 OK\r\n";
    @memcpy(buf[0..sl.len], sl); w = sl.len;
    var k: usize = 0;
    while (k < MAX_RESP_HEADERS + 1) : (k += 1) {
        const one = std.fmt.bufPrint(buf[w..], "H{d}: v\r\n", .{k}) catch unreachable;
        w += one.len;
    }
    @memcpy(buf[w..][0..2], "\r\n"); w += 2;
    var r = Response{};
    try testing.expectError(error.BufferTooSmall, parseHead(buf[0..w], &r));
}
