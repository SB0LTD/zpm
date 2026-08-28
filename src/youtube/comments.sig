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

// ── Win32 WinHTTP ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn ReadFile(?*anyopaque, [*]u8, u32, *u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// ── WinHTTP types ──
const HINTERNET = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*]const u16;

const WINHTTP_ACCESS_TYPE_DEFAULT: DWORD = 0;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const INTERNET_DEFAULT_HTTPS_PORT: u16 = 443;
const WINHTTP_ADDREQ_FLAG_ADD: DWORD = 0x20000000;
const WINHTTP_ADDREQ_FLAG_REPLACE: DWORD = 0x80000000;

// ── WinHTTP function pointer types ──
const WinHttpOpenFn = *const fn (LPCWSTR, DWORD, ?LPCWSTR, ?LPCWSTR, DWORD) callconv(.c) HINTERNET;
const WinHttpConnectFn = *const fn (HINTERNET, LPCWSTR, u16, DWORD) callconv(.c) HINTERNET;
const WinHttpOpenRequestFn = *const fn (HINTERNET, LPCWSTR, LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?*anyopaque, DWORD) callconv(.c) HINTERNET;
const WinHttpSendRequestFn = *const fn (HINTERNET, ?LPCWSTR, DWORD, ?*anyopaque, DWORD, DWORD, usize) callconv(.c) BOOL;
const WinHttpReceiveResponseFn = *const fn (HINTERNET, ?*anyopaque) callconv(.c) BOOL;
const WinHttpReadDataFn = *const fn (HINTERNET, [*]u8, DWORD, *DWORD) callconv(.c) BOOL;
const WinHttpCloseHandleFn = *const fn (HINTERNET) callconv(.c) BOOL;
const WinHttpAddRequestHeadersFn = *const fn (HINTERNET, LPCWSTR, DWORD, DWORD) callconv(.c) BOOL;

// ── Module state ──
var fn_open: ?WinHttpOpenFn = null;
var fn_connect: ?WinHttpConnectFn = null;
var fn_openReq: ?WinHttpOpenRequestFn = null;
var fn_sendReq: ?WinHttpSendRequestFn = null;
var fn_recvResp: ?WinHttpReceiveResponseFn = null;
var fn_readData: ?WinHttpReadDataFn = null;
var fn_closeHandle: ?WinHttpCloseHandleFn = null;
var fn_addHeaders: ?WinHttpAddRequestHeadersFn = null;
var winhttp_loaded: bool = false;

// Token buffer
var token_buf: [512]u8 = undefined;
var token_len: usize = 0;

// Response buffer
var response_buf: [8192]u8 = undefined;
var response_len: usize = 0;

/// Load WinHTTP DLL (lazy init).
pub fn initHttp() bool {
    if (winhttp_loaded) return true;
    const dll = LoadLibraryA("winhttp.dll") orelse return false;
    fn_open = @ptrCast(GetProcAddress(dll, "WinHttpOpen"));
    fn_connect = @ptrCast(GetProcAddress(dll, "WinHttpConnect"));
    fn_openReq = @ptrCast(GetProcAddress(dll, "WinHttpOpenRequest"));
    fn_sendReq = @ptrCast(GetProcAddress(dll, "WinHttpSendRequest"));
    fn_recvResp = @ptrCast(GetProcAddress(dll, "WinHttpReceiveResponse"));
    fn_readData = @ptrCast(GetProcAddress(dll, "WinHttpReadData"));
    fn_closeHandle = @ptrCast(GetProcAddress(dll, "WinHttpCloseHandle"));
    fn_addHeaders = @ptrCast(GetProcAddress(dll, "WinHttpAddRequestHeaders"));
    if (fn_open == null or fn_sendReq == null) return false;
    winhttp_loaded = true;
    return true;
}

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
    if (!initHttp()) return false;

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

// ── HTTP POST (WinHTTP) ──

fn httpPost(body: []const u8) bool {
    const open = fn_open orelse return false;
    const connect_fn = fn_connect orelse return false;
    const openReq = fn_openReq orelse return false;
    const sendReq = fn_sendReq orelse return false;
    const recvResp = fn_recvResp orelse return false;
    const readData = fn_readData orelse return false;
    const closeHandle = fn_closeHandle orelse return false;
    const addHeaders = fn_addHeaders orelse return false;

    // UTF-16 constants
    const W_AGENT = comptime toWide("gotliv/1.0");
    const W_HOST = comptime toWide("www.googleapis.com");
    const W_VERB = comptime toWide("POST");
    const W_PATH = comptime toWide("/youtube/v3/commentThreads?part=snippet");
    const W_CT = comptime toWide("Content-Type: application/json\r\n");

    const hSession = open(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return false;
    const hConnect = connect_fn(hSession, &W_HOST, INTERNET_DEFAULT_HTTPS_PORT, 0) orelse {
        _ = closeHandle(hSession);
        return false;
    };
    const hRequest = openReq(hConnect, &W_VERB, &W_PATH, null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = closeHandle(hConnect);
        _ = closeHandle(hSession);
        return false;
    };

    // Content-Type header
    _ = addHeaders(hRequest, &W_CT, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

    // Authorization header
    var auth_w: [600]u16 = undefined;
    const auth_prefix = "Authorization: Bearer ";
    var wlen: usize = 0;
    for (auth_prefix) |c| { auth_w[wlen] = c; wlen += 1; }
    for (0..token_len) |i| { auth_w[wlen] = token_buf[i]; wlen += 1; }
    auth_w[wlen] = '\r'; wlen += 1;
    auth_w[wlen] = '\n'; wlen += 1;
    auth_w[wlen] = 0;
    _ = addHeaders(hRequest, &auth_w, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

    // Send
    if (sendReq(hRequest, null, 0, @ptrCast(@constCast(body.ptr)), @intCast(body.len), @intCast(body.len), 0) == 0) {
        _ = closeHandle(hRequest);
        _ = closeHandle(hConnect);
        _ = closeHandle(hSession);
        return false;
    }

    if (recvResp(hRequest, null) == 0) {
        _ = closeHandle(hRequest);
        _ = closeHandle(hConnect);
        _ = closeHandle(hSession);
        return false;
    }

    // Read response
    response_len = 0;
    while (response_len < response_buf.len) {
        var n: DWORD = 0;
        if (readData(hRequest, response_buf[response_len..].ptr, @intCast(response_buf.len - response_len), &n) == 0) break;
        if (n == 0) break;
        response_len += n;
    }

    _ = closeHandle(hRequest);
    _ = closeHandle(hConnect);
    _ = closeHandle(hSession);

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

fn toWide(comptime s: []const u8) [s.len + 1]u16 {
    var result: [s.len + 1]u16 = undefined;
    for (0..s.len) |i| result[i] = s[i];
    result[s.len] = 0;
    return result;
}
