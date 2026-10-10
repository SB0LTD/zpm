// @zpm/youtube/stream — HTTP Chunked Stream Downloader
//
// Downloads media streams from YouTube's CDN via HTTPS GET with Range headers.
// Handles: ranged transfer, resumable downloads, 403 retries, throttle backoff.
//
// YouTube CDN URLs point to googlevideo.com (r1---sn-XXXX.googlevideo.com).
// Streams can be up to several GB for video, or 50-200 MB for audio.
//
// Strategy:
//   1. Parse the stream URL to extract host and path
//   2. Connect to the CDN host over the pure-Sig @zpm/http TLS 1.3 stack
//   3. Download in chunks (1 MB each) using Range headers
//   4. Write each chunk directly to disk (no buffering entire file in RAM)
//   5. Retry on 403 (signature expired) or 429 (rate limit)
//
// For audio-only (gotliv's use case):
//   Opus 160kbps × 90 min = ~108 MB — manageable in chunks.

const http = @import("net.sig");

// ── Win32 (file output + sleep only) ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn Sleep(u32) void;

const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

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
            host_buf[0..host_len],
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
            var n_written: u32 = 0;
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

/// Download a single chunk via a ranged GET through @zpm/http.
const ChunkResult = struct { bytes: usize = 0, total: u64 = 0, success: bool = false, eof: bool = false };

fn downloadChunk(
    host: []const u8,
    path: []const u8,
    port: u16,
    range_start: u64,
    range_end: u64,
) ChunkResult {
    last_status = 0;
    var result = ChunkResult{};

    const extra = "Origin: https://www.youtube.com\r\nReferer: https://www.youtube.com/\r\nAccept-Encoding: identity\r\n";
    const r = http.getRangeInto(
        host,
        port,
        path,
        extra,
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        range_start,
        range_end,
        &chunk_buf,
    );
    last_status = r.status;
    if (!r.ok) return result;

    // Validate the server's framing before accepting the bytes, exactly as the
    // old WinHTTP path did (206 → verify Content-Range; 200 at offset 0 → use
    // the full Content-Length as total).
    var expected: usize = 0;
    if (r.status == 206) {
        const cr = parseContentRange(r.content_range) orelse return result;
        if (cr.start != range_start or cr.end > range_end) return result;
        const range_len = cr.end - cr.start + 1;
        const got = r.len;
        if (got == 0 or got > CHUNK_SIZE or got != range_len) return result;
        expected = got;
        result.total = cr.total;
    } else if (r.status == 200 and range_start == 0) {
        const got = r.len;
        if (got == 0 or got > CHUNK_SIZE or (r.content_length > 0 and r.content_length != got)) return result;
        expected = got;
        result.total = got; // whole resource delivered in one shot
    } else {
        return result;
    }

    result.bytes = expected;
    result.success = true;
    // EOF terminates the response range, rather than the whole resource.
    if (result.total > 0) result.eof = range_start + expected == result.total;
    return result;
}

pub const ContentRange = struct { start: u64, end: u64, total: u64 };

/// Parse the server's complete range metadata ("bytes start-end/total").
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
    const end = parseDecimal(header[dash + 1 .. slash]) orelse return null;
    const total = parseDecimal(header[slash + 1 ..]) orelse return null;
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

// Tests (inline, std.testing) -- content-range + URL parsing (pure, offline).
const std = @import("std");
const testing = std.testing;

test "stream: parseContentRange reads start/end/total" {
    const r = parseContentRange("bytes 0-1048575/5242880").?;
    try testing.expectEqual(@as(u64, 0), r.start);
    try testing.expectEqual(@as(u64, 1048575), r.end);
    try testing.expectEqual(@as(u64, 5242880), r.total);
}

test "stream: parseContentRange rejects end>=total" {
    try testing.expect(parseContentRange("bytes 0-10/10") == null);
}

test "stream: parseUrl splits host and path" {
    var host: [256]u8 = undefined;
    var path: [9216]u8 = undefined;
    var hl: usize = 0;
    var pl: usize = 0;
    var port: u16 = 0;
    try testing.expect(parseUrl("https://r1.googlevideo.com/videoplayback?x=1", &host, &hl, &path, &pl, &port));
    try testing.expectEqualSlices(u8, "r1.googlevideo.com", host[0..hl]);
    try testing.expectEqualSlices(u8, "/videoplayback?x=1", path[0..pl]);
    try testing.expectEqual(@as(u16, 443), port);
}
