// @zpm/youtube/captions — Subtitle/Caption Download
//
// Downloads auto-generated or manual subtitles from YouTube videos.
// Uses yt-dlp's subtitle extraction (no API key needed).
//
// Supported formats: vtt, srt, json3, srv1, srv2, srv3
// Languages: any ISO 639-1 code (he, en, ar, ru, etc.)
//
// Usage:
//   captions.download(&video_id, "he", .vtt, ".gotliv/subs.vtt");
//   captions.downloadAuto(&video_id, "he", .srt, ".gotliv/auto_subs.srt");
//   const langs = captions.listAvailable(&video_id);

const meta = @import("metadata.sig");

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

/// Subtitle format.
pub const SubFormat = enum {
    vtt, // WebVTT
    srt, // SubRip
    json3, // YouTube JSON3 (timestamps + words)
    srv1, // YouTube srv1
    srv2, // YouTube srv2
    srv3, // YouTube srv3
    ttml, // Timed Text Markup Language

    pub fn ext(self: SubFormat) []const u8 {
        return switch (self) {
            .vtt => "vtt",
            .srt => "srt",
            .json3 => "json3",
            .srv1 => "srv1",
            .srv2 => "srv2",
            .srv3 => "srv3",
            .ttml => "ttml",
        };
    }
};

/// Available caption track info.
pub const CaptionTrack = struct {
    lang_code: [8]u8, // ISO 639-1 (e.g., "he", "en")
    lang_len: u8,
    is_auto: bool, // auto-generated vs manual
    name: [64]u8, // display name
    name_len: u8,
};

pub const MAX_TRACKS: usize = 32;

/// Download manual (human-uploaded) subtitles.
/// Returns true if subtitles were found and downloaded.
pub fn download(
    video_id: *const [meta.VIDEO_ID_LEN]u8,
    lang: []const u8,
    format: SubFormat,
    output_path: []const u8,
) bool {
    // yt-dlp --write-sub --sub-lang he --sub-format vtt --skip-download -o "output" "URL"
    var cmd: [512]u8 = undefined;
    var pos: usize = 0;

    pos = appendStr(&cmd, pos, "yt-dlp --write-sub --sub-lang ");
    pos = appendSlice(&cmd, pos, lang);
    pos = appendStr(&cmd, pos, " --sub-format ");
    pos = appendSlice(&cmd, pos, format.ext());
    pos = appendStr(&cmd, pos, " --skip-download -o \"");
    pos = appendSlice(&cmd, pos, output_path);
    pos = appendStr(&cmd, pos, "\" \"https://www.youtube.com/watch?v=");
    @memcpy(cmd[pos .. pos + meta.VIDEO_ID_LEN], video_id);
    pos += meta.VIDEO_ID_LEN;
    pos = appendStr(&cmd, pos, "\"");
    cmd[pos] = 0;

    return runProcess(@ptrCast(cmd[0..pos :0]));
}

/// Download auto-generated subtitles.
pub fn downloadAuto(
    video_id: *const [meta.VIDEO_ID_LEN]u8,
    lang: []const u8,
    format: SubFormat,
    output_path: []const u8,
) bool {
    var cmd: [512]u8 = undefined;
    var pos: usize = 0;

    pos = appendStr(&cmd, pos, "yt-dlp --write-auto-sub --sub-lang ");
    pos = appendSlice(&cmd, pos, lang);
    pos = appendStr(&cmd, pos, " --sub-format ");
    pos = appendSlice(&cmd, pos, format.ext());
    pos = appendStr(&cmd, pos, " --skip-download -o \"");
    pos = appendSlice(&cmd, pos, output_path);
    pos = appendStr(&cmd, pos, "\" \"https://www.youtube.com/watch?v=");
    @memcpy(cmd[pos .. pos + meta.VIDEO_ID_LEN], video_id);
    pos += meta.VIDEO_ID_LEN;
    pos = appendStr(&cmd, pos, "\"");
    cmd[pos] = 0;

    return runProcess(@ptrCast(cmd[0..pos :0]));
}

/// Download all available subtitles (manual + auto) for a video.
pub fn downloadAll(
    video_id: *const [meta.VIDEO_ID_LEN]u8,
    format: SubFormat,
    output_dir: []const u8,
) bool {
    var cmd: [512]u8 = undefined;
    var pos: usize = 0;

    pos = appendStr(&cmd, pos, "yt-dlp --all-subs --sub-format ");
    pos = appendSlice(&cmd, pos, format.ext());
    pos = appendStr(&cmd, pos, " --skip-download -o \"");
    pos = appendSlice(&cmd, pos, output_dir);
    pos = appendStr(&cmd, pos, "/%(id)s.%(ext)s\" \"https://www.youtube.com/watch?v=");
    @memcpy(cmd[pos .. pos + meta.VIDEO_ID_LEN], video_id);
    pos += meta.VIDEO_ID_LEN;
    pos = appendStr(&cmd, pos, "\"");
    cmd[pos] = 0;

    return runProcess(@ptrCast(cmd[0..pos :0]));
}

/// List available caption languages for a video.
/// Uses yt-dlp --list-subs and parses the output.
/// Returns number of tracks found (written to `tracks`).
pub fn listAvailable(video_id: *const [meta.VIDEO_ID_LEN]u8, tracks: []CaptionTrack) usize {
    var cmd: [256]u8 = undefined;
    var pos: usize = 0;

    pos = appendStr(&cmd, pos, "cmd.exe /c yt-dlp --list-subs --skip-download \"https://www.youtube.com/watch?v=");
    @memcpy(cmd[pos .. pos + meta.VIDEO_ID_LEN], video_id);
    pos += meta.VIDEO_ID_LEN;
    pos = appendStr(&cmd, pos, "\" > .yt_subs_tmp.txt");
    cmd[pos] = 0;

    if (!runProcess(@ptrCast(cmd[0..pos :0]))) return 0;

    // Read and parse output
    const TEMP = ".yt_subs_tmp.txt\x00";
    const h = CreateFileA(@ptrCast(TEMP), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE or h == null) return 0;

    var buf: [8192]u8 = undefined;
    var n: u32 = 0;
    _ = ReadFile(h, &buf, 8192, &n, null);
    _ = CloseHandle(h);
    _ = DeleteFileA(@ptrCast(TEMP));

    return parseSubsList(buf[0..n], tracks);
}

fn parseSubsList(data: []const u8, tracks: []CaptionTrack) usize {
    // yt-dlp --list-subs output format:
    // Language  Name        Formats
    // he        Hebrew      vtt, srv1, srv2, srv3, json3
    // en        English     vtt, srv1, ...
    var count: usize = 0;
    var in_subs = false;
    var in_auto = false;
    var line_start: usize = 0;

    for (0..data.len) |i| {
        if (data[i] == '\n' or i == data.len - 1) {
            const line = data[line_start..i];

            // Detect section headers
            if (containsStr(line, "Available subtitles")) { in_subs = true; in_auto = false; }
            if (containsStr(line, "Available automatic captions")) { in_auto = true; in_subs = false; }

            // Parse language lines (start with 2-3 letter code)
            if ((in_subs or in_auto) and line.len > 4 and count < tracks.len) {
                if (isAlpha(line[0]) and isAlpha(line[1]) and (line[2] == ' ' or (isAlpha(line[2]) and line[3] == ' '))) {
                    var track = CaptionTrack{
                        .lang_code = undefined,
                        .lang_len = 0,
                        .is_auto = in_auto,
                        .name = undefined,
                        .name_len = 0,
                    };
                    // Extract lang code
                    var lc: usize = 0;
                    while (lc < line.len and lc < 8 and line[lc] != ' ') : (lc += 1) {
                        track.lang_code[lc] = line[lc];
                    }
                    track.lang_len = @intCast(lc);

                    // Extract name (between first and second multi-space gap)
                    var ns = lc;
                    while (ns < line.len and line[ns] == ' ') : (ns += 1) {}
                    var ne = ns;
                    while (ne < line.len and !(ne + 1 < line.len and line[ne] == ' ' and line[ne + 1] == ' ')) : (ne += 1) {}
                    const nlen = @min(ne - ns, 64);
                    if (nlen > 0) @memcpy(track.name[0..nlen], line[ns .. ns + nlen]);
                    track.name_len = @intCast(nlen);

                    tracks[count] = track;
                    count += 1;
                }
            }
            line_start = i + 1;
        }
    }
    return count;
}

// ── Helpers ──

fn appendStr(buf: *[512]u8, pos: usize, s: []const u8) usize {
    const len = @min(s.len, 511 - pos);
    @memcpy(buf[pos .. pos + len], s[0..len]);
    return pos + len;
}

fn appendSlice(buf: *[512]u8, pos: usize, s: []const u8) usize {
    return appendStr(buf, pos, s);
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
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
