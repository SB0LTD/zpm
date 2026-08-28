// @zpm/youtube/url — YouTube URL Parsing Utilities
//
// Extracts video IDs, channel handles, and playlist IDs from various URL formats.
//
// Supported formats:
//   https://www.youtube.com/watch?v=XXXXXXXXXXX
//   https://youtu.be/XXXXXXXXXXX
//   https://www.youtube.com/embed/XXXXXXXXXXX
//   https://www.youtube.com/v/XXXXXXXXXXX
//   https://www.youtube.com/shorts/XXXXXXXXXXX
//   https://www.youtube.com/@handle
//   https://www.youtube.com/channel/UCXXXXXXXXXXXXXXXXXXXXXXXX
//   Bare 11-char ID

pub const VIDEO_ID_LEN: usize = 11;
pub const CHANNEL_ID_LEN: usize = 24; // "UC" + 22 chars

/// Extract an 11-character video ID from a YouTube URL.
/// Returns true on success, writing the ID to `out`.
pub fn extractVideoId(input: []const u8, out: *[VIDEO_ID_LEN]u8) bool {
    // Pattern: "v=" parameter
    if (findParam(input, "v=")) |pos| {
        if (pos + VIDEO_ID_LEN <= input.len) {
            @memcpy(out, input[pos .. pos + VIDEO_ID_LEN]);
            return true;
        }
    }

    // Pattern: youtu.be/XXXXXXXXXXX
    if (findAfter(input, "youtu.be/")) |pos| {
        if (pos + VIDEO_ID_LEN <= input.len) {
            @memcpy(out, input[pos .. pos + VIDEO_ID_LEN]);
            return true;
        }
    }

    // Pattern: /embed/XXXXXXXXXXX or /v/XXXXXXXXXXX or /shorts/XXXXXXXXXXX
    const path_patterns = [_][]const u8{ "/embed/", "/v/", "/shorts/" };
    for (path_patterns) |pat| {
        if (findAfter(input, pat)) |pos| {
            if (pos + VIDEO_ID_LEN <= input.len) {
                @memcpy(out, input[pos .. pos + VIDEO_ID_LEN]);
                return true;
            }
        }
    }

    // Fallback: bare 11-char ID (all valid base64url characters)
    if (input.len == VIDEO_ID_LEN and isValidVideoId(input)) {
        @memcpy(out, input[0..VIDEO_ID_LEN]);
        return true;
    }

    return false;
}

/// Extract a channel handle (text after @) from a YouTube URL.
/// Returns the handle length written to `out`, or 0 on failure.
pub fn extractChannelHandle(input: []const u8, out: *[128]u8) usize {
    // Pattern: youtube.com/@handle
    if (findAfter(input, "/@")) |pos| {
        var end = pos;
        while (end < input.len and input[end] != '/' and input[end] != '?' and input[end] != ' ') : (end += 1) {}
        const len = @min(end - pos, 128);
        @memcpy(out[0..len], input[pos .. pos + len]);
        return len;
    }
    return 0;
}

/// Extract channel ID (UC...) from a URL.
pub fn extractChannelId(input: []const u8, out: *[CHANNEL_ID_LEN]u8) bool {
    if (findAfter(input, "/channel/")) |pos| {
        if (pos + CHANNEL_ID_LEN <= input.len) {
            @memcpy(out, input[pos .. pos + CHANNEL_ID_LEN]);
            return true;
        }
    }
    return false;
}

/// Check if a string looks like a valid YouTube video ID (base64url charset).
pub fn isValidVideoId(s: []const u8) bool {
    if (s.len != VIDEO_ID_LEN) return false;
    for (s) |c| {
        if (!isBase64Url(c)) return false;
    }
    return true;
}

/// Build a full watch URL from a video ID.
pub fn buildWatchUrl(video_id: *const [VIDEO_ID_LEN]u8, buf: *[64]u8) usize {
    const prefix = "https://www.youtube.com/watch?v=";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + VIDEO_ID_LEN], video_id);
    return prefix.len + VIDEO_ID_LEN;
}

/// Build a channel videos URL from a handle or channel URL.
pub fn buildChannelVideosUrl(channel_url: []const u8, buf: *[512]u8) usize {
    const len = @min(channel_url.len, 480);
    @memcpy(buf[0..len], channel_url[0..len]);
    var pos = len;

    // Strip trailing slash
    if (pos > 0 and buf[pos - 1] == '/') pos -= 1;

    // Append /videos if not already there
    if (!endsWith(buf[0..pos], "/videos")) {
        const suffix = "/videos";
        @memcpy(buf[pos .. pos + suffix.len], suffix);
        pos += suffix.len;
    }
    return pos;
}

// ── Internal helpers ──

fn findParam(haystack: []const u8, param: []const u8) ?usize {
    const pos = findSubstr(haystack, param) orelse return null;
    return pos + param.len;
}

fn findAfter(haystack: []const u8, needle: []const u8) ?usize {
    const pos = findSubstr(haystack, needle) orelse return null;
    return pos + needle.len;
}

fn findSubstr(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        if (eqlSlice(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return eqlSlice(haystack[haystack.len - suffix.len ..], suffix);
}

fn isBase64Url(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_';
}
