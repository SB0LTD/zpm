// Layer 0 — JSON response parser for registry API responses.
//
// Converts registry JSON strings into typed structs needed by the
// resolver and commands. Uses minimal hand-written JSON parsing —
// no std.json dependency, no allocator for core parsing.
//
// Operates on raw byte slices with fixed-size output buffers.

const std = @import("std");
const resolver = @import("resolver.sig");
const registry = @import("registry.sig");

pub const ResolvedDep = resolver.ResolvedDep;

pub const SearchResult = struct {
    name: []const u8,
    description: []const u8,
    layer: u2,
};

// ── JSON Helpers ──

/// Find a string value for a given JSON key.
/// Searches for `"field_name"` followed by `:` and a quoted string value.
/// Returns the content between the value quotes, or null if not found.
pub fn findStringField(json: []const u8, field_name: []const u8) ?[]const u8 {
    // We need to find: "field_name" : "value"
    // Build the pattern: "field_name"
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        // Look for opening quote of a key
        if (json[i] != '"') continue;
        const key_start = i + 1;
        if (key_start + field_name.len >= json.len) return null;

        // Check if this key matches field_name
        if (!std.mem.eql(u8, json[key_start..][0..field_name.len], field_name)) continue;
        const after_key = key_start + field_name.len;
        if (after_key >= json.len or json[after_key] != '"') continue;

        // Skip past closing quote of key, then find colon
        var j = after_key + 1;
        j = skipWhitespace(json, j);
        if (j >= json.len or json[j] != ':') continue;
        j += 1;
        j = skipWhitespace(json, j);

        // Expect opening quote of value
        if (j >= json.len or json[j] != '"') continue;
        j += 1;
        const val_start = j;

        // Find closing quote (handle escaped quotes)
        while (j < json.len) : (j += 1) {
            if (json[j] == '\\') {
                j += 1; // skip escaped char
                continue;
            }
            if (json[j] == '"') break;
        }
        return json[val_start..j];
    }
    return null;
}

/// Find an integer value for a given JSON key.
/// Searches for `"field_name"` followed by `:` and a numeric value.
/// Returns the parsed integer, or null if not found.
pub fn findIntField(json: []const u8, field_name: []const u8) ?i64 {
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        const key_start = i + 1;
        if (key_start + field_name.len >= json.len) continue;

        if (!std.mem.eql(u8, json[key_start..][0..field_name.len], field_name)) continue;
        const after_key = key_start + field_name.len;
        if (after_key >= json.len or json[after_key] != '"') continue;

        var j = after_key + 1;
        j = skipWhitespace(json, j);
        if (j >= json.len or json[j] != ':') continue;
        j += 1;
        j = skipWhitespace(json, j);

        // Parse integer (possibly negative)
        if (j >= json.len) continue;
        var neg = false;
        if (json[j] == '-') {
            neg = true;
            j += 1;
        }
        if (j >= json.len or json[j] < '0' or json[j] > '9') continue;

        var result: i64 = 0;
        while (j < json.len and json[j] >= '0' and json[j] <= '9') : (j += 1) {
            result = result * 10 + @as(i64, json[j] - '0');
        }
        return if (neg) -result else result;
    }
    return null;
}

/// Find a JSON array for a given key and iterate its string elements.
/// Returns the number of string elements found, writing them into `out`.
/// Each element in `out` is a slice into the original `json` buffer.
pub fn findArrayField(json: []const u8, field_name: []const u8, out: [][]const u8) usize {
    // Find the key, then locate the '[' ... ']' array
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        const key_start = i + 1;
        if (key_start + field_name.len >= json.len) return 0;

        if (!std.mem.eql(u8, json[key_start..][0..field_name.len], field_name)) continue;
        const after_key = key_start + field_name.len;
        if (after_key >= json.len or json[after_key] != '"') continue;

        var j = after_key + 1;
        j = skipWhitespace(json, j);
        if (j >= json.len or json[j] != ':') continue;
        j += 1;
        j = skipWhitespace(json, j);

        // Expect opening bracket
        if (j >= json.len or json[j] != '[') continue;
        j += 1;

        // Parse string elements
        var count: usize = 0;
        while (j < json.len and json[j] != ']') : (j += 1) {
            if (json[j] == '"') {
                j += 1;
                const elem_start = j;
                while (j < json.len and json[j] != '"') : (j += 1) {
                    if (json[j] == '\\') j += 1;
                }
                if (count < out.len) {
                    out[count] = json[elem_start..j];
                    count += 1;
                }
                // j now points at closing quote, loop increment will advance past it
            }
        }
        return count;
    }
    return 0;
}

fn skipWhitespace(json: []const u8, start: usize) usize {
    var i = start;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    return i;
}

// ── Package Metadata Parser ──

/// Maximum number of system libraries or zpm dependencies per package.
const max_array_entries = 32;

/// Static storage for parsed array fields (avoids allocator).
/// These are module-level so the returned slices remain valid.
var syslib_buf: [max_array_entries][]const u8 = undefined;
var zpmdep_buf: [max_array_entries][]const u8 = undefined;

/// Parse a package metadata JSON response into a ResolvedDep.
///
/// JSON format:
/// ```json
/// {
///   "scope": "zpm",
///   "name": "core",
///   "version": "0.1.0",
///   "url": "https://...",
///   "hash": "1220abc...",
///   "layer": 0,
///   "system_libraries": ["kernel32"],
///   "zpm_dependencies": ["@zpm/win32"]
/// }
/// ```
///
/// Returns true on success, false if required fields are missing.
pub fn parsePackageMetadata(json: []const u8, out: *ResolvedDep) bool {
    const scope = findStringField(json, "scope") orelse return false;
    const name = findStringField(json, "name") orelse return false;
    const version = findStringField(json, "version") orelse return false;
    const url = findStringField(json, "url") orelse return false;
    const hash = findStringField(json, "hash") orelse return false;
    const layer_val = findIntField(json, "layer") orelse return false;

    if (layer_val < 0 or layer_val > 3) return false;

    const syslib_count = findArrayField(json, "system_libraries", &syslib_buf);
    const zpmdep_count = findArrayField(json, "zpm_dependencies", &zpmdep_buf);

    out.* = .{
        .scope = scope,
        .name = name,
        .version = version,
        .url = url,
        .hash = hash,
        .layer = @intCast(layer_val),
        .system_libraries = syslib_buf[0..syslib_count],
        .zpm_dependencies = zpmdep_buf[0..zpmdep_count],
        .is_direct = false,
    };
    return true;
}

// ── Search Results Parser ──

/// Parse a search results JSON array into SearchResult entries.
///
/// JSON format:
/// ```json
/// [
///   {"name": "@zpm/core", "description": "Core types", "layer": 0},
///   {"name": "@zpm/window", "description": "Window management", "layer": 1}
/// ]
/// ```
///
/// Returns the number of results parsed (up to `out.len`).
pub fn parseSearchResults(json: []const u8, out: []SearchResult) usize {
    if (json.len == 0) return 0;

    // Find the opening bracket
    var i: usize = 0;
    i = skipWhitespace(json, i);
    if (i >= json.len or json[i] != '[') return 0;
    i += 1;

    var count: usize = 0;

    // Parse each object in the array
    while (i < json.len and count < out.len) {
        i = skipWhitespace(json, i);
        if (i >= json.len) break;
        if (json[i] == ']') break;
        if (json[i] == ',') {
            i += 1;
            continue;
        }

        // Find the object boundaries { ... }
        if (json[i] != '{') {
            i += 1;
            continue;
        }
        const obj_start = i;
        var depth: usize = 0;
        var obj_end: usize = i;
        while (obj_end < json.len) : (obj_end += 1) {
            if (json[obj_end] == '{') depth += 1;
            if (json[obj_end] == '}') {
                depth -= 1;
                if (depth == 0) {
                    obj_end += 1;
                    break;
                }
            }
        }

        const obj = json[obj_start..obj_end];

        const name = findStringField(obj, "name") orelse {
            i = obj_end;
            continue;
        };
        const description = findStringField(obj, "description") orelse "";
        const layer_val = findIntField(obj, "layer") orelse 0;

        const clamped_layer: u2 = if (layer_val >= 0 and layer_val <= 3)
            @intCast(layer_val)
        else
            0;

        out[count] = .{
            .name = name,
            .description = description,
            .layer = clamped_layer,
        };
        count += 1;
        i = obj_end;
    }

    return count;
}

// ── Tests ──

const testing = std.testing;

// ── parsePackageMetadata tests ──

test "parsePackageMetadata: valid complete JSON" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","url":"https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz","hash":"1220abc123","layer":0,"system_libraries":[],"zpm_dependencies":[]}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(parsePackageMetadata(json, &dep));
    try testing.expectEqualStrings("zpm", dep.scope);
    try testing.expectEqualStrings("core", dep.name);
    try testing.expectEqualStrings("0.1.0", dep.version);
    try testing.expectEqualStrings("https://registry.zpm.dev/pkg/@zpm/core/0.1.0.tar.gz", dep.url);
    try testing.expectEqualStrings("1220abc123", dep.hash);
    try testing.expectEqual(@as(u2, 0), dep.layer);
    try testing.expectEqual(@as(usize, 0), dep.system_libraries.len);
    try testing.expectEqual(@as(usize, 0), dep.zpm_dependencies.len);
    try testing.expect(!dep.is_direct);
}

test "parsePackageMetadata: with system_libraries array" {
    const json =
        \\{"scope":"zpm","name":"window","version":"0.1.0","url":"url","hash":"hash","layer":1,"system_libraries":["kernel32","gdi32","user32","shell32"],"zpm_dependencies":[]}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(parsePackageMetadata(json, &dep));
    try testing.expectEqualStrings("zpm", dep.scope);
    try testing.expectEqualStrings("window", dep.name);
    try testing.expectEqual(@as(u2, 1), dep.layer);
    try testing.expectEqual(@as(usize, 4), dep.system_libraries.len);
    try testing.expectEqualStrings("kernel32", dep.system_libraries[0]);
    try testing.expectEqualStrings("gdi32", dep.system_libraries[1]);
    try testing.expectEqualStrings("user32", dep.system_libraries[2]);
    try testing.expectEqualStrings("shell32", dep.system_libraries[3]);
}

test "parsePackageMetadata: with zpm_dependencies array" {
    const json =
        \\{"scope":"zpm","name":"window","version":"0.1.0","url":"url","hash":"hash","layer":1,"system_libraries":["kernel32"],"zpm_dependencies":["@zpm/win32","@zpm/gl"]}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(parsePackageMetadata(json, &dep));
    try testing.expectEqual(@as(usize, 2), dep.zpm_dependencies.len);
    try testing.expectEqualStrings("@zpm/win32", dep.zpm_dependencies[0]);
    try testing.expectEqualStrings("@zpm/gl", dep.zpm_dependencies[1]);
}

test "parsePackageMetadata: with whitespace variations" {
    const json =
        \\{
        \\  "scope" : "myorg" ,
        \\  "name" : "chart-overlay" ,
        \\  "version" : "0.2.0" ,
        \\  "url" : "https://example.com/pkg.tar.gz" ,
        \\  "hash" : "1220def456" ,
        \\  "layer" : 2 ,
        \\  "system_libraries" : [] ,
        \\  "zpm_dependencies" : ["@zpm/gl"]
        \\}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(parsePackageMetadata(json, &dep));
    try testing.expectEqualStrings("myorg", dep.scope);
    try testing.expectEqualStrings("chart-overlay", dep.name);
    try testing.expectEqualStrings("0.2.0", dep.version);
    try testing.expectEqual(@as(u2, 2), dep.layer);
    try testing.expectEqual(@as(usize, 1), dep.zpm_dependencies.len);
    try testing.expectEqualStrings("@zpm/gl", dep.zpm_dependencies[0]);
}

test "parsePackageMetadata: extra fields are tolerated" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","url":"u","hash":"h","layer":0,"extra_field":"ignored","system_libraries":[],"zpm_dependencies":[],"published_at":1234567890}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(parsePackageMetadata(json, &dep));
    try testing.expectEqualStrings("zpm", dep.scope);
    try testing.expectEqualStrings("core", dep.name);
}

test "parsePackageMetadata: missing scope returns false" {
    const json =
        \\{"name":"core","version":"0.1.0","url":"u","hash":"h","layer":0}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: missing name returns false" {
    const json =
        \\{"scope":"zpm","version":"0.1.0","url":"u","hash":"h","layer":0}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: missing version returns false" {
    const json =
        \\{"scope":"zpm","name":"core","url":"u","hash":"h","layer":0}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: missing url returns false" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","hash":"h","layer":0}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: missing hash returns false" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","url":"u","layer":0}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: missing layer returns false" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","url":"u","hash":"h"}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: invalid layer value returns false" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","url":"u","hash":"h","layer":5}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: negative layer returns false" {
    const json =
        \\{"scope":"zpm","name":"core","version":"0.1.0","url":"u","hash":"h","layer":-1}
    ;
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata(json, &dep));
}

test "parsePackageMetadata: empty string returns false" {
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata("", &dep));
}

test "parsePackageMetadata: malformed JSON returns false" {
    var dep: ResolvedDep = undefined;
    try testing.expect(!parsePackageMetadata("not json at all", &dep));
    try testing.expect(!parsePackageMetadata("{broken", &dep));
    try testing.expect(!parsePackageMetadata("[]", &dep));
}

// ── parseSearchResults tests ──

test "parseSearchResults: valid array with multiple results" {
    const json =
        \\[{"name":"@zpm/core","description":"Core types","layer":0},{"name":"@zpm/window","description":"Window management","layer":1}]
    ;
    var results: [8]SearchResult = undefined;
    const count = parseSearchResults(json, &results);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("@zpm/core", results[0].name);
    try testing.expectEqualStrings("Core types", results[0].description);
    try testing.expectEqual(@as(u2, 0), results[0].layer);
    try testing.expectEqualStrings("@zpm/window", results[1].name);
    try testing.expectEqualStrings("Window management", results[1].description);
    try testing.expectEqual(@as(u2, 1), results[1].layer);
}

test "parseSearchResults: empty array" {
    var results: [8]SearchResult = undefined;
    const count = parseSearchResults("[]", &results);
    try testing.expectEqual(@as(usize, 0), count);
}

test "parseSearchResults: empty string returns 0" {
    var results: [8]SearchResult = undefined;
    const count = parseSearchResults("", &results);
    try testing.expectEqual(@as(usize, 0), count);
}

test "parseSearchResults: malformed JSON returns 0" {
    var results: [8]SearchResult = undefined;
    try testing.expectEqual(@as(usize, 0), parseSearchResults("not json", &results));
    try testing.expectEqual(@as(usize, 0), parseSearchResults("{}", &results));
    try testing.expectEqual(@as(usize, 0), parseSearchResults("[broken", &results));
}

test "parseSearchResults: with whitespace variations" {
    const json =
        \\[
        \\  {
        \\    "name" : "@zpm/gl" ,
        \\    "description" : "OpenGL bindings" ,
        \\    "layer" : 1
        \\  }
        \\]
    ;
    var results: [8]SearchResult = undefined;
    const count = parseSearchResults(json, &results);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("@zpm/gl", results[0].name);
    try testing.expectEqualStrings("OpenGL bindings", results[0].description);
    try testing.expectEqual(@as(u2, 1), results[0].layer);
}

test "parseSearchResults: output buffer limits results" {
    const json =
        \\[{"name":"a","description":"","layer":0},{"name":"b","description":"","layer":0},{"name":"c","description":"","layer":0}]
    ;
    var results: [2]SearchResult = undefined;
    const count = parseSearchResults(json, &results);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("a", results[0].name);
    try testing.expectEqualStrings("b", results[1].name);
}

test "parseSearchResults: missing name skips entry" {
    const json =
        \\[{"description":"no name","layer":0},{"name":"@zpm/core","description":"ok","layer":0}]
    ;
    var results: [8]SearchResult = undefined;
    const count = parseSearchResults(json, &results);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("@zpm/core", results[0].name);
}

// ── findStringField tests ──

test "findStringField: basic key-value" {
    const json =
        \\{"key":"value"}
    ;
    const val = findStringField(json, "key");
    try testing.expect(val != null);
    try testing.expectEqualStrings("value", val.?);
}

test "findStringField: missing key returns null" {
    const json =
        \\{"other":"value"}
    ;
    try testing.expect(findStringField(json, "missing") == null);
}

test "findStringField: empty JSON returns null" {
    try testing.expect(findStringField("", "key") == null);
    try testing.expect(findStringField("{}", "key") == null);
}

// ── findIntField tests ──

test "findIntField: positive integer" {
    const json =
        \\{"count":42}
    ;
    const val = findIntField(json, "count");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 42), val.?);
}

test "findIntField: zero" {
    const json =
        \\{"layer":0}
    ;
    const val = findIntField(json, "layer");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 0), val.?);
}

test "findIntField: negative integer" {
    const json =
        \\{"offset":-5}
    ;
    const val = findIntField(json, "offset");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, -5), val.?);
}

test "findIntField: missing key returns null" {
    const json =
        \\{"other":1}
    ;
    try testing.expect(findIntField(json, "missing") == null);
}

// ── findArrayField tests ──

test "findArrayField: string array" {
    const json =
        \\{"libs":["kernel32","gdi32","user32"]}
    ;
    var out: [8][]const u8 = undefined;
    const count = findArrayField(json, "libs", &out);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("kernel32", out[0]);
    try testing.expectEqualStrings("gdi32", out[1]);
    try testing.expectEqualStrings("user32", out[2]);
}

test "findArrayField: empty array" {
    const json =
        \\{"libs":[]}
    ;
    var out: [8][]const u8 = undefined;
    const count = findArrayField(json, "libs", &out);
    try testing.expectEqual(@as(usize, 0), count);
}

test "findArrayField: missing key returns 0" {
    const json =
        \\{"other":[]}
    ;
    var out: [8][]const u8 = undefined;
    const count = findArrayField(json, "missing", &out);
    try testing.expectEqual(@as(usize, 0), count);
}

test "findArrayField: output buffer limits elements" {
    const json =
        \\{"items":["a","b","c","d"]}
    ;
    var out: [2][]const u8 = undefined;
    const count = findArrayField(json, "items", &out);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("b", out[1]);
}
