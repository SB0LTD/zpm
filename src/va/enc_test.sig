//! @zpm/va enc_test — the encoder through the driver and a pretend NVENC:
//! H.264 with B pictures (real I_PCM macroblocks, so FFmpeg decodes the
//! stream back to the input in display order: /tmp/galaxy-va-enc/
//! h264-b.264 against h264-b.yuv), HEVC's B-picture setup, and surfaces
//! made over an app's dma-bufs (block linear read in place, linear
//! converted), and AV1's headers.

const std = @import("std");
const linux = std.os.linux;
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const node = @import("node.sig");
const tiling = @import("tiling.sig");
const bits = @import("bits.sig");
const nvenc = @import("nvenc.sig");
const encode = @import("encode.sig");
const enc_h264 = @import("enc_h264.sig");
const enc_hevc = @import("enc_hevc.sig");
const enc_import = @import("enc_import.sig");
const driver = @import("driver.sig");

const testing = std.testing;
const Fake = node.Fake;

/// The fake kernel, and DRM's PRIME import and nv_drm's G_BUFFER_INFO on
/// top (an fd is 100 + a handle, as the fake's export gives it).
pub const ImportFake = struct {
    k: *Fake,
    imports: u32 = 0,

    pub fn open(s: *ImportFake, p: [*:0]const u8) i64 {
        return s.k.open(p);
    }
    pub fn close(s: *ImportFake, fd: i32) void {
        s.k.close(fd);
    }
    pub fn dup(s: *ImportFake, fd: i32) i64 {
        return s.k.dup(fd);
    }
    pub fn ioctl(s: *ImportFake, fd: i32, req: u32, a: []u8) i64 {
        switch (req) {
            enc_import.PRIME_FD_TO_HANDLE => {
                const h = @as(i64, @as(i32, @bitCast(node.rd32(a, 8)))) - 100;
                if (h <= 0 or h >= s.k.bufs.len or s.k.bufs[@intCast(h)].mem.len == 0) return -9;
                node.wr32(a, 0, @intCast(h));
                s.imports += 1;
                return 0;
            },
            enc_import.G_BUFFER_INFO => {
                const h = node.rd32(a, 0);
                if (h == 0 or h >= s.k.bufs.len or s.k.bufs[h].mem.len == 0) return -22;
                node.wr64(a, 8, s.k.bufs[h].va);
                node.wr64(a, 16, @as(u64, h) << 32);
                node.wr64(a, 24, s.k.bufs[h].mem.len);
                return 0;
            },
            else => return s.k.ioctl(fd, req, a),
        }
    }
    pub fn mapBuffer(s: *ImportFake, fd: i32, len: usize, off: u64) i64 {
        return s.k.mapBuffer(fd, len, off);
    }
    pub fn unmap(s: *ImportFake, where: usize, len: usize) void {
        s.k.unmap(where, len);
    }
    pub fn reserve(s: *ImportFake, len: usize) i64 {
        return s.k.reserve(len);
    }
    pub fn discard(s: *ImportFake, where: usize, len: usize) void {
        s.k.discard(where, len);
    }
    pub fn nowNs(s: *ImportFake) i64 {
        return s.k.nowNs();
    }
    pub fn say(s: *ImportFake, line: []const u8) void {
        s.k.say(line);
    }
    pub fn yield(s: *ImportFake) void {
        s.k.yield();
    }
};

const D = driver.Driver(*ImportFake);

// ── The pretend encoder ─────────────────────────────────────────────────────

const Seen = struct {
    methods: [0x800 / 4]u32 = [_]u32{0} ** (0x800 / 4),
    app: u32 = 0,
    pictures: u32 = 0,
    setup: [nvenc.SETUP_BYTES]u8 = [_]u8{0} ** nvenc.SETUP_BYTES,
};
var seen: Seen = .{};

fn methodsOf(push: []const u32) [0x800 / 4]u32 {
    var m = [_]u32{0} ** (0x800 / 4);
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

fn at(k: *Fake, m: []const u32, method: u32, len: usize) []u8 {
    return k.at(@as(u64, m[method >> 2]) << 8, len).?;
}

/// The pretend NVENC: reads the methods and the setup, writes a slice
/// (H.264: I_PCM macroblocks of the block-linear input, in an I, P or B
/// slice as the setup says; HEVC, AV1: a few bytes) where the setup says,
/// with its size in the status.
fn fakeEncode(k: *Fake, sub: Fake.Submit) void {
    const m = methodsOf(k.push(sub));
    if (m[nvenc.SET_IN_DRV_PIC_SETUP >> 2] == 0) return;
    seen.methods = m;
    seen.app = m[nvenc.SET_APPLICATION_ID >> 2];
    seen.pictures += 1;
    const setup = at(k, &m, nvenc.SET_IN_DRV_PIC_SETUP, nvenc.SETUP_BYTES);
    @memcpy(&seen.setup, setup);
    const start: usize = @intCast(switch (seen.app) {
        nvenc.APPLICATION_ID_H264 => nvenc.get(setup, nvenc.H264.bitstream_start_pos),
        nvenc.APPLICATION_ID_H265 => nvenc.get(setup, nvenc.H265.bitstream_start_pos),
        else => nvenc.get(setup, nvenc.Av1.bitstream_start_pos),
    });
    const out = at(k, &m, nvenc.SET_OUT_BITSTREAM, start + (64 << 10))[start..];
    const n = switch (seen.app) {
        nvenc.APPLICATION_ID_H264 => pcmSlice(k, &m, setup, out),
        nvenc.APPLICATION_ID_H265 => blob(out, &.{ 0, 0, 0, 1, 0x26, 0x01, 0xaf, 0x80 }),
        // (AV1: tile data, opaque to a header parser)
        else => blob(out, &.{ 0x12, 0x34, 0x56, 0x78, 0x9a }),
    };
    const stat = at(k, &m, nvenc.SET_OUT_ENC_STATUS, nvenc.Stat.SIZE);
    if (seen.app == nvenc.APPLICATION_ID_AV1) {
        nvenc.set(stat, nvenc.Av1Stat.total_bit_count, n * 8);
        nvenc.set(stat, nvenc.Av1Stat.num_tiles, 1);
        nvenc.set(stat, nvenc.Av1Stat.av1_start_qp, nvenc.get(setup, nvenc.Av1.base_q_idx));
        nvenc.set(stat, nvenc.Av1Stat.loop_filter_level, nvenc.get(setup, nvenc.Av1.lf_filter_level));
        nvenc.set(stat, nvenc.Av1Stat.total_intra_cost, 40_000);
        nvenc.set(stat, nvenc.Av1Stat.total_inter_cost, 10_000);
    } else {
        nvenc.set(stat, nvenc.Stat.total_bit_count, n * 8);
        nvenc.set(stat, nvenc.Stat.num_slices, 1);
    }
}

fn blob(out: []u8, b: []const u8) usize {
    @memcpy(out[0..b.len], b);
    return b.len;
}

fn signExtend(v: u64, width: u6) i32 {
    const shift: u6 = 32 - width;
    const x: i32 = @bitCast(@as(u32, @truncate(v)) << @intCast(shift));
    return x >> @intCast(shift);
}

var pcm_rbsp: [32 << 10]u8 = undefined;
var pcm_y: [64 * 64]u8 = undefined;
var pcm_uv: [64 * 32]u8 = undefined;

/// An H.264 slice of I_PCM macroblocks holding the block-linear input,
/// its header made from the setup as the engine would write it.
fn pcmSlice(k: *Fake, m: []const u32, setup: []const u8, out: []u8) usize {
    const H = nvenc.H264;
    const w: usize = @intCast(nvenc.get(setup, H.input_cfg_frame_width_minus1) + 1);
    const h: usize = @intCast(nvenc.get(setup, H.input_cfg_frame_height_minus1) + 1);
    const pitch: u32 = @intCast(nvenc.get(setup, H.input_cfg_sfc_pitch));
    const cpitch: u32 = @intCast(nvenc.get(setup, H.input_cfg_sfc_pitch_chroma));
    const gobs: u5 = @intCast(nvenc.get(setup, H.input_cfg_block_height));
    // (any block height: the plane's own blocks)
    const luma = at(k, m, nvenc.SET_IN_CUR_PIC, 64 << 10);
    const chroma = at(k, m, nvenc.SET_IN_CUR_PIC_CHROMA_U, 32 << 10);
    detile(&pcm_y, w, luma, pitch, gobs, .blackwell8, w, h);
    detile(&pcm_uv, w, chroma, cpitch, gobs, .blackwell16, w, h / 2);
    const pic_type = nvenc.get(setup, H.pic_type);
    const idr = pic_type == 3;
    const intra = pic_type >= 2;
    const b = pic_type == 1;
    const ref = nvenc.get(setup, H.ref_pic_flag) != 0;
    var wr = bits.Writer.init(&pcm_rbsp);
    wr.u(8, if (idr) 0x65 else if (ref) 0x41 else 0x01);
    wr.ue(0); // first_mb_in_slice
    wr.ue(if (intra) 7 else if (b) 6 else 5); // slice_type, all slices
    wr.ue(@intCast(nvenc.get(setup, H.pic_param_set_id)));
    wr.u(@intCast(nvenc.get(setup, H.log2_max_frame_num_minus4) + 4), @intCast(nvenc.get(setup, H.frame_num)));
    if (idr) wr.ue(@intCast(nvenc.get(setup, H.idr_pic_id)));
    if (nvenc.get(setup, H.pic_order_cnt_type) == 0) wr.u(@intCast(nvenc.get(setup, H.log2_max_pic_order_cnt_lsb_minus4) + 4), @intCast(nvenc.get(setup, H.pic_order_cnt_lsb)));
    if (b) wr.flag(true); // direct_spatial_mv_pred_flag
    if (!intra) {
        wr.flag(false); // num_ref_idx_active_override_flag
        wr.flag(false); // ref_pic_list_modification_flag_l0
        if (b) wr.flag(false); // ..._l1
    }
    if (ref) {
        // dec_ref_pic_marking()
        wr.flag(false);
        if (idr) wr.flag(false);
    }
    const init_qp = 26 + signExtend(nvenc.get(setup, H.pic_init_qp_minus26), 6);
    const qp: i32 = @intCast(nvenc.get(setup[nvenc.SLICE_CONTROL_OFF..], nvenc.H264Slice.qp_avr));
    wr.se(qp - init_qp);
    if (nvenc.get(setup, H.deblocking_filter_control_present_flag) != 0) wr.ue(1);
    for (0..(h + 15) / 16) |my| {
        for (0..(w + 15) / 16) |mx| {
            if (!intra) wr.ue(0); // mb_skip_run
            wr.ue(if (intra) 25 else if (b) 48 else 30); // I_PCM
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

/// A block-linear plane of blocks of 2^gobs GOBs into a linear picture.
fn detile(dst: []u8, dst_pitch: usize, src: []const u8, pitch: u32, gobs: u5, s: tiling.Swizzle, width: usize, rows: usize) void {
    const block_rows = @as(usize, tiling.GOB_ROWS) << gobs;
    const block_bytes = @as(usize, tiling.GOB_BYTES) << gobs;
    for (0..rows) |y| {
        for (0..width) |x| {
            const block = (y / block_rows) * (pitch / tiling.GOB_WIDTH) + x / tiling.GOB_WIDTH;
            const gob = (y % block_rows) / tiling.GOB_ROWS;
            dst[y * dst_pitch + x] = src[block * block_bytes + gob * tiling.GOB_BYTES + tiling.gobOffset(s, x % tiling.GOB_WIDTH, y % tiling.GOB_ROWS)];
        }
    }
}

/// The inverse.
fn tile(dst: []u8, src: []const u8, src_pitch: usize, pitch: u32, gobs: u5, s: tiling.Swizzle, width: usize, rows: usize) void {
    const block_rows = @as(usize, tiling.GOB_ROWS) << gobs;
    const block_bytes = @as(usize, tiling.GOB_BYTES) << gobs;
    for (0..rows) |y| {
        for (0..width) |x| {
            const block = (y / block_rows) * (pitch / tiling.GOB_WIDTH) + x / tiling.GOB_WIDTH;
            const gob = (y % block_rows) / tiling.GOB_ROWS;
            dst[block * block_bytes + gob * tiling.GOB_BYTES + tiling.gobOffset(s, x % tiling.GOB_WIDTH, y % tiling.GOB_ROWS)] = src[y * src_pitch + x];
        }
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn pattern(x: usize, y: usize, n: u32) u8 {
    return @truncate(x * 5 + y * 3 + n * 29 + 16);
}

/// Picture `n`'s NV12 (linear, `pitch` a row) and its planar I420 copy.
fn fillNv12(dst: []u8, pitch: usize, uv_at: usize, w: u32, h: u32, n: u32, planar: []u8) void {
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    for (0..h) |y| {
        for (0..w) |x| {
            dst[y * pitch + x] = pattern(x, y, n);
            planar[y * w + x] = pattern(x, y, n);
        }
    }
    for (0..ch) |y| {
        for (0..cw) |x| {
            const u = pattern(x + 7, y + 50, n);
            const v = pattern(x + 90, y + 3, n);
            dst[uv_at + y * pitch + 2 * x] = u;
            dst[uv_at + y * pitch + 2 * x + 1] = v;
            planar[w * h + y * cw + x] = u;
            planar[w * h + cw * ch + y * cw + x] = v;
        }
    }
}

/// The surface's picture put in as an app does (CreateImage, Map, PutImage).
fn putInput(d: *D, surface: u32, w: u32, h: u32, n: u32, planar: []u8) !void {
    var img: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.NV12_FORMAT, w, h, &img));
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(img.buf, &p));
    const b: [*]u8 = @ptrCast(p.?);
    fillNv12(b[img.offsets[0] .. img.offsets[1] + img.pitches[1] * ((h + 1) / 2)], img.pitches[0], img.offsets[1] - img.offsets[0], w, h, n, planar);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(img.buf));
    try testing.expectEqual(va.SUCCESS, d.putImage(surface, img.image_id, 0, 0, w, h, 0, 0, w, h));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
}

fn miscBuffer(d: *D, kind: u32, value: anytype, out: *u32) !void {
    var mb: [4 + 64]u8 = undefined;
    std.mem.writeInt(u32, mb[0..4], kind, .little);
    const bytes = std.mem.asBytes(&value);
    @memcpy(mb[4..][0..bytes.len], bytes);
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_MISC_PARAMETER_BUFFER, @intCast(4 + bytes.len), 1, &mb, out));
}

fn picture(d: *D, ctx: u32, input: u32, bufs: []const [3]usize) !void {
    var ids: [16]u32 = undefined;
    for (bufs, 0..) |b, i| {
        const ptr: *const anyopaque = @ptrFromInt(b[2]);
        try testing.expectEqual(va.SUCCESS, d.createBuffer(@intCast(b[0]), @intCast(b[1]), 1, ptr, &ids[i]));
    }
    try testing.expectEqual(va.SUCCESS, d.beginPicture(ctx, input));
    try testing.expectEqual(va.SUCCESS, d.renderPicture(ctx, ids[0..bufs.len]));
    try testing.expectEqual(va.SUCCESS, d.endPicture(ctx));
    for (ids[0..bufs.len]) |id| try testing.expectEqual(va.SUCCESS, d.destroyBuffer(id));
}

fn buf(kind: u32, value: anytype) [3]usize {
    return .{ kind, @sizeOf(@TypeOf(value.*)), @intFromPtr(value) };
}

fn codedBytes(d: *D, coded: u32, out: []u8) !usize {
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(coded, &p));
    const seg: *const ve.CodedBufferSegment = @ptrCast(@alignCast(p.?));
    try testing.expectEqual(@as(?*anyopaque, null), seg.next);
    const data: [*]const u8 = @ptrCast(seg.buf.?);
    @memcpy(out[0..seg.size], data[0..seg.size]);
    try testing.expectEqual(va.SUCCESS, d.unmapBuffer(coded));
    return seg.size;
}

/// A file for WSL's ffmpeg (no C library: the system calls).
pub fn writeFile(path: [*:0]const u8, data: []const u8) void {
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

fn h264Seq() enc_h264.Seq {
    var s = enc_h264.testSeq(3, 2);
    s.intra_period = 30;
    s.ip_period = 3;
    s.max_num_ref_frames = 2;
    s.frame_cropping_flag = 1;
    s.frame_crop_right_offset = 4;
    s.frame_crop_bottom_offset = 4;
    s.vui_parameters_present_flag = 1;
    s.vui_fields = .{ .timing_info_present_flag = 1, .bitstream_restriction_flag = 1, .log2_max_mv_length_horizontal = 15, .log2_max_mv_length_vertical = 15, .motion_vectors_over_pic_boundaries_flag = 1 };
    s.num_units_in_tick = 1;
    s.time_scale = 60;
    return s;
}

fn ref264(id: u32, poc: i32) va.PictureH264 {
    return .{ .picture_id = id, .frame_idx = 0, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = poc, .BottomFieldOrderCnt = poc };
}

fn slice264(slice_type: u8, poc_lsb: u16, l0: ?va.PictureH264, l1: ?va.PictureH264) ve.EncSliceParameterBufferH264 {
    var s = std.mem.zeroes(ve.EncSliceParameterBufferH264);
    s.num_macroblocks = 6;
    s.slice_type = slice_type;
    s.pic_order_cnt_lsb = poc_lsb;
    s.direct_spatial_mv_pred_flag = 1;
    const none = va.PictureH264{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    for (&s.RefPicList0, &s.RefPicList1) |*a, *b| {
        a.* = none;
        b.* = none;
    }
    if (l0) |r| s.RefPicList0[0] = r;
    if (l1) |r| s.RefPicList1[0] = r;
    return s;
}

var stream: [128 << 10]u8 = undefined;
var yuv: [4 * 40 * 24 * 3 / 2]u8 = undefined;

test "enc: H.264 with B pictures through the pretend encoder: I0 P3 B1 B2, decoded in display order" {
    var k = Fake{ .encoder = fakeEncode };
    var f = ImportFake{ .k = &k };
    seen = .{};
    var d: D = .{ .node = .{ .sys = &f } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{ .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 }, .{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_VBR } };
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    // four inputs, four reconstructions
    var in: [4]u32 = undefined;
    var rec: [4]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &in, &.{}));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &rec, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    const frame = 40 * 24 * 3 / 2;
    for (0..4) |n| try putInput(&d, in[n], 40, 24, @intCast(n), yuv[n * frame ..][0..frame]);
    const seq = h264Seq();
    var rc = std.mem.zeroes(ve.RateControl);
    rc.bits_per_second = 400_000;
    rc.target_percentage = 90;
    var fr = std.mem.zeroes(ve.FrameRate);
    fr.framerate = 30 | (1 << 16);
    // coding order: display 0 (IDR), 3 (P), 1 (B), 2 (B)
    const order = [_]u32{ 0, 3, 1, 2 };
    const frame_num = [_]u16{ 0, 1, 2, 2 };
    var n_out: usize = 0;
    for (order, 0..) |disp, i| {
        const poc: i32 = @intCast(disp * 2);
        const idr = i == 0;
        const is_b = i >= 2;
        var pic = enc_h264.testPic(rec[disp], coded, idr, frame_num[i]);
        pic.CurrPic.TopFieldOrderCnt = poc;
        pic.CurrPic.BottomFieldOrderCnt = poc;
        pic.pic_fields.reference_pic_flag = if (is_b) 0 else 1;
        var sl = slice264(2, @intCast(poc), null, null);
        if (i == 1) {
            pic.ReferenceFrames[0] = ref264(rec[0], 0);
            sl = slice264(0, @intCast(poc), ref264(rec[0], 0), null);
        } else if (is_b) {
            pic.ReferenceFrames[0] = ref264(rec[0], 0);
            pic.ReferenceFrames[1] = ref264(rec[3], 6);
            sl = slice264(1, @intCast(poc), ref264(rec[0], 0), ref264(rec[3], 6));
        }
        if (idr) {
            try picture(&d, ctx, in[disp], &.{ buf(ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq), buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &pic), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &sl) });
        } else {
            try picture(&d, ctx, in[disp], &.{ buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &pic), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &sl) });
        }
        if (is_b) {
            // B: L0 the IDR's slot, L1 the P's; temporal distances either side
            const S = nvenc.H264;
            try testing.expectEqual(@as(u64, 1), nvenc.get(&seen.setup, S.pic_type));
            try testing.expectEqual(@as(u64, 0), nvenc.get(&seen.setup, S.ref_pic_flag));
            try testing.expectEqual(@as(u64, 0), nvenc.get(&seen.setup, nvenc.at(S.l0, 0)));
            try testing.expectEqual(@as(u64, 1), nvenc.get(&seen.setup, nvenc.at(S.l1, 0)));
            const td1 = signExtend(nvenc.get(&seen.setup, nvenc.at(S.temp_dist_l1, 0)), 8);
            try testing.expectEqual(poc - 6, td1);
            // DistScaleFactor[0][0]: tb = poc, td = 6: (16384 + 3) / 6 = 2731; (poc * 2731 + 32) >> 6
            const dsf = signExtend(nvenc.get(&seen.setup, S.dist_scale_factor), 16);
            try testing.expectEqual((poc * 2731 + 32) >> 6, dsf);
            // the collocated picture's motion: the P's (L1[0]) buffer
            const p_out = seen_coloc_p;
            try testing.expectEqual(p_out, seen.methods[nvenc.SET_IN_COLOC_DATA >> 2]);
            // both references bound (slots 0 and 1)
            try testing.expect(seen.methods[nvenc.SET_IN_REF_PIC0_LUMA >> 2] != 0);
            try testing.expect(seen.methods[(nvenc.SET_IN_REF_PIC0_LUMA + 4) >> 2] != 0);
        }
        if (i == 1) seen_coloc_p = seen.methods[nvenc.SET_OUT_COLOC_DATA >> 2];
        n_out += try codedBytes(&d, coded, stream[n_out..]);
    }
    try testing.expectEqual(@as(u32, 0), d.errors);
    // the SPS says two pictures may wait for reordering
    writeFile("/tmp/galaxy-va-enc/h264-b.264", stream[0..n_out]);
    writeFile("/tmp/galaxy-va-enc/h264-b.yuv", &yuv);
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(coded));
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}

var seen_coloc_p: u32 = 0;

/// One IDR picture of the 40x24 test sequence from surface `input` into
/// `coded`, its stream appended to `out`.
fn idr264(d: *D, ctx: u32, input: u32, recon: u32, coded: u32, out: []u8) !usize {
    const seq = h264Seq();
    const pic = enc_h264.testPic(recon, coded, true, 0);
    const sl = slice264(2, 0, null, null);
    try picture(d, ctx, input, &.{ buf(ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq), buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &pic), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &sl) });
    return codedBytes(d, coded, out);
}

/// A DRM_PRIME_2 descriptor of one NV12 picture: two objects (two fds),
/// each its modifier.
fn prime2(fd: [2]i32, size: u32, off: [2]u32, pitch: u32, mods: [2]u64, w: u32, h: u32) va.DrmPrimeDescriptor {
    var dd = std.mem.zeroes(va.DrmPrimeDescriptor);
    dd.fourcc = va.FOURCC_NV12;
    dd.width = w;
    dd.height = h;
    dd.num_objects = 2;
    dd.objects[0] = .{ .fd = fd[0], .size = size, .drm_format_modifier = mods[0] };
    dd.objects[1] = .{ .fd = fd[1], .size = size, .drm_format_modifier = mods[1] };
    dd.num_layers = 2;
    dd.layers[0] = .{ .drm_format = va.DRM_FORMAT_R8, .num_planes = 1, .object_index = .{ 0, 0, 0, 0 }, .offset = .{ off[0], 0, 0, 0 }, .pitch = .{ pitch, 0, 0, 0 } };
    dd.layers[1] = .{ .drm_format = va.DRM_FORMAT_GR88, .num_planes = 1, .object_index = .{ 1, 0, 0, 0 }, .offset = .{ off[1], 0, 0, 0 }, .pitch = .{ pitch, 0, 0, 0 } };
    return dd;
}

fn importAttribs(mem: u32, p: *anyopaque) [2]va.SurfaceAttrib {
    return .{
        driver.intAttrib(va.SURFACE_ATTRIB_MEMORY_TYPE, va.SURFACE_ATTRIB_SETTABLE, mem),
        .{ .type = va.SURFACE_ATTRIB_EXTERNAL_BUFFER_DESCRIPTOR, .flags = va.SURFACE_ATTRIB_SETTABLE, .value = .{ .type = va.GENERIC_POINTER, .value = .{ .p = p } } },
    };
}

var y4m_a: [40 * 24 * 3 / 2]u8 = undefined;
var y4m_b: [40 * 24 * 3 / 2]u8 = undefined;
var lin_tmp: [64 * 24 * 2]u8 = undefined;

test "enc: an app's dma-bufs as encoder input: block linear read in place (16-GOB blocks), linear converted" {
    var k = Fake{ .encoder = fakeEncode };
    var f = ImportFake{ .k = &k };
    seen = .{};
    var d: D = .{ .node = .{ .sys = &f } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_H264_MAIN, ve.ENTRYPOINT_ENC_SLICE, &.{}, &cfg));
    var rec: [2]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &rec, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 40, 24, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));

    // ── block linear: a camera frame in the GPU's own layout, blocks of
    // 16 GOBs (128 rows), Y and UV in two dma-bufs ──
    const pitch: u32 = 64;
    var y_buf = d.node.alloc(1, node.G_VRAM).?;
    var uv_buf = d.node.alloc(1, node.G_VRAM).?;
    @memset(y_buf.bytes(), 0);
    @memset(uv_buf.bytes(), 0);
    fillNv12(&lin_tmp, pitch, pitch * 24, 40, 24, 3, &y4m_a);
    tile(y_buf.bytes(), &lin_tmp, pitch, pitch, 4, .blackwell8, 40, 24);
    tile(uv_buf.bytes(), lin_tmp[pitch * 24 ..], pitch, pitch, 4, .blackwell16, 40, 12);
    const mods = [2]u64{ tiling.nvidiaBlockLinear2d(0, 2, 2, 6, 4), tiling.nvidiaBlockLinear2d(0, 3, 2, 6, 4) };
    var desc = prime2(.{ @intCast(100 + y_buf.handle), @intCast(100 + uv_buf.handle) }, @intCast(y_buf.len), .{ 0, 0 }, pitch, mods, 40, 24);
    var in_bl: [1]u32 = undefined;
    const at2 = importAttribs(va.MEM_TYPE_DRM_PRIME_2, &desc);
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &in_bl, &at2));
    try testing.expectEqual(@as(u32, 2), f.imports);
    const conversions = d.conversions;
    var out: [16 << 10]u8 = undefined;
    const n = try idr264(&d, ctx, in_bl[0], rec[0], coded, &out);
    // the engine read the app's planes where they are, at their block height
    try testing.expectEqual(nvenc.shifted(y_buf.va), seen.methods[nvenc.SET_IN_CUR_PIC >> 2]);
    try testing.expectEqual(nvenc.shifted(uv_buf.va), seen.methods[nvenc.SET_IN_CUR_PIC_CHROMA_U >> 2]);
    try testing.expectEqual(@as(u64, 4), nvenc.get(&seen.setup, nvenc.H264.input_cfg_block_height));
    try testing.expectEqualSlices(u32, &conversions, &d.conversions);
    writeFile("/tmp/galaxy-va-enc/h264-import-bl.264", out[0..n]);
    writeFile("/tmp/galaxy-va-enc/h264-import-bl.yuv", &y4m_a);

    // ── pitch linear: VASurfaceAttribExternalBuffers, one fd ──
    var lin_buf = d.node.alloc(1, 0).?;
    fillNv12(lin_buf.bytes(), pitch, pitch * 24, 40, 24, 9, &y4m_b);
    var fds = [_]usize{100 + lin_buf.handle};
    var ext = std.mem.zeroes(enc_import.ExternalBuffers);
    ext.pixel_format = va.FOURCC_NV12;
    ext.width = 40;
    ext.height = 24;
    ext.data_size = pitch * 36;
    ext.num_planes = 2;
    ext.pitches = .{ pitch, pitch, 0, 0 };
    ext.offsets = .{ 0, pitch * 24, 0, 0 };
    ext.buffers = &fds;
    ext.num_buffers = 1;
    var in_lin: [1]u32 = undefined;
    const at1 = importAttribs(va.MEM_TYPE_DRM_PRIME, &ext);
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &in_lin, &at1));
    const m = try idr264(&d, ctx, in_lin[0], rec[1], coded, &out);
    // converted into the surface's own block-linear planes (the CPU's
    // converter here; the GPU's in the library), each encode
    try testing.expect(d.conversions[1] > conversions[1]);
    try testing.expect(seen.methods[nvenc.SET_IN_CUR_PIC >> 2] != nvenc.shifted(lin_buf.va));
    writeFile("/tmp/galaxy-va-enc/h264-import-lin.264", out[0..m]);
    writeFile("/tmp/galaxy-va-enc/h264-import-lin.yuv", &y4m_b);
    // (a compressed modifier, an odd plane offset: refused)
    var bad = prime2(.{ @intCast(100 + y_buf.handle), @intCast(100 + uv_buf.handle) }, @intCast(y_buf.len), .{ 0, 0 }, pitch, .{ tiling.nvidiaBlockLinear2d(1, 2, 2, 6, 1), mods[1] }, 40, 24);
    var none: [1]u32 = undefined;
    const at3 = importAttribs(va.MEM_TYPE_DRM_PRIME_2, &bad);
    try testing.expectEqual(va.ERROR_UNSUPPORTED_MEMORY_TYPE, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &none, &at3));
    try testing.expectEqual(@as(u32, 0), d.errors);
    try testing.expectEqual(va.SUCCESS, d.destroySurfaces(&in_bl));
    try testing.expectEqual(va.SUCCESS, d.destroySurfaces(&in_lin));
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(coded));
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}

test "enc: HEVC B picture's setup: the RPS both sides, the lists, the collocated picture" {
    const seq = enc_hevc.testSeq(64, 48);
    var pic = enc_hevc.testPic(0x403, 0x1000, false, 4);
    pic.pic_fields.coding_type = 3;
    pic.pic_fields.reference_pic_flag = 0;
    pic.nal_unit_type = 0; // TRAIL_N
    pic.reference_frames[0] = .{ .picture_id = 0x400, .pic_order_cnt = 0, .flags = 0 };
    pic.reference_frames[1] = .{ .picture_id = 0x401, .pic_order_cnt = 8, .flags = 0 };
    var sl = enc_hevc.Slice{ .num_ctu = 4, .slice_type = 0, .collocated_from_l0 = false };
    sl.ref0[0] = 0x400;
    sl.ref1[0] = 0x401;
    var refs = [_]u32{va.INVALID_ID} ** nvenc.REF_SLOTS;
    refs[0] = 0x400;
    refs[1] = 0x401;
    var poc = [_]i32{0} ** nvenc.REF_SLOTS;
    poc[1] = 8;
    var b: [nvenc.SETUP_BYTES]u8 = undefined;
    const planes = enc_h264.Planes{ .luma = 0, .chroma = 0, .pitch_luma = 64, .pitch_chroma = 64 };
    // (an app's SPS with a 16-bit POC LSB)
    enc_hevc.setup(&b, .{ .seq = &seq, .pic = &pic, .slices = &.{sl}, .input = planes, .recon = planes, .ref_ids = refs, .ref_poc = poc, .params = .{ .have_sps = true, .log2_max_poc_lsb_minus4 = 12, .temporal_mvp = true }, .collocated_id = 0x401, .qp = 30, .gop_length = 30, .framerate = 30, .bitstream_start = 0, .bitstream_room = 1 << 20, .history_bytes = 4096 });
    const H = nvenc.H265;
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, H.pic_type)); // B
    try testing.expectEqual(@as(u64, 12), nvenc.get(&b, H.log2_max_pic_order_cnt_lsb_minus4));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, H.st_num_negative_pics));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, H.st_num_positive_pics));
    try testing.expectEqual(@as(u64, 3), nvenc.get(&b, H.st_delta_poc_s0_minus1)); // 4 - 0 - 1
    try testing.expectEqual(@as(u64, 3), nvenc.get(&b, H.st_delta_poc_s1_minus1)); // 8 - 4 - 1
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, H.st_used_by_curr_pic_s0_flag));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, H.st_used_by_curr_pic_s1_flag));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, nvenc.at(H.l1, 0)));
    try testing.expectEqual(@as(u64, 0xfc), nvenc.get(&b, nvenc.at(H.temp_dist_l1, 0))); // -4
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, nvenc.at(H.poc_entry_l1, 0))); // S1's first: entry 1
    try testing.expectEqual(@as(u64, 0), nvenc.get(&b, nvenc.at(H.poc_entry_l0, 0)));
    try testing.expectEqual(@as(u64, 4), nvenc.get(&b, H.pic_order_cnt_lsb));
    const c = b[nvenc.SLICE_CONTROL_OFF..];
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H265Slice.slice_type));
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H265Slice.collocated_from_l0_flag));
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H265Slice.collocated_ref_idx));
    try testing.expectEqual(va.ERROR_MAX_NUM_EXCEEDED, enc_hevc.checkSlices(&.{.{ .slice_type = 0, .l1_minus1 = 1 }}));
}

// ── AV1 ─────────────────────────────────────────────────────────────────────

const enc_av1 = @import("enc_av1.sig");

var av1_stream: [64 << 10]u8 = undefined;

test "enc: AV1 through the pretend encoder: a key frame, a hidden P, a B, the P shown after; the OBUs" {
    var k = Fake{ .encoder = fakeEncode };
    var f = ImportFake{ .k = &k };
    seen = .{};
    var d: D = .{ .node = .{ .sys = &f } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    // FFmpeg's questions: the AV1 attributes (Ext2 it requires)
    var attribs = [_]va.ConfigAttrib{
        .{ .type = ve.ATTRIB_ENC_AV1_EXT2, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = 0 },
        .{ .type = ve.ATTRIB_ENC_MAX_REF_FRAMES, .value = 0 },
    };
    try testing.expectEqual(va.SUCCESS, d.getConfigAttributes(enc_av1.PROFILE, ve.ENTRYPOINT_ENC_SLICE, &attribs));
    try testing.expectEqual(enc_av1.ATTRIB_EXT2, attribs[0].value);
    try testing.expectEqual(enc_av1.PACKED_HEADERS, attribs[1].value);
    try testing.expectEqual(@as(u32, 4 | (3 << 16)), attribs[2].value);
    var cfg: u32 = 0;
    const attrs = [_]va.ConfigAttrib{ .{ .type = ve.ATTRIB_RATE_CONTROL, .value = ve.RC_CBR }, .{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_PICTURE } };
    try testing.expectEqual(va.SUCCESS, d.createConfig(enc_av1.PROFILE, ve.ENTRYPOINT_ENC_SLICE, &attrs, &cfg));
    var in: [3]u32 = undefined;
    var rec: [3]u32 = undefined;
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 256, 192, &in, &.{}));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420, 256, 192, &rec, &.{}));
    var ctx: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createContext(cfg, 256, 192, &ctx));
    var coded: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createBuffer(ve.ENC_CODED_BUFFER, 1 << 20, 1, null, &coded));
    var seq = enc_av1.testSeq();
    seq.bits_per_second = 1_000_000;
    seq.ip_period = 2;
    const tg = std.mem.zeroes(ve.EncTileGroupBufferAV1);
    var n: usize = 0;
    // ── key frame (order 0) into slot 0 .. 7 ──
    var p0 = enc_av1.testPic(rec[0], coded, true, 0);
    try picture(&d, ctx, in[0], &.{ buf(ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq), buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &p0), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &tg) });
    try testing.expectEqual(nvenc.APPLICATION_ID_AV1, seen.app);
    try testing.expectEqual(nvenc.CODEC_TYPE_AV1 | nvenc.CONTROL_GPTIMER_ON, seen.methods[nvenc.SET_CONTROL_PARAMS >> 2]);
    try testing.expectEqual(@as(u64, 3), nvenc.get(&seen.setup, nvenc.Av1.pic_type));
    // the CDFs: the defaults in, the reconstruction's own table out; the line buffers bound
    try testing.expect(seen.methods[nvenc.SET_IN_AV1_PROBABILITY_DATA >> 2] != 0);
    const key_cdf = seen.methods[nvenc.SET_OUT_AV1_PROBABILITY_DATA >> 2];
    try testing.expect(key_cdf != 0 and seen.methods[nvenc.SET_IOLR_LEFTCOLUMN >> 2] != 0);
    const q0 = nvenc.get(&seen.setup, nvenc.Av1.base_q_idx);
    try testing.expect(q0 >= 1 and q0 <= 255);
    n += try codedBytes(&d, coded, av1_stream[n..]);
    // TD, the driver's sequence header, the frame header, the tile group
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x00, 0x0a }, av1_stream[0..3]);
    // ── P (order 2), hidden: refreshes slot 1 ──
    var p2 = enc_av1.testPic(rec[2], coded, false, 2);
    p2.reference_frames[0] = rec[0];
    p2.ref_frame_idx = .{ 0, 0, 0, 0, 0, 0, 0 };
    p2.primary_ref_frame = 0;
    p2.refresh_frame_flags = 2;
    try picture(&d, ctx, in[2], &.{ buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &p2), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &tg) });
    try testing.expectEqual(@as(u64, 0), nvenc.get(&seen.setup, nvenc.Av1.pic_type)); // P
    // (starts from the key frame's adapted CDFs)
    try testing.expectEqual(key_cdf, seen.methods[nvenc.SET_IN_AV1_PROBABILITY_DATA >> 2]);
    const m2 = try codedBytes(&d, coded, av1_stream[n..]);
    // a temporal delimiter (the key frame was shown), then the header: not shown
    try testing.expectEqual(@as(u8, 0x12), av1_stream[n]);
    n += m2;
    // ── B (order 1): LAST the key frame, BWDREF the P; shown, then the P ──
    var p1 = enc_av1.testPic(rec[1], coded, false, 1);
    p1.reference_frames[0] = rec[0];
    p1.reference_frames[1] = rec[2];
    p1.ref_frame_idx = .{ 0, 0, 0, 0, 1, 1, 1 };
    p1.primary_ref_frame = 0;
    p1.refresh_frame_flags = 0;
    p1.ref_frame_ctrl_l0 = 1;
    p1.ref_frame_ctrl_l1 = 5;
    p1.mode_control_flags.reference_mode = 2;
    p1.picture_flags.disable_frame_recon = 1;
    try picture(&d, ctx, in[1], &.{ buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &p1), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &tg) });
    try testing.expectEqual(@as(u64, 1), nvenc.get(&seen.setup, nvenc.Av1.pic_type)); // B
    try testing.expectEqual(@as(u64, 1), nvenc.get(&seen.setup, nvenc.Av1.num_ref_idx_l1_active));
    const m1 = try codedBytes(&d, coded, av1_stream[n..]);
    // no temporal delimiter (same temporal unit as the hidden P); the P
    // shown after it: TD, show_existing_frame of slot 1
    try testing.expect(av1_stream[n] != 0x12);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x00, 0x1a, 0x01, 0x98 }, av1_stream[n + m1 - 5 ..][0..5]);
    n += m1;
    try testing.expectEqual(@as(u32, 0), d.errors);
    writeFile("/tmp/galaxy-va-enc/av1.obu", av1_stream[0..n]);
    try testing.expectEqual(va.SUCCESS, d.destroyBuffer(coded));
    try testing.expectEqual(va.SUCCESS, d.destroyContext(ctx));
}
