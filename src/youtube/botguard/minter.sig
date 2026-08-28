// @zpm/youtube/botguard/minter — PO Token Minting
//
// Mints Proof-of-Origin tokens using the integrity token and content bindings.
// Two token types:
//   - Content-bound: bound to a specific video ID (for player requests)
//   - Session-bound: bound to visitor data (for stream URL &pot= parameter)
//
// The actual minting is performed by a callback function provided by the
// BotGuard VM during execution. This module manages calling that callback
// and encoding the results.

const jsvm = @import("jsvm/root.sig");

extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
}

/// Mint a content-bound PO token for a specific video.
/// `integrity_token`: base64 integrity token from WAA/GenerateIT
/// `video_id`: 11-char YouTube video ID (content binding)
/// `out`: buffer for base64-encoded PO token
/// Returns token length, or 0 on failure.
pub fn mintContentBound(integrity_token: []const u8, video_id: []const u8, out: *[256]u8) usize {
    return mintToken(integrity_token, video_id, out);
}

/// Mint a session-bound PO token.
/// `integrity_token`: base64 integrity token
/// `visitor_data`: visitor data string (session binding)
/// `out`: buffer for base64-encoded PO token
pub fn mintSessionBound(integrity_token: []const u8, visitor_data: []const u8, out: *[256]u8) usize {
    return mintToken(integrity_token, visitor_data, out);
}

/// Core minting function.
/// Calls the BotGuard VM's minter callback with the integrity token and binding.
fn mintToken(integrity_token: []const u8, content_binding: []const u8, out: *[256]u8) usize {
    // The minter works by:
    // 1. Decode integrity token from base64 to bytes
    // 2. Pass to the minter function (getMinter callback from VM)
    // 3. Call the returned mint function with content_binding encoded as UTF-8 bytes
    // 4. Base64-encode the result (~110-128 bytes)

    // Use the JS VM's minter state
    var raw_token: [192]u8 = undefined;
    const raw_len = jsvm.callMinter(integrity_token, content_binding, &raw_token);
    if (raw_len == 0) return 0;

    // Base64 encode
    const encoded_len = base64Encode(raw_token[0..raw_len], out);
    return encoded_len;
}

/// Generate a cold-start token (XOR-cipher placeholder).
/// Used to begin playback before the real PO token is ready.
/// YouTube accepts this temporarily (1-2 MB of data) before requiring the real token.
pub fn mintColdStart(video_id: []const u8, out: *[256]u8) usize {
    // Cold start tokens are XOR-encrypted with a simple key
    // Format: base64(xor(video_id_padded, key))
    // The key is derived from the visitor data
    var padded: [128]u8 = @splat(0);
    const id_len = @min(video_id.len, 64);
    @memcpy(padded[0..id_len], video_id[0..id_len]);

    // XOR with a rotating key (simplified — real implementation uses BG-derived key)
    const key = "YouTubePOTokenColdStart2024XORKey";
    for (0..128) |i| {
        padded[i] ^= key[i % key.len];
    }

    return base64Encode(padded[0..128], out);
}

// ── Base64 encoding ──

const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64Encode(input: []const u8, out: *[256]u8) usize {
    var oi: usize = 0;
    var i: usize = 0;

    while (i + 2 < input.len) {
        if (oi + 4 > 256) break;
        const b0: u32 = input[i];
        const b1: u32 = input[i + 1];
        const b2: u32 = input[i + 2];
        const triple = (b0 << 16) | (b1 << 8) | b2;
        out[oi] = B64_CHARS[@intCast((triple >> 18) & 0x3F)];
        out[oi + 1] = B64_CHARS[@intCast((triple >> 12) & 0x3F)];
        out[oi + 2] = B64_CHARS[@intCast((triple >> 6) & 0x3F)];
        out[oi + 3] = B64_CHARS[@intCast(triple & 0x3F)];
        oi += 4;
        i += 3;
    }

    // Handle remaining 1-2 bytes
    if (i < input.len) {
        if (oi + 4 > 256) return oi;
        const b0: u32 = input[i];
        if (i + 1 < input.len) {
            const b1: u32 = input[i + 1];
            const triple = (b0 << 16) | (b1 << 8);
            out[oi] = B64_CHARS[@intCast((triple >> 18) & 0x3F)];
            out[oi + 1] = B64_CHARS[@intCast((triple >> 12) & 0x3F)];
            out[oi + 2] = B64_CHARS[@intCast((triple >> 6) & 0x3F)];
            oi += 3;
        } else {
            const triple = b0 << 16;
            out[oi] = B64_CHARS[@intCast((triple >> 18) & 0x3F)];
            out[oi + 1] = B64_CHARS[@intCast((triple >> 12) & 0x3F)];
            oi += 2;
        }
    }

    return oi;
}
