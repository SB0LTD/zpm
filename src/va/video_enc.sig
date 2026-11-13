//! @zpm/va video_enc — the RTX's encoders for apps that hold pictures, not
//! VA-API buffers: Galaxy's Media Foundation encoder MFTs (galaxy-pe's
//! NtGalaxyVideo), or any native recorder. An Encoder takes NV12 pictures
//! in display order and gives back each one's coded bytes: H.264 (Annex B,
//! SPS and PPS before each IDR: NVENC), VP8 and VP9 (one frame each: the
//! RTX's compute engine, KIR kernels). It drives the driver as FFmpeg's
//! vaapi encoders do, the simplest way a real-time encoder does: every
//! picture a reference for the next (I then P..., an IDR / key frame every
//! `gop`, or when asked), no B pictures, so a picture's bytes come back
//! before the next goes in; the rate is the driver's control (CBR at
//! `bitrate`, or constant QP).
//!
//! Generic over the driver type; allocation-free (fixed surfaces and one
//! coded buffer, the driver's pools).

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const enc_vpx = @import("enc_vpx.sig");
const vav8 = @import("vaapi_vp8.sig");
const vav9 = @import("vaapi_vp9.sig");

pub const Codec = @import("video.sig").Codec;

pub const Status = enum(u32) { ok = 0, unsupported = 3, failed = 4, bad = 5 };

pub const Params = struct {
    codec: Codec,
    width: u32,
    height: u32,
    fps_num: u32 = 30,
    fps_den: u32 = 1,
    /// bits a second; 0: constant QP `qp`
    bitrate: u32 = 0,
    qp: u32 = 26,
    /// a key frame every `gop` (0: only the first)
    gop: u32 = 60,
    /// H.264: 66, 77 or 100 (0: High)
    profile: u32 = 0,
};

pub fn Encoder(comptime D: type) type {
    return struct {
        const Self = @This();

        drv: *D,
        p: Params = undefined,
        config: u32 = 0,
        context: u32 = 0,
        coded: u32 = 0,
        input: u32 = 0,
        recon: [2]u32 = .{ 0, 0 },
        image: va.Image = undefined,
        have_image: bool = false,
        /// pictures encoded; the reconstructed one the next refers to
        n: u64 = 0,
        since_key: u32 = 0,
        last: usize = 0,
        idr_id: u16 = 0,
        /// the last picture's bytes are in the coded buffer
        ready: bool = false,
        key: bool = false,
        pts: i64 = 0,
        duration: i64 = 0,

        pub fn init(self: *Self, drv: *D, p: Params) Status {
            self.* = .{ .drv = drv, .p = p };
            const profile: va.Profile = switch (p.codec) {
                .h264 => switch (p.profile) {
                    66 => va.PROFILE_H264_CONSTRAINED_BASELINE,
                    77 => va.PROFILE_H264_MAIN,
                    else => va.PROFILE_H264_HIGH,
                },
                .vp8 => vav8.PROFILE_VP8_VERSION0_3,
                .vp9 => vav9.PROFILE_VP9_PROFILE0,
                else => return .unsupported,
            };
            if (p.width < 16 or p.height < 16 or p.width > 4096 or p.height > 4096 or p.width % 2 != 0 or p.height % 2 != 0) return .unsupported;
            const d = drv;
            const attrs = [_]va.ConfigAttrib{
                .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 },
                .{ .type = ve.ATTRIB_RATE_CONTROL, .value = if (p.bitrate > 0) ve.RC_CBR else ve.RC_CQP },
            };
            if (d.createConfig(profile, ve.ENTRYPOINT_ENC_SLICE, &attrs, &self.config) != va.SUCCESS) return .unsupported;
            var in: [1]u32 = undefined;
            if (d.createSurfaces(va.RT_FORMAT_YUV420, p.width, p.height, &in, &.{}) != va.SUCCESS) {
                self.deinit();
                return .failed;
            }
            self.input = in[0];
            if (d.createSurfaces(va.RT_FORMAT_YUV420, p.width, p.height, &self.recon, &.{}) != va.SUCCESS) {
                self.deinit();
                return .failed;
            }
            if (d.createContext(self.config, p.width, p.height, &self.context) != va.SUCCESS) {
                self.deinit();
                return .unsupported;
            }
            const coded_bytes: u32 = @intCast(@max(p.width * p.height * 3 / 2, 64 << 10) + (64 << 10));
            if (d.createBuffer(ve.ENC_CODED_BUFFER, coded_bytes, 1, null, &self.coded) != va.SUCCESS) {
                self.deinit();
                return .failed;
            }
            if (d.createImage(&va.NV12_FORMAT, p.width, p.height, &self.image) != va.SUCCESS) {
                self.deinit();
                return .failed;
            }
            self.have_image = true;
            return .ok;
        }

        pub fn deinit(self: *Self) void {
            const d = self.drv;
            if (self.have_image) _ = d.destroyImage(self.image.image_id);
            if (self.coded != 0) _ = d.destroyBuffer(self.coded);
            if (self.context != 0) _ = d.destroyContext(self.context);
            if (self.recon[0] != 0) _ = d.destroySurfaces(&self.recon);
            if (self.input != 0) _ = d.destroySurfaces(&.{self.input});
            if (self.config != 0) _ = d.destroyConfig(self.config);
            self.have_image = false;
            self.coded = 0;
            self.context = 0;
            self.recon = .{ 0, 0 };
            self.input = 0;
            self.config = 0;
        }

        /// One NV12 picture (`pitch` bytes a row, chroma after `height`
        /// rows) encoded; its bytes then wait for `take`.
        pub fn encode(self: *Self, nv12: []const u8, pitch: u32, pts: i64, duration: i64, force_key: bool) Status {
            const d = self.drv;
            const p = self.p;
            if (pitch < p.width or @as(u64, pitch) * p.height * 3 / 2 > nv12.len) return .bad;
            // the picture into the input surface (the image, then PutImage)
            var mp: ?*anyopaque = null;
            if (d.mapBuffer(self.image.buf, &mp) != va.SUCCESS) return .failed;
            const dst: [*]u8 = @ptrCast(mp.?);
            const ip = self.image.pitches;
            const io = self.image.offsets;
            for (0..p.height) |r| @memcpy(dst[io[0] + r * ip[0] ..][0..p.width], nv12[r * pitch ..][0..p.width]);
            for (0..p.height / 2) |r| @memcpy(dst[io[1] + r * ip[1] ..][0..p.width], nv12[(p.height + r) * pitch ..][0..p.width]);
            _ = d.unmapBuffer(self.image.buf);
            if (d.putImage(self.input, self.image.image_id, 0, 0, p.width, p.height, 0, 0, p.width, p.height) != va.SUCCESS) return .failed;

            const key = self.n == 0 or force_key or (p.gop > 0 and self.since_key >= p.gop);
            const cur = if (self.n == 0) 0 else 1 - self.last;
            const ok = switch (p.codec) {
                .h264 => self.h264(key, cur),
                .vp8 => self.vp8(key, cur),
                .vp9 => self.vp9(key, cur),
                else => false,
            };
            if (!ok) return .failed;
            self.last = cur;
            self.n += 1;
            self.since_key = if (key) 1 else self.since_key + 1;
            self.ready = true;
            self.key = key;
            self.pts = pts;
            self.duration = duration;
            return .ok;
        }

        /// The last picture's bytes into `out` (its length; 0: none, or
        /// `out` too small: `need` says how many).
        pub fn take(self: *Self, out: []u8, need: *u32) usize {
            if (!self.ready) return 0;
            const d = self.drv;
            var mp: ?*anyopaque = null;
            if (d.mapBuffer(self.coded, &mp) != va.SUCCESS) {
                self.ready = false;
                return 0;
            }
            defer _ = d.unmapBuffer(self.coded);
            var total: usize = 0;
            var seg: ?*const ve.CodedBufferSegment = @ptrCast(@alignCast(mp));
            while (seg) |s| : (seg = @ptrCast(@alignCast(s.next))) total += s.size;
            need.* = @intCast(total);
            if (total > out.len) return 0;
            var at: usize = 0;
            seg = @ptrCast(@alignCast(mp));
            while (seg) |s| : (seg = @ptrCast(@alignCast(s.next))) {
                const b: [*]const u8 = @ptrCast(s.buf.?);
                @memcpy(out[at..][0..s.size], b[0..s.size]);
                at += s.size;
            }
            self.ready = false;
            return at;
        }

        fn misc(d: *D, kind: u32, value: anytype, out: *u32) bool {
            var mb: [4 + 96]u8 = undefined;
            std.mem.writeInt(u32, mb[0..4], kind, .little);
            const bytes = std.mem.asBytes(value);
            @memcpy(mb[4..][0..bytes.len], bytes);
            return d.createBuffer(ve.ENC_MISC_PARAMETER_BUFFER, @intCast(4 + bytes.len), 1, &mb, out) == va.SUCCESS;
        }

        /// One picture: these buffers, then Begin/Render/EndPicture on the input.
        fn picture(self: *Self, bufs: []const [3]usize) bool {
            const d = self.drv;
            var ids: [8]u32 = undefined;
            var n: usize = 0;
            defer for (ids[0..n]) |id| {
                _ = d.destroyBuffer(id);
            };
            for (bufs) |b| {
                const ptr: *const anyopaque = @ptrFromInt(b[2]);
                if (d.createBuffer(@intCast(b[0]), @intCast(b[1]), 1, ptr, &ids[n]) != va.SUCCESS) return false;
                n += 1;
            }
            if (self.p.bitrate > 0) {
                var rc = std.mem.zeroes(ve.RateControl);
                rc.bits_per_second = self.p.bitrate;
                rc.target_percentage = 100;
                var fr = std.mem.zeroes(ve.FrameRate);
                fr.framerate = (self.p.fps_num & 0xffff) | ((self.p.fps_den & 0xffff) << 16);
                if (!misc(d, ve.MISC_RATE_CONTROL, &rc, &ids[n])) return false;
                n += 1;
                if (!misc(d, ve.MISC_FRAME_RATE, &fr, &ids[n])) return false;
                n += 1;
            }
            if (d.beginPicture(self.context, self.input) != va.SUCCESS) return false;
            if (d.renderPicture(self.context, ids[0..n]) != va.SUCCESS) return false;
            if (d.endPicture(self.context) != va.SUCCESS) return false;
            return d.syncSurface(self.input, 2_000_000_000) == va.SUCCESS;
        }

        fn buf(kind: u32, value: anytype) [3]usize {
            return .{ kind, @sizeOf(@TypeOf(value.*)), @intFromPtr(value) };
        }

        fn h264(self: *Self, key: bool, cur: usize) bool {
            const p = self.p;
            const wm: u16 = @intCast((p.width + 15) / 16);
            const hm: u16 = @intCast((p.height + 15) / 16);
            var seq = std.mem.zeroes(ve.EncSequenceParameterBufferH264);
            seq.level_idc = if (@as(u32, wm) * hm > 3600) 51 else if (@as(u32, wm) * hm > 1620) 40 else 31;
            seq.intra_period = if (p.gop > 0) p.gop else 0;
            seq.intra_idr_period = seq.intra_period;
            seq.ip_period = 1;
            seq.bits_per_second = p.bitrate;
            seq.max_num_ref_frames = 1;
            seq.picture_width_in_mbs = wm;
            seq.picture_height_in_mbs = hm;
            seq.seq_fields = .{ .chroma_format_idc = 1, .frame_mbs_only_flag = 1, .direct_8x8_inference_flag = 1, .log2_max_frame_num_minus4 = 4, .pic_order_cnt_type = 0, .log2_max_pic_order_cnt_lsb_minus4 = 4 };
            if (p.width % 16 != 0 or p.height % 16 != 0) {
                seq.frame_cropping_flag = 1;
                seq.frame_crop_right_offset = (@as(u32, wm) * 16 - p.width) / 2;
                seq.frame_crop_bottom_offset = (@as(u32, hm) * 16 - p.height) / 2;
            }
            seq.vui_parameters_present_flag = 1;
            seq.vui_fields = .{ .timing_info_present_flag = 1, .bitstream_restriction_flag = 1, .log2_max_mv_length_horizontal = 15, .log2_max_mv_length_vertical = 15, .motion_vectors_over_pic_boundaries_flag = 1 };
            seq.num_units_in_tick = p.fps_den;
            seq.time_scale = 2 * p.fps_num;
            const frame_num: u16 = @intCast(if (key) 0 else self.since_key % 256);
            var pic = std.mem.zeroes(ve.EncPictureParameterBufferH264);
            const poc: i32 = @as(i32, frame_num) * 2;
            pic.CurrPic = .{ .picture_id = self.recon[cur], .frame_idx = frame_num, .flags = 0, .TopFieldOrderCnt = poc, .BottomFieldOrderCnt = poc };
            const none = va.PictureH264{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
            for (&pic.ReferenceFrames) |*r| r.* = none;
            var ref = none;
            if (!key) {
                const prev_num: u16 = frame_num -% 1;
                ref = .{ .picture_id = self.recon[self.last], .frame_idx = prev_num, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = poc - 2, .BottomFieldOrderCnt = poc - 2 };
                pic.ReferenceFrames[0] = ref;
            }
            pic.coded_buf = self.coded;
            pic.frame_num = frame_num;
            pic.pic_init_qp = @intCast(@min(p.qp, 51));
            pic.pic_fields = .{ .idr_pic_flag = @intFromBool(key), .reference_pic_flag = 1, .entropy_coding_mode_flag = @intFromBool(p.profile != 66), .transform_8x8_mode_flag = @intFromBool(p.profile == 100 or p.profile == 0), .deblocking_filter_control_present_flag = 1 };
            var sl = std.mem.zeroes(ve.EncSliceParameterBufferH264);
            sl.num_macroblocks = @as(u32, wm) * hm;
            sl.slice_type = if (key) 2 else 0;
            sl.idr_pic_id = self.idr_id;
            sl.pic_order_cnt_lsb = @intCast(@as(u32, @intCast(poc)) & 0xff);
            sl.direct_spatial_mv_pred_flag = 1;
            for (&sl.RefPicList0, &sl.RefPicList1) |*a, *b| {
                a.* = none;
                b.* = none;
            }
            if (!key) sl.RefPicList0[0] = ref;
            if (key) self.idr_id +%= 1;
            return self.picture(&.{ buf(ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq), buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &pic), buf(ve.ENC_SLICE_PARAMETER_BUFFER, &sl) });
        }

        fn vp8(self: *Self, key: bool, cur: usize) bool {
            const p = self.p;
            var seq = std.mem.zeroes(enc_vpx.SeqVp8);
            seq.frame_width = p.width;
            seq.frame_height = p.height;
            seq.bits_per_second = p.bitrate;
            seq.intra_period = p.gop;
            var pic = std.mem.zeroes(enc_vpx.PicVp8);
            pic.reconstructed_frame = self.recon[cur];
            pic.coded_buf = self.coded;
            if (key) {
                pic.ref_flags = 1; // force_kf
                pic.ref_last_frame = va.INVALID_ID;
                pic.ref_gf_frame = va.INVALID_ID;
                pic.ref_arf_frame = va.INVALID_ID;
            } else {
                pic.ref_flags = 0b1100; // no golden, no altref: the last only
                pic.ref_last_frame = self.recon[self.last];
                pic.ref_gf_frame = self.recon[self.last];
                pic.ref_arf_frame = self.recon[self.last];
                pic.pic_flags = 1; // inter
            }
            pic.pic_flags |= (1 << 4) | (1 << 19) | (1 << 20) | (1 << 21);
            var q = std.mem.zeroes(enc_vpx.QMatrixVp8);
            const qi: u16 = @intCast(@min(p.qp * 127 / 51, 127));
            q.quantization_index = .{ qi, qi, qi, qi };
            return self.picture(&.{ buf(ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq), buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &pic), buf(enc_vpx.QMATRIX_BUFFER, &q) });
        }

        fn vp9(self: *Self, key: bool, cur: usize) bool {
            const p = self.p;
            var seq = std.mem.zeroes(enc_vpx.SeqVp9);
            seq.max_frame_width = p.width;
            seq.max_frame_height = p.height;
            seq.bits_per_second = p.bitrate;
            seq.intra_period = p.gop;
            var pic = std.mem.zeroes(enc_vpx.PicVp9);
            pic.frame_width_src = p.width;
            pic.frame_height_src = p.height;
            pic.frame_width_dst = p.width;
            pic.frame_height_dst = p.height;
            pic.reconstructed_frame = self.recon[cur];
            for (&pic.reference_frames) |*r| r.* = va.INVALID_ID;
            pic.coded_buf = self.coded;
            pic.refresh_frame_flags = 0xff;
            pic.luma_ac_qindex = @intCast(@min(p.qp * 255 / 51, 255));
            if (key) {
                pic.ref_flags = 1; // force_kf
            } else {
                pic.reference_frames[0] = self.recon[self.last];
                pic.ref_flags = 1 << 1; // ref_frame_ctrl_l0: LAST, slot 0
                pic.pic_flags = 1; // inter
            }
            pic.pic_flags |= 1 << 1; // shown
            return self.picture(&.{ buf(ve.ENC_SEQUENCE_PARAMETER_BUFFER, &seq), buf(ve.ENC_PICTURE_PARAMETER_BUFFER, &pic) });
        }
    };
}
