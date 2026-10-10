// Redirect decision logic (Req 9).
//
// Pure helpers the fetch/Client loop consults after each response:
//   isRedirect(status)              -> is this a 3xx we follow?
//   rewriteMethod(method, status)   -> new method + whether to drop the body
//   resolveLocation(cur, loc, out)  -> absolute target URL (abs / scheme-rel / rel)
//   insecureDowngrade(from, to)     -> https -> http (refused unless opted in)
// The loop itself (connect, send, read, count) lives in client.sig; keeping the
// decisions here makes them hermetically testable without a socket.

const std = @import("std");
const errors = @import("errors.sig");
const url_mod = @import("url.sig");

pub const Error = errors.Error;
pub const Method = errors.Method;
pub const Scheme = url_mod.Scheme;

/// 301/302/303/307/308 are the redirects we follow.
pub fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

pub const MethodRewrite = struct {
    method: Method,
    drop_body: bool,
};

/// Per RFC + common practice: 303 always -> GET+drop; 301/302 -> GET+drop for
/// a non-GET/HEAD (what browsers do); 307/308 preserve method and body.
pub fn rewriteMethod(method: Method, status: u16) MethodRewrite {
    switch (status) {
        307, 308 => return .{ .method = method, .drop_body = false },
        303 => return .{ .method = .GET, .drop_body = true },
        301, 302 => {
            if (method == .GET or method == .HEAD) return .{ .method = method, .drop_body = false };
            return .{ .method = .GET, .drop_body = true };
        },
        else => return .{ .method = method, .drop_body = false },
    }
}

/// A redirect from https to http is an insecure downgrade.
pub fn insecureDowngrade(from: Scheme, to: Scheme) bool {
    return from == .https and to == .http;
}

/// Resolve a Location value against the current URL into `out`, producing an
/// absolute URL string. Supports absolute, scheme-relative (//host/..),
/// absolute-path (/path), and relative-path forms. Returns the written slice.
pub fn resolveLocation(cur: url_mod.Url, cur_raw: []const u8, loc: []const u8, out: []u8) Error![]const u8 {
    if (loc.len == 0) return Error.BadResponse;

    // Absolute URL: has a scheme (contains "://").
    if (hasScheme(loc)) {
        return copyOut(out, loc);
    }

    // Scheme-relative: //host/path -> borrow current scheme.
    if (loc.len >= 2 and loc[0] == '/' and loc[1] == '/') {
        var w = Writer{ .b = out };
        try w.put(schemeStr(cur.scheme));
        try w.put(":");
        try w.put(loc);
        return out[0..w.n];
    }

    // Build scheme://host[:port] prefix from the current URL.
    var w = Writer{ .b = out };
    try w.put(schemeStr(cur.scheme));
    try w.put("://");
    try w.put(cur.host);
    if (cur.port != defaultPort(cur.scheme)) {
        try w.put(":");
        try w.putU16(cur.port);
    }

    if (loc[0] == '/') {
        // Absolute-path reference.
        try w.put(loc);
    } else {
        // Relative-path reference: replace the last path segment of cur.path_query.
        const base = basePath(cur.path_query);
        try w.put(base);
        try w.put(loc);
    }
    _ = cur_raw;
    return out[0..w.n];
}

const Writer = struct {
    b: []u8,
    n: usize = 0,
    fn put(self: *Writer, s: []const u8) Error!void {
        if (self.n + s.len > self.b.len) return Error.BufferTooSmall;
        @memcpy(self.b[self.n .. self.n + s.len], s);
        self.n += s.len;
    }
    fn putU16(self: *Writer, v: u16) Error!void {
        var tmp: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return Error.BufferTooSmall;
        try self.put(s);
    }
};

fn copyOut(out: []u8, s: []const u8) Error![]const u8 {
    if (s.len > out.len) return Error.BufferTooSmall;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

/// True if `s` begins with an http(s) scheme followed by "://".
fn hasScheme(s: []const u8) bool {
    const marker = "://";
    var i: usize = 0;
    while (i + marker.len <= s.len) : (i += 1) {
        if (s[i] == '/' or s[i] == '?' or s[i] == '#') return false; // path started first
        if (s[i] == marker[0] and s[i + 1] == marker[1] and s[i + 2] == marker[2]) return true;
    }
    return false;
}

fn schemeStr(s: Scheme) []const u8 {
    return if (s == .https) "https" else "http";
}

fn defaultPort(s: Scheme) u16 {
    return if (s == .https) 443 else 80;
}

/// Return the path up to and including the last '/' (the directory base),
/// dropping any query. For "/a/b?x" -> "/a/"; for "/" -> "/".
fn basePath(path_query: []const u8) []const u8 {
    // strip query
    var end = path_query.len;
    for (path_query, 0..) |c, i| { if (c == '?') { end = i; break; } }
    const path = path_query[0..end];
    var last_slash: usize = 0;
    var found = false;
    for (path, 0..) |c, i| { if (c == '/') { last_slash = i; found = true; } }
    if (!found) return "/";
    return path[0 .. last_slash + 1];
}

// Tests (inline, std.testing) -- redirect decisions
const testing = std.testing;

fn pu(raw: []const u8, hb: []u8) url_mod.Url {
    return url_mod.Url.parse(raw, hb) catch unreachable;
}

test "redirect: status classification" {
    try testing.expect(isRedirect(301));
    try testing.expect(isRedirect(302));
    try testing.expect(isRedirect(303));
    try testing.expect(isRedirect(307));
    try testing.expect(isRedirect(308));
    try testing.expect(!isRedirect(200));
    try testing.expect(!isRedirect(304));
    try testing.expect(!isRedirect(300));
}

test "redirect: method rewrite rules" {
    // 303 always GET + drop body
    const a = rewriteMethod(.POST, 303);
    try testing.expectEqual(Method.GET, a.method);
    try testing.expect(a.drop_body);
    // 301/302 on POST -> GET + drop
    const b = rewriteMethod(.POST, 302);
    try testing.expectEqual(Method.GET, b.method);
    try testing.expect(b.drop_body);
    // 301/302 on GET -> keep
    const c = rewriteMethod(.GET, 301);
    try testing.expectEqual(Method.GET, c.method);
    try testing.expect(!c.drop_body);
    // 307/308 preserve method + body
    const d = rewriteMethod(.POST, 307);
    try testing.expectEqual(Method.POST, d.method);
    try testing.expect(!d.drop_body);
    const e = rewriteMethod(.PUT, 308);
    try testing.expectEqual(Method.PUT, e.method);
    try testing.expect(!e.drop_body);
}

test "redirect: insecure downgrade detection" {
    try testing.expect(insecureDowngrade(.https, .http));
    try testing.expect(!insecureDowngrade(.http, .https));
    try testing.expect(!insecureDowngrade(.https, .https));
    try testing.expect(!insecureDowngrade(.http, .http));
}

test "redirect: resolve absolute Location" {
    var hb: [256]u8 = undefined;
    const cur = pu("https://a.com/x", &hb);
    var out: [256]u8 = undefined;
    const r = try resolveLocation(cur, "https://a.com/x", "https://b.com/y", &out);
    try testing.expectEqualSlices(u8, "https://b.com/y", r);
}

test "redirect: resolve absolute-path Location" {
    var hb: [256]u8 = undefined;
    const cur = pu("https://a.com/dir/page?q=1", &hb);
    var out: [256]u8 = undefined;
    const r = try resolveLocation(cur, "https://a.com/dir/page", "/other", &out);
    try testing.expectEqualSlices(u8, "https://a.com/other", r);
}

test "redirect: resolve absolute-path keeps non-default port" {
    var hb: [256]u8 = undefined;
    const cur = pu("https://a.com:8443/dir/", &hb);
    var out: [256]u8 = undefined;
    const r = try resolveLocation(cur, "x", "/p", &out);
    try testing.expectEqualSlices(u8, "https://a.com:8443/p", r);
}

test "redirect: resolve relative-path Location" {
    var hb: [256]u8 = undefined;
    const cur = pu("https://a.com/dir/page?q=1", &hb);
    var out: [256]u8 = undefined;
    const r = try resolveLocation(cur, "x", "next", &out);
    try testing.expectEqualSlices(u8, "https://a.com/dir/next", r);
}

test "redirect: resolve scheme-relative Location" {
    var hb: [256]u8 = undefined;
    const cur = pu("https://a.com/x", &hb);
    var out: [256]u8 = undefined;
    const r = try resolveLocation(cur, "x", "//cdn.com/asset", &out);
    try testing.expectEqualSlices(u8, "https://cdn.com/asset", r);
}

test "redirect: empty Location rejected" {
    var hb: [256]u8 = undefined;
    const cur = pu("https://a.com/", &hb);
    var out: [256]u8 = undefined;
    try testing.expectError(error.BadResponse, resolveLocation(cur, "x", "", &out));
}
