//! @zpm/va enc_h264 — H.264 encoding's two halves that are not the
//! engine's: the parameter sets the driver writes (SPS and PPS, from VA's
//! sequence and picture parameters, when the app sends no packed headers
//! of its own), and the engine's picture setup (nvenc_h264_drv_pic_setup_s
//! and its slice, ME, MD and quantisation controls) derived from the same
//! parameters, so the slice headers the engine writes agree with the
//! parameter sets in the stream.
//!
//! Profiles: Constrained Baseline (CAVLC, no 8x8 transform, no B), Main,
//! High; 4:2:0 8-bit, progressive frames, pic_order_cnt_type 0 or 2; P
//! pictures with up to MAX_L0 references, B pictures (referenced or not)
//! with up to MAX_L0 before and MAX_L1 after (EncMaxRefFrames), their
//! direct-mode scale factors (8.4.1.2.3) given to the engine.
//!
//! Pure: no calls, no state.

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const nvenc = @import("nvenc.sig");
const bits = @import("bits.sig");
const tiling = @import("tiling.sig");
const enc_rc = @import("enc_rc.sig");

const H = nvenc.H264;

pub const Seq = ve.EncSequenceParameterBufferH264;
pub const Pic = ve.EncPictureParameterBufferH264;

pub const PROFILES = [_]va.Profile{ va.PROFILE_H264_CONSTRAINED_BASELINE, va.PROFILE_H264_MAIN, va.PROFILE_H264_HIGH };

/// The references a picture's lists may hold: the engine's lists have 8
/// entries each; NVIDIA's own driver offers up to 4 in L0 and 1 in L1
/// for these generations' encoders, and so does this one (ASSUMED the
/// firmware's limits; only the hardware says more).
pub const MAX_L0 = 4;
pub const MAX_L1 = 1;
/// The list entries a slice carries here.
pub const LIST = 4;

/// profile_idc for a VA profile.
pub fn profileIdc(p: va.Profile) u8 {
    return switch (p) {
        va.PROFILE_H264_CONSTRAINED_BASELINE => 66,
        va.PROFILE_H264_MAIN => 77,
        else => 100,
    };
}

/// What a slice parameter buffer says that the setup needs.
pub const Slice = struct {
    first_mb: u32 = 0,
    num_mb: u32 = 0,
    /// 0 P, 1 B, 2 I (VA's, mod 5)
    slice_type: u8 = 2,
    idr_pic_id: u16 = 0,
    pic_order_cnt_lsb: u16 = 0,
    delta_pic_order_cnt_bottom: i32 = 0,
    override: bool = false,
    l0_minus1: u8 = 0,
    l1_minus1: u8 = 0,
    cabac_init_idc: u8 = 0,
    qp_delta: i8 = 0,
    deblock_idc: u8 = 0,
    alpha: i8 = 0,
    beta: i8 = 0,
    direct_spatial: bool = true,
    /// RefPicList0's and RefPicList1's surfaces (VA ids; INVALID_ID: none)
    ref0: [LIST]u32 = [_]u32{va.INVALID_ID} ** LIST,
    ref1: [LIST]u32 = [_]u32{va.INVALID_ID} ** LIST,

    pub fn of(s: *const ve.EncSliceParameterBufferH264) Slice {
        var r = Slice{
            .first_mb = s.macroblock_address,
            .num_mb = s.num_macroblocks,
            .slice_type = s.slice_type % 5,
            .idr_pic_id = s.idr_pic_id,
            .pic_order_cnt_lsb = s.pic_order_cnt_lsb,
            .delta_pic_order_cnt_bottom = s.delta_pic_order_cnt_bottom,
            .override = s.num_ref_idx_active_override_flag != 0,
            .l0_minus1 = s.num_ref_idx_l0_active_minus1,
            .l1_minus1 = s.num_ref_idx_l1_active_minus1,
            .cabac_init_idc = s.cabac_init_idc,
            .qp_delta = s.slice_qp_delta,
            .deblock_idc = s.disable_deblocking_filter_idc,
            .alpha = s.slice_alpha_c0_offset_div2,
            .beta = s.slice_beta_offset_div2,
            .direct_spatial = s.direct_spatial_mv_pred_flag != 0,
        };
        for (&r.ref0, &r.ref1, 0..) |*id0, *id1, k| {
            const p = s.RefPicList0[k];
            id0.* = if (p.flags & va.PICTURE_H264_INVALID != 0) va.INVALID_ID else p.picture_id;
            const q = s.RefPicList1[k];
            id1.* = if (q.flags & va.PICTURE_H264_INVALID != 0) va.INVALID_ID else q.picture_id;
        }
        return r;
    }

    /// The active entries of list `l` (0, 1).
    pub fn list(s: *const Slice, l: u1) []const u32 {
        if (l == 0) return s.ref0[0..@min(@as(usize, s.l0_minus1) + 1, LIST)];
        if (s.slice_type != 1) return s.ref1[0..0];
        return s.ref1[0..@min(@as(usize, s.l1_minus1) + 1, LIST)];
    }
};

// ── The parameter sets ──────────────────────────────────────────────────────

/// Whether the driver can encode what `seq` asks (else why not).
pub fn check(profile: va.Profile, seq: *const Seq, pic: *const Pic) va.Status {
    const sf = seq.seq_fields;
    if (sf.chroma_format_idc != 1 or seq.bit_depth_luma_minus8 != 0 or seq.bit_depth_chroma_minus8 != 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
    if (sf.frame_mbs_only_flag == 0) return va.ERROR_INVALID_PARAMETER;
    if (sf.pic_order_cnt_type == 1) return va.ERROR_INVALID_PARAMETER;
    if (pic.pic_fields.pic_scaling_matrix_present_flag != 0 or sf.seq_scaling_matrix_present_flag != 0) return va.ERROR_INVALID_PARAMETER;
    if (profile == va.PROFILE_H264_CONSTRAINED_BASELINE and (pic.pic_fields.entropy_coding_mode_flag != 0 or pic.pic_fields.transform_8x8_mode_flag != 0)) return va.ERROR_INVALID_PARAMETER;
    if (profile == va.PROFILE_H264_MAIN and pic.pic_fields.transform_8x8_mode_flag != 0) return va.ERROR_INVALID_PARAMETER;
    // (implicit or explicit weights: not given to the engine)
    if (pic.pic_fields.weighted_pred_flag != 0 or pic.pic_fields.weighted_bipred_idc != 0) return va.ERROR_INVALID_PARAMETER;
    return va.SUCCESS;
}

/// Whether the slices' lists are ones the engine takes.
pub fn checkSlices(profile: va.Profile, slices: []const Slice) va.Status {
    for (slices) |s| {
        if (s.slice_type == 1 and profile == va.PROFILE_H264_CONSTRAINED_BASELINE) return va.ERROR_INVALID_PARAMETER;
        if (s.slice_type != 2 and s.l0_minus1 + 1 > MAX_L0) return va.ERROR_MAX_NUM_EXCEEDED;
        if (s.slice_type == 1 and s.l1_minus1 + 1 > MAX_L1) return va.ERROR_MAX_NUM_EXCEEDED;
        if (s.slice_type != slices[0].slice_type) return va.ERROR_INVALID_PARAMETER;
    }
    return va.SUCCESS;
}

/// seq_parameter_set_rbsp() as a NAL unit (start code, emulation
/// prevention) into `out`: its length, or null when `out` is too small.
pub fn writeSps(out: []u8, profile: va.Profile, seq: *const Seq) ?usize {
    var rbsp: [512]u8 = undefined;
    var w = bits.Writer.init(&rbsp);
    const sf = seq.seq_fields;
    const idc = profileIdc(profile);
    w.u(8, 0x67); // nal_ref_idc 3, SPS
    w.u(8, idc);
    // constraint_set0..5 flags, reserved_zero_2bits
    const cs: u32 = switch (profile) {
        va.PROFILE_H264_CONSTRAINED_BASELINE => 0xc0, // set0, set1
        va.PROFILE_H264_MAIN => 0x40, // set1
        else => 0,
    };
    w.u(8, cs);
    w.u(8, seq.level_idc);
    w.ue(seq.seq_parameter_set_id);
    if (idc == 100) {
        w.ue(sf.chroma_format_idc);
        w.ue(seq.bit_depth_luma_minus8);
        w.ue(seq.bit_depth_chroma_minus8);
        w.flag(false); // qpprime_y_zero_transform_bypass_flag
        w.flag(false); // seq_scaling_matrix_present_flag
    }
    w.ue(sf.log2_max_frame_num_minus4);
    w.ue(sf.pic_order_cnt_type);
    if (sf.pic_order_cnt_type == 0) w.ue(sf.log2_max_pic_order_cnt_lsb_minus4);
    w.ue(seq.max_num_ref_frames);
    w.flag(false); // gaps_in_frame_num_value_allowed_flag
    w.ue(@as(u32, seq.picture_width_in_mbs) - 1);
    w.ue(@as(u32, seq.picture_height_in_mbs) - 1);
    w.flag(true); // frame_mbs_only_flag
    w.flag(sf.direct_8x8_inference_flag != 0);
    w.flag(seq.frame_cropping_flag != 0);
    if (seq.frame_cropping_flag != 0) {
        w.ue(seq.frame_crop_left_offset);
        w.ue(seq.frame_crop_right_offset);
        w.ue(seq.frame_crop_top_offset);
        w.ue(seq.frame_crop_bottom_offset);
    }
    w.flag(seq.vui_parameters_present_flag != 0);
    if (seq.vui_parameters_present_flag != 0) vui(&w, seq);
    w.trailing();
    if (w.overflow) return null;
    return bits.nal(out, w.bytes(), 1);
}

fn vui(w: *bits.Writer, seq: *const Seq) void {
    const v = seq.vui_fields;
    w.flag(v.aspect_ratio_info_present_flag != 0);
    if (v.aspect_ratio_info_present_flag != 0) {
        w.u(8, seq.aspect_ratio_idc);
        if (seq.aspect_ratio_idc == 255) {
            w.u(16, seq.sar_width);
            w.u(16, seq.sar_height);
        }
    }
    w.flag(false); // overscan_info_present_flag
    w.flag(false); // video_signal_type_present_flag
    w.flag(false); // chroma_loc_info_present_flag
    w.flag(v.timing_info_present_flag != 0);
    if (v.timing_info_present_flag != 0) {
        w.u(32, seq.num_units_in_tick);
        w.u(32, seq.time_scale);
        w.flag(v.fixed_frame_rate_flag != 0);
    }
    w.flag(false); // nal_hrd_parameters_present_flag
    w.flag(false); // vcl_hrd_parameters_present_flag
    w.flag(false); // pic_struct_present_flag
    w.flag(v.bitstream_restriction_flag != 0);
    if (v.bitstream_restriction_flag != 0) {
        w.flag(v.motion_vectors_over_pic_boundaries_flag != 0);
        w.ue(0); // max_bytes_per_pic_denom
        w.ue(0); // max_bits_per_mb_denom
        w.ue(v.log2_max_mv_length_horizontal);
        w.ue(v.log2_max_mv_length_vertical);
        // max_num_reorder_frames: the B pictures between anchors
        const reorder = if (seq.ip_period > 1) seq.ip_period - 1 else 0;
        w.ue(reorder);
        w.ue(@max(seq.max_num_ref_frames, reorder, 1)); // max_dec_frame_buffering
    }
}

/// pic_parameter_set_rbsp() as a NAL unit into `out`.
pub fn writePps(out: []u8, profile: va.Profile, pic: *const Pic) ?usize {
    var rbsp: [128]u8 = undefined;
    var w = bits.Writer.init(&rbsp);
    const pf = pic.pic_fields;
    w.u(8, 0x68); // nal_ref_idc 3, PPS
    w.ue(pic.pic_parameter_set_id);
    w.ue(pic.seq_parameter_set_id);
    w.flag(pf.entropy_coding_mode_flag != 0);
    w.flag(pf.pic_order_present_flag != 0); // bottom_field_pic_order_in_frame_present_flag
    w.ue(0); // num_slice_groups_minus1
    w.ue(pic.num_ref_idx_l0_active_minus1);
    w.ue(pic.num_ref_idx_l1_active_minus1);
    w.flag(pf.weighted_pred_flag != 0);
    w.u(2, pf.weighted_bipred_idc);
    w.se(@as(i32, pic.pic_init_qp) - 26);
    w.se(0); // pic_init_qs_minus26
    w.se(pic.chroma_qp_index_offset);
    w.flag(pf.deblocking_filter_control_present_flag != 0);
    w.flag(pf.constrained_intra_pred_flag != 0);
    w.flag(pf.redundant_pic_cnt_present_flag != 0);
    if (profileIdc(profile) == 100 and (pf.transform_8x8_mode_flag != 0 or pic.second_chroma_qp_index_offset != pic.chroma_qp_index_offset)) {
        w.flag(pf.transform_8x8_mode_flag != 0);
        w.flag(false); // pic_scaling_matrix_present_flag
        w.se(pic.second_chroma_qp_index_offset);
    }
    w.trailing();
    if (w.overflow) return null;
    return bits.nal(out, w.bytes(), 1);
}

// ── The engine's picture setup ──────────────────────────────────────────────

/// A picture's planes as the engine sees them (GPU addresses and pitches).
pub const Planes = struct {
    luma: u64,
    chroma: u64,
    pitch_luma: u32,
    pitch_chroma: u32,
    /// block linear: log2 of GOBs per block (the input's; references and
    /// reconstructions are tiled 16x16 and ignore it)
    block_height: u7 = INPUT_BLOCK_HEIGHT,
};

/// What one picture's setup is made from.
pub const Setup = struct {
    profile: va.Profile,
    seq: *const Seq,
    pic: *const Pic,
    slices: []const Slice,
    /// the picture's size (the sequence's, uncropped: whole macroblocks)
    width: u32,
    height: u32,
    /// the input's and the reconstructed picture's pitches
    input: Planes,
    recon: Planes,
    /// each reference slot's VA surface (ReferenceFrames[i]; INVALID_ID:
    /// none): the engine's slot i
    ref_ids: [nvenc.REF_SLOTS]u32,
    /// each reference's POC (TopFieldOrderCnt)
    ref_poc: [nvenc.REF_SLOTS]i32,
    /// the QP the driver chose (rate control)
    qp: u8,
    /// a GOP's length (rate control's statistics only)
    gop_length: u32,
    framerate: u32,
    /// the output: where the engine starts writing, the room it has
    bitstream_start: u32,
    bitstream_room: u32,
    history_bytes: u32,
    magic: u32 = nvenc.MAGIC,
};

/// The block height of the input picture's blocks: log2 of GOBs per
/// block (tiling.sig's blocks are 2 GOBs); surface_cfg's block_height
/// takes nvenc.blockHeightField of it.
pub const INPUT_BLOCK_HEIGHT: u7 = tiling.BLOCK_GOBS_LOG2;

/// pic_type: 0 P, 1 B, 2 I, 3 IDR.
pub fn picType(pic: *const Pic, first: Slice) u2 {
    if (pic.pic_fields.idr_pic_flag != 0) return 3;
    return switch (first.slice_type) {
        0 => 0,
        1 => 1,
        else => 2,
    };
}

/// Temporal direct's DistScaleFactor (8.4.1.2.3, frames): a picture at
/// `cur` between `poc0` (L0) and `poc1` (L1); `zero` when the two
/// references' distance is 0 (the factor is then unused).
pub fn directScale(cur: i32, poc0: i32, poc1: i32) struct { scale: i32, zero: bool } {
    const td = std.math.clamp(poc1 - poc0, -128, 127);
    if (td == 0) return .{ .scale = 256, .zero = true };
    const tb = std.math.clamp(cur - poc0, -128, 127);
    const tx = @divTrunc(16384 + @divTrunc(@as(i32, @intCast(@abs(td))), 2), td);
    return .{ .scale = std.math.clamp((tb * tx + 32) >> 6, -1024, 1023), .zero = false };
}

/// The reference slot of VA surface `id` (null: not a reference).
fn slotOf(s: Setup, id: u32) ?u8 {
    if (id == va.INVALID_ID) return null;
    for (s.ref_ids, 0..) |r, i| {
        if (r == id) return @intCast(i);
    }
    return null;
}

/// The setup (nvenc_h264_drv_pic_setup_s, then its controls) into `buf`
/// (nvenc.SETUP_BYTES).
pub fn setup(buf: []u8, s: Setup) void {
    @memset(buf[0..nvenc.SETUP_BYTES], 0);
    const pic = s.pic;
    const seq = s.seq;
    const pf = pic.pic_fields;
    const sf = seq.seq_fields;
    const first = s.slices[0];
    nvenc.set(buf, H.magic, s.magic);
    // the reference, input and reconstructed pictures
    const cfgs = [_][4]nvenc.F{
        .{ H.refpic_cfg_frame_width_minus1, H.refpic_cfg_frame_height_minus1, H.refpic_cfg_sfc_pitch, H.refpic_cfg_sfc_pitch_chroma },
        .{ H.input_cfg_frame_width_minus1, H.input_cfg_frame_height_minus1, H.input_cfg_sfc_pitch, H.input_cfg_sfc_pitch_chroma },
        .{ H.outputpic_cfg_frame_width_minus1, H.outputpic_cfg_frame_height_minus1, H.outputpic_cfg_sfc_pitch, H.outputpic_cfg_sfc_pitch_chroma },
    };
    for (cfgs, 0..) |c, i| {
        const p = if (i == 1) s.input else s.recon;
        nvenc.set(buf, c[0], s.width - 1);
        nvenc.set(buf, c[1], s.height - 1);
        nvenc.set(buf, c[2], p.pitch_luma);
        nvenc.set(buf, c[3], p.pitch_chroma);
    }
    // (offsets 0: each plane has its own address method, as NVK's
    // decoder setup leaves its offsets 0)
    nvenc.set(buf, H.refpic_cfg_tiled_16x16, 1);
    nvenc.set(buf, H.outputpic_cfg_tiled_16x16, 1);
    nvenc.set(buf, H.input_cfg_block_height, nvenc.blockHeightField(s.input.block_height));
    // sps_data, pps_data: what the parameter sets say
    nvenc.set(buf, H.profile_idc, profileIdc(s.profile));
    nvenc.set(buf, H.level_idc, seq.level_idc);
    nvenc.set(buf, H.chroma_format_idc, 1);
    nvenc.set(buf, H.pic_order_cnt_type, sf.pic_order_cnt_type);
    nvenc.set(buf, H.log2_max_frame_num_minus4, sf.log2_max_frame_num_minus4);
    nvenc.set(buf, H.log2_max_pic_order_cnt_lsb_minus4, sf.log2_max_pic_order_cnt_lsb_minus4);
    nvenc.set(buf, H.frame_mbs_only, 1);
    nvenc.set(buf, H.pic_param_set_id, pic.pic_parameter_set_id);
    nvenc.set(buf, H.entropy_coding_mode_flag, pf.entropy_coding_mode_flag);
    nvenc.set(buf, H.pps_num_ref_idx_l0_active_minus1, pic.num_ref_idx_l0_active_minus1);
    nvenc.set(buf, H.pps_num_ref_idx_l1_active_minus1, pic.num_ref_idx_l1_active_minus1);
    nvenc.set(buf, H.weighted_bipred_idc, pf.weighted_bipred_idc);
    nvenc.setSigned(buf, H.pic_init_qp_minus26, @as(i64, pic.pic_init_qp) - 26);
    nvenc.setSigned(buf, H.chroma_qp_index_offset, pic.chroma_qp_index_offset);
    nvenc.setSigned(buf, H.second_chroma_qp_index_offset, pic.second_chroma_qp_index_offset);
    nvenc.set(buf, H.constrained_intra_pred_flag, pf.constrained_intra_pred_flag);
    nvenc.set(buf, H.deblocking_filter_control_present_flag, pf.deblocking_filter_control_present_flag);
    nvenc.set(buf, H.transform_8x8_mode_flag, pf.transform_8x8_mode_flag);
    nvenc.set(buf, H.pic_order_present_flag, pf.pic_order_present_flag);
    nvenc.set(buf, H.weighted_pred_flag, pf.weighted_pred_flag);
    // rate control: the driver's QP (encode.sig puts the firmware's in
    // instead when it runs it)
    enc_rc.constQp(buf, enc_rc.RcFields.of(H), s.qp, s.framerate, s.gop_length);
    // pic_control: the lists, the slice header's values, the controls
    // (unused entries as NVIDIA's driver leaves them: lists -2,
    // distances -1, scale factors -1; nvenc.LIST_NONE)
    const cur_poc = pic.CurrPic.TopFieldOrderCnt;
    for (0..8) |k| {
        const kk: u32 = @intCast(k);
        nvenc.set(buf, nvenc.at(H.l0, kk), nvenc.LIST_NONE);
        nvenc.set(buf, nvenc.at(H.l1, kk), nvenc.LIST_NONE);
        nvenc.set(buf, nvenc.at(H.temp_dist_l0, kk), nvenc.DIST_NONE);
        nvenc.set(buf, nvenc.at(H.temp_dist_l1, kk), nvenc.DIST_NONE);
    }
    for (0..64) |k| nvenc.set(buf, nvenc.at(H.dist_scale_factor, @intCast(k)), nvenc.SCALE_NONE);
    var poc0 = [_]i32{0} ** LIST;
    var poc1 = [_]i32{0} ** LIST;
    const lists = [2][]const u32{ first.list(0), if (first.slice_type == 1) first.list(1) else &.{} };
    for (lists, 0..) |l, li| {
        for (l, 0..) |id, k| {
            const kk: u32 = @intCast(k);
            const slot = slotOf(s, id) orelse continue;
            const d = std.math.clamp(cur_poc - s.ref_poc[slot], -128, 127);
            if (li == 0) {
                nvenc.set(buf, nvenc.at(H.l0, kk), slot);
                nvenc.setSigned(buf, nvenc.at(H.temp_dist_l0, kk), d);
                poc0[k] = s.ref_poc[slot];
            } else {
                nvenc.set(buf, nvenc.at(H.l1, kk), slot);
                nvenc.setSigned(buf, nvenc.at(H.temp_dist_l1, kk), d);
                poc1[k] = s.ref_poc[slot];
            }
        }
    }
    // temporal direct's scale factors, [refidx1][refidx0] (8.4.1.2.3); a
    // P picture's as NVIDIA's driver writes them: 256 (1.0) for each L0
    // entry in use, in every row
    if (first.slice_type == 0) {
        for (0..8) |r1| {
            for (lists[0], 0..) |_, r0| nvenc.setSigned(buf, nvenc.at(H.dist_scale_factor, @intCast(r1 * 8 + r0)), 256);
        }
    }
    if (first.slice_type == 1) {
        var zero: u64 = 0;
        for (lists[1], 0..) |_, r1| {
            for (lists[0], 0..) |_, r0| {
                const f = directScale(cur_poc, poc0[r0], poc1[r1]);
                const idx: u32 = @intCast(r1 * 8 + r0);
                nvenc.setSigned(buf, nvenc.at(H.dist_scale_factor, idx), f.scale);
                if (f.zero) zero |= @as(u64, 1) << @intCast(idx);
            }
        }
        nvenc.set(buf, H.diff_pic_order_cnt_zero, zero & 0xffff_ffff);
        nvenc.set(buf, nvenc.at(H.diff_pic_order_cnt_zero, 1), zero >> 32);
    }
    nvenc.set(buf, H.frame_num, pic.frame_num);
    nvenc.set(buf, H.pic_order_cnt_lsb, first.pic_order_cnt_lsb);
    nvenc.set(buf, H.idr_pic_id, first.idr_pic_id);
    nvenc.setSigned(buf, H.delta_pic_order_cnt_bottom, first.delta_pic_order_cnt_bottom);
    nvenc.set(buf, H.num_forced_slices_minus1, s.slices.len - 1);
    nvenc.set(buf, H.slice_control_offset, nvenc.SLICE_CONTROL_OFF);
    nvenc.set(buf, H.me_control_offset, nvenc.ME_CONTROL_OFF);
    nvenc.set(buf, H.md_control_offset, nvenc.MD_CONTROL_OFF);
    nvenc.set(buf, H.q_control_offset, nvenc.Q_CONTROL_OFF);
    nvenc.set(buf, H.hist_buf_size, s.history_bytes);
    nvenc.set(buf, H.bitstream_buf_size, s.bitstream_room);
    nvenc.set(buf, H.bitstream_start_pos, s.bitstream_start);
    nvenc.set(buf, H.pic_type, picType(pic, first));
    nvenc.set(buf, H.ref_pic_flag, @intFromBool(pf.reference_pic_flag != 0));
    nvenc.set(buf, H.b_as_ref, @intFromBool(first.slice_type == 1 and pf.reference_pic_flag != 0));
    // static slices: the slice controls' macroblock counts
    nvenc.set(buf, H.slice_mode, 1);
    nvenc.set(buf, H.base_view, 1);
    nvenc.set(buf, H.e4byte_start_code, 1);
    nvenc.set(buf, H.gp_timer_timeout_val, nvenc.GPTIMER_TIMEOUT);
    // the slice controls
    for (s.slices, 0..) |sl, i| {
        const c = buf[nvenc.SLICE_CONTROL_OFF + i * nvenc.H264Slice.SIZE ..];
        const L = nvenc.H264Slice;
        nvenc.set(c, L.num_mb, sl.num_mb);
        nvenc.set(c, L.qp_avr, s.qp);
        nvenc.set(c, L.qp_slice_min, s.qp);
        nvenc.set(c, L.qp_slice_max, s.qp);
        nvenc.setSigned(c, L.slice_alpha_c0_offset_div2, sl.alpha);
        nvenc.setSigned(c, L.slice_beta_offset_div2, sl.beta);
        nvenc.set(c, L.force_intra, @intFromBool(sl.slice_type == 2));
        nvenc.set(c, L.disable_deblocking_filter_idc, sl.deblock_idc);
        nvenc.set(c, L.cabac_init_idc, sl.cabac_init_idc);
        nvenc.set(c, L.num_ref_idx_active_override_flag, @intFromBool(sl.override));
        nvenc.set(c, L.num_ref_idx_l0_active_minus1, sl.l0_minus1);
        nvenc.set(c, L.num_ref_idx_l1_active_minus1, sl.l1_minus1);
    }
    nvenc.meControl(buf[nvenc.ME_CONTROL_OFF..]);
    const md = buf[nvenc.MD_CONTROL_OFF..];
    const D = nvenc.H264Md;
    const t8 = pf.transform_8x8_mode_flag != 0;
    nvenc.set(md, D.intra_luma4x4_mode_enable, 0x1ff);
    nvenc.set(md, D.intra_luma8x8_mode_enable, if (t8) 0x1ff else 0);
    nvenc.set(md, D.intra_luma16x16_mode_enable, 0xf);
    nvenc.set(md, D.intra_chroma_mode_enable, 0xf);
    nvenc.set(md, D.l0_part_16x16_enable, 1);
    nvenc.set(md, D.l0_part_16x8_enable, 1);
    nvenc.set(md, D.l0_part_8x16_enable, 1);
    nvenc.set(md, D.l0_part_8x8_enable, 1);
    // (B pictures: the same partitions for L1 and bi-prediction; direct
    // mode as the slice header says, B_Skip with it)
    for (0..4) |p| {
        const pp: u32 = @intCast(p);
        nvenc.set(md, .{ .bit = D.l1_part_16x16_enable.bit + pp, .width = 1 }, 1);
        nvenc.set(md, .{ .bit = D.bi_part_16x16_enable.bit + pp, .width = 1 }, 1);
    }
    if (first.slice_type == 1) {
        nvenc.set(md, D.bdirect_mode, if (first.direct_spatial) 1 else 2);
        nvenc.set(md, D.bskip_enable, 1);
    }
    nvenc.set(md, D.pskip_enable, 1);
    nvenc.set(md, D.mv_cost_enable, 1);
    // which intra sizes to search: 4x4, 16x16, and 8x8 with the 8x8 transform
    nvenc.set(md, D.ip_search_mode, if (t8) 7 else 5);
    // (the quantisation control left zero: no QPP, no dead zones)
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

pub fn testSeq(w_mbs: u16, h_mbs: u16) Seq {
    var s = std.mem.zeroes(Seq);
    s.level_idc = 31;
    s.intra_period = 30;
    s.ip_period = 1;
    s.max_num_ref_frames = 1;
    s.picture_width_in_mbs = w_mbs;
    s.picture_height_in_mbs = h_mbs;
    s.seq_fields = .{ .chroma_format_idc = 1, .frame_mbs_only_flag = 1, .direct_8x8_inference_flag = 1, .log2_max_frame_num_minus4 = 4, .pic_order_cnt_type = 0, .log2_max_pic_order_cnt_lsb_minus4 = 4 };
    return s;
}

pub fn testPic(target: u32, coded: u32, idr: bool, frame_num: u16) Pic {
    var p = std.mem.zeroes(Pic);
    p.CurrPic = .{ .picture_id = target, .frame_idx = frame_num, .flags = 0, .TopFieldOrderCnt = @as(i32, frame_num) * 2, .BottomFieldOrderCnt = @as(i32, frame_num) * 2 };
    for (&p.ReferenceFrames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    p.coded_buf = coded;
    p.frame_num = frame_num;
    p.pic_init_qp = 26;
    p.pic_fields = .{ .idr_pic_flag = @intFromBool(idr), .reference_pic_flag = 1, .deblocking_filter_control_present_flag = 1 };
    return p;
}

test "enc_h264: an SPS and a PPS, bit by bit" {
    var seq = testSeq(3, 2);
    seq.frame_cropping_flag = 1;
    seq.frame_crop_right_offset = 4; // 48 - 2*4 = 40
    seq.frame_crop_bottom_offset = 4; // 32 - 2*4 = 24
    var out: [64]u8 = undefined;
    const n = writeSps(&out, va.PROFILE_H264_CONSTRAINED_BASELINE, &seq).?;
    // 66, set0+set1, level 31; sps id 0 (1), log2_max_frame_num-4 4
    // (00101), poc type 0 (1), log2 poc lsb-4 4 (00101), refs 1 (010),
    // gaps 0, w-1 2 (011), h-1 1 (010), frame_mbs 1, d8x8 1, crop 1,
    // 0 (1) 4 (00101) 0 (1) 4 (00101), vui 0, trailing 1
    var want: [32]u8 = undefined;
    var w = bits.Writer.init(&want);
    w.u(8, 0x67);
    w.u(8, 66);
    w.u(8, 0xc0);
    w.u(8, 31);
    const tail = "1" ++ "00101" ++ "1" ++ "00101" ++ "010" ++ "0" ++ "011" ++ "010" ++ "1" ++ "1" ++ "1" ++ "1" ++ "00101" ++ "1" ++ "00101" ++ "0" ++ "1";
    for (tail) |c| w.bit(@intCast(c - '0'));
    w.alignZero();
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 }, out[0..4]);
    try testing.expectEqualSlices(u8, w.bytes(), out[4..n]);
    const pic = testPic(0x400, 0x1000, true, 0);
    const m = writePps(&out, va.PROFILE_H264_HIGH, &pic).?;
    // pps 0, sps 0, cavlc, no bottom poc, 1 group (1), refs 0 0 (1 1),
    // wp 0, bipred 00, qp-26 0 (1), qs 0 (1), cqp 0 (1), deblock 1, cip
    // 0, redundant 0, trailing: 1 1 0 0 1 1 1 0 00 1 1 1 1 0 0 1
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80 }, out[0..m]);
}

test "enc_h264: the setup from VA's parameters" {
    const seq = testSeq(3, 2);
    var pic = testPic(0x401, 0x1000, false, 1);
    pic.ReferenceFrames[0] = .{ .picture_id = 0x400, .frame_idx = 0, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    pic.pic_init_qp = 23;
    pic.chroma_qp_index_offset = -2;
    pic.pic_fields.entropy_coding_mode_flag = 1;
    var sl = Slice{ .num_mb = 6, .slice_type = 0, .pic_order_cnt_lsb = 2, .deblock_idc = 0, .alpha = -1 };
    sl.ref0[0] = 0x400;
    var refs = [_]u32{va.INVALID_ID} ** nvenc.REF_SLOTS;
    refs[0] = 0x400;
    var buf: [nvenc.SETUP_BYTES]u8 = undefined;
    setup(&buf, .{
        .profile = va.PROFILE_H264_MAIN,
        .seq = &seq,
        .pic = &pic,
        .slices = &.{sl},
        .width = 48,
        .height = 32,
        .input = .{ .luma = 0, .chroma = 0, .pitch_luma = 64, .pitch_chroma = 64 },
        .recon = .{ .luma = 0, .chroma = 0, .pitch_luma = 64, .pitch_chroma = 64 },
        .ref_ids = refs,
        .ref_poc = [_]i32{0} ** nvenc.REF_SLOTS,
        .qp = 30,
        .gop_length = 30,
        .framerate = 30,
        .bitstream_start = 37,
        .bitstream_room = 1 << 20,
        .history_bytes = 4096,
    });
    try testing.expectEqual(@as(u32, nvenc.MAGIC), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u64, 47), nvenc.get(&buf, H.input_cfg_frame_width_minus1));
    try testing.expectEqual(@as(u64, 31), nvenc.get(&buf, H.outputpic_cfg_frame_height_minus1));
    try testing.expectEqual(@as(u64, 64), nvenc.get(&buf, H.input_cfg_sfc_pitch));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.refpic_cfg_tiled_16x16));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, H.input_cfg_tiled_16x16));
    try testing.expectEqual(@as(u64, 77), nvenc.get(&buf, H.profile_idc));
    try testing.expectEqual(@as(u64, 31), nvenc.get(&buf, H.level_idc));
    try testing.expectEqual(@as(u64, 4), nvenc.get(&buf, H.log2_max_frame_num_minus4));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.entropy_coding_mode_flag));
    try testing.expectEqual(@as(u64, 0x3d), nvenc.get(&buf, H.pic_init_qp_minus26)); // -3
    try testing.expectEqual(@as(u64, 0x1e), nvenc.get(&buf, H.chroma_qp_index_offset)); // -2
    try testing.expectEqual(@as(u64, 30), nvenc.get(&buf, H.rc_qp_p));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, nvenc.at(H.l0, 0)));
    // (unused entries as NVIDIA's driver writes them: -2, distances -1;
    // a P picture's scale factors 256 for its L0 entry, -1 elsewhere)
    try testing.expectEqual(@as(u64, nvenc.LIST_NONE), nvenc.get(&buf, nvenc.at(H.l0, 1)));
    try testing.expectEqual(@as(u64, nvenc.LIST_NONE), nvenc.get(&buf, nvenc.at(H.l1, 0)));
    try testing.expectEqual(@as(u64, nvenc.DIST_NONE), nvenc.get(&buf, nvenc.at(H.temp_dist_l0, 1)));
    try testing.expectEqual(@as(u64, 256), nvenc.get(&buf, nvenc.at(H.dist_scale_factor, 0)));
    try testing.expectEqual(@as(u64, 256), nvenc.get(&buf, nvenc.at(H.dist_scale_factor, 7 * 8)));
    try testing.expectEqual(@as(u64, nvenc.SCALE_NONE), nvenc.get(&buf, nvenc.at(H.dist_scale_factor, 1)));
    // the input's 16-row blocks: 2 GOBs
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, H.input_cfg_block_height));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, nvenc.at(H.temp_dist_l0, 0)));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.frame_num));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, H.pic_order_cnt_lsb));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, H.pic_type)); // P
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.ref_pic_flag));
    try testing.expectEqual(@as(u64, 37), nvenc.get(&buf, H.bitstream_start_pos));
    try testing.expectEqual(@as(u64, nvenc.SLICE_CONTROL_OFF), nvenc.get(&buf, H.slice_control_offset));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, H.num_forced_slices_minus1));
    const c = buf[nvenc.SLICE_CONTROL_OFF..];
    try testing.expectEqual(@as(u64, 6), nvenc.get(c, nvenc.H264Slice.num_mb));
    try testing.expectEqual(@as(u64, 30), nvenc.get(c, nvenc.H264Slice.qp_avr));
    try testing.expectEqual(@as(u64, 0xf), nvenc.get(c, nvenc.H264Slice.slice_alpha_c0_offset_div2));
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H264Slice.force_intra));
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H264Slice.disable_slice_header));
    const md = buf[nvenc.MD_CONTROL_OFF..];
    try testing.expectEqual(@as(u64, 0x1ff), nvenc.get(md, nvenc.H264Md.intra_luma4x4_mode_enable));
    try testing.expectEqual(@as(u64, 0), nvenc.get(md, nvenc.H264Md.intra_luma8x8_mode_enable));
    try testing.expectEqual(@as(u64, 5), nvenc.get(md, nvenc.H264Md.ip_search_mode));
    const me = buf[nvenc.ME_CONTROL_OFF..];
    try testing.expectEqual(@as(u64, 4), nvenc.get(me, nvenc.Me.hint_type4));
    try testing.expectEqual(va.SUCCESS, check(va.PROFILE_H264_MAIN, &seq, &pic));
    pic.pic_fields.transform_8x8_mode_flag = 1;
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, check(va.PROFILE_H264_MAIN, &seq, &pic));
}
