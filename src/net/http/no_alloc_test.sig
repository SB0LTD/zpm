// Property test: the @zpm/http modules use no allocator (Req 2.1, 2.4; 15.2).
//
// Modeled on src/transport/no_alloc_test.sig: scan each module source for
// forbidden allocator patterns (all storage must be caller-owned slices,
// comptime-sized arrays, or static module vars). Also asserts the bounded
// MAX_* capacity constants exist and that the public entry points take no
// allocator parameter.

const std = @import("std");
const testing = std.testing;

const request = @import("request.sig");
const response = @import("response.sig");
const cookie = @import("cookie.sig");

const forbidden_patterns = [_][]const u8{
    "Allocator",
    ".alloc(",
    ".free(",
    ".create(",
    ".destroy(",
    "std.heap",
    "std.ArrayList",
    "std.HashMap",
    "std.AutoHashMap",
};

fn isInComment(src: []const u8, pos: usize) bool {
    var i = pos;
    while (i >= 2) : (i -= 1) {
        if (src[i - 1] == '\n') return false;
        if (src[i - 1] == '/' and src[i - 2] == '/') return true;
    }
    return false;
}

fn lineAt(src: []const u8, pos: usize) usize {
    var line: usize = 1;
    for (src[0..pos]) |c| { if (c == '\n') line += 1; }
    return line;
}

fn findForbidden(src: []const u8, pattern: []const u8) ?usize {
    if (pattern.len > src.len) return null;
    const end = src.len - pattern.len;
    var i: usize = 0;
    while (i <= end) : (i += 1) {
        if (src[i] == pattern[0]) {
            if (std.mem.eql(u8, src[i..][0..pattern.len], pattern)) {
                if (!isInComment(src, i)) return i;
            }
        }
    }
    return null;
}

fn scanSource(name: []const u8, content: []const u8) usize {
    var violations: usize = 0;
    for (forbidden_patterns) |pattern| {
        if (findForbidden(content, pattern)) |pos| {
            const line = lineAt(content, pos);
            std.debug.print("VIOLATION: {s} in {s} at line {d}\n", .{ pattern, name, line });
            violations += 1;
        }
    }
    return violations;
}

test "no allocator usage -- errors.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("errors.sig", @embedFile("errors.sig")));
}

test "no allocator usage -- url.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("url.sig", @embedFile("url.sig")));
}

test "no allocator usage -- transport.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("transport.sig", @embedFile("transport.sig")));
}

test "no allocator usage -- cookie.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("cookie.sig", @embedFile("cookie.sig")));
}

test "no allocator usage -- request.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("request.sig", @embedFile("request.sig")));
}

test "no allocator usage -- response.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("response.sig", @embedFile("response.sig")));
}

test "no allocator usage -- body.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("body.sig", @embedFile("body.sig")));
}

test "no allocator usage -- protocol.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("protocol.sig", @embedFile("protocol.sig")));
}

test "no allocator usage -- retry.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("retry.sig", @embedFile("retry.sig")));
}

test "no allocator usage -- redirect.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("redirect.sig", @embedFile("redirect.sig")));
}

test "bounded MAX_* capacity constants exist" {
    try testing.expect(request.MAX_REQUEST_HEADER > 0);
    try testing.expect(request.MAX_EXTRA_HEADERS > 0);
    try testing.expect(response.MAX_RESP_HEADERS > 0);
    try testing.expect(cookie.MAX_COOKIES >= 64);
}
