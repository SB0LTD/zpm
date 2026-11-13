//! @zpm/va enc_hevc — HEVC Main encoding's halves that are not the
//! engine's: the VPS, SPS and PPS the driver writes when the app packs
//! none, and the engine's picture setup (nvenc_h265_drv_pic_setup_s and
//! its controls) from VA's parameters.
//!
//! VA's HEVC parameters do not carry everything the slice headers depend
//! on (log2_max_pic_order_cnt_lsb, output_flag_present_flag,
//! num_extra_slice_header_bits, cabac_init_present_flag, the deblocking
//! override, the slice chroma QP offsets, lists modification): those are
//! fixed here to what FFmpeg's hevc_vaapi writes in its own parameter sets
//! (hw_base_encode_h265.c: POC LSB 12 bits, the rest off), so the engine's
//! slice headers agree with the app's packed headers and with the
//! driver's. The short-term reference picture set is in each slice header
//! (FFmpeg's SPS has none), made from VA's reference list.
//!
//! When the app packs its own SPS and PPS, what they say (POC LSB length,
//! output flags, extra slice header bits, cabac_init_present, the
//! deblocking override, lists modification, the SPS's RPS count) is read
//! from them (enc_parse.sig) and given to the engine instead.
//!
//! Main (4:2:0 8-bit); P pictures with up to MAX_L0 references, B pictures
//! (random access or low delay) with up to MAX_L0 and MAX_L1; CTBs of 16
//! to 64.
//!
//! Pure: no calls, no state.

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const nvenc = @import("nvenc.sig");
const bits = @import("bits.sig");
const h264 = @import("enc_h264.sig");
const enc_rc = @import("enc_rc.sig");
const enc_parse = @import("enc_parse.sig");

const H = nvenc.H265;

pub const PROFILE = va.PROFILE_HEVC_MAIN;
pub const Seq = ve.EncSequenceParameterBufferHEVC;
pub const Pic = ve.EncPictureParameterBufferHEVC;

/// log2_max_pic_order_cnt_lsb_minus4 of the driver's own SPS (FFmpeg's
/// choice too); an app's packed SPS gives its own (enc_parse.HevcParams).
pub const POC_LSB_MINUS4: u32 = 8;
pub const MAX_L0 = h264.MAX_L0;
pub const MAX_L1 = h264.MAX_L1;
const LIST = h264.LIST;
/// The DPB the driver's VPS and SPS declare (references and the picture).
pub const DPB = MAX_L0 + MAX_L1 + 1;

/// VAConfigAttribValEncHEVCFeatures this driver answers: AMP, SAO,
/// temporal MVP, strong intra smoothing, CU QP delta supported (1), the
/// rest not (0); two bits each, in va_enc_hevc.h's order.
pub const FEATURES: u32 = (1 << 4) | (1 << 6) | (1 << 10) | (1 << 12) | (1 << 22);
/// VAConfigAttribValEncHEVCBlockSizes: CTBs 32 (max and min), CBs from
/// 16, transforms 4 to 32, hierarchy depth up to 2.
///
/// The smallest CB is what FFmpeg aligns its surfaces and the SPS's
/// picture size to (hw_base_encode_h265: surface = size aligned to
/// min_cb_size). With 8 here a 1080-row picture stayed 1080 rows, and
/// the engine was given a height that is no whole number of macroblocks;
/// NVENC encodes whole 16x16 blocks (nvenc_drv.h 2.1), NVIDIA's own HEVC
/// streams are 1088 rows with a conformance window, and Tegra's NVENC
/// never finished an H.264 picture 1080 rows high (switch-frame-tap's
/// M91 Run R: 1088 encodes, 1080 never completes). With 16 the picture is
/// 1088 rows and the stream's conformance window crops it.
pub const BLOCK_SIZES: u32 = 2 | (2 << 2) | (1 << 4) | (3 << 6) | (0 << 8) | (2 << 10) | (0 << 12) | (2 << 14) | (0 << 16);
/// The smallest CB BLOCK_SIZES offers (log2 - 3).
pub const MIN_CB_MINUS3: u32 = (BLOCK_SIZES >> 4) & 3;

pub const Slice = struct {
    address: u32 = 0,
    num_ctu: u32 = 0,
    /// 0 B, 1 P, 2 I
    slice_type: u8 = 2,
    l0_minus1: u8 = 0,
    l1_minus1: u8 = 0,
    override: bool = false,
    cabac_init: bool = false,
    max_num_merge_cand: u8 = 5,
    qp_delta: i8 = 0,
    beta: i8 = 0,
    tc: i8 = 0,
    sao_luma: bool = false,
    sao_chroma: bool = false,
    temporal_mvp: bool = false,
    deblocking_disabled: bool = false,
    loop_filter_across_slices: bool = false,
    collocated_from_l0: bool = true,
    ref0: [LIST]u32 = [_]u32{va.INVALID_ID} ** LIST,
    ref1: [LIST]u32 = [_]u32{va.INVALID_ID} ** LIST,

    pub fn of(s: *const ve.EncSliceParameterBufferHEVC) Slice {
        const f = s.slice_fields;
        var r = Slice{
            .address = s.slice_segment_address,
            .num_ctu = s.num_ctu_in_slice,
            .slice_type = s.slice_type,
            .l0_minus1 = s.num_ref_idx_l0_active_minus1,
            .l1_minus1 = s.num_ref_idx_l1_active_minus1,
            .cabac_init = f.cabac_init_flag != 0,
            .override = f.num_ref_idx_active_override_flag != 0,
            .max_num_merge_cand = if (s.max_num_merge_cand == 0) 5 else s.max_num_merge_cand,
            .qp_delta = s.slice_qp_delta,
            .beta = s.slice_beta_offset_div2,
            .tc = s.slice_tc_offset_div2,
            .sao_luma = f.slice_sao_luma_flag != 0,
            .sao_chroma = f.slice_sao_chroma_flag != 0,
            .temporal_mvp = f.slice_temporal_mvp_enabled_flag != 0,
            .deblocking_disabled = f.slice_deblocking_filter_disabled_flag != 0,
            .loop_filter_across_slices = f.slice_loop_filter_across_slices_enabled_flag != 0,
            .collocated_from_l0 = f.collocated_from_l0_flag != 0 or s.slice_type != 0,
        };
        for (&r.ref0, &r.ref1, 0..) |*id0, *id1, k| {
            const p = s.ref_pic_list0[k];
            id0.* = if (p.flags & va.PICTURE_HEVC_INVALID != 0) va.INVALID_ID else p.picture_id;
            const q = s.ref_pic_list1[k];
            id1.* = if (q.flags & va.PICTURE_HEVC_INVALID != 0) va.INVALID_ID else q.picture_id;
        }
        return r;
    }

    /// The active entries of list `l` (B slices have both).
    pub fn list(s: *const Slice, l: u1) []const u32 {
        if (s.slice_type == 2) return s.ref0[0..0];
        if (l == 0) return s.ref0[0..@min(@as(usize, s.l0_minus1) + 1, LIST)];
        if (s.slice_type != 0) return s.ref1[0..0];
        return s.ref1[0..@min(@as(usize, s.l1_minus1) + 1, LIST)];
    }

    /// collocated_ref_idx: where the picture's collocated reference
    /// (VA's collocated_ref_pic_index names it in reference_frames) is in
    /// the list it comes from.
    pub fn collocatedIdx(s: *const Slice, id: u32) u8 {
        const l = s.list(if (s.collocated_from_l0) 0 else 1);
        return @intCast(std.mem.indexOfScalar(u32, l, id) orelse 0);
    }
};

pub fn checkSlices(slices: []const Slice) va.Status {
    for (slices) |s| {
        if (s.slice_type != slices[0].slice_type) return va.ERROR_INVALID_PARAMETER;
        if (s.slice_type != 2 and s.l0_minus1 + 1 > MAX_L0) return va.ERROR_MAX_NUM_EXCEEDED;
        if (s.slice_type == 0 and s.l1_minus1 + 1 > MAX_L1) return va.ERROR_MAX_NUM_EXCEEDED;
    }
    return va.SUCCESS;
}

fn ctbLog2(seq: *const Seq) u32 {
    return @as(u32, seq.log2_min_luma_coding_block_size_minus3) + 3 + seq.log2_diff_max_min_luma_coding_block_size;
}

pub fn check(seq: *const Seq, pic: *const Pic) va.Status {
    const sf = seq.seq_fields;
    if (sf.chroma_format_idc != 1 or sf.bit_depth_luma_minus8 != 0 or sf.bit_depth_chroma_minus8 != 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
    if (sf.scaling_list_enabled_flag != 0 or sf.pcm_enabled_flag != 0 or sf.separate_colour_plane_flag != 0) return va.ERROR_INVALID_PARAMETER;
    const ctb = ctbLog2(seq);
    if (ctb < 4 or ctb > 6) return va.ERROR_INVALID_PARAMETER;
    const tb_min = @as(u32, seq.log2_min_transform_block_size_minus2) + 2;
    const tb_max = tb_min + seq.log2_diff_max_min_transform_block_size;
    if (tb_max > 5 or tb_max > ctb) return va.ERROR_INVALID_PARAMETER;
    const pf = pic.pic_fields;
    if (pf.tiles_enabled_flag != 0 or pf.weighted_pred_flag != 0 or pf.weighted_bipred_flag != 0 or pf.transquant_bypass_enabled_flag != 0 or pf.scaling_list_data_present_flag != 0 or pf.dependent_slice_segments_enabled_flag != 0) return va.ERROR_INVALID_PARAMETER;
    return va.SUCCESS;
}

// ── The parameter sets ──────────────────────────────────────────────────────

/// profile_tier_level(1, 0): Main, progressive frames.
fn profileTierLevel(w: *bits.Writer, seq: *const Seq) void {
    w.u(2, 0); // general_profile_space
    w.u(1, seq.general_tier_flag);
    w.u(5, 1); // general_profile_idc: Main
    // general_profile_compatibility_flag[32]: Main (1) and Main 10 (2)
    w.u(32, 0x6000_0000);
    w.flag(true); // general_progressive_source_flag
    w.flag(false); // general_interlaced_source_flag
    w.flag(false); // general_non_packed_constraint_flag
    w.flag(true); // general_frame_only_constraint_flag
    w.u(32, 0); // general_reserved_zero_43bits (and general_inbld_flag)
    w.u(12, 0);
    w.u(8, seq.general_level_idc);
}

/// The VPS, SPS and PPS as three NAL units into `out` (`width` and
/// `height`: the picture's display size, for the conformance window).
pub fn writeHeadersSized(out: []u8, seq: *const Seq, pic: *const Pic, width: u32, height: u32) ?usize {
    var n: usize = 0;
    var rbsp: [512]u8 = undefined;
    // ── VPS ──
    var w = bits.Writer.init(&rbsp);
    w.u(16, 0x4001); // VPS_NUT (32), layer 0, temporal id 1
    w.u(4, 0); // vps_video_parameter_set_id
    w.flag(true); // vps_base_layer_internal_flag
    w.flag(true); // vps_base_layer_available_flag
    w.u(6, 0); // vps_max_layers_minus1
    w.u(3, 0); // vps_max_sub_layers_minus1
    w.flag(true); // vps_temporal_id_nesting_flag
    w.u(16, 0xffff);
    profileTierLevel(&w, seq);
    const reorder: u32 = if (seq.ip_period > 1) @min(seq.ip_period - 1, DPB - 1) else 0;
    w.flag(false); // vps_sub_layer_ordering_info_present_flag
    w.ue(DPB - 1); // vps_max_dec_pic_buffering_minus1: the references and the picture
    w.ue(reorder); // vps_max_num_reorder_pics
    w.ue(0); // vps_max_latency_increase_plus1
    w.u(6, 0); // vps_max_layer_id
    w.ue(0); // vps_num_layer_sets_minus1
    w.flag(false); // vps_timing_info_present_flag
    w.flag(false); // vps_extension_flag
    w.trailing();
    if (w.overflow) return null;
    n += bits.nal(out[n..], w.bytes(), 2) orelse return null;
    // ── SPS ──
    w = bits.Writer.init(&rbsp);
    const sf = seq.seq_fields;
    w.u(16, 0x4201); // SPS_NUT (33)
    w.u(4, 0); // sps_video_parameter_set_id
    w.u(3, 0); // sps_max_sub_layers_minus1
    w.flag(true); // sps_temporal_id_nesting_flag
    profileTierLevel(&w, seq);
    w.ue(0); // sps_seq_parameter_set_id
    w.ue(1); // chroma_format_idc
    const pw: u32 = seq.pic_width_in_luma_samples;
    const ph: u32 = seq.pic_height_in_luma_samples;
    w.ue(pw);
    w.ue(ph);
    const crop = width < pw or height < ph;
    w.flag(crop);
    if (crop) {
        w.ue(0);
        w.ue((pw - @min(width, pw)) / 2);
        w.ue(0);
        w.ue((ph - @min(height, ph)) / 2);
    }
    w.ue(0); // bit_depth_luma_minus8
    w.ue(0); // bit_depth_chroma_minus8
    w.ue(POC_LSB_MINUS4);
    w.flag(false); // sps_sub_layer_ordering_info_present_flag
    w.ue(DPB - 1); // sps_max_dec_pic_buffering_minus1
    w.ue(reorder); // sps_max_num_reorder_pics
    w.ue(0); // sps_max_latency_increase_plus1
    w.ue(seq.log2_min_luma_coding_block_size_minus3);
    w.ue(seq.log2_diff_max_min_luma_coding_block_size);
    w.ue(seq.log2_min_transform_block_size_minus2);
    w.ue(seq.log2_diff_max_min_transform_block_size);
    w.ue(seq.max_transform_hierarchy_depth_inter);
    w.ue(seq.max_transform_hierarchy_depth_intra);
    w.flag(false); // scaling_list_enabled_flag
    w.flag(sf.amp_enabled_flag != 0);
    w.flag(sf.sample_adaptive_offset_enabled_flag != 0);
    w.flag(false); // pcm_enabled_flag
    w.ue(0); // num_short_term_ref_pic_sets: each slice has its own
    w.flag(false); // long_term_ref_pics_present_flag
    w.flag(sf.sps_temporal_mvp_enabled_flag != 0);
    w.flag(sf.strong_intra_smoothing_enabled_flag != 0);
    const vf = seq.vui_fields;
    w.flag(seq.vui_parameters_present_flag != 0);
    if (seq.vui_parameters_present_flag != 0) {
        w.flag(vf.aspect_ratio_info_present_flag != 0);
        if (vf.aspect_ratio_info_present_flag != 0) {
            w.u(8, seq.aspect_ratio_idc);
            if (seq.aspect_ratio_idc == 255) {
                w.u(16, seq.sar_width);
                w.u(16, seq.sar_height);
            }
        }
        w.flag(false); // overscan_info_present_flag
        w.flag(false); // video_signal_type_present_flag
        w.flag(false); // chroma_loc_info_present_flag
        w.flag(false); // neutral_chroma_indication_flag
        w.flag(false); // field_seq_flag
        w.flag(false); // frame_field_info_present_flag
        w.flag(false); // default_display_window_flag
        w.flag(vf.vui_timing_info_present_flag != 0);
        if (vf.vui_timing_info_present_flag != 0) {
            w.u(32, seq.vui_num_units_in_tick);
            w.u(32, seq.vui_time_scale);
            w.flag(false); // vui_poc_proportional_to_timing_flag
            w.flag(false); // vui_hrd_parameters_present_flag
        }
        w.flag(vf.bitstream_restriction_flag != 0);
        if (vf.bitstream_restriction_flag != 0) {
            w.flag(false); // tiles_fixed_structure_flag
            w.flag(vf.motion_vectors_over_pic_boundaries_flag != 0);
            w.flag(vf.restricted_ref_pic_lists_flag != 0);
            w.ue(seq.min_spatial_segmentation_idc);
            w.ue(seq.max_bytes_per_pic_denom);
            w.ue(seq.max_bits_per_min_cu_denom);
            w.ue(vf.log2_max_mv_length_horizontal);
            w.ue(vf.log2_max_mv_length_vertical);
        }
    }
    w.flag(false); // sps_extension_present_flag
    w.trailing();
    if (w.overflow) return null;
    n += bits.nal(out[n..], w.bytes(), 2) orelse return null;
    // ── PPS ──
    w = bits.Writer.init(&rbsp);
    const pf = pic.pic_fields;
    w.u(16, 0x4401); // PPS_NUT (34)
    w.ue(pic.slice_pic_parameter_set_id);
    w.ue(0); // pps_seq_parameter_set_id
    w.flag(false); // dependent_slice_segments_enabled_flag
    w.flag(false); // output_flag_present_flag
    w.u(3, 0); // num_extra_slice_header_bits
    w.flag(pf.sign_data_hiding_enabled_flag != 0);
    w.flag(false); // cabac_init_present_flag
    w.ue(pic.num_ref_idx_l0_default_active_minus1);
    w.ue(pic.num_ref_idx_l1_default_active_minus1);
    w.se(@as(i32, pic.pic_init_qp) - 26);
    w.flag(pf.constrained_intra_pred_flag != 0);
    w.flag(pf.transform_skip_enabled_flag != 0);
    w.flag(pf.cu_qp_delta_enabled_flag != 0);
    if (pf.cu_qp_delta_enabled_flag != 0) w.ue(pic.diff_cu_qp_delta_depth);
    w.se(pic.pps_cb_qp_offset);
    w.se(pic.pps_cr_qp_offset);
    w.flag(false); // pps_slice_chroma_qp_offsets_present_flag
    w.flag(false); // weighted_pred_flag
    w.flag(false); // weighted_bipred_flag
    w.flag(false); // transquant_bypass_enabled_flag
    w.flag(false); // tiles_enabled_flag
    w.flag(pf.entropy_coding_sync_enabled_flag != 0);
    w.flag(pf.pps_loop_filter_across_slices_enabled_flag != 0);
    w.flag(false); // deblocking_filter_control_present_flag
    w.flag(false); // pps_scaling_list_data_present_flag
    w.flag(false); // lists_modification_present_flag
    w.ue(pic.log2_parallel_merge_level_minus2);
    w.flag(false); // slice_segment_header_extension_present_flag
    w.flag(false); // pps_extension_present_flag
    w.trailing();
    if (w.overflow) return null;
    n += bits.nal(out[n..], w.bytes(), 2) orelse return null;
    return n;
}

// ── The engine's picture setup ──────────────────────────────────────────────

pub const Setup = struct {
    seq: *const Seq,
    pic: *const Pic,
    slices: []const Slice,
    input: h264.Planes,
    recon: h264.Planes,
    ref_ids: [nvenc.REF_SLOTS]u32,
    ref_poc: [nvenc.REF_SLOTS]i32,
    /// what the app's packed SPS and PPS say (the driver's own when none)
    params: enc_parse.HevcParams = .{},
    /// the collocated picture (VA's collocated_ref_pic_index's surface)
    collocated_id: u32 = va.INVALID_ID,
    qp: u8,
    gop_length: u32,
    framerate: u32,
    bitstream_start: u32,
    bitstream_room: u32,
    history_bytes: u32,
    magic: u32 = nvenc.MAGIC,
};

/// pic_type: 0 P, 1 B, 2 I, 3 IDR (VA's coding_type: 1 I, 2 P, 3 B).
pub fn picType(pic: *const Pic) u2 {
    if (pic.pic_fields.idr_pic_flag != 0) return 3;
    return switch (pic.pic_fields.coding_type) {
        2 => 0,
        3 => 1,
        else => 2,
    };
}

fn log2Size(v: u32) u2 {
    // 8 -> 0, 16 -> 1, 32 -> 2, 64 -> 3 (CUs); 4 -> 0 .. 32 -> 3 (TUs)
    return @intCast(v);
}

pub fn setup(buf: []u8, s: Setup) void {
    @memset(buf[0..nvenc.SETUP_BYTES], 0);
    const pic = s.pic;
    const seq = s.seq;
    const pf = pic.pic_fields;
    const sf = seq.seq_fields;
    const w: u32 = seq.pic_width_in_luma_samples;
    const h: u32 = seq.pic_height_in_luma_samples;
    nvenc.set(buf, H.magic, s.magic);
    const cfgs = [_][4]nvenc.F{
        .{ H.refpic_cfg_frame_width_minus1, H.refpic_cfg_frame_height_minus1, H.refpic_cfg_sfc_pitch, H.refpic_cfg_sfc_pitch_chroma },
        .{ H.input_cfg_frame_width_minus1, H.input_cfg_frame_height_minus1, H.input_cfg_sfc_pitch, H.input_cfg_sfc_pitch_chroma },
        .{ H.outputpic_cfg_frame_width_minus1, H.outputpic_cfg_frame_height_minus1, H.outputpic_cfg_sfc_pitch, H.outputpic_cfg_sfc_pitch_chroma },
    };
    for (cfgs, 0..) |c, i| {
        const p = if (i == 1) s.input else s.recon;
        nvenc.set(buf, c[0], w - 1);
        nvenc.set(buf, c[1], h - 1);
        nvenc.set(buf, c[2], p.pitch_luma);
        nvenc.set(buf, c[3], p.pitch_chroma);
    }
    nvenc.set(buf, H.refpic_cfg_tiled_16x16, 1);
    nvenc.set(buf, H.outputpic_cfg_tiled_16x16, 1);
    nvenc.set(buf, H.input_cfg_block_height, nvenc.blockHeightField(s.input.block_height));
    // sps_data
    const min_cb = @as(u32, seq.log2_min_luma_coding_block_size_minus3);
    const ctb = ctbLog2(seq);
    const min_tb = @as(u32, seq.log2_min_transform_block_size_minus2);
    nvenc.set(buf, H.chroma_format_idc, 1);
    const prm = s.params;
    nvenc.set(buf, H.log2_max_pic_order_cnt_lsb_minus4, prm.log2_max_poc_lsb_minus4);
    nvenc.set(buf, H.min_cu_size, log2Size(min_cb));
    nvenc.set(buf, H.max_cu_size, log2Size(ctb - 3));
    nvenc.set(buf, H.min_tu_size, log2Size(min_tb));
    nvenc.set(buf, H.max_tu_size, log2Size(min_tb + seq.log2_diff_max_min_transform_block_size));
    nvenc.set(buf, H.max_transform_depth_inter, @min(seq.max_transform_hierarchy_depth_inter, 3));
    nvenc.set(buf, H.max_transform_depth_intra, @min(seq.max_transform_hierarchy_depth_intra, 3));
    nvenc.set(buf, H.amp_enabled_flag, sf.amp_enabled_flag);
    nvenc.set(buf, H.strong_intra_smoothing_enabled_flag, sf.strong_intra_smoothing_enabled_flag);
    nvenc.set(buf, H.sample_adaptive_offset_enabled_flag, if (prm.have_sps) @intFromBool(prm.sao) else sf.sample_adaptive_offset_enabled_flag);
    nvenc.set(buf, H.sps_temporal_mvp_enabled_flag, if (prm.have_sps) @intFromBool(prm.temporal_mvp) else sf.sps_temporal_mvp_enabled_flag);
    nvenc.set(buf, H.num_short_term_ref_pic_sets, prm.num_short_term_ref_pic_sets);
    // (the app's PPS: what its slice headers carry)
    nvenc.set(buf, H.output_flag_present_flag, @intFromBool(prm.output_flag_present));
    nvenc.set(buf, H.num_extra_slice_header_bits, prm.num_extra_slice_header_bits);
    nvenc.set(buf, H.cabac_init_present_flag, @intFromBool(prm.cabac_init_present));
    nvenc.set(buf, H.deblocking_filter_override_enabled_flag, @intFromBool(prm.deblocking_override_enabled));
    nvenc.set(buf, H.pps_slice_chroma_qp_offsets_present, @intFromBool(prm.slice_chroma_qp_offsets_present));
    nvenc.set(buf, H.lists_modification_present_flag, @intFromBool(prm.lists_modification_present));
    // pps_data
    nvenc.set(buf, H.pic_param_set_id, pic.slice_pic_parameter_set_id);
    nvenc.set(buf, H.pps_num_ref_idx_l0_active_minus1, pic.num_ref_idx_l0_default_active_minus1);
    nvenc.set(buf, H.pps_num_ref_idx_l1_active_minus1, pic.num_ref_idx_l1_default_active_minus1);
    nvenc.set(buf, H.constrained_intra_pred_flag, pf.constrained_intra_pred_flag);
    nvenc.set(buf, H.transform_skip_enabled_flag, pf.transform_skip_enabled_flag);
    nvenc.set(buf, H.pps_loop_filter_across_slices_enabled_flag, pf.pps_loop_filter_across_slices_enabled_flag);
    nvenc.set(buf, H.cu_qp_delta_enabled_flag, pf.cu_qp_delta_enabled_flag);
    nvenc.set(buf, H.diff_cu_qp_delta_depth, @min(pic.diff_cu_qp_delta_depth, 3));
    nvenc.setSigned(buf, H.pic_init_qp_minus26, @as(i64, pic.pic_init_qp) - 26);
    nvenc.setSigned(buf, H.pps_cb_qp_offset, pic.pps_cb_qp_offset);
    nvenc.setSigned(buf, H.pps_cr_qp_offset, pic.pps_cr_qp_offset);
    nvenc.set(buf, H.sign_data_hiding_enabled_flag, pf.sign_data_hiding_enabled_flag);
    nvenc.set(buf, H.log2_parallel_merge_level_minus2, @min(pic.log2_parallel_merge_level_minus2, 7));
    enc_rc.constQp(buf, enc_rc.RcFields.of(H), s.qp, s.framerate, s.gop_length);
    // the short-term RPS (in the slice header): every reference kept,
    // those before this picture nearest first (S0), then those after it
    // nearest first (S1); the RPS's entries are S0's then S1's
    const cur = pic.decoded_curr_pic.pic_order_cnt;
    var neg: [nvenc.REF_SLOTS]u8 = undefined;
    var pos: [nvenc.REF_SLOTS]u8 = undefined;
    var nneg: u32 = 0;
    var npos: u32 = 0;
    for (s.ref_ids, 0..) |id, i| {
        if (id == va.INVALID_ID or s.ref_poc[i] == cur) continue;
        if (s.ref_poc[i] < cur) {
            neg[nneg] = @intCast(i);
            nneg += 1;
        } else {
            pos[npos] = @intCast(i);
            npos += 1;
        }
    }
    const Order = struct {
        fn before(ss: *const Setup, a: u8, b: u8) bool {
            return ss.ref_poc[a] > ss.ref_poc[b];
        }
        fn after(ss: *const Setup, a: u8, b: u8) bool {
            return ss.ref_poc[a] < ss.ref_poc[b];
        }
    };
    std.mem.sort(u8, neg[0..nneg], &s, Order.before);
    std.mem.sort(u8, pos[0..npos], &s, Order.after);
    const first = s.slices[0];
    const l0 = first.list(0);
    const l1 = first.list(1);
    const sides = [2][]const u8{ neg[0..nneg], pos[0..npos] };
    const deltas = [2]nvenc.F{ H.st_delta_poc_s0_minus1, H.st_delta_poc_s1_minus1 };
    const used_f = [2]nvenc.F{ H.st_used_by_curr_pic_s0_flag, H.st_used_by_curr_pic_s1_flag };
    for (sides, 0..) |side, si| {
        var used: u32 = 0;
        var prev = cur;
        for (side, 0..) |slot, k| {
            const kk: u32 = @intCast(k);
            const gap = if (si == 0) prev - s.ref_poc[slot] else s.ref_poc[slot] - prev;
            nvenc.set(buf, nvenc.at(deltas[si], kk), @as(u64, @intCast(gap - 1)));
            prev = s.ref_poc[slot];
            const id = s.ref_ids[slot];
            if (std.mem.indexOfScalar(u32, l0, id) != null or std.mem.indexOfScalar(u32, l1, id) != null) used |= @as(u32, 1) << @intCast(k);
        }
        nvenc.set(buf, used_f[si], used);
    }
    nvenc.set(buf, H.st_num_negative_pics, nneg);
    nvenc.set(buf, H.st_num_positive_pics, npos);
    // the lists: slots, distances, and each entry's place in the RPS
    for (0..8) |k| {
        const kk: u32 = @intCast(k);
        // (unused: the lists -2 and the distances -1, as NVIDIA's driver
        // writes H.264's; nvenc.LIST_NONE)
        nvenc.set(buf, nvenc.at(H.l0, kk), nvenc.LIST_NONE);
        nvenc.set(buf, nvenc.at(H.l1, kk), nvenc.LIST_NONE);
        nvenc.set(buf, nvenc.at(H.temp_dist_l0, kk), nvenc.DIST_NONE);
        nvenc.set(buf, nvenc.at(H.temp_dist_l1, kk), nvenc.DIST_NONE);
        nvenc.set(buf, nvenc.at(H.poc_entry_l0, kk), 0xff);
        nvenc.set(buf, nvenc.at(H.poc_entry_l1, kk), 0xff);
    }
    const lf = [2][3]nvenc.F{ .{ H.l0, H.temp_dist_l0, H.poc_entry_l0 }, .{ H.l1, H.temp_dist_l1, H.poc_entry_l1 } };
    for ([2][]const u32{ l0, l1 }, 0..) |l, li| {
        for (l, 0..) |id, k| {
            const kk: u32 = @intCast(k);
            if (id == va.INVALID_ID) continue;
            const slot = std.mem.indexOfScalar(u32, &s.ref_ids, id) orelse continue;
            nvenc.set(buf, nvenc.at(lf[li][0], kk), slot);
            nvenc.setSigned(buf, nvenc.at(lf[li][1], kk), std.math.clamp(cur - s.ref_poc[slot], -128, 127));
            const su: u8 = @intCast(slot);
            const e: u32 = if (std.mem.indexOfScalar(u8, neg[0..nneg], su)) |e0| @intCast(e0) else if (std.mem.indexOfScalar(u8, pos[0..npos], su)) |e1| nneg + @as(u32, @intCast(e1)) else continue;
            nvenc.set(buf, nvenc.at(lf[li][2], kk), e);
        }
    }
    nvenc.set(buf, H.pic_output_flag, 1);
    const poc_lsb = @as(u32, @bitCast(cur)) & ((@as(u32, 1) << @intCast(@as(u32, prm.log2_max_poc_lsb_minus4) + 4)) - 1);

    nvenc.set(buf, H.pic_order_cnt_lsb, poc_lsb);
    nvenc.set(buf, H.num_forced_slices_minus1, s.slices.len - 1);
    nvenc.set(buf, H.slice_control_offset, nvenc.H265_SLICE_OFF);
    nvenc.set(buf, H.me_control_offset, nvenc.H265_ME_OFF);
    nvenc.set(buf, H.md_control_offset, nvenc.H265_MD_OFF);
    nvenc.set(buf, H.q_control_offset, nvenc.H265_Q_OFF);
    nvenc.set(buf, H.hist_buf_size, s.history_bytes);
    nvenc.set(buf, H.bitstream_buf_size, s.bitstream_room);
    nvenc.set(buf, H.bitstream_start_pos, s.bitstream_start);
    nvenc.set(buf, H.pic_type, picType(pic));
    nvenc.set(buf, H.ref_pic_flag, pf.reference_pic_flag);
    nvenc.set(buf, H.slice_mode, 1);
    const ctb_size = @as(u32, 1) << @intCast(ctb);
    const ctbs = ((w + ctb_size - 1) / ctb_size) * ((h + ctb_size - 1) / ctb_size);
    nvenc.set(buf, H.ceil_log2_pic_size_in_ctbs, std.math.log2_int_ceil(u32, @max(ctbs, 1)));
    // the whole picture one strip of its CTB rows (as H.264's), the
    // statistics where nvenc_h265_stat_data_s has them
    nvenc.set(buf, H.strips_in_frame, 1);
    nvenc.set(buf, H.slice_encoding_row_num, (h + ctb_size - 1) / ctb_size);
    nvenc.set(buf, H.slice_stat_offset, nvenc.SLICE_STAT_OFF);
    nvenc.set(buf, H.mpec_stat_offset, nvenc.MPEC_STAT_OFF);
    nvenc.set(buf, H.short_term_ref_pic_set_sps_flag, 0);
    nvenc.set(buf, H.e4byte_start_code, 1);
    nvenc.set(buf, H.nal_unit_type, pic.nal_unit_type);
    nvenc.set(buf, H.nuh_temporal_id_plus1, 1);
    nvenc.set(buf, H.gp_timer_timeout_val, nvenc.GPTIMER_TIMEOUT);
    for (s.slices, 0..) |sl, i| {
        const c = buf[nvenc.H265_SLICE_OFF + i * nvenc.H265Slice.SIZE ..];
        const L = nvenc.H265Slice;
        nvenc.set(c, L.num_ctus, sl.num_ctu);
        nvenc.set(c, L.qp_avr, s.qp);
        nvenc.set(c, L.qp_slice_min, s.qp);
        nvenc.set(c, L.qp_slice_max, s.qp);
        nvenc.set(c, L.slice_type, sl.slice_type);
        nvenc.set(c, L.five_minus_max_num_merge_cand, 5 - @min(sl.max_num_merge_cand, 5));
        nvenc.set(c, L.slice_deblocking_filter_disabled_flag, @intFromBool(sl.deblocking_disabled));
        nvenc.set(c, L.slice_loop_filter_across_slices_enabled_flag, @intFromBool(sl.loop_filter_across_slices));
        nvenc.set(c, L.slice_sao_luma_flag, @intFromBool(sl.sao_luma));
        nvenc.set(c, L.slice_sao_chroma_flag, @intFromBool(sl.sao_chroma));
        nvenc.set(c, L.slice_temporal_mvp_enabled_flag, @intFromBool(sl.temporal_mvp));
        nvenc.set(c, L.collocated_from_l0_flag, @intFromBool(sl.collocated_from_l0));
        nvenc.set(c, L.num_ref_idx_active_override_flag, @intFromBool(sl.override));
        nvenc.set(c, L.num_ref_idx_l0_active_minus1, sl.l0_minus1);
        nvenc.set(c, L.num_ref_idx_l1_active_minus1, if (sl.slice_type == 0) sl.l1_minus1 else 0);
        nvenc.set(c, L.collocated_ref_idx, if (s.collocated_id != va.INVALID_ID) sl.collocatedIdx(s.collocated_id) else 0);
        nvenc.set(c, L.cabac_init_flag, @intFromBool(sl.cabac_init and prm.cabac_init_present));
    }
    nvenc.meControl(buf[nvenc.H265_ME_OFF..]);
    const md = buf[nvenc.H265_MD_OFF..];
    const D = nvenc.H265Md;
    for ([_]nvenc.F{ D.luma4x4_modes, D.luma8x8_modes, D.luma16x16_modes, D.luma32x32_modes, D.luma64x64_modes }) |f| nvenc.set(md, f, 0xffff_ffff);
    nvenc.set(md, D.luma_modes_leftbits, 0x3fff_ffff);
    nvenc.set(md, D.cu16x16_part_2Nx2N_enable, 1);
    nvenc.set(md, D.cu32x32_part_2Nx2N_enable, 1);
    nvenc.set(md, D.cu64x64_part_2Nx2N_enable, @intFromBool(ctb == 6));
    nvenc.set(md, D.intra_mode_4x4_enable, 1);
    nvenc.set(md, D.intra_mode_8x8_enable, 1);
    nvenc.set(md, D.intra_mode_16x16_enable, 1);
    nvenc.set(md, D.intra_mode_32x32_enable, @intFromBool(ctb >= 5));
    nvenc.set(md, D.intra_mode_64x64_enable, @intFromBool(ctb == 6));
    nvenc.set(md, D.chroma_modes, 0x1f);
    nvenc.set(md, D.tusize_4x4_enable, 1);
    nvenc.set(md, D.tusize_8x8_enable, 1);
    nvenc.set(md, D.tusize_16x16_enable, 1);
    nvenc.set(md, D.tusize_32x32_enable, @intFromBool(min_tb + seq.log2_diff_max_min_transform_block_size >= 3));
    nvenc.set(md, D.pskip_enable, 1);
    nvenc.set(md, D.mv_cost_enable, 1);
    nvenc.set(md, D.ip_search_mode, 0xf);
    // the mode decision's search depth as NVIDIA's H.264 MD control sets
    // its own (MD_NVIDIA_H264: RDO level 1, two transform searches, one
    // SSD candidate for each intra size, early termination); this
    // driver left them 0 before
    nvenc.set(md, D.rdo_level, 1);
    nvenc.set(md, D.tu_search_num_cu16, 2);
    nvenc.set(md, D.tu_search_num_cu32, 2);
    for (0..4) |k| nvenc.set(md, .{ .bit = D.intra_ssd_cnt_4x4.bit + 4 * @as(u32, @intCast(k)), .width = 4 }, 1);
    nvenc.set(md, D.early_termination_ip1, 1);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

pub fn testSeq(w: u16, h: u16) Seq {
    var s = std.mem.zeroes(Seq);
    s.general_profile_idc = 1;
    s.general_level_idc = 93;
    s.intra_period = 30;
    s.ip_period = 1;
    s.pic_width_in_luma_samples = w;
    s.pic_height_in_luma_samples = h;
    s.seq_fields = .{ .chroma_format_idc = 1, .amp_enabled_flag = 1, .strong_intra_smoothing_enabled_flag = 1 };
    s.log2_min_luma_coding_block_size_minus3 = 0;
    s.log2_diff_max_min_luma_coding_block_size = 2;
    s.log2_min_transform_block_size_minus2 = 0;
    s.log2_diff_max_min_transform_block_size = 3;
    s.max_transform_hierarchy_depth_inter = 2;
    s.max_transform_hierarchy_depth_intra = 2;
    return s;
}

pub fn testPic(target: u32, coded: u32, idr: bool, poc: i32) Pic {
    var p = std.mem.zeroes(Pic);
    p.decoded_curr_pic = .{ .picture_id = target, .pic_order_cnt = poc, .flags = 0 };
    for (&p.reference_frames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    p.coded_buf = coded;
    p.pic_init_qp = 30;
    p.nal_unit_type = if (idr) 19 else 1;
    p.pic_fields = .{ .idr_pic_flag = @intFromBool(idr), .coding_type = if (idr) 1 else 2, .reference_pic_flag = 1, .pps_loop_filter_across_slices_enabled_flag = 1 };
    return p;
}

test "enc_hevc: the parameter sets start as they must" {
    const seq = testSeq(64, 48);
    const pic = testPic(0x400, 0x1000, true, 0);
    var out: [256]u8 = undefined;
    const n = writeHeadersSized(&out, &seq, &pic, 60, 44).?;
    // VPS: 40 01, id 0 + flags 1 1 + 0 layers: 0000 11 00; 0000 000 1: 0c 01;
    // ff ff; Main: 01, compatible with 1 and 2: 60 00 00 (03) 00
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60, 0, 0, 3 }, out[0..15]);
    // the SPS and PPS follow, each its own NAL unit
    var starts: usize = 0;
    var i: usize = 0;
    while (i + 4 <= n) : (i += 1) {
        if (out[i] == 0 and out[i + 1] == 0 and out[i + 2] == 0 and out[i + 3] == 1) starts += 1;
    }
    try testing.expectEqual(@as(usize, 3), starts);
    try testing.expectEqual(va.SUCCESS, check(&seq, &pic));
    var bad = seq;
    bad.log2_diff_max_min_luma_coding_block_size = 4;
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, check(&bad, &pic));
}

test "enc_hevc: a P picture's setup: the RPS, the lists, the slice" {
    const seq = testSeq(64, 48);
    var pic = testPic(0x402, 0x1000, false, 4);
    pic.reference_frames[0] = .{ .picture_id = 0x400, .pic_order_cnt = 0, .flags = 0 };
    pic.reference_frames[1] = .{ .picture_id = 0x401, .pic_order_cnt = 2, .flags = 0 };
    var sl = Slice{ .num_ctu = 4, .slice_type = 1, .sao_luma = true };
    sl.ref0[0] = 0x401;
    var refs = [_]u32{va.INVALID_ID} ** nvenc.REF_SLOTS;
    refs[0] = 0x400;
    refs[1] = 0x401;
    var poc = [_]i32{0} ** nvenc.REF_SLOTS;
    poc[1] = 2;
    var buf: [nvenc.SETUP_BYTES]u8 = undefined;
    const planes = h264.Planes{ .luma = 0, .chroma = 0, .pitch_luma = 64, .pitch_chroma = 64 };
    setup(&buf, .{ .seq = &seq, .pic = &pic, .slices = &.{sl}, .input = planes, .recon = planes, .ref_ids = refs, .ref_poc = poc, .qp = 33, .gop_length = 30, .framerate = 30, .bitstream_start = 100, .bitstream_room = 1 << 20, .history_bytes = 4096 });
    try testing.expectEqual(@as(u64, 63), nvenc.get(&buf, H.input_cfg_frame_width_minus1));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, H.min_cu_size));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, H.max_cu_size));
    try testing.expectEqual(@as(u64, 3), nvenc.get(&buf, H.max_tu_size));
    try testing.expectEqual(@as(u64, 8), nvenc.get(&buf, H.log2_max_pic_order_cnt_lsb_minus4));
    try testing.expectEqual(@as(u64, 4), nvenc.get(&buf, H.pic_init_qp_minus26));
    // two references before it: POC 2 (delta 2 -> 1), then POC 0 (delta 2 -> 1)
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, H.st_num_negative_pics));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, nvenc.at(H.st_delta_poc_s0_minus1, 0)));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, nvenc.at(H.st_delta_poc_s0_minus1, 1)));
    // only the nearest is used by this picture
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.st_used_by_curr_pic_s0_flag));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, nvenc.at(H.l0, 0)));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, nvenc.at(H.poc_entry_l0, 0)));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, nvenc.at(H.temp_dist_l0, 0)));
    try testing.expectEqual(@as(u64, 4), nvenc.get(&buf, H.pic_order_cnt_lsb));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, H.pic_type));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.nal_unit_type));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, H.ceil_log2_pic_size_in_ctbs)); // 2x2 CTBs of 32
    const c = buf[nvenc.H265_SLICE_OFF..];
    try testing.expectEqual(@as(u64, 4), nvenc.get(c, nvenc.H265Slice.num_ctus));
    try testing.expectEqual(@as(u64, 1), nvenc.get(c, nvenc.H265Slice.slice_type));
    try testing.expectEqual(@as(u64, 1), nvenc.get(c, nvenc.H265Slice.slice_sao_luma_flag));
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H265Slice.five_minus_max_num_merge_cand));
    // (nothing forced intra: the picture type says it)
    try testing.expectEqual(@as(u64, 0), nvenc.get(c, nvenc.H265Slice.force_intra));
}

test "enc_hevc: the controls near the setup, one strip of the CTB rows, the MD's search depth, 16-sample CBs offered" {
    // FFmpeg's surface for 1920x1080: aligned to the smallest CB offered,
    // 16: 1088 rows (the engine's whole macroblocks), not 1080
    try testing.expectEqual(@as(u32, 1), MIN_CB_MINUS3);
    const min_cb = @as(u32, 8) << @intCast(MIN_CB_MINUS3);
    try testing.expectEqual(@as(u32, 1088), std.mem.alignForward(u32, 1080, min_cb));
    try testing.expectEqual(@as(u32, 2), BLOCK_SIZES & 3); // CTB 32
    var seq = testSeq(1920, 1088);
    seq.log2_min_luma_coding_block_size_minus3 = 1;
    seq.log2_diff_max_min_luma_coding_block_size = 1;
    const pic = testPic(0x401, 0x1000, true, 0);
    const sl = Slice{ .num_ctu = 60 * 34, .slice_type = 2 };
    var buf: [nvenc.SETUP_BYTES]u8 = undefined;
    const planes = h264.Planes{ .luma = 0, .chroma = 0, .pitch_luma = 1920, .pitch_chroma = 1920 };
    setup(&buf, .{ .seq = &seq, .pic = &pic, .slices = &.{sl}, .input = planes, .recon = planes, .ref_ids = [_]u32{va.INVALID_ID} ** nvenc.REF_SLOTS, .ref_poc = [_]i32{0} ** nvenc.REF_SLOTS, .qp = 28, .gop_length = 120, .framerate = 30, .bitstream_start = 0, .bitstream_room = 1 << 22, .history_bytes = 4096 });
    try testing.expectEqual(@as(u64, 1087), nvenc.get(&buf, H.input_cfg_frame_height_minus1));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.min_cu_size));
    try testing.expectEqual(@as(u64, nvenc.H265_SLICE_OFF), nvenc.get(&buf, H.slice_control_offset));
    try testing.expectEqual(@as(u64, nvenc.H265_MD_OFF), nvenc.get(&buf, H.md_control_offset));
    try testing.expectEqual(@as(u64, nvenc.H265_Q_OFF), nvenc.get(&buf, H.q_control_offset));
    try testing.expectEqual(@as(u64, nvenc.H265_ME_OFF), nvenc.get(&buf, H.me_control_offset));
    try testing.expect(nvenc.get(&buf, H.me_control_offset) + nvenc.Me.SIZE <= 0x600);
    try testing.expectEqualSlices(u8, &nvenc.ME_NVIDIA, buf[nvenc.H265_ME_OFF..][0..nvenc.Me.SIZE]);
    try testing.expectEqual(@as(u64, 1), nvenc.get(&buf, H.strips_in_frame));
    try testing.expectEqual(@as(u64, 34), nvenc.get(&buf, H.slice_encoding_row_num)); // 1088 / 32
    try testing.expectEqual(@as(u64, 0x80), nvenc.get(&buf, H.slice_stat_offset));
    try testing.expectEqual(@as(u64, 0x1000b0), nvenc.get(&buf, H.mpec_stat_offset));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&buf, H.bitstream_start_pos));
    const md = buf[nvenc.H265_MD_OFF..];
    try testing.expectEqual(@as(u64, 1), nvenc.get(md, nvenc.H265Md.rdo_level));
    try testing.expectEqual(@as(u64, 2), nvenc.get(md, nvenc.H265Md.tu_search_num_cu16));
    try testing.expectEqual(@as(u64, 2), nvenc.get(md, nvenc.H265Md.tu_search_num_cu32));
    try testing.expectEqual(@as(u64, 0x1111), nvenc.get(md, .{ .bit = nvenc.H265Md.intra_ssd_cnt_4x4.bit, .width = 16 }));
    try testing.expectEqual(@as(u64, 60 * 34), nvenc.get(buf[nvenc.H265_SLICE_OFF..], nvenc.H265Slice.num_ctus));
    // (the controls do not overlap the setup or each other)
    for (buf[nvenc.H265.SIZE - 8 .. nvenc.H265.SIZE]) |x| try testing.expectEqual(@as(u8, 0), x);
}
