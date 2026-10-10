// @zpm/youtube/comments — YouTube Data API v3 Comments
//
// Posts comments on YouTube videos via the commentThreads endpoint.
// Requires an OAuth2 access token with youtube.force-ssl scope.
//
// API: POST https://www.googleapis.com/youtube/v3/commentThreads?part=snippet
// Auth: Bearer token in Authorization header
//
// Token management:
//   Tokens are loaded from a file path provided by the caller.
//   Token refresh is out of scope — caller provides a valid token.

const meta = @import("metadata.sig");
const http = @import("net.sig");

// ── Win32 (token file I/O only) ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn ReadFile(?*anyopaque, [*]u8, u32, *u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// Token buffer
var token_buf: [512]u8 = undefined;
var token_len: usize = 0;

// Response buffer
var response_buf: [8192]u8 = undefined;
var response_len: usize = 0;

/// Load an OAuth2 bearer token from a file.
/// Returns true if a non-empty token was loaded.
pub fn loadToken(path: [*:0]const u8) bool {
    const h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return false;
    var n: u32 = 0;
    _ = ReadFile(h, &token_buf, 512, &n, null);
    _ = CloseHandle(h);
    token_len = @intCast(n);
    // Trim whitespace
    while (token_len > 0 and (token_buf[token_len - 1] == '\n' or
        token_buf[token_len - 1] == '\r' or token_buf[token_len - 1] == ' '))
    {
        token_len -= 1;
    }
    return token_len > 0;
}

/// Set token directly from a buffer (for callers that manage tokens in memory).
pub fn setToken(tok: []const u8) void {
    const len = @min(tok.len, 512);
    @memcpy(token_buf[0..len], tok[0..len]);
    token_len = len;
}

/// Post a comment on a YouTube video.
/// Returns true on success (HTTP 200 with valid response).
pub fn post(video_id: *const [meta.VIDEO_ID_LEN]u8, comment_text: []const u8) bool {
    if (token_len == 0) return false;

    // Build JSON body
    var body: [4096]u8 = undefined;
    const body_len = buildCommentBody(video_id, comment_text, &body);

    return httpPost(body[0..body_len]);
}

/// Get the last response body (for debugging failed requests).
pub fn lastResponse() []const u8 {
    return response_buf[0..response_len];
}

// ── JSON body builder ──

fn buildCommentBody(video_id: *const [meta.VIDEO_ID_LEN]u8, text: []const u8, body: *[4096]u8) usize {
    var pos: usize = 0;

    const p1 = "{\"snippet\":{\"videoId\":\"";
    @memcpy(body[pos .. pos + p1.len], p1);
    pos += p1.len;

    @memcpy(body[pos .. pos + meta.VIDEO_ID_LEN], video_id);
    pos += meta.VIDEO_ID_LEN;

    const p2 = "\",\"topLevelComment\":{\"snippet\":{\"textOriginal\":\"";
    @memcpy(body[pos .. pos + p2.len], p2);
    pos += p2.len;

    // JSON-escape the comment text
    for (text) |c| {
        if (pos >= 3900) break;
        switch (c) {
            '"' => { body[pos] = '\\'; pos += 1; body[pos] = '"'; pos += 1; },
            '\\' => { body[pos] = '\\'; pos += 1; body[pos] = '\\'; pos += 1; },
            '\n' => { body[pos] = '\\'; pos += 1; body[pos] = 'n'; pos += 1; },
            '\r' => { body[pos] = '\\'; pos += 1; body[pos] = 'r'; pos += 1; },
            else => { body[pos] = c; pos += 1; },
        }
    }

    const p3 = "\"}}}}";
    @memcpy(body[pos .. pos + p3.len], p3);
    pos += p3.len;

    return pos;
}

// ── HTTP POST (via @zpm/http) ──

fn httpPost(body: []const u8) bool {
    // Build the request header block: Content-Type + Authorization: Bearer <token>.
    var hdr: [700]u8 = undefined;
    var hp: usize = 0;
    const ct = "Content-Type: application/json\r\nAuthorization: Bearer ";
    @memcpy(hdr[hp .. hp + ct.len], ct);
    hp += ct.len;
    @memcpy(hdr[hp .. hp + token_len], token_buf[0..token_len]);
    hp += token_len;
    hdr[hp] = '\r'; hp += 1;
    hdr[hp] = '\n'; hp += 1;

    const r = http.postInto(
        "www.googleapis.com",
        443,
        "/youtube/v3/commentThreads?part=snippet",
        hdr[0..hp],
        body,
        "gotliv/1.0",
        &response_buf,
    );
    response_len = r.len;

    // Success check: response contains "snippet" (valid comment response)
    return containsStr(response_buf[0..response_len], "\"snippet\"");
}

// ── Helpers ──

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var match = true;
        for (0..needle.len) |j| if (haystack[i + j] != needle[j]) { match = false; break; };
        if (match) return true;
    }
    return false;
}
