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
const minter = @import("botguard/minter.sig");
const session_mod = @import("session.sig");
const challenge_mod = @import("botguard/challenge.sig");
const http = @import("net.sig");
const sabr_mod = @import("sabr/root.sig");

// Cold-start PO token for the current download (base64url). Minted from the
// video id as content binding; YouTube accepts it while StreamProtectionStatus
// is 2 (enough to fetch streams). Regenerated per audio() call.
var g_pot_buf: [256]u8 = undefined;
var g_pot_len: usize = 0;
var g_stream_pot_buf: [256]u8 = undefined;
var g_stream_pot_len: usize = 0;
var g_session: session_mod.Session = session_mod.Session.init();
var g_challenge: challenge_mod.Challenge = challenge_mod.Challenge.init();
var g_player_copy: [innertube.RESPONSE_BUF_SIZE]u8 = undefined;

pub const TokenSource = enum { none, cold_start, vm };
var g_token_source: TokenSource = .none;
const MediaKind = enum { audio, video };
pub const DownloadOptions = struct {
    require_vm_token: bool = false,
    progress: stream_mod.ProgressFn = null,
    // When non-empty, use this base64url content-bound PO token instead of
    // minting one (lets a caller relay a token when a headless mint is gated).
    pot_override: []const u8 = "",
};

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
    contains_video: bool = false,
    contains_audio: bool = false,
    token_source: TokenSource = .none,
};
pub const VideoDownloadStatus = struct {
    video: DownloadStatus,
    audio: DownloadStatus,
    success: bool,
};

/// Download audio for a video by ID.
/// `video_id`: 11-char YouTube video ID
/// `output_path`: null-terminated file path
/// `codec_pref`: preferred audio codec (.opus = best quality, .aac = most compatible)
pub fn audio(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, codec_pref: AudioCodec) DownloadStatus {
    return downloadMedia(video_id, output_path, codec_pref, .audio, .{}, null, null);
}

pub fn audioWithOptions(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, codec_pref: AudioCodec, options: DownloadOptions) DownloadStatus {
    return downloadMedia(video_id, output_path, codec_pref, .audio, options, null, null);
}

fn downloadMedia(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, codec_pref: AudioCodec, kind: MediaKind, options: DownloadOptions, audio_path: ?[*:0]const u8, audio_status_out: ?*DownloadStatus) DownloadStatus {
    var status = DownloadStatus{
        .success = false,
        .bytes_downloaded = 0,
        .container = .unknown,
        .codec = .unknown,
        .bitrate = 0,
        .duration_sec = 0,
    };

    print("  [download] Fetching player data...\n");

    prepareTokens(video_id, options);
    status.token_source = g_token_source;
    if (options.require_vm_token and g_token_source != .vm) {
        print("  [download] ERROR: VM token required and minting did not succeed\n");
        return status;
    }

    // Both authenticated client routes carry this session's visitor and token.
    var resp = playerInSession(video_id, false);
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] session WEB: no streams, trying session IOS...\n");
        resp = playerInSession(video_id, true);
    }
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] session WEB: no streams, trying web_embedded...\n");
        resp = innertube.playerWebEmbed(video_id);
    }
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] web_embedded: no streams, trying android_vr...\n");
        resp = innertube.playerAndroidVr(video_id);
    }
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] android_vr: no streams. status=");
        if (extractJsonString(resp, "\"status\"")) |st| { print(st); } else { print("?"); }
        print(" reason=");
        if (extractJsonString(resp, "\"reason\"")) |rs| { print(rs); } else { print("?"); }
        print(" resp_len=");
        printNum(@intCast(resp.len));
        print(", trying ios...\n");
        resp = innertube.playerIos(video_id);
    }
    if ((resp.len == 0 or findStr(resp, "streamingData") == null) and g_pot_len > 0) {
        print("  [download] trying WEB with PO token...\n");
        resp = innertube.playerWithPot(video_id, .web, g_pot_buf[0..g_pot_len]);
    }
    if ((resp.len == 0 or findStr(resp, "streamingData") == null) and g_pot_len > 0) {
        print("  [download] trying TVHTML5_EMBED with PO token...\n");
        resp = innertube.playerWithPot(video_id, .tv_embedded, g_pot_buf[0..g_pot_len]);
    }
    if (resp.len == 0 or findStr(resp, "streamingData") == null) {
        print("  [download] web+pot: no streams, trying web (no pot)...\n");
        resp = innertube.player(video_id);
    }
    if (resp.len == 0) {
        print("  [download] ERROR: No player response from any client\n");
        return status;
    }
    // Debug: if still no streamingData, dump the playability status / response head
    // so we can see WHY YouTube refused (PO required, login, unplayable, etc.).
    if (findStr(resp, "streamingData") == null) {
        print("  [download] no streamingData. response head:\n    ");
        const hlen = @min(resp.len, 400);
        _ = WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), resp.ptr, @intCast(hlen), null, null);
        print("\n");
        if (extractJsonString(resp, "\"status\"")) |st| { print("  [download] playabilityStatus="); print(st); print("\n"); }
        if (extractJsonString(resp, "\"reason\"")) |rs| { print("  [download] reason="); print(rs); print("\n"); }
    }

    // Step 2: Check if we need cipher decryption
    if (findStr(resp, "\"signatureCipher\"") != null or findStr(resp, "&n=") != null or findStr(resp, "\\u0026n=") != null) {
        // The watch-page helper shares InnerTube's response buffer. Preserve
        // the chosen player response before using it for another request.
        if (resp.len > g_player_copy.len) return status;
        @memcpy(g_player_copy[0..resp.len], resp);
        resp = g_player_copy[0..resp.len];
        print("  [download] Loading player.js for signature/n transforms...\n");

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
    const best = if (kind == .video)
        manifest_mod.selectBestMuxed(&formats, n_formats) orelse manifest_mod.selectBestVideo(&formats, n_formats)
    else
        manifest_mod.selectBestAudio(&formats, n_formats, codec_pref) orelse manifest_mod.selectBestMuxed(&formats, n_formats);
    if (best == null) {
        print(if (kind == .video) "  [download] ERROR: No video stream found\n" else "  [download] ERROR: No audio stream found\n");
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
    status.contains_video = fmt.is_video;
    status.contains_audio = fmt.is_audio;

    // SABR branch: when the player response exposes serverAbrStreamingUrl (and
    // the selected format lacks a direct URL), YouTube serves this media only
    // via SABR POST delivery. Pull it through the pure-Sig SABR loop using the
    // content-bound PO token + the session jar. The direct-URL path below stays
    // the fallback whenever a direct URL IS present.
    if (fmt.url_len == 0 and sabr_mod.player_fields.serverAbrStreamingUrl(resp) != null) {
        if (trySabr(resp, fmt, kind, output_path, options, &status)) return status;
    }

    // Step 5: Download the stream
    if (fmt.url_len == 0) {
        print("  [download] ERROR: No stream URL (cipher failed?)\n");
        return status;
    }

    // Append the PO token to the stream URL (&pot=...) — required by GVS for the
    // stream to serve full data (2026). Build the final URL in a local buffer.
    var url_buf: [9216]u8 = undefined;
    var url_final: []const u8 = fmt.url[0..fmt.url_len];
    print("  [download] stream URL length=");
    printNum(@intCast(fmt.url_len));
    print("\n");
    if (g_stream_pot_len > 0 and fmt.url_len + g_stream_pot_len + 8 < url_buf.len and findStr(fmt.url[0..fmt.url_len], "pot=") == null) {
        var up: usize = 0;
        @memcpy(url_buf[up .. up + fmt.url_len], fmt.url[0..fmt.url_len]);
        up += fmt.url_len;
        const amp = "&pot=";
        @memcpy(url_buf[up .. up + amp.len], amp);
        up += amp.len;
        @memcpy(url_buf[up .. up + g_stream_pot_len], g_stream_pot_buf[0..g_stream_pot_len]);
        up += g_stream_pot_len;
        url_final = url_buf[0..up];
        print("  [download] stream URL + &pot= appended\n");
    }

    print("  [download] Downloading...\n");
    const dl_result = stream_mod.downloadToFile(
        url_final,
        output_path,
        fmt.content_length,
        options.progress,
    );

    status.bytes_downloaded = dl_result.bytes_written;
    status.success = dl_result.success;

    if (status.success) {
        setContainer(fmt, &status);

        print("  [download] Complete: ");
        printNum(status.bytes_downloaded / 1024);
        print(" KB\n");
    } else {
        print("  [download] FAILED after ");
        printNum(dl_result.retries);
        print(" retries (last HTTP status=");
        printNum(stream_mod.last_status);
        print(")\n");

        // PO-exempt fallback: as of 2026, adaptive audio streams (opus/m4a)
        // require a GVS PO token and 403 without one. The muxed itag 18 (360p
        // MP4, video+audio) is still served WITHOUT a PO token. Its AAC audio
        // track is fine for whisper transcription, so fall back to it.
        if (manifest_mod.selectByItag(&formats, n_formats, 18)) |mux| {
            print("  [download] Falling back to muxed itag=18 (PO-exempt)...\n");
            print("  [download] itag=18 URL length=");
            printNum(@intCast(mux.url_len));
            print(", size=");
            printNum(mux.content_length);
            print("\n");
            var m_buf: [9216]u8 = undefined;
            var m_url: []const u8 = mux.url[0..mux.url_len];
            if (g_stream_pot_len > 0 and mux.url_len + g_stream_pot_len + 8 < m_buf.len and findStr(mux.url[0..mux.url_len], "pot=") == null) {
                var mp: usize = 0;
                @memcpy(m_buf[mp .. mp + mux.url_len], mux.url[0..mux.url_len]);
                mp += mux.url_len;
                const amp = "&pot=";
                @memcpy(m_buf[mp .. mp + amp.len], amp);
                mp += amp.len;
                @memcpy(m_buf[mp .. mp + g_stream_pot_len], g_stream_pot_buf[0..g_stream_pot_len]);
                mp += g_stream_pot_len;
                m_url = m_buf[0..mp];
            }
            const mux_result = stream_mod.downloadToFile(m_url, output_path, mux.content_length, options.progress);
            status.bytes_downloaded = mux_result.bytes_written;
            status.success = mux_result.success;
            if (status.success) {
                status.container = .mp4;
                status.codec = .aac;
                status.bitrate = mux.bitrate;
                status.contains_video = mux.is_video;
                status.contains_audio = mux.is_audio;
                print("  [download] Complete (itag 18 muxed): ");
                printNum(status.bytes_downloaded / 1024);
                print(" KB\n");
            } else {
                print("  [download] itag 18 fallback also FAILED (HTTP status=");
                printNum(stream_mod.last_status);
                print(")\n");
            }
        }
    }

    // Extract duration from player response
    if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| {
        status.duration_sec = parseUint(dur_str);
    }

    if (status.success and kind == .video and !status.contains_audio and audio_path != null and audio_status_out != null) {
        if (manifest_mod.selectBestAudio(&formats, n_formats, .aac) orelse manifest_mod.selectBestAudio(&formats, n_formats, .any)) |audio_fmt| {
            print("  [download] Downloading matching adaptive audio from the same player/session...\n");
            var a_url: [9216]u8 = undefined;
            const a_len = appendStreamToken(audio_fmt.url[0..audio_fmt.url_len], &a_url);
            const a_result = stream_mod.downloadToFile(a_url[0..a_len], audio_path.?, audio_fmt.content_length, options.progress);
            var a_status = DownloadStatus{
                .success = a_result.success,
                .bytes_downloaded = a_result.bytes_written,
                .container = .unknown,
                .codec = .unknown,
                .bitrate = audio_fmt.bitrate,
                .duration_sec = status.duration_sec,
                .contains_audio = true,
                .token_source = g_token_source,
            };
            setContainer(audio_fmt, &a_status);
            audio_status_out.?.* = a_status;
        }
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

/// Download the best video stream, preferring complete audio+video when present.
/// Check contains_audio to distinguish a separate adaptive video track.
pub fn video(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8) DownloadStatus {
    return downloadMedia(video_id, output_path, .any, .video, .{}, null, null);
}

pub fn videoWithOptions(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, options: DownloadOptions) DownloadStatus {
    return downloadMedia(video_id, output_path, .any, .video, options, null, null);
}

/// Download both adaptive tracks using one player response, visitor session,
/// and pair of PO tokens. A muxed format needs only the primary output file.
pub fn videoWithAudio(video_id: *const [meta.VIDEO_ID_LEN]u8, video_path: [*:0]const u8, audio_path: [*:0]const u8, options: DownloadOptions) VideoDownloadStatus {
    var audio_status = DownloadStatus{ .success = false, .bytes_downloaded = 0, .container = .unknown, .codec = .unknown, .bitrate = 0, .duration_sec = 0 };
    const video_status = downloadMedia(video_id, video_path, .any, .video, options, audio_path, &audio_status);
    return .{ .video = video_status, .audio = audio_status, .success = video_status.success and (video_status.contains_audio or audio_status.success) };
}

fn appendStreamToken(url: []const u8, out: []u8) usize {
    if (url.len > out.len) return 0;
    @memcpy(out[0..url.len], url);
    if (g_stream_pot_len == 0 or findStr(url, "pot=") != null) return url.len;
    if (url.len + g_stream_pot_len + 5 > out.len) return 0;
    var n = appendS(out, url.len, "&pot=");
    n = appendS(out, n, g_stream_pot_buf[0..g_stream_pot_len]);
    return n;
}

fn setContainer(fmt: *const manifest_mod.StreamFormat, status: *DownloadStatus) void {
    const mime = fmt.mime_type[0..fmt.mime_len];
    if (findStr(mime, "webm") != null) status.container = .webm;
    if (findStr(mime, "mp4") != null) status.container = .mp4;
    if (findStr(mime, "opus") != null) status.codec = .opus;
    if (findStr(mime, "mp4a") != null) status.codec = .aac;
}

fn prepareTokens(video_id: *const [meta.VIDEO_ID_LEN]u8, options: DownloadOptions) void {
    g_pot_len = 0;
    g_stream_pot_len = 0;
    g_token_source = .none;
    g_session = session_mod.Session.init();
    g_challenge = challenge_mod.Challenge.init();

    // A relayed content-bound token short-circuits minting (the session is
    // still bootstrapped below for the SABR jar + visitorData).
    if (options.pot_override.len > 0 and options.pot_override.len <= g_pot_buf.len) {
        @memcpy(g_pot_buf[0..options.pot_override.len], options.pot_override);
        g_pot_len = options.pot_override.len;
        _ = session_mod.bootstrap(&g_session, &g_challenge);
        if (g_session.visitorData().len > 0) {
            g_stream_pot_len = minter.mintColdStart(g_session.visitorData(), &g_stream_pot_buf);
        } else {
            g_stream_pot_len = minter.mintColdStart(video_id, &g_stream_pot_buf);
        }
        g_token_source = .vm; // treated as an externally-provided real token
        print("  [download] using relayed content-bound PO token (pot_override)\n");
        return;
    }

    var integrity_result = session_mod.IntegrityResult{};
    if (session_mod.establishIntegrityToken(&g_session, &g_challenge, &integrity_result)) {
        const token = integrity_result.integrity_token[0..integrity_result.integrity_token_len];
        g_pot_len = minter.mintContentBound(token, video_id, &g_pot_buf);
        if (g_session.visitorData().len > 0)
            g_stream_pot_len = minter.mintSessionBound(token, g_session.visitorData(), &g_stream_pot_buf);
        if (g_pot_len > 0 and g_stream_pot_len > 0) {
            g_token_source = .vm;
            print("  [download] VM minted content and visitor PO tokens\n");
            return;
        }
    }
    g_pot_len = minter.mintColdStart(video_id, &g_pot_buf);
    const binding = if (g_session.visitorData().len > 0) g_session.visitorData() else video_id[0..];
    g_stream_pot_len = minter.mintColdStart(binding, &g_stream_pot_buf);
    if (g_pot_len > 0 and g_stream_pot_len > 0) g_token_source = .cold_start;
    print("  [download] VM integrity unavailable; trying cold-start tokens\n");
}

// ── SABR branch ──
//
// Decodes the SABR URL + ustreamer config + PO token from the player response
// and runs the pure-Sig SABR loop (sabr/stream.sig) to pull `fmt` to disk.
// Returns true if the loop produced a non-empty file (status is updated); false
// to let the caller fall through to the direct-URL path. Fail-closed: a wall or
// SABR error leaves status.success=false with the raw signals printed.
var g_sabr_url_buf: [9216]u8 = undefined;
var g_sabr_cfg_buf: [8192]u8 = undefined;
var g_sabr_pot_buf: [512]u8 = undefined;

fn trySabr(
    resp: []const u8,
    fmt: *const manifest_mod.StreamFormat,
    kind: MediaKind,
    output_path: [*:0]const u8,
    options: DownloadOptions,
    status: *DownloadStatus,
) bool {
    _ = options;
    print("  [download] SABR branch: serverAbrStreamingUrl present, no direct URL\n");

    // 1. serverAbrStreamingUrl (JSON-escaped) -> unescape to a real URL.
    const url_esc = sabr_mod.player_fields.serverAbrStreamingUrl(resp) orelse return false;
    const url_len = sabr_mod.player_fields.unescapeInto(url_esc, &g_sabr_url_buf);
    if (url_len == 0) return false;
    const sabr_url = g_sabr_url_buf[0..url_len];

    // 2. ustreamer config (base64 string) -> raw bytes for the request field.
    var cfg_bytes: []const u8 = "";
    if (sabr_mod.player_fields.ustreamerConfig(resp)) |cfg_b64| {
        const n = base64Decode(cfg_b64, &g_sabr_cfg_buf);
        cfg_bytes = g_sabr_cfg_buf[0..n];
    }

    // 3. content-bound PO token (g_pot_buf holds base64url text) -> raw bytes.
    var pot_bytes: []const u8 = "";
    if (g_pot_len > 0) {
        const n = base64Decode(g_pot_buf[0..g_pot_len], &g_sabr_pot_buf);
        pot_bytes = g_sabr_pot_buf[0..n];
    }

    // 4. split the SABR URL into host/port/path.
    var host: [256]u8 = undefined;
    var path: [9216]u8 = undefined;
    var hl: usize = 0;
    var pl: usize = 0;
    var port: u16 = 443;
    if (!sabr_mod.stream.parseUrl(sabr_url, &host, &hl, &path, &pl, &port)) return false;

    // 5. open the output sink + the live transport (session jar).
    var fsink = sabr_mod.stream.FileSink.open(output_path) orelse return false;
    defer fsink.close();
    var transport_ctx = sabr_mod.stream.NetTransport{ .jar = &g_session.jar };

    const client_version = if (g_session.clientVersion().len > 0) g_session.clientVersion() else "2.20250312.04.00";
    const selected = sabr_mod.request.SelectedFormat{
        .itag = @intCast(fmt.itag),
        .last_modified = fmt.last_modified,
        .xtags = fmt.xtags[0..fmt.xtags_len],
    };

    print("  [download] SABR loop starting itag=");
    printNum(fmt.itag);
    print(" lmt=");
    printNum(fmt.last_modified);
    print("\n");

    const res = sabr_mod.stream.runLoop(
        transport_ctx.transport(),
        host[0..hl],
        port,
        path[0..pl],
        selected,
        kind == .audio,
        cfg_bytes,
        pot_bytes,
        1, // WEB
        client_version,
        fsink.sink(),
    );

    status.bytes_downloaded = res.bytes_written;
    status.success = res.success and res.bytes_written > 0;

    if (status.success) {
        setContainer(fmt, status);
        print("  [download] SABR complete: ");
        printNum(res.bytes_written / 1024);
        print(" KB\n");
        return true;
    }

    // Fail-closed: report the precise server verdict rather than faking success.
    print("  [download] SABR did not complete. last_status=");
    printNum(res.last_status);
    print(" protection_status=");
    printNum(@as(u64, @intCast(if (res.protection_status < 0) 0 else res.protection_status)));
    if (res.sabr_error_seen) {
        print(" sabr_error_code=");
        printNum(@as(u64, @intCast(if (res.sabr_error_code < 0) 0 else res.sabr_error_code)));
    }
    print(" bytes=");
    printNum(res.bytes_written);
    print("\n");
    return res.bytes_written > 0; // partial bytes still count as "handled"
}

// Decode standard OR url-safe base64 (ignoring padding/whitespace) into `out`.
fn base64Decode(input: []const u8, out: []u8) usize {
    var acc: u32 = 0;
    var nbits: u5 = 0;
    var oi: usize = 0;
    for (input) |c| {
        const v: i16 = b64Val(c);
        if (v < 0) continue;
        acc = (acc << 6) | @as(u32, @intCast(v));
        if (nbits >= 2) {
            nbits -= 2;
            if (oi >= out.len) return oi;
            out[oi] = @intCast((acc >> nbits) & 0xFF);
            oi += 1;
        } else nbits += 6;
    }
    return oi;
}

fn b64Val(c: u8) i16 {
    if (c >= 'A' and c <= 'Z') return @as(i16, c - 'A');
    if (c >= 'a' and c <= 'z') return @as(i16, c - 'a') + 26;
    if (c >= '0' and c <= '9') return @as(i16, c - '0') + 52;
    if (c == '+' or c == '-') return 62;
    if (c == '/' or c == '_') return 63;
    return -1;
}

fn playerInSession(video_id: *const [meta.VIDEO_ID_LEN]u8, ios: bool) []const u8 {
    if (!g_session.bootstrapped) return "";
    var body: [4096]u8 = undefined;
    var p: usize = 0;
    const version = if (ios) "20.10.4" else if (g_session.clientVersion().len > 0) g_session.clientVersion() else "2.20250312.04.00";
    p = appendS(&body, p, "{\"context\":{\"client\":{\"clientName\":\"");
    p = appendS(&body, p, if (ios) "IOS" else "WEB");
    p = appendS(&body, p, "\",\"clientVersion\":\"");
    p = appendS(&body, p, version);
    p = appendS(&body, p, "\",\"hl\":\"en\",\"gl\":\"US\",\"visitorData\":\"");
    p = appendS(&body, p, g_session.visitorData());
    p = appendS(&body, p, "\"");
    if (ios) p = appendS(&body, p, ",\"deviceMake\":\"Apple\",\"deviceModel\":\"iPhone16,2\",\"osName\":\"iOS\",\"osVersion\":\"17.7.1\"");
    p = appendS(&body, p, "}},\"videoId\":\"");
    p = appendS(&body, p, video_id);
    p = appendS(&body, p, "\",\"contentCheckOk\":true,\"racyCheckOk\":true,\"serviceIntegrityDimensions\":{\"poToken\":\"");
    p = appendS(&body, p, g_pot_buf[0..g_pot_len]);
    p = appendS(&body, p, "\"}}");
    var headers: [4096]u8 = undefined;
    var h: usize = 0;
    h = appendS(&headers, h, "Content-Type: application/json\r\nOrigin: https://www.youtube.com\r\nReferer: https://www.youtube.com/watch?v=");
    h = appendS(&headers, h, video_id);
    h = appendS(&headers, h, "\r\nX-Youtube-Client-Name: ");
    h = appendS(&headers, h, if (ios) "5" else "1");
    h = appendS(&headers, h, "\r\nX-Youtube-Client-Version: ");
    h = appendS(&headers, h, version);
    h = appendS(&headers, h, "\r\nX-Goog-Visitor-Id: ");
    h = appendS(&headers, h, g_session.visitorData());
    h = appendS(&headers, h, "\r\n");
    const ios_ua = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 17_7_1 like Mac OS X;)";
    const response = http.request(.post, "www.youtube.com", 443, "/youtubei/v1/player?prettyPrint=false", headers[0..h], body[0..p], &g_session.jar, if (ios) ios_ua else http.CHROME_UA);
    return if (response.ok) response.body else "";
}

fn appendS(buf: []u8, pos: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - pos);
    @memcpy(buf[pos..pos + n], s[0..n]);
    return pos + n;
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
