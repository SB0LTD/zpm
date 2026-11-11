//! @zpm/va driver tests — the driver over a fake node (node.Fake) whose
//! pretend decoder reads each pushbuffer as NVDEC would and writes a
//! pattern into the target, block linear: profiles and Firefox's probe,
//! init's refusals, and Begin/Render/End/Sync with the submitted words,
//! the bitstream, the reference slots, the linear picture, the export and
//! the images checked.

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const tiling = @import("tiling.sig");
const node = @import("node.sig");
const driver = @import("driver.sig");
const hevc = @import("hevc.sig");

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

fn expectPicture(d: *TestDriver, surface: u32, n: u32) !void {
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
    var profiles: [8]va.Profile = undefined;
    var n: i32 = 0;
    try testing.expectEqual(va.SUCCESS, d.queryConfigProfiles(&profiles, &n));
    try testing.expectEqualSlices(va.Profile, &.{ 13, 6, 7, 17 }, profiles[0..@intCast(n)]);
    // Firefox's vaapitest: each profile's entrypoints, then a config of
    // (profile, VLD) with no attributes
    for (profiles[0..@intCast(n)]) |p| {
        var eps: [4]va.Entrypoint = undefined;
        var m: i32 = 0;
        try testing.expectEqual(va.SUCCESS, d.queryConfigEntrypoints(p, &eps, &m));
        try testing.expectEqualSlices(va.Entrypoint, &.{va.ENTRYPOINT_VLD}, eps[0..@intCast(m)]);
        var cfg: u32 = 0;
        try testing.expectEqual(va.SUCCESS, d.createConfig(p, va.ENTRYPOINT_VLD, &.{}, &cfg));
        var qp: va.Profile = 0;
        var qe: va.Entrypoint = 0;
        var qa: [4]va.ConfigAttrib = undefined;
        var qn: i32 = 0;
        try testing.expectEqual(va.SUCCESS, d.queryConfigAttributes(cfg, &qp, &qe, &qa, &qn));
        try testing.expectEqual(p, qp);
        try testing.expectEqual(va.RT_FORMAT_YUV420, qa[0].value);
        try testing.expectEqual(va.SUCCESS, d.destroyConfig(cfg));
    }
    var eps: [4]va.Entrypoint = undefined;
    var m: i32 = 0;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, d.queryConfigEntrypoints(1, &eps, &m)); // MPEG2Main
    var cfg: u32 = 0;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, d.createConfig(va.PROFILE_NONE, va.ENTRYPOINT_VLD, &.{}, &cfg));
    try testing.expectEqual(va.ERROR_UNSUPPORTED_ENTRYPOINT, d.createConfig(va.PROFILE_H264_MAIN, 6, &.{}, &cfg)); // EncSlice
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
    try testing.expectEqual(@as(i32, 1), m);
    try testing.expectEqual(va.FOURCC_NV12, formats[0].fourcc);
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
    // done: the picture, linear
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[0], SYNC_NS));
    try expectPicture(&d, surfaces[0], 0);
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

    // ── export: one dma-buf, two layers (R8, GR88), linear ──
    var desc: va.DrmPrimeDescriptor = undefined;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_MEMORY_TYPE, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME, 0, &desc));
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_READ_ONLY | va.EXPORT_SURFACE_SEPARATE_LAYERS, &desc));
    try testing.expectEqual(va.FOURCC_NV12, desc.fourcc);
    try testing.expectEqual(@as(u32, 40), desc.width);
    try testing.expectEqual(@as(u32, 24), desc.height);
    try testing.expectEqual(@as(u32, 1), desc.num_objects);
    try testing.expectEqual(@as(i32, 201), desc.objects[0].fd);
    try testing.expectEqual(@as(u32, @intCast(s1.linear.len)), desc.objects[0].size);
    try testing.expectEqual(va.DRM_FORMAT_MOD_LINEAR, desc.objects[0].drm_format_modifier);
    try testing.expectEqual(@as(u32, 2), desc.num_layers);
    try testing.expectEqual(va.DRM_FORMAT_R8, desc.layers[0].drm_format);
    try testing.expectEqual(@as(u32, 1), desc.layers[0].num_planes);
    try testing.expectEqual(@as(u32, 64), desc.layers[0].pitch[0]);
    try testing.expectEqual(@as(u32, 0), desc.layers[0].offset[0]);
    try testing.expectEqual(va.DRM_FORMAT_GR88, desc.layers[1].drm_format);
    try testing.expectEqual(@as(u32, 64 * 32), desc.layers[1].offset[0]);
    try testing.expectEqual(@as(u32, 64), desc.layers[1].pitch[0]);
    try testing.expectEqual(@as(u32, 0), desc.layers[1].object_index[0]);
    // (the dma-buf made once: a second export dups it)
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(surfaces[1], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_COMPOSED_LAYERS, &desc));
    try testing.expectEqual(@as(u32, 1), k.exports);
    try testing.expectEqual(@as(i32, 202), desc.objects[0].fd);
    try testing.expectEqual(@as(u32, 1), desc.num_layers);
    try testing.expectEqual(va.DRM_FORMAT_NV12, desc.layers[0].drm_format);
    try testing.expectEqual([4]u32{ 0, 64 * 32, 0, 0 }, desc.layers[0].offset);

    // ── images: derived (the linear picture itself), and a copy ──
    var img: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.deriveImage(surfaces[1], &img));
    try testing.expectEqual(va.FOURCC_NV12, img.format.fourcc);
    try testing.expectEqual([3]u32{ 64, 64, 0 }, img.pitches);
    try testing.expectEqual([3]u32{ 0, 64 * 32, 0 }, img.offsets);
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(img.buf, &p));
    try testing.expectEqual(@intFromPtr(s1.linear.cpu), @intFromPtr(p.?));
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(img.buf));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
    var copy: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.NV12_FORMAT, 40, 24, &copy));
    try testing.expectEqual(va.SUCCESS, d.getImage(surfaces[0], 0, 0, 40, 24, copy.image_id));
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(copy.buf, &p));
    const bytes: [*]const u8 = @ptrCast(p.?);
    try testing.expectEqual(pattern(39, 23, 0), bytes[23 * copy.pitches[0] + 39]);
    try testing.expectEqual(pattern(1 + 7, 100 + 11, 0), bytes[copy.offsets[1] + 11 * copy.pitches[1] + 7]);
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
