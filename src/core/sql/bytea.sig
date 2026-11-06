//! BYTEA text input and output (Layer 0), after PostgreSQL's byteain and
//! byteaout with bytea_output = 'hex'.
//!
//! Input starting with `\x` is hex: pairs of hex digits in either case, with
//! spaces, tabs, CR and LF allowed between pairs. An invalid digit or an odd
//! number of digits is 22023 (invalid_parameter_value), as in
//! hex_decode_safe. Any other input is the escape format: `\\` is one
//! backslash, `\ooo` (first digit 0-3) is one octal byte, every other byte
//! stands for itself and any other backslash is 22P02. Output is `\x`
//! followed by lowercase hex digits.
//!
//! Values are raw bytes in a caller-owned buffer bounded by
//! Config.text_bytes; longer values are TextCapacity (54000). Their text
//! form needs 2 * len + 2 bytes.
const types = @import("types.sig");
const Error = types.Error;

fn hexDigit(byte: u8) Error!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidParameterValue,
    };
}

fn octal(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}

fn put(out: []u8, at: *usize, byte: u8) Error!void {
    if (at.* == out.len) return error.TextCapacity;
    out[at.*] = byte;
    at.* += 1;
}

/// Decodes `input` into `out`; returns the byte count.
pub fn parse(input: []const u8, out: []u8) Error!usize {
    var at: usize = 0;
    if (input.len >= 2 and input[0] == '\\' and input[1] == 'x') {
        var index: usize = 2;
        while (index < input.len) {
            const byte = input[index];
            if (byte == ' ' or byte == '\n' or byte == '\t' or byte == '\r') {
                index += 1;
                continue;
            }
            const high = try hexDigit(byte);
            if (index + 1 == input.len) return error.InvalidParameterValue;
            const low = try hexDigit(input[index + 1]);
            try put(out, &at, high << 4 | low);
            index += 2;
        }
        return at;
    }
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte != '\\') {
            try put(out, &at, byte);
            index += 1;
        } else if (index + 3 < input.len and input[index + 1] >= '0' and input[index + 1] <= '3' and octal(input[index + 2]) and octal(input[index + 3])) {
            try put(out, &at, (input[index + 1] - '0') << 6 | (input[index + 2] - '0') << 3 | (input[index + 3] - '0'));
            index += 4;
        } else if (index + 1 < input.len and input[index + 1] == '\\') {
            try put(out, &at, '\\');
            index += 2;
        } else return error.InvalidTextRepresentation;
    }
    return at;
}

/// Hex output into `buffer` (at least 2 * bytes.len + 2 long).
pub fn format(bytes: []const u8, buffer: []u8) []const u8 {
    const digits = "0123456789abcdef";
    buffer[0] = '\\';
    buffer[1] = 'x';
    for (bytes, 0..) |byte, index| {
        buffer[2 + index * 2] = digits[byte >> 4];
        buffer[3 + index * 2] = digits[byte & 15];
    }
    return buffer[0 .. 2 + bytes.len * 2];
}

/// byteacat into `out`; returns the byte count.
pub fn concat(left: []const u8, right: []const u8, out: []u8) Error!usize {
    if (left.len > out.len or right.len > out.len - left.len) return error.TextCapacity;
    @memcpy(out[0..left.len], left);
    @memcpy(out[left.len..][0..right.len], right);
    return left.len + right.len;
}
