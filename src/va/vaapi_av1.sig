//! @zpm/va vaapi_av1 — libva 2.22's AV1 decode buffers (va/va_dec_av1.h):
//! VADecPictureParameterBufferAV1, VASliceParameterBufferAV1 and the
//! structs inside them, as av1.sig reads them.
//!
//! Transcribed from intel/libva tag 2.22.0 (MIT). Each C union of a bit
//! field struct and its `value` is a packed struct of the same width.
//! Sizes and offsets were measured with gcc on x86-64 Linux against the
//! real headers and are checked at compile time for LP64 (the anchor
//! frame list is a pointer).

const std = @import("std");

/// VAProfileAV1Profile0 (va.h).
pub const PROFILE_AV1_PROFILE0: i32 = 32;

pub const SeqInfoFields = packed struct(u32) {
    still_picture: u1 = 0,
    use_128x128_superblock: u1 = 0,
    enable_filter_intra: u1 = 0,
    enable_intra_edge_filter: u1 = 0,
    enable_interintra_compound: u1 = 0,
    enable_masked_compound: u1 = 0,
    enable_dual_filter: u1 = 0,
    enable_order_hint: u1 = 0,
    enable_jnt_comp: u1 = 0,
    enable_cdef: u1 = 0,
    mono_chrome: u1 = 0,
    color_range: u1 = 0,
    subsampling_x: u1 = 0,
    subsampling_y: u1 = 0,
    chroma_sample_position: u1 = 0,
    film_grain_params_present: u1 = 0,
    reserved: u16 = 0,
};

pub const SegmentInfoFields = packed struct(u32) {
    enabled: u1 = 0,
    update_map: u1 = 0,
    temporal_update: u1 = 0,
    update_data: u1 = 0,
    reserved: u28 = 0,
};

/// VASegmentationStructAV1. feature_mask[i] bit j: feature j of segment i
/// (SEG_LVL_ALT_Q 0 .. SEG_LVL_GLOBALMV 7).
pub const Segmentation = extern struct {
    segment_info_fields: SegmentInfoFields = .{},
    feature_data: [8][8]i16 = [_][8]i16{[_]i16{0} ** 8} ** 8,
    feature_mask: [8]u8 = [_]u8{0} ** 8,
    va_reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const FilmGrainInfoFields = packed struct(u32) {
    apply_grain: u1 = 0,
    chroma_scaling_from_luma: u1 = 0,
    grain_scaling_minus_8: u2 = 0,
    ar_coeff_lag: u2 = 0,
    ar_coeff_shift_minus_6: u2 = 0,
    grain_scale_shift: u2 = 0,
    overlap_flag: u1 = 0,
    clip_to_restricted_range: u1 = 0,
    reserved: u20 = 0,
};

/// VAFilmGrainStructAV1.
pub const FilmGrain = extern struct {
    film_grain_info_fields: FilmGrainInfoFields = .{},
    grain_seed: u16 = 0,
    num_y_points: u8 = 0,
    point_y_value: [14]u8 = [_]u8{0} ** 14,
    point_y_scaling: [14]u8 = [_]u8{0} ** 14,
    num_cb_points: u8 = 0,
    point_cb_value: [10]u8 = [_]u8{0} ** 10,
    point_cb_scaling: [10]u8 = [_]u8{0} ** 10,
    num_cr_points: u8 = 0,
    point_cr_value: [10]u8 = [_]u8{0} ** 10,
    point_cr_scaling: [10]u8 = [_]u8{0} ** 10,
    ar_coeffs_y: [24]i8 = [_]i8{0} ** 24,
    ar_coeffs_cb: [25]i8 = [_]i8{0} ** 25,
    ar_coeffs_cr: [25]i8 = [_]i8{0} ** 25,
    cb_mult: u8 = 0,
    cb_luma_mult: u8 = 0,
    cb_offset: u16 = 0,
    cr_mult: u8 = 0,
    cr_luma_mult: u8 = 0,
    cr_offset: u16 = 0,
    va_reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

/// VAAV1TransformationType.
pub const WM_IDENTITY: u32 = 0;
pub const WM_TRANSLATION: u32 = 1;
pub const WM_ROTZOOM: u32 = 2;
pub const WM_AFFINE: u32 = 3;

/// VAWarpedMotionParamsAV1: one reference's global motion (gm_params).
pub const WarpedMotion = extern struct {
    wmtype: u32 = WM_IDENTITY,
    wmmat: [8]i32 = .{ 0, 0, 1 << 16, 0, 0, 1 << 16, 0, 0 },
    invalid: u8 = 0,
    va_reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const PicInfoFields = packed struct(u32) {
    /// 0 KEY_FRAME, 1 INTER_FRAME, 2 INTRA_ONLY_FRAME, 3 SWITCH_FRAME
    frame_type: u2 = 0,
    show_frame: u1 = 0,
    showable_frame: u1 = 0,
    error_resilient_mode: u1 = 0,
    disable_cdf_update: u1 = 0,
    allow_screen_content_tools: u1 = 0,
    force_integer_mv: u1 = 0,
    allow_intrabc: u1 = 0,
    use_superres: u1 = 0,
    allow_high_precision_mv: u1 = 0,
    is_motion_mode_switchable: u1 = 0,
    use_ref_frame_mvs: u1 = 0,
    disable_frame_end_update_cdf: u1 = 0,
    uniform_tile_spacing_flag: u1 = 0,
    allow_warped_motion: u1 = 0,
    large_scale_tile: u1 = 0,
    reserved: u15 = 0,
};

pub const LoopFilterInfoFields = packed struct(u8) {
    sharpness_level: u3 = 0,
    mode_ref_delta_enabled: u1 = 0,
    mode_ref_delta_update: u1 = 0,
    reserved: u3 = 0,
};

pub const QMatrixFields = packed struct(u16) {
    using_qmatrix: u1 = 0,
    qm_y: u4 = 0,
    qm_u: u4 = 0,
    qm_v: u4 = 0,
    reserved: u3 = 0,
};

pub const ModeControlFields = packed struct(u32) {
    delta_q_present_flag: u1 = 0,
    log2_delta_q_res: u2 = 0,
    delta_lf_present_flag: u1 = 0,
    log2_delta_lf_res: u2 = 0,
    delta_lf_multi: u1 = 0,
    /// 0 ONLY_4X4, 1 TX_MODE_LARGEST, 2 TX_MODE_SELECT
    tx_mode: u2 = 0,
    reference_select: u1 = 0,
    reduced_tx_set_used: u1 = 0,
    skip_mode_present: u1 = 0,
    reserved: u20 = 0,
};

pub const LoopRestorationFields = packed struct(u16) {
    yframe_restoration_type: u2 = 0,
    cbframe_restoration_type: u2 = 0,
    crframe_restoration_type: u2 = 0,
    /// the frame header's lr_unit_shift with the 128x128 superblock's
    /// increment in (FFmpeg's): the luma unit is 64 << lr_unit_shift
    lr_unit_shift: u2 = 0,
    lr_uv_shift: u1 = 0,
    reserved: u7 = 0,
};

/// VADecPictureParameterBufferAV1.
pub const PictureParameterBufferAV1 = extern struct {
    profile: u8 = 0,
    order_hint_bits_minus_1: u8 = 0,
    /// 0: 8-bit, 1: 10-bit, 2: 12-bit
    bit_depth_idx: u8 = 0,
    matrix_coefficients: u8 = 0,
    seq_info_fields: SeqInfoFields = .{},
    /// the decode target (the grain-free picture)
    current_frame: u32 = 0,
    /// with apply_grain: where the grained picture goes
    current_display_picture: u32 = 0,
    anchor_frames_num: u8 = 0,
    anchor_frames_list: ?[*]u32 = null,
    /// the upscaled size (with superres)
    frame_width_minus1: u16 = 0,
    frame_height_minus1: u16 = 0,
    output_frame_width_in_tiles_minus_1: u16 = 0,
    output_frame_height_in_tiles_minus_1: u16 = 0,
    /// the eight reference slots' surfaces before this frame
    ref_frame_map: [8]u32 = [_]u32{0xffff_ffff} ** 8,
    /// LAST..ALTREF: indices into ref_frame_map
    ref_frame_idx: [7]u8 = [_]u8{0} ** 7,
    /// into ref_frame_idx; 7: none
    primary_ref_frame: u8 = 7,
    order_hint: u8 = 0,
    seg_info: Segmentation = .{},
    film_grain_info: FilmGrain = .{},
    tile_cols: u8 = 1,
    tile_rows: u8 = 1,
    /// (ignored with uniform_tile_spacing_flag; the last tile's is the
    /// rest of the frame)
    width_in_sbs_minus_1: [63]u16 = [_]u16{0} ** 63,
    height_in_sbs_minus_1: [63]u16 = [_]u16{0} ** 63,
    tile_count_minus_1: u16 = 0,
    context_update_tile_id: u16 = 0,
    pic_info_fields: PicInfoFields = .{},
    /// 8 without superres, 9..16 with
    superres_scale_denominator: u8 = 8,
    /// 0 EIGHTTAP .. 3 BILINEAR, 4 SWITCHABLE
    interp_filter: u8 = 0,
    filter_level: [2]u8 = .{ 0, 0 },
    filter_level_u: u8 = 0,
    filter_level_v: u8 = 0,
    loop_filter_info_fields: LoopFilterInfoFields = .{},
    ref_deltas: [8]i8 = [_]i8{0} ** 8,
    mode_deltas: [2]i8 = .{ 0, 0 },
    base_qindex: u8 = 0,
    y_dc_delta_q: i8 = 0,
    u_dc_delta_q: i8 = 0,
    u_ac_delta_q: i8 = 0,
    v_dc_delta_q: i8 = 0,
    v_ac_delta_q: i8 = 0,
    qmatrix_fields: QMatrixFields = .{},
    mode_control_fields: ModeControlFields = .{},
    cdef_damping_minus_3: u8 = 0,
    cdef_bits: u8 = 0,
    /// (primary << 2) | secondary (the secondary's coded 0..3)
    cdef_y_strengths: [8]u8 = [_]u8{0} ** 8,
    cdef_uv_strengths: [8]u8 = [_]u8{0} ** 8,
    loop_restoration_fields: LoopRestorationFields = .{},
    /// LAST..ALTREF
    wm: [7]WarpedMotion = [_]WarpedMotion{.{}} ** 7,
    va_reserved: [8]u32 = [_]u32{0} ** 8,
};

/// VASliceParameterBufferAV1: one tile.
pub const SliceParameterBufferAV1 = extern struct {
    /// the tile's bytes, from slice_data_offset in the slice data buffer
    slice_data_size: u32 = 0,
    slice_data_offset: u32 = 0,
    slice_data_flag: u32 = 0,
    tile_row: u16 = 0,
    tile_column: u16 = 0,
    tg_start: u16 = 0,
    tg_end: u16 = 0,
    anchor_frame_idx: u8 = 0,
    tile_idx_in_tile_list: u16 = 0,
    va_reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

// ── Layout checks (LP64; measured with gcc against libva 2.22's headers) ──

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Segmentation) == 156);
        std.debug.assert(@offsetOf(Segmentation, "feature_mask") == 132);
        std.debug.assert(@sizeOf(FilmGrain) == 176);
        std.debug.assert(@offsetOf(FilmGrain, "ar_coeffs_y") == 77);
        std.debug.assert(@offsetOf(FilmGrain, "cb_mult") == 151);
        std.debug.assert(@offsetOf(FilmGrain, "cb_offset") == 154);
        std.debug.assert(@offsetOf(FilmGrain, "cr_offset") == 158);
        std.debug.assert(@offsetOf(FilmGrain, "va_reserved") == 160);
        std.debug.assert(@sizeOf(WarpedMotion) == 56);
        std.debug.assert(@offsetOf(WarpedMotion, "invalid") == 36);
        const P = PictureParameterBufferAV1;
        std.debug.assert(@offsetOf(P, "seq_info_fields") == 4);
        std.debug.assert(@offsetOf(P, "current_frame") == 8);
        std.debug.assert(@offsetOf(P, "anchor_frames_num") == 16);
        std.debug.assert(@offsetOf(P, "anchor_frames_list") == 24);
        std.debug.assert(@offsetOf(P, "frame_width_minus1") == 32);
        std.debug.assert(@offsetOf(P, "ref_frame_map") == 40);
        std.debug.assert(@offsetOf(P, "ref_frame_idx") == 72);
        std.debug.assert(@offsetOf(P, "primary_ref_frame") == 79);
        std.debug.assert(@offsetOf(P, "order_hint") == 80);
        std.debug.assert(@offsetOf(P, "seg_info") == 84);
        std.debug.assert(@offsetOf(P, "film_grain_info") == 240);
        std.debug.assert(@offsetOf(P, "tile_cols") == 416);
        std.debug.assert(@offsetOf(P, "width_in_sbs_minus_1") == 418);
        std.debug.assert(@offsetOf(P, "height_in_sbs_minus_1") == 544);
        std.debug.assert(@offsetOf(P, "tile_count_minus_1") == 670);
        std.debug.assert(@offsetOf(P, "context_update_tile_id") == 672);
        std.debug.assert(@offsetOf(P, "pic_info_fields") == 676);
        std.debug.assert(@offsetOf(P, "superres_scale_denominator") == 680);
        std.debug.assert(@offsetOf(P, "filter_level") == 682);
        std.debug.assert(@offsetOf(P, "loop_filter_info_fields") == 686);
        std.debug.assert(@offsetOf(P, "ref_deltas") == 687);
        std.debug.assert(@offsetOf(P, "mode_deltas") == 695);
        std.debug.assert(@offsetOf(P, "base_qindex") == 697);
        std.debug.assert(@offsetOf(P, "v_ac_delta_q") == 702);
        std.debug.assert(@offsetOf(P, "qmatrix_fields") == 704);
        std.debug.assert(@offsetOf(P, "mode_control_fields") == 708);
        std.debug.assert(@offsetOf(P, "cdef_damping_minus_3") == 712);
        std.debug.assert(@offsetOf(P, "cdef_y_strengths") == 714);
        std.debug.assert(@offsetOf(P, "cdef_uv_strengths") == 722);
        std.debug.assert(@offsetOf(P, "loop_restoration_fields") == 730);
        std.debug.assert(@offsetOf(P, "wm") == 732);
        std.debug.assert(@offsetOf(P, "va_reserved") == 1124);
        std.debug.assert(@sizeOf(P) == 1160);
        const S = SliceParameterBufferAV1;
        std.debug.assert(@offsetOf(S, "tile_row") == 12);
        std.debug.assert(@offsetOf(S, "anchor_frame_idx") == 20);
        std.debug.assert(@offsetOf(S, "tile_idx_in_tile_list") == 22);
        std.debug.assert(@sizeOf(S) == 40);
    }
}

test "vaapi_av1: bit fields where gcc puts them" {
    var p = PictureParameterBufferAV1{};
    p.seq_info_fields.film_grain_params_present = 1;
    p.pic_info_fields.large_scale_tile = 1;
    p.mode_control_fields.skip_mode_present = 1;
    p.loop_restoration_fields.lr_uv_shift = 1;
    p.qmatrix_fields.qm_v = 15;
    p.loop_filter_info_fields.mode_ref_delta_update = 1;
    p.film_grain_info.film_grain_info_fields.clip_to_restricted_range = 1;
    p.seg_info.segment_info_fields.update_data = 1;
    const b = std.mem.asBytes(&p);
    const word = struct {
        fn at(bytes: []const u8, off: usize) u32 {
            return std.mem.readInt(u32, bytes[off..][0..4], .little);
        }
    }.at;
    // (gcc: the bit each set field lands on)
    try std.testing.expectEqual(@as(u32, 0x8000), word(b, 4));
    try std.testing.expectEqual(@as(u32, 0x1_0000), word(b, 676));
    try std.testing.expectEqual(@as(u32, 0x800), word(b, 708));
    try std.testing.expectEqual(@as(u32, 0x0100_0000), word(b, 728) & 0xffff_0000);
    try std.testing.expectEqual(@as(u32, 0x1e00), word(b, 704) & 0xffff);
    try std.testing.expectEqual(@as(u32, 0x0010_0000), word(b, 684) & 0x00ff_0000);
    try std.testing.expectEqual(@as(u32, 0x800), word(b, 240));
    try std.testing.expectEqual(@as(u32, 8), word(b, 84));
}
