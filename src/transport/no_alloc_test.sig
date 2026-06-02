// Property test: no allocator usage in transport modules
// **Validates: Requirements 17.1**
//
// Scans all transport module source files for forbidden patterns that indicate
// allocator usage. The zero-allocator memory model requires all storage to be
// stack-allocated, comptime-sized arrays, fixed-size ring buffers, or static
// module-level variables.
//
// Run: zig test src/transport/no_alloc_test.sig  (from zpm/)

const std = @import("std");
const testing = std.testing;

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

/// Check if position is inside a line comment on the same line.
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
    for (src[0..pos]) |c| {
        if (c == '\n') line += 1;
    }
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
            std.debug.print("VIOLATION: \"{s}\" found in {s} at line {d}\n", .{ pattern, name, line });
            violations += 1;
        }
    }
    return violations;
}

test "no allocator usage — udp.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("udp.sig", @embedFile("udp.sig")));
}

test "no allocator usage — packet.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("packet.sig", @embedFile("packet.sig")));
}

test "no allocator usage — crypto.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("crypto.sig", @embedFile("crypto.sig")));
}

test "no allocator usage — conn.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("conn.sig", @embedFile("conn.sig")));
}

test "no allocator usage — recovery.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("recovery.sig", @embedFile("recovery.sig")));
}

test "no allocator usage — streams.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("streams.sig", @embedFile("streams.sig")));
}

test "no allocator usage — datagram.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("datagram.sig", @embedFile("datagram.sig")));
}

test "no allocator usage — scheduler.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("scheduler.sig", @embedFile("scheduler.sig")));
}

test "no allocator usage — telemetry.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("telemetry.sig", @embedFile("telemetry.sig")));
}

test "no allocator usage — appmap.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("appmap.sig", @embedFile("appmap.sig")));
}

test "no allocator usage — root.sig" {
    try testing.expectEqual(@as(usize, 0), scanSource("root.sig", @embedFile("root.sig")));
}
