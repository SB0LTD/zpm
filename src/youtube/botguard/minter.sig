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
pub fn mintContentBound(integrity_token: []const u8, video_id: []const u8, out: []u8) usize {
    return mintToken(integrity_token, video_id, out);
}

/// Mint a session-bound PO token.
/// `integrity_token`: base64 integrity token
/// `visitor_data`: visitor data string (session binding)
/// `out`: buffer for base64-encoded PO token
pub fn mintSessionBound(integrity_token: []const u8, visitor_data: []const u8, out: []u8) usize {
    return mintToken(integrity_token, visitor_data, out);
}

/// Core minting function (WebPoMinter protocol):
///   1. Decode the integrity token from base64 to bytes.
///   2. getMinter = webPoSignalOutput[0]; mintCallback = getMinter(intBytes).
///   3. rawPoToken = mintCallback(contentBindingBytes)  (a byte array).
///   4. websafe-base64 encode the raw PO token bytes.
var int_bytes_buf: [1024]u8 = undefined;
var raw_pot_buf: [1024]u8 = undefined;
fn mintToken(integrity_token: []const u8, content_binding: []const u8, out: []u8) usize {
    // 1. base64-decode the integrity token.
    const int_len = base64Decode(integrity_token, int_bytes_buf[0..]);
    if (int_len == 0) return 0;

    // 2-3. Drive the VM minter chain to get the raw PO token bytes.
    const raw_len = jsvm.mintPoToken(int_bytes_buf[0..int_len], content_binding, raw_pot_buf[0..]);
    if (raw_len == 0) return 0;

    // 4. websafe (URL-safe, unpadded) base64 encode.
    return base64UrlEncode(raw_pot_buf[0..raw_len], out);
}

/// Decode standard base64 (ignoring '=' padding and whitespace) into `out`.
/// Returns the number of bytes decoded (0 on failure).
fn base64Decode(input: []const u8, out: []u8) usize {
    var acc: u32 = 0;
    var nbits: u5 = 0;
    var oi: usize = 0;
    for (input) |c| {
        const v: i16 = b64Val(c);
        if (v < 0) continue; // skip '=', newlines, etc.
        acc = (acc << 6) | @as(u32, @intCast(v));
        if (nbits >= 2) {
            nbits -= 2;
            if (oi >= out.len) return oi;
            out[oi] = @intCast((acc >> nbits) & 0xFF);
            oi += 1;
        } else {
            nbits += 6;
        }
    }
    return oi;
}

/// Map a base64 char (standard OR url-safe) to its 6-bit value, or -1.
fn b64Val(c: u8) i16 {
    if (c >= 'A' and c <= 'Z') return @as(i16, c - 'A');
    if (c >= 'a' and c <= 'z') return @as(i16, c - 'a') + 26;
    if (c >= '0' and c <= '9') return @as(i16, c - '0') + 52;
    if (c == '+' or c == '-') return 62;
    if (c == '/' or c == '_') return 63;
    return -1;
}

/// URL-safe base64 encode (no padding): '+'->'-', '/'->'_'.
fn base64UrlEncode(input: []const u8, out: []u8) usize {
    const n = base64Encode(input, out);
    for (0..n) |i| {
        if (out[i] == '+') out[i] = '-' else if (out[i] == '/') out[i] = '_';
    }
    return n;
}

/// Generate a cold-start PO token — the REAL BgUtils `createColdStartToken`
/// algorithm (WebPoMinter.createColdStartToken). Usable while YouTube's
/// StreamProtectionStatus (sps) is 2 (does NOT require the BotGuard interpreter's
/// getMinter). Packet layout:
///   header = [k0, k1, 0, clientState, ts>>24, ts>>16, ts>>8, ts]   (bytes)
///   packet = [34, header.len + cb.len] ++ header ++ contentBindingBytes
///   payload = packet[2..]; for i in [2..len): payload[i] ^= payload[i % 2]
///   token  = base64url(packet)   (unpadded)
/// `content_binding` = video id / visitor data (UTF-8). `out` = base64url token.
var cs_rng: u64 = 0x9E3779B97F4A7C15;
fn csRandByte() u8 {
    cs_rng ^= cs_rng << 13;
    cs_rng ^= cs_rng >> 7;
    cs_rng ^= cs_rng << 17;
    return @intCast(cs_rng & 0xFF);
}
pub fn mintColdStart(content_binding: []const u8, out: *[256]u8) usize {
    return mintColdStartTs(content_binding, defaultTimestamp(), 1, out);
}
fn defaultTimestamp() u32 {
    // Seconds since epoch. Uses GetSystemTimeAsFileTime for a real timestamp.
    var ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    // FILETIME = 100ns intervals since 1601-01-01. Convert to Unix seconds.
    const hundred_ns: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    const EPOCH_DIFF: u64 = 11644473600; // seconds between 1601 and 1970
    const unix_sec: u64 = (hundred_ns / 10_000_000) -| EPOCH_DIFF;
    return @intCast(unix_sec & 0xFFFFFFFF);
}
const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };
extern "kernel32" fn GetSystemTimeAsFileTime(*FILETIME) void;
pub fn mintColdStartTs(content_binding: []const u8, timestamp: u32, client_state: u8, out: *[256]u8) usize {
    const cb_len = @min(content_binding.len, 128);
    // header: 2 random keys, 0, clientState, 4 timestamp bytes (big-endian).
    const k0 = csRandByte();
    const k1 = csRandByte();
    var packet: [256]u8 = undefined;
    var pl: usize = 0;
    packet[pl] = 34; pl += 1; // packet[0]
    const header_len: usize = 8;
    packet[pl] = @intCast((header_len + cb_len) & 0xFF); pl += 1; // packet[1] = payload length
    // header (part of payload, starts at packet[2])
    packet[pl] = k0; pl += 1;
    packet[pl] = k1; pl += 1;
    packet[pl] = 0; pl += 1;
    packet[pl] = client_state; pl += 1;
    packet[pl] = @intCast((timestamp >> 24) & 0xFF); pl += 1;
    packet[pl] = @intCast((timestamp >> 16) & 0xFF); pl += 1;
    packet[pl] = @intCast((timestamp >> 8) & 0xFF); pl += 1;
    packet[pl] = @intCast(timestamp & 0xFF); pl += 1;
    // content binding bytes
    @memcpy(packet[pl .. pl + cb_len], content_binding[0..cb_len]);
    pl += cb_len;
    // XOR-obfuscate the payload (packet[2..]) with the 2 random keys.
    const key_len: usize = 2;
    var i: usize = key_len;
    while (i < (pl - 2)) : (i += 1) {
        packet[2 + i] ^= packet[2 + (i % key_len)];
    }
    return base64UrlEncode(packet[0..pl], out);
}

// ── Base64 encoding ──

const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64Encode(input: []const u8, out: []u8) usize {
    const required = (input.len / 3) * 4 + (if (input.len % 3 == 0) @as(usize, 0) else input.len % 3 + 1);
    if (required > out.len) return 0;
    var oi: usize = 0;
    var i: usize = 0;

    while (i + 2 < input.len) {
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
