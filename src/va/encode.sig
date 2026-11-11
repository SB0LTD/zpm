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
//!   0x1100  the stream: the headers the driver writes or the app packed,
//!           then the engine's slices from bitstream_start_pos on
//!           (SET_OUT_BITSTREAM is 0x1100), then any filler
//!
//! The input picture is the engine's as it lies in memory (`Input`: block
//! linear planes, any block height); a picture that needs a pass first
//! (pitch linear) has had it before EndPicture gets here (enc_input.sig).
//!
//! References: VA names the surfaces; each surface that is or becomes a
//! reference keeps an entry in `kept` while VA's lists name it, and the
//! entry's co-located motion buffer is what a later B picture (or HEVC's
//! temporal MVP) reads as its collocated picture's.
//!
//! Rate control: enc_rc.sig (the driver's controller unless the
//! firmware's is asked for).
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
/// EncMaxRefFrames: L0 in the low 16 bits, L1 in the high 16.
pub const MAX_REFS: u32 = h264.MAX_L0 | (h264.MAX_L1 << 16);
/// (the old name: L0's count)
pub const MAX_REFS_L0: u32 = h264.MAX_L0;
/// Surfaces kept as references at once (each with its co-located buffer).
pub const KEPT = 10;

pub fn supported(profile: va.Profile) ?Codec {
    if (std.mem.indexOfScalar(va.Profile, &h264.PROFILES, profile) != null) return .h264;
    if (profile == hevc.PROFILE) return .hevc;
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
    // ── the sequence (kept across pictures) ──
    have_seq: bool = false,
    h264_seq: h264.Seq = undefined,
    hevc_seq: hevc.Seq = undefined,
    /// what the app's packed HEVC SPS and PPS say
    hevc_params: enc_parse.HevcParams = .{},
    kept: Kept = .{},
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
        var st = State{ .kind = kind, .profile = profile, .width = width, .height = height, .packed_headers = packed_headers };
        st.rate = .{ .mode = rcMode(rc_mode), .scale = .h26x, .pixels = @as(u64, width) * height, .max_qp = 51 };
        return st;
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
            const header_len: usize = if (st.kind == .hevc) 2 else 1;
            const wrote = if (st.packed_emulation) copy(room, b.data[0..n]) else emulate(room, b.data[0..n], header_len);
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
    };
}

/// The reconstructed picture's surface.
pub fn reconSurface(st: *const State) u32 {
    return switch (st.kind) {
        .h264 => st.h264_pic.CurrPic.picture_id,
        .hevc => st.hevc_pic.decoded_curr_pic.picture_id,
    };
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
        return s.base + s.sizes.coloc_off + k * s.sizes.coloc;
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
};

/// What the finished picture needs to know (kept with its coded buffer).
pub const Done = struct {
    kind: Codec = .h264,
    type: enc_rc.Type = .i,
    qp: i32 = 0,
    /// the stream's bytes the driver wrote (headers) ahead of the engine's
    header_bytes: u32 = 0,
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
    };
    if (st_ok != va.SUCCESS) return st_ok;
    const sl_ok = switch (st.kind) {
        .h264 => h264.checkSlices(st.profile, st.h264_slices[0..st.slices]),
        .hevc => hevc.checkSlices(st.hevc_slices[0..st.slices]),
    };
    if (sl_ok != va.SUCCESS) return sl_ok;
    const recon_id = reconSurface(st);
    const recon = in.lookup.surface(recon_id) orelse return va.ERROR_INVALID_SURFACE;
    if (recon.luma == in.input.luma) return va.ERROR_INVALID_SURFACE;

    // The stream: the driver's parameter sets (no packed ones came), then
    // the app's packed headers.
    const data = in.coded[DATA_OFF..];
    var n: usize = 0;
    const idr = switch (st.kind) {
        .h264 => st.h264_pic.pic_fields.idr_pic_flag != 0,
        .hevc => st.hevc_pic.pic_fields.idr_pic_flag != 0,
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
        .bitstream = in.coded_va + DATA_OFF,
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
    };
    const in_k = st.kept.find(col_id) orelse out_k;
    a.coloc_out = in.scratch.coloc(out_k);
    a.coloc_in = in.scratch.coloc(in_k);
    for ([_]u64{ a.setup, a.status, a.bitstream, a.history, a.rc_process, a.coloc_in, a.coloc_out, a.cur_luma, a.cur_chroma, a.out_luma, a.out_chroma }) |x| {
        if (!nvenc.addressable(x)) return va.ERROR_INVALID_SURFACE;
    }

    const room: u32 = @intCast(@min(in.coded.len - DATA_OFF, std.math.maxInt(u32)));
    const input_planes = h264.Planes{ .luma = a.cur_luma, .chroma = a.cur_chroma, .pitch_luma = inp.pitch_luma, .pitch_chroma = inp.pitch_chroma, .block_height = inp.block_height };
    const recon_planes = h264.Planes{ .luma = recon.luma, .chroma = recon.chroma, .pitch_luma = recon.pitch_luma, .pitch_chroma = recon.pitch_chroma };
    const fps = st.rate.fps_num / @max(st.rate.fps_den, 1);
    const t = picType(st);
    var done = Done{ .kind = st.kind, .type = t };
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
                .bitstream_start = @intCast(n),
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
                .bitstream_start = @intCast(n),
                .bitstream_room = room,
                .history_bytes = @intCast(in.scratch.sizes.history),
                .magic = in.magic,
            });
            a.application_id = nvenc.APPLICATION_ID_H265;
            a.codec_type = nvenc.CODEC_TYPE_H265;
            if (st.firmware_rc and st.rate.active()) a.rc_mode = firmware(st, in, enc_rc.RcFields.of(nvenc.H265), qp);
            done.qp = qp;
        },
    }
    // a clean status, an empty segment until the engine is done
    @memset(in.coded[STATUS_OFF..DATA_OFF], 0);
    @memset(in.coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], 0);
    out.dwords = nvenc.push(in.push, a);
    out.header_bytes = @intCast(n);
    out.qp = @intCast(done.qp);
    out.intra = t == .i;
    done.header_bytes = @intCast(n);
    out.done = done;
    st.pictures += 1;
    return va.SUCCESS;
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
    const r = nvenc.Result.ofKind(coded[STATUS_OFF..][0..nvenc.Stat.SIZE], switch (done.kind) {
        .h264 => .h264,
        .hevc => .hevc,
    });
    const header_bytes = done.header_bytes;
    const room = coded.len - DATA_OFF;
    var n: usize = header_bytes + @as(usize, r.bytes());
    const overflow = n > room;
    if (overflow) n = room;
    if (r.failed()) n = header_bytes;
    var pad_bytes: u32 = 0;
    if (st) |s| {
        const pad = s.rate.done(done.type, @as(u64, n) * 8, done.qp, r.intra_cost, r.inter_cost);
        if (pad > 0 and !r.failed()) {
            const want: usize = @intCast(pad / 8);
            pad_bytes = @intCast(filler(coded[DATA_OFF..], n, want, done.kind));
            n += pad_bytes;
        }
    }
    var seg = std.mem.zeroes(ve.CodedBufferSegment);
    seg.size = @intCast(n);
    seg.status = if (overflow) ve.CODED_BUF_STATUS_SLICE_OVERFLOW_MASK else 0;
    seg.buf = coded.ptr + DATA_OFF;
    seg.next = null;
    @memcpy(coded[SEGMENT_OFF..][0..@sizeOf(ve.CodedBufferSegment)], std.mem.asBytes(&seg));
    return .{ .bytes = @intCast(n), .result = r, .overflow = overflow, .pad_bytes = pad_bytes };
}

/// A filler data NAL unit of about `want` bytes after the `at` bytes of
/// `stream` (H.264's type 12, HEVC's FD_NUT 38: 0xff bytes and the RBSP's
/// stop bit), as much as fits: its length.
pub fn filler(stream: []u8, at: usize, want: usize, kind: Codec) usize {
    const head: []const u8 = switch (kind) {
        .h264 => &.{ 0, 0, 0, 1, 0x0c },
        .hevc => &.{ 0, 0, 0, 1, 0x4c, 0x01 },
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

/// The context's scratch: history (nvenc_drv.h 2.3: at least
/// ((width + 15) / 16 + 16) * 128 bytes; HEVC's per 64-pixel CTB, given
/// room), KEPT co-located buffers (64 bytes a macroblock), the rate
/// control's state.
pub const ScratchSizes = struct {
    history: usize,
    history_off: usize = 0,
    coloc: usize,
    coloc_off: usize,
    rc: usize,
    rc_off: usize,
    total: usize,
};

pub fn scratchSizes(width: u32, height: u32) ScratchSizes {
    const wmbs: usize = (width + 15) / 16;
    const hmbs: usize = (height + 15) / 16;
    const history = std.mem.alignForward(usize, (wmbs + 16) * 1024, 4096);
    const coloc = std.mem.alignForward(usize, wmbs * hmbs * 64, 4096);
    const rc: usize = 4096;
    const coloc_off = history;
    const rc_off = coloc_off + KEPT * coloc;
    return .{ .history = history, .coloc = coloc, .coloc_off = coloc_off, .rc = rc, .rc_off = rc_off, .total = rc_off + rc };
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
    var coded: [DATA_OFF + 64]u8 align(16) = undefined;
    @memset(&coded, 0);
    var st = State.init(.h264, va.PROFILE_H264_MAIN, 48, 32, ve.RC_CQP, 0);
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 20 * 8 + 3, .little);
    const f = finish(&st, &coded, .{ .header_bytes = 30 });
    try testing.expectEqual(@as(u32, 51), f.bytes);
    try testing.expect(!f.overflow);
    const seg = std.mem.bytesToValue(ve.CodedBufferSegment, coded[0..@sizeOf(ve.CodedBufferSegment)]);
    try testing.expectEqual(@as(u32, 51), seg.size);
    try testing.expectEqual(@intFromPtr(&coded) + DATA_OFF, @intFromPtr(seg.buf.?));
    try testing.expectEqual(@as(?*anyopaque, null), seg.next);
    // too big for the buffer: cut, and said
    std.mem.writeInt(u32, coded[STATUS_OFF + 8 ..][0..4], 1000 * 8, .little);
    const g = finish(&st, &coded, .{ .header_bytes = 30, .type = .p });
    try testing.expect(g.overflow);
    try testing.expectEqual(@as(u32, 64), g.bytes);
    // a filler NAL unit
    var s: [32]u8 = undefined;
    const n = filler(&s, 4, 12, .h264);
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x0c, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x80 }, s[4..16]);
    try testing.expectEqual(@as(usize, 0), filler(&s, 30, 12, .hevc));
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
