// @zpm/youtube/sabr/player_fields — SABR fields from the player response
//
// Extracts the two values the SABR transport needs from a WEB/MWEB InnerTube
// player JSON (both live under "streamingData"):
//
//   serverAbrStreamingUrl        — the POST endpoint for SABR media delivery
//   serverAbrStreamingUrlConfig  — ustreamer config blob (also seen as
//     "videoPlaybackUstreamerConfig"); a base64 string the request builder
//     base64-decodes before embedding as bytes (field 5).
//
// Returned slices borrow the caller's player buffer. The URL value is JSON-
// escaped in the response ("https:\/\/..."), so a caller that needs the raw
// URL should unescape it; `unescapeInto` is provided for that. Zero allocation.

/// serverAbrStreamingUrl (raw, still JSON-escaped) or null if absent.
pub fn serverAbrStreamingUrl(player_json: []const u8) ?[]const u8 {
    return findStrVal(player_json, "\"serverAbrStreamingUrl\"");
}

/// The ustreamer config base64 string, trying the known key spellings in order.
pub fn ustreamerConfig(player_json: []const u8) ?[]const u8 {
    return findStrVal(player_json, "\"videoPlaybackUstreamerConfig\"") orelse
        findStrVal(player_json, "\"serverAbrStreamingUrlConfig\"") orelse
        findStrVal(player_json, "\"ustreamerConfig\"");
}

/// Unescape a JSON string value (handles \/ \" \\ \n \r \t and \uXXXX for the
/// BMP) into `out`, returning bytes written.
pub fn unescapeInto(s: []const u8, out: []u8) usize {
    return jsonUnescape(s, out);
}

// ── JSON helpers (private copies; identical semantics to session.sig) ──

fn findStr(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    for (0..hay.len - needle.len + 1) |i| {
        var ok = true;
        for (0..needle.len) |j| if (hay[i + j] != needle[j]) { ok = false; break; };
        if (ok) return i;
    }
    return null;
}

fn findStrVal(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = findStr(data, key) orelse return null;
    var i = pos + key.len;
    if (i < data.len and data[i] == '"') i += 1;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != ':') return null;
    i += 1;
    while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {
        if (data[i] == '\\' and i + 1 < data.len) i += 1;
    }
    if (i > start) return data[start..i];
    return data[start..start];
}

fn jsonUnescape(s: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < out.len) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) { out[o] = c; o += 1; i += 1; continue; }
        const e = s[i + 1];
        i += 2;
        switch (e) {
            'n' => { out[o] = '\n'; o += 1; },
            'r' => { out[o] = '\r'; o += 1; },
            't' => { out[o] = '\t'; o += 1; },
            'b' => { out[o] = 8; o += 1; },
            'f' => { out[o] = 12; o += 1; },
            '"' => { out[o] = '"'; o += 1; },
            '\\' => { out[o] = '\\'; o += 1; },
            '/' => { out[o] = '/'; o += 1; },
            'u' => {
                if (i + 4 <= s.len) {
                    const cp: u32 = (@as(u32, hexNib(s[i])) << 12) | (@as(u32, hexNib(s[i + 1])) << 8) |
                        (@as(u32, hexNib(s[i + 2])) << 4) | @as(u32, hexNib(s[i + 3]));
                    i += 4;
                    if (cp < 0x80) { out[o] = @intCast(cp); o += 1; }
                    else if (cp < 0x800) {
                        if (o + 1 < out.len) { out[o] = @intCast(0xC0 | (cp >> 6)); out[o + 1] = @intCast(0x80 | (cp & 0x3F)); o += 2; }
                    } else {
                        if (o + 2 < out.len) { out[o] = @intCast(0xE0 | (cp >> 12)); out[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F)); out[o + 2] = @intCast(0x80 | (cp & 0x3F)); o += 3; }
                    }
                }
            },
            else => { out[o] = e; o += 1; },
        }
    }
    return o;
}

fn hexNib(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

// ── Tests (inline, std.testing) ──

const std = @import("std");
const testing = std.testing;

test "player_fields: extracts serverAbrStreamingUrl and ustreamer config" {
    const player =
        "{\"streamingData\":{\"expiresInSeconds\":\"21540\"," ++
        "\"serverAbrStreamingUrl\":\"https:\\/\\/rr5.googlevideo.com\\/videoplayback?expire=1&sabr=1\"," ++
        "\"videoPlaybackUstreamerConfig\":\"CgkKB2Zvbw==\"}}";
    const url = serverAbrStreamingUrl(player).?;
    try testing.expectEqualSlices(u8, "https:\\/\\/rr5.googlevideo.com\\/videoplayback?expire=1&sabr=1", url);
    var ubuf: [256]u8 = undefined;
    const n = unescapeInto(url, &ubuf);
    try testing.expectEqualSlices(u8, "https://rr5.googlevideo.com/videoplayback?expire=1&sabr=1", ubuf[0..n]);
    const cfg = ustreamerConfig(player).?;
    try testing.expectEqualSlices(u8, "CgkKB2Zvbw==", cfg);
}

test "player_fields: absent fields return null" {
    const player = "{\"streamingData\":{\"formats\":[]}}";
    try testing.expect(serverAbrStreamingUrl(player) == null);
    try testing.expect(ustreamerConfig(player) == null);
}

test "player_fields: ustreamer config fallback key" {
    const player = "{\"streamingData\":{\"ustreamerConfig\":\"Zm9v\"}}";
    try testing.expectEqualSlices(u8, "Zm9v", ustreamerConfig(player).?);
}
