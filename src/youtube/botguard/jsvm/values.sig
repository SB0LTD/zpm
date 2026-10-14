// @zpm/youtube/botguard/jsvm/values — JavaScript Value Types
//
// Defines the runtime value representation for the JS interpreter.
// Uses a tagged union (NaN-boxing would be more efficient but less readable).
// Fixed-size value pool — no heap allocator.
const std = @import("std");

/// ECMAScript Number::toString in base ten. Use shortest round-trip digits,
/// then apply JS's decimal/exponent thresholds to a caller-provided buffer.
/// Integer byte/index conversions stay on a small arithmetic fast path.
pub fn numberToString(n: f64, buf: []u8) usize {
    if (buf.len < 32) return 0;
    if (n != n) { @memcpy(buf[0..3], "NaN"); return 3; }
    if (n == 0) { buf[0] = '0'; return 1; }
    const negative = n < 0;
    const magnitude = if (negative) -n else n;
    var used: usize = 0;
    if (negative) { buf[0] = '-'; used = 1; }
    if (magnitude == std.math.inf(f64)) { @memcpy(buf[used..][0..8], "Infinity"); return used + 8; }
    if (magnitude <= 9007199254740991 and magnitude == @floor(magnitude)) {
        var v: u64 = @intFromFloat(magnitude);
        var digits: [16]u8 = undefined;
        var count: usize = 0;
        while (v > 0) : (v /= 10) { digits[count] = @intCast('0' + v % 10); count += 1; }
        while (count > 0) { count -= 1; buf[used] = digits[count]; used += 1; }
        return used;
    }
    var scratch: [32]u8 = undefined;
    const scientific = std.fmt.bufPrint(&scratch, "{e}", .{magnitude}) catch return 0;
    var digits: [24]u8 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (at < scientific.len and scientific[at] != 'e') : (at += 1) {
        if (scientific[at] == '.') continue;
        digits[count] = scientific[at]; count += 1;
    }
    at += 1;
    var exponent_negative = false;
    if (at < scientific.len and (scientific[at] == '-' or scientific[at] == '+')) { exponent_negative = scientific[at] == '-'; at += 1; }
    var exponent: i32 = 0;
    while (at < scientific.len) : (at += 1) exponent = exponent * 10 + scientific[at] - '0';
    if (exponent_negative) exponent = -exponent;
    if (exponent < -6 or exponent >= 21) {
        buf[used] = digits[0]; used += 1;
        if (count > 1) { buf[used] = '.'; used += 1; @memcpy(buf[used..][0..count-1], digits[1..count]); used += count-1; }
        buf[used] = 'e'; used += 1;
        buf[used] = if (exponent < 0) '-' else '+'; used += 1;
        var e: u32 = @intCast(if (exponent < 0) -exponent else exponent);
        var reversed: [3]u8 = undefined; var len: usize = 0;
        while (e > 0) : (e /= 10) { reversed[len] = @intCast('0' + e % 10); len += 1; }
        while (len > 0) { len -= 1; buf[used] = reversed[len]; used += 1; }
        return used;
    }
    const point = exponent + 1;
    if (point <= 0) {
        buf[used] = '0'; buf[used+1] = '.'; used += 2;
        var zeros = -point;
        while (zeros > 0) : (zeros -= 1) { buf[used] = '0'; used += 1; }
        @memcpy(buf[used..][0..count], digits[0..count]); return used + count;
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(point)) or i < count) : (i += 1) {
        if (i == point) { buf[used] = '.'; used += 1; }
        buf[used] = if (i < count) digits[i] else '0'; used += 1;
    }
    return used;
}

/// Maximum number of live values in the VM at once.
pub const MAX_VALUES: usize = 65536;

// Runtime object coercion is supplied by the object layer, which owns internal
// slots. Keeping this callback here avoids importing objects back into values.
pub var object_number: ?*const fn (u32) f64 = null;

/// Maximum string storage (all interned strings).
// Source decompression creates immutable prefixes before eval consumes the
// completed text. Keep these in a bounded arena; no string may be silently
// truncated or turned into the empty string when the arena is exhausted.
pub const MAX_STRING_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_STRINGS: usize = 262144;
const STRING_HASH_SLOTS: usize = MAX_STRINGS * 2;

/// JavaScript value type tags.
pub const ValueType = enum(u8) {
    undefined,
    null_val,
    boolean,
    number,
    string, // index into string table
    object, // index into object table
    function, // index into function table
    array, // index into object table (arrays are objects)
    symbol,
};

/// A JavaScript value (16 bytes).
pub const Value = extern struct {
    tag: ValueType,
    _pad: [3]u8 = .{ 0, 0, 0 },
    data: extern union {
        boolean: u32, // 0 or 1
        number: f64,
        str_idx: u32, // index into string pool
        obj_idx: u32, // index into object pool
        func_idx: u32, // index into function pool
    },

    pub const UNDEFINED = Value{ .tag = .undefined, .data = .{ .number = 0 } };
    pub const NULL = Value{ .tag = .null_val, .data = .{ .number = 0 } };
    pub const TRUE = Value{ .tag = .boolean, .data = .{ .boolean = 1 } };
    pub const FALSE = Value{ .tag = .boolean, .data = .{ .boolean = 0 } };

    pub fn number(n: f64) Value {
        return .{ .tag = .number, .data = .{ .number = n } };
    }

    pub fn string(idx: u32) Value {
        return .{ .tag = .string, .data = .{ .str_idx = idx } };
    }

    pub fn object(idx: u32) Value {
        return .{ .tag = .object, .data = .{ .obj_idx = idx } };
    }

    pub fn function(idx: u32) Value {
        return .{ .tag = .function, .data = .{ .func_idx = idx } };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self.tag) {
            .undefined, .null_val => false,
            .boolean => self.data.boolean != 0,
            .number => self.data.number != 0.0 and self.data.number == self.data.number, // NaN is falsy
            .string => getStringLen(self.data.str_idx) > 0,
            .object, .array, .function => true,
            .symbol => true,
        };
    }

    pub fn toNumber(self: Value) f64 {
        return switch (self.tag) {
            .undefined => @as(f64, @bitCast(@as(u64, 0x7FF8000000000000))), // NaN
            .null_val => 0.0,
            .boolean => if (self.data.boolean != 0) 1.0 else 0.0,
            .number => self.data.number,
            .string => parseNumberFromString(self.data.str_idx),
            .object, .array, .function => if (object_number) |convert| convert(self.data.obj_idx) else @as(f64, @bitCast(@as(u64, 0x7FF8000000000000))),
            else => @as(f64, @bitCast(@as(u64, 0x7FF8000000000000))), // NaN
        };
    }
};

// ── String pool ──

var string_pool: [MAX_STRING_BYTES]u8 = undefined;
var string_offsets: [MAX_STRINGS]u32 = undefined;
var string_lengths: [MAX_STRINGS]u32 = undefined;
var string_unit_lengths: [MAX_STRINGS]u32 = undefined;
var string_checkpoint_starts: [MAX_STRINGS]u32 = undefined;
// Non-ASCII strings index every 64 UTF-16 units. ASCII indexing stays O(1),
// and arbitrary Unicode indexing scans at most 63 units, with no heap storage.
var string_checkpoints: [MAX_STRING_BYTES / 64]u32 = undefined;
var checkpoint_used: u32 = 0;
// Zero means vacant, otherwise index + 1. At most 50% occupied.
var string_hash_slots: [STRING_HASH_SLOTS]u32 = [_]u32{0} ** STRING_HASH_SLOTS;
var n_strings: u32 = 0;
var pool_used: u32 = 0;
pub var exhausted: bool = false;
pub fn stringCount() u32 { return n_strings; }
pub fn stringBytesUsed() u32 { return pool_used; }

/// Intern a string, return its index.
pub fn internString(text: []const u8) u32 {
    // Canonical WTF-8 keeps each UTF-16 unit independently addressable,
    // including lone surrogates. Astral UTF-8 input becomes two surrogate units.
    // Normalize only when needed and stage into unused caller-owned arena space.
    var scan: usize = 0;
    while (scan < text.len) {
        const before = scan;
        const cp = readCodePoint(text, &scan);
        if (cp > 0xFFFF or (cp >= 128 and scan == before + 1)) {
            var used: usize = 0; var at: usize = 0;
            while (at < text.len) {
                const point = readCodePoint(text, &at);
                if (point > 0xFFFF) {
                    const shifted = point - 0x10000;
                    const first = encodeCodeUnit(@intCast(0xD800 + (shifted >> 10)), string_pool[pool_used+used..]);
                    if (first == 0) { exhausted = true; return 0; } used += first;
                    const second = encodeCodeUnit(@intCast(0xDC00 + (shifted & 1023)), string_pool[pool_used+used..]);
                    if (second == 0) { exhausted = true; return 0; } used += second;
                } else {
                    const len = encodeCodeUnit(@intCast(point), string_pool[pool_used+used..]);
                    if (len == 0) { exhausted = true; return 0; } used += len;
                }
            }
            return internCanonical(string_pool[pool_used..][0..used]);
        }
    }
    return internCanonical(text);
}
fn internCanonical(text: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (text) |c| hash = (hash ^ c) *% 16777619;
    var slot: usize = hash & (STRING_HASH_SLOTS - 1);
    while (string_hash_slots[slot] != 0) {
        const i = string_hash_slots[slot] - 1;
        if (string_lengths[i] == text.len) {
            const off = string_offsets[i];
            if (eqlBytes(string_pool[off .. off + text.len], text)) return i;
        }
        slot = (slot + 1) & (STRING_HASH_SLOTS - 1);
    }

    // Add new string
    if (n_strings >= MAX_STRINGS or text.len > MAX_STRING_BYTES - pool_used) {
        exhausted = true;
        return 0; // VM observes exhausted and stops before consuming this value.
    }

    const idx = n_strings;
    string_offsets[idx] = pool_used;
    string_lengths[idx] = @intCast(text.len);
    if (string_pool[pool_used..].ptr != text.ptr) @memcpy(string_pool[pool_used .. pool_used + text.len], text);
    var ascii = true;
    for (text) |ch| if (ch >= 128) { ascii = false; break; };
    string_checkpoint_starts[idx] = checkpoint_used;
    if (ascii) string_unit_lengths[idx] = @intCast(text.len) else {
        var at: usize = 0; var units: u32 = 0;
        while (at < text.len) {
            if (units > 0 and units % 64 == 0) {
                if (checkpoint_used == string_checkpoints.len) { exhausted = true; return 0; }
                string_checkpoints[checkpoint_used] = @intCast(at); checkpoint_used += 1;
            }
            _ = readCodePoint(text, &at); units += 1;
        }
        string_unit_lengths[idx] = units;
    }
    pool_used += @intCast(text.len);
    n_strings += 1;
    string_hash_slots[slot] = idx + 1;
    return @intCast(idx);
}

/// Get the text of an interned string.
pub fn getString(idx: u32) []const u8 {
    if (idx >= n_strings) return "";
    const off = string_offsets[idx];
    const len = string_lengths[idx];
    return string_pool[off .. off + len];
}

/// Get string length.
pub fn getStringLen(idx: u32) usize {
    if (idx >= n_strings) return 0;
    return string_lengths[idx];
}
pub fn getStringUnitLength(idx: u32) usize {
    return if (idx < n_strings) string_unit_lengths[idx] else 0;
}
pub fn stringUnitByteOffset(idx: u32, unit: usize) usize {
    if (idx >= n_strings) return 0;
    const text = getString(idx);
    const units = string_unit_lengths[idx];
    if (unit >= units) return text.len;
    if (units == text.len) return unit;
    const group = unit / 64;
    var at: usize = if (group == 0) 0 else string_checkpoints[string_checkpoint_starts[idx] + group - 1];
    var i = group * 64;
    while (i < unit) : (i += 1) _ = readCodePoint(text, &at);
    return at;
}
pub fn getStringCodeUnit(idx: u32, unit: usize) ?u16 {
    if (unit >= getStringUnitLength(idx)) return null;
    var at = stringUnitByteOffset(idx, unit);
    return @intCast(readCodePoint(getString(idx), &at));
}
pub fn getStringUnit(idx: u32, unit: usize) u32 {
    if (unit >= getStringUnitLength(idx)) return internString("");
    const text = getString(idx);
    const start = stringUnitByteOffset(idx, unit);
    var end = start; _ = readCodePoint(text, &end);
    return internString(text[start..end]);
}
pub fn sliceStringUnits(idx: u32, start: usize, end: usize) u32 {
    const text = getString(idx);
    const from = stringUnitByteOffset(idx, start);
    const to = stringUnitByteOffset(idx, @max(start, end));
    return internString(text[from..to]);
}
pub fn encodeCodeUnit(unit: u16, out: []u8) usize {
    const size: usize = if (unit < 128) 1 else if (unit < 2048) 2 else 3;
    if (out.len < size) return 0;
    if (size == 1) out[0] = @intCast(unit) else if (size == 2) {
        out[0] = @intCast(0xC0 | (unit >> 6)); out[1] = @intCast(0x80 | (unit & 63));
    } else {
        out[0] = @intCast(0xE0 | (unit >> 12)); out[1] = @intCast(0x80 | ((unit >> 6) & 63)); out[2] = @intCast(0x80 | (unit & 63));
    }
    return size;
}
fn readCodePoint(text: []const u8, at: *usize) u32 {
    const first = text[at.*]; at.* += 1;
    if (first < 128) return first;
    const size: usize = if (first >= 0xC2 and first <= 0xDF) 2 else if (first >= 0xE0 and first <= 0xEF) 3 else if (first >= 0xF0 and first <= 0xF4) 4 else return first;
    if (size - 1 > text.len - at.*) return first;
    var cp: u32 = first & @as(u8, if (size == 2) 31 else if (size == 3) 15 else 7);
    for (text[at.*..][0..size-1]) |ch| { if (ch < 128 or ch >= 192) return first; cp = (cp << 6) | (ch & 63); }
    if (cp < (if (size == 2) @as(u32, 128) else if (size == 3) @as(u32, 2048) else @as(u32, 65536)) or cp > 0x10FFFF) return first;
    at.* += size - 1;
    return cp;
}


/// Reset the value system (for new execution).
pub fn reset() void {
    n_strings = 0;
    pool_used = 0;
    checkpoint_used = 0;
    exhausted = false;
    @memset(&string_hash_slots, 0);
    // Pre-intern common strings
    _ = internString(""); // index 0 = empty string
    _ = internString("undefined"); // index 1
    _ = internString("null"); // index 2
    _ = internString("true"); // index 3
    _ = internString("false"); // index 4
    _ = internString("object"); // index 5
    _ = internString("function"); // index 6
    _ = internString("number"); // index 7
    _ = internString("string"); // index 8
    _ = internString("boolean"); // index 9
    _ = internString("prototype"); // index 10
    _ = internString("constructor"); // index 11
    _ = internString("length"); // index 12
    _ = internString("toString"); // index 13
    _ = internString("valueOf"); // index 14
}

// ── Helpers ──

fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

fn parseNumberFromString(idx: u32) f64 {
    const text = getString(idx);
    const nan = @as(f64, @bitCast(@as(u64, 0x7FF8000000000000)));
    // JS ToNumber(String): trim leading/trailing whitespace. An empty or
    // whitespace-only string is 0. A string that is not a valid numeric literal
    // is NaN (NOT 0) — e.g. `Number("abc")` and `"abc" == 0` (false). The old
    // digit-scan returned 0 for any non-numeric string, so `<string> == 0`
    // wrongly became true, corrupting BotGuard guards like `H==0&&(K=H)`.
    var s: usize = 0;
    var e: usize = text.len;
    while (s < e and isWs(text[s])) s += 1;
    while (e > s and isWs(text[e - 1])) e -= 1;
    if (s == e) return 0.0; // empty / all-whitespace -> 0
    const t = text[s..e];

    // Optional leading sign.
    var i: usize = 0;
    var sign: f64 = 1;
    if (t[i] == '-') { sign = -1; i += 1; } else if (t[i] == '+') i += 1;
    if (i >= t.len) return nan; // just a sign -> NaN

    // Hex / octal / binary integer literals (no sign allowed by spec, but we
    // already consumed an optional sign; JS ToNumber actually forbids sign for
    // 0x/0o/0b — a signed one yields NaN. Keep it simple: only unsigned form.)
    if (sign == 1 and i == 0 and t.len > 2 and t[0] == '0') {
        const radix: ?u8 = switch (t[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |rdx| {
            var hv: f64 = 0;
            var k: usize = 2;
            if (k >= t.len) return nan;
            while (k < t.len) : (k += 1) {
                const d = hexDigitVal(t[k], rdx) orelse return nan;
                hv = hv * @as(f64, @floatFromInt(rdx)) + @as(f64, @floatFromInt(d));
            }
            return hv;
        }
    }

    // Validate the JS decimal grammar before the correctly-rounded converter;
    // it also accepts inf/nan spellings which JS ToNumber must reject.
    if (std.mem.eql(u8, t[i..], "Infinity")) return sign * std.math.inf(f64);
    var saw_digit = false;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_digit = true;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return nan;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
        const exponent_start = i;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {}
        if (i == exponent_start) return nan;
    }
    if (i != t.len) return nan;
    return parseDecimal(t);
}

pub fn parseDecimal(text: []const u8) f64 {
    return std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn hexDigitVal(c: u8, radix: u8) ?u8 {
    const v: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return null,
    };
    if (v >= radix) return null;
    return v;
}


