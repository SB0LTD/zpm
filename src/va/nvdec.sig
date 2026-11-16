//! @zpm/va nvdec — the RTX's video decoder as this driver programs it:
//! NVCFB0_VIDEO_DECODER (GB206's NVDEC, Blackwell), its methods, the
//! H.264 picture setup it reads (nvdec_h264_pic_s), the status it writes
//! (nvdec_status_s), the sizes of its scratch buffers, and one frame's
//! pushbuffer.
//!
//! NVIDIA's public material stops at Ada: the methods are NVC9B0's
//! (open-gpu-doc classes/video/clc9b0.h; NVC5B0's, which Mesa's NVK uses
//! on Turing and later, at the same offsets) and the setup structs are
//! nvdec_drv.h's. Blackwell's are assumed to be the same — THE RISK: if
//! GB206's firmware reads a longer or reordered nvdec_h264_pic_s, every
//! field past the first change is wrong, and the decoder errors or writes
//! garbage (the status word and GALAXY_VA_DEBUG say which).
//!
//! The order of methods, the scratch buffers' sizes, the watchdog, the
//! bitstream's layout (start codes, slice offsets plus the end, the
//! explicit end-of-stream) and the reference pictures' fields follow Mesa
//! NVK's H.264 decode (src/nouveau/vulkan/rust/video/decode/h264.rs, MIT),
//! which drives the same engine on GSP GPUs. What VA-API's buffers carry
//! maps to the fields as elFarto's nvidia-vaapi-driver (src/h264.c, MIT)
//! maps them to CUVID's, which carry the same information.
//!
//! Pure: no calls, no state; the driver (driver.sig) lays the results out
//! in GPU memory.

const std = @import("std");
const va = @import("vaapi.sig");

// ── The class and its methods (clc9b0.h) ───────────────────────────────────

/// NVCFB0_VIDEO_DECODER, bound on subchannel 0 at the start of each
/// pushbuffer (the kernel's video channel runs nothing else).
pub const CLASS: u32 = 0xcfb0;
/// SET_OBJECT's ENGINE field (cl906f.h, 20:16): NVK binds the decoder with
/// ENGINE_SW (0x1f); Galaxy's kernel probe binds it with 0. NVK's is taken.
pub const SET_OBJECT_ENGINE_SW: u32 = 0x1f << 16;

pub const SET_OBJECT: u32 = 0x000;
pub const NOP: u32 = 0x100;
pub const SET_APPLICATION_ID: u32 = 0x200;
pub const EXECUTE: u32 = 0x300;
pub const SET_CONTROL_PARAMS: u32 = 0x400;
pub const SET_DRV_PIC_SETUP_OFFSET: u32 = 0x404;
pub const SET_IN_BUF_BASE_OFFSET: u32 = 0x408;
pub const SET_PICTURE_INDEX: u32 = 0x40c;
pub const SET_SLICE_OFFSETS_BUF_OFFSET: u32 = 0x410;
pub const SET_COLOC_DATA_OFFSET: u32 = 0x414;
pub const SET_HISTORY_OFFSET: u32 = 0x418;
pub const SET_NVDEC_STATUS_OFFSET: u32 = 0x424;
pub const SET_PICTURE_LUMA_OFFSET0: u32 = 0x430;
pub const SET_PICTURE_CHROMA_OFFSET0: u32 = 0x474;
pub const H264_SET_MBHIST_BUF_OFFSET: u32 = 0x500;

pub const APPLICATION_ID_H264: u32 = 3;
pub const CODEC_TYPE_H264: u32 = 3;

/// The decoder's picture slots: SET_PICTURE_{LUMA,CHROMA}_OFFSET0..16, a
/// picture's index (CurrPicIdx, a DPB entry's index) and its co-located
/// motion slot (CurrColIdx, col_idx), which this driver keeps the same.
pub const SLOTS = 17;

/// A pushbuffer method header: incrementing, `count` dwords from `method`
/// on `subch` (galaxy nv_chan.sig's `header`, cla06f.h).
pub fn header(subch: u32, method: u32, count: u32) u32 {
    return (1 << 29) | (count << 16) | (subch << 13) | (method >> 2);
}

/// SET_CONTROL_PARAMS for an H.264 frame, as NVK sets it: the watchdog
/// (GPTIMER_ON; its timeout is the setup's gptimer_timeout_value), error
/// concealment, the macroblock timer, and ERROR_FRM_IDX (12:7).
pub fn controlParams(error_frm_idx: u32) u32 {
    return CODEC_TYPE_H264 | (1 << 4) | (1 << 6) | ((error_frm_idx & 0x3f) << 7) | (1 << 13);
}

// ── The structs (nvdec_drv.h) ───────────────────────────────────────────────

/// nvdec_dpb_entry_s: a reference picture.
pub const DpbEntry = extern struct {
    bits: packed struct(u32) {
        /// its picture slot
        index: u7 = 0,
        /// its co-located motion slot
        col_idx: u5 = 0,
        /// 1 top field, 2 bottom field, 3 both (a frame), 0 unused
        state: u2 = 0,
        is_long_term: u1 = 0,
        not_existing: u1 = 0,
        /// decoded as fields (an unpaired field or a complementary pair)
        is_field: u1 = 0,
        /// 1 short-term, 2 long-term reference, per field
        top_field_marking: u4 = 0,
        bottom_field_marking: u4 = 0,
        output_memory_layout: u1 = 0,
        reserved: u6 = 0,
    } = .{},
    FieldOrderCnt: [2]u32 = .{ 0, 0 },
    /// FrameNum (short-term), LongTermFrameIdx (long-term)
    FrameIdx: i32 = 0,
};

/// nvdec_h264_pic_s: one H.264 picture's setup (SET_DRV_PIC_SETUP_OFFSET).
pub const H264Pic = extern struct {
    /// nvdec_pass2_otf_s: encryption, off (52 bytes: its "0x10" comment is
    /// not its size)
    encryption: [13]u32 = [_]u32{0} ** 13,
    eos: [16]u8 = [_]u8{0} ** 16,
    explicitEOSPresentFlag: u8 = 0,
    hint_dump_en: u8 = 0,
    reserved0: [2]u8 = .{ 0, 0 },
    stream_len: u32 = 0,
    slice_count: u32 = 0,
    mbhist_buffer_size: u32 = 0,
    /// the watchdog's timeout in the engine's cycles (0: the ucode's
    /// default, 1 << 27)
    gptimer_timeout_value: u32 = 0,
    log2_max_pic_order_cnt_lsb_minus4: i32 = 0,
    delta_pic_order_always_zero_flag: i32 = 0,
    frame_mbs_only_flag: i32 = 0,
    PicWidthInMbs: i32 = 0,
    FrameHeightInMbs: i32 = 0,
    surface: packed struct(u32) {
        /// 0 TBL, 1 KBL (the GPU's block linear), 2 Tile16x16
        tileFormat: u2 = 0,
        /// blocks of 2 << gob_height GOBs (0: GOB_2)
        gob_height: u3 = 0,
        reserved: u27 = 0,
    } = .{},
    entropy_coding_mode_flag: i32 = 0,
    pic_order_present_flag: i32 = 0,
    num_ref_idx_l0_active_minus1: i32 = 0,
    num_ref_idx_l1_active_minus1: i32 = 0,
    deblocking_filter_control_present_flag: i32 = 0,
    redundant_pic_cnt_present_flag: i32 = 0,
    transform_8x8_mode_flag: i32 = 0,
    pitch_luma: u32 = 0,
    pitch_chroma: u32 = 0,
    luma_top_offset: u32 = 0,
    luma_bot_offset: u32 = 0,
    luma_frame_offset: u32 = 0,
    chroma_top_offset: u32 = 0,
    chroma_bot_offset: u32 = 0,
    chroma_frame_offset: u32 = 0,
    /// the history buffer's size in 256-byte units
    HistBufferSize: u32 = 0,
    flags: packed struct(u32) {
        MbaffFrameFlag: u1 = 0,
        direct_8x8_inference_flag: u1 = 0,
        weighted_pred_flag: u1 = 0,
        constrained_intra_pred_flag: u1 = 0,
        ref_pic_flag: u1 = 0,
        field_pic_flag: u1 = 0,
        bottom_field_flag: u1 = 0,
        second_field: u1 = 0,
        log2_max_frame_num_minus4: u4 = 0,
        chroma_format_idc: u2 = 0,
        pic_order_cnt_type: u2 = 0,
        pic_init_qp_minus26: i6 = 0,
        chroma_qp_index_offset: i5 = 0,
        second_chroma_qp_index_offset: i5 = 0,
    } = .{},
    current: packed struct(u32) {
        weighted_bipred_idc: u2 = 0,
        CurrPicIdx: u7 = 0,
        CurrColIdx: u5 = 0,
        frame_num: u16 = 0,
        frame_surfaces: u1 = 0,
        output_memory_layout: u1 = 0,
    } = .{},
    CurrFieldOrderCnt: [2]i32 = .{ 0, 0 },
    dpb: [16]DpbEntry = [_]DpbEntry{.{}} ** 16,
    /// raster scan order (not zig-zag)
    WeightScale: [6][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** 6,
    WeightScale8x8: [2][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** 2,
    num_inter_view_refs_lX: [2]u8 = .{ 0, 0 },
    reserved1: [14]u8 = [_]u8{0} ** 14,
    inter_view_refidx_lX: [2][16]i8 = [_][16]i8{[_]i8{0} ** 16} ** 2,
    lossless: packed struct(u32) {
        lossless_ipred8x8_filter_enable: u1 = 0,
        qpprime_y_zero_transform_bypass_flag: u1 = 0,
        reserved2: u30 = 0,
    } = .{},
    /// nvdec_display_param_s (0x1c bytes): no display output (NVK's)
    displayPara: [7]u32 = [_]u32{0} ** 7,
    /// nvdec_pass2_otf_ext_s (12 bytes)
    ssm: [3]u32 = .{ 0, 0, 0 },
};

/// nvdec_status_s: what the decoder reports of a frame
/// (SET_NVDEC_STATUS_OFFSET).
pub const Status = extern struct {
    mbs_correctly_decoded: u32,
    mbs_in_error: u32,
    cycle_count: u32,
    error_status: u32,
    /// the HEVC/VP9 union (nine words)
    codec: [9]u32,
    slice_header_error_code: u32,

    pub fn failed(s: Status) bool {
        return s.error_status != 0 or s.mbs_in_error != 0 or s.slice_header_error_code != 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(DpbEntry) == 16);
    std.debug.assert(@offsetOf(H264Pic, "eos") == 0x34);
    std.debug.assert(@offsetOf(H264Pic, "stream_len") == 0x48);
    std.debug.assert(@offsetOf(H264Pic, "gptimer_timeout_value") == 0x54);
    std.debug.assert(@offsetOf(H264Pic, "surface") == 0x6c);
    std.debug.assert(@offsetOf(H264Pic, "pitch_luma") == 0x8c);
    std.debug.assert(@offsetOf(H264Pic, "HistBufferSize") == 0xac);
    std.debug.assert(@offsetOf(H264Pic, "flags") == 0xb0);
    std.debug.assert(@offsetOf(H264Pic, "CurrFieldOrderCnt") == 0xb8);
    std.debug.assert(@offsetOf(H264Pic, "dpb") == 0xc0);
    std.debug.assert(@offsetOf(H264Pic, "WeightScale") == 0x1c0);
    std.debug.assert(@offsetOf(H264Pic, "WeightScale8x8") == 0x220);
    std.debug.assert(@offsetOf(H264Pic, "lossless") == 0x2d0);
    std.debug.assert(@offsetOf(H264Pic, "displayPara") == 0x2d4);
    std.debug.assert(@sizeOf(H264Pic) == 0x2fc);
    std.debug.assert(@sizeOf(Status) == 56);
}

// ── The scratch buffers ─────────────────────────────────────────────────────

/// NVK's explicit end of stream: two end-of-stream NAL units (type 11).
pub const EOS = [16]u8{ 0, 0, 1, 0x0b, 0, 0, 0, 0, 0, 0, 1, 0x0b, 0, 0, 0, 0 };

/// NVK's (and NVIDIA's driver's) watchdog: without a timeout the timer
/// never fires, and a wedged decode hangs the engine for good.
pub const GPTIMER_TIMEOUT: u32 = 81_000_000;

/// The most slices one picture may have: SET_SLICE_OFFSETS_BUF_OFFSET's
/// table holds each slice's offset and then the end (NVK's 256 entries).
pub const MAX_SLICES = 255;
pub const SLICE_TABLE_BYTES = (MAX_SLICES + 1) * 4;

pub const Sizes = struct {
    /// co-located motion data, for every picture slot
    coloc: u32,
    /// one row of macroblock history (H264_SET_MBHIST_BUF_OFFSET)
    mbhist: u32,
    /// SET_HISTORY_OFFSET's (HistBufferSize is it in 256-byte units)
    history: u32,
};

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

/// The scratch buffers for pictures `width_mbs` macroblocks wide and
/// `height_map_units` tall in map units (NVK's compute_opaque_buffer_sizes;
/// the co-located data for all SLOTS, where NVK sizes it by the stream's
/// reference count, since a slot here is any of the 17).
pub fn sizes(width_mbs: u32, height_map_units: u32) Sizes {
    const per_pic = alignUp(alignUp(height_map_units, 2) * width_mbs * 64 - 63, 0x100);
    return .{
        .coloc = per_pic * SLOTS,
        .mbhist = alignUp(width_mbs * 104, 0x100),
        .history = alignUp(width_mbs * 0x300, 0x200),
    };
}

// ── VA-API's H.264 picture as the decoder's setup ───────────────────────────

/// A reference picture's place: its slot (index and col_idx), and whether
/// it was decoded as fields.
pub const Ref = struct {
    slot: u5,
    is_field: bool,
};

/// The decode target's planes, as the decoder writes them (tiling.sig).
pub const Target = struct {
    pitch_luma: u32,
    pitch_chroma: u32,
    /// blocks of 2 << gob_height GOBs
    gob_height: u3,
};

/// What one picture's setup is made from: VA-API's picture parameters
/// (and scaling lists, flat when none came), its first slice's active
/// reference counts, the slices' count and bitstream bytes, the target,
/// the slots, the scratch sizes.
pub const Picture = struct {
    pic: *const va.PictureParameterBufferH264,
    iq: ?*const va.IQMatrixBufferH264 = null,
    num_ref_idx_l0_active_minus1: u8 = 0,
    num_ref_idx_l1_active_minus1: u8 = 0,
    slice_count: u32,
    /// the slices' bytes with their start codes (EOS not counted)
    stream_len: u32,
    target: Target,
    /// the target's slot
    slot: u5,
    /// the second field of a pair whose first is in the target already
    second_field: bool = false,
    /// VA's ReferenceFrames[i] resolved (null: none, or not a surface)
    refs: [16]?Ref = [_]?Ref{null} ** 16,
    sizes: Sizes,
};

fn orOther(v: i32, other: i32) i32 {
    // (NVK: a missing field's order count, INT_MAX, is the other one's)
    return if (v == std.math.maxInt(i32)) other else v;
}

/// The decoder's setup for `p` (NVK's decode(), field by field).
pub fn h264Setup(p: Picture) H264Pic {
    const pic = p.pic;
    const seq = pic.seq_fields;
    const pf = pic.pic_fields;
    var s = H264Pic{};
    s.explicitEOSPresentFlag = 1;
    s.eos = EOS;
    s.gptimer_timeout_value = GPTIMER_TIMEOUT;
    s.slice_count = p.slice_count;
    s.stream_len = p.stream_len + @as(u32, EOS.len);
    s.mbhist_buffer_size = p.sizes.mbhist;
    s.log2_max_pic_order_cnt_lsb_minus4 = seq.log2_max_pic_order_cnt_lsb_minus4;
    s.delta_pic_order_always_zero_flag = seq.delta_pic_order_always_zero_flag;
    s.frame_mbs_only_flag = seq.frame_mbs_only_flag;
    s.PicWidthInMbs = @as(i32, pic.picture_width_in_mbs_minus1) + 1;
    // (VA's height is the frame's, both fields: NVK's map units doubled)
    s.FrameHeightInMbs = @as(i32, pic.picture_height_in_mbs_minus1) + 1;
    s.surface = .{ .tileFormat = 1, .gob_height = p.target.gob_height };
    s.entropy_coding_mode_flag = pf.entropy_coding_mode_flag;
    s.pic_order_present_flag = pf.pic_order_present_flag;
    s.num_ref_idx_l0_active_minus1 = p.num_ref_idx_l0_active_minus1;
    s.num_ref_idx_l1_active_minus1 = p.num_ref_idx_l1_active_minus1;
    s.deblocking_filter_control_present_flag = pf.deblocking_filter_control_present_flag;
    s.redundant_pic_cnt_present_flag = pf.redundant_pic_cnt_present_flag;
    s.transform_8x8_mode_flag = pf.transform_8x8_mode_flag;
    s.pitch_luma = p.target.pitch_luma;
    s.pitch_chroma = p.target.pitch_chroma;
    // (NVK's field offsets: the bottom field one row on)
    s.luma_bot_offset = @as(u32, @intCast(s.PicWidthInMbs)) * 16;
    s.chroma_bot_offset = p.target.pitch_chroma / 2;
    s.HistBufferSize = p.sizes.history >> 8;
    const field = pf.field_pic_flag != 0;
    s.flags = .{
        .MbaffFrameFlag = @intFromBool(seq.mb_adaptive_frame_field_flag != 0 and !field),
        .direct_8x8_inference_flag = seq.direct_8x8_inference_flag,
        .weighted_pred_flag = pf.weighted_pred_flag,
        .constrained_intra_pred_flag = pf.constrained_intra_pred_flag,
        .ref_pic_flag = pf.reference_pic_flag,
        .field_pic_flag = pf.field_pic_flag,
        .bottom_field_flag = @intFromBool(pic.CurrPic.flags & va.PICTURE_H264_BOTTOM_FIELD != 0),
        .second_field = @intFromBool(p.second_field),
        .log2_max_frame_num_minus4 = seq.log2_max_frame_num_minus4,
        .chroma_format_idc = seq.chroma_format_idc,
        .pic_order_cnt_type = seq.pic_order_cnt_type,
        .pic_init_qp_minus26 = @truncate(pic.pic_init_qp_minus26),
        .chroma_qp_index_offset = @truncate(pic.chroma_qp_index_offset),
        .second_chroma_qp_index_offset = @truncate(pic.second_chroma_qp_index_offset),
    };
    s.current = .{
        .weighted_bipred_idc = pf.weighted_bipred_idc,
        .CurrPicIdx = p.slot,
        .CurrColIdx = p.slot,
        .frame_num = pic.frame_num,
    };
    const top = pic.CurrPic.TopFieldOrderCnt;
    const bottom = pic.CurrPic.BottomFieldOrderCnt;
    s.CurrFieldOrderCnt = .{ orOther(top, bottom), orOther(bottom, top) };
    for (pic.ReferenceFrames, p.refs, 0..) |rf, ref, i| {
        const r = ref orelse continue;
        if (rf.flags & va.PICTURE_H264_INVALID != 0) continue;
        // which fields it is a reference by (neither flag: the frame)
        var state: u2 = 0;
        if (rf.flags & va.PICTURE_H264_TOP_FIELD != 0) state |= 1;
        if (rf.flags & va.PICTURE_H264_BOTTOM_FIELD != 0) state |= 2;
        if (state == 0) state = 3;
        const long = rf.flags & va.PICTURE_H264_LONG_TERM_REFERENCE != 0;
        const marking: u4 = if (long) 2 else 1;
        s.dpb[i] = .{
            .bits = .{
                .index = r.slot,
                .col_idx = r.slot,
                .state = state,
                .is_long_term = @intFromBool(long),
                .is_field = @intFromBool(r.is_field),
                .top_field_marking = if (state & 1 != 0) marking else 0,
                .bottom_field_marking = if (state & 2 != 0) marking else 0,
            },
            .FieldOrderCnt = .{
                @bitCast(orOther(rf.TopFieldOrderCnt, rf.BottomFieldOrderCnt)),
                @bitCast(orOther(rf.BottomFieldOrderCnt, rf.TopFieldOrderCnt)),
            },
            .FrameIdx = @intCast(rf.frame_idx & 0xffff),
        };
    }
    if (p.iq) |iq| {
        s.WeightScale = iq.ScalingList4x4;
        s.WeightScale8x8 = iq.ScalingList8x8;
    } else {
        // (flat, NVK's)
        s.WeightScale = [_][16]u8{[_]u8{16} ** 16} ** 6;
        s.WeightScale8x8 = [_][64]u8{[_]u8{16} ** 64} ** 2;
    }
    return s;
}

// ── One frame's pushbuffer ──────────────────────────────────────────────────

/// Where one frame's inputs and outputs are (GPU addresses, 256-byte
/// aligned, below 1 << 40: the methods take them shifted right by 8).
pub const FrameAddrs = struct {
    pic_setup: u64,
    bitstream: u64,
    slice_offsets: u64,
    coloc: u64,
    history: u64,
    status: u64,
    mbhist: u64,
    /// each picture slot's planes (an unused slot: the target's, so a
    /// broken stream's reference reads the target, not address 0)
    luma: [SLOTS]u64,
    chroma: [SLOTS]u64,
    /// the decode's number (NVK's frame counter: SET_PICTURE_INDEX)
    picture_index: u32,
    /// SET_CONTROL_PARAMS' ERROR_FRM_IDX
    error_frm_idx: u32,
};

/// The dwords one frame takes.
pub const PUSH_DWORDS = 2 + 9 * 2 + 2 * (1 + SLOTS) + 2 + 2;

/// An address as the offset methods take it.
pub fn shifted(addr: u64) u32 {
    std.debug.assert(addr & 0xff == 0 and addr >> 40 == 0);
    return @truncate(addr >> 8);
}

/// Whether `addr` can be given to the decoder.
pub fn addressable(addr: u64) bool {
    return addr & 0xff == 0 and addr >> 40 == 0;
}

/// One H.264 frame's methods (NVK's order) into `out`: the decoder bound,
/// the application, the controls, the setup, the bitstream, the slices,
/// the scratch buffers, the status, the picture slots, then EXECUTE. Its
/// length (PUSH_DWORDS). The kernel's fence follows it on the channel.
pub fn h264Push(out: []u32, a: FrameAddrs) usize {
    var n: usize = 0;
    const one = struct {
        fn put(o: []u32, at: *usize, method: u32, value: u32) void {
            o[at.*] = header(0, method, 1);
            o[at.* + 1] = value;
            at.* += 2;
        }
    }.put;
    one(out, &n, SET_OBJECT, CLASS | SET_OBJECT_ENGINE_SW);
    one(out, &n, SET_APPLICATION_ID, APPLICATION_ID_H264);
    one(out, &n, SET_CONTROL_PARAMS, controlParams(a.error_frm_idx));
    one(out, &n, SET_DRV_PIC_SETUP_OFFSET, shifted(a.pic_setup));
    one(out, &n, SET_IN_BUF_BASE_OFFSET, shifted(a.bitstream));
    one(out, &n, SET_PICTURE_INDEX, a.picture_index);
    one(out, &n, SET_SLICE_OFFSETS_BUF_OFFSET, shifted(a.slice_offsets));
    one(out, &n, SET_COLOC_DATA_OFFSET, shifted(a.coloc));
    one(out, &n, SET_HISTORY_OFFSET, shifted(a.history));
    one(out, &n, SET_NVDEC_STATUS_OFFSET, shifted(a.status));
    out[n] = header(0, SET_PICTURE_LUMA_OFFSET0, SLOTS);
    n += 1;
    for (a.luma) |l| {
        out[n] = shifted(l);
        n += 1;
    }
    out[n] = header(0, SET_PICTURE_CHROMA_OFFSET0, SLOTS);
    n += 1;
    for (a.chroma) |c| {
        out[n] = shifted(c);
        n += 1;
    }
    one(out, &n, H264_SET_MBHIST_BUF_OFFSET, shifted(a.mbhist));
    // NOTIFY off, NOTIFY_ON end, AWAKEN off: the kernel's fence says done
    one(out, &n, EXECUTE, 0);
    std.debug.assert(n == PUSH_DWORDS);
    return n;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testPicture() va.PictureParameterBufferH264 {
    var p = std.mem.zeroes(va.PictureParameterBufferH264);
    p.CurrPic = .{ .picture_id = 7, .frame_idx = 3, .flags = 0, .TopFieldOrderCnt = 6, .BottomFieldOrderCnt = 6 };
    for (&p.ReferenceFrames) |*r| r.* = .{ .picture_id = va.INVALID_ID, .frame_idx = 0, .flags = va.PICTURE_H264_INVALID, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 0 };
    p.ReferenceFrames[0] = .{ .picture_id = 5, .frame_idx = 2, .flags = va.PICTURE_H264_SHORT_TERM_REFERENCE, .TopFieldOrderCnt = 4, .BottomFieldOrderCnt = std.math.maxInt(i32) };
    p.ReferenceFrames[1] = .{ .picture_id = 4, .frame_idx = 9, .flags = va.PICTURE_H264_LONG_TERM_REFERENCE | va.PICTURE_H264_BOTTOM_FIELD, .TopFieldOrderCnt = 0, .BottomFieldOrderCnt = 1 };
    p.picture_width_in_mbs_minus1 = 119; // 1920
    p.picture_height_in_mbs_minus1 = 67; // 1088
    p.num_ref_frames = 4;
    p.seq_fields = .{ .chroma_format_idc = 1, .frame_mbs_only_flag = 1, .direct_8x8_inference_flag = 1, .log2_max_frame_num_minus4 = 5, .pic_order_cnt_type = 0, .log2_max_pic_order_cnt_lsb_minus4 = 2, .mb_adaptive_frame_field_flag = 1 };
    p.pic_init_qp_minus26 = -3;
    p.chroma_qp_index_offset = -2;
    p.second_chroma_qp_index_offset = 4;
    p.pic_fields = .{ .entropy_coding_mode_flag = 1, .weighted_pred_flag = 1, .weighted_bipred_idc = 2, .transform_8x8_mode_flag = 1, .deblocking_filter_control_present_flag = 1, .reference_pic_flag = 1 };
    p.frame_num = 3;
    return p;
}

test "nvdec: a hand-made VA picture as nvdec_h264_pic_s" {
    const p = testPicture();
    var iq = std.mem.zeroes(va.IQMatrixBufferH264);
    iq.ScalingList4x4[2][5] = 21;
    iq.ScalingList8x8[1][63] = 33;
    var refs = [_]?Ref{null} ** 16;
    refs[0] = .{ .slot = 2, .is_field = false };
    refs[1] = .{ .slot = 9, .is_field = true };
    const sz = sizes(120, 68);
    const s = h264Setup(.{
        .pic = &p,
        .iq = &iq,
        .num_ref_idx_l0_active_minus1 = 2,
        .num_ref_idx_l1_active_minus1 = 1,
        .slice_count = 4,
        .stream_len = 1000,
        .target = .{ .pitch_luma = 1920, .pitch_chroma = 1920, .gob_height = 0 },
        .slot = 5,
        .refs = refs,
        .sizes = sz,
    });
    try testing.expectEqual(@as(u8, 1), s.explicitEOSPresentFlag);
    try testing.expectEqualSlices(u8, &EOS, &s.eos);
    try testing.expectEqual(GPTIMER_TIMEOUT, s.gptimer_timeout_value);
    try testing.expectEqual(@as(u32, 1016), s.stream_len);
    try testing.expectEqual(@as(u32, 4), s.slice_count);
    try testing.expectEqual(@as(u32, 12544), s.mbhist_buffer_size); // align(120*104, 256)
    try testing.expectEqual(@as(u32, 92160 >> 8), s.HistBufferSize); // align(120*0x300, 512)
    try testing.expectEqual(@as(i32, 2), s.log2_max_pic_order_cnt_lsb_minus4);
    try testing.expectEqual(@as(i32, 1), s.frame_mbs_only_flag);
    try testing.expectEqual(@as(i32, 120), s.PicWidthInMbs);
    try testing.expectEqual(@as(i32, 68), s.FrameHeightInMbs);
    try testing.expectEqual(@as(u2, 1), s.surface.tileFormat);
    try testing.expectEqual(@as(u3, 0), s.surface.gob_height);
    try testing.expectEqual(@as(i32, 1), s.entropy_coding_mode_flag);
    try testing.expectEqual(@as(i32, 2), s.num_ref_idx_l0_active_minus1);
    try testing.expectEqual(@as(i32, 1), s.num_ref_idx_l1_active_minus1);
    try testing.expectEqual(@as(i32, 1), s.deblocking_filter_control_present_flag);
    try testing.expectEqual(@as(i32, 1), s.transform_8x8_mode_flag);
    try testing.expectEqual(@as(u32, 1920), s.pitch_luma);
    try testing.expectEqual(@as(u32, 1920), s.luma_bot_offset);
    try testing.expectEqual(@as(u32, 960), s.chroma_bot_offset);
    // (MBAFF only for a frame picture of an MBAFF sequence: this one)
    try testing.expectEqual(@as(u1, 1), s.flags.MbaffFrameFlag);
    try testing.expectEqual(@as(u1, 1), s.flags.direct_8x8_inference_flag);
    try testing.expectEqual(@as(u1, 1), s.flags.weighted_pred_flag);
    try testing.expectEqual(@as(u1, 1), s.flags.ref_pic_flag);
    try testing.expectEqual(@as(u1, 0), s.flags.field_pic_flag);
    try testing.expectEqual(@as(u4, 5), s.flags.log2_max_frame_num_minus4);
    try testing.expectEqual(@as(u2, 1), s.flags.chroma_format_idc);
    try testing.expectEqual(@as(i6, -3), s.flags.pic_init_qp_minus26);
    try testing.expectEqual(@as(i5, -2), s.flags.chroma_qp_index_offset);
    try testing.expectEqual(@as(i5, 4), s.flags.second_chroma_qp_index_offset);
    try testing.expectEqual(@as(u2, 2), s.current.weighted_bipred_idc);
    try testing.expectEqual(@as(u7, 5), s.current.CurrPicIdx);
    try testing.expectEqual(@as(u5, 5), s.current.CurrColIdx);
    try testing.expectEqual(@as(u16, 3), s.current.frame_num);
    try testing.expectEqual([2]i32{ 6, 6 }, s.CurrFieldOrderCnt);
    // the short-term frame: both fields marked 1; its missing bottom
    // order count is its top's
    try testing.expectEqual(@as(u7, 2), s.dpb[0].bits.index);
    try testing.expectEqual(@as(u5, 2), s.dpb[0].bits.col_idx);
    try testing.expectEqual(@as(u2, 3), s.dpb[0].bits.state);
    try testing.expectEqual(@as(u4, 1), s.dpb[0].bits.top_field_marking);
    try testing.expectEqual(@as(u4, 1), s.dpb[0].bits.bottom_field_marking);
    try testing.expectEqual([2]u32{ 4, 4 }, s.dpb[0].FieldOrderCnt);
    try testing.expectEqual(@as(i32, 2), s.dpb[0].FrameIdx);
    // the long-term bottom field
    try testing.expectEqual(@as(u7, 9), s.dpb[1].bits.index);
    try testing.expectEqual(@as(u2, 2), s.dpb[1].bits.state);
    try testing.expectEqual(@as(u1, 1), s.dpb[1].bits.is_long_term);
    try testing.expectEqual(@as(u1, 1), s.dpb[1].bits.is_field);
    try testing.expectEqual(@as(u4, 0), s.dpb[1].bits.top_field_marking);
    try testing.expectEqual(@as(u4, 2), s.dpb[1].bits.bottom_field_marking);
    try testing.expectEqual(@as(i32, 9), s.dpb[1].FrameIdx);
    // the rest unused
    try testing.expectEqual(@as(u2, 0), s.dpb[2].bits.state);
    try testing.expectEqual(@as(u8, 21), s.WeightScale[2][5]);
    try testing.expectEqual(@as(u8, 33), s.WeightScale8x8[1][63]);
    // the words as the decoder reads them
    const bytes = std.mem.asBytes(&s);
    try testing.expectEqual(@as(u32, 1016), std.mem.readInt(u32, bytes[0x48..][0..4], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[0x6c..][0..4], .little));
    const flags = std.mem.readInt(u32, bytes[0xb0..][0..4], .little);
    // MBAFF|direct8x8|wp|ref (bits 0,1,2,4), log2 frame num 5 (8..11),
    // chroma 1 (12), qp -3 (16..21), -2 (22..26), 4 (27..31)
    try testing.expectEqual(@as(u32, 0x17 | (5 << 8) | (1 << 12) | (0x3d << 16) | (0x1e << 22) | (4 << 27)), flags);
    const cur = std.mem.readInt(u32, bytes[0xb4..][0..4], .little);
    try testing.expectEqual(@as(u32, 2 | (5 << 2) | (5 << 9) | (3 << 14)), cur);
    const dpb1 = std.mem.readInt(u32, bytes[0xc0 + 16 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 9 | (9 << 7) | (2 << 12) | (1 << 14) | (1 << 16) | (2 << 21)), dpb1);
}

test "nvdec: a field picture, no scaling lists" {
    var p = testPicture();
    p.pic_fields.field_pic_flag = 1;
    p.CurrPic.flags = va.PICTURE_H264_BOTTOM_FIELD;
    p.CurrPic.TopFieldOrderCnt = std.math.maxInt(i32);
    p.CurrPic.BottomFieldOrderCnt = 7;
    const s = h264Setup(.{ .pic = &p, .slice_count = 1, .stream_len = 10, .target = .{ .pitch_luma = 64, .pitch_chroma = 64, .gob_height = 0 }, .slot = 0, .second_field = true, .sizes = sizes(4, 4) });
    try testing.expectEqual(@as(u1, 0), s.flags.MbaffFrameFlag);
    try testing.expectEqual(@as(u1, 1), s.flags.field_pic_flag);
    try testing.expectEqual(@as(u1, 1), s.flags.bottom_field_flag);
    try testing.expectEqual(@as(u1, 1), s.flags.second_field);
    try testing.expectEqual([2]i32{ 7, 7 }, s.CurrFieldOrderCnt);
    try testing.expectEqual(@as(u8, 16), s.WeightScale[5][15]);
    try testing.expectEqual(@as(u8, 16), s.WeightScale8x8[0][0]);
    // (no reference resolved: none in the DPB)
    try testing.expectEqual(@as(u2, 0), s.dpb[0].bits.state);
}

test "nvdec: the scratch sizes (NVK's formulas)" {
    const s = sizes(120, 68);
    // align(68*120*64 - 63, 256) per picture, for 17 slots
    try testing.expectEqual(@as(u32, 522240 * SLOTS), s.coloc);
    try testing.expectEqual(@as(u32, 12544), s.mbhist);
    try testing.expectEqual(@as(u32, 92160), s.history);
    // (odd map units round up to a pair)
    try testing.expectEqual(sizes(3, 6).coloc, sizes(3, 5).coloc);
}

test "nvdec: one frame's pushbuffer, word by word" {
    var a = FrameAddrs{
        .pic_setup = 0x1_0000_0100,
        .bitstream = 0x1_0000_2000,
        .slice_offsets = 0x1_0000_0400,
        .coloc = 0x2_0000_0000,
        .history = 0x2_0010_0000,
        .status = 0x1_0000_0800,
        .mbhist = 0x2_0020_0000,
        .luma = undefined,
        .chroma = undefined,
        .picture_index = 41,
        .error_frm_idx = 41 % 4,
    };
    for (&a.luma, &a.chroma, 0..) |*l, *c, i| {
        l.* = 0x30_0000_0000 + i * 0x40_0000;
        c.* = l.* + 0x20_0000;
    }
    var out: [PUSH_DWORDS + 4]u32 = undefined;
    const n = h264Push(&out, a);
    try testing.expectEqual(@as(usize, 60), n);
    const want_head = [_]u32{
        0x2001_0000, 0x001f_cfb0, // SET_OBJECT
        0x2001_0080, 3, // SET_APPLICATION_ID H264
        0x2001_0100, 3 | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 13), // SET_CONTROL_PARAMS
        0x2001_0101, 0x100_0001, // SET_DRV_PIC_SETUP_OFFSET
        0x2001_0102, 0x100_0020, // SET_IN_BUF_BASE_OFFSET
        0x2001_0103, 41, // SET_PICTURE_INDEX
        0x2001_0104, 0x100_0004, // SET_SLICE_OFFSETS_BUF_OFFSET
        0x2001_0105, 0x200_0000, // SET_COLOC_DATA_OFFSET
        0x2001_0106, 0x200_1000, // SET_HISTORY_OFFSET
        0x2001_0109, 0x100_0008, // SET_NVDEC_STATUS_OFFSET
        0x2011_010c, // SET_PICTURE_LUMA_OFFSET0, 17
    };
    try testing.expectEqualSlices(u32, &want_head, out[0..want_head.len]);
    try testing.expectEqual(@as(u32, 0x3000_0000), out[21]);
    try testing.expectEqual(@as(u32, 0x3000_0000 + 16 * 0x4000), out[37]);
    try testing.expectEqual(@as(u32, 0x2011_011d), out[38]); // SET_PICTURE_CHROMA_OFFSET0, 17
    try testing.expectEqual(@as(u32, 0x3000_2000), out[39]);
    try testing.expectEqual(@as(u32, 0x2001_0140), out[56]); // H264_SET_MBHIST_BUF_OFFSET
    try testing.expectEqual(@as(u32, 0x200_2000), out[57]);
    try testing.expectEqual(@as(u32, 0x2001_00c0), out[58]); // EXECUTE
    try testing.expectEqual(@as(u32, 0), out[59]);
}
