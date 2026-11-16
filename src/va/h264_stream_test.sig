//! @zpm/va h264 stream test — h264_parse on x264's real streams
//! (testdata/h264_high.h264: High profile, 96x64, 80 frames, IDR every 40,
//! two B-frames with B-pyramid, so references marked by MMCO and the POC
//! LSB wrapping at 64 inside a GOP; testdata/h264_base.h264: Baseline, POC
//! type 2, 20 frames): parameter sets as ffmpeg's trace_headers reads
//! them, every picture decoded once and output once in display order (POC
//! rising in each IDR period, as ffmpeg's decoder outputs them), the DPB
//! never holding more references than the SPS allows, no reference ever
//! the picture being decoded or a surface already given back, and every
//! surface given back at the end.

const std = @import("std");
const va = @import("vaapi.sig");
const h264 = @import("h264_parse.sig");

const HIGH = @embedFile("testdata/h264_high.h264");
const BASE = @embedFile("testdata/h264_base.h264");

/// The stream cut into access units as a demuxer hands them over (each
/// picture's first slice, with the parameter sets and SEI before it).
fn accessUnits(data: []const u8, out: [][]const u8) usize {
    var starts: [512]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    var pending: ?usize = null; // the first non-VCL NAL since the last VCL one
    while (i + 3 < data.len) : (i += 1) {
        if (!(data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1)) continue;
        const at = if (i > 0 and data[i - 1] == 0) i - 1 else i;
        const t = data[i + 3] & 0x1f;
        if (t == 1 or t == 5) {
            // first_mb_in_slice == 0: ue(v) of value 0 is the bit '1'
            const first = data[i + 4] & 0x80 != 0;
            if (first) {
                starts[n] = pending orelse at;
                n += 1;
            }
            pending = null;
        } else if (pending == null) {
            pending = at;
        }
        i += 2;
    }
    for (0..n) |k| {
        const e = if (k + 1 < n) starts[k + 1] else data.len;
        out[k] = data[starts[k]..e];
    }
    return n;
}

const Sim = struct {
    free: [24]bool = [_]bool{true} ** 24,
    taken: u32 = 0,
    n_released: u32 = 0,
    outputs: [256]i32 = undefined,
    out_surface: [256]u32 = undefined,
    n_out: usize = 0,
    bad: bool = false,

    fn surface(ctx: *anyopaque) ?u32 {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        for (&s.free, 0..) |*f, i| if (f.*) {
            f.* = false;
            s.taken += 1;
            return @intCast(0x400 + i);
        };
        return null;
    }
    fn output(ctx: *anyopaque, p: *const h264.Pic) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (s.free[p.surface - 0x400]) s.bad = true;
        s.outputs[s.n_out] = p.poc();
        s.out_surface[s.n_out] = p.surface;
        s.n_out += 1;
    }
    fn released(ctx: *anyopaque, surface_: u32) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (s.free[surface_ - 0x400]) s.bad = true;
        s.free[surface_ - 0x400] = true;
        s.n_released += 1;
    }
    fn cb(s: *Sim) h264.Callbacks {
        return .{ .ctx = s, .surface = surface, .output = output, .released = released };
    }
};

var state: h264.State = .{};
var pic: h264.Picture = .{};

fn run(data: []const u8, sim: *Sim) !usize {
    state = .{};
    var aus: [256][]const u8 = undefined;
    const n = accessUnits(data, &aus);
    var pts: i64 = 0;
    for (aus[0..n]) |au| {
        const got = try h264.take(&state, au, pts, 1, sim.cb(), &pic);
        try std.testing.expect(got);
        pts += 1;
        // the picture's references: live surfaces, never its own, at most num_ref_frames
        var refs: u32 = 0;
        for (pic.pic.ReferenceFrames) |rf| {
            if (rf.flags & va.PICTURE_H264_INVALID != 0) continue;
            refs += 1;
            try std.testing.expect(rf.picture_id != pic.surface);
            try std.testing.expect(!sim.free[rf.picture_id - 0x400]);
        }
        try std.testing.expect(refs <= state.activeSps().?.num_ref_frames);
        // a B slice's lists name pictures on both sides of it
        if (pic.slices[0].slice_type == 1) {
            try std.testing.expect(pic.slices[0].RefPicList0[0].flags & va.PICTURE_H264_INVALID == 0);
            try std.testing.expect(pic.slices[0].RefPicList1[0].flags & va.PICTURE_H264_INVALID == 0);
            const cur = @min(pic.pic.CurrPic.TopFieldOrderCnt, pic.pic.CurrPic.BottomFieldOrderCnt);
            try std.testing.expect(pic.slices[0].RefPicList0[0].TopFieldOrderCnt < cur);
            try std.testing.expect(pic.slices[0].RefPicList1[0].TopFieldOrderCnt > cur);
        }
        for (pic.slices[0..pic.count]) |s| try std.testing.expectEqual(@as(u32, 0), s.slice_data_offset);
        h264.finish(&state, &pic, sim.cb());
    }
    h264.drain(&state, sim.cb());
    h264.reset(&state, sim.cb());
    return n;
}

test "h264: x264 High with B-pyramid: parameter sets, POC across the LSB wrap, MMCO, display order" {
    var sim = Sim{};
    const n = try run(HIGH, &sim);
    try std.testing.expectEqual(@as(usize, 80), n);
    try std.testing.expect(!sim.bad);
    const sps = state.activeSps().?;
    try std.testing.expectEqual(@as(u8, 100), sps.profile_idc);
    try std.testing.expectEqual(@as(u32, 96), sps.width());
    try std.testing.expectEqual(@as(u32, 64), sps.height());
    try std.testing.expectEqual(@as(u8, 4), sps.num_ref_frames);
    try std.testing.expectEqual(@as(?u8, 2), sps.reorder);
    try std.testing.expectEqual(@as(u32, 4), sps.dpbFrames());
    try std.testing.expectEqual(@as(u5, 6), sps.log2_max_poc_lsb);
    try std.testing.expect(state.pps[0].transform_8x8_mode);
    try std.testing.expect(state.pps[0].entropy_coding_mode);
    // every picture out once, in display order: POC 0, 2, 4 ... 78 in each GOP
    try std.testing.expectEqual(@as(usize, 80), sim.n_out);
    for (0..80) |k| try std.testing.expectEqual(@as(i32, @intCast((k % 40) * 2)), sim.outputs[k]);
    try std.testing.expectEqual(sim.taken, sim.n_released);
    // the picture parameters as FFmpeg's vaapi_h264 fills them
    try std.testing.expectEqual(@as(u16, 5), pic.pic.picture_width_in_mbs_minus1);
    try std.testing.expectEqual(@as(u16, 3), pic.pic.picture_height_in_mbs_minus1);
    try std.testing.expectEqual(@as(u1, 1), pic.pic.seq_fields.frame_mbs_only_flag);
    try std.testing.expectEqual(@as(u1, 1), pic.pic.seq_fields.direct_8x8_inference_flag);
    try std.testing.expectEqual(@as(u4, 2), pic.pic.seq_fields.log2_max_pic_order_cnt_lsb_minus4);
    try std.testing.expectEqual(@as(u1, 1), pic.pic.pic_fields.entropy_coding_mode_flag);
    try std.testing.expectEqual(@as(u1, 1), pic.pic.pic_fields.transform_8x8_mode_flag);
    // (no scaling matrix in the stream: flat lists)
    try std.testing.expectEqual(@as(u8, 16), pic.iq.ScalingList4x4[5][15]);
    try std.testing.expectEqual(@as(u8, 16), pic.iq.ScalingList8x8[1][63]);
}

test "h264: x264 Baseline (POC type 2, no reordering): output as decoded" {
    var sim = Sim{};
    const n = try run(BASE, &sim);
    try std.testing.expectEqual(@as(usize, 20), n);
    try std.testing.expect(!sim.bad);
    const sps = state.activeSps().?;
    try std.testing.expectEqual(@as(u8, 66), sps.profile_idc);
    try std.testing.expectEqual(@as(u2, 2), sps.poc_type);
    try std.testing.expectEqual(@as(u32, 0), sps.reorderDepth());
    try std.testing.expectEqual(@as(usize, 20), sim.n_out);
    for (0..20) |k| try std.testing.expectEqual(@as(i32, @intCast((k % 10) * 2)), sim.outputs[k]);
    try std.testing.expectEqual(sim.taken, sim.n_released);
}

test "h264: scaling lists fall back as Table 7-2 says" {
    // An SPS of High profile with seq_scaling_matrix_present_flag and only
    // list 0 sent (all 16: delta 0 after 16 -> flat 16 ... but list 1 not
    // present: falls back to list 0; list 3 not present: Default_4x4_Inter).
    var s = h264.Scaling{};
    var bits = [_]u8{0} ** 64;
    // present flags: 1 then ues for list0 (delta 8 then zeros = all 16), then 0 x7
    // se(8) = ue(15) = 0001 0000; then 15 x se(0)='1'; then flags 0000000
    const pattern = "1" ++ "000010000" ++ "111111111111111" ++ "0000000";
    var k: usize = 0;
    for (pattern) |c| {
        if (c == '1') bits[k / 8] |= @as(u8, 0x80) >> @intCast(k % 8);
        k += 1;
    }
    bits[k / 8] |= @as(u8, 0x80) >> @intCast(k % 8); // stop bit
    var r = @import("enc_parse.sig").Reader.init(&bits);
    readScalingForTest(&r, &s);
    try std.testing.expectEqual(@as(u8, 16), s.l4[0][0]);
    try std.testing.expectEqual(@as(u8, 16), s.l4[1][7]); // from list 0
    try std.testing.expectEqual(@as(u8, 10), s.l4[3][0]); // Default_4x4_Inter
    try std.testing.expectEqual(@as(u8, 6), s.l8[0][0]); // Default_8x8_Intra
}

fn readScalingForTest(r: anytype, s: *h264.Scaling) void {
    h264.testReadScaling(r, s);
}
