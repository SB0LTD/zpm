// @zpm/youtube/botguard/challenge — WAA Challenge Fetcher
//
// Fetches BotGuard challenge data from Google's Web Anti-Abuse API.
// The challenge contains:
//   - The VM interpreter JavaScript (URL or inline)
//   - A bytecode program to run in the VM
//   - The global object name for accessing the VM
//
// Two methods:
//   1. WAA Create API (POST to jnn-pa.googleapis.com)
//   2. Extract from YouTube watch page HTML (embedded in ytInitialPlayerResponse)

// ── Win32 WinHTTP ──
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;

const HINTERNET = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*]const u16;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

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

fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
}

// ── Challenge data ──

pub const MAX_SCRIPT_SIZE: usize = 768 * 1024; // BG scripts are ~500KB
pub const MAX_PROGRAM_SIZE: usize = 16 * 1024;

pub const Challenge = struct {
    // VM script (JavaScript source, fetched from interpreterUrl)
    script: [MAX_SCRIPT_SIZE]u8,
    script_len: usize,
    // Bytecode program (base64-encoded, passed to the VM)
    program: [MAX_PROGRAM_SIZE]u8,
    program_len: usize,
    // Global name (how to access the VM after script execution)
    global_name: [32]u8,
    global_name_len: usize,
    // Interpreter hash (for caching)
    interpreter_hash: [64]u8,
    hash_len: usize,
    // Request key (needed for integrity token step)
    request_key: [128]u8,
    request_key_len: usize,

    pub fn init() Challenge {
        return .{
            .script = undefined,
            .script_len = 0,
            .program = undefined,
            .program_len = 0,
            .global_name = undefined,
            .global_name_len = 0,
            .interpreter_hash = undefined,
            .hash_len = 0,
            .request_key = undefined,
            .request_key_len = 0,
        };
    }
};

// Response buffer
const RESP_BUF_SIZE: usize = 32 * 1024;
var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
var resp_buf_len: usize = 0;

/// Get the raw response buffer (for debugging).
pub fn getRawResponse() []const u8 {
    return resp_buf[0..resp_buf_len];
}

/// Fetch challenge via the WAA Create API.
/// This is the primary method — works without needing a YouTube page.
pub fn fetch(chal: *Challenge) bool {
    if (!ensureHttp()) return false;

    print("  [botguard] Fetching challenge from WAA API...\n");

    // First, get the request key from YouTube's attestation endpoint
    if (!fetchRequestKey(chal)) {
        // Use a known default request key as fallback
        const default_key = "O43z0dpjhgX20SCx4KAo";
        @memcpy(chal.request_key[0..default_key.len], default_key);
        chal.request_key_len = default_key.len;
    }

    // POST to WAA/Create
    const body_prefix = "[\"";
    const body_suffix = "\"]";
    var body: [256]u8 = undefined;
    var blen: usize = 0;
    @memcpy(body[blen .. blen + body_prefix.len], body_prefix);
    blen += body_prefix.len;
    @memcpy(body[blen .. blen + chal.request_key_len], chal.request_key[0..chal.request_key_len]);
    blen += chal.request_key_len;
    @memcpy(body[blen .. blen + body_suffix.len], body_suffix);
    blen += body_suffix.len;

    const resp_len = waaPost("/$rpc/google.internal.waa.v1.Waa/Create", body[0..blen]);
    if (resp_len == 0) {
        print("  [botguard] WAA/Create request failed\n");
        return false;
    }

    print("  [botguard] WAA response: ");
    printNum(resp_len);
    print(" bytes\n");

    // Parse the response to extract interpreterUrl, program, globalName
    return parseWaaResponse(resp_buf[0..resp_len], chal);
}

/// Fetch the VM script from its URL.
/// Called after fetch() successfully extracts the interpreterUrl.
pub fn fetchScript(chal: *Challenge) bool {
    if (chal.hash_len == 0) return false;
    if (!ensureHttp()) return false;

    // The interpreter URL is typically:
    // /s/player/<hash>/player_ias.vflset/en_US/base.js
    // OR from the WAA response as a full URL path

    // Build the script fetch URL
    // For now, use the YouTube player JS URL pattern
    var script_url: [256]u8 = undefined;
    var url_len: usize = 0;

    // If we have an interpreter URL from the challenge, use it
    if (chal.hash_len > 0) {
        // Construct: https://www.youtube.com/s/player/<hash>/...
        // The hash from WAA is the interpreter hash
        // We'll fetch it from www.youtube.com
        const prefix = "/s/player/";
        @memcpy(script_url[0..prefix.len], prefix);
        url_len = prefix.len;
        @memcpy(script_url[url_len .. url_len + chal.hash_len], chal.interpreter_hash[0..chal.hash_len]);
        url_len += chal.hash_len;
        const suffix = "/player_ias.vflset/en_US/base.js";
        @memcpy(script_url[url_len .. url_len + suffix.len], suffix);
        url_len += suffix.len;
    }

    if (url_len == 0) return false;

    print("  [botguard] Fetching VM script...\n");

    // HTTPS GET from www.youtube.com
    const W_AGENT = comptime toWide("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    const W_HOST = comptime toWide("www.youtube.com");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return false;
    defer _ = fn_closeHandle.?(hSession);

    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse return false;
    defer _ = fn_closeHandle.?(hConnect);

    var path_w: [256]u16 = undefined;
    for (0..url_len) |i| path_w[i] = script_url[i];
    path_w[url_len] = 0;

    const hRequest = fn_openReq.?(hConnect, null, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse return false;
    defer _ = fn_closeHandle.?(hRequest);

    if (fn_sendReq.?(hRequest, null, 0, null, 0, 0, 0) == 0) return false;
    if (fn_recvResp.?(hRequest, null) == 0) return false;

    // Read into challenge script buffer
    chal.script_len = 0;
    while (chal.script_len < MAX_SCRIPT_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, chal.script[chal.script_len..].ptr, @intCast(MAX_SCRIPT_SIZE - chal.script_len), &n) == 0) break;
        if (n == 0) break;
        chal.script_len += n;
    }

    print("  [botguard] Script: ");
    printNum(chal.script_len);
    print(" bytes\n");

    return chal.script_len > 0;
}

// ── Internal: fetch request key from YouTube attestation endpoint ──

fn fetchRequestKey(chal: *Challenge) bool {
    // The request key comes from InnerTube's attestation challenge endpoint
    // POST https://www.youtube.com/youtubei/v1/att/get
    // Body: {"context":{"client":{"clientName":"WEB","clientVersion":"2.20241126.01.00"}}}

    const W_AGENT = comptime toWide("Mozilla/5.0");
    const W_HOST = comptime toWide("www.youtube.com");
    const W_POST = comptime toWide("POST");
    const W_PATH = comptime toWide("/youtubei/v1/att/get");
    const W_CT = comptime toWide("Content-Type: application/json\r\n");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return false;
    defer _ = fn_closeHandle.?(hSession);
    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse return false;
    defer _ = fn_closeHandle.?(hConnect);
    const hRequest = fn_openReq.?(hConnect, &W_POST, &W_PATH, null, null, null, WINHTTP_FLAG_SECURE) orelse return false;
    defer _ = fn_closeHandle.?(hRequest);

    _ = fn_addHeaders.?(hRequest, &W_CT, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

    const body = "{\"context\":{\"client\":{\"clientName\":\"WEB\",\"clientVersion\":\"2.20241126.01.00\"}}}";
    if (fn_sendReq.?(hRequest, null, 0, @ptrCast(@constCast(body.ptr)), body.len, body.len, 0) == 0) return false;
    if (fn_recvResp.?(hRequest, null) == 0) return false;

    var total: usize = 0;
    while (total < RESP_BUF_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, resp_buf[total..].ptr, @intCast(RESP_BUF_SIZE - total), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return false;

    // Extract the request key from response
    // Look for "requestKey" or "challenge" field
    const key_marker = "requestKey";
    if (findStrVal(resp_buf[0..total], key_marker)) |val| {
        const klen = @min(val.len, 128);
        @memcpy(chal.request_key[0..klen], val[0..klen]);
        chal.request_key_len = klen;
        return true;
    }

    return false;
}

// ── Internal: WAA POST helper ──

fn waaPost(path: []const u8, body: []const u8) usize {
    const W_AGENT = comptime toWide("grpc-web-javascript/0.1");
    const W_HOST = comptime toWide("jnn-pa.googleapis.com");
    const W_POST = comptime toWide("POST");
    const W_CT = comptime toWide("Content-Type: application/json+protobuf\r\n");
    const W_KEY = comptime toWide("x-goog-api-key: AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw\r\n");
    const W_UA = comptime toWide("x-user-agent: grpc-web-javascript/0.1\r\n");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return 0;
    defer _ = fn_closeHandle.?(hSession);
    const hConnect = fn_connect.?(hSession, &W_HOST, 443, 0) orelse return 0;
    defer _ = fn_closeHandle.?(hConnect);

    var path_w: [128]u16 = undefined;
    for (0..path.len) |i| path_w[i] = path[i];
    path_w[path.len] = 0;

    const hRequest = fn_openReq.?(hConnect, &W_POST, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse return 0;
    defer _ = fn_closeHandle.?(hRequest);

    _ = fn_addHeaders.?(hRequest, &W_CT, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    _ = fn_addHeaders.?(hRequest, &W_KEY, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
    _ = fn_addHeaders.?(hRequest, &W_UA, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

    if (fn_sendReq.?(hRequest, null, 0, @ptrCast(@constCast(body.ptr)), @intCast(body.len), @intCast(body.len), 0) == 0) return 0;
    if (fn_recvResp.?(hRequest, null) == 0) return 0;

    var total: usize = 0;
    while (total < RESP_BUF_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, resp_buf[total..].ptr, @intCast(RESP_BUF_SIZE - total), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }
    resp_buf_len = total;
    return total;
}

// ── Parse WAA Create response ──

fn parseWaaResponse(resp: []const u8, chal: *Challenge) bool {
    // WAA response is a JSON array:
    // [messageId, null, interpreterHash, scriptContent, null, program, globalName, ...]
    // OR it may have interpreterUrl instead of inline script

    // Look for the program (base64 string, usually the longest string in response)
    if (findStrVal(resp, "program")) |prog| {
        const plen = @min(prog.len, MAX_PROGRAM_SIZE);
        @memcpy(chal.program[0..plen], prog[0..plen]);
        chal.program_len = plen;
    }

    // Look for globalName
    if (findStrVal(resp, "globalName")) |gn| {
        const glen = @min(gn.len, 32);
        @memcpy(chal.global_name[0..glen], gn[0..glen]);
        chal.global_name_len = glen;
    }

    // Look for interpreterHash
    if (findStrVal(resp, "interpreterHash")) |ih| {
        const hlen = @min(ih.len, 64);
        @memcpy(chal.interpreter_hash[0..hlen], ih[0..hlen]);
        chal.hash_len = hlen;
    }

    // Look for inline script (interpreterJavascript)
    if (findStrVal(resp, "privateDoNotAccessOrElseSafeScriptWrappedValue")) |script| {
        const slen = @min(script.len, MAX_SCRIPT_SIZE);
        @memcpy(chal.script[0..slen], script[0..slen]);
        chal.script_len = slen;
    }

    // Look for interpreterUrl (if script not inline)
    if (chal.script_len == 0) {
        if (findStrVal(resp, "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue")) |url_val| {
            // Store the URL in interpreter_hash for fetchScript to use
            const ulen = @min(url_val.len, 64);
            @memcpy(chal.interpreter_hash[0..ulen], url_val[0..ulen]);
            chal.hash_len = ulen;
        }
    }

    return chal.program_len > 0;
}

// ── Helpers ──

fn findStrVal(data: []const u8, key: []const u8) ?[]const u8 {
    // Find a JSON string value after a key
    const pos = findStr(data, key) orelse return null;
    var i = pos + key.len;
    // Skip to the value string (past ":", whitespace, quote)
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1; // skip opening quote
    // For inline values that follow immediately
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1; // skip second quote (this might be empty string)
    // Actually we need: find key, skip to ":", find first string value after it
    // Let me redo this properly:
    var j = pos + key.len;
    while (j < data.len and (data[j] == '"' or data[j] == ':' or data[j] == ' ' or data[j] == '\n' or data[j] == '\r' or data[j] == '\t' or data[j] == ',')) : (j += 1) {}
    // j should now be past the delimiter noise. Find the next quoted string.
    while (j < data.len and data[j] != '"') : (j += 1) {}
    if (j >= data.len) return null;
    j += 1; // skip opening quote
    const start = j;
    while (j < data.len and data[j] != '"') : (j += 1) {
        if (data[j] == '\\' and j + 1 < data.len) j += 1; // skip escaped chars
    }
    if (j > start) return data[start..j];
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

fn printNum(val: usize) void {
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    if (v == 0) { print("0"); return; }
    while (v > 0) : (len += 1) { buf[len] = @intCast((v % 10) + '0'); v /= 10; }
    var rev: [20]u8 = undefined;
    for (0..len) |i| rev[i] = buf[len - 1 - i];
    print(rev[0..len]);
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
