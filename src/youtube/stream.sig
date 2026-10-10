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
const WinHttpQueryHeadersFn = *const fn (HINTERNET, DWORD, ?LPCWSTR, ?*anyopaque, *DWORD, ?*DWORD) callconv(.c) BOOL;
const WINHTTP_QUERY_STATUS_CODE: DWORD = 19;
const WINHTTP_QUERY_CONTENT_LENGTH: DWORD = 5;
const WINHTTP_QUERY_CONTENT_RANGE: DWORD = 53;
const WINHTTP_QUERY_FLAG_NUMBER: DWORD = 0x20000000;

var fn_open: ?WinHttpOpenFn = null;
var fn_connect: ?WinHttpConnectFn = null;
var fn_openReq: ?WinHttpOpenRequestFn = null;
var fn_sendReq: ?WinHttpSendRequestFn = null;
var fn_recvResp: ?WinHttpReceiveResponseFn = null;
var fn_readData: ?WinHttpReadDataFn = null;
var fn_closeHandle: ?WinHttpCloseHandleFn = null;
var fn_addHeaders: ?WinHttpAddRequestHeadersFn = null;
var fn_queryHeaders: ?WinHttpQueryHeadersFn = null;
var http_loaded: bool = false;
// Last HTTP status code observed by downloadChunk (for diagnostics).
pub var last_status: u32 = 0;

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
    var path_buf: [9216]u8 = undefined;
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
    var total = if (content_length > 0) content_length else 0xFFFFFFFFFFFFFFFF;
    const max_retries: u16 = 5;
    var retries_at_offset: u16 = 0;
    var complete = false;
    defer _ = CloseHandle(fh);

    while (offset < total) {
        const chunk_end = @min(offset + CHUNK_SIZE - 1, total - 1);

        const chunk = downloadChunk(
            &host_w,
            host_len,
            path_buf[0..path_len],
            port,
            offset,
            chunk_end,
        );

        if (!chunk.success) {
            // Retry logic
            if (retries_at_offset >= max_retries) break;
            retries_at_offset += 1;
            result.retries +|= 1;
            Sleep(1000 * retries_at_offset);
            continue;
        }
        retries_at_offset = 0;
        if (chunk.total > 0) {
            if (content_length > 0 and chunk.total != content_length) break;
            total = chunk.total;
        }
        const bytes_read = chunk.bytes;
        if (bytes_read == 0) {
            complete = chunk.eof and offset > 0 and (total == 0xFFFFFFFFFFFFFFFF or offset == total);
            break;
        }

        // Write chunk to file
        var written: usize = 0;
        while (written < bytes_read) {
            var n_written: DWORD = 0;
            if (WriteFile(fh, chunk_buf[written..].ptr, @intCast(bytes_read - written), &n_written, null) == 0 or n_written == 0) {
                result.bytes_written = offset + written;
                return result;
            }
            written += n_written;
        }
        offset += bytes_read;
        result.bytes_written = offset;

        // Progress callback
        if (progress) |cb| cb(offset, content_length);

        if (offset == total or (chunk.eof and total == 0xFFFFFFFFFFFFFFFF)) { complete = true; break; }
    }

    result.success = complete and result.bytes_written > 0;
    return result;
}

/// Download a single chunk via Range request.
const ChunkResult = struct { bytes: usize = 0, total: u64 = 0, success: bool = false, eof: bool = false };

fn downloadChunk(
    host_w: *const [256]u16,
    host_len: usize,
    path: []const u8,
    port: u16,
    range_start: u64,
    range_end: u64,
) ChunkResult {
    _ = host_len;
    last_status = 0;
    const W_AGENT = comptime toWide("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36");

    const hSession = fn_open.?(&W_AGENT, WINHTTP_ACCESS_TYPE_DEFAULT, null, null, 0) orelse return .{};
    const hConnect = fn_connect.?(hSession, @ptrCast(host_w), port, 0) orelse {
        _ = fn_closeHandle.?(hSession);
        return .{};
    };

    // Convert path to UTF-16
    var path_w: [9216]u16 = undefined;
    if (path.len >= path_w.len) {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return .{};
    }
    for (0..path.len) |i| path_w[i] = path[i];
    path_w[path.len] = 0;

    const hRequest = fn_openReq.?(hConnect, null, @ptrCast(&path_w), null, null, null, WINHTTP_FLAG_SECURE) orelse {
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return .{};
    };

    // Add Range header: "Range: bytes=START-END\r\n"
    var range_hdr: [64]u16 = undefined;
    const range_str = buildRangeHeader(range_start, range_end);
    for (0..range_str.len) |i| range_hdr[i] = range_str.buf[i];
    range_hdr[range_str.len] = 0;
    _ = fn_addHeaders.?(hRequest, @ptrCast(&range_hdr), @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD);
    const W_HEADERS = comptime toWide("Origin: https://www.youtube.com\r\nReferer: https://www.youtube.com/\r\nAccept-Encoding: identity\r\n");
    _ = fn_addHeaders.?(hRequest, &W_HEADERS, @bitCast(@as(i32, -1)), WINHTTP_ADDREQ_FLAG_ADD);

    // Send
    if (fn_sendReq.?(hRequest, null, 0, null, 0, 0, 0) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return .{};
    }
    if (fn_recvResp.?(hRequest, null) == 0) {
        _ = fn_closeHandle.?(hRequest);
        _ = fn_closeHandle.?(hConnect);
        _ = fn_closeHandle.?(hSession);
        return .{};
    }

    // Query HTTP status code (diagnostics + treat non-2xx as failure)
    if (fn_queryHeaders) |qh| {
        var status_code: DWORD = 0;
        var sc_len: DWORD = @sizeOf(DWORD);
        if (qh(hRequest, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, &status_code, &sc_len, null) != 0) {
            last_status = status_code;
            if (status_code != 200 and status_code != 206) {
                _ = fn_closeHandle.?(hRequest);
                _ = fn_closeHandle.?(hConnect);
                _ = fn_closeHandle.?(hSession);
                return .{};
            }
        }
    }
    defer _ = fn_closeHandle.?(hRequest);
    defer _ = fn_closeHandle.?(hConnect);
    defer _ = fn_closeHandle.?(hSession);
    var result = ChunkResult{};
    var expected: usize = 0;
    if (last_status == 206) {
        var header: [128]u8 = undefined;
        const len = readHeader(hRequest, WINHTTP_QUERY_CONTENT_RANGE, &header);
        const range = parseContentRange(header[0..len]) orelse return result;
        if (range.start != range_start or range.end > range_end or range.end < range.start) return result;
        const n = range.end - range.start + 1;
        if (n > CHUNK_SIZE) return result;
        expected = @intCast(n);
        result.total = range.total;
    } else if (last_status == 200 and range_start == 0) {
        var header: [32]u8 = undefined;
        const len = readHeader(hRequest, WINHTTP_QUERY_CONTENT_LENGTH, &header);
        if (len > 0) {
            const n = parseDecimal(header[0..len]) orelse return result;
            if (n == 0 or n > CHUNK_SIZE) return result;
            expected = @intCast(n);
            result.total = n;
        }
    } else return result;

    // Read response body
    var total: usize = 0;
    while (total < CHUNK_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, chunk_buf[total..].ptr, @intCast(CHUNK_SIZE - total), &n) == 0) return result;
        if (n == 0) { result.eof = true; break; }
        total += n;
    }
    if (expected > 0 and total != expected) return result;
    if (expected == 0 and !result.eof) return result;
    result.bytes = total;
    result.success = true;
    // EOF terminates the response range, rather than the whole resource.
    if (result.total > 0) result.eof = range_start + total == result.total;
    return result;
}

fn readHeader(request: HINTERNET, kind: DWORD, out: []u8) usize {
    var wide: [128]u16 = undefined;
    var size: DWORD = @sizeOf(@TypeOf(wide));
    if (fn_queryHeaders.?(request, kind, null, &wide, &size, null) == 0) return 0;
    var n: usize = 0;
    while (n < wide.len and wide[n] != 0 and n < out.len) : (n += 1) {
        if (wide[n] > 127) return 0;
        out[n] = @intCast(wide[n]);
    }
    return n;
}

pub const ContentRange = struct { start: u64, end: u64, total: u64 };

/// Parse the server's complete range metadata before accepting response bytes.
pub fn parseContentRange(header: []const u8) ?ContentRange {
    const prefix = "bytes ";
    if (header.len <= prefix.len) return null;
    for (prefix, 0..) |c, i| if (header[i] != c) return null;
    var dash: usize = prefix.len;
    while (dash < header.len and header[dash] != '-') : (dash += 1) {}
    var slash = dash + 1;
    while (slash < header.len and header[slash] != '/') : (slash += 1) {}
    if (dash >= header.len or slash >= header.len) return null;
    const start = parseDecimal(header[prefix.len..dash]) orelse return null;
    const end = parseDecimal(header[dash + 1..slash]) orelse return null;
    const total = parseDecimal(header[slash + 1..]) orelse return null;
    if (end < start or total == 0 or end >= total) return null;
    return .{ .start = start, .end = end, .total = total };
}

fn parseDecimal(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u64 = c - '0';
        if (n > (0xFFFFFFFFFFFFFFFF - digit) / 10) return null;
        n = n * 10 + digit;
    }
    return n;
}

// ── URL parsing ──

fn parseUrl(url_str: []const u8, host: *[256]u8, host_len: *usize, path: *[9216]u8, path_len: *usize, port: *u16) bool {
    const scheme = "https://";
    if (url_str.len <= scheme.len) return false;
    for (scheme, 0..) |c, j| if (url_str[j] != c) return false;
    var i: usize = scheme.len;

    // Extract host (until / or :)
    host_len.* = 0;
    while (i < url_str.len and url_str[i] != '/' and url_str[i] != ':') : (i += 1) {
        if (host_len.* >= host.len - 1 or url_str[i] <= 32 or url_str[i] >= 127) return false;
        host[host_len.*] = url_str[i];
        host_len.* += 1;
    }
    if (host_len.* == 0) return false;

    // Port
    port.* = 443;
    if (i < url_str.len and url_str[i] == ':') {
        i += 1;
        var value: u32 = 0;
        const start = i;
        while (i < url_str.len and url_str[i] >= '0' and url_str[i] <= '9') : (i += 1) {
            value = value * 10 + @as(u32, url_str[i] - '0');
            if (value > 65535) return false;
        }
        if (i == start or value == 0) return false;
        port.* = @intCast(value);
    }

    // Path (everything from / onwards)
    path_len.* = 0;
    if (i < url_str.len and url_str[i] == '/') {
        while (i < url_str.len) : (i += 1) {
            if (path_len.* >= path.len - 1 or url_str[i] < 32 or url_str[i] >= 127) return false;
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
    fn_queryHeaders = @ptrCast(GetProcAddress(dll, "WinHttpQueryHeaders"));
    if (fn_open == null or fn_connect == null or fn_openReq == null or fn_sendReq == null or
        fn_recvResp == null or fn_readData == null or fn_closeHandle == null or
        fn_addHeaders == null or fn_queryHeaders == null) return false;
    http_loaded = true;
    return true;
}

fn toWide(comptime s: []const u8) [s.len + 1]u16 {
    var r: [s.len + 1]u16 = undefined;
    for (0..s.len) |i| r[i] = s[i];
    r[s.len] = 0;
    return r;
}
