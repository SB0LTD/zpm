// Base64 encoder — RFC 4648 standard alphabet
// Layer 1: Platform (internal to mcp/ module)
//
// Comptime lookup table, chunk-oriented encoding for streaming.
// No allocator — caller provides output buffer.

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Encode a complete input buffer into base64.
/// Output buffer must be at least `encodedLen(input.len)` bytes.
/// Returns the number of bytes written.
pub fn encode(input: []const u8, output: []u8) usize {
    var pos: usize = 0;
    var i: usize = 0;

    // Full 3-byte groups
    while (i + 3 <= input.len) : (i += 3) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];
        output[pos] = ALPHABET[b0 >> 2];
        output[pos + 1] = ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[pos + 2] = ALPHABET[((b1 & 0x0F) << 2) | (b2 >> 6)];
        output[pos + 3] = ALPHABET[b2 & 0x3F];
        pos += 4;
    }

    // Remainder
    const rem = input.len - i;
    if (rem == 1) {
        const b0 = input[i];
        output[pos] = ALPHABET[b0 >> 2];
        output[pos + 1] = ALPHABET[(b0 & 0x03) << 4];
        output[pos + 2] = '=';
        output[pos + 3] = '=';
        pos += 4;
    } else if (rem == 2) {
        const b0 = input[i];
        const b1 = input[i + 1];
        output[pos] = ALPHABET[b0 >> 2];
        output[pos + 1] = ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[pos + 2] = ALPHABET[(b1 & 0x0F) << 2];
        output[pos + 3] = '=';
        pos += 4;
    }

    return pos;
}

/// Compute the base64-encoded length for a given input length.
pub fn encodedLen(input_len: usize) usize {
    return ((input_len + 2) / 3) * 4;
}
