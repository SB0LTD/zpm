// URL parsing for HTTP client.
//
// Parses scheme://host[:port]/path?query into components, supporting:
// - Default ports: https=443, http=80
// - Bracketed IPv6 hosts: [::1], [fe80::1]
// - Default path: / when omitted
// - Query strings preserved verbatim
//
// Rejects malformed URLs:
// - Missing scheme
// - Empty host
// - Host too long (>255 bytes, leaves room for null terminator in buffers)

const std = @import("std");
const errors = @import("errors.sig");

// Canonical Scheme/Error live in errors.sig; re-export Scheme so existing
// url.Scheme references keep working.
pub const Scheme = errors.Scheme;
const Error = error{ InvalidUrl };

pub const Url = struct {
    scheme: Scheme,
    host: []const u8,     // slice into caller/opts storage
    port: u16,            // defaulted: https=443, http=80
    path_query: []const u8, // "/path?query", defaults to "/"

    const MAX_HOST = 256;  // bytes, leaves room for null terminator in buffers

    /// Parse a raw URL string into components.
    /// Copies the host into caller-provided host_buf (must be >= MAX_HOST).
    /// Returns InvalidUrl for malformed input.
    pub fn parse(raw: []const u8, host_buf: []u8) Error!Url {
        var idx: usize = 0;

        // 1. Parse scheme
        const scheme_end = indexOf(raw, "://", idx);
        if (scheme_end == null) return error.InvalidUrl;
        const scheme_start: usize = 0;
        const scheme_slice = raw[scheme_start..scheme_end.?];

        const scheme: Scheme = if (std.ascii.eqlIgnoreCase(scheme_slice, "https"))
            Scheme.https
        else if (std.ascii.eqlIgnoreCase(scheme_slice, "http"))
            Scheme.http
        else
            return error.InvalidUrl;

        idx = scheme_end.? + 3; // skip "://"

        // 2. Parse host (possibly bracketed IPv6)
        const host_start = idx;
        var host_end: usize = raw.len;

        // Find end of authority (start of path)
        // Look for '/', '?', or end of string
        var i: usize = idx;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (c == '/' or c == '?') {
                host_end = i;
                break;
            }
        }

        const host_raw = raw[host_start..host_end];
        if (host_raw.len == 0) return error.InvalidUrl;
        if (host_raw.len >= host_buf.len) return error.InvalidUrl;

        // Copy host to buffer
        @memcpy(host_buf[0..host_raw.len], host_raw);

        // 3. Handle IPv6 bracketed addresses
        var host: []const u8 = host_buf[0..host_raw.len];
        var port_str: ?[]const u8 = null;

        if (host_raw[0] == '[') {
            // IPv6 bracketed address: [fe80::1] or [fe80::1]:8080
            const close_bracket = indexOfChar(host_raw, ']', 1);
            if (close_bracket == null) return error.InvalidUrl;

            // Check for port after closing bracket
            const after_close = close_bracket.? + 1;
            if (after_close < host_raw.len) {
                if (host_raw[after_close] == ':') {
                    port_str = host_raw[after_close + 1 ..];
                } else if (host_raw[after_close] != 0) {
                    // Invalid character after closing bracket
                    return error.InvalidUrl;
                }
            }

            // Extract just the IPv6 part (without brackets) for the host field
            host = host_buf[1..close_bracket.?];
        } else {
            // Regular IPv4 or hostname: example.com or example.com:8080
            const colon = indexOfChar(host_raw, ':', 0);
            if (colon != null) {
                port_str = host_raw[colon.? + 1 ..];
                host = host_buf[0..colon.?];
            }
        }

        if (host.len == 0) return error.InvalidUrl;

        // 4. Parse port (if present)
        var port: u16 = undefined;
        if (scheme == .https) {
            port = 443;
        } else {
            port = 80;
        }

        if (port_str != null) {
            // Parse port number
            if (port_str.?.len == 0) return error.InvalidUrl;
            
            // Port must be numeric
            var port_val: u32 = 0;
            for (port_str.?) |c| {
                if (c < '0' or c > '9') return error.InvalidUrl;
                port_val = port_val * 10 + @as(u32, c - '0');
                if (port_val > 65535) return error.InvalidUrl;
            }
            port = @intCast(port_val);
        }

        // 5. Parse path and query. host_end marks where the authority stopped;
        //    everything from there is the path+query. Default to "/" when absent,
        //    and prepend "/" when the URL jumps straight to a query ("?...").
        var path_query: []const u8 = "/"; // default
        if (host_end < raw.len) {
            if (raw[host_end] == '?') {
                const qlen = raw.len - host_end;
                if (qlen + 1 > host_buf.len - host_raw.len) return error.InvalidUrl;
                const base = host_raw.len;
                host_buf[base] = '/';
                @memcpy(host_buf[base + 1 ..][0..qlen], raw[host_end..]);
                path_query = host_buf[base .. base + 1 + qlen];
            } else {
                path_query = raw[host_end..];
            }
        }

        return Url{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path_query = path_query,
        };
    }
};

/// Find substring in string, return index or null
fn indexOf(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len) return null;

    var i: usize = start;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var found = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (haystack[i + j] != needle[j]) {
                found = false;
                break;
            }
        }
        if (found) return i;
    }
    return null;
}

/// Find character in string, return index or null
fn indexOfChar(haystack: []const u8, c: u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    var i: usize = start;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == c) return i;
    }
    return null;
}

// Tests (inline, std.testing) -- URL parser
const testing = std.testing;

test "url: https default port" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("https://example.com/path?query", &host_buf);
    try testing.expectEqual(Scheme.https, parsed.scheme);
    try testing.expectEqual(@as(u16, 443), parsed.port);
    try testing.expectEqualSlices(u8, "example.com", parsed.host);
    try testing.expectEqualSlices(u8, "/path?query", parsed.path_query);
}

test "url: http explicit default port" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("http://example.com:80/path", &host_buf);
    try testing.expectEqual(Scheme.http, parsed.scheme);
    try testing.expectEqual(@as(u16, 80), parsed.port);
    try testing.expectEqualSlices(u8, "example.com", parsed.host);
    try testing.expectEqualSlices(u8, "/path", parsed.path_query);
}

test "url: explicit non-default port" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("https://example.com:8443/api", &host_buf);
    try testing.expectEqual(@as(u16, 8443), parsed.port);
    try testing.expectEqualSlices(u8, "example.com", parsed.host);
    try testing.expectEqualSlices(u8, "/api", parsed.path_query);
}

test "url: query preserved" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("https://example.com/path?key=value&foo=bar", &host_buf);
    try testing.expectEqualSlices(u8, "/path?key=value&foo=bar", parsed.path_query);
}

test "url: missing scheme rejected" {
    var host_buf: [256]u8 = undefined;
    try testing.expectError(error.InvalidUrl, Url.parse("example.com/path", &host_buf));
}

test "url: empty host rejected" {
    var host_buf: [256]u8 = undefined;
    try testing.expectError(error.InvalidUrl, Url.parse("https:///path", &host_buf));
}

test "url: over-long host rejected" {
    var host_buf: [256]u8 = undefined;
    var raw_buf: [512]u8 = undefined;
    @memcpy(raw_buf[0..8], "https://");
    var i: usize = 8;
    while (i < 300) : (i += 1) raw_buf[i] = 'a';
    @memcpy(raw_buf[i..][0..6], "/path/");
    try testing.expectError(error.InvalidUrl, Url.parse(raw_buf[0 .. i + 6], &host_buf));
}

test "url: IPv6 brackets with port" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("https://[::1]:8080/path", &host_buf);
    try testing.expectEqual(@as(u16, 8080), parsed.port);
    try testing.expectEqualSlices(u8, "::1", parsed.host);
    try testing.expectEqualSlices(u8, "/path", parsed.path_query);
}

test "url: IPv6 without port uses default" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("http://[fe80::1]/api", &host_buf);
    try testing.expectEqual(@as(u16, 80), parsed.port);
    try testing.expectEqualSlices(u8, "fe80::1", parsed.host);
}

test "url: path-less defaults to slash" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("https://example.com", &host_buf);
    try testing.expectEqual(@as(u16, 443), parsed.port);
    try testing.expectEqualSlices(u8, "example.com", parsed.host);
    try testing.expectEqualSlices(u8, "/", parsed.path_query);
}

test "url: path-less with query" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("http://example.com?query=1", &host_buf);
    try testing.expectEqualSlices(u8, "example.com", parsed.host);
    try testing.expectEqualSlices(u8, "/?query=1", parsed.path_query);
}

test "url: case-insensitive scheme" {
    var host_buf: [256]u8 = undefined;
    const parsed = try Url.parse("HTTPS://Example.COM", &host_buf);
    try testing.expectEqual(Scheme.https, parsed.scheme);
    try testing.expectEqualSlices(u8, "Example.COM", parsed.host);
}

test "url: assorted malformed inputs rejected" {
    const bad = [_][]const u8{
        "no-scheme.com/path",
        "://missing-scheme.com/path",
        "http://",
        "https://",
        "ftp://example.com",
        "http://example.com:99999",
        "http://example.com:abc",
    };
    for (bad) |raw| {
        var host_buf: [256]u8 = undefined;
        try testing.expectError(error.InvalidUrl, Url.parse(raw, &host_buf));
    }
}

