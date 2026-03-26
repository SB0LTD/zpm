// Layer 0 — Pure data types and validation for zpm.pkg.zon manifests.
// No I/O, no allocator. Hand-written ZON parser returns slices into source.

const names = @import("names.zig");

// ── Public Types ──

pub const Platform = enum {
    windows,
    linux,
    macos,
    any,
};

pub const Constraints = struct {
    no_allocator: bool = false,
    no_std_io: bool = false,
};

pub const DepRef = struct {
    scope: []const u8,
    name: []const u8,
    version_req: []const u8 = "",
};

pub const PackageManifest = struct {
    protocol_version: u32,
    scope: []const u8,
    name: []const u8,
    version: []const u8 = "0.0.0",
    layer: u2,
    platform: Platform = .any,
    system_libraries: []const []const u8 = &.{},
    zpm_dependencies: []const []const u8 = &.{},
    exports: []const []const u8 = &.{},
    constraints: Constraints = .{},
    description: []const u8 = "",
    license: []const u8 = "",
    repository: []const u8 = "",
};

// ── Validation ──

pub const ValidationField = enum {
    protocol_version,
    scope,
    name,
    version,
    layer,
};

pub const ValidationError = struct {
    field: ValidationField,
    message: []const u8,
};

/// Maximum number of validation errors returned in a single pass.
const max_errors = 16;

pub const ValidationResult = struct {
    errors: [max_errors]ValidationError = undefined,
    count: usize = 0,

    pub fn ok(self: *const ValidationResult) bool {
        return self.count == 0;
    }

    pub fn add(self: *ValidationResult, field: ValidationField, message: []const u8) void {
        if (self.count < max_errors) {
            self.errors[self.count] = .{ .field = field, .message = message };
            self.count += 1;
        }
    }

    pub fn slice(self: *const ValidationResult) []const ValidationError {
        return self.errors[0..self.count];
    }
};

/// Validates all manifest fields. Returns a result with zero or more errors.
pub fn validate(m: *const PackageManifest) ValidationResult {
    var result = ValidationResult{};

    if (m.protocol_version != 1) {
        result.add(.protocol_version, "protocol_version must be 1");
    }

    if (!isValidIdentifier(m.scope)) {
        result.add(.scope, "scope must be 1-64 lowercase alphanumeric or hyphen characters");
    }

    if (!isValidIdentifier(m.name)) {
        result.add(.name, "name must be 1-64 lowercase alphanumeric or hyphen characters");
    }

    if (!isValidSemver(m.version)) {
        result.add(.version, "version must be valid semver (e.g. 1.0.0)");
    }

    if (m.layer > 2) {
        result.add(.layer, "layer must be 0, 1, or 2");
    }

    return result;
}

// ── Validation Helpers ──

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        if (!isLowerAlphanumOrHyphen(c)) return false;
    }
    return true;
}

fn isLowerAlphanumOrHyphen(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
}

fn isValidSemver(s: []const u8) bool {
    if (s.len == 0) return false;

    var version_part = s;
    for (s, 0..) |c, i| {
        if (c == '-') {
            version_part = s[0..i];
            break;
        }
    }

    var dots: usize = 0;
    var segment_len: usize = 0;
    for (version_part) |c| {
        if (c == '.') {
            if (segment_len == 0) return false;
            dots += 1;
            segment_len = 0;
        } else if (c >= '0' and c <= '9') {
            segment_len += 1;
        } else {
            return false;
        }
    }
    if (segment_len == 0) return false;
    return dots == 2;
}

// ── ZON Parsing — zero allocation, slices into source ──

pub const ParseError = error{ InvalidZon, MissingField };

/// Parse a zpm.pkg.zon from raw source bytes. All returned string fields
/// are slices into the original source — zero allocation.
pub fn parseFromSource(source: []const u8) ParseError!PackageManifest {
    var m = PackageManifest{
        .protocol_version = 0,
        .scope = "",
        .name = "",
        .version = "0.0.0",
        .layer = 0,
    };

    // Required fields
    m.protocol_version = @intCast(findZonIntField(source, ".protocol_version") orelse 0);
    m.scope = findZonStringField(source, ".scope") orelse "";
    m.name = findZonStringField(source, ".name") orelse "";

    // Optional fields
    if (findZonStringField(source, ".version")) |v| m.version = v;
    if (findZonIntField(source, ".layer")) |l| {
        if (l >= 0 and l <= 3) m.layer = @intCast(l);
    }
    if (findZonEnumField(source, ".platform")) |p| {
        m.platform = parsePlatform(p);
    }
    if (findZonStringField(source, ".description")) |d| m.description = d;
    if (findZonStringField(source, ".license")) |l| m.license = l;
    if (findZonStringField(source, ".repository")) |r| m.repository = r;

    // Array fields
    m.system_libraries = findZonStringArray(source, ".system_libraries", &syslib_store);
    m.zpm_dependencies = findZonStringArray(source, ".zpm_dependencies", &zpmdep_store);
    m.exports = findZonStringArray(source, ".exports", &exports_store);

    // Constraints sub-struct
    if (findZonBoolField(source, ".no_allocator")) |v| m.constraints.no_allocator = v;
    if (findZonBoolField(source, ".no_std_io")) |v| m.constraints.no_std_io = v;

    return m;
}

// ── Static storage for parsed arrays (module-level, no allocator) ──

const max_array_entries = 32;
var syslib_store: [max_array_entries][]const u8 = undefined;
var zpmdep_store: [max_array_entries][]const u8 = undefined;
var exports_store: [max_array_entries][]const u8 = undefined;

// ── ZON Field Helpers ──

/// Find `.field_name = "value"` in ZON source, return the value slice.
fn findZonStringField(source: []const u8, field_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + field_name.len < source.len) : (i += 1) {
        if (!startsWith(source[i..], field_name)) continue;
        var j = i + field_name.len;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '=') continue;
        j += 1;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '"') continue;
        j += 1;
        const val_start = j;
        while (j < source.len and source[j] != '"') {
            if (source[j] == '\\') j += 1;
            j += 1;
        }
        return source[val_start..j];
    }
    return null;
}

/// Find `.field_name = number` in ZON source, return the integer value.
fn findZonIntField(source: []const u8, field_name: []const u8) ?i64 {
    var i: usize = 0;
    while (i + field_name.len < source.len) : (i += 1) {
        if (!startsWith(source[i..], field_name)) continue;
        var j = i + field_name.len;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '=') continue;
        j += 1;
        j = skipZonWs(source, j);
        if (j >= source.len) continue;
        // Must be a digit (not a quote or dot — those are strings/enums)
        if (source[j] < '0' or source[j] > '9') continue;
        var result: i64 = 0;
        while (j < source.len and source[j] >= '0' and source[j] <= '9') : (j += 1) {
            result = result * 10 + @as(i64, source[j] - '0');
        }
        return result;
    }
    return null;
}

/// Find `.field_name = true/false` in ZON source.
fn findZonBoolField(source: []const u8, field_name: []const u8) ?bool {
    var i: usize = 0;
    while (i + field_name.len < source.len) : (i += 1) {
        if (!startsWith(source[i..], field_name)) continue;
        var j = i + field_name.len;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '=') continue;
        j += 1;
        j = skipZonWs(source, j);
        if (j + 4 <= source.len and startsWith(source[j..], "true")) return true;
        if (j + 5 <= source.len and startsWith(source[j..], "false")) return false;
    }
    return null;
}

/// Find `.field_name = .enum_value` in ZON source, return the enum name.
fn findZonEnumField(source: []const u8, field_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + field_name.len < source.len) : (i += 1) {
        if (!startsWith(source[i..], field_name)) continue;
        var j = i + field_name.len;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '=') continue;
        j += 1;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '.') continue;
        j += 1;
        const val_start = j;
        while (j < source.len and isIdentChar(source[j])) : (j += 1) {}
        if (j == val_start) continue;
        return source[val_start..j];
    }
    return null;
}

/// Find `.field_name = .{ "a", "b" }` in ZON source, write strings to out buffer.
/// Returns a slice of the out buffer with the found strings.
fn findZonStringArray(source: []const u8, field_name: []const u8, out: *[max_array_entries][]const u8) []const []const u8 {
    var i: usize = 0;
    while (i + field_name.len < source.len) : (i += 1) {
        if (!startsWith(source[i..], field_name)) continue;
        var j = i + field_name.len;
        j = skipZonWs(source, j);
        if (j >= source.len or source[j] != '=') continue;
        j += 1;
        j = skipZonWs(source, j);
        // Expect `.{`
        if (j + 1 >= source.len or source[j] != '.' or source[j + 1] != '{') continue;
        j += 2;

        var count: usize = 0;
        while (j < source.len and source[j] != '}') : (j += 1) {
            if (source[j] == '"') {
                j += 1;
                const elem_start = j;
                while (j < source.len and source[j] != '"') {
                    if (source[j] == '\\') j += 1;
                    j += 1;
                }
                if (count < max_array_entries) {
                    out[count] = source[elem_start..j];
                    count += 1;
                }
            }
        }
        return out[0..count];
    }
    return out[0..0];
}

fn parsePlatform(s: []const u8) Platform {
    if (strEql(s, "windows")) return .windows;
    if (strEql(s, "linux")) return .linux;
    if (strEql(s, "macos")) return .macos;
    return .any;
}

fn skipZonWs(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) : (i += 1) {}
    return i;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return strEql(haystack[0..needle.len], needle);
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ── Tests ──

const std = @import("std");
const testing = std.testing;

test "validate: valid manifest passes" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "core",
        .version = "0.1.0",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(result.ok());
}

test "validate: wrong protocol_version" {
    const m = PackageManifest{
        .protocol_version = 2,
        .scope = "zpm",
        .name = "core",
        .version = "0.1.0",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(!result.ok());
    try testing.expectEqual(@as(usize, 1), result.count);
    try testing.expectEqual(ValidationField.protocol_version, result.slice()[0].field);
}

test "validate: invalid scope — uppercase" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "Zpm",
        .name = "core",
        .version = "0.1.0",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationField.scope, result.slice()[0].field);
}

test "validate: invalid scope — empty" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "",
        .name = "core",
        .version = "0.1.0",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationField.scope, result.slice()[0].field);
}

test "validate: invalid name — too long" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "a" ** 65,
        .version = "0.1.0",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationField.name, result.slice()[0].field);
}

test "validate: invalid version — not semver" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "core",
        .version = "1.0",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationField.version, result.slice()[0].field);
}

test "validate: valid semver with prerelease" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "core",
        .version = "1.0.0-alpha.1",
        .layer = 0,
    };
    const result = validate(&m);
    try testing.expect(result.ok());
}

test "validate: layer 3 rejected" {
    const m = PackageManifest{
        .protocol_version = 1,
        .scope = "zpm",
        .name = "core",
        .version = "0.1.0",
        .layer = 3,
    };
    const result = validate(&m);
    try testing.expect(!result.ok());
    try testing.expectEqual(ValidationField.layer, result.slice()[0].field);
}

test "validate: multiple errors reported" {
    const m = PackageManifest{
        .protocol_version = 0,
        .scope = "",
        .name = "INVALID",
        .version = "bad",
        .layer = 3,
    };
    const result = validate(&m);
    try testing.expectEqual(@as(usize, 5), result.count);
}

test "isValidSemver: valid versions" {
    try testing.expect(isValidSemver("0.0.0"));
    try testing.expect(isValidSemver("1.2.3"));
    try testing.expect(isValidSemver("10.20.30"));
    try testing.expect(isValidSemver("0.1.0-beta"));
}

test "isValidSemver: invalid versions" {
    try testing.expect(!isValidSemver(""));
    try testing.expect(!isValidSemver("1"));
    try testing.expect(!isValidSemver("1.0"));
    try testing.expect(!isValidSemver("1.0."));
    try testing.expect(!isValidSemver(".1.0"));
    try testing.expect(!isValidSemver("1.0.0.0"));
    try testing.expect(!isValidSemver("a.b.c"));
}

test "parseFromSource: valid manifest" {
    const source =
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "zpm",
        \\    .name = "window",
        \\    .version = "0.1.0",
        \\    .layer = 1,
        \\    .platform = .windows,
        \\    .system_libraries = .{ "kernel32", "gdi32" },
        \\    .zpm_dependencies = .{ "@zpm/win32", "@zpm/gl" },
        \\    .exports = .{ "window" },
        \\    .constraints = .{
        \\        .no_allocator = true,
        \\        .no_std_io = true,
        \\    },
        \\}
    ;
    const m = try parseFromSource(source);

    try testing.expectEqual(@as(u32, 1), m.protocol_version);
    try testing.expectEqualStrings("zpm", m.scope);
    try testing.expectEqualStrings("window", m.name);
    try testing.expectEqualStrings("0.1.0", m.version);
    try testing.expectEqual(@as(u2, 1), m.layer);
    try testing.expectEqual(Platform.windows, m.platform);
    try testing.expectEqual(@as(usize, 2), m.system_libraries.len);
    try testing.expectEqual(@as(usize, 2), m.zpm_dependencies.len);
    try testing.expectEqual(@as(usize, 1), m.exports.len);
    try testing.expect(m.constraints.no_allocator);
    try testing.expect(m.constraints.no_std_io);
}

test "parseFromSource: minimal manifest" {
    const source =
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "zpm",
        \\    .name = "core",
        \\    .layer = 0,
        \\}
    ;
    const m = try parseFromSource(source);

    try testing.expectEqual(@as(u32, 1), m.protocol_version);
    try testing.expectEqualStrings("zpm", m.scope);
    try testing.expectEqualStrings("core", m.name);
    try testing.expectEqual(@as(u2, 0), m.layer);
    try testing.expectEqual(Platform.any, m.platform);
    try testing.expectEqual(@as(usize, 0), m.system_libraries.len);
    try testing.expect(!m.constraints.no_allocator);
}

test "parseFromSource + validate round-trip" {
    const source =
        \\.{
        \\    .protocol_version = 1,
        \\    .scope = "myorg",
        \\    .name = "chart-overlay",
        \\    .version = "0.2.0",
        \\    .layer = 2,
        \\    .platform = .windows,
        \\    .constraints = .{ .no_allocator = true },
        \\}
    ;
    const m = try parseFromSource(source);
    const result = validate(&m);
    try testing.expect(result.ok());
}

// ── Property Tests ──

test "property: manifest field validation rejects invalid inputs (randomized)" {
    // Property 12: Generate scopes/names with invalid chars, lengths > 64,
    // and empty strings — verify the validator always rejects them.
    //
    // Validates: Requirements 1.3, 1.4

    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();

    const valid_chars = "abcdefghijklmnopqrstuvwxyz0123456789-";
    const invalid_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+=[]{}|;:',.<>?/~ ";

    var name_buf: [128]u8 = undefined;

    const iterations = 500;
    for (0..iterations) |i| {
        const category = i % 5;
        var scope: []const u8 = "zpm";
        var name_val: []const u8 = "core";
        var version: []const u8 = "1.0.0";
        var protocol_version: u32 = 1;
        const layer: u2 = 0;

        switch (category) {
            0 => {
                scope = "";
            },
            1 => {
                const len = rand.intRangeAtMost(usize, 1, 10);
                for (0..len) |j| {
                    name_buf[j] = invalid_chars[rand.intRangeLessThan(usize, 0, invalid_chars.len)];
                }
                scope = name_buf[0..len];
            },
            2 => {
                const len = rand.intRangeAtMost(usize, 65, 128);
                for (0..len) |j| {
                    name_buf[j] = valid_chars[rand.intRangeLessThan(usize, 0, valid_chars.len)];
                }
                name_val = name_buf[0..len];
            },
            3 => {
                const bad_versions = [_][]const u8{ "", "1", "1.0", "abc", "1.0.", ".1.0", "1.0.0.0" };
                version = bad_versions[rand.intRangeLessThan(usize, 0, bad_versions.len)];
            },
            4 => {
                protocol_version = rand.intRangeAtMost(u32, 2, 100);
            },
            else => unreachable,
        }

        const m = PackageManifest{
            .protocol_version = protocol_version,
            .scope = scope,
            .name = name_val,
            .version = version,
            .layer = layer,
        };
        const result = validate(&m);

        if (result.ok()) {
            std.debug.print("Property 12 failed: validator accepted invalid manifest (category {}):\n", .{category});
            std.debug.print("  scope='{s}' name='{s}' version='{s}' proto={} layer={}\n", .{ scope, name_val, version, protocol_version, layer });
            return error.TestUnexpectedResult;
        }
    }
}

test "property: manifest parse round-trip preserves fields (randomized)" {
    // Property 22: Generate valid manifests, serialize to ZON string,
    // parse back via parseFromSource, verify all fields match.
    //
    // Validates: Requirement 1.1

    var prng = std.Random.DefaultPrng.init(0xBEEF_F00D);
    const rand = prng.random();

    const alpha = "abcdefghijklmnopqrstuvwxyz0123456789";
    const platforms = [_]Platform{ .windows, .linux, .macos, .any };
    const platform_strs = [_][]const u8{ ".windows", ".linux", ".macos", ".any" };

    const iterations = 200;
    for (0..iterations) |_| {
        var scope_buf: [16]u8 = undefined;
        const scope_len = rand.intRangeAtMost(usize, 1, 16);
        for (0..scope_len) |j| {
            scope_buf[j] = alpha[rand.intRangeLessThan(usize, 0, alpha.len)];
        }
        const scope = scope_buf[0..scope_len];

        var name_buf_inner: [16]u8 = undefined;
        const name_len = rand.intRangeAtMost(usize, 1, 16);
        for (0..name_len) |j| {
            name_buf_inner[j] = alpha[rand.intRangeLessThan(usize, 0, alpha.len)];
        }
        const name_val = name_buf_inner[0..name_len];

        var ver_buf: [32]u8 = undefined;
        const major = rand.intRangeAtMost(u32, 0, 99);
        const minor = rand.intRangeAtMost(u32, 0, 99);
        const patch = rand.intRangeAtMost(u32, 0, 99);
        const ver_len = std.fmt.bufPrint(&ver_buf, "{}.{}.{}", .{ major, minor, patch }) catch unreachable;

        const layer: u2 = @intCast(rand.intRangeAtMost(u32, 0, 2));

        const plat_idx = rand.intRangeLessThan(usize, 0, platforms.len);
        const plat_str = platform_strs[plat_idx];
        const expected_platform = platforms[plat_idx];

        const no_alloc = rand.boolean();
        const no_io = rand.boolean();

        var zon_buf: [1024]u8 = undefined;
        const zon_src = std.fmt.bufPrint(&zon_buf,
            \\.{{
            \\    .protocol_version = 1,
            \\    .scope = "{s}",
            \\    .name = "{s}",
            \\    .version = "{s}",
            \\    .layer = {d},
            \\    .platform = {s},
            \\    .constraints = .{{
            \\        .no_allocator = {s},
            \\        .no_std_io = {s},
            \\    }},
            \\}}
        , .{
            scope,
            name_val,
            ver_len,
            @as(u32, layer),
            plat_str,
            if (no_alloc) "true" else "false",
            if (no_io) "true" else "false",
        }) catch unreachable;

        const m = parseFromSource(zon_src) catch |err| {
            std.debug.print("Property 22: parseFromSource failed for ZON:\n{s}\nerror: {}\n", .{ zon_src, err });
            return err;
        };

        try testing.expectEqual(@as(u32, 1), m.protocol_version);
        try testing.expectEqualStrings(scope, m.scope);
        try testing.expectEqualStrings(name_val, m.name);
        try testing.expectEqualStrings(ver_len, m.version);
        try testing.expectEqual(layer, m.layer);
        try testing.expectEqual(expected_platform, m.platform);
        try testing.expectEqual(no_alloc, m.constraints.no_allocator);
        try testing.expectEqual(no_io, m.constraints.no_std_io);

        const vr = validate(&m);
        if (!vr.ok()) {
            std.debug.print("Property 22: valid manifest failed validation:\n{s}\n", .{zon_src});
            for (vr.slice()) |e| {
                std.debug.print("  {s}: {s}\n", .{ @tagName(e.field), e.message });
            }
            return error.TestUnexpectedResult;
        }
    }
}
