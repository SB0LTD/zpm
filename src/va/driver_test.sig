//! @zpm/va driver tests — the driver over a fake node (node.Fake) whose
//! pretend decoder reads each pushbuffer as NVDEC would and writes a
//! pattern into the target, block linear: profiles and Firefox's probe,
//! init's refusals, and Begin/Render/End/Sync with the submitted words,
//! the bitstream, the reference slots, the linear picture, the export and
//! the images checked. Encoding: the attributes FFmpeg asks, configs, and
//! whole encodes through a pretend encoder that reads the setup and the
//! block-linear input as NVENC would and writes a real H.264 slice of
//! I_PCM macroblocks (the input's samples, losslessly), so the stream the
//! driver hands back decodes to the picture put in: the test writes it to
//! /tmp/galaxy-va-enc/ for WSL's ffmpeg to check.

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const tiling = @import("tiling.sig");
const node = @import("node.sig");
const driver = @import("driver.sig");
const hevc = @import("hevc.sig");
const ve = @import("vaapi_enc.sig");
const nvenc = @import("nvenc.sig");
const enc_h264 = @import("enc_h264.sig");
const enc_hevc = @import("enc_hevc.sig");
const encode = @import("encode.sig");
const bits = @import("bits.sig");
const convert = @import("convert.sig");
const linux = std.os.linux;

const testing = std.testing;
const Fake = node.Fake;
const TestDriver = driver.Driver(*Fake);
const SURFACE_BASE = driver.SURFACE_BASE;
const CONTEXT_BASE = driver.CONTEXT_BASE;
const SYNC_NS = driver.SYNC_NS;

/// What the pretend decoder saw of the last frame.
const Seen = struct {
    methods: [0x600 / 4]u32 = [_]u32{0} ** (0x600 / 4),
    dwords: u32 = 0,
    pic: nvdec.H264Pic = .{},
    hevc: hevc.HevcPic = .{},
    stream: [64]u8 = [_]u8{0} ** 64,
    slices: [4]u32 = .{ 0, 0, 0, 0 },
    frames: u32 = 0,
};
var seen: Seen = .{};

fn pattern(x: usize, y: usize, n: u32) u8 {
    return @truncate(x * 3 + y * 5 + n * 17);
}

/// The bytes behind the address method `method` was given.
fn at(k: *Fake, m: []const u32, method: u32, len: usize) []u8 {
    return k.at(@as(u64, m[method >> 2]) << 8, len).?;
}

/// The pretend decoder: reads the pushbuffer's methods, and "decodes" a
/// pattern into the target's planes (block linear, as Blackwell's GOBs lay
/// them out), with a clean status.
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
    // (the init's probe: no picture)
    if (m[nvdec.SET_DRV_PIC_SETUP_OFFSET >> 2] == 0) return;
    seen.methods = m;
    seen.dwords = sub.dwords;
    if (m[nvdec.SET_APPLICATION_ID >> 2] == hevc.APPLICATION_ID_HEVC) return fakeDecodeHevc(k, &m);
    const pic = std.mem.bytesToValue(nvdec.H264Pic, at(k, &m, nvdec.SET_DRV_PIC_SETUP_OFFSET, @sizeOf(nvdec.H264Pic)));
    seen.pic = pic;
    const n = @min(pic.stream_len, 64);
    @memcpy(seen.stream[0..n], at(k, &m, nvdec.SET_IN_BUF_BASE_OFFSET, n));
    const offs = at(k, &m, nvdec.SET_SLICE_OFFSETS_BUF_OFFSET, 16);
    for (&seen.slices, 0..) |*s, j| s.* = std.mem.readInt(u32, offs[j * 4 ..][0..4], .little);
    const cur: u32 = pic.current.CurrPicIdx;
    const w: usize = @intCast(pic.PicWidthInMbs * 16);
    const h: usize = @intCast(pic.FrameHeightInMbs * 16);
    const lp = tiling.Plane.of(pic.pitch_luma, @intCast(h));
    const cp = tiling.Plane.of(pic.pitch_chroma, @intCast(h / 2));
    const luma = at(k, &m, nvdec.SET_PICTURE_LUMA_OFFSET0 + 4 * cur, @intCast(lp.bytes()));
    const chroma = at(k, &m, nvdec.SET_PICTURE_CHROMA_OFFSET0 + 4 * cur, @intCast(cp.bytes()));
    for (0..h) |y| {
        for (0..w) |x| luma[lp.offsetOf(.blackwell8, x, y)] = pattern(x, y, seen.frames);
    }
    for (0..h / 2) |y| {
        for (0..w) |x| chroma[cp.offsetOf(.blackwell16, x, y)] = pattern(x + 1, y + 100, seen.frames);
    }
    const st = at(k, &m, nvdec.SET_NVDEC_STATUS_OFFSET, @sizeOf(nvdec.Status));
    std.mem.writeInt(u32, st[0..4], @intCast((w / 16) * (h / 16)), .little);
    seen.frames += 1;
}

/// The pretend decoder's HEVC: nvdec_hevc_pic_s's size, strides and slot.
fn fakeDecodeHevc(k: *Fake, m: []const u32) void {
    const pic = std.mem.bytesToValue(hevc.HevcPic, at(k, m, nvdec.SET_DRV_PIC_SETUP_OFFSET, @sizeOf(hevc.HevcPic)));
    seen.hevc = pic;
    const n = @min(pic.stream_len, 64);
    @memcpy(seen.stream[0..n], at(k, m, nvdec.SET_IN_BUF_BASE_OFFSET, n));
    const cur: u32 = pic.curr_pic_idx;
    const w: usize = pic.pic_width_in_luma_samples;
    const h: usize = pic.pic_height_in_luma_samples;
    const lp = tiling.Plane.of(pic.framestride[0], @intCast(h));
    const cp = tiling.Plane.of(pic.framestride[1], @intCast(h / 2));
    const luma = at(k, m, nvdec.SET_PICTURE_LUMA_OFFSET0 + 4 * cur, @intCast(lp.bytes()));
    const chroma = at(k, m, nvdec.SET_PICTURE_CHROMA_OFFSET0 + 4 * cur, @intCast(cp.bytes()));
    for (0..h) |y| {
        for (0..w) |x| luma[lp.offsetOf(.blackwell8, x, y)] = pattern(x, y, seen.frames);
    }
    for (0..h / 2) |y| {
        for (0..w) |x| chroma[cp.offsetOf(.blackwell16, x, y)] = pattern(x + 1, y + 100, seen.frames);
    }
    const st = at(k, m, nvdec.SET_NVDEC_STATUS_OFFSET, @sizeOf(nvdec.Status));
    std.mem.writeInt(u32, st[0..4], @intCast((w / 16) * (h / 16)), .little);
    seen.frames += 1;
}

/// A decoder whose every frame fails: an error status, nothing decoded.
fn failDecode(k: *Fake, sub: Fake.Submit) void {
    const push = k.push(sub);
    if (push.len < nvdec.PUSH_DWORDS) return;
    // (SET_NVDEC_STATUS_OFFSET is the tenth method: words 18, 19)
    const st = k.at(@as(u64, push[19]) << 8, @sizeOf(nvdec.Status)).?;
    std.mem.writeInt(u32, st[12..16], 0x13, .little);
    std.mem.writeInt(u32, st[4..8], 6, .little);
}

fn testPic(target: u32, frame_num: u16) va.PictureParameterBufferH264 {
    var p = std.mem.zeroes(va.PictureParameterBufferH264);
    const poc: i32 = @as(i32, frame_num) * 2;
    p.CurrPic = .{ .picture_id = target, .frame_idx = frame_num, .flags = 0, .TopFieldOrderCnt = poc, .BottomFieldOrderCnt = poc };
    for (&p.ReferenceFrames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    // 3 x 2 macroblocks: a 40 x 24 picture coded as 48 x 32
    p.picture_width_in_mbs_minus1 = 2;
    p.picture_height_in_mbs_minus1 = 1;
    p.num_ref_frames = 2;
    p.seq_fields = .{ .chroma_format_idc = 1, .frame_mbs_only_flag = 1, .direct_8x8_inference_flag = 1 };
    p.pic_fields = .{ .reference_pic_flag = 1, .deblocking_filter_control_present_flag = 1 };
    p.frame_num = frame_num;
    return p;
}

/// One picture, as FFmpeg's vaapi hwaccel hands it: its parameters, then
/// two slices (one parameter buffer of two, one data buffer).
fn decodeOne(d: *TestDriver, ctx: u32, pic: *const va.PictureParameterBufferH264, surface: u32) !void {
    var slices = [_]va.SliceParameterBufferH264{ std.mem.zeroes(va.SliceParameterBufferH264), std.mem.zeroes(va.SliceParameterBufferH264) };
    slices[0].slice_data_offset = 0;
    slices[0].slice_data_size = 5;
    slices[0].num_ref_idx_l0_active_minus1 = 1;
    slices[1].slice_data_offset = 5;
    slices[1].slice_data_size = 4;
    slices[1].first_mb_in_slice = 3;
    const data = [_]u8{ 0x65, 1, 2, 3, 4, 0x41, 9, 8, 7 };
    var ids: [3]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(va.PictureParameterBufferH264), 1, pic, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_PARAMETER_BUFFER, @sizeOf(va.SliceParameterBufferH264), 2, &slices, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_DATA_BUFFER, data.len, 1, &data, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surface));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, ids[0..1]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, ids[1..3]));
    try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
    for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
}

/// The decode's picture where the decoder wrote it (VRAM, block linear):
/// nothing converted, no linear copy made.
fn expectPicture(d: *TestDriver, surface: u32, n: u32) !void {
    const s = &d.surfaces[surface - SURFACE_BASE];
    const t = s.tiled.bytes();
    const at_uv: usize = @intCast(s.layout.chroma_offset);
    for (0..s.height) |y| {
        for (0..s.width) |x| try testing.expectEqual(pattern(x, y, n), t[s.layout.luma.offsetOf(.blackwell8, x, y)]);
    }
    for (0..(s.height + 1) / 2) |y| {
        for (0..s.width) |x| try testing.expectEqual(pattern(x + 1, y + 100, n), t[at_uv + s.layout.chroma.offsetOf(.blackwell16, x, y)]);
    }
}

/// The surface's linear copy (a CPU reader's): the picture, pitch linear.
fn expectLinear(d: *TestDriver, surface: u32, n: u32) !void {
    const s = &d.surfaces[surface - SURFACE_BASE];
    const lin = s.linear_layout;
    const out = s.linear.bytes();
    for (0..s.height) |y| {
        for (0..s.width) |x| try testing.expectEqual(pattern(x, y, n), out[y * lin.pitch + x]);
    }
    for (0..(s.height + 1) / 2) |y| {
        for (0..s.width) |x| try testing.expectEqual(pattern(x + 1, y + 100, n), out[lin.uv_offset + y * lin.pitch + x]);
    }
}

test "driver: profiles, entrypoints, attributes, and Firefox's probe" {
    var k = Fake{};
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var profiles: [12]va.Profile = undefined;
    var n: i32 = 0;
    try testing.expectEqual(va.SUCCESS, d.queryConfigProfiles(&profiles, &n));
    // (HEVCMain10 18 and VP9Profile2 21: the 10-bit profiles vaapitest
    // looks for)
    try testing.expectEqualSlices(va.Profile, &.{ 13, 6, 7, 17, 18, 14, 19, 21, 32 }, profiles[0..@intCast(n)]);
    // Firefox's vaapitest: each profile's entrypoints, then a config of
    // (profile, VLD) with no attributes; H.264, HEVC and AV1 also encode
    for (profiles[0..@intCast(n)]) |p| {
        var eps: [4]va.Entrypoint = undefined;
        var m: i32 = 0;
        try testing.expectEqual(va.SUCCESS, d.queryConfigEntrypoints(p, &eps, &m));
        if (p == 14 or p == va.PROFILE_VP9_PROFILE_0 or p == va.PROFILE_HEVC_MAIN10 or p == va.PROFILE_VP9_PROFILE_2) {
            try testing.expectEqualSlices(va.Entrypoint, &.{va.ENTRYPOINT_VLD}, eps[0..@intCast(m)]);
        } else {
            try testing.expectEqualSlices(va.Entrypoint, &.{ va.ENTRYPOINT_VLD, ve.ENTRYPOINT_ENC_SLICE }, eps[0..@intCast(m)]);
        }
        var cfg: u32 = 0;
        try testing.expectEqual(va.SUCCESS, d.createConfig(p, va.ENTRYPOINT_VLD, &.{}, &cfg));
        var qp: va.Profile = 0;
        var qe: va.Entrypoint = 0;
        var qa: [4]va.ConfigAttrib = undefined;
        var qn: i32 = 0;
        try testing.expectEqual(va.SUCCESS, d.queryConfigAttributes(cfg, &qp, &qe, &qa, &qn));
        try testing.expectEqual(p, qp);
        try testing.expectEqual(driver.rtFormats(p), qa[0].value);
        try testing.expectEqual(va.SUCCESS, d.destroyConfig(cfg));
    }
    var eps: [4]va.Entrypoint = undefined;
    var m: i32 = 0;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, d.queryConfigEntrypoints(1, &eps, &m)); // MPEG2Main
    var cfg: u32 = 0;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, d.createConfig(va.PROFILE_NONE, va.ENTRYPOINT_VLD, &.{}, &cfg));
    try testing.expectEqual(va.ERROR_UNSUPPORTED_ENTRYPOINT, d.createConfig(va.PROFILE_H264_MAIN, 7, &.{}, &cfg)); // EncPicture
    try testing.expectEqual(va.ERROR_UNSUPPORTED_ENTRYPOINT, d.createConfig(va.PROFILE_VP9_PROFILE_0, ve.ENTRYPOINT_ENC_SLICE, &.{}, &cfg));
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, d.createConfig(va.PROFILE_H264_MAIN, va.ENTRYPOINT_VLD, &.{.{ .type = va.ATTRIB_RT_FORMAT, .value = 0x2 }}, &cfg));
    var attribs = [_]va.ConfigAttrib{ .{ .type = va.ATTRIB_RT_FORMAT, .value = 0 }, .{ .type = va.ATTRIB_MAX_PICTURE_WIDTH, .value = 0 }, .{ .type = 40, .value = 0 } };
    try testing.expectEqual(va.SUCCESS, d.getConfigAttributes(va.PROFILE_H264_HIGH, va.ENTRYPOINT_VLD, &attribs));
    try testing.expectEqual(va.RT_FORMAT_YUV420, attribs[0].value);
    try testing.expectEqual(@as(u32, driver.MAX_SIZE), attribs[1].value);
    try testing.expectEqual(va.ATTRIB_NOT_SUPPORTED, attribs[2].value);
    // surfaces' attributes: counted, then listed
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_MAIN, va.ENTRYPOINT_VLD, &.{}, &cfg));
    var sn: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.querySurfaceAttributes(cfg, null, &sn));
    try testing.expectEqual(@as(u32, 6), sn);
    var sa: [6]va.SurfaceAttrib = undefined;
    sn = 2;
    try testing.expectEqual(va.ERROR_MAX_NUM_EXCEEDED, d.querySurfaceAttributes(cfg, &sa, &sn));
    sn = 6;
    try testing.expectEqual(va.SUCCESS, d.querySurfaceAttributes(cfg, &sa, &sn));
    try testing.expectEqual(va.SURFACE_ATTRIB_PIXEL_FORMAT, sa[0].type);
    try testing.expectEqual(va.FOURCC_NV12, @as(u32, @bitCast(sa[0].value.value.i)));
    try testing.expectEqual(va.SURFACE_ATTRIB_MEMORY_TYPE, sa[5].type);
    try testing.expectEqual(va.MEM_TYPE_VA | va.MEM_TYPE_DRM_PRIME_2, @as(u32, @bitCast(sa[5].value.value.i)));
    var formats: [2]va.ImageFormat = undefined;
    try testing.expectEqual(va.SUCCESS, d.queryImageFormats(&formats, &m));
    try testing.expectEqual(@as(i32, 2), m);
    try testing.expectEqual(va.FOURCC_NV12, formats[0].fourcc);
    try testing.expectEqual(va.FOURCC_P010, formats[1].fourcc);
    try testing.expectEqual(@as(u32, 24), formats[1].bits_per_pixel);
    // the 10-bit profiles: 8- and 10-bit targets, both pixel formats
    // listed (FFmpeg takes the one its stream's format matches)
    for ([_]va.Profile{ va.PROFILE_HEVC_MAIN10, va.PROFILE_VP9_PROFILE_2, va.PROFILE_AV1_PROFILE_0 }) |p| {
        var c10: u32 = 0;
        try testing.expectEqual(va.SUCCESS, d.createConfig(p, va.ENTRYPOINT_VLD, &.{.{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420_10 }}, &c10));
        var s10: [7]va.SurfaceAttrib = undefined;
        var n10: u32 = 7;
        try testing.expectEqual(va.SUCCESS, d.querySurfaceAttributes(c10, &s10, &n10));
        try testing.expectEqual(@as(u32, 7), n10);
        try testing.expectEqual(va.FOURCC_NV12, @as(u32, @bitCast(s10[0].value.value.i)));
        try testing.expectEqual(va.FOURCC_P010, @as(u32, @bitCast(s10[1].value.value.i)));
        try testing.expectEqual(va.SUCCESS, d.destroyConfig(c10));
    }
    // (H.264 has no 10-bit here)
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, d.createConfig(va.PROFILE_H264_HIGH, va.ENTRYPOINT_VLD, &.{.{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420_10 }}, &cfg));
}

test "driver: init refuses another GPU and a GPU without a decoder" {
    var k = Fake{ .chip = 0x4303_0c00 };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.ERROR_UNIMPLEMENTED, d.init(3, .{}));
    try testing.expectEqual(@as(?[*]u8, null), d.pool);
    var k2 = Fake{ .has_decoder = false };
    var d2: TestDriver = .{ .node = .{ .sys = &k2 } };
    try testing.expectEqual(va.ERROR_UNIMPLEMENTED, d2.init(-1, .{}));
    try testing.expectEqual(@as(u32, 0), k2.live);
    try testing.expectEqual(@as(i32, -1), d2.node.fd);
}

test "driver: Begin/Render/End/Sync through a fake node: the pushbuffer, the bitstream, the picture" {
    var k = Fake{ .decoder = fakeDecode };
    seen = .{};
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    try testing.expectEqual(@as(u32, 1), k.n_submits); // the probe
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_HIGH, va.ENTRYPOINT_VLD, &.{}, &cfg));
    var surfaces: [3]u32 = undefined;
    const nv12 = [_]va.SurfaceAttrib{driver.intAttrib(va.SURFACE_ATTRIB_PIXEL_FORMAT, va.SURFACE_ATTRIB_SETTABLE, va.FOURCC_NV12)};
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &surfaces, &nv12));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));

    // ── frame 0: an I picture into surface 0 ──
    const p0 = testPic(surfaces[0], 0);
    try decodeOne(&d, ctx, &p0, surfaces[0]);
    try testing.expectEqual(@as(u32, 2), k.n_submits);
    const sub = k.submits[1];
    const c = &d.contexts[ctx - CONTEXT_BASE];
    try testing.expectEqual(c.work.handle, sub.handle);
    try testing.expectEqual(@as(u32, driver.PUSH_OFF), sub.offset);
    try testing.expectEqual(@as(u32, nvdec.PUSH_DWORDS), sub.dwords);
    const push = k.push(sub);
    try testing.expectEqual(nvdec.header(0, nvdec.SET_OBJECT, 1), push[0]);
    try testing.expectEqual(nvdec.CLASS | nvdec.SET_OBJECT_ENGINE_SW, push[1]);
    try testing.expectEqual(nvdec.APPLICATION_ID_H264, seen.methods[nvdec.SET_APPLICATION_ID >> 2]);
    try testing.expectEqual(nvdec.controlParams(0), seen.methods[nvdec.SET_CONTROL_PARAMS >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.STREAM_OFF), seen.methods[nvdec.SET_IN_BUF_BASE_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.PIC_OFF), seen.methods[nvdec.SET_DRV_PIC_SETUP_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.SLICES_OFF), seen.methods[nvdec.SET_SLICE_OFFSETS_BUF_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.STATUS_OFF), seen.methods[nvdec.SET_NVDEC_STATUS_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + c.coloc_off), seen.methods[nvdec.SET_COLOC_DATA_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + c.history_off), seen.methods[nvdec.SET_HISTORY_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + c.mbhist_off), seen.methods[nvdec.H264_SET_MBHIST_BUF_OFFSET >> 2]);
    try testing.expectEqual(@as(u32, 0), seen.methods[nvdec.SET_PICTURE_INDEX >> 2]);
    try testing.expectEqual(@as(u32, 0), seen.methods[nvdec.EXECUTE >> 2]);
    // the bitstream: a start code before each slice, then the end of stream
    const want_stream = [_]u8{ 0, 0, 1, 0x65, 1, 2, 3, 4, 0, 0, 1, 0x41, 9, 8, 7 } ++ nvdec.EOS;
    try testing.expectEqual(@as(u32, want_stream.len), seen.pic.stream_len);
    try testing.expectEqualSlices(u8, &want_stream, seen.stream[0..want_stream.len]);
    try testing.expectEqualSlices(u32, &.{ 0, 8, 15 }, seen.slices[0..3]);
    try testing.expectEqual(@as(u32, 2), seen.pic.slice_count);
    try testing.expectEqual(@as(i32, 1), seen.pic.num_ref_idx_l0_active_minus1);
    try testing.expectEqual(@as(i32, 3), seen.pic.PicWidthInMbs);
    try testing.expectEqual(@as(i32, 2), seen.pic.FrameHeightInMbs);
    try testing.expectEqual(@as(u32, 64), seen.pic.pitch_luma);
    try testing.expectEqual(@as(u2, 1), seen.pic.surface.tileFormat);
    try testing.expectEqual(@as(u3, 0), seen.pic.surface.gob_height);
    // the target in slot 0; every unheld slot names it too
    const s0 = &d.surfaces[surfaces[0] - SURFACE_BASE];
    try testing.expectEqual(@as(u7, 0), seen.pic.current.CurrPicIdx);
    for (0..nvdec.SLOTS) |slot| {
        try testing.expectEqual(nvdec.shifted(s0.tiled.va), seen.methods[(nvdec.SET_PICTURE_LUMA_OFFSET0 >> 2) + slot]);
        try testing.expectEqual(nvdec.shifted(s0.tiled.va + s0.layout.chroma_offset), seen.methods[(nvdec.SET_PICTURE_CHROMA_OFFSET0 >> 2) + slot]);
    }
    try testing.expectEqual(@as(u2, 0), seen.pic.dpb[0].bits.state);
    // done: the picture where the decoder wrote it, in VRAM; no linear
    // copy, nothing converted
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[0], SYNC_NS));
    try expectPicture(&d, surfaces[0], 0);
    try testing.expect(k.bufs[s0.tiled.handle].vram);
    try testing.expectEqual(@as(u32, 0), s0.linear.handle);
    try testing.expectEqual([3]u32{ 0, 0, 0 }, d.conversions);
    var status: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.querySurfaceStatus(surfaces[0], &status));
    try testing.expectEqual(va.SURFACE_READY, status);
    try testing.expectEqual(@as(u32, 0), d.errors);

    // ── frame 1: a P picture into surface 1, referencing surface 0; the
    //    GPU busy until waited for ──
    k.hold = true;
    var p1 = testPic(surfaces[1], 1);
    p1.ReferenceFrames[0] = .{ .picture_id = surfaces[0], .frame_idx = 0, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    try decodeOne(&d, ctx, &p1, surfaces[1]);
    try testing.expectEqual(va.SUCCESS, d.querySurfaceStatus(surfaces[1], &status));
    try testing.expectEqual(va.SURFACE_RENDERING, status);
    const s1 = &d.surfaces[surfaces[1] - SURFACE_BASE];
    try testing.expectEqual(@as(u7, 1), seen.pic.current.CurrPicIdx);
    try testing.expectEqual(@as(u7, 0), seen.pic.dpb[0].bits.index);
    try testing.expectEqual(@as(u5, 0), seen.pic.dpb[0].bits.col_idx);
    try testing.expectEqual(@as(u2, 3), seen.pic.dpb[0].bits.state);
    try testing.expectEqual(@as(u4, 1), seen.pic.dpb[0].bits.top_field_marking);
    try testing.expectEqual(nvdec.shifted(s0.tiled.va), seen.methods[nvdec.SET_PICTURE_LUMA_OFFSET0 >> 2]);
    try testing.expectEqual(nvdec.shifted(s1.tiled.va), seen.methods[(nvdec.SET_PICTURE_LUMA_OFFSET0 >> 2) + 1]);
    try testing.expectEqual(nvdec.shifted(s1.tiled.va), seen.methods[(nvdec.SET_PICTURE_LUMA_OFFSET0 >> 2) + 2]);
    try testing.expectEqual(@as(u32, 1), seen.methods[nvdec.SET_PICTURE_INDEX >> 2]);
    try testing.expectEqual(nvdec.controlParams(1), seen.methods[nvdec.SET_CONTROL_PARAMS >> 2]);
    // (the second frame slot: its own bitstream)
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.FRAME_BYTES + driver.STREAM_OFF), seen.methods[nvdec.SET_IN_BUF_BASE_OFFSET >> 2]);
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[1], SYNC_NS));
    try expectPicture(&d, surfaces[1], 1);
    try testing.expectEqual(va.SUCCESS, d.querySurfaceStatus(surfaces[1], &status));
    try testing.expectEqual(va.SURFACE_READY, status);

    // ── export: the decode target itself, one dma-buf (VRAM), block
    //    linear: Y (R8) and UV (GR88) as two objects of it (their
    //    modifiers differ on Blackwell: sector layouts 2 and 3) ──
    var desc: va.DrmPrimeDescriptor = undefined;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_MEMORY_TYPE, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME, 0, &desc));
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_READ_ONLY | va.EXPORT_SURFACE_SEPARATE_LAYERS, &desc));
    try testing.expectEqual(va.FOURCC_NV12, desc.fourcc);
    try testing.expectEqual(@as(u32, 40), desc.width);
    try testing.expectEqual(@as(u32, 24), desc.height);
    try testing.expectEqual(@as(u32, 2), desc.num_objects);
    // (two fds of the one dma-buf, each layer's own: Firefox closes them)
    try testing.expectEqual(@as(i32, 201), desc.objects[0].fd);
    try testing.expectEqual(@as(i32, 202), desc.objects[1].fd);
    try testing.expectEqual(@as(u32, 1), k.exports);
    for (0..2) |o| try testing.expectEqual(@as(u32, @intCast(s1.tiled.len)), desc.objects[o].size);
    try testing.expectEqual(@as(u64, 0x0300_0000_0420_6011), desc.objects[0].drm_format_modifier);
    try testing.expectEqual(@as(u64, 0x0300_0000_0460_6011), desc.objects[1].drm_format_modifier);
    try testing.expectEqual(@as(u32, 2), desc.num_layers);
    try testing.expectEqual(va.DRM_FORMAT_R8, desc.layers[0].drm_format);
    try testing.expectEqual(@as(u32, 1), desc.layers[0].num_planes);
    try testing.expectEqual(@as(u32, 64), desc.layers[0].pitch[0]);
    try testing.expectEqual(@as(u32, 0), desc.layers[0].offset[0]);
    try testing.expectEqual(@as(u32, 0), desc.layers[0].object_index[0]);
    try testing.expectEqual(va.DRM_FORMAT_GR88, desc.layers[1].drm_format);
    // (the 40 x 24 surface's rows padded to 128: Y is 64 x 128, 8 KiB)
    try testing.expectEqual(@as(u32, @intCast(s1.layout.chroma_offset)), desc.layers[1].offset[0]);
    try testing.expectEqual(@as(u32, 8192), desc.layers[1].offset[0]);
    try testing.expectEqual(@as(u32, 64), desc.layers[1].pitch[0]);
    try testing.expectEqual(@as(u32, 1), desc.layers[1].object_index[0]);
    // composed: one NV12 layer, its planes in the two objects; the
    // dma-buf made once, dup'd for each export
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_COMPOSED_LAYERS, &desc));
    try testing.expectEqual(@as(u32, 1), k.exports);
    try testing.expectEqual(@as(i32, 203), desc.objects[0].fd);
    try testing.expectEqual(@as(u32, 1), desc.num_layers);
    try testing.expectEqual(va.DRM_FORMAT_NV12, desc.layers[0].drm_format);
    try testing.expectEqual([4]u32{ 0, 8192, 0, 0 }, desc.layers[0].offset);
    try testing.expectEqual([4]u32{ 0, 1, 0, 0 }, desc.layers[0].object_index);
    try testing.expectEqual([4]u32{ 64, 64, 0, 0 }, desc.layers[0].pitch);
    // (still nothing converted: the frame goes out as the decoder wrote it)
    try testing.expectEqual([3]u32{ 0, 0, 0 }, d.conversions);
    try testing.expectEqual(@as(u32, 0), s1.linear.handle);
    // GALAXY_VA_GOB=turing: one modifier for both planes, one object
    d.opts.gob = .turing;
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_SEPARATE_LAYERS, &desc));
    try testing.expectEqual(@as(u32, 1), desc.num_objects);
    try testing.expectEqual(@as(u64, 0x0300_0000_0060_6011), desc.objects[0].drm_format_modifier);
    try testing.expectEqual(@as(u32, 0), desc.layers[1].object_index[0]);
    d.opts.gob = .blackwell;

    // ── images: derived (the linear copy, made and converted when it is
    //    mapped), and a copy (converted for vaGetImage) ──
    var img: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.deriveImage(surfaces[1], &img));
    try testing.expectEqual(va.FOURCC_NV12, img.format.fourcc);
    try testing.expectEqual([3]u32{ 64, 64, 0 }, img.pitches);
    try testing.expectEqual([3]u32{ 0, 64 * 32, 0 }, img.offsets);
    try testing.expect(s1.linear.handle != 0 and !k.bufs[s1.linear.handle].vram);
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(img.buf, &p));
    try testing.expectEqual(@intFromPtr(s1.linear.cpu), @intFromPtr(p.?));
    try testing.expectEqual(@as(u32, 1), d.conversions[@intFromEnum(convert.Done.cpu)]);
    try expectLinear(&d, surfaces[1], 1);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(img.buf));
    // (mapped: the app may have written it, so the picture is converted
    // back before the next export)
    try testing.expect(s1.tiled_stale);
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_SEPARATE_LAYERS, &desc));
    try testing.expectEqual(@as(u32, 2), d.conversions[@intFromEnum(convert.Done.cpu)]);
    try testing.expect(!s1.tiled_stale);
    try expectPicture(&d, surfaces[1], 1);
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
    var copy: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.NV12_FORMAT, 40, 24, &copy));
    try testing.expectEqual(va.SUCCESS, d.getImage(surfaces[0], 0, 0, 40, 24, copy.image_id));
    try testing.expectEqual(@as(u32, 3), d.conversions[@intFromEnum(convert.Done.cpu)]);
    // (again: the linear copy is current, nothing converted)
    try testing.expectEqual(va.SUCCESS, d.getImage(surfaces[0], 0, 0, 40, 24, copy.image_id));
    try testing.expectEqual(@as(u32, 3), d.conversions[@intFromEnum(convert.Done.cpu)]);
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(copy.buf, &p));
    const bytes: [*]const u8 = @ptrCast(p.?);
    try testing.expectEqual(pattern(39, 23, 0), bytes[23 * copy.pitches[0] + 39]);
    try testing.expectEqual(pattern(1 + 7, 100 + 11, 0), bytes[copy.offsets[1] + 11 * copy.pitches[1] + 7]);
    try testing.expectEqual(va.SUCCESS, d.destroyImage(copy.image_id));
    // (a P010 image for an NV12 surface: refused)
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.P010_FORMAT, 40, 24, &copy));
    try testing.expectEqual(va.ERROR_INVALID_IMAGE_FORMAT, d.getImage(surfaces[0], 0, 0, 40, 24, copy.image_id));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(copy.image_id));

    // ── a surface used as a reference keeps its slot; others are let go ──
    var p2 = testPic(surfaces[2], 2);
    p2.ReferenceFrames[0] = .{ .picture_id = surfaces[1], .frame_idx = 1, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 2, .BottomFieldOrderCnt = 2 };
    try decodeOne(&d, ctx, &p2, surfaces[2]);
    try testing.expectEqual(@as(u7, 0), seen.pic.current.CurrPicIdx); // (surface 0's slot, let go)
    try testing.expectEqual(@as(u7, 1), seen.pic.dpb[0].bits.index);
    try testing.expectEqual([2]u32{ 2, 2 }, seen.pic.dpb[0].FieldOrderCnt);
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[2], SYNC_NS));
    try expectPicture(&d, surfaces[2], 2);

    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
    try testing.expectEqual(va.SUCCESS, d.destroySurfaces(&surfaces));
    try testing.expectEqual(va.ERROR_INVALID_SURFACE, d.syncSurface(surfaces[0], 0));
    d.terminate();
    try testing.expectEqual(@as(u32, 0), k.live);
}

test "driver: a decode the decoder reports failed; a picture with no slices" {
    var k = Fake{ .decoder = failDecode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_MAIN, va.ENTRYPOINT_VLD, &.{}, &cfg));
    var surface: [1]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &surface, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    const p = testPic(surface[0], 0);
    try decodeOne(&d, ctx, &p, surface[0]);
    try testing.expectEqual(va.ERROR_DECODING_ERROR, d.syncSurface(surface[0], SYNC_NS));
    try testing.expectEqual(@as(u32, 1), d.errors);
    var ids: [1]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(va.PictureParameterBufferH264), 1, &p, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surface[0]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, d.endPicture(ctx));
    // (a picture bigger than its context)
    var big = testPic(surface[0], 1);
    big.picture_width_in_mbs_minus1 = 9;
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(va.PictureParameterBufferH264), 1, &big, &ids[0]));
    try decodeTooBig(&d, ctx, ids[0], surface[0]);
}

fn decodeTooBig(d: *TestDriver, ctx: u32, pic: u32, surface: u32) !void {
    var slice = std.mem.zeroes(va.SliceParameterBufferH264);
    slice.slice_data_size = 2;
    const data = [_]u8{ 0x65, 0 };
    var ids: [3]u32 = .{ pic, 0, 0 };
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_PARAMETER_BUFFER, @sizeOf(va.SliceParameterBufferH264), 1, &slice, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_DATA_BUFFER, data.len, 1, &data, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surface));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.ERROR_RESOLUTION_NOT_SUPPORTED, d.endPicture(ctx));
}

fn hevcPic(target: u32, poc: i32) va.PictureParameterBufferHEVC {
    var p = std.mem.zeroes(va.PictureParameterBufferHEVC);
    p.CurrPic = .{ .picture_id = target, .pic_order_cnt = poc, .flags = 0 };
    for (&p.ReferenceFrames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    p.pic_width_in_luma_samples = 64;
    p.pic_height_in_luma_samples = 48;
    p.pic_fields = .{ .chroma_format_idc = 1 };
    p.log2_diff_max_min_luma_coding_block_size = 3;
    p.log2_diff_max_min_transform_block_size = 3;
    p.log2_max_pic_order_cnt_lsb_minus4 = 4;
    p.num_short_term_ref_pic_sets = 1;
    return p;
}

/// One HEVC picture as FFmpeg's vaapi hwaccel hands it: parameters, then
/// one slice (its NAL unit header first; `nal` its type).
fn decodeHevc(d: *TestDriver, ctx: u32, pic: *const va.PictureParameterBufferHEVC, surface: u32, data: []const u8) !void {
    var slice = std.mem.zeroes(va.SliceParameterBufferHEVC);
    slice.slice_data_size = @intCast(data.len);
    var ids: [3]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(va.PictureParameterBufferHEVC), 1, pic, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_PARAMETER_BUFFER, @sizeOf(va.SliceParameterBufferHEVC), 1, &slice, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_DATA_BUFFER, @intCast(data.len), 1, data.ptr, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surface));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, ids[0..1]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, ids[1..3]));
    try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
    for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
}

test "driver: HEVC through a fake node: an IDR, then a P picture referencing it" {
    var k = Fake{ .decoder = fakeDecode };
    seen = .{};
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_HEVC_MAIN, va.ENTRYPOINT_VLD, &.{}, &cfg));
    var surfaces: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 64, 48, &surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 64, 48, &ctx));
    const c = &d.contexts[ctx - CONTEXT_BASE];
    try testing.expectEqual(driver.Codec.hevc, c.codec);
    // (64x48 rows padded to 128: the decoder's whole CTUs fit)
    try testing.expectEqual(@as(u32, 128), d.surfaces[surfaces[0] - SURFACE_BASE].layout.luma.rows);

    // IDR_W_RADL: first_slice 1, no_output 0, pps id 0, slice_type I (2)
    const idr = [_]u8{ 19 << 1, 1, 0xa6, 0x80 };
    const p0 = hevcPic(surfaces[0], 0);
    var pi = p0;
    pi.slice_parsing_fields.IdrPicFlag = 1;
    pi.slice_parsing_fields.RapPicFlag = 1;
    try decodeHevc(&d, ctx, &pi, surfaces[0], &idr);
    try testing.expectEqual(hevc.APPLICATION_ID_HEVC, seen.methods[nvdec.SET_APPLICATION_ID >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.PIC_OFF), seen.methods[nvdec.SET_DRV_PIC_SETUP_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.STREAM_OFF), seen.methods[nvdec.SET_IN_BUF_BASE_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + driver.AUX_OFF + hevc.TILES_OFF), seen.methods[hevc.HEVC_SET_TILE_SIZES_OFFSET >> 2]);
    try testing.expectEqual(nvdec.shifted(c.work.va + c.scratch_off), seen.methods[nvdec.SET_COLOC_DATA_OFFSET >> 2]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 } ++ idr, seen.stream[0..8]);
    try testing.expectEqual(@as(u32, 8), seen.hevc.stream_len);
    try testing.expectEqual(@as(u8, 1), seen.hevc.IDR_picture_flag);
    try testing.expectEqual(@as(u8, 0), seen.hevc.num_ref_frames);
    try testing.expectEqual(@as(u16, 0), seen.hevc.sw_hdr_skip_length);
    try testing.expectEqual(@as(u32, 64), seen.hevc.framestride[0]);
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[0], SYNC_NS));
    try expectPicture(&d, surfaces[0], 0);

    // TRAIL_R: first 1, pps 0, slice_type P (1), poc lsb 2 (8 bits),
    // st_ref_pic_set_sps_flag 1 (one set: no index): 9 bits skipped
    const trail = [_]u8{ 1 << 1, 1, 0xd0, 0x14, 0xc0 };
    var p1 = hevcPic(surfaces[1], 2);
    p1.ReferenceFrames[0] = .{ .picture_id = surfaces[0], .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_RPS_ST_CURR_BEFORE };
    try decodeHevc(&d, ctx, &p1, surfaces[1], &trail);
    try testing.expectEqual(@as(u16, 9), seen.hevc.sw_hdr_skip_length);
    try testing.expectEqual(@as(u8, 1), seen.hevc.num_ref_frames);
    const s0 = &d.surfaces[surfaces[0] - SURFACE_BASE];
    const ref_slot = seen.hevc.initreflistidxl0[0];
    try testing.expect(ref_slot != seen.hevc.curr_pic_idx);
    try testing.expectEqual(@as(i16, 2), seen.hevc.RefDiffPicOrderCnts[ref_slot]);
    try testing.expectEqual(nvdec.shifted(s0.tiled.va), seen.methods[(nvdec.SET_PICTURE_LUMA_OFFSET0 >> 2) + ref_slot]);
    try testing.expectEqual(@as(u32, 1), seen.methods[nvdec.SET_PICTURE_INDEX >> 2]);
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[1], SYNC_NS));
    try expectPicture(&d, surfaces[1], 1);
    try testing.expectEqual(@as(u32, 0), d.errors);
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}

test "driver: an AV1 config makes an AV1 context with the module's buffers" {
    var k = Fake{ .decoder = fakeDecode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{ .av1_blackwell = true }));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_AV1_PROFILE_0, va.ENTRYPOINT_VLD, &.{}, &cfg));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 1920, 1080, &ctx));
    const c = &d.contexts[ctx - CONTEXT_BASE];
    try testing.expectEqual(driver.Codec.av1, c.codec);
    try testing.expect(c.av1.blackwell);
    try testing.expectEqual(@import("av1.sig").scratchBytes(1920, 1080), c.scratch_bytes);
    try testing.expect(c.work.len >= c.scratch_off + c.scratch_bytes);
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}

// ── Encoding ────────────────────────────────────────────────────────────────

/// What the pretend encoder saw of the last picture.
const EncSeen = struct {
    methods: [0x800 / 4]u32 = [_]u32{0} ** (0x800 / 4),
    dwords: u32 = 0,
    app: u32 = 0,
    pictures: u32 = 0,
    setup: [nvenc.SETUP_BYTES]u8 = [_]u8{0} ** nvenc.SETUP_BYTES,
};
var enc_seen: EncSeen = .{};

/// The pretend encoder: reads the pushbuffer's methods and the setup as
/// NVENC would, and writes a slice (H.264: real I_PCM macroblocks of the
/// block-linear input; HEVC: a few bytes) where the setup says, with its
/// size in the status.
fn fakeEncode(k: *Fake, sub: Fake.Submit) void {
    const push = k.push(sub);
    var m = [_]u32{0} ** (0x800 / 4);
    var i: usize = 0;
    while (i < push.len) {
        const h = push[i];
        const method = h & 0x1fff;
        const count = (h >> 16) & 0x1fff;
        for (0..count) |j| m[method + j] = push[i + 1 + j];
        i += 1 + count;
    }
    // (the init's probe: no picture)
    if (m[nvenc.SET_IN_DRV_PIC_SETUP >> 2] == 0) return;
    enc_seen.methods = m;
    enc_seen.dwords = sub.dwords;
    enc_seen.app = m[nvenc.SET_APPLICATION_ID >> 2];
    enc_seen.pictures += 1;
    const setup = at(k, &m, nvenc.SET_IN_DRV_PIC_SETUP, nvenc.SETUP_BYTES);
    @memcpy(&enc_seen.setup, setup);
    const h264 = enc_seen.app == nvenc.APPLICATION_ID_H264;
    const start: usize = @intCast(nvenc.get(setup, if (h264) nvenc.H264.bitstream_start_pos else nvenc.H265.bitstream_start_pos));
    const out = at(k, &m, nvenc.SET_OUT_BITSTREAM, start + (64 << 10))[start..];
    const n = if (h264) pcmSlice(k, &m, setup, out) else fakeHevcSlice(out);
    const stat = at(k, &m, nvenc.SET_OUT_ENC_STATUS, nvenc.Stat.SIZE);
    nvenc.set(stat, nvenc.Stat.total_bit_count, n * 8);
    nvenc.set(stat, nvenc.Stat.num_slices, 1);
}

fn signExtend(v: u64, width: u6) i32 {
    const shift: u6 = 32 - width;
    const x: i32 = @bitCast(@as(u32, @truncate(v)) << @intCast(shift));
    return x >> @intCast(shift);
}

var pcm_rbsp: [16 << 10]u8 = undefined;
var pcm_y: [64 * 64]u8 = undefined;
var pcm_uv: [64 * 32]u8 = undefined;

/// An H.264 slice of I_PCM macroblocks holding the block-linear input
/// picture, its header made from the setup (as the engine would write
/// it): decoded, it is the input exactly.
fn pcmSlice(k: *Fake, m: []const u32, setup: []const u8, out: []u8) usize {
    const H = nvenc.H264;
    const w: usize = @intCast(nvenc.get(setup, H.input_cfg_frame_width_minus1) + 1);
    const h: usize = @intCast(nvenc.get(setup, H.input_cfg_frame_height_minus1) + 1);
    const pitch: u32 = @intCast(nvenc.get(setup, H.input_cfg_sfc_pitch));
    const lp = tiling.Plane.of(pitch, @intCast(h));
    const cp = tiling.Plane.of(pitch, @intCast(h / 2));
    const luma = at(k, m, nvenc.SET_IN_CUR_PIC, @intCast(lp.bytes()));
    const chroma = at(k, m, nvenc.SET_IN_CUR_PIC_CHROMA_U, @intCast(cp.bytes()));
    tiling.detile(&pcm_y, w, luma, lp, .blackwell8, w, h);
    tiling.detile(&pcm_uv, w, chroma, cp, .blackwell16, w, h / 2);
    const pic_type = nvenc.get(setup, H.pic_type);
    const idr = pic_type == 3;
    const intra = pic_type >= 2;
    var wr = bits.Writer.init(&pcm_rbsp);
    wr.u(8, if (idr) 0x65 else 0x61);
    wr.ue(0); // first_mb_in_slice
    wr.ue(if (intra) 7 else 5); // slice_type: I or P, all slices
    wr.ue(@intCast(nvenc.get(setup, H.pic_param_set_id)));
    wr.u(@intCast(nvenc.get(setup, H.log2_max_frame_num_minus4) + 4), @intCast(nvenc.get(setup, H.frame_num)));
    if (idr) wr.ue(@intCast(nvenc.get(setup, H.idr_pic_id)));
    if (nvenc.get(setup, H.pic_order_cnt_type) == 0) wr.u(@intCast(nvenc.get(setup, H.log2_max_pic_order_cnt_lsb_minus4) + 4), @intCast(nvenc.get(setup, H.pic_order_cnt_lsb)));
    if (!intra) {
        wr.flag(false); // num_ref_idx_active_override_flag
        wr.flag(false); // ref_pic_list_modification_flag_l0
    }
    // dec_ref_pic_marking(): no_output_of_prior_pics, long_term_reference
    // (IDR); adaptive_ref_pic_marking_mode_flag (else)
    wr.flag(false);
    if (idr) wr.flag(false);
    const init_qp = 26 + signExtend(nvenc.get(setup, H.pic_init_qp_minus26), 6);
    const qp: i32 = @intCast(nvenc.get(setup[nvenc.SLICE_CONTROL_OFF..], nvenc.H264Slice.qp_avr));
    wr.se(qp - init_qp);
    // (deblocking off: the samples stay exact)
    if (nvenc.get(setup, H.deblocking_filter_control_present_flag) != 0) wr.ue(1);
    for (0..(h + 15) / 16) |my| {
        for (0..(w + 15) / 16) |mx| {
            if (!intra) wr.ue(0); // mb_skip_run
            wr.ue(if (intra) 25 else 30); // I_PCM
            wr.alignZero();
            for (0..16) |yy| {
                for (0..16) |xx| wr.u(8, pcm_y[(my * 16 + yy) * w + mx * 16 + xx]);
            }
            for (0..2) |plane| {
                for (0..8) |yy| {
                    for (0..8) |xx| wr.u(8, pcm_uv[(my * 8 + yy) * w + mx * 16 + 2 * xx + plane]);
                }
            }
        }
    }
    wr.trailing();
    return bits.nal(out, wr.bytes(), 1).?;
}

fn fakeHevcSlice(out: []u8) usize {
    const s = [_]u8{ 0, 0, 0, 1, 0x26, 0x01, 0xaf, 0x80 };
    @memcpy(out[0..s.len], &s);
    return s.len;
}

fn encPattern(x: usize, y: usize, n: u32) u8 {
    return @truncate(x * 5 + y * 3 + n * 29 + 16);
}

/// The surface's picture put in as an app does (CreateImage, Map, PutImage).
fn putInput(d: *TestDriver, surface: u32, w: u32, h: u32, n: u32, planar: []u8) !void {
    var img: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.NV12_FORMAT, w, h, &img));
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(img.buf, &p));
    const b: [*]u8 = @ptrCast(p.?);
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    for (0..h) |y| {
        for (0..w) |x| {
            const v = encPattern(x, y, n);
            b[img.offsets[0] + y * img.pitches[0] + x] = v;
            planar[y * w + x] = v;
        }
    }
    for (0..ch) |y| {
        for (0..cw) |x| {
            const u = encPattern(x + 7, y + 50, n);
            const v = encPattern(x + 90, y + 3, n);
            b[img.offsets[1] + y * img.pitches[1] + 2 * x] = u;
            b[img.offsets[1] + y * img.pitches[1] + 2 * x + 1] = v;
            planar[w * h + y * cw + x] = u;
            planar[w * h + cw * ch + y * cw + x] = v;
        }
    }
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(img.buf));
    try testing.expectEqual(va.SUCCESS, d.putImage(surface, img.image_id, 0, 0, w, h, 0, 0, w, h));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
}

const Packed = struct { kind: u32, data: []const u8 };

fn miscBuffer(d: *TestDriver, kind: u32, value: anytype, out: *u32) !void {
    var buf: [4 + 64]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], kind, .little);
    const bytes = std.mem.asBytes(&value);
    @memcpy(buf[4..][0..bytes.len], bytes);
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_MISC_PARAMETER_BUFFER, @intCast(4 + bytes.len), 1, &buf, out));
}

/// One picture as FFmpeg's h264_vaapi hands it: (at an IDR) the sequence
/// and the misc parameters, the picture, packed headers, the slice.
fn encodeOne(d: *TestDriver, ctx: u32, input: u32, seq: ?*const enc_h264.Seq, pic: *const enc_h264.Pic, slice: *const ve.EncSliceParameterBufferH264, packed_headers: []const Packed) !void {
    var ids: [16]u32 = undefined;
    var n: usize = 0;
    if (seq) |sq| {
        try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SEQUENCE_PARAMETER_BUFFER, @sizeOf(enc_h264.Seq), 1, sq, &ids[n]));
        n += 1;
        var rc = std.mem.zeroes(ve.RateControl);
        rc.bits_per_second = sq.bits_per_second;
        rc.target_percentage = 100;
        rc.initial_qp = 28;
        try miscBuffer(d, ve.MISC_RATE_CONTROL, rc, &ids[n]);
        n += 1;
        var fr = std.mem.zeroes(ve.FrameRate);
        fr.framerate = 30 | (1 << 16);
        try miscBuffer(d, ve.MISC_FRAME_RATE, fr, &ids[n]);
        n += 1;
    }
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PICTURE_PARAMETER_BUFFER, @sizeOf(enc_h264.Pic), 1, pic, &ids[n]));
    n += 1;
    for (packed_headers) |ph| {
        const param = ve.PackedHeaderParameterBuffer{ .type = ph.kind, .bit_length = @intCast(ph.data.len * 8), .has_emulation_bytes = 1, .va_reserved = .{ 0, 0, 0, 0 } };
        try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PACKED_HEADER_PARAMETER_BUFFER, @sizeOf(ve.PackedHeaderParameterBuffer), 1, &param, &ids[n]));
        try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PACKED_HEADER_DATA_BUFFER, @intCast(ph.data.len), 1, ph.data.ptr, &ids[n + 1]));
        n += 2;
    }
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SLICE_PARAMETER_BUFFER, @sizeOf(ve.EncSliceParameterBufferH264), 1, slice, &ids[n]));
    n += 1;
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, input));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, ids[0..n]));
    try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
    for (ids[0..n]) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
}

fn encSeq() enc_h264.Seq {
    var s = enc_h264.testSeq(3, 2);
    s.bits_per_second = 500_000;
    // 48x32 coded, 40x24 shown
    s.frame_cropping_flag = 1;
    s.frame_crop_right_offset = 4;
    s.frame_crop_bottom_offset = 4;
    s.vui_parameters_present_flag = 1;
    s.vui_fields = .{ .timing_info_present_flag = 1, .bitstream_restriction_flag = 1, .log2_max_mv_length_horizontal = 15, .log2_max_mv_length_vertical = 15, .motion_vectors_over_pic_boundaries_flag = 1 };
    s.num_units_in_tick = 1;
    s.time_scale = 60;
    return s;
}

fn encSlice(slice_type: u8, poc_lsb: u16, ref: u32) ve.EncSliceParameterBufferH264 {
    var s = std.mem.zeroes(ve.EncSliceParameterBufferH264);
    s.num_macroblocks = 6;
    s.slice_type = slice_type;
    s.pic_order_cnt_lsb = poc_lsb;
    for (&s.RefPicList0) |*r| r.* = .{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    for (&s.RefPicList1) |*r| r.* = .{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    if (ref != va.INVALID_ID) s.RefPicList0[0] = .{ .picture_id = ref, .frame_idx = 0, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    return s;
}

/// The coded buffer's segment and its bytes (mapped; unmapped after).
fn codedBytes(d: *TestDriver, coded: u32, out: []u8) !usize {
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(coded, &p));
    const seg: *const ve.CodedBufferSegment = @ptrCast(@alignCast(p.?));
    try testing.expectEqual(@as(?*anyopaque, null), seg.next);
    try testing.expectEqual(@as(u32, 0), seg.status);
    const data: [*]const u8 = @ptrCast(seg.buf.?);
    @memcpy(out[0..seg.size], data[0..seg.size]);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(coded));
    return seg.size;
}

/// A file for WSL's ffmpeg (no C library: the system calls).
fn writeFile(path: [*:0]const u8, data: []const u8) void {
    if (comptime @import("builtin").os.tag != .linux) return;
    _ = linux.mkdirat(linux.AT.FDCWD, "/tmp/galaxy-va-enc", 0o755);
    const r: isize = @bitCast(linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644));
    if (r < 0) return;
    const fd: i32 = @intCast(r);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n: isize = @bitCast(linux.write(fd, data[off..].ptr, data.len - off));
        if (n <= 0) return;
        off += @intCast(n);
    }
}

var enc_stream: [64 << 10]u8 = undefined;
var enc_yuv: [2 * 40 * 24 * 3 / 2]u8 = undefined;

test "driver: encode's attributes as FFmpeg asks, configs, and a GPU without an encoder" {
    var k = Fake{ .encoder = fakeEncode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    try testing.expect(d.has_encoder);
    try testing.expectEqual(@as(u32, 1), k.n_esubmits); // the probe
    var attribs = [_]va.ConfigAttrib{
        .{ .type = va.ATTRIB_RT_FORMAT, .value = 0 },
        .{ .type = ve.ATTRIB_RATE_CONTROL, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_MAX_REF_FRAMES, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_MAX_SLICES, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_SLICE_STRUCTURE, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_QUALITY_RANGE, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_HEVC_FEATURES, .value = 0 },
    };
    try testing.expectEqual(va.SUCCESS, d.getConfigAttributes(va.PROFILE_H264_HIGH, ve.ENTRYPOINT_ENC_SLICE, &attribs));
    try testing.expectEqual(va.RT_FORMAT_YUV420, attribs[0].value);
    try testing.expectEqual(ve.RC_CQP | ve.RC_CBR | ve.RC_VBR, attribs[1].value);
    try testing.expectEqual(ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_MISC | ve.PACKED_HEADER_RAW_DATA, attribs[2].value);
    // L0 references in the low half, L1 in the high: B pictures
    try testing.expectEqual(encode.MAX_REFS, attribs[3].value);
    try testing.expectEqual(@as(u32, nvenc.MAX_SLICES), attribs[4].value);
    try testing.expect(attribs[5].value & ve.SLICE_STRUCTURE_ARBITRARY_MACROBLOCKS != 0);
    try testing.expectEqual(va.ATTRIB_NOT_SUPPORTED, attribs[6].value);
    try testing.expectEqual(va.ATTRIB_NOT_SUPPORTED, attribs[7].value); // (HEVC's only)
    try testing.expectEqual(va.SUCCESS, d.getConfigAttributes(va.PROFILE_HEVC_MAIN, ve.ENTRYPOINT_ENC_SLICE, attribs[7..8]));
    try testing.expectEqual(enc_hevc.FEATURES, attribs[7].value);
    try testing.expectEqual(va.ERROR_UNSUPPORTED_ENTRYPOINT, d.getConfigAttributes(va.PROFILE_VP9_PROFILE_0, ve.ENTRYPOINT_ENC_SLICE, &attribs));
    // configs: one rate control mode of these, packed headers of these
    var cfg: u32 = 0;
    const cbr = [_]va.ConfigAttrib{ .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 }, .{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR }, .{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_MISC } };
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &cbr, &cfg));
    var qp: va.Profile = 0;
    var qe: va.Entrypoint = 0;
    var qa: [8]va.ConfigAttrib = undefined;
    var qn: i32 = 0;
    try testing.expectEqual(va.SUCCESS, d.queryConfigAttributes(cfg, &qp, &qe, &qa, &qn));
    try testing.expectEqual(ve.ENTRYPOINT_ENC_SLICE, qe);
    try testing.expectEqual(@as(i32, 3), qn);
    try testing.expectEqual(ve.RC_CBR, qa[1].value);
    try testing.expectEqual(ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_MISC, qa[2].value);
    try testing.expectEqual(va.ERROR_INVALID_CONFIG, d.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &.{.{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR | ve.RC_VBR }}, &cfg));
    try testing.expectEqual(va.ERROR_INVALID_CONFIG, d.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &.{.{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = ve.PACKED_HEADER_SLICE }}, &cfg));

    // no encoder (the kernel's ENODEV): decode only, and said so
    var k2 = Fake{ .has_encoder = false };
    var d2: TestDriver = .{ .node = .{ .sys = &k2 } };
    try testing.expectEqual(va.SUCCESS, d2.init(3, .{}));
    defer d2.terminate();
    try testing.expect(!d2.has_encoder);
    try testing.expect(!d2.node.lost);
    var eps: [4]va.Entrypoint = undefined;
    var m: i32 = 0;
    try testing.expectEqual(va.SUCCESS, d2.queryConfigEntrypoints(va.PROFILE_H264_MAIN, &eps, &m));
    try testing.expectEqualSlices(va.Entrypoint, &.{va.ENTRYPOINT_VLD}, eps[0..@intCast(m)]);
    try testing.expectEqual(va.ERROR_UNSUPPORTED_ENTRYPOINT, d2.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &.{}, &cfg));
    // (GALAXY_VA_ENCODE=0: the same, without asking the kernel)
    var k3 = Fake{};
    var d3: TestDriver = .{ .node = .{ .sys = &k3 } };
    try testing.expectEqual(va.SUCCESS, d3.init(3, .{ .encode = false }));
    defer d3.terminate();
    try testing.expect(!d3.has_encoder);
    try testing.expectEqual(@as(u32, 0), k3.n_esubmits);
}

test "driver: H.264 through the fake encoder: an IDR then a P picture, the stream decodes to the input" {
    var k = Fake{ .encoder = fakeEncode };
    enc_seen = .{};
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{ .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 }, .{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR } };
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_CONSTRAINED_BASELINE, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    // two inputs, two reconstructed pictures (FFmpeg's pools)
    var surfaces: [4]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    const c = &d.contexts[ctx - CONTEXT_BASE];
    try testing.expect(c.encoding);
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 3 * 40 * 24 + (1 << 16), 1, null, &coded));
    // (a coded buffer never encoded into maps to an empty segment)
    var empty: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try codedBytes(&d, coded, &empty));

    // ── an IDR picture: the driver's SPS and PPS, then the engine's slice ──
    const frame = 40 * 24 * 3 / 2;
    try putInput(&d, surfaces[0], 40, 24, 0, enc_yuv[0..frame]);
    const seq = encSeq();
    const pic0 = enc_h264.testPic(surfaces[2], coded, true, 0);
    const s0 = encSlice(2, 0, va.INVALID_ID);
    try encodeOne(&d, ctx, surfaces[0], &seq, &pic0, &s0, &.{});
    try testing.expectEqual(@as(u32, 2), k.n_esubmits);
    const sub = k.esubmits[1];
    try testing.expectEqual(c.work.handle, sub.handle);
    const push = k.push(sub);
    try testing.expectEqual(nvenc.header(0, nvenc.SET_OBJECT, 1), push[0]);
    try testing.expectEqual(@as(u32, 0xcfb7) | nvenc.SET_OBJECT_ENGINE_SW, push[1]);
    try testing.expectEqual(nvenc.APPLICATION_ID_H264, enc_seen.app);
    try testing.expectEqual(nvenc.CODEC_TYPE_H264 | nvenc.CONTROL_GPTIMER_ON, enc_seen.methods[nvenc.SET_CONTROL_PARAMS >> 2]);
    const in0 = &d.surfaces[surfaces[0] - SURFACE_BASE];
    const rec0 = &d.surfaces[surfaces[2] - SURFACE_BASE];
    const cb = &d.coded[d.buffers[coded - driver.BUFFER_BASE].coded];
    try testing.expectEqual(nvenc.shifted(in0.tiled.va), enc_seen.methods[nvenc.SET_IN_CUR_PIC >> 2]);
    try testing.expectEqual(nvenc.shifted(in0.tiled.va + in0.layout.chroma_offset), enc_seen.methods[nvenc.SET_IN_CUR_PIC_CHROMA_U >> 2]);
    try testing.expectEqual(nvenc.shifted(rec0.tiled.va), enc_seen.methods[nvenc.SET_OUT_REF_PIC_LUMA >> 2]);
    try testing.expectEqual(nvenc.shifted(cb.buf.va + encode.DATA_OFF), enc_seen.methods[nvenc.SET_OUT_BITSTREAM >> 2]);
    try testing.expectEqual(nvenc.shifted(cb.buf.va + encode.STATUS_OFF), enc_seen.methods[nvenc.SET_OUT_ENC_STATUS >> 2]);
    try testing.expectEqual(nvenc.shifted(c.work.va + driver.ENC_SETUP_OFF), enc_seen.methods[nvenc.SET_IN_DRV_PIC_SETUP >> 2]);
    try testing.expectEqual(@as(u32, 0), enc_seen.methods[nvenc.SET_IN_REF_PIC0_LUMA >> 2]);
    try testing.expectEqual(@as(u64, 3), nvenc.get(&enc_seen.setup, nvenc.H264.pic_type)); // IDR
    try testing.expectEqual(@as(u64, 66), nvenc.get(&enc_seen.setup, nvenc.H264.profile_idc));
    try testing.expectEqual(@as(u64, 6), nvenc.get(enc_seen.setup[nvenc.SLICE_CONTROL_OFF..], nvenc.H264Slice.num_mb));
    // (CBR at 500 kb/s: the rate control's QP, an intra picture's at or
    // below the app's initial 28)
    try testing.expect(nvenc.get(enc_seen.setup[nvenc.SLICE_CONTROL_OFF..], nvenc.H264Slice.qp_avr) <= 28);
    // FFmpeg's async path: vaSyncBuffer on the coded buffer, then map it
    try testing.expectEqual(va.SUCCESS, d.syncBuffer(coded, std.math.maxInt(i64)));
    var n = try codedBytes(&d, coded, &enc_stream);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 66, 0xc0, 31 }, enc_stream[0..8]);
    const header_bytes = cb.header_bytes;
    try testing.expectEqual(@as(u64, header_bytes), nvenc.get(&enc_seen.setup, nvenc.H264.bitstream_start_pos));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65 }, enc_stream[header_bytes..][0..5]);

    // ── a P picture referencing the IDR's reconstruction ──
    try putInput(&d, surfaces[1], 40, 24, 1, enc_yuv[frame..][0..frame]);
    var pic1 = enc_h264.testPic(surfaces[3], coded, false, 1);
    pic1.ReferenceFrames[0] = .{ .picture_id = surfaces[2], .frame_idx = 0, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    const s1 = encSlice(0, 2, surfaces[2]);
    k.hold = true;
    try encodeOne(&d, ctx, surfaces[1], null, &pic1, &s1, &.{});
    var status: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.querySurfaceStatus(surfaces[1], &status));
    try testing.expectEqual(va.SURFACE_RENDERING, status);
    try testing.expectEqual(@as(u64, 0), nvenc.get(&enc_seen.setup, nvenc.H264.pic_type)); // P
    try testing.expectEqual(@as(u64, 0), nvenc.get(&enc_seen.setup, nvenc.at(nvenc.H264.l0, 0)));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&enc_seen.setup, nvenc.H264.frame_num));
    try testing.expectEqual(nvenc.shifted(rec0.tiled.va), enc_seen.methods[nvenc.SET_IN_REF_PIC0_LUMA >> 2]);
    try testing.expectEqual(nvenc.shifted(rec0.tiled.va + rec0.layout.chroma_offset), enc_seen.methods[nvenc.SET_IN_REF_PIC0_CHROMA >> 2]);
    // the old path: vaSyncSurface on the input fills the coded buffer too
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[1], SYNC_NS));
    const m1 = try codedBytes(&d, coded, enc_stream[n..]);
    // (no parameter sets: not an IDR, no new sequence)
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x61 }, enc_stream[n..][0..5]);
    n += m1;
    try testing.expectEqual(@as(u32, 2), c.enc.rate.frames);
    try testing.expectEqual(@as(u32, 0), d.errors);
    writeFile("/tmp/galaxy-va-enc/h264.264", enc_stream[0..n]);
    writeFile("/tmp/galaxy-va-enc/h264.yuv", &enc_yuv);

    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(coded));
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
    try testing.expectEqual(va.SUCCESS, d.destroySurfaces(&surfaces));
}

test "driver: H.264 with the app's packed headers: its SPS, PPS and SEI, none of the driver's" {
    var k = Fake{ .encoder = fakeEncode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{.{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_RAW_DATA }};
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_HIGH, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    var surfaces: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    var yuv: [40 * 24 * 3 / 2]u8 = undefined;
    try putInput(&d, surfaces[0], 40, 24, 5, &yuv);
    // the app's parameter sets (the driver's writer stands in for FFmpeg's
    // CBS here) and a user-data SEI
    const seq = encSeq();
    var pic = enc_h264.testPic(surfaces[1], coded, true, 0);
    pic.pic_init_qp = 30;
    var ps: [256]u8 = undefined;
    var np = enc_h264.writeSps(&ps, va.PROFILE_H264_HIGH, &seq).?;
    np += enc_h264.writePps(ps[np..], va.PROFILE_H264_HIGH, &pic).?;
    const sei = [_]u8{ 0, 0, 0, 1, 0x06, 0x05, 0x10 } ++ [_]u8{0x47} ** 16 ++ [_]u8{0x80};
    const s0 = encSlice(2, 0, va.INVALID_ID);
    try encodeOne(&d, ctx, surfaces[0], &seq, &pic, &s0, &.{ .{ .kind = ve.PACKED_SEQUENCE, .data = ps[0..np] }, .{ .kind = ve.PACKED_RAW_DATA, .data = &sei } });
    var out: [8 << 10]u8 = undefined;
    const n = try codedBytes(&d, coded, &out);
    try testing.expectEqualSlices(u8, ps[0..np], out[0..np]);
    try testing.expectEqualSlices(u8, &sei, out[np..][0..sei.len]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65 }, out[np + sei.len ..][0..5]);
    // (CQP: the app's QP, pic_init_qp + slice_qp_delta)
    try testing.expectEqual(@as(u64, 30), nvenc.get(enc_seen.setup[nvenc.SLICE_CONTROL_OFF..], nvenc.H264Slice.qp_avr));
    writeFile("/tmp/galaxy-va-enc/h264-packed.264", out[0..n]);
    writeFile("/tmp/galaxy-va-enc/h264-packed.yuv", &yuv);
}

test "driver: HEVC through the fake encoder: the driver's VPS, SPS and PPS, the setup" {
    var k = Fake{ .encoder = fakeEncode };
    enc_seen = .{};
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{ .nvenc_magic = 0xc9b7_0006 }));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_HEVC_MAIN, ve.ENTRYPOINT_ENC_SLICE, &.{}, &cfg));
    var surfaces: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 64, 48, &surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 64, 48, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    var yuv: [64 * 48 * 3 / 2]u8 = undefined;
    try putInput(&d, surfaces[0], 64, 48, 2, &yuv);
    var seq = enc_hevc.testSeq(64, 48);
    seq.vui_parameters_present_flag = 1;
    seq.vui_fields = .{ .vui_timing_info_present_flag = 1 };
    seq.vui_num_units_in_tick = 1;
    seq.vui_time_scale = 30;
    const pic = enc_hevc.testPic(surfaces[1], coded, true, 0);
    var slice = std.mem.zeroes(ve.EncSliceParameterBufferHEVC);
    slice.num_ctu_in_slice = 4;
    slice.slice_type = 2;
    slice.max_num_merge_cand = 5;
    for (&slice.ref_pic_list0) |*r| r.* = .{ .picture_id = va.INVALID_ID, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    for (&slice.ref_pic_list1) |*r| r.* = .{ .picture_id = va.INVALID_ID, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    var ids: [3]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SEQUENCE_PARAMETER_BUFFER, @sizeOf(enc_hevc.Seq), 1, &seq, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PICTURE_PARAMETER_BUFFER, @sizeOf(enc_hevc.Pic), 1, &pic, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SLICE_PARAMETER_BUFFER, @sizeOf(ve.EncSliceParameterBufferHEVC), 1, &slice, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surfaces[0]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
    try testing.expectEqual(nvenc.APPLICATION_ID_H265, enc_seen.app);
    try testing.expectEqual(nvenc.CODEC_TYPE_H265 | nvenc.CONTROL_GPTIMER_ON, enc_seen.methods[nvenc.SET_CONTROL_PARAMS >> 2]);
    // (GALAXY_VA_NVENC_MAGIC's word, not the assumed one)
    try testing.expectEqual(@as(u64, 0xc9b7_0006), nvenc.get(&enc_seen.setup, nvenc.H265.magic));
    try testing.expectEqual(@as(u64, 3), nvenc.get(&enc_seen.setup, nvenc.H265.pic_type));
    try testing.expectEqual(@as(u64, 19), nvenc.get(&enc_seen.setup, nvenc.H265.nal_unit_type));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&enc_seen.setup, nvenc.H265.max_cu_size));
    try testing.expectEqual(@as(u64, 4), nvenc.get(enc_seen.setup[nvenc.SLICE_CONTROL_OFF..], nvenc.H265Slice.num_ctus));
    var out: [4 << 10]u8 = undefined;
    const n = try codedBytes(&d, coded, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x40, 0x01 }, out[0..6]);
    const cb = &d.coded[d.buffers[coded - driver.BUFFER_BASE].coded];
    try testing.expectEqual(@as(usize, cb.header_bytes + 8), n);
    // (the parameter sets alone, for ffmpeg's trace_headers)
    writeFile("/tmp/galaxy-va-enc/hevc-headers.265", out[0..cb.header_bytes]);
    for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
}

test "driver: an encode refused: no coded buffer, a reconstruction over its input, a lost GPU" {
    var k = Fake{ .encoder = fakeEncode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &.{}, &cfg));
    var surfaces: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    const seq = encSeq();
    const s0 = encSlice(2, 0, va.INVALID_ID);
    // (a picture naming a buffer that is not a coded buffer)
    var pic = enc_h264.testPic(surfaces[1], 0x1234, true, 0);
    var ids: [3]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SEQUENCE_PARAMETER_BUFFER, @sizeOf(enc_h264.Seq), 1, &seq, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PICTURE_PARAMETER_BUFFER, @sizeOf(enc_h264.Pic), 1, &pic, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SLICE_PARAMETER_BUFFER, @sizeOf(ve.EncSliceParameterBufferH264), 1, &s0, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surfaces[0]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, d.endPicture(ctx));
    for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
    // (the reconstruction into the input itself)
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    pic = enc_h264.testPic(surfaces[0], coded, true, 0);
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SEQUENCE_PARAMETER_BUFFER, @sizeOf(enc_h264.Seq), 1, &seq, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PICTURE_PARAMETER_BUFFER, @sizeOf(enc_h264.Pic), 1, &pic, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_SLICE_PARAMETER_BUFFER, @sizeOf(ve.EncSliceParameterBufferH264), 1, &s0, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surfaces[0]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.ERROR_INVALID_SURFACE, d.endPicture(ctx));
    // (a lost GPU: the encode is not submitted)
    pic = enc_h264.testPic(surfaces[1], coded, true, 0);
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_PICTURE_PARAMETER_BUFFER, @sizeOf(enc_h264.Pic), 1, &pic, &ids[1]));
    k.hung = true;
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surfaces[0]));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.ERROR_OPERATION_FAILED, d.endPicture(ctx));
    try testing.expect(d.node.lost);
}
