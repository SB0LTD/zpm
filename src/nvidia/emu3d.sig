//! @zpm/nvidia emu3d — the emulated RTX's 3D engine (BLACKWELL_B, class
//! 0xce97): what EmuDevice does with the methods nvidia/draw.sig sends.
//!
//! It keeps the methods' values as the engine does, latches a constant
//! buffer where one is bound, and at a draw reads the whole state the way
//! the hardware would: the color target, the viewport, the scissor, the
//! blend, the two stages' programs (each a header and the code after it,
//! read from GPU memory and decoded), the texture pools. The vertex
//! program runs in sm120_emu for each vertex; the triangles of the strip
//! are walked at pixel centres with the top-left rule on a 1/256 pixel
//! grid; each covered pixel's attribute words are carried as the pixel
//! program's header says, the pixel program runs, its texture
//! instructions sample through the header and the sampler its handle
//! names, and the color is blended into the target's bytes.
//!
//! The arithmetic is gpu/draw.sig's (the rules every GPU's pipeline is
//! held to): centres at halves, unnormalized texels clamped to the edge,
//! a blend in floats rounded to the nearest of 256 steps.
//!
//! GL's draws too (gl3d.sig, gpu/nvidia_gl): triangles, strips and fans of
//! any length (the vertex program run on up to VERTICES vertices at a
//! time, a primitive's that came before run again), instances, the
//! provoking vertex first or last, GL's blend factors and equations and
//! the constant colour, the channels written, RG8 targets, the depth's
//! clip volume (-w..w or 0..w: a pixel whose depth falls outside is not
//! drawn) and the depth carried to the pixel program in window units; a
//! pixel program that writes the depth (its header's bit, its register
//! after the colours' and the sample mask's) has it tested and written in
//! place of the plane's, clamped to 0..1.
//!
//! It is as strict as it can be: state the renderer does not send, or
//! sends with another value, is a refused stream with the reason kept
//! (`why`), so a renderer that drifts from what NVK does fails here and
//! not only on the Legion. That includes the case NVK names as raising
//! "Out Of Range Address": a vertex program storing a varying the pixel
//! program does not read.
//!
//! What it does not know: whether the real engine needs every value it
//! insists on, or wants more. Nothing here has been compared with the
//! hardware yet.
//!
//! Allocation-free: an Engine is the caller's (about 1 MB, static).

const std = @import("std");
const emu = @import("sm120_emu.sig");
const sph = @import("sph.sig");
const qmd = @import("qmd.sig");
const gr = @import("draw.sig");
const gl3d = @import("gl3d.sig");

/// The class's methods, by address / 4.
const METHODS = 0x1000;
const GROUPS = 5;
const SLOTS = 16;
/// The vertices the vertex program runs on at once (a draw's primitives
/// go by in runs of as many as their vertices fit).
const VERTICES = 96;
/// A program's instructions, at most.
const CODE = emu.MAX_INSTRS;
/// The vertices clipping a triangle against w > 0 makes, at most.
const CLIPPED = 2;
/// The plane a triangle is clipped against: w at least this.
const W_MIN: f64 = 1.0 / 1048576.0; // (2^-20: the same in f32)

const POSITION = sph.ATTR_POSITION / 4;
const GENERIC = sph.ATTR_GENERIC / 4;
const GENERIC_END = GENERIC + 4 * sph.GENERICS;

/// What the engine reads GPU memory and runs programs with: the device's.
pub const Host = struct {
    mem: emu.Memory,
    work: *emu.Work,
};

const Bound = struct { valid: bool = false, va: u64 = 0, size: u32 = 0 };

const Target = struct {
    bytes: []u8,
    /// Bytes a row (rows of bytes), or across (block linear: whole GOBs).
    pitch: u32,
    /// Pixels a row and rows.
    width: u32,
    height: u32,
    format: Fmt,
    /// Block linear, blocks of 2^gobs GOBs high (null: rows of bytes).
    gobs: ?u3 = null,
};

/// A colour target's pixels: the renderer's three, and GL's RG8.
const Fmt = enum { rgba8, bgra8, r8, rg8 };

const Clip = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

/// The depth target as gl3d sends it: block linear, 32-bit words, depth
/// in bits 0..23 (X8Z24, or S8Z24 with STENCIL_IS_SEPARATE), and its
/// stencil plane (S8, Blackwell's 8-bit GOBs) when there is one.
const ZT = struct { bytes: []u8, pitch: u32, width: u32, height: u32, gobs: u3, stencil: ?[]u8 = null, s_pitch: u32 = 0 };
const STENCIL_TWO_SIDE = gl3d.SET_TWO_SIDED_STENCIL_TEST;

/// A texture as its header and its sampler describe it.
const Tex = struct {
    bytes: []const u8,
    pitch: u32,
    width: u32,
    height: u32,
    /// Bytes a texel: 4 (A8B8G8R8) or 1 (R8).
    size: u32,
    /// Where each of x, y, z, w comes from (the header's sources).
    source: [4]u3,
    linear: bool,
};

pub const Engine = struct {
    methods: [METHODS]u32 = @splat(0),
    /// Each group's slots, as BIND_GROUP_CONSTANT_BUFFER latched them.
    bound: [GROUPS][SLOTS]Bound = @splat(@splat(.{})),
    /// Why the last stream was refused, in a sentence ("": it was not).
    why: []const u8 = "",
    draws: u64 = 0,
    pixels: u64 = 0,
    stats: emu.Stats = .{},
    // A draw's working storage.
    vin: [VERTICES][emu.ATTR_WORDS]u32 = undefined,
    /// The run's vertices' outputs, then those clipping makes (CLIPPED a
    /// triangle at most, made again for each).
    vout: [VERTICES + CLIPPED][emu.ATTR_WORDS]u32 = undefined,
    vstored: [VERTICES][emu.ATTR_WORDS / 32]u32 = undefined,
    win: [VERTICES + CLIPPED][2]i64 = undefined,
    vp: [4]f64 = .{ 0, 0, 0, 0 },
    pin: [emu.MAX_THREADS][emu.ATTR_WORDS]u32 = undefined,
    killed: [emu.MAX_THREADS]bool = undefined,
    /// Each queued pixel's window depth, and whether its triangle faces
    /// front (the pixel program's facing, the stencil's two faces).
    zw: [emu.MAX_THREADS]f32 = undefined,
    front: [emu.MAX_THREADS]bool = undefined,
    /// A queued pixel the triangle does not cover: run (a quad's helper,
    /// for its neighbours' derivatives), never written.
    helper: [emu.MAX_THREADS]bool = undefined,
    at: [emu.MAX_THREADS][2]u32 = undefined,
    queued: u32 = 0,
    /// Each stage's code, read once a draw.
    vcode: [CODE * 2]u64 = undefined,
    pcode: [CODE * 2]u64 = undefined,
    vn: usize = 0,
    pn: usize = 0,
    /// The draw's provoking vertex is the last (else the first), and its
    /// depth range for the pixels (window units).
    zlo: f64 = 0,
    zhi: f64 = 1,
    zscale: f64 = 1,
    zoffset: f64 = 0,
    vhead: [sph.WORDS]u32 = undefined,
    phead: [sph.WORDS]u32 = undefined,
    host: Host = undefined,

    fn refuse(g: *Engine, why: []const u8) error{BadStream} {
        g.why = why;
        return error.BadStream;
    }

    fn need(g: *Engine, ok: bool, why: []const u8) error{BadStream}!void {
        if (!ok) return g.refuse(why);
    }

    fn reg(g: *const Engine, m: u32) u32 {
        return g.methods[m / 4];
    }

    fn float(g: *const Engine, m: u32) f64 {
        return @as(f32, @bitCast(g.methods[m / 4]));
    }

    /// One method's data, as the engine takes it.
    pub fn method(g: *Engine, host: Host, m: u32, v: u32) anyerror!void {
        if (m / 4 >= METHODS) return g.refuse("a method past the class's");
        // (the ways of drawing nothing here models: BEGIN and END, the
        // older array draw, a clear, a macro)
        if (m == 0x1618 or m == 0x1614 or m == 0x0d78 or m == 0x19d0 or m == 0x1214 or m == 0x1218 or m >= 0x3800)
            return g.refuse("BEGIN, DRAW_VERTEX_ARRAY, CLEAR_SURFACE or a macro: not modelled (the renderer draws with DRAW_VERTEX_ARRAY_BEGIN_END)");
        g.methods[m / 4] = v;
        const bind = gr.BIND_GROUP_CONSTANT_BUFFER;
        if (m >= bind and m < bind + 32 * GROUPS and (m - bind) % 32 == 0) return g.bindBuffer((m - bind) / 32, v);
        if (m == gr.DRAW_VERTEX_ARRAY_BEGIN_END_B) {
            g.host = host;
            return g.draw(g.reg(gr.DRAW_VERTEX_ARRAY_BEGIN_END_A), v, false);
        }
        if (m == gl3d.DRAW_INDEX_BUFFER_BEGIN_END_B) {
            g.host = host;
            return g.draw(g.reg(gl3d.DRAW_INDEX_BUFFER_BEGIN_END_A), v, true);
        }
    }

    /// BIND_GROUP_CONSTANT_BUFFER: the selector's buffer latched in the
    /// group's slot, or the slot emptied.
    fn bindBuffer(g: *Engine, group: u32, v: u32) error{BadStream}!void {
        const slot = (v >> 4) & 0x1f;
        if (slot >= SLOTS) return g.refuse("a constant buffer slot past 15");
        if (v & 1 == 0) {
            g.bound[group][slot] = .{};
            return;
        }
        const sel = gr.SET_CONSTANT_BUFFER_SELECTOR_A;
        const size = g.reg(sel) & 0x1_ffff;
        const va = @as(u64, g.reg(sel + 4) & 0xff) << 32 | g.reg(sel + 8);
        // (NVK: a buffer's address a multiple of 64 bytes, 64 KiB at most)
        if (size == 0 or size > 0x1_0000 or va % 64 != 0) return g.refuse("a constant buffer bound with no size, more than 64 KiB, or an address that is not a multiple of 64");
        g.bound[group][slot] = .{ .valid = true, .va = va, .size = size };
    }

    /// The state a draw needs as the renderer sends it (NVK's values): a
    /// difference is refused, not guessed at.
    fn validate(g: *Engine) error{BadStream}!void {
        try g.need(g.reg(gr.SET_RENDER_ENABLE_C) == 1, "rendering is not enabled (SET_RENDER_ENABLE_C)");
        try g.need(g.reg(gr.CHECK_SPH_VERSION) == 0x0003_0003 and g.reg(gr.CHECK_AAM_VERSION) == 0x0002_0002, "the header and attribute map versions were not checked (CHECK_SPH_VERSION, CHECK_AAM_VERSION)");
        const cts = g.reg(gr.SET_CT_SELECT);
        try g.need(cts & 0xf >= 1 and cts & 0xf <= 8 and cts & ~@as(u32, 0xf) == gl3d.ctSelect(0) and g.reg(gr.SET_CT_MRT_ENABLE) == 1, "not 1 to 8 color targets, slot t target t (SET_CT_SELECT, SET_CT_MRT_ENABLE)");
        try g.need(g.reg(gr.SET_ZT_SELECT) <= 1 and g.reg(gr.SET_DEPTH_BOUNDS_TEST) == 0, "more than one depth target, or a depth bounds test: not modelled");
        try g.need(g.reg(gr.SET_ZT_SELECT) == 1 or (g.reg(gr.SET_DEPTH_TEST) == 0 and g.reg(gr.SET_STENCIL_TEST) == 0), "a depth or stencil test with no depth target (SET_ZT_SELECT)");
        try g.need(g.reg(gr.SET_STENCIL_TEST) == 0 or g.reg(gl3d.SET_ZT_A + 8) & gl3d.ZT_STENCIL_IS_SEPARATE != 0, "a stencil test with no stencil plane (X8Z24 has none)");
        try g.need(g.reg(STENCIL_TWO_SIDE) <= 1, "SET_TWO_SIDED_STENCIL_TEST neither on nor off");
        try g.need(g.reg(gr.SET_RASTER_ENABLE) == 1, "the rasterizer is off (SET_RASTER_ENABLE)");
        try g.need(g.reg(gr.SET_ANTI_ALIAS) == 0 and g.reg(gr.SET_ANTI_ALIAS_SAMPLE_POSITIONS) == 0x8888_8888, "more than one sample, or a sample not at the pixel's centre");
        try g.need(g.reg(gr.SET_VIEWPORT_PIXEL) == 0 and g.reg(gr.SET_WINDOW_ORIGIN) == 0, "pixel centres not at halves, or the origin not the top left");
        try g.need(g.reg(gr.SET_VIEWPORT_SCALE_OFFSET) == 1 and g.reg(gr.SET_VIEWPORT_COORDINATE_SWIZZLE) == 0x6420, "no viewport transform, or a swizzled one");
        try g.need(g.reg(gr.SET_VIEWPORT_Z_CLIP) <= 1, "a depth clip range other than -w..w or 0..w");
        try g.need(g.reg(gr.SET_PROVOKING_VERTEX) <= 1, "a provoking vertex other than the first or the last");
        try g.need(g.reg(gr.SET_WINDOW_OFFSET_X) == 0 and g.reg(gr.SET_WINDOW_OFFSET_X + 4) == 0 and g.reg(gr.SET_WINDOW_CLIP_ENABLE) == 0, "a window offset or window clips: not modelled");
        try g.need(g.reg(gr.SET_FRONT_POLYGON_MODE) == 0x1b02 and g.reg(gr.SET_FRONT_POLYGON_MODE + 4) == 0x1b02, "polygons not filled: not modelled");
        try g.need(g.reg(gr.OGL_SET_CULL) == 0 or switch (g.reg(gl3d.OGL_SET_CULL_FACE)) {
            gl3d.CULL_FRONT, gl3d.CULL_BACK, gl3d.CULL_FRONT_AND_BACK => true,
            else => false,
        }, "a culled face other than FRONT, BACK or FRONT_AND_BACK");
        try g.need(g.reg(gr.OGL_SET_FRONT_FACE) == gl3d.FRONT_CW or g.reg(gr.OGL_SET_FRONT_FACE) == gl3d.FRONT_CCW, "a front face other than CW or CCW");
        const topo = g.reg(gr.SET_PRIMITIVE_TOPOLOGY);
        try g.need(g.reg(gr.SET_PRIMITIVE_TOPOLOGY_CONTROL) == 1 and topo >= 4 and topo <= 6, "not triangles, a strip or a fan by SET_PRIMITIVE_TOPOLOGY");
        try g.need(g.reg(gr.SET_DRAW_CONTROL_A) == gr.DRAW_CONTROL and g.reg(gr.SET_DRAW_CONTROL_A + 4) >= 1, "SET_DRAW_CONTROL is not instances from the first");
        try g.need(g.reg(gr.SET_DA_OUTPUT) == 0x1000 and g.reg(gr.SET_VERTEX_ID_BASE) == 0 and g.reg(gr.SET_GLOBAL_BASE_VERTEX_INDEX) == 0 and g.reg(gr.SET_GLOBAL_BASE_VERTEX_INDEX + 4) == 0, "the vertex's index would not count from the draw's first vertex");
        for (0..16) |j| {
            const n: u32 = @intCast(j);
            try g.need(g.reg(gr.SET_VERTEX_STREAM_A_FORMAT + 16 * n) & 0x1000 == 0 and g.reg(gr.SET_VERTEX_STREAM_B_FORMAT + 16 * n) & 0x1000 == 0, "a vertex stream is on: not modelled");
        }
        try g.need(g.reg(gr.SET_BLEND_STATE_PER_TARGET) == 1 and g.reg(gr.SET_COLOR_CLAMP) == 1 and g.reg(gr.SET_LOGIC_OP) == 0 and g.reg(gr.SET_ALPHA_TEST) == 0, "the color write is not: clamped, per-target blend state, no logic op, no alpha test");
        for (0..cts & 0xf) |ti| try g.need(g.reg(gr.SET_CT_WRITE + 4 * @as(u32, @intCast(ti))) & ~@as(u32, 0x1111) == 0, "a target's channels not each on or off (SET_CT_WRITE)");
        for ([_]u32{ 0, 2, 3, 4 }) |j| try g.need(g.reg(gr.SET_PIPELINE_SHADER + 64 * j) & 1 == 0, "a stage other than the vertex and the pixel one is on: not modelled");
    }

    /// Color target 0: rows of bytes, where memory is.
    fn target(g: *Engine) error{BadStream}!Target {
        return try g.targetAt(0) orelse g.refuse("color target 0 is off (format 0)");
    }

    /// Color target `i` (null: off, its format 0): rows of bytes, where
    /// memory is.
    fn targetAt(g: *Engine, i: u32) error{BadStream}!?Target {
        const a = gr.SET_COLOR_TARGET_A + 64 * i;
        if (g.reg(a + 16) == 0) return null;
        const va = @as(u64, g.reg(a) & 0xff) << 32 | g.reg(a + 4);
        const pitch = g.reg(a + 8);
        const height = g.reg(a + 12);
        const format: Fmt = switch (g.reg(a + 16)) {
            0xcf => .bgra8,
            0xd5 => .rgba8,
            0xf3 => .r8,
            0xea => .rg8,
            else => return g.refuse("a color target format the renderer does not use"),
        };
        try g.need(g.reg(a + 24) == 1 and g.reg(a + 28) == 0 and g.reg(a + 32) == 0, "the color target is not one layer");
        try g.need(g.reg(gr.SET_COLOR_COMPRESSION + 4 * i) == 0, "color compression on plain memory");
        const mem = g.reg(a + 20);
        if (mem != gr.TARGET_MEMORY_PITCH) {
            // block linear (NVK's: one GOB wide and deep, the width in
            // pixels), in Turing2D's GOBs as the depth target
            try g.need(mem & ~@as(u32, 0xf0) == 0 and (mem >> 4) & 0xf <= 5, "the color target is neither rows of bytes (LAYOUT_PITCH) nor block linear one GOB wide and deep");
            const gobs: u3 = @intCast((mem >> 4) & 0xf);
            const across = pitch * pixelBytes(format);
            try g.need(va % 512 == 0 and across % 64 == 0 and pitch != 0 and height != 0, "a block-linear color target not on a GOB, or its rows not whole GOBs across");
            const rows_per_block = @as(u32, 8) << gobs;
            const size = @as(usize, across / 64) * ((height + rows_per_block - 1) / rows_per_block) * (@as(usize, 512) << gobs);
            const bytes = g.host.mem.find(va, size) orelse return g.refuse("the color target's memory is not mapped");
            return .{ .bytes = bytes, .pitch = across, .width = pitch, .height = height, .format = format, .gobs = gobs };
        }
        // (NVK: the hardware "gets grumpy" otherwise)
        try g.need(va % 128 == 0 and pitch % 128 == 0 and pitch != 0 and height != 0, "the color target's address or its rows are not multiples of 128 bytes");
        const bytes = g.host.mem.find(va, @as(usize, pitch) * height) orelse return g.refuse("the color target's memory is not mapped");
        return .{ .bytes = bytes, .pitch = pitch, .width = pitch / pixelBytes(format), .height = height, .format = format };
    }

    /// Target i's blend (null: off), as its SET_BLEND and per-target state
    /// say.
    fn blendAt(g: *Engine, i: u32) error{BadStream}!?Blend {
        if (g.reg(gr.SET_BLEND + 4 * i) & 1 == 0) return null;
        const b = gr.SET_BLEND_PER_TARGET_SEPARATE_FOR_ALPHA + 32 * i;
        try g.need(g.reg(b) == 1, "the alpha's blend not separate (SET_BLEND_PER_TARGET_SEPARATE_FOR_ALPHA)");
        var x = Blend{ .ops = undefined, .constant = undefined };
        for (0..6) |k| {
            x.ops[k] = g.reg(b + 4 + 4 * @as(u32, @intCast(k)));
            const ok = if (k % 3 == 0) equationOk(x.ops[k]) else factorOk(x.ops[k]);
            try g.need(ok, "a blend factor or equation that is not one of GL's");
        }
        for (0..4) |k| x.constant[k] = @floatCast(g.float(gr.SET_BLEND_CONST_RED + 4 * @as(u32, @intCast(k))));
        return x;
    }

    /// The colour targets' layouts as the hardware takes them: all alike,
    /// and block linear when a depth target is selected. A pitch colour
    /// target beside a depth target is the class's data error
    /// RT_LINEAR_WITH_ZETA: the Legion's RTX lost its channel to it (Xid
    /// 69, pc-all's drawtest step 4).
    fn layoutsAgree(g: *Engine, t: Target) error{BadStream}!void {
        try g.need(g.reg(gr.SET_ZT_SELECT) == 0 or t.gobs != null, "RT_LINEAR_WITH_ZETA: a depth target beside a color target of rows of bytes (LAYOUT_PITCH); the RTX refuses the draw (class error, Xid 69)");
        for (1..g.reg(gr.SET_CT_SELECT) & 0xf) |ti| {
            const x = (try g.targetAt(@intCast(ti))) orelse continue;
            try g.need((x.gobs == null) == (t.gobs == null), "color targets of both layouts in one draw (rows of bytes and block linear)");
        }
    }

    /// The depth target, when one is selected, as SET_ZT_A .. and
    /// SET_ZT_SIZE_A .. say: block linear (Turing2D's 32-bit GOBs), X8Z24,
    /// or S8Z24 with its stencil the SET_ST_* plane (Blackwell's 8-bit
    /// GOBs). A combined depth-stencil target (the stencil in the depth's
    /// words: Z24S8, or S8Z24 without STENCIL_IS_SEPARATE) is refused as
    /// the RTX refused it: pc-full2's first draw with one lost the channel
    /// (GSP-RM: class 0xce97, method 0x274 data 6, error code 0x13, Xid
    /// 69); NVK never sends one on Blackwell (nvk_use_separate_zs).
    fn depthTarget(g: *Engine) error{BadStream}!?ZT {
        if (g.reg(gr.SET_ZT_SELECT) == 0) return null;
        const a = gl3d.SET_ZT_A;
        const va = @as(u64, g.reg(a) & 0xff) << 32 | g.reg(a + 4);
        const fmt = g.reg(a + 8);
        const separate = fmt == gl3d.ZT_S8Z24 | gl3d.ZT_STENCIL_IS_SEPARATE;
        try g.need(fmt == gl3d.ZT_X8Z24 or separate, "a depth target whose stencil shares its words (Z24S8, or S8Z24 without STENCIL_IS_SEPARATE): Blackwell refuses the draw (class error 0x13 at the draw, Xid 69: pc-full2); X8Z24, or S8Z24 with its stencil a plane of its own");
        const bs = g.reg(a + 12);
        try g.need(bs & 0xf == 0 and (bs >> 8) & 0xf == 0 and (bs >> 4) & 0xf <= 5, "a depth target's blocks not one GOB wide and deep");
        const gobs: u3 = @intCast((bs >> 4) & 0xf);
        const w = g.reg(gl3d.SET_ZT_SIZE_A);
        const h = g.reg(gl3d.SET_ZT_SIZE_A + 4);
        const c = g.reg(gl3d.SET_ZT_SIZE_A + 8);
        try g.need(w != 0 and h != 0 and (c == 1 or c == 0x1_0001), "a depth target with no size, or more than one layer");
        try g.need(va % 512 == 0, "a depth target not on a GOB");
        const pitch = (w * 4 + 63) / 64 * 64;
        const rows_per_block = @as(u32, 8) << gobs;
        const blocks_down = (h + rows_per_block - 1) / rows_per_block;
        const bytes = @as(usize, pitch / 64) * blocks_down * (@as(usize, 512) << gobs);
        const mem = g.host.mem.find(va, bytes) orelse return g.refuse("the depth target's memory is not mapped");
        var z = ZT{ .bytes = mem, .pitch = pitch, .width = w, .height = h, .gobs = gobs };
        if (separate) {
            const st = gl3d.SET_ST_A;
            const sva = @as(u64, g.reg(st) & 0xff) << 32 | g.reg(st + 4);
            try g.need(g.reg(st + 8) == bs and sva % 512 == 0, "a stencil plane not on a GOB, or its blocks not the depth's");
            const sw = g.reg(gl3d.SET_ST_SIZE_A);
            try g.need(sw >= w and sw % 64 == 0 and g.reg(gl3d.SET_ST_SIZE_A + 4) >= h, "a stencil plane narrower or shorter than the depth, or not whole GOBs across");
            const sbytes = @as(usize, sw / 64) * blocks_down * (@as(usize, 512) << gobs);
            z.stencil = g.host.mem.find(sva, sbytes) orelse return g.refuse("the stencil plane's memory is not mapped");
            z.s_pitch = sw;
        }
        return z;
    }

    /// Where pixels may be written: the surface's clip, the viewport's,
    /// the scissor (when on), the target.
    fn clipOf(g: *const Engine, t: Target) Clip {
        var c = Clip{ .x0 = 0, .y0 = 0, .x1 = t.width, .y1 = t.height };
        const both = [_][2]u32{
            .{ g.reg(gr.SET_SURFACE_CLIP_HORIZONTAL), g.reg(gr.SET_SURFACE_CLIP_HORIZONTAL + 4) },
            .{ g.reg(gr.SET_VIEWPORT_CLIP_HORIZONTAL), g.reg(gr.SET_VIEWPORT_CLIP_HORIZONTAL + 4) },
        };
        // (each: a start in the low half, a size in the high)
        for (both) |hv| {
            c.x0 = @max(c.x0, hv[0] & 0xffff);
            c.x1 = @min(c.x1, @as(i64, hv[0] & 0xffff) + (hv[0] >> 16));
            c.y0 = @max(c.y0, hv[1] & 0xffff);
            c.y1 = @min(c.y1, @as(i64, hv[1] & 0xffff) + (hv[1] >> 16));
        }
        if (g.reg(gr.SET_SCISSOR_ENABLE) & 1 != 0) {
            // (a start and an end, the end past the last)
            const h = g.reg(gr.SET_SCISSOR_ENABLE + 4);
            const v = g.reg(gr.SET_SCISSOR_ENABLE + 8);
            c.x0 = @max(c.x0, h & 0xffff);
            c.x1 = @min(c.x1, h >> 16);
            c.y0 = @max(c.y0, v & 0xffff);
            c.y1 = @min(c.y1, v >> 16);
        }
        return c;
    }

    /// Stage j's program read from GPU memory into `code` (loaded into the
    /// emulator before its stage runs: `load`): its header into `head`, its
    /// instructions' count into `n`, the group its constant buffers bind to
    /// returned.
    fn program(g: *Engine, j: u32, kind: sph.Stage, head: *[sph.WORDS]u32, code: []u64, n_out: *usize) anyerror!u32 {
        const sh = g.reg(gr.SET_PIPELINE_SHADER + 64 * j);
        try g.need(sh & 1 != 0 and (sh >> 4) & 0xf == j, "the vertex or the pixel stage is off, or its type is not its index");
        const va = @as(u64, g.reg(gr.SET_PIPELINE_PROGRAM_ADDRESS_A + 64 * j) & 0xff) << 32 | g.reg(gr.SET_PIPELINE_PROGRAM_ADDRESS_A + 64 * j + 4);
        try g.need(va % sph.BYTES == 0, "a program's header is not at a multiple of 128 bytes");
        const hb = g.host.mem.find(va, sph.BYTES) orelse return g.refuse("a program's header is not in mapped memory");
        for (head, 0..) |*w, k| w.* = std.mem.readInt(u32, hb[k * 4 ..][0..4], .little);
        const is = sph.stageOf(head) orelse return g.refuse("a program's header is not a version 4 vertex or pixel header");
        try g.need(is == kind, "a stage's program has the other stage's header");
        // The code: the instructions after the header, to the first
        // all-zero one.
        var n: usize = 0;
        while (n < CODE) : (n += 1) {
            const ib = g.host.mem.find(va + sph.CODE_AT + n * 16, 16) orelse break;
            if (std.mem.allEqual(u8, ib, 0)) break;
            code[2 * n] = std.mem.readInt(u64, ib[0..8], .little);
            code[2 * n + 1] = std.mem.readInt(u64, ib[8..16], .little);
        }
        try g.need(n != 0 and n < CODE, "a program with no code after its header, or more instructions than the emulator holds");
        // (what the engine prefetches must reach the code's end)
        const blocks = g.reg(gr.SET_PIPELINE_PROGRAM_ADDRESS_A + 64 * j + 8) & 0x7f;
        try g.need(blocks != 0, "a program with nothing to prefetch (SET_PIPELINE_PROGRAM_PREFETCH)");
        n_out.* = n;
        const group = g.reg(gr.SET_PIPELINE_REGISTER_COUNT + 64 * j + 4) & 7;
        try g.need(group < GROUPS, "a stage's binding group past 4");
        return group;
    }

    /// Stage j's code (read by `program`) into the emulator, its register
    /// count checked against what the code touches.
    fn load(g: *Engine, j: u32, code: []const u64) anyerror!void {
        try emu.loadWords(g.host.work, code);
        const registers = g.reg(gr.SET_PIPELINE_REGISTER_COUNT + 64 * j) & 0x1ff;
        if (g.host.work.top) |top| try g.need(registers > top, "a stage's register count is below the registers its program touches");
    }

    /// A group's bound constant buffers, as a Stage takes them.
    fn buffers(g: *Engine, group: u32) error{BadStream}![qmd.CBUFS][]const u8 {
        var out: [qmd.CBUFS][]const u8 = .{&.{}} ** qmd.CBUFS;
        for (&out, 0..) |*o, slot| {
            const b = g.bound[group][slot];
            if (!b.valid) continue;
            o.* = g.host.mem.find(b.va, b.size) orelse return g.refuse("a bound constant buffer's memory is not mapped");
        }
        return out;
    }

    fn stored(g: *const Engine, v: usize, word: usize) bool {
        return (g.vstored[v][word / 32] >> @intCast(word % 32)) & 1 != 0;
    }

    fn vfloat(g: *const Engine, v: usize, word: usize) f64 {
        return @as(f32, @bitCast(g.vout[v][word]));
    }

    /// The index buffer as SET_INDEX_BUFFER_A, _SIZE_A and _E say: its
    /// bytes, and an index's size.
    const IndexBuffer = struct { bytes: []const u8, size: u32 };

    fn indexBuffer(g: *Engine, first: u32, count: u32) error{BadStream}!IndexBuffer {
        const va = @as(u64, g.reg(gl3d.SET_INDEX_BUFFER_A) & 0xff) << 32 | g.reg(gl3d.SET_INDEX_BUFFER_A + 4);
        const limit = @as(u64, g.reg(gl3d.SET_INDEX_BUFFER_SIZE_A) & 0xff) << 32 | g.reg(gl3d.SET_INDEX_BUFFER_SIZE_A + 4);
        const size: u32 = switch (g.reg(gl3d.SET_INDEX_BUFFER_E) & 3) {
            0 => 1,
            1 => 2,
            2 => 4,
            else => return g.refuse("an index size other than 1, 2 or 4 bytes (SET_INDEX_BUFFER_E)"),
        };
        try g.need(va % size == 0, "an index buffer not on its indices' size");
        try g.need((@as(u64, first) + count) * size <= limit, "indices past the index buffer's size (SET_INDEX_BUFFER_SIZE): not modelled");
        const bytes = g.host.mem.find(va, @intCast(limit)) orelse return g.refuse("the index buffer's memory is not mapped");
        return .{ .bytes = bytes, .size = size };
    }

    /// Index `at` of the buffer.
    fn indexAt(ib: IndexBuffer, at: u32) u32 {
        return switch (ib.size) {
            1 => ib.bytes[at],
            2 => std.mem.readInt(u16, ib.bytes[2 * at ..][0..2], .little),
            else => std.mem.readInt(u32, ib.bytes[4 * at ..][0..4], .little),
        };
    }

    /// What a draw's primitives are drawn with (draw's, for its runs).
    const DrawCtx = struct {
        t: Target,
        clip: Clip,
        vcb: [qmd.CBUFS][]const u8,
        pcb: [qmd.CBUFS][]const u8,
        vp: [4]f64,
        topo: u32,
        last: bool,
        /// Indexed: the vertex's index the buffer's, else its place.
        ib: ?IndexBuffer,
    };

    /// DRAW_VERTEX_ARRAY_BEGIN_END: `count` vertices from `first`; or
    /// (indexed) DRAW_INDEX_BUFFER_BEGIN_END: `count` indices from index
    /// `first` of the index buffer, each the vertex's index, the strip or
    /// the fan begun again past each one SET_DA_PRIMITIVE_RESTART_INDEX
    /// names when SET_DA_PRIMITIVE_RESTART is on (a list's partial
    /// primitive dropped). As SET_PRIMITIVE_TOPOLOGY says (triangles, a
    /// strip, a fan), as many instances as SET_DRAW_CONTROL_B says.
    fn draw(g: *Engine, first: u32, count: u32, indexed: bool) anyerror!void {
        g.why = "";
        try g.validate();
        const topo = g.reg(gr.SET_PRIMITIVE_TOPOLOGY);
        const instances = g.reg(gr.SET_DRAW_CONTROL_A + 4);
        const ib: ?IndexBuffer = if (indexed) try g.indexBuffer(first, count) else null;
        try g.need(g.reg(gr.SET_DA_PRIMITIVE_RESTART) <= 1, "SET_DA_PRIMITIVE_RESTART neither on nor off");
        const t = try g.target();
        try g.layoutsAgree(t);
        const clip = g.clipOf(t);
        var stats = emu.Stats{};
        defer {
            g.stats.warps += stats.warps;
            g.stats.instructions += stats.instructions;
            g.stats.thread_instructions += stats.thread_instructions;
            g.stats.hazard_checks += stats.hazard_checks;
            g.stats.cycles = @max(g.stats.cycles, stats.cycles);
        }

        // The two programs, and what the pixel one reads against what the
        // vertex one stores.
        const vgroup = try g.program(gr.STAGE_VERTEX, .vertex, &g.vhead, &g.vcode, &g.vn);
        const pgroup = try g.program(gr.STAGE_PIXEL, .pixel, &g.phead, &g.pcode, &g.pn);
        try g.need(g.phead[18] & 0xf != 0, "the pixel program does not write target 0");
        for (GENERIC..GENERIC_END) |word| {
            const read = sph.interpOf(&g.phead, @intCast((word - GENERIC) / 4), @intCast((word - GENERIC) % 4)) != .unused;
            const was = sph.bit(&g.vhead, 400 + @as(u32, @intCast(word)));
            // (NVK: a varying stored that no pixel program reads raises
            // "Out Of Range Address" on the hardware and kills the channel)
            if (was and !read) return g.refuse("the vertex program stores a varying the pixel program does not read (NVK: Out Of Range Address on the hardware)");
            if (read and !was) return g.refuse("the pixel program reads a varying the vertex program does not store");
        }
        const vcb = try g.buffers(vgroup);
        const pcb = try g.buffers(pgroup);

        // The viewport: clip space to window pixels and depth.
        const sx = g.float(gr.SET_VIEWPORT_SCALE_X);
        const sy = g.float(gr.SET_VIEWPORT_SCALE_X + 4);
        g.zscale = g.float(gr.SET_VIEWPORT_SCALE_X + 8);
        const ox = g.float(gr.SET_VIEWPORT_SCALE_X + 12);
        const oy = g.float(gr.SET_VIEWPORT_SCALE_X + 16);
        g.zoffset = g.float(gr.SET_VIEWPORT_SCALE_X + 20);
        g.zlo = if (g.reg(gr.SET_VIEWPORT_Z_CLIP) == 0) -1 else 0;
        g.zhi = 1;
        const last = g.reg(gr.SET_PROVOKING_VERTEX) == 1;
        const dc = DrawCtx{ .t = t, .clip = clip, .vcb = vcb, .pcb = pcb, .vp = .{ sx, sy, ox, oy }, .topo = topo, .last = last, .ib = ib };
        const restart = indexed and g.reg(gr.SET_DA_PRIMITIVE_RESTART) & 1 != 0;
        const restart_at = g.reg(gl3d.SET_DA_PRIMITIVE_RESTART_INDEX);
        var inst: u32 = 0;
        while (inst < instances) : (inst += 1) {
            if (!restart) {
                try g.segment(&dc, first, count, inst, &stats);
                continue;
            }
            // (the primitives between restart indices, each run begun anew)
            var at: u32 = 0;
            while (at < count) {
                var end = at;
                while (end < count and indexAt(ib.?, first + end) != restart_at) end += 1;
                try g.segment(&dc, first + at, end - at, inst, &stats);
                at = end + 1;
            }
        }
        g.draws += 1;
    }

    /// One run of primitives (a draw's, or a restarted strip's or fan's):
    /// `count` vertices from `first` (indexed: indices from index
    /// `first`), instance `inst`.
    fn segment(g: *Engine, dc: *const DrawCtx, first: u32, count: u32, inst: u32, stats: *emu.Stats) anyerror!void {
        const topo = dc.topo;
        const t = dc.t;
        const clip = dc.clip;
        const vcb = dc.vcb;
        const pcb = dc.pcb;
        const last = dc.last;
        const prims: u32 = switch (topo) {
            4 => count / 3,
            else => if (count >= 3) count - 2 else 0,
        };
        // (vertices a run of primitives takes, at most)
        const per: u32 = switch (topo) {
            4 => VERTICES / 3,
            else => VERTICES - 2,
        };
        {
            var p0: u32 = 0;
            while (p0 < prims) {
                const np = @min(per, prims - p0);
                // the run's vertices, as indices into the draw's
                var idx: [VERTICES]u32 = undefined;
                var nv: usize = 0;
                switch (topo) {
                    4 => for (0..3 * np) |k| {
                        idx[nv] = 3 * p0 + @as(u32, @intCast(k));
                        nv += 1;
                    },
                    5 => for (0..np + 2) |k| {
                        idx[nv] = p0 + @as(u32, @intCast(k));
                        nv += 1;
                    },
                    else => {
                        idx[0] = 0;
                        nv = 1;
                        for (0..np + 1) |k| {
                            idx[nv] = p0 + 1 + @as(u32, @intCast(k));
                            nv += 1;
                        }
                    },
                }
                // The vertex program, a thread a vertex: no stream is on,
                // so all it is given is its index and the instance's.
                try g.load(gr.STAGE_VERTEX, g.vcode[0 .. 2 * g.vn]);
                for (0..nv) |v| {
                    g.vin[v] = @splat(0);
                    g.vin[v][sph.ATTR_VERTEX_ID / 4] = if (dc.ib) |ib| indexAt(ib, first + idx[v]) else first + idx[v];
                    g.vin[v][sph.ATTR_INSTANCE_ID / 4] = inst;
                }
                var vs = emu.Stage{ .kind = .vertex, .header = &g.vhead, .in = g.vin[0..nv], .out = g.vout[0..nv], .stored = g.vstored[0..nv], .cbufs = vcb };
                try emu.stageBegin(g.host.work, @intCast(nv));
                try emu.stageRun(g.host.work, &g.host.mem, &vs, @intCast(nv), stats);
                g.vp = dc.vp;
                for (0..nv) |v| g.project(v);
                // the pixel program from here
                try g.load(gr.STAGE_PIXEL, g.pcode[0 .. 2 * g.pn]);
                g.queued = 0;
                for (0..np) |k| {
                    const q: usize = k;
                    // (each primitive's vertices in GL's order: the
                    // provoking one is the first or the last of them)
                    const tri0: [3]usize = switch (topo) {
                        4 => .{ 3 * q, 3 * q + 1, 3 * q + 2 },
                        5 => if ((p0 + k) % 2 == 0) .{ q, q + 1, q + 2 } else .{ q + 1, q, q + 2 },
                        // (a fan's: GL's (0, i + 1, i + 2), the last
                        // provoking)
                        else => .{ 0, q + 1, q + 2 },
                    };
                    const flat = if (last) tri0[2] else tri0[0];
                    try g.clipped(t, pcb, clip, tri0, flat, stats);
                }
                try g.shade(t, pcb, stats);
                p0 += np;
            }
        }
    }

    /// Vertex v's window place, on the rasterizer's grid (1/256 of a pixel);
    /// one at or behind the eye is never projected (clipped first). Clamped
    /// far out (the guard band's work is the hardware's). In f32, op by op
    /// as gfxapi's compute raster has it (x * (1/w) * scale + offset, then
    /// to the grid rounding to nearest even): the model of the viewport
    /// transform, so the two rasterizers put a vertex in the same place.
    fn project(g: *Engine, v: usize) void {
        const vp: [4]f32 = .{ @floatCast(g.vp[0]), @floatCast(g.vp[1]), @floatCast(g.vp[2]), @floatCast(g.vp[3]) };
        g.win[v] = windowOf(@floatCast(g.vfloat(v, POSITION)), @floatCast(g.vfloat(v, POSITION + 1)), @floatCast(g.vfloat(v, POSITION + 3)), vp);
    }

    /// A triangle clipped against w >= W_MIN (as the hardware clips
    /// against the eye's plane), then rasterized: whole, nothing, or as one
    /// or two triangles over vertices made where its edges cross the plane
    /// (every output word carried linearly in clip space; the flat ones
    /// the provoking vertex's).
    fn clipped(g: *Engine, t: Target, cb: [qmd.CBUFS][]const u8, clip: Clip, tri: [3]usize, flat: usize, stats: *emu.Stats) anyerror!void {
        var kept: [3]bool = undefined;
        var n_in: u32 = 0;
        for (tri, 0..) |v, k| {
            const w = g.vfloat(v, POSITION + 3);
            kept[k] = w >= W_MIN;
            n_in += @intFromBool(kept[k]);
        }
        if (n_in == 3) return g.triangle(t, cb, clip, tri, flat, stats);
        if (n_in == 0) return;
        // the polygon's vertices in order: kept ones, and one where each
        // edge crosses the plane
        var poly: [4]usize = undefined;
        var n: usize = 0;
        var made: usize = 0;
        for (0..3) |k| {
            const a = tri[k];
            const b = tri[(k + 1) % 3];
            if (kept[k]) {
                poly[n] = a;
                n += 1;
            }
            if (kept[k] != kept[(k + 1) % 3]) {
                const wa = g.vfloat(a, POSITION + 3);
                const wb = g.vfloat(b, POSITION + 3);
                const s = (W_MIN - wa) / (wb - wa);
                const o = VERTICES + made;
                for (0..emu.ATTR_WORDS) |word| {
                    const x = g.vfloat(a, word) + (g.vfloat(b, word) - g.vfloat(a, word)) * s;
                    g.vout[o][word] = @bitCast(@as(f32, @floatCast(x)));
                }
                // (flat words: the provoking vertex's bits)
                for (GENERIC..GENERIC_END) |word| {
                    if (sph.interpOf(&g.phead, @intCast((word - GENERIC) / 4), @intCast((word - GENERIC) % 4)) == .constant) g.vout[o][word] = g.vout[flat][word];
                }
                g.vout[o][POSITION + 3] = @bitCast(@as(f32, @floatCast(W_MIN)));
                g.project(o);
                poly[n] = o;
                n += 1;
                made += 1;
            }
        }
        var k: usize = 1;
        while (k + 1 < n) : (k += 1) try g.triangle(t, cb, clip, .{ poly[0], poly[k], poly[k + 1] }, flat, stats);
    }

    /// One triangle's covered pixels queued (and shaded as the queue fills).
    fn triangle(g: *Engine, t: Target, cb: [qmd.CBUFS][]const u8, clip: Clip, tri0: [3]usize, flat: usize, stats: *emu.Stats) anyerror!void {
        const win = &g.win;
        var tri = tri0;
        var area = edge(win[tri[0]], win[tri[1]], win[tri[2]]);
        if (area == 0) return;
        if (g.culled(area)) return;
        // (front: wound as OGL_SET_FRONT_FACE says, as culling has it)
        const front = (area > 0) == gl3d.frontCcwOf(g.reg(gr.OGL_SET_FRONT_FACE));
        if (area < 0) {
            std.mem.swap(usize, &tri[1], &tri[2]);
            area = -area;
        }
        const a = win[tri[0]];
        const b = win[tri[1]];
        const c = win[tri[2]];
        const x0 = @max(clip.x0, @divFloor(@min(a[0], b[0], c[0]), 256));
        const x1 = @min(clip.x1, @divFloor(@max(a[0], b[0], c[0]), 256) + 1);
        const y0 = @max(clip.y0, @divFloor(@min(a[1], b[1], c[1]), 256));
        const y1 = @min(clip.y1, @divFloor(@max(a[1], b[1], c[1]), 256) + 1);
        // The pixels go by 2 x 2 quads, as the hardware's pixel warps take
        // them: a quad with any pixel covered runs all four (lanes 4q ..
        // 4q + 3: x across in bit 0, y down in bit 1), the others helpers.
        const fa: f64 = @floatFromInt(area);
        const zp = g.depthPlane(tri, area);
        var qy = y0 & ~@as(i64, 1);
        while (qy < y1) : (qy += 2) {
            var qx = x0 & ~@as(i64, 1);
            while (qx < x1) : (qx += 2) {
                var cov: [4]bool = undefined;
                var bary: [4][3]f64 = undefined;
                var zpx: [4]f32 = undefined;
                var any = false;
                for (0..4) |l| {
                    const px = qx + @as(i64, @intCast(l & 1));
                    const py = qy + @as(i64, @intCast(l >> 1));
                    const p = [2]i64{ px * 256 + 128, py * 256 + 128 };
                    // (each edge's function at the centre: the weight of
                    // the vertex across from it)
                    const e = [3]i64{ edge(b, c, p), edge(c, a, p), edge(a, b, p) };
                    bary[l] = .{ @as(f64, @floatFromInt(e[0])) / fa, @as(f64, @floatFromInt(e[1])) / fa, @as(f64, @floatFromInt(e[2])) / fa };
                    zpx[l] = zp.at(px, py);
                    cov[l] = px >= x0 and px < x1 and py >= y0 and py < y1 and inside(e[0], b, c) and inside(e[1], c, a) and inside(e[2], a, b) and g.depthIn(zpx[l]);
                    any = any or cov[l];
                }
                if (!any) continue;
                for (0..4) |l| {
                    const px = qx + @as(i64, @intCast(l & 1));
                    const py = qy + @as(i64, @intCast(l >> 1));
                    // (a helper outside the target is never written: its
                    // place is kept in range)
                    g.carry(tri, flat, bary[l], zpx[l], @intCast(@max(px, 0)), @intCast(@max(py, 0)), !cov[l], front);
                }
                if (g.queued == emu.MAX_THREADS) try g.shade(t, cb, stats);
            }
        }
    }

    /// The triangle's depth (window units) as a plane over the pixel
    /// centres from its first vertex: in f32, op by op as gfxapi's compute
    /// raster sets it up (writeTri) and reads it (plane), so a pixel both
    /// rasterizers draw gets the same depth bits from either (draws split
    /// between them do not z-fight). `area`: twice the triangle's area on
    /// the grid, > 0 (tri wound so).
    fn depthPlane(g: *const Engine, tri: [3]usize, area: i64) DepthPlane {
        var zc: [3]f32 = undefined;
        var w: [3]f32 = undefined;
        var win: [3][2]i64 = undefined;
        for (tri, 0..) |v, k| {
            zc[k] = @floatCast(g.vfloat(v, POSITION + 2));
            w[k] = @floatCast(g.vfloat(v, POSITION + 3));
            win[k] = g.win[v];
        }
        return planeOf(zc, w, win, @floatCast(g.zscale), @floatCast(g.zoffset), area);
    }

    /// Whether a triangle whose grid places give `area` (edge(v0, v1, v2):
    /// > 0 counter-clockwise as the window's coordinates count, x right
    /// and y as the rows grow) is culled, as OGL_SET_CULL, OGL_SET_CULL_FACE
    /// and OGL_SET_FRONT_FACE say.
    fn culled(g: *const Engine, area: i64) bool {
        return cullOf(area, g.reg(gr.OGL_SET_CULL) != 0, g.reg(gl3d.OGL_SET_CULL_FACE), gl3d.frontCcwOf(g.reg(gr.OGL_SET_FRONT_FACE)));
    }

    /// Whether a pixel's depth (window units) is in the viewport's depth
    /// range, as gfxapi's raster keeps a pixel (depthInRange).
    fn depthIn(g: *const Engine, z: f32) bool {
        return depthInRange(z, @floatCast(g.zlo), @floatCast(g.zhi), @floatCast(g.zscale), @floatCast(g.zoffset));
    }

    /// A pixel queued (a helper: not covered, run for its quad, never
    /// written): the attribute words its thread will read, carried across
    /// the triangle as the pixel program's header says.
    fn carry(g: *Engine, tri: [3]usize, flat: usize, bary: [3]f64, zpix: f32, px: u32, py: u32, helper: bool, front: bool) void {
        const n = g.queued;
        const in = &g.pin[n];
        in.* = @splat(0xdead_beef);
        var inv: [3]f64 = undefined;
        for (tri, 0..) |v, k| inv[k] = 1 / g.vfloat(v, POSITION + 3);
        // The position: the pixel's centre, the depth, and 1/w.
        in[POSITION] = @bitCast(@as(f32, @floatFromInt(px)) + 0.5);
        in[POSITION + 1] = @bitCast(@as(f32, @floatFromInt(py)) + 0.5);
        var w: f64 = 0;
        for (0..3) |k| w += bary[k] * inv[k];
        // (the depth, in window units: the triangle's plane, depthPlane)
        in[POSITION + 2] = @bitCast(zpix);
        g.zw[n] = zpix;
        in[POSITION + 3] = @bitCast(@as(f32, @floatCast(w)));
        for (GENERIC..GENERIC_END) |word| {
            switch (sph.interpOf(&g.phead, @intCast((word - GENERIC) / 4), @intCast((word - GENERIC) % 4))) {
                .unused => {},
                .constant => in[word] = g.vout[flat][word],
                // (over w: the program multiplies by the reciprocal of 1/w)
                .perspective => {
                    var x: f64 = 0;
                    for (tri, 0..) |v, k| x += bary[k] * g.vfloat(v, word) * inv[k];
                    in[word] = @bitCast(@as(f32, @floatCast(x)));
                },
                .linear => {
                    var x: f64 = 0;
                    for (tri, 0..) |v, k| x += bary[k] * g.vfloat(v, word);
                    in[word] = @bitCast(@as(f32, @floatCast(x)));
                },
            }
        }
        g.at[n] = .{ px, py };
        g.helper[n] = helper;
        g.front[n] = front;
        g.queued = n + 1;
    }

    /// The queued pixels' threads run, and their colors written.
    fn shade(g: *Engine, t: Target, cb: [qmd.CBUFS][]const u8, stats: *emu.Stats) anyerror!void {
        const n = g.queued;
        g.queued = 0;
        if (n == 0) return;
        var ps = emu.Stage{ .kind = .pixel, .header = &g.phead, .in = g.pin[0..n], .front = g.front[0..n], .killed = g.killed[0..n], .cbufs = cb, .ctx = g, .sample = &sampleCall };
        try emu.stageBegin(g.host.work, n);
        try emu.stageRun(g.host.work, &g.host.mem, &ps, n, stats);
        // Each colour target SET_CT_SELECT counts that the program writes:
        // its memory, blend, channels, and the registers its output is in
        // (four for each target the header names, in order, as NAK leaves
        // them; a target it does not write is left as it is).
        const Out = struct { t: Target, bl: ?Blend, mask: u4, reg: u32 };
        var outs: [8]Out = undefined;
        var n_out: usize = 0;
        var targets: u32 = 0;
        for (0..8) |ti| {
            const i: u32 = @intCast(ti);
            if ((g.phead[18] >> @intCast(4 * i)) & 0xf == 0) continue;
            const base = 4 * targets;
            targets += 1;
            if (i >= g.reg(gr.SET_CT_SELECT) & 0xf) continue;
            const tt = (if (i == 0) t else try g.targetAt(i)) orelse continue;
            const ct = g.reg(gr.SET_CT_WRITE + 4 * i);
            const mask: u4 = @intCast((ct & 1) | ((ct >> 4) & 1) << 1 | ((ct >> 8) & 1) << 2 | ((ct >> 12) & 1) << 3);
            outs[n_out] = .{ .t = tt, .bl = try g.blendAt(i), .mask = mask, .reg = base };
            n_out += 1;
        }
        const zt = try g.depthTarget();
        // (a program that writes the depth (gl_FragDepth): its register
        // after the colours' and the sample mask's, as NAK leaves them)
        const writes_depth = sph.bit(&g.phead, 609);
        for (0..n) |k| {
            if (g.killed[k] or g.helper[k]) continue;
            // (the depth and stencil tests, late: in the pixels' order, so
            // a later primitive's pixel tests against an earlier one's)
            if (zt) |z| {
                const zw: f32 = if (writes_depth) shaderDepth(@bitCast(emu.threadReg(g.host.work, @intCast(k), @intCast(4 * targets + 1)))) else g.zw[k];
                if (!g.depthStencil(z, g.at[k][0], g.at[k][1], zw, g.front[k])) continue;
            }
            for (outs[0..n_out]) |o| {
                if (g.at[k][0] >= o.t.width or g.at[k][1] >= o.t.height) continue;
                var color: [4]f32 = undefined;
                for (&color, 0..) |*ch, r| ch.* = @bitCast(emu.threadReg(g.host.work, @intCast(k), @intCast(o.reg + r)));
                write(o.t, g.at[k][0], g.at[k][1], color, o.bl, o.mask);
            }
        }
        g.pixels += n;
    }

    /// The depth and stencil tests of a pixel at (x, y) with window depth
    /// `zw` (clamped to 0..1, as the viewport's z clip holds it), the
    /// target's word updated as the state says (a back face's stencil by
    /// the back state when SET_TWO_SIDED_STENCIL_TEST is on); whether the
    /// colour is written.
    fn depthStencil(g: *Engine, z: ZT, x: u32, y: u32, zw: f32, front: bool) bool {
        if (x >= z.width or y >= z.height) return false;
        const at = blAddress(z.pitch, z.gobs, x * 4, y);
        const w = std.mem.readInt(u32, z.bytes[at..][0..4], .little);
        const zq = depthWord(zw);
        const old_z = w & 0xff_ffff;
        const s_at = if (z.stencil != null) blAddress8(z.s_pitch, z.gobs, x, y) else 0;
        var stencil: u32 = if (z.stencil) |sb| sb[s_at] else 0;
        const st_on = g.reg(gr.SET_STENCIL_TEST) & 1 != 0 and z.stencil != null;
        const back = !front and g.reg(STENCIL_TWO_SIDE) & 1 != 0;
        // (each face's: the ops and the func, the reference, the value
        // mask, the write mask)
        const s = gl3d.SET_STENCIL_OP_FAIL;
        const b = gl3d.SET_BACK_STENCIL_OP_FAIL;
        const ops = if (back) [4]u32{ g.reg(b), g.reg(b + 4), g.reg(b + 8), g.reg(b + 12) } else [4]u32{ g.reg(s), g.reg(s + 4), g.reg(s + 8), g.reg(s + 12) };
        const ref = (if (back) g.reg(gl3d.SET_BACK_STENCIL_FUNC_REF) else g.reg(s + 16)) & 0xff;
        const vm = (if (back) g.reg(gl3d.SET_BACK_STENCIL_FUNC_MASK) else g.reg(s + 20)) & 0xff;
        const wm = (if (back) g.reg(gl3d.SET_BACK_STENCIL_MASK) else g.reg(s + 24)) & 0xff;
        // (the stencil test: reference against the value, both masked)
        var s_pass = true;
        if (st_on) s_pass = funcPasses(ops[3], ref & vm, stencil & vm);
        const d_on = g.reg(gr.SET_DEPTH_TEST) & 1 != 0;
        const d_pass = !d_on or funcPasses(g.reg(gr.SET_DEPTH_FUNC), zq, old_z);
        var new_z = old_z;
        if (s_pass and d_pass and d_on and g.reg(gr.SET_DEPTH_WRITE) & 1 != 0) new_z = zq;
        if (st_on) {
            const op = ops[if (!s_pass) 0 else if (!d_pass) 1 else 2];
            const v = stencilOp(op, stencil, ref);
            stencil = (v & wm) | (stencil & ~wm & 0xff);
        }
        // (bits 24..31 of a depth word kept: X8Z24's X8, S8Z24's unused)
        std.mem.writeInt(u32, z.bytes[at..][0..4], (w & 0xff00_0000) | new_z, .little);
        if (z.stencil) |sb| sb[s_at] = @intCast(stencil & 0xff);
        return s_pass and d_pass;
    }

    /// The texture and the sampler a handle names, from the pools.
    fn texture(g: *Engine, handle: u32) error{BadStream}!Tex {
        try g.need(g.reg(gr.SET_TEXTURE_HEADER_VERSION) == 1 and g.reg(gr.SET_SAMPLER_BINDING) == 0, "the texture header version is not 1, or samplers are bound through headers");
        const hi = handle & 0xf_ffff;
        const si = handle >> 20;
        const hp = gr.SET_TEX_HEADER_POOL_A;
        const sp = gr.SET_TEX_SAMPLER_POOL_A;
        try g.need(hi != 0 and hi <= g.reg(hp + 8), "a texture handle names the null header or one past the pool's last");
        try g.need(si <= g.reg(sp + 8), "a texture handle names a sampler past the pool's last");
        const hva = (@as(u64, g.reg(hp) & 0x1ff_ffff) << 32 | g.reg(hp + 4)) + @as(u64, hi) * 32;
        const sva = (@as(u64, g.reg(sp) & 0x1ff_ffff) << 32 | g.reg(sp + 4)) + @as(u64, si) * 32;
        const hb = g.host.mem.find(hva, 32) orelse return g.refuse("the texture header pool is not in mapped memory");
        const sb = g.host.mem.find(sva, 32) orelse return g.refuse("the sampler pool is not in mapped memory");
        var h: [8]u32 = undefined;
        var s: [8]u32 = undefined;
        for (&h, 0..) |*w, k| w.* = std.mem.readInt(u32, hb[k * 4 ..][0..4], .little);
        for (&s, 0..) |*w, k| w.* = std.mem.readInt(u32, sb[k * 4 ..][0..4], .little);
        // The header: rows of bytes, one level, two dimensions.
        try g.need(h[3] >> 28 == 2 and (h[4] >> 22) & 0xf == 7 and h[2] >> 28 == 0, "a texture header that is not rows of bytes (PITCH_V2), one level, TWO_D_NO_MIPMAP");
        try g.need((h[3] >> 12) & 0xf == 0 and h[4] & (1 << 21) == 0, "a texture that is not unsigned normalized, or is sRGB: not modelled");
        const components = (h[3] >> 16) & 0x7f;
        try g.need(components == 0x08 or components == 0x1d, "a texture's components are not A8B8G8R8 or R8");
        var t = Tex{
            .bytes = &.{},
            .pitch = (h[2] & 0x1_ffff) << 5,
            .width = (h[4] & 0x1_ffff) + 1,
            .height = (h[5] & 0x1_ffff) + 1,
            .size = if (components == 0x08) 4 else 1,
            .source = .{ @truncate(h[3]), @truncate(h[3] >> 3), @truncate(h[3] >> 6), @truncate(h[3] >> 9) },
            .linear = false,
        };
        for (t.source) |src| try g.need(src == 0 or src == 7 or (src >= 2 and src <= 5), "a texture channel's source the renderer does not use");
        try g.need(t.pitch >= t.width * t.size, "a texture's rows are shorter than its width");
        const va = @as(u64, h[1] & 0x1ff_ffff) << 32 | (h[0] & 0xffff_ffe0);
        t.bytes = g.host.mem.find(va, @as(usize, t.pitch) * (t.height - 1) + @as(usize, t.width) * t.size) orelse return g.refuse("a texture's memory is not mapped");
        // The sampler: clamped to the edge, unnormalized, one filter.
        try g.need(s[0] & 7 == 2 and (s[0] >> 3) & 7 == 2, "a sampler that does not clamp to the edge: not modelled");
        try g.need(s[1] & (1 << 25) != 0, "a sampler with normalized coordinates: not modelled");
        const mag = s[1] & 7;
        const min = (s[1] >> 4) & 3;
        try g.need(mag == min and (mag == 1 or mag == 2), "a sampler whose two filters differ, or are neither point nor linear");
        t.linear = mag == 2;
        return t;
    }

    /// TEX: the Stage's callback.
    fn sampleCall(ctx: ?*anyopaque, handle: u32, x: f32, y: f32) emu.Error![4]f32 {
        const g: *Engine = @ptrCast(@alignCast(ctx.?));
        const t = g.texture(handle) catch return error.Unsupported;
        return sample(t, x, y);
    }
};

// ── The rasterizer's model, alone ──────────────────────────────────────────
// What the engine above uses to place vertices, cover pixels and give them
// depth (and gfxapi's compute raster does bit for bit): pub, so the
// hardware test (gpu/nvidia_draw.sig) can put the real 3D engine's
// pixels beside the model's.

/// A vertex's window place on the 1/256 grid: x * (1/w) * scale + offset in
/// f32, op by op, rounded to nearest even; w at least W_MIN (one behind
/// the eye's plane: clipped before, placed all the same). `vp`: scale x,
/// y, offset x, y.
pub fn windowOf(x: f32, y: f32, w_in: f32, vp: [4]f32) [2]i64 {
    const w: f32 = @max(w_in, @as(f32, @floatCast(W_MIN)));
    const iw: f32 = 1.0 / w;
    const xw = x * iw * vp[0] + vp[2];
    const yw = y * iw * vp[1] + vp[3];
    return .{ gridOf(xw * 256), gridOf(yw * 256) };
}

/// A window coordinate on the grid (rounded to nearest, ties to even),
/// held far out (the edge functions' products stay in 64 bits); not a
/// number is 0.
pub fn gridOf(x: f32) i64 {
    const lim: f32 = 1 << 29;
    if (x != x) return 0;
    return @intFromFloat(rne(std.math.clamp(x, -lim, lim)));
}

/// The depth plane of a triangle (its vertices' clip z and w, their grid
/// places, wound so that `area` = edge(win0, win1, win2) > 0) over the
/// pixel centres from its first vertex, in f32 op by op as gfxapi's
/// compute raster sets it up (writeTri) and reads it (plane).
pub fn planeOf(zc: [3]f32, w_in: [3]f32, win: [3][2]i64, zs: f32, zo: f32, area: i64) DepthPlane {
    var z: [3]f32 = undefined;
    var fx: [3]f32 = undefined;
    var fy: [3]f32 = undefined;
    for (0..3) |k| {
        const w: f32 = @max(w_in[k], @as(f32, @floatCast(W_MIN)));
        const iw: f32 = 1.0 / w;
        z[k] = zc[k] * iw * zs + zo;
        fx[k] = @as(f32, @floatFromInt(win[k][0])) * (1.0 / 256.0);
        fy[k] = @as(f32, @floatFromInt(win[k][1])) * (1.0 / 256.0);
    }
    // (the determinant from the exact area: its high and low words)
    const hi: i32 = @intCast(area >> 32);
    const lo: u32 = @truncate(@as(u64, @bitCast(area)));
    const det: f32 = (@as(f32, @floatFromInt(hi)) * 4294967296.0 + @as(f32, @floatFromInt(lo))) * (1.0 / 65536.0);
    const idet: f32 = 1.0 / det;
    const ex1 = fx[1] - fx[0];
    const ey1 = fy[1] - fy[0];
    const ex2 = fx[2] - fx[0];
    const ey2 = fy[2] - fy[0];
    const d1 = z[1] - z[0];
    const d2 = z[2] - z[0];
    return .{ .z0 = z[0], .gx = (d1 * ey2 - d2 * ey1) * idet, .gy = (d2 * ex1 - d1 * ex2) * idet, .x0 = fx[0], .y0 = fy[0] };
}

/// Whether a triangle of `area` (edge(v0, v1, v2) on the grid) is culled:
/// front when its winding (counter-clockwise: area > 0) is the front's.
pub fn cullOf(area: i64, on: bool, face: u32, front_ccw: bool) bool {
    if (!on or area == 0) return false;
    const front = (area > 0) == front_ccw;
    return switch (face) {
        gl3d.CULL_FRONT => front,
        gl3d.CULL_BACK => !front,
        gl3d.CULL_FRONT_AND_BACK => true,
        else => false,
    };
}

/// Whether a pixel's depth (window units) is in the viewport's depth range
/// (the clip volume's near and far planes there: zlo, zhi in NDC, -1 or
/// 0 and 1), as gfxapi's raster keeps a pixel: zmin <= z <= zmax.
pub fn depthInRange(z: f32, zlo: f32, zhi: f32, zs: f32, zo: f32) bool {
    const lo_w: f32 = zlo * zs + zo;
    const hi_w: f32 = zhi * zs + zo;
    return z >= @min(lo_w, hi_w) and z <= @max(lo_w, hi_w);
}

/// A depth's 24-bit word, as the raster's depthWord: in f32, rounded to
/// the nearest even (above 2^23 the product is whole already; adding a
/// half in f32 would round it up).
pub fn depthWord(z: f32) u32 {
    return @intFromFloat(rne(std.math.clamp(z, 0, 1) * 16777215.0));
}

/// A depth a pixel program wrote (gl_FragDepth) as the engine takes it:
/// clamped to the viewport's 0..1, not a number 0 (as gfxapi's compute
/// raster's fmax and fmin give it).
pub fn shaderDepth(z: f32) f32 {
    if (z != z) return 0;
    return std.math.clamp(z, 0, 1);
}

/// x rounded to the nearest whole number, ties to even (as cvt's .rne).
pub fn rne(x: f32) f32 {
    return if (@abs(x - @trunc(x)) == 0.5) 2 * @round(x / 2) else @round(x);
}

/// A triangle's depth plane (depthPlane): z0 at its first vertex (x0, y0,
/// pixels), slopes gx, gy.
pub const DepthPlane = struct {
    z0: f32,
    gx: f32,
    gy: f32,
    x0: f32,
    y0: f32,

    /// At pixel (px, py)'s centre, as gfxapi's raster's plane().
    pub fn at(p: DepthPlane, px: i64, py: i64) f32 {
        const dx = (@as(f32, @floatFromInt(px)) + 0.5) - p.x0;
        const dy = (@as(f32, @floatFromInt(py)) + 0.5) - p.y0;
        return (p.z0 + p.gx * dx) + p.gy * dy;
    }
};

/// The edge a -> b's function at p, on the 1/256 grid: positive on the
/// inside of a triangle wound as `draw` leaves it.
pub fn edge(a: [2]i64, b: [2]i64, p: [2]i64) i64 {
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

/// Whether a centre with edge function `e` on a -> b counts as covered:
/// inside, or on the edge where it is a top or a left one (the top-left
/// rule: a pixel on two triangles' shared edge is drawn once).
pub fn inside(e: i64, a: [2]i64, b: [2]i64) bool {
    if (e != 0) return e > 0;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return (dy == 0 and dx > 0) or dy < 0;
}

/// A texel's four floats after the header's sources: its bytes over 255.
fn texel(t: Tex, x: u32, y: u32) [4]f32 {
    const at = @as(usize, y) * t.pitch + @as(usize, x) * t.size;
    const one: f32 = 1.0 / 255.0;
    // (the components as the layout names them: R the first byte)
    var comp = [4]f32{ 0, 0, 0, 0 };
    for (0..t.size) |k| comp[k] = @as(f32, @floatFromInt(t.bytes[at + k])) * one;
    var out: [4]f32 = undefined;
    for (&out, t.source) |*o, src| o.* = switch (src) {
        2...5 => comp[src - 2],
        7 => 1,
        else => 0,
    };
    return out;
}

fn clampTexel(v: f32, size: u32) u32 {
    const top: f32 = @floatFromInt(size - 1);
    if (v != v) return 0;
    return @intFromFloat(std.math.clamp(v, 0, top));
}

/// The texture at (u, v), in texels (gpu/draw.sig's rule): the texel the
/// point is in, or the four around it weighed by how near their centres
/// are; past the edge, the edge's.
fn sample(t: Tex, u: f32, v: f32) [4]f32 {
    if (!t.linear) return texel(t, clampTexel(@floor(u), t.width), clampTexel(@floor(v), t.height));
    const fu = u - 0.5;
    const fv = v - 0.5;
    const x0f = @floor(fu);
    const y0f = @floor(fv);
    const wx = fu - x0f;
    const wy = fv - y0f;
    const a = texel(t, clampTexel(x0f, t.width), clampTexel(y0f, t.height));
    const b = texel(t, clampTexel(x0f + 1, t.width), clampTexel(y0f, t.height));
    const c = texel(t, clampTexel(x0f, t.width), clampTexel(y0f + 1, t.height));
    const d = texel(t, clampTexel(x0f + 1, t.width), clampTexel(y0f + 1, t.height));
    var out: [4]f32 = undefined;
    for (&out, 0..) |*o, i| {
        const top = a[i] + (b[i] - a[i]) * wx;
        const bottom = c[i] + (d[i] - c[i]) * wx;
        o.* = top + (bottom - top) * wy;
    }
    return out;
}

/// A channel as the target keeps it: not a number is 0, then [0, 1], then
/// the nearest of 256 steps.
fn quantize(v: f32) u8 {
    if (v != v) return 0;
    return @intFromFloat(@floor(std.math.clamp(v, 0, 1) * 255 + 0.5));
}

/// A compare as GL's NEVER .. ALWAYS (0x200 + bits: less 1, equal 2,
/// greater 4) of `a` against `b`.
fn funcPasses(func: u32, a: u32, b: u32) bool {
    const f = func & 7;
    return (a < b and f & 1 != 0) or (a == b and f & 2 != 0) or (a > b and f & 4 != 0);
}

/// GL's stencil operation on `v` (8 bits), with the reference `ref`.
fn stencilOp(op: u32, v: u32, ref: u32) u32 {
    return switch (op) {
        0 => 0,
        0x1e01 => ref,
        0x1e02 => @min(v + 1, 0xff),
        0x1e03 => v -| 1,
        0x150a => ~v & 0xff,
        0x8507 => (v + 1) & 0xff,
        0x8508 => (v + 0xff) & 0xff,
        else => v,
    };
}

/// Byte `x` of row `y` of a block-linear plane of 8-bit texels on
/// Blackwell (`pitch` bytes across, blocks of 2^gobs GOBs): its GOBs are
/// swizzled (x/8)*64 + y*8 + x%8 (drm_fourcc.h's GB20x 8-bpp sector
/// layout; gfxapi blocklinear's Blackwell8, NVDEC's luma on the Legion).
pub fn blAddress8(pitch: u32, gobs: u3, x: u32, y: u32) usize {
    const shift: u5 = @as(u5, gobs) + 3;
    const block = (y >> shift) * (pitch / 64) + x / 64;
    const gob = (y >> 3) & ((@as(u32, 1) << gobs) - 1);
    const ix = x % 64;
    const inner = (ix / 8) * 64 + (y % 8) * 8 + ix % 8;
    return (@as(usize, block) << (@as(u6, gobs) + 9)) + gob * 512 + inner;
}

/// Byte `xb` of row `y` of a block-linear surface (`pitch` bytes across,
/// blocks of 2^gobs GOBs, Turing2D's swizzle: 32-bit texels).
pub fn blAddress(pitch: u32, gobs: u3, xb: u32, y: u32) usize {
    const shift: u5 = @as(u5, gobs) + 3;
    const block = (y >> shift) * (pitch / 64) + xb / 64;
    const gob = (y >> 3) & ((@as(u32, 1) << gobs) - 1);
    const ix = xb % 64;
    const iy = y % 8;
    const inner = (ix / 32) * 256 + (iy / 4) * 128 + ((ix % 32) / 16) * 64 + (iy % 4) * 16 + ix % 16;
    return (@as(usize, block) << (@as(u6, gobs) + 9)) + gob * 512 + inner;
}

/// A blend as the target's state has it: the equations and factors (rgb's
/// equation, source, destination, then alpha's), the constant colour.
const Blend = struct { ops: [6]u32, constant: [4]f32 };

fn equationOk(v: u32) bool {
    return v == 0x8006 or v == 0x8007 or v == 0x8008 or v == 0x800a or v == 0x800b;
}

fn factorOk(v: u32) bool {
    return (v >= 0x4300 and v <= 0x4308) or v == 0x4000 or v == 0x4001 or (v >= 0xc001 and v <= 0xc004);
}

/// GL's factor for channel `ch` (3: alpha), from the source, the
/// destination and the constant.
fn factor(v: u32, ch: usize, s: [4]f32, d: [4]f32, k: [4]f32) f32 {
    return switch (v) {
        0x4000 => 0,
        0x4001 => 1,
        0x4300 => s[ch],
        0x4301 => 1 - s[ch],
        0x4302 => s[3],
        0x4303 => 1 - s[3],
        0x4304 => d[3],
        0x4305 => 1 - d[3],
        0x4306 => d[ch],
        0x4307 => 1 - d[ch],
        0x4308 => if (ch == 3) 1 else @min(s[3], 1 - d[3]),
        0xc001 => k[ch],
        0xc002 => 1 - k[ch],
        0xc003 => k[3],
        else => 1 - k[3],
    };
}

fn equation(v: u32, a: f32, fa: f32, b: f32, fb: f32) f32 {
    return switch (v) {
        0x8006 => a * fa + b * fb,
        0x8007 => @min(a, b),
        0x8008 => @max(a, b),
        0x800a => a * fa - b * fb,
        else => b * fb - a * fa,
    };
}

fn pixelBytes(f: Fmt) u32 {
    return switch (f) {
        .r8 => 1,
        .rg8 => 2,
        else => 4,
    };
}

/// The pixel (x, y) after `src` is drawn there: replaced, or blended with
/// what it holds (`bl`: GL's arithmetic in floats, the colour clamped to
/// [0, 1] first), the channels `mask` names alone written.
fn write(t: Target, x: u32, y: u32, src0: [4]f32, bl: ?Blend, mask: u4) void {
    const one: f32 = 1.0 / 255.0;
    const at = if (t.gobs) |n| blAddress(t.pitch, n, x * pixelBytes(t.format), y) else @as(usize, y) * t.pitch + @as(usize, x) * pixelBytes(t.format);
    // (where each of r, g, b, a is among the pixel's bytes; none: not kept)
    const order: [4]?u8 = switch (t.format) {
        .bgra8 => .{ 2, 1, 0, 3 },
        .rgba8 => .{ 0, 1, 2, 3 },
        .rg8 => .{ 0, 1, null, null },
        .r8 => .{ 0, null, null, null },
    };
    var src: [4]f32 = undefined;
    for (&src, src0) |*o, v| o.* = if (v != v) 0 else std.math.clamp(v, 0, 1);
    var dst: [4]f32 = .{ 0, 0, 0, 1 };
    for (order, 0..) |byte, ch| {
        if (byte) |b| dst[ch] = @as(f32, @floatFromInt(t.bytes[at + b])) * one;
    }
    for (order, 0..) |byte, ch| {
        const b = byte orelse continue;
        if ((mask >> @intCast(ch)) & 1 == 0) continue;
        const v = if (bl) |bx| blk: {
            const base: usize = if (ch == 3) 3 else 0;
            const fs = factor(bx.ops[base + 1], ch, src, dst, bx.constant);
            const fd = factor(bx.ops[base + 2], ch, src, dst, bx.constant);
            break :blk equation(bx.ops[base], src[ch], fs, dst[ch], fd);
        } else src[ch];
        t.bytes[at + b] = quantize(v);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the top-left rule: a rectangle's two triangles cover each pixel once" {
    // (0,0) (4,0) (0,4) and (4,0) (4,4) (0,4), wound the same way, in pixels
    const s = 256;
    const tris = [2][3][2]i64{
        .{ .{ 0, 0 }, .{ 4 * s, 0 }, .{ 0, 4 * s } },
        .{ .{ 4 * s, 0 }, .{ 4 * s, 4 * s }, .{ 0, 4 * s } },
    };
    var total: u32 = 0;
    for (0..6) |y| for (0..6) |x| {
        const p = [2]i64{ @as(i64, @intCast(x)) * s + 128, @as(i64, @intCast(y)) * s + 128 };
        var n: u32 = 0;
        for (tris) |t| {
            try testing.expect(edge(t[0], t[1], t[2]) > 0);
            if (inside(edge(t[1], t[2], p), t[1], t[2]) and inside(edge(t[2], t[0], p), t[2], t[0]) and inside(edge(t[0], t[1], p), t[0], t[1])) n += 1;
        }
        try testing.expectEqual(@as(u32, if (x < 4 and y < 4) 1 else 0), n);
        total += n;
    };
    try testing.expectEqual(@as(u32, 16), total);
    // An edge through pixel centres: the left one takes them, the right
    // one leaves them (a rectangle from 0.5 to 2.5 covers pixels 0 and 1).
    const half = [3][2]i64{ .{ 128, 0 }, .{ 640, 0 }, .{ 128, 4 * s } };
    try testing.expect(inside(edge(half[2], half[0], .{ 128, 128 }), half[2], half[0]));
    const right = [3][2]i64{ .{ 640, 0 }, .{ 640, 4 * s }, .{ 128, 4 * s } };
    try testing.expect(!inside(edge(right[0], right[1], .{ 640, 128 }), right[0], right[1]));
}

fn expectColor(want: [4]f32, got: [4]f32) !void {
    for (want, got) |w, g| try testing.expectApproxEqAbs(w, g, 1e-6);
}

test "a texel through the header's sources, the filter at a centre and between two" {
    // two BGRA texels: (b, g, r, a) = (0, 51, 102, 255) and (255, 204, 153, 0)
    const bytes = [_]u8{ 0, 51, 102, 255, 255, 204, 153, 0 };
    var t = Tex{ .bytes = &bytes, .pitch = 32, .width = 2, .height = 1, .size = 4, .source = .{ 4, 3, 2, 5 }, .linear = false };
    try expectColor(.{ 0.4, 0.2, 0, 1 }, texel(t, 0, 0));
    try expectColor(.{ 0.6, 0.8, 1, 0 }, sample(t, 1.9, 0.2));
    // (past the edge: the edge's)
    try expectColor(.{ 0.6, 0.8, 1, 0 }, sample(t, 7, -3));
    t.linear = true;
    try expectColor(.{ 0.4, 0.2, 0, 1 }, sample(t, 0.5, 0.5));
    const mid = sample(t, 1, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid[3], 1e-6);
    // alpha read as one
    t.source[3] = 7;
    try testing.expectEqual(@as(f32, 1), sample(t, 1.5, 0.5)[3]);
}

test "a pixel written: replaced, and premultiplied source over" {
    var bytes = [_]u8{ 255, 0, 0, 255 } ** 2; // blue, opaque (b, g, r, a)
    const t = Target{ .bytes = &bytes, .pitch = 8, .width = 2, .height = 1, .format = .bgra8 };
    const over = Blend{ .ops = .{ 0x8006, 0x4001, 0x4303, 0x8006, 0x4001, 0x4303 }, .constant = .{ 0, 0, 0, 0 } };
    write(t, 0, 0, .{ 0, 0.5, 0, 0.5 }, over, 0xf);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 0, 255 }, bytes[0..4]);
    write(t, 1, 0, .{ 1, 0.5, 0, 0.25 }, null, 0xf);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 255, 64 }, bytes[4..8]);
}

test "a stencil plane's byte lands where Blackwell's 8-bit GOB puts it" {
    // (row 9, byte 21, two GOBs a block: the second GOB, its column 2,
    // row 1, byte 5)
    try testing.expectEqual(@as(usize, 512 + 2 * 64 + 1 * 8 + 5), blAddress8(64, 1, 21, 9));
    // (the next GOB across: the next block)
    try testing.expectEqual(@as(usize, 1024), blAddress8(128, 1, 64, 0));
}

test "a block-linear target's pixel lands where its GOB puts it" {
    var bytes = [_]u8{0} ** 1024;
    const t = Target{ .bytes = &bytes, .pitch = 64, .width = 16, .height = 16, .format = .rgba8, .gobs = 1 };
    // (pixel (5, 9): byte 20 of row 9, the second GOB of the block)
    write(t, 5, 9, .{ 1, 0, 0, 1 }, null, 0xf);
    const at = blAddress(64, 1, 20, 9);
    try testing.expectEqual(@as(usize, 512 + 64 + 16 + 4), at);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, bytes[at..][0..4]);
}
