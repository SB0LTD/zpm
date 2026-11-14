//! @zpm/va encode — an encode context's state between libva's calls, and
//! what EndPicture makes for the engine: the codec's parameter buffers
//! kept, packed headers gathered, the rate control's QP, the parameter
//! sets written into the coded buffer ahead of the engine's slices, the
//! references' buffers, the setup and the pushbuffer; and, once the engine
//! is done, the coded buffer's segment (with CBR's filler).
//!
//! The coded buffer (one of the kernel's buffers, the CPU's and the
//! engine's):
//!
//!   0x0000  VACodedBufferSegment (what vaMapBuffer returns)
//!   0x0100  the engine's status (nvenc_pic_stat_s; SET_OUT_ENC_STATUS)
//!   0x1100  the headers' room (HEADER_BYTES): the headers the driver
//!           writes or the app packed end at its end
//!   0x5100  the engine's slices (SET_OUT_BITSTREAM; bitstream_start_pos
//!           0, as NVIDIA's driver has it), then any filler
//!
//! The stream (what vaMapBuffer's segment names) begins where the headers
//! do: the engine starts at a 256-byte aligned address, at offset 0, and
//! nothing is moved after it. (This driver had the engine start
//! bitstream_start_pos bytes, the headers' length, into the stream before:
//! an odd offset such as 268, which no NVIDIA job is known to use.)
//!
//! The input picture is the engine's as it lies in memory (`Input`: block
//! linear planes, any block height); a picture that needs a pass first
//! (pitch linear, RGB) has had it, on the GPU, before EndPicture gets
//! here (driver.sig, enc_import.sig, enc_rgb.sig).
//!
//! References: VA names the surfaces; each surface that is or becomes a
//! reference keeps an entry in `kept` while VA's lists name it, and the
//! entry's co-located motion buffer is what a later B picture (or HEVC's
//! temporal MVP) reads as its collocated picture's.
//!
//! Rate control: enc_rc.sig (the driver's controller unless the
//! firmware's is asked for).
//!
//! AV1 (enc_av1.sig): the driver writes the OBUs around the engine's tile
//! data; each kept surface also keeps the CDFs its picture adapted, which
//! a later picture naming it as primary reference starts from.
//!
//! Allocation-free: fixed fields; the caller's buffers.

const std = @import("std");
const va = @import("vaapi.sig");
const ve = @import("vaapi_enc.sig");
const codec = @import("codec.sig");
const nvenc = @import("nvenc.sig");
const tiling = @import("tiling.sig");
const bits = @import("bits.sig");
const h264 = @import("enc_h264.sig");
const hevc = @import("enc_hevc.sig");
const enc_rc = @import("enc_rc.sig");
const enc_parse = @import("enc_parse.sig");
const av1 = @import("enc_av1.sig");

pub const Codec = enum { h264, hevc, av1 };

pub const SEGMENT_OFF: usize = 0;
pub const STATUS_OFF: usize = 0x100;
pub const DATA_OFF: usize = 0x1100;
/// the headers' room ahead of the engine's slices
pub const HEADER_BYTES: usize = 16 << 10;
/// where the engine's slices go (SET_OUT_BITSTREAM)
pub const SLICES_OFF: usize = DATA_OFF + HEADER_BYTES;
comptime {
    std.debug.assert(SLICES_OFF % 256 == 0);
}

/// RateControl's modes this driver answers.
pub const RC_MODES: u32 = ve.RC_CQP | ve.RC_CBR | ve.RC_VBR;
/// The packed headers it takes: the app's parameter sets (sequence) and
/// its SEI and other NAL units (misc, raw). Not slices: the engine writes
/// its slice headers.
pub const PACKED_HEADERS: u32 = ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_MISC | ve.PACKED_HEADER_RAW_DATA;
/// EncMaxRefFrames: L0 in the low 16 bits, L1 in the high 16. No L1 (no
/// B pictures) unless GALAXY_VA_NVENC_B=1 asks: the engine's B pictures
/// (direct modes, the co-located motion, two lists) have never encoded
/// on hardware, and an app offered L1 sends them (FFmpeg's default is two
/// B pictures between anchors); offered none, it sends I and P pictures.
pub const MAX_REFS: u32 = h264.MAX_L0;
pub const MAX_REFS_AV1: u32 = av1.MAX_L0;
/// (the old name: L0's count)
pub const MAX_REFS_L0: u32 = h264.MAX_L0;
/// GALAXY_VA_NVENC_B=1: L1 too.
pub const MAX_REFS_B: u32 = h264.MAX_L0 | (h264.MAX_L1 << 16);
pub const MAX_REFS_AV1_B: u32 = av1.MAX_L0 | (av1.MAX_L1 << 16);

/// EncMaxRefFrames for `profile` (one of `supported`'s), with or without
/// B pictures.
pub fn maxRefs(profile: va.Profile, b_frames: bool) u32 {
    const kind = supported(profile) orelse return 0;
    if (kind == .av1) return if (b_frames) MAX_REFS_AV1_B else MAX_REFS_AV1;
    return if (b_frames) MAX_REFS_B else MAX_REFS;
}

/// The packed headers a codec takes.
pub fn packedHeaders(kind: Codec) u32 {
    return if (kind == .av1) av1.PACKED_HEADERS else PACKED_HEADERS;
}
/// Surfaces kept as references at once (each with its co-located buffer).
pub const KEPT = 10;

pub fn supported(profile: va.Profile) ?Codec {
    if (std.mem.indexOfScalar(va.Profile, &h264.PROFILES, profile) != null) return .h264;
    if (profile == hevc.PROFILE) return .hevc;
    if (profile == av1.PROFILE) return .av1;
    return null;
}

/// The rate control's mode for VA's.
pub fn rcMode(va_mode: u32) enc_rc.Mode {
    return switch (va_mode) {
        ve.RC_CBR => .cbr,
        ve.RC_VBR => .vbr,
        else => .cqp,
    };
}

// ── The surfaces kept as references ─────────────────────────────────────────

pub const Kept = struct {
    ids: [KEPT]u32 = [_]u32{va.INVALID_ID} ** KEPT,

    pub fn find(k: *const Kept, id: u32) ?u8 {
        if (id == va.INVALID_ID) return null;
        for (k.ids, 0..) |x, i| {
            if (x == id) return @intCast(i);
        }
        return null;
    }

    /// An entry for `id` (the picture being made): its own, else one no
    /// surface of `live` (the picture's references) holds.
    pub fn take(k: *Kept, id: u32, live: []const u32) ?u8 {
        if (k.find(id)) |i| return i;
        for (&k.ids, 0..) |*x, i| {
            if (x.* == va.INVALID_ID or std.mem.indexOfScalar(u32, live, x.*) == null) {
                x.* = id;
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn reset(k: *Kept) void {
        k.* = .{};
    }
};

// ── The context's state ─────────────────────────────────────────────────────

pub const State = struct {
    kind: Codec,
    profile: va.Profile,
    width: u32,
    height: u32,
    /// the config's packed headers (the app's choice)
    packed_headers: u32,
    rate: enc_rc.Controller = .{},
    /// GALAXY_VA_NVENC_RC=firmware: the engine's own rate control
    firmware_rc: bool = false,
    firmware_rc_started: bool = false,
    /// GALAXY_VA_NVENC_B=1: B pictures taken (else refused: MAX_REFS)
    b_frames: bool = false,
    /// which MEPRED buffer the next inter picture writes (they swap)
    mepred_flip: u1 = 0,
    // ── the sequence (kept across pictures) ──
    have_seq: bool = false,
    h264_seq: h264.Seq = undefined,
    hevc_seq: hevc.Seq = undefined,
    av1_seq: av1.Seq = undefined,
    /// AV1: what the reference slots hold, what was shown
    av1_state: Av1State = .{},
    /// what the app's packed HEVC SPS and PPS say
    hevc_params: enc_parse.HevcParams = .{},
    kept: Kept = .{},
    // ── the picture being made ──
    have_pic: bool = false,
    h264_pic: h264.Pic = undefined,
    hevc_pic: hevc.Pic = undefined,
    av1_pic: av1.Pic = undefined,
    /// AV1: the app's packed frame header said whether it is shown
    av1_shown: ?bool = null,
    av1_showable: bool = false,
    /// a sequence parameter buffer came with this picture
    new_seq: bool = false,
    h264_slices: [nvenc.MAX_SLICES]h264.Slice = undefined,
    hevc_slices: [nvenc.MAX_SLICES]hevc.Slice = undefined,
    slices: u32 = 0,
    /// the app's packed headers, in order, ready for the stream
    hdr: [HEADER_BYTES]u8 = undefined,
    hdr_len: u32 = 0,
    /// a packed sequence header came (the driver writes none then)
    packed_seq: bool = false,
    /// a packed header's parameters, waiting for its data
    packed_kind: u32 = 0,
    packed_bits: u32 = 0,
    packed_emulation: bool = true,
    packed_waiting: bool = false,
    bad: va.Status = va.SUCCESS,
    pictures: u32 = 0,
    /// what the engine said of the context's pictures
    tally: Tally = .{},

    pub fn init(kind: Codec, profile: va.Profile, width: u32, height: u32, rc_mode: u32, packed_headers: u32) State {
        var st = State{ .kind = kind, .profile = profile, .width = width, .height = height, .packed_headers = packed_headers };
        const scale: enc_rc.Scale = if (kind == .av1) .av1 else .h26x;
        st.rate = .{ .mode = rcMode(rc_mode), .scale = scale, .pixels = @as(u64, width) * height, .max_qp = enc_rc.qMax(scale) };
        return st;
    }
};

/// AV1's state across pictures: each reference slot's order hint, whether
/// the last picture was shown, and a hidden picture waiting for its
/// show_existing_frame. (Each kept surface's CDFs are the table the
/// engine wrote for its picture: ASSUMED written also when the picture
/// adapted none, disable_frame_end_update_cdf, as the CDFs it read.)
pub const Av1State = struct {
    slot_hint: [8]u8 = .{0} ** 8,
    defaults_written: bool = false,
    prev_shown: bool = true,
    last_shown: u8 = 0,
    hidden: ?struct { slot: u3, hint: u8 } = null,
};

/// A new picture (BeginPicture).
pub fn begin(st: *State) void {
    st.have_pic = false;
    st.av1_shown = null;
    st.new_seq = false;
    st.slices = 0;
    st.hdr_len = 0;
    st.packed_seq = false;
    st.packed_waiting = false;
    st.bad = va.SUCCESS;
}

fn value(comptime T: type, data: []const u8) ?T {
    if (data.len < @sizeOf(T)) return null;
    return std.mem.bytesToValue(T, data[0..@sizeOf(T)]);
}

/// The sequence's GOP shape for the rate control.
fn gopOf(st: *State, intra_period: u32, ip_period: u32, bps: u32) void {
    st.rate.intra_period = intra_period;
    st.rate.ip_period = @max(ip_period, 1);
    if (st.rate.bits_per_second == 0) st.rate.bits_per_second = bps;
}

/// One VA buffer of the picture (RenderPicture).
pub fn take(st: *State, b: codec.Buffer) va.Status {
    switch (b.kind) {
        ve.ENC_SEQUENCE_PARAMETER_BUFFER => switch (st.kind) {
            .h264 => {
                st.h264_seq = value(h264.Seq, b.data) orelse return va.ERROR_INVALID_BUFFER;
                gopOf(st, st.h264_seq.intra_period, st.h264_seq.ip_period, st.h264_seq.bits_per_second);
                st.have_seq = true;
                st.new_seq = true;
            },
            .hevc => {
                st.hevc_seq = value(hevc.Seq, b.data) orelse return va.ERROR_INVALID_BUFFER;
                gopOf(st, st.hevc_seq.intra_period, st.hevc_seq.ip_period, st.hevc_seq.bits_per_second);
                st.have_seq = true;
                st.new_seq = true;
            },
            .av1 => {
                st.av1_seq = value(av1.Seq, b.data) orelse return va.ERROR_INVALID_BUFFER;
                gopOf(st, st.av1_seq.intra_period, st.av1_seq.ip_period, st.av1_seq.bits_per_second);
                st.have_seq = true;
                st.new_seq = true;
            },
        },
        ve.ENC_PICTURE_PARAMETER_BUFFER => switch (st.kind) {
            .h264 => {
                st.h264_pic = value(h264.Pic, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.have_pic = true;
            },
            .hevc => {
                st.hevc_pic = value(hevc.Pic, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.have_pic = true;
            },
            .av1 => {
                st.av1_pic = value(av1.Pic, b.data) orelse return va.ERROR_INVALID_BUFFER;
                st.have_pic = true;
            },
        },
        ve.ENC_SLICE_PARAMETER_BUFFER => {
            for (0..b.count) |k| {
                if (st.slices >= nvenc.MAX_SLICES) return va.ERROR_MAX_NUM_EXCEEDED;
                switch (st.kind) {
                    .h264 => {
                        if (b.size < @sizeOf(ve.EncSliceParameterBufferH264)) return va.ERROR_INVALID_BUFFER;
                        const s = b.element(ve.EncSliceParameterBufferH264, k);
                        st.h264_slices[st.slices] = h264.Slice.of(&s);
                    },
                    .hevc => {
                        if (b.size < @sizeOf(ve.EncSliceParameterBufferHEVC)) return va.ERROR_INVALID_BUFFER;
                        const s = b.element(ve.EncSliceParameterBufferHEVC, k);
                        st.hevc_slices[st.slices] = hevc.Slice.of(&s);
                    },
                    // (AV1's tile groups: one tile, one group)
                    .av1 => if (b.size < 2) return va.ERROR_INVALID_BUFFER,
                }
                st.slices += 1;
            }
        },
        ve.ENC_MISC_PARAMETER_BUFFER => {
            if (b.data.len < 4) return va.ERROR_INVALID_BUFFER;
            const kind = std.mem.readInt(u32, b.data[0..4], .little);
            const rest = b.data[4..];
            switch (kind) {
                ve.MISC_RATE_CONTROL => {
                    const p = value(ve.RateControl, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.rateControl(p.bits_per_second, p.target_percentage, p.initial_qp, p.min_qp, p.max_qp);
                },
                ve.MISC_FRAME_RATE => {
                    const p = value(ve.FrameRate, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.frameRate(p.framerate & 0xffff, p.framerate >> 16);
                },
                ve.MISC_HRD => {
                    const h = value(ve.Hrd, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.hrd(h.buffer_size, h.initial_buffer_fullness);
                },
                // (quality levels, max frame size, ...: taken, not used)
                else => {},
            }
        },
        ve.ENC_PACKED_HEADER_PARAMETER_BUFFER => {
            const p = value(ve.PackedHeaderParameterBuffer, b.data) orelse return va.ERROR_INVALID_BUFFER;
            st.packed_kind = p.type;
            st.packed_bits = p.bit_length;
            st.packed_emulation = p.has_emulation_bytes != 0;
            st.packed_waiting = true;
        },
        ve.ENC_PACKED_HEADER_DATA_BUFFER => {
            if (!st.packed_waiting) return va.ERROR_INVALID_BUFFER;
            st.packed_waiting = false;
            const n = @min((st.packed_bits + 7) / 8, b.data.len);
            // (the engine writes its own slice headers: an app's are dropped)
            if (st.packed_kind == ve.PACKED_SLICE) return va.SUCCESS;
            const room = st.hdr[st.hdr_len..];
            if (st.kind == .av1 and st.packed_kind == ve.PACKED_PICTURE) {
                // (the app's frame header: whether it is shown; the driver
                // writes its own)
                if (av1.shownOf(b.data[0..n])) |sh| {
                    st.av1_shown = sh.show;
                    st.av1_showable = sh.showable;
                }
                return va.SUCCESS;
            }
            const header_len: usize = if (st.kind == .hevc) 2 else 1;
            // (OBUs have no emulation prevention)
            const wrote = if (st.packed_emulation or st.kind == .av1) copy(room, b.data[0..n]) else emulate(room, b.data[0..n], header_len);
            const written = wrote orelse return va.ERROR_NOT_ENOUGH_BUFFER;
            if (st.packed_kind == ve.PACKED_SEQUENCE) {
                st.packed_seq = true;
                // what its SPS and PPS say that the engine's slice headers
                // must agree with
                if (st.kind == .hevc) {
                    var p = enc_parse.HevcParams{};
                    enc_parse.parsePacked(&p, room[0..written]);
                    if (p.unsupported) return va.ERROR_INVALID_PARAMETER;
                    if (p.have_sps) st.hevc_params = p;
                }
            }
            st.hdr_len += @intCast(written);
        },
        else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
    }
    return va.SUCCESS;
}

fn copy(out: []u8, data: []const u8) ?usize {
    if (data.len > out.len) return null;
    @memcpy(out[0..data.len], data);
    return data.len;
}

/// A packed NAL unit without emulation prevention bytes (`data`: a start
/// code, the NAL unit header, the payload) with them added after the
/// header: VA's packed header is one NAL unit (its payload may hold
/// 00 00 01, so nothing after the first start code is taken for another).
fn emulate(out: []u8, data: []const u8, header_len: usize) ?usize {
    const sc = startCode(data, 0) orelse return copy(out, data);
    const body = data[sc + 3 ..];
    return bits.nal(out, body, @min(header_len, body.len));
}

fn startCode(data: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) return i;
    }
    return null;
}

/// The coded buffer this picture goes into (its VA id).
pub fn codedBuffer(st: *const State) ?u32 {
    if (!st.have_pic) return null;
    return switch (st.kind) {
        .h264 => st.h264_pic.coded_buf,
        .hevc => st.hevc_pic.coded_buf,
        .av1 => st.av1_pic.coded_buf,
    };
}

/// The reconstructed picture's surface.
pub fn reconSurface(st: *const State) u32 {
    return switch (st.kind) {
        .h264 => st.h264_pic.CurrPic.picture_id,
        .hevc => st.hevc_pic.decoded_curr_pic.picture_id,
        .av1 => st.av1_pic.reconstructed_frame,
    };
}

/// Whether the HEVC sequence uses temporal MVP: the app's packed SPS
/// says so when it gave one (that is what goes into the stream), else
/// its sequence parameters.
pub fn hevcTemporalMvp(st: *const State) bool {
    if (st.hevc_params.have_sps) return st.hevc_params.temporal_mvp;
    return st.hevc_seq.seq_fields.sps_temporal_mvp_enabled_flag != 0;
}

/// The picture's type for the rate control.
pub fn picType(st: *const State) enc_rc.Type {
    return switch (st.kind) {
        .h264 => switch (st.h264_slices[0].slice_type) {
            0 => .p,
            1 => .b,
            else => .i,
        },
        .hevc => switch (st.hevc_slices[0].slice_type) {
            0 => .b,
            1 => .p,
            else => .i,
        },
        .av1 => av1.rcType(&st.av1_pic),
    };
}

// ── EndPicture ──────────────────────────────────────────────────────────────

/// The picture to encode, as the engine reads it: its block-linear planes
/// (GPU addresses), their pitches and block height.
pub const Input = struct {
    luma: u64,
    chroma: u64,
    pitch_luma: u32,
    pitch_chroma: u32,
    /// log2 of GOBs per block
    block_height: u7 = tiling.BLOCK_GOBS_LOG2,
    /// the planes' rows (whole blocks)
    rows: u32,
    width: u32,
    height: u32,
    /// the surface's own picture when the engine reads a copy of it (the
    /// driver's Turing copy, driver.nvencInput), 0 when it reads `luma`:
    /// what a reconstruction must not overwrite
    surface_luma: u64 = 0,

    /// The surface's own picture (its luma plane).
    pub fn own(i: Input) u64 {
        return if (i.surface_luma != 0) i.surface_luma else i.luma;
    }
};

/// The context's buffers for the engine: one allocation (`base` on the
/// GPU, `cpu` here) laid out as `sizes` says.
pub const Scratch = struct {
    base: u64,
    cpu: []u8,
    sizes: ScratchSizes,

    pub fn history(s: Scratch) u64 {
        return s.base + s.sizes.history_off;
    }
    pub fn rcProcess(s: Scratch) u64 {
        return s.base + s.sizes.rc_off;
    }
    pub fn coloc(s: Scratch, k: usize) u64 {
        if (s.sizes.coloc_align != 0) return std.mem.alignForward(u64, s.base + s.sizes.coloc_off, s.sizes.coloc_align) + k * s.sizes.coloc;
        return s.base + s.sizes.coloc_off + k * s.sizes.coloc;
    }
    /// MEPRED buffer `k` (0, 1)
    pub fn mepred(s: Scratch, k: usize) u64 {
        return s.base + s.sizes.mepred_off + k * s.sizes.mepred;
    }
    /// AV1: kept surface `k`'s CDFs (KEPT: the discard table)
    pub fn cdf(s: Scratch, k: usize) u64 {
        return s.base + s.sizes.cdf_off + k * av1.CDF_BYTES;
    }
    pub fn defaults(s: Scratch, ctx: u2) u64 {
        return s.base + s.sizes.defaults_off + @as(usize, ctx) * av1.CDF_BYTES;
    }
    /// AV1's line buffers: 0..2 above (entropy context, motion vectors,
    /// deblocking's top row), 3..5 left (deblocking, CDEF, restoration)
    pub fn line(s: Scratch, i: usize) u64 {
        const above = s.sizes.lines.above;
        return s.base + s.sizes.lines_off + (if (i < 3) i * above else 3 * above + (i - 3) * s.sizes.lines.left);
    }
};

/// GALAXY_VA_NVENC_TRY: readings of the engine's setup for a test boot.
/// HEVC and AV1 have not encoded a picture on GB206 and nothing public
/// says which the firmware wants: pc-full8's HEVC (co-located out bound,
/// temporal MVP on) stopped with ucode error 19 COLLOC_OFFSET; pc-full9's
/// and pc-full10's (no co-located buffer, temporal MVP off) faulted the
/// engine (exception 47); AV1 (co-located in and out the same buffer, tile
/// controls at 0x400, the setup 0x800 into its frame slot) stopped with
/// ucode error 3 PICSETUP_OFFSET. A comma-separated list of the words
/// below; the defaults are the readings nvenc_drv.h's text supports.
pub const Try = struct {
    /// HEVC's co-located motion buffers. `out` (the default, the word
    /// "colocout"): out on every reference picture (nvenc_drv.h 2.2: the
    /// engine writes it for reference pictures; FORCE_OUTCOL writes it for
    /// others), in only for temporal MVP. `both` ("colocboth"): in as well
    /// on every picture (another kept entry when there is no collocated
    /// picture). `tmvp` ("coloctmvp"): both only with temporal MVP, as
    /// pc-full9 and pc-full10 did.
    hevc_coloc: enum { out, both, tmvp } = .out,
    /// AV1's tile controls: at TILE_CONTROL_OFF (0x400), or right after
    /// nvenc_av1_drv_pic_setup_s's 768 bytes ("tiles300")
    av1_tiles_at: u32 = nvenc.TILE_CONTROL_OFF,
    /// AV1's key frames bind no co-located input ("av1nocolin"); by
    /// default their own output entry is bound as the input too
    av1_key_colin: bool = true,
    /// the setup 4 KiB aligned in its frame slot ("setup4k"; the driver's)
    setup_4k: bool = false,
    /// the co-located buffers apart from the history and 1 MiB aligned
    /// (scratchSizesPlaced; the default), or packed after the history as
    /// before pc-full12 ("coloctight")
    coloc_apart: bool = true,

    /// The words of `v` (others ignored).
    pub fn parse(v: []const u8) Try {
        var t = Try{};
        var it = std.mem.tokenizeAny(u8, v, ", ");
        while (it.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, "colocout")) t.hevc_coloc = .out;
            if (std.ascii.eqlIgnoreCase(w, "colocboth")) t.hevc_coloc = .both;
            if (std.ascii.eqlIgnoreCase(w, "coloctmvp")) t.hevc_coloc = .tmvp;
            if (std.ascii.eqlIgnoreCase(w, "tiles300")) t.av1_tiles_at = nvenc.Av1.SIZE;
            if (std.ascii.eqlIgnoreCase(w, "av1nocolin")) t.av1_key_colin = false;
            if (std.ascii.eqlIgnoreCase(w, "setup4k")) t.setup_4k = true;
            if (std.ascii.eqlIgnoreCase(w, "coloctight")) t.coloc_apart = false;
        }
        return t;
    }
};

pub const EndIn = struct {
    /// the frame slot's pushbuffer and setup area (CPU, GPU)
    push: []u32,
    setup: []u8,
    setup_va: u64,
    coded: []u8,
    coded_va: u64,
    input: Input,
    lookup: codec.Lookup,
    scratch: Scratch,
    picture_index: u32,
    magic: u32 = nvenc.MAGIC,
    try_: Try = .{},
};

/// What the finished picture needs to know (kept with its coded buffer).
pub const Done = struct {
    kind: Codec = .h264,
    type: enc_rc.Type = .i,
    qp: i32 = 0,
    /// the stream's bytes the driver wrote (headers) ahead of the engine's
    header_bytes: u32 = 0,
    /// SET_PICTURE_INDEX's value (the status names it once written)
    picture_index: u32 = 0,
    /// AV1: where the frame header and the tile group's size are, the
    /// frame (for a rewrite with the engine's QP and loop-filter level),
    /// and a hidden picture to show after this one
    av1_fh_off: u32 = 0,
    av1_fh_room: u32 = 0,
    av1_tg_size_off: u32 = 0,
    av1_frame: ?av1.Frame = null,
    av1_show_existing: ?u3 = null,
};

pub const EndOut = struct {
    dwords: usize = 0,
    header_bytes: u32 = 0,
    qp: u8 = 0,
    intra: bool = false,
    done: Done = .{},
};

/// The picture's stream headers, setup and pushbuffer (EndPicture), or
/// why not.
pub fn end(st: *State, in: EndIn, out: *EndOut) va.Status {
    if (st.bad != va.SUCCESS) return st.bad;
    if (!st.have_pic or !st.have_seq or st.slices == 0) return va.ERROR_INVALID_PARAMETER;
    if (in.coded.len <= DATA_OFF + HEADER_BYTES + 4096) return va.ERROR_NOT_ENOUGH_BUFFER;
    const st_ok = switch (st.kind) {
        .h264 => h264.check(st.profile, &st.h264_seq, &st.h264_pic),
        .hevc => hevc.check(&st.hevc_seq, &st.hevc_pic),
        .av1 => av1.check(&st.av1_seq, &st.av1_pic, @as(u32, st.av1_pic.frame_width_minus_1) + 1, @as(u32, st.av1_pic.frame_height_minus_1) + 1),
    };
    if (st_ok != va.SUCCESS) return st_ok;
    const sl_ok = switch (st.kind) {
        .h264 => h264.checkSlices(st.profile, st.h264_slices[0..st.slices]),
        .hevc => hevc.checkSlices(st.hevc_slices[0..st.slices]),
        .av1 => va.SUCCESS,
    };
    if (sl_ok != va.SUCCESS) return sl_ok;
    // (B pictures only when asked for: MAX_REFS)
    if (picType(st) == .b and !st.b_frames) return va.ERROR_INVALID_PARAMETER;
    if (st.kind == .av1) return endAv1(st, in, out);
    const recon_id = reconSurface(st);
    const recon = in.lookup.surface(recon_id) orelse return va.ERROR_INVALID_SURFACE;
    if (recon.luma == in.input.own()) return va.ERROR_INVALID_SURFACE;

    // The stream: the driver's parameter sets (no packed ones came), then
    // the app's packed headers.
    const data = in.coded[DATA_OFF..];
    var n: usize = 0;
    const idr = switch (st.kind) {
        .h264 => st.h264_pic.pic_fields.idr_pic_flag != 0,
        .hevc => st.hevc_pic.pic_fields.idr_pic_flag != 0,
        .av1 => unreachable,
    };
    if (idr) st.kept.reset();
    if ((idr or st.new_seq) and !st.packed_seq) {
        switch (st.kind) {
            .h264 => {
                n += h264.writeSps(data[n..HEADER_BYTES], st.profile, &st.h264_seq) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
                n += h264.writePps(data[n..HEADER_BYTES], st.profile, &st.h264_pic) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
            },
            .hevc => {
                n += hevc.writeHeadersSized(data[n..HEADER_BYTES], &st.hevc_seq, &st.hevc_pic, st.width, st.height) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
                // (the driver's own parameter sets: their defaults)
                st.hevc_params = .{};
            },
            .av1 => unreachable,
        }
    }
    if (n + st.hdr_len > HEADER_BYTES) return va.ERROR_NOT_ENOUGH_BUFFER;
    @memcpy(data[n..][0..st.hdr_len], st.hdr[0..st.hdr_len]);
    n += st.hdr_len;

    // The references: VA's list, the engine's slots; each kept surface's
    // co-located buffer.
    const inp = in.input;
    var ref_ids = [_]u32{va.INVALID_ID} ** nvenc.REF_SLOTS;
    var ref_poc = [_]i32{0} ** nvenc.REF_SLOTS;
    var a = nvenc.PictureAddrs{
        .application_id = undefined,
        .codec_type = undefined,
        .setup = in.setup_va,
        .status = in.coded_va + STATUS_OFF,
        .bitstream = in.coded_va + SLICES_OFF,
        .history = in.scratch.history(),
        .rc_process = in.scratch.rcProcess(),
        .coloc_in = undefined,
        .coloc_out = undefined,
        .cur_luma = inp.luma,
        .cur_chroma = inp.chroma,
        .out_luma = recon.luma,
        .out_chroma = recon.chroma,
        .picture_index = in.picture_index,
    };
    switch (st.kind) {
        .h264 => for (st.h264_pic.ReferenceFrames, 0..) |r, i| {
            if (r.flags & va.PICTURE_H264_INVALID != 0 or r.picture_id == va.INVALID_ID) continue;
            const s = in.lookup.surface(r.picture_id) orelse continue;
            ref_ids[i] = r.picture_id;
            ref_poc[i] = r.TopFieldOrderCnt;
            a.ref_luma[i] = s.luma;
            a.ref_chroma[i] = s.chroma;
        },
        .hevc => for (st.hevc_pic.reference_frames, 0..) |r, i| {
            if (r.flags & va.PICTURE_HEVC_INVALID != 0 or r.picture_id == va.INVALID_ID) continue;
            const s = in.lookup.surface(r.picture_id) orelse continue;
            ref_ids[i] = r.picture_id;
            ref_poc[i] = r.pic_order_cnt;
            a.ref_luma[i] = s.luma;
            a.ref_chroma[i] = s.chroma;
        },
        .av1 => unreachable,
    }
    // the reconstruction's entry (its co-located motion goes there), and
    // the collocated picture's: B's L1[0] (H.264), the picture's
    // collocated reference (HEVC); else the first reference's
    const out_k = st.kept.take(recon_id, &ref_ids) orelse return va.ERROR_MAX_NUM_EXCEEDED;
    const col_id: u32 = switch (st.kind) {
        .h264 => blk: {
            const f = &st.h264_slices[0];
            break :blk if (f.slice_type == 1) f.ref1[0] else f.ref0[0];
        },
        .hevc => blk: {
            const p = &st.hevc_pic;
            const ci = p.collocated_ref_pic_index;
            break :blk if (ci < p.reference_frames.len and p.reference_frames[ci].flags & va.PICTURE_HEVC_INVALID == 0) p.reference_frames[ci].picture_id else st.hevc_slices[0].ref0[0];
        },
        .av1 => unreachable,
    };
    const in_k = st.kept.find(col_id) orelse out_k;
    // the co-located motion as nvenc_drv.h 3.x says: written by a
    // reference picture, read by a B picture (H.264) or by a picture whose
    // slices use HEVC's temporal motion vector prediction. H.264 without
    // B pictures (GALAXY_VA_NVENC_B unset) binds neither, as NVIDIA's
    // driver binds neither on its I and P pictures (grc); this driver
    // bound SET_OUT_COLOC_DATA on every H.264 reference before.
    const t0 = picType(st);
    const is_ref = switch (st.kind) {
        .h264 => st.h264_pic.pic_fields.reference_pic_flag != 0,
        .hevc => st.hevc_pic.pic_fields.reference_pic_flag != 0,
        .av1 => unreachable,
    };
    const tmvp_reads = st.kind == .hevc and t0 != .i and st.hevc_slices[0].temporal_mvp and hevcTemporalMvp(st);
    const reads_col = switch (st.kind) {
        .h264 => t0 == .b,
        .hevc => tmvp_reads or in.try_.hevc_coloc == .both,
        .av1 => unreachable,
    };
    // (HEVC: on every reference picture unless Try says otherwise: the
    // engine faulted without it, pc-full9 and pc-full10)
    const writes_col = is_ref and switch (st.kind) {
        .h264 => st.b_frames,
        .hevc => in.try_.hevc_coloc != .tmvp or hevcTemporalMvp(st),
        .av1 => unreachable,
    };
    // (an input with no collocated picture: another kept entry, never the
    // one being written)
    const col_k = if (in_k == out_k and !tmvp_reads) (out_k + 1) % KEPT else in_k;
    a.coloc_out = if (writes_col) in.scratch.coloc(out_k) else 0;
    a.coloc_in = if (reads_col) in.scratch.coloc(col_k) else 0;
    if (t0 != .i) motionBuffers(st, in.scratch, &a);
    for ([_]u64{ a.setup, a.status, a.bitstream, a.history, a.rc_process, a.cur_luma, a.cur_chroma, a.out_luma, a.out_chroma }) |x| {
        if (!nvenc.addressable(x)) return va.ERROR_INVALID_SURFACE;
    }
    for ([_]u64{ a.coloc_in, a.coloc_out, a.mepred_in, a.mepred_out }) |x| {
        if (x != 0 and !nvenc.addressable(x)) return va.ERROR_INVALID_SURFACE;
    }

    const room: u32 = @intCast(@min(in.coded.len - SLICES_OFF, std.math.maxInt(u32)));
    const input_planes = h264.Planes{ .luma = a.cur_luma, .chroma = a.cur_chroma, .pitch_luma = inp.pitch_luma, .pitch_chroma = inp.pitch_chroma, .block_height = inp.block_height };
    const recon_planes = h264.Planes{ .luma = recon.luma, .chroma = recon.chroma, .pitch_luma = recon.pitch_luma, .pitch_chroma = recon.pitch_chroma };
    const fps = st.rate.fps_num / @max(st.rate.fps_den, 1);
    const t = picType(st);
    var done = Done{ .kind = st.kind, .type = t, .picture_index = in.picture_index };
    switch (st.kind) {
        .h264 => {
            const pic = &st.h264_pic;
            const seq = &st.h264_seq;
            const slices = st.h264_slices[0..st.slices];
            const plan = st.rate.plan(t, @as(i32, pic.pic_init_qp) + slices[0].qp_delta);
            const qp: u8 = @intCast(std.math.clamp(plan.qp, 0, 51));
            const w = @as(u32, seq.picture_width_in_mbs) * 16;
            const h = @as(u32, seq.picture_height_in_mbs) * 16;
            if (w > inp.pitch_luma or h > inp.rows) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            h264.setup(in.setup, .{
                .profile = st.profile,
                .seq = seq,
                .pic = pic,
                .slices = slices,
                .width = w,
                .height = h,
                .input = input_planes,
                .recon = recon_planes,
                .ref_ids = ref_ids,
                .ref_poc = ref_poc,
                .qp = qp,
                .gop_length = if (seq.intra_period != 0) seq.intra_period else 0xffff_ffff,
                .framerate = fps,
                .bitstream_start = 0,
                .bitstream_room = room,
                .history_bytes = @intCast(in.scratch.sizes.history),
                .magic = in.magic,
            });
            a.application_id = nvenc.APPLICATION_ID_H264;
            a.codec_type = nvenc.CODEC_TYPE_H264;
            if (st.firmware_rc and st.rate.active()) a.rc_mode = firmware(st, in, enc_rc.RcFields.of(nvenc.H264), qp);
            done.qp = qp;
        },
        .hevc => {
            const pic = &st.hevc_pic;
            const seq = &st.hevc_seq;
            const slices = st.hevc_slices[0..st.slices];
            const plan = st.rate.plan(t, @as(i32, pic.pic_init_qp) + slices[0].qp_delta);
            const qp: u8 = @intCast(std.math.clamp(plan.qp, 0, 51));
            if (seq.pic_width_in_luma_samples > inp.pitch_luma or seq.pic_height_in_luma_samples > inp.rows) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            hevc.setup(in.setup, .{
                .seq = seq,
                .pic = pic,
                .slices = slices,
                .input = input_planes,
                .recon = recon_planes,
                .ref_ids = ref_ids,
                .ref_poc = ref_poc,
                .params = st.hevc_params,
                .collocated_id = col_id,
                .qp = qp,
                .gop_length = if (seq.intra_period != 0) seq.intra_period else 0xffff_ffff,
                .framerate = fps,
                .bitstream_start = 0,
                .bitstream_room = room,
                .history_bytes = @intCast(in.scratch.sizes.history),
                .magic = in.magic,
            });
            a.application_id = nvenc.APPLICATION_ID_H265;
            a.codec_type = nvenc.CODEC_TYPE_H265;
            if (st.firmware_rc and st.rate.active()) a.rc_mode = firmware(st, in, enc_rc.RcFields.of(nvenc.H265), qp);
            done.qp = qp;
        },
        .av1 => unreachable,
    }
    // the headers end where the engine's slices begin
    placeHeaders(in.coded, n);
    // a clean status (its picture index poisoned: unwritten, it says so),
    // an empty segment until the engine is done
    clearStatus(in.coded, in.picture_index);
    out.dwords = nvenc.push(in.push, a);
    out.header_bytes = @intCast(n);
    out.qp = @intCast(done.qp);
    out.intra = t == .i;
    done.header_bytes = @intCast(n);
    out.done = done;
    st.pictures += 1;
    return va.SUCCESS;
}

/// AV1's EndPicture (`end`'s checks done): the OBUs ahead of the engine's
/// tile data, the references and CDFs, the setup and the pushbuffer.
fn endAv1(st: *State, in: EndIn, out: *EndOut) va.Status {
    const pic = &st.av1_pic;
    const seq = &st.av1_seq;
    const as = &st.av1_state;
    const width = @as(u32, pic.frame_width_minus_1) + 1;
    const height = @as(u32, pic.frame_height_minus_1) + 1;
    const recon_id = pic.reconstructed_frame;
    const recon = in.lookup.surface(recon_id) orelse return va.ERROR_INVALID_SURFACE;
    const inp = in.input;
    if (recon.luma == inp.own()) return va.ERROR_INVALID_SURFACE;
    if (width > inp.pitch_luma or height > inp.rows) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
    const key = pic.picture_flags.frame_type == 0;
    if (key) as.hidden = null;

    // shown? the app's packed frame header says; else a picture whose
    // order hint runs ahead of the next to show is hidden
    var show = true;
    var showable = false;
    if (st.av1_shown) |sh| {
        show = sh;
        showable = st.av1_showable;
    } else if (!key and pic.order_hint != as.last_shown +% 1) {
        const ahead = @as(i8, @bitCast(pic.order_hint -% as.last_shown));
        if (ahead > 1) {
            show = false;
            showable = true;
        }
    }
    const t = av1.rcType(pic);
    const plan = st.rate.plan(t, pic.base_qindex);
    const q: u8 = @intCast(std.math.clamp(plan.qp, 1, 255));
    const frame = av1.frameOf(seq, pic, q, show, showable, as.slot_hint);

    // The stream: a temporal delimiter (a new temporal unit), the
    // sequence header at a key frame (the app's, or the driver's), the
    // app's other OBUs, the frame header (room for a rewrite), the tile
    // group's header.
    const data = in.coded[DATA_OFF..];
    var n: usize = 0;
    if (as.prev_shown) n += av1.temporalDelimiter(data[n..]);
    if ((key or st.new_seq) and !st.packed_seq) {
        n += av1.sequenceHeaderObu(data[n..HEADER_BYTES], seq, width, height) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
    }
    if (n + st.hdr_len > HEADER_BYTES) return va.ERROR_NOT_ENOUGH_BUFFER;
    @memcpy(data[n..][0..st.hdr_len], st.hdr[0..st.hdr_len]);
    n += st.hdr_len;
    var probe: [512]u8 = undefined;
    const plain = av1.frameHeaderObu(&probe, frame, 0) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
    const fh_room: u32 = @intCast(plain - 5 + 2);
    const fh_off: u32 = @intCast(n);
    n += av1.frameHeaderObu(data[n..HEADER_BYTES], frame, fh_room) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
    if (n + 5 > HEADER_BYTES) return va.ERROR_NOT_ENOUGH_BUFFER;
    data[n] = av1.obuHeader(av1.OBU_TILE_GROUP);
    av1.leb128Fixed(data[n + 1 ..][0..4], 0);
    const tg_size_off: u32 = @intCast(n + 1);
    n += 5;

    // The references (VA's slots are the engine's), the kept surfaces'
    // CDFs: the primary reference's, else the defaults for the quantiser.
    var ref_ids = [_]u32{va.INVALID_ID} ** 8;
    var a = nvenc.PictureAddrs{
        .application_id = nvenc.APPLICATION_ID_AV1,
        .codec_type = nvenc.CODEC_TYPE_AV1,
        .setup = in.setup_va,
        .status = in.coded_va + STATUS_OFF,
        .bitstream = in.coded_va + SLICES_OFF,
        .history = in.scratch.history(),
        .rc_process = in.scratch.rcProcess(),
        .coloc_in = undefined,
        .coloc_out = undefined,
        .cur_luma = inp.luma,
        .cur_chroma = inp.chroma,
        .out_luma = recon.luma,
        .out_chroma = recon.chroma,
        .picture_index = in.picture_index,
    };
    for (pic.reference_frames, 0..) |id, i| {
        if (id == va.INVALID_ID) continue;
        const s = in.lookup.surface(id) orelse continue;
        ref_ids[i] = id;
        a.ref_luma[i] = s.luma;
        a.ref_chroma[i] = s.chroma;
    }
    const out_k = st.kept.take(recon_id, &ref_ids) orelse return va.ERROR_MAX_NUM_EXCEEDED;
    if (!as.defaults_written) {
        for (0..4) |ctx| av1.writeDefaults(in.scratch.cpu[in.scratch.sizes.defaults_off + ctx * av1.CDF_BYTES ..][0..av1.CDF_BYTES], @intCast(ctx));
        as.defaults_written = true;
    }
    var prob_in = in.scratch.defaults(av1.qContext(q));
    if (!frame.intra() and !frame.error_resilient and frame.primary_ref_frame != av1.NONE) {
        const src = pic.reference_frames[frame.ref_frame_idx[frame.primary_ref_frame]];
        if (st.kept.find(src)) |k| prob_in = in.scratch.cdf(k);
    }
    // the co-located motion: this picture's own entry out; in, LAST's
    // (the first reference's) on an inter picture, else its own
    var col_k = out_k;
    if (!frame.intra()) {
        if (st.kept.find(pic.reference_frames[frame.ref_frame_idx[0]])) |k| col_k = k;
        motionBuffers(st, in.scratch, &a);
    }
    a.coloc_in = if (frame.intra() and !in.try_.av1_key_colin) 0 else in.scratch.coloc(col_k);
    a.coloc_out = in.scratch.coloc(out_k);
    a.av1 = .{
        .prob_in = prob_in,
        .prob_out = in.scratch.cdf(out_k),
        .above_ctx = in.scratch.line(0),
        .above_mv = in.scratch.line(1),
        .deblock_top = in.scratch.line(2),
        .deblock_left = in.scratch.line(3),
        .cdef_left = in.scratch.line(4),
        .lr_left = in.scratch.line(5),
    };
    for ([_]u64{ a.setup, a.status, a.bitstream, a.history, a.rc_process, a.cur_luma, a.cur_chroma, a.out_luma, a.out_chroma, a.av1.?.prob_in, a.av1.?.lr_left }) |x| {
        if (!nvenc.addressable(x)) return va.ERROR_INVALID_SURFACE;
    }
    if (a.coloc_in != 0 and !nvenc.addressable(a.coloc_in)) return va.ERROR_INVALID_SURFACE;
    if (a.mepred_in != 0 and !nvenc.addressable(a.mepred_out)) return va.ERROR_INVALID_SURFACE;
    const room: u32 = @intCast(@min(in.coded.len - SLICES_OFF, std.math.maxInt(u32)));
    av1.setup(in.setup, .{
        .frame = frame,
        .pic = pic,
        .input = .{ .luma = inp.luma, .chroma = inp.chroma, .pitch_luma = inp.pitch_luma, .pitch_chroma = inp.pitch_chroma, .block_height = inp.block_height },
        .recon = .{ .luma = recon.luma, .chroma = recon.chroma, .pitch_luma = recon.pitch_luma, .pitch_chroma = recon.pitch_chroma },
        .ref_ids = ref_ids,
        .framerate = st.rate.fps_num / @max(st.rate.fps_den, 1),
        .gop_length = if (seq.intra_period != 0) seq.intra_period else 0xffff_ffff,
        .bitstream_start = 0,
        .bitstream_room = room,
        .history_bytes = @intCast(in.scratch.sizes.history),
        .magic = in.magic,
        .tiles_at = in.try_.av1_tiles_at,
    });
    if (st.firmware_rc and st.rate.active()) a.rc_mode = firmware(st, in, enc_rc.RcFields.of(nvenc.Av1), q);

    // After it: the slots it refreshes hold its order hint; shown, or
    // hidden until the picture before it is out (then shown with a
    // show_existing_frame, unless the app packs its own headers).
    var done = Done{ .kind = .av1, .type = t, .qp = q, .header_bytes = @intCast(n), .picture_index = in.picture_index, .av1_fh_off = fh_off, .av1_fh_room = fh_room, .av1_tg_size_off = tg_size_off, .av1_frame = frame };
    var first_slot: ?u3 = null;
    for (0..8) |i| {
        if (frame.refresh & (@as(u8, 1) << @intCast(i)) == 0) continue;
        as.slot_hint[i] = frame.order_hint;
        if (first_slot == null) first_slot = @intCast(i);
    }
    if (show) {
        as.last_shown = frame.order_hint;
        if (st.av1_shown == null) {
            if (as.hidden) |h| {
                if (h.hint == frame.order_hint +% 1) {
                    done.av1_show_existing = h.slot;
                    as.last_shown = h.hint;
                    as.hidden = null;
                }
            }
        }
    } else if (first_slot) |slot| {
        as.hidden = .{ .slot = slot, .hint = frame.order_hint };
    }
    as.prev_shown = show;

    placeHeaders(in.coded, n);
    clearStatus(in.coded, in.picture_index);
    out.dwords = nvenc.push(in.push, a);
    out.header_bytes = @intCast(n);
    out.qp = q;
    out.intra = t == .i;
    out.done = done;
    st.pictures += 1;
    return va.SUCCESS;
}

/// The `n` bytes of headers written at the headers' room's start moved
/// to its end, against the engine's slices (SLICES_OFF).
fn placeHeaders(coded: []u8, n: usize) void {
    const room = coded[DATA_OFF..SLICES_OFF];
    if (n != 0) std.mem.copyBackwards(u8, room[HEADER_BYTES - n ..], room[0..n]);
}

/// Where the stream of a picture with `header_bytes` of headers begins in
/// its coded buffer.
pub fn streamOff(header_bytes: u32) usize {
    return SLICES_OFF - header_bytes;
}

/// The status cleared, its picture index poisoned; the segment empty.
fn clearStatus(coded: []u8, picture_index: u32) void {
    @memset(coded[STATUS_OFF..DATA_OFF], 0);
    std.mem.writeInt(u32, coded[STATUS_OFF..][0..4], nvenc.statusPoison(picture_index), .little);
    @memset(coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], 0);
}

/// An inter picture's MEPRED buffers, as NVIDIA's driver binds them: the
/// one the last inter picture wrote in, the other out; they swap.
fn motionBuffers(st: *State, scratch: Scratch, a: *nvenc.PictureAddrs) void {
    if (scratch.sizes.mepred == 0) return;
    const w = st.mepred_flip;
    a.mepred_out = scratch.mepred(w);
    a.mepred_in = scratch.mepred(w ^ 1);
    st.mepred_flip = w ^ 1;
}

/// AV1's picture done (`n` bytes so far: the OBUs and the tile data): the
/// tile group's size patched; the frame header rewritten if the engine
/// reports another QP or loop-filter level than it was given; a hidden
/// picture's show_existing_frame after it. The bytes now.
fn finishAv1(stream: []u8, n0: usize, r: nvenc.Result, done: Done) usize {
    var n = n0;
    if (done.av1_tg_size_off + 4 > stream.len) return n;
    av1.leb128Fixed(stream[done.av1_tg_size_off..][0..4], @intCast(@min(n - done.header_bytes, std.math.maxInt(u28))));
    if (done.av1_frame) |f0| {
        var f = f0;
        var changed = false;
        if (r.av1_qindex != 0 and r.av1_qindex != f.qindex) {
            f.qindex = @intCast(r.av1_qindex);
            changed = true;
        }
        if (r.av1_lf_level != f.lf[0] and !(r.av1_lf_level == 0 and f.lf[0] == 0)) {
            const l: u6 = @intCast(@min(r.av1_lf_level, 63));
            f.lf = .{ l, l, if (l == 0) 0 else f.lf[2], if (l == 0) 0 else f.lf[3] };
            changed = true;
        }
        if (changed) {
            var tmp: [512]u8 = undefined;
            if (av1.frameHeaderObu(&tmp, f, done.av1_fh_room)) |m| {
                if (m == 5 + done.av1_fh_room) @memcpy(stream[done.av1_fh_off..][0..m], tmp[0..m]);
            }
        }
    }
    if (done.av1_show_existing) |slot| {
        if (n + 5 <= stream.len) {
            n += av1.temporalDelimiter(stream[n..]);
            n += av1.showExistingObu(stream[n..], slot);
        }
    }
    return n;
}

/// The firmware's rate control (GALAXY_VA_NVENC_RC=firmware): its struct
/// over the driver's QPs, its state started once. Its RCMODE.
fn firmware(st: *State, in: EndIn, f: enc_rc.RcFields, qp: u8) u32 {
    if (!st.firmware_rc_started) {
        const at = in.scratch.sizes.rc_off;
        enc_rc.firmwareState(in.scratch.cpu[at..][0..nvenc.Persistent.SIZE], &st.rate);
        st.firmware_rc_started = true;
    }
    const q: i32 = qp;
    const b_frames = if (st.rate.ip_period > 1) st.rate.ip_period - 1 else 0;
    return enc_rc.firmwareSetup(in.setup, f, &st.rate, .{ q, q + 2, q - 2 }, b_frames);
}

/// What a finished picture came to.
pub const Finished = struct {
    bytes: u32,
    result: nvenc.Result,
    overflow: bool,
    pad_bytes: u32 = 0,
};

/// The engine is done with the picture in `coded` (`done` says what it
/// was): the segment vaMapBuffer returns, filled; the rate control (its
/// context's, if it still has one) told; CBR's filler appended.
pub fn finish(st: ?*State, coded: []u8, done: Done) Finished {
    const r = statusOf(coded, done.kind);
    if (coded.len < SLICES_OFF or done.header_bytes > HEADER_BYTES) {
        // (no picture of end()'s fits: nothing to say)
        emptySegment(coded);
        return .{ .bytes = 0, .result = r, .overflow = false };
    }
    const header_bytes = done.header_bytes;
    const at = streamOff(header_bytes);
    const stream = coded[at..];
    const room = stream.len;
    var n: usize = header_bytes + @as(usize, r.bytes());
    const overflow = n > room;
    if (overflow) n = room;
    if (r.failed()) n = header_bytes;
    if (done.kind == .av1 and !r.failed()) n = finishAv1(stream, n, r, done);
    var pad_bytes: u32 = 0;
    // (a lost picture is not the rate control's to learn from: told it
    // was the headers' size, it took the QP down to 1 on every one of
    // them, pc-1111h)
    if (st != null and !r.failed()) {
        const s = st.?;
        const pad = s.rate.done(done.type, @as(u64, n) * 8, done.qp, r.intra_cost, r.inter_cost);
        if (pad > 0) {
            const want: usize = @intCast(pad / 8);
            pad_bytes = @intCast(filler(stream, n, want, done.kind));
            n += pad_bytes;
        }
    }
    var seg = std.mem.zeroes(ve.CodedBufferSegment);
    seg.size = @intCast(n);
    seg.status = if (overflow) ve.CODED_BUF_STATUS_SLICE_OVERFLOW_MASK else 0;
    seg.buf = coded.ptr + at;
    seg.next = null;
    @memcpy(coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], std.mem.asBytes(&seg));
    return .{ .bytes = @intCast(n), .result = r, .overflow = overflow, .pad_bytes = pad_bytes };
}

/// The engine's status of the picture in `coded` (the codec's struct).
pub fn statusOf(coded: []const u8, kind: Codec) nvenc.Result {
    return nvenc.Result.ofKind(coded[STATUS_OFF..][0..nvenc.Stat.SIZE], switch (kind) {
        .h264 => .h264,
        .hevc => .hevc,
        .av1 => .av1,
    });
}

/// A context's pictures as the engine reported them (for the driver's
/// lines: the first pictures and every failure said, the rest counted).
pub const Tally = struct {
    pictures: u32 = 0,
    encoded: u32 = 0,
    failed: u32 = 0,
    /// pictures whose status the engine never wrote (its index unchanged)
    unwritten: u32 = 0,
    /// pictures lost with the channel
    lost: u32 = 0,
    slice_bytes: u64 = 0,
    said: u32 = 0,
    first_failed: u32 = 0,
    first_ucode: u32 = 0,
    last_ucode: u32 = 0,
    /// pictures said in full: the first SAY_FIRST, then failures up to
    /// SAY_MAX lines in all
    pub const SAY_FIRST = 4;
    pub const SAY_MAX = 24;

    /// The picture `done` counted; whether to say it.
    pub fn count(t: *Tally, done: Done, r: nvenc.Result) bool {
        t.pictures += 1;
        if (!r.written(done.picture_index)) t.unwritten += 1;
        if (r.failed()) {
            if (t.failed == 0) {
                t.first_failed = done.picture_index;
                t.first_ucode = r.ucode_error;
            }
            t.failed += 1;
            t.last_ucode = r.ucode_error;
        } else {
            t.encoded += 1;
            t.slice_bytes += r.bytes();
        }
        const say = t.said < SAY_MAX and (t.pictures <= SAY_FIRST or r.failed());
        if (say) t.said += 1;
        return say;
    }

    /// The context's pictures in one line.
    pub fn line(t: *const Tally, buf: []u8, kind: Codec) []const u8 {
        return std.fmt.bufPrint(buf, "{s} encode context done: {d} pictures, {d} encoded ({d} B of slices), {d} failed (the first: picture {d}, ucode error {d} {s}; the last's {d} {s}), {d} statuses never written, {d} lost with the channel", .{
            @tagName(kind), t.pictures,                         t.encoded,     t.slice_bytes,
            t.failed,       t.first_failed,                     t.first_ucode, nvenc.ucodeErrorName(t.first_ucode),
            t.last_ucode,   nvenc.ucodeErrorName(t.last_ucode), t.unwritten,   t.lost,
        }) catch buf[0..0];
    }
};

/// A picture's setup in a line (the first picture's, for the boot log):
/// the magic, the three surfaces' sizes, the controls' offsets, the
/// bitstream's start and room, the history, the strip.
pub fn setupLine(buf: []u8, kind: Codec, setup: []const u8) []const u8 {
    const g = nvenc.get;
    return switch (kind) {
        .h264 => blk: {
            const H = nvenc.H264;
            break :blk std.fmt.bufPrint(buf, "h264 setup: magic {x}, input {d}x{d} pitch {d} block height {d}, recon {d}x{d} pitch {d}, pic_type {d}, slice mode {d} max {d}, controls slice {x} md {x} q {x} me {x}, start {d} room {d}, history {d}, strips {d} rows {d}, stats {x}/{x}, timer {d}", .{
                g(setup, H.magic),                                g(setup, H.input_cfg_frame_width_minus1) + 1,      g(setup, H.input_cfg_frame_height_minus1) + 1, g(setup, H.input_cfg_sfc_pitch), g(setup, H.input_cfg_block_height),
                g(setup, H.outputpic_cfg_frame_width_minus1) + 1, g(setup, H.outputpic_cfg_frame_height_minus1) + 1, g(setup, H.outputpic_cfg_sfc_pitch),           g(setup, H.pic_type),            g(setup, H.slice_mode),
                g(setup, H.max_slice_size),                       g(setup, H.slice_control_offset),                  g(setup, H.md_control_offset),                 g(setup, H.q_control_offset),    g(setup, H.me_control_offset),
                g(setup, H.bitstream_start_pos),                  g(setup, H.bitstream_buf_size),                    g(setup, H.hist_buf_size),                     g(setup, H.strips_in_frame),     g(setup, H.slice_encoding_row_num),
                g(setup, H.slice_stat_offset),                    g(setup, H.mpec_stat_offset),                      g(setup, H.gp_timer_timeout_val),
            }) catch buf[0..0];
        },
        .hevc => blk: {
            const H = nvenc.H265;
            break :blk std.fmt.bufPrint(buf, "hevc setup: magic {x}, input {d}x{d} pitch {d} block height {d}, recon {d}x{d} pitch {d}, pic_type {d} nal {d}, cu {d}..{d} tu {d}..{d}, controls slice {x} md {x} q {x} me {x}, start {d} room {d}, history {d}, ctbs log2 {d}, strips {d} rows {d}, timer {d}", .{
                g(setup, H.magic),                                g(setup, H.input_cfg_frame_width_minus1) + 1,      g(setup, H.input_cfg_frame_height_minus1) + 1, g(setup, H.input_cfg_sfc_pitch),    g(setup, H.input_cfg_block_height),
                g(setup, H.outputpic_cfg_frame_width_minus1) + 1, g(setup, H.outputpic_cfg_frame_height_minus1) + 1, g(setup, H.outputpic_cfg_sfc_pitch),           g(setup, H.pic_type),               g(setup, H.nal_unit_type),
                g(setup, H.min_cu_size),                          g(setup, H.max_cu_size),                           g(setup, H.min_tu_size),                       g(setup, H.max_tu_size),            g(setup, H.slice_control_offset),
                g(setup, H.md_control_offset),                    g(setup, H.q_control_offset),                      g(setup, H.me_control_offset),                 g(setup, H.bitstream_start_pos),    g(setup, H.bitstream_buf_size),
                g(setup, H.hist_buf_size),                        g(setup, H.ceil_log2_pic_size_in_ctbs),            g(setup, H.strips_in_frame),                   g(setup, H.slice_encoding_row_num), g(setup, H.gp_timer_timeout_val),
            }) catch buf[0..0];
        },
        .av1 => blk: {
            const A = nvenc.Av1;
            break :blk std.fmt.bufPrint(buf, "av1 setup: magic {x}, input {d}x{d} pitch {d}, frame type {d}, tiles at {x}, start {d} room {d}, history {d}, strips {d} ({d}x{d} SBs), timer {d}", .{
                g(setup, A.magic),               g(setup, A.input_cfg_frame_width_minus1) + 1, g(setup, A.input_cfg_frame_height_minus1) + 1, g(setup, A.input_cfg_sfc_pitch), g(setup, A.frame_type),
                g(setup, A.tile_control_offset), g(setup, A.bitstream_start_pos),              g(setup, A.bitstream_buf_size),                g(setup, A.hist_buf_size),       g(setup, A.strips_in_frame),
                g(setup, A.strip_width_in_sbs),  g(setup, A.strip_height_in_sbs),              g(setup, A.gp_timer_timeout_val),
            }) catch buf[0..0];
        },
    };
}

/// A picture's pushbuffer as methods and values in a line ("700=1103 ...").
pub fn pushLine(buf: []u8, push: []const u32) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i + 1 < push.len) : (i += 2) {
        const m = (push[i] & 0x1fff) << 2;
        const s = std.fmt.bufPrint(buf[w..], "{x}={x} ", .{ m, push[i + 1] }) catch break;
        w += s.len;
    }
    return buf[0..w];
}

/// What the engine said of one picture, in a line: whether it wrote the
/// status at all (the picture index came back), its error words (and
/// their names), the bits it reports, where it says it wrote them, its
/// counts.
pub fn reportLine(buf: []u8, done: Done, r: nvenc.Result) []const u8 {
    const t = switch (done.type) {
        .i => "I",
        .p => "P",
        .b => "B",
    };
    const verdict = if (!r.written(done.picture_index)) "NO STATUS (the engine never wrote it)" else if (r.failed()) "FAILED" else "encoded";
    return std.fmt.bufPrint(buf, "{s} picture {d} ({s}, QP {d}): {s}; status index {x}, error_status {d} (2 is routine), ucode error {d} {s}; {d} bits ({d} B of slices after {d} B of headers), slices {d}, avg QP {d}, start {d}, last valid {d}, intra/inter {d}/{d}, cycles {d}", .{
        @tagName(done.kind),                 done.picture_index, t,              done.qp,
        verdict,                             r.picture_index,    r.error_status, r.ucode_error,
        nvenc.ucodeErrorName(r.ucode_error), r.bits,             r.bytes(),      done.header_bytes,
        r.slices,                            r.avg_qp,           r.start,        r.last_valid,
        r.intra_count,                       r.inter_count,      r.cycles,
    }) catch buf[0..0];
}

/// A filler data NAL unit of about `want` bytes after the `at` bytes of
/// `stream` (H.264's type 12, HEVC's FD_NUT 38: 0xff bytes and the RBSP's
/// stop bit), as much as fits: its length.
pub fn filler(stream: []u8, at: usize, want: usize, kind: Codec) usize {
    const head: []const u8 = switch (kind) {
        .h264 => &.{ 0, 0, 0, 1, 0x0c },
        .hevc => &.{ 0, 0, 0, 1, 0x4c, 0x01 },
        .av1 => return av1.paddingObu(stream[@min(at, stream.len)..], want),
    };
    if (want < head.len + 1 or at + head.len + 1 > stream.len) return 0;
    const len = @min(want, stream.len - at);
    @memcpy(stream[at..][0..head.len], head);
    @memset(stream[at + head.len ..][0 .. len - head.len - 1], 0xff);
    stream[at + len - 1] = 0x80;
    return len;
}

/// An empty segment (a coded buffer never encoded into, or lost).
pub fn emptySegment(coded: []u8) void {
    var seg = std.mem.zeroes(ve.CodedBufferSegment);
    seg.buf = coded.ptr + DATA_OFF;
    @memcpy(coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], std.mem.asBytes(&seg));
}

/// The context's scratch: history (a block for every macroblock of the
/// picture and a row more, as NVIDIA's driver gives it:
/// nvenc.historyBytes; AV1's own sizing when that is more), KEPT
/// co-located buffers (64 bytes a macroblock), the rate control's state,
/// the two MEPRED buffers (nvenc.MEPRED_BYTES_PER_MB).
pub const ScratchSizes = struct {
    history: usize,
    history_off: usize = 0,
    coloc: usize,
    coloc_off: usize,
    /// the co-located buffers apart (Try.coloc_apart): each this aligned
    /// by its GPU address (the scratch keeps room to align the first);
    /// 0, packed after the history
    coloc_align: usize = 0,
    rc: usize,
    rc_off: usize,
    mepred: usize = 0,
    mepred_off: usize = 0,
    /// AV1: KEPT + 1 CDF tables (the last a discard), the four default
    /// tables, the line buffers
    cdf_off: usize = 0,
    defaults_off: usize = 0,
    lines: av1.Lines = .{ .above = 0, .left = 0, .history = 0 },
    lines_off: usize = 0,
    total: usize,
};

pub fn scratchSizes(width: u32, height: u32) ScratchSizes {
    return scratchSizesFor(.h264, width, height);
}

/// How far apart (and aligned) the co-located buffers go with
/// Try.coloc_apart.
pub const COLOC_APART: usize = 1 << 20;

pub fn scratchSizesFor(kind: Codec, width: u32, height: u32) ScratchSizes {
    return scratchSizesPlaced(kind, width, height, false);
}

/// The scratch's layout; `apart`: the co-located buffers last, each
/// COLOC_APART aligned by GPU address and that long, clear of the history
/// whatever the engine takes it to need (Try.coloc_apart: HEVC's
/// co-located output packed after the history, 8 KiB aligned, stopped
/// with COLLOC_OFFSET on pc-full8 and pc-full11).
pub fn scratchSizesPlaced(kind: Codec, width: u32, height: u32, apart: bool) ScratchSizes {
    const wmbs: usize = (width + 15) / 16;
    const hmbs: usize = (height + 15) / 16;
    const lines = av1.Lines.of(width, height);
    const history = if (kind == .av1) @max(lines.history, nvenc.historyBytes(wmbs, hmbs)) else nvenc.historyBytes(wmbs, hmbs);
    const coloc = std.mem.alignForward(usize, wmbs * hmbs * 64, 4096);
    const rc: usize = 4096;
    const coloc_off = history;
    const rc_off = coloc_off + KEPT * coloc;
    const mepred = std.mem.alignForward(usize, wmbs * hmbs * nvenc.MEPRED_BYTES_PER_MB, 4096);
    const mepred_off = rc_off + rc;
    var s = ScratchSizes{ .history = history, .coloc = coloc, .coloc_off = coloc_off, .rc = rc, .rc_off = rc_off, .mepred = mepred, .mepred_off = mepred_off, .total = mepred_off + 2 * mepred };
    if (kind == .av1) {
        s.cdf_off = s.total;
        s.defaults_off = s.cdf_off + (KEPT + 1) * av1.CDF_BYTES;
        s.lines_off = s.defaults_off + 4 * av1.CDF_BYTES;
        s.lines = lines;
        s.total = s.lines_off + 3 * lines.above + 3 * lines.left;
    }
    if (apart) {
        // (the rest moved down over where the co-located buffers were)
        const gap = KEPT * coloc;
        s.rc_off -= gap;
        s.mepred_off -= gap;
        if (kind == .av1) {
            s.cdf_off -= gap;
            s.defaults_off -= gap;
            s.lines_off -= gap;
        }
        s.total -= gap;
        s.coloc = std.mem.alignForward(usize, coloc, COLOC_APART);
        s.coloc_off = std.mem.alignForward(usize, s.total, 4096);
        s.coloc_align = COLOC_APART;
        s.total = s.coloc_off + COLOC_APART + KEPT * s.coloc;
    }
    return s;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "encode: rate control holds a CBR stream near its target" {
    var st = State.init(.h264, va.PROFILE_H264_MAIN, 640, 480, ve.RC_CBR, 0);
    st.rate.rateControl(3_000_000, 100, 30, 0, 0);
    st.rate.frameRate(30, 1);
    st.rate.hrd(600_000, 300_000);
    // pictures twice too big: the QP climbs
    var q = st.rate.plan(.p, 0).qp;
    // (near the app's initial QP, the buffer's start allowing)
    try testing.expect(q >= 10 and q <= 32);
    const first = q;
    for (0..5) |_| {
        _ = st.rate.done(.p, 200_000, q, 0, 0);
        q = st.rate.plan(.p, 0).qp;
    }
    try testing.expect(q > first);
    // then far too small: it comes back down
    const high = q;
    for (0..40) |_| {
        _ = st.rate.done(.p, 10_000, q, 0, 0);
        q = st.rate.plan(.p, 0).qp;
    }
    try testing.expect(q < high);
    // CQP: the app's QP, untouched
    var c = enc_rc.Controller{};
    try testing.expectEqual(@as(i32, 22), c.plan(.p, 22).qp);
}

test "encode: packed headers without emulation bytes get them" {
    const data = [_]u8{ 0, 0, 1, 0x06, 0, 0, 1, 0x80, 0, 0, 0, 0x10 };
    var out: [32]u8 = undefined;
    const n = emulate(&out, &data, 1).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x06, 0, 0, 3, 1, 0x80, 0, 0, 3, 0, 0x10 }, out[0..n]);
    // (HEVC: a two-byte header left alone)
    const hd = [_]u8{ 0, 0, 0, 1, 0x40, 0x01, 0, 0, 2 };
    const m = emulate(&out, &hd, 2).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x40, 0x01, 0, 0, 3, 2 }, out[0..m]);
}

test "encode: a finished picture's segment, and CBR's filler" {
    var coded: [SLICES_OFF + 64]u8 align(16) = undefined;
    @memset(&coded, 0);
    var st = State.init(.h264, va.PROFILE_H264_MAIN, 48, 32, ve.RC_CQP, 0);
    // (error_status 2, as on every picture of NVIDIA's own: no failure)
    std.mem.writeInt(u32, coded[STATUS_OFF + 4 ..][0..4], 2, .little);
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 20 * 8 + 3, .little);
    const f = finish(&st, &coded, .{ .header_bytes = 30 });
    try testing.expectEqual(@as(u32, 51), f.bytes);
    try testing.expect(!f.overflow and !f.result.failed());
    const seg = std.mem.bytesToValue(ve.CodedBufferSegment, coded[0..@sizeOf(ve.CodedBufferSegment)]);
    try testing.expectEqual(@as(u32, 51), seg.size);
    // (the stream: the 30 bytes of headers right before the engine's
    // slices)
    try testing.expectEqual(@intFromPtr(&coded) + SLICES_OFF - 30, @intFromPtr(seg.buf.?));
    try testing.expectEqual(@as(?*anyopaque, null), seg.next);
    // too big for the buffer: cut, and said
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 1000 * 8, .little);
    const g = finish(&st, &coded, .{ .header_bytes = 30, .type = .p });
    try testing.expect(g.overflow);
    try testing.expectEqual(@as(u32, 30 + 64), g.bytes);
    // a ucode error, or no bits: the headers alone, the rate control not
    // told
    const frames = st.rate.frames;
    std.mem.writeInt(u32, coded[STATUS_OFF + 4 ..][0..4], 2 | (13 << 2), .little);
    const h = finish(&st, &coded, .{ .header_bytes = 30, .type = .p });
    try testing.expect(h.result.failed());
    try testing.expectEqual(@as(u32, 30), h.bytes);
    try testing.expectEqual(@as(u32, 13), h.result.ucode_error);
    std.mem.writeInt(u32, coded[STATUS_OFF + 4 ..][0..4], 2, .little);
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 0, .little);
    try testing.expect(finish(&st, &coded, .{ .header_bytes = 30, .type = .p }).result.failed());
    try testing.expectEqual(frames, st.rate.frames);
    // (a buffer too small for any picture: an empty segment)
    var tiny: [DATA_OFF + 64]u8 align(16) = undefined;
    @memset(&tiny, 0);
    try testing.expectEqual(@as(u32, 0), finish(null, &tiny, .{ .header_bytes = 30 }).bytes);
    // a filler NAL unit
    var s: [32]u8 = undefined;
    const n = filler(&s, 4, 12, .h264);
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x0c, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x80 }, s[4..16]);
    try testing.expectEqual(@as(usize, 0), filler(&s, 30, 12, .hevc));
}

var b_coded: [DATA_OFF + HEADER_BYTES + 8192]u8 = undefined;

test "encode: no B pictures unless asked for (GALAXY_VA_NVENC_B=1): no L1 offered, a B picture refused" {
    try testing.expectEqual(@as(u32, h264.MAX_L0), maxRefs(va.PROFILE_H264_HIGH, false));
    try testing.expectEqual(@as(u32, h264.MAX_L0 | (h264.MAX_L1 << 16)), maxRefs(va.PROFILE_H264_HIGH, true));
    try testing.expectEqual(@as(u32, av1.MAX_L0), maxRefs(av1.PROFILE, false));
    try testing.expectEqual(@as(u32, av1.MAX_L0 | (av1.MAX_L1 << 16)), maxRefs(av1.PROFILE, true));
    var st = State.init(.h264, va.PROFILE_H264_MAIN, 48, 32, ve.RC_CQP, 0);
    st.h264_seq = h264.testSeq(3, 2);
    st.h264_pic = h264.testPic(0x402, 0x1000, false, 2);
    st.have_seq = true;
    st.have_pic = true;
    st.h264_slices[0] = .{ .num_mb = 6, .slice_type = 1 };
    st.slices = 1;
    var out: EndOut = .{};
    const in = EndIn{
        .push = undefined,
        .setup = undefined,
        .setup_va = 0,
        .coded = &b_coded,
        .coded_va = 0,
        .input = undefined,
        .lookup = undefined,
        .scratch = undefined,
        .picture_index = 0,
    };
    try testing.expectEqual(va.ERROR_INVALID_PARAMETER, end(&st, in, &out));
    try testing.expectEqual(@as(u32, 0), st.pictures);
}

test "encode: HEVC binds a co-located buffer only for a sequence with temporal MVP, which the features do not offer" {
    try testing.expectEqual(@as(u32, 0), hevc.FEATURES & hevc.FEATURES_TEMPORAL_MVP);
    var st = State.init(.hevc, va.PROFILE_HEVC_MAIN, 64, 64, ve.RC_CQP, 0);
    st.hevc_seq = std.mem.zeroes(hevc.Seq);
    try testing.expect(!hevcTemporalMvp(&st));
    st.hevc_seq.seq_fields.sps_temporal_mvp_enabled_flag = 1;
    try testing.expect(hevcTemporalMvp(&st));
    // an app's packed SPS is what the stream carries: it decides
    st.hevc_params = .{ .have_sps = true, .temporal_mvp = false };
    try testing.expect(!hevcTemporalMvp(&st));
    st.hevc_params.temporal_mvp = true;
    try testing.expect(hevcTemporalMvp(&st));
}

test "encode: the scratch holds a whole picture's history and two MEPRED buffers" {
    const s = scratchSizesFor(.h264, 1920, 1088);
    try testing.expectEqual(nvenc.historyBytes(120, 68), s.history);
    try testing.expect(s.history >= 120 * 69 * 224);
    try testing.expect(s.mepred >= 120 * 68 * nvenc.MEPRED_BYTES_PER_MB);
    try testing.expect(s.mepred_off >= s.rc_off + s.rc);
    try testing.expectEqual(s.mepred_off + 2 * s.mepred, s.total);
    const a = scratchSizesFor(.av1, 1920, 1088);
    try testing.expect(a.history >= nvenc.historyBytes(120, 68));
    try testing.expect(a.lines_off >= a.mepred_off + 2 * a.mepred);
}

test "encode: the co-located buffers apart: last, aligned by GPU address, inside the scratch" {
    for ([_]Codec{ .h264, .hevc, .av1 }) |kind| {
        const t = scratchSizesFor(kind, 1920, 1088);
        const s = scratchSizesPlaced(kind, 1920, 1088, true);
        try testing.expectEqual(t.history, s.history);
        try testing.expectEqual(t.rc_off - KEPT * t.coloc, s.rc_off);
        try testing.expect(s.coloc_off >= s.mepred_off + 2 * s.mepred);
        if (kind == .av1) try testing.expect(s.coloc_off >= s.lines_off + 3 * s.lines.above + 3 * s.lines.left);
        var cpu: [1]u8 = undefined;
        for ([_]u64{ 0x40_eee0_8000, 0x41_0000_0000, 0x40_0012_3400 }) |base| {
            const sc = Scratch{ .base = base, .cpu = &cpu, .sizes = s };
            for (0..KEPT) |k| {
                const a = sc.coloc(k);
                try testing.expectEqual(@as(u64, 0), a % COLOC_APART);
                try testing.expect(a >= base + s.coloc_off and a + s.coloc <= base + s.total);
                // (clear of the history: at least 1 MiB past it)
                try testing.expect(a >= base + s.history + COLOC_APART);
            }
        }
    }
}

test "encode: kept surfaces: an entry per reference, reused once no list names it" {
    var k = Kept{};
    const live0 = [_]u32{};
    try testing.expectEqual(@as(?u8, 0), k.take(0x400, &live0));
    try testing.expectEqual(@as(?u8, 0), k.take(0x400, &live0));
    const live1 = [_]u32{0x400};
    try testing.expectEqual(@as(?u8, 1), k.take(0x401, &live1));
    // 0x400 dropped from the lists: its entry goes to the next picture
    const live2 = [_]u32{0x401};
    try testing.expectEqual(@as(?u8, 0), k.take(0x402, &live2));
    try testing.expectEqual(@as(?u8, 1), k.find(0x401));
}

test "encode: the engine's report: a status never written, error_status 2 no failure, a ucode error named, the context's tally" {
    var coded: [SLICES_OFF + 256]u8 align(16) = undefined;
    @memset(&coded, 0);
    // (EndPicture's clean status: the picture index poisoned)
    clearStatus(&coded, 7);
    var r = statusOf(&coded, .hevc);
    try testing.expect(!r.written(7));
    try testing.expect(r.failed());
    var line: [400]u8 = undefined;
    const done = Done{ .kind = .hevc, .type = .i, .qp = 25, .header_bytes = 99, .picture_index = 7 };
    try testing.expect(std.mem.indexOf(u8, reportLine(&line, done, r), "NO STATUS") != null);
    // the engine's: its index, error_status 2, 4000 bits: encoded
    std.mem.writeInt(u32, coded[STATUS_OFF..][0..4], 7, .little);
    std.mem.writeInt(u32, coded[STATUS_OFF + 4 ..][0..4], 2, .little);
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 4000, .little);
    r = statusOf(&coded, .hevc);
    try testing.expect(r.written(7) and !r.failed());
    const ok = reportLine(&line, done, r);
    try testing.expect(std.mem.indexOf(u8, ok, "hevc picture 7 (I, QP 25): encoded") != null);
    try testing.expect(std.mem.indexOf(u8, ok, "4000 bits (500 B of slices after 99 B of headers)") != null);
    // ucode error 13: failed, and named as nvenc_drv.h's ERROR_CODES do
    std.mem.writeInt(u32, coded[STATUS_OFF + 4 ..][0..4], 2 | (13 << 2), .little);
    r = statusOf(&coded, .hevc);
    try testing.expect(r.failed());
    try testing.expect(std.mem.indexOf(u8, reportLine(&line, done, r), "ucode error 13 INPUT_BITSTREAM_OFFSET") != null);
    try testing.expectEqualStrings("GPTMR_TIMEOUT", nvenc.ucodeErrorName(1));
    try testing.expectEqualStrings("PICSETUP_OFFSET", nvenc.ucodeErrorName(3));
    try testing.expectEqualStrings("H264_BAD_MAGIC", nvenc.ucodeErrorName(nvenc.ENC_ERROR_H264_BAD_MAGIC));
    // the tally: the first SAY_FIRST pictures said, then failures only
    var t = Tally{};
    var good = r;
    good.ucode_error = 0;
    var said: u32 = 0;
    for (0..10) |k| {
        var d = done;
        d.picture_index = @intCast(k);
        good.picture_index = @intCast(k);
        if (t.count(d, if (k == 6) r else good)) said += 1;
    }
    try testing.expectEqual(@as(u32, Tally.SAY_FIRST + 1), said);
    try testing.expectEqual(@as(u32, 9), t.encoded);
    try testing.expectEqual(@as(u32, 1), t.failed);
    try testing.expectEqual(@as(u32, 6), t.first_failed);
    try testing.expectEqual(@as(u32, 13), t.first_ucode);
    try testing.expect(std.mem.indexOf(u8, t.line(&line, .hevc), "10 pictures, 9 encoded (4500 B of slices), 1 failed (the first: picture 6, ucode error 13") != null);
}

test "encode: the headers placed against the engine's slices, the stream where the segment says" {
    var coded: [SLICES_OFF + 64]u8 align(16) = undefined;
    @memset(&coded, 0);
    const hdr = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 3 };
    @memcpy(coded[DATA_OFF..][0..hdr.len], &hdr);
    placeHeaders(&coded, hdr.len);
    try testing.expectEqualSlices(u8, &hdr, coded[SLICES_OFF - hdr.len .. SLICES_OFF]);
    try testing.expectEqual(SLICES_OFF - hdr.len, streamOff(hdr.len));
    // the engine's slice right after them: one stream
    coded[SLICES_OFF] = 0xaa;
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 8, .little);
    const f = finish(null, &coded, .{ .header_bytes = hdr.len });
    try testing.expectEqual(@as(u32, hdr.len + 1), f.bytes);
    const seg = std.mem.bytesToValue(ve.CodedBufferSegment, coded[0..@sizeOf(ve.CodedBufferSegment)]);
    const p: [*]const u8 = @ptrCast(seg.buf.?);
    try testing.expectEqualSlices(u8, &(hdr ++ [_]u8{0xaa}), p[0..seg.size]);
}
