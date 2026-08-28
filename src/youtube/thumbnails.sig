// @zpm/youtube/thumbnails — Thumbnail Download
//
// Downloads video thumbnails at various resolutions.
// YouTube thumbnails are publicly accessible at predictable URLs:
//   https://i.ytimg.com/vi/{VIDEO_ID}/{quality}.jpg
//
// No API key or yt-dlp needed — direct HTTPS GET.
//
// Qualities:
//   default    — 120x90
//   mqdefault  — 320x180
//   hqdefault  — 480x360
//   sddefault  — 640x480
//   maxresdefault — 1280x720 (not always available)

const meta = @import("metadata.sig");

// ── Win32 WinHTTP ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn LoadLibraryA([*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) ?*anyopaque;

const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// WinHTTP function pointers (lazy-loaded)
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

// Image buffer (thumbnails are max ~150KB for maxres)
const IMG_BUF_SIZE: usize = 256 * 1024;
var img_buf: [IMG_BUF_SIZE]u8 = undefined;

/// Thumbnail quality levels.
pub const Quality = enum {
    default, // 120x90
    medium, // 320x180
    high, // 480x360
    standard, // 640x480
    maxres, // 1280x720

    pub fn filename(self: Quality) []const u8 {
        return switch (self) {
            .default => "default",
            .medium => "mqdefault",
            .high => "hqdefault",
            .standard => "sddefault",
            .maxres => "maxresdefault",
        };
    }
};

/// Download a video thumbnail and save to disk.
/// Returns the number of bytes written, or 0 on failure.
pub fn download(video_id: *const [meta.VIDEO_ID_LEN]u8, quality: Quality, output_path: [*:0]const u8) usize {
    if (!ensureHttp()) return 0;

    // Build URL path: /vi/{id}/{quality}.jpg
    var path_buf: [64]u8 = undefined;
    var plen: usize = 0;
    const p1 = "/vi/";
    @memcpy(path_buf[plen .. plen + p1.len], p1);
    plen += p1.len;
    @memcpy(path_buf[plen .. plen + meta.VIDEO_ID_LEN], video_id);
    plen += meta.VIDEO_ID_LEN;
    path_buf[plen] = '/';
    plen += 1;
    const qname = quality.filename();
    @memcpy(path_buf[plen .. plen + qname.len], qname);
    plen += qname.len;
    const ext = ".jpg";
    @memcpy(path_buf[plen .. plen + ext.len], ext);
    plen += ext.len;

    // Convert to UTF-16 for WinHTTP
    var path_w: [80]u16 = undefined;
    for (0..plen) |i| path_w[i] = path_buf[i];
    path_w[plen] = 0;

    // HTTPS GET to i.ytimg.com
    const W_AGENT = comptime toWide("zpm-youtube/1.0");
    const W_HOST = comptime toWide("i.ytimg.com");

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

    // Read response body
    var total: usize = 0;
    while (total < IMG_BUF_SIZE) {
        var n: DWORD = 0;
        if (fn_readData.?(hRequest, img_buf[total..].ptr, @intCast(IMG_BUF_SIZE - total), &n) == 0) break;
        if (n == 0) break;
        total += n;
    }

    _ = fn_closeHandle.?(hRequest);
    _ = fn_closeHandle.?(hConnect);
    _ = fn_closeHandle.?(hSession);

    if (total == 0) return 0;

    // Write to file
    const fh = CreateFileA(output_path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (fh == INVALID_HANDLE or fh == null) return 0;
    _ = WriteFile(fh, &img_buf, @intCast(total), null, null);
    _ = CloseHandle(fh);

    return total;
}

/// Get the public thumbnail URL for a video (no download, just the URL string).
pub fn getUrl(video_id: *const [meta.VIDEO_ID_LEN]u8, quality: Quality, buf: *[128]u8) usize {
    var pos: usize = 0;
    const prefix = "https://i.ytimg.com/vi/";
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos .. pos + meta.VIDEO_ID_LEN], video_id);
    pos += meta.VIDEO_ID_LEN;
    buf[pos] = '/';
    pos += 1;
    const qname = quality.filename();
    @memcpy(buf[pos .. pos + qname.len], qname);
    pos += qname.len;
    const ext = ".jpg";
    @memcpy(buf[pos .. pos + ext.len], ext);
    pos += ext.len;
    return pos;
}

// ── Init ──

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
