// Property test: transport modules are domain-agnostic (except appmap)
// **Validates: Requirements 18.2**
//
// Scans all transport module source files EXCEPT appmap.zig for forbidden
// domain-specific identifiers. The QUIC transport core is a generic, reusable
// transport that knows nothing about packages, registries, or zpm semantics.
// Only appmap.zig bridges zpm-specific operations to QUIC lanes.
//
// Forbidden identifiers: registry, package, manifest, zpm_dep, publish,
// resolve, search, tarball
//
// Run: zig build test-domain-agnostic  (from zpm/)

const std = @import("std");
const testing = std.testing;

// ── Module sources loaded at comptime via @embedFile ──
// Every transport .zig file EXCEPT appmap.zig (the sole zpm-aware bridge).

const modules = .{
    .{ "udp.zig", @embedFile("udp.zig") },
    .{ "packet.zig", @embedFile("packet.zig") },
    .{ "crypto.zig", @embedFile("crypto.zig") },
    .{ "conn.zig", @embedFile("conn.zig") },
    .{ "recovery.zig", @embedFile("recovery.zig") },
    .{ "streams.zig", @embedFile("streams.zig") },
    .{ "datagram.zig", @embedFile("datagram.zig") },
    .{ "scheduler.zig", @embedFile("scheduler.zig") },
    .{ "telemetry.zig", @embedFile("telemetry.zig") },
    .{ "root.zig", @embedFile("root.zig") },
};

// ── Forbidden domain-specific identifiers ──

const forbidden_identifiers = [_][]const u8{
    "registry",
    "package",
    "manifest",
    "zpm_dep",
    "publish",
    "resolve",
    "search",
    "tarball",
};

// ── Helpers ──

/// Check if position is inside a line comment (// ...) on the same line.
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

/// Check if the character is a valid Zig identifier character (alphanumeric or _).
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Find a forbidden identifier as a whole word (not a substring of a larger
/// identifier). Skips occurrences inside // line comments.
/// Returns the position of the first non-comment match, or null.
fn findForbidden(src: []const u8, pattern: []const u8) ?usize {
    if (pattern.len > src.len) return null;
    const end = src.len - pattern.len;
    var i: usize = 0;
    while (i <= end) : (i += 1) {
        if (!std.mem.eql(u8, src[i..][0..pattern.len], pattern)) continue;

        // Word-boundary check: must not be part of a larger identifier
        if (i > 0 and isIdentChar(src[i - 1])) continue;
        if (i + pattern.len < src.len and isIdentChar(src[i + pattern.len])) continue;

        // Skip if inside a line comment
        if (isInComment(src, i)) continue;

        return i;
    }
    return null;
}

/// Scan a single module source for all forbidden identifiers.
/// Returns the number of violations found.
fn scanSource(name: []const u8, content: []const u8) usize {
    var violations: usize = 0;
    for (forbidden_identifiers) |pattern| {
        // Scan for all occurrences, not just the first
        var offset: usize = 0;
        while (offset + pattern.len <= content.len) {
            if (findForbidden(content[offset..], pattern)) |rel_pos| {
                const abs_pos = offset + rel_pos;
                const line = lineAt(content, abs_pos);
                std.debug.print("VIOLATION: \"{s}\" found in {s} at line {d}\n", .{ pattern, name, line });
                violations += 1;
                offset = abs_pos + pattern.len;
            } else break;
        }
    }
    return violations;
}

// ── Tests ──

test "transport core modules contain no domain-specific identifiers" {
    var total_violations: usize = 0;
    inline for (modules) |entry| {
        total_violations += scanSource(entry[0], entry[1]);
    }
    try testing.expectEqual(@as(usize, 0), total_violations);
}
