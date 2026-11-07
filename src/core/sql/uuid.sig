//! UUID text input and output (Layer 0), after PostgreSQL's uuid.c.
//!
//! uuid_in accepts 32 hex digits in either case, optionally enclosed in one
//! pair of braces, with a single hyphen allowed after any group of four
//! digits except the last. Nothing else, including surrounding whitespace,
//! is accepted (22P02). Output is the lowercase 8-4-4-4-12 form. Values are
//! 16 fixed bytes, compared bytewise (uuid_cmp is memcmp).
const types = @import("types.sig");
const Error = types.Error;

pub const Uuid = [16]u8;
pub const text_len: usize = 36;

fn nibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn parse(input: []const u8) Error!Uuid {
    var out: Uuid = undefined;
    var at: usize = 0;
    const braces = input.len != 0 and input[0] == '{';
    if (braces) at = 1;
    for (0..16) |index| {
        if (input.len - at < 2) return error.InvalidTextRepresentation;
        const high = nibble(input[at]) orelse return error.InvalidTextRepresentation;
        const low = nibble(input[at + 1]) orelse return error.InvalidTextRepresentation;
        out[index] = high << 4 | low;
        at += 2;
        if (at < input.len and input[at] == '-' and index % 2 == 1 and index < 15) at += 1;
    }
    if (braces) {
        if (at == input.len or input[at] != '}') return error.InvalidTextRepresentation;
        at += 1;
    }
    if (at != input.len) return error.InvalidTextRepresentation;
    return out;
}

/// The canonical text into `buffer` (at least 36 bytes).
pub fn format(value: *const Uuid, buffer: []u8) []const u8 {
    const digits = "0123456789abcdef";
    var at: usize = 0;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            buffer[at] = '-';
            at += 1;
        }
        buffer[at] = digits[byte >> 4];
        buffer[at + 1] = digits[byte & 15];
        at += 2;
    }
    return buffer[0..at];
}
