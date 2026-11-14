//! @zpm/va enc_av1 — AV1 encoding's halves that are not the engine's: the
//! OBUs the driver writes (temporal delimiter, sequence header, frame
//! header, the tile group's header, padding) and the engine's picture
//! setup (nvenc_av1_drv_pic_setup_s, its MD and ME controls, one tile
//! control), from VA's AV1 parameters (va_enc_av1.h) as FFmpeg's av1_vaapi
//! fills them.
//!
//! The stream of one picture, in the coded buffer (encode.sig's layout):
//!
//!   [OBU_TEMPORAL_DELIMITER]   when this picture starts a temporal unit
//!                              (the last one was shown)
//!   [OBU_SEQUENCE_HEADER]      the app's packed one, or the driver's, at a
//!                              key frame
//!   [the app's metadata OBUs]  (packed misc / raw data)
//!   OBU_FRAME_HEADER           the driver's, `fh_room` bytes: written at
//!                              EndPicture, rewritten when the engine is
//!                              done if its status reports another QP or
//!                              loop-filter level (nvenc_av1_pic_stat_s:
//!                              "to be inserted into frame header by
//!                              driver"); zero bytes after the trailing
//!                              bits fill the room (AV1 5.3.4)
//!   OBU_TILE_GROUP header      one tile: no tile fields; its size a
//!                              4-byte leb128 patched when done
//!   the engine's tile data     from bitstream_start_pos (ASSUMED: the
//!                              engine writes the tile's data alone, no
//!                              OBU around it)
//!   [OBU_FRAME_HEADER show_existing_frame]  (see below)
//!   [OBU_PADDING]              CBR's filler
//!
//! The app's packed picture header (FFmpeg packs its own frame header) is
//! read for show_frame and showable_frame only: the driver writes the
//! frame header itself, from the same VA parameters and the QP the rate
//! control chose, so the two never disagree. Without packed picture
//! headers a picture whose order hint runs ahead of the next one to show
//! is hidden, and shown later with a show_existing_frame header after the
//! picture before it.
//!
//! The engine's CDFs: a picture reads its primary reference's adapted
//! CDFs (kept per reference surface: SET_OUT_AV1_PROBABILITY_DATA wrote
//! them) or the defaults for its quantiser's context (av1_cdf.sig's
//! tables, in NVDEC's layout: ASSUMED NVENC's too, the same entropy
//! block's tables on the same chip). The line buffers' sizes are not
//! public: generous ones are given (ASSUMED).
//!
//! Main profile, 8-bit 4:2:0, one tile (up to 4096 wide and 2304 x 4096
//! in area: AV1's largest tile), 64x64 superblocks, no segmentation,
//! superres, intra block copy, palette, warped motion or film grain;
//! inter pictures with up to MAX_L0 references forward and MAX_L1
//! backward (compound prediction). The engine's minimum is 192x128
//! (nvenc_drv.h: frame_width_minus1 191..8191, height 127..8191).
//!
//! Pure: no calls, no state.

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const nvenc = @import("nvenc.sig");
const bits = @import("bits.sig");
const h264 = @import("enc_h264.sig");
const enc_rc = @import("enc_rc.sig");
const cdf = @import("av1_cdf.sig");

const A = nvenc.Av1;

pub const PROFILE: va.Profile = 32; // VAProfileAV1Profile0
pub const Seq = ve.EncSequenceParameterBufferAV1;
pub const Pic = ve.EncPictureParameterBufferAV1;

pub const MIN_WIDTH = 192;
pub const MIN_HEIGHT = 128;
pub const MAX_L0 = 4;
pub const MAX_L1 = 3;
pub const NONE: u3 = 7; // PRIMARY_REF_NONE

/// VAConfigAttribEncAV1: CDEF strengths per channel (1); nothing else.
pub const ATTRIB: u32 = 1 << 26;
/// VAConfigAttribEncAV1Ext1: EIGHTTAP only.
pub const ATTRIB_EXT1: u32 = 1;
/// VAConfigAttribEncAV1Ext2: tile sizes and OBU sizes in 4 bytes, the
/// transform modes LARGEST and SELECT, one tile.
pub const ATTRIB_EXT2: u32 = 3 | (3 << 2) | (6 << 4);
/// The packed headers taken: sequence (the app's SH), picture (read for
/// show_frame only), misc and raw (metadata OBUs).
pub const PACKED_HEADERS: u32 = ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_PICTURE | ve.PACKED_HEADER_MISC | ve.PACKED_HEADER_RAW_DATA;

pub const OBU_SEQUENCE_HEADER = 1;
pub const OBU_TEMPORAL_DELIMITER = 2;
pub const OBU_FRAME_HEADER = 3;
pub const OBU_TILE_GROUP = 4;
pub const OBU_METADATA = 5;
pub const OBU_FRAME = 6;
pub const OBU_PADDING = 15;

/// An OBU header with obu_has_size_field.
pub fn obuHeader(t: u4) u8 {
    return (@as(u8, t) << 3) | 2;
}

/// `v` as a leb128 of exactly 4 bytes (AV1 4.10.5 allows the longer form).
pub fn leb128Fixed(out: []u8, v: u32) void {
    out[0] = @as(u8, @truncate(v & 0x7f)) | 0x80;
    out[1] = @as(u8, @truncate((v >> 7) & 0x7f)) | 0x80;
    out[2] = @as(u8, @truncate((v >> 14) & 0x7f)) | 0x80;
    out[3] = @truncate((v >> 21) & 0x7f);
}

// ── What a frame is ─────────────────────────────────────────────────────────

pub const Size = struct {
    width: u32,
    height: u32,
    sb_cols: u32,
    sb_rows: u32,

    pub fn of(width: u32, height: u32) Size {
        const mi_cols = 2 * ((width + 7) >> 3);
        const mi_rows = 2 * ((height + 7) >> 3);
        return .{ .width = width, .height = height, .sb_cols = (mi_cols + 15) >> 4, .sb_rows = (mi_rows + 15) >> 4 };
    }
};

fn tileLog2(blk: u32, target: u32) u32 {
    var k: u5 = 0;
    while ((blk << k) < target) k += 1;
    return k;
}

/// Everything the frame header (and the setup) says.
pub const Frame = struct {
    size: Size,
    frame_type: u2,
    show_frame: bool = true,
    showable_frame: bool = false,
    error_resilient: bool = false,
    disable_cdf_update: bool = false,
    disable_frame_end_update_cdf: bool = false,
    order_hint_bits: u4 = 8,
    enable_order_hint: bool = true,
    enable_cdef: bool = false,
    enable_restoration: bool = false,
    order_hint: u8 = 0,
    primary_ref_frame: u3 = NONE,
    refresh: u8 = 0xff,
    ref_frame_idx: [7]u3 = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// RefOrderHint of each slot (before this frame's refresh)
    slot_hint: [8]u8 = .{0} ** 8,
    qindex: u8 = 128,
    /// loop_filter_level[0..3]: luma vertical, horizontal, U, V
    lf: [4]u6 = .{ 0, 0, 0, 0 },
    sharpness: u3 = 0,
    lf_delta_enabled: bool = true,
    lf_delta_update: bool = false,
    ref_deltas: [8]i8 = DEFAULT_REF_DELTAS,
    mode_deltas: [2]i8 = .{ 0, 0 },
    cdef_damping_minus_3: u2 = 2,
    cdef_bits: u2 = 2,
    /// (primary << 2) | secondary, as nvenc_av1_cdef_cfg_s and VA give them
    cdef_y: [8]u6 = .{0} ** 8,
    cdef_uv: [8]u6 = .{0} ** 8,
    tx_mode_select: bool = true,
    reference_select: bool = false,
    reduced_tx_set: bool = false,

    pub fn intra(f: Frame) bool {
        return f.frame_type == 0 or f.frame_type == 2;
    }
};

pub const DEFAULT_REF_DELTAS = [8]i8{ 1, 0, 0, 0, -1, 0, -1, -1 };

fn relDist(f: Frame, a: u8, b: u8) i32 {
    if (!f.enable_order_hint) return 0;
    const diff: i32 = @as(i32, a) - @as(i32, b);
    const m: i32 = @as(i32, 1) << @intCast(f.order_hint_bits - 1);
    return (diff & (m - 1)) - (diff & m);
}

/// skip_mode_params()'s skipModeAllowed (5.9.22).
fn skipModeAllowed(f: Frame) bool {
    if (f.intra() or !f.reference_select or !f.enable_order_hint) return false;
    var fwd: i32 = -1;
    var bwd: i32 = -1;
    var fwd_hint: u8 = 0;
    var bwd_hint: u8 = 0;
    for (f.ref_frame_idx, 0..) |idx, i| {
        const h = f.slot_hint[idx];
        if (relDist(f, h, f.order_hint) < 0) {
            if (fwd < 0 or relDist(f, h, fwd_hint) > 0) {
                fwd = @intCast(i);
                fwd_hint = h;
            }
        } else if (relDist(f, h, f.order_hint) > 0) {
            if (bwd < 0 or relDist(f, h, bwd_hint) < 0) {
                bwd = @intCast(i);
                bwd_hint = h;
            }
        }
    }
    if (fwd < 0) return false;
    if (bwd >= 0) return true;
    for (f.ref_frame_idx) |idx| {
        const h = f.slot_hint[idx];
        if (relDist(f, h, fwd_hint) < 0) return true;
    }
    return false;
}

fn deltaQ(w: *bits.Writer, v: i8) void {
    w.flag(v != 0);
    if (v != 0) su(w, 7, v);
}

/// su(n): n bits, two's complement.
fn su(w: *bits.Writer, n: u6, v: i32) void {
    const mask: u32 = (@as(u32, 1) << @intCast(n)) - 1;
    w.u(n, @as(u32, @bitCast(v)) & mask);
}

/// uncompressed_header() of `f` (no show_existing_frame), byte aligned
/// by its trailing bits.
pub fn writeFrameHeader(w: *bits.Writer, f: Frame) void {
    const key_shown = f.frame_type == 0 and f.show_frame;
    const intra = f.intra();
    w.flag(false); // show_existing_frame
    w.u(2, f.frame_type);
    w.flag(f.show_frame);
    if (!f.show_frame) w.flag(f.showable_frame);
    const er = f.frame_type == 3 or key_shown or f.error_resilient;
    if (!(f.frame_type == 3 or key_shown)) w.flag(f.error_resilient);
    w.flag(f.disable_cdf_update);
    // (allow_screen_content_tools 0: the sequence forces it off)
    w.flag(false); // frame_size_override_flag
    if (f.enable_order_hint) w.u(f.order_hint_bits, f.order_hint);
    if (!(intra or er)) w.u(3, f.primary_ref_frame);
    if (!(f.frame_type == 3 or key_shown)) w.u(8, f.refresh);
    if (!intra or f.refresh != 0xff) {
        if (er and f.enable_order_hint) {
            for (f.slot_hint) |h| w.u(f.order_hint_bits, h);
        }
    }
    if (intra) {
        // frame_size(), superres_params(): nothing; render_size()
        w.flag(false); // render_and_frame_size_different
    } else {
        if (f.enable_order_hint) w.flag(false); // frame_refs_short_signaling
        for (f.ref_frame_idx) |i| w.u(3, i);
        w.flag(false); // render_and_frame_size_different
        w.flag(false); // allow_high_precision_mv
        w.flag(false); // is_filter_switchable
        w.u(2, 0); // interpolation_filter: EIGHTTAP
        w.flag(false); // is_motion_mode_switchable
    }
    if (!f.disable_cdf_update) w.flag(f.disable_frame_end_update_cdf);
    // tile_info(): uniform, the fewest tiles (one)
    const sb_cols = f.size.sb_cols;
    const sb_rows = f.size.sb_rows;
    w.flag(true); // uniform_tile_spacing_flag
    const max_log2_cols = tileLog2(1, @min(sb_cols, 64));
    const max_log2_rows = tileLog2(1, @min(sb_rows, 64));
    if (0 < max_log2_cols) w.flag(false); // increment_tile_cols_log2
    if (0 < max_log2_rows) w.flag(false); // increment_tile_rows_log2
    // quantization_params()
    w.u(8, f.qindex);
    deltaQ(w, 0); // DeltaQYDc
    deltaQ(w, 0); // DeltaQUDc
    deltaQ(w, 0); // DeltaQUAc
    w.flag(false); // using_qmatrix
    w.flag(false); // segmentation_enabled
    if (f.qindex > 0) w.flag(false); // delta_q_present
    // loop_filter_params() (qindex > 0: not lossless)
    w.u(6, f.lf[0]);
    w.u(6, f.lf[1]);
    if (f.lf[0] != 0 or f.lf[1] != 0) {
        w.u(6, f.lf[2]);
        w.u(6, f.lf[3]);
    }
    w.u(3, f.sharpness);
    w.flag(f.lf_delta_enabled);
    if (f.lf_delta_enabled) {
        w.flag(f.lf_delta_update);
        if (f.lf_delta_update) {
            for (f.ref_deltas) |d| {
                w.flag(true);
                su(w, 7, d);
            }
            for (f.mode_deltas) |d| {
                w.flag(true);
                su(w, 7, d);
            }
        }
    }
    // cdef_params()
    if (f.enable_cdef) {
        w.u(2, f.cdef_damping_minus_3);
        w.u(2, f.cdef_bits);
        for (0..@as(usize, 1) << f.cdef_bits) |i| {
            w.u(4, f.cdef_y[i] >> 2);
            w.u(2, f.cdef_y[i] & 3);
            w.u(4, f.cdef_uv[i] >> 2);
            w.u(2, f.cdef_uv[i] & 3);
        }
    }
    // lr_params(): restoration is off in the sequence
    w.flag(f.tx_mode_select); // tx_mode_select
    if (!intra) w.flag(f.reference_select);
    if (skipModeAllowed(f)) w.flag(false); // skip_mode_present
    // (allow_warped_motion: off in the sequence)
    w.flag(f.reduced_tx_set);
    if (!intra) {
        for (0..7) |_| w.flag(false); // is_global
    }
    // (film grain: off in the sequence)
}

/// A frame header OBU of `f` into `out`, its payload padded with zeros to
/// `room` bytes (0: no padding): its length, or null when it does not fit.
pub fn frameHeaderObu(out: []u8, f: Frame, room: usize) ?usize {
    var payload: [256]u8 = undefined;
    var w = bits.Writer.init(&payload);
    writeFrameHeader(&w, f);
    w.trailing();
    if (w.overflow) return null;
    const n = w.bytes().len;
    const size = @max(n, room);
    if (out.len < 5 + size) return null;
    out[0] = obuHeader(OBU_FRAME_HEADER);
    leb128Fixed(out[1..5], @intCast(size));
    @memcpy(out[5..][0..n], w.bytes());
    @memset(out[5 + n ..][0 .. size - n], 0);
    return 5 + size;
}

/// A frame header OBU showing slot `slot` (show_existing_frame).
pub fn showExistingObu(out: []u8, slot: u3) usize {
    out[0] = obuHeader(OBU_FRAME_HEADER);
    out[1] = 1;
    // show_existing_frame 1, frame_to_show_map_idx (3), trailing 1, zeros
    out[2] = 0x80 | (@as(u8, slot) << 4) | 0x08;
    return 3;
}

/// The temporal delimiter.
pub fn temporalDelimiter(out: []u8) usize {
    out[0] = obuHeader(OBU_TEMPORAL_DELIMITER);
    out[1] = 0;
    return 2;
}

/// sequence_header_obu() from VA's sequence parameters (the picture's
/// `width` x `height`), as an OBU.
pub fn sequenceHeaderObu(out: []u8, seq: *const Seq, width: u32, height: u32) ?usize {
    var payload: [64]u8 = undefined;
    var w = bits.Writer.init(&payload);
    const sf = seq.seq_fields;
    w.u(3, 0); // seq_profile: Main
    w.flag(sf.still_picture != 0);
    w.flag(false); // reduced_still_picture_header
    w.flag(false); // timing_info_present_flag
    w.flag(false); // initial_display_delay_present_flag
    w.u(5, 0); // operating_points_cnt_minus_1
    w.u(12, 0); // operating_point_idc[0]
    w.u(5, seq.seq_level_idx);
    if (seq.seq_level_idx > 7) w.u(1, seq.seq_tier);
    const wb = std.math.log2_int(u32, @max(width - 1, 1)) + 1;
    const hb = std.math.log2_int(u32, @max(height - 1, 1)) + 1;
    w.u(4, wb - 1);
    w.u(4, hb - 1);
    w.u(@intCast(wb), width - 1);
    w.u(@intCast(hb), height - 1);
    w.flag(false); // frame_id_numbers_present_flag
    w.flag(false); // use_128x128_superblock
    w.flag(false); // enable_filter_intra
    w.flag(false); // enable_intra_edge_filter
    w.flag(false); // enable_interintra_compound
    w.flag(false); // enable_masked_compound
    w.flag(false); // enable_warped_motion
    w.flag(false); // enable_dual_filter
    const oh = sf.enable_order_hint != 0;
    w.flag(oh);
    if (oh) {
        w.flag(false); // enable_jnt_comp
        w.flag(false); // enable_ref_frame_mvs
    }
    w.flag(false); // seq_choose_screen_content_tools
    w.flag(false); // seq_force_screen_content_tools
    if (oh) w.u(3, seq.order_hint_bits_minus_1);
    w.flag(false); // enable_superres
    w.flag(sf.enable_cdef != 0);
    w.flag(false); // enable_restoration
    // color_config(): 8-bit 4:2:0, nothing described
    w.flag(false); // high_bitdepth
    w.flag(false); // mono_chrome
    w.flag(false); // color_description_present_flag
    w.flag(false); // color_range
    w.u(2, 0); // chroma_sample_position: unknown
    w.flag(false); // separate_uv_delta_q
    w.flag(false); // film_grain_params_present
    w.trailing();
    if (w.overflow) return null;
    const n = w.bytes().len;
    if (out.len < 2 + n) return null;
    out[0] = obuHeader(OBU_SEQUENCE_HEADER);
    out[1] = @intCast(n);
    @memcpy(out[2..][0..n], w.bytes());
    return 2 + n;
}

/// An OBU_PADDING of about `want` bytes (CBR's filler): its length.
pub fn paddingObu(out: []u8, want: usize) usize {
    if (want < 6 or out.len < 6) return 0;
    const len = @min(want, out.len);
    out[0] = obuHeader(OBU_PADDING);
    leb128Fixed(out[1..5], @intCast(len - 5));
    @memset(out[5..len], 0);
    return len;
}

/// show_frame and showable_frame of an app's packed frame header OBU
/// (FFmpeg's), or null if it is not one.
pub fn shownOf(packed_obu: []const u8) ?struct { show: bool, showable: bool } {
    if (packed_obu.len < 2) return null;
    const t = (packed_obu[0] >> 3) & 0xf;
    if (t != OBU_FRAME_HEADER and t != OBU_FRAME) return null;
    var at: usize = 1;
    if (packed_obu[0] & 4 != 0) at += 1; // extension
    if (packed_obu[0] & 2 != 0) {
        // obu_size
        while (at < packed_obu.len and packed_obu[at] & 0x80 != 0) at += 1;
        at += 1;
    }
    if (at >= packed_obu.len) return null;
    const b = packed_obu[at];
    if (b & 0x80 != 0) return .{ .show = true, .showable = false }; // show_existing_frame
    const show = b & 0x10 != 0;
    return .{ .show = show, .showable = if (show) false else b & 0x08 != 0 };
}

// ── From VA's parameters ────────────────────────────────────────────────────

pub fn check(seq: *const Seq, pic: *const Pic, width: u32, height: u32) va.Status {
    const sf = seq.seq_fields;
    if (seq.seq_profile != 0 or sf.bit_depth_minus8 != 0 or sf.mono_chrome != 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
    if (sf.use_128x128_superblock != 0 or sf.enable_superres != 0 or sf.enable_warped_motion != 0 or sf.enable_restoration != 0) return va.ERROR_INVALID_PARAMETER;
    const pf = pic.picture_flags;
    if (pf.use_superres != 0 or pf.allow_intrabc != 0 or pf.palette_mode_enable != 0 or pf.allow_screen_content_tools != 0 or pf.frame_type == 3) return va.ERROR_INVALID_PARAMETER;
    if (pic.segments.seg_flags & 1 != 0 or pic.mode_control_flags.delta_q_present != 0) return va.ERROR_INVALID_PARAMETER;
    if (width < MIN_WIDTH or height < MIN_HEIGHT or width > 4096) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    const sz = Size.of(width, height);
    // one tile: no wider than 4096, no larger than 4096 x 2304
    if (sz.sb_cols * sz.sb_rows > 2304) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    if (pic.tile_cols > 1 or pic.tile_rows > 1) return va.ERROR_INVALID_PARAMETER;
    return va.SUCCESS;
}

/// The reference names (1..7) of a list control (search_idx0..6), up to
/// `max`.
pub fn listOf(ctrl: u32, max: usize, out: []u3) usize {
    var n: usize = 0;
    for (0..7) |k| {
        const name: u3 = @intCast((ctrl >> @intCast(3 * k)) & 7);
        if (name == 0 or n >= max) break;
        out[n] = name;
        n += 1;
    }
    return n;
}

/// A loop-filter level for `qindex` when the app leaves it to the driver
/// (libaom's picking from the quantiser, rounded: 0 at the lowest
/// quantisers, 63 at the highest).
pub fn lfLevel(qindex: u8) u6 {
    return @intCast(std.math.clamp((@as(i32, qindex) * 8 - 64) >> 5, 0, 63));
}

/// The CDEF presets the driver gives when the app gives none (preset 0
/// must be off for the engine: nvenc_drv.h's note): (primary, secondary).
pub const CDEF_Y = [8]u6{ 0, (2 << 2) | 1, (4 << 2) | 1, (8 << 2) | 2, 0, 0, 0, 0 };
pub const CDEF_UV = [8]u6{ 0, (1 << 2) | 0, (2 << 2) | 1, (4 << 2) | 1, 0, 0, 0, 0 };

/// The frame VA describes, with the driver's `qindex`, `show` (from the
/// app's packed header or the order hints) and the slots' order hints.
pub fn frameOf(seq: *const Seq, pic: *const Pic, qindex: u8, show: bool, showable: bool, slot_hint: [8]u8) Frame {
    const pf = pic.picture_flags;
    const sf = seq.seq_fields;
    var f = Frame{
        .size = Size.of(@as(u32, pic.frame_width_minus_1) + 1, @as(u32, pic.frame_height_minus_1) + 1),
        .frame_type = pf.frame_type,
        .show_frame = show,
        .showable_frame = showable,
        .error_resilient = pf.error_resilient_mode != 0,
        .disable_cdf_update = pf.disable_cdf_update != 0,
        .disable_frame_end_update_cdf = pf.disable_frame_end_update_cdf != 0,
        .order_hint_bits = @intCast(@as(u32, seq.order_hint_bits_minus_1) + 1),
        .enable_order_hint = sf.enable_order_hint != 0,
        .enable_cdef = sf.enable_cdef != 0,
        .order_hint = pic.order_hint,
        .primary_ref_frame = @intCast(@min(pic.primary_ref_frame, 7)),
        .refresh = pic.refresh_frame_flags,
        .slot_hint = slot_hint,
        .qindex = @max(qindex, 1),
        .sharpness = @intCast(pic.loop_filter_flags & 7),
        .lf_delta_enabled = pic.loop_filter_flags & 8 != 0,
        .lf_delta_update = pic.loop_filter_flags & 16 != 0,
        .ref_deltas = pic.ref_deltas,
        .mode_deltas = pic.mode_deltas,
        .tx_mode_select = pic.mode_control_flags.tx_mode != 1,
        .reference_select = pic.mode_control_flags.reference_mode != 0,
        .reduced_tx_set = pf.reduced_tx_set != 0,
    };
    for (&f.ref_frame_idx, pic.ref_frame_idx) |*o, i| o.* = @intCast(i & 7);
    if (f.frame_type == 0 and f.show_frame) f.refresh = 0xff;
    if (f.intra()) f.reference_select = false;
    // the loop filter: the app's levels, else the driver's for the QP
    const app_lf = [4]u8{ pic.filter_level[0], pic.filter_level[1], pic.filter_level_u, pic.filter_level_v };
    if (app_lf[0] == 0 and app_lf[1] == 0) {
        const l = lfLevel(f.qindex);
        f.lf = .{ l, l, l, l };
    } else {
        for (&f.lf, app_lf) |*o, v| o.* = @intCast(@min(v, 63));
    }
    // CDEF: the app's strengths, else the driver's presets
    if (f.enable_cdef) {
        var any = false;
        for (pic.cdef_y_strengths) |v| any = any or v != 0;
        if (any) {
            f.cdef_bits = @intCast(pic.cdef_bits & 3);
            f.cdef_damping_minus_3 = @intCast(pic.cdef_damping_minus_3 & 3);
            for (&f.cdef_y, &f.cdef_uv, pic.cdef_y_strengths, pic.cdef_uv_strengths) |*y, *uv, a, b| {
                y.* = @intCast(a & 63);
                uv.* = @intCast(b & 63);
            }
        } else {
            f.cdef_y = CDEF_Y;
            f.cdef_uv = CDEF_UV;
        }
    }
    return f;
}

/// The picture's type for the rate control: I for intra, B when it has
/// backward references, else P.
pub fn rcType(pic: *const Pic) enc_rc.Type {
    if (pic.picture_flags.frame_type == 0 or pic.picture_flags.frame_type == 2) return .i;
    var names: [7]u3 = undefined;
    return if (listOf(pic.ref_frame_ctrl_l1, MAX_L1, &names) > 0) .b else .p;
}

// ── The engine's setup ──────────────────────────────────────────────────────

pub const Setup = struct {
    frame: Frame,
    pic: *const Pic,
    input: h264.Planes,
    recon: h264.Planes,
    /// each VA reference slot's surface (reference_frames), the engine's
    /// slot of the same number
    ref_ids: [8]u32,
    framerate: u32,
    gop_length: u32,
    bitstream_start: u32,
    bitstream_room: u32,
    history_bytes: u32,
    magic: u32 = nvenc.MAGIC,
    /// where the tile controls go in the setup (encode.Try.av1_tiles_at)
    tiles_at: u32 = nvenc.TILE_CONTROL_OFF,
};

pub fn setup(buf: []u8, s: Setup) void {
    @memset(buf[0..nvenc.SETUP_BYTES], 0);
    const f = s.frame;
    const pic = s.pic;
    nvenc.set(buf, A.magic, s.magic);
    const cfgs = [_][4]nvenc.F{
        .{ A.refpic_cfg_frame_width_minus1, A.refpic_cfg_frame_height_minus1, A.refpic_cfg_sfc_pitch, A.refpic_cfg_sfc_pitch_chroma },
        .{ A.input_cfg_frame_width_minus1, A.input_cfg_frame_height_minus1, A.input_cfg_sfc_pitch, A.input_cfg_sfc_pitch_chroma },
        .{ A.outputpic_cfg_frame_width_minus1, A.outputpic_cfg_frame_height_minus1, A.outputpic_cfg_sfc_pitch, A.outputpic_cfg_sfc_pitch_chroma },
    };
    for (cfgs, 0..) |c, i| {
        const p = if (i == 1) s.input else s.recon;
        nvenc.set(buf, c[0], f.size.width - 1);
        nvenc.set(buf, c[1], f.size.height - 1);
        nvenc.set(buf, c[2], p.pitch_luma);
        nvenc.set(buf, c[3], p.pitch_chroma);
    }
    nvenc.set(buf, A.refpic_cfg_tiled_16x16, 1);
    nvenc.set(buf, A.outputpic_cfg_tiled_16x16, 1);
    nvenc.set(buf, A.input_cfg_block_height, nvenc.blockHeightField(s.input.block_height));
    // seqhdr_data: CUs 16 to 64 (the engine's range), 8-bit 4:2:0
    nvenc.set(buf, A.min_cu_size, 1);
    nvenc.set(buf, A.max_cu_size, 3);
    nvenc.set(buf, A.chroma_format_idc, 1);
    nvenc.set(buf, A.enable_cdef, @intFromBool(f.enable_cdef));
    // framehdr_data: what the frame header says
    nvenc.set(buf, A.frame_type, f.frame_type);
    nvenc.set(buf, A.disable_cdf_update, @intFromBool(f.disable_cdf_update));
    nvenc.set(buf, A.frame_end_update_cdf, @intFromBool(!f.disable_frame_end_update_cdf and !f.disable_cdf_update));
    nvenc.set(buf, A.interp_filter, 0); // EIGHTTAP
    nvenc.set(buf, A.mc_hfilter, 1);
    nvenc.set(buf, A.mc_vfilter, 1);
    nvenc.set(buf, A.frame_tx_mode, if (f.tx_mode_select) 1 else 0);
    nvenc.set(buf, A.frame_reference_mode, if (f.reference_select) 1 else 0);
    nvenc.set(buf, A.reduced_tx_set_flag, @intFromBool(f.reduced_tx_set));
    const backward = rcType(pic) == .b;
    nvenc.set(buf, A.bicompound_enable, @intFromBool(backward and f.reference_select));
    // the references' sign bias (LAST .. ALTREF: 1 for a later picture)
    if (!f.intra()) {
        for (f.ref_frame_idx, 0..) |slot, i| {
            const later = relDist(f, f.slot_hint[slot], f.order_hint) > 0;
            nvenc.set(buf, nvenc.at(A.ref_frame_sign_bias, @intCast(i + 1)), @intFromBool(later));
        }
    }
    for (f.lf, 0..) |l, i| nvenc.set(buf, nvenc.at(A.lf_filter_level, @intCast(i)), l);
    for (f.ref_deltas, 0..) |d, i| nvenc.setSigned(buf, nvenc.at(A.lf_ref_delta, @intCast(i)), d);
    nvenc.setSigned(buf, A.lf_mode_delta_0, f.mode_deltas[0]);
    nvenc.setSigned(buf, A.lf_mode_delta_1, f.mode_deltas[1]);
    nvenc.set(buf, A.lf_delta_enabled, @intFromBool(f.lf_delta_enabled));
    nvenc.set(buf, A.lf_sharpness, f.sharpness);
    if (f.lf_delta_update) {
        nvenc.set(buf, A.lf_update_ref_delta_flag, 0xff);
        nvenc.set(buf, A.lf_update_mode_delta0, 1);
        nvenc.set(buf, A.lf_update_mode_delta1, 1);
    }
    if (f.enable_cdef) {
        const presets = @as(u32, 1) << f.cdef_bits;
        nvenc.set(buf, A.cdef_damping_minus_3, f.cdef_damping_minus_3);
        nvenc.set(buf, A.cdef_bits, f.cdef_bits);
        var luma_idx: u64 = 0;
        for (0..@min(presets, 4)) |i| {
            const ii: u32 = @intCast(i);
            nvenc.set(buf, nvenc.at(A.cdef_y_strength_0, ii), f.cdef_y[i]);
            nvenc.set(buf, nvenc.at(A.cdef_uv_strength_0, ii), f.cdef_uv[i]);
            luma_idx |= @as(u64, ii) << @intCast(3 * i);
        }
        nvenc.set(buf, A.cdef_y_strength_num_minus_1, @min(presets, 4) - 1);
        nvenc.set(buf, A.cdef_uv_strength_num_minus_1, @min(presets, 4) - 1);
        nvenc.set(buf, A.cdef_combined_idx_minus_1, @min(presets, 4) - 1);
        nvenc.set(buf, A.cdef_combined_luma_idx, luma_idx);
        nvenc.set(buf, A.cdef_combined_chroma_idx, luma_idx);
    }
    nvenc.set(buf, A.base_q_idx, f.qindex);
    // rate control: the driver's qindex (encode.sig puts the firmware's
    // in when it runs it)
    enc_rc.constQp(buf, enc_rc.RcFields.of(A), f.qindex, s.framerate, s.gop_length);
    // pic_control: the lists, by reference name through ref_frame_idx to
    // the slot; poc_entry the name's index (LAST 0 .. ALTREF 6)
    // (unused: the lists -2 and the distances -1, as NVIDIA's driver
    // writes H.264's; nvenc.LIST_NONE)
    for (0..4) |k| {
        nvenc.set(buf, nvenc.at(A.l0, @intCast(k)), nvenc.LIST_NONE);
        nvenc.set(buf, nvenc.at(A.temp_dist_l0, @intCast(k)), nvenc.DIST_NONE);
        nvenc.set(buf, nvenc.at(A.poc_entry_l0, @intCast(k)), 0xff);
    }
    for (0..3) |k| {
        nvenc.set(buf, nvenc.at(A.l1, @intCast(k)), nvenc.LIST_NONE);
        nvenc.set(buf, nvenc.at(A.temp_dist_l1, @intCast(k)), nvenc.DIST_NONE);
        nvenc.set(buf, nvenc.at(A.poc_entry_l1, @intCast(k)), 0xff);
    }
    var counts = [2]usize{ 0, 0 };
    if (!f.intra()) {
        var names: [7]u3 = undefined;
        const ctrls = [2]u32{ pic.ref_frame_ctrl_l0, pic.ref_frame_ctrl_l1 };
        const maxes = [2]usize{ MAX_L0, MAX_L1 };
        const fields = [2][3]nvenc.F{ .{ A.l0, A.temp_dist_l0, A.poc_entry_l0 }, .{ A.l1, A.temp_dist_l1, A.poc_entry_l1 } };
        for (ctrls, 0..) |ctrl, li| {
            var n = listOf(ctrl, maxes[li], &names);
            // (no list given: LAST alone)
            if (li == 0 and n == 0) {
                names[0] = 1;
                n = 1;
            }
            for (names[0..n], 0..) |name, k| {
                const kk: u32 = @intCast(k);
                const slot = f.ref_frame_idx[name - 1];
                nvenc.set(buf, nvenc.at(fields[li][0], kk), slot);
                nvenc.setSigned(buf, nvenc.at(fields[li][1], kk), std.math.clamp(relDist(f, f.order_hint, f.slot_hint[slot]), -128, 127));
                nvenc.set(buf, nvenc.at(fields[li][2], kk), name - 1);
            }
            counts[li] = n;
        }
    }
    nvenc.set(buf, A.num_ref_idx_l0_active, counts[0]);
    nvenc.set(buf, A.num_ref_idx_l1_active, counts[1]);
    nvenc.set(buf, A.pic_output_flag, @intFromBool(pic.picture_flags.disable_frame_recon == 0));
    nvenc.set(buf, A.max_tu_depth_inter, 2);
    nvenc.set(buf, A.max_tu_depth_intra, 0);
    nvenc.set(buf, A.tile_control_offset, s.tiles_at);
    nvenc.set(buf, A.hist_buf_size, s.history_bytes);
    nvenc.set(buf, A.bitstream_buf_size, s.bitstream_room);
    nvenc.set(buf, A.bitstream_start_pos, s.bitstream_start);
    // pic_type: 0 P, 1 B, 2 I, 3 IDR (a key frame)
    nvenc.set(buf, A.pic_type, switch (f.frame_type) {
        0 => 3,
        2 => 2,
        else => if (backward) 1 else 0,
    });
    nvenc.set(buf, A.ref_pic_flag, @intFromBool(f.refresh != 0));
    nvenc.set(buf, A.num_tile_cols, 1);
    nvenc.set(buf, A.num_tile_rows, 1);
    nvenc.set(buf, A.strips_in_frame, 1);
    nvenc.set(buf, A.strip_width_in_sbs, f.size.sb_cols);
    nvenc.set(buf, A.strip_height_in_sbs, f.size.sb_rows);
    nvenc.set(buf, A.gp_timer_timeout_val, nvenc.GPTIMER_TIMEOUT);
    // the one tile
    const t = buf[s.tiles_at..];
    const T = nvenc.Av1Tile;
    nvenc.set(t, T.tile_bot_sbx, f.size.sb_cols - 1);
    nvenc.set(t, T.tile_bot_sby, f.size.sb_rows - 1);
    nvenc.set(t, T.qp_avr, f.qindex);
    nvenc.set(t, T.qp_tile_min, f.qindex);
    nvenc.set(t, T.qp_tile_max, f.qindex);
    nvenc.set(t, T.tile_type, switch (f.frame_type) {
        0, 2 => 2,
        else => if (backward) 0 else 1,
    });
    nvenc.set(t, T.force_intra, @intFromBool(f.intra()));
    nvenc.set(t, T.tile_end_update_cdf, 1);
    // MD: every partition, transform size and base intra mode; every
    // transform type (both stages)
    const md = buf[A.MD_CONTROL_OFF..];
    const M = nvenc.Av1Md;
    for ([_]nvenc.F{ M.cu8x8_part_2Nx2N_enable, M.cu16x16_part_2Nx2N_enable, M.cu32x32_part_2Nx2N_enable, M.cu64x64_part_2Nx2N_enable, M.tusize_4x4_enable, M.tusize_8x8_enable, M.tusize_16x16_enable, M.tusize_32x32_enable, M.tusize_64x64_enable, M.mv_cost_enable }) |fl| nvenc.set(md, fl, 1);
    for (0..5) |k| nvenc.set(md, nvenc.at(M.intra_luma_base_mode_4x4_enable, @intCast(k)), 0x1fff);
    nvenc.set(md, M.tx_type_search_mask, 0xffff);
    nvenc.set(md, nvenc.at(M.tx_type_search_mask, 1), 0xffff);
    nvenc.meControl(buf[A.ME_CONTROL_OFF..]);
}

// ── The CDFs and the context's buffers ──────────────────────────────────────

/// One CDF table (NVDEC's layout, 256-byte aligned room).
pub const CDF_BYTES: usize = std.mem.alignForward(usize, cdf.TABLE_BYTES, 4096);

/// The default table for quantiser context `ctx` into `out`.
pub fn writeDefaults(out: []u8, ctx: u2) void {
    for (cdf.PREFIX, 0..) |v, i| std.mem.writeInt(u16, out[2 * i ..][0..2], v, .little);
    for (cdf.COEF[ctx], 0..) |v, i| std.mem.writeInt(u16, out[2 * (cdf.COEF_AT + i) ..][0..2], v, .little);
}

/// The quantiser context of base_q_idx (AV1 spec 8.3.2's thresholds).
pub fn qContext(q: u8) u2 {
    if (q <= 20) return 0;
    if (q <= 60) return 1;
    if (q <= 120) return 2;
    return 3;
}

/// The line buffers (ASSUMED sizes: generous) and the history.
pub const Lines = struct {
    above: usize,
    left: usize,
    history: usize,

    pub fn of(width: u32, height: u32) Lines {
        const sz = Size.of(@max(width, 1), @max(height, 1));
        return .{
            .above = std.mem.alignForward(usize, @max(64 << 10, @as(usize, sz.sb_cols) * (8 << 10)), 4096),
            .left = std.mem.alignForward(usize, @max(64 << 10, @as(usize, sz.sb_rows) * (8 << 10)), 4096),
            // nvenc_drv.h: AV1_HIST_PIXEL_FRAME_SIZE, AV1_HIST_MV_SB_SIZE a superblock
            .history = std.mem.alignForward(usize, 8 * 8192 + @as(usize, sz.sb_cols) * sz.sb_rows * 1024, 4096),
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

pub fn testSeq() Seq {
    var s = std.mem.zeroes(Seq);
    s.seq_level_idx = 8;
    s.intra_period = 120;
    s.ip_period = 1;
    s.seq_fields = .{ .enable_order_hint = 1, .enable_cdef = 1, .subsampling_x = 1, .subsampling_y = 1 };
    s.order_hint_bits_minus_1 = 7;
    return s;
}

pub fn testPic(recon: u32, coded: u32, key: bool, order: u8) Pic {
    var p = std.mem.zeroes(Pic);
    p.frame_width_minus_1 = 255;
    p.frame_height_minus_1 = 143;
    p.reconstructed_frame = recon;
    p.coded_buf = coded;
    for (&p.reference_frames) |*r| r.* = va.INVALID_ID;
    p.order_hint = order;
    p.primary_ref_frame = NONE;
    p.base_qindex = 128;
    p.picture_flags = .{ .frame_type = if (key) 0 else 1 };
    p.mode_control_flags = .{ .tx_mode = 2 };
    p.loop_filter_flags = 8; // delta enabled
    p.ref_deltas = DEFAULT_REF_DELTAS;
    p.refresh_frame_flags = if (key) 0xff else 1;
    p.ref_frame_ctrl_l0 = 1; // LAST
    return p;
}

test "enc_av1: OBU headers, fixed-length leb128, show_existing, padding" {
    var b: [8]u8 = undefined;
    leb128Fixed(&b, 300);
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x82, 0x80, 0x00 }, b[0..4]);
    try testing.expectEqual(@as(u8, 0x1a), obuHeader(OBU_FRAME_HEADER));
    try testing.expectEqual(@as(u8, 0x22), obuHeader(OBU_TILE_GROUP));
    try testing.expectEqual(@as(usize, 3), showExistingObu(&b, 5));
    // show_existing 1, idx 101, trailing 1: 1101 1000
    try testing.expectEqualSlices(u8, &.{ 0x1a, 1, 0xd8 }, b[0..3]);
    var pad: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 20), paddingObu(&pad, 20));
    try testing.expectEqual(@as(u8, 0x7a), pad[0]);
    try testing.expectEqual(@as(u8, 15 | 0x80), pad[1]);
    try testing.expect(shownOf(&b).?.show);
    // a hidden, showable inter frame: show_existing 0, type 01, show 0, showable 1
    const hid = shownOf(&.{ 0x1a, 1, 0x28 }).?;
    try testing.expect(!hid.show and hid.showable);
    try testing.expectEqual(null, shownOf(&.{ 0x22, 0 }));
}

test "enc_av1: a key frame's header, bit by bit" {
    const seq = testSeq();
    const pic = testPic(0x400, 0x1000, true, 0);
    const f = frameOf(&seq, &pic, 100, true, false, .{0} ** 8);
    var out: [64]u8 = undefined;
    const n = frameHeaderObu(&out, f, 0).?;
    // 256x144: 4x3 superblocks of 64: one tile, tile log2 maxima 2 and 2
    var want: [32]u8 = undefined;
    var w = bits.Writer.init(&want);
    w.u(1, 0); // show_existing
    w.u(2, 0); // key
    w.u(1, 1); // show
    w.u(1, 0); // disable_cdf_update
    w.u(1, 0); // frame_size_override
    w.u(8, 0); // order_hint
    w.u(1, 0); // render_and_frame_size_different
    w.u(1, 0); // disable_frame_end_update_cdf
    w.u(1, 1); // uniform
    w.u(1, 0); // increment cols
    w.u(1, 0); // increment rows
    w.u(8, 100); // base_q_idx
    w.u(3, 0); // delta q y dc, u dc, u ac
    w.u(1, 0); // qmatrix
    w.u(1, 0); // segmentation
    w.u(1, 0); // delta_q_present
    const l = lfLevel(100);
    w.u(6, l);
    w.u(6, l);
    w.u(6, l);
    w.u(6, l);
    w.u(3, 0); // sharpness
    w.u(1, 1); // delta enabled
    w.u(1, 0); // delta update
    w.u(2, 2); // cdef damping - 3
    w.u(2, 2); // cdef bits
    for (0..4) |i| {
        w.u(4, CDEF_Y[i] >> 2);
        w.u(2, CDEF_Y[i] & 3);
        w.u(4, CDEF_UV[i] >> 2);
        w.u(2, CDEF_UV[i] & 3);
    }
    w.u(1, 1); // tx_mode_select
    w.u(1, 0); // reduced_tx_set
    w.trailing();
    try testing.expectEqual(@as(u8, 0x1a), out[0]);
    try testing.expectEqualSlices(u8, w.bytes(), out[5..n]);
    // padded to a room: the same bits, then zeros
    const m = frameHeaderObu(&out, f, w.bytes().len + 3).?;
    try testing.expectEqual(n + 3, m);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out[n..m]);
}

test "enc_av1: an inter frame's setup: the lists by name, sign bias, the tile" {
    const seq = testSeq();
    var pic = testPic(0x403, 0x1000, false, 2);
    // LAST and GOLDEN before (slots 0, 1), BWDREF after (slot 2)
    pic.ref_frame_idx = .{ 0, 0, 0, 1, 2, 2, 2 };
    pic.ref_frame_ctrl_l0 = 1 | (4 << 3);
    pic.ref_frame_ctrl_l1 = 5;
    pic.mode_control_flags.reference_mode = 2;
    pic.primary_ref_frame = 0;
    const f = frameOf(&seq, &pic, 120, true, false, .{ 1, 0, 4, 0, 0, 0, 0, 0 });
    var b: [nvenc.SETUP_BYTES]u8 = undefined;
    const planes = h264.Planes{ .luma = 0, .chroma = 0, .pitch_luma = 256, .pitch_chroma = 256 };
    setup(&b, .{ .frame = f, .pic = &pic, .input = planes, .recon = planes, .ref_ids = .{va.INVALID_ID} ** 8, .framerate = 30, .gop_length = 120, .bitstream_start = 64, .bitstream_room = 1 << 20, .history_bytes = 1 << 20 });
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, A.pic_type)); // B
    try testing.expectEqual(@as(u64, 2), nvenc.get(&b, A.num_ref_idx_l0_active));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, A.num_ref_idx_l1_active));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&b, nvenc.at(A.l0, 0)));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, nvenc.at(A.l0, 1)));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&b, nvenc.at(A.l1, 0)));
    try testing.expectEqual(@as(u64, 3), nvenc.get(&b, nvenc.at(A.poc_entry_l0, 1))); // GOLDEN
    try testing.expectEqual(@as(u64, 4), nvenc.get(&b, nvenc.at(A.poc_entry_l1, 0))); // BWDREF
    try testing.expectEqual(@as(u64, 0xfe), nvenc.get(&b, nvenc.at(A.temp_dist_l1, 0))); // 2 - 4
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, nvenc.at(A.ref_frame_sign_bias, 5))); // BWDREF later
    try testing.expectEqual(@as(u64, 0), nvenc.get(&b, nvenc.at(A.ref_frame_sign_bias, 1)));
    try testing.expectEqual(@as(u64, 1), nvenc.get(&b, A.frame_reference_mode));
    try testing.expectEqual(@as(u64, 120), nvenc.get(&b, A.base_q_idx));
    try testing.expectEqual(@as(u64, 3), nvenc.get(&b, A.strip_width_in_sbs) - 1);
    // (144 rows: three superblock rows)
    try testing.expectEqual(@as(u64, 2), nvenc.get(b[nvenc.TILE_CONTROL_OFF..], nvenc.Av1Tile.tile_bot_sby));
    try testing.expectEqual(@as(u64, 0), nvenc.get(b[nvenc.TILE_CONTROL_OFF..], nvenc.Av1Tile.tile_type)); // B
    // skip mode allowed (a forward and a backward reference): its flag coded
    try testing.expect(skipModeAllowed(f));
    // too small, too many tiles, 10-bit: refused
    var small = pic;
    try testing.expectEqual(va.ERROR_RESOLUTION_NOT_SUPPORTED, check(&seq, &small, 128, 96));
    small.tile_cols = 2;
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, check(&seq, &small, 256, 144));
    var deep = seq;
    deep.seq_fields.bit_depth_minus8 = 2;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, check(&deep, &pic, 256, 144));
    // the default CDFs: the decoder's table, by quantiser context
    var t: [cdf.TABLE_BYTES]u8 = undefined;
    writeDefaults(&t, qContext(200));
    try testing.expectEqual(cdf.COEF[3][0], std.mem.readInt(u16, t[2 * cdf.COEF_AT ..][0..2], .little));
}
