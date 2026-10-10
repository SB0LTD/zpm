// @zpm/youtube/botguard/jsvm/values — JavaScript Value Types
//
// Defines the runtime value representation for the JS interpreter.
// Uses a tagged union (NaN-boxing would be more efficient but less readable).
// Fixed-size value pool — no heap allocator.

/// Maximum number of live values in the VM at once.
pub const MAX_VALUES: usize = 65536;

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
            else => @as(f64, @bitCast(@as(u64, 0x7FF8000000000000))), // NaN
        };
    }
};

// ── String pool ──

var string_pool: [MAX_STRING_BYTES]u8 = undefined;
var string_offsets: [MAX_STRINGS]u32 = undefined;
var string_lengths: [MAX_STRINGS]u32 = undefined;
// Zero means vacant, otherwise index + 1. At most 50% occupied.
var string_hash_slots: [STRING_HASH_SLOTS]u32 = [_]u32{0} ** STRING_HASH_SLOTS;
var n_strings: u32 = 0;
var pool_used: u32 = 0;
pub var exhausted: bool = false;
pub fn stringCount() u32 { return n_strings; }
pub fn stringBytesUsed() u32 { return pool_used; }

/// Intern a string, return its index.
pub fn internString(text: []const u8) u32 {
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
    @memcpy(string_pool[pool_used .. pool_used + text.len], text);
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


/// Reset the value system (for new execution).
pub fn reset() void {
    n_strings = 0;
    pool_used = 0;
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

    // Decimal: [digits][.digits][(e|E)[+/-]digits]
    var val: f64 = 0;
    var saw_digit = false;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
        val = val * 10 + @as(f64, @floatFromInt(t[i] - '0'));
        saw_digit = true;
    }
    if (i < t.len and t[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
            val += @as(f64, @floatFromInt(t[i] - '0')) * frac;
            frac *= 0.1;
            saw_digit = true;
        }
    }
    if (!saw_digit) return nan; // no mantissa digits -> NaN
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        var esign: f64 = 1;
        if (i < t.len and t[i] == '-') { esign = -1; i += 1; } else if (i < t.len and t[i] == '+') i += 1;
        var exp: f64 = 0;
        var saw_exp = false;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
            exp = exp * 10 + @as(f64, @floatFromInt(t[i] - '0'));
            saw_exp = true;
        }
        if (!saw_exp) return nan; // "1e" -> NaN
        val *= pow10(esign * exp);
    }
    // Any leftover (non-consumed) characters -> NaN.
    if (i != t.len) return nan;
    return sign * val;
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

fn pow10(p: f64) f64 {
    // Simple integer-exponent power of 10 (p is an integer value here).
    var result: f64 = 1;
    var n: i64 = @intFromFloat(if (p < 0) -p else p);
    while (n > 0) : (n -= 1) result *= 10;
    return if (p < 0) 1.0 / result else result;
}
