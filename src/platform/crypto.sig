// HMAC-SHA256 via Windows BCrypt — for API request signing
// Layer 1: Platform
//
// Thin wrapper around BCrypt. Takes a key and message, produces
// a 32-byte HMAC-SHA256 digest. No allocator needed.

const w32 = @import("win32");

/// HMAC-SHA256 output size in bytes
pub const HMAC_SHA256_LEN = 32;

/// Compute HMAC-SHA256(key, message) → 32-byte digest.
/// Returns true on success, false on any BCrypt failure.
pub fn hmacSha256(key: []const u8, message: []const u8, out: *[HMAC_SHA256_LEN]u8) bool {
    var alg: w32.BCRYPT_ALG_HANDLE = null;
    var status = w32.BCryptOpenAlgorithmProvider(
        &alg,
        w32.BCRYPT_HMAC_SHA256_ALG,
        null,
        w32.BCRYPT_ALG_HANDLE_HMAC_FLAG,
    );
    if (status != 0) return false;
    defer _ = w32.BCryptCloseAlgorithmProvider(alg, 0);

    var hash: w32.BCRYPT_HASH_HANDLE = null;
    status = w32.BCryptCreateHash(
        alg,
        &hash,
        null,
        0,
        @constCast(key.ptr),
        @intCast(key.len),
        0,
    );
    if (status != 0) return false;
    defer _ = w32.BCryptDestroyHash(hash);

    status = w32.BCryptHashData(hash, message.ptr, @intCast(message.len), 0);
    if (status != 0) return false;

    status = w32.BCryptFinishHash(hash, out, HMAC_SHA256_LEN, 0);
    return status == 0;
}

/// Convert a 32-byte digest to a 64-char lowercase hex string.
pub fn toHex(digest: *const [HMAC_SHA256_LEN]u8, out: *[HMAC_SHA256_LEN * 2]u8) void {
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

/// Get current Unix timestamp in milliseconds (for Binance API).
pub fn timestampMs() u64 {
    var ft: w32.FILETIME = .{};
    w32.GetSystemTimeAsFileTime(&ft);
    // FILETIME is 100-nanosecond intervals since 1601-01-01
    // Unix epoch starts 1970-01-01 = 11644473600 seconds later
    const ft64: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const unix_100ns = ft64 - 116444736000000000;
    return unix_100ns / 10000; // 100ns → ms
}
