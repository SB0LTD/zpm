//! @zpm/va vp9_read — a VP9 stream (IVF/WebM frames, superframes split)
//! read as a VA-API client reads it, for video.Decoder: each frame's
//! uncompressed header far enough for VA's picture parameters (profile,
//! depth, size, the reference slots a frame names and refreshes, the two
//! headers' lengths), the eight reference slots' surfaces, and what is
//! shown: frames with show_frame, and show_existing_frame's slot (shown
//! again, nothing decoded). The decoder module (vp9.sig) parses both
//! headers itself from the frame's bytes; what VA gives it must agree with
//! the bitstream, and does, being read from it here.
//!
//! Pure and allocation-free.

const std = @import("std");
const vav = @import("vaapi_vp9.sig");

pub const Error = error{ Truncated, Corrupt, Unsupported };

/// A superframe's frames (the index at its end, VP9 Annex B), or the one
/// frame the bytes are.
pub const Frames = struct {
    sizes: [8]u32 = undefined,
    n: u32 = 0,

    pub fn of(data: []const u8) Frames {
        var f = Frames{};
        if (data.len > 0) {
            const last = data[data.len - 1];
            if (last & 0xe0 == 0xc0) {
                const count: u32 = (last & 7) + 1;
                const mag: u32 = ((last >> 3) & 3) + 1;
                const index_len = 2 + mag * count;
                if (data.len >= index_len and data[data.len - index_len] == last) {
                    var at = data.len - index_len + 1;
                    var total: usize = 0;
                    for (0..count) |i| {
                        var sz: u32 = 0;
                        for (0..mag) |b| sz |= @as(u32, data[at + b]) << @intCast(8 * b);
                        at += mag;
                        f.sizes[i] = sz;
                        total += sz;
                    }
                    if (total + index_len <= data.len) {
                        f.n = count;
                        return f;
                    }
                }
            }
        }
        f.sizes[0] = @intCast(data.len);
        f.n = if (data.len > 0) 1 else 0;
        return f;
    }
};

const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    fn bit(r: *Bits) Error!u1 {
        if (r.pos >= r.data.len * 8) return error.Truncated;
        const b = (r.data[r.pos >> 3] >> @intCast(7 - (r.pos & 7))) & 1;
        r.pos += 1;
        return @intCast(b);
    }
    fn flag(r: *Bits) Error!bool {
        return try r.bit() == 1;
    }
    fn bits(r: *Bits, n: u6) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | try r.bit();
        return v;
    }
    fn signed(r: *Bits, n: u6) Error!void {
        _ = try r.bits(n);
        _ = try r.bit();
    }
};

/// What a frame's uncompressed header says that VA's buffers carry.
pub const Header = struct {
    profile: u2 = 0,
    show_existing: bool = false,
    existing_idx: u3 = 0,
    key: bool = false,
    show_frame: bool = false,
    error_res: bool = false,
    intra_only: bool = false,
    reset_context: u2 = 0,
    refresh: u8 = 0,
    ref_idx: [3]u3 = .{ 0, 0, 0 },
    sign_bias: [3]u1 = .{ 0, 0, 0 },
    /// 0: a reference's (`size_from`)
    width: u32 = 0,
    height: u32 = 0,
    size_from: ?u2 = null,
    allow_hp: bool = false,
    interp: u3 = 0,
    refresh_context: bool = false,
    parallel: bool = false,
    context_idx: u2 = 0,
    lf_level: u8 = 0,
    lf_sharpness: u8 = 0,
    log2_tile_cols: u8 = 0,
    log2_tile_rows: u8 = 0,
    seg_enabled: bool = false,
    seg_update_map: bool = false,
    seg_temporal: bool = false,
    seg_tree: [7]u8 = [_]u8{255} ** 7,
    seg_pred: [3]u8 = [_]u8{255} ** 3,
    lossless: bool = false,
    bit_depth: u8 = 8,
    /// the uncompressed header's bytes, the compressed header's
    uncompressed_bytes: u32 = 0,
    compressed_bytes: u32 = 0,
};

fn tileColsLog2(width: u32) struct { min: u32, max: u32 } {
    const mi_cols = (width + 7) >> 3;
    const sb_cols = (mi_cols + 7) >> 3;
    var min: u32 = 0;
    while ((@as(u32, 64) << @intCast(min)) < sb_cols) min += 1;
    var max: u32 = 1;
    while ((sb_cols >> @intCast(max)) >= 4) max += 1;
    max -= 1;
    return .{ .min = @min(min, 6), .max = @min(@max(max, min), 6) };
}

fn colorConfig(r: *Bits, h: *Header) Error!void {
    if (h.profile >= 2) {
        h.bit_depth = if (try r.flag()) 12 else 10;
    } else h.bit_depth = 8;
    const cs = try r.bits(3);
    if (cs != 7) {
        _ = try r.bit();
        if (h.profile == 1 or h.profile == 3) {
            const ssx = try r.bit();
            const ssy = try r.bit();
            _ = try r.bit();
            if (ssx != 1 or ssy != 1) return error.Unsupported; // (4:2:0 only)
        }
    } else {
        if (h.profile == 1 or h.profile == 3) return error.Unsupported; // 4:4:4 RGB
        return error.Corrupt;
    }
}

/// The uncompressed header of `frame`. `sizes`: each reference slot's
/// frame size (frame_size_with_refs); `depth`: the stream's (inter frames
/// keep it).
pub fn parse(frame: []const u8, sizes: *const [8][2]u32, depth: u8, out: *Header) Error!void {
    var r = Bits{ .data = frame };
    var h = Header{ .bit_depth = depth };
    if (try r.bits(2) != 2) return error.Corrupt;
    const lo = try r.bit();
    const hi = try r.bit();
    h.profile = (@as(u2, hi) << 1) | lo;
    if (h.profile == 3) _ = try r.bit();
    if (try r.flag()) {
        h.show_existing = true;
        h.existing_idx = @intCast(try r.bits(3));
        out.* = h;
        return;
    }
    h.key = try r.bit() == 0;
    h.show_frame = try r.flag();
    h.error_res = try r.flag();
    if (h.key) {
        if (try r.bits(24) != 0x498342) return error.Corrupt;
        try colorConfig(&r, &h);
        h.refresh = 0xff;
        h.width = try r.bits(16) + 1;
        h.height = try r.bits(16) + 1;
        if (try r.flag()) _ = try r.bits(32);
    } else {
        h.intra_only = if (h.show_frame) false else try r.flag();
        h.reset_context = if (h.error_res) 0 else @intCast(try r.bits(2));
        if (h.intra_only) {
            if (try r.bits(24) != 0x498342) return error.Corrupt;
            if (h.profile > 0) try colorConfig(&r, &h) else h.bit_depth = 8;
            h.refresh = @intCast(try r.bits(8));
            h.width = try r.bits(16) + 1;
            h.height = try r.bits(16) + 1;
            if (try r.flag()) _ = try r.bits(32);
        } else {
            h.refresh = @intCast(try r.bits(8));
            for (0..3) |i| {
                h.ref_idx[i] = @intCast(try r.bits(3));
                h.sign_bias[i] = try r.bit();
            }
            for (0..3) |i| {
                if (try r.flag()) {
                    h.size_from = @intCast(i);
                    const s = sizes[h.ref_idx[i]];
                    h.width = s[0];
                    h.height = s[1];
                    break;
                }
            }
            if (h.size_from == null) {
                h.width = try r.bits(16) + 1;
                h.height = try r.bits(16) + 1;
            }
            if (try r.flag()) _ = try r.bits(32);
            h.allow_hp = try r.flag();
            h.interp = if (try r.flag()) 4 else @intCast(try r.bits(2));
        }
    }
    if (h.width == 0 or h.height == 0) return error.Corrupt;
    if (!h.error_res) {
        h.refresh_context = try r.flag();
        h.parallel = try r.flag();
    } else h.parallel = true;
    h.context_idx = @intCast(try r.bits(2));
    // loop_filter_params
    h.lf_level = @intCast(try r.bits(6));
    h.lf_sharpness = @intCast(try r.bits(3));
    if (try r.flag()) {
        if (try r.flag()) {
            for (0..4) |_| {
                if (try r.flag()) try r.signed(6);
            }
            for (0..2) |_| {
                if (try r.flag()) try r.signed(6);
            }
        }
    }
    // quantization_params
    const base_q = try r.bits(8);
    var deltas_zero = true;
    for (0..3) |_| {
        if (try r.flag()) {
            const v = try r.bits(4);
            _ = try r.bit();
            if (v != 0) deltas_zero = false;
        }
    }
    h.lossless = base_q == 0 and deltas_zero;
    // segmentation_params
    h.seg_enabled = try r.flag();
    if (h.seg_enabled) {
        h.seg_update_map = try r.flag();
        if (h.seg_update_map) {
            for (&h.seg_tree) |*t| t.* = if (try r.flag()) @intCast(try r.bits(8)) else 255;
            h.seg_temporal = try r.flag();
            for (&h.seg_pred) |*t| t.* = if (h.seg_temporal and try r.flag()) @intCast(try r.bits(8)) else 255;
        }
        if (try r.flag()) {
            _ = try r.bit();
            const fbits = [4]u6{ 8, 6, 2, 0 };
            const signed_ = [4]bool{ true, true, false, false };
            for (0..8) |_| {
                for (0..4) |f| {
                    if (try r.flag()) {
                        _ = try r.bits(fbits[f]);
                        if (signed_[f]) _ = try r.bit();
                    }
                }
            }
        }
    }
    // tile_info
    const t = tileColsLog2(h.width);
    var cols: u32 = t.min;
    while (cols < t.max and try r.flag()) cols += 1;
    h.log2_tile_cols = @intCast(cols);
    h.log2_tile_rows = try r.bit();
    if (h.log2_tile_rows != 0) h.log2_tile_rows += try r.bit();
    h.compressed_bytes = try r.bits(16);
    if (h.compressed_bytes == 0) return error.Corrupt;
    h.uncompressed_bytes = @intCast((r.pos + 7) / 8);
    if (h.uncompressed_bytes + h.compressed_bytes > frame.len) return error.Truncated;
    out.* = h;
}

pub const INVALID: u32 = 0xffffffff;

/// VA's picture parameters for a frame whose slots hold `slots` (VA
/// surfaces; INVALID: none).
pub fn pictureParams(h: *const Header, slots: *const [8]u32) vav.PictureParameterBufferVP9 {
    var p = std.mem.zeroes(vav.PictureParameterBufferVP9);
    p.frame_width = @intCast(h.width);
    p.frame_height = @intCast(h.height);
    p.reference_frames = slots.*;
    p.pic_fields = .{
        .subsampling_x = 1,
        .subsampling_y = 1,
        .frame_type = @intFromBool(!h.key),
        .show_frame = @intFromBool(h.show_frame),
        .error_resilient_mode = @intFromBool(h.error_res),
        .intra_only = @intFromBool(h.intra_only),
        .allow_high_precision_mv = @intFromBool(h.allow_hp),
        // (FFmpeg's numbering: the bitstream's 0 smooth, 1 regular, 2
        // sharp, 3 bilinear map to it as libvpx's literal_to_filter does)
        .mcomp_filter_type = switch (h.interp) {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 3,
            else => 4,
        },
        .frame_parallel_decoding_mode = @intFromBool(h.parallel),
        .reset_frame_context = h.reset_context,
        .refresh_frame_context = @intFromBool(h.refresh_context),
        .frame_context_idx = h.context_idx,
        .segmentation_enabled = @intFromBool(h.seg_enabled),
        .segmentation_temporal_update = @intFromBool(h.seg_temporal),
        .segmentation_update_map = @intFromBool(h.seg_update_map),
        .last_ref_frame = h.ref_idx[0],
        .last_ref_frame_sign_bias = h.sign_bias[0],
        .golden_ref_frame = h.ref_idx[1],
        .golden_ref_frame_sign_bias = h.sign_bias[1],
        .alt_ref_frame = h.ref_idx[2],
        .alt_ref_frame_sign_bias = h.sign_bias[2],
        .lossless_flag = @intFromBool(h.lossless),
    };
    p.filter_level = h.lf_level;
    p.sharpness_level = h.lf_sharpness;
    p.log2_tile_rows = h.log2_tile_rows;
    p.log2_tile_columns = h.log2_tile_cols;
    p.frame_header_length_in_bytes = @intCast(h.uncompressed_bytes);
    p.first_partition_size = @intCast(h.compressed_bytes);
    p.mb_segment_tree_probs = h.seg_tree;
    p.segment_pred_probs = h.seg_pred;
    p.profile = h.profile;
    p.bit_depth = h.bit_depth;
    return p;
}

pub fn sliceParams(len: u32) vav.SliceParameterBufferVP9 {
    var s = std.mem.zeroes(vav.SliceParameterBufferVP9);
    s.slice_data_size = len;
    s.slice_data_offset = 0;
    s.slice_data_flag = 0;
    return s;
}
