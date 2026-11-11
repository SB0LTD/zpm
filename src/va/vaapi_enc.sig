//! @zpm/va vaapi_enc — libva 2.22's encode side: the EncSlice entrypoint,
//! the config attributes an encoder answers, the encode buffer types, the
//! coded buffer's segment list, the misc parameters (rate control, frame
//! rate, HRD), packed headers, and the H.264 and HEVC sequence, picture
//! and slice parameter buffers (va.h, va_enc_h264.h, va_enc_hevc.h).
//!
//! Sizes and offsets are asserted below as gcc measures them on libva
//! 2.22's headers for x86-64 (LP64).

const std = @import("std");
const va = @import("vaapi.sig");

pub const ENTRYPOINT_ENC_SLICE: va.Entrypoint = 6;

// ── Config attributes (VAConfigAttribType) and their values ─────────────────

pub const ATTRIB_RATE_CONTROL: u32 = 5;
pub const ATTRIB_ENC_PACKED_HEADERS: u32 = 10;
pub const ATTRIB_ENC_INTERLACED: u32 = 11;
pub const ATTRIB_ENC_MAX_REF_FRAMES: u32 = 13;
pub const ATTRIB_ENC_MAX_SLICES: u32 = 14;
pub const ATTRIB_ENC_SLICE_STRUCTURE: u32 = 15;
pub const ATTRIB_ENC_QUALITY_RANGE: u32 = 21;
pub const ATTRIB_ENC_INTRA_REFRESH: u32 = 23;
pub const ATTRIB_ENC_ROI: u32 = 25;
pub const ATTRIB_MAX_FRAME_SIZE: u32 = 38;
pub const ATTRIB_PREDICTION_DIRECTION: u32 = 39;
pub const ATTRIB_ENC_HEVC_FEATURES: u32 = 50;
pub const ATTRIB_ENC_HEVC_BLOCK_SIZES: u32 = 51;

pub const RC_NONE: u32 = 0x01;
pub const RC_CBR: u32 = 0x02;
pub const RC_VBR: u32 = 0x04;
pub const RC_CQP: u32 = 0x10;

pub const PACKED_HEADER_NONE: u32 = 0;
pub const PACKED_HEADER_SEQUENCE: u32 = 0x01;
pub const PACKED_HEADER_PICTURE: u32 = 0x02;
pub const PACKED_HEADER_SLICE: u32 = 0x04;
pub const PACKED_HEADER_MISC: u32 = 0x08;
pub const PACKED_HEADER_RAW_DATA: u32 = 0x10;

pub const ENC_INTERLACED_NONE: u32 = 0;

pub const SLICE_STRUCTURE_POWER_OF_TWO_ROWS: u32 = 0x01;
pub const SLICE_STRUCTURE_ARBITRARY_MACROBLOCKS: u32 = 0x02;
pub const SLICE_STRUCTURE_EQUAL_ROWS: u32 = 0x04;
pub const SLICE_STRUCTURE_ARBITRARY_ROWS: u32 = 0x10;

// ── Buffer types (VABufferType) ─────────────────────────────────────────────

pub const ENC_CODED_BUFFER: u32 = 21;
pub const ENC_SEQUENCE_PARAMETER_BUFFER: u32 = 22;
pub const ENC_PICTURE_PARAMETER_BUFFER: u32 = 23;
pub const ENC_SLICE_PARAMETER_BUFFER: u32 = 24;
pub const ENC_PACKED_HEADER_PARAMETER_BUFFER: u32 = 25;
pub const ENC_PACKED_HEADER_DATA_BUFFER: u32 = 26;
pub const ENC_MISC_PARAMETER_BUFFER: u32 = 27;

/// VAEncPackedHeaderType.
pub const PACKED_SEQUENCE: u32 = 1;
pub const PACKED_PICTURE: u32 = 2;
pub const PACKED_SLICE: u32 = 3;
pub const PACKED_RAW_DATA: u32 = 4;
pub const PACKED_MISC_MASK: u32 = 0x8000_0000;

/// VAEncMiscParameterType.
pub const MISC_FRAME_RATE: u32 = 0;
pub const MISC_RATE_CONTROL: u32 = 1;
pub const MISC_MAX_FRAME_SIZE: u32 = 4;
pub const MISC_HRD: u32 = 5;
pub const MISC_QUALITY_LEVEL: u32 = 6;

/// VACodedBufferSegment's status: the picture overflowed the buffer.
pub const CODED_BUF_STATUS_SLICE_OVERFLOW_MASK: u32 = 0x100;

/// vaSyncBuffer's "forever".
pub const TIMEOUT_INFINITE: u64 = 0xffff_ffff_ffff_ffff;

// ── Common structs ──────────────────────────────────────────────────────────

pub const CodedBufferSegment = extern struct {
    size: u32,
    bit_offset: u32,
    status: u32,
    reserved: u32,
    buf: ?*anyopaque,
    next: ?*anyopaque,
    va_reserved: [4]u32,
};

pub const PackedHeaderParameterBuffer = extern struct {
    type: u32,
    bit_length: u32,
    has_emulation_bytes: u8,
    va_reserved: [4]u32,
};

/// VAEncMiscParameterRateControl (after the misc buffer's type word).
pub const RateControl = extern struct {
    bits_per_second: u32,
    target_percentage: u32,
    window_size: u32,
    initial_qp: u32,
    min_qp: u32,
    basic_unit_size: u32,
    rc_flags: u32,
    ICQ_quality_factor: u32,
    max_qp: u32,
    quality_factor: u32,
    target_frame_size: u32,
    va_reserved: [4]u32,
};

pub const FrameRate = extern struct {
    /// numerator in the low 16 bits, denominator in the high 16 (0: 1)
    framerate: u32,
    framerate_flags: u32,
    va_reserved: [4]u32,
};

pub const Hrd = extern struct {
    initial_buffer_fullness: u32,
    buffer_size: u32,
    va_reserved: [4]u32,
};

// ── H.264 (va_enc_h264.h) ───────────────────────────────────────────────────

pub const EncSeqFieldsH264 = packed struct(u32) {
    chroma_format_idc: u2 = 0,
    frame_mbs_only_flag: u1 = 0,
    mb_adaptive_frame_field_flag: u1 = 0,
    seq_scaling_matrix_present_flag: u1 = 0,
    direct_8x8_inference_flag: u1 = 0,
    log2_max_frame_num_minus4: u4 = 0,
    pic_order_cnt_type: u2 = 0,
    log2_max_pic_order_cnt_lsb_minus4: u4 = 0,
    delta_pic_order_always_zero_flag: u1 = 0,
    _: u15 = 0,
};

pub const EncVuiFieldsH264 = packed struct(u32) {
    aspect_ratio_info_present_flag: u1 = 0,
    timing_info_present_flag: u1 = 0,
    bitstream_restriction_flag: u1 = 0,
    log2_max_mv_length_horizontal: u5 = 0,
    log2_max_mv_length_vertical: u5 = 0,
    fixed_frame_rate_flag: u1 = 0,
    low_delay_hrd_flag: u1 = 0,
    motion_vectors_over_pic_boundaries_flag: u1 = 0,
    _: u16 = 0,
};

pub const EncSequenceParameterBufferH264 = extern struct {
    seq_parameter_set_id: u8,
    level_idc: u8,
    intra_period: u32,
    intra_idr_period: u32,
    ip_period: u32,
    bits_per_second: u32,
    max_num_ref_frames: u32,
    picture_width_in_mbs: u16,
    picture_height_in_mbs: u16,
    seq_fields: EncSeqFieldsH264,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    num_ref_frames_in_pic_order_cnt_cycle: u8,
    offset_for_non_ref_pic: i32,
    offset_for_top_to_bottom_field: i32,
    offset_for_ref_frame: [256]i32,
    frame_cropping_flag: u8,
    frame_crop_left_offset: u32,
    frame_crop_right_offset: u32,
    frame_crop_top_offset: u32,
    frame_crop_bottom_offset: u32,
    vui_parameters_present_flag: u8,
    vui_fields: EncVuiFieldsH264,
    aspect_ratio_idc: u8,
    sar_width: u32,
    sar_height: u32,
    num_units_in_tick: u32,
    time_scale: u32,
    va_reserved: [4]u32,
};

pub const EncPicFieldsH264 = packed struct(u32) {
    idr_pic_flag: u1 = 0,
    reference_pic_flag: u2 = 0,
    entropy_coding_mode_flag: u1 = 0,
    weighted_pred_flag: u1 = 0,
    weighted_bipred_idc: u2 = 0,
    constrained_intra_pred_flag: u1 = 0,
    transform_8x8_mode_flag: u1 = 0,
    deblocking_filter_control_present_flag: u1 = 0,
    redundant_pic_cnt_present_flag: u1 = 0,
    pic_order_present_flag: u1 = 0,
    pic_scaling_matrix_present_flag: u1 = 0,
    _: u19 = 0,
};

pub const EncPictureParameterBufferH264 = extern struct {
    CurrPic: va.PictureH264,
    ReferenceFrames: [16]va.PictureH264,
    coded_buf: u32,
    pic_parameter_set_id: u8,
    seq_parameter_set_id: u8,
    last_picture: u8,
    frame_num: u16,
    pic_init_qp: u8,
    num_ref_idx_l0_active_minus1: u8,
    num_ref_idx_l1_active_minus1: u8,
    chroma_qp_index_offset: i8,
    second_chroma_qp_index_offset: i8,
    pic_fields: EncPicFieldsH264,
    va_reserved: [4]u32,
};

pub const EncSliceParameterBufferH264 = extern struct {
    macroblock_address: u32,
    num_macroblocks: u32,
    macroblock_info: u32,
    /// 0 P, 1 B, 2 I (and 5..7 the same)
    slice_type: u8,
    pic_parameter_set_id: u8,
    idr_pic_id: u16,
    pic_order_cnt_lsb: u16,
    delta_pic_order_cnt_bottom: i32,
    delta_pic_order_cnt: [2]i32,
    direct_spatial_mv_pred_flag: u8,
    num_ref_idx_active_override_flag: u8,
    num_ref_idx_l0_active_minus1: u8,
    num_ref_idx_l1_active_minus1: u8,
    RefPicList0: [32]va.PictureH264,
    RefPicList1: [32]va.PictureH264,
    luma_log2_weight_denom: u8,
    chroma_log2_weight_denom: u8,
    luma_weight_l0_flag: u8,
    luma_weight_l0: [32]i16,
    luma_offset_l0: [32]i16,
    chroma_weight_l0_flag: u8,
    chroma_weight_l0: [32][2]i16,
    chroma_offset_l0: [32][2]i16,
    luma_weight_l1_flag: u8,
    luma_weight_l1: [32]i16,
    luma_offset_l1: [32]i16,
    chroma_weight_l1_flag: u8,
    chroma_weight_l1: [32][2]i16,
    chroma_offset_l1: [32][2]i16,
    cabac_init_idc: u8,
    slice_qp_delta: i8,
    disable_deblocking_filter_idc: u8,
    slice_alpha_c0_offset_div2: i8,
    slice_beta_offset_div2: i8,
    va_reserved: [4]u32,
};

// ── HEVC (va_enc_hevc.h) ────────────────────────────────────────────────────

pub const EncSeqFieldsHEVC = packed struct(u32) {
    chroma_format_idc: u2 = 0,
    separate_colour_plane_flag: u1 = 0,
    bit_depth_luma_minus8: u3 = 0,
    bit_depth_chroma_minus8: u3 = 0,
    scaling_list_enabled_flag: u1 = 0,
    strong_intra_smoothing_enabled_flag: u1 = 0,
    amp_enabled_flag: u1 = 0,
    sample_adaptive_offset_enabled_flag: u1 = 0,
    pcm_enabled_flag: u1 = 0,
    pcm_loop_filter_disabled_flag: u1 = 0,
    sps_temporal_mvp_enabled_flag: u1 = 0,
    low_delay_seq: u1 = 0,
    hierachical_flag: u1 = 0,
    _: u14 = 0,
};

pub const EncVuiFieldsHEVC = packed struct(u32) {
    aspect_ratio_info_present_flag: u1 = 0,
    neutral_chroma_indication_flag: u1 = 0,
    field_seq_flag: u1 = 0,
    vui_timing_info_present_flag: u1 = 0,
    bitstream_restriction_flag: u1 = 0,
    tiles_fixed_structure_flag: u1 = 0,
    motion_vectors_over_pic_boundaries_flag: u1 = 0,
    restricted_ref_pic_lists_flag: u1 = 0,
    log2_max_mv_length_horizontal: u5 = 0,
    log2_max_mv_length_vertical: u5 = 0,
    _: u14 = 0,
};

pub const EncSequenceParameterBufferHEVC = extern struct {
    general_profile_idc: u8,
    general_level_idc: u8,
    general_tier_flag: u8,
    intra_period: u32,
    intra_idr_period: u32,
    ip_period: u32,
    bits_per_second: u32,
    pic_width_in_luma_samples: u16,
    pic_height_in_luma_samples: u16,
    seq_fields: EncSeqFieldsHEVC,
    log2_min_luma_coding_block_size_minus3: u8,
    log2_diff_max_min_luma_coding_block_size: u8,
    log2_min_transform_block_size_minus2: u8,
    log2_diff_max_min_transform_block_size: u8,
    max_transform_hierarchy_depth_inter: u8,
    max_transform_hierarchy_depth_intra: u8,
    pcm_sample_bit_depth_luma_minus1: u32,
    pcm_sample_bit_depth_chroma_minus1: u32,
    log2_min_pcm_luma_coding_block_size_minus3: u32,
    log2_max_pcm_luma_coding_block_size_minus3: u32,
    vui_parameters_present_flag: u8,
    vui_fields: EncVuiFieldsHEVC,
    aspect_ratio_idc: u8,
    sar_width: u32,
    sar_height: u32,
    vui_num_units_in_tick: u32,
    vui_time_scale: u32,
    min_spatial_segmentation_idc: u16,
    max_bytes_per_pic_denom: u8,
    max_bits_per_min_cu_denom: u8,
    scc_fields: u32,
    va_reserved: [7]u32,
};

pub const EncPicFieldsHEVC = packed struct(u32) {
    idr_pic_flag: u1 = 0,
    /// 1 I, 2 P, 3 B
    coding_type: u3 = 0,
    reference_pic_flag: u1 = 0,
    dependent_slice_segments_enabled_flag: u1 = 0,
    sign_data_hiding_enabled_flag: u1 = 0,
    constrained_intra_pred_flag: u1 = 0,
    transform_skip_enabled_flag: u1 = 0,
    cu_qp_delta_enabled_flag: u1 = 0,
    weighted_pred_flag: u1 = 0,
    weighted_bipred_flag: u1 = 0,
    transquant_bypass_enabled_flag: u1 = 0,
    tiles_enabled_flag: u1 = 0,
    entropy_coding_sync_enabled_flag: u1 = 0,
    loop_filter_across_tiles_enabled_flag: u1 = 0,
    pps_loop_filter_across_slices_enabled_flag: u1 = 0,
    scaling_list_data_present_flag: u1 = 0,
    screen_content_flag: u1 = 0,
    enable_gpu_weighted_prediction: u1 = 0,
    no_output_of_prior_pics_flag: u1 = 0,
    _: u11 = 0,
};

pub const EncPictureParameterBufferHEVC = extern struct {
    decoded_curr_pic: va.PictureHEVC,
    reference_frames: [15]va.PictureHEVC,
    coded_buf: u32,
    collocated_ref_pic_index: u8,
    last_picture: u8,
    pic_init_qp: u8,
    diff_cu_qp_delta_depth: u8,
    pps_cb_qp_offset: i8,
    pps_cr_qp_offset: i8,
    num_tile_columns_minus1: u8,
    num_tile_rows_minus1: u8,
    column_width_minus1: [19]u8,
    row_height_minus1: [21]u8,
    log2_parallel_merge_level_minus2: u8,
    ctu_max_bitsize_allowed: u8,
    num_ref_idx_l0_default_active_minus1: u8,
    num_ref_idx_l1_default_active_minus1: u8,
    slice_pic_parameter_set_id: u8,
    nal_unit_type: u8,
    pic_fields: EncPicFieldsHEVC,
    hierarchical_level_plus1: u8,
    va_byte_reserved: u8,
    scc_fields: u16,
    va_reserved: [15]u32,
};

pub const EncSliceFieldsHEVC = packed struct(u32) {
    last_slice_of_pic_flag: u1 = 0,
    dependent_slice_segment_flag: u1 = 0,
    colour_plane_id: u2 = 0,
    slice_temporal_mvp_enabled_flag: u1 = 0,
    slice_sao_luma_flag: u1 = 0,
    slice_sao_chroma_flag: u1 = 0,
    num_ref_idx_active_override_flag: u1 = 0,
    mvd_l1_zero_flag: u1 = 0,
    cabac_init_flag: u1 = 0,
    slice_deblocking_filter_disabled_flag: u2 = 0,
    slice_loop_filter_across_slices_enabled_flag: u1 = 0,
    collocated_from_l0_flag: u1 = 0,
    _: u18 = 0,
};

pub const EncSliceParameterBufferHEVC = extern struct {
    slice_segment_address: u32,
    num_ctu_in_slice: u32,
    /// 0 B, 1 P, 2 I
    slice_type: u8,
    slice_pic_parameter_set_id: u8,
    num_ref_idx_l0_active_minus1: u8,
    num_ref_idx_l1_active_minus1: u8,
    ref_pic_list0: [15]va.PictureHEVC,
    ref_pic_list1: [15]va.PictureHEVC,
    luma_log2_weight_denom: u8,
    delta_chroma_log2_weight_denom: i8,
    delta_luma_weight_l0: [15]i8,
    luma_offset_l0: [15]i8,
    delta_chroma_weight_l0: [15][2]i8,
    chroma_offset_l0: [15][2]i8,
    delta_luma_weight_l1: [15]i8,
    luma_offset_l1: [15]i8,
    delta_chroma_weight_l1: [15][2]i8,
    chroma_offset_l1: [15][2]i8,
    max_num_merge_cand: u8,
    slice_qp_delta: i8,
    slice_cb_qp_offset: i8,
    slice_cr_qp_offset: i8,
    slice_beta_offset_div2: i8,
    slice_tc_offset_div2: i8,
    slice_fields: EncSliceFieldsHEVC,
    pred_weight_table_bit_offset: u32,
    pred_weight_table_bit_length: u32,
    va_reserved: [6]u32,
};

// ── Layout checks (gcc on libva 2.22, x86-64) ───────────────────────────────

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(CodedBufferSegment) == 48);
        std.debug.assert(@offsetOf(CodedBufferSegment, "buf") == 16);
        std.debug.assert(@offsetOf(CodedBufferSegment, "next") == 24);
    }
    std.debug.assert(@sizeOf(PackedHeaderParameterBuffer) == 28);
    std.debug.assert(@offsetOf(PackedHeaderParameterBuffer, "has_emulation_bytes") == 8);
    std.debug.assert(@sizeOf(RateControl) == 60);
    std.debug.assert(@offsetOf(RateControl, "rc_flags") == 24);
    std.debug.assert(@offsetOf(RateControl, "max_qp") == 32);
    std.debug.assert(@offsetOf(RateControl, "target_frame_size") == 40);
    std.debug.assert(@sizeOf(FrameRate) == 24);
    std.debug.assert(@sizeOf(Hrd) == 24);
    std.debug.assert(@sizeOf(EncSequenceParameterBufferH264) == 1132);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "intra_period") == 4);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "picture_width_in_mbs") == 24);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "seq_fields") == 28);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "bit_depth_luma_minus8") == 32);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "offset_for_non_ref_pic") == 36);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "frame_cropping_flag") == 1068);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "frame_crop_left_offset") == 1072);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "vui_parameters_present_flag") == 1088);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "vui_fields") == 1092);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "aspect_ratio_idc") == 1096);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "sar_width") == 1100);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferH264, "time_scale") == 1112);
    std.debug.assert(@sizeOf(EncPictureParameterBufferH264) == 648);
    std.debug.assert(@offsetOf(EncPictureParameterBufferH264, "coded_buf") == 612);
    std.debug.assert(@offsetOf(EncPictureParameterBufferH264, "pic_parameter_set_id") == 616);
    std.debug.assert(@offsetOf(EncPictureParameterBufferH264, "frame_num") == 620);
    std.debug.assert(@offsetOf(EncPictureParameterBufferH264, "pic_init_qp") == 622);
    std.debug.assert(@offsetOf(EncPictureParameterBufferH264, "chroma_qp_index_offset") == 625);
    std.debug.assert(@offsetOf(EncPictureParameterBufferH264, "pic_fields") == 628);
    std.debug.assert(@sizeOf(EncSliceParameterBufferH264) == 3140);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "slice_type") == 12);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "idr_pic_id") == 14);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "pic_order_cnt_lsb") == 16);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "delta_pic_order_cnt_bottom") == 20);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "direct_spatial_mv_pred_flag") == 32);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "RefPicList0") == 36);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "RefPicList1") == 1188);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "luma_log2_weight_denom") == 2340);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "luma_weight_l0") == 2344);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "cabac_init_idc") == 3118);
    std.debug.assert(@offsetOf(EncSliceParameterBufferH264, "slice_beta_offset_div2") == 3122);
    std.debug.assert(@sizeOf(EncSequenceParameterBufferHEVC) == 116);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "intra_period") == 4);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "pic_width_in_luma_samples") == 20);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "seq_fields") == 24);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "log2_min_luma_coding_block_size_minus3") == 28);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "pcm_sample_bit_depth_luma_minus1") == 36);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "vui_parameters_present_flag") == 52);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "vui_fields") == 56);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "aspect_ratio_idc") == 60);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "vui_num_units_in_tick") == 72);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "min_spatial_segmentation_idc") == 80);
    std.debug.assert(@offsetOf(EncSequenceParameterBufferHEVC, "scc_fields") == 84);
    std.debug.assert(@sizeOf(EncPictureParameterBufferHEVC) == 576);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "reference_frames") == 28);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "coded_buf") == 448);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "pic_init_qp") == 454);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "column_width_minus1") == 460);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "log2_parallel_merge_level_minus2") == 500);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "nal_unit_type") == 505);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "pic_fields") == 508);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "hierarchical_level_plus1") == 512);
    std.debug.assert(@offsetOf(EncPictureParameterBufferHEVC, "scc_fields") == 514);
    std.debug.assert(@sizeOf(EncSliceParameterBufferHEVC) == 1076);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "slice_type") == 8);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "ref_pic_list0") == 12);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "ref_pic_list1") == 432);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "luma_log2_weight_denom") == 852);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "max_num_merge_cand") == 1034);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "slice_fields") == 1040);
    std.debug.assert(@offsetOf(EncSliceParameterBufferHEVC, "pred_weight_table_bit_offset") == 1044);
}

test "vaapi_enc: bit fields where gcc puts them" {
    // (gcc: the first declared bit field is the least significant)
    const pf = EncPicFieldsH264{ .idr_pic_flag = 1, .reference_pic_flag = 1, .entropy_coding_mode_flag = 1, .transform_8x8_mode_flag = 1 };
    try std.testing.expectEqual(@as(u32, 0x1 | 0x2 | 0x8 | 0x100), @as(u32, @bitCast(pf)));
    const sf = EncSeqFieldsH264{ .chroma_format_idc = 1, .frame_mbs_only_flag = 1, .log2_max_frame_num_minus4 = 3, .pic_order_cnt_type = 2 };
    try std.testing.expectEqual(@as(u32, 1 | 4 | (3 << 6) | (2 << 10)), @as(u32, @bitCast(sf)));
    const hf = EncPicFieldsHEVC{ .idr_pic_flag = 1, .coding_type = 1, .reference_pic_flag = 1 };
    try std.testing.expectEqual(@as(u32, 1 | 2 | 0x10), @as(u32, @bitCast(hf)));
}
