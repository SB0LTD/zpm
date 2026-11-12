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
//! - the colour target (rows of bytes: RGBA8, BGRA8, RG8, R8), the
//!   channels written, the blend (GL's factors and equations, the
//!   constant colour), the viewport (x, y and depth: GL's -w..w clip
//!   volume), the scissor;
//! - the primitives: triangles, a strip or a fan of `count` vertices, the
//!   vertex's index 0 .. count - 1 (the programs fetch their attributes
//!   and the element array themselves), `instances` times.
//!
//! Not yet (the GL layer keeps such draws on its compute kernels): depth
//! and stencil targets and tests, more than one colour target, culling,
//! points and lines, multisampling.
//!
//! Nothing here has run on the Legion's RTX; the emulated engine (emu3d)
//! runs it.
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

// The depth-stencil target and its tests (cl9097.h's methods).
pub const SET_ZT_A: u32 = 0x0fe0; // address (high), then low, format, block size, array pitch
pub const SET_ZT_SIZE_A: u32 = 0x1228; // width, height, third dimension
/// SET_ZT_FORMAT: S8Z24 (depth in bits 0..23, stencil 24..31: GL's
/// DEPTH24_STENCIL8 as the engine keeps it; Mesa's Z24_UNORM_S8_UINT).
pub const ZT_S8Z24: u32 = 0x14;
pub const SET_STENCIL_OP_FAIL: u32 = 0x1384; // fail, zfail, zpass, func, ref, func mask, write mask

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

/// A depth-stencil target: block linear (whole 64-byte GOBs across,
/// blocks of 2^gobs_log2 GOBs), S8Z24.
pub const Depth = struct {
    va: u64,
    width: u32,
    height: u32,
    gobs_log2: u3,
    tested: bool,
    write: bool,
    /// NEVER 0 .. ALWAYS 7 (the OGL value is 0x200 + it)
    func: u3 = 1,
    /// one for both faces (two-sided stencil is not sent)
    stencil: ?Stencil = null,
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
};

/// OGL_SET_CULL_FACE (cl9097.h): the faces culled when OGL_SET_CULL is on.
pub const OGL_SET_CULL_FACE: u32 = 0x1920;
pub const CULL_FRONT: u32 = 0x404;
pub const CULL_BACK: u32 = 0x405;
pub const CULL_FRONT_AND_BACK: u32 = 0x408;
/// OGL_SET_FRONT_FACE's values.
pub const FRONT_CW: u32 = 0x900;
pub const FRONT_CCW: u32 = 0x901;

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
    // the target's own format, its channels
    many(p, gr.SET_COLOR_TARGET_A + 16, &.{targetFormat(d.format)});
    many(p, gr.SET_CT_WRITE, &.{@as(u32, d.mask & 1) | @as(u32, (d.mask >> 1) & 1) << 4 | @as(u32, (d.mask >> 2) & 1) << 8 | @as(u32, (d.mask >> 3) & 1) << 12});
    // the viewport: x, y and depth; GL's clip volume (-w <= z <= w)
    many(p, gr.SET_VIEWPORT_SCALE_X, &.{ bits(d.scale[0]), bits(d.scale[1]), bits(d.scale[2]), bits(d.offset[0]), bits(d.offset[1]), bits(d.offset[2]) });
    one(p, gr.SET_VIEWPORT_Z_CLIP, SET_VIEWPORT_SCALE_Z_CLIP_GL);
    gr.setScissor(p, d.scissor[0], d.scissor[1], d.scissor[2], d.scissor[3]);
    one(p, gr.SET_PROVOKING_VERTEX, PROVOKING_LAST);
    one(p, gr.OGL_SET_FRONT_FACE, if (d.front_ccw) FRONT_CCW else FRONT_CW);
    if (d.cull != 0) {
        one(p, OGL_SET_CULL_FACE, switch (d.cull) {
            1 => CULL_FRONT,
            2 => CULL_BACK,
            else => CULL_FRONT_AND_BACK,
        });
        one(p, gr.OGL_SET_CULL, 1);
    } else one(p, gr.OGL_SET_CULL, 0);
    if (d.depth) |z| {
        many(p, SET_ZT_A, &.{ @truncate(z.va >> 32), @truncate(z.va), ZT_S8Z24, @as(u32, z.gobs_log2) << 4, 0 });
        many(p, SET_ZT_SIZE_A, &.{ z.width, z.height, 0x1_0001 });
        one(p, gr.SET_ZT_SELECT, 1);
        one(p, gr.SET_DEPTH_TEST, @intFromBool(z.tested));
        one(p, gr.SET_DEPTH_WRITE, @intFromBool(z.write));
        many(p, gr.SET_DEPTH_FUNC, &.{0x200 + @as(u32, z.func)});
        if (z.stencil) |s| {
            one(p, gr.SET_STENCIL_TEST, 1);
            many(p, SET_STENCIL_OP_FAIL, &.{ @intFromEnum(s.fail), @intFromEnum(s.zfail), @intFromEnum(s.zpass), 0x200 + @as(u32, s.func), s.reference, s.value_mask, s.write_mask });
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
    many(p, gr.SET_DRAW_CONTROL_A, &.{ gr.DRAW_CONTROL, d.instances });
    many(p, gr.DRAW_VERTEX_ARRAY_BEGIN_END_A, &.{ 0, d.count });
}

/// Dwords emit takes at most (draw.sig's state, and the draw's own).
pub const MAX_DWORDS = 900;

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
}
