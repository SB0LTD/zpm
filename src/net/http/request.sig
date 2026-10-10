// HTTP/1.1 request model and serializer.
//
// `Request` is the caller-facing options struct (method, url, headers, body,
// cookie jar, policy). `serializeHead` renders the request line + headers +
// blank line into a caller-owned buffer; the protocol layer then writes the
// head followed by the body (two writeAlls, no per-byte socket calls).
//
// Every caller-supplied header byte is injection-checked: a bare CR, LF, or NUL
// in a name or value is rejected with InvalidHeader (Req 3.7).

const std = @import("std");
const errors = @import("errors.sig");
const url_mod = @import("url.sig");
const cookie = @import("cookie.sig");
const retry = @import("retry.sig");

pub const Error = errors.Error;
pub const Method = errors.Method;
pub const CookieJar = cookie.CookieJar;
pub const CHROME_UA = cookie.CHROME_UA;
pub const RetryPolicy = retry.RetryPolicy;

pub const MAX_REQUEST_HEADER: usize = 8 * 1024; // serialized request head
pub const MAX_EXTRA_HEADERS: usize = 4 * 1024; // caller raw header block

pub const Timeouts = struct {
    connect_ms: u32 = 15_000,
    send_ms: u32 = 20_000,
    recv_ms: u32 = 30_000,
    total_ms: u32 = 60_000,
};

/// Caller-facing request options. All slices are borrowed; the client copies
/// nothing beyond what it writes into caller buffers.
pub const Request = struct {
    method: Method = .GET,
    /// Absolute URL (scheme://host[:port]/path?query).
    url: []const u8,
    /// Raw extra-header block, verbatim: "Name: v\r\nName2: v2\r\n". Each
    /// line is injection-checked. May be empty.
    headers: []const u8 = "",
    /// Optional Content-Type; framing rules apply a default when a body is
    /// present and neither this nor an extra header set it.
    content_type: []const u8 = "",
    body: []const u8 = "",
    user_agent: []const u8 = CHROME_UA,
    jar: ?*CookieJar = null,
    timeouts: Timeouts = .{},
    max_redirects: u8 = 5,
    allow_insecure_redirect: bool = false,
    retry_non_idempotent: bool = false,
    trace: ?*errors.Trace = null,
    retry: RetryPolicy = .{},
};

/// Reject a bare CR, LF, or NUL anywhere in a caller-supplied header byte run.
/// Validate a caller extra-header block: each line is CRLF-terminated, non-
/// empty, contains a colon, and holds no bare CR/LF/NUL inside the line. An
/// empty block is valid. This allows the legitimate CRLF separators while
/// rejecting header-injection attempts (Req 3.7).
fn validHeaderBlock(block: []const u8) bool {
    if (block.len == 0) return true;
    var i: usize = 0;
    while (i < block.len) {
        var e = i;
        while (e < block.len and block[e] != '\r' and block[e] != '\n') : (e += 1) {
            if (block[e] == 0) return false;
        }
        if (e + 1 >= block.len or block[e] != '\r' or block[e + 1] != '\n') return false;
        const line = block[i..e];
        if (line.len == 0) return false;
        var has_colon = false;
        for (line) |c| { if (c == ':') { has_colon = true; break; } }
        if (!has_colon) return false;
        i = e + 2;
    }
    return true;
}

fn hasForbidden(bytes: []const u8) bool {
    for (bytes) |b| if (b == '\r' or b == '\n' or b == 0) return true;
    return false;
}

fn methodName(m: Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .HEAD => "HEAD",
        .PATCH => "PATCH",
        .OPTIONS => "OPTIONS",
    };
}

/// Case-insensitive substring search over a header block, matching only at a
/// line start (so "Content-Length" does not match inside another value).
fn blockHasHeader(block: []const u8, name_lower: []const u8) bool {
    var i: usize = 0;
    while (i < block.len) {
        // start of a line
        var j: usize = 0;
        while (j < name_lower.len and i + j < block.len and lower(block[i + j]) == name_lower[j]) : (j += 1) {}
        if (j == name_lower.len and i + j < block.len and block[i + j] == ':') return true;
        // advance to next line
        while (i < block.len and block[i] != '\n') : (i += 1) {}
        i += 1;
    }
    return false;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Bounded append-only writer over a caller buffer.
const Buf = struct {
    b: []u8,
    n: usize = 0,
    fn put(self: *Buf, s: []const u8) Error!void {
        if (self.n + s.len > self.b.len) return Error.BufferTooSmall;
        @memcpy(self.b[self.n .. self.n + s.len], s);
        self.n += s.len;
    }
    fn putU16(self: *Buf, v: u16) Error!void {
        var tmp: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return Error.BufferTooSmall;
        try self.put(s);
    }
    fn putUsize(self: *Buf, v: usize) Error!void {
        var tmp: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return Error.BufferTooSmall;
        try self.put(s);
    }
};

fn defaultPort(scheme: url_mod.Scheme) u16 {
    return if (scheme == .https) 443 else 80;
}

/// Serialize the request line + headers + terminating blank line into `out`.
/// Returns the written head slice. The body is written separately by the
/// protocol layer. `keep_alive` picks Connection: keep-alive vs close.
///
/// Order (design 3.1-3.9): request line, Host, User-Agent, Accept-Encoding,
/// Connection, verbatim extra headers, Cookie, auto Content-Length/-Type.
pub fn serializeHead(out: []u8, u: url_mod.Url, req: Request, keep_alive: bool) Error![]const u8 {
    // Guard caller-controlled bytes up front.
    if (!validHeaderBlock(req.headers)) return Error.InvalidHeader;
    if (hasForbidden(req.content_type)) return Error.InvalidHeader;
    if (hasForbidden(req.user_agent)) return Error.InvalidHeader;

    var w = Buf{ .b = out };

    // 1. Request line.
    try w.put(methodName(req.method));
    try w.put(" ");
    try w.put(u.path_query);
    try w.put(" HTTP/1.1\r\n");

    // 2. Host (host:port when non-default for the scheme).
    try w.put("Host: ");
    try w.put(u.host);
    if (u.port != defaultPort(u.scheme)) {
        try w.put(":");
        try w.putU16(u.port);
    }
    try w.put("\r\n");

    // 3. User-Agent.
    try w.put("User-Agent: ");
    try w.put(req.user_agent);
    try w.put("\r\n");

    // 4. Accept-Encoding: identity (unless caller overrides via extra headers).
    if (!blockHasHeader(req.headers, "accept-encoding")) {
        try w.put("Accept-Encoding: identity\r\n");
    }

    // 5. Connection.
    if (!blockHasHeader(req.headers, "connection")) {
        try w.put(if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n");
    }

    // 6. Caller extra headers, verbatim (already injection-checked above).
    try w.put(req.headers);

    // 7. Cookie header from the jar.
    if (req.jar) |jar| {
        if (jar.count() != 0) {
            var cbuf: [cookie.MAX_COOKIES * (64 + 1 + 768 + 2)]u8 = undefined;
            const clen = jar.serialize(&cbuf);
            if (clen != 0) {
                try w.put("Cookie: ");
                try w.put(cbuf[0..clen]);
                try w.put("\r\n");
            }
        }
    }

    // 8. Body framing: auto Content-Length and Content-Type when a body is
    //    present and the caller did not already frame it.
    const has_len = blockHasHeader(req.headers, "content-length");
    const has_te = blockHasHeader(req.headers, "transfer-encoding");
    const has_ct_hdr = blockHasHeader(req.headers, "content-type");
    if (req.body.len > 0 and !has_len and !has_te) {
        try w.put("Content-Length: ");
        try w.putUsize(req.body.len);
        try w.put("\r\n");
        if (!has_ct_hdr) {
            if (req.content_type.len > 0) {
                try w.put("Content-Type: ");
                try w.put(req.content_type);
                try w.put("\r\n");
            } else {
                try w.put("Content-Type: application/octet-stream\r\n");
            }
        }
    } else if (req.content_type.len > 0 and !has_ct_hdr and req.body.len > 0) {
        // caller framed length/TE themselves but still gave a content type
        try w.put("Content-Type: ");
        try w.put(req.content_type);
        try w.put("\r\n");
    }

    // 9. Blank line terminates the head.
    try w.put("\r\n");
    return out[0..w.n];
}

// Tests (inline, std.testing) -- request serialization
const testing = std.testing;

fn parseUrl(raw: []const u8, hb: []u8) url_mod.Url {
    return url_mod.Url.parse(raw, hb) catch unreachable;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "request: GET line, Host, UA, defaults" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://example.com/path?q=1", &hb);
    const head = try serializeHead(&out, u, .{ .url = "https://example.com/path?q=1" }, false);
    try testing.expect(contains(head, "GET /path?q=1 HTTP/1.1\r\n"));
    try testing.expect(contains(head, "Host: example.com\r\n"));
    try testing.expect(contains(head, "User-Agent: "));
    try testing.expect(contains(head, "Accept-Encoding: identity\r\n"));
    try testing.expect(contains(head, "Connection: close\r\n"));
    try testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
}

test "request: Host includes non-default port" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://example.com:8443/", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x" }, false);
    try testing.expect(contains(head, "Host: example.com:8443\r\n"));
}

test "request: keep-alive flag selects Connection header" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x" }, true);
    try testing.expect(contains(head, "Connection: keep-alive\r\n"));
}

test "request: body framing adds Content-Length and default Content-Type" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://h/post", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x", .method = .POST, .body = "hello" }, false);
    try testing.expect(contains(head, "POST /post HTTP/1.1\r\n"));
    try testing.expect(contains(head, "Content-Length: 5\r\n"));
    try testing.expect(contains(head, "Content-Type: application/octet-stream\r\n"));
}

test "request: caller Content-Type respected" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x", .method = .POST, .body = "{}", .content_type = "application/json" }, false);
    try testing.expect(contains(head, "Content-Type: application/json\r\n"));
    try testing.expect(!contains(head, "application/octet-stream"));
}

test "request: caller Content-Length not duplicated" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x", .method = .POST, .body = "abc", .headers = "Content-Length: 3\r\n" }, false);
    // only the caller's one appears
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "Content-Length:"));
}

test "request: bodyless has no Content-Type" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x" }, false);
    try testing.expect(!contains(head, "Content-Type"));
    try testing.expect(!contains(head, "Content-Length"));
}

test "request: header injection rejected" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    const u = parseUrl("https://h/", &hb);
    try testing.expectError(error.InvalidHeader, serializeHead(&out, u, .{ .url = "x", .user_agent = "bad\r\nX-Evil: 1" }, false));
}

test "request: cookie header emitted from jar" {
    var hb: [256]u8 = undefined;
    var out: [MAX_REQUEST_HEADER]u8 = undefined;
    var jar = CookieJar.init();
    jar.set("SID", "xyz");
    const u = parseUrl("https://h/", &hb);
    const head = try serializeHead(&out, u, .{ .url = "x", .jar = &jar }, false);
    try testing.expect(contains(head, "Cookie: SID=xyz\r\n"));
}
