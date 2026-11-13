//! @zpm/va h264_parse — an H.264 elementary stream (Annex B: start codes;
//! or 4-byte lengths) read as a VA-API client reads it, for apps that hand
//! over the bitstream itself (Media Foundation's decoder on Galaxy's
//! Windows layer, video.sig) instead of VA's buffers: sequence and picture
//! parameter sets, each slice's header, the picture order count (8.2.1:
//! types 0, 1 and 2), the decoded picture buffer's reference marking
//! (8.2.5: sliding window, memory management control operations, IDR) and
//! the pictures' output order (C.4.5.3's bumping), and what that makes of
//! VA's buffers as FFmpeg's vaapi_h264 fills them: the picture parameters
//! (CurrPic, the ReferenceFrames the DPB holds), the scaling lists in the
//! bitstream's (zig-zag) order, and one slice parameter buffer per slice.
//! The driver (driver.sig) turns those into NVDEC's setup; the decoder
//! parses each slice's header and builds its reference lists itself, so
//! the lists here are VA's initial ones only where VA's struct wants
//! them, and a slice's prediction weights are left out (NVDEC reads them
//! from the slice header).
//!
//! What is left for later: interlaced field pairs are marked as frames
//! (MBAFF frames decode; PAFF field pictures are refused, `Error.Field`),
//! slice groups (Baseline's FMO, ASO) and SVC/MVC NAL units are refused,
//! frame_num gaps (gaps_in_frame_num_value_allowed_flag) only slide the
//! window, without "non-existing" frames.
//!
//! Pure and allocation-free: fixed tables (32 SPS, 256 PPS, a 16-picture
//! DPB), the caller's slices.

const std = @import("std");
const va = @import("vaapi.sig");
const Reader = @import("enc_parse.sig").Reader;

pub const MAX_SPS = 32;
pub const MAX_PPS = 256;
pub const MAX_DPB = 16;
pub const MAX_SLICES = 128;

pub const Error = error{ Truncated, Bad, Unsupported, Field, NoParameterSet };

// ── NAL units ────────────────────────────────────────────────────────────────

pub const NAL_SLICE: u8 = 1;
pub const NAL_DPA: u8 = 2;
pub const NAL_IDR: u8 = 5;
pub const NAL_SEI: u8 = 6;
pub const NAL_SPS: u8 = 7;
pub const NAL_PPS: u8 = 8;
pub const NAL_AUD: u8 = 9;
pub const NAL_END_SEQ: u8 = 10;
pub const NAL_END_STREAM: u8 = 11;

/// The NAL units of an access unit: start codes (00 00 01 or 00 00 00 01)
/// or, when the buffer does not start with one, 4-byte big-endian lengths
/// (MP4's AVCC with lengthSizeMinusOne 3, what a demuxer may pass through).
pub const NalIter = struct {
    data: []const u8,
    pos: usize = 0,
    lengths: bool = false,

    pub fn init(data: []const u8) NalIter {
        var it = NalIter{ .data = data };
        it.lengths = !startsWithCode(data);
        return it;
    }

    pub fn next(it: *NalIter) ?[]const u8 {
        if (it.lengths) {
            if (it.pos + 4 > it.data.len) return null;
            const n = std.mem.readInt(u32, it.data[it.pos..][0..4], .big);
            it.pos += 4;
            if (n == 0 or n > it.data.len - it.pos) {
                it.pos = it.data.len;
                return null;
            }
            const nal = it.data[it.pos..][0..n];
            it.pos += n;
            return nal;
        }
        // past the next start code
        const s = findCode(it.data, it.pos) orelse return null;
        const begin = s.end;
        const e = findCode(it.data, begin);
        var end = if (e) |x| x.start else it.data.len;
        it.pos = end;
        // (a four-byte start code's leading zero, and trailing zero bytes)
        while (end > begin and it.data[end - 1] == 0) end -= 1;
        if (end <= begin) return it.next();
        return it.data[begin..end];
    }
};

fn startsWithCode(d: []const u8) bool {
    if (d.len >= 3 and d[0] == 0 and d[1] == 0 and d[2] == 1) return true;
    if (d.len >= 4 and d[0] == 0 and d[1] == 0 and d[2] == 0 and d[3] == 1) return true;
    return false;
}

const Code = struct { start: usize, end: usize };

fn findCode(d: []const u8, from: usize) ?Code {
    var i = from;
    while (i + 3 <= d.len) : (i += 1) {
        if (d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 1) return .{ .start = i, .end = i + 3 };
    }
    return null;
}

/// Whether bits are left in the RBSP before its stop bit (7.2's
/// more_rbsp_data), `r` reading NAL unit `nal`.
fn moreData(r: *const Reader, nal: []const u8) bool {
    var last = nal.len;
    while (last > 0 and nal[last - 1] == 0) last -= 1;
    if (last == 0) return false;
    const b = nal[last - 1];
    const stop: u3 = @intCast(@ctz(b)); // the stop bit, counted from the least significant
    const stop_pos = (last - 1) * 8 + (7 - @as(usize, stop));
    const here = r.pos * 8 + r.bit;
    return here < stop_pos;
}

// ── Scaling lists ────────────────────────────────────────────────────────────

/// Table 7-3's defaults, in zig-zag (bitstream) order.
const DEFAULT_4X4_INTRA = [16]u8{ 6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42 };
const DEFAULT_4X4_INTER = [16]u8{ 10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34 };
const DEFAULT_8X8_INTRA = [64]u8{
    6,  10, 10, 13, 11, 13, 16, 16, 16, 16, 18, 18, 18, 18, 18, 23,
    23, 23, 23, 23, 23, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27,
    27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31,
    31, 33, 33, 33, 33, 33, 36, 36, 36, 36, 38, 38, 38, 40, 40, 42,
};
const DEFAULT_8X8_INTER = [64]u8{
    9,  13, 13, 15, 13, 15, 17, 17, 17, 17, 19, 19, 19, 19, 19, 21,
    21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 24, 24, 24, 24,
    24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27,
    27, 28, 28, 28, 28, 28, 30, 30, 30, 30, 32, 32, 32, 33, 33, 35,
};

pub const Scaling = struct {
    l4: [6][16]u8 = [_][16]u8{[_]u8{16} ** 16} ** 6,
    /// Y intra, Y inter (and for 4:4:4, Cb and Cr: VA carries two)
    l8: [6][64]u8 = [_][64]u8{[_]u8{16} ** 64} ** 6,
};

/// One scaling_list() (7.3.2.1.1.1): the list read, or its default (true
/// when useDefaultScalingMatrixFlag), into `out`.
fn readList(r: *Reader, out: []u8) bool {
    var last: i32 = 8;
    var next: i32 = 8;
    for (out, 0..) |*v, j| {
        if (next != 0) {
            const delta = r.se();
            next = @mod(last + delta + 256, 256);
            if (j == 0 and next == 0) return true;
        }
        const val = if (next == 0) last else next;
        v.* = @intCast(val);
        last = val;
    }
    return false;
}

/// The lists of an SPS or PPS (7.4.2.1.1, Table 7-2's fall-back rules A
/// and B): `present` lists read, the others from their fall-back.
fn readScaling(r: *Reader, n8: usize, fallback: ?*const Scaling, out: *Scaling) void {
    var i: usize = 0;
    while (i < 6 + n8) : (i += 1) {
        const present = r.flag();
        if (i < 6) {
            if (present) {
                if (readList(r, &out.l4[i])) out.l4[i] = if (i < 3) DEFAULT_4X4_INTRA else DEFAULT_4X4_INTER;
            } else {
                // rule A (an SPS, fallback null) or B (a PPS: the SPS's)
                out.l4[i] = if (i == 0 or i == 3)
                    (if (fallback) |f| f.l4[i] else if (i == 0) DEFAULT_4X4_INTRA else DEFAULT_4X4_INTER)
                else
                    out.l4[i - 1];
            }
        } else {
            const k = i - 6;
            if (present) {
                if (readList(r, &out.l8[k])) out.l8[k] = if (k % 2 == 0) DEFAULT_8X8_INTRA else DEFAULT_8X8_INTER;
            } else {
                out.l8[k] = if (k < 2)
                    (if (fallback) |f| f.l8[k] else if (k == 0) DEFAULT_8X8_INTRA else DEFAULT_8X8_INTER)
                else
                    out.l8[k - 2];
            }
        }
    }
    // (lists past n8 the transform_8x8_mode leaves unread: their fall-back)
    var k = n8;
    while (k < 6) : (k += 1) {
        out.l8[k] = if (k < 2)
            (if (fallback) |f| f.l8[k] else if (k == 0) DEFAULT_8X8_INTRA else DEFAULT_8X8_INTER)
        else
            out.l8[k - 2];
    }
}

// ── Parameter sets ───────────────────────────────────────────────────────────

pub const Sps = struct {
    valid: bool = false,
    profile_idc: u8 = 0,
    constraint_flags: u8 = 0,
    level_idc: u8 = 0,
    id: u8 = 0,
    chroma_format_idc: u2 = 1,
    separate_colour_plane: bool = false,
    bit_depth_luma: u8 = 8,
    bit_depth_chroma: u8 = 8,
    transform_bypass: bool = false,
    scaling_present: bool = false,
    scaling: Scaling = .{},
    log2_max_frame_num: u5 = 4,
    poc_type: u2 = 0,
    log2_max_poc_lsb: u5 = 4,
    delta_pic_order_always_zero: bool = false,
    offset_for_non_ref_pic: i32 = 0,
    offset_for_top_to_bottom_field: i32 = 0,
    num_ref_frames_in_poc_cycle: u8 = 0,
    offset_for_ref_frame: [255]i32 = [_]i32{0} ** 255,
    num_ref_frames: u8 = 0,
    gaps_allowed: bool = false,
    mb_width: u16 = 0,
    /// in map units (frame_mbs_only: macroblocks; else field macroblock pairs)
    map_height: u16 = 0,
    frame_mbs_only: bool = true,
    mbaff: bool = false,
    direct_8x8_inference: bool = false,
    crop: [4]u32 = .{ 0, 0, 0, 0 },
    /// VUI's bitstream_restriction: max_num_reorder_frames, max_dec_frame_buffering
    reorder: ?u8 = null,
    max_dec_frame_buffering: ?u8 = null,

    /// The frame's height in macroblocks (both fields).
    pub fn mbHeight(s: *const Sps) u32 {
        return @as(u32, s.map_height) * (if (s.frame_mbs_only) @as(u32, 1) else 2);
    }

    pub fn width(s: *const Sps) u32 {
        return @as(u32, s.mb_width) * 16;
    }
    pub fn height(s: *const Sps) u32 {
        return s.mbHeight() * 16;
    }

    /// The picture's visible rectangle (frame_cropping), in samples:
    /// left, top, width, height.
    pub fn visible(s: *const Sps) [4]u32 {
        const cx: u32 = if (s.chroma_format_idc == 1 or s.chroma_format_idc == 2) 2 else 1;
        const cy: u32 = (if (s.chroma_format_idc == 1) @as(u32, 2) else 1) * (if (s.frame_mbs_only) @as(u32, 1) else 2);
        const l = s.crop[0] * cx;
        const r = s.crop[1] * cx;
        const t = s.crop[2] * cy;
        const b = s.crop[3] * cy;
        const w = s.width();
        const h = s.height();
        if (l + r >= w or t + b >= h) return .{ 0, 0, w, h };
        return .{ l, t, w - l - r, h - t - b };
    }

    /// The DPB's size in frames (A.3.1's MaxDpbMbs for the level, or the
    /// VUI's max_dec_frame_buffering).
    pub fn dpbFrames(s: *const Sps) u32 {
        if (s.max_dec_frame_buffering) |m| return @max(@min(@as(u32, m), MAX_DPB), @max(@as(u32, s.num_ref_frames), 1));
        const max_dpb_mbs: u32 = switch (s.level_idc) {
            9, 10 => 396,
            11 => if (s.constraint_flags & 0x10 != 0 and s.profile_idc != 100 and s.profile_idc != 110 and s.profile_idc != 122 and s.profile_idc != 244) 396 else 900,
            12, 13, 20 => 2376,
            21 => 4752,
            22, 30 => 8100,
            31 => 18000,
            32 => 20480,
            40, 41 => 32768,
            42 => 34816,
            50 => 110400,
            51, 52 => 184320,
            else => 696320, // level 6.x
        };
        const frame_mbs = @as(u32, s.mb_width) * s.mbHeight();
        if (frame_mbs == 0) return MAX_DPB;
        return @max(@min(max_dpb_mbs / frame_mbs, MAX_DPB), @max(@as(u32, s.num_ref_frames), 1));
    }

    /// Pictures that may wait for output (the bumping process's limit).
    pub fn reorderDepth(s: *const Sps) u32 {
        if (s.reorder) |r| return @min(r, MAX_DPB);
        // (no VUI: Baseline and Constrained Baseline never reorder; others
        // may hold a whole DPB)
        if (s.profile_idc == 66) return 0;
        if (s.profile_idc == 44 or s.profile_idc == 86 or s.profile_idc == 100 or s.profile_idc == 110 or s.profile_idc == 122 or s.profile_idc == 244) {
            if (s.constraint_flags & 0x10 != 0) return 0; // intra profiles
        }
        return s.dpbFrames();
    }
};

pub const Pps = struct {
    valid: bool = false,
    id: u8 = 0,
    sps_id: u8 = 0,
    entropy_coding_mode: bool = false,
    bottom_field_pic_order_in_frame_present: bool = false,
    num_slice_groups: u8 = 1,
    num_ref_idx_l0_default: u8 = 1,
    num_ref_idx_l1_default: u8 = 1,
    weighted_pred: bool = false,
    weighted_bipred_idc: u2 = 0,
    pic_init_qp_minus26: i8 = 0,
    pic_init_qs_minus26: i8 = 0,
    chroma_qp_index_offset: i8 = 0,
    deblocking_filter_control_present: bool = false,
    constrained_intra_pred: bool = false,
    redundant_pic_cnt_present: bool = false,
    transform_8x8_mode: bool = false,
    scaling_present: bool = false,
    scaling: Scaling = .{},
    second_chroma_qp_index_offset: i8 = 0,
};

fn hasHighFields(profile_idc: u8) bool {
    return switch (profile_idc) {
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 => true,
        else => false,
    };
}

/// seq_parameter_set_rbsp() (7.3.2.1.1) from NAL unit `nal` (header included).
pub fn parseSps(nal: []const u8, out: *Sps) Error!void {
    if (nal.len < 4) return error.Truncated;
    var r = Reader.init(nal[1..]);
    var s = Sps{};
    s.profile_idc = @intCast(r.u(8));
    s.constraint_flags = @intCast(r.u(8));
    s.level_idc = @intCast(r.u(8));
    const id = r.ue();
    if (id >= MAX_SPS) return error.Bad;
    s.id = @intCast(id);
    if (hasHighFields(s.profile_idc)) {
        const cf = r.ue();
        if (cf > 3) return error.Bad;
        s.chroma_format_idc = @intCast(cf);
        if (cf == 3) s.separate_colour_plane = r.flag();
        const bl = r.ue();
        const bc = r.ue();
        if (bl > 6 or bc > 6) return error.Bad;
        s.bit_depth_luma = @intCast(bl + 8);
        s.bit_depth_chroma = @intCast(bc + 8);
        s.transform_bypass = r.flag();
        s.scaling_present = r.flag();
        if (s.scaling_present) readScaling(&r, if (cf != 3) 2 else 6, null, &s.scaling);
    }
    const lfn = r.ue();
    if (lfn > 12) return error.Bad;
    s.log2_max_frame_num = @intCast(lfn + 4);
    const pt = r.ue();
    if (pt > 2) return error.Bad;
    s.poc_type = @intCast(pt);
    if (pt == 0) {
        const lp = r.ue();
        if (lp > 12) return error.Bad;
        s.log2_max_poc_lsb = @intCast(lp + 4);
    } else if (pt == 1) {
        s.delta_pic_order_always_zero = r.flag();
        s.offset_for_non_ref_pic = r.se();
        s.offset_for_top_to_bottom_field = r.se();
        const n = r.ue();
        if (n > 255) return error.Bad;
        s.num_ref_frames_in_poc_cycle = @intCast(n);
        for (0..n) |i| s.offset_for_ref_frame[i] = r.se();
    }
    const nrf = r.ue();
    if (nrf > MAX_DPB) return error.Bad;
    s.num_ref_frames = @intCast(nrf);
    s.gaps_allowed = r.flag();
    const w = r.ue() + 1;
    const h = r.ue() + 1;
    if (w > 1024 or h > 1024) return error.Bad;
    s.mb_width = @intCast(w);
    s.map_height = @intCast(h);
    s.frame_mbs_only = r.flag();
    if (!s.frame_mbs_only) s.mbaff = r.flag();
    s.direct_8x8_inference = r.flag();
    if (r.flag()) {
        for (&s.crop) |*c| c.* = r.ue();
    }
    if (r.flag()) parseVui(&r, &s);
    if (r.bad) return error.Truncated;
    s.valid = true;
    out.* = s;
}

fn skipHrd(r: *Reader) void {
    const cpb = r.ue() + 1;
    _ = r.u(4);
    _ = r.u(4);
    var i: u32 = 0;
    while (i < cpb and i < 32) : (i += 1) {
        _ = r.ue();
        _ = r.ue();
        _ = r.flag();
    }
    _ = r.u(5);
    _ = r.u(5);
    _ = r.u(5);
    _ = r.u(5);
}

/// vui_parameters() (E.1.1): only bitstream_restriction is kept.
fn parseVui(r: *Reader, s: *Sps) void {
    if (r.flag()) { // aspect_ratio_info_present_flag
        if (r.u(8) == 255) {
            _ = r.u(16);
            _ = r.u(16);
        }
    }
    if (r.flag()) _ = r.flag(); // overscan
    if (r.flag()) { // video_signal_type_present_flag
        _ = r.u(3);
        _ = r.flag();
        if (r.flag()) {
            _ = r.u(8);
            _ = r.u(8);
            _ = r.u(8);
        }
    }
    if (r.flag()) {
        _ = r.ue();
        _ = r.ue();
    }
    if (r.flag()) { // timing_info_present_flag
        _ = r.u(32);
        _ = r.u(32);
        _ = r.flag();
    }
    const nal_hrd = r.flag();
    if (nal_hrd) skipHrd(r);
    const vcl_hrd = r.flag();
    if (vcl_hrd) skipHrd(r);
    if (nal_hrd or vcl_hrd) _ = r.flag(); // low_delay_hrd_flag
    _ = r.flag(); // pic_struct_present_flag
    if (r.flag()) { // bitstream_restriction_flag
        _ = r.flag();
        _ = r.ue();
        _ = r.ue();
        _ = r.ue();
        _ = r.ue();
        const reorder = r.ue();
        const buffering = r.ue();
        if (!r.bad) {
            s.reorder = @intCast(@min(reorder, MAX_DPB));
            s.max_dec_frame_buffering = @intCast(@min(buffering, MAX_DPB));
        }
    }
    if (r.bad) {
        // (a truncated VUI loses only what it would have said)
        r.bad = false;
        s.reorder = null;
        s.max_dec_frame_buffering = null;
    }
}

/// pic_parameter_set_rbsp() (7.3.2.2); `spss` gives the scaling lists' fall-back.
pub fn parsePps(nal: []const u8, spss: *const [MAX_SPS]Sps, out: *Pps) Error!void {
    if (nal.len < 2) return error.Truncated;
    var r = Reader.init(nal[1..]);
    var p = Pps{};
    const id = r.ue();
    const sid = r.ue();
    if (id >= MAX_PPS or sid >= MAX_SPS) return error.Bad;
    p.id = @intCast(id);
    p.sps_id = @intCast(sid);
    const sps = &spss[sid];
    if (!sps.valid) return error.NoParameterSet;
    p.entropy_coding_mode = r.flag();
    p.bottom_field_pic_order_in_frame_present = r.flag();
    const groups = r.ue() + 1;
    if (groups > 1) return error.Unsupported; // (FMO: Baseline's slice groups)
    p.num_slice_groups = 1;
    const l0 = r.ue() + 1;
    const l1 = r.ue() + 1;
    if (l0 > 32 or l1 > 32) return error.Bad;
    p.num_ref_idx_l0_default = @intCast(l0);
    p.num_ref_idx_l1_default = @intCast(l1);
    p.weighted_pred = r.flag();
    p.weighted_bipred_idc = @intCast(r.u(2));
    p.pic_init_qp_minus26 = @intCast(std.math.clamp(r.se(), -26, 25));
    p.pic_init_qs_minus26 = @intCast(std.math.clamp(r.se(), -26, 25));
    p.chroma_qp_index_offset = @intCast(std.math.clamp(r.se(), -12, 12));
    p.deblocking_filter_control_present = r.flag();
    p.constrained_intra_pred = r.flag();
    p.redundant_pic_cnt_present = r.flag();
    p.second_chroma_qp_index_offset = p.chroma_qp_index_offset;
    // the SPS's lists unless this PPS has its own
    p.scaling = sps.scaling;
    if (moreData(&r, nal[1..])) {
        p.transform_8x8_mode = r.flag();
        p.scaling_present = r.flag();
        if (p.scaling_present) {
            const n8: usize = if (p.transform_8x8_mode) (if (sps.chroma_format_idc == 3) @as(usize, 6) else 2) else 0;
            const fb: ?*const Scaling = if (sps.scaling_present) &sps.scaling else null;
            readScaling(&r, n8, fb, &p.scaling);
        }
        p.second_chroma_qp_index_offset = @intCast(std.math.clamp(r.se(), -12, 12));
    }
    if (r.bad) return error.Truncated;
    p.valid = true;
    out.* = p;
}

// ── Slice headers ────────────────────────────────────────────────────────────

pub const MmcoOp = struct { op: u8, a: u32 = 0, b: u32 = 0 };

pub const SliceHeader = struct {
    nal_type: u8,
    nal_ref_idc: u2,
    first_mb: u32,
    slice_type: u8,
    pps_id: u8,
    frame_num: u32,
    field_pic: bool = false,
    bottom_field: bool = false,
    idr_pic_id: u32 = 0,
    poc_lsb: u32 = 0,
    delta_poc_bottom: i32 = 0,
    delta_poc: [2]i32 = .{ 0, 0 },
    redundant_pic_cnt: u32 = 0,
    direct_spatial_mv_pred: bool = false,
    num_ref_idx_l0: u8 = 0,
    num_ref_idx_l1: u8 = 0,
    no_output_of_prior_pics: bool = false,
    long_term_reference: bool = false,
    adaptive: bool = false,
    mmco: [32]MmcoOp = undefined,
    mmco_count: u8 = 0,
    cabac_init_idc: u8 = 0,
    slice_qp_delta: i8 = 0,
    disable_deblocking_filter_idc: u8 = 0,
    slice_alpha_c0_offset_div2: i8 = 0,
    slice_beta_offset_div2: i8 = 0,
    /// the header's bits from the NAL unit header's first (emulation
    /// prevention bytes counted as the bitstream has them)
    bits: u32 = 0,

    pub fn isIdr(h: *const SliceHeader) bool {
        return h.nal_type == NAL_IDR;
    }
    pub fn isB(h: *const SliceHeader) bool {
        return h.slice_type == 1;
    }
    pub fn isP(h: *const SliceHeader) bool {
        return h.slice_type == 0 or h.slice_type == 3;
    }
    pub fn isI(h: *const SliceHeader) bool {
        return h.slice_type == 2 or h.slice_type == 4;
    }
};

fn skipRefPicListModification(r: *Reader) void {
    if (r.flag()) {
        var n: u32 = 0;
        while (n < 66 and !r.bad) : (n += 1) {
            const idc = r.ue();
            if (idc == 3) break;
            _ = r.ue();
        }
    }
}

fn skipPredWeightTable(r: *Reader, sps: *const Sps, h: *const SliceHeader) void {
    _ = r.ue(); // luma_log2_weight_denom
    const chroma = sps.chroma_format_idc != 0 and !sps.separate_colour_plane;
    if (chroma) _ = r.ue();
    const lists: u32 = if (h.isB()) 2 else 1;
    var l: u32 = 0;
    while (l < lists) : (l += 1) {
        const n = if (l == 0) h.num_ref_idx_l0 else h.num_ref_idx_l1;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (r.flag()) {
                _ = r.se();
                _ = r.se();
            }
            if (chroma and r.flag()) {
                _ = r.se();
                _ = r.se();
                _ = r.se();
                _ = r.se();
            }
        }
    }
}

/// slice_header() (7.3.3) of slice NAL unit `nal`.
pub fn parseSlice(nal: []const u8, spss: *const [MAX_SPS]Sps, ppss: *const [MAX_PPS]Pps, out: *SliceHeader) Error!void {
    if (nal.len < 2) return error.Truncated;
    var r = Reader.init(nal[1..]);
    var h = SliceHeader{ .nal_type = nal[0] & 0x1f, .nal_ref_idc = @intCast((nal[0] >> 5) & 3), .first_mb = 0, .slice_type = 0, .pps_id = 0, .frame_num = 0 };
    h.first_mb = r.ue();
    const st = r.ue();
    if (st > 9) return error.Bad;
    h.slice_type = @intCast(st % 5);
    const pid = r.ue();
    if (pid >= MAX_PPS) return error.Bad;
    h.pps_id = @intCast(pid);
    const pps = &ppss[pid];
    if (!pps.valid) return error.NoParameterSet;
    const sps = &spss[pps.sps_id];
    if (!sps.valid) return error.NoParameterSet;
    if (sps.separate_colour_plane) _ = r.u(2);
    h.frame_num = r.u(sps.log2_max_frame_num);
    if (!sps.frame_mbs_only) {
        h.field_pic = r.flag();
        if (h.field_pic) h.bottom_field = r.flag();
    }
    if (h.isIdr()) h.idr_pic_id = r.ue();
    if (sps.poc_type == 0) {
        h.poc_lsb = r.u(sps.log2_max_poc_lsb);
        if (pps.bottom_field_pic_order_in_frame_present and !h.field_pic) h.delta_poc_bottom = r.se();
    } else if (sps.poc_type == 1 and !sps.delta_pic_order_always_zero) {
        h.delta_poc[0] = r.se();
        if (pps.bottom_field_pic_order_in_frame_present and !h.field_pic) h.delta_poc[1] = r.se();
    }
    if (pps.redundant_pic_cnt_present) h.redundant_pic_cnt = r.ue();
    if (h.isB()) h.direct_spatial_mv_pred = r.flag();
    h.num_ref_idx_l0 = pps.num_ref_idx_l0_default;
    h.num_ref_idx_l1 = pps.num_ref_idx_l1_default;
    if (h.isP() or h.isB()) {
        if (r.flag()) { // num_ref_idx_active_override_flag
            const a = r.ue() + 1;
            if (a > 32) return error.Bad;
            h.num_ref_idx_l0 = @intCast(a);
            if (h.isB()) {
                const b = r.ue() + 1;
                if (b > 32) return error.Bad;
                h.num_ref_idx_l1 = @intCast(b);
            }
        }
    }
    if (!h.isB()) h.num_ref_idx_l1 = 0;
    if (h.isI()) h.num_ref_idx_l0 = 0;
    if (h.nal_type == 20 or h.nal_type == 21) return error.Unsupported;
    if (!h.isI()) skipRefPicListModification(&r);
    if (h.isB()) skipRefPicListModification(&r);
    if ((pps.weighted_pred and h.isP()) or (pps.weighted_bipred_idc == 1 and h.isB())) skipPredWeightTable(&r, sps, &h);
    if (h.nal_ref_idc != 0) {
        if (h.isIdr()) {
            h.no_output_of_prior_pics = r.flag();
            h.long_term_reference = r.flag();
        } else {
            h.adaptive = r.flag();
            if (h.adaptive) {
                while (!r.bad) {
                    const op = r.ue();
                    if (op == 0) break;
                    if (op > 6 or h.mmco_count >= h.mmco.len) return error.Bad;
                    var m = MmcoOp{ .op = @intCast(op) };
                    if (op == 1 or op == 3) m.a = r.ue(); // difference_of_pic_nums_minus1
                    if (op == 2) m.a = r.ue(); // long_term_pic_num
                    if (op == 3 or op == 6) m.b = r.ue(); // long_term_frame_idx
                    if (op == 4) m.a = r.ue(); // max_long_term_frame_idx_plus1
                    h.mmco[h.mmco_count] = m;
                    h.mmco_count += 1;
                }
            }
        }
    }
    if (pps.entropy_coding_mode and !h.isI()) h.cabac_init_idc = @intCast(@min(r.ue(), 2));
    h.slice_qp_delta = @intCast(std.math.clamp(r.se(), -87, 77));
    if (h.slice_type == 3 or h.slice_type == 4) { // SP, SI
        if (h.slice_type == 3) _ = r.flag();
        _ = r.se();
    }
    if (pps.deblocking_filter_control_present) {
        const d = r.ue();
        if (d > 2) return error.Bad;
        h.disable_deblocking_filter_idc = @intCast(d);
        if (d != 1) {
            h.slice_alpha_c0_offset_div2 = @intCast(std.math.clamp(r.se(), -6, 6));
            h.slice_beta_offset_div2 = @intCast(std.math.clamp(r.se(), -6, 6));
        }
    }
    if (r.bad) return error.Truncated;
    h.bits = @intCast(8 + r.pos * 8 + r.bit);
    out.* = h;
}

// ── The decoded picture buffer ───────────────────────────────────────────────

/// One picture the DPB holds (a frame: this module marks frames only).
pub const Pic = struct {
    used: bool = false,
    /// the app's handle for the picture's storage (a VA surface)
    surface: u32 = 0,
    frame_num: u32 = 0,
    frame_num_wrap: i32 = 0,
    long_term_frame_idx: u32 = 0,
    top_poc: i32 = 0,
    bottom_poc: i32 = 0,
    short_ref: bool = false,
    long_ref: bool = false,
    /// waiting to be output (display order)
    needed_for_output: bool = false,
    /// the app's timestamp for it
    pts: i64 = 0,
    duration: i64 = 0,
    /// counted when output, to keep output order among equal POCs
    serial: u64 = 0,

    pub fn poc(p: *const Pic) i32 {
        return @min(p.top_poc, p.bottom_poc);
    }
    pub fn isRef(p: *const Pic) bool {
        return p.short_ref or p.long_ref;
    }
};

/// One picture's VA buffers, ready for Begin/Render/EndPicture.
pub const Picture = struct {
    pic: va.PictureParameterBufferH264 = std.mem.zeroes(va.PictureParameterBufferH264),
    iq: va.IQMatrixBufferH264 = std.mem.zeroes(va.IQMatrixBufferH264),
    slices: [MAX_SLICES]va.SliceParameterBufferH264 = undefined,
    /// each slice's NAL unit (header included, no start code), in the
    /// caller's access unit
    data: [MAX_SLICES][]const u8 = undefined,
    count: u32 = 0,
    /// the surface it decodes into (the caller's, from `begin`)
    surface: u32 = 0,
    /// the visible rectangle and the coded size
    visible: [4]u32 = .{ 0, 0, 0, 0 },
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 8,
    profile_idc: u8 = 0,
    /// pictures the DPB will hold at most (frames, the reference ones and
    /// those waiting for output): the surfaces a decoder needs
    dpb_frames: u32 = 0,
    /// the first slice's header (what `finish` marks by)
    first: SliceHeader = undefined,
};

/// What a decoder keeps across access units.
pub const State = struct {
    sps: [MAX_SPS]Sps = [_]Sps{.{}} ** MAX_SPS,
    pps: [MAX_PPS]Pps = [_]Pps{.{}} ** MAX_PPS,
    dpb: [MAX_DPB + 1]Pic = [_]Pic{.{}} ** (MAX_DPB + 1),
    /// the current picture's slot in dpb, while one is being decoded
    cur: ?usize = null,
    // POC state (8.2.1)
    prev_poc_msb: i32 = 0,
    prev_poc_lsb: u32 = 0,
    prev_frame_num_offset: i32 = 0,
    prev_frame_num: u32 = 0,
    prev_ref_has_mmco5: bool = false,
    prev_ref_was_bottom: bool = false,
    prev_top_poc_mmco5: i32 = 0,
    max_long_term_frame_idx: i32 = -1, // "no long-term frame indices"
    active_sps: ?u8 = null,
    serial: u64 = 0,
    /// a sequence change (new size, depth or DPB): the caller makes new
    /// surfaces before the next picture
    changed: bool = false,
    have_idr: bool = false,

    pub fn activeSps(st: *const State) ?*const Sps {
        const id = st.active_sps orelse return null;
        return &st.sps[id];
    }

    fn beginPicture(st: *State, h: *const SliceHeader, pts: i64, duration: i64, cb: Callbacks, out: *Picture) Error!void {
        return beginPictureImpl(st, h, pts, duration, cb, out);
    }

    fn initialLists(st: *const State, h: *const SliceHeader, s: *va.SliceParameterBufferH264) void {
        initialListsImpl(st, h, s);
    }
};

/// What `decode` asks of its caller: a surface for the new picture (null:
/// none free), and what to do with a picture leaving the DPB in display
/// order (output it: the caller reads the surface, then may reuse it once
/// `released` says so).
pub const Callbacks = struct {
    ctx: *anyopaque,
    surface: *const fn (ctx: *anyopaque) ?u32,
    output: *const fn (ctx: *anyopaque, p: *const Pic) void,
    /// a surface no picture needs any more
    released: *const fn (ctx: *anyopaque, surface: u32) void,
};

/// Feeds one access unit's NAL units (parameter sets are taken, slices of
/// one picture gathered into `out`). Returns true when `out` holds a
/// picture to decode; the caller decodes it, then calls `finish`.
pub fn take(st: *State, au: []const u8, pts: i64, duration: i64, cb: Callbacks, out: *Picture) Error!bool {
    var it = NalIter.init(au);
    out.count = 0;
    var first: ?SliceHeader = null;
    while (it.next()) |nal| {
        if (nal.len < 1 or nal[0] & 0x80 != 0) continue;
        const t = nal[0] & 0x1f;
        switch (t) {
            NAL_SPS => {
                var s: Sps = .{};
                parseSps(nal, &s) catch |e| {
                    if (e == error.Truncated or e == error.Bad) continue;
                    return e;
                };
                if (st.active_sps) |a| if (a == s.id) {
                    const o = &st.sps[a];
                    if (o.mb_width != s.mb_width or o.map_height != s.map_height or o.bit_depth_luma != s.bit_depth_luma or o.chroma_format_idc != s.chroma_format_idc or o.dpbFrames() != s.dpbFrames() or o.frame_mbs_only != s.frame_mbs_only)
                        st.changed = true;
                };
                st.sps[s.id] = s;
            },
            NAL_PPS => {
                var p: Pps = .{};
                parsePps(nal, &st.sps, &p) catch |e| {
                    if (e == error.Truncated or e == error.Bad or e == error.NoParameterSet) continue;
                    return e;
                };
                st.pps[p.id] = p;
            },
            NAL_SLICE, NAL_IDR => {
                var h: SliceHeader = undefined;
                try parseSlice(nal, &st.sps, &st.pps, &h);
                if (h.redundant_pic_cnt > 0) continue;
                if (h.field_pic) return error.Field;
                if (first == null) {
                    first = h;
                    out.first = h;
                    try st.beginPicture(&h, pts, duration, cb, out);
                } else if (h.first_mb == 0) {
                    // (a second picture in the buffer: only one is taken)
                    break;
                }
                if (out.count >= MAX_SLICES) return error.Unsupported;
                out.slices[out.count] = sliceParams(st, &h, nal);
                out.data[out.count] = nal;
                out.count += 1;
            },
            NAL_DPA, 3, 4 => return error.Unsupported, // data partitioning
            else => {},
        }
    }
    return first != null and out.count > 0;
}

fn sliceParams(st: *const State, h: *const SliceHeader, nal: []const u8) va.SliceParameterBufferH264 {
    var s = std.mem.zeroes(va.SliceParameterBufferH264);
    s.slice_data_size = @intCast(nal.len);
    s.slice_data_offset = 0;
    s.slice_data_flag = 0; // VA_SLICE_DATA_FLAG_ALL
    s.slice_data_bit_offset = @intCast(h.bits);
    s.first_mb_in_slice = @intCast(h.first_mb);
    s.slice_type = h.slice_type;
    s.direct_spatial_mv_pred_flag = @intFromBool(h.direct_spatial_mv_pred);
    s.num_ref_idx_l0_active_minus1 = if (h.num_ref_idx_l0 > 0) h.num_ref_idx_l0 - 1 else 0;
    s.num_ref_idx_l1_active_minus1 = if (h.num_ref_idx_l1 > 0) h.num_ref_idx_l1 - 1 else 0;
    s.cabac_init_idc = h.cabac_init_idc;
    s.slice_qp_delta = h.slice_qp_delta;
    s.disable_deblocking_filter_idc = h.disable_deblocking_filter_idc;
    s.slice_alpha_c0_offset_div2 = h.slice_alpha_c0_offset_div2;
    s.slice_beta_offset_div2 = h.slice_beta_offset_div2;
    for (&s.RefPicList0) |*p| p.* = invalidPic();
    for (&s.RefPicList1) |*p| p.* = invalidPic();
    // (the initial lists, 8.2.4.2: for P by descending PicNum then long-term;
    // for B by POC around the current. NVDEC builds its own from the DPB and
    // the slice header; VA's lists are filled as a client's would be.)
    if (!h.isI()) st.initialLists(h, &s);
    return s;
}

fn invalidPic() va.PictureH264 {
    return .{ .picture_id = 0xffffffff, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
}

fn vaPic(p: *const Pic) va.PictureH264 {
    var flags: u32 = 0;
    if (p.long_ref) flags |= va.PICTURE_H264_LONG_TERM_REFERENCE else if (p.short_ref) flags |= va.PICTURE_H264_SHORT_TERM_REFERENCE;
    return .{
        .picture_id = p.surface,
        .frame_idx = if (p.long_ref) p.long_term_frame_idx else p.frame_num,
        .flags = flags,
        .TopFieldOrderCnt = p.top_poc,
        .BottomFieldOrderCnt = p.bottom_poc,
    };
}

fn lessThan(_: void, a: Key, b: Key) bool {
    return a.k < b.k;
}
const Key = struct { k: i64, i: u8 };

fn initialListsImpl(st: *const State, h: *const SliceHeader, s: *va.SliceParameterBufferH264) void {
    const cur = &st.dpb[st.cur.?];
    var short: [MAX_DPB + 1]Key = undefined;
    var long: [MAX_DPB + 1]Key = undefined;
    var ns: usize = 0;
    var nl: usize = 0;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or i == st.cur.?) continue;
        if (p.short_ref) {
            short[ns] = .{ .k = if (h.isB()) p.poc() else -@as(i64, p.frame_num_wrap), .i = @intCast(i) };
            ns += 1;
        } else if (p.long_ref) {
            long[nl] = .{ .k = p.long_term_frame_idx, .i = @intCast(i) };
            nl += 1;
        }
    }
    std.mem.sort(Key, short[0..ns], {}, lessThan);
    std.mem.sort(Key, long[0..nl], {}, lessThan);
    if (!h.isB()) {
        var k: usize = 0;
        for (short[0..ns]) |x| {
            if (k < 32) s.RefPicList0[k] = vaPic(&st.dpb[x.i]);
            k += 1;
        }
        for (long[0..nl]) |x| {
            if (k < 32) s.RefPicList0[k] = vaPic(&st.dpb[x.i]);
            k += 1;
        }
        return;
    }
    // B: list 0 = POC below the current (descending), then above (ascending);
    // list 1 the other way round; long-term after both.
    const cp = cur.poc();
    var l0: [MAX_DPB * 2 + 2]u8 = undefined;
    var l1: [MAX_DPB * 2 + 2]u8 = undefined;
    var n0: usize = 0;
    var n1: usize = 0;
    var j: usize = ns;
    while (j > 0) {
        j -= 1;
        if (short[j].k < cp) {
            l0[n0] = short[j].i;
            n0 += 1;
        }
    }
    for (short[0..ns]) |x| if (x.k > cp) {
        l0[n0] = x.i;
        n0 += 1;
        l1[n1] = x.i;
        n1 += 1;
    };
    j = ns;
    while (j > 0) {
        j -= 1;
        if (short[j].k < cp) {
            l1[n1] = short[j].i;
            n1 += 1;
        }
    }
    for (long[0..nl]) |x| {
        l0[n0] = x.i;
        n0 += 1;
        l1[n1] = x.i;
        n1 += 1;
    }
    // (8.2.4.2.3: list 1 equal to list 0 with more than one entry swaps its first two)
    if (n1 > 1 and std.mem.eql(u8, l0[0..n0], l1[0..n1])) std.mem.swap(u8, &l1[0], &l1[1]);
    for (l0[0..@min(n0, 32)], 0..) |x, k| s.RefPicList0[k] = vaPic(&st.dpb[x]);
    for (l1[0..@min(n1, 32)], 0..) |x, k| s.RefPicList1[k] = vaPic(&st.dpb[x]);
}

// (methods on State; written apart for reading)
fn beginPictureImpl(st: *State, h: *const SliceHeader, pts: i64, duration: i64, cb: Callbacks, out: *Picture) Error!void {
    const pps = &st.pps[h.pps_id];
    const sps_id = pps.sps_id;
    const sps = &st.sps[sps_id];
    if (sps.chroma_format_idc != 1 or sps.bit_depth_luma != 8 or sps.bit_depth_chroma != 8) return error.Unsupported;
    if (!sps.frame_mbs_only and !sps.mbaff) {} // (PAFF streams: frames refused per picture by field_pic)
    if (st.active_sps == null or st.active_sps.? != sps_id) {
        if (st.active_sps != null) st.changed = true;
        st.active_sps = sps_id;
    }
    if (!st.have_idr and !h.isIdr()) {
        // (a stream joined after its IDR: wait for a recovery point at an I picture)
        if (!h.isI()) return error.NoParameterSet;
    }

    // IDR: every reference let go; output all unless no_output_of_prior_pics
    if (h.isIdr()) {
        st.have_idr = true;
        for (&st.dpb) |*p| {
            if (!p.used) continue;
            p.short_ref = false;
            p.long_ref = false;
        }
        flushOutput(st, cb, !h.no_output_of_prior_pics);
        st.max_long_term_frame_idx = if (h.long_term_reference) 0 else -1;
    } else if (sps.gaps_allowed and h.frame_num != st.prev_frame_num and h.frame_num != (st.prev_frame_num + 1) % (@as(u32, 1) << sps.log2_max_frame_num)) {
        // (frame_num gap: the sliding window moves as non-existing frames would)
        var gaps: u32 = 0;
        var fn_ = (st.prev_frame_num + 1) % (@as(u32, 1) << sps.log2_max_frame_num);
        while (fn_ != h.frame_num and gaps < 32) : (gaps += 1) {
            slidingWindow(st, sps, cb);
            fn_ = (fn_ + 1) % (@as(u32, 1) << sps.log2_max_frame_num);
        }
    }

    // a slot for the picture: the DPB is bumped until one is free
    var slot: ?usize = null;
    while (slot == null) {
        for (&st.dpb, 0..) |*p, i| if (!p.used) {
            slot = i;
            break;
        };
        if (slot == null and !bump(st, cb, true)) return error.Bad;
    }
    const surface = cb.surface(cb.ctx) orelse return error.Bad;
    const cur = &st.dpb[slot.?];
    cur.* = .{ .used = true, .surface = surface, .frame_num = h.frame_num, .pts = pts, .duration = duration };
    st.cur = slot;

    computePoc(st, sps, h, cur);
    // FrameNumWrap of every short-term reference (8.2.4.1)
    const max_fn: i64 = @as(i64, 1) << sps.log2_max_frame_num;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or i == slot.? or !p.short_ref) continue;
        p.frame_num_wrap = if (p.frame_num > h.frame_num) @intCast(@as(i64, p.frame_num) - max_fn) else @intCast(p.frame_num);
    }

    // VA's picture parameters
    var pp = &out.pic;
    pp.* = std.mem.zeroes(va.PictureParameterBufferH264);
    pp.CurrPic = .{ .picture_id = surface, .frame_idx = h.frame_num, .flags = 0, .TopFieldOrderCnt = cur.top_poc, .BottomFieldOrderCnt = cur.bottom_poc };
    if (h.nal_ref_idc != 0) pp.CurrPic.flags |= if (h.long_term_reference) va.PICTURE_H264_LONG_TERM_REFERENCE else va.PICTURE_H264_SHORT_TERM_REFERENCE;
    var k: usize = 0;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or i == slot.? or !p.isRef()) continue;
        if (k < 16) pp.ReferenceFrames[k] = vaPic(p);
        k += 1;
    }
    while (k < 16) : (k += 1) pp.ReferenceFrames[k] = invalidPic();
    pp.picture_width_in_mbs_minus1 = @intCast(sps.mb_width - 1);
    pp.picture_height_in_mbs_minus1 = @intCast(sps.mbHeight() - 1);
    pp.bit_depth_luma_minus8 = sps.bit_depth_luma - 8;
    pp.bit_depth_chroma_minus8 = sps.bit_depth_chroma - 8;
    pp.num_ref_frames = sps.num_ref_frames;
    pp.seq_fields = .{
        .chroma_format_idc = sps.chroma_format_idc,
        .residual_colour_transform_flag = @intFromBool(sps.separate_colour_plane),
        .gaps_in_frame_num_value_allowed_flag = @intFromBool(sps.gaps_allowed),
        .frame_mbs_only_flag = @intFromBool(sps.frame_mbs_only),
        .mb_adaptive_frame_field_flag = @intFromBool(sps.mbaff),
        .direct_8x8_inference_flag = @intFromBool(sps.direct_8x8_inference),
        .MinLumaBiPredSize8x8 = @intFromBool(sps.level_idc >= 31),
        .log2_max_frame_num_minus4 = @intCast(sps.log2_max_frame_num - 4),
        .pic_order_cnt_type = sps.poc_type,
        .log2_max_pic_order_cnt_lsb_minus4 = if (sps.poc_type == 0) @intCast(sps.log2_max_poc_lsb - 4) else 0,
        .delta_pic_order_always_zero_flag = @intFromBool(sps.delta_pic_order_always_zero),
    };
    pp.num_slice_groups_minus1 = 0;
    pp.pic_init_qp_minus26 = pps.pic_init_qp_minus26;
    pp.pic_init_qs_minus26 = pps.pic_init_qs_minus26;
    pp.chroma_qp_index_offset = pps.chroma_qp_index_offset;
    pp.second_chroma_qp_index_offset = pps.second_chroma_qp_index_offset;
    pp.pic_fields = .{
        .entropy_coding_mode_flag = @intFromBool(pps.entropy_coding_mode),
        .weighted_pred_flag = @intFromBool(pps.weighted_pred),
        .weighted_bipred_idc = pps.weighted_bipred_idc,
        .transform_8x8_mode_flag = @intFromBool(pps.transform_8x8_mode),
        .field_pic_flag = 0,
        .constrained_intra_pred_flag = @intFromBool(pps.constrained_intra_pred),
        .pic_order_present_flag = @intFromBool(pps.bottom_field_pic_order_in_frame_present),
        .deblocking_filter_control_present_flag = @intFromBool(pps.deblocking_filter_control_present),
        .redundant_pic_cnt_present_flag = @intFromBool(pps.redundant_pic_cnt_present),
        .reference_pic_flag = @intFromBool(h.nal_ref_idc != 0),
    };
    pp.frame_num = @intCast(h.frame_num);
    // the scaling lists, as FFmpeg's vaapi_h264 gives them: bitstream order,
    // the 8x8 lists Y intra and Y inter
    out.iq.ScalingList4x4 = pps.scaling.l4;
    out.iq.ScalingList8x8 = .{ pps.scaling.l8[0], pps.scaling.l8[1] };
    out.surface = surface;
    out.visible = sps.visible();
    out.width = sps.width();
    out.height = sps.height();
    out.bit_depth = sps.bit_depth_luma;
    out.profile_idc = sps.profile_idc;
    out.dpb_frames = sps.dpbFrames();
}

/// 8.2.1: the picture's TopFieldOrderCnt and BottomFieldOrderCnt (frames).
fn computePoc(st: *State, sps: *const Sps, h: *const SliceHeader, cur: *Pic) void {
    const max_fn: i32 = @as(i32, 1) << sps.log2_max_frame_num;
    switch (sps.poc_type) {
        0 => {
            if (h.isIdr()) {
                st.prev_poc_msb = 0;
                st.prev_poc_lsb = 0;
            } else if (st.prev_ref_has_mmco5) {
                st.prev_poc_msb = 0;
                st.prev_poc_lsb = if (st.prev_ref_was_bottom) 0 else @intCast(@max(st.prev_top_poc_mmco5, 0));
            }
            const max_lsb: i32 = @as(i32, 1) << sps.log2_max_poc_lsb;
            const lsb: i32 = @intCast(h.poc_lsb);
            const plsb: i32 = @intCast(st.prev_poc_lsb);
            var msb: i32 = st.prev_poc_msb;
            if (lsb < plsb and plsb - lsb >= @divTrunc(max_lsb, 2)) {
                msb = st.prev_poc_msb + max_lsb;
            } else if (lsb > plsb and lsb - plsb > @divTrunc(max_lsb, 2)) {
                msb = st.prev_poc_msb - max_lsb;
            }
            cur.top_poc = msb + lsb;
            cur.bottom_poc = cur.top_poc + h.delta_poc_bottom;
            if (h.nal_ref_idc != 0) {
                st.prev_poc_msb = msb;
                st.prev_poc_lsb = h.poc_lsb;
            }
        },
        1 => {
            var offset: i32 = 0;
            if (h.isIdr()) offset = 0 else if (st.prev_frame_num > h.frame_num) offset = st.prev_frame_num_offset + max_fn else offset = st.prev_frame_num_offset;
            if (st.prev_ref_has_mmco5 and !h.isIdr()) {
                offset = if (st.prev_frame_num > h.frame_num) max_fn else 0;
            }
            var abs: i32 = if (sps.num_ref_frames_in_poc_cycle != 0) offset + @as(i32, @intCast(h.frame_num)) else 0;
            if (h.nal_ref_idc == 0 and abs > 0) abs -= 1;
            var expected: i32 = 0;
            if (abs > 0) {
                const n: i32 = sps.num_ref_frames_in_poc_cycle;
                var delta_cycle: i32 = 0;
                for (sps.offset_for_ref_frame[0..sps.num_ref_frames_in_poc_cycle]) |o| delta_cycle += o;
                const cycle = @divTrunc(abs - 1, n);
                const in_cycle: usize = @intCast(@mod(abs - 1, n));
                expected = cycle * delta_cycle;
                for (sps.offset_for_ref_frame[0 .. in_cycle + 1]) |o| expected += o;
            }
            if (h.nal_ref_idc == 0) expected += sps.offset_for_non_ref_pic;
            cur.top_poc = expected + h.delta_poc[0];
            cur.bottom_poc = cur.top_poc + sps.offset_for_top_to_bottom_field + h.delta_poc[1];
            st.prev_frame_num_offset = offset;
        },
        2 => {
            var offset: i32 = 0;
            if (h.isIdr()) offset = 0 else if (st.prev_frame_num > h.frame_num) offset = st.prev_frame_num_offset + max_fn else offset = st.prev_frame_num_offset;
            if (st.prev_ref_has_mmco5 and !h.isIdr()) {
                offset = if (st.prev_frame_num > h.frame_num) max_fn else 0;
            }
            var t: i32 = 0;
            if (!h.isIdr()) {
                t = 2 * (offset + @as(i32, @intCast(h.frame_num)));
                if (h.nal_ref_idc == 0) t -= 1;
            }
            cur.top_poc = t;
            cur.bottom_poc = t;
            st.prev_frame_num_offset = offset;
        },
        3 => unreachable,
    }
}

/// Once the picture is submitted: its reference marking (8.2.5), its place
/// in the output queue, and the bumping it causes.
fn finishPictureImpl(st: *State, h0: *const SliceHeader, cb: Callbacks) void {
    const slot = st.cur orelse return;
    st.cur = null;
    const cur = &st.dpb[slot];
    const sps = &st.sps[st.active_sps.?];
    var had_mmco5 = false;
    if (h0.nal_ref_idc != 0) {
        if (h0.isIdr()) {
            if (h0.long_term_reference) {
                cur.long_ref = true;
                cur.long_term_frame_idx = 0;
            } else cur.short_ref = true;
        } else if (h0.adaptive) {
            for (h0.mmco[0..h0.mmco_count]) |m| {
                if (m.op == 5) had_mmco5 = true;
                mmco(st, sps, h0, cur, m, cb);
            }
            if (!cur.long_ref) cur.short_ref = true;
        } else {
            slidingWindow(st, sps, cb);
            cur.short_ref = true;
        }
    }
    if (had_mmco5) {
        // (8.2.1: after memory_management_control_operation 5 the picture
        // counts as POC 0 and frame_num 0)
        const t = cur.top_poc - cur.poc();
        const b = cur.bottom_poc - cur.poc();
        cur.top_poc = t;
        cur.bottom_poc = b;
        cur.frame_num = 0;
        st.prev_top_poc_mmco5 = cur.top_poc;
        flushOutput(st, cb, true);
    }
    if (h0.nal_ref_idc != 0) {
        st.prev_ref_has_mmco5 = had_mmco5;
        st.prev_ref_was_bottom = false;
    }
    st.prev_frame_num = if (had_mmco5) 0 else h0.frame_num;
    if (had_mmco5) st.prev_frame_num_offset = 0;

    cur.needed_for_output = true;
    st.serial += 1;
    cur.serial = st.serial;
    // C.4.5.3: bump while more pictures wait than the stream may reorder
    // (or the DPB is over full)
    const depth = sps.reorderDepth();
    while (true) {
        var waiting: u32 = 0;
        var used: u32 = 0;
        for (&st.dpb) |*p| {
            if (!p.used) continue;
            used += 1;
            if (p.needed_for_output) waiting += 1;
        }
        if (waiting > depth or used > sps.dpbFrames()) {
            if (!bump(st, cb, false)) break;
        } else break;
    }
}

/// Outputs the waiting picture of the lowest POC; frees its slot when it
/// is no reference. Returns false when none waits (or, with `need_slot`,
/// none could be freed).
fn bump(st: *State, cb: Callbacks, need_slot: bool) bool {
    var best: ?usize = null;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or !p.needed_for_output) continue;
        if (st.cur != null and i == st.cur.?) continue;
        if (best == null or p.poc() < st.dpb[best.?].poc() or (p.poc() == st.dpb[best.?].poc() and p.serial < st.dpb[best.?].serial)) best = i;
    }
    if (best) |b| {
        const p = &st.dpb[b];
        p.needed_for_output = false;
        cb.output(cb.ctx, p);
        if (!p.isRef()) {
            cb.released(cb.ctx, p.surface);
            p.used = false;
        }
        return true;
    }
    if (need_slot) {
        // (a DPB full of references nobody marked unused: the oldest goes, as
        // a broken stream would need)
        var oldest: ?usize = null;
        for (&st.dpb, 0..) |*p, i| {
            if (!p.used or (st.cur != null and i == st.cur.?)) continue;
            if (oldest == null or p.frame_num_wrap < st.dpb[oldest.?].frame_num_wrap) oldest = i;
        }
        if (oldest) |o| {
            st.dpb[o].short_ref = false;
            st.dpb[o].long_ref = false;
            cb.released(cb.ctx, st.dpb[o].surface);
            st.dpb[o].used = false;
            return true;
        }
    }
    return false;
}

/// Every waiting picture out in display order (`output`: else dropped);
/// slots with no reference freed.
fn flushOutput(st: *State, cb: Callbacks, output: bool) void {
    if (output) {
        while (bump(st, cb, false)) {}
    }
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or (st.cur != null and i == st.cur.?)) continue;
        p.needed_for_output = false;
        if (!p.isRef()) {
            cb.released(cb.ctx, p.surface);
            p.used = false;
        }
    }
}

/// A reference picture's marking undone; its slot freed when it was
/// already output.
fn unmark(st: *State, p: *Pic, cb: Callbacks) void {
    _ = st;
    p.short_ref = false;
    p.long_ref = false;
    if (!p.needed_for_output) {
        cb.released(cb.ctx, p.surface);
        p.used = false;
    }
}

/// 8.2.5.3.
fn slidingWindow(st: *State, sps: *const Sps, cb: Callbacks) void {
    var n: u32 = 0;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or (st.cur != null and i == st.cur.?)) continue;
        if (p.isRef()) n += 1;
    }
    const limit = @max(@as(u32, sps.num_ref_frames), 1);
    while (n >= limit) : (n -= 1) {
        var oldest: ?usize = null;
        for (&st.dpb, 0..) |*p, i| {
            if (!p.used or !p.short_ref or (st.cur != null and i == st.cur.?)) continue;
            if (oldest == null or p.frame_num_wrap < st.dpb[oldest.?].frame_num_wrap) oldest = i;
        }
        const o = oldest orelse break;
        unmark(st, &st.dpb[o], cb);
    }
}

fn picNumOf(p: *const Pic) i32 {
    return p.frame_num_wrap;
}

/// One memory_management_control_operation (8.2.5.4), for a frame.
fn mmco(st: *State, sps: *const Sps, h: *const SliceHeader, cur: *Pic, m: MmcoOp, cb: Callbacks) void {
    _ = sps;
    const curr_pic_num: i32 = @intCast(h.frame_num);
    switch (m.op) {
        1 => {
            const pn = curr_pic_num - @as(i32, @intCast(m.a + 1));
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.short_ref and picNumOf(p) == pn) {
                    unmark(st, p, cb);
                    break;
                }
            }
        },
        2 => {
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.long_ref and p.long_term_frame_idx == m.a) {
                    unmark(st, p, cb);
                    break;
                }
            }
        },
        3 => {
            const pn = curr_pic_num - @as(i32, @intCast(m.a + 1));
            // the long-term index's holder let go first
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.long_ref and p.long_term_frame_idx == m.b and !(p.short_ref and picNumOf(p) == pn)) {
                    unmark(st, p, cb);
                }
            }
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.short_ref and picNumOf(p) == pn) {
                    p.short_ref = false;
                    p.long_ref = true;
                    p.long_term_frame_idx = m.b;
                    break;
                }
            }
        },
        4 => {
            st.max_long_term_frame_idx = @as(i32, @intCast(m.a)) - 1;
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.long_ref and @as(i32, @intCast(p.long_term_frame_idx)) > st.max_long_term_frame_idx) unmark(st, p, cb);
            }
        },
        5 => {
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.isRef()) unmark(st, p, cb);
            }
            st.max_long_term_frame_idx = -1;
        },
        6 => {
            for (&st.dpb) |*p| {
                if (p.used and p != cur and p.long_ref and p.long_term_frame_idx == m.b) unmark(st, p, cb);
            }
            cur.long_ref = true;
            cur.short_ref = false;
            cur.long_term_frame_idx = m.b;
        },
        else => {},
    }
}

// ── The State's interface ───────────────────────────────────────────────────

/// The picture `take` returned has been submitted: its marking and output.
pub fn finish(st: *State, p: *const Picture, cb: Callbacks) void {
    finishPictureImpl(st, &p.first, cb);
}

/// The picture `take` returned could not be decoded: its slot freed.
pub fn abandon(st: *State, cb: Callbacks) void {
    const slot = st.cur orelse return;
    cb.released(cb.ctx, st.dpb[slot].surface);
    st.dpb[slot].used = false;
    st.cur = null;
}

/// End of stream: every waiting picture out.
pub fn drain(st: *State, cb: Callbacks) void {
    flushOutput(st, cb, true);
}

/// A seek: every picture dropped, references too, until the next IDR.
pub fn reset(st: *State, cb: Callbacks) void {
    for (&st.dpb) |*p| {
        if (!p.used) continue;
        cb.released(cb.ctx, p.surface);
        p.* = .{};
    }
    st.cur = null;
    st.prev_poc_msb = 0;
    st.prev_poc_lsb = 0;
    st.prev_frame_num_offset = 0;
    st.prev_frame_num = 0;
    st.prev_ref_has_mmco5 = false;
    st.have_idr = false;
}


/// (h264_stream_test: an SPS's lists alone, rule A)
pub fn testReadScaling(r: *Reader, s: *Scaling) void {
    readScaling(r, 2, null, s);
}
