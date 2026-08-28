// @zpm/youtube/playlist — Playlist Operations
//
// List playlist contents, enumerate a channel's playlists, and extract
// video ordering within playlists. All via yt-dlp (no API key needed).
//
// Usage:
//   const n = playlist.listVideos("PLxxxxxxxxxx", &results);
//   const np = playlist.listChannelPlaylists("https://.../@handle", &playlists);

const meta = @import("metadata.sig");
const url_mod = @import("url.sig");

// ── Win32 ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn ReadFile(?*anyopaque, [*]u8, u32, *u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn DeleteFileA([*:0]const u8) c_int;
extern "kernel32" fn CreateProcessA(
    ?[*:0]const u8, ?[*:0]u8, ?*anyopaque, ?*anyopaque,
    c_int, u32, ?*anyopaque, ?[*:0]const u8,
    *StartupInfo, *ProcessInfo,
) c_int;
extern "kernel32" fn WaitForSingleObject(?*anyopaque, u32) u32;
extern "kernel32" fn GetExitCodeProcess(?*anyopaque, *u32) c_int;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INFINITE: u32 = 0xFFFFFFFF;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const StartupInfo = extern struct {
    cb: u32 = @sizeOf(StartupInfo),
    reserved: ?[*:0]u8 = null, desktop: ?[*:0]u8 = null, title: ?[*:0]u8 = null,
    x: u32 = 0, y: u32 = 0, xsize: u32 = 0, ysize: u32 = 0,
    xcountchars: u32 = 0, ycountchars: u32 = 0,
    fillattr: u32 = 0, flags: u32 = 0,
    showwindow: u16 = 0, reserved2: u16 = 0,
    reserved3: ?*anyopaque = null, stdin: ?*anyopaque = null,
    stdout: ?*anyopaque = null, stderr: ?*anyopaque = null,
};

const ProcessInfo = extern struct {
    process: ?*anyopaque = null, thread: ?*anyopaque = null,
    process_id: u32 = 0, thread_id: u32 = 0,
};

const SCAN_BUF_SIZE: usize = 2 * 1024 * 1024;
var scan_buf: [SCAN_BUF_SIZE]u8 = undefined;
const TEMP_PATH = ".yt_playlist_tmp.txt\x00";

/// Playlist metadata.
pub const PlaylistInfo = struct {
    id: [34]u8, // "PL" + 32 chars (or shorter)
    id_len: u8,
    title: [128]u8,
    title_len: u8,
    video_count: u16,
};

pub const MAX_PLAYLISTS: usize = 256;

/// List all videos in a playlist by playlist ID or URL.
/// Returns number of videos found.
pub fn listVideos(playlist_url: []const u8, results: []meta.VideoMeta) usize {
    var cmd: [1024]u8 = undefined;
    var pos: usize = 0;

    const prefix = "cmd.exe /c yt-dlp --flat-playlist --print \"%(id)s\\t%(title)s\\t%(upload_date)s\\t%(duration)s\" \"";
    pos = appendStr(&cmd, pos, prefix);
    pos = appendSlice(&cmd, pos, playlist_url);
    pos = appendStr(&cmd, pos, "\" > .yt_playlist_tmp.txt");
    cmd[pos] = 0;

    if (!runProcess(@ptrCast(cmd[0..pos :0]))) return 0;

    const data_len = readTempFile();
    if (data_len == 0) return 0;
    _ = DeleteFileA(@ptrCast(TEMP_PATH));

    return parseTsv(scan_buf[0..data_len], results);
}

/// List all playlists from a channel.
/// Uses: yt-dlp --flat-playlist --print "%(id)s\t%(title)s\t%(playlist_count)s" <channel>/playlists
pub fn listChannelPlaylists(channel_url: []const u8, playlists: []PlaylistInfo) usize {
    var url_buf: [512]u8 = undefined;
    const url_len = buildPlaylistsUrl(channel_url, &url_buf);

    var cmd: [1024]u8 = undefined;
    var pos: usize = 0;

    const prefix = "cmd.exe /c yt-dlp --flat-playlist --print \"%(id)s\\t%(title)s\\t%(playlist_count)s\" \"";
    pos = appendStr(&cmd, pos, prefix);
    pos = appendSlice(&cmd, pos, url_buf[0..url_len]);
    pos = appendStr(&cmd, pos, "\" > .yt_playlist_tmp.txt");
    cmd[pos] = 0;

    if (!runProcess(@ptrCast(cmd[0..pos :0]))) return 0;

    const data_len = readTempFile();
    if (data_len == 0) return 0;
    _ = DeleteFileA(@ptrCast(TEMP_PATH));

    return parsePlaylists(scan_buf[0..data_len], playlists);
}

/// Get the position/index of a video within a playlist.
/// Returns 0 if not found, 1-indexed position otherwise.
pub fn videoPosition(playlist_url: []const u8, video_id: *const [meta.VIDEO_ID_LEN]u8) u16 {
    var results: [2048]meta.VideoMeta = undefined;
    const n = listVideos(playlist_url, &results);
    for (0..n) |i| {
        if (eqlSlice(&results[i].id, video_id)) return @intCast(i + 1);
    }
    return 0;
}

// ── Parsing ──

fn parseTsv(data: []const u8, results: []meta.VideoMeta) usize {
    var count: usize = 0;
    var line_start: usize = 0;
    for (0..data.len) |i| {
        if (data[i] == '\n' or i == data.len - 1) {
            const le = if (data[i] == '\n') i else i + 1;
            if (le > line_start and count < results.len) {
                if (parseVideoLine(data[line_start..le], &results[count])) count += 1;
            }
            line_start = i + 1;
        }
    }
    return count;
}

fn parseVideoLine(line: []const u8, v: *meta.VideoMeta) bool {
    if (line.len < meta.VIDEO_ID_LEN + 2) return false;
    v.* = meta.VideoMeta.init();
    // Split on tabs
    var tab1: usize = 0;
    while (tab1 < line.len and line[tab1] != '\t') : (tab1 += 1) {}
    if (tab1 < meta.VIDEO_ID_LEN) return false;
    @memcpy(&v.id, line[0..meta.VIDEO_ID_LEN]);

    if (tab1 + 1 >= line.len) { v.valid = true; return true; }
    var tab2 = tab1 + 1;
    while (tab2 < line.len and line[tab2] != '\t') : (tab2 += 1) {}
    const tlen = @min(tab2 - tab1 - 1, meta.MAX_TITLE_LEN);
    @memcpy(v.title[0..tlen], line[tab1 + 1 .. tab1 + 1 + tlen]);
    v.title_len = @intCast(tlen);

    if (tab2 + 1 < line.len) {
        var tab3 = tab2 + 1;
        while (tab3 < line.len and line[tab3] != '\t') : (tab3 += 1) {}
        const date_f = line[tab2 + 1 .. tab3];
        if (date_f.len >= 8) @memcpy(&v.upload_date, date_f[0..8]);
        if (tab3 + 1 < line.len) v.duration = parseUint(line[tab3 + 1 ..]);
    }
    v.valid = true;
    return true;
}

fn parsePlaylists(data: []const u8, playlists: []PlaylistInfo) usize {
    var count: usize = 0;
    var line_start: usize = 0;
    for (0..data.len) |i| {
        if (data[i] == '\n' or i == data.len - 1) {
            const le = if (data[i] == '\n') i else i + 1;
            if (le > line_start and count < playlists.len) {
                if (parsePlaylistLine(data[line_start..le], &playlists[count])) count += 1;
            }
            line_start = i + 1;
        }
    }
    return count;
}

fn parsePlaylistLine(line: []const u8, pl: *PlaylistInfo) bool {
    if (line.len < 3) return false;
    pl.* = PlaylistInfo{ .id = undefined, .id_len = 0, .title = undefined, .title_len = 0, .video_count = 0 };
    var tab1: usize = 0;
    while (tab1 < line.len and line[tab1] != '\t') : (tab1 += 1) {}
    const id_len = @min(tab1, 34);
    @memcpy(pl.id[0..id_len], line[0..id_len]);
    pl.id_len = @intCast(id_len);

    if (tab1 + 1 >= line.len) return true;
    var tab2 = tab1 + 1;
    while (tab2 < line.len and line[tab2] != '\t') : (tab2 += 1) {}
    const tlen = @min(tab2 - tab1 - 1, 128);
    @memcpy(pl.title[0..tlen], line[tab1 + 1 .. tab1 + 1 + tlen]);
    pl.title_len = @intCast(tlen);

    if (tab2 + 1 < line.len) pl.video_count = @intCast(parseUint(line[tab2 + 1 ..]));
    return true;
}

// ── URL helpers ──

fn buildPlaylistsUrl(channel_url: []const u8, buf: *[512]u8) usize {
    const len = @min(channel_url.len, 480);
    @memcpy(buf[0..len], channel_url[0..len]);
    var pos = len;
    if (pos > 0 and buf[pos - 1] == '/') pos -= 1;
    // Replace /videos with /playlists or append
    if (endsWith(buf[0..pos], "/videos")) {
        pos -= 7; // remove "/videos"
    }
    const suffix = "/playlists";
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    return pos;
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    for (0..suffix.len) |i| if (haystack[haystack.len - suffix.len + i] != suffix[i]) return false;
    return true;
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

fn parseUint(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| { if (c >= '0' and c <= '9') v = v * 10 + @as(u32, c - '0'); }
    return v;
}

fn appendStr(buf: *[1024]u8, pos: usize, s: []const u8) usize {
    const len = @min(s.len, 1023 - pos);
    @memcpy(buf[pos .. pos + len], s[0..len]);
    return pos + len;
}

fn appendSlice(buf: *[1024]u8, pos: usize, s: []const u8) usize {
    return appendStr(buf, pos, s);
}

fn readTempFile() usize {
    const h = CreateFileA(@ptrCast(TEMP_PATH), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return 0;
    var total: usize = 0;
    while (total < SCAN_BUF_SIZE) {
        var n: u32 = 0;
        if (ReadFile(h, scan_buf[total..].ptr, @intCast(SCAN_BUF_SIZE - total), &n, null) == 0) break;
        if (n == 0) break;
        total += n;
    }
    _ = CloseHandle(h);
    return total;
}

fn runProcess(cmd_line: [*:0]u8) bool {
    var si = StartupInfo{};
    var pi = ProcessInfo{};
    if (CreateProcessA(null, cmd_line, null, null, 0, 0, null, null, &si, &pi) == 0) return false;
    _ = WaitForSingleObject(pi.process, INFINITE);
    var exit_code: u32 = 1;
    _ = GetExitCodeProcess(pi.process, &exit_code);
    _ = CloseHandle(pi.thread);
    _ = CloseHandle(pi.process);
    return exit_code == 0;
}
