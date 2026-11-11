//! @zpm/va vaapi_vp9 — libva 2.22's VP9 decode buffers (va/va_dec_vp9.h,
//! VA-API 1.22): the picture parameters, the slice parameters (one VP9
//! "slice" is the whole frame) and their per-segment values.
//!
//! Transcribed from intel/libva tag 2.22.0. Sizes and offsets were measured
//! with gcc on x86-64 Linux against libva 2.22's headers and are checked at
//! compile time; nothing here holds a pointer or a long, so AArch64 lays it
//! out the same.

const std = @import("std");

/// VAProfileVP9Profile0: 8-bit 4:2:0 (the only VP9 profile this driver
/// decodes).
pub const PROFILE_VP9_PROFILE0: i32 = 19;
pub const PROFILE_VP9_PROFILE1: i32 = 20;
pub const PROFILE_VP9_PROFILE2: i32 = 21;
pub const PROFILE_VP9_PROFILE3: i32 = 22;

/// VADecPictureParameterBufferVP9's pic_fields.
pub const PicFields = packed struct(u32) {
    subsampling_x: u1 = 0,
    subsampling_y: u1 = 0,
    /// 0 key frame, 1 inter frame
    frame_type: u1 = 0,
    show_frame: u1 = 0,
    error_resilient_mode: u1 = 0,
    intra_only: u1 = 0,
    allow_high_precision_mv: u1 = 0,
    /// FFmpeg's numbering: 0 smooth, 1 regular, 2 sharp, 3 bilinear,
    /// 4 switchable
    mcomp_filter_type: u3 = 0,
    frame_parallel_decoding_mode: u1 = 0,
    reset_frame_context: u2 = 0,
    refresh_frame_context: u1 = 0,
    frame_context_idx: u2 = 0,
    segmentation_enabled: u1 = 0,
    segmentation_temporal_update: u1 = 0,
    segmentation_update_map: u1 = 0,
    /// indexes into reference_frames
    last_ref_frame: u3 = 0,
    last_ref_frame_sign_bias: u1 = 0,
    golden_ref_frame: u3 = 0,
    golden_ref_frame_sign_bias: u1 = 0,
    alt_ref_frame: u3 = 0,
    alt_ref_frame_sign_bias: u1 = 0,
    lossless_flag: u1 = 0,
};

/// VADecPictureParameterBufferVP9.
pub const PictureParameterBufferVP9 = extern struct {
    frame_width: u16,
    frame_height: u16,
    /// the eight reference slots' surfaces (VA_INVALID_SURFACE: none)
    reference_frames: [8]u32,
    pic_fields: PicFields,
    filter_level: u8,
    sharpness_level: u8,
    log2_tile_rows: u8,
    log2_tile_columns: u8,
    /// the uncompressed header's bytes
    frame_header_length_in_bytes: u8,
    /// the compressed header's bytes
    first_partition_size: u16,
    mb_segment_tree_probs: [7]u8,
    segment_pred_probs: [3]u8,
    profile: u8,
    bit_depth: u8,
    va_reserved: [8]u32,
};

/// VASegmentParameterVP9: one segment's values, derived (VA's, not the
/// bitstream's: this driver reads the bitstream's own).
pub const SegmentParameterVP9 = extern struct {
    segment_flags: packed struct(u16) {
        segment_reference_enabled: u1 = 0,
        segment_reference: u2 = 0,
        segment_reference_skipped: u1 = 0,
        reserved: u12 = 0,
    },
    filter_level: [4][2]u8,
    luma_ac_quant_scale: i16,
    luma_dc_quant_scale: i16,
    chroma_ac_quant_scale: i16,
    chroma_dc_quant_scale: i16,
    va_reserved: [4]u32,
};

/// VASliceParameterBufferVP9: the frame's place in its slice data buffer.
pub const SliceParameterBufferVP9 = extern struct {
    slice_data_size: u32,
    slice_data_offset: u32,
    slice_data_flag: u32,
    seg_param: [8]SegmentParameterVP9,
    va_reserved: [4]u32,
};

comptime {
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "reference_frames") == 4);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "pic_fields") == 36);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "filter_level") == 40);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "log2_tile_columns") == 43);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "frame_header_length_in_bytes") == 44);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "first_partition_size") == 46);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "mb_segment_tree_probs") == 48);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "segment_pred_probs") == 55);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "profile") == 58);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "bit_depth") == 59);
    std.debug.assert(@offsetOf(PictureParameterBufferVP9, "va_reserved") == 60);
    std.debug.assert(@sizeOf(PictureParameterBufferVP9) == 92);
    std.debug.assert(@offsetOf(SegmentParameterVP9, "filter_level") == 2);
    std.debug.assert(@offsetOf(SegmentParameterVP9, "luma_ac_quant_scale") == 10);
    std.debug.assert(@offsetOf(SegmentParameterVP9, "chroma_dc_quant_scale") == 16);
    std.debug.assert(@offsetOf(SegmentParameterVP9, "va_reserved") == 20);
    std.debug.assert(@sizeOf(SegmentParameterVP9) == 36);
    std.debug.assert(@offsetOf(SliceParameterBufferVP9, "seg_param") == 12);
    std.debug.assert(@offsetOf(SliceParameterBufferVP9, "va_reserved") == 300);
    std.debug.assert(@sizeOf(SliceParameterBufferVP9) == 316);
}

test "vaapi_vp9: pic_fields bits as libva's compiler places them" {
    // (gcc: lossless_flag alone is 0x80000000, alt_ref_frame 7 is 0x38000000)
    try std.testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(PicFields{ .lossless_flag = 1 })));
    try std.testing.expectEqual(@as(u32, 0x3800_0000), @as(u32, @bitCast(PicFields{ .alt_ref_frame = 7 })));
    try std.testing.expectEqual(@as(u32, 0x380), @as(u32, @bitCast(PicFields{ .mcomp_filter_type = 7 })));
}
