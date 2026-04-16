// Layer 0 — Pure data transformation, no I/O, no allocator.
//
// Converts between scoped protocol names (@scope/name) and
// Zig-safe ZON identifiers (scope-name). Fixed-buffer only.

/// Maximum length of a scoped name: @<scope>/<name> = 1 + 64 + 1 + 64 = 130
/// Maximum length of a ZON key: <scope>-<name> = 64 + 1 + 64 = 129
const max_scoped_len = 130;
const max_zon_key_len = 129;

pub const NameError = error{
    MissingAtPrefix,
    MissingSlash,
    EmptyScope,
    EmptyName,
    TooLong,
};

/// Converts a scoped name like `@zpm/core` to a ZON key like `zpm-core`.
/// Strips the leading `@` and replaces `/` with `-`.
/// Returns a slice into the provided output buffer.
pub fn scopedNameToZonKey(scoped: []const u8, out: *[max_zon_key_len]u8) NameError![]const u8 {
    if (scoped.len == 0 or scoped[0] != '@') return error.MissingAtPrefix;

    const without_at = scoped[1..];

    // Find the '/' separator
    const slash_pos = indexOf(without_at, '/') orelse return error.MissingSlash;
    if (slash_pos == 0) return error.EmptyScope;
    if (slash_pos + 1 >= without_at.len) return error.EmptyName;

    const result_len = without_at.len - 1; // '/' becomes '-', same count
    if (result_len > max_zon_key_len) return error.TooLong;

    var i: usize = 0;
    for (without_at) |c| {
        out[i] = if (c == '/') '-' else c;
        i += 1;
    }
    // The '/' was replaced with '-', so length = without_at.len
    return out[0..without_at.len];
}

/// Converts a ZON key like `zpm-core` back to a scoped name like `@zpm/core`.
/// Treats the substring before the first `-` as the scope and the rest as the name.
/// Returns a slice into the provided output buffer.
pub fn zonKeyToScopedName(zon_key: []const u8, out: *[max_scoped_len]u8) NameError![]const u8 {
    const sep = indexOf(zon_key, '-') orelse return error.MissingSlash;
    if (sep == 0) return error.EmptyScope;
    if (sep + 1 >= zon_key.len) return error.EmptyName;

    const scope = zon_key[0..sep];
    const name = zon_key[sep + 1 ..];

    // Result: @ + scope + / + name
    const result_len = 1 + scope.len + 1 + name.len;
    if (result_len > max_scoped_len) return error.TooLong;

    out[0] = '@';
    @memcpy(out[1 .. 1 + scope.len], scope);
    out[1 + scope.len] = '/';
    @memcpy(out[2 + scope.len .. 2 + scope.len + name.len], name);

    return out[0..result_len];
}

/// Simple byte search — no std dependency.
fn indexOf(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}


// ── Tests ──

const std = @import("std");
const testing = std.testing;

test "scopedNameToZonKey: basic conversion" {
    var buf: [max_zon_key_len]u8 = undefined;
    const result = try scopedNameToZonKey("@zpm/core", &buf);
    try testing.expectEqualStrings("zpm-core", result);
}

test "scopedNameToZonKey: hyphenated name" {
    var buf: [max_zon_key_len]u8 = undefined;
    const result = try scopedNameToZonKey("@foo/bar-baz", &buf);
    try testing.expectEqualStrings("foo-bar-baz", result);
}

test "scopedNameToZonKey: rejects missing @" {
    var buf: [max_zon_key_len]u8 = undefined;
    try testing.expectError(error.MissingAtPrefix, scopedNameToZonKey("zpm/core", &buf));
}

test "scopedNameToZonKey: rejects missing slash" {
    var buf: [max_zon_key_len]u8 = undefined;
    try testing.expectError(error.MissingSlash, scopedNameToZonKey("@zpmcore", &buf));
}

test "scopedNameToZonKey: rejects empty scope" {
    var buf: [max_zon_key_len]u8 = undefined;
    try testing.expectError(error.EmptyScope, scopedNameToZonKey("@/core", &buf));
}

test "scopedNameToZonKey: rejects empty name" {
    var buf: [max_zon_key_len]u8 = undefined;
    try testing.expectError(error.EmptyName, scopedNameToZonKey("@zpm/", &buf));
}

test "zonKeyToScopedName: basic conversion" {
    var buf: [max_scoped_len]u8 = undefined;
    const result = try zonKeyToScopedName("zpm-core", &buf);
    try testing.expectEqualStrings("@zpm/core", result);
}

test "zonKeyToScopedName: hyphenated name preserved" {
    var buf: [max_scoped_len]u8 = undefined;
    const result = try zonKeyToScopedName("foo-bar-baz", &buf);
    try testing.expectEqualStrings("@foo/bar-baz", result);
}

test "zonKeyToScopedName: rejects no separator" {
    var buf: [max_scoped_len]u8 = undefined;
    try testing.expectError(error.MissingSlash, zonKeyToScopedName("zpmcore", &buf));
}

test "round-trip: scopedName -> zonKey -> scopedName" {
    var zon_buf: [max_zon_key_len]u8 = undefined;
    var scoped_buf: [max_scoped_len]u8 = undefined;

    const names = [_][]const u8{
        "@zpm/core",
        "@zpm/window",
        "@zpm/win32",
        "@myorg/chart-overlay",
        "@a/b",
        "@zpm/file-io",
    };

    for (names) |original| {
        const zon_key = try scopedNameToZonKey(original, &zon_buf);
        const restored = try zonKeyToScopedName(zon_key, &scoped_buf);
        try testing.expectEqualStrings(original, restored);
    }
}

test "property: scoped name round-trip (randomized)" {
    // Property 1: For all valid scoped names @<scope>/<name>,
    // zonKeyToScopedName(scopedNameToZonKey(x)) == x.
    //
    // Scope uses [a-z0-9] (no hyphens — the reverse mapping splits on
    // the first '-', so hyphens in scope would break the round-trip).
    // Name uses [a-z0-9-].
    //
    // Validates: Requirement 2.3

    const alphabet_scope = "abcdefghijklmnopqrstuvwxyz0123456789";
    const alphabet_name = "abcdefghijklmnopqrstuvwxyz0123456789-";

    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rand = prng.random();

    var zon_buf: [max_zon_key_len]u8 = undefined;
    var scoped_buf: [max_scoped_len]u8 = undefined;

    const iterations = 1000;
    for (0..iterations) |_| {
        // Generate random scope: 1..64 chars from alphabet_scope
        var input_buf: [max_scoped_len]u8 = undefined;
        var pos: usize = 0;

        input_buf[pos] = '@';
        pos += 1;

        const scope_len = rand.intRangeAtMost(usize, 1, 64);
        for (0..scope_len) |_| {
            input_buf[pos] = alphabet_scope[rand.intRangeLessThan(usize, 0, alphabet_scope.len)];
            pos += 1;
        }

        input_buf[pos] = '/';
        pos += 1;

        // Generate random name: 1..64 chars from alphabet_name,
        // but avoid leading/trailing '-' and '--' to stay realistic
        const name_len = rand.intRangeAtMost(usize, 1, 64);
        var prev_hyphen = true; // force first char to be non-hyphen
        var name_chars: usize = 0;
        while (name_chars < name_len) {
            const c = alphabet_name[rand.intRangeLessThan(usize, 0, alphabet_name.len)];
            if (c == '-' and prev_hyphen) continue; // skip double-hyphen / leading hyphen
            input_buf[pos] = c;
            pos += 1;
            name_chars += 1;
            prev_hyphen = (c == '-');
        }
        // Trim trailing hyphen
        if (pos > 0 and input_buf[pos - 1] == '-') pos -= 1;
        // Ensure name is non-empty after trim
        if (input_buf[pos - 1] == '/') {
            input_buf[pos] = 'a';
            pos += 1;
        }

        const scoped_name = input_buf[0..pos];

        // Round-trip: scoped → zon key → scoped
        const zon_key = scopedNameToZonKey(scoped_name, &zon_buf) catch |err| {
            std.debug.print("scopedNameToZonKey failed for '{s}': {}\n", .{ scoped_name, err });
            return err;
        };
        const restored = zonKeyToScopedName(zon_key, &scoped_buf) catch |err| {
            std.debug.print("zonKeyToScopedName failed for '{s}' (from '{s}'): {}\n", .{ zon_key, scoped_name, err });
            return err;
        };

        if (!std.mem.eql(u8, scoped_name, restored)) {
            std.debug.print("Round-trip failed:\n  input:    '{s}'\n  zon_key:  '{s}'\n  restored: '{s}'\n", .{ scoped_name, zon_key, restored });
            return error.TestUnexpectedResult;
        }
    }
}
