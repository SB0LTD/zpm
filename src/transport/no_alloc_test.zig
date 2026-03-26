// Property test: no allocator usage in transport modules
// **Validates: Requirements 17.1**
//
// Scans all transport module source files for forbidden patterns that indicate
// allocator usage. The zero-allocator memory model requires all storage to be
// stack-allocated, comptime-sized arrays, fixed-size ring buffers, or static
// module-level variables.
//
// Run: zig test src/transport/no_alloc_test.zig  (from zpm/)

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

test "no allocator usage — udp.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("udp.zig", @embedFile("udp.zig")));
}

test "no allocator usage — packet.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("packet.zig", @embedFile("packet.zig")));
}

test "no allocator usage — crypto.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("crypto.zig", @embedFile("crypto.zig")));
}

test "no allocator usage — conn.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("conn.zig", @embedFile("conn.zig")));
}

test "no allocator usage — recovery.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("recovery.zig", @embedFile("recovery.zig")));
}

test "no allocator usage — streams.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("streams.zig", @embedFile("streams.zig")));
}

test "no allocator usage — datagram.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("datagram.zig", @embedFile("datagram.zig")));
}

test "no allocator usage — scheduler.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("scheduler.zig", @embedFile("scheduler.zig")));
}

test "no allocator usage — telemetry.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("telemetry.zig", @embedFile("telemetry.zig")));
}

test "no allocator usage — appmap.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("appmap.zig", @embedFile("appmap.zig")));
}

test "no allocator usage — root.zig" {
    try testing.expectEqual(@as(usize, 0), scanSource("root.zig", @embedFile("root.zig")));
}
