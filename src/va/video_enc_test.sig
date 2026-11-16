//! @zpm/va video_enc test — video_enc.Encoder through the driver on the
//! fake node: VP8 and VP9 on the encoders' CPU engine (the same kernels the
//! RTX's compute engine runs: a real bitstream), each frame's header read
//! back with vp8_read / vp9_read (the size, key frames where asked and
//! every `gop`), written as IVF to /tmp/galaxy-va-enc for WSL's ffmpeg; and
//! H.264's parameter sets written ahead of an IDR's slices (NVENC itself is
//! not pretended here: enc_test's pretend encoder covers the slices).

const std = @import("std");
const va = @import("vaapi.sig");
const node = @import("node.sig");
const driver = @import("driver.sig");
const video_enc = @import("video_enc.sig");
const vp8r = @import("vp8_read.sig");
const vp9r = @import("vp9_read.sig");
const h264 = @import("h264_parse.sig");
const enc_test = @import("enc_test.sig");

const Fake = node.Fake;
const D = driver.Driver(*Fake);
const W = 96;
const H = 64;

var enc: video_enc.Encoder(D) = undefined;
var pic: [W * H * 3 / 2]u8 = undefined;
var out: [256 << 10]u8 = undefined;
var ivf: [512 << 10]u8 = undefined;

fn frame(n: u32) void {
    for (0..H) |y| for (0..W) |x| {
        pic[y * W + x] = @truncate(x * 2 + y + n * 7);
    };
    for (0..H / 2) |y| for (0..W) |x| {
        pic[(H + y) * W + x] = @truncate(128 + x / 4 + n);
    };
}

fn ivfHeader(o: []u8, fourcc: *const [4]u8, frames: u32) usize {
    @memset(o[0..32], 0);
    @memcpy(o[0..4], "DKIF");
    std.mem.writeInt(u16, o[6..8], 32, .little);
    @memcpy(o[8..12], fourcc);
    std.mem.writeInt(u16, o[12..14], W, .little);
    std.mem.writeInt(u16, o[14..16], H, .little);
    std.mem.writeInt(u32, o[16..20], 30, .little);
    std.mem.writeInt(u32, o[20..24], 1, .little);
    std.mem.writeInt(u32, o[24..28], frames, .little);
    return 32;
}

fn run(codec: video_enc.Codec, comptime fourcc: *const [4]u8, path: [*:0]const u8) !void {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try std.testing.expectEqual(video_enc.Status.ok, enc.init(&d, .{ .codec = codec, .width = W, .height = H, .gop = 5, .qp = 30 }));
    defer enc.deinit();
    const N = 12;
    var n_ivf = ivfHeader(&ivf, fourcc, N);
    var st8 = vp8r.State{};
    var sizes9 = [_][2]u32{.{ 0, 0 }} ** 8;
    for (0..N) |n| {
        frame(@intCast(n));
        try std.testing.expectEqual(video_enc.Status.ok, enc.encode(&pic, W, @intCast(n * 100), 100, n == 7));
        var need: u32 = 0;
        const len = enc.take(&out, &need);
        try std.testing.expect(len > 0);
        try std.testing.expectEqual(need, @as(u32, @intCast(len)));
        const bytes = out[0..len];
        if (codec == .vp8) {
            var f: vp8r.Frame = .{};
            try vp8r.read(&st8, bytes, &f);
            try std.testing.expectEqual(@as(u32, W), f.width);
            try std.testing.expectEqual(@as(u32, H), f.height);
            // key frames: the first, every 5 since the last key, and the one asked for
            try std.testing.expectEqual(enc.key, f.key);
            vp8r.commit(&st8, &f, @intCast(0x400 + n % 2));
        } else {
            var h: vp9r.Header = .{};
            try vp9r.parse(bytes, &sizes9, 8, &h);
            try std.testing.expectEqual(enc.key, h.key);
            try std.testing.expectEqual(@as(u32, W), h.width);
            try std.testing.expectEqual(@as(u32, H), h.height);
            for (0..8) |s| {
                if (h.refresh & (@as(u8, 1) << @intCast(s)) != 0) sizes9[s] = .{ h.width, h.height };
            }
        }
        std.mem.writeInt(u32, ivf[n_ivf..][0..4], @intCast(len), .little);
        std.mem.writeInt(u64, ivf[n_ivf + 4 ..][0..8], n, .little);
        @memcpy(ivf[n_ivf + 12 ..][0..len], bytes);
        n_ivf += 12 + len;
    }
    enc_test.writeFile(path, ivf[0..n_ivf]);
}

test "video_enc: VP8, I then P, a key frame every 5 and one asked for; each frame's header read back" {
    try run(.vp8, "VP80", "/tmp/galaxy-va-enc/mf-vp8.ivf");
}

test "video_enc: VP9, the same" {
    try run(.vp9, "VP90", "/tmp/galaxy-va-enc/mf-vp9.ivf");
}

test "video_enc: H.264's IDR comes with an SPS and a PPS of the picture's size (High, 96x64)" {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try std.testing.expectEqual(video_enc.Status.ok, enc.init(&d, .{ .codec = .h264, .width = W, .height = H, .gop = 30, .profile = 100 }));
    defer enc.deinit();
    frame(0);
    try std.testing.expectEqual(video_enc.Status.ok, enc.encode(&pic, W, 0, 100, false));
    var need: u32 = 0;
    const len = enc.take(&out, &need);
    try std.testing.expect(len > 8);
    var it = h264.NalIter.init(out[0..len]);
    const sps_nal = it.next() orelse return error.NoSps;
    try std.testing.expectEqual(@as(u8, h264.NAL_SPS), sps_nal[0] & 0x1f);
    var sps: h264.Sps = .{};
    try h264.parseSps(sps_nal, &sps);
    try std.testing.expectEqual(@as(u32, W), sps.width());
    try std.testing.expectEqual(@as(u32, H), sps.height());
    try std.testing.expectEqual(@as(u8, 100), sps.profile_idc);
    const pps_nal = it.next() orelse return error.NoPps;
    try std.testing.expectEqual(@as(u8, h264.NAL_PPS), pps_nal[0] & 0x1f);
}
