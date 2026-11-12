//! @zpm/va vp9_kernels — the VP9 encoder's pixel work (profile 0, 8-bit
//! 4:2:0), written once over vpx_dsl's backends (the CPU's, and KIR for
//! the RTX), as vp8_kernels.sig is for VP8:
//!
//!   (load)   vp8_kernels.load: the input picture into the source planes
//!   motion   every 16x16 unit's vector: a step-2 search on subsampled SADs,
//!            the best's full-pel neighbours, the zero vector, half and
//!            quarter pels through VP9's regular eight-tap filter
//!   luma16, luma8
//!            a wavefront of units (x + y = wave: each needs its left,
//!            above and above-left ones done): a unit is one 16x16 block
//!            (luma16), or 8x8 blocks where it leaves the frame's 8x8 grid
//!            (luma8); the mode (DC, V, H, TM or the motion search's
//!            vector) by SATD and the modes' bits; the transform size
//!            (intra: the block's, or 4x4 predicted one by one; inter: 8x8,
//!            or the block's where the residual is mostly its mean, as
//!            libvpx's real-time mode picks); the forward transform (DCT or
//!            ADST by the mode, libvpx's), quantization, and the
//!            reconstruction as libvpx's decoder makes it (its inverse
//!            transforms, its prediction edges)
//!   chroma16, chroma8
//!            the same wavefront after them: the chroma mode or
//!            prediction, the transforms (DCT), the block's skip flag, and
//!            what the loop filter does at each 8x8 cell's edges (libvpx's
//!            masks: vp9_loopfilter.c's build_masks and vp9_adjust_mask,
//!            per cell)
//!   lfv, lfh the loop filter, a wavefront of 64x64 superblocks (x + 2y =
//!            wave): every vertical edge of a superblock (an invocation a
//!            pixel row), then every horizontal one (a pixel column), in
//!            libvpx's order (filter_block_plane_ss00 and ss11)
//!
//! The CPU packs the unit records (modes, vectors, transform sizes,
//! quantized coefficients) into the bitstream (enc_vp9.sig).
//!
//! Each kernel stays under sm_120's compiler limits (16384 instructions
//! and registers): hence the 16x16 and 8x8 kernels, the chroma planes a
//! loop, one block-size transform of either kind. An if never has an else
//! when both sides hold divergent regions: they would share convergence
//! barriers (two ifs instead).

const std = @import("std");
const dsl = @import("vpx_dsl.sig");
const k8 = @import("vp8_kernels.sig");
const tx = @import("vp9_tx.sig");
const t9 = @import("vp9_enc_tables.sig");

pub const MEM = k8.MEM;
pub const INFO = k8.INFO;
pub const SURF = k8.SURF;

// ── Parameters: vp8_kernels' first 54 (the planes, load's), then these ──────
pub const P_COUNT = k8.P_COUNT;
pub const P_WAVE = k8.P_WAVE;
pub const P_YS = k8.P_YS;
pub const P_CS = k8.P_CS;
pub const P_SRC_Y = k8.P_SRC_Y;
pub const P_SRC_U = k8.P_SRC_U;
pub const P_SRC_V = k8.P_SRC_V;
pub const P_REC_Y = k8.P_REC_Y;
pub const P_REC_U = k8.P_REC_U;
pub const P_REC_V = k8.P_REC_V;
pub const P_REF_Y = k8.P_REF_Y;
pub const P_REF_U = k8.P_REF_U;
pub const P_REF_V = k8.P_REF_V;
pub const P_KEY = k8.P_KEY;
pub const P_W = k8.P_W;
pub const P_H = k8.P_H;
pub const P_AW = k8.P_AW;
pub const P_AH = k8.P_AH;
pub const P_WSHIFT = k8.P_WSHIFT;
/// dequantization factors: Y DC, Y AC, UV DC, UV AC; their reciprocals,
/// rounding offsets, largest levels
pub const P9_Q = 54;
pub const P9_QI = 58;
pub const P9_QR = 62;
pub const P9_LAMBDA = 66;
pub const P9_RANGE = 67;
/// units (16x16) across and down; the 8x8 grid's columns and rows
pub const P9_UW = 68;
pub const P9_UH = 69;
pub const P9_MIC = 70;
pub const P9_MIR = 71;
/// loop filter levels of intra and inter blocks; sharpness
pub const P9_LF_INTRA = 72;
pub const P9_LF_INTER = 73;
pub const P9_SHARP = 74;
/// the units' scratch in MEM (SCR_BYTES a row of units)
pub const P9_SCR = 75;
/// mode costs (1/16 bits): DC, V, H, TM; an inter block's; the chroma
/// modes; choosing 4x4 transforms
pub const P9_MCOST = 76;
pub const P9_INTER_COST = 80;
pub const P9_UVCOST = 81;
pub const P9_TX4_COST = 85;
/// superblocks across
pub const P9_SBW = 86;
pub const P9_QM = 87;
/// inter blocks' transforms: 1 8x8, 2 the block's size, 3 by the residual
/// (libvpx's real-time rule)
pub const P9_INTER_TX = 91;
pub const PARAMS = 92;

pub const Q_YDC = 0;
pub const Q_YAC = 1;
pub const Q_UVDC = 2;
pub const Q_UVAC = 3;

// ── The unit record (INFO), raster order of units ──────────────────────────
pub const U_BYTES = 1024;
/// the four 8x8 cells (raster in the unit), 16 bytes each
pub const C_KIND = 0; // 0 outside the frame, 1 an 8x8 block, 2 part of the 16x16 block
pub const C_INTER = 1;
pub const C_YMODE = 2; // VP9's numbers: DC 0, V 1, H 2, TM 9
pub const C_UVMODE = 3;
pub const C_TX = 4; // 0 4x4, 1 8x8, 2 16x16
pub const C_SKIP = 5;
pub const C_LEVEL = 6;
pub const C_LFY = 7; // left kind | top kind << 2 | 4x4 inside << 4 (kinds: 0, 1 4-wide, 2 8, 3 16)
pub const C_MVR = 8; // i16, eighth pels
pub const C_MVC = 10;
pub const C_LFUV = 12; // (cell 0) the unit's chroma cell: left | top << 2 | inside vertical << 4 | inside horizontal << 5
pub const C_LEVELUV = 13;
pub const C_NZY = 14; // the block's luma has a nonzero coefficient
pub const U_ME_MVR = 64;
pub const U_ME_MVC = 66;
pub const U_ME_COST = 68;
/// quantized coefficients, i16, each plane's laid out as its pixels
/// (a transform block's coefficient (r, c) where its pixel (r, c) is)
pub const U_Y = 128;
pub const U_U = 640;
pub const U_V = 768;

pub const SCR_BYTES = 4096;
const SCR_A = 0;
const SCR_B = 1024;
const SCR_R = 2048;

pub const MODE9 = [4]i32{ 0, 1, 2, 9 };

fn Be(comptime Ptr: type) type {
    return @typeInfo(Ptr).pointer.child;
}

inline fn bit(b: anytype, p: anytype) @TypeOf(b.c(0)) {
    return b.sel(p, b.c(1), b.c(0));
}

inline fn px8(b: anytype, off: anytype) @TypeOf(b.c(0)) {
    return b.ld(.u8, MEM, off);
}

/// What a unit's work needs.
fn Unit(comptime B: type) type {
    return struct {
        ux: B.V,
        uy: B.V,
        rec: B.V, // its record's offset
        scr: B.V, // its scratch's offset
        px: B.V,
        py: B.V,
        lambda: B.V,
    };
}

fn unitOf(b: anytype, ux: anytype, uy: anytype) Unit(Be(@TypeOf(b))) {
    const u = b.mad(uy, b.param(P9_UW), ux);
    return .{
        .ux = ux,
        .uy = uy,
        .rec = b.mul(u, b.c(U_BYTES)),
        // (a wavefront's units are on different rows: a row's scratch)
        .scr = b.add(b.param(P9_SCR), b.mul(uy, b.c(SCR_BYTES))),
        .px = b.shl(ux, b.c(4)),
        .py = b.shl(uy, b.c(4)),
        .lambda = b.param(P9_LAMBDA),
    };
}

/// The unit of wavefront `wave` (x + y = wave) this invocation has.
fn waveUnit(b: anytype) [2]@TypeOf(b.c(0)) {
    const wave = b.param(P_WAVE);
    const uymin = b.max(b.c(0), b.sub(wave, b.sub(b.param(P9_UW), b.c(1))));
    const uy = b.add(uymin, b.index());
    return .{ b.sub(wave, uy), uy };
}

// ── Pixels, prediction ──────────────────────────────────────────────────────

/// A reconstructed pixel as VP9's intra prediction sees the frame's edges
/// (libvpx's build_intra_predictors for DC, V, H, TM: above the frame 127,
/// its corner too; left of it 129).
fn edgePx(b: anytype, base: anytype, stride: anytype, x: anytype, y: anytype) @TypeOf(b.c(0)) {
    const cx = b.max(x, b.c(0));
    const cy = b.max(y, b.c(0));
    const v = px8(b, b.add(base, b.mad(cy, stride, cx)));
    return b.sel(b.lt(y, b.c(0)), b.c(127), b.sel(b.lt(x, b.c(0)), b.c(129), v));
}

/// The n x n DC by which edges there are (VP9's dc_pred variants).
fn dcOf(b: anytype, base: anytype, stride: anytype, x0: anytype, y0: anytype, comptime n: u32) @TypeOf(b.c(0)) {
    const ln: i32 = std.math.log2_int(u32, n);
    var sa = b.c(0);
    var sl = b.c(0);
    const row = b.add(base, b.mul(b.max(b.sub(y0, b.c(1)), b.c(0)), stride));
    const col = b.add(base, b.max(b.sub(x0, b.c(1)), b.c(0)));
    for (0..n) |k| {
        sa = b.add(sa, px8(b, b.add(row, b.add(x0, b.c(@intCast(k))))));
        sl = b.add(sl, px8(b, b.add(col, b.mul(b.add(y0, b.c(@intCast(k))), stride))));
    }
    const up = b.gt(y0, b.c(0));
    const left = b.gt(x0, b.c(0));
    const both = b.sar(b.add(b.add(sa, sl), b.c(@intCast(n))), b.c(ln + 1));
    const one_a = b.sar(b.add(sa, b.c(@intCast(n / 2))), b.c(ln));
    const one_l = b.sar(b.add(sl, b.c(@intCast(n / 2))), b.c(ln));
    return b.sel(b.pand(up, left), both, b.sel(up, one_a, b.sel(left, one_l, b.c(128))));
}

/// The prediction of mode `m` (0..3: DC, V, H, TM) of the n x n block at
/// (x0, y0) for its 4x4 part at (x, y).
fn intra4(b: anytype, base: anytype, stride: anytype, x0: anytype, y0: anytype, x: anytype, y: anytype, m: anytype, dc: anytype) [16]@TypeOf(b.c(0)) {
    var a: [4]@TypeOf(b.c(0)) = undefined;
    var l: [4]@TypeOf(b.c(0)) = undefined;
    for (0..4) |k| {
        a[k] = edgePx(b, base, stride, b.add(x, b.c(@intCast(k))), b.sub(y0, b.c(1)));
        l[k] = edgePx(b, base, stride, b.sub(x0, b.c(1)), b.add(y, b.c(@intCast(k))));
    }
    const corner = edgePx(b, base, stride, b.sub(x0, b.c(1)), b.sub(y0, b.c(1)));
    var p: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |r| {
        for (0..4) |c| {
            const tm = dsl.clip8(b, b.sub(b.add(l[r], a[c]), corner));
            p[r * 4 + c] = b.sel(b.eq(m, b.c(0)), dc, b.sel(b.eq(m, b.c(1)), a[c], b.sel(b.eq(m, b.c(2)), l[r], tm)));
        }
    }
    return p;
}

/// 16 pixels of a 4x4 block (x a multiple of 4).
fn block4(b: anytype, base: anytype, stride: anytype, x: anytype, y: anytype) [16]@TypeOf(b.c(0)) {
    var s: [16]@TypeOf(b.c(0)) = undefined;
    const at = b.add(base, b.mad(y, stride, x));
    for (0..4) |r| {
        const w = b.ld(.i32, MEM, b.add(at, b.mul(b.c(@intCast(r)), stride)));
        for (0..4) |c| s[r * 4 + c] = b.band(b.shr(w, b.c(@intCast(8 * c))), b.c(255));
    }
    return s;
}

fn store4(b: anytype, base: anytype, stride: anytype, x: anytype, y: anytype, v: [16]@TypeOf(b.c(0))) void {
    for (0..4) |r| {
        const row = b.add(base, b.add(b.mul(b.add(y, b.c(@intCast(r))), stride), x));
        const word = b.bor(b.bor(v[r * 4], b.shl(v[r * 4 + 1], b.c(8))), b.bor(b.shl(v[r * 4 + 2], b.c(16)), b.shl(v[r * 4 + 3], b.c(24))));
        b.st(.i32, MEM, row, word);
    }
}

fn diff16(b: anytype, s: [16]@TypeOf(b.c(0)), p: [16]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    var d: [16]@TypeOf(b.c(0)) = undefined;
    for (0..16) |k| d[k] = b.sub(s[k], p[k]);
    return d;
}

/// The eight taps of sub-pel position `f` (0..15).
fn taps8(b: anytype, f: anytype) [8]@TypeOf(b.c(0)) {
    var t: [8]@TypeOf(b.c(0)) = undefined;
    for (0..8) |k| {
        var v = b.c(t9.SUBPEL_FILTERS_8[0][k]);
        for (1..16) |p| {
            if (t9.SUBPEL_FILTERS_8[p][k] == t9.SUBPEL_FILTERS_8[0][k]) continue;
            v = b.sel(b.eq(f, b.c(@intCast(p))), b.c(t9.SUBPEL_FILTERS_8[p][k]), v);
        }
        t[k] = v;
    }
    return t;
}

fn filt8(b: anytype, t: [8]@TypeOf(b.c(0)), s: [8]@TypeOf(b.c(0))) @TypeOf(b.c(0)) {
    var acc = b.c(64);
    for (0..8) |k| acc = b.mad(s[k], t[k], acc);
    return dsl.clip8(b, b.sar(acc, b.c(7)));
}

/// A reference pixel, coordinates clamped to the picture (VP9's
/// reference: the cropped frame, its edges repeated without end).
inline fn refPx(b: anytype, base: anytype, stride: anytype, w: anytype, h: anytype, x: anytype, y: anytype) @TypeOf(b.c(0)) {
    const cx = dsl.clamp(b, x, b.c(0), b.sub(w, b.c(1)));
    const cy = dsl.clamp(b, y, b.c(0), b.sub(h, b.c(1)));
    return px8(b, b.add(base, b.mad(cy, stride, cx)));
}

/// The eight-tap prediction (libvpx's vpx_convolve8: horizontal then
/// vertical, 8-bit between) of the 4x4 block whose top-left is (x, y)
/// plus a vector's whole pels, `fx`, `fy` its sixteenths.
pub fn pred8x4(b: anytype, plane: anytype, stride: anytype, w: anytype, h: anytype, x: anytype, y: anytype, fx: anytype, fy: anytype) [16]@TypeOf(b.c(0)) {
    const V = @TypeOf(b.c(0));
    const th = taps8(b, fx);
    const tv = taps8(b, fy);
    // the reference's rows and columns, clamped to the picture once
    var cols: [11]V = undefined;
    for (0..11) |c| cols[c] = dsl.clamp(b, b.add(x, b.c(@as(i32, @intCast(c)) - 3)), b.c(0), b.sub(w, b.c(1)));
    var first: [11][4]V = undefined;
    for (0..11) |r| {
        const yy = dsl.clamp(b, b.add(y, b.c(@as(i32, @intCast(r)) - 3)), b.c(0), b.sub(h, b.c(1)));
        const at = b.mad(yy, stride, plane);
        var row: [11]V = undefined;
        for (0..11) |c| row[c] = px8(b, b.add(at, cols[c]));
        for (0..4) |c| first[r][c] = filt8(b, th, row[c..][0..8].*);
    }
    var out: [16]V = undefined;
    for (0..4) |r| {
        for (0..4) |c| {
            var col: [8]V = undefined;
            for (0..8) |k| col[k] = first[r + k][c];
            out[r * 4 + c] = filt8(b, tv, col);
        }
    }
    return out;
}

/// A plane's inter prediction of the 4x4 block at (x, y): luma (vector
/// in eighths) or chroma (the same vector, sixteenths of its pels).
fn interPred(b: anytype, comptime is_luma: bool, ref: anytype, stride: anytype, x: anytype, y: anytype, mvr: anytype, mvc: anytype) [16]@TypeOf(b.c(0)) {
    const w = if (is_luma) b.param(P_W) else b.shr(b.add(b.param(P_W), b.c(1)), b.c(1));
    const h = if (is_luma) b.param(P_H) else b.shr(b.add(b.param(P_H), b.c(1)), b.c(1));
    if (is_luma) {
        return pred8x4(b, ref, stride, w, h, b.add(x, b.sar(mvc, b.c(3))), b.add(y, b.sar(mvr, b.c(3))), b.shl(b.band(mvc, b.c(7)), b.c(1)), b.shl(b.band(mvr, b.c(7)), b.c(1)));
    }
    return pred8x4(b, ref, stride, w, h, b.add(x, b.sar(mvc, b.c(4))), b.add(y, b.sar(mvr, b.c(4))), b.band(mvc, b.c(15)), b.band(mvr, b.c(15)));
}

// ── Quantization and the transforms of a block ─────────────────────────────

pub fn quant(b: anytype, x: @TypeOf(b.c(0)), comptime kind: usize) @TypeOf(b.c(0)) {
    const a = b.abs(x);
    const l = b.min(b.sar(b.mul(b.add(a, b.param(P9_QR + kind)), b.param(P9_QI + kind)), b.c(16)), b.param(P9_QM + kind));
    return b.sel(b.lt(x, b.c(0)), b.neg(l), l);
}

/// Where a plane's coefficient (r, c) of a unit's record is.
fn coefAt(b: anytype, base: anytype, comptime stride: i32, r: anytype, c: anytype) @TypeOf(b.c(0)) {
    return b.add(base, b.shl(b.mad(r, b.c(stride), c), b.c(1)));
}

/// What a transform block works with: its plane (reconstruction, source),
/// its place (pixels; and in the unit's coefficients), its type.
fn Tb(comptime B: type) type {
    return struct {
        rec: B.V, // plane base (MEM)
        src: B.V,
        stride: B.V,
        x: B.V,
        y: B.V,
        coef: B.V, // the unit plane's coefficients (INFO)
        cx: B.V, // the block's place in them
        cy: B.V,
        ttype: B.V, // 0 DCT_DCT, 1 ADST_DCT, 2 DCT_ADST, 3 ADST_ADST
        scr: B.V,
        nz: B.Var,
    };
}

fn sel4(b: anytype, p: anytype, x: [4]@TypeOf(b.c(0)), y: [4]@TypeOf(b.c(0))) [4]@TypeOf(b.c(0)) {
    var o: [4]@TypeOf(b.c(0)) = undefined;
    for (0..4) |k| o[k] = b.sel(p, x[k], y[k]);
    return o;
}

/// A 4x4 transform block, the prediction already in the reconstruction:
/// the residual's forward transform (libvpx's vp9_fht4x4), quantization,
/// the levels stored, the decoder's inverse (vp9_iht4x4_16_add), the
/// reconstruction stored. Its SATD of the residual returned.
fn tx4(b: anytype, t: anytype, comptime coef_stride: i32, comptime qdc: usize, comptime qac: usize, comptime dct_only: bool) @TypeOf(b.c(0)) {
    const V = @TypeOf(b.c(0));
    const pred = block4(b, t.rec, t.stride, t.x, t.y);
    const src = block4(b, t.src, t.stride, t.x, t.y);
    const res = diff16(b, src, pred);
    const col_adst = b.ne(b.band(t.ttype, b.c(1)), b.c(0));
    const row_adst = b.ne(b.band(t.ttype, b.c(2)), b.c(0));
    // (chroma's: the DCT only, no ADST code)
    const T4 = struct {
        fn fwd(bb: anytype, p: anytype, in: [4]@TypeOf(bb.c(0))) [4]@TypeOf(bb.c(0)) {
            if (dct_only) return tx.fdct4(bb, in);
            return sel4(bb, p, tx.fadst4(bb, in), tx.fdct4(bb, in));
        }
        fn inv(bb: anytype, p: anytype, in: [4]@TypeOf(bb.c(0))) [4]@TypeOf(bb.c(0)) {
            if (dct_only) return tx.idct4(bb, in);
            return sel4(bb, p, tx.iadst4(bb, in), tx.idct4(bb, in));
        }
    };
    // forward: columns (x16, the first input +1), then rows ((x + 1) >> 2)
    var tmp: [16]V = undefined;
    for (0..4) |i| {
        var in: [4]V = undefined;
        for (0..4) |j| in[j] = b.shl(res[j * 4 + i], b.c(4));
        if (i == 0) in[0] = b.add(in[0], bit(b, b.ne(in[0], b.c(0))));
        const o = T4.fwd(b, col_adst, in);
        for (0..4) |j| tmp[j * 4 + i] = o[j];
    }
    var dq: [16]V = undefined;
    var nz = b.get(t.nz);
    inline for (0..4) |i| {
        const o = T4.fwd(b, row_adst, tmp[i * 4 ..][0..4].*);
        inline for (0..4) |j| {
            const co = b.sar(b.add(o[j], b.c(1)), b.c(2));
            const kind = if (i == 0 and j == 0) qdc else qac;
            const l = quant(b, co, kind);
            b.st(.i16, INFO, coefAt(b, t.coef, coef_stride, b.add(t.cy, b.c(@intCast(i))), b.add(t.cx, b.c(@intCast(j)))), l);
            nz = b.bor(nz, l);
            dq[i * 4 + j] = b.mul(l, b.param(P9_Q + kind));
        }
    }
    b.put(t.nz, nz);
    // inverse: rows, columns, >> 4
    var rows: [16]V = undefined;
    for (0..4) |i| {
        const o = T4.inv(b, row_adst, dq[i * 4 ..][0..4].*);
        for (0..4) |j| rows[i * 4 + j] = o[j];
    }
    var out: [16]V = undefined;
    for (0..4) |j| {
        const in = [4]V{ rows[j], rows[4 + j], rows[8 + j], rows[12 + j] };
        const o = T4.inv(b, col_adst, in);
        for (0..4) |k| out[k * 4 + j] = dsl.clip8(b, b.add(pred[k * 4 + j], b.sar(b.add(o[k], b.c(8)), b.c(4))));
    }
    store4(b, t.rec, t.stride, t.x, t.y, out);
    return k8.satd(b, res);
}

/// The 1-D transforms of `n` points by type (adst or not) into the
/// scratch row R: forward or inverse.
fn tx1d(b: anytype, comptime n: u32, comptime inverse: bool, adst: anytype, in: [n]@TypeOf(b.c(0)), scr: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const W = struct {
        in: [n]V,
        scr: V,
        fn put(bb: *B, s: V, o: [n]V) void {
            for (0..n) |k| bb.st(.i32, MEM, bb.add(s, bb.c(@intCast(SCR_R + 4 * k))), o[k]);
        }
        pub fn then(s: @This(), bb: *B) void {
            put(bb, s.scr, switch (n) {
                8 => if (inverse) tx.iadst8(bb, s.in) else tx.fadst8(bb, s.in),
                16 => if (inverse) tx.iadst16(bb, s.in) else tx.fadst16(bb, s.in),
                else => unreachable,
            });
        }
        pub fn otherwise(s: @This(), bb: *B) void {
            put(bb, s.scr, switch (n) {
                8 => if (inverse) tx.idct8(bb, s.in) else tx.fdct8(bb, s.in),
                16 => if (inverse) tx.idct16(bb, s.in) else tx.fdct16(bb, s.in),
                else => unreachable,
            });
        }
    };
    b.whenElse(adst, W{ .in = in, .scr = scr });
}

fn rowR(b: anytype, comptime n: u32, scr: anytype) [n]@TypeOf(b.c(0)) {
    var o: [n]@TypeOf(b.c(0)) = undefined;
    for (0..n) |k| o[k] = b.ld(.i32, MEM, b.add(scr, b.c(@intCast(SCR_R + 4 * k))));
    return o;
}

/// An 8x8 or 16x16 transform block (as tx4, through the unit's scratch):
/// libvpx's vp9_fht8x8 / vp9_fht16x16 forward, vp9_iht8x8_64_add /
/// vp9_iht16x16_256_add inverse.
fn txN(b: anytype, t: anytype, comptime n: u32, comptime coef_stride: i32, comptime qdc: usize, comptime qac: usize) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const T = @TypeOf(t);
    const col_adst = b.ne(b.band(t.ttype, b.c(1)), b.c(0));
    const row_adst = b.ne(b.band(t.ttype, b.c(2)), b.c(0));
    const S = struct {
        t: T,
        col_adst: B.P,
        row_adst: B.P,
        fn a(bb: *B, s: V, i: V, k: V) V {
            return bb.add(s, bb.shl(bb.mad(i, bb.c(@intCast(n)), k), bb.c(2)));
        }
    };
    const s = S{ .t = t, .col_adst = col_adst, .row_adst = row_adst };
    // forward columns: residual x4, (16: (x + 1 + (x < 0)) >> 2) into A
    const FC = struct {
        s: S,
        pub fn body(o: @This(), bb: *B, j: V) void {
            const tt = o.s.t;
            var in: [n]V = undefined;
            for (0..n) |k| {
                const yy = bb.add(tt.y, bb.c(@intCast(k)));
                const xx = bb.add(tt.x, j);
                const sp = px8(bb, bb.add(tt.src, bb.mad(yy, tt.stride, xx)));
                const pp = px8(bb, bb.add(tt.rec, bb.mad(yy, tt.stride, xx)));
                in[k] = bb.shl(bb.sub(sp, pp), bb.c(2));
            }
            tx1d(bb, n, false, o.s.col_adst, in, tt.scr);
            const out = rowR(bb, n, tt.scr);
            for (0..n) |k| {
                var v = out[k];
                if (n == 16) v = bb.sar(bb.add(bb.add(v, bb.c(1)), bit(bb, bb.lt(v, bb.c(0)))), bb.c(2));
                bb.st(.i32, MEM, S.a(bb, bb.add(tt.scr, bb.c(SCR_A)), bb.c(@intCast(k)), j), v);
            }
        }
    };
    b.loop(b.c(@intCast(n)), FC{ .s = s });
    // forward rows (8: (x + (x < 0)) >> 1), quantized, stored; dequantized into B
    const FR = struct {
        s: S,
        pub fn body(o: @This(), bb: *B, i: V) void {
            const tt = o.s.t;
            var in: [n]V = undefined;
            for (0..n) |k| in[k] = bb.ld(.i32, MEM, S.a(bb, bb.add(tt.scr, bb.c(SCR_A)), i, bb.c(@intCast(k))));
            tx1d(bb, n, false, o.s.row_adst, in, tt.scr);
            const out = rowR(bb, n, tt.scr);
            var nz = bb.get(tt.nz);
            const first = bb.eq(i, bb.c(0));
            inline for (0..n) |k| {
                var v = out[k];
                if (n == 8) v = bb.sar(bb.add(v, bit(bb, bb.lt(v, bb.c(0)))), bb.c(1));
                var l = quant(bb, v, qac);
                var dq = bb.mul(l, bb.param(P9_Q + qac));
                if (k == 0) {
                    const ld = quant(bb, v, qdc);
                    l = bb.sel(first, ld, l);
                    dq = bb.sel(first, bb.mul(ld, bb.param(P9_Q + qdc)), dq);
                }
                bb.st(.i16, INFO, coefAt(bb, tt.coef, coef_stride, bb.add(tt.cy, i), bb.add(tt.cx, bb.c(@intCast(k)))), l);
                nz = bb.bor(nz, l);
                bb.st(.i32, MEM, S.a(bb, bb.add(tt.scr, bb.c(SCR_B)), i, bb.c(@intCast(k))), dq);
            }
            bb.put(tt.nz, nz);
        }
    };
    b.loop(b.c(@intCast(n)), FR{ .s = s });
    // inverse rows: B into A
    const IR = struct {
        s: S,
        pub fn body(o: @This(), bb: *B, i: V) void {
            const tt = o.s.t;
            var in: [n]V = undefined;
            for (0..n) |k| in[k] = bb.ld(.i32, MEM, S.a(bb, bb.add(tt.scr, bb.c(SCR_B)), i, bb.c(@intCast(k))));
            tx1d(bb, n, true, o.s.row_adst, in, tt.scr);
            const out = rowR(bb, n, tt.scr);
            for (0..n) |k| bb.st(.i32, MEM, S.a(bb, bb.add(tt.scr, bb.c(SCR_A)), i, bb.c(@intCast(k))), out[k]);
        }
    };
    b.loop(b.c(@intCast(n)), IR{ .s = s });
    // inverse columns, rounded (8: >> 5, 16: >> 6), added to the prediction
    const IC = struct {
        s: S,
        pub fn body(o: @This(), bb: *B, j: V) void {
            const tt = o.s.t;
            var in: [n]V = undefined;
            for (0..n) |k| in[k] = bb.ld(.i32, MEM, S.a(bb, bb.add(tt.scr, bb.c(SCR_A)), bb.c(@intCast(k)), j));
            tx1d(bb, n, true, o.s.col_adst, in, tt.scr);
            const out = rowR(bb, n, tt.scr);
            const sh: i32 = if (n == 8) 5 else 6;
            for (0..n) |k| {
                const at = bb.add(tt.rec, bb.mad(bb.add(tt.y, bb.c(@intCast(k))), tt.stride, bb.add(tt.x, j)));
                const r = bb.sar(bb.add(out[k], bb.c(@as(i32, 1) << @intCast(sh - 1))), bb.c(sh));
                bb.st(.u8, MEM, at, dsl.clip8(bb, bb.add(px8(bb, at), r)));
            }
        }
    };
    b.loop(b.c(@intCast(n)), IC{ .s = s });
}

// ── motion ──────────────────────────────────────────────────────────────────

fn mvBits(b: anytype, d: anytype) @TypeOf(b.c(0)) {
    const a = b.abs(d);
    var n = b.c(1);
    inline for ([_]i32{ 0, 1, 3, 7, 15, 31, 63, 127, 255 }) |t| n = b.add(n, b.shl(bit(b, b.gt(a, b.c(t))), b.c(1)));
    return n;
}

fn consider(b: anytype, best: anytype, br: anytype, bc: anytype, cost: anytype, r: anytype, c: anytype) void {
    const better = b.lt(cost, b.get(best));
    b.put(best, b.sel(better, cost, b.get(best)));
    b.put(br, b.sel(better, r, b.get(br)));
    b.put(bc, b.sel(better, c, b.get(bc)));
}

/// SAD of the unit's 16x16 source and the reference at (dx, dy), every
/// `step`-th row and column.
fn sad16(b: anytype, px: anytype, py: anytype, dx: anytype, dy: anytype, comptime step: u32) @TypeOf(b.c(0)) {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const acc = b.vr(b.c(0));
    const Row = struct {
        acc: B.Var,
        px: V,
        py: V,
        dx: V,
        dy: V,
        pub fn body(s: @This(), bb: *B, r: V) void {
            const y = bb.add(s.py, bb.mul(r, bb.c(@intCast(step))));
            const ys = bb.param(P_YS);
            const src = bb.add(bb.param(P_SRC_Y), bb.mad(y, ys, s.px));
            const ry = bb.add(y, s.dy);
            const rx = bb.add(s.px, s.dx);
            var sum = bb.get(s.acc);
            var c: u32 = 0;
            while (c < 16) : (c += step) {
                const a = px8(bb, bb.add(src, bb.c(@intCast(c))));
                const r2 = refPx(bb, bb.param(P_REF_Y), ys, bb.param(P_W), bb.param(P_H), bb.add(rx, bb.c(@intCast(c))), ry);
                sum = bb.add(sum, bb.abs(bb.sub(a, r2)));
            }
            bb.put(s.acc, sum);
        }
    };
    b.loop(b.c(@intCast(16 / step)), Row{ .acc = acc, .px = px, .py = py, .dx = dx, .dy = dy });
    return b.get(acc);
}

/// SAD of the unit's source and the eight-tap prediction at (mvr, mvc).
fn sadSub(b: anytype, px: anytype, py: anytype, mvr: anytype, mvc: anytype) @TypeOf(b.c(0)) {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const acc = b.vr(b.c(0));
    const Blk = struct {
        acc: B.Var,
        px: V,
        py: V,
        mvr: V,
        mvc: V,
        pub fn body(s: @This(), bb: *B, j: V) void {
            const bx = bb.add(s.px, bb.shl(bb.band(j, bb.c(3)), bb.c(2)));
            const by = bb.add(s.py, bb.shl(bb.shr(j, bb.c(2)), bb.c(2)));
            const ys = bb.param(P_YS);
            const p = interPred(bb, true, bb.param(P_REF_Y), ys, bx, by, s.mvr, s.mvc);
            const src = block4(bb, bb.param(P_SRC_Y), ys, bx, by);
            var sum = bb.get(s.acc);
            for (0..16) |k| sum = bb.add(sum, bb.abs(bb.sub(src[k], p[k])));
            bb.put(s.acc, sum);
        }
    };
    b.loop(b.c(16), Blk{ .acc = acc, .px = px, .py = py, .mvr = mvr, .mvc = mvc });
    return b.get(acc);
}

fn divide3(b: anytype, k: anytype) @TypeOf(b.c(0)) {
    return b.shr(b.mul(k, b.c(11)), b.c(5));
}

/// Every unit's vector (inter frames): an invocation a unit, its index
/// uy << P_WSHIFT | ux.
pub fn motion(b: anytype) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            motionUnit(bb);
        }
    };
    const i = b.index();
    const ux = b.band(i, b.sub(b.shl(b.c(1), b.param(P_WSHIFT)), b.c(1)));
    b.when(b.pand(b.lt(i, b.param(P_COUNT)), b.lt(ux, b.param(P9_UW))), T{});
}

fn motionUnit(b: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const i = b.index();
    const shift = b.param(P_WSHIFT);
    const uy = b.shr(i, shift);
    const ux = b.band(i, b.sub(b.shl(b.c(1), shift), b.c(1)));
    const u = unitOf(b, ux, uy);
    const px = u.px;
    const py = u.py;
    const lambda = u.lambda;
    const range = b.param(P9_RANGE);
    // the window: a block out of the frame's 8x8 grid by at most 8 pels
    // (no prediction of the decoder's clamps the vector)
    const gw = b.shl(b.param(P9_MIC), b.c(3));
    const gh = b.shl(b.param(P9_MIR), b.c(3));
    const lo_x = b.max(b.neg(range), b.sub(b.c(-8), px));
    const hi_x = b.max(lo_x, b.min(range, b.sub(b.sub(gw, b.c(8)), px)));
    const lo_y = b.max(b.neg(range), b.sub(b.c(-8), py));
    const hi_y = b.max(lo_y, b.min(range, b.sub(b.sub(gh, b.c(8)), py)));

    const best = b.vr(b.c(0x7fff_ffff));
    const bdx = b.vr(b.c(0));
    const bdy = b.vr(b.c(0));
    const Win = struct { best: B.Var, bdx: B.Var, bdy: B.Var, px: V, py: V, lo_x: V, hi_x: V, lo_y: V, hi_y: V, lambda: V };
    const win = Win{ .best = best, .bdx = bdx, .bdy = bdy, .px = px, .py = py, .lo_x = lo_x, .hi_x = hi_x, .lo_y = lo_y, .hi_y = hi_y, .lambda = lambda };
    const Col = struct {
        w: Win,
        dy: V,
        pub fn body(s: @This(), bb: *B, k: V) void {
            const dx = bb.add(s.w.lo_x, bb.shl(k, bb.c(1)));
            const sad = bb.shl(sad16(bb, s.w.px, s.w.py, dx, s.dy, 2), bb.c(2));
            const bits = bb.add(mvBits(bb, bb.shl(dx, bb.c(2))), mvBits(bb, bb.shl(s.dy, bb.c(2))));
            consider(bb, s.w.best, s.w.bdy, s.w.bdx, bb.add(sad, bb.sar(bb.mul(bits, s.w.lambda), bb.c(4))), s.dy, dx);
        }
    };
    const RowS = struct {
        w: Win,
        pub fn body(s: @This(), bb: *B, k: V) void {
            const dy = bb.add(s.w.lo_y, bb.shl(k, bb.c(1)));
            bb.loop(bb.add(bb.shr(bb.sub(s.w.hi_x, s.w.lo_x), bb.c(1)), bb.c(1)), Col{ .w = s.w, .dy = dy });
        }
    };
    b.loop(b.add(b.shr(b.sub(hi_y, lo_y), b.c(1)), b.c(1)), RowS{ .w = win });

    const cdx = b.get(bdx);
    const cdy = b.get(bdy);
    b.put(best, b.add(sad16(b, px, py, b.c(0), b.c(0), 1), b.sar(b.mul(b.c(2), lambda), b.c(4))));
    b.put(bdx, b.c(0));
    b.put(bdy, b.c(0));
    const Fine = struct {
        w: Win,
        cdx: V,
        cdy: V,
        const Try = struct {
            w: Win,
            dx: V,
            dy: V,
            pub fn then(t: @This(), b2: *B) void {
                const sad = sad16(b2, t.w.px, t.w.py, t.dx, t.dy, 1);
                const bits = b2.add(mvBits(b2, b2.shl(t.dx, b2.c(2))), mvBits(b2, b2.shl(t.dy, b2.c(2))));
                consider(b2, t.w.best, t.w.bdy, t.w.bdx, b2.add(sad, b2.sar(b2.mul(bits, t.w.lambda), b2.c(4))), t.dy, t.dx);
            }
        };
        pub fn body(s: @This(), bb: *B, k: V) void {
            const q = divide3(bb, k);
            const dy = bb.add(s.cdy, bb.sub(q, bb.c(1)));
            const dx = bb.add(s.cdx, bb.sub(bb.sub(k, bb.mul(q, bb.c(3))), bb.c(1)));
            const inside = bb.pand(bb.pand(bb.ge(dx, s.w.lo_x), bb.le(dx, s.w.hi_x)), bb.pand(bb.ge(dy, s.w.lo_y), bb.le(dy, s.w.hi_y)));
            bb.when(inside, Try{ .w = s.w, .dx = dx, .dy = dy });
        }
    };
    b.loop(b.c(9), Fine{ .w = win, .cdx = cdx, .cdy = cdy });

    const mvr = b.vr(b.shl(b.get(bdy), b.c(3)));
    const mvc = b.vr(b.shl(b.get(bdx), b.c(3)));
    const sub_best = b.vr(b.c(0));
    b.put(sub_best, b.add(sadSub(b, px, py, b.get(mvr), b.get(mvc)), b.sar(b.mul(b.add(mvBits(b, b.sar(b.get(mvr), b.c(1))), mvBits(b, b.sar(b.get(mvc), b.c(1)))), lambda), b.c(4))));
    const SubW = struct { best: B.Var, mvr: B.Var, mvc: B.Var, cr: V, cc: V, w: Win };
    inline for ([_]i32{ 4, 2 }) |step| {
        const Sub = struct {
            s: SubW,
            const Try = struct {
                s: SubW,
                r: V,
                c: V,
                pub fn then(t: @This(), b2: *B) void {
                    const sad = sadSub(b2, t.s.w.px, t.s.w.py, t.r, t.c);
                    const bits = b2.add(mvBits(b2, b2.sar(t.r, b2.c(1))), mvBits(b2, b2.sar(t.c, b2.c(1))));
                    consider(b2, t.s.best, t.s.mvr, t.s.mvc, b2.add(sad, b2.sar(b2.mul(bits, t.s.w.lambda), b2.c(4))), t.r, t.c);
                }
            };
            pub fn body(o: @This(), bb: *B, k: V) void {
                const kk = bb.add(k, bit(bb, bb.ge(k, bb.c(4))));
                const q = divide3(bb, kk);
                const r = bb.add(o.s.cr, bb.mul(bb.sub(q, bb.c(1)), bb.c(step)));
                const c = bb.add(o.s.cc, bb.mul(bb.sub(bb.sub(kk, bb.mul(q, bb.c(3))), bb.c(1)), bb.c(step)));
                const w = o.s.w;
                const inside = bb.pand(bb.pand(bb.ge(c, bb.shl(w.lo_x, bb.c(3))), bb.le(c, bb.shl(w.hi_x, bb.c(3)))), bb.pand(bb.ge(r, bb.shl(w.lo_y, bb.c(3))), bb.le(r, bb.shl(w.hi_y, bb.c(3)))));
                bb.when(inside, Try{ .s = o.s, .r = r, .c = c });
            }
        };
        b.loop(b.c(8), Sub{ .s = .{ .best = sub_best, .mvr = mvr, .mvc = mvc, .cr = b.get(mvr), .cc = b.get(mvc), .w = win } });
    }
    b.st(.i16, INFO, b.add(u.rec, b.c(U_ME_MVR)), b.get(mvr));
    b.st(.i16, INFO, b.add(u.rec, b.c(U_ME_MVC)), b.get(mvc));
    b.st(.i32, INFO, b.add(u.rec, b.c(U_ME_COST)), b.get(sub_best));
}

// ── luma ────────────────────────────────────────────────────────────────────

/// The luma of a wavefront's units that are one 16x16 block.
pub fn luma16(b: anytype) void {
    lumaKernel(b, 16);
}

/// The luma of a wavefront's units at the 8x8 grid's edge (8x8 blocks).
pub fn luma8(b: anytype) void {
    lumaKernel(b, 8);
}

fn lumaKernel(b: anytype, comptime n: u32) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            lumaUnit(bb, n);
        }
    };
    b.when(b.lt(b.index(), b.param(P_COUNT)), T{});
}

fn cellAt(b: anytype, u: anytype, k: anytype, comptime field: i32) @TypeOf(b.c(0)) {
    return b.add(u.rec, b.add(b.shl(k, b.c(4)), b.c(field)));
}

fn lumaUnit(b: anytype, comptime n: u32) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const xy = waveUnit(b);
    const u = unitOf(b, xy[0], xy[1]);
    const mi_r = b.shl(u.uy, b.c(1));
    const mi_c = b.shl(u.ux, b.c(1));
    const full = b.pand(b.lt(b.add(mi_r, b.c(1)), b.param(P9_MIR)), b.lt(b.add(mi_c, b.c(1)), b.param(P9_MIC)));
    const U = Unit(B);
    const Full = struct {
        u: U,
        pub fn then(s: @This(), bb: *B) void {
            lumaBlock(bb, s.u, 16, s.u.px, s.u.py, bb.c(0));
        }
        const Cell = struct {
            u: U,
            mi_r: V,
            mi_c: V,
            const In = struct {
                u: U,
                k: V,
                pub fn then(t: @This(), b2: *B) void {
                    const x0 = b2.add(t.u.px, b2.shl(b2.band(t.k, b2.c(1)), b2.c(3)));
                    const y0 = b2.add(t.u.py, b2.shl(b2.shr(t.k, b2.c(1)), b2.c(3)));
                    lumaBlock(b2, t.u, 8, x0, y0, t.k);
                }
                pub fn otherwise(t: @This(), b2: *B) void {
                    b2.st(.u8, INFO, cellAt(b2, t.u, t.k, C_KIND), b2.c(0));
                }
            };
            pub fn body(s: @This(), bb: *B, k: V) void {
                const r = bb.add(s.mi_r, bb.shr(k, bb.c(1)));
                const c = bb.add(s.mi_c, bb.band(k, bb.c(1)));
                const inside = bb.pand(bb.lt(r, bb.param(P9_MIR)), bb.lt(c, bb.param(P9_MIC)));
                bb.whenElse(inside, In{ .u = s.u, .k = k });
            }
        };
        pub fn otherwise(s: @This(), bb: *B) void {
            bb.loop(bb.c(4), Cell{ .u = s.u, .mi_r = bb.shl(s.u.uy, bb.c(1)), .mi_c = bb.shl(s.u.ux, bb.c(1)) });
        }
    };
    const Edge = struct {
        f: Full,
        pub fn then(s: @This(), bb: *B) void {
            s.f.otherwise(bb);
        }
    };
    if (n == 16) b.when(full, Full{ .u = u }) else b.when(b.pnot(full), Edge{ .f = .{ .u = u } });
}

/// An if-else body's then side as an if body.
fn Then(comptime S: type) type {
    return struct {
        s: S,
        pub fn then(o: @This(), bb: anytype) void {
            o.s.then(bb);
        }
    };
}

/// Its else side as an if body.
fn Else(comptime S: type) type {
    return struct {
        s: S,
        pub fn then(o: @This(), bb: anytype) void {
            o.s.otherwise(bb);
        }
    };
}

/// The 4x4 parts of an n x n block: (x, y) of part j.
fn partXy(b: anytype, comptime n: u32, x0: anytype, y0: anytype, j: anytype) [2]@TypeOf(b.c(0)) {
    const per: i32 = @intCast(n / 4);
    const sh: i32 = std.math.log2_int(u32, n / 4);
    return .{ b.add(x0, b.shl(b.band(j, b.c(per - 1)), b.c(2))), b.add(y0, b.shl(b.shr(j, b.c(sh)), b.c(2))) };
}

/// A luma block of n x n (16, or 8 at the frame's edge) at (x0, y0), its
/// first cell `cell`: the mode, the transform size, the reconstruction,
/// the cells' records.
fn lumaBlock(b: anytype, u: anytype, comptime n: u32, x0: anytype, y0: anytype, cell: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const U = @TypeOf(u);
    const parts: i32 = @intCast((n / 4) * (n / 4));
    const key = b.ne(b.param(P_KEY), b.c(0));
    const base = b.param(P_REC_Y);
    const ys = b.param(P_YS);
    const dc = dcOf(b, base, ys, x0, y0, n);
    const best = b.vr(b.c(0x7fff_ffff));
    const best_m = b.vr(b.c(0));
    inline for (0..4) |m| {
        const Cost = struct {
            x0: V,
            y0: V,
            dc: V,
            acc: B.Var,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const xy = partXy(bb, n, s.x0, s.y0, j);
                const p = intra4(bb, bb.param(P_REC_Y), bb.param(P_YS), s.x0, s.y0, xy[0], xy[1], bb.c(m), s.dc);
                const src = block4(bb, bb.param(P_SRC_Y), bb.param(P_YS), xy[0], xy[1]);
                bb.put(s.acc, bb.add(bb.get(s.acc), k8.satd(bb, diff16(bb, src, p))));
            }
        };
        const acc = b.vr(b.c(0));
        b.loop(b.c(parts), Cost{ .x0 = x0, .y0 = y0, .dc = dc, .acc = acc });
        const cost = b.add(b.get(acc), b.sar(b.mul(u.lambda, b.param(P9_MCOST + m)), b.c(8)));
        const better = b.lt(cost, b.get(best));
        b.put(best, b.sel(better, cost, b.get(best)));
        b.put(best_m, b.sel(better, b.c(m), b.get(best_m)));
    }
    const intra_cost = b.get(best);
    const inter = b.vr(b.c(0));
    const mvr = b.vr(b.c(0));
    const mvc = b.vr(b.c(0));
    const Inter = struct {
        u: U,
        x0: V,
        y0: V,
        best: B.Var,
        inter: B.Var,
        mvr: B.Var,
        mvc: B.Var,
        const Cost = struct {
            x0: V,
            y0: V,
            r: V,
            c: V,
            acc: B.Var,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const xy = partXy(bb, n, s.x0, s.y0, j);
                const p = interPred(bb, true, bb.param(P_REF_Y), bb.param(P_YS), xy[0], xy[1], s.r, s.c);
                const src = block4(bb, bb.param(P_SRC_Y), bb.param(P_YS), xy[0], xy[1]);
                bb.put(s.acc, bb.add(bb.get(s.acc), k8.satd(bb, diff16(bb, src, p))));
            }
        };
        pub fn then(s: @This(), bb: *B) void {
            const r = bb.ld(.i16, INFO, bb.add(s.u.rec, bb.c(U_ME_MVR)));
            const c = bb.ld(.i16, INFO, bb.add(s.u.rec, bb.c(U_ME_MVC)));
            const acc = bb.vr(bb.c(0));
            bb.loop(bb.c(parts), Cost{ .x0 = s.x0, .y0 = s.y0, .r = r, .c = c, .acc = acc });
            const bits16 = bb.add(bb.param(P9_INTER_COST), bb.shl(bb.add(mvBits(bb, bb.sar(r, bb.c(1))), mvBits(bb, bb.sar(c, bb.c(1)))), bb.c(4)));
            const cost = bb.add(bb.get(acc), bb.sar(bb.mul(s.u.lambda, bits16), bb.c(8)));
            const better = bb.lt(cost, bb.get(s.best));
            bb.put(s.best, bb.sel(better, cost, bb.get(s.best)));
            bb.put(s.inter, bit(bb, better));
            bb.put(s.mvr, bb.sel(better, r, bb.c(0)));
            bb.put(s.mvc, bb.sel(better, c, bb.c(0)));
        }
    };
    b.when(b.pnot(key), Inter{ .u = u, .x0 = x0, .y0 = y0, .best = best, .inter = inter, .mvr = mvr, .mvc = mvc });
    const is_inter = b.ne(b.get(inter), b.c(0));
    const m = b.get(best_m);
    const nz = b.vr(b.c(0));
    const txs = b.vr(b.c(if (n == 16) 2 else 1));
    const tb = Tb(B){
        .rec = base,
        .src = b.param(P_SRC_Y),
        .stride = ys,
        .x = x0,
        .y = y0,
        .coef = b.add(u.rec, b.c(U_Y)),
        .cx = b.sub(x0, u.px),
        .cy = b.sub(y0, u.py),
        .ttype = b.c(0),
        .scr = u.scr,
        .nz = nz,
    };
    const Rec = struct {
        const Self = @This();
        u: U,
        x0: V,
        y0: V,
        m: V,
        dc: V,
        intra_cost: V,
        mvr: V,
        mvc: V,
        tb: Tb(B),
        txs: B.Var,
        nz: B.Var,
        /// what comes after the prediction: 1 the block's own transform
        /// (an inter block's or an intra one's), 2 an inter 16x16 block's
        /// four 8x8 ones
        next: B.Var,
        // the whole block's prediction into the reconstruction
        fn PredT(comptime inter_pred: bool) type {
            return struct {
                s: Self,
                pub fn body(o: @This(), b2: *B, j: V) void {
                    const xy = partXy(b2, n, o.s.x0, o.s.y0, j);
                    const p = if (inter_pred)
                        interPred(b2, true, b2.param(P_REF_Y), b2.param(P_YS), xy[0], xy[1], o.s.mvr, o.s.mvc)
                    else
                        intra4(b2, b2.param(P_REC_Y), b2.param(P_YS), o.s.x0, o.s.y0, xy[0], xy[1], o.s.m, o.s.dc);
                    store4(b2, b2.param(P_REC_Y), b2.param(P_YS), xy[0], xy[1], p);
                }
            };
        }
        // an inter block: its prediction, then the size of its transforms
        // (P9_INTER_TX: 1 8x8, 2 the block's, 3 libvpx's real-time rule:
        // the block's where the residual's mean is most of it (sse > 4
        // var), else 8x8)
        const Stats = struct {
            s: Self,
            sum: B.Var,
            sse: B.Var,
            pub fn body(o: @This(), b2: *B, r: V) void {
                const at = b2.mad(b2.add(o.s.y0, r), b2.param(P_YS), o.s.x0);
                var sum = b2.get(o.sum);
                var sse = b2.get(o.sse);
                for (0..n) |k| {
                    const d = b2.sub(px8(b2, b2.add(b2.param(P_SRC_Y), b2.add(at, b2.c(@intCast(k))))), px8(b2, b2.add(b2.param(P_REC_Y), b2.add(at, b2.c(@intCast(k))))));
                    sum = b2.add(sum, d);
                    sse = b2.mad(d, d, sse);
                }
                b2.put(o.sum, sum);
                b2.put(o.sse, sse);
            }
        };
        const InterPrep = struct {
            s: Self,
            pub fn then(o: @This(), bb: *B) void {
                bb.loop(bb.c(parts), PredT(true){ .s = o.s });
                const sum = bb.vr(bb.c(0));
                const sse = bb.vr(bb.c(0));
                bb.loop(bb.c(@intCast(n)), Stats{ .s = o.s, .sum = sum, .sse = sse });
                // (4 sum^2 / N > 3 sse, in 32 bits)
                const sh: i32 = if (n == 16) 4 else 2;
                const q = bb.sar(bb.get(sum), bb.c(sh));
                const flat = bb.gt(bb.mul(bb.mul(q, q), bb.c(if (n == 16) 4 else 1)), bb.mul(bb.get(sse), bb.c(3)));
                const mode = bb.param(P9_INTER_TX);
                const big = bb.por(bb.eq(mode, bb.c(2)), bb.pand(bb.eq(mode, bb.c(3)), flat));
                // (an 8x8 block's 8x8 is its own)
                bb.put(o.s.next, if (n == 16) bb.sel(big, bb.c(1), bb.c(2)) else bb.c(1));
            }
        };
        // an intra block: 4x4 transforms, each predicted from the last
        // ones' reconstruction; the block's prediction and its transform
        // instead where they cost no more
        const Part4 = struct {
            s: Self,
            acc: B.Var,
            pub fn body(o: @This(), b2: *B, j: V) void {
                const xy = partXy(b2, n, o.s.x0, o.s.y0, j);
                const dc4 = dcOf(b2, b2.param(P_REC_Y), b2.param(P_YS), xy[0], xy[1], 4);
                const p = intra4(b2, b2.param(P_REC_Y), b2.param(P_YS), xy[0], xy[1], xy[0], xy[1], o.s.m, dc4);
                store4(b2, b2.param(P_REC_Y), b2.param(P_YS), xy[0], xy[1], p);
                var t = o.s.tb;
                t.x = xy[0];
                t.y = xy[1];
                t.cx = b2.sub(xy[0], o.s.u.px);
                t.cy = b2.sub(xy[1], o.s.u.py);
                t.ttype = o.s.m;
                b2.put(o.acc, b2.add(b2.get(o.acc), tx4(b2, t, 16, Q_YDC, Q_YAC, false)));
            }
        };
        const Redo = struct {
            s: Self,
            pub fn then(o: @This(), b2: *B) void {
                b2.put(o.s.nz, b2.c(0));
                b2.put(o.s.txs, b2.c(if (n == 16) 2 else 1));
                b2.loop(b2.c(parts), PredT(false){ .s = o.s });
                b2.put(o.s.next, b2.c(1));
            }
        };
        const IntraPrep = struct {
            s: Self,
            pub fn then(o: @This(), bb: *B) void {
                const s = o.s;
                bb.put(s.txs, bb.c(0));
                var mbits = bb.param(P9_MCOST);
                inline for (1..4) |mm| mbits = bb.sel(bb.eq(s.m, bb.c(mm)), bb.param(P9_MCOST + mm), mbits);
                const acc = bb.vr(bb.sar(bb.mul(s.u.lambda, bb.add(mbits, bb.param(P9_TX4_COST))), bb.c(8)));
                bb.loop(bb.c(parts), Part4{ .s = s, .acc = acc });
                bb.when(bb.ge(bb.get(acc), s.intra_cost), Redo{ .s = s });
            }
        };
        // the block's own transform (an inter block's DCT, an intra
        // block's by its mode)
        const Big = struct {
            s: Self,
            ttype: V,
            pub fn then(o: @This(), bb: *B) void {
                var t = o.s.tb;
                t.ttype = o.ttype;
                txN(bb, t, n, 16, Q_YDC, Q_YAC);
            }
        };
        // a 16x16 inter block's four 8x8 transforms
        const Mid = struct {
            s: Self,
            const Quad = struct {
                s: Self,
                pub fn body(o: @This(), b3: *B, j: V) void {
                    var t = o.s.tb;
                    t.x = b3.add(o.s.x0, b3.shl(b3.band(j, b3.c(1)), b3.c(3)));
                    t.y = b3.add(o.s.y0, b3.shl(b3.shr(j, b3.c(1)), b3.c(3)));
                    t.cx = b3.sub(t.x, o.s.u.px);
                    t.cy = b3.sub(t.y, o.s.u.py);
                    txN(b3, t, 8, 16, Q_YDC, Q_YAC);
                }
            };
            pub fn then(o: @This(), b2: *B) void {
                b2.put(o.s.txs, b2.c(1));
                b2.loop(b2.c(4), Quad{ .s = o.s });
            }
        };
    };
    // (ifs one after another, none with an else: an if's two sides with
    // divergent regions inside would share convergence barriers on sm_120)
    const next = b.vr(b.c(0));
    const rec = Rec{ .u = u, .x0 = x0, .y0 = y0, .m = m, .dc = dc, .intra_cost = intra_cost, .mvr = b.get(mvr), .mvc = b.get(mvc), .tb = tb, .txs = txs, .nz = nz, .next = next };
    b.when(is_inter, Rec.InterPrep{ .s = rec });
    b.when(b.pnot(is_inter), Rec.IntraPrep{ .s = rec });
    b.when(b.eq(b.get(next), b.c(1)), Rec.Big{ .s = rec, .ttype = b.sel(is_inter, b.c(0), m) });
    if (n == 16) b.when(b.eq(b.get(next), b.c(2)), Rec.Mid{ .s = rec });

    // the cells' records
    const ymode = b.sel(b.eq(m, b.c(3)), b.c(9), m);
    const kind: i32 = if (n == 16) 2 else 1;
    const cells: i32 = if (n == 16) 4 else 1;
    const W = struct {
        u: U,
        cell: V,
        inter: V,
        ymode: V,
        tx: V,
        mvr: V,
        mvc: V,
        nz: V,
        pub fn body(s: @This(), bb: *B, k: V) void {
            const kk = bb.add(s.cell, k);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_KIND), bb.c(kind));
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_INTER), s.inter);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_YMODE), s.ymode);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_TX), s.tx);
            bb.st(.i16, INFO, cellAt(bb, s.u, kk, C_MVR), s.mvr);
            bb.st(.i16, INFO, cellAt(bb, s.u, kk, C_MVC), s.mvc);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_NZY), bit(bb, bb.ne(s.nz, bb.c(0))));
        }
    };
    b.loop(b.c(cells), W{ .u = u, .cell = cell, .inter = b.get(inter), .ymode = ymode, .tx = b.get(txs), .mvr = b.get(mvr), .mvc = b.get(mvc), .nz = b.get(nz) });
}

// ── chroma, the skip flags, the loop filter's edges ─────────────────────────

/// The chroma of a wavefront's 16x16 blocks (after their luma).
pub fn chroma16(b: anytype) void {
    chromaKernel(b, 16);
}

/// The chroma of a wavefront's units of 8x8 blocks.
pub fn chroma8(b: anytype) void {
    chromaKernel(b, 8);
}

fn chromaKernel(b: anytype, comptime n: u32) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            chromaUnit(bb, n);
        }
    };
    b.when(b.lt(b.index(), b.param(P_COUNT)), T{});
}

fn chromaUnit(b: anytype, comptime n: u32) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const xy = waveUnit(b);
    const u = unitOf(b, xy[0], xy[1]);
    const U = Unit(B);
    const kind0 = b.ld(.u8, INFO, cellAt(b, u, b.c(0), C_KIND));
    const Full = struct {
        u: U,
        pub fn then(s: @This(), bb: *B) void {
            chromaBlock(bb, s.u, 16, s.u.px, s.u.py, bb.c(0));
        }
        const Cell = struct {
            u: U,
            const In = struct {
                u: U,
                k: V,
                pub fn then(t: @This(), b2: *B) void {
                    const x0 = b2.add(t.u.px, b2.shl(b2.band(t.k, b2.c(1)), b2.c(3)));
                    const y0 = b2.add(t.u.py, b2.shl(b2.shr(t.k, b2.c(1)), b2.c(3)));
                    chromaBlock(b2, t.u, 8, x0, y0, t.k);
                }
            };
            pub fn body(s: @This(), bb: *B, k: V) void {
                bb.when(bb.ne(bb.ld(.u8, INFO, cellAt(bb, s.u, k, C_KIND)), bb.c(0)), In{ .u = s.u, .k = k });
            }
        };
        pub fn otherwise(s: @This(), bb: *B) void {
            bb.loop(bb.c(4), Cell{ .u = s.u });
        }
    };
    const Edge = struct {
        f: Full,
        pub fn then(s: @This(), bb: *B) void {
            s.f.otherwise(bb);
        }
    };
    if (n == 16) b.when(b.eq(kind0, b.c(2)), Full{ .u = u }) else b.when(b.ne(kind0, b.c(2)), Edge{ .f = .{ .u = u } });
}

fn chromaBlock(b: anytype, u: anytype, comptime n: u32, x0: anytype, y0: anytype, cell: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const U = @TypeOf(u);
    const cn = n / 2;
    const parts: i32 = @intCast((cn / 4) * (cn / 4));
    const cx0 = b.shr(x0, b.c(1));
    const cy0 = b.shr(y0, b.c(1));
    const inter = b.ne(b.ld(.u8, INFO, cellAt(b, u, cell, C_INTER)), b.c(0));
    const txy_coded = b.ld(.u8, INFO, cellAt(b, u, cell, C_TX));
    const mvr = b.ld(.i16, INFO, cellAt(b, u, cell, C_MVR));
    const mvc = b.ld(.i16, INFO, cellAt(b, u, cell, C_MVC));
    // the chroma transform: 8x8 for a 16x16 block of 8x8 or 16x16
    // transforms (uv_txsize_lookup)
    const tx8_coded = if (n == 16) b.ge(txy_coded, b.c(1)) else b.pc(false);
    // an intra block's chroma mode by SATD over both planes (a loop of
    // the planes: U, then V)
    var accs: [4]B.Var = undefined;
    for (&accs) |*a| a.* = b.vr(b.c(0));
    const Modes = struct {
        cx0: V,
        cy0: V,
        accs: [4]B.Var,
        const PlaneCost = struct {
            cx0: V,
            cy0: V,
            accs: [4]B.Var,
            pub fn body(s: @This(), b2: *B, p: V) void {
                const first = b2.eq(p, b2.c(0));
                const rec = b2.sel(first, b2.param(P_REC_U), b2.param(P_REC_V));
                const src = b2.sel(first, b2.param(P_SRC_U), b2.param(P_SRC_V));
                const dc = dcOf(b2, rec, b2.param(P_CS), s.cx0, s.cy0, cn);
                inline for (0..4) |m| {
                    const Cost = struct {
                        cx0: V,
                        cy0: V,
                        rec: V,
                        src: V,
                        dc: V,
                        acc: B.Var,
                        pub fn body(o: @This(), b3: *B, j: V) void {
                            const xy = partXy(b3, cn, o.cx0, o.cy0, j);
                            const pr = intra4(b3, o.rec, b3.param(P_CS), o.cx0, o.cy0, xy[0], xy[1], b3.c(m), o.dc);
                            const sv = block4(b3, o.src, b3.param(P_CS), xy[0], xy[1]);
                            b3.put(o.acc, b3.add(b3.get(o.acc), k8.satd(b3, diff16(b3, sv, pr))));
                        }
                    };
                    b2.loop(b2.c(parts), Cost{ .cx0 = s.cx0, .cy0 = s.cy0, .rec = rec, .src = src, .dc = dc, .acc = s.accs[m] });
                }
            }
        };
        pub fn then(s: @This(), bb: *B) void {
            bb.loop(bb.c(2), PlaneCost{ .cx0 = s.cx0, .cy0 = s.cy0, .accs = s.accs });
        }
    };
    b.when(b.pnot(inter), Modes{ .cx0 = cx0, .cy0 = cy0, .accs = accs });
    const best = b.vr(b.c(0x7fff_ffff));
    const best_m = b.vr(b.c(0));
    inline for (0..4) |mm| {
        const cost = b.add(b.get(accs[mm]), b.sar(b.mul(u.lambda, b.param(P9_UVCOST + mm)), b.c(8)));
        const better = b.lt(cost, b.get(best));
        b.put(best, b.sel(better, cost, b.get(best)));
        b.put(best_m, b.sel(better, b.c(mm), b.get(best_m)));
    }
    const m = b.get(best_m);
    const nz = b.vr(b.c(0));
    const Pl = struct {
        const Self = @This();
        tb: Tb(B),
        ref: V,
        inter: B.P,
        m: V,
        dc: V,
        mvr: V,
        mvc: V,
        cx0: V,
        cy0: V,
        // the whole chroma block predicted, one 8x8 transform
        pub fn then(s: @This(), bb: *B) void {
            const Pred = struct {
                s: Self,
                pub fn body(o: @This(), b2: *B, j: V) void {
                    const xy = partXy(b2, cn, o.s.cx0, o.s.cy0, j);
                    const IP = struct {
                        s: Self,
                        x: V,
                        y: V,
                        pub fn then(q: @This(), b3: *B) void {
                            store4(b3, q.s.tb.rec, q.s.tb.stride, q.x, q.y, interPred(b3, false, q.s.ref, q.s.tb.stride, q.x, q.y, q.s.mvr, q.s.mvc));
                        }
                        pub fn otherwise(q: @This(), b3: *B) void {
                            store4(b3, q.s.tb.rec, q.s.tb.stride, q.x, q.y, intra4(b3, q.s.tb.rec, q.s.tb.stride, q.s.cx0, q.s.cy0, q.x, q.y, q.s.m, q.s.dc));
                        }
                    };
                    b2.whenElse(o.s.inter, IP{ .s = o.s, .x = xy[0], .y = xy[1] });
                }
            };
            bb.loop(bb.c(parts), Pred{ .s = s });
            if (cn == 8) txN(bb, s.tb, 8, 8, Q_UVDC, Q_UVAC);
        }
        // 4x4 transforms: an intra one predicted from the last ones'
        // reconstruction
        pub fn otherwise(s: @This(), bb: *B) void {
            const Part = struct {
                s: Self,
                pub fn body(o: @This(), b2: *B, j: V) void {
                    const xy = partXy(b2, cn, o.s.cx0, o.s.cy0, j);
                    const IP = struct {
                        s: Self,
                        x: V,
                        y: V,
                        pub fn then(q: @This(), b3: *B) void {
                            store4(b3, q.s.tb.rec, q.s.tb.stride, q.x, q.y, interPred(b3, false, q.s.ref, q.s.tb.stride, q.x, q.y, q.s.mvr, q.s.mvc));
                        }
                        pub fn otherwise(q: @This(), b3: *B) void {
                            const dc4 = dcOf(b3, q.s.tb.rec, q.s.tb.stride, q.x, q.y, 4);
                            store4(b3, q.s.tb.rec, q.s.tb.stride, q.x, q.y, intra4(b3, q.s.tb.rec, q.s.tb.stride, q.x, q.y, q.x, q.y, q.s.m, dc4));
                        }
                    };
                    b2.whenElse(o.s.inter, IP{ .s = o.s, .x = xy[0], .y = xy[1] });
                    var t = o.s.tb;
                    t.x = xy[0];
                    t.y = xy[1];
                    t.cx = b2.add(o.s.tb.cx, b2.sub(xy[0], o.s.cx0));
                    t.cy = b2.add(o.s.tb.cy, b2.sub(xy[1], o.s.cy0));
                    _ = tx4(b2, t, 8, Q_UVDC, Q_UVAC, true);
                }
            };
            bb.loop(bb.c(parts), Part{ .s = s });
        }
    };
    // each plane (U, then V): its prediction, transforms, reconstruction
    // (the loop inside the transform size's branch: a branch inside a
    // uniform loop diverges on sm_120)
    const Planes = struct {
        const PSelf = @This();
        u: U,
        inter: B.P,
        tx8: B.P,
        m: V,
        mvr: V,
        mvc: V,
        cx0: V,
        cy0: V,
        nz: B.Var,
        fn pl(s: @This(), bb: *B, p: V) Pl {
            const first = bb.eq(p, bb.c(0));
            const rec = bb.sel(first, bb.param(P_REC_U), bb.param(P_REC_V));
            const tb = Tb(B){
                .rec = rec,
                .src = bb.sel(first, bb.param(P_SRC_U), bb.param(P_SRC_V)),
                .stride = bb.param(P_CS),
                .x = s.cx0,
                .y = s.cy0,
                .coef = bb.add(s.u.rec, bb.sel(first, bb.c(U_U), bb.c(U_V))),
                .cx = bb.sub(s.cx0, bb.shr(s.u.px, bb.c(1))),
                .cy = bb.sub(s.cy0, bb.shr(s.u.py, bb.c(1))),
                .ttype = bb.c(0),
                .scr = s.u.scr,
                .nz = s.nz,
            };
            const dc = dcOf(bb, rec, bb.param(P_CS), s.cx0, s.cy0, cn);
            const ref = bb.sel(first, bb.param(P_REF_U), bb.param(P_REF_V));
            return .{ .tb = tb, .ref = ref, .inter = s.inter, .m = s.m, .dc = dc, .mvr = s.mvr, .mvc = s.mvc, .cx0 = s.cx0, .cy0 = s.cy0 };
        }
        const Big = struct {
            s: PSelf,
            pub fn body(o: @This(), bb: *B, p: V) void {
                o.s.pl(bb, p).then(bb);
            }
        };
        const Small = struct {
            s: PSelf,
            pub fn body(o: @This(), bb: *B, p: V) void {
                o.s.pl(bb, p).otherwise(bb);
            }
        };
        pub fn then(s: @This(), bb: *B) void {
            bb.loop(bb.c(2), Big{ .s = s });
        }
        pub fn otherwise(s: @This(), bb: *B) void {
            bb.loop(bb.c(2), Small{ .s = s });
        }
    };
    // (two ifs: see lumaBlock's)
    const planes = Planes{ .u = u, .inter = inter, .tx8 = tx8_coded, .m = m, .mvr = mvr, .mvc = mvc, .cx0 = cx0, .cy0 = cy0, .nz = nz };
    b.when(tx8_coded, Then(Planes){ .s = planes });
    b.when(b.pnot(tx8_coded), Else(Planes){ .s = planes });

    // the block's skip flag, the cells' loop filter edges
    const nzy = b.ld(.u8, INFO, cellAt(b, u, cell, C_NZY));
    const skip = b.pand(b.eq(nzy, b.c(0)), b.eq(b.get(nz), b.c(0)));
    const level = b.sel(inter, b.param(P9_LF_INTER), b.param(P9_LF_INTRA));
    const txe = b.pnot(b.pand(skip, inter));
    // (a skipped inter block's transform size is its largest, as the
    // decoder takes it: what its edges are filtered as)
    const txy = b.sel(txe, txy_coded, b.c(if (n == 16) 2 else 1));
    const tx8 = if (n == 16) b.ge(txy, b.c(1)) else b.pc(false);
    const has = b.gt(level, b.c(0));
    const bmi_r = b.shr(y0, b.c(3));
    const bmi_c = b.shr(x0, b.c(3));
    const cells: i32 = if (n == 16) 4 else 1;
    const LF = struct {
        u: U,
        cell: V,
        skip: B.P,
        txe: B.P,
        has: B.P,
        level: V,
        txy: V,
        bmi_r: V,
        bmi_c: V,
        pub fn body(s: @This(), bb: *B, k: V) void {
            const ir = if (n == 16) bb.shr(k, bb.c(1)) else bb.c(0);
            const ic = if (n == 16) bb.band(k, bb.c(1)) else bb.c(0);
            const r = bb.add(s.bmi_r, ir);
            const c = bb.add(s.bmi_c, ic);
            const tx_edges = bb.pand(s.txe, bb.lt(s.txy, bb.c(2)));
            const kind = bb.add(s.txy, bb.c(1));
            var kl = bb.sel(bb.por(bb.eq(ic, bb.c(0)), tx_edges), kind, bb.c(0));
            kl = bb.sel(bb.pand(bb.eq(kl, bb.c(1)), bb.eq(bb.band(c, bb.c(3)), bb.c(0))), bb.c(2), kl);
            kl = bb.sel(bb.eq(c, bb.c(0)), bb.c(0), kl);
            var kt = bb.sel(bb.por(bb.eq(ir, bb.c(0)), tx_edges), kind, bb.c(0));
            kt = bb.sel(bb.pand(bb.eq(kt, bb.c(1)), bb.eq(bb.band(r, bb.c(3)), bb.c(0))), bb.c(2), kt);
            kt = bb.sel(bb.eq(r, bb.c(0)), bb.c(0), kt);
            const in4 = bit(bb, bb.pand(s.txe, bb.eq(s.txy, bb.c(0))));
            const flags = bb.sel(s.has, bb.bor(bb.bor(kl, bb.shl(kt, bb.c(2))), bb.shl(in4, bb.c(4))), bb.c(0));
            const kk = bb.add(s.cell, k);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_SKIP), bit(bb, s.skip));
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_TX), s.txy);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_LEVEL), s.level);
            bb.st(.u8, INFO, cellAt(bb, s.u, kk, C_LFY), flags);
        }
    };
    b.loop(b.c(cells), LF{ .u = u, .cell = cell, .skip = skip, .txe = txe, .has = has, .level = level, .txy = txy, .bmi_r = bmi_r, .bmi_c = bmi_c });
    // the unit's chroma cell: its top-left block's
    const UV = struct {
        u: U,
        txe: B.P,
        has: B.P,
        level: V,
        uvk: V,
        r: V,
        c: V,
        m: V,
        inter: B.P,
        pub fn then(s: @This(), bb: *B) void {
            var kl = s.uvk;
            kl = bb.sel(bb.pand(bb.eq(kl, bb.c(1)), bb.eq(bb.band(s.c, bb.c(7)), bb.c(0))), bb.c(2), kl);
            kl = bb.sel(bb.eq(s.c, bb.c(0)), bb.c(0), kl);
            var kt = s.uvk;
            kt = bb.sel(bb.pand(bb.eq(kt, bb.c(1)), bb.eq(bb.band(s.r, bb.c(7)), bb.c(0))), bb.c(2), kt);
            kt = bb.sel(bb.eq(s.r, bb.c(0)), bb.c(0), kt);
            const ib = bb.pand(bb.pand(bb.eq(s.uvk, bb.c(1)), s.txe), bb.lt(bb.add(s.c, bb.c(1)), bb.param(P9_MIC)));
            const iv = bit(bb, ib);
            const ih = bit(bb, bb.pand(ib, bb.lt(bb.add(s.r, bb.c(1)), bb.param(P9_MIR))));
            const flags = bb.sel(s.has, bb.bor(bb.bor(kl, bb.shl(kt, bb.c(2))), bb.bor(bb.shl(iv, bb.c(4)), bb.shl(ih, bb.c(5)))), bb.c(0));
            bb.st(.u8, INFO, cellAt(bb, s.u, bb.c(0), C_LFUV), flags);
            bb.st(.u8, INFO, cellAt(bb, s.u, bb.c(0), C_LEVELUV), s.level);
        }
    };
    const uvk = b.sel(tx8, b.c(2), b.c(1));
    b.when(b.eq(cell, b.c(0)), UV{ .u = u, .txe = txe, .has = has, .level = level, .uvk = uvk, .r = bmi_r, .c = bmi_c, .m = m, .inter = inter });
    // the chroma mode (VP9's numbers), for every cell of the block
    const uvmode = b.sel(b.eq(m, b.c(3)), b.c(9), m);
    const M = struct {
        u: U,
        cell: V,
        v: V,
        pub fn body(s: @This(), bb: *B, k: V) void {
            bb.st(.u8, INFO, cellAt(bb, s.u, bb.add(s.cell, k), C_UVMODE), s.v);
        }
    };
    b.loop(b.c(cells), M{ .u = u, .cell = cell, .v = b.sel(inter, b.c(0), uvmode) });
}

// ── the loop filter ─────────────────────────────────────────────────────────

fn sc(b: anytype, x: anytype) @TypeOf(b.c(0)) {
    return dsl.clamp(b, x, b.c(-128), b.c(127));
}

inline fn rp2(b: anytype, x: anytype, comptime n: u5) @TypeOf(b.c(0)) {
    return b.sar(b.add(x, b.c(@as(i32, 1) << (n - 1))), b.c(n));
}

/// One position of an edge: q0 at `q0`, the taps `across` apart; `kind` 1
/// (filter4), 2 (filter8), 3 (filter16); thresholds of `level`
/// (vpx_dsp/loopfilter.c, its masks).
fn lfPos(b: anytype, qat: anytype, across: anytype, kind: anytype, level: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const sharp = b.param(P9_SHARP);
    var lim = b.sar(level, b.add(bit(b, b.gt(sharp, b.c(0))), bit(b, b.gt(sharp, b.c(4)))));
    lim = b.sel(b.gt(sharp, b.c(0)), b.min(lim, b.sub(b.c(9), sharp)), lim);
    lim = b.max(lim, b.c(1));
    const mblim = b.add(b.shl(b.add(level, b.c(2)), b.c(1)), lim);
    const hev_th = b.sar(level, b.c(4));
    const Ctx = struct { q0: V, across: V, kind: V, lim: V, mblim: V, hev: V };
    const ctx = Ctx{ .q0 = qat, .across = across, .kind = kind, .lim = lim, .mblim = mblim, .hev = hev_th };
    const W = struct {
        c: Ctx,
        // filter16 (with filter8 and filter4 under it)
        pub fn then(s: @This(), bb: *B) void {
            var at: [16]V = undefined;
            var a: [16]V = undefined; // p7 .. p0 q0 .. q7
            for (0..16) |t| {
                at[t] = bb.add(s.c.q0, bb.mul(s.c.across, bb.c(@as(i32, @intCast(t)) - 8)));
                a[t] = px8(bb, at[t]);
            }
            const r = core(bb, a[4..12].*, s.c);
            // flat2: p7..p4, q4..q7 within 1 of p0, q0
            var f2 = r.flat;
            for ([_]usize{ 0, 1, 2, 3 }) |t| f2 = bb.pand(f2, bb.le(bb.abs(bb.sub(a[t], a[7])), bb.c(1)));
            for ([_]usize{ 12, 13, 14, 15 }) |t| f2 = bb.pand(f2, bb.le(bb.abs(bb.sub(a[t], a[8])), bb.c(1)));
            const use16 = bb.pand(f2, r.mask);
            // the 16-tap outputs p6 .. q6 (positions 1 .. 14)
            var o16: [16]V = undefined;
            for (1..15) |i| {
                // the window: 15 taps around position i, ends repeated, i doubled
                var sum = bb.c(8);
                var w: i32 = -7;
                while (w <= 7) : (w += 1) {
                    const pos = std.math.clamp(@as(i32, @intCast(i)) + w, 0, 15);
                    sum = bb.add(sum, a[@intCast(pos)]);
                }
                sum = bb.add(sum, a[i]);
                o16[i] = bb.sar(sum, bb.c(4));
            }
            for (1..15) |i| {
                const v = if (i >= 4 and i <= 11) bb.sel(use16, o16[i], r.out[i - 4]) else bb.sel(use16, o16[i], a[i]);
                bb.st(.u8, MEM, at[i], v);
            }
        }
        pub fn otherwise(s: @This(), bb: *B) void {
            var at: [8]V = undefined;
            var a: [8]V = undefined;
            for (0..8) |t| {
                at[t] = bb.add(s.c.q0, bb.mul(s.c.across, bb.c(@as(i32, @intCast(t)) - 4)));
                a[t] = px8(bb, at[t]);
            }
            const r = core(bb, a, s.c);
            for (1..7) |i| bb.st(.u8, MEM, at[i], r.out[i]);
        }
        const Core = struct { out: [8]V, flat: B.P, mask: B.P };
        /// filter8 / filter4 on p3..q3 (kind 1: filter4 only)
        fn core(bb: *B, a: [8]V, c: Ctx) Core {
            var bad = bb.pc(false);
            for (0..3) |t| bad = bb.por(bad, bb.gt(bb.abs(bb.sub(a[t], a[t + 1])), c.lim));
            for (4..7) |t| bad = bb.por(bad, bb.gt(bb.abs(bb.sub(a[t], a[t + 1])), c.lim));
            bad = bb.por(bad, bb.gt(bb.add(bb.shl(bb.abs(bb.sub(a[3], a[4])), bb.c(1)), bb.shr(bb.abs(bb.sub(a[2], a[5])), bb.c(1))), c.mblim));
            const mask = bb.pnot(bad);
            var flat = bb.pc(true);
            for ([_]usize{ 0, 1, 2 }) |t| flat = bb.pand(flat, bb.le(bb.abs(bb.sub(a[t], a[3])), bb.c(1)));
            for ([_]usize{ 5, 6, 7 }) |t| flat = bb.pand(flat, bb.le(bb.abs(bb.sub(a[t], a[4])), bb.c(1)));
            const hev = bb.por(bb.gt(bb.abs(bb.sub(a[2], a[3])), c.hev), bb.gt(bb.abs(bb.sub(a[5], a[4])), c.hev));
            // filter4
            const ps1 = bb.sub(a[2], bb.c(128));
            const ps0 = bb.sub(a[3], bb.c(128));
            const qs0 = bb.sub(a[4], bb.c(128));
            const qs1 = bb.sub(a[5], bb.c(128));
            var f = bb.sel(hev, sc(bb, bb.sub(ps1, qs1)), bb.c(0));
            f = bb.sel(mask, sc(bb, bb.add(f, bb.mul(bb.c(3), bb.sub(qs0, ps0)))), bb.c(0));
            const f1 = bb.sar(sc(bb, bb.add(f, bb.c(4))), bb.c(3));
            const f2 = bb.sar(sc(bb, bb.add(f, bb.c(3))), bb.c(3));
            const o = bb.sel(hev, bb.c(0), bb.sar(bb.add(f1, bb.c(1)), bb.c(1)));
            var out4: [8]V = a;
            out4[4] = bb.add(sc(bb, bb.sub(qs0, f1)), bb.c(128));
            out4[3] = bb.add(sc(bb, bb.add(ps0, f2)), bb.c(128));
            out4[5] = bb.add(sc(bb, bb.sub(qs1, o)), bb.c(128));
            out4[2] = bb.add(sc(bb, bb.add(ps1, o)), bb.c(128));
            // filter8 (kind 2 and 3)
            const p3 = a[0];
            const p2 = a[1];
            const p1 = a[2];
            const p0 = a[3];
            const q0 = a[4];
            const q1 = a[5];
            const q2 = a[6];
            const q3 = a[7];
            var out8: [8]V = a;
            out8[1] = rp2(bb, bb.add(bb.add(bb.mul(p3, bb.c(3)), bb.shl(p2, bb.c(1))), bb.add(bb.add(p1, p0), q0)), 3);
            out8[2] = rp2(bb, bb.add(bb.add(bb.shl(p3, bb.c(1)), p2), bb.add(bb.add(bb.shl(p1, bb.c(1)), p0), bb.add(q0, q1))), 3);
            out8[3] = rp2(bb, bb.add(bb.add(bb.add(p3, p2), bb.add(p1, bb.shl(p0, bb.c(1)))), bb.add(bb.add(q0, q1), q2)), 3);
            out8[4] = rp2(bb, bb.add(bb.add(bb.add(p2, p1), bb.add(p0, bb.shl(q0, bb.c(1)))), bb.add(bb.add(q1, q2), q3)), 3);
            out8[5] = rp2(bb, bb.add(bb.add(bb.add(p1, p0), bb.add(q0, bb.shl(q1, bb.c(1)))), bb.add(q2, bb.shl(q3, bb.c(1)))), 3);
            out8[6] = rp2(bb, bb.add(bb.add(bb.add(p0, q0), bb.add(q1, bb.shl(q2, bb.c(1)))), bb.mul(q3, bb.c(3))), 3);
            const use8 = bb.pand(bb.pand(flat, mask), bb.gt(c.kind, bb.c(1)));
            var out: [8]V = undefined;
            for (0..8) |i| out[i] = bb.sel(use8, out8[i], out4[i]);
            return .{ .out = out, .flat = flat, .mask = mask };
        }
    };
    b.whenElse(b.eq(kind, b.c(3)), W{ .c = ctx });
}

/// Which superblock of wavefront `wave` (x + 2y) an invocation's 128
/// belong to (64 luma, 32 U, 32 V), and its row or column.
fn waveSb(b: anytype) [4]@TypeOf(b.c(0)) {
    const wave = b.param(P_WAVE);
    const symin = b.max(b.c(0), b.sar(b.add(b.sub(wave, b.param(P9_SBW)), b.c(2)), b.c(1)));
    const i = b.index();
    const sy = b.add(symin, b.shr(i, b.c(7)));
    const sx = b.sub(wave, b.shl(sy, b.c(1)));
    return .{ sx, sy, b.band(i, b.c(127)), b.c(0) };
}

fn cellRec(b: anytype, mi_r: anytype, mi_c: anytype) @TypeOf(b.c(0)) {
    const unit = b.mad(b.shr(mi_r, b.c(1)), b.param(P9_UW), b.shr(mi_c, b.c(1)));
    const k = b.add(b.shl(b.band(mi_r, b.c(1)), b.c(1)), b.band(mi_c, b.c(1)));
    return b.add(b.mul(unit, b.c(U_BYTES)), b.shl(k, b.c(4)));
}

/// The vertical edges of a superblock, a pixel row an invocation.
pub fn lfv(b: anytype) void {
    lfPass(b, true);
}

/// The horizontal edges of a superblock, a pixel column an invocation.
pub fn lfh(b: anytype) void {
    lfPass(b, false);
}

fn lfPass(b: anytype, comptime vertical: bool) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const T = struct {
        pub fn then(_: @This(), bb: *B) void {
            const w = waveSb(bb);
            const sx = w[0];
            const sy = w[1];
            const r = w[2];
            const is_y = bb.lt(r, bb.c(64));
            // (chroma: 0 .. 31 U's lines, 32 .. 63 V's)
            const line = bb.sel(is_y, r, bb.sub(r, bb.c(64)));
            const Y = struct {
                sx: V,
                sy: V,
                line: V,
                pub fn then(s: @This(), b2: *B) void {
                    lfLuma(b2, s.sx, s.sy, s.line, vertical);
                }
                pub fn otherwise(s: @This(), b2: *B) void {
                    lfChroma(b2, s.sx, s.sy, s.line, vertical);
                }
            };
            bb.whenElse(is_y, Y{ .sx = sx, .sy = sy, .line = line });
        }
    };
    b.when(b.lt(b.index(), b.param(P_COUNT)), T{});
}

fn lfLuma(b: anytype, sx: anytype, sy: anytype, line: anytype, comptime vertical: bool) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    // the line's cell row (vertical edges) or column (horizontal)
    const fixed_mi = b.add(b.shl(if (vertical) sy else sx, b.c(3)), b.shr(line, b.c(3)));
    const limit = b.param(if (vertical) P9_MIR else P9_MIC);
    const C = struct {
        const Self = @This();
        sx: V,
        sy: V,
        line: V,
        fixed_mi: V,
        pub fn then(s: @This(), bb: *B) void {
            const E = struct {
                s: Self,
                pub fn body(o: @This(), b2: *B, k: V) void {
                    const ss = o.s;
                    const mi = b2.add(b2.shl(if (vertical) ss.sx else ss.sy, b2.c(3)), k);
                    const In = struct {
                        mi: V,
                        ss: Self,
                        pub fn then(q: @This(), b3: *B) void {
                            const mi_r = if (vertical) q.ss.fixed_mi else q.mi;
                            const mi_c = if (vertical) q.mi else q.ss.fixed_mi;
                            const rec = cellRec(b3, mi_r, mi_c);
                            const flags = b3.ld(.u8, INFO, b3.add(rec, b3.c(C_LFY)));
                            const level = b3.ld(.u8, INFO, b3.add(rec, b3.c(C_LEVEL)));
                            const ys = b3.param(P_YS);
                            const px = if (vertical) b3.shl(mi_c, b3.c(3)) else b3.add(b3.shl(q.ss.sx, b3.c(6)), q.ss.line);
                            const py = if (vertical) b3.add(b3.shl(q.ss.sy, b3.c(6)), q.ss.line) else b3.shl(mi_r, b3.c(3));
                            const at = b3.add(b3.param(P_REC_Y), b3.mad(py, ys, px));
                            const across = if (vertical) b3.c(1) else ys;
                            const kind = b3.band(b3.shr(flags, b3.c(if (vertical) 0 else 2)), b3.c(3));
                            lfEdge(b3, at, across, kind, level);
                            const in4 = b3.ne(b3.band(flags, b3.c(16)), b3.c(0));
                            lfEdge(b3, b3.add(at, b3.shl(across, b3.c(2))), across, b3.sel(in4, b3.c(1), b3.c(0)), level);
                        }
                    };
                    b2.when(b2.lt(mi, b2.param(if (vertical) P9_MIC else P9_MIR)), In{ .mi = mi, .ss = ss });
                }
            };
            bb.loop(bb.c(8), E{ .s = s });
        }
    };
    b.when(b.lt(fixed_mi, limit), C{ .sx = sx, .sy = sy, .line = line, .fixed_mi = fixed_mi });
}

/// An edge where `kind` is nonzero.
fn lfEdge(b: anytype, at: anytype, across: anytype, kind: anytype, level: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const E = struct {
        at: V,
        across: V,
        kind: V,
        level: V,
        pub fn then(s: @This(), bb: *B) void {
            lfPos(bb, s.at, s.across, s.kind, s.level);
        }
    };
    b.when(b.gt(kind, b.c(0)), E{ .at = at, .across = across, .kind = kind, .level = level });
}

fn lfChroma(b: anytype, sx: anytype, sy: anytype, line: anytype, comptime vertical: bool) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const plane_u = b.lt(line, b.c(32));
    const l = b.band(line, b.c(31));
    // the line's chroma cell row (vertical edges) or column (horizontal),
    // and its first 8x8 grid row or column
    const fixed_mi = b.add(b.shl(if (vertical) sy else sx, b.c(3)), b.shl(b.shr(l, b.c(3)), b.c(1)));
    const limit = b.param(if (vertical) P9_MIR else P9_MIC);
    const C = struct {
        const Self = @This();
        sx: V,
        sy: V,
        l: V,
        fixed_mi: V,
        plane_u: B.P,
        pub fn then(s: @This(), bb: *B) void {
            const E = struct {
                s: Self,
                pub fn body(o: @This(), b2: *B, k: V) void {
                    const ss = o.s;
                    const mi = b2.add(b2.shl(if (vertical) ss.sx else ss.sy, b2.c(3)), b2.shl(k, b2.c(1)));
                    const In = struct {
                        mi: V,
                        k: V,
                        ss: Self,
                        pub fn then(q: @This(), b3: *B) void {
                            const mi_r = if (vertical) q.ss.fixed_mi else q.mi;
                            const mi_c = if (vertical) q.mi else q.ss.fixed_mi;
                            const rec = cellRec(b3, mi_r, mi_c);
                            const flags = b3.ld(.u8, INFO, b3.add(rec, b3.c(C_LFUV)));
                            const level = b3.ld(.u8, INFO, b3.add(rec, b3.c(C_LEVELUV)));
                            const cs = b3.param(P_CS);
                            const cx = if (vertical) b3.shl(b3.add(b3.shl(q.ss.sx, b3.c(2)), q.k), b3.c(3)) else b3.add(b3.shl(q.ss.sx, b3.c(5)), q.ss.l);
                            const cy = if (vertical) b3.add(b3.shl(q.ss.sy, b3.c(5)), q.ss.l) else b3.shl(b3.add(b3.shl(q.ss.sy, b3.c(2)), q.k), b3.c(3));
                            const base = b3.sel(q.ss.plane_u, b3.param(P_REC_U), b3.param(P_REC_V));
                            const at = b3.add(base, b3.mad(cy, cs, cx));
                            const across = if (vertical) b3.c(1) else cs;
                            const kind = b3.band(b3.shr(flags, b3.c(if (vertical) 0 else 2)), b3.c(3));
                            lfEdge(b3, at, across, kind, level);
                            const in4 = b3.ne(b3.band(flags, b3.c(if (vertical) 16 else 32)), b3.c(0));
                            lfEdge(b3, b3.add(at, b3.shl(across, b3.c(2))), across, b3.sel(in4, b3.c(1), b3.c(0)), level);
                        }
                    };
                    b2.when(b2.lt(mi, b2.param(if (vertical) P9_MIC else P9_MIR)), In{ .mi = mi, .k = k, .ss = ss });
                }
            };
            bb.loop(bb.c(4), E{ .s = s });
        }
    };
    b.when(b.lt(fixed_mi, limit), C{ .sx = sx, .sy = sy, .l = l, .fixed_mi = fixed_mi, .plane_u = plane_u });
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "vp9_kernels: the kernels build for the CPU" {
    const none = [_]u32{0} ** dsl.MAX_PARAMS;
    const bufs = [dsl.MAX_BUFS][]u8{ &.{}, &.{}, &.{}, &.{} };
    dsl.runCpu(motion, bufs, &none, 0);
    dsl.runCpu(luma16, bufs, &none, 0);
    dsl.runCpu(luma8, bufs, &none, 0);
    dsl.runCpu(chroma16, bufs, &none, 0);
    dsl.runCpu(chroma8, bufs, &none, 0);
    dsl.runCpu(lfv, bufs, &none, 0);
    dsl.runCpu(lfh, bufs, &none, 0);
}

test "vp9_kernels: libvpx's 1-D transforms invert (the forward ones, the decoder's inverse)" {
    var b = dsl.Cpu.init(.{ &.{}, &.{}, &.{}, &.{} }, &.{}, 0);
    inline for (.{ 4, 8, 16 }) |n| {
        var x: [n]i32 = undefined;
        for (0..n) |k| x[k] = @as(i32, @intCast((k * 53 + 11) % 97)) * 16 - 700;
        const pairs = .{ .{ tx.fdct4, tx.idct4, tx.fadst4, tx.iadst4 }, .{ tx.fdct8, tx.idct8, tx.fadst8, tx.iadst8 }, .{ tx.fdct16, tx.idct16, tx.fadst16, tx.iadst16 } };
        const p = pairs[switch (n) {
            4 => 0,
            8 => 1,
            else => 2,
        }];
        // forward then inverse: the input back, times n/2 (4: 1/2 more)
        // within a few units
        inline for (.{ .{ p[0], p[1] }, .{ p[2], p[3] } }) |f| {
            const y = f[1](&b, f[0](&b, x));
            for (0..n) |k| {
                const want = @divTrunc(x[k] * @as(i32, n), 2);
                try testing.expect(@abs(y[k] - want) <= @max(16, @abs(want) / 64));
            }
        }
    }
}
