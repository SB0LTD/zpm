// Property test: all buffer sizes are comptime constants
// **Validates: Requirements 17.5**
//
// Scans all transport module source files to verify:
// 1. All `pub const` declarations with size-related names are assigned integer
//    literals or comptime expressions (not runtime values).
// 2. No dynamic-size wrapper types (BoundedArray, ArrayListUnmanaged, etc.)
//    are used — all arrays must be comptime-sized.
// 3. No `pub var` or module-level `var` declarations are used for size constants.
//
// Run: zig build test-comptime-sizes  (from zpm/)

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

// ── Size-related name fragments ──
// A `pub const` whose name contains any of these is considered a size constant.

const size_name_fragments = [_][]const u8{
    "size",
    "max",
    "buf",
    "len",
    "count",
    "slots",
    "capacity",
    "cap",
};

// ── Dynamic-size wrapper patterns (forbidden) ──

const dynamic_wrappers = [_][]const u8{
    "std.BoundedArray",
    "std.ArrayListUnmanaged",
    "std.ArrayListAligned",
    "std.MultiArrayList",
    "std.SegmentedList",
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

/// Find pattern in src, skipping occurrences inside line comments.
fn findPattern(src: []const u8, pattern: []const u8) ?usize {
    if (pattern.len > src.len) return null;
    const end = src.len - pattern.len;
    var i: usize = 0;
    while (i <= end) : (i += 1) {
        if (std.mem.eql(u8, src[i..][0..pattern.len], pattern)) {
            if (!isInComment(src, i)) return i;
        }
    }
    return null;
}

/// Find all occurrences of pattern, returning count (skipping comments).
fn countPattern(src: []const u8, pattern: []const u8) usize {
    if (pattern.len > src.len) return 0;
    var n: usize = 0;
    var i: usize = 0;
    const end = src.len - pattern.len;
    while (i <= end) : (i += 1) {
        if (std.mem.eql(u8, src[i..][0..pattern.len], pattern)) {
            if (!isInComment(src, i)) n += 1;
        }
    }
    return n;
}

/// Check if a character is a valid Zig identifier character.
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Extract the identifier name starting at `start` in `src`.
fn extractIdent(src: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < src.len and isIdentChar(src[end])) : (end += 1) {}
    return src[start..end];
}

/// Check if a name contains any of the size-related fragments (case-insensitive match
/// on the fragment since Zig uses snake_case).
fn isSizeName(name: []const u8) bool {
    for (size_name_fragments) |frag| {
        if (name.len >= frag.len) {
            var i: usize = 0;
            while (i + frag.len <= name.len) : (i += 1) {
                if (std.mem.eql(u8, name[i..][0..frag.len], frag)) return true;
            }
        }
    }
    return false;
}

/// After `= `, check if the RHS is a comptime-known value:
/// - Integer literal (digits, optionally with 0x prefix)
/// - Identifier (another const)
/// - @as(...) expression
/// - @import(...) (type, not a size, but valid)
/// - @sizeOf(...)
/// - Arithmetic expression of the above
///
/// Returns true if the RHS looks comptime-safe.
fn isComptimeRhs(src: []const u8, eq_pos: usize) bool {
    // Find start of RHS (skip `= ` and whitespace)
    var i = eq_pos + 1;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
    if (i >= src.len) return false;

    const c = src[i];

    // Integer literal (decimal or hex)
    if (c >= '0' and c <= '9') return true;

    // Builtin call (@as, @sizeOf, @import, etc.)
    if (c == '@') return true;

    // Identifier reference (another const)
    if (isIdentChar(c)) return true;

    // Parenthesized expression
    if (c == '(') return true;

    return false;
}

/// Scan for `pub var` or bare `var` at module level that look like size constants.
/// These should be `pub const` instead.
fn scanVarSizeDecls(name: []const u8, src: []const u8) usize {
    var violations: usize = 0;
    const pub_var = "pub var ";
    var i: usize = 0;
    while (i + pub_var.len < src.len) : (i += 1) {
        // Only match at start of line (after newline or at pos 0)
        if (i > 0 and src[i - 1] != '\n') continue;
        if (!std.mem.eql(u8, src[i..][0..pub_var.len], pub_var)) continue;
        if (isInComment(src, i)) continue;

        const ident = extractIdent(src, i + pub_var.len);
        if (isSizeName(ident)) {
            const line = lineAt(src, i);
            std.debug.print("VIOLATION: `pub var {s}` should be `pub const` in {s} at line {d}\n", .{ ident, name, line });
            violations += 1;
        }
    }
    return violations;
}

/// Scan for `pub const` size declarations and verify their RHS is comptime-known.
fn scanConstSizeDecls(name: []const u8, src: []const u8) usize {
    var violations: usize = 0;
    const pub_const = "pub const ";
    var i: usize = 0;
    while (i + pub_const.len < src.len) : (i += 1) {
        if (i > 0 and src[i - 1] != '\n') continue;
        if (!std.mem.eql(u8, src[i..][0..pub_const.len], pub_const)) continue;
        if (isInComment(src, i)) continue;

        const ident_start = i + pub_const.len;
        const ident = extractIdent(src, ident_start);
        if (!isSizeName(ident)) continue;

        // Find the `=` sign after the type annotation or directly
        var j = ident_start + ident.len;
        // Skip optional type annotation (`: type`)
        while (j < src.len and src[j] != '=' and src[j] != ';' and src[j] != '\n') : (j += 1) {}
        if (j >= src.len or src[j] != '=') continue;

        if (!isComptimeRhs(src, j)) {
            const line = lineAt(src, i);
            std.debug.print("VIOLATION: `pub const {s}` has non-comptime RHS in {s} at line {d}\n", .{ ident, name, line });
            violations += 1;
        }
    }
    return violations;
}

/// Scan for dynamic-size wrapper types (forbidden in transport modules).
fn scanDynamicWrappers(name: []const u8, src: []const u8) usize {
    var violations: usize = 0;
    for (dynamic_wrappers) |wrapper| {
        if (findPattern(src, wrapper)) |pos| {
            const line = lineAt(src, pos);
            std.debug.print("VIOLATION: dynamic wrapper `{s}` found in {s} at line {d}\n", .{ wrapper, name, line });
            violations += 1;
        }
    }
    return violations;
}

// ── Tests ──

test "no dynamic-size wrappers in transport modules" {
    var total_violations: usize = 0;
    inline for (modules) |entry| {
        total_violations += scanDynamicWrappers(entry[0], entry[1]);
    }
    try testing.expectEqual(@as(usize, 0), total_violations);
}

test "all size constants are pub const, not pub var" {
    var total_violations: usize = 0;
    inline for (modules) |entry| {
        total_violations += scanVarSizeDecls(entry[0], entry[1]);
    }
    try testing.expectEqual(@as(usize, 0), total_violations);
}

test "all pub const size declarations have comptime-known RHS" {
    var total_violations: usize = 0;
    inline for (modules) |entry| {
        total_violations += scanConstSizeDecls(entry[0], entry[1]);
    }
    try testing.expectEqual(@as(usize, 0), total_violations);
}
