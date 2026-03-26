// Property test: no shared source files across transport modules
// **Validates: Requirements 18.1**
//
// Parses `zpm/build.zig` and verifies that no `.zig` file path appears as
// `root_source_file` in more than one transport module's `addModule()` call.
// This ensures the Zig compiler never encounters the "file exists in multiple
// modules" error for transport modules.
//
// Run: zig build test-shared-source  (from zpm/)

const std = @import("std");
const testing = std.testing;

const build_embed = @import("build_embed");
const build_source: []const u8 = build_embed.content;

/// Extract all `b.path("src/transport/...")` strings that appear within
/// `addModule(` call contexts in the build source. Returns the count of
/// paths found, writing them into `out_paths`.
fn extractTransportPaths(
    src: []const u8,
    out_paths: [][]const u8,
) usize {
    // We scan for the pattern: .root_source_file = b.path("src/transport/
    // and extract the full path string up to the closing quote.
    const needle = "b.path(\"src/transport/";
    var count: usize = 0;
    var i: usize = 0;

    while (i + needle.len < src.len) : (i += 1) {
        if (!std.mem.eql(u8, src[i..][0..needle.len], needle)) continue;

        // Check this is inside a root_source_file assignment by scanning
        // backwards for `.root_source_file` on the same or previous line.
        const context_start = if (i >= 120) i - 120 else 0;
        const context = src[context_start..i];
        if (std.mem.indexOf(u8, context, ".root_source_file") == null) {
            continue;
        }

        // Extract the path string: starts after b.path(" and ends at the next "
        const path_start = i + "b.path(\"".len;
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
