// Cookie jar for the pure-Sig HTTP client.
//
// Migrated verbatim (semantics-preserving) from platform/http_session.sig so
// the YouTube/BotGuard session flow carries over with no behavioral change:
// a fixed-size name=value store with set/get/clear/count/serialize and raw
// Set-Cookie absorption. Zero allocation; all storage is inline.
//
// The only addition over the original is absorbFromHeaders(*const HeaderSet),
// a thin wrapper added in the response-parser step that drives the same set()
// from the parsed response instead of a WinHTTP raw-header re-query.

const std = @import("std");

/// Default browser User-Agent. Same string the old http_session used.
pub const CHROME_UA: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

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
            out[pos] = '=';  pos += 1;
            @memcpy(out[pos .. pos + c.value_len], c.value[0..c.value_len]);
            pos += c.value_len;
            first = false;
        }
        return pos;
    }

    /// Parse the raw response headers (CRLF-separated) and absorb every
    /// `Set-Cookie:` line into the jar. Only name=value is kept (attributes
    /// like Path/Domain/Expires/Secure are dropped - we send the jar back to
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

// -- helpers (verbatim from http_session) --

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

// Tests (inline, std.testing) -- CookieJar
const testing = std.testing;

test "cookie: set/get and replace" {
    var jar = CookieJar.init();
    jar.set("a", "1");
    jar.set("b", "2");
    try testing.expectEqualSlices(u8, "1", jar.get("a").?);
    try testing.expectEqualSlices(u8, "2", jar.get("b").?);
    try testing.expectEqual(@as(usize, 2), jar.count());
    jar.set("a", "99"); // replace
    try testing.expectEqualSlices(u8, "99", jar.get("a").?);
    try testing.expectEqual(@as(usize, 2), jar.count());
    try testing.expect(jar.get("missing") == null);
}

test "cookie: serialize produces a=1; b=2" {
    var jar = CookieJar.init();
    jar.set("a", "1");
    jar.set("b", "2");
    var out: [64]u8 = undefined;
    const n = jar.serialize(&out);
    try testing.expectEqualSlices(u8, "a=1; b=2", out[0..n]);
}

test "cookie: empty jar serializes to nothing" {
    var jar = CookieJar.init();
    var out: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), jar.serialize(&out));
}

test "cookie: absorb multiple Set-Cookie lines" {
    var jar = CookieJar.init();
    const headers = "HTTP/1.1 200 OK\r\nSet-Cookie: VISITOR=abc; Path=/; Secure\r\nSet-Cookie: YSC=def; HttpOnly\r\nContent-Type: text/html\r\n\r\n";
    jar.absorbRawHeaders(headers);
    try testing.expectEqualSlices(u8, "abc", jar.get("VISITOR").?);
    try testing.expectEqualSlices(u8, "def", jar.get("YSC").?);
    try testing.expectEqual(@as(usize, 2), jar.count());
}

test "cookie: case-insensitive Set-Cookie header name" {
    var jar = CookieJar.init();
    jar.absorbRawHeaders("set-COOKIE: x=1\r\n");
    try testing.expectEqualSlices(u8, "1", jar.get("x").?);
}

test "cookie: long __Secure value bounded not overflowed" {
    var jar = CookieJar.init();
    var big: [2000]u8 = undefined;
    @memset(&big, 'z');
    jar.set("__Secure-TOK", &big);
    const v = jar.get("__Secure-TOK").?;
    try testing.expectEqual(@as(usize, 768), v.len); // clamped to COOKIE_VALUE_MAX
}

test "cookie: jar overflow is bounded" {
    var jar = CookieJar.init();
    var namebuf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_COOKIES + 10) : (i += 1) {
        const nm = std.fmt.bufPrint(&namebuf, "c{d}", .{i}) catch unreachable;
        jar.set(nm, "v");
    }
    try testing.expectEqual(MAX_COOKIES, jar.count());
}
