// @zpm/youtube/net — app-local HTTP adapter over @zpm/http
//
// A thin, allocator-free shim that preserves the exact call surface the
// YouTube layers used to get from the (now-deleted) platform/http_session and
// the hand-rolled WinHTTP blocks, but drives everything through the pure-Sig
// @zpm/http client (TLS 1.3, cookie jar, redirects, retries, typed errors).
//
// This module is app-specific orchestration: general HTTP lives in @zpm/http.
// Here we only re-shape @zpm/http's full-URL, caller-buffer API into the
// host/port/path + shared-static-buffer convention the YouTube callers expect,
// so the migration preserves behaviour (status/body/ok, persistent CookieJar)
// without duplicating any HTTP logic.
//
// Zero heap: all storage is module-static or caller-provided.

const zhttp = @import("zpm_http");

// ── Re-exports so callers keep one import ──

pub const CookieJar = zhttp.CookieJar;
pub const CHROME_UA = zhttp.CHROME_UA;

/// HTTP verb, matching the old http_session.Method surface.
pub const Method = enum { get, post };

/// Result of a request. Mirrors the old http_session.Response: a status code,
/// a borrowed body slice (valid until the next request reusing the shared
/// buffer), and a convenience `ok` flag (2xx/3xx).
pub const Response = struct {
    status: u32 = 0,
    body: []const u8 = "",
    ok: bool = false,
};

// ── Shared buffers (module-static, zero heap) ──
//
// Body destination for request()/get()/post(): 1 MB, matching the old
// http_session shared buffer (homepage HTML + BotGuard script can be large).
pub const RESP_BUF_SIZE: usize = 1024 * 1024;
var resp_buf: [RESP_BUF_SIZE]u8 = undefined;

// Response header scratch (status line + headers; cookies absorbed from here).
var header_scratch: [64 * 1024]u8 = undefined;
// Serialized request head.
var req_head: [16 * 1024]u8 = undefined;
// Built absolute URL for a request.
var url_buf: [zhttp.MAX_URL_BYTES]u8 = undefined;
// Caller extra-header block, normalized to CRLF-terminated lines.
var hdr_buf: [8 * 1024]u8 = undefined;

/// Wall-clock seconds for TLS certificate validity. The youtube callers do not
/// thread a clock, so we read it once here from the OS.
extern "kernel32" fn GetSystemTimeAsFileTime(*FILETIME) void;
const FILETIME = extern struct { low: u32 = 0, high: u32 = 0 };

fn nowUnix() i64 {
    var ft: FILETIME = .{};
    GetSystemTimeAsFileTime(&ft);
    const ticks: u64 = (@as(u64, ft.high) << 32) | @as(u64, ft.low);
    // FILETIME is 100ns ticks since 1601-01-01; convert to Unix seconds.
    const UNIX_EPOCH_TICKS: u64 = 116444736000000000;
    if (ticks < UNIX_EPOCH_TICKS) return 0;
    return @intCast((ticks - UNIX_EPOCH_TICKS) / 10_000_000);
}

/// Build "https://host[:port]path" into url_buf and return the slice (or null
/// if it does not fit). Port 443 is omitted (default); anything else is
/// appended. `path` must start with '/'.
fn buildUrl(host: []const u8, port: u16, path: []const u8) ?[]const u8 {
    if (host.len == 0 or path.len == 0 or path[0] != '/') return null;
    var p: usize = 0;
    const scheme = "https://";
    if (p + scheme.len > url_buf.len) return null;
    @memcpy(url_buf[p .. p + scheme.len], scheme);
    p += scheme.len;
    if (p + host.len > url_buf.len) return null;
    @memcpy(url_buf[p .. p + host.len], host);
    p += host.len;
    if (port != 443) {
        if (p + 1 > url_buf.len) return null;
        url_buf[p] = ':';
        p += 1;
        var tmp: [8]u8 = undefined;
        var t: usize = 0;
        var v: u32 = port;
        if (v == 0) { tmp[t] = '0'; t += 1; } else {
            var digits: [8]u8 = undefined;
            var d: usize = 0;
            while (v > 0) : (d += 1) { digits[d] = @intCast('0' + (v % 10)); v /= 10; }
            while (d > 0) { d -= 1; tmp[t] = digits[d]; t += 1; }
        }
        if (p + t > url_buf.len) return null;
        @memcpy(url_buf[p .. p + t], tmp[0..t]);
        p += t;
    }
    if (p + path.len > url_buf.len) return null;
    @memcpy(url_buf[p .. p + path.len], path);
    p += path.len;
    return url_buf[0..p];
}

/// Normalize a caller header block into hdr_buf. @zpm/http requires each extra
/// header line to be CRLF-terminated; the youtube callers already pass that
/// form ("Name: v\r\n..."), so this is a bounded copy that also guarantees a
/// trailing CRLF. Returns the normalized slice (empty if the input was empty).
fn normalizeHeaders(extra: []const u8) ?[]const u8 {
    if (extra.len == 0) return "";
    if (extra.len > hdr_buf.len) return null;
    const n = extra.len;
    @memcpy(hdr_buf[0..n], extra[0..n]);
    var len = n;
    // Ensure CRLF termination (callers already do this, but be defensive so
    // the serializer's per-line validation always sees complete lines).
    if (len >= 2 and hdr_buf[len - 2] == '\r' and hdr_buf[len - 1] == '\n') return hdr_buf[0..len];
    if (len + 2 <= hdr_buf.len) {
        hdr_buf[len] = '\r';
        hdr_buf[len + 1] = '\n';
        len += 2;
    } else return null;
    return hdr_buf[0..len];
}

/// Perform an HTTPS request against `host`/`path`, optionally sending `body`
/// (POST) and a cookie jar, absorbing Set-Cookie back into the jar. Mirrors the
/// old http_session.request: the response body lands in a shared static buffer
/// and the returned slice is valid until the next call. Zero heap.
pub fn request(
    method: Method,
    host: []const u8,
    port: u16,
    path: []const u8,
    extra_headers: []const u8,
    body: []const u8,
    jar: ?*CookieJar,
    user_agent: []const u8,
) Response {
    const url = buildUrl(host, port, path) orelse return .{};
    const hdrs = normalizeHeaders(extra_headers) orelse return .{};

    const req = zhttp.Request{
        .method = if (method == .post) .POST else .GET,
        .url = url,
        .headers = hdrs,
        .body = body,
        .user_agent = user_agent,
        .jar = jar,
        // Content-Type is carried verbatim in the caller header block, matching
        // the old WinHTTP AddRequestHeaders behaviour, so leave content_type
        // empty and let the extra headers frame it.
    };

    const bufs = zhttp.Buffers{
        .body = &resp_buf,
        .header_scratch = &header_scratch,
        .req_head = &req_head,
    };

    const resp = zhttp.fetch(req, bufs, nowUnix()) catch return .{};
    return .{
        .status = resp.status,
        .body = resp.body,
        .ok = resp.status >= 200 and resp.status < 400,
    };
}

/// GET over TLS with the cookie jar (default Chrome UA).
pub fn get(host: []const u8, path: []const u8, jar: ?*CookieJar, extra_headers: []const u8) Response {
    return request(.get, host, 443, path, extra_headers, "", jar, CHROME_UA);
}

/// POST over TLS with the cookie jar (default Chrome UA).
pub fn post(host: []const u8, path: []const u8, extra_headers: []const u8, body: []const u8, jar: ?*CookieJar) Response {
    return request(.post, host, 443, path, extra_headers, body, jar, CHROME_UA);
}

// ── Caller-buffer variants (for layers that own their response buffer) ──

/// Result of a GET/POST that writes directly into a caller buffer.
pub const IntoResult = struct {
    status: u32 = 0,
    len: usize = 0,
    ok: bool = false,
};

/// GET `https://host[:port]path` into `out`, returning status + bytes written.
/// Used by layers (innertube, thumbnails) that manage their own large buffers.
pub fn getInto(host: []const u8, port: u16, path: []const u8, extra_headers: []const u8, user_agent: []const u8, out: []u8) IntoResult {
    return into(.get, host, port, path, extra_headers, "", user_agent, out);
}

/// POST `body` to `https://host[:port]path` into `out`.
pub fn postInto(host: []const u8, port: u16, path: []const u8, extra_headers: []const u8, body: []const u8, user_agent: []const u8, out: []u8) IntoResult {
    return into(.post, host, port, path, extra_headers, body, user_agent, out);
}

/// POST `body` to `https://host[:port]path` into the caller buffer `out`,
/// threading a cookie jar so a session's cookies ride the request (and any
/// Set-Cookie is absorbed back). This is the SABR variant: the loop owns a
/// multi-MB `out` buffer (a UMP response can exceed the 1 MB static `resp_buf`)
/// and must send the visitor session jar. `postInto` stays jar-less for its
/// existing callers.
pub fn postIntoJar(host: []const u8, port: u16, path: []const u8, extra_headers: []const u8, body: []const u8, user_agent: []const u8, jar: ?*CookieJar, out: []u8) IntoResult {
    const url = buildUrl(host, port, path) orelse return .{};
    const hdrs = normalizeHeaders(extra_headers) orelse return .{};
    const req = zhttp.Request{
        .method = .POST,
        .url = url,
        .headers = hdrs,
        .body = body,
        .user_agent = user_agent,
        .jar = jar,
    };
    const bufs = zhttp.Buffers{
        .body = out,
        .header_scratch = &header_scratch,
        .req_head = &req_head,
    };
    const resp = zhttp.fetch(req, bufs, nowUnix()) catch return .{};
    return .{ .status = resp.status, .len = resp.body.len, .ok = resp.status >= 200 and resp.status < 400 };
}

fn into(
    method: Method,
    host: []const u8,
    port: u16,
    path: []const u8,
    extra_headers: []const u8,
    body: []const u8,
    user_agent: []const u8,
    out: []u8,
) IntoResult {
    const url = buildUrl(host, port, path) orelse return .{};
    const hdrs = normalizeHeaders(extra_headers) orelse return .{};
    const req = zhttp.Request{
        .method = if (method == .post) .POST else .GET,
        .url = url,
        .headers = hdrs,
        .body = body,
        .user_agent = user_agent,
    };
    const bufs = zhttp.Buffers{
        .body = out,
        .header_scratch = &header_scratch,
        .req_head = &req_head,
    };
    const resp = zhttp.fetch(req, bufs, nowUnix()) catch return .{};
    return .{ .status = resp.status, .len = resp.body.len, .ok = resp.status >= 200 and resp.status < 400 };
}

// ── Ranged GET (for the stream downloader) ──

/// Result of a ranged GET: the HTTP status, the bytes written into the caller
/// buffer, and the total resource size parsed from a `Content-Range` header
/// (0 when absent, e.g. a 200 response).
pub const RangeResult = struct {
    status: u32 = 0,
    len: usize = 0,
    total: u64 = 0,
    // Borrowed from shared header scratch until the next HTTP request.
    content_range: []const u8 = "",
    content_length: u64 = 0,
    ok: bool = false,
};

/// GET `https://host[:port]path` for byte range [start, end] inclusive into
/// `out`. Sends a `Range: bytes=start-end` header plus the given extra headers.
/// Parses `Content-Range: bytes start-end/total` to recover the full resource
/// size. Preserves the behaviour of the old WinHTTP ranged downloader: only a
/// 200 or 206 status yields `ok = true`.
pub fn getRangeInto(
    host: []const u8,
    port: u16,
    path: []const u8,
    extra_headers: []const u8,
    user_agent: []const u8,
    start: u64,
    end: u64,
    out: []u8,
) RangeResult {
    const url = buildUrl(host, port, path) orelse return .{};

    // Build the header block: Range line first, then the caller's extra headers.
    var hb: [8 * 1024]u8 = undefined;
    var p: usize = 0;
    const pre = "Range: bytes=";
    @memcpy(hb[p .. p + pre.len], pre);
    p += pre.len;
    p += writeU64(hb[p..], start);
    hb[p] = '-'; p += 1;
    p += writeU64(hb[p..], end);
    hb[p] = '\r'; p += 1;
    hb[p] = '\n'; p += 1;
    if (p + extra_headers.len + 2 > hb.len) return .{};
    if (extra_headers.len > 0) {
        @memcpy(hb[p .. p + extra_headers.len], extra_headers);
        p += extra_headers.len;
        if (!(p >= 2 and hb[p - 2] == '\r' and hb[p - 1] == '\n') and p + 2 <= hb.len) {
            hb[p] = '\r'; p += 1; hb[p] = '\n'; p += 1;
        }
    }

    const req = zhttp.Request{
        .method = .GET,
        .url = url,
        .headers = hb[0..p],
        .user_agent = user_agent,
    };
    const bufs = zhttp.Buffers{
        .body = out,
        .header_scratch = &header_scratch,
        .req_head = &req_head,
    };
    const resp = zhttp.fetch(req, bufs, nowUnix()) catch return .{};

    const cr = resp.header("content-range") orelse "";
    const total = parseContentRangeTotal(cr) orelse 0;
    const content_length = if (resp.header("content-length")) |cl| parseDecimal(cl) orelse 0 else 0;
    const okstatus = resp.complete and (resp.status == 200 or resp.status == 206);
    return .{ .status = resp.status, .len = resp.body.len, .total = total, .content_range = cr, .content_length = content_length, .ok = okstatus };
}

/// Parse the total from "bytes start-end/total"; returns null if malformed.
fn parseContentRangeTotal(cr: []const u8) ?u64 {
    const prefix = "bytes ";
    if (cr.len <= prefix.len) return null;
    for (prefix, 0..) |c, j| if (cr[j] != c) return null;
    var i: usize = 0;
    while (i < cr.len and cr[i] != '/') : (i += 1) {}
    if (i >= cr.len) return null;
    i += 1;
    if (i >= cr.len or cr[i] == '*') return null;
    return parseDecimal(cr[i..]);
}

fn parseDecimal(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u64 = c - '0';
        if (n > (0xFFFFFFFFFFFFFFFF - digit) / 10) return null;
        n = n * 10 + digit;
    }
    return n;
}

fn writeU64(buf: []u8, val: u64) usize {
    if (val == 0) { buf[0] = '0'; return 1; }
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v = val;
    while (v > 0) : (d += 1) { digits[d] = @intCast('0' + (v % 10)); v /= 10; }
    var n: usize = 0;
    while (d > 0) { d -= 1; buf[n] = digits[d]; n += 1; }
    return n;
}

// Tests (inline, std.testing) -- URL/header shaping (pure, offline).
const std = @import("std");
const testing = std.testing;

test "net: buildUrl omits default port 443" {
    const u = buildUrl("www.youtube.com", 443, "/watch?v=abc").?;
    try testing.expectEqualSlices(u8, "https://www.youtube.com/watch?v=abc", u);
}

test "net: buildUrl includes non-default port" {
    const u = buildUrl("example.com", 8443, "/").?;
    try testing.expectEqualSlices(u8, "https://example.com:8443/", u);
}

test "net: normalizeHeaders passes through CRLF-terminated block" {
    const h = normalizeHeaders("Content-Type: application/json\r\n").?;
    try testing.expectEqualSlices(u8, "Content-Type: application/json\r\n", h);
}

test "net: normalizeHeaders appends missing CRLF" {
    const h = normalizeHeaders("X-A: 1").?;
    try testing.expectEqualSlices(u8, "X-A: 1\r\n", h);
}

test "net: empty header block stays empty" {
    try testing.expectEqual(@as(usize, 0), normalizeHeaders("").?.len);
}

test "net: Method maps to zpm_http verbs" {
    try testing.expectEqual(zhttp.Method.POST, @as(zhttp.Method, if (Method.post == .post) .POST else .GET));
}

test "net: parseContentRangeTotal reads total after slash" {
    try testing.expectEqual(@as(u64, 12345), parseContentRangeTotal("bytes 0-1023/12345").?);
}

test "net: parseContentRangeTotal rejects unknown total" {
    try testing.expect(parseContentRangeTotal("bytes 0-1023/*") == null);
}

test "net: writeU64 renders decimal" {
    var b: [20]u8 = undefined;
    const n = writeU64(&b, 1048575);
    try testing.expectEqualSlices(u8, "1048575", b[0..n]);
}
