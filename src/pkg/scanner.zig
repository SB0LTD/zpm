// Layer 0 — Source file scanner for zpm package protocol.
// No I/O, no allocator. Operates on byte slices passed by the caller.
//
// Scans .zig source files for constraint violations (std.io/fs imports,
// allocator params) and extracts module/syslib declarations from build.zig.

const validator = @import("validator.zig");

// ── Source File Scanning ──

/// Scan a single .zig source file for constraint violations.
/// Returns a SourceScanResult with flags for std.io/fs imports and allocator params.
pub fn scanSourceFile(file_path: []const u8, content: []const u8) validator.SourceScanResult {
    return .{
        .file_path = file_path,
        .has_std_io_import = containsPattern(content, "@import(\"std\").io") or containsPattern(content, "std.io"),
        .has_std_fs_import = containsPattern(content, "@import(\"std\").fs") or containsPattern(content, "std.fs"),
        .has_allocator_param = containsAllocatorParam(content),
    };
}

// ── Build.zig Extraction ──

/// Extract module names from build.zig content.
/// Looks for patterns like: addModule("name", ...) and addImport("name", ...)
/// Returns the number of names written to `out`.
pub fn extractModuleNames(build_content: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    const patterns = [_][]const u8{ "addModule(\"", "addImport(\"" };

    for (patterns) |pattern| {
        var pos: usize = 0;
        while (pos < build_content.len) {
            if (findPattern(build_content, pos, pattern)) |start| {
                const name_start = start + pattern.len;
                if (findQuoteEnd(build_content, name_start)) |name_end| {
                    if (count < out.len) {
                        out[count] = build_content[name_start..name_end];
                        count += 1;
                    }
                    pos = name_end + 1;
                } else {
                    pos = name_start;
                }
            } else {
                break;
            }
        }
    }

    return dedup(out, count);
}

/// Extract system library names from build.zig content.
/// Looks for patterns like: linkSystemLibrary("name", ...)
/// Returns the number of names written to `out`.
pub fn extractSystemLibraries(build_content: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    const pattern = "linkSystemLibrary(\"";
    var pos: usize = 0;

    while (pos < build_content.len) {
        if (findPattern(build_content, pos, pattern)) |start| {
            const name_start = start + pattern.len;
            if (findQuoteEnd(build_content, name_start)) |name_end| {
                if (count < out.len) {
                    out[count] = build_content[name_start..name_end];
                    count += 1;
                }
                pos = name_end + 1;
            } else {
                pos = name_start;
            }
        } else {
            break;
        }
    }

    return dedup(out, count);
}

// ── Helpers ──

/// Check if `haystack` contains `needle` anywhere.
fn containsPattern(haystack: []const u8, needle: []const u8) bool {
    return findPattern(haystack, 0, needle) != null;
}

/// Find the first occurrence of `needle` in `haystack` starting at `from`.
fn findPattern(haystack: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    if (haystack.len < needle.len) return null;
    if (from > haystack.len - needle.len) return null;

    var i = from;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (sliceEql(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

/// Find the closing quote position starting from `start`.
fn findQuoteEnd(content: []const u8, start: usize) ?usize {
    var i = start;
    while (i < content.len) : (i += 1) {
        if (content[i] == '"') return i;
        if (content[i] == '\\') {
            i += 1; // skip escaped char
        }
    }
    return null;
}

/// Check if content contains `std.mem.Allocator` in a pub fn signature.
/// Scans line-by-line: for lines starting with `pub fn` (after optional whitespace),
/// checks if the line contains `std.mem.Allocator`.
fn containsAllocatorParam(content: []const u8) bool {
    const alloc_pattern = "std.mem.Allocator";
    var line_start: usize = 0;

    while (line_start < content.len) {
        // Find end of current line
        var line_end = line_start;
        while (line_end < content.len and content[line_end] != '\n') : (line_end += 1) {}

        const line = content[line_start..line_end];

        // Check if this line starts with `pub fn` (after whitespace)
        const trimmed = trimLeft(line);
        if (startsWith(trimmed, "pub fn")) {
            // Check if this line (the signature) contains std.mem.Allocator
            if (containsPattern(line, alloc_pattern)) {
                return true;
            }
        }

        line_start = if (line_end < content.len) line_end + 1 else content.len;
    }

    return false;
}

/// Trim leading whitespace.
fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

/// Check if `s` starts with `prefix`.
fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return sliceEql(s[0..prefix.len], prefix);
}

/// Byte-level slice equality.
fn sliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

/// Deduplicate entries in-place. Returns new count.
fn dedup(items: [][]const u8, count: usize) usize {
    if (count <= 1) return count;
    var write: usize = 1;
    var read: usize = 1;
    while (read < count) : (read += 1) {
        var is_dup = false;
        for (items[0..write]) |existing| {
            if (sliceEql(items[read], existing)) {
                is_dup = true;
                break;
            }
        }
        if (!is_dup) {
            items[write] = items[read];
            write += 1;
        }
    }
    return write;
}

// ── Tests ──

const std = @import("std");
const testing = std.testing;

// ── scanSourceFile tests ──

test "scanSourceFile: detects @import(\"std\").io" {
    const content = "const std = @import(\"std\").io;\n";
    const result = scanSourceFile("src/foo.zig", content);
    try testing.expect(result.has_std_io_import);
    try testing.expect(!result.has_std_fs_import);
    try testing.expect(!result.has_allocator_param);
    try testing.expectEqualStrings("src/foo.zig", result.file_path);
}

test "scanSourceFile: detects std.io usage" {
    const content = "const writer = std.io.getStdOut();\n";
    const result = scanSourceFile("src/bar.zig", content);
    try testing.expect(result.has_std_io_import);
}

test "scanSourceFile: detects @import(\"std\").fs" {
    const content = "const fs = @import(\"std\").fs;\n";
    const result = scanSourceFile("src/fs.zig", content);
    try testing.expect(result.has_std_fs_import);
}

test "scanSourceFile: detects std.fs usage" {
    const content = "const dir = std.fs.cwd();\n";
    const result = scanSourceFile("src/dir.zig", content);
    try testing.expect(result.has_std_fs_import);
}

test "scanSourceFile: detects allocator param in pub fn" {
    const content = "pub fn init(allocator: std.mem.Allocator) void {}\n";
    const result = scanSourceFile("src/alloc.zig", content);
    try testing.expect(result.has_allocator_param);
}

test "scanSourceFile: detects allocator param with leading whitespace" {
    const content = "    pub fn create(alloc: std.mem.Allocator, n: usize) !void {}\n";
    const result = scanSourceFile("src/alloc2.zig", content);
    try testing.expect(result.has_allocator_param);
}

test "scanSourceFile: ignores allocator in non-pub fn" {
    const content = "fn helper(allocator: std.mem.Allocator) void {}\n";
    const result = scanSourceFile("src/priv.zig", content);
    try testing.expect(!result.has_allocator_param);
}

test "scanSourceFile: clean file returns all false" {
    const content =
        \\const math = @import("math");
        \\
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    const result = scanSourceFile("src/clean.zig", content);
    try testing.expect(!result.has_std_io_import);
    try testing.expect(!result.has_std_fs_import);
    try testing.expect(!result.has_allocator_param);
}

test "scanSourceFile: empty content returns all false" {
    const result = scanSourceFile("src/empty.zig", "");
    try testing.expect(!result.has_std_io_import);
    try testing.expect(!result.has_std_fs_import);
    try testing.expect(!result.has_allocator_param);
}

test "scanSourceFile: detects multiple violations" {
    const content =
        \\const io = @import("std").io;
        \\const fs = std.fs;
        \\
        \\pub fn doStuff(alloc: std.mem.Allocator) void {}
    ;
    const result = scanSourceFile("src/multi.zig", content);
    try testing.expect(result.has_std_io_import);
    try testing.expect(result.has_std_fs_import);
    try testing.expect(result.has_allocator_param);
}

// ── extractModuleNames tests ──

test "extractModuleNames: finds addModule names" {
    const content =
        \\const mod = b.addModule("core", .{});
        \\const mod2 = b.addModule("window", .{});
    ;
    var out: [16][]const u8 = undefined;
    const count = extractModuleNames(content, &out);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("core", out[0]);
    try testing.expectEqualStrings("window", out[1]);
}

test "extractModuleNames: finds addImport names" {
    const content =
        \\exe.root_module.addImport("gl", gl_dep.module("gl"));
        \\exe.root_module.addImport("timer", timer_dep.module("timer"));
    ;
    var out: [16][]const u8 = undefined;
    const count = extractModuleNames(content, &out);
    // addImport("gl"), addImport("timer"), plus module("gl"), module("timer") are NOT matched
    // Actually addImport matches, and the module("gl") part doesn't match addModule or addImport
    try testing.expect(count >= 2);
    try testing.expectEqualStrings("gl", out[0]);
    try testing.expectEqualStrings("timer", out[1]);
}

test "extractModuleNames: deduplicates names" {
    const content =
        \\const mod = b.addModule("core", .{});
        \\exe.addImport("core", core_dep.module("core"));
    ;
    var out: [16][]const u8 = undefined;
    const count = extractModuleNames(content, &out);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("core", out[0]);
}

test "extractModuleNames: empty content returns zero" {
    var out: [16][]const u8 = undefined;
    const count = extractModuleNames("", &out);
    try testing.expectEqual(@as(usize, 0), count);
}

test "extractModuleNames: no matches returns zero" {
    const content = "const x = 42;\nfn foo() void {}\n";
    var out: [16][]const u8 = undefined;
    const count = extractModuleNames(content, &out);
    try testing.expectEqual(@as(usize, 0), count);
}

// ── extractSystemLibraries tests ──

test "extractSystemLibraries: finds linkSystemLibrary names" {
    const content =
        \\win32_mod.linkSystemLibrary("kernel32", .{});
        \\gl_mod.linkSystemLibrary("opengl32", .{});
        \\window_mod.linkSystemLibrary("gdi32", .{});
    ;
    var out: [16][]const u8 = undefined;
    const count = extractSystemLibraries(content, &out);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("kernel32", out[0]);
    try testing.expectEqualStrings("opengl32", out[1]);
    try testing.expectEqualStrings("gdi32", out[2]);
}

test "extractSystemLibraries: deduplicates libraries" {
    const content =
        \\mod1.linkSystemLibrary("kernel32", .{});
        \\mod2.linkSystemLibrary("kernel32", .{});
        \\mod3.linkSystemLibrary("gdi32", .{});
    ;
    var out: [16][]const u8 = undefined;
    const count = extractSystemLibraries(content, &out);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("kernel32", out[0]);
    try testing.expectEqualStrings("gdi32", out[1]);
}

test "extractSystemLibraries: empty content returns zero" {
    var out: [16][]const u8 = undefined;
    const count = extractSystemLibraries("", &out);
    try testing.expectEqual(@as(usize, 0), count);
}

test "extractSystemLibraries: no matches returns zero" {
    const content = "const x = 42;\nfn foo() void {}\n";
    var out: [16][]const u8 = undefined;
    const count = extractSystemLibraries(content, &out);
    try testing.expectEqual(@as(usize, 0), count);
}
