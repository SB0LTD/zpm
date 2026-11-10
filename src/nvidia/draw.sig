//! @zpm/nvidia draw — rectangles drawn by the RTX's 3D engine (BLACKWELL_B,
//! class 0xce97), over any Device (Galaxy's kernel driver, or EmuDevice in
//! the tests).
//!
//! What a compositor draws with, the same calls as the Adreno's renderer
//! (adreno/draw.sig; gpu/draw.sig is the interface above both): a solid
//! color, an image (a texture times a color), a mask (an 8-bit coverage
//! texture times a color), each a rectangle in window pixels, replacing the
//! target's pixels or blended over them (premultiplied alpha), inside a
//! scissor; and the same with a rounded rectangle's coverage worked out per
//! pixel. The rasterizer walks the rectangle, the texture unit filters, the
//! render backend blends: no compute kernel.
//!
//! How a rectangle reaches the engine. It is a triangle strip of four
//! vertices with no vertex buffer: the vertex program reads the vertex's
//! index and picks a corner from the rectangle's record, 128 bytes the CPU
//! wrote (the corners in clip space, the varyings at the corners, the
//! color, the shape's numbers, the texture's handle). The record is bound
//! as constant buffer 0 of the vertex and the pixel stage, so a rectangle
//! costs nine dwords of pushbuffer: the buffer's address, its two bindings,
//! and the draw. A texture is a 32-byte header in a pool and one of two
//! samplers (nearest, linear: both unnormalized, clamped to the edge); the
//! pixel program is handed their indices in the record and samples through
//! them (Blackwell has no bound textures).
//!
//! The methods and their values are NVK's for this class (Mesa's Vulkan
//! driver, conformant on it; read as documentation), sent raw: NVK sends a
//! draw from a macro, and its two privileged-register writes (one masks the
//! "Out Of Range Address" shader exception) have no raw form. So each
//! vertex program stores exactly what its pixel program reads, which is
//! the case NVK says never raises that exception.
//!
//! One pass is one pushbuffer: begin(target), the rectangles in order, then
//! submit. The whole state is sent in every pass (a few hundred dwords):
//! the channel may have drawn something else in between.
//!
//! Colors are premultiplied, four floats (r, g, b, a) in [0, 1].
//!
//! Nothing here has run on the Legion's RTX yet.
//!
//! Allocation-free: four device buffers (the programs, the pools, the
//! records, the pushbuffer), sized at init.

const std = @import("std");
const push = @import("push.sig");
const sph = @import("sph.sig");
const sm120_asm = @import("sm120_asm.sig");
const device = @import("device.sig");

pub const Device = device.Device;
pub const Buffer = device.Buffer;
pub const Fence = device.Fence;

pub const Error = device.Error || sm120_asm.Error || error{
    /// The pass's rectangles did not fit the stream or the records.
    StreamFull,
    /// Its textures' headers did not fit the pool.
    StateFull,
    BadKernel,
    /// A rectangle before begin(), or begin() twice.
    NoPass,
};

// ── The types (gpu/draw.sig's, under this module's names) ───────────────────

pub const Format = enum(u8) {
    /// R, G, B, A.
    rgba8,
    /// B, G, R, A (a little-endian 0xAARRGGBB word).
    bgra8,
    /// One byte, read as (v, 0, 0, 1).
    r8,
};

/// What a pass draws to: `height` rows of `pitch` bytes at `va`. The
/// engine takes rows a multiple of 128 bytes apart, from an address that
/// is one too.
pub const Target = struct {
    va: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: Format = .bgra8,
};

pub const Filter = enum(u8) { nearest = 0, linear = 1 };

/// A texture a rectangle samples, with unnormalized coordinates (texels),
/// clamped to its edge; one level, rows of `pitch` bytes (a multiple of 32,
/// from an address that is one too).
pub const Texture = struct {
    va: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: Format = .bgra8,
    filter: Filter = .linear,
    /// Its alpha reads as one whatever its bytes hold.
    no_alpha: bool = false,
};

pub const Blend = enum(u8) {
    /// The color replaces the pixel.
    replace,
    /// Premultiplied source over: color + pixel * (1 - color's alpha).
    over,
};

/// What a rectangle's pixels are.
pub const Kind = enum(u8) { solid, image, mask, rrect, ring, image_rr };
const KINDS = 6;

/// A rectangle's corners: x0, y0, x1, y1 (pixels; x1 and y1 past the end).
pub const Rect = [4]f32;
/// Premultiplied r, g, b, a.
pub const Color = [4]f32;

/// A rounded rectangle as the coverage programs take it: its centre, its
/// half size less the radius, the radius.
pub const Shape = struct {
    cx: f32,
    cy: f32,
    kx: f32,
    ky: f32,
    rad: f32,
};

// ── The 3D engine's methods (clce97.h, by address) ──────────────────────────

/// The subchannel the 3D engine is bound to (NVK's; compute is on 1).
pub const SUBCH: u32 = 0;
pub const BLACKWELL_B: u32 = 0xce97;

pub const SET_API_MANDATED_EARLY_Z: u32 = 0x0210;
pub const SET_DRAW_CONTROL_A: u32 = 0x0260;
pub const DRAW_VERTEX_ARRAY_BEGIN_END_A: u32 = 0x0270;
pub const DRAW_VERTEX_ARRAY_BEGIN_END_B: u32 = 0x0274;
pub const SET_VARIABLE_PIXEL_RATE_SHADING_TABLE_SELECT: u32 = 0x02cc;
pub const SET_SUBTILING_PERF_KNOB_A: u32 = 0x0360;
pub const SET_RASTER_ENABLE: u32 = 0x037c;
pub const SET_RASTER_INPUT: u32 = 0x0740;
pub const SET_HYBRID_ANTI_ALIAS_CONTROL: u32 = 0x0754;
pub const SET_SHADER_LOCAL_MEMORY_WINDOW: u32 = 0x077c;
pub const SET_TEXTURE_HEADER_VERSION: u32 = 0x07ac;
pub const SET_COLOR_TARGET_A: u32 = 0x0800;
pub const SET_VIEWPORT_SCALE_X: u32 = 0x0a00;
pub const SET_VIEWPORT_COORDINATE_SWIZZLE: u32 = 0x0a18;
pub const SET_VIEWPORT_CLIP_HORIZONTAL: u32 = 0x0c00;
pub const SET_VIEWPORT_Z_CLIP: u32 = 0x0d7c;
pub const SET_SHADER_CACHE_CONTROL: u32 = 0x0d94;
pub const INVALIDATE_SHADER_CACHES_NO_WFI: u32 = 0x0da4;
pub const SET_FRONT_POLYGON_MODE: u32 = 0x0dac;
pub const SET_POLY_SMOOTH: u32 = 0x0db4;
pub const SET_POLY_OFFSET_POINT: u32 = 0x0dc0;
pub const SET_PATCH: u32 = 0x0dcc;
pub const SET_WINDOW_OFFSET_X: u32 = 0x0df8;
pub const SET_SCISSOR_ENABLE: u32 = 0x0e00;
pub const SET_POST_Z_PS_IMASK: u32 = 0x0f1c;
pub const SET_VERTEX_STREAM_SUBSTITUTE_A: u32 = 0x0f84;
pub const SET_SINGLE_CT_WRITE_CONTROL: u32 = 0x0f90;
pub const SET_CT_MRT_ENABLE: u32 = 0x0fac;
pub const SET_SAMPLE_MASK_X0_Y0: u32 = 0x0fbc;
pub const SET_SURFACE_CLIP_HORIZONTAL: u32 = 0x0ff4;
pub const SET_VERTEX_ID_BASE: u32 = 0x1118;
pub const SET_FILL_VIA_TRIANGLE: u32 = 0x113c;
pub const SET_CONSERVATIVE_RASTER: u32 = 0x1148;
pub const SET_MESH_CONTROL: u32 = 0x114c;
pub const SET_VERTEX_ATTRIBUTE_A: u32 = 0x1160;
pub const SET_ANTI_ALIAS_SAMPLE_POSITIONS: u32 = 0x11e0;
pub const SET_CT_SELECT: u32 = 0x121c;
pub const SET_SAMPLER_BINDING: u32 = 0x1234;
pub const INVALIDATE_TEXTURE_DATA_CACHE_NO_WFI: u32 = 0x1288;
pub const SET_SHADING_RATE_INDEX_SURFACE: u32 = 0x12a8;
pub const SET_DEPTH_TEST: u32 = 0x12cc;
pub const SET_SHADE_MODE: u32 = 0x12d4;
pub const SET_BLEND_STATE_PER_TARGET: u32 = 0x12e4;
pub const SET_DEPTH_WRITE: u32 = 0x12e8;
pub const SET_ALPHA_TEST: u32 = 0x12ec;
pub const SET_DEPTH_FUNC: u32 = 0x130c;
pub const SET_BLEND_CONST_RED: u32 = 0x131c;
pub const SET_BLEND_SEPARATE_FOR_ALPHA: u32 = 0x133c;
pub const SET_SINGLE_ROP_CONTROL: u32 = 0x135c;
pub const SET_BLEND: u32 = 0x1360;
pub const SET_STENCIL_TEST: u32 = 0x1380;
pub const SET_WINDOW_ORIGIN: u32 = 0x13ac;
pub const INVALIDATE_SAMPLER_CACHE_NO_WFI: u32 = 0x1424;
pub const SET_GLOBAL_BASE_VERTEX_INDEX: u32 = 0x1434;
pub const SET_USER_CLIP_ENABLE: u32 = 0x1510;
pub const SET_ANTI_ALIAS_ENABLE: u32 = 0x1534;
pub const SET_ZT_SELECT: u32 = 0x1538;
pub const SET_ANTI_ALIAS_ALPHA_CONTROL: u32 = 0x153c;
pub const SET_RENDER_ENABLE_C: u32 = 0x1558;
pub const SET_TEX_SAMPLER_POOL_A: u32 = 0x155c;
pub const SET_TEX_HEADER_POOL_A: u32 = 0x1574;
pub const SET_ACTIVE_ZCULL_REGION: u32 = 0x1590;
pub const SET_RT_LAYER: u32 = 0x15cc;
pub const SET_ANTI_ALIAS: u32 = 0x15d0;
pub const SET_EDGE_FLAG: u32 = 0x15e4;
pub const SET_ATTRIBUTE_DEFAULT: u32 = 0x1610;
pub const SET_DA_PRIMITIVE_RESTART: u32 = 0x1644;
pub const SET_DA_OUTPUT: u32 = 0x164c;
pub const SET_PROVOKING_VERTEX: u32 = 0x1684;
pub const CHECK_SPH_VERSION: u32 = 0x16a8;
pub const CHECK_AAM_VERSION: u32 = 0x1794;
pub const OGL_SET_CULL: u32 = 0x1918;
pub const OGL_SET_FRONT_FACE: u32 = 0x191c;
pub const SET_VIEWPORT_PIXEL: u32 = 0x1924;
pub const SET_VIEWPORT_SCALE_OFFSET: u32 = 0x192c;
pub const SET_VIEWPORT_CLIP_CONTROL: u32 = 0x193c;
pub const SET_USER_CLIP_OP: u32 = 0x1940;
pub const SET_PRIMITIVE_TOPOLOGY_CONTROL: u32 = 0x1948;
pub const SET_WINDOW_CLIP_ENABLE: u32 = 0x194c;
pub const SET_ZCULL_BOUNDS: u32 = 0x196c;
pub const SET_PRIMITIVE_TOPOLOGY: u32 = 0x1970;
pub const SET_CLIP_ID_TEST: u32 = 0x197c;
pub const SET_DEPTH_BOUNDS_TEST: u32 = 0x19bc;
pub const SET_LOGIC_OP: u32 = 0x19c4;
pub const SET_COLOR_COMPRESSION: u32 = 0x19e0;
pub const SET_CT_WRITE: u32 = 0x1a00;
pub const SET_VERTEX_STREAM_A_FORMAT: u32 = 0x1c00;
pub const SET_VERTEX_STREAM_B_FORMAT: u32 = 0x1d00;
pub const SET_BLEND_PER_TARGET_SEPARATE_FOR_ALPHA: u32 = 0x1e00;
pub const SET_PIPELINE_SHADER: u32 = 0x2000;
pub const SET_PIPELINE_REGISTER_COUNT: u32 = 0x200c;
pub const SET_PIPELINE_PROGRAM_ADDRESS_A: u32 = 0x2014;
pub const SET_CONSTANT_BUFFER_SELECTOR_A: u32 = 0x2380;
pub const BIND_GROUP_CONSTANT_BUFFER: u32 = 0x2410;
pub const SET_COLOR_CLAMP: u32 = 0x2600;

/// A pipeline stage's index (NVK's: the stage's type), and its binding
/// group for constant buffers.
pub const STAGE_VERTEX: u32 = 1;
pub const STAGE_PIXEL: u32 = 5;
pub const GROUP_VERTEX: u32 = 0;
pub const GROUP_PIXEL: u32 = 4;

/// SET_COLOR_TARGET_FORMAT's values.
pub fn targetFormat(f: Format) u32 {
    return switch (f) {
        .bgra8 => 0xcf, // A8R8G8B8
        .rgba8 => 0xd5, // A8B8G8R8
        .r8 => 0xf3,
    };
}

/// SET_COLOR_TARGET_MEMORY: rows of bytes (LAYOUT_PITCH), not blocks.
pub const TARGET_MEMORY_PITCH: u32 = 0x1000;
/// SET_PRIMITIVE_TOPOLOGY: a triangle strip.
pub const TOPOLOGY_TRIANGLE_STRIP: u32 = 5;
/// SET_DRAW_CONTROL_A: the first primitive and instance, the instances
/// iterated by the engine (NVK's word).
pub const DRAW_CONTROL: u32 = 0x200;
/// A vertex attribute with no stream behind it (NVK's: it reads zeros).
pub const ATTRIBUTE_INACTIVE: u32 = 0x3820_0040;
/// The blend's values (the OpenGL names' numbers, as NVK sends).
pub const BLEND_FUNC_ADD: u32 = 0x8006;
pub const BLEND_ONE: u32 = 0x4001;
pub const BLEND_ONE_MINUS_SRC_ALPHA: u32 = 0x4303;

// ── A rectangle's record ────────────────────────────────────────────────────

/// Bytes a record (a constant buffer's size and address are multiples of 64).
pub const RECORD = 128;
/// Where a record's parts are (bytes): the corners in clip space (x0, y0,
/// x1, y1), the varyings at them (s0, t0, s1, t1), the color, three
/// vectors a kind's program reads its own way, the texture's handle.
pub const AT_CORNERS = 0x00;
pub const AT_VARYINGS = 0x10;
pub const AT_COLOR = 0x20;
pub const AT_P1 = 0x30;
pub const AT_P2 = 0x40;
pub const AT_HANDLE = 0x60;

// ── The programs ────────────────────────────────────────────────────────────
// Constant buffer 0 is the rectangle's record. A pixel program's color
// leaves in R0..R3.

/// A solid rectangle's vertex program: the vertex's index picks the corner
/// (bit 0: the right-hand ones, bit 1: the lower ones); z is 0 and w is 1.
/// It stores the position and nothing else.
const VS_FLAT =
    \\ALD R0, a[0x2fc]
    \\LDC R4, c[0x0][0x0]
    \\LDC R5, c[0x0][0x4]
    \\LDC R8, c[0x0][0x8]
    \\LDC R9, c[0x0][0xc]
    \\LOP3.LUT R1, R0, 0x1, RZ, 0xc0, !PT
    \\LOP3.LUT R2, R0, 0x2, RZ, 0xc0, !PT
    \\ISETP.NE.AND P0, PT, R1, RZ, PT
    \\ISETP.NE.AND P1, PT, R2, RZ, PT
    \\SEL R4, R8, R4, P0
    \\SEL R5, R9, R5, P1
    \\MOV R6, 0x0
    \\MOV R7, 0x3f800000
    \\AST.128 a[0x70], R4
    \\EXIT
;

/// The same with the corner's varyings (two words: a texture coordinate,
/// or the pixel's position) stored as generic vector 0's x and y.
const VS_VARY =
    \\ALD R0, a[0x2fc]
    \\LDC R4, c[0x0][0x0]
    \\LDC R5, c[0x0][0x4]
    \\LDC R8, c[0x0][0x8]
    \\LDC R9, c[0x0][0xc]
    \\LDC R10, c[0x0][0x10]
    \\LDC R11, c[0x0][0x14]
    \\LDC R12, c[0x0][0x18]
    \\LDC R13, c[0x0][0x1c]
    \\LOP3.LUT R1, R0, 0x1, RZ, 0xc0, !PT
    \\LOP3.LUT R2, R0, 0x2, RZ, 0xc0, !PT
    \\ISETP.NE.AND P0, PT, R1, RZ, PT
    \\ISETP.NE.AND P1, PT, R2, RZ, PT
    \\SEL R4, R8, R4, P0
    \\SEL R5, R9, R5, P1
    \\SEL R10, R12, R10, P0
    \\SEL R11, R13, R11, P1
    \\MOV R6, 0x0
    \\MOV R7, 0x3f800000
    \\AST.128 a[0x70], R4
    \\AST.64 a[0x80], R10
    \\EXIT
;

/// A pixel program's start: the two varyings into R4 and R5, carried in
/// perspective as NAK has it (each over w, times the reciprocal of 1/w).
const VARYINGS =
    \\IPA.PASS R0, a[0x7c]
    \\IPA.PASS R4, a[0x80]
    \\IPA.PASS R5, a[0x84]
    \\MUFU.RCP R0, R0
    \\FMUL.RZ R4, R4, R0
    \\FMUL.RZ R5, R5, R0
    \\
;

/// The texel at (R4, R5) through the record's handle: red, green, blue,
/// alpha into R0..R3.
const SAMPLE =
    \\LDC R6, c[0x0][0x60]
    \\TEX.B.DXY R2, R0, R4, R6, 2D
    \\
;

/// The record's color into R8..R11.
const COLOR =
    \\LDC R8, c[0x0][0x20]
    \\LDC R9, c[0x0][0x24]
    \\LDC R10, c[0x0][0x28]
    \\LDC R11, c[0x0][0x2c]
    \\
;

/// A rounded rectangle's coverage at a pixel, as gfx.sdRoundRect: with q =
/// |p - centre| - k (k: the half size less the radius), the distance is
/// length(max(q, 0)) + min(max(q.x, q.y), 0) - radius, and the coverage a
/// half less that, between 0 and 1. The pixel's offset from the centre is
/// in registers `dx` and `dy` (kept), -k in `kx` and `ky`, -radius in
/// `rad`; the coverage lands in `out`, and `t1` and `t2` are used.
fn coverage(comptime dx: u8, comptime dy: u8, comptime kx: u8, comptime ky: u8, comptime rad: u8, comptime out: u8, comptime t1: u8, comptime t2: u8) []const u8 {
    return std.fmt.comptimePrint(
        \\FADD R{[t1]d}, |R{[dx]d}|, R{[kx]d}
        \\FADD R{[t2]d}, |R{[dy]d}|, R{[ky]d}
        \\FMNMX R{[out]d}, R{[t1]d}, R{[t2]d}, !PT
        \\FMNMX R{[out]d}, R{[out]d}, RZ, PT
        \\FMNMX R{[t1]d}, R{[t1]d}, RZ, !PT
        \\FMNMX R{[t2]d}, R{[t2]d}, RZ, !PT
        \\FMUL R{[t1]d}, R{[t1]d}, R{[t1]d}
        \\FFMA R{[t1]d}, R{[t2]d}, R{[t2]d}, R{[t1]d}
        \\MUFU.SQRT R{[t1]d}, R{[t1]d}
        \\FADD R{[out]d}, R{[out]d}, R{[t1]d}
        \\FADD R{[out]d}, R{[out]d}, R{[rad]d}
        \\FADD.SAT R{[out]d}, -R{[out]d}, 0.5
        \\
    , .{ .dx = dx, .dy = dy, .kx = kx, .ky = ky, .rad = rad, .out = out, .t1 = t1, .t2 = t2 });
}

/// The record's color.
const FS_SOLID =
    \\LDC R0, c[0x0][0x20]
    \\LDC R1, c[0x0][0x24]
    \\LDC R2, c[0x0][0x28]
    \\LDC R3, c[0x0][0x2c]
    \\EXIT
;

/// The texel times the color.
const FS_IMAGE = VARYINGS ++ SAMPLE ++ COLOR ++
    \\FMUL R0, R0, R8
    \\FMUL R1, R1, R9
    \\FMUL R2, R2, R10
    \\FMUL R3, R3, R11
    \\EXIT
;

/// The texel's first channel (coverage) times the color.
const FS_MASK = VARYINGS ++ SAMPLE ++ COLOR ++
    \\FMUL R1, R0, R9
    \\FMUL R2, R0, R10
    \\FMUL R3, R0, R11
    \\FMUL R0, R0, R8
    \\EXIT
;

/// A filled rounded rectangle. The varyings are the pixel's position.
/// P1: -centre x, y, then -k x, y; P2.x: -radius.
const FS_RRECT = VARYINGS ++
    \\LDC R12, c[0x0][0x30]
    \\LDC R13, c[0x0][0x34]
    \\LDC R14, c[0x0][0x38]
    \\LDC R15, c[0x0][0x3c]
    \\LDC R16, c[0x0][0x40]
    \\FADD R4, R4, R12
    \\FADD R5, R5, R13
    \\
++ coverage(4, 5, 14, 15, 16, 20, 21, 22) ++ COLOR ++
    \\FMUL R0, R8, R20
    \\FMUL R1, R9, R20
    \\FMUL R2, R10, R20
    \\FMUL R3, R11, R20
    \\EXIT
;

/// A stroked rounded rectangle: the outer shape's coverage less the
/// inner's (the same centre), not below 0.
/// P1: -centre x, y, then -k x, y (outer); P2: -radius outer, -radius
/// inner, then -k x, y (inner).
const FS_RING = VARYINGS ++
    \\LDC R12, c[0x0][0x30]
    \\LDC R13, c[0x0][0x34]
    \\LDC R14, c[0x0][0x38]
    \\LDC R15, c[0x0][0x3c]
    \\LDC R16, c[0x0][0x40]
    \\LDC R17, c[0x0][0x44]
    \\LDC R18, c[0x0][0x48]
    \\LDC R19, c[0x0][0x4c]
    \\FADD R4, R4, R12
    \\FADD R5, R5, R13
    \\
++ coverage(4, 5, 14, 15, 16, 20, 21, 22) ++ coverage(4, 5, 18, 19, 17, 23, 21, 22) ++
    \\FADD R20, R20, -R23
    \\FMNMX R20, R20, RZ, !PT
    \\
++ COLOR ++
    \\FMUL R0, R8, R20
    \\FMUL R1, R9, R20
    \\FMUL R2, R10, R20
    \\FMUL R3, R11, R20
    \\EXIT
;

/// The texel times the color times a rounded rectangle's coverage. The
/// varyings are the texture coordinates; the pixel's position less the
/// centre is theirs scaled and moved.
/// P1: the scale x, y, then the offset x, y; P2: -k x, y, then -radius.
const FS_IMAGE_RR = VARYINGS ++ SAMPLE ++
    \\LDC R12, c[0x0][0x30]
    \\LDC R13, c[0x0][0x34]
    \\LDC R14, c[0x0][0x38]
    \\LDC R15, c[0x0][0x3c]
    \\LDC R16, c[0x0][0x40]
    \\LDC R17, c[0x0][0x44]
    \\LDC R18, c[0x0][0x48]
    \\FFMA R4, R4, R12, R14
    \\FFMA R5, R5, R13, R15
    \\
++ coverage(4, 5, 16, 17, 18, 20, 21, 22) ++ COLOR ++
    \\FMUL R0, R0, R8
    \\FMUL R1, R1, R9
    \\FMUL R2, R2, R10
    \\FMUL R3, R3, R11
    \\FMUL R0, R0, R20
    \\FMUL R1, R1, R20
    \\FMUL R2, R2, R20
    \\FMUL R3, R3, R20
    \\EXIT
;

/// The programs: the two vertex programs, then a pixel program a kind.
const PROGRAMS = 2 + KINDS;
const SOURCES = [PROGRAMS][]const u8{ VS_FLAT, VS_VARY, FS_SOLID, FS_IMAGE, FS_MASK, FS_RRECT, FS_RING, FS_IMAGE_RR };

/// Whether a kind's programs carry varyings (all but a solid rectangle's).
fn varies(k: Kind) bool {
    return k != .solid;
}

/// A program's bytes in the code buffer: its header, then its code (a
/// multiple of the 128 bytes a header's address is aligned to).
const SLOT = 2048;
const CODE_BYTES = PROGRAMS * SLOT;
/// The registers a stage is given at least (NAK's floor).
const MIN_REGISTERS = 18;

/// The header in front of program `i`.
fn headerOf(i: usize) [sph.WORDS]u32 {
    if (i == 0) return sph.vertex(.{ .vertex_id = true });
    if (i == 1) {
        var v = sph.Vertex{ .vertex_id = true };
        v.out_generic[0] = 0x3;
        return sph.vertex(v);
    }
    var p = sph.Pixel{};
    if (varies(@enumFromInt(i - 2))) p.in_generic[0] = .{ .perspective, .perspective, .unused, .unused };
    return sph.pixel(p);
}

/// A program as the engine is told of it.
const Prog = struct {
    /// Its header's address.
    va: u64 = 0,
    registers: u32 = 0,
    /// Its header and code, in 256-byte blocks (the prefetch).
    blocks: u32 = 0,
};

// ── The pools ───────────────────────────────────────────────────────────────

/// The state buffer: a page of zeros (what a vertex stream that is off
/// reads), the two samplers, then the texture headers (the first one the
/// null texture, zeros).
const ZERO_AT = 0;
const SAMPLERS_AT = 4096;
const HEADERS_AT = 8192;
const ENTRY = 32;

/// A sampler's words: unnormalized coordinates, clamped to the edge, one
/// level (NVK's words for the same, with its two legacy bits).
pub fn samplerWords(f: Filter) [8]u32 {
    return .{ 0x0002_6092, if (f == .linear) 0x0200_02a2 else 0x0200_0291, 0, 0, 0, 0, 0, 0 };
}

/// Whether the texture unit reads `t` as it is meant: its address and its
/// rows multiples of 32 bytes, the rows under 4 MiB.
pub fn textureFits(t: Texture) bool {
    return t.va % 32 == 0 and t.pitch % 32 == 0 and t.pitch < (1 << 22) and t.width != 0 and t.height != 0 and t.width <= 0x20000 and t.height <= 0x20000;
}

/// Whether the engine draws to `t`: its address and its rows multiples of
/// 128 bytes (NVK: the hardware "gets grumpy" otherwise).
pub fn targetFits(t: Target) bool {
    return t.va % 128 == 0 and t.pitch % 128 == 0 and t.width != 0 and t.height != 0 and t.width <= 0xffff and t.height <= 0xffff and t.pitch >= t.width * @as(u32, if (t.format == .r8) 1 else 4);
}

/// A texture's header (TEXHEAD_V2_PITCH: rows of bytes, one level, two
/// dimensions, no mipmap), as NIL fills it.
pub fn headerWords(t: Texture) [8]u32 {
    // (the channels' sources, the data type, the components, the layout)
    var kind: u32 = switch (t.format) {
        .bgra8 => 0x2008_0a9c,
        .rgba8 => 0x2008_0b1a,
        .r8 => 0x201d_0e02,
    };
    // (alpha reads as one: its source ONE_FLOAT)
    if (t.no_alpha and t.format != .r8) kind |= 7 << 9;
    return .{
        @truncate(t.va & 0xffff_ffe0),
        @truncate((t.va >> 32) & 0x1ff_ffff),
        (t.pitch >> 5) | 0x000e_0000,
        kind,
        (t.width - 1) | 0x11c2_0000,
        t.height - 1,
        0x0300_0000,
        0,
    };
}

/// The word a texture instruction is handed: the header's index, and the
/// sampler's above it.
pub fn handleOf(header: u32, sampler: u32) u32 {
    return (header & 0xf_ffff) | (sampler << 20);
}

// ── The stream ──────────────────────────────────────────────────────────────

const Push = push.Push;

fn one(p: *Push, m: u32, v: u32) void {
    p.immediate(SUBCH, m, v);
}

fn many(p: *Push, m: u32, data: []const u32) void {
    p.method(SUBCH, m, data);
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}

/// The engine's state for these passes: what NVK sends when it starts a
/// queue and before its first draw, for one color target, no depth, one
/// sample, no vertex buffers. `zero_va` is a page of zeros, `samplers_va`
/// and `headers_va` the pools (`headers` entries).
pub fn setup(p: *Push, zero_va: u64, samplers_va: u64, headers_va: u64, headers: u32) void {
    p.setObject(SUBCH, BLACKWELL_B);
    one(p, SET_RENDER_ENABLE_C, 1);
    many(p, SET_CT_SELECT, &.{0x0fac_6881}); // one target, each slot its own
    one(p, SET_BLEND_SEPARATE_FOR_ALPHA, 1);
    one(p, SET_SINGLE_CT_WRITE_CONTROL, 1);
    one(p, SET_SINGLE_ROP_CONTROL, 0);
    one(p, SET_SHADE_MODE, 0x1d01);
    one(p, SET_SHADER_CACHE_CONTROL, 1);
    many(p, CHECK_SPH_VERSION, &.{0x0003_0003});
    many(p, CHECK_AAM_VERSION, &.{0x0002_0002});
    one(p, SET_ATTRIBUTE_DEFAULT, 0xe);
    one(p, SET_DA_OUTPUT, 0x1000); // the vertex's index counts from the draw's first
    one(p, SET_BLEND_STATE_PER_TARGET, 1);
    one(p, SET_ALPHA_TEST, 0);
    one(p, SET_COLOR_CLAMP, 1);
    one(p, SET_FILL_VIA_TRIANGLE, 0);
    one(p, SET_POLY_SMOOTH, 0);
    one(p, SET_VIEWPORT_PIXEL, 0); // centres at halves
    one(p, SET_ANTI_ALIAS_ENABLE, 1);
    one(p, SET_WINDOW_ORIGIN, 0); // the top left
    many(p, SET_WINDOW_OFFSET_X, &.{ 0, 0 });
    one(p, SET_WINDOW_CLIP_ENABLE, 0);
    one(p, SET_CLIP_ID_TEST, 0);
    one(p, SET_VIEWPORT_SCALE_OFFSET, 1);
    one(p, SET_VIEWPORT_CLIP_CONTROL, 0x181d);
    for (1..16) |i| one(p, SET_SCISSOR_ENABLE + 16 * @as(u32, @intCast(i)), 0);
    one(p, SET_CT_MRT_ENABLE, 1);
    many(p, SET_SHADER_LOCAL_MEMORY_WINDOW, &.{0xff00_0000});
    // No constant buffer bound to any stage.
    for (0..5) |g| for (0..16) |slot| one(p, BIND_GROUP_CONSTANT_BUFFER + 32 * @as(u32, @intCast(g)), @as(u32, @intCast(slot)) << 4);
    one(p, SET_RT_LAYER, 0);
    one(p, SET_EDGE_FLAG, 1);
    one(p, SET_SAMPLER_BINDING, 0); // a sampler's index its own
    one(p, SET_PRIMITIVE_TOPOLOGY_CONTROL, 1); // the topology its own state
    many(p, SET_VERTEX_STREAM_SUBSTITUTE_A, &.{ @truncate(zero_va >> 32), @truncate(zero_va) });
    // No vertex stream, every attribute off.
    for (0..16) |j| one(p, SET_VERTEX_STREAM_A_FORMAT + 16 * @as(u32, @intCast(j)), 0);
    for (0..16) |j| one(p, SET_VERTEX_STREAM_B_FORMAT + 16 * @as(u32, @intCast(j)), 0);
    many(p, SET_VERTEX_ATTRIBUTE_A, &(.{ATTRIBUTE_INACTIVE} ** 32));
    one(p, SET_TEXTURE_HEADER_VERSION, 1);
    many(p, SET_GLOBAL_BASE_VERTEX_INDEX, &.{ 0, 0 }); // and the base instance
    one(p, SET_VERTEX_ID_BASE, 0);
    // The pools, and what the engine caches of them and of the records.
    many(p, SET_TEX_HEADER_POOL_A, &.{ @truncate(headers_va >> 32), @truncate(headers_va), headers - 1 });
    many(p, SET_TEX_SAMPLER_POOL_A, &.{ @truncate(samplers_va >> 32), @truncate(samplers_va), 1 });
    many(p, INVALIDATE_SAMPLER_CACHE_NO_WFI, &.{ 0, 0 }); // and the headers'
    one(p, INVALIDATE_TEXTURE_DATA_CACHE_NO_WFI, 0);
    one(p, INVALIDATE_SHADER_CACHES_NO_WFI, 0x1000); // the constants
    // What NVK sends before a draw: the input assembly, the rasterizer,
    // one sample, no depth, no stencil.
    one(p, SET_PRIMITIVE_TOPOLOGY, TOPOLOGY_TRIANGLE_STRIP);
    one(p, SET_DA_PRIMITIVE_RESTART, 0);
    one(p, SET_PATCH, 1);
    one(p, SET_VIEWPORT_Z_CLIP, 1);
    one(p, SET_RASTER_ENABLE, 1);
    many(p, SET_FRONT_POLYGON_MODE, &.{ 0x1b02, 0x1b02 });
    one(p, OGL_SET_CULL, 0);
    one(p, OGL_SET_FRONT_FACE, 0x900);
    one(p, SET_PROVOKING_VERTEX, 0);
    many(p, SET_POLY_OFFSET_POINT, &.{ 0, 0, 0 });
    one(p, SET_RASTER_INPUT, 0);
    one(p, SET_CONSERVATIVE_RASTER, 0);
    one(p, SET_ANTI_ALIAS_ALPHA_CONTROL, 0);
    many(p, SET_ANTI_ALIAS_SAMPLE_POSITIONS, &(.{0x8888_8888} ** 4));
    many(p, SET_SAMPLE_MASK_X0_Y0, &(.{0xffff} ** 4));
    one(p, SET_DEPTH_TEST, 0);
    one(p, SET_DEPTH_WRITE, 0);
    one(p, SET_DEPTH_BOUNDS_TEST, 0);
    one(p, SET_STENCIL_TEST, 0);
    one(p, SET_DEPTH_FUNC, 0x207);
    one(p, SET_LOGIC_OP, 0);
    many(p, SET_BLEND_CONST_RED, &.{ 0, 0, 0, 0 });
    many(p, SET_CT_WRITE, &.{0x1111});
    // Premultiplied source over, for when the blend is on.
    many(p, SET_BLEND_PER_TARGET_SEPARATE_FOR_ALPHA, &.{ 1, BLEND_FUNC_ADD, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLEND_FUNC_ADD, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA });
    // The stages: no tessellation, no geometry; what NVK sends with a
    // vertex and a pixel program.
    for ([_]u32{ 2, 3, 4 }) |j| one(p, SET_PIPELINE_SHADER + 64 * j, j << 4);
    one(p, SET_MESH_CONTROL, 0);
    one(p, SET_VARIABLE_PIXEL_RATE_SHADING_TABLE_SELECT, 2);
    one(p, SET_USER_CLIP_ENABLE, 0);
    one(p, SET_USER_CLIP_OP, 0);
    many(p, SET_SUBTILING_PERF_KNOB_A, &.{ 0x2016_4010, 0x20 });
    one(p, SET_API_MANDATED_EARLY_Z, 0);
    one(p, SET_POST_Z_PS_IMASK, 0);
    one(p, SET_ZCULL_BOUNDS, 0);
    many(p, SET_DRAW_CONTROL_A, &.{ DRAW_CONTROL, 1 }); // and one instance
}

/// The pass's target, its viewport and its scissor (the whole of it).
pub fn target(p: *Push, t: Target) void {
    many(p, SET_SURFACE_CLIP_HORIZONTAL, &.{ t.width << 16, t.height << 16 });
    // (rows of bytes: the width is the pitch, one layer)
    many(p, SET_COLOR_TARGET_A, &.{ @truncate(t.va >> 32), @truncate(t.va), t.pitch, t.height, targetFormat(t.format), TARGET_MEMORY_PITCH, 1, 0, 0 });
    one(p, SET_COLOR_COMPRESSION, 0);
    for (1..8) |i| {
        const n: u32 = @intCast(i);
        many(p, SET_COLOR_TARGET_A + 64 * n, &.{ 0, 0, 64, 0, 0, 0, 1, 0, 0 });
        one(p, SET_COLOR_COMPRESSION + 4 * n, 1);
    }
    one(p, SET_ZT_SELECT, 0);
    one(p, SET_ACTIVE_ZCULL_REGION, 0x3f);
    many(p, SET_SHADING_RATE_INDEX_SURFACE, &(.{0} ** 8));
    one(p, SET_ANTI_ALIAS, 0);
    one(p, SET_HYBRID_ANTI_ALIAS_CONTROL, 1);
    const hw: f32 = @as(f32, @floatFromInt(t.width)) / 2;
    const hh: f32 = @as(f32, @floatFromInt(t.height)) / 2;
    // Clip x and y in [-1, 1] to the target's pixels, y downwards.
    many(p, SET_VIEWPORT_SCALE_X, &.{ bits(hw), bits(hh), bits(1), bits(hw), bits(hh), bits(0) });
    many(p, SET_VIEWPORT_COORDINATE_SWIZZLE, &.{0x6420});
    many(p, SET_VIEWPORT_CLIP_HORIZONTAL, &.{ t.width << 16, t.height << 16, bits(0), bits(1) });
    setScissor(p, 0, 0, t.width, t.height);
}

/// Draw only inside [x0, x1) x [y0, y1) from here on.
pub fn setScissor(p: *Push, x0: u32, y0: u32, x1: u32, y1: u32) void {
    many(p, SET_SCISSOR_ENABLE, &.{ 1, (x0 & 0xffff) | (x1 & 0xffff) << 16, (y0 & 0xffff) | (y1 & 0xffff) << 16 });
}

pub fn setBlend(p: *Push, b: Blend) void {
    one(p, SET_BLEND, @intFromBool(b == .over));
}

/// A stage's program: its type, its header's address and how much to
/// prefetch, its registers and the group its constant buffers bind to.
fn stage(p: *Push, j: u32, group: u32, g: Prog) void {
    one(p, SET_PIPELINE_SHADER + 64 * j, 1 | j << 4);
    many(p, SET_PIPELINE_PROGRAM_ADDRESS_A + 64 * j, &.{ @truncate(g.va >> 32), @truncate(g.va), g.blocks });
    many(p, SET_PIPELINE_REGISTER_COUNT + 64 * j, &.{ g.registers, group });
}

/// The record at `va` as both stages' constant buffer 0, and its
/// rectangle drawn: a strip of four vertices from vertex 0.
pub fn rect(p: *Push, va: u64) void {
    many(p, SET_CONSTANT_BUFFER_SELECTOR_A, &.{ RECORD, @truncate(va >> 32), @truncate(va) });
    one(p, BIND_GROUP_CONSTANT_BUFFER + 32 * GROUP_VERTEX, 1);
    one(p, BIND_GROUP_CONSTANT_BUFFER + 32 * GROUP_PIXEL, 1);
    many(p, DRAW_VERTEX_ARRAY_BEGIN_END_A, &.{ 0, 4 });
}

// ── The renderer ────────────────────────────────────────────────────────────

pub const Options = struct {
    /// The pushbuffer's bytes: a few hundred dwords a pass, nine a
    /// rectangle and a few more where the kind, the blend or the scissor
    /// changes.
    stream_bytes: usize = 256 * 1024,
    /// The rectangles a pass may hold (128 bytes each).
    rects: u32 = 4096,
    /// The textures a pass may sample.
    textures: u32 = 255,
};

pub const Stats = struct {
    rects: u32 = 0,
    /// Changes of program, and of texture.
    programs: u32 = 0,
    bindings: u32 = 0,
    stream_dwords: u32 = 0,
};

pub const Renderer = struct {
    dev: Device,
    code: Buffer,
    state: Buffer,
    records: Buffer,
    pb: Buffer,
    p: Push,
    progs: [PROGRAMS]Prog,
    in_pass: bool,
    t: Target,
    kind: ?Kind,
    blend: ?Blend,
    tex: ?Texture,
    handle: u32,
    /// Texture headers written this pass (the null one counted), and the
    /// pool's size.
    headers: u32,
    max_headers: u32,
    max_rects: u32,
    state_full: bool,
    records_full: bool,
    /// A target or a texture the engine would misread: the pass is refused.
    bad: bool,
    stats: Stats,

    /// Assemble the programs and take the buffers. `work` is the
    /// assembler's scratch.
    pub fn init(r: *Renderer, dev: Device, work: *sm120_asm.Work, opts: Options) Error!void {
        r.dev = dev;
        r.in_pass = false;
        r.stats = .{};
        r.max_headers = 1 + opts.textures;
        r.max_rects = opts.rects;
        r.code = try dev.alloc(CODE_BYTES);
        errdefer dev.free(r.code);
        r.state = try dev.alloc(HEADERS_AT + @as(usize, r.max_headers) * ENTRY);
        errdefer dev.free(r.state);
        r.records = try dev.alloc(@as(usize, opts.rects) * RECORD);
        errdefer dev.free(r.records);
        r.pb = try dev.alloc(opts.stream_bytes);
        errdefer dev.free(r.pb);
        @memset(r.code.cpu, 0);
        for (SOURCES, 0..) |src, i| {
            var words: [(SLOT - sph.BYTES) / 8]u64 = undefined;
            const k = try sm120_asm.assemble(src, &words, work);
            if (k.code.len > words.len) return error.BadKernel;
            const slot = r.code.cpu[i * SLOT ..][0..SLOT];
            const head = headerOf(i);
            for (head, 0..) |w, n| std.mem.writeInt(u32, slot[n * 4 ..][0..4], w, .little);
            for (k.code, 0..) |w, n| std.mem.writeInt(u64, slot[sph.CODE_AT + n * 8 ..][0..8], w, .little);
            const bytes = sph.BYTES + k.code.len * 8;
            r.progs[i] = .{
                .va = r.code.va + i * SLOT,
                .registers = @max(k.registers, MIN_REGISTERS),
                .blocks = @intCast(@min((bytes + 255) / 256, 127)),
            };
        }
        dev.toDevice(r.code, 0, CODE_BYTES);
        @memset(r.state.cpu[0..HEADERS_AT], 0);
        for ([_]Filter{ .nearest, .linear }, 0..) |f, i| {
            for (samplerWords(f), 0..) |w, n| std.mem.writeInt(u32, r.state.cpu[SAMPLERS_AT + i * ENTRY + n * 4 ..][0..4], w, .little);
        }
        dev.toDevice(r.state, 0, HEADERS_AT);
    }

    pub fn deinit(r: *Renderer) void {
        r.dev.free(r.pb);
        r.dev.free(r.records);
        r.dev.free(r.state);
        r.dev.free(r.code);
    }

    /// Start a pass on `t`: its pixels as they are, the scissor the whole
    /// target.
    pub fn begin(r: *Renderer, t: Target) void {
        r.p = .{ .buf = r.pb.words() };
        r.in_pass = true;
        r.t = t;
        r.kind = null;
        r.blend = null;
        r.tex = null;
        r.handle = 0;
        r.headers = 1;
        @memset(r.state.cpu[HEADERS_AT..][0..ENTRY], 0);
        r.state_full = false;
        r.records_full = false;
        r.bad = !targetFits(t);
        r.stats = .{};
        setup(&r.p, r.state.va + ZERO_AT, r.state.va + SAMPLERS_AT, r.state.va + HEADERS_AT, r.max_headers);
        target(&r.p, t);
    }

    /// Draw only inside [x0, x1) x [y0, y1) from here on.
    pub fn scissor(r: *Renderer, x0: u32, y0: u32, x1: u32, y1: u32) void {
        if (!r.in_pass) return;
        setScissor(&r.p, @min(x0, r.t.width), @min(y0, r.t.height), @min(x1, r.t.width), @min(y1, r.t.height));
    }

    fn use(r: *Renderer, kind: Kind, b: Blend) void {
        if (r.kind == null or r.kind.? != kind) {
            // (a vertex program that stores what this pixel program reads)
            stage(&r.p, STAGE_VERTEX, GROUP_VERTEX, r.progs[@intFromBool(varies(kind))]);
            stage(&r.p, STAGE_PIXEL, GROUP_PIXEL, r.progs[2 + @as(usize, @intFromEnum(kind))]);
            r.kind = kind;
            r.stats.programs += 1;
        }
        if (r.blend == null or r.blend.? != b) {
            setBlend(&r.p, b);
            r.blend = b;
        }
    }

    /// The handle `t` is sampled through: its header in the pool (written
    /// once a run of rectangles), and its filter's sampler.
    fn bind(r: *Renderer, t: Texture) u32 {
        if (r.tex) |cur| if (std.meta.eql(cur, t)) return r.handle;
        if (!textureFits(t)) {
            r.bad = true;
            return 0;
        }
        if (r.headers >= r.max_headers) {
            r.state_full = true;
            return 0;
        }
        const at = HEADERS_AT + @as(usize, r.headers) * ENTRY;
        for (headerWords(t), 0..) |w, n| std.mem.writeInt(u32, r.state.cpu[at + n * 4 ..][0..4], w, .little);
        r.handle = handleOf(r.headers, @intFromEnum(t.filter));
        r.headers += 1;
        r.tex = t;
        r.stats.bindings += 1;
        return r.handle;
    }

    /// A rectangle's record written and its draw sent: the corners, the
    /// varyings at them, the color, the kind's own numbers, the handle.
    fn emit(r: *Renderer, rc: Rect, vary: [4]f32, color: Color, params: []const f32, handle: u32) void {
        if (r.stats.rects >= r.max_rects) {
            r.records_full = true;
            return;
        }
        const at = @as(usize, r.stats.rects) * RECORD;
        const rec = r.records.cpu[at..][0..RECORD];
        @memset(rec, 0);
        const sx = 2 / @as(f32, @floatFromInt(r.t.width));
        const sy = 2 / @as(f32, @floatFromInt(r.t.height));
        const corners = [4]f32{ rc[0] * sx - 1, rc[1] * sy - 1, rc[2] * sx - 1, rc[3] * sy - 1 };
        for (corners, 0..) |v, n| std.mem.writeInt(u32, rec[AT_CORNERS + n * 4 ..][0..4], bits(v), .little);
        for (vary, 0..) |v, n| std.mem.writeInt(u32, rec[AT_VARYINGS + n * 4 ..][0..4], bits(v), .little);
        for (color, 0..) |v, n| std.mem.writeInt(u32, rec[AT_COLOR + n * 4 ..][0..4], bits(v), .little);
        for (params, 0..) |v, n| std.mem.writeInt(u32, rec[AT_P1 + n * 4 ..][0..4], bits(v), .little);
        std.mem.writeInt(u32, rec[AT_HANDLE..][0..4], handle, .little);
        rect(&r.p, r.records.va + at);
        r.stats.rects += 1;
    }

    fn drawn(r: *const Renderer, rc: Rect) bool {
        return r.in_pass and rc[2] > rc[0] and rc[3] > rc[1];
    }

    /// A rectangle of one color.
    pub fn fill(r: *Renderer, rc: Rect, color: Color, b: Blend) void {
        if (!r.drawn(rc)) return;
        r.use(.solid, b);
        r.emit(rc, .{ 0, 0, 0, 0 }, color, &.{}, 0);
    }

    /// `t`'s texels from (uv[0], uv[1]) to (uv[2], uv[3]) across the
    /// rectangle, each times `tint`.
    pub fn image(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, b: Blend) void {
        if (!r.drawn(rc)) return;
        r.use(.image, b);
        r.emit(rc, uv, tint, &.{}, r.bind(t));
    }

    /// `color` times the coverage in `t` (an r8 texture), as text is drawn.
    pub fn mask(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, color: Color, b: Blend) void {
        if (!r.drawn(rc)) return;
        r.use(.mask, b);
        r.emit(rc, uv, color, &.{}, r.bind(t));
    }

    /// `color` times the coverage of the rounded rectangle `s`, over the
    /// pixels of `rc` (s's bounds, or less).
    pub fn rrect(r: *Renderer, rc: Rect, s: Shape, color: Color, b: Blend) void {
        if (!r.drawn(rc)) return;
        r.use(.rrect, b);
        r.emit(rc, rc, color, &.{ -s.cx, -s.cy, -s.kx, -s.ky, -s.rad }, 0);
    }

    /// `color` times the coverage of `outer` less that of `inner` (the
    /// same centre; null: nothing taken out): a stroke.
    pub fn ring(r: *Renderer, rc: Rect, outer: Shape, inner: ?Shape, color: Color, b: Blend) void {
        if (!r.drawn(rc)) return;
        r.use(.ring, b);
        // (no inner shape: one no pixel is inside)
        const in = inner orelse Shape{ .cx = outer.cx, .cy = outer.cy, .kx = -1e9, .ky = -1e9, .rad = 0 };
        r.emit(rc, rc, color, &.{ -outer.cx, -outer.cy, -outer.kx, -outer.ky, -outer.rad, -in.rad, -in.kx, -in.ky }, 0);
    }

    /// image, times the coverage of the rounded rectangle `s` (in window
    /// pixels, as `rc`).
    pub fn imageRR(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, s: Shape, b: Blend) void {
        if (!r.drawn(rc)) return;
        if (!(uv[2] != uv[0] and uv[3] != uv[1])) return;
        r.use(.image_rr, b);
        // the pixel's position from the texture coordinates, less the centre
        const sx = (rc[2] - rc[0]) / (uv[2] - uv[0]);
        const sy = (rc[3] - rc[1]) / (uv[3] - uv[1]);
        r.emit(rc, uv, tint, &.{ sx, sy, rc[0] - uv[0] * sx - s.cx, rc[1] - uv[1] * sy - s.cy, -s.kx, -s.ky, -s.rad }, r.bind(t));
    }

    /// End the pass and hand it to the GPU. The target's pixels are in
    /// memory once the fence is done (fromDevice them before the CPU reads).
    pub fn submit(r: *Renderer) Error!Fence {
        if (!r.in_pass) return error.NoPass;
        r.in_pass = false;
        if (r.state_full) return error.StateFull;
        if (r.bad) return error.BadStream;
        if (r.records_full) return error.StreamFull;
        r.p.check() catch return error.StreamFull;
        r.stats.stream_dwords = @intCast(r.p.len);
        r.dev.toDevice(r.state, HEADERS_AT, @as(usize, r.headers) * ENTRY);
        if (r.stats.rects != 0) r.dev.toDevice(r.records, 0, @as(usize, r.stats.rects) * RECORD);
        r.dev.toDevice(r.pb, 0, r.p.len * 4);
        return r.dev.submit(r.pb, @intCast(r.p.len));
    }

    /// The pass submit() ended, handed over again (the device refused it:
    /// its ring was busy with another context's work).
    pub fn resubmit(r: *Renderer) Error!Fence {
        if (r.in_pass or r.stats.stream_dwords == 0) return error.NoPass;
        return r.dev.submit(r.pb, r.stats.stream_dwords);
    }

    /// submit, and wait for it.
    pub fn run(r: *Renderer, timeout_us: u64) Error!void {
        const f = try r.submit();
        try r.dev.wait(f, timeout_us);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const sched = @import("sm120_sched.sig");

var test_work: sm120_asm.Work = .{};

test "every program assembles, is scheduled without a hazard left open, and fits its slot" {
    for (SOURCES, 0..) |src, i| {
        var words: [(SLOT - sph.BYTES) / 8]u64 = undefined;
        const k = try sm120_asm.assemble(src, &words, &test_work);
        try testing.expect(k.scheduled);
        try testing.expect(k.code.len <= words.len);
        try testing.expectEqual(@as(u32, 0), (try sched.check(test_work.instrs[0..k.count], test_work.slots[0..k.count], &test_work.sched)).open);
        // a vertex header in front of the vertex programs, a pixel one after
        const head = headerOf(i);
        try testing.expectEqual(if (i < 2) sph.Stage.vertex else sph.Stage.pixel, sph.stageOf(&head).?);
    }
    // The vertex programs store what their pixel programs read: the
    // position alone, or with generic vector 0's x and y.
    try testing.expect(!sph.bit(&headerOf(0), 432));
    try testing.expect(sph.bit(&headerOf(1), 432) and sph.bit(&headerOf(1), 433) and !sph.bit(&headerOf(1), 434));
    try testing.expectEqual(sph.Interp.unused, sph.interpOf(&headerOf(2), 0, 0));
    for (3..PROGRAMS) |i| {
        try testing.expectEqual(sph.Interp.perspective, sph.interpOf(&headerOf(i), 0, 1));
        try testing.expectEqual(sph.Interp.unused, sph.interpOf(&headerOf(i), 0, 2));
    }
}

test "a texture's header and the samplers: NVK's words" {
    const t = Texture{ .va = 0x12_3456_7000, .width = 640, .height = 480, .pitch = 2560, .format = .bgra8 };
    try testing.expectEqual([8]u32{ 0x3456_7000, 0x12, 0x000e_0050, 0x2008_0a9c, 0x11c2_027f, 479, 0x0300_0000, 0 }, headerWords(t));
    var o = t;
    o.no_alpha = true;
    try testing.expectEqual(@as(u32, 0x2008_0e9c), headerWords(o)[3]);
    o.format = .rgba8;
    try testing.expectEqual(@as(u32, 0x2008_0f1a), headerWords(o)[3]);
    o.format = .r8;
    try testing.expectEqual(@as(u32, 0x201d_0e02), headerWords(o)[3]);
    try testing.expectEqual(@as(u32, 0x0200_0291), samplerWords(.nearest)[1]);
    try testing.expectEqual(@as(u32, 0x0200_02a2), samplerWords(.linear)[1]);
    try testing.expectEqual(@as(u32, 0x0010_0003), handleOf(3, 1));
    // rows the texture unit or the engine would misread
    o.pitch = 2576;
    try testing.expect(!textureFits(o));
    try testing.expect(textureFits(t));
    try testing.expect(targetFits(.{ .va = 0x1000, .width = 64, .height = 32, .pitch = 256 }));
    try testing.expect(!targetFits(.{ .va = 0x1000, .width = 60, .height = 32, .pitch = 240 }));
    try testing.expect(!targetFits(.{ .va = 0x1040, .width = 64, .height = 32, .pitch = 256 }));
}

test "the stream: a target, a rectangle's nine dwords" {
    var buf: [512]u32 = undefined;
    var p = Push{ .buf = &buf };
    rect(&p, 0x10_0004_0080);
    try p.check();
    try testing.expectEqualSlices(u32, &.{
        0x2003_08e0, RECORD, 0x10, 0x0004_0080, // the selector: size, address
        0x8001_0904, // bound to the vertex stage's slot 0
        0x8001_0924, // and the pixel stage's
        0x2002_009c, 0, 4, // four vertices from vertex 0
    }, p.words());
    p = .{ .buf = &buf };
    target(&p, .{ .va = 0x10_0010_0000, .width = 64, .height = 32, .pitch = 256 });
    try p.check();
    const w = p.words();
    try testing.expectEqualSlices(u32, &.{ 0x2002_03fd, 64 << 16, 32 << 16 }, w[0..3]);
    try testing.expectEqualSlices(u32, &.{ 0x2009_0200, 0x10, 0x0010_0000, 256, 32, 0xcf, 0x1000, 1, 0, 0 }, w[3..13]);
    // the viewport: half the size as the scale and as the offset
    var i: usize = 0;
    while (w[i] != push.header(SUBCH, SET_VIEWPORT_SCALE_X, 6)) i += 1;
    try testing.expectEqualSlices(u32, &.{ bits(32), bits(16), bits(1), bits(32), bits(16), bits(0) }, w[i + 1 ..][0..6]);
    // and the scissor, the whole target, last
    try testing.expectEqualSlices(u32, &.{ 0x2003_0380, 1, 64 << 16, 32 << 16 }, w[w.len - 4 ..]);
}
