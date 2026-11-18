//! @zpm/ps5gfx state — what a draw's registers say, as values a renderer
//! can use.
//!
//! A PS5 game sets the GPU's registers through command packets, and a
//! draw uses whatever they hold then (ps5's agcdriver.sig keeps them:
//! `State`, three banks). This file reads them: where the colour and
//! depth targets are and what they are made of, the viewport and the
//! scissors, how triangles are culled, tested against depth and blended,
//! where the shaders are and the words a game gave them.
//!
//! Nothing here draws, and nothing here knows a renderer: each function
//! is the registers' own meaning (AMD's, for the GPU family the console
//! has: the register numbers and fields are those of the public headers
//! for it, as open projects document the PS5's use of them). Coordinates
//! are the console's: pixels from a target's top left, y down.
//!
//! A value this cannot make sense of is not guessed: the function answers
//! null, or the raw code is kept for the caller to refuse and name.
//!
//! Allocation-free; pure.

const std = @import("std");
const ps5 = @import("ps5");

pub const State = ps5.agcdriver.State;
const shader = ps5.agc.shader;

// ── Register numbers ────────────────────────────────────────────────────────

/// Context registers.
pub const CX = struct {
    pub const DB_RENDER_CONTROL = 0x000;
    pub const DB_DEPTH_VIEW = 0x002;
    pub const DB_DEPTH_SIZE = 0x007;
    pub const SCREEN_SCISSOR_TL = 0x00C;
    pub const SCREEN_SCISSOR_BR = 0x00D;
    pub const DB_Z_INFO = 0x010;
    pub const DB_STENCIL_INFO = 0x011;
    pub const DB_Z_READ_BASE = 0x012;
    pub const DB_Z_WRITE_BASE = 0x014;
    pub const DB_Z_READ_BASE_HI = 0x01A;
    pub const DB_Z_WRITE_BASE_HI = 0x01C;
    pub const WINDOW_OFFSET = 0x080;
    pub const WINDOW_SCISSOR_TL = 0x081;
    pub const WINDOW_SCISSOR_BR = 0x082;
    pub const CB_TARGET_MASK = 0x08E;
    pub const CB_SHADER_MASK = 0x08F;
    pub const GENERIC_SCISSOR_TL = 0x090;
    pub const GENERIC_SCISSOR_BR = 0x091;
    /// Sixteen pairs, a viewport's own scissor.
    pub const VPORT_SCISSOR_0_TL = 0x094;
    /// Sixteen pairs of floats: the least and most depth a viewport keeps.
    pub const VPORT_ZMIN_0 = 0x0B4;
    pub const BLEND_RED = 0x105;
    /// Sixteen sets of six floats: x scale, x offset, y, y, z, z.
    pub const VPORT_XSCALE_0 = 0x10F;
    /// Thirty-two: where each input of the pixel shader comes from.
    pub const PS_INPUT_CNTL_0 = 0x191;
    pub const PS_INPUT_ENA = 0x1B3;
    pub const PS_INPUT_ADDR = 0x1B4;
    pub const PS_IN_CONTROL = 0x1B6;
    pub const BARYC_CNTL = 0x1B8;
    pub const SHADER_Z_FORMAT = 0x1C4;
    pub const SHADER_COL_FORMAT = 0x1C5;
    /// Eight: a target's blending.
    pub const BLEND0_CONTROL = 0x1E0;
    pub const DB_DEPTH_CONTROL = 0x200;
    pub const CB_COLOR_CONTROL = 0x202;
    pub const DB_SHADER_CONTROL = 0x203;
    pub const CLIP_CNTL = 0x204;
    pub const SU_SC_MODE_CNTL = 0x205;
    pub const VTE_CNTL = 0x206;
    pub const VS_OUT_CNTL = 0x207;
    pub const SC_MODE_CNTL_0 = 0x292;
    pub const SHADER_STAGES_EN = 0x2D5;
    pub const AA_CONFIG = 0x2F8;
    /// Eight targets, fifteen registers each.
    pub const CB_COLOR0_BASE = 0x318;
    pub const CB_COLOR0_VIEW = 0x31B;
    pub const CB_COLOR0_INFO = 0x31C;
    pub const CB_COLOR0_ATTRIB = 0x31D;
    pub const CB_STRIDE = 15;
    /// Eight each, one a target.
    pub const CB_COLOR0_BASE_EXT = 0x390;
    pub const CB_COLOR0_ATTRIB2 = 0x3B0;
    pub const CB_COLOR0_ATTRIB3 = 0x3B8;
};

/// Shader registers.
pub const SH = struct {
    pub const PGM_LO_PS = 0x008;
    pub const USER_DATA_PS_0 = 0x00C;
    pub const USER_DATA_GS_0 = 0x08C;
    /// The vertex side's program (the merged shader's first half).
    pub const PGM_LO_ES = 0x0C8;
    /// User-data words a stage has.
    pub const USER_DATA_WORDS = 32;
};

pub const TARGETS = 8;
pub const VIEWPORTS = 16;

// ── Small helpers ───────────────────────────────────────────────────────────

fn bits(word: u32, lo: u5, n: u6) u32 {
    return (word >> lo) & @as(u32, @truncate((@as(u64, 1) << n) - 1));
}

fn float(word: u32) f32 {
    return @bitCast(word);
}

/// A rectangle of pixels: from (x0, y0), up to and not (x1, y1). y down.
pub const Rect = struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,

    pub fn empty(r: Rect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }

    pub fn meet(a: Rect, b: Rect) Rect {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }
};

// ── Colour targets ──────────────────────────────────────────────────────────

/// What a colour target's words are (`CB_COLOR_INFO`'s format): the bits
/// of each component, as AMD numbers them.
pub const COLOR = struct {
    pub const NONE = 0;
    pub const R8 = 1;
    pub const R16 = 2;
    pub const RG8 = 3;
    pub const R32 = 4;
    pub const RG16 = 5;
    pub const R10G11B11 = 6;
    pub const R11G11B10 = 7;
    pub const R10G10B10A2 = 8;
    pub const A2B10G10R10 = 9;
    pub const RGBA8 = 10;
    pub const RG32 = 11;
    pub const RGBA16 = 12;
    pub const RGBA32 = 14;
    pub const R5G6B5 = 16;
};

/// How a component's bits are read (`CB_COLOR_INFO`'s number type).
pub const NUMBER = struct {
    pub const UNORM = 0;
    pub const SNORM = 1;
    pub const UINT = 4;
    pub const SINT = 5;
    pub const SRGB = 6;
    pub const FLOAT = 7;
};

/// The order components lie in memory (`CB_COLOR_INFO`'s component swap).
/// For four bytes: 0 red first, 1 blue first, 2 and 3 those with alpha
/// first.
pub const SWAP = struct {
    pub const STANDARD = 0;
    pub const ALTERNATE = 1;
    pub const STANDARD_REVERSED = 2;
    pub const ALTERNATE_REVERSED = 3;
};

/// How a surface's pixels are laid out in memory (AMD's swizzle modes).
pub const TILING = struct {
    /// Rows, left to right.
    pub const LINEAR = 0;
};

/// A colour target as the registers describe it.
pub const Target = struct {
    /// Where its pixels are.
    address: u64,
    width: u32,
    height: u32,
    format: u8,
    number: u8,
    swap: u8,
    tiling: u8,
    /// Coverage samples, as a power of two.
    samples_log2: u8,
    mip: u8,
    first_slice: u16,
    last_slice: u16,
    /// 0 one row, 1 a picture, 2 a volume.
    dimension: u8,
    /// The four channels the draw may write (red is bit 0), and the ones
    /// the pixel shader gives at all.
    write: u4,
    shader: u4,

    /// Four bytes a pixel, in one of the two orders a renderer here can
    /// draw into, read as plain fractions (sRGB told apart by `srgb`).
    pub fn bytes4(t: Target) ?enum { rgba, bgra } {
        if (t.format != COLOR.RGBA8) return null;
        if (t.number != NUMBER.UNORM and t.number != NUMBER.SRGB) return null;
        return switch (t.swap) {
            SWAP.STANDARD => .rgba,
            SWAP.ALTERNATE => .bgra,
            else => null,
        };
    }

    pub fn srgb(t: Target) bool {
        return t.number == NUMBER.SRGB;
    }
};

/// Colour target `n`, or null when none is set there.
pub fn target(s: *const State, n: u3) ?Target {
    const i: usize = n;
    const info = s.cx[CX.CB_COLOR0_INFO + CX.CB_STRIDE * i];
    const format = bits(info, 2, 5);
    if (format == COLOR.NONE) return null;
    const view = s.cx[CX.CB_COLOR0_VIEW + CX.CB_STRIDE * i];
    const attrib = s.cx[CX.CB_COLOR0_ATTRIB + CX.CB_STRIDE * i];
    const attrib2 = s.cx[CX.CB_COLOR0_ATTRIB2 + i];
    const attrib3 = s.cx[CX.CB_COLOR0_ATTRIB3 + i];
    return .{
        .address = (@as(u64, s.cx[CX.CB_COLOR0_BASE + CX.CB_STRIDE * i]) << 8) |
            (@as(u64, s.cx[CX.CB_COLOR0_BASE_EXT + i] & 0xFF) << 40),
        .width = bits(attrib2, 14, 14) + 1,
        .height = bits(attrib2, 0, 14) + 1,
        .format = @intCast(format),
        .number = @intCast(bits(info, 8, 3)),
        .swap = @intCast(bits(info, 11, 2)),
        .tiling = @intCast(bits(attrib3, 14, 5)),
        .samples_log2 = @intCast(bits(attrib, 12, 3)),
        .mip = @intCast(bits(view, 26, 4)),
        .first_slice = @intCast(bits(view, 0, 13)),
        .last_slice = @intCast(bits(view, 13, 13)),
        .dimension = @intCast(bits(attrib3, 24, 2)),
        .write = @truncate(s.cx[CX.CB_TARGET_MASK] >> (4 * @as(u5, n))),
        .shader = @truncate(s.cx[CX.CB_SHADER_MASK] >> (4 * @as(u5, n))),
    };
}

/// What the colour path does with a draw (`CB_COLOR_CONTROL`'s mode).
pub const ColorMode = enum { off, normal, other };

pub fn colorMode(s: *const State) ColorMode {
    return switch (bits(s.cx[CX.CB_COLOR_CONTROL], 4, 3)) {
        0 => .off,
        1 => .normal,
        else => .other,
    };
}

// ── Blending ────────────────────────────────────────────────────────────────

/// What a colour is multiplied by before the two are combined.
pub const FACTOR = struct {
    pub const ZERO = 0;
    pub const ONE = 1;
    pub const SRC_COLOR = 2;
    pub const ONE_MINUS_SRC_COLOR = 3;
    pub const SRC_ALPHA = 4;
    pub const ONE_MINUS_SRC_ALPHA = 5;
    pub const DST_ALPHA = 6;
    pub const ONE_MINUS_DST_ALPHA = 7;
    pub const DST_COLOR = 8;
    pub const ONE_MINUS_DST_COLOR = 9;
    pub const SRC_ALPHA_SATURATE = 10;
    pub const CONSTANT_COLOR = 13;
    pub const ONE_MINUS_CONSTANT_COLOR = 14;
    pub const SRC1_COLOR = 15;
    pub const ONE_MINUS_SRC1_COLOR = 16;
    pub const SRC1_ALPHA = 17;
    pub const ONE_MINUS_SRC1_ALPHA = 18;
    pub const CONSTANT_ALPHA = 19;
    pub const ONE_MINUS_CONSTANT_ALPHA = 20;
};

/// How the two are combined: 0 added, 1 the target's taken from the
/// shader's, 2 the lesser, 3 the greater, 4 the shader's from the target's.
pub const COMBINE = struct {
    pub const ADD = 0;
    pub const SUBTRACT = 1;
    pub const MIN = 2;
    pub const MAX = 3;
    pub const REVERSE_SUBTRACT = 4;
};

/// A target's blending: null when it has none (the shader's colour is
/// written as it is).
pub const Blend = struct {
    color_src: u8,
    color_dst: u8,
    color_op: u8,
    alpha_src: u8,
    alpha_dst: u8,
    alpha_op: u8,
    constant: [4]f32,
};

pub fn blend(s: *const State, n: u3) ?Blend {
    const c = s.cx[CX.BLEND0_CONTROL + @as(usize, n)];
    if (bits(c, 30, 1) == 0) return null;
    const separate = bits(c, 29, 1) != 0;
    const src = bits(c, 0, 5);
    const op = bits(c, 5, 3);
    const dst = bits(c, 8, 5);
    return .{
        .color_src = @intCast(src),
        .color_dst = @intCast(dst),
        .color_op = @intCast(op),
        .alpha_src = @intCast(if (separate) bits(c, 16, 5) else src),
        .alpha_dst = @intCast(if (separate) bits(c, 24, 5) else dst),
        .alpha_op = @intCast(if (separate) bits(c, 21, 3) else op),
        .constant = .{
            float(s.cx[CX.BLEND_RED]),
            float(s.cx[CX.BLEND_RED + 1]),
            float(s.cx[CX.BLEND_RED + 2]),
            float(s.cx[CX.BLEND_RED + 3]),
        },
    };
}

// ── Depth ───────────────────────────────────────────────────────────────────

/// A comparison: 0 never, 1 less, 2 equal, 3 less or equal, 4 greater,
/// 5 not equal, 6 greater or equal, 7 always. (Bit 0 less, bit 1 equal,
/// bit 2 greater.)
pub const Compare = u3;

/// The depth target and the test against it.
pub const Depth = struct {
    /// Where the depth values are; 0 with `format` 0: no depth target.
    address: u64,
    width: u32,
    height: u32,
    /// 0 none, 1 sixteen bits, 3 thirty-two bits of float.
    format: u8,
    tiling: u8,
    samples_log2: u8,
    /// The draw compares against the target, and what passes.
    test_on: bool,
    func: Compare,
    /// What passes is written.
    write: bool,
    /// The draw only clears the target (to `clear`).
    clears: bool,
    clear: f32,
    stencil_on: bool,
};

pub fn depth(s: *const State) Depth {
    const info = s.cx[CX.DB_Z_INFO];
    const control = s.cx[CX.DB_DEPTH_CONTROL];
    const size = s.cx[CX.DB_DEPTH_SIZE];
    const view = s.cx[CX.DB_DEPTH_VIEW];
    const format = bits(info, 0, 2);
    return .{
        .address = if (format == 0) 0 else (@as(u64, s.cx[CX.DB_Z_WRITE_BASE]) << 8) |
            (@as(u64, s.cx[CX.DB_Z_WRITE_BASE_HI] & 0xFF) << 40),
        .width = bits(size, 0, 14) + 1,
        .height = bits(size, 16, 14) + 1,
        .format = @intCast(format),
        .tiling = @intCast(bits(info, 4, 5)),
        .samples_log2 = @intCast(bits(info, 2, 2)),
        .test_on = format != 0 and bits(control, 1, 1) != 0,
        .func = @intCast(bits(control, 4, 3)),
        // (a view marked read-only is not written, whatever the control says)
        .write = format != 0 and bits(control, 2, 1) != 0 and bits(view, 24, 1) == 0,
        .clears = bits(s.cx[CX.DB_RENDER_CONTROL], 0, 1) != 0,
        .clear = float(s.cx[0x00B]),
        .stencil_on = bits(control, 0, 1) != 0 and bits(s.cx[CX.DB_STENCIL_INFO], 0, 1) != 0,
    };
}

// ── Viewport, scissor, rasteriser ───────────────────────────────────────────

/// A viewport: a clip-space position (after the divide) times `scale`
/// plus `offset` is a pixel and a depth. Depth is kept to `zmin..zmax`.
pub const Viewport = struct {
    scale: [3]f32,
    offset: [3]f32,
    zmin: f32,
    zmax: f32,
    /// Clip space's depth runs 0 to 1 (else -1 to 1).
    zero_to_one: bool,
    /// Depth outside the range is clamped, not clipped away.
    depth_clamp: bool,
};

/// Viewport `v`. Null when the transform is switched off in part (all of
/// it on, or all of it off, are the two a game sets): with all of it off
/// the position is already in pixels, and the answer is scale 1, offset 0.
pub fn viewport(s: *const State, v: u4) ?Viewport {
    const i: usize = v;
    const clip = s.cx[CX.CLIP_CNTL];
    var out: Viewport = .{
        .scale = .{ 1, 1, 1 },
        .offset = .{ 0, 0, 0 },
        .zmin = float(s.cx[CX.VPORT_ZMIN_0 + 2 * i]),
        .zmax = float(s.cx[CX.VPORT_ZMIN_0 + 2 * i + 1]),
        .zero_to_one = bits(clip, 19, 1) != 0,
        .depth_clamp = bits(clip, 26, 2) != 0,
    };
    switch (s.cx[CX.VTE_CNTL]) {
        0 => {},
        0x43F => {
            const r = s.cx[CX.VPORT_XSCALE_0 + 6 * i ..][0..6];
            out.scale = .{ float(r[0]), float(r[2]), float(r[4]) };
            out.offset = .{ float(r[1]), float(r[3]), float(r[5]) };
        },
        else => return null,
    }
    return out;
}

fn corner(word: u32) [2]i32 {
    return .{ @intCast(bits(word, 0, 15)), @intCast(bits(word, 16, 15)) };
}

fn pair(s: *const State, tl: usize) Rect {
    const a = corner(s.cx[tl]);
    const b = corner(s.cx[tl + 1]);
    return .{ .x0 = a[0], .y0 = a[1], .x1 = b[0], .y1 = b[1] };
}

/// The pixels a draw may touch in a target `width` by `height`: the
/// target itself and every scissor that applies, met. `v`: the viewport
/// whose own scissor counts when viewport scissors are on.
pub fn scissor(s: *const State, width: u32, height: u32, v: u4) Rect {
    var r: Rect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(width), .y1 = @intCast(height) };
    r = r.meet(pair(s, CX.SCREEN_SCISSOR_TL));
    r = r.meet(pair(s, CX.WINDOW_SCISSOR_TL));
    r = r.meet(pair(s, CX.GENERIC_SCISSOR_TL));
    if (bits(s.cx[CX.SC_MODE_CNTL_0], 1, 1) != 0) r = r.meet(pair(s, CX.VPORT_SCISSOR_0_TL + 2 * @as(usize, v)));
    return if (r.empty()) .{} else r;
}

/// How triangles are told front from back, and which are dropped.
pub const Raster = struct {
    cull_front: bool,
    cull_back: bool,
    /// A front triangle's corners go round clockwise on the screen (y
    /// down), else the other way.
    front_clockwise: bool,
    /// Triangles are filled (else drawn as lines or points: `fill` false).
    fill: bool,
    /// The last vertex of a primitive gives its flat values, else the
    /// first.
    provoke_last: bool,
    samples_log2: u8,
};

pub fn raster(s: *const State) Raster {
    const m = s.cx[CX.SU_SC_MODE_CNTL];
    return .{
        .cull_front = bits(m, 0, 1) != 0,
        .cull_back = bits(m, 1, 1) != 0,
        .front_clockwise = bits(m, 2, 1) != 0,
        .fill = bits(m, 3, 2) == 0,
        .provoke_last = bits(m, 19, 1) != 0,
        .samples_log2 = @intCast(bits(s.cx[CX.AA_CONFIG], 0, 3)),
    };
}

/// What a draw's vertices make (`ps5.agc.shader.PRIMITIVE`).
pub fn primitive(s: *const State) u32 {
    return s.uc[ps5.agcdriver.UC.PRIMITIVE_TYPE] & 0x3F;
}

// ── Shaders ─────────────────────────────────────────────────────────────────

/// Which of the shader stages a draw runs.
pub const Stages = struct {
    word: u32,

    pub fn geometry(st: Stages) bool {
        return (st.word & shader.STAGES.GEOMETRY) != 0;
    }
    pub fn hull(st: Stages) bool {
        return (st.word & shader.STAGES.HULL) != 0;
    }
    /// Lanes the vertex side's code runs at once.
    pub fn vertexLanes(st: Stages) u8 {
        return if ((st.word & shader.STAGES.VERTEX_WAVE32) != 0) 32 else 64;
    }
};

pub fn stages(s: *const State) Stages {
    return .{ .word = s.cx[CX.SHADER_STAGES_EN] };
}

/// A stage's code and the words a game gave it.
pub const Program = struct {
    /// Where the code is (0: none set).
    address: u64,
    user: *const [SH.USER_DATA_WORDS]u32,
};

/// The vertex side (the merged shader every PS5 draw's vertices go
/// through).
pub fn vertexProgram(s: *const State) Program {
    return .{
        .address = shader.programAddress(s.sh[SH.PGM_LO_ES], s.sh[SH.PGM_LO_ES + 1]),
        .user = s.sh[SH.USER_DATA_GS_0..][0..SH.USER_DATA_WORDS],
    };
}

pub fn pixelProgram(s: *const State) Program {
    return .{
        .address = shader.programAddress(s.sh[SH.PGM_LO_PS], s.sh[SH.PGM_LO_PS + 1]),
        .user = s.sh[SH.USER_DATA_PS_0..][0..SH.USER_DATA_WORDS],
    };
}

/// Where one input of the pixel shader comes from (`PS_INPUT_CNTL`).
pub const PixelInput = struct {
    /// The vertex side's output slot; null: the default value.
    slot: ?u5,
    /// One vertex's value for the whole primitive.
    flat: bool,
    /// The default: (0,0,0,0), (0,0,0,1), (1,1,1,0), (1,1,1,1).
    default: u2,
    /// Two 16-bit halves in each word.
    halves: bool,

    pub fn defaultValue(p: PixelInput) [4]f32 {
        const xyz: f32 = if ((p.default & 2) != 0) 1 else 0;
        const w: f32 = if ((p.default & 1) != 0) 1 else 0;
        return .{ xyz, xyz, xyz, w };
    }
};

pub fn pixelInput(s: *const State, n: u5) PixelInput {
    const c = s.cx[CX.PS_INPUT_CNTL_0 + @as(usize, n)];
    const I = shader.INPUT;
    return .{
        .slot = if ((c & I.DEFAULT) != 0) null else @intCast(c & I.SLOT),
        .flat = (c & I.FLAT) != 0,
        .default = @intCast(bits(c, I.DEFAULT_VALUE_SHIFT, 2)),
        .halves = (c & I.HALVES) != 0,
    };
}

/// How the pixel shader is entered and what it gives back.
pub const PixelSetup = struct {
    /// Inputs it has (`PS_IN_CONTROL`).
    inputs: u8,
    /// Lanes its code runs at once.
    lanes: u8,
    /// Which of sixteen built-in values it is handed and in which
    /// registers (`PS_INPUT_ENA`, `PS_INPUT_ADDR`): `builtinRegister`.
    enabled: u16,
    placed: u16,
    /// A colour output's layout, four bits a target (`COL_FORMAT`).
    color_formats: u32,
    /// It may drop a pixel; it gives its own depth.
    may_kill: bool,
    writes_depth: bool,
};

pub fn pixelSetup(s: *const State) PixelSetup {
    const in = s.cx[CX.PS_IN_CONTROL];
    const db = s.cx[CX.DB_SHADER_CONTROL];
    return .{
        .inputs = @intCast(bits(in, 0, 6)),
        .lanes = if (bits(in, 15, 1) != 0) 32 else 64,
        .enabled = @truncate(s.cx[CX.PS_INPUT_ENA]),
        .placed = @truncate(s.cx[CX.PS_INPUT_ADDR]),
        .color_formats = s.cx[CX.SHADER_COL_FORMAT],
        .may_kill = bits(db, 6, 1) != 0,
        .writes_depth = bits(db, 0, 1) != 0,
    };
}

/// The built-in values a pixel shader can be handed, in the order their
/// registers are given out.
pub const BUILTIN = struct {
    pub const PERSP_SAMPLE = 0;
    pub const PERSP_CENTER = 1;
    pub const PERSP_CENTROID = 2;
    pub const PERSP_PULL_MODEL = 3;
    pub const LINEAR_SAMPLE = 4;
    pub const LINEAR_CENTER = 5;
    pub const LINEAR_CENTROID = 6;
    pub const LINE_STIPPLE = 7;
    pub const POS_X = 8;
    pub const POS_Y = 9;
    pub const POS_Z = 10;
    pub const POS_W = 11;
    pub const FRONT_FACE = 12;
    pub const ANCILLARY = 13;
    pub const SAMPLE_COVERAGE = 14;
    pub const POS_FIXED = 15;

    /// Registers a built-in takes.
    pub fn size(kind: u4) u8 {
        return switch (kind) {
            PERSP_SAMPLE, PERSP_CENTER, PERSP_CENTROID, LINEAR_SAMPLE, LINEAR_CENTER, LINEAR_CENTROID => 2,
            PERSP_PULL_MODEL => 3,
            else => 1,
        };
    }
};

/// The first register a built-in is in at the pixel shader's entry, or
/// null when the shader is not handed it. Registers go to the placed
/// built-ins in order from v0, whether enabled or not.
pub fn builtinRegister(p: PixelSetup, kind: u4) ?u8 {
    if (((p.placed >> kind) & 1) == 0) return null;
    var at: u8 = 0;
    var k: u4 = 0;
    while (k < kind) : (k += 1) {
        if (((p.placed >> k) & 1) != 0) at += BUILTIN.size(k);
    }
    return if (((p.enabled >> kind) & 1) != 0) at else null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fresh = struct {
    var state: State = undefined;

    fn get() *State {
        state.reset();
        return &state;
    }
};

fn f(x: f32) u32 {
    return @bitCast(x);
}

test "a colour target: where it is, its size, what its pixels are made of" {
    const s = Fresh.get();
    for (0..TARGETS) |n| try testing.expectEqual(@as(?Target, null), target(s, @intCast(n)));

    // Target 1: 1920 x 1080, four bytes with blue first, sRGB, at an
    // address above 2^40, mip 2, slices 3 to 5.
    const n = 1;
    s.cx[CX.CB_COLOR0_BASE + CX.CB_STRIDE * n] = 0x1234_5678;
    s.cx[CX.CB_COLOR0_BASE_EXT + n] = 0xFFFF_FF7A;
    s.cx[CX.CB_COLOR0_INFO + CX.CB_STRIDE * n] = (COLOR.RGBA8 << 2) | (NUMBER.SRGB << 8) | (SWAP.ALTERNATE << 11);
    s.cx[CX.CB_COLOR0_VIEW + CX.CB_STRIDE * n] = 3 | (5 << 13) | (2 << 26);
    s.cx[CX.CB_COLOR0_ATTRIB + CX.CB_STRIDE * n] = 2 << 12;
    s.cx[CX.CB_COLOR0_ATTRIB2 + n] = 1079 | (1919 << 14) | (3 << 28);
    s.cx[CX.CB_COLOR0_ATTRIB3 + n] = (27 << 14) | (1 << 24);
    s.cx[CX.CB_TARGET_MASK] = 0x0000_0070;
    s.cx[CX.CB_SHADER_MASK] = 0x0000_00F0;
    const t = target(s, n).?;
    try testing.expectEqual(@as(u64, 0x7A_1234_5678_00), t.address);
    try testing.expectEqual(@as(u32, 1920), t.width);
    try testing.expectEqual(@as(u32, 1080), t.height);
    try testing.expectEqual(@as(u8, COLOR.RGBA8), t.format);
    try testing.expectEqual(@as(u8, 27), t.tiling);
    try testing.expectEqual(@as(u8, 1), t.dimension);
    try testing.expectEqual(@as(u8, 2), t.samples_log2);
    try testing.expectEqual(@as(u8, 2), t.mip);
    try testing.expectEqual(@as(u16, 3), t.first_slice);
    try testing.expectEqual(@as(u16, 5), t.last_slice);
    try testing.expectEqual(@as(u4, 7), t.write);
    try testing.expectEqual(@as(u4, 0xF), t.shader);
    try testing.expect(t.bytes4().? == .bgra);
    try testing.expect(t.srgb());
    // The neighbours are still none: fifteen registers a target, not one.
    try testing.expectEqual(@as(?Target, null), target(s, 0));
    try testing.expectEqual(@as(?Target, null), target(s, 2));

    // Layouts a renderer here cannot draw into are told apart, not taken
    // for four bytes.
    var other = t;
    other.swap = SWAP.STANDARD;
    try testing.expect(other.bytes4().? == .rgba);
    other.swap = SWAP.STANDARD_REVERSED;
    try testing.expect(other.bytes4() == null);
    other = t;
    other.number = NUMBER.UINT;
    try testing.expect(other.bytes4() == null);
    other = t;
    other.format = COLOR.RGBA16;
    try testing.expect(other.bytes4() == null);

    try testing.expectEqual(ColorMode.normal, colorMode(s));
    s.cx[CX.CB_COLOR_CONTROL] = 0x00CC_0000;
    try testing.expectEqual(ColorMode.off, colorMode(s));
    s.cx[CX.CB_COLOR_CONTROL] = 0x00CC_0020;
    try testing.expectEqual(ColorMode.other, colorMode(s));
}

test "blending: off as a queue starts, one rule for colour and alpha unless they are separate" {
    const s = Fresh.get();
    try testing.expectEqual(@as(?Blend, null), blend(s, 0));

    // On, source alpha and one minus it, added; the alpha fields are set
    // to something else and not separate: they do not count.
    s.cx[CX.BLEND0_CONTROL + 2] = (1 << 30) | FACTOR.SRC_ALPHA | (COMBINE.ADD << 5) | (FACTOR.ONE_MINUS_SRC_ALPHA << 8) |
        (FACTOR.ONE << 16) | (COMBINE.MAX << 21) | (FACTOR.ZERO << 24);
    for (0..4) |c| s.cx[CX.BLEND_RED + c] = f(0.25 * @as(f32, @floatFromInt(c + 1)));
    var b = blend(s, 2).?;
    try testing.expectEqual(@as(u8, FACTOR.SRC_ALPHA), b.color_src);
    try testing.expectEqual(@as(u8, FACTOR.ONE_MINUS_SRC_ALPHA), b.color_dst);
    try testing.expectEqual(@as(u8, COMBINE.ADD), b.color_op);
    try testing.expectEqual(@as(u8, FACTOR.SRC_ALPHA), b.alpha_src);
    try testing.expectEqual(@as(u8, FACTOR.ONE_MINUS_SRC_ALPHA), b.alpha_dst);
    try testing.expectEqual(@as(u8, COMBINE.ADD), b.alpha_op);
    try testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 1.0 }, b.constant);
    try testing.expectEqual(@as(?Blend, null), blend(s, 1));

    s.cx[CX.BLEND0_CONTROL + 2] |= 1 << 29;
    b = blend(s, 2).?;
    try testing.expectEqual(@as(u8, FACTOR.SRC_ALPHA), b.color_src);
    try testing.expectEqual(@as(u8, FACTOR.ONE), b.alpha_src);
    try testing.expectEqual(@as(u8, FACTOR.ZERO), b.alpha_dst);
    try testing.expectEqual(@as(u8, COMBINE.MAX), b.alpha_op);
}

test "depth: the target, the test, and when nothing is written" {
    const s = Fresh.get();
    var d = depth(s);
    try testing.expectEqual(@as(u8, 0), d.format);
    try testing.expectEqual(@as(u64, 0), d.address);
    try testing.expect(!d.test_on and !d.write and !d.clears and !d.stencil_on);

    s.cx[CX.DB_Z_INFO] = 3 | (1 << 2) | (10 << 4);
    s.cx[CX.DB_Z_WRITE_BASE] = 0x00AB_CDEF;
    s.cx[CX.DB_Z_WRITE_BASE_HI] = 0x12;
    s.cx[CX.DB_DEPTH_SIZE] = 1279 | (719 << 16);
    // Test on, write on, "greater or equal"; stencil asked for, but the
    // target has none.
    s.cx[CX.DB_DEPTH_CONTROL] = 1 | (1 << 1) | (1 << 2) | (6 << 4);
    s.cx[0x00B] = f(0.5);
    d = depth(s);
    try testing.expectEqual(@as(u8, 3), d.format);
    try testing.expectEqual(@as(u64, 0x12_00AB_CDEF_00), d.address);
    try testing.expectEqual(@as(u32, 1280), d.width);
    try testing.expectEqual(@as(u32, 720), d.height);
    try testing.expectEqual(@as(u8, 10), d.tiling);
    try testing.expectEqual(@as(u8, 1), d.samples_log2);
    try testing.expect(d.test_on and d.write and !d.clears and !d.stencil_on);
    try testing.expectEqual(@as(Compare, 6), d.func);
    try testing.expectEqual(@as(f32, 0.5), d.clear);

    s.cx[CX.DB_STENCIL_INFO] = 1;
    try testing.expect(depth(s).stencil_on);
    // A read-only view is not written; a clearing draw says so.
    s.cx[CX.DB_DEPTH_VIEW] = 1 << 24;
    try testing.expect(!depth(s).write);
    try testing.expect(depth(s).test_on);
    s.cx[CX.DB_RENDER_CONTROL] = 1;
    try testing.expect(depth(s).clears);
    // With no target, the control's bits mean nothing.
    s.cx[CX.DB_Z_INFO] = 0;
    s.cx[CX.DB_DEPTH_VIEW] = 0;
    d = depth(s);
    try testing.expect(!d.test_on and !d.write);
}

test "the viewport and the scissors" {
    const s = Fresh.get();
    // As a queue starts: the transform off, so pixels in, pixels out.
    var v = viewport(s, 0).?;
    try testing.expectEqual([3]f32{ 1, 1, 1 }, v.scale);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, v.offset);
    try testing.expect(!v.zero_to_one and !v.depth_clamp);

    // Viewport 3 of a 1280 x 720 target, y up in clip space, depth 0 to 1.
    s.cx[CX.VTE_CNTL] = 0x43F;
    const r = s.cx[CX.VPORT_XSCALE_0 + 6 * 3 ..][0..6];
    r.* = .{ f(640), f(640), f(-360), f(360), f(1), f(0) };
    s.cx[CX.VPORT_ZMIN_0 + 2 * 3] = f(0);
    s.cx[CX.VPORT_ZMIN_0 + 2 * 3 + 1] = f(1);
    s.cx[CX.CLIP_CNTL] = (1 << 19) | (1 << 27);
    v = viewport(s, 3).?;
    try testing.expectEqual([3]f32{ 640, -360, 1 }, v.scale);
    try testing.expectEqual([3]f32{ 640, 360, 0 }, v.offset);
    try testing.expectEqual(@as(f32, 0), v.zmin);
    try testing.expectEqual(@as(f32, 1), v.zmax);
    try testing.expect(v.zero_to_one and v.depth_clamp);
    // (viewport 0 is still what a queue starts with: scale 1, no offset)
    try testing.expectEqual([3]f32{ 1, 1, 1 }, viewport(s, 0).?.scale);
    // Part of the transform off: not a state this reads.
    s.cx[CX.VTE_CNTL] = 0x43E;
    try testing.expect(viewport(s, 3) == null);

    // Scissors as a queue starts: the whole target.
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 }, scissor(s, 1280, 720, 0));
    // Each one cuts: the screen's on the left, the window's on top, the
    // generic one on the right and at the bottom.
    s.cx[CX.SCREEN_SCISSOR_TL] = 100;
    s.cx[CX.WINDOW_SCISSOR_TL] = (50 << 16) | 0x8000_0000;
    s.cx[CX.GENERIC_SCISSOR_BR] = 1000 | (600 << 16);
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 50, .x1 = 1000, .y1 = 600 }, scissor(s, 1280, 720, 0));
    // A viewport's own scissor counts while viewport scissors are on (as
    // a queue starts), and only that viewport's.
    s.cx[CX.VPORT_SCISSOR_0_TL + 2 * 3] = 200 | (100 << 16);
    s.cx[CX.VPORT_SCISSOR_0_TL + 2 * 3 + 1] = 900 | (500 << 16);
    try testing.expectEqual(Rect{ .x0 = 200, .y0 = 100, .x1 = 900, .y1 = 500 }, scissor(s, 1280, 720, 3));
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 50, .x1 = 1000, .y1 = 600 }, scissor(s, 1280, 720, 0));
    s.cx[CX.SC_MODE_CNTL_0] = 0;
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 50, .x1 = 1000, .y1 = 600 }, scissor(s, 1280, 720, 3));
    // Nothing left: the empty rectangle, not a negative one.
    s.cx[CX.GENERIC_SCISSOR_BR] = 80 | (600 << 16);
    try testing.expect(scissor(s, 1280, 720, 0).empty());
    try testing.expectEqual(Rect{}, scissor(s, 1280, 720, 0));
    // A target smaller than every scissor.
    s.cx[CX.GENERIC_SCISSOR_BR] = 0x4000_4000;
    s.cx[CX.SCREEN_SCISSOR_TL] = 0;
    s.cx[CX.WINDOW_SCISSOR_TL] = 0x8000_0000;
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 64, .y1 = 32 }, scissor(s, 64, 32, 0));
}

test "the rasteriser's mode and the primitive" {
    const s = Fresh.get();
    var r = raster(s);
    try testing.expect(!r.cull_front and !r.cull_back and !r.front_clockwise and r.fill and !r.provoke_last);
    s.cx[CX.SU_SC_MODE_CNTL] = 2 | 4 | (1 << 19);
    s.cx[CX.AA_CONFIG] = 2;
    r = raster(s);
    try testing.expect(!r.cull_front and r.cull_back and r.front_clockwise and r.fill and r.provoke_last);
    try testing.expectEqual(@as(u8, 2), r.samples_log2);
    s.cx[CX.SU_SC_MODE_CNTL] = 1 | (1 << 3);
    r = raster(s);
    try testing.expect(r.cull_front and !r.fill);

    s.uc[ps5.agcdriver.UC.PRIMITIVE_TYPE] = shader.PRIMITIVE.TRIANGLE_STRIP;
    try testing.expectEqual(shader.PRIMITIVE.TRIANGLE_STRIP, primitive(s));
}

test "the shaders: where they are, their words, the stages" {
    const s = Fresh.get();
    try testing.expectEqual(@as(u64, 0), vertexProgram(s).address);
    s.sh[SH.PGM_LO_ES] = 0x0012_3456;
    s.sh[SH.PGM_LO_ES + 1] = 0xFFFF_FF02;
    s.sh[SH.PGM_LO_PS] = 0x0065_4321;
    s.sh[SH.USER_DATA_GS_0 + 5] = 0xAAAA;
    s.sh[SH.USER_DATA_PS_0 + 31] = 0xBBBB;
    const v = vertexProgram(s);
    const p = pixelProgram(s);
    try testing.expectEqual(@as(u64, 0x02_0012_3456_00), v.address);
    try testing.expectEqual(@as(u64, 0x6543_2100), p.address);
    try testing.expectEqual(@as(u32, 0xAAAA), v.user[5]);
    try testing.expectEqual(@as(u32, 0xBBBB), p.user[31]);

    try testing.expect(!stages(s).geometry() and !stages(s).hull());
    try testing.expectEqual(@as(u8, 64), stages(s).vertexLanes());
    s.cx[CX.SHADER_STAGES_EN] = 0x0040_2024;
    try testing.expect(stages(s).geometry() and stages(s).hull());
    try testing.expectEqual(@as(u8, 32), stages(s).vertexLanes());
}

test "a pixel shader's inputs and its built-in values' registers" {
    const s = Fresh.get();
    // Input 0 from slot 3; input 1 flat from slot 31; input 2 the default
    // (0,0,0,1); input 3 the default (1,1,1,1) in halves.
    s.cx[CX.PS_INPUT_CNTL_0 + 0] = 3;
    s.cx[CX.PS_INPUT_CNTL_0 + 1] = 31 | (1 << 10);
    s.cx[CX.PS_INPUT_CNTL_0 + 2] = 0x20 | (1 << 8);
    s.cx[CX.PS_INPUT_CNTL_0 + 3] = 0x20 | (3 << 8) | (1 << 19);
    var in = pixelInput(s, 0);
    try testing.expectEqual(@as(?u5, 3), in.slot);
    try testing.expect(!in.flat and !in.halves);
    in = pixelInput(s, 1);
    try testing.expectEqual(@as(?u5, 31), in.slot);
    try testing.expect(in.flat);
    in = pixelInput(s, 2);
    try testing.expectEqual(@as(?u5, null), in.slot);
    try testing.expectEqual([4]f32{ 0, 0, 0, 1 }, in.defaultValue());
    in = pixelInput(s, 3);
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, in.defaultValue());
    try testing.expect(in.halves);

    // Handed: the perspective centre pair and the pixel's x and y.
    s.cx[CX.PS_INPUT_ENA] = 0x302;
    s.cx[CX.PS_INPUT_ADDR] = 0x302;
    s.cx[CX.PS_IN_CONTROL] = 4 | (1 << 15);
    s.cx[CX.SHADER_COL_FORMAT] = 0x94;
    s.cx[CX.DB_SHADER_CONTROL] = (1 << 6) | 1;
    var p = pixelSetup(s);
    try testing.expectEqual(@as(u8, 4), p.inputs);
    try testing.expectEqual(@as(u8, 32), p.lanes);
    try testing.expectEqual(@as(u32, 0x94), p.color_formats);
    try testing.expect(p.may_kill and p.writes_depth);
    try testing.expectEqual(@as(?u8, 0), builtinRegister(p, BUILTIN.PERSP_CENTER));
    try testing.expectEqual(@as(?u8, 2), builtinRegister(p, BUILTIN.POS_X));
    try testing.expectEqual(@as(?u8, 3), builtinRegister(p, BUILTIN.POS_Y));
    try testing.expectEqual(@as(?u8, null), builtinRegister(p, BUILTIN.POS_Z));
    try testing.expectEqual(@as(?u8, null), builtinRegister(p, BUILTIN.PERSP_SAMPLE));
    // Placed and not enabled: its registers are kept free, nothing is in
    // them, and what follows moves up. The pull model takes three.
    p.placed = 0x30B;
    p.enabled = 0x302;
    try testing.expectEqual(@as(?u8, null), builtinRegister(p, BUILTIN.PERSP_SAMPLE));
    try testing.expectEqual(@as(?u8, 2), builtinRegister(p, BUILTIN.PERSP_CENTER));
    try testing.expectEqual(@as(?u8, null), builtinRegister(p, BUILTIN.PERSP_PULL_MODEL));
    try testing.expectEqual(@as(?u8, 7), builtinRegister(p, BUILTIN.POS_X));
    try testing.expectEqual(@as(?u8, 8), builtinRegister(p, BUILTIN.POS_Y));
}
