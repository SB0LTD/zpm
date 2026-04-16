// Layer 0 — String-based ZON manipulation for build.zig.zon.
//
// Operates on build.zig.zon content as a byte buffer. Parses the
// .dependencies field, adds/removes entries, and outputs valid ZON.
// No full AST — just enough string matching for the well-structured
// ZON format that Zig produces.
//
// Zpm deps follow the naming convention: scope-name (e.g. "zpm-core").
// Non-zpm deps are preserved unchanged.

const names = @import("names.sig");

// ── String Helpers (no std dependency) ──

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn strStartsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return strEql(haystack[0..prefix.len], prefix);
}

fn strIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (strEql(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn strIndexOfPos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (start >= haystack.len) return null;
    if (strIndexOf(haystack[start..], needle)) |offset| return start + offset;
    return null;
}

// ── Public Types ──

pub const ZonDep = struct {
    zon_name: []const u8, // "zpm-core"
    url: []const u8,
    hash: []const u8,
};

pub const ZonError = error{
    InvalidFormat,
    DependencyNotFound,
    DependencyRequired, // can't remove, another pkg depends on it
    BufferTooSmall,
    OutOfMemory,
};

// ── Fixed-capacity list (replaces BoundedArray) ──

fn FixedList(comptime T: type, comptime cap: usize) type {
    return struct {
        items: [cap]T = undefined,
        len: usize = 0,

        const Self = @This();

        fn append(self: *Self, item: T) ZonError!void {
            if (self.len >= cap) return ZonError.BufferTooSmall;
            self.items[self.len] = item;
            self.len += 1;
        }

        fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }
    };
}

// ── Public API ──

/// Extract dependency entries from ZON source text into caller's buffer.
/// Returns the number of deps written. All string fields are slices into
/// the original source — zero allocation.
pub fn parseDeps(source: []const u8, out: []ZonDep) ZonError!usize {
    const deps_start = findDepsBlock(source) orelse return ZonError.InvalidFormat;
    const block = source[deps_start..];
    const block_end = findMatchingBrace(block) orelse return ZonError.InvalidFormat;
    const deps_content = block[0..block_end];

    var count: usize = 0;
    var pos: usize = 0;
    while (pos < deps_content.len) {
        const entry = findNextEntry(deps_content, pos) orelse break;
        if (count >= out.len) return ZonError.BufferTooSmall;
        out[count] = .{
            .zon_name = entry.name,
            .url = entry.url,
            .hash = entry.hash,
        };
        count += 1;
        pos = entry.end_pos;
    }

    return count;
}

/// Add or update dependencies in ZON source. Returns new ZON content
/// written into `out`. Preserves non-zpm entries. Idempotent: adding
/// the same dep at the same url+hash produces identical output.
pub fn addDeps(source: []const u8, new_deps: []const ZonDep, out: []u8) ZonError![]const u8 {
    const deps_start = findDepsBlock(source) orelse return ZonError.InvalidFormat;
    const block = source[deps_start..];
    const block_end = findMatchingBrace(block) orelse return ZonError.InvalidFormat;

    const abs_block_end = deps_start + block_end;

    // Find where to resume after deps block
    var after_deps = abs_block_end + 1;
    while (after_deps < source.len and (source[after_deps] == ',' or source[after_deps] == ' ' or source[after_deps] == '\n' or source[after_deps] == '\r')) {
        after_deps += 1;
    }

    // Collect existing deps
    const deps_content = block[0..block_end];
    var existing = FixedList(ExistingDep, 128){};
    {
        var pos: usize = 0;
        while (pos < deps_content.len) {
            const entry = findNextEntry(deps_content, pos) orelse break;
            try existing.append(.{
                .name = entry.name,
                .url = entry.url,
                .hash = entry.hash,
                .is_zpm = isZpmDep(entry.name),
            });
            pos = entry.end_pos;
        }
    }

    // Build output
    var w = BufWriter{ .buf = out, .pos = 0 };

    const before_deps = findDepsFieldStart(source) orelse return ZonError.InvalidFormat;
    w.write(source[0..before_deps]) catch return ZonError.BufferTooSmall;
    w.write(".dependencies = .{") catch return ZonError.BufferTooSmall;

    var wrote_any = false;

    // Write non-zpm deps first (preserved)
    for (existing.slice()) |dep| {
        if (!dep.is_zpm) {
            w.write("\n") catch return ZonError.BufferTooSmall;
            writeDepEntry(&w, dep.name, dep.url, dep.hash) catch return ZonError.BufferTooSmall;
            wrote_any = true;
        }
    }

    // Build set of new dep names
    var new_names = FixedList([]const u8, 128){};
    for (new_deps) |nd| {
        try new_names.append(nd.zon_name);
    }

    // Keep existing zpm deps not being replaced
    for (existing.slice()) |dep| {
        if (dep.is_zpm and !containsName(new_names.slice(), dep.name)) {
            w.write("\n") catch return ZonError.BufferTooSmall;
            writeDepEntry(&w, dep.name, dep.url, dep.hash) catch return ZonError.BufferTooSmall;
            wrote_any = true;
        }
    }

    // Write new/updated deps
    for (new_deps) |nd| {
        w.write("\n") catch return ZonError.BufferTooSmall;
        writeDepEntry(&w, nd.zon_name, nd.url, nd.hash) catch return ZonError.BufferTooSmall;
        wrote_any = true;
    }

    if (wrote_any) {
        w.write("\n    ") catch return ZonError.BufferTooSmall;
    }
    w.write("},\n") catch return ZonError.BufferTooSmall;

    w.write(source[after_deps..]) catch return ZonError.BufferTooSmall;

    return out[0..w.pos];
}

/// A simple dependency graph interface for removal checks.
pub const DepGraph = struct {
    entries: []const GraphEntry,

    pub const GraphEntry = struct {
        zon_name: []const u8,
        depends_on: []const []const u8,
    };

    pub fn getDeps(self: *const DepGraph, zon_name: []const u8) ?[]const []const u8 {
        for (self.entries) |entry| {
            if (strEql(entry.zon_name, zon_name)) return entry.depends_on;
        }
        return null;
    }
};

/// Remove a dependency from ZON source. Checks that no other installed
/// zpm dep depends on the target (returns DependencyRequired if so).
/// Also removes orphaned transitive deps no longer needed.
///
/// `direct_deps` lists the zon_names of directly-installed packages
/// (as opposed to transitive deps). Direct deps are never auto-removed.
pub fn removeDep(
    source: []const u8,
    zon_name: []const u8,
    all_deps: []const ZonDep,
    direct_deps: []const []const u8,
    dep_graph: *const DepGraph,
    out: []u8,
) ZonError![]const u8 {
    if (!depExists(all_deps, zon_name)) return ZonError.DependencyNotFound;

    // Check no other installed zpm dep depends on the target
    for (all_deps) |dep| {
        if (strEql(dep.zon_name, zon_name)) continue;
        if (!isZpmDep(dep.zon_name)) continue;
        if (dep_graph.getDeps(dep.zon_name)) |deps_of| {
            for (deps_of) |child| {
                if (strEql(child, zon_name)) {
                    return ZonError.DependencyRequired;
                }
            }
        }
    }

    // Determine which deps to remove: target + orphaned transitive deps
    var to_remove = FixedList([]const u8, 128){};
    try to_remove.append(zon_name);
    findOrphans(all_deps, direct_deps, zon_name, dep_graph, &to_remove) catch return ZonError.BufferTooSmall;

    // Build kept deps list
    var kept = FixedList(ZonDep, 128){};
    for (all_deps) |dep| {
        if (!containsName(to_remove.slice(), dep.zon_name)) {
            try kept.append(dep);
        }
    }

    return rebuildWithDeps(source, kept.slice(), out);
}

/// Check if a dependency name follows the zpm naming convention.
pub fn isZpmDep(zon_name: []const u8) bool {
    return strStartsWith(zon_name, "zpm-");
}

// ── Internal Types ──

const ExistingDep = struct {
    name: []const u8,
    url: []const u8,
    hash: []const u8,
    is_zpm: bool,
};

const ParsedEntry = struct {
    name: []const u8,
    url: []const u8,
    hash: []const u8,
    end_pos: usize,
};

// ── Internal Helpers ──

fn findDepsBlock(source: []const u8) ?usize {
    const marker = ".dependencies";
    const idx = strIndexOf(source, marker) orelse return null;
    const after_marker = source[idx + marker.len ..];
    var i: usize = 0;
    while (i < after_marker.len and (after_marker[i] == ' ' or after_marker[i] == '=' or
        after_marker[i] == '\n' or after_marker[i] == '\r' or after_marker[i] == '\t'))
    {
        i += 1;
    }
    if (i + 1 < after_marker.len and after_marker[i] == '.' and after_marker[i + 1] == '{') {
        return idx + marker.len + i + 2;
    }
    return null;
}

fn findDepsFieldStart(source: []const u8) ?usize {
    const marker = ".dependencies";
    const idx = strIndexOf(source, marker) orelse return null;
    var start = idx;
    while (start > 0 and source[start - 1] == ' ') {
        start -= 1;
    }
    return start;
}

fn findMatchingBrace(block: []const u8) ?usize {
    var depth: usize = 1;
    var i: usize = 0;
    while (i < block.len) {
        if (block[i] == '{') {
            depth += 1;
        } else if (block[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        } else if (block[i] == '"') {
            i += 1;
            while (i < block.len and block[i] != '"') {
                if (block[i] == '\\') i += 1;
                i += 1;
            }
        }
        i += 1;
    }
    return null;
}

fn findNextEntry(content: []const u8, start: usize) ?ParsedEntry {
    var pos = start;
    while (pos < content.len) {
        if (content[pos] == '.' and pos + 1 < content.len) {
            if (content[pos + 1] == '@' and pos + 2 < content.len and content[pos + 2] == '"') {
                // .@"name" format
                const name_start = pos + 3;
                const name_end = strIndexOfPos(content, name_start, "\"") orelse return null;
                const entry_name = content[name_start..name_end];
                const after_name = content[name_end + 1 ..];
                const eb_offset = strIndexOf(after_name, ".{") orelse return null;
                const eb_start = name_end + 1 + eb_offset + 2;
                const entry_content = content[eb_start..];
                const entry_end = findMatchingBrace(entry_content) orelse return null;
                const entry_inner = entry_content[0..entry_end];
                const url = extractStringField(entry_inner, ".url") orelse return null;
                const hash = extractStringField(entry_inner, ".hash") orelse return null;
                var end_pos = eb_start + entry_end + 1;
                while (end_pos < content.len and (content[end_pos] == ',' or content[end_pos] == ' ')) {
                    end_pos += 1;
                }
                return .{ .name = entry_name, .url = url, .hash = hash, .end_pos = end_pos };
            } else if ((content[pos + 1] >= 'a' and content[pos + 1] <= 'z') or content[pos + 1] == '_') {
                // .identifier format
                const name_start = pos + 1;
                var name_end = name_start;
                while (name_end < content.len and isIdentChar(content[name_end])) {
                    name_end += 1;
                }
                const entry_name = content[name_start..name_end];
                const after_name = content[name_end..];
                const eb_offset = strIndexOf(after_name, ".{") orelse {
                    pos = name_end;
                    continue;
                };
                const eb_start = name_end + eb_offset + 2;
                const entry_content = content[eb_start..];
                const entry_end = findMatchingBrace(entry_content) orelse return null;
                const entry_inner = entry_content[0..entry_end];
                const url = extractStringField(entry_inner, ".url") orelse {
                    pos = eb_start + entry_end + 1;
                    continue;
                };
                const hash = extractStringField(entry_inner, ".hash") orelse {
                    pos = eb_start + entry_end + 1;
                    continue;
                };
                var end_pos = eb_start + entry_end + 1;
                while (end_pos < content.len and (content[end_pos] == ',' or content[end_pos] == ' ')) {
                    end_pos += 1;
                }
                return .{ .name = entry_name, .url = url, .hash = hash, .end_pos = end_pos };
            }
        }
        pos += 1;
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

fn extractStringField(content: []const u8, field_name: []const u8) ?[]const u8 {
    const field_pos = strIndexOf(content, field_name) orelse return null;
    const after_field = content[field_pos + field_name.len ..];
    var i: usize = 0;
    while (i < after_field.len and (after_field[i] == ' ' or after_field[i] == '=' or after_field[i] == '\t')) {
        i += 1;
    }
    if (i >= after_field.len or after_field[i] != '"') return null;
    i += 1;
    const str_start = i;
    while (i < after_field.len and after_field[i] != '"') {
        if (after_field[i] == '\\') i += 1;
        i += 1;
    }
    if (i >= after_field.len) return null;
    return after_field[str_start..i];
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (strEql(item, name)) return true;
    }
    return false;
}

fn depExists(deps: []const ZonDep, zon_name: []const u8) bool {
    for (deps) |dep| {
        if (strEql(dep.zon_name, zon_name)) return true;
    }
    return false;
}

fn findOrphans(
    all_deps: []const ZonDep,
    direct_deps: []const []const u8,
    removed: []const u8,
    dep_graph: *const DepGraph,
    to_remove: *FixedList([]const u8, 128),
) !void {
    // Collect transitive deps of the removed package
    var candidates = FixedList([]const u8, 128){};
    collectTransitiveDeps(removed, dep_graph, &candidates) catch return;

    // Iteratively find orphans — removing one dep may orphan others
    var changed = true;
    while (changed) {
        changed = false;
        for (candidates.slice()) |candidate| {
            if (containsName(to_remove.slice(), candidate)) continue;
            if (!isZpmDep(candidate)) continue;

            // Direct deps are never auto-removed as orphans
            if (containsName(direct_deps, candidate)) continue;

            // Check if any remaining (non-removed) zpm dep still needs this candidate
            var still_needed = false;
            for (all_deps) |dep| {
                if (strEql(dep.zon_name, removed)) continue;
                if (strEql(dep.zon_name, candidate)) continue;
                if (containsName(to_remove.slice(), dep.zon_name)) continue;
                if (!isZpmDep(dep.zon_name)) continue;
                if (dependsOn(dep.zon_name, candidate, dep_graph)) {
                    still_needed = true;
                    break;
                }
            }

            if (!still_needed) {
                to_remove.append(candidate) catch return;
                changed = true;
            }
        }
    }
}

fn collectTransitiveDeps(
    zon_name: []const u8,
    dep_graph: *const DepGraph,
    result: *FixedList([]const u8, 128),
) !void {
    const deps_of = dep_graph.getDeps(zon_name) orelse return;
    for (deps_of) |child| {
        if (!containsName(result.slice(), child)) {
            result.append(child) catch return;
            collectTransitiveDeps(child, dep_graph, result) catch return;
        }
    }
}

fn dependsOn(parent: []const u8, target: []const u8, dep_graph: *const DepGraph) bool {
    const deps_of = dep_graph.getDeps(parent) orelse return false;
    for (deps_of) |child| {
        if (strEql(child, target)) return true;
        if (dependsOn(child, target, dep_graph)) return true;
    }
    return false;
}

const BufWriter = struct {
    buf: []u8,
    pos: usize,

    fn write(self: *BufWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos .. self.pos + data.len], data);
        self.pos += data.len;
    }
};

fn writeDepEntry(w: *BufWriter, dep_name: []const u8, url: []const u8, hash: []const u8) !void {
    const needs_quote = needsQuotedName(dep_name);
    w.write("        ") catch return error.BufferTooSmall;
    if (needs_quote) {
        w.write(".@\"") catch return error.BufferTooSmall;
        w.write(dep_name) catch return error.BufferTooSmall;
        w.write("\"") catch return error.BufferTooSmall;
    } else {
        w.write(".") catch return error.BufferTooSmall;
        w.write(dep_name) catch return error.BufferTooSmall;
    }
    w.write(" = .{\n") catch return error.BufferTooSmall;
    w.write("            .url = \"") catch return error.BufferTooSmall;
    w.write(url) catch return error.BufferTooSmall;
    w.write("\",\n") catch return error.BufferTooSmall;
    w.write("            .hash = \"") catch return error.BufferTooSmall;
    w.write(hash) catch return error.BufferTooSmall;
    w.write("\",\n") catch return error.BufferTooSmall;
    w.write("        },") catch return error.BufferTooSmall;
}

fn needsQuotedName(dep_name: []const u8) bool {
    for (dep_name) |c| {
        if (c == '-') return true;
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return true;
    }
    return false;
}

fn rebuildWithDeps(source: []const u8, deps: []const ZonDep, out: []u8) ZonError![]const u8 {
    const deps_start = findDepsBlock(source) orelse return ZonError.InvalidFormat;
    const block = source[deps_start..];
    const block_end = findMatchingBrace(block) orelse return ZonError.InvalidFormat;
    var after_deps = deps_start + block_end + 1;
    while (after_deps < source.len and (source[after_deps] == ',' or source[after_deps] == ' ' or
        source[after_deps] == '\n' or source[after_deps] == '\r'))
    {
        after_deps += 1;
    }
    var w = BufWriter{ .buf = out, .pos = 0 };
    const before_deps = findDepsFieldStart(source) orelse return ZonError.InvalidFormat;
    w.write(source[0..before_deps]) catch return ZonError.BufferTooSmall;
    w.write(".dependencies = .{") catch return ZonError.BufferTooSmall;
    var wrote_any = false;
    for (deps) |dep| {
        w.write("\n") catch return ZonError.BufferTooSmall;
        writeDepEntry(&w, dep.zon_name, dep.url, dep.hash) catch return ZonError.BufferTooSmall;
        wrote_any = true;
    }
    if (wrote_any) {
        w.write("\n    ") catch return ZonError.BufferTooSmall;
    }
    w.write("},\n") catch return ZonError.BufferTooSmall;
    w.write(source[after_deps..]) catch return ZonError.BufferTooSmall;
    return out[0..w.pos];
}


// ── Tests ──

const std = @import("std");
const testing = std.testing;

const sample_zon =
    \\.{
    \\    .name = .@"my-app",
    \\    .version = "0.1.0",
    \\    .fingerprint = 0xdeadbeef,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220abc123",
    \\        },
    \\        .@"zpm-window" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz",
    \\            .hash = "1220def456",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

const empty_deps_zon =
    \\.{
    \\    .name = .@"my-app",
    \\    .version = "0.1.0",
    \\    .fingerprint = 0xdeadbeef,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{},
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

const mixed_deps_zon =
    \\.{
    \\    .name = .@"my-app",
    \\    .version = "0.1.0",
    \\    .fingerprint = 0xdeadbeef,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .ziglyph = .{
    \\            .url = "https://example.com/ziglyph/0.1.0.tar.gz",
    \\            .hash = "1220zig000",
    \\        },
    \\        .@"zpm-core" = .{
    \\            .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz",
    \\            .hash = "1220abc123",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

test "parseDeps: extracts dependencies from ZON source" {
    var deps: [64]ZonDep = undefined;
    const count = try parseDeps(sample_zon, &deps);

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("zpm-core", deps[0].zon_name);
    try testing.expectEqualStrings("https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz", deps[0].url);
    try testing.expectEqualStrings("1220abc123", deps[0].hash);
    try testing.expectEqualStrings("zpm-window", deps[1].zon_name);
    try testing.expectEqualStrings("https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz", deps[1].url);
    try testing.expectEqualStrings("1220def456", deps[1].hash);
}

test "parseDeps: empty dependencies block" {
    var deps: [64]ZonDep = undefined;
    const count = try parseDeps(empty_deps_zon, &deps);
    try testing.expectEqual(@as(usize, 0), count);
}

test "parseDeps: mixed zpm and non-zpm deps" {
    var deps: [64]ZonDep = undefined;
    const count = try parseDeps(mixed_deps_zon, &deps);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("ziglyph", deps[0].zon_name);
    try testing.expectEqualStrings("zpm-core", deps[1].zon_name);
}

test "addDeps: add new deps to empty block" {
    const new_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz", .hash = "1220abc123" },
    };
    var out: [4096]u8 = undefined;
    const result = try addDeps(empty_deps_zon, &new_deps, &out);

    try testing.expect(std.mem.indexOf(u8, result, "zpm-core") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1220abc123") != null);
    try testing.expect(std.mem.indexOf(u8, result, ".paths") != null);
}

test "addDeps: idempotent — adding same dep twice produces identical output" {
    const new_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz", .hash = "1220abc123" },
    };
    var out1: [4096]u8 = undefined;
    const result1 = try addDeps(empty_deps_zon, &new_deps, &out1);

    var out2: [4096]u8 = undefined;
    const result2 = try addDeps(result1, &new_deps, &out2);

    try testing.expectEqualStrings(result1, result2);
}

test "addDeps: preserves non-zpm deps" {
    const new_deps = [_]ZonDep{
        .{ .zon_name = "zpm-window", .url = "https://registry.zpm.dev/pkg/@zpm/window/0.1.0.tar.gz", .hash = "1220win000" },
    };
    var out: [4096]u8 = undefined;
    const result = try addDeps(mixed_deps_zon, &new_deps, &out);

    try testing.expect(std.mem.indexOf(u8, result, "ziglyph") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1220zig000") != null);
    try testing.expect(std.mem.indexOf(u8, result, "zpm-window") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1220win000") != null);
    try testing.expect(std.mem.indexOf(u8, result, "zpm-core") != null);
}

test "addDeps: update existing dep with new hash" {
    const new_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "https://registry.zpm.dev/pkg/@zpm/core/0.2.0.tar.gz", .hash = "1220new999" },
    };
    var out: [4096]u8 = undefined;
    const result = try addDeps(sample_zon, &new_deps, &out);

    try testing.expect(std.mem.indexOf(u8, result, "1220new999") != null);
    try testing.expect(std.mem.indexOf(u8, result, "0.2.0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1220abc123") == null);
    try testing.expect(std.mem.indexOf(u8, result, "zpm-window") != null);
}

test "removeDep: removes a dep with no dependents" {
    const all_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "url1", .hash = "hash1" },
        .{ .zon_name = "zpm-window", .url = "url2", .hash = "hash2" },
    };
    const graph_entries = [_]DepGraph.GraphEntry{
        .{ .zon_name = "zpm-core", .depends_on = &.{} },
        .{ .zon_name = "zpm-window", .depends_on = &.{"zpm-core"} },
    };
    const graph = DepGraph{ .entries = &graph_entries };
    const direct = [_][]const u8{ "zpm-core", "zpm-window" };

    var out: [4096]u8 = undefined;
    const result = try removeDep(sample_zon, "zpm-window", &all_deps, &direct, &graph, &out);

    try testing.expect(std.mem.indexOf(u8, result, "zpm-window") == null);
    try testing.expect(std.mem.indexOf(u8, result, "zpm-core") != null);
}

test "removeDep: rejects removal when another dep depends on target" {
    const all_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "url1", .hash = "hash1" },
        .{ .zon_name = "zpm-window", .url = "url2", .hash = "hash2" },
    };
    const graph_entries = [_]DepGraph.GraphEntry{
        .{ .zon_name = "zpm-core", .depends_on = &.{} },
        .{ .zon_name = "zpm-window", .depends_on = &.{"zpm-core"} },
    };
    const graph = DepGraph{ .entries = &graph_entries };
    const direct = [_][]const u8{ "zpm-core", "zpm-window" };

    var out: [4096]u8 = undefined;
    const result = removeDep(sample_zon, "zpm-core", &all_deps, &direct, &graph, &out);
    try testing.expectError(ZonError.DependencyRequired, result);
}


test "removeDep: removes orphaned transitive deps" {
    const zon_with_three =
        \\.{
        \\    .name = .@"my-app",
        \\    .version = "0.1.0",
        \\    .fingerprint = 0xdeadbeef,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{
        \\        .@"zpm-gl" = .{
        \\            .url = "url-gl",
        \\            .hash = "hash-gl",
        \\        },
        \\        .@"zpm-window" = .{
        \\            .url = "url-window",
        \\            .hash = "hash-window",
        \\        },
        \\        .@"zpm-app" = .{
        \\            .url = "url-app",
        \\            .hash = "hash-app",
        \\        },
        \\    },
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    ;

    const all_deps = [_]ZonDep{
        .{ .zon_name = "zpm-gl", .url = "url-gl", .hash = "hash-gl" },
        .{ .zon_name = "zpm-window", .url = "url-window", .hash = "hash-window" },
        .{ .zon_name = "zpm-app", .url = "url-app", .hash = "hash-app" },
    };
    const graph_entries = [_]DepGraph.GraphEntry{
        .{ .zon_name = "zpm-gl", .depends_on = &.{} },
        .{ .zon_name = "zpm-window", .depends_on = &.{"zpm-gl"} },
        .{ .zon_name = "zpm-app", .depends_on = &.{"zpm-window"} },
    };
    const graph = DepGraph{ .entries = &graph_entries };
    // Only zpm-app is direct; zpm-window and zpm-gl are transitive
    const direct = [_][]const u8{"zpm-app"};

    var out: [4096]u8 = undefined;
    const result = try removeDep(zon_with_three, "zpm-app", &all_deps, &direct, &graph, &out);

    try testing.expect(std.mem.indexOf(u8, result, "zpm-app") == null);
    try testing.expect(std.mem.indexOf(u8, result, "zpm-window") == null);
    try testing.expect(std.mem.indexOf(u8, result, "zpm-gl") == null);
    try testing.expect(std.mem.indexOf(u8, result, ".dependencies") != null);
}

test "removeDep: DependencyNotFound for missing dep" {
    const all_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "url1", .hash = "hash1" },
    };
    const graph_entries = [_]DepGraph.GraphEntry{
        .{ .zon_name = "zpm-core", .depends_on = &.{} },
    };
    const graph = DepGraph{ .entries = &graph_entries };
    const direct = [_][]const u8{"zpm-core"};

    var out: [4096]u8 = undefined;
    const result = removeDep(sample_zon, "zpm-nonexistent", &all_deps, &direct, &graph, &out);
    try testing.expectError(ZonError.DependencyNotFound, result);
}

test "isZpmDep: identifies zpm deps" {
    try testing.expect(isZpmDep("zpm-core"));
    try testing.expect(isZpmDep("zpm-window"));
    try testing.expect(isZpmDep("zpm-win32"));
    try testing.expect(!isZpmDep("ziglyph"));
    try testing.expect(!isZpmDep("some-other-lib"));
    try testing.expect(!isZpmDep("myorg-chart"));
}

test "addDeps: output is valid ZON structure" {
    const new_deps = [_]ZonDep{
        .{ .zon_name = "zpm-core", .url = "https://example.com/core.tar.gz", .hash = "1220aaa" },
        .{ .zon_name = "zpm-gl", .url = "https://example.com/gl.tar.gz", .hash = "1220bbb" },
    };
    var out: [4096]u8 = undefined;
    const result = try addDeps(empty_deps_zon, &new_deps, &out);

    // Basic structural checks
    try testing.expect(std.mem.startsWith(u8, result, ".{"));
    try testing.expect(result.len >= 2);
    try testing.expect(result[result.len - 2] == '}');
    try testing.expect(result[result.len - 1] == '\n');
    try testing.expect(std.mem.indexOf(u8, result, ".dependencies") != null);
    try testing.expect(std.mem.indexOf(u8, result, ".paths") != null);

    // Can re-parse the deps
    var re_deps: [64]ZonDep = undefined;
    const re_count = try parseDeps(result, &re_deps);
    try testing.expectEqual(@as(usize, 2), re_count);
}

test "removeDep: preserves non-zpm deps during removal" {
    const all_deps = [_]ZonDep{
        .{ .zon_name = "ziglyph", .url = "https://example.com/ziglyph/0.1.0.tar.gz", .hash = "1220zig000" },
        .{ .zon_name = "zpm-core", .url = "https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz", .hash = "1220abc123" },
    };
    const graph_entries = [_]DepGraph.GraphEntry{
        .{ .zon_name = "zpm-core", .depends_on = &.{} },
    };
    const graph = DepGraph{ .entries = &graph_entries };
    const direct = [_][]const u8{"zpm-core"};

    var out: [4096]u8 = undefined;
    const result = try removeDep(mixed_deps_zon, "zpm-core", &all_deps, &direct, &graph, &out);

    try testing.expect(std.mem.indexOf(u8, result, "zpm-core") == null);
    try testing.expect(std.mem.indexOf(u8, result, "ziglyph") != null);
    try testing.expect(std.mem.indexOf(u8, result, "1220zig000") != null);
}

// ── Property-Based Tests ──

test "Property 6: Build Manifest Mutation Preserves Non-Zpm Dependencies" {
    // **Validates: Requirements 5.3, 5.4**
    // Generate build.zig.zon with mixed zpm/non-zpm deps, call addDeps to
    // add/update zpm deps, verify non-zpm entries are unchanged in the output
    // and output is valid (can be re-parsed).
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE_0006);
    const rand = prng.random();

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        // Generate 1-3 random non-zpm dep names
        const num_non_zpm = rand.intRangeAtMost(usize, 1, 3);
        var non_zpm_names: [3][16]u8 = undefined;
        var non_zpm_lens: [3]usize = undefined;
        for (0..num_non_zpm) |i| {
            const name_len = rand.intRangeAtMost(usize, 3, 12);
            for (0..name_len) |j| {
                non_zpm_names[i][j] = "abcdefghijklmnopqrstuvwxyz"[rand.intRangeAtMost(usize, 0, 25)];
            }
            non_zpm_lens[i] = name_len;
        }

        // Generate 1-3 random zpm dep names
        const num_zpm = rand.intRangeAtMost(usize, 1, 3);
        var zpm_suffixes: [3][12]u8 = undefined;
        var zpm_suffix_lens: [3]usize = undefined;
        for (0..num_zpm) |i| {
            const suf_len = rand.intRangeAtMost(usize, 2, 8);
            for (0..suf_len) |j| {
                zpm_suffixes[i][j] = "abcdefghijklmnopqrstuvwxyz"[rand.intRangeAtMost(usize, 0, 25)];
            }
            zpm_suffix_lens[i] = suf_len;
        }

        // Build ZON source with mixed deps
        var src_buf: [8192]u8 = undefined;
        var src_pos: usize = 0;
        const header =
            \\.{
            \\    .name = .@"test-app",
            \\    .version = "0.1.0",
            \\    .fingerprint = 0xdeadbeef,
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{
            \\
        ;
        @memcpy(src_buf[src_pos .. src_pos + header.len], header);
        src_pos += header.len;

        // Write non-zpm deps
        for (0..num_non_zpm) |i| {
            const name_slice = non_zpm_names[i][0..non_zpm_lens[i]];
            const entry_result = std.fmt.bufPrint(src_buf[src_pos..], "        .{s} = .{{\n            .url = \"https://example.com/{s}.tar.gz\",\n            .hash = \"1220nhash{d}\",\n        }},\n", .{ name_slice, name_slice, i }) catch break;
            src_pos += entry_result.len;
        }

        // Write existing zpm deps
        for (0..num_zpm) |i| {
            const suf_slice = zpm_suffixes[i][0..zpm_suffix_lens[i]];
            const entry_result = std.fmt.bufPrint(src_buf[src_pos..], "        .@\"zpm-{s}\" = .{{\n            .url = \"https://registry.zpm.dev/pkg/old/{s}.tar.gz\",\n            .hash = \"1220old{d}\",\n        }},\n", .{ suf_slice, suf_slice, i }) catch break;
            src_pos += entry_result.len;
        }

        const footer =
            \\    },
            \\    .paths = .{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\    },
            \\}
            \\
        ;
        @memcpy(src_buf[src_pos .. src_pos + footer.len], footer);
        src_pos += footer.len;

        const source = src_buf[0..src_pos];

        // Parse original non-zpm deps for comparison
        var orig_dep_buf: [64]ZonDep = undefined;
        const orig_count = parseDeps(source, &orig_dep_buf) catch continue;
        const orig_deps = orig_dep_buf[0..orig_count];

        var orig_non_zpm_count: usize = 0;
        var orig_nh_names: [8][32]u8 = undefined;
        var orig_nh_name_lens: [8]usize = undefined;
        var orig_nh_urls: [8][128]u8 = undefined;
        var orig_nh_url_lens: [8]usize = undefined;
        var orig_nh_hashes: [8][32]u8 = undefined;
        var orig_nh_hash_lens: [8]usize = undefined;
        for (orig_deps) |dep| {
            if (!isZpmDep(dep.zon_name)) {
                const idx = orig_non_zpm_count;
                @memcpy(orig_nh_names[idx][0..dep.zon_name.len], dep.zon_name);
                orig_nh_name_lens[idx] = dep.zon_name.len;
                @memcpy(orig_nh_urls[idx][0..dep.url.len], dep.url);
                orig_nh_url_lens[idx] = dep.url.len;
                @memcpy(orig_nh_hashes[idx][0..dep.hash.len], dep.hash);
                orig_nh_hash_lens[idx] = dep.hash.len;
                orig_non_zpm_count += 1;
            }
        }

        // Generate new zpm deps to add/update
        const num_new = rand.intRangeAtMost(usize, 1, 3);
        var new_deps_arr: [3]ZonDep = undefined;
        var new_name_bufs: [3][20]u8 = undefined;
        var new_url_bufs: [3][64]u8 = undefined;
        var new_hash_bufs: [3][20]u8 = undefined;
        for (0..num_new) |i| {
            const suf_len = rand.intRangeAtMost(usize, 2, 8);
            new_name_bufs[i][0] = 'h';
            new_name_bufs[i][1] = 'e';
            new_name_bufs[i][2] = 'i';
            new_name_bufs[i][3] = 'l';
            new_name_bufs[i][4] = '-';
            for (0..suf_len) |j| {
                new_name_bufs[i][5 + j] = "abcdefghijklmnopqrstuvwxyz"[rand.intRangeAtMost(usize, 0, 25)];
            }
            const name_total = 5 + suf_len;
            const url_res = std.fmt.bufPrint(&new_url_bufs[i], "https://new.dev/{d}.tar.gz", .{iteration * 10 + i}) catch continue;
            const hash_res = std.fmt.bufPrint(&new_hash_bufs[i], "1220new{d}{d}", .{ iteration, i }) catch continue;
            new_deps_arr[i] = .{
                .zon_name = new_name_bufs[i][0..name_total],
                .url = url_res,
                .hash = hash_res,
            };
        }

        // Call addDeps
        var out: [16384]u8 = undefined;
        const result = addDeps(source, new_deps_arr[0..num_new], &out) catch continue;

        // Verify non-zpm entries are unchanged
        var result_dep_buf: [64]ZonDep = undefined;
        const result_count = parseDeps(result, &result_dep_buf) catch {
            return error.TestUnexpectedResult;
        };
        const result_deps = result_dep_buf[0..result_count];

        var result_non_zpm_count: usize = 0;
        for (result_deps) |dep| {
            if (!isZpmDep(dep.zon_name)) {
                try testing.expect(result_non_zpm_count < orig_non_zpm_count);
                try testing.expectEqualStrings(
                    orig_nh_names[result_non_zpm_count][0..orig_nh_name_lens[result_non_zpm_count]],
                    dep.zon_name,
                );
                try testing.expectEqualStrings(
                    orig_nh_urls[result_non_zpm_count][0..orig_nh_url_lens[result_non_zpm_count]],
                    dep.url,
                );
                try testing.expectEqualStrings(
                    orig_nh_hashes[result_non_zpm_count][0..orig_nh_hash_lens[result_non_zpm_count]],
                    dep.hash,
                );
                result_non_zpm_count += 1;
            }
        }
        try testing.expectEqual(orig_non_zpm_count, result_non_zpm_count);

        // Verify output is valid ZON (can be re-parsed without error)
        var reparse_buf: [64]ZonDep = undefined;
        _ = parseDeps(result, &reparse_buf) catch {
            return error.TestUnexpectedResult;
        };

        // Verify structural validity
        try testing.expect(std.mem.indexOf(u8, result, ".dependencies") != null);
        try testing.expect(std.mem.indexOf(u8, result, ".paths") != null);
    }
}

test "Property 7: Install Idempotency" {
    // **Validates: Requirement 5.5**
    // Add a package via addDeps, then add the same package again with identical
    // url+hash, verify the output is byte-identical both times.
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE_0007);
    const rand = prng.random();

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        // Generate a random zpm package name
        var name_buf: [20]u8 = undefined;
        name_buf[0] = 'h';
        name_buf[1] = 'e';
        name_buf[2] = 'i';
        name_buf[3] = 'l';
        name_buf[4] = '-';
        const suf_len = rand.intRangeAtMost(usize, 2, 10);
        for (0..suf_len) |j| {
            name_buf[5 + j] = "abcdefghijklmnopqrstuvwxyz"[rand.intRangeAtMost(usize, 0, 25)];
        }
        const pkg_name = name_buf[0 .. 5 + suf_len];

        // Generate random url and hash
        var url_buf: [64]u8 = undefined;
        const url_slice = std.fmt.bufPrint(&url_buf, "https://registry.zpm.dev/pkg/{d}.tar.gz", .{iteration}) catch continue;
        var hash_buf: [32]u8 = undefined;
        const hash_slice = std.fmt.bufPrint(&hash_buf, "1220idem{d:0>6}", .{iteration}) catch continue;

        const deps_to_add = [_]ZonDep{
            .{ .zon_name = pkg_name, .url = url_slice, .hash = hash_slice },
        };

        // First install: add to empty deps
        var out1: [8192]u8 = undefined;
        const result1 = addDeps(empty_deps_zon, &deps_to_add, &out1) catch continue;

        // Second install: add same package again to the result
        var out2: [8192]u8 = undefined;
        const result2 = addDeps(result1, &deps_to_add, &out2) catch {
            return error.TestUnexpectedResult;
        };

        // Verify byte-identical output
        try testing.expectEqualStrings(result1, result2);
    }
}

test "Property 8: Removal Safety" {
    // **Validates: Requirements 5.6, 5.7**
    // Generate dep graphs, verify removeDep is rejected (DependencyRequired)
    // when another dep depends on the target. Also verify orphaned transitive
    // deps are cleaned when safe.
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE_0008);
    const rand = prng.random();

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        // Generate a chain of 2-4 zpm deps: A -> B -> C [-> D]
        const chain_len = rand.intRangeAtMost(usize, 2, 4);
        var chain_names: [4][16]u8 = undefined;
        var chain_name_lens: [4]usize = undefined;
        for (0..chain_len) |i| {
            chain_names[i][0] = 'h';
            chain_names[i][1] = 'e';
            chain_names[i][2] = 'i';
            chain_names[i][3] = 'l';
            chain_names[i][4] = '-';
            const suf_len = rand.intRangeAtMost(usize, 2, 8);
            for (0..suf_len) |j| {
                chain_names[i][5 + j] = "abcdefghijklmnopqrstuvwxyz"[rand.intRangeAtMost(usize, 0, 25)];
            }
            // Append index to avoid collisions
            const idx_res = std.fmt.bufPrint(chain_names[i][5 + suf_len ..], "{d}", .{i}) catch continue;
            chain_name_lens[i] = 5 + suf_len + idx_res.len;
        }

        // Build ZON source with all chain deps
        var src_buf: [8192]u8 = undefined;
        var src_pos: usize = 0;
        const header =
            \\.{
            \\    .name = .@"test-app",
            \\    .version = "0.1.0",
            \\    .fingerprint = 0xdeadbeef,
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{
            \\
        ;
        @memcpy(src_buf[src_pos .. src_pos + header.len], header);
        src_pos += header.len;

        var valid = true;
        for (0..chain_len) |i| {
            const name_slice = chain_names[i][0..chain_name_lens[i]];
            const entry_res = std.fmt.bufPrint(src_buf[src_pos..], "        .@\"{s}\" = .{{\n            .url = \"https://test.dev/{s}.tar.gz\",\n            .hash = \"1220chain{d}{d}\",\n        }},\n", .{ name_slice, name_slice, iteration, i }) catch {
                valid = false;
                break;
            };
            src_pos += entry_res.len;
        }
        if (!valid) continue;

        const footer =
            \\    },
            \\    .paths = .{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\    },
            \\}
            \\
        ;
        @memcpy(src_buf[src_pos .. src_pos + footer.len], footer);
        src_pos += footer.len;

        const source = src_buf[0..src_pos];

        // Build all_deps array
        var all_deps: [4]ZonDep = undefined;
        var url_bufs: [4][64]u8 = undefined;
        var hash_bufs: [4][32]u8 = undefined;
        var url_lens: [4]usize = undefined;
        var hash_lens: [4]usize = undefined;
        for (0..chain_len) |i| {
            const name_slice = chain_names[i][0..chain_name_lens[i]];
            const u_res = std.fmt.bufPrint(&url_bufs[i], "https://test.dev/{s}.tar.gz", .{name_slice}) catch {
                valid = false;
                break;
            };
            url_lens[i] = u_res.len;
            const h_res = std.fmt.bufPrint(&hash_bufs[i], "1220chain{d}{d}", .{ iteration, i }) catch {
                valid = false;
                break;
            };
            hash_lens[i] = h_res.len;
            all_deps[i] = .{
                .zon_name = name_slice,
                .url = url_bufs[i][0..url_lens[i]],
                .hash = hash_bufs[i][0..hash_lens[i]],
            };
        }
        if (!valid) continue;

        // Build dep graph: chain[0] has no deps, chain[1] depends on chain[0], etc.
        var graph_entries: [4]DepGraph.GraphEntry = undefined;
        var dep_on_bufs: [4][1][]const u8 = undefined;
        graph_entries[0] = .{
            .zon_name = chain_names[0][0..chain_name_lens[0]],
            .depends_on = &.{},
        };
        for (1..chain_len) |i| {
            dep_on_bufs[i] = .{chain_names[i - 1][0..chain_name_lens[i - 1]]};
            graph_entries[i] = .{
                .zon_name = chain_names[i][0..chain_name_lens[i]],
                .depends_on = &dep_on_bufs[i],
            };
        }
        const graph = DepGraph{ .entries = graph_entries[0..chain_len] };

        // Test 1: Removing a dep that others depend on should be rejected.
        // chain[0] is depended on by chain[1], so removing chain[0] should fail.
        if (chain_len >= 2) {
            const direct_all: [4][]const u8 = .{
                chain_names[0][0..chain_name_lens[0]],
                chain_names[1][0..chain_name_lens[1]],
                if (chain_len > 2) chain_names[2][0..chain_name_lens[2]] else "",
                if (chain_len > 3) chain_names[3][0..chain_name_lens[3]] else "",
            };
            var out: [16384]u8 = undefined;
            const remove_result = removeDep(
                source,
                chain_names[0][0..chain_name_lens[0]],
                all_deps[0..chain_len],
                direct_all[0..chain_len],
                &graph,
                &out,
            );
            try testing.expectError(ZonError.DependencyRequired, remove_result);
        }

        // Test 2: Removing the tail of the chain (last dep, which nothing depends on)
        // with only the tail as direct dep — transitive deps should be orphaned and cleaned.
        {
            const tail_idx = chain_len - 1;
            // Only the tail is a direct dep; everything else is transitive
            const direct_tail = [_][]const u8{chain_names[tail_idx][0..chain_name_lens[tail_idx]]};
            var out: [16384]u8 = undefined;
            const remove_result = removeDep(
                source,
                chain_names[tail_idx][0..chain_name_lens[tail_idx]],
                all_deps[0..chain_len],
                &direct_tail,
                &graph,
                &out,
            ) catch continue;

            // All chain deps should be removed (tail + orphaned transitive)
            for (0..chain_len) |i| {
                const name_slice = chain_names[i][0..chain_name_lens[i]];
                try testing.expect(std.mem.indexOf(u8, remove_result, name_slice) == null);
            }

            // Output should still be valid ZON
            try testing.expect(std.mem.indexOf(u8, remove_result, ".dependencies") != null);
            var reparse_buf2: [64]ZonDep = undefined;
            _ = parseDeps(remove_result, &reparse_buf2) catch {
                return error.TestUnexpectedResult;
            };
        }
    }
}
