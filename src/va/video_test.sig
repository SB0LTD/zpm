//! @zpm/va video test — video.Decoder on the driver over the fake node,
//! fed x264's High-profile stream (testdata/h264_high.h264, 80 frames,
//! B-pyramid) one access unit at a time, as Media Foundation's decoder
//! hands them over: every picture goes through Begin/Render/EndPicture
//! (the pretend decoder fills the target's luma with the picture's order
//! count / 2), and comes back in display order through the caller's
//! memory in NV12 and YV12, cropped to the visible 96x64, each with the
//! timestamp its access unit came with; pushes that find no free surface
//! say `.full` until a picture is read.

const std = @import("std");
const va = @import("vaapi.sig");
const node = @import("node.sig");
const nvdec = @import("nvdec.sig");
const driver = @import("driver.sig");
const video = @import("video.sig");

const Fake = node.Fake;
const D = driver.Driver(*Fake);
const HIGH = @embedFile("testdata/h264_high.h264");

fn at(k: *Fake, m: []const u32, method: u32, len: usize) []u8 {
    return k.at(@as(u64, m[method >> 2]) << 8, len).?;
}

/// The pretend decoder: the target's luma plane all POC / 2, chroma 128.
fn fakeDecode(k: *Fake, sub: Fake.Submit) void {
    const push = k.push(sub);
    var m = [_]u32{0} ** (0x600 / 4);
    var i: usize = 0;
    while (i < push.len) {
        const h = push[i];
        const method = h & 0x1fff;
        const count = (h >> 16) & 0x1fff;
        for (0..count) |j| m[method + j] = push[i + 1 + j];
        i += 1 + count;
    }
    if (m[nvdec.SET_DRV_PIC_SETUP_OFFSET >> 2] == 0) return;
    const pic = std.mem.bytesToValue(nvdec.H264Pic, at(k, &m, nvdec.SET_DRV_PIC_SETUP_OFFSET, @sizeOf(nvdec.H264Pic)));
    const cur: u32 = pic.current.CurrPicIdx;
    const hgt: u32 = @intCast(pic.FrameHeightInMbs * 16);
    const luma = at(k, &m, nvdec.SET_PICTURE_LUMA_OFFSET0 + 4 * cur, pic.pitch_luma * hgt);
    const chroma = at(k, &m, nvdec.SET_PICTURE_CHROMA_OFFSET0 + 4 * cur, pic.pitch_chroma * hgt / 2);
    @memset(luma, @truncate(@as(u32, @bitCast(pic.CurrFieldOrderCnt[0])) / 2));
    @memset(chroma, 128);
    const st = at(k, &m, nvdec.SET_NVDEC_STATUS_OFFSET, @sizeOf(nvdec.Status));
    std.mem.writeInt(u32, st[0..4], (pic.pitch_luma / 16) * (hgt / 16), .little);
}

fn accessUnits(data: []const u8, out: [][]const u8) usize {
    var starts: [512]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    var pending: ?usize = null;
    while (i + 3 < data.len) : (i += 1) {
        if (!(data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1)) continue;
        const at_ = if (i > 0 and data[i - 1] == 0) i - 1 else i;
        const t = data[i + 3] & 0x1f;
        if (t == 1 or t == 5) {
            if (data[i + 4] & 0x80 != 0) {
                starts[n] = pending orelse at_;
                n += 1;
            }
            pending = null;
        } else if (pending == null) pending = at_;
        i += 2;
    }
    for (0..n) |k| out[k] = data[starts[k]..if (k + 1 < n) starts[k + 1] else data.len];
    return n;
}

var dec: video.Decoder(D) = undefined;

test "video: x264's High stream through the decoder, pictures out in display order" {
    var k = Fake{ .decoder = fakeDecode };
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try std.testing.expectEqual(video.Status.ok, dec.init(&d, .h264));
    defer dec.deinit();
    var aus: [128][]const u8 = undefined;
    const n = accessUnits(HIGH, &aus);
    try std.testing.expectEqual(@as(usize, 80), n);
    var buf: [96 * 64 * 3 / 2]u8 = undefined;
    var got: u32 = 0;
    var fulls: u32 = 0;
    var pts_sum: i64 = 0;
    var k_au: usize = 0;
    // (a caller that reads one picture per push, as an MFT's ProcessOutput does)
    while (k_au < n) {
        const st = dec.push(aus[k_au], @intCast(k_au * 100), 100);
        if (st == .full) {
            fulls += 1;
            const o = dec.next() orelse return error.FullButEmpty;
            pts_sum += o.pts;
            try std.testing.expect(dec.read(&buf, 96, .nv12));
            try std.testing.expectEqual(@as(u8, @intCast(got % 40)), buf[0]);
            try std.testing.expectEqual(@as(u8, @intCast(got % 40)), buf[96 * 64 - 1]);
            try std.testing.expectEqual(@as(u8, 128), buf[96 * 64]);
            got += 1;
            continue;
        }
        try std.testing.expectEqual(video.Status.ok, st);
        k_au += 1;
        if (dec.next()) |o| {
            // (pts went in decode order; each picture keeps its own)
            pts_sum += o.pts;
            try std.testing.expectEqual([4]u32{ 0, 0, 96, 64 }, o.visible);
            var y: [96 * 64 + 2 * 48 * 32]u8 = undefined;
            try std.testing.expect(dec.read(&y, 96, .yv12));
            try std.testing.expectEqual(@as(u8, @intCast(got % 40)), y[50]);
            try std.testing.expectEqual(@as(u8, 128), y[96 * 64 + 5]);
            got += 1;
        }
    }
    try std.testing.expectEqual(video.Status.ok, dec.drain());
    while (dec.next()) |o| {
        pts_sum += o.pts;
        try std.testing.expect(dec.read(&buf, 96, .nv12));
        try std.testing.expectEqual(@as(u8, @intCast(got % 40)), buf[0]);
        got += 1;
    }
    try std.testing.expectEqual(@as(u32, 80), got);
    try std.testing.expectEqual(@as(i64, 100 * 79 * 80 / 2), pts_sum);
    try std.testing.expectEqual(@as(u64, 80), dec.decoded);
    try std.testing.expectEqual(@as(u64, 0), dec.errors);
}

test "video: no decoder in the GPU, no Decoder (the driver refuses at init)" {
    var k = Fake{ .has_decoder = false };
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expect(d.init(3, .{}) != va.SUCCESS);
}
