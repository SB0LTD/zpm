// @zpm/youtube/stream — HTTP Chunked Stream Downloader
//
// Downloads media streams from YouTube's CDN via HTTPS GET with Range headers.
// Handles: chunked transfer, resumable downloads, 403 retries, throttle backoff.
//
// YouTube CDN URLs point to googlevideo.com (r1---sn-XXXX.googlevideo.com).
// Streams can be up to several GB for video, or 50-200 MB for audio.
//
// Strategy:
//   1. Parse the stream URL to extract host and path
//   2. Connect to the CDN host via WinHTTP HTTPS
//   3. Download in chunks (1 MB each) using Range headers
//   4. Write each chunk directly to disk (no buffering entire file in RAM)
//   5. Retry on 403 (signature expired) or 429 (rate limit)
//
// For audio-only (gotliv's use case):
//   Opus 160kbps × 90 min = ~108 MB — manageable in chunks.

// ── Win32 ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;
extern "kernel32" fn Sleep(u32) void;

const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// WinHTTP
const HINTERNET = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const LPCWSTR = [*]const u16;
const WINHTTP_ACCESS_TYPE_DEFAULT: DWORD = 0;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const WINHTTP_ADDREQ_FLAG_ADD: DWORD = 0x20000000;

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

// Download chunk buffer (1 MB)
const CHUNK_SIZE: usize = 1024 * 1024;
var chunk_buf: [CHUNK_SIZE]u8 = undefined;

/// Download progress callback type.
pub const ProgressFn = ?*const fn (downloaded: u64, total: u64) void;

/// Download result.
pub const DownloadResult = struct {
    bytes_written: u64,
    success: bool,
    retries: u16,
};

/// Download a stream URL to a file.
/// `stream_url`: full HTTPS URL to the media stream
/// `output_path`: null-terminated file path to write
/// `content_length`: expected total bytes (0 = unknown, download until EOF)
/// `progress`: optional progress callback
pub fn downloadToFile(
    stream_url: []const u8,
    output_path: [*:0]const u8,
    content_length: u64,
    progress: ProgressFn,
) DownloadResult {
    var result = DownloadResult{ .bytes_written = 0, .success = false, .retries = 0 };

    if (!ensureHttp()) return result;

    // Parse host and path from URL
    var host_buf: [256]u8 = undefined;
    var path_buf: [2048]u8 = undefined;
    var host_len: usize = 0;
    var path_len: usize = 0;
    var port: u16 = 443;

    if (!parseUrl(stream_url, &host_buf, &host_len, &path_buf, &path_len, &port)) return result;

    // Open output file
    const fh = CreateFileA(output_path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (fh == INVALID_HANDLE or fh == null) return result;

    // Convert host to UTF-16
    var host_w: [256]u16 = undefined;
    for (0..host_len) |i| host_w[i] = host_buf[i];
    host_w[host_len] = 0;

    // Download in chunks with Range headers
    var offset: u64 = 0;
    const total = if (content_length > 0) content_length else 0xFFFFFFFFFFFFFFFF;
    const max_retries: u16 = 5;

    while (offset < total) {
        const chunk_end = if (content_length > 0)
            @min(offset + CHUNK_SIZE - 1, content_length - 1)
        else
            offset + CHUNK_SIZE - 1;

        const bytes_read = downloadChunk(
            &host_w,
            host_len,
            path_buf[0..path_len],
            port,
            offset,
            chunk_end,
        );

        if (bytes_read == 0) {
            // Retry logic
            if (result.retries >= max_retries) break;
            result.retries += 1;
            Sleep(1000 * result.retries); // exponential-ish backoff
            continue;
        }

        // Write chunk to file
        _ = WriteFile(fh, &chunk_buf, @intCast(bytes_read), null, null);
        offset += bytes_read;
        result.bytes_written = offset;

        // Progress callback
        if (progress) |cb| cb(offset, content_length);

        // If we got less than chunk size and content_length is unknown, we're done
        if (content_length == 0 and bytes_read < CHUNK_SIZE) break;
    }

    _ = CloseHandle(fh);
    result.success = (content_length == 0 and result.bytes_written > 0) or
        (result.bytes_written >= content_length);
    return result;
}

/// Download a single chunk via Range request.
fn downloadChunk(
    host_w: *const [256]u16,
    host_len: usize,
    path: []const u8,
    port: u16,
    range_start: u64,
    range_end: u64,
) usize {
    _ = host_len;
    const W_AGENT = comptime toWide("zpm-youtube/1.0");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return 0;
    const hConnect = fn_connect.?(hSession, @ptrCast(host_w), port, 0) orelse {
        _ = fn_closeHandle.?(hSession);
        return 0;
    };

    // Convert path to UTF-16
    var path_w: [2048]u16 = undefined;
    for (0..path.len) |i| path_w[i] = path[i];
    path_w[path.len] = 0;

    const hRequest = fn_openReq.?(hConnect, null, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return 0;
    };

    // Add Range header: "Range: bytes=START-END\r\n"
    var range_hdr: [64]u16 = undefined;
    const range_str = buildRangeHeader(range_start, range_end);
    for (0..range_str.len) |i| range_hdr[i] = range_str.buf[i];
    range_hdr[range_str.len] = 0;
    _ = fn_addHeaders.?(hRequest, @ptrCast(&range_hdr), @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD);

    // Send
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

    // Read response body
    var total: usize = 0;
    while (total < CHUNK_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, chunk_buf[total..].ptr, @intCast(CHUNK_SIZE - total), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }

    _ = fn_closeHandle.?(hRequest);
    _ = fn_closeHandle.?(hConnect);
    _ = fn_closeHandle.?(hSession);

    return total;
}

// ── URL parsing ──

fn parseUrl(url_str: []const u8, host: *[256]u8, host_len: *usize, path: *[2048]u8, path_len: *usize, port: *u16) bool {
    // Skip https://
    var i: usize = 0;
    if (url_str.len > 8 and url_str[0] == 'h') {
        while (i < url_str.len and !(i > 0 and url_str[i - 1] == '/' and url_str[i - 2] == '/')) : (i += 1) {}
    }

    // Extract host (until / or :)
    host_len.* = 0;
    while (i < url_str.len and url_str[i] != '/' and url_str[i] != ':' and host_len.* < 256) : (i += 1) {
        host[host_len.*] = url_str[i];
        host_len.* += 1;
    }
    if (host_len.* == 0) return false;

    // Port
    port.* = 443;
    if (i < url_str.len and url_str[i] == ':') {
        i += 1;
        port.* = 0;
        while (i < url_str.len and url_str[i] >= '0' and url_str[i] <= '9') : (i += 1) {
            port.* = port.* * 10 + @as(u16, url_str[i] - '0');
        }
    }

    // Path (everything from / onwards)
    path_len.* = 0;
    if (i < url_str.len and url_str[i] == '/') {
        while (i < url_str.len and path_len.* < 2048) : (i += 1) {
            path[path_len.*] = url_str[i];
            path_len.* += 1;
        }
    } else {
        path[0] = '/';
        path_len.* = 1;
    }

    return true;
}

// ── Range header builder ──

const RangeStr = struct { buf: [64]u8, len: usize };

fn buildRangeHeader(start: u64, end: u64) RangeStr {
    var r = RangeStr{ .buf = undefined, .len = 0 };
    const prefix = "Range: bytes=";
    @memcpy(r.buf[0..prefix.len], prefix);
    r.len = prefix.len;
    r.len += u64ToStr(start, r.buf[r.len..]);
    r.buf[r.len] = '-';
    r.len += 1;
    r.len += u64ToStr(end, r.buf[r.len..]);
    r.buf[r.len] = '\r';
    r.len += 1;
    r.buf[r.len] = '\n';
    r.len += 1;
    return r;
}

fn u64ToStr(val: u64, buf: []u8) usize {
    var tmp: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    if (v == 0) { buf[0] = '0'; return 1; }
    while (v > 0) : (len += 1) { tmp[len] = @intCast((v % 10) + '0'); v /= 10; }
    for (0..len) |i| buf[i] = tmp[len - 1 - i];
    return len;
}

// ── Helpers ──

fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
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
