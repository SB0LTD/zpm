// @zpm/youtube/botguard/jsvm/values — JavaScript Value Types
//
// Defines the runtime value representation for the JS interpreter.
// Uses a tagged union (NaN-boxing would be more efficient but less readable).
// Fixed-size value pool — no heap allocator.

/// Maximum number of live values in the VM at once.
pub const MAX_VALUES: usize = 65536;

/// Maximum string storage (all interned strings).
pub const MAX_STRING_BYTES: usize = 2 * 1024 * 1024; // 2 MB

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
var string_offsets: [65536]u32 = undefined; // offset into pool for each string
var string_lengths: [65536]u16 = undefined; // length of each string
var n_strings: u32 = 0;
var pool_used: u32 = 0;

/// Intern a string, return its index.
pub fn internString(text: []const u8) u32 {
    // Check if already interned (linear scan — could optimize with hash table)
    const tlen: u16 = @intCast(@min(text.len, 65535));
    for (0..n_strings) |i| {
        if (string_lengths[i] == tlen) {
            const off = string_offsets[i];
            if (eqlBytes(string_pool[off .. off + tlen], text[0..tlen])) {
                return @intCast(i);
            }
        }
    }

    // Add new string
    if (n_strings >= 65536 or pool_used + tlen > MAX_STRING_BYTES) {
        return 0; // out of space — return empty string index
    }

    const idx = n_strings;
    string_offsets[idx] = pool_used;
    string_lengths[idx] = tlen;
    @memcpy(string_pool[pool_used .. pool_used + tlen], text[0..tlen]);
    pool_used += tlen;
    n_strings += 1;
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
    if (text.len == 0) return 0.0;
    // Simple integer parsing (full parseFloat would be needed for BG)
    var val: f64 = 0;
    var sign: f64 = 1;
    var i: usize = 0;
    if (i < text.len and text[i] == '-') { sign = -1; i += 1; }
    if (i < text.len and text[i] == '+') i += 1;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        val = val * 10 + @as(f64, @floatFromInt(text[i] - '0'));
    }
    return sign * val;
}
