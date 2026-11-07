//! Layer 0 Bitcoin/Solana base58. Caller output doubles as conversion scratch.
//! Arbitrary lengths fit when the caller supplies enough space; no hidden capacity.
//! Buffers must not overlap. On error, output contents are unspecified.
pub const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
pub const Error = error{ InvalidChar, OutputTooSmall, NonCanonical };
fn digit(character: u8) u8 {
    for (ALPHABET, 0..) |byte, index| if (byte == character) return @intCast(index);
    return 255;
}
fn reverse(bytes: []u8) void {
    var i: usize = 0;
    while (i < bytes.len / 2) : (i += 1) {
        const other = bytes.len - i - 1;
        const temporary = bytes[i];
        bytes[i] = bytes[other];
        bytes[other] = temporary;
    }
}
fn shift(bytes: []u8, used: usize, zeroes: usize) void {
    var i = used;
    while (i > 0) {
        i -= 1;
        bytes[zeroes + i] = bytes[i];
    }
}
pub fn encode(input: []const u8, output: []u8) Error!usize {
    var zeroes: usize = 0;
    while (zeroes < input.len and input[zeroes] == 0) : (zeroes += 1) {}
    if (zeroes > output.len) return error.OutputTooSmall;
    @memset(output, 0);
    var used: usize = 0;
    for (input[zeroes..]) |byte| {
        var carry: u32 = byte;
        for (0..used) |i| {
            carry += @as(u32, output[i]) * 256;
            output[i] = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry != 0) : (carry /= 58) {
            if (used == output.len - zeroes) return error.OutputTooSmall;
            output[used] = @intCast(carry % 58);
            used += 1;
        }
    }
    reverse(output[0..used]);
    shift(output, used, zeroes);
    @memset(output[0..zeroes], ALPHABET[0]);
    for (output[zeroes..][0..used]) |*byte| byte.* = ALPHABET[byte.*];
    return used + zeroes;
}
pub fn decode(encoded: []const u8, output: []u8) Error!usize {
    for (encoded) |character| if (digit(character) == 255) return error.InvalidChar;
    var zeroes: usize = 0;
    while (zeroes < encoded.len and encoded[zeroes] == ALPHABET[0]) : (zeroes += 1) {}
    if (zeroes > output.len) return error.OutputTooSmall;
    @memset(output, 0);
    var used: usize = 0;
    for (encoded[zeroes..]) |character| {
        var carry: u32 = digit(character);
        for (0..used) |i| {
            carry += @as(u32, output[i]) * 58;
            output[i] = @truncate(carry);
            carry >>= 8;
        }
        while (carry != 0) : (carry >>= 8) {
            if (used == output.len - zeroes) return error.OutputTooSmall;
            output[used] = @truncate(carry);
            used += 1;
        }
    }
    reverse(output[0..used]);
    shift(output, used, zeroes);
    @memset(output[0..zeroes], 0);
    return used + zeroes;
}
pub fn encodeKey(key: *const [32]u8, output: *[44]u8) usize {
    return encode(key, output) catch unreachable;
}
pub fn decodeKey(encoded: []const u8, output: *[32]u8) Error!void {
    if (try decode(encoded, output) != output.len) return error.NonCanonical;
}
