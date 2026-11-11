//! @zpm/va av1 — AV1 Main (profile 0, 8-bit 4:2:0) on the RTX's video
//! decoder (NVDEC, NVCFB0 on GB206): the picture setup it reads
//! (nvdec_av1_pic_s), the tile and global-motion tables, the probability
//! (CDF) tables, motion-vector and segment-map buffers kept per decoded
//! frame, and one frame's pushbuffer, behind codec.sig.
//!
//! Sources. The struct, its buffers' sizes and the methods are NVIDIA's
//! public Ada headers (open-gpu-doc nvdec_drv.h, clc9b0.h; MIT). Blackwell's
//! are assumed the same — THE RISK, as for H.264 (nvdec.sig): if GB206's
//! firmware reads a longer or reordered nvdec_av1_pic_s, every field past
//! the change is wrong and the status word says so (GALAXY_VA_DEBUG). One
//! independent AV1 driver for this engine (AROS nvgfx, 2026, from traces of
//! NVIDIA's driver with the class reported as CFB0) says Blackwell's driver
//! also writes reserved12 = 0xffff, reserved_stat = 9, a word at 0x244 (past
//! Ada's 0x23c-byte struct) of ceil(width / 128) + 1, and binds one more
//! buffer at method 0x4dc of that many 16 KiB blocks: `State.blackwell`
//! turns those on (off by default; nothing public confirms them).
//!
//! The method set, the default CDF layout (av1_cdf.sig), the filter
//! buffer's parts and their order, the superres step defaults and the
//! application id (0x12, AVD: clc9b0.h names no AV1 id) follow Mesa NVK's
//! AV1 work (Collabora, branch nvk-vulkan-video-av1, MIT), unmerged and
//! unfinished; where it says XXX/TODO the AV1 specification decides, and
//! AROS nvgfx's traced facts (no code of it is used) break ties:
//! - Picture slots by role: slot i is reference i (LAST .. ALTREF, through
//!   ref_frame_idx), slot 8 the current picture, SET_PICTURE_INDEX 8 and
//!   frame_buffer_idx naming the same slots. (codec.Picture.picture_index,
//!   a decode counter, is not used: AV1's setup names no output slot, and
//!   the trace sends 8.) Unused slots name the target, never address 0.
//! - The tile table is AV1TileInfo_OLD (16 bytes a tile: width and height
//!   in superblocks, start, end) at SET_TILE_SIZE_BUF_OFFSET; no tile
//!   stream info buffer.
//! - The global-motion buffer: per reference, gm_params[0..5] as int32,
//!   then the warp's shear (alpha, beta, gamma, delta) as int16 (spec
//!   7.11.3.6).
//! - mf*_type are reference names (LAST 1 .. ALTREF 7); mfmv_side flags a
//!   negative offset; frame_off is current minus reference.
//!
//! The CDFs, without the CPU: every decoded frame gets its own CDF table
//! from a pool of POOL in the scratch buffer; the decoder writes the
//! adapted CDFs there (AV1_SET_PROB_TAB_WRITE) and a later frame reads its
//! primary reference's table directly (AV1_SET_PROB_TAB_READ), or one of
//! four default tables (one per quantizer context) when it has none. With
//! disable_frame_end_update_cdf the frame keeps the table it read. VA-API
//! gives no refresh_frame_flags, so what each reference slot holds is
//! ref_frame_map's surfaces: a decoded frame's state (its CDF table, its
//! motion vectors and segment map, size, order hints, frame type) is kept
//! by its surface while a later frame's ref_frame_map names it. The one
//! CPU step: an intra frame with intrabc adapts the MV CDFs (intrabc's) in
//! its table; the spec saves the regular MV CDFs (still the defaults) for
//! later frames, so End.wait is set and `after` puts the defaults back.
//!
//! Not done in this round: film grain (apply_grain off: the grain-free
//! picture goes to the target, current_display_picture is not written),
//! 10/12-bit, 4:4:4 and monochrome (refused), large-scale tile (refused),
//! references of another size than the frame (refused:
//! ERROR_RESOLUTION_NOT_SUPPORTED; superres's horizontal scaling is set).

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const codec = @import("codec.sig");
const vaav1 = @import("vaapi_av1.sig");
const cdf = @import("av1_cdf.sig");

pub const PictureParameterBufferAV1 = vaav1.PictureParameterBufferAV1;
pub const SliceParameterBufferAV1 = vaav1.SliceParameterBufferAV1;

/// VAProfileAV1Profile0.
pub const PROFILE: va.Profile = vaav1.PROFILE_AV1_PROFILE0;

/// SET_APPLICATION_ID's AVD (0x12): NVK's (and NVIDIA's driver's) AV1.
pub const APPLICATION_ID_AV1: u32 = 0x12;
pub const CODEC_TYPE_AV1: u32 = 0x0a;

// ── Methods (clc9b0.h) ──────────────────────────────────────────────────────

pub const SET_INTRA_TOP_BUF_OFFSET: u32 = 0x4c8;
pub const SET_TILE_SIZE_BUF_OFFSET: u32 = 0x4cc;
pub const SET_FILTER_BUFFER_OFFSET: u32 = 0x4d0;
/// Not in clc9b0.h: Blackwell's extra buffer as AROS's trace has it.
pub const SET_BLK_BUF_OFFSET: u32 = 0x4dc;
pub const AV1_SET_PROB_TAB_READ_BUF_OFFSET: u32 = 0x640;
pub const AV1_SET_PROB_TAB_WRITE_BUF_OFFSET: u32 = 0x644;
pub const AV1_SET_SEGMENT_READ_BUF_OFFSET: u32 = 0x648;
pub const AV1_SET_SEGMENT_WRITE_BUF_OFFSET: u32 = 0x64c;
pub const AV1_SET_COL_MV0_READ_BUF_OFFSET: u32 = 0x650;
pub const AV1_SET_COL_MVWRITE_BUF_OFFSET: u32 = 0x65c;
pub const AV1_SET_GLOBAL_MODEL_BUF_OFFSET: u32 = 0x660;
pub const AV1_SET_FILM_GRAIN_BUF_OFFSET: u32 = 0x664;

// ── The structs (nvdec_drv.h) ───────────────────────────────────────────────

/// av1_fgs_cfg_t (film grain; left zero: apply_grain off).
pub const FgsCfg = extern struct {
    bits: packed struct(u16) {
        apply_grain: u1 = 0,
        overlap_flag: u1 = 0,
        clip_to_restricted_range: u1 = 0,
        chroma_scaling_from_luma: u1 = 0,
        num_y_points_b: u1 = 0,
        num_cb_points_b: u1 = 0,
        num_cr_points_b: u1 = 0,
        scaling_shift: u4 = 0,
        reserved_fgs: u5 = 0,
    } = .{},
    sw_random_seed: u16 = 0,
    cb_offset: i16 = 0,
    cr_offset: i16 = 0,
    cb_mult: i8 = 0,
    cb_luma_mult: i8 = 0,
    cr_mult: i8 = 0,
    cr_luma_mult: i8 = 0,
};

/// frame_info_t.
pub const FrameInfo = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    /// luma and chroma pitches in 16-byte units
    stride: [2]u16 = .{ 0, 0 },
    /// the picture slot holding it
    frame_buffer_idx: u32 = 0,
};

/// ref_frame_struct_s.
pub const RefFrame = extern struct {
    info: FrameInfo = .{},
    /// scale_factors_reference_s: (reference << 14) / current, rounded
    x_scale_fp: i16 = 0,
    y_scale_fp: i16 = 0,
    bits: packed struct(u8) {
        sign_bias: u1 = 0,
        /// identity, translation, rotzoom, affine
        wmtype: u2 = 0,
        reserved_rf: u5 = 0,
    } = .{},
    pad0: u8 = 0,
    /// current minus reference, reference minus current (order hints)
    frame_off: i16 = 0,
    roffset: i16 = 0,
    pad1: [2]u8 = .{ 0, 0 },
};

/// nvdec_av1_pic_s: one AV1 picture's setup (SET_DRV_PIC_SETUP_OFFSET).
/// The padding C leaves is spelt out, so every byte is defined.
pub const Av1Pic = extern struct {
    /// nvdec_pass2_otf_s: encryption, off
    encryption: [13]u32 = [_]u32{0} ** 13,
    /// nvdec_pass2_otf_ext_s
    ssm: [3]u32 = .{ 0, 0, 0 },
    fgs_cfg: FgsCfg = .{},
    gptimer_timeout_value: u32 = 0,
    stream_len: u32 = 0,
    /// bytes to skip before the frame's data (ours start at a tile)
    reserved12: u32 = 0,
    seq: packed struct(u32) {
        use_128x128_superblock: u1 = 0,
        /// 1: 4:2:0
        chroma_format: u2 = 0,
        bit_depth: u4 = 0,
        enable_filter_intra: u1 = 0,
        enable_intra_edge_filter: u1 = 0,
        enable_interintra_compound: u1 = 0,
        enable_masked_compound: u1 = 0,
        enable_dual_filter: u1 = 0,
        reserved10: u1 = 0,
        reserved0: u3 = 0,
        enable_jnt_comp: u1 = 0,
        reserved1: u1 = 0,
        enable_cdef: u1 = 0,
        reserved11: u1 = 0,
        enable_fgs: u1 = 0,
        enable_substream_decoding: u1 = 0,
        reserved2: u10 = 0,
    } = .{},
    frame: packed struct(u32) {
        /// 0 key, 1 inter, 2 intra only, 3 switch
        frame_type: u2 = 0,
        show_frame: u1 = 0,
        reserved13: u1 = 0,
        disable_cdf_update: u1 = 0,
        allow_screen_content_tools: u1 = 0,
        cur_frame_force_integer_mv: u1 = 0,
        scale_denom_minus9: u3 = 0,
        allow_intrabc: u1 = 0,
        allow_high_precision_mv: u1 = 0,
        interp_filter: u3 = 0,
        switchable_motion_mode: u1 = 0,
        use_ref_frame_mvs: u1 = 0,
        refresh_frame_context: u1 = 0,
        delta_q_present_flag: u1 = 0,
        delta_q_res: u2 = 0,
        delta_lf_present_flag: u1 = 0,
        delta_lf_res: u2 = 0,
        delta_lf_multi: u1 = 0,
        reserved3: u1 = 0,
        coded_lossless: u1 = 0,
        tile_enabled: u1 = 0,
        reserved4: u2 = 0,
        superres_is_scaled: u1 = 0,
        reserved_fh: u1 = 0,
    } = .{},
    tiles: packed struct(u32) {
        tile_cols: u8 = 0,
        tile_rows: u8 = 0,
        context_update_tile_id: u16 = 0,
    } = .{},
    tools: packed struct(u32) {
        cdef_damping_minus_3: u2 = 0,
        cdef_bits: u2 = 0,
        /// 0 ONLY_4X4, 3 LARGEST, 4 SELECT
        frame_tx_mode: u3 = 0,
        /// 0 single, 2 select
        frame_reference_mode: u2 = 0,
        skip_mode_flag: u1 = 0,
        /// reference names (LAST 1 .. ALTREF 7)
        skip_ref0: u4 = 0,
        skip_ref1: u4 = 0,
        allow_warp: u1 = 0,
        reduced_tx_set_used: u1 = 0,
        ref_scaling_enable: u1 = 0,
        reserved5: u1 = 0,
        reserved6: u10 = 0,
    } = .{},
    superres_upscaled_width: u16 = 0,
    superres_luma_step: u16 = 0,
    superres_chroma_step: u16 = 0,
    superres_init_luma_subpel_x: u16 = 0,
    superres_init_chroma_subpel_x: u16 = 0,
    base_qindex: u8 = 0,
    y_dc_delta_q: i8 = 0,
    u_dc_delta_q: i8 = 0,
    v_dc_delta_q: i8 = 0,
    u_ac_delta_q: i8 = 0,
    v_ac_delta_q: i8 = 0,
    qm_y: u8 = 0,
    qm_u: u8 = 0,
    qm_v: u8 = 0,
    pad_7b: u8 = 0,
    /// 4 bits a strength, eight of them
    cdef_y_pri_strength: u32 = 0,
    cdef_uv_pri_strength: u32 = 0,
    /// 2 bits a strength (the coded value: 3 means 4)
    cdef_sec: packed struct(u32) {
        y: u16 = 0,
        uv: u16 = 0,
    } = .{},
    segment_enabled: u8 = 0,
    segment_update_map: u8 = 0,
    reserved7: u8 = 0,
    segment_temporal_update: u8 = 0,
    segment_feature_data: [8][8]i16 = [_][8]i16{[_]i16{0} ** 8} ** 8,
    last_active_segid: u8 = 0,
    segid_preskip: u8 = 0,
    /// the primary reference's segment map is read
    prevsegid_flag: u8 = 0,
    /// segments whose alternative quantizer is negative
    segment_quant_sign: u8 = 0,
    filter_level: [2]u8 = .{ 0, 0 },
    filter_level_u: u8 = 0,
    filter_level_v: u8 = 0,
    lf_sharpness_level: u8 = 0,
    lf_ref_deltas: [8]i8 = [_]i8{0} ** 8,
    lf_mode_deltas: [2]i8 = .{ 0, 0 },
    /// FrameRestorationType per plane, 2 bits each (Y, U, V)
    lr_type: u8 = 0,
    /// 0: 32, 1: 64, 2: 128, 3: 256 per plane, 2 bits each
    lr_unit_size: u8 = 0,
    pad_121: [3]u8 = .{ 0, 0, 0 },
    current_frame: FrameInfo = .{},
    /// LAST, LAST2, LAST3, GOLDEN, BWDREF, ALTREF2, ALTREF
    ref_frame: [7]RefFrame = [_]RefFrame{.{}} ** 7,
    mfmv: packed struct(u32) {
        use_temporal0_mvs: u1 = 0,
        use_temporal1_mvs: u1 = 0,
        use_temporal2_mvs: u1 = 0,
        mf1_type: u3 = 0,
        mf2_type: u3 = 0,
        mf3_type: u3 = 0,
        reserved_mfmv: u20 = 0,
    } = .{},
    mfmv_offset: [3][7]i16 = [_][7]i16{[_]i16{0} ** 7} ** 3,
    mfmv_side: [3][7]i8 = [_][7]i8{[_]i8{0} ** 7} ** 3,
    surface: packed struct(u8) {
        /// 0 TBL, 1 KBL (the GPU's block linear)
        tileformat: u2 = 0,
        /// blocks of 2 << gob_height GOBs
        gob_height: u3 = 0,
        errorConcealOn: u1 = 0,
        reserver8: u2 = 0,
    } = .{},
    errors: packed struct(u8) {
        stream_error_detection: u1 = 0,
        mv_error_detection: u1 = 0,
        coeff_error_detection: u1 = 0,
        reserved_eh: u5 = 0,
    } = .{},
    pad_21d: [3]u8 = .{ 0, 0, 0 },
    /// the filter buffer's parts, in 256-byte units from its start
    Av1FltTopOffset: u32 = 0,
    Av1FltVertOffset: u32 = 0,
    Av1CdefVertOffset: u32 = 0,
    Av1LrVertOffset: u32 = 0,
    Av1HusVertOffset: u32 = 0,
    Av1FgsVertOffset: u32 = 0,
    stat: packed struct(u32) {
        enable_histogram: u1 = 0,
        sw_skip_start_length: u14 = 0,
        reserved_stat: u17 = 0,
    } = .{},
};

comptime {
    // (gcc on nvdec_drv.h: each field's offset, each bit field's word)
    std.debug.assert(@sizeOf(FgsCfg) == 12);
    std.debug.assert(@sizeOf(FrameInfo) == 12);
    std.debug.assert(@sizeOf(RefFrame) == 24);
    std.debug.assert(@offsetOf(RefFrame, "frame_off") == 18);
    std.debug.assert(@offsetOf(RefFrame, "roffset") == 20);
    std.debug.assert(@offsetOf(Av1Pic, "ssm") == 0x34);
    std.debug.assert(@offsetOf(Av1Pic, "fgs_cfg") == 0x40);
    std.debug.assert(@offsetOf(Av1Pic, "gptimer_timeout_value") == 0x4c);
    std.debug.assert(@offsetOf(Av1Pic, "stream_len") == 0x50);
    std.debug.assert(@offsetOf(Av1Pic, "reserved12") == 0x54);
    std.debug.assert(@offsetOf(Av1Pic, "seq") == 0x58);
    std.debug.assert(@offsetOf(Av1Pic, "frame") == 0x5c);
    std.debug.assert(@offsetOf(Av1Pic, "tiles") == 0x60);
    std.debug.assert(@offsetOf(Av1Pic, "tools") == 0x64);
    std.debug.assert(@offsetOf(Av1Pic, "superres_upscaled_width") == 0x68);
    std.debug.assert(@offsetOf(Av1Pic, "superres_init_chroma_subpel_x") == 0x70);
    std.debug.assert(@offsetOf(Av1Pic, "base_qindex") == 0x72);
    std.debug.assert(@offsetOf(Av1Pic, "v_ac_delta_q") == 0x77);
    std.debug.assert(@offsetOf(Av1Pic, "qm_v") == 0x7a);
    std.debug.assert(@offsetOf(Av1Pic, "cdef_y_pri_strength") == 0x7c);
    std.debug.assert(@offsetOf(Av1Pic, "cdef_sec") == 0x84);
    std.debug.assert(@offsetOf(Av1Pic, "segment_enabled") == 0x88);
    std.debug.assert(@offsetOf(Av1Pic, "segment_feature_data") == 0x8c);
    std.debug.assert(@offsetOf(Av1Pic, "last_active_segid") == 0x10c);
    std.debug.assert(@offsetOf(Av1Pic, "segment_quant_sign") == 0x10f);
    std.debug.assert(@offsetOf(Av1Pic, "filter_level") == 0x110);
    std.debug.assert(@offsetOf(Av1Pic, "lf_sharpness_level") == 0x114);
    std.debug.assert(@offsetOf(Av1Pic, "lf_ref_deltas") == 0x115);
    std.debug.assert(@offsetOf(Av1Pic, "lf_mode_deltas") == 0x11d);
    std.debug.assert(@offsetOf(Av1Pic, "lr_type") == 0x11f);
    std.debug.assert(@offsetOf(Av1Pic, "lr_unit_size") == 0x120);
    std.debug.assert(@offsetOf(Av1Pic, "current_frame") == 0x124);
    std.debug.assert(@offsetOf(Av1Pic, "ref_frame") == 0x130);
    std.debug.assert(@offsetOf(Av1Pic, "mfmv") == 0x1d8);
    std.debug.assert(@offsetOf(Av1Pic, "mfmv_offset") == 0x1dc);
    std.debug.assert(@offsetOf(Av1Pic, "mfmv_side") == 0x206);
    std.debug.assert(@offsetOf(Av1Pic, "surface") == 0x21b);
    std.debug.assert(@offsetOf(Av1Pic, "errors") == 0x21c);
    std.debug.assert(@offsetOf(Av1Pic, "Av1FltTopOffset") == 0x220);
    std.debug.assert(@offsetOf(Av1Pic, "Av1LrVertOffset") == 0x22c);
    std.debug.assert(@offsetOf(Av1Pic, "Av1HusVertOffset") == 0x230);
    std.debug.assert(@offsetOf(Av1Pic, "Av1FgsVertOffset") == 0x234);
    std.debug.assert(@offsetOf(Av1Pic, "stat") == 0x238);
    std.debug.assert(@sizeOf(Av1Pic) == 0x23c);
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

/// Blackwell's word past Ada's struct (State.blackwell): ceil(width / 128)
/// + 1 at 0x244.
pub const BLACKWELL_WORD_AT: usize = 0x244;
pub const MAX_PIC_BYTES: usize = 0x248;

// ── Per-frame side buffers (the frame slot's aux) ───────────────────────────

/// nvdec_drv.h's AV1_MAX_TILES.
pub const MAX_TILES = 256;
/// AV1TileInfo_OLD: width and height in superblocks, the tile's start and
/// end in the bitstream (little-endian), 6 bytes of padding.
pub const TILE_ENTRY: usize = 16;
pub const TILES_OFF: usize = 0;
pub const TILES_BYTES: usize = MAX_TILES * TILE_ENTRY;
/// Seven references' global motion, 32 bytes each (AV1_GLOBAL_MOTION_BUF_SIZE).
pub const GM_OFF: usize = 0x1000;
pub const GM_ENTRY: usize = 32;
pub const MAX_AUX_BYTES: usize = GM_OFF + 0x100;

comptime {
    std.debug.assert(MAX_PIC_BYTES <= codec.PIC_BYTES and MAX_AUX_BYTES <= codec.AUX_BYTES);
    std.debug.assert(TILES_OFF + TILES_BYTES <= GM_OFF);
}

// ── The context's buffers (scratch) ─────────────────────────────────────────

/// Frames whose state can be alive at once: the eight reference slots'
/// (at most eight surfaces) and the one being decoded.
pub const POOL = 9;
/// One CDF table's room (12256 bytes, 256-aligned).
pub const CDF_STRIDE: usize = 0x3000;
/// The picture slot of the current picture.
pub const CUR_SLOT: u5 = 8;

const INTRA_TOP_BYTES: usize = 8 * 8192; // AV1_INTRA_TOP_BUF_SIZE
const FGS_BYTES: usize = 13056; // AV1_FGS_BUF_SIZE: sizeof(AV1FilmGrainMemory)

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) / a * a;
}

/// Where each of the context's buffers is in the scratch, by nvdec_drv.h's
/// sizes for the context's size.
pub const Layout = struct {
    /// AV1_TEMPORAL_MV_BUF_SIZE, AV1_SEGMENT_ID_BUF_SIZE
    mv_bytes: usize,
    seg_bytes: usize,
    /// four default tables (quantizer contexts 0..3), then POOL written ones
    cdf_off: usize,
    mv_off: usize,
    seg_off: usize,
    /// never written by the decoder: no segment map, no motion vectors, no
    /// film grain
    zero_off: usize,
    filter_off: usize,
    /// the filter buffer's parts in 256-byte units: deblocking top, its
    /// vertical (left) part, CDEF, the upscaler (ping-pong), restoration,
    /// film grain (NVK's traced order)
    flt: [6]u32,
    intra_top_off: usize,
    blk_off: usize,
    bytes: usize,

    pub fn of(width: u32, height: u32) Layout {
        const w: usize = width;
        const h: usize = height;
        const area64 = alignUp(w, 128) * alignUp(h, 128) / (64 * 64);
        const mv_bytes = alignUp(area64 * 256, 4096);
        const seg_bytes = alignUp(area64 * 128, 4096);
        const cols = alignUp(w, 64) / 64 + 2;
        const rows = alignUp(h, 64) / 64 + 2;
        const parts = [6]usize{
            alignUp(cols * alignUp(1920, 128), 256), // AV1_DBLK_TOP_BUF_SIZE
            alignUp(rows * alignUp(1536, 128), 256), // AV1_DBLK_LEFT_BUF_SIZE
            alignUp(rows * alignUp(1792, 128), 256), // AV1_CDEF_LEFT_BUF_SIZE
            2 * alignUp(rows * alignUp(12544, 128), 256), // AV1_HUS_LEFT_BUF_SIZE
            alignUp(rows * alignUp(1920, 128), 256), // AV1_LR_LEFT_BUF_SIZE
            alignUp(rows * alignUp(320, 128), 256), // AV1_FGS_LEFT_BUF_SIZE
        };
        var l: Layout = undefined;
        l.mv_bytes = mv_bytes;
        l.seg_bytes = seg_bytes;
        var at: usize = 0;
        l.cdf_off = at;
        at += (4 + POOL) * CDF_STRIDE;
        l.mv_off = at;
        at += POOL * mv_bytes;
        l.seg_off = at;
        at += POOL * seg_bytes;
        l.zero_off = at;
        at += alignUp(@max(mv_bytes, seg_bytes, FGS_BYTES), 256);
        l.filter_off = at;
        var f: usize = 0;
        for (parts, 0..) |p, i| {
            l.flt[i] = @intCast(f >> 8);
            f += p;
        }
        at += f;
        l.intra_top_off = at;
        at += INTRA_TOP_BYTES;
        l.blk_off = at;
        at += blkUnits(width) * 16384;
        l.bytes = at;
        return l;
    }

    pub fn defaultCdf(l: Layout, q: u2) usize {
        return l.cdf_off + @as(usize, q) * CDF_STRIDE;
    }
    pub fn poolCdf(l: Layout, k: usize) usize {
        return l.cdf_off + (4 + k) * CDF_STRIDE;
    }
    pub fn mv(l: Layout, k: usize) usize {
        return l.mv_off + k * l.mv_bytes;
    }
    pub fn seg(l: Layout, k: usize) usize {
        return l.seg_off + k * l.seg_bytes;
    }
};

/// Blackwell's extra buffer, in 16 KiB blocks (AROS's trace).
fn blkUnits(width: u32) usize {
    return (@as(usize, width) + 127) / 128 + 1;
}

pub fn scratchBytes(width: u32, height: u32) usize {
    return Layout.of(width, height).bytes;
}

// ── The state ───────────────────────────────────────────────────────────────

const NONE: u32 = 0xffff_ffff;
const PRIMARY_REF_NONE = 7;
const KEY_FRAME = 0;
const INTER_FRAME = 1;
const INTRA_ONLY_FRAME = 2;
const SWITCH_FRAME = 3;

/// What a later frame needs of a decoded one, kept by its surface.
pub const Saved = struct {
    /// NONE: a free entry
    surface: u32 = NONE,
    /// its motion vectors' and segment map's pool entry
    buf: u8 = 0,
    /// its CDF table: 0..3 a default table (by quantizer context), 4 + k
    /// the pool's table k
    cdf: u8 = 0,
    frame_type: u2 = 0,
    order_hint: u8 = 0,
    /// the order hints of its references, LAST .. ALTREF
    ref_order_hint: [7]u8 = [_]u8{0} ** 7,
    upscaled_width: u16 = 0,
    height: u16 = 0,
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    /// it had segmentation on (its segment map was written)
    segmap: bool = false,
};

pub const State = struct {
    width: u32,
    height: u32,
    layout: Layout,
    /// Blackwell's extra fields and buffer as AROS's trace has them (see
    /// the header); off: Ada's public layout.
    blackwell: bool = false,
    saved: [POOL]Saved = [_]Saved{.{}} ** POOL,
    defaults_written: bool = false,
    /// the pool table whose MV CDFs `after` resets (intrabc)
    fixup: ?u8 = null,
    // ── the picture being made ──
    pic: PictureParameterBufferAV1 = undefined,
    have_pic: bool = false,
    params: ?codec.Buffer = null,
    stream: usize = 0,
    tile_start: [MAX_TILES]u32 = undefined,
    tile_end: [MAX_TILES]u32 = undefined,
    tile_seen: [MAX_TILES]bool = [_]bool{false} ** MAX_TILES,

    pub fn init(width: u32, height: u32) State {
        return .{ .width = width, .height = height, .layout = Layout.of(width, height) };
    }
};

pub fn begin(st: *State) void {
    st.have_pic = false;
    st.params = null;
    st.stream = 0;
    st.tile_seen = [_]bool{false} ** MAX_TILES;
}

/// Zero bytes after the bitstream (not counted in stream_len), so a read
/// past a tile's end finds nothing.
const STREAM_PAD: usize = 256;

pub fn take(st: *State, b: codec.Buffer, slot: codec.Slot) va.Status {
    switch (b.kind) {
        va.PICTURE_PARAMETER_BUFFER => {
            if (b.data.len < @sizeOf(PictureParameterBufferAV1)) return va.ERROR_INVALID_BUFFER;
            const p = b.element(PictureParameterBufferAV1, 0);
            const s = p.seq_info_fields;
            if (p.profile != 0) return va.ERROR_UNSUPPORTED_PROFILE;
            // Main: 8- and 10-bit 4:2:0 (a 10-bit picture: a P010 target)
            if (p.bit_depth_idx > 1 or s.mono_chrome != 0 or s.subsampling_x != 1 or s.subsampling_y != 1) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            if (p.pic_info_fields.large_scale_tile != 0) return va.ERROR_UNIMPLEMENTED;
            if (p.tile_cols == 0 or p.tile_rows == 0 or p.tile_cols > 64 or p.tile_rows > 64) return va.ERROR_INVALID_PARAMETER;
            if (@as(u32, p.tile_cols) * p.tile_rows > MAX_TILES) return va.ERROR_MAX_NUM_EXCEEDED;
            st.pic = p;
            st.have_pic = true;
        },
        va.SLICE_PARAMETER_BUFFER => {
            if (b.size < @sizeOf(SliceParameterBufferAV1) or b.count == 0) return va.ERROR_INVALID_BUFFER;
            st.params = b;
        },
        va.SLICE_DATA_BUFFER => {
            const params = st.params orelse return va.ERROR_INVALID_BUFFER;
            if (!st.have_pic) return va.ERROR_INVALID_BUFFER;
            if (st.stream + b.data.len + STREAM_PAD > slot.stream.len) return va.ERROR_NOT_ENOUGH_BUFFER;
            const cols: u32 = st.pic.tile_cols;
            const tiles = cols * st.pic.tile_rows;
            // (a tile group's data whole; each tile's start and end in it)
            for (0..params.count) |k| {
                const t = params.element(SliceParameterBufferAV1, k);
                if (@as(u64, t.slice_data_offset) + t.slice_data_size > b.data.len) return va.ERROR_INVALID_BUFFER;
                if (t.tile_column >= cols or t.tile_row >= st.pic.tile_rows) return va.ERROR_INVALID_PARAMETER;
                const i = @as(u32, t.tile_row) * cols + t.tile_column;
                std.debug.assert(i < tiles);
                st.tile_start[i] = @intCast(st.stream + t.slice_data_offset);
                st.tile_end[i] = @intCast(st.stream + t.slice_data_offset + t.slice_data_size);
                st.tile_seen[i] = true;
            }
            @memcpy(slot.stream[st.stream..][0..b.data.len], b.data);
            st.stream += b.data.len;
            st.params = null;
        },
        else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
    }
    return va.SUCCESS;
}

// ── What VA-API leaves to the driver (the AV1 specification's processes) ────

/// The coefficient CDFs' quantizer context (spec get_qctx, libaom's).
pub fn qContext(base_q_idx: u8) u2 {
    if (base_q_idx <= 20) return 0;
    if (base_q_idx <= 60) return 1;
    if (base_q_idx <= 120) return 2;
    return 3;
}

/// Spec get_relative_dist.
pub fn relativeDist(p: *const PictureParameterBufferAV1, a: i32, b: i32) i32 {
    if (p.seq_info_fields.enable_order_hint == 0) return 0;
    const diff = a - b;
    const m = @as(i32, 1) << @intCast(p.order_hint_bits_minus_1);
    return (diff & (m - 1)) - (diff & m);
}

/// The frame's sizes: VA's is the upscaled one; with superres the coded
/// width is smaller (spec 7.21: compute_image_size, superres_params).
pub const Size = struct {
    upscaled_width: u32,
    width: u32,
    height: u32,
    mi_cols: u32,
    mi_rows: u32,
};

pub fn frameSize(p: *const PictureParameterBufferAV1) Size {
    const up = @as(u32, p.frame_width_minus1) + 1;
    const h = @as(u32, p.frame_height_minus1) + 1;
    var w = up;
    if (p.pic_info_fields.use_superres != 0 and p.superres_scale_denominator > 8) {
        const d: u32 = p.superres_scale_denominator;
        w = @max((up * 8 + d / 2) / d, @min(16, up));
    }
    return .{ .upscaled_width = up, .width = w, .height = h, .mi_cols = 2 * ((w + 7) >> 3), .mi_rows = 2 * ((h + 7) >> 3) };
}

/// Each tile column's width and each row's height in superblocks (spec
/// tile_info: uniform spacing from the counts; otherwise VA's sizes, the
/// last one the rest of the frame). False: they do not add up.
pub fn tileSizes(p: *const PictureParameterBufferAV1, sz: Size, widths: *[64]u16, heights: *[64]u16) bool {
    const sb128 = p.seq_info_fields.use_128x128_superblock != 0;
    const sb_cols = if (sb128) (sz.mi_cols + 31) >> 5 else (sz.mi_cols + 15) >> 4;
    const sb_rows = if (sb128) (sz.mi_rows + 31) >> 5 else (sz.mi_rows + 15) >> 4;
    if (p.pic_info_fields.uniform_tile_spacing_flag != 0) {
        return uniform(sb_cols, p.tile_cols, widths) and uniform(sb_rows, p.tile_rows, heights);
    }
    return explicitSizes(sb_cols, p.tile_cols, &p.width_in_sbs_minus_1, widths) and
        explicitSizes(sb_rows, p.tile_rows, &p.height_in_sbs_minus_1, heights);
}

fn uniform(sbs: u32, count: u32, out: *[64]u16) bool {
    // (the log2 whose uniform split gives `count` tiles)
    var log2: u5 = 0;
    while (log2 <= 6) : (log2 += 1) {
        const size = (sbs + (@as(u32, 1) << log2) - 1) >> log2;
        if (size == 0) return false;
        if ((sbs + size - 1) / size != count) continue;
        var left = sbs;
        for (0..count) |i| {
            const this = @min(size, left);
            out[i] = @intCast(this);
            left -= this;
        }
        return true;
    }
    return false;
}

fn explicitSizes(sbs: u32, count: u32, minus1: *const [63]u16, out: *[64]u16) bool {
    var used: u32 = 0;
    for (0..count - 1) |i| {
        out[i] = minus1[i] + 1;
        used += out[i];
    }
    if (used >= sbs) return false;
    out[count - 1] = @intCast(sbs - used);
    return true;
}

/// Spec 7.11.3.7's Div_Lut: round((1 << 14) * 256 / (256 + i)).
pub const DIV_LUT: [257]u16 = blk: {
    var t: [257]u16 = undefined;
    for (0..257) |i| t[i] = @intCast(((1 << 22) + (256 + i) / 2) / (256 + i));
    break :blk t;
};

fn round2Signed(x: i64, n: u6) i64 {
    if (n == 0) return x;
    const half = @as(i64, 1) << (n - 1);
    return if (x >= 0) (x + half) >> n else -((-x + half) >> n);
}

fn clip16(x: i64) i16 {
    return @intCast(std.math.clamp(x, -32768, 32767));
}

/// Spec 7.11.3.6 setupShear: alpha, beta, gamma, delta of a warp's matrix
/// (zeros for one without a scale, wmmat[2] 0).
pub fn shear(m: *const [8]i32) [4]i16 {
    if (m[2] <= 0) return .{ 0, 0, 0, 0 };
    const d: u64 = @intCast(m[2]);
    const n: u6 = @intCast(63 - @clz(d));
    const e = d - (@as(u64, 1) << n);
    const f: u64 = if (n > 8) @intCast(round2Signed(@intCast(e), n - 8)) else e << @intCast(8 - n);
    const div: i64 = DIV_LUT[@intCast(f)];
    const shift: u6 = n + 14;
    const alpha0 = clip16(@as(i64, m[2]) - (1 << 16));
    const beta0 = clip16(m[3]);
    const gamma0 = clip16(round2Signed((@as(i64, m[4]) << 16) * div, shift));
    const delta0 = clip16(@as(i64, m[5]) - round2Signed(@as(i64, m[3]) * m[4] * div, shift) - (1 << 16));
    var out: [4]i16 = undefined;
    for ([4]i16{ alpha0, beta0, gamma0, delta0 }, 0..) |v, i| out[i] = @intCast(round2Signed(v, 6) * 64);
    return out;
}

/// libaom's av1_upscale_normative steps (spec 7.16): the step and the
/// first position for one plane, `down` coded samples to `up`.
fn superresStep(down: i64, up: i64) struct { step: u16, x0: u16 } {
    const step = @divTrunc((down << 14) + @divTrunc(up, 2), up);
    const err = up * step - (down << 14);
    const x0 = @divTrunc(-((up - down) << 13) + @divTrunc(up, 2), up) + 128 - @divTrunc(err, 2);
    return .{ .step = @intCast(step), .x0 = @intCast(x0 & 0x3fff) };
}

// ── A frame's setup ─────────────────────────────────────────────────────────

/// A resolved reference: what was kept of it, its surface's pitches.
pub const Ref = struct {
    saved: Saved,
    pitch_luma: u32,
    pitch_chroma: u32,
};

/// What one picture's setup is made from.
pub const Frame = struct {
    p: *const PictureParameterBufferAV1,
    /// the tiles' bytes (STREAM_PAD not counted)
    stream_len: u32,
    pitch_luma: u32,
    pitch_chroma: u32,
    gob_height: u3,
    /// the pictures' bytes a sample: 2 for a 10-bit frame (P010 targets
    /// and references; the setup's strides count samples)
    sample_bytes: u8 = 1,
    /// LAST .. ALTREF (null: an intra frame's, or not known)
    refs: [7]?Ref = [_]?Ref{null} ** 7,
    /// the primary reference's state (null: none)
    prim: ?Saved = null,
    layout: *const Layout,
    blackwell: bool = false,
};

pub const Setup = struct {
    pic: Av1Pic,
    /// the motion field's sources: reference indices (0 LAST .. 6 ALTREF)
    mf: [3]?u3 = .{ null, null, null },
};

fn intra(frame_type: u2) bool {
    return frame_type == KEY_FRAME or frame_type == INTRA_ONLY_FRAME;
}

/// The decoder's setup for `f` (VA-API's fields; what VA leaves out worked
/// out by the spec).
pub fn av1Setup(f: Frame) Setup {
    const p = f.p;
    const seq = p.seq_info_fields;
    const pf = p.pic_info_fields;
    const mc = p.mode_control_fields;
    const sz = frameSize(p);
    const is_intra = intra(pf.frame_type);
    var out = Setup{ .pic = .{} };
    const s = &out.pic;

    s.gptimer_timeout_value = nvdec.GPTIMER_TIMEOUT;
    s.stream_len = f.stream_len;
    s.seq = .{
        .use_128x128_superblock = seq.use_128x128_superblock,
        .chroma_format = 1,
        .bit_depth = if (p.bit_depth_idx == 1) 10 else 8,
        .enable_filter_intra = seq.enable_filter_intra,
        .enable_intra_edge_filter = seq.enable_intra_edge_filter,
        .enable_interintra_compound = seq.enable_interintra_compound,
        .enable_masked_compound = seq.enable_masked_compound,
        .enable_dual_filter = seq.enable_dual_filter,
        .enable_jnt_comp = seq.enable_jnt_comp,
        // (off where CDEF does nothing: one strength set, all zero)
        .enable_cdef = @intFromBool(seq.enable_cdef != 0 and (p.cdef_bits != 0 or p.cdef_y_strengths[0] != 0 or p.cdef_uv_strengths[0] != 0)),
    };
    const scaled = sz.width != sz.upscaled_width;
    s.frame = .{
        // (VA: a switch frame is decoded as an inter frame)
        .frame_type = if (pf.frame_type == SWITCH_FRAME) INTER_FRAME else pf.frame_type,
        .show_frame = pf.show_frame,
        .disable_cdf_update = pf.disable_cdf_update,
        .allow_screen_content_tools = pf.allow_screen_content_tools,
        .cur_frame_force_integer_mv = pf.force_integer_mv,
        .scale_denom_minus9 = if (pf.use_superres != 0 and p.superres_scale_denominator >= 9) @intCast(p.superres_scale_denominator - 9) else 0,
        .allow_intrabc = pf.allow_intrabc,
        .allow_high_precision_mv = pf.allow_high_precision_mv,
        .interp_filter = @intCast(p.interp_filter & 7),
        .switchable_motion_mode = pf.is_motion_mode_switchable,
        .use_ref_frame_mvs = pf.use_ref_frame_mvs,
        .refresh_frame_context = @intFromBool(pf.disable_frame_end_update_cdf == 0),
        .delta_q_present_flag = mc.delta_q_present_flag,
        .delta_q_res = mc.log2_delta_q_res,
        .delta_lf_present_flag = mc.delta_lf_present_flag,
        .delta_lf_res = mc.log2_delta_lf_res,
        .delta_lf_multi = mc.delta_lf_multi,
        .coded_lossless = @intFromBool(codedLossless(p)),
        .tile_enabled = @intFromBool(@as(u32, p.tile_cols) * p.tile_rows > 1),
        .superres_is_scaled = @intFromBool(scaled),
    };
    s.tiles = .{ .tile_cols = p.tile_cols, .tile_rows = p.tile_rows, .context_update_tile_id = p.context_update_tile_id };
    const tx_mode = [4]u3{ 0, 3, 4, 4 };
    s.tools = .{
        .cdef_damping_minus_3 = @intCast(p.cdef_damping_minus_3 & 3),
        .cdef_bits = @intCast(p.cdef_bits & 3),
        .frame_tx_mode = tx_mode[mc.tx_mode],
        .frame_reference_mode = if (mc.reference_select != 0) 2 else 0,
        .allow_warp = pf.allow_warped_motion,
        .reduced_tx_set_used = mc.reduced_tx_set_used,
    };

    // Superres (NVK's and the trace's 14 for a step when not scaled).
    s.superres_upscaled_width = @intCast(sz.upscaled_width);
    s.superres_luma_step = 14;
    s.superres_chroma_step = 14;
    if (scaled) {
        const l = superresStep(sz.width, sz.upscaled_width);
        const c = superresStep((sz.width + 1) >> 1, (sz.upscaled_width + 1) >> 1);
        s.superres_luma_step = l.step;
        s.superres_chroma_step = c.step;
        s.superres_init_luma_subpel_x = l.x0;
        s.superres_init_chroma_subpel_x = c.x0;
    }

    // Quantizer.
    s.base_qindex = p.base_qindex;
    s.y_dc_delta_q = p.y_dc_delta_q;
    s.u_dc_delta_q = p.u_dc_delta_q;
    s.v_dc_delta_q = p.v_dc_delta_q;
    s.u_ac_delta_q = p.u_ac_delta_q;
    s.v_ac_delta_q = p.v_ac_delta_q;
    const qm = p.qmatrix_fields;
    s.qm_y = if (qm.using_qmatrix != 0) qm.qm_y else 15;
    s.qm_u = if (qm.using_qmatrix != 0) qm.qm_u else 15;
    s.qm_v = if (qm.using_qmatrix != 0) qm.qm_v else 15;

    // CDEF: VA packs (primary << 2) | secondary.
    var ysec: u16 = 0;
    var uvsec: u16 = 0;
    for (0..@as(usize, 1) << @intCast(p.cdef_bits & 3)) |i| {
        s.cdef_y_pri_strength |= @as(u32, (p.cdef_y_strengths[i] >> 2) & 15) << @intCast(4 * i);
        s.cdef_uv_pri_strength |= @as(u32, (p.cdef_uv_strengths[i] >> 2) & 15) << @intCast(4 * i);
        ysec |= @as(u16, p.cdef_y_strengths[i] & 3) << @intCast(2 * i);
        uvsec |= @as(u16, p.cdef_uv_strengths[i] & 3) << @intCast(2 * i);
    }
    s.cdef_sec = .{ .y = ysec, .uv = uvsec };

    // Segmentation (spec 5.9.14's LastActiveSegId and SegIdPreSkip).
    const sg = &p.seg_info;
    if (sg.segment_info_fields.enabled != 0) {
        s.segment_enabled = 1;
        s.segment_update_map = sg.segment_info_fields.update_map;
        s.segment_temporal_update = sg.segment_info_fields.temporal_update;
        for (0..8) |i| {
            const mask = sg.feature_mask[i];
            for (0..8) |j| {
                if (mask & (@as(u8, 1) << @intCast(j)) != 0) s.segment_feature_data[i][j] = sg.feature_data[i][j];
            }
            if (mask != 0) s.last_active_segid = @intCast(i);
            if (mask & 0xe0 != 0) s.segid_preskip = 1;
            if (mask & 1 != 0 and sg.feature_data[i][0] < 0) s.segment_quant_sign |= @as(u8, 1) << @intCast(i);
        }
    }
    if (f.prim) |pr| {
        s.prevsegid_flag = @intFromBool(pr.segmap and pr.mi_cols == sz.mi_cols and pr.mi_rows == sz.mi_rows);
    }

    // Loop filter, restoration.
    s.filter_level = p.filter_level;
    s.filter_level_u = p.filter_level_u;
    s.filter_level_v = p.filter_level_v;
    s.lf_sharpness_level = p.loop_filter_info_fields.sharpness_level;
    if (p.loop_filter_info_fields.mode_ref_delta_enabled != 0) {
        s.lf_ref_deltas = p.ref_deltas;
        s.lf_mode_deltas = p.mode_deltas;
    }
    const lr = p.loop_restoration_fields;
    s.lr_type = @as(u8, lr.yframe_restoration_type) | (@as(u8, lr.cbframe_restoration_type) << 2) | (@as(u8, lr.crframe_restoration_type) << 4);
    if (s.lr_type == 0) {
        // (the trace's: 256 everywhere when nothing is restored)
        s.lr_unit_size = 0x3f;
    } else {
        const y: u8 = @as(u8, lr.lr_unit_shift) + 1;
        const uv: u8 = y - lr.lr_uv_shift;
        s.lr_unit_size = y | (uv << 2) | (uv << 4);
    }

    // The pictures. Their strides in units of 16 samples (16 bytes for
    // 8-bit, as NVK traced; 32 for a 10-bit frame's 2-byte samples, as
    // the decoder's other codecs count 10-bit strides in samples)
    const stride_unit: u32 = 16 * @as(u32, f.sample_bytes);
    s.current_frame = .{
        .width = @intCast(sz.width),
        .height = @intCast(sz.height),
        .stride = .{ @intCast(f.pitch_luma / stride_unit), @intCast(f.pitch_chroma / stride_unit) },
        .frame_buffer_idx = CUR_SLOT,
    };
    const cur_hint: i32 = p.order_hint;
    if (!is_intra) {
        for (f.refs, 0..) |ref, i| {
            const r = ref orelse continue;
            const sv = r.saved;
            const rh: i32 = sv.order_hint;
            const x_scale = ((@as(u32, sv.upscaled_width) << 14) + sz.width / 2) / sz.width;
            const y_scale = ((@as(u32, sv.height) << 14) + sz.height / 2) / sz.height;
            if (x_scale != 1 << 14 or y_scale != 1 << 14) s.tools.ref_scaling_enable = 1;
            s.ref_frame[i] = .{
                .info = .{
                    .width = sv.upscaled_width,
                    .height = sv.height,
                    .stride = .{ @intCast(r.pitch_luma / stride_unit), @intCast(r.pitch_chroma / stride_unit) },
                    .frame_buffer_idx = @intCast(i),
                },
                .x_scale_fp = @intCast(@min(x_scale, 0x7fff)),
                .y_scale_fp = @intCast(@min(y_scale, 0x7fff)),
                .bits = .{
                    .sign_bias = @intFromBool(relativeDist(p, rh, cur_hint) > 0),
                    .wmtype = @intCast(p.wm[i].wmtype & 3),
                },
                .frame_off = @intCast(relativeDist(p, cur_hint, rh)),
                .roffset = @intCast(relativeDist(p, rh, cur_hint)),
            };
        }
        if (mc.skip_mode_present != 0) skipMode(p, f.refs, s);
        if (pf.use_ref_frame_mvs != 0 and seq.enable_order_hint != 0) out.mf = motionField(p, f.refs, sz, s);
    }

    s.surface = .{ .tileformat = 1, .gob_height = f.gob_height };
    const l = f.layout;
    s.Av1FltTopOffset = l.flt[0];
    s.Av1FltVertOffset = l.flt[1];
    s.Av1CdefVertOffset = l.flt[2];
    s.Av1HusVertOffset = l.flt[3];
    s.Av1LrVertOffset = l.flt[4];
    s.Av1FgsVertOffset = l.flt[5];
    if (f.blackwell) {
        s.reserved12 = 0xffff;
        s.stat.reserved_stat = 9;
    }
    return out;
}

/// CodedLossless (spec 5.9.12): every segment's quantizer 0, no DC/AC deltas.
fn codedLossless(p: *const PictureParameterBufferAV1) bool {
    if (p.y_dc_delta_q != 0 or p.u_dc_delta_q != 0 or p.u_ac_delta_q != 0 or p.v_dc_delta_q != 0 or p.v_ac_delta_q != 0) return false;
    const sg = &p.seg_info;
    for (0..8) |i| {
        var q: i32 = p.base_qindex;
        if (sg.segment_info_fields.enabled != 0 and sg.feature_mask[i] & 1 != 0) q += sg.feature_data[i][0];
        if (std.math.clamp(q, 0, 255) != 0) return false;
    }
    return true;
}

/// SkipModeFrame[0..1] (spec 5.9.22), as reference names.
fn skipMode(p: *const PictureParameterBufferAV1, refs: [7]?Ref, s: *Av1Pic) void {
    const cur: i32 = p.order_hint;
    var fwd: ?usize = null;
    var bwd: ?usize = null;
    var fwd_hint: i32 = 0;
    var bwd_hint: i32 = 0;
    for (refs, 0..) |ref, i| {
        const r = ref orelse continue;
        const h: i32 = r.saved.order_hint;
        if (relativeDist(p, h, cur) < 0) {
            if (fwd == null or relativeDist(p, h, fwd_hint) > 0) {
                fwd = i;
                fwd_hint = h;
            }
        } else if (relativeDist(p, h, cur) > 0) {
            if (bwd == null or relativeDist(p, h, bwd_hint) < 0) {
                bwd = i;
                bwd_hint = h;
            }
        }
    }
    const a = fwd orelse return;
    var other = bwd;
    if (other == null) {
        var second_hint: i32 = 0;
        for (refs, 0..) |ref, i| {
            const r = ref orelse continue;
            const h: i32 = r.saved.order_hint;
            if (relativeDist(p, h, fwd_hint) < 0 and (other == null or relativeDist(p, h, second_hint) > 0)) {
                other = i;
                second_hint = h;
            }
        }
    }
    const b = other orelse return;
    s.tools.skip_mode_flag = 1;
    s.tools.skip_ref0 = @intCast(1 + @min(a, b));
    s.tools.skip_ref1 = @intCast(1 + @max(a, b));
}

/// The motion field's sources (libaom av1_setup_motion_field: LAST unless
/// an overlay, then BWDREF, ALTREF2, ALTREF ahead of the frame, LAST2,
/// three at most) and their references' offsets.
fn motionField(p: *const PictureParameterBufferAV1, refs: [7]?Ref, sz: Size, s: *Av1Pic) [3]?u3 {
    const cur: i32 = p.order_hint;
    var mf = [3]?u3{ null, null, null };
    var n: usize = 0;
    const usable = struct {
        fn f(r: ?Ref, size: Size) bool {
            const v = r orelse return false;
            return !intra(v.saved.frame_type) and v.saved.mi_cols == size.mi_cols and v.saved.mi_rows == size.mi_rows;
        }
    }.f;
    var stamp: i32 = 2;
    if (refs[0]) |last| {
        const overlay = if (refs[3]) |golden| last.saved.ref_order_hint[6] == golden.saved.order_hint else false;
        if (!overlay and usable(refs[0], sz)) {
            mf[n] = 0;
            n += 1;
        }
        stamp -= 1;
    }
    for ([3]u3{ 4, 5, 6 }) |i| {
        const r = refs[i] orelse continue;
        if (relativeDist(p, r.saved.order_hint, cur) <= 0) continue;
        if (i == 6 and stamp < 0) continue;
        if (!usable(refs[i], sz) or n == 3) continue;
        mf[n] = i;
        n += 1;
        stamp -= 1;
    }
    if (stamp >= 0 and usable(refs[1], sz) and n < 3) {
        mf[n] = 1;
        n += 1;
    }
    for (mf[0..n], 0..) |src, k| {
        const sv = refs[src.?].?.saved;
        for (0..7) |j| {
            const off = relativeDist(p, sv.order_hint, sv.ref_order_hint[j]);
            s.mfmv_offset[k][j] = @intCast(off);
            s.mfmv_side[k][j] = @intFromBool(off < 0);
        }
    }
    s.mfmv = .{
        .use_temporal0_mvs = @intFromBool(n > 0),
        .use_temporal1_mvs = @intFromBool(n > 1),
        .use_temporal2_mvs = @intFromBool(n > 2),
        .mf1_type = if (mf[0]) |v| @as(u3, v) + 1 else 0,
        .mf2_type = if (mf[1]) |v| @as(u3, v) + 1 else 0,
        .mf3_type = if (mf[2]) |v| @as(u3, v) + 1 else 0,
    };
    return mf;
}

// ── One frame's pushbuffer ──────────────────────────────────────────────────

pub const Addrs = struct {
    pic_setup: u64,
    bitstream: u64,
    status: u64,
    coloc: u64,
    tile_info: u64,
    global_motion: u64,
    film_grain: u64,
    seg_read: u64,
    seg_write: u64,
    col_mv: [3]u64,
    col_mv_write: u64,
    filter: u64,
    intra_top: u64,
    prob_read: u64,
    prob_write: u64,
    /// Blackwell's extra buffer (State.blackwell), or none
    blk: ?u64 = null,
    luma: [nvdec.SLOTS]u64,
    chroma: [nvdec.SLOTS]u64,
};

pub const PUSH_DWORDS = 2 * 7 + 2 * 15 + 2 * (1 + nvdec.SLOTS) + 2;

/// One AV1 frame's methods: the decoder bound, the application, the
/// controls, the picture index, the setup, the bitstream, the status, the
/// AV1 buffers (in the traced driver's order), the picture slots, EXECUTE.
pub fn av1Push(out: []u32, a: Addrs) usize {
    var n: usize = 0;
    codec.bind(out, &n);
    codec.put(out, &n, nvdec.SET_APPLICATION_ID, APPLICATION_ID_AV1);
    codec.put(out, &n, nvdec.SET_CONTROL_PARAMS, codec.controlParams(CODEC_TYPE_AV1, 0));
    codec.put(out, &n, nvdec.SET_PICTURE_INDEX, CUR_SLOT);
    codec.put(out, &n, nvdec.SET_DRV_PIC_SETUP_OFFSET, nvdec.shifted(a.pic_setup));
    codec.put(out, &n, nvdec.SET_IN_BUF_BASE_OFFSET, nvdec.shifted(a.bitstream));
    codec.put(out, &n, nvdec.SET_NVDEC_STATUS_OFFSET, nvdec.shifted(a.status));
    codec.put(out, &n, nvdec.SET_COLOC_DATA_OFFSET, nvdec.shifted(a.coloc));
    codec.put(out, &n, SET_TILE_SIZE_BUF_OFFSET, nvdec.shifted(a.tile_info));
    codec.put(out, &n, AV1_SET_GLOBAL_MODEL_BUF_OFFSET, nvdec.shifted(a.global_motion));
    codec.put(out, &n, AV1_SET_FILM_GRAIN_BUF_OFFSET, nvdec.shifted(a.film_grain));
    codec.put(out, &n, AV1_SET_SEGMENT_READ_BUF_OFFSET, nvdec.shifted(a.seg_read));
    codec.put(out, &n, AV1_SET_SEGMENT_WRITE_BUF_OFFSET, nvdec.shifted(a.seg_write));
    for (a.col_mv, 0..) |m, i| codec.put(out, &n, AV1_SET_COL_MV0_READ_BUF_OFFSET + 4 * @as(u32, @intCast(i)), nvdec.shifted(m));
    codec.put(out, &n, AV1_SET_COL_MVWRITE_BUF_OFFSET, nvdec.shifted(a.col_mv_write));
    codec.put(out, &n, SET_FILTER_BUFFER_OFFSET, nvdec.shifted(a.filter));
    codec.put(out, &n, SET_INTRA_TOP_BUF_OFFSET, nvdec.shifted(a.intra_top));
    codec.put(out, &n, AV1_SET_PROB_TAB_READ_BUF_OFFSET, nvdec.shifted(a.prob_read));
    codec.put(out, &n, AV1_SET_PROB_TAB_WRITE_BUF_OFFSET, nvdec.shifted(a.prob_write));
    if (a.blk) |b| codec.put(out, &n, SET_BLK_BUF_OFFSET, nvdec.shifted(b));
    codec.pictures(out, &n, a.luma, a.chroma);
    codec.execute(out, &n);
    std.debug.assert(n <= PUSH_DWORDS);
    return n;
}

// ── The picture ─────────────────────────────────────────────────────────────

fn find(st: *const State, surface: u32) ?*const Saved {
    if (surface == NONE) return null;
    for (&st.saved) |*s| {
        if (s.surface == surface) return s;
    }
    return null;
}

/// A default table for each quantizer context, written once (the driver
/// zeroed the scratch; the decoder only reads these).
fn writeDefaults(st: *State, scratch: codec.Scratch) void {
    for (0..4) |q| {
        const at = scratch.cpu[st.layout.defaultCdf(@intCast(q))..][0..cdf.TABLE_BYTES];
        @memcpy(at[0 .. cdf.COEF_AT * 2], std.mem.sliceAsBytes(&cdf.PREFIX));
        @memcpy(at[cdf.COEF_AT * 2 ..], std.mem.sliceAsBytes(&cdf.COEF[q]));
    }
    st.defaults_written = true;
}

pub fn end(st: *State, slot: codec.Slot, scratch: codec.Scratch, pic: codec.Picture, lookup: codec.Lookup, out: *codec.End) va.Status {
    if (!st.have_pic) return va.ERROR_INVALID_PARAMETER;
    const p = &st.pic;
    const pf = p.pic_info_fields;
    const tiles = @as(u32, p.tile_cols) * p.tile_rows;
    for (st.tile_seen[0..tiles]) |seen| {
        if (!seen) return va.ERROR_INVALID_PARAMETER;
    }
    const sz = frameSize(p);
    if (sz.upscaled_width > st.width or sz.height > st.height) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    if (sz.upscaled_width > pic.target.width or sz.height > pic.target.height) return va.ERROR_INVALID_SURFACE;
    // (a 10-bit frame into a P010 target, an 8-bit one into NV12)
    const depth: u32 = if (p.bit_depth_idx == 1) 10 else 8;
    if (!pic.target.holds(depth)) return va.ERROR_INVALID_SURFACE;
    const L = st.layout;
    if (scratch.cpu.len < L.bytes) return va.ERROR_ALLOCATION_FAILED;
    var widths: [64]u16 = undefined;
    var heights: [64]u16 = undefined;
    if (!tileSizes(p, sz, &widths, &heights)) return va.ERROR_INVALID_PARAMETER;
    if (st.stream + STREAM_PAD > slot.stream.len) return va.ERROR_NOT_ENOUGH_BUFFER;

    // The references, by what was kept of their surfaces.
    const is_intra = intra(pf.frame_type);
    var f = Frame{
        .p = p,
        .stream_len = @intCast(st.stream),
        .pitch_luma = pic.target.pitch_luma,
        .pitch_chroma = pic.target.pitch_chroma,
        .gob_height = pic.gob_height,
        .sample_bytes = pic.target.sample_bytes,
        .layout = &st.layout,
        .blackwell = st.blackwell,
    };
    var ref_surface = [_]?codec.SurfaceRef{null} ** 7;
    if (!is_intra) {
        for (0..7) |i| {
            const id = p.ref_frame_map[p.ref_frame_idx[i] & 7];
            if (id == pic.target_id) continue;
            const sv = find(st, id) orelse continue;
            const sr = lookup.surface(id) orelse continue;
            if (sv.upscaled_width != sz.upscaled_width or sv.height != sz.height) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            if (sr.sample_bytes != pic.target.sample_bytes) return va.ERROR_INVALID_SURFACE;
            f.refs[i] = .{ .saved = sv.*, .pitch_luma = sr.pitch_luma, .pitch_chroma = sr.pitch_chroma };
            ref_surface[i] = sr;
        }
        if (p.primary_ref_frame < PRIMARY_REF_NONE and pf.error_resilient_mode == 0) {
            if (f.refs[p.primary_ref_frame]) |r| f.prim = r.saved;
        }
    }

    // The picture slots: references by role, the current at CUR_SLOT, the
    // rest the target.
    var luma: [nvdec.SLOTS]u64 = undefined;
    var chroma: [nvdec.SLOTS]u64 = undefined;
    for (0..nvdec.SLOTS) |i| {
        const r: codec.SurfaceRef = if (i < 7) (ref_surface[i] orelse pic.target) else pic.target;
        if (!nvdec.addressable(r.luma) or !nvdec.addressable(r.chroma)) return va.ERROR_INVALID_SURFACE;
        luma[i] = r.luma;
        chroma[i] = r.chroma;
    }

    // Nothing can fail from here on: let go of the frames no reference
    // slot holds, then take a motion/segment buffer and a CDF table.
    if (!st.defaults_written) writeDefaults(st, scratch);
    for (&st.saved) |*s| {
        if (s.surface == NONE) continue;
        if (s.surface == pic.target_id or std.mem.indexOfScalar(u32, &p.ref_frame_map, s.surface) == null) s.* = .{};
    }
    var buf_used = [_]bool{false} ** POOL;
    var cdf_used = [_]bool{false} ** POOL;
    for (st.saved) |s| {
        if (s.surface == NONE) continue;
        buf_used[s.buf] = true;
        if (s.cdf >= 4) cdf_used[s.cdf - 4] = true;
    }
    const buf: u8 = @intCast(std.mem.indexOfScalar(bool, &buf_used, false).?);
    const write: u8 = @intCast(std.mem.indexOfScalar(bool, &cdf_used, false).?);
    const read: u8 = if (f.prim) |pr| pr.cdf else qContext(p.base_qindex);
    const cdf_addr = struct {
        fn of(l: Layout, base: u64, c: u8) u64 {
            return base + if (c < 4) l.defaultCdf(@intCast(c)) else l.poolCdf(c - 4);
        }
    }.of;

    const setup = av1Setup(f);
    const s = &setup.pic;

    // The setup, the tile table, the global motion, the stream's padding.
    @memset(slot.pic[0..MAX_PIC_BYTES], 0);
    @memcpy(slot.pic[0..@sizeOf(Av1Pic)], std.mem.asBytes(s));
    if (st.blackwell) std.mem.writeInt(u32, slot.pic[BLACKWELL_WORD_AT..][0..4], @intCast(blkUnits(sz.upscaled_width)), .little);
    const aux = slot.aux;
    @memset(aux[0..MAX_AUX_BYTES], 0);
    var t: usize = 0;
    for (0..p.tile_rows) |r| {
        for (0..p.tile_cols) |c| {
            const e = aux[TILES_OFF + t * TILE_ENTRY ..][0..TILE_ENTRY];
            e[0] = @intCast(widths[c]);
            e[1] = @intCast(heights[r]);
            std.mem.writeInt(u32, e[2..6], st.tile_start[t], .little);
            std.mem.writeInt(u32, e[6..10], st.tile_end[t], .little);
            t += 1;
        }
    }
    for (p.wm, 0..) |wm, i| {
        const e = aux[GM_OFF + i * GM_ENTRY ..][0..GM_ENTRY];
        for (0..6) |k| std.mem.writeInt(i32, e[4 * k ..][0..4], wm.wmmat[k], .little);
        for (shear(&wm.wmmat), 0..) |v, k| std.mem.writeInt(i16, e[24 + 2 * k ..][0..2], v, .little);
    }
    @memset(slot.stream[st.stream..][0..STREAM_PAD], 0);

    const base = scratch.va;
    var col_mv = [3]u64{ base + L.zero_off, base + L.zero_off, base + L.zero_off };
    for (setup.mf, 0..) |src, k| {
        const i = src orelse continue;
        col_mv[k] = base + L.mv(f.refs[i].?.saved.buf);
    }
    const n = av1Push(slot.push, .{
        .pic_setup = slot.pic_va,
        .bitstream = slot.stream_va,
        .status = slot.status_va,
        .coloc = base + L.mv(buf),
        .tile_info = slot.aux_va + TILES_OFF,
        .global_motion = slot.aux_va + GM_OFF,
        .film_grain = base + L.zero_off,
        .seg_read = if (s.prevsegid_flag != 0) base + L.seg(f.prim.?.buf) else base + L.zero_off,
        .seg_write = base + L.seg(buf),
        .col_mv = col_mv,
        .col_mv_write = base + L.mv(buf),
        .filter = base + L.filter_off,
        .intra_top = base + L.intra_top_off,
        .prob_read = cdf_addr(L, base, read),
        .prob_write = base + L.poolCdf(write),
        .blk = if (st.blackwell) base + L.blk_off else null,
        .luma = luma,
        .chroma = chroma,
    });

    // What later frames need of this one, kept by its surface.
    // (at most eight are kept for ref_frame_map: one of POOL is free)
    var keep: usize = 0;
    while (st.saved[keep].surface != NONE) keep += 1;
    var ref_hints = [_]u8{0} ** 7;
    for (f.refs, 0..) |ref, i| {
        if (ref) |r| ref_hints[i] = r.saved.order_hint;
    }
    const adapted = pf.disable_frame_end_update_cdf == 0;
    st.saved[keep] = .{
        .surface = pic.target_id,
        .buf = buf,
        .cdf = if (adapted) 4 + write else read,
        .frame_type = pf.frame_type,
        .order_hint = p.order_hint,
        .ref_order_hint = ref_hints,
        .upscaled_width = @intCast(sz.upscaled_width),
        .height = @intCast(sz.height),
        .mi_cols = sz.mi_cols,
        .mi_rows = sz.mi_rows,
        .segmap = p.seg_info.segment_info_fields.enabled != 0,
    };
    // (intrabc adapted the MV CDFs: the regular ones go back to the
    // defaults once the decoder is done)
    const fix = is_intra and pf.allow_intrabc != 0 and adapted;
    st.fixup = if (fix) write else null;
    out.* = .{ .dwords = n, .wait = fix };
    return va.SUCCESS;
}

/// The decode `end` asked to wait for is done: an intrabc frame's table
/// gets the default (regular) MV CDFs back.
pub fn after(st: *State, scratch: codec.Scratch) void {
    const k = st.fixup orelse return;
    const at = st.layout.poolCdf(k) + cdf.MV_AT * 2;
    @memcpy(scratch.cpu[at..][0 .. cdf.MV_U16 * 2], std.mem.sliceAsBytes(cdf.PREFIX[cdf.MV_AT..][0..cdf.MV_U16]));
    st.fixup = null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    _ = vaav1;
}

fn wordAt(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

test "av1: nvdec_av1_pic_s's bit fields where gcc puts them" {
    var s = Av1Pic{};
    s.seq.enable_cdef = 1;
    s.seq.bit_depth = 15;
    s.frame.refresh_frame_context = 1;
    s.frame.interp_filter = 7;
    s.tiles.context_update_tile_id = 0xffff;
    s.tools.ref_scaling_enable = 1;
    s.tools.skip_ref1 = 15;
    s.cdef_sec.uv = 0xffff;
    s.segment_quant_sign = 0xff;
    s.mfmv.mf3_type = 7;
    s.surface.gob_height = 7;
    s.errors.coeff_error_detection = 1;
    s.stat.reserved_stat = 0x1ffff;
    const b = std.mem.asBytes(&s);
    // (the masks gcc gave for each field of nvdec_drv.h's struct)
    try testing.expectEqual(@as(u32, 0x0004_0078), wordAt(b, 0x58));
    try testing.expectEqual(@as(u32, 0x0002_7000), wordAt(b, 0x5c));
    try testing.expectEqual(@as(u32, 0xffff_0000), wordAt(b, 0x60));
    try testing.expectEqual(@as(u32, 0x0013_c000), wordAt(b, 0x64));
    try testing.expectEqual(@as(u32, 0xffff_0000), wordAt(b, 0x84));
    try testing.expectEqual(@as(u32, 0xff00_0000), wordAt(b, 0x10c));
    try testing.expectEqual(@as(u32, 0x0000_0e00), wordAt(b, 0x1d8));
    try testing.expectEqual(@as(u32, 0x1c00_0000), wordAt(b, 0x218));
    try testing.expectEqual(@as(u32, 0x0000_0004), wordAt(b, 0x21c));
    try testing.expectEqual(@as(u32, 0xffff_8000), wordAt(b, 0x238));
    var r = RefFrame{};
    r.bits = .{ .sign_bias = 1, .wmtype = 3 };
    r.frame_off = -2;
    try testing.expectEqual(@as(u8, 7), std.mem.asBytes(&r)[16]);
    try testing.expectEqual(@as(u32, 0xfffe), wordAt(std.mem.asBytes(&r), 16) >> 16);
}

fn fnv1a(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

test "av1: the default CDF tables (libaom's values, NVK's layout)" {
    // libaom entropymode.c: default_partition_cdf[0] AOM_CDF4(19132, 25510,
    // 30392); default_kf_y_mode_cdf[0][0] starts 15588; entropymv.c: the
    // joints AOM_CDF4(4096, ...); token_cdfs.h: av1_default_txb_skip_cdfs
    // [q][0][0] AOM_CDF2(31849), (30371), (29614), (26887) and
    // av1_default_coeff_base_multi_cdfs[0][0][0][0] AOM_CDF4(4034, ...).
    try testing.expectEqualSlices(u16, &.{ 32768 - 19132, 32768 - 25510, 32768 - 30392 }, cdf.PREFIX[0..3]);
    try testing.expectEqual(@as(u16, 32768 - 15588), cdf.PREFIX[208]);
    try testing.expectEqual(@as(u16, 32768 - 4096), cdf.PREFIX[cdf.MV_AT]);
    for ([4]u16{ 31849, 30371, 29614, 26887 }, 0..) |v, q| try testing.expectEqual(32768 - v, cdf.COEF[q][0]);
    try testing.expectEqual(@as(u16, 32768 - 4034), cdf.COEF[0][3584 - cdf.COEF_AT]);
    // The four whole tables (FNV-1a of their bytes, from the C dump of
    // NVK's structs; AROS's independent table gives the same).
    var t: [cdf.TABLE_BYTES]u8 = undefined;
    for ([4]u32{ 0x6e606314, 0xf56ff0ad, 0x9a859934, 0x80303e0c }, 0..) |want, q| {
        @memcpy(t[0 .. cdf.COEF_AT * 2], std.mem.sliceAsBytes(&cdf.PREFIX));
        @memcpy(t[cdf.COEF_AT * 2 ..], std.mem.sliceAsBytes(&cdf.COEF[q]));
        try testing.expectEqual(want, fnv1a(&t));
    }
    try testing.expectEqual(@as(u2, 0), qContext(20));
    try testing.expectEqual(@as(u2, 1), qContext(21));
    try testing.expectEqual(@as(u2, 2), qContext(120));
    try testing.expectEqual(@as(u2, 3), qContext(121));
}

test "av1: Div_Lut and the warp's shear (spec 7.11.3.6)" {
    try testing.expectEqual(@as(u16, 16384), DIV_LUT[0]);
    try testing.expectEqual(@as(u16, 16320), DIV_LUT[1]);
    try testing.expectEqual(@as(u16, 15650), DIV_LUT[12]);
    try testing.expectEqual(@as(u16, 10923), DIV_LUT[128]);
    try testing.expectEqual(@as(u16, 8192), DIV_LUT[256]);
    // (an independent C implementation's answers)
    const a = [8]i32{ 1234, -5678, 65536 + 1000, 500, -500, 65536 - 2000, 0, 0 };
    try testing.expectEqual([4]i16{ 1024, 512, -512, -1984 }, shear(&a));
    const b = [8]i32{ 0, 0, 70000, -3000, 2500, 61000, 0, 0 };
    try testing.expectEqual([4]i16{ 4480, -3008, 2368, -4416 }, shear(&b));
    const id = WarpedMotion{};
    try testing.expectEqual([4]i16{ 0, 0, 0, 0 }, shear(&id.wmmat));
    try testing.expectEqual([4]i16{ 0, 0, 0, 0 }, shear(&([_]i32{0} ** 8)));
}

const WarpedMotion = vaav1.WarpedMotion;

test "av1: tile sizes, uniform and explicit" {
    var p = PictureParameterBufferAV1{};
    p.frame_width_minus1 = 1919;
    p.frame_height_minus1 = 1079;
    p.pic_info_fields.uniform_tile_spacing_flag = 1;
    p.tile_cols = 4;
    p.tile_rows = 2;
    var w: [64]u16 = undefined;
    var h: [64]u16 = undefined;
    // 1920 x 1080 in 64x64 superblocks: 30 x 17
    try testing.expect(tileSizes(&p, frameSize(&p), &w, &h));
    try testing.expectEqualSlices(u16, &.{ 8, 8, 8, 6 }, w[0..4]);
    try testing.expectEqualSlices(u16, &.{ 9, 8 }, h[0..2]);
    // 128x128 superblocks: 15 x 9; three columns of 5
    p.seq_info_fields.use_128x128_superblock = 1;
    p.tile_cols = 3;
    try testing.expect(!tileSizes(&p, frameSize(&p), &w, &h)); // (3 is no uniform split of 15)
    p.tile_cols = 4;
    try testing.expect(tileSizes(&p, frameSize(&p), &w, &h));
    try testing.expectEqualSlices(u16, &.{ 4, 4, 4, 3 }, w[0..4]);
    // explicit: the last one is the rest
    p.pic_info_fields.uniform_tile_spacing_flag = 0;
    p.tile_cols = 3;
    p.width_in_sbs_minus_1[0] = 3;
    p.width_in_sbs_minus_1[1] = 6;
    p.tile_rows = 1;
    try testing.expect(tileSizes(&p, frameSize(&p), &w, &h));
    try testing.expectEqualSlices(u16, &.{ 4, 7, 4 }, w[0..3]);
    try testing.expectEqual(@as(u16, 9), h[0]);
    p.width_in_sbs_minus_1[1] = 10;
    try testing.expect(!tileSizes(&p, frameSize(&p), &w, &h));
}

test "av1: superres" {
    var p = PictureParameterBufferAV1{};
    p.frame_width_minus1 = 255;
    p.frame_height_minus1 = 127;
    p.pic_info_fields.use_superres = 1;
    p.superres_scale_denominator = 16;
    const sz = frameSize(&p);
    try testing.expectEqual(@as(u32, 128), sz.width);
    try testing.expectEqual(@as(u32, 32), sz.mi_cols);
    const l = Layout.of(256, 128);
    const s = av1Setup(.{ .p = &p, .stream_len = 0, .pitch_luma = 256, .pitch_chroma = 256, .gob_height = 0, .layout = &l }).pic;
    try testing.expectEqual(@as(u1, 1), s.frame.superres_is_scaled);
    try testing.expectEqual(@as(u3, 7), s.frame.scale_denom_minus9);
    try testing.expectEqual(@as(u16, 256), s.superres_upscaled_width);
    try testing.expectEqual(@as(u16, 128), s.current_frame.width);
    // step (128 << 14) / 256; x0 = (-(128 << 13) + 128) / 256 + 128 - 0
    try testing.expectEqual(@as(u16, 8192), s.superres_luma_step);
    try testing.expectEqual(@as(u16, 8192), s.superres_chroma_step);
    try testing.expectEqual(@as(u16, (16384 - 3967)), s.superres_init_luma_subpel_x);
    try testing.expectEqual(@as(u16, (16384 - 3967)), s.superres_init_chroma_subpel_x);
    // (not scaled: the traced 14s)
    p.pic_info_fields.use_superres = 0;
    p.superres_scale_denominator = 8;
    const t = av1Setup(.{ .p = &p, .stream_len = 0, .pitch_luma = 256, .pitch_chroma = 256, .gob_height = 0, .layout = &l }).pic;
    try testing.expectEqual(@as(u16, 14), t.superres_luma_step);
    try testing.expectEqual(@as(u1, 0), t.frame.superres_is_scaled);
}

test "av1: one frame's pushbuffer, word by word" {
    var a = Addrs{
        .pic_setup = 0x1_0000_0400,
        .bitstream = 0x1_0001_0000,
        .status = 0x1_0000_1400,
        .coloc = 0x2_0000_1000,
        .tile_info = 0x1_0000_2000,
        .global_motion = 0x1_0000_3000,
        .film_grain = 0x2_0000_5000,
        .seg_read = 0x2_0000_6000,
        .seg_write = 0x2_0000_7000,
        .col_mv = .{ 0x2_0000_8000, 0x2_0000_9000, 0x2_0000_a000 },
        .col_mv_write = 0x2_0000_b000,
        .filter = 0x2_0000_c000,
        .intra_top = 0x2_0000_d000,
        .prob_read = 0x2_0000_e000,
        .prob_write = 0x2_0000_f000,
        .luma = undefined,
        .chroma = undefined,
    };
    for (&a.luma, &a.chroma, 0..) |*l, *c, i| {
        l.* = 0x30_0000_0000 + i * 0x40_0000;
        c.* = l.* + 0x20_0000;
    }
    var out: [PUSH_DWORDS]u32 = undefined;
    const n = av1Push(&out, a);
    try testing.expectEqual(@as(usize, 80), n);
    const want = [_]u32{
        0x2001_0000, 0x001f_cfb0, // SET_OBJECT
        0x2001_0080, 0x12, // SET_APPLICATION_ID AVD
        0x2001_0100, 0x0a | (1 << 4) | (1 << 6) | (1 << 13), // SET_CONTROL_PARAMS AV1
        0x2001_0103, 8, // SET_PICTURE_INDEX: the current's slot
        0x2001_0101, 0x100_0004, // SET_DRV_PIC_SETUP_OFFSET
        0x2001_0102, 0x100_0100, // SET_IN_BUF_BASE_OFFSET
        0x2001_0109, 0x100_0014, // SET_NVDEC_STATUS_OFFSET
        0x2001_0105, 0x200_0010, // SET_COLOC_DATA_OFFSET
        0x2001_0133, 0x100_0020, // SET_TILE_SIZE_BUF_OFFSET
        0x2001_0198, 0x100_0030, // AV1_SET_GLOBAL_MODEL_BUF_OFFSET
        0x2001_0199, 0x200_0050, // AV1_SET_FILM_GRAIN_BUF_OFFSET
        0x2001_0192, 0x200_0060, // AV1_SET_SEGMENT_READ_BUF_OFFSET
        0x2001_0193, 0x200_0070, // AV1_SET_SEGMENT_WRITE_BUF_OFFSET
        0x2001_0194, 0x200_0080, // AV1_SET_COL_MV0_READ_BUF_OFFSET
        0x2001_0195, 0x200_0090, // COL_MV1
        0x2001_0196, 0x200_00a0, // COL_MV2
        0x2001_0197, 0x200_00b0, // AV1_SET_COL_MVWRITE_BUF_OFFSET
        0x2001_0134, 0x200_00c0, // SET_FILTER_BUFFER_OFFSET
        0x2001_0132, 0x200_00d0, // SET_INTRA_TOP_BUF_OFFSET
        0x2001_0190, 0x200_00e0, // AV1_SET_PROB_TAB_READ_BUF_OFFSET
        0x2001_0191, 0x200_00f0, // AV1_SET_PROB_TAB_WRITE_BUF_OFFSET
        0x2011_010c, // SET_PICTURE_LUMA_OFFSET0, 17
    };
    try testing.expectEqualSlices(u32, &want, out[0..want.len]);
    try testing.expectEqual(@as(u32, 0x3000_0000), out[43]);
    try testing.expectEqual(@as(u32, 0x3000_0000 + 16 * 0x4000), out[59]);
    try testing.expectEqual(@as(u32, 0x2011_011d), out[60]); // SET_PICTURE_CHROMA_OFFSET0, 17
    try testing.expectEqual(@as(u32, 0x3000_2000), out[61]);
    try testing.expectEqual(@as(u32, 0x2001_00c0), out[78]); // EXECUTE
    try testing.expectEqual(@as(u32, 0), out[79]);
    // Blackwell's buffer after the probability tables
    a.blk = 0x2_0010_0000;
    try testing.expectEqual(@as(usize, 82), av1Push(&out, a));
    try testing.expectEqual(@as(u32, 0x2001_0137), out[42]);
    try testing.expectEqual(@as(u32, 0x200_1000), out[43]);
    try testing.expectEqual(@as(u32, 0x2011_010c), out[44]);
}

// ── Whole pictures through take and end ─────────────────────────────────────

const TW = 256;
const TH = 128;
const SCRATCH_VA: u64 = 0x20_0000_0000;
var test_scratch: [scratchBytes(TW, TH)]u8 align(256) = undefined;
var test_slot: codec.FakeSlot = .{};

fn testScratch() codec.Scratch {
    return .{ .cpu = &test_scratch, .va = SCRATCH_VA };
}

/// The value a single-word method got in the pushbuffer.
fn method(push: []const u32, m: u32) ?u32 {
    var i: usize = 0;
    while (i + 1 < push.len) : (i += 1) {
        if (push[i] == nvdec.header(0, m, 1)) return push[i + 1];
    }
    return null;
}

fn keyFrame() PictureParameterBufferAV1 {
    var p = PictureParameterBufferAV1{};
    p.seq_info_fields = .{ .enable_order_hint = 1, .enable_cdef = 1, .subsampling_x = 1, .subsampling_y = 1, .enable_filter_intra = 1, .enable_intra_edge_filter = 1 };
    p.order_hint_bits_minus_1 = 6;
    p.frame_width_minus1 = TW - 1;
    p.frame_height_minus1 = TH - 1;
    p.pic_info_fields = .{ .frame_type = KEY_FRAME, .show_frame = 1, .error_resilient_mode = 1, .uniform_tile_spacing_flag = 1 };
    p.base_qindex = 100;
    p.cdef_bits = 1;
    p.cdef_damping_minus_3 = 2;
    p.cdef_y_strengths[0] = (5 << 2) | 3;
    p.cdef_y_strengths[1] = (15 << 2) | 1;
    p.cdef_uv_strengths[1] = (2 << 2) | 2;
    p.filter_level = .{ 10, 12 };
    p.filter_level_u = 3;
    p.filter_level_v = 4;
    p.mode_control_fields = .{ .tx_mode = 2 };
    return p;
}

fn interFrame(order: u8, map: [8]u32) PictureParameterBufferAV1 {
    var p = keyFrame();
    p.pic_info_fields = .{ .frame_type = INTER_FRAME, .show_frame = 1, .uniform_tile_spacing_flag = 1 };
    p.order_hint = order;
    p.ref_frame_map = map;
    p.ref_frame_idx = .{ 0, 1, 2, 3, 4, 5, 6 };
    p.primary_ref_frame = 0;
    return p;
}

const Decoded = struct {
    status: va.Status,
    end: codec.End = .{ .dwords = 0 },
    slot: codec.Slot = undefined,
};

/// One frame of `tiles` tiles (one tile group of fake tile data) into
/// surface `target`.
/// The fake surfaces' bytes a sample (2: P010, a 10-bit test's).
var test_sample_bytes: u8 = 1;

fn decode(st: *State, p: PictureParameterBufferAV1, target: u32) Decoded {
    var surfaces = codec.FakeSurfaces{ .w = TW, .h = TH, .n = 8, .sample_bytes = test_sample_bytes };
    const slot = test_slot.slot();
    begin(st);
    var pp = p;
    var r = take(st, .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(PictureParameterBufferAV1), .count = 1, .data = std.mem.asBytes(&pp) }, slot);
    if (r != va.SUCCESS) return .{ .status = r };
    const tiles = @as(usize, p.tile_cols) * p.tile_rows;
    var params: [MAX_TILES]SliceParameterBufferAV1 = undefined;
    var data: [MAX_TILES * 8]u8 = undefined;
    for (0..tiles) |i| {
        params[i] = .{ .slice_data_size = 6, .slice_data_offset = @intCast(8 * i + 2), .tile_row = @intCast(i / p.tile_cols), .tile_column = @intCast(i % p.tile_cols) };
        for (0..8) |k| data[8 * i + k] = @intCast((i * 16 + k) & 0xff);
    }
    r = take(st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(SliceParameterBufferAV1), .count = @intCast(tiles), .data = std.mem.sliceAsBytes(params[0..tiles]) }, slot);
    if (r != va.SUCCESS) return .{ .status = r };
    r = take(st, .{ .kind = va.SLICE_DATA_BUFFER, .size = @intCast(tiles * 8), .count = 1, .data = data[0 .. tiles * 8] }, slot);
    if (r != va.SUCCESS) return .{ .status = r };
    const look = surfaces.lookup();
    var d = Decoded{ .status = undefined, .slot = slot };
    d.status = end(st, slot, testScratch(), .{ .target_id = target, .target = look.surface(target).?, .gob_height = 2, .picture_index = 5 }, look, &d.end);
    return d;
}

fn surfaceLuma(id: u32) u64 {
    return 0x40_0000_0000 + @as(u64, id) * 0x100_0000;
}

test "av1: a key frame of four tiles in two tile groups" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    var surfaces = codec.FakeSurfaces{ .w = TW, .h = TH, .n = 8 };
    const look = surfaces.lookup();
    const slot = test_slot.slot();
    var p = keyFrame();
    p.tile_cols = 2;
    p.tile_rows = 2;
    p.context_update_tile_id = 3;
    p.current_frame = 3;
    // tile groups: tiles 0..1, then 2..3, each its own data buffer
    begin(&st);
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(PictureParameterBufferAV1), .count = 1, .data = std.mem.asBytes(&p) }, slot));
    const g1 = [_]SliceParameterBufferAV1{
        .{ .slice_data_size = 5, .slice_data_offset = 0, .tile_row = 0, .tile_column = 0 },
        .{ .slice_data_size = 3, .slice_data_offset = 9, .tile_row = 0, .tile_column = 1 },
    };
    const d1 = [_]u8{ 1, 2, 3, 4, 5, 0, 0, 2, 0, 6, 7, 8 };
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(SliceParameterBufferAV1), .count = 2, .data = std.mem.sliceAsBytes(&g1) }, slot));
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = d1.len, .count = 1, .data = &d1 }, slot));
    const g2 = [_]SliceParameterBufferAV1{
        .{ .slice_data_size = 2, .slice_data_offset = 1, .tile_row = 1, .tile_column = 0 },
        .{ .slice_data_size = 4, .slice_data_offset = 4, .tile_row = 1, .tile_column = 1 },
    };
    const d2 = [_]u8{ 9, 10, 11, 0, 12, 13, 14, 15 };
    // (the data before its parameters: refused)
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = d2.len, .count = 1, .data = &d2 }, slot));
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(SliceParameterBufferAV1), .count = 2, .data = std.mem.sliceAsBytes(&g2) }, slot));
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = d2.len, .count = 1, .data = &d2 }, slot));
    var e: codec.End = undefined;
    try testing.expectEqual(va.SUCCESS, end(&st, slot, testScratch(), .{ .target_id = 3, .target = look.surface(3).?, .gob_height = 2, .picture_index = 5 }, look, &e));
    try testing.expectEqual(@as(usize, 80), e.dwords);
    try testing.expect(!e.wait);

    // the bitstream: both groups' bytes, then zeros
    try testing.expectEqualSlices(u8, &d1, slot.stream[0..12]);
    try testing.expectEqualSlices(u8, &d2, slot.stream[12..20]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** STREAM_PAD), slot.stream[20..][0..STREAM_PAD]);
    // the tile table: 256 x 128 in 64x64 superblocks is 4 x 2: tiles 2 x 1
    const want_tiles = [4][4]u32{
        .{ 2, 1, 0, 5 },
        .{ 2, 1, 9, 12 },
        .{ 2, 1, 13, 15 },
        .{ 2, 1, 16, 20 },
    };
    for (want_tiles, 0..) |w, i| {
        const t = slot.aux[TILES_OFF + i * TILE_ENTRY ..][0..TILE_ENTRY];
        try testing.expectEqual(@as(u8, @intCast(w[0])), t[0]);
        try testing.expectEqual(@as(u8, @intCast(w[1])), t[1]);
        try testing.expectEqual(w[2], std.mem.readInt(u32, t[2..6], .little));
        try testing.expectEqual(w[3], std.mem.readInt(u32, t[6..10], .little));
        try testing.expectEqualSlices(u8, &([_]u8{0} ** 6), t[10..16]);
    }
    // global motion: identity for each reference
    for (0..7) |i| {
        const g = slot.aux[GM_OFF + i * GM_ENTRY ..][0..GM_ENTRY];
        try testing.expectEqual(@as(u32, 1 << 16), wordAt(g, 8));
        try testing.expectEqual(@as(u32, 1 << 16), wordAt(g, 20));
        try testing.expectEqual(@as(u32, 0), wordAt(g, 24) | wordAt(g, 28));
    }

    // the setup, as the decoder reads it
    const s = slot.pic;
    try testing.expectEqual(nvdec.GPTIMER_TIMEOUT, wordAt(s, 0x4c));
    try testing.expectEqual(@as(u32, 20), wordAt(s, 0x50));
    // 4:2:0, 8-bit, filter intra, intra edge, CDEF
    try testing.expectEqual(@as(u32, 2 | (8 << 3) | (1 << 7) | (1 << 8) | (1 << 18)), wordAt(s, 0x58));
    // key, shown, refresh_frame_context, tile_enabled
    try testing.expectEqual(@as(u32, 0 | (1 << 2) | (1 << 17) | (1 << 27)), wordAt(s, 0x5c));
    try testing.expectEqual(@as(u32, 2 | (2 << 8) | (3 << 16)), wordAt(s, 0x60));
    // damping 2, cdef_bits 1, TX_MODE_SELECT (4)
    try testing.expectEqual(@as(u32, 2 | (1 << 2) | (4 << 4)), wordAt(s, 0x64));
    try testing.expectEqual(@as(u16, TW), std.mem.readInt(u16, s[0x68..0x6a], .little));
    try testing.expectEqual(@as(u8, 100), s[0x72]);
    try testing.expectEqualSlices(u8, &.{ 15, 15, 15 }, s[0x78..0x7b]);
    try testing.expectEqual(@as(u32, 5 | (15 << 4)), wordAt(s, 0x7c));
    try testing.expectEqual(@as(u32, 2 << 4), wordAt(s, 0x80));
    try testing.expectEqual(@as(u32, (3 | (1 << 2)) | ((2 << 2) << 16)), wordAt(s, 0x84));
    try testing.expectEqualSlices(u8, &.{ 10, 12, 3, 4 }, s[0x110..0x114]);
    try testing.expectEqual(@as(u8, 0x3f), s[0x120]);
    // current_frame: 256 x 128, pitches / 16, slot 8
    try testing.expectEqual(@as(u32, TW | (TH << 16)), wordAt(s, 0x124));
    try testing.expectEqual(@as(u32, 16 | (16 << 16)), wordAt(s, 0x128));
    try testing.expectEqual(@as(u32, 8), wordAt(s, 0x12c));
    // no references in a key frame
    try testing.expectEqualSlices(u8, &([_]u8{0} ** (7 * 24)), s[0x130..0x1d8]);
    // block linear, GOB height 2
    try testing.expectEqual(@as(u8, 1 | (2 << 2)), s[0x21b]);
    const L = st.layout;
    for (L.flt, 0..) |o, i| {
        const at: usize = switch (i) {
            0 => 0x220,
            1 => 0x224,
            2 => 0x228,
            3 => 0x230, // the upscaler's (Hus) part is fourth in the buffer
            4 => 0x22c,
            else => 0x234,
        };
        try testing.expectEqual(o, wordAt(s, at));
    }
    try testing.expectEqual(@as(u32, 0), L.flt[0]);
    // (256 wide: 6 superblock columns of 1920 for the deblocking top)
    try testing.expectEqual(@as(u32, 6 * 1920 / 256), L.flt[1]);

    // the pushbuffer: the setup, the defaults for q context 2, the pool's
    // first table, the first motion/segment buffers, the slots
    const push = slot.push[0..e.dwords];
    const sv = SCRATCH_VA;
    try testing.expectEqual(nvdec.shifted(slot.pic_va), method(push, nvdec.SET_DRV_PIC_SETUP_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(slot.stream_va), method(push, nvdec.SET_IN_BUF_BASE_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(slot.aux_va + TILES_OFF), method(push, SET_TILE_SIZE_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(slot.aux_va + GM_OFF), method(push, AV1_SET_GLOBAL_MODEL_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.defaultCdf(2)), method(push, AV1_SET_PROB_TAB_READ_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(0)), method(push, AV1_SET_PROB_TAB_WRITE_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.zero_off), method(push, AV1_SET_SEGMENT_READ_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.seg(0)), method(push, AV1_SET_SEGMENT_WRITE_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.zero_off), method(push, AV1_SET_COL_MV0_READ_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.mv(0)), method(push, AV1_SET_COL_MVWRITE_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.filter_off), method(push, SET_FILTER_BUFFER_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(sv + L.intra_top_off), method(push, SET_INTRA_TOP_BUF_OFFSET).?);
    try testing.expect(method(push, SET_BLK_BUF_OFFSET) == null);
    for (0..nvdec.SLOTS) |i| try testing.expectEqual(nvdec.shifted(surfaceLuma(3)), push[43 + i]);
    // the default tables written into the scratch
    for ([4]u32{ 0x6e606314, 0xf56ff0ad, 0x9a859934, 0x80303e0c }, 0..) |want, q| {
        try testing.expectEqual(want, fnv1a(test_scratch[L.defaultCdf(@intCast(q))..][0..cdf.TABLE_BYTES]));
    }
    // what is kept of it
    const k = find(&st, 3).?;
    try testing.expectEqual(@as(u8, 4), k.cdf);
    try testing.expectEqual(@as(u8, 0), k.buf);
    try testing.expectEqual(@as(u32, 64), k.mi_cols);
}

test "av1: the CDF tables and buffers across a sequence" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    const L = st.layout;
    const sv = SCRATCH_VA;
    const prob = struct {
        fn read(d: Decoded) u32 {
            return method(d.slot.push[0..d.end.dwords], AV1_SET_PROB_TAB_READ_BUF_OFFSET).?;
        }
        fn write(d: Decoded) u32 {
            return method(d.slot.push[0..d.end.dwords], AV1_SET_PROB_TAB_WRITE_BUF_OFFSET).?;
        }
        fn mvw(d: Decoded) u32 {
            return method(d.slot.push[0..d.end.dwords], AV1_SET_COL_MVWRITE_BUF_OFFSET).?;
        }
    };
    // VA-API gives no refresh_frame_flags: the test keeps the reference
    // slots as the spec's reference update would, and hands them over as
    // ref_frame_map.
    var map = [_]u32{NONE} ** 8;
    const refresh = struct {
        fn f(m: *[8]u32, flags: u8, surface: u32) void {
            for (0..8) |i| {
                if (flags & (@as(u8, 1) << @intCast(i)) != 0) m[i] = surface;
            }
        }
    }.f;

    // 1: a key frame (q context 2), refresh_frame_flags 0xff
    var d = decode(&st, keyFrame(), 1);
    try testing.expectEqual(va.SUCCESS, d.status);
    try testing.expectEqual(nvdec.shifted(sv + L.defaultCdf(2)), prob.read(d));
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(0)), prob.write(d));
    try testing.expectEqual(nvdec.shifted(sv + L.mv(0)), prob.mvw(d));
    refresh(&map, 0xff, 1);

    // 2: inter, primary LAST (surface 1: pool 0), refresh 0x01
    d = decode(&st, interFrame(1, map), 2);
    try testing.expectEqual(va.SUCCESS, d.status);
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(0)), prob.read(d));
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(1)), prob.write(d));
    try testing.expectEqual(nvdec.shifted(sv + L.mv(1)), prob.mvw(d));
    refresh(&map, 0x01, 2);

    // 3: inter, primary LAST (surface 2: pool 1), no frame-end update: it
    // keeps pool 1 (the decoder's write goes to a table nobody keeps)
    var p = interFrame(2, map);
    p.pic_info_fields.disable_frame_end_update_cdf = 1;
    d = decode(&st, p, 3);
    try testing.expectEqual(va.SUCCESS, d.status);
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(1)), prob.read(d));
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(2)), prob.write(d));
    try testing.expectEqual(@as(u8, 4 + 1), find(&st, 3).?.cdf);
    refresh(&map, 0x02, 3);

    // 4: primary_ref_frame 1 (LAST2 = slot 1 =
    // surface 3, pool 1); pool 2 is free again; refresh nothing
    p = interFrame(3, map);
    p.primary_ref_frame = 1;
    d = decode(&st, p, 4);
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(1)), prob.read(d));
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(2)), prob.write(d));
    // (surfaces 1, 2, 3 hold motion buffers 0, 1, 2: 4 takes 3)
    try testing.expectEqual(nvdec.shifted(sv + L.mv(3)), prob.mvw(d));

    // 5: a key frame (q context 0), refresh 0xff; 4 was in no slot, its
    // table and buffer are free again
    p = keyFrame();
    p.base_qindex = 7;
    p.ref_frame_map = map;
    d = decode(&st, p, 5);
    try testing.expectEqual(nvdec.shifted(sv + L.defaultCdf(0)), prob.read(d));
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(2)), prob.write(d));
    try testing.expectEqual(nvdec.shifted(sv + L.mv(3)), prob.mvw(d));
    try testing.expect(find(&st, 4) == null);
    refresh(&map, 0xff, 5);

    // 6: everything before 5 is gone: pools 0 and 1 free again
    d = decode(&st, interFrame(1, map), 6);
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(2)), prob.read(d));
    try testing.expectEqual(nvdec.shifted(sv + L.poolCdf(0)), prob.write(d));
    try testing.expectEqual(nvdec.shifted(sv + L.mv(0)), prob.mvw(d));
    try testing.expect(find(&st, 1) == null and find(&st, 2) == null and find(&st, 3) == null);

    // 7: error-resilient frame with a primary named: still the defaults
    p = interFrame(2, map);
    p.pic_info_fields.error_resilient_mode = 1;
    p.base_qindex = 200;
    d = decode(&st, p, 7);
    try testing.expectEqual(nvdec.shifted(sv + L.defaultCdf(3)), prob.read(d));
}

test "av1: an intrabc key frame's MV CDFs go back to the defaults" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    var p = keyFrame();
    p.pic_info_fields.allow_screen_content_tools = 1;
    p.pic_info_fields.allow_intrabc = 1;
    const d = decode(&st, p, 2);
    try testing.expectEqual(va.SUCCESS, d.status);
    try testing.expect(d.end.wait);
    try testing.expectEqual(@as(u32, 1 << 10), wordAt(d.slot.pic, 0x5c) & (1 << 10));
    // the decoder wrote an adapted table into pool 0
    const at = st.layout.poolCdf(0);
    @memset(test_scratch[at..][0..cdf.TABLE_BYTES], 0x55);
    after(&st, testScratch());
    const mv = test_scratch[at + cdf.MV_AT * 2 ..][0 .. cdf.MV_U16 * 2];
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(cdf.PREFIX[cdf.MV_AT..][0..cdf.MV_U16]), mv);
    try testing.expectEqual(@as(u8, 0x55), test_scratch[at + cdf.MV_AT * 2 - 1]);
    try testing.expectEqual(@as(u8, 0x55), test_scratch[at + (cdf.MV_AT + cdf.MV_U16) * 2]);
    try testing.expect(st.fixup == null);
    // (without the frame-end update nothing is written: no wait)
    p.pic_info_fields.disable_frame_end_update_cdf = 1;
    try testing.expect(!decode(&st, p, 3).end.wait);
}

test "av1: references, skip mode and the motion field" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    // 1: key frame, order 0
    try testing.expectEqual(va.SUCCESS, decode(&st, keyFrame(), 1).status);
    var map = [_]u32{1} ** 8;
    // 2: inter, order 4, all references the key frame (intra: no motion
    // field source)
    var p = interFrame(4, map);
    p.pic_info_fields.use_ref_frame_mvs = 1;
    var d = decode(&st, p, 2);
    try testing.expectEqual(va.SUCCESS, d.status);
    try testing.expectEqual(@as(u32, 0), wordAt(d.slot.pic, 0x1d8));
    // 3: inter, order 2: LAST .. GOLDEN the key frame (0), BWDREF ..
    // ALTREF frame 2 (4)
    map = .{ 1, 1, 1, 1, 2, 2, 2, 1 };
    p = interFrame(2, map);
    p.pic_info_fields.use_ref_frame_mvs = 1;
    p.mode_control_fields.skip_mode_present = 1;
    p.mode_control_fields.reference_select = 1;
    p.wm[4] = .{ .wmtype = vaav1.WM_ROTZOOM, .wmmat = .{ 1234, -5678, 65536 + 1000, 500, -500, 65536 - 2000, 0, 0 } };
    d = decode(&st, p, 3);
    try testing.expectEqual(va.SUCCESS, d.status);
    const s = std.mem.bytesToValue(Av1Pic, d.slot.pic[0..@sizeOf(Av1Pic)]);
    // skip mode: LAST forward (0 < 2), BWDREF backward (4 > 2)
    try testing.expectEqual(@as(u1, 1), s.tools.skip_mode_flag);
    try testing.expectEqual(@as(u4, 1), s.tools.skip_ref0);
    try testing.expectEqual(@as(u4, 5), s.tools.skip_ref1);
    try testing.expectEqual(@as(u2, 2), s.tools.frame_reference_mode);
    // references: their slots, sizes, scale (1 << 14), sign bias, offsets
    for (0..7) |i| {
        const r = s.ref_frame[i];
        try testing.expectEqual(@as(u32, @intCast(i)), r.info.frame_buffer_idx);
        try testing.expectEqual(@as(u16, TW), r.info.width);
        try testing.expectEqual(@as(u16, 16), r.info.stride[0]);
        try testing.expectEqual(@as(i16, 1 << 14), r.x_scale_fp);
        const back = i >= 4;
        try testing.expectEqual(@as(u1, @intFromBool(back)), r.bits.sign_bias);
        try testing.expectEqual(@as(i16, if (back) -2 else 2), r.frame_off);
        try testing.expectEqual(@as(i16, if (back) 2 else -2), r.roffset);
    }
    try testing.expectEqual(@as(u2, 2), s.ref_frame[4].bits.wmtype);
    try testing.expectEqual(@as(u1, 0), s.tools.ref_scaling_enable);
    // motion field: LAST is intra (skipped, a stamp spent), BWDREF and
    // ALTREF2 project; ALTREF has no stamp left
    try testing.expectEqual(@as(u1, 1), s.mfmv.use_temporal0_mvs);
    try testing.expectEqual(@as(u1, 1), s.mfmv.use_temporal1_mvs);
    try testing.expectEqual(@as(u1, 0), s.mfmv.use_temporal2_mvs);
    try testing.expectEqual(@as(u3, 5), s.mfmv.mf1_type);
    try testing.expectEqual(@as(u3, 6), s.mfmv.mf2_type);
    // frame 2's references were all order 0: offset 4 from it
    try testing.expectEqual([7]i16{ 4, 4, 4, 4, 4, 4, 4 }, s.mfmv_offset[0]);
    try testing.expectEqual([7]i8{ 0, 0, 0, 0, 0, 0, 0 }, s.mfmv_side[0]);
    // the slots: references by role, the rest and the current the target
    const push = d.slot.push[0..d.end.dwords];
    for (0..nvdec.SLOTS) |i| {
        const want: u32 = if (i < 4) 1 else if (i < 7) 2 else 3;
        try testing.expectEqual(nvdec.shifted(surfaceLuma(want)), push[43 + i]);
    }
    const L = st.layout;
    // frame 2 kept motion buffer 1: both sources read it
    try testing.expectEqual(nvdec.shifted(SCRATCH_VA + L.mv(1)), method(push, AV1_SET_COL_MV0_READ_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(SCRATCH_VA + L.mv(1)), method(push, AV1_SET_COL_MV0_READ_BUF_OFFSET + 4).?);
    try testing.expectEqual(nvdec.shifted(SCRATCH_VA + L.zero_off), method(push, AV1_SET_COL_MV0_READ_BUF_OFFSET + 8).?);
    // global motion: BWDREF's matrix and shear
    const g = d.slot.aux[GM_OFF + 4 * GM_ENTRY ..][0..GM_ENTRY];
    try testing.expectEqual(@as(u32, 1234), wordAt(g, 0));
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -500))), wordAt(g, 16));
    try testing.expectEqual(@as(i16, 1024), std.mem.readInt(i16, g[24..26], .little));
    try testing.expectEqual(@as(i16, -1984), std.mem.readInt(i16, g[30..32], .little));
}

test "av1: segmentation, the previous map and coded lossless" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    var p = keyFrame();
    p.seg_info.segment_info_fields = .{ .enabled = 1, .update_map = 1 };
    p.seg_info.feature_mask[2] = 1; // ALT_Q
    p.seg_info.feature_data[2][0] = -20;
    p.seg_info.feature_mask[5] = 1 << 5; // REF_FRAME
    p.seg_info.feature_data[5][5] = 1;
    p.seg_info.feature_data[6][0] = 99; // (not enabled: not sent)
    var d = decode(&st, p, 1);
    try testing.expectEqual(va.SUCCESS, d.status);
    var s = std.mem.bytesToValue(Av1Pic, d.slot.pic[0..@sizeOf(Av1Pic)]);
    try testing.expectEqual(@as(u8, 1), s.segment_enabled);
    try testing.expectEqual(@as(u8, 5), s.last_active_segid);
    try testing.expectEqual(@as(u8, 1), s.segid_preskip);
    try testing.expectEqual(@as(u8, 1 << 2), s.segment_quant_sign);
    try testing.expectEqual(@as(i16, -20), s.segment_feature_data[2][0]);
    try testing.expectEqual(@as(i16, 0), s.segment_feature_data[6][0]);
    try testing.expectEqual(@as(u8, 0), s.prevsegid_flag);
    // the next frame reads frame 1's map (same size, segmentation on)
    p = interFrame(1, [_]u32{1} ** 8);
    p.seg_info.segment_info_fields = .{ .enabled = 1 };
    d = decode(&st, p, 2);
    s = std.mem.bytesToValue(Av1Pic, d.slot.pic[0..@sizeOf(Av1Pic)]);
    try testing.expectEqual(@as(u8, 1), s.prevsegid_flag);
    const push = d.slot.push[0..d.end.dwords];
    try testing.expectEqual(nvdec.shifted(SCRATCH_VA + st.layout.seg(0)), method(push, AV1_SET_SEGMENT_READ_BUF_OFFSET).?);
    try testing.expectEqual(nvdec.shifted(SCRATCH_VA + st.layout.seg(1)), method(push, AV1_SET_SEGMENT_WRITE_BUF_OFFSET).?);
    // coded lossless: q 0 everywhere
    p = keyFrame();
    p.base_qindex = 0;
    try testing.expectEqual(@as(u32, 1 << 26), wordAt(decode(&st, p, 3).slot.pic, 0x5c) & (1 << 26));
    p.seg_info.segment_info_fields = .{ .enabled = 1 };
    p.seg_info.feature_mask[1] = 1;
    p.seg_info.feature_data[1][0] = 3;
    try testing.expectEqual(@as(u32, 0), wordAt(decode(&st, p, 3).slot.pic, 0x5c) & (1 << 26));
}

test "av1: a 10-bit key frame into a P010 surface: bit depth 10, strides in 16-sample units of 2-byte samples; an 8-bit frame not into P010" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    test_sample_bytes = 2;
    defer test_sample_bytes = 1;
    var p = keyFrame();
    p.bit_depth_idx = 1;
    const d = decode(&st, p, 1);
    try testing.expectEqual(va.SUCCESS, d.status);
    const s = std.mem.bytesToValue(Av1Pic, d.slot.pic[0..@sizeOf(Av1Pic)]);
    try testing.expectEqual(@as(u4, 10), s.seq.bit_depth);
    // (a 256-sample row: 512 bytes, 16 units of 32 bytes)
    try testing.expectEqual([2]u16{ 16, 16 }, s.current_frame.stride);
    // an 8-bit frame into a P010 surface: refused
    try testing.expectEqual(va.ERROR_INVALID_SURFACE, decode(&st, keyFrame(), 2).status);
}

test "av1: what is refused" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    var p = keyFrame();
    p.profile = 1;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_PROFILE, decode(&st, p, 1).status);
    p = keyFrame();
    p.bit_depth_idx = 2; // (12-bit: Professional)
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, decode(&st, p, 1).status);
    // (10-bit into an NV12 surface)
    p = keyFrame();
    p.bit_depth_idx = 1;
    try testing.expectEqual(va.ERROR_INVALID_SURFACE, decode(&st, p, 1).status);
    p = keyFrame();
    p.seq_info_fields.mono_chrome = 1;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, decode(&st, p, 1).status);
    p = keyFrame();
    p.pic_info_fields.large_scale_tile = 1;
    try testing.expectEqual(va.ERROR_UNIMPLEMENTED, decode(&st, p, 1).status);
    p = keyFrame();
    p.frame_width_minus1 = TW;
    try testing.expectEqual(va.ERROR_RESOLUTION_NOT_SUPPORTED, decode(&st, p, 1).status);
    // a reference of another size
    try testing.expectEqual(va.SUCCESS, decode(&st, keyFrame(), 1).status);
    p = interFrame(1, [_]u32{1} ** 8);
    p.frame_width_minus1 = TW / 2 - 1;
    try testing.expectEqual(va.ERROR_RESOLUTION_NOT_SUPPORTED, decode(&st, p, 2).status);
    // (a refused frame changed nothing: frame 1 is still kept)
    try testing.expect(find(&st, 1) != null);
    // a missing tile
    var slot = test_slot.slot();
    begin(&st);
    p = keyFrame();
    p.tile_cols = 2;
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(PictureParameterBufferAV1), .count = 1, .data = std.mem.asBytes(&p) }, slot));
    const one = [_]SliceParameterBufferAV1{.{ .slice_data_size = 1 }};
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(SliceParameterBufferAV1), .count = 1, .data = std.mem.sliceAsBytes(&one) }, slot));
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = 1, .count = 1, .data = &[_]u8{7} }, slot));
    var surfaces = codec.FakeSurfaces{ .w = TW, .h = TH, .n = 8 };
    const look = surfaces.lookup();
    var e: codec.End = undefined;
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, end(&st, slot, testScratch(), .{ .target_id = 4, .target = look.surface(4).?, .gob_height = 0, .picture_index = 0 }, look, &e));
    _ = &slot;
}

test "av1: Blackwell's traced extras when asked for" {
    @memset(&test_scratch, 0);
    var st = State.init(TW, TH);
    st.blackwell = true;
    const d = decode(&st, keyFrame(), 1);
    try testing.expectEqual(va.SUCCESS, d.status);
    try testing.expectEqual(@as(u32, 0xffff), wordAt(d.slot.pic, 0x54));
    try testing.expectEqual(@as(u32, 9 << 15), wordAt(d.slot.pic, 0x238));
    try testing.expectEqual(@as(u32, 3), wordAt(d.slot.pic, BLACKWELL_WORD_AT));
    try testing.expectEqual(@as(usize, 82), d.end.dwords);
    try testing.expectEqual(nvdec.shifted(SCRATCH_VA + st.layout.blk_off), method(d.slot.push[0..d.end.dwords], SET_BLK_BUF_OFFSET).?);
}

test "av1: the scratch sizes (nvdec_drv.h's formulas)" {
    const l = Layout.of(1920, 1080);
    try testing.expectEqual(@as(usize, 139264), l.mv_bytes); // align(1920*1152/4096*256, 4096)
    try testing.expectEqual(@as(usize, 69632), l.seg_bytes);
    // deblocking top 32 * 1920, then 19 rows of 1536, 1792, 2 * 12544, 1920, 384
    try testing.expectEqual([6]u32{ 0, 240, 354, 487, 2349, 2492 }, l.flt);
    try testing.expectEqual(@as(usize, 3_152_128), scratchBytes(1920, 1080));
    try testing.expectEqual(@as(usize, 9_560_320), scratchBytes(3840, 2160));
    try testing.expect(l.zero_off % 256 == 0 and l.filter_off % 256 == 0 and l.blk_off % 256 == 0);
}
