//! @zpm/gfxapi texture — a draw's texture reads in KIR: texelFetch, the
//! sampled read (nearest or bilinear, each axis wrapped: repeat, clamp to
//! edge, mirrored repeat), textureSize. Every float operation is one KIR
//! defines bit for bit, so a sample is the same on every GPU and on the
//! CPU (sRGB's decode apart: it uses exp2 and log2).
//!
//! A texture is a binding (its image's memory) and a descriptor of
//! DESC_WORDS words in the uniform binding, which the draw fills from the
//! GL state of the texture's unit (`descriptor`): its size, row stride,
//! format (texel bytes, kind, channels, sRGB), a swizzle, wrap modes and
//! filter. One code reads every format: a texel is up to four aligned
//! words (clamped inside the image: no read past it), its channels taken
//! as the format says. So a program's code does not depend on what is
//! bound to its samplers.
//!
//! Not yet: mipmaps (level 0 is read, with the magnification filter),
//! cube maps, 3D and array textures, shadow comparisons.

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
pub const DESC_WORDS = 8;
const D_W = 0;
const D_H = 1;
const D_STRIDE = 2;
const D_FMT = 3;
const D_SWZ = 4;
const D_MODE = 5;
const D_LAST = 6;

// D_FMT: log2 of the texel's bytes (bits 0..2), its kind (4..5), its
// channels (8..10), sRGB (12), a texture there (13)
const F_SRGB: u32 = 1 << 12;
const F_VALID: u32 = 1 << 13;
// D_SWZ: 3 bits a channel: 0..3 one of the texel's, 4 zero, 5 one
pub const SWZ_ZERO = 4;
pub const SWZ_ONE = 5;
pub const IDENTITY: u32 = 0 | 1 << 3 | 2 << 6 | 3 << 9;
// D_MODE: wrap s (bits 0..1), wrap t (4..5), bilinear (8)
const M_LINEAR: u32 = 1 << 8;

pub const Wrap = enum(u2) { repeat, clamp, mirror };

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
    linear: bool = false,
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
}

/// What a sampler returns: floats, or int or uint bits.
pub const Kind = enum { float, int, uint };

/// Where a texture is: its binding, its descriptor's first word in the
/// uniform binding `uni`.
pub const Slot = struct { b: u8, uni: u8, word: u32 };

const D = struct { w: V, h: V, stride: V, fmt: V, swz: V, mode: V, last: V };

fn loadDesc(k: *kir.Kernel, s: Slot) D {
    const at = struct {
        fn w(kk: *kir.Kernel, ss: Slot, i: u32) V {
            var m = kir.global(ss.uni, 32);
            m.imm = @intCast((ss.word + i) * 4);
            return kk.load(.u32, m, u(0));
        }
    }.w;
    return .{ .w = at(k, s, D_W), .h = at(k, s, D_H), .stride = at(k, s, D_STRIDE), .fmt = at(k, s, D_FMT), .swz = at(k, s, D_SWZ), .mode = at(k, s, D_MODE), .last = at(k, s, D_LAST) };
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

/// Texel (x, y) (u32, inside the image) as its channels (missing ones 0,
/// 0, 0, 1), sRGB decoded, before the swizzle.
fn texel(k: *kir.Kernel, b: u8, d: D, x: Arg, y: Arg, kind: Kind) [4]Arg {
    const shift = k.op3(.bfe, .u32, r(d.fmt), u(0), u(3));
    const addr = k.op3(.imad, .u32, y, r(d.stride), r(k.op2(.shl, .u32, x, r(shift))));
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

/// texture(): (s, t) in [0, 1] across the image, nearest or bilinear,
/// wrapped; `off` in texels (textureOffset).
pub fn sample(k: *kir.Kernel, slot: Slot, s: Arg, t: Arg, kind: Kind, off: [2]i32) [4]Arg {
    const d = loadDesc(k, slot);
    const wf = k.cvt(.u32, .f32, .rne, r(d.w));
    const hf = k.cvt(.u32, .f32, .rne, r(d.h));
    // (integer textures: nearest)
    const linear = if (kind == .float) k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.mode), u(M_LINEAR))), u(0)) else k.mov(.pred, u(0));
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
    const t00 = texel(k, slot.b, d, xa, ya, kind);
    if (kind != .float) return finish(k, d, t00, kind);
    const xb = idx(k, wrap(k, k.op2(.fadd, .f32, r(x0), f(1)), wf, ws));
    const yb = idx(k, wrap(k, k.op2(.fadd, .f32, r(y0), f(1)), hf, wt));
    const t10 = texel(k, slot.b, d, xb, ya, kind);
    const t01 = texel(k, slot.b, d, xa, yb, kind);
    const t11 = texel(k, slot.b, d, xb, yb, kind);
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
    return finish(k, d, out, kind);
}

/// texelFetch(): texel (x, y) (ints; clamped inside the image), `off`
/// added.
pub fn fetch(k: *kir.Kernel, slot: Slot, x: Arg, y: Arg, kind: Kind, off: [2]i32) [4]Arg {
    const d = loadDesc(k, slot);
    const cl = struct {
        fn c(kk: *kir.Kernel, v: Arg, o: i32, n: V) Arg {
            const moved = if (o != 0) r(kk.op2(.iadd, .i32, v, u(@bitCast(o)))) else v;
            const last = kk.op2(.isub, .i32, r(n), u(1));
            return r(kk.op2(.imax, .i32, r(kk.op2(.imin, .i32, moved, r(last))), u(0)));
        }
    }.c;
    const raw = texel(k, slot.b, d, cl(k, x, off[0], d.w), cl(k, y, off[1], d.h), kind);
    return finish(k, d, raw, kind);
}

/// textureSize(): level `lod`'s width and height (ints; at least 1, 0
/// without a texture).
pub fn size(k: *kir.Kernel, slot: Slot, lod: Arg) [2]Arg {
    const d = loadDesc(k, slot);
    const valid = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_VALID))), u(0));
    var out: [2]Arg = undefined;
    for ([_]V{ d.w, d.h }, 0..) |v, i| {
        const s = k.op2(.imax, .u32, r(k.op2(.shr, .u32, r(v), lod)), u(1));
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
