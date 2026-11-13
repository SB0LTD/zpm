//! @zpm/va av1_read — an AV1 stream (temporal units of OBUs, the low
//! overhead format MP4 and WebM hold) read as a VA-API client reads it, for
//! video.Decoder: the sequence header (5.5), each frame header (5.9: frame
//! size and superres, the references, the interpolation filter, tiles,
//! quantizer, segmentation, delta q/lf, loop filter, CDEF, loop
//! restoration, transform and reference modes, skip mode, global motion,
//! film grain), the tile groups' tiles, and the state AV1 keeps per
//! reference slot (7.20, 7.21: sizes, order hints, loop filter deltas,
//! segmentation data, global motion, film grain), so VA's picture
//! parameters and tile parameters are what FFmpeg's vaapi_av1 sends. The
//! decoder (av1.sig on NVDEC) keeps the CDFs, motion vectors and segment
//! maps by surface.
//!
//! Not done: large-scale tile, frame id numbers' checks (read, not used),
//! operating point selection (the first is decoded), 4:4:4/4:2:2.
//!
//! Pure and allocation-free.

const std = @import("std");
const vav = @import("vaapi_av1.sig");

pub const Error = error{ Truncated, Corrupt, Unsupported };
pub const INVALID: u32 = 0xffffffff;

const OBU_SEQUENCE_HEADER = 1;
const OBU_TEMPORAL_DELIMITER = 2;
const OBU_FRAME_HEADER = 3;
const OBU_TILE_GROUP = 4;
const OBU_FRAME = 6;
const OBU_REDUNDANT_FRAME_HEADER = 7;

const KEY_FRAME = 0;
const INTER_FRAME = 1;
const INTRA_ONLY_FRAME = 2;
const SWITCH_FRAME = 3;
const PRIMARY_REF_NONE = 7;
const SELECT: u8 = 2;

const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    fn bit(r: *Bits) Error!u1 {
        if (r.pos >= r.data.len * 8) return error.Truncated;
        const b = (r.data[r.pos >> 3] >> @intCast(7 - (r.pos & 7))) & 1;
        r.pos += 1;
        return @intCast(b);
    }
    fn f(r: *Bits, n: u6) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | try r.bit();
        return v;
    }
    fn flag(r: *Bits) Error!bool {
        return try r.bit() == 1;
    }
    fn uvlc(r: *Bits) Error!u32 {
        var lz: u32 = 0;
        while (try r.bit() == 0) {
            lz += 1;
            if (lz >= 32) return error.Corrupt;
        }
        if (lz == 0) return 0;
        return try r.f(@intCast(lz)) + (@as(u32, 1) << @intCast(lz)) - 1;
    }
    fn su(r: *Bits, n: u6) Error!i32 {
        const v = try r.f(n);
        const sign = @as(u32, 1) << @intCast(n - 1);
        if (v & sign != 0) return @as(i32, @intCast(v)) - @as(i32, @intCast(2 * sign));
        return @intCast(v);
    }
    fn ns(r: *Bits, n: u32) Error!u32 {
        if (n <= 1) return 0;
        var w: u6 = 0;
        var x = n;
        while (x != 0) : (x >>= 1) w += 1;
        const m = (@as(u32, 1) << @intCast(w)) - n;
        const v = try r.f(w - 1);
        if (v < m) return v;
        const extra = try r.bit();
        return (v << 1) - m + extra;
    }
    fn le(r: *Bits, n: u32) Error!u32 {
        var t: u32 = 0;
        for (0..n) |i| t += try r.f(8) << @intCast(i * 8);
        return t;
    }
    fn byteAlign(r: *Bits) void {
        r.pos = (r.pos + 7) & ~@as(usize, 7);
    }
};

fn leb128(d: []const u8, at: *usize) Error!u64 {
    var v: u64 = 0;
    for (0..8) |i| {
        if (at.* >= d.len) return error.Truncated;
        const b = d[at.*];
        at.* += 1;
        v |= @as(u64, b & 0x7f) << @intCast(7 * i);
        if (b & 0x80 == 0) return v;
    }
    return error.Corrupt;
}

// ── The sequence header ─────────────────────────────────────────────────────

pub const Seq = struct {
    valid: bool = false,
    profile: u8 = 0,
    still_picture: bool = false,
    reduced_still: bool = false,
    frame_width_bits: u6 = 0,
    frame_height_bits: u6 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    frame_id_numbers: bool = false,
    delta_frame_id_bits: u6 = 0,
    frame_id_bits: u6 = 0,
    sb128: bool = false,
    filter_intra: bool = false,
    intra_edge: bool = false,
    interintra: bool = false,
    masked: bool = false,
    warped: bool = false,
    dual_filter: bool = false,
    order_hint: bool = false,
    jnt_comp: bool = false,
    ref_frame_mvs: bool = false,
    force_screen_content: u8 = SELECT,
    force_integer_mv: u8 = SELECT,
    order_hint_bits: u6 = 0,
    superres: bool = false,
    cdef: bool = false,
    restoration: bool = false,
    bit_depth: u8 = 8,
    mono: bool = false,
    color_range: bool = false,
    ssx: bool = true,
    ssy: bool = true,
    chroma_sample_position: u2 = 0,
    matrix_coefficients: u8 = 2,
    separate_uv_delta_q: bool = false,
    film_grain: bool = false,
    decoder_model: bool = false,
    equal_picture_interval: bool = false,
    buffer_removal_time_bits: u6 = 0,
    buffer_delay_bits: u6 = 0,
    frame_presentation_time_bits: u6 = 0,
    op_idc: u32 = 0,
    op_decoder_model: [32]bool = [_]bool{false} ** 32,
    op_idc_all: [32]u32 = [_]u32{0} ** 32,
    op_count: u32 = 1,
};

fn parseSeq(data: []const u8, out: *Seq) Error!void {
    var r = Bits{ .data = data };
    var s = Seq{};
    s.profile = @intCast(try r.f(3));
    s.still_picture = try r.flag();
    s.reduced_still = try r.flag();
    if (s.reduced_still) {
        _ = try r.f(5); // seq_level_idx[0]
    } else {
        const timing = try r.flag();
        if (timing) {
            _ = try r.f(32);
            _ = try r.f(32);
            s.equal_picture_interval = try r.flag();
            if (s.equal_picture_interval) _ = try r.uvlc();
            s.decoder_model = try r.flag();
            if (s.decoder_model) {
                s.buffer_delay_bits = @intCast(try r.f(5) + 1);
                _ = try r.f(32);
                s.buffer_removal_time_bits = @intCast(try r.f(5) + 1);
                s.frame_presentation_time_bits = @intCast(try r.f(5) + 1);
            }
        }
        const initial_display_delay = try r.flag();
        const ops = try r.f(5) + 1;
        s.op_count = ops;
        for (0..ops) |i| {
            s.op_idc_all[i] = try r.f(12);
            const level = try r.f(5);
            if (level > 7) _ = try r.bit();
            if (s.decoder_model) {
                s.op_decoder_model[i] = try r.flag();
                if (s.op_decoder_model[i]) {
                    // operating_parameters_info
                    _ = try r.f(s.buffer_delay_bits);
                    _ = try r.f(s.buffer_delay_bits);
                    _ = try r.bit();
                }
            }
            if (initial_display_delay) {
                if (try r.flag()) _ = try r.f(4);
            }
        }
        s.op_idc = s.op_idc_all[0];
    }
    s.frame_width_bits = @intCast(try r.f(4) + 1);
    s.frame_height_bits = @intCast(try r.f(4) + 1);
    s.max_width = try r.f(s.frame_width_bits) + 1;
    s.max_height = try r.f(s.frame_height_bits) + 1;
    if (!s.reduced_still) s.frame_id_numbers = try r.flag();
    if (s.frame_id_numbers) {
        s.delta_frame_id_bits = @intCast(try r.f(4) + 2);
        s.frame_id_bits = @intCast(try r.f(3) + 1 + s.delta_frame_id_bits);
    }
    s.sb128 = try r.flag();
    s.filter_intra = try r.flag();
    s.intra_edge = try r.flag();
    if (!s.reduced_still) {
        s.interintra = try r.flag();
        s.masked = try r.flag();
        s.warped = try r.flag();
        s.dual_filter = try r.flag();
        s.order_hint = try r.flag();
        if (s.order_hint) {
            s.jnt_comp = try r.flag();
            s.ref_frame_mvs = try r.flag();
        }
        if (try r.flag()) s.force_screen_content = SELECT else s.force_screen_content = try r.bit();
        if (s.force_screen_content > 0) {
            if (try r.flag()) s.force_integer_mv = SELECT else s.force_integer_mv = try r.bit();
        } else s.force_integer_mv = SELECT;
        if (s.order_hint) s.order_hint_bits = @intCast(try r.f(3) + 1);
    }
    s.superres = try r.flag();
    s.cdef = try r.flag();
    s.restoration = try r.flag();
    // color_config
    const high = try r.flag();
    if (s.profile == 2 and high) s.bit_depth = if (try r.flag()) 12 else 10 else s.bit_depth = if (high) 10 else 8;
    s.mono = if (s.profile == 1) false else try r.flag();
    var cp: u32 = 2;
    var tc: u32 = 2;
    var mc: u32 = 2;
    if (try r.flag()) {
        cp = try r.f(8);
        tc = try r.f(8);
        mc = try r.f(8);
    }
    s.matrix_coefficients = @intCast(mc);
    if (s.mono) {
        s.color_range = try r.flag();
        s.ssx = true;
        s.ssy = true;
    } else if (cp == 1 and tc == 13 and mc == 0) {
        s.color_range = true;
        s.ssx = false;
        s.ssy = false;
    } else {
        s.color_range = try r.flag();
        if (s.profile == 0) {
            s.ssx = true;
            s.ssy = true;
        } else if (s.profile == 1) {
            s.ssx = false;
            s.ssy = false;
        } else if (s.bit_depth == 12) {
            s.ssx = try r.flag();
            s.ssy = if (s.ssx) try r.flag() else false;
        } else {
            s.ssx = true;
            s.ssy = false;
        }
        if (s.ssx and s.ssy) s.chroma_sample_position = @intCast(try r.f(2));
    }
    if (!s.mono) s.separate_uv_delta_q = try r.flag();
    s.film_grain = try r.flag();
    s.valid = true;
    out.* = s;
}

// ── What each reference slot keeps ─────────────────────────────────────────

pub const GmParams = [7][6]i32;
const DEFAULT_GM = [6]i32{ 0, 0, 1 << 16, 0, 0, 1 << 16 };

pub const Slot = struct {
    valid: bool = false,
    surface: u32 = INVALID,
    frame_type: u8 = 0,
    upscaled_width: u32 = 0,
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    order_hint: u32 = 0,
    saved_order_hints: [8]u32 = [_]u32{0} ** 8,
    gm: GmParams = [_][6]i32{DEFAULT_GM} ** 7,
    lf_ref: [8]i8 = .{ 1, 0, 0, 0, -1, 0, -1, -1 },
    lf_mode: [2]i8 = .{ 0, 0 },
    seg_enabled: [8][8]bool = [_][8]bool{[_]bool{false} ** 8} ** 8,
    seg_data: [8][8]i16 = [_][8]i16{[_]i16{0} ** 8} ** 8,
    grain: vav.FilmGrain = .{},
    showable: bool = false,
    bit_depth: u8 = 8,
};

pub const State = struct {
    seq: Seq = .{},
    slots: [8]Slot = [_]Slot{.{}} ** 8,
    /// the frame header being decoded (between its header OBU and its
    /// last tile group)
    seen_header: bool = false,
};

/// One frame read: VA's buffers, and what its decode does to the slots.
pub const Frame = struct {
    show_existing: bool = false,
    existing_slot: u3 = 0,
    show: bool = false,
    showable: bool = false,
    key: bool = false,
    refresh: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    render: [2]u32 = .{ 0, 0 },
    apply_grain: bool = false,
    pic: vav.PictureParameterBufferAV1 = .{},
    tiles: [256]vav.SliceParameterBufferAV1 = undefined,
    n_tiles: u32 = 0,
    /// the tile groups' bytes, as one slice data buffer (the caller's bytes
    /// copied: groups in OBUs are not contiguous)
    data: [*]u8 = undefined,
    data_cap: usize = 0,
    data_len: usize = 0,
    /// the slot state the frame leaves (refresh)
    next_slot: Slot = .{},
};

fn tileLog2(blk: u32, target: u32) u32 {
    var k: u32 = 0;
    while ((blk << @intCast(k)) < target) k += 1;
    return k;
}

fn getRelativeDist(seq: *const Seq, a: u32, b: u32) i32 {
    if (!seq.order_hint) return 0;
    const bits = seq.order_hint_bits;
    var diff: i32 = @as(i32, @intCast(a)) - @as(i32, @intCast(b));
    const m: i32 = @as(i32, 1) << @intCast(bits - 1);
    diff = (diff & (m - 1)) - (diff & m);
    return diff;
}

/// decode_signed_subexp_with_ref (5.9.26 helpers for global motion).
fn decodeSubexp(r: *Bits, num_syms: u32) Error!u32 {
    var i: u32 = 0;
    var mk: u32 = 0;
    const k: u32 = 3;
    while (true) {
        const b2 = if (i != 0) k + i - 1 else k;
        const a = @as(u32, 1) << @intCast(b2);
        if (num_syms <= mk + 3 * a) {
            return try r.ns(num_syms - mk) + mk;
        }
        if (try r.flag()) {
            i += 1;
            mk += a;
        } else {
            return try r.f(@intCast(b2)) + mk;
        }
    }
}
fn inverseRecenter(rr: i32, v: i32) i32 {
    if (v > 2 * rr) return v;
    if (v & 1 != 0) return rr - ((v + 1) >> 1);
    return rr + (v >> 1);
}
fn decodeUnsignedSubexpWithRef(r: *Bits, mx: i32, ref: i32) Error!i32 {
    const v: i32 = @intCast(try decodeSubexp(r, @intCast(mx)));
    if ((ref << 1) <= mx) return inverseRecenter(ref, v);
    return mx - 1 - inverseRecenter(mx - 1 - ref, v);
}
fn decodeSignedSubexpWithRef(r: *Bits, low: i32, high: i32, ref: i32) Error!i32 {
    const x = try decodeUnsignedSubexpWithRef(r, high - low, ref - low);
    return x + low;
}

const WARPEDMODEL_PREC_BITS = 16;
const GM_ABS_TRANS_BITS = 12;
const GM_ABS_TRANS_ONLY_BITS = 9;
const GM_ABS_ALPHA_BITS = 12;
const GM_ALPHA_PREC_BITS = 15;
const GM_TRANS_PREC_BITS = 6;
const GM_TRANS_ONLY_PREC_BITS = 3;

fn readGmParam(r: *Bits, gm: *[6]i32, prev: *const [6]i32, typ: u32, idx: usize, allow_hp: bool) Error!void {
    var abs_bits: u6 = GM_ABS_ALPHA_BITS;
    var prec_bits: u6 = GM_ALPHA_PREC_BITS;
    if (idx < 2) {
        if (typ == vav.WM_TRANSLATION) {
            abs_bits = GM_ABS_TRANS_ONLY_BITS - @as(u6, @intFromBool(!allow_hp));
            prec_bits = GM_TRANS_ONLY_PREC_BITS - @as(u6, @intFromBool(!allow_hp));
        } else {
            abs_bits = GM_ABS_TRANS_BITS;
            prec_bits = GM_TRANS_PREC_BITS;
        }
    }
    const prec_diff: u6 = WARPEDMODEL_PREC_BITS - prec_bits;
    const round: i32 = if (idx % 3 == 2) (@as(i32, 1) << WARPEDMODEL_PREC_BITS) else 0;
    const sub: i32 = if (idx % 3 == 2) (@as(i32, 1) << @intCast(prec_bits)) else 0;
    const mx: i32 = @as(i32, 1) << @intCast(abs_bits);
    const rr = (prev[idx] >> @intCast(prec_diff)) - sub;
    gm[idx] = (try decodeSignedSubexpWithRef(r, -mx, mx + 1, rr) << @intCast(prec_diff)) + round;
}

/// Reads one temporal unit (or one frame's OBUs) against `st`; `out` gets
/// the frame. `data_buf` holds the tile groups' bytes. Returns the bytes
/// of `tu` consumed (a temporal unit may hold more than one frame: call
/// again with the rest), 0 when nothing is left.
pub fn read(st: *State, tu: []const u8, data_buf: []u8, out: *Frame) Error!usize {
    var at: usize = 0;
    var f = Frame{ .data = data_buf.ptr, .data_cap = data_buf.len };
    var have_header = false;
    var tiles_seen: u32 = 0;
    var total_tiles: u32 = 0;
    var tile_size_bytes: u32 = 4;
    var hdr: Hdr = .{};
    while (at < tu.len) {
        const obu_start = at;
        const h = tu[at];
        at += 1;
        if (h & 0x80 != 0) return error.Corrupt;
        const typ = (h >> 3) & 0xf;
        const ext = h & 4 != 0;
        const has_size = h & 2 != 0;
        if (ext) at += 1;
        var size: usize = tu.len - at;
        if (has_size) size = @intCast(try leb128(tu, &at));
        if (at + size > tu.len) return error.Truncated;
        const payload = tu[at..][0..size];
        at += size;
        switch (typ) {
            OBU_SEQUENCE_HEADER => try parseSeq(payload, &st.seq),
            OBU_TEMPORAL_DELIMITER => {
                if (have_header) return obu_start;
                st.seen_header = false;
            },
            OBU_FRAME_HEADER, OBU_REDUNDANT_FRAME_HEADER, OBU_FRAME => {
                if (typ == OBU_REDUNDANT_FRAME_HEADER and have_header) continue;
                if (have_header and typ != OBU_REDUNDANT_FRAME_HEADER) return obu_start; // (the next frame)
                if (!st.seq.valid) return error.Corrupt;
                var r = Bits{ .data = payload };
                try frameHeader(st, &r, &f, &hdr);
                have_header = true;
                if (f.show_existing) {
                    out.* = f;
                    return at;
                }
                total_tiles = @as(u32, f.pic.tile_cols) * f.pic.tile_rows;
                tile_size_bytes = hdr.tile_size_bytes;
                if (typ == OBU_FRAME) {
                    r.byteAlign();
                    try tileGroup(payload[r.pos / 8 ..], &f, total_tiles, tile_size_bytes, &tiles_seen);
                }
            },
            OBU_TILE_GROUP => {
                if (!have_header) continue;
                try tileGroup(payload, &f, total_tiles, tile_size_bytes, &tiles_seen);
            },
            else => {},
        }
        if (have_header and !f.show_existing and tiles_seen >= total_tiles and total_tiles > 0) {
            out.* = f;
            return at;
        }
    }
    if (have_header and !f.show_existing) {
        if (tiles_seen < total_tiles) return error.Truncated;
        out.* = f;
    }
    return if (have_header) at else 0;
}

fn tileGroup(payload: []const u8, f: *Frame, total: u32, tsb: u32, seen: *u32) Error!void {
    var r = Bits{ .data = payload };
    var tg_start: u32 = 0;
    var tg_end: u32 = total - 1;
    if (total > 1) {
        if (try r.flag()) {
            const bits = tileLog2(1, f.pic.tile_cols) + tileLog2(1, f.pic.tile_rows);
            tg_start = try r.f(@intCast(bits));
            tg_end = try r.f(@intCast(bits));
        }
    }
    r.byteAlign();
    var pos = r.pos / 8;
    // the group's bytes into the slice data buffer
    const base = f.data_len;
    const body = payload[pos..];
    if (base + body.len > f.data_cap) return error.Unsupported;
    @memcpy(f.data[base..][0..body.len], body);
    f.data_len += body.len;
    pos = 0;
    var t = tg_start;
    while (t <= tg_end) : (t += 1) {
        var size: usize = undefined;
        if (t == tg_end) size = body.len - pos else {
            if (pos + tsb > body.len) return error.Truncated;
            var v: usize = 0;
            for (0..tsb) |i| v |= @as(usize, body[pos + i]) << @intCast(8 * i);
            size = v + 1;
            pos += tsb;
        }
        if (pos + size > body.len) return error.Truncated;
        if (f.n_tiles >= f.tiles.len) return error.Unsupported;
        f.tiles[f.n_tiles] = .{
            .slice_data_size = @intCast(size),
            .slice_data_offset = @intCast(base + pos),
            .slice_data_flag = 0,
            .tile_row = @intCast(t / f.pic.tile_cols),
            .tile_column = @intCast(t % f.pic.tile_cols),
            .tg_start = @intCast(tg_start),
            .tg_end = @intCast(tg_end),
        };
        f.n_tiles += 1;
        pos += size;
    }
    seen.* += tg_end - tg_start + 1;
}

const Hdr = struct {
    tile_size_bytes: u32 = 4,
};

/// uncompressed_header() (5.9.2) into `f`'s VA picture parameters.
fn frameHeader(st: *State, r: *Bits, f: *Frame, hdr: *Hdr) Error!void {
    const seq = &st.seq;
    const p = &f.pic;
    p.* = .{};
    var frame_type: u8 = KEY_FRAME;
    var show_frame = true;
    var showable = false;
    var error_res = false;
    var id_len: u6 = 0;
    if (seq.frame_id_numbers) id_len = seq.frame_id_bits;
    const all_frames: u8 = 0xff;
    var frame_is_intra = true;
    if (seq.reduced_still) {
        frame_type = KEY_FRAME;
        show_frame = true;
        showable = false;
        error_res = true;
    } else {
        if (try r.flag()) { // show_existing_frame
            f.show_existing = true;
            f.existing_slot = @intCast(try r.f(3));
            if (seq.decoder_model and !seq.equal_picture_interval) _ = try r.f(seq.frame_presentation_time_bits);
            if (seq.frame_id_numbers) _ = try r.f(id_len);
            const s = &st.slots[f.existing_slot];
            if (!s.valid) return error.Corrupt;
            f.show = true;
            f.width = s.upscaled_width;
            f.height = s.frame_height;
            // (a shown key frame refreshes every slot: 7.21)
            if (s.frame_type == KEY_FRAME) f.refresh = all_frames;
            f.key = s.frame_type == KEY_FRAME;
            f.next_slot = s.*;
            return;
        }
        frame_type = @intCast(try r.f(2));
        frame_is_intra = frame_type == INTRA_ONLY_FRAME or frame_type == KEY_FRAME;
        show_frame = try r.flag();
        if (show_frame and seq.decoder_model and !seq.equal_picture_interval) _ = try r.f(seq.frame_presentation_time_bits);
        if (show_frame) showable = frame_type != KEY_FRAME else showable = try r.flag();
        if (frame_type == SWITCH_FRAME or (frame_type == KEY_FRAME and show_frame)) error_res = true else error_res = try r.flag();
    }
    if (frame_type == KEY_FRAME and show_frame) {
        for (&st.slots) |*s| {
            s.valid = false;
            s.order_hint = 0;
        }
    }
    const disable_cdf_update = try r.flag();
    var allow_screen_content: bool = false;
    if (seq.force_screen_content == SELECT) allow_screen_content = try r.flag() else allow_screen_content = seq.force_screen_content == 1;
    var force_integer_mv = false;
    if (allow_screen_content) {
        if (seq.force_integer_mv == SELECT) force_integer_mv = try r.flag() else force_integer_mv = seq.force_integer_mv == 1;
    }
    if (frame_is_intra) force_integer_mv = true;
    if (seq.frame_id_numbers) _ = try r.f(id_len);
    var frame_size_override = false;
    if (frame_type == SWITCH_FRAME) frame_size_override = true else if (seq.reduced_still) frame_size_override = false else frame_size_override = try r.flag();
    const order_hint = try r.f(seq.order_hint_bits);
    var primary_ref_frame: u8 = PRIMARY_REF_NONE;
    if (!(frame_is_intra or error_res)) primary_ref_frame = @intCast(try r.f(3));
    if (seq.decoder_model) {
        const present = try r.flag();
        if (present) {
            for (0..seq.op_count) |i| {
                if (seq.op_decoder_model[i]) {
                    const idc = seq.op_idc_all[i];
                    // (temporal and spatial ids of this OBU: the first layer's)
                    if (idc == 0 or (idc & 1 != 0 and idc & 0x100 != 0)) _ = try r.f(seq.buffer_removal_time_bits);
                }
            }
        }
    }
    var allow_hp = false;
    var use_ref_frame_mvs = false;
    var allow_intrabc = false;
    var refresh: u8 = 0;
    if (frame_type == SWITCH_FRAME or (frame_type == KEY_FRAME and show_frame)) refresh = all_frames else refresh = @intCast(try r.f(8));
    if (!frame_is_intra or refresh != all_frames) {
        if (error_res and seq.order_hint) {
            for (0..8) |_| _ = try r.f(seq.order_hint_bits); // ref_order_hint (no gap frames made)
        }
    }
    var width: u32 = 0;
    var height: u32 = 0;
    var upscaled: u32 = 0;
    var render = [2]u32{ 0, 0 };
    var superres_denom: u32 = 8;
    var ref_frame_idx = [_]u8{0} ** 7;
    var interp: u8 = 0;
    var motion_switchable = false;
    if (frame_is_intra) {
        try frameSize(seq, r, frame_size_override, &width, &height, &upscaled, &superres_denom);
        try renderSize(r, upscaled, height, &render);
        if (allow_screen_content and upscaled == width) allow_intrabc = try r.flag();
    } else {
        var short_signaling = false;
        if (seq.order_hint) short_signaling = try r.flag();
        if (short_signaling) {
            // (set_frame_refs, 7.8: refused, as rare as it is)
            return error.Unsupported;
        }
        for (0..7) |i| {
            ref_frame_idx[i] = @intCast(try r.f(3));
            if (seq.frame_id_numbers) _ = try r.f(seq.delta_frame_id_bits);
        }
        if (frame_size_override and !error_res) {
            // frame_size_with_refs
            var found = false;
            for (0..7) |i| {
                if (try r.flag()) {
                    const s = &st.slots[ref_frame_idx[i]];
                    upscaled = s.upscaled_width;
                    width = upscaled;
                    height = s.frame_height;
                    render = .{ s.render_width, s.render_height };
                    found = true;
                    break;
                }
            }
            if (!found) {
                try frameSize(seq, r, frame_size_override, &width, &height, &upscaled, &superres_denom);
                try renderSize(r, upscaled, height, &render);
            } else {
                try superresParams(seq, r, &width, upscaled, &superres_denom);
            }
        } else {
            try frameSize(seq, r, frame_size_override, &width, &height, &upscaled, &superres_denom);
            try renderSize(r, upscaled, height, &render);
        }
        if (force_integer_mv) allow_hp = false else allow_hp = try r.flag();
        // read_interpolation_filter
        if (try r.flag()) interp = 4 else interp = @intCast(try r.f(2));
        motion_switchable = try r.flag();
        if (error_res or !seq.ref_frame_mvs) use_ref_frame_mvs = false else use_ref_frame_mvs = try r.flag();
    }
    var disable_frame_end_update_cdf = true;
    if (seq.reduced_still or disable_cdf_update) disable_frame_end_update_cdf = true else disable_frame_end_update_cdf = try r.flag();

    // load_previous (the primary reference's saved state)
    var lf_ref = [8]i8{ 1, 0, 0, 0, -1, 0, -1, -1 };
    var lf_mode = [2]i8{ 0, 0 };
    var seg_en: [8][8]bool = [_][8]bool{[_]bool{false} ** 8} ** 8;
    var seg_data: [8][8]i16 = [_][8]i16{[_]i16{0} ** 8} ** 8;
    var prev_gm: GmParams = [_][6]i32{DEFAULT_GM} ** 7;
    if (primary_ref_frame != PRIMARY_REF_NONE) {
        const s = &st.slots[ref_frame_idx[primary_ref_frame]];
        lf_ref = s.lf_ref;
        lf_mode = s.lf_mode;
        seg_en = s.seg_enabled;
        seg_data = s.seg_data;
        prev_gm = s.gm;
    }

    // tile_info (5.9.15)
    const sb_shift: u5 = if (seq.sb128) 5 else 4;
    const mi_cols = 2 * ((width + 7) >> 3);
    const mi_rows = 2 * ((height + 7) >> 3);
    const sb_cols = if (seq.sb128) (mi_cols + 31) >> 5 else (mi_cols + 15) >> 4;
    const sb_rows = if (seq.sb128) (mi_rows + 31) >> 5 else (mi_rows + 15) >> 4;
    const sb_size_log2: u5 = sb_shift + 2;
    const max_tile_width_sb = @as(u32, 4096) >> sb_size_log2;
    var max_tile_area_sb: u32 = @as(u32, 4096 * 2304) >> @intCast(2 * @as(u32, sb_size_log2));
    const min_log2_tile_cols = tileLog2(max_tile_width_sb, sb_cols);
    const max_log2_tile_cols = tileLog2(1, @min(sb_cols, 64));
    const max_log2_tile_rows = tileLog2(1, @min(sb_rows, 64));
    const min_log2_tiles = @max(min_log2_tile_cols, tileLog2(max_tile_area_sb, sb_rows * sb_cols));
    const uniform = try r.flag();
    var tile_cols: u32 = 0;
    var tile_rows: u32 = 0;
    var tile_cols_log2: u32 = 0;
    var tile_rows_log2: u32 = 0;
    if (uniform) {
        tile_cols_log2 = min_log2_tile_cols;
        while (tile_cols_log2 < max_log2_tile_cols) {
            if (try r.flag()) tile_cols_log2 += 1 else break;
        }
        const tile_width_sb = (sb_cols + (@as(u32, 1) << @intCast(tile_cols_log2)) - 1) >> @intCast(tile_cols_log2);
        var i: u32 = 0;
        var start: u32 = 0;
        while (start < sb_cols) : (start += tile_width_sb) {
            if (i < 63) p.width_in_sbs_minus_1[i] = @intCast(@min(tile_width_sb, sb_cols - start) - 1);
            i += 1;
        }
        tile_cols = i;
        const min_log2_tile_rows = if (min_log2_tiles > tile_cols_log2) min_log2_tiles - tile_cols_log2 else 0;
        tile_rows_log2 = min_log2_tile_rows;
        while (tile_rows_log2 < max_log2_tile_rows) {
            if (try r.flag()) tile_rows_log2 += 1 else break;
        }
        const tile_height_sb = (sb_rows + (@as(u32, 1) << @intCast(tile_rows_log2)) - 1) >> @intCast(tile_rows_log2);
        i = 0;
        start = 0;
        while (start < sb_rows) : (start += tile_height_sb) {
            if (i < 63) p.height_in_sbs_minus_1[i] = @intCast(@min(tile_height_sb, sb_rows - start) - 1);
            i += 1;
        }
        tile_rows = i;
    } else {
        var widest: u32 = 0;
        var start: u32 = 0;
        var i: u32 = 0;
        while (start < sb_cols and i < 64) : (i += 1) {
            const max_w = @min(sb_cols - start, max_tile_width_sb);
            const w = try r.ns(max_w) + 1;
            if (i < 63) p.width_in_sbs_minus_1[i] = @intCast(w - 1);
            widest = @max(widest, w);
            start += w;
        }
        tile_cols = i;
        tile_cols_log2 = tileLog2(1, tile_cols);
        if (min_log2_tiles > 0) max_tile_area_sb = (sb_rows * sb_cols) >> @intCast(min_log2_tiles + 1) else max_tile_area_sb = sb_rows * sb_cols;
        const max_tile_height_sb = @max(max_tile_area_sb / widest, 1);
        start = 0;
        i = 0;
        while (start < sb_rows and i < 64) : (i += 1) {
            const max_h = @min(sb_rows - start, max_tile_height_sb);
            const hh = try r.ns(max_h) + 1;
            if (i < 63) p.height_in_sbs_minus_1[i] = @intCast(hh - 1);
            start += hh;
        }
        tile_rows = i;
        tile_rows_log2 = tileLog2(1, tile_rows);
    }
    var context_update_tile_id: u32 = 0;
    if (tile_cols_log2 > 0 or tile_rows_log2 > 0) {
        context_update_tile_id = try r.f(@intCast(tile_rows_log2 + tile_cols_log2));
        hdr.tile_size_bytes = try r.f(2) + 1;
    }
    p.tile_cols = @intCast(tile_cols);
    p.tile_rows = @intCast(tile_rows);
    p.context_update_tile_id = @intCast(context_update_tile_id);

    // quantization_params (5.9.12)
    const base_q = try r.f(8);
    p.base_qindex = @intCast(base_q);
    p.y_dc_delta_q = @intCast(try readDeltaQ(r));
    if (!seq.mono) {
        var diff_uv = false;
        if (seq.separate_uv_delta_q) diff_uv = try r.flag();
        p.u_dc_delta_q = @intCast(try readDeltaQ(r));
        p.u_ac_delta_q = @intCast(try readDeltaQ(r));
        if (diff_uv) {
            p.v_dc_delta_q = @intCast(try readDeltaQ(r));
            p.v_ac_delta_q = @intCast(try readDeltaQ(r));
        } else {
            p.v_dc_delta_q = p.u_dc_delta_q;
            p.v_ac_delta_q = p.u_ac_delta_q;
        }
    }
    const using_qm = try r.flag();
    p.qmatrix_fields.using_qmatrix = @intFromBool(using_qm);
    if (using_qm) {
        p.qmatrix_fields.qm_y = @intCast(try r.f(4));
        p.qmatrix_fields.qm_u = @intCast(try r.f(4));
        if (!seq.separate_uv_delta_q) p.qmatrix_fields.qm_v = p.qmatrix_fields.qm_u else p.qmatrix_fields.qm_v = @intCast(try r.f(4));
    }

    // segmentation_params (5.9.14)
    const seg_enabled = try r.flag();
    p.seg_info.segment_info_fields.enabled = @intFromBool(seg_enabled);
    if (seg_enabled) {
        var update_map = true;
        var temporal_update = false;
        var update_data = true;
        if (primary_ref_frame != PRIMARY_REF_NONE) {
            update_map = try r.flag();
            if (update_map) temporal_update = try r.flag();
            update_data = try r.flag();
        }
        p.seg_info.segment_info_fields.update_map = @intFromBool(update_map);
        p.seg_info.segment_info_fields.temporal_update = @intFromBool(temporal_update);
        p.seg_info.segment_info_fields.update_data = @intFromBool(update_data);
        if (update_data) {
            const bits = [8]u6{ 8, 6, 6, 6, 6, 3, 0, 0 };
            const signed = [8]bool{ true, true, true, true, true, false, false, false };
            const maxv = [8]i16{ 255, 63, 63, 63, 63, 7, 0, 0 };
            for (0..8) |i| {
                for (0..8) |j| {
                    var v: i16 = 0;
                    const en = try r.flag();
                    if (en) {
                        if (signed[j]) {
                            const x = try r.su(bits[j] + 1);
                            v = @intCast(std.math.clamp(x, -@as(i32, maxv[j]), maxv[j]));
                        } else {
                            v = @intCast(@min(try r.f(bits[j]), @as(u32, @intCast(maxv[j]))));
                        }
                    }
                    seg_en[i][j] = en;
                    seg_data[i][j] = v;
                }
            }
        }
    } else {
        seg_en = [_][8]bool{[_]bool{false} ** 8} ** 8;
        seg_data = [_][8]i16{[_]i16{0} ** 8} ** 8;
    }
    for (0..8) |i| {
        var mask: u8 = 0;
        for (0..8) |j| {
            if (seg_en[i][j]) mask |= @as(u8, 1) << @intCast(j);
            p.seg_info.feature_data[i][j] = seg_data[i][j];
        }
        p.seg_info.feature_mask[i] = mask;
    }
    // CodedLossless (for the filters below)
    var coded_lossless = true;
    for (0..8) |i| {
        var q: i32 = @intCast(base_q);
        if (seg_enabled and seg_en[i][0]) q = std.math.clamp(q + seg_data[i][0], 0, 255);
        const lossless = q == 0 and p.y_dc_delta_q == 0 and p.u_ac_delta_q == 0 and p.u_dc_delta_q == 0 and p.v_ac_delta_q == 0 and p.v_dc_delta_q == 0;
        if (!lossless) coded_lossless = false;
        if (!seg_enabled) break;
    }
    const all_lossless = coded_lossless and width == upscaled;

    // delta_q_params, delta_lf_params
    var mc = vav.ModeControlFields{};
    if (base_q > 0) mc.delta_q_present_flag = @intFromBool(try r.flag());
    if (mc.delta_q_present_flag != 0) mc.log2_delta_q_res = @intCast(try r.f(2));
    if (mc.delta_q_present_flag != 0) {
        if (!allow_intrabc) mc.delta_lf_present_flag = @intFromBool(try r.flag());
        if (mc.delta_lf_present_flag != 0) {
            mc.log2_delta_lf_res = @intCast(try r.f(2));
            mc.delta_lf_multi = @intFromBool(try r.flag());
        }
    }

    // loop_filter_params (5.9.11)
    if (coded_lossless or allow_intrabc) {
        lf_ref = .{ 1, 0, 0, 0, -1, 0, -1, -1 };
        lf_mode = .{ 0, 0 };
    } else {
        p.filter_level[0] = @intCast(try r.f(6));
        p.filter_level[1] = @intCast(try r.f(6));
        if (!seq.mono) {
            if (p.filter_level[0] != 0 or p.filter_level[1] != 0) {
                p.filter_level_u = @intCast(try r.f(6));
                p.filter_level_v = @intCast(try r.f(6));
            }
        }
        p.loop_filter_info_fields.sharpness_level = @intCast(try r.f(3));
        const delta_enabled = try r.flag();
        p.loop_filter_info_fields.mode_ref_delta_enabled = @intFromBool(delta_enabled);
        if (delta_enabled) {
            const update = try r.flag();
            p.loop_filter_info_fields.mode_ref_delta_update = @intFromBool(update);
            if (update) {
                for (&lf_ref) |*d| {
                    if (try r.flag()) d.* = @intCast(try r.su(7));
                }
                for (&lf_mode) |*d| {
                    if (try r.flag()) d.* = @intCast(try r.su(7));
                }
            }
        }
    }
    p.ref_deltas = lf_ref;
    p.mode_deltas = lf_mode;

    // cdef_params (5.9.19)
    if (!(coded_lossless or allow_intrabc or !seq.cdef)) {
        p.cdef_damping_minus_3 = @intCast(try r.f(2));
        p.cdef_bits = @intCast(try r.f(2));
        for (0..(@as(usize, 1) << @intCast(p.cdef_bits))) |i| {
            // (VA carries the secondary strength as coded, 0..3)
            const yp = try r.f(4);
            const ys = try r.f(2);
            p.cdef_y_strengths[i] = @intCast((yp << 2) | ys);
            if (!seq.mono) {
                const up = try r.f(4);
                const us = try r.f(2);
                p.cdef_uv_strengths[i] = @intCast((up << 2) | us);
            }
        }
    }
    // lr_params (5.9.20)
    if (!(all_lossless or allow_intrabc or !seq.restoration)) {
        var uses_lr = false;
        var uses_chroma_lr = false;
        const remap = [4]u2{ 0, 3, 1, 2 }; // RESTORE_NONE, SWITCHABLE, WIENER, SGRPROJ
        var types: [3]u2 = .{ 0, 0, 0 };
        const planes: usize = if (seq.mono) 1 else 3;
        for (0..planes) |i| {
            const t = remap[try r.f(2)];
            types[i] = t;
            if (t != 0) {
                uses_lr = true;
                if (i > 0) uses_chroma_lr = true;
            }
        }
        p.loop_restoration_fields.yframe_restoration_type = types[0];
        p.loop_restoration_fields.cbframe_restoration_type = types[1];
        p.loop_restoration_fields.crframe_restoration_type = types[2];
        if (uses_lr) {
            var shift: u32 = 0;
            if (seq.sb128) {
                shift = try r.f(1);
                shift += 1;
            } else {
                shift = try r.f(1);
                if (shift != 0) shift += try r.f(1);
            }
            p.loop_restoration_fields.lr_unit_shift = @intCast(shift);
            if (seq.ssx and seq.ssy and uses_chroma_lr) p.loop_restoration_fields.lr_uv_shift = @intCast(try r.f(1));
        }
    }
    // read_tx_mode
    if (coded_lossless) mc.tx_mode = 0 else mc.tx_mode = if (try r.flag()) 2 else 1;
    // frame_reference_mode
    if (!frame_is_intra) mc.reference_select = @intFromBool(try r.flag());
    // skip_mode_params (5.9.22)
    var skip_mode_present = false;
    if (!(frame_is_intra or mc.reference_select == 0 or !seq.order_hint)) {
        var forward_idx: i32 = -1;
        var backward_idx: i32 = -1;
        var forward_hint: u32 = 0;
        var backward_hint: u32 = 0;
        for (0..7) |i| {
            const ref_hint = st.slots[ref_frame_idx[i]].order_hint;
            if (getRelativeDist(seq, ref_hint, order_hint) < 0) {
                if (forward_idx < 0 or getRelativeDist(seq, ref_hint, forward_hint) > 0) {
                    forward_idx = @intCast(i);
                    forward_hint = ref_hint;
                }
            } else if (getRelativeDist(seq, ref_hint, order_hint) > 0) {
                if (backward_idx < 0 or getRelativeDist(seq, ref_hint, backward_hint) < 0) {
                    backward_idx = @intCast(i);
                    backward_hint = ref_hint;
                }
            }
        }
        var allowed = false;
        if (forward_idx < 0) {
            allowed = false;
        } else if (backward_idx >= 0) {
            allowed = true;
        } else {
            var second_idx: i32 = -1;
            var second_hint: u32 = 0;
            for (0..7) |i| {
                const ref_hint = st.slots[ref_frame_idx[i]].order_hint;
                if (getRelativeDist(seq, ref_hint, forward_hint) < 0) {
                    if (second_idx < 0 or getRelativeDist(seq, ref_hint, second_hint) > 0) {
                        second_idx = @intCast(i);
                        second_hint = ref_hint;
                    }
                }
            }
            allowed = second_idx >= 0;
        }
        if (allowed) skip_mode_present = try r.flag();
    }
    mc.skip_mode_present = @intFromBool(skip_mode_present);
    var allow_warped = false;
    if (frame_is_intra or error_res or !seq.warped) allow_warped = false else allow_warped = try r.flag();
    mc.reduced_tx_set_used = @intFromBool(try r.flag());
    p.mode_control_fields = mc;

    // global_motion_params (5.9.24)
    var gm: GmParams = [_][6]i32{DEFAULT_GM} ** 7;
    for (0..7) |i| {
        p.wm[i] = .{};
    }
    if (!frame_is_intra) {
        for (0..7) |i| {
            var typ: u32 = vav.WM_IDENTITY;
            if (try r.flag()) {
                if (try r.flag()) typ = vav.WM_ROTZOOM else typ = if (try r.flag()) vav.WM_TRANSLATION else vav.WM_AFFINE;
            }
            if (typ >= vav.WM_ROTZOOM) {
                try readGmParam(r, &gm[i], &prev_gm[i], typ, 2, allow_hp);
                try readGmParam(r, &gm[i], &prev_gm[i], typ, 3, allow_hp);
                if (typ == vav.WM_AFFINE) {
                    try readGmParam(r, &gm[i], &prev_gm[i], typ, 4, allow_hp);
                    try readGmParam(r, &gm[i], &prev_gm[i], typ, 5, allow_hp);
                } else {
                    gm[i][4] = -gm[i][3];
                    gm[i][5] = gm[i][2];
                }
            }
            if (typ >= vav.WM_TRANSLATION) {
                try readGmParam(r, &gm[i], &prev_gm[i], typ, 0, allow_hp);
                try readGmParam(r, &gm[i], &prev_gm[i], typ, 1, allow_hp);
            }
            p.wm[i].wmtype = typ;
            for (0..6) |k| p.wm[i].wmmat[k] = gm[i][k];
            // (shear validity is the decoder's to judge: invalid left 0)
        }
    }

    // film_grain_params (5.9.30)
    var grain: vav.FilmGrain = .{};
    if (seq.film_grain and (show_frame or showable)) {
        const apply = try r.flag();
        if (apply) {
            const seed = try r.f(16);
            var update = true;
            if (frame_type == INTER_FRAME) update = try r.flag();
            if (!update) {
                const ref = try r.f(3);
                grain = st.slots[ref].grain;
                grain.grain_seed = @intCast(seed);
            } else {
                grain.grain_seed = @intCast(seed);
                var fi = vav.FilmGrainInfoFields{ .apply_grain = 1 };
                grain.num_y_points = @intCast(try r.f(4));
                if (grain.num_y_points > 14) return error.Corrupt;
                for (0..grain.num_y_points) |i| {
                    grain.point_y_value[i] = @intCast(try r.f(8));
                    grain.point_y_scaling[i] = @intCast(try r.f(8));
                }
                var csfl = false;
                if (!seq.mono) csfl = try r.flag();
                fi.chroma_scaling_from_luma = @intFromBool(csfl);
                if (seq.mono or csfl or (seq.ssx and seq.ssy and grain.num_y_points == 0)) {
                    grain.num_cb_points = 0;
                    grain.num_cr_points = 0;
                } else {
                    grain.num_cb_points = @intCast(try r.f(4));
                    if (grain.num_cb_points > 10) return error.Corrupt;
                    for (0..grain.num_cb_points) |i| {
                        grain.point_cb_value[i] = @intCast(try r.f(8));
                        grain.point_cb_scaling[i] = @intCast(try r.f(8));
                    }
                    grain.num_cr_points = @intCast(try r.f(4));
                    if (grain.num_cr_points > 10) return error.Corrupt;
                    for (0..grain.num_cr_points) |i| {
                        grain.point_cr_value[i] = @intCast(try r.f(8));
                        grain.point_cr_scaling[i] = @intCast(try r.f(8));
                    }
                }
                fi.grain_scaling_minus_8 = @intCast(try r.f(2));
                fi.ar_coeff_lag = @intCast(try r.f(2));
                const lag: u32 = fi.ar_coeff_lag;
                const num_pos_luma = 2 * lag * (lag + 1);
                const num_pos_chroma = if (grain.num_y_points > 0) num_pos_luma + 1 else num_pos_luma;
                if (grain.num_y_points > 0) {
                    for (0..num_pos_luma) |i| grain.ar_coeffs_y[i] = @intCast(@as(i32, @intCast(try r.f(8))) - 128);
                }
                if (csfl or grain.num_cb_points > 0) {
                    for (0..num_pos_chroma) |i| grain.ar_coeffs_cb[i] = @intCast(@as(i32, @intCast(try r.f(8))) - 128);
                }
                if (csfl or grain.num_cr_points > 0) {
                    for (0..num_pos_chroma) |i| grain.ar_coeffs_cr[i] = @intCast(@as(i32, @intCast(try r.f(8))) - 128);
                }
                fi.ar_coeff_shift_minus_6 = @intCast(try r.f(2));
                fi.grain_scale_shift = @intCast(try r.f(2));
                if (grain.num_cb_points > 0) {
                    grain.cb_mult = @intCast(try r.f(8));
                    grain.cb_luma_mult = @intCast(try r.f(8));
                    grain.cb_offset = @intCast(try r.f(9));
                }
                if (grain.num_cr_points > 0) {
                    grain.cr_mult = @intCast(try r.f(8));
                    grain.cr_luma_mult = @intCast(try r.f(8));
                    grain.cr_offset = @intCast(try r.f(9));
                }
                fi.overlap_flag = @intFromBool(try r.flag());
                fi.clip_to_restricted_range = @intFromBool(try r.flag());
                grain.film_grain_info_fields = fi;
            }
            grain.film_grain_info_fields.apply_grain = 1;
        }
    }

    // VA's picture parameters (FFmpeg's vaapi_av1)
    p.profile = seq.profile;
    p.order_hint_bits_minus_1 = if (seq.order_hint_bits > 0) seq.order_hint_bits - 1 else 0;
    p.bit_depth_idx = switch (seq.bit_depth) {
        8 => 0,
        10 => 1,
        else => 2,
    };
    p.matrix_coefficients = seq.matrix_coefficients;
    p.seq_info_fields = .{
        .still_picture = @intFromBool(seq.still_picture),
        .use_128x128_superblock = @intFromBool(seq.sb128),
        .enable_filter_intra = @intFromBool(seq.filter_intra),
        .enable_intra_edge_filter = @intFromBool(seq.intra_edge),
        .enable_interintra_compound = @intFromBool(seq.interintra),
        .enable_masked_compound = @intFromBool(seq.masked),
        .enable_dual_filter = @intFromBool(seq.dual_filter),
        .enable_order_hint = @intFromBool(seq.order_hint),
        .enable_jnt_comp = @intFromBool(seq.jnt_comp),
        .enable_cdef = @intFromBool(seq.cdef),
        .mono_chrome = @intFromBool(seq.mono),
        .color_range = @intFromBool(seq.color_range),
        .subsampling_x = @intFromBool(seq.ssx),
        .subsampling_y = @intFromBool(seq.ssy),
        .chroma_sample_position = @intFromBool(seq.chroma_sample_position != 0),
        .film_grain_params_present = @intFromBool(seq.film_grain),
    };
    p.frame_width_minus1 = @intCast(upscaled - 1);
    p.frame_height_minus1 = @intCast(height - 1);
    for (0..8) |i| p.ref_frame_map[i] = if (st.slots[i].valid) st.slots[i].surface else INVALID;
    p.ref_frame_idx = ref_frame_idx;
    p.primary_ref_frame = primary_ref_frame;
    p.order_hint = @intCast(order_hint);
    p.film_grain_info = grain;
    p.tile_count_minus_1 = @intCast(tile_cols * tile_rows - 1);
    p.pic_info_fields = .{
        .frame_type = @intCast(frame_type),
        .show_frame = @intFromBool(show_frame),
        .showable_frame = @intFromBool(showable),
        .error_resilient_mode = @intFromBool(error_res),
        .disable_cdf_update = @intFromBool(disable_cdf_update),
        .allow_screen_content_tools = @intFromBool(allow_screen_content),
        .force_integer_mv = @intFromBool(force_integer_mv),
        .allow_intrabc = @intFromBool(allow_intrabc),
        .use_superres = @intFromBool(superres_denom != 8),
        .allow_high_precision_mv = @intFromBool(allow_hp),
        .is_motion_mode_switchable = @intFromBool(motion_switchable),
        .use_ref_frame_mvs = @intFromBool(use_ref_frame_mvs),
        .disable_frame_end_update_cdf = @intFromBool(disable_frame_end_update_cdf),
        .uniform_tile_spacing_flag = @intFromBool(uniform),
        .allow_warped_motion = @intFromBool(allow_warped),
        .large_scale_tile = 0,
    };
    p.superres_scale_denominator = @intCast(superres_denom);
    p.interp_filter = interp;

    f.show = show_frame;
    f.showable = showable;
    f.key = frame_type == KEY_FRAME;
    f.refresh = refresh;
    f.width = upscaled;
    f.height = height;
    f.render = render;
    f.apply_grain = grain.film_grain_info_fields.apply_grain != 0;
    // the state a refreshed slot keeps (7.20)
    var ns = Slot{ .valid = true, .frame_type = frame_type, .upscaled_width = upscaled, .frame_width = width, .frame_height = height, .render_width = render[0], .render_height = render[1], .order_hint = order_hint, .gm = gm, .lf_ref = lf_ref, .lf_mode = lf_mode, .seg_enabled = seg_en, .seg_data = seg_data, .grain = grain, .showable = showable, .bit_depth = seq.bit_depth };
    for (0..7) |i| ns.saved_order_hints[i + 1] = st.slots[ref_frame_idx[i]].order_hint;
    f.next_slot = ns;
}

fn readDeltaQ(r: *Bits) Error!i32 {
    if (try r.flag()) return try r.su(7);
    return 0;
}

fn superresParams(seq: *const Seq, r: *Bits, width: *u32, upscaled: u32, denom: *u32) Error!void {
    var d: u32 = 8;
    if (seq.superres) {
        if (try r.flag()) d = try r.f(3) + 9;
    }
    denom.* = d;
    width.* = (upscaled * 8 + d / 2) / d;
}

fn frameSize(seq: *const Seq, r: *Bits, override: bool, width: *u32, height: *u32, upscaled: *u32, denom: *u32) Error!void {
    if (override) {
        upscaled.* = try r.f(seq.frame_width_bits) + 1;
        height.* = try r.f(seq.frame_height_bits) + 1;
    } else {
        upscaled.* = seq.max_width;
        height.* = seq.max_height;
    }
    try superresParams(seq, r, width, upscaled.*, denom);
}

fn renderSize(r: *Bits, upscaled: u32, height: u32, out: *[2]u32) Error!void {
    if (try r.flag()) {
        out[0] = try r.f(16) + 1;
        out[1] = try r.f(16) + 1;
    } else out.* = .{ upscaled, height };
}

/// The frame was decoded into `surface` (its slots refreshed: 7.20).
pub fn commit(st: *State, f: *const Frame, surface: u32) void {
    var s = f.next_slot;
    if (!f.show_existing) s.surface = surface;
    for (0..8) |i| {
        if (f.refresh & (@as(u8, 1) << @intCast(i)) != 0) st.slots[i] = s;
    }
}
