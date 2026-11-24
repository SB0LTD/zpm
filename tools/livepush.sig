//! livepush: zpm's live path end to end on a host. An H.264 Annex B file
//! (access units delimited by AUD NAL units) and s16le 48 kHz stereo PCM
//! go out as one RTMP stream (zpm's aac, flv, rtmp), e.g. to ffmpeg's own
//! listener:
//!
//!   ffmpeg -listen 1 -i rtmp://127.0.0.1:1935/live/test -c copy got.flv &
//!   livepush VIDEO.h264 AUDIO.pcm FPS rtmp://127.0.0.1:1935/live/test
//!
//! Plain TCP only (rtmp://, an IPv4 address); no pacing: as fast as the
//! socket takes it.
//!
//!   sig build-exe -OReleaseSafe -target x86_64-linux-gnu --dep aac --dep flv
//!     --dep rtmp -Mroot=tools/livepush.sig -Maac=src/core/aac.sig
//!     -Mflv=src/live/flv.sig --dep flv -Mrtmp=src/live/rtmp.sig --name livepush
//!   ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30:duration=5 -c:v libx264
//!     -g 60 -bf 0 -x264-params aud=1 -f h264 v.h264
//!   ffmpeg -f lavfi -i sine=frequency=440:duration=5 -ac 2 -ar 48000 -f s16le a.pcm
//!
//! 2026-11-24: 150 pictures and 234 AAC frames into ffmpeg's listener; the
//! .flv it wrote probes as H.264 High 1280x720 30 fps + AAC LC 48 kHz
//! stereo, 5.0 s, and decodes without an error.
const std = @import("std");
const aac = @import("aac");
const flv = @import("flv");
const rtmp = @import("rtmp");
const linux = std.os.linux;

var enc: aac.Encoder = .{};
var pub_: rtmp.Publisher = undefined;
var video_bytes: [8 << 20]u8 = undefined;
var audio_samples: [32 << 20]i16 = undefined;
var body: [1 << 20]u8 = undefined;

const Tcp = struct {
    fd: i32,
    fn read(ctx: *anyopaque, buf: []u8) rtmp.IoError!usize {
        const t: *Tcp = @ptrCast(@alignCast(ctx));
        const r: isize = @bitCast(linux.read(t.fd, buf.ptr, buf.len));
        if (r < 0) return error.Io;
        return @intCast(r);
    }
    fn write(ctx: *anyopaque, data: []const u8) rtmp.IoError!void {
        const t: *Tcp = @ptrCast(@alignCast(ctx));
        var at: usize = 0;
        while (at < data.len) {
            const r: isize = @bitCast(linux.write(t.fd, data[at..].ptr, data.len - at));
            if (r <= 0) return error.Closed;
            at += @intCast(r);
        }
    }
    fn ready(ctx: *anyopaque) usize {
        const t: *Tcp = @ptrCast(@alignCast(ctx));
        var n: c_int = 0;
        if (linux.ioctl(t.fd, linux.T.FIONREAD, @intFromPtr(&n)) != 0) return 0;
        return @intCast(@max(n, 0));
    }
};

fn readFile(path: []const u8, out: []u8) ![]u8 {
    var z: [512]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd: isize = @bitCast(linux.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return error.Open;
    var got: usize = 0;
    while (got < out.len) {
        const r: isize = @bitCast(linux.read(@intCast(fd), out[got..].ptr, out.len - got));
        if (r <= 0) break;
        got += @intCast(r);
    }
    _ = linux.close(@intCast(fd));
    return out[0..got];
}

/// Where the access unit starting at `from` ends: the next AUD's start code.
fn auEnd(s: []const u8, from: usize) usize {
    var i = from + 4;
    while (i + 4 < s.len) : (i += 1) {
        if (s[i] == 0 and s[i + 1] == 0 and s[i + 2] == 1 and s[i + 3] & 0x1f == 9) {
            return if (i > 0 and s[i - 1] == 0) i - 1 else i;
        }
    }
    return s.len;
}

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const vpath = it.next() orelse return error.Usage;
    const apath = it.next() orelse return error.Usage;
    const fps = try std.fmt.parseInt(u32, it.next() orelse "30", 10);
    const url = rtmp.Url.parse(it.next() orelse return error.Usage) orelse return error.BadUrl;
    const video = try readFile(vpath, &video_bytes);
    const pcm_bytes = try readFile(apath, std.mem.sliceAsBytes(&audio_samples));
    const pcm = audio_samples[0 .. pcm_bytes.len / 4 * 2];

    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, url.host, '.');
    for (&ip) |*b| b.* = try std.fmt.parseInt(u8, parts.next() orelse return error.BadHost, 10);
    const fd: i32 = @intCast(@as(isize, @bitCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0))));
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, url.port), .addr = @bitCast(ip) };
    if (@as(isize, @bitCast(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) < 0) return error.Connect;
    var tcp = Tcp{ .fd = fd };
    pub_ = rtmp.Publisher.init(.{ .ctx = &tcp, .readFn = Tcp.read, .writeFn = Tcp.write, .readyFn = Tcp.ready });
    var random: [1528]u8 = undefined;
    for (&random, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    pub_.open(url.app, url.tc_url, url.key, &random) catch |e| {
        std.debug.print("livepush: open: {s} ({s})\n", .{ @errorName(e), pub_.statusCode() });
        return e;
    };
    std.debug.print("livepush: publishing, stream {d}\n", .{pub_.stream});

    try enc.init(.{ .sample_rate = 48_000, .channels = 2, .bit_rate = 160_000 });
    var avc = flv.Avc{};
    try pub_.data(try flv.metaData(.{ .width = 1280, .height = 720, .frame_rate = @floatFromInt(fps), .video_kbps = 4500, .audio_kbps = 160 }, true, &body));
    try pub_.audio(0, try flv.aacSequenceHeader(&enc.audioSpecificConfig(), &body));

    var vat: usize = 0;
    var vframe: u32 = 0;
    var aframe: u32 = 0;
    const aframes: u32 = @intCast(pcm.len / (aac.FRAME * 2));
    var frame: [aac.MAX_FRAME_BYTES]u8 = undefined;
    var sent_v: u32 = 0;
    var sent_a: u32 = 0;
    while (vat < video.len or aframe < aframes) {
        const vt: u64 = @as(u64, vframe) * 1000 / fps;
        const at: u64 = @as(u64, aframe) * aac.FRAME * 1000 / 48_000;
        if (vat < video.len and (aframe >= aframes or vt <= at)) {
            const end = auEnd(video, vat);
            const au = video[vat..end];
            vat = end;
            if (try avc.learn(au)) try pub_.video(@intCast(vt), try avc.sequenceHeader(&body));
            try pub_.video(@intCast(vt), try flv.videoPicture(au, flv.isKey(au), &body));
            vframe += 1;
            sent_v += 1;
        } else {
            const out = try enc.encode(pcm[aframe * aac.FRAME * 2 ..][0 .. aac.FRAME * 2], &frame);
            try pub_.audio(@intCast(at), try flv.aacFrame(out, &body));
            aframe += 1;
            sent_a += 1;
        }
        try pub_.service();
    }
    pub_.close(url.key);
    _ = linux.close(fd);
    std.debug.print("livepush: {d} pictures, {d} audio frames sent\n", .{ sent_v, sent_a });
}
