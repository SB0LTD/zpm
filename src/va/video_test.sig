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
const VP9 = @embedFile("testdata/vp9_96x64.ivf");
const VP8 = @embedFile("testdata/vp8_96x64.ivf");
const HEVC = @embedFile("testdata/hevc_128x96.hevc");
const vp9r = @import("vp9_read.sig");
const vp8r = @import("vp8_read.sig");
var vp9_frames: u32 = 0;

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
    // (other codecs: decoded as they come, nothing painted)
    if (m[nvdec.SET_APPLICATION_ID >> 2] != nvdec.APPLICATION_ID_H264) {
        vp9_frames += 1;
        return;
    }
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

test "video: libvpx's VP9 stream (IVF) through the decoder: every frame decoded and shown in order" {
    var k = Fake{ .decoder = fakeDecode };
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try std.testing.expectEqual(video.Status.ok, dec.init(&d, .vp9));
    defer dec.deinit();
    vp9_frames = 0;
    var pos: usize = 32;
    var n: i64 = 0;
    var shown: i64 = 0;
    var buf: [96 * 64 * 3 / 2]u8 = undefined;
    while (pos + 12 <= VP9.len) {
        const sz = std.mem.readInt(u32, VP9[pos..][0..4], .little);
        const frame = VP9[pos + 12 ..][0..sz];
        pos += 12 + sz;
        while (true) {
            const st = dec.push(frame, n * 100, 100);
            if (st == .full) {
                const o = dec.next() orelse return error.FullButEmpty;
                try std.testing.expectEqual(shown * 100, o.pts);
                try std.testing.expect(dec.read(&buf, 96, .nv12));
                shown += 1;
                continue;
            }
            // (the driver's own parse of both headers agreed with VA's
            // lengths, or the decode would have failed)
            try std.testing.expectEqual(video.Status.ok, st);
            break;
        }
        n += 1;
        while (dec.next()) |o| {
            try std.testing.expectEqual(shown * 100, o.pts);
            try std.testing.expectEqual([4]u32{ 0, 0, 96, 64 }, o.visible);
            try std.testing.expect(dec.read(&buf, 96, .nv12));
            shown += 1;
        }
    }
    try std.testing.expectEqual(@as(i64, 30), n);
    try std.testing.expectEqual(@as(i64, 30), shown);
    try std.testing.expectEqual(@as(u32, 30), vp9_frames);
    try std.testing.expectEqual(@as(u64, 0), dec.errors);
}

test "video: libvpx's VP8 stream (IVF, four token partitions) through the decoder: every frame decoded and shown in order" {
    var k = Fake{ .decoder = fakeDecode };
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try std.testing.expectEqual(video.Status.ok, dec.init(&d, .vp8));
    defer dec.deinit();
    vp9_frames = 0;
    var pos: usize = 32;
    var n: i64 = 0;
    var shown: i64 = 0;
    var buf: [96 * 64 * 3 / 2]u8 = undefined;
    while (pos + 12 <= VP8.len) {
        const sz = std.mem.readInt(u32, VP8[pos..][0..4], .little);
        const frame = VP8[pos + 12 ..][0..sz];
        pos += 12 + sz;
        while (true) {
            const st = dec.push(frame, n * 100, 100);
            if (st == .full) {
                const o = dec.next() orelse return error.FullButEmpty;
                try std.testing.expectEqual(shown * 100, o.pts);
                try std.testing.expect(dec.read(&buf, 96, .nv12));
                shown += 1;
                continue;
            }
            // (the driver checked each DCT partition's size against the
            // frame's own table, or the decode would have failed)
            try std.testing.expectEqual(video.Status.ok, st);
            break;
        }
        n += 1;
        while (dec.next()) |o| {
            try std.testing.expectEqual(shown * 100, o.pts);
            try std.testing.expectEqual([4]u32{ 0, 0, 96, 64 }, o.visible);
            try std.testing.expect(dec.read(&buf, 96, .nv12));
            shown += 1;
        }
    }
    try std.testing.expectEqual(@as(i64, 30), n);
    try std.testing.expectEqual(@as(i64, 30), shown);
    try std.testing.expectEqual(@as(u32, 30), vp9_frames);
    try std.testing.expectEqual(@as(u64, 0), dec.errors);
}

test "video: VP8's frame headers: four DCT partitions in every frame (libvpx -slices 4), the key frame's size" {
    var st = vp8r.State{};
    var f: vp8r.Frame = .{};
    var pos: usize = 32;
    var n: u32 = 0;
    while (pos + 12 <= VP8.len) {
        const sz = std.mem.readInt(u32, VP8[pos..][0..4], .little);
        const frame = VP8[pos + 12 ..][0..sz];
        pos += 12 + sz;
        try vp8r.read(&st, frame, &f);
        try std.testing.expectEqual(@as(u8, 5), f.slice.num_of_partitions);
        try std.testing.expectEqual(@as(u32, 96), f.pic.frame_width);
        try std.testing.expectEqual(@as(u32, 64), f.pic.frame_height);
        try std.testing.expect(f.pic.loop_filter_level[0] <= 63);
        vp8r.commit(&st, &f, 0x400 + n % 4);
        n += 1;
    }
    try std.testing.expectEqual(@as(u32, 30), n);
}

test "video: a VP9 superframe's index splits it" {
    // two frames of 3 and 2 bytes, sizes in one byte each: marker 0b110_00_001
    const sf = [_]u8{ 1, 2, 3, 4, 5, 0xc1, 3, 2, 0xc1 };
    const f = vp9r.Frames.of(&sf);
    try std.testing.expectEqual(@as(u32, 2), f.n);
    try std.testing.expectEqual(@as(u32, 3), f.sizes[0]);
    try std.testing.expectEqual(@as(u32, 2), f.sizes[1]);
    const one = vp9r.Frames.of(sf[0..5]);
    try std.testing.expectEqual(@as(u32, 1), one.n);
}

test "video: x265's open-GOP HEVC stream through the decoder: 30 pictures out, each once" {
    var k = Fake{ .decoder = fakeDecode };
    var d: D = .{ .node = .{ .sys = &k } };
    try std.testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try std.testing.expectEqual(video.Status.ok, dec.init(&d, .hevc));
    defer dec.deinit();
    var starts: [64]usize = undefined;
    var n: usize = 0;
    var pending: ?usize = null;
    var i: usize = 0;
    while (i + 5 < HEVC.len) : (i += 1) {
        if (!(HEVC[i] == 0 and HEVC[i + 1] == 0 and HEVC[i + 2] == 1)) continue;
        const at_ = if (i > 0 and HEVC[i - 1] == 0) i - 1 else i;
        const t = (HEVC[i + 3] >> 1) & 0x3f;
        if (t <= 21 and (t <= 9 or t >= 16)) {
            if (HEVC[i + 5] & 0x80 != 0) {
                starts[n] = pending orelse at_;
                n += 1;
            }
            pending = null;
        } else if (pending == null) pending = at_;
        i += 2;
    }
    var buf: [128 * 96 * 3 / 2]u8 = undefined;
    var shown: u32 = 0;
    var seen = [_]bool{false} ** 30;
    var kk: usize = 0;
    while (kk < n) {
        const au = HEVC[starts[kk]..if (kk + 1 < n) starts[kk + 1] else HEVC.len];
        const st = dec.push(au, @intCast(kk), 1);
        if (st == .full) {
            const o = dec.next() orelse return error.FullButEmpty;
            seen[@intCast(o.pts)] = true;
            try std.testing.expect(dec.read(&buf, 128, .nv12));
            shown += 1;
            continue;
        }
        try std.testing.expectEqual(video.Status.ok, st);
        kk += 1;
        while (dec.next()) |o| {
            seen[@intCast(o.pts)] = true;
            try std.testing.expect(dec.read(&buf, 128, .nv12));
            shown += 1;
        }
    }
    try std.testing.expectEqual(video.Status.ok, dec.drain());
    while (dec.next()) |o| {
        seen[@intCast(o.pts)] = true;
        try std.testing.expect(dec.read(&buf, 128, .nv12));
        shown += 1;
    }
    try std.testing.expectEqual(@as(u32, 30), shown);
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expectEqual(@as(u64, 30), dec.decoded);
    try std.testing.expectEqual(@as(u64, 0), dec.errors);
}
