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

// ── Win32 file sink (append writer) ──
extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(?*anyopaque) c_int;

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
    bytes_written: u64 = 0,
    last_status: u32 = 0,
    media_end: bool = false,
    sabr_error_code: i32 = 0,
    sabr_error_seen: bool = false,
    protection_status: i32 = 0, // last STREAM_PROTECTION_STATUS.status (0 if none)
    redirects: u16 = 0,
};

/// Per-format accumulation state updated while parsing UMP parts.
pub const FormatProgress = struct {
    itag: i32 = 0,
    bytes: u64 = 0,
    last_segment_num: i32 = -1,
    total_segments: i64 = 0,
    content_length: i64 = 0,
};

/// What a single UMP buffer pass reports back to the loop.
pub const ProcessOutcome = struct {
    media_end: bool = false,
    redirect_url: []const u8 = "", // non-empty => follow SABR_REDIRECT
    sabr_error_seen: bool = false,
    sabr_error_code: i32 = 0,
    protection_status: i32 = 0,
    backoff_time_ms: i32 = 0,
    media_bytes: u64 = 0, // media bytes appended this pass
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
    var result = SabrResult{};
    var progress = FormatProgress{ .itag = selected.itag };

    var host: []const u8 = host_in;
    var port_cur: u16 = port;
    var path: []const u8 = path_in;

    var state = ump.PartialState.init(&stitch_buf);
    var player_time_ms: i64 = 0;

    var iter: u16 = 0;
    while (iter < MAX_ITERATIONS) : (iter += 1) {
        // Build the request body for this round.
        const audio: []const request.SelectedFormat = if (is_audio) &.{selected} else &.{};
        const video: []const request.SelectedFormat = if (is_audio) &.{} else &.{selected};
        var body_buf: [8192]u8 = undefined;
        const params = request.AbrParams{
            .player_time_ms = player_time_ms,
            .audio_formats = audio,
            .video_formats = video,
            .ustreamer_config = ustreamer_config,
            .po_token = po_token,
            .client_name = client_name,
            .client_version = client_version,
            .enabled_track_types_bitfield = if (is_audio) 1 else 0,
        };
        const body_len = request.buildAbrRequest(params, &body_buf) catch return result;

        const r = transport.post(transport.ctx, host, port_cur, path, body_buf[0..body_len], &resp_buf);
        result.last_status = r.status;
        if (!r.ok or r.len == 0) {
            // No bytes / HTTP error: stop fail-closed.
            break;
        }

        const combined = state.combine(resp_buf[0..r.len]) orelse break;
        // Walk parts via the shared `applyPart` dispatch (same path as
        // processUmpBuffer) while keeping the reader cursor so a part split
        // across this and the next POST survives via state.carry(leftover).
        var pr = ump.PartReader.init(combined);
        var pass = ProcessOutcome{};
        var write_failed = false;
        while (pr.next()) |part| {
            applyPart(part, sink, &progress, &pass, &write_failed);
            if (write_failed) break;
        }
        if (write_failed) break;
        state.carry(pr.leftover());

        result.bytes_written = progress.bytes;
        if (pass.protection_status != 0) result.protection_status = pass.protection_status;
        player_time_ms += 5000; // advance ~one request window; refined by headers below

        if (pass.sabr_error_seen) {
            result.sabr_error_seen = true;
            result.sabr_error_code = pass.sabr_error_code;
            break;
        }
        if (pass.media_end) {
            result.media_end = true;
            result.success = progress.bytes > 0;
            break;
        }
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
        if (progress.total_segments > 0 and progress.last_segment_num + 1 >= @as(i32, @intCast(@min(progress.total_segments, 0x7FFFFFFF)))) {
            result.success = progress.bytes > 0;
            break;
        }
        if (selected_content_length(selected, progress) > 0 and progress.bytes >= @as(u64, @intCast(progress.content_length))) {
            result.success = progress.bytes > 0;
            break;
        }
        // No media and no control signal => nothing more to pull.
        if (pass.media_bytes == 0 and pass.backoff_time_ms == 0 and pass.redirect_url.len == 0) {
            result.success = progress.bytes > 0;
            break;
        }
    }

    return result;
}

var redirect_host: [256]u8 = undefined;
var redirect_path: [9216]u8 = undefined;

fn selected_content_length(selected: request.SelectedFormat, progress: FormatProgress) i64 {
    _ = selected;
    return progress.content_length;
}

/// Shared part dispatch used by both the offline `processUmpBuffer` and the
/// live loop (so they cannot diverge).
fn applyPart(part: ump.Part, sink: Sink, progress: *FormatProgress, pass: *ProcessOutcome, write_failed: *bool) void {
    switch (part.part_type) {
        ump.PartType.MEDIA_HEADER => {
            const mh = ump.decodeMediaHeader(part.payload);
            if (mh.itag != 0 and progress.itag == 0) progress.itag = mh.itag;
            if (mh.segment_num > progress.last_segment_num) progress.last_segment_num = mh.segment_num;
            if (mh.content_length > 0) progress.content_length = mh.content_length;
        },
        ump.PartType.MEDIA => {
            var hid: u32 = 0;
            const media = ump.mediaBytes(part.payload, &hid);
            if (media.len > 0) {
                if (!sink.write(sink.ctx, media)) {
                    write_failed.* = true;
                    return;
                }
                progress.bytes += media.len;
                pass.media_bytes += media.len;
            }
        },
        ump.PartType.MEDIA_END => pass.media_end = true,
        ump.PartType.FORMAT_INITIALIZATION_METADATA => {
            const fim = ump.decodeFormatInit(part.payload);
            if (fim.end_segment_num > 0) progress.total_segments = fim.end_segment_num;
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
        },
        ump.PartType.STREAM_PROTECTION_STATUS => {
            const sps = ump.decodeStreamProtectionStatus(part.payload);
            pass.protection_status = sps.status;
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

test "sabr-loop: runLoop pulls media via a fake transport and stops on MEDIA_END" {
    // A fake transport that serves one UMP response: MEDIA then MEDIA_END.
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
        .{ .itag = 251, .last_modified = 100 },
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
