//! @zpm/va hevc — HEVC Main (8-bit 4:2:0) on the RTX's video decoder: the
//! picture setup it reads (nvdec_hevc_pic_s), its scaling lists and tile
//! sizes, its buffers and one frame's pushbuffer, behind codec.sig.
//!
//! Sources: the struct and the methods are NVIDIA's public Ada headers
//! (open-gpu-doc nvdec_drv.h, clc9b0.h; MIT). Blackwell's are assumed the
//! same — THE RISK, as for H.264 (nvdec.sig): a longer or reordered
//! nvdec_hevc_pic_s on GB206 garbles every field after the change, and the
//! decoder's status says so (GALAXY_VA_DEBUG). The method order and the
//! intra-top buffer follow Mesa NVK's H.265 work (Collabora, MIT, branch
//! nvk-vulkan-video-h265). The buffer sizes, the scaling-list and tile-size
//! layouts, the slot and reference-list rules and what sw_hdr_skip_length
//! counts are facts learnt from averne's Tegra NVDEC decoder for FFmpeg,
//! which decodes HEVC on that hardware; none of its code is used.
//!
//! What VA-API does not say and is worked out here:
//! - sw_hdr_skip_length: the slice header's bits from after slice_type to
//!   the end of the long-term reference set (the decoder skips them; the
//!   driver has decoded them). The first slice's header is parsed for it
//!   (`skipBits`), emulation-prevention bytes removed as the decoder does.
//! - The initial reference lists (initreflistidxl0/l1): StCurrBefore by
//!   descending order count, StCurrAfter by ascending, LtCurr in the slice
//!   header's order where its order count bits match, repeated to 16
//!   entries (the decoder applies the slice's list modification itself).
//!
//! Main10: a 10-bit stream decodes into a P010 surface (output mode 1,
//! the frame strides in 2-byte samples, init_qp with QpBdOffsetY).
//!
//! Blackwell (codec.sig's `Blackwell`): GB206's decoder faulted at address
//! 0 on the first HEVC picture with Ada's method set (pc-1111c). NVIDIA's
//! driver, as AROS nvgfx traced it on the CFB0 class, binds one more buffer
//! (0x4dc, `Layout.blk_off`) and writes reserved6 (a surface code), reserved7
//! (a depth and chroma code), a count at 0x11c and 0xffff at 0x120, past
//! Ada's struct; `State.blackwell` says which (full by default). Its
//! v3.HevcSliceEdgeOffset (the SAO-above part's, in NVIDIA's layout) and
//! co-located-MV concealment are set too, and the bitstream is padded with
//! 256 zero bytes, as NVIDIA's driver does.
//!
//! Left for later: 12-bit, 4:4:4, the above-row filter
//! offsets' real use (set apart here, see `Layout`).

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const codec = @import("codec.sig");

pub const PROFILE = va.PROFILE_HEVC_MAIN;

pub const APPLICATION_ID_HEVC: u32 = 7;
pub const CODEC_TYPE_HEVC: u32 = 7;

// ── Methods (clc9b0.h) ──────────────────────────────────────────────────────

pub const SET_INTRA_TOP_BUF_OFFSET: u32 = 0x4c8;
pub const HEVC_SET_SCALING_LIST_OFFSET: u32 = 0x580;
pub const HEVC_SET_TILE_SIZES_OFFSET: u32 = 0x584;
pub const HEVC_SET_FILTER_BUFFER_OFFSET: u32 = 0x588;

// ── The structs (nvdec_drv.h) ───────────────────────────────────────────────

/// nvdec_hevc_main10_444_ext_s with nvdec_hevc_pic_v1_s's word: Main's
/// fields stay 0; the above-row filter offsets are set (see Layout).
pub const V1 = extern struct {
    sps_444_ext: u32 = 0,
    pps_444_ext: u32 = 0,
    cb_qp_adjustment: [6]i8 = [_]i8{0} ** 6,
    cr_qp_adjustment: [6]i8 = [_]i8{0} ** 6,
    /// filter (above) offset from the filter buffer, 256-byte units
    HevcFltAboveOffset: u32 = 0,
    HevcSaoAboveOffset: u32 = 0,
    /// sw_skip_start_length:14, external_ref_mem_dis:1,
    /// error_recovery_start_pos:2, error_external_mv_en:1
    misc: u32 = 0,
};

/// nvdec_hevc_pic_s.
pub const HevcPic = extern struct {
    /// encryption keys and IV (off)
    keys: [12]u32 = [_]u32{0} ** 12,
    stream_len: u32 = 0,
    enable_encryption: u32 = 0,
    /// key_increment, encryption_mode, key_slot_index, ssm, histogram,
    /// substreams: all off
    crypt: u32 = 0,
    gptimer_timeout_value: u32 = 0,
    surface: packed struct(u8) {
        /// 0 TBL, 1 KBL (block linear), 2 Tile16x16
        tileformat: u2 = 0,
        gob_height: u3 = 0,
        reserved: u3 = 0,
    } = .{},
    /// the stream has start codes
    sw_start_code_e: u8 = 0,
    /// 0 Rec.709 8-bit
    disp_output_mode: u8 = 0,
    reserved1: u8 = 0,
    framestride: [2]u32 = .{ 0, 0 },
    /// one picture's co-located motion, 256-byte units
    colMvBuffersize: u32 = 0,
    /// from the filter buffer, 256-byte units
    HevcSaoBufferOffset: u32 = 0,
    HevcBsdCtrlOffset: u32 = 0,
    pic_width_in_luma_samples: u16 = 0,
    pic_height_in_luma_samples: u16 = 0,
    sps0: packed struct(u32) {
        chroma_format_idc: u4 = 0,
        bit_depth_luma: u4 = 0,
        bit_depth_chroma: u4 = 0,
        log2_min_luma_coding_block_size: u4 = 0,
        log2_max_luma_coding_block_size: u4 = 0,
        log2_min_transform_block_size: u4 = 0,
        log2_max_transform_block_size: u4 = 0,
        reserved2: u4 = 0,
    } = .{},
    sps1: packed struct(u32) {
        max_transform_hierarchy_depth_inter: u3 = 0,
        max_transform_hierarchy_depth_intra: u3 = 0,
        scalingListEnable: u1 = 0,
        amp_enable_flag: u1 = 0,
        sample_adaptive_offset_enabled_flag: u1 = 0,
        pcm_enabled_flag: u1 = 0,
        pcm_sample_bit_depth_luma: u4 = 0,
        pcm_sample_bit_depth_chroma: u4 = 0,
        log2_min_pcm_luma_coding_block_size: u4 = 0,
        log2_max_pcm_luma_coding_block_size: u4 = 0,
        pcm_loop_filter_disabled_flag: u1 = 0,
        sps_temporal_mvp_enabled_flag: u1 = 0,
        strong_intra_smoothing_enabled_flag: u1 = 0,
        reserved3: u3 = 0,
    } = .{},
    pps0: packed struct(u32) {
        dependent_slice_segments_enabled_flag: u1 = 0,
        output_flag_present_flag: u1 = 0,
        num_extra_slice_header_bits: u3 = 0,
        sign_data_hiding_enabled_flag: u1 = 0,
        cabac_init_present_flag: u1 = 0,
        num_ref_idx_l0_default_active: u4 = 0,
        num_ref_idx_l1_default_active: u4 = 0,
        init_qp: u7 = 0,
        constrained_intra_pred_flag: u1 = 0,
        transform_skip_enabled_flag: u1 = 0,
        cu_qp_delta_enabled_flag: u1 = 0,
        diff_cu_qp_delta_depth: u2 = 0,
        reserved4: u5 = 0,
    } = .{},
    pps_cb_qp_offset: i8 = 0,
    pps_cr_qp_offset: i8 = 0,
    pps_beta_offset: i8 = 0,
    pps_tc_offset: i8 = 0,
    pps1: packed struct(u32) {
        pps_slice_chroma_qp_offsets_present_flag: u1 = 0,
        weighted_pred_flag: u1 = 0,
        weighted_bipred_flag: u1 = 0,
        transquant_bypass_enabled_flag: u1 = 0,
        tiles_enabled_flag: u1 = 0,
        entropy_coding_sync_enabled_flag: u1 = 0,
        num_tile_columns: u5 = 0,
        num_tile_rows: u5 = 0,
        loop_filter_across_tiles_enabled_flag: u1 = 0,
        loop_filter_across_slices_enabled_flag: u1 = 0,
        deblocking_filter_control_present_flag: u1 = 0,
        deblocking_filter_override_enabled_flag: u1 = 0,
        pps_deblocking_filter_disabled_flag: u1 = 0,
        lists_modification_present_flag: u1 = 0,
        log2_parallel_merge_level: u3 = 0,
        slice_segment_header_extension_present_flag: u1 = 0,
        reserved5: u6 = 0,
    } = .{},
    num_ref_frames: u8 = 0,
    reserved6: u8 = 0,
    /// bit 15 - slot: that slot's picture is a long-term reference
    longtermflag: u16 = 0,
    initreflistidxl0: [16]u8 = [_]u8{0} ** 16,
    initreflistidxl1: [16]u8 = [_]u8{0} ** 16,
    /// per slot: the current order count less that picture's
    RefDiffPicOrderCnts: [16]i16 = [_]i16{0} ** 16,
    IDR_picture_flag: u8 = 0,
    RAP_picture_flag: u8 = 0,
    curr_pic_idx: u8 = 0,
    /// 2: no dithering (8-bit output)
    pattern_id: u8 = 0,
    sw_hdr_skip_length: u16 = 0,
    reserved7: u16 = 0,
    /// nvdec_ecdma_config_s (24 bytes): off
    ecdma: [6]u32 = [_]u32{0} ** 6,
    dxva: packed struct(u32) {
        separate_colour_plane_flag: u1 = 0,
        log2_max_pic_order_cnt_lsb_minus4: u4 = 0,
        num_short_term_ref_pic_sets: u7 = 0,
        num_long_term_ref_pics_sps: u6 = 0,
        bBitParsingDisable: u1 = 0,
        num_delta_pocs_of_rps_idx: u8 = 0,
        long_term_ref_pics_present_flag: u1 = 0,
        reserved_dxva: u4 = 0,
    } = .{},
    num_bits_short_term_ref_pics_in_slice: u32 = 0,
    v1: V1 = .{},
    /// nvdec_hevc_pic_v2_s (MV-HEVC): off
    v2: u32 = 0,
    /// nvdec_hevc_pic_v3_s (slice-level decoding): off
    v3: [2]u32 = .{ 0, 0 },
    /// nvdec_pass2_otf_ext_s
    ssm: [3]u32 = .{ 0, 0, 0 },
};

/// nvdec_hevc_scaling_list_s (HEVC_SET_SCALING_LIST_OFFSET): VA's lists
/// as they come (raster order), the DC terms first.
pub const ScalingList = extern struct {
    ScalingListDCCoeff16x16: [6]u8,
    ScalingListDCCoeff32x32: [2]u8,
    reserved0: [8]u8 = [_]u8{0} ** 8,
    ScalingList4x4: [6][16]u8,
    ScalingList8x8: [6][64]u8,
    ScalingList16x16: [6][64]u8,
    ScalingList32x32: [2][64]u8,
};

comptime {
    std.debug.assert(@offsetOf(HevcPic, "stream_len") == 0x30);
    std.debug.assert(@offsetOf(HevcPic, "gptimer_timeout_value") == 0x3c);
    std.debug.assert(@offsetOf(HevcPic, "surface") == 0x40);
    std.debug.assert(@offsetOf(HevcPic, "framestride") == 0x44);
    std.debug.assert(@offsetOf(HevcPic, "pic_width_in_luma_samples") == 0x58);
    std.debug.assert(@offsetOf(HevcPic, "sps0") == 0x5c);
    std.debug.assert(@offsetOf(HevcPic, "pps0") == 0x64);
    std.debug.assert(@offsetOf(HevcPic, "pps_cb_qp_offset") == 0x68);
    std.debug.assert(@offsetOf(HevcPic, "pps1") == 0x6c);
    std.debug.assert(@offsetOf(HevcPic, "num_ref_frames") == 0x70);
    std.debug.assert(@offsetOf(HevcPic, "initreflistidxl0") == 0x74);
    std.debug.assert(@offsetOf(HevcPic, "RefDiffPicOrderCnts") == 0x94);
    std.debug.assert(@offsetOf(HevcPic, "IDR_picture_flag") == 0xb4);
    std.debug.assert(@offsetOf(HevcPic, "sw_hdr_skip_length") == 0xb8);
    std.debug.assert(@offsetOf(HevcPic, "ecdma") == 0xbc);
    std.debug.assert(@offsetOf(HevcPic, "dxva") == 0xd4);
    std.debug.assert(@offsetOf(HevcPic, "v1") == 0xdc);
    std.debug.assert(@sizeOf(V1) == 0x20);
    std.debug.assert(@offsetOf(HevcPic, "v2") == 0xfc);
    std.debug.assert(@sizeOf(HevcPic) == 0x114);
    std.debug.assert(@sizeOf(ScalingList) == 1008);
}

// ── Buffers ─────────────────────────────────────────────────────────────────

/// Blackwell's words past Ada's struct (State.blackwell): the 0x4dc
/// buffer's count (codec.blkUnits of the picture's width), then a u16 0xffff.
pub const BLACKWELL_UNITS_AT: usize = 0x11c;
pub const BLACKWELL_FFFF_AT: usize = 0x120;
pub const MAX_PIC_BYTES: usize = 0x124;
/// The frame slot's side buffers: the scaling list, then the tile sizes.
pub const SCALING_OFF: usize = 0;
pub const TILES_OFF: usize = 0x400;
/// The tile-size buffer: (width, height) in CTBs per tile, raster order,
/// then from u16 index 0x380 each column's and each row's right/bottom
/// edge in 16-sample units.
pub const TILES_BYTES: usize = 0x900;
pub const TILE_EDGES_AT: usize = 0x380;
pub const MAX_AUX_BYTES: usize = TILES_OFF + TILES_BYTES;

const CTU_SIZE = 64;
/// The filter buffer's bytes per row of 64-aligned height: deblocking,
/// SAO, then the BSD's control data.
const FILTER_SIZE = 480;
const SAO_SIZE = 3840;
const BSD_SIZE = 60;
/// The intra-prediction row above (NVK: one 64 KiB upload; room here for
/// 8K-wide pictures).
const INTRA_TOP_BYTES: usize = 0x40000;

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) / a * a;
}

/// Where the context's buffers are in its scratch, for pictures up to
/// `width` x `height`.
pub const Layout = struct {
    /// one picture's co-located motion (all 17 slots' follow it)
    colmv: usize,
    coloc_off: usize,
    filter_off: usize,
    /// inside the filter buffer
    sao_off: usize,
    bsd_off: usize,
    /// the rows above, set apart after the BSD's data (nvdec_drv.h's
    /// HEVC_DBLK_TOP_BUF_SIZE; the SAO's sized alike): whether the
    /// decoder reads these offsets or keeps its own is not public, so
    /// they never overlap the rest
    flt_above_off: usize,
    sao_above_off: usize,
    intra_top_off: usize,
    /// Blackwell's buffer (codec.SET_BLK_BUF_OFFSET)
    blk_off: usize,
    bytes: usize,

    pub fn of(width: u32, height: u32) Layout {
        const w = alignUp(width, CTU_SIZE);
        const h = alignUp(height, CTU_SIZE);
        const colmv = alignUp(w * h / 16, 256);
        const coloc_off = 0;
        const filter_off = alignUp(coloc_off + colmv * nvdec.SLOTS, 4096);
        const sao_off = FILTER_SIZE * h;
        const bsd_off = (FILTER_SIZE + SAO_SIZE) * h;
        const sb16 = alignUp(width, 16) / 16 + 2;
        const flt_above_off = alignUp((FILTER_SIZE + SAO_SIZE + BSD_SIZE) * h, 256);
        const sao_above_off = flt_above_off + alignUp(sb16 * alignUp(632, 128), 256);
        const filter_bytes = sao_above_off + alignUp(sb16 * alignUp(713, 128), 256);
        const intra_top_off = alignUp(filter_off + filter_bytes, 4096);
        const blk_off = intra_top_off + INTRA_TOP_BYTES;
        return .{
            .colmv = colmv,
            .coloc_off = coloc_off,
            .filter_off = filter_off,
            .sao_off = sao_off,
            .bsd_off = bsd_off,
            .flt_above_off = flt_above_off,
            .sao_above_off = sao_above_off,
            .intra_top_off = intra_top_off,
            .blk_off = blk_off,
            .bytes = blk_off + alignUp(codec.blkBytes(width), 4096),
        };
    }
};

pub fn scratchBytes(width: u32, height: u32) usize {
    return Layout.of(width, height).bytes;
}

// ── The slice header's skipped bits ─────────────────────────────────────────

/// A big-endian bit reader over a NAL unit's payload that drops
/// emulation-prevention bytes (00 00 03), as the decoder counts bits.
pub const Bits = struct {
    data: []const u8,
    /// byte and bit position
    at: usize = 0,
    bit: u3 = 0,
    zeros: u2 = 0,
    /// the bits read so far (RBSP bits)
    read: u32 = 0,
    cur: u8 = 0,
    loaded: bool = false,

    fn load(b: *Bits) error{End}!void {
        while (true) {
            if (b.at >= b.data.len) return error.End;
            const v = b.data[b.at];
            if (b.zeros == 2 and v == 3) {
                b.at += 1;
                b.zeros = 0;
                continue;
            }
            b.zeros = if (v == 0) @min(b.zeros + 1, 2) else 0;
            b.cur = v;
            b.loaded = true;
            return;
        }
    }

    pub fn u1_(b: *Bits) error{End}!u32 {
        if (!b.loaded) try b.load();
        const v = (b.cur >> (7 - @as(u3, b.bit))) & 1;
        if (b.bit == 7) {
            b.bit = 0;
            b.at += 1;
            b.loaded = false;
        } else b.bit += 1;
        b.read += 1;
        return v;
    }

    pub fn u(b: *Bits, n: u6) error{End}!u32 {
        var v: u32 = 0;
        var k: u6 = 0;
        while (k < n) : (k += 1) v = (v << 1) | try b.u1_();
        return v;
    }

    /// ue(v)
    pub fn ue(b: *Bits) error{ End, Bad }!u32 {
        var zeros: u6 = 0;
        while ((try b.u1_()) == 0) {
            zeros += 1;
            if (zeros > 31) return error.Bad;
        }
        if (zeros == 0) return 0;
        return ((@as(u32, 1) << @intCast(zeros)) - 1) + try b.u(zeros);
    }
};

/// Ceil(Log2(n)), 0 for n <= 1.
fn ceilLog2(n: u32) u6 {
    if (n <= 1) return 0;
    return @intCast(32 - @clz(n - 1));
}

/// A long-term reference the slice header names for the current picture.
pub const LtEntry = struct {
    /// its order count's low bits, and the whole count when the header
    /// gives the high bits (else null); null lsb: taken from the SPS's
    /// list, which VA-API does not pass on
    lsb: ?u32,
    poc: ?i32,
    used: bool,
};

pub const Header = struct {
    /// sw_hdr_skip_length
    skip: u32,
    lt: [32]LtEntry = undefined,
    lt_count: u8 = 0,
};

/// The first slice segment's header (`nal`: its NAL unit, from the header
/// bytes on), read to the end of the long-term reference set.
pub fn parseHeader(nal: []const u8, p: *const va.PictureParameterBufferHEVC) error{ End, Bad }!Header {
    if (nal.len < 3) return error.End;
    const nal_type = (nal[0] >> 1) & 0x3f;
    var b = Bits{ .data = nal[2..] };
    const pf = p.pic_fields;
    const sf = p.slice_parsing_fields;
    const first = try b.u1_();
    if (nal_type >= 16 and nal_type <= 23) _ = try b.u1_(); // no_output_of_prior_pics_flag
    _ = try b.ue(); // slice_pic_parameter_set_id
    var dependent: u32 = 0;
    if (first == 0) {
        if (sf.dependent_slice_segments_enabled_flag != 0) dependent = try b.u1_();
        const log2_min_cb: u6 = @intCast(@as(u32, p.log2_min_luma_coding_block_size_minus3) + 3);
        const log2_ctb: u6 = log2_min_cb + @as(u6, @intCast(p.log2_diff_max_min_luma_coding_block_size));
        const ctb: u32 = @as(u32, 1) << @intCast(log2_ctb);
        const ctbs = ((p.pic_width_in_luma_samples + ctb - 1) / ctb) * ((p.pic_height_in_luma_samples + ctb - 1) / ctb);
        _ = try b.u(ceilLog2(ctbs)); // slice_segment_address
    }
    if (dependent != 0) return error.Bad; // (a picture's first slice never is)
    var k: u32 = 0;
    while (k < p.num_extra_slice_header_bits) : (k += 1) _ = try b.u1_();
    _ = try b.ue(); // slice_type
    const start = b.read;
    var h = Header{ .skip = 0 };
    if (sf.output_flag_present_flag != 0) _ = try b.u1_(); // pic_output_flag
    if (pf.separate_colour_plane_flag != 0) _ = try b.u(2); // colour_plane_id
    const idr = nal_type == 19 or nal_type == 20;
    if (!idr) {
        const lsb_bits: u6 = @intCast(@as(u32, p.log2_max_pic_order_cnt_lsb_minus4) + 4);
        const poc_lsb = try b.u(lsb_bits);
        const sps_flag = try b.u1_();
        if (sps_flag == 0) {
            // (VA gives its length: short_term_ref_pic_set() itself)
            var s: u32 = 0;
            while (s < p.st_rps_bits) : (s += 1) _ = try b.u1_();
        } else {
            _ = try b.u(ceilLog2(p.num_short_term_ref_pic_sets));
        }
        if (sf.long_term_ref_pics_present_flag != 0) {
            var num_sps: u32 = 0;
            if (p.num_long_term_ref_pic_sps > 0) num_sps = try b.ue();
            const num_pics = try b.ue();
            if (num_sps + num_pics > h.lt.len) return error.Bad;
            const max_lsb: i64 = @as(i64, 1) << lsb_bits;
            const cur_poc: i64 = p.CurrPic.pic_order_cnt;
            var msb_cycle: i64 = 0;
            var i: u32 = 0;
            while (i < num_sps + num_pics) : (i += 1) {
                var e = LtEntry{ .lsb = null, .poc = null, .used = true };
                if (i < num_sps) {
                    if (p.num_long_term_ref_pic_sps > 1) _ = try b.u(ceilLog2(p.num_long_term_ref_pic_sps)); // lt_idx_sps
                } else {
                    e.lsb = try b.u(lsb_bits); // poc_lsb_lt
                    e.used = (try b.u1_()) != 0;
                }
                const msb_present = try b.u1_();
                if (msb_present != 0) {
                    const cycle = try b.ue();
                    // (DeltaPocMsbCycleLt accumulates, but not across the
                    // SPS/slice boundary)
                    msb_cycle = if (i == 0 or i == num_sps) cycle else msb_cycle + cycle;
                    if (e.lsb) |l| {
                        const poc = cur_poc - msb_cycle * max_lsb - @as(i64, poc_lsb) + @as(i64, l);
                        e.poc = std.math.cast(i32, poc);
                    }
                }
                h.lt[h.lt_count] = e;
                h.lt_count += 1;
            }
        }
    }
    h.skip = b.read - start;
    return h;
}

// ── Per-context state ───────────────────────────────────────────────────────

const NONE: u32 = 0xffff_ffff;
const MAX_STREAM_SLICES = 600;

pub const State = struct {
    width: u32,
    height: u32,
    layout: Layout,
    /// Blackwell's additions sent (GALAXY_VA_HEVC_BLACKWELL)
    blackwell: codec.Blackwell = .full,
    /// SET_CONTROL_PARAMS' word (GALAXY_VA_CONTROL)
    control: codec.Control = .nvk,
    /// each picture slot's VA surface (NONE: free)
    slot_surface: [nvdec.SLOTS]u32 = [_]u32{NONE} ** nvdec.SLOTS,
    // ── the picture being made ──
    pic: va.PictureParameterBufferHEVC = undefined,
    have_pic: bool = false,
    iq: va.IQMatrixBufferHEVC = undefined,
    have_iq: bool = false,
    header: Header = .{ .skip = 0 },
    have_header: bool = false,
    slices: u32 = 0,
    stream: usize = 0,
    /// the slice parameter buffer whose data comes next
    params: ?codec.Buffer = null,

    pub fn init(width: u32, height: u32) State {
        return .{ .width = width, .height = height, .layout = Layout.of(width, height) };
    }
};

pub fn begin(st: *State) void {
    st.have_pic = false;
    st.have_iq = false;
    st.have_header = false;
    st.slices = 0;
    st.stream = 0;
    st.params = null;
}

/// The 4-byte start code each slice gets (the decoder finds slices by
/// them: sw_start_code_e).
const START = [4]u8{ 0, 0, 0, 1 };

pub fn take(st: *State, b: codec.Buffer, slot: codec.Slot) va.Status {
    switch (b.kind) {
        va.PICTURE_PARAMETER_BUFFER => {
            if (b.data.len < @sizeOf(va.PictureParameterBufferHEVC)) return va.ERROR_INVALID_BUFFER;
            st.pic = b.element(va.PictureParameterBufferHEVC, 0);
            st.have_pic = true;
        },
        va.IQ_MATRIX_BUFFER => {
            if (b.data.len < @sizeOf(va.IQMatrixBufferHEVC)) return va.ERROR_INVALID_BUFFER;
            st.iq = b.element(va.IQMatrixBufferHEVC, 0);
            st.have_iq = true;
        },
        va.SLICE_PARAMETER_BUFFER => {
            if (b.size < @sizeOf(va.SliceParameterBufferHEVC) or b.count == 0) return va.ERROR_INVALID_BUFFER;
            st.params = b;
        },
        va.SLICE_DATA_BUFFER => {
            const params = st.params orelse return va.ERROR_INVALID_BUFFER;
            if (!st.have_pic) return va.ERROR_INVALID_BUFFER;
            for (0..params.count) |k| {
                const s = params.element(va.SliceParameterBufferHEVC, k);
                if (@as(u64, s.slice_data_offset) + s.slice_data_size > b.data.len) return va.ERROR_INVALID_BUFFER;
                if (st.slices >= MAX_STREAM_SLICES) return va.ERROR_MAX_NUM_EXCEEDED;
                const nal = b.data[s.slice_data_offset..][0..s.slice_data_size];
                if (st.stream + START.len + nal.len > slot.stream.len) return va.ERROR_NOT_ENOUGH_BUFFER;
                if (!st.have_header) {
                    st.header = parseHeader(nal, &st.pic) catch return va.ERROR_INVALID_BUFFER;
                    st.have_header = true;
                }
                @memcpy(slot.stream[st.stream..][0..START.len], &START);
                @memcpy(slot.stream[st.stream + START.len ..][0..nal.len], nal);
                st.stream += START.len + nal.len;
                st.slices += 1;
            }
            st.params = null;
        },
        else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
    }
    return va.SUCCESS;
}

// ── The picture ─────────────────────────────────────────────────────────────

/// Picture slots: those not holding the target or a reference are let go;
/// the target and each reference keep theirs or take the lowest free one.
/// The target's slot, or null (refs that found none are left out).
fn assignSlots(st: *State, target: u32, refs: []u32) ?u5 {
    for (&st.slot_surface) |*o| {
        if (o.* == NONE or o.* == target) continue;
        if (std.mem.indexOfScalar(u32, refs, o.*) == null) o.* = NONE;
    }
    const t = slotOf(st, target) orelse takeSlot(st, target) orelse return null;
    for (refs) |*r| {
        if (r.* == NONE) continue;
        if (slotOf(st, r.*) == null and takeSlot(st, r.*) == null) r.* = NONE;
    }
    return t;
}

fn slotOf(st: *const State, id: u32) ?u5 {
    const k = std.mem.indexOfScalar(u32, &st.slot_surface, id) orelse return null;
    return @intCast(k);
}

fn takeSlot(st: *State, id: u32) ?u5 {
    const k = std.mem.indexOfScalar(u32, &st.slot_surface, NONE) orelse return null;
    st.slot_surface[k] = id;
    return @intCast(k);
}

fn clipDiff(d: i64) i16 {
    return @intCast(std.math.clamp(d, -128, 127));
}

/// The tile sizes (TILES_BYTES) for `p`.
pub fn tileSizes(out: []u16, p: *const va.PictureParameterBufferHEVC) void {
    @memset(out, 0);
    const log2_ctb: u5 = @intCast(@as(u32, p.log2_min_luma_coding_block_size_minus3) + 3 + p.log2_diff_max_min_luma_coding_block_size);
    const ctb: u32 = @as(u32, 1) << log2_ctb;
    const wc = (p.pic_width_in_luma_samples + ctb - 1) / ctb;
    const hc = (p.pic_height_in_luma_samples + ctb - 1) / ctb;
    if (p.pic_fields.tiles_enabled_flag == 0) {
        out[0] = @intCast(wc);
        out[1] = @intCast(hc);
        return;
    }
    const cols = @as(u32, p.num_tile_columns_minus1) + 1;
    const rows = @as(u32, p.num_tile_rows_minus1) + 1;
    var cw: [20]u32 = undefined;
    var rh: [22]u32 = undefined;
    // (VA passes the widths whether the spacing is uniform or not: the
    // last is what the others leave)
    var used: u32 = 0;
    for (0..cols) |i| {
        cw[i] = if (i + 1 == cols) wc -| used else @as(u32, p.column_width_minus1[i]) + 1;
        used += cw[i];
    }
    used = 0;
    for (0..rows) |i| {
        rh[i] = if (i + 1 == rows) hc -| used else @as(u32, p.row_height_minus1[i]) + 1;
        used += rh[i];
    }
    var n: usize = 0;
    for (0..rows) |r| {
        for (0..cols) |c| {
            out[n] = @intCast(cw[c]);
            out[n + 1] = @intCast(rh[r]);
            n += 2;
        }
    }
    // the edges, in 16-sample units
    const shift: u5 = log2_ctb - 4;
    var e = TILE_EDGES_AT;
    var sum: u32 = 0;
    for (cw[0..cols]) |w| {
        sum += w;
        out[e] = @intCast(sum << shift);
        e += 1;
    }
    sum = 0;
    for (rh[0..rows]) |h| {
        sum += h;
        out[e] = @intCast(sum << shift);
        e += 1;
    }
}

pub const PUSH_DWORDS = 2 * 14 + 2 * (1 + nvdec.SLOTS) + 2;

pub fn end(st: *State, slot: codec.Slot, scratch: codec.Scratch, pic: codec.Picture, lookup: codec.Lookup, out: *codec.End) va.Status {
    if (!st.have_pic or st.slices == 0 or !st.have_header) return va.ERROR_INVALID_PARAMETER;
    const p = &st.pic;
    const pf = p.pic_fields;
    const sf = p.slice_parsing_fields;
    if (pf.chroma_format_idc != 1 or pf.separate_colour_plane_flag != 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
    // Main (8-bit) and Main10 (10-bit, P010 targets): luma and chroma of
    // one depth, the target's
    const depth = @as(u32, p.bit_depth_luma_minus8) + 8;
    if (p.bit_depth_chroma_minus8 != p.bit_depth_luma_minus8 or (depth != 8 and depth != 10)) return va.ERROR_UNSUPPORTED_RT_FORMAT;
    if (!pic.target.holds(depth)) return va.ERROR_INVALID_SURFACE;
    if (p.pic_width_in_luma_samples > st.width or p.pic_height_in_luma_samples > st.height) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    if (p.pic_width_in_luma_samples > pic.target.width or p.pic_height_in_luma_samples > pic.target.height) return va.ERROR_INVALID_SURFACE;
    if (p.num_tile_columns_minus1 >= 20 or p.num_tile_rows_minus1 >= 22) return va.ERROR_INVALID_PARAMETER;
    const L = st.layout;
    if (scratch.cpu.len < L.bytes) return va.ERROR_ALLOCATION_FAILED;

    // The references (VA's 15) and everyone's slot.
    var ref_id = [_]u32{NONE} ** 15;
    for (p.ReferenceFrames, 0..) |rf, k| {
        if (rf.flags & va.PICTURE_HEVC_INVALID != 0 or rf.picture_id == va.INVALID_ID) continue;
        if (lookup.surface(rf.picture_id) == null) continue;
        ref_id[k] = rf.picture_id;
    }
    const cur = assignSlots(st, pic.target_id, &ref_id) orelse return va.ERROR_MAX_NUM_EXCEEDED;

    var s = HevcPic{};
    s.stream_len = @intCast(st.stream);
    s.gptimer_timeout_value = nvdec.GPTIMER_TIMEOUT;
    s.surface = .{ .tileformat = 1, .gob_height = pic.gob_height };
    s.sw_start_code_e = 1;
    // (nvdec_drv.h's output modes: 0 Rec.709 8-bit, 1 Rec.709 10-bit: the
    // 16-bit samples of P010, the 10 bits at the top; the frame strides
    // then count those 2-byte samples, half the bytes, as NVIDIA's Tegra
    // driver and NVK give them)
    const ten = depth == 10;
    s.disp_output_mode = if (ten) 1 else 0;
    s.framestride = if (ten) .{ pic.target.pitch_luma / 2, pic.target.pitch_chroma / 2 } else .{ pic.target.pitch_luma, pic.target.pitch_chroma };
    s.colMvBuffersize = @intCast(L.colmv >> 8);
    s.HevcSaoBufferOffset = @intCast(L.sao_off >> 8);
    s.HevcBsdCtrlOffset = @intCast(L.bsd_off >> 8);
    s.v1.HevcFltAboveOffset = @intCast(L.flt_above_off >> 8);
    s.v1.HevcSaoAboveOffset = @intCast(L.sao_above_off >> 8);
    s.pic_width_in_luma_samples = p.pic_width_in_luma_samples;
    s.pic_height_in_luma_samples = p.pic_height_in_luma_samples;
    const log2_min_cb = @as(u32, p.log2_min_luma_coding_block_size_minus3) + 3;
    const log2_min_tb = @as(u32, p.log2_min_transform_block_size_minus2) + 2;
    s.sps0 = .{
        .chroma_format_idc = 1,
        .bit_depth_luma = @intCast(depth),
        .bit_depth_chroma = @intCast(depth),
        .log2_min_luma_coding_block_size = @intCast(log2_min_cb),
        .log2_max_luma_coding_block_size = @intCast(log2_min_cb + p.log2_diff_max_min_luma_coding_block_size),
        .log2_min_transform_block_size = @intCast(log2_min_tb),
        .log2_max_transform_block_size = @intCast(log2_min_tb + p.log2_diff_max_min_transform_block_size),
    };
    const pcm = pf.pcm_enabled_flag != 0;
    const log2_min_pcm = @as(u32, p.log2_min_pcm_luma_coding_block_size_minus3) + 3;
    s.sps1 = .{
        .max_transform_hierarchy_depth_inter = @intCast(p.max_transform_hierarchy_depth_inter),
        .max_transform_hierarchy_depth_intra = @intCast(p.max_transform_hierarchy_depth_intra),
        .scalingListEnable = pf.scaling_list_enabled_flag,
        .amp_enable_flag = pf.amp_enabled_flag,
        .sample_adaptive_offset_enabled_flag = sf.sample_adaptive_offset_enabled_flag,
        .pcm_enabled_flag = pf.pcm_enabled_flag,
        .pcm_sample_bit_depth_luma = if (pcm) @intCast(@as(u32, p.pcm_sample_bit_depth_luma_minus1) + 1) else 0,
        .pcm_sample_bit_depth_chroma = if (pcm) @intCast(@as(u32, p.pcm_sample_bit_depth_chroma_minus1) + 1) else 0,
        .log2_min_pcm_luma_coding_block_size = if (pcm) @intCast(log2_min_pcm) else 0,
        .log2_max_pcm_luma_coding_block_size = if (pcm) @intCast(log2_min_pcm + p.log2_diff_max_min_pcm_luma_coding_block_size) else 0,
        .pcm_loop_filter_disabled_flag = pf.pcm_loop_filter_disabled_flag,
        .sps_temporal_mvp_enabled_flag = sf.sps_temporal_mvp_enabled_flag,
        .strong_intra_smoothing_enabled_flag = pf.strong_intra_smoothing_enabled_flag,
    };
    s.pps0 = .{
        .dependent_slice_segments_enabled_flag = sf.dependent_slice_segments_enabled_flag,
        .output_flag_present_flag = sf.output_flag_present_flag,
        .num_extra_slice_header_bits = @intCast(p.num_extra_slice_header_bits & 7),
        .sign_data_hiding_enabled_flag = pf.sign_data_hiding_enabled_flag,
        .cabac_init_present_flag = sf.cabac_init_present_flag,
        .num_ref_idx_l0_default_active = @intCast((@as(u32, p.num_ref_idx_l0_default_active_minus1) + 1) & 15),
        .num_ref_idx_l1_default_active = @intCast((@as(u32, p.num_ref_idx_l1_default_active_minus1) + 1) & 15),
        // (plus 6 for each bit past 8: QpBdOffsetY, as NVK sets it)
        .init_qp = @intCast(@as(i32, p.init_qp_minus26) + 26 + 6 * @as(i32, p.bit_depth_luma_minus8)),
        .constrained_intra_pred_flag = pf.constrained_intra_pred_flag,
        .transform_skip_enabled_flag = pf.transform_skip_enabled_flag,
        .cu_qp_delta_enabled_flag = pf.cu_qp_delta_enabled_flag,
        .diff_cu_qp_delta_depth = @intCast(p.diff_cu_qp_delta_depth & 3),
    };
    s.pps_cb_qp_offset = p.pps_cb_qp_offset;
    s.pps_cr_qp_offset = p.pps_cr_qp_offset;
    s.pps_beta_offset = p.pps_beta_offset_div2 *% 2;
    s.pps_tc_offset = p.pps_tc_offset_div2 *% 2;
    const tiles = pf.tiles_enabled_flag != 0;
    s.pps1 = .{
        .pps_slice_chroma_qp_offsets_present_flag = sf.pps_slice_chroma_qp_offsets_present_flag,
        .weighted_pred_flag = pf.weighted_pred_flag,
        .weighted_bipred_flag = pf.weighted_bipred_flag,
        .transquant_bypass_enabled_flag = pf.transquant_bypass_enabled_flag,
        .tiles_enabled_flag = pf.tiles_enabled_flag,
        .entropy_coding_sync_enabled_flag = pf.entropy_coding_sync_enabled_flag,
        .num_tile_columns = if (tiles) @intCast(@as(u32, p.num_tile_columns_minus1) + 1) else 0,
        .num_tile_rows = if (tiles) @intCast(@as(u32, p.num_tile_rows_minus1) + 1) else 0,
        .loop_filter_across_tiles_enabled_flag = if (tiles) pf.loop_filter_across_tiles_enabled_flag else 0,
        .loop_filter_across_slices_enabled_flag = pf.pps_loop_filter_across_slices_enabled_flag,
        .deblocking_filter_control_present_flag = @intFromBool(sf.deblocking_filter_override_enabled_flag != 0 or sf.pps_disable_deblocking_filter_flag != 0 or p.pps_beta_offset_div2 != 0 or p.pps_tc_offset_div2 != 0),
        .deblocking_filter_override_enabled_flag = sf.deblocking_filter_override_enabled_flag,
        .pps_deblocking_filter_disabled_flag = sf.pps_disable_deblocking_filter_flag,
        .lists_modification_present_flag = sf.lists_modification_present_flag,
        .log2_parallel_merge_level = @intCast((@as(u32, p.log2_parallel_merge_level_minus2) + 2) & 7),
        .slice_segment_header_extension_present_flag = sf.slice_segment_header_extension_present_flag,
    };
    s.IDR_picture_flag = sf.IdrPicFlag;
    s.RAP_picture_flag = sf.RapPicFlag;
    s.curr_pic_idx = cur;
    s.pattern_id = 2;
    s.sw_hdr_skip_length = @intCast(@min(st.header.skip, 0xffff));
    s.dxva = .{
        .log2_max_pic_order_cnt_lsb_minus4 = @intCast(p.log2_max_pic_order_cnt_lsb_minus4 & 15),
        .num_short_term_ref_pic_sets = @intCast(p.num_short_term_ref_pic_sets & 0x7f),
        .num_long_term_ref_pics_sps = @intCast(p.num_long_term_ref_pic_sps & 0x3f),
        .long_term_ref_pics_present_flag = sf.long_term_ref_pics_present_flag,
    };
    s.num_bits_short_term_ref_pics_in_slice = p.st_rps_bits;
    // v3 as NVIDIA's driver sets it (AROS's trace): the slice-edge part at
    // the SAO-above part's offset, concealment from co-located MVs (1, 3:2),
    // a P slice's (1, 6:5) for an intra picture
    s.v3 = .{ (1 << 2) | (@as(u32, @intFromBool(sf.RapPicFlag != 0)) << 5), @intCast(L.sao_above_off >> 8) };
    if (st.blackwell.writesFields()) {
        s.reserved6 = codec.surfaceCode(depth);
        // (3 x depth index + chroma_format_idc - 1; 4:2:0 only here)
        s.reserved7 = codec.depthCode(depth);
    }

    // The reference sets, by slot.
    const cur_poc: i64 = p.CurrPic.pic_order_cnt;
    var bef: [15]u8 = undefined;
    var before_poc: [15]i32 = undefined;
    var nb: usize = 0;
    var aft: [15]u8 = undefined;
    var after_poc: [15]i32 = undefined;
    var na: usize = 0;
    var lt: [15]u8 = undefined;
    var lt_poc: [15]i32 = undefined;
    var nl: usize = 0;
    // (a reference for the slots nobody holds: concealment reads it)
    var scratch_slot: ?u5 = null;
    var scratch_diff: i16 = 0;
    for (p.ReferenceFrames, 0..) |rf, k| {
        const id = ref_id[k];
        if (id == NONE) continue;
        const rs = slotOf(st, id) orelse continue;
        const diff = clipDiff(cur_poc - rf.pic_order_cnt);
        if (rs < 16) s.RefDiffPicOrderCnts[rs] = diff;
        if (rf.flags & va.PICTURE_HEVC_LONG_TERM_REFERENCE != 0 and rs < 16) s.longtermflag |= @as(u16, 1) << @intCast(15 - @as(u5, rs));
        const set = rf.flags & (va.PICTURE_HEVC_RPS_ST_CURR_BEFORE | va.PICTURE_HEVC_RPS_ST_CURR_AFTER | va.PICTURE_HEVC_RPS_LT_CURR);
        if (set != 0 and scratch_slot == null) {
            scratch_slot = rs;
            scratch_diff = diff;
        }
        if (set & va.PICTURE_HEVC_RPS_ST_CURR_BEFORE != 0) {
            bef[nb] = rs;
            before_poc[nb] = rf.pic_order_cnt;
            nb += 1;
        } else if (set & va.PICTURE_HEVC_RPS_ST_CURR_AFTER != 0) {
            aft[na] = rs;
            after_poc[na] = rf.pic_order_cnt;
            na += 1;
        } else if (set & va.PICTURE_HEVC_RPS_LT_CURR != 0) {
            lt[nl] = rs;
            lt_poc[nl] = rf.pic_order_cnt;
            nl += 1;
        }
    }
    // StCurrBefore: nearest first (descending); StCurrAfter: ascending.
    sortBy(bef[0..nb], before_poc[0..nb], .desc);
    sortBy(aft[0..na], after_poc[0..na], .asc);
    orderLongTerm(lt[0..nl], lt_poc[0..nl], &st.header, p.log2_max_pic_order_cnt_lsb_minus4);
    s.num_ref_frames = @intCast(nb + na + nl);
    if (nb + na + nl != 0) {
        fillList(&s.initreflistidxl0, bef[0..nb], aft[0..na], lt[0..nl]);
        fillList(&s.initreflistidxl1, aft[0..na], bef[0..nb], lt[0..nl]);
    }
    for (0..16) |i| {
        if (i == cur) continue;
        if (st.slot_surface[i] == NONE) s.RefDiffPicOrderCnts[i] = scratch_diff;
    }

    // Side buffers: scaling lists, tile sizes.
    if (pf.scaling_list_enabled_flag != 0) {
        var sl: ScalingList = undefined;
        if (st.have_iq) {
            const iq = &st.iq;
            sl = .{
                .ScalingListDCCoeff16x16 = iq.ScalingListDC16x16,
                .ScalingListDCCoeff32x32 = iq.ScalingListDC32x32,
                .ScalingList4x4 = iq.ScalingList4x4,
                .ScalingList8x8 = iq.ScalingList8x8,
                .ScalingList16x16 = iq.ScalingList16x16,
                .ScalingList32x32 = iq.ScalingList32x32,
            };
        } else {
            sl = .{
                .ScalingListDCCoeff16x16 = [_]u8{16} ** 6,
                .ScalingListDCCoeff32x32 = [_]u8{16} ** 2,
                .ScalingList4x4 = [_][16]u8{[_]u8{16} ** 16} ** 6,
                .ScalingList8x8 = [_][64]u8{[_]u8{16} ** 64} ** 6,
                .ScalingList16x16 = [_][64]u8{[_]u8{16} ** 64} ** 6,
                .ScalingList32x32 = [_][64]u8{[_]u8{16} ** 64} ** 2,
            };
        }
        @memcpy(slot.aux[SCALING_OFF..][0..@sizeOf(ScalingList)], std.mem.asBytes(&sl));
    }
    const tile_words: [*]u16 = @ptrCast(@alignCast(slot.aux.ptr + TILES_OFF));
    tileSizes(tile_words[0 .. TILES_BYTES / 2], p);
    @memset(slot.pic[0..MAX_PIC_BYTES], 0);
    @memcpy(slot.pic[0..@sizeOf(HevcPic)], std.mem.asBytes(&s));
    if (st.blackwell.writesFields()) {
        std.mem.writeInt(u32, slot.pic[BLACKWELL_UNITS_AT..][0..4], codec.blkUnits(p.pic_width_in_luma_samples), .little);
        std.mem.writeInt(u16, slot.pic[BLACKWELL_FFFF_AT..][0..2], 0xffff, .little);
    }
    codec.padStream(slot.stream, st.stream);

    // The picture slots' planes: unused ones the scratch reference's (or
    // the target's), never address 0.
    var luma: [nvdec.SLOTS]u64 = undefined;
    var chroma: [nvdec.SLOTS]u64 = undefined;
    var fill = pic.target;
    if (scratch_slot) |ss| {
        if (lookup.surface(st.slot_surface[ss])) |r| fill = r;
    }
    for (0..nvdec.SLOTS) |i| {
        const r: codec.SurfaceRef = if (i == cur) pic.target else if (st.slot_surface[i] != NONE) (lookup.surface(st.slot_surface[i]) orelse fill) else fill;
        luma[i] = r.luma;
        chroma[i] = r.chroma;
        if (!nvdec.addressable(r.luma) or !nvdec.addressable(r.chroma)) return va.ERROR_INVALID_SURFACE;
    }

    const o = slot.push;
    var n: usize = 0;
    codec.bind(o, &n);
    codec.put(o, &n, nvdec.SET_APPLICATION_ID, APPLICATION_ID_HEVC);
    codec.put(o, &n, nvdec.SET_CONTROL_PARAMS, codec.controlFor(CODEC_TYPE_HEVC, st.control));
    codec.put(o, &n, nvdec.SET_PICTURE_INDEX, pic.picture_index);
    codec.put(o, &n, nvdec.SET_DRV_PIC_SETUP_OFFSET, nvdec.shifted(slot.pic_va));
    codec.put(o, &n, nvdec.SET_IN_BUF_BASE_OFFSET, nvdec.shifted(slot.stream_va));
    codec.put(o, &n, nvdec.SET_NVDEC_STATUS_OFFSET, nvdec.shifted(slot.status_va));
    codec.put(o, &n, nvdec.SET_COLOC_DATA_OFFSET, nvdec.shifted(scratch.va + L.coloc_off));
    codec.put(o, &n, HEVC_SET_FILTER_BUFFER_OFFSET, nvdec.shifted(scratch.va + L.filter_off));
    codec.put(o, &n, HEVC_SET_TILE_SIZES_OFFSET, nvdec.shifted(slot.aux_va + TILES_OFF));
    codec.put(o, &n, HEVC_SET_SCALING_LIST_OFFSET, nvdec.shifted(slot.aux_va + SCALING_OFF));
    codec.put(o, &n, SET_INTRA_TOP_BUF_OFFSET, nvdec.shifted(scratch.va + L.intra_top_off));
    if (st.blackwell.bindsBuffer()) codec.put(o, &n, codec.SET_BLK_BUF_OFFSET, nvdec.shifted(scratch.va + L.blk_off));
    codec.pictures(o, &n, luma, chroma);
    codec.execute(o, &n);
    std.debug.assert(n <= PUSH_DWORDS);
    out.* = .{ .dwords = n };
    return va.SUCCESS;
}

pub fn after(_: *State, _: codec.Scratch) void {}

fn sortBy(slots: []u8, pocs: []i32, comptime dir: enum { asc, desc }) void {
    // (15 at most: insertion sort)
    var i: usize = 1;
    while (i < slots.len) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const swap = if (dir == .asc) pocs[j] < pocs[j - 1] else pocs[j] > pocs[j - 1];
            if (!swap) break;
            std.mem.swap(i32, &pocs[j], &pocs[j - 1]);
            std.mem.swap(u8, &slots[j], &slots[j - 1]);
        }
    }
}

/// LtCurr in the slice header's order, where its order count (whole, or
/// low bits) names a reference; the rest after, in VA's order.
fn orderLongTerm(slots: []u8, pocs: []i32, h: *const Header, log2_lsb_minus4: u8) void {
    const mask: i64 = (@as(i64, 1) << @intCast(@as(u32, log2_lsb_minus4) + 4)) - 1;
    var placed: usize = 0;
    for (h.lt[0..h.lt_count]) |e| {
        if (!e.used) continue;
        for (placed..slots.len) |k| {
            const hit = if (e.poc) |v| pocs[k] == v else if (e.lsb) |l| (@as(i64, pocs[k]) & mask) == l else false;
            if (!hit) continue;
            std.mem.swap(u8, &slots[k], &slots[placed]);
            std.mem.swap(i32, &pocs[k], &pocs[placed]);
            placed += 1;
            break;
        }
    }
}

/// a, then b, then c, over and over to 16 entries.
fn fillList(out: *[16]u8, a: []const u8, b: []const u8, c: []const u8) void {
    var i: usize = 0;
    while (i < 16) {
        for ([_][]const u8{ a, b, c }) |set| {
            for (set) |v| {
                if (i == 16) return;
                out[i] = v;
                i += 1;
            }
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testParams() va.PictureParameterBufferHEVC {
    var p = std.mem.zeroes(va.PictureParameterBufferHEVC);
    p.CurrPic = .{ .picture_id = 3, .pic_order_cnt = 8, .flags = 0 };
    for (&p.ReferenceFrames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    p.pic_width_in_luma_samples = 1920;
    p.pic_height_in_luma_samples = 1080;
    p.pic_fields = .{ .chroma_format_idc = 1, .amp_enabled_flag = 1, .sign_data_hiding_enabled_flag = 1, .cu_qp_delta_enabled_flag = 1, .pps_loop_filter_across_slices_enabled_flag = 1 };
    p.log2_min_luma_coding_block_size_minus3 = 0;
    p.log2_diff_max_min_luma_coding_block_size = 3;
    p.log2_min_transform_block_size_minus2 = 0;
    p.log2_diff_max_min_transform_block_size = 3;
    p.max_transform_hierarchy_depth_inter = 2;
    p.max_transform_hierarchy_depth_intra = 1;
    p.init_qp_minus26 = -4;
    p.diff_cu_qp_delta_depth = 1;
    p.pps_cb_qp_offset = -2;
    p.log2_parallel_merge_level_minus2 = 0;
    p.slice_parsing_fields = .{ .sps_temporal_mvp_enabled_flag = 1, .sample_adaptive_offset_enabled_flag = 1 };
    p.log2_max_pic_order_cnt_lsb_minus4 = 4;
    p.num_short_term_ref_pic_sets = 3;
    p.num_ref_idx_l0_default_active_minus1 = 1;
    p.pps_beta_offset_div2 = -1;
    p.pps_tc_offset_div2 = 2;
    return p;
}

/// Bits to bytes, MSB first; `epb` puts 00 00 03 where the payload has
/// 00 00 0x (as an encoder must).
fn pack(comptime bits: []const u8, out: []u8) usize {
    var n: usize = 0;
    var cur: u8 = 0;
    var k: u4 = 0;
    for (bits) |c| {
        if (c == ' ') continue;
        cur = (cur << 1) | @as(u8, if (c == '1') 1 else 0);
        k += 1;
        if (k == 8) {
            out[n] = cur;
            n += 1;
            cur = 0;
            k = 0;
        }
    }
    if (k != 0) {
        out[n] = cur << @intCast(8 - @as(u4, k));
        n += 1;
    }
    return n;
}

test "hevc: nvdec_hevc_pic_s's words" {
    var s = HevcPic{};
    s.sps0 = .{ .chroma_format_idc = 1, .bit_depth_luma = 8, .bit_depth_chroma = 8, .log2_min_luma_coding_block_size = 3, .log2_max_luma_coding_block_size = 6 };
    s.pps1 = .{ .tiles_enabled_flag = 1, .num_tile_columns = 3, .num_tile_rows = 2, .log2_parallel_merge_level = 2 };
    s.longtermflag = 1 << 14;
    s.surface = .{ .tileformat = 1, .gob_height = 0 };
    const b = std.mem.asBytes(&s);
    try testing.expectEqual(@as(u32, 1 | (8 << 4) | (8 << 8) | (3 << 12) | (6 << 16)), std.mem.readInt(u32, b[0x5c..][0..4], .little));
    try testing.expectEqual(@as(u32, (1 << 4) | (3 << 6) | (2 << 11) | (2 << 22)), std.mem.readInt(u32, b[0x6c..][0..4], .little));
    try testing.expectEqual(@as(u16, 1 << 14), std.mem.readInt(u16, b[0x72..][0..2], .little));
    try testing.expectEqual(@as(u8, 1), b[0x40]);
}

test "hevc: the bit reader drops emulation prevention" {
    var b = Bits{ .data = &[_]u8{ 0x00, 0x00, 0x03, 0x01, 0xa0 } };
    try testing.expectEqual(@as(u32, 0), try b.u(16));
    try testing.expectEqual(@as(u32, 0x01), try b.u(8));
    try testing.expectEqual(@as(u32, 24), b.read);
    // 1 (ue 0), 01 0 (ue 1)
    try testing.expectEqual(@as(u32, 0), try b.ue());
    try testing.expectEqual(@as(u32, 1), try b.ue());
}

test "hevc: the skipped bits of an IDR's and a trailing picture's headers" {
    var p = testParams();
    var buf: [32]u8 = undefined;
    // IDR_W_RADL (19): first 1, no_output 0, pps id ue 0 (1), slice_type
    // ue 2 (011): nothing skipped (no output flag, no colour plane)
    var n = pack("1 0 1 011 0000000", buf[2..]);
    buf[0] = 19 << 1;
    buf[1] = 1;
    const h0 = try parseHeader(buf[0 .. 2 + n], &p);
    try testing.expectEqual(@as(u32, 0), h0.skip);
    // TRAIL_R (1): first 1, pps id ue 0, slice_type ue 1 (010), then the
    // skipped part: poc lsb (8 bits), st_ref_pic_set_sps_flag 1, its
    // index Ceil(Log2(3)) = 2 bits: 11 bits
    p.slice_parsing_fields.output_flag_present_flag = 1;
    n = pack("1 1 010 1 00000110 1 01 1 000000", buf[2..]);
    buf[0] = 1 << 1;
    const h1 = try parseHeader(buf[0 .. 2 + n], &p);
    try testing.expectEqual(@as(u32, 1 + 8 + 1 + 2), h1.skip);
    // the slice's own RPS: VA's st_rps_bits counted
    p.st_rps_bits = 7;
    n = pack("1 1 010 0 00000110 0 1010101 1 00000", buf[2..]);
    const h2 = try parseHeader(buf[0 .. 2 + n], &p);
    try testing.expectEqual(@as(u32, 1 + 8 + 1 + 7), h2.skip);
    // long-term: no SPS candidates, num_long_term_pics ue 1 (010),
    // poc_lsb_lt 8 bits = 2, used 1, msb present 1, cycle ue 0 (1)
    p.slice_parsing_fields.long_term_ref_pics_present_flag = 1;
    p.st_rps_bits = 0;
    n = pack("1 1 010 0 00000110 1 01 010 00000010 1 1 1 0000", buf[2..]);
    const h3 = try parseHeader(buf[0 .. 2 + n], &p);
    try testing.expectEqual(@as(u32, 1 + 8 + 1 + 2 + 3 + 8 + 1 + 1 + 1), h3.skip);
    try testing.expectEqual(@as(u8, 1), h3.lt_count);
    try testing.expectEqual(@as(?u32, 2), h3.lt[0].lsb);
    // POC 8 - 0 * 256 - 6 + 2
    try testing.expectEqual(@as(?i32, 4), h3.lt[0].poc);
}

test "hevc: tile sizes, uniform and not" {
    var p = testParams();
    var t: [TILES_BYTES / 2]u16 = undefined;
    tileSizes(&t, &p);
    // 1920x1080 in 64-sample CTBs: 30 x 17
    try testing.expectEqual(@as(u16, 30), t[0]);
    try testing.expectEqual(@as(u16, 17), t[1]);
    p.pic_fields.tiles_enabled_flag = 1;
    p.num_tile_columns_minus1 = 1;
    p.num_tile_rows_minus1 = 1;
    p.column_width_minus1[0] = 14;
    p.row_height_minus1[0] = 8;
    tileSizes(&t, &p);
    try testing.expectEqualSlices(u16, &.{ 15, 9, 15, 9, 15, 8, 15, 8 }, t[0..8]);
    // edges in 16-sample units (<< 2)
    try testing.expectEqualSlices(u16, &.{ 60, 120, 36, 68 }, t[TILE_EDGES_AT..][0..4]);
}

test "hevc: a P picture through take and end" {
    var st = State.init(1920, 1080);
    var fs = codec.FakeSlot{};
    const slot = fs.slot();
    var surf = codec.FakeSurfaces{ .w = 1920, .h = 1088, .n = 8 };
    var p = testParams();
    // refs: POC 4 (before), 6 (before), 12 (after), 0 long-term, 2 kept
    // for later (foll)
    p.ReferenceFrames[0] = .{ .picture_id = 5, .pic_order_cnt = 4, .flags = va.PICTURE_HEVC_RPS_ST_CURR_BEFORE };
    p.ReferenceFrames[1] = .{ .picture_id = 6, .pic_order_cnt = 12, .flags = va.PICTURE_HEVC_RPS_ST_CURR_AFTER };
    p.ReferenceFrames[2] = .{ .picture_id = 7, .pic_order_cnt = 6, .flags = va.PICTURE_HEVC_RPS_ST_CURR_BEFORE };
    p.ReferenceFrames[3] = .{ .picture_id = 8, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_RPS_LT_CURR | va.PICTURE_HEVC_LONG_TERM_REFERENCE };
    p.ReferenceFrames[4] = .{ .picture_id = 2, .pic_order_cnt = 2, .flags = 0 };
    var slice = std.mem.zeroes(va.SliceParameterBufferHEVC);
    var data: [64]u8 = undefined;
    data[0] = 1 << 1;
    data[1] = 1;
    const n = pack("1 1 010 00001000 1 01 0000000", data[2..]);
    slice.slice_data_size = @intCast(2 + n);
    slice.slice_data_offset = 0;
    begin(&st);
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(va.PictureParameterBufferHEVC), .count = 1, .data = std.mem.asBytes(&p) }, slot));
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(va.SliceParameterBufferHEVC), .count = 1, .data = std.mem.asBytes(&slice) }, slot));
    try testing.expectEqual(va.SUCCESS, take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = slice.slice_data_size, .count = 1, .data = data[0..slice.slice_data_size] }, slot));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 2, 1 }, slot.stream[0..6]);
    const L = Layout.of(1920, 1080);
    // (the scratch is only addressed, never read, by end)
    var big: [1]u8 = undefined;
    const scratch = codec.Scratch{ .cpu = @as([*]u8, @ptrCast(&big))[0..L.bytes], .va = 0x20_0000_0000 };
    var e: codec.End = undefined;
    const target = surf.lookup().surface(3).?;
    try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, .{ .target_id = 3, .target = target, .gob_height = 0, .picture_index = 9 }, surf.lookup(), &e));
    const s = std.mem.bytesToValue(HevcPic, slot.pic[0..@sizeOf(HevcPic)]);
    // slots: target 0, then the refs in VA's order 1..5
    try testing.expectEqual(@as(u8, 0), s.curr_pic_idx);
    try testing.expectEqual(@as(u32, @intCast(4 + 2 + n)), s.stream_len);
    try testing.expectEqual(@as(u16, 8 + 1 + 2), s.sw_hdr_skip_length);
    try testing.expectEqual(@as(u8, 4), s.num_ref_frames);
    // l0: before by descending POC (6: slot 3, 4: slot 1), after (12: 2),
    // long-term (0: slot 4), again
    try testing.expectEqualSlices(u8, &.{ 3, 1, 2, 4, 3, 1, 2, 4 }, s.initreflistidxl0[0..8]);
    try testing.expectEqualSlices(u8, &.{ 2, 3, 1, 4, 2, 3, 1, 4 }, s.initreflistidxl1[0..8]);
    try testing.expectEqual(@as(i16, 4), s.RefDiffPicOrderCnts[1]);
    try testing.expectEqual(@as(i16, -4), s.RefDiffPicOrderCnts[2]);
    try testing.expectEqual(@as(i16, 8), s.RefDiffPicOrderCnts[4]);
    try testing.expectEqual(@as(i16, 6), s.RefDiffPicOrderCnts[5]);
    // an unused slot carries the first current reference's difference
    try testing.expectEqual(@as(i16, 4), s.RefDiffPicOrderCnts[9]);
    try testing.expectEqual(@as(u16, 1 << 11), s.longtermflag);
    try testing.expectEqual(@as(u8, 2), s.pattern_id);
    try testing.expectEqual(@as(i8, -2), s.pps_beta_offset);
    try testing.expectEqual(@as(i8, 4), s.pps_tc_offset);
    try testing.expectEqual(@as(u7, 22), s.pps0.init_qp);
    try testing.expectEqual(@as(u4, 2), s.pps0.num_ref_idx_l0_default_active);
    try testing.expectEqual(@as(u32, @intCast(L.colmv >> 8)), s.colMvBuffersize);
    try testing.expectEqual(target.pitch_luma, s.framestride[0]);
    // the push: bound, HEVC, the buffers, slot 0 the target, slot 9 the
    // scratch reference (slot 1's surface 5), EXECUTE last
    const w = slot.push[0..e.dwords];
    try testing.expectEqual(@as(u32, nvdec.CLASS | nvdec.SET_OBJECT_ENGINE_SW), w[1]);
    try testing.expectEqual(APPLICATION_ID_HEVC, w[3]);
    try testing.expectEqual(@as(u32, 9), w[7]);
    try testing.expectEqual(nvdec.header(0, HEVC_SET_FILTER_BUFFER_OFFSET, 1), w[16]);
    try testing.expectEqual(nvdec.shifted(scratch.va + L.filter_off), w[17]);
    // (Blackwell's buffer after the intra-top one)
    try testing.expectEqual(nvdec.header(0, SET_INTRA_TOP_BUF_OFFSET, 1), w[22]);
    try testing.expectEqual(nvdec.header(0, codec.SET_BLK_BUF_OFFSET, 1), w[24]);
    try testing.expectEqual(nvdec.shifted(scratch.va + L.blk_off), w[25]);
    const luma0 = 27;
    try testing.expectEqual(nvdec.header(0, nvdec.SET_PICTURE_LUMA_OFFSET0, nvdec.SLOTS), w[luma0 - 1]);
    try testing.expectEqual(nvdec.shifted(target.luma), w[luma0]);
    try testing.expectEqual(nvdec.shifted(surf.lookup().surface(5).?.luma), w[luma0 + 9]);
    try testing.expectEqual(nvdec.header(0, nvdec.EXECUTE, 1), w[e.dwords - 2]);
    try testing.expectEqual(@as(usize, 64), e.dwords);
    // Blackwell's setup words: surface code 9 (8-bit), depth code 0, the
    // count for 1920 (16) at 0x11c, 0xffff at 0x120; v3's slice edge
    try testing.expectEqual(@as(u8, 9), s.reserved6);
    try testing.expectEqual(@as(u16, 0), s.reserved7);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, slot.pic[BLACKWELL_UNITS_AT..][0..4], .little));
    try testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, slot.pic[BLACKWELL_FFFF_AT..][0..2], .little));
    try testing.expectEqual(@as(u32, @intCast(L.sao_above_off >> 8)), s.v3[1]);
    try testing.expectEqual(@as(u32, 1 << 2), s.v3[0] & 0xc);
    // the stream padded with zeros
    try testing.expectEqual(@as(u8, 0), slot.stream[s.stream_len + 255]);
    try testing.expect(L.blk_off + codec.blkBytes(1920) <= L.bytes);
    // Ada's (off): no buffer, no words; the control word NVIDIA's
    st.blackwell = .off;
    st.control = .nvidia;
    begin(&st);
    _ = take(&st, .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(va.PictureParameterBufferHEVC), .count = 1, .data = std.mem.asBytes(&p) }, slot);
    _ = take(&st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(va.SliceParameterBufferHEVC), .count = 1, .data = std.mem.asBytes(&slice) }, slot);
    _ = take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = slice.slice_data_size, .count = 1, .data = data[0..slice.slice_data_size] }, slot);
    try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, .{ .target_id = 3, .target = target, .gob_height = 0, .picture_index = 9 }, surf.lookup(), &e));
    try testing.expectEqual(@as(usize, 62), e.dwords);
    try testing.expectEqual(@as(u32, 0x52057), slot.push[5]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, slot.pic[BLACKWELL_UNITS_AT..][0..4], .little));
    try testing.expectEqual(@as(u8, 0), slot.pic[0x71]);
    st.blackwell = .full;
    st.control = .nvk;
    // a second picture drops the slots of pictures no longer referenced
    p.ReferenceFrames[4] = .{ .picture_id = va.INVALID_ID, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    p.CurrPic.picture_id = 2;
    begin(&st);
    _ = take(&st, .{ .kind = va.PICTURE_PARAMETER_BUFFER, .size = @sizeOf(va.PictureParameterBufferHEVC), .count = 1, .data = std.mem.asBytes(&p) }, slot);
    _ = take(&st, .{ .kind = va.SLICE_PARAMETER_BUFFER, .size = @sizeOf(va.SliceParameterBufferHEVC), .count = 1, .data = std.mem.asBytes(&slice) }, slot);
    _ = take(&st, .{ .kind = va.SLICE_DATA_BUFFER, .size = slice.slice_data_size, .count = 1, .data = data[0..slice.slice_data_size] }, slot);
    try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, .{ .target_id = 2, .target = surf.lookup().surface(2).?, .gob_height = 0, .picture_index = 10 }, surf.lookup(), &e));
    // surface 3 (last target) is let go; surface 2 keeps slot 5
    try testing.expectEqual(NONE, st.slot_surface[0]);
    try testing.expectEqual(@as(u32, 2), st.slot_surface[5]);
}

test "hevc: Main10 into a P010 target (output mode 1, strides in 2-byte samples, 10-bit depths, QpBdOffset); not into NV12; 12-bit and mixed depths refused" {
    var st = State.init(64, 64);
    var fs = codec.FakeSlot{};
    const slot = fs.slot();
    var surf = codec.FakeSurfaces{ .w = 64, .h = 64, .n = 4 };
    var p = testParams();
    p.pic_width_in_luma_samples = 64;
    p.pic_height_in_luma_samples = 64;
    p.bit_depth_luma_minus8 = 2;
    p.bit_depth_chroma_minus8 = 2;
    st.pic = p;
    st.have_pic = true;
    st.have_header = true;
    st.slices = 1;
    var big: [1]u8 = undefined;
    const scratch = codec.Scratch{ .cpu = @as([*]u8, @ptrCast(&big))[0..st.layout.bytes], .va = 0x20_0000_0000 };
    var e: codec.End = undefined;
    // an NV12 target: not this stream's
    const nv12 = surf.lookup().surface(1).?;
    try testing.expectEqual(va.ERROR_INVALID_SURFACE, end(&st, slot, scratch, .{ .target_id = 1, .target = nv12, .gob_height = 0, .picture_index = 0 }, surf.lookup(), &e));
    // a P010 one: 128 bytes a row (64 samples of 2 bytes)
    var p010 = nv12;
    p010.sample_bytes = 2;
    p010.pitch_luma = 128;
    p010.pitch_chroma = 128;
    try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, .{ .target_id = 1, .target = p010, .gob_height = 0, .picture_index = 0 }, surf.lookup(), &e));
    const s = std.mem.bytesToValue(HevcPic, slot.pic[0..@sizeOf(HevcPic)]);
    try testing.expectEqual(@as(u8, 1), s.disp_output_mode);
    try testing.expectEqual([2]u32{ 64, 64 }, s.framestride);
    try testing.expectEqual(@as(u4, 10), s.sps0.bit_depth_luma);
    try testing.expectEqual(@as(u4, 10), s.sps0.bit_depth_chroma);
    // (init_qp_minus26 -4: 22, and 12 for the two bits past 8)
    try testing.expectEqual(@as(u7, 34), s.pps0.init_qp);
    try testing.expectEqual(@as(u8, 2), s.pattern_id);
    // Blackwell's codes for 10-bit 4:2:0: surface 2, depth 3
    try testing.expectEqual(@as(u8, 2), s.reserved6);
    try testing.expectEqual(@as(u16, 3), s.reserved7);
    // 12-bit, and luma and chroma of different depths
    st.pic.bit_depth_luma_minus8 = 4;
    st.pic.bit_depth_chroma_minus8 = 4;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, end(&st, slot, scratch, .{ .target_id = 1, .target = p010, .gob_height = 0, .picture_index = 0 }, surf.lookup(), &e));
    st.pic.bit_depth_luma_minus8 = 2;
    st.pic.bit_depth_chroma_minus8 = 0;
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, end(&st, slot, scratch, .{ .target_id = 1, .target = p010, .gob_height = 0, .picture_index = 0 }, surf.lookup(), &e));
}
