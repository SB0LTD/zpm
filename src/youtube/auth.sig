// @zpm/youtube/auth — OAuth2 Token Management
//
// Manages YouTube API authentication tokens.
// Supports:
//   - Loading tokens from files
//   - Token validation (check expiry via tokeninfo endpoint)
//   - Storing tokens securely (file-based)
//   - Multiple token profiles (for different channels/accounts)
//
// YouTube API requires OAuth2 tokens for write operations (comments, uploads).
// Read-only operations (via yt-dlp) don't need tokens.
//
// Token format: raw access_token string in a file (one line, no JSON wrapper).
// Refresh flow is out of scope — use Google's OAuth playground or
// a browser-based flow to obtain tokens.

// ── Win32 ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn ReadFile(?*anyopaque, [*]u8, u32, *u32, ?*anyopaque) c_int;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn GetFileSize(?*anyopaque, ?*u32) u32;
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// WinHTTP for token validation
const HINTERNET = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*]const u16;
const WINHTTP_ACCESS_TYPE_DEFAULT: DWORD = 0;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;

const WinHttpOpenFn = *const fn (LPCWSTR, DWORD, ?LPCWSTR, ?LPCWSTR, DWORD) callconv(.c) HINTERNET;
const WinHttpConnectFn = *const fn (HINTERNET, LPCWSTR, u16, DWORD) callconv(.c) HINTERNET;
const WinHttpOpenRequestFn = *const fn (HINTERNET, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?*anyopaque, DWORD) callconv(.c) HINTERNET;
const WinHttpSendRequestFn = *const fn (HINTERNET, ?LPCWSTR, DWORD, ?*anyopaque, DWORD, DWORD, usize) callconv(.c) BOOL;
const WinHttpReceiveResponseFn = *const fn (HINTERNET, ?*anyopaque) callconv(.c) BOOL;
const WinHttpReadDataFn = *const fn (HINTERNET, [*]u8, DWORD, *DWORD) callconv(.c) BOOL;
const WinHttpCloseHandleFn = *const fn (HINTERNET) callconv(.c) BOOL;

var fn_open: ?WinHttpOpenFn = null;
var fn_connect: ?WinHttpConnectFn = null;
var fn_openReq: ?WinHttpOpenRequestFn = null;
var fn_sendReq: ?WinHttpSendRequestFn = null;
var fn_recvResp: ?WinHttpReceiveResponseFn = null;
var fn_readData: ?WinHttpReadDataFn = null;
var fn_closeHandle: ?WinHttpCloseHandleFn = null;
var http_loaded: bool = false;

/// Maximum token length.
pub const MAX_TOKEN_LEN: usize = 2048;

/// Token state.
pub const TokenState = enum {
    empty, // no token loaded
    loaded, // loaded but not validated
    valid, // validated (not expired)
    expired, // validated and found expired
    invalid, // validation failed (network or bad token)
};

/// Token info returned by Google's tokeninfo endpoint.
pub const TokenInfo = struct {
    state: TokenState,
    expires_in: i32, // seconds until expiry (-1 = unknown)
    scope: [256]u8,
    scope_len: u16,
    email: [128]u8,
    email_len: u8,
};

// Module state
var current_token: [MAX_TOKEN_LEN]u8 = undefined;
var current_token_len: usize = 0;
var current_state: TokenState = .empty;

/// Load a token from a file path.
pub fn load(path: [*:0]const u8) bool {
    const h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return false;

    var n: u32 = 0;
    _ = ReadFile(h, &current_token, @intCast(MAX_TOKEN_LEN), &n, null);
    _ = CloseHandle(h);
    current_token_len = @intCast(n);

    // Trim whitespace
    while (current_token_len > 0 and isWhitespace(current_token[current_token_len - 1])) {
        current_token_len -= 1;
    }

    if (current_token_len > 0) {
        current_state = .loaded;
        return true;
    }
    current_state = .empty;
    return false;
}

/// Set token directly from a buffer.
pub fn set(token: []const u8) void {
    const len = @min(token.len, MAX_TOKEN_LEN);
    @memcpy(current_token[0..len], token[0..len]);
    current_token_len = len;
    current_state = .loaded;
}

/// Save the current token to a file.
pub fn save(path: [*:0]const u8) bool {
    if (current_token_len == 0) return false;
    const h = CreateFileA(path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return false;
    _ = WriteFile(h, &current_token, @intCast(current_token_len), null, null);
    _ = CloseHandle(h);
    return true;
}

/// Get the current token as a slice.
pub fn getToken() []const u8 {
    return current_token[0..current_token_len];
}

/// Get the current state.
pub fn state() TokenState {
    return current_state;
}

/// Check if a token is loaded and non-empty.
pub fn isLoaded() bool {
    return current_token_len > 0;
}

/// Validate the token against Google's tokeninfo endpoint.
/// GET https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=TOKEN
/// Returns token info including expiry.
pub fn validate() TokenInfo {
    var info = TokenInfo{
        .state = .invalid,
        .expires_in = -1,
        .scope = undefined,
        .scope_len = 0,
        .email = undefined,
        .email_len = 0,
    };

    if (current_token_len == 0) {
        info.state = .empty;
        return info;
    }

    if (!ensureHttp()) return info;

    // Build path: /oauth2/v3/tokeninfo?access_token=TOKEN
    var path_buf: [MAX_TOKEN_LEN + 64]u8 = undefined;
    const path_prefix = "/oauth2/v3/tokeninfo?access_token=";
    @memcpy(path_buf[0..path_prefix.len], path_prefix);
    @memcpy(path_buf[path_prefix.len .. path_prefix.len + current_token_len], current_token[0..current_token_len]);
    const path_len = path_prefix.len + current_token_len;

    // Convert to UTF-16
    var path_w: [MAX_TOKEN_LEN + 64]u16 = undefined;
    for (0..path_len) |i| path_w[i] = path_buf[i];
    path_w[path_len] = 0;

    const W_AGENT = comptime toWide("zpm-youtube/1.0");
    const W_HOST = comptime toWide("www.googleapis.com");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return info;
    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse {
        _ = fn_closeHandle.?(hSession);
        return info;
    };
    const hRequest = fn_openReq.?(hConnect, null, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return info;
    };

    if (fn_sendReq.?(hRequest, null, 0, null, 0, 0, 0) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return info;
    }
    if (fn_recvResp.?(hRequest, null) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return info;
    }

    var resp: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < 4096) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, resp[total..].ptr, @intCast(4096 - total), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }

    _ = fn_closeHandle.?(hRequest);
    _ = fn_closeHandle.?(hConnect);
    _ = fn_closeHandle.?(hSession);

    // Parse response
    if (total == 0) return info;

    // Check for error response
    if (containsStr(resp[0..total], "\"error\"")) {
        info.state = .expired;
        current_state = .expired;
        return info;
    }

    // Extract expires_in
    if (extractInt(resp[0..total], "\"expires_in\"")) |v| {
        info.expires_in = @intCast(v);
        if (v > 0) {
            info.state = .valid;
            current_state = .valid;
        } else {
            info.state = .expired;
            current_state = .expired;
        }
    }

    // Extract scope
    if (extractStr(resp[0..total], "\"scope\"")) |v| {
        const slen = @min(v.len, 256);
        @memcpy(info.scope[0..slen], v[0..slen]);
        info.scope_len = @intCast(slen);
    }

    // Extract email
    if (extractStr(resp[0..total], "\"email\"")) |v| {
        const elen = @min(v.len, 128);
        @memcpy(info.email[0..elen], v[0..elen]);
        info.email_len = @intCast(elen);
    }

    return info;
}

/// Check if the token has youtube.force-ssl scope (required for comments).
pub fn hasYoutubeScope() bool {
    const info = validate();
    if (info.state != .valid) return false;
    return containsStr(info.scope[0..info.scope_len], "youtube");
}

// ── Helpers ──

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var ok = true;
        for (0..needle.len) |j| if (haystack[i + j] != needle[j]) { ok = false; break; };
        if (ok) return true;
    }
    return false;
}

fn extractInt(data: []const u8, key: []const u8) ?u64 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '"')) : (i += 1) {}
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;
    var val: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        val = val * 10 + @as(u64, data[i] - '0');
    }
    return val;
}

fn extractStr(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1;
    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i > start) return data[start..i];
    return null;
}

fn findStr(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        var ok = true;
        for (0..needle.len) |j| if (haystack[i + j] != needle[j]) { ok = false; break; };
        if (ok) return i;
    }
    return null;
}

fn ensureHttp() bool {
    if (http_loaded) return true;
    const dll = LoadLibraryA("winhttp.dll") orelse return false;
    fn_open = @ptrCast(GetProcAddress(dll, "WinHttpOpen"));
    fn_connect = @ptrCast(GetProcAddress(dll, "WinHttpConnect"));
    fn_openReq = @ptrCast(GetProcAddress(dll, "WinHttpOpenRequest"));
    fn_sendReq = @ptrCast(GetProcAddress(dll, "WinHttpSendRequest"));
    fn_recvResp = @ptrCast(GetProcAddress(dll, "WinHttpReceiveResponse"));
    fn_readData = @ptrCast(GetProcAddress(dll, "WinHttpReadData"));
    fn_closeHandle = @ptrCast(GetProcAddress(dll, "WinHttpCloseHandle"));
    if (fn_open == null or fn_sendReq == null) return false;
    http_loaded = true;
    return true;
}

fn toWide(comptime s: []const u8) [s.len + 1]u16 {
    var r: [s.len + 1]u16 = undefined;
    for (0..s.len) |i| r[i] = s[i];
    r[s.len] = 0;
    return r;
}
