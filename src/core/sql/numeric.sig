//! Exact NUMERIC values (Layer 0, design §4.2, Q02).
//!
//! A value is a signed decimal coefficient with a display scale:
//! value = coef x 10^-dscale. The coefficient is held in four 64-bit limbs
//! and must stay below 10^digits (Config.numeric_digits, at most 76, default
//! 64): a result that needs more significant digits raises NumericCapacity
//! (54000), a documented capacity limit where PostgreSQL would continue.
//! Rounding is half away from zero, division and modulo scales follow
//! PostgreSQL's select_div_scale / mod_var, NUMERIC(p,s) typmods follow
//! PostgreSQL 15+ (negative scales allowed; precision above `digits` is a
//! capacity error at DDL), and NaN / +-Infinity are supported (NaN sorts
//! after every other value; NaN = NaN). There is no negative zero.
//! PostgreSQL's base-10000 representation (weight, first digit, ndigits) is
//! derived on demand for select_div_scale and the binary wire format.
const types = @import("types.sig");
const Error = types.Error;

pub const Special = enum(u8) { finite, nan, pinf, ninf };

pub const max_display_scale: i32 = 1000;
/// Capacity limit on a stored display scale (PostgreSQL allows 1000); a
/// formatted value is at most format_bytes long.
pub const max_scale: usize = 120;
pub const format_bytes: usize = 200;
/// NUMERIC_MIN_SIG_DIGITS in PostgreSQL's select_div_scale.
const min_sig_digits: i32 = 16;

pub const Numeric = struct {
    limbs: [4]u64 = @splat(0),
    dscale: u16 = 0,
    negative: bool = false,
    special: Special = .finite,

    pub fn coef(self: *const Numeric) u256 {
        return @bitCast(self.limbs);
    }

    pub fn setCoef(self: *Numeric, value: u256) void {
        self.limbs = @bitCast(value);
        if (value == 0) self.negative = false;
    }

    pub fn isZero(self: *const Numeric) bool {
        return self.special == .finite and self.coef() == 0;
    }
};

pub const pow10 = blk: {
    var table: [155]u512 = undefined;
    table[0] = 1;
    for (1..table.len) |index| table[index] = table[index - 1] * 10;
    break :blk table;
};

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

/// Decimal digits of a value (0 has zero digits).
pub fn digitCount(value: u512) usize {
    var count: usize = 0;
    while (count < pow10.len and value >= pow10[count]) count += 1;
    return count;
}

pub fn nan() Numeric {
    return .{ .special = .nan };
}

const pow10_wide = blk: {
    @setEvalBranchQuota(100000);
    var table: [200]u1024 = undefined;
    table[0] = 1;
    for (1..table.len) |index| table[index] = table[index - 1] * 10;
    break :blk table;
};

fn rankOf(value: *const Numeric) i8 {
    return switch (value.special) {
        .ninf => -2,
        .finite => 0,
        .pinf => 2,
        .nan => 3,
    };
}

/// btree order: -Infinity < finite < Infinity < NaN; NaN = NaN.
pub fn compareValues(a: *const Numeric, b: *const Numeric) i8 {
    const ra = rankOf(a);
    const rb = rankOf(b);
    if (ra != rb) return if (ra < rb) -1 else 1;
    if (a.special != .finite) return 0;
    const scale = @max(a.dscale, b.dscale);
    const left: u1024 = @as(u1024, a.coef()) * pow10_wide[scale - a.dscale];
    const right: u1024 = @as(u1024, b.coef()) * pow10_wide[scale - b.dscale];
    const sa: i8 = if (left == 0) 0 else if (a.negative) -1 else 1;
    const sb: i8 = if (right == 0) 0 else if (b.negative) -1 else 1;
    if (sa != sb) return if (sa < sb) -1 else 1;
    if (left == right) return 0;
    const greater = left > right;
    return if (greater == (sa > 0)) 1 else -1;
}

/// Hash key consistent with compareValues (trailing fractional zeros ignored).
pub fn numeric_hash(value: *const Numeric) [5]u64 {
    if (value.special != .finite) return .{ @intFromEnum(value.special), 0, 0, 0, 0 };
    var raw = value.coef();
    var scale: u64 = value.dscale;
    while (scale > 0 and raw != 0 and raw % 10 == 0) {
        raw /= 10;
        scale -= 1;
    }
    if (raw == 0) scale = 0;
    const limbs: [4]u64 = @bitCast(raw);
    return .{ scale | (@as(u64, @intFromBool(value.negative and raw != 0)) << 32), limbs[0], limbs[1], limbs[2], limbs[3] };
}

pub fn Ops(comptime digits: usize) type {
    if (digits == 0 or digits > 76) @compileError("numeric_digits must be 1..76");
    const limit: u512 = pow10[digits];
    return struct {
        pub const max_digits = digits;

        fn make(value: u512, dscale: usize, negative: bool) Error!Numeric {
            if (value >= limit) return error.NumericCapacity;
            if (dscale > max_scale) return error.NumericCapacity;
            var out: Numeric = .{ .dscale = @intCast(dscale), .negative = negative };
            out.setCoef(@intCast(value));
            return out;
        }

        pub fn fromInt(value: i64) Numeric {
            var out: Numeric = .{ .negative = value < 0 };
            const magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
            out.setCoef(magnitude);
            return out;
        }

        /// numeric_in: surrounding whitespace, sign, digits with an optional
        /// point and exponent, or NaN / [+-]Infinity / [+-]inf.
        pub fn parse(input: []const u8) Error!Numeric {
            var start: usize = 0;
            var end = input.len;
            while (start < end and space(input[start])) start += 1;
            while (end > start and space(input[end - 1])) end -= 1;
            const text = input[start..end];
            if (insensitive(text, "nan")) return nan();
            var index: usize = 0;
            var negative = false;
            if (index < text.len and (text[index] == '+' or text[index] == '-')) {
                negative = text[index] == '-';
                index += 1;
            }
            const rest = text[index..];
            if (insensitive(rest, "infinity") or insensitive(rest, "inf")) return .{ .special = if (negative) .ninf else .pinf };
            var value: u512 = 0;
            var significant: usize = 0;
            var fraction: usize = 0;
            var seen_digit = false;
            var seen_point = false;
            var previous_underscore = false;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (byte == '.') {
                    if (seen_point or previous_underscore) return error.InvalidTextRepresentation;
                    seen_point = true;
                    continue;
                }
                if (byte == '_') {
                    // PostgreSQL 16+: single underscores between digits.
                    if (!seen_digit or previous_underscore or index + 1 == text.len or !types.digit(text[index + 1])) return error.InvalidTextRepresentation;
                    previous_underscore = true;
                    continue;
                }
                if (!types.digit(byte)) break;
                previous_underscore = false;
                seen_digit = true;
                if (seen_point) fraction += 1;
                if (value != 0 or byte != '0') significant += 1;
                if (significant > digits + 2) return error.NumericCapacity;
                value = value * 10 + (byte - '0');
            }
            if (!seen_digit) return error.InvalidTextRepresentation;
            var exponent: i64 = 0;
            if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
                index += 1;
                var exponent_negative = false;
                if (index < text.len and (text[index] == '+' or text[index] == '-')) {
                    exponent_negative = text[index] == '-';
                    index += 1;
                }
                const exponent_start = index;
                while (index < text.len and types.digit(text[index])) : (index += 1) {
                    exponent = exponent * 10 + (text[index] - '0');
                    if (exponent > 1000) return error.NumericValueOutOfRange;
                }
                if (index == exponent_start) return error.InvalidTextRepresentation;
                if (exponent_negative) exponent = -exponent;
            }
            if (index != text.len) return error.InvalidTextRepresentation;
            var scale: i64 = @as(i64, @intCast(fraction)) - exponent;
            if (scale < 0) {
                const shift: usize = @intCast(-scale);
                if (value != 0) {
                    if (shift >= pow10.len or digitCount(value) + shift > digits) return error.NumericCapacity;
                    value *= pow10[shift];
                }
                scale = 0;
            }
            if (scale > max_display_scale) return error.NumericValueOutOfRange;
            return make(value, @intCast(scale), negative);
        }

        /// numeric_out.
        pub fn format(value: *const Numeric, out: []u8) []const u8 {
            switch (value.special) {
                .nan => return copy(out, "NaN"),
                .pinf => return copy(out, "Infinity"),
                .ninf => return copy(out, "-Infinity"),
                .finite => {},
            }
            var reversed: [format_bytes]u8 = undefined;
            var count: usize = 0;
            var magnitude: u256 = value.coef();
            while (magnitude != 0 or count <= value.dscale) {
                reversed[count] = @intCast('0' + magnitude % 10);
                magnitude /= 10;
                count += 1;
                if (count == reversed.len) break;
            }
            // `count` digits, at least dscale + 1 (a leading integer zero).
            var at: usize = 0;
            if (value.negative and value.coef() != 0) {
                out[at] = '-';
                at += 1;
            }
            var position = count;
            while (position > 0) {
                position -= 1;
                if (position + 1 == value.dscale and value.dscale != 0) {
                    out[at] = '.';
                    at += 1;
                }
                out[at] = reversed[position];
                at += 1;
            }
            return out[0..at];
        }

        fn copy(out: []u8, text: []const u8) []const u8 {
            @memcpy(out[0..text.len], text);
            return out[0..text.len];
        }

        /// Coefficient scaled to `scale` decimals (scale >= dscale).
        fn scaled(value: *const Numeric, scale: usize) Error!u512 {
            const shift = scale - value.dscale;
            if (shift >= pow10.len) return error.NumericCapacity;
            const raw: u512 = value.coef();
            if (raw != 0 and digitCount(raw) + shift > 150) return error.NumericCapacity;
            return raw * pow10[shift];
        }

        pub const compare = compareValues;
        pub const hashKey = numeric_hash;

        pub fn negate(value: Numeric) Numeric {
            var out = value;
            switch (value.special) {
                .pinf => out.special = .ninf,
                .ninf => out.special = .pinf,
                .nan => {},
                .finite => out.negative = !value.negative and value.coef() != 0,
            }
            return out;
        }

        fn infinite(negative: bool) Numeric {
            return .{ .special = if (negative) .ninf else .pinf };
        }

        fn sign(value: *const Numeric) i8 {
            return switch (value.special) {
                .ninf => -1,
                .pinf => 1,
                .nan => 0,
                .finite => if (value.coef() == 0) 0 else if (value.negative) -1 else 1,
            };
        }

        fn signedAdd(a: u512, an: bool, b: u512, bn: bool, scale: usize) Error!Numeric {
            if (an == bn) return make(a + b, scale, an);
            if (a >= b) return make(a - b, scale, an);
            return make(b - a, scale, bn);
        }

        pub fn add(a: *const Numeric, b: *const Numeric) Error!Numeric {
            if (a.special == .nan or b.special == .nan) return nan();
            if (a.special != .finite or b.special != .finite) {
                if (a.special != .finite and b.special != .finite and a.special != b.special) return nan();
                return if (a.special != .finite) a.* else b.*;
            }
            const scale: usize = @max(a.dscale, b.dscale);
            return signedAdd(try scaled(a, scale), a.negative, try scaled(b, scale), b.negative, scale);
        }

        pub fn sub(a: *const Numeric, b: *const Numeric) Error!Numeric {
            const negated = negate(b.*);
            return add(a, &negated);
        }

        pub fn mul(a: *const Numeric, b: *const Numeric) Error!Numeric {
            if (a.special == .nan or b.special == .nan) return nan();
            if (a.special != .finite or b.special != .finite) {
                const product = sign(a) * sign(b);
                if (product == 0) return nan();
                return infinite(product < 0);
            }
            const scale: usize = @as(usize, a.dscale) + b.dscale;
            const product = @as(u512, a.coef()) * @as(u512, b.coef());
            return make(product, scale, a.negative != b.negative);
        }

        /// PostgreSQL's base-10000 weight and first digit of a non-zero value.
        pub fn baseWeight(value: *const Numeric) struct { weight: i32, first: u32 } {
            const raw: u512 = value.coef();
            if (raw == 0) return .{ .weight = 0, .first = 0 };
            // Decimal exponent of the leading digit.
            const exponent: i32 = @as(i32, @intCast(digitCount(raw))) - 1 - @as(i32, value.dscale);
            const weight = @divFloor(exponent, 4);
            // first = floor(|v| / 10000^weight) mod 10000.
            const shift: i32 = 4 * weight + @as(i32, value.dscale);
            const whole: u512 = if (shift >= 0) raw / pow10[@intCast(shift)] else raw * pow10[@intCast(-shift)];
            return .{ .weight = weight, .first = @intCast(whole % 10000) };
        }

        /// select_div_scale.
        pub fn divScale(a: *const Numeric, b: *const Numeric) i32 {
            const left = baseWeight(a);
            const right = baseWeight(b);
            var qweight = left.weight - right.weight;
            if (left.first <= right.first) qweight -= 1;
            var rscale: i32 = min_sig_digits - qweight * 4;
            rscale = @max(rscale, @as(i32, a.dscale));
            rscale = @max(rscale, @as(i32, b.dscale));
            rscale = @max(rscale, 0);
            return @min(rscale, max_display_scale);
        }

        /// Quotient of coefficients rounded (or truncated) to `rscale`.
        fn quotient(a: *const Numeric, b: *const Numeric, rscale: usize, rounding: bool) Error!Numeric {
            const shift: i64 = @as(i64, @intCast(rscale)) + b.dscale - @as(i64, a.dscale);
            var numerator: u512 = a.coef();
            var denominator: u512 = b.coef();
            if (shift >= 0) {
                if (shift >= pow10.len or (numerator != 0 and digitCount(numerator) + @as(usize, @intCast(shift)) > 150)) return error.NumericCapacity;
                numerator *= pow10[@intCast(shift)];
            } else {
                if (-shift >= pow10.len or digitCount(denominator) + @as(usize, @intCast(-shift)) > 150) return error.NumericCapacity;
                denominator *= pow10[@intCast(-shift)];
            }
            var q = numerator / denominator;
            const r = numerator % denominator;
            if (rounding and r != 0 and r >= denominator - r) q += 1;
            return make(q, rscale, a.negative != b.negative);
        }

        pub fn div(a: *const Numeric, b: *const Numeric) Error!Numeric {
            if (a.special == .nan or b.special == .nan) return nan();
            if (b.special == .finite and b.coef() == 0) return error.DivisionByZero;
            if (a.special != .finite) {
                if (b.special != .finite) return nan();
                return infinite((a.special == .ninf) != (sign(b) < 0));
            }
            if (b.special != .finite) return .{};
            return quotient(a, b, @intCast(divScale(a, b)), true);
        }

        /// numeric % numeric: x - trunc(x / y) * y, scale max(dscales).
        pub fn mod(a: *const Numeric, b: *const Numeric) Error!Numeric {
            if (a.special == .nan or b.special == .nan) return nan();
            if (b.special == .finite and b.coef() == 0) return error.DivisionByZero;
            if (a.special != .finite) return nan();
            if (b.special != .finite) return a.*;
            const scale: usize = @max(a.dscale, b.dscale);
            const left = try scaled(a, scale);
            const right = try scaled(b, scale);
            return make(left % right, scale, a.negative);
        }

        /// Round half away from zero to `scale` decimals (scale may be
        /// negative: round to 10^-scale); the result's dscale is max(scale, 0).
        pub fn round(value: *const Numeric, scale: i32) Error!Numeric {
            if (value.special != .finite) return value.*;
            const target: usize = @intCast(@max(scale, 0));
            var raw: u512 = value.coef();
            const current: i32 = value.dscale;
            if (scale >= current) {
                if (target > max_scale) return error.NumericCapacity;
                const shift = target - value.dscale;
                // Reject before widening arithmetic: a bounded coefficient
                // times 10^120 can overflow even the u512 intermediate.
                if (raw != 0 and digitCount(raw) + shift > digits) return error.NumericCapacity;
                return make(raw * pow10[shift], target, value.negative);
            }
            const drop_wide: i64 = @as(i64, current) - scale;
            if (drop_wide >= 150) return make(0, target, false);
            const drop: usize = @intCast(drop_wide);
            const unit = pow10[drop];
            const remainder = raw % unit;
            raw /= unit;
            if (remainder * 2 >= unit) raw += 1;
            if (scale < 0) raw *= pow10[@intCast(-scale)];
            return make(raw, target, value.negative);
        }

        pub const Typmod = struct { precision: i32, scale: i32 };

        pub fn encodeTypmod(precision: i32, scale: i32) Error!i32 {
            if (precision < 1 or precision > 1000) return error.InvalidParameterValue;
            if (scale < -1000 or scale > 1000) return error.InvalidParameterValue;
            if (precision > digits) return error.NumericCapacity;
            return ((precision << 16) | (scale & 0x7ff)) + 4;
        }

        pub fn decodeTypmod(typmod: i32) ?Typmod {
            if (typmod < 4) return null;
            const raw = typmod - 4;
            const low: i32 = raw & 0x7ff;
            return .{ .precision = (raw >> 16) & 0xffff, .scale = if (low >= 0x400) low - 0x800 else low };
        }

        /// NUMERIC(p,s) coercion: round to s, then at most p - s integer
        /// digits (22003); NaN passes, infinities do not.
        pub fn applyTypmod(value: *const Numeric, typmod: i32) Error!Numeric {
            const mod_value = decodeTypmod(typmod) orelse return value.*;
            if (value.special == .nan) return value.*;
            if (value.special != .finite) return error.NumericValueOutOfRange;
            const rounded = try round(value, mod_value.scale);
            const raw: u512 = rounded.coef();
            const integer_digits = @as(i32, @intCast(digitCount(raw))) - @as(i32, rounded.dscale);
            if (raw != 0 and integer_digits > mod_value.precision - mod_value.scale) return error.NumericValueOutOfRange;
            return rounded;
        }

        /// numeric -> int2/int4/int8: round half away, range check (22003);
        /// NaN and infinities cannot convert (0A000 in PostgreSQL).
        pub fn toInt(value: *const Numeric, low: i64, high: i64) Error!i64 {
            if (value.special != .finite) return error.UnsupportedStatement;
            const rounded = try round(value, 0);
            const raw: u512 = rounded.coef();
            if (raw > 9223372036854775808) return error.NumericValueOutOfRange;
            const magnitude: u64 = @intCast(raw);
            const result: i64 = if (rounded.negative)
                (if (magnitude == 9223372036854775808) -9223372036854775808 else -@as(i64, @intCast(magnitude)))
            else if (magnitude > 9223372036854775807) return error.NumericValueOutOfRange else @intCast(magnitude);
            if (result < low or result > high) return error.NumericValueOutOfRange;
            return result;
        }

        /// Base-10000 digits for the PostgreSQL binary format.
        pub const Base10000 = struct { digits: [40]u16 = @splat(0), ndigits: u16 = 0, weight: i16 = 0 };

        pub fn toBase10000(value: *const Numeric) Base10000 {
            var out: Base10000 = .{};
            if (value.special != .finite or value.coef() == 0) return out;
            // Align the fraction to a multiple of four digits.
            const pad: usize = (4 - value.dscale % 4) % 4;
            var raw: u512 = @as(u512, value.coef()) * pow10[pad];
            const fraction_groups: i32 = @intCast((value.dscale + pad) / 4);
            var groups: [40]u16 = undefined;
            var count: usize = 0;
            while (raw != 0) : (count += 1) {
                groups[count] = @intCast(raw % 10000);
                raw /= 10000;
            }
            // groups[0] is the least significant; weight of the top group.
            var first: usize = 0;
            while (first < count and groups[first] == 0) first += 1;
            const top: i32 = @as(i32, @intCast(count)) - 1 - fraction_groups;
            var position = count;
            while (position > first) {
                position -= 1;
                out.digits[out.ndigits] = groups[position];
                out.ndigits += 1;
            }
            out.weight = @intCast(top);
            return out;
        }

        /// Inverse of toBase10000 (binary input). Digits must be < 10000.
        pub fn fromBase10000(groups: []const u16, weight: i16, negative: bool, dscale: u16) Error!Numeric {
            var raw: u512 = 0;
            for (groups) |group| {
                if (group >= 10000) return error.InvalidTextRepresentation;
                if (digitCount(raw) > 140) return error.NumericCapacity;
                raw = raw * 10000 + group;
            }
            // value = raw * 10000^(weight - ndigits + 1); rescale to dscale.
            const exponent: i64 = 4 * (@as(i64, weight) - @as(i64, @intCast(groups.len)) + 1) + dscale;
            if (exponent >= 0) {
                if (raw != 0 and (exponent >= pow10.len or digitCount(raw) + @as(usize, @intCast(exponent)) > 150)) return error.NumericCapacity;
                if (raw != 0) raw *= pow10[@intCast(exponent)];
            } else {
                const drop: usize = @intCast(-exponent);
                if (drop >= pow10.len) raw = 0 else raw /= pow10[drop];
            }
            return make(raw, dscale, negative);
        }
    };
}
