//! @zpm/gfxapi texture — a draw's texture reads in KIR: texelFetch, the
//! sampled read (nearest or bilinear, each axis wrapped: repeat, clamp to
//! edge, mirrored repeat, clamp to border), textureSize. Every float operation is one KIR
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
//! Integer textures read their base level for filtered lookups.

const std = @import("std");
const gpu = @import("gpu");
const engine = @import("engine.sig");
const blocklinear = @import("blocklinear.sig");
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
const D_LAYERS = D_AT + engine.MAX_LEVELS;
const D_IMAGE_LEVELS = D_LAYERS + 1;
/// The border color (CLAMP_TO_BORDER), in the texel's channel order: four
/// words, a float's bits or an integer's (State.border is in R, G, B, A:
/// `descriptor` stores it so).
const D_BORDER = D_IMAGE_LEVELS + 1;
pub const DESC_WORDS = D_BORDER + 4;

// D_FMT: log2 of the texel's bytes (bits 0..2), its kind (4..6:
// unorm16 is 4, its bits 4..5 reading as unorm8's and bit 6 saying two
// bytes a channel), its channels (8..10), sRGB (12), a texture there (13)
// ... block linear (15: the image's memory is NVIDIA's block-linear
// layout, D_STRIDE its pitch; its swizzle at 16..17, log2 of its blocks'
// height in GOBs at 18..20: blocklinear.sig), block-compressed (22..24:
// engine.Image.bc, the BC kind + 1; D_STRIDE a row of blocks' bytes)
const F_WIDE: u32 = 1 << 6;
const F_SRGB: u32 = 1 << 12;
const F_VALID: u32 = 1 << 13;
const F_DEPTH: u32 = 1 << 14;
const F_BLOCK: u32 = 1 << 15;
const F_BC_SHIFT = 22;
// D_SWZ: 3 bits a channel: 0..3 one of the texel's, 4 zero, 5 one
pub const SWZ_ZERO = 4;
pub const SWZ_ONE = 5;
pub const IDENTITY: u32 = 0 | 1 << 3 | 2 << 6 | 3 << 9;
// D_MODE: wrap s (bits 0..1), wrap t (4..5), wrap r (12..13), compare
// (16..18), magnification LINEAR (8)
const M_LINEAR: u32 = 1 << 8;
const L_MIN_LINEAR: u32 = 1 << 10;
const L_MATTERS: u32 = 1 << 11;

/// border: OES_texture_border_clamp's CLAMP_TO_BORDER (an axis outside
/// the level reads the border color; addressed as clamp otherwise)
pub const Wrap = enum(u2) { repeat, clamp, mirror, border };
pub const Mip = enum(u2) { none, nearest, linear };

/// What the draw knows of a unit's texture: its image (null: none, or
/// incomplete: it reads (0, 0, 0, 1)), and its state.
pub const State = struct {
    img: ?*engine.Image = null,
    layers: u32 = 1,
    srgb: bool = false,
    /// The API's channels as the format's R, G, B, A (or SWZ_ZERO,
    /// SWZ_ONE): a format's swizzle (LUMINANCE, ALPHA ...) and
    /// TEXTURE_SWIZZLE_* composed. Where the image keeps R, G, B and A in
    /// its texels (bgra8's bytes are B, G, R, A) is `descriptor`'s to add,
    /// from the image's format, never the caller's: Direct3D's B8G8R8A8
    /// textures (galaxy-pe's) were sampled with red and blue exchanged
    /// while GL and Vulkan each swapped them themselves.
    swizzle: [4]u3 = .{ 0, 1, 2, 3 },
    wrap_s: Wrap = .repeat,
    wrap_t: Wrap = .repeat,
    wrap_r: Wrap = .repeat,
    compare: u3 = 0,
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
    /// the border color: R, G, B, A (before the swizzle)
    border: [4]u32 = .{ 0, 0, 0, 0 },
};

/// Where format `fmt` keeps R, G, B and A in its texel: channel i of
/// the format is the texel's channel storedAt(fmt)[i].
pub fn storedAt(fmt: engine.Format) [4]u3 {
    return if (fmt == .bgra8) .{ 2, 1, 0, 3 } else .{ 0, 1, 2, 3 };
}

/// A texture's descriptor words.
pub fn descriptor(s: State, out: *[DESC_WORDS]u32) void {
    @memset(out, 0);
    const img = s.img orelse return;
    // (an image in GPU memory without a CPU view, as Vulkan's in VRAM, is
    // live too: its size is the buffer's)
    const bytes: u64 = if (img.buf.cpu.len != 0) img.buf.cpu.len else if (img.buf.gpu != 0) img.buf.bytes else 0;
    if (img.width == 0 or bytes == 0) return;
    // (a float depth image, engine.Image.depth_float: its depth plane read
    // as R32F, the depths themselves; its words never d24s8's)
    const fmt: @TypeOf(img.format) = if (img.depth_float) .r32f else img.format;
    out[D_W] = img.width;
    out[D_H] = img.height;
    out[D_STRIDE] = img.stride;
    out[D_FMT] = std.math.log2_int(u32, fmt.bytes()) | @as(u32, @intFromEnum(fmt.kind())) << 4 | fmt.channels() << 8 |
        F_VALID | (if (s.srgb) F_SRGB else 0) | (if (fmt == .d24s8) F_DEPTH else 0) | @as(u32, img.bc) << F_BC_SHIFT;
    if (img.layout.block) {
        out[D_FMT] |= F_BLOCK | @as(u32, @intFromEnum(img.layout.swizzle)) << 16 | @as(u32, img.layout.gobs_log2) << 18;
    }
    // (the format's R, G, B, A as the texel's channels: bgra8's B, G, R, A)
    const at = storedAt(fmt);
    var swz: u32 = 0;
    for (s.swizzle, 0..) |c, i| {
        const stored: u32 = if (c < 4) at[c] else c;
        // (an image without alpha reads opaque)
        const cc: u32 = if (img.no_alpha and stored == 3) SWZ_ONE else stored;
        swz |= cc << @intCast(3 * i);
    }
    out[D_SWZ] = swz;
    out[D_MODE] = @as(u32, @intFromEnum(s.wrap_s)) | @as(u32, @intFromEnum(s.wrap_t)) << 4 |
        @as(u32, @intFromEnum(s.wrap_r)) << 12 | @as(u32, s.compare) << 16 | (if (s.linear) M_LINEAR else 0);
    out[D_LAST] = @intCast(@min(@max(bytes / 4, 1) - 1, 0xffff_ffff));
    const matters = s.mip != .none or s.min_linear != s.linear;
    out[D_LOD] = @as(u32, s.base) | @as(u32, s.last) << 4 | @as(u32, @intFromEnum(s.mip)) << 8 | (if (s.min_linear) L_MIN_LINEAR else 0) | (if (matters) L_MATTERS else 0);
    out[D_MIN_LOD] = @bitCast(s.min_lod);
    out[D_MAX_LOD] = @bitCast(s.max_lod);
    // (GL: 0.5 when magnifying LINEAR and minifying NEAREST_MIPMAP_*)
    out[D_C] = @bitCast(@as(f32, if (s.linear and s.mip != .none and !s.min_linear) 0.5 else 0));
    for (0..img.levels) |l| out[D_AT + l] = img.level_at[l];
    out[D_LAYERS] = s.layers;
    out[D_IMAGE_LEVELS] = img.levels;
    for (s.border, at) |w, c| out[D_BORDER + @as(u32, c)] = w;
}

/// What a sampler returns: floats, or int or uint bits.
pub const Kind = enum { float, int, uint };

/// Where a texture is: its binding, its descriptor's first word in the
/// uniform binding `uni`.
pub const Slot = struct { b: u8, uni: u8, word: u32, volume: bool = false, cube: bool = false, offset_z: i32 = 0, shadow: ?Arg = null };

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

/// A level's place: its byte offset, size and row stride, and the rows
/// of memory a layer of it takes (its height; a block-compressed level's
/// rows of blocks).
const Lvl = struct { off: V, w: V, h: V, stride: V, rows: V };

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
    // (block-compressed: a row of blocks, 8 or 16 bytes each)
    const bck = k.op3(.bfe, .u32, r(d.fmt), u(F_BC_SHIFT), u(3));
    const block_stride = k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(k.op2(.iadd, .u32, r(w), u(3))), u(2))), r(bcBlockShift(k, bck)));
    const stride = k.sel(.u32, r(is0), r(d.stride), r(packed_stride));
    const is_bc = k.cmp(.u32, .ne, r(bck), u(0));
    const rows = k.sel(.u32, r(is_bc), r(k.op2(.shr, .u32, r(k.op2(.iadd, .u32, r(h), u(3))), u(2))), r(h));
    return .{ .off = off, .w = w, .h = h, .stride = k.sel(.u32, r(is_bc), r(block_stride), r(stride)), .rows = rows };
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
/// 0, 0, 1), sRGB decoded, before the swizzle. `with_bc`: a
/// block-compressed image's texel decoded here too (else the caller
/// decodes it: sampleLevel, its four taps in one loop).
fn texel(k: *kir.Kernel, b: u8, d: D, lv: Lvl, x: Arg, y: Arg, kind: Kind, with_bc: bool) [4]Arg {
    const shift = k.op3(.bfe, .u32, r(d.fmt), u(0), u(3));
    const xb = k.op2(.shl, .u32, x, r(shift));
    // pitch linear, or (a video decoder's picture, imported with NVIDIA's
    // modifier) the GOB the texel is in and its place in it: a branch on
    // the descriptor, so every lane takes the same way
    const addr = k.reg(.u32);
    k.set(addr, .iadd, r(lv.off), r(k.op3(.imad, .u32, y, r(lv.stride), r(xb))), kir.no);
    k.ifp(r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_BLOCK))), u(0))));
    {
        const swz = k.op3(.bfe, .u32, r(d.fmt), u(16), u(2));
        const gobs = k.op3(.bfe, .u32, r(d.fmt), u(18), u(3));
        const at = blocklinear.address(k, r(lv.stride), r(gobs), r(swz), r(xb), y);
        k.set(addr, .iadd, r(lv.off), r(at), kir.no);
    }
    k.endif();
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
    const wide = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_WIDE))), u(0));
    for (&out, 0..) |*o, c| {
        const byte = k.op3(.bfe, .u32, r(words[0]), r(k.op2(.iadd, .u32, r(byte0), u(@intCast(8 * c)))), u(8));
        // (times 1/255, not a division: an exact division keeps registers
        // in a loop on ir3; the same bits on every device all the same)
        var un = k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(byte))), f(1.0 / 255.0));
        if (c < 3) un = srgbToLinear(k, un, srgb);
        if (c < 2) {
            // unorm16 (R16, GR1616): two bytes a channel, times 1/65535;
            // an R16's texel at byte 0 or 2 of its word, a GR1616's G at 2
            // (the offset masked to 0 or 16: one shift-and-mask on ir3)
            const at: Arg = if (c == 0) r(k.op2(.@"and", .u32, r(byte0), u(16))) else u(16);
            const half = k.op3(.bfe, .u32, r(words[0]), at, u(16));
            const un16 = k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(half))), f(1.0 / 65535.0));
            un = k.sel(.f32, r(wide), r(un16), r(un));
        }
        var v = k.sel(.f32, r(unorm), r(un), r(k.mov(.f32, r(words[c]))));
        if (c == 0) {
            const depth = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_DEPTH))), u(0));
            v = k.sel(.f32, r(depth), r(unpackDepth(k, words[0])), r(v));
        }
        const have = k.cmp(.u32, .gt, r(channels), u(@intCast(c)));
        o.* = r(k.sel(.f32, r(have), r(v), if (c == 3) f(1) else f(0)));
    }
    if (!with_bc) return out;
    // (a block-compressed image: the texel decoded from its block, a
    // branch on the descriptor as the layouts' are)
    const bck = k.op3(.bfe, .u32, r(d.fmt), u(F_BC_SHIFT), u(3));
    var regs: [4]V = undefined;
    for (&regs, out) |*g, o| {
        g.* = k.reg(.f32);
        k.set(g.*, .mov, o, no, no);
    }
    k.ifp(r(k.cmp(.u32, .ne, r(bck), u(0))));
    {
        const v = bcTexel(k, b, d, lv, x, y, bck, srgb);
        for (regs, v) |g, val| k.set(g, .mov, r(val), no, no);
    }
    k.endif();
    var res: [4]Arg = undefined;
    for (&res, regs) |*o, g| o.* = r(g);
    return res;
}

/// log2 of a block's bytes for BC kind + 1 `bck` (3: BC1 and BC4; 4).
fn bcBlockShift(k: *kir.Kernel, bck: V) V {
    const is8 = k.op2(.por, .pred, r(k.cmp(.u32, .eq, r(bck), u(1))), r(k.cmp(.u32, .lt, r(k.op2(.isub, .u32, r(bck), u(4))), u(2))));
    return k.sel(.u32, r(is8), u(3), u(4));
}

/// x / d for the divisors BC's palettes take (3, 5, 7), as
/// (x * ceil(2^20 / d)) >> 20: exact for every x they meet (x < 1800).
fn divBy(k: *kir.Kernel, x: Arg, m: Arg) V {
    return k.op2(.shr, .u32, r(k.op2(.imul, .u32, x, m)), u(20));
}
const DIV3: u32 = 349526;
const DIV5: u32 = 209716;
const DIV7: u32 = 149797;

/// A 5- or 6-bit channel to 8 bits (its top bits repeated).
fn expand(k: *kir.Kernel, v: V, bits: u32) V {
    return k.op2(.@"or", .u32, r(k.op2(.shl, .u32, r(v), u(8 - bits))), r(k.op2(.shr, .u32, r(v), u(2 * bits - 8))));
}

/// Texel `ti` (0..15) of an alpha block in words wa, wb (BC3's alpha, BC4,
/// BC5's channels): its value, 0..255, or -127..127 where `sgn` (BC4 and
/// BC5 signed; -128 reads as -127), as an i32. The Direct3D 11 spec's
/// palette: eight values, or six and the two ends (0 and 255, or -127
/// and 127), each rounded toward zero as bc.sig's decoder does.
fn alphaBlock(k: *kir.Kernel, wa: V, wb: V, ti: V, sgn: V) V {
    const lo127 = kir.i(-127);
    const s0 = k.op2(.imax, .i32, r(k.op3(.bfe, .i32, r(wa), u(0), u(8))), lo127);
    const s1 = k.op2(.imax, .i32, r(k.op3(.bfe, .i32, r(wa), u(8), u(8))), lo127);
    const a0 = k.sel(.i32, r(sgn), r(s0), r(k.op3(.bfe, .u32, r(wa), u(0), u(8))));
    const a1 = k.sel(.i32, r(sgn), r(s1), r(k.op3(.bfe, .u32, r(wa), u(8), u(8))));
    // (its 3-bit index at bit 16 + 3 ti of the 64 bits, perhaps across both words)
    const p = k.op3(.imad, .u32, r(ti), u(3), u(16));
    const pl = k.op2(.imin, .u32, r(p), u(31));
    const vlo = k.op2(.@"or", .u32, r(k.op2(.shr, .u32, r(wa), r(pl))), r(k.op2(.shl, .u32, r(wb), r(k.op2(.isub, .u32, u(32), r(pl))))));
    const vhi = k.op2(.shr, .u32, r(wb), r(k.op2(.isub, .u32, r(k.op2(.imax, .u32, r(p), u(32))), u(32))));
    const idx = k.op2(.@"and", .u32, r(k.sel(.u32, r(k.cmp(.u32, .lt, r(p), u(32))), r(vlo), r(vhi))), u(7));
    const gt = k.cmp(.i32, .gt, r(a0), r(a1));
    const m = k.sel(.u32, r(gt), u(7), u(5));
    const t = k.op2(.isub, .u32, r(idx), u(1));
    const n = k.op2(.iadd, .i32, r(k.op2(.imul, .i32, r(k.op2(.isub, .u32, r(m), r(t))), r(a0))), r(k.op2(.imul, .i32, r(t), r(a1))));
    const q = divBy(k, r(k.op1(.iabs, .i32, r(n))), r(k.sel(.u32, r(gt), u(DIV7), u(DIV5))));
    const qs = k.sel(.i32, r(k.cmp(.i32, .lt, r(n), kir.i(0))), r(k.op1(.ineg, .i32, r(q))), r(q));
    const ends = k.op2(.pand, .pred, r(k.op1(.pnot, .pred, r(gt))), r(k.cmp(.u32, .ge, r(idx), u(6))));
    const lo = k.sel(.i32, r(sgn), lo127, kir.i(0));
    const hi = k.sel(.i32, r(sgn), kir.i(127), kir.i(255));
    var v = k.sel(.i32, r(ends), r(k.sel(.i32, r(k.cmp(.u32, .eq, r(idx), u(6))), r(lo), r(hi))), r(qs));
    v = k.sel(.i32, r(k.cmp(.u32, .eq, r(idx), u(1))), r(a1), r(v));
    return k.sel(.i32, r(k.cmp(.u32, .eq, r(idx), u(0))), r(a0), r(v));
}

/// Texel (x, y) of a block-compressed level (bck: BC kind + 1) as R, G, B,
/// A floats: BC1 to BC3's colours (and sRGB's decode where `srgb`), BC4's
/// and BC5's channels (B 0, A 1), the same values bc.sig's decoder gives
/// (its bytes times 1/255; a signed channel's value times 1/127).
fn bcTexel(k: *kir.Kernel, b: u8, d: D, lv: Lvl, x: Arg, y: Arg, bck: V, srgb: V) [4]V {
    const bx = k.op2(.shr, .u32, x, u(2));
    const by = k.op2(.shr, .u32, y, u(2));
    const addr = k.op2(.iadd, .u32, r(lv.off), r(k.op3(.imad, .u32, r(by), r(lv.stride), r(k.op2(.shl, .u32, r(bx), r(bcBlockShift(k, bck)))))));
    const w0 = k.op2(.shr, .u32, r(addr), u(2));
    var w: [4]V = undefined;
    for (&w, 0..) |*wi, n| {
        const at = k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(w0), u(@intCast(n)))), r(d.last));
        wi.* = k.load(.u32, kir.global(b, 32), r(k.op2(.shl, .u32, r(at), u(2))));
    }
    const ti = k.op3(.imad, .u32, r(k.op2(.@"and", .u32, y, u(3))), u(4), r(k.op2(.@"and", .u32, x, u(3))));
    // colours: BC1's block, BC2's and BC3's second half (always four)
    const bc1 = k.cmp(.u32, .eq, r(bck), u(1));
    const cw = k.sel(.u32, r(bc1), r(w[0]), r(w[2]));
    const iw = k.sel(.u32, r(bc1), r(w[1]), r(w[3]));
    const c0 = k.op2(.@"and", .u32, r(cw), u(0xffff));
    const c1 = k.op2(.shr, .u32, r(cw), u(16));
    const four = k.op2(.por, .pred, r(k.cmp(.u32, .gt, r(c0), r(c1))), r(k.op1(.pnot, .pred, r(bc1))));
    const idx = k.op3(.bfe, .u32, r(iw), r(k.op2(.shl, .u32, r(ti), u(1))), u(2));
    const fields = [3][2]u32{ .{ 11, 5 }, .{ 5, 6 }, .{ 0, 5 } };
    var col: [3]V = undefined;
    for (&col, fields) |*c, fl| {
        const e0 = expand(k, k.op3(.bfe, .u32, r(c0), u(fl[0]), u(fl[1])), fl[1]);
        const e1 = expand(k, k.op3(.bfe, .u32, r(c1), u(fl[0]), u(fl[1])), fl[1]);
        const p2 = k.sel(.u32, r(four), r(divBy(k, r(k.op3(.imad, .u32, r(e0), u(2), r(e1))), u(DIV3))), r(k.op2(.shr, .u32, r(k.op2(.iadd, .u32, r(e0), r(e1))), u(1))));
        const p3 = k.sel(.u32, r(four), r(divBy(k, r(k.op3(.imad, .u32, r(e1), u(2), r(e0))), u(DIV3))), u(0));
        var v = k.sel(.u32, r(k.cmp(.u32, .eq, r(idx), u(2))), r(p2), r(p3));
        v = k.sel(.u32, r(k.cmp(.u32, .eq, r(idx), u(1))), r(e1), r(v));
        c.* = k.sel(.u32, r(k.cmp(.u32, .eq, r(idx), u(0))), r(e0), r(v));
    }
    // alphas: BC1's (0 for its transparent black), BC2's four bits, the
    // alpha blocks (BC3's alpha, BC4's and BC5's channels)
    const a_bc1 = k.sel(.u32, r(k.op2(.pand, .pred, r(k.op1(.pnot, .pred, r(four))), r(k.cmp(.u32, .eq, r(idx), u(3))))), u(0), u(255));
    const nib_w = k.sel(.u32, r(k.cmp(.u32, .lt, r(ti), u(8))), r(w[0]), r(w[1]));
    const a_bc2 = k.op2(.imul, .u32, r(k.op3(.bfe, .u32, r(nib_w), r(k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(ti), u(7))), u(2))), u(4))), u(17));
    const sgn = k.op2(.por, .pred, r(k.cmp(.u32, .eq, r(bck), u(5))), r(k.cmp(.u32, .eq, r(bck), u(7))));
    const ab01 = alphaBlock(k, w[0], w[1], ti, sgn);
    const ab23 = alphaBlock(k, w[2], w[3], ti, sgn);
    var a = k.sel(.u32, r(k.cmp(.u32, .eq, r(bck), u(2))), r(a_bc2), r(ab01));
    a = k.sel(.u32, r(bc1), r(a_bc1), r(a));
    const scale = k.sel(.f32, r(sgn), f(1.0 / 127.0), f(1.0 / 255.0));
    const colour = k.cmp(.u32, .le, r(bck), u(3));
    const bc5 = k.cmp(.u32, .ge, r(bck), u(6));
    const unit = f(1.0 / 255.0);
    var colf: [3]V = undefined;
    for (&colf, col) |*o, c| o.* = srgbToLinear(k, k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(c))), unit), srgb);
    const ch01 = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(ab01))), r(scale));
    const ch23 = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(ab23))), r(scale));
    const af = k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(a))), unit);
    return .{
        k.sel(.f32, r(colour), r(colf[0]), r(ch01)),
        k.sel(.f32, r(colour), r(colf[1]), r(k.sel(.f32, r(bc5), r(ch23), f(0)))),
        k.sel(.f32, r(colour), r(colf[2]), f(0)),
        k.sel(.f32, r(colour), r(af), f(1)),
    };
}

fn unpackDepth(k: *kir.Kernel, word: V) V {
    const bits = k.op3(.bfe, .u32, r(word), u(0), u(24));
    return k.op2(.fmul, .f32, r(k.cvt(.u32, .f32, .rne, r(bits))), f(1.0 / 16777215.0));
}

fn filteredTexel(k: *kir.Kernel, slot: Slot, d: D, lv: Lvl, x: Arg, y: Arg, kind: Kind, with_bc: bool) [4]Arg {
    const reference = slot.shadow orelse return texel(k, slot.b, d, lv, x, y, kind, with_bc);
    const row = k.op3(.imad, .u32, y, r(lv.stride), r(lv.off));
    const at = k.op3(.imad, .u32, x, u(4), r(row));
    const limit = k.op2(.shl, .u32, r(d.last), u(2));
    const word = k.load(.u32, kir.global(slot.b, 32), r(k.op2(.imin, .u32, r(at), r(limit))));
    // (a D24S8 image's 24 bits, or an R32F one's float: Direct3D's
    // D32_FLOAT depth seen through an R32_FLOAT view)
    const d24 = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_DEPTH))), u(0));
    const depth = k.sel(.f32, r(d24), r(unpackDepth(k, word)), r(k.mov(.f32, r(word))));
    const ref = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, reference, f(0))), f(1));
    const less = k.cmp(.f32, .lt, r(ref), r(depth));
    const greater = k.cmp(.f32, .gt, r(ref), r(depth));
    const relation = k.sel(.u32, r(less), u(1), r(k.sel(.u32, r(greater), u(4), u(2))));
    const compare = k.op3(.bfe, .u32, r(d.mode), u(16), u(3));
    const pass = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(relation), r(compare))), u(0));
    return .{ r(k.sel(.f32, r(pass), f(1), f(0))), f(0), f(0), f(1) };
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
/// repeat, 1 clamp, 2 mirrored repeat, 3 clamp to border: as clamp, the
/// border read by the caller): exact (the approximate reciprocal
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
    const clamps = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(mode), u(1))), u(0));
    const v = k.sel(.f32, r(clamps), r(clamped), r(k.sel(.f32, r(k.cmp(.u32, .eq, r(mode), u(2))), r(mir), r(rep))));
    // (inside whatever came: an index past the image is never read)
    return k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(v), f(0))), r(last));
}

/// How a sample's level of detail comes.
pub const Lod = union(enum) {
    /// none (a vertex shader's implicit one): the base level, magnified
    base,
    /// from the derivatives of (s, t) across and up (a fragment shader's
    /// implicit LOD, textureGrad's), plus a bias
    grad: struct { dsdx: Arg, dtdx: Arg, dsdy: Arg, dtdy: Arg, bias: Arg, drdx: Arg = f(0), drdy: Arg = f(0) },
    /// given (textureLod)
    level: Arg,
};

/// texture(): (s, t) in [0, 1] across the image, its level and filter as
/// `lod` and the descriptor say (nearest, bilinear, or trilinear between
/// two levels), wrapped; `off` in texels (textureOffset). Integer
/// textures: the base level, nearest.
pub fn sample(k: *kir.Kernel, slot: Slot, s: Arg, t: Arg, kind: Kind, off: [2]i32, lod: Lod) [4]Arg {
    return sampleArray(k, slot, s, t, null, kind, off, lod);
}

pub fn sampleArray(k: *kir.Kernel, slot: Slot, s: Arg, t: Arg, layer: ?Arg, kind: Kind, off: [2]i32, lod: Lod) [4]Arg {
    const d = loadDesc(k, slot);
    const slice: ?Arg = if (slot.volume or slot.cube) layer else if (layer) |z| blk: {
        const count = k.op2(.imax, .u32, r(descWord(k, slot, D_LAYERS)), u(1));
        const last = k.cvt(.u32, .f32, .rne, r(k.op2(.isub, .u32, r(count), u(1))));
        const rounded = k.op1(.ffloor, .f32, r(k.op2(.fadd, .f32, z, f(0.5))));
        const clamped = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(rounded), f(0))), r(last));
        break :blk r(k.cvt(.f32, .u32, .rz, r(clamped)));
    } else null;
    const lw = descWord(k, slot, D_LOD);
    const base = k.op3(.bfe, .u32, r(lw), u(0), u(4));
    if (kind != .float) {
        const raw = sampleLayerLevel(k, slot, d, base, slice, s, t, k.mov(.pred, u(0)), kind, off);
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
                var rx = k.op2(.fadd, .f32, r(sq(k, gd.dsdx, wb)), r(sq(k, gd.dtdx, hb)));
                var ry = k.op2(.fadd, .f32, r(sq(k, gd.dsdy, wb)), r(sq(k, gd.dtdy, hb)));
                if (slot.volume) {
                    const db = k.cvt(.u32, .f32, .rne, r(depthAt(k, slot, base)));
                    rx = k.op2(.fadd, .f32, r(rx), r(sq(k, gd.drdx, db)));
                    ry = k.op2(.fadd, .f32, r(ry), r(sq(k, gd.drdy, db)));
                }
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
        const cv = sampleLayerLevel(k, slot, d, lvl, slice, s, t, linear, kind, off);
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

fn depthAt(k: *kir.Kernel, slot: Slot, level: V) V {
    const depth = descWord(k, slot, D_LAYERS);
    const n = if (slot.volume) k.op2(.shr, .u32, r(depth), r(level)) else depth;
    return k.op2(.imax, .u32, r(n), u(1));
}

/// Cube face order follows GL's +X, -X, +Y, -Y, +Z, -Z enums.
pub const CubeProjection = struct { s: Arg, t: Arg, face: Arg, inverse_major: Arg };

pub fn cubeProject(k: *kir.Kernel, x: Arg, y: Arg, z: Arg) CubeProjection {
    const ax = k.op1(.fabs, .f32, x);
    const ay = k.op1(.fabs, .f32, y);
    const az = k.op1(.fabs, .f32, z);
    const x_major = k.op2(.pand, .pred, r(k.cmp(.f32, .ge, r(ax), r(ay))), r(k.cmp(.f32, .ge, r(ax), r(az))));
    const y_major = k.cmp(.f32, .ge, r(ay), r(az));
    const major = k.sel(.f32, r(x_major), x, r(k.sel(.f32, r(y_major), y, z)));
    const neg = k.cmp(.f32, .lt, r(major), f(0));
    const axis = k.sel(.u32, r(x_major), u(0), r(k.sel(.u32, r(y_major), u(2), u(4))));
    const face = k.op2(.iadd, .u32, r(axis), r(k.sel(.u32, r(neg), u(1), u(0))));
    const nx = k.op1(.fneg, .f32, x);
    const ny = k.op1(.fneg, .f32, y);
    const nz = k.op1(.fneg, .f32, z);
    const sc = k.sel(.f32, r(x_major), r(k.sel(.f32, r(neg), z, r(nz))), r(k.sel(.f32, r(y_major), x, r(k.sel(.f32, r(neg), r(nx), x)))));
    const tc = k.sel(.f32, r(x_major), r(ny), r(k.sel(.f32, r(y_major), r(k.sel(.f32, r(neg), r(nz), z)), r(ny))));
    const mag = k.op2(.fmax, .f32, r(k.op1(.fabs, .f32, r(major))), f(1e-30));
    const inverse = k.op1(.frcp, .f32, r(mag));
    const scale = k.op2(.fmul, .f32, f(0.5), r(inverse));
    return .{ .s = r(k.op3(.fmad, .f32, r(sc), r(scale), f(0.5))), .t = r(k.op3(.fmad, .f32, r(tc), r(scale), f(0.5))), .face = r(face), .inverse_major = r(inverse) };
}

/// Project an explicit direction gradient using the selected face's frame.
pub fn cubeGradient(k: *kir.Kernel, p: CubeProjection, x: Arg, y: Arg, z: Arg) [2]Arg {
    const xf = k.cmp(.u32, .lt, p.face, u(2));
    const yf = k.cmp(.u32, .lt, p.face, u(4));
    const neg = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, p.face, u(1))), u(0));
    const nx = k.op1(.fneg, .f32, x);
    const ny = k.op1(.fneg, .f32, y);
    const nz = k.op1(.fneg, .f32, z);
    const ds = k.sel(.f32, r(xf), r(k.sel(.f32, r(neg), z, r(nz))), r(k.sel(.f32, r(yf), x, r(k.sel(.f32, r(neg), r(nx), x)))));
    const dt = k.sel(.f32, r(xf), r(ny), r(k.sel(.f32, r(yf), r(k.sel(.f32, r(neg), r(nz), z)), r(ny))));
    const major = k.sel(.f32, r(xf), x, r(k.sel(.f32, r(yf), y, z)));
    const dm = k.sel(.f32, r(neg), r(k.op1(.fneg, .f32, r(major))), r(major));
    var out: [2]Arg = undefined;
    for (&out, [_]Arg{ p.s, p.t }, [_]V{ ds, dt }) |*result, coord, derivative| {
        const q = k.op2(.fsub, .f32, f(0.5), coord);
        const top = k.op3(.fmad, .f32, r(q), r(dm), r(k.op2(.fmul, .f32, f(0.5), r(derivative))));
        result.* = r(k.op2(.fmul, .f32, r(top), p.inverse_major));
    }
    return out;
}

fn cubeTap(k: *kir.Kernel, slot: Slot, d: D, lv: Lvl, face: Arg, x: V, y: V, linear: V, kind: Kind) [4]Arg {
    const width = k.cvt(.u32, .f32, .rne, r(lv.w));
    const height = k.cvt(.u32, .f32, .rne, r(lv.h));
    const clamp = struct {
        fn index(kk: *kir.Kernel, value: V, size_: V) V {
            const last = kk.op2(.fsub, .f32, r(size_), f(1));
            return kk.cvt(.f32, .u32, .rz, r(kk.op2(.fmin, .f32, r(kk.op2(.fmax, .f32, r(value), f(0))), r(last))));
        }
    }.index;
    const ix = k.reg(.u32);
    const iy = k.reg(.u32);
    const selected = k.reg(.u32);
    k.set(ix, .mov, r(clamp(k, x, width)), no, no);
    k.set(iy, .mov, r(clamp(k, y, height)), no, no);
    k.set(selected, .mov, face, no, no);
    if (kind == .float) {
        const outside_x = k.op2(.por, .pred, r(k.cmp(.f32, .lt, r(x), f(0))), r(k.cmp(.f32, .ge, r(x), r(width))));
        const outside_y = k.op2(.por, .pred, r(k.cmp(.f32, .lt, r(y), f(0))), r(k.cmp(.f32, .ge, r(y), r(height))));
        k.ifp(r(k.op2(.pand, .pred, r(linear), r(k.op2(.por, .pred, r(outside_x), r(outside_y))))));
        const s = k.op3(.fmad, .f32, r(k.op2(.fadd, .f32, r(x), f(0.5))), r(k.op2(.fmul, .f32, f(2), r(k.op1(.frcp, .f32, r(width))))), f(-1));
        const t = k.op3(.fmad, .f32, r(k.op2(.fadd, .f32, r(y), f(0.5))), r(k.op2(.fmul, .f32, f(2), r(k.op1(.frcp, .f32, r(height))))), f(-1));
        const x_face = k.cmp(.u32, .lt, face, u(2));
        const y_face = k.cmp(.u32, .lt, face, u(4));
        const negative = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, face, u(1))), u(0));
        const sign = k.sel(.f32, r(negative), f(-1), f(1));
        const signed_s = k.op2(.fmul, .f32, r(s), r(sign));
        const signed_t = k.op2(.fmul, .f32, r(t), r(sign));
        const dx = k.sel(.f32, r(x_face), r(sign), r(k.sel(.f32, r(y_face), r(s), r(signed_s))));
        const dy = k.sel(.f32, r(x_face), r(k.op1(.fneg, .f32, r(t))), r(k.sel(.f32, r(y_face), r(sign), r(k.op1(.fneg, .f32, r(t))))));
        const dz = k.sel(.f32, r(x_face), r(k.op1(.fneg, .f32, r(signed_s))), r(k.sel(.f32, r(y_face), r(signed_t), r(sign))));
        const projected = cubeProject(k, r(dx), r(dy), r(dz));
        k.set(ix, .mov, r(clamp(k, k.op1(.ffloor, .f32, r(k.op2(.fmul, .f32, projected.s, r(width)))), width)), no, no);
        k.set(iy, .mov, r(clamp(k, k.op1(.ffloor, .f32, r(k.op2(.fmul, .f32, projected.t, r(height)))), height)), no, no);
        k.set(selected, .mov, projected.face, no, no);
        k.endif();
    }
    return filteredTexel(k, slot, d, sliceOf(k, lv, r(selected)), r(ix), r(iy), kind, true);
}

fn sampleLayerLevel(k: *kir.Kernel, slot: Slot, d: D, level: V, layer: ?Arg, s: Arg, t: Arg, linear: V, kind: Kind, off: [2]i32) [4]Arg {
    const lv = levelOf(k, slot, d, level);
    if (slot.cube) return sampleLevel(k, slot, d, lv, s, t, linear, kind, off, layer);
    if (!slot.volume) return sampleLevel(k, slot, d, sliceOf(k, lv, layer), s, t, linear, kind, off, null);
    const depth = k.cvt(.u32, .f32, .rne, r(depthAt(k, slot, level)));
    const z = k.op2(.fsub, .f32, r(k.op2(.fmul, .f32, layer orelse f(0), r(depth))), r(k.sel(.f32, r(linear), f(0.5), f(0))));
    const floor = k.op1(.ffloor, .f32, r(z));
    const fraction = k.op2(.fsub, .f32, r(z), r(floor));
    const first = k.op2(.fadd, .f32, r(floor), f(@floatFromInt(slot.offset_z)));
    const mode = k.op3(.bfe, .u32, r(d.mode), u(12), u(2));
    const a = k.cvt(.f32, .u32, .rz, r(wrap(k, first, depth, mode)));
    if (kind != .float) return sampleLevel(k, slot, d, sliceOf(k, lv, r(a)), s, t, linear, kind, off, null);
    const b = k.cvt(.f32, .u32, .rz, r(wrap(k, k.op2(.fadd, .f32, r(first), f(1)), depth, mode)));
    const blend = k.op2(.pand, .pred, r(linear), r(k.cmp(.u32, .ne, r(a), r(b))));
    const current = k.reg(.u32);
    const second = k.reg(.pred);
    var out: [4]Arg = undefined;
    k.set(current, .mov, r(a), no, no);
    k.set(second, .mov, u(0), no, no);
    for (&out) |*channel| {
        const value = k.reg(.f32);
        k.set(value, .mov, f(0), no, no);
        channel.* = r(value);
    }
    k.loop();
    const texel_channels = sampleLevel(k, slot, d, sliceOf(k, lv, r(current)), s, t, linear, kind, off, null);
    for (out, texel_channels) |dst, src| {
        const mix = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, dst, r(k.op2(.fsub, .f32, f(1), r(fraction))))), r(k.op2(.fmul, .f32, src, r(fraction))));
        k.set(dst.reg, .sel, r(mix), src, r(second));
    }
    k.brk(r(k.op2(.por, .pred, r(second), r(k.op1(.pnot, .pred, r(blend))))));
    k.set(current, .mov, r(b), no, no);
    k.set(second, .mov, u(1), no, no);
    k.endloop();
    return out;
}

/// One level's sample: (s, t) in [0, 1] across it, nearest or bilinear
/// (`linear`), wrapped, `off` added: its channels before the swizzle.
fn sampleLevel(k: *kir.Kernel, slot: Slot, d: D, lv: Lvl, s: Arg, t: Arg, linear: V, kind: Kind, off: [2]i32, cube_face: ?Arg) [4]Arg {
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
    const t00 = if (cube_face) |face| cubeTap(k, slot, d, lv, face, x0, y0, linear, kind) else filteredTexel(k, slot, d, lv, xa, ya, kind, kind != .float);
    if (kind != .float) {
        if (cube_face != null) return t00;
        const out_x = outside(k, x0, wf, ws);
        const out_y = outside(k, y0, hf, wt);
        return withBorder(k, t00, borderColor(k, slot), k.op2(.por, .pred, r(out_x), r(out_y)), kind);
    }
    const x1 = k.op2(.fadd, .f32, r(x0), f(1));
    const y1 = k.op2(.fadd, .f32, r(y0), f(1));
    const xb = idx(k, wrap(k, x1, wf, ws));
    const yb = idx(k, wrap(k, y1, hf, wt));
    var t10 = if (cube_face) |face| cubeTap(k, slot, d, lv, face, x1, y0, linear, kind) else filteredTexel(k, slot, d, lv, xb, ya, kind, false);
    var t01 = if (cube_face) |face| cubeTap(k, slot, d, lv, face, x0, y1, linear, kind) else filteredTexel(k, slot, d, lv, xa, yb, kind, false);
    var t11 = if (cube_face) |face| cubeTap(k, slot, d, lv, face, x1, y1, linear, kind) else filteredTexel(k, slot, d, lv, xb, yb, kind, false);
    var t00m = t00;
    if (cube_face == null and slot.shadow == null) {
        // (a block-compressed image: the four taps decoded in one loop, one
        // decoder's code in the program, not four: Unigine's shaders, a
        // decoder a tap, passed the GPU compiler's size)
        var taps: [4][4]V = undefined;
        const from = [4][4]Arg{ t00, t10, t01, t11 };
        for (&taps, from) |*tp, src| for (tp, src) |*g, v| {
            g.* = k.reg(.f32);
            k.set(g.*, .mov, v, no, no);
        };
        const bck = k.op3(.bfe, .u32, r(d.fmt), u(F_BC_SHIFT), u(3));
        const srgb = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(d.fmt), u(F_SRGB))), u(0));
        k.ifp(r(k.cmp(.u32, .ne, r(bck), u(0))));
        {
            const n = k.reg(.u32);
            k.set(n, .mov, u(0), no, no);
            k.loop();
            {
                const tx_ = k.sel(.u32, r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(n), u(1))), u(0))), xb, xa);
                const ty_n = k.sel(.u32, r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(n), u(2))), u(0))), yb, ya);
                const v = bcTexel(k, slot.b, d, lv, r(tx_), r(ty_n), bck, srgb);
                for (taps, 0..) |tp, ti| {
                    const here = k.cmp(.u32, .eq, r(n), u(@intCast(ti)));
                    for (tp, v) |g, val| k.set(g, .sel, r(val), r(g), r(here));
                }
                k.set(n, .iadd, r(n), u(1), no);
                k.brk(r(k.cmp(.u32, .ge, r(n), u(4))));
            }
            k.endloop();
        }
        k.endif();
        for (&t00m, taps[0]) |*o, g| o.* = r(g);
        for (&t10, taps[1]) |*o, g| o.* = r(g);
        for (&t01, taps[2]) |*o, g| o.* = r(g);
        for (&t11, taps[3]) |*o, g| o.* = r(g);
    }
    var t00b = t00m;
    var t10b = t10;
    var t01b = t01;
    if (cube_face == null) {
        // CLAMP_TO_BORDER: a tap outside the level on such an axis reads the
        // border color
        const out_x0 = outside(k, x0, wf, ws);
        const out_x1 = outside(k, x1, wf, ws);
        const out_y0 = outside(k, y0, hf, wt);
        const out_y1 = outside(k, y1, hf, wt);
        const bc = borderColor(k, slot);
        t00b = withBorder(k, t00m, bc, k.op2(.por, .pred, r(out_x0), r(out_y0)), kind);
        t10b = withBorder(k, t10, bc, k.op2(.por, .pred, r(out_x1), r(out_y0)), kind);
        t01b = withBorder(k, t01, bc, k.op2(.por, .pred, r(out_x0), r(out_y1)), kind);
        t11 = withBorder(k, t11, bc, k.op2(.por, .pred, r(out_x1), r(out_y1)), kind);
    }
    const gx = k.op2(.fsub, .f32, f(1), r(fx));
    const gy = k.op2(.fsub, .f32, f(1), r(fy));
    var out: [4]Arg = undefined;
    for (&out, 0..) |*o, c| {
        const top = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, t00b[c], r(gx))), r(k.op2(.fmul, .f32, t10b[c], r(fx))));
        const bot = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, t01b[c], r(gx))), r(k.op2(.fmul, .f32, t11[c], r(fx))));
        const lerped = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(top), r(gy))), r(k.op2(.fmul, .f32, r(bot), r(fy))));
        // (nearest: the texel itself, not a blend with weight 0: inf and NaN survive)
        o.* = r(k.sel(.f32, r(linear), r(lerped), t00b[c]));
    }
    return out;
}

/// Whether an integer-valued float coordinate is outside [0, n) on an axis
/// wrapped CLAMP_TO_BORDER (mode 3).
fn outside(k: *kir.Kernel, x: V, n: V, mode: V) V {
    const off = k.op2(.por, .pred, r(k.cmp(.f32, .lt, r(x), f(0))), r(k.cmp(.f32, .ge, r(x), r(n))));
    return k.op2(.pand, .pred, r(off), r(k.cmp(.u32, .eq, r(mode), u(3))));
}

/// The border color's four words (the descriptor's).
fn borderColor(k: *kir.Kernel, slot: Slot) [4]V {
    var out: [4]V = undefined;
    for (&out, 0..) |*w, i| w.* = descWord(k, slot, D_BORDER + @as(u32, @intCast(i)));
    return out;
}

/// A tap's channels, or the border color where `use` (the texel's raw
/// channels, before the swizzle: the border is kept in their order).
fn withBorder(k: *kir.Kernel, tap: [4]Arg, bc: [4]V, use: V, kind: Kind) [4]Arg {
    var out: [4]Arg = undefined;
    for (&out, 0..) |*o, c| {
        const b: Arg = if (kind == .float) r(k.mov(.f32, r(bc[c]))) else r(bc[c]);
        o.* = r(k.sel(ty(kind), r(use), b, tap[c]));
    }
    return out;
}

/// The explicit fetch level is independent of the minification filter.
/// Clamp undefined levels to keep out-of-range reads within the allocation.
fn levelAt(k: *kir.Kernel, slot: Slot, lod: Arg) V {
    const lw = descWord(k, slot, D_LOD);
    const rel = k.op2(.imax, .i32, lod, u(0));
    const levels = k.op2(.imax, .u32, r(descWord(k, slot, D_IMAGE_LEVELS)), u(1));
    const last = k.op2(.isub, .u32, r(levels), u(1));
    return k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(k.op3(.bfe, .u32, r(lw), u(0), u(4))), r(rel))), r(last));
}

/// texelFetch(): texel (x, y) of level `lod` past the base (ints; clamped
/// inside the level), `off` added.
pub fn fetch(k: *kir.Kernel, slot: Slot, x: Arg, y: Arg, kind: Kind, off: [2]i32, lod: Arg) [4]Arg {
    return fetchArray(k, slot, x, y, null, kind, off, lod);
}

fn sliceOf(k: *kir.Kernel, level: Lvl, layer: ?Arg) Lvl {
    const z = layer orelse return level;
    var lv = level;
    const pitch = k.op2(.imul, .u32, r(lv.rows), r(lv.stride));
    lv.off = k.op3(.imad, .u32, z, r(pitch), r(lv.off));
    return lv;
}

pub fn fetchArray(k: *kir.Kernel, slot: Slot, x: Arg, y: Arg, layer: ?Arg, kind: Kind, off: [2]i32, lod: Arg) [4]Arg {
    const d = loadDesc(k, slot);
    const cl = struct {
        fn c(kk: *kir.Kernel, v: Arg, o: i32, n: V) Arg {
            const moved = if (o != 0) r(kk.op2(.iadd, .i32, v, u(@bitCast(o)))) else v;
            const last = kk.op2(.isub, .i32, r(n), u(1));
            return r(kk.op2(.imax, .i32, r(kk.op2(.imin, .i32, moved, r(last))), u(0)));
        }
    }.c;
    const level = levelAt(k, slot, lod);
    const z = if (layer) |a| cl(k, a, slot.offset_z, depthAt(k, slot, level)) else null;
    const lv = sliceOf(k, levelOf(k, slot, d, level), z);
    const raw = texel(k, slot.b, d, lv, cl(k, x, off[0], lv.w), cl(k, y, off[1], lv.h), kind, true);
    return finish(k, d, raw, kind);
}

pub fn layerSize(k: *kir.Kernel, slot: Slot, lod: Arg) Arg {
    const count = descWord(k, slot, D_LAYERS);
    if (!slot.volume) return r(count);
    const base = k.op3(.bfe, .u32, r(descWord(k, slot, D_LOD)), u(0), u(4));
    const level = k.op2(.iadd, .u32, r(base), lod);
    const n = depthAt(k, slot, level);
    return r(k.sel(.u32, r(k.cmp(.u32, .eq, r(count), u(0))), u(0), r(n)));
}

/// textureSize(): level `lod`'s (past the base) width and height (ints;
/// at least 1, 0 without a texture).
/// The levels a sampler reads (its base to its last): a Direct3D
/// view's mip count.
pub fn levelCount(k: *kir.Kernel, slot: Slot) Arg {
    const lw = descWord(k, slot, D_LOD);
    const base = k.op3(.bfe, .u32, r(lw), u(0), u(4));
    const last = k.op3(.bfe, .u32, r(lw), u(4), u(4));
    return r(k.op2(.iadd, .u32, r(k.op2(.isub, .u32, r(last), r(base))), u(1)));
}

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

test "texture: block-compressed texels read as bc.sig decodes them (every kind, three levels)" {
    const bc = @import("bc.sig");
    const interp = gpu.interp;
    const kinds = [_]bc.Kind{ .bc1, .bc2, .bc3, .bc4u, .bc4s, .bc5u, .bc5s };
    const fmts = [_]engine.Format{ .rgba8, .rgba8, .rgba8, .r8, .r32f, .rg8, .rg32f };
    const S = struct {
        // level 0 (8x8: 2x2 blocks), level 1 (4x4: one), level 2 (2x2: one)
        var mem: [6 * 16]u8 align(16) = undefined;
        var uni: [DESC_WORDS]u32 = undefined;
        var out: [128 * 4]f32 = undefined;
        var insts: [8192]kir.Inst = undefined;
        var tys: [8192]kir.Ty = undefined;
        var work: [4 << 20]u8 align(64) = undefined;
    };
    var rng = std.Random.DefaultPrng.init(0xbc15);
    for (kinds, fmts, 1..) |kind, fmt, code| {
        rng.random().bytes(&S.mem);
        const bb = kind.blockBytes();
        var img = engine.Image{ .buf = .{ .cpu = &S.mem, .bytes = S.mem.len }, .width = 8, .height = 8, .stride = 2 * bb, .format = fmt, .levels = 3, .bc = @intCast(code) };
        img.level_at[1] = 4 * bb;
        img.level_at[2] = 5 * bb;
        descriptor(.{ .img = &img, .last = 2 }, &S.uni);
        var k = kir.Kernel.init(.{ .insts = &S.insts, .tys = &S.tys }, "bc", .{ 128, 1, 1 });
        const bt = k.binding();
        const bu = k.binding();
        const bo = k.binding();
        const ix = k.tid(0);
        // (lanes 0..63 level 0, 64..79 level 1, 80..83 level 2)
        const in1 = k.cmp(.u32, .ge, r(ix), u(64));
        const in2 = k.cmp(.u32, .ge, r(ix), u(80));
        const j = k.sel(.u32, r(in2), r(k.op2(.isub, .u32, r(ix), u(80))), r(k.sel(.u32, r(in1), r(k.op2(.isub, .u32, r(ix), u(64))), r(ix))));
        const wlog = k.sel(.u32, r(in2), u(1), r(k.sel(.u32, r(in1), u(2), u(3))));
        const x = k.op2(.@"and", .u32, r(j), r(k.op2(.isub, .u32, r(k.op2(.shl, .u32, u(1), r(wlog))), u(1))));
        const y = k.op2(.shr, .u32, r(j), r(wlog));
        const lod = k.sel(.u32, r(in2), u(2), r(k.sel(.u32, r(in1), u(1), u(0))));
        const v = fetch(&k, .{ .b = bt, .uni = bu, .word = 0 }, r(x), r(y), .float, .{ 0, 0 }, r(lod));
        for (v, 0..) |c, n| k.store(.f32, kir.global(bo, 32), r(k.op3(.imad, .u32, r(ix), u(16), u(@intCast(4 * n)))), c);
        try k.finish();
        var w = gpu.Work.init(&S.work);
        var trap: interp.Trap = .{};
        _ = try interp.runKernel(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{ &S.mem, std.mem.sliceAsBytes(&S.uni), std.mem.sliceAsBytes(&S.out) }, &.{}, &w, &trap);
        const levels = [_][3]u32{ .{ 0, 8, 0 }, .{ 4 * bb, 4, 64 }, .{ 5 * bb, 2, 80 } };
        const tb = kind.texelBytes();
        for (levels) |lv| {
            const nb = bc.blocks(lv[1]);
            const span = @min(4, lv[1]);
            for (0..nb) |by| for (0..nb) |bx| {
                var px: [4 * 4 * 8]u8 = undefined;
                bc.decode(kind, S.mem[lv[0] + (by * nb + bx) * bb ..][0..bb], &px, 4 * tb, span, span);
                for (0..span) |ty_| for (0..span) |tx| {
                    const t = px[(ty_ * 4 + tx) * tb ..];
                    var want = [4]f32{ 0, 0, 0, 1 };
                    switch (kind) {
                        .bc1, .bc2, .bc3 => for (&want, 0..) |*o, c| {
                            o.* = @as(f32, @floatFromInt(t[c])) * (1.0 / 255.0);
                        },
                        .bc4u, .bc5u => for (0..tb) |c| {
                            want[c] = @as(f32, @floatFromInt(t[c])) * (1.0 / 255.0);
                        },
                        .bc4s, .bc5s => for (0..tb / 4) |c| {
                            want[c] = @bitCast(std.mem.readInt(u32, t[4 * c ..][0..4], .little));
                        },
                    }
                    const lane = lv[2] + (by * 4 + ty_) * lv[1] + bx * 4 + tx;
                    const got = S.out[lane * 4 ..][0..4];
                    for (want, got) |a, g| {
                        if (@abs(a - g) > 1e-6) {
                            std.debug.print("{s} level width {d} texel ({d}, {d}): want {any} got {any}\n", .{ @tagName(kind), lv[1], bx * 4 + tx, by * 4 + ty_, want, got.* });
                            return error.TestExpectedEqual;
                        }
                    }
                };
            };
        }
        // Sampled, bilinear, between four texels of level 0 (repeat): their
        // mean, every tap of sampleLevel's decoding loop in it.
        const fetched = S.out;
        descriptor(.{ .img = &img, .last = 2, .linear = true, .min_linear = true }, &S.uni);
        var ks = kir.Kernel.init(.{ .insts = &S.insts, .tys = &S.tys }, "bc-sampled", .{ 64, 1, 1 });
        const st = ks.binding();
        const su = ks.binding();
        const so = ks.binding();
        const sx = ks.tid(0);
        const fx = ks.cvt(.u32, .f32, .rne, r(ks.op2(.@"and", .u32, r(sx), u(7))));
        const fy = ks.cvt(.u32, .f32, .rne, r(ks.op2(.shr, .u32, r(sx), u(3))));
        // ((x + 1) / 8: halfway between texels x and x + 1)
        const ss = ks.op2(.fmul, .f32, r(ks.op2(.fadd, .f32, r(fx), f(1))), f(0.125));
        const tt = ks.op2(.fmul, .f32, r(ks.op2(.fadd, .f32, r(fy), f(1))), f(0.125));
        const sv = sample(&ks, .{ .b = st, .uni = su, .word = 0 }, r(ss), r(tt), .float, .{ 0, 0 }, .base);
        for (sv, 0..) |c, n| ks.store(.f32, kir.global(so, 32), r(ks.op3(.imad, .u32, r(sx), u(16), u(@intCast(4 * n)))), c);
        try ks.finish();
        var ws = gpu.Work.init(&S.work);
        var strap: interp.Trap = .{};
        _ = try interp.runKernel(&ks, gpu.interp_caps, .{ 1, 1, 1 }, &.{ &S.mem, std.mem.sliceAsBytes(&S.uni), std.mem.sliceAsBytes(&S.out) }, &.{}, &ws, &strap);
        for (0..8) |yy| for (0..8) |xx| {
            const at = struct {
                fn t(o: *const [128 * 4]f32, x_: usize, y_: usize, c: usize) f32 {
                    return o[((y_ % 8) * 8 + x_ % 8) * 4 + c];
                }
            }.t;
            for (0..4) |c| {
                const top = at(&fetched, xx, yy, c) * 0.5 + at(&fetched, xx + 1, yy, c) * 0.5;
                const bot = at(&fetched, xx, yy + 1, c) * 0.5 + at(&fetched, xx + 1, yy + 1, c) * 0.5;
                const want = top * 0.5 + bot * 0.5;
                const got = S.out[(yy * 8 + xx) * 4 + c];
                if (@abs(want - got) > 1e-6) {
                    std.debug.print("{s} sampled between ({d}, {d}) channel {d}: want {d} got {d}\n", .{ @tagName(kind), xx, yy, c, want, got });
                    return error.TestExpectedEqual;
                }
            }
        };
    }
}
