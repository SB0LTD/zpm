// @zpm/youtube/innertube — Pure Sig InnerTube API Client
//
// Direct HTTP client for YouTube's private InnerTube API.
// No yt-dlp, no Python, no external dependencies. Pure WinHTTP.
//
// Endpoints:
//   /youtubei/v1/player   — Get stream URLs, metadata, captions
//   /youtubei/v1/browse   — Channel pages, playlists, home feed
//   /youtubei/v1/search   — Search YouTube
//   /youtubei/v1/next     — Related videos, comments
//   /youtubei/v1/resolve  — Resolve URLs to canonical form
//
// Client contexts (determines what data YouTube returns):
//   WEB        — Full desktop experience, all formats
//   ANDROID    — Sometimes returns direct URLs without cipher
//   IOS        — Similar to ANDROID
//   TV_EMBED   — Embed player, fewer restrictions
//
// All requests are POST with JSON body containing:
//   { "context": { "client": { "clientName": "...", "clientVersion": "..." } },
//     ...endpoint-specific params... }
//
// Rate limiting: YouTube allows ~500 requests/min from a single IP.
// No API key needed for public data.

// ── Win32 WinHTTP ──
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;

const HINTERNET = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*]const u16;

const WINHTTP_ACCESS_TYPE_DEFAULT: DWORD = 0;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const WINHTTP_ADDREQ_FLAG_ADD: DWORD = 0x20000000;
const WINHTTP_ADDREQ_FLAG_REPLACE: DWORD = 0x80000000;

const WinHttpOpenFn = *const fn (LPCWSTR, DWORD, ?LPCWSTR, ?LPCWSTR, DWORD) callconv(.c) HINTERNET;
const WinHttpConnectFn = *const fn (HINTERNET, LPCWSTR, u16, DWORD) callconv(.c) HINTERNET;
const WinHttpOpenRequestFn = *const fn (HINTERNET, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?*anyopaque, DWORD) callconv(.c) HINTERNET;
const WinHttpSendRequestFn = *const fn (HINTERNET, ?LPCWSTR, DWORD, ?*anyopaque, DWORD, DWORD, usize) callconv(.c) BOOL;
const WinHttpReceiveResponseFn = *const fn (HINTERNET, ?*anyopaque) callconv(.c) BOOL;
const WinHttpReadDataFn = *const fn (HINTERNET, [*]u8, DWORD, *DWORD) callconv(.c) BOOL;
const WinHttpCloseHandleFn = *const fn (HINTERNET) callconv(.c) BOOL;
const WinHttpAddRequestHeadersFn = *const fn (HINTERNET, LPCWSTR, DWORD, DWORD) callconv(.c) BOOL;

var fn_open: ?WinHttpOpenFn = null;
var fn_connect: ?WinHttpConnectFn = null;
var fn_openReq: ?WinHttpOpenRequestFn = null;
var fn_sendReq: ?WinHttpSendRequestFn = null;
var fn_recvResp: ?WinHttpReceiveResponseFn = null;
var fn_readData: ?WinHttpReadDataFn = null;
var fn_closeHandle: ?WinHttpCloseHandleFn = null;
var fn_addHeaders: ?WinHttpAddRequestHeadersFn = null;
var http_loaded: bool = false;

// ── Response buffer (512 KB — player responses can be large) ──
pub const RESPONSE_BUF_SIZE: usize = 512 * 1024;
var response_buf: [RESPONSE_BUF_SIZE]u8 = undefined;
var response_len: usize = 0;

// ── Client context definitions ──

pub const ClientType = enum {
    web,
    web_embedded,
    android,
    android_vr,
    ios,
    tv_embedded,
    mweb,
};

/// Get the client name string for the InnerTube context.
fn clientName(ct: ClientType) []const u8 {
    return switch (ct) {
        .web => "WEB",
        .web_embedded => "WEB_EMBEDDED_PLAYER",
        .android => "ANDROID",
        .android_vr => "ANDROID_VR",
        .ios => "IOS",
        .tv_embedded => "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        .mweb => "MWEB",
    };
}

/// Get the client version for the InnerTube context.
fn clientVersion(ct: ClientType) []const u8 {
    return switch (ct) {
        .web => "2.20241126.01.00",
        .web_embedded => "2.20241126.01.00",
        .android => "19.29.37",
        .android_vr => "1.62.27",
        .ios => "19.29.1",
        .tv_embedded => "2.0",
        .mweb => "2.20241126.01.00",
    };
}

// ── API Endpoints ──

pub const Endpoint = enum {
    player,
    browse,
    search,
    next,
    resolve,

    pub fn path(self: Endpoint) []const u8 {
        return switch (self) {
            .player => "/youtubei/v1/player",
            .browse => "/youtubei/v1/browse",
            .search => "/youtubei/v1/search",
            .next => "/youtubei/v1/next",
            .resolve => "/youtubei/v1/navigation/resolve_url",
        };
    }
};

// ── Core request function ──

/// Make an InnerTube API request.
/// `endpoint`: which API endpoint to call
/// `client`: which client context to use
/// `body_extra`: additional JSON fields to include in the request body (without outer braces)
///   e.g., "\"videoId\":\"dQw4w9WgXcQ\"" for player requests
/// Returns: slice of the response body, or empty on failure.
pub fn request(endpoint: Endpoint, client: ClientType, body_extra: []const u8) []const u8 {
    if (!ensureHttp()) return "";

    // Build JSON body
    var body: [4096]u8 = undefined;
    const body_len = buildBody(client, body_extra, &body);

    // Build URL path as UTF-16
    const ep_path = endpoint.path();
    var path_w: [64]u16 = undefined;
    for (0..ep_path.len) |i| path_w[i] = ep_path[i];
    path_w[ep_path.len] = 0;

    // WinHTTP calls
    const W_AGENT = comptime toWide("zpm-youtube/1.0");
    const W_HOST = comptime toWide("www.youtube.com");
    const W_POST = comptime toWide("POST");
    const W_CT = comptime toWide("Content-Type: application/json\r\n");
    const W_ORIGIN = comptime toWide("Origin: https://www.youtube.com\r\n");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return "";
    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse {
        _ = fn_closeHandle.?(hSession);
        return "";
    };
    const hRequest = fn_openReq.?(hConnect, &W_POST, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return "";
    };

    // Headers
    _ = fn_addHeaders.?(hRequest, &W_CT, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    _ = fn_addHeaders.?(hRequest, &W_ORIGIN, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

    // Add User-Agent for iOS/Android clients
    if (client == .ios) {
        const W_UA_IOS = comptime toWide("User-Agent: com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_7_1 like Mac OS X;)\r\n");
        _ = fn_addHeaders.?(hRequest, &W_UA_IOS, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    } else if (client == .android or client == .android_vr) {
        const W_UA_ANDROID = comptime toWide("User-Agent: com.google.android.youtube/19.29.37 (Linux; U; Android 14) gzip\r\n");
        _ = fn_addHeaders.?(hRequest, &W_UA_ANDROID, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    }

    // Send
    if (fn_sendReq.?(hRequest, null, 0, @ptrCast(@constCast(body[0..body_len].ptr)), @intCast(body_len), @intCast(body_len), 0) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return "";
    }

    if (fn_recvResp.?(hRequest, null) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return "";
    }

    // Read response
    response_len = 0;
    while (response_len < RESPONSE_BUF_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, response_buf[response_len..].ptr, @intCast(RESPONSE_BUF_SIZE - response_len), &n) == 0) break;
        if (n == 0) break;
        response_len += n;
    }

    _ = fn_closeHandle.?(hRequest);
    _ = fn_closeHandle.?(hConnect);
    _ = fn_closeHandle.?(hSession);

    return response_buf[0..response_len];
}

// ── Convenience functions ──

/// Get player data for a video ID.
/// Returns raw JSON response from /youtubei/v1/player.
pub fn player(video_id: []const u8) []const u8 {
    var extra: [64]u8 = undefined;
    const elen = buildKV(&extra, "\"videoId\":\"", video_id, "\"");
    return request(.player, .web, extra[0..elen]);
}

/// Get player data using ANDROID client (sometimes returns direct URLs).
pub fn playerAndroid(video_id: []const u8) []const u8 {
    var extra: [64]u8 = undefined;
    const elen = buildKV(&extra, "\"videoId\":\"", video_id, "\"");
    return request(.player, .android, extra[0..elen]);
}

/// Get player data using IOS client (best for getting stream URLs without cipher).
pub fn playerIos(video_id: []const u8) []const u8 {
    var extra: [64]u8 = undefined;
    const elen = buildKV(&extra, "\"videoId\":\"", video_id, "\"");
    return request(.player, .ios, extra[0..elen]);
}

/// Get player data using WEB_EMBEDDED client (NO PO TOKEN REQUIRED for embeddable videos).
pub fn playerWebEmbed(video_id: []const u8) []const u8 {
    var extra: [64]u8 = undefined;
    const elen = buildKV(&extra, "\"videoId\":\"", video_id, "\"");
    return request(.player, .web_embedded, extra[0..elen]);
}

/// Get player data using ANDROID_VR client (NO PO TOKEN REQUIRED).
pub fn playerAndroidVr(video_id: []const u8) []const u8 {
    var extra: [64]u8 = undefined;
    const elen = buildKV(&extra, "\"videoId\":\"", video_id, "\"");
    return request(.player, .android_vr, extra[0..elen]);
}

/// Get player data using TV_EMBEDDED client (fewer age restrictions).
pub fn playerTvEmbed(video_id: []const u8) []const u8 {
    var extra: [64]u8 = undefined;
    const elen = buildKV(&extra, "\"videoId\":\"", video_id, "\"");
    return request(.player, .tv_embedded, extra[0..elen]);
}

/// Browse a channel's videos tab.
/// `channel_id`: starts with "UC..." (24 chars)
pub fn browseChannel(channel_id: []const u8) []const u8 {
    var extra: [128]u8 = undefined;
    var pos: usize = 0;
    pos = appendS(&extra, pos, "\"browseId\":\"");
    pos = appendS(&extra, pos, channel_id);
    pos = appendS(&extra, pos, "\",\"params\":\"EgZ2aWRlb3PyBgQKAjoA\""); // videos tab param
    return request(.browse, .web, extra[0..pos]);
}

/// Browse with a continuation token (for pagination).
pub fn browseContinuation(continuation: []const u8) []const u8 {
    var extra: [512]u8 = undefined;
    var pos: usize = 0;
    pos = appendS(&extra, pos, "\"continuation\":\"");
    const clen = @min(continuation.len, 450);
    @memcpy(extra[pos .. pos + clen], continuation[0..clen]);
    pos += clen;
    pos = appendS(&extra, pos, "\"");
    return request(.browse, .web, extra[0..pos]);
}

/// Search YouTube.
pub fn search(query_text: []const u8) []const u8 {
    var extra: [512]u8 = undefined;
    var pos: usize = 0;
    pos = appendS(&extra, pos, "\"query\":\"");
    // JSON-escape the query
    for (query_text) |c| {
        if (pos >= 490) break;
        switch (c) {
            '"' => { extra[pos] = '\\'; pos += 1; extra[pos] = '"'; pos += 1; },
            '\\' => { extra[pos] = '\\'; pos += 1; extra[pos] = '\\'; pos += 1; },
            else => { extra[pos] = c; pos += 1; },
        }
    }
    pos = appendS(&extra, pos, "\"");
    return request(.search, .web, extra[0..pos]);
}

/// Fetch the raw watch page HTML for a video (needed to find player.js URL).
/// Uses a separate GET request (not InnerTube POST).
pub fn fetchWatchPage(video_id: []const u8) []const u8 {
    if (!ensureHttp()) return "";

    // Build path: /watch?v=XXXXXXXXXXX
    var path_buf: [64]u8 = undefined;
    var plen: usize = 0;
    const prefix = "/watch?v=";
    @memcpy(path_buf[plen .. plen + prefix.len], prefix);
    plen += prefix.len;
    const id_len = @min(video_id.len, 11);
    @memcpy(path_buf[plen .. plen + id_len], video_id[0..id_len]);
    plen += id_len;

    var path_w: [64]u16 = undefined;
    for (0..plen) |i| path_w[i] = path_buf[i];
    path_w[plen] = 0;

    const W_AGENT = comptime toWide("Mozilla/5.0");
    const W_HOST = comptime toWide("www.youtube.com");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return "";
    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse {
        _ = fn_closeHandle.?(hSession);
        return "";
    };
    // GET request (verb = null defaults to GET)
    const hRequest = fn_openReq.?(hConnect, null, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return "";
    };

    if (fn_sendReq.?(hRequest, null, 0, null, 0, 0, 0) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return "";
    }
    if (fn_recvResp.?(hRequest, null) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return "";
    }

    response_len = 0;
    while (response_len < RESPONSE_BUF_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, response_buf[response_len..].ptr, @intCast(RESPONSE_BUF_SIZE - response_len), &n) == 0) break;
        if (n == 0) break;
        response_len += n;
    }

    _ = fn_closeHandle.?(hRequest);
    _ = fn_closeHandle.?(hConnect);
    _ = fn_closeHandle.?(hSession);

    return response_buf[0..response_len];
}

/// Fetch a JavaScript file (player.js) by path.
/// path: e.g., "/s/player/abcdef01/player_ias.vflset/en_US/base.js"
/// Writes to the provided buffer. Returns bytes written.
pub fn fetchPlayerJs(js_path: []const u8, out_buf: [*]u8, out_cap: usize) usize {
    if (!ensureHttp()) return 0;

    var path_w: [256]u16 = undefined;
    const plen = @min(js_path.len, 255);
    for (0..plen) |i| path_w[i] = js_path[i];
    path_w[plen] = 0;

    const W_AGENT = comptime toWide("Mozilla/5.0");
    const W_HOST = comptime toWide("www.youtube.com");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return 0;
    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse {
        _ = fn_closeHandle.?(hSession);
        return 0;
    };
    const hRequest = fn_openReq.?(hConnect, null, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return 0;
    };

    if (fn_sendReq.?(hRequest, null, 0, null, 0, 0, 0) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return 0;
    }
    if (fn_recvResp.?(hRequest, null) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return 0;
    }

    var total: usize = 0;
    while (total < out_cap) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, out_buf + total, @intCast(@min(out_cap - total, 0x7FFFFFFF)), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }

    _ = fn_closeHandle.?(hRequest);
    _ = fn_closeHandle.?(hConnect);
    _ = fn_closeHandle.?(hSession);

    return total;
}

// ── JSON body builder ──

fn buildBody(client: ClientType, extra: []const u8, body: *[4096]u8) usize {
    var pos: usize = 0;

    pos = appendS(body, pos, "{\"context\":{\"client\":{\"clientName\":\"");
    pos = appendS(body, pos, clientName(client));
    pos = appendS(body, pos, "\",\"clientVersion\":\"");
    pos = appendS(body, pos, clientVersion(client));
    pos = appendS(body, pos, "\",\"hl\":\"en\",\"gl\":\"US\"");

    // Add platform-specific fields
    switch (client) {
        .ios => {
            pos = appendS(body, pos, ",\"deviceMake\":\"Apple\",\"deviceModel\":\"iPhone16,2\",\"osName\":\"iOS\",\"osVersion\":\"17.7.1\"");
        },
        .android, .android_vr => {
            pos = appendS(body, pos, ",\"androidSdkVersion\":34,\"osName\":\"Android\",\"osVersion\":\"14\",\"platform\":\"MOBILE\"");
        },
        else => {},
    }

    pos = appendS(body, pos, "}}");

    // Add content check flags (required for many videos)
    pos = appendS(body, pos, ",\"contentCheckOk\":true,\"racyCheckOk\":true");

    if (extra.len > 0) {
        pos = appendS(body, pos, ",");
        @memcpy(body[pos .. pos + extra.len], extra);
        pos += extra.len;
    }

    pos = appendS(body, pos, "}");
    return pos;
}

fn buildKV(buf: *[64]u8, prefix: []const u8, value: []const u8, suffix: []const u8) usize {
    var pos: usize = 0;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    const vlen = @min(value.len, 30);
    @memcpy(buf[pos .. pos + vlen], value[0..vlen]);
    pos += vlen;
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    return pos;
}

// ── Helpers ──

fn appendS(buf: anytype, pos: usize, s: []const u8) usize {
    const len = @min(s.len, buf.len - pos);
    @memcpy(buf[pos .. pos + len], s[0..len]);
    return pos + len;
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
    fn_addHeaders = @ptrCast(GetProcAddress(dll, "WinHttpAddRequestHeaders"));
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
