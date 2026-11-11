//! @zpm/va encode — an encode context's state between libva's calls, and
//! what EndPicture makes for the engine: the codec's parameter buffers
//! kept, packed headers gathered, the rate control's QP, the parameter
//! sets written into the coded buffer ahead of the engine's slices, the
//! input picture tiled, the setup and the pushbuffer; and, once the engine
//! is done, the coded buffer's segment.
//!
//! The coded buffer (one of the kernel's buffers, the CPU's and the
//! engine's):
//!
//!   0x0000  VACodedBufferSegment (what vaMapBuffer returns)
//!   0x0100  the engine's status (nvenc_pic_stat_s; SET_OUT_ENC_STATUS)
//!   0x1100  the stream: the headers the driver writes or the app packed,
//!           then the engine's slices from bitstream_start_pos on
//!           (SET_OUT_BITSTREAM is 0x1100)
//!
//! Rate control is the driver's: the engine runs at constant QP
//! (RCMODE_CONSTQP) and each picture's QP is chosen here, from the app's
//! (CQP), or from the bits the last pictures took against the target
//! (CBR, VBR). The engine's own picture rate control is not driven: its
//! RCMODE values past CONSTQP and its state's meaning are not public.
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

pub const Codec = enum { h264, hevc };

pub const SEGMENT_OFF: usize = 0;
pub const STATUS_OFF: usize = 0x100;
pub const DATA_OFF: usize = 0x1100;
/// the headers' room ahead of the engine's slices
pub const HEADER_BYTES: usize = 16 << 10;

/// RateControl's modes this driver answers.
pub const RC_MODES: u32 = ve.RC_CQP | ve.RC_CBR | ve.RC_VBR;
/// The packed headers it takes: the app's parameter sets (sequence) and
/// its SEI and other NAL units (misc, raw). Not slices: the engine writes
/// its slice headers.
pub const PACKED_HEADERS: u32 = ve.PACKED_HEADER_SEQUENCE | ve.PACKED_HEADER_MISC | ve.PACKED_HEADER_RAW_DATA;
/// References a P picture may have (EncMaxRefFrames: L0 in the low 16
/// bits, no L1: no B pictures).
pub const MAX_REFS_L0: u32 = 1;

pub fn supported(profile: va.Profile) ?Codec {
    if (std.mem.indexOfScalar(va.Profile, &h264.PROFILES, profile) != null) return .h264;
    if (profile == hevc.PROFILE) return .hevc;
    return null;
}

// ── Rate control ────────────────────────────────────────────────────────────

pub const Rate = struct {
    mode: u32 = ve.RC_CQP,
    bits_per_second: u32 = 0,
    target_percentage: u32 = 100,
    fps_num: u32 = 30,
    fps_den: u32 = 1,
    min_qp: u8 = 10,
    max_qp: u8 = 51,
    buffer_bits: u64 = 0,
    /// the virtual buffer's fill against the target (bits; positive: over)
    fullness: i64 = 0,
    /// the next picture's QP (CBR, VBR), from initial_qp or 28
    qp: i32 = 28,
    frames: u32 = 0,

    /// The misc rate control parameters.
    pub fn control(r: *Rate, p: ve.RateControl) void {
        if (p.bits_per_second != 0) r.bits_per_second = p.bits_per_second;
        if (p.target_percentage != 0) r.target_percentage = @min(p.target_percentage, 100);
        if (p.initial_qp != 0) r.qp = @intCast(@min(p.initial_qp, 51));
        if (p.min_qp != 0) r.min_qp = @intCast(@min(p.min_qp, 51));
        if (p.max_qp != 0) r.max_qp = @intCast(@min(p.max_qp, 51));
        if (r.max_qp < r.min_qp) r.max_qp = r.min_qp;
    }

    pub fn frameRate(r: *Rate, p: ve.FrameRate) void {
        const num = p.framerate & 0xffff;
        const den = p.framerate >> 16;
        if (num == 0) return;
        r.fps_num = num;
        r.fps_den = if (den == 0) 1 else den;
    }

    /// A picture's target size in bits (VBR: the average's share).
    pub fn target(r: *const Rate) u64 {
        const bps: u64 = if (r.mode == ve.RC_VBR) @as(u64, r.bits_per_second) * r.target_percentage / 100 else r.bits_per_second;
        return @max(bps * r.fps_den / r.fps_num, 1);
    }

    /// The QP of the next picture: the app's for CQP (`app_qp`), else the
    /// controller's, a little lower for an intra picture.
    pub fn next(r: *const Rate, app_qp: i32, intra: bool) u8 {
        if (r.mode == ve.RC_CQP or r.bits_per_second == 0) return @intCast(std.math.clamp(app_qp, 0, 51));
        const q = r.qp - @as(i32, if (intra) 2 else 0);
        return @intCast(std.math.clamp(q, r.min_qp, r.max_qp));
    }

    /// A finished picture took `n` bits: the buffer's fill moves, the QP
    /// follows (one step a picture against the picture's own size, one
    /// more when the buffer is a quarter over or under).
    pub fn took(r: *Rate, n: u64, intra: bool) void {
        r.frames += 1;
        if (r.mode == ve.RC_CQP or r.bits_per_second == 0) return;
        const t = r.target();
        // (an intra picture's budget: four pictures')
        const budget = if (intra) t * 4 else t;
        r.fullness += @as(i64, @intCast(n)) - @as(i64, @intCast(t));
        const buffer: i64 = @intCast(if (r.buffer_bits != 0) r.buffer_bits else @as(u64, r.bits_per_second));
        // (VBR lets the buffer run below the target freely)
        if (r.mode == ve.RC_VBR and r.fullness < 0) r.fullness = @max(r.fullness, -buffer);
        var d: i32 = 0;
        if (n > budget + budget / 2) d += 1;
        if (n < budget / 2) d -= 1;
        if (r.fullness > @divTrunc(buffer, 4)) d += 1;
        if (r.fullness < -@divTrunc(buffer, 4) and r.mode == ve.RC_CBR) d -= 1;
        r.qp = std.math.clamp(r.qp + d, r.min_qp, r.max_qp);
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
    rate: Rate = .{},
    // ── the sequence (kept across pictures) ──
    have_seq: bool = false,
    h264_seq: h264.Seq = undefined,
    hevc_seq: hevc.Seq = undefined,
    // ── the picture being made ──
    have_pic: bool = false,
    h264_pic: h264.Pic = undefined,
    hevc_pic: hevc.Pic = undefined,
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

    pub fn init(kind: Codec, profile: va.Profile, width: u32, height: u32, rc_mode: u32, packed_headers: u32) State {
        return .{ .kind = kind, .profile = profile, .width = width, .height = height, .packed_headers = packed_headers, .rate = .{ .mode = rc_mode } };
    }
};

/// A new picture (BeginPicture).
pub fn begin(st: *State) void {
    st.have_pic = false;
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

/// One VA buffer of the picture (RenderPicture).
pub fn take(st: *State, b: codec.Buffer) va.Status {
    switch (b.kind) {
        ve.ENC_SEQUENCE_PARAMETER_BUFFER => switch (st.kind) {
            .h264 => {
                st.h264_seq = value(h264.Seq, b.data) orelse return va.ERROR_INVALID_BUFFER;
                if (st.rate.bits_per_second == 0) st.rate.bits_per_second = st.h264_seq.bits_per_second;
                st.have_seq = true;
                st.new_seq = true;
            },
            .hevc => {
                st.hevc_seq = value(hevc.Seq, b.data) orelse return va.ERROR_INVALID_BUFFER;
                if (st.rate.bits_per_second == 0) st.rate.bits_per_second = st.hevc_seq.bits_per_second;
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
                }
                st.slices += 1;
            }
        },
        ve.ENC_MISC_PARAMETER_BUFFER => {
            if (b.data.len < 4) return va.ERROR_INVALID_BUFFER;
            const kind = std.mem.readInt(u32, b.data[0..4], .little);
            const rest = b.data[4..];
            switch (kind) {
                ve.MISC_RATE_CONTROL => st.rate.control(value(ve.RateControl, rest) orelse return va.ERROR_INVALID_BUFFER),
                ve.MISC_FRAME_RATE => st.rate.frameRate(value(ve.FrameRate, rest) orelse return va.ERROR_INVALID_BUFFER),
                ve.MISC_HRD => {
                    const h = value(ve.Hrd, rest) orelse return va.ERROR_INVALID_BUFFER;
                    st.rate.buffer_bits = h.buffer_size;
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
            if (st.packed_kind == ve.PACKED_SEQUENCE) st.packed_seq = true;
            const room = st.hdr[st.hdr_len..];
            const header_len: usize = if (st.kind == .hevc) 2 else 1;
            const wrote = if (st.packed_emulation) copy(room, b.data[0..n]) else emulate(room, b.data[0..n], header_len);
            st.hdr_len += @intCast(wrote orelse return va.ERROR_NOT_ENOUGH_BUFFER);
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
    };
}

/// The reconstructed picture's surface.
pub fn reconSurface(st: *const State) u32 {
    return switch (st.kind) {
        .h264 => st.h264_pic.CurrPic.picture_id,
        .hevc => st.hevc_pic.decoded_curr_pic.picture_id,
    };
}

// ── EndPicture ──────────────────────────────────────────────────────────────

/// The picture to encode: its linear NV12 (the app's) and the buffer the
/// engine reads it from (block linear; the surface's own).
pub const Input = struct {
    linear: []const u8,
    lin: tiling.Linear,
    tiled: []u8,
    tiled_va: u64,
    layout: tiling.Nv12,
    width: u32,
    height: u32,
};

/// The context's buffers for the engine.
pub const Scratch = struct {
    history: u64,
    history_bytes: u32,
    rc_process: u64,
    /// two co-located motion buffers, used in turn
    coloc: [2]u64,
};

pub const EndIn = struct {
    /// the frame slot's pushbuffer and setup area (CPU, GPU)
    push: []u32,
    setup: []u8,
    setup_va: u64,
    coded: []u8,
    coded_va: u64,
    input: Input,
    gob: tiling.Gob,
    lookup: codec.Lookup,
    scratch: Scratch,
    picture_index: u32,
    magic: u32 = nvenc.MAGIC,
};

pub const EndOut = struct {
    dwords: usize = 0,
    /// the stream's bytes the driver wrote (headers) ahead of the engine's
    header_bytes: u32 = 0,
    qp: u8 = 0,
    intra: bool = false,
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
    };
    if (st_ok != va.SUCCESS) return st_ok;
    const recon = in.lookup.surface(reconSurface(st)) orelse return va.ERROR_INVALID_SURFACE;
    if (recon.luma == in.input.tiled_va) return va.ERROR_INVALID_SURFACE;

    // The stream: the driver's parameter sets (no packed ones came), then
    // the app's packed headers.
    const data = in.coded[DATA_OFF..];
    var n: usize = 0;
    const idr = switch (st.kind) {
        .h264 => st.h264_pic.pic_fields.idr_pic_flag != 0,
        .hevc => st.hevc_pic.pic_fields.idr_pic_flag != 0,
    };
    if ((idr or st.new_seq) and !st.packed_seq) {
        switch (st.kind) {
            .h264 => {
                n += h264.writeSps(data[n..HEADER_BYTES], st.profile, &st.h264_seq) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
                n += h264.writePps(data[n..HEADER_BYTES], st.profile, &st.h264_pic) orelse return va.ERROR_NOT_ENOUGH_BUFFER;
            },
            .hevc => n += hevc.writeHeadersSized(data[n..HEADER_BYTES], &st.hevc_seq, &st.hevc_pic, st.width, st.height) orelse return va.ERROR_NOT_ENOUGH_BUFFER,
        }
    }
    if (n + st.hdr_len > HEADER_BYTES) return va.ERROR_NOT_ENOUGH_BUFFER;
    @memcpy(data[n..][0..st.hdr_len], st.hdr[0..st.hdr_len]);
    n += st.hdr_len;

    // The input, block linear.
    const inp = in.input;
    nvenc.tileNv12(inp.tiled, inp.layout, in.gob, inp.linear, inp.lin, inp.width, inp.height);

    // The references: VA's list, the engine's slots.
    var ref_ids = [_]u32{va.INVALID_ID} ** nvenc.REF_SLOTS;
    var ref_poc = [_]i32{0} ** nvenc.REF_SLOTS;
    var a = nvenc.PictureAddrs{
        .application_id = undefined,
        .codec_type = undefined,
        .setup = in.setup_va,
        .status = in.coded_va + STATUS_OFF,
        .bitstream = in.coded_va + DATA_OFF,
        .history = in.scratch.history,
        .rc_process = in.scratch.rc_process,
        .coloc_in = in.scratch.coloc[(st.pictures + 1) % 2],
        .coloc_out = in.scratch.coloc[st.pictures % 2],
        .cur_luma = inp.tiled_va,
        .cur_chroma = inp.tiled_va + inp.layout.chroma_offset,
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
    }
    for ([_]u64{ a.setup, a.status, a.bitstream, a.history, a.rc_process, a.coloc_in, a.coloc_out, a.cur_luma, a.cur_chroma, a.out_luma, a.out_chroma }) |x| {
        if (!nvenc.addressable(x)) return va.ERROR_INVALID_SURFACE;
    }

    const room: u32 = @intCast(@min(in.coded.len - DATA_OFF, std.math.maxInt(u32)));
    const input_planes = h264.Planes{ .luma = a.cur_luma, .chroma = a.cur_chroma, .pitch_luma = inp.layout.luma.pitch, .pitch_chroma = inp.layout.chroma.pitch };
    const recon_planes = h264.Planes{ .luma = recon.luma, .chroma = recon.chroma, .pitch_luma = recon.pitch_luma, .pitch_chroma = recon.pitch_chroma };
    const fps = st.rate.fps_num / @max(st.rate.fps_den, 1);
    switch (st.kind) {
        .h264 => {
            const pic = &st.h264_pic;
            const seq = &st.h264_seq;
            const slices = st.h264_slices[0..st.slices];
            const intra = slices[0].slice_type == 2 or pic.pic_fields.idr_pic_flag != 0;
            const qp = st.rate.next(@as(i32, pic.pic_init_qp) + slices[0].qp_delta, intra);
            const w = @as(u32, seq.picture_width_in_mbs) * 16;
            const h = @as(u32, seq.picture_height_in_mbs) * 16;
            if (w > inp.layout.luma.pitch or h > inp.layout.luma.rows) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
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
                .bitstream_start = @intCast(n),
                .bitstream_room = room,
                .history_bytes = in.scratch.history_bytes,
                .magic = in.magic,
            });
            a.application_id = nvenc.APPLICATION_ID_H264;
            a.codec_type = nvenc.CODEC_TYPE_H264;
            out.qp = qp;
            out.intra = intra;
        },
        .hevc => {
            const pic = &st.hevc_pic;
            const seq = &st.hevc_seq;
            const slices = st.hevc_slices[0..st.slices];
            const intra = slices[0].slice_type == 2 or pic.pic_fields.idr_pic_flag != 0;
            const qp = st.rate.next(@as(i32, pic.pic_init_qp) + slices[0].qp_delta, intra);
            if (seq.pic_width_in_luma_samples > inp.layout.luma.pitch or seq.pic_height_in_luma_samples > inp.layout.luma.rows) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            hevc.setup(in.setup, .{
                .seq = seq,
                .pic = pic,
                .slices = slices,
                .input = input_planes,
                .recon = recon_planes,
                .ref_ids = ref_ids,
                .ref_poc = ref_poc,
                .qp = qp,
                .gop_length = if (seq.intra_period != 0) seq.intra_period else 0xffff_ffff,
                .framerate = fps,
                .bitstream_start = @intCast(n),
                .bitstream_room = room,
                .history_bytes = in.scratch.history_bytes,
                .magic = in.magic,
            });
            a.application_id = nvenc.APPLICATION_ID_H265;
            a.codec_type = nvenc.CODEC_TYPE_H265;
            out.qp = qp;
            out.intra = intra;
        },
    }
    // a clean status, an empty segment until the engine is done
    @memset(in.coded[STATUS_OFF..DATA_OFF], 0);
    @memset(in.coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], 0);
    out.dwords = nvenc.push(in.push, a);
    out.header_bytes = @intCast(n);
    st.pictures += 1;
    return va.SUCCESS;
}

/// What a finished picture came to.
pub const Finished = struct {
    bytes: u32,
    result: nvenc.Result,
    overflow: bool,
};

/// The engine is done with the picture in `coded` (its headers
/// `header_bytes` long): the segment vaMapBuffer returns, filled; the
/// rate control (its context's, if it still has one) told.
pub fn finish(rate: ?*Rate, coded: []u8, header_bytes: u32, intra: bool) Finished {
    const r = nvenc.Result.of(coded[STATUS_OFF..][0..nvenc.Stat.SIZE]);
    const room = coded.len - DATA_OFF;
    var n: usize = header_bytes + @as(usize, r.bytes());
    const overflow = n > room;
    if (overflow) n = room;
    if (r.failed()) n = header_bytes;
    var seg = std.mem.zeroes(ve.CodedBufferSegment);
    seg.size = @intCast(n);
    seg.status = if (overflow) ve.CODED_BUF_STATUS_SLICE_OVERFLOW_MASK else 0;
    seg.buf = coded.ptr + DATA_OFF;
    seg.next = null;
    @memcpy(coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], std.mem.asBytes(&seg));
    if (rate) |rc| rc.took(@as(u64, n) * 8, intra);
    return .{ .bytes = @intCast(n), .result = r, .overflow = overflow };
}

/// An empty segment (a coded buffer never encoded into, or lost).
pub fn emptySegment(coded: []u8) void {
    var seg = std.mem.zeroes(ve.CodedBufferSegment);
    seg.buf = coded.ptr + DATA_OFF;
    @memcpy(coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], std.mem.asBytes(&seg));
}

/// The context's scratch: history (nvenc_drv.h 2.3: at least
/// ((width + 15) / 16 + 16) * 128 bytes; HEVC's per 64-pixel CTB, given
/// room), two co-located buffers (64 bytes a macroblock), the rate
/// control's state.
pub const ScratchSizes = struct {
    history: usize,
    coloc: usize,
    rc: usize,
    total: usize,
};

pub fn scratchSizes(width: u32, height: u32) ScratchSizes {
    const wmbs: usize = (width + 15) / 16;
    const hmbs: usize = (height + 15) / 16;
    const history = std.mem.alignForward(usize, (wmbs + 16) * 1024, 4096);
    const coloc = std.mem.alignForward(usize, wmbs * hmbs * 64, 4096);
    const rc: usize = 4096;
    return .{ .history = history, .coloc = coloc, .rc = rc, .total = history + 2 * coloc + rc };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "encode: rate control holds a CBR stream near its target" {
    var r = Rate{ .mode = ve.RC_CBR };
    r.control(.{ .bits_per_second = 3_000_000, .target_percentage = 100, .window_size = 1000, .initial_qp = 30, .min_qp = 0, .basic_unit_size = 0, .rc_flags = 0, .ICQ_quality_factor = 0, .max_qp = 0, .quality_factor = 0, .target_frame_size = 0, .va_reserved = .{ 0, 0, 0, 0 } });
    r.frameRate(.{ .framerate = 30 | (1 << 16), .framerate_flags = 0, .va_reserved = .{ 0, 0, 0, 0 } });
    try testing.expectEqual(@as(u64, 100_000), r.target());
    try testing.expectEqual(@as(u8, 30), r.next(0, false));
    try testing.expectEqual(@as(u8, 28), r.next(0, true));
    // pictures twice too big: the QP climbs
    for (0..5) |_| r.took(200_000, false);
    try testing.expect(r.next(0, false) > 30);
    // then far too small: it comes back down
    const high = r.qp;
    for (0..40) |_| r.took(10_000, false);
    try testing.expect(r.qp < high);
    // CQP: the app's QP, untouched
    const q = Rate{};
    try testing.expectEqual(@as(u8, 22), q.next(22, false));
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

test "encode: a finished picture's segment" {
    var coded: [DATA_OFF + 64]u8 align(16) = undefined;
    @memset(&coded, 0);
    var st = State.init(.h264, va.PROFILE_H264_MAIN, 48, 32, ve.RC_CQP, 0);
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 20 * 8 + 3, .little);
    const f = finish(&st.rate, &coded, 30, true);
    try testing.expectEqual(@as(u32, 51), f.bytes);
    try testing.expect(!f.overflow);
    const seg = std.mem.bytesToValue(ve.CodedBufferSegment, coded[0..@sizeOf(ve.CodedBufferSegment)]);
    try testing.expectEqual(@as(u32, 51), seg.size);
    try testing.expectEqual(@intFromPtr(&coded) + DATA_OFF, @intFromPtr(seg.buf.?));
    try testing.expectEqual(@as(?*anyopaque, null), seg.next);
    // too big for the buffer: cut, and said
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 1000 * 8, .little);
    const g = finish(&st.rate, &coded, 30, false);
    try testing.expect(g.overflow);
    try testing.expectEqual(@as(u32, 64), g.bytes);
}
