//! @zpm/va enc_vp9 — a VP9 frame (profile 0, 8-bit 4:2:0, one tile): the
//! kernels' dispatches (vp9_kernels.sig, on whichever engine the driver
//! has: the RTX's, or the CPU's), then the bitstream from the unit records
//! they leave, on the CPU.
//!
//! What the stream uses: key frames and inter frames from one reference
//! (the app's LAST slot; GOLDEN and ALTREF name the same frame), 16x16
//! blocks where the frame's 8x8 grid has them and 8x8 blocks at its edges
//! (64x64 and 32x32 always split); the intra modes DC, V, H and TM;
//! NEARESTMV, NEARMV, ZEROMV and NEWMV at quarter pels with the regular
//! eight-tap filter; transform sizes chosen per block (TX_MODE_SELECT:
//! intra the block's own size or 4x4, inter 8x8 or the block's); the loop
//! filter with VP9's default reference and mode deltas; no segmentation.
//! Every frame is error resilient: the default probabilities, no backward
//! adaptation, no previous frame's vectors, so a frame's bits depend on
//! nothing but the reference picture. The coefficients' probabilities that
//! pay for themselves are updated for the frame (libvpx's savings search,
//! on the frame's own counts: a first pass of the tile counts them).
//!
//! The decoder's view is the encoder's: the reconstruction the kernels
//! leave is, bit for bit, what libvpx and FFmpeg decode the stream to (the
//! tests in WSL check it).
//!
//! Allocation-free: fixed state; the caller's buffers.

const std = @import("std");
const dsl = @import("vpx_dsl.sig");
const k8 = @import("vp8_kernels.sig");
const k9 = @import("vp9_kernels.sig");
const t9 = @import("vp9_tables.sig");
const e9 = @import("vp9_enc_tables.sig");
const vb = @import("vpx_bool.sig");
const enc_vp8 = @import("enc_vp8.sig");

pub const Kernel = enum { load, motion, luma16, luma8, chroma16, chroma8, lfv, lfh };

/// The input picture as the load kernel reads it (VP8's).
pub const Surface = enc_vp8.Surface;

/// Reconstructions kept (the references the slots name, the frame being
/// made), then the source.
pub const FRAMES = 3;
/// The largest frame: one tile column (VP9 needs more past 4096 pels).
pub const MAX_SIZE = 4096;
pub const MAX_SBW = MAX_SIZE / 64;
const NONE: u8 = 0xff;

/// Where everything is in the kernels' memory.
pub const Layout = struct {
    width: u32,
    height: u32,
    /// the 8x8 grid
    mic: u32,
    mir: u32,
    /// 16x16 units, 64x64 superblocks
    uw: u32,
    uh: u32,
    sbw: u32,
    sbh: u32,
    aw: u32,
    ah: u32,
    ys: u32,
    cs: u32,
    plane_y: u32,
    plane_c: u32,
    frame_bytes: u32,
    /// the kernels' scratch (a row of units each)
    scr: u32,
    mem_bytes: usize,
    info_bytes: usize,

    pub fn of(width: u32, height: u32) Layout {
        const uw = (width + 15) / 16;
        const uh = (height + 15) / 16;
        const mic = (width + 7) / 8;
        const mir = (height + 7) / 8;
        const aw = uw * 16;
        const ah = uh * 16;
        const plane_y = aw * ah;
        const plane_c = (aw / 2) * (ah / 2);
        const frame_bytes = std.mem.alignForward(u32, plane_y + 2 * plane_c, 256);
        const scr = frame_bytes * (FRAMES + 1);
        return .{
            .width = width,
            .height = height,
            .mic = mic,
            .mir = mir,
            .uw = uw,
            .uh = uh,
            .sbw = (mic + 7) / 8,
            .sbh = (mir + 7) / 8,
            .aw = aw,
            .ah = ah,
            .ys = aw,
            .cs = aw / 2,
            .plane_y = plane_y,
            .plane_c = plane_c,
            .frame_bytes = frame_bytes,
            .scr = scr,
            .mem_bytes = @as(usize, scr) + @as(usize, uh) * k9.SCR_BYTES,
            .info_bytes = @as(usize, uw) * uh * k9.U_BYTES,
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

/// What the app (or the rate control) asks of a frame.
pub const Picture = struct {
    key: bool,
    /// base_q_idx (1..255: 0 would be lossless)
    q: u8,
    show: bool = true,
    /// (every frame is error resilient: see the top)
    error_resilient: bool = false,
    /// the reference slots this frame refreshes (key frames: all)
    refresh: u8 = 0xff,
    /// the slot inter frames predict from (the app's LAST)
    ref_slot: u3 = 0,
    sharpness: u3 = 0,
    /// null: the encoder's choice for the quantizer
    filter_level: ?u6 = null,
    search_range: u32 = 16,
};

/// What a finished frame came to.
pub const Stats = struct {
    bytes: usize = 0,
    key: bool = false,
    q: u8 = 0,
    filter_level: u6 = 0,
    intra_blocks: u32 = 0,
    inter_blocks: u32 = 0,
    skipped_blocks: u32 = 0,
    header_bytes: usize = 0,
    /// (about) the modes' share of the tile: partitions, modes, vectors
    mode_bytes: usize = 0,
};

pub const Error = error{ TooBig, NoSpace, Engine };

/// The encoder's state across frames.
pub const Encoder = struct {
    lay: Layout,
    width: u32,
    height: u32,
    /// the reconstruction (0 .. FRAMES-1) each of the decoder's eight
    /// reference slots holds
    slots: [8]u8 = @splat(NONE),
    /// the last frame's reconstruction
    recon: u8 = 0,
    frames: u64 = 0,
    last: Stats = .{},

    pub fn init(width: u32, height: u32) Error!Encoder {
        if (width == 0 or height == 0 or width > MAX_SIZE or height > MAX_SIZE) return error.TooBig;
        return .{ .lay = Layout.of(width, height), .width = width, .height = height };
    }

    /// The reconstruction of the last frame (its frame), for a reader.
    pub fn lastSlot(e: *const Encoder) usize {
        return e.recon;
    }
};

/// A new frame store: the next frame is a key frame.
pub fn restart(e: *Encoder) void {
    e.slots = @splat(NONE);
}

// ── Quantizers, costs, the filter level ─────────────────────────────────────

pub fn dcQ(q: u8) i32 {
    return e9.DC_QLOOKUP[q];
}
pub fn acQ(q: u8) i32 {
    return e9.AC_QLOOKUP[q];
}

/// The filter level for `q` (libvpx's LPF_PICK_FROM_Q fit).
pub fn filterLevel(q: u8, key: bool) u6 {
    var l: i32 = (acQ(q) * 20723 + 1015158 + (1 << 17)) >> 18;
    if (key) l -= 4;
    return @intCast(std.math.clamp(l, 0, 63));
}

fn cost16(c: u32) u32 {
    return (c + 8) >> 4;
}

const INTRA_TREE = [_]i8{ 0, 2, -9, 4, -1, 6, 8, 12, -2, 10, -4, -5, -3, 14, -8, 16, -6, -7 };
/// (INTER_OFFSET: NEARESTMV 0, NEARMV 1, ZEROMV 2, NEWMV 3)
const INTER_TREE = [_]i8{ -2, 2, 0, 4, -1, -3 };
const PARTITION_TREE = [_]i8{ 0, 2, -1, 4, -2, -3 };
const MV_JOINT_TREE = [_]i8{ 0, 2, -1, 4, -2, -3 };
const MV_CLASS_TREE = [_]i8{ 0, 2, -1, 4, 6, 8, -2, -3, 10, 12, -4, -5, -6, 14, 16, 18, -7, -8, -9, -10 };
const MV_FP_TREE = [_]i8{ 0, 2, -1, 4, -2, -3 };
const COEF_CON_TREE = [_]i8{ 2, 6, -2, 4, -3, -4, 8, 10, -5, -6, 12, 14, -7, -8, -9, -10 };

const INTRA_CODES = vb.codes(&INTRA_TREE, 10);
const INTER_CODES = vb.codes(&INTER_TREE, 4);
const PARTITION_CODES = vb.codes(&PARTITION_TREE, 4);
const JOINT_CODES = vb.codes(&MV_JOINT_TREE, 4);
const CLASS_CODES = vb.codes(&MV_CLASS_TREE, 11);
const FP_CODES = vb.codes(&MV_FP_TREE, 4);
const CON_CODES = vb.codes(&COEF_CON_TREE, 11);

const NEARESTMV = 10;
const NEARMV = 11;
const ZEROMV = 12;
const NEWMV = 13;
const PART_NONE = 0;
const PART_SPLIT = 3;

const FC = &t9.DEFAULT;

/// The kernels' parameters common to the frame (`cur`, `ref`: the
/// reconstructions made and predicted from).
pub fn frameParams(e: *const Encoder, surf: Surface, pic: Picture, key: bool, level: u6, cur: usize, ref: usize) [dsl.MAX_PARAMS]u32 {
    const l = e.lay;
    var p: [dsl.MAX_PARAMS]u32 = @splat(0);
    p[k8.P_MBW] = l.uw;
    p[k8.P_MBH] = l.uh;
    p[k9.P_YS] = l.ys;
    p[k9.P_CS] = l.cs;
    p[k9.P_SRC_Y] = l.yOff(FRAMES);
    p[k9.P_SRC_U] = l.uOff(FRAMES);
    p[k9.P_SRC_V] = l.vOff(FRAMES);
    p[k9.P_REC_Y] = l.yOff(cur);
    p[k9.P_REC_U] = l.uOff(cur);
    p[k9.P_REC_V] = l.vOff(cur);
    p[k9.P_REF_Y] = l.yOff(ref);
    p[k9.P_REF_U] = l.uOff(ref);
    p[k9.P_REF_V] = l.vOff(ref);
    p[k9.P_KEY] = @intFromBool(key);
    p[k8.P_S_LUMA] = surf.luma;
    p[k8.P_S_CHROMA] = surf.chroma;
    p[k8.P_S_PITCH_L] = surf.pitch_luma;
    p[k8.P_S_PITCH_C] = surf.pitch_chroma;
    p[k8.P_S_SWZ_L] = surf.swz_luma;
    p[k8.P_S_SWZ_C] = surf.swz_chroma;
    p[k8.P_S_GOBS] = surf.gobs;
    p[k9.P_W] = l.width;
    p[k9.P_H] = l.height;
    p[k9.P_AW] = l.aw;
    p[k9.P_AH] = l.ah;
    // the quantizers (no deltas): Y DC, Y AC, UV DC, UV AC
    const f = [4]i32{ dcQ(pic.q), acQ(pic.q), dcQ(pic.q), acQ(pic.q) };
    for (0..4) |i| {
        const q: u32 = @intCast(f[i]);
        p[k9.P9_Q + i] = q;
        p[k9.P9_QI + i] = (65536 + q - 1) / q;
        const dc = i == k9.Q_YDC or i == k9.Q_UVDC;
        p[k9.P9_QR + i] = (q * @as(u32, if (dc) 6 else 5)) >> 4;
        // (a level the coefficient tokens hold, its dequantized value an
        // int16)
        p[k9.P9_QM + i] = @min(16450, 32767 / q);
    }
    // a bit's weight: VP9's coefficients are 8x the pels' scale (VP8's 2x)
    p[k9.P9_LAMBDA] = @intCast(@max(4, @divTrunc(acQ(pic.q) * 26, 16)));
    p[k9.P9_RANGE] = pic.search_range;
    p[k9.P9_UW] = l.uw;
    p[k9.P9_UH] = l.uh;
    p[k9.P9_MIC] = l.mic;
    p[k9.P9_MIR] = l.mir;
    p[k9.P9_SBW] = l.sbw;
    p[k9.P9_SCR] = l.scr;
    // the filter levels (vp9_loop_filter_frame_init, the default deltas:
    // intra +1 (x2 from level 32), LAST 0)
    if (level > 0) {
        const scale: u32 = @as(u32, 1) << @intCast(level >> 5);
        p[k9.P9_LF_INTRA] = @min(63, level + scale);
        p[k9.P9_LF_INTER] = level;
    }
    p[k9.P9_SHARP] = pic.sharpness;
    // inter transforms by the residual (8x8, or the block's where it is flat)
    p[k9.P9_INTER_TX] = 3;
    // the modes' costs (1/16 bits)
    const intra_flag: u32 = if (key) 0 else vb.cost(false, FC.intra_inter[0]);
    const mode9 = [4]usize{ 0, 1, 2, 9 };
    for (0..4) |m| {
        const probs: []const u8 = if (key) &t9.KF_Y_MODE[0][0] else &FC.y_mode[2];
        p[k9.P9_MCOST + m] = cost16(vb.codeCost(&INTRA_TREE, probs, INTRA_CODES[mode9[m]]) + intra_flag);
        const uvp: []const u8 = if (key) &t9.KF_UV_MODE[0] else &FC.uv_mode[0];
        p[k9.P9_UVCOST + m] = cost16(vb.codeCost(&INTRA_TREE, uvp, INTRA_CODES[mode9[m]]));
    }
    // an inter block: its flag, LAST, NEWMV's code and its joint
    p[k9.P9_INTER_COST] = cost16(vb.cost(true, FC.intra_inter[0]) + vb.cost(false, FC.single_ref[4][0]) +
        vb.codeCost(&INTER_TREE, &FC.inter_mode[3], INTER_CODES[3]) + 2 * 256);
    // 4x4 transforms: their size's code over the block's (16x16's)
    const t4 = vb.cost(false, FC.tx16[0][0]);
    const t16 = vb.cost(true, FC.tx16[0][0]) + vb.cost(true, FC.tx16[0][1]);
    p[k9.P9_TX4_COST] = cost16(if (t4 > t16) t4 - t16 else 0) + 32;
    return p;
}

fn ceilLog2(x: u32) u32 {
    var s: u32 = 0;
    while ((@as(u64, 1) << @intCast(s)) < x) s += 1;
    return s;
}

/// The kernels of one frame, dispatched on `eng` (and waited for): load,
/// motion (inter frames), the luma and chroma wavefronts of units, the
/// loop filter's wavefronts of superblocks.
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
        const shift = ceilLog2(l.uw);
        p[k8.P_WSHIFT] = shift;
        p[k8.P_COUNT] = l.uh << @intCast(shift);
        try eng.dispatch(.motion, p[k8.P_COUNT], &p);
    }
    const waves = l.uw + l.uh - 1;
    for (0..waves) |t| {
        const ti: i32 = @intCast(t);
        const ymin: i32 = @max(0, ti - @as(i32, @intCast(l.uw - 1)));
        const ymax: i32 = @min(@as(i32, @intCast(l.uh)) - 1, ti);
        p[k8.P_WAVE] = @intCast(t);
        p[k8.P_COUNT] = @intCast(ymax - ymin + 1);
        // (units of 8x8 blocks: the last row's where the 8x8 grid's rows
        // are odd, the last column's where its columns are)
        const edge = (l.mir & 1 != 0 and t + 1 >= l.uh) or (l.mic & 1 != 0 and t + 1 >= l.uw);
        try eng.dispatch(.luma16, p[k8.P_COUNT], &p);
        if (edge) try eng.dispatch(.luma8, p[k8.P_COUNT], &p);
        try eng.dispatch(.chroma16, p[k8.P_COUNT], &p);
        if (edge) try eng.dispatch(.chroma8, p[k8.P_COUNT], &p);
    }
    if (level > 0) {
        const sbw: i32 = @intCast(l.sbw);
        const sbh: i32 = @intCast(l.sbh);
        var t: i32 = 0;
        while (t < sbw + 2 * (sbh - 1)) : (t += 1) {
            const ymin: i32 = @max(0, (t - sbw + 2) >> 1);
            const ymax: i32 = @min(sbh - 1, t >> 1);
            if (ymax < ymin) continue;
            p[k8.P_WAVE] = @intCast(t);
            p[k8.P_COUNT] = @intCast((ymax - ymin + 1) * 128);
            try eng.dispatch(.lfv, p[k8.P_COUNT], &p);
            try eng.dispatch(.lfh, p[k8.P_COUNT], &p);
        }
    }
    try eng.finish();
}

// ── The bitstream ───────────────────────────────────────────────────────────

/// The uncompressed header's bits (MSB first).
const Bits = struct {
    buf: []u8,
    n: usize = 0,

    fn put(b: *Bits, comptime width: u5, v: u32) void {
        var k: u5 = width;
        while (k > 0) {
            k -= 1;
            const byte = b.n >> 3;
            const sh: u3 = @intCast(7 - (b.n & 7));
            if (b.n & 7 == 0) b.buf[byte] = 0;
            if ((v >> k) & 1 != 0) b.buf[byte] |= @as(u8, 1) << sh;
            b.n += 1;
        }
    }
    fn bytes(b: *const Bits) usize {
        return (b.n + 7) >> 3;
    }
};

/// The scan and its neighbours of a transform size and type.
const Scan = struct { scan: []const u16, nb: []const u16 };

fn scanOf(tx: u2, ttype: u2) Scan {
    return switch (tx) {
        0 => switch (ttype) {
            1 => .{ .scan = &e9.ROW_SCAN_4X4, .nb = &e9.ROW_NB_4X4 },
            2 => .{ .scan = &e9.COL_SCAN_4X4, .nb = &e9.COL_NB_4X4 },
            else => .{ .scan = &e9.DEFAULT_SCAN_4X4, .nb = &e9.DEFAULT_NB_4X4 },
        },
        1 => switch (ttype) {
            1 => .{ .scan = &e9.ROW_SCAN_8X8, .nb = &e9.ROW_NB_8X8 },
            2 => .{ .scan = &e9.COL_SCAN_8X8, .nb = &e9.COL_NB_8X8 },
            else => .{ .scan = &e9.DEFAULT_SCAN_8X8, .nb = &e9.DEFAULT_NB_8X8 },
        },
        else => switch (ttype) {
            1 => .{ .scan = &e9.ROW_SCAN_16X16, .nb = &e9.ROW_NB_16X16 },
            2 => .{ .scan = &e9.COL_SCAN_16X16, .nb = &e9.COL_NB_16X16 },
            else => .{ .scan = &e9.DEFAULT_SCAN_16X16, .nb = &e9.DEFAULT_NB_16X16 },
        },
    };
}

fn band(tx: u2, c: usize) usize {
    if (tx == 0) return e9.BAND_4X4[c];
    return if (c < e9.BAND_8X8_HEAD.len) e9.BAND_8X8_HEAD[c] else 5;
}

const ENERGY = [11]u8{ 0, 1, 2, 3, 3, 4, 4, 5, 5, 5, 5 };
const CAT_BASE = [6]u32{ 5, 7, 11, 19, 35, 67 };

fn tokenOf(a: u32) usize {
    if (a <= 4) return a;
    if (a <= 6) return 5;
    if (a <= 10) return 6;
    if (a <= 18) return 7;
    if (a <= 34) return 8;
    if (a <= 66) return 9;
    return 10;
}

/// A transform block's levels: a unit plane's (`base` in the record,
/// `stride` its width), at (x, y) of it.
const TxBlock = struct {
    unit: []const u8,
    base: usize,
    stride: usize,
    x: usize,
    y: usize,
    tx: u2,
    ttype: u2,
};

/// Where a transform block's token decisions go: written (with `probs`),
/// counted (the probability updates' counts), or both.
const Tok = struct {
    w: ?*vb.Writer,
    counts: ?*[6][6][3][2]u32,
    probs: *const [6][6][3]u8,

    fn node(s: Tok, bnd: usize, ctx: usize, n: usize, b: bool) void {
        if (s.w) |w| w.write(b, s.probs[bnd][ctx][n]);
        if (s.counts) |c| c[bnd][ctx][n][@intFromBool(b)] += 1;
    }
    fn fixed(s: Tok, b: bool, p: u8) void {
        if (s.w) |w| w.write(b, p);
    }
};

/// One transform block's tokens (libvpx's decode_coefs in reverse);
/// whether it had a nonzero level.
fn writeTokens(s: Tok, t: TxBlock, ctx0: usize) bool {
    const probs = s.probs;
    const side: usize = @as(usize, 4) << t.tx;
    const n = side * side;
    const sc = scanOf(t.tx, t.ttype);
    var v: [256]i32 = undefined;
    var eob: usize = 0;
    for (0..n) |c| {
        const pos: usize = sc.scan[c];
        const at = t.base + ((t.y + pos / side) * t.stride + t.x + pos % side) * 2;
        v[c] = std.mem.readInt(i16, t.unit[at..][0..2], .little);
        if (v[c] != 0) eob = c + 1;
    }
    var ctx = ctx0;
    if (eob == 0) {
        s.node(band(t.tx, 0), ctx, 0, false);
        return false;
    }
    var cache: [256]u8 = undefined;
    var c: usize = 0;
    while (true) {
        var bnd = band(t.tx, c);
        s.node(bnd, ctx, 0, true);
        while (v[c] == 0) {
            s.node(bnd, ctx, 1, false);
            cache[sc.scan[c]] = 0;
            c += 1;
            ctx = (1 + @as(usize, cache[sc.nb[2 * c]]) + cache[sc.nb[2 * c + 1]]) >> 1;
            bnd = band(t.tx, c);
        }
        s.node(bnd, ctx, 1, true);
        const a: u32 = @abs(v[c]);
        var tok: usize = 1;
        if (a == 1) {
            s.node(bnd, ctx, 2, false);
        } else {
            s.node(bnd, ctx, 2, true);
            tok = tokenOf(a);
            if (s.w) |w| {
                vb.writeCode(w, &COEF_CON_TREE, &e9.PARETO8_FULL[probs[bnd][ctx][2] - 1], CON_CODES[tok]);
                if (tok >= 5) {
                    const tab: []const u8 = switch (tok) {
                        5 => &e9.CAT1,
                        6 => &e9.CAT2,
                        7 => &e9.CAT3,
                        8 => &e9.CAT4,
                        9 => &e9.CAT5,
                        else => &e9.CAT6,
                    };
                    const extra = a - CAT_BASE[tok - 5];
                    for (tab, 0..) |pr, i| w.write((extra >> @intCast(tab.len - 1 - i)) & 1 != 0, pr);
                }
            }
        }
        s.fixed(v[c] < 0, 128);
        cache[sc.scan[c]] = ENERGY[tok];
        c += 1;
        if (c == n) break;
        ctx = (1 + @as(usize, cache[sc.nb[2 * c]]) + cache[sc.nb[2 * c + 1]]) >> 1;
        if (c == eob) {
            s.node(band(t.tx, c), ctx, 0, false);
            break;
        }
    }
    return true;
}

// ── The coefficient probabilities' updates (forward only: every frame
// starts from the defaults) ─────────────────────────────────────────────────

/// A frame's coefficient probabilities, [tx size][plane type][reference]
/// [band][context][node].
pub const Coef = [4][2][2][6][6][3]u8;
/// Their decisions' counts (4x4 to 16x16).
const Counts = [3][2][2][6][6][3][2]u32;
/// Which of them a frame updates.
const Updates = [3][2][2][6][6][3]bool;

const DIFF_UPDATE = 252;

const UPDATE_BITS = [255]u8{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 0 };
const MAP_TABLE = [254]u8{ 20, 21, 22, 23, 24, 25, 0, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 1, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 2, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 3, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 4, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 5, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 6, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 7, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 8, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 9, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 10, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 11, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 12, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 13, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 14, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 15, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 16, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 17, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 18, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 19 };

fn recenterNonneg(v: i32, m: i32) i32 {
    if (v > (m << 1)) return v;
    if (v >= m) return (v - m) << 1;
    return ((m - v) << 1) - 1;
}

/// libvpx's remap_prob: what the decoder's inv_remap_prob maps back to
/// `newp` from `oldp`.
fn remapProb(newp: u8, oldp: u8) usize {
    const v: i32 = @as(i32, newp) - 1;
    const m: i32 = @as(i32, oldp) - 1;
    const i = if ((m << 1) <= 255) recenterNonneg(v, m) - 1 else recenterNonneg(254 - v, 254 - m) - 1;
    return MAP_TABLE[@intCast(i)];
}

/// A probability's update (vp9_write_prob_diff_update: the remapped
/// difference, sub-exponentially).
fn writeProbDiff(w: *vb.Writer, newp: u8, oldp: u8) void {
    const d: u32 = @intCast(remapProb(newp, oldp));
    if (d < 16) {
        w.bit(false);
        w.literal(4, d);
    } else if (d < 32) {
        w.bit(true);
        w.bit(false);
        w.literal(4, d - 16);
    } else if (d < 64) {
        w.bit(true);
        w.bit(true);
        w.bit(false);
        w.literal(5, d - 32);
    } else {
        w.bit(true);
        w.bit(true);
        w.bit(true);
        const u = d - 64;
        const m = 65;
        if (u < m) {
            w.literal(7, u);
        } else {
            w.literal(7, m + ((u - m) >> 1));
            w.literal(1, (u - m) & 1);
        }
    }
}

/// The best update of a probability for its counts (libvpx's
/// vp9_prob_diff_update_savings_search): the new probability and what it
/// saves (1/256 bits; 0: none).
fn updateSavings(ct: [2]u32, oldp: u8) struct { p: u8, s: i64 } {
    const old_b: i64 = @intCast(vb.branchCost(ct[0], ct[1], oldp));
    const upd_cost: i64 = @as(i64, vb.cost(true, DIFF_UPDATE)) - vb.cost(false, DIFF_UPDATE);
    var best: i64 = 0;
    var bestp = oldp;
    if (old_b > upd_cost + 5 * 256) {
        const start = vb.bestProb(ct[0], ct[1]);
        var newp: i32 = start;
        const step: i32 = if (start > oldp) -1 else 1;
        while (newp != oldp) : (newp += step) {
            const np: u8 = @intCast(newp);
            const new_b: i64 = @intCast(vb.branchCost(ct[0], ct[1], np));
            const s = old_b - new_b - (@as(i64, UPDATE_BITS[remapProb(np, oldp)]) * 256 + upd_cost);
            if (s > best) {
                best = s;
                bestp = np;
            }
        }
    }
    return .{ .p = bestp, .s = best };
}

/// The updates of transform size `tx` (libvpx's two-loop search): whether
/// any are sent (then `probs` and `upd` say which).
fn decideUpdates(tx: usize, counts: *const Counts, probs: *Coef, upd: *Updates) bool {
    var savings: i64 = 0;
    var n: usize = 0;
    const c0: i64 = vb.cost(false, DIFF_UPDATE);
    for (0..2) |i| for (0..2) |j| for (0..6) |k| for (0..(if (k == 0) @as(usize, 3) else 6)) |l| for (0..3) |m| {
        const oldp = probs[tx][i][j][k][l][m];
        const r = updateSavings(counts[tx][i][j][k][l][m], oldp);
        if (r.s > 0 and r.p != oldp) {
            upd[tx][i][j][k][l][m] = true;
            probs[tx][i][j][k][l][m] = r.p;
            savings += r.s - c0;
            n += 1;
        } else {
            upd[tx][i][j][k][l][m] = false;
            savings -= c0;
        }
    };
    if (n == 0 or savings < 0) {
        // (not sent: the defaults stay)
        probs[tx] = FC.coef[tx];
        return false;
    }
    return true;
}

/// A cell's record (16 bytes: vp9_kernels' C_*).
const Cell = struct {
    b: []const u8,
    fn inter(c: Cell) bool {
        return c.b[k9.C_INTER] != 0;
    }
    fn skip(c: Cell) bool {
        return c.b[k9.C_SKIP] != 0;
    }
    fn tx(c: Cell) u2 {
        return @intCast(c.b[k9.C_TX]);
    }
    fn ymode(c: Cell) u8 {
        return c.b[k9.C_YMODE];
    }
    fn mv(c: Cell) [2]i32 {
        return .{ std.mem.readInt(i16, c.b[k9.C_MVR..][0..2], .little), std.mem.readInt(i16, c.b[k9.C_MVC..][0..2], .little) };
    }
};

/// The tx type of an intra mode (DC, V, H, TM; the others' never used).
fn txType(ymode: u8) u2 {
    return switch (ymode) {
        1 => 1,
        2 => 2,
        9 => 3,
        else => 0,
    };
}

const MV_REF_16 = [8][2]i32{ .{ -1, 0 }, .{ 0, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 }, .{ -3, 0 }, .{ 0, -3 }, .{ -3, -3 } };
const MV_REF_8 = [8][2]i32{ .{ -1, 0 }, .{ 0, -1 }, .{ -1, -1 }, .{ -2, 0 }, .{ 0, -2 }, .{ -2, -1 }, .{ -1, -2 }, .{ -2, -2 } };
const COUNTER_TO_CONTEXT = [19]u8{ 2, 3, 4, 1, 3, 9, 0, 9, 9, 5, 5, 9, 5, 9, 9, 9, 9, 9, 6 };

fn mode2counter(m: u8) u32 {
    return switch (m) {
        NEARESTMV, NEARMV => 0,
        ZEROMV => 3,
        NEWMV => 1,
        else => 9,
    };
}

fn writeMvComponent(w: *vb.Writer, v: i32, c: *const t9.MvComponent) void {
    const mag: u32 = @abs(v);
    const z = mag - 1;
    const cls: usize = if (z >= 2 * 4096) 10 else std.math.log2_int(u32, @max(1, z >> 3));
    const base: u32 = if (cls == 0) 0 else @as(u32, 2) << @intCast(cls + 2);
    const off = z - base;
    const d = off >> 3;
    const fr = (off >> 1) & 3;
    w.write(v < 0, c.sign);
    vb.writeCode(w, &MV_CLASS_TREE, &c.classes, CLASS_CODES[cls]);
    if (cls == 0) {
        w.write(d != 0, c.class0[0]);
    } else {
        for (0..cls) |i| w.write((d >> @intCast(i)) & 1 != 0, c.bits[i]);
    }
    vb.writeCode(w, &MV_FP_TREE, if (cls == 0) &c.class0_fp[d] else &c.fp, FP_CODES[fr]);
}

fn mvCost(diff: [2]i32) u32 {
    var bits: u32 = 0;
    for (diff) |d| {
        const a: u32 = @abs(d);
        bits += if (a == 0) 0 else 2 * (std.math.log2_int(u32, a) + 2);
    }
    return bits * 256;
}

const Pack = struct {
    w: *vb.Writer,
    l: *const Layout,
    rec: []const u8,
    /// each cell's coded mode (intra: its mode, inter: NEARESTMV ..)
    modes: []u8,
    key: bool,
    /// the frame's coefficient probabilities; the tokens counted (the
    /// first pass, no tokens written) or written
    coef: *const Coef,
    counts: ?*Counts = null,
    above_y: [MAX_SBW * 16]u8 = @splat(0),
    above_u: [MAX_SBW * 8]u8 = @splat(0),
    above_v: [MAX_SBW * 8]u8 = @splat(0),
    above_p: [MAX_SBW * 8]u8 = @splat(0),
    left_y: [16]u8 = @splat(0),
    left_u: [8]u8 = @splat(0),
    left_v: [8]u8 = @splat(0),
    left_p: [8]u8 = @splat(0),
    intra: u32 = 0,
    inter: u32 = 0,
    skipped: u32 = 0,

    fn unit(p: *const Pack, r: u32, c: u32) []const u8 {
        const u = (r >> 1) * p.l.uw + (c >> 1);
        return p.rec[@as(usize, u) * k9.U_BYTES ..][0..k9.U_BYTES];
    }
    fn cell(p: *const Pack, r: u32, c: u32) Cell {
        const k = ((r & 1) << 1) | (c & 1);
        return .{ .b = p.unit(r, c)[k * 16 ..][0..16] };
    }

    fn partition(p: *Pack, r: u32, c: u32, bsl: u2) void {
        const l = p.l;
        if (r >= l.mir or c >= l.mic) return;
        const hbs: u32 = (@as(u32, 1) << bsl) >> 1;
        const part: usize = switch (bsl) {
            0 => PART_NONE,
            1 => if (r + 1 < l.mir and c + 1 < l.mic) PART_NONE else PART_SPLIT,
            else => PART_SPLIT,
        };
        const above = (p.above_p[c] >> bsl) & 1;
        const left = (p.left_p[r & 7] >> bsl) & 1;
        const ctx = @as(usize, left) * 2 + above + @as(usize, bsl) * 4;
        const probs: *const [3]u8 = if (p.key) &t9.KF_PARTITION[ctx] else &FC.partition[ctx];
        const has_rows = r + hbs < l.mir;
        const has_cols = c + hbs < l.mic;
        if (has_rows and has_cols) {
            vb.writeCode(p.w, &PARTITION_TREE, probs, PARTITION_CODES[part]);
        } else if (!has_rows and has_cols) {
            p.w.write(part == PART_SPLIT, probs[1]);
        } else if (has_rows and !has_cols) {
            p.w.write(part == PART_SPLIT, probs[2]);
        }
        if (bsl == 0) {
            p.block(r, c, false);
        } else if (part == PART_NONE) {
            p.block(r, c, true);
        } else {
            const sub: u2 = bsl - 1;
            p.partition(r, c, sub);
            p.partition(r, c + hbs, sub);
            p.partition(r + hbs, c, sub);
            p.partition(r + hbs, c + hbs, sub);
        }
        if (bsl == 0 or part != PART_SPLIT) {
            const v: u8 = if (bsl == 0) 14 else 12;
            const bs: u32 = @as(u32, 1) << bsl;
            @memset(p.above_p[c..][0..bs], v);
            @memset(p.left_p[(r & 7)..][0..bs], v);
        }
    }

    /// The tile: the superblocks in raster order.
    fn frame(p: *Pack) void {
        var sr: u32 = 0;
        while (sr < p.l.sbh) : (sr += 1) {
            @memset(&p.left_y, 0);
            @memset(&p.left_u, 0);
            @memset(&p.left_v, 0);
            @memset(&p.left_p, 0);
            var sc: u32 = 0;
            while (sc < p.l.sbw) : (sc += 1) p.partition(sr * 8, sc * 8, 3);
        }
    }

    fn inside(p: *const Pack, r: i32, c: i32) bool {
        return r >= 0 and c >= 0 and r < p.l.mir and c < p.l.mic;
    }

    fn writeTx(p: *Pack, above: ?Cell, left: ?Cell, max_tx: u2, tx: u2) void {
        var actx: u32 = if (above) |a| (if (!a.skip()) a.tx() else max_tx) else max_tx;
        var lctx: u32 = if (left) |a| (if (!a.skip()) a.tx() else max_tx) else max_tx;
        if (left == null) lctx = actx;
        if (above == null) actx = lctx;
        const ctx: usize = @intFromBool(actx + lctx > max_tx);
        if (max_tx == 1) {
            p.w.write(tx != 0, FC.tx8[ctx][0]);
        } else {
            p.w.write(tx != 0, FC.tx16[ctx][0]);
            if (tx != 0) p.w.write(tx != 1, FC.tx16[ctx][1]);
        }
    }

    /// An inter block's mode (and vector): the cheapest the decoder reads
    /// as its vector.
    fn writeInter(p: *Pack, r: u32, c: u32, big: bool, mv: [2]i32) u8 {
        const refs = if (big) &MV_REF_16 else &MV_REF_8;
        const ri: i32 = @intCast(r);
        const ci: i32 = @intCast(c);
        var counter: u32 = 0;
        for (refs[0..2]) |o| {
            if (p.inside(ri + o[0], ci + o[1])) counter += mode2counter(p.modes[@as(usize, @intCast(ri + o[0])) * p.l.mic + @as(usize, @intCast(ci + o[1]))]);
        }
        const mctx = COUNTER_TO_CONTEXT[counter];
        // the candidates (dec_find_mv_refs: LAST's vectors only)
        var list: [2][2]i32 = @splat(.{ 0, 0 });
        var n: usize = 0;
        for (refs) |o| {
            if (!p.inside(ri + o[0], ci + o[1])) continue;
            const x = p.cell(@intCast(ri + o[0]), @intCast(ci + o[1]));
            if (!x.inter()) continue;
            const m = x.mv();
            if (n == 0) {
                list[0] = m;
                n = 1;
            } else if (m[0] != list[0][0] or m[1] != list[0][1]) {
                list[1] = m;
                n = 2;
                break;
            }
        }
        // clamped (clamp_mv_ref) and to whole quarter pels
        const bw: i32 = if (big) 2 else 1;
        const to_left = -ci * 64;
        const to_right = (@as(i32, @intCast(p.l.mic)) - bw - ci) * 64;
        const to_top = -ri * 64;
        const to_bottom = (@as(i32, @intCast(p.l.mir)) - bw - ri) * 64;
        for (&list) |*m| {
            m[0] = std.math.clamp(m[0], to_top - 128, to_bottom + 128);
            m[1] = std.math.clamp(m[1], to_left - 128, to_right + 128);
            for (m) |*x| {
                if (x.* & 1 != 0) x.* += if (x.* > 0) -1 else 1;
            }
        }
        const probs = &FC.inter_mode[mctx];
        var best: u8 = NEWMV;
        var best_cost: u32 = vb.codeCost(&INTER_TREE, probs, INTER_CODES[3]) + vb.codeCost(&MV_JOINT_TREE, &FC.mv_joints, JOINT_CODES[3]) + mvCost(.{ mv[0] - list[0][0], mv[1] - list[0][1] });
        const zero = mv[0] == 0 and mv[1] == 0;
        const cands = [3]struct { ok: bool, mode: u8, code: usize }{
            .{ .ok = mv[0] == list[0][0] and mv[1] == list[0][1], .mode = NEARESTMV, .code = 0 },
            .{ .ok = mv[0] == list[1][0] and mv[1] == list[1][1], .mode = NEARMV, .code = 1 },
            .{ .ok = zero, .mode = ZEROMV, .code = 2 },
        };
        for (cands) |k| {
            if (!k.ok) continue;
            const cst = vb.codeCost(&INTER_TREE, probs, INTER_CODES[k.code]);
            if (cst < best_cost) {
                best = k.mode;
                best_cost = cst;
            }
        }
        vb.writeCode(p.w, &INTER_TREE, probs, INTER_CODES[best - NEARESTMV]);
        if (best == NEWMV) {
            const d = [2]i32{ mv[0] - list[0][0], mv[1] - list[0][1] };
            const joint: usize = (@as(usize, @intFromBool(d[0] != 0)) << 1) | @intFromBool(d[1] != 0);
            vb.writeCode(p.w, &MV_JOINT_TREE, &FC.mv_joints, JOINT_CODES[joint]);
            if (d[0] != 0) writeMvComponent(p.w, d[0], &FC.mv[0]);
            if (d[1] != 0) writeMvComponent(p.w, d[1], &FC.mv[1]);
        }
        return best;
    }

    fn block(p: *Pack, r: u32, c: u32, big: bool) void {
        const w = p.w;
        const cl = p.cell(r, c);
        const above: ?Cell = if (r > 0) p.cell(r - 1, c) else null;
        const left: ?Cell = if (c > 0) p.cell(r, c - 1) else null;
        const inter = cl.inter();
        const skip = cl.skip();
        const tx = cl.tx();
        const ymode = cl.ymode();
        const uvmode = cl.b[k9.C_UVMODE];
        const max_tx: u2 = if (big) 2 else 1;
        const sctx = @as(usize, @intFromBool(if (above) |a| a.skip() else false)) + @intFromBool(if (left) |a| a.skip() else false);
        w.write(skip, FC.skip[sctx]);
        var mode: u8 = ymode;
        if (p.key) {
            p.writeTx(above, left, max_tx, tx);
            const am: usize = if (above) |a| (if (a.inter()) 0 else a.ymode()) else 0;
            const lm: usize = if (left) |a| (if (a.inter()) 0 else a.ymode()) else 0;
            vb.writeCode(w, &INTRA_TREE, &t9.KF_Y_MODE[am][lm], INTRA_CODES[ymode]);
            vb.writeCode(w, &INTRA_TREE, &t9.KF_UV_MODE[ymode], INTRA_CODES[uvmode]);
        } else {
            const a_in = above != null and !above.?.inter();
            const l_in = left != null and !left.?.inter();
            var iictx: usize = 0;
            if (above != null and left != null) {
                iictx = if (a_in and l_in) 3 else @intFromBool(a_in or l_in);
            } else if (above != null or left != null) {
                iictx = 2 * @as(usize, @intFromBool(a_in or l_in));
            }
            w.write(inter, FC.intra_inter[iictx]);
            if (!(inter and skip)) p.writeTx(above, left, max_tx, tx);
            if (!inter) {
                vb.writeCode(w, &INTRA_TREE, &FC.y_mode[if (big) 2 else 1], INTRA_CODES[ymode]);
                vb.writeCode(w, &INTRA_TREE, &FC.uv_mode[ymode], INTRA_CODES[uvmode]);
            } else {
                const any_inter = (above != null and above.?.inter()) or (left != null and left.?.inter());
                w.write(false, FC.single_ref[if (any_inter) 4 else 2][0]);
                mode = p.writeInter(r, c, big, cl.mv());
            }
        }
        if (inter) p.inter += 1 else p.intra += 1;
        const cells: u32 = if (big) 2 else 1;
        for (0..cells) |dr| for (0..cells) |dc| {
            p.modes[(r + dr) * p.l.mic + c + dc] = mode;
        };

        // the tokens (or the contexts' reset)
        const n4: u32 = if (big) 4 else 2;
        const n4c: u32 = n4 / 2;
        const ay = p.above_y[c * 2 ..][0..n4];
        const ly = p.left_y[(r & 7) * 2 ..][0..n4];
        if (skip) {
            p.skipped += 1;
            @memset(ay, 0);
            @memset(ly, 0);
            @memset(p.above_u[c..][0..n4c], 0);
            @memset(p.above_v[c..][0..n4c], 0);
            @memset(p.left_u[(r & 7)..][0..n4c], 0);
            @memset(p.left_v[(r & 7)..][0..n4c], 0);
            return;
        }
        const u = p.unit(r, c);
        const ref: usize = @intFromBool(inter);
        const tw: ?*vb.Writer = if (p.counts == null) w else null;
        // luma
        {
            const step: u32 = @as(u32, 1) << tx;
            const tok = Tok{ .w = tw, .counts = if (p.counts) |k| &k[tx][0][ref] else null, .probs = &p.coef[tx][0][ref] };
            const ttype: u2 = if (inter) 0 else txType(ymode);
            var row: u32 = 0;
            while (row < n4) : (row += step) {
                var col: u32 = 0;
                while (col < n4) : (col += step) {
                    var ctx: usize = 0;
                    for (ay[col..][0..step]) |x| if (x != 0) {
                        ctx += 1;
                        break;
                    };
                    for (ly[row..][0..step]) |x| if (x != 0) {
                        ctx += 1;
                        break;
                    };
                    const nz = writeTokens(tok, .{ .unit = u, .base = k9.U_Y, .stride = 16, .x = (c & 1) * 8 + col * 4, .y = (r & 1) * 8 + row * 4, .tx = tx, .ttype = ttype }, ctx);
                    @memset(ay[col..][0..step], @intFromBool(nz));
                    @memset(ly[row..][0..step], @intFromBool(nz));
                }
            }
        }
        // chroma: 8x8 for a 16x16 block of 8x8 or 16x16 transforms, else 4x4
        const uvtx: u2 = if (big and tx >= 1) 1 else 0;
        const step: u32 = @as(u32, 1) << uvtx;
        const tok = Tok{ .w = tw, .counts = if (p.counts) |k| &k[uvtx][1][ref] else null, .probs = &p.coef[uvtx][1][ref] };
        inline for (0..2) |pl| {
            const ac = if (pl == 0) p.above_u[c..][0..n4c] else p.above_v[c..][0..n4c];
            const lc = if (pl == 0) p.left_u[(r & 7)..][0..n4c] else p.left_v[(r & 7)..][0..n4c];
            var row: u32 = 0;
            while (row < n4c) : (row += step) {
                var col: u32 = 0;
                while (col < n4c) : (col += step) {
                    var ctx: usize = 0;
                    for (ac[col..][0..step]) |x| if (x != 0) {
                        ctx += 1;
                        break;
                    };
                    for (lc[row..][0..step]) |x| if (x != 0) {
                        ctx += 1;
                        break;
                    };
                    const nz = writeTokens(tok, .{ .unit = u, .base = if (pl == 0) k9.U_U else k9.U_V, .stride = 8, .x = (c & 1) * 4 + col * 4, .y = (r & 1) * 4 + row * 4, .tx = uvtx, .ttype = 0 }, ctx);
                    @memset(ac[col..][0..step], @intFromBool(nz));
                    @memset(lc[row..][0..step], @intFromBool(nz));
                }
            }
        }
    }
};

/// The compressed header: TX_MODE_SELECT, the coefficients' updates, no
/// other probabilities'.
fn compressedHeader(w: *vb.Writer, key: bool, probs: *const Coef, upd: *const Updates, sent: [3]bool) void {
    w.bit(false); // the marker
    w.literal(2, 3);
    w.bit(true); // TX_MODE_SELECT
    for (0..2 * 1 + 2 * 2 + 2 * 3) |_| w.write(false, DIFF_UPDATE); // tx probabilities
    // the coefficients, each size (32x32: never used)
    for (0..4) |tx| {
        if (tx == 3 or !sent[tx]) {
            w.bit(false);
            continue;
        }
        w.bit(true);
        for (0..2) |i| for (0..2) |j| for (0..6) |k| for (0..(if (k == 0) @as(usize, 3) else 6)) |l| for (0..3) |m| {
            const u = upd[tx][i][j][k][l][m];
            w.write(u, DIFF_UPDATE);
            if (u) writeProbDiff(w, probs[tx][i][j][k][l][m], FC.coef[tx][i][j][k][l][m]);
        };
    }
    for (0..3) |_| w.write(false, DIFF_UPDATE); // skip
    if (key) return;
    // inter modes, intra/inter, (single reference: no mode bits), single
    // reference, y modes, partitions, then the vectors' (MV_UPDATE_PROB)
    for (0..7 * 3 + 4 + 5 * 2 + 4 * 9 + 16 * 3) |_| w.write(false, DIFF_UPDATE);
    for (0..3 + 2 * (1 + 10 + 1 + 10) + 2 * (2 * 3 + 3)) |_| w.write(false, 252);
}

/// The frame's bytes: the uncompressed header, the compressed header, the
/// tile. `scratch`: the cells' modes and the two coders' bytes.
pub fn pack(e: *Encoder, records: []const u8, pic: Picture, key: bool, level: u6, out: []u8, scratch: []u8) Error!Stats {
    const l = e.lay;
    var st = Stats{ .key = key, .q = pic.q, .filter_level = level };
    const cells: usize = @as(usize, l.mic) * l.mir;
    const hdr_at = std.mem.alignForward(usize, cells, 64);
    const HDR = 16 << 10;
    if (scratch.len < hdr_at + HDR + 4096) return error.NoSpace;
    const modes = scratch[0..cells];
    const hdr = scratch[hdr_at..][0..HDR];
    const tile = scratch[hdr_at + HDR ..];

    // the tokens counted (a pass of the modes, no tokens), the
    // probabilities that pay updated, the tile written with them
    var counts: Counts = std.mem.zeroes(Counts);
    var probs: Coef = FC.coef;
    var upd: Updates = undefined;
    var sent = [3]bool{ false, false, false };
    {
        var cw = vb.Writer.init(tile);
        var pk = Pack{ .w = &cw, .l = &l, .rec = records, .modes = modes, .key = key, .coef = &probs, .counts = &counts };
        pk.frame();
        st.mode_bytes = cw.pos;
    }
    for (0..3) |tx| sent[tx] = decideUpdates(tx, &counts, &probs, &upd);

    var hw = vb.Writer.init(hdr);
    compressedHeader(&hw, key, &probs, &upd, sent);
    const hdr_len = hw.finishVp9();
    if (hw.overflow) return error.NoSpace;

    var tw = vb.Writer.init(tile);
    tw.bit(false); // the marker
    var pk = Pack{ .w = &tw, .l = &l, .rec = records, .modes = modes, .key = key, .coef = &probs };
    pk.frame();
    const tile_len = tw.finishVp9();
    if (tw.overflow) return error.NoSpace;

    // the uncompressed header
    if (out.len < 64) return error.NoSpace;
    var b = Bits{ .buf = out };
    b.put(2, 2); // frame marker
    b.put(2, 0); // profile 0
    b.put(1, 0); // show_existing_frame
    b.put(1, @intFromBool(!key));
    b.put(1, @intFromBool(pic.show));
    b.put(1, 1); // error_resilient_mode
    if (key) {
        b.put(8, 0x49);
        b.put(8, 0x83);
        b.put(8, 0x42);
        b.put(3, 1); // BT.601
        b.put(1, 0); // studio range
        b.put(16, l.width - 1);
        b.put(16, l.height - 1);
        b.put(1, 0); // render size: the frame's
    } else {
        if (!pic.show) b.put(1, 0); // intra_only
        b.put(8, pic.refresh);
        for (0..3) |_| {
            b.put(3, pic.ref_slot); // LAST, GOLDEN, ALTREF: the one reference
            b.put(1, 0); // sign bias
        }
        b.put(1, 1); // the size: LAST's
        b.put(1, 0); // render size: the frame's
        b.put(1, 0); // allow_high_precision_mv
        b.put(1, 0); // not switchable
        b.put(2, 1); // EIGHTTAP (regular)
    }
    b.put(2, 0); // frame_context_idx
    b.put(6, level);
    b.put(3, pic.sharpness);
    b.put(1, 1); // mode_ref_delta_enabled
    b.put(1, 0); // (the defaults)
    b.put(8, pic.q);
    b.put(3, 0); // no quantizer deltas
    b.put(1, 0); // no segmentation
    // one tile column (the fewest: one up to 4096 pels), one row
    const sb64 = l.sbw;
    var max_log2: u32 = 1;
    while ((sb64 >> @intCast(max_log2)) >= 4) max_log2 += 1;
    if (max_log2 - 1 > 0) b.put(1, 0);
    b.put(1, 0);
    b.put(16, @intCast(hdr_len));
    const head = b.bytes();
    if (head + hdr_len + tile_len > out.len) return error.NoSpace;
    @memcpy(out[head..][0..hdr_len], hdr[0..hdr_len]);
    @memcpy(out[head + hdr_len ..][0..tile_len], tile[0..tile_len]);

    st.bytes = head + hdr_len + tile_len;
    st.header_bytes = head + hdr_len;
    st.intra_blocks = pk.intra;
    st.inter_blocks = pk.inter;
    st.skipped_blocks = pk.skipped;
    return st;
}

/// One frame: the kernels on `eng`, then the bitstream into `out`. A key
/// frame where the app asks, where the store has no reference for the
/// app's slot, or where no reconstruction is free for the new frame.
pub fn encodeFrame(e: *Encoder, eng: anytype, surf: Surface, pic0: Picture, out: []u8, scratch: []u8) !Stats {
    var pic = pic0;
    pic.q = @max(pic.q, 1);
    var key = pic.key or e.slots[pic.ref_slot] == NONE;
    const ref: usize = if (key) 0 else e.slots[pic.ref_slot];
    // a reconstruction no slot holds (key frames: any)
    var cur: usize = 0;
    var free = false;
    for (0..FRAMES) |f| {
        if (std.mem.indexOfScalar(u8, &e.slots, @intCast(f)) == null) {
            cur = f;
            free = true;
            break;
        }
    }
    if (!free) {
        key = true;
        cur = 0;
    }
    pic.key = key;
    if (key) pic.refresh = 0xff;
    const level: u6 = pic.filter_level orelse filterLevel(pic.q, key);
    const p = frameParams(e, surf, pic, key, level, cur, ref);
    try dispatchFrame(e, eng, p, key, level);
    const st = try pack(e, eng.records(), pic, key, level, out, scratch);
    for (0..8) |i| {
        if ((pic.refresh >> @intCast(i)) & 1 != 0) e.slots[i] = @intCast(cur);
    }
    e.recon = @intCast(cur);
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
            .motion => dsl.runCpu(k9.motion, bufs, params, threads),
            .luma16 => dsl.runCpu(k9.luma16, bufs, params, threads),
            .luma8 => dsl.runCpu(k9.luma8, bufs, params, threads),
            .chroma16 => dsl.runCpu(k9.chroma16, bufs, params, threads),
            .chroma8 => dsl.runCpu(k9.chroma8, bufs, params, threads),
            .lfv => dsl.runCpu(k9.lfv, bufs, params, threads),
            .lfh => dsl.runCpu(k9.lfh, bufs, params, threads),
        }
    }
    pub fn finish(_: *CpuEngine) Error!void {}
    pub fn records(e: *CpuEngine) []const u8 {
        return e.info;
    }
};

/// The CPU engine's memory (frames and records) for `e`.
pub fn cpuBytes(e: *const Encoder) usize {
    return e.lay.mem_bytes + e.lay.info_bytes;
}

/// One frame on the CPU engine (`mem`: cpuBytes of it, `surf_mem`: the
/// input picture's buffer); the stream's bytes.
pub fn encodeCpu(e: *Encoder, mem: []u8, surf_mem: []u8, surf: Surface, pic: Picture, out: []u8, scratch: []u8) Error!usize {
    const l = e.lay;
    var eng = CpuEngine{ .mem = mem[0..l.mem_bytes], .info = mem[l.mem_bytes..][0..l.info_bytes], .surf = surf_mem };
    const st = try encodeFrame(e, &eng, surf, pic, out, scratch);
    return st.bytes;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "enc_vp9: the trees' codes" {
    // DC is one 0; TM 10; NEWMV 111; PARTITION_SPLIT 111; FOUR 011
    try testing.expectEqual(vb.Code{ .bits = 0, .len = 1 }, INTRA_CODES[0]);
    try testing.expectEqual(vb.Code{ .bits = 0b10, .len = 2 }, INTRA_CODES[9]);
    try testing.expectEqual(vb.Code{ .bits = 0b111, .len = 3 }, INTER_CODES[3]);
    try testing.expectEqual(vb.Code{ .bits = 0, .len = 1 }, INTER_CODES[2]);
    try testing.expectEqual(vb.Code{ .bits = 0b111, .len = 3 }, PARTITION_CODES[3]);
    try testing.expectEqual(vb.Code{ .bits = 0b011, .len = 3 }, CON_CODES[4]);
}

test "enc_vp9: the uncompressed header's bits" {
    var buf: [4]u8 = undefined;
    var b = Bits{ .buf = &buf };
    b.put(2, 2);
    b.put(2, 0);
    b.put(1, 0);
    b.put(1, 1);
    b.put(1, 1);
    b.put(1, 1);
    b.put(8, 0xa5);
    try testing.expectEqual(@as(usize, 2), b.bytes());
    try testing.expectEqual(@as(u8, 0x87), buf[0]);
    try testing.expectEqual(@as(u8, 0xa5), buf[1]);
}
