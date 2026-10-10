// @zpm/youtube/innertube — Pure Sig InnerTube API Client
//
// Direct HTTP client for YouTube's private InnerTube API.
// No yt-dlp, no Python, no external dependencies. Pure Sig via @zpm/http.
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

const http = @import("net.sig");

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
        .web => "2.20250312.04.00",
        .web_embedded => "2.20250310.01.00",
        .android => "20.10.38",
        .android_vr => "1.62.27",
        .ios => "20.10.4",
        .tv_embedded => "2.0",
        .mweb => "2.20250311.03.00",
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
    // Build JSON body
    var body: [4096]u8 = undefined;
    const body_len = buildBody(client, body_extra, &body);

    // Content-Type + Origin always; the client-specific UA is passed as the
    // user_agent (not a duplicate User-Agent header).
    const hdrs = "Content-Type: application/json\r\nOrigin: https://www.youtube.com\r\n";
    const ua: []const u8 = switch (client) {
        .ios => "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_7_1 like Mac OS X;)",
        .android, .android_vr => "com.google.android.youtube/19.29.37 (Linux; U; Android 14) gzip",
        else => "zpm-youtube/1.0",
    };

    const r = http.postInto("www.youtube.com", 443, endpoint.path(), hdrs, body[0..body_len], ua, &response_buf);
    response_len = r.len;
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

/// Get player data with a PO token in serviceIntegrityDimensions (required by
/// YouTube for most clients as of 2026). `pot` = base64url PO token.
pub fn playerWithPot(video_id: []const u8, client: ClientType, pot: []const u8) []const u8 {
    var extra: [512]u8 = undefined;
    var pos: usize = 0;
    pos = appendS(&extra, pos, "\"videoId\":\"");
    pos = appendS(&extra, pos, video_id);
    pos = appendS(&extra, pos, "\",\"serviceIntegrityDimensions\":{\"poToken\":\"");
    pos = appendS(&extra, pos, pot);
    pos = appendS(&extra, pos, "\"}");
    return request(.player, client, extra[0..pos]);
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
    // Build path: /watch?v=XXXXXXXXXXX
    var path_buf: [64]u8 = undefined;
    var plen: usize = 0;
    const prefix = "/watch?v=";
    @memcpy(path_buf[plen .. plen + prefix.len], prefix);
    plen += prefix.len;
    const id_len = @min(video_id.len, 11);
    @memcpy(path_buf[plen .. plen + id_len], video_id[0..id_len]);
    plen += id_len;

    const r = http.getInto("www.youtube.com", 443, path_buf[0..plen], "", "Mozilla/5.0", &response_buf);
    response_len = r.len;
    return response_buf[0..response_len];
}

/// Fetch a JavaScript file (player.js) by path.
/// path: e.g., "/s/player/abcdef01/player_ias.vflset/en_US/base.js"
/// Writes to the provided buffer. Returns bytes written.
pub fn fetchPlayerJs(js_path: []const u8, out_buf: [*]u8, out_cap: usize) usize {
    const r = http.getInto("www.youtube.com", 443, js_path, "", "Mozilla/5.0", out_buf[0..out_cap]);
    return r.len;
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

