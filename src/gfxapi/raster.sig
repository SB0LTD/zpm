//! @zpm/gfxapi raster — GL's draws as three KIR kernels per pipeline, the
//! same on every GPU (ir3, sm_120) and on the CPU (KIR's interpreter):
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
//! 3. **raster** (a group per TILE x TILE pixels, a thread per pixel): the
//!    tile's pixels and depth loaded once, then every triangle in order
//!    (GL's order: blending is right): a tile outside its box or one of
//!    its edges skipped; coverage exact (each edge's constant for the tile
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
//! Not yet: points and lines; clipping (a triangle with a vertex at w <= 0,
//! or beyond GUARD pixels, is dropped: a guard band); multisampling;
//! several color attachments; stencil tests. Shaders are KIR emitters
//! (`Shaders`); the GLSL compiler (the next stage) makes them.
//!
//! Allocation-free: kernels are built into the caller's storage.

const std = @import("std");
const gpu = @import("gpu");
const engine = @import("engine.sig");
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
/// Scalar varyings (a vec4 is four).
pub const MAX_VARYINGS = 16;
pub const MAX_UNIFORM_WORDS = 1024;
/// A tile's edge constants are clamped to +-LIMIT: the 32-bit per-pixel
/// part then never overflows (fixed coordinates < 2^19, steps < 2^7).
const LIMIT: u32 = 1 << 29;

pub const VERTEX_GROUP = 64;
pub const SETUP_GROUP = 64;

// ── What a pipeline's shaders are ──────────────────────────────────────────

pub const VertexIO = struct {
    /// the attributes: four registers each (f32 bits; an integer
    /// attribute's raw bits)
    attr: [MAX_ATTRS][4]V = undefined,
    vertex_id: V = .none,
    instance_id: V = .none,
    /// the binding uniforms are loaded from (uniform(k, io.uniforms, word))
    uniforms: u8 = 0,
    /// outputs: the clip-space position, the varyings (f32)
    position: [4]V = .{ .none, .none, .none, .none },
    varying: [MAX_VARYINGS]V = [_]V{.none} ** MAX_VARYINGS,
};

pub const FragmentIO = struct {
    varying: [MAX_VARYINGS]V = undefined,
    /// gl_FragCoord: x + 0.5, y + 0.5, depth, 1/w
    frag_coord: [4]V = undefined,
    /// gl_FrontFacing (a pred)
    front_facing: V = .none,
    uniforms: u8 = 0,
    /// outputs: the color (f32, 0..1 for unorm targets), and a pred that
    /// drops the fragment (discard), if the shader sets one
    color: [4]V = .{ .none, .none, .none, .none },
    discard: V = .none,
};

/// The shaders: KIR emitters (what GLSL compiles to, or Sig code).
pub const Shaders = struct {
    ctx: ?*const anyopaque = null,
    attrs: u8 = 0,
    varyings: u8 = 0,
    /// bit i: varying i is flat (the provoking vertex's), else smooth
    flat: u32 = 0,
    vertex: *const fn (?*const anyopaque, *kir.Kernel, *VertexIO) void,
    fragment: *const fn (?*const anyopaque, *kir.Kernel, *FragmentIO) void,
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
    /// the device's programs: vertex, setup, raster (none on the CPU)
    progs: [3]?gpu.Program = .{ null, null, null },
    /// the engine that loaded them
    owner: ?*anyopaque = null,

    pub fn init(sh: Shaders) Pipeline {
        std.debug.assert(sh.attrs <= MAX_ATTRS and sh.varyings <= MAX_VARYINGS);
        return .{ .shaders = sh, .vstride = VREC + sh.varyings, .sstride = SREC + 3 * @as(u32, sh.varyings) };
    }
};

// a vertex's record: x, y (1/16 pixel, i32), depth (window), 1/w (< 0:
// the vertex is out), then the varyings
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

pub const Topology = enum(u8) { triangles, strip, fan };

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

pub const Draw = struct {
    pipe: *const Pipeline,
    color: *engine.Image,
    depth: ?*engine.Image = null,
    attrs: [MAX_ATTRS]Attr = [_]Attr{.{}} ** MAX_ATTRS,
    /// the element array: its buffer, byte offset, index size (1, 2, 4)
    index: ?*engine.Image = null,
    index_offset: u32 = 0,
    index_size: u8 = 0,
    topology: Topology = .triangles,
    first: u32 = 0,
    count: u32 = 0,
    instances: u32 = 1,
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

    pub fn triangles(d: *const Draw) u32 {
        return switch (d.topology) {
            .triangles => d.count / 3,
            .strip, .fan => if (d.count >= 3) d.count - 2 else 0,
        };
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
// an attribute's format word
const F_FLOAT = 1 << 8;
const F_SIGNED = 1 << 9;
const F_NORM = 1 << 10;
const F_INT = 1 << 11;

/// bindings: 0 vertex records (written), 1 uniforms, 2 the element array,
/// 3.. each attribute's buffer
pub fn vertexKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    var k = kir.Kernel.init(s, "gl_vertex", .{ VERTEX_GROUP, 1, 1 });
    const b_out = k.binding();
    const b_uni = k.binding();
    const b_idx = k.binding();
    var b_attr: [MAX_ATTRS]u8 = undefined;
    for (&b_attr) |*b| b.* = k.binding();
    const sh = p.shaders;
    const count = k.param(.u32, V_COUNT);
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(VERTEX_GROUP), r(k.tid(0)));
    const inst = k.gid(1);
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(count))));
    {
        // the vertex: first + x, or the element array's x-th index
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
        var io = VertexIO{ .vertex_id = v, .instance_id = inst, .uniforms = b_uni };
        for (0..sh.attrs) |a| io.attr[a] = fetch(&k, b_attr[a], @intCast(V_ATTR + a * V_ATTR_WORDS), v, inst);
        sh.vertex(sh.ctx, &k, &io);
        // clip space to window space
        const w = io.position[3];
        const iw = k.div(f(1), r(w));
        const xw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(io.position[0]), r(iw))), r(k.param(.f32, V_HX)))), r(k.param(.f32, V_CX)));
        const yw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(io.position[1]), r(iw))), r(k.param(.f32, V_HY)))), r(k.param(.f32, V_CY)));
        const zw = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(io.position[2]), r(iw))), r(k.param(.f32, V_ZS)))), r(k.param(.f32, V_ZB)));
        // (in: w > 0, inside the guard band; NaN fails every compare)
        var ok = k.cmp(.f32, .gt, r(w), f(0));
        ok = k.op2(.pand, .pred, r(ok), r(k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(xw))), f(GUARD))));
        ok = k.op2(.pand, .pred, r(ok), r(k.cmp(.f32, .le, r(k.op1(.fabs, .f32, r(yw))), f(GUARD))));
        const xs = k.sel(.f32, r(ok), r(xw), f(0));
        const ys = k.sel(.f32, r(ok), r(yw), f(0));
        const xf = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(xs), f(SUB))));
        const yf = k.cvt(.f32, .i32, .rne, r(k.op2(.fmul, .f32, r(ys), f(SUB))));
        const rec = k.op3(.imad, .u32, r(inst), r(count), r(x));
        const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(k.param(.u32, V_STRIDE)))), u(2));
        k.store(.i32, memAt(b_out, 0), r(base), r(xf));
        k.store(.i32, memAt(b_out, 4), r(base), r(yf));
        k.store(.f32, memAt(b_out, 8), r(base), r(zw));
        k.store(.f32, memAt(b_out, 12), r(base), r(k.sel(.f32, r(ok), r(iw), f(-1))));
        for (0..sh.varyings) |j| {
            const val = io.varying[j];
            const out = if (sh.flat & (@as(u32, 1) << @intCast(j)) != 0) val else k.op2(.fmul, .f32, r(val), r(iw));
            k.store(.f32, memAt(b_out, @intCast(16 + 4 * j)), r(base), r(out));
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

// ── Kernel 2: triangle setup ───────────────────────────────────────────────

const T_NTRI = 0;
const T_COUNT = 1;
const T_MODE = 2;
const T_CULL = 3;
const T_FRONT_CCW = 4;
const T_VSTRIDE = 5;
const T_SSTRIDE = 6;
const T_RECT = 7; // x0, y0, x1, y1 (exclusive)

/// bindings: 0 triangle records (written), 1 vertex records
pub fn setupKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    var k = kir.Kernel.init(s, "gl_setup", .{ SETUP_GROUP, 1, 1 });
    const b_out = k.binding();
    const b_v = k.binding();
    const sh = p.shaders;
    const ntri = k.param(.u32, T_NTRI);
    const t = k.op3(.imad, .u32, r(k.gid(0)), u(SETUP_GROUP), r(k.tid(0)));
    const inst = k.gid(1);
    k.ifp(r(k.cmp(.u32, .lt, r(t), r(ntri))));
    {
        // the topology's vertices (GL's: the last provokes)
        const mode = k.param(.u32, T_MODE);
        const t3 = k.op2(.imul, .u32, r(t), u(3));
        const odd = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(t), u(1))), u(0));
        const is_strip = k.cmp(.u32, .eq, r(mode), u(1));
        const is_fan = k.cmp(.u32, .eq, r(mode), u(2));
        const t1 = k.op2(.iadd, .u32, r(t), u(1));
        const t2 = k.op2(.iadd, .u32, r(t), u(2));
        // strip: (t, t+1, t+2), odd t (t+1, t, t+2); fan: (0, t+1, t+2)
        const s0 = k.sel(.u32, r(odd), r(t1), r(t));
        const s1 = k.sel(.u32, r(odd), r(t), r(t1));
        var iv: [3]V = undefined;
        iv[0] = k.sel(.u32, r(is_fan), u(0), r(k.sel(.u32, r(is_strip), r(s0), r(t3))));
        iv[1] = k.sel(.u32, r(is_fan), r(t1), r(k.sel(.u32, r(is_strip), r(s1), r(k.op2(.iadd, .u32, r(t3), u(1))))));
        iv[2] = k.sel(.u32, r(k.op2(.por, .pred, r(is_fan), r(is_strip))), r(t2), r(k.op2(.iadd, .u32, r(t3), u(2))));
        const vstride = k.param(.u32, T_VSTRIDE);
        const count = k.param(.u32, T_COUNT);
        var vx: [3]V = undefined;
        var vy: [3]V = undefined;
        var vz: [3]V = undefined;
        var vw: [3]V = undefined;
        var vv: [3][MAX_VARYINGS]V = undefined;
        for (0..3) |n| {
            const rec = k.op3(.imad, .u32, r(inst), r(count), r(iv[n]));
            const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(rec), r(vstride))), u(2));
            vx[n] = k.load(.i32, memAt(b_v, 0), r(base));
            vy[n] = k.load(.i32, memAt(b_v, 4), r(base));
            vz[n] = k.load(.f32, memAt(b_v, 8), r(base));
            vw[n] = k.load(.f32, memAt(b_v, 12), r(base));
            for (0..sh.varyings) |j| vv[n][j] = k.load(.f32, memAt(b_v, @intCast(16 + 4 * j)), r(base));
        }
        var valid = k.cmp(.f32, .gt, r(vw[0]), f(0));
        valid = k.op2(.pand, .pred, r(valid), r(k.cmp(.f32, .gt, r(vw[1]), f(0))));
        valid = k.op2(.pand, .pred, r(valid), r(k.cmp(.f32, .gt, r(vw[2]), f(0))));
        // twice the signed area, exact: (x1-x0)(y2-y0) - (x2-x0)(y1-y0)
        const dx1 = k.op2(.isub, .i32, r(vx[1]), r(vx[0]));
        const dy1 = k.op2(.isub, .i32, r(vy[1]), r(vy[0]));
        const dx2 = k.op2(.isub, .i32, r(vx[2]), r(vx[0]));
        const dy2 = k.op2(.isub, .i32, r(vy[2]), r(vy[0]));
        const area = sub64(&k, mul64(&k, r(dx1), r(dy2)), mul64(&k, r(dx2), r(dy1)));
        const zero = k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(area.hi), i(0))), r(k.cmp(.u32, .eq, r(area.lo), u(0))));
        const neg = k.cmp(.i32, .lt, r(area.hi), i(0));
        const ccw = k.op1(.pnot, .pred, r(k.op2(.por, .pred, r(neg), r(zero))));
        const front_ccw = k.cmp(.u32, .ne, r(k.param(.u32, T_FRONT_CCW)), u(0));
        // front facing: counter-clockwise exactly when the front is
        const same = k.cmp(.u32, .eq, r(k.sel(.u32, r(ccw), u(1), u(0))), r(k.sel(.u32, r(front_ccw), u(1), u(0))));
        const cull = k.param(.u32, T_CULL);
        const cull_front = k.op2(.pand, .pred, r(same), r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(cull), u(1))), u(0))));
        const cull_back = k.op2(.pand, .pred, r(k.op1(.pnot, .pred, r(same))), r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(cull), u(2))), u(0))));
        valid = k.op2(.pand, .pred, r(valid), r(k.op1(.pnot, .pred, r(zero))));
        valid = k.op2(.pand, .pred, r(valid), r(k.op1(.pnot, .pred, r(k.op2(.por, .pred, r(cull_front), r(cull_back))))));
        // (flat varyings: the provoking vertex's, taken before any swap)
        var flat_v: [MAX_VARYINGS]V = undefined;
        for (0..sh.varyings) |j| flat_v[j] = vv[2][j];
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
        swap(&k, .i32, sw, &vx[1], &vx[2]);
        swap(&k, .i32, sw, &vy[1], &vy[2]);
        swap(&k, .f32, sw, &vz[1], &vz[2]);
        swap(&k, .f32, sw, &vw[1], &vw[2]);
        for (0..sh.varyings) |j| swap(&k, .f32, sw, &vv[1][j], &vv[2][j]);
        // |area| (> 0 once valid)
        const nlo = k.op2(.isub, .u32, u(0), r(area.lo));
        const nhi = k.op2(.isub, .i32, r(k.op2(.isub, .i32, i(0), r(area.hi))), r(k.sel(.u32, r(k.cmp(.u32, .ne, r(area.lo), u(0))), u(1), u(0))));
        const alo = k.sel(.u32, r(neg), r(nlo), r(area.lo));
        const ahi = k.sel(.i32, r(neg), r(nhi), r(area.hi));
        // the box, in pixels whose centers (x * 16 + 8) it may hold
        const xmin = k.op2(.imin, .i32, r(k.op2(.imin, .i32, r(vx[0]), r(vx[1]))), r(vx[2]));
        const xmax = k.op2(.imax, .i32, r(k.op2(.imax, .i32, r(vx[0]), r(vx[1]))), r(vx[2]));
        const ymin = k.op2(.imin, .i32, r(k.op2(.imin, .i32, r(vy[0]), r(vy[1]))), r(vy[2]));
        const ymax = k.op2(.imax, .i32, r(k.op2(.imax, .i32, r(vy[0]), r(vy[1]))), r(vy[2]));
        const px0 = k.op2(.imax, .i32, r(k.op2(.shr, .i32, r(k.op2(.iadd, .i32, r(xmin), i(7))), u(4))), r(k.param(.i32, T_RECT)));
        const py0 = k.op2(.imax, .i32, r(k.op2(.shr, .i32, r(k.op2(.iadd, .i32, r(ymin), i(7))), u(4))), r(k.param(.i32, T_RECT + 1)));
        const px1 = k.op2(.imin, .i32, r(k.op2(.shr, .i32, r(k.op2(.isub, .i32, r(xmax), i(8))), u(4))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 2)), i(1))));
        const py1 = k.op2(.imin, .i32, r(k.op2(.shr, .i32, r(k.op2(.isub, .i32, r(ymax), i(8))), u(4))), r(k.op2(.isub, .i32, r(k.param(.i32, T_RECT + 3)), i(1))));
        const tri = k.op3(.imad, .u32, r(inst), r(ntri), r(t));
        const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(tri), r(k.param(.u32, T_SSTRIDE)))), u(2));
        const st = struct {
            fn w(kk: *kir.Kernel, b: u8, bs: V, word: u32, ty: kir.Ty, val: Arg) void {
                kk.store(ty, memAt(b, word * 4), r(bs), val);
            }
        }.w;
        st(&k, b_out, base, S_VALID, .u32, r(k.sel(.u32, r(valid), u(1), u(0))));
        st(&k, b_out, base, S_BOX, .i32, r(px0));
        st(&k, b_out, base, S_BOX + 1, .i32, r(py0));
        st(&k, b_out, base, S_BOX + 2, .i32, r(px1));
        st(&k, b_out, base, S_BOX + 3, .i32, r(py1));
        // the edges a -> b (0 -> 1, 1 -> 2, 2 -> 0): A = ay - by, B = bx - ax;
        // a pixel on an edge is in when A > 0, or A == 0 and B > 0
        for (0..3) |e| {
            const a = e;
            const b = (e + 1) % 3;
            const A = k.op2(.isub, .i32, r(vy[a]), r(vy[b]));
            const B = k.op2(.isub, .i32, r(vx[b]), r(vx[a]));
            const tie = k.op2(.por, .pred, r(k.cmp(.i32, .gt, r(A), i(0))), r(k.op2(.pand, .pred, r(k.cmp(.i32, .eq, r(A), i(0))), r(k.cmp(.i32, .gt, r(B), i(0))))));
            const w0: u32 = @intCast(S_EDGE + 5 * e);
            st(&k, b_out, base, w0, .i32, r(A));
            st(&k, b_out, base, w0 + 1, .i32, r(B));
            st(&k, b_out, base, w0 + 2, .i32, r(vx[a]));
            st(&k, b_out, base, w0 + 3, .i32, r(vy[a]));
            st(&k, b_out, base, w0 + 4, .i32, r(k.sel(.i32, r(tie), i(0), i(-1))));
        }
        st(&k, b_out, base, S_FRONT, .u32, r(k.sel(.u32, r(same), u(1), u(0))));
        // planes over pixel coordinates from vertex 0
        var fx: [3]V = undefined;
        var fy: [3]V = undefined;
        for (0..3) |n| {
            fx[n] = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(vx[n]))), f(1.0 / @as(f32, SUB)));
            fy[n] = k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(vy[n]))), f(1.0 / @as(f32, SUB)));
        }
        st(&k, b_out, base, S_XY, .f32, r(fx[0]));
        st(&k, b_out, base, S_XY + 1, .f32, r(fy[0]));
        const ex1 = k.op2(.fsub, .f32, r(fx[1]), r(fx[0]));
        const ey1 = k.op2(.fsub, .f32, r(fy[1]), r(fy[0]));
        const ex2 = k.op2(.fsub, .f32, r(fx[2]), r(fx[0]));
        const ey2 = k.op2(.fsub, .f32, r(fy[2]), r(fy[0]));
        // the determinant from the exact area (in pixels^2: / 256)
        const det = k.op2(.fmul, .f32, r(k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(k.cvt(.i32, .f32, .rne, r(ahi))), f(4294967296.0))), r(k.cvt(.u32, .f32, .rne, r(alo))))), f(1.0 / 256.0));
        const idet = k.div(f(1), r(k.sel(.f32, r(valid), r(det), f(1))));
        const Plane = struct {
            fn emit(kk: *kir.Kernel, bo: u8, bs: V, word: u32, v0: V, v1: V, v2: V, x1: V, y1: V, x2: V, y2: V, id: V) void {
                const d1 = kk.op2(.fsub, .f32, r(v1), r(v0));
                const d2 = kk.op2(.fsub, .f32, r(v2), r(v0));
                const ddx = kk.op2(.fmul, .f32, r(kk.op2(.fsub, .f32, r(kk.op2(.fmul, .f32, r(d1), r(y2))), r(kk.op2(.fmul, .f32, r(d2), r(y1))))), r(id));
                const ddy = kk.op2(.fmul, .f32, r(kk.op2(.fsub, .f32, r(kk.op2(.fmul, .f32, r(d2), r(x1))), r(kk.op2(.fmul, .f32, r(d1), r(x2))))), r(id));
                kk.store(.f32, memAt(bo, word * 4), r(bs), r(v0));
                kk.store(.f32, memAt(bo, (word + 1) * 4), r(bs), r(ddx));
                kk.store(.f32, memAt(bo, (word + 2) * 4), r(bs), r(ddy));
            }
        };
        Plane.emit(&k, b_out, base, S_Z, vz[0], vz[1], vz[2], ex1, ey1, ex2, ey2, idet);
        Plane.emit(&k, b_out, base, S_W, vw[0], vw[1], vw[2], ex1, ey1, ex2, ey2, idet);
        for (0..sh.varyings) |j| {
            const w0: u32 = @intCast(SREC + 3 * j);
            if (sh.flat & (@as(u32, 1) << @intCast(j)) != 0) {
                st(&k, b_out, base, w0, .f32, r(flat_v[j]));
                st(&k, b_out, base, w0 + 1, .f32, f(0));
                st(&k, b_out, base, w0 + 2, .f32, f(0));
            } else Plane.emit(&k, b_out, base, w0, vv[0][j], vv[1][j], vv[2][j], ex1, ey1, ex2, ey2, idet);
        }
    }
    k.endif();
    return k;
}

// ── Kernel 3: tiles ────────────────────────────────────────────────────────

const R_RECT = 0; // x0, y0, x1, y1 (exclusive)
const R_NTRI = 4;
const R_SSTRIDE = 5;
const R_C_STRIDE = 6; // the color image: words a row, top-down, height
const R_C_TOPDOWN = 7;
const R_C_HEIGHT = 8;
const R_SHIFT_R = 9; // byte shifts of red and blue (rgba8: 0, 16; bgra8: 16, 0)
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
pub const RASTER_PARAMS = 49;

/// bindings: 0 color (written), 1 depth (written when on), 2 triangle
/// records, 3 uniforms
pub fn rasterKernel(s: kir.Storage, p: *const Pipeline) kir.Kernel {
    var k = kir.Kernel.init(s, "gl_raster", .{ TILE, TILE, 1 });
    const b_c = k.binding();
    const b_d = k.binding();
    const b_t = k.binding();
    const b_uni = k.binding();
    const sh = p.shaders;
    const lx = k.tid(0);
    const ly = k.tid(1);
    const tx0 = k.op3(.imad, .i32, r(k.gid(0)), u(TILE), r(k.param(.i32, R_RECT)));
    const ty0 = k.op3(.imad, .i32, r(k.gid(1)), u(TILE), r(k.param(.i32, R_RECT + 1)));
    const px = k.op2(.iadd, .i32, r(tx0), r(lx));
    const py = k.op2(.iadd, .i32, r(ty0), r(ly));
    const inside = k.op2(.pand, .pred, r(k.cmp(.i32, .lt, r(px), r(k.param(.i32, R_RECT + 2)))), r(k.cmp(.i32, .lt, r(py), r(k.param(.i32, R_RECT + 3)))));
    // the pixel's place in the color and depth images (GL rows, maybe flipped)
    const rowOf = struct {
        fn f_(kk: *kir.Kernel, y: V, td: u16, h: u16) V {
            const flipped = kk.op2(.isub, .i32, r(kk.op2(.isub, .i32, r(kk.param(.i32, h)), i(1))), r(y));
            return kk.sel(.i32, r(kk.cmp(.u32, .ne, r(kk.param(.u32, td)), u(0))), r(flipped), r(y));
        }
    }.f_;
    const c_off = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(rowOf(&k, py, R_C_TOPDOWN, R_C_HEIGHT)), r(k.param(.u32, R_C_STRIDE)), r(px))), u(2));
    const d_on = k.cmp(.u32, .ne, r(k.param(.u32, R_DEPTH)), u(0));
    const d_off = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(rowOf(&k, py, R_D_TOPDOWN, R_D_HEIGHT)), r(k.param(.u32, R_D_STRIDE)), r(px))), u(2));
    // the pixel and its depth, loaded once
    const old_c = k.reg(.u32);
    const old_d = k.reg(.u32);
    k.set(old_c, .mov, u(0), no, no);
    k.set(old_d, .mov, u(0), no, no);
    k.ifp(r(inside));
    k.setAux(old_c, .ld, r(c_off), no, no, @bitCast(kir.global(b_c, 32)));
    k.ifp(r(d_on));
    k.setAux(old_d, .ld, r(d_off), no, no, @bitCast(kir.global(b_d, 32)));
    k.endif();
    k.endif();
    const shift_r = k.param(.u32, R_SHIFT_R);
    const shift_b = k.param(.u32, R_SHIFT_B);
    const chan = struct {
        fn f_(kk: *kir.Kernel, word: V, sh_: Arg) V {
            const byte = kk.op3(.bfe, .u32, r(word), sh_, u(8));
            return kk.div(r(kk.cvt(.u32, .f32, .rne, r(byte))), f(255));
        }
    }.f_;
    var dst: [4]V = undefined;
    for (&dst) |*d| d.* = k.reg(.f32);
    k.set(dst[0], .mov, r(chan(&k, old_c, r(shift_r))), no, no);
    k.set(dst[1], .mov, r(chan(&k, old_c, u(8))), no, no);
    k.set(dst[2], .mov, r(chan(&k, old_c, r(shift_b))), no, no);
    k.set(dst[3], .sel, f(1), r(chan(&k, old_c, u(24))), r(k.cmp(.u32, .ne, r(k.param(.u32, R_NO_ALPHA)), u(0))));
    const depth = k.reg(.u32);
    k.set(depth, .@"and", r(old_d), u(0x00ff_ffff), no);
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
    const tri = k.reg(.u32);
    k.set(tri, .mov, u(0), no, no);
    k.loop();
    {
        k.brk(r(k.cmp(.u32, .ge, r(tri), r(ntri))));
        const tc = k.mov(.u32, r(tri));
        k.set(tri, .iadd, r(tri), u(1), no);
        const base = k.op2(.shl, .u32, r(k.op2(.imul, .u32, r(tc), r(sstride))), u(2));
        const ld = struct {
            fn w(kk: *kir.Kernel, b: u8, bs: V, word: u32, ty: kir.Ty) V {
                return kk.load(ty, memAt(b, word * 4), r(bs));
            }
        }.w;
        // a triangle not drawn, or whose box misses the tile: the next
        // (the same for the whole group)
        const valid = ld(&k, b_t, base, S_VALID, .u32);
        const bx0 = ld(&k, b_t, base, S_BOX, .i32);
        const by0 = ld(&k, b_t, base, S_BOX + 1, .i32);
        const bx1 = ld(&k, b_t, base, S_BOX + 2, .i32);
        const by1 = ld(&k, b_t, base, S_BOX + 3, .i32);
        var miss = k.cmp(.u32, .eq, r(valid), u(0));
        miss = k.op2(.por, .pred, r(miss), r(k.cmp(.i32, .lt, r(bx1), r(tx0))));
        miss = k.op2(.por, .pred, r(miss), r(k.cmp(.i32, .gt, r(bx0), r(tx1))));
        miss = k.op2(.por, .pred, r(miss), r(k.cmp(.i32, .lt, r(by1), r(ty0))));
        miss = k.op2(.por, .pred, r(miss), r(k.cmp(.i32, .gt, r(by0), r(ty1))));
        k.cont(r(miss));
        // coverage: each edge's value at the tile's first center in 64
        // bits; a tile wholly outside one edge, the next triangle; else
        // clamped, and each pixel's in 32 bits
        var covered = inside;
        var out_tile = k.mov(.pred, u(0));
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
            covered = k.op2(.pand, .pred, r(covered), r(k.cmp(.i32, .ge, r(k.op2(.iadd, .i32, r(ev), r(bias))), i(0))));
        }
        k.cont(r(out_tile));
        k.ifp(r(covered));
        {
            const X = k.op2(.fadd, .f32, r(k.cvt(.i32, .f32, .rne, r(px))), f(0.5));
            const Y = k.op2(.fadd, .f32, r(k.cvt(.i32, .f32, .rne, r(py))), f(0.5));
            const dX = k.op2(.fsub, .f32, r(X), r(ld(&k, b_t, base, S_XY, .f32)));
            const dY = k.op2(.fsub, .f32, r(Y), r(ld(&k, b_t, base, S_XY + 1, .f32)));
            const plane = struct {
                fn at(kk: *kir.Kernel, b: u8, bs: V, word: u32, dx: V, dy: V) V {
                    const a0 = kk.load(.f32, memAt(b, word * 4), r(bs));
                    const gx = kk.load(.f32, memAt(b, (word + 1) * 4), r(bs));
                    const gy = kk.load(.f32, memAt(b, (word + 2) * 4), r(bs));
                    return kk.op2(.fadd, .f32, r(kk.op2(.fadd, .f32, r(a0), r(kk.op2(.fmul, .f32, r(gx), r(dx))))), r(kk.op2(.fmul, .f32, r(gy), r(dy))));
                }
            }.at;
            const z = plane(&k, b_t, base, S_Z, dX, dY);
            // (outside the depth range: clipped)
            var pass = k.op2(.pand, .pred, r(k.cmp(.f32, .ge, r(z), r(k.param(.f32, R_ZMIN)))), r(k.cmp(.f32, .le, r(z), r(k.param(.f32, R_ZMAX)))));
            const dz = k.cvt(.f32, .u32, .rne, r(k.op2(.fmul, .f32, r(k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(z), f(0))), f(1))), f(16777215.0))));
            const func = k.param(.u32, R_DFUNC);
            const bitOn = struct {
                fn f_(kk: *kir.Kernel, w: V, bit: u32) V {
                    return kk.cmp(.u32, .ne, r(kk.op2(.@"and", .u32, r(w), u(bit))), u(0));
                }
            }.f_;
            const lt = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(dz), r(depth))), r(bitOn(&k, func, 1)));
            const eq = k.op2(.pand, .pred, r(k.cmp(.u32, .eq, r(dz), r(depth))), r(bitOn(&k, func, 2)));
            const gt = k.op2(.pand, .pred, r(k.cmp(.u32, .gt, r(dz), r(depth))), r(bitOn(&k, func, 4)));
            const dpass = k.op2(.por, .pred, r(k.op2(.por, .pred, r(lt), r(eq))), r(gt));
            pass = k.op2(.pand, .pred, r(pass), r(k.sel(.pred, r(d_on), r(dpass), u(1))));
            k.ifp(r(pass));
            {
                const iw = plane(&k, b_t, base, S_W, dX, dY);
                const wv = k.div(f(1), r(iw));
                var io = FragmentIO{ .uniforms = b_uni };
                for (0..sh.varyings) |j| {
                    const val = plane(&k, b_t, base, @intCast(SREC + 3 * j), dX, dY);
                    io.varying[j] = if (sh.flat & (@as(u32, 1) << @intCast(j)) != 0) val else k.op2(.fmul, .f32, r(val), r(wv));
                }
                io.frag_coord = .{ X, Y, z, iw };
                io.front_facing = k.cmp(.u32, .ne, r(ld(&k, b_t, base, S_FRONT, .u32)), u(0));
                sh.fragment(sh.ctx, &k, &io);
                const live = if (io.discard == .none) k.mov(.pred, u(1)) else k.op1(.pnot, .pred, r(io.discard));
                k.ifp(r(live));
                {
                    var src: [4]V = undefined;
                    for (0..4) |c| src[c] = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(io.color[c]), f(0))), f(1));
                    const out = blend(&k, src, dst);
                    for (0..4) |c| k.set(dst[c], .mov, r(out[c]), no, no);
                    k.set(touched, .mov, u(1), no, no);
                    k.ifp(r(k.op2(.pand, .pred, r(d_on), r(k.cmp(.u32, .ne, r(k.param(.u32, R_DWRITE)), u(0))))));
                    k.set(depth, .mov, r(dz), no, no);
                    k.endif();
                }
                k.endif();
            }
            k.endif();
        }
        k.endif();
    }
    k.endloop();
    // the pixel and its depth, stored once (the masked channels kept)
    k.ifp(r(k.op2(.pand, .pred, r(inside), r(k.cmp(.u32, .ne, r(touched), u(0))))));
    {
        const pack = struct {
            fn f_(kk: *kir.Kernel, c: V, sh_: Arg) V {
                const b = kk.cvt(.f32, .u32, .rne, r(kk.op2(.fmul, .f32, r(c), f(255))));
                return kk.op2(.shl, .u32, r(b), sh_);
            }
        }.f_;
        var word = k.op2(.@"or", .u32, r(pack(&k, dst[0], r(shift_r))), r(pack(&k, dst[1], u(8))));
        word = k.op2(.@"or", .u32, r(word), r(pack(&k, dst[2], r(shift_b))));
        word = k.op2(.@"or", .u32, r(word), r(pack(&k, dst[3], u(24))));
        const keep = k.param(.u32, R_KEEP);
        const merged = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old_c), r(keep))), r(k.op2(.@"and", .u32, r(word), r(k.op1(.not, .u32, r(keep))))));
        k.store(.u32, kir.global(b_c, 32), r(c_off), r(merged));
        k.ifp(r(k.op2(.pand, .pred, r(d_on), r(k.cmp(.u32, .ne, r(k.param(.u32, R_DWRITE)), u(0))))));
        k.store(.u32, kir.global(b_d, 32), r(d_off), r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old_d), u(0xff00_0000))), r(depth))));
        k.endif();
    }
    k.endif();
    return k;
}

/// GL's blending of `src` over `dst` (both clamped to 0..1): every factor
/// as c + ks*s + kd*d + ksa*s.a + kda*d.a, SRC_ALPHA_SATURATE apart, the
/// five equations; off: src. The result clamped to 0..1.
fn blend(k: *kir.Kernel, src: [4]V, dst: [4]V) [4]V {
    const on = k.cmp(.u32, .ne, r(k.param(.u32, R_BLEND)), u(0));
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

/// The vertex kernel's parameters.
pub fn vertexParams(d: *const Draw, out: []u32) []u32 {
    const n = V_ATTR + MAX_ATTRS * V_ATTR_WORDS;
    @memset(out[0..n], 0);
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

pub fn setupParams(d: *const Draw, out: []u32) []u32 {
    const rect = d.rect;
    const p = [_]u32{ d.triangles(), d.count, @intFromEnum(d.topology), d.cull, @intFromBool(d.front_ccw), d.pipe.vstride, d.pipe.sstride, rect.x0, rect.y0, rect.x1, rect.y1 };
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

pub fn rasterParams(d: *const Draw, out: []u32) []u32 {
    @memset(out[0..RASTER_PARAMS], 0);
    const rect = d.rect;
    out[R_RECT] = rect.x0;
    out[R_RECT + 1] = rect.y0;
    out[R_RECT + 2] = rect.x1;
    out[R_RECT + 3] = rect.y1;
    out[R_NTRI] = d.triangles() * d.instances;
    out[R_SSTRIDE] = d.pipe.sstride;
    out[R_C_STRIDE] = d.color.stride / 4;
    out[R_C_TOPDOWN] = @intFromBool(d.color.top_down);
    out[R_C_HEIGHT] = d.color.height;
    out[R_SHIFT_R] = if (d.color.format == .bgra8) 16 else 0;
    out[R_SHIFT_B] = if (d.color.format == .bgra8) 0 else 16;
    out[R_KEEP] = d.keep;
    out[R_NO_ALPHA] = @intFromBool(d.color.no_alpha);
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
    if (d.blend) |b| {
        out[R_BLEND] = 1;
        out[R_EQ_RGB] = @intFromEnum(b.eq_rgb);
        out[R_EQ_A] = @intFromEnum(b.eq_a);
        out[R_SATURATE] = @intFromBool(b.saturate);
        factorWords(b.src_rgb, true, out[R_SRC_RGB..]);
        factorWords(b.dst_rgb, true, out[R_DST_RGB..]);
        factorWords(b.src_a, false, out[R_SRC_A..]);
        factorWords(b.dst_a, false, out[R_DST_A..]);
    }
    return out[0..RASTER_PARAMS];
}
