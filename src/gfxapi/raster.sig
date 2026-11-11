//! @zpm/gfxapi raster — GL's draws as three KIR kernels per pipeline and
//! one for every pipeline, the same on every GPU (ir3, sm_120) and on the
//! CPU (KIR's interpreter):
//!
//! 1. **vertex** (a thread per vertex of each instance): the attributes
//!    fetched (any of GL's formats, a constant where an array is off, an
//!    instance's where the divisor says), the shader's vertex code, then
//!    clip to window space: the position snapped to 1/16 pixel (GL's 4
//!    subpixel bits), depth through the depth range, 1/w, the varyings
//!    multiplied by 1/w (perspective) or kept (flat).
//! 2. **setup** (a thread per triangle): the topology's vertices (lists,
//!    strips, fans; the last vertex provokes), the signed area exact in
//!    64 bits, culling, the triangle turned counter-clockwise, its pixel
//!    box, three edge equations in integers with a tie rule (a pixel on
//!    an edge two triangles share is drawn by exactly one), and plane
//!    equations for depth, 1/w and each varying.
//! 3. **bin** (a group per BIN x BIN pixels, a thread per triangle at a
//!    time): the triangles whose boxes meet the bin, listed in order; a
//!    draw whose rectangle is one bin has none.
//! 4. **raster** (a group per TILE x TILE pixels, a thread per pixel): the
//!    tile's pixels and depth loaded once, then its bin's triangles in
//!    order (GL's order: blending is right), 64 at a time: each thread
//!    tests one's box against the tile and the hits are compacted in
//!    shared memory; a tile outside one of a triangle's edges is skipped;
//!    coverage exact (each edge's constant for the tile
//!    in 64 bits, then 32-bit per pixel); depth interpolated, clipped to
//!    the depth range, tested; the varyings interpolated and divided by
//!    the interpolated 1/w; the shader's fragment code; blending (every
//!    GL factor and equation); the pixels and depth stored once.
//!
//! Exact by construction: coverage is integer arithmetic, and every float
//! operation is one KIR defines bit for bit (no fused or fast
//! multiply-add), so a frame is the same bytes on the Adreno, the RTX and
//! the CPU.
//!
//! Color targets: RGBA8, BGRA8, RG8 and R8 (WebRender's masks), up to
//! MAX_TARGETS of them in one draw (output i into target i, each with its
//! format, colour mask and blending on or off).
//!
//! Primitives: triangles (lists, strips, fans), points (a square sprite
//! gl_PointSize a side: two triangles, gl_PointCoord's planes across it),
//! lines (lists, strips, loops; one pixel wide; single-sampled by GL's and
//! Vulkan's diamond-exit rule, exact in integers; multisampled as a
//! rectangle: two triangles).
//!
//! Multisampling (2x, 4x, 8x: `Variant.samples`, the images' `samples`):
//! each sample's coverage from the edges at Vulkan's standard sample
//! positions, its own depth on the depth plane, its own depth and stencil
//! tests and blending; the fragment code once a pixel; alpha to coverage
//! and the sample mask. The samples' words live in shared memory.
//! engine.resolve averages them into a single-sampled image.
//!
//! Depth bias (triangles), gl_FragDepth (the tests after the fragment
//! code), clip distances (interpolated, a sample with one below 0 at the
//! pixel's center is out).
//!
//! GL ES 3.0's too: transform feedback (a fifth kernel, **capture**: the
//! vertex code again, its outputs as the shader made them into buffers),
//! occlusion queries (a pixel the raster writes says a sample passed),
//! primitive restart at the fixed index (the index's vertex is out: the
//! primitives with it are dropped; a strip or fan starts anew after it).
//!
//! Each pipeline's tile kernel is built per `Variant` (stencil, samples,
//! targets, lines) and its setup kernel per `SetupKind`, at the first draw
//! that needs it (raster.Pipeline.more).
//!
//! Not yet: clipping (a triangle with a vertex at w <= 0, or beyond GUARD
//! pixels, is dropped: a guard band); lines wider than a pixel; sample
//! shading; float and integer targets; per-target blend factors.
//! Shaders are KIR emitters (`Shaders`): GLSL programs' (glsl/gen.sig),
//! Vulkan's SPIR-V (src/vk through src/spirv), or Sig code. Besides the
//! uniform words and the textures, a pipeline may bind buffers
//! (`Shaders.buffers`: Vulkan's uniform and storage buffers).
//!
//! Allocation-free: kernels are built into the caller's storage.

const std = @import("std");
const gpu = @import("gpu");
const engine = @import("engine.sig");
const texture = @import("texture.sig");
const kir = gpu.kir;
const V = kir.V;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const i = kir.i;
const no = kir.no;

/// Pixels a side of a tile: a group of TILE * TILE threads.
pub const TILE = 8;
/// Subpixel steps a pixel (4 bits, GL's SUBPIXEL_BITS).
pub const SUB = 16;
/// How far from the origin (pixels) a vertex may lie; past it, its
/// triangle is dropped (a guard band in place of clipping).
pub const GUARD: f32 = 24576;
/// GL ES 3.0's MAX_VERTEX_ATTRIBS at least.
pub const MAX_ATTRS = 16;
/// Scalar varyings (a vec4 is four): GL ES 3.0's 15 vectors, and room.
pub const MAX_VARYINGS = 64;
pub const MAX_UNIFORM_WORDS = 1024;
/// Buffers a pipeline's shaders may read and write besides the uniform
/// words (Vulkan's uniform and storage buffers): bound after the textures.
pub const MAX_BUFFERS = 32;
/// A tile's edge constants are clamped to +-LIMIT: the 32-bit per-pixel
/// part then never overflows (fixed coordinates < 2^19, steps < 2^7).
const LIMIT: u32 = 1 << 29;

pub const VERTEX_GROUP = 64;
pub const SETUP_GROUP = 64;
/// Tiles a side of a bin: the bin kernel lists, for each BIN x BIN pixels,
/// the triangles whose boxes meet them (in order), and a tile goes
/// through its bin's list alone.
pub const BIN_TILES = 8;
const BIN_SHIFT = 3;
pub const BIN = TILE * BIN_TILES;
/// Triangles a bin's list holds at most (Engine.bin_cap may lower it);
/// past it, the bin's tiles go through every triangle.
pub const BIN_CAP = 2048;
/// Triangles a group culls at once: a tile's threads, and the bin
/// kernel's group, one triangle each.
const CULL = TILE * TILE;

comptime {
    std.debug.assert(BIN_TILES == 1 << BIN_SHIFT and CULL == 64);
}

// ── What a pipeline's shaders are ──────────────────────────────────────────

pub const VertexIO = struct {
    /// the attributes: four registers each (f32 bits; an integer
    /// attribute's raw bits)
    attr: [MAX_ATTRS][4]V = undefined,
    vertex_id: V = .none,
    instance_id: V = .none,
    /// the binding uniforms are loaded from (uniform(k, io.uniforms, word))
    uniforms: u8 = 0,
    /// the first texture's binding (the pipeline's textures follow)
    textures: u8 = 0,
    /// the first buffer's binding (Shaders.buffers of them follow)
    buffers: u8 = 0,
    /// outputs: the clip-space position, the varyings (f32)
    position: [4]V = .{ .none, .none, .none, .none },
    varying: [MAX_VARYINGS]V = [_]V{.none} ** MAX_VARYINGS,
    /// gl_PointSize (Shaders.point_size; unset: 1)
    point_size: V = .none,
    /// gl_ClipDistance[i] (Shaders.clips of them; unset: 0, kept)
    clip: [MAX_CLIP]V = [_]V{.none} ** MAX_CLIP,
};

/// A lane's quad neighbours (KIR's lanes are a group's threads in order,
/// x fastest: a tile's pixel (x, y) is lane y * TILE + x): xor these.
pub const QUAD_X = 1;
pub const QUAD_Y = TILE;

pub const FragmentIO = struct {
    /// whole 2 x 2 quads run the code (pixels not drawn among them as
    /// helpers): a derivative is a difference with the quad's neighbour,
    /// through a shuffle (lane xor QUAD_X, QUAD_Y)
    quads: bool = false,
    /// (quads) preds: the pixel is its quad's right one, its top one
    odd_x: V = .none,
    odd_y: V = .none,
    varying: [MAX_VARYINGS]V = undefined,
    /// gl_FragCoord: x + 0.5, y + 0.5, depth, 1/w
    frag_coord: [4]V = undefined,
    /// gl_FrontFacing (a pred)
    front_facing: V = .none,
    uniforms: u8 = 0,
    textures: u8 = 0,
    buffers: u8 = 0,
    /// gl_PointCoord (Shaders.point_coord: points' 0..1 across the
    /// sprite, s right and t down; 0 for other primitives)
    point_coord: [2]V = .{ .none, .none },
    /// outputs: the color (f32, 0..1 for unorm targets), and a pred that
    /// drops the fragment (discard), if the shader sets one
    color: [4]V = .{ .none, .none, .none, .none },
    /// the outputs at locations 1 .. MAX_TARGETS - 1 (index 0 unused: it
    /// is `color`), drawn into Draw.targets; an output a bound target has
    /// and the code never writes is 0, 0, 0, 0
    colors: [MAX_TARGETS][4]V = [_][4]V{.{ .none, .none, .none, .none }} ** MAX_TARGETS,
    /// gl_FragDepth (Shaders.frag_depth): the depth tested and written in
    /// place of the interpolated one, clamped to 0..1
    depth: V = .none,
    discard: V = .none,
    /// the code takes derivatives (set by the fragment emitter)
    derivatives: bool = false,
};

/// The shaders: KIR emitters (what GLSL compiles to, or Sig code).
pub const Shaders = struct {
    ctx: ?*const anyopaque = null,
    attrs: u8 = 0,
    varyings: u8 = 0,
    /// bit i: varying i is flat (the provoking vertex's, its bits kept:
    /// an integer's too), else smooth
    flat: u64 = 0,
    /// textures both stages may read (texture.sig), bound after each
    /// kernel's own buffers
    textures: u8 = 0,
    /// buffers both stages may read and write (Draw.buffers), bound after
    /// the textures
    buffers: u8 = 0,
    /// the fragment code takes derivatives: the raster runs it for whole
    /// quads (FragmentIO.quads)
    quads: bool = false,
    /// transform feedback: the components a vertex writes (the capture
    /// kernel), and each buffer's words a vertex
    capture: []const Capture = &.{},
    capture_stride: [MAX_CAPTURE_BUFFERS]u32 = @splat(0),
    /// the vertex code writes gl_PointSize (VertexIO.point_size): a word
    /// more in a vertex's record
    point_size: bool = false,
    /// the fragment code reads gl_PointCoord (FragmentIO.point_coord):
    /// two planes more in a primitive's record
    point_coord: bool = false,
    /// the fragment code writes gl_FragDepth (FragmentIO.depth): the
    /// depth and stencil tests come after it (no early rejection)
    frag_depth: bool = false,
    /// clip distances the vertex code writes (VertexIO.clip): each
    /// interpolated as a varying is, and a sample where one is below 0 is
    /// not drawn (the half-space clipped away, per pixel)
    clips: u8 = 0,
    vertex: *const fn (?*const anyopaque, *kir.Kernel, *VertexIO) void,
    fragment: *const fn (?*const anyopaque, *kir.Kernel, *FragmentIO) void,
};

/// Colour targets a draw writes at once (Vulkan's colour attachments, GL's
/// draw buffers): fragment output i into target i.
pub const MAX_TARGETS = 8;
/// Samples a pixel may have (multisampling): 1, 2, 4 or 8.
pub const MAX_SAMPLES = 8;
/// Clip distances (gl_ClipDistance, Vulkan's ClipDistance).
pub const MAX_CLIP = 8;
/// The largest point side (pixels): ALIASED_POINT_SIZE_RANGE's top.
pub const MAX_POINT_SIZE: f32 = 1024;

/// Where a pixel's samples are, in 1/16 pixel from its lower left corner
/// (the raster's y up): Vulkan's standard locations (D3D's), which count
/// y down from the top, flipped. Index: log2(samples).
pub const sample_pos = [4][]const [2]u8{
    &.{.{ 8, 8 }},
    &.{ .{ 12, 4 }, .{ 4, 12 } },
    &.{ .{ 6, 14 }, .{ 14, 10 }, .{ 2, 6 }, .{ 10, 2 } },
    &.{ .{ 9, 11 }, .{ 7, 5 }, .{ 13, 7 }, .{ 5, 13 }, .{ 3, 3 }, .{ 1, 9 }, .{ 11, 1 }, .{ 15, 15 } },
};

pub fn samplePositions(samples: u32) []const [2]u8 {
    return sample_pos[std.math.log2_int(u32, @max(samples, 1))];
}

/// What a pipeline's tile kernel is built for (one program each, made at
/// the first draw that needs it): the stencil test, samples a pixel, the
/// colour targets, lines.
pub const Variant = struct {
    stencil: bool = false,
    /// samples a pixel, every target's and the depth's (1, 2, 4, 8)
    samples: u8 = 1,
    /// the colour targets drawn: bit i, output i into Draw's target i (0:
    /// depth and stencil only)
    targets: u8 = 1,
    /// the records are lines, covered by GL's and Vulkan's diamond-exit
    /// rule (single-sampled lines); else triangles (multisampled lines and
    /// every point are rectangles: two triangles each)
    lines: bool = false,

    pub fn key(v: Variant) u32 {
        return @as(u32, @intFromBool(v.stencil)) | @as(u32, std.math.log2_int(u32, v.samples)) << 1 | @as(u32, v.targets) << 3 | @as(u32, @intFromBool(v.lines)) << 11;
    }

    fn name(v: Variant) []const u8 {
        if (v.lines) return if (v.stencil) "gl_raster_lines_stencil" else "gl_raster_lines";
        if (v.samples > 1) return if (v.stencil) "gl_raster_ms_stencil" else "gl_raster_ms";
        if (v.targets != 1) return if (v.stencil) "gl_raster_mrt_stencil" else "gl_raster_mrt";
        return if (v.stencil) "gl_raster_stencil" else "gl_raster";
    }
};

/// What a draw's primitives make for the tiles: triangles (as given), a
/// record a line (diamond exit), or two triangles a line (a rectangle one
/// pixel wide: multisampled) or a point (a square sprite).
pub const SetupKind = enum(u2) { triangles, lines, line_quads, points };

/// Transform feedback's buffers (GL ES 3.0's MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS).
pub const MAX_CAPTURE_BUFFERS = 4;

/// A component a vertex writes to a transform feedback buffer: the
/// position's (src: its component) or a varying word's, into word `word`
/// of `buffer`'s record.
pub const Capture = struct {
    position: bool = false,
    src: u8 = 0,
    buffer: u8 = 0,
    word: u16 = 0,
};

/// A uniform word (f32 bits, or an int's) of the binding `b`.
pub fn uniform(k: *kir.Kernel, ty: kir.Ty, b: u8, word: u32) V {
    return k.load(ty, memAt(b, word * 4), u(0));
}

fn memAt(b: u8, imm: u32) kir.Mem {
    var m = kir.global(b, 32);
    m.imm = @intCast(imm);
    return m;
}

/// A pipeline: its shaders, its records' sizes, its kernels on a device.
pub const Pipeline = struct {
    shaders: Shaders,
    /// words a vertex's record takes, and a triangle's
    vstride: u32,
    sstride: u32,
    /// Vertex, setup, raster, the optional stencil raster variant, and
    /// transform feedback's capture.
    progs: [5]?gpu.Program = @splat(null),
    stencil_refused_by: ?*anyopaque = null,
    capture_refused_by: ?*anyopaque = null,
    /// the engine that loaded them
    owner: ?*anyopaque = null,
    /// the engine whose GPU refused them (their draws run on the CPU, not
    /// compiled again at every draw)
    refused_by: ?*anyopaque = null,
    /// draws of it checked against the CPU (the engine's Check)
    checked: u8 = 0,
    /// The other kernels its draws needed (on the owner's GPU): setup
    /// kernels of other primitives, tile kernels of other variants, by
    /// their keys (kindKey); and the keys the GPU refused.
    more_key: [MAX_MORE]u32 = @splat(0),
    more: [MAX_MORE]?gpu.Program = @splat(null),
    n_more: u8 = 0,
    refused_key: [MAX_MORE]u32 = @splat(0),
    n_refused: u8 = 0,
    /// the slot of `more` the next program goes to once all are taken (in
    /// turn: a draw's setup and tile kernels never take each other's)
    evict: u8 = 0,

    pub const MAX_MORE = 12;

    pub fn init(sh: Shaders) Pipeline {
        std.debug.assert(sh.attrs <= MAX_ATTRS and sh.varyings <= MAX_VARYINGS and sh.textures <= texture.MAX_TEX and sh.buffers <= MAX_BUFFERS and sh.clips <= MAX_CLIP);
        const planes = @as(u32, sh.varyings) + sh.clips;
        return .{
            .shaders = sh,
            .vstride = VREC + planes + @intFromBool(sh.point_size),
            .sstride = SREC + 3 * planes + if (sh.point_coord) @as(u32, 6) else 0,
        };
    }

    /// The vertex record's word of clip distance i, and of the point size.
    fn vClip(p: *const Pipeline, j: usize) u32 {
        return VREC + p.shaders.varyings + @as(u32, @intCast(j));
    }
    fn vSize(p: *const Pipeline) u32 {
        return VREC + p.shaders.varyings + p.shaders.clips;
    }
    /// The primitive record's plane of clip distance i, and of gl_PointCoord.
    fn sClip(p: *const Pipeline, j: usize) u32 {
        return SREC + 3 * (p.shaders.varyings + @as(u32, @intCast(j)));
    }
    fn sCoord(p: *const Pipeline) u32 {
        return SREC + 3 * (@as(u32, p.shaders.varyings) + p.shaders.clips);
    }
};

/// A program's key among a pipeline's `more`: a setup kernel's (kind) or
/// a tile kernel's (its variant's key).
pub fn setupKey(kind: SetupKind) u32 {
    return 1 << 20 | @as(u32, @intFromEnum(kind));
}
pub fn tileKey(v: Variant) u32 {
    return 2 << 20 | v.key();
}

// a vertex's record: x, y (1/16 pixel, i32), depth (window), 1/w (< 0:
// the vertex is out), then the varyings, the clip distances (as the
// varyings: times 1/w) and the point size
const VREC = 4;
// a triangle's record: valid, box (4), three edges (A, B, ax, ay, bias),
// front facing, X0, Y0 (pixels), the planes (a0, d/dx, d/dy) of depth and
// 1/w, then each varying's
const S_VALID = 0;
const S_BOX = 1;
const S_EDGE = 5;
const S_FRONT = 20;
const S_XY = 21;
const S_Z = 23;
const S_W = 26;
const SREC = 29;

// ── What a draw is ─────────────────────────────────────────────────────────

pub const Topology = enum(u8) { triangles, strip, fan, points, lines, line_strip, line_loop };

/// A colour target past Draw.color: its image (as many samples as the
/// draw's), its bits kept (the colour mask's channels off), and whether
/// it blends (Draw.blend's factors and equations: one set for every
/// target, as GL ES 3.0 and Vulkan without independentBlend have it).
pub const Target = struct {
    img: *engine.Image,
    keep: u32 = 0,
    blend: bool = true,
};

pub const Attr = struct {
    /// a GL buffer's storage; null: the constant
    buf: ?*engine.Image = null,
    offset: u32 = 0,
    stride: u32 = 0,
    /// components 1..4 (0: the constant)
    comps: u8 = 0,
    /// bytes a component: 1, 2, 4
    size: u8 = 4,
    float: bool = true,
    signed: bool = false,
    normalized: bool = false,
    /// glVertexAttribIPointer's: the bits, unconverted
    integer: bool = false,
    /// 0: per vertex; 1: per instance
    divisor: u32 = 0,
    /// the value where comps is 0 (glVertexAttrib*'s)
    constant: [4]u32 = .{ 0, 0, 0, 0x3f80_0000 },
};

/// Blend factors as f = c + ks * s + kd * d + ksa * s.a + kda * d.a (each
/// of GL's is one; ONE_MINUS_X is 1 - X), per color channel for RGB and
/// for alpha; SRC_ALPHA_SATURATE (RGB only) apart.
pub const Factor = struct {
    c: [4]f32 = .{ 0, 0, 0, 0 },
    ks: f32 = 0,
    kd: f32 = 0,
    ksa: f32 = 0,
    kda: f32 = 0,
};

pub const Equation = enum(u8) { add, subtract, reverse_subtract, min, max };

pub const Blend = struct {
    src_rgb: Factor = .{ .c = .{ 1, 1, 1, 1 } },
    dst_rgb: Factor = .{},
    src_a: Factor = .{ .c = .{ 1, 1, 1, 1 } },
    dst_a: Factor = .{},
    /// src_rgb is SRC_ALPHA_SATURATE: min(s.a, 1 - d.a)
    saturate: bool = false,
    eq_rgb: Equation = .add,
    eq_a: Equation = .add,
};

pub const StencilOp = enum(u3) { keep, zero, replace, incr, decr, invert, incr_wrap, decr_wrap };
pub const Stencil = struct {
    func: u3 = 7,
    reference: u8 = 0,
    value_mask: u8 = 0xff,
    write_mask: u8 = 0xff,
    fail: StencilOp = .keep,
    depth_fail: StencilOp = .keep,
    pass: StencilOp = .keep,
};

pub const Draw = struct {
    pipe: *const Pipeline,
    color: *engine.Image,
    depth: ?*engine.Image = null,
    stencil: ?*engine.Image = null,
    stencil_front: Stencil = .{},
    stencil_back: Stencil = .{},
    attrs: [MAX_ATTRS]Attr = [_]Attr{.{}} ** MAX_ATTRS,
    /// the pipeline's textures' images (null: none bound: reads 0, 0, 0, 1)
    textures: [texture.MAX_TEX]?*engine.Image = [_]?*engine.Image{null} ** texture.MAX_TEX,
    /// the pipeline's buffers (Shaders.buffers; null: zeros)
    buffers: [MAX_BUFFERS]?*engine.Image = [_]?*engine.Image{null} ** MAX_BUFFERS,
    /// the element array: its buffer, byte offset, index size (1, 2, 4)
    index: ?*engine.Image = null,
    index_offset: u32 = 0,
    index_size: u8 = 0,
    topology: Topology = .triangles,
    first: u32 = 0,
    count: u32 = 0,
    instances: u32 = 1,
    /// primitive restart at the fixed index (the index type's largest)
    restart: bool = false,
    /// an occlusion query's word: set where a sample passes (null: none)
    query: ?*engine.Image = null,
    /// window = ndc * half + center (x, y); depth = ndc * scale + bias,
    /// fragments outside [zmin, zmax] dropped
    center: [2]f32 = .{ 0, 0 },
    half: [2]f32 = .{ 0, 0 },
    depth_scale: f32 = 0.5,
    depth_bias: f32 = 0.5,
    zmin: f32 = 0,
    zmax: f32 = 1,
    /// the pixels drawn may be in (viewport, framebuffer, scissor met)
    rect: engine.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    /// bit 0: cull front faces, bit 1: back faces
    cull: u2 = 0,
    front_ccw: bool = true,
    depth_test: bool = false,
    /// bit 0: pass when less, 1: equal, 2: greater (NEVER 0 .. ALWAYS 7)
    depth_func: u3 = 0b001,
    depth_write: bool = false,
    blend: ?Blend = null,
    /// the color bits kept (glColorMask's channels off)
    keep: u32 = 0,
    uniforms: []const u32 = &.{},
    /// Fragment outputs 1 .. MAX_TARGETS - 1 into these (null: not
    /// drawn); output 0 goes to `color` unless `color_off` (GL's
    /// DrawBuffers with NONE first, a depth-only pass: `color` is then
    /// never touched and only names the draw's size).
    targets: [MAX_TARGETS]?Target = @splat(null),
    color_off: bool = false,
    /// Multisampling (the images' `samples` > 1): the samples drawn, bit
    /// s for sample s (glSampleCoverage's, Vulkan's pSampleMask), and
    /// alpha to coverage (output 0's alpha takes that share of them).
    sample_mask: u32 = 0xff,
    alpha_to_coverage: bool = false,
    /// Depth bias (glPolygonOffset, Vulkan's depthBias): triangles' depth
    /// moved by factor * max(|dz/dx|, |dz/dy|) + units * 2^-24, at most
    /// |clamp| (0: no clamp) toward its sign.
    bias_factor: f32 = 0,
    bias_units: f32 = 0,
    bias_clamp: f32 = 0,

    /// The byte of the vertex records' buffer past the records: primitive
    /// restart's word (the engine allocates it and zeroes it).
    pub fn restartWord(d: *const Draw) u32 {
        return d.instances * d.count * d.pipe.vstride * 4;
    }

    /// Primitives a instance.
    pub fn prims(d: *const Draw) u32 {
        return switch (d.topology) {
            .triangles => d.count / 3,
            .strip, .fan => if (d.count >= 3) d.count - 2 else 0,
            .points => d.count,
            .lines => d.count / 2,
            .line_strip => if (d.count >= 2) d.count - 1 else 0,
            .line_loop => if (d.count >= 2) d.count else 0,
        };
    }

    /// (kept for callers counting triangles: the primitives)
    pub fn triangles(d: *const Draw) u32 {
        return d.prims();
    }

    /// Samples a pixel: the targets' (and the depth's).
    pub fn samples(d: *const Draw) u8 {
        if (!d.color_off) return d.color.samples;
        for (d.targets) |t| {
            if (t) |x| return x.img.samples;
        }
        if (d.depth) |x| return x.samples;
        if (d.stencil) |x| return x.samples;
        return 1;
    }

    pub fn setupKind(d: *const Draw) SetupKind {
        return switch (d.topology) {
            .triangles, .strip, .fan => .triangles,
            .points => .points,
            .lines, .line_strip, .line_loop => if (d.samples() > 1) .line_quads else .lines,
        };
    }

    /// Records the setup kernel makes an instance (two a rectangle).
    pub fn records(d: *const Draw) u32 {
        return switch (d.setupKind()) {
            .triangles, .lines => d.prims(),
            .line_quads, .points => 2 * d.prims(),
        };
    }

    /// The tile kernel the draw needs.
    pub fn variant(d: *const Draw) Variant {
        var mask: u8 = if (d.color_off) 0 else 1;
        for (d.targets[1..], 1..) |tg, ti| {
            if (tg != null) mask |= @as(u8, 1) << @intCast(ti);
        }
        return .{ .stencil = d.stencil != null, .samples = d.samples(), .targets = mask, .lines = d.setupKind() == .lines };
    }
};

// ── 64-bit integers in pairs of 32-bit registers ───────────────────────────

const W64 = struct { lo: V, hi: V };

fn mul64(k: *kir.Kernel, a: Arg, b: Arg) W64 {
    return .{ .lo = k.op2(.imul, .u32, a, b), .hi = k.op2(.imulhi, .i32, a, b) };
}

fn add64(k: *kir.Kernel, x: W64, y: W64) W64 {
    const lo = k.op2(.iadd, .u32, r(x.lo), r(y.lo));
    const carry = k.sel(.u32, r(k.cmp(.u32, .lt, r(lo), r(x.lo))), u(1), u(0));
    return .{ .lo = lo, .hi = k.op2(.iadd, .i32, r(k.op2(.iadd, .i32, r(x.hi), r(y.hi))), r(carry)) };
}

fn sub64(k: *kir.Kernel, x: W64, y: W64) W64 {
    const lo = k.op2(.isub, .u32, r(x.lo), r(y.lo));
    const borrow = k.sel(.u32, r(k.cmp(.u32, .lt, r(x.lo), r(y.lo))), u(1), u(0));
    return .{ .lo = lo, .hi = k.op2(.isub, .i32, r(k.op2(.isub, .i32, r(x.hi), r(y.hi))), r(borrow)) };
}

// ── Culling a group's triangles at once ────────────────────────────────────

fn shAt(off: u32) kir.Mem {
    var m = kir.shared(32);
    m.imm = @intCast(off);
    return m;
}

/// Two arrays of CULL words in shared memory: a scan's.
const Scan = struct { a: u32, b: u32 };

fn scanAlloc(k: *kir.Kernel) Scan {
    return .{ .a = k.sharedAlloc(CULL * 4, 4), .b = k.sharedAlloc(CULL * 4, 4) };
}

/// Ordered compaction over the group's CULL threads (`t` is the thread's
/// linear index): its place among the threads before it that have `hit`,
/// and how many have it. A scan in shared memory, its barriers included:
/// call it where the whole group is, never under divergence.
///
/// Every shared address here and in the lists it fills is clamped into
/// its CULL words: the thread's index, the place (below CULL; a place
/// that wrapped below 0 too) and the count (at most CULL). All of them
/// are in range by construction, and the emulated RTX runs these kernels
/// clean with any warp order and WebRender's tile kernels on random data;
/// yet the Legion (fa08a266, 1110u, 1110w) faulted Out Of Range Address
/// on every SM in one of Firefox's gl_raster launches, now and then, and
/// lost its GPU context. Clamped, such a launch draws a tile wrong at
/// worst instead (three IMNMX a chunk).
fn compact(k: *kir.Kernel, sc: Scan, t_in: V, hit: V) struct { pos: V, total: V } {
    const x = k.sel(.u32, r(hit), u(1), u(0));
    const t = k.op2(.imin, .u32, r(t_in), u(CULL - 1));
    const t4 = k.op2(.shl, .u32, r(t), u(2));
    k.store(.u32, shAt(sc.a), r(t4), r(x));
    k.barrier();
    var cur = sc.a;
    var nxt = sc.b;
    var d: u32 = 1;
    while (d < CULL) : (d *= 2) {
        const v = k.load(.u32, shAt(cur), r(t4));
        const has = k.cmp(.u32, .ge, r(t), u(d));
        const o4 = k.sel(.u32, r(has), r(k.op2(.isub, .u32, r(t4), u(4 * d))), r(t4));
        const p = k.load(.u32, shAt(cur), r(o4));
        k.store(.u32, shAt(nxt), r(t4), r(k.op2(.iadd, .u32, r(v), r(k.sel(.u32, r(has), r(p), u(0))))));
        k.barrier();
        const sw = cur;
        cur = nxt;
        nxt = sw;
    }
    const incl = k.load(.u32, shAt(cur), r(t4));
    const total = k.load(.u32, shAt(cur), u(4 * (CULL - 1)));
    // (every read done before the next scan writes)
    k.barrier();
    return .{
        .pos = k.op2(.imin, .u32, r(k.op2(.isub, .u32, r(incl), r(x))), u(CULL - 1)),
        .total = k.op2(.imin, .u32, r(total), u(CULL)),
    };
}

/// Whether triangle record `base`'s pixel box meets [x0, x1] x [y0, y1]
/// (inclusive) and the triangle is drawn.
fn meets(k: *kir.Kernel, b: u8, base: V, x0: V, y0: V, x1: V, y1: V) V {
    const valid = ld(k, b, base, S_VALID, .u32);
    var hit = k.cmp(.u32, .ne, r(valid), u(0));
    hit = k.op2(.pand, .pred, r(hit), r(k.cmp(.i32, .ge, r(ld(k, b, base, S_BOX + 2, .i32)), r(x0))));
    hit = k.op2(.pand, .pred, r(hit), r(k.cmp(.i32, .le, r(ld(k, b, base, S_BOX, .i32)), r(x1))));
    hit = k.op2(.pand, .pred, r(hit), r(k.cmp(.i32, .ge, r(ld(k, b, base, S_BOX + 3, .i32)), r(y0))));
    return k.op2(.pand, .pred, r(hit), r(k.cmp(.i32, .le, r(ld(k, b, base, S_BOX + 1, .i32)), r(y1))));
}

// ── Kernel 1: vertices ─────────────────────────────────────────────────────

// parameters
const V_COUNT = 0;
const V_FIRST = 1;
const V_INDEX_SIZE = 2;
const V_INDEX_OFF = 3;
const V_CX = 4;
const V_CY = 5;
const V_HX = 6;
const V_HY = 7;
const V_ZS = 8;
const V_ZB = 9;
const V_STRIDE = 10;
const V_INDEX_LIMIT = 11;
const V_ATTR = 12;
const V_ATTR_WORDS = 8;
/// the restart index (0: none), after the attributes; then the capture
/// kernel's buffers' first words
const V_RESTART = V_ATTR + MAX_ATTRS * V_ATTR_WORDS;
const C_BASE = V_RESTART + 1;
/// points drawn: a vertex outside the clip volume is out (its sprite
/// with it), as GL and Vulkan clip points
const V_POINTS = C_BASE + MAX_CAPTURE_BUFFERS;
/// primitive restart in a strip or fan: the byte of the word after the
/// records, set where a vertex is the restart index (RESTART_NONE: none)
const V_FLAG = V_POINTS + 1;
pub const VERTEX_PARAMS = V_FLAG + 1;
pub const RESTART_NONE: u32 = 0xffff_ffff;
/// A restart index's vertex record's x (no vertex snaps there).
const RESTART_X: u32 = 0x8000_0000;
// an attribute's format word
const F_FLOAT = 1 << 8;
const F_SIGNED = 1 << 9;
const F_NORM = 1 << 10;
const F_INT = 1 << 11;

/// bindings: 0 vertex records (written), 1 uniforms, 2 the element array,
/// 3.. each attribute's buffer, then the textures
pub fn vertexKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    var k = kir.Kernel.init(s, "gl_vertex", .{ VERTEX_GROUP, 1, 1 });
    const b_out = k.binding();
    const b_uni = k.binding();
    const b_idx = k.binding();
    var b_attr: [MAX_ATTRS]u8 = undefined;
    for (&b_attr) |*b| b.* = k.binding();
    const sh = p.shaders;
    const b_tex = k.bindings;
    for (0..sh.textures) |_| _ = k.binding();
    const b_buf = k.bindings;
    for (0..sh.buffers) |_| _ = k.binding();
    const count = k.param(.u32, V_COUNT);
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(VERTEX_GROUP), r(k.tid(0)));
    const inst = k.gid(1);
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(count))));
    {
        const v = vertexOf(&k, b_idx, x);
        var io = VertexIO{ .vertex_id = v, .instance_id = inst, .uniforms = b_uni, .textures = b_tex, .buffers = b_buf };
        for (0..sh.attrs) |a| io.attr[a] = fetch(&k, b_attr[a], @intCast(V_ATTR + a * V_ATTR_WORDS), v, inst);
        sh.vertex(sh.ctx, &k, &io);
        // clip space to window space
        const w = io.position[3];
        const iw = k.div(f(1), r(w));
        const xw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(io.position[0]), r(iw))), r(k.param(.f32, V_HX)))), r(k.param(.f32, V_CX)));
        const yw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(io.position[1]), r(iw))), r(k.param(.f32, V_HY)))), r(k.param(.f32, V_CY)));
        const zw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(io.position[2]), r(iw))), r(k.param(.f32, V_ZS)))), r(k.param(.f32, V_ZB)));
        // (in: w > 0, inside the guard band; NaN fails every compare; not
        // the restart index)
        var ok = k.cmp(.f32, .gt, r(w), f(0));
        const restart = k.param(.u32, V_RESTART);
        const restarts = k.op2(.pand, .pred, r(k.cmp(.u32, .ne, r(restart), u(0))), r(k.cmp(.u32, .eq, r(v), r(restart))));
        ok = k.op2(.pand, .pred, r(ok), r(k.op1(.pnot, .pred, r(restarts))));
        ok = k.op2(.pand, .pred, r(ok), r(k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(xw))), f(GUARD))));
        ok = k.op2(.pand, .pred, r(ok), r(k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(yw))), f(GUARD))));
        {
            // (a point: inside -w <= x, y, z <= w)
            var in = k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(io.position[0]))), r(w));
            in = k.op2(.pand, .pred, r(in), r(k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(io.position[1]))), r(w))));
            in = k.op2(.pand, .pred, r(in), r(k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(io.position[2]))), r(w))));
            const pts = k.cmp(.u32, .ne, r(k.param(.u32, V_POINTS)), u(0));
            ok = k.op2(.pand, .pred, r(ok), r(k.op2(.por, .pred, r(k.op1(.pnot, .pred, r(pts))), r(in))));
        }
        const xs = k.sel(.f32, r(ok), r(xw), f(0));
        const ys = k.sel(.f32, r(ok), r(yw), f(0));
        const xf = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(xs), f(SUB))));
        const yf = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(ys), f(SUB))));
        const rec = k.op3(.imad, .u32, r(inst), r(count), r(x));
        const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(k.param(.u32, V_STRIDE)))), u(2));
        // (the restart index's record: marked for the strip's setup, and
        // the draw's word set)
        k.store(.i32, memAt(b_out, 0), r(base), r(k.sel(.i32, r(restarts), u(RESTART_X), r(xf))));
        const flag_at = k.param(.u32, V_FLAG);
        k.ifp(r(k.op2(.pand, .pred, r(restarts), r(k.cmp(.u32, .ne, r(flag_at), u(RESTART_NONE))))));
        k.store(.u32, kir.global(b_out, 32), r(flag_at), r(k.mov(.u32, u(1))));
        k.endif();
        k.store(.i32, memAt(b_out, 4), r(base), r(yf));
        k.store(.f32, memAt(b_out, 8), r(base), r(zw));
        k.store(.f32, memAt(b_out, 12), r(base), r(k.sel(.f32, r(ok), r(iw), f(-1))));
        for (0..sh.varyings) |j| {
            const val = io.varying[j];
            const out = if (sh.flat & (@as(u64, 1) << @intCast(j)) != 0) val else k.op2(.fmul, .f32, r(val), r(iw));
            k.store(.f32, memAt(b_out, @intCast(16 + 4 * j)), r(base), r(out));
        }
        for (0..sh.clips) |j| {
            const cd = if (io.clip[j] == .none) k.mov(.f32, f(0)) else io.clip[j];
            k.store(.f32, memAt(b_out, 4 * p.vClip(j)), r(base), r(k.op2(.fmul, .f32, r(cd), r(iw))));
        }
        if (sh.point_size) {
            // (GL's and Vulkan's point sizes: 1 .. the largest; NaN: 1)
            const ps = if (io.point_size == .none) k.mov(.f32, f(1)) else io.point_size;
            const psz = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(ps), f(1))), f(MAX_POINT_SIZE));
            k.store(.f32, memAt(b_out, 4 * p.vSize()), r(base), r(psz));
        }
    }
    k.endif();
    return k;
}

/// The vertex thread x draws: first + x, or the element array's x-th
/// index.
fn vertexOf(k: *kir.Kernel, b_idx: u8, x: V) V {
    const idx_size = k.param(.u32, V_INDEX_SIZE);
    const v = k.reg(.u32);
    k.set(v, .iadd, r(k.param(.u32, V_FIRST)), r(x), no);
    k.ifp(r(k.cmp(.u32, .ne, r(idx_size), u(0))));
    {
        const at = k.op3(.imad, .u32, r(x), r(idx_size), r(k.param(.u32, V_INDEX_OFF)));
        // (inside the buffer whatever the app asks: the last word at most)
        const wat = k.op2(.imin, .u32, r(k.op2(.@"and", .u32, r(at), u(0xffff_fffc))), r(k.param(.u32, V_INDEX_LIMIT)));
        const word = k.load(.u32, kir.global(b_idx, 32), r(wat));
        const shift = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(at), u(3))), u(3));
        k.set(v, .bfe, r(word), r(shift), r(k.op2(.shl, .u32, r(idx_size), u(3))));
    }
    k.endif();
    return v;
}

/// Transform feedback: a thread per vertex of each instance (as the
/// vertex kernel), the shader's vertex code, and the outputs it captures,
/// as the shader made them (clip space; no 1/w), into each buffer's
/// record of vertex (instance * count + x), from the buffer's first word.
pub fn captureKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    var k = kir.Kernel.init(s, "gl_capture", .{ VERTEX_GROUP, 1, 1 });
    var b_out: [MAX_CAPTURE_BUFFERS]u8 = undefined;
    for (&b_out) |*b| b.* = k.binding();
    const b_uni = k.binding();
    const b_idx = k.binding();
    var b_attr: [MAX_ATTRS]u8 = undefined;
    for (&b_attr) |*b| b.* = k.binding();
    const sh = p.shaders;
    const b_tex = k.bindings;
    for (0..sh.textures) |_| _ = k.binding();
    const b_buf = k.bindings;
    for (0..sh.buffers) |_| _ = k.binding();
    const count = k.param(.u32, V_COUNT);
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(VERTEX_GROUP), r(k.tid(0)));
    const inst = k.gid(1);
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(count))));
    {
        const v = vertexOf(&k, b_idx, x);
        var io = VertexIO{ .vertex_id = v, .instance_id = inst, .uniforms = b_uni, .textures = b_tex, .buffers = b_buf };
        for (0..sh.attrs) |a| io.attr[a] = fetch(&k, b_attr[a], @intCast(V_ATTR + a * V_ATTR_WORDS), v, inst);
        sh.vertex(sh.ctx, &k, &io);
        const rec = k.op3(.imad, .u32, r(inst), r(count), r(x));
        var at: [MAX_CAPTURE_BUFFERS]V = @splat(.none);
        for (sh.capture_stride, 0..) |stride, b| {
            if (stride == 0) continue;
            at[b] = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(rec), u(stride), r(k.param(.u32, @intCast(C_BASE + b))))), u(2));
        }
        for (sh.capture) |cp| {
            const val = if (cp.position) io.position[cp.src] else io.varying[cp.src];
            const m = memAt(b_out[cp.buffer], @as(u32, cp.word) * 4);
            // (an output the code never writes: 0)
            if (val == .none) k.store(.u32, m, r(at[cp.buffer]), r(k.mov(.u32, u(0)))) else k.store(.f32, m, r(at[cp.buffer]), r(val));
        }
    }
    k.endif();
    return k;
}

/// An attribute's four components for vertex v of instance `inst`.
fn fetch(k: *kir.Kernel, b: u8, pw: u16, v: V, inst: V) [4]V {
    const fmt = k.param(.u32, pw + 2);
    const comps = k.op2(.@"and", .u32, r(fmt), u(7));
    const size = k.op3(.bfe, .u32, r(fmt), u(4), u(4));
    const integer = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(fmt), u(F_INT))), u(0));
    const float = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(fmt), u(F_FLOAT))), u(0));
    const signed = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(fmt), u(F_SIGNED))), u(0));
    const norm = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(fmt), u(F_NORM))), u(0));
    const per_inst = k.cmp(.u32, .ne, r(k.param(.u32, pw + 3)), u(0));
    const ai = k.sel(.u32, r(per_inst), r(inst), r(v));
    const base = k.op3(.imad, .u32, r(ai), r(k.param(.u32, pw + 1)), r(k.param(.u32, pw)));
    var out: [4]V = undefined;
    for (0..4) |c| {
        const o = k.reg(.u32);
        out[c] = o;
        // (missing components: 0, 0, 0, 1; the int 1 for an integer one)
        if (c == 3) {
            k.set(o, .sel, u(1), u(0x3f80_0000), r(integer));
        } else k.set(o, .mov, u(0), no, no);
        const constant = k.cmp(.u32, .eq, r(comps), u(0));
        k.ifp(r(constant));
        k.set(o, .mov, r(k.param(.u32, pw + 4 + @as(u16, @intCast(c)))), no, no);
        k.els();
        k.ifp(r(k.cmp(.u32, .gt, r(comps), u(@intCast(c)))));
        {
            const at = k.op3(.imad, .u32, r(size), u(@intCast(c)), r(base));
            // (inside the buffer whatever the app asks: its last word at most)
            const wat = k.op2(.imin, .u32, r(k.op2(.@"and", .u32, r(at), u(0xffff_fffc))), r(k.param(.u32, pw + 5)));
            const word = k.load(.u32, kir.global(b, 32), r(wat));
            k.ifp(r(float));
            k.set(o, .mov, r(word), no, no);
            k.els();
            {
                const shift = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(at), u(3))), u(3));
                const bits = k.op2(.shl, .u32, r(size), u(3));
                const uraw = k.op3(.bfe, .u32, r(word), r(shift), r(bits));
                const sraw = k.op3(.bfe, .i32, r(word), r(shift), r(bits));
                k.ifp(r(integer));
                k.set(o, .sel, r(sraw), r(uraw), r(signed));
                k.els();
                {
                    const fu = k.cvt(.u32, .f32, .rne, r(uraw));
                    const fs = k.cvt(.i32, .f32, .rne, r(sraw));
                    const fv = k.sel(.f32, r(signed), r(fs), r(fu));
                    // (normalized: c / (2^b - 1), or c / (2^(b-1) - 1) at least -1)
                    const nv = k.div(r(fv), r(k.param(.f32, pw + 4)));
                    const ns = k.sel(.f32, r(signed), r(k.op2(.fmax, .f32, r(nv), f(-1))), r(nv));
                    // (f32 bits into the attribute's register: mov reinterprets)
                    k.set(o, .sel, r(k.mov(.u32, r(ns))), r(k.mov(.u32, r(fv))), r(norm));
                }
                k.endif();
            }
            k.endif();
        }
        k.endif();
        k.endif();
    }
    return out;
}

// ── Kernel 2: primitive setup ──────────────────────────────────────────────

const T_NTRI = 0; // primitives an instance
const T_COUNT = 1;
const T_MODE = 2;
const T_CULL = 3;
const T_FRONT_CCW = 4;
const T_VSTRIDE = 5;
const T_SSTRIDE = 6;
const T_RECT = 7; // x0, y0, x1, y1 (exclusive)
const T_BIAS = 11; // depth bias: factor, units (times 2^-24), clamp
const T_MS = 14; // multisampled: boxes take every pixel a sample may be in
const T_FLAG = 15; // primitive restart's word in the vertex records (V_FLAG)
pub const SETUP_PARAMS = 16;

/// bindings: 0 triangle records (written), 1 vertex records
pub fn setupKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    return setupKernelFor(s, p, .triangles);
}

/// A thread per primitive of each instance (Draw.prims), its records
/// (Draw.records) from the vertices':
/// - triangles: lists, strips and fans; culled, turned counter-clockwise,
///   depth bias added;
/// - lines (lists, strips, loops): a record each, covered by the
///   diamond-exit rule in the tile kernel (Variant.lines);
/// - line_quads: a line as a rectangle one pixel wide, its ends square
///   (GL's and Vulkan's multisampled lines): two triangles;
/// - points: the sprite, a square gl_PointSize pixels a side about the
///   vertex: two triangles, gl_PointCoord's planes across it.
/// Lines and points are never culled and always face front.
pub fn setupKernelFor(s: kir.Storage, p: *const Pipeline, kind: SetupKind) kir.Kernel {
    const names = [_][]const u8{ "gl_setup", "gl_setup_lines", "gl_setup_line_quads", "gl_setup_points" };
    var k = kir.Kernel.init(s, names[@intFromEnum(kind)], .{ SETUP_GROUP, 1, 1 });
    const b_out = k.binding();
    const b_v = k.binding();
    const ntri = k.param(.u32, T_NTRI);
    const t = k.op3(.imad, .u32, r(k.gid(0)), u(SETUP_GROUP), r(k.tid(0)));
    const inst = k.gid(1);
    k.ifp(r(k.cmp(.u32, .lt, r(t), r(ntri))));
    {
        const mode = k.param(.u32, T_MODE);
        const count = k.param(.u32, T_COUNT);
        const vstride = k.param(.u32, T_VSTRIDE);
        const prim = k.op3(.imad, .u32, r(inst), r(ntri), r(t));
        const sv = SetupVerts{ .k = &k, .b_v = b_v, .inst = inst, .count = count, .vstride = vstride };
        switch (kind) {
            .triangles => {
                // the topology's vertices (GL's: the last provokes)
                const t3 = k.op2(.imul, .u32, r(t), u(3));
                const is_strip = k.cmp(.u32, .eq, r(mode), u(1));
                const is_fan = k.cmp(.u32, .eq, r(mode), u(2));
                // primitive restart in a strip or fan (the draw had a
                // restart index): a new one from the vertex after the last
                // restart before t, its first triangle even, its center
                // that vertex
                const start = k.reg(.u32);
                k.set(start, .mov, u(0), no, no);
                const flag_at = k.param(.u32, T_FLAG);
                const strip_or_fan = k.op2(.por, .pred, r(is_strip), r(is_fan));
                const any = k.op2(.pand, .pred, r(strip_or_fan), r(k.cmp(.u32, .ne, r(flag_at), u(RESTART_NONE))));
                k.ifp(r(any));
                k.ifp(r(k.cmp(.u32, .ne, r(k.load(.u32, kir.global(b_v, 32), r(k.op2(.imin, .u32, r(flag_at), u(RESTART_NONE - 3))))), u(0))));
                {
                    const j = k.reg(.u32);
                    k.set(j, .mov, r(t), no, no);
                    k.loop();
                    {
                        k.brk(r(k.cmp(.u32, .eq, r(j), u(0))));
                        k.set(j, .isub, r(j), u(1), no);
                        const x = sv.xOf(j);
                        const hit = k.cmp(.u32, .eq, r(x), u(RESTART_X));
                        k.ifp(r(hit));
                        k.set(start, .iadd, r(j), u(1), no);
                        k.endif();
                        k.brk(r(hit));
                    }
                    k.endloop();
                }
                k.endif();
                k.endif();
                const odd = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(k.op2(.isub, .u32, r(t), r(start))), u(1))), u(0));
                const t1 = k.op2(.iadd, .u32, r(t), u(1));
                const t2 = k.op2(.iadd, .u32, r(t), u(2));
                // strip: (t, t+1, t+2), odd t (t+1, t, t+2); fan: (0, t+1, t+2)
                const s0 = k.sel(.u32, r(odd), r(t1), r(t));
                const s1 = k.sel(.u32, r(odd), r(t), r(t1));
                var iv: [3]V = undefined;
                iv[0] = k.sel(.u32, r(is_fan), r(start), r(k.sel(.u32, r(is_strip), r(s0), r(t3))));
                iv[1] = k.sel(.u32, r(is_fan), r(t1), r(k.sel(.u32, r(is_strip), r(s1), r(k.op2(.iadd, .u32, r(t3), u(1))))));
                iv[2] = k.sel(.u32, r(k.op2(.por, .pred, r(is_fan), r(is_strip))), r(t2), r(k.op2(.iadd, .u32, r(t3), u(2))));
                var c: Corners = undefined;
                for (0..3) |n| c.set(n, sv.vertex(iv[n]));
                writeTri(&k, p, b_out, b_v, prim, c, c.vbase[2], .{ .cull = true, .bias = true });
            },
            .lines, .line_quads => {
                // lists (2t, 2t+1), strips (t, t+1), loops (t, t+1 or 0)
                const is_list = k.cmp(.u32, .eq, r(mode), u(@intFromEnum(Topology.lines)));
                const is_loop = k.cmp(.u32, .eq, r(mode), u(@intFromEnum(Topology.line_loop)));
                const t2 = k.op2(.shl, .u32, r(t), u(1));
                const t1 = k.op2(.iadd, .u32, r(t), u(1));
                const ia = k.sel(.u32, r(is_list), r(t2), r(t));
                const nb = k.sel(.u32, r(is_list), r(k.op2(.iadd, .u32, r(t2), u(1))), r(t1));
                const ib = k.sel(.u32, r(k.op2(.pand, .pred, r(is_loop), r(k.cmp(.u32, .ge, r(nb), r(count))))), u(0), r(nb));
                const a = sv.vertex(ia);
                const b = sv.vertex(ib);
                if (kind == .lines) {
                    writeLine(&k, p, b_out, b_v, prim, a, b);
                } else {
                    // the rectangle: the ends +- half a pixel across the line
                    const dx = k.cvt(.i32, .f32, .rne, r(k.op2(.isub, .i32, r(b.x), r(a.x))));
                    const dy = k.cvt(.i32, .f32, .rne, r(k.op2(.isub, .i32, r(b.y), r(a.y))));
                    const len = k.sqrt(r(k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(dx), r(dx))), r(k.op2(.fmul, .f32, r(dy), r(dy))))));
                    const il = k.div(f(SUB / 2), r(k.op2(.fmax, .f32, r(len), f(1))));
                    const nx = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(k.op1(.fneg, .f32, r(dy))), r(il))));
                    const ny = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(dx), r(il))));
                    const a1 = a.moved(&k, nx, ny, false);
                    const a2 = a.moved(&k, nx, ny, true);
                    const b1 = b.moved(&k, nx, ny, false);
                    const b2 = b.moved(&k, nx, ny, true);
                    const r0 = k.op2(.shl, .u32, r(prim), u(1));
                    var c: Corners = undefined;
                    c.set(0, a1);
                    c.set(1, a2);
                    c.set(2, b2);
                    writeTri(&k, p, b_out, b_v, r0, c, b.base, .{});
                    c.set(0, a1);
                    c.set(1, b2);
                    c.set(2, b1);
                    writeTri(&k, p, b_out, b_v, k.op2(.iadd, .u32, r(r0), u(1)), c, b.base, .{});
                }
            },
            .points => {
                const a = sv.vertex(t);
                // the side in 1/16 pixel, halved (rounded: an even side's
                // corners on whole pixels' edges)
                const size = if (p.shaders.point_size) k.load(.f32, memAt(b_v, 4 * p.vSize()), r(a.base)) else k.mov(.f32, f(1));
                const h = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(size), f(SUB / 2))));
                const nh = k.op2(.isub, .i32, i(0), r(h));
                const c0 = a.at(&k, nh, nh);
                const c1 = a.at(&k, h, nh);
                const c2 = a.at(&k, h, h);
                const c3 = a.at(&k, nh, h);
                const r0 = k.op2(.shl, .u32, r(prim), u(1));
                const sprite = Sprite{ .x = a.x, .y = a.y, .size = size };
                var c: Corners = undefined;
                c.set(0, c0);
                c.set(1, c1);
                c.set(2, c2);
                writeTri(&k, p, b_out, b_v, r0, c, a.base, .{ .sprite = sprite });
                c.set(0, c0);
                c.set(1, c2);
                c.set(2, c3);
                writeTri(&k, p, b_out, b_v, k.op2(.iadd, .u32, r(r0), u(1)), c, a.base, .{ .sprite = sprite });
            },
        }
    }
    k.endif();
    return k;
}

/// A vertex as setup reads it: x, y (1/16 pixel), depth, 1/w, and its
/// record's byte offset (the varyings' place).
const SVert = struct {
    x: V,
    y: V,
    z: V,
    w: V,
    base: V,

    /// The same vertex moved by (dx, dy) 1/16 pixels (negated: -).
    fn moved(a: SVert, k: *kir.Kernel, dx: V, dy: V, neg: bool) SVert {
        const op: kir.Op = if (neg) .isub else .iadd;
        var o = a;
        o.x = k.op2(op, .i32, r(a.x), r(dx));
        o.y = k.op2(op, .i32, r(a.y), r(dy));
        return o;
    }
    fn at(a: SVert, k: *kir.Kernel, dx: V, dy: V) SVert {
        return a.moved(k, dx, dy, false);
    }
};

const SetupVerts = struct {
    k: *kir.Kernel,
    b_v: u8,
    inst: V,
    count: V,
    vstride: V,

    /// Vertex ix's x alone (RESTART_X: the restart index's).
    fn xOf(sv: SetupVerts, ix: V) V {
        const k = sv.k;
        const rec = k.op3(.imad, .u32, r(sv.inst), r(sv.count), r(ix));
        return k.load(.u32, memAt(sv.b_v, 0), r(k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(sv.vstride))), u(2))));
    }

    fn vertex(sv: SetupVerts, ix: V) SVert {
        const k = sv.k;
        const rec = k.op3(.imad, .u32, r(sv.inst), r(sv.count), r(ix));
        const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(sv.vstride))), u(2));
        return .{
            .x = k.load(.i32, memAt(sv.b_v, 0), r(base)),
            .y = k.load(.i32, memAt(sv.b_v, 4), r(base)),
            .z = k.load(.f32, memAt(sv.b_v, 8), r(base)),
            .w = k.load(.f32, memAt(sv.b_v, 12), r(base)),
            .base = base,
        };
    }
};

const Corners = struct {
    vx: [3]V,
    vy: [3]V,
    vz: [3]V,
    vw: [3]V,
    vbase: [3]V,

    fn set(c: *Corners, n: usize, v: SVert) void {
        c.vx[n] = v.x;
        c.vy[n] = v.y;
        c.vz[n] = v.z;
        c.vw[n] = v.w;
        c.vbase[n] = v.base;
    }
};

/// A point's sprite: its center (1/16 pixel) and side (pixels), for
/// gl_PointCoord's planes.
const Sprite = struct { x: V, y: V, size: V };

const TriOpts = struct {
    /// a triangle of the draw's (culled by winding, its facing kept, depth
    /// bias added); else a rectangle's half (never culled, front facing)
    cull: bool = false,
    bias: bool = false,
    sprite: ?Sprite = null,
};

fn st(k: *kir.Kernel, b: u8, bs: V, word: u32, ty: kir.Ty, val: Arg) void {
    k.store(ty, memAt(b, word * 4), r(bs), val);
}

/// A plane over pixel coordinates from the primitive's first corner:
/// value v0 there, slopes (gx, gy).
fn putPlane(k: *kir.Kernel, bo: u8, bs: V, word: u32, v0: Arg, gx: Arg, gy: Arg) void {
    k.store(.f32, memAt(bo, word * 4), r(bs), v0);
    k.store(.f32, memAt(bo, (word + 1) * 4), r(bs), gx);
    k.store(.f32, memAt(bo, (word + 2) * 4), r(bs), gy);
}

/// Triangle record `rec`: corners c (any winding), the provoking vertex's
/// record at pbase (flat varyings').
fn writeTri(k: *kir.Kernel, p: *const Pipeline, b_out: u8, b_v: u8, rec: V, c_in: Corners, pbase_in: V, o: TriOpts) void {
    const sh = p.shaders;
    var c = c_in;
    var valid = k.cmp(.f32, .gt, r(c.vw[0]), f(0));
    valid = k.op2(.pand, .pred, r(valid), r(k.cmp(.f32, .gt, r(c.vw[1]), f(0))));
    valid = k.op2(.pand, .pred, r(valid), r(k.cmp(.f32, .gt, r(c.vw[2]), f(0))));
    // twice the signed area, exact: (x1-x0)(y2-y0) - (x2-x0)(y1-y0)
    const dx1 = k.op2(.isub, .i32, r(c.vx[1]), r(c.vx[0]));
    const dy1 = k.op2(.isub, .i32, r(c.vy[1]), r(c.vy[0]));
    const dx2 = k.op2(.isub, .i32, r(c.vx[2]), r(c.vx[0]));
    const dy2 = k.op2(.isub, .i32, r(c.vy[2]), r(c.vy[0]));
    const area = sub64(k, mul64(k, r(dx1), r(dy2)), mul64(k, r(dx2), r(dy1)));
    const zero = k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(area.hi), i(0))), r(k.cmp(.u32, .eq, r(area.lo), u(0))));
    const neg = k.cmp(.i32, .lt, r(area.hi), i(0));
    const ccw = k.op1(.pnot, .pred, r(k.op2(.por, .pred, r(neg), r(zero))));
    valid = k.op2(.pand, .pred, r(valid), r(k.op1(.pnot, .pred, r(zero))));
    var same: V = .none;
    if (o.cull) {
        const front_ccw = k.cmp(.u32, .ne, r(k.param(.u32, T_FRONT_CCW)), u(0));
        // front facing: counter-clockwise exactly when the front is
        same = k.cmp(.u32, .eq, r(k.sel(.u32, r(ccw), u(1), u(0))), r(k.sel(.u32, r(front_ccw), u(1), u(0))));
        const cull = k.param(.u32, T_CULL);
        const cull_front = k.op2(.pand, .pred, r(same), r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(cull), u(1))), u(0))));
        const cull_back = k.op2(.pand, .pred, r(k.op1(.pnot, .pred, r(same))), r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(cull), u(2))), u(0))));
        valid = k.op2(.pand, .pred, r(valid), r(k.op1(.pnot, .pred, r(k.op2(.por, .pred, r(cull_front), r(cull_back))))));
    }
    // counter-clockwise from here: a clockwise triangle's 1 and 2 swap
    const sw = k.op1(.pnot, .pred, r(ccw));
    const swap = struct {
        fn two(kk: *kir.Kernel, ty: kir.Ty, p_: V, a: *V, b: *V) void {
            const na = kk.sel(ty, r(p_), r(b.*), r(a.*));
            const nb = kk.sel(ty, r(p_), r(a.*), r(b.*));
            a.* = na;
            b.* = nb;
        }
    }.two;
    swap(k, .i32, sw, &c.vx[1], &c.vx[2]);
    swap(k, .i32, sw, &c.vy[1], &c.vy[2]);
    swap(k, .f32, sw, &c.vz[1], &c.vz[2]);
    swap(k, .f32, sw, &c.vw[1], &c.vw[2]);
    swap(k, .u32, sw, &c.vbase[1], &c.vbase[2]);
    // (the provoking vertex's record, before any swap: flat varyings')
    const pbase = if (o.cull) k.sel(.u32, r(sw), r(c.vbase[1]), r(c.vbase[2])) else pbase_in;
    // |area| (> 0 once valid)
    const nlo = k.op2(.isub, .u32, u(0), r(area.lo));
    const nhi = k.op2(.isub, .i32, r(k.op2(.isub, .i32, i(0), r(area.hi))), r(k.sel(.u32, r(k.cmp(.u32, .ne, r(area.lo), u(0))), u(1), u(0))));
    const alo = k.sel(.u32, r(neg), r(nlo), r(area.lo));
    const ahi = k.sel(.i32, r(neg), r(nhi), r(area.hi));
    // the box, in pixels whose centers (x * 16 + 8) it may hold
    const xmin = k.op2(.imin, .i32, r(k.op2(.imin, .i32, r(c.vx[0]), r(c.vx[1]))), r(c.vx[2]));
    const xmax = k.op2(.imax, .i32, r(k.op2(.imax, .i32, r(c.vx[0]), r(c.vx[1]))), r(c.vx[2]));
    const ymin = k.op2(.imin, .i32, r(k.op2(.imin, .i32, r(c.vy[0]), r(c.vy[1]))), r(c.vy[2]));
    const ymax = k.op2(.imax, .i32, r(k.op2(.imax, .i32, r(c.vy[0]), r(c.vy[1]))), r(c.vy[2]));
    // (multisampled: every sample is within half a pixel of its center,
    // so the box is one pixel larger each way; the tile kernel's edge
    // test is exact)
    const px0 = k.op2(.imax, .i32, r(k.op2(.shr, .i32, r(k.op2(.iadd, .i32, r(xmin), i(7))), u(4))), r(k.param(.i32, T_RECT)));
    const py0 = k.op2(.imax, .i32, r(k.op2(.shr, .i32, r(k.op2(.iadd, .i32, r(ymin), i(7))), u(4))), r(k.param(.i32, T_RECT + 1)));
    const px1 = k.op2(.imin, .i32, r(k.op2(.shr, .i32, r(k.op2(.isub, .i32, r(xmax), i(8))), u(4))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 2)), i(1))));
    const py1 = k.op2(.imin, .i32, r(k.op2(.shr, .i32, r(k.op2(.isub, .i32, r(ymax), i(8))), u(4))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 3)), i(1))));
    const ms = k.cmp(.u32, .ne, r(k.param(.u32, T_MS)), u(0));
    const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(k.param(.u32, T_SSTRIDE)))), u(2));
    st(k, b_out, base, S_VALID, .u32, r(k.sel(.u32, r(valid), u(1), u(0))));
    st(k, b_out, base, S_BOX, .i32, r(k.sel(.i32, r(ms), r(k.op2(.imax, .i32, r(k.op2(.shr, .i32, r(xmin), u(4))), r(k.param(.i32, T_RECT)))), r(px0))));
    st(k, b_out, base, S_BOX + 1, .i32, r(k.sel(.i32, r(ms), r(k.op2(.imax, .i32, r(k.op2(.shr, .i32, r(ymin), u(4))), r(k.param(.i32, T_RECT + 1)))), r(py0))));
    st(k, b_out, base, S_BOX + 2, .i32, r(k.sel(.i32, r(ms), r(k.op2(.imin, .i32, r(k.op2(.shr, .i32, r(xmax), u(4))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 2)), i(1))))), r(px1))));
    st(k, b_out, base, S_BOX + 3, .i32, r(k.sel(.i32, r(ms), r(k.op2(.imin, .i32, r(k.op2(.shr, .i32, r(ymax), u(4))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 3)), i(1))))), r(py1))));
    // the edges a -> b (0 -> 1, 1 -> 2, 2 -> 0): A = ay - by, B = bx - ax;
    // a pixel on an edge is in when A > 0, or A == 0 and B > 0
    for (0..3) |e| {
        const a = e;
        const b = (e + 1) % 3;
        const A = k.op2(.isub, .i32, r(c.vy[a]), r(c.vy[b]));
        const B = k.op2(.isub, .i32, r(c.vx[b]), r(c.vx[a]));
        const tie = k.op2(.por, .pred, r(k.cmp(.i32, .gt, r(A), i(0))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(A), i(0))), r(k.cmp(.i32, .gt, r(B), i(0))))));
        const w0: u32 = @intCast(S_EDGE + 5 * e);
        st(k, b_out, base, w0, .i32, r(A));
        st(k, b_out, base, w0 + 1, .i32, r(B));
        st(k, b_out, base, w0 + 2, .i32, r(c.vx[a]));
        st(k, b_out, base, w0 + 3, .i32, r(c.vy[a]));
        st(k, b_out, base, w0 + 4, .i32, r(k.sel(.i32, r(tie), i(0), i(-1))));
    }
    st(k, b_out, base, S_FRONT, .u32, if (o.cull) r(k.sel(.u32, r(same), u(1), u(0))) else u(1));
    // planes over pixel coordinates from vertex 0
    var fx: [3]V = undefined;
    var fy: [3]V = undefined;
    for (0..3) |n| {
        fx[n] = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(c.vx[n]))), f(1.0 / @as(f32, SUB)));
        fy[n] = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(c.vy[n]))), f(1.0 / @as(f32, SUB)));
    }
    st(k, b_out, base, S_XY, .f32, r(fx[0]));
    st(k, b_out, base, S_XY + 1, .f32, r(fy[0]));
    const ex1 = k.op2(.fsub, .f32, r(fx[1]), r(fx[0]));
    const ey1 = k.op2(.fsub, .f32, r(fy[1]), r(fy[0]));
    const ex2 = k.op2(.fsub, .f32, r(fx[2]), r(fx[0]));
    const ey2 = k.op2(.fsub, .f32, r(fy[2]), r(fy[0]));
    // the determinant from the exact area (in pixels^2: / 256)
    const det = k.op2(.fmul, .f32, r(k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(ahi))), f(4294967296.0))), r(k.cvt(.u32, .f32, .rne, r(alo))))), f(1.0 / 256.0));
    const idet = k.div(f(1), r(k.sel(.f32, r(valid), r(det), f(1))));
    const Plane = struct {
        fn slopes(kk: *kir.Kernel, v0: V, v1: V, v2: V, x1: V, y1: V, x2: V, y2: V, id: V) [2]V {
            const d1 = kk.op2(.fsub, .f32, r(v1), r(v0));
            const d2 = kk.op2(.fsub, .f32, r(v2), r(v0));
            const ddx = kk.op2(.fmul, .f32, r(kk.op2(.fsub, .f32, r(kk.op2(.fmul, .f32, r(d1), r(y2))), r(kk.op2(.fmul, .f32, r(d2), r(y1))))), r(id));
            const ddy = kk.op2(.fmul, .f32, r(kk.op2(.fsub, .f32, r(kk.op2(.fmul, .f32, r(d2), r(x1))), r(kk.op2(.fmul, .f32, r(d1), r(x2))))), r(id));
            return .{ ddx, ddy };
        }
        fn emit(kk: *kir.Kernel, bo: u8, bs: V, word: u32, v0: V, v1: V, v2: V, x1: V, y1: V, x2: V, y2: V, id: V) void {
            const g = slopes(kk, v0, v1, v2, x1, y1, x2, y2, id);
            putPlane(kk, bo, bs, word, r(v0), r(g[0]), r(g[1]));
        }
    };
    {
        const g = Plane.slopes(k, c.vz[0], c.vz[1], c.vz[2], ex1, ey1, ex2, ey2, idet);
        var z0 = c.vz[0];
        if (o.bias) {
            // depth bias: factor * the larger slope + units (2^-24 each:
            // a 24-bit depth's least step), at most the clamp
            const dz = k.op2(.fmax, .f32, r(k.op1(.fabs, .f32, r(g[0]))), r(k.op1(.fabs, .f32, r(g[1]))));
            const raw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.param(.f32, T_BIAS)), r(dz))), r(k.op2(.fmul, .f32, r(k.param(.f32, T_BIAS + 1)), f(1.0 / 16777216.0))));
            const cl = k.param(.f32, T_BIAS + 2);
            const pos = k.cmp(.f32, .gt, r(cl), f(0));
            const negc = k.cmp(.f32, .lt, r(cl), f(0));
            var off = k.sel(.f32, r(pos), r(k.op2(.fmin, .f32, r(raw), r(cl))), r(raw));
            off = k.sel(.f32, r(negc), r(k.op2(.fmax, .f32, r(off), r(cl))), r(off));
            // (no bias: the depth untouched, whatever the slopes)
            const on = k.op2(.por, .pred, r(k.cmp(.f32, .ne, r(k.param(.f32, T_BIAS)), f(0))), r(k.cmp(.f32, .ne, r(k.param(.f32, T_BIAS + 1)), f(0))));
            z0 = k.sel(.f32, r(on), r(k.op2(.fadd, .f32, r(z0), r(off))), r(z0));
        }
        putPlane(k, b_out, base, S_Z, r(z0), r(g[0]), r(g[1]));
    }
    Plane.emit(k, b_out, base, S_W, c.vw[0], c.vw[1], c.vw[2], ex1, ey1, ex2, ey2, idet);
    for (0..sh.varyings) |j| {
        const w0: u32 = @intCast(SREC + 3 * j);
        const at = memAt(b_v, @intCast(16 + 4 * j));
        if (sh.flat & (@as(u64, 1) << @intCast(j)) != 0) {
            st(k, b_out, base, w0, .u32, r(k.load(.u32, at, r(pbase))));
            st(k, b_out, base, w0 + 1, .f32, f(0));
            st(k, b_out, base, w0 + 2, .f32, f(0));
        } else {
            const v0 = k.load(.f32, at, r(c.vbase[0]));
            const v1 = k.load(.f32, at, r(c.vbase[1]));
            const v2 = k.load(.f32, at, r(c.vbase[2]));
            Plane.emit(k, b_out, base, w0, v0, v1, v2, ex1, ey1, ex2, ey2, idet);
        }
    }
    for (0..sh.clips) |j| {
        const at = memAt(b_v, 4 * p.vClip(j));
        const v0 = k.load(.f32, at, r(c.vbase[0]));
        const v1 = k.load(.f32, at, r(c.vbase[1]));
        const v2 = k.load(.f32, at, r(c.vbase[2]));
        Plane.emit(k, b_out, base, p.sClip(j), v0, v1, v2, ex1, ey1, ex2, ey2, idet);
    }
    if (sh.point_coord) {
        const cw = p.sCoord();
        if (o.sprite) |sp| {
            // s = 1/2 + (X - x) / size, t = 1/2 - (Y - y) / size
            const inv = k.div(f(1), r(sp.size));
            const cx = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(sp.x))), f(1.0 / @as(f32, SUB)));
            const cy = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(sp.y))), f(1.0 / @as(f32, SUB)));
            const s0 = k.op2(.fadd, .f32, f(0.5), r(k.op2(.fmul, .f32, r(k.op2(.fsub, .f32, r(fx[0]), r(cx))), r(inv))));
            const t0 = k.op2(.fsub, .f32, f(0.5), r(k.op2(.fmul, .f32, r(k.op2(.fsub, .f32, r(fy[0]), r(cy))), r(inv))));
            putPlane(k, b_out, base, cw, r(s0), r(inv), f(0));
            putPlane(k, b_out, base, cw + 3, r(t0), f(0), r(k.op1(.fneg, .f32, r(inv))));
        } else {
            putPlane(k, b_out, base, cw, f(0), f(0), f(0));
            putPlane(k, b_out, base, cw + 3, f(0), f(0), f(0));
        }
    }
}

// a line's record: valid, box, then in S_EDGE's words its ends in the
// diamonds' axes (u = x + y, v = x - y, 1/16 pixel), its first end and
// direction, 8 * max(|dx|, |dy|) and the side a tie falls (Variant.lines)
const L_UA = S_EDGE;
const L_VA = S_EDGE + 1;
const L_UB = S_EDGE + 2;
const L_VB = S_EDGE + 3;
const L_AX = S_EDGE + 4;
const L_AY = S_EDGE + 5;
const L_DX = S_EDGE + 6;
const L_DY = S_EDGE + 7;
const L_M8 = S_EDGE + 8;
const L_TPOS = S_EDGE + 9;

/// Line record `rec` from a to b: GL's and Vulkan's diamond-exit rule
/// (rasterKernelFor's lines): its varyings along it, t the fragment
/// center's projection (perspective-correct, as GL says).
fn writeLine(k: *kir.Kernel, p: *const Pipeline, b_out: u8, b_v: u8, rec: V, a: SVert, b: SVert) void {
    const sh = p.shaders;
    var valid = k.op2(.pand, .pred, r(k.cmp(.f32, .gt, r(a.w), f(0))), r(k.cmp(.f32, .gt, r(b.w), f(0))));
    const dx = k.op2(.isub, .i32, r(b.x), r(a.x));
    const dy = k.op2(.isub, .i32, r(b.y), r(a.y));
    valid = k.op2(.pand, .pred, r(valid), r(k.op2(.por, .pred, r(k.cmp(.i32, .ne, r(dx), i(0))), r(k.cmp(.i32, .ne, r(dy), i(0))))));
    const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(k.param(.u32, T_SSTRIDE)))), u(2));
    // the box: pixels whose diamonds the line may meet
    const xmin = k.op2(.imin, .i32, r(a.x), r(b.x));
    const xmax = k.op2(.imax, .i32, r(a.x), r(b.x));
    const ymin = k.op2(.imin, .i32, r(a.y), r(b.y));
    const ymax = k.op2(.imax, .i32, r(a.y), r(b.y));
    st(k, b_out, base, S_VALID, .u32, r(k.sel(.u32, r(valid), u(1), u(0))));
    st(k, b_out, base, S_BOX, .i32, r(k.op2(.imax, .i32, r(k.op2(.isub, .i32, r(k.op2(.shr, .i32, r(xmin), u(4))), i(1))), r(k.param(.i32, T_RECT)))));
    st(k, b_out, base, S_BOX + 1, .i32, r(k.op2(.imax, .i32, r(k.op2(.isub, .i32, r(k.op2(.shr, .i32, r(ymin), u(4))), i(1))), r(k.param(.i32, T_RECT + 1)))));
    st(k, b_out, base, S_BOX + 2, .i32, r(k.op2(.imin, .i32, r(k.op2(.iadd, .i32, r(k.op2(.shr, .i32, r(xmax), u(4))), i(1))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 2)), i(1))))));
    st(k, b_out, base, S_BOX + 3, .i32, r(k.op2(.imin, .i32, r(k.op2(.iadd, .i32, r(k.op2(.shr, .i32, r(ymax), u(4))), i(1))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 3)), i(1))))));
    st(k, b_out, base, L_UA, .i32, r(k.op2(.iadd, .i32, r(a.x), r(a.y))));
    st(k, b_out, base, L_VA, .i32, r(k.op2(.isub, .i32, r(a.x), r(a.y))));
    st(k, b_out, base, L_UB, .i32, r(k.op2(.iadd, .i32, r(b.x), r(b.y))));
    st(k, b_out, base, L_VB, .i32, r(k.op2(.isub, .i32, r(b.x), r(b.y))));
    st(k, b_out, base, L_AX, .i32, r(a.x));
    st(k, b_out, base, L_AY, .i32, r(a.y));
    st(k, b_out, base, L_DX, .i32, r(dx));
    st(k, b_out, base, L_DY, .i32, r(dy));
    st(k, b_out, base, L_M8, .i32, r(k.op2(.shl, .i32, r(k.op2(.imax, .i32, r(k.op1(.iabs, .i32, r(dx))), r(k.op1(.iabs, .i32, r(dy))))), u(3))));
    // ends moved by (d, d') with d >> d' > 0: a tie on a diamond's corner
    // falls to the side of dy's sign (or -dx's on a level line)
    const tpos = k.op2(.por, .pred, r(k.cmp(.i32, .gt, r(dy), i(0))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(dy), i(0))), r(k.cmp(.i32, .lt, r(dx), i(0))))));
    st(k, b_out, base, L_TPOS, .u32, r(k.sel(.u32, r(tpos), u(1), u(0))));
    st(k, b_out, base, S_FRONT, .u32, u(1));
    // planes: v0 + (v1 - v0) * t, t = ((X, Y) - a) . d / |d|^2
    const fx = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(a.x))), f(1.0 / @as(f32, SUB)));
    const fy = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(a.y))), f(1.0 / @as(f32, SUB)));
    st(k, b_out, base, S_XY, .f32, r(fx));
    st(k, b_out, base, S_XY + 1, .f32, r(fy));
    const ddx = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(dx))), f(1.0 / @as(f32, SUB)));
    const ddy = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(dy))), f(1.0 / @as(f32, SUB)));
    const l2 = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(ddx), r(ddx))), r(k.op2(.fmul, .f32, r(ddy), r(ddy))));
    const il2 = k.div(f(1), r(k.sel(.f32, r(valid), r(l2), f(1))));
    const kx = k.op2(.fmul, .f32, r(ddx), r(il2));
    const ky = k.op2(.fmul, .f32, r(ddy), r(il2));
    const Plane = struct {
        fn emit(kk: *kir.Kernel, bo: u8, bs: V, word: u32, v0: V, v1: V, kx_: V, ky_: V) void {
            const d = kk.op2(.fsub, .f32, r(v1), r(v0));
            putPlane(kk, bo, bs, word, r(v0), r(kk.op2(.fmul, .f32, r(d), r(kx_))), r(kk.op2(.fmul, .f32, r(d), r(ky_))));
        }
    };
    Plane.emit(k, b_out, base, S_Z, a.z, b.z, kx, ky);
    Plane.emit(k, b_out, base, S_W, a.w, b.w, kx, ky);
    for (0..sh.varyings) |j| {
        const w0: u32 = @intCast(SREC + 3 * j);
        const at = memAt(b_v, @intCast(16 + 4 * j));
        if (sh.flat & (@as(u64, 1) << @intCast(j)) != 0) {
            // (the last vertex provokes)
            st(k, b_out, base, w0, .u32, r(k.load(.u32, at, r(b.base))));
            st(k, b_out, base, w0 + 1, .f32, f(0));
            st(k, b_out, base, w0 + 2, .f32, f(0));
        } else Plane.emit(k, b_out, base, w0, k.load(.f32, at, r(a.base)), k.load(.f32, at, r(b.base)), kx, ky);
    }
    for (0..sh.clips) |j| {
        const at = memAt(b_v, 4 * p.vClip(j));
        Plane.emit(k, b_out, base, p.sClip(j), k.load(.f32, at, r(a.base)), k.load(.f32, at, r(b.base)), kx, ky);
    }
    if (sh.point_coord) {
        putPlane(k, b_out, base, p.sCoord(), f(0), f(0), f(0));
        putPlane(k, b_out, base, p.sCoord() + 3, f(0), f(0), f(0));
    }
}

// ── Kernel 2b: bins ────────────────────────────────────────────────────────

const B_NTRI = 0; // every instance's triangles
const B_SSTRIDE = 1;
const B_RECT = 2; // x0, y0 (the first bin's corner)
const B_BINS_X = 4;
const B_BASE = 5; // the bins' first word in the triangle buffer
const B_CAP = 6;
pub const BIN_PARAMS = 7;

/// A group per bin (BIN x BIN pixels from the draw's corner): the
/// triangles whose boxes meet it, in order, CULL at a time. A bin's words
/// in the triangle buffer: how many (more than its cap: the list ran
/// over), then the list.
///   binding: 0 the triangle records, then the bins (written)
/// The same for every pipeline (records are laid out alike).
pub fn binKernel(s: kir.Storage) kir.Kernel {
    var k = kir.Kernel.init(s, "gl_bin", .{ CULL, 1, 1 });
    const b_t = k.binding();
    const t = k.tid(0);
    const ntri = k.param(.u32, B_NTRI);
    const sstride = k.param(.u32, B_SSTRIDE);
    const cap = k.param(.u32, B_CAP);
    const x0 = k.op3(.imad, .i32, r(k.gid(0)), u(BIN), r(k.param(.i32, B_RECT)));
    const y0 = k.op3(.imad, .i32, r(k.gid(1)), u(BIN), r(k.param(.i32, B_RECT + 1)));
    const x1 = k.op2(.iadd, .i32, r(x0), i(BIN - 1));
    const y1 = k.op2(.iadd, .i32, r(y0), i(BIN - 1));
    const bin = k.op3(.imad, .u32, r(k.gid(1)), r(k.param(.u32, B_BINS_X)), r(k.gid(0)));
    const bbase = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(bin), r(k.op2(.iadd, .u32, r(cap), u(1))), r(k.param(.u32, B_BASE)))), u(2));
    const sc = scanAlloc(&k);
    const count = k.reg(.u32);
    k.set(count, .mov, u(0), no, no);
    const chunk = k.reg(.u32);
    k.set(chunk, .mov, u(0), no, no);
    const last = k.op2(.isub, .u32, r(ntri), u(1));
    k.loop();
    {
        k.brk(r(k.cmp(.u32, .ge, r(chunk), r(ntri))));
        const j = k.op2(.iadd, .u32, r(chunk), r(t));
        k.set(chunk, .iadd, r(chunk), u(CULL), no);
        // (past the end: the last triangle read, and not kept)
        const jj = k.op2(.imin, .u32, r(j), r(last));
        const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(jj), r(sstride))), u(2));
        const in = k.cmp(.u32, .lt, r(j), r(ntri));
        const hit = k.op2(.pand, .pred, r(in), r(meets(&k, b_t, base, x0, y0, x1, y1)));
        const c = compact(&k, sc, t, hit);
        const at = k.op2(.iadd, .u32, r(count), r(c.pos));
        k.ifp(r(k.op2(.pand, .pred, r(hit), r(k.cmp(.u32, .lt, r(at), r(cap))))));
        k.store(.u32, memAt(b_t, 4), r(k.op3(.imad, .u32, r(at), u(4), r(bbase))), r(j));
        k.endif();
        k.set(count, .iadd, r(count), r(c.total), no);
    }
    k.endloop();
    k.ifp(r(k.cmp(.u32, .eq, r(t), u(0))));
    k.store(.u32, memAt(b_t, 0), r(bbase), r(count));
    k.endif();
    return k;
}

/// How a draw's triangles are binned: none when the draw's rectangle is
/// one bin (its tiles go through every triangle).
pub const Bins = struct {
    on: bool = false,
    x: u32 = 1,
    y: u32 = 1,
    /// the first bin's word in the triangle buffer, and a bin's list's room
    base: u32 = 0,
    cap: u32 = 0,

    /// Words the bins take after the triangle records.
    pub fn words(b: Bins) usize {
        return if (b.on) @as(usize, b.x) * b.y * (b.cap + 1) else 0;
    }
};

pub fn binsOf(d: *const Draw, cap_limit: u32) Bins {
    const w = d.rect.width();
    const h = d.rect.height();
    if (w <= BIN and h <= BIN) return .{};
    const ntri = d.records() * d.instances;
    return .{
        .on = true,
        .x = (w + BIN - 1) / BIN,
        .y = (h + BIN - 1) / BIN,
        .base = ntri * d.pipe.sstride,
        .cap = @min(ntri, cap_limit),
    };
}

pub fn binParams(d: *const Draw, b: Bins, out: []u32) []u32 {
    const p = [_]u32{ d.records() * d.instances, d.pipe.sstride, d.rect.x0, d.rect.y0, b.x, b.base, b.cap };
    @memcpy(out[0..p.len], &p);
    return out[0..p.len];
}

// ── Kernel 3: tiles ────────────────────────────────────────────────────────

const R_RECT = 0; // x0, y0, x1, y1 (exclusive)
const R_NTRI = 4;
const R_SSTRIDE = 5;
const R_C_STRIDE = 6; // the color image: bytes a row, top-down, height
const R_C_TOPDOWN = 7;
const R_C_HEIGHT = 8;
const R_SHIFT_R = 9; // byte shifts of red and blue (bgra8: 16, 0; else 0, 16)
const R_SHIFT_B = 10;
const R_KEEP = 11;
const R_NO_ALPHA = 12;
const R_DEPTH = 13; // depth test on (a depth image bound)
const R_DFUNC = 14;
const R_DWRITE = 15;
const R_D_STRIDE = 16;
const R_D_TOPDOWN = 17;
const R_D_HEIGHT = 18;
const R_ZMIN = 19;
const R_ZMAX = 20;
const R_BLEND = 21;
const R_EQ_RGB = 22;
const R_EQ_A = 23;
const R_SATURATE = 24;
const R_SRC_RGB = 25; // c (3), ks, kd, ksa, kda
const R_DST_RGB = 32;
const R_SRC_A = 39; // c, ks, kd, ksa, kda
const R_DST_A = 44;
const R_BINNED = 49; // the triangles binned: bins a row, their first word, cap
const R_BINS_X = 50;
const R_BIN_BASE = 51;
const R_BIN_CAP = 52;
const R_BPP = 53; // the color image's bytes a pixel: 4 (RGBA8, BGRA8), 2 (RG8), 1 (R8)
const R_STENCIL = 54;
const R_S_STRIDE = 55;
const R_S_TOPDOWN = 56;
const R_S_HEIGHT = 57;
const R_DS_SHARED = 58;
const R_S_FRONT = 59;
const R_S_BACK = 66;
const R_QUERY = 73; // an occlusion query on: a pixel written sets its word
const R_SAMPLE_MASK = 74; // multisampled: the samples drawn, alpha to coverage on
const R_A2C = 75;
/// targets 1 .. MAX_TARGETS - 1: each target 0's words (TF) in turn
const R_TGT = 76;
const TGT_WORDS = 9;
pub const RASTER_PARAMS = R_TGT + (MAX_TARGETS - 1) * TGT_WORDS;

/// A colour target's words.
const TF = enum(u8) { stride, topdown, height, bpp, shift_r, shift_b, keep, no_alpha, blend };

fn tw(t: usize, fld: TF) u16 {
    if (t == 0) return switch (fld) {
        .stride => R_C_STRIDE,
        .topdown => R_C_TOPDOWN,
        .height => R_C_HEIGHT,
        .bpp => R_BPP,
        .shift_r => R_SHIFT_R,
        .shift_b => R_SHIFT_B,
        .keep => R_KEEP,
        .no_alpha => R_NO_ALPHA,
        .blend => R_BLEND,
    };
    return @intCast(R_TGT + (t - 1) * TGT_WORDS + @intFromEnum(fld));
}

/// bindings: 0 color (written), 1 depth (written when on), 2 triangle
/// records, 3 uniforms, then the textures, the buffers (Shaders.buffers),
/// an occlusion query's word, the stencil image (Variant.stencil), and
/// targets 1.. (Variant.targets' bits)
pub fn rasterKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    return rasterKernelFor(s, p, .{});
}

pub fn stencilKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    return rasterKernelFor(s, p, .{ .stencil = true });
}

fn rowOf(k: *kir.Kernel, y: V, td: u16, h: u16) V {
    const flipped = k.op2(.isub, .i32, r(k.op2(.isub, .i32, r(k.param(.i32, h)), i(1))), r(y));
    return k.sel(.i32, r(k.cmp(.u32, .ne, r(k.param(.u32, td)), u(0))), r(flipped), r(y));
}

/// A colour word's channel as 0..1.
fn chan(k: *kir.Kernel, word: V, sh_: Arg) V {
    const byte = k.op3(.bfe, .u32, r(word), sh_, u(8));
    return k.div(r(k.cvt(.u32, .f32, .rne, r(byte))), f(255));
}

fn packChan(k: *kir.Kernel, c: V, sh_: Arg) V {
    const b = k.cvt(.f32, .u32, .rne, r(k.op2(.fmul, .f32, r(c), f(255))));
    return k.op2(.shl, .u32, r(b), sh_);
}

/// A target's pixel word as four floats (missing channels 0, alpha 1).
fn unpack(k: *kir.Kernel, word: V, t: usize) [4]V {
    return .{
        chan(k, word, r(k.param(.u32, tw(t, .shift_r)))),
        chan(k, word, u(8)),
        chan(k, word, r(k.param(.u32, tw(t, .shift_b)))),
        k.sel(.f32, r(k.cmp(.u32, .ne, r(k.param(.u32, tw(t, .no_alpha))), u(0))), f(1), r(chan(k, word, u(24)))),
    };
}

fn pack(k: *kir.Kernel, c: [4]V, t: usize) V {
    var word = k.op2(.@"or", .u32, r(packChan(k, c[0], r(k.param(.u32, tw(t, .shift_r))))), r(packChan(k, c[1], u(8))));
    word = k.op2(.@"or", .u32, r(word), r(packChan(k, c[2], r(k.param(.u32, tw(t, .shift_b))))));
    return k.op2(.@"or", .u32, r(word), r(packChan(k, c[3], u(24))));
}

/// The kept bits of `old`, the rest of `word` (the colour mask).
fn merge(k: *kir.Kernel, old: V, word: V, t: usize) V {
    const keep = k.param(.u32, tw(t, .keep));
    return k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old), r(keep))), r(k.op2(.@"and", .u32, r(word), r(k.op1(.not, .u32, r(keep))))));
}

/// A target's pixel (or sample) loaded at its width (4, 2 or 1 bytes).
fn loadPixel(k: *kir.Kernel, dst: V, b: u8, off: V, wide: V, pair: V) void {
    k.ifp(r(wide));
    k.setAux(dst, .ld, r(off), no, no, @bitCast(kir.global(b, 32)));
    k.els();
    k.ifp(r(pair));
    k.setAux(dst, .ld, r(off), no, no, @bitCast(kir.global(b, 16)));
    k.els();
    k.setAux(dst, .ld, r(off), no, no, @bitCast(kir.global(b, 8)));
    k.endif();
    k.endif();
}

fn storePixel(k: *kir.Kernel, b: u8, off: V, val: V, wide: V, pair: V) void {
    k.ifp(r(wide));
    k.store(.u32, kir.global(b, 32), r(off), r(val));
    k.els();
    k.ifp(r(pair));
    k.store(.u32, kir.global(b, 16), r(off), r(val));
    k.els();
    k.store(.u32, kir.global(b, 8), r(off), r(val));
    k.endif();
    k.endif();
}

fn bitOn(k: *kir.Kernel, w: V, bit: u32) V {
    return k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(w), u(bit))), u(0));
}

/// A depth (0..1, clamped) as the 24-bit value stored.
fn depthWord(k: *kir.Kernel, z: V) V {
    return k.cvt(.f32, .u32, .rne, r(k.op2(.fmul, .f32, r(k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(z), f(0))), f(1))), f(16777215.0))));
}

/// The depth test of dz against `depth` (R_DFUNC); passes where the test
/// is off.
fn depthPass(k: *kir.Kernel, d_on: V, dz: V, depth: V) V {
    const func = k.param(.u32, R_DFUNC);
    const lt = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(dz), r(depth))), r(bitOn(k, func, 1)));
    const eq = k.op2(.pand, .pred, r(k.cmp(.u32, .eq, r(dz), r(depth))), r(bitOn(k, func, 2)));
    const gt = k.op2(.pand, .pred, r(k.cmp(.u32, .gt, r(dz), r(depth))), r(bitOn(k, func, 4)));
    return k.sel(.pred, r(d_on), r(k.op2(.por, .pred, r(k.op2(.por, .pred, r(lt), r(eq))), r(gt))), u(1));
}

/// The stencil test of `stencil` for the face (passes where off).
fn stencilPass(k: *kir.Kernel, s_on: V, front: V, stencil: V) V {
    var sp: [3]V = undefined;
    for (&sp, 0..) |*param, index| {
        param.* = k.sel(.u32, r(front), r(k.param(.u32, @intCast(R_S_FRONT + index))), r(k.param(.u32, @intCast(R_S_BACK + index))));
    }
    const ref_masked = k.op2(.@"and", .u32, r(sp[1]), r(sp[2]));
    const stencil_masked = k.op2(.@"and", .u32, r(stencil), r(sp[2]));
    const slt = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(ref_masked), r(stencil_masked))), r(bitOn(k, sp[0], 1)));
    const seq = k.op2(.pand, .pred, r(k.cmp(.u32, .eq, r(ref_masked), r(stencil_masked))), r(bitOn(k, sp[0], 2)));
    const sgt = k.op2(.pand, .pred, r(k.cmp(.u32, .gt, r(ref_masked), r(stencil_masked))), r(bitOn(k, sp[0], 4)));
    return k.sel(.pred, r(s_on), r(k.op2(.por, .pred, r(k.op2(.por, .pred, r(slt), r(seq))), r(sgt))), u(1));
}

/// The face's stencil operation (fail, depth fail or pass) on `stencil`,
/// under its write mask.
fn stencilUpdate(k: *kir.Kernel, front: V, spass: V, dpass: V, stencil: V) void {
    var update: [5]V = undefined;
    for (&update, 0..) |*param, index| {
        const field: usize = if (index == 0) 1 else index + 2;
        param.* = k.sel(.u32, r(front), r(k.param(.u32, @intCast(R_S_FRONT + field))), r(k.param(.u32, @intCast(R_S_BACK + field))));
    }
    const op = k.sel(.u32, r(spass), r(k.sel(.u32, r(dpass), r(update[4]), r(update[3]))), r(update[2]));
    const result = stencilOp(k, op, stencil, update[0]);
    const mask = update[1];
    k.set(stencil, .@"or", r(k.op2(.@"and", .u32, r(result), r(mask))), r(k.op2(.@"and", .u32, r(stencil), r(k.op1(.not, .u32, r(mask))))), no);
}

/// A primitive record's plane at (dx, dy) from its first corner.
fn plane(k: *kir.Kernel, b: u8, bs: V, word: u32, dx: V, dy: V) V {
    const a0 = k.load(.f32, memAt(b, word * 4), r(bs));
    const gx = k.load(.f32, memAt(b, (word + 1) * 4), r(bs));
    const gy = k.load(.f32, memAt(b, (word + 2) * 4), r(bs));
    return k.op2(.fadd, .f32, r(k.op2(.fadd, .f32, r(a0), r(k.op2(.fmul, .f32, r(gx), r(dx))))), r(k.op2(.fmul, .f32, r(gy), r(dy))));
}

fn ld(k: *kir.Kernel, b: u8, bs: V, word: u32, ty: kir.Ty) V {
    return k.load(ty, memAt(b, word * 4), r(bs));
}

/// A tile kernel (a group per TILE x TILE pixels, a thread per pixel) for
/// variant `v`:
/// - single-sampled: each target's pixel kept in floats through the
///   primitives (blending in floats), the depth and stencil in integers,
///   stored once;
/// - multisampled: each sample's coverage from the edges at its place
///   (sample_pos), the fragment code once a pixel (at its center), then
///   for each covered sample its own depth (the depth plane at the
///   sample), depth and stencil tests, and blending into the sample (its
///   word kept packed, as the image holds it); alpha to coverage and the
///   sample mask;
/// - lines: GL's and Vulkan's diamond-exit rule, exact in integers (the
///   ends nudged by an infinitesimal (d, d'), d >> d' > 0, so a tie on a
///   diamond's corner falls one way);
/// - colour targets: output i into target i, each with its format, colour
///   mask and blending on or off;
/// - gl_FragDepth: the tests after the fragment code; clip distances: a
///   sample whose distance plane is below 0 at the pixel's center is out.
pub fn rasterKernelFor(s: kir.Storage, p: *const Pipeline, v: Variant) kir.Kernel {
    const S: u32 = v.samples;
    const ms = S > 1;
    std.debug.assert(S == 1 or S == 2 or S == 4 or S == 8);
    std.debug.assert(!(ms and v.lines));
    const spos = samplePositions(S);
    const stencil_enabled = v.stencil;
    const late = p.shaders.frag_depth;
    var k = kir.Kernel.init(s, v.name(), .{ TILE, TILE, 1 });
    const b_c = k.binding();
    const b_d = k.binding();
    const b_t = k.binding();
    const b_uni = k.binding();
    const sh = p.shaders;
    const b_tex = k.bindings;
    for (0..sh.textures) |_| _ = k.binding();
    const b_buf = k.bindings;
    for (0..sh.buffers) |_| _ = k.binding();
    const b_q = k.binding();
    const b_s = if (stencil_enabled) k.binding() else 0;
    var tb: [MAX_TARGETS]u8 = @splat(0);
    var on: [MAX_TARGETS]bool = @splat(false);
    tb[0] = b_c;
    on[0] = v.targets & 1 != 0;
    for (1..MAX_TARGETS) |tt| {
        if (v.targets >> @intCast(tt) & 1 == 0) continue;
        on[tt] = true;
        tb[tt] = k.binding();
    }
    const lx = k.tid(0);
    const ly = k.tid(1);
    const odd_x: V = if (sh.quads) k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(lx), u(1))), u(0)) else .none;
    const odd_y: V = if (sh.quads) k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(ly), u(1))), u(0)) else .none;
    const tx0 = k.op3(.imad, .i32, r(k.gid(0)), u(TILE), r(k.param(.i32, R_RECT)));
    const ty0 = k.op3(.imad, .i32, r(k.gid(1)), u(TILE), r(k.param(.i32, R_RECT + 1)));
    const px = k.op2(.iadd, .i32, r(tx0), r(lx));
    const py = k.op2(.iadd, .i32, r(ty0), r(ly));
    const inside = k.op2(.pand, .pred, r(k.cmp(.i32, .lt, r(px), r(k.param(.i32, R_RECT + 2)))), r(k.cmp(.i32, .lt, r(py), r(k.param(.i32, R_RECT + 3)))));
    // (a pixel's samples side by side: sample s of pixel x at x * S + s)
    const pxs = if (ms) k.op2(.imul, .u32, r(px), u(S)) else px;
    // each target's pixel: its place, its width (a pixel of 4, 2 or 1
    // bytes: R8 and RG8 too, their channels from byte 0 as RGBA8's; what
    // they lack reads 0, alpha 1)
    var c_off: [MAX_TARGETS]V = @splat(.none);
    var wide: [MAX_TARGETS]V = @splat(.none);
    var pair: [MAX_TARGETS]V = @splat(.none);
    var bpp: [MAX_TARGETS]V = @splat(.none);
    for (0..MAX_TARGETS) |tt| {
        if (!on[tt]) continue;
        bpp[tt] = k.param(.u32, tw(tt, .bpp));
        wide[tt] = k.cmp(.u32, .eq, r(bpp[tt]), u(4));
        pair[tt] = k.cmp(.u32, .eq, r(bpp[tt]), u(2));
        c_off[tt] = k.op3(.imad, .u32, r(rowOf(&k, py, tw(tt, .topdown), tw(tt, .height))), r(k.param(.u32, tw(tt, .stride))), r(k.op2(.imul, .u32, r(pxs), r(bpp[tt]))));
    }
    const d_on = k.cmp(.u32, .ne, r(k.param(.u32, R_DEPTH)), u(0));
    const d_off = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(rowOf(&k, py, R_D_TOPDOWN, R_D_HEIGHT)), r(k.param(.u32, R_D_STRIDE)), r(pxs))), u(2));
    const s_on = if (stencil_enabled) k.cmp(.u32, .ne, r(k.param(.u32, R_STENCIL)), u(0)) else .none;
    const s_off = if (stencil_enabled) k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(rowOf(&k, py, R_S_TOPDOWN, R_S_HEIGHT)), r(k.param(.u32, R_S_STRIDE)), r(pxs))), u(2)) else .none;
    const shared_ds = if (stencil_enabled) k.cmp(.u32, .ne, r(k.param(.u32, R_DS_SHARED)), u(0)) else .none;
    // Multisampled, the samples' words live in shared memory (each
    // thread its own): a slot a target, the depth word, the stencil word,
    // each sample's depth (f32); slot j's sample s of lane l at
    // ms_base + (j * S + s) * 256 + 4 l. Registers stay those of one
    // pixel whatever the samples and targets.
    const lane4 = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(ly), u(TILE), r(lx))), u(2));
    const SLOT = S * CULL * 4;
    var cslot: [MAX_TARGETS]u32 = @splat(0);
    var nslot: u32 = 0;
    for (0..MAX_TARGETS) |tt| {
        if (!on[tt]) continue;
        cslot[tt] = nslot;
        nslot += 1;
    }
    const dslot = nslot;
    const sslot = nslot + 1;
    const zslot = nslot + 2;
    const ms_base: u32 = if (ms) k.sharedAlloc((nslot + 3) * SLOT, 4) else 0;
    const sOff = struct {
        fn f_(base: u32, slot_bytes: u32, slot: u32, sm: u32) kir.Mem {
            return shAt(base + slot * slot_bytes + sm * CULL * 4);
        }
    }.f_;
    // the pixels (or samples) and their depth and stencil, loaded once
    var old_c: [MAX_TARGETS]V = @splat(.none);
    var old_d: V = .none;
    var old_s: V = .none;
    if (!ms) {
        for (0..MAX_TARGETS) |tt| {
            if (!on[tt]) continue;
            old_c[tt] = k.reg(.u32);
            k.set(old_c[tt], .mov, u(0), no, no);
        }
        old_d = k.reg(.u32);
        k.set(old_d, .mov, u(0), no, no);
        if (stencil_enabled) {
            old_s = k.reg(.u32);
            k.set(old_s, .mov, u(0), no, no);
        }
    }
    k.ifp(r(inside));
    if (!ms) {
        for (0..MAX_TARGETS) |tt| {
            if (on[tt]) loadPixel(&k, old_c[tt], tb[tt], c_off[tt], wide[tt], pair[tt]);
        }
        k.ifp(r(d_on));
        k.setAux(old_d, .ld, r(d_off), no, no, @bitCast(kir.global(b_d, 32)));
        k.endif();
        if (stencil_enabled) {
            k.ifp(r(s_on));
            k.setAux(old_s, .ld, r(s_off), no, no, @bitCast(kir.global(b_s, 32)));
            k.endif();
        }
    } else {
        // each target's samples into its slot (a loop: one load's code
        // whatever the samples)
        const tmp = k.reg(.u32);
        for (0..MAX_TARGETS) |tt| {
            if (!on[tt]) continue;
            const goff = k.reg(.u32);
            k.set(goff, .mov, r(c_off[tt]), no, no);
            const sa = k.reg(.u32);
            k.set(sa, .mov, r(lane4), no, no);
            const si = k.reg(.u32);
            k.set(si, .mov, u(0), no, no);
            k.loop();
            {
                k.brk(r(k.cmp(.u32, .ge, r(si), u(S))));
                loadPixel(&k, tmp, tb[tt], goff, wide[tt], pair[tt]);
                k.store(.u32, sOff(ms_base, SLOT, cslot[tt], 0), r(sa), r(tmp));
                k.set(goff, .iadd, r(goff), r(bpp[tt]), no);
                k.set(sa, .iadd, r(sa), u(CULL * 4), no);
                k.set(si, .iadd, r(si), u(1), no);
            }
            k.endloop();
        }
        for (0..S) |sm| {
            const smu: u32 = @intCast(sm);
            k.set(tmp, .mov, u(0), no, no);
            k.ifp(r(d_on));
            k.setAux(tmp, .ld, r(d_off), no, no, @bitCast(memAt(b_d, 4 * smu)));
            k.endif();
            k.store(.u32, sOff(ms_base, SLOT, dslot, smu), r(lane4), r(tmp));
            if (stencil_enabled) {
                k.set(tmp, .mov, u(0), no, no);
                k.ifp(r(s_on));
                k.setAux(tmp, .ld, r(s_off), no, no, @bitCast(memAt(b_s, 4 * smu)));
                k.endif();
                k.store(.u32, sOff(ms_base, SLOT, sslot, smu), r(lane4), r(tmp));
            }
        }
    }
    k.endif();
    // single-sampled: each target's pixel in floats, the depth (24 bits)
    // and stencil (8) in integers
    var dst: [MAX_TARGETS][4]V = undefined;
    var depth: V = .none;
    var stencil: V = .none;
    if (!ms) {
        for (0..MAX_TARGETS) |tt| {
            if (!on[tt]) continue;
            for (&dst[tt]) |*d| d.* = k.reg(.f32);
            const val = unpack(&k, old_c[tt], tt);
            for (0..4) |c| k.set(dst[tt][c], .mov, r(val[c]), no, no);
        }
        depth = k.reg(.u32);
        k.set(depth, .@"and", r(old_d), u(0x00ff_ffff), no);
        if (stencil_enabled) {
            stencil = k.reg(.u32);
            k.set(stencil, .shr, r(old_s), u(24), no);
        }
    }
    // bit 0: a sample passed (colour, depth), bit 1: stencil written
    const touched = k.reg(.u32);
    k.set(touched, .mov, u(0), no, no);
    const ntri = k.param(.u32, R_NTRI);
    const sstride = k.param(.u32, R_SSTRIDE);
    const lx16 = k.op2(.shl, .i32, r(lx), u(4));
    const ly16 = k.op2(.shl, .i32, r(ly), u(4));
    // the tile's first pixel center, in 1/16 pixel
    const tcx = k.op2(.iadd, .i32, r(k.op2(.shl, .i32, r(tx0), u(4))), i(SUB / 2));
    const tcy = k.op2(.iadd, .i32, r(k.op2(.shl, .i32, r(ty0), u(4))), i(SUB / 2));
    const tx1 = k.op2(.iadd, .i32, r(tx0), i(TILE - 1));
    const ty1 = k.op2(.iadd, .i32, r(ty0), i(TILE - 1));
    // The triangles that may reach the tile: its bin's list, or every
    // triangle (unbinned, or the bin's list ran over), CULL at a time:
    // each thread tests one triangle's box against the tile, the hits are
    // compacted in order into shared memory, and the group goes through
    // them (GL's order kept: blending is right).
    const t = k.op3(.imad, .u32, r(ly), u(TILE), r(lx));
    const sc = scanAlloc(&k);
    const list = k.sharedAlloc(CULL * 4, 4);
    const cap = k.param(.u32, R_BIN_CAP);
    const bin = k.op3(.imad, .u32, r(k.op2(.shr, .u32, r(k.gid(1)), u(BIN_SHIFT))), r(k.param(.u32, R_BINS_X)), r(k.op2(.shr, .u32, r(k.gid(0)), u(BIN_SHIFT))));
    const bbase = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(bin), r(k.op2(.iadd, .u32, r(cap), u(1))), r(k.param(.u32, R_BIN_BASE)))), u(2));
    const n = k.reg(.u32);
    k.set(n, .mov, r(ntri), no, no);
    const listed = k.reg(.pred);
    k.set(listed, .mov, u(0), no, no);
    k.ifp(r(k.cmp(.u32, .ne, r(k.param(.u32, R_BINNED)), u(0))));
    {
        const cnt = k.load(.u32, kir.global(b_t, 32), r(bbase));
        const fits = k.cmp(.u32, .le, r(cnt), r(cap));
        k.set(listed, .mov, r(fits), no, no);
        k.set(n, .sel, r(cnt), r(ntri), r(fits));
    }
    k.endif();
    const chunk = k.reg(.u32);
    k.set(chunk, .mov, u(0), no, no);
    k.loop();
    {
        k.brk(r(k.cmp(.u32, .ge, r(chunk), r(n))));
        const jt = k.op2(.iadd, .u32, r(chunk), r(t));
        k.set(chunk, .iadd, r(chunk), u(CULL), no);
        // (past the end: the last one read, and not kept; unlisted: the
        // list's address is the first record's, a word always there)
        const jj = k.op2(.imin, .u32, r(jt), r(k.op2(.isub, .u32, r(n), u(1))));
        const lat = k.sel(.u32, r(listed), r(k.op3(.imad, .u32, r(jj), u(4), r(bbase))), u(0));
        const entry = k.load(.u32, memAt(b_t, 4), r(lat));
        const tj = k.sel(.u32, r(listed), r(entry), r(jj));
        const jbase = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(tj), r(sstride))), u(2));
        const hit = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(jt), r(n))), r(meets(&k, b_t, jbase, tx0, ty0, tx1, ty1)));
        const cut = compact(&k, sc, t, hit);
        k.ifp(r(hit));
        k.store(.u32, shAt(list), r(k.op2(.shl, .u32, r(cut.pos), u(2))), r(tj));
        k.endif();
        k.barrier();
        const ix = k.reg(.u32);
        k.set(ix, .mov, u(0), no, no);
        k.loop();
        {
            k.brk(r(k.cmp(.u32, .ge, r(ix), r(cut.total))));
            const tc = k.load(.u32, shAt(list), r(k.op2(.shl, .u32, r(ix), u(2))));
            k.set(ix, .iadd, r(ix), u(1), no);
            const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(tc), r(sstride))), u(2));
            // coverage: single-sampled, `covered`; multisampled, `cmask`
            // (bit s: sample s covered)
            var covered = inside;
            var cmask: V = .none;
            var out_tile = k.mov(.pred, u(0));
            if (v.lines) {
                const cov = lineCover(&k, b_t, base, tcx, tcy, lx16, ly16, px, py);
                covered = k.op2(.pand, .pred, r(covered), r(cov.covered));
                out_tile = cov.out_tile;
            } else {
                // each edge's value at the tile's first center in 64 bits;
                // a tile wholly outside one edge, the next triangle; else
                // clamped, and each pixel's in 32 bits (each sample's: the
                // pixel's and a constant)
                var scov: [MAX_SAMPLES]V = @splat(inside);
                for (0..3) |e| {
                    const w0: u32 = @intCast(S_EDGE + 5 * e);
                    const A = ld(&k, b_t, base, w0, .i32);
                    const B = ld(&k, b_t, base, w0 + 1, .i32);
                    const ax = ld(&k, b_t, base, w0 + 2, .i32);
                    const ay = ld(&k, b_t, base, w0 + 3, .i32);
                    const bias = ld(&k, b_t, base, w0 + 4, .i32);
                    const c64 = add64(&k, mul64(&k, r(A), r(k.op2(.isub, .i32, r(tcx), r(ax)))), mul64(&k, r(B), r(k.op2(.isub, .i32, r(tcy), r(ay)))));
                    const above = k.op2(.por, .pred, r(k.cmp(.i32, .gt, r(c64.hi), i(0))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(c64.hi), i(0))), r(k.cmp(.u32, .gt, r(c64.lo), u(LIMIT))))));
                    const below = k.op2(.por, .pred, r(k.cmp(.i32, .lt, r(c64.hi), i(-1))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(c64.hi), i(-1))), r(k.cmp(.u32, .lt, r(c64.lo), u(@as(u32, 0) -% LIMIT))))));
                    out_tile = k.op2(.por, .pred, r(out_tile), r(below));
                    const c32 = k.sel(.i32, r(above), u(LIMIT), r(c64.lo));
                    const ev = k.op2(.iadd, .i32, r(k.op2(.iadd, .i32, r(c32), r(k.op2(.imul, .i32, r(A), r(lx16))))), r(k.op2(.imul, .i32, r(B), r(ly16))));
                    if (!ms) {
                        covered = k.op2(.pand, .pred, r(covered), r(k.cmp(.i32, .ge, r(k.op2(.iadd, .i32, r(ev), r(bias))), i(0))));
                    } else {
                        const eb = k.op2(.iadd, .i32, r(ev), r(bias));
                        for (0..S) |sm| {
                            const ox: i32 = @as(i32, spos[sm][0]) - SUB / 2;
                            const oy: i32 = @as(i32, spos[sm][1]) - SUB / 2;
                            const at = k.op2(.iadd, .i32, r(k.op2(.iadd, .i32, r(eb), r(k.op2(.imul, .i32, r(A), i(ox))))), r(k.op2(.imul, .i32, r(B), i(oy))));
                            scov[sm] = k.op2(.pand, .pred, r(scov[sm]), r(k.cmp(.i32, .ge, r(at), i(0))));
                        }
                    }
                }
                if (ms) {
                    cmask = k.mov(.u32, u(0));
                    for (0..S) |sm| cmask = k.op2(.@"or", .u32, r(cmask), r(k.sel(.u32, r(scov[sm]), u(@as(u32, 1) << @intCast(sm)), u(0))));
                    covered = k.cmp(.u32, .ne, r(cmask), u(0));
                }
            }
            k.cont(r(out_tile));
            // (quads: every lane computes, and a quad with a pixel to draw
            // runs the fragment code whole; else covered pixels alone)
            if (!sh.quads) k.ifp(r(covered));
            {
                const X = k.op2(.fadd, .f32, r(k.cvt(.i32, .f32, .rne, r(px))), f(0.5));
                const Y = k.op2(.fadd, .f32, r(k.cvt(.i32, .f32, .rne, r(py))), f(0.5));
                const dX = k.op2(.fsub, .f32, r(X), r(ld(&k, b_t, base, S_XY, .f32)));
                const dY = k.op2(.fsub, .f32, r(Y), r(ld(&k, b_t, base, S_XY + 1, .f32)));
                const z = plane(&k, b_t, base, S_Z, dX, dY);
                // clip distances: below 0 at the center, out
                var clip_ok: V = .none;
                for (0..sh.clips) |j| {
                    const cd = k.cmp(.f32, .ge, r(plane(&k, b_t, base, p.sClip(j), dX, dY)), f(0));
                    clip_ok = if (clip_ok == .none) cd else k.op2(.pand, .pred, r(clip_ok), r(cd));
                }
                const front = k.cmp(.u32, .ne, r(ld(&k, b_t, base, S_FRONT, .u32)), u(0));
                const frag = Frag{ .k = &k, .p = p, .b_t = b_t, .base = base, .b_uni = b_uni, .b_tex = b_tex, .b_buf = b_buf, .odd_x = odd_x, .odd_y = odd_y, .X = X, .Y = Y, .dX = dX, .dY = dY, .z = z, .front = front };
                if (!ms) {
                    // (outside the depth range: clipped)
                    var zin = k.op2(.pand, .pred, r(k.cmp(.f32, .ge, r(z), r(k.param(.f32, R_ZMIN)))), r(k.cmp(.f32, .le, r(z), r(k.param(.f32, R_ZMAX)))));
                    if (clip_ok != .none) zin = k.op2(.pand, .pred, r(zin), r(clip_ok));
                    var pass = zin;
                    const clipped = if (stencil_enabled or late) k.op2(.pand, .pred, r(pass), r(covered)) else .none;
                    var dz: V = .none;
                    var dpass: V = .none;
                    var spass: V = .none;
                    if (!late) {
                        dz = depthWord(&k, z);
                        dpass = depthPass(&k, d_on, dz, depth);
                        pass = k.op2(.pand, .pred, r(pass), r(dpass));
                        if (stencil_enabled) {
                            spass = stencilPass(&k, s_on, front, stencil);
                            pass = k.op2(.pand, .pred, r(pass), r(spass));
                        }
                        if (sh.quads) pass = k.op2(.pand, .pred, r(pass), r(covered));
                    }
                    // Stencil fail operations still depend on fragment discard.
                    // Evaluate covered fragments even when their tests fail.
                    const shade = if (late) clipped else if (stencil_enabled) k.sel(.pred, r(s_on), r(clipped), r(pass)) else pass;
                    k.ifp(r(if (sh.quads) quadAny(&k, shade) else shade));
                    {
                        var io = frag.run();
                        var live = if (io.discard == .none) k.mov(.pred, u(1)) else k.op1(.pnot, .pred, r(io.discard));
                        if (stencil_enabled or late) {
                            live = k.op2(.pand, .pred, r(live), r(clipped));
                        } else if (sh.quads) live = k.op2(.pand, .pred, r(live), r(pass));
                        k.ifp(r(live));
                        {
                            if (late) {
                                // gl_FragDepth: the tests now
                                dz = depthWord(&k, if (io.depth == .none) z else io.depth);
                                dpass = depthPass(&k, d_on, dz, depth);
                                pass = dpass;
                                if (stencil_enabled) {
                                    spass = stencilPass(&k, s_on, front, stencil);
                                    pass = k.op2(.pand, .pred, r(pass), r(spass));
                                }
                            }
                            if (stencil_enabled) {
                                k.ifp(r(s_on));
                                stencilUpdate(&k, front, spass, dpass, stencil);
                                k.set(touched, .@"or", r(touched), u(2), no);
                                k.endif();
                            }
                            if (stencil_enabled or late) k.ifp(r(pass));
                            for (0..MAX_TARGETS) |tt| {
                                if (!on[tt]) continue;
                                const src = clamped(&k, outputOf(&io, tt));
                                const out = blend(&k, src, dst[tt], k.cmp(.u32, .ne, r(k.param(.u32, tw(tt, .blend))), u(0)));
                                for (0..4) |c| k.set(dst[tt][c], .mov, r(out[c]), no, no);
                            }
                            k.set(touched, .@"or", r(touched), u(1), no);
                            k.ifp(r(k.op2(.pand, .pred, r(d_on), r(k.cmp(.u32, .ne, r(k.param(.u32, R_DWRITE)), u(0))))));
                            k.set(depth, .mov, r(dz), no, no);
                            k.endif();
                            if (stencil_enabled or late) k.endif();
                        }
                        k.endif();
                    }
                    k.endif();
                } else {
                    // multisampled: each sample's depth on the plane at its
                    // place (kept in its slot), tested early for the shade
                    const gzx = ld(&k, b_t, base, S_Z + 1, .f32);
                    const gzy = ld(&k, b_t, base, S_Z + 2, .f32);
                    const zmin = k.param(.f32, R_ZMIN);
                    const zmax = k.param(.f32, R_ZMAX);
                    var shade = k.mov(.pred, u(0));
                    for (0..S) |sm| {
                        const smu: u32 = @intCast(sm);
                        const ox: f32 = (@as(f32, @floatFromInt(spos[sm][0])) - SUB / 2) / SUB;
                        const oy: f32 = (@as(f32, @floatFromInt(spos[sm][1])) - SUB / 2) / SUB;
                        const zs = k.op2(.fadd, .f32, r(k.op2(.fadd, .f32, r(z), r(k.op2(.fmul, .f32, r(gzx), f(ox))))), r(k.op2(.fmul, .f32, r(gzy), f(oy))));
                        k.store(.f32, sOff(ms_base, SLOT, zslot, smu), r(lane4), r(zs));
                        var ok = k.op2(.pand, .pred, r(bitOn(&k, cmask, @as(u32, 1) << @intCast(sm))), r(zRange(&k, zs, zmin, zmax, clip_ok)));
                        if (!late) {
                            const dword = k.load(.u32, sOff(ms_base, SLOT, dslot, smu), r(lane4));
                            var pass = k.op2(.pand, .pred, r(ok), r(depthPass(&k, d_on, depthWord(&k, zs), k.op2(.@"and", .u32, r(dword), u(0x00ff_ffff)))));
                            if (stencil_enabled) {
                                const sword = k.load(.u32, sOff(ms_base, SLOT, sslot, smu), r(lane4));
                                pass = k.op2(.pand, .pred, r(pass), r(stencilPass(&k, s_on, front, k.op2(.shr, .u32, r(sword), u(24)))));
                                // (the stencil on: a sample in range is
                                // shaded, its fail operations need discard)
                                ok = k.sel(.pred, r(s_on), r(ok), r(pass));
                            } else ok = pass;
                        }
                        shade = k.op2(.por, .pred, r(shade), r(ok));
                    }
                    k.ifp(r(if (sh.quads) quadAny(&k, shade) else shade));
                    {
                        var io = frag.run();
                        const live = if (io.discard == .none) k.mov(.pred, u(1)) else k.op1(.pnot, .pred, r(io.discard));
                        k.ifp(r(live));
                        {
                            // the samples drawn: covered, the sample mask's,
                            // alpha to coverage's share (output 0's alpha)
                            var smask = k.op2(.@"and", .u32, r(cmask), r(k.param(.u32, R_SAMPLE_MASK)));
                            {
                                const a = if (io.color[3] == .none) k.mov(.f32, f(1)) else io.color[3];
                                const ca = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(a), f(0))), f(1));
                                const cnt = k.cvt(.f32, .u32, .rne, r(k.op2(.fmul, .f32, r(ca), f(@floatFromInt(S)))));
                                const amask = k.op2(.isub, .u32, r(k.op2(.shl, .u32, r(k.mov(.u32, u(1))), r(cnt))), u(1));
                                const a2c = k.cmp(.u32, .ne, r(k.param(.u32, R_A2C)), u(0));
                                smask = k.sel(.u32, r(a2c), r(k.op2(.@"and", .u32, r(smask), r(amask))), r(smask));
                            }
                            var src: [MAX_TARGETS][4]V = undefined;
                            var blends: [MAX_TARGETS]V = @splat(.none);
                            for (0..MAX_TARGETS) |tt| {
                                if (!on[tt]) continue;
                                src[tt] = clamped(&k, outputOf(&io, tt));
                                blends[tt] = k.cmp(.u32, .ne, r(k.param(.u32, tw(tt, .blend))), u(0));
                            }
                            const zf: V = if (late) (if (io.depth == .none) z else io.depth) else .none;
                            const zmin2 = k.param(.f32, R_ZMIN);
                            const zmax2 = k.param(.f32, R_ZMAX);
                            const dwrite = k.op2(.pand, .pred, r(d_on), r(k.cmp(.u32, .ne, r(k.param(.u32, R_DWRITE)), u(0))));
                            // each sample in turn (a loop: one sample's code
                            // whatever the samples)
                            const sa = k.reg(.u32);
                            k.set(sa, .mov, r(lane4), no, no);
                            const si = k.reg(.u32);
                            k.set(si, .mov, u(0), no, no);
                            k.loop();
                            {
                                k.brk(r(k.cmp(.u32, .ge, r(si), u(S))));
                                const bit = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(smask), r(si))), u(1))), u(0));
                                const zs = k.load(.f32, sOff(ms_base, SLOT, zslot, 0), r(sa));
                                k.ifp(r(k.op2(.pand, .pred, r(bit), r(zRange(&k, zs, zmin2, zmax2, clip_ok)))));
                                {
                                    const dword = k.load(.u32, sOff(ms_base, SLOT, dslot, 0), r(sa));
                                    const dz = depthWord(&k, if (late) zf else zs);
                                    const dpass = depthPass(&k, d_on, dz, k.op2(.@"and", .u32, r(dword), u(0x00ff_ffff)));
                                    var pass = dpass;
                                    if (stencil_enabled) {
                                        const sword = k.load(.u32, sOff(ms_base, SLOT, sslot, 0), r(sa));
                                        const stv = k.reg(.u32);
                                        k.set(stv, .shr, r(sword), u(24), no);
                                        const spass = stencilPass(&k, s_on, front, stv);
                                        pass = k.op2(.pand, .pred, r(pass), r(spass));
                                        k.ifp(r(s_on));
                                        stencilUpdate(&k, front, spass, dpass, stv);
                                        k.store(.u32, sOff(ms_base, SLOT, sslot, 0), r(sa), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(sword), u(0x00ff_ffff))), r(k.op2(.shl, .u32, r(stv), u(24))))));
                                        k.set(touched, .@"or", r(touched), u(2), no);
                                        k.endif();
                                    }
                                    k.ifp(r(pass));
                                    for (0..MAX_TARGETS) |tt| {
                                        if (!on[tt]) continue;
                                        const m = sOff(ms_base, SLOT, cslot[tt], 0);
                                        const old = k.load(.u32, m, r(sa));
                                        const out = blend(&k, src[tt], unpack(&k, old, tt), blends[tt]);
                                        k.store(.u32, m, r(sa), r(merge(&k, old, pack(&k, out, tt), tt)));
                                    }
                                    k.set(touched, .@"or", r(touched), u(1), no);
                                    k.ifp(r(dwrite));
                                    k.store(.u32, sOff(ms_base, SLOT, dslot, 0), r(sa), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(dword), u(0xff00_0000))), r(dz))));
                                    k.endif();
                                    k.endif();
                                }
                                k.endif();
                                k.set(sa, .iadd, r(sa), u(CULL * 4), no);
                                k.set(si, .iadd, r(si), u(1), no);
                            }
                            k.endloop();
                        }
                        k.endif();
                    }
                    k.endif();
                }
            }
            if (!sh.quads) k.endif();
        }
        k.endloop();
    }
    k.endloop();
    // the pixels (or samples) and their depth, stored once (the masked
    // channels kept)
    const color_touched = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(touched), u(1))), u(0));
    const dwrite = k.op2(.pand, .pred, r(d_on), r(k.cmp(.u32, .ne, r(k.param(.u32, R_DWRITE)), u(0))));
    k.ifp(r(k.op2(.pand, .pred, r(inside), r(color_touched))));
    {
        for (0..MAX_TARGETS) |tt| {
            if (!on[tt]) continue;
            if (!ms) {
                storePixel(&k, tb[tt], c_off[tt], merge(&k, old_c[tt], pack(&k, dst[tt], tt), tt), wide[tt], pair[tt]);
                continue;
            }
            const goff = k.reg(.u32);
            k.set(goff, .mov, r(c_off[tt]), no, no);
            const sa = k.reg(.u32);
            k.set(sa, .mov, r(lane4), no, no);
            const si = k.reg(.u32);
            k.set(si, .mov, u(0), no, no);
            k.loop();
            {
                k.brk(r(k.cmp(.u32, .ge, r(si), u(S))));
                storePixel(&k, tb[tt], goff, k.load(.u32, sOff(ms_base, SLOT, cslot[tt], 0), r(sa)), wide[tt], pair[tt]);
                k.set(goff, .iadd, r(goff), r(bpp[tt]), no);
                k.set(sa, .iadd, r(sa), u(CULL * 4), no);
                k.set(si, .iadd, r(si), u(1), no);
            }
            k.endloop();
        }
        if (!stencil_enabled) {
            k.ifp(r(dwrite));
            if (!ms) {
                k.store(.u32, kir.global(b_d, 32), r(d_off), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old_d), u(0xff000000))), r(depth))));
            } else for (0..S) |sm| {
                const smu: u32 = @intCast(sm);
                k.store(.u32, memAt(b_d, 4 * smu), r(d_off), r(k.load(.u32, sOff(ms_base, SLOT, dslot, smu), r(lane4))));
            }
            k.endif();
        }
    }
    k.endif();
    // an occlusion query: a sample passed here
    k.ifp(r(k.op2(.pand, .pred, r(k.op2(.pand, .pred, r(inside), r(color_touched))), r(k.cmp(.u32, .ne, r(k.param(.u32, R_QUERY)), u(0))))));
    k.store(.u32, kir.global(b_q, 32), r(k.mov(.u32, u(0))), r(k.mov(.u32, u(1))));
    k.endif();
    if (stencil_enabled) {
        const depth_written = k.op2(.pand, .pred, r(color_touched), r(dwrite));
        const stencil_written = k.op2(.pand, .pred, r(s_on), r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(touched), u(2))), u(0))));
        k.ifp(r(k.op2(.pand, .pred, r(inside), r(k.op2(.por, .pred, r(depth_written), r(k.op2(.pand, .pred, r(shared_ds), r(stencil_written))))))));
        if (!ms) {
            const low_depth = k.sel(.u32, r(depth_written), r(depth), r(k.op2(.@"and", .u32, r(old_d), u(0x00ffffff))));
            const high_stencil = k.sel(.u32, r(shared_ds), r(k.op2(.shl, .u32, r(stencil), u(24))), r(k.op2(.@"and", .u32, r(old_d), u(0xff000000))));
            k.store(.u32, kir.global(b_d, 32), r(d_off), r(k.op2(.@"or", .u32, r(low_depth), r(high_stencil))));
        } else for (0..S) |sm| {
            // (the depth word's slot holds its stencil bits as they were;
            // one image for both: the stencil slot's)
            const smu: u32 = @intCast(sm);
            const dword = k.load(.u32, sOff(ms_base, SLOT, dslot, smu), r(lane4));
            const sword = k.load(.u32, sOff(ms_base, SLOT, sslot, smu), r(lane4));
            const both = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(dword), u(0x00ff_ffff))), r(k.op2(.@"and", .u32, r(sword), u(0xff00_0000))));
            k.store(.u32, memAt(b_d, 4 * smu), r(d_off), r(k.sel(.u32, r(shared_ds), r(both), r(dword))));
        }
        k.endif();
        k.ifp(r(k.op2(.pand, .pred, r(inside), r(k.op2(.pand, .pred, r(stencil_written), r(k.op1(.pnot, .pred, r(shared_ds))))))));
        if (!ms) {
            k.store(.u32, kir.global(b_s, 32), r(s_off), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old_s), u(0x00ffffff))), r(k.op2(.shl, .u32, r(stencil), u(24))))));
        } else for (0..S) |sm| {
            const smu: u32 = @intCast(sm);
            k.store(.u32, memAt(b_s, 4 * smu), r(s_off), r(k.load(.u32, sOff(ms_base, SLOT, sslot, smu), r(lane4))));
        }
        k.endif();
    }
    return k;
}

/// A sample's depth in the depth range (and the clip distances' half
/// spaces).
fn zRange(k: *kir.Kernel, zs: V, lo: V, hi: V, clip: V) V {
    var x = k.op2(.pand, .pred, r(k.cmp(.f32, .ge, r(zs), r(lo))), r(k.cmp(.f32, .le, r(zs), r(hi))));
    if (clip != .none) x = k.op2(.pand, .pred, r(x), r(clip));
    return x;
}

/// A fragment's inputs (one primitive at one pixel), to run the fragment
/// code with.
const Frag = struct {
    k: *kir.Kernel,
    p: *const Pipeline,
    b_t: u8,
    base: V,
    b_uni: u8,
    b_tex: u8,
    b_buf: u8,
    odd_x: V,
    odd_y: V,
    X: V,
    Y: V,
    dX: V,
    dY: V,
    z: V,
    front: V,

    fn run(fr: Frag) FragmentIO {
        const k = fr.k;
        const sh = fr.p.shaders;
        const iw = plane(k, fr.b_t, fr.base, S_W, fr.dX, fr.dY);
        const wv = k.div(f(1), r(iw));
        var io = FragmentIO{ .uniforms = fr.b_uni, .textures = fr.b_tex, .buffers = fr.b_buf, .quads = sh.quads, .odd_x = fr.odd_x, .odd_y = fr.odd_y };
        for (0..sh.varyings) |j| {
            const w0: u32 = @intCast(SREC + 3 * j);
            // (flat: the provoking vertex's bits, untouched: an integer's too)
            io.varying[j] = if (sh.flat & (@as(u64, 1) << @intCast(j)) != 0) ld(k, fr.b_t, fr.base, w0, .f32) else k.op2(.fmul, .f32, r(plane(k, fr.b_t, fr.base, w0, fr.dX, fr.dY)), r(wv));
        }
        io.frag_coord = .{ fr.X, fr.Y, fr.z, iw };
        io.front_facing = fr.front;
        if (sh.point_coord) {
            const cw = fr.p.sCoord();
            io.point_coord = .{ plane(k, fr.b_t, fr.base, cw, fr.dX, fr.dY), plane(k, fr.b_t, fr.base, cw + 3, fr.dX, fr.dY) };
        }
        sh.fragment(sh.ctx, k, &io);
        return io;
    }
};

/// Output `t`'s colour (0 where the code has none).
fn outputOf(io: *const FragmentIO, t: usize) [4]V {
    return if (t == 0) io.color else io.colors[t];
}

fn clamped(k: *kir.Kernel, c: [4]V) [4]V {
    var o: [4]V = undefined;
    for (0..4) |x| o[x] = if (c[x] == .none) k.mov(.f32, f(0)) else k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(c[x]), f(0))), f(1));
    return o;
}

/// GL's and Vulkan's diamond-exit rule for the line record at `base`, at
/// each pixel of the tile (its center in 1/16 pixel): the line crosses
/// the pixel's diamond (|x - cx| + |y - cy| < 1/2, as the square
/// |u - uc|, |v - vc| < 8 in u = x + y, v = x - y) and does not end in it.
/// The ends nudged by (d, d'), d >> d' > 0: on the square's edges a
/// coordinate tie counts the low side in; on its corners, the side of
/// tpos. Separating axes: u, v, and the line's normal (its function g at
/// the corners, gC -+ 8 max(|dx|, |dy|)).
fn lineCover(k: *kir.Kernel, b_t: u8, base: V, tcx: V, tcy: V, lx16: V, ly16: V, px: V, py: V) struct { covered: V, out_tile: V } {
    const ua = ld(k, b_t, base, L_UA, .i32);
    const va = ld(k, b_t, base, L_VA, .i32);
    const ub = ld(k, b_t, base, L_UB, .i32);
    const vb = ld(k, b_t, base, L_VB, .i32);
    const ax = ld(k, b_t, base, L_AX, .i32);
    const ay = ld(k, b_t, base, L_AY, .i32);
    const dx = ld(k, b_t, base, L_DX, .i32);
    const dy = ld(k, b_t, base, L_DY, .i32);
    const m8 = ld(k, b_t, base, L_M8, .i32);
    const tpos = k.cmp(.u32, .ne, r(ld(k, b_t, base, L_TPOS, .u32)), u(0));
    // g at the tile's first center in 64 bits: (cx - ax) dy - (cy - ay) dx
    const g64 = sub64(k, mul64(k, r(dy), r(k.op2(.isub, .i32, r(tcx), r(ax)))), mul64(k, r(dx), r(k.op2(.isub, .i32, r(tcy), r(ay)))));
    const above = k.op2(.por, .pred, r(k.cmp(.i32, .gt, r(g64.hi), i(0))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(g64.hi), i(0))), r(k.cmp(.u32, .gt, r(g64.lo), u(LIMIT))))));
    const below = k.op2(.por, .pred, r(k.cmp(.i32, .lt, r(g64.hi), i(-1))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(g64.hi), i(-1))), r(k.cmp(.u32, .lt, r(g64.lo), u(@as(u32, 0) -% LIMIT))))));
    const g32 = k.sel(.i32, r(above), u(LIMIT), r(k.sel(.i32, r(below), u(@as(u32, 0) -% LIMIT), r(g64.lo))));
    const gc = k.op2(.isub, .i32, r(k.op2(.iadd, .i32, r(g32), r(k.op2(.imul, .i32, r(dy), r(lx16))))), r(k.op2(.imul, .i32, r(dx), r(ly16))));
    // the normal axis: min corner < 0 < max corner (ties by tpos)
    const one_if_not = k.sel(.i32, r(tpos), i(0), i(1));
    const lo_ok = k.cmp(.i32, .le, r(k.op2(.iadd, .i32, r(k.op2(.isub, .i32, r(gc), r(m8))), r(one_if_not))), i(0));
    const hi_ok = k.cmp(.i32, .ge, r(k.op2(.iadd, .i32, r(gc), r(m8))), r(k.sel(.i32, r(tpos), i(1), i(0))));
    // the center in u and v
    const cx = k.op2(.iadd, .i32, r(k.op2(.shl, .i32, r(px), u(4))), i(SUB / 2));
    const cy = k.op2(.iadd, .i32, r(k.op2(.shl, .i32, r(py), u(4))), i(SUB / 2));
    const uc = k.op2(.iadd, .i32, r(cx), r(cy));
    const vc = k.op2(.isub, .i32, r(cx), r(cy));
    const inRange = struct {
        // [lo, hi] of the segment meets [c - 8, c + 8)
        fn f_(kk: *kir.Kernel, a: V, b: V, c: V) V {
            const lo = kk.op2(.imin, .i32, r(a), r(b));
            const hi = kk.op2(.imax, .i32, r(a), r(b));
            return kk.op2(.pand, .pred, r(kk.cmp(.i32, .ge, r(hi), r(kk.op2(.isub, .i32, r(c), i(8))))), r(kk.cmp(.i32, .lt, r(lo), r(kk.op2(.iadd, .i32, r(c), i(8))))));
        }
        // a point inside: p - c in [-8, 8)
        fn in(kk: *kir.Kernel, p_: V, c: V) V {
            const d = kk.op2(.isub, .i32, r(p_), r(c));
            return kk.op2(.pand, .pred, r(kk.cmp(.i32, .ge, r(d), i(-8))), r(kk.cmp(.i32, .lt, r(d), i(8))));
        }
    };
    var cov = k.op2(.pand, .pred, r(lo_ok), r(hi_ok));
    cov = k.op2(.pand, .pred, r(cov), r(inRange.f_(k, ua, ub, uc)));
    cov = k.op2(.pand, .pred, r(cov), r(inRange.f_(k, va, vb, vc)));
    // (the end's own diamond: the next line's)
    const b_in = k.op2(.pand, .pred, r(inRange.in(k, ub, uc)), r(inRange.in(k, vb, vc)));
    cov = k.op2(.pand, .pred, r(cov), r(k.op1(.pnot, .pred, r(b_in))));
    const far = k.op2(.por, .pred, r(above), r(below));
    return .{ .covered = cov, .out_tile = far };
}

fn stencilOp(k: *kir.Kernel, op: V, value: V, reference: V) V {
    var result = value;
    const increment = k.op2(.iadd, .u32, r(value), u(1));
    const decrement = k.op2(.isub, .u32, r(value), u(1));
    const values = [_]V{
        value,
        k.mov(.u32, u(0)),
        reference,
        k.op2(.imin, .u32, r(increment), u(255)),
        k.sel(.u32, r(k.cmp(.u32, .eq, r(value), u(0))), u(0), r(decrement)),
        k.op2(.xor, .u32, r(value), u(255)),
        k.op2(.@"and", .u32, r(increment), u(255)),
        k.op2(.@"and", .u32, r(decrement), u(255)),
    };
    for (values[1..], 1..) |candidate, index| {
        result = k.sel(.u32, r(k.cmp(.u32, .eq, r(op), u(@intCast(index)))), r(candidate), r(result));
    }
    return result;
}

/// Whether any pixel of the lane's quad has `p` (every lane of the group
/// there).
fn quadAny(k: *kir.Kernel, p: V) V {
    var q = k.sel(.u32, r(p), u(1), u(0));
    q = k.op2(.@"or", .u32, r(q), r(k.shfl(.u32, .xor, r(q), u(QUAD_X))));
    q = k.op2(.@"or", .u32, r(q), r(k.shfl(.u32, .xor, r(q), u(QUAD_Y))));
    return k.cmp(.u32, .ne, r(q), u(0));
}

/// GL's blending of `src` over `dst` (both clamped to 0..1): every factor
/// as c + ks*s + kd*d + ksa*s.a + kda*d.a, SRC_ALPHA_SATURATE apart, the
/// five equations; `on` false: src. The result clamped to 0..1.
fn blend(k: *kir.Kernel, src: [4]V, dst: [4]V, on: V) [4]V {
    const one_minus_da = k.op2(.fsub, .f32, f(1), r(dst[3]));
    const sat = k.op2(.fmin, .f32, r(src[3]), r(one_minus_da));
    const saturate = k.cmp(.u32, .ne, r(k.param(.u32, R_SATURATE)), u(0));
    const factor = struct {
        fn f_(kk: *kir.Kernel, pw: u16, c: usize, s: V, d: V, sa: V, da: V) V {
            const cw: u16 = pw + @as(u16, @intCast(c));
            const kw: u16 = if (pw == R_SRC_A or pw == R_DST_A) pw + 1 else pw + 3;
            var x = kk.mov(.f32, r(kk.param(.f32, cw)));
            x = kk.op2(.fadd, .f32, r(x), r(kk.op2(.fmul, .f32, r(kk.param(.f32, kw)), r(s))));
            x = kk.op2(.fadd, .f32, r(x), r(kk.op2(.fmul, .f32, r(kk.param(.f32, kw + 1)), r(d))));
            x = kk.op2(.fadd, .f32, r(x), r(kk.op2(.fmul, .f32, r(kk.param(.f32, kw + 2)), r(sa))));
            x = kk.op2(.fadd, .f32, r(x), r(kk.op2(.fmul, .f32, r(kk.param(.f32, kw + 3)), r(da))));
            return x;
        }
    }.f_;
    const combine = struct {
        fn f_(kk: *kir.Kernel, eq: V, s: V, d: V, fs: V, fd: V) V {
            const ss = kk.op2(.fmul, .f32, r(s), r(fs));
            const dd = kk.op2(.fmul, .f32, r(d), r(fd));
            var x = kk.op2(.fadd, .f32, r(ss), r(dd));
            x = kk.sel(.f32, r(kk.cmp(.u32, .eq, r(eq), u(1))), r(kk.op2(.fsub, .f32, r(ss), r(dd))), r(x));
            x = kk.sel(.f32, r(kk.cmp(.u32, .eq, r(eq), u(2))), r(kk.op2(.fsub, .f32, r(dd), r(ss))), r(x));
            x = kk.sel(.f32, r(kk.cmp(.u32, .eq, r(eq), u(3))), r(kk.op2(.fmin, .f32, r(s), r(d))), r(x));
            x = kk.sel(.f32, r(kk.cmp(.u32, .eq, r(eq), u(4))), r(kk.op2(.fmax, .f32, r(s), r(d))), r(x));
            return kk.op2(.fmin, .f32, r(kk.op2(.fmax, .f32, r(x), f(0))), f(1));
        }
    }.f_;
    var out: [4]V = undefined;
    const eq_rgb = k.param(.u32, R_EQ_RGB);
    for (0..3) |c| {
        const fs0 = factor(k, R_SRC_RGB, c, src[c], dst[c], src[3], dst[3]);
        const fs = k.sel(.f32, r(saturate), r(sat), r(fs0));
        const fd = factor(k, R_DST_RGB, c, src[c], dst[c], src[3], dst[3]);
        out[c] = k.sel(.f32, r(on), r(combine(k, eq_rgb, src[c], dst[c], fs, fd)), r(src[c]));
    }
    const fsa = factor(k, R_SRC_A, 0, src[3], dst[3], src[3], dst[3]);
    const fda = factor(k, R_DST_A, 0, src[3], dst[3], src[3], dst[3]);
    out[3] = k.sel(.f32, r(on), r(combine(k, k.param(.u32, R_EQ_A), src[3], dst[3], fsa, fda)), r(src[3]));
    return out;
}

// ── The kernels' parameters for a draw ─────────────────────────────────────

/// The byte offset of a buffer's last whole word.
fn lastWord(b: *const engine.Image) u32 {
    const n: u32 = @intCast(@min(b.buf.cpu.len, std.math.maxInt(u32)));
    return if (n >= 4) (n - 4) & ~@as(u32, 3) else 0;
}

fn fbits(x: f32) u32 {
    return @bitCast(x);
}

/// The vertex kernel's parameters (and the capture kernel's: then the
/// buffers' first words, captureParams).
pub fn vertexParams(d: *const Draw, out: []u32) []u32 {
    const n = VERTEX_PARAMS;
    @memset(out[0..n], 0);
    if (d.restart and d.index != null) out[V_RESTART] = switch (d.index_size) {
        1 => 0xff,
        2 => 0xffff,
        else => 0xffff_ffff,
    };
    out[V_COUNT] = d.count;
    out[V_FIRST] = if (d.index == null) d.first else 0;
    out[V_INDEX_SIZE] = if (d.index != null) d.index_size else 0;
    out[V_INDEX_OFF] = d.index_offset;
    out[V_CX] = fbits(d.center[0]);
    out[V_CY] = fbits(d.center[1]);
    out[V_HX] = fbits(d.half[0]);
    out[V_HY] = fbits(d.half[1]);
    out[V_ZS] = fbits(d.depth_scale);
    out[V_ZB] = fbits(d.depth_bias);
    out[V_STRIDE] = d.pipe.vstride;
    out[V_INDEX_LIMIT] = if (d.index) |ib| lastWord(ib) else 0;
    out[V_POINTS] = @intFromBool(d.topology == .points);
    out[V_FLAG] = restartFlag(d);
    for (d.attrs, 0..) |a, j| {
        const w = out[V_ATTR + j * V_ATTR_WORDS ..][0..V_ATTR_WORDS];
        if (a.buf == null or a.comps == 0) {
            w.* = .{ 0, 0, 0, 0, a.constant[0], a.constant[1], a.constant[2], a.constant[3] };
            continue;
        }
        var fmt: u32 = a.comps | @as(u32, a.size) << 4;
        if (a.float) fmt |= F_FLOAT;
        if (a.signed) fmt |= F_SIGNED;
        if (a.normalized and !a.integer and !a.float) fmt |= F_NORM;
        if (a.integer) fmt |= F_INT;
        const bits: u6 = @intCast(@as(u32, a.size) * 8 - @intFromBool(a.signed));
        const div: f32 = if (bits >= 32) 4294967295.0 else @floatFromInt((@as(u64, 1) << bits) - 1);
        w.* = .{ a.offset, a.stride, fmt, @intFromBool(a.divisor != 0), fbits(div), lastWord(a.buf.?), 0, 0 };
    }
    return out[0..n];
}

/// Primitive restart's word (a byte offset after the draw's vertex
/// records, Draw.restartWord), or RESTART_NONE: strips and fans with an
/// element array and restart on.
pub fn restartFlag(d: *const Draw) u32 {
    if (!d.restart or d.index == null or (d.topology != .strip and d.topology != .fan)) return RESTART_NONE;
    return d.restartWord();
}

/// The capture kernel's parameters: the vertex kernel's, and each
/// transform feedback buffer's first word.
pub fn captureParams(d: *const Draw, bases: [MAX_CAPTURE_BUFFERS]u32, out: []u32) []u32 {
    const p = vertexParams(d, out);
    @memcpy(out[C_BASE..][0..MAX_CAPTURE_BUFFERS], &bases);
    return p;
}

pub fn setupParams(d: *const Draw, out: []u32) []u32 {
    const rect = d.rect;
    const p = [_]u32{ d.prims(), d.count, @backingInt(d.topology), d.cull, @intFromBool(d.front_ccw), d.pipe.vstride, d.pipe.sstride, rect.x0, rect.y0, rect.x1, rect.y1, fbits(d.bias_factor), fbits(d.bias_units), fbits(d.bias_clamp), @intFromBool(d.samples() > 1), restartFlag(d) };
    comptime std.debug.assert(p.len == SETUP_PARAMS);
    @memcpy(out[0..p.len], &p);
    return out[0..p.len];
}

fn factorWords(fc: Factor, rgb: bool, out: []u32) void {
    if (rgb) {
        out[0] = fbits(fc.c[0]);
        out[1] = fbits(fc.c[1]);
        out[2] = fbits(fc.c[2]);
        out[3] = fbits(fc.ks);
        out[4] = fbits(fc.kd);
        out[5] = fbits(fc.ksa);
        out[6] = fbits(fc.kda);
    } else {
        out[0] = fbits(fc.c[3]);
        out[1] = fbits(fc.ks);
        out[2] = fbits(fc.kd);
        out[3] = fbits(fc.ksa);
        out[4] = fbits(fc.kda);
    }
}

pub fn rasterParams(d: *const Draw, bins: Bins, out: []u32) []u32 {
    @memset(out[0..RASTER_PARAMS], 0);
    out[R_BINNED] = @intFromBool(bins.on);
    out[R_BINS_X] = bins.x;
    out[R_BIN_BASE] = bins.base;
    out[R_BIN_CAP] = bins.cap;
    const rect = d.rect;
    out[R_RECT] = rect.x0;
    out[R_RECT + 1] = rect.y0;
    out[R_RECT + 2] = rect.x1;
    out[R_RECT + 3] = rect.y1;
    out[R_NTRI] = d.records() * d.instances;
    out[R_SSTRIDE] = d.pipe.sstride;
    out[R_C_STRIDE] = d.color.stride;
    out[R_BPP] = d.color.format.bytes();
    out[R_C_TOPDOWN] = @intFromBool(d.color.top_down);
    out[R_C_HEIGHT] = d.color.height;
    out[R_SHIFT_R] = if (d.color.format == .bgra8) 16 else 0;
    out[R_SHIFT_B] = if (d.color.format == .bgra8) 0 else 16;
    out[R_KEEP] = d.keep;
    out[R_NO_ALPHA] = @intFromBool(d.color.no_alpha or d.color.format.channels() < 4);
    if (d.depth) |dp| {
        out[R_DEPTH] = @intFromBool(d.depth_test);
        out[R_D_STRIDE] = dp.stride / 4;
        out[R_D_TOPDOWN] = @intFromBool(dp.top_down);
        out[R_D_HEIGHT] = dp.height;
    }
    out[R_DFUNC] = d.depth_func;
    out[R_DWRITE] = @intFromBool(d.depth_write);
    out[R_ZMIN] = fbits(d.zmin);
    out[R_ZMAX] = fbits(d.zmax);
    if (d.stencil) |stencil| {
        out[R_STENCIL] = 1;
        out[R_S_STRIDE] = stencil.stride / 4;
        out[R_S_TOPDOWN] = @intFromBool(stencil.top_down);
        out[R_S_HEIGHT] = stencil.height;
        out[R_DS_SHARED] = @intFromBool(d.depth == stencil);
        for ([_]Stencil{ d.stencil_front, d.stencil_back }, [_]usize{ R_S_FRONT, R_S_BACK }) |face, start| {
            const words = [_]u32{ face.func, face.reference, face.value_mask, face.write_mask, @backingInt(face.fail), @backingInt(face.depth_fail), @backingInt(face.pass) };
            @memcpy(out[start..][0..words.len], &words);
        }
    }
    out[R_QUERY] = @intFromBool(d.query != null);
    out[R_SAMPLE_MASK] = d.sample_mask;
    out[R_A2C] = @intFromBool(d.alpha_to_coverage);
    if (d.color_off) out[R_BLEND] = 0;
    for (d.targets[1..], 1..) |tg, ti| {
        const x = tg orelse continue;
        const img = x.img;
        const w = out[tw(ti, .stride)..][0..TGT_WORDS];
        w[@intFromEnum(TF.stride)] = img.stride;
        w[@intFromEnum(TF.topdown)] = @intFromBool(img.top_down);
        w[@intFromEnum(TF.height)] = img.height;
        w[@intFromEnum(TF.bpp)] = img.format.bytes();
        w[@intFromEnum(TF.shift_r)] = if (img.format == .bgra8) 16 else 0;
        w[@intFromEnum(TF.shift_b)] = if (img.format == .bgra8) 0 else 16;
        w[@intFromEnum(TF.keep)] = x.keep;
        w[@intFromEnum(TF.no_alpha)] = @intFromBool(img.no_alpha or img.format.channels() < 4);
        w[@intFromEnum(TF.blend)] = @intFromBool(x.blend and d.blend != null);
    }
    if (d.blend) |b| {
        out[R_BLEND] = 1;
        out[R_EQ_RGB] = @backingInt(b.eq_rgb);
        out[R_EQ_A] = @backingInt(b.eq_a);
        out[R_SATURATE] = @intFromBool(b.saturate);
        factorWords(b.src_rgb, true, out[R_SRC_RGB..]);
        factorWords(b.dst_rgb, true, out[R_DST_RGB..]);
        factorWords(b.src_a, false, out[R_SRC_A..]);
        factorWords(b.dst_a, false, out[R_DST_A..]);
    }
    return out[0..RASTER_PARAMS];
}
