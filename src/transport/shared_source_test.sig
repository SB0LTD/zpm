// Property test: no shared source files across transport modules
// **Validates: Requirements 18.1**
//
// Parses `zpm/build.sig` and verifies that no `.sig` file path appears as
// `root_source_file` in more than one transport module's `addModule()` call.
// This ensures the Zig compiler never encounters the "file exists in multiple
// modules" error for transport modules.
//
// Run: zig build test-shared-source  (from zpm/)

const std = @import("std");
const testing = std.testing;

const build_embed = @import("build_embed");
const build_source: []const u8 = build_embed.content;

/// Extract transport module paths from either the canonical Sig graph
/// (`ctx.addModule`) or the transitional std.Build graph (`b.path`).
fn extractTransportPaths(
    src: []const u8,
    out_paths: [][]const u8,
) usize {
    const native_needle = "ctx.addModule(";
    const legacy_needle = "b.path(\"src/transport/";
    const native_graph = std.mem.indexOf(u8, src, native_needle) != null;
    var count: usize = 0;
    var i: usize = 0;

    while (i < src.len) : (i += 1) {
        const path_start = if (native_graph) native: {
            if (i + native_needle.len >= src.len or
                !std.mem.eql(u8, src[i..][0..native_needle.len], native_needle)) continue;
            const line_end = i + (std.mem.indexOfScalar(u8, src[i..], '\n') orelse (src.len - i));
            const marker = "\"src/transport/";
            const marker_pos = std.mem.indexOf(u8, src[i..line_end], marker) orelse continue;
            break :native i + marker_pos + 1;
        } else legacy: {
            if (i + legacy_needle.len >= src.len or
                !std.mem.eql(u8, src[i..][0..legacy_needle.len], legacy_needle)) continue;
            const context_start = if (i >= 120) i - 120 else 0;
            if (std.mem.indexOf(u8, src[context_start..i], ".root_source_file") == null) continue;
            break :legacy i + "b.path(\"".len;
        };
        var path_end = path_start;
        while (path_end < src.len and src[path_end] != '"') : (path_end += 1) {}
        if (path_end >= src.len) continue;

        const path = src[path_start..path_end];

        if (count < out_paths.len) {
            out_paths[count] = path;
            count += 1;
        }
    }
    return count;
}

test "no shared source files across transport modules" {
    var paths: [64][]const u8 = undefined;
    const count = extractTransportPaths(build_source, &paths);

    // We should have found at least the known transport modules
    try testing.expect(count >= 2);

    // Check for duplicates: for each pair, verify no two paths are equal
    var duplicates: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j: usize = i + 1;
        while (j < count) : (j += 1) {
            if (std.mem.eql(u8, paths[i], paths[j])) {
                std.debug.print("DUPLICATE: \"{s}\" appears as root_source_file in multiple transport modules\n", .{paths[i]});
                duplicates += 1;
            }
        }
    }

    try testing.expectEqual(@as(usize, 0), duplicates);
}
