// @zpm/youtube/sabr/stream — SABR streaming loop
//
// Drives the SABR delivery loop for one selected format:
//
//   1. Build a VideoPlaybackAbrRequest (request.sig) for the selected
//      (itag, lmt) with the current buffered ranges + player time.
//   2. POST it to serverAbrStreamingUrl (net.postIntoJar; the session jar + a
//      multi-MB caller buffer).
//   3. Parse the UMP response (ump.sig), stitching parts across POSTs via
//      PartialState.
//   4. Append each MEDIA part's bytes to the output sink; update buffered
//      ranges / player time from MEDIA_HEADER + NEXT_REQUEST_POLICY.
//   5. On SABR_REDIRECT switch the SABR URL and re-POST; stop on MEDIA_END or
//      when the selected format's contentLength / totalSegments is reached.
//   6. On SABR_ERROR / a STREAM_PROTECTION_STATUS wall, stop and surface the
//      raw status in SabrResult (fail-closed; never fabricate success).
//
// The HTTP POST sits behind `Transport` and the file write behind `Sink` so the
// parse/accumulate core (`processUmpBuffer`) is exercised offline in tests with
// a synthetic UMP byte stream and a memory sink. Zero allocation: response and
// stitch buffers are module-static or caller-provided.

const ump = @import("ump.sig");
const request = @import("request.sig");
const http = @import("youtube_net");
const profiling = @import("../download_profile.sig");

// ── Win32 file sink (append writer) ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;
extern "kernel32" fn FlushFileBuffers(?*anyopaque) c_int;
extern "kernel32" fn MoveFileExA([*:0]const u8, [*:0]const u8, u32) c_int;
extern "kernel32" fn Sleep(u32) void;
extern "kernel32" fn GetTickCount64() u64;

const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

/// A byte sink the loop appends decoded MEDIA bytes to. `ctx` is opaque; `write`
/// returns false on a write failure (which aborts the loop fail-closed).
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
};

const ProfiledSink = struct {
    inner: Sink,
    profile: ?*profiling.Profile,
    fn write(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *ProfiledSink = @ptrCast(@alignCast(ctx));
        const started = profiling.clock(self.profile);
        defer profiling.add(self.profile, "sink_ns", started);
        return self.inner.write(self.inner.ctx, bytes);
    }
};
fn sleepProfiled(ms: u32, profile: ?*profiling.Profile) void {
    const started = profiling.clock(profile);
    Sleep(ms);
    profiling.add(profile, "sleep_ns", started);
}

/// A Win32 file-backed sink. Open once, append each MEDIA chunk, close at end.
pub const FileSink = struct {
    handle: ?*anyopaque = null,
    bytes_written: u64 = 0,

    pub fn open(path: [*:0]const u8) ?FileSink {
        const fh = CreateFileA(path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (fh == INVALID_HANDLE or fh == null) return null;
        return .{ .handle = fh, .bytes_written = 0 };
    }

    pub fn close(self: *FileSink) void {
        if (self.handle) |h| {
            _ = CloseHandle(h);
            self.handle = null;
        }
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *FileSink = @ptrCast(@alignCast(ctx));
        if (self.handle == null) return false;
        var off: usize = 0;
        while (off < bytes.len) {
            var n: u32 = 0;
            if (WriteFile(self.handle, bytes[off..].ptr, @intCast(bytes.len - off), &n, null) == 0 or n == 0)
                return false;
            off += n;
        }
        self.bytes_written += bytes.len;
        return true;
    }

    pub fn sink(self: *FileSink) Sink {
        return .{ .ctx = @ptrCast(self), .write = &writeImpl };
    }
};

/// Stages a download beside its destination. Failed/cancelled transfers leave
/// `<path>.part` for inspection and never replace an existing complete file.
/// The caller commits only after the streaming protocol reports completion.
pub const StagedFileSink = struct {
    file: FileSink,
    destination: [1024:0]u8 = @splat(0),
    partial: [1029:0]u8 = @splat(0),
    committed: bool = false,

    pub fn open(path: [*:0]const u8) ?StagedFileSink {
        var self = StagedFileSink{ .file = .{} };
        var length: usize = 0;
        while (path[length] != 0) : (length += 1) {
            if (length == self.destination.len) return null;
            self.destination[length] = path[length];
            self.partial[length] = path[length];
        }
        if (length == 0) return null;
        @memcpy(self.partial[length..][0..5], ".part");
        self.file = FileSink.open(&self.partial) orelse return null;
        return self;
    }

    pub fn close(self: *StagedFileSink) void { self.file.close(); }
    pub fn sink(self: *StagedFileSink) Sink { return self.file.sink(); }

    pub fn commit(self: *StagedFileSink) bool {
        if (self.committed) return true;
        const handle = self.file.handle orelse return false;
        const flushed = FlushFileBuffers(handle) != 0;
        self.file.close();
        if (!flushed) return false;
        // Same-directory rename stays on the same volume. Replace the requested
        // destination only after a complete transfer; propagate commit failures.
        if (MoveFileExA(&self.partial, &self.destination, 1 | 8) == 0) return false;
        self.committed = true;
        return true;
    }
};

// ── Transport seam ──

pub const PostResult = struct { status: u32 = 0, len: usize = 0, ok: bool = false };

/// Abstracts the SABR POST so the loop can be tested without a network. The
/// production transport posts through net.postIntoJar.
pub const Transport = struct {
    ctx: *anyopaque,
    post: *const fn (ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult,
};

// ── Loop state + result ──

/// Outcome the loop surfaces so a caller can distinguish success from a wall.
pub const SabrResult = struct {
    success: bool = false,
    failure: Failure = .none,
    bytes_written: u64 = 0,
    last_status: u32 = 0,
    media_end: bool = false,
    sabr_error_code: i32 = 0,
    sabr_error_seen: bool = false,
    protection_status: i32 = 0, // last STREAM_PROTECTION_STATUS.status (0 if none)
    redirects: u16 = 0,
    requests: u32 = 0,
    retries: u32 = 0,
};

pub const Failure = enum { none, transport, http_status, empty_response, request_capacity, response_capacity, media_write, cancelled, sabr_error, protection, incomplete, iteration_limit };

/// Per-format accumulation state updated while parsing UMP parts.
pub const FormatProgress = struct {
    itag: i32 = 0,
    last_modified: u64 = 0,
    bytes: u64 = 0,
    last_segment_num: i32 = -1,
    total_segments: i64 = 0,
    end_time_ms: i64 = 0,
    buffered_end_ms: i64 = 0,
    header_id: u32 = 0,
    header_active: bool = false,
    segment_num: i32 = 0,
    segment_init: bool = false,
    segment_end_ms: i64 = 0,
    segment_expected_bytes: i64 = 0,
    segment_bytes: u64 = 0,
    initialized: bool = false,
};

/// What a single UMP buffer pass reports back to the loop.
pub const ProcessOutcome = struct {
    media_end: bool = false,
    redirect_url: []const u8 = "", // non-empty => follow SABR_REDIRECT
    sabr_error_seen: bool = false,
    sabr_error_code: i32 = 0,
    protection_status: i32 = 0,
    backoff_time_ms: i32 = 0,
    playback_cookie: []const u8 = "",
    media_bytes: u64 = 0, // media bytes appended this pass
    // A SABR_CONTEXT_UPDATE the server wants echoed back on the next request.
    ctx_update: []const u8 = "", // raw value bytes (borrowed from the response)
    ctx_update_type: i32 = 0,
    ctx_update_scope: i32 = 0,
    ctx_update_send_by_default: bool = false,
    has_ctx_update: bool = false,
};

/// Parse a complete UMP buffer, routing MEDIA bytes to `sink` and recording the
/// control signals the loop acts on. `progress` tracks the selected format's
/// accumulation. Returns the outcome, or null if a sink write failed.
pub fn processUmpBuffer(buf: []const u8, sink: Sink, progress: *FormatProgress) ?ProcessOutcome {
    var out = ProcessOutcome{};
    var write_failed = false;
    var pr = ump.PartReader.init(buf);
    while (pr.next()) |part| {
        applyPart(part, sink, progress, &out, &write_failed);
        if (write_failed) return null;
    }
    return out;
}

// ── Full loop ──

const RESP_BUF_SIZE: usize = 8 * 1024 * 1024; // 8 MB per SABR response
var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
var stitch_buf: [RESP_BUF_SIZE + 1024 * 1024]u8 = undefined;
var redirect_url_buf: [4096]u8 = undefined;

const MAX_ITERATIONS: u16 = 2048;
const MAX_REDIRECTS: u16 = 8;
// How many consecutive ATTESTATION_PENDING (status 2) passes to tolerate before
// concluding the server will not transition to OK (a genuine attestation wall).
const MAX_PENDING_PASSES: u16 = 24;

/// Run the SABR loop against `transport`, appending media to `sink`. `host`/
/// `path` are the parsed serverAbrStreamingUrl; `selected` is the single
/// audio OR video format to pull. Returns a fail-closed SabrResult.
pub fn runLoop(
    transport: Transport,
    host_in: []const u8,
    port: u16,
    path_in: []const u8,
    selected: request.SelectedFormat,
    is_audio: bool,
    ustreamer_config: []const u8,
    po_token: []const u8,
    client_name: i32,
    client_version: []const u8,
    sink: Sink,
) SabrResult {
    return runLoopWithOptions(transport, host_in, port, path_in, selected, is_audio, ustreamer_config, po_token, client_name, client_version, sink, .{});
}

pub const LoopOptions = struct {
    profile: ?*profiling.Profile = null,
    progress: ?*const fn (downloaded: u64, total: u64) void = null,
    // Return false to cancel between HTTP requests.
    on_response: ?*const fn (result: SabrResult) bool = null,
    // Retry only failures with no HTTP response, or transient server statuses.
    // Each attempt reuses the same request number/body; no media is committed.
    max_transport_retries: u8 = 3,
    retry_delay_ms: u32 = 250,
};

pub fn runLoopWithOptions(
    transport: Transport, host_in: []const u8, port: u16, path_in: []const u8,
    selected: request.SelectedFormat, is_audio: bool, ustreamer_config: []const u8,
    po_token: []const u8, client_name: i32, client_version: []const u8,
    sink: Sink, options: LoopOptions,
) SabrResult {
    var result = SabrResult{};
    var measured_sink = ProfiledSink{ .inner = sink, .profile = options.profile };
    const actual_sink = if (options.profile != null) Sink{ .ctx = &measured_sink, .write = &ProfiledSink.write } else sink;
    var progress = FormatProgress{ .itag = selected.itag, .last_modified = selected.last_modified };

    // Reset diagnostic per-pass trace for this run.
    dbg_pass_n = 0;
    dbg_n_media_header = 0;
    dbg_n_media = 0;
    dbg_n_ctx_update = 0;
    dbg_n_next_policy = 0;
    dbg_n_sps = 0;
    dbg_n_fim = 0;
    dbg_last_part_n = 0;

    var host: []const u8 = host_in;
    var port_cur: u16 = port;
    var path: []const u8 = path_in;

    var state = ump.PartialState.init(&stitch_buf);
    var player_time_ms: i64 = 0;
    var playback_cookie: [512]u8 = undefined;
    var playback_cookie_len: usize = 0;
    // Latest SABR context update the server asked us to echo (survives passes).
    var ctx_update_len: usize = 0;
    var ctx_update_type: i32 = 0;

    var pending_passes: u16 = 0;
    const started = GetTickCount64();
    var iter: u16 = 0;
    while (iter < MAX_ITERATIONS) : (iter += 1) {
        // Build the request body for this round.
        const audio: []const request.SelectedFormat = if (is_audio) &.{selected} else &.{};
        const video: []const request.SelectedFormat = if (is_audio) &.{} else &.{selected};
        var body_buf: [16384]u8 = undefined;
        const buffered = request.BufferedRange{
            .itag = selected.itag,
            .last_modified = selected.last_modified,
            .start_time_ms = 0,
            .duration_ms = progress.buffered_end_ms,
            .start_segment_index = 0,
            .end_segment_index = progress.last_segment_num,
        };
        const params = request.AbrParams{
            .player_time_ms = player_time_ms,
            .elapsed_wall_time_ms = @intCast(@min(GetTickCount64() - started, 0x7fffffffffffffff)),
            .audio_formats = audio,
            .video_formats = video,
            .initialized_formats = if (progress.initialized) &.{selected} else &.{},
            .ustreamer_config = ustreamer_config,
            .po_token = po_token,
            .client_name = client_name,
            .client_version = client_version,
            .playback_cookie = playback_cookie[0..playback_cookie_len],
            .enabled_track_types_bitfield = if (is_audio) 1 else 0,
            .buffered = if (progress.last_segment_num >= 0) &.{buffered} else &.{},
            .sabr_context = ctx_update_buf[0..ctx_update_len],
            .sabr_context_type = ctx_update_type,
        };
        const build_started = profiling.clock(options.profile);
        const body_len = request.buildAbrRequest(params, &body_buf) catch {
            profiling.add(options.profile, "request_build_ns", build_started);
            result.failure = .request_capacity;
            return result;
        };

        var request_path: [9408]u8 = undefined;
        const request_path_len = numberedPath(path, iter, &request_path) orelse {
            profiling.add(options.profile, "request_build_ns", build_started);
            result.failure = .request_capacity;
            break;
        };
        profiling.add(options.profile, "request_build_ns", build_started);
        var r: PostResult = .{};
        var attempts: u16 = 0;
        while (true) {
            const http_started = profiling.clock(options.profile);
            r = transport.post(transport.ctx, host, port_cur, request_path[0..request_path_len], body_buf[0..body_len], &resp_buf);
            if (options.profile) |p| p.recordHttp(profiling.clock(p) -| http_started, r.len, r.status);
            result.requests += 1;
            result.last_status = r.status;
            const transient = r.status == 0 or r.status == 408 or r.status == 429 or r.status == 500 or r.status == 502 or r.status == 503 or r.status == 504;
            if (r.ok or !transient or attempts >= options.max_transport_retries) break;
            if (options.on_response) |callback| if (!callback(result)) {
                result.failure = .cancelled;
                return result;
            };
            attempts += 1;
            result.retries += 1;
            if (options.retry_delay_ms > 0) sleepProfiled(@min(options.retry_delay_ms, 30000), options.profile);
        }
        if (!r.ok or r.len == 0) {
            result.failure = if (r.status == 0) .transport else if (!r.ok) .http_status else .empty_response;
            break;
        }
        if (r.len > resp_buf.len) { result.failure = .response_capacity; break; }
        const ump_started = profiling.clock(options.profile);
        const combined = state.combine(resp_buf[0..r.len]) orelse { profiling.add(options.profile, "ump_ns", ump_started); result.failure = .response_capacity; break; };
        // Walk parts via the shared `applyPart` dispatch (same path as
        // processUmpBuffer) while keeping the reader cursor so a part split
        // across this and the next POST survives via state.carry(leftover).
        var pr = ump.PartReader.init(combined);
        var pass = ProcessOutcome{};
        var write_failed = false;
        while (pr.next()) |part| {
            applyPart(part, actual_sink, &progress, &pass, &write_failed);
            if (write_failed) break;
        }
        if (write_failed) { profiling.add(options.profile, "ump_ns", ump_started); result.bytes_written = progress.bytes; result.failure = .media_write; break; }
        state.carry(pr.leftover());
        profiling.add(options.profile, "ump_ns", ump_started);
        if (options.profile) |p| {
            if (progress.bytes > 0 and p.first_media_ns == 0) p.first_media_ns = profiling.clock(p) -| p.started_ns;
            if (p.sample_count > 0 and p.dropped_samples == 0) {
                p.samples[p.sample_count - 1].media_bytes = pass.media_bytes;
                p.samples[p.sample_count - 1].protection = pass.protection_status;
            }
        }

        result.bytes_written = progress.bytes;
        if (pass.protection_status != 0) result.protection_status = pass.protection_status;
        if (options.progress) |callback| callback(progress.bytes, selected.content_length);
        if (options.on_response) |callback| if (!callback(result)) { result.failure = .cancelled; break; };
        if (result.protection_status == 3) { result.failure = .protection; break; }
        player_time_ms = progress.buffered_end_ms;
        if (pass.playback_cookie.len > playback_cookie.len) break;
        if (pass.playback_cookie.len > 0) {
            @memcpy(playback_cookie[0..pass.playback_cookie.len], pass.playback_cookie);
            playback_cookie_len = pass.playback_cookie.len;
        }
        // Capture a SABR context update to echo on the next request (this is how
        // the server validates and transitions STREAM_PROTECTION_STATUS 2 -> OK).
        // NOTE: capture the per-pass handshake trace BEFORE we overwrite
        // ctx_update_* with this pass's update, so `sent_ctx_*` reflects what we
        // actually sent INTO this request (the previous pass's captured context).
        if (dbg_pass_n < dbg_passes.len) {
            dbg_passes[dbg_pass_n] = .{
                .request_no = result.requests,
                .http_status = r.status,
                .protection_status = pass.protection_status,
                .media_bytes = pass.media_bytes,
                .total_bytes = progress.bytes,
                .has_ctx_update = pass.has_ctx_update,
                .ctx_type = pass.ctx_update_type,
                .ctx_scope = pass.ctx_update_scope,
                .ctx_send_by_default = pass.ctx_update_send_by_default,
                .ctx_len = pass.ctx_update.len,
                .sabr_error_seen = pass.sabr_error_seen,
                .sabr_error_code = pass.sabr_error_code,
                .backoff_ms = pass.backoff_time_ms,
                .sent_ctx_len = ctx_update_len,
                .sent_ctx_type = ctx_update_type,
                .sent_pot_len = po_token.len,
                .sent_buffered_end_ms = buffered.duration_ms,
                .sent_player_time_ms = player_time_ms,
                .sent_initialized = progress.initialized,
            };
            dbg_pass_n += 1;
        }

        if (pass.has_ctx_update and pass.ctx_update.len > 0 and pass.ctx_update.len <= ctx_update_buf.len) {
            @memcpy(ctx_update_buf[0..pass.ctx_update.len], pass.ctx_update);
            ctx_update_len = pass.ctx_update.len;
            ctx_update_type = pass.ctx_update_type;
        }

        if (pass.sabr_error_seen) {
            result.sabr_error_seen = true;
            result.sabr_error_code = pass.sabr_error_code;
            break;
        }
        if (pass.media_end) result.media_end = true;
        if (pass.redirect_url.len > 0 and result.redirects < MAX_REDIRECTS) {
            // Follow SABR_REDIRECT: re-parse host/path from the new URL.
            const n = @min(pass.redirect_url.len, redirect_url_buf.len);
            @memcpy(redirect_url_buf[0..n], pass.redirect_url[0..n]);
            var h2: [256]u8 = undefined;
            var p2: [9216]u8 = undefined;
            var hl: usize = 0;
            var pl: usize = 0;
            var pt: u16 = 443;
            if (parseUrl(redirect_url_buf[0..n], &h2, &hl, &p2, &pl, &pt)) {
                // Copy into module-static holders that outlive the loop body.
                @memcpy(redirect_host[0..hl], h2[0..hl]);
                @memcpy(redirect_path[0..pl], p2[0..pl]);
                host = redirect_host[0..hl];
                path = redirect_path[0..pl];
                port_cur = pt;
                result.redirects += 1;
                state.reset();
                continue;
            }
        }

        // Stop when the selected format is fully pulled.
        if (formatComplete(selected, progress) and state.len == 0) {
            result.success = true;
            break;
        }
        // STREAM_PROTECTION_STATUS == 2 (ATTESTATION_PENDING): the server
        // accepted the request and is validating the PO token; it may return an
        // empty media pass for a few round-trips before it transitions to OK and
        // resumes delivery. Keep requesting (bounded) rather than giving up on
        // the first empty pass, as long as the token/handshake is in flight.
        if (pass.protection_status == 2) {
            pending_passes += 1;
            if (pending_passes <= MAX_PENDING_PASSES) {
                if (pass.backoff_time_ms > 0) sleepProfiled(@intCast(@min(pass.backoff_time_ms, 30000)), options.profile);
                continue;
            }
            break;
        }
        pending_passes = 0;
        // No media and no control signal => nothing more to pull.
        if (pass.media_bytes == 0 and pass.backoff_time_ms == 0 and pass.redirect_url.len == 0) {
            break;
        }
        if (pass.backoff_time_ms > 0) sleepProfiled(@intCast(@min(pass.backoff_time_ms, 30000)), options.profile);
    }

    if (!result.success and result.failure == .none) result.failure = if (iter == MAX_ITERATIONS) .iteration_limit else if (result.sabr_error_seen) .sabr_error else if (result.protection_status == 2 or result.protection_status == 3) .protection else .incomplete;
    return result;
}

var redirect_host: [256]u8 = undefined;
var redirect_path: [9216]u8 = undefined;
var ctx_update_buf: [4096]u8 = undefined;

// Preserve signed query fields while replacing only client request controls.
fn numberedPath(path: []const u8, number: u16, out: []u8) ?usize {
    var query: usize = 0;
    while (query < path.len and path[query] != '?') : (query += 1) {}
    if (query + 32 > out.len) return null;
    @memcpy(out[0..query], path[0..query]);
    var n = query;
    var at = if (query < path.len) query + 1 else path.len;
    var first = true;
    while (at < path.len) {
        const start = at;
        while (at < path.len and path[at] != '&') : (at += 1) {}
        const field = path[start..at];
        const skip = (field.len >= 3 and field[0] == 'r' and field[1] == 'n' and field[2] == '=') or
            (field.len >= 4 and field[0] == 'a' and field[1] == 'l' and field[2] == 'r' and field[3] == '=');
        if (!skip and field.len > 0) {
            if (n + 1 + field.len + 32 > out.len) return null;
            out[n] = if (first) '?' else '&'; n += 1;
            @memcpy(out[n..][0..field.len], field); n += field.len;
            first = false;
        }
        if (at < path.len) at += 1;
    }
    const suffix = "alr=no&rn=";
    out[n] = if (first) '?' else '&'; n += 1;
    @memcpy(out[n..][0..suffix.len], suffix); n += suffix.len;
    var digits: [5]u8 = undefined;
    var d = digits.len;
    var value = number;
    while (true) {
        d -= 1; digits[d] = @intCast(value % 10 + '0'); value /= 10;
        if (value == 0) break;
    }
    @memcpy(out[n..][0..digits.len - d], digits[d..]);
    return n + digits.len - d;
}

// Diagnostics: counts of each interesting part type seen across the whole loop.
pub var dbg_n_media_header: u32 = 0;
pub var dbg_n_media: u32 = 0;
pub var dbg_n_ctx_update: u32 = 0;
pub var dbg_n_next_policy: u32 = 0;
pub var dbg_n_sps: u32 = 0;
pub var dbg_n_fim: u32 = 0;
pub var dbg_n_passes: u32 = 0;
pub var dbg_last_part_types: [16]u64 = [_]u64{0} ** 16;
pub var dbg_last_part_n: usize = 0;

// Per-pass handshake trace (diagnostic only; no production behavior change).
// Captures, for each SABR round-trip, exactly what the server returned and what
// the client carried INTO that request, so a protection-2 wall can be bisected.
pub const DbgPass = struct {
    request_no: u32 = 0,
    http_status: u32 = 0,
    protection_status: i32 = 0,
    media_bytes: u64 = 0,
    total_bytes: u64 = 0,
    // Signals received this pass
    has_ctx_update: bool = false,
    ctx_type: i32 = 0,
    ctx_scope: i32 = 0,
    ctx_send_by_default: bool = false,
    ctx_len: usize = 0,
    sabr_error_seen: bool = false,
    sabr_error_code: i32 = 0,
    backoff_ms: i32 = 0,
    // What the client carried INTO this request
    sent_ctx_len: usize = 0,
    sent_ctx_type: i32 = 0,
    sent_pot_len: usize = 0,
    sent_buffered_end_ms: i64 = 0,
    sent_player_time_ms: i64 = 0,
    sent_initialized: bool = false,
};
pub var dbg_passes: [256]DbgPass = undefined;
pub var dbg_pass_n: usize = 0;

fn formatComplete(selected: request.SelectedFormat, progress: FormatProgress) bool {
    if (progress.header_active or progress.bytes == 0) return false;
    if (selected.content_length > 0) return progress.bytes == selected.content_length;
    return progress.end_time_ms > 0 and progress.buffered_end_ms >= progress.end_time_ms;
}

/// Shared part dispatch used by both the offline `processUmpBuffer` and the
/// live loop (so they cannot diverge).
fn applyPart(part: ump.Part, sink: Sink, progress: *FormatProgress, pass: *ProcessOutcome, write_failed: *bool) void {
    if (dbg_last_part_n < dbg_last_part_types.len) { dbg_last_part_types[dbg_last_part_n] = part.part_type; dbg_last_part_n += 1; }
    switch (part.part_type) {
        ump.PartType.MEDIA_HEADER => dbg_n_media_header += 1,
        ump.PartType.MEDIA => dbg_n_media += 1,
        ump.PartType.SABR_CONTEXT_UPDATE => dbg_n_ctx_update += 1,
        ump.PartType.NEXT_REQUEST_POLICY => dbg_n_next_policy += 1,
        ump.PartType.STREAM_PROTECTION_STATUS => dbg_n_sps += 1,
        ump.PartType.FORMAT_INITIALIZATION_METADATA => dbg_n_fim += 1,
        else => {},
    }
    switch (part.part_type) {
        ump.PartType.MEDIA_HEADER => {
            const mh = ump.decodeMediaHeader(part.payload);
            if (mh.itag != 0 and progress.itag == 0) progress.itag = mh.itag;
            if (mh.itag != progress.itag or (mh.lmt != 0 and progress.last_modified != 0 and mh.lmt != progress.last_modified)) return;
            // A second unfinished selected header would require reordering
            // pending segment buffers. Abort rather than append corrupt bytes.
            if (progress.header_active) { write_failed.* = true; return; }
            if (mh.segment_num <= progress.last_segment_num) return;
            progress.header_id = mh.header_id;
            progress.header_active = true;
            progress.segment_num = mh.segment_num;
            progress.segment_init = mh.is_init_segment;
            if (mh.start_ms < 0 or mh.duration_ms < 0 or mh.start_ms > 0x7FFFFFFFFFFFFFFF - mh.duration_ms) {
                write_failed.* = true;
                return;
            }
            progress.segment_end_ms = mh.start_ms + mh.duration_ms;
            progress.segment_expected_bytes = mh.content_length;
            progress.segment_bytes = 0;
        },
        ump.PartType.MEDIA => {
            var hid: u32 = 0;
            const media = ump.mediaBytes(part.payload, &hid);
            if (!progress.header_active or hid != progress.header_id) return;
            if (media.len > 0) {
                if (!sink.write(sink.ctx, media)) {
                    write_failed.* = true;
                    return;
                }
                progress.bytes += media.len;
                progress.segment_bytes += media.len;
                pass.media_bytes += media.len;
            }
        },
        ump.PartType.MEDIA_END => {
            if (part.payload.len != 1 or !progress.header_active or part.payload[0] != progress.header_id) return;
            if (progress.segment_expected_bytes > 0 and progress.segment_bytes != @as(u64, @intCast(progress.segment_expected_bytes))) {
                write_failed.* = true;
                return;
            }
            progress.header_active = false;
            if (progress.segment_init) progress.initialized = true;
            if (!progress.segment_init) {
                progress.last_segment_num = progress.segment_num;
                progress.buffered_end_ms = @max(progress.buffered_end_ms, progress.segment_end_ms);
            }
            pass.media_end = true;
        },
        ump.PartType.FORMAT_INITIALIZATION_METADATA => {
            const fim = ump.decodeFormatInit(part.payload);
            if (fim.itag == progress.itag and (fim.lmt == 0 or progress.last_modified == 0 or fim.lmt == progress.last_modified)) {
                progress.total_segments = fim.end_segment_num;
                progress.end_time_ms = fim.end_time_ms;
            }
        },
        ump.PartType.SABR_REDIRECT => {
            const red = ump.decodeSabrRedirect(part.payload);
            if (red.url.len > 0) pass.redirect_url = red.url;
        },
        ump.PartType.SABR_ERROR => {
            const err = ump.decodeSabrError(part.payload);
            pass.sabr_error_seen = true;
            pass.sabr_error_code = err.code;
        },
        ump.PartType.NEXT_REQUEST_POLICY => {
            const pol = ump.decodeNextRequestPolicy(part.payload);
            pass.backoff_time_ms = pol.backoff_time_ms;
            pass.playback_cookie = pol.playback_cookie;
        },
        ump.PartType.STREAM_PROTECTION_STATUS => {
            const sps = ump.decodeStreamProtectionStatus(part.payload);
            pass.protection_status = sps.status;
        },
        ump.PartType.SABR_CONTEXT_UPDATE => {
            const cu = ump.decodeSabrContextUpdate(part.payload);
            if (cu.present and cu.value.len > 0) {
                pass.ctx_update = cu.value;
                pass.ctx_update_type = cu.ctx_type;
                pass.ctx_update_scope = cu.scope;
                pass.ctx_update_send_by_default = cu.send_by_default;
                pass.has_ctx_update = true;
            }
        },
        else => {},
    }
}

// ── URL parsing (host/port/path split; mirrors stream.sig) ──

pub fn parseUrl(url_str: []const u8, host: *[256]u8, host_len: *usize, path: *[9216]u8, path_len: *usize, port: *u16) bool {
    const scheme = "https://";
    if (url_str.len <= scheme.len) return false;
    for (scheme, 0..) |c, j| if (url_str[j] != c) return false;
    var i: usize = scheme.len;

    host_len.* = 0;
    while (i < url_str.len and url_str[i] != '/' and url_str[i] != ':') : (i += 1) {
        if (host_len.* >= host.len - 1 or url_str[i] <= 32 or url_str[i] >= 127) return false;
        host[host_len.*] = url_str[i];
        host_len.* += 1;
    }
    if (host_len.* == 0) return false;

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

// ── Production transport (net.postIntoJar) ──

/// Context the live transport carries: the session cookie jar + request headers.
pub const NetTransport = struct {
    jar: ?*http.CookieJar = null,
    user_agent: []const u8 = http.CHROME_UA,
    extra_headers: []const u8 = "Content-Type: application/x-protobuf\r\nOrigin: https://www.youtube.com\r\n",

    fn postImpl(ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult {
        const self: *NetTransport = @ptrCast(@alignCast(ctx));
        const r = http.postIntoJar(host, port, path, self.extra_headers, body, self.user_agent, self.jar, out);
        return .{ .status = r.status, .len = r.len, .ok = r.ok };
    }

    pub fn transport(self: *NetTransport) Transport {
        return .{ .ctx = @ptrCast(self), .post = &postImpl };
    }
};

// ── Tests (inline, std.testing) ──

const std = @import("std");
const testing = std.testing;

// A memory sink that collects written bytes for assertions.
const MemSink = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *MemSink = @ptrCast(@alignCast(ctx));
        if (self.len + bytes.len > self.buf.len) return false;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
        return true;
    }
    fn sink(self: *MemSink) Sink {
        return .{ .ctx = @ptrCast(self), .write = &writeImpl };
    }
};

fn writeUmpVarint(buf: []u8, value: u64) usize {
    if (value < 0x80) {
        buf[0] = @intCast(value);
        return 1;
    } else if (value < 0x4000) {
        buf[0] = @as(u8, 0x80) | @as(u8, @intCast(value & 0x3F));
        buf[1] = @intCast((value >> 6) & 0xFF);
        return 2;
    }
    buf[0] = 0xF0;
    buf[1] = @intCast(value & 0xFF);
    buf[2] = @intCast((value >> 8) & 0xFF);
    buf[3] = @intCast((value >> 16) & 0xFF);
    buf[4] = @intCast((value >> 24) & 0xFF);
    return 5;
}

fn appendPart(buf: []u8, off: usize, ptype: u64, payload: []const u8) usize {
    var p = off;
    p += writeUmpVarint(buf[p..], ptype);
    p += writeUmpVarint(buf[p..], payload.len);
    @memcpy(buf[p .. p + payload.len], payload);
    return p + payload.len;
}

test "sabr-loop: processUmpBuffer collects media and terminates on MEDIA_END" {
    // Build: MEDIA_HEADER(itag=251), MEDIA(header_id=0 + "AUDIO"), MEDIA_END.
    var buf: [128]u8 = undefined;
    var mh: [8]u8 = undefined;
    var mw = @import("protobuf").Writer.init(&mh);
    try mw.writeVarintField(3, 251); // itag
    var p: usize = 0;
    p = appendPart(&buf, p, ump.PartType.MEDIA_HEADER, mw.bytes());
    p = appendPart(&buf, p, ump.PartType.MEDIA, &.{ 0x00, 'A', 'U', 'D', 'I', 'O' });
    p = appendPart(&buf, p, ump.PartType.MEDIA_END, &.{0x00});

    var mem = MemSink{};
    var progress = FormatProgress{ .itag = 251 };
    const outcome = processUmpBuffer(buf[0..p], mem.sink(), &progress).?;
    try testing.expect(outcome.media_end);
    try testing.expectEqual(@as(u64, 5), outcome.media_bytes);
    try testing.expectEqual(@as(u64, 5), progress.bytes);
    try testing.expectEqualSlices(u8, "AUDIO", mem.buf[0..mem.len]);
    try testing.expectEqual(@as(i32, 251), progress.itag);
}

test "sabr-loop: runLoop completes only the full selected representation" {
    const Fake = struct {
        served: bool = false,
        resp: [64]u8 = undefined,
        resp_len: usize = 0,

        fn postImpl(ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult {
            _ = host;
            _ = port;
            _ = path;
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.served) return .{ .status = 204, .len = 0, .ok = false };
            self.served = true;
            @memcpy(out[0..self.resp_len], self.resp[0..self.resp_len]);
            return .{ .status = 200, .len = self.resp_len, .ok = true };
        }
    };
    var fake = Fake{};
    var fp: usize = 0;
    var mh: [16]u8 = undefined;
    var mw = @import("protobuf").Writer.init(&mh);
    try mw.writeVarintField(3, 251);
    try mw.writeVarintField(14, 3);
    fp = appendPart(&fake.resp, fp, ump.PartType.MEDIA_HEADER, mw.bytes());
    fp = appendPart(&fake.resp, fp, ump.PartType.MEDIA, &.{ 0x00, 'X', 'Y', 'Z' });
    fp = appendPart(&fake.resp, fp, ump.PartType.MEDIA_END, &.{0x00});
    fake.resp_len = fp;

    const transport = Transport{ .ctx = @ptrCast(&fake), .post = &Fake.postImpl };
    var mem = MemSink{};
    const res = runLoop(
        transport,
        "rr5.googlevideo.com",
        443,
        "/videoplayback?sabr=1",
        .{ .itag = 251, .last_modified = 100, .content_length = 3 },
        true,
        "",
        "",
        1,
        "2.2025",
        mem.sink(),
    );
    try testing.expect(res.success);
    try testing.expect(res.media_end);
    try testing.expectEqual(@as(u64, 3), res.bytes_written);
    try testing.expectEqualSlices(u8, "XYZ", mem.buf[0..mem.len]);

    // MEDIA_END closes this segment; it does not prove the rest of a video
    // exists. The next HTTP failure must leave the whole file incomplete.
    fake.served = false;
    mem = .{};
    const partial = runLoop(transport, "rr5.googlevideo.com", 443, "/videoplayback?sabr=1", .{ .itag = 251, .last_modified = 100, .content_length = 6 }, true, "", "", 1, "2.2025", mem.sink());
    try testing.expect(!partial.success);
    try testing.expectEqual(@as(u64, 3), partial.bytes_written);
    fake.served = false;
    mem = .{};
    const unknown = runLoop(transport, "rr5.googlevideo.com", 443, "/videoplayback?sabr=1", .{ .itag = 251, .last_modified = 100 }, true, "", "", 1, "2.2025", mem.sink());
    try testing.expect(!unknown.success);
}

test "sabr-loop: parseUrl splits SABR host and path" {
    var host: [256]u8 = undefined;
    var path: [9216]u8 = undefined;
    var hl: usize = 0;
    var pl: usize = 0;
    var port: u16 = 0;
    try testing.expect(parseUrl("https://rr5.googlevideo.com/videoplayback?sabr=1", &host, &hl, &path, &pl, &port));
    try testing.expectEqualSlices(u8, "rr5.googlevideo.com", host[0..hl]);
    try testing.expectEqualSlices(u8, "/videoplayback?sabr=1", path[0..pl]);
}

test "sabr-loop: two segments require two POSTs and echo buffered progress" {
    const Fake = struct {
        responses: [2][64]u8 = undefined,
        lengths: [2]usize = .{ 0, 0 },
        calls: usize = 0,
        acknowledged: bool = false,
        fn postImpl(ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult {
            _ = host; _ = port; _ = path;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.calls >= 2) return .{};
            if (self.calls == 1) {
                var r = @import("protobuf").Reader.init(body);
                while (!r.atEnd()) {
                    const tag = r.readTag() catch break;
                    if (tag.field == 3) self.acknowledged = true;
                    r.skipField(tag.wire) catch break;
                }
            }
            const n = self.lengths[self.calls];
            @memcpy(out[0..n], self.responses[self.calls][0..n]);
            self.calls += 1;
            return .{ .status = 200, .ok = true, .len = n };
        }
    };
    var fake = Fake{};
    for (0..2) |i| {
        var mh: [32]u8 = undefined;
        var mw = @import("protobuf").Writer.init(&mh);
        try mw.writeVarintField(3, 251);
        try mw.writeVarintField(9, i);
        try mw.writeVarintField(11, i * 1000);
        try mw.writeVarintField(12, 1000);
        try mw.writeVarintField(14, 3);
        var p = appendPart(&fake.responses[i], 0, ump.PartType.MEDIA_HEADER, mw.bytes());
        p = appendPart(&fake.responses[i], p, ump.PartType.MEDIA, if (i == 0) &.{ 0, 'A', 'B', 'C' } else &.{ 0, 'D', 'E', 'F' });
        fake.lengths[i] = appendPart(&fake.responses[i], p, ump.PartType.MEDIA_END, &.{0});
    }
    var mem = MemSink{};
    const res = runLoop(.{ .ctx = @ptrCast(&fake), .post = &Fake.postImpl }, "cdn.test", 443, "/videoplayback", .{ .itag = 251, .last_modified = 1, .content_length = 6 }, true, "", "", 1, "2.test", mem.sink());
    try testing.expect(res.success);
    try testing.expectEqual(@as(usize, 2), fake.calls);
    try testing.expect(fake.acknowledged);
    try testing.expectEqualSlices(u8, "ABCDEF", mem.buf[0..mem.len]);
}

test "sabr-loop: a truncated segment and unrelated track cannot complete" {
    var buf: [64]u8 = undefined;
    var mh: [16]u8 = undefined;
    var mw = @import("protobuf").Writer.init(&mh);
    try mw.writeVarintField(3, 140);
    try mw.writeVarintField(14, 6);
    var p = appendPart(&buf, 0, ump.PartType.MEDIA_HEADER, mw.bytes());
    p = appendPart(&buf, p, ump.PartType.MEDIA, &.{ 0, 'A', 'B', 'C' });
    p = appendPart(&buf, p, ump.PartType.MEDIA_END, &.{0});
    var mem = MemSink{};
    var unrelated = FormatProgress{ .itag = 251 };
    const ignored = processUmpBuffer(buf[0..p], mem.sink(), &unrelated).?;
    try testing.expect(!ignored.media_end);
    try testing.expectEqual(@as(usize, 0), mem.len);
    var selected = FormatProgress{ .itag = 140 };
    try testing.expect(processUmpBuffer(buf[0..p], mem.sink(), &selected) == null);
}

test "sabr-loop: transient retry preserves request body and sequence" {
    const Fake = struct {
        calls: usize = 0,
        body: [16384]u8 = undefined,
        body_len: usize = 0,
        same_request: bool = true,
        response: [64]u8 = undefined,
        response_len: usize = 0,
        fn post(ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult {
            _ = host; _ = port;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.same_request = self.same_request and std.mem.eql(u8, path, "/videoplayback?alr=no&rn=0");
            self.calls += 1;
            if (self.calls == 1) {
                @memcpy(self.body[0..body.len], body);
                self.body_len = body.len;
                return .{};
            }
            self.same_request = self.same_request and std.mem.eql(u8, self.body[0..self.body_len], body);
            @memcpy(out[0..self.response_len], self.response[0..self.response_len]);
            return .{ .ok = true, .status = 200, .len = self.response_len };
        }
    };
    var fake = Fake{};
    var mh: [16]u8 = undefined;
    var mw = @import("protobuf").Writer.init(&mh);
    try mw.writeVarintField(1, 200);
    try mw.writeVarintField(3, 251);
    try mw.writeVarintField(14, 3);
    var p = appendPart(&fake.response, 0, ump.PartType.MEDIA_HEADER, mw.bytes());
    p = appendPart(&fake.response, p, ump.PartType.MEDIA, &.{ 200, 'A', 'B', 'C' });
    // A high-bit header ID is one byte, not a protobuf/UMP varint.
    fake.response_len = appendPart(&fake.response, p, ump.PartType.MEDIA_END, &.{200});
    var mem = MemSink{};
    var profile = profiling.Profile{};
    profile.started_ns = profiling.clock(&profile);
    const res = runLoopWithOptions(.{ .ctx = @ptrCast(&fake), .post = &Fake.post }, "cdn.test", 443, "/videoplayback", .{ .itag = 251, .last_modified = 0, .content_length = 3 }, true, "", "", 1, "2.test", mem.sink(), .{ .retry_delay_ms = 0, .profile = &profile });
    try testing.expect(res.success);
    try testing.expectEqual(Failure.none, res.failure);
    try testing.expectEqual(@as(u32, 2), res.requests);
    try testing.expectEqual(@as(u32, 1), res.retries);
    try testing.expect(fake.same_request);
    try testing.expectEqualSlices(u8, "ABC", mem.buf[0..mem.len]);
    // Profiling includes the failed transport attempt without attributing
    // media to it, and preserves successful delivery/retry semantics.
    try testing.expectEqual(@as(u32, 2), profile.http_requests);
    try testing.expectEqual(@as(usize, 2), profile.sample_count);
    try testing.expectEqual(@as(u32, 0), profile.samples[0].status);
    try testing.expectEqual(@as(u64, 0), profile.samples[0].media_bytes);
    try testing.expectEqual(@as(u64, 3), profile.samples[1].media_bytes);
    try testing.expectEqual(@as(u64, fake.response_len), profile.response_bytes);
    try testing.expect(profile.ump_ns >= profile.sink_ns);
}

test "sabr-loop: permanent rejection is not retried; network retries are bounded" {
    const Fake = struct {
        calls: usize = 0,
        status: u32 = 403,
        fn post(ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult {
            _ = host; _ = port; _ = path; _ = body; _ = out;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return .{ .status = self.status };
        }
    };
    var fake = Fake{};
    var mem = MemSink{};
    const transport = Transport{ .ctx = @ptrCast(&fake), .post = &Fake.post };
    const rejected = runLoopWithOptions(transport, "cdn.test", 443, "/videoplayback", .{ .itag = 251, .last_modified = 0 }, true, "", "", 1, "2.test", mem.sink(), .{ .retry_delay_ms = 0 });
    try testing.expectEqual(Failure.http_status, rejected.failure);
    try testing.expectEqual(@as(usize, 1), fake.calls);
    fake = .{ .status = 0 };
    const failed = runLoopWithOptions(transport, "cdn.test", 443, "/videoplayback", .{ .itag = 251, .last_modified = 0 }, true, "", "", 1, "2.test", mem.sink(), .{ .max_transport_retries = 2, .retry_delay_ms = 0 });
    try testing.expectEqual(Failure.transport, failed.failure);
    try testing.expectEqual(@as(usize, 3), fake.calls);
    try testing.expectEqual(@as(u32, 2), failed.retries);
    try testing.expectEqual(@as(u64, 0), failed.bytes_written);
}

test "sabr-loop: cancellation during network retry stops before another POST" {
    const Fake = struct {
        calls: usize = 0,
        fn post(ctx: *anyopaque, host: []const u8, port: u16, path: []const u8, body: []const u8, out: []u8) PostResult {
            _ = host; _ = port; _ = path; _ = body; _ = out;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return .{};
        }
        fn cancel(_: SabrResult) bool { return false; }
    };
    var fake = Fake{};
    var mem = MemSink{};
    const res = runLoopWithOptions(.{ .ctx = @ptrCast(&fake), .post = &Fake.post }, "cdn.test", 443, "/videoplayback", .{ .itag = 251, .last_modified = 0 }, true, "", "", 1, "2.test", mem.sink(), .{ .on_response = &Fake.cancel, .retry_delay_ms = 0 });
    try testing.expectEqual(Failure.cancelled, res.failure);
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqual(@as(u32, 0), res.retries);
    try testing.expect(!res.success);
}
