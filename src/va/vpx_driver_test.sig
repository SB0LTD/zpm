//! @zpm/va vpx_driver_test — VP8 and VP9 encoding through the driver, as
//! Firefox's VA-API probe and FFmpeg's vp8_vaapi / vp9_vaapi call it, on
//! the CPU's engine (the driver's tests have no GPU; vpx_gpu.sig's tests
//! run the same kernels on KIR's interpreter and the emulated RTX). Each
//! stream is written to /tmp/galaxy-va-enc/ with the encoder's own
//! reconstruction, for WSL's ffmpeg and libvpx to decode and compare.

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const node = @import("node.sig");
const tiling = @import("tiling.sig");
const driver = @import("driver.sig");
const enc_vpx = @import("enc_vpx.sig");
const enc_vp8 = @import("enc_vp8.sig");
const vav8 = @import("vaapi_vp8.sig");
const vav9 = @import("vaapi_vp9.sig");
const enc_test = @import("enc_test.sig");

const testing = std.testing;
const Fake = node.Fake;
const D = driver.Driver(*Fake);

test "vpx: Firefox's probe finds VP8 and VP9 encoding; FFmpeg's attribute queries" {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    for ([_]va.Profile{ vav8.PROFILE_VP8_VERSION0_3, vav9.PROFILE_VP9_PROFILE0 }) |p| {
        var eps: [4]va.Entrypoint = undefined;
        var m: i32 = 0;
        try testing.expectEqual(va.SUCCESS, d.queryConfigEntrypoints(p, &eps, &m));
        try testing.expectEqualSlices(va.Entrypoint, &.{ va.ENTRYPOINT_VLD, ve.ENTRYPOINT_ENC_SLICE }, eps[0..@intCast(m)]);
        // vaapitest: a config of (profile, EncSlice) with no attributes
        var cfg: u32 = 0;
        try testing.expectEqual(va.SUCCESS, d.createConfig(p, ve.ENTRYPOINT_ENC_SLICE, &.{}, &cfg));
        try testing.expectEqual(va.SUCCESS, d.destroyConfig(cfg));
        var attribs = [_]va.ConfigAttrib{
            .{ .type = va.ATTRIB_RT_FORMAT, .value = 0 },
            .{ .type = ve.ATTRIB_RATE_CONTROL, .value = 0 },
            .{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = 0 },
            .{ .type = ve.ATTRIB_ENC_MAX_REF_FRAMES, .value = 0 },
            .{ .type = ve.ATTRIB_ENC_QUALITY_RANGE, .value = 0 },
        };
        try testing.expectEqual(va.SUCCESS, d.getConfigAttributes(p, ve.ENTRYPOINT_ENC_SLICE, &attribs));
        try testing.expectEqual(va.RT_FORMAT_YUV420, attribs[0].value);
        try testing.expectEqual(ve.RC_CQP | ve.RC_CBR | ve.RC_VBR, attribs[1].value);
        try testing.expectEqual(ve.PACKED_HEADER_NONE, attribs[2].value);
        // one L0 reference, no L1: FFmpeg sends P pictures only
        try testing.expectEqual(@as(u32, 1), attribs[3].value);
        try testing.expectEqual(va.ATTRIB_NOT_SUPPORTED, attribs[4].value);
        // packed headers refused, one rate control mode taken
        const packed_attr = [_]va.ConfigAttrib{.{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = ve.PACKED_HEADER_SEQUENCE }};
        try testing.expectEqual(va.ERROR_INVALID_CONFIG, d.createConfig(p, ve.ENTRYPOINT_ENC_SLICE, &packed_attr, &cfg));
        const cbr = [_]va.ConfigAttrib{.{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR }};
        try testing.expectEqual(va.SUCCESS, d.createConfig(p, ve.ENTRYPOINT_ENC_SLICE, &cbr, &cfg));
        try testing.expectEqual(va.SUCCESS, d.destroyConfig(cfg));
    }
    // GALAXY_VA_VPX_ENCODE=0: decode only
    var d2: D = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d2.init(3, .{ .vpx_encode = false }));
    defer d2.terminate();
    var eps: [4]va.Entrypoint = undefined;
    var m: i32 = 0;
    try testing.expectEqual(va.SUCCESS, d2.queryConfigEntrypoints(vav8.PROFILE_VP8_VERSION0_3, &eps, &m));
    try testing.expectEqual(@as(i32, 1), m);
}

const W = 40;
const H = 24;
const FRAMES = 5;
const FRAME_BYTES = W * H + 2 * ((W + 1) / 2) * ((H + 1) / 2);

var yuv: [FRAMES * FRAME_BYTES]u8 = undefined;
var stream: [256 << 10]u8 = undefined;
var mine: [64 << 10]u8 = undefined;
var recon: [FRAMES * FRAME_BYTES]u8 = undefined;
var ivf: [300 << 10]u8 = undefined;

/// A moving picture: shapes and texture, frame `n`.
fn fill(dst: []u8, pitch: usize, uv_at: usize, n: u32, planar: []u8) void {
    const cw = (W + 1) / 2;
    const ch = (H + 1) / 2;
    for (0..H) |y| for (0..W) |x| {
        const xx = @as(i32, @intCast(x)) - @as(i32, @intCast(n * 2));
        const yy = @as(i32, @intCast(y)) - @as(i32, @intCast(n));
        var v: i32 = 50 + @divTrunc(xx * 3 + yy * 4, 2) + @mod(xx * 7 + yy * 11, 13);
        if (@mod(@divFloor(xx, 6) + @divFloor(yy, 6), 2) == 0) v += 60;
        const b: u8 = @intCast(std.math.clamp(v, 0, 255));
        dst[y * pitch + x] = b;
        planar[y * W + x] = b;
    };
    for (0..ch) |y| for (0..cw) |x| {
        const u: u8 = @intCast(90 + (x * 4 + y * 3 + n * 5) % 60);
        const v: u8 = @intCast(150 - (x * 2 + y * 5 + n * 3) % 50);
        dst[uv_at + y * pitch + 2 * x] = u;
        dst[uv_at + y * pitch + 2 * x + 1] = v;
        planar[W * H + y * cw + x] = u;
        planar[W * H + cw * ch + y * cw + x] = v;
    };
}

fn putInput(d: *D, surface: u32, n: u32) !void {
    var img: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.NV12_FORMAT, W, H, &img));
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(img.buf, &p));
    const b: [*]u8 = @ptrCast(p.?);
    fill(b[img.offsets[0] .. img.offsets[1] + img.pitches[1] * ((H + 1) / 2)], img.pitches[0], img.offsets[1] - img.offsets[0], n, yuv[n * FRAME_BYTES ..][0..FRAME_BYTES]);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(img.buf));
    try testing.expectEqual(va.SUCCESS, d.putImage(surface, img.image_id, 0, 0, W, H, 0, 0, W, H));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
}

fn createBuf(d: *D, kind: u32, value: anytype) !u32 {
    var id: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(kind, @sizeOf(@TypeOf(value.*)), 1, value, &id));
    return id;
}

fn miscBuf(d: *D, kind: u32, value: anytype) !u32 {
    var mb: [4 + 64]u8 = undefined;
    std.mem.writeInt(u32, mb[0..4], kind, .little);
    const bytes = std.mem.asBytes(value);
    @memcpy(mb[4..][0..bytes.len], bytes);
    var id: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_MISC_PARAMETER_BUFFER, @intCast(4 + bytes.len), 1, &mb, &id));
    return id;
}

fn ivfHeader(out: []u8, fourcc: *const [4]u8, frames: u32) usize {
    @memset(out[0..32], 0);
    @memcpy(out[0..4], "DKIF");
    std.mem.writeInt(u16, out[6..8], 32, .little);
    @memcpy(out[8..12], fourcc);
    std.mem.writeInt(u16, out[12..14], W, .little);
    std.mem.writeInt(u16, out[14..16], H, .little);
    std.mem.writeInt(u32, out[16..20], 30, .little);
    std.mem.writeInt(u32, out[20..24], 1, .little);
    std.mem.writeInt(u32, out[24..28], frames, .little);
    return 32;
}

fn ivfFrame(out: []u8, data: []const u8, pts: u64) usize {
    std.mem.writeInt(u32, out[0..4], @intCast(data.len), .little);
    std.mem.writeInt(u64, out[4..12], pts, .little);
    @memcpy(out[12..][0..data.len], data);
    return 12 + data.len;
}

/// The reconstruction the CPU engine left (frame slot `slot`), cropped.
fn reconOf(c: anytype, slot: usize, out: []u8) void {
    const lay = c.vpx.vp8.lay;
    const mem = c.vpx_cpu.bytes();
    const cw = (W + 1) / 2;
    const ch = (H + 1) / 2;
    for (0..H) |y| @memcpy(out[y * W ..][0..W], mem[lay.yOff(slot) + y * lay.ys ..][0..W]);
    for (0..ch) |y| @memcpy(out[W * H + y * cw ..][0..cw], mem[lay.uOff(slot) + y * lay.cs ..][0..cw]);
    for (0..ch) |y| @memcpy(out[W * H + cw * ch + y * cw ..][0..cw], mem[lay.vOff(slot) + y * lay.cs ..][0..cw]);
}

test "vpx: VP8 through the driver as FFmpeg's vp8_vaapi sends it: a key frame, inter frames, CQP; the stream is the encoder's" {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{ .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 }, .{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CQP } };
    try testing.expectEqual(va.SUCCESS, d.createConfig(vav8.PROFILE_VP8_VERSION0_3, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    var in: [FRAMES]u32 = undefined;
    var rec: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, W, H, &in, &.{}));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, W, H, &rec, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, W, H, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    for (0..FRAMES) |n| try putInput(&d, in[n], @intCast(n));

    // the same pictures straight through enc_vp8 (the CPU engine), for the
    // stream the driver must give
    var ref_enc = try enc_vp8.Encoder.init(W, H);
    const lay = ref_enc.lay;
    var mem_buf: [64 << 10]u8 = @splat(0);
    var info_buf: [16 << 10]u8 = @splat(0);
    var scratch_buf: [128 << 10]u8 = undefined;

    var seq = std.mem.zeroes(enc_vpx.SeqVp8);
    seq.frame_width = W;
    seq.frame_height = H;
    var n_ivf = ivfHeader(&ivf, "VP80", FRAMES);
    for (0..FRAMES) |n| {
        var pic = std.mem.zeroes(enc_vpx.PicVp8);
        pic.reconstructed_frame = rec[n & 1];
        pic.coded_buf = coded;
        if (n == 0) {
            pic.ref_flags = 1; // force_kf
            pic.ref_last_frame = va.INVALID_ID;
            pic.ref_gf_frame = va.INVALID_ID;
            pic.ref_arf_frame = va.INVALID_ID;
        } else {
            pic.ref_flags = 0b1100; // no golden, no altref
            pic.ref_last_frame = rec[(n - 1) & 1];
            pic.ref_gf_frame = rec[(n - 1) & 1];
            pic.ref_arf_frame = rec[(n - 1) & 1];
            pic.pic_flags = 1; // inter
        }
        pic.pic_flags |= (1 << 4) | (1 << 19) | (1 << 20) | (1 << 21);
        var q = std.mem.zeroes(enc_vpx.QMatrixVp8);
        q.quantization_index = .{ 24, 24, 24, 24 };
        var ids: [3]u32 = undefined;
        ids[0] = try createBuf(&d, ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq);
        ids[1] = try createBuf(&d, ve.ENC_PICTURE_PARAMETER_BUFFER, &pic);
        ids[2] = try createBuf(&d, enc_vpx.QMATRIX_BUFFER, &q);
        try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, in[n]));
        try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
        try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
        for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
        try testing.expectEqual(va.SUCCESS, d.syncSurface(in[n], 1_000_000_000));
        var p: ?*anyopaque = null;
        try testing.expectEqual(va.SUCCESS, d.mapBuffer(coded, &p));
        const seg: *const ve.CodedBufferSegment = @ptrCast(@alignCast(p.?));
        try testing.expectEqual(@as(u32, 0), seg.status);
        const data: [*]const u8 = @ptrCast(seg.buf.?);
        const got = data[0..seg.size];
        try testing.expectEqual(va.SUCCESS, d.unmapBuffer(coded));
        // the frame tag: key (bit 0 clear) first, shown
        try testing.expectEqual(n != 0, got[0] & 1 != 0);
        try testing.expect(got[0] & 0x10 != 0);
        if (n == 0) {
            try testing.expectEqualSlices(u8, &.{ 0x9d, 0x01, 0x2a }, got[3..6]);
            try testing.expectEqual(@as(u16, W), std.mem.readInt(u16, got[6..8], .little));
            try testing.expectEqual(@as(u16, H), std.mem.readInt(u16, got[8..10], .little));
        }
        // the encoder alone, on the surface's own picture
        const ci = ctx - driver.CONTEXT_BASE;
        const c = &d.contexts[ci];
        const s = &d.surfaces[in[n] - driver.SURFACE_BASE];
        const sw = s.layout.swizzles(.blackwell);
        const surf = enc_vp8.Surface{ .luma = 0, .chroma = @intCast(s.layout.chroma_offset), .pitch_luma = s.layout.luma.pitch, .pitch_chroma = s.layout.chroma.pitch, .swz_luma = @intFromEnum(sw[0]), .swz_chroma = @intFromEnum(sw[1]), .gobs = tiling.BLOCK_GOBS_LOG2 };
        var eng = enc_vp8.CpuEngine{ .mem = mem_buf[0..lay.mem_bytes], .info = info_buf[0..lay.info_bytes], .surf = s.tiled.bytes() };
        const st = try enc_vp8.encodeFrame(&ref_enc, &eng, surf, .{ .key = n == 0, .q = 24 }, &mine, &scratch_buf);
        try testing.expectEqualSlices(u8, mine[0..st.bytes], got);
        n_ivf += ivfFrame(ivf[n_ivf..], got, n);
        reconOf(c, c.vpx.vp8.lastSlot(), recon[n * FRAME_BYTES ..][0..FRAME_BYTES]);
        try testing.expect(c.vpx_engine == .cpu);
    }
    enc_test.writeFile("/tmp/galaxy-va-enc/vp8.ivf", ivf[0..n_ivf]);
    enc_test.writeFile("/tmp/galaxy-va-enc/vp8-recon.yuv", &recon);
    enc_test.writeFile("/tmp/galaxy-va-enc/vp8-input.yuv", &yuv);
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(coded));
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}

test "vpx: VP8 CBR: the rate control holds the stream near its rate" {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{.{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR }};
    try testing.expectEqual(va.SUCCESS, d.createConfig(vav8.PROFILE_VP8_VERSION0_3, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    var in: [FRAMES]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, W, H, &in, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, W, H, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    for (0..FRAMES) |n| try putInput(&d, in[n], @intCast(n));
    var seq = std.mem.zeroes(enc_vpx.SeqVp8);
    seq.frame_width = W;
    seq.frame_height = H;
    seq.bits_per_second = 60_000;
    seq.intra_period = 30;
    var rc = std.mem.zeroes(ve.RateControl);
    rc.bits_per_second = 60_000;
    rc.target_percentage = 100;
    var fr = std.mem.zeroes(ve.FrameRate);
    fr.framerate = 30 | (1 << 16);
    var total: usize = 0;
    const N = 60;
    var qs: [N]u8 = undefined;
    for (0..N) |n| {
        var pic = std.mem.zeroes(enc_vpx.PicVp8);
        pic.coded_buf = coded;
        pic.reconstructed_frame = in[0];
        pic.ref_flags = if (n == 0) 1 else 0b1100;
        pic.pic_flags = @as(u32, @intFromBool(n != 0)) | (1 << 4) | (1 << 21);
        var q = std.mem.zeroes(enc_vpx.QMatrixVp8);
        q.quantization_index = .{ 40, 40, 40, 40 };
        var ids = [_]u32{
            try createBuf(&d, ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq),
            try createBuf(&d, ve.ENC_PICTURE_PARAMETER_BUFFER, &pic),
            try createBuf(&d, enc_vpx.QMATRIX_BUFFER, &q),
            try miscBuf(&d, ve.MISC_RATE_CONTROL, &rc),
            try miscBuf(&d, ve.MISC_FRAME_RATE, &fr),
        };
        try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, in[n % FRAMES]));
        try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
        try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
        for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
        var p: ?*anyopaque = null;
        try testing.expectEqual(va.SUCCESS, d.mapBuffer(coded, &p));
        const seg: *const ve.CodedBufferSegment = @ptrCast(@alignCast(p.?));
        total += seg.size;
        try testing.expectEqual(va.SUCCESS, d.unmapBuffer(coded));
        qs[n] = d.contexts[ctx - driver.CONTEXT_BASE].vpx.vp8.last.q;
    }
    // the second half's rate within a third of the target (the first
    // second settles the model)
    const rate = @as(f64, @floatFromInt(total * 8)) / (@as(f64, N) / 30.0);
    try testing.expect(rate > 60_000 * 0.5 and rate < 60_000 * 1.5);
    // the quantizer moved from the app's 40
    try testing.expect(qs[N - 1] != 40 or qs[N / 2] != 40);
}

// ── VP9 ─────────────────────────────────────────────────────────────────────

const enc_vp9 = @import("enc_vp9.sig");

fn reconOf9(c: anytype, slot: usize, out: []u8) void {
    const lay = c.vpx.vp9.lay;
    const mem = c.vpx_cpu.bytes();
    const cw = (W + 1) / 2;
    const ch = (H + 1) / 2;
    for (0..H) |y| @memcpy(out[y * W ..][0..W], mem[lay.yOff(slot) + y * lay.ys ..][0..W]);
    for (0..ch) |y| @memcpy(out[W * H + y * cw ..][0..cw], mem[lay.uOff(slot) + y * lay.cs ..][0..cw]);
    for (0..ch) |y| @memcpy(out[W * H + cw * ch + y * cw ..][0..cw], mem[lay.vOff(slot) + y * lay.cs ..][0..cw]);
}

test "vpx: VP9 through the driver as FFmpeg's vp9_vaapi sends it: a key frame, inter frames, CQP; the stream is the encoder's" {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{ .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 }, .{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CQP } };
    try testing.expectEqual(va.SUCCESS, d.createConfig(vav9.PROFILE_VP9_PROFILE0, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    var in: [FRAMES]u32 = undefined;
    var rec: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, W, H, &in, &.{}));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, W, H, &rec, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, W, H, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    for (0..FRAMES) |n| try putInput(&d, in[n], @intCast(n));

    // the same pictures straight through enc_vp9 (the CPU engine)
    var ref_enc = try enc_vp9.Encoder.init(W, H);
    const lay = ref_enc.lay;
    var mem_buf: [64 << 10]u8 = @splat(0);
    var info_buf: [16 << 10]u8 = @splat(0);
    var scratch_buf: [128 << 10]u8 = undefined;
    const Q = 96;

    var seq = std.mem.zeroes(enc_vpx.SeqVp9);
    seq.max_frame_width = W;
    seq.max_frame_height = H;
    seq.intra_period = 30;
    var n_ivf = ivfHeader(&ivf, "VP90", FRAMES);
    for (0..FRAMES) |n| {
        var pic = std.mem.zeroes(enc_vpx.PicVp9);
        pic.frame_width_src = W;
        pic.frame_height_src = H;
        pic.frame_width_dst = W;
        pic.frame_height_dst = H;
        pic.reconstructed_frame = rec[n & 1];
        for (&pic.reference_frames) |*r| r.* = va.INVALID_ID;
        pic.coded_buf = coded;
        pic.refresh_frame_flags = 0xff;
        pic.luma_ac_qindex = Q;
        if (n == 0) {
            pic.ref_flags = 1; // force_kf
        } else {
            pic.reference_frames[0] = rec[(n - 1) & 1];
            pic.ref_flags = 1 << 1; // ref_frame_ctrl_l0: LAST, slot 0
            pic.pic_flags = 1; // inter
        }
        pic.pic_flags |= 1 << 1; // shown
        var ids: [2]u32 = undefined;
        ids[0] = try createBuf(&d, ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq);
        ids[1] = try createBuf(&d, ve.ENC_PICTURE_PARAMETER_BUFFER, &pic);
        try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, in[n]));
        try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
        try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
        for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
        try testing.expectEqual(va.SUCCESS, d.syncSurface(in[n], 1_000_000_000));
        var p: ?*anyopaque = null;
        try testing.expectEqual(va.SUCCESS, d.mapBuffer(coded, &p));
        const seg: *const ve.CodedBufferSegment = @ptrCast(@alignCast(p.?));
        try testing.expectEqual(@as(u32, 0), seg.status);
        const data: [*]const u8 = @ptrCast(seg.buf.?);
        const got = data[0..seg.size];
        try testing.expectEqual(va.SUCCESS, d.unmapBuffer(coded));
        // the uncompressed header: frame marker, profile 0, not an existing
        // frame, the frame type, shown, error resilient; a key frame's sync
        try testing.expectEqual(@as(u8, 0b10_00_0), got[0] >> 3);
        try testing.expectEqual(n != 0, got[0] & 0b100 != 0);
        try testing.expect(got[0] & 0b11 == 0b11);
        if (n == 0) try testing.expectEqualSlices(u8, &.{ 0x49, 0x83, 0x42 }, got[1..4]);
        // the encoder alone, on the surface's own picture
        const ci = ctx - driver.CONTEXT_BASE;
        const c = &d.contexts[ci];
        const s = &d.surfaces[in[n] - driver.SURFACE_BASE];
        const sw = s.layout.swizzles(.blackwell);
        const surf = enc_vp9.Surface{ .luma = 0, .chroma = @intCast(s.layout.chroma_offset), .pitch_luma = s.layout.luma.pitch, .pitch_chroma = s.layout.chroma.pitch, .swz_luma = @intFromEnum(sw[0]), .swz_chroma = @intFromEnum(sw[1]), .gobs = tiling.BLOCK_GOBS_LOG2 };
        var eng = enc_vp9.CpuEngine{ .mem = mem_buf[0..lay.mem_bytes], .info = info_buf[0..lay.info_bytes], .surf = s.tiled.bytes() };
        const st = try enc_vp9.encodeFrame(&ref_enc, &eng, surf, .{ .key = n == 0, .q = Q }, &mine, &scratch_buf);
        try testing.expectEqualSlices(u8, mine[0..st.bytes], got);
        if (n > 0) try testing.expect(st.inter_blocks > 0);
        n_ivf += ivfFrame(ivf[n_ivf..], got, n);
        reconOf9(c, c.vpx.vp9.lastSlot(), recon[n * FRAME_BYTES ..][0..FRAME_BYTES]);
        try testing.expect(c.vpx_engine == .cpu);
    }
    enc_test.writeFile("/tmp/galaxy-va-enc/vp9.ivf", ivf[0..n_ivf]);
    enc_test.writeFile("/tmp/galaxy-va-enc/vp9-recon.yuv", &recon);
    enc_test.writeFile("/tmp/galaxy-va-enc/vp9-input.yuv", &yuv);
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(coded));
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}

test "vpx: VP9 CBR: the rate control holds the stream near its rate" {
    var k = Fake{};
    var d: D = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{.{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR }};
    try testing.expectEqual(va.SUCCESS, d.createConfig(vav9.PROFILE_VP9_PROFILE0, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    var in: [FRAMES]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, W, H, &in, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, W, H, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    for (0..FRAMES) |n| try putInput(&d, in[n], @intCast(n));
    var seq = std.mem.zeroes(enc_vpx.SeqVp9);
    seq.max_frame_width = W;
    seq.max_frame_height = H;
    seq.bits_per_second = 60_000;
    seq.intra_period = 30;
    var rc = std.mem.zeroes(ve.RateControl);
    rc.bits_per_second = 60_000;
    rc.target_percentage = 100;
    var fr = std.mem.zeroes(ve.FrameRate);
    fr.framerate = 30 | (1 << 16);
    var total: usize = 0;
    const N = 60;
    var qs: [N]u8 = undefined;
    for (0..N) |n| {
        var pic = std.mem.zeroes(enc_vpx.PicVp9);
        pic.coded_buf = coded;
        pic.reconstructed_frame = in[0];
        for (&pic.reference_frames) |*r| r.* = va.INVALID_ID;
        pic.refresh_frame_flags = 0xff;
        pic.luma_ac_qindex = 120;
        pic.ref_flags = if (n == 0) 1 else (1 << 1);
        pic.pic_flags = @as(u32, @intFromBool(n != 0)) | (1 << 1);
        var ids = [_]u32{
            try createBuf(&d, ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq),
            try createBuf(&d, ve.ENC_PICTURE_PARAMETER_BUFFER, &pic),
            try miscBuf(&d, ve.MISC_RATE_CONTROL, &rc),
            try miscBuf(&d, ve.MISC_FRAME_RATE, &fr),
        };
        try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, in[n % FRAMES]));
        try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, &ids));
        try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
        for (ids) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
        var p: ?*anyopaque = null;
        try testing.expectEqual(va.SUCCESS, d.mapBuffer(coded, &p));
        const seg: *const ve.CodedBufferSegment = @ptrCast(@alignCast(p.?));
        total += seg.size;
        try testing.expectEqual(va.SUCCESS, d.unmapBuffer(coded));
        qs[n] = d.contexts[ctx - driver.CONTEXT_BASE].vpx.vp9.last.q;
    }
    // the stream within half of the target either way; the quantizer moved
    // from the app's 120
    const rate = @as(f64, @floatFromInt(total * 8)) / (@as(f64, N) / 30.0);
    try testing.expect(rate > 60_000 * 0.5 and rate < 60_000 * 1.5);
    try testing.expect(qs[N - 1] != 120 or qs[N / 2] != 120);
}
