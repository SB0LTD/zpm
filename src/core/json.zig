// Minimal JSON helpers — no allocator, no heap
// Layer 0: Foundation
//
// Operates on raw byte slices. Finds keys, extracts string/number/bool values.
// Handles nested objects by key path (e.g. find "k" then find "t" within it).
// Sufficient for flat/shallow JSON like config files and streaming messages.

const std = @import("std");

/// Find the position just after a key match (after the closing quote of the key).
/// Searches for "key" pattern in the data.
pub fn findKey(data: []const u8, key: []const u8) ?usize {
    if (data.len < key.len) return null;
    for (0..data.len - key.len + 1) |i| {
        if (std.mem.eql(u8, data[i..][0..key.len], key)) {
            return i + key.len;
        }
    }
    return null;
}

/// Extract a JSON string value for a given key: "key": "value"
/// Returns the content between quotes.
pub fn getString(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = findKey(data, key) orelse return null;
    // Skip colon, whitespace, and opening quote
    var i = pos;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return null;
    i += 1; // skip opening quote
    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    return data[start..i];
}

/// Extract a JSON float value. Handles both quoted ("1.5") and unquoted (1.5) numbers.
pub fn getFloat(data: []const u8, key: []const u8) ?f64 {
    const pos = findKey(data, key) orelse return null;
    var i = pos;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len) return null;
    // Skip optional quote
    if (data[i] == '"') i += 1;
    const start = i;
    while (i < data.len and data[i] != '"' and data[i] != ',' and data[i] != '}' and data[i] != ' ' and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
    return parseFloat(data[start..i]);
}

/// Extract a JSON integer value. Handles both quoted and unquoted.
pub fn getInt(data: []const u8, key: []const u8) ?i64 {
    const pos = findKey(data, key) orelse return null;
    var i = pos;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len) return null;
    if (data[i] == '"') i += 1;
    var result: i64 = 0;
    var neg = false;
    if (i < data.len and data[i] == '-') {
        neg = true;
        i += 1;
    }
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, data[i] - '0');
    }
    return if (neg) -result else result;
}
/// Extract a JSON boolean value for a given key.
pub fn getBool(data: []const u8, key: []const u8) bool {
    const pos = findKey(data, key) orelse return false;
    var i = pos;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i + 4 <= data.len and std.mem.eql(u8, data[i .. i + 4], "true")) return true;
    return false;
}

/// Parse a float from a byte slice (no allocator).
pub fn parseFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var result: f64 = 0;
    var frac: f64 = 0;
    var frac_div: f64 = 1;
    var in_frac = false;
    var neg = false;
    var i: usize = 0;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] == '.') {
            in_frac = true;
        } else if (s[i] >= '0' and s[i] <= '9') {
            const d: f64 = @floatFromInt(s[i] - '0');
            if (in_frac) {
                frac_div *= 10;
                frac += d / frac_div;
            } else {
                result = result * 10 + d;
            }
        } else break;
    }
    result += frac;
    return if (neg) -result else result;
}

/// Find the extent of a JSON object starting at a given position.
/// Returns the slice from the opening { to the matching }.
pub fn findObject(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = findKey(data, key) orelse return null;
    var i = pos;
    while (i < data.len and data[i] != '{') : (i += 1) {}
    if (i >= data.len) return null;
    const start = i;
    var depth: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '{') depth += 1;
        if (data[i] == '}') {
            depth -= 1;
            if (depth == 0) return data[start .. i + 1];
        }
    }
    return null;
}

/// Check if `data` starts with `pat`. Useful for streaming JSON parsers
/// that scan for known key patterns without full tokenization.
pub fn matchBytes(data: []const u8, pat: []const u8) bool {
    if (data.len < pat.len) return false;
    for (pat, 0..) |c, i| {
        if (data[i] != c) return false;
    }
    return true;
}

/// Parse a bare integer from a byte slice (no key lookup).
pub fn getIntFromSlice(s: []const u8) i64 {
    var result: i64 = 0;
    var neg = false;
    var i: usize = 0;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        i = 1;
    }
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, s[i] - '0');
    }
    return if (neg) -result else result;
}
