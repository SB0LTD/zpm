// @zpm/youtube/thumbnails — Thumbnail Download
//
// Downloads video thumbnails at various resolutions.
// YouTube thumbnails are publicly accessible at predictable URLs:
//   https://i.ytimg.com/vi/{VIDEO_ID}/{quality}.jpg
//
// No API key or yt-dlp needed — direct HTTPS GET via @zpm/http.
//
// Qualities:
//   default    — 120x90
//   mqdefault  — 320x180
//   hqdefault  — 480x360
//   sddefault  — 640x480
//   maxresdefault — 1280x720 (not always available)

const meta = @import("metadata.sig");
const http = @import("net.sig");

// ── Win32 (file output only) ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;

const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

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

    // HTTPS GET to i.ytimg.com via @zpm/http (TLS 1.3, pure Sig).
    const r = http.getInto("i.ytimg.com", 443, path_buf[0..plen], "", "zpm-youtube/1.0", &img_buf);
    if (!r.ok or r.len == 0) return 0;
    const total = r.len;

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
