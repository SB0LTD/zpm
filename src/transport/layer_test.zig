// Property test: transport module layer hierarchy
// **Validates: Requirements 18.2**
//
// Scans all transport module source files and verifies they only @import from
// allowed layers:
//   - "std", "builtin" (Zig built-ins)
//   - Layer 0 (core): "math", "json", "core"
//   - Layer 1 (platform): "win32", "crypto", "timer", "file_io", "logging", "seqlock"
//   - Layer 1 (transport siblings): "udp", "packet", "transport_crypto", "recovery",
//     "streams", "datagram", "scheduler", "conn", "telemetry", "appmap"
//   - Relative file imports (starting with "./" or containing ".zig")
//
// Forbidden imports:
//   - Layer 2 (render): "render", "color", "primitives", "text", "icon", "gl"
//   - Layer 3-4 (widgets): anything widget-related
//   - Layer 5 (app): "app", "main"
//   - Platform I/O that transport shouldn't use: "window", "input", "threading",
//     "http", "screenshot", "png", "mcp"
//
// Run: zig build test-layer  (from zpm/)

const std = @import("std");
const testing = std.testing;

// ── Module sources loaded at comptime via @embedFile ──

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
    .{ "appmap.zig", @embedFile("appmap.zig") },
    .{ "root.zig", @embedFile("root.zig") },
};

// ── Allowed import names ──

const allowed_imports = [_][]const u8{
    // Zig built-ins
    "std",
    "builtin",
    // Layer 0 (core)
    "math",
    "json",
    "core",
    // Layer 1 (platform)
    "win32",
    "crypto",
    "timer",
    "file_io",
    "logging",
    "seqlock",
    // Layer 1 (transport siblings)
    "udp",
    "packet",
    "transport_crypto",
    "recovery",
    "streams",
    "datagram",
    "scheduler",
    "conn",
    "telemetry",
    "appmap",
};

// ── Helpers ──

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

/// Check if an import name is a relative file import (starts with "./" or
/// contains ".zig"), which is allowed for intra-module file references.
fn isRelativeImport(name: []const u8) bool {
    if (name.len >= 2 and name[0] == '.' and (name[1] == '/' or name[1] == '.')) return true;
    // Check for ".zig" anywhere in the name
    if (name.len >= 4) {
        var i: usize = 0;
        while (i + 4 <= name.len) : (i += 1) {
            if (std.mem.eql(u8, name[i..][0..4], ".zig")) return true;
        }
    }
    return false;
}

/// Check if an import name is in the allowed list.
fn isAllowedImport(name: []const u8) bool {
    // Relative file imports are always allowed
    if (isRelativeImport(name)) return true;

    for (allowed_imports) |allowed| {
        if (name.len == allowed.len and std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

/// Extract all @import("...") names from source and check each against the
/// allowed list. Returns the number of violations found.
fn scanImports(module_name: []const u8, src: []const u8) usize {
    var violations: usize = 0;
    const pattern = "@import(\"";
    const pattern_len = pattern.len;

    if (src.len < pattern_len) return 0;

    var i: usize = 0;
    const end = src.len - pattern_len;
    while (i <= end) : (i += 1) {
        if (!std.mem.eql(u8, src[i..][0..pattern_len], pattern)) continue;
        if (isInComment(src, i)) continue;

        // Extract the import name between the quotes
        const name_start = i + pattern_len;
        var name_end = name_start;
        while (name_end < src.len and src[name_end] != '"') : (name_end += 1) {}
        if (name_end >= src.len) continue;

        const import_name = src[name_start..name_end];
        if (import_name.len == 0) continue;

        if (!isAllowedImport(import_name)) {
            const line = lineAt(src, i);
            std.debug.print("VIOLATION: forbidden import \"{s}\" in {s} at line {d}\n", .{
                import_name, module_name, line,
            });
            violations += 1;
        }
    }
    return violations;
}

// ── Tests ──

test "transport modules only import from allowed layers" {
    var total_violations: usize = 0;
    inline for (modules) |entry| {
        total_violations += scanImports(entry[0], entry[1]);
    }
    try testing.expectEqual(@as(usize, 0), total_violations);
}
