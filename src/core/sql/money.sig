//! MONEY values (Layer 0), after PostgreSQL's cash.c with lc_monetary = C:
//! two fraction digits, `$` currency symbol, `,` thousands separator, `.`
//! decimal point and a leading `-` for negative amounts.
//!
//! A value is an i64 count of cents (-92233720368547758.08 through
//! 92233720368547758.07). cash_in accepts surrounding whitespace, `$` before
//! or after the sign, a leading `-`, `+` or `(`, `,` separators anywhere in
//! the digits, at most two kept fraction digits (a third rounds half up) and
//! trailing `)`, sign, `$` or whitespace; anything else is 22P02 and an
//! out-of-range amount 22003. Output is `$1,234.50` / `-$1,234.50`.
//! Arithmetic results outside the range are 22003; division by zero 22012.
const types = @import("types.sig");
const float_text = @import("float_text.sig");
const Error = types.Error;

/// 10^frac_digits.
pub const scale: i64 = 100;
pub const fraction_digits: usize = 2;
/// Longest output: sign, `$`, 17 integer digits with 5 separators, point, 2.
pub const text_bytes: usize = 28;

fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

pub fn parse(input: []const u8) Error!i64 {
    var at: usize = 0;
    var value: i64 = 0;
    var negative = false;
    const peek = struct {
        fn f(text: []const u8, index: usize) u8 {
            return if (index < text.len) text[index] else 0;
        }
    }.f;
    while (space(peek(input, at))) at += 1;
    if (peek(input, at) == '$') at += 1;
    while (space(peek(input, at))) at += 1;
    if (peek(input, at) == '-') {
        negative = true;
        at += 1;
    } else if (peek(input, at) == '(') {
        negative = true;
        at += 1;
    } else if (peek(input, at) == '+') at += 1;
    while (space(peek(input, at))) at += 1;
    if (peek(input, at) == '$') at += 1;
    while (space(peek(input, at))) at += 1;
    // Built in the negative, as cash_in does, so the minimum is reachable.
    var seen_dot = false;
    var decimals: usize = 0;
    while (at < input.len) : (at += 1) {
        const byte = input[at];
        if (digit(byte) and (!seen_dot or decimals < fraction_digits)) {
            const times = @mulWithOverflow(value, 10);
            if (times[1] != 0) return error.NumericValueOutOfRange;
            const next = @subWithOverflow(times[0], @as(i64, byte - '0'));
            if (next[1] != 0) return error.NumericValueOutOfRange;
            value = next[0];
            if (seen_dot) decimals += 1;
        } else if (byte == '.' and !seen_dot) {
            seen_dot = true;
        } else if (byte == ',') {
            // Thousands separator: ignored.
        } else break;
    }
    if (digit(peek(input, at)) and input[at] >= '5') {
        const rounded = @subWithOverflow(value, 1);
        if (rounded[1] != 0) return error.NumericValueOutOfRange;
        value = rounded[0];
    }
    while (decimals < fraction_digits) : (decimals += 1) {
        const times = @mulWithOverflow(value, 10);
        if (times[1] != 0) return error.NumericValueOutOfRange;
        value = times[0];
    }
    while (digit(peek(input, at))) at += 1;
    while (at < input.len) : (at += 1) {
        const byte = input[at];
        if (space(byte) or byte == ')' or byte == '+' or byte == '$') continue;
        if (byte == '-') {
            negative = true;
            continue;
        }
        return error.InvalidTextRepresentation;
    }
    if (negative) return value;
    if (value == -9223372036854775808) return error.NumericValueOutOfRange;
    return -value;
}

/// cash_out into `buffer` (at least text_bytes long).
pub fn format(value: i64, buffer: []u8) []const u8 {
    var digits: [32]u8 = undefined;
    var at: usize = digits.len;
    var magnitude: u64 = @abs(value);
    var position: i64 = @intCast(fraction_digits);
    while (true) {
        if (position == 0) {
            at -= 1;
            digits[at] = '.';
        } else if (position < 0 and @mod(position, 3) == 0) {
            at -= 1;
            digits[at] = ',';
        }
        at -= 1;
        digits[at] = @intCast('0' + magnitude % 10);
        magnitude /= 10;
        position -= 1;
        if (magnitude == 0 and position < 0) break;
    }
    var out: usize = 0;
    if (value < 0) {
        buffer[out] = '-';
        out += 1;
    }
    buffer[out] = '$';
    out += 1;
    @memcpy(buffer[out..][0 .. digits.len - at], digits[at..]);
    return buffer[0 .. out + digits.len - at];
}

/// The amount as plain decimal text for numeric_in (cash_numeric).
pub fn decimal(value: i64, buffer: *[32]u8) []const u8 {
    var at: usize = buffer.len;
    var magnitude: u64 = @abs(value);
    var position: usize = 0;
    while (true) {
        if (position == fraction_digits) {
            at -= 1;
            buffer[at] = '.';
        }
        at -= 1;
        buffer[at] = @intCast('0' + magnitude % 10);
        magnitude /= 10;
        position += 1;
        if (magnitude == 0 and position > fraction_digits) break;
    }
    if (value < 0) {
        at -= 1;
        buffer[at] = '-';
    }
    return buffer[at..];
}

/// int4_cash / int8_cash.
pub fn fromInteger(value: i64) Error!i64 {
    const product = @mulWithOverflow(value, scale);
    if (product[1] != 0) return error.NumericValueOutOfRange;
    return product[0];
}

pub fn add(a: i64, b: i64) Error!i64 {
    const sum = @addWithOverflow(a, b);
    if (sum[1] != 0) return error.NumericValueOutOfRange;
    return sum[0];
}

pub fn sub(a: i64, b: i64) Error!i64 {
    const difference = @subWithOverflow(a, b);
    if (difference[1] != 0) return error.NumericValueOutOfRange;
    return difference[0];
}

/// cash_mul_int8.
pub fn mulInteger(a: i64, b: i64) Error!i64 {
    const product = @mulWithOverflow(a, b);
    if (product[1] != 0) return error.NumericValueOutOfRange;
    return product[0];
}

/// cash_div_int8: C division, truncating toward zero.
pub fn divInteger(a: i64, b: i64) Error!i64 {
    if (b == 0) return error.DivisionByZero;
    if (a == -9223372036854775808 and b == -1) return error.NumericValueOutOfRange;
    return @divTrunc(a, b);
}

/// cash_mul_flt8 / cash_div_flt8: rint of the float result, range checked.
pub fn mulFloat(a: i64, b: f64) Error!i64 {
    return float_text.toInt(@as(f64, @floatFromInt(a)) * b, -9223372036854775808, 9223372036854775807);
}

pub fn divFloat(a: i64, b: f64) Error!i64 {
    if (b == 0) return error.DivisionByZero;
    return float_text.toInt(@as(f64, @floatFromInt(a)) / b, -9223372036854775808, 9223372036854775807);
}

/// cash_div_cash: a float8 ratio.
pub fn ratio(a: i64, b: i64) Error!f64 {
    if (b == 0) return error.DivisionByZero;
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
}
