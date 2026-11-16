//! @zpm/va vaapi_vp8 — libva 2.22's VP8 decode buffers (va/va_dec_vp8.h,
//! VA-API 1.22): the picture parameters, the slice parameters (one VP8
//! "slice" is the whole frame after its uncompressed data chunk), the
//! coefficient probabilities and the quantizer indices.
//!
//! Transcribed from intel/libva tag 2.22.0. Sizes and offsets were measured
//! with gcc on x86-64 Linux against libva 2.22's headers and are checked at
//! compile time; nothing here holds a pointer or a long, so AArch64 lays it
//! out the same.

const std = @import("std");

/// VAProfileVP8Version0_3: bitstream versions 0 to 3, 8-bit 4:2:0.
pub const PROFILE_VP8_VERSION0_3: i32 = 14;

/// VAProbabilityBufferType (VAProbabilityDataBufferVP8).
pub const PROBABILITY_BUFFER: u32 = 13;

/// VAPictureParameterBufferVP8's pic_fields.
pub const PicFields = packed struct(u32) {
    /// the bitstream's: 0 is a key frame
    key_frame: u1 = 0,
    version: u3 = 0,
    segmentation_enabled: u1 = 0,
    update_mb_segmentation_map: u1 = 0,
    update_segment_feature_data: u1 = 0,
    /// 0 normal, 1 simple
    filter_type: u1 = 0,
    sharpness_level: u3 = 0,
    loop_filter_adj_enable: u1 = 0,
    mode_ref_lf_delta_update: u1 = 0,
    sign_bias_golden: u1 = 0,
    sign_bias_alternate: u1 = 0,
    mb_no_coeff_skip: u1 = 0,
    loop_filter_disable: u1 = 0,
    reserved: u15 = 0,
};

/// VABoolCoderContextVPX: the first partition's bool decoder where the
/// client's header parse left it.
pub const BoolCoderContextVPX = extern struct {
    range: u8,
    value: u8,
    count: u8,
};

/// VAPictureParameterBufferVP8.
pub const PictureParameterBufferVP8 = extern struct {
    frame_width: u32,
    frame_height: u32,
    /// the reference surfaces (VA_INVALID_SURFACE: none)
    last_ref_frame: u32,
    golden_ref_frame: u32,
    alt_ref_frame: u32,
    out_of_loop_frame: u32,
    pic_fields: PicFields,
    mb_segment_tree_probs: [3]u8,
    /// per segment, after the segment's adjustment
    loop_filter_level: [4]u8,
    loop_filter_deltas_ref_frame: [4]i8,
    loop_filter_deltas_mode: [4]i8,
    prob_skip_false: u8,
    prob_intra: u8,
    prob_last: u8,
    prob_gf: u8,
    y_mode_probs: [4]u8,
    uv_mode_probs: [3]u8,
    mv_probs: [2][19]u8,
    bool_coder_ctx: BoolCoderContextVPX,
    va_reserved: [4]u32,
};

/// VASliceParameterBufferVP8.
pub const SliceParameterBufferVP8 = extern struct {
    slice_data_size: u32,
    /// where the first partition starts in the slice data buffer
    slice_data_offset: u32,
    slice_data_flag: u32,
    /// the first partition's bits the client's header parse took
    macroblock_offset: u32,
    /// the first partition and the DCT partitions (2, 3, 5 or 9)
    num_of_partitions: u8,
    /// [0]: the first partition's bytes after macroblock_offset (rounded
    /// up); then each DCT partition's
    partition_size: [9]u32,
    va_reserved: [4]u32,
};

/// VAProbabilityDataBufferVP8: the frame's coefficient probabilities, after
/// its header's updates (block type, band, context, node).
pub const ProbabilityDataBufferVP8 = extern struct {
    dct_coeff_probs: [4][8][3][11]u8,
    va_reserved: [4]u32,
};

/// VAIQMatrixBufferVP8: each segment's quantizer indices.
pub const IQMatrixBufferVP8 = extern struct {
    quantization_index: [4][6]u16,
    va_reserved: [4]u32,
};

comptime {
    std.debug.assert(@sizeOf(BoolCoderContextVPX) == 3);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "last_ref_frame") == 8);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "out_of_loop_frame") == 20);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "pic_fields") == 24);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "mb_segment_tree_probs") == 28);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "loop_filter_level") == 31);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "loop_filter_deltas_ref_frame") == 35);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "loop_filter_deltas_mode") == 39);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "prob_skip_false") == 43);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "prob_gf") == 46);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "y_mode_probs") == 47);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "uv_mode_probs") == 51);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "mv_probs") == 54);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "bool_coder_ctx") == 92);
    std.debug.assert(@offsetOf(PictureParameterBufferVP8, "va_reserved") == 96);
    std.debug.assert(@sizeOf(PictureParameterBufferVP8) == 112);
    std.debug.assert(@offsetOf(SliceParameterBufferVP8, "macroblock_offset") == 12);
    std.debug.assert(@offsetOf(SliceParameterBufferVP8, "num_of_partitions") == 16);
    std.debug.assert(@offsetOf(SliceParameterBufferVP8, "partition_size") == 20);
    std.debug.assert(@offsetOf(SliceParameterBufferVP8, "va_reserved") == 56);
    std.debug.assert(@sizeOf(SliceParameterBufferVP8) == 72);
    std.debug.assert(@offsetOf(ProbabilityDataBufferVP8, "va_reserved") == 1056);
    std.debug.assert(@sizeOf(ProbabilityDataBufferVP8) == 1072);
    std.debug.assert(@offsetOf(IQMatrixBufferVP8, "va_reserved") == 48);
    std.debug.assert(@sizeOf(IQMatrixBufferVP8) == 64);
}

test "vaapi_vp8: pic_fields bits as libva's compiler places them" {
    // (gcc: loop_filter_disable alone is 0x10000, sharpness 7 is 0x700,
    // version 3 is 0x6)
    try std.testing.expectEqual(@as(u32, 0x1_0000), @as(u32, @bitCast(PicFields{ .loop_filter_disable = 1 })));
    try std.testing.expectEqual(@as(u32, 0x700), @as(u32, @bitCast(PicFields{ .sharpness_level = 7 })));
    try std.testing.expectEqual(@as(u32, 0x6), @as(u32, @bitCast(PicFields{ .version = 3 })));
    try std.testing.expectEqual(@as(u32, 0x8000), @as(u32, @bitCast(PicFields{ .mb_no_coeff_skip = 1 })));
}
