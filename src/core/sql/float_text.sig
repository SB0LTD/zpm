//! REAL / DOUBLE PRECISION text I/O and checked arithmetic (Layer 0, Q02).
//!
//! Input is checked against the float8in/float4in grammar measured on the
//! reference (musl strtod) BEFORE std.fmt.parseFloat sees it, after trimming
//! whitespace; letters match case-insensitively:
//!   decimal  [+-]?(digits.digits?|.digits|digits)([eE][+-]?digits)?
//!   hex      [+-]?0x(hex.hex?|.hex|hex)(p[+-]?digits)?
//!   special  [+-]?(Infinity|inf|NaN)
//! Anything else is 22P02; an overflow, or an underflow to zero of non-zero
//! digits, is 22003. Output is the shortest round-trip digits
//! (std.fmt.float.render) laid out like PostgreSQL's float8out/float4out with
//! extra_float_digits = 1: fixed notation for decimal exponents -4..14
//! (float4: -4..5), otherwise d.ddde+XX.
const std = @import("std");
const types = @import("types.sig");
const Error = types.Error;

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == 0x0b or byte == 0x0c;
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn insensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != y) return false;
    return true;
}

fn hexDigit(byte: u8) bool {
    return types.digit(byte) or (lower(byte) >= 'a' and lower(byte) <= 'f');
}

const Shape = struct { special: enum { none, inf, nan } = .none, negative: bool = false, nonzero: bool = false };

/// Grammar check; returns the trimmed text and its shape.
fn check(text: []const u8) Error!Shape {
    var out: Shape = .{};
    var index: usize = 0;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) {
        out.negative = text[index] == '-';
        index += 1;
    }
    const rest = text[index..];
    if (insensitive(rest, "infinity") or insensitive(rest, "inf")) {
        out.special = .inf;
        return out;
    }
    if (insensitive(rest, "nan")) {
        out.special = .nan;
        return out;
    }
    const hex = rest.len > 2 and rest[0] == '0' and lower(rest[1]) == 'x';
    if (hex) index += 2;
    const digitFn = if (hex) &hexDigit else &types.digit;
    var mantissa: usize = 0;
    while (index < text.len and digitFn(text[index])) : (index += 1) {
        mantissa += 1;
        if (text[index] != '0') out.nonzero = true;
    }
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and digitFn(text[index])) : (index += 1) {
            mantissa += 1;
            if (text[index] != '0') out.nonzero = true;
        }
    }
    if (mantissa == 0) return error.InvalidTextRepresentation;
    const marker: u8 = if (hex) 'p' else 'e';
    if (index < text.len and lower(text[index]) == marker) {
        index += 1;
        if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
        const start = index;
        while (index < text.len and types.digit(text[index])) index += 1;
        if (index == start) return error.InvalidTextRepresentation;
    }
    if (index != text.len) return error.InvalidTextRepresentation;
    return out;
}

/// float8in / float4in.
pub fn parse(comptime T: type, input: []const u8) Error!T {
    var start: usize = 0;
    var end = input.len;
    while (start < end and space(input[start])) start += 1;
    while (end > start and space(input[end - 1])) end -= 1;
    const text = input[start..end];
    const shape = try check(text);
    switch (shape.special) {
        .inf => return if (shape.negative) -inf(T) else inf(T),
        .nan => return nan(T),
        .none => {},
    }
    const value = std.fmt.parseFloat(T, text) catch return error.InvalidTextRepresentation;
    if (isInf(value)) return error.NumericValueOutOfRange;
    if (value == 0 and shape.nonzero) return error.NumericValueOutOfRange;
    return value;
}

/// float8out / float4out (extra_float_digits = 1: shortest exact digits).
pub fn format(comptime T: type, value: T, out: []u8) []const u8 {
    if (isNan(value)) return copy(out, "NaN");
    if (isInf(value)) return copy(out, if (value < 0) "-Infinity" else "Infinity");
    if (value == 0) return copy(out, if (signbit(value)) "-0" else "0");
    var buffer: [64]u8 = undefined;
    const scientific = std.fmt.float.render(&buffer, value, .{ .mode = .scientific }) catch unreachable;
    // scientific: [-]d[.ddd]e[-]x
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    const negative = scientific[0] == '-';
    if (negative) index = 1;
    while (index < scientific.len and scientific[index] != 'e') : (index += 1) {
        if (scientific[index] == '.') continue;
        digits[count] = scientific[index];
        count += 1;
    }
    index += 1;
    var exponent_negative = false;
    if (index < scientific.len and scientific[index] == '-') {
        exponent_negative = true;
        index += 1;
    }
    var exponent: i32 = 0;
    while (index < scientific.len) : (index += 1) exponent = exponent * 10 + (scientific[index] - '0');
    if (exponent_negative) exponent = -exponent;
    const fixed_limit: i32 = if (T == f32) 6 else 15;
    var at: usize = 0;
    if (negative) {
        out[0] = '-';
        at = 1;
    }
    if (exponent < -4 or exponent >= fixed_limit) {
        out[at] = digits[0];
        at += 1;
        if (count > 1) {
            out[at] = '.';
            at += 1;
            @memcpy(out[at..][0 .. count - 1], digits[1..count]);
            at += count - 1;
        }
        out[at] = 'e';
        out[at + 1] = if (exponent < 0) '-' else '+';
        at += 2;
        const magnitude: u32 = @intCast(if (exponent < 0) -exponent else exponent);
        if (magnitude >= 100) {
            out[at] = @intCast('0' + magnitude / 100);
            at += 1;
        }
        out[at] = @intCast('0' + (magnitude / 10) % 10);
        out[at + 1] = @intCast('0' + magnitude % 10);
        return out[0 .. at + 2];
    }
    if (exponent < 0) {
        const zeros: usize = @intCast(-exponent - 1);
        out[at] = '0';
        out[at + 1] = '.';
        at += 2;
        @memset(out[at..][0..zeros], '0');
        at += zeros;
        @memcpy(out[at..][0..count], digits[0..count]);
        return out[0 .. at + count];
    }
    const integer: usize = @intCast(exponent + 1);
    for (0..@max(integer, count)) |position| {
        if (position == integer) {
            out[at] = '.';
            at += 1;
        }
        out[at] = if (position < count) digits[position] else '0';
        at += 1;
    }
    return out[0..at];
}

fn copy(out: []u8, text: []const u8) []const u8 {
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

/// Scientific text of a finite value rounded to `significant` digits
/// (%.*e; float8_numeric uses DBL_DIG = 15, float4_numeric FLT_DIG = 6).
pub fn roundedText(comptime T: type, value: T, significant: usize, out: []u8) []const u8 {
    return std.fmt.float.render(out, value, .{ .mode = .scientific, .precision = significant - 1 }) catch unreachable;
}

pub fn isNan(value: anytype) bool {
    return value != value;
}

pub fn inf(comptime T: type) T {
    return if (T == f32) @as(f32, @bitCast(@as(u32, 0x7f800000))) else @as(f64, @bitCast(@as(u64, 0x7ff0000000000000)));
}

pub fn nan(comptime T: type) T {
    return if (T == f32) @as(f32, @bitCast(@as(u32, 0x7fc00000))) else @as(f64, @bitCast(@as(u64, 0x7ff8000000000000)));
}

pub fn isInf(value: anytype) bool {
    const T = @TypeOf(value);
    return value == inf(T) or value == -inf(T);
}

pub fn signbit(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == f32) return @as(u32, @bitCast(value)) >> 31 != 0;
    return @as(u64, @bitCast(value)) >> 63 != 0;
}

pub fn ArithmeticOf(comptime T: type) type {
    return struct {
        fn overflow(result: T, a: T, b: T) bool {
            return isInf(result) and !isInf(a) and !isInf(b);
        }

        pub fn add(a: T, b: T) Error!T {
            const result = a + b;
            if (overflow(result, a, b)) return error.NumericValueOutOfRange;
            return result;
        }

        pub fn sub(a: T, b: T) Error!T {
            const result = a - b;
            if (overflow(result, a, b)) return error.NumericValueOutOfRange;
            return result;
        }

        pub fn mul(a: T, b: T) Error!T {
            const result = a * b;
            if (overflow(result, a, b)) return error.NumericValueOutOfRange;
            if (result == 0 and a != 0 and b != 0) return error.NumericValueOutOfRange;
            return result;
        }

        pub fn div(a: T, b: T) Error!T {
            if (b == 0) return error.DivisionByZero;
            const result = a / b;
            if (isInf(result) and !isInf(a)) return error.NumericValueOutOfRange;
            if (result == 0 and a != 0 and !isInf(b)) return error.NumericValueOutOfRange;
            return result;
        }
    };
}

/// Portable rint(): nearest-even without libc or ambient rounding-mode state.
/// At/above 2^52 every finite float8 is integral; the same bit guard retains
/// NaNs and infinities. Smaller conversions are safely bounded inside i64.
pub fn rint(value: f64) f64 {
    const bits: u64 = @bitCast(value);
    if (bits & 0x7fff_ffff_ffff_ffff >= 0x4330_0000_0000_0000) return value;
    var whole: i64 = @intFromFloat(value);
    const fraction = value - @as(f64, @floatFromInt(whole));
    const distance = @abs(fraction);
    if (distance > 0.5 or (distance == 0.5 and whole & 1 != 0)) whole += if (fraction < 0) @as(i64, -1) else 1;
    // An integer cast loses the sign of zero, which ROUND(float8) retains.
    return if (whole == 0) @bitCast(bits & 0x8000_0000_0000_0000) else @floatFromInt(whole);
}

/// float -> integer cast (rint, range check 22003; NaN 22003).
pub fn toInt(value: f64, low: i64, high: i64) Error!i64 {
    if (isNan(value) or isInf(value)) return error.NumericValueOutOfRange;
    const rounded = rint(value);
    if (rounded < @as(f64, @floatFromInt(low)) or rounded > @as(f64, @floatFromInt(high))) return error.NumericValueOutOfRange;
    if (rounded >= 9223372036854775807.0) return error.NumericValueOutOfRange;
    return @intFromFloat(rounded);
}

/// btree float order: NaN after everything, NaN = NaN, -0 = 0.
pub fn compare(comptime T: type, a: T, b: T) i8 {
    const a_nan = isNan(a);
    const b_nan = isNan(b);
    if (a_nan or b_nan) return if (a_nan and b_nan) 0 else if (a_nan) 1 else -1;
    return if (a < b) -1 else if (a > b) 1 else 0;
}
