// @zpm/youtube/sabr/request — VideoPlaybackAbrRequest protobuf builder
//
// Encodes the request body a SABR `POST .../videoplayback?...&sabr=1` carries.
// All field numbers are from the googlevideo protos (proto2):
//
//   VideoPlaybackAbrRequest (video_playback_abr_request.proto):
//     1  client_abr_state            (ClientAbrState)
//     3  buffered_ranges             (repeated BufferedRange)
//     5  video_playback_ustreamer_config (bytes)
//     16 selected_audio_format_ids   (repeated misc.FormatId)
//     17 selected_video_format_ids   (repeated misc.FormatId)
//     19 streamer_context            (StreamerContext)
//
//   ClientAbrState (client_abr_state.proto):
//     13 time_since_last_manual_format_selection_ms (int64)
//     23 bandwidth_estimate          (int64)
//     28 player_time_ms              (int64)
//     40 enabled_track_types_bitfield (int32)
//
//   misc.FormatId (misc/common.proto):
//     1 itag (int32), 2 last_modified (uint64), 3 xtags (string)
//
//   BufferedRange (buffered_range.proto):
//     1 format_id (FormatId), 2 start_time_ms, 3 duration_ms,
//     4 start_segment_index, 5 end_segment_index
//
//   StreamerContext (streamer_context.proto):
//     1 client_info (ClientInfo), 2 po_token (bytes)
//   StreamerContext.ClientInfo:
//     16 client_name (int32), 17 client_version (string)
//
// Zero allocation: everything encodes into the caller's `out` buffer via the
// @zpm/core/protobuf Writer, with small fixed stack scratch for nested messages.

const pb = @import("protobuf");

/// A selected adaptive format, identified by (itag, lastModified) — SABR keys
/// formats by this pair, not by URL.
pub const SelectedFormat = struct {
    itag: i32,
    last_modified: u64,
    xtags: []const u8 = "",
};

/// A client buffered range (what we already have on disk for a format).
pub const BufferedRange = struct {
    itag: i32,
    last_modified: u64,
    start_time_ms: i64,
    duration_ms: i64,
    start_segment_index: i32,
    end_segment_index: i32,
};

/// Inputs to the request builder.
pub const AbrParams = struct {
    // ClientAbrState
    player_time_ms: i64 = 0,
    bandwidth_estimate: i64 = 0,
    last_manual_format_selection_ms: i64 = 0,
    enabled_track_types_bitfield: i32 = 0,

    // Selected formats (audio and/or video). Empty slice => field omitted.
    audio_formats: []const SelectedFormat = &.{},
    video_formats: []const SelectedFormat = &.{},

    // Already-buffered ranges (empty on the first request).
    buffered: []const BufferedRange = &.{},

    // Raw ustreamer config bytes (base64-decoded by the caller before passing).
    ustreamer_config: []const u8 = "",

    // Content-bound PO token bytes (base64url-decoded by the caller).
    po_token: []const u8 = "",

    // StreamerContext.ClientInfo
    client_name: i32 = 1, // WEB
    client_version: []const u8 = "",
};

/// Encode a misc.FormatId into `w` as a length-delimited field `field_no`.
fn writeFormatId(w: *pb.Writer, field_no: u32, fmt: SelectedFormat) pb.Error!void {
    var scratch: [64]u8 = undefined;
    var fw = pb.Writer.init(&scratch);
    try fw.writeVarintField(1, @as(u64, @bitCast(@as(i64, fmt.itag))));
    try fw.writeVarintField(2, fmt.last_modified);
    if (fmt.xtags.len > 0) try fw.writeLenDelim(3, fmt.xtags);
    try w.writeLenDelim(field_no, fw.bytes());
}

/// Encode a ClientAbrState message into `scratch`, return the encoded slice.
fn encodeClientAbrState(p: AbrParams, scratch: []u8) pb.Error![]const u8 {
    var w = pb.Writer.init(scratch);
    if (p.last_manual_format_selection_ms != 0)
        try w.writeVarintField(13, @bitCast(p.last_manual_format_selection_ms));
    if (p.bandwidth_estimate != 0)
        try w.writeVarintField(23, @bitCast(p.bandwidth_estimate));
    try w.writeVarintField(28, @bitCast(p.player_time_ms));
    if (p.enabled_track_types_bitfield != 0)
        try w.writeVarintField(40, @as(u64, @bitCast(@as(i64, p.enabled_track_types_bitfield))));
    return w.bytes();
}

/// Encode a BufferedRange into `scratch`, return the encoded slice.
fn encodeBufferedRange(br: BufferedRange, scratch: []u8) pb.Error![]const u8 {
    var w = pb.Writer.init(scratch);
    try writeFormatId(&w, 1, .{ .itag = br.itag, .last_modified = br.last_modified });
    try w.writeVarintField(2, @bitCast(br.start_time_ms));
    try w.writeVarintField(3, @bitCast(br.duration_ms));
    try w.writeVarintField(4, @as(u64, @bitCast(@as(i64, br.start_segment_index))));
    try w.writeVarintField(5, @as(u64, @bitCast(@as(i64, br.end_segment_index))));
    return w.bytes();
}

/// Encode a StreamerContext into `scratch`, return the encoded slice.
fn encodeStreamerContext(p: AbrParams, scratch: []u8) pb.Error![]const u8 {
    var w = pb.Writer.init(scratch);
    // client_info (field 1)
    var ci_scratch: [128]u8 = undefined;
    var ci = pb.Writer.init(&ci_scratch);
    try ci.writeVarintField(16, @as(u64, @bitCast(@as(i64, p.client_name))));
    if (p.client_version.len > 0) try ci.writeLenDelim(17, p.client_version);
    try w.writeLenDelim(1, ci.bytes());
    // po_token (field 2)
    if (p.po_token.len > 0) try w.writeLenDelim(2, p.po_token);
    return w.bytes();
}

/// Build a VideoPlaybackAbrRequest into `out`. Returns bytes written.
pub fn buildAbrRequest(p: AbrParams, out: []u8) pb.Error!usize {
    var w = pb.Writer.init(out);

    // field 1: client_abr_state
    var abr_scratch: [128]u8 = undefined;
    const abr = try encodeClientAbrState(p, &abr_scratch);
    try w.writeLenDelim(1, abr);

    // field 3: buffered_ranges (repeated)
    for (p.buffered) |br| {
        var br_scratch: [128]u8 = undefined;
        const enc = try encodeBufferedRange(br, &br_scratch);
        try w.writeLenDelim(3, enc);
    }

    // field 5: video_playback_ustreamer_config
    if (p.ustreamer_config.len > 0) try w.writeLenDelim(5, p.ustreamer_config);

    // field 16: selected_audio_format_ids (repeated)
    for (p.audio_formats) |fmt| try writeFormatId(&w, 16, fmt);

    // field 17: selected_video_format_ids (repeated)
    for (p.video_formats) |fmt| try writeFormatId(&w, 17, fmt);

    // field 19: streamer_context
    var sc_scratch: [1024]u8 = undefined;
    const sc = try encodeStreamerContext(p, &sc_scratch);
    try w.writeLenDelim(19, sc);

    return w.pos;
}

// ── Tests (inline, std.testing) ──

const std = @import("std");
const testing = std.testing;

test "sabr-request: encodes selected audio format id round-trip" {
    const p = AbrParams{
        .player_time_ms = 0,
        .audio_formats = &.{.{ .itag = 251, .last_modified = 1700000000000000 }},
        .po_token = "POTOKEN",
        .client_name = 1,
        .client_version = "2.2025",
    };
    var out: [512]u8 = undefined;
    const n = try buildAbrRequest(p, &out);
    try testing.expect(n > 0);

    // Decode top-level and recover the selected audio format id (field 16).
    var r = pb.Reader.init(out[0..n]);
    var found_itag: i32 = 0;
    var found_lmt: u64 = 0;
    var found_pot = false;
    while (!r.atEnd()) {
        const tag = try r.readTag();
        if (tag.field == 16) {
            const fp = try r.readLenDelim();
            var fr = pb.Reader.init(fp);
            while (!fr.atEnd()) {
                const ftag = try fr.readTag();
                switch (ftag.field) {
                    1 => found_itag = @truncate(@as(i64, @bitCast(try fr.readVarint()))),
                    2 => found_lmt = try fr.readVarint(),
                    else => try fr.skipField(ftag.wire),
                }
            }
        } else if (tag.field == 19) {
            const sc = try r.readLenDelim();
            var sr = pb.Reader.init(sc);
            while (!sr.atEnd()) {
                const stag = try sr.readTag();
                if (stag.field == 2) {
                    const pot = try sr.readLenDelim();
                    found_pot = std.mem.eql(u8, pot, "POTOKEN");
                } else try sr.skipField(stag.wire);
            }
        } else try r.skipField(tag.wire);
    }
    try testing.expectEqual(@as(i32, 251), found_itag);
    try testing.expectEqual(@as(u64, 1700000000000000), found_lmt);
    try testing.expect(found_pot);
}

test "sabr-request: golden bytes for a minimal request" {
    // Minimal params: player_time_ms=0 only in client_abr_state, one audio
    // format (itag=140, lmt=5), client_name=1, no pot/ustreamer/version.
    const p = AbrParams{
        .player_time_ms = 0,
        .audio_formats = &.{.{ .itag = 140, .last_modified = 5 }},
        .client_name = 1,
    };
    var out: [256]u8 = undefined;
    const n = try buildAbrRequest(p, &out);

    // Hand-computed golden:
    //   field1 client_abr_state (LEN): tag 0x0A, len 0x02, body [player_time_ms(28)=0]
    //     28<<3|0 = 224 -> varint E0 01 ; value 0 -> 00  => body = E0 01 00 (len 3)
    //   field16 audio fmt (LEN): tag 16<<3|2=130 -> varint 82 01 ; len ; body
    //     FormatId: itag(1)=140 -> 08 8C 01 ; last_modified(2)=5 -> 10 05
    //       body = 08 8C 01 10 05 (len 5)
    //   field19 streamer_context (LEN): tag 19<<3|2=154 -> 9A 01 ; len ; body
    //     client_info(1) LEN: tag 0A ; body client_name(16)=1 -> 80 01 01 (len 3)
    //       -> 0A 03 80 01 01 (len 5)
    //     body = 0A 03 80 01 01 (len 5)
    const golden = [_]u8{
        // field1 client_abr_state
        0x0A, 0x03, 0xE0, 0x01, 0x00,
        // field16 selected_audio_format_ids
        0x82, 0x01, 0x05, 0x08, 0x8C, 0x01, 0x10, 0x05,
        // field19 streamer_context
        0x9A, 0x01, 0x05, 0x0A, 0x03, 0x80, 0x01, 0x01,
    };
    try testing.expectEqualSlices(u8, &golden, out[0..n]);
}
