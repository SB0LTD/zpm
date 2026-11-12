//! @zpm/va vp8_read — a VP8 stream (one frame a buffer, as WebM and IVF
//! hold it) read as a VA-API client reads it, for video.Decoder: the frame
//! tag and the key frame's size, the first partition's frame header read
//! with VP8's boolean decoder (RFC 6386 sections 7, 9 and 19.2), and the
//! state VP8 keeps across frames: the coefficient, mode and motion-vector
//! probabilities (updated by each frame, kept or not as
//! refresh_entropy_probs says), the segmentation and loop-filter deltas,
//! and the last, golden and altref references (refreshes and copies, as
//! FFmpeg's vp8 decoder keeps them). What it makes is VA's picture
//! parameters, probability buffer and slice parameters as FFmpeg's
//! vaapi_vp8 fills them; the decoder (vp8.sig on NVDEC) parses the
//! macroblocks itself.
//!
//! Pure and allocation-free.

const std = @import("std");
const vav = @import("vaapi_vp8.sig");
const t8 = @import("vp8_tables.sig");

pub const Error = error{ Truncated, Corrupt, Unsupported };
pub const INVALID: u32 = 0xffffffff;

/// RFC 6386's boolean decoder (section 7.3, its reference code).
const Bool = struct {
    data: []const u8,
    pos: usize = 0,
    value: u32 = 0,
    range: u32 = 255,
    bit_count: u32 = 0,

    fn next(b: *Bool) u32 {
        const v: u32 = if (b.pos < b.data.len) b.data[b.pos] else 0;
        b.pos += 1;
        return v;
    }
    fn init(data: []const u8) Bool {
        var b = Bool{ .data = data };
        b.value = (b.next() << 8) | b.next();
        return b;
    }
    fn read(b: *Bool, prob: u8) u1 {
        const split: u32 = 1 + (((b.range - 1) * prob) >> 8);
        const big = split << 8;
        var bit: u1 = 0;
        if (b.value >= big) {
            b.range -= split;
            b.value -= big;
            bit = 1;
        } else b.range = split;
        while (b.range < 128) {
            b.value <<= 1;
            b.range <<= 1;
            b.bit_count += 1;
            if (b.bit_count == 8) {
                b.bit_count = 0;
                b.value |= b.next();
            }
        }
        return bit;
    }
    fn flag(b: *Bool) bool {
        return b.read(128) == 1;
    }
    fn lit(b: *Bool, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | b.read(128);
        return v;
    }
    /// L(n) then a sign bit.
    fn signedLit(b: *Bool, n: u5) i32 {
        const v: i32 = @intCast(b.lit(n));
        return if (b.flag()) -v else v;
    }
    fn overrun(b: *const Bool) bool {
        return b.pos > b.data.len + 2;
    }
};

/// What VP8 keeps from frame to frame.
pub const State = struct {
    width: u32 = 0,
    height: u32 = 0,
    coef: [4][8][3][11]u8 = t8.DEFAULT_COEF_PROBS,
    ymode: [4]u8 = t8.DEFAULT_YMODE_PROB,
    uvmode: [3]u8 = t8.DEFAULT_UV_MODE_PROB,
    mv: [2][19]u8 = t8.DEFAULT_MV_CONTEXT,
    seg_enabled: bool = false,
    seg_abs: bool = false,
    seg_quant: [4]i8 = .{ 0, 0, 0, 0 },
    seg_lf: [4]i8 = .{ 0, 0, 0, 0 },
    lf_delta_enabled: bool = false,
    lf_ref: [4]i8 = .{ 0, 0, 0, 0 },
    lf_mode: [4]i8 = .{ 0, 0, 0, 0 },
    /// the references' surfaces
    last: u32 = INVALID,
    golden: u32 = INVALID,
    altref: u32 = INVALID,
    have_key: bool = false,
};

/// One frame read: what VA's buffers carry, and what its decode changes.
pub const Frame = struct {
    key: bool = false,
    show: bool = false,
    version: u3 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pic: vav.PictureParameterBufferVP8 = undefined,
    probs: vav.ProbabilityDataBufferVP8 = undefined,
    iq: vav.IQMatrixBufferVP8 = undefined,
    slice: vav.SliceParameterBufferVP8 = undefined,
    /// where the slice data starts in the frame (after the uncompressed chunk)
    data_offset: u32 = 0,
    // the reference updates once decoded
    refresh_golden: bool = false,
    refresh_alt: bool = false,
    refresh_last: bool = false,
    copy_golden: u2 = 0,
    copy_alt: u2 = 0,
    /// the state the frame leaves (its probabilities, when kept)
    next: State = .{},
};

fn clampLevel(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 63));
}

/// Reads frame `data` against `st` (not changed: `out.next` is the state
/// after it, `commit` puts it in place once the frame is decoded).
pub fn read(st: *const State, data: []const u8, out: *Frame) Error!void {
    if (data.len < 3) return error.Truncated;
    const tag = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    var f = Frame{};
    f.key = tag & 1 == 0;
    f.version = @intCast((tag >> 1) & 7);
    f.show = (tag >> 4) & 1 == 1;
    const first_size = tag >> 5;
    if (f.version > 3) return error.Unsupported;
    var at: usize = 3;
    var next = st.*;
    if (f.key) {
        if (data.len < 10) return error.Truncated;
        if (data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) return error.Corrupt;
        next.width = (@as(u32, data[6]) | (@as(u32, data[7]) << 8)) & 0x3fff;
        next.height = (@as(u32, data[8]) | (@as(u32, data[9]) << 8)) & 0x3fff;
        if (next.width == 0 or next.height == 0) return error.Corrupt;
        at = 10;
        // a key frame resets what VP8 keeps
        next.coef = t8.DEFAULT_COEF_PROBS;
        next.ymode = t8.DEFAULT_YMODE_PROB;
        next.uvmode = t8.DEFAULT_UV_MODE_PROB;
        next.mv = t8.DEFAULT_MV_CONTEXT;
        next.seg_abs = false;
        next.seg_quant = .{ 0, 0, 0, 0 };
        next.seg_lf = .{ 0, 0, 0, 0 };
        next.lf_ref = .{ 0, 0, 0, 0 };
        next.lf_mode = .{ 0, 0, 0, 0 };
        next.have_key = true;
    } else if (!st.have_key) return error.Corrupt;
    if (at + first_size > data.len) return error.Truncated;
    f.width = next.width;
    f.height = next.height;
    var b = Bool.init(data[at..][0..first_size]);

    var pic = std.mem.zeroes(vav.PictureParameterBufferVP8);
    var pf = vav.PicFields{};
    if (f.key) {
        _ = b.flag(); // color_space
        _ = b.flag(); // clamping_type
    }
    // segmentation
    next.seg_enabled = b.flag();
    var tree = [3]u8{ 255, 255, 255 };
    if (next.seg_enabled) {
        const update_map = b.flag();
        const update_data = b.flag();
        pf.update_mb_segmentation_map = @intFromBool(update_map);
        pf.update_segment_feature_data = @intFromBool(update_data);
        if (update_data) {
            next.seg_abs = b.flag();
            for (&next.seg_quant) |*q| q.* = if (b.flag()) @intCast(b.signedLit(7)) else 0;
            for (&next.seg_lf) |*l| l.* = if (b.flag()) @intCast(b.signedLit(6)) else 0;
        }
        if (update_map) {
            for (&tree) |*p| p.* = if (b.flag()) @intCast(b.lit(8)) else 255;
        }
    }
    pf.segmentation_enabled = @intFromBool(next.seg_enabled);
    // the loop filter
    const filter_type = b.flag();
    const level: i32 = @intCast(b.lit(6));
    const sharpness = b.lit(3);
    next.lf_delta_enabled = b.flag();
    var delta_update = false;
    if (next.lf_delta_enabled) {
        delta_update = b.flag();
        if (delta_update) {
            for (&next.lf_ref) |*d| {
                if (b.flag()) d.* = @intCast(b.signedLit(6));
            }
            for (&next.lf_mode) |*d| {
                if (b.flag()) d.* = @intCast(b.signedLit(6));
            }
        }
    }
    const dct_log2 = b.lit(2);
    // the quantizer (the decoder reads it from the header: VA's IQ matrix
    // is filled for completeness)
    const y_ac: i32 = @intCast(b.lit(7));
    var deltas: [5]i32 = .{ 0, 0, 0, 0, 0 };
    for (&deltas) |*d| d.* = if (b.flag()) b.signedLit(4) else 0;
    // the references
    var refresh_entropy = true;
    if (f.key) {
        refresh_entropy = b.flag();
        f.refresh_golden = true;
        f.refresh_alt = true;
        f.refresh_last = true;
    } else {
        f.refresh_golden = b.flag();
        f.refresh_alt = b.flag();
        if (!f.refresh_golden) f.copy_golden = @intCast(b.lit(2));
        if (!f.refresh_alt) f.copy_alt = @intCast(b.lit(2));
        pf.sign_bias_golden = b.read(128);
        pf.sign_bias_alternate = b.read(128);
        refresh_entropy = b.flag();
        f.refresh_last = b.flag();
    }
    // this frame's probabilities: updates on top of what is kept
    var coef = next.coef;
    for (0..4) |i| for (0..8) |j| for (0..3) |k| for (0..11) |l| {
        if (b.read(t8.COEF_UPDATE_PROBS[i][j][k][l]) == 1) coef[i][j][k][l] = @intCast(b.lit(8));
    };
    const skip_enabled = b.flag();
    pic.prob_skip_false = if (skip_enabled) @intCast(b.lit(8)) else 0;
    var ymode = next.ymode;
    var uvmode = next.uvmode;
    var mv = next.mv;
    if (!f.key) {
        pic.prob_intra = @intCast(b.lit(8));
        pic.prob_last = @intCast(b.lit(8));
        pic.prob_gf = @intCast(b.lit(8));
        if (b.flag()) {
            for (&ymode) |*p| p.* = @intCast(b.lit(8));
        }
        if (b.flag()) {
            for (&uvmode) |*p| p.* = @intCast(b.lit(8));
        }
        for (0..2) |i| for (0..19) |j| {
            if (b.read(t8.MV_UPDATE_PROBS[i][j]) == 1) {
                const x = b.lit(7);
                mv[i][j] = if (x != 0) @intCast(x << 1) else 1;
            }
        };
    }
    if (b.overrun()) return error.Truncated;
    // (refresh_entropy_probs 0: this frame's updates are its own; the
    // kept probabilities stay as they were)
    if (refresh_entropy) {
        next.coef = coef;
        next.ymode = ymode;
        next.uvmode = uvmode;
        next.mv = mv;
    }

    // VA's picture parameters (FFmpeg's vaapi_vp8)
    pic.frame_width = next.width;
    pic.frame_height = next.height;
    pic.last_ref_frame = if (f.key) INVALID else st.last;
    pic.golden_ref_frame = if (f.key) INVALID else st.golden;
    pic.alt_ref_frame = if (f.key) INVALID else st.altref;
    pic.out_of_loop_frame = INVALID;
    pf.key_frame = @intFromBool(!f.key);
    pf.version = f.version;
    pf.filter_type = @intFromBool(filter_type);
    pf.sharpness_level = @intCast(sharpness);
    pf.loop_filter_adj_enable = @intFromBool(next.lf_delta_enabled);
    pf.mode_ref_lf_delta_update = @intFromBool(delta_update);
    pf.mb_no_coeff_skip = @intFromBool(skip_enabled);
    pf.loop_filter_disable = @intFromBool(level == 0);
    pic.pic_fields = pf;
    pic.mb_segment_tree_probs = tree;
    for (0..4) |s| {
        var l = level;
        if (next.seg_enabled) l = if (next.seg_abs) next.seg_lf[s] else level + next.seg_lf[s];
        pic.loop_filter_level[s] = clampLevel(l);
    }
    pic.loop_filter_deltas_ref_frame = next.lf_ref;
    pic.loop_filter_deltas_mode = next.lf_mode;
    pic.y_mode_probs = ymode;
    pic.uv_mode_probs = uvmode;
    pic.mv_probs = mv;
    pic.bool_coder_ctx = .{ .range = @intCast(b.range), .value = @intCast((b.value >> 8) & 0xff), .count = @intCast(b.bit_count) };
    f.pic = pic;
    f.probs = std.mem.zeroes(vav.ProbabilityDataBufferVP8);
    f.probs.dct_coeff_probs = coef;
    // the quantizer indices, each segment's
    f.iq = std.mem.zeroes(vav.IQMatrixBufferVP8);
    for (0..4) |s| {
        var q = y_ac;
        if (next.seg_enabled) q = if (next.seg_abs) next.seg_quant[s] else y_ac + next.seg_quant[s];
        const base = std.math.clamp(q, 0, 127);
        const idx = [6]i32{ base, base + deltas[0], base + deltas[1], base + deltas[2], base + deltas[3], base + deltas[4] };
        for (idx, 0..) |v, k| f.iq.quantization_index[s][k] = @intCast(std.math.clamp(v, 0, 127));
    }
    // the slice: the first partition on (its size whole: macroblock_offset
    // 0), then each DCT partition's size from the table after it
    const parts: u32 = @as(u32, 1) << @intCast(dct_log2);
    var s = std.mem.zeroes(vav.SliceParameterBufferVP8);
    s.slice_data_offset = 0;
    s.slice_data_flag = 0;
    s.macroblock_offset = 0;
    s.num_of_partitions = @intCast(parts + 1);
    s.partition_size[0] = first_size;
    const after = at + first_size;
    const table = 3 * (parts - 1);
    if (after + table > data.len) return error.Truncated;
    var pos = after + table;
    for (0..parts) |k| {
        var size: u32 = undefined;
        if (k + 1 < parts) {
            const tb = data[after + 3 * k ..][0..3];
            size = @as(u32, tb[0]) | (@as(u32, tb[1]) << 8) | (@as(u32, tb[2]) << 16);
        } else size = @intCast(data.len - pos);
        if (pos + size > data.len) return error.Truncated;
        s.partition_size[k + 1] = size;
        pos += size;
    }
    f.data_offset = @intCast(at);
    s.slice_data_size = @intCast(data.len - at);
    f.slice = s;
    f.next = next;
    out.* = f;
}

/// The frame was decoded into `surface`: the state it leaves, the
/// references it refreshes or copies (copies from the references before
/// this frame, as FFmpeg's decoder does).
pub fn commit(st: *State, f: *const Frame, surface: u32) void {
    const old_last = st.last;
    const old_golden = st.golden;
    const old_alt = st.altref;
    st.* = f.next;
    st.last = old_last;
    st.golden = old_golden;
    st.altref = old_alt;
    if (f.copy_golden == 1) st.golden = old_last else if (f.copy_golden == 2) st.golden = old_alt;
    if (f.copy_alt == 1) st.altref = old_last else if (f.copy_alt == 2) st.altref = old_golden;
    if (f.refresh_golden) st.golden = surface;
    if (f.refresh_alt) st.altref = surface;
    if (f.refresh_last) st.last = surface;
}
