//! @zpm/gfxapi texture — a draw's texture reads in KIR: texelFetch, the
//! sampled read (nearest or bilinear, each axis wrapped: repeat, clamp to
//! edge, mirrored repeat), textureSize. Every float operation is one KIR
//! defines bit for bit, so a sample is the same on every GPU and on the
//! CPU (sRGB's decode apart: it uses exp2 and log2).
//!
//! A texture is a binding (its image's memory: every mipmap level) and a
//! descriptor of DESC_WORDS words in the uniform binding, which the draw
//! fills from the GL state of the texture's unit (`descriptor`): level
//! 0's size and row stride, the format (texel bytes, kind, channels,
//! sRGB), a swizzle, wrap modes, the filters, the base and last levels,
//! the LOD range, and each level's offset. One code reads every format: a
//! texel is up to four aligned words (clamped inside the image: no read
//! past it), its channels taken as the format says. So a program's code
//! does not depend on what is bound to its samplers.
//!
//! Mipmaps: a sample's level of detail λ is its derivatives' (a fragment
//! shader's, through its quad; textureGrad's), or given (textureLod), or
//! none (the base level, magnified: a vertex shader's). It is clamped to
//! the LOD range; at or below c it magnifies, else minifies, and
//! *_MIPMAP_NEAREST read the nearest level, *_MIPMAP_LINEAR the two
//! round it, blended (GL ES 3.0's rules). λ is skipped where it cannot
//! matter (no mipmaps, and one filter both ways).
//!
//! Not yet: cube maps, 3D and array textures, shadow comparisons, LOD for
//! integer textures (their base level is read).

const std = @import("std");
const gpu = @import("gpu");
const engine = @import("engine.sig");
const kir = gpu.kir;
const V = kir.V;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const no = kir.no;

/// Samplers a program may have (GL ES 3.0: 16 a stage).
pub const MAX_TEX = 16;
const D_W = 0; // level 0's
const D_H = 1;
const D_STRIDE = 2;
const D_FMT = 3;
const D_SWZ = 4;
const D_MODE = 5;
const D_LAST = 6;
const D_LOD = 7; // base level (0..3), last level (4..7), mipmaps (8..9: none, nearest, linear), min LINEAR (10), λ matters (11)
const D_MIN_LOD = 8; // f32
const D_MAX_LOD = 9; // f32
const D_C = 10; // f32: a λ at or below it magnifies
const D_AT = 11; // level l's byte offset at D_AT + l
pub const DESC_WORDS = D_AT + engine.MAX_LEVELS;

// D_FMT: log2 of the texel's bytes (bits 0..2), its kind (4..5), its
// channels (8..10), sRGB (12), a texture there (13)
const F_SRGB: u32 = 1 << 12;
const F_VALID: u32 = 1 << 13;
// D_SWZ: 3 bits a channel: 0..3 one of the texel's, 4 zero, 5 one
pub const SWZ_ZERO = 4;
pub const SWZ_ONE = 5;
pub const IDENTITY: u32 = 0 | 1 << 3 | 2 << 6 | 3 << 9;
// D_MODE: wrap s (bits 0..1), wrap t (4..5), magnification LINEAR (8)
const M_LINEAR: u32 = 1 << 8;
const L_MIN_LINEAR: u32 = 1 << 10;
const L_MATTERS: u32 = 1 << 11;

pub const Wrap = enum(u2) { repeat, clamp, mirror };
pub const Mip = enum(u2) { none, nearest, linear };

/// What the draw knows of a unit's texture: its image (null: none, or
/// incomplete: it reads (0, 0, 0, 1)), and its state.
pub const State = struct {
    img: ?*engine.Image = null,
    srgb: bool = false,
    /// GL's channels as the texel's (or SWZ_ZERO, SWZ_ONE), the format's
    /// swizzle (BGRA, LUMINANCE ...) and TEXTURE_SWIZZLE_* composed
    swizzle: [4]u3 = .{ 0, 1, 2, 3 },
    wrap_s: Wrap = .repeat,
    wrap_t: Wrap = .repeat,
    /// the magnification filter LINEAR
    linear: bool = false,
    /// the minification filter's: LINEAR (or *_MIPMAP_* LINEAR within a
    /// level), and between levels
    min_linear: bool = false,
    mip: Mip = .none,
    /// the levels read: base .. last (held by the image)
    base: u8 = 0,
    last: u8 = 0,
    min_lod: f32 = -1000,
    max_lod: f32 = 1000,
};

/// A texture's descriptor words.
pub fn descriptor(s: State, out: *[DESC_WORDS]u32) void {
    @memset(out, 0);
    const img = s.img orelse return;
    if (!img.live()) return;
    const fmt = img.format;
    out[D_W] = img.width;
    out[D_H] = img.height;
    out[D_STRIDE] = img.stride;
    out[D_FMT] = std.math.log2_int(u32, fmt.bytes()) | @as(u32, @intFromEnum(fmt.kind())) << 4 | fmt.channels() << 8 | F_VALID | (if (s.srgb) F_SRGB else 0);
    var swz: u32 = 0;
    for (s.swizzle, 0..) |c, i| {
        // (an image without alpha reads opaque)
        const cc: u32 = if (img.no_alpha and c == 3) SWZ_ONE else c;
        swz |= cc << @intCast(3 * i);
    }
    out[D_SWZ] = swz;
    out[D_MODE] = @as(u32, @intFromEnum(s.wrap_s)) | @as(u32, @intFromEnum(s.wrap_t)) << 4 | (if (s.linear) M_LINEAR else 0);
    out[D_LAST] = @intCast(@max(img.buf.cpu.len / 4, 1) - 1);
    const matters = s.mip != .none or s.min_linear != s.linear;
    out[D_LOD] = @as(u32, s.base) | @as(u32, s.last) << 4 | @as(u32, @intFromEnum(s.mip)) << 8 | (if (s.min_linear) L_MIN_LINEAR else 0) | (if (matters) L_MATTERS else 0);
    out[D_MIN_LOD] = @bitCast(s.min_lod);
    out[D_MAX_LOD] = @bitCast(s.max_lod);
    // (GL: 0.5 when magnifying LINEAR and minifying NEAREST_MIPMAP_*)
    out[D_C] = @bitCast(@as(f32, if (s.linear and s.mip != .none and !s.min_linear) 0.5 else 0));
    for (0..img.levels) |l| out[D_AT + l] = img.level_at[l];
}

/// What a sampler returns: floats, or int or uint bits.
pub const Kind = enum { float, int, uint };

/// Where a texture is: its binding, its descriptor's first word in the
/// uniform binding `uni`.
pub const Slot = struct { b: u8, uni: u8, word: u32 };

const D = struct { w: V, h: V, stride: V, fmt: V, swz: V, mode: V, last: V };

fn descWord(k: *kir.Kernel, s: Slot, i: u32) V {
    return descWordAs(k, s, i, .u32);
}

fn descWordAs(k: *kir.Kernel, s: Slot, i: u32, t: kir.Ty) V {
    var m = kir.global(s.uni, 32);
    m.imm = @intCast((s.word + i) * 4);
    return k.load(t, m, u(0));
}

fn loadDesc(k: *kir.Kernel, s: Slot) D {
    return .{ .w = descWord(k, s, D_W), .h = descWord(k, s, D_H), .stride = descWord(k, s, D_STRIDE), .fmt = descWord(k, s, D_FMT), .swz = descWord(k, s, D_SWZ), .mode = descWord(k, s, D_MODE), .last = descWord(k, s, D_LAST) };
}

/// A level's place: its byte offset, size and row stride.
const Lvl = struct { off: V, w: V, h: V, stride: V };

/// Level `l` (u32) of the texture.
fn levelOf(k: *kir.Kernel, s: Slot, d: D, l: V) Lvl {
    const w = k.op2(.imax, .u32, r(k.op2(.shr, .u32, r(d.w), r(l))), u(1));
    const h = k.op2(.imax, .u32, r(k.op2(.shr, .u32, r(d.h), r(l))), u(1));
    const sh = k.op3(.bfe, .u32, r(d.fmt), u(0), u(3));
    const packed_stride = k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(w), r(sh))), u(3))), u(0xffff_fffc));
    const is0 = k.cmp(.u32, .eq, r(l), u(0));
    var m = kir.global(s.uni, 32);
    m.imm = @intCast((s.word + D_AT) * 4);
    const off = k.load(.u32, m, r(k.op2(.shl, .u32, r(l), u(2))));
    return .{ .off = off, .w = w, .h = h, .stride = k.sel(.u32, r(is0), r(d.stride), r(packed_stride)) };
}

fn one(kind: Kind) Arg {
    return if (kind == .float) f(1) else u(1);
}

fn ty(kind: Kind) kir.Ty {
    return switch (kind) {
        .float => .f32,
        .int => .i32,
        .uint => .u32,
    };
}

/// Texel (x, y) (u32, inside the level) as its channels (missing ones 0,
/// 0, 0, 1), sRGB decoded, before the swizzle.
fn texel(k: *kir.Kernel, b: u8, d: D, lv: Lvl, x: Arg, y: Arg, kind: Kind) [4]Arg {
    const shift = k.op3(.bfe, .u32, r(d.fmt), u(0), u(3));
    const addr = k.op2(.iadd, .u32, r(lv.off), r(k.op3(.imad, .u32, y, r(lv.stride), r(k.op2(.shl, .u32, x, r(shift))))));
    const w0 = k.op2(.shr, .u32, r(addr), u(2));
    var words: [4]V = undefined;
    for (&words, 0..) |*w, i| {
        const at = k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(w0), u(@intCast(i)))), r(d.last));
        w.* = k.load(.u32, kir.global(b, 32), r(k.op2(.shl, .u32, r(at), u(2))));
    }
    const channels = k.op3(.bfe, .u32, r(d.fmt), u(8), u(3));
    var out: [4]Arg = undefined;
    if (kind != .float) {
        for (&out, 0..) |*o, c| {
            const have = k.cmp(.u32, .gt, r(channels), u(@intCast(c)));
            o.* = r(k.sel(ty(kind), r(have), r(words[c]), if (c == 3) one(kind) else u(0)));
        }
        return out;
    }
    const unorm = k.cmp(.u32, .eq, r(k.op3(.bfe, .u32, r(d.fmt), u(4), u(2))), u(0));
    const byte0 = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(addr), u(3))), u(3));
    const srgb = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_SRGB))), u(0));
    for (&out, 0..) |*o, c| {
        const byte = k.op3(.bfe, .u32, r(words[0]), r(k.op2(.iadd, .u32, r(byte0), u(@intCast(8 * c)))), u(8));
        // (times 1/255, not a division: an exact division keeps registers
        // in a loop on ir3; the same bits on every device all the same)
        var un = k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(byte))), f(1.0 / 255.0));
        if (c < 3) un = srgbToLinear(k, un, srgb);
        const v = k.sel(.f32, r(unorm), r(un), r(k.mov(.f32, r(words[c]))));
        const have = k.cmp(.u32, .gt, r(channels), u(@intCast(c)));
        o.* = r(k.sel(.f32, r(have), r(v), if (c == 3) f(1) else f(0)));
    }
    return out;
}

/// sRGB's decode where `on`: c / 12.92, or ((c + 0.055) / 1.055)^2.4.
fn srgbToLinear(k: *kir.Kernel, c: V, on: V) V {
    const lo = k.op2(.fmul, .f32, r(c), f(1.0 / 12.92));
    const base = k.op2(.fmul, .f32, r(k.op2(.fadd, .f32, r(c), f(0.055))), f(1.0 / 1.055));
    const hi = k.op1(.fexp2, .f32, r(k.op2(.fmul, .f32, r(k.op1(.flog2, .f32, r(base))), f(2.4))));
    const lin = k.sel(.f32, r(k.cmp(.f32, .le, r(c), f(0.04045))), r(lo), r(hi));
    return k.sel(.f32, r(on), r(lin), r(c));
}

/// The swizzle, and (0, 0, 0, 1) where no texture is bound.
fn finish(k: *kir.Kernel, d: D, raw: [4]Arg, kind: Kind) [4]Arg {
    const t = ty(kind);
    const valid = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_VALID))), u(0));
    var out: [4]Arg = undefined;
    for (&out, 0..) |*o, c| {
        const code = k.op3(.bfe, .u32, r(d.swz), u(@intCast(3 * c)), u(3));
        var v: Arg = if (kind == .float) f(0) else u(0);
        v = r(k.sel(t, r(k.cmp(.u32, .eq, r(code), u(SWZ_ONE))), one(kind), v));
        var ch: usize = 4;
        while (ch > 0) {
            ch -= 1;
            v = r(k.sel(t, r(k.cmp(.u32, .eq, r(code), u(@intCast(ch)))), raw[ch], v));
        }
        o.* = r(k.sel(t, r(valid), v, if (c == 3) one(kind) else (if (kind == .float) f(0) else u(0))));
    }
    return out;
}

/// An integer-valued float wrapped into [0, size - 1] by the mode (0
/// repeat, 1 clamp, 2 mirrored repeat): exact (the approximate reciprocal
/// corrected).
fn wrap(k: *kir.Kernel, x: V, n: V, mode: V) V {
    const last = k.op2(.fsub, .f32, r(n), f(1));
    const clamped = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(x), f(0))), r(last));
    const modOf = struct {
        fn m(kk: *kir.Kernel, xx: V, p: V) V {
            const q = kk.op1(.ffloor, .f32, r(kk.op2(.fmul, .f32, r(xx), r(kk.op1(.frcp, .f32, r(p))))));
            var rem = kk.op2(.fsub, .f32, r(xx), r(kk.op2(.fmul, .f32, r(q), r(p))));
            rem = kk.sel(.f32, r(kk.cmp(.f32, .lt, r(rem), f(0))), r(kk.op2(.fadd, .f32, r(rem), r(p))), r(rem));
            return kk.sel(.f32, r(kk.cmp(.f32, .ge, r(rem), r(p))), r(kk.op2(.fsub, .f32, r(rem), r(p))), r(rem));
        }
    }.m;
    const rep = modOf(k, x, n);
    const twice = k.op2(.fadd, .f32, r(n), r(n));
    const m2 = modOf(k, x, twice);
    const mir = k.sel(.f32, r(k.cmp(.f32, .lt, r(m2), r(n))), r(m2), r(k.op2(.fsub, .f32, r(k.op2(.fsub, .f32, r(twice), f(1))), r(m2))));
    const v = k.sel(.f32, r(k.cmp(.u32, .eq, r(mode), u(1))), r(clamped), r(k.sel(.f32, r(k.cmp(.u32, .eq, r(mode), u(2))), r(mir), r(rep))));
    // (inside whatever came: an index past the image is never read)
    return k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(v), f(0))), r(last));
}

/// How a sample's level of detail comes.
pub const Lod = union(enum) {
    /// none (a vertex shader's implicit one): the base level, magnified
    base,
    /// from the derivatives of (s, t) across and up (a fragment shader's
    /// implicit LOD, textureGrad's), plus a bias
    grad: struct { dsdx: Arg, dtdx: Arg, dsdy: Arg, dtdy: Arg, bias: Arg },
    /// given (textureLod)
    level: Arg,
};

/// texture(): (s, t) in [0, 1] across the image, its level and filter as
/// `lod` and the descriptor say (nearest, bilinear, or trilinear between
/// two levels), wrapped; `off` in texels (textureOffset). Integer
/// textures: the base level, nearest.
pub fn sample(k: *kir.Kernel, slot: Slot, s: Arg, t: Arg, kind: Kind, off: [2]i32, lod: Lod) [4]Arg {
    const d = loadDesc(k, slot);
    const lw = descWord(k, slot, D_LOD);
    const base = k.op3(.bfe, .u32, r(lw), u(0), u(4));
    if (kind != .float) {
        const raw = sampleLevel(k, slot, d, levelOf(k, slot, d, base), s, t, k.mov(.pred, u(0)), kind, off);
        return finish(k, d, raw, kind);
    }
    const last = k.op3(.bfe, .u32, r(lw), u(4), u(4));
    const mip = k.op3(.bfe, .u32, r(lw), u(8), u(2));
    // λ, clamped to the LOD range
    const lam = k.reg(.f32);
    k.set(lam, .mov, f(-1e30), no, no);
    switch (lod) {
        .base => {},
        .level => |x| k.set(lam, .mov, x, no, no),
        .grad => |gd| {
            // (only where it can matter: mipmaps, or two filters)
            k.ifp(r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(lw), u(L_MATTERS))), u(0))));
            {
                const wb = k.cvt(.u32, .f32, .rne, r(k.op2(.imax, .u32, r(k.op2(.shr, .u32, r(d.w), r(base))), u(1))));
                const hb = k.cvt(.u32, .f32, .rne, r(k.op2(.imax, .u32, r(k.op2(.shr, .u32, r(d.h), r(base))), u(1))));
                const sq = struct {
                    fn f_(kk: *kir.Kernel, a: Arg, sz: V) V {
                        const v = kk.op2(.fmul, .f32, a, r(sz));
                        return kk.op2(.fmul, .f32, r(v), r(v));
                    }
                }.f_;
                const rx = k.op2(.fadd, .f32, r(sq(k, gd.dsdx, wb)), r(sq(k, gd.dtdx, hb)));
                const ry = k.op2(.fadd, .f32, r(sq(k, gd.dsdy, wb)), r(sq(k, gd.dtdy, hb)));
                // λ = log2 ρ = log2(ρ²) / 2 (ρ² 0: -inf, magnified)
                const l2 = k.op1(.flog2, .f32, r(k.op2(.fmax, .f32, r(rx), r(ry))));
                k.set(lam, .fadd, r(k.op2(.fmul, .f32, r(l2), f(0.5))), gd.bias, no);
            }
            k.endif();
        },
    }
    const lam_c = k.op2(.fmax, .f32, r(k.op2(.fmin, .f32, r(lam), r(descWordAs(k, slot, D_MAX_LOD, .f32)))), r(descWordAs(k, slot, D_MIN_LOD, .f32)));
    const mag = k.cmp(.f32, .le, r(lam_c), r(descWordAs(k, slot, D_C, .f32)));
    const mag_linear = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.mode), u(M_LINEAR))), u(0));
    const min_linear = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(lw), u(L_MIN_LINEAR))), u(0));
    const linear = k.sel(.pred, r(mag), r(mag_linear), r(min_linear));
    // the levels: the nearest (λ <= 1/2: the base; else ceil(λ + 1/2) - 1),
    // or floor(λ) and the next with λ's fraction; never past the last
    const nomip = k.op2(.por, .pred, r(mag), r(k.cmp(.u32, .eq, r(mip), u(0))));
    const lam_f = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(lam_c), f(0))), f(15));
    const up = k.op2(.fsub, .f32, r(k.op1(.fceil, .f32, r(k.op2(.fadd, .f32, r(lam_f), f(0.5))))), f(1));
    const near_rel = k.sel(.f32, r(k.cmp(.f32, .le, r(lam_f), f(0.5))), f(0), r(up));
    const fl = k.op1(.ffloor, .f32, r(lam_f));
    const frac = k.op2(.fsub, .f32, r(lam_f), r(fl));
    const at = struct {
        fn f_(kk: *kir.Kernel, b: V, rel: V, l: V) V {
            return kk.op2(.imin, .u32, r(kk.op2(.iadd, .u32, r(b), r(kk.cvt(.f32, .u32, .rz, r(rel))))), r(l));
        }
    }.f_;
    const d1 = at(k, base, fl, last);
    const d2 = k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(d1), u(1))), r(last));
    const lin_mip = k.cmp(.u32, .eq, r(mip), u(2));
    const level1 = k.sel(.u32, r(nomip), r(base), r(k.sel(.u32, r(lin_mip), r(d1), r(at(k, base, near_rel, last)))));
    // one level's read, or (trilinear) two in a loop's two passes, each
    // weighted: the code of one read either way
    const tri = k.op2(.pand, .pred, r(k.op1(.pnot, .pred, r(nomip))), r(k.op2(.pand, .pred, r(lin_mip), r(k.cmp(.u32, .ne, r(d2), r(d1))))));
    const lvl = k.reg(.u32);
    k.set(lvl, .mov, r(level1), no, no);
    const wgt = k.reg(.f32);
    k.set(wgt, .sel, r(k.op2(.fsub, .f32, f(1), r(frac))), f(1), r(tri));
    const second = k.reg(.pred);
    k.set(second, .mov, u(0), no, no);
    var outv: [4]V = undefined;
    for (&outv) |*o| {
        o.* = k.reg(.f32);
        k.set(o.*, .mov, f(0), no, no);
    }
    k.loop();
    {
        const cv = sampleLevel(k, slot, d, levelOf(k, slot, d, lvl), s, t, linear, kind, off);
        // (one level: the read itself, not a blend: inf and NaN survive)
        for (outv, 0..) |o, c| k.set(o, .sel, r(k.op2(.fadd, .f32, r(o), r(k.op2(.fmul, .f32, cv[c], r(wgt))))), cv[c], r(tri));
        k.brk(r(k.op2(.por, .pred, r(k.op1(.pnot, .pred, r(tri))), r(second))));
        k.set(second, .mov, u(1), no, no);
        k.set(lvl, .mov, r(d2), no, no);
        k.set(wgt, .mov, r(frac), no, no);
    }
    k.endloop();
    var out: [4]Arg = undefined;
    for (outv, 0..) |o, c| out[c] = r(o);
    return finish(k, d, out, kind);
}

/// One level's sample: (s, t) in [0, 1] across it, nearest or bilinear
/// (`linear`), wrapped, `off` added: its channels before the swizzle.
fn sampleLevel(k: *kir.Kernel, slot: Slot, d: D, lv: Lvl, s: Arg, t: Arg, linear: V, kind: Kind, off: [2]i32) [4]Arg {
    const wf = k.cvt(.u32, .f32, .rne, r(lv.w));
    const hf = k.cvt(.u32, .f32, .rne, r(lv.h));
    const half = k.sel(.f32, r(linear), f(0.5), f(0));
    const tx = k.op2(.fsub, .f32, r(k.op2(.fmul, .f32, s, r(wf))), r(half));
    const ty_ = k.op2(.fsub, .f32, r(k.op2(.fmul, .f32, t, r(hf))), r(half));
    var x0 = k.op1(.ffloor, .f32, r(tx));
    var y0 = k.op1(.ffloor, .f32, r(ty_));
    const fx = k.op2(.fsub, .f32, r(tx), r(x0));
    const fy = k.op2(.fsub, .f32, r(ty_), r(y0));
    if (off[0] != 0) x0 = k.op2(.fadd, .f32, r(x0), f(@floatFromInt(off[0])));
    if (off[1] != 0) y0 = k.op2(.fadd, .f32, r(y0), f(@floatFromInt(off[1])));
    const ws = k.op3(.bfe, .u32, r(d.mode), u(0), u(2));
    const wt = k.op3(.bfe, .u32, r(d.mode), u(4), u(2));
    const idx = struct {
        fn i(kk: *kir.Kernel, v: V) Arg {
            return r(kk.cvt(.f32, .u32, .rz, r(v)));
        }
    }.i;
    const xa = idx(k, wrap(k, x0, wf, ws));
    const ya = idx(k, wrap(k, y0, hf, wt));
    const t00 = texel(k, slot.b, d, lv, xa, ya, kind);
    if (kind != .float) return t00;
    const xb = idx(k, wrap(k, k.op2(.fadd, .f32, r(x0), f(1)), wf, ws));
    const yb = idx(k, wrap(k, k.op2(.fadd, .f32, r(y0), f(1)), hf, wt));
    const t10 = texel(k, slot.b, d, lv, xb, ya, kind);
    const t01 = texel(k, slot.b, d, lv, xa, yb, kind);
    const t11 = texel(k, slot.b, d, lv, xb, yb, kind);
    const gx = k.op2(.fsub, .f32, f(1), r(fx));
    const gy = k.op2(.fsub, .f32, f(1), r(fy));
    var out: [4]Arg = undefined;
    for (&out, 0..) |*o, c| {
        const top = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, t00[c], r(gx))), r(k.op2(.fmul, .f32, t10[c], r(fx))));
        const bot = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, t01[c], r(gx))), r(k.op2(.fmul, .f32, t11[c], r(fx))));
        const lerped = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(top), r(gy))), r(k.op2(.fmul, .f32, r(bot), r(fy))));
        // (nearest: the texel itself, not a blend with weight 0: inf and NaN survive)
        o.* = r(k.sel(.f32, r(linear), r(lerped), t00[c]));
    }
    return out;
}

/// The level `lod` (an int) past the base, at most the last.
fn levelAt(k: *kir.Kernel, slot: Slot, lod: Arg) V {
    const lw = descWord(k, slot, D_LOD);
    const rel = k.op2(.imax, .i32, lod, u(0));
    return k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(k.op3(.bfe, .u32, r(lw), u(0), u(4))), r(rel))), r(k.op3(.bfe, .u32, r(lw), u(4), u(4))));
}

/// texelFetch(): texel (x, y) of level `lod` past the base (ints; clamped
/// inside the level), `off` added.
pub fn fetch(k: *kir.Kernel, slot: Slot, x: Arg, y: Arg, kind: Kind, off: [2]i32, lod: Arg) [4]Arg {
    const d = loadDesc(k, slot);
    const lv = levelOf(k, slot, d, levelAt(k, slot, lod));
    const cl = struct {
        fn c(kk: *kir.Kernel, v: Arg, o: i32, n: V) Arg {
            const moved = if (o != 0) r(kk.op2(.iadd, .i32, v, u(@bitCast(o)))) else v;
            const last = kk.op2(.isub, .i32, r(n), u(1));
            return r(kk.op2(.imax, .i32, r(kk.op2(.imin, .i32, moved, r(last))), u(0)));
        }
    }.c;
    const raw = texel(k, slot.b, d, lv, cl(k, x, off[0], lv.w), cl(k, y, off[1], lv.h), kind);
    return finish(k, d, raw, kind);
}

/// textureSize(): level `lod`'s (past the base) width and height (ints;
/// at least 1, 0 without a texture).
pub fn size(k: *kir.Kernel, slot: Slot, lod: Arg) [2]Arg {
    const d = loadDesc(k, slot);
    const valid = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_VALID))), u(0));
    const base = k.op3(.bfe, .u32, r(descWord(k, slot, D_LOD)), u(0), u(4));
    const l = k.op2(.iadd, .u32, r(base), lod);
    var out: [2]Arg = undefined;
    for ([_]V{ d.w, d.h }, 0..) |v, i| {
        const s = k.op2(.imax, .u32, r(k.op2(.shr, .u32, r(v), r(l))), u(1));
        out[i] = r(k.sel(.u32, r(valid), r(s), u(0)));
    }
    return out;
}

test "texture: a descriptor's words" {
    var buf: [64]u8 = undefined;
    var img = engine.Image{ .buf = .{ .cpu = &buf }, .width = 4, .height = 2, .stride = 8, .format = .rg8 };
    var w: [DESC_WORDS]u32 = undefined;
    descriptor(.{ .img = &img, .swizzle = .{ 0, 0, 0, 1 }, .wrap_s = .clamp, .linear = true }, &w);
    try std.testing.expectEqual(@as(u32, 4), w[D_W]);
    try std.testing.expectEqual(@as(u32, 8), w[D_STRIDE]);
    // two bytes (log2 1), unorm, two channels, valid
    try std.testing.expectEqual(@as(u32, 1 | 2 << 8 | F_VALID), w[D_FMT]);
    try std.testing.expectEqual(@as(u32, 0 | 0 << 3 | 0 << 6 | 1 << 9), w[D_SWZ]);
    try std.testing.expectEqual(@as(u32, 1 | M_LINEAR), w[D_MODE]);
    try std.testing.expectEqual(@as(u32, 15), w[D_LAST]);
    descriptor(.{}, &w);
    try std.testing.expectEqual(@as(u32, 0), w[D_FMT]);
}
