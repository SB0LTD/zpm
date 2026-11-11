//! @zpm/va vaapi — libva's side of a VA-API driver, as libva 2.22 (VA-API
//! 1.22, Alpine's) lays it out: the driver context libva hands
//! `__vaDriverInit_1_0`, the table of entry points the driver fills in, and
//! the structs and numbers of the calls this driver answers (H.264 decode,
//! NV12 surfaces, DRM PRIME export).
//!
//! Transcribed from intel/libva tag 2.22.0: va/va.h, va/va_backend.h,
//! va/va_drmcommon.h. Sizes and offsets are checked at compile time for
//! x86-64 and AArch64 Linux (LP64: pointers and `unsigned long` 8 bytes).
//! The H.264 buffers are in va.h itself (there is no va_dec_h264.h for
//! decode).

const std = @import("std");

// ── Status codes (va.h) ─────────────────────────────────────────────────────

pub const Status = u32;
pub const SUCCESS: Status = 0x00;
pub const ERROR_OPERATION_FAILED: Status = 0x01;
pub const ERROR_ALLOCATION_FAILED: Status = 0x02;
pub const ERROR_INVALID_DISPLAY: Status = 0x03;
pub const ERROR_INVALID_CONFIG: Status = 0x04;
pub const ERROR_INVALID_CONTEXT: Status = 0x05;
pub const ERROR_INVALID_SURFACE: Status = 0x06;
pub const ERROR_INVALID_BUFFER: Status = 0x07;
pub const ERROR_INVALID_IMAGE: Status = 0x08;
pub const ERROR_INVALID_SUBPICTURE: Status = 0x09;
pub const ERROR_ATTR_NOT_SUPPORTED: Status = 0x0a;
pub const ERROR_MAX_NUM_EXCEEDED: Status = 0x0b;
pub const ERROR_UNSUPPORTED_PROFILE: Status = 0x0c;
pub const ERROR_UNSUPPORTED_ENTRYPOINT: Status = 0x0d;
pub const ERROR_UNSUPPORTED_RT_FORMAT: Status = 0x0e;
pub const ERROR_UNSUPPORTED_BUFFERTYPE: Status = 0x0f;
pub const ERROR_SURFACE_BUSY: Status = 0x10;
pub const ERROR_FLAG_NOT_SUPPORTED: Status = 0x11;
pub const ERROR_INVALID_PARAMETER: Status = 0x12;
pub const ERROR_RESOLUTION_NOT_SUPPORTED: Status = 0x13;
pub const ERROR_UNIMPLEMENTED: Status = 0x14;
pub const ERROR_INVALID_IMAGE_FORMAT: Status = 0x16;
pub const ERROR_DECODING_ERROR: Status = 0x17;
pub const ERROR_INVALID_VALUE: Status = 0x19;
pub const ERROR_HW_BUSY: Status = 0x22;
pub const ERROR_UNSUPPORTED_MEMORY_TYPE: Status = 0x24;
pub const ERROR_NOT_ENOUGH_BUFFER: Status = 0x25;
pub const ERROR_TIMEDOUT: Status = 0x26;
pub const ERROR_UNKNOWN: Status = 0xffff_ffff;

pub const INVALID_ID: u32 = 0xffff_ffff;

// ── Profiles, entrypoints, attributes ───────────────────────────────────────

/// VAProfile (a C enum: int).
pub const Profile = i32;
pub const PROFILE_NONE: Profile = -1;
pub const PROFILE_H264_MAIN: Profile = 6;
pub const PROFILE_H264_HIGH: Profile = 7;
pub const PROFILE_H264_CONSTRAINED_BASELINE: Profile = 13;
pub const PROFILE_HEVC_MAIN: Profile = 17;
pub const PROFILE_VP9_PROFILE_0: Profile = 19;
pub const PROFILE_AV1_PROFILE_0: Profile = 32;

/// VAEntrypoint.
pub const Entrypoint = u32;
pub const ENTRYPOINT_VLD: Entrypoint = 1;

/// VAConfigAttribType values this driver answers.
pub const ATTRIB_RT_FORMAT: u32 = 0;
pub const ATTRIB_DEC_SLICE_MODE: u32 = 6;
pub const ATTRIB_MAX_PICTURE_WIDTH: u32 = 18;
pub const ATTRIB_MAX_PICTURE_HEIGHT: u32 = 19;
pub const ATTRIB_NOT_SUPPORTED: u32 = 0x8000_0000;
pub const RT_FORMAT_YUV420: u32 = 0x1;
pub const DEC_SLICE_MODE_NORMAL: u32 = 0x1;

pub const ConfigAttrib = extern struct {
    type: u32,
    value: u32,
};

// ── Surfaces' attributes ────────────────────────────────────────────────────

pub const GENERIC_INTEGER: u32 = 1;
pub const GENERIC_POINTER: u32 = 3;

pub const GenericValue = extern struct {
    type: u32,
    value: extern union {
        i: i32,
        f: f32,
        p: ?*anyopaque,
        func: ?*const fn () callconv(.c) void,
    },
};

/// VASurfaceAttribType.
pub const SURFACE_ATTRIB_NONE: u32 = 0;
pub const SURFACE_ATTRIB_PIXEL_FORMAT: u32 = 1;
pub const SURFACE_ATTRIB_MIN_WIDTH: u32 = 2;
pub const SURFACE_ATTRIB_MAX_WIDTH: u32 = 3;
pub const SURFACE_ATTRIB_MIN_HEIGHT: u32 = 4;
pub const SURFACE_ATTRIB_MAX_HEIGHT: u32 = 5;
pub const SURFACE_ATTRIB_MEMORY_TYPE: u32 = 6;
pub const SURFACE_ATTRIB_EXTERNAL_BUFFER_DESCRIPTOR: u32 = 7;
pub const SURFACE_ATTRIB_USAGE_HINT: u32 = 8;
pub const SURFACE_ATTRIB_DRM_FORMAT_MODIFIERS: u32 = 9;

pub const SURFACE_ATTRIB_GETTABLE: u32 = 1;
pub const SURFACE_ATTRIB_SETTABLE: u32 = 2;

pub const MEM_TYPE_VA: u32 = 0x0000_0001;
pub const MEM_TYPE_DRM_PRIME: u32 = 0x2000_0000;
pub const MEM_TYPE_DRM_PRIME_2: u32 = 0x4000_0000;

pub const SurfaceAttrib = extern struct {
    type: u32,
    flags: u32,
    value: GenericValue,
};

/// VASurfaceStatus.
pub const SURFACE_RENDERING: u32 = 1;
pub const SURFACE_READY: u32 = 4;

/// vaExportSurfaceHandle's flags.
pub const EXPORT_SURFACE_READ_ONLY: u32 = 0x1;
pub const EXPORT_SURFACE_SEPARATE_LAYERS: u32 = 0x4;
pub const EXPORT_SURFACE_COMPOSED_LAYERS: u32 = 0x8;

/// VADRMPRIMESurfaceDescriptor (va_drmcommon.h): what
/// vaExportSurfaceHandle fills for VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2.
pub const DrmPrimeDescriptor = extern struct {
    fourcc: u32,
    width: u32,
    height: u32,
    num_objects: u32,
    objects: [4]extern struct {
        fd: i32,
        size: u32,
        drm_format_modifier: u64,
    },
    num_layers: u32,
    layers: [4]extern struct {
        drm_format: u32,
        num_planes: u32,
        object_index: [4]u32,
        offset: [4]u32,
        pitch: [4]u32,
    },
};

/// libva's struct drm_state (va_drmcommon.h): `driver_context->drm_state`,
/// the render node libva opened for the display.
pub const DrmState = extern struct {
    fd: i32,
    auth_type: i32,
    va_reserved: [8]i32,
};

// ── Images ──────────────────────────────────────────────────────────────────

pub const FOURCC_NV12: u32 = 0x3231_564e; // 'N','V','1','2'
pub const LSB_FIRST: u32 = 1;

pub const ImageFormat = extern struct {
    fourcc: u32,
    byte_order: u32,
    bits_per_pixel: u32,
    depth: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    alpha_mask: u32,
    va_reserved: [4]u32,
};

pub const Image = extern struct {
    image_id: u32,
    format: ImageFormat,
    buf: u32,
    width: u16,
    height: u16,
    data_size: u32,
    num_planes: u32,
    pitches: [3]u32,
    offsets: [3]u32,
    num_palette_entries: i32,
    entry_bytes: i32,
    component_order: [4]i8,
    va_reserved: [4]u32,
};

/// NV12 as vaQueryImageFormats and DeriveImage describe it.
pub const NV12_FORMAT = ImageFormat{
    .fourcc = FOURCC_NV12,
    .byte_order = LSB_FIRST,
    .bits_per_pixel = 12,
    .depth = 0,
    .red_mask = 0,
    .green_mask = 0,
    .blue_mask = 0,
    .alpha_mask = 0,
    .va_reserved = .{ 0, 0, 0, 0 },
};

// ── Buffers ─────────────────────────────────────────────────────────────────

/// VABufferType values this driver takes.
pub const PICTURE_PARAMETER_BUFFER: u32 = 0;
pub const IQ_MATRIX_BUFFER: u32 = 1;
pub const SLICE_PARAMETER_BUFFER: u32 = 4;
pub const SLICE_DATA_BUFFER: u32 = 5;
pub const IMAGE_BUFFER: u32 = 9;

// ── H.264 decode (va.h) ─────────────────────────────────────────────────────

pub const PICTURE_H264_INVALID: u32 = 0x01;
pub const PICTURE_H264_TOP_FIELD: u32 = 0x02;
pub const PICTURE_H264_BOTTOM_FIELD: u32 = 0x04;
pub const PICTURE_H264_SHORT_TERM_REFERENCE: u32 = 0x08;
pub const PICTURE_H264_LONG_TERM_REFERENCE: u32 = 0x10;

pub const PictureH264 = extern struct {
    picture_id: u32,
    frame_idx: u32,
    flags: u32,
    TopFieldOrderCnt: i32,
    BottomFieldOrderCnt: i32,
    va_reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

/// VAPictureParameterBufferH264's seq_fields.
pub const SeqFields = packed struct(u32) {
    chroma_format_idc: u2 = 0,
    residual_colour_transform_flag: u1 = 0,
    gaps_in_frame_num_value_allowed_flag: u1 = 0,
    frame_mbs_only_flag: u1 = 0,
    mb_adaptive_frame_field_flag: u1 = 0,
    direct_8x8_inference_flag: u1 = 0,
    MinLumaBiPredSize8x8: u1 = 0,
    log2_max_frame_num_minus4: u4 = 0,
    pic_order_cnt_type: u2 = 0,
    log2_max_pic_order_cnt_lsb_minus4: u4 = 0,
    delta_pic_order_always_zero_flag: u1 = 0,
    _: u13 = 0,
};

/// VAPictureParameterBufferH264's pic_fields.
pub const PicFields = packed struct(u32) {
    entropy_coding_mode_flag: u1 = 0,
    weighted_pred_flag: u1 = 0,
    weighted_bipred_idc: u2 = 0,
    transform_8x8_mode_flag: u1 = 0,
    field_pic_flag: u1 = 0,
    constrained_intra_pred_flag: u1 = 0,
    pic_order_present_flag: u1 = 0,
    deblocking_filter_control_present_flag: u1 = 0,
    redundant_pic_cnt_present_flag: u1 = 0,
    reference_pic_flag: u1 = 0,
    _: u21 = 0,
};

pub const PictureParameterBufferH264 = extern struct {
    CurrPic: PictureH264,
    ReferenceFrames: [16]PictureH264,
    picture_width_in_mbs_minus1: u16,
    /// The frame's height in macroblocks, less one (FFmpeg: mb_height - 1,
    /// which counts both fields of an interlaced frame).
    picture_height_in_mbs_minus1: u16,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    num_ref_frames: u8,
    seq_fields: SeqFields,
    num_slice_groups_minus1: u8,
    slice_group_map_type: u8,
    slice_group_change_rate_minus1: u16,
    pic_init_qp_minus26: i8,
    pic_init_qs_minus26: i8,
    chroma_qp_index_offset: i8,
    second_chroma_qp_index_offset: i8,
    pic_fields: PicFields,
    frame_num: u16,
    va_reserved: [8]u32,
};

pub const IQMatrixBufferH264 = extern struct {
    /// In raster scan order (va.h).
    ScalingList4x4: [6][16]u8,
    ScalingList8x8: [2][64]u8,
    va_reserved: [4]u32,
};

pub const SliceParameterBufferH264 = extern struct {
    slice_data_size: u32,
    /// Byte offset of the slice's NAL unit header in the slice data buffer
    /// (no start code before it).
    slice_data_offset: u32,
    slice_data_flag: u32,
    slice_data_bit_offset: u16,
    first_mb_in_slice: u16,
    slice_type: u8,
    direct_spatial_mv_pred_flag: u8,
    num_ref_idx_l0_active_minus1: u8,
    num_ref_idx_l1_active_minus1: u8,
    cabac_init_idc: u8,
    slice_qp_delta: i8,
    disable_deblocking_filter_idc: u8,
    slice_alpha_c0_offset_div2: i8,
    slice_beta_offset_div2: i8,
    RefPicList0: [32]PictureH264,
    RefPicList1: [32]PictureH264,
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
    va_reserved: [4]u32,
};

// ── HEVC decode (va.h, va_dec_hevc.h) ───────────────────────────────────────

pub const PICTURE_HEVC_INVALID: u32 = 0x01;
pub const PICTURE_HEVC_FIELD_PIC: u32 = 0x02;
pub const PICTURE_HEVC_BOTTOM_FIELD: u32 = 0x04;
pub const PICTURE_HEVC_LONG_TERM_REFERENCE: u32 = 0x08;
/// The current picture's RPS sets a reference is in (VAAPI's own).
pub const PICTURE_HEVC_RPS_ST_CURR_BEFORE: u32 = 0x10;
pub const PICTURE_HEVC_RPS_ST_CURR_AFTER: u32 = 0x20;
pub const PICTURE_HEVC_RPS_LT_CURR: u32 = 0x40;

pub const PictureHEVC = extern struct {
    picture_id: u32,
    pic_order_cnt: i32,
    flags: u32,
    va_reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

/// VAPictureParameterBufferHEVC's pic_fields.
pub const HevcPicFields = packed struct(u32) {
    chroma_format_idc: u2 = 0,
    separate_colour_plane_flag: u1 = 0,
    pcm_enabled_flag: u1 = 0,
    scaling_list_enabled_flag: u1 = 0,
    transform_skip_enabled_flag: u1 = 0,
    amp_enabled_flag: u1 = 0,
    strong_intra_smoothing_enabled_flag: u1 = 0,
    sign_data_hiding_enabled_flag: u1 = 0,
    constrained_intra_pred_flag: u1 = 0,
    cu_qp_delta_enabled_flag: u1 = 0,
    weighted_pred_flag: u1 = 0,
    weighted_bipred_flag: u1 = 0,
    transquant_bypass_enabled_flag: u1 = 0,
    tiles_enabled_flag: u1 = 0,
    entropy_coding_sync_enabled_flag: u1 = 0,
    pps_loop_filter_across_slices_enabled_flag: u1 = 0,
    loop_filter_across_tiles_enabled_flag: u1 = 0,
    pcm_loop_filter_disabled_flag: u1 = 0,
    NoPicReorderingFlag: u1 = 0,
    NoBiPredFlag: u1 = 0,
    _: u11 = 0,
};

/// VAPictureParameterBufferHEVC's slice_parsing_fields.
pub const HevcSliceParsingFields = packed struct(u32) {
    lists_modification_present_flag: u1 = 0,
    long_term_ref_pics_present_flag: u1 = 0,
    sps_temporal_mvp_enabled_flag: u1 = 0,
    cabac_init_present_flag: u1 = 0,
    output_flag_present_flag: u1 = 0,
    dependent_slice_segments_enabled_flag: u1 = 0,
    pps_slice_chroma_qp_offsets_present_flag: u1 = 0,
    sample_adaptive_offset_enabled_flag: u1 = 0,
    deblocking_filter_override_enabled_flag: u1 = 0,
    pps_disable_deblocking_filter_flag: u1 = 0,
    slice_segment_header_extension_present_flag: u1 = 0,
    RapPicFlag: u1 = 0,
    IdrPicFlag: u1 = 0,
    IntraPicFlag: u1 = 0,
    _: u18 = 0,
};

pub const PictureParameterBufferHEVC = extern struct {
    CurrPic: PictureHEVC,
    ReferenceFrames: [15]PictureHEVC,
    pic_width_in_luma_samples: u16,
    pic_height_in_luma_samples: u16,
    pic_fields: HevcPicFields,
    sps_max_dec_pic_buffering_minus1: u8,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    pcm_sample_bit_depth_luma_minus1: u8,
    pcm_sample_bit_depth_chroma_minus1: u8,
    log2_min_luma_coding_block_size_minus3: u8,
    log2_diff_max_min_luma_coding_block_size: u8,
    log2_min_transform_block_size_minus2: u8,
    log2_diff_max_min_transform_block_size: u8,
    log2_min_pcm_luma_coding_block_size_minus3: u8,
    log2_diff_max_min_pcm_luma_coding_block_size: u8,
    max_transform_hierarchy_depth_intra: u8,
    max_transform_hierarchy_depth_inter: u8,
    init_qp_minus26: i8,
    diff_cu_qp_delta_depth: u8,
    pps_cb_qp_offset: i8,
    pps_cr_qp_offset: i8,
    log2_parallel_merge_level_minus2: u8,
    num_tile_columns_minus1: u8,
    num_tile_rows_minus1: u8,
    column_width_minus1: [19]u16,
    row_height_minus1: [21]u16,
    slice_parsing_fields: HevcSliceParsingFields,
    log2_max_pic_order_cnt_lsb_minus4: u8,
    num_short_term_ref_pic_sets: u8,
    /// (libva's name: num_long_term_ref_pic_sps)
    num_long_term_ref_pic_sps: u8,
    num_ref_idx_l0_default_active_minus1: u8,
    num_ref_idx_l1_default_active_minus1: u8,
    pps_beta_offset_div2: i8,
    pps_tc_offset_div2: i8,
    num_extra_slice_header_bits: u8,
    /// the bits short_term_ref_pic_set() takes in the slice segment header
    /// when short_term_ref_pic_set_sps_flag is 0 (0 when it is 1)
    st_rps_bits: u32,
    va_reserved: [8]u32,
};

pub const SliceParameterBufferHEVC = extern struct {
    slice_data_size: u32,
    /// Byte offset of the slice's NAL unit header in the slice data buffer
    /// (no start code before it).
    slice_data_offset: u32,
    slice_data_flag: u32,
    slice_data_byte_offset: u32,
    slice_segment_address: u32,
    RefPicList: [2][15]u8,
    LongSliceFlags: u32,
    collocated_ref_idx: u8,
    num_ref_idx_l0_active_minus1: u8,
    num_ref_idx_l1_active_minus1: u8,
    slice_qp_delta: i8,
    slice_cb_qp_offset: i8,
    slice_cr_qp_offset: i8,
    slice_beta_offset_div2: i8,
    slice_tc_offset_div2: i8,
    luma_log2_weight_denom: u8,
    delta_chroma_log2_weight_denom: i8,
    delta_luma_weight_l0: [15]i8,
    luma_offset_l0: [15]i8,
    delta_chroma_weight_l0: [15][2]i8,
    ChromaOffsetL0: [15][2]i8,
    delta_luma_weight_l1: [15]i8,
    luma_offset_l1: [15]i8,
    delta_chroma_weight_l1: [15][2]i8,
    ChromaOffsetL1: [15][2]i8,
    five_minus_max_num_merge_cand: u8,
    num_entry_point_offsets: u16,
    entry_offset_to_subset_array: u16,
    slice_data_num_emu_prevn_bytes: u16,
    va_reserved: [2]u32,
};

pub const IQMatrixBufferHEVC = extern struct {
    /// raster order (FFmpeg's VA-API HEVC passes its raster lists)
    ScalingList4x4: [6][16]u8,
    ScalingList8x8: [6][64]u8,
    ScalingList16x16: [6][64]u8,
    ScalingList32x32: [2][64]u8,
    ScalingListDC16x16: [6]u8,
    ScalingListDC32x32: [2]u8,
    va_reserved: [4]u32,
};

comptime {
    // (libva 2.22 on x86-64, measured with gcc on its headers)
    std.debug.assert(@sizeOf(PictureHEVC) == 28);
    std.debug.assert(@offsetOf(PictureParameterBufferHEVC, "pic_width_in_luma_samples") == 448);
    std.debug.assert(@offsetOf(PictureParameterBufferHEVC, "pic_fields") == 452);
    std.debug.assert(@offsetOf(PictureParameterBufferHEVC, "column_width_minus1") == 476);
    std.debug.assert(@offsetOf(PictureParameterBufferHEVC, "slice_parsing_fields") == 556);
    std.debug.assert(@offsetOf(PictureParameterBufferHEVC, "st_rps_bits") == 568);
    std.debug.assert(@sizeOf(PictureParameterBufferHEVC) == 604);
    std.debug.assert(@offsetOf(SliceParameterBufferHEVC, "LongSliceFlags") == 52);
    std.debug.assert(@offsetOf(SliceParameterBufferHEVC, "five_minus_max_num_merge_cand") == 246);
    std.debug.assert(@sizeOf(SliceParameterBufferHEVC) == 264);
    std.debug.assert(@sizeOf(IQMatrixBufferHEVC) == 1016);
}

// ── The driver context and its table (va_backend.h) ─────────────────────────

/// A slot of the table: a C function pointer (each entry point here has
/// its own C signature; libva only checks that the ones it needs are set).
pub const Fn = ?*const anyopaque;

/// struct VADriverVTable, in order. libva allocates it (zeroed) before
/// calling the driver's init; the driver fills it in.
pub const DriverVTable = extern struct {
    vaTerminate: Fn = null,
    vaQueryConfigProfiles: Fn = null,
    vaQueryConfigEntrypoints: Fn = null,
    vaGetConfigAttributes: Fn = null,
    vaCreateConfig: Fn = null,
    vaDestroyConfig: Fn = null,
    vaQueryConfigAttributes: Fn = null,
    vaCreateSurfaces: Fn = null,
    vaDestroySurfaces: Fn = null,
    vaCreateContext: Fn = null,
    vaDestroyContext: Fn = null,
    vaCreateBuffer: Fn = null,
    vaBufferSetNumElements: Fn = null,
    vaMapBuffer: Fn = null,
    vaUnmapBuffer: Fn = null,
    vaDestroyBuffer: Fn = null,
    vaBeginPicture: Fn = null,
    vaRenderPicture: Fn = null,
    vaEndPicture: Fn = null,
    vaSyncSurface: Fn = null,
    vaQuerySurfaceStatus: Fn = null,
    vaQuerySurfaceError: Fn = null,
    vaPutSurface: Fn = null,
    vaQueryImageFormats: Fn = null,
    vaCreateImage: Fn = null,
    vaDeriveImage: Fn = null,
    vaDestroyImage: Fn = null,
    vaSetImagePalette: Fn = null,
    vaGetImage: Fn = null,
    vaPutImage: Fn = null,
    vaQuerySubpictureFormats: Fn = null,
    vaCreateSubpicture: Fn = null,
    vaDestroySubpicture: Fn = null,
    vaSetSubpictureImage: Fn = null,
    vaSetSubpictureChromakey: Fn = null,
    vaSetSubpictureGlobalAlpha: Fn = null,
    vaAssociateSubpicture: Fn = null,
    vaDeassociateSubpicture: Fn = null,
    vaQueryDisplayAttributes: Fn = null,
    vaGetDisplayAttributes: Fn = null,
    vaSetDisplayAttributes: Fn = null,
    vaBufferInfo: Fn = null,
    vaLockSurface: Fn = null,
    vaUnlockSurface: Fn = null,
    vaGetSurfaceAttributes: Fn = null,
    vaCreateSurfaces2: Fn = null,
    vaQuerySurfaceAttributes: Fn = null,
    vaAcquireBufferHandle: Fn = null,
    vaReleaseBufferHandle: Fn = null,
    vaCreateMFContext: Fn = null,
    vaMFAddContext: Fn = null,
    vaMFReleaseContext: Fn = null,
    vaMFSubmit: Fn = null,
    vaCreateBuffer2: Fn = null,
    vaQueryProcessingRate: Fn = null,
    vaExportSurfaceHandle: Fn = null,
    vaSyncSurface2: Fn = null,
    vaSyncBuffer: Fn = null,
    vaCopy: Fn = null,
    vaMapBuffer2: Fn = null,
    reserved: [53]c_ulong = [_]c_ulong{0} ** 53,
};

/// The entries libva 2.22's va_openDriver requires set after init (va.c's
/// CHECK_VTABLE list); without any one, vaInitialize fails.
pub const REQUIRED = [_][]const u8{
    "vaTerminate",              "vaQueryConfigProfiles",    "vaQueryConfigEntrypoints", "vaQueryConfigAttributes",
    "vaCreateConfig",           "vaDestroyConfig",          "vaGetConfigAttributes",    "vaCreateSurfaces",
    "vaDestroySurfaces",        "vaCreateContext",          "vaDestroyContext",         "vaCreateBuffer",
    "vaBufferSetNumElements",   "vaMapBuffer",              "vaUnmapBuffer",            "vaDestroyBuffer",
    "vaBeginPicture",           "vaRenderPicture",          "vaEndPicture",             "vaSyncSurface",
    "vaQuerySurfaceStatus",     "vaQueryImageFormats",      "vaCreateImage",            "vaDeriveImage",
    "vaDestroyImage",           "vaSetImagePalette",        "vaGetImage",               "vaPutImage",
    "vaQuerySubpictureFormats", "vaCreateSubpicture",       "vaDestroySubpicture",      "vaSetSubpictureImage",
    "vaSetSubpictureChromakey", "vaSetSubpictureGlobalAlpha", "vaAssociateSubpicture",  "vaDeassociateSubpicture",
    "vaQueryDisplayAttributes", "vaGetDisplayAttributes",   "vaSetDisplayAttributes",
};

/// struct VADriverContext.
pub const DriverContext = extern struct {
    pDriverData: ?*anyopaque,
    vtable: ?*DriverVTable,
    vtable_glx: ?*anyopaque,
    vtable_egl: ?*anyopaque,
    vtable_tpi: ?*anyopaque,
    native_dpy: ?*anyopaque,
    x11_screen: i32,
    version_major: i32,
    version_minor: i32,
    max_profiles: i32,
    max_entrypoints: i32,
    max_attributes: i32,
    max_image_formats: i32,
    max_subpic_formats: i32,
    max_display_attributes: i32,
    str_vendor: ?[*:0]const u8,
    handle: ?*anyopaque,
    drm_state: ?*DrmState,
    glx: ?*anyopaque,
    display_type: c_ulong,
    vtable_wayland: ?*anyopaque,
    vtable_vpp: ?*anyopaque,
    override_driver_name: ?[*:0]u8,
    pDisplayContext: ?*anyopaque,
    error_callback: ?*const anyopaque,
    info_callback: ?*const anyopaque,
    vtable_prot: ?*anyopaque,
    reserved: [37]c_ulong,
};

// ── DRM formats (drm_fourcc.h) ──────────────────────────────────────────────

pub const DRM_FORMAT_R8: u32 = 0x2020_3852; // 'R','8',' ',' '
pub const DRM_FORMAT_GR88: u32 = 0x3838_5247; // 'G','R','8','8'
pub const DRM_FORMAT_NV12: u32 = 0x3231_564e; // 'N','V','1','2'
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;

// ── Layout checks (LP64) ────────────────────────────────────────────────────

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(GenericValue) == 16);
        std.debug.assert(@sizeOf(SurfaceAttrib) == 24);
        std.debug.assert(@sizeOf(ImageFormat) == 48);
        std.debug.assert(@sizeOf(Image) == 120);
        std.debug.assert(@offsetOf(DrmPrimeDescriptor, "num_layers") == 80);
        std.debug.assert(@offsetOf(DrmPrimeDescriptor, "layers") == 84);
        std.debug.assert(@sizeOf(DrmPrimeDescriptor) == 312);
        std.debug.assert(@sizeOf(PictureH264) == 36);
        std.debug.assert(@offsetOf(PictureParameterBufferH264, "picture_width_in_mbs_minus1") == 612);
        std.debug.assert(@offsetOf(PictureParameterBufferH264, "seq_fields") == 620);
        std.debug.assert(@offsetOf(PictureParameterBufferH264, "pic_init_qp_minus26") == 628);
        std.debug.assert(@offsetOf(PictureParameterBufferH264, "pic_fields") == 632);
        std.debug.assert(@offsetOf(PictureParameterBufferH264, "frame_num") == 636);
        std.debug.assert(@sizeOf(PictureParameterBufferH264) == 672);
        std.debug.assert(@sizeOf(IQMatrixBufferH264) == 240);
        std.debug.assert(@offsetOf(SliceParameterBufferH264, "RefPicList0") == 28);
        std.debug.assert(@sizeOf(SliceParameterBufferH264) == 3128);
        std.debug.assert(@offsetOf(DriverVTable, "vaExportSurfaceHandle") == 55 * 8);
        std.debug.assert(@sizeOf(DriverVTable) == 113 * 8);
        std.debug.assert(@offsetOf(DriverContext, "x11_screen") == 48);
        std.debug.assert(@offsetOf(DriverContext, "str_vendor") == 88);
        std.debug.assert(@offsetOf(DriverContext, "drm_state") == 104);
        std.debug.assert(@offsetOf(DriverContext, "vtable_prot") == 176);
        std.debug.assert(@sizeOf(DriverContext) == 184 + 37 * 8);
    }
}
