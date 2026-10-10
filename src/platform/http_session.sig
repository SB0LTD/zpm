// @zpm/platform/http_session — Cookied HTTP Session Client (Layer 1: Platform)
//
// A browser-like HTTPS client built on WinHTTP with a persistent cookie jar.
// Unlike the one-shot GET helpers in platform/http.sig, this maintains cookie
// state across requests so a caller can perform a real multi-request session:
//
//   homepage GET  ->  Set-Cookie: VISITOR_INFO1_LIVE, YSC, __Secure-*, CONSENT
//   att/get POST  ->  (sends Cookie: header + reads more Set-Cookie)
//   GenerateIT    ->  (session-bound, cookies + visitor id carried)
//   player POST   ->  (session-bound stream URLs)
//
// Design (matches the zero-heap conventions in innertube.sig / challenge.sig):
//   - WinHTTP resolved dynamically via LoadLibraryA/GetProcAddress (no module
//     import wiring needed; identical to the other youtube WinHTTP layers).
//   - Fixed-size module-static buffers; no allocator.
//   - Explicit cookie jar: we parse Set-Cookie from the raw response headers and
//     store name=value pairs, then emit a single `Cookie:` header on each request
//     to the SAME registrable domain. This gives us full control (WinHTTP's
//     implicit jar is per-session-handle and not introspectable).
//
// The cookie jar is domain-agnostic within one logical session: YouTube first-
// party cookies are what matter for a genuine visitor session, so callers scope
// a jar per host family (youtube.com). jnn-pa.googleapis.com requests carry the
// visitor id via header, not cookies.

// ── Win32 / WinHTTP (dynamic) ──
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;

const HINTERNET = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*]const u16;

const WINHTTP_ACCESS_TYPE_DEFAULT: DWORD = 0;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const WINHTTP_ADDREQ_FLAG_ADD: DWORD = 0x20000000;
const WINHTTP_ADDREQ_FLAG_REPLACE: DWORD = 0x80000000;
const WINHTTP_ADDREQ_FLAG_COALESCE_WITH_SEMICOLON: DWORD = 0x01000000;

// WinHttpQueryHeaders info levels / flags.
const WINHTTP_QUERY_RAW_HEADERS_CRLF: DWORD = 22;
const WINHTTP_QUERY_STATUS_CODE: DWORD = 19;
const WINHTTP_QUERY_FLAG_NUMBER: DWORD = 0x20000000;
const WINHTTP_HEADER_NAME_BY_INDEX: ?LPCWSTR = null;

// WinHTTP options.
const WINHTTP_OPTION_DISABLE_FEATURE: DWORD = 63;
const WINHTTP_DISABLE_COOKIES: DWORD = 0x00000001;
const WINHTTP_OPTION_REDIRECT_POLICY: DWORD = 88;
const WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP: DWORD = 1;

const WinHttpOpenFn = *const fn (LPCWSTR, DWORD, ?LPCWSTR, ?LPCWSTR, DWORD) callconv(.c) HINTERNET;
const WinHttpConnectFn = *const fn (HINTERNET, LPCWSTR, u16, DWORD) callconv(.c) HINTERNET;
const WinHttpOpenRequestFn = *const fn (HINTERNET, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?*anyopaque, DWORD) callconv(.c) HINTERNET;
const WinHttpSendRequestFn = *const fn (HINTERNET, ?LPCWSTR, DWORD, ?*anyopaque, DWORD, DWORD, usize) callconv(.c) BOOL;
const WinHttpReceiveResponseFn = *const fn (HINTERNET, ?*anyopaque) callconv(.c) BOOL;
const WinHttpReadDataFn = *const fn (HINTERNET, [*]u8, DWORD, *DWORD) callconv(.c) BOOL;
const WinHttpCloseHandleFn = *const fn (HINTERNET) callconv(.c) BOOL;
const WinHttpAddRequestHeadersFn = *const fn (HINTERNET, LPCWSTR, DWORD, DWORD) callconv(.c) BOOL;
const WinHttpQueryHeadersFn = *const fn (HINTERNET, DWORD, ?LPCWSTR, ?*anyopaque, *DWORD, ?*DWORD) callconv(.c) BOOL;
const WinHttpSetOptionFn = *const fn (HINTERNET, DWORD, ?*const anyopaque, DWORD) callconv(.c) BOOL;
const WinHttpSetTimeoutsFn = *const fn (HINTERNET, c_int, c_int, c_int, c_int) callconv(.c) BOOL;

var fn_open: ?WinHttpOpenFn = null;
var fn_connect: ?WinHttpConnectFn = null;
var fn_openReq: ?WinHttpOpenRequestFn = null;
var fn_sendReq: ?WinHttpSendRequestFn = null;
var fn_recvResp: ?WinHttpReceiveResponseFn = null;
var fn_readData: ?WinHttpReadDataFn = null;
var fn_closeHandle: ?WinHttpCloseHandleFn = null;
var fn_addHeaders: ?WinHttpAddRequestHeadersFn = null;
var fn_queryHeaders: ?WinHttpQueryHeadersFn = null;
var fn_setOption: ?WinHttpSetOptionFn = null;
var fn_setTimeouts: ?WinHttpSetTimeoutsFn = null;
var http_loaded: bool = false;

fn ensureHttp() bool {
    if (http_loaded) return true;
    const dll = LoadLibraryA("winhttp.dll") orelse return false;
    fn_open = @ptrCast(GetProcAddress(dll, "WinHttpOpen"));
    fn_connect = @ptrCast(GetProcAddress(dll, "WinHttpConnect"));
    fn_openReq = @ptrCast(GetProcAddress(dll, "WinHttpOpenRequest"));
    fn_sendReq = @ptrCast(GetProcAddress(dll, "WinHttpSendRequest"));
    fn_recvResp = @ptrCast(GetProcAddress(dll, "WinHttpReceiveResponse"));
    fn_readData = @ptrCast(GetProcAddress(dll, "WinHttpReadData"));
    fn_closeHandle = @ptrCast(GetProcAddress(dll, "WinHttpCloseHandle"));
    fn_addHeaders = @ptrCast(GetProcAddress(dll, "WinHttpAddRequestHeaders"));
    fn_queryHeaders = @ptrCast(GetProcAddress(dll, "WinHttpQueryHeaders"));
    fn_setOption = @ptrCast(GetProcAddress(dll, "WinHttpSetOption"));
    fn_setTimeouts = @ptrCast(GetProcAddress(dll, "WinHttpSetTimeouts"));
    if (fn_open == null or fn_sendReq == null or fn_queryHeaders == null) return false;
    http_loaded = true;
    return true;
}

fn toWide(comptime s: []const u8) [s.len + 1]u16 {
    var r: [s.len + 1]u16 = undefined;
    for (0..s.len) |i| r[i] = s[i];
    r[s.len] = 0;
    return r;
}

/// Widen a runtime ASCII/UTF-8 byte slice into `out` (null-terminated).
/// Returns false if it doesn't fit. Non-ASCII bytes are passed through as-is
/// (WinHTTP header/path values here are ASCII).
fn widenRt(s: []const u8, out: []u16) bool {
    if (s.len + 1 > out.len) return false;
    for (0..s.len) |i| out[i] = s[i];
    out[s.len] = 0;
    return true;
}

// ── Cookie jar ──

pub const MAX_COOKIES: usize = 64;
const COOKIE_NAME_MAX: usize = 64;
const COOKIE_VALUE_MAX: usize = 768; // __Secure-* / session tokens can be long

const Cookie = struct {
    name: [COOKIE_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    value: [COOKIE_VALUE_MAX]u8 = undefined,
    value_len: usize = 0,
    used: bool = false,
};

pub const CookieJar = struct {
    cookies: [MAX_COOKIES]Cookie = [_]Cookie{.{}} ** MAX_COOKIES,

    pub fn init() CookieJar {
        return .{};
    }

    pub fn clear(self: *CookieJar) void {
        for (0..MAX_COOKIES) |i| self.cookies[i].used = false;
    }

    /// Count of live cookies.
    pub fn count(self: *const CookieJar) usize {
        var n: usize = 0;
        for (self.cookies) |c| if (c.used) { n += 1; };
        return n;
    }

    /// Insert or replace a cookie by name.
    pub fn set(self: *CookieJar, name: []const u8, value: []const u8) void {
        if (name.len == 0 or name.len > COOKIE_NAME_MAX) return;
        const vlen = @min(value.len, COOKIE_VALUE_MAX);
        // Replace existing.
        for (0..MAX_COOKIES) |i| {
            const c = &self.cookies[i];
            if (c.used and eq(c.name[0..c.name_len], name)) {
                @memcpy(c.value[0..vlen], value[0..vlen]);
                c.value_len = vlen;
                return;
            }
        }
        // Insert into a free slot.
        for (0..MAX_COOKIES) |i| {
            const c = &self.cookies[i];
            if (!c.used) {
                @memcpy(c.name[0..name.len], name);
                c.name_len = name.len;
                @memcpy(c.value[0..vlen], value[0..vlen]);
                c.value_len = vlen;
                c.used = true;
                return;
            }
        }
    }

    /// Look up a cookie value by name.
    pub fn get(self: *const CookieJar, name: []const u8) ?[]const u8 {
        for (self.cookies) |c| {
            if (c.used and eq(c.name[0..c.name_len], name)) return c.value[0..c.value_len];
        }
        return null;
    }

    /// Serialize all cookies as a `Cookie:` header VALUE ("a=1; b=2") into `out`.
    /// Returns the number of bytes written (0 if the jar is empty).
    pub fn serialize(self: *const CookieJar, out: []u8) usize {
        var pos: usize = 0;
        var first = true;
        for (self.cookies) |c| {
            if (!c.used) continue;
            const need = c.name_len + 1 + c.value_len + (if (first) @as(usize, 0) else 2);
            if (pos + need > out.len) break;
            if (!first) { out[pos] = ';'; out[pos + 1] = ' '; pos += 2; }
            @memcpy(out[pos .. pos + c.name_len], c.name[0..c.name_len]);
            pos += c.name_len;
            out[pos] = '='; pos += 1;
            @memcpy(out[pos .. pos + c.value_len], c.value[0..c.value_len]);
            pos += c.value_len;
            first = false;
        }
        return pos;
    }

    /// Parse the raw response headers (CRLF-separated) and absorb every
    /// `Set-Cookie:` line into the jar. Only name=value is kept (attributes
    /// like Path/Domain/Expires/Secure are dropped — we send the jar back to
    /// the same host family, which is what a browser session needs here).
    pub fn absorbRawHeaders(self: *CookieJar, headers: []const u8) void {
        var i: usize = 0;
        while (i < headers.len) {
            // Find end of this header line.
            var end = i;
            while (end + 1 < headers.len and !(headers[end] == '\r' and headers[end + 1] == '\n')) : (end += 1) {}
            const line = headers[i..end];
            i = end + 2;
            if (i > headers.len) i = headers.len;
            // Case-insensitive prefix "set-cookie:".
            if (hasPrefixCI(line, "set-cookie:")) {
                var rest = line["set-cookie:".len..];
                rest = trimLeadWs(rest);
                // Cookie is up to the first ';'.
                var semi: usize = 0;
                while (semi < rest.len and rest[semi] != ';') : (semi += 1) {}
                const pair = rest[0..semi];
                // Split name=value.
                var eqp: usize = 0;
                while (eqp < pair.len and pair[eqp] != '=') : (eqp += 1) {}
                if (eqp < pair.len) {
                    const nm = pair[0..eqp];
                    const vv = pair[eqp + 1 ..];
                    self.set(nm, vv);
                }
            }
        }
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn hasPrefixCI(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (0..prefix.len) |i| if (lower(s[i]) != lower(prefix[i])) return false;
    return true;
}

fn trimLeadWs(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t')) : (a += 1) {}
    return s[a..];
}

// ── Request/response ──

pub const Method = enum { get, post };

/// Result of a request.
pub const Response = struct {
    status: u32 = 0,
    body: []const u8 = "",
    ok: bool = false,
};

// Shared response body buffer (1 MB — homepage HTML + BG script can be large).
pub const RESP_BUF_SIZE: usize = 1024 * 1024;
var resp_buf: [RESP_BUF_SIZE]u8 = undefined;

// Raw response headers scratch (for Set-Cookie parsing).
var raw_headers_w: [16384]u16 = undefined;
var raw_headers_a: [16384]u8 = undefined;

/// Perform an HTTPS request against `host` (ASCII) / `path` (ASCII), optionally
/// sending `body` (POST) and a jar's cookies, absorbing Set-Cookie back into the
/// jar. `extra_headers` is a raw header block ("Name: v\r\nName2: v2\r\n") or "".
///
/// The response body is stored in a shared static buffer; the returned slice is
/// valid until the next call. Zero-heap.
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
    if (!ensureHttp()) return .{};

    var host_w: [256]u16 = undefined;
    if (!widenRt(host, &host_w)) return .{};
    var path_w: [2048]u16 = undefined;
    if (!widenRt(path, &path_w)) return .{};
    var ua_w: [256]u16 = undefined;
    if (!widenRt(user_agent, &ua_w)) return .{};

    const W_POST = comptime toWide("POST");

    const hSession = fn_open.?(&ua_w, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return .{};
    defer _ = fn_closeHandle.?(hSession);
    if (fn_setTimeouts) |st| _ = st(hSession, 15000, 20000, 30000, 60000);
    // We manage cookies ourselves — disable WinHTTP's implicit jar so it doesn't
    // send stale/duplicate cookies. (Best-effort; ignore failure.)
    if (fn_setOption) |so| {
        var feat: DWORD = WINHTTP_DISABLE_COOKIES;
        _ = so(hSession, WINHTTP_OPTION_DISABLE_FEATURE, @ptrCast(&feat), @sizeOf(DWORD));
    }

    const hConnect = fn_connect.?(hSession, &host_w, port, 0) orelse return .{};
    defer _ = fn_closeHandle.?(hConnect);

    const verb: ?LPCWSTR = if (method == .post) @as(LPCWSTR, &W_POST) else null;
    const hRequest = fn_openReq.?(hConnect, verb, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse return .{};
    defer _ = fn_closeHandle.?(hRequest);

    // Extra headers (Content-Type, api keys, visitor id, etc.).
    if (extra_headers.len > 0) {
        var eh_w: [4096]u16 = undefined;
        if (widenRt(extra_headers, &eh_w)) {
            _ = fn_addHeaders.?(hRequest, &eh_w, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
        }
    }

    // Cookie header from the jar.
    if (jar) |j| {
        var cookie_val: [4096]u8 = undefined;
        const cl = j.serialize(&cookie_val);
        if (cl > 0) {
            var line: [4160]u8 = undefined;
            var p: usize = 0;
            const pre = "Cookie: ";
            @memcpy(line[p .. p + pre.len], pre); p += pre.len;
            @memcpy(line[p .. p + cl], cookie_val[0..cl]); p += cl;
            line[p] = '\r'; p += 1; line[p] = '\n'; p += 1;
            var line_w: [4160]u16 = undefined;
            if (widenRt(line[0..p], &line_w)) {
                _ = fn_addHeaders.?(hRequest, &line_w, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
            }
        }
    }

    // Send.
    const blen: u32 = @intCast(body.len);
    const body_ptr: ?*anyopaque = if (body.len > 0) @ptrCast(@constCast(body.ptr)) else null;
    if (fn_sendReq.?(hRequest, null, 0, body_ptr, blen, blen, 0) == 0) return .{};
    if (fn_recvResp.?(hRequest, null) == 0) return .{};

    // Status code.
    var status_code: u32 = 0;
    var sz: DWORD = @sizeOf(u32);
    _ = fn_queryHeaders.?(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, @ptrCast(&status_code), &sz, null);

    // Raw response headers -> absorb Set-Cookie.
    if (jar) |j| {
        var hsz: DWORD = @intCast(raw_headers_w.len * 2); // bytes
        if (fn_queryHeaders.?(hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, @ptrCast(&raw_headers_w), &hsz, null) != 0) {
            const nwch = hsz / 2;
            const n = @min(nwch, raw_headers_a.len);
            var k: usize = 0;
            while (k < n) : (k += 1) raw_headers_a[k] = @intCast(raw_headers_w[k] & 0xFF);
            j.absorbRawHeaders(raw_headers_a[0..n]);
        }
    }

    // Body.
    var total: usize = 0;
    while (total < RESP_BUF_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, resp_buf[total..].ptr, @intCast(RESP_BUF_SIZE - total), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }

    return .{ .status = status_code, .body = resp_buf[0..total], .ok = status_code >= 200 and status_code < 400 };
}

// ── Convenience wrappers ──

pub const CHROME_UA: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// GET over TLS with the cookie jar.
pub fn get(host: []const u8, path: []const u8, jar: ?*CookieJar, extra_headers: []const u8) Response {
    return request(.get, host, 443, path, extra_headers, "", jar, CHROME_UA);
}

/// POST over TLS with the cookie jar.
pub fn post(host: []const u8, path: []const u8, extra_headers: []const u8, body: []const u8, jar: ?*CookieJar) Response {
    return request(.post, host, 443, path, extra_headers, body, jar, CHROME_UA);
}
