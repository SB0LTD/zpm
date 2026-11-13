//! @zpm/va enc_vp8 — a VP8 frame (RFC 6386, version 0, one token
//! partition): the kernels' dispatches (vp8_kernels.sig, on whichever
//! engine the driver has: the RTX's, or the CPU's), then the bitstream
//! from the macroblock records they leave, on the CPU.
//!
//! What the stream uses: key frames and inter frames from the last frame
//! (golden and altref are refreshed as the app asks but never predicted
//! from); the four 16x16 intra modes and B_PRED's ten; NEARESTMV, NEARMV,
//! ZEROMV and NEWMV (no SPLITMV); the normal loop filter with libvpx's
//! reference and mode deltas; no segmentation; coefficient probability
//! updates where they pay (libvpx's rule), kept for later frames unless
//! the stream is error resilient; the skip flag.
//!
//! The decoder's view is the encoder's: the reconstruction the kernels
//! leave is, bit for bit, what libvpx and FFmpeg decode the stream to (the
//! tests in WSL check it).
//!
//! Allocation-free: fixed state; the caller's buffers.

const std = @import("std");
const dsl = @import("vpx_dsl.sig");
const k8 = @import("vp8_kernels.sig");
const t8 = @import("vp8_tables.sig");
const vb = @import("vpx_bool.sig");

pub const Kernel = enum { load, motion, encode, filter };

/// The reconstruction and its reference: two frames, then the source.
pub const FRAMES = 2;
pub const MAX_MBW = 256;

/// Where everything is in the kernels' memory.
pub const Layout = struct {
    width: u32,
    height: u32,
    mbw: u32,
    mbh: u32,
    aw: u32,
    ah: u32,
    ys: u32,
    cs: u32,
    plane_y: u32,
    plane_c: u32,
    frame_bytes: u32,
    mem_bytes: usize,
    info_bytes: usize,

    pub fn of(width: u32, height: u32) Layout {
        const mbw = (width + 15) / 16;
        const mbh = (height + 15) / 16;
        const aw = mbw * 16;
        const ah = mbh * 16;
        const plane_y = aw * ah;
        const plane_c = (aw / 2) * (ah / 2);
        const frame_bytes = std.mem.alignForward(u32, plane_y + 2 * plane_c, 256);
        return .{
            .width = width,
            .height = height,
            .mbw = mbw,
            .mbh = mbh,
            .aw = aw,
            .ah = ah,
            .ys = aw,
            .cs = aw / 2,
            .plane_y = plane_y,
            .plane_c = plane_c,
            .frame_bytes = frame_bytes,
            .mem_bytes = @as(usize, frame_bytes) * (FRAMES + 1),
            .info_bytes = @as(usize, mbw) * mbh * k8.MB_BYTES,
        };
    }
    pub fn yOff(l: Layout, f: usize) u32 {
        return @intCast(f * l.frame_bytes);
    }
    pub fn uOff(l: Layout, f: usize) u32 {
        return l.yOff(f) + l.plane_y;
    }
    pub fn vOff(l: Layout, f: usize) u32 {
        return l.uOff(f) + l.plane_c;
    }
};

/// The input picture as the load kernel reads it (binding SURF).
pub const Surface = struct {
    luma: u32,
    chroma: u32,
    pitch_luma: u32,
    pitch_chroma: u32,
    /// tiling.Swizzle numbers of the planes
    swz_luma: u32,
    swz_chroma: u32,
    /// log2 of GOBs a block
    gobs: u32,
};

/// What the app (or the rate control) asks of a frame.
pub const Picture = struct {
    key: bool,
    q: u7,
    show: bool = true,
    refresh_golden: bool = true,
    refresh_alt: bool = true,
    refresh_last: bool = true,
    /// probability updates last only for their frame
    error_resilient: bool = false,
    sharpness: u3 = 0,
    /// null: the encoder's choice for the quantizer
    filter_level: ?u6 = null,
    search_range: u32 = 16,
};

pub const REF_LF_DELTAS = [4]i8{ 2, 0, -2, -2 };
pub const MODE_LF_DELTAS = [4]i8{ 4, -2, 2, 4 };

/// What a finished frame came to.
pub const Stats = struct {
    bytes: usize = 0,
    key: bool = false,
    q: u7 = 0,
    filter_level: u6 = 0,
    intra_mbs: u32 = 0,
    skipped_mbs: u32 = 0,
    first_partition: usize = 0,
};

pub const Error = error{ TooBig, NoSpace, Engine };

/// The encoder's state across frames.
pub const Encoder = struct {
    lay: Layout,
    /// the decoder's coefficient probabilities as the last frame left them
    coef: [4][8][3][11]u8 = t8.DEFAULT_COEF_PROBS,
    /// the frame slot the next reconstruction goes into
    cur: u1 = 0,
    have_last: bool = false,
    frames: u64 = 0,
    /// the last frame's share of intra macroblocks (prob_intra's guess)
    prob_intra: u8 = 63,
    last: Stats = .{},

    pub fn init(width: u32, height: u32) Error!Encoder {
        if (width == 0 or height == 0 or width > 16383 or height > 16383) return error.TooBig;
        const l = Layout.of(width, height);
        if (l.mbw > MAX_MBW) return error.TooBig;
        return .{ .lay = l };
    }

    /// The reconstruction of the last frame (its slot), for a reader.
    pub fn lastSlot(e: *const Encoder) usize {
        return e.cur ^ 1;
    }
};

// ── Quantizers, costs, the filter level ─────────────────────────────────────

pub fn dcQ(q: i32) i32 {
    return t8.DC_QLOOKUP[@intCast(std.math.clamp(q, 0, 127))];
}
pub fn acQ(q: i32) i32 {
    return t8.AC_QLOOKUP[@intCast(std.math.clamp(q, 0, 127))];
}

/// The six dequantization factors (Y1 DC, Y1 AC, Y2 DC, Y2 AC, UV DC, UV
/// AC) of base index `q` (no deltas).
pub fn factors(q: u7) [6]i32 {
    const qi: i32 = q;
    return .{ dcQ(qi), acQ(qi), dcQ(qi) * 2, @max((acQ(qi) * 101581) >> 16, 8), @min(dcQ(qi), 132), acQ(qi) };
}

/// The filter level the encoder picks for `q` (libvpx searches; this is a
/// fit of its choices on natural video).
pub fn filterLevel(q: u7, key: bool) u6 {
    var l: i32 = @divTrunc(@as(i32, q) * 5 + 4, 8);
    if (key) l -= 2;
    return @intCast(std.math.clamp(l, 0, 63));
}

fn cost16(c: u32) u32 {
    return (c + 8) >> 4;
}

/// The kernels' parameters common to the frame.
pub fn frameParams(e: *const Encoder, surf: Surface, pic: Picture, key: bool, level: u6) [dsl.MAX_PARAMS]u32 {
    const l = e.lay;
    var p: [dsl.MAX_PARAMS]u32 = @splat(0);
    p[k8.P_MBW] = l.mbw;
    p[k8.P_MBH] = l.mbh;
    p[k8.P_YS] = l.ys;
    p[k8.P_CS] = l.cs;
    p[k8.P_SRC_Y] = l.yOff(FRAMES);
    p[k8.P_SRC_U] = l.uOff(FRAMES);
    p[k8.P_SRC_V] = l.vOff(FRAMES);
    p[k8.P_REC_Y] = l.yOff(e.cur);
    p[k8.P_REC_U] = l.uOff(e.cur);
    p[k8.P_REC_V] = l.vOff(e.cur);
    p[k8.P_REF_Y] = l.yOff(e.cur ^ 1);
    p[k8.P_REF_U] = l.uOff(e.cur ^ 1);
    p[k8.P_REF_V] = l.vOff(e.cur ^ 1);
    p[k8.P_KEY] = @intFromBool(key);
    const f = factors(pic.q);
    for (0..6) |i| {
        const q: u32 = @intCast(f[i]);
        p[k8.P_Q + i] = q;
        p[k8.P_QI + i] = (65536 + q - 1) / q;
        // rounding: DCs a little more generous than ACs
        const dc_like = i == k8.Q_Y1DC or i == k8.Q_UVDC or i == k8.Q_Y2DC;
        const num: u32 = if (dc_like) 7 else 5;
        p[k8.P_QR + i] = (q * num) >> 4;
    }
    // a bit's weight: about 0.4 of the AC step, in SATD units * 16
    p[k8.P_LAMBDA] = @intCast(@max(8, @divTrunc(acQ(pic.q) * 26, 4)));
    p[k8.P_RANGE] = pic.search_range;
    // the filter levels with the deltas (vp8_loop_filter_frame_init)
    const lv: i32 = level;
    const lf = [4]i32{
        lv + REF_LF_DELTAS[0] + MODE_LF_DELTAS[0],
        lv + REF_LF_DELTAS[0],
        lv + REF_LF_DELTAS[1] + MODE_LF_DELTAS[1],
        lv + REF_LF_DELTAS[1] + MODE_LF_DELTAS[2],
    };
    for (0..4) |i| p[k8.P_LF + i] = if (level == 0) 0 else @intCast(std.math.clamp(lf[i], 0, 63));
    p[k8.P_SHARP] = pic.sharpness;
    p[k8.P_S_LUMA] = surf.luma;
    p[k8.P_S_CHROMA] = surf.chroma;
    p[k8.P_S_PITCH_L] = surf.pitch_luma;
    p[k8.P_S_PITCH_C] = surf.pitch_chroma;
    p[k8.P_S_SWZ_L] = surf.swz_luma;
    p[k8.P_S_SWZ_C] = surf.swz_chroma;
    p[k8.P_S_GOBS] = surf.gobs;
    p[k8.P_W] = l.width;
    p[k8.P_H] = l.height;
    p[k8.P_AW] = l.aw;
    p[k8.P_AH] = l.ah;
    // the modes' costs
    const intra_flag: u32 = if (key) 0 else vb.cost(false, e.prob_intra);
    const inter_flag: u32 = if (key) 0 else vb.cost(true, e.prob_intra);
    const ycodes = comptime vb.codes(&t8.YMODE_TREE, 5);
    const kfcodes = comptime vb.codes(&t8.KF_YMODE_TREE, 5);
    for (0..5) |m| {
        const c = if (key) vb.codeCost(&t8.KF_YMODE_TREE, &t8.KF_YMODE_PROB, kfcodes[m]) else vb.codeCost(&t8.YMODE_TREE, &t8.DEFAULT_YMODE_PROB, ycodes[m]);
        p[k8.P_MCOST + m] = cost16(c + intra_flag);
    }
    // (an inter macroblock: its flag, LAST, and a mode's few bits)
    p[k8.P_INTER_COST] = cost16(inter_flag + vb.cost(false, 255) + 2 * 256);
    const bcodes = comptime vb.codes(&t8.BMODE_TREE, 10);
    for (0..10) |m| p[k8.P_BCOST + m] = cost16(vb.codeCost(&t8.BMODE_TREE, &t8.BMODE_PROB, bcodes[m]));
    const uvcodes = comptime vb.codes(&t8.UV_MODE_TREE, 4);
    for (0..4) |m| p[k8.P_UVCOST + m] = cost16(vb.codeCost(&t8.UV_MODE_TREE, if (key) &t8.KF_UV_MODE_PROB else &t8.DEFAULT_UV_MODE_PROB, uvcodes[m]));
    return p;
}

fn ceilLog2(x: u32) u32 {
    var s: u32 = 0;
    while ((@as(u64, 1) << @intCast(s)) < x) s += 1;
    return s;
}

/// The kernels of one frame, dispatched on `eng` (and waited for): load,
/// motion (inter frames), the encode wavefronts, the filter's.
pub fn dispatchFrame(e: *const Encoder, eng: anytype, base: [dsl.MAX_PARAMS]u32, key: bool, level: u6) !void {
    const l = e.lay;
    var p = base;
    for (0..3) |plane| {
        const words = if (plane == 0) l.aw / 4 else l.aw / 8;
        const rows = if (plane == 0) l.ah else l.ah / 2;
        const shift = ceilLog2(words);
        p[k8.P_PLANE] = @intCast(plane);
        p[k8.P_WSHIFT] = shift;
        p[k8.P_COUNT] = rows << @intCast(shift);
        try eng.dispatch(.load, p[k8.P_COUNT], &p);
    }
    if (!key) {
        const shift = ceilLog2(l.mbw);
        p[k8.P_WSHIFT] = shift;
        p[k8.P_COUNT] = l.mbh << @intCast(shift);
        try eng.dispatch(.motion, p[k8.P_COUNT], &p);
    }
    const waves = l.mbw + 2 * (l.mbh - 1);
    inline for (0..2) |pass| {
        if (pass == 1 and level == 0) break;
        for (0..waves) |t| {
            const ti: i32 = @intCast(t);
            const ymin: i32 = @max(0, @divFloor(ti - @as(i32, @intCast(l.mbw)) + 2, 2));
            const ymax: i32 = @min(@as(i32, @intCast(l.mbh)) - 1, @divFloor(ti, 2));
            if (ymax < ymin) continue;
            p[k8.P_WAVE] = @intCast(t);
            p[k8.P_COUNT] = @intCast(ymax - ymin + 1);
            try eng.dispatch(if (pass == 0) .encode else .filter, p[k8.P_COUNT], &p);
        }
    }
    try eng.finish();
}

// ── The bitstream ───────────────────────────────────────────────────────────

const Counts = [4][8][3][11][2]u32;
const Probs = [4][8][3][11]u8;

/// Where token decisions go: counted, or written.
const Sink = struct {
    w: ?*vb.Writer = null,
    counts: ?*Counts = null,
    probs: *const Probs,

    fn tree(s: *Sink, t: usize, band: usize, ctx: usize, node: usize, b: bool) void {
        if (s.w) |w| w.write(b, s.probs[t][band][ctx][node]);
        if (s.counts) |c| c[t][band][ctx][node][@intFromBool(b)] += 1;
    }
    fn fixed(s: *Sink, b: bool, p: u8) void {
        if (s.w) |w| w.write(b, p);
    }
};

/// One block's tokens (RFC 6386 13; libvpx's GetCoeffs in reverse); whether
/// it had a nonzero coefficient (the next blocks' context).
fn tokens(s: *Sink, t: usize, first: usize, ctx0: usize, coefs: []const u8) bool {
    var v: [16]i32 = undefined;
    var eob: usize = 0;
    for (0..16) |k| {
        v[k] = std.mem.readInt(i16, coefs[2 * @as(usize, t8.ZIGZAG[k]) ..][0..2], .little);
        if (k >= first and v[k] != 0) eob = k + 1;
    }
    var band: usize = t8.COEF_BANDS[first];
    var ctx = ctx0;
    if (eob == 0) {
        s.tree(t, band, ctx, 0, false);
        return false;
    }
    s.tree(t, band, ctx, 0, true);
    var pos = first;
    while (true) {
        const x = v[pos];
        if (x == 0) {
            s.tree(t, band, ctx, 1, false);
            pos += 1;
            band = t8.COEF_BANDS[pos];
            ctx = 0;
            continue;
        }
        s.tree(t, band, ctx, 1, true);
        const a: u32 = @abs(x);
        if (a == 1) {
            s.tree(t, band, ctx, 2, false);
        } else {
            s.tree(t, band, ctx, 2, true);
            if (a <= 4) {
                s.tree(t, band, ctx, 3, false);
                if (a == 2) {
                    s.tree(t, band, ctx, 4, false);
                } else {
                    s.tree(t, band, ctx, 4, true);
                    s.tree(t, band, ctx, 5, a == 4);
                }
            } else {
                s.tree(t, band, ctx, 3, true);
                if (a <= 10) {
                    s.tree(t, band, ctx, 6, false);
                    if (a <= 6) {
                        s.tree(t, band, ctx, 7, false);
                        s.fixed(a == 6, 159);
                    } else {
                        s.tree(t, band, ctx, 7, true);
                        const d = a - 7;
                        s.fixed(d >> 1 != 0, 165);
                        s.fixed(d & 1 != 0, 145);
                    }
                } else {
                    s.tree(t, band, ctx, 6, true);
                    const cat: u5 = if (a <= 18) 0 else if (a <= 34) 1 else if (a <= 66) 2 else 3;
                    s.tree(t, band, ctx, 8, cat >> 1 != 0);
                    s.tree(t, band, ctx, 9 + @as(usize, cat >> 1), cat & 1 != 0);
                    const tab: []const u8 = switch (cat) {
                        0 => &t8.CAT3,
                        1 => &t8.CAT4,
                        2 => &t8.CAT5,
                        else => &t8.CAT6,
                    };
                    const extra = a - (3 + (@as(u32, 8) << cat));
                    for (tab, 0..) |pr, i| s.fixed((extra >> @intCast(tab.len - 1 - i)) & 1 != 0, pr);
                }
            }
        }
        s.fixed(x < 0, 128);
        pos += 1;
        if (pos == 16) break;
        band = t8.COEF_BANDS[pos];
        ctx = if (a == 1) 1 else 2;
        if (pos == eob) {
            s.tree(t, band, ctx, 0, false);
            break;
        }
        s.tree(t, band, ctx, 0, true);
    }
    return true;
}

/// A macroblock's record, as the packer reads it.
const Rec = struct {
    bytes: []const u8,
    fn ymode(r: Rec) u8 {
        return r.bytes[k8.I_YMODE];
    }
    fn uvmode(r: Rec) u8 {
        return r.bytes[k8.I_UVMODE];
    }
    fn skip(r: Rec) bool {
        return r.bytes[k8.I_SKIP] != 0;
    }
    fn mv(r: Rec) [2]i16 {
        return .{ std.mem.readInt(i16, r.bytes[k8.I_MVR..][0..2], .little), std.mem.readInt(i16, r.bytes[k8.I_MVC..][0..2], .little) };
    }
    fn bmode(r: Rec, i: usize) u8 {
        return r.bytes[k8.I_BMODES + i];
    }
    fn block(r: Rec, i: usize) []const u8 {
        return r.bytes[k8.I_COEF + 32 * i ..][0..32];
    }
};

/// The token contexts: above (per macroblock column) and left, 9 each (Y
/// 0..3, U 4..5, V 6..7, Y2 8).
const Ctx = struct {
    above: [MAX_MBW][9]u8 = undefined,
    left: [9]u8 = undefined,
};

/// A macroblock's tokens (in the decoder's order: Y2, Y, U, V).
fn mbTokens(s: *Sink, cx: *Ctx, col: usize, r: Rec) void {
    const a = &cx.above[col];
    const l = &cx.left;
    const has_y2 = r.ymode() != t8.B_PRED;
    if (r.skip()) {
        // vp8_reset_mb_tokens_context
        @memset(a[0..8], 0);
        @memset(l[0..8], 0);
        if (has_y2) {
            a[8] = 0;
            l[8] = 0;
        }
        return;
    }
    var first: usize = 0;
    var ytype: usize = 3;
    if (has_y2) {
        const nz = tokens(s, 1, 0, a[8] + l[8], r.block(24));
        a[8] = @intFromBool(nz);
        l[8] = @intFromBool(nz);
        first = 1;
        ytype = 0;
    }
    for (0..16) |i| {
        const ai = i & 3;
        const li = i >> 2;
        const nz = tokens(s, ytype, first, a[ai] + l[li], r.block(i));
        a[ai] = @intFromBool(nz);
        l[li] = @intFromBool(nz);
    }
    for (16..24) |i| {
        const ai = 4 + (@as(usize, @intFromBool(i > 19)) << 1) + (i & 1);
        const li = 4 + (@as(usize, @intFromBool(i > 19)) << 1) + @intFromBool((i & 3) > 1);
        const nz = tokens(s, 2, 0, a[ai] + l[li], r.block(i));
        a[ai] = @intFromBool(nz);
        l[li] = @intFromBool(nz);
    }
}

fn allTokens(s: *Sink, l: Layout, records: []const u8) void {
    var cx = Ctx{};
    for (0..l.mbw) |c| @memset(&cx.above[c], 0);
    for (0..l.mbh) |row| {
        @memset(&cx.left, 0);
        for (0..l.mbw) |col| {
            const r = Rec{ .bytes = records[(row * l.mbw + col) * k8.MB_BYTES ..][0..k8.MB_BYTES] };
            mbTokens(s, &cx, col, r);
        }
    }
}

/// What a macroblock is to its neighbours' mode coding.
const ModeInfo = struct {
    /// 0 intra (or outside the frame), 1 LAST
    ref: u8 = 0,
    mv: [2]i16 = .{ 0, 0 },
    ymode: u8 = 0,
    bmodes: [16]u8 = @splat(0),
};

/// The implied subblock modes of a 16x16 mode (key frames' contexts).
fn impliedB(ymode: u8) u8 {
    return switch (ymode) {
        t8.V_PRED => t8.B_VE_PRED,
        t8.H_PRED => t8.B_HE_PRED,
        t8.TM_PRED => t8.B_TM_PRED,
        else => t8.B_DC_PRED,
    };
}

fn subMode(mi: *const ModeInfo, i: usize) u8 {
    return if (mi.ymode == t8.B_PRED) mi.bmodes[i] else impliedB(mi.ymode);
}

fn writeMvComponent(w: *vb.Writer, v: i32, p: *const [19]u8) void {
    const x: u32 = @abs(v);
    const small = comptime vb.codes(&t8.SMALL_MVTREE, 8);
    if (x < 8) {
        w.write(false, p[t8.MVP_IS_SHORT]);
        vb.writeCode(w, &t8.SMALL_MVTREE, p[t8.MVP_SHORT..][0..7], small[x]);
        if (x == 0) return;
    } else {
        w.write(true, p[t8.MVP_IS_SHORT]);
        for (0..3) |i| w.write((x >> @intCast(i)) & 1 != 0, p[t8.MVP_BITS + i]);
        var i: usize = t8.MV_LONG_WIDTH - 1;
        while (i > 3) : (i -= 1) w.write((x >> @intCast(i)) & 1 != 0, p[t8.MVP_BITS + i]);
        if (x & 0xfff0 != 0) w.write((x >> 3) & 1 != 0, p[t8.MVP_BITS + 3]);
    }
    w.write(v < 0, p[t8.MVP_SIGN]);
}

/// vp8_clamp_mv2: a near vector held within 16 pels (plus the block) of
/// the frame.
fn clampMv2(mv: [2]i32, col: usize, row: usize, l: Layout) [2]i32 {
    const to_left: i32 = -@as(i32, @intCast(col * 16)) * 8;
    const to_right: i32 = @as(i32, @intCast((l.mbw - 1 - col) * 16)) * 8;
    const to_top: i32 = -@as(i32, @intCast(row * 16)) * 8;
    const to_bottom: i32 = @as(i32, @intCast((l.mbh - 1 - row) * 16)) * 8;
    const margin = 16 << 3;
    return .{ std.math.clamp(mv[0], to_top - margin, to_bottom + margin), std.math.clamp(mv[1], to_left - margin, to_right + margin) };
}

fn eqMv(a: [2]i32, b: [2]i32) bool {
    return a[0] == b[0] and a[1] == b[1];
}

/// An inter macroblock's mode and vector, as the decoder reads them
/// (read_mb_modes_mv): the near vectors of above, left, above-left.
fn writeInterMb(w: *vb.Writer, above: *const ModeInfo, left: *const ModeInfo, aboveleft: *const ModeInfo, mv: [2]i32, col: usize, row: usize, l: Layout) void {
    var near: [4][2]i32 = @splat(.{ 0, 0 });
    var cnt = [4]i32{ 0, 0, 0, 0 };
    var n: usize = 0;
    if (above.ref != 0) {
        if (above.mv[0] != 0 or above.mv[1] != 0) {
            n += 1;
            near[n] = .{ above.mv[0], above.mv[1] };
        }
        cnt[n] += 2;
    }
    if (left.ref != 0) {
        if (left.mv[0] != 0 or left.mv[1] != 0) {
            const m = [2]i32{ left.mv[0], left.mv[1] };
            if (!eqMv(m, near[n])) {
                n += 1;
                near[n] = m;
            }
            cnt[n] += 2;
        } else cnt[0] += 2;
    }
    if (aboveleft.ref != 0) {
        if (aboveleft.mv[0] != 0 or aboveleft.mv[1] != 0) {
            const m = [2]i32{ aboveleft.mv[0], aboveleft.mv[1] };
            if (!eqMv(m, near[n])) {
                n += 1;
                near[n] = m;
            }
            cnt[n] += 1;
        } else cnt[0] += 1;
    }
    const zero = mv[0] == 0 and mv[1] == 0;
    w.write(!zero, t8.MODE_CONTEXTS[@intCast(cnt[0])][0]);
    if (zero) return;
    // the decoder's merge and swap (CNT_SPLITMV is cnt[3] here)
    if (cnt[3] > 0 and eqMv(near[n], near[1])) cnt[1] += 1;
    if (cnt[2] > cnt[1]) {
        std.mem.swap(i32, &cnt[1], &cnt[2]);
        std.mem.swap([2]i32, &near[1], &near[2]);
    }
    const nearest = clampMv2(near[1], col, row, l);
    const is_nearest = eqMv(mv, nearest);
    w.write(!is_nearest, t8.MODE_CONTEXTS[@intCast(cnt[1])][1]);
    if (is_nearest) return;
    const nearmv = clampMv2(near[2], col, row, l);
    const is_near = eqMv(mv, nearmv);
    w.write(!is_near, t8.MODE_CONTEXTS[@intCast(cnt[2])][2]);
    if (is_near) return;
    // NEWMV (not SPLITMV: no neighbour is split)
    w.write(false, t8.MODE_CONTEXTS[0][3]);
    const best_i: usize = @intFromBool(cnt[1] >= cnt[0]);
    const best = clampMv2(near[best_i], col, row, l);
    writeMvComponent(w, @divExact(mv[0] - best[0], 2), &t8.DEFAULT_MV_CONTEXT[0]);
    writeMvComponent(w, @divExact(mv[1] - best[1], 2), &t8.DEFAULT_MV_CONTEXT[1]);
}

/// The first partition's header (after the frame tag).
fn writeHeader(w: *vb.Writer, pic: Picture, key: bool, level: u6, probs: *const Probs, update: *const [4][8][3][11]bool) void {
    if (key) {
        w.bit(false); // color space
        w.bit(false); // clamping required
    }
    w.bit(false); // no segmentation
    w.bit(false); // the normal filter
    w.literal(6, level);
    w.literal(3, pic.sharpness);
    // the reference and mode deltas: sent with key frames (which reset
    // them), kept after
    w.bit(true);
    w.bit(key);
    if (key) {
        for (REF_LF_DELTAS ++ MODE_LF_DELTAS) |d| {
            w.bit(true);
            w.literal(6, @abs(d));
            w.bit(d < 0);
        }
    }
    w.literal(2, 0); // one token partition
    w.literal(7, pic.q);
    for (0..5) |_| w.bit(false); // no quantizer deltas
    if (!key) {
        w.bit(pic.refresh_golden);
        w.bit(pic.refresh_alt);
        if (!pic.refresh_golden) w.literal(2, 0);
        if (!pic.refresh_alt) w.literal(2, 0);
        w.bit(false); // sign bias golden
        w.bit(false); // sign bias altref
    }
    w.bit(!pic.error_resilient); // refresh_entropy_probs
    if (!key) w.bit(pic.refresh_last);
    for (0..4) |i| for (0..8) |j| for (0..3) |k| for (0..11) |n| {
        const up = update[i][j][k][n];
        w.write(up, t8.COEF_UPDATE_PROBS[i][j][k][n]);
        if (up) w.literal(8, probs[i][j][k][n]);
    };
}

/// The frame's bytes: the tag, the key frame's start code and size, the
/// first partition (header, modes) and the token partition. `scratch`
/// holds the partitions while they are written.
pub fn pack(e: *Encoder, records: []const u8, pic: Picture, key: bool, level: u6, out: []u8, scratch: []u8) Error!Stats {
    const l = e.lay;
    var st = Stats{ .key = key, .q = pic.q, .filter_level = level };
    if (key) e.coef = t8.DEFAULT_COEF_PROBS;

    // the probabilities: libvpx's savings rule on this frame's counts
    var counts: Counts = std.mem.zeroes(Counts);
    {
        var s = Sink{ .counts = &counts, .probs = &e.coef };
        allTokens(&s, l, records);
    }
    var probs: Probs = e.coef;
    var update: [4][8][3][11]bool = std.mem.zeroes([4][8][3][11]bool);
    for (0..4) |i| for (0..8) |j| for (0..3) |k| for (0..11) |n| {
        const c = counts[i][j][k][n];
        const old = e.coef[i][j][k][n];
        const new = vb.bestProb(c[0], c[1]);
        if (new == old) continue;
        const upd = t8.COEF_UPDATE_PROBS[i][j][k][n];
        const before = vb.branchCost(c[0], c[1], old) + vb.cost(false, upd);
        const after = vb.branchCost(c[0], c[1], new) + vb.cost(true, upd) + 8 * 256;
        if (after < before) {
            probs[i][j][k][n] = new;
            update[i][j][k][n] = true;
        }
    };

    // the macroblocks' modes
    var n_skip: u32 = 0;
    var n_intra: u32 = 0;
    const mbs = l.mbw * l.mbh;
    for (0..mbs) |m| {
        const r = Rec{ .bytes = records[m * k8.MB_BYTES ..][0..k8.MB_BYTES] };
        n_skip += @intFromBool(r.skip());
        n_intra += @intFromBool(r.ymode() != k8.MODE_INTER);
    }
    const prob_skip = vb.bestProb(mbs - n_skip, n_skip);
    const prob_intra = vb.bestProb(n_intra, mbs - n_intra);

    const half = scratch.len / 2;
    var w = vb.Writer.init(scratch[0..half]);
    writeHeader(&w, pic, key, level, &probs, &update);
    w.bit(true); // mb_no_coeff_skip
    w.literal(8, prob_skip);
    if (!key) {
        w.literal(8, prob_intra);
        w.literal(8, 255); // prob_last: every inter macroblock is LAST's
        w.literal(8, 128); // prob_gf
        w.bit(false); // no ymode probabilities
        w.bit(false); // no uv mode probabilities
        for (0..2) |c| for (0..19) |i| w.write(false, t8.MV_UPDATE_PROBS[c][i]);
    }
    var rows: [2][MAX_MBW + 1]ModeInfo = @splat(@splat(.{}));
    const border = ModeInfo{};
    const kfy = comptime vb.codes(&t8.KF_YMODE_TREE, 5);
    const ycodes = comptime vb.codes(&t8.YMODE_TREE, 5);
    const bcodes = comptime vb.codes(&t8.BMODE_TREE, 10);
    const uvcodes = comptime vb.codes(&t8.UV_MODE_TREE, 4);
    for (0..l.mbh) |row| {
        const cur = &rows[row & 1];
        const prev = &rows[(row & 1) ^ 1];
        for (0..l.mbw) |col| {
            const r = Rec{ .bytes = records[(row * l.mbw + col) * k8.MB_BYTES ..][0..k8.MB_BYTES] };
            const ym = r.ymode();
            var mi = ModeInfo{ .ymode = ym };
            if (ym == t8.B_PRED) {
                for (0..16) |i| mi.bmodes[i] = r.bmode(i);
            }
            w.write(r.skip(), prob_skip);
            const above: *const ModeInfo = if (row > 0) &prev[col] else &border;
            const left: *const ModeInfo = if (col > 0) &cur[col - 1] else &border;
            const aboveleft: *const ModeInfo = if (row > 0 and col > 0) &prev[col - 1] else &border;
            if (key) {
                vb.writeCode(&w, &t8.KF_YMODE_TREE, &t8.KF_YMODE_PROB, kfy[ym]);
                if (ym == t8.B_PRED) {
                    for (0..16) |i| {
                        const a = if (i < 4) subMode(above, i + 12) else mi.bmodes[i - 4];
                        const lft = if (i & 3 == 0) subMode(left, i + 3) else mi.bmodes[i - 1];
                        vb.writeCode(&w, &t8.BMODE_TREE, &t8.KF_BMODE_PROB[a][lft], bcodes[mi.bmodes[i]]);
                    }
                }
                vb.writeCode(&w, &t8.UV_MODE_TREE, &t8.KF_UV_MODE_PROB, uvcodes[r.uvmode()]);
            } else if (ym != k8.MODE_INTER) {
                w.write(false, prob_intra);
                vb.writeCode(&w, &t8.YMODE_TREE, &t8.DEFAULT_YMODE_PROB, ycodes[ym]);
                if (ym == t8.B_PRED) {
                    for (0..16) |i| vb.writeCode(&w, &t8.BMODE_TREE, &t8.BMODE_PROB, bcodes[mi.bmodes[i]]);
                }
                vb.writeCode(&w, &t8.UV_MODE_TREE, &t8.DEFAULT_UV_MODE_PROB, uvcodes[r.uvmode()]);
            } else {
                w.write(true, prob_intra);
                w.write(false, 255); // LAST
                const mv = r.mv();
                writeInterMb(&w, above, left, aboveleft, .{ mv[0], mv[1] }, col, row, l);
                mi.ref = 1;
                mi.mv = mv;
            }
            cur[col] = mi;
        }
    }
    const first_len = w.finish();
    if (w.overflow) return error.NoSpace;

    // the tokens
    var tw = vb.Writer.init(scratch[half..]);
    {
        var s = Sink{ .w = &tw, .probs = &probs };
        allTokens(&s, l, records);
    }
    const tok_len = tw.finish();
    if (tw.overflow) return error.NoSpace;

    // the frame
    const head: usize = if (key) 10 else 3;
    if (head + first_len + tok_len > out.len) return error.NoSpace;
    if (first_len >= 1 << 19) return error.NoSpace;
    const tag: u32 = @as(u32, @intFromBool(!key)) | (0 << 1) | (@as(u32, @intFromBool(pic.show)) << 4) | (@as(u32, @intCast(first_len)) << 5);
    out[0] = @truncate(tag);
    out[1] = @truncate(tag >> 8);
    out[2] = @truncate(tag >> 16);
    if (key) {
        out[3] = 0x9d;
        out[4] = 0x01;
        out[5] = 0x2a;
        std.mem.writeInt(u16, out[6..8], @intCast(l.width), .little);
        std.mem.writeInt(u16, out[8..10], @intCast(l.height), .little);
    }
    @memcpy(out[head..][0..first_len], scratch[0..first_len]);
    @memcpy(out[head + first_len ..][0..tok_len], scratch[half..][0..tok_len]);

    // what lasts
    if (!pic.error_resilient) e.coef = probs;
    e.prob_intra = if (key) e.prob_intra else @max(prob_intra, 8);
    st.bytes = head + first_len + tok_len;
    st.first_partition = first_len;
    st.intra_mbs = n_intra;
    st.skipped_mbs = n_skip;
    return st;
}

/// One frame: the kernels on `eng`, then the bitstream into `out`.
pub fn encodeFrame(e: *Encoder, eng: anytype, surf: Surface, pic0: Picture, out: []u8, scratch: []u8) !Stats {
    var pic = pic0;
    const key = pic.key or !e.have_last;
    pic.key = key;
    const level: u6 = pic.filter_level orelse filterLevel(pic.q, key);
    const p = frameParams(e, surf, pic, key, level);
    try dispatchFrame(e, eng, p, key, level);
    const st = try pack(e, eng.records(), pic, key, level, out, scratch);
    // the reconstruction becomes the reference (unless the app keeps it)
    if (key or pic.refresh_last) e.cur ^= 1;
    e.have_last = true;
    e.frames += 1;
    e.last = st;
    return st;
}

/// The engine that runs the kernels on the CPU (vpx_dsl.Cpu).
pub const CpuEngine = struct {
    mem: []u8,
    info: []u8,
    surf: []u8,

    pub fn dispatch(e: *CpuEngine, comptime k: Kernel, threads: u32, params: *const [dsl.MAX_PARAMS]u32) Error!void {
        const bufs = [dsl.MAX_BUFS][]u8{ e.mem, e.info, e.surf, &.{} };
        switch (k) {
            .load => dsl.runCpu(k8.load, bufs, params, threads),
            .motion => dsl.runCpu(k8.motion, bufs, params, threads),
            .encode => dsl.runCpu(k8.encode, bufs, params, threads),
            .filter => dsl.runCpu(k8.filter, bufs, params, threads),
        }
    }
    pub fn finish(_: *CpuEngine) Error!void {}
    pub fn records(e: *CpuEngine) []const u8 {
        return e.info;
    }
};
