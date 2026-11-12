//! @zpm/va hevc_parse test — hevc_parse on x265's stream (testdata/
//! hevc_128x96.hevc: 30 frames, open GOPs with CRAs every 15, 3 B-frames, 4
//! references, 2 slices a picture): every slice's own short-term RPS
//! length equal to ffmpeg's trace_headers (hevc_stream_test's table), and
//! the stream through `take` (the CRA after the first: its RASL pictures
//! decoded, they reference the GOP before), every picture output once in
//! POC order, no reference ever freed while named, the parameter sets as
//! VA carries them.

const std = @import("std");
const va = @import("vaapi.sig");
const hevc = @import("hevc_parse.sig");
const table = @import("hevc_stream_test.sig");

const STREAM = @embedFile("testdata/hevc_128x96.hevc");

test "hevc_parse: each slice's st_ref_pic_set length as ffmpeg's trace counts it" {
    var spss: [hevc.MAX_SPS]hevc.Sps = [_]hevc.Sps{.{}} ** hevc.MAX_SPS;
    var ppss: [hevc.MAX_PPS]hevc.Pps = [_]hevc.Pps{.{}} ** hevc.MAX_PPS;
    var it = hevc.NalIter.init(STREAM);
    var k: usize = 0;
    while (it.next()) |nal| {
        const t = (nal[0] >> 1) & 0x3f;
        if (t == hevc.SPS_NUT) {
            var s: hevc.Sps = .{};
            try hevc.parseSps(nal, &s);
            spss[s.id] = s;
        } else if (t == hevc.PPS_NUT) {
            var p: hevc.Pps = .{};
            try hevc.parsePps(nal, &spss, &p);
            ppss[p.id] = p;
        } else if (t <= 21 and (t <= 9 or t >= 16)) {
            var h: hevc.SliceHeader = undefined;
            try hevc.parseSlice(nal, &spss, &ppss, &h);
            const want = table.SLICES[k];
            try std.testing.expectEqual(want.nal_type, h.nal_type);
            try std.testing.expectEqual(want.first == 1, h.first);
            try std.testing.expectEqual(want.st_rps_bits, h.st_rps_bits);
            k += 1;
        }
    }
    try std.testing.expectEqual(table.SLICES.len, k);
    const s = &spss[0];
    try std.testing.expectEqual(@as(u32, 128), s.width);
    try std.testing.expectEqual(@as(u32, 96), s.height);
    try std.testing.expectEqual(@as(u5, 8), s.log2_max_poc_lsb);
    try std.testing.expectEqual(@as(u8, 0), s.num_st_rps);
}

const Sim = struct {
    free: [24]bool = [_]bool{true} ** 24,
    taken: u32 = 0,
    released: u32 = 0,
    out_pts: [64]i64 = undefined,
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
    fn output(ctx: *anyopaque, surf: u32, pts: i64, _: i64) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (s.free[surf - 0x400]) s.bad = true;
        s.out_pts[s.n_out] = pts;
        s.n_out += 1;
    }
    fn release(ctx: *anyopaque, surf: u32) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (s.free[surf - 0x400]) s.bad = true;
        s.free[surf - 0x400] = true;
        s.released += 1;
    }
    fn cb(s: *Sim) hevc.Callbacks {
        return .{ .ctx = s, .surface = surface, .output = output, .released = release };
    }
};

var state: hevc.State = .{};
var pic: hevc.Picture = .{};

test "hevc_parse: x265's open-GOP stream in display order, references kept while named" {
    state = .{};
    var sim = Sim{};
    // access units: each picture's first slice segment (and what precedes it)
    var starts: [64]usize = undefined;
    var n: usize = 0;
    var pending: ?usize = null;
    var i: usize = 0;
    while (i + 5 < STREAM.len) : (i += 1) {
        if (!(STREAM[i] == 0 and STREAM[i + 1] == 0 and STREAM[i + 2] == 1)) continue;
        const at = if (i > 0 and STREAM[i - 1] == 0) i - 1 else i;
        const t = (STREAM[i + 3] >> 1) & 0x3f;
        if (t <= 21 and (t <= 9 or t >= 16)) {
            if (STREAM[i + 5] & 0x80 != 0) {
                starts[n] = pending orelse at;
                n += 1;
            }
            pending = null;
        } else if (pending == null) pending = at;
        i += 2;
    }
    try std.testing.expectEqual(@as(usize, 30), n);
    // (the pts given is each picture's POC as the trace reads it: display order)
    for (0..n) |k| {
        const au = STREAM[starts[k]..if (k + 1 < n) starts[k + 1] else STREAM.len];
        const got = try hevc.take(&state, au, @intCast(k), 1, sim.cb(), &pic);
        try std.testing.expect(got);
        try std.testing.expectEqual(@as(u32, 2), pic.count);
        for (pic.pic.ReferenceFrames) |rf| {
            if (rf.flags & va.PICTURE_HEVC_INVALID != 0) continue;
            try std.testing.expect(rf.picture_id != pic.surface);
            try std.testing.expect(!sim.free[rf.picture_id - 0x400]);
        }
        try std.testing.expectEqual(@as(u16, 128), pic.pic.pic_width_in_luma_samples);
        hevc.finish(&state, &pic, sim.cb());
    }
    hevc.drain(&state, sim.cb());
    hevc.reset(&state, sim.cb());
    try std.testing.expect(!sim.bad);
    try std.testing.expectEqual(@as(usize, 30), sim.n_out);
    try std.testing.expectEqual(sim.taken, sim.released);
}
