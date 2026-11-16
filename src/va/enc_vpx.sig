//! @zpm/va enc_vpx — VP8 and VP9 encoding through VA-API: libva 2.22's
//! VP8 and VP9 encode buffers (va_enc_vp8.h, va_enc_vp9.h), what a context
//! keeps between libva's calls, and each picture's plan (key or inter, the
//! quantizer from the app's or the rate control's, the references the app
//! names). The pixel work is the kernels' (vp8_kernels.sig and
//! vp9_kernels.sig, on the RTX or the CPU); the bitstream the CPU's
//! (enc_vp8.sig, enc_vp9.sig); driver.sig runs a picture through them at
//! EndPicture and fills the coded buffer.
//!
//! The RTX's NVENC has no VP8 or VP9 encoder: these profiles' EncSlice is
//! offered whenever encoding is (it needs only the GPU's compute engine).
//!
//! What an app sends (FFmpeg's vp8_vaapi and vp9_vaapi, so Firefox's
//! VA-API encoder): a sequence parameter buffer (size, rate, key frame
//! interval), a picture parameter buffer (the reconstructed and reference
//! surfaces, the coded buffer, the frame type and flags, VP9's quantizer),
//! VP8's quantization matrix buffer (its quantizer), misc parameters (rate
//! control, frame rate, HRD, quality level: taken; the first three steer
//! the rate control), no slices and no packed headers. Each VA surface
//! the app names as the reconstruction or a reference is the encoder's
//! frame store's business: the encoder keeps the decoder's state itself
//! (the frame it predicts from is the one the decoder will have).
//!
//! Allocation-free: fixed fields.

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const codec = @import("codec.sig");
const enc_rc = @import("enc_rc.sig");
const enc_vp8 = @import("enc_vp8.sig");
const enc_vp9 = @import("enc_vp9.sig");
const vav8 = @import("vaapi_vp8.sig");
const vav9 = @import("vaapi_vp9.sig");

pub const Codec = enum { vp8, vp9 };

pub fn supported(profile: va.Profile) ?Codec {
    if (profile == vav8.PROFILE_VP8_VERSION0_3) return .vp8;
    if (profile == vav9.PROFILE_VP9_PROFILE0) return .vp9;
    return null;
}

pub const RC_MODES: u32 = ve.RC_CQP | ve.RC_CBR | ve.RC_VBR;
/// No packed headers: the encoder writes the whole frame.
pub const PACKED_HEADERS: u32 = ve.PACKED_HEADER_NONE;
/// One reference (L0), no B pictures (FFmpeg then sends P pictures only).
pub const MAX_REFS: u32 = 1;
/// VAQMatrixBufferType (VP8's quantizer).
pub const QMATRIX_BUFFER: u32 = 11;

// ── libva 2.22's VP8 encode buffers (va_enc_vp8.h) ──────────────────────────

pub const SeqVp8 = extern struct {
    frame_width: u32,
    frame_height: u32,
    frame_width_scale: u32,
    frame_height_scale: u32,
    error_resilient: u32,
    kf_auto: u32,
    kf_min_dist: u32,
    kf_max_dist: u32,
    bits_per_second: u32,
    intra_period: u32,
    reference_frames: [4]u32,
    va_reserved: [4]u32,
};

pub const PicVp8 = extern struct {
    reconstructed_frame: u32,
    ref_last_frame: u32,
    ref_gf_frame: u32,
    ref_arf_frame: u32,
    coded_buf: u32,
    /// force_kf 0, no_ref_last 1, no_ref_gf 2, no_ref_arf 3, temporal_id
    /// 4..11, first_ref 12..13, second_ref 14..15
    ref_flags: u32,
    /// frame_type 0 (0: key), version 1..3, show_frame 4, color_space 5,
    /// recon_filter_type 6..7, loop_filter_type 8..9, auto_partitions 10,
    /// num_token_partitions 11..12, clamping_type 13, segmentation_enabled
    /// 14, update_mb_segmentation_map 15, update_segment_feature_data 16,
    /// loop_filter_adj_enable 17, refresh_entropy_probs 18,
    /// refresh_golden_frame 19, refresh_alternate_frame 20, refresh_last
    /// 21, copy_buffer_to_golden 22..23, copy_buffer_to_alternate 24..25,
    /// sign_bias_golden 26, sign_bias_alternate 27, mb_no_coeff_skip 28,
    /// forced_lf_adjustment 29
    pic_flags: u32,
    loop_filter_level: [4]i8,
    ref_lf_delta: [4]i8,
    mode_lf_delta: [4]i8,
    sharpness_level: u8,
    clamp_qindex_high: u8,
    clamp_qindex_low: u8,
    va_reserved: [4]u32,
};

pub const QMatrixVp8 = extern struct {
    quantization_index: [4]u16,
    quantization_index_delta: [5]i16,
    va_reserved: [4]u32,
};

// ── libva 2.22's VP9 encode buffers (va_enc_vp9.h) ──────────────────────────

pub const SeqVp9 = extern struct {
    max_frame_width: u32,
    max_frame_height: u32,
    kf_auto: u32,
    kf_min_dist: u32,
    kf_max_dist: u32,
    bits_per_second: u32,
    intra_period: u32,
    va_reserved: [4]u32,
};

pub const PicVp9 = extern struct {
    frame_width_src: u32,
    frame_height_src: u32,
    frame_width_dst: u32,
    frame_height_dst: u32,
    reconstructed_frame: u32,
    reference_frames: [8]u32,
    coded_buf: u32,
    /// force_kf 0, ref_frame_ctrl_l0 1..3, ref_frame_ctrl_l1 4..6,
    /// ref_last_idx 7..9, ref_last_sign_bias 10, ref_gf_idx 11..13,
    /// ref_gf_sign_bias 14, ref_arf_idx 15..17, ref_arf_sign_bias 18,
    /// temporal_id 19..26
    ref_flags: u32,
    /// frame_type 0 (0: key), show_frame 1, error_resilient_mode 2,
    /// intra_only 3, allow_high_precision_mv 4, mcomp_filter_type 5..7,
    /// frame_parallel_decoding_mode 8, reset_frame_context 9..10,
    /// refresh_frame_context 11, frame_context_idx 12..13,
    /// segmentation_enabled 14, segmentation_temporal_update 15,
    /// segmentation_update_map 16, lossless_mode 17, comp_prediction_mode
    /// 18..19, auto_segmentation 20, super_frame_flag 21
    pic_flags: u32,
    refresh_frame_flags: u8,
    luma_ac_qindex: u8,
    luma_dc_qindex_delta: i8,
    chroma_ac_qindex_delta: i8,
    chroma_dc_qindex_delta: i8,
    filter_level: u8,
    sharpness_level: u8,
    ref_lf_delta: [4]i8,
    mode_lf_delta: [2]i8,
    bit_offset_ref_lf_delta: u16,
    bit_offset_mode_lf_delta: u16,
    bit_offset_lf_level: u16,
    bit_offset_qindex: u16,
    bit_offset_first_partition_size: u16,
    bit_offset_segmentation: u16,
    bit_size_segmentation: u16,
    log2_tile_rows: u8,
    log2_tile_columns: u8,
    skip_frame_flag: u8,
    number_skip_frames: u8,
    skip_frames_size: u32,
    va_reserved: [8]u32,
};

comptime {
    // (gcc's sizes and offsets for libva 2.22 on x86-64)
    std.debug.assert(@sizeOf(SeqVp8) == 72);
    std.debug.assert(@sizeOf(PicVp8) == 60);
    std.debug.assert(@offsetOf(PicVp8, "loop_filter_level") == 28);
    std.debug.assert(@offsetOf(PicVp8, "sharpness_level") == 40);
    std.debug.assert(@sizeOf(QMatrixVp8) == 36);
    std.debug.assert(@sizeOf(SeqVp9) == 44);
    std.debug.assert(@sizeOf(PicVp9) == 132);
    std.debug.assert(@offsetOf(PicVp9, "refresh_frame_flags") == 64);
    std.debug.assert(@offsetOf(PicVp9, "bit_offset_ref_lf_delta") == 78);
    std.debug.assert(@offsetOf(PicVp9, "skip_frames_size") == 96);
}

fn bits(v: u32, at: u5, n: u5) u32 {
    return (v >> at) & ((@as(u32, 1) << n) - 1);
}

// ── A context's state ───────────────────────────────────────────────────────

pub const State = struct {
    codec: Codec,
    width: u32,
    height: u32,
    rate: enc_rc.Controller = .{},
    vp8: enc_vp8.Encoder = undefined,
    vp9: enc_vp9.Encoder = undefined,
    have_seq: bool = false,
    have_pic: bool = false,
    have_q: bool = false,
    seq8: SeqVp8 = undefined,
    pic8: PicVp8 = undefined,
    q8: QMatrixVp8 = undefined,
    seq9: SeqVp9 = undefined,
    pic9: PicVp9 = undefined,
    bad: va.Status = va.SUCCESS,
    /// pictures since the last key frame
    since_key: u32 = 0,
    pictures: u64 = 0,

    pub fn init(kind: Codec, width: u32, height: u32, rc_mode: u32) State {
        var st = State{ .codec = kind, .width = width, .height = height };
        const scale: enc_rc.Scale = if (kind == .vp8) .vp8 else .av1;
        st.rate = .{
            .mode = switch (rc_mode) {
                ve.RC_CBR => .cbr,
                ve.RC_VBR => .vbr,
                else => .cqp,
            },
            .scale = scale,
            .pixels = @as(u64, width) * height,
            .max_qp = enc_rc.qMax(scale),
        };
        return st;
    }
};

pub fn begin(st: *State) void {
    st.have_pic = false;
    st.have_q = false;
    st.bad = va.SUCCESS;
}

fn value(comptime T: type, data: []const u8) ?T {
    if (data.len < @sizeOf(T)) return null;
    return std.mem.bytesToValue(T, data[0..@sizeOf(T)]);
}

/// One VA buffer of the picture (RenderPicture).
pub fn take(st: *State, b: codec.Buffer) va.Status {
    switch (b.kind) {
        ve.ENC_SEQUENCE_PARAMETER_BUFFER => switch (st.codec) {
            .vp8 => {
                st.seq8 = value(SeqVp8, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.rate.intra_period = st.seq8.intra_period;
                if (st.rate.bits_per_second == 0) st.rate.bits_per_second = st.seq8.bits_per_second;
                st.have_seq = true;
            },
            .vp9 => {
                st.seq9 = value(SeqVp9, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.rate.intra_period = st.seq9.intra_period;
                if (st.rate.bits_per_second == 0) st.rate.bits_per_second = st.seq9.bits_per_second;
                st.have_seq = true;
            },
        },
        ve.ENC_PICTURE_PARAMETER_BUFFER => switch (st.codec) {
            .vp8 => {
                st.pic8 = value(PicVp8, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.have_pic = true;
            },
            .vp9 => {
                st.pic9 = value(PicVp9, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.have_pic = true;
            },
        },
        QMATRIX_BUFFER => {
            if (st.codec != .vp8) return va.ERROR_UNSUPPORTED_BUFFERTYPE;
            st.q8 = value(QMatrixVp8, b.data) orelse return va.ERROR_INVALID_BUFFER;
            st.have_q = true;
        },
        ve.ENC_MISC_PARAMETER_BUFFER => {
            if (b.data.len < 4) return va.ERROR_INVALID_BUFFER;
            const kind = std.mem.readInt(u32, b.data[0..4], .little);
            const rest = b.data[4..];
            switch (kind) {
                ve.MISC_RATE_CONTROL => {
                    const p = value(ve.RateControl, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.rateControl(p.bits_per_second, p.target_percentage, p.initial_qp, p.min_qp, p.max_qp);
                },
                ve.MISC_FRAME_RATE => {
                    const p = value(ve.FrameRate, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.frameRate(p.framerate & 0xffff, p.framerate >> 16);
                },
                ve.MISC_HRD => {
                    const h = value(ve.Hrd, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.hrd(h.buffer_size, h.initial_buffer_fullness);
                },
                // (quality levels, temporal layers, segments, ...: taken, not used)
                else => {},
            }
        },
        // (slices: none in VP8 or VP9; an app's packed headers are refused
        // by the config)
        ve.ENC_SLICE_PARAMETER_BUFFER => {},
        else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
    }
    return va.SUCCESS;
}

pub fn codedBuffer(st: *const State) ?u32 {
    if (!st.have_pic) return null;
    return switch (st.codec) {
        .vp8 => st.pic8.coded_buf,
        .vp9 => st.pic9.coded_buf,
    };
}

/// A picture's plan: its frame (as the codec's encoder takes it) and the
/// rate control's view of it.
pub const Plan = struct {
    vp8: enc_vp8.Picture = undefined,
    vp9: enc_vp9.Picture = undefined,
    key: bool,
    q: u8,
    type: enc_rc.Type,
};

/// What EndPicture encodes: the frame type (the app's, or a key frame
/// where the sequence's interval asks), the quantizer (CQP: the app's;
/// CBR, VBR: the rate control's), the app's flags.
pub fn plan(st: *State, out: *Plan) va.Status {
    if (!st.have_pic) return va.ERROR_INVALID_PARAMETER;
    out.* = planOf(st);
    return va.SUCCESS;
}

fn planOf(st: *State) Plan {
    switch (st.codec) {
        .vp8 => {
            const p = &st.pic8;
            var key = bits(p.pic_flags, 0, 1) == 0 or bits(p.ref_flags, 0, 1) != 0 or st.pictures == 0;
            if (st.have_seq and st.seq8.kf_auto != 0 and st.seq8.kf_max_dist != 0 and st.since_key >= st.seq8.kf_max_dist) key = true;
            const t: enc_rc.Type = if (key) .i else .p;
            const app_q: i32 = if (st.have_q) st.q8.quantization_index[0] else 40;
            const pl = st.rate.plan(t, app_q);
            const lo: i32 = p.clamp_qindex_low;
            const hi: i32 = if (p.clamp_qindex_high == 0) 127 else p.clamp_qindex_high;
            const q: u7 = @intCast(std.math.clamp(std.math.clamp(pl.qp, @min(lo, hi), @max(lo, hi)), 0, 127));
            return .{
                .key = key,
                .q = q,
                .type = t,
                .vp8 = .{
                    .key = key,
                    .q = q,
                    .show = bits(p.pic_flags, 4, 1) != 0,
                    .refresh_golden = bits(p.pic_flags, 19, 1) != 0,
                    .refresh_alt = bits(p.pic_flags, 20, 1) != 0,
                    .refresh_last = bits(p.pic_flags, 21, 1) != 0 or key,
                    .error_resilient = st.have_seq and st.seq8.error_resilient != 0,
                    .sharpness = @intCast(@min(p.sharpness_level, 7)),
                },
            };
        },
        .vp9 => {
            const p = &st.pic9;
            var key = bits(p.pic_flags, 0, 1) == 0 or bits(p.ref_flags, 0, 1) != 0 or st.pictures == 0;
            if (st.have_seq and st.seq9.kf_auto != 0 and st.seq9.kf_max_dist != 0 and st.since_key >= st.seq9.kf_max_dist) key = true;
            const t: enc_rc.Type = if (key) .i else .p;
            const pl = st.rate.plan(t, if (p.luma_ac_qindex == 0) 100 else p.luma_ac_qindex);
            const q: u8 = @intCast(std.math.clamp(pl.qp, 1, 255));
            return .{
                .key = key,
                .q = q,
                .type = t,
                .vp9 = .{
                    .key = key,
                    .q = q,
                    .show = bits(p.pic_flags, 1, 1) != 0,
                    .error_resilient = bits(p.pic_flags, 2, 1) != 0,
                    .refresh = if (key) 0xff else p.refresh_frame_flags,
                    .ref_slot = @intCast(bits(p.ref_flags, 7, 3)),
                    .sharpness = @intCast(@min(p.sharpness_level, 7)),
                },
            };
        },
    }
}

/// After the picture: the rate control told, the key frame counted.
pub fn done(st: *State, pl: Plan, bytes: usize) void {
    _ = st.rate.done(pl.type, @as(u64, bytes) * 8, pl.q, 0, 0);
    st.since_key = if (pl.key) 1 else st.since_key + 1;
    st.pictures += 1;
}

/// The coded buffer's segment for `bytes` of stream at DATA_OFF (`full`:
/// the stream did not fit).
pub fn segment(coded: []u8, data_off: usize, bytes: u32, full: bool) void {
    var seg = std.mem.zeroes(ve.CodedBufferSegment);
    seg.size = bytes;
    seg.status = if (full) ve.CODED_BUF_STATUS_SLICE_OVERFLOW_MASK else 0;
    seg.buf = coded.ptr + data_off;
    seg.next = null;
    @memcpy(coded[0..@sizeOf(ve.CodedBufferSegment)], std.mem.asBytes(&seg));
}

// ── The RTX's engine (the shared library's converter: vpx_gpu.sig) ──────────

/// A picture for the converter's GPU context to encode.
pub const GpuJob = struct {
    state: *State,
    plan: Plan,
    /// the input picture: its planes, its buffer's dma-buf and size
    surface: enc_vp8.Surface,
    surface_fd: i32,
    surface_bytes: usize,
    /// the stream's room, the packer's scratch
    out: []u8,
    scratch: []u8,
    /// the frame store is new (the context's first picture there, or after
    /// the CPU had it): the GPU's frames start again
    fresh: bool,
};

pub const GpuDone = union(enum) {
    /// encoded: its bytes
    done: usize,
    /// encoded, but the stream did not fit
    full,
    /// no GPU here (or not opened): the CPU encodes
    unavailable,
    /// the GPU failed mid-way (lost, a fault): the CPU encodes from a key frame
    failed,
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "enc_vpx: FFmpeg's VP8 buffers make a plan" {
    var st = State.init(.vp8, 64, 48, ve.RC_CQP);
    begin(&st);
    var seq = std.mem.zeroes(SeqVp8);
    seq.frame_width = 64;
    seq.frame_height = 48;
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = ve.ENC_SEQUENCE_PARAMETER_BUFFER, .size = @sizeOf(SeqVp8), .count = 1, .data = std.mem.asBytes(&seq) }));
    var pic = std.mem.zeroes(PicVp8);
    pic.coded_buf = 0x1003;
    pic.ref_flags = 1; // force_kf
    pic.pic_flags = (1 << 4) | (1 << 19) | (1 << 20) | (1 << 21);
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = ve.ENC_PICTURE_PARAMETER_BUFFER, .size = @sizeOf(PicVp8), .count = 1, .data = std.mem.asBytes(&pic) }));
    var q = std.mem.zeroes(QMatrixVp8);
    q.quantization_index = .{ 37, 37, 37, 37 };
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = QMATRIX_BUFFER, .size = @sizeOf(QMatrixVp8), .count = 1, .data = std.mem.asBytes(&q) }));
    try testing.expectEqual(@as(?u32, 0x1003), codedBuffer(&st));
    var pl: Plan = undefined;
    try testing.expectEqual(va.SUCCESS, plan(&st, &pl));
    try testing.expect(pl.key);
    try testing.expectEqual(@as(u8, 37), pl.q);
    try testing.expect(pl.vp8.show and pl.vp8.refresh_last);
    done(&st, pl, 1000);
    // the next picture: inter
    begin(&st);
    pic.ref_flags = 0b1100; // no golden, no altref
    pic.pic_flags |= 1; // inter
    _ = take(&st, .{ .kind = ve.ENC_PICTURE_PARAMETER_BUFFER, .size = @sizeOf(PicVp8), .count = 1, .data = std.mem.asBytes(&pic) });
    _ = take(&st, .{ .kind = QMATRIX_BUFFER, .size = @sizeOf(QMatrixVp8), .count = 1, .data = std.mem.asBytes(&q) });
    var p2: Plan = undefined;
    try testing.expectEqual(va.SUCCESS, plan(&st, &p2));
    try testing.expect(!p2.key);
    try testing.expectEqual(supported(vav8.PROFILE_VP8_VERSION0_3), .vp8);
    try testing.expectEqual(supported(vav9.PROFILE_VP9_PROFILE0), .vp9);
}
