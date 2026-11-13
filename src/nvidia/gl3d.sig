//! @zpm/nvidia gl3d — a GL-shaped draw's state for the RTX's 3D engine
//! (BLACKWELL_B), as methods: what gpu/nvidia_device sends for a run's
//! graphics dispatch (programs compiled by gpu/nvidia_gl from KIR).
//!
//! The engine's whole state is draw.sig's (NVK's values for this class,
//! sent raw: every draw sends all of it, the channel may have drawn
//! something else in between), and then the draw's own:
//!
//! - its two programs (each a header and its code, gpu/nvidia_gl);
//! - constant buffer 0 of both stages: the binding addresses and the
//!   parameter words, laid out as a compute launch's (qmd.cbuf0Into), so a
//!   program reads them as a kernel does;
//! - up to eight colour targets (rows of bytes, or block linear: RGBA8,
//!   BGRA8, RG8, R8; the pixel program's output t into target t), each's
//!   channels written and blend on or off; the blend (GL's factors and equations,
//!   the constant colour), the viewport (x, y and depth: GL's -w..w clip
//!   volume), the scissor;
//! - the depth target (block linear, 32-bit words, depth in bits 0..23)
//!   and, for a stencil test, its stencil in a plane of its own (8-bit,
//!   block linear: Blackwell keeps them apart), the depth test and write,
//!   the stencil of both faces; culling and the front face;
//! - the primitives: triangles, a strip or a fan of `count` vertices, the
//!   vertex's index 0 .. count - 1 (the programs fetch their attributes
//!   and the element array themselves), `instances` times.
//!
//! Not yet (the GL layer keeps such draws on its compute kernels): points
//! and lines, multisampling, depth textures, depth bias, clip distances.
//!
//! **A depth target needs block-linear colour targets.** The engine
//! refuses a draw whose colour target is rows of bytes (LAYOUT_PITCH)
//! while a depth target is selected: a class error, data error
//! RT_LINEAR_WITH_ZETA (0x12 on G80, 0x98 from GF100: envytools'
//! g80_defs; nvc0's validate_fb asserts no depth beside a linear colour
//! buffer; NVK draws a linear image with depth through a tiled shadow).
//! GSP-RM then recovers the channel with Xid 69
//! (ROBUST_CHANNEL_GR_CLASS_ERROR). pc-all's first triangle had both that
//! and a combined depth-stencil format (below), and its error code was
//! not logged. whyNot says so before a draw is sent; emu3d refuses such a
//! stream the same way.
//!
//! **Blackwell keeps stencil apart from depth.** pc-full2 (block-linear
//! colour) still lost the channel at the first draw with a depth target:
//! GSP-RM's log named class 0xce97, method 0x274 (DRAW_VERTEX_ARRAY_
//! BEGIN_END_B, the draw), data 6, error code 0x13. The depth target was
//! SET_ZT_FORMAT 0x14, a combined depth-stencil format with the stencil
//! in the same words. NVK on Blackwell never sends one: it splits every
//! depth-stencil image into a depth plane and an S8 plane
//! (nvk_use_separate_zs) and sends SET_ZT_FORMAT with STENCIL_IS_SEPARATE
//! and the stencil plane by SET_ST_*; a depth-only image is X8Z24. So a
//! depth target here is X8Z24 (depth in bits 0..23, as the model keeps
//! it), or S8Z24 with its stencil a plane of its own; emu3d refuses the
//! combined forms.
//!
//! **The front face** is named on the screen: with the window's origin at
//! the top left, OGL_SET_FRONT_FACE CCW makes front the triangles
//! counter-clockwise as seen (y down), which have a negative area in the
//! target's coordinates (x right, y as the rows grow). The model's
//! `front_ccw` is the positive area's, so it is sent as CW (frontFaceWord;
//! NVK sends Vulkan's CCW as CCW, Vulkan's being the screen's). pc-full2
//! culled, and painted gl_FrontFacing, the other way round before.
//!
//! The rectangles (draw.sig) have run on the Legion's RTX bit for bit, and
//! so have triangles with no depth (pc-full2: step 4a EXACT, several
//! colour targets EXACT).
//!
//! Allocation-free.

const std = @import("std");
const push = @import("push.sig");
const gr = @import("draw.sig");

const Push = push.Push;
const SUBCH = gr.SUBCH;

pub const Format = enum(u8) { rgba8, bgra8, r8, rg8 };

/// SET_COLOR_TARGET_FORMAT's values.
pub fn targetFormat(f: Format) u32 {
    return switch (f) {
        .bgra8 => 0xcf, // A8R8G8B8
        .rgba8 => 0xd5, // A8B8G8R8
        .rg8 => 0xea, // R8G8
        .r8 => 0xf3,
    };
}

pub fn formatBytes(f: Format) u32 {
    return switch (f) {
        .r8 => 1,
        .rg8 => 2,
        else => 4,
    };
}

/// GL's blend factors as the engine takes them (OGL_*: the GL enum's
/// number, with 0x4000; the constant ones 0xc001..0xc004).
pub const Factor = enum(u32) {
    zero = 0x4000,
    one = 0x4001,
    src_color = 0x4300,
    one_minus_src_color = 0x4301,
    src_alpha = 0x4302,
    one_minus_src_alpha = 0x4303,
    dst_alpha = 0x4304,
    one_minus_dst_alpha = 0x4305,
    dst_color = 0x4306,
    one_minus_dst_color = 0x4307,
    src_alpha_saturate = 0x4308,
    constant_color = 0xc001,
    one_minus_constant_color = 0xc002,
    constant_alpha = 0xc003,
    one_minus_constant_alpha = 0xc004,
};

pub const Equation = enum(u32) {
    add = 0x8006,
    min = 0x8007,
    max = 0x8008,
    subtract = 0x800a,
    reverse_subtract = 0x800b,
};

pub const Blend = struct {
    src_rgb: Factor = .one,
    dst_rgb: Factor = .zero,
    src_a: Factor = .one,
    dst_a: Factor = .zero,
    eq_rgb: Equation = .add,
    eq_a: Equation = .add,
    constant: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Topology = enum(u32) { triangles = 4, strip = 5, fan = 6 };

// An indexed draw (cl9097.h, clc597.h; NVK's on Turing and later): the
// index buffer's address, its size, the indices' size, primitive restart,
// then SET_DRAW_CONTROL_A .. DRAW_INDEX_BUFFER_BEGIN_END_B in one method
// (the control word, the instances, the first index, the count: the last
// draws).
pub const SET_INDEX_BUFFER_A: u32 = 0x17c8; // address (high), low
pub const SET_INDEX_BUFFER_SIZE_A: u32 = 0x0238; // bytes (high), low
pub const SET_INDEX_BUFFER_E: u32 = 0x17d8; // 0 one byte, 1 two, 2 four
pub const SET_DA_PRIMITIVE_RESTART_INDEX: u32 = 0x1648;
pub const DRAW_INDEX_BUFFER_BEGIN_END_A: u32 = 0x0268;
pub const DRAW_INDEX_BUFFER_BEGIN_END_B: u32 = 0x026c;

/// The draw's indices: rows of `size`-byte indices from `va` (`bytes` of
/// them), from index `first`; with `restart`, the type's largest value
/// begins a strip or a fan anew (GL's PRIMITIVE_RESTART_FIXED_INDEX).
/// The vertex's index the vertex program reads is the index.
pub const Index = struct { va: u64, bytes: u32, size: u8, first: u32, restart: bool = false };

// The depth-stencil target and its tests (cl9097.h's methods; the
// stencil plane's, clcd97.h's).
pub const SET_ZT_A: u32 = 0x0fe0; // address (high), then low, format, block size, array pitch
pub const SET_ZT_SIZE_A: u32 = 0x1228; // width, height, third dimension
/// SET_ZT_FORMAT's: X8Z24 (depth in bits 0..23, no stencil: Mesa's
/// Z24X8_UNORM), S8Z24 (Mesa's Z24_UNORM_S8_UINT: NVK's for
/// D24_UNORM_S8_UINT, with STENCIL_IS_SEPARATE on Blackwell), and the
/// combined Z24S8 (0x14, stencil in bits 0..7) pc-all and pc-full2 sent.
pub const ZT_X8Z24: u32 = 0x15;
pub const ZT_S8Z24: u32 = 0x16;
pub const ZT_Z24S8: u32 = 0x14;
/// SET_ZT_FORMAT_STENCIL_IS_SEPARATE (clcd97.h on): the stencil is the
/// SET_ST_* plane.
pub const ZT_STENCIL_IS_SEPARATE: u32 = 1 << 8;
pub const SET_ST_A: u32 = 0x0f00; // address (high), low, block size, array pitch
pub const SET_ST_SIZE_A: u32 = 0x120c; // width (bytes: S8), height
pub const SET_ZT_SPARSE: u32 = 0x1208;
pub const SET_STENCIL_COMPRESSION: u32 = 0x111c;
pub const SET_ZT_LAYER: u32 = 0x179c;
pub const SET_Z_COMPRESSION: u32 = 0x19cc;
pub const SET_STENCIL_OP_FAIL: u32 = 0x1384; // fail, zfail, zpass, func, ref, func mask, write mask
/// The back faces' stencil (cl9097.h): on with SET_TWO_SIDED_STENCIL_TEST
/// (NVK keeps it on always), else the front's state is both faces'.
pub const SET_TWO_SIDED_STENCIL_TEST: u32 = 0x1594;
pub const SET_BACK_STENCIL_OP_FAIL: u32 = 0x1598; // fail, zfail, zpass, func
pub const SET_BACK_STENCIL_FUNC_REF: u32 = 0x0f54;
pub const SET_BACK_STENCIL_MASK: u32 = 0x0f58; // the write mask
pub const SET_BACK_STENCIL_FUNC_MASK: u32 = 0x0f5c;

/// GL's stencil operations, as the engine takes them (the GL enums).
pub const StencilOp = enum(u32) { keep = 0x1e00, zero = 0, replace = 0x1e01, incr = 0x1e02, decr = 0x1e03, invert = 0x150a, incr_wrap = 0x8507, decr_wrap = 0x8508 };

pub const Stencil = struct {
    /// NEVER 0 .. ALWAYS 7 (bit 0 less, 1 equal, 2 greater: GL's order)
    func: u3 = 7,
    reference: u8 = 0,
    value_mask: u8 = 0xff,
    write_mask: u8 = 0xff,
    fail: StencilOp = .keep,
    zfail: StencilOp = .keep,
    zpass: StencilOp = .keep,
};

/// A depth target: block linear (whole 64-byte GOBs across, blocks of
/// 2^gobs_log2 GOBs, Turing2D's GOBs), 32-bit words, depth in bits 0..23
/// (8..31 the engine's); a stencil test needs `stencil_va`.
pub const Depth = struct {
    va: u64,
    /// The stencil plane (S8: a byte a pixel, block linear in Blackwell's
    /// 8-bit GOBs, stencilPitch(width) bytes across, as many GOBs a block
    /// as the depth's), or null: no stencil.
    stencil_va: ?u64 = null,
    width: u32,
    height: u32,
    gobs_log2: u3,
    tested: bool,
    write: bool,
    /// NEVER 0 .. ALWAYS 7 (the OGL value is 0x200 + it)
    func: u3 = 1,
    /// the front faces' stencil (with `stencil` set, both faces' unless
    /// `back` is)
    stencil: ?Stencil = null,
    /// the back faces' (two-sided stencil), null: the front's
    back: ?Stencil = null,
};

/// A program as the engine is told of it: its header's address, its
/// registers, the 256-byte blocks to prefetch (header and code).
pub const Prog = struct { va: u64, registers: u32, bytes: u64 };

pub const Draw = struct {
    vertex: Prog,
    pixel: Prog,
    /// Constant buffer 0 of both stages (64-byte aligned, 64 KiB at most).
    cb_va: u64,
    cb_bytes: u32,
    /// A page of zeros (what an attribute with no stream reads, and the
    /// pools' place: the programs sample nothing).
    zero_va: u64,
    target: gr.Target,
    format: Format,
    /// The colour targets' layout: null rows of `target.pitch` bytes
    /// (LAYOUT_PITCH); else block linear (one GOB wide and deep, blocks of
    /// 2^n GOBs high: 8 << n rows), `target.pitch` bytes across (whole
    /// GOBs, 64 bytes), the target at a GOB (512 bytes). A depth target
    /// needs it (RT_LINEAR_WITH_ZETA).
    color_gobs: ?u3 = null,
    /// The channels written: bit 0 red .. bit 3 alpha.
    mask: u4 = 0xf,
    blend: ?Blend = null,
    /// window = clip / w * scale + offset (x, y in pixels from the
    /// target's top row, depth).
    scale: [3]f32,
    offset: [3]f32,
    /// x0, y0, x1, y1: [x0, x1) x [y0, y1), in the target's rows.
    scissor: [4]u32,
    topology: Topology = .triangles,
    count: u32,
    instances: u32 = 1,
    depth: ?Depth = null,
    /// Faces culled: bit 0 front, bit 1 back.
    cull: u2 = 0,
    /// Front faces counter-clockwise in the window's coordinates (x
    /// right, y as the rows grow).
    front_ccw: bool = true,
    /// Colour targets 1 .. 7 (null: none; one inside the highest is sent
    /// off: format 0): as wide and high as target 0.
    more: [7]?More = @splat(null),
    /// Indexed (the hardware's index buffer and primitive restart), else
    /// the vertices' indices 0 .. count - 1.
    index: ?Index = null,
};

/// A colour target past the first: rows of `pitch` bytes from `va` (128
/// bytes apart, as the first's; block linear as the first is, with
/// Draw.color_gobs), its format, channels and blend.
pub const More = struct {
    va: u64,
    pitch: u32,
    format: Format,
    mask: u4 = 0xf,
    /// The draw's blend applies to it (else its colour replaces).
    blend: bool = true,
};

/// SET_CT_SELECT: `count` targets, slot t its own target t (draw.sig's
/// setup sends it for one).
pub fn ctSelect(count: u32) u32 {
    return 0x0fac_6880 | count;
}

/// The stencil plane's bytes across: whole GOBs.
pub fn stencilPitch(width: u32) u32 {
    return (width + 63) / 64 * 64;
}

/// OGL_SET_FRONT_FACE for the model's `front_ccw` (front: a positive area
/// in the target's coordinates, x right and y as the rows grow): the
/// engine names the winding as seen (y down), the other way round.
pub fn frontFaceWord(front_ccw: bool) u32 {
    return if (front_ccw) FRONT_CW else FRONT_CCW;
}

/// The model's `front_ccw` for an OGL_SET_FRONT_FACE word (emu3d's side).
pub fn frontCcwOf(word: u32) bool {
    return word == FRONT_CW;
}

fn ctWrite(mask: u4) u32 {
    return @as(u32, mask & 1) | @as(u32, (mask >> 1) & 1) << 4 | @as(u32, (mask >> 2) & 1) << 8 | @as(u32, (mask >> 3) & 1) << 12;
}

/// OGL_SET_CULL_FACE (cl9097.h): the faces culled when OGL_SET_CULL is on.
pub const OGL_SET_CULL_FACE: u32 = 0x1920;
pub const CULL_FRONT: u32 = 0x404;
pub const CULL_BACK: u32 = 0x405;
pub const CULL_FRONT_AND_BACK: u32 = 0x408;
/// OGL_SET_FRONT_FACE's values.
pub const FRONT_CW: u32 = 0x900;
pub const FRONT_CCW: u32 = 0x901;

/// SET_COLOR_TARGET_MEMORY: block linear (LAYOUT_BLOCKLINEAR, 0 in bit
/// 12), one GOB wide and deep, 2^gobs GOBs high.
pub fn blockMemory(gobs: u3) u32 {
    return @as(u32, gobs) << 4;
}

/// Colour target t's nine words (SET_COLOR_TARGET_A .. _LAYER): rows of
/// `pitch` bytes (the width is the pitch, LAYOUT_PITCH), or block linear
/// (the width in pixels: the pitch over the pixel's bytes, as NVK sends).
pub fn targetWords(va: u64, pitch: u32, height: u32, f: Format, gobs: ?u3) [9]u32 {
    return if (gobs) |n|
        .{ @truncate(va >> 32), @truncate(va), pitch / formatBytes(f), height, targetFormat(f), blockMemory(n), 1, 0, 0 }
    else
        .{ @truncate(va >> 32), @truncate(va), pitch, height, targetFormat(f), gr.TARGET_MEMORY_PITCH, 1, 0, 0 };
}

/// Why the engine would refuse `d` (a class error: GSP-RM recovers the
/// channel, Xid 69), or null. Checked before a draw is sent.
pub fn whyNot(d: *const Draw) ?[]const u8 {
    if (d.depth != null and d.color_gobs == null)
        return "a depth target beside colour targets of rows of bytes (LAYOUT_PITCH): the engine's data error RT_LINEAR_WITH_ZETA (Xid 69)";
    if (d.target.va % 128 != 0 or d.target.pitch % 128 != 0 or d.target.pitch == 0 or d.target.height == 0)
        return "a colour target whose address or rows are not on 128 bytes (RT_INVALID_ALIGNMENT)";
    if (d.color_gobs) |n| {
        if (n > 5 or d.target.va % 512 != 0 or d.target.pitch % 64 != 0 or d.target.pitch % formatBytes(d.format) != 0)
            return "a block-linear colour target not on a GOB, or its blocks over 32 GOBs high";
        // (8- and 16-bit texels have GOBs of their own on Blackwell)
        if (formatBytes(d.format) != 4) return "a block-linear colour target of 8- or 16-bit pixels (Blackwell's GOBs for them are not modelled)";
    }
    for (d.more) |mm| {
        const m = mm orelse continue;
        if (m.va % 128 != 0 or m.pitch % 128 != 0) return "a colour target whose address or rows are not on 128 bytes (RT_INVALID_ALIGNMENT)";
        if (d.color_gobs != null and (m.va % 512 != 0 or m.pitch % formatBytes(m.format) != 0)) return "a block-linear colour target not on a GOB";
        if (d.color_gobs != null and formatBytes(m.format) != 4) return "a block-linear colour target of 8- or 16-bit pixels (Blackwell's GOBs for them are not modelled)";
    }
    if (d.depth) |z| {
        if (z.gobs_log2 > 5 or z.va % 512 != 0 or z.width == 0 or z.height == 0) return "a depth target not on a GOB, with no size, or its blocks over 32 GOBs high";
        if (z.stencil != null and z.stencil_va == null) return "a stencil test with no stencil plane (Blackwell keeps stencil apart from depth: STENCIL_IS_SEPARATE)";
        if (z.stencil_va) |sva| if (sva % 512 != 0) return "a stencil plane not on a GOB";
    }
    return null;
}

fn one(p: *Push, m: u32, v: u32) void {
    p.immediate(SUBCH, m, v);
}

fn many(p: *Push, m: u32, data: []const u32) void {
    p.method(SUBCH, m, data);
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}

/// SET_VIEWPORT_Z_CLIP for GL's clip volume.
pub const SET_VIEWPORT_SCALE_Z_CLIP_GL: u32 = 0; // SET_VIEWPORT_Z_CLIP: NEGATIVE_W_TO_POSITIVE_W
pub const SET_BLEND_CONST: u32 = gr.SET_BLEND_CONST_RED;
pub const SET_CONSTANT_BUFFER_SELECTOR_A = gr.SET_CONSTANT_BUFFER_SELECTOR_A;
/// SET_PROVOKING_VERTEX: GL's flat varyings are the last vertex's.
pub const PROVOKING_LAST: u32 = 1;

/// The whole of a draw: state, programs, buffers, the draw.
pub fn emit(p: *Push, d: *const Draw) void {
    gr.setup(p, d.zero_va, d.zero_va, d.zero_va, 1);
    gr.target(p, .{ .va = d.target.va, .width = d.target.width, .height = d.target.height, .pitch = d.target.pitch, .format = .bgra8 });
    // the target's own format (and layout, when block linear), its channels
    if (d.color_gobs) |n| {
        many(p, gr.SET_COLOR_TARGET_A, &targetWords(d.target.va, d.target.pitch, d.target.height, d.format, n));
    } else many(p, gr.SET_COLOR_TARGET_A + 16, &.{targetFormat(d.format)});
    many(p, gr.SET_CT_WRITE, &.{ctWrite(d.mask)});
    // the other colour targets (the pixel program's outputs 1 .. 7): each
    // its memory, format, channels and blend; CT_SELECT counts to the last
    var count: u32 = 1;
    for (d.more, 1..) |m, ti| {
        const x = m orelse continue;
        const t: u32 = @intCast(ti);
        many(p, gr.SET_COLOR_TARGET_A + 64 * t, &targetWords(x.va, x.pitch, d.target.height, x.format, d.color_gobs));
        one(p, gr.SET_COLOR_COMPRESSION + 4 * t, 0);
        one(p, gr.SET_CT_WRITE + 4 * t, ctWrite(x.mask));
        if (d.blend) |b| {
            one(p, gr.SET_BLEND + 4 * t, @intFromBool(x.blend));
            if (x.blend) many(p, gr.SET_BLEND_PER_TARGET_SEPARATE_FOR_ALPHA + 32 * t, &.{ 1, @intFromEnum(b.eq_rgb), @intFromEnum(b.src_rgb), @intFromEnum(b.dst_rgb), @intFromEnum(b.eq_a), @intFromEnum(b.src_a), @intFromEnum(b.dst_a) });
        } else one(p, gr.SET_BLEND + 4 * t, 0);
        count = t + 1;
    }
    many(p, gr.SET_CT_SELECT, &.{ctSelect(count)});
    // the viewport: x, y and depth; GL's clip volume (-w <= z <= w)
    many(p, gr.SET_VIEWPORT_SCALE_X, &.{ bits(d.scale[0]), bits(d.scale[1]), bits(d.scale[2]), bits(d.offset[0]), bits(d.offset[1]), bits(d.offset[2]) });
    one(p, gr.SET_VIEWPORT_Z_CLIP, SET_VIEWPORT_SCALE_Z_CLIP_GL);
    gr.setScissor(p, d.scissor[0], d.scissor[1], d.scissor[2], d.scissor[3]);
    one(p, gr.SET_PROVOKING_VERTEX, PROVOKING_LAST);
    one(p, gr.OGL_SET_FRONT_FACE, frontFaceWord(d.front_ccw));
    if (d.cull != 0) {
        one(p, OGL_SET_CULL_FACE, switch (d.cull) {
            1 => CULL_FRONT,
            2 => CULL_BACK,
            else => CULL_FRONT_AND_BACK,
        });
        one(p, gr.OGL_SET_CULL, 1);
    } else one(p, gr.OGL_SET_CULL, 0);
    if (d.depth) |z| {
        // (as NVK sends a Blackwell depth image: X8Z24 alone, or S8Z24
        // with its stencil the SET_ST_* plane; the width in words of a
        // whole-GOB row; one layer; no compression, no sparse)
        const fmt = if (z.stencil_va != null) ZT_S8Z24 | ZT_STENCIL_IS_SEPARATE else ZT_X8Z24;
        many(p, SET_ZT_A, &.{ @truncate(z.va >> 32), @truncate(z.va), fmt, @as(u32, z.gobs_log2) << 4, 0 });
        many(p, SET_ZT_SIZE_A, &.{ (z.width * 4 + 63) / 64 * 16, z.height, 1 });
        one(p, SET_ZT_LAYER, 0);
        one(p, SET_Z_COMPRESSION, 0);
        one(p, SET_STENCIL_COMPRESSION, 0);
        one(p, SET_ZT_SPARSE, 0);
        if (z.stencil_va) |sva| {
            many(p, SET_ST_A, &.{ @truncate(sva >> 32), @truncate(sva), @as(u32, z.gobs_log2) << 4, 0 });
            many(p, SET_ST_SIZE_A, &.{ stencilPitch(z.width), z.height });
        }
        one(p, gr.SET_ZT_SELECT, 1);
        one(p, gr.SET_DEPTH_TEST, @intFromBool(z.tested));
        one(p, gr.SET_DEPTH_WRITE, @intFromBool(z.write));
        many(p, gr.SET_DEPTH_FUNC, &.{0x200 + @as(u32, z.func)});
        if (z.stencil) |s| {
            one(p, gr.SET_STENCIL_TEST, 1);
            many(p, SET_STENCIL_OP_FAIL, &.{ @intFromEnum(s.fail), @intFromEnum(s.zfail), @intFromEnum(s.zpass), 0x200 + @as(u32, s.func), s.reference, s.value_mask, s.write_mask });
            // the back faces' (the front's again when one-sided), as NVK
            // sends them with two-sided stencil on
            const b = z.back orelse s;
            one(p, SET_TWO_SIDED_STENCIL_TEST, 1);
            many(p, SET_BACK_STENCIL_OP_FAIL, &.{ @intFromEnum(b.fail), @intFromEnum(b.zfail), @intFromEnum(b.zpass), 0x200 + @as(u32, b.func) });
            many(p, SET_BACK_STENCIL_FUNC_REF, &.{ b.reference, b.write_mask, b.value_mask });
        }
    }
    one(p, gr.SET_PRIMITIVE_TOPOLOGY, @intFromEnum(d.topology));
    // the blend
    if (d.blend) |b| {
        one(p, gr.SET_BLEND, 1);
        many(p, gr.SET_BLEND_PER_TARGET_SEPARATE_FOR_ALPHA, &.{ 1, @intFromEnum(b.eq_rgb), @intFromEnum(b.src_rgb), @intFromEnum(b.dst_rgb), @intFromEnum(b.eq_a), @intFromEnum(b.src_a), @intFromEnum(b.dst_a) });
        many(p, gr.SET_BLEND_CONST_RED, &.{ bits(b.constant[0]), bits(b.constant[1]), bits(b.constant[2]), bits(b.constant[3]) });
    } else one(p, gr.SET_BLEND, 0);
    // the programs, constant buffer 0 of both stages
    for ([_]struct { u32, u32, Prog }{ .{ gr.STAGE_VERTEX, gr.GROUP_VERTEX, d.vertex }, .{ gr.STAGE_PIXEL, gr.GROUP_PIXEL, d.pixel } }) |s| {
        one(p, gr.SET_PIPELINE_SHADER + 64 * s[0], 1 | s[0] << 4);
        many(p, gr.SET_PIPELINE_PROGRAM_ADDRESS_A + 64 * s[0], &.{ @truncate(s[2].va >> 32), @truncate(s[2].va), @intCast(@min((s[2].bytes + 255) / 256, 127)) });
        many(p, gr.SET_PIPELINE_REGISTER_COUNT + 64 * s[0], &.{ s[2].registers, s[1] });
    }
    many(p, gr.SET_CONSTANT_BUFFER_SELECTOR_A, &.{ d.cb_bytes, @truncate(d.cb_va >> 32), @truncate(d.cb_va) });
    one(p, gr.BIND_GROUP_CONSTANT_BUFFER + 32 * gr.GROUP_VERTEX, 1);
    one(p, gr.BIND_GROUP_CONSTANT_BUFFER + 32 * gr.GROUP_PIXEL, 1);
    one(p, gr.INVALIDATE_SHADER_CACHES_NO_WFI, 0x1001); // the code and the constants
    if (d.index) |ix| {
        many(p, SET_INDEX_BUFFER_A, &.{ @truncate(ix.va >> 32), @truncate(ix.va) });
        many(p, SET_INDEX_BUFFER_SIZE_A, &.{ 0, ix.bytes });
        one(p, SET_INDEX_BUFFER_E, switch (ix.size) {
            1 => 0,
            2 => 1,
            else => 2,
        });
        one(p, gr.SET_DA_PRIMITIVE_RESTART, @intFromBool(ix.restart));
        many(p, SET_DA_PRIMITIVE_RESTART_INDEX, &.{restartIndex(ix.size)});
        many(p, gr.SET_DRAW_CONTROL_A, &.{ gr.DRAW_CONTROL, d.instances, ix.first, d.count });
        return;
    }
    many(p, gr.SET_DRAW_CONTROL_A, &.{ gr.DRAW_CONTROL, d.instances });
    many(p, gr.DRAW_VERTEX_ARRAY_BEGIN_END_A, &.{ 0, d.count });
}

/// The fixed restart index of `size`-byte indices: the type's largest.
pub fn restartIndex(size: u8) u32 {
    return switch (size) {
        1 => 0xff,
        2 => 0xffff,
        else => 0xffff_ffff,
    };
}

/// Dwords emit takes at most (draw.sig's state, and the draw's own: 26
/// a colour target past the first).
pub const MAX_DWORDS = 1100;

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "gl3d: a draw's stream fits, ends in its draw, names its programs and buffer" {
    var buf: [MAX_DWORDS]u32 = undefined;
    var p = Push{ .buf = &buf };
    const d = Draw{
        .vertex = .{ .va = 0x10_0000_0000, .registers = 24, .bytes = 0x300 },
        .pixel = .{ .va = 0x10_0000_1000, .registers = 32, .bytes = 0x200 },
        .cb_va = 0x10_0000_2000,
        .cb_bytes = 0x400,
        .zero_va = 0x10_0000_3000,
        .target = .{ .va = 0x10_0001_0000, .width = 64, .height = 32, .pitch = 256 },
        .format = .rgba8,
        .blend = .{ .src_rgb = .src_alpha, .dst_rgb = .one_minus_src_alpha },
        .scale = .{ 32, 16, 0.5 },
        .offset = .{ 32, 16, 0.5 },
        .scissor = .{ 0, 0, 64, 32 },
        .count = 6,
        .instances = 3,
    };
    emit(&p, &d);
    try p.check();
    const w = p.words();
    try testing.expectEqualSlices(u32, &.{ push.header(SUBCH, gr.DRAW_VERTEX_ARRAY_BEGIN_END_A, 2), 0, 6 }, w[w.len - 3 ..]);
    try testing.expect(w.len < MAX_DWORDS);
    // every colour target, a depth target with two-sided stencil: fits
    var all = d;
    for (&all.more) |*m| m.* = .{ .va = 0x10_0002_0000, .pitch = 256, .format = .bgra8 };
    all.depth = .{ .va = 0x10_0003_0000, .stencil_va = 0x10_0004_0000, .width = 64, .height = 32, .gobs_log2 = 2, .tested = true, .write = true, .stencil = .{}, .back = .{} };
    p = Push{ .buf = &buf };
    emit(&p, &all);
    try p.check();
    try testing.expect(p.words().len < MAX_DWORDS);
    try testing.expectEqual(@as(u32, 0x0fac_6888), ctSelect(8));
}

test "gl3d: what the Legion refused (depth beside pitch colour, a combined depth-stencil format) is refused before it is sent; block-linear colour, X8Z24 and S8Z24 with its stencil plane are sent as NVK sends them" {
    var d = Draw{
        .vertex = .{ .va = 0x10_0000_0000, .registers = 24, .bytes = 0x300 },
        .pixel = .{ .va = 0x10_0000_1000, .registers = 32, .bytes = 0x200 },
        .cb_va = 0x10_0000_2000,
        .cb_bytes = 0x400,
        .zero_va = 0x10_0000_3000,
        .target = .{ .va = 0x10_0001_0000, .width = 64, .height = 32, .pitch = 256 },
        .format = .rgba8,
        .scale = .{ 32, 16, 0.5 },
        .offset = .{ 32, 16, 0.5 },
        .scissor = .{ 0, 0, 64, 32 },
        .count = 6,
    };
    try testing.expectEqual(@as(?[]const u8, null), whyNot(&d));
    d.depth = .{ .va = 0x10_0003_0000, .width = 64, .height = 32, .gobs_log2 = 2, .tested = true, .write = true };
    try testing.expect(std.mem.indexOf(u8, whyNot(&d).?, "RT_LINEAR_WITH_ZETA") != null);
    d.color_gobs = 2;
    try testing.expectEqual(@as(?[]const u8, null), whyNot(&d));
    // (the stream: target 0 block linear, its width in pixels)
    var buf: [MAX_DWORDS]u32 = undefined;
    var p = Push{ .buf = &buf };
    emit(&p, &d);
    try p.check();
    const want = [_]u32{ push.header(SUBCH, gr.SET_COLOR_TARGET_A, 9), 0x10, 0x0001_0000, 64, 32, 0xd5, 0x20, 1, 0, 0 };
    try testing.expect(std.mem.indexOf(u32, p.words(), &want) != null);
    // (the depth target X8Z24: depth in bits 0..23, no stencil)
    try testing.expect(std.mem.indexOf(u32, p.words(), &[_]u32{ push.header(SUBCH, SET_ZT_A, 5), 0x10, 0x0003_0000, ZT_X8Z24, 0x20, 0 }) != null);
    // (a stencil test needs its plane; with it, S8Z24, STENCIL_IS_SEPARATE
    // and SET_ST_*, as NVK sends a Blackwell D24S8 image)
    d.depth.?.stencil = .{};
    try testing.expect(std.mem.indexOf(u8, whyNot(&d).?, "stencil plane") != null);
    d.depth.?.stencil_va = 0x10_0004_0000;
    try testing.expectEqual(@as(?[]const u8, null), whyNot(&d));
    p = Push{ .buf = &buf };
    emit(&p, &d);
    try testing.expect(std.mem.indexOf(u32, p.words(), &[_]u32{ push.header(SUBCH, SET_ZT_A, 5), 0x10, 0x0003_0000, ZT_S8Z24 | ZT_STENCIL_IS_SEPARATE, 0x20, 0 }) != null);
    try testing.expect(std.mem.indexOf(u32, p.words(), &[_]u32{ push.header(SUBCH, SET_ST_A, 4), 0x10, 0x0004_0000, 0x20, 0 }) != null);
    try testing.expect(std.mem.indexOf(u32, p.words(), &[_]u32{ push.header(SUBCH, SET_ST_SIZE_A, 2), 64, 32 }) != null);
    // (front counter-clockwise in the target's rows: the engine's CW)
    try testing.expect(std.mem.indexOf(u32, p.words(), &[_]u32{push.headerImmd(SUBCH, gr.OGL_SET_FRONT_FACE, FRONT_CW)}) != null);
    try testing.expect(frontCcwOf(frontFaceWord(true)) and !frontCcwOf(frontFaceWord(false)));
    // (a target off a GOB is refused as block linear)
    d.target.va += 128;
    try testing.expect(whyNot(&d) != null);
}
