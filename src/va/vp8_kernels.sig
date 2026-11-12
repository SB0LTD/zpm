//! @zpm/va vp8_kernels — the VP8 encoder's pixel work, written once over
//! vpx_dsl's backends (the CPU's, and KIR for the RTX):
//!
//!   load     the input picture (NV12, block linear: the surface as the
//!            decoder or the app left it) into the source planes (I420,
//!            pitch linear, padded to whole macroblocks by repeating the
//!            last column and row); one invocation 4 bytes of a plane's row
//!   motion   motion search, every macroblock at once (inter frames): a
//!            step-2 search of the window on subsampled SADs, the full-pel
//!            neighbours of its best, the zero vector, then the half and
//!            quarter pels around it through VP8's six-tap filter
//!   encode   a wavefront of macroblocks (x + 2y = wave: each needs its
//!            left, above, above-left and above-right neighbours done): the
//!            mode decision (16x16 intra modes, B_PRED's ten subblock modes,
//!            the motion search's vector, by SATD and the modes' bits), the
//!            transform (VP8's DCT, the Y2 Walsh-Hadamard), quantization,
//!            and the reconstruction exactly as the decoder makes it
//!            (prediction edges as libvpx's decoder sees them; the inverse
//!            transforms are RFC 6386's)
//!   filter   the loop filter (the normal one), a wavefront of macroblocks
//!            in the same order as the decoder's raster scan needs it, with
//!            the levels the frame header and its deltas give each one
//!
//! The CPU packs what `encode` leaves in the macroblock records (modes,
//! vectors, quantized coefficients) into the bitstream (enc_vp8.sig).
//!
//! Memory (binding MEM): planes of bytes, I420, the luma `P_YS` bytes a row,
//! the chroma `P_CS`; offsets are parameters. The records (binding INFO):
//! MB_BYTES each, raster order. The input picture: binding SURF.

const std = @import("std");
const dsl = @import("vpx_dsl.sig");

pub const MEM: u8 = 0;
pub const INFO: u8 = 1;
pub const SURF: u8 = 2;

// ── Parameters (u32 words) ──────────────────────────────────────────────────
pub const P_COUNT = 0; // invocations
pub const P_WAVE = 1;
pub const P_MBW = 2;
pub const P_MBH = 3;
pub const P_YS = 4;
pub const P_CS = 5;
pub const P_SRC_Y = 6;
pub const P_SRC_U = 7;
pub const P_SRC_V = 8;
pub const P_REC_Y = 9;
pub const P_REC_U = 10;
pub const P_REC_V = 11;
pub const P_REF_Y = 12;
pub const P_REF_U = 13;
pub const P_REF_V = 14;
pub const P_KEY = 15;
/// dequantization factors: Y1 DC, Y1 AC, Y2 DC, Y2 AC, UV DC, UV AC
pub const P_Q = 16;
/// their reciprocals (65536 / q, rounded up) and rounding offsets
pub const P_QI = 22;
pub const P_QR = 28;
/// the mode decision's weight of a bit, SATD units * 16
pub const P_LAMBDA = 34;
/// motion search: the window (full pels each way)
pub const P_RANGE = 35;
/// loop filter: levels for B_PRED, the other intra modes, inter with a
/// zero vector, inter with another; sharpness
pub const P_LF = 36;
pub const P_SHARP = 40;
/// load: the surface's planes (byte offsets in SURF), pitches, swizzles,
/// log2 of GOBs a block, the picture's size, the planes' aligned size
pub const P_S_LUMA = 41;
pub const P_S_CHROMA = 42;
pub const P_S_PITCH_L = 43;
pub const P_S_PITCH_C = 44;
pub const P_S_SWZ_L = 45;
pub const P_S_SWZ_C = 46;
pub const P_S_GOBS = 47;
pub const P_W = 48;
pub const P_H = 49;
pub const P_AW = 50;
pub const P_AH = 51;
pub const PARAMS = 52;

// ── The macroblock record (INFO) ────────────────────────────────────────────
pub const MB_BYTES = 1024;
/// 0..3 the 16x16 intra modes (DC, V, H, TM), 4 B_PRED, 5 inter (LAST)
pub const I_YMODE = 0;
pub const I_UVMODE = 1;
/// 1: every coefficient zero
pub const I_SKIP = 2;
pub const I_MVR = 4; // the macroblock's vector (1/8 pels, even), i16
pub const I_MVC = 6;
pub const I_BMODES = 8; // u8 x 16
pub const I_ME_MVR = 24; // the motion search's vector and cost
pub const I_ME_MVC = 26;
pub const I_ME_COST = 28;
/// i16 coefficients, 25 blocks of 16 in raster order: Y 0..15, U 16..19,
/// V 20..23, Y2 24
pub const I_COEF = 64;
/// u8: whether each block has a nonzero coefficient
pub const I_NZ = 864;

pub const MODE_INTER = 5;

pub const Q_Y1DC = 0;
pub const Q_Y1AC = 1;
pub const Q_Y2DC = 2;
pub const Q_Y2AC = 3;
pub const Q_UVDC = 4;
pub const Q_UVAC = 5;

/// The biggest level the encoder writes (cat 6 holds up to 2048 + 66).
pub const MAX_LEVEL = 2047;

fn Be(comptime Ptr: type) type {
    return @typeInfo(Ptr).pointer.child;
}

inline fn bit(b: anytype, p: anytype) @TypeOf(b.c(0)) {
    return b.sel(p, b.c(1), b.c(0));
}

// ── Transforms (RFC 6386; libvpx's encoder dct.c and decoder idctllm.c) ─────

/// The forward DCT of a 4x4 residual (row-major), libvpx's vp8_short_fdct4x4.
pub fn fdct(b: anytype, d: [16]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    var t: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const ip = d[i * 4 ..][0..4];
        const a1 = b.shl(b.add(ip[0], ip[3]), b.c(3));
        const b1 = b.shl(b.add(ip[1], ip[2]), b.c(3));
        const c1 = b.shl(b.sub(ip[1], ip[2]), b.c(3));
        const d1 = b.shl(b.sub(ip[0], ip[3]), b.c(3));
        t[i * 4 + 0] = b.add(a1, b1);
        t[i * 4 + 2] = b.sub(a1, b1);
        t[i * 4 + 1] = b.sar(b.add(b.mad(c1, b.c(2217), b.mul(d1, b.c(5352))), b.c(14500)), b.c(12));
        t[i * 4 + 3] = b.sar(b.add(b.sub(b.mul(d1, b.c(2217)), b.mul(c1, b.c(5352))), b.c(7500)), b.c(12));
    }
    var o: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const a1 = b.add(t[i], t[12 + i]);
        const b1 = b.add(t[4 + i], t[8 + i]);
        const c1 = b.sub(t[4 + i], t[8 + i]);
        const d1 = b.sub(t[i], t[12 + i]);
        o[i] = b.sar(b.add(b.add(a1, b1), b.c(7)), b.c(4));
        o[8 + i] = b.sar(b.add(b.sub(a1, b1), b.c(7)), b.c(4));
        o[4 + i] = b.add(b.sar(b.add(b.mad(c1, b.c(2217), b.mul(d1, b.c(5352))), b.c(12000)), b.c(16)), bit(b, b.ne(d1, b.c(0))));
        o[12 + i] = b.sar(b.add(b.sub(b.mul(d1, b.c(2217)), b.mul(c1, b.c(5352))), b.c(51000)), b.c(16));
    }
    return o;
}

/// The forward Walsh-Hadamard transform of the 16 luma DCs (raster order
/// of the blocks), libvpx's vp8_short_walsh4x4.
pub fn fwalsh(b: anytype, d: [16]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    var t: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const ip = d[i * 4 ..][0..4];
        const a1 = b.shl(b.add(ip[0], ip[2]), b.c(2));
        const d1 = b.shl(b.add(ip[1], ip[3]), b.c(2));
        const c1 = b.shl(b.sub(ip[1], ip[3]), b.c(2));
        const b1 = b.shl(b.sub(ip[0], ip[2]), b.c(2));
        t[i * 4 + 0] = b.add(b.add(a1, d1), bit(b, b.ne(a1, b.c(0))));
        t[i * 4 + 1] = b.add(b1, c1);
        t[i * 4 + 2] = b.sub(b1, c1);
        t[i * 4 + 3] = b.sub(a1, d1);
    }
    var o: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const a1 = b.add(t[i], t[8 + i]);
        const d1 = b.add(t[4 + i], t[12 + i]);
        const c1 = b.sub(t[4 + i], t[12 + i]);
        const b1 = b.sub(t[i], t[8 + i]);
        const outs = [4]@TypeOf(b.c(0)){ b.add(a1, d1), b.add(b1, c1), b.sub(b1, c1), b.sub(a1, d1) };
        for (outs, 0..) |x, k| {
            const y = b.add(x, bit(b, b.lt(x, b.c(0))));
            o[k * 4 + i] = b.sar(b.add(y, b.c(3)), b.c(3));
        }
    }
    return o;
}

/// The decoder's inverse DCT (vp8_short_idct4x4llm) of dequantized
/// coefficients: the residual.
pub fn idct(b: anytype, ip: [16]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    const S = 35468;
    const C = 20091;
    var t: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const a1 = b.add(ip[i], ip[8 + i]);
        const b1 = b.sub(ip[i], ip[8 + i]);
        var temp1 = b.sar(b.mul(ip[4 + i], b.c(S)), b.c(16));
        var temp2 = b.add(ip[12 + i], b.sar(b.mul(ip[12 + i], b.c(C)), b.c(16)));
        const c1 = b.sub(temp1, temp2);
        temp1 = b.add(ip[4 + i], b.sar(b.mul(ip[4 + i], b.c(C)), b.c(16)));
        temp2 = b.sar(b.mul(ip[12 + i], b.c(S)), b.c(16));
        const d1 = b.add(temp1, temp2);
        t[i] = b.add(a1, d1);
        t[12 + i] = b.sub(a1, d1);
        t[4 + i] = b.add(b1, c1);
        t[8 + i] = b.sub(b1, c1);
    }
    var o: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const r = t[i * 4 ..][0..4];
        const a1 = b.add(r[0], r[2]);
        const b1 = b.sub(r[0], r[2]);
        var temp1 = b.sar(b.mul(r[1], b.c(S)), b.c(16));
        var temp2 = b.add(r[3], b.sar(b.mul(r[3], b.c(C)), b.c(16)));
        const c1 = b.sub(temp1, temp2);
        temp1 = b.add(r[1], b.sar(b.mul(r[1], b.c(C)), b.c(16)));
        temp2 = b.sar(b.mul(r[3], b.c(S)), b.c(16));
        const d1 = b.add(temp1, temp2);
        o[i * 4 + 0] = b.sar(b.add(b.add(a1, d1), b.c(4)), b.c(3));
        o[i * 4 + 3] = b.sar(b.add(b.sub(a1, d1), b.c(4)), b.c(3));
        o[i * 4 + 1] = b.sar(b.add(b.add(b1, c1), b.c(4)), b.c(3));
        o[i * 4 + 2] = b.sar(b.add(b.sub(b1, c1), b.c(4)), b.c(3));
    }
    return o;
}

/// The decoder's inverse Walsh-Hadamard transform (vp8_short_inv_walsh4x4):
/// each luma block's DC.
pub fn iwalsh(b: anytype, ip: [16]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    var t: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const a1 = b.add(ip[i], ip[12 + i]);
        const b1 = b.add(ip[4 + i], ip[8 + i]);
        const c1 = b.sub(ip[4 + i], ip[8 + i]);
        const d1 = b.sub(ip[i], ip[12 + i]);
        t[i] = b.add(a1, b1);
        t[4 + i] = b.add(c1, d1);
        t[8 + i] = b.sub(a1, b1);
        t[12 + i] = b.sub(d1, c1);
    }
    var o: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const r = t[i * 4 ..][0..4];
        const a1 = b.add(r[0], r[3]);
        const b1 = b.add(r[1], r[2]);
        const c1 = b.sub(r[1], r[2]);
        const d1 = b.sub(r[0], r[3]);
        o[i * 4 + 0] = b.sar(b.add(b.add(a1, b1), b.c(3)), b.c(3));
        o[i * 4 + 1] = b.sar(b.add(b.add(c1, d1), b.c(3)), b.c(3));
        o[i * 4 + 2] = b.sar(b.add(b.sub(a1, b1), b.c(3)), b.c(3));
        o[i * 4 + 3] = b.sar(b.add(b.sub(d1, c1), b.c(3)), b.c(3));
    }
    return o;
}

/// A 4x4 residual's SATD: the Hadamard transform's absolute sum, halved.
pub fn satd(b: anytype, d: [16]@TypeOf(b.c(0))) @TypeOf(b.c(0)) {
    var t: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |i| {
        const r = d[i * 4 ..][0..4];
        const s0 = b.add(r[0], r[1]);
        const s1 = b.sub(r[0], r[1]);
        const s2 = b.add(r[2], r[3]);
        const s3 = b.sub(r[2], r[3]);
        t[i * 4 + 0] = b.add(s0, s2);
        t[i * 4 + 1] = b.add(s1, s3);
        t[i * 4 + 2] = b.sub(s0, s2);
        t[i * 4 + 3] = b.sub(s1, s3);
    }
    var sum = b.c(0);
    for (0..4) |i| {
        const s0 = b.add(t[i], t[4 + i]);
        const s1 = b.sub(t[i], t[4 + i]);
        const s2 = b.add(t[8 + i], t[12 + i]);
        const s3 = b.sub(t[8 + i], t[12 + i]);
        sum = b.add(sum, b.abs(b.add(s0, s2)));
        sum = b.add(sum, b.abs(b.add(s1, s3)));
        sum = b.add(sum, b.abs(b.sub(s0, s2)));
        sum = b.add(sum, b.abs(b.sub(s1, s3)));
    }
    return b.sar(sum, b.c(1));
}

/// A coefficient's level for quantizer `kind` (deadzone, by reciprocal).
pub fn quant(b: anytype, x: @TypeOf(b.c(0)), comptime kind: usize) @TypeOf(b.c(0)) {
    const a = b.abs(x);
    const l = b.min(b.sar(b.mul(b.add(a, b.param(P_QR + kind)), b.param(P_QI + kind)), b.c(16)), b.c(MAX_LEVEL));
    return b.sel(b.lt(x, b.c(0)), b.neg(l), l);
}

// ── Pixels ──────────────────────────────────────────────────────────────────

inline fn px8(b: anytype, off: anytype) @TypeOf(b.c(0)) {
    return b.ld(.u8, MEM, off);
}

/// A reference pixel (x, y) of a plane at `base` (`w` x `h`, `stride`),
/// coordinates clamped: the frame's edges repeated without end, as the
/// decoder's border extension has it for the vectors this encoder makes.
inline fn refPx(b: anytype, base: anytype, stride: anytype, w: anytype, h: anytype, x: anytype, y: anytype) @TypeOf(b.c(0)) {
    const cx = dsl.clamp(b, x, b.c(0), b.sub(w, b.c(1)));
    const cy = dsl.clamp(b, y, b.c(0), b.sub(h, b.c(1)));
    return px8(b, b.add(base, b.mad(cy, stride, cx)));
}

const FILTERS = [8][6]i32{
    .{ 0, 0, 128, 0, 0, 0 },     .{ 0, -6, 123, 12, -1, 0 }, .{ 2, -11, 108, 36, -8, 1 }, .{ 0, -9, 93, 50, -6, 0 },
    .{ 3, -16, 77, 77, -16, 3 }, .{ 0, -6, 50, 93, -9, 0 },  .{ 1, -8, 36, 108, -11, 2 }, .{ 0, -1, 12, 123, -6, 0 },
};

/// The six taps of sub-pel position `f` (0..7, a value): selects of the
/// table (no indexing of registers).
fn taps(b: anytype, f: @TypeOf(b.c(0))) [6]@TypeOf(b.c(0)) {
    var t: [6]@TypeOf(b.c(0)) = undefined;
    for (0..6) |k| {
        var v = b.c(FILTERS[0][k]);
        for (1..8) |p| {
            if (FILTERS[p][k] == FILTERS[0][k]) continue;
            v = b.sel(b.eq(f, b.c(@intCast(p))), b.c(FILTERS[p][k]), v);
        }
        t[k] = v;
    }
    return t;
}

fn filt6(b: anytype, t: [6]@TypeOf(b.c(0)), s: [6]@TypeOf(b.c(0))) @TypeOf(b.c(0)) {
    var acc = b.c(64);
    for (0..6) |k| acc = b.mad(s[k], t[k], acc);
    return dsl.clip8(b, b.sar(acc, b.c(7)));
}

/// The six-tap prediction of a 4x4 block whose top-left is (x, y) of the
/// reference plane plus a vector's full pels; `fx`, `fy` its eighths.
pub fn sixtap4x4(b: anytype, plane: anytype, stride: anytype, w: anytype, h: anytype, x: anytype, y: anytype, fx: anytype, fy: anytype) [16]@TypeOf(b.c(0)) {
    const V = @TypeOf(b.c(0));
    const th = taps(b, fx);
    const tv = taps(b, fy);
    // the first pass: 9 rows (y-2 .. y+6), 4 columns
    var first: [9][4]V = undefined;
    for (0..9) |r| {
        const yy = b.add(y, b.c(@as(i32, @intCast(r)) - 2));
        var row: [9]V = undefined;
        for (0..9) |c| row[c] = refPx(b, plane, stride, w, h, b.add(x, b.c(@as(i32, @intCast(c)) - 2)), yy);
        for (0..4) |c| first[r][c] = filt6(b, th, row[c..][0..6].*);
    }
    var out: [16]V = undefined;
    for (0..4) |r| {
        for (0..4) |c| {
            out[r * 4 + c] = filt6(b, tv, .{ first[r][c], first[r + 1][c], first[r + 2][c], first[r + 3][c], first[r + 4][c], first[r + 5][c] });
        }
    }
    return out;
}

/// 16 pixels of the 4x4 block at (x, y) of a plane (x a multiple of 4:
/// a word a row).
fn block4(b: anytype, base: anytype, stride: anytype, x: anytype, y: anytype) [16]@TypeOf(b.c(0)) {
    var s: [16]@TypeOf(b.c(0)) = undefined;
    const at = b.add(base, b.mad(y, stride, x));
    for (0..4) |r| {
        const w = b.ld(.i32, MEM, b.add(at, b.mul(b.c(@intCast(r)), stride)));
        for (0..4) |c| s[r * 4 + c] = b.band(b.shr(w, b.c(@intCast(8 * c))), b.c(255));
    }
    return s;
}

fn diff16(b: anytype, s: [16]@TypeOf(b.c(0)), p: [16]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    var d: [16]@TypeOf(b.c(0)) = undefined;
    for (0..16) |k| d[k] = b.sub(s[k], p[k]);
    return d;
}

// ── load ────────────────────────────────────────────────────────────────────

/// Where byte (x, y) of a block-linear plane is (tiling.sig's offsetOf):
/// blocks of 2^gobs GOBs (64 bytes x 8 rows), `swz` tiling.Swizzle's
/// number (0 Turing, 1 Blackwell 8-bit, 2 Blackwell 16-bit).
pub fn blAddress(b: anytype, pitch: anytype, gobs: anytype, swz: anytype, x: anytype, y: anytype) @TypeOf(b.c(0)) {
    const rows_log2 = b.add(gobs, b.c(3));
    const block = b.add(b.mul(b.shr(y, rows_log2), b.shr(pitch, b.c(6))), b.shr(x, b.c(6)));
    const gob = b.band(b.shr(y, b.c(3)), b.sub(b.shl(b.c(1), gobs), b.c(1)));
    const gx = b.band(x, b.c(63));
    const gy = b.band(y, b.c(7));
    // the three layouts' closed forms
    const x32 = b.shl(b.shr(gx, b.c(5)), b.c(8));
    const x16 = b.band(b.shr(gx, b.c(4)), b.c(1));
    const xlo = b.band(gx, b.c(15));
    const turing = b.add(b.add(x32, b.shl(b.shr(gy, b.c(2)), b.c(7))), b.add(b.add(b.shl(x16, b.c(6)), b.shl(b.band(gy, b.c(3)), b.c(4))), xlo));
    const bw16 = b.add(b.add(x32, b.shl(x16, b.c(7))), b.add(b.shl(gy, b.c(4)), xlo));
    const bw8 = b.add(b.add(b.shl(b.shr(gx, b.c(3)), b.c(6)), b.shl(gy, b.c(3))), b.band(gx, b.c(7)));
    const in_gob = b.sel(b.eq(swz, b.c(1)), bw8, b.sel(b.eq(swz, b.c(2)), bw16, turing));
    return b.add(b.add(b.shl(block, b.add(b.c(9), gobs)), b.shl(gob, b.c(9))), in_gob);
}

/// load's extra parameters: which plane (0 Y, 1 U, 2 V), log2 of the
/// invocations a row (the row's words, rounded up to a power of two)
pub const P_PLANE = 52;
pub const P_WSHIFT = 53;

/// The input picture into the source planes, one plane a dispatch: an
/// invocation a word (4 bytes) of a row; its index is row << P_WSHIFT |
/// word. Columns and rows past the picture repeat its last ones.
pub fn load(b: anytype) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            loadWord(bb);
        }
    };
    const i = b.index();
    const shift = b.param(P_WSHIFT);
    const plane = b.param(P_PLANE);
    const words = b.shr(b.param(P_AW), b.sel(b.eq(plane, b.c(0)), b.c(2), b.c(3)));
    const word = b.band(i, b.sub(b.shl(b.c(1), shift), b.c(1)));
    b.when(b.pand(b.lt(i, b.param(P_COUNT)), b.lt(word, words)), T{});
}

fn loadWord(b: anytype) void {
    const i = b.index();
    const shift = b.param(P_WSHIFT);
    const plane = b.param(P_PLANE);
    const is_y = b.eq(plane, b.c(0));
    const row = b.shr(i, shift);
    const word = b.band(i, b.sub(b.shl(b.c(1), shift), b.c(1)));
    const x0 = b.shl(word, b.c(2));
    const w = b.param(P_W);
    const h = b.param(P_H);
    const cwid = b.shr(b.add(w, b.c(1)), b.c(1));
    const chgt = b.shr(b.add(h, b.c(1)), b.c(1));
    const maxx = b.sub(b.sel(is_y, w, cwid), b.c(1));
    const sy = b.min(row, b.sub(b.sel(is_y, h, chgt), b.c(1)));
    const pitch = b.sel(is_y, b.param(P_S_PITCH_L), b.param(P_S_PITCH_C));
    const swz = b.sel(is_y, b.param(P_S_SWZ_L), b.param(P_S_SWZ_C));
    const base = b.sel(is_y, b.param(P_S_LUMA), b.param(P_S_CHROMA));
    const gobs = b.param(P_S_GOBS);
    // chroma: the U (even) or V (odd) byte of the pair
    const v_byte = b.sel(b.eq(plane, b.c(2)), b.c(1), b.c(0));
    var word_v = b.c(0);
    for (0..4) |q| {
        const sx = b.min(b.add(x0, b.c(@intCast(q))), maxx);
        const bx = b.sel(is_y, sx, b.add(b.shl(sx, b.c(1)), v_byte));
        const v = b.ld(.u8, SURF, b.add(base, blAddress(b, pitch, gobs, swz, bx, sy)));
        word_v = b.bor(word_v, b.shl(v, b.c(@intCast(8 * q))));
    }
    const dst_base = b.sel(is_y, b.param(P_SRC_Y), b.sel(b.eq(plane, b.c(1)), b.param(P_SRC_U), b.param(P_SRC_V)));
    const stride = b.sel(is_y, b.param(P_YS), b.param(P_CS));
    b.st(.i32, MEM, b.add(dst_base, b.mad(row, stride, x0)), word_v);
}

// ── motion ──────────────────────────────────────────────────────────────────

/// The bits a vector component of `d` quarter pels costs, roughly.
fn mvBits(b: anytype, d: anytype) @TypeOf(b.c(0)) {
    const a = b.abs(d);
    var n = b.c(1);
    inline for ([_]i32{ 0, 1, 3, 7, 15, 31, 63, 127, 255 }) |t| n = b.add(n, b.shl(bit(b, b.gt(a, b.c(t))), b.c(1)));
    return n;
}

/// SAD of the 16x16 source block at (px, py) and the reference's at
/// (px + dx, py + dy), every `step`-th row and column (1 or 2).
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
            const aw = bb.shl(bb.param(P_MBW), bb.c(4));
            const ah = bb.shl(bb.param(P_MBH), bb.c(4));
            const ry = bb.add(y, s.dy);
            const rx = bb.add(s.px, s.dx);
            var sum = bb.get(s.acc);
            var c: u32 = 0;
            while (c < 16) : (c += step) {
                const a = px8(bb, bb.add(src, bb.c(@intCast(c))));
                const r2 = refPx(bb, bb.param(P_REF_Y), ys, aw, ah, bb.add(rx, bb.c(@intCast(c))), ry);
                sum = bb.add(sum, bb.abs(bb.sub(a, r2)));
            }
            bb.put(s.acc, sum);
        }
    };
    b.loop(b.c(@intCast(16 / step)), Row{ .acc = acc, .px = px, .py = py, .dx = dx, .dy = dy });
    return b.get(acc);
}

/// SAD of the source block and the six-tap prediction at vector (mvr, mvc)
/// (eighth pels).
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
            const aw = bb.shl(bb.param(P_MBW), bb.c(4));
            const ah = bb.shl(bb.param(P_MBH), bb.c(4));
            const p = sixtap4x4(bb, bb.param(P_REF_Y), ys, aw, ah, bb.add(bx, bb.sar(s.mvc, bb.c(3))), bb.add(by, bb.sar(s.mvr, bb.c(3))), bb.band(s.mvc, bb.c(7)), bb.band(s.mvr, bb.c(7)));
            const src = block4(bb, bb.param(P_SRC_Y), ys, bx, by);
            var sum = bb.get(s.acc);
            for (0..16) |k| sum = bb.add(sum, bb.abs(bb.sub(src[k], p[k])));
            bb.put(s.acc, sum);
        }
    };
    b.loop(b.c(16), Blk{ .acc = acc, .px = px, .py = py, .mvr = mvr, .mvc = mvc });
    return b.get(acc);
}

/// Every macroblock's best vector (motion search, inter frames): an
/// invocation a macroblock, its index my << P_WSHIFT | mx.
pub fn motion(b: anytype) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            motionMb(bb);
        }
    };
    const i = b.index();
    const mx = b.band(i, b.sub(b.shl(b.c(1), b.param(P_WSHIFT)), b.c(1)));
    b.when(b.pand(b.lt(i, b.param(P_COUNT)), b.lt(mx, b.param(P_MBW))), T{});
}

/// A search candidate's cost against the best so far.
fn consider(b: anytype, best: anytype, br: anytype, bc: anytype, cost: anytype, r: anytype, c: anytype) void {
    const better = b.lt(cost, b.get(best));
    b.put(best, b.sel(better, cost, b.get(best)));
    b.put(br, b.sel(better, r, b.get(br)));
    b.put(bc, b.sel(better, c, b.get(bc)));
}

fn motionMb(b: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const i = b.index();
    const shift = b.param(P_WSHIFT);
    const my = b.shr(i, shift);
    const mx = b.band(i, b.sub(b.shl(b.c(1), shift), b.c(1)));
    const mbw = b.param(P_MBW);
    const mb = b.mad(my, mbw, mx);
    const px = b.shl(mx, b.c(4));
    const py = b.shl(my, b.c(4));
    const aw = b.shl(mbw, b.c(4));
    const ah = b.shl(b.param(P_MBH), b.c(4));
    const lambda = b.param(P_LAMBDA);
    const range = b.param(P_RANGE);
    // the window: the block may lie at most 16 pels outside the frame (the
    // decoder never clamps such a vector)
    const lo_x = b.max(b.neg(range), b.sub(b.c(-16), px));
    const hi_x = b.min(range, b.sub(aw, px));
    const lo_y = b.max(b.neg(range), b.sub(b.c(-16), py));
    const hi_y = b.min(range, b.sub(ah, py));

    // the step-2 search on subsampled SADs
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

    // full SADs: the zero vector, then the coarse best's 3x3
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

    // sub-pel: half pels, then quarter pels, around the best (eighth-pel
    // units, even); every candidate stays inside the window
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
                // k 0..7: the 8 neighbours (the centre skipped)
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
    const rec = b.mul(mb, b.c(MB_BYTES));
    b.st(.i16, INFO, b.add(rec, b.c(I_ME_MVR)), b.get(mvr));
    b.st(.i16, INFO, b.add(rec, b.c(I_ME_MVC)), b.get(mvc));
    b.st(.i32, INFO, b.add(rec, b.c(I_ME_COST)), b.get(sub_best));
}

/// k / 3 for 0 <= k < 16.
fn divide3(b: anytype, k: anytype) @TypeOf(b.c(0)) {
    return b.shr(b.mul(k, b.c(11)), b.c(5));
}

// ── encode ──────────────────────────────────────────────────────────────────

/// encode's mode costs (1/16 bits): the luma modes (DC, V, H, TM,
/// B_PRED), an inter macroblock's (its flag and mode, not its vector), the
/// ten subblock modes, the four chroma modes.
pub const P_MCOST = 54;
pub const P_INTER_COST = 59;
pub const P_BCOST = 60;
pub const P_UVCOST = 70;
pub const ENC_PARAMS = 74;

/// i16 x 16: the luma blocks' DCs between the passes (scratch).
pub const I_TMP = 896;

/// What every step of a macroblock's encode needs.
fn Mb(comptime B: type) type {
    return struct {
        mx: B.V,
        my: B.V,
        px: B.V,
        py: B.V,
        rec: B.V, // the record's offset
        ys: B.V,
        cs: B.V,
        aw: B.V,
        ah: B.V,
        lambda: B.V,
    };
}

/// A pixel of a reconstructed plane as intra prediction sees the frame's
/// edges (libvpx's decoder: the row above the frame 127, its corner too;
/// the column left of it 129; past the right edge, the row's last pixel).
fn edgePx(b: anytype, base: anytype, stride: anytype, w: anytype, x: anytype, y: anytype) @TypeOf(b.c(0)) {
    const cx = b.min(b.max(x, b.c(0)), b.sub(w, b.c(1)));
    const cy = b.max(y, b.c(0));
    const v = px8(b, b.add(base, b.mad(cy, stride, cx)));
    return b.sel(b.lt(y, b.c(0)), b.c(127), b.sel(b.lt(x, b.c(0)), b.c(129), v));
}

inline fn avg2(b: anytype, x: anytype, y: anytype) @TypeOf(b.c(0)) {
    return b.sar(b.add(b.add(x, y), b.c(1)), b.c(1));
}
inline fn avg3(b: anytype, x: anytype, y: anytype, z: anytype) @TypeOf(b.c(0)) {
    return b.sar(b.add(b.add(x, b.add(y, y)), b.add(z, b.c(2))), b.c(2));
}

/// A subblock prediction pixel as a formula of the edge: kind 0 the edge
/// value `a`, 1 avg2(a, b), 2 avg3(a, b, c). Edge indices: L0..L3 0..3,
/// the corner 4, A0..A7 5..12 (the vpx_dsp predictors VP8 uses).
const F = struct { k: u2, a: u4, b: u4 = 0, c: u4 = 0 };
const E_X = 4;
const E_A = 5;

fn bTable(comptime mode: u4) [16]F {
    var t: [16]F = undefined;
    const S = struct {
        fn c2(a: u4, b: u4) F {
            return .{ .k = 1, .a = a, .b = b };
        }
        fn c3(a: u4, b: u4, c: u4) F {
            return .{ .k = 2, .a = a, .b = b, .c = c };
        }
        fn put(tt: *[16]F, x: usize, y: usize, f: F) void {
            tt[y * 4 + x] = f;
        }
    };
    const A = E_A;
    const X = E_X;
    switch (mode) {
        2 => for (0..4) |y| { // B_VE_PRED
            for (0..4) |x| t[y * 4 + x] = S.c3(if (x == 0) X else A + x - 1, A + x, A + x + 1);
        },
        3 => for (0..4) |y| { // B_HE_PRED
            const l = [_]u4{ X, 0, 1, 2, 3, 3 };
            for (0..4) |x| t[y * 4 + x] = S.c3(l[y], l[y + 1], l[y + 2]);
        },
        4 => for (0..4) |y| { // B_LD_PRED (d45e)
            for (0..4) |x| {
                const s = x + y;
                t[y * 4 + x] = S.c3(A + s, A + s + 1, if (s == 6) A + 7 else A + s + 2);
            }
        },
        5 => for (0..4) |y| { // B_RD_PRED (d135)
            for (0..4) |x| {
                // the edge as one line: L3 L2 L1 L0 X A0 A1 A2 A3
                const line = [_]u4{ 3, 2, 1, 0, X, A, A + 1, A + 2, A + 3 };
                const d: usize = 4 + x - y; // the centre's place
                t[y * 4 + x] = S.c3(line[d - 1], line[d], line[d + 1]);
            }
        },
        6 => { // B_VR_PRED (d117)
            S.put(&t, 0, 0, S.c2(X, A));
            S.put(&t, 1, 2, S.c2(X, A));
            S.put(&t, 1, 0, S.c2(A, A + 1));
            S.put(&t, 2, 2, S.c2(A, A + 1));
            S.put(&t, 2, 0, S.c2(A + 1, A + 2));
            S.put(&t, 3, 2, S.c2(A + 1, A + 2));
            S.put(&t, 3, 0, S.c2(A + 2, A + 3));
            S.put(&t, 0, 3, S.c3(2, 1, 0));
            S.put(&t, 0, 2, S.c3(1, 0, X));
            S.put(&t, 0, 1, S.c3(0, X, A));
            S.put(&t, 1, 3, S.c3(0, X, A));
            S.put(&t, 1, 1, S.c3(X, A, A + 1));
            S.put(&t, 2, 3, S.c3(X, A, A + 1));
            S.put(&t, 2, 1, S.c3(A, A + 1, A + 2));
            S.put(&t, 3, 3, S.c3(A, A + 1, A + 2));
            S.put(&t, 3, 1, S.c3(A + 1, A + 2, A + 3));
        },
        7 => { // B_VL_PRED (d63e)
            S.put(&t, 0, 0, S.c2(A, A + 1));
            S.put(&t, 1, 0, S.c2(A + 1, A + 2));
            S.put(&t, 0, 2, S.c2(A + 1, A + 2));
            S.put(&t, 2, 0, S.c2(A + 2, A + 3));
            S.put(&t, 1, 2, S.c2(A + 2, A + 3));
            S.put(&t, 3, 0, S.c2(A + 3, A + 4));
            S.put(&t, 2, 2, S.c2(A + 3, A + 4));
            S.put(&t, 3, 2, S.c3(A + 4, A + 5, A + 6));
            S.put(&t, 0, 1, S.c3(A, A + 1, A + 2));
            S.put(&t, 1, 1, S.c3(A + 1, A + 2, A + 3));
            S.put(&t, 0, 3, S.c3(A + 1, A + 2, A + 3));
            S.put(&t, 2, 1, S.c3(A + 2, A + 3, A + 4));
            S.put(&t, 1, 3, S.c3(A + 2, A + 3, A + 4));
            S.put(&t, 3, 1, S.c3(A + 3, A + 4, A + 5));
            S.put(&t, 2, 3, S.c3(A + 3, A + 4, A + 5));
            S.put(&t, 3, 3, S.c3(A + 5, A + 6, A + 7));
        },
        8 => { // B_HD_PRED (d153)
            S.put(&t, 0, 0, S.c2(0, X));
            S.put(&t, 2, 1, S.c2(0, X));
            S.put(&t, 0, 1, S.c2(1, 0));
            S.put(&t, 2, 2, S.c2(1, 0));
            S.put(&t, 0, 2, S.c2(2, 1));
            S.put(&t, 2, 3, S.c2(2, 1));
            S.put(&t, 0, 3, S.c2(3, 2));
            S.put(&t, 3, 0, S.c3(A, A + 1, A + 2));
            S.put(&t, 2, 0, S.c3(X, A, A + 1));
            S.put(&t, 1, 0, S.c3(0, X, A));
            S.put(&t, 3, 1, S.c3(0, X, A));
            S.put(&t, 1, 1, S.c3(1, 0, X));
            S.put(&t, 3, 2, S.c3(1, 0, X));
            S.put(&t, 1, 2, S.c3(2, 1, 0));
            S.put(&t, 3, 3, S.c3(2, 1, 0));
            S.put(&t, 1, 3, S.c3(3, 2, 1));
        },
        9 => { // B_HU_PRED (d207)
            S.put(&t, 0, 0, S.c2(0, 1));
            S.put(&t, 2, 0, S.c2(1, 2));
            S.put(&t, 0, 1, S.c2(1, 2));
            S.put(&t, 2, 1, S.c2(2, 3));
            S.put(&t, 0, 2, S.c2(2, 3));
            S.put(&t, 1, 0, S.c3(0, 1, 2));
            S.put(&t, 3, 0, S.c3(1, 2, 3));
            S.put(&t, 1, 1, S.c3(1, 2, 3));
            S.put(&t, 3, 1, S.c3(2, 3, 3));
            S.put(&t, 1, 2, S.c3(2, 3, 3));
            for ([_][2]usize{ .{ 3, 2 }, .{ 2, 2 }, .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 } }) |p| S.put(&t, p[0], p[1], .{ .k = 0, .a = 3 });
        },
        else => unreachable,
    }
    return t;
}

/// Subblock mode `mode`'s prediction from the edge `e`.
fn bPredict(b: anytype, comptime mode: u4, e: [13]@TypeOf(b.c(0))) [16]@TypeOf(b.c(0)) {
    var p: [16]@TypeOf(b.c(0)) = undefined;
    switch (mode) {
        0 => { // B_DC_PRED
            var s = b.c(4);
            for (0..4) |k| s = b.add(s, b.add(e[k], e[E_A + k]));
            const dc = b.sar(s, b.c(3));
            for (0..16) |k| p[k] = dc;
        },
        1 => { // B_TM_PRED
            for (0..4) |y| {
                for (0..4) |x| p[y * 4 + x] = dsl.clip8(b, b.sub(b.add(e[y], e[E_A + x]), e[E_X]));
            }
        },
        else => {
            const t = comptime bTable(mode);
            inline for (t, 0..) |f, k| {
                p[k] = switch (f.k) {
                    0 => e[f.a],
                    1 => avg2(b, e[f.a], e[f.b]),
                    else => avg3(b, e[f.a], e[f.b], e[f.c]),
                };
            }
        },
    }
    return p;
}

/// The 16x16 (or 8x8) DC as libvpx's decoder: by which edges there are.
fn dcOf(b: anytype, base: anytype, stride: anytype, x0: anytype, y0: anytype, up: anytype, left: anytype, comptime n: u32) @TypeOf(b.c(0)) {
    var sa = b.c(0);
    var sl = b.c(0);
    const row = b.add(base, b.mul(b.max(b.sub(y0, b.c(1)), b.c(0)), stride));
    const col = b.add(base, b.max(b.sub(x0, b.c(1)), b.c(0)));
    for (0..n) |k| {
        sa = b.add(sa, px8(b, b.add(row, b.add(x0, b.c(@intCast(k))))));
        sl = b.add(sl, px8(b, b.add(col, b.mul(b.add(y0, b.c(@intCast(k))), stride))));
    }
    const sh: i32 = if (n == 16) 4 else 3;
    const both = b.sar(b.add(b.add(sa, sl), b.c(@as(i32, @intCast(n)))), b.c(sh + 1));
    const one_a = b.sar(b.add(sa, b.c(@as(i32, @intCast(n / 2)))), b.c(sh));
    const one_l = b.sar(b.add(sl, b.c(@as(i32, @intCast(n / 2)))), b.c(sh));
    return b.sel(b.pand(up, left), both, b.sel(up, one_a, b.sel(left, one_l, b.c(128))));
}

/// The 16x16 (8x8) intra prediction of mode `m` (a value 0..3) for the
/// 4x4 block at (x, y): DC `dc`, V, H, TM.
fn intraBlock(b: anytype, base: anytype, stride: anytype, w: anytype, x0: anytype, y0: anytype, x: anytype, y: anytype, m: anytype, dc: anytype) [16]@TypeOf(b.c(0)) {
    var a: [4]@TypeOf(b.c(0)) = undefined;
    var l: [4]@TypeOf(b.c(0)) = undefined;
    for (0..4) |k| {
        a[k] = edgePx(b, base, stride, w, b.add(x, b.c(@intCast(k))), b.sub(y0, b.c(1)));
        l[k] = edgePx(b, base, stride, w, b.sub(x0, b.c(1)), b.add(y, b.c(@intCast(k))));
    }
    const corner = edgePx(b, base, stride, w, b.sub(x0, b.c(1)), b.sub(y0, b.c(1)));
    var p: [16]@TypeOf(b.c(0)) = undefined;
    for (0..4) |r| {
        for (0..4) |c| {
            const tm = dsl.clip8(b, b.sub(b.add(l[r], a[c]), corner));
            p[r * 4 + c] = b.sel(b.eq(m, b.c(0)), dc, b.sel(b.eq(m, b.c(1)), a[c], b.sel(b.eq(m, b.c(2)), l[r], tm)));
        }
    }
    return p;
}

fn store4x4(b: anytype, base: anytype, stride: anytype, x: anytype, y: anytype, v: [16]@TypeOf(b.c(0))) void {
    for (0..4) |r| {
        const row = b.add(base, b.add(b.mul(b.add(y, b.c(@intCast(r))), stride), x));
        // one 32-bit store when the block's address allows: x is a multiple of 4
        const word = b.bor(b.bor(v[r * 4], b.shl(v[r * 4 + 1], b.c(8))), b.bor(b.shl(v[r * 4 + 2], b.c(16)), b.shl(v[r * 4 + 3], b.c(24))));
        b.st(.i32, MEM, row, word);
    }
}

fn coefAt(b: anytype, rec: anytype, blk: anytype, k: usize) @TypeOf(b.c(0)) {
    return b.add(rec, b.add(b.c(@intCast(I_COEF + 2 * k)), b.shl(blk, b.c(5))));
}

/// Quantizes `coefs` (DC with `dc_kind`, the rest with `ac_kind`; `skip_dc`:
/// the DC is not coded), stores the levels and the block's nonzero flag,
/// and returns the dequantized coefficients (the DC dequantized as 0 when
/// skipped).
fn quantBlock(b: anytype, rec: anytype, blk: anytype, coefs: [16]@TypeOf(b.c(0)), comptime dc_kind: usize, comptime ac_kind: usize, comptime skip_dc: bool) [16]@TypeOf(b.c(0)) {
    var dq: [16]@TypeOf(b.c(0)) = undefined;
    var nz = b.c(0);
    inline for (0..16) |k| {
        if (k == 0 and skip_dc) {
            b.st(.i16, INFO, coefAt(b, rec, blk, 0), b.c(0));
            dq[0] = b.c(0);
            continue;
        }
        const kind = if (k == 0) dc_kind else ac_kind;
        const l = quant(b, coefs[k], kind);
        b.st(.i16, INFO, coefAt(b, rec, blk, k), l);
        nz = b.bor(nz, l);
        dq[k] = b.mul(l, b.param(P_Q + kind));
    }
    b.st(.u8, INFO, b.add(rec, b.add(b.c(I_NZ), blk)), bit(b, b.ne(nz, b.c(0))));
    return dq;
}

/// Adds `res` to the prediction in the plane (the block at x, y) and stores.
fn reconstruct(b: anytype, base: anytype, stride: anytype, x: anytype, y: anytype, pred: [16]@TypeOf(b.c(0)), res: [16]@TypeOf(b.c(0))) void {
    var out: [16]@TypeOf(b.c(0)) = undefined;
    for (0..16) |k| out[k] = dsl.clip8(b, b.add(pred[k], res[k]));
    store4x4(b, base, stride, x, y, out);
}

pub fn encode(b: anytype) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            encodeMb(bb);
        }
    };
    b.when(b.lt(b.index(), b.param(P_COUNT)), T{});
}

/// The macroblock of wavefront `wave` this invocation encodes: x + 2y = wave.
fn waveMb(b: anytype) [2]@TypeOf(b.c(0)) {
    const wave = b.param(P_WAVE);
    const ymin = b.max(b.c(0), b.sar(b.add(b.sub(wave, b.param(P_MBW)), b.c(2)), b.c(1)));
    const my = b.add(ymin, b.index());
    const mx = b.sub(wave, b.shl(my, b.c(1)));
    return .{ mx, my };
}

fn encodeMb(b: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const xy = waveMb(b);
    const mbw = b.param(P_MBW);
    const e = Mb(B){
        .mx = xy[0],
        .my = xy[1],
        .px = b.shl(xy[0], b.c(4)),
        .py = b.shl(xy[1], b.c(4)),
        .rec = b.mul(b.mad(xy[1], mbw, xy[0]), b.c(MB_BYTES)),
        .ys = b.param(P_YS),
        .cs = b.param(P_CS),
        .aw = b.shl(mbw, b.c(4)),
        .ah = b.shl(b.param(P_MBH), b.c(4)),
        .lambda = b.param(P_LAMBDA),
    };
    const key = b.ne(b.param(P_KEY), b.c(0));
    const up = b.gt(e.my, b.c(0));
    const left = b.gt(e.mx, b.c(0));
    b.st(.u8, INFO, b.add(e.rec, b.c(I_NZ + 24)), b.c(0));

    // 1. the 16x16 intra modes by SATD
    const best = b.vr(b.c(0x7fff_ffff));
    const best_mode = b.vr(b.c(0));
    const dc16 = dcOf(b, b.param(P_REC_Y), e.ys, e.px, e.py, up, left, 16);
    inline for (0..4) |m| {
        const Cost = struct {
            e: Mb(B),
            dc: V,
            acc: B.Var,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const x = bb.add(s.e.px, bb.shl(bb.band(j, bb.c(3)), bb.c(2)));
                const y = bb.add(s.e.py, bb.shl(bb.shr(j, bb.c(2)), bb.c(2)));
                const p = intraBlock(bb, bb.param(P_REC_Y), s.e.ys, s.e.aw, s.e.px, s.e.py, x, y, bb.c(m), s.dc);
                const src = block4(bb, bb.param(P_SRC_Y), s.e.ys, x, y);
                bb.put(s.acc, bb.add(bb.get(s.acc), satd(bb, diff16(bb, src, p))));
            }
        };
        const acc = b.vr(b.c(0));
        b.loop(b.c(16), Cost{ .e = e, .dc = dc16, .acc = acc });
        const cost = b.add(b.get(acc), b.sar(b.mul(e.lambda, b.param(P_MCOST + m)), b.c(8)));
        const better = b.lt(cost, b.get(best));
        b.put(best, b.sel(better, cost, b.get(best)));
        b.put(best_mode, b.sel(better, b.c(m), b.get(best_mode)));
    }

    // 2. inter: the motion search's vector
    const mvr = b.vr(b.c(0));
    const mvc = b.vr(b.c(0));
    const Inter = struct {
        e: Mb(B),
        best: B.Var,
        best_mode: B.Var,
        mvr: B.Var,
        mvc: B.Var,
        const Cost = struct {
            e: Mb(B),
            r: V,
            c: V,
            acc: B.Var,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const x = bb.add(s.e.px, bb.shl(bb.band(j, bb.c(3)), bb.c(2)));
                const y = bb.add(s.e.py, bb.shl(bb.shr(j, bb.c(2)), bb.c(2)));
                const p = sixtap4x4(bb, bb.param(P_REF_Y), s.e.ys, s.e.aw, s.e.ah, bb.add(x, bb.sar(s.c, bb.c(3))), bb.add(y, bb.sar(s.r, bb.c(3))), bb.band(s.c, bb.c(7)), bb.band(s.r, bb.c(7)));
                const src = block4(bb, bb.param(P_SRC_Y), s.e.ys, x, y);
                bb.put(s.acc, bb.add(bb.get(s.acc), satd(bb, diff16(bb, src, p))));
            }
        };
        pub fn then(s: @This(), bb: *B) void {
            const r = bb.ld(.i16, INFO, bb.add(s.e.rec, bb.c(I_ME_MVR)));
            const c = bb.ld(.i16, INFO, bb.add(s.e.rec, bb.c(I_ME_MVC)));
            bb.put(s.mvr, r);
            bb.put(s.mvc, c);
            const acc = bb.vr(bb.c(0));
            bb.loop(bb.c(16), Cost{ .e = s.e, .r = r, .c = c, .acc = acc });
            const bits16 = bb.add(bb.param(P_INTER_COST), bb.shl(bb.add(mvBits(bb, bb.sar(r, bb.c(1))), mvBits(bb, bb.sar(c, bb.c(1)))), bb.c(4)));
            const cost = bb.add(bb.get(acc), bb.sar(bb.mul(s.e.lambda, bits16), bb.c(8)));
            const better = bb.lt(cost, bb.get(s.best));
            bb.put(s.best, bb.sel(better, cost, bb.get(s.best)));
            bb.put(s.best_mode, bb.sel(better, bb.c(MODE_INTER), bb.get(s.best_mode)));
        }
    };
    b.when(b.pnot(key), Inter{ .e = e, .best = best, .best_mode = best_mode, .mvr = mvr, .mvc = mvc });

    // 3. B_PRED: each subblock's mode, transform and reconstruction in
    // order (the next one predicts from them)
    const bcost = b.vr(b.sar(b.mul(e.lambda, b.param(P_MCOST + 4)), b.c(8)));
    const Sub = struct {
        e: Mb(B),
        acc: B.Var,
        pub fn body(s: @This(), bb: *B, j: V) void {
            const bx = bb.band(j, bb.c(3));
            const by = bb.shr(j, bb.c(2));
            const sx = bb.add(s.e.px, bb.shl(bx, bb.c(2)));
            const sy = bb.add(s.e.py, bb.shl(by, bb.c(2)));
            const base = bb.param(P_REC_Y);
            var eg: [13]V = undefined;
            for (0..4) |k| eg[k] = edgePx(bb, base, s.e.ys, s.e.aw, bb.sub(sx, bb.c(1)), bb.add(sy, bb.c(@intCast(k))));
            eg[E_X] = edgePx(bb, base, s.e.ys, s.e.aw, bb.sub(sx, bb.c(1)), bb.sub(sy, bb.c(1)));
            for (0..4) |k| eg[E_A + k] = edgePx(bb, base, s.e.ys, s.e.aw, bb.add(sx, bb.c(@intCast(k))), bb.sub(sy, bb.c(1)));
            // above-right: the row above the macroblock for the right column
            // and the top row (the decoder's copy down), else the subblock's
            const ar_row = bb.sel(bb.por(bb.eq(bx, bb.c(3)), bb.eq(by, bb.c(0))), bb.sub(s.e.py, bb.c(1)), bb.sub(sy, bb.c(1)));
            for (0..4) |k| eg[E_A + 4 + k] = edgePx(bb, base, s.e.ys, s.e.aw, bb.add(sx, bb.c(@intCast(4 + k))), ar_row);
            const src = block4(bb, bb.param(P_SRC_Y), s.e.ys, sx, sy);
            var best_p: [16]V = bPredict(bb, 0, eg);
            var best_c = bb.add(satd(bb, diff16(bb, src, best_p)), bb.sar(bb.mul(s.e.lambda, bb.param(P_BCOST)), bb.c(8)));
            var best_m = bb.c(0);
            inline for (1..10) |m| {
                const p = bPredict(bb, m, eg);
                const cst = bb.add(satd(bb, diff16(bb, src, p)), bb.sar(bb.mul(s.e.lambda, bb.param(P_BCOST + m)), bb.c(8)));
                const better = bb.lt(cst, best_c);
                for (0..16) |k| best_p[k] = bb.sel(better, p[k], best_p[k]);
                best_c = bb.sel(better, cst, best_c);
                best_m = bb.sel(better, bb.c(m), best_m);
            }
            bb.st(.u8, INFO, bb.add(s.e.rec, bb.add(bb.c(I_BMODES), j)), best_m);
            bb.put(s.acc, bb.add(bb.get(s.acc), best_c));
            const dq = quantBlock(bb, s.e.rec, j, fdct(bb, diff16(bb, src, best_p)), Q_Y1DC, Q_Y1AC, false);
            reconstruct(bb, base, s.e.ys, sx, sy, best_p, idct(bb, dq));
        }
    };
    b.loop(b.c(16), Sub{ .e = e, .acc = bcost });
    const use_b = b.lt(b.get(bcost), b.get(best));
    b.put(best_mode, b.sel(use_b, b.c(4), b.get(best_mode)));
    const mode = b.get(best_mode);
    const inter = b.eq(mode, b.c(MODE_INTER));
    b.put(mvr, b.sel(inter, b.get(mvr), b.c(0)));
    b.put(mvc, b.sel(inter, b.get(mvc), b.c(0)));

    // 4. the luma of the other modes: prediction, then the blocks' DCs
    // through the Y2 transform
    const Luma = struct {
        const Self = @This();
        e: Mb(B),
        mode: V,
        mvr: V,
        mvc: V,
        dc: V,
        const Pred = struct {
            l: *const Self,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const e2 = s.l.e;
                const x = bb.add(e2.px, bb.shl(bb.band(j, bb.c(3)), bb.c(2)));
                const y = bb.add(e2.py, bb.shl(bb.shr(j, bb.c(2)), bb.c(2)));
                const IP = struct {
                    l: *const Self,
                    x: V,
                    y: V,
                    pub fn then(t: @This(), b2: *B) void {
                        const e3 = t.l.e;
                        const p = sixtap4x4(b2, b2.param(P_REF_Y), e3.ys, e3.aw, e3.ah, b2.add(t.x, b2.sar(t.l.mvc, b2.c(3))), b2.add(t.y, b2.sar(t.l.mvr, b2.c(3))), b2.band(t.l.mvc, b2.c(7)), b2.band(t.l.mvr, b2.c(7)));
                        store4x4(b2, b2.param(P_REC_Y), e3.ys, t.x, t.y, p);
                    }
                    pub fn otherwise(t: @This(), b2: *B) void {
                        const e3 = t.l.e;
                        const p = intraBlock(b2, b2.param(P_REC_Y), e3.ys, e3.aw, e3.px, e3.py, t.x, t.y, t.l.mode, t.l.dc);
                        store4x4(b2, b2.param(P_REC_Y), e3.ys, t.x, t.y, p);
                    }
                };
                bb.whenElse(bb.eq(s.l.mode, bb.c(MODE_INTER)), IP{ .l = s.l, .x = x, .y = y });
            }
        };
        const Fwd = struct {
            l: *const Self,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const e2 = s.l.e;
                const x = bb.add(e2.px, bb.shl(bb.band(j, bb.c(3)), bb.c(2)));
                const y = bb.add(e2.py, bb.shl(bb.shr(j, bb.c(2)), bb.c(2)));
                const p = block4(bb, bb.param(P_REC_Y), e2.ys, x, y);
                const src = block4(bb, bb.param(P_SRC_Y), e2.ys, x, y);
                const co = fdct(bb, diff16(bb, src, p));
                bb.st(.i16, INFO, bb.add(e2.rec, bb.add(bb.c(I_TMP), bb.shl(j, bb.c(1)))), co[0]);
                _ = quantBlock(bb, e2.rec, j, co, Q_Y1DC, Q_Y1AC, true);
            }
        };
        const Inv = struct {
            l: *const Self,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const e2 = s.l.e;
                const x = bb.add(e2.px, bb.shl(bb.band(j, bb.c(3)), bb.c(2)));
                const y = bb.add(e2.py, bb.shl(bb.shr(j, bb.c(2)), bb.c(2)));
                var dq: [16]V = undefined;
                dq[0] = bb.ld(.i16, INFO, bb.add(e2.rec, bb.add(bb.c(I_TMP), bb.shl(j, bb.c(1)))));
                for (1..16) |k| dq[k] = bb.mul(bb.ld(.i16, INFO, coefAt(bb, e2.rec, j, k)), bb.param(P_Q + Q_Y1AC));
                const p = block4(bb, bb.param(P_REC_Y), e2.ys, x, y);
                reconstruct(bb, bb.param(P_REC_Y), e2.ys, x, y, p, idct(bb, dq));
            }
        };
        pub fn then(s: *const @This(), bb: *B) void {
            const e2 = s.e;
            bb.loop(bb.c(16), Pred{ .l = s });
            bb.loop(bb.c(16), Fwd{ .l = s });
            var dcs: [16]V = undefined;
            for (0..16) |k| dcs[k] = bb.ld(.i16, INFO, bb.add(e2.rec, bb.c(@intCast(I_TMP + 2 * k))));
            const dq = quantBlock(bb, e2.rec, bb.c(24), fwalsh(bb, dcs), Q_Y2DC, Q_Y2AC, false);
            const back = iwalsh(bb, dq);
            for (0..16) |k| bb.st(.i16, INFO, bb.add(e2.rec, bb.c(@intCast(I_TMP + 2 * k))), back[k]);
            bb.loop(bb.c(16), Inv{ .l = s });
        }
    };
    const luma = Luma{ .e = e, .mode = mode, .mvr = b.get(mvr), .mvc = b.get(mvc), .dc = dc16 };
    b.when(b.pnot(use_b), &luma);

    // 5. chroma: an intra macroblock's mode by SATD, an inter one's vector
    const uv_best = b.vr(b.c(0x7fff_ffff));
    const uv_mode = b.vr(b.c(0));
    const cw = b.shr(e.aw, b.c(1));
    const cx = b.shr(e.px, b.c(1));
    const cy = b.shr(e.py, b.c(1));
    const dcu = dcOf(b, b.param(P_REC_U), e.cs, cx, cy, up, left, 8);
    const dcv = dcOf(b, b.param(P_REC_V), e.cs, cx, cy, up, left, 8);
    const Chroma = struct {
        const Self = @This();
        e: Mb(B),
        cw: V,
        cx: V,
        cy: V,
        dcu: V,
        dcv: V,
        best: B.Var,
        best_mode: B.Var,
        fn blockXy(s: @This(), bb: *B, j: V) [2]V {
            const q = bb.band(j, bb.c(3));
            return .{ bb.add(s.cx, bb.shl(bb.band(q, bb.c(1)), bb.c(2))), bb.add(s.cy, bb.shl(bb.shr(q, bb.c(1)), bb.c(2))) };
        }
        fn plane(bb: *B, j: V, comptime which: enum { rec, src }) V {
            const is_v = bb.ge(j, bb.c(4));
            return switch (which) {
                .rec => bb.sel(is_v, bb.param(P_REC_V), bb.param(P_REC_U)),
                .src => bb.sel(is_v, bb.param(P_SRC_V), bb.param(P_SRC_U)),
            };
        }
        const Cost = struct {
            o: *const Self,
            m: V,
            acc: B.Var,
            pub fn body(s: @This(), bb: *B, j: V) void {
                const xy2 = s.o.blockXy(bb, j);
                const dc = bb.sel(bb.ge(j, bb.c(4)), s.o.dcv, s.o.dcu);
                const p = intraBlock(bb, plane(bb, j, .rec), s.o.e.cs, s.o.cw, s.o.cx, s.o.cy, xy2[0], xy2[1], s.m, dc);
                const src = block4(bb, plane(bb, j, .src), s.o.e.cs, xy2[0], xy2[1]);
                bb.put(s.acc, bb.add(bb.get(s.acc), satd(bb, diff16(bb, src, p))));
            }
        };
        pub fn then(s: *const @This(), bb: *B) void {
            inline for (0..4) |m| {
                const acc = bb.vr(bb.c(0));
                bb.loop(bb.c(8), Cost{ .o = s, .m = bb.c(m), .acc = acc });
                const cost = bb.add(bb.get(acc), bb.sar(bb.mul(s.e.lambda, bb.param(P_UVCOST + m)), bb.c(8)));
                const better = bb.lt(cost, bb.get(s.best));
                bb.put(s.best, bb.sel(better, cost, bb.get(s.best)));
                bb.put(s.best_mode, bb.sel(better, bb.c(m), bb.get(s.best_mode)));
            }
        }
    };
    const chroma = Chroma{ .e = e, .cw = cw, .cx = cx, .cy = cy, .dcu = dcu, .dcv = dcv, .best = uv_best, .best_mode = uv_mode };
    b.when(b.pnot(inter), &chroma);
    const CPred = struct {
        const Self = @This();
        o: *const Chroma,
        mode: V,
        inter: B.P,
        mvr: V,
        mvc: V,
        const IP = struct {
            s: *const Self,
            j: V,
            x: V,
            y: V,
            pub fn then(t: @This(), b2: *B) void {
                const o = t.s.o;
                const ur = b2.sar(t.s.mvr, b2.c(1));
                const uc = b2.sar(t.s.mvc, b2.c(1));
                const ref = b2.sel(b2.ge(t.j, b2.c(4)), b2.param(P_REF_V), b2.param(P_REF_U));
                const p = sixtap4x4(b2, ref, o.e.cs, o.cw, b2.shr(o.e.ah, b2.c(1)), b2.add(t.x, b2.sar(uc, b2.c(3))), b2.add(t.y, b2.sar(ur, b2.c(3))), b2.band(uc, b2.c(7)), b2.band(ur, b2.c(7)));
                store4x4(b2, Chroma.plane(b2, t.j, .rec), o.e.cs, t.x, t.y, p);
            }
            pub fn otherwise(t: @This(), b2: *B) void {
                const o = t.s.o;
                const dc = b2.sel(b2.ge(t.j, b2.c(4)), o.dcv, o.dcu);
                const p = intraBlock(b2, Chroma.plane(b2, t.j, .rec), o.e.cs, o.cw, o.cx, o.cy, t.x, t.y, t.s.mode, dc);
                store4x4(b2, Chroma.plane(b2, t.j, .rec), o.e.cs, t.x, t.y, p);
            }
        };
        pub fn body(s: *const @This(), bb: *B, j: V) void {
            const xy2 = s.o.blockXy(bb, j);
            bb.whenElse(s.inter, IP{ .s = s, .j = j, .x = xy2[0], .y = xy2[1] });
        }
    };
    const cpred = CPred{ .o = &chroma, .mode = b.get(uv_mode), .inter = inter, .mvr = b.get(mvr), .mvc = b.get(mvc) };
    b.loop(b.c(8), &cpred);
    const CRes = struct {
        o: *const Chroma,
        pub fn body(s: @This(), bb: *B, j: V) void {
            const xy2 = s.o.blockXy(bb, j);
            const rp = Chroma.plane(bb, j, .rec);
            const p = block4(bb, rp, s.o.e.cs, xy2[0], xy2[1]);
            const src = block4(bb, Chroma.plane(bb, j, .src), s.o.e.cs, xy2[0], xy2[1]);
            const dq = quantBlock(bb, s.o.e.rec, bb.add(j, bb.c(16)), fdct(bb, diff16(bb, src, p)), Q_UVDC, Q_UVAC, false);
            reconstruct(bb, rp, s.o.e.cs, xy2[0], xy2[1], p, idct(bb, dq));
        }
    };
    b.loop(b.c(8), CRes{ .o = &chroma });

    // 6. the record
    var nzs = b.c(0);
    for (0..25) |k| nzs = b.bor(nzs, b.ld(.u8, INFO, b.add(e.rec, b.c(@intCast(I_NZ + k)))));
    b.st(.u8, INFO, b.add(e.rec, b.c(I_YMODE)), mode);
    b.st(.u8, INFO, b.add(e.rec, b.c(I_UVMODE)), b.get(uv_mode));
    b.st(.u8, INFO, b.add(e.rec, b.c(I_SKIP)), bit(b, b.eq(nzs, b.c(0))));
    b.st(.i16, INFO, b.add(e.rec, b.c(I_MVR)), b.get(mvr));
    b.st(.i16, INFO, b.add(e.rec, b.c(I_MVC)), b.get(mvc));
}

// ── filter ──────────────────────────────────────────────────────────────────

fn sc(b: anytype, x: anytype) @TypeOf(b.c(0)) {
    return dsl.clamp(b, x, b.c(-128), b.c(127));
}

/// One edge of the loop filter: `count` positions `along` apart, the taps
/// `across` apart (q0 at the position); the macroblock edge's filter or the
/// subblock edge's.
fn edge(b: anytype, base: anytype, along: anytype, across: anytype, count: i32, comptime mb_edge: bool, lim: anytype, blim: anytype, hev_th: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const Pos = struct {
        base: V,
        along: V,
        across: V,
        lim: V,
        blim: V,
        hev_th: V,
        pub fn body(s: @This(), bb: *B, k: V) void {
            const q0a = bb.add(s.base, bb.mul(k, s.along));
            var a: [8]V = undefined; // p3 p2 p1 p0 q0 q1 q2 q3
            var at: [8]V = undefined;
            for (0..8) |t| {
                at[t] = bb.add(q0a, bb.mul(s.across, bb.c(@as(i32, @intCast(t)) - 4)));
                a[t] = px8(bb, at[t]);
            }
            var bad = bb.pc(false);
            for (0..3) |t| bad = bb.por(bad, bb.gt(bb.abs(bb.sub(a[t], a[t + 1])), s.lim));
            for (4..7) |t| bad = bb.por(bad, bb.gt(bb.abs(bb.sub(a[t], a[t + 1])), s.lim));
            const edge_d = bb.add(bb.shl(bb.abs(bb.sub(a[3], a[4])), bb.c(1)), bb.shr(bb.abs(bb.sub(a[2], a[5])), bb.c(1)));
            bad = bb.por(bad, bb.gt(edge_d, s.blim));
            const mask = bb.pnot(bad);
            const hev = bb.por(bb.gt(bb.abs(bb.sub(a[2], a[3])), s.hev_th), bb.gt(bb.abs(bb.sub(a[5], a[4])), s.hev_th));
            var p: [8]V = undefined;
            for (0..8) |t| p[t] = bb.sub(a[t], bb.c(128));
            const zero = bb.c(0);
            if (mb_edge) {
                var fv = sc(bb, bb.sub(p[2], p[5]));
                fv = sc(bb, bb.add(fv, bb.mul(bb.c(3), bb.sub(p[4], p[3]))));
                fv = bb.sel(mask, fv, zero);
                const f2h = bb.sel(hev, fv, zero);
                const f1 = bb.sar(sc(bb, bb.add(f2h, bb.c(4))), bb.c(3));
                const f2 = bb.sar(sc(bb, bb.add(f2h, bb.c(3))), bb.c(3));
                var qs0 = sc(bb, bb.sub(p[4], f1));
                var ps0 = sc(bb, bb.add(p[3], f2));
                const w = bb.sel(hev, zero, fv);
                var u = sc(bb, bb.sar(bb.add(bb.c(63), bb.mul(w, bb.c(27))), bb.c(7)));
                qs0 = sc(bb, bb.sub(qs0, u));
                ps0 = sc(bb, bb.add(ps0, u));
                u = sc(bb, bb.sar(bb.add(bb.c(63), bb.mul(w, bb.c(18))), bb.c(7)));
                const qs1 = sc(bb, bb.sub(p[5], u));
                const ps1 = sc(bb, bb.add(p[2], u));
                u = sc(bb, bb.sar(bb.add(bb.c(63), bb.mul(w, bb.c(9))), bb.c(7)));
                const qs2 = sc(bb, bb.sub(p[6], u));
                const ps2 = sc(bb, bb.add(p[1], u));
                bb.st(.u8, MEM, at[1], bb.add(ps2, bb.c(128)));
                bb.st(.u8, MEM, at[2], bb.add(ps1, bb.c(128)));
                bb.st(.u8, MEM, at[3], bb.add(ps0, bb.c(128)));
                bb.st(.u8, MEM, at[4], bb.add(qs0, bb.c(128)));
                bb.st(.u8, MEM, at[5], bb.add(qs1, bb.c(128)));
                bb.st(.u8, MEM, at[6], bb.add(qs2, bb.c(128)));
            } else {
                var fv = bb.sel(hev, sc(bb, bb.sub(p[2], p[5])), zero);
                fv = sc(bb, bb.add(fv, bb.mul(bb.c(3), bb.sub(p[4], p[3]))));
                fv = bb.sel(mask, fv, zero);
                const f1 = bb.sar(sc(bb, bb.add(fv, bb.c(4))), bb.c(3));
                const f2 = bb.sar(sc(bb, bb.add(fv, bb.c(3))), bb.c(3));
                const qs0 = sc(bb, bb.sub(p[4], f1));
                const ps0 = sc(bb, bb.add(p[3], f2));
                const o = bb.sel(hev, zero, bb.sar(bb.add(f1, bb.c(1)), bb.c(1)));
                const qs1 = sc(bb, bb.sub(p[5], o));
                const ps1 = sc(bb, bb.add(p[2], o));
                bb.st(.u8, MEM, at[2], bb.add(ps1, bb.c(128)));
                bb.st(.u8, MEM, at[3], bb.add(ps0, bb.c(128)));
                bb.st(.u8, MEM, at[4], bb.add(qs0, bb.c(128)));
                bb.st(.u8, MEM, at[5], bb.add(qs1, bb.c(128)));
            }
        }
    };
    b.loop(b.c(count), Pos{ .base = base, .along = along, .across = across, .lim = lim, .blim = blim, .hev_th = hev_th });
}

pub fn filter(b: anytype) void {
    const T = struct {
        pub fn then(_: @This(), bb: anytype) void {
            filterMb(bb);
        }
    };
    b.when(b.lt(b.index(), b.param(P_COUNT)), T{});
}

fn filterMb(b: anytype) void {
    const B = Be(@TypeOf(b));
    const V = B.V;
    const xy = waveMb(b);
    const mx = xy[0];
    const my = xy[1];
    const rec = b.mul(b.mad(my, b.param(P_MBW), mx), b.c(MB_BYTES));
    const ymode = b.ld(.u8, INFO, b.add(rec, b.c(I_YMODE)));
    const skip = b.ld(.u8, INFO, b.add(rec, b.c(I_SKIP)));
    const zero_mv = b.pand(b.eq(b.ld(.i16, INFO, b.add(rec, b.c(I_MVR))), b.c(0)), b.eq(b.ld(.i16, INFO, b.add(rec, b.c(I_MVC))), b.c(0)));
    const level = b.sel(b.eq(ymode, b.c(4)), b.param(P_LF), b.sel(b.lt(ymode, b.c(4)), b.param(P_LF + 1), b.sel(zero_mv, b.param(P_LF + 2), b.param(P_LF + 3))));
    const Go = struct {
        mx: V,
        my: V,
        level: V,
        skip_lf: B.P,
        pub fn then(s: @This(), bb: *B) void {
            const sharp = bb.param(P_SHARP);
            var interior = bb.sar(s.level, bit(bb, bb.gt(sharp, bb.c(0))));
            interior = bb.sar(interior, bit(bb, bb.gt(sharp, bb.c(4))));
            interior = bb.sel(bb.gt(sharp, bb.c(0)), bb.min(interior, bb.sub(bb.c(9), sharp)), interior);
            interior = bb.max(interior, bb.c(1));
            const key = bb.ne(bb.param(P_KEY), bb.c(0));
            const l = s.level;
            const hev_key = bb.add(bit(bb, bb.ge(l, bb.c(15))), bit(bb, bb.ge(l, bb.c(40))));
            const hev_inter = bb.add(bb.add(bit(bb, bb.ge(l, bb.c(15))), bit(bb, bb.ge(l, bb.c(20)))), bit(bb, bb.ge(l, bb.c(40))));
            const hev = bb.sel(key, hev_key, hev_inter);
            const mblim = bb.add(bb.shl(bb.add(l, bb.c(2)), bb.c(1)), interior);
            const blim = bb.add(bb.shl(l, bb.c(1)), interior);
            const ys = bb.param(P_YS);
            const cs = bb.param(P_CS);
            const y0 = bb.add(bb.param(P_REC_Y), bb.add(bb.mul(bb.shl(s.my, bb.c(4)), ys), bb.shl(s.mx, bb.c(4))));
            const coff = bb.add(bb.mul(bb.shl(s.my, bb.c(3)), cs), bb.shl(s.mx, bb.c(3)));
            const uo = bb.add(bb.param(P_REC_U), coff);
            const vo = bb.add(bb.param(P_REC_V), coff);
            const Lim = struct { ys: V, cs: V, y0: V, u0: V, v0: V, lim: V, blim: V, mblim: V, hev: V };
            const lm = Lim{ .ys = ys, .cs = cs, .y0 = y0, .u0 = uo, .v0 = vo, .lim = interior, .blim = blim, .mblim = mblim, .hev = hev };
            const MbV = struct {
                m: Lim,
                pub fn then(t: @This(), b2: *B) void {
                    const m = t.m;
                    edge(b2, m.y0, m.ys, b2.c(1), 16, true, m.lim, m.mblim, m.hev);
                    edge(b2, m.u0, m.cs, b2.c(1), 8, true, m.lim, m.mblim, m.hev);
                    edge(b2, m.v0, m.cs, b2.c(1), 8, true, m.lim, m.mblim, m.hev);
                }
            };
            const BV = struct {
                m: Lim,
                pub fn then(t: @This(), b2: *B) void {
                    const m = t.m;
                    for ([_]i32{ 4, 8, 12 }) |o| edge(b2, b2.add(m.y0, b2.c(o)), m.ys, b2.c(1), 16, false, m.lim, m.blim, m.hev);
                    edge(b2, b2.add(m.u0, b2.c(4)), m.cs, b2.c(1), 8, false, m.lim, m.blim, m.hev);
                    edge(b2, b2.add(m.v0, b2.c(4)), m.cs, b2.c(1), 8, false, m.lim, m.blim, m.hev);
                }
            };
            const MbH = struct {
                m: Lim,
                pub fn then(t: @This(), b2: *B) void {
                    const m = t.m;
                    edge(b2, m.y0, b2.c(1), m.ys, 16, true, m.lim, m.mblim, m.hev);
                    edge(b2, m.u0, b2.c(1), m.cs, 8, true, m.lim, m.mblim, m.hev);
                    edge(b2, m.v0, b2.c(1), m.cs, 8, true, m.lim, m.mblim, m.hev);
                }
            };
            const BH = struct {
                m: Lim,
                pub fn then(t: @This(), b2: *B) void {
                    const m = t.m;
                    for ([_]i32{ 4, 8, 12 }) |o| edge(b2, b2.add(m.y0, b2.mul(b2.c(o), m.ys)), b2.c(1), m.ys, 16, false, m.lim, m.blim, m.hev);
                    edge(b2, b2.add(m.u0, b2.shl(m.cs, b2.c(2))), b2.c(1), m.cs, 8, false, m.lim, m.blim, m.hev);
                    edge(b2, b2.add(m.v0, b2.shl(m.cs, b2.c(2))), b2.c(1), m.cs, 8, false, m.lim, m.blim, m.hev);
                }
            };
            bb.when(bb.gt(s.mx, bb.c(0)), MbV{ .m = lm });
            bb.when(bb.pnot(s.skip_lf), BV{ .m = lm });
            bb.when(bb.gt(s.my, bb.c(0)), MbH{ .m = lm });
            bb.when(bb.pnot(s.skip_lf), BH{ .m = lm });
        }
    };
    const skip_lf = b.pand(b.ne(ymode, b.c(4)), b.ne(skip, b.c(0)));
    b.when(b.gt(level, b.c(0)), Go{ .mx = mx, .my = my, .level = level, .skip_lf = skip_lf });
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "vp8_kernels: the transforms invert (DCT, Walsh-Hadamard) as RFC 6386's decoder has them" {
    var b = dsl.Cpu.init(.{ &.{}, &.{}, &.{}, &.{} }, &.{}, 0);
    var d: [16]i32 = undefined;
    for (0..16) |k| d[k] = @as(i32, @intCast((k * 37) % 61)) - 30;
    const back = idct(&b, fdct(&b, d));
    for (0..16) |k| try testing.expect(@abs(back[k] - d[k]) <= 1);
    var dc: [16]i32 = undefined;
    for (0..16) |k| dc[k] = @as(i32, @intCast(k * 100)) - 700;
    const wb = iwalsh(&b, fwalsh(&b, dc));
    for (0..16) |k| try testing.expect(@abs(wb[k] - dc[k]) <= 1);
    // a flat block: the DC, 8 times the value (libvpx's rounding leaves
    // an AC of 1 or so)
    const flat = fdct(&b, @splat(10));
    try testing.expectEqual(@as(i32, 80), flat[0]);
    for (1..16) |k| try testing.expect(@abs(flat[k]) <= 1);
}
