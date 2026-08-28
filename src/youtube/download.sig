// @zpm/youtube/download — Pure Sig Audio/Video Download
//
// Complete download pipeline using native InnerTube + cipher + stream modules.
// No yt-dlp, no Python, no external subprocess.
//
// Pipeline for audio download:
//   1. Call InnerTube /player to get streaming data
//   2. Parse adaptive formats, select best audio stream
//   3. If cipher-protected: load player.js, extract cipher, decrypt signature
//   4. Apply nsig transform to avoid throttling
//   5. Download stream via HTTPS chunked transfer
//   6. Write to output file (WebM/Opus or M4A/AAC — both whisper-compatible)
//
// Usage:
//   const ok = download.audio(&video_id, "output.webm", .opus);
//   const ok = download.audioByUrl("https://youtube.com/watch?v=...", "output.m4a", .aac);

const meta = @import("metadata.sig");
const innertube = @import("innertube.sig");
const cipher_mod = @import("cipher.sig");
const manifest_mod = @import("manifest.sig");
const stream_mod = @import("stream.sig");
const mux_mod = @import("mux.sig");
const url_mod = @import("url.sig");

// ── Win32 (for null-terminated path conversion) ──
extern "kernel32" fn GetStdHandle(u32) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

fn print(msg: []const u8) void {
    _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), msg.ptr, @intCast(msg.len), null, null);
}

fn printNum(val: u64) void {
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    if (v == 0) { print("0"); return; }
    while (v > 0) : (len += 1) { buf[len] = @intCast((v % 10) + '0'); v /= 10; }
    var rev: [20]u8 = undefined;
    for (0..len) |i| rev[i] = buf[len - 1 - i];
    print(rev[0..len]);
}

/// Audio codec preference for download.
pub const AudioCodec = manifest_mod.AudioCodec;

/// Download result with status info.
pub const DownloadStatus = struct {
    success: bool,
    bytes_downloaded: u64,
    container: mux_mod.ContainerType,
    codec: mux_mod.AudioCodecId,
    bitrate: u32,
    duration_sec: u32,
};

/// Download audio for a video by ID.
/// `video_id`: 11-char YouTube video ID
/// `output_path`: null-terminated file path
/// `codec_pref`: preferred audio codec (.opus = best quality, .aac = most compatible)
pub fn audio(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, codec_pref: AudioCodec) DownloadStatus {
    var status = DownloadStatus{
        .success = false,
        .bytes_downloaded = 0,
        .container = .unknown,
        .codec = .unknown,
        .bitrate = 0,
        .duration_sec = 0,
    };

    print("  [download] Fetching player data...\n");

    // Step 1: Get player response
    // Try clients that DON'T require PO tokens first:
    //   1. web_embedded — works for embeddable videos (most public videos)
    //   2. android_vr — works except for "made for kids" videos
    //   3. IOS — requires PO token but sometimes works
    //   4. WEB — requires PO token, last resort
    var resp = innertube.playerWebEmbed(video_id);
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] web_embedded: no streams, trying android_vr...\n");
        resp = innertube.playerAndroidVr(video_id);
    }
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] android_vr: no streams, trying ios...\n");
        resp = innertube.playerIos(video_id);
    }
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] ios: no streams, trying web...\n");
        resp = innertube.player(video_id);
    }
    var need_cipher = false;
    if (resp.len == 0) {
        print("  [download] ERROR: No player response from any client\n");
        return status;
    }

    // Step 2: Check if we need cipher decryption
    if (findStr(resp, "\"signatureCipher\"") != null) {
        need_cipher = true;
        print("  [download] Cipher-protected, loading player.js...\n");

        // Fetch watch page to get player.js URL
        const watch_page = innertube.fetchWatchPage(video_id);
        if (watch_page.len > 0) {
            const player_url = cipher_mod.extractPlayerUrl(watch_page);
            if (player_url.len > 0) {
                if (!cipher_mod.loadCipher(player_url)) {
                    print("  [download] WARN: Cipher extraction failed\n");
                }
            }
        }
    }

    // Step 3: Parse available formats
    print("  [download] Parsing formats...\n");
    var formats: [manifest_mod.MAX_FORMATS]manifest_mod.StreamFormat = undefined;
    const n_formats = manifest_mod.parseFormats(resp, &formats);

    if (n_formats == 0) {
        print("  [download] ERROR: No formats found\n");
        return status;
    }

    // Step 4: Select best audio stream
    const best = manifest_mod.selectBestAudio(&formats, n_formats, codec_pref);
    if (best == null) {
        print("  [download] ERROR: No audio stream found\n");
        return status;
    }
    const fmt = best.?;

    print("  [download] Selected: itag=");
    printNum(fmt.itag);
    print(", bitrate=");
    printNum(fmt.bitrate);
    print(", size=");
    printNum(fmt.content_length);
    print(" bytes\n");

    status.bitrate = fmt.bitrate;

    // Step 5: Download the stream
    if (fmt.url_len == 0) {
        print("  [download] ERROR: No stream URL (cipher failed?)\n");
        return status;
    }

    print("  [download] Downloading...\n");
    const dl_result = stream_mod.downloadToFile(
        fmt.url[0..fmt.url_len],
        output_path,
        fmt.content_length,
        null, // no progress callback
    );

    status.bytes_downloaded = dl_result.bytes_written;
    status.success = dl_result.success;

    if (status.success) {
        // Detect container type
        const mime = fmt.mime_type[0..fmt.mime_len];
        if (findStr(mime, "webm") != null) {
            status.container = .webm;
            status.codec = .opus;
        } else if (findStr(mime, "mp4") != null) {
            status.container = .mp4;
            status.codec = .aac;
        }

        print("  [download] Complete: ");
        printNum(status.bytes_downloaded / 1024);
        print(" KB\n");
    } else {
        print("  [download] FAILED after ");
        printNum(dl_result.retries);
        print(" retries\n");
    }

    // Extract duration from player response
    if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| {
        status.duration_sec = parseUint(dur_str);
    }

    return status;
}

/// Download audio by URL (any YouTube URL format).
pub fn audioByUrl(video_url: []const u8, output_path: [*:0]const u8, codec_pref: AudioCodec) DownloadStatus {
    var video_id: [meta.VIDEO_ID_LEN]u8 = undefined;
    if (!url_mod.extractVideoId(video_url, &video_id)) {
        return DownloadStatus{
            .success = false,
            .bytes_downloaded = 0,
            .container = .unknown,
            .codec = .unknown,
            .bitrate = 0,
            .duration_sec = 0,
        };
    }
    return audio(&video_id, output_path, codec_pref);
}

/// Download video (best quality audio + video muxed) — for future use.
/// Currently downloads best audio only (video muxing requires container writing).
pub fn video(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8) DownloadStatus {
    return audio(video_id, output_path, .any);
}

// ── Helpers ──

fn extractJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const kpos = findStr(data, key) orelse return null;
    var i = kpos + key.len;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return null;
    i += 1;
    const start = i;
    while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
    if (i > start) return data[start..i];
    return null;
}

fn parseUint(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| { if (c >= '0' and c <= '9') v = v * 10 + @as(u32, c - '0'); }
    return v;
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
