//! @zpm/va driver pipeline tests — the driver over a fake node (node.Fake)
//! whose work stays running until a real wait (`hold`): several pictures
//! in flight with no wait, a frame slot's wait FRAMES pictures back, VP9's
//! backward adaptation waiting for the next BeginPicture (not EndPicture)
//! with libvpx's probabilities still matched frame after frame, the old
//! per-picture wait (GALAXY_VA_SERIAL=1), the debug counts and their line,
//! a read-only map, and H.264's scratch in VRAM (GALAXY_VA_SCRATCH=vram).

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const node = @import("node.sig");
const driver = @import("driver.sig");
const vp9 = @import("vp9.sig");
const vav = @import("vaapi_vp9.sig");

const testing = std.testing;
const Fake = node.Fake;
const TestDriver = driver.Driver(*Fake);
const SURFACE_BASE = driver.SURFACE_BASE;
const CONTEXT_BASE = driver.CONTEXT_BASE;
const SYNC_NS = driver.SYNC_NS;

/// What the pretend decoder has done: pictures, and VP9 frames (the
/// clip's frame whose counts it writes next).
var decoded: u32 = 0;
var vp9_frame: usize = 0;

/// The pushbuffer's methods, by dword index.
fn methodsOf(k: *Fake, sub: Fake.Submit) [0x600 / 4]u32 {
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
    return m;
}

/// The pretend decoder: a clean status with a cycle count; for VP9, the
/// clip frame's counts (libvpx's) where the decoder writes them.
fn pipeDecode(k: *Fake, sub: Fake.Submit) void {
    const m = methodsOf(k, sub);
    // (the init's probe: no picture)
    if (m[nvdec.SET_DRV_PIC_SETUP_OFFSET >> 2] == 0) return;
    decoded += 1;
    const st = k.at(@as(u64, m[nvdec.SET_NVDEC_STATUS_OFFSET >> 2]) << 8, @sizeOf(nvdec.Status)).?;
    var s = std.mem.zeroes(nvdec.Status);
    s.mbs_correctly_decoded = 1;
    s.cycle_count = 1000 * decoded;
    @memcpy(st, std.mem.asBytes(&s));
    if (m[nvdec.SET_APPLICATION_ID >> 2] == vp9.APPLICATION_ID_VP9 and vp9_frame < vp9.CLIP.len) {
        const counts = k.at(@as(u64, m[vp9.VP9_SET_CTX_COUNTER_BUF_OFFSET >> 2]) << 8, @sizeOf(vp9.HwCounts)).?;
        for (vp9.CLIP[vp9_frame].counts) |c| std.mem.writeInt(u32, counts[c[0] * 4 ..][0..4], c[1], .little);
        vp9_frame += 1;
    }
}

// ── H.264 ───────────────────────────────────────────────────────────────────

fn h264Pic(target: u32, frame_num: u16) va.PictureParameterBufferH264 {
    var p = std.mem.zeroes(va.PictureParameterBufferH264);
    const poc: i32 = @as(i32, frame_num) * 2;
    p.CurrPic = .{ .picture_id = target, .frame_idx = frame_num, .flags = 0, .TopFieldOrderCnt = poc, .BottomFieldOrderCnt = poc };
    for (&p.ReferenceFrames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    p.picture_width_in_mbs_minus1 = 2;
    p.picture_height_in_mbs_minus1 = 1;
    p.num_ref_frames = 2;
    p.seq_fields = .{ .chroma_format_idc = 1, .frame_mbs_only_flag = 1, .direct_8x8_inference_flag = 1 };
    p.pic_fields = .{ .reference_pic_flag = 1 };
    p.frame_num = frame_num;
    return p;
}

/// A picture of one slice into `surface` (referencing `ref`, if one).
fn h264One(d: *TestDriver, ctx: u32, surface: u32, frame_num: u16, ref: ?u32) !void {
    var pic = h264Pic(surface, frame_num);
    if (ref) |r| pic.ReferenceFrames[0] = .{ .picture_id = r, .frame_idx = 0, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    var slice = std.mem.zeroes(va.SliceParameterBufferH264);
    slice.slice_data_size = 5;
    const data = [_]u8{ 0x65, 1, 2, 3, 4 };
    var ids: [3]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(va.PictureParameterBufferH264), 1, &pic, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_PARAMETER_BUFFER, @sizeOf(va.SliceParameterBufferH264), 1, &slice, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_DATA_BUFFER, data.len, 1, &data, &ids[2]));
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surface));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
    try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
    for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
}

fn h264Context(d: *TestDriver, surfaces: []u32) !u32 {
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_HIGH, va.ENTRYPOINT_VLD, &.{}, &cfg));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    return ctx;
}

test "driver pipeline: H.264 pictures in flight without a wait, a frame slot's wait FRAMES back, the app's sync, the counts" {
    var k = Fake{ .decoder = pipeDecode };
    decoded = 0;
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{ .debug = true }));
    defer d.terminate();
    var surfaces: [6]u32 = undefined;
    const ctx = try h264Context(&d, &surfaces);
    const c = &d.contexts[ctx - CONTEXT_BASE];
    // (the GPU busy: nothing done until a real wait)
    k.hold = true;
    for (0..driver.FRAMES) |i| try h264One(&d, ctx, surfaces[i], @intCast(i), null);
    // FRAMES pictures submitted, none waited for: each one deeper in flight
    try testing.expectEqual(@as(u32, driver.FRAMES), c.stats.pictures);
    try testing.expectEqual(@as(u32, 0), d.node.vstats.blocked);
    try testing.expectEqual(@as(u32, driver.FRAMES), c.stats.in_flight_max);
    try testing.expectEqual(@as(u64, 1 + 2 + 3 + 4), c.stats.in_flight_sum);
    for (surfaces[0..driver.FRAMES]) |s| try testing.expect(d.surfaces[s - SURFACE_BASE].pending);
    // the next picture takes the first frame slot again: its decode
    // waited for (it slept: still running), its status read
    try h264One(&d, ctx, surfaces[driver.FRAMES], driver.FRAMES, null);
    try testing.expectEqual(@as(u32, 1), c.stats.slot_waits);
    try testing.expectEqual(@as(u32, 0), c.stats.after_waits);
    try testing.expectEqual(@as(u32, 1), c.stats.statuses);
    try testing.expectEqual(@as(u32, 1000), c.stats.cycles_max);
    // (that wait finished everything before: this one alone in flight)
    try testing.expectEqual(@as(u64, 10 + 1), c.stats.in_flight_sum);
    // the app's sync: a wait of its own, told apart
    try testing.expectEqual(va.SUCCESS, d.syncSurface(surfaces[driver.FRAMES], SYNC_NS));
    try testing.expectEqual(@as(u32, 2), d.node.vstats.blocked);
    var buf: [512]u8 = undefined;
    const line = c.stats.line(&buf, "h264", 48, 32, d.node.vstats);
    try testing.expect(std.mem.startsWith(u8, line, "galaxy-va: h264 48x32 pipeline: 5 pictures"));
    try testing.expect(std.mem.indexOf(u8, line, "in flight at submit avg 2.2 max 4") != null);
    try testing.expect(std.mem.indexOf(u8, line, "the driver's 0.20 (frame slot 1, after a decode 0;") != null);
    try testing.expect(std.mem.indexOf(u8, line, "the app's 0.20 (1;") != null);
    try testing.expect(std.mem.endsWith(u8, line, "statuses)\n"));
    // the context's end: its decodes' statuses read, the line said
    const lines = k.lines;
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
    try testing.expectEqual(lines + 1, k.lines);
}

test "driver pipeline: without GALAXY_VA_DEBUG pictures are counted, nothing looked at or said" {
    var k = Fake{ .decoder = pipeDecode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var surfaces: [3]u32 = undefined;
    const ctx = try h264Context(&d, &surfaces);
    k.hold = true;
    const waits = k.waits;
    for (0..3) |i| try h264One(&d, ctx, surfaces[i], @intCast(i), null);
    // (no G_VWAIT at all: no look, no wait)
    try testing.expectEqual(waits, k.waits);
    try testing.expectEqual(@as(u32, 3), d.contexts[ctx - CONTEXT_BASE].stats.pictures);
    const lines = k.lines;
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
    try testing.expectEqual(lines, k.lines);
}

test "driver pipeline: the summary fits its line whatever the counts" {
    const big = std.math.maxInt(u32);
    const s = driver.Stats{
        .pictures = big,
        .first_ns = 0,
        .last_ns = std.math.maxInt(i64),
        .in_flight_sum = std.math.maxInt(u64) / 1000,
        .in_flight_max = big,
        .slot_waits = big,
        .after_waits = big,
        .own_ns = std.math.maxInt(u64),
        .statuses = big,
        .cycles_sum = std.math.maxInt(u64),
        .cycles_max = big,
    };
    var buf: [512]u8 = undefined;
    const line = s.line(&buf, "av1", 4096, 4096, .{ .blocked = big, .blocked_ns = std.math.maxInt(u64) });
    try testing.expect(std.mem.startsWith(u8, line, "galaxy-va: av1 4096x4096 pipeline: "));
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
}

// ── VP9 ─────────────────────────────────────────────────────────────────────

fn vp9Context(d: *TestDriver, surfaces: []u32) !u32 {
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_VP9_PROFILE_0, va.ENTRYPOINT_VLD, &.{}, &cfg));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 512, 64, surfaces, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 512, 64, &ctx));
    return ctx;
}

fn crc(x: anytype) u32 {
    return std.hash.Crc32.hash(std.mem.asBytes(x));
}

/// The clip's frame `i`'s buffers, as FFmpeg's vaapi hwaccel makes them.
fn vp9Buffers(d: *TestDriver, f: vp9.ClipFrame, refs: [8]u32, ids: *[3]u32) !void {
    var p = std.mem.zeroes(vav.PictureParameterBufferVP9);
    p.frame_width = 512;
    p.frame_height = 64;
    p.reference_frames = refs;
    p.pic_fields = .{ .subsampling_x = 1, .subsampling_y = 1, .frame_type = @intFromBool(!f.key), .show_frame = 1 };
    p.frame_header_length_in_bytes = f.uncompressed;
    p.first_partition_size = f.compressed;
    p.bit_depth = 8;
    var sp = std.mem.zeroes(vav.SliceParameterBufferVP9);
    sp.slice_data_size = @intCast(f.bytes.len);
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.PICTURE_PARAMETER_BUFFER, @sizeOf(vav.PictureParameterBufferVP9), 1, &p, &ids[0]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_PARAMETER_BUFFER, @sizeOf(vav.SliceParameterBufferVP9), 1, &sp, &ids[1]));
    try testing.expectEqual(va.SUCCESS, d.createBuffer(va.SLICE_DATA_BUFFER, @intCast(f.bytes.len), 1, f.bytes.ptr, &ids[2]));
}

/// libvpx's clip through the driver, the decoder busy until waited for:
/// each frame's forward-updated probabilities and the adaptation after it
/// as libvpx's; `serial`: the adaptation at EndPicture (GALAXY_VA_SERIAL=1),
/// else at the next BeginPicture with EndPicture never waiting.
fn vp9Clip(serial: bool) !void {
    var k = Fake{ .decoder = pipeDecode };
    vp9_frame = 0;
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{ .serial_after = serial }));
    defer d.terminate();
    var surfaces: [8]u32 = undefined;
    const ctx = try vp9Context(&d, &surfaces);
    const c = &d.contexts[ctx - CONTEXT_BASE];
    k.hold = true;
    var refs = [_]u32{va.INVALID_ID} ** 8;
    for (vp9.CLIP, 0..) |f, i| {
        const target = surfaces[i];
        var ids: [3]u32 = undefined;
        try vp9Buffers(&d, f, refs, &ids);
        try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, target));
        // the last frame's adaptation done by now, whichever way, as libvpx's
        try testing.expect(!c.after_due);
        if (i > 0) try testing.expectEqual(vp9.CLIP[i - 1].crc_adapted, crc(&c.vp9.ctx[0]));
        try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
        // (this frame's forward updates over the adapted context: libvpx's)
        try testing.expectEqual(f.crc_forward, crc(&c.vp9.fc));
        const waits = k.waits;
        const blocked = d.node.vstats.blocked;
        try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
        for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
        if (serial) {
            // waited for at once, adapted
            try testing.expectEqual(blocked + 1, d.node.vstats.blocked);
            try testing.expect(!c.after_due);
            try testing.expectEqual(f.crc_adapted, crc(&c.vp9.ctx[0]));
        } else {
            // no wait, not a look: the decode runs on; the adaptation due
            try testing.expectEqual(waits, k.waits);
            try testing.expect(c.after_due);
            try testing.expect(d.surfaces[target - SURFACE_BASE].pending);
        }
        for (&refs, 0..) |*r, slot| {
            if (c.vp9.hdr.refresh_flags & (@as(u8, 1) << @intCast(slot)) != 0) r.* = target;
        }
    }
    // each frame's adaptation waited once for its decode (still running)
    try testing.expectEqual(@as(u32, if (serial) vp9.CLIP.len else vp9.CLIP.len - 1), c.stats.after_waits);
    try testing.expectEqual(@as(u32, vp9.CLIP.len), c.stats.pictures);
    // the last frame's adaptation, at a BeginPicture that goes no further
    if (!serial) {
        try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, surfaces[vp9.CLIP.len]));
        try testing.expectEqual(vp9.CLIP[vp9.CLIP.len - 1].crc_adapted, crc(&c.vp9.ctx[0]));
    }
    try testing.expectEqual(@as(usize, vp9.CLIP.len), vp9_frame);
    try testing.expectEqual(@as(u32, 0), d.errors);
}

test "driver pipeline: VP9's backward adaptation waits for the next BeginPicture, libvpx's probabilities every frame" {
    try vp9Clip(false);
}

test "driver pipeline: GALAXY_VA_SERIAL=1 adapts at EndPicture, waiting there, the same probabilities" {
    try vp9Clip(true);
}

// ── Maps and scratch ────────────────────────────────────────────────────────

test "driver pipeline: a derived image mapped read only is not converted back; a map to write is" {
    var k = Fake{ .decoder = pipeDecode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var surfaces: [2]u32 = undefined;
    const ctx = try h264Context(&d, &surfaces);
    try h264One(&d, ctx, surfaces[0], 0, null);
    var image: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.deriveImage(surfaces[0], &image));
    const s = &d.surfaces[surfaces[0] - SURFACE_BASE];
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBufferFor(image.buf, &p, driver.MAP_READ));
    try testing.expect(p != null);
    try testing.expect(!s.tiled_stale);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(image.buf));
    // (a reference now: nothing converted for the decoder)
    const conversions = d.conversions;
    try h264One(&d, ctx, surfaces[1], 1, surfaces[0]);
    try testing.expectEqual(conversions, d.conversions);
    try testing.expectEqual(va.SUCCESS, d.mapBufferFor(image.buf, &p, driver.MAP_READ | driver.MAP_WRITE));
    try testing.expect(s.tiled_stale);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(image.buf));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(image.image_id));
}

test "driver pipeline: GALAXY_VA_SCRATCH=vram puts H.264's decoder-only buffers in VRAM" {
    var k = Fake{ .decoder = pipeDecode };
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{ .h264_scratch_vram = true }));
    defer d.terminate();
    const live = k.live;
    var surfaces: [1]u32 = undefined;
    const ctx = try h264Context(&d, &surfaces);
    const c = &d.contexts[ctx - CONTEXT_BASE];
    try testing.expect(c.vram_scratch.handle != 0);
    try testing.expect(k.bufs[c.vram_scratch.handle].vram);
    try testing.expect(!k.bufs[c.work.handle].vram);
    try testing.expectEqual(driver.FRAMES * driver.FRAME_BYTES, c.work.len);
    try h264One(&d, ctx, surfaces[0], 0, null);
    const m = methodsOf(&k, k.submits[k.n_submits - 1]);
    const lo = c.vram_scratch.va;
    const hi = lo + c.vram_scratch.len;
    for ([_]u32{ nvdec.SET_COLOC_DATA_OFFSET, nvdec.SET_HISTORY_OFFSET, nvdec.H264_SET_MBHIST_BUF_OFFSET }) |method| {
        const at = @as(u64, m[method >> 2]) << 8;
        try testing.expect(at >= lo and at < hi);
    }
    try testing.expectEqual(lo, @as(u64, m[nvdec.SET_COLOC_DATA_OFFSET >> 2]) << 8);
    // (the frame slot's own buffers stay in the work buffer)
    try testing.expectEqual(c.work.va + driver.STREAM_OFF, @as(u64, m[nvdec.SET_IN_BUF_BASE_OFFSET >> 2]) << 8);
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
    // (both buffers given back: the surface's is left)
    try testing.expectEqual(live + 1, k.live);
}
