//! Additional catalog identifier types (Layer 0): pg_lsn and xid8, after
//! PostgreSQL's pg_lsn.c and xid8funcs.c.
//!
//! pg_lsn (OID 3220) is a 64-bit WAL position written as two hexadecimal
//! halves `X/Y` of one to eight digits each, with nothing else around them
//! (22P02 otherwise). Output is `%X/%X` (upper case, no zero padding).
//! xid8 (OID 5069) is a 64-bit full transaction id. Its input is
//! uint64in_subr: strtou64 with base 0 (decimal, 0x hex or 0 octal),
//! leading and trailing whitespace allowed, an optional sign (a negative
//! value wraps modulo 2^64, as strtoull does), 22003 on overflow and 22P02
//! otherwise. Output is unsigned decimal. Both compare as unsigned 64-bit
//! integers.
const types = @import("types.sig");
const Error = types.Error;

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// pg_lsn_in_internal.
pub fn parseLsn(input: []const u8) Error!u64 {
    var at: usize = 0;
    var high: u64 = 0;
    while (at < input.len and at < 9) : (at += 1) {
        const digit = hexDigit(input[at]) orelse break;
        high = high << 4 | digit;
    }
    const high_len = at;
    if (high_len < 1 or high_len > 8 or at == input.len or input[at] != '/') return error.InvalidTextRepresentation;
    at += 1;
    const start = at;
    var low: u64 = 0;
    while (at < input.len and at - start < 9) : (at += 1) {
        const digit = hexDigit(input[at]) orelse break;
        low = low << 4 | digit;
    }
    const low_len = at - start;
    if (low_len < 1 or low_len > 8 or at != input.len) return error.InvalidTextRepresentation;
    return high << 32 | low;
}

fn hexText(value: u32, buffer: []u8) usize {
    const digits = "0123456789ABCDEF";
    var scratch: [8]u8 = undefined;
    var index: usize = scratch.len;
    var rest = value;
    while (true) {
        index -= 1;
        scratch[index] = digits[rest & 15];
        rest >>= 4;
        if (rest == 0) break;
    }
    @memcpy(buffer[0 .. scratch.len - index], scratch[index..]);
    return scratch.len - index;
}

/// pg_lsn_out: `%X/%X` (at most 17 bytes).
pub fn formatLsn(value: u64, buffer: []u8) []const u8 {
    var at = hexText(@truncate(value >> 32), buffer);
    buffer[at] = '/';
    at += 1;
    at += hexText(@truncate(value), buffer[at..]);
    return buffer[0..at];
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

/// xid8in (uint64in_subr with strtou64(s, &end, 0)).
pub fn parseXid8(input: []const u8) Error!u64 {
    var at: usize = 0;
    while (at < input.len and space(input[at])) at += 1;
    var negative = false;
    if (at < input.len and (input[at] == '+' or input[at] == '-')) {
        negative = input[at] == '-';
        at += 1;
    }
    var base: u64 = 10;
    if (at + 1 < input.len and input[at] == '0' and (input[at + 1] == 'x' or input[at + 1] == 'X') and
        at + 2 < input.len and hexDigit(input[at + 2]) != null)
    {
        base = 16;
        at += 2;
    } else if (at < input.len and input[at] == '0') base = 8;
    const start = at;
    var value: u64 = 0;
    var overflow = false;
    while (at < input.len) : (at += 1) {
        const digit = hexDigit(input[at]) orelse break;
        if (digit >= base) break;
        const shifted = @mulWithOverflow(value, base);
        const added = @addWithOverflow(shifted[0], digit);
        if (shifted[1] != 0 or added[1] != 0) overflow = true;
        value = added[0];
    }
    if (at == start) return error.InvalidTextRepresentation;
    if (overflow) return error.NumericValueOutOfRange;
    while (at < input.len and space(input[at])) at += 1;
    if (at != input.len) return error.InvalidTextRepresentation;
    return if (negative) 0 -% value else value;
}

/// xid8out: unsigned decimal (at most 20 bytes).
pub fn formatXid8(value: u64, buffer: []u8) []const u8 {
    var scratch: [20]u8 = undefined;
    var index: usize = scratch.len;
    var rest = value;
    while (true) {
        index -= 1;
        scratch[index] = @intCast('0' + rest % 10);
        rest /= 10;
        if (rest == 0) break;
    }
    @memcpy(buffer[0 .. scratch.len - index], scratch[index..]);
    return buffer[0 .. scratch.len - index];
}
