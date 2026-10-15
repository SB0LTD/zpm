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
const nsig_mod = @import("nsig.sig");
const manifest_mod = @import("manifest.sig");
const stream_mod = @import("stream.sig");
const mux_mod = @import("mux.sig");
const url_mod = @import("url.sig");
const minter = @import("botguard/minter.sig");
const session_mod = @import("session.sig");
const challenge_mod = @import("botguard/challenge.sig");
const http = @import("net.sig");
const sabr_mod = @import("sabr/root.sig");
const profiling = @import("download_profile.sig");
pub const Profile = profiling.Profile;

// Video-bound web PO token for the current download (base64url). A cold-start
// token is allowed only when the caller does not require the VM proof; the SABR
// path uses the content-bound token.
var g_pot_buf: [256]u8 = undefined;
var g_pot_len: usize = 0;
var g_stream_pot_buf: [1536]u8 = undefined;
var g_stream_pot_len: usize = 0;
var g_session: session_mod.Session = session_mod.Session.init();
var g_challenge: challenge_mod.Challenge = challenge_mod.Challenge.init();
var g_player_copy: [innertube.RESPONSE_BUF_SIZE]u8 = undefined;
var g_web_client: session_mod.WebClient = .mweb;
// Optional synchronous diagnostic observer. Slices are borrowed for this call;
// the download API remains single-operation and callbacks must not reenter it.
pub var debug_sabr_capture: ?*const fn ([]const u8, []const u8, []const u8, []const u8, []const u8) void = null;
// When set, the audio path skips the iOS-first probe and resolves the stream
// through the WEB/MWEB client (signatureCipher + nsig via player.js) using the
// session's visitorData-bound GVS PO token. Used as a one-shot fallback after an
// iOS direct URL is rejected by GVS (HTTP 403) for a protected video.
var g_skip_ios: bool = false;

// iOS InnerTube User-Agent — must match the client that minted iOS stream URLs
// so googlevideo (GVS) accepts the CDN range requests.
const IOS_UA = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 17_7_1 like Mac OS X;)";

pub const TokenSource = enum { none, cold_start, vm, external };
var g_token_source: TokenSource = .none;
const MediaKind = enum { audio, video };
pub const DownloadOptions = struct {
    // Caller-owned; reset for each top-level operation. Null disables profiling.
    profile: ?*Profile = null,
    // Refresh a rejected native attestation once by default; 0 disables it.
    // At most 3 refreshes per track are permitted. External proofs are never refreshed.
    max_attestation_refreshes: u8 = 1,
    web_client: session_mod.WebClient = .mweb,
    require_vm_token: bool = false,
    progress: stream_mod.ProgressFn = null,
    sabr_response: ?*const fn (result: sabr_mod.stream.SabrResult) bool = null,
    // Externally-minted content-bound PO token (websafe-b64). When non-empty,
    // prepareTokens uses it directly and skips the live Create/VM/GenerateIT
    // establishment (relay a token minted via create-test --pinned <videoId>).
    // The SABR path also consumes it as the content-bound token.
    pot_override: []const u8 = "",
};

// ── Caller-controlled media request API ───────────────────────────────────
//
// Audio entry points delegate to `fetch`; video helpers additionally coordinate
// matching tracks from one session. For a specific representation, drive
// `fetch` directly: pick the track kind, codec, an exact itag, and
// the delivery mechanism. `probe` enumerates every available form first so a
// caller can choose deterministically.

/// Which track the caller wants out of the player response.
pub const Track = enum {
    audio, // adaptive audio-only (smallest; what ASR wants)
    video, // adaptive video-only (no audio track)
    muxed, // a single stream carrying BOTH audio and video (e.g. itag 18)
    best_video, // best video, muxed if available else adaptive video-only
};

/// How the bytes should be fetched from the CDN. `auto` tries the robust order
/// for the track (direct URL with PO token, then SABR, then a muxed fallback
/// for audio); the explicit values force a single mechanism (fail-closed).
pub const Delivery = enum { auto, direct, sabr };

/// A caller-controlled download request. Zero-value = "best adaptive audio,
/// auto delivery" (the common ASR case).
pub const MediaRequest = struct {
    track: Track = .audio,
    codec: AudioCodec = .any, // audio codec preference (ignored for video)
    itag: u16 = 0, // 0 = best match; non-zero = this exact format
    delivery: Delivery = .auto,
    allow_muxed_fallback: bool = true, // audio may fall back to a muxed stream
    options: DownloadOptions = .{},
};

/// A caller-facing view of one available format (from `probe`).
pub const FormatInfo = struct {
    itag: u16 = 0,
    is_audio: bool = false,
    is_video: bool = false,
    has_direct_url: bool = false, // a usable signed/transformed CDN URL exists
    bitrate: u32 = 0,
    content_length: u64 = 0,
    last_modified: u64 = 0,
    container: mux_mod.ContainerType = .unknown,
    codec: mux_mod.AudioCodecId = .unknown,
};

/// Result of probing a video: how many forms, and whether SABR delivery is
/// offered (so a caller knows adaptive formats can be pulled even when their
/// direct URL is gated).
pub const ProbeResult = struct {
    count: usize = 0,
    sabr_available: bool = false,
    duration_sec: u32 = 0,
    token_source: TokenSource = .none,
    ok: bool = false,
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
    selected_itag: u16 = 0,
    attestation_refreshes: u8 = 0,
    sabr_result: ?sabr_mod.stream.SabrResult = null,
    transform_failure: ?nsig_mod.Failure = null,
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
    return fetch(video_id, .{ .track = .audio, .codec = codec_pref }, output_path);
}

pub fn audioWithOptions(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, codec_pref: AudioCodec, options: DownloadOptions) DownloadStatus {
    return fetch(video_id, .{ .track = .audio, .codec = codec_pref, .options = options }, output_path);
}

/// Caller-controlled download. Resolves `req` against the video's player
/// response and delivers the selected format to `output_path`, trying the
/// delivery mechanisms per `req.delivery`. Audio wrappers delegate here;
/// videoWithAudio additionally coordinates a matching track when necessary.
pub fn fetch(video_id: *const [meta.VIDEO_ID_LEN]u8, req: MediaRequest, output_path: [*:0]const u8) DownloadStatus {
    if (req.options.profile) |p| { p.* = .{}; p.started_ns = profiling.clock(p); }
    const started = profiling.clock(req.options.profile);
    defer profiling.add(req.options.profile, "total_ns", started);
    return fetchAttempts(fetchImpl, video_id, req, output_path);
}

fn fetchAttempts(comptime perform: anytype, video_id: *const [meta.VIDEO_ID_LEN]u8, req: MediaRequest, output_path: [*:0]const u8) DownloadStatus {
    return fetchAttemptsFrom(perform, video_id, req, output_path, 0);
}

fn shouldRefresh(status: DownloadStatus, options: DownloadOptions, refreshes: u8) bool {
    if (status.success or refreshes >= @min(options.max_attestation_refreshes, 3) or
        status.token_source != .vm or options.pot_override.len > 0) return false;
    const sabr = status.sabr_result orelse return false;
    return sabr.failure == .protection;
}

fn announceRefresh(refreshes: u8) void {
    print("  [download] SABR rejected the proof; establishing a fresh native session (refresh ");
    printNum(refreshes); print(")\n");
}

fn fetchAttemptsFrom(comptime perform: anytype, video_id: *const [meta.VIDEO_ID_LEN]u8, req: MediaRequest, output_path: [*:0]const u8, initial_refreshes: u8) DownloadStatus {
    var refreshes = initial_refreshes;
    while (true) {
        var status = perform(video_id, req, output_path);
        status.attestation_refreshes = refreshes;
        if (!shouldRefresh(status, req.options, refreshes)) return status;
        refreshes += 1;
        announceRefresh(refreshes);
        // fetchImpl prepares a new session/challenge and reacquires formats.
        // The previous staged sink has closed; never append its preview to
        // a new representation or publish it as a complete destination.
    }
}

fn fetchImpl(video_id: *const [meta.VIDEO_ID_LEN]u8, req: MediaRequest, output_path: [*:0]const u8) DownloadStatus {
    var status = DownloadStatus{ .success = false, .bytes_downloaded = 0, .container = .unknown, .codec = .unknown, .bitrate = 0, .duration_sec = 0 };

    print("  [download] Fetching player data...\n");
    prepareTokens(video_id, req.options);
    status.token_source = g_token_source;
    if (req.options.require_vm_token and g_token_source != .vm) {
        print("  [download] ERROR: VM token required and minting did not succeed\n");
        return status;
    }

    const want_audio = req.track == .audio;
    const ctx = acquirePlayer(video_id, req.options, want_audio and req.delivery != .sabr and req.options.pot_override.len == 0);
    status.token_source = g_token_source;
    if (!ctx.ok) return status;
    const resp = ctx.resp;
    g_ctx_sabr_available = ctx.sabr_available;
    if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| status.duration_sec = parseUint(dur_str);

    var formats: [manifest_mod.MAX_FORMATS]manifest_mod.StreamFormat = undefined;
    const n = manifest_mod.parseFormats(resp, &formats);
    if (n == 0) { print("  [download] ERROR: No formats found\n"); return status; }

    // Build the ordered candidate list for this request.
    var cands: [4]*const manifest_mod.StreamFormat = undefined;
    var nc: usize = 0;
    if (req.itag != 0) {
        // Exact itag: honor both direct-capable and SABR-only selection.
        if (manifest_mod.selectByItag(&formats, n, req.itag) orelse manifest_mod.selectBySabr(&formats, n, req.itag)) |f| { cands[nc] = f; nc += 1; }
    } else switch (req.track) {
        .audio => {
            if (manifest_mod.selectBestAudio(&formats, n, req.codec)) |f| { cands[nc] = f; nc += 1; }
            if (ctx.sabr_available) { if (manifest_mod.selectBestSabrWithCodec(&formats, n, true, req.codec)) |f| { if (nc == 0 or f != cands[0]) { cands[nc] = f; nc += 1; } } }
            if (req.allow_muxed_fallback and req.delivery != .sabr and req.codec == .any) { if (manifest_mod.selectByItag(&formats, n, 18) orelse manifest_mod.selectBestMuxed(&formats, n)) |f| { cands[nc] = f; nc += 1; } }
        },
        .video => {
            if (manifest_mod.selectBestVideo(&formats, n)) |f| { cands[nc] = f; nc += 1; }
            if (ctx.sabr_available) { if (manifest_mod.selectBestSabr(&formats, n, false)) |f| { cands[nc] = f; nc += 1; } }
        },
        .muxed => {
            if (manifest_mod.selectByItag(&formats, n, 18) orelse manifest_mod.selectBestMuxed(&formats, n)) |f| { cands[nc] = f; nc += 1; }
        },
        .best_video => {
            if (manifest_mod.selectBestMuxed(&formats, n)) |f| { cands[nc] = f; nc += 1; }
            if (manifest_mod.selectBestVideo(&formats, n)) |f| { cands[nc] = f; nc += 1; }
            if (ctx.sabr_available) { if (manifest_mod.selectBestSabr(&formats, n, false)) |f| { cands[nc] = f; nc += 1; } }
        },
    }
    if (nc == 0) {
        print(if (want_audio) "  [download] ERROR: No audio stream found\n" else "  [download] ERROR: No stream found\n");
        return status;
    }

    const media_kind: MediaKind = if (want_audio) .audio else .video;
    for (cands[0..nc]) |f| {
        if (req.itag != 0) {
            const valid_track = switch (req.track) { .audio => f.is_audio and !f.is_video, .video => f.is_video and !f.is_audio, .muxed => f.is_video and f.is_audio, .best_video => f.is_video };
            if (!valid_track) return status;
            const mime = f.mime_type[0..f.mime_len];
            if (want_audio and req.codec == .aac and findStr(mime, "mp4a") == null and findStr(mime, "aac") == null) return status;
            if (want_audio and req.codec == .opus and findStr(mime, "opus") == null) return status;
        }
        print("  [download] Candidate itag=");
        printNum(f.itag);
        print(" direct=");
        print(if (f.url_len > 0) "yes" else "no");
        print(" size=");
        printNum(f.content_length);
        print("\n");
        if (deliverOne(resp, f, media_kind, output_path, req.delivery, req.options, &status)) {
            if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| status.duration_sec = parseUint(dur_str);
            print("  [download] Complete: ");
            printNum(status.bytes_downloaded / 1024);
            print(" KB (itag ");
            printNum(f.itag);
            print(")\n");
            return status;
        }
        if (status.sabr_result) |result| if (result.failure == .cancelled) return status;
    }

    // iOS one-shot fallback: a protected video's iOS URL serves only a ~1MB
    // preview then 403s. Retry audio once through the WEB/MWEB + nsig path.
    if (want_audio and ctx.used_ios and !g_skip_ios) {
        print("  [download] iOS stream rejected; retrying via WEB/MWEB + nsig path...\n");
        g_skip_ios = true;
        const retry = fetchImpl(video_id, req, output_path);
        g_skip_ios = false;
        if (retry.success) return retry;
    }

    print(if (want_audio) "  [download] ERROR: audio delivery failed on all candidates\n" else "  [download] ERROR: delivery failed on all candidates\n");
    return status;
}

/// Enumerate every available form for `video_id` into `out`, returning a
/// ProbeResult. Lets a caller see all forms (and whether SABR is offered)
/// before choosing a MediaRequest. Uses one player acquisition.
pub fn probe(video_id: *const [meta.VIDEO_ID_LEN]u8, options: DownloadOptions, out: []FormatInfo) ProbeResult {
    if (options.profile) |p| { p.* = .{}; p.started_ns = profiling.clock(p); }
    const started = profiling.clock(options.profile);
    defer profiling.add(options.profile, "total_ns", started);
    var pr = ProbeResult{};
    prepareTokens(video_id, options);
    pr.token_source = g_token_source;
    const ctx = acquirePlayer(video_id, options, true);
    pr.token_source = g_token_source;
    if (!ctx.ok) return pr;
    pr.sabr_available = ctx.sabr_available;
    pr.ok = true;
    if (extractJsonString(ctx.resp, "\"lengthSeconds\"")) |dur_str| pr.duration_sec = parseUint(dur_str);

    var formats: [manifest_mod.MAX_FORMATS]manifest_mod.StreamFormat = undefined;
    const n = manifest_mod.parseFormats(ctx.resp, &formats);
    var k: usize = 0;
    while (k < n and k < out.len) : (k += 1) {
        const f = &formats[k];
        var info = FormatInfo{
            .itag = f.itag,
            .is_audio = f.is_audio,
            .is_video = f.is_video,
            .has_direct_url = f.url_len > 0,
            .bitrate = f.bitrate,
            .content_length = f.content_length,
            .last_modified = f.last_modified,
        };
        var tmp = DownloadStatus{ .success = false, .bytes_downloaded = 0, .container = .unknown, .codec = .unknown, .bitrate = 0, .duration_sec = 0 };
        setContainer(f, &tmp);
        info.container = tmp.container;
        info.codec = tmp.codec;
        out[k] = info;
    }
    pr.count = k;
    return pr;
}

// Chosen player response + the context needed to deliver its formats. The
// `resp` slice lives in g_player_copy (stable across later innertube calls).
const PlayerCtx = struct {
    resp: []const u8 = "",
    used_ios: bool = false,
    sabr_available: bool = false,
    ok: bool = false,
};

/// Acquire a usable player response via the client sweep, load the signature/n
/// transforms when needed, and copy the response into g_player_copy so it stays
/// valid across subsequent innertube requests. Tokens must already be prepared
/// (prepareTokens). `want_audio` enables the iOS-first probe (direct audio URLs).
fn acquirePlayer(video_id: *const [meta.VIDEO_ID_LEN]u8, options: DownloadOptions, want_audio: bool) PlayerCtx {
    const started = profiling.clock(options.profile);
    defer profiling.add(options.profile, "player_ns", started);
    var ctx = PlayerCtx{};

    stream_mod.setUserAgent("");
    stream_mod.setWebHeaders(true);

    var resp: []const u8 = "";
    if (want_audio and !options.require_vm_token and !g_skip_ios) {
        const ios_resp = innertube.playerIos(video_id);
        if (hasDirectAudio(ios_resp)) {
            print("  [download] iOS client: direct audio URLs present, using iOS response\n");
            resp = ios_resp;
            ctx.used_ios = true;
            g_stream_pot_len = 0;
            g_token_source = .none;
            stream_mod.setUserAgent(IOS_UA);
            stream_mod.setWebHeaders(false);
        }
    }

    g_web_client = options.web_client;
    if (resp.len == 0) resp = session_mod.playerInSession(&g_session, video_id, g_web_client, g_pot_buf[0..g_pot_len]);
    if (!hasPlayerFormats(resp)) {
        print("  [download] session MWEB: no direct formats, trying session WEB...\n");
        g_web_client = .web;
        resp = session_mod.playerInSession(&g_session, video_id, .web, g_pot_buf[0..g_pot_len]);
    }
    if (!hasPlayerFormats(resp) and (options.require_vm_token or options.pot_override.len > 0)) {
        print("  [download] ERROR: Web VM token has no downloadable WEB/MWEB formats\n");
        return ctx;
    }
    if (!hasPlayerFormats(resp)) {
        g_stream_pot_len = 0;
        g_token_source = .none;
        print("  [download] session WEB: no direct formats, trying web_embedded...\n");
        resp = innertube.playerWebEmbed(video_id);
    }
    if (!hasPlayerFormats(resp)) {
        print("  [download] web_embedded: no streams, trying android_vr...\n");
        resp = innertube.playerAndroidVr(video_id);
    }
    if (!hasPlayerFormats(resp)) {
        print("  [download] android_vr: no streams. status=");
        if (extractJsonString(resp, "\"status\"")) |st| { print(st); } else { print("?"); }
        print(" reason=");
        if (extractJsonString(resp, "\"reason\"")) |rs| { print(rs); } else { print("?"); }
        print(", trying ios...\n");
        resp = innertube.playerIos(video_id);
    }
    if (resp.len == 0) {
        print("  [download] ERROR: No player response from any client\n");
        return ctx;
    }
    if (findStr(resp, "streamingData") == null) {
        if (extractJsonString(resp, "\"status\"")) |st| { print("  [download] playabilityStatus="); print(st); print("\n"); }
        if (extractJsonString(resp, "\"reason\"")) |rs| { print("  [download] reason="); print(rs); print("\n"); }
    }

    // Preserve the chosen response before any further innertube requests reuse
    // the shared response buffer (watch page / player.js fetch).
    if (resp.len > g_player_copy.len) return ctx;
    @memcpy(g_player_copy[0..resp.len], resp);
    resp = g_player_copy[0..resp.len];

    // Load signature/n transforms when the response needs them.
    if (findStr(resp, "\"signatureCipher\"") != null or findStr(resp, "&n=") != null or findStr(resp, "\\u0026n=") != null) {
        print("  [download] Loading player.js for signature/n transforms...\n");
        var player_url = g_session.playerUrl();
        if (player_url.len == 0) player_url = cipher_mod.extractPlayerUrl(innertube.fetchWatchPage(video_id));
        if (player_url.len > 0) {
            if (!cipher_mod.loadCipher(player_url)) print("  [download] WARN: Signature extraction unavailable; direct URLs may still use n transform\n");
        }
    }

    ctx.resp = resp;
    ctx.sabr_available = sabr_mod.player_fields.serverAbrStreamingUrl(resp) != null;
    ctx.ok = true;
    return ctx;
}

/// Deliver a single selected format to `path` per the delivery policy, updating
/// `status`. Returns true on a non-empty written file. `auto` tries the direct
/// signed/transformed URL (when present) and SABR (when offered) in a robust
/// order; `.direct`/`.sabr` force one mechanism (fail-closed).
fn deliverOne(resp: []const u8, fmt: *const manifest_mod.StreamFormat, kind: MediaKind, path: [*:0]const u8, delivery: Delivery, options: DownloadOptions, status: *DownloadStatus) bool {
    status.selected_itag = fmt.itag;
    status.sabr_result = null;
    status.bitrate = fmt.bitrate;
    status.contains_video = fmt.is_video;
    status.contains_audio = fmt.is_audio;

    const want_direct = (delivery == .auto or delivery == .direct) and fmt.url_len > 0;
    const want_sabr = (delivery == .auto or delivery == .sabr) and g_ctx_sabr_available;

    // SABR-first when the format has no direct URL, or when the caller forced
    // SABR. Otherwise try the direct URL first (it is cheaper when it works).
    if ((delivery == .sabr or fmt.url_len == 0) and want_sabr) {
        if (trySabr(resp, fmt, kind, path, options, status)) return true;
        if (status.sabr_result) |result| if (result.failure == .cancelled) return false;
        if (delivery == .sabr) return false;
    }

    if (want_direct) {
        var url_buf: [9216]u8 = undefined;
        const url_len = appendStreamToken(fmt.url[0..fmt.url_len], &url_buf);
        if (url_len != 0) {
            print("  [download] Downloading (direct) itag=");
            printNum(fmt.itag);
            print(" size=");
            printNum(fmt.content_length);
            print("\n");
            const direct_started = profiling.clock(options.profile);
            const dl = stream_mod.downloadToFile(url_buf[0..url_len], path, fmt.content_length, options.progress);
            profiling.add(options.profile, "transfer_ns", direct_started);
            status.bytes_downloaded = dl.bytes_written;
            status.success = dl.success;
            if (dl.success) { status.transform_failure = null; setContainer(fmt, status); return true; }
            print("  [download] direct FAILED (HTTP status=");
            printNum(stream_mod.last_status);
            print(")\n");
        }
    }

    // Direct URL failed or absent: try SABR if we have not already.
    if (delivery == .auto and want_sabr and fmt.url_len > 0) {
        if (trySabr(resp, fmt, kind, path, options, status)) return true;
    }

    return false;
}

// serverAbrStreamingUrl availability for the response currently being
// delivered — set by the resolver before calling deliverOne.
var g_ctx_sabr_available: bool = false;

fn downloadMedia(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, codec_pref: AudioCodec, kind: MediaKind, options: DownloadOptions, audio_path: ?[*:0]const u8, audio_status_out: ?*DownloadStatus) DownloadStatus {
    // Audio delegates entirely to the caller-controlled resolver.
    if (kind == .audio)
        return fetch(video_id, .{ .track = .audio, .codec = codec_pref, .options = options }, output_path);

    if (options.profile) |p| { p.* = .{}; p.started_ns = profiling.clock(p); }
    const operation_started = profiling.clock(options.profile);
    defer profiling.add(options.profile, "total_ns", operation_started);

    var refreshes: u8 = 0;
    while (true) {
        var status = downloadVideoOnce(video_id, output_path, options, audio_path, audio_status_out);
        status.attestation_refreshes = refreshes;
        if (!shouldRefresh(status, options, refreshes)) return status;
        refreshes += 1;
        announceRefresh(refreshes);
    }
}

fn downloadVideoOnce(video_id: *const [meta.VIDEO_ID_LEN]u8, output_path: [*:0]const u8, options: DownloadOptions, audio_path: ?[*:0]const u8, audio_status_out: ?*DownloadStatus) DownloadStatus {
    // Video path: acquire one player response, select the best video (muxed when
    // available), deliver it, and — for videoWithAudio — pull a matching adaptive
    // audio track from the same response/session when the video has no audio.
    var status = DownloadStatus{ .success = false, .bytes_downloaded = 0, .container = .unknown, .codec = .unknown, .bitrate = 0, .duration_sec = 0 };

    print("  [download] Fetching player data...\n");
    prepareTokens(video_id, options);
    status.token_source = g_token_source;
    if (options.require_vm_token and g_token_source != .vm) {
        print("  [download] ERROR: VM token required and minting did not succeed\n");
        return status;
    }

    const ctx = acquirePlayer(video_id, options, false);
    status.token_source = g_token_source;
    if (!ctx.ok) return status;
    const resp = ctx.resp;
    g_ctx_sabr_available = ctx.sabr_available;
    if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| status.duration_sec = parseUint(dur_str);

    var formats: [manifest_mod.MAX_FORMATS]manifest_mod.StreamFormat = undefined;
    const n_formats = manifest_mod.parseFormats(resp, &formats);
    if (n_formats == 0) { print("  [download] ERROR: No formats found\n"); return status; }

    // Candidate order: a complete muxed stream first (one file, has audio), then
    // adaptive video-only, then SABR.
    var cands: [3]*const manifest_mod.StreamFormat = undefined;
    var nc: usize = 0;
    if (manifest_mod.selectBestMuxed(&formats, n_formats)) |f| { cands[nc] = f; nc += 1; }
    if (manifest_mod.selectBestVideo(&formats, n_formats)) |f| { cands[nc] = f; nc += 1; }
    if (ctx.sabr_available) { if (manifest_mod.selectBestSabr(&formats, n_formats, false)) |f| { cands[nc] = f; nc += 1; } }
    if (nc == 0) { print("  [download] ERROR: No video stream found\n"); return status; }

    var delivered = false;
    for (cands[0..nc]) |f| {
        if (deliverOne(resp, f, .video, output_path, .auto, options, &status)) { delivered = true; break; }
        if (status.sabr_result) |sabr| if (sabr.failure == .cancelled) return status;
    }
    if (!delivered) { print("  [download] ERROR: video delivery failed on all candidates\n"); return status; }

    if (extractJsonString(resp, "\"lengthSeconds\"")) |dur_str| status.duration_sec = parseUint(dur_str);
    print("  [download] Complete: ");
    printNum(status.bytes_downloaded / 1024);
    print(" KB\n");

    // videoWithAudio: fetch a matching adaptive audio track when the delivered
    // video carries no audio.
    if (!status.contains_audio and audio_path != null and audio_status_out != null)
        downloadMatchingAudio(video_id, resp, &formats, n_formats, audio_path.?, options, status.duration_sec, audio_status_out.?);

    return status;
}

fn downloadMatchingAudio(video_id: *const [meta.VIDEO_ID_LEN]u8, resp: []const u8, formats: []const manifest_mod.StreamFormat, n_formats: usize, path: [*:0]const u8, options: DownloadOptions, duration_sec: u32, out: *DownloadStatus) void {
    const direct = manifest_mod.selectBestAudio(formats, n_formats, .aac) orelse manifest_mod.selectBestAudio(formats, n_formats, .any);
    const audio_fmt = direct orelse (if (sabr_mod.player_fields.serverAbrStreamingUrl(resp) != null) manifest_mod.selectBestSabr(formats, n_formats, true) else null) orelse return;
    print("  [download] Downloading matching adaptive audio from the same player/session...\n");
    out.* = .{ .success = false, .bytes_downloaded = 0, .container = .unknown, .codec = .unknown, .bitrate = audio_fmt.bitrate, .duration_sec = duration_sec, .contains_audio = true, .token_source = g_token_source };
    if (audio_fmt.url_len == 0) {
        _ = trySabr(resp, audio_fmt, .audio, path, options, out);
        if (shouldRefresh(out.*, options, 0)) {
            announceRefresh(1);
            // Preserve the completed video and the outer operation's profile.
            // Re-resolve only this audio representation in a fresh session.
            out.* = fetchAttemptsFrom(fetchImpl, video_id, .{
                .track = .audio, .itag = audio_fmt.itag, .delivery = .sabr,
                .allow_muxed_fallback = false, .options = options,
            }, path, 1);
        }
        return;
    }
    var a_url: [9216]u8 = undefined;
    const a_len = appendStreamToken(audio_fmt.url[0..audio_fmt.url_len], &a_url);
    if (a_len == 0) return;
    const audio_started = profiling.clock(options.profile);
    const result = stream_mod.downloadToFile(a_url[0..a_len], path, audio_fmt.content_length, options.progress);
    profiling.add(options.profile, "transfer_ns", audio_started);
    out.bytes_downloaded = result.bytes_written;
    out.success = result.success;
    if (out.success) setContainer(audio_fmt, out);
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
/// and video-bound PO token. A muxed format needs only the primary output file.
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
    const started = profiling.clock(options.profile);
    defer profiling.add(options.profile, "tokens_ns", started);
    g_pot_len = 0;
    g_stream_pot_len = 0;
    g_token_source = .none;
    g_session = session_mod.Session.init();
    g_challenge = challenge_mod.Challenge.init();

    // External proofs are diagnostic inputs, not evidence of native minting.
    if (options.pot_override.len > 0 and options.require_vm_token) {
        print("  [download] ERROR: External PO token cannot satisfy require_vm_token\n");
        return;
    }
    if (options.pot_override.len > 0 and options.pot_override.len <= g_pot_buf.len) {
        @memcpy(g_pot_buf[0..options.pot_override.len], options.pot_override);
        g_pot_len = options.pot_override.len;
        if (!session_mod.bootstrap(&g_session, &g_challenge)) return;
        _ = session_mod.prepareMobileClient(&g_session);
        @memcpy(g_stream_pot_buf[0..g_pot_len], g_pot_buf[0..g_pot_len]);
        g_stream_pot_len = g_pot_len;
        g_token_source = .external;
        print("  [download] using relayed content-bound PO token (pot_override)\n");
        return;
    }

    if (session_mod.bootstrap(&g_session, &g_challenge)) _ = session_mod.prepareMobileClient(&g_session);
    // Each retry obtains a fresh challenge through the same visitor/cookie jar.
    const MAX_VM_ATTEMPTS: u32 = 3;
    var attempt: u32 = 0;
    while (attempt < MAX_VM_ATTEMPTS) : (attempt += 1) {
        var integrity_result = session_mod.IntegrityResult{};
        if (attempt > 0) g_challenge = challenge_mod.Challenge.init();
        if (attempt > 0) { print("  [download] minter retry "); printNum(attempt); print("/"); printNum(MAX_VM_ATTEMPTS); print("\n"); }
        if (session_mod.establishIntegrityTokenProfiled(&g_session, &g_challenge, &integrity_result, options.profile) and integrity_result.minter_ready) {
            const token = integrity_result.integrity_token[0..integrity_result.integrity_token_len];
            // The /player request's serviceIntegrityDimensions.poToken is bound
            // to the video id (content binding).
            g_pot_len = minter.mintContentBound(token, video_id, &g_pot_buf);
            // The GVS/stream (&pot=) token for the WEB/MWEB CDN URLs must be
            // bound to the session's visitorData (yt-dlp: "GVS PO Token …
            // Missing required Visitor Data" for web/mweb). Mint a session-bound
            // GVS token when visitorData is present; otherwise reuse the
            // content-bound proof.
            const visitor = g_session.visitorData();
            if (visitor.len > 0) g_stream_pot_len = minter.mintSessionBound(token, visitor, &g_stream_pot_buf);
            if (g_pot_len > 0) {
                g_token_source = .vm;
                print("  [download] VM minted content proof; visitor proof="); print(if (g_stream_pot_len > 0) "YES" else "NO"); print(" attempt "); printNum(attempt + 1); print("\n");
                return;
            }
        }
    }
    if (options.require_vm_token) return;
    g_pot_len = minter.mintColdStart(video_id, &g_pot_buf);
    g_stream_pot_len = g_pot_len;
    if (g_pot_len > 0) @memcpy(g_stream_pot_buf[0..g_pot_len], g_pot_buf[0..g_pot_len]);
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
    print("  [download] SABR branch: serverAbrStreamingUrl present, no direct URL\n");

    // 1. serverAbrStreamingUrl (JSON-escaped) -> unescape to a real URL.
    const url_esc = sabr_mod.player_fields.serverAbrStreamingUrl(resp) orelse return false;
    const raw_url_len = sabr_mod.player_fields.unescapeInto(url_esc, &g_sabr_url_buf);
    if (raw_url_len == 0 or raw_url_len == g_sabr_url_buf.len) return false;
    const url_len = manifest_mod.transformStreamUrl(g_sabr_url_buf[0..raw_url_len], &g_sabr_url_buf);
    if (url_len == 0) {
        status.transform_failure = nsig_mod.lastFailure();
        print("  [download] SABR endpoint n transform unavailable: "); print(@tagName(nsig_mod.lastFailure()));
        if (nsig_mod.failureDetail().len > 0) { print(" ("); print(nsig_mod.failureDetail()); print(")"); }
        print("\n");
        return false;
    }
    status.transform_failure = null;
    const sabr_url = g_sabr_url_buf[0..url_len];

    // 2. ustreamer config (base64 string) -> raw bytes for the request field.
    var cfg_bytes: []const u8 = "";
    if (sabr_mod.player_fields.ustreamerConfig(resp)) |cfg_b64| {
        const n = base64Decode(cfg_b64, &g_sabr_cfg_buf);
        if (n == 0) return false;
        cfg_bytes = g_sabr_cfg_buf[0..n];
    }

    // 3. SABR playback attestation binds to the video, unlike direct GVS
    // URLs whose token binds to visitorData. Decode the content-bound proof.
    var pot_bytes: []const u8 = "";
    const sabr_pot_src = g_pot_buf[0..g_pot_len];
    if (sabr_pot_src.len > 0) {
        const n = base64Decode(sabr_pot_src, &g_sabr_pot_buf);
        if (n == 0) return false;
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
    var fsink = sabr_mod.stream.StagedFileSink.open(output_path) orelse return false;
    defer fsink.close();
    var transport_ctx = sabr_mod.stream.NetTransport{
        .jar = &g_session.jar,
        .user_agent = if (g_web_client == .mweb) session_mod.MWEB_UA else http.CHROME_UA,
    };

    const client_version = if (g_web_client == .mweb)
        g_session.mweb_client_version[0..g_session.mweb_client_version_len]
    else g_session.clientVersion();
    if (client_version.len == 0) return false;
    if (debug_sabr_capture) |capture| capture(sabr_url, resp, g_pot_buf[0..g_pot_len], pot_bytes, client_version);
    const selected = sabr_mod.request.SelectedFormat{
        .itag = @intCast(fmt.itag),
        .last_modified = fmt.last_modified,
        .xtags = fmt.xtags[0..fmt.xtags_len],
        .content_length = fmt.content_length,
    };

    print("  [download] SABR loop starting itag=");
    printNum(fmt.itag);
    print(" lmt=");
    printNum(fmt.last_modified);
    print(" cfg_bytes=");
    printNum(cfg_bytes.len);
    print(" pot_bytes=");
    printNum(pot_bytes.len);
    print(" client=");
    printNum(if (g_web_client == .mweb) 2 else 1);
    print(" cv_len=");
    printNum(client_version.len);
    print("\n");

    const transfer_started = profiling.clock(options.profile);
    const res = sabr_mod.stream.runLoopWithOptions(
        transport_ctx.transport(),
        host[0..hl],
        port,
        path[0..pl],
        selected,
        kind == .audio,
        cfg_bytes,
        pot_bytes,
        if (g_web_client == .mweb) 2 else 1,
        client_version,
        fsink.sink(),
        .{ .progress = options.progress, .on_response = options.sabr_response, .profile = options.profile },
    );
    profiling.add(options.profile, "transfer_ns", transfer_started);

    status.sabr_result = res;
    status.bytes_downloaded = res.bytes_written;
    status.success = res.success and res.bytes_written > 0;
    var committed = true;
    if (status.success) {
        const commit_started = profiling.clock(options.profile);
        committed = fsink.commit();
        profiling.add(options.profile, "commit_ns", commit_started);
    }
    if (!committed) {
        print("  [download] ERROR: complete SABR data could not be committed to the destination\n");
        status.success = false;
        status.sabr_result.?.success = false;
        status.sabr_result.?.failure = .media_write;
    }

    if (status.success) {
        status.transform_failure = null;
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
    print("  [download] SABR parts: media_header=");
    printNum(sabr_mod.stream.dbg_n_media_header);
    print(" media=");
    printNum(sabr_mod.stream.dbg_n_media);
    print(" ctx_update=");
    printNum(sabr_mod.stream.dbg_n_ctx_update);
    print(" next_policy=");
    printNum(sabr_mod.stream.dbg_n_next_policy);
    print(" sps=");
    printNum(sabr_mod.stream.dbg_n_sps);
    print(" fim=");
    printNum(sabr_mod.stream.dbg_n_fim);
    print("\n");
    // A gated/partial SABR response is NOT a usable stream — report failure so
    // the resolver can fall through to the WEB/MWEB session (proper pot) or the
    // muxed fallback. Only a completed stream counts as handled.
    return false;
}

// Decode standard or URL-safe base64, rejecting malformed or oversized values.
fn base64Decode(input: []const u8, out: []u8) usize {
    var acc: u32 = 0;
    var nbits: u5 = 0;
    var oi: usize = 0;
    var padding: usize = 0;
    for (input) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        if (c == '=') { padding += 1; if (padding > 2) return 0; continue; }
        const v: i16 = b64Val(c);
        if (v < 0 or padding > 0) return 0;
        acc = (acc << 6) | @as(u32, @intCast(v));
        if (nbits >= 2) {
            nbits -= 2;
            if (oi >= out.len) return 0;
            out[oi] = @intCast((acc >> nbits) & 0xFF);
            oi += 1;
        } else nbits += 6;
    }
    if (nbits == 6 or (nbits > 0 and acc & ((@as(u32, 1) << nbits) - 1) != 0)) return 0;
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

fn hasPlayerFormats(resp: []const u8) bool {
    if (resp.len == 0) return false;
    var formats: [manifest_mod.MAX_FORMATS]manifest_mod.StreamFormat = undefined;
    return manifest_mod.parseFormats(resp, &formats) > 0;
}

/// True when `resp` has at least one audio format carrying a directly usable
/// stream URL (populated without needing player.js cipher/nsig). The iOS client
/// satisfies this; WEB/MWEB generally do not (their audio is signatureCipher-only).
fn hasDirectAudio(resp: []const u8) bool {
    if (resp.len == 0) return false;
    var formats: [manifest_mod.MAX_FORMATS]manifest_mod.StreamFormat = undefined;
    const n = manifest_mod.parseFormats(resp, &formats);
    for (0..n) |i| {
        if (formats[i].is_audio and !formats[i].is_video and formats[i].url_len > 0) return true;
    }
    return false;
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

test "download profile resets stale samples before rejected external proof" {
    const testing = @import("std").testing;
    var profile = Profile{ .http_requests = 9, .sample_count = 1, .vm_ns = 42 };
    const status = fetch("7Cbr_W7I2Vg", .{ .options = .{ .require_vm_token = true, .pot_override = "diagnostic", .profile = &profile } }, "unused.m4a");
    try testing.expect(!status.success);
    try testing.expectEqual(TokenSource.none, status.token_source);
    try testing.expectEqual(@as(u32, 0), profile.http_requests);
    try testing.expectEqual(@as(usize, 0), profile.sample_count);
    try testing.expectEqual(@as(u64, 0), profile.vm_ns);
    try testing.expect(profile.total_ns >= profile.tokens_ns);
}

test "download attestation refresh is bounded and only applies to native protection failures" {
    const testing = @import("std").testing;
    const Fake = struct {
        var calls: u8 = 0;
        var succeeds_after: u8 = 2;
        var failure: sabr_mod.stream.Failure = .protection;
        var source: TokenSource = .vm;
        fn run(_: *const [meta.VIDEO_ID_LEN]u8, _: MediaRequest, _: [*:0]const u8) DownloadStatus {
            calls += 1;
            return .{ .success = calls >= succeeds_after, .bytes_downloaded = 3, .container = .mp4, .codec = .aac, .bitrate = 1, .duration_sec = 1,
                .token_source = source, .sabr_result = .{ .failure = if (calls >= succeeds_after) .none else failure } };
        }
    };
    const recovered = fetchAttempts(Fake.run, "7Cbr_W7I2Vg", .{}, "unused.m4a");
    try testing.expect(recovered.success);
    try testing.expectEqual(@as(u8, 2), Fake.calls);
    try testing.expectEqual(@as(u8, 1), recovered.attestation_refreshes);
    Fake.succeeds_after = 255;
    inline for (.{sabr_mod.stream.Failure.cancelled, .transport, .http_status, .media_write}) |failure| {
        Fake.calls = 0; Fake.failure = failure;
        _ = fetchAttempts(Fake.run, "7Cbr_W7I2Vg", .{}, "unused.m4a");
        try testing.expectEqual(@as(u8, 1), Fake.calls);
    }
    Fake.failure = .protection;
    Fake.source = .external; Fake.calls = 0;
    _ = fetchAttempts(Fake.run, "7Cbr_W7I2Vg", .{}, "unused.m4a");
    try testing.expectEqual(@as(u8, 1), Fake.calls);
    Fake.source = .vm; Fake.calls = 0;
    _ = fetchAttempts(Fake.run, "7Cbr_W7I2Vg", .{ .options = .{ .max_attestation_refreshes = 0 } }, "unused.m4a");
    try testing.expectEqual(@as(u8, 1), Fake.calls);
    Fake.calls = 0;
    _ = fetchAttempts(Fake.run, "7Cbr_W7I2Vg", .{ .options = .{ .pot_override = "diagnostic" } }, "unused.m4a");
    try testing.expectEqual(@as(u8, 1), Fake.calls);
    Fake.calls = 0;
    const exhausted = fetchAttempts(Fake.run, "7Cbr_W7I2Vg", .{ .options = .{ .max_attestation_refreshes = 255 } }, "unused.m4a");
    try testing.expect(!exhausted.success);
    try testing.expectEqual(@as(u8, 4), Fake.calls);
    try testing.expectEqual(@as(u8, 3), exhausted.attestation_refreshes);
    try testing.expectEqual(sabr_mod.stream.Failure.protection, exhausted.sabr_result.?.failure);
    Fake.calls = 0;
    const audio_exhausted = fetchAttemptsFrom(Fake.run, "7Cbr_W7I2Vg", .{}, "unused.m4a", 1);
    try testing.expectEqual(@as(u8, 1), Fake.calls);
    try testing.expectEqual(@as(u8, 1), audio_exhausted.attestation_refreshes);

}
