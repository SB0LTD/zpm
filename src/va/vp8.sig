//! @zpm/va vp8 — VP8 (bitstream versions 0 to 3, 8-bit 4:2:0) on the RTX's
//! video decoder (NVCFB0, GB206), as a codec module (codec.sig): VA-API's
//! VP8 buffers in, nvdec_vp8_pic_s, the decoder's probability table and one
//! frame's pushbuffer out.
//!
//! The decoder parses VP8 itself: the bitstream it gets is the frame after
//! its uncompressed data chunk (the 3-byte frame tag, and on key frames the
//! start code and the size), that is the first partition (frame header and
//! modes), the DCT partitions' size table and the DCT partitions, exactly as
//! VA-API's slice data carries it. The setup only says where the first
//! partition ends (firstPartSize), whether this is a key frame, the version,
//! the size and the planes. VA-API's slice parameters do not give the first
//! partition's size directly: it is ceil(macroblock_offset / 8) +
//! partition_size[0] (libva's comment and every client: FFmpeg, GStreamer),
//! and is checked here against the DCT partition sizes the bitstream's own
//! table holds.
//!
//! The probability table (VP8_SET_PROB_DATA_OFFSET) is written each frame
//! from what VA-API gives: the coefficient probabilities (the probability
//! buffer), the intra mode and motion vector probabilities (the picture
//! parameters), all after the frame header's updates. Every VP8 update is a
//! replacement, never a delta, so whether the decoder re-reads the frame's
//! updates on top of these or not, it decodes with the same values; and as
//! each frame gets a fresh table, nothing it writes back carries over. On key
//! frames the intra mode slots take VP8's inter-frame defaults (a key frame
//! resets them; its own modes use fixed probabilities), whatever the client
//! sent there (FFmpeg sends the key-frame ones).
//!
//! NVIDIA's public material stops at Ada: the VP8 methods are NVC9B0's
//! (clc9b0.h: VP8_SET_PROB_DATA_OFFSET 0x540, application id and codec type
//! 5) and the setup is nvdec_drv.h's nvdec_vp8_pic_s (0xc0 bytes), its
//! offsets measured with gcc and asserted below. Blackwell's nvdec_vp8_pic_s
//! is assumed to be Ada's public one — THE RISK, as for H.264, HEVC and VP9:
//! if GB206's firmware reads a longer or reordered struct, every field past
//! the change is wrong, and the decoder's status says so (GALAXY_VA_DEBUG).
//! Further unverified on hardware:
//! - the probability table's layout beyond its first 0x4b0 bytes (the rest,
//!   to 0x4cc, is zeroed as the Tegra decoder zeroes it; the buffer is
//!   0x4b00 bytes, the room the Tegra decoder gives it);
//! - FrameStride in 16-byte units, FrameWidth/FrameHeight rounded up to
//!   whole macroblocks, segmentation_feature_data_update repeated in the
//!   byte after it: the Tegra decoder's choices, which work there;
//! - VP8_SET_HEADER_PARTITION_BUF_BASE_OFFSET (0x544) is never set (the
//!   first partition stays in the bitstream, as on Tegra);
//! - the intra mode slots' use on key frames (see above).
//!
//! What was taken from averne's Tegra NVDEC VP8 hwaccel for FFmpeg (facts
//! only, no code): which buffers there are and their sizes (the probability
//! table, a history buffer of 0x200 bytes per macroblock column), the
//! probability table's layout (coefficients [4][8][3] of 11 in 12 bytes,
//! then 4 luma mode, 3 chroma mode in 4, two motion vector sets of 19 in 20),
//! that the bitstream starts after the uncompressed chunk, the picture slots
//! (0 golden, 1 altref, 2 last, 3 current; a missing reference is the
//! current frame) and the setup fields it fills.
//!
//! Allocator-free: the state is fixed-size.

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const codec = @import("codec.sig");
const vav = @import("vaapi_vp8.sig");

/// VAProfileVP8Version0_3.
pub const PROFILE: va.Profile = vav.PROFILE_VP8_VERSION0_3;

// ── The class's VP8 methods (clc9b0.h) ──────────────────────────────────────

pub const APPLICATION_ID_VP8: u32 = 5;
pub const CODEC_TYPE_VP8: u32 = 5;

pub const VP8_SET_PROB_DATA_OFFSET: u32 = 0x540;
/// (not used: the first partition stays in the bitstream)
pub const VP8_SET_HEADER_PARTITION_BUF_BASE_OFFSET: u32 = 0x544;

// ── The decoder's structs (nvdec_drv.h) ─────────────────────────────────────

/// The picture slots the decoder reads VP8's frames from.
pub const SLOT_GOLDEN = 0;
pub const SLOT_ALTREF = 1;
pub const SLOT_LAST = 2;
pub const SLOT_CURRENT = 3;

/// nvdec_vp8_pic_s: one VP8 frame's setup (SET_DRV_PIC_SETUP_OFFSET).
pub const Vp8Pic = extern struct {
    /// nvdec_pass2_otf_s: encryption off
    wrapped_session_key: [4]u32 = .{ 0, 0, 0, 0 },
    wrapped_content_key: [4]u32 = .{ 0, 0, 0, 0 },
    initialization_vector: [4]u32 = .{ 0, 0, 0, 0 },
    /// enable_encryption:1, key_increment:6, encryption_mode:4,
    /// key_slot_index:4, ssm_en:1
    encryption: u32 = 0,
    gptimer_timeout_value: u32 = 0,
    /// in whole macroblocks
    FrameWidth: u16 = 0,
    FrameHeight: u16 = 0,
    keyFrame: u8 = 0,
    version: u8 = 0,
    surface: packed struct(u8) {
        /// 0 TBL, 1 KBL (block linear), 2 Tile16x16
        tileFormat: u2 = 0,
        gob_height: u3 = 0,
        reserved: u3 = 0,
    } = .{},
    errorConcealOn: u8 = 0,
    /// the first partition's bytes (frame header and modes)
    firstPartSize: u32 = 0,
    /// the history buffer's, 256-byte units
    HistBufferSize: u32 = 0,
    /// the bitstream's bytes
    VLDBufferSize: u32 = 0,
    /// luma and chroma pitches, 16-byte units
    FrameStride: [2]u32 = .{ 0, 0 },
    /// planes' offsets (256-byte units): 0, the slots give the planes
    luma_top_offset: u32 = 0,
    luma_bot_offset: u32 = 0,
    luma_frame_offset: u32 = 0,
    chroma_top_offset: u32 = 0,
    chroma_bot_offset: u32 = 0,
    chroma_frame_offset: u32 = 0,
    /// nvdec_display_param_s: no display output
    displayPara: [7]u32 = [_]u32{0} ** 7,
    /// 0 NV12
    current_output_memory_layout: u8 = 0,
    /// golden, altref, last: NV12
    output_memory_layout: [3]u8 = .{ 0, 0, 0 },
    segmentation_feature_data_update: u8 = 0,
    reserved1: [3]u8 = .{ 0, 0, 0 },
    /// written by the decoder (the header's buffer copies and so on)
    resultValue: u32 = 0,
    /// each DCT partition's offset: encrypted streams only
    partition_offset: [8]u32 = [_]u32{0} ** 8,
    /// nvdec_pass2_otf_ext_s
    ssm: [3]u32 = .{ 0, 0, 0 },
};

/// The probability table (VP8_SET_PROB_DATA_OFFSET), each row padded.
pub const Probs = extern struct {
    /// block type, band, context: 11 node probabilities in 12 bytes
    coef: [4][8][3][12]u8,
    /// the inter-frame intra modes: luma 4, chroma 3 in 4
    ymode: [4]u8,
    uvmode: [4]u8,
    /// row, column: 19 in 20
    mv: [2][20]u8,
    /// (zeroed, as the Tegra decoder leaves it)
    tail: [0x1c]u8,
};

comptime {
    std.debug.assert(@offsetOf(Vp8Pic, "encryption") == 0x30);
    std.debug.assert(@offsetOf(Vp8Pic, "gptimer_timeout_value") == 0x34);
    std.debug.assert(@offsetOf(Vp8Pic, "FrameWidth") == 0x38);
    std.debug.assert(@offsetOf(Vp8Pic, "keyFrame") == 0x3c);
    std.debug.assert(@offsetOf(Vp8Pic, "version") == 0x3d);
    std.debug.assert(@offsetOf(Vp8Pic, "surface") == 0x3e);
    std.debug.assert(@offsetOf(Vp8Pic, "errorConcealOn") == 0x3f);
    std.debug.assert(@offsetOf(Vp8Pic, "firstPartSize") == 0x40);
    std.debug.assert(@offsetOf(Vp8Pic, "HistBufferSize") == 0x44);
    std.debug.assert(@offsetOf(Vp8Pic, "VLDBufferSize") == 0x48);
    std.debug.assert(@offsetOf(Vp8Pic, "FrameStride") == 0x4c);
    std.debug.assert(@offsetOf(Vp8Pic, "luma_top_offset") == 0x54);
    std.debug.assert(@offsetOf(Vp8Pic, "chroma_frame_offset") == 0x68);
    std.debug.assert(@offsetOf(Vp8Pic, "displayPara") == 0x6c);
    std.debug.assert(@offsetOf(Vp8Pic, "current_output_memory_layout") == 0x88);
    std.debug.assert(@offsetOf(Vp8Pic, "output_memory_layout") == 0x89);
    std.debug.assert(@offsetOf(Vp8Pic, "segmentation_feature_data_update") == 0x8c);
    std.debug.assert(@offsetOf(Vp8Pic, "reserved1") == 0x8d);
    std.debug.assert(@offsetOf(Vp8Pic, "resultValue") == 0x90);
    std.debug.assert(@offsetOf(Vp8Pic, "partition_offset") == 0x94);
    std.debug.assert(@offsetOf(Vp8Pic, "ssm") == 0xb4);
    std.debug.assert(@sizeOf(Vp8Pic) == 0xc0);
    std.debug.assert(@offsetOf(Probs, "ymode") == 0x480);
    std.debug.assert(@offsetOf(Probs, "uvmode") == 0x484);
    std.debug.assert(@offsetOf(Probs, "mv") == 0x488);
    std.debug.assert(@offsetOf(Probs, "tail") == 0x4b0);
    std.debug.assert(@sizeOf(Probs) == 0x4cc);
}

// ── Buffers ─────────────────────────────────────────────────────────────────

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) / a * a;
}

/// The setup's room in a frame slot.
pub const MAX_PIC_BYTES: usize = @sizeOf(Vp8Pic);
/// The frame slot's side buffer: the probability table, in the room the
/// Tegra decoder gives it.
pub const PROB_BYTES: usize = 0x4b00;
pub const MAX_AUX_BYTES: usize = PROB_BYTES;

/// The history buffer's bytes per macroblock column.
const HISTORY_PER_MB_COLUMN: usize = 0x200;

/// The dwords one frame's pushbuffer takes.
pub const PUSH_DWORDS: usize = 9 * 2 + 2 * (1 + nvdec.SLOTS) + 2;

comptime {
    std.debug.assert(MAX_PIC_BYTES <= codec.PIC_BYTES);
    std.debug.assert(MAX_AUX_BYTES <= codec.AUX_BYTES);
}

/// The context-wide buffer (scratch): the history, for pictures up to
/// `width` wide.
pub fn historyBytes(width: u32) usize {
    return alignUp((alignUp(width, 16) / 16) * HISTORY_PER_MB_COLUMN, 0x100);
}

pub fn scratchBytes(width: u32, height: u32) usize {
    _ = height;
    return historyBytes(width);
}

/// VP8's default inter-frame intra mode probabilities (RFC 6386 11.4), what
/// a key frame resets them to.
pub const DEFAULT_YMODE = [4]u8{ 112, 86, 140, 37 };
pub const DEFAULT_UVMODE = [3]u8{ 162, 101, 204 };

// ── The partitions ──────────────────────────────────────────────────────────

/// Where the frame's partitions are in its bitstream (from the first
/// partition's start).
pub const Partitions = struct {
    /// the first partition's bytes
    first: u32,
    /// DCT partitions: 1, 2, 4 or 8
    count: u8,
    at: [8]u32,
    size: [8]u32,
    /// the bytes all of them take
    end: u32,
};

pub const Error = error{ Corrupt, Short };

/// The partitions of `data` (a frame from its first partition on) as VA's
/// slice parameters give them, checked against the size table the
/// bitstream holds after the first partition.
pub fn partitions(data: []const u8, s: *const vav.SliceParameterBufferVP8) Error!Partitions {
    const n = s.num_of_partitions;
    if (n != 2 and n != 3 and n != 5 and n != 9) return error.Corrupt;
    const dct: u8 = n - 1;
    const first: u64 = (@as(u64, s.macroblock_offset) + 7) / 8 + s.partition_size[0];
    if (first == 0) return error.Corrupt;
    const table: u64 = 3 * @as(u64, dct - 1);
    if (first + table > data.len) return error.Short;
    var p = Partitions{ .first = @intCast(first), .count = dct, .at = [_]u32{0} ** 8, .size = [_]u32{0} ** 8, .end = 0 };
    var at: u64 = first + table;
    for (0..dct) |k| {
        const size = s.partition_size[k + 1];
        if (k + 1 < dct) {
            // (the last partition's size is not in the table: the rest)
            const t = data[@intCast(first + 3 * k)..][0..3];
            const told = @as(u32, t[0]) | (@as(u32, t[1]) << 8) | (@as(u32, t[2]) << 16);
            if (told != size) return error.Corrupt;
        }
        p.at[k] = @intCast(at);
        p.size[k] = size;
        at += size;
        if (at > data.len) return error.Short;
    }
    p.end = @intCast(at);
    return p;
}

// ── The module ──────────────────────────────────────────────────────────────

pub const State = struct {
    /// the context's largest picture (the scratch's size)
    width: u32,
    height: u32,
    pic: vav.PictureParameterBufferVP8 = undefined,
    have_pic: bool = false,
    coef: [4][8][3][11]u8 = undefined,
    have_probs: bool = false,
    slice: vav.SliceParameterBufferVP8 = undefined,
    have_slice: bool = false,
    /// the slice data taken: the bitstream in the stream, its partitions
    have_frame: bool = false,
    parts: Partitions = undefined,
    stream_len: u32 = 0,

    pub fn init(width: u32, height: u32) State {
        return .{ .width = width, .height = height };
    }
};

pub fn begin(st: *State) void {
    st.have_pic = false;
    st.have_probs = false;
    st.have_slice = false;
    st.have_frame = false;
    st.stream_len = 0;
}

pub fn take(st: *State, b: codec.Buffer, slot: codec.Slot) va.Status {
    switch (b.kind) {
        va.PICTURE_PARAMETER_BUFFER => {
            if (b.size < @sizeOf(vav.PictureParameterBufferVP8) or b.count < 1 or b.data.len < @sizeOf(vav.PictureParameterBufferVP8)) return va.ERROR_INVALID_BUFFER;
            const p = b.element(vav.PictureParameterBufferVP8, 0);
            if (p.frame_width == 0 or p.frame_height == 0 or p.frame_width > 0x3fff or p.frame_height > 0x3fff) return va.ERROR_INVALID_PARAMETER;
            if (p.pic_fields.version > 3) return va.ERROR_INVALID_PARAMETER;
            st.pic = p;
            st.have_pic = true;
        },
        vav.PROBABILITY_BUFFER => {
            if (b.data.len < @sizeOf([4][8][3][11]u8)) return va.ERROR_INVALID_BUFFER;
            @memcpy(std.mem.asBytes(&st.coef), b.data[0..@sizeOf([4][8][3][11]u8)]);
            st.have_probs = true;
        },
        // (the decoder reads the quantizer indices from the frame header)
        va.IQ_MATRIX_BUFFER => {},
        va.SLICE_PARAMETER_BUFFER => {
            if (b.size < @sizeOf(vav.SliceParameterBufferVP8) or b.count < 1 or b.data.len < @sizeOf(vav.SliceParameterBufferVP8)) return va.ERROR_INVALID_BUFFER;
            // (one slice: the frame)
            const s = b.element(vav.SliceParameterBufferVP8, 0);
            // (VA_SLICE_DATA_FLAG_ALL: a frame in pieces is not taken)
            if (s.slice_data_flag != 0) return va.ERROR_INVALID_PARAMETER;
            st.slice = s;
            st.have_slice = true;
        },
        va.SLICE_DATA_BUFFER => {
            if (!st.have_pic or !st.have_slice) return va.ERROR_INVALID_PARAMETER;
            return frame(st, b.data, slot);
        },
        else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
    }
    return va.SUCCESS;
}

/// The frame's bytes into the stream. (FFmpeg's slice is the frame from the
/// first partition on; GStreamer's starts at slice_data_offset but counts
/// the uncompressed chunk in slice_data_size: what is there is taken.)
fn frame(st: *State, data: []const u8, slot: codec.Slot) va.Status {
    const s = &st.slice;
    if (s.slice_data_offset > data.len) return va.ERROR_INVALID_BUFFER;
    const avail = data.len - s.slice_data_offset;
    const len: usize = @min(s.slice_data_size, avail);
    const bytes = data[s.slice_data_offset..][0..len];
    const p = partitions(bytes, s) catch |e| return switch (e) {
        error.Short => va.ERROR_INVALID_BUFFER,
        error.Corrupt => va.ERROR_INVALID_PARAMETER,
    };
    if (len > slot.stream.len) return va.ERROR_NOT_ENOUGH_BUFFER;
    @memcpy(slot.stream[0..len], bytes);
    // (a little zero padding after it, where it fits)
    const pad = @min(slot.stream.len - len, 16);
    @memset(slot.stream[len..][0..pad], 0);
    st.parts = p;
    st.stream_len = @intCast(len);
    st.have_frame = true;
    return va.SUCCESS;
}

/// The table for this frame: VA's probabilities in the decoder's layout.
pub fn probs(st: *const State) Probs {
    var t = std.mem.zeroes(Probs);
    for (0..4) |i| for (0..8) |j| for (0..3) |k| {
        @memcpy(t.coef[i][j][k][0..11], &st.coef[i][j][k]);
    };
    if (st.pic.pic_fields.key_frame == 0) {
        t.ymode = DEFAULT_YMODE;
        t.uvmode[0..3].* = DEFAULT_UVMODE;
    } else {
        t.ymode = st.pic.y_mode_probs;
        t.uvmode[0..3].* = st.pic.uv_mode_probs;
    }
    for (0..2) |c| @memcpy(t.mv[c][0..19], &st.pic.mv_probs[c]);
    return t;
}

pub fn end(st: *State, slot: codec.Slot, scratch: codec.Scratch, pic: codec.Picture, lookup: codec.Lookup, out: *codec.End) va.Status {
    if (!st.have_frame or !st.have_probs) return va.ERROR_INVALID_PARAMETER;
    const p = &st.pic;
    const width = p.frame_width;
    const height = p.frame_height;
    if (width > st.width or height > st.height) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    if (width > pic.target.width or height > pic.target.height) return va.ERROR_INVALID_SURFACE;
    const history = historyBytes(st.width);
    if (scratch.cpu.len < history or slot.pic.len < MAX_PIC_BYTES or slot.aux.len < MAX_AUX_BYTES or slot.push.len < PUSH_DWORDS) return va.ERROR_OPERATION_FAILED;
    const key = p.pic_fields.key_frame == 0;

    // the references: golden, altref, last (none on a key frame: the
    // target's planes, never address 0)
    var luma = [_]u64{pic.target.luma} ** nvdec.SLOTS;
    var chroma = [_]u64{pic.target.chroma} ** nvdec.SLOTS;
    if (!key) {
        const ids = [3]u32{ p.golden_ref_frame, p.alt_ref_frame, p.last_ref_frame };
        for (ids, [3]usize{ SLOT_GOLDEN, SLOT_ALTREF, SLOT_LAST }) |id, i| {
            if (id == va.INVALID_ID) continue;
            const r = lookup.surface(id) orelse continue;
            luma[i] = r.luma;
            chroma[i] = r.chroma;
        }
    }
    for (luma, chroma) |l, c| {
        if (!nvdec.addressable(l) or !nvdec.addressable(c)) return va.ERROR_INVALID_SURFACE;
    }

    // the setup
    const seg_update: u8 = @intFromBool(p.pic_fields.segmentation_enabled != 0 and p.pic_fields.update_segment_feature_data != 0);
    var s = Vp8Pic{};
    s.gptimer_timeout_value = nvdec.GPTIMER_TIMEOUT;
    s.FrameWidth = @intCast(alignUp(width, 16));
    s.FrameHeight = @intCast(alignUp(height, 16));
    s.keyFrame = @intFromBool(key);
    s.version = p.pic_fields.version;
    s.surface = .{ .tileFormat = 1, .gob_height = pic.gob_height };
    s.errorConcealOn = 1;
    s.firstPartSize = st.parts.first;
    s.HistBufferSize = @intCast(history >> 8);
    s.VLDBufferSize = st.stream_len;
    s.FrameStride = .{ pic.target.pitch_luma / 16, pic.target.pitch_chroma / 16 };
    s.segmentation_feature_data_update = seg_update;
    s.reserved1[0] = seg_update;
    @memcpy(slot.pic[0..@sizeOf(Vp8Pic)], std.mem.asBytes(&s));

    // the probability table
    const t = probs(st);
    @memset(slot.aux[0..PROB_BYTES], 0);
    @memcpy(slot.aux[0..@sizeOf(Probs)], std.mem.asBytes(&t));

    // the pushbuffer
    luma[SLOT_CURRENT] = pic.target.luma;
    chroma[SLOT_CURRENT] = pic.target.chroma;
    const o = slot.push;
    var n: usize = 0;
    codec.bind(o, &n);
    codec.put(o, &n, nvdec.SET_APPLICATION_ID, APPLICATION_ID_VP8);
    codec.put(o, &n, nvdec.SET_CONTROL_PARAMS, codec.controlParams(CODEC_TYPE_VP8, 0));
    codec.put(o, &n, nvdec.SET_PICTURE_INDEX, pic.picture_index);
    codec.put(o, &n, nvdec.SET_DRV_PIC_SETUP_OFFSET, nvdec.shifted(slot.pic_va));
    codec.put(o, &n, nvdec.SET_IN_BUF_BASE_OFFSET, nvdec.shifted(slot.stream_va));
    codec.put(o, &n, nvdec.SET_NVDEC_STATUS_OFFSET, nvdec.shifted(slot.status_va));
    codec.put(o, &n, VP8_SET_PROB_DATA_OFFSET, nvdec.shifted(slot.aux_va));
    codec.put(o, &n, nvdec.SET_HISTORY_OFFSET, nvdec.shifted(scratch.va));
    codec.pictures(o, &n, luma, chroma);
    codec.execute(o, &n);
    std.debug.assert(n == PUSH_DWORDS);

    st.have_frame = false;
    out.* = .{ .dwords = n };
    return va.SUCCESS;
}

pub fn after(_: *State, _: codec.Scratch) void {}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "vp8: every declaration compiles" {
    testing.refAllDecls(@This());
}

test "vp8: the decoder's structs as nvdec_drv.h lays them out" {
    // (the offsets are asserted at compile time; the bit fields here)
    var s = Vp8Pic{};
    s.surface = .{ .tileFormat = 1, .gob_height = 2 };
    s.keyFrame = 1;
    s.version = 3;
    const b = std.mem.asBytes(&s);
    // (gcc: tileFormat 1 and gob_height 2 is 0x09)
    try testing.expectEqual(@as(u8, 0x09), b[0x3e]);
    try testing.expectEqual(@as(u8, 1), b[0x3c]);
    try testing.expectEqual(@as(u8, 3), b[0x3d]);
    try testing.expectEqual(@as(usize, 0xc0), MAX_PIC_BYTES);
    try testing.expectEqual(@as(usize, 0x4b00), MAX_AUX_BYTES);
    try testing.expectEqual(@as(usize, 56), PUSH_DWORDS);
    // 72 wide: 5 macroblock columns of history; 4K: 240
    try testing.expectEqual(@as(usize, 0xa00), scratchBytes(72, 40));
    try testing.expectEqual(@as(usize, 240 * 0x200), scratchBytes(3840, 2160));
}

/// A frame of a clip made by FFmpeg's libvpx encoder (from its testsrc),
/// with what libvpx v1.14.0's decoder read of it: the frame tag, the header
/// fields a VA-API client passes on, the first partition's bits its header
/// took (VA's macroblock_offset), each DCT partition's place in the frame,
/// and the probabilities the frame decodes with (coefficients: the clip's
/// first frame in full, then the changes from the frame before).
const ClipFrame = struct {
    bytes: []const u8,
    key: bool,
    version: u3,
    show: bool,
    first: u32,
    mbo: u32,
    /// (offset in the frame, bytes)
    parts: []const [2]u32,
    seg: bool,
    segmap: bool,
    segdata: bool,
    lfdelta: bool,
    lfupdate: bool,
    skip: bool,
    filter_type: u1,
    lf: u6,
    sharp: u3,
    bias_g: u1,
    bias_a: u1,
    prob_skip: u8,
    prob_intra: u8,
    prob_last: u8,
    prob_gf: u8,
    q: u8,
    segtree: [3]u8,
    seglf: [4]i8,
    refd: [4]i8,
    moded: [4]i8,
    ymode: [4]u8,
    uvmode: [3]u8,
    mv: [2][19]u8,
    coef_base: ?[]const u8,
    coef_diff: []const [2]u16,

    fn chunk(f: ClipFrame) u32 {
        return if (f.key) 10 else 3;
    }
};

/// VA's picture parameters for `f` as FFmpeg's vaapi_vp8.c builds them.
fn vaPicture(f: ClipFrame, last: u32, golden: u32, alt: u32) vav.PictureParameterBufferVP8 {
    var p = std.mem.zeroes(vav.PictureParameterBufferVP8);
    p.frame_width = 72;
    p.frame_height = 40;
    p.last_ref_frame = last;
    p.golden_ref_frame = golden;
    p.alt_ref_frame = alt;
    p.out_of_loop_frame = va.INVALID_ID;
    p.pic_fields = .{
        .key_frame = @intFromBool(!f.key),
        .version = f.version,
        .segmentation_enabled = @intFromBool(f.seg),
        .update_mb_segmentation_map = @intFromBool(f.segmap),
        .update_segment_feature_data = @intFromBool(f.segdata),
        .filter_type = f.filter_type,
        .sharpness_level = f.sharp,
        .loop_filter_adj_enable = @intFromBool(f.lfdelta),
        .mode_ref_lf_delta_update = @intFromBool(f.lfupdate),
        .sign_bias_golden = f.bias_g,
        .sign_bias_alternate = f.bias_a,
        .mb_no_coeff_skip = @intFromBool(f.skip),
        .loop_filter_disable = @intFromBool(f.lf == 0),
    };
    p.mb_segment_tree_probs = f.segtree;
    for (0..4) |i| {
        const level: i32 = if (f.seg) @as(i32, f.seglf[i]) + f.lf else f.lf;
        p.loop_filter_level[i] = @intCast(std.math.clamp(level, 0, 63));
    }
    p.loop_filter_deltas_ref_frame = f.refd;
    p.loop_filter_deltas_mode = f.moded;
    p.prob_skip_false = f.prob_skip;
    p.prob_intra = f.prob_intra;
    p.prob_last = f.prob_last;
    p.prob_gf = f.prob_gf;
    if (f.key) {
        // (FFmpeg sends the key frame's fixed mode probabilities)
        p.y_mode_probs = .{ 145, 156, 163, 128 };
        p.uv_mode_probs = .{ 142, 114, 183 };
    } else {
        p.y_mode_probs = f.ymode;
        p.uv_mode_probs = f.uvmode;
    }
    p.mv_probs = f.mv;
    return p;
}

/// VA's slice parameters for `f` as FFmpeg builds them: the frame from its
/// first partition on.
fn vaSlice(f: ClipFrame) vav.SliceParameterBufferVP8 {
    var s = std.mem.zeroes(vav.SliceParameterBufferVP8);
    s.slice_data_size = @intCast(f.bytes.len - f.chunk());
    s.slice_data_offset = 0;
    s.macroblock_offset = f.mbo;
    s.num_of_partitions = @intCast(f.parts.len + 1);
    s.partition_size[0] = f.first - (f.mbo + 7) / 8;
    for (f.parts, 1..) |pt, i| s.partition_size[i] = pt[1];
    return s;
}

fn buffer(kind: u32, bytes: []const u8) codec.Buffer {
    return .{ .kind = kind, .size = @intCast(bytes.len), .count = 1, .data = bytes };
}

const TestCtx = struct {
    var fs: codec.FakeSlot = .{};
    var scratch: [0x1000]u8 align(256) = undefined;
};

/// The frame's three parameter buffers, then its data, through `take`.
fn takeFrame(st: *State, slot: codec.Slot, f: ClipFrame, coef: *const [1056]u8, last: u32, golden: u32, alt: u32) !void {
    begin(st);
    const pic = vaPicture(f, last, golden, alt);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    var pb = std.mem.zeroes(vav.ProbabilityDataBufferVP8);
    @memcpy(std.mem.asBytes(&pb.dct_coeff_probs), coef);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(vav.PROBABILITY_BUFFER, std.mem.asBytes(&pb)), slot));
    var iq = std.mem.zeroes(vav.IQMatrixBufferVP8);
    for (&iq.quantization_index) |*seg| seg.* = [_]u16{f.q} ** 6;
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.IQ_MATRIX_BUFFER, std.mem.asBytes(&iq)), slot));
    const sp = vaSlice(f);
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.SUCCESS, take(st, buffer(va.SLICE_DATA_BUFFER, f.bytes[f.chunk()..]), slot));
}

/// A clip through take and end: each frame's bitstream, partitions, setup
/// and probability table against libvpx's reading of it.
fn runClip(clip: []const ClipFrame) !void {
    var st = State.init(72, 40);
    var surfaces = codec.FakeSurfaces{ .w = 72, .h = 40, .n = 8 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(72, 40)], .va = 0x20_0000_0000 };
    var coef: [1056]u8 = undefined;
    // the reference surfaces as FFmpeg keeps them (the clips refresh only
    // last after their key frame)
    var last: u32 = va.INVALID_ID;
    var golden: u32 = va.INVALID_ID;
    for (clip, 0..) |f, i| {
        if (f.coef_base) |b| @memcpy(&coef, b);
        for (f.coef_diff) |d| coef[d[0]] = @intCast(d[1]);
        const target: u32 = @intCast(i + 1);
        const slot = TestCtx.fs.slot();
        try takeFrame(&st, slot, f, &coef, last, golden, golden);

        // the frame tag, read here: the first partition's size VA's
        // parameters gave
        const tag = @as(u32, f.bytes[0]) | (@as(u32, f.bytes[1]) << 8) | (@as(u32, f.bytes[2]) << 16);
        try testing.expectEqual(@as(u32, @intFromBool(!f.key)), tag & 1);
        try testing.expectEqual(tag >> 5, st.parts.first);
        try testing.expectEqual(f.first, st.parts.first);
        // the DCT partitions where libvpx found them
        try testing.expectEqual(f.parts.len, st.parts.count);
        for (f.parts, 0..) |pt, k| {
            try testing.expectEqual(pt[0] - f.chunk(), st.parts.at[k]);
            try testing.expectEqual(pt[1], st.parts.size[k]);
        }
        try testing.expectEqual(@as(u32, @intCast(f.bytes.len - f.chunk())), st.parts.end);
        // the bitstream: the frame after its uncompressed chunk, padded
        const stream = f.bytes[f.chunk()..];
        try testing.expectEqual(@as(u32, @intCast(stream.len)), st.stream_len);
        try testing.expectEqualSlices(u8, stream, TestCtx.fs.stream[0..stream.len]);
        try testing.expectEqualSlices(u8, &[_]u8{0} ** 16, TestCtx.fs.stream[stream.len..][0..16]);

        var out: codec.End = undefined;
        const p = codec.Picture{ .target_id = target, .target = surfaces.lookup().surface(target).?, .gob_height = 2, .picture_index = @intCast(i) };
        try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, p, surfaces.lookup(), &out));
        try testing.expectEqual(PUSH_DWORDS, out.dwords);
        try testing.expect(!out.wait);

        const s = std.mem.bytesToValue(Vp8Pic, slot.pic[0..@sizeOf(Vp8Pic)]);
        try testing.expectEqual(@as(u8, @intFromBool(f.key)), s.keyFrame);
        try testing.expectEqual(@as(u8, f.version), s.version);
        try testing.expectEqual(f.first, s.firstPartSize);
        try testing.expectEqual(@as(u32, @intCast(stream.len)), s.VLDBufferSize);
        try testing.expectEqual(@as(u16, 80), s.FrameWidth);
        try testing.expectEqual(@as(u16, 48), s.FrameHeight);
        // (FakeSurfaces: 64-byte aligned pitches, 128 bytes)
        try testing.expectEqual([2]u32{ 8, 8 }, s.FrameStride);
        try testing.expectEqual(@as(u2, 1), s.surface.tileFormat);
        try testing.expectEqual(@as(u3, 2), s.surface.gob_height);
        try testing.expectEqual(@as(u8, 1), s.errorConcealOn);
        try testing.expectEqual(nvdec.GPTIMER_TIMEOUT, s.gptimer_timeout_value);
        try testing.expectEqual(@as(u32, 0xa), s.HistBufferSize);
        const seg_update: u8 = @intFromBool(f.seg and f.segdata);
        try testing.expectEqual(seg_update, s.segmentation_feature_data_update);
        try testing.expectEqual(seg_update, s.reserved1[0]);

        // the probability table: libvpx's probabilities for this frame
        const t = std.mem.bytesToValue(Probs, slot.aux[0..@sizeOf(Probs)]);
        for (0..4) |a| for (0..8) |b| for (0..3) |c| {
            try testing.expectEqualSlices(u8, coef[((a * 8 + b) * 3 + c) * 11 ..][0..11], t.coef[a][b][c][0..11]);
            try testing.expectEqual(@as(u8, 0), t.coef[a][b][c][11]);
        };
        try testing.expectEqual(f.ymode, t.ymode);
        try testing.expectEqual(f.uvmode, t.uvmode[0..3].*);
        try testing.expectEqual(@as(u8, 0), t.uvmode[3]);
        for (0..2) |c| {
            try testing.expectEqual(f.mv[c], t.mv[c][0..19].*);
            try testing.expectEqual(@as(u8, 0), t.mv[c][19]);
        }
        for (slot.aux[@offsetOf(Probs, "tail")..PROB_BYTES]) |v| try testing.expectEqual(@as(u8, 0), v);

        // the slots: golden, altref, last, current
        const w = slot.push[0..out.dwords];
        const luma0 = 19;
        const want_ref: [3]u32 = if (f.key) .{ target, target, target } else .{ golden, golden, last };
        for (want_ref, 0..) |r, k| try testing.expectEqual(nvdec.shifted(surfaces.lookup().surface(r).?.luma), w[luma0 + k]);
        try testing.expectEqual(nvdec.shifted(p.target.luma), w[luma0 + 3]);

        last = target;
        if (f.key) golden = target;
    }
}

test "vp8: two libvpx clips, frame by frame, against libvpx" {
    // CLIP_A: 72x40, a key frame then five inter frames, four DCT
    // partitions, probabilities kept from frame to frame
    try runClip(&CLIP_A);
    // CLIP_B: 72x40, three frames, error resilient (refresh_entropy_probs
    // 0), segmentation on, one DCT partition
    try runClip(&CLIP_B);
}

test "vp8: an inter frame's pushbuffer, word by word" {
    var st = State.init(72, 40);
    var surfaces = codec.FakeSurfaces{ .w = 72, .h = 40, .n = 8 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(72, 40)], .va = 0x20_0000_0000 };
    var coef: [1056]u8 = undefined;
    @memcpy(&coef, CLIP_A[0].coef_base.?);
    for (CLIP_A[1].coef_diff) |d| coef[d[0]] = @intCast(d[1]);
    const slot = TestCtx.fs.slot();
    // last: surface 3, golden: 1, altref: 5; the target 2
    try takeFrame(&st, slot, CLIP_A[1], &coef, 3, 1, 5);
    var out: codec.End = undefined;
    const p = codec.Picture{ .target_id = 2, .target = surfaces.lookup().surface(2).?, .gob_height = 0, .picture_index = 7 };
    try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, p, surfaces.lookup(), &out));
    const want = [_]u32{
        0x2001_0000, 0x001f_cfb0, // SET_OBJECT
        0x2001_0080, 5, // SET_APPLICATION_ID VP8
        0x2001_0100, 5 | (1 << 4) | (1 << 6) | (1 << 13), // SET_CONTROL_PARAMS
        0x2001_0103, 7, // SET_PICTURE_INDEX
        0x2001_0101, 0x1000_0004, // SET_DRV_PIC_SETUP_OFFSET
        0x2001_0102, 0x1000_0100, // SET_IN_BUF_BASE_OFFSET
        0x2001_0109, 0x1000_0014, // SET_NVDEC_STATUS_OFFSET
        0x2001_0150, 0x1000_0020, // VP8_SET_PROB_DATA_OFFSET
        0x2001_0106, 0x2000_0000, // SET_HISTORY_OFFSET
        0x2011_010c, // SET_PICTURE_LUMA_OFFSET0, 17
        0x4001_0000, 0x4005_0000, 0x4003_0000, 0x4002_0000, // golden, altref, last, current
    };
    try testing.expectEqualSlices(u32, &want, slot.push[0..want.len]);
    // (the unused slots: the target)
    for (slot.push[want.len .. want.len + 13]) |v| try testing.expectEqual(@as(u32, 0x4002_0000), v);
    try testing.expectEqual(@as(u32, 0x2011_011d), slot.push[36]); // SET_PICTURE_CHROMA_OFFSET0, 17
    try testing.expectEqualSlices(u32, &.{ 0x4001_8000, 0x4005_8000, 0x4003_8000, 0x4002_8000 }, slot.push[37..41]);
    for (slot.push[41..54]) |v| try testing.expectEqual(@as(u32, 0x4002_8000), v);
    try testing.expectEqualSlices(u32, &.{ 0x2001_00c0, 0 }, slot.push[54..56]); // EXECUTE
    try testing.expectEqual(@as(usize, 56), out.dwords);

    // a reference VA does not know: the target in its slot
    try takeFrame(&st, slot, CLIP_A[1], &coef, 3, 42, 5);
    try testing.expectEqual(va.SUCCESS, end(&st, slot, scratch, p, surfaces.lookup(), &out));
    try testing.expectEqual(@as(u32, 0x4002_0000), slot.push[19]);
    try testing.expectEqual(@as(u32, 0x4005_0000), slot.push[20]);
}

test "vp8: GStreamer's slice (offset past the chunk, the frame's whole size)" {
    var st = State.init(72, 40);
    const slot = TestCtx.fs.slot();
    const f = CLIP_A[0];
    begin(&st);
    const pic = vaPicture(f, va.INVALID_ID, va.INVALID_ID, va.INVALID_ID);
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    var sp = vaSlice(f);
    sp.slice_data_offset = f.chunk();
    sp.slice_data_size = @intCast(f.bytes.len);
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes), slot));
    try testing.expectEqual(f.first, st.parts.first);
    try testing.expectEqual(@as(u32, @intCast(f.bytes.len - 10)), st.stream_len);
    try testing.expectEqualSlices(u8, f.bytes[10..], TestCtx.fs.stream[0..st.stream_len]);
}

test "vp8: refused and malformed input" {
    var st = State.init(72, 40);
    const slot = TestCtx.fs.slot();
    const f = CLIP_A[1];
    var surfaces = codec.FakeSurfaces{ .w = 72, .h = 40, .n = 2 };
    const scratch = codec.Scratch{ .cpu = TestCtx.scratch[0..scratchBytes(72, 40)], .va = 0x20_0000_0000 };
    const p = codec.Picture{ .target_id = 1, .target = surfaces.lookup().surface(1).?, .gob_height = 0, .picture_index = 0 };
    var out: codec.End = undefined;
    begin(&st);
    var pic = vaPicture(f, 2, 2, 2);
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, take(&st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)[0..100]), slot));
    pic.pic_fields.version = 4;
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(&st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    pic.pic_fields.version = 0;
    // slice data before its parameters
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes[3..]), slot));
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.PICTURE_PARAMETER_BUFFER, std.mem.asBytes(&pic)), slot));
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes[3..]), slot));
    // a partition count VP8 cannot have
    var sp = vaSlice(f);
    sp.num_of_partitions = 4;
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes[3..]), slot));
    // a first partition one byte off: the size table no longer agrees
    sp = vaSlice(f);
    sp.partition_size[0] += 1;
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes[3..]), slot));
    // partitions past the data
    sp = vaSlice(f);
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes[3 .. f.bytes.len - 1]), slot));
    // a frame in pieces
    sp.slice_data_flag = 1;
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, take(&st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    sp.slice_data_flag = 0;
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_PARAMETER_BUFFER, std.mem.asBytes(&sp)), slot));
    try testing.expectEqual(va.SUCCESS, take(&st, buffer(va.SLICE_DATA_BUFFER, f.bytes[3..]), slot));
    // no probabilities: no picture
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, end(&st, slot, scratch, p, surfaces.lookup(), &out));
    try testing.expectEqual(va.ERROR_INVALID_BUFFER, take(&st, buffer(vav.PROBABILITY_BUFFER, &[_]u8{0} ** 100), slot));
    try testing.expectEqual(va.ERROR_UNSUPPORTED_BUFFERTYPE, take(&st, buffer(9, &[_]u8{0} ** 100), slot));
    // a frame larger than the context
    var small = State.init(64, 32);
    var coef: [1056]u8 = undefined;
    @memcpy(&coef, CLIP_A[0].coef_base.?);
    try takeFrame(&small, slot, CLIP_A[0], &coef, va.INVALID_ID, va.INVALID_ID, va.INVALID_ID);
    try testing.expectEqual(va.ERROR_RESOLUTION_NOT_SUPPORTED, end(&small, slot, scratch, p, surfaces.lookup(), &out));
    // nothing taken since: no picture to end
    begin(&st);
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, end(&st, slot, scratch, p, surfaces.lookup(), &out));
}

// ── The clips, made by FFmpeg 6.1's libvpx encoder from its testsrc (72x40)
// and read by libvpx v1.14.0's decoder (made by gentest8.py) ───────────────

const CLIP_A = [_]ClipFrame{
    .{
        .bytes = "\x90\x1f\x00\x9d\x01\x2a\x48\x00\x28\x00\x00\x87\x08\x85\x85\x88\x85\x84\x88\x82\x02\x02\x75\xba" ++
            "\x25\x02\x7e\x2b\xf8\x47\xfa\xa3\xfd\x57\xe4\x26\xa4\xfc\x17\xec\xc7\xeb\x1f\xf7\x9d\x89\x3f\xcc" ++
            "\xff\x00\x7d\x82\x7c\x3b\xf1\x6f\xe7\x7f\x84\x9f\xdb\xbb\x40\xfd\x99\xfb\x80\xff\x72\xfe\x27\xfc" ++
            "\x8f\xf0\x83\x80\x0f\xe9\x4f\xf6\x2f\xe6\x7e\xc1\x3f\xcb\x3f\x99\xf6\x00\xff\x38\xfe\x81\xea\xf5" ++
            "\xfd\x77\xd8\x07\xf6\x03\xd8\x07\xf8\x77\xf4\x0f\x43\x5f\xec\xbf\xe8\x3e\x03\xbf\x5d\xff\xd1\x7f" ++
            "\x94\xf8\x10\xfe\x67\xfc\xaf\xe7\xff\x4c\x07\xf8\x0f\x9a\xde\xed\xbe\x6d\xf8\x8b\x6a\x1b\xeb\xa7" ++
            "\xc7\xbf\x13\x7f\x0f\x74\x8c\x7e\x28\xdc\xea\x7e\x03\xf8\x03\xca\x6f\xe2\x03\xc8\x03\xfc\x57\xfa" ++
            "\x8f\xf0\x1f\xc1\x4f\x7d\x1f\xe2\x7f\x29\x7d\x42\xfc\x81\xfe\x3b\xdc\x2b\xf8\xd7\xf2\x6f\xf0\x1f" ++
            "\x99\x9f\xda\x79\x00\x7f\x49\x7d\xaf\xae\x74\x9b\x68\xf1\xff\xa9\x36\x01\x89\x1a\xab\x55\x84\x93" ++
            "\xb1\x2c\x1a\xca\xa0\xc9\x5d\xab\x41\x81\xb7\x8f\xb2\x28\x30\x9a\x86\x42\x96\x4b\x17\x5b\xca\xa4" ++
            "\x5c\x66\x3e\x3f\xfd\x43\x2f\x39\x63\xe4\x9c\xc5\x6c\x0f\x07\x40\x63\x8b\x99\x6f\xa8\x80\x69\x01" ++
            "\x00\x71\x01\x00\x6b\x01\x00\xfe\xff\xc5\xb3\x7d\xfc\x83\xa8\xae\x09\xa0\xa2\x01\x93\x30\x93\x10" ++
            "\x79\x5b\x85\x93\x15\x79\x30\xed\xd7\x8c\x9c\x18\xab\xc6\xfd\xad\x8a\x68\xff\xe1\x42\x92\x40\xe6" ++
            "\xef\x1a\xa2\xc7\xff\xb3\xf7\xe7\xfb\x42\x33\x0d\xf3\x73\x3e\x77\x70\x23\xc0\x66\x15\xbd\x21\xf4" ++
            "\xa6\x9a\x38\x8a\xfa\x5a\x46\x45\x69\x91\x2f\x40\x44\xe5\x2e\x16\x87\x87\x52\x60\xad\x71\x71\x6f" ++
            "\xbd\x44\xdb\xf1\x5d\x84\x5d\x9e\xcd\x57\xb7\x53\x65\xf5\x31\x91\xbd\xf1\xc1\x9e\xcf\x5f\x98\x64" ++
            "\xfb\xc1\x33\xab\xf7\x99\x3e\xee\x05\x92\x8c\x01\xdd\xc4\x69\xed\xd8\x35\xc8\x30\x33\xc9\x4a\x24" ++
            "\xbf\xa5\xa4\x9a\x34\x0b\x06\x45\x9c\x00\x26\x86\xe5\xb0\x32\x5a\xcc\xc0\x9b\x55\x13\xe8\xc0\x99" ++
            "\x43\xdf\xe6\x7d\x4d\x68\x8e\xad\xf5\x51\x88\x73\xff\xe7\x9a\x37\x2c\x36\xcc\x00\x24\x6a\x18\xb4" ++
            "\x1f\x7a\xb3\x57\x3d\x34\xea\x18\xb4\x1f\x76\x7b\xd8\xf1\x31\xc5\x62\x22\x83\x3a\x79\xa9\xed\x13" ++
            "\x36\xb0\x17\xef\xfb\x96\xf0\xaa\xf9\x78\xe3\xa8\x3f\x83\x56\xcd\x66\x48\xa4\x82\x7a\x90\xef\x05" ++
            "\x02\x03\xe9\x21\x6b\xce\xac\xc8\xbf\xc4\x2b\x3f\x74\xc0\xf7\x68\x64\xb3\xbd\xb5\xd5\x45\xde\xef" ++
            "\x1f\x7a\x75\x1b\xd7\xf7\xd4\x0b\x6a\x87\xf5\x7b\x50\x36\x61\x79\x3b\xf8\xcc\x72\x7c\xe7\x83\x79" ++
            "\x4d\xbd\xd2\xc9\xc4\x0b\x90\x52\x05\x13\xa7\xf5\x81\x62\x6d\x7f\x82\x5b\x3f\xf2\x0c\xe0\x5a\x2e" ++
            "\x6e\xc2\xf7\x75\x5b\x57\x6a\x01\x2e\x56\x40\xc1\xd5\xd1\xcb\x57\x8d\x09\x1a\x5c\x68\xc2\xb9\xf1" ++
            "\xc9\x2d\xfc\x4b\xdd\xa8\x02\xdb\xe2\x01\xe9\x28\xee\xd0\x4e\x6e\x3f\x15\xe4\x82\x14\x7a\xeb\xfc" ++
            "\x4b\xfa\x5d\x8b\x77\x6d\xed\x00\x23\x27\xc0\x09\x90\x6d\x7c\x54\xac\x4d\x23\xf9\x9f\xd7\xb4\xb9" ++
            "\xc0\x9a\x91\xff\xf2\xdb\x31\x84\xc2\x47\x28\x76\xf0\x28\x93\xa1\x0e\x40\x02\xa4\xe6\x79\x9f\xff" ++
            "\x97\xa9\xb5\x0b\x41\xc3\x19\x81\xe0\xef\x2c\xf0\x48\xac\xd3\xf8\x9e\x91\xa8\x31\x89\x62\x69\xff" ++
            "\xfd\x3e\x37\x15\xe8\xf5\x04\x0c\xd1\x6c\x42\xb2\x5c\x84\x8d\xdd\x46\x90\xac\xe5\x9e\xa9\xa3\x22" ++
            "\x54\xc1\xce\x89\x31\x76\xdc\x3b\xa2\xca\x1e\xf6\x7c\x43\x84\xf3\x22\x58\x69\x88\x06\xc0\x53\x7c" ++
            "\xc2\xc3\xab\x5a\x19\x00\x28\xaa\xbf\x95\x12\xf1\x1d\xca\x2a\xbb\xd0\x19\x77\xf2\x3a\xe8\x00\x15" ++
            "\x40\x01\xc5\x62\xa5\xc9\x0d\x1b\xc8\xf2\xcc\xba\xde\xcf\xf3\x77\xb2\xc7\x6d\xbf\x79\x4e\x85\x6e" ++
            "\x9b\xe2\xcc\x51\x8c\xec\xf0\xba\x08\x45\x30\x5f\xf8\xc9\xc9\xab\x27\x12\x98\x9a\xb1\x69\x54\x4b" ++
            "\xf1\x2b\x9d\x35\xd3\xad\xdd\x00\x42\x7a\xeb\xfd\xab\x12\x84\x13\x3b\x1e\x11\xad\x80\xac\xa2\x72" ++
            "\xbe\xad\xe1\xfc\x03\x8c\x00\xf8\x00\x50\xde\xd8\x80\xde\x55\xab\x3e\x8b\x63\x76\x86\xdd\xe5\x4d" ++
            "\x6b\x85\x15\x2e\x85\xa3\xa7\xba\x60\x49\x79\x29\x93\x80\x34\xfb\x1e\x06\xd0\xe8\x60\xd2\x63\x79" ++
            "\x21\xd2\x4a\x32\x3c\x11\xb3\x52\xd9\x2e\xb4\x69\xe1\xf9\x07\x90\xea\xc0\x20\x17\x03\xbf\xc9\x41" ++
            "\xac\x98\x28\x40\x79\xb5\x7b\x09\x2a\x72\xb7\x72\xe7\xc6\xc0\x06\xda\x38\x13\xff\xfc\xdb\x76\x45" ++
            "\x21\x3b\xea\x49\xf1\x1f\x8d\xe6\x63\xf7\x3b\x4d\x3b\xa8\x03\x74\x70\xf7\x82\x83\xff\xfe\xf6\xd7" ++
            "\xd5\x75\xf4\x13\x7f\xce\x20\x00\x0c\x20\x07\xf2\x42\xd7\xea\x7e\xf8\x5f\x33\xb6\x60\x00\x01\x34" ++
            "\xed\x95\x8b\x1b\xd5\xc7\xdb\x46\xaf\xff\xef\xfd\xc0\x82\xc7\x70\x00\x49\xe4\x5d\x2b\x6f\x8f\xdb" ++
            "\x56\xdd\x4b\xe9\x84\xc7\xc7\xcf\xf1\xcf\xff\xa5\xae\xb3\x23\x4c\x7b\xb3\x48\x6c\xa7\xdd\xf9\x86" ++
            "\x9f\x41\x21\x3b\x7a\x92\x81\xde\x7c\x72\x25\x21\x0b\xbb\x78\xb0\xb3\xa3\x7d\xd1\xcc\x7e\x6e\xbe" ++
            "\x81\xf0\x0f\x23\xb0\xeb\x24\x81\x6f\xfb\x3e\x2d\xa1\xb2\x96\x4f\xf9\x60\x5c\x37\xfa\x40\x66\x22" ++
            "\x21\x00\xf1\x57\xfe\x9c\x54\xd6\x1e\x8f\x77\x02\xa5\xd4\x12\x01\xbe\xa1\xcb\xf5\x3c\x3e\x2b\x98" ++
            "\xef\x44\xf3\x7a\xd4\xc4\xb4\x3d\x57\xd7\x49\xbf\x6a\x17\x68\x83\x05\x59\xb7\x13\xa3\xe9\xde\xf2" ++
            "\xcf\xdc\x79\x70\x12\x2e\xc5\x10\x38\x8c\x4b\x4d\x76\x96\x43\xc0\xd8\xe0\x80\xa3\xe5\x83\x03\xd7" ++
            "\xb6\x7e\xf4\x4b\xad\xec\xa1\xd9\x45\xf8\x8d\x75\xd6\x5f\x59\x20\x0c\x0d\x5e\xcb\x7c\xc5\x34\x2f" ++
            "\x32\xbe\xb3\x73\xd0\xb5\x36\xd3\xfd\x51\x1b\x9e\x81\x4b\x1a\xbf\xbb\x3e\x70\xc8\xb7\x80\x6f\x7b" ++
            "\x4a\x80\x23\xfe\xee\x18\xe0\x3e\xe8\x9c\x22\x4f\x48\x30\xae\x66\x06\x23\x90\xfb\x93\x27\xcc\xa2" ++
            "\x79\xc4\xf5\xf3\x6c\xa0\x43\xa4\xd1\x85\x73\x30\x61\x6a\xbe\x71\x4e\x4e\x89\xca\x90\x2c\x08\x9f" ++
            "\xfd\xbd\xe5\xd9\xfc\x7e\x93\x92\xf1\x78\x30\x87\xee\x51\x03\xb4\x63\x3a\x67\xa7\x65\x1c\xca\x6a" ++
            "\xdf\x1d\xea\x5a\xa9\xb8\x8b\xcd\xb3\x1a\x1c\xf7\x8c\x78\x1e\x91\x31\x5f\xf0\x34\xda\x07\x1f\x37" ++
            "\x2b\x87\x2b\x19\x6f\xc1\xad\xc9\x58\xf6\xf4\x3e\x17\x70\xa7\x76\xd5\xdb\x98\x71\xe8\x41\xef\x4a" ++
            "\xe8\x3d\xbb\x17\xdc\x88\xea\x62\x02\x30\xc9\xa1\x4c\xf5\x28\x7a\x51\xd3\xfd\xe1\x4e\x23\xa2\x60" ++
            "\x21\x4d\xee\x08\x39\x27\xe8\xea\x67\xff\xfa\xb2\x97\x15\x87\x02\x2a\x10\x00\x00\x00",
        .key = true,
        .version = 0,
        .show = true,
        .first = 252,
        .mbo = 1523,
        .parts = &.{ .{ 271, 361 }, .{ 632, 369 }, .{ 1001, 363 }, .{ 1364, 1 } },
        .seg = false,
        .segmap = false,
        .segdata = false,
        .lfdelta = true,
        .lfupdate = true,
        .skip = true,
        .filter_type = 0,
        .lf = 2,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 255,
        .prob_intra = 0,
        .prob_last = 0,
        .prob_gf = 0,
        .q = 4,
        .segtree = .{ 0, 0, 0 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -2, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\x80\x80\x80\x80\x80\x80\x80\xfd\x88\xfe\xff\xe4\xdb\x80\x80\x80\x80\x80\xbd\x81\xf2\xff" ++
            "\xe3\xd5\xff\xdb\x80\x80\x80\x6a\x7e\xe3\xfc\xd6\xd1\xff\xff\x80\x80\x80\x01\x62\xf8\xff\xec\xe2" ++
            "\xff\xff\x80\x80\x80\xb5\x85\xee\xfe\xdd\xea\xff\x9a\x80\x80\x80\x4e\x86\xca\xf7\xc6\xb4\xff\xdb" ++
            "\x80\x80\x80\x01\xb9\xf9\xff\xf3\xff\x80\x80\x80\x80\x80\xb8\x96\xf7\xff\xec\xe0\x80\x80\x80\x80" ++
            "\x80\x4d\x6e\xd8\xff\xec\xe6\x80\x80\x80\x80\x80\x01\x65\xfb\xff\xf1\xff\x80\x80\x80\x80\x80\xaa" ++
            "\x8b\xf1\xfc\xec\xd1\xff\xff\x80\x80\x80\x25\x74\xc4\xf3\xe4\xff\xff\xff\x80\x80\x80\x01\xcc\xfe" ++
            "\xff\xf5\xff\x80\x80\x80\x80\x80\xcf\xa0\xfa\xff\xee\x80\x80\x80\x80\x80\x80\x66\x67\xe7\xff\xd3" ++
            "\xab\x80\x80\x80\x80\x80\x01\x98\xfc\xff\xf0\xff\x80\x80\x80\x80\x80\xb1\x87\xf3\xff\xea\xe1\x80" ++
            "\x80\x80\x80\x80\x50\x81\xd3\xff\xc2\xe0\x80\x80\x80\x80\x80\x01\x01\xff\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\xf6\x01\xff\x80\x80\x80\x80\x80\x80\x80\x80\xff\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\xc6\x23\xed\xdf\xc1\xbb\xa2\xa0\x91\x9b\x3e\x83\x2d\xc6\xdd\xac\xb0\xdc\x9d\xfc\xdd\x01\x44\x2f" ++
            "\x92\xd0\x95\xa7\xdd\xa2\xff\xdf\x80\x01\x95\xf1\xff\xdd\xe0\xff\xff\x80\x80\x80\xb8\x8d\xea\xfd" ++
            "\xde\xdc\xff\xc7\x80\x80\x80\x51\x63\xb5\xf2\xb0\xbe\xf9\xca\xff\xff\x80\x01\x81\xe8\xfd\xd6\xc5" ++
            "\xf2\xc4\xff\xff\x80\x63\x79\xd2\xfa\xc9\xc6\xff\xca\x80\x80\x80\x17\x5b\xa3\xf2\xaa\xbb\xf7\xd2" ++
            "\xff\xff\x80\x01\xc8\xf6\xff\xea\xff\x80\x80\x80\x80\x80\x6d\xb2\xf1\xff\xe7\xf5\xff\xff\x80\x80" ++
            "\x80\x2c\x82\xc9\xfd\xcd\xc0\xff\xff\x80\x80\x80\x01\x84\xef\xfb\xdb\xd1\xff\xa5\x80\x80\x80\x5e" ++
            "\x88\xe1\xfb\xda\xbe\xff\xff\x80\x80\x80\x16\x64\xae\xf5\xba\xa1\xff\xc7\x80\x80\x80\x01\xb6\xf9" ++
            "\xff\xe8\xeb\x80\x80\x80\x80\x80\x7c\x8f\xf1\xff\xe3\xea\x80\x80\x80\x80\x80\x23\x4d\xb5\xfb\xc1" ++
            "\xd3\xff\xcd\x80\x80\x80\x01\x9d\xf7\xff\xec\xe7\xff\xff\x80\x80\x80\x79\x8d\xeb\xff\xe1\xe3\xff" ++
            "\xff\x80\x80\x80\x2d\x63\xbc\xfb\xc3\xd9\xff\xe0\x80\x80\x80\x01\x01\xfb\xff\xd5\xff\x80\x80\x80" ++
            "\x80\x80\xcb\x01\xf8\xff\xff\x80\x80\x80\x80\x80\x80\x89\x01\xb1\xff\xe0\xff\x80\x80\x80\x80\x80" ++
            "\x01\x09\xf8\xfb\xcf\xd0\xff\xc0\x80\x80\x80\x01\x0d\x4b\x15\xc1\xb9\x23\xc6\x51\x55\x80\x01\x11" ++
            "\x24\x05\xa1\xb3\x18\xa7\x63\x79\x80\x01\x5f\xf7\xfd\xd4\xb7\xff\xff\x80\x80\x80\xef\x5a\x49\x33" ++
            "\xd3\xd1\x01\xff\x80\x80\x80\x01\x0e\x16\x3b\xbc\xc3\x24\x6e\x80\x80\x80\x01\x18\xef\xfb\xda\xdb" ++
            "\xff\xcd\x80\x80\x80\x01\x33\xdb\x33\xc4\xba\x80\x80\x80\x80\x80\x01\x72\x13\x23\xc9\xda\x20\xe4" ++
            "\x80\x80\x80\x01\xbf\xfb\xff\xff\x80\x80\x80\x80\x80\x80\xdf\xa5\xf9\xff\xd5\xff\x80\x80\x80\x80" ++
            "\x80\x01\x7c\x29\x62\x33\x80\x80\x80\x80\x80\x80\x01\x10\x09\x2c\x33\x80\x80\x80\x80\x80\x80\xbe" ++
            "\x24\xe6\xff\xec\xff\x80\x80\x80\x80\x80\x01\x38\x40\x80\x80\x80\x80\x80\x80\x80\x80\x01\x7a\x5d" ++
            "\x80\x80\x80\x80\x80\x80\x80\x80\x01\xc0\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01\x0e\x40\x80\x80" ++
            "\x80\x80\x80\x80\x80\x80\x01\x86\x35\x65\xa0\x80\x80\x80\x80\x80\x80\x0e\x3e\x77\xa2\x94\x80\x80" ++
            "\x80\x80\x80\x80\x10\x33\x2b\x80\x80\x80\x80\x80\xff\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\xca\x18\x01\x01\xba\xbf\xdc\xa0\xf0\xaf\xff\x39\x26\x3c\x36\xa9\xb8\x45\xae\xff\xbb\x80\x3d\x2e" ++
            "\x8a\xdb\x97\xb2\xf0\xaa\xff\xd8\x80\x01\x70\xe6\xfa\xc7\xbf\xf7\x9f\xff\xff\x80\xa6\x6d\xe4\xfc" ++
            "\xd3\xd7\xff\xae\x80\x80\x80\x27\x06\x26\x1e\xac\xb4\x4d\xb2\xff\x3d\x80\x01\x34\xdc\xf6\xc6\xc7" ++
            "\xf9\xdc\xff\xff\x80\x7c\x4a\xbf\xf3\xb7\xc1\xfa\xdd\xff\xff\x80\x18\x47\x82\x18\x9a\xaa\x51\xb6" ++
            "\xff\xff\x80\x01\xb6\xe1\xf9\xdb\xf0\xff\xe0\x80\x80\x80\x95\x96\xe2\xfc\xd8\xcd\xff\xab\x80\x80" ++
            "\x80\x1c\x6c\xaa\xf2\xb7\xc2\xfe\xdf\xff\xff\x80\x01\x51\x46\x01\xcc\xcb\x01\xc0\x80\x80\x80\x7b" ++
            "\x66\xd1\xf7\xbc\xc4\xff\xe9\x80\x80\x80\x14\x5f\x99\x37\xa4\xad\xff\xcb\x80\x80\x80\x01\xde\xf8" ++
            "\x01\xd8\xd5\x80\x80\x80\x80\x80\xa8\xaf\xf6\xfc\xeb\xcd\xff\xff\x80\x80\x80\x2f\x01\x15\x51\x01" ++
            "\xd4\xff\x14\x80\x80\x80\x01\x79\x45\x89\xd4\xd6\xa5\xff\x80\x80\x80\x01\x54\x40\x8e\xc9\xca\xff" ++
            "\xdb\x80\x80\x80\x0a\x1a\x26\x80\xa2\xb9\xcc\x69\x80\x80\x80\x01\x01\xff\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\xf4\x01\xff\x80\x80\x80\x80\x80\x80\x80\x80\x01\x01\x25\x80\x80\x80\x80\x80\x80\x80\x80",
        .coef_diff = &.{},
    },
    .{
        .bytes = "\x11\x05\x00\x06\x14\x10\x00\x1e\xb7\x25\x8b\xc4\x48\x9b\xdd\x2f\xfb\x38\x3f\xdb\xd1\xfa\x85\x07" ++
            "\x6d\x81\xe7\xff\xbb\xff\x6e\xb7\x38\xb1\xba\x71\x60\x25\xba\xd9\xc0\xc0\x88\x13\x00\x00\x4e\x00" ++
            "\x00\x53\x00\x00\x81\x89\xcc\xb6\x0a\x20\x92\xae\x36\xdf\x48\x5a\x32\x08\x10\xfa\x11\x0e\x00\x0b" ++
            "\xa1\x0a\xcd\xd5\xb4\x43\x2f\x85\x83\xd2\xb8\x33\x4a\xac\xc5\x6b\x4a\x68\x5e\x9b\xf7\xee\x9d\x97" ++
            "\x0d\xf1\xcc\x64\x72\x81\x77\x97\x42\x6a\xfc\x8c\x8f\x06\x96\x48\xf1\x05\x1e\x94\xa6\xa7\x88\x76" ++
            "\x2a\xa1\xd3\x25\x37\x09\x79\x4f\xa5\xdf\x40\xef\x79\x7f\xbb\xfa\x4c\xfd\x7a\x48\x3c\x91\x25\xa5" ++
            "\xbb\x6b\x7e\x00\x00\x9a\xd0\x1e\x48\xe0\x0c\x60\x46\x82\x80\x6c\x21\xf6\xbb\x74\xa9\x06\x6a\xdc" ++
            "\x14\x52\x13\xd6\x5c\xa3\x1a\x1a\x0e\x90\xd7\x81\x20\x03\x49\x22\xab\x40\x9a\x39\x8a\x51\x10\xc2" ++
            "\x28\x00\x88\xcc\x80\x4e\x9f\x60\x01\x8d\xf6\x85\xa9\xf6\x77\xd0\x85\x10\x7c\x30\xa3\x92\x56\x84" ++
            "\x6a\xbe\xa2\x29\xfc\x3c\x4b\x85\x08\x5b\x55\x10\xca\x8e\x00\x00\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 40,
        .mbo = 270,
        .parts = &.{ .{ 52, 19 }, .{ 71, 78 }, .{ 149, 83 }, .{ 232, 1 } },
        .seg = false,
        .segmap = false,
        .segdata = false,
        .lfdelta = true,
        .lfupdate = false,
        .skip = true,
        .filter_type = 0,
        .lf = 6,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 238,
        .prob_intra = 1,
        .prob_last = 255,
        .prob_gf = 128,
        .q = 4,
        .segtree = .{ 0, 0, 0 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -2, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 33, 230 }, .{ 528, 180 }, .{ 529, 160 }, .{ 539, 53 }, .{ 540, 111 }, .{ 541, 236 }, .{ 553, 255 }, .{ 572, 14 }, .{ 573, 226 }, .{ 605, 142 }, .{ 638, 1 }, .{ 661, 255 }, .{ 728, 255 }, .{ 848, 183 } },
    },
    .{
        .bytes = "\xb1\x02\x00\x05\x14\x10\x00\x1b\xcc\xd0\xc5\x91\x1b\xd7\x7c\xc3\x12\xa8\xda\xee\x2b\x28\x3c\xd4" ++
            "\x0b\x00\x00\x5f\x00\x00\x62\x00\x00\xcb\x15\x00\x0b\x80\xb0\x9b\x4b\xc0\x00\x00\x0b\xa1\x0b\x5c" ++
            "\x24\x04\x32\xf8\x58\x4a\x10\xfe\x21\xe7\x8d\x00\x18\xb5\x06\xce\x58\x39\xc4\x5e\x6d\x71\x14\x3c" ++
            "\x6d\xe1\x28\xad\x06\x3b\xd5\xa5\xac\xea\xb3\x37\x42\x8b\x2e\x90\xc3\x21\x1e\x0d\x2c\x91\xee\x50" ++
            "\x6a\x05\xec\x87\x5e\xe0\x98\xf6\xe6\xcd\x62\x4b\x75\xfa\x84\x72\x7b\xa6\x63\xa3\x6c\xaf\x80\x03" ++
            "\xc5\xef\xbb\xb1\xdf\x65\xb9\xc6\x1b\x1b\x46\x21\x60\xe5\xde\xc1\x86\xa0\x00\x97\x91\xef\x5c\x7d" ++
            "\xd6\x02\x51\x69\x3a\x5d\xe2\x69\x1c\xf4\xa4\x59\x45\xd6\xb6\x14\xc9\xfb\x94\x50\x00\x2a\x5d\x70" ++
            "\x03\xbe\x13\x3b\xb7\x27\x24\x78\x2e\xe0\x79\x12\x7b\x80\x1a\x80\x0c\x9d\x97\x8b\x5e\xa6\x76\x60" ++
            "\xba\x04\xfb\xe0\xa0\x8f\x79\x62\xc8\x5d\x58\xff\x3d\xe4\xd3\xfe\x64\xbf\x2c\x01\xc1\x79\x67\x9d" ++
            "\x1d\x80\x34\x5c\x74\x4a\x9e\x80\x9b\xeb\x3b\x01\x67\xea\xa3\x70\x33\xf1\x5e\x00\x00\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 21,
        .mbo = 111,
        .parts = &.{ .{ 33, 11 }, .{ 44, 95 }, .{ 139, 98 }, .{ 237, 1 } },
        .seg = false,
        .segmap = false,
        .segdata = false,
        .lfdelta = true,
        .lfupdate = false,
        .skip = true,
        .filter_type = 0,
        .lf = 5,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 221,
        .prob_intra = 1,
        .prob_last = 238,
        .prob_gf = 255,
        .q = 4,
        .segtree = .{ 0, 0, 0 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -2, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 44, 37 }, .{ 584, 219 } },
    },
    .{
        .bytes = "\xb1\x02\x00\x05\x14\x10\x00\x18\x3b\x0b\xc4\xf0\x2d\xd2\x31\x4e\x68\xdf\xc3\x79\xd6\x09\xa7\xd0" ++
            "\x08\x00\x00\x50\x00\x00\x4d\x00\x00\xe5\xb4\x80\x7e\xbd\xb3\x5e\x00\xde\x48\x82\xf0\xf0\x04\x7d" ++
            "\xff\xd4\x4e\xab\x7f\xd4\x4c\x8a\xe0\x49\x8c\x25\x53\xb9\x05\xc2\x4d\x74\x6a\x0c\x32\xcd\xfc\x5a" ++
            "\x13\xc1\x11\x17\x23\x1e\xb1\x1e\x0d\x2c\x91\xe0\xd2\xc8\x35\x3b\xd2\x95\xd6\x43\xe8\x2a\x0e\x97" ++
            "\x56\xa3\xe6\x1a\xcf\xe6\xb1\x10\x9b\x4f\x6c\x47\xf5\xe8\x3c\xba\x61\xa5\x6a\x60\xa7\x61\x9d\x30" ++
            "\x00\x97\x90\x64\xca\xe0\x04\xfa\x30\x11\x0f\x89\x18\x0e\x98\x20\x6b\x7c\x54\x59\x97\xb7\x40\x0b" ++
            "\xa0\xa8\x06\x82\xb9\xf1\xb5\x24\x8d\xce\xec\xe8\xac\x80\x00\xd5\x94\xa5\x4c\x80\x02\xc7\x4f\x05" ++
            "\xf0\x23\x0e\xc0\x7e\x0a\x01\xf1\x24\xc0\x73\xd1\x29\x01\x24\xb6\xa4\xa2\x4f\xe8\xf2\xe1\x84\x28" ++
            "\xd6\xc1\x21\x8a\x98\x00\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 21,
        .mbo = 110,
        .parts = &.{ .{ 33, 8 }, .{ 41, 80 }, .{ 121, 77 }, .{ 198, 1 } },
        .seg = false,
        .segmap = false,
        .segdata = false,
        .lfdelta = true,
        .lfupdate = false,
        .skip = true,
        .filter_type = 0,
        .lf = 5,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 204,
        .prob_intra = 1,
        .prob_last = 238,
        .prob_gf = 255,
        .q = 4,
        .segtree = .{ 0, 0, 0 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -2, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 308, 1 }, .{ 473, 12 } },
    },
    .{
        .bytes = "\xf1\x02\x00\x05\x14\x10\x00\x1a\xd3\x02\x8f\xc8\x06\x3b\xa6\xb5\x04\xdd\x9b\xea\x72\x71\xde\xe4" ++
            "\x70\x00\x08\x00\x00\x5d\x00\x00\x63\x00\x00\xe5\xb4\x80\x7e\xbd\xb3\x5e\x00\xfc\x25\xcd\xfa\xdf" ++
            "\xaf\xaf\x00\x8a\xa9\x83\xb5\xd6\x0a\x79\x6b\x5c\x3f\xc6\xff\x1b\x01\x10\xb7\x6f\x07\xdd\xf6\x43" ++
            "\x7d\x39\x7b\x3b\xfb\xb7\x04\x43\xcb\xfe\xc1\xcf\x71\xa5\xb5\x92\x3c\x24\x22\x92\x5d\x72\x02\x03" ++
            "\x81\x96\xb8\xba\x1c\x24\x09\xdf\xb4\x24\xc1\x90\xa1\x1f\xa3\xac\x4d\x19\x6b\x3b\x2c\xbf\x85\x82" ++
            "\xf1\x44\xc1\x9c\x8c\xfa\xa4\xaa\x57\x10\x0e\x57\xc7\x90\xb0\x80\x9a\xd0\x08\xbf\x08\x79\x83\x32" ++
            "\xbc\x03\xea\x08\x55\xe4\x13\x55\x2a\x9d\x12\x79\x3e\x2a\x2c\xcb\xdc\x65\x50\x7b\x15\xb1\xa1\x66" ++
            "\x0b\xa0\x33\xad\x54\x00\x08\xb2\x4d\xf8\xf7\xd5\xc5\x7e\xa0\x00\x0a\x10\x05\x66\xb1\xcf\x14\x67" ++
            "\x95\xa5\xc1\x5b\x1d\x9d\x6a\x12\xe6\x8f\x32\x28\x31\x5c\x29\xe2\x01\x33\xb2\xc8\xab\x87\x60\x64" ++
            "\xb7\xe4\x95\x6f\x69\x0f\x22\xbe\xd4\x35\xbe\x71\x2a\x37\x02\xde\x80\x00\x00\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 23,
        .mbo = 113,
        .parts = &.{ .{ 35, 8 }, .{ 43, 93 }, .{ 136, 99 }, .{ 235, 1 } },
        .seg = false,
        .segmap = false,
        .segdata = false,
        .lfdelta = true,
        .lfupdate = false,
        .skip = true,
        .filter_type = 0,
        .lf = 5,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 204,
        .prob_intra = 1,
        .prob_last = 238,
        .prob_gf = 255,
        .q = 4,
        .segtree = .{ 0, 0, 0 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -2, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 68, 149 }, .{ 133, 255 } },
    },
    .{
        .bytes = "\xb1\x02\x00\x06\x14\x10\x00\x19\x85\x5a\x3f\x00\x96\xe9\x18\xa7\x34\x6f\xe1\xbb\xb0\xca\x2a\x14" ++
            "\x08\x00\x00\x57\x00\x00\x4a\x00\x00\xe5\xb4\x80\x7e\xbd\xb3\x5e\x00\xcc\xdd\x11\xf4\xc7\x6f\x2d" ++
            "\x22\xe3\x76\x18\xc5\x04\xfc\xa0\xd2\x37\x2f\xf6\x21\xcb\xc2\x29\x50\xf3\x87\x6b\xfe\xfe\x8a\x08" ++
            "\x20\x1b\x2f\xb7\xbc\x24\x0d\xd5\xb9\xcd\x64\x35\xc4\x6e\xfa\x61\x41\x8c\x31\x86\xc2\xcd\xfa\x22" ++
            "\x7f\x9d\xb7\x7c\x66\xaa\x7c\xe9\xa7\xde\x5d\xbb\x2a\xff\xa4\x53\xb0\x7b\xde\x79\x1a\x87\x01\x82" ++
            "\xc9\x20\x41\x99\x39\x22\x50\x00\x97\x90\x63\x73\x51\x0f\x30\x64\xc0\x1f\x01\x02\x77\x25\xa5\x12" ++
            "\xc0\x10\x35\xb3\xb4\x3f\xf8\xeb\xa7\xd0\x04\x52\xf7\x80\xfd\xfb\x61\x48\x38\xea\xe8\x8d\xc1\x5d" ++
            "\x41\xc0\x00\x23\x5f\xf4\xc7\x03\xb0\x0d\xd0\x10\x47\x13\xcf\x71\xc0\xf6\xce\xc3\x04\x71\x04\x09" ++
            "\xb2\xc0\x06\x92\x24\x72\x80\x28\x00\x00\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 21,
        .mbo = 111,
        .parts = &.{ .{ 33, 8 }, .{ 41, 87 }, .{ 128, 74 }, .{ 202, 1 } },
        .seg = false,
        .segmap = false,
        .segdata = false,
        .lfdelta = true,
        .lfupdate = false,
        .skip = true,
        .filter_type = 0,
        .lf = 6,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 204,
        .prob_intra = 1,
        .prob_last = 238,
        .prob_gf = 255,
        .q = 4,
        .segtree = .{ 0, 0, 0 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -2, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 133, 171 }, .{ 552, 183 } },
    },
};

const CLIP_B = [_]ClipFrame{
    .{
        .bytes = "\xd0\x21\x00\x9d\x01\x2a\x48\x00\x28\x00\x39\x05\x00\x02\x1c\x24\x0c\x2c\x2c\x44\xcc\x24\x40\x10" ++
            "\x00\x13\xad\xd1\x28\x13\xf0\x1f\xc2\x0f\xd6\x2f\xf4\x1f\x21\x35\x4f\xe1\x5f\x66\x7f\x5b\xff\xc0" ++
            "\x7b\x80\xf8\x0d\xc8\x1f\xca\xff\x0c\xfd\x82\x7c\x3b\xf1\x6f\xe5\xbf\x84\x5f\xd2\x7d\x80\x7f\x10" ++
            "\x3e\x40\xfd\x99\xfb\x80\xff\x72\xfe\x27\xfc\x73\xf0\x7f\x80\x0f\xe8\x87\xf4\x4f\xe8\x1e\xc1\x3f" ++
            "\xc9\x7f\xa0\x76\x00\xff\x38\xfe\x71\xea\xe9\xfd\x57\xd8\x07\xf6\x4b\xd8\x07\xf8\x2f\xf3\xef\x43" ++
            "\xaf\xed\x7f\xe7\x3e\x03\xbf\x5d\xff\xc4\xff\x80\xf8\x10\xfe\x5f\xfc\xab\xe7\xc7\x4c\x07\xf8\x0f" ++
            "\x99\x2e\xdd\x3e\x79\xf8\xed\xce\xee\x7b\x17\xcd\xff\x13\xbf\x13\xbd\x80\x77\x45\x7f\x14\xfc\x7a" ++
            "\xc9\x03\xfc\x9f\xbf\xbf\xf1\xcf\xc0\x1e\x60\x1f\xe8\x1f\x95\x7f\x00\x7f\x92\xfe\x57\xc8\x03\xfc" ++
            "\x57\xfa\x37\xe5\x87\xf2\xff\x78\x0f\xe1\x7f\x9f\x7f\x51\xff\x0b\xd4\x15\xfa\x27\xfd\xaf\xf3\x5f" ++
            "\xf9\xbf\x20\x0f\xe8\x8f\xb6\x36\x39\xb8\x62\x67\x89\xe1\xb4\x42\x29\xb6\xdd\x98\x3b\xd9\x68\xd9" ++
            "\x27\x6c\x68\x16\x19\x30\xc8\xa0\xb8\x1f\x2f\x4a\x09\x63\x6f\xc9\xe3\xcc\x29\x80\x74\x7f\x3d\x3f" ++
            "\x22\xc8\xf8\x9b\x05\xbf\x44\xa1\x4d\xfa\x99\x03\xe9\x08\xff\xb0\xfe\xff\xc4\xd9\x08\x33\x8d\x52" ++
            "\x04\x38\xe3\x8b\xa3\xcf\xd6\x0b\xfd\x4b\x41\x5b\x64\xdc\x0d\x6e\x53\xe2\x21\x6c\x9b\x7d\x32\x4b" ++
            "\xa3\x7f\xda\x0d\x60\x5a\x40\x38\xcb\x1d\x53\x7a\x65\xb8\x62\xb8\x9c\x5c\x64\x08\xa1\x88\x84\x1e" ++
            "\x6b\x93\xb8\x16\x0c\x1a\x0d\x21\x45\xff\x19\x47\xec\xce\xf1\xe8\x72\x5a\x00\xf6\xec\x02\x85\xb7" ++
            "\x57\x74\x8b\x6b\x76\x61\xe2\x38\xd4\x9d\x71\xe2\xfb\x0d\xda\xc4\x13\xcc\x77\x42\x41\x47\x0a\x5b" ++
            "\x5d\x99\xf1\x03\xaf\x8f\xaa\x45\x78\x5e\xf0\x26\xde\xaf\x0c\x20\xde\x2a\xee\xca\x24\x10\x0c\x5e" ++
            "\xbf\x41\xb2\x58\x0a\xe4\x21\x9e\x44\x24\x5a\x8b\xb8\x16\x0a\xd4\xf8\x9d\x02\x0e\xd7\x1a\x1f\x26" ++
            "\xde\x5e\x0e\x08\xa8\x88\x9b\xbd\xb6\xe8\x33\xc4\x0c\x05\x44\x31\x11\xa4\x00\x9f\x06\x3f\xfe\x87" ++
            "\x17\xc7\xdc\x82\x44\x00\xa4\x00\xce\x9c\xdb\xc4\x16\x34\xa6\x72\x02\x6d\x31\xce\xa5\x84\xd0\x9a" ++
            "\xf4\x49\x49\xa7\x96\x4d\x72\x2d\x82\xe2\x0d\x82\xef\x00\xcb\x9a\x56\xe7\x1a\xcb\xf4\x21\x17\x4a" ++
            "\x1f\xe2\x9d\x6b\x08\xa4\x66\xaa\x7f\x3f\x73\x62\x8e\x44\x11\x86\x24\x5b\x58\x6a\x98\x49\x6b\x64" ++
            "\x4a\x1a\xd9\xda\x1b\x38\xcb\x2f\x80\x08\xb3\x29\x9f\xb9\x18\x67\x5f\x4f\x9b\x1e\xaf\x3c\x30\x1f" ++
            "\x03\xfe\x2e\xf3\x45\xb0\x84\xff\xfc\xf7\xa8\xc7\x71\xd3\xb9\x8e\xa4\xdd\x96\x4e\x7b\x05\x4e\x61" ++
            "\x78\x5a\x90\x99\x8a\x6b\x31\xbd\xdf\x6d\x73\xde\x92\xfd\x62\xa6\xb9\xca\x80\x44\x6e\xad\xd2\x78" ++
            "\x07\x09\x95\xf9\xf9\xed\x6f\x9a\xc9\x6e\xbb\xd9\xc3\x0e\x53\xf7\xd5\xf1\xe0\x99\xd9\xae\x4c\x7b" ++
            "\xca\xdd\xd5\x6c\xc1\x3b\xd0\x37\x36\xcd\xb4\xbb\x97\xf7\x6b\x8e\x3f\x6d\x3d\x69\x12\xa0\xb5\xb5" ++
            "\x0f\xc5\x47\xa6\x4f\xb8\x57\x7e\xfd\x6d\x7f\x65\xa0\x1b\xdc\xf4\x44\xcc\x01\xa3\xf1\x4c\x21\xb8" ++
            "\x56\x55\xff\x21\x37\xb3\x4b\xbf\xff\x2f\x33\x14\xbb\x67\xca\x72\x13\x41\xde\x57\x4f\x7d\x39\xd9" ++
            "\xfe\x0c\x46\xb0\xb2\x2a\x83\x2f\xff\xd3\xda\xc6\xe9\x43\x89\xa2\x52\xbc\x14\xe8\x00\x24\xf1\xe5" ++
            "\x95\xf4\xfa\x38\xa0\x24\x30\x4f\xb5\x3f\x71\x49\x91\xc4\x98\xb5\xe6\x52\x95\xc4\x0f\xcd\x85\xf0" ++
            "\xa4\xe3\x76\xf7\xbf\xc1\x42\xd2\x90\xb2\x04\x36\xf7\xf2\x98\x1e\xa4\x16\xaa\xe8\x14\x5d\x91\x49" ++
            "\xfe\x52\x00\x0a\x9f\x40\x74\xa6\x50\xb6\xae\xb3\x44\xdc\x8e\x9d\xb2\xc6\x4c\x7a\xe7\xa2\xc3\x6e" ++
            "\xd5\xc6\x4e\x55\x4b\x10\x83\x0f\xde\x23\xc6\x0d\x03\xdc\x42\x73\x9f\xf9\xf6\xfa\x37\xc8\xf3\xc7" ++
            "\xbc\x53\x3e\x26\x99\xc7\x18\x68\x32\xa9\x80\x09\x1a\xc0\xca\x49\x70\x73\x4a\xaa\x98\xc9\xb3\xf8" ++
            "\x85\xbe\x29\x99\xaf\xfd\x4b\xf8\x91\x80\x22\xec\x89\x65\x4f\xb2\xaf\x90\xed\xd2\x61\xc2\xf7\xeb" ++
            "\x82\xf8\x6d\x32\xc1\x63\xdd\x55\xe6\xfc\x91\xa2\xc2\x9d\xe4\xb2\x0c\xb4\xa2\xe5\xf3\xe5\x83\x08" ++
            "\x83\x7f\x55\x46\xc8\xe5\xab\x6b\xa5\x50\x1e\xb9\xe5\xdb\x8a\x5c\x61\x58\xfb\x00\x80\x57\x0e\xbb" ++
            "\xd8\x2c\x18\x43\x5c\x9a\xda\xe9\xa9\xa3\xc9\x97\x3d\x07\xf9\x80\x06\xda\x3b\x55\xff\x36\xdd\x86" ++
            "\xb5\x06\x2a\x00\x4c\xc2\x65\xea\x7c\x5d\x0f\xdf\xaa\x73\xd4\x35\xe0\x2c\x2d\xff\xff\x76\xd3\x21" ++
            "\x78\x6a\x85\x86\x3f\xab\x6b\x25\xc6\x00\x08\xa1\x44\x9a\xe3\xa9\x54\x85\x80\x4e\xcb\xf3\x2b\x18" ++
            "\xc5\x00\x02\x21\x5d\xe9\xe3\x8b\xc8\x83\x5c\xf2\x8f\x07\x91\x5e\x10\x5d\x40\x00\x9e\x43\xde\xe7" ++
            "\xed\xcf\x23\x94\xbe\x11\x71\xfe\x45\x9f\x6e\xec\xff\x15\xbc\x10\xe2\x65\x9d\xf8\x4e\x21\x58\x91" ++
            "\xf2\xa7\x46\xd5\x96\xec\xee\x37\x23\x67\xa3\x87\x69\x37\x3d\x8b\x4a\xbe\x71\x76\xcc\xa5\x96\xd9" ++
            "\x79\x70\xdb\x83\x2f\xc4\x00\x78\xef\x1b\x6a\xc8\xbb\x5e\x2c\xee\xff\xec\xf7\xd3\x83\xaa\x3e\x50" ++
            "\xdf\x5e\xf2\xb4\x24\xe8\x68\x8c\x3a\xda\x87\xde\xe9\x65\x30\xb2\xfe\xe5\xeb\x7f\x71\x34\x19\xfe" ++
            "\x34\xeb\xa9\xd0\xf9\x02\xbe\x06\x95\x05\x80\xdc\x45\x14\xb1\x67\x78\x38\x43\x18\x88\x32\xae\x33" ++
            "\x9a\xce\x43\x78\x10\x0d\xc5\x84\xb6\x59\x13\xa7\x77\x74\x9e\x58\xdf\xba\xae\xbc\x67\xf0\x4c\x53" ++
            "\xd6\x5c\x7b\x90\x5c\x95\x85\x06\x20\x5b\xa2\x92\xb3\xe0\x17\xcd\x09\x31\x49\xf8\x42\x8c\xa8\x3a" ++
            "\xc6\x32\xbf\x3f\xf5\xe9\x21\xa7\xb1\x5f\xcb\xbb\x55\xbf\x7a\xb6\x98\x86\x05\x90\x7b\x64\x67\x09" ++
            "\xa9\x34\xfa\x47\x89\xf6\x9d\xd1\x15\x1f\x9d\xd5\x13\x9e\x15\xde\x6f\x8c\xde\xd1\x95\x9e\x54\xb2" ++
            "\x2b\x8e\x51\x09\xed\x45\x42\x48\x50\x43\xfa\x36\x20\x44\x5d\x3c\x97\x4e\xfd\x56\x0c\x68\x2e\x4e" ++
            "\xee\xec\x07\x68\xb9\xc5\x2e\xd2\xe8\xd8\x90\x92\xbf\x2a\x6e\x1a\xf9\x45\x5c\xd1\xbf\xda\x0a\xe7" ++
            "\xf1\x28\x3c\x7d\x3f\x21\xfb\xff\xdb\x6c\xd5\xff\x93\x30\x18\xc2\x6f\xe0\xd4\x64\x5d\x66\x57\x97" ++
            "\x0a\x7b\xaa\x71\x46\x64\x88\x5b\x95\x1e\x93\x00\x9d\x7d\x99\x02\xc1\x50\x5b\xfe\x7c\x70\x88\x22" ++
            "\x11\x74\x1a\xf8\x44\xc2\x15\xab\x63\x17\xf7\x1c\x18\xcc\x56\xaa\x44\x29\x57\xca\xef\x77\x53\x6f" ++
            "\x51\xe6\xcb\x52\xd0\x51\x82\xd1\x53\x16\x76\x81\xfa\xf8\x48\xe0\x9e\x04\xee\x28\xfa\x4c\x80\x2e" ++
            "\x26\xaa\xe8\xd9\x14\xc1\x48\x40\x6a\x55\x50\x68\x08\x6a\xd9\x71\xed\xad\x10\x31\x4b\x83\xaf\x53" ++
            "\x52\xd9\x26\xc8\xc5\x95\x20\x00",
        .key = true,
        .version = 0,
        .show = true,
        .first = 270,
        .mbo = 1702,
        .parts = &.{.{ 280, 1120 }},
        .seg = true,
        .segmap = true,
        .segdata = true,
        .lfdelta = true,
        .lfupdate = true,
        .skip = true,
        .filter_type = 0,
        .lf = 2,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 255,
        .prob_intra = 0,
        .prob_last = 0,
        .prob_gf = 0,
        .q = 4,
        .segtree = .{ 255, 255, 255 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -12, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\x80\x80\x80\x80\x80\x80\x80\xfd\x88\xfe\xff\xe4\xdb\x80\x80\x80\x80\x80\xbd\x81\xf2\xff" ++
            "\xe3\xd5\xff\xdb\x80\x80\x80\x6a\x7e\xe3\xfc\xd6\xd1\xff\xff\x80\x80\x80\x01\x62\xf8\xff\xec\xe2" ++
            "\xff\xff\x80\x80\x80\xb5\x85\xee\xfe\xdd\xea\xff\x9a\x80\x80\x80\x4e\x86\xca\xf7\xc6\xb4\xff\xdb" ++
            "\x80\x80\x80\x01\xb9\xf9\xff\xf3\xff\x80\x80\x80\x80\x80\xb8\x96\xf7\xff\xec\xe0\x80\x80\x80\x80" ++
            "\x80\x4d\x6e\xd8\xff\xec\xe6\x80\x80\x80\x80\x80\x01\x65\xfb\xff\xf1\xff\x80\x80\x80\x80\x80\xaa" ++
            "\x8b\xf1\xfc\xec\xd1\xff\xff\x80\x80\x80\x25\x74\xc4\xf3\xe4\xff\xff\xff\x80\x80\x80\x01\xcc\xfe" ++
            "\xff\xf5\xff\x80\x80\x80\x80\x80\xcf\xa0\xfa\xff\xee\x80\x80\x80\x80\x80\x80\x66\x67\xe7\xff\xd3" ++
            "\xab\x80\x80\x80\x80\x80\x01\x98\xfc\xff\xf0\xff\x80\x80\x80\x80\x80\xb1\x87\xf3\xff\xea\xe1\x80" ++
            "\x80\x80\x80\x80\x50\x81\xd3\xff\xc2\xe0\x80\x80\x80\x80\x80\x01\x01\xff\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\xf6\x01\xff\x80\x80\x80\x80\x80\x80\x80\x80\xff\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\xc6\x23\xed\xdf\xc1\xbb\xa2\xa0\x91\x9b\x3e\x83\x2d\xc6\xdd\xac\xb0\xdc\x9d\xfc\xdd\x01\x44\x2f" ++
            "\x92\xd0\x95\xa7\xdd\xa2\xff\xdf\x80\x01\x95\xf1\xff\xdd\xe0\xff\xff\x80\x80\x80\xb8\x8d\xea\xfd" ++
            "\xde\xdc\xff\xc7\x80\x80\x80\x51\x63\xb5\xf2\xb0\xbe\xf9\xca\xff\xff\x80\x01\x81\xe8\xfd\xd6\xc5" ++
            "\xf2\xc4\xff\xff\x80\x63\x79\xd2\xfa\xc9\xc6\xff\xca\x80\x80\x80\x17\x5b\xa3\xf2\xaa\xbb\xf7\xd2" ++
            "\xff\xff\x80\x01\xc8\xf6\xff\xea\xff\x80\x80\x80\x80\x80\x6d\xb2\xf1\xff\xe7\xf5\xff\xff\x80\x80" ++
            "\x80\x2c\x82\xc9\xfd\xcd\xc0\xff\xff\x80\x80\x80\x01\x84\xef\xfb\xdb\xd1\xff\xa5\x80\x80\x80\x5e" ++
            "\x88\xe1\xfb\xda\xbe\xff\xff\x80\x80\x80\x16\x64\xae\xf5\xba\xa1\xff\xc7\x80\x80\x80\x01\xb6\xf9" ++
            "\xff\xe8\xeb\x80\x80\x80\x80\x80\x7c\x8f\xf1\xff\xe3\xea\x80\x80\x80\x80\x80\x23\x4d\xb5\xfb\xc1" ++
            "\xd3\xff\xcd\x80\x80\x80\x01\x9d\xf7\xff\xec\xe7\xff\xff\x80\x80\x80\x79\x8d\xeb\xff\xe1\xe3\xff" ++
            "\xff\x80\x80\x80\x2d\x63\xbc\xfb\xc3\xd9\xff\xe0\x80\x80\x80\x01\x01\xfb\xff\xd5\xff\x80\x80\x80" ++
            "\x80\x80\xcb\x01\xf8\xff\xff\x80\x80\x80\x80\x80\x80\x89\x01\xb1\xff\xe0\xff\x80\x80\x80\x80\x80" ++
            "\x01\x09\xf8\xfb\xcf\xd0\xff\xc0\x80\x80\x80\x01\x0d\x4b\x01\xc1\xb9\x20\xc6\x62\xa0\x80\x01\x11" ++
            "\x29\x0a\xa1\xb3\x19\xa7\x6f\x80\x80\x01\x5f\xf7\x01\xd4\xb7\xff\xff\x80\x80\x80\x9a\x5a\x40\x2b" ++
            "\xd3\xd1\x33\xff\x80\x80\x80\x01\x0e\x16\x2d\xbc\xc3\x22\x49\x80\x80\x80\x01\x18\xef\x01\xda\xdb" ++
            "\x40\xcd\x80\x80\x80\x01\x33\xdb\x33\xc4\xba\x80\x80\x80\x80\x80\x01\x72\x13\x1c\xc9\xda\x1f\xe4" ++
            "\x80\x80\x80\x01\xbf\xfb\xff\xff\x80\x80\x80\x80\x80\x80\xdf\xa5\xf9\xff\xd5\xff\x80\x80\x80\x80" ++
            "\x80\x01\x7c\x10\x44\x40\x80\x80\x80\x80\x80\x80\x01\x10\x09\x25\x40\x80\x80\x80\x80\x80\x80\xbe" ++
            "\x24\xe6\xff\xec\xff\x80\x80\x80\x80\x80\x01\x38\x38\x80\x80\x80\x80\x80\x80\x80\x80\x01\x74\x55" ++
            "\x80\x80\x80\x80\x80\x80\x80\x80\x01\xc0\x92\x80\x80\x80\x80\x80\x80\x80\x80\x01\x05\x3e\x80\x80" ++
            "\x80\x80\x80\x80\x80\x80\x01\x86\x3a\x6b\x9c\x80\x80\x80\x80\x80\x80\x0e\x3e\x77\x89\x80\x80\x80" ++
            "\x80\x80\x80\x80\x10\x2f\x2a\x80\x80\x80\x80\x80\xf1\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80" ++
            "\xca\x18\x01\x01\xba\xbf\xdc\xa0\xf0\xaf\xff\x30\x26\x26\x3c\xa9\xb8\x76\xae\xff\xbb\x80\x3d\x2e" ++
            "\x8a\x27\x97\xb2\xf0\xaa\xff\xd8\x80\x01\x70\xe6\xfa\xc7\xbf\xf7\x9f\xff\xff\x80\xa6\x6d\xe4\xfc" ++
            "\xd3\xd7\xff\xae\x80\x80\x80\x27\x4d\x20\x37\xac\xb4\x4e\xb2\xff\x4e\x80\x01\x34\xdc\x01\xc6\xc7" ++
            "\xf9\xdc\xff\xff\x80\x7c\x4a\xbf\xf3\xb7\xc1\xfa\xdd\xff\xff\x80\x18\x47\x0a\x14\x9a\xaa\x7a\xb6" ++
            "\xff\xff\x80\x01\xb6\xe1\xf9\xdb\xf0\xff\xe0\x80\x80\x80\x95\x96\xe2\xfc\xd8\xcd\xff\xab\x80\x80" ++
            "\x80\x1c\x6c\x01\x27\xb7\xc2\xfe\xdf\xff\xff\x80\x01\x51\x4f\x1c\xcc\xcb\x01\xc0\x80\x80\x80\x7b" ++
            "\x66\xd1\xf7\xbc\xc4\xff\xe9\x80\x80\x80\x14\x5f\x01\x40\xa4\xad\xab\xcb\x80\x80\x80\x01\x80\x92" ++
            "\x2b\xd8\xd5\x80\x80\x80\x80\x80\xa8\xaf\xf6\xfc\xeb\xcd\xff\xff\x80\x80\x80\x2f\x01\x15\x46\xd3" ++
            "\xd4\xb0\x2f\x80\x80\x80\x01\x79\x2a\x85\x3e\x51\x85\xff\x80\x80\x80\x8d\x54\xd5\xfc\xc9\xca\xff" ++
            "\xdb\x80\x80\x80\x0a\x50\x13\x6b\xa2\xb9\xd7\x37\x80\x80\x80\x01\x01\xff\x80\x80\x80\x80\x80\x80" ++
            "\x80\x80\xf4\x01\xff\x80\x80\x80\x80\x80\x80\x80\x80\x01\x01\x11\x80\x80\x80\x80\x80\x80\x80\x80",
        .coef_diff = &.{},
    },
    .{
        .bytes = "\x51\x03\x00\xe3\xe2\xa8\x14\x47\xaf\x10\x4f\x4f\xb1\x0a\x2f\xe0\x8a\xe0\x1f\xc0\x6d\xc0\xbf\xd0" ++
            "\x01\xa4\x07\x8d\x00\xc7\xcd\xdf\xea\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 26,
        .mbo = 172,
        .parts = &.{.{ 29, 5 }},
        .seg = true,
        .segmap = true,
        .segdata = true,
        .lfdelta = true,
        .lfupdate = true,
        .skip = true,
        .filter_type = 0,
        .lf = 5,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 34,
        .prob_intra = 1,
        .prob_last = 255,
        .prob_gf = 128,
        .q = 41,
        .segtree = .{ 255, 255, 255 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -12, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 528, 253 }, .{ 539, 175 }, .{ 541, 224 }, .{ 542, 243 }, .{ 545, 249 }, .{ 547, 255 }, .{ 548, 255 }, .{ 550, 73 }, .{ 552, 171 }, .{ 553, 221 }, .{ 556, 236 }, .{ 558, 255 }, .{ 559, 234 }, .{ 564, 253 }, .{ 572, 239 }, .{ 574, 244 }, .{ 575, 250 }, .{ 578, 255 }, .{ 583, 155 }, .{ 584, 77 }, .{ 585, 195 }, .{ 586, 248 }, .{ 589, 255 }, .{ 590, 255 }, .{ 597, 251 }, .{ 600, 255 }, .{ 605, 201 }, .{ 608, 255 }, .{ 616, 69 }, .{ 617, 46 }, .{ 618, 190 }, .{ 619, 239 }, .{ 622, 255 }, .{ 649, 141 }, .{ 651, 248 }, .{ 652, 255 }, .{ 653, 255 }, .{ 662, 248 }, .{ 663, 255 }, .{ 664, 255 }, .{ 682, 149 }, .{ 683, 1 }, .{ 684, 255 }, .{ 694, 226 }, .{ 695, 255 }, .{ 704, 247 }, .{ 706, 255 }, .{ 715, 240 }, .{ 716, 128 }, .{ 717, 255 }, .{ 728, 252 }, .{ 729, 255 }, .{ 730, 255 }, .{ 737, 213 }, .{ 739, 250 }, .{ 740, 255 }, .{ 741, 255 }, .{ 748, 55 }, .{ 749, 93 }, .{ 750, 255 }, .{ 756, 128 }, .{ 794, 213 }, .{ 795, 235 }, .{ 803, 126 }, .{ 805, 182 }, .{ 806, 232 }, .{ 809, 228 }, .{ 817, 219 }, .{ 849, 162 }, .{ 850, 232 }, .{ 853, 245 }, .{ 856, 255 }, .{ 861, 246 }, .{ 882, 130 }, .{ 883, 219 }, .{ 886, 243 }, .{ 915, 170 }, .{ 916, 242 }, .{ 926, 230 }, .{ 927, 252 }, .{ 930, 255 }, .{ 948, 153 }, .{ 949, 243 }, .{ 952, 255 }, .{ 958, 222 }, .{ 959, 248 }, .{ 960, 255 }, .{ 980, 116 }, .{ 981, 215 }, .{ 982, 255 }, .{ 985, 255 }, .{ 986, 255 }, .{ 992, 236 }, .{ 993, 253 }, .{ 994, 212 }, .{ 995, 214 }, .{ 996, 255 }, .{ 1012, 42 }, .{ 1014, 160 }, .{ 1015, 240 }, .{ 1018, 255 }, .{ 1019, 205 }, .{ 1045, 238 }, .{ 1047, 255 } },
    },
    .{
        .bytes = "\x11\x04\x00\xe3\xba\xf8\x14\x47\xaf\x10\x4f\x4f\xb1\x0a\x2f\xdf\xec\x20\x32\xc8\xbf\x01\x23\x3a" ++
            "\x61\xcb\xbd\x0f\x3c\x30\x7c\x96\x7d\x6e\xe0\xc9\x3a\x76\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x03\xb3\xf5\x00\x00\x00\x00\x00\x00\x1f\x09\x7c\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x4d\x56\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x00\x12\xa0\x00\x00\x3b\x49\x5e\x98\x4a\x98\xba\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x10" ++
            "\x01\x04\xd4\x91\x89\xa6\x70\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x7c\x4a" ++
            "\x80\xba\x29\x6d\x36\x26\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x2c\xf8\x00\x1f\x0f\xa2\x46" ++
            "\x47\x83\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\xdb\xd0\x00\x00\x00\x00\x00" ++
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x6f\x3b\xc0\x00\x00\x00",
        .key = false,
        .version = 0,
        .show = true,
        .first = 32,
        .mbo = 216,
        .parts = &.{.{ 35, 172 }},
        .seg = true,
        .segmap = true,
        .segdata = true,
        .lfdelta = true,
        .lfupdate = true,
        .skip = true,
        .filter_type = 0,
        .lf = 5,
        .sharp = 0,
        .bias_g = 0,
        .bias_a = 0,
        .prob_skip = 136,
        .prob_intra = 1,
        .prob_last = 255,
        .prob_gf = 128,
        .q = 31,
        .segtree = .{ 255, 255, 255 },
        .seglf = .{ 0, 0, 0, 0 },
        .refd = .{ 2, 0, -2, -2 },
        .moded = .{ 4, -12, 2, 4 },
        .ymode = .{ 112, 86, 140, 37 },
        .uvmode = .{ 162, 101, 204 },
        .mv = .{ .{ 162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254 }, .{ 164, 128, 204, 170, 119, 235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254 } },
        .coef_base = null,
        .coef_diff = &.{ .{ 33, 1 }, .{ 473, 1 }, .{ 528, 1 }, .{ 572, 1 } },
    },
};
