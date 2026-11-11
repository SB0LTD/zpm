//! @zpm/va vp9 — VP9 profiles 0 and 2 (8- and 10-bit 4:2:0) on the RTX's video decoder
//! (NVCFB0, GB206), as a codec module (codec.sig): VA-API's VP9 buffers in,
//! nvdec_vp9_pic_s, the decoder's probability table and tile sizes, and one
//! frame's pushbuffer out; VP9's backward adaptation from the counts the
//! decoder writes.
//!
//! The decoder parses only the tiles: the driver reads both headers itself.
//! VA-API gives derived per-segment values, but the decoder wants the raw
//! segmentation features, loop filter deltas and quantizer deltas, so the
//! uncompressed header is parsed here from the slice data; the compressed
//! header is decoded with a boolean decoder and its forward probability
//! updates applied to the frame's context; the bitstream handed to the
//! decoder starts after both headers.
//!
//! NVIDIA's public material stops at Ada: the VP9 methods are NVC9B0's
//! (clc9b0.h, 0x5c0..0x5ec), the setup (nvdec_vp9_pic_s), probability table
//! (nvdec_vp9EntropyProbs_t) and counts (nvdec_vp9EntropyCounts_t) are
//! nvdec_drv.h's, their offsets measured with gcc and asserted below.
//! Blackwell's are assumed to be the same — THE RISK, as for H.264: if
//! GB206's firmware reads a longer or reordered nvdec_vp9_pic_s, every field
//! past the first change is wrong. Further unverified on hardware:
//! - the filter buffer's layout: the Tegra decoder's per-row filter and BSD
//!   control parts (912 and 76 bytes per row of 64-aligned height), then an
//!   "above" part sized by nvdec_drv.h's VP9_DBLK_TOP_BUF_SIZE that
//!   v1.Vp9FltAboveOffset points at (the Tegra decoder predates v1);
//! - qpChAc/qpChDc take the bitstream's delta_q_uv_dc/delta_q_uv_ac in that
//!   order (the Tegra decoder's; libvpx streams keep both 0);
//! - mcomp_filter_type uses FFmpeg's and VA's numbering (0 smooth, 1
//!   regular, 2 sharp, 3 bilinear, 4 switchable: the bitstream's literal),
//!   as the Tegra decoder and nvidia-vaapi-driver pass it;
//! - ref_pred_probs, ref_scores and prob_comppred are left 0.
//!
//! What was taken from averne's Tegra NVDEC VP9 hwaccel for FFmpeg (facts
//! only, no code): the buffers and their sizes, slots 0/1/2/3 = last,
//! golden, altref, current, the segment map and co-located motion
//! ping-pong, the tile size buffer's layout and its two constants at u16
//! 0x37a/0x37b, the probability table's mode order (libvpx's) and partition
//! layout (key frame defaults, then the context's), the counts' layout, and
//! the flags (prevShowFrame, prevIsKeyFrame, comp refs + 1, sign biases).
//! VP9 itself (default tables, header syntax, boolean decoder, adaptation)
//! follows libvpx v1.14.0 (BSD) and the VP9 bitstream specification; the
//! tests compare against libvpx's own results.
//!
//! Allocator-free: the state, the contexts and every table are fixed-size.

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const codec = @import("codec.sig");
const vav = @import("vaapi_vp9.sig");
const tables = @import("vp9_tables.sig");

pub const FrameContext = tables.FrameContext;

/// VAProfileVP9Profile0.
pub const PROFILE: va.Profile = vav.PROFILE_VP9_PROFILE0;

// ── The class's VP9 methods (clc9b0.h) ──────────────────────────────────────

pub const APPLICATION_ID_VP9: u32 = 9;
pub const CODEC_TYPE_VP9: u32 = 9;

pub const VP9_SET_PROB_TAB_BUF_OFFSET: u32 = 0x5c0;
pub const VP9_SET_CTX_COUNTER_BUF_OFFSET: u32 = 0x5c4;
pub const VP9_SET_SEGMENT_READ_BUF_OFFSET: u32 = 0x5c8;
pub const VP9_SET_SEGMENT_WRITE_BUF_OFFSET: u32 = 0x5cc;
pub const VP9_SET_TILE_SIZE_BUF_OFFSET: u32 = 0x5d0;
pub const VP9_SET_COL_MVWRITE_BUF_OFFSET: u32 = 0x5d4;
pub const VP9_SET_COL_MVREAD_BUF_OFFSET: u32 = 0x5d8;
pub const VP9_SET_FILTER_BUFFER_OFFSET: u32 = 0x5dc;

// ── The decoder's structs (nvdec_drv.h) ─────────────────────────────────────

/// A reference's coded size and its planes' pitches.
pub const RefDims = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    stride: [2]u16 = .{ 0, 0 },
};

/// nvdec_vp9_pic_s: one VP9 frame's setup (SET_DRV_PIC_SETUP_OFFSET).
pub const Vp9Pic = extern struct {
    /// encryption: off
    wrapped_session_key: [4]u32 = .{ 0, 0, 0, 0 },
    wrapped_content_key: [4]u32 = .{ 0, 0, 0, 0 },
    initialization_vector: [4]u32 = .{ 0, 0, 0, 0 },
    /// the tile data's bytes
    stream_len: u32 = 0,
    enable_encryption: u32 = 0,
    secure: packed struct(u32) {
        key_increment: u6 = 0,
        encryption_mode: u4 = 0,
        sw_hdr_skip_length: u14 = 0,
        key_slot_index: u4 = 0,
        ssm_en: u1 = 0,
        enable_histogram: u1 = 0,
        reserved0: u2 = 0,
    } = .{},
    gptimer_timeout_value: u32 = 0,
    surface: packed struct(u8) {
        /// 0 TBL, 1 KBL (the GPU's block linear), 2 Tile16x16
        tileformat: u2 = 0,
        /// blocks of 2 << gob_height GOBs
        gob_height: u3 = 0,
        reserved: u3 = 0,
    } = .{},
    reserved1: [3]u8 = .{ 0, 0, 0 },
    /// the BSD control part's offset in the filter buffer, 256-byte units
    Vp9BsdCtrlOffset: u32 = 0,
    /// last, golden, altref
    refs: [3]RefDims = [_]RefDims{.{}} ** 3,
    width: u16 = 0,
    height: u16 = 0,
    framestride: [2]u16 = .{ 0, 0 },
    flags: packed struct(u8) {
        keyFrame: u1 = 0,
        prevIsKeyFrame: u1 = 0,
        resolutionChange: u1 = 0,
        errorResilient: u1 = 0,
        prevShowFrame: u1 = 0,
        intraOnly: u1 = 0,
        reserved2: u2 = 0,
    } = .{},
    reserved3: [3]u8 = .{ 0, 0, 0 },
    /// [0, last, golden, altref]
    refFrameSignBias: [4]u8 = .{ 0, 0, 0, 0 },
    loopFilterLevel: i8 = 0,
    loopFilterSharpness: i8 = 0,
    /// base_q_idx
    qpYAc: u8 = 0,
    qpYDc: i8 = 0,
    qpChAc: i8 = 0,
    qpChDc: i8 = 0,
    lossless: i8 = 0,
    /// tx_mode 0..4
    transform_mode: i8 = 0,
    allow_high_precision_mv: i8 = 0,
    mcomp_filter_type: i8 = 0,
    /// reference_mode: 0 single, 1 compound, 2 select
    comp_pred_mode: i8 = 0,
    /// 1 last, 2 golden, 3 altref; 0 when compound is not allowed
    comp_fixed_ref: i8 = 0,
    comp_var_ref: [2]i8 = .{ 0, 0 },
    log2_tile_columns: i8 = 0,
    log2_tile_rows: i8 = 0,
    segmentEnabled: u8 = 0,
    segmentMapUpdate: u8 = 0,
    segmentMapTemporalUpdate: u8 = 0,
    /// 1: absolute values, 0: deltas
    segmentFeatureMode: u8 = 0,
    /// [segment][quantizer, loop filter, reference, skip]
    segmentFeatureEnable: [8][4]u8 = [_][4]u8{.{ 0, 0, 0, 0 }} ** 8,
    segmentFeatureData: [8][4]i16 = [_][4]i16{.{ 0, 0, 0, 0 }} ** 8,
    modeRefLfEnabled: i8 = 0,
    /// [intra, last, golden, altref]
    mbRefLfDelta: [4]i8 = .{ 0, 0, 0, 0 },
    mbModeLfDelta: [2]i8 = .{ 0, 0 },
    reserved5: u8 = 0,
    /// nvdec_vp9_pic_v1_s
    v1: extern struct {
        /// the filter buffer's "above" part, 256-byte units
        Vp9FltAboveOffset: u32 = 0,
        bits: packed struct(u32) {
            external_ref_mem_dis: u1 = 0,
            bit_depth: u4 = 0,
            error_recovery_start_pos: u2 = 0,
            error_external_mv_en: u1 = 0,
            reserved0: u24 = 0,
        } = .{},
    } = .{},
    /// nvdec_pass2_otf_ext_s (12 bytes)
    ssm: [3]u32 = .{ 0, 0, 0 },
};

/// nvdec_nmv_context.
pub const HwMv = extern struct {
    joints: [3]u8,
    sign: [2]u8,
    class0: [2][1]u8,
    fp: [2][3]u8,
    class0_hp: [2]u8,
    hp: [2]u8,
    classes: [2][10]u8,
    class0_fp: [2][2][3]u8,
    bits: [2][10]u8,
};

/// nvdec_vp9AdaptiveEntropyProbs_t: the context's probabilities. Every
/// index is libvpx's; vectors of nine are split in eight and one.
pub const HwAdaptive = extern struct {
    /// three used of four
    inter_mode_prob: [7][4]u8,
    intra_inter_prob: [4]u8,
    uv_mode_prob: [10][8]u8,
    tx8x8_prob: [2][1]u8,
    tx16x16_prob: [2][2]u8,
    tx32x32_prob: [2][3]u8,
    sb_ymode_probB: [4][1]u8,
    sb_ymode_prob: [4][8]u8,
    /// [0]: the key frame defaults, [1]: the context's; three used of four
    partition_prob: [2][16][4]u8,
    uv_mode_probB: [10][1]u8,
    switchable_interp_prob: [4][2]u8,
    comp_inter_prob: [5]u8,
    mbskip_probs: [3]u8,
    pad1: [1]u8,
    nmvc: HwMv,
    single_ref_prob: [5][2]u8,
    comp_ref_prob: [5]u8,
    pad2: [17]u8,
    /// [plane type][reference][band][context][node], three used of four
    probCoeffs: [4][2][2][6][6][4]u8,
};

/// nvdec_vp9EntropyProbs_t: the probability table (VP9_SET_PROB_TAB_BUF).
pub const HwProbs = extern struct {
    /// the key frame luma modes [above][left]
    kf_bmode_prob: [10][10][8]u8,
    kf_bmode_probB: [10][10][1]u8,
    ref_pred_probs: [3]u8,
    mb_segment_tree_probs: [7]u8,
    segment_pred_probs: [3]u8,
    ref_scores: [4]u8,
    prob_comppred: [2]u8,
    pad1: [9]u8,
    kf_uv_mode_prob: [10][8]u8,
    kf_uv_mode_probB: [10][1]u8,
    pad2: [6]u8,
    a: HwAdaptive,
};

/// nvdec_nmv_context_counts.
pub const HwMvCounts = extern struct {
    joints: [4]u32,
    sign: [2][2]u32,
    classes: [2][11]u32,
    class0: [2][2]u32,
    bits: [2][10][2]u32,
    class0_fp: [2][2][4]u32,
    fp: [2][4]u32,
    class0_hp: [2][2]u32,
    hp: [2][2]u32,
};

/// nvdec_vp9EntropyCounts_t: what the decoder counted of one frame
/// (VP9_SET_CTX_COUNTER_BUF). Indexes are libvpx's, but inter modes are
/// counted per tree node ([0][0] ZERO, [1][0] NEAREST, [2][0] NEAR,
/// [2][1] NEW), coefficients as ZERO, ONE, TWO+ and EOB, and countEobs is
/// libvpx's eob_branch.
pub const HwCounts = extern struct {
    inter_mode_counts: [7][3][2]u32,
    sb_ymode_counts: [4][10]u32,
    uv_mode_counts: [10][10]u32,
    partition_counts: [16][4]u32,
    switchable_interp_counts: [4][3]u32,
    intra_inter_count: [4][2]u32,
    comp_inter_count: [5][2]u32,
    single_ref_count: [5][2][2]u32,
    comp_ref_count: [5][2]u32,
    tx32x32_count: [2][4]u32,
    tx16x16_count: [2][3]u32,
    tx8x8_count: [2][2]u32,
    mbskip_count: [3][2]u32,
    nmvcount: HwMvCounts,
    countCoeffs: [4][2][2][6][6][4]u32,
    countEobs: [4][2][2][6][6]u32,
};

comptime {
    // (gcc's offsets of nvdec_drv.h's structs)
    std.debug.assert(@offsetOf(Vp9Pic, "stream_len") == 0x30);
    std.debug.assert(@offsetOf(Vp9Pic, "gptimer_timeout_value") == 0x3c);
    std.debug.assert(@offsetOf(Vp9Pic, "surface") == 0x40);
    std.debug.assert(@offsetOf(Vp9Pic, "Vp9BsdCtrlOffset") == 0x44);
    std.debug.assert(@offsetOf(Vp9Pic, "refs") == 0x48);
    std.debug.assert(@offsetOf(Vp9Pic, "width") == 0x60);
    std.debug.assert(@offsetOf(Vp9Pic, "framestride") == 0x64);
    std.debug.assert(@offsetOf(Vp9Pic, "flags") == 0x68);
    std.debug.assert(@offsetOf(Vp9Pic, "refFrameSignBias") == 0x6c);
    std.debug.assert(@offsetOf(Vp9Pic, "loopFilterLevel") == 0x70);
    std.debug.assert(@offsetOf(Vp9Pic, "qpYAc") == 0x72);
    std.debug.assert(@offsetOf(Vp9Pic, "lossless") == 0x76);
    std.debug.assert(@offsetOf(Vp9Pic, "comp_var_ref") == 0x7c);
    std.debug.assert(@offsetOf(Vp9Pic, "log2_tile_columns") == 0x7e);
    std.debug.assert(@offsetOf(Vp9Pic, "segmentEnabled") == 0x80);
    std.debug.assert(@offsetOf(Vp9Pic, "segmentFeatureEnable") == 0x84);
    std.debug.assert(@offsetOf(Vp9Pic, "segmentFeatureData") == 0xa4);
    std.debug.assert(@offsetOf(Vp9Pic, "modeRefLfEnabled") == 0xe4);
    std.debug.assert(@offsetOf(Vp9Pic, "mbRefLfDelta") == 0xe5);
    std.debug.assert(@offsetOf(Vp9Pic, "mbModeLfDelta") == 0xe9);
    std.debug.assert(@offsetOf(Vp9Pic, "v1") == 0xec);
    std.debug.assert(@offsetOf(Vp9Pic, "ssm") == 0xf4);
    std.debug.assert(@sizeOf(Vp9Pic) == 0x100);
    std.debug.assert(@sizeOf(HwMv) == 0x45);
    std.debug.assert(@offsetOf(HwAdaptive, "uv_mode_prob") == 0x20);
    std.debug.assert(@offsetOf(HwAdaptive, "tx8x8_prob") == 0x70);
    std.debug.assert(@offsetOf(HwAdaptive, "sb_ymode_prob") == 0x80);
    std.debug.assert(@offsetOf(HwAdaptive, "partition_prob") == 0xa0);
    std.debug.assert(@offsetOf(HwAdaptive, "uv_mode_probB") == 0x120);
    std.debug.assert(@offsetOf(HwAdaptive, "mbskip_probs") == 0x137);
    std.debug.assert(@offsetOf(HwAdaptive, "nmvc") == 0x13b);
    std.debug.assert(@offsetOf(HwAdaptive, "single_ref_prob") == 0x180);
    std.debug.assert(@offsetOf(HwAdaptive, "probCoeffs") == 0x1a0);
    std.debug.assert(@sizeOf(HwAdaptive) == 0xaa0);
    std.debug.assert(@offsetOf(HwProbs, "kf_bmode_probB") == 0x320);
    std.debug.assert(@offsetOf(HwProbs, "ref_pred_probs") == 0x384);
    std.debug.assert(@offsetOf(HwProbs, "kf_uv_mode_prob") == 0x3a0);
    std.debug.assert(@offsetOf(HwProbs, "a") == 0x400);
    std.debug.assert(@sizeOf(HwProbs) == 0xea0);
    std.debug.assert(@sizeOf(HwMvCounts) == 0x1a8);
    std.debug.assert(@offsetOf(HwCounts, "sb_ymode_counts") == 0xa8);
    std.debug.assert(@offsetOf(HwCounts, "partition_counts") == 0x2d8);
    std.debug.assert(@offsetOf(HwCounts, "tx32x32_count") == 0x4c8);
    std.debug.assert(@offsetOf(HwCounts, "mbskip_count") == 0x510);
    std.debug.assert(@offsetOf(HwCounts, "nmvcount") == 0x528);
    std.debug.assert(@offsetOf(HwCounts, "countCoeffs") == 0x6d0);
    std.debug.assert(@offsetOf(HwCounts, "countEobs") == 0x2ad0);
    std.debug.assert(@sizeOf(HwCounts) == 0x33d0);
}

// ── Buffers ─────────────────────────────────────────────────────────────────

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) / a * a;
}

/// The setup's room in a frame slot.
pub const MAX_PIC_BYTES: usize = @sizeOf(Vp9Pic);

/// The frame slot's side buffers: the probability table, then the tile
/// sizes (u16 width and height in superblocks per tile, row by row; 0x700
/// bytes with two constants near the end).
pub const AUX_PROBS: usize = 0;
pub const AUX_TILES: usize = alignUp(@sizeOf(HwProbs), 0x100);
pub const TILE_BYTES: usize = 0x700;
pub const MAX_AUX_BYTES: usize = AUX_TILES + TILE_BYTES;

/// The dwords one frame's pushbuffer takes.
pub const PUSH_DWORDS: usize = 15 * 2 + 2 * (1 + nvdec.SLOTS) + 2;

comptime {
    std.debug.assert(MAX_PIC_BYTES <= codec.PIC_BYTES);
    std.debug.assert(MAX_AUX_BYTES <= codec.AUX_BYTES);
}

/// The context-wide buffers in the scratch (offsets from its start, all
/// 256-byte aligned).
pub const Layout = struct {
    /// the decoder's counts (HwCounts)
    counts: usize,
    /// segment maps: two written in turn, one never written (all zero: read
    /// after a frame that reset the map)
    seg: [3]usize,
    seg_bytes: usize,
    /// co-located motion: written in turn
    mv: [2]usize,
    mv_bytes: usize,
    /// the filter buffer, and its BSD control and "above" parts' offsets
    /// within it
    filter: usize,
    filter_bytes: usize,
    bsd: usize,
    above: usize,
    total: usize,
};

/// The scratch's layout for pictures up to `width` x `height`.
pub fn layout(width: u32, height: u32) Layout {
    const w: usize = width;
    const h: usize = height;
    // superblocks of 64 over the 16-aligned picture
    const sbs = ((alignUp(w, 16) + 63) / 64) * ((alignUp(h, 16) + 63) / 64);
    const seg_bytes = alignUp(sbs * 32, 0x100);
    const mv_bytes = alignUp(sbs * 1024, 0x100);
    const rows = alignUp(h, 64);
    const filt = rows * 912;
    const bsd = rows * 76;
    // nvdec_drv.h's VP9_DBLK_TOP_BUF_SIZE
    const above = alignUp((alignUp(w, 64) / 64 + 2) * 2048, 0x100);
    var l: Layout = undefined;
    var at: usize = 0;
    l.counts = at;
    at += alignUp(@sizeOf(HwCounts), 0x100);
    for (&l.seg) |*s| {
        s.* = at;
        at += seg_bytes;
    }
    l.seg_bytes = seg_bytes;
    for (&l.mv) |*m| {
        m.* = at;
        at += mv_bytes;
    }
    l.mv_bytes = mv_bytes;
    l.filter = at;
    l.bsd = filt;
    l.above = filt + bsd;
    l.filter_bytes = filt + bsd + above;
    at += l.filter_bytes;
    l.total = at;
    return l;
}

/// The context-wide buffers' bytes (codec.sig's scratchBytes).
pub fn scratchBytes(width: u32, height: u32) usize {
    return layout(width, height).total;
}

// ── Reading bits ────────────────────────────────────────────────────────────

pub const Error = error{Corrupt};

/// The uncompressed header's plain bits, most significant first.
const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn bit(r: *BitReader) Error!u1 {
        if (r.pos >= r.data.len * 8) return error.Corrupt;
        const b = r.data[r.pos >> 3] >> @intCast(7 - (r.pos & 7));
        r.pos += 1;
        return @truncate(b);
    }

    fn flag(r: *BitReader) Error!bool {
        return try r.bit() == 1;
    }

    fn bits(r: *BitReader, n: u6) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | try r.bit();
        return v;
    }

    /// n bits of magnitude, then the sign
    fn signed(r: *BitReader, n: u5) Error!i32 {
        const v: i32 = @intCast(try r.bits(n));
        return if (try r.flag()) -v else v;
    }

    fn bytes(r: BitReader) usize {
        return (r.pos + 7) / 8;
    }
};

/// VP9's boolean decoder (the specification's init_bool / read_bool).
pub const BoolDecoder = struct {
    data: []const u8,
    /// the next bit to shift in
    pos: usize,
    value: u32,
    range: u32,

    /// Starts on `data` (its first byte, then the marker bit, which must
    /// be 0).
    pub fn init(data: []const u8) Error!BoolDecoder {
        if (data.len == 0) return error.Corrupt;
        var d = BoolDecoder{ .data = data, .pos = 8, .value = data[0], .range = 255 };
        if (d.read(128) != 0) return error.Corrupt;
        return d;
    }

    fn next(d: *BoolDecoder) u32 {
        // (past the end: zeros, the specification's padding)
        if (d.pos >= d.data.len * 8) return 0;
        const b = (d.data[d.pos >> 3] >> @intCast(7 - (d.pos & 7))) & 1;
        d.pos += 1;
        return b;
    }

    /// One bool, 1 with probability (256 - p) / 256.
    pub fn read(d: *BoolDecoder, p: u8) u1 {
        const split = 1 + (((d.range - 1) * @as(u32, p)) >> 8);
        var b: u1 = 0;
        if (d.value < split) {
            d.range = split;
        } else {
            d.range -= split;
            d.value -= split;
            b = 1;
        }
        while (d.range < 128) {
            d.value = (d.value << 1) | d.next();
            d.range <<= 1;
        }
        return b;
    }

    pub fn literal(d: *BoolDecoder, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | d.read(128);
        return v;
    }
};

// ── Forward updates (libvpx vp9_dsubexp.c, the specification's diff_update_prob)

const DIFF_UPDATE_PROB: u8 = 252;
const MV_UPDATE_PROB: u8 = 252;

const INV_MAP_TABLE = [255]u8{
    7,   20,  33,  46,  59,  72,  85,  98,  111, 124, 137, 150, 163, 176, 189,
    202, 215, 228, 241, 254, 1,   2,   3,   4,   5,   6,   8,   9,   10,  11,
    12,  13,  14,  15,  16,  17,  18,  19,  21,  22,  23,  24,  25,  26,  27,
    28,  29,  30,  31,  32,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,
    44,  45,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  60,
    61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  73,  74,  75,  76,
    77,  78,  79,  80,  81,  82,  83,  84,  86,  87,  88,  89,  90,  91,  92,
    93,  94,  95,  96,  97,  99,  100, 101, 102, 103, 104, 105, 106, 107, 108,
    109, 110, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 125,
    126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 138, 139, 140, 141,
    142, 143, 144, 145, 146, 147, 148, 149, 151, 152, 153, 154, 155, 156, 157,
    158, 159, 160, 161, 162, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173,
    174, 175, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 190,
    191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 203, 204, 205, 206,
    207, 208, 209, 210, 211, 212, 213, 214, 216, 217, 218, 219, 220, 221, 222,
    223, 224, 225, 226, 227, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238,
    239, 240, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 253,
};

fn invRecenterNonneg(v: u32, m: u32) u32 {
    if (v > 2 * m) return v;
    return if (v & 1 != 0) m - ((v + 1) >> 1) else m + (v >> 1);
}

fn invRemapProb(delta: u32, prob: u8) u8 {
    const v: u32 = INV_MAP_TABLE[@min(delta, INV_MAP_TABLE.len - 1)];
    const m: u32 = @as(u32, prob) - 1;
    if ((m << 1) <= 255) return @intCast(1 + invRecenterNonneg(v, m));
    return @intCast(255 - invRecenterNonneg(v, 255 - 1 - m));
}

fn decodeTermSubexp(d: *BoolDecoder) u32 {
    if (d.read(128) == 0) return d.literal(4);
    if (d.read(128) == 0) return d.literal(4) + 16;
    if (d.read(128) == 0) return d.literal(5) + 32;
    // decode_uniform: 8 bits, 65 values coded in 7
    const v = d.literal(7);
    const u = if (v < 65) v else (v << 1) - 65 + d.read(128);
    return u + 64;
}

fn diffUpdate(d: *BoolDecoder, p: *u8) void {
    if (d.read(DIFF_UPDATE_PROB) == 1) {
        // (a probability of 0 never comes from the tables or an update)
        if (p.* == 0) p.* = 1;
        p.* = invRemapProb(decodeTermSubexp(d), p.*);
    }
}

fn diffUpdateAll(d: *BoolDecoder, ps: []u8) void {
    for (ps) |*p| diffUpdate(d, p);
}

fn mvUpdate(d: *BoolDecoder, ps: []u8) void {
    for (ps) |*p| {
        if (d.read(MV_UPDATE_PROB) == 1) p.* = @intCast((d.literal(7) << 1) | 1);
    }
}

// ── The headers ─────────────────────────────────────────────────────────────

/// Segmentation as it persists from frame to frame.
pub const Segmentation = struct {
    /// segmentation_abs_or_delta_update
    abs_delta: bool = false,
    /// [segment][quantizer, loop filter, reference, skip]
    enabled: [8][4]bool = [_][4]bool{.{ false, false, false, false }} ** 8,
    data: [8][4]i16 = [_][4]i16{.{ 0, 0, 0, 0 }} ** 8,
    tree_probs: [7]u8 = [_]u8{255} ** 7,
    pred_probs: [3]u8 = [_]u8{255} ** 3,
};

/// The loop filter's deltas as they persist from frame to frame.
pub const LoopFilterDeltas = struct {
    /// intra, last, golden, altref
    ref: [4]i8 = .{ 1, 0, -1, -1 },
    mode: [2]i8 = .{ 0, 0 },
};

/// tx_mode values.
pub const TX_MODE_SELECT: u3 = 4;
/// interp_filter: switchable.
pub const INTERP_SWITCHABLE: u3 = 4;

/// One frame's headers.
pub const Header = struct {
    profile: u2 = 0,
    key: bool = false,
    show_frame: bool = false,
    error_res: bool = false,
    intra_only: bool = false,
    reset_context: u2 = 0,
    refresh_flags: u8 = 0,
    /// last, golden, altref: indexes into the eight reference slots
    ref_idx: [3]u3 = .{ 0, 0, 0 },
    /// [0, last, golden, altref] (zeroed by a reset, as libvpx does)
    sign_bias: [4]u1 = .{ 0, 0, 0, 0 },
    /// the size if the header carries it (0: a reference's, VA's is used)
    width: u32 = 0,
    height: u32 = 0,
    allow_hp: bool = false,
    /// the bitstream's literal (0 smooth, 1 regular, 2 sharp, 3 bilinear)
    /// or INTERP_SWITCHABLE
    interp: u3 = 0,
    refresh_context: bool = false,
    parallel: bool = false,
    /// after the reset rules (0 for intra-only and error resilient frames)
    context_idx: u2 = 0,
    /// as written (the one reset_frame_context 2 resets)
    raw_context_idx: u2 = 0,
    /// FrameIsIntra or error_resilient_mode: contexts, segmentation, loop
    /// filter deltas and the segment map were reset
    reset: bool = false,
    lf_level: u6 = 0,
    lf_sharpness: u3 = 0,
    lf_delta_enabled: bool = false,
    base_q: u8 = 0,
    dq_y_dc: i8 = 0,
    dq_uv_dc: i8 = 0,
    dq_uv_ac: i8 = 0,
    lossless: bool = false,
    seg_enabled: bool = false,
    seg_update_map: bool = false,
    seg_temporal: bool = false,
    seg_update_data: bool = false,
    log2_tile_cols: u3 = 0,
    log2_tile_rows: u2 = 0,
    /// the two headers' bytes
    uncompressed_bytes: usize = 0,
    compressed_bytes: usize = 0,
    // from the compressed header
    tx_mode: u3 = 0,
    /// 0 single, 1 compound, 2 select
    reference_mode: u2 = 0,
    comp_fixed_ref: u2 = 0,
    comp_var_ref: [2]u2 = .{ 0, 0 },

    pub fn intra(h: Header) bool {
        return h.key or h.intra_only;
    }
};

/// What a frame's headers change in the context's state, applied once both
/// parsed.
const Parsed = struct {
    hdr: Header,
    seg: Segmentation,
    lf: LoopFilterDeltas,
    fc: FrameContext,
};

fn readSyncCode(r: *BitReader) Error!void {
    if (try r.bits(8) != 0x49 or try r.bits(8) != 0x83 or try r.bits(8) != 0x42) return error.Corrupt;
}

fn readFrameSize(r: *BitReader, h: *Header) Error!void {
    h.width = try r.bits(16) + 1;
    h.height = try r.bits(16) + 1;
}

fn readRenderSize(r: *BitReader) Error!void {
    if (try r.flag()) _ = try r.bits(32);
}

/// tile columns' bounds for `width` (libvpx vp9_get_tile_n_bits)
fn tileColsLog2(width: u32) struct { min: u3, max: u3 } {
    const mi_cols = (width + 7) >> 3;
    const sb_cols = (mi_cols + 7) >> 3;
    var min: u32 = 0;
    while ((@as(u32, 64) << @intCast(min)) < sb_cols) min += 1;
    var max: u32 = 1;
    while ((sb_cols >> @intCast(max)) >= 4) max += 1;
    max -= 1;
    return .{ .min = @intCast(@min(min, 6)), .max = @intCast(@min(@max(max, min), 6)) };
}

/// The uncompressed header (the specification's uncompressed_header()),
/// for a frame `va_width` wide when the header takes its size from a
/// reference. `st`'s persistent parts are read, not changed.
fn parseUncompressed(st: *const State, data: []const u8, va_width: u32, p: *Parsed) Error!void {
    var r = BitReader{ .data = data };
    var h = Header{};
    if (try r.bits(2) != 2) return error.Corrupt;
    const lo = try r.bit();
    const hi = try r.bit();
    h.profile = (@as(u2, hi) << 1) | lo;
    if (h.profile == 3) _ = try r.bit();
    // (show_existing_frame: nothing to decode; VA clients show the
    // reference themselves)
    if (try r.flag()) return error.Corrupt;
    h.key = try r.bit() == 0;
    h.show_frame = try r.flag();
    h.error_res = try r.flag();
    if (h.key) {
        try readSyncCode(&r);
        try readColorConfig(&r, h.profile);
        h.refresh_flags = 0xff;
        try readFrameSize(&r, &h);
        try readRenderSize(&r);
    } else {
        h.intra_only = if (h.show_frame) false else try r.flag();
        h.reset_context = if (h.error_res) 0 else @intCast(try r.bits(2));
        if (h.intra_only) {
            try readSyncCode(&r);
            if (h.profile > 0) try readColorConfig(&r, h.profile);
            h.refresh_flags = @intCast(try r.bits(8));
            try readFrameSize(&r, &h);
            try readRenderSize(&r);
        } else {
            h.refresh_flags = @intCast(try r.bits(8));
            for (0..3) |i| {
                h.ref_idx[i] = @intCast(try r.bits(3));
                h.sign_bias[1 + i] = try r.bit();
            }
            // frame_size_with_refs: a reference's size, or its own
            var found = false;
            for (0..3) |_| {
                if (try r.flag()) {
                    found = true;
                    break;
                }
            }
            if (!found) try readFrameSize(&r, &h);
            try readRenderSize(&r);
            h.allow_hp = try r.flag();
            h.interp = if (try r.flag()) INTERP_SWITCHABLE else @intCast(try r.bits(2));
        }
    }
    if (!h.error_res) {
        h.refresh_context = try r.flag();
        h.parallel = try r.flag();
    } else {
        h.refresh_context = false;
        h.parallel = true;
    }
    h.context_idx = @intCast(try r.bits(2));
    h.raw_context_idx = h.context_idx;

    var seg = st.seg;
    var lf = st.lf;
    h.reset = h.intra() or h.error_res;
    if (h.reset) {
        // setup_past_independence: features cleared, deltas defaulted,
        // sign biases zeroed, context 0
        seg.abs_delta = false;
        seg.enabled = [_][4]bool{.{ false, false, false, false }} ** 8;
        seg.data = [_][4]i16{.{ 0, 0, 0, 0 }} ** 8;
        lf = .{};
        h.sign_bias = .{ 0, 0, 0, 0 };
    }

    // loop_filter_params
    h.lf_level = @intCast(try r.bits(6));
    h.lf_sharpness = @intCast(try r.bits(3));
    h.lf_delta_enabled = try r.flag();
    if (h.lf_delta_enabled) {
        if (try r.flag()) {
            for (&lf.ref) |*d| {
                if (try r.flag()) d.* = @intCast(try r.signed(6));
            }
            for (&lf.mode) |*d| {
                if (try r.flag()) d.* = @intCast(try r.signed(6));
            }
        }
    }

    // quantization_params
    h.base_q = @intCast(try r.bits(8));
    inline for (.{ &h.dq_y_dc, &h.dq_uv_dc, &h.dq_uv_ac }) |dq| {
        dq.* = if (try r.flag()) @intCast(try r.signed(4)) else 0;
    }
    h.lossless = h.base_q == 0 and h.dq_y_dc == 0 and h.dq_uv_dc == 0 and h.dq_uv_ac == 0;

    // segmentation_params
    h.seg_enabled = try r.flag();
    if (h.seg_enabled) {
        h.seg_update_map = try r.flag();
        if (h.seg_update_map) {
            for (&seg.tree_probs) |*t| t.* = if (try r.flag()) @intCast(try r.bits(8)) else 255;
            h.seg_temporal = try r.flag();
            for (&seg.pred_probs) |*t| {
                t.* = if (h.seg_temporal and try r.flag()) @intCast(try r.bits(8)) else 255;
            }
        }
        h.seg_update_data = try r.flag();
        if (h.seg_update_data) {
            seg.abs_delta = try r.flag();
            const bits = [4]u5{ 8, 6, 2, 0 };
            const maxes = [4]i16{ 255, 63, 3, 0 };
            const signed = [4]bool{ true, true, false, false };
            for (0..8) |s| {
                for (0..4) |f| {
                    seg.enabled[s][f] = try r.flag();
                    var v: i16 = 0;
                    if (seg.enabled[s][f]) {
                        v = @min(@as(i16, @intCast(try r.bits(bits[f]))), maxes[f]);
                        if (signed[f] and try r.flag()) v = -v;
                    }
                    seg.data[s][f] = v;
                }
            }
        }
    }

    // tile_info
    const width = if (h.width != 0) h.width else va_width;
    const t = tileColsLog2(width);
    var cols: u32 = t.min;
    while (cols < t.max and try r.flag()) cols += 1;
    h.log2_tile_cols = @intCast(cols);
    h.log2_tile_rows = @intCast(try r.bit());
    if (h.log2_tile_rows != 0) h.log2_tile_rows += try r.bit();

    h.compressed_bytes = try r.bits(16);
    if (h.compressed_bytes == 0) return error.Corrupt;
    h.uncompressed_bytes = r.bytes();

    // the context the frame starts from, after the reset rules (context 0
    // after a reset, which may itself have been reset)
    if (h.reset) {
        const all = h.key or h.error_res or h.reset_context == 3;
        const zero_reset = h.reset_context == 2 and h.raw_context_idx == 0;
        p.fc = if (all or zero_reset) tables.DEFAULT else st.ctx[0];
        h.context_idx = 0;
    } else {
        p.fc = st.ctx[h.context_idx];
    }
    p.hdr = h;
    p.seg = seg;
    p.lf = lf;
}

fn readColorConfig(r: *BitReader, profile: u2) Error!void {
    if (profile >= 2) _ = try r.bit(); // ten_or_twelve_bit
    const color_space = try r.bits(3);
    if (color_space != 7) {
        _ = try r.bit(); // color_range
        if (profile == 1 or profile == 3) _ = try r.bits(3);
    } else {
        if (profile == 1 or profile == 3) _ = try r.bit() else return error.Corrupt;
    }
}

/// The compressed header (the specification's compressed_header()): its
/// forward updates into `p.fc`, the frame's tx and reference modes into
/// `p.hdr`.
fn parseCompressed(data: []const u8, p: *Parsed) Error!void {
    var d = try BoolDecoder.init(data);
    const h = &p.hdr;
    const fc = &p.fc;
    // read_tx_mode
    if (h.lossless) {
        h.tx_mode = 0;
    } else {
        h.tx_mode = @intCast(d.literal(2));
        if (h.tx_mode == 3) h.tx_mode += d.read(128);
    }
    if (h.tx_mode == TX_MODE_SELECT) {
        diffUpdateAll(&d, std.mem.asBytes(&fc.tx8));
        diffUpdateAll(&d, std.mem.asBytes(&fc.tx16));
        diffUpdateAll(&d, std.mem.asBytes(&fc.tx32));
    }
    // read_coef_probs: up to the largest transform the mode allows
    const max_tx: usize = @min(h.tx_mode, 3);
    for (0..max_tx + 1) |t| {
        if (d.read(128) == 1) {
            for (0..2) |i| for (0..2) |j| for (0..6) |k| {
                const contexts: usize = if (k == 0) 3 else 6;
                for (0..contexts) |l| diffUpdateAll(&d, &fc.coef[t][i][j][k][l]);
            };
        }
    }
    diffUpdateAll(&d, &fc.skip);
    if (!h.intra()) {
        diffUpdateAll(&d, std.mem.asBytes(&fc.inter_mode));
        if (h.interp == INTERP_SWITCHABLE) diffUpdateAll(&d, std.mem.asBytes(&fc.interp));
        diffUpdateAll(&d, &fc.intra_inter);
        // frame_reference_mode
        const compound_allowed = h.sign_bias[2] != h.sign_bias[1] or h.sign_bias[3] != h.sign_bias[1];
        h.reference_mode = 0;
        if (compound_allowed and d.read(128) == 1) {
            h.reference_mode = if (d.read(128) == 1) 2 else 1;
        }
        if (h.reference_mode != 0) {
            // setup_compound_reference_mode: 1 last, 2 golden, 3 altref
            if (h.sign_bias[1] == h.sign_bias[2]) {
                h.comp_fixed_ref = 3;
                h.comp_var_ref = .{ 1, 2 };
            } else if (h.sign_bias[1] == h.sign_bias[3]) {
                h.comp_fixed_ref = 2;
                h.comp_var_ref = .{ 1, 3 };
            } else {
                h.comp_fixed_ref = 1;
                h.comp_var_ref = .{ 2, 3 };
            }
        }
        if (h.reference_mode == 2) diffUpdateAll(&d, &fc.comp_inter);
        if (h.reference_mode != 1) diffUpdateAll(&d, std.mem.asBytes(&fc.single_ref));
        if (h.reference_mode != 0) diffUpdateAll(&d, &fc.comp_ref);
        diffUpdateAll(&d, std.mem.asBytes(&fc.y_mode));
        diffUpdateAll(&d, std.mem.asBytes(&fc.partition));
        // mv_probs
        mvUpdate(&d, &fc.mv_joints);
        for (&fc.mv) |*c| {
            mvUpdate(&d, (&c.sign)[0..1]);
            mvUpdate(&d, &c.classes);
            mvUpdate(&d, &c.class0);
            mvUpdate(&d, &c.bits);
        }
        for (&fc.mv) |*c| {
            mvUpdate(&d, std.mem.asBytes(&c.class0_fp));
            mvUpdate(&d, &c.fp);
        }
        if (h.allow_hp) {
            for (&fc.mv) |*c| {
                mvUpdate(&d, (&c.class0_hp)[0..1]);
                mvUpdate(&d, (&c.hp)[0..1]);
            }
        }
    }
}

// ── Backward adaptation (libvpx vp9_adapt_coef_probs, _mode_probs, _mv_probs)

/// libvpx's tree: a node's two children at 2n and 2n+1, a value <= 0 is
/// the leaf -value.
const Tree = []const i8;
const INTRA_MODE_TREE = [_]i8{ 0, 2, -9, 4, -1, 6, 8, 12, -2, 10, -4, -5, -3, 14, -8, 16, -6, -7 };
/// leaves: NEAREST 0, NEAR 1, ZERO 2, NEW 3
const INTER_MODE_TREE = [_]i8{ -2, 2, 0, 4, -1, -3 };
const PARTITION_TREE = [_]i8{ 0, 2, -1, 4, -2, -3 };
const INTERP_TREE = [_]i8{ 0, 2, -1, -2 };
const MV_JOINT_TREE = [_]i8{ 0, 2, -1, 4, -2, -3 };
const MV_CLASS_TREE = [_]i8{ 0, 2, -1, 4, 6, 8, -2, -3, 10, 12, -4, -5, -6, 14, 16, 18, -7, -8, -9, -10 };
const MV_CLASS0_TREE = [_]i8{ 0, -1 };
const MV_FP_TREE = [_]i8{ 0, 2, -1, 4, -2, -3 };

const COUNT_TO_UPDATE_FACTOR = [21]u32{ 0, 6, 12, 19, 25, 32, 38, 44, 51, 57, 64, 70, 76, 83, 89, 96, 102, 108, 115, 121, 128 };

fn getProb(num: u32, den: u32) u8 {
    const p: u64 = (@as(u64, num) * 256 + (den >> 1)) / den;
    return @intCast(std.math.clamp(p, 1, 255));
}

fn weighted(p1: u8, p2: u8, factor: u32) u8 {
    return @intCast((@as(u32, p1) * (256 - factor) + @as(u32, p2) * factor + 128) >> 8);
}

/// merge_probs: the coefficients' adaptation
fn mergeProbs(pre: u8, ct0: u32, ct1: u32, count_sat: u32, max_factor: u32) u8 {
    const den = ct0 +% ct1;
    const prob: u8 = if (den == 0) 128 else getProb(ct0, den);
    const count = @min(den, count_sat);
    return weighted(pre, prob, max_factor * count / count_sat);
}

/// mode_mv_merge_probs: the modes' and motion vectors' adaptation
fn modeMvMerge(pre: u8, ct0: u32, ct1: u32) u8 {
    const den = ct0 +% ct1;
    if (den == 0) return pre;
    const count = @min(den, 20);
    return weighted(pre, getProb(ct0, den), COUNT_TO_UPDATE_FACTOR[count]);
}

fn treeMergeAt(i: usize, tree: Tree, pre: []const u8, counts: []const u32, out: []u8) u32 {
    const l = tree[i];
    const left = if (l <= 0) counts[@intCast(-l)] else treeMergeAt(@intCast(l), tree, pre, counts, out);
    const r = tree[i + 1];
    const right = if (r <= 0) counts[@intCast(-r)] else treeMergeAt(@intCast(r), tree, pre, counts, out);
    out[i >> 1] = modeMvMerge(pre[i >> 1], left, right);
    return left +% right;
}

fn treeMerge(tree: Tree, pre: []const u8, counts: []const u32, out: []u8) void {
    _ = treeMergeAt(0, tree, pre, counts, out);
}

/// What adaptation needs to know of the frame.
pub const AdaptFlags = struct {
    /// a key frame or intra-only: coefficients only
    intra: bool,
    /// the previous frame was a key frame (coefficients adapt faster)
    last_key: bool,
    interp_switchable: bool,
    tx_select: bool,
    allow_hp: bool,
};

/// The backward adaptation: `cur` (the frame's probabilities after its
/// forward updates) becomes the adapted context, from `pre` (the saved
/// context the frame started from) and the decoder's counts. What VP9 does
/// not adapt keeps `cur`'s values.
pub fn adapt(pre: *const FrameContext, cur: *FrameContext, c: *const HwCounts, f: AdaptFlags) void {
    // coefficients
    const factor: u32 = if (f.intra) 112 else if (f.last_key) 128 else 112;
    for (0..4) |t| for (0..2) |i| for (0..2) |j| for (0..6) |k| {
        const contexts: usize = if (k == 0) 3 else 6;
        for (0..contexts) |l| {
            const n = c.countCoeffs[t][i][j][k][l];
            const eob = c.countEobs[t][i][j][k][l];
            const branch = [3][2]u32{ .{ n[3], eob -% n[3] }, .{ n[0], n[1] +% n[2] }, .{ n[1], n[2] } };
            for (0..3) |m| {
                cur.coef[t][i][j][k][l][m] = mergeProbs(pre.coef[t][i][j][k][l][m], branch[m][0], branch[m][1], 24, factor);
            }
        }
    };
    if (f.intra) return;

    // modes
    for (0..4) |i| cur.intra_inter[i] = modeMvMerge(pre.intra_inter[i], c.intra_inter_count[i][0], c.intra_inter_count[i][1]);
    for (0..5) |i| cur.comp_inter[i] = modeMvMerge(pre.comp_inter[i], c.comp_inter_count[i][0], c.comp_inter_count[i][1]);
    for (0..5) |i| cur.comp_ref[i] = modeMvMerge(pre.comp_ref[i], c.comp_ref_count[i][0], c.comp_ref_count[i][1]);
    for (0..5) |i| for (0..2) |j| {
        cur.single_ref[i][j] = modeMvMerge(pre.single_ref[i][j], c.single_ref_count[i][j][0], c.single_ref_count[i][j][1]);
    };
    for (0..7) |i| {
        const n = c.inter_mode_counts[i];
        const counts = [4]u32{ n[1][0], n[2][0], n[0][0], n[2][1] };
        treeMerge(&INTER_MODE_TREE, &pre.inter_mode[i], &counts, &cur.inter_mode[i]);
    }
    for (0..4) |i| treeMerge(&INTRA_MODE_TREE, &pre.y_mode[i], &c.sb_ymode_counts[i], &cur.y_mode[i]);
    for (0..10) |i| treeMerge(&INTRA_MODE_TREE, &pre.uv_mode[i], &c.uv_mode_counts[i], &cur.uv_mode[i]);
    for (0..16) |i| treeMerge(&PARTITION_TREE, &pre.partition[i], &c.partition_counts[i], &cur.partition[i]);
    if (f.interp_switchable) {
        for (0..4) |i| treeMerge(&INTERP_TREE, &pre.interp[i], &c.switchable_interp_counts[i], &cur.interp[i]);
    }
    if (f.tx_select) {
        for (0..2) |i| {
            const c8 = c.tx8x8_count[i];
            cur.tx8[i][0] = modeMvMerge(pre.tx8[i][0], c8[0], c8[1]);
            const c16 = c.tx16x16_count[i];
            cur.tx16[i][0] = modeMvMerge(pre.tx16[i][0], c16[0], c16[1] +% c16[2]);
            cur.tx16[i][1] = modeMvMerge(pre.tx16[i][1], c16[1], c16[2]);
            const c32 = c.tx32x32_count[i];
            cur.tx32[i][0] = modeMvMerge(pre.tx32[i][0], c32[0], c32[1] +% c32[2] +% c32[3]);
            cur.tx32[i][1] = modeMvMerge(pre.tx32[i][1], c32[1], c32[2] +% c32[3]);
            cur.tx32[i][2] = modeMvMerge(pre.tx32[i][2], c32[2], c32[3]);
        }
    }
    for (0..3) |i| cur.skip[i] = modeMvMerge(pre.skip[i], c.mbskip_count[i][0], c.mbskip_count[i][1]);

    // motion vectors
    const mv = &c.nmvcount;
    treeMerge(&MV_JOINT_TREE, &pre.mv_joints, &mv.joints, &cur.mv_joints);
    for (0..2) |i| {
        const p = &pre.mv[i];
        const o = &cur.mv[i];
        o.sign = modeMvMerge(p.sign, mv.sign[i][0], mv.sign[i][1]);
        treeMerge(&MV_CLASS_TREE, &p.classes, &mv.classes[i], &o.classes);
        treeMerge(&MV_CLASS0_TREE, &p.class0, &mv.class0[i], &o.class0);
        for (0..10) |j| o.bits[j] = modeMvMerge(p.bits[j], mv.bits[i][j][0], mv.bits[i][j][1]);
        for (0..2) |j| treeMerge(&MV_FP_TREE, &p.class0_fp[j], &mv.class0_fp[i][j], &o.class0_fp[j]);
        treeMerge(&MV_FP_TREE, &p.fp, &mv.fp[i], &o.fp);
        if (f.allow_hp) {
            o.class0_hp = modeMvMerge(p.class0_hp, mv.class0_hp[i][0], mv.class0_hp[i][1]);
            o.hp = modeMvMerge(p.hp, mv.hp[i][0], mv.hp[i][1]);
        }
    }
}

// ── The decoder's tables from a frame ───────────────────────────────────────

/// The probability table for a frame whose (forward-updated) probabilities
/// are `fc`.
pub fn hwProbs(fc: *const FrameContext, seg: *const Segmentation, seg_temporal: bool) HwProbs {
    var p = std.mem.zeroes(HwProbs);
    for (0..10) |a| for (0..10) |l| {
        p.kf_bmode_prob[a][l] = tables.KF_Y_MODE[a][l][0..8].*;
        p.kf_bmode_probB[a][l][0] = tables.KF_Y_MODE[a][l][8];
    };
    p.mb_segment_tree_probs = seg.tree_probs;
    p.segment_pred_probs = if (seg_temporal) seg.pred_probs else .{ 255, 255, 255 };
    for (0..10) |i| {
        p.kf_uv_mode_prob[i] = tables.KF_UV_MODE[i][0..8].*;
        p.kf_uv_mode_probB[i][0] = tables.KF_UV_MODE[i][8];
    }
    const a = &p.a;
    for (0..7) |i| a.inter_mode_prob[i] = .{ fc.inter_mode[i][0], fc.inter_mode[i][1], fc.inter_mode[i][2], 0 };
    a.intra_inter_prob = fc.intra_inter;
    for (0..10) |i| {
        a.uv_mode_prob[i] = fc.uv_mode[i][0..8].*;
        a.uv_mode_probB[i][0] = fc.uv_mode[i][8];
    }
    a.tx8x8_prob = fc.tx8;
    a.tx16x16_prob = fc.tx16;
    a.tx32x32_prob = fc.tx32;
    for (0..4) |i| {
        a.sb_ymode_prob[i] = fc.y_mode[i][0..8].*;
        a.sb_ymode_probB[i][0] = fc.y_mode[i][8];
    }
    for (0..16) |k| {
        a.partition_prob[0][k] = .{ tables.KF_PARTITION[k][0], tables.KF_PARTITION[k][1], tables.KF_PARTITION[k][2], 0 };
        a.partition_prob[1][k] = .{ fc.partition[k][0], fc.partition[k][1], fc.partition[k][2], 0 };
    }
    a.switchable_interp_prob = fc.interp;
    a.comp_inter_prob = fc.comp_inter;
    a.mbskip_probs = fc.skip;
    a.nmvc.joints = fc.mv_joints;
    for (0..2) |i| {
        const c = &fc.mv[i];
        a.nmvc.sign[i] = c.sign;
        a.nmvc.class0[i] = c.class0;
        a.nmvc.fp[i] = c.fp;
        a.nmvc.class0_hp[i] = c.class0_hp;
        a.nmvc.hp[i] = c.hp;
        a.nmvc.classes[i] = c.classes;
        a.nmvc.class0_fp[i] = c.class0_fp;
        a.nmvc.bits[i] = c.bits;
    }
    a.single_ref_prob = fc.single_ref;
    a.comp_ref_prob = fc.comp_ref;
    for (0..4) |t| for (0..2) |i| for (0..2) |j| for (0..6) |k| for (0..6) |l| {
        const q = fc.coef[t][i][j][k][l];
        a.probCoeffs[t][i][j][k][l] = .{ q[0], q[1], q[2], 0 };
    };
    return p;
}

/// The tile size buffer: each tile's width and height in superblocks, row
/// by row, and the two constants the Tegra decoder sets.
pub fn tileSizes(out: []u8, width: u32, height: u32, log2_cols: u3, log2_rows: u2) void {
    @memset(out[0..TILE_BYTES], 0);
    const sb_cols = (width + 63) / 64;
    const sb_rows = (height + 63) / 64;
    const cols = @as(u32, 1) << log2_cols;
    const rows = @as(u32, 1) << log2_rows;
    var n: usize = 0;
    for (0..rows) |i| for (0..cols) |j| {
        const ii: u32 = @intCast(i);
        const jj: u32 = @intCast(j);
        const w = (sb_cols * (jj + 1) >> log2_cols) - (sb_cols * jj >> log2_cols);
        const h = (sb_rows * (ii + 1) >> log2_rows) - (sb_rows * ii >> log2_rows);
        std.mem.writeInt(u16, out[n * 4 ..][0..2], @intCast(w), .little);
        std.mem.writeInt(u16, out[n * 4 + 2 ..][0..2], @intCast(h), .little);
        n += 1;
    };
    std.mem.writeInt(u16, out[0x37a * 2 ..][0..2], 9, .little);
    std.mem.writeInt(u16, out[0x37b * 2 ..][0..2], 1, .little);
}

// ── The module ──────────────────────────────────────────────────────────────

/// A reference slot's last frame: which surface, at what size.
const RefSlot = struct {
    id: u32 = va.INVALID_ID,
    width: u16 = 0,
    height: u16 = 0,
};

/// The previous decoded frame.
const Last = struct {
    valid: bool = false,
    key: bool = false,
    show: bool = false,
    width: u32 = 0,
    height: u32 = 0,
};

pub const State = struct {
    /// the context's largest picture (the scratch's size)
    width: u32,
    height: u32,
    /// VP9's four saved probability contexts
    ctx: [4]FrameContext,
    /// the current frame's probabilities (after its forward updates)
    fc: FrameContext,
    seg: Segmentation = .{},
    lf: LoopFilterDeltas = .{},
    hdr: Header = .{},
    pic: vav.PictureParameterBufferVP9 = undefined,
    have_pic: bool = false,
    have_slice: bool = false,
    /// the slice data taken: headers parsed, tiles in the stream
    have_frame: bool = false,
    slice_offset: u32 = 0,
    slice_size: u32 = 0,
    stream_len: u32 = 0,
    last: Last = .{},
    slots: [8]RefSlot = [_]RefSlot{.{}} ** 8,
    /// which segment map holds the latest map, and whether it is to be
    /// read as all zero (a reset since)
    seg_latest: u1 = 0,
    seg_zero: bool = true,
    /// which co-located motion buffer the last frame wrote
    mv_latest: u1 = 0,
    /// a decode whose counts `after` adapts from
    pending: ?struct { idx: u2, flags: AdaptFlags } = null,

    pub fn init(width: u32, height: u32) State {
        return .{
            .width = width,
            .height = height,
            .ctx = [_]FrameContext{tables.DEFAULT} ** 4,
            .fc = tables.DEFAULT,
        };
    }
};

pub fn begin(st: *State) void {
    st.have_pic = false;
    st.have_slice = false;
    st.have_frame = false;
    st.stream_len = 0;
}

pub fn take(st: *State, b: codec.Buffer, slot: codec.Slot) va.Status {
    switch (b.kind) {
        va.PICTURE_PARAMETER_BUFFER => {
            if (b.size < @sizeOf(vav.PictureParameterBufferVP9) or b.count < 1 or b.data.len < @sizeOf(vav.PictureParameterBufferVP9)) return va.ERROR_INVALID_BUFFER;
            const p = b.element(vav.PictureParameterBufferVP9, 0);
            // profile 0 (8-bit 4:2:0) and 2 (10-bit 4:2:0: a P010 target)
            if (p.profile != 0 and p.profile != 2) return va.ERROR_UNSUPPORTED_PROFILE;
            if (p.bit_depth != (if (p.profile == 2) @as(u8, 10) else 8) or p.pic_fields.subsampling_x != 1 or p.pic_fields.subsampling_y != 1) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            if (p.frame_width == 0 or p.frame_height == 0) return va.ERROR_INVALID_PARAMETER;
            st.pic = p;
            st.have_pic = true;
            return va.SUCCESS;
        },
        va.SLICE_PARAMETER_BUFFER => {
            if (b.size < @sizeOf(vav.SliceParameterBufferVP9) or b.count < 1 or b.data.len < @sizeOf(vav.SliceParameterBufferVP9)) return va.ERROR_INVALID_BUFFER;
            // (one slice: the frame)
            const s = b.element(vav.SliceParameterBufferVP9, 0);
            st.slice_offset = s.slice_data_offset;
            st.slice_size = s.slice_data_size;
            st.have_slice = true;
            return va.SUCCESS;
        },
        va.SLICE_DATA_BUFFER => {
            if (!st.have_pic or !st.have_slice) return va.ERROR_INVALID_PARAMETER;
            const end_at = @as(u64, st.slice_offset) + st.slice_size;
            if (end_at > b.data.len) return va.ERROR_INVALID_BUFFER;
            return frame(st, b.data[st.slice_offset..@intCast(end_at)], slot);
        },
        else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
    }
}

/// One frame's bytes: both headers parsed, the tiles into the stream.
fn frame(st: *State, data: []const u8, slot: codec.Slot) va.Status {
    var p: Parsed = undefined;
    parseUncompressed(st, data, st.pic.frame_width, &p) catch return va.ERROR_INVALID_PARAMETER;
    const h = &p.hdr;
    if (h.profile != st.pic.profile) return va.ERROR_UNSUPPORTED_PROFILE;
    if (h.width != 0 and (h.width != st.pic.frame_width or h.height != st.pic.frame_height)) return va.ERROR_INVALID_PARAMETER;
    // (VA's header sizes must be the bitstream's: else this parse is wrong)
    if (h.uncompressed_bytes != st.pic.frame_header_length_in_bytes or h.compressed_bytes != st.pic.first_partition_size) return va.ERROR_INVALID_PARAMETER;
    const tiles_at = h.uncompressed_bytes + h.compressed_bytes;
    if (tiles_at > data.len) return va.ERROR_INVALID_PARAMETER;
    parseCompressed(data[h.uncompressed_bytes..tiles_at], &p) catch return va.ERROR_INVALID_PARAMETER;
    const tiles = data[tiles_at..];
    if (tiles.len > slot.stream.len) return va.ERROR_NOT_ENOUGH_BUFFER;
    @memcpy(slot.stream[0..tiles.len], tiles);
    // (a little zero padding after the tiles, where it fits)
    const pad = @min(slot.stream.len - tiles.len, 16);
    @memset(slot.stream[tiles.len..][0..pad], 0);

    // the reset's effects on the saved contexts (setup_past_independence)
    if (h.reset) {
        if (h.key or h.error_res or h.reset_context == 3) {
            st.ctx = [_]FrameContext{tables.DEFAULT} ** 4;
        } else if (h.reset_context == 2) {
            st.ctx[h.raw_context_idx] = tables.DEFAULT;
        }
        st.seg_zero = true;
    }
    st.fc = p.fc;
    st.seg = p.seg;
    st.lf = p.lf;
    st.hdr = p.hdr;
    st.stream_len = @intCast(tiles.len);
    st.have_frame = true;
    return va.SUCCESS;
}

pub fn end(st: *State, slot: codec.Slot, scratch: codec.Scratch, pic: codec.Picture, lookup: codec.Lookup, out: *codec.End) va.Status {
    if (!st.have_frame) return va.ERROR_INVALID_PARAMETER;
    const h = st.hdr;
    const width: u32 = st.pic.frame_width;
    const height: u32 = st.pic.frame_height;
    if (width > st.width or height > st.height) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    const l = layout(st.width, st.height);
    if (scratch.cpu.len < l.total or slot.pic.len < MAX_PIC_BYTES or slot.aux.len < MAX_AUX_BYTES or slot.push.len < PUSH_DWORDS) return va.ERROR_OPERATION_FAILED;
    // profile 2: 10-bit samples into a P010 target, every stride the
    // decoder is given counting 2-byte samples (half the bytes: "the
    // stride is divided by 2 when the depth is > 8", NVIDIA's Tegra
    // driver), v1.bit_depth 10
    const depth: u32 = st.pic.bit_depth;
    if (!pic.target.holds(depth)) return va.ERROR_INVALID_SURFACE;
    const unit: u32 = if (depth > 8) 2 else 1;

    // the references: last, golden, altref (none for an intra frame: the
    // target's planes, never address 0)
    var luma = [_]u64{pic.target.luma} ** nvdec.SLOTS;
    var chroma = [_]u64{pic.target.chroma} ** nvdec.SLOTS;
    var s = Vp9Pic{};
    for (0..3) |i| {
        var dims = RefDims{
            .width = @intCast(width),
            .height = @intCast(height),
            .stride = .{ @truncate(pic.target.pitch_luma / unit), @truncate(pic.target.pitch_chroma / unit) },
        };
        if (!h.intra()) {
            const k = h.ref_idx[i];
            const id = st.pic.reference_frames[k];
            if (lookup.surface(id)) |r| {
                luma[i] = r.luma;
                chroma[i] = r.chroma;
                const known = st.slots[k].id == id and st.slots[k].width != 0;
                dims = .{
                    .width = if (known) st.slots[k].width else @truncate(r.width),
                    .height = if (known) st.slots[k].height else @truncate(r.height),
                    .stride = .{ @truncate(r.pitch_luma / unit), @truncate(r.pitch_chroma / unit) },
                };
            }
        }
        s.refs[i] = dims;
    }

    // the setup
    s.stream_len = st.stream_len;
    s.gptimer_timeout_value = nvdec.GPTIMER_TIMEOUT;
    s.surface = .{ .tileformat = 1, .gob_height = pic.gob_height };
    s.Vp9BsdCtrlOffset = @intCast(l.bsd >> 8);
    s.width = @intCast(width);
    s.height = @intCast(height);
    s.framestride = .{ @truncate(pic.target.pitch_luma / unit), @truncate(pic.target.pitch_chroma / unit) };
    s.flags = .{
        .keyFrame = @intFromBool(h.key),
        .prevIsKeyFrame = @intFromBool(st.last.valid and st.last.key),
        .resolutionChange = @intFromBool(st.last.valid and (st.last.width != width or st.last.height != height)),
        .errorResilient = @intFromBool(h.error_res),
        .prevShowFrame = @intFromBool(st.last.valid and st.last.show),
        .intraOnly = @intFromBool(h.intra_only),
    };
    s.refFrameSignBias = .{ 0, h.sign_bias[1], h.sign_bias[2], h.sign_bias[3] };
    s.loopFilterLevel = @intCast(h.lf_level);
    s.loopFilterSharpness = @intCast(h.lf_sharpness);
    s.qpYAc = h.base_q;
    s.qpYDc = h.dq_y_dc;
    s.qpChAc = h.dq_uv_dc;
    s.qpChDc = h.dq_uv_ac;
    s.lossless = @intFromBool(h.lossless);
    s.transform_mode = @intCast(h.tx_mode);
    s.allow_high_precision_mv = @intFromBool(h.allow_hp and !h.intra());
    s.mcomp_filter_type = @intCast(h.interp);
    s.comp_pred_mode = @intCast(h.reference_mode);
    s.comp_fixed_ref = @intCast(h.comp_fixed_ref);
    s.comp_var_ref = .{ @intCast(h.comp_var_ref[0]), @intCast(h.comp_var_ref[1]) };
    s.log2_tile_columns = @intCast(h.log2_tile_cols);
    s.log2_tile_rows = @intCast(h.log2_tile_rows);
    s.segmentEnabled = @intFromBool(h.seg_enabled);
    s.segmentMapUpdate = @intFromBool(h.seg_update_map);
    s.segmentMapTemporalUpdate = @intFromBool(h.seg_temporal);
    s.segmentFeatureMode = @intFromBool(st.seg.abs_delta);
    for (0..8) |i| {
        for (0..4) |f| s.segmentFeatureEnable[i][f] = @intFromBool(st.seg.enabled[i][f]);
        s.segmentFeatureData[i] = .{ st.seg.data[i][0], st.seg.data[i][1], st.seg.data[i][2], 0 };
    }
    s.modeRefLfEnabled = @intFromBool(h.lf_delta_enabled);
    s.mbRefLfDelta = st.lf.ref;
    s.mbModeLfDelta = st.lf.mode;
    s.v1.Vp9FltAboveOffset = @intCast(l.above >> 8);
    s.v1.bits.bit_depth = @intCast(depth);
    @memcpy(slot.pic[0..@sizeOf(Vp9Pic)], std.mem.asBytes(&s));

    // the side buffers
    const probs = hwProbs(&st.fc, &st.seg, h.seg_temporal);
    @memcpy(slot.aux[AUX_PROBS..][0..@sizeOf(HwProbs)], std.mem.asBytes(&probs));
    tileSizes(slot.aux[AUX_TILES..], width, height, h.log2_tile_cols, h.log2_tile_rows);

    // the ping-pong buffers
    const seg_read = if (st.seg_zero) l.seg[2] else l.seg[st.seg_latest];
    const seg_write = l.seg[1 - @as(usize, st.seg_latest)];
    const mv_read = l.mv[st.mv_latest];
    const mv_write = l.mv[1 - @as(usize, st.mv_latest)];

    // the pushbuffer
    const o = slot.push;
    var n: usize = 0;
    codec.bind(o, &n);
    codec.put(o, &n, nvdec.SET_APPLICATION_ID, APPLICATION_ID_VP9);
    codec.put(o, &n, nvdec.SET_CONTROL_PARAMS, codec.controlParams(CODEC_TYPE_VP9, 0));
    codec.put(o, &n, nvdec.SET_PICTURE_INDEX, pic.picture_index);
    codec.put(o, &n, nvdec.SET_DRV_PIC_SETUP_OFFSET, nvdec.shifted(slot.pic_va));
    codec.put(o, &n, nvdec.SET_IN_BUF_BASE_OFFSET, nvdec.shifted(slot.stream_va));
    codec.put(o, &n, nvdec.SET_NVDEC_STATUS_OFFSET, nvdec.shifted(slot.status_va));
    codec.put(o, &n, VP9_SET_PROB_TAB_BUF_OFFSET, nvdec.shifted(slot.aux_va + AUX_PROBS));
    codec.put(o, &n, VP9_SET_CTX_COUNTER_BUF_OFFSET, nvdec.shifted(scratch.va + l.counts));
    codec.put(o, &n, VP9_SET_TILE_SIZE_BUF_OFFSET, nvdec.shifted(slot.aux_va + AUX_TILES));
    codec.put(o, &n, VP9_SET_COL_MVWRITE_BUF_OFFSET, nvdec.shifted(scratch.va + mv_write));
    codec.put(o, &n, VP9_SET_COL_MVREAD_BUF_OFFSET, nvdec.shifted(scratch.va + mv_read));
    codec.put(o, &n, VP9_SET_SEGMENT_READ_BUF_OFFSET, nvdec.shifted(scratch.va + seg_read));
    codec.put(o, &n, VP9_SET_SEGMENT_WRITE_BUF_OFFSET, nvdec.shifted(scratch.va + seg_write));
    codec.put(o, &n, VP9_SET_FILTER_BUFFER_OFFSET, nvdec.shifted(scratch.va + l.filter));
    luma[3] = pic.target.luma;
    chroma[3] = pic.target.chroma;
    codec.pictures(o, &n, luma, chroma);
    codec.execute(o, &n);
    std.debug.assert(n == PUSH_DWORDS);

    // what this frame leaves for the next
    const adapt_due = !h.error_res and !h.parallel and h.refresh_context;
    if (h.refresh_context and h.parallel) st.ctx[h.context_idx] = st.fc;
    st.pending = if (adapt_due) .{ .idx = h.context_idx, .flags = .{
        .intra = h.intra(),
        .last_key = st.last.valid and st.last.key,
        .interp_switchable = h.interp == INTERP_SWITCHABLE,
        .tx_select = h.tx_mode == TX_MODE_SELECT,
        .allow_hp = h.allow_hp,
    } } else null;
    if (h.seg_enabled and h.seg_update_map) {
        st.seg_latest = 1 - st.seg_latest;
        st.seg_zero = false;
    }
    st.mv_latest = 1 - st.mv_latest;
    for (0..8) |i| {
        if (h.refresh_flags & (@as(u8, 1) << @intCast(i)) != 0) {
            st.slots[i] = .{ .id = pic.target_id, .width = @intCast(width), .height = @intCast(height) };
        }
    }
    st.last = .{ .valid = true, .key = h.key, .show = h.show_frame, .width = width, .height = height };
    st.have_frame = false;
    out.* = .{ .dwords = n, .wait = adapt_due };
    return va.SUCCESS;
}

/// The decode `end` asked to wait for is done: VP9's backward adaptation
/// from the decoder's counts, saved into the frame's context. The driver
/// calls it before the next picture's buffers are taken.
pub fn after(st: *State, scratch: codec.Scratch) void {
    const p = st.pending orelse return;
    st.pending = null;
    const l = layout(st.width, st.height);
    if (scratch.cpu.len < l.total) return;
    const src = scratch.cpu[l.counts..][0..@sizeOf(HwCounts)];
    var counts: HwCounts = undefined;
    @memcpy(std.mem.asBytes(&counts), src);
    adapt(&st.ctx[p.idx], &st.fc, &counts, p.flags);
    st.ctx[p.idx] = st.fc;
    // (no decode is running: start the next frame's counts from zero)
    @memset(src, 0);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "vp9: every declaration compiles" {
    testing.refAllDecls(@This());
}

test "vp9: the decoder's structs as nvdec_drv.h lays them out" {
    // (the offsets are asserted at compile time; the bit fields here)
    var s = Vp9Pic{};
    s.surface = .{ .tileformat = 1, .gob_height = 2 };
    s.flags = .{ .keyFrame = 1, .prevShowFrame = 1 };
    s.v1.bits.bit_depth = 8;
    const b = std.mem.asBytes(&s);
    try testing.expectEqual(@as(u8, 1 | (2 << 2)), b[0x40]);
    // (gcc: keyFrame and prevShowFrame set is 0x11)
    try testing.expectEqual(@as(u8, 0x11), b[0x68]);
    try testing.expectEqual(@as(u32, 8 << 1), std.mem.readInt(u32, b[0xf0..][0..4], .little));
    try testing.expectEqual(@as(usize, 0xf00), AUX_TILES);
    try testing.expectEqual(@as(usize, 0x1600), MAX_AUX_BYTES);
    try testing.expectEqual(@as(usize, 68), PUSH_DWORDS);
}

/// libvpx's boolean encoder (vpx_dsp/bitwriter), for the tests.
const BoolEncoder = struct {
    buf: []u8,
    pos: usize = 0,
    low: u32 = 0,
    range: u32 = 255,
    count: i32 = -24,

    fn write(e: *BoolEncoder, bit: u1, p: u8) void {
        const split = 1 + (((e.range - 1) * @as(u32, p)) >> 8);
        var range = if (bit == 1) e.range - split else split;
        var low = e.low;
        if (bit == 1) low += split;
        var shift: i32 = @clz(@as(u8, @intCast(range)));
        range <<= @intCast(shift);
        e.count += shift;
        if (e.count >= 0) {
            const offset: i32 = shift - e.count;
            if (((low << @intCast(offset - 1)) & 0x8000_0000) != 0) {
                var x = e.pos;
                while (x > 0 and e.buf[x - 1] == 0xff) : (x -= 1) e.buf[x - 1] = 0;
                e.buf[x - 1] += 1;
            }
            e.buf[e.pos] = @truncate(low >> @intCast(24 - offset));
            e.pos += 1;
            low <<= @intCast(offset);
            shift = e.count;
            low &= 0xff_ffff;
            e.count -= 8;
        }
        low <<= @intCast(shift);
        e.low = low;
        e.range = range;
    }

    fn finish(e: *BoolEncoder) void {
        for (0..32) |_| e.write(0, 128);
    }
};

const Lcg = struct {
    s: u64,
    fn next(l: *Lcg) u32 {
        l.s = l.s *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(l.s >> 33);
    }
};

test "vp9: the boolean decoder on hand-made bytes" {
    // 0x7f: below the first split (marker 0, range 128); then each 0xff
    // bit lands above the split: ones
    var d = try BoolDecoder.init(&.{ 0x7f, 0xff, 0xff });
    try testing.expectEqual(@as(u32, 0xff), d.literal(8));
    // all zero: zeros, past the end too
    d = try BoolDecoder.init(&.{0x00});
    try testing.expectEqual(@as(u32, 0), d.literal(16));
    // a first byte of 0x80 or more: the marker bit is 1
    try testing.expectError(error.Corrupt, BoolDecoder.init(&.{ 0x80, 0 }));
    try testing.expectError(error.Corrupt, BoolDecoder.init(&.{}));
    // by hand: 0x40 then 0x00: marker 0 (64 < 128, range 128); p 128:
    // split 64, value 64 is not below it: 1 (value 0, range 64 -> 128);
    // then value 0: 0
    d = try BoolDecoder.init(&.{ 0x40, 0x00 });
    try testing.expectEqual(@as(u1, 1), d.read(128));
    try testing.expectEqual(@as(u1, 0), d.read(128));
}

test "vp9: the boolean decoder reads what libvpx's encoder wrote" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    var e = BoolEncoder{ .buf = &buf };
    e.write(0, 128); // the marker
    var rng = Lcg{ .s = 7 };
    var bits: [6000]u1 = undefined;
    var probs: [6000]u8 = undefined;
    for (&bits, &probs) |*b, *p| {
        p.* = @intCast(1 + rng.next() % 255);
        // (biased as the probability says, mostly)
        b.* = @intFromBool(rng.next() % 256 >= p.*);
        e.write(b.*, p.*);
    }
    e.finish();
    var d = try BoolDecoder.init(buf[0..e.pos]);
    for (bits, probs) |b, p| try testing.expectEqual(b, d.read(p));
}

test "vp9: diff updates against libvpx's inverse remap" {
    // (inv_remap_prob by hand: delta 0 -> table 7, m - 1 = 127, 254 <= 255:
    // 1 + inv_recenter(7, 127) = 1 + 127 - 4 = 124)
    try testing.expectEqual(@as(u8, 124), invRemapProb(0, 128));
    // (m - 1 = 199, 398 > 255: 255 - inv_recenter(7, 55) = 255 - 51 = 204)
    try testing.expectEqual(@as(u8, 204), invRemapProb(0, 200));
    // (delta 20 -> table 1: 1 + inv_recenter(1, 9) = 1 + 9 - 1 = 9)
    try testing.expectEqual(@as(u8, 9), invRemapProb(20, 10));
}

fn fillLcg(bytes: []u8, rng: *Lcg) void {
    for (bytes) |*b| b.* = @intCast(1 + rng.next() % 255);
}

test "vp9: backward adaptation matches libvpx on made-up counts" {
    // libvpx v1.14.0's vp9_adapt_coef_probs / _mode_probs / _mv_probs on
    // the same LCG-made contexts and counts (CRC-32s of its result)
    const Case = struct { seed: u64, key: bool, intra_only: bool, last_key: bool, switchable: bool, txsel: bool, hp: bool, crc: u32 };
    const cases = [_]Case{
        .{ .seed = 1, .key = false, .intra_only = false, .last_key = false, .switchable = true, .txsel = true, .hp = true, .crc = 0x732f53ca },
        .{ .seed = 2, .key = false, .intra_only = false, .last_key = true, .switchable = false, .txsel = false, .hp = false, .crc = 0xf71ee28a },
        .{ .seed = 3, .key = true, .intra_only = false, .last_key = false, .switchable = true, .txsel = true, .hp = true, .crc = 0xd1b1bfe4 },
        .{ .seed = 4, .key = false, .intra_only = true, .last_key = true, .switchable = true, .txsel = true, .hp = true, .crc = 0x1d64e51c },
    };
    for (cases) |c| {
        var rng = Lcg{ .s = c.seed };
        var pre: FrameContext = undefined;
        var cur: FrameContext = undefined;
        fillLcg(std.mem.asBytes(&pre), &rng);
        fillLcg(std.mem.asBytes(&cur), &rng);
        var counts: HwCounts = undefined;
        const head = std.mem.asBytes(&counts)[0..@offsetOf(HwCounts, "countEobs")];
        var at: usize = 0;
        while (at < head.len) : (at += 4) std.mem.writeInt(u32, head[at..][0..4], rng.next() % 40, .little);
        for (0..4) |t| for (0..2) |i| for (0..2) |j| for (0..6) |k| for (0..6) |l| {
            counts.countEobs[t][i][j][k][l] = counts.countCoeffs[t][i][j][k][l][3] + rng.next() % 40;
        };
        adapt(&pre, &cur, &counts, .{ .intra = c.key or c.intra_only, .last_key = c.last_key, .interp_switchable = c.switchable, .tx_select = c.txsel, .allow_hp = c.hp });
        try testing.expectEqual(c.crc, std.hash.Crc32.hash(std.mem.asBytes(&cur)));
    }
}

test "vp9: tile sizes" {
    var buf: [TILE_BYTES]u8 = undefined;
    // 1920x1080: 30x17 superblocks, 4 columns, 2 rows
    tileSizes(&buf, 1920, 1080, 2, 1);
    const want = [_]u16{ 7, 8, 8, 8, 7, 8, 8, 8, 7, 9, 8, 9, 7, 9, 8, 9 };
    for (want, 0..) |v, i| try testing.expectEqual(v, std.mem.readInt(u16, buf[i * 2 ..][0..2], .little));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[32..][0..2], .little));
    try testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, buf[0x37a * 2 ..][0..2], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[0x37b * 2 ..][0..2], .little));
}

test "vp9: the scratch layout" {
    const l = layout(512, 64);
    try testing.expectEqual(@as(usize, 0x3400), l.seg[0]);
    try testing.expectEqual(@as(usize, 0x100), l.seg_bytes);
    try testing.expectEqual(@as(usize, 0x3700), l.mv[0]);
    try testing.expectEqual(@as(usize, 0x2000), l.mv_bytes);
    try testing.expectEqual(@as(usize, 0x7700), l.filter);
    try testing.expectEqual(@as(usize, 64 * 912), l.bsd);
    try testing.expectEqual(@as(usize, 64 * 988), l.above);
    try testing.expectEqual(@as(usize, 64 * 988 + 10 * 2048), l.filter_bytes);
    try testing.expectEqual(l.total, scratchBytes(512, 64));
    // 4K: everything 256-byte aligned
    const k = layout(3840, 2160);
    for ([_]usize{ k.counts, k.seg[1], k.seg[2], k.mv[1], k.filter, k.bsd, k.above, k.total }) |o| try testing.expectEqual(@as(usize, 0), o & 0xff);
}

const TestCtx = struct {
    var fs: codec.FakeSlot = .{};
    var scratch: [256 << 10]u8 align(256) = undefined;
    var st: State = undefined;
};

fn vaPicture(f: ClipFrame, refs: [8]u32) vav.PictureParameterBufferVP9 {
    var p = std.mem.zeroes(vav.PictureParameterBufferVP9);
    p.frame_width = 512;
    p.frame_height = 64;
    p.reference_frames = refs;
    p.pic_fields = .{ .subsampling_x = 1, .subsampling_y = 1, .frame_type = @intFromBool(!f.key), .show_frame = 1 };
    p.frame_header_length_in_bytes = f.uncompressed;
    p.first_partition_size = f.compressed;
    p.bit_depth = 8;
    return p;
}

fn buffer(kind: u32, bytes: []const u8) codec.Buffer {
    return .{ .kind = kind, .size = @intCast(bytes.len), .count = 1, .data = bytes };
}

test "vp9: a libvpx clip through take, end and after, against libvpx" {
    const st = &TestCtx.st;
    st.* = State.init(512, 64);
    var surfaces = codec.FakeSurfaces{ .w = 512, .h = 64, .n = 8 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(512, 64)], .va = 0x20_0000_0000 };
    @memset(scratch.cpu, 0);
    const l = layout(512, 64);
    // VA's reference slots as FFmpeg fills them: the surface each slot holds
    var refs = [_]u32{va.INVALID_ID} ** 8;
    for (CLIP, 0..) |f, i| {
        const target: u32 = @intCast(i + 1);
        const slot = TestCtx.fs.slot();
        begin(st);
        const pic = vaPicture(f, refs);
        try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
        var sp = std.mem.zeroes(vav.SliceParameterBufferVP9);
        sp.slice_data_size = @intCast(f.bytes.len);
        try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
        try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_DATA_BUFFER, f.bytes), slot));

        // the headers as libvpx read them
        const h = st.hdr;
        try testing.expectEqual(f.key, h.key);
        try testing.expectEqual(f.tx_mode, h.tx_mode);
        try testing.expectEqual(f.interp, h.interp);
        try testing.expectEqual(f.q, h.base_q);
        try testing.expectEqual(f.lf, h.lf_level);
        try testing.expectEqual(f.seg, h.seg_enabled);
        try testing.expectEqual(f.log2_cols, h.log2_tile_cols);
        // the forward updates: the probabilities libvpx decoded the frame with
        try testing.expectEqual(f.crc_forward, std.hash.Crc32.hash(std.mem.asBytes(&st.fc)));
        // the tiles, after both headers
        const tiles = f.bytes[f.uncompressed + @as(usize, f.compressed) ..];
        try testing.expectEqual(@as(u32, @intCast(tiles.len)), st.stream_len);
        try testing.expectEqualSlices(u8, tiles, TestCtx.fs.stream[0..tiles.len]);

        var out: codec.End = undefined;
        const p = codec.Picture{ .target_id = target, .target = surfaces.lookup().surface(target).?, .gob_height = 2, .picture_index = @intCast(i) };
        try testing.expectEqual(va.SUCCESS, end(st, slot, scratch, p, surfaces.lookup(), &out));
        try testing.expectEqual(PUSH_DWORDS, out.dwords);
        // (every clip frame refreshes its context, frame-parallel off)
        try testing.expect(out.wait);

        // the probability table: the frame's probabilities, libvpx's order
        const probs = std.mem.bytesToValue(HwProbs, slot.aux[0..@sizeOf(HwProbs)]);
        try testing.expectEqualSlices(u8, st.fc.coef[1][0][1][2][3][0..3], probs.a.probCoeffs[1][0][1][2][3][0..3]);
        try testing.expectEqual(st.fc.y_mode[2][8], probs.a.sb_ymode_probB[2][0]);
        try testing.expectEqual(tables.KF_Y_MODE[3][5][7], probs.kf_bmode_prob[3][5][7]);
        try testing.expectEqual(st.fc.partition[13][2], probs.a.partition_prob[1][13][2]);
        try testing.expectEqual(tables.KF_PARTITION[13][2], probs.a.partition_prob[0][13][2]);
        try testing.expectEqual(st.fc.mv[1].class0_fp[1][2], probs.a.nmvc.class0_fp[1][1][2]);

        const setup = std.mem.bytesToValue(Vp9Pic, slot.pic[0..@sizeOf(Vp9Pic)]);
        try testing.expectEqual(@as(u32, @intCast(tiles.len)), setup.stream_len);
        try testing.expectEqual(nvdec.GPTIMER_TIMEOUT, setup.gptimer_timeout_value);
        try testing.expectEqual(@as(u3, 2), setup.surface.gob_height);
        try testing.expectEqual(@as(u2, 1), setup.surface.tileformat);
        try testing.expectEqual(@as(u4, 8), setup.v1.bits.bit_depth);
        try testing.expectEqual(@as(u16, 512), setup.width);
        try testing.expectEqual([2]u16{ 512, 512 }, setup.framestride);
        try testing.expectEqual(@as(u1, @intFromBool(f.key)), setup.flags.keyFrame);
        try testing.expectEqual(@as(u1, @intFromBool(i == 1)), setup.flags.prevIsKeyFrame);
        try testing.expectEqual(@as(u1, @intFromBool(i > 0)), setup.flags.prevShowFrame);
        try testing.expectEqual(f.q, setup.qpYAc);

        if (i == 1) {
            // the inter frame's setup: its references, segmentation, tiles
            for (setup.refs) |r| try testing.expectEqual(RefDims{ .width = 512, .height = 64, .stride = .{ 512, 512 } }, r);
            try testing.expectEqual(@as(i8, 1), setup.allow_high_precision_mv);
            try testing.expectEqual(@as(i8, 4), setup.mcomp_filter_type);
            try testing.expectEqual(@as(i8, 3), setup.transform_mode);
            try testing.expectEqual(@as(i8, 1), setup.log2_tile_columns);
            try testing.expectEqual(@as(u8, 1), setup.segmentEnabled);
            try testing.expectEqual(@as(u8, 1), setup.segmentMapUpdate);
            try testing.expectEqual(@as(u8, 1), setup.segmentMapTemporalUpdate);
            try testing.expectEqual(@as(u8, 0), setup.segmentFeatureMode);
            // (libvpx: segments 1 and 2 have a quantizer delta of -27)
            try testing.expectEqual([4]u8{ 1, 0, 0, 0 }, setup.segmentFeatureEnable[1]);
            try testing.expectEqual([4]i16{ -27, 0, 0, 0 }, setup.segmentFeatureData[2]);
            try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, setup.segmentFeatureEnable[3]);
            try testing.expectEqual(@as(i8, 1), setup.modeRefLfEnabled);
            try testing.expectEqual([4]i8{ 1, 0, -1, -1 }, setup.mbRefLfDelta);
            try testing.expectEqual(@as(u32, 0xe4), setup.Vp9BsdCtrlOffset);
            try testing.expectEqual(@as(u32, 0xf7), setup.v1.Vp9FltAboveOffset);
            try testing.expectEqual([4]u8{ 255, 255, 128, 1 }, probs.mb_segment_tree_probs[0..4].*);
            try testing.expectEqual([3]u8{ 213, 1, 1 }, probs.segment_pred_probs);
            // two tile columns of 4 superblocks, one row
            for ([_]u16{ 4, 1, 4, 1, 0 }, 0..) |v, k| try testing.expectEqual(v, std.mem.readInt(u16, slot.aux[AUX_TILES + k * 2 ..][0..2], .little));

            // the pushbuffer, word by word
            const want = [_]u32{
                0x2001_0000, 0x001f_cfb0, // SET_OBJECT
                0x2001_0080, 9, // SET_APPLICATION_ID VP9
                0x2001_0100, 9 | (1 << 4) | (1 << 6) | (1 << 13), // SET_CONTROL_PARAMS
                0x2001_0103, 1, // SET_PICTURE_INDEX
                0x2001_0101, 0x1000_0004, // SET_DRV_PIC_SETUP_OFFSET
                0x2001_0102, 0x1000_0100, // SET_IN_BUF_BASE_OFFSET
                0x2001_0109, 0x1000_0014, // SET_NVDEC_STATUS_OFFSET
                0x2001_0170, 0x1000_0020, // VP9_SET_PROB_TAB_BUF_OFFSET
                0x2001_0171, 0x2000_0000, // VP9_SET_CTX_COUNTER_BUF_OFFSET
                0x2001_0174, 0x1000_002f, // VP9_SET_TILE_SIZE_BUF_OFFSET
                0x2001_0175, 0x2000_0037, // VP9_SET_COL_MVWRITE_BUF_OFFSET (mv 0)
                0x2001_0176, 0x2000_0057, // VP9_SET_COL_MVREAD_BUF_OFFSET (mv 1: the key frame's)
                0x2001_0172, 0x2000_0036, // VP9_SET_SEGMENT_READ_BUF_OFFSET (the zero map)
                0x2001_0173, 0x2000_0035, // VP9_SET_SEGMENT_WRITE_BUF_OFFSET (map 1)
                0x2001_0177, 0x2000_0077, // VP9_SET_FILTER_BUFFER_OFFSET
                0x2011_010c, // SET_PICTURE_LUMA_OFFSET0, 17
                0x4001_0000, 0x4001_0000, 0x4001_0000, 0x4002_0000, // last, golden, altref: surface 1; current: 2
            };
            try testing.expectEqualSlices(u32, &want, slot.push[0..want.len]);
            // (the unused slots: the target)
            for (slot.push[want.len .. want.len + 13]) |w| try testing.expectEqual(@as(u32, 0x4002_0000), w);
            try testing.expectEqual(@as(u32, 0x2011_011d), slot.push[48]); // SET_PICTURE_CHROMA_OFFSET0, 17
            try testing.expectEqual(@as(u32, 0x4001_8000), slot.push[49]);
            try testing.expectEqual(@as(u32, 0x4002_8000), slot.push[52]);
            try testing.expectEqual(@as(u32, 0x4002_8000), slot.push[65]);
            try testing.expectEqual([2]u32{ 0x2001_00c0, 0 }, slot.push[66..68].*); // EXECUTE
        }
        if (i == 2) {
            // frame 1 wrote map 1: read it, write map 0
            try testing.expectEqual(@as(u32, 0x2000_0035), slot.push[25]);
            try testing.expectEqual(@as(u32, 0x2000_0034), slot.push[27]);
        }

        // the decoder's counts (libvpx's, in the decoder's layout), then
        // the adaptation libvpx did
        const cw = scratch.cpu[l.counts..][0..@sizeOf(HwCounts)];
        @memset(cw, 0);
        for (f.counts) |c| std.mem.writeInt(u32, cw[c[0] * 4 ..][0..4], c[1], .little);
        after(st, scratch);
        try testing.expectEqual(f.crc_adapted, std.hash.Crc32.hash(std.mem.asBytes(&st.ctx[0])));
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, cw[0..4], .little));
        for (&refs, 0..) |*r, k| {
            if (st.hdr.refresh_flags & (@as(u8, 1) << @intCast(k)) != 0) r.* = target;
        }
    }
}

test "vp9: profile 2 (10-bit): taken, its setup's strides in 2-byte samples and bit depth 10, a P010 target only" {
    const st = &TestCtx.st;
    st.* = State.init(512, 64);
    var surfaces = codec.FakeSurfaces{ .w = 512, .h = 64, .n = 8 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(512, 64)], .va = 0x20_0000_0000 };
    @memset(scratch.cpu, 0);
    const slot = TestCtx.fs.slot();
    begin(st);
    var pic = vaPicture(CLIP[0], [_]u32{va.INVALID_ID} ** 8);
    // profile 2: 10 bits only (12 and 8 refused)
    pic.profile = 2;
    pic.bit_depth = 12;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    pic.bit_depth = 8;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    pic.bit_depth = 10;
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    // (the clip is profile 0: its header says so, and is refused for a
    // profile-2 picture)
    var sp = std.mem.zeroes(vav.SliceParameterBufferVP9);
    sp.slice_data_size = @intCast(CLIP[0].bytes.len);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, take(st, buffer(va.SLICE_DATA_BUFFER, CLIP[0].bytes), slot));
    // the setup for a 10-bit frame: the clip's key frame parsed as profile
    // 0, then its picture's depth made 10
    begin(st);
    pic.profile = 0;
    pic.bit_depth = 8;
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_DATA_BUFFER, CLIP[0].bytes), slot));
    st.pic.bit_depth = 10;
    var out: codec.End = undefined;
    const nv12 = surfaces.lookup().surface(1).?;
    try testing.expectEqual(va.ERROR_INVALID_SURFACE, end(st, slot, scratch, .{ .target_id = 1, .target = nv12, .gob_height = 0, .picture_index = 0 }, surfaces.lookup(), &out));
    var p010 = nv12;
    p010.sample_bytes = 2;
    p010.pitch_luma = 1024;
    p010.pitch_chroma = 1024;
    try testing.expectEqual(va.SUCCESS, end(st, slot, scratch, .{ .target_id = 1, .target = p010, .gob_height = 0, .picture_index = 0 }, surfaces.lookup(), &out));
    const setup = std.mem.bytesToValue(Vp9Pic, slot.pic[0..@sizeOf(Vp9Pic)]);
    try testing.expectEqual(@as(u4, 10), setup.v1.bits.bit_depth);
    try testing.expectEqual([2]u16{ 512, 512 }, setup.framestride);
    for (setup.refs) |r| try testing.expectEqual([2]u16{ 512, 512 }, r.stride);
}

test "vp9: refused and malformed input" {
    const st = &TestCtx.st;
    st.* = State.init(512, 64);
    const slot = TestCtx.fs.slot();
    begin(st);
    var pic = vaPicture(CLIP[0], [_]u32{va.INVALID_ID} ** 8);
    pic.profile = 1;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    pic.profile = 0;
    pic.bit_depth = 10;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    pic.bit_depth = 8;
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)[0..40]), slot));
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    // slice data before its parameters
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(st, buffer(va.SLICE_DATA_BUFFER, CLIP[0].bytes), slot));
    var sp = std.mem.zeroes(vav.SliceParameterBufferVP9);
    sp.slice_data_size = @intCast(CLIP[0].bytes.len + 1);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    // past the buffer's end
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, take(st, buffer(va.SLICE_DATA_BUFFER, CLIP[0].bytes), slot));
    sp.slice_data_size = @intCast(CLIP[0].bytes.len);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    // a header length VA got wrong
    pic.frame_header_length_in_bytes += 1;
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(st, buffer(va.SLICE_DATA_BUFFER, CLIP[0].bytes), slot));
    // a broken frame marker
    pic.frame_header_length_in_bytes -= 1;
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    var bad: [64]u8 = undefined;
    @memcpy(&bad, CLIP[0].bytes[0..64]);
    bad[0] ^= 0xc0;
    sp.slice_data_size = 64;
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(st, buffer(va.SLICE_DATA_BUFFER, &bad), slot));
    try testing.expectEqual(va.ERROR_UNSUPPORTED_BUFFERTYPE, take(st, buffer(va.IQ_MATRIX_BUFFER, &bad), slot));
    // nothing taken: no picture to end
    var out: codec.End = undefined;
    var surfaces = codec.FakeSurfaces{ .w = 512, .h = 64, .n = 2 };
    const p = codec.Picture{ .target_id = 1, .target = surfaces.lookup().surface(1).?, .gob_height = 0, .picture_index = 0 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(512, 64)], .va = 0x20_0000_0000 };
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, end(st, slot, scratch, p, surfaces.lookup(), &out));
    // a frame larger than the context
    st.* = State.init(256, 64);
    begin(st);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    sp.slice_data_size = @intCast(CLIP[0].bytes.len);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_DATA_BUFFER, CLIP[0].bytes), slot));
    try testing.expectEqual(va.ERROR_RESOLUTION_NOT_SUPPORTED, end(st, slot, scratch, p, surfaces.lookup(), &out));
}

test "vp9: a compound-prediction compressed header written by libvpx's bool encoder" {
    // (the clips have no compound prediction: this header is made here,
    // in the syntax's order, with two updates to look for)
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    var e = BoolEncoder{ .buf = &buf };
    e.write(0, 128); // the marker
    const lit = struct {
        fn w(enc: *BoolEncoder, v: u32, n: u5) void {
            var k: u5 = n;
            while (k > 0) {
                k -= 1;
                enc.write(@intCast((v >> k) & 1), 128);
            }
        }
    }.w;
    lit(&e, 3, 2); // tx_mode ALLOW_32X32 ...
    e.write(0, 128); // ... not TX_MODE_SELECT
    for (0..4) |_| e.write(0, 128); // no coefficient updates, 4x4 to 32x32
    for (0..3) |_| e.write(0, DIFF_UPDATE_PROB); // skip
    for (0..21) |_| e.write(0, DIFF_UPDATE_PROB); // inter modes
    for (0..8) |_| e.write(0, DIFF_UPDATE_PROB); // switchable filters
    for (0..4) |_| e.write(0, DIFF_UPDATE_PROB); // intra/inter
    e.write(1, 128); // compound allowed: not single ...
    e.write(1, 128); // ... but select
    // comp_inter[0]: an update of delta 0 (subexp: 0, then 4 bits of 0)
    e.write(1, DIFF_UPDATE_PROB);
    e.write(0, 128);
    lit(&e, 0, 4);
    for (0..4) |_| e.write(0, DIFF_UPDATE_PROB);
    for (0..10) |_| e.write(0, DIFF_UPDATE_PROB); // single_ref
    for (0..5) |_| e.write(0, DIFF_UPDATE_PROB); // comp_ref
    for (0..36) |_| e.write(0, DIFF_UPDATE_PROB); // y modes
    for (0..48) |_| e.write(0, DIFF_UPDATE_PROB); // partitions
    for (0..3) |_| e.write(0, MV_UPDATE_PROB); // joints
    for (0..2) |_| for (0..22) |_| e.write(0, MV_UPDATE_PROB); // sign, classes, class0, bits
    for (0..2) |_| for (0..9) |_| e.write(0, MV_UPDATE_PROB); // class0_fp, fp
    for (0..3) |_| e.write(0, MV_UPDATE_PROB); // class0_hp, hp, class0_hp
    e.write(1, MV_UPDATE_PROB); // the horizontal hp: (0x55 << 1) | 1
    lit(&e, 0x55, 7);
    e.finish();

    var p: Parsed = undefined;
    p.hdr = .{ .interp = INTERP_SWITCHABLE, .allow_hp = true, .base_q = 60, .sign_bias = .{ 0, 0, 0, 1 } };
    p.fc = tables.DEFAULT;
    try parseCompressed(buf[0..e.pos], &p);
    try testing.expectEqual(@as(u3, 3), p.hdr.tx_mode);
    try testing.expectEqual(@as(u2, 2), p.hdr.reference_mode);
    // last and golden agree: altref is the fixed reference
    try testing.expectEqual(@as(u2, 3), p.hdr.comp_fixed_ref);
    try testing.expectEqual([2]u2{ 1, 2 }, p.hdr.comp_var_ref);
    try testing.expectEqual(invRemapProb(0, tables.DEFAULT.comp_inter[0]), p.fc.comp_inter[0]);
    try testing.expectEqual(tables.DEFAULT.comp_inter[1], p.fc.comp_inter[1]);
    try testing.expectEqual(@as(u8, 0xab), p.fc.mv[1].hp);
    try testing.expectEqual(tables.DEFAULT.mv[0].hp, p.fc.mv[0].hp);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&tables.DEFAULT.coef), std.mem.asBytes(&p.fc.coef));

    // the same with golden's bias apart from last's: golden is fixed
    p.hdr = .{ .interp = INTERP_SWITCHABLE, .allow_hp = true, .base_q = 60, .sign_bias = .{ 0, 0, 1, 0 } };
    p.fc = tables.DEFAULT;
    try parseCompressed(buf[0..e.pos], &p);
    try testing.expectEqual(@as(u2, 2), p.hdr.comp_fixed_ref);
    try testing.expectEqual([2]u2{ 1, 3 }, p.hdr.comp_var_ref);
}

test "vp9: the reset rules for intra-only frames" {
    // an intra-only frame, profile 0: frame marker, profile 0, not
    // show-existing, inter type, hidden, not error resilient, intra_only,
    // reset_frame_context, sync code, refresh flags, size, render size,
    // refresh_frame_context, frame-parallel, frame_context_idx 2
    var bits: [256]u1 = undefined;
    var n: usize = 0;
    const put = struct {
        fn f(b: []u1, at: *usize, v: u32, k: u5) void {
            var i: u5 = k;
            while (i > 0) {
                i -= 1;
                b[at.*] = @intCast((v >> i) & 1);
                at.* += 1;
            }
        }
    }.f;
    const st = &TestCtx.st;
    for ([_]u2{ 0, 2, 3 }) |reset| {
        n = 0;
        put(&bits, &n, 2, 2);
        put(&bits, &n, 0, 2);
        put(&bits, &n, 0, 1);
        put(&bits, &n, 1, 1); // inter frame type
        put(&bits, &n, 0, 1); // hidden
        put(&bits, &n, 0, 1); // not error resilient
        put(&bits, &n, 1, 1); // intra_only
        put(&bits, &n, reset, 2);
        put(&bits, &n, 0x498342, 24);
        put(&bits, &n, 0x04, 8); // refresh slot 2
        put(&bits, &n, 63, 16);
        put(&bits, &n, 63, 16);
        put(&bits, &n, 0, 1);
        put(&bits, &n, 1, 1); // refresh_frame_context
        put(&bits, &n, 0, 1); // not frame-parallel
        put(&bits, &n, 2, 2); // frame_context_idx 2
        put(&bits, &n, 0, 6 + 3 + 1); // loop filter: level, sharpness, no deltas
        put(&bits, &n, 0, 8 + 3); // q 0, no deltas: lossless
        put(&bits, &n, 0, 1); // no segmentation
        // (64 wide: no tile column bits) tile rows 0
        put(&bits, &n, 0, 1);
        put(&bits, &n, 1, 16); // header_size_in_bytes
        var bytes = [_]u8{0} ** 32;
        for (bits[0..n], 0..) |b, i| bytes[i / 8] |= @as(u8, b) << @intCast(7 - i % 8);

        st.* = State.init(64, 64);
        // saved contexts made distinct
        for (&st.ctx, 0..) |*c, i| c.skip[0] = @intCast(10 + i);
        st.pic = std.mem.zeroes(vav.PictureParameterBufferVP9);
        st.pic.frame_width = 64;
        st.pic.frame_height = 64;
        var p: Parsed = undefined;
        try parseUncompressed(st, &bytes, 64, &p);
        try testing.expect(p.hdr.intra_only and p.hdr.reset and !p.hdr.key);
        try testing.expectEqual(@as(u8, 0x04), p.hdr.refresh_flags);
        try testing.expectEqual(@as(u32, 64), p.hdr.width);
        try testing.expectEqual(@as(u2, 0), p.hdr.context_idx);
        try testing.expectEqual(@as(u2, 2), p.hdr.raw_context_idx);
        try testing.expect(p.hdr.lossless);
        try testing.expectEqual((n + 7) / 8, p.hdr.uncompressed_bytes);
        // libvpx: 0/1 keep the contexts and use context 0; 2 resets only
        // context 2 (and still uses 0); 3 resets all
        try testing.expectEqual(@as(u8, if (reset == 3) 192 else 10), p.fc.skip[0]);
    }
}

/// A clip through take, end and after: each frame's headers, forward
/// updates and saved context against libvpx's.
fn runClip(clip: []const ClipFrame) !void {
    const st = &TestCtx.st;
    const w: u32 = clip[0].width;
    const h: u32 = clip[0].height;
    st.* = State.init(w, h);
    var surfaces = codec.FakeSurfaces{ .w = w, .h = h, .n = 8 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(w, h)], .va = 0x20_0000_0000 };
    @memset(scratch.cpu, 0);
    const l = layout(w, h);
    var refs = [_]u32{va.INVALID_ID} ** 8;
    for (clip, 0..) |f, i| {
        const target: u32 = @intCast(i % 8 + 1);
        const slot = TestCtx.fs.slot();
        begin(st);
        var pic = vaPicture(f, refs);
        pic.frame_width = f.width;
        pic.frame_height = f.height;
        try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
        var sp = std.mem.zeroes(vav.SliceParameterBufferVP9);
        sp.slice_data_size = @intCast(f.bytes.len);
        try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
        try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_DATA_BUFFER, f.bytes), slot));
        const hd = st.hdr;
        try testing.expectEqual(f.key, hd.key);
        try testing.expectEqual(f.show, hd.show_frame);
        try testing.expectEqual(f.intra_only, hd.intra_only);
        try testing.expectEqual(f.error_res, hd.error_res);
        try testing.expectEqual(f.refresh, hd.refresh_context);
        try testing.expectEqual(f.parallel, hd.parallel);
        try testing.expectEqual(f.ctx, hd.context_idx);
        try testing.expectEqual(f.tx_mode, hd.tx_mode);
        try testing.expectEqual(f.interp, hd.interp);
        try testing.expectEqual(f.reference_mode, hd.reference_mode);
        try testing.expectEqual(f.q, hd.base_q);
        try testing.expectEqual(f.lf, hd.lf_level);
        try testing.expectEqual(f.seg, hd.seg_enabled);
        try testing.expectEqual(f.log2_cols, hd.log2_tile_cols);
        try testing.expectEqual(f.crc_forward, std.hash.Crc32.hash(std.mem.asBytes(&st.fc)));

        var out: codec.End = undefined;
        const p = codec.Picture{ .target_id = target, .target = surfaces.lookup().surface(target).?, .gob_height = 0, .picture_index = @intCast(i) };
        try testing.expectEqual(va.SUCCESS, end(st, slot, scratch, p, surfaces.lookup(), &out));
        try testing.expectEqual(f.refresh and !f.parallel and !f.error_res, out.wait);
        if (out.wait) {
            const cw = scratch.cpu[l.counts..][0..@sizeOf(HwCounts)];
            @memset(cw, 0);
            for (f.counts) |c| std.mem.writeInt(u32, cw[c[0] * 4 ..][0..4], c[1], .little);
            after(st, scratch);
        }
        // the context saved (or, refreshing none, the frame's own)
        const saved = if (f.refresh) &st.ctx[f.ctx] else &st.fc;
        try testing.expectEqual(f.crc_adapted, std.hash.Crc32.hash(std.mem.asBytes(saved)));
        for (&refs, 0..) |*r, k| {
            if (st.hdr.refresh_flags & (@as(u8, 1) << @intCast(k)) != 0) r.* = target;
        }
    }
}

test "vp9: three libvpx clips, frame by frame, against libvpx" {
    // adapting, frame-parallel (the forward updates saved at end), error
    // resilient (every frame resets the contexts)
    try runClip(&CLIP);
    try runClip(&CLIP2);
    try runClip(&CLIP3);
}

// ── The clips, made by FFmpeg's libvpx-vp9 from its testsrc and decoded by
// libvpx v1.14.0, with what libvpx computed of each frame: header fields,
// CRC-32s of the probabilities after the forward updates and after the
// backward adaptation (FRAME_CONTEXT's bytes, which are this
// FrameContext's), and its counts in the decoder's layout (word index,
// value).
//   CLIP: 512x64, a key frame, then inter frames with segmentation
//         (temporal updates) and two tile columns; frame-parallel off.
//   CLIP2: 64x64, eight frames, frame-parallel on.
//   CLIP3: 64x64, three frames, error resilient.

// (made by gentest.py from libvpx v1.14.0's decode of the clips)
const ClipFrame = struct {
    bytes: []const u8,
    uncompressed: u8,
    compressed: u16,
    key: bool,
    show: bool,
    intra_only: bool,
    error_res: bool,
    refresh: bool,
    parallel: bool,
    ctx: u2,
    tx_mode: u3,
    interp: u3,
    reference_mode: u2,
    q: u8,
    lf: u6,
    seg: bool,
    log2_cols: u3,
    width: u16,
    height: u16,
    crc_forward: u32,
    crc_adapted: u32,
    counts: []const [2]u32,
};

const CLIP = [_]ClipFrame{
    .{
        .bytes = "\x82\x49\x83\x42\x00\x1f\xf0\x03\xf4\x04\x38\x24\x1c\x18\x42\x10\x02\xa0\x7f\x91\xa6\x2f\xdd\xf7" ++
            "\x45\xf8\xed\xe9\xd9\xb8\x05\x8f\xad\xd1\x78\xd3\x9f\x2b\xf7\xfd\xf6\x7d\x2d\xeb\xb7\xa7\x69\xb0" ++
            "\xd0\x3f\xe4\xf7\x5e\xf8\x35\x3f\xe8\xfd\x7f\x6d\xe1\x5e\xa7\xc7\xfc\x6f\xd9\x8a\x3f\x8f\xf4\xfe" ++
            "\x6f\x5b\xfa\xb3\x57\xe8\x15\x55\xf6\xce\xe2\xe0\xdd\xce\xc0\xdd\x82\x5a\x1c\xd5\x8a\x91\x36\xfe" ++
            "\xeb\xe2\xb2\x29\x00\x00\x00\x00\x02\x8f\x69\x87\xff\xff\x59\xaf\x10\x16\xaf\xca\xd8\xdf\xac\xce" ++
            "\x61\x5a\x76\xf7\x22\xba\x92\xb5\xb3\x0c\x15\x12\x59\xa9\x75\xdf\x85\x41\x0d\xd9\x5b\xb3\x35\x0f" ++
            "\xa0\xe1\x90\x8b\xff\x22\x3d\xcf\x1c\x76\x40\x71\xdb\xe2\x57\x50\xad\x92\x33\x42\x0a\x81\x20\xeb" ++
            "\x11\xfa\x63\x91\x1e\x56\x88\x7b\x3b\x40\x1e\x8a\x6c\xa8\x72\x7b\xe4\x7e\x3b\xf3\xa4\x97\xec\x62" ++
            "\x1e\xa4\xed\x22\x7a\x0f\x15\x21\xea\xbf\xb5\x80\xae\xbc\x08\x50\xdb\xf8\x39\xcc\x70\x4f\xf9\x07" ++
            "\x63\xf3\xc1\xad\x7b\x0d\xbd\x56\x18\x1f\x8a\x00\x43\xf6\x7e\xbb\x9a\xc4\x49\xd2\x98\x45\xd8\xb8" ++
            "\x51\x5c\x1d\x65\x88\xa7\x0c\x1f\xd9\xd7\x48\x37\xff\xfe\x52\xa5\x9d\x4f\x33\xab\x47\x8b\x27\x36" ++
            "\xaa\xfb\x8f\xc1\x95\x4f\x3e\xa9\x14\x7f\xf0\xd9\xa9\xb8\x2a\x3b\x28\x2a\x45\x07\x70\xa4\xaf\x28" ++
            "\x2c\xa2\xe4\xdd\x0c\xbf\x7f\x9a\x64\x9e\x08\x95\xf2\x43\x73\xe6\xf4\x29\x1f\x2b\x3b\xaf\x9b\x7c" ++
            "\x78\x87\x25\x3b\x2b\xcf\xaa\xab\x47\xee\x07\xe7\xe9\xac\x4c\x87\x40\x20\x50\xb0\x8c\x94\x8f\xf4" ++
            "\xb7\x4b\x9b\x38\x78\xc0\x83\xed\xd0\x99\x03\xc4\x82\x7c\xd7\xb9\xb5\x9c\x54\x87\x85\xb8\xe1\x6e" ++
            "\xb5\x21\xc6\x86\x1e\x33\xa8\xdf\x6b\x5b\xe8\xbf\x0a\xf5\x89\xb2\x9d\x5a\x8f\x58\xf2\x1f\xef\x86" ++
            "\x75\x9d\xff\xd8\x27\x5c\x41\x49\x90\x07\x3d\xdd\x41\x50\x81\xa8\x37\xc0\x87\x76\xbb\x2f\x75\x98" ++
            "\xd5\x99\xf1\xaf\x18\x26\x6b\x29\x08\x0e\x60\xd3\x64\xbd\x11\x20\xa3\xb1\x14\xd8\x33\xd2\xf5\xa0" ++
            "\xe4\x48\xaf\x45\xb3\xa4\xbe\xd0\x84\xd3\x62\xd0\x62\x52\xf7\xff\xe6\xd7\x2c\xdc\xa8\x73\x38\x43" ++
            "\x99\xa5\xb7\x9c\xef\x0f\x96\xed\xe8\x61\x7c\x27\xca\x5f\xd0\x5e\xa8\x8e\x15\x40\x49\x98\x6b\x26" ++
            "\x96\xf5\x2e\x5f\x7a\x19\xaf\xb0\x26\x37\x77\xc3\xff\xc7\xb2\xed\xbf\x9b\x48\x04\x42\x1c\x85\xbf" ++
            "\xf1\xf6\xfc\x95\x3c\x59\x3b\x43\x03\x0a\x4e\x63\x53\xcb\xa6\x8e\x00\x5a\x02\xc5\x5f\x7f\xff\xb4" ++
            "\xd4\x79\x1c\xe1\x76\x09\x66\x2f\x4c\x73\xe5\xd8\x2f\xdc\xc2\xde\x6e\x50\x32\xe2\xc4\xc6\xbf\x73" ++
            "\xe2\x70\x11\xc8\xea\x41\xcf\x28\xf5\x76\xf8\x6d\x93\x04\xf8\xa9\x3a\x56\xaf\xff\x9a\xd2\x53\xc6" ++
            "\xd6\x0d\x9d\x07\xcb\x25\x4b\x92\x86\x34\xd5\x5d\xee\xf0\x1c\xa4\xee\x0a\xc8\x27\x36\x18\x8c\x47" ++
            "\x04\x0d\x82\x2a\x45\x49\x44\xe4\xc3\xe3\x2d\x48\x1d\x10\xd2\xda\x6b\xdc\x0a\x7d\xf7\x5a\x0c\xd9" ++
            "\x5c\x9a\x70\xd7\x71\xe1\x05\x9e\x1f\xfa\xb0\x8c\x32\xf8\x87\x4b\xcf\x79\xf2\xdb\x61\xbc\x43\x95" ++
            "\xee\x5d\x05\xff\xff\xee\x38\xc3\xc9\x0b\x2c\xc3\x51\x9d\x56\xe6\x61\x82\x95\x8c\xa8\x3d\x49\x71" ++
            "\x69\x96\xf4\x6e\x20\x0c\xf4\x0e\x7f\x56\xa0\xb0\x56\x0c\x1b\xfa\x93\x0a\x6a\x5f\xfe\x0b\x0d\x57" ++
            "\x21\xda\xd3\x76\x7c\xb9\x48\xfd\xae\x03\x51\xaa\x3f\x16\xe6\x27\xdf\x8e\xcf\xab\xa0\x15\xbb\x76" ++
            "\xd2\x78\x5b\x39\x95\xa3\x87\x7d\x89\x30\xe7\x8f\x3e\x4a\x5e\x7b\xcf\x94\x7c\x81\xfb\x80\xaa\x31" ++
            "\x5d\x60\xe6\xca\x6b\x98\x98\x0f\x3b\xc1\x45\x9f\x2d\x7a\x8c\x5e\x00\x69\x87\xff\xff\x14\xe0\xf2" ++
            "\x2e\x1b\x7c\x52\xf4\x4d\xbb\x79\x43\xdc\xf4\xb0\x87\xab\x65\xb6\x5a\x5e\xa3\xe2\x0a\x5b\x96\xab" ++
            "\x79\xae\xad\xb7\x20\x34\xd2\x48\x00\xe1\xea\xff\x90\xd0\x54\x98\x81\x12\x5d\xf3\x02\xc0\x3a\x8e" ++
            "\x3f\x90\xb2\x54\x96\x61\x4f\x76\x4e\x1b\x14\xc9\x7e\x1a\x5b\xc9\xc5\x63\x9b\xcb\x32\x34\xd2\x3b" ++
            "\x31\x65\xa9\x14\xc9\x55\x9e\x13\x0d\x17\xa5\x1d\xe7\x79\x82\xf5\xc1\xfa\x8e\xd5\x33\x23\x7b\x15" ++
            "\x6d\x42\x7b\x03\x0d\xb5\x03\x75\x95\xe5\x7f\xb4\x00\x71\xdb\x36\x89\x2b\xc2\x8d\xf4\x52\xc7\xc5" ++
            "\x85\x59\xf7\x06\x77\x80\xa8\x42\x92\x46\x00\xe7\x6d\x68\x23\x52\x3c\xcb\x8e\x0b\xa5\xf5\xed\x01" ++
            "\xb2\xf8\x45\x87\xff\xfe\x6c\x03\x31\x86\x34\x46\x3c\x60\xd5\x33\xb3\x2e\x44\xb2\xf1\x8d\x82\x4d" ++
            "\x60\x12\x18\xe4\x55\x98\x65\x1e\xd3\x7f\xc3\xba\x87\xd8\xcf\x9a\x9e\xd7\x09\xab\xf7\x8b\x26\x85" ++
            "\xbf\xfe\x03\x46\xe8\xc0\x80\x34\x79\x84\x10\x4f\x33\xbd\xe1\x17\x9e\x50\xcf\x8f\xc1\x39\xb9\x2a" ++
            "\x1e\xf1\x07\x24\x07\x7d\xf1\x9b\x92\x43\xf7\x89\x75\x6a\x15\x1e\x61\x2c\x7f\xb1\xbb\x7b\xa0\xfc" ++
            "\xcb\xc5\x89\x17\x82\x47\xcc\xc1\xf4\x01\xf5\x56\x2b\xb8\x94\xa7\x53\xd9\x61\xc8\xde\xde\x0e\x80" ++
            "\x77\x7a\x38\x07\x95\xb5\x69\x1a\xc2\xef\xff\xd4\x27\xff\xff\xf2\x2a\xce\x40\xe6\x9f\x4d\x33\xd7" ++
            "\xc1\xc9\x1f\xc0\x47\x1d\x55\xd9\x0f\x33\x35\x7d\x5b\x4f\x97\x4b\x2e\x54\x06\x7b\x02\x6d\x93\xde" ++
            "\x64\x67\xca\xaa\xe0\x19\x19\x69\x97\xe5\x6e\xf4\xe8\x8d\x6e\x7d\xfa\xf6\xd2\x1b\x44\x56\x75\x7e" ++
            "\xf6\x8e\x3f\x20\xe5\xf0\x7a\xbd\xb9\x03\x95\x32\x30\xb7\xe2\xff\xdf\x2c\xe1\x3c\xf4\x54\x87\x43" ++
            "\x80\xc7\x7b\xd6\x5b\x23\x60\x56\xff\xfa\xfa\x2e\xd4\xac\x06\xa4\xa2\x5a\xea\x89\x53\x8e\x50\xb3" ++
            "\x24\x67\xf6\xb2\x8a\x0a\xff\x7f\xfd\x20\x36\x9d\xac\x4a\x5f\x3a\xff\xa5\x38\x2d\xea\x04\x12\xde" ++
            "\x33\x57\x4e\x76\x51\xc1\x14\xfd\xfd\x8e\x9a\xdc\x96\x5d\xa1\xf5\x05\xc8\xf9\x51\x93\xac\x0f\xe6" ++
            "\x4a\xfb\xff\xdc\xb9\xa7\x8c\x5b\x2f\x37\x74\x63\x77\xe8\xff\x2c\xb4\x8e\x82\xff\x2d\x1a\x9f\x6d" ++
            "\xf7\x06\x6b\x9c\x15\xf0\x00\x47\xcb\x8b\x5e\x0d\xc6\x0f\xf3\xff\x28\x2f\xeb\xd7\xa8\x8a\xf2\x9d" ++
            "\xaa\x61\x0d\x0f\xdf\x3c\x2a\x39\xc1\xbc\xfc\xb6\x38\xd0\x70\xfc\x28\xa9\x6c\x00\xb1\xd3\x17\x8b" ++
            "\x71\xfb\x02\xb2\xca\x60\xbf\xde\xca\x0e\x0e\xe6\x95\x7f\xe5\x94\x67\xaa\xe1\xb3\xff\xff\xdc\x6d" ++
            "\x02\x78\x32\x6b\xa2\x5e\x5c\xb9\x4c\x59\xfc\x07\xe8\xbf\xa0\x07\x5b\x3f\x75\xc7\x8e\xf7\xf5\x63" ++
            "\x3f\xe8\xa4\x88\xf7\x7b\xdb\x07\xee\x61\xde\x0e\x4e\xd4\x8a\x3c\xa6\x15\x85\x0f\x43\x5a\x0d\x79" ++
            "\xc9\xb2\xe2\x3a\xcb\xbc\xc1\xae\x9f\xad\x56\xa2\xcf\x54\x08\xd8\xe1\xf2\xff\x88\x74\x1e\x4d\x7d" ++
            "\xfa\xc5\xea\x40\x41\x11\xf3\x17\x25\x62\x40\xcf\x97\x6e\x07\x4b\x51\xf1\x7b\x43\x9a\x26\x00",
        .uncompressed = 18,
        .compressed = 84,
        .key = true,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = false,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 0,
        .reference_mode = 0,
        .q = 33,
        .lf = 2,
        .seg = false,
        .log2_cols = 1,
        .width = 512,
        .height = 64,
        .crc_forward = 0x861aebaf,
        .crc_adapted = 0x91b1919d,
        .counts = &[_][2]u32{
            .{ 182, 90 },   .{ 185, 11 },  .{ 186, 2 },    .{ 189, 3 },   .{ 190, 8 },   .{ 191, 7 },    .{ 192, 1 },   .{ 193, 2 },
            .{ 198, 15 },   .{ 200, 1 },   .{ 201, 10 },   .{ 202, 2 },   .{ 205, 13 },  .{ 206, 15 },   .{ 209, 7 },   .{ 210, 4 },
            .{ 213, 1 },    .{ 214, 12 },  .{ 217, 4 },    .{ 221, 1 },   .{ 222, 3 },   .{ 225, 11 },   .{ 229, 1 },   .{ 233, 2 },
            .{ 241, 6 },    .{ 309, 1 },   .{ 311, 1 },    .{ 313, 13 },  .{ 315, 2 },   .{ 316, 2 },    .{ 318, 10 },  .{ 319, 22 },
            .{ 320, 3 },    .{ 321, 8 },   .{ 322, 1 },    .{ 323, 90 },  .{ 324, 59 },  .{ 325, 15 },   .{ 326, 41 },  .{ 327, 36 },
            .{ 328, 12 },   .{ 329, 14 },  .{ 438, 3 },    .{ 439, 7 },   .{ 440, 1 },   .{ 441, 4 },    .{ 442, 7 },   .{ 443, 39 },
            .{ 444, 6 },    .{ 445, 23 },  .{ 446, 11 },   .{ 447, 11 },  .{ 460, 5 },   .{ 461, 7 },    .{ 462, 1 },   .{ 464, 5 },
            .{ 465, 22 },   .{ 466, 7 },   .{ 467, 9 },    .{ 468, 2 },   .{ 469, 6 },   .{ 470, 3 },    .{ 471, 2 },   .{ 472, 1 },
            .{ 474, 1 },    .{ 478, 4 },   .{ 480, 10 },   .{ 482, 16 },  .{ 483, 1 },   .{ 484, 14 },   .{ 485, 4 },   .{ 486, 2 },
            .{ 487, 15 },   .{ 488, 9 },   .{ 489, 9 },    .{ 491, 10 },  .{ 492, 2 },   .{ 493, 1 },    .{ 495, 1 },   .{ 496, 11 },
            .{ 497, 1 },    .{ 498, 1 },   .{ 502, 7 },    .{ 504, 1 },   .{ 506, 16 },  .{ 508, 6 },    .{ 509, 1 },   .{ 510, 2 },
            .{ 511, 1 },    .{ 512, 1 },   .{ 514, 1 },    .{ 516, 1 },   .{ 518, 2 },   .{ 519, 1 },    .{ 520, 1 },   .{ 521, 1 },
            .{ 522, 3 },    .{ 523, 7 },   .{ 525, 1 },    .{ 526, 13 },  .{ 530, 10 },  .{ 533, 1 },    .{ 538, 2 },   .{ 540, 2 },
            .{ 541, 2 },    .{ 542, 3 },   .{ 545, 1 },    .{ 546, 7 },   .{ 550, 5 },   .{ 554, 1 },    .{ 560, 1 },   .{ 562, 3 },
            .{ 565, 5 },    .{ 566, 3 },   .{ 570, 7 },    .{ 574, 5 },   .{ 724, 5 },   .{ 725, 6 },    .{ 726, 7 },   .{ 727, 9 },
            .{ 728, 8 },    .{ 729, 9 },   .{ 730, 46 },   .{ 731, 5 },   .{ 732, 9 },   .{ 733, 20 },   .{ 734, 31 },  .{ 735, 3 },
            .{ 748, 29 },   .{ 749, 11 },  .{ 751, 4 },    .{ 752, 28 },  .{ 753, 17 },  .{ 754, 8 },    .{ 755, 10 },  .{ 756, 8 },
            .{ 757, 5 },    .{ 758, 5 },   .{ 759, 3 },    .{ 760, 6 },   .{ 761, 10 },  .{ 762, 4 },    .{ 764, 21 },  .{ 765, 14 },
            .{ 766, 37 },   .{ 768, 13 },  .{ 769, 3 },    .{ 770, 32 },  .{ 771, 2 },   .{ 772, 71 },   .{ 773, 14 },  .{ 775, 16 },
            .{ 776, 46 },   .{ 777, 20 },  .{ 779, 25 },   .{ 780, 25 },  .{ 781, 7 },   .{ 782, 7 },    .{ 783, 5 },   .{ 784, 22 },
            .{ 785, 4 },    .{ 786, 6 },   .{ 789, 3 },    .{ 790, 13 },  .{ 793, 2 },   .{ 794, 26 },   .{ 796, 12 },  .{ 797, 11 },
            .{ 798, 5 },    .{ 799, 15 },  .{ 800, 5 },    .{ 801, 22 },  .{ 802, 4 },   .{ 803, 27 },   .{ 805, 6 },   .{ 806, 1 },
            .{ 807, 12 },   .{ 808, 2 },   .{ 809, 5 },    .{ 810, 10 },  .{ 811, 9 },   .{ 813, 1 },    .{ 814, 15 },  .{ 816, 1 },
            .{ 818, 23 },   .{ 821, 1 },   .{ 823, 1 },    .{ 824, 3 },   .{ 825, 3 },   .{ 826, 1 },    .{ 827, 2 },   .{ 828, 3 },
            .{ 829, 2 },    .{ 830, 4 },   .{ 833, 1 },    .{ 834, 8 },   .{ 836, 1 },   .{ 838, 4 },    .{ 842, 2 },   .{ 848, 3 },
            .{ 849, 3 },    .{ 851, 2 },   .{ 852, 1 },    .{ 853, 5 },   .{ 854, 3 },   .{ 855, 1 },    .{ 856, 1 },   .{ 857, 2 },
            .{ 858, 4 },    .{ 860, 1 },   .{ 862, 2 },    .{ 866, 2 },   .{ 1014, 3 },  .{ 1015, 29 },  .{ 1017, 4 },  .{ 1018, 47 },
            .{ 1019, 3 },   .{ 1020, 11 }, .{ 1021, 8 },   .{ 1022, 10 }, .{ 1036, 37 }, .{ 1037, 7 },   .{ 1038, 2 },  .{ 1040, 6 },
            .{ 1041, 14 },  .{ 1042, 5 },  .{ 1044, 2 },   .{ 1045, 3 },  .{ 1046, 13 }, .{ 1047, 2 },   .{ 1048, 3 },  .{ 1050, 3 },
            .{ 1051, 7 },   .{ 1052, 6 },  .{ 1053, 1 },   .{ 1054, 3 },  .{ 1055, 8 },  .{ 1056, 22 },  .{ 1058, 3 },  .{ 1059, 1 },
            .{ 1060, 68 },  .{ 1061, 3 },  .{ 1063, 19 },  .{ 1064, 17 }, .{ 1065, 9 },  .{ 1066, 1 },   .{ 1067, 1 },  .{ 1068, 12 },
            .{ 1069, 3 },   .{ 1070, 8 },  .{ 1072, 1 },   .{ 1073, 1 },  .{ 1074, 1 },  .{ 1076, 4 },   .{ 1077, 3 },  .{ 1078, 1 },
            .{ 1080, 9 },   .{ 1081, 10 }, .{ 1084, 92 },  .{ 1085, 20 }, .{ 1087, 19 }, .{ 1088, 5 },   .{ 1089, 25 }, .{ 1093, 7 },
            .{ 1094, 7 },   .{ 1098, 1 },  .{ 1108, 102 }, .{ 1109, 5 },  .{ 1111, 26 }, .{ 1112, 2 },   .{ 1113, 14 }, .{ 1117, 2 },
            .{ 1118, 1 },   .{ 1300, 10 }, .{ 1303, 8 },   .{ 1304, 2 },  .{ 1305, 1 },  .{ 1306, 20 },  .{ 1307, 1 },  .{ 1310, 20 },
            .{ 1324, 24 },  .{ 1328, 2 },  .{ 1333, 10 },  .{ 1334, 2 },  .{ 1337, 4 },  .{ 1338, 10 },  .{ 1340, 1 },  .{ 1342, 19 },
            .{ 1346, 34 },  .{ 1348, 34 }, .{ 1349, 4 },   .{ 1351, 1 },  .{ 1352, 8 },  .{ 1353, 6 },   .{ 1354, 1 },  .{ 1355, 2 },
            .{ 1356, 10 },  .{ 1357, 8 },  .{ 1359, 1 },   .{ 1360, 10 }, .{ 1361, 6 },  .{ 1362, 4 },   .{ 1364, 14 }, .{ 1365, 3 },
            .{ 1366, 44 },  .{ 1372, 64 }, .{ 1373, 9 },   .{ 1374, 2 },  .{ 1375, 3 },  .{ 1376, 23 },  .{ 1377, 7 },  .{ 1378, 3 },
            .{ 1379, 4 },   .{ 1380, 29 }, .{ 1381, 2 },   .{ 1382, 16 }, .{ 1385, 22 }, .{ 1386, 3 },   .{ 1389, 1 },  .{ 1390, 1 },
            .{ 1396, 207 }, .{ 1397, 10 }, .{ 1399, 11 },  .{ 1400, 96 }, .{ 1401, 29 }, .{ 1402, 2 },   .{ 1404, 13 }, .{ 1405, 32 },
            .{ 1406, 4 },   .{ 1408, 1 },  .{ 1409, 7 },   .{ 1410, 8 },  .{ 1414, 1 },  .{ 1420, 135 }, .{ 1421, 9 },  .{ 1422, 5 },
            .{ 1423, 31 },  .{ 1424, 21 }, .{ 1425, 9 },   .{ 1426, 8 },  .{ 1428, 3 },  .{ 1429, 1 },   .{ 1430, 2 },  .{ 1434, 1 },
            .{ 1438, 1 },   .{ 1591, 8 },  .{ 1594, 6 },   .{ 1595, 1 },  .{ 1624, 2 },  .{ 1625, 1 },   .{ 1626, 1 },  .{ 1630, 5 },
            .{ 1634, 3 },   .{ 1637, 2 },  .{ 1640, 2 },   .{ 1641, 3 },  .{ 1645, 2 },  .{ 1646, 2 },   .{ 1650, 1 },  .{ 1652, 4 },
            .{ 1657, 1 },   .{ 1658, 1 },  .{ 1660, 8 },   .{ 1661, 3 },  .{ 1663, 1 },  .{ 1664, 3 },   .{ 1665, 4 },  .{ 1670, 2 },
            .{ 1677, 1 },   .{ 1678, 1 },  .{ 1684, 27 },  .{ 1685, 4 },  .{ 1686, 1 },  .{ 1687, 1 },   .{ 1688, 7 },  .{ 1689, 3 },
            .{ 1696, 1 },   .{ 1701, 1 },  .{ 1708, 78 },  .{ 1709, 6 },  .{ 1711, 4 },  .{ 1712, 5 },   .{ 1713, 2 },  .{ 1716, 1 },
            .{ 1722, 1 },   .{ 1878, 10 }, .{ 1879, 2 },   .{ 1882, 2 },  .{ 1915, 2 },  .{ 1923, 10 },  .{ 2166, 7 },  .{ 2211, 7 },
            .{ 2740, 10 },  .{ 2741, 51 }, .{ 2742, 51 },  .{ 2747, 43 }, .{ 2748, 12 }, .{ 2749, 2 },   .{ 2750, 4 },  .{ 2751, 24 },
            .{ 2752, 23 },  .{ 2753, 18 }, .{ 2754, 3 },   .{ 2755, 5 },  .{ 2756, 6 },  .{ 2757, 8 },   .{ 2758, 6 },  .{ 2759, 2 },
            .{ 2760, 4 },   .{ 2761, 12 }, .{ 2762, 11 },  .{ 2763, 2 },  .{ 2764, 1 },  .{ 2765, 2 },   .{ 2766, 7 },  .{ 2767, 6 },
            .{ 2768, 4 },   .{ 2769, 1 },  .{ 2771, 4 },   .{ 2772, 7 },  .{ 2773, 5 },  .{ 2774, 5 },   .{ 2812, 27 }, .{ 2813, 68 },
            .{ 2814, 63 },  .{ 2818, 11 }, .{ 2819, 58 },  .{ 2820, 18 }, .{ 2821, 17 }, .{ 2822, 54 },  .{ 2823, 48 }, .{ 2824, 58 },
            .{ 2825, 34 },  .{ 2826, 17 }, .{ 2827, 13 },  .{ 2828, 7 },  .{ 2829, 18 }, .{ 2830, 20 },  .{ 2831, 32 }, .{ 2832, 12 },
            .{ 2833, 19 },  .{ 2834, 10 }, .{ 2835, 13 },  .{ 2836, 1 },  .{ 2837, 6 },  .{ 2838, 8 },   .{ 2839, 6 },  .{ 2840, 5 },
            .{ 2841, 1 },   .{ 2843, 7 },  .{ 2844, 8 },   .{ 2845, 5 },  .{ 2846, 2 },  .{ 2847, 2 },   .{ 2884, 32 }, .{ 2885, 54 },
            .{ 2886, 29 },  .{ 2891, 24 }, .{ 2892, 20 },  .{ 2893, 13 }, .{ 2894, 16 }, .{ 2895, 23 },  .{ 2896, 52 }, .{ 2897, 8 },
            .{ 2898, 10 },  .{ 2902, 37 }, .{ 2908, 45 },  .{ 2956, 18 }, .{ 2957, 24 }, .{ 2958, 20 },  .{ 2963, 1 },  .{ 2964, 12 },
            .{ 2965, 14 },  .{ 2966, 20 }, .{ 2967, 34 },  .{ 2968, 3 },  .{ 2969, 15 }, .{ 2970, 15 },  .{ 2971, 18 }, .{ 2972, 61 },
            .{ 2974, 8 },   .{ 2975, 13 }, .{ 2976, 38 },  .{ 2977, 7 },  .{ 2978, 1 },  .{ 2980, 66 },  .{ 2981, 8 },  .{ 2982, 6 },
            .{ 2983, 14 },  .{ 2984, 1 },  .{ 2986, 36 },  .{ 3028, 8 },  .{ 3029, 7 },  .{ 3037, 4 },   .{ 3038, 5 },  .{ 3039, 3 },
            .{ 3041, 1 },   .{ 3042, 4 },  .{ 3043, 1 },   .{ 3044, 4 },  .{ 3045, 2 },  .{ 3046, 4 },   .{ 3047, 4 },  .{ 3048, 1 },
            .{ 3050, 2 },   .{ 3052, 8 },  .{ 3053, 4 },   .{ 3056, 1 },  .{ 3058, 9 },  .{ 3100, 12 },  .{ 3101, 2 },  .{ 3109, 2 },
            .{ 3111, 10 },  .{ 3172, 7 },  .{ 3183, 7 },
        },
    },
    .{
        .bytes = "\x86\x00\x40\x92\xe0\x11\x25\x0c\xc0\x40\x70\x18\x0c\x07\xab\x01\x80\xc1\x1b\x88\xdc\x00\x00\x04" ++
            "\x00\x0e\x60\xf9\xdf\x9b\x77\x80\x00\x00\x00\x00\x27\x78\xb6\xbd\x5e\x4e\xd7\x9f\x65\x13\x0e\xc9" ++
            "\x1c\x63\xaa\x5e\x66\xcb\xcc\x10\x6f\x6b\x56\xae\x90\x73\xa7\xc9\x5e\x20\xb6\x35\x6a\xe1\xc1\x27" ++
            "\x87\xb2\x18\x20\x7b\xa8\xb4\xc4\x71\x05\xb1\xab\x57\x1a\xf5\x44\x49\x76\x9f\x18\x61\x26\x71\x13" ++
            "\x7c\xd5\xa7\x59\x17\x83\xb2\x19\x28\x80",
        .uncompressed = 26,
        .compressed = 7,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = false,
        .ctx = 0,
        .tx_mode = 3,
        .interp = 4,
        .reference_mode = 0,
        .q = 74,
        .lf = 1,
        .seg = true,
        .log2_cols = 1,
        .width = 512,
        .height = 64,
        .crc_forward = 0x47869181,
        .crc_adapted = 0xf3b08c33,
        .counts = &[_][2]u32{
            .{ 13, 84 },  .{ 14, 54 },  .{ 15, 30 },  .{ 16, 26 },  .{ 17, 4 },   .{ 19, 5 },   .{ 20, 1 },   .{ 21, 4 },
            .{ 22, 4 },   .{ 182, 20 }, .{ 198, 47 }, .{ 201, 5 },  .{ 206, 4 },  .{ 214, 17 }, .{ 217, 2 },  .{ 222, 1 },
            .{ 225, 12 }, .{ 233, 2 },  .{ 241, 6 },  .{ 246, 66 }, .{ 247, 6 },  .{ 255, 13 }, .{ 256, 4 },  .{ 259, 89 },
            .{ 284, 2 },  .{ 292, 87 }, .{ 325, 2 },  .{ 326, 2 },  .{ 327, 20 }, .{ 328, 4 },  .{ 329, 61 }, .{ 331, 4 },
            .{ 336, 4 },  .{ 350, 4 },  .{ 384, 4 },  .{ 427, 4 },  .{ 435, 4 },  .{ 868, 1 },  .{ 870, 1 },  .{ 871, 2 },
            .{ 892, 2 },  .{ 903, 1 },  .{ 916, 3 },  .{ 941, 1 },  .{ 943, 1 },  .{ 1157, 1 }, .{ 1159, 1 }, .{ 1184, 1 },
            .{ 1185, 1 }, .{ 1204, 1 }, .{ 1208, 1 }, .{ 1209, 1 }, .{ 1228, 2 }, .{ 1232, 1 }, .{ 1233, 1 }, .{ 1252, 5 },
            .{ 1255, 1 }, .{ 1256, 2 }, .{ 1257, 2 }, .{ 1445, 2 }, .{ 1446, 2 }, .{ 1447, 2 }, .{ 1450, 2 }, .{ 1475, 2 },
            .{ 1477, 4 }, .{ 1479, 4 }, .{ 1734, 2 }, .{ 1738, 2 }, .{ 1765, 4 }, .{ 1767, 4 }, .{ 2848, 4 }, .{ 2856, 1 },
            .{ 2866, 1 }, .{ 2920, 2 }, .{ 2927, 2 }, .{ 2933, 1 }, .{ 2938, 1 }, .{ 2944, 2 }, .{ 2992, 6 }, .{ 2993, 2 },
            .{ 2999, 2 }, .{ 3000, 8 }, .{ 3064, 2 }, .{ 3065, 2 }, .{ 3072, 8 },
        },
    },
    .{
        .bytes = "\x86\x00\x40\x92\x98\x04\x4e\xe3\x30\x17\x7c\x06\x03\x01\xf1\x40\x60\x30\x46\xa2\x35\x00\x00\x01" ++
            "\x00\x01\x80\x70\x00\x00\x00\x00\x00\x26\x73\x00\x50\x40\x93\xc1\x22\xdc\x3c\x22\x75\xb3\x57\x21" ++
            "\x50\x38\x99\xdf\x49\x71\x3d\xb6\xa3\x82\x13\x85\x52\x37\x43\x97\xa4\x9e\x91\x65\x56\x63\xbf\x00" ++
            "\x7c\x06\x6b\x82\xc9\x39\x57\x66\x74\x64\x5c\xb6\x75\x0c\x75\x4e\x8b\x39\x61\x04\xa5\x7e\xb8\xaf" ++
            "\xad\xc1\x25\x00",
        .uncompressed = 27,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = false,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 1,
        .reference_mode = 0,
        .q = 119,
        .lf = 1,
        .seg = true,
        .log2_cols = 1,
        .width = 512,
        .height = 64,
        .crc_forward = 0xf3b08c33,
        .crc_adapted = 0x3ce36202,
        .counts = &[_][2]u32{
            .{ 13, 51 },   .{ 14, 38 },  .{ 15, 13 },  .{ 16, 7 },   .{ 17, 6 },   .{ 19, 9 },   .{ 20, 8 },    .{ 21, 1 },
            .{ 22, 1 },    .{ 182, 8 },  .{ 198, 29 }, .{ 199, 1 },  .{ 201, 2 },  .{ 214, 16 }, .{ 217, 6 },   .{ 222, 4 },
            .{ 225, 2 },   .{ 233, 2 },  .{ 238, 1 },  .{ 241, 5 },  .{ 259, 60 }, .{ 276, 1 },  .{ 277, 1 },   .{ 284, 11 },
            .{ 285, 6 },   .{ 286, 2 },  .{ 290, 4 },  .{ 292, 35 }, .{ 293, 6 },  .{ 294, 7 },  .{ 318, 1 },   .{ 319, 5 },
            .{ 323, 1 },   .{ 325, 3 },  .{ 326, 2 },  .{ 327, 16 }, .{ 328, 5 },  .{ 329, 34 }, .{ 331, 6 },   .{ 336, 6 },
            .{ 349, 1 },   .{ 351, 5 },  .{ 362, 1 },  .{ 385, 5 },  .{ 386, 5 },  .{ 415, 1 },  .{ 427, 5 },   .{ 430, 1 },
            .{ 435, 5 },   .{ 873, 3 },  .{ 875, 1 },  .{ 899, 3 },  .{ 1157, 1 }, .{ 1159, 2 }, .{ 1161, 2 },  .{ 1163, 1 },
            .{ 1184, 1 },  .{ 1185, 1 }, .{ 1187, 2 }, .{ 1207, 1 }, .{ 1445, 9 }, .{ 1447, 1 }, .{ 1449, 1 },  .{ 1451, 1 },
            .{ 1472, 1 },  .{ 1473, 4 }, .{ 1475, 9 }, .{ 1492, 1 }, .{ 1496, 2 }, .{ 1516, 1 }, .{ 1517, 1 },  .{ 1519, 1 },
            .{ 1733, 1 },  .{ 1734, 3 }, .{ 1738, 1 }, .{ 1761, 1 }, .{ 1763, 1 }, .{ 1764, 1 }, .{ 1765, 3 },  .{ 1767, 2 },
            .{ 1769, 1 },  .{ 1771, 1 }, .{ 1780, 1 }, .{ 1784, 2 }, .{ 1804, 3 }, .{ 1805, 1 }, .{ 1831, 1 },  .{ 1833, 1 },
            .{ 2849, 4 },  .{ 2855, 3 }, .{ 2920, 3 }, .{ 2921, 3 }, .{ 2927, 3 }, .{ 2932, 1 }, .{ 2992, 10 }, .{ 2993, 2 },
            .{ 2999, 14 }, .{ 3010, 1 }, .{ 3064, 4 }, .{ 3065, 1 }, .{ 3071, 2 }, .{ 3072, 6 }, .{ 3073, 2 },  .{ 3082, 1 },
            .{ 3088, 1 },
        },
    },
    .{
        .bytes = "\x86\x00\x40\x92\x98\x08\x4b\x03\x30\x16\x9c\x06\x03\x01\xea\xc9\x60\x30\x47\xe2\x3f\x00\x00\x01" ++
            "\x00\x01\x80\x70\x00\x00\x00\x00\x00\x38\x7a\x26\xe3\x8e\x0d\x68\xda\x77\x9a\x6d\xb4\xee\x2f\x72" ++
            "\x51\xb7\xf1\x28\x58\xd5\x6f\x93\x13\x72\x62\x68\xff\x36\x18\x5e\x62\x8c\xe1\x46\x23\xf8\x7f\x7c" ++
            "\xb3\xf1\x97\xa5\xe3\x41\x56\x7d\xf2\x0a\x55\x38\x9c\x06\xe9\x1e\x74\x20\x7a\x28\xf6\x0d\x9b\xca" ++
            "\xa2\x59\x5f\xf9\xe4\xd1\x2e\x9c\xbe\xc1\x7b\x17\x8c\x45\x26\x73\x63\xc8\xe3\x37\x2a\x6f\xf2\xb8" ++
            "\x97\xcf\x8b\xf2\x75\x79\xb5\x34\x78\xbd\xc8\x7f\x5b\x87\xfb\xfe\xcf\x1b\xc7\xa1\xfe\x40",
        .uncompressed = 27,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = false,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 1,
        .reference_mode = 0,
        .q = 88,
        .lf = 2,
        .seg = true,
        .log2_cols = 1,
        .width = 512,
        .height = 64,
        .crc_forward = 0x3ce36202,
        .crc_adapted = 0xcdaf9fef,
        .counts = &[_][2]u32{
            .{ 13, 64 },  .{ 14, 53 },   .{ 15, 11 },  .{ 16, 4 },    .{ 17, 7 },   .{ 19, 13 },   .{ 20, 11 },   .{ 21, 2 },
            .{ 22, 2 },   .{ 182, 24 },  .{ 198, 30 }, .{ 201, 5 },   .{ 209, 1 },  .{ 214, 18 },  .{ 217, 7 },   .{ 222, 5 },
            .{ 225, 2 },  .{ 233, 2 },   .{ 241, 6 },  .{ 259, 77 },  .{ 276, 3 },  .{ 277, 5 },   .{ 284, 14 },  .{ 285, 12 },
            .{ 286, 1 },  .{ 290, 5 },   .{ 292, 37 }, .{ 293, 6 },   .{ 294, 17 }, .{ 318, 2 },   .{ 319, 3 },   .{ 323, 7 },
            .{ 325, 2 },  .{ 326, 4 },   .{ 327, 20 }, .{ 328, 8 },   .{ 329, 43 }, .{ 331, 7 },   .{ 336, 6 },   .{ 337, 1 },
            .{ 349, 4 },  .{ 350, 3 },   .{ 362, 1 },  .{ 363, 3 },   .{ 384, 3 },  .{ 412, 1 },   .{ 419, 3 },   .{ 425, 3 },
            .{ 430, 3 },  .{ 431, 1 },   .{ 434, 3 },  .{ 868, 4 },   .{ 869, 2 },  .{ 870, 1 },   .{ 871, 4 },   .{ 873, 1 },
            .{ 875, 2 },  .{ 892, 3 },   .{ 893, 2 },  .{ 894, 2 },   .{ 895, 1 },  .{ 896, 2 },   .{ 897, 3 },   .{ 899, 1 },
            .{ 903, 1 },  .{ 916, 4 },   .{ 920, 5 },  .{ 921, 1 },   .{ 923, 1 },  .{ 924, 2 },   .{ 941, 2 },   .{ 942, 1 },
            .{ 943, 3 },  .{ 945, 1 },   .{ 947, 1 },  .{ 1156, 1 },  .{ 1158, 2 }, .{ 1159, 5 },  .{ 1160, 1 },  .{ 1162, 3 },
            .{ 1163, 2 }, .{ 1164, 1 },  .{ 1180, 5 }, .{ 1181, 1 },  .{ 1191, 4 }, .{ 1192, 1 },  .{ 1194, 1 },  .{ 1204, 5 },
            .{ 1205, 2 }, .{ 1207, 1 },  .{ 1208, 1 }, .{ 1209, 1 },  .{ 1228, 2 }, .{ 1231, 2 },  .{ 1232, 3 },  .{ 1233, 3 },
            .{ 1252, 5 }, .{ 1255, 1 },  .{ 1256, 2 }, .{ 1257, 2 },  .{ 1444, 1 }, .{ 1445, 3 },  .{ 1446, 1 },  .{ 1447, 2 },
            .{ 1449, 2 }, .{ 1450, 1 },  .{ 1469, 1 }, .{ 1471, 1 },  .{ 1472, 2 }, .{ 1473, 4 },  .{ 1474, 1 },  .{ 1475, 3 },
            .{ 1476, 2 }, .{ 1477, 2 },  .{ 1492, 4 }, .{ 1496, 5 },  .{ 1497, 3 }, .{ 1516, 5 },  .{ 1517, 1 },  .{ 1519, 2 },
            .{ 1520, 5 }, .{ 1521, 1 },  .{ 1540, 4 }, .{ 1541, 2 },  .{ 1543, 2 }, .{ 1734, 2 },  .{ 1737, 1 },  .{ 1760, 1 },
            .{ 1761, 1 }, .{ 1764, 1 },  .{ 1765, 1 }, .{ 1768, 1 },  .{ 1770, 1 }, .{ 1780, 3 },  .{ 1784, 3 },  .{ 1785, 1 },
            .{ 1788, 1 }, .{ 1793, 1 },  .{ 1804, 7 }, .{ 1805, 1 },  .{ 1808, 2 }, .{ 1809, 2 },  .{ 1828, 21 }, .{ 1832, 9 },
            .{ 1833, 3 }, .{ 1852, 16 }, .{ 1853, 4 }, .{ 1855, 3 },  .{ 1856, 2 }, .{ 2848, 11 }, .{ 2849, 3 },  .{ 2854, 4 },
            .{ 2855, 5 }, .{ 2856, 1 },  .{ 2860, 1 }, .{ 2861, 1 },  .{ 2866, 3 }, .{ 2867, 1 },  .{ 2920, 8 },  .{ 2921, 6 },
            .{ 2922, 1 }, .{ 2926, 1 },  .{ 2928, 4 }, .{ 2929, 1 },  .{ 2932, 3 }, .{ 2933, 1 },  .{ 2938, 3 },  .{ 2944, 2 },
            .{ 2992, 7 }, .{ 2993, 3 },  .{ 2998, 1 }, .{ 2999, 10 }, .{ 3000, 4 }, .{ 3005, 3 },  .{ 3010, 2 },  .{ 3016, 2 },
            .{ 3064, 2 }, .{ 3065, 1 },  .{ 3071, 2 }, .{ 3072, 2 },  .{ 3073, 2 }, .{ 3077, 1 },  .{ 3078, 1 },  .{ 3082, 1 },
            .{ 3083, 2 }, .{ 3088, 3 },  .{ 3094, 4 },
        },
    },
};

const CLIP2 = [_]ClipFrame{
    .{
        .bytes = "\x82\x49\x83\x42\x00\x03\xf0\x03\xf6\x04\x38\x24\x1c\x18\x42\x00\x02\x60\x6f\xb0\xfa\xff\xc9\xf2" ++
            "\x34\x67\x42\xbc\xa6\xb8\x19\x6f\xe0\x6a\x3e\x62\x33\xc7\xed\xf9\xde\xfc\xbe\x97\x03\x23\x14\x7e" ++
            "\xc3\x8b\xbb\x5b\xed\x00\x00\x00\x7e\x18\xe5\x64\xda\x60\xf2\x80\x13\xbc\xe8\x60\xa4\xc1\xf0\x73" ++
            "\xc6\x48\x2f\x68\xad\xff\x81\x23\xa0\xb8\x58\x5b\xeb\x7f\xff\xfd\x12\x07\xdd\xf5\x06\x10\x71\xe9" ++
            "\x0f\xfa\x67\x2b\x98\x2e\xa0\x90\xec\x7d\xc5\xf3\xdd\x31\x58\x7d\xd8\xb8\x49\x1b\x5b\x2e\xd7\x5f" ++
            "\xff\xfb\xdf\x50\xa4\x69\xd0\x59\x6f\x0c\x8b\x00\xca\xec\x4d\x28\x0f\xca\x58\x9f\x28\xbf\x3c\xef" ++
            "\x44\x24\x72\xe3\x82\x2e\xef\x61\x27\x32\x4d\x17\x7b\x73\x41\x5a\x0e\x68\xb9\xf6\x8d\x9a\x02\x2e" ++
            "\xba\xd2\xaf\x1a\xb0\xd2\x42\xe5\xcf\xb0\x4c\xc3\x26\x0e\xf1\xbf\x01\xf6\xfd\x6d\x12\xed\xaa\xe8" ++
            "\x0e\x96\x0e\x6c\xf0\xa2\x86\x4e\x8d\x72\xa8\x6f\x7d\x16\xbd\x53\xc5\xff\x60\xf2\x37\x20\xf5\x9e" ++
            "\x66\x18\x6b\x1c\x42\x54\x10\x9c\x0a\x36\xc6\x8d\xef\x71\xc1\x3d\x3d\xd5\x8f\xcc\x01\x27\xba\x5b" ++
            "\x5c\xd3\x31\xc0\x8d\x93\x44\x29\xae\xfb\x79\x51\xd5\x7c\x01\x23\xa8\x88\xec\x77\xd2\x23\x6d\x29" ++
            "\xde\xae\x31\x19\x49\x86\x42\xe2\x21\x06\x16\x1c\x15\x69\x8a\x5e\x97\x25\x8e\x3f\xef\xf6\xd0\x5e" ++
            "\xbb\x28\x9c\xbb\x60\xd2\x21\x7f\xc0\x4e\xf0\x0f\xb3\x63\xe4\x99\xed\x40\xbd\x6e\x06\xff\x2b\x0b" ++
            "\xa4\x3c\x3a\x0a\x2b\xa9\x2c\x83\x0f\xf5\xb1\xc3\x4e\xf4\x67\x61\x38\xcf\xae\x87\x9e\xfd\x6e\xe7" ++
            "\x0e\x1c\x87\x7b\xc2\x18\x6e\x14\x0c\x19\xfb\xc2\x2f\xf1\x35\xe3\xae\x81\x3c\x02\x7a\xb6\xc8\x5e" ++
            "\xa1\x0a\x6f\x20\x4e\x69\x81\x9a\x62\xdd\x91\x95\x9e\x5e\x7b\x9f\xf5\x75\xfd\x06\x0b\x23\xeb\xa1" ++
            "\xd5\x1e\x97\x9f\x87\xcd\xa2\x00\x20\x9c\xc3\x89\x71\x66\x24\x8f\x4f\x80\x0b\x59\x88\x39\x4d\xcf" ++
            "\x47\xd2\xdc\x0d\x9e\x2c\xff\x5f\x08\x29\x03\x0b\x69\xfb\xb5\x66\x55\xdd\xfa\x6b\x77\xfe\x4b\xe3" ++
            "\x04\x5d\x38\x57\x93\xb1\x36\xf5\x05\x31\x37\x75\xf8\x75\x9e\x75\xfd\x14\x36\x31\xa1\xab\xa6\xcd" ++
            "\xb8\xf7\x91\xbe\x48\x67\x22\x7c\xf0\xab\xbf\x45\xae\xf1\x83\x22\x88\xc6\x66\x21\x44\x3e\xdd\xae" ++
            "\xcb\xf9\x7d\x01\x44\xbf\x65\x82\xd4\x0d\xa9\x70\x0a\x92\x5a\x72\x3e\xd5\x89\xea\x04\x25\x3f\xc5" ++
            "\x5f\xe0\xf7\x18\xdd\x32\xf4\xbb\x4b\xc2\x9c\x70\x60\x59\xb3\x49\xdd\xa2\x7f\x66\xc1\xaf\xe5\x9b" ++
            "\xf1\x39\x59\xf5\x65\x84\x35\x78\xbf\xa6\xd3\x37\xd6\x21\x5f\xf0\x25\xfe\x6f\x5b\x60\xee\x85\x4d" ++
            "\xd7\xd4\x4f\xe7\x12\x4c\xb7\x12\xff\x54\x46\x46\xa1\x4a\xb1\xf4\xdf\x77\xa3\xc2\xc9\x08\xc6\x55" ++
            "\x3c\xc5\x65\xf5\x8f\xcd\x45\xb5\xcf\xe3\x47\xb4\x2a\x1a\xaa\xbe\xed\x96\x01\x1b\x83\x36\xbf\xdc" ++
            "\xbb\x3c\x5a\xd8\x73\x24\x6d\x16\x0b\x67\x88\xcf\x69\x67\xbf\x48\x4c\x75\x61\x67\xc5\x2e\xfb\x8e" ++
            "\xba\xe0\x43\xfe\x20\x25\x17\x27\x30\x8b\x2f\x8f\xc1\x38\x51\x95\x6b\xe1\xa7\xb9\x8b\xff\x65\x0b" ++
            "\xdb\x4f\xfe\x1d\xd9\xf1\x38\x8d\x0b\x32\xfc\x11\x8c\x67\x43\xc3\xe7\x5a\x88\x1e\x32\x8d\x6e\x55" ++
            "\x33\xfc\x01\x53\x6c\x59\xcd\x9c\x09\x1a\x57\x42\x5f\xee\xb7\x77\xe5\xe4\x59\x77\x85\x57\x77\xde" ++
            "\xe0\x9e\xa0\xb2\xf7\x19\x7b\xdd\x34\x2d\xaa\x13\xee\x21\xd4\x6b\x35\x14\xe6\x48\xe5\xf4\x1e\x06" ++
            "\xd1\x24\xf3\x4c\x51\xd1\x5d\xa1\xe0\xc6\xf2\x67\x1e\x8f\x92\xdb\xfd\x1d\xb4\xe3\x80\x34\xaf\xe4" ++
            "\x5d\xe5\x58\x66\x13\xf4\x66\xa0\xdf\xfd\x28\x77\xfb\x34\x36\x20\x48\x52\x1d\x07\x5f\xde\x6c\x6e" ++
            "\x26\x99\x23\x86\x4a\x0b\x36\x08\xef\xf9\xfd\xaf\xac\x5d\xd8\x1a\x15\xb8\x16\xd5\xd8\x9b\x79\x21" ++
            "\x13\x18\xc2\xf1\x30\xb0\xa6\xcd\x11\x31\x7d\x4e\xde\x88\x5e\xab\x90\xde\x43\xc8\xbf\xe3\x01\xc1" ++
            "\x8c\x0a\x8c\xf8\xde\x3b\x81\x73\x79\xf0\x56\x8c\x5a\x2e\x2d\xa4\x8c\x79\x90\x07\xf9\x83\xc6\x13" ++
            "\xa7\x51\xad\xc5\x8f\xb2\x47\xa4\xf2\x62\xec\x9e\x5f\xd1\x09\xb0\x31\x3f\x4f\x40\x2c\x68\xbf\xcf" ++
            "\xd7\xf5\x63\x9a\xad\x8a\x3a\x4e\xf7\x44\x23\x95\x40\x5a\x11\x75\x9b\x29\xb6\x00\xb1\x6c\x78\xb1" ++
            "\x04\xef\x76\x4f\x48\xc7\x28\x74\x56\x27\x9a\x0e\xdd\x75\x63\xe7\xb1\xc3\x6d\xd0\x54\xf5\x57\x45" ++
            "\x25\x86\x9b\x10\x2c\x30\x4c\x61\x68\xcb\x96\xe3\x55\xe9\x27\xa3\x27\x2e\xcb\x1a\x48\xee\xe3\x4e" ++
            "\xc2\x11\xad\xfd\xdb\xa3\x7e\x3f\xa2\x97\x24\x53\x9a\xe4\xd9\x91\x02\x09\x8b\x42\x6c\x37\x98\xe5" ++
            "\x0c\xaf\xfd\xff\x0a\xe3\x48\x5e\x15\xc3\x25\xb0\xbc\xdb\x22\xdb\x76\x4b\x0b\x11\x3b\x8e\x91\x98" ++
            "\xc5\xe4\xad\xf9\x8f\xf7\xee\x44\x93\xcc\x34\x0a\x15\x6c\x49\x42\x68\x58\xed\xd1\xbb\x50\x5a\xb1" ++
            "\xd1\x50\x19\xe3\x83\xef\xc0\x00",
        .uncompressed = 18,
        .compressed = 38,
        .key = true,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 3,
        .interp = 0,
        .reference_mode = 0,
        .q = 33,
        .lf = 2,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x2152e8a8,
        .crc_adapted = 0x2152e8a8,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\x9c\x08\x49\x40\x00\x03\x70\x00\x00\x7a\x49\x13\x03\xf3\x97\x74\x14\x86\x32\xc5" ++
            "\xdf\x37\x3f\x26\x7b\xb7\xd4\x11\xb9\x0c\x9a\x21\xf5\x7f\x60",
        .uncompressed = 10,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 1,
        .reference_mode = 0,
        .q = 74,
        .lf = 2,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x2152e8a8,
        .crc_adapted = 0x2152e8a8,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\x9c\x00\x4a\xc0\x00\x03\x60\x00\x00\x7a\x49\x14\x4a\x05\xfe\x56\xb5\x4d\x36\x4f" ++
            "\x53\xef\x29\xf7\x85\x96\x6c\x64\x95\xe2\x5e\x0a\x3a\xb7\xff\xb5\xb0\x60\x14\xb8\x00",
        .uncompressed = 10,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 3,
        .interp = 1,
        .reference_mode = 0,
        .q = 86,
        .lf = 0,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x2152e8a8,
        .crc_adapted = 0x2152e8a8,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\x9c\x14\x49\xc0\x00\x04\x26\xac\x00\x00\x7a\x94\xee\xc4\xae\x53\xc8\x94\x6a\xe6" ++
            "\x45\x00",
        .uncompressed = 10,
        .compressed = 4,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 1,
        .interp = 1,
        .reference_mode = 0,
        .q = 78,
        .lf = 5,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x41a9b086,
        .crc_adapted = 0x41a9b086,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\x9c\x18\x48\xa0\x00\x03\x70\x00\x00\x7a\x94\xd2\xbf\xe0\x1f\x49\xe7\x91\x4c\x17" ++
            "\x42\x82\xcf\x6c\x76\x0d\x7f\x95\xcd\x8d\x95\xa1\x6d\x0b\x1d\x54\x38\xcf\xa5\x40\xd7\xfd\x1f\xc7" ++
            "\xba\x35\x3c\x3c\xc8\xe1\x5d\x05\x02\x03\x59\x28\x42\x26\x02\x0c\xb4\x69\xc2\xdf\x27\x5f\xfa\x76" ++
            "\x4a\x00",
        .uncompressed = 10,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 1,
        .reference_mode = 0,
        .q = 69,
        .lf = 6,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x41a9b086,
        .crc_adapted = 0x41a9b086,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\xf0\x01\x1e\x00\x00\x0c\x70\x00\x00\x7a\x47\x33\xd7\xf0\x0f\xfc\x01\x3d\xe3\x25" ++
            "\x94\xa9\x71\x30\xd0\x5a\x7c\xc2\x3e\xaa\x04\xbf\x11\xc8\x59\xb3\x3f\xc1\xe7\x0e\xbf\xd1\xff\xe1" ++
            "\x6f\x43\x3c\xc9\xa9\xef\x80\xbd\x71\x4b\xb9\x45\x88\x1c\x98\x1f\x7e\x31\x24\x57\x72\x53\x45\xbb" ++
            "\x82\x00",
        .uncompressed = 10,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 4,
        .reference_mode = 0,
        .q = 60,
        .lf = 0,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x41a9b086,
        .crc_adapted = 0x41a9b086,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\xf0\x31\x1b\x80\x00\x0c\x70\x00\x00\x7a\x47\x41\x59\x98\xc5\x56\xfe\x5e\xd6\x72" ++
            "\xbd\x53\x20\x0e\x33\xf8\xff\x08\xdf\xc0\x2d\x65\x48\x99\x51\xe7\x6e\x8a\xa6\xa3\x1e\xf4\xb2\xd9" ++
            "\xe8\x44\x18\xfc\xa0",
        .uncompressed = 10,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 4,
        .reference_mode = 0,
        .q = 55,
        .lf = 3,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x41a9b086,
        .crc_adapted = 0x41a9b086,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x86\x00\x40\x92\x9c\x18\x46\x40\x00\x05\x70\xab\x78\x00\x00\x7a\x57\xdd\x77\xff\x28\x7f\xe0\x1f" ++
            "\x46\x46\x10\x46\x57\x45\xcf\x58\x18\x79\x89\xc0\xf8\x3c\x3e\x1b\x89\xa4\x0e\x80\x2f\x25\x95\xcb" ++
            "\x88\xbc\x7f\xa3\xf8\xf7\x45\xf4\x90\xfd\x65\x9e\x35\x78\x46\x10\x67\x24\xed\x0c\x07\xa1\x6a\x4d" ++
            "\xd7\x35\x4a\xf3\x14\x46\x00",
        .uncompressed = 10,
        .compressed = 5,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = false,
        .refresh = true,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 1,
        .reference_mode = 0,
        .q = 50,
        .lf = 6,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x5776fc3a,
        .crc_adapted = 0x5776fc3a,
        .counts = &[_][2]u32{},
    },
};

const CLIP3 = [_]ClipFrame{
    .{
        .bytes = "\x83\x49\x83\x42\x00\x03\xf0\x03\xf0\x10\xe0\x90\x70\x61\x08\x00\x09\x80\x6f\xb0\xfa\xff\xc9\xf2" ++
            "\x34\x67\x42\xbc\xa6\xb8\x19\x6f\xe0\x6a\x3e\x62\x33\xc7\xed\xf9\xde\xfc\xbe\x97\x03\x23\x14\x7e" ++
            "\xc3\x8b\xbb\x5b\xed\x00\x00\x00\x7e\x18\xe5\x64\xda\x60\xf2\x80\x13\xbc\xe8\x60\xa4\xc1\xf0\x73" ++
            "\xc6\x48\x2f\x68\xad\xff\x81\x23\xa0\xb8\x58\x5b\xeb\x7f\xff\xfd\x12\x07\xdd\xf5\x06\x10\x71\xe9" ++
            "\x0f\xfa\x67\x2b\x98\x2e\xa0\x90\xec\x7d\xc5\xf3\xdd\x31\x58\x7d\xd8\xb8\x49\x1b\x5b\x2e\xd7\x5f" ++
            "\xff\xfb\xdf\x50\xa4\x69\xd0\x59\x6f\x0c\x8b\x00\xca\xec\x4d\x28\x0f\xca\x58\x9f\x28\xbf\x3c\xef" ++
            "\x44\x24\x72\xe3\x82\x2e\xef\x61\x27\x32\x4d\x17\x7b\x73\x41\x5a\x0e\x68\xb9\xf6\x8d\x9a\x02\x2e" ++
            "\xba\xd2\xaf\x1a\xb0\xd2\x42\xe5\xcf\xb0\x4c\xc3\x26\x0e\xf1\xbf\x01\xf6\xfd\x6d\x12\xed\xaa\xe8" ++
            "\x0e\x96\x0e\x6c\xf0\xa2\x86\x4e\x8d\x72\xa8\x6f\x7d\x16\xbd\x53\xc5\xff\x60\xf2\x37\x20\xf5\x9e" ++
            "\x66\x18\x6b\x1c\x42\x54\x10\x9c\x0a\x36\xc6\x8d\xef\x71\xc1\x3d\x3d\xd5\x8f\xcc\x01\x27\xba\x5b" ++
            "\x5c\xd3\x31\xc0\x8d\x93\x44\x29\xae\xfb\x79\x51\xd5\x7c\x01\x23\xa8\x88\xec\x77\xd2\x23\x6d\x29" ++
            "\xde\xae\x31\x19\x49\x86\x42\xe2\x21\x06\x16\x1c\x15\x69\x8a\x5e\x97\x25\x8e\x3f\xef\xf6\xd0\x5e" ++
            "\xbb\x28\x9c\xbb\x60\xd2\x21\x7f\xc0\x4e\xf0\x0f\xb3\x63\xe4\x99\xed\x40\xbd\x6e\x06\xff\x2b\x0b" ++
            "\xa4\x3c\x3a\x0a\x2b\xa9\x2c\x83\x0f\xf5\xb1\xc3\x4e\xf4\x67\x61\x38\xcf\xae\x87\x9e\xfd\x6e\xe7" ++
            "\x0e\x1c\x87\x7b\xc2\x18\x6e\x14\x0c\x19\xfb\xc2\x2f\xf1\x35\xe3\xae\x81\x3c\x02\x7a\xb6\xc8\x5e" ++
            "\xa1\x0a\x6f\x20\x4e\x69\x81\x9a\x62\xdd\x91\x95\x9e\x5e\x7b\x9f\xf5\x75\xfd\x06\x0b\x23\xeb\xa1" ++
            "\xd5\x1e\x97\x9f\x87\xcd\xa2\x00\x20\x9c\xc3\x89\x71\x66\x24\x8f\x4f\x80\x0b\x59\x88\x39\x4d\xcf" ++
            "\x47\xd2\xdc\x0d\x9e\x2c\xff\x5f\x08\x29\x03\x0b\x69\xfb\xb5\x66\x55\xdd\xfa\x6b\x77\xfe\x4b\xe3" ++
            "\x04\x5d\x38\x57\x93\xb1\x36\xf5\x05\x31\x37\x75\xf8\x75\x9e\x75\xfd\x14\x36\x31\xa1\xab\xa6\xcd" ++
            "\xb8\xf7\x91\xbe\x48\x67\x22\x7c\xf0\xab\xbf\x45\xae\xf1\x83\x22\x88\xc6\x66\x21\x44\x3e\xdd\xae" ++
            "\xcb\xf9\x7d\x01\x44\xbf\x65\x82\xd4\x0d\xa9\x70\x0a\x92\x5a\x72\x3e\xd5\x89\xea\x04\x25\x3f\xc5" ++
            "\x5f\xe0\xf7\x18\xdd\x32\xf4\xbb\x4b\xc2\x9c\x70\x60\x59\xb3\x49\xdd\xa2\x7f\x66\xc1\xaf\xe5\x9b" ++
            "\xf1\x39\x59\xf5\x65\x84\x35\x78\xbf\xa6\xd3\x37\xd6\x21\x5f\xf0\x25\xfe\x6f\x5b\x60\xee\x85\x4d" ++
            "\xd7\xd4\x4f\xe7\x12\x4c\xb7\x12\xff\x54\x46\x46\xa1\x4a\xb1\xf4\xdf\x77\xa3\xc2\xc9\x08\xc6\x55" ++
            "\x3c\xc5\x65\xf5\x8f\xcd\x45\xb5\xcf\xe3\x47\xb4\x2a\x1a\xaa\xbe\xed\x96\x01\x1b\x83\x36\xbf\xdc" ++
            "\xbb\x3c\x5a\xd8\x73\x24\x6d\x16\x0b\x67\x88\xcf\x69\x67\xbf\x48\x4c\x75\x61\x67\xc5\x2e\xfb\x8e" ++
            "\xba\xe0\x43\xfe\x20\x25\x17\x27\x30\x8b\x2f\x8f\xc1\x38\x51\x95\x6b\xe1\xa7\xb9\x8b\xff\x65\x0b" ++
            "\xdb\x4f\xfe\x1d\xd9\xf1\x38\x8d\x0b\x32\xfc\x11\x8c\x67\x43\xc3\xe7\x5a\x88\x1e\x32\x8d\x6e\x55" ++
            "\x33\xfc\x01\x53\x6c\x59\xcd\x9c\x09\x1a\x57\x42\x5f\xee\xb7\x77\xe5\xe4\x59\x77\x85\x57\x77\xde" ++
            "\xe0\x9e\xa0\xb2\xf7\x19\x7b\xdd\x34\x2d\xaa\x13\xee\x21\xd4\x6b\x35\x14\xe6\x48\xe5\xf4\x1e\x06" ++
            "\xd1\x24\xf3\x4c\x51\xd1\x5d\xa1\xe0\xc6\xf2\x67\x1e\x8f\x92\xdb\xfd\x1d\xb4\xe3\x80\x34\xaf\xe4" ++
            "\x5d\xe5\x58\x66\x13\xf4\x66\xa0\xdf\xfd\x28\x77\xfb\x34\x36\x20\x48\x52\x1d\x07\x5f\xde\x6c\x6e" ++
            "\x26\x99\x23\x86\x4a\x0b\x36\x08\xef\xf9\xfd\xaf\xac\x5d\xd8\x1a\x15\xb8\x16\xd5\xd8\x9b\x79\x21" ++
            "\x13\x18\xc2\xf1\x30\xb0\xa6\xcd\x11\x31\x7d\x4e\xde\x88\x5e\xab\x90\xde\x43\xc8\xbf\xe3\x01\xc1" ++
            "\x8c\x0a\x8c\xf8\xde\x3b\x81\x73\x79\xf0\x56\x8c\x5a\x2e\x2d\xa4\x8c\x79\x90\x07\xf9\x83\xc6\x13" ++
            "\xa7\x51\xad\xc5\x8f\xb2\x47\xa4\xf2\x62\xec\x9e\x5f\xd1\x09\xb0\x31\x3f\x4f\x40\x2c\x68\xbf\xcf" ++
            "\xd7\xf5\x63\x9a\xad\x8a\x3a\x4e\xf7\x44\x23\x95\x40\x5a\x11\x75\x9b\x29\xb6\x00\xb1\x6c\x78\xb1" ++
            "\x04\xef\x76\x4f\x48\xc7\x28\x74\x56\x27\x9a\x0e\xdd\x75\x63\xe7\xb1\xc3\x6d\xd0\x54\xf5\x57\x45" ++
            "\x25\x86\x9b\x10\x2c\x30\x4c\x61\x68\xcb\x96\xe3\x55\xe9\x27\xa3\x27\x2e\xcb\x1a\x48\xee\xe3\x4e" ++
            "\xc2\x11\xad\xfd\xdb\xa3\x7e\x3f\xa2\x97\x24\x53\x9a\xe4\xd9\x91\x02\x09\x8b\x42\x6c\x37\x98\xe5" ++
            "\x0c\xaf\xfd\xff\x0a\xe3\x48\x5e\x15\xc3\x25\xb0\xbc\xdb\x22\xdb\x76\x4b\x0b\x11\x3b\x8e\x91\x98" ++
            "\xc5\xe4\xad\xf9\x8f\xf7\xee\x44\x93\xcc\x34\x0a\x15\x6c\x49\x42\x68\x58\xed\xd1\xbb\x50\x5a\xb1" ++
            "\xd1\x50\x19\xe3\x83\xef\xc0\x00",
        .uncompressed = 18,
        .compressed = 38,
        .key = true,
        .show = true,
        .intra_only = false,
        .error_res = true,
        .refresh = false,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 3,
        .interp = 0,
        .reference_mode = 0,
        .q = 33,
        .lf = 2,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x2152e8a8,
        .crc_adapted = 0x2152e8a8,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x87\x01\x02\x4a\x40\x87\x04\x83\x83\x12\x80\x00\x06\x70\x00\x00\x7a\x49\x13\x03\xf3\x97\x74\x14" ++
            "\x86\x32\xc5\xdf\x37\x3f\x26\x7b\xb7\xd4\x11\xb9\x0c\x9a\x21\xf5\x7f\x60",
        .uncompressed = 13,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = true,
        .refresh = false,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 4,
        .interp = 1,
        .reference_mode = 0,
        .q = 74,
        .lf = 2,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x4c541574,
        .crc_adapted = 0x4c541574,
        .counts = &[_][2]u32{},
    },
    .{
        .bytes = "\x87\x01\x02\x4a\x40\x07\x04\x83\x83\x15\x80\x00\x06\x60\x00\x00\x7a\x49\x14\x4a\x05\xfe\x56\xb5" ++
            "\x4d\x36\x4f\x53\xef\x29\xf7\x85\x96\x6c\x64\x95\xe2\x5e\x0a\x3a\xb7\xff\xb5\xb0\x60\x14\xb8\x00",
        .uncompressed = 13,
        .compressed = 3,
        .key = false,
        .show = true,
        .intra_only = false,
        .error_res = true,
        .refresh = false,
        .parallel = true,
        .ctx = 0,
        .tx_mode = 3,
        .interp = 1,
        .reference_mode = 0,
        .q = 86,
        .lf = 0,
        .seg = false,
        .log2_cols = 0,
        .width = 64,
        .height = 64,
        .crc_forward = 0x4c541574,
        .crc_adapted = 0x4c541574,
        .counts = &[_][2]u32{},
    },
};
