//! @zpm/va hevc stream test — hevc.parseHeader on a real stream: x265's
//! 30 frames of 128x96 (testdata/hevc_128x96.hevc: open GOPs every 15
//! frames, 3 B-frames, 4 references, 2 slices a picture), each slice's
//! skipped bits checked against ffmpeg's trace_headers of the same file
//! (the table: generated from that trace; VA's st_rps_bits is the length
//! trace_headers gives the slice's own short_term_ref_pic_set()).

const std = @import("std");
const va = @import("vaapi.sig");
const hevc = @import("hevc.sig");

const STREAM = @embedFile("testdata/hevc_128x96.hevc");

pub const SPS = .{ .log2_max_poc_lsb_minus4 = 4, .num_st_rps = 0, .long_term = 0, .num_lt_sps = 0, .width = 128, .height = 96, .log2_min_cb_minus3 = 0, .log2_diff_cb = 3, .separate_colour_plane = 0 };
pub const PPS = .{ .output_flag_present = 0, .extra_bits = 0, .dependent_slices = 0 };
pub const Slice = struct { off: u32, len: u32, nal_type: u8, first: u1, st_rps_bits: u32, skip: u32 };
pub const SLICES = [_]Slice{
    .{ .off = 2380, .len = 1677, .nal_type = 20, .first = 1, .st_rps_bits = 0, .skip = 0 },
    .{ .off = 4060, .len = 5, .nal_type = 20, .first = 0, .st_rps_bits = 0, .skip = 0 },
    .{ .off = 4069, .len = 597, .nal_type = 1, .first = 1, .st_rps_bits = 8, .skip = 17 },
    .{ .off = 4669, .len = 9, .nal_type = 1, .first = 0, .st_rps_bits = 8, .skip = 17 },
    .{ .off = 4682, .len = 201, .nal_type = 1, .first = 1, .st_rps_bits = 12, .skip = 21 },
    .{ .off = 4886, .len = 8, .nal_type = 1, .first = 0, .st_rps_bits = 12, .skip = 21 },
    .{ .off = 4898, .len = 147, .nal_type = 0, .first = 1, .st_rps_bits = 12, .skip = 21 },
    .{ .off = 5048, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 12, .skip = 21 },
    .{ .off = 5061, .len = 835, .nal_type = 1, .first = 1, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 5899, .len = 11, .nal_type = 1, .first = 0, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 5914, .len = 158, .nal_type = 1, .first = 1, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 6075, .len = 10, .nal_type = 1, .first = 0, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 6089, .len = 124, .nal_type = 0, .first = 1, .st_rps_bits = 16, .skip = 25 },
    .{ .off = 6216, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 16, .skip = 25 },
    .{ .off = 6229, .len = 67, .nal_type = 0, .first = 1, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 6299, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 6312, .len = 699, .nal_type = 1, .first = 1, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 7014, .len = 12, .nal_type = 1, .first = 0, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 7030, .len = 339, .nal_type = 1, .first = 1, .st_rps_bits = 24, .skip = 33 },
    .{ .off = 7372, .len = 10, .nal_type = 1, .first = 0, .st_rps_bits = 24, .skip = 33 },
    .{ .off = 7386, .len = 84, .nal_type = 0, .first = 1, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 7473, .len = 10, .nal_type = 0, .first = 0, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 7487, .len = 122, .nal_type = 0, .first = 1, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 7612, .len = 10, .nal_type = 0, .first = 0, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 10002, .len = 2092, .nal_type = 21, .first = 1, .st_rps_bits = 24, .skip = 33 },
    .{ .off = 12097, .len = 9, .nal_type = 21, .first = 0, .st_rps_bits = 24, .skip = 33 },
    .{ .off = 12110, .len = 395, .nal_type = 9, .first = 1, .st_rps_bits = 26, .skip = 35 },
    .{ .off = 12508, .len = 10, .nal_type = 9, .first = 0, .st_rps_bits = 26, .skip = 35 },
    .{ .off = 12522, .len = 107, .nal_type = 8, .first = 1, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 12632, .len = 10, .nal_type = 8, .first = 0, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 12646, .len = 124, .nal_type = 8, .first = 1, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 12773, .len = 10, .nal_type = 8, .first = 0, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 12787, .len = 1121, .nal_type = 1, .first = 1, .st_rps_bits = 10, .skip = 19 },
    .{ .off = 13911, .len = 9, .nal_type = 1, .first = 0, .st_rps_bits = 10, .skip = 19 },
    .{ .off = 13924, .len = 377, .nal_type = 1, .first = 1, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 14304, .len = 8, .nal_type = 1, .first = 0, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 14316, .len = 76, .nal_type = 0, .first = 1, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 14395, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 14408, .len = 61, .nal_type = 0, .first = 1, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 14472, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 14485, .len = 683, .nal_type = 1, .first = 1, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 15171, .len = 11, .nal_type = 1, .first = 0, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 15186, .len = 172, .nal_type = 1, .first = 1, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 15361, .len = 10, .nal_type = 1, .first = 0, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 15375, .len = 107, .nal_type = 0, .first = 1, .st_rps_bits = 16, .skip = 25 },
    .{ .off = 15485, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 16, .skip = 25 },
    .{ .off = 15498, .len = 575, .nal_type = 1, .first = 1, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 16076, .len = 12, .nal_type = 1, .first = 0, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 16092, .len = 163, .nal_type = 1, .first = 1, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 16258, .len = 10, .nal_type = 1, .first = 0, .st_rps_bits = 22, .skip = 31 },
    .{ .off = 16272, .len = 138, .nal_type = 0, .first = 1, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 16413, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 16426, .len = 401, .nal_type = 1, .first = 1, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 16830, .len = 12, .nal_type = 1, .first = 0, .st_rps_bits = 18, .skip = 27 },
    .{ .off = 16846, .len = 222, .nal_type = 1, .first = 1, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 17071, .len = 10, .nal_type = 1, .first = 0, .st_rps_bits = 20, .skip = 29 },
    .{ .off = 17085, .len = 160, .nal_type = 0, .first = 1, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 17248, .len = 9, .nal_type = 0, .first = 0, .st_rps_bits = 14, .skip = 23 },
    .{ .off = 17261, .len = 335, .nal_type = 1, .first = 1, .st_rps_bits = 16, .skip = 25 },
    .{ .off = 17599, .len = 12, .nal_type = 1, .first = 0, .st_rps_bits = 16, .skip = 25 },
};

test "hevc: every slice's skipped bits in x265's stream, as ffmpeg's trace counts them" {
    var p = std.mem.zeroes(va.PictureParameterBufferHEVC);
    p.pic_width_in_luma_samples = SPS.width;
    p.pic_height_in_luma_samples = SPS.height;
    p.log2_min_luma_coding_block_size_minus3 = SPS.log2_min_cb_minus3;
    p.log2_diff_max_min_luma_coding_block_size = SPS.log2_diff_cb;
    p.log2_max_pic_order_cnt_lsb_minus4 = SPS.log2_max_poc_lsb_minus4;
    p.num_short_term_ref_pic_sets = SPS.num_st_rps;
    p.num_long_term_ref_pic_sps = SPS.num_lt_sps;
    p.pic_fields.separate_colour_plane_flag = SPS.separate_colour_plane;
    p.slice_parsing_fields.long_term_ref_pics_present_flag = SPS.long_term;
    p.slice_parsing_fields.output_flag_present_flag = PPS.output_flag_present;
    p.slice_parsing_fields.dependent_slice_segments_enabled_flag = PPS.dependent_slices;
    p.num_extra_slice_header_bits = PPS.extra_bits;
    var firsts: u32 = 0;
    for (SLICES) |s| {
        const nal = STREAM[s.off..][0..s.len];
        try std.testing.expectEqual(s.nal_type, (nal[0] >> 1) & 0x3f);
        p.st_rps_bits = s.st_rps_bits;
        const h = try hevc.parseHeader(nal, &p);
        try std.testing.expectEqual(s.skip, h.skip);
        firsts += s.first;
    }
    try std.testing.expectEqual(@as(usize, 60), SLICES.len);
    try std.testing.expectEqual(@as(u32, 30), firsts);
}
