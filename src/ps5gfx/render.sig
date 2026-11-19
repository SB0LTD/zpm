//! @zpm/ps5gfx render — the renderer: a PS5 draw carried out on the
//! engine.
//!
//! ps5's graphics driver reads a game's command buffers on its worker
//! thread and hands each draw here with the registers as they stand
//! (`agcdriver.renderer`). A draw is read (state.sig), put in the
//! engine's terms (draw.sig), given the image its target is kept as
//! (target.sig) and the pipeline its shaders were made into, and handed
//! to gfxapi's engine. When the driver is about to tell the game that
//! the GPU got somewhere (a label, an interrupt, a flip) it asks for
//! everything drawn so far to be finished (`sync`). The display takes a
//! flipped buffer's frame from here by its address.
//!
//! The shaders are someone else's work: `shade` is asked for a draw's
//! pipeline and what it reads (a recompiler of the game's shader code is
//! to answer; a test answers with emitters of its own).
//!
//! A draw this cannot carry out rightly is left out, counted by its
//! reason, and the reason said once. Nothing is guessed at: a frame with
//! a draw missing shows what is not done, a frame with a draw done
//! wrongly hides it. `Why` is the list.
//!
//! Depth. A draw with colour off is drawn into its depth target alone. A
//! draw marked as clearing depth is carried out as a fill of the clear
//! value over what the draw's scissor and viewport leave (a clear is
//! drawn as a rectangle over the target: its own corners are not read).
//! A depth target is tested against only while it holds what the game's
//! draws made of it: a new one does not, nor one a draw that was to
//! write it was left out of, until the game clears it.
//!
//! Known, and drawn all the same (none of it is checked or refused):
//! - a game's own write into a target's memory (a clear or a copy done
//!   by the CPU, by a memory packet or by a compute shader) does not
//!   reach the target's image, and once a target has an image the
//!   display takes that image, not the game's memory;
//! - a target used as a texture by a later draw: `shade` is told nothing
//!   of the targets yet;
//! - a draw's second and later colour targets are not drawn (said once);
//! - every primitive goes through viewport 0; a line is one pixel wide
//!   and a point the engine's own size; the guard band is the viewport;
//! - a triangle with a corner behind the eye is dropped whole (the
//!   engine does not clip);
//! - depth is the engine's 24 bits (or its float form on a GPU), whatever
//!   the game's format.
//!
//! One engine, used by the driver's worker (draws) and by the display's
//! thread (frames): a lock is held around every use. `install` and
//! `shade` are set before a game submits anything.
//!
//! Allocation-free: the engine's memory is the host's (`Config`).

const std = @import("std");
const builtin = @import("builtin");
const ps5 = @import("ps5");
const gfxapi = @import("gfxapi");
const state = @import("state.sig");
const convert = @import("draw.sig");
const target = @import("target.sig");

const agcdriver = ps5.agcdriver;
const engine = gfxapi.engine;
const raster = gfxapi.raster;
const texture = gfxapi.texture;
const Engine = engine.Engine;
const State = state.State;

// ── What shades a draw ──────────────────────────────────────────────────────

/// A draw, for whoever makes its shaders.
pub const Request = struct {
    state: *const State,
    /// What the engine's own count of vertices must have added to be the
    /// number the game's vertex code sees: an indexed draw's base vertex
    /// (a draw without indices starts its count at the first vertex
    /// already). And the same for instances.
    add_vertex: i32,
    add_instance: u32,
    /// The colour target holds sRGB: the engine stores what it is given,
    /// so the pixel shader's colour is to be encoded before it is handed
    /// over. (Such a draw is never blended here.)
    target_srgb: bool = false,
    /// Colour is off: only what the draw does to depth counts.
    depth_only: bool = false,
};

/// A draw's shaders as the engine takes them, and what they read.
///
/// The images named are whoever answered's, and stay as they are until
/// it is asked again. The pipeline must stay where it is and as it is
/// for longer: the engine keeps pointers into it until what was drawn
/// with it has run. Before a pipeline is changed, moved or given up,
/// finish the engine's work (`Engine.finish`) and unload it
/// (`Engine.unloadPipeline`).
pub const Shading = struct {
    pipe: *const raster.Pipeline,
    uniforms: []const u32 = &.{},
    buffers: [raster.MAX_BUFFERS]?*engine.Image = [_]?*engine.Image{null} ** raster.MAX_BUFFERS,
    textures: [texture.MAX_TEX]?*engine.Image = [_]?*engine.Image{null} ** texture.MAX_TEX,
    /// The pixel shader reads a value that is one vertex's for a whole
    /// primitive. (The engine takes the last vertex's: a draw that wants
    /// the first is left out.)
    flat: bool = false,
};

/// Null: these shaders cannot be made (the draw is left out). It is
/// called with the renderer's lock held: it must not ask for a frame.
pub const Shade = *const fn (e: *Engine, r: Request) ?Shading;

pub var shade: ?Shade = null;

// ── Counts ──────────────────────────────────────────────────────────────────

/// Why a draw was left out.
pub const Why = enum(u8) {
    no_renderer,
    no_shaders,
    shaders,
    stages,
    color_mode,
    no_target,
    target_layout,
    target_view,
    srgb_blend,
    samples,
    primitive,
    polygon_mode,
    provoking,
    viewport,
    window_offset,
    indices,
    stencil,
    depth_target,
    depth_unknown,
    depth_clamp,
    depth_bias,
    depth_bounds,
    clear_with_color,
    blend,
    engine,

    fn text(w: Why) []const u8 {
        return switch (w) {
            .no_renderer => "the renderer was not set up",
            .no_shaders => "nothing makes shaders yet",
            .shaders => "its shaders could not be made",
            .stages => "it has a geometry or hull stage",
            .color_mode => "the colour path is in a mode that is not drawing, or combines bits in a way that is not copying",
            .no_target => "it has no colour target",
            .target_layout => "its target is not four bytes a pixel, or there is no memory for it",
            .target_view => "it draws into a smaller level or a later slice of its target",
            .srgb_blend => "it blends into an sRGB target (the engine would blend the stored values, not the light they stand for)",
            .samples => "it is multisampled",
            .primitive => "its primitive is one the engine does not draw (rectangles, quads, patches)",
            .polygon_mode => "its triangles are to be lines or points",
            .provoking => "a flat value is to be the first vertex's (the engine takes the last)",
            .viewport => "its viewport's transform is on in part",
            .window_offset => "its vertices are moved by a window offset",
            .indices => "its indices are at no address",
            .stencil => "it tests stencil",
            .depth_target => "its depth target is not as tall as its colour target, is narrower, or there is no memory for it",
            .depth_unknown => "it tests against a depth target that does not hold what the game drew (never cleared, or a draw into it was left out)",
            .depth_clamp => "depth outside the range is to be clamped (the engine drops it)",
            .depth_bias => "its triangles' depth is biased",
            .depth_bounds => "it tests depth bounds",
            .clear_with_color => "it clears depth and draws colour at once",
            .blend => "its blending uses a second colour or a rule the engine has none for",
            .engine => "the engine refused it, or had no memory for its indices",
        };
    }
};

const REASONS = @typeInfo(Why).@"enum".field_names.len;

pub const stats = struct {
    /// Draws handed to the engine (those into depth alone among them).
    pub var drawn: u64 = 0;
    pub var depth_only: u64 = 0;
    /// Depth clears carried out.
    pub var cleared: u64 = 0;
    /// Draws with nothing to draw: a scissor that holds no pixel, a draw
    /// marked as not reaching the rasteriser, colour off and nothing to
    /// write to depth.
    pub var empty: u64 = 0;
    pub var left_out: [REASONS]u64 = [_]u64{0} ** REASONS;
    /// Draws whose second and later colour targets were not drawn.
    pub var targets_dropped: u64 = 0;
    pub var syncs: u64 = 0;
    pub var frames: u64 = 0;

    pub fn leftOut(w: Why) u64 {
        return left_out[@intFromEnum(w)];
    }

    pub fn clear() void {
        drawn = 0;
        depth_only = 0;
        cleared = 0;
        empty = 0;
        left_out = [_]u64{0} ** REASONS;
        targets_dropped = 0;
        syncs = 0;
        frames = 0;
    }
};

var said = [_]bool{false} ** REASONS;
var said_targets = false;

fn say(comptime prefix: []const u8, text: []const u8) void {
    // (a test's host is not this kernel)
    if (builtin.is_test) return;
    var buf: [240]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[ps5] gfx: " ++ prefix ++ "{s} (said once)\n", .{text}) catch return;
    _ = ps5.sys.call(ps5.abi.Sys.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
}

fn leave(w: Why) void {
    const i = @intFromEnum(w);
    stats.left_out[i] += 1;
    if (!said[i]) say("a draw is left out: ", w.text());
    said[i] = true;
}

fn nothing() ?Why {
    stats.empty += 1;
    return null;
}

// ── The engine ──────────────────────────────────────────────────────────────

/// Memory for the engine: its images (a game's targets among them) and
/// its work while it draws on the CPU.
pub const Config = struct {
    pool: []u8,
    cpu_work: []u8,
};

var eng: Engine = undefined;
var targets: target.Targets = .{};
var lock: ps5.pthread.Lock = .{};
var ready = false;

/// Sets the engine up and takes the driver's draws and the display's
/// requests for frames. Once, before a game submits anything; a second
/// call changes nothing.
pub fn install(cfg: Config) void {
    lock.lock();
    defer lock.unlock();
    if (!ready) {
        eng.init(.{ .pool = cfg.pool, .cpu_work = cfg.cpu_work });
        ready = true;
    }
    agcdriver.renderer = .{ .draw = onDraw, .sync = onSync };
    ps5.videoout.source = frame;
}

/// Whether a draw is to write its depth target (carried out or not).
fn writesDepth(dz: state.Depth) bool {
    return dz.format != 0 and dz.address != 0 and (dz.clears or (dz.test_on and dz.write));
}

fn onDraw(s: *const State, d: agcdriver.Draw) void {
    lock.lock();
    defer lock.unlock();
    if (!ready) return leave(.no_renderer);
    if (drawOne(s, d)) |why| {
        // What the draw was to write to depth is not there: the target no
        // longer holds what the game made of it.
        const dz = state.depth(s);
        if (writesDepth(dz)) targets.trust(dz.address, false);
        leave(why);
    }
}

fn onSync() void {
    lock.lock();
    defer lock.unlock();
    stats.syncs += 1;
    if (ready) eng.finish();
}

/// The frame drawn into the target at `address`, as the display takes one
/// (`width` x `height` words, rows from the top, 0xAARRGGBB). False:
/// nothing was drawn there.
pub fn frame(address: u64, width: u32, height: u32, out: [*]u32) bool {
    lock.lock();
    defer lock.unlock();
    if (!ready) return false;
    eng.finish();
    if (!targets.frame(&eng, address, width, height, out)) return false;
    stats.frames += 1;
    return true;
}

/// One draw. Null: drawn, or there was nothing to draw.
///
/// Everything that can refuse comes before the first image is made: a
/// draw left out leaves no image behind for its target (the display
/// would take that image, black, over the game's own memory).
fn drawOne(s: *const State, d: agcdriver.Draw) ?Why {
    if (d.count == 0 or d.instances == 0) return nothing();
    const mode = state.raster(s);
    if (mode.kill) return nothing();
    const stages = state.stages(s);
    if (stages.geometry() or stages.hull()) return .stages;

    const dz = state.depth(s);
    const has_depth = dz.format != 0 and dz.address != 0;
    const color_on = switch (state.colorMode(s)) {
        .off => false,
        .normal => true,
        .other => return .color_mode,
    };
    // The draw's size: its colour target's, or with colour off its depth
    // target's.
    var colour: ?state.Target = null;
    var width: u32 = dz.width;
    var height: u32 = dz.height;
    if (color_on) {
        const t = state.target(s, 0) orelse return .no_target;
        if (t.samples_log2 != 0) return .samples;
        if (t.mip != 0 or t.first_slice != 0) return .target_view;
        if (convert.format(t) == null or t.address == 0) return .target_layout;
        colour = t;
        width = t.width;
        height = t.height;
    } else if (!has_depth) return nothing();
    if (mode.samples_log2 != 0 or (has_depth and dz.samples_log2 != 0)) return .samples;

    const v = state.viewport(s, 0) orelse return .viewport;
    var area = state.scissor(s, width, height, 0);
    if (convert.box(v)) |b| area = area.meet(b);
    const rect = convert.rect(area, width, height) orelse return nothing();

    if (dz.clears and has_depth) {
        if (color_on) return .clear_with_color;
        const z = targets.depth(&eng, dz) orelse return .depth_target;
        eng.fillDepth(z, rect, dz.clear, 0, 0);
        // (cleared all over, it holds what the game made of it again)
        if (rect.x0 == 0 and rect.y0 == 0 and rect.x1 == z.width and rect.y1 == z.height) targets.trust(dz.address, true);
        stats.cleared += 1;
        return null;
    }

    const tested = dz.test_on;
    if (!color_on and !(tested and dz.write)) return nothing();
    if (!mode.fill) return .polygon_mode;
    if (mode.vertices_offset) {
        const by = state.windowOffset(s);
        if (by[0] != 0 or by[1] != 0) return .window_offset;
    }
    const topology = convert.topology(state.primitive(s)) orelse return .primitive;
    if (dz.stencil_on) return .stencil;
    if (v.depth_clamp) return .depth_clamp;
    if (tested) {
        if (dz.bounds_on) return .depth_bounds;
        if (mode.depth_bias) return .depth_bias;
        // (the same height: a row of one is then the same row of the
        // other, whichever way up the engine counts them)
        if (dz.address == 0 or dz.height != height or dz.width < width) return .depth_target;
        if (!targets.trusted(dz.address)) return .depth_unknown;
    }
    var blend: ?raster.Blend = null;
    if (colour) |t| {
        if (state.blend(s, 0)) |b| {
            if (t.srgb()) return .srgb_blend;
            blend = convert.blend(b) orelse return .blend;
        }
    }
    const indexed = d.index_size != 0;
    if (indexed and d.index_address == 0) return .indices;

    const make = shade orelse return .no_shaders;
    const sh = make(&eng, .{
        .state = s,
        .add_vertex = if (indexed) d.base_vertex else 0,
        .add_instance = d.first_instance,
        .target_srgb = if (colour) |t| t.srgb() else false,
        .depth_only = !color_on,
    }) orelse return .shaders;
    if (sh.flat and !mode.provoke_last) return .provoking;

    // The images, last.
    var size_only: engine.Image = undefined;
    var color: *engine.Image = undefined;
    if (colour) |t| {
        color = targets.color(&eng, t) orelse return .target_layout;
    } else {
        // (with colour off the engine reads the draw's size from this and
        // nothing else)
        size_only = engine.wrap(.{}, width, height, width * 4, .rgba8, false);
        color = &size_only;
    }
    var depth: ?*engine.Image = null;
    if (tested) depth = targets.depth(&eng, dz) orelse return .depth_target;

    var rd = raster.Draw{ .pipe = sh.pipe, .color = color };
    rd.color_off = !color_on;
    rd.uniforms = sh.uniforms;
    rd.buffers = sh.buffers;
    rd.textures = sh.textures;
    rd.topology = topology;
    rd.count = d.count;
    rd.instances = d.instances;
    // The indices are read from the game's memory now, as the GPU reads
    // them when it comes to the draw, into a buffer of the engine's.
    var indices: engine.Image = undefined;
    if (indexed) {
        const bytes = @as(usize, d.count) * d.index_size;
        indices = eng.newBuffer(std.mem.alignForward(usize, bytes, 4)) orelse return .engine;
        const from: [*]const u8 = @ptrFromInt(@as(usize, @intCast(d.index_address)));
        eng.writeBytes(&indices, 0, from[0..bytes]);
        rd.index = &indices;
        rd.index_size = d.index_size;
        rd.restart = state.restart(s);
    } else {
        rd.first = @bitCast(d.base_vertex);
    }
    // (given back once the engine has run what was drawn with it)
    defer if (indexed) eng.freeImage(&indices);
    const vp = convert.viewport(v, height);
    rd.center = vp.center;
    rd.half = vp.half;
    rd.depth_scale = vp.depth_scale;
    rd.depth_bias = vp.depth_bias;
    rd.zmin = vp.zmin;
    rd.zmax = vp.zmax;
    rd.rect = rect;
    const f = convert.faces(mode);
    rd.cull = f.cull;
    rd.front_ccw = f.front_ccw;
    if (depth) |z| {
        rd.depth = z;
        rd.depth_test = true;
        rd.depth_func = dz.func;
        rd.depth_write = dz.write;
    }
    if (colour) |t| {
        rd.blend = blend;
        rd.keep = convert.keep(color.format, t.write);
        for (1..state.TARGETS) |n| {
            if (state.target(s, @intCast(n)) == null) continue;
            stats.targets_dropped += 1;
            if (!said_targets) say("", "a draw has more than one colour target: only the first is drawn");
            said_targets = true;
            break;
        }
    }
    if (!eng.draw(&rd)) return .engine;
    stats.drawn += 1;
    if (!color_on) stats.depth_only += 1;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const kir = @import("gpu").kir;
const pm4 = ps5.pm4;
const CX = state.CX;
const PRIMITIVE = ps5.agc.shader.PRIMITIVE;

/// Shaders of the test's own: three corners from the uniform words (x, y
/// in clip space, from word 4), one depth for all of them (word 10), one
/// colour for every pixel (words 0 to 3).
const Plain = struct {
    var words = [_]u32{0} ** 11;
    var pipe: raster.Pipeline = undefined;
    var made = false;
    var asked: u32 = 0;
    var last: Request = undefined;
    /// What the answer says of flat values.
    var flat = false;

    fn vertex(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        const off = k.op2(.iadd, .u32, kir.r(k.op2(.shl, .u32, kir.r(io.vertex_id), kir.u(3))), kir.u(16));
        const m = kir.global(io.uniforms, 32);
        io.position = .{
            k.load(.f32, m, kir.r(off)),
            k.load(.f32, m, kir.r(k.op2(.iadd, .u32, kir.r(off), kir.u(4)))),
            raster.uniform(k, .f32, io.uniforms, 10),
            k.mov(.f32, kir.f(1)),
        };
    }

    fn fragment(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        for (0..4) |c| io.color[c] = raster.uniform(k, .f32, io.uniforms, @intCast(c));
    }

    fn make(_: *Engine, r: Request) ?Shading {
        if (!made) pipe = raster.Pipeline.init(.{ .vertex = vertex, .fragment = fragment });
        made = true;
        asked += 1;
        last = r;
        return .{ .pipe = &pipe, .uniforms = &words, .flat = flat };
    }

    fn color(c: [4]f32) void {
        for (0..4) |i| words[i] = @bitCast(c[i]);
    }

    fn corners(p: [3][2]f32) void {
        for (0..3) |i| {
            words[4 + 2 * i] = @bitCast(p[i][0]);
            words[5 + 2 * i] = @bitCast(p[i][1]);
        }
    }

    fn depth(z: f32) void {
        words[10] = @bitCast(z);
    }
};

const Host = struct {
    var pool: [8 << 20]u8 align(64) = undefined;
    var work: [4 << 20]u8 align(64) = undefined;
};

const W = 32;
const H = 32;
/// Where the test's targets "are" (addresses a game would name; their
/// bytes are never touched).
const TARGET: u64 = 0x7_1234_5600;
const DEPTH: u64 = 0x7_2000_0000;

fn bitsOf(x: f32) u32 {
    return @bitCast(x);
}

/// Corners that cover the whole of clip space.
const all = [3][2]f32{ .{ -1, 1 }, .{ 3, 1 }, .{ -1, -3 } };
/// A triangle in the top left corner of the screen, its corners in the
/// order that goes round clockwise there: top left, top right, bottom
/// left of a 16-pixel square.
const corner = [3][2]f32{ .{ -1, 1 }, .{ 0, 1 }, .{ -1, 0 } };
/// The same with unequal sides: 24 pixels along the top, 8 down the left
/// (turned about its diagonal it would not cover the same pixels).
const wedge = [3][2]f32{ .{ -1, 1 }, .{ 0.5, 1 }, .{ -1, 0.5 } };

/// A command buffer in the making.
const Buffer = struct {
    words: [512]u32 = undefined,
    w: pm4.Writer = undefined,
    /// The colour target's address.
    at: u64 = TARGET,

    fn cx(b: *Buffer, reg: u32, value: u32) void {
        _ = b.w.setRegisters(.cx, reg, &.{value}).?;
    }

    fn uc(b: *Buffer, reg: u32, value: u32) void {
        _ = b.w.setRegisters(.uc, reg, &.{value}).?;
    }

    /// A 32 x 32 target of four bytes at `at`, the whole of clip space on
    /// it (y up, depth 0 to 1 as it is), triangles; and every other
    /// register a test here changes put back to what a queue starts with
    /// (the queue's registers stay as the last buffer left them, from
    /// test to test).
    fn scene(b: *Buffer, swap: u32) void {
        b.w = .{ .words = &b.words };
        b.cx(CX.SHADER_STAGES_EN, 0);
        b.cx(CX.CB_COLOR_CONTROL, 0x00CC_0010);
        b.cx(CX.CB_TARGET_MASK, 0xFFFF_FFFF);
        b.cx(CX.CB_COLOR0_INFO + CX.CB_STRIDE, 0);
        b.cx(CX.CB_COLOR0_VIEW, 0);
        b.cx(CX.CB_COLOR0_ATTRIB, 0);
        b.cx(CX.BLEND0_CONTROL, 0x2001_0001);
        b.cx(CX.SU_SC_MODE_CNTL, 0);
        b.cx(CX.AA_CONFIG, 0);
        b.cx(CX.GENERIC_SCISSOR_TL, 0x8000_0000);
        b.cx(CX.GENERIC_SCISSOR_BR, 0x4000_4000);
        b.cx(CX.DB_RENDER_CONTROL, 0);
        b.cx(CX.DB_DEPTH_VIEW, 0);
        b.cx(CX.DB_DEPTH_CONTROL, 0);
        b.cx(CX.DB_Z_INFO, 0);
        b.cx(CX.DB_STENCIL_INFO, 0);
        b.uc(agcdriver.UC.INDEX_OFFSET, 0);
        b.uc(0x24B, 0);

        b.cx(CX.CB_COLOR0_BASE, @truncate(b.at >> 8));
        b.cx(CX.CB_COLOR0_BASE_EXT, @truncate(b.at >> 40));
        b.cx(CX.CB_COLOR0_INFO, (state.COLOR.RGBA8 << 2) | (state.NUMBER.UNORM << 8) | (swap << 11));
        b.cx(CX.CB_COLOR0_ATTRIB2, (H - 1) | ((W - 1) << 14));
        b.cx(CX.CB_COLOR0_ATTRIB3, 1 << 24);
        b.cx(CX.VTE_CNTL, 0x43F);
        _ = b.w.setRegisters(.cx, CX.VPORT_XSCALE_0, &.{ bitsOf(W / 2), bitsOf(W / 2), bitsOf(-H / 2), bitsOf(H / 2), bitsOf(1), bitsOf(0) }).?;
        _ = b.w.setRegisters(.cx, CX.VPORT_ZMIN_0, &.{ bitsOf(0), bitsOf(1) }).?;
        b.cx(CX.CLIP_CNTL, 1 << 19);
        b.uc(agcdriver.UC.PRIMITIVE_TYPE, PRIMITIVE.TRIANGLES);
    }

    /// The depth target at DEPTH, as large as the colour target.
    fn depthTarget(b: *Buffer) void {
        b.cx(CX.DB_Z_INFO, 3);
        b.cx(CX.DB_Z_WRITE_BASE, @truncate(DEPTH >> 8));
        b.cx(CX.DB_Z_WRITE_BASE_HI, @truncate(DEPTH >> 40));
        b.cx(CX.DB_DEPTH_SIZE, (W - 1) | ((H - 1) << 16));
    }

    /// Tested against the depth target with `func`, and written or not.
    fn depthTest(b: *Buffer, func: u32, write: bool) void {
        b.depthTarget();
        b.cx(CX.DB_DEPTH_CONTROL, (1 << 1) | (@as(u32, @intFromBool(write)) << 2) | (func << 4));
    }

    fn colourOff(b: *Buffer) void {
        b.cx(CX.CB_COLOR_CONTROL, 0x00CC_0000);
    }

    fn draw(b: *Buffer, count: u32) void {
        _ = b.w.put(pm4.OP.DRAW_INDEX_AUTO, 0, &.{ count, 2 }).?;
    }

    /// Handed to the driver as a game hands it, and carried out (a test
    /// is the driver's worker).
    fn run(b: *Buffer) !void {
        const submit: *const fn (?*const agcdriver.Submission) callconv(.c) i32 =
            @ptrCast(agcdriver.exports.find(comptime ps5.nid.of("sceAgcDriverSubmitDcb")).?);
        const sub: agcdriver.Submission = .{ .commands = &b.words, .words = @intCast(b.w.len) };
        try testing.expectEqual(@as(i32, 0), submit(&sub));
        agcdriver.waitIdle();
    }

    /// The whole colour target painted one colour, with nothing in the
    /// way.
    fn paint(b: *Buffer, c: [4]f32) !void {
        Plain.color(c);
        Plain.corners(all);
        Plain.depth(0.5);
        b.scene(state.SWAP.STANDARD);
        b.draw(3);
        try b.run();
    }

    /// The depth target cleared to `z` all over, as a game does it: a
    /// draw with colour off and the clear switched on.
    fn clearDepth(b: *Buffer, z: f32) !void {
        Plain.corners(all);
        b.scene(state.SWAP.STANDARD);
        b.colourOff();
        b.depthTarget();
        b.cx(CX.DB_RENDER_CONTROL, 1);
        b.cx(0x00B, bitsOf(z));
        b.draw(3);
        try b.run();
    }
};

fn setUp() void {
    install(.{ .pool = &Host.pool, .cpu_work = &Host.work });
    shade = Plain.make;
    Plain.flat = false;
    Plain.depth(0.5);
    stats.clear();
    Plain.asked = 0;
}

var shot: [W * H]u32 = undefined;

/// The frame at TARGET.
fn look() !void {
    @memset(&shot, 0xDEAD_BEEF);
    try testing.expect(frame(TARGET, W, H, &shot));
}

/// One of its pixels (x from the left, y from the top) without its alpha.
fn at(x: usize, y: usize) u32 {
    return shot[y * W + x] & 0x00FF_FFFF;
}

fn near(got: u32, want: u32) !void {
    for ([_]u5{ 16, 8, 0 }) |shift| {
        const a: i32 = @intCast((got >> shift) & 0xFF);
        const b: i32 = @intCast((want >> shift) & 0xFF);
        if (@abs(a - b) > 1) {
            std.debug.print("got {x:0>6}, want {x:0>6}\n", .{ got, want });
            return error.TestExpectedEqual;
        }
    }
}

test "a triangle from a game's command buffer lands where the console would put it" {
    setUp();
    var b: Buffer = .{};
    try b.paint(.{ 0, 0, 0, 0 });
    Plain.color(.{ 1, 0.5, 0.25, 1 });
    Plain.corners(wedge);
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 2), stats.drawn);
    try testing.expectEqual(@as(i32, 0), Plain.last.add_vertex);
    try testing.expect(!Plain.last.target_srgb and !Plain.last.depth_only);

    try look();
    // Inside: near the top left corner, far along the top edge, a little
    // way down the left edge.
    const orange: u32 = 0xFF_8040;
    try testing.expectEqual(orange, at(2, 1));
    try testing.expectEqual(orange, at(18, 1));
    try testing.expectEqual(orange, at(1, 5));
    // Outside: as far down the left edge as it goes along the top (the
    // triangle turned about its diagonal would be there), past the long
    // edge, and the other three corners (a picture upside down would have
    // the bottom left painted).
    try testing.expectEqual(@as(u32, 0), at(1, 18));
    try testing.expectEqual(@as(u32, 0), at(14, 6));
    try testing.expectEqual(@as(u32, 0), at(2, 29));
    try testing.expectEqual(@as(u32, 0), at(29, 2));
    try testing.expectEqual(@as(u32, 0), at(29, 29));

    // Blue first in the target's memory: the display's frame is the same.
    setUp();
    try b.paint(.{ 0, 0, 0, 0 });
    Plain.color(.{ 1, 0.5, 0.25, 1 });
    Plain.corners(wedge);
    b.scene(state.SWAP.ALTERNATE);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(orange, at(18, 1));
    try testing.expectEqual(@as(u32, 0), at(1, 18));
}

test "faces: which way round is front, and which side is dropped" {
    // The corner triangle goes round clockwise on the screen.
    const cases = [_]struct { mode: u32, shown: bool }{
        // nothing dropped
        .{ .mode = 0, .shown = true },
        // back faces dropped, front is clockwise: it is a front face
        .{ .mode = 2 | 4, .shown = true },
        // back faces dropped, front is the other way: it is a back face
        .{ .mode = 2, .shown = false },
        // front faces dropped, front is clockwise
        .{ .mode = 1 | 4, .shown = false },
        .{ .mode = 1, .shown = true },
        .{ .mode = 3, .shown = false },
    };
    for (cases) |c| {
        setUp();
        var b: Buffer = .{};
        try b.paint(.{ 0, 0, 0, 0 });
        Plain.color(.{ 1, 1, 1, 1 });
        Plain.corners(corner);
        b.scene(state.SWAP.STANDARD);
        b.cx(CX.SU_SC_MODE_CNTL, c.mode);
        b.draw(3);
        try b.run();
        try look();
        const got = at(2, 2) != 0;
        if (got != c.shown) {
            std.debug.print("mode {x}: shown {}, wanted {}\n", .{ c.mode, got, c.shown });
            return error.TestExpectedEqual;
        }
    }
}

test "the scissor, the viewport's own box, the write mask and blending reach the engine" {
    setUp();
    var b: Buffer = .{};
    try b.paint(.{ 0, 0, 0, 0 });

    // The corner triangle, cut to the columns left of 8, red not written.
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(corner);
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.GENERIC_SCISSOR_BR, 8 | (16384 << 16));
    b.cx(CX.CB_TARGET_MASK, 0xE);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FFFF), at(2, 2));
    try testing.expectEqual(@as(u32, 0x00_FFFF), at(7, 2));
    try testing.expectEqual(@as(u32, 0), at(8, 2));
    try testing.expectEqual(@as(u32, 0), at(12, 2));

    // Over it, half-clear red through "source alpha, one minus source
    // alpha": half of each.
    Plain.color(.{ 1, 0, 0, 0.5 });
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.BLEND0_CONTROL, (1 << 30) | state.FACTOR.SRC_ALPHA | (state.FACTOR.ONE_MINUS_SRC_ALPHA << 8));
    b.draw(3);
    try b.run();
    try look();
    try near(at(2, 2), 0x80_8080);
    // (where the first triangle was cut away: half red over black)
    try near(at(12, 2), 0x80_0000);

    // Factors that are not each other's mirror: the shader's colour times
    // one, the target's times nothing, is the shader's colour (the two
    // the wrong way round would leave the target as it was).
    Plain.color(.{ 0, 1, 0, 0.25 });
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.BLEND0_CONTROL, (1 << 30) | state.FACTOR.ONE | (state.FACTOR.ZERO << 8));
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FF00), at(2, 2));
    // And the target's alone, taken from the shader's: nothing of the
    // shader's is left, and "subtract" of nothing from it leaves it.
    Plain.color(.{ 1, 1, 1, 1 });
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.BLEND0_CONTROL, (1 << 30) | state.FACTOR.ZERO | (state.COMBINE.REVERSE_SUBTRACT << 5) | (state.FACTOR.ONE << 8));
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FF00), at(2, 2));

    // A viewport that is the right half of the target: a triangle over
    // all of clip space is drawn inside it alone, though no scissor says
    // so.
    try b.paint(.{ 0, 0, 0, 0 });
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(all);
    b.scene(state.SWAP.STANDARD);
    _ = b.w.setRegisters(.cx, CX.VPORT_XSCALE_0, &.{ bitsOf(W / 4), bitsOf(3 * W / 4) }).?;
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0xFF_FFFF), at(20, 10));
    try testing.expectEqual(@as(u32, 0xFF_FFFF), at(16, 30));
    try testing.expectEqual(@as(u32, 0), at(15, 10));
    try testing.expectEqual(@as(u32, 0), at(2, 2));
}

test "indices are read from the game's memory; an indexed draw's base vertex is the shaders' to add" {
    setUp();
    var b: Buffer = .{};
    try b.paint(.{ 0, 0, 0, 0 });

    // The corner triangle's corners named backwards: it goes round the
    // other way, and with back faces dropped and clockwise as front it is
    // not shown. Named forwards it is.
    const Indices = struct {
        var back = [_]u16{ 2, 1, 0 };
        var forth = [_]u16{ 0, 1, 2 };
    };
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(corner);
    for ([_]struct { list: *[3]u16, shown: bool }{ .{ .list = &Indices.back, .shown = false }, .{ .list = &Indices.forth, .shown = true } }) |c| {
        b.scene(state.SWAP.STANDARD);
        b.cx(CX.SU_SC_MODE_CNTL, 2 | 4);
        b.uc(agcdriver.UC.INDEX_OFFSET, 7);
        const addr = @intFromPtr(c.list);
        _ = b.w.put(pm4.OP.INDEX_TYPE, 0, &.{0}).?;
        _ = b.w.put(pm4.OP.DRAW_INDEX_2, 0, &.{ 3, @truncate(addr), @truncate(addr >> 32), 3, 0 }).?;
        try b.run();
        try look();
        try testing.expectEqual(c.shown, at(2, 2) != 0);
    }
    try testing.expectEqual(@as(i32, 7), Plain.last.add_vertex);

    // Indices at no address: left out, and nothing is read.
    b.scene(state.SWAP.STANDARD);
    _ = b.w.put(pm4.OP.DRAW_INDEX_2, 0, &.{ 3, 0, 0, 3, 0 }).?;
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.indices));
}

/// What stats.left_out holds, to see that one reason and no other moved.
fn reasons() [REASONS]u64 {
    return stats.left_out;
}

test "draws that cannot be carried out rightly are left out and counted by their reason" {
    setUp();
    var b: Buffer = .{};
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(corner);

    const Set = struct { reg: u32, value: u32 };
    const none: Set = .{ .reg = CX.DB_DEPTH_VIEW, .value = 0 };
    const srgb: u32 = (state.COLOR.RGBA8 << 2) | (state.NUMBER.SRGB << 8);
    const cases = [_]struct { why: Why, set: [2]Set }{
        .{ .why = .stages, .set = .{ .{ .reg = CX.SHADER_STAGES_EN, .value = 0x20 }, none } },
        .{ .why = .stages, .set = .{ .{ .reg = CX.SHADER_STAGES_EN, .value = 0x04 }, none } },
        .{ .why = .color_mode, .set = .{ .{ .reg = CX.CB_COLOR_CONTROL, .value = 0x00CC_0040 }, none } },
        // (drawing, with the bits combined by "exclusive or")
        .{ .why = .color_mode, .set = .{ .{ .reg = CX.CB_COLOR_CONTROL, .value = 0x0066_0010 }, none } },
        .{ .why = .polygon_mode, .set = .{ .{ .reg = CX.SU_SC_MODE_CNTL, .value = (1 << 3) | (1 << 5) | (1 << 8) }, none } },
        .{ .why = .samples, .set = .{ .{ .reg = CX.AA_CONFIG, .value = 2 }, none } },
        .{ .why = .samples, .set = .{ .{ .reg = CX.CB_COLOR0_ATTRIB, .value = 2 << 12 }, none } },
        .{ .why = .viewport, .set = .{ .{ .reg = CX.VTE_CNTL, .value = 0x03F }, none } },
        .{ .why = .blend, .set = .{ .{ .reg = CX.BLEND0_CONTROL, .value = (1 << 30) | state.FACTOR.SRC1_COLOR }, none } },
        .{ .why = .target_layout, .set = .{ .{ .reg = CX.CB_COLOR0_INFO, .value = (state.COLOR.RGBA16 << 2) | (state.NUMBER.FLOAT << 8) }, none } },
        .{ .why = .no_target, .set = .{ .{ .reg = CX.CB_COLOR0_INFO, .value = 0 }, none } },
        // (a smaller level of the target; a later slice)
        .{ .why = .target_view, .set = .{ .{ .reg = CX.CB_COLOR0_VIEW, .value = 1 << 26 }, none } },
        .{ .why = .target_view, .set = .{ .{ .reg = CX.CB_COLOR0_VIEW, .value = 2 | (2 << 13) }, none } },
        .{ .why = .srgb_blend, .set = .{ .{ .reg = CX.CB_COLOR0_INFO, .value = srgb }, .{ .reg = CX.BLEND0_CONTROL, .value = (1 << 30) | state.FACTOR.ONE } } },
        .{ .why = .depth_clamp, .set = .{ .{ .reg = CX.CLIP_CNTL, .value = (1 << 19) | (1 << 26) }, none } },
        .{ .why = .depth_clamp, .set = .{ .{ .reg = CX.CLIP_CNTL, .value = (1 << 19) | (1 << 27) }, none } },
        .{ .why = .stencil, .set = .{ .{ .reg = CX.DB_Z_INFO, .value = 3 }, .{ .reg = CX.DB_STENCIL_INFO, .value = 1 } } },
    };
    for (cases) |c| {
        const before = reasons();
        b.scene(state.SWAP.STANDARD);
        for (c.set) |r| b.cx(r.reg, r.value);
        // (stencil is asked for by the depth control's own bit)
        if (c.why == .stencil) b.cx(CX.DB_DEPTH_CONTROL, 1);
        b.draw(3);
        try b.run();
        const after = reasons();
        for (0..REASONS) |i| {
            const want = before[i] + @intFromBool(i == @intFromEnum(c.why));
            if (after[i] != want) {
                std.debug.print("{s}: reason {s} is {d}, should be {d}\n", .{ @tagName(c.why), @tagName(@as(Why, @enumFromInt(i))), after[i], want });
                return error.TestExpectedEqual;
            }
        }
    }
    try testing.expectEqual(@as(u64, 0), stats.drawn);

    // An sRGB target with no blending is drawn, and the shaders are told
    // to encode.
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.CB_COLOR0_INFO, srgb);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.drawn);
    try testing.expect(Plain.last.target_srgb);

    // A primitive the engine has none for.
    b.scene(state.SWAP.STANDARD);
    b.uc(agcdriver.UC.PRIMITIVE_TYPE, PRIMITIVE.RECTANGLES);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.primitive));

    // A flat value from the first vertex (as a queue starts): the engine
    // would take the last, so the draw is left out; told to take the
    // last, it is drawn.
    Plain.flat = true;
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.provoking));
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.SU_SC_MODE_CNTL, 1 << 19);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.provoking));
    try testing.expectEqual(@as(u64, 2), stats.drawn);
    Plain.flat = false;

    // Nothing makes shaders.
    shade = null;
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.no_shaders));
    shade = Plain.make;

    // Nothing to draw is not a draw left out: a scissor with no pixel in
    // it, a draw kept from the rasteriser, colour off with no depth
    // target. (A draw of no vertices does not leave the driver.)
    const drawn = stats.drawn;
    b.scene(state.SWAP.STANDARD);
    b.draw(0);
    b.cx(CX.GENERIC_SCISSOR_BR, 0);
    b.draw(3);
    b.cx(CX.GENERIC_SCISSOR_BR, 0x4000_4000);
    b.cx(CX.CLIP_CNTL, (1 << 19) | (1 << 22));
    b.draw(3);
    b.cx(CX.CLIP_CNTL, 1 << 19);
    b.colourOff();
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 3), stats.empty);
    try testing.expectEqual(drawn, stats.drawn);

    // A second colour target: the draw is drawn, into the first.
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.CB_COLOR0_INFO + CX.CB_STRIDE, state.COLOR.RGBA8 << 2);
    b.draw(3);
    try b.run();
    try testing.expectEqual(drawn + 1, stats.drawn);
    try testing.expectEqual(@as(u64, 1), stats.targets_dropped);
}

test "a draw left out leaves no image behind for its target" {
    setUp();
    var b: Buffer = .{ .at = 0x7_3333_0000 };
    var out: [W * H]u32 = undefined;
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(corner);
    // Left out for its primitive, for want of shaders, and for its
    // shaders' flat value: the display is still told nothing was drawn
    // there (and shows what the game's own memory holds).
    b.scene(state.SWAP.STANDARD);
    b.uc(agcdriver.UC.PRIMITIVE_TYPE, PRIMITIVE.RECTANGLES);
    b.draw(3);
    try b.run();
    shade = null;
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    shade = Plain.make;
    Plain.flat = true;
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    Plain.flat = false;
    try testing.expectEqual(@as(u64, 0), stats.drawn);
    try testing.expect(!frame(b.at, W, H, &out));
    // Drawn, it has one.
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try testing.expect(frame(b.at, W, H, &out));
    try testing.expectEqual(@as(u32, 0xFF_FFFF), out[2 * W + 2] & 0x00FF_FFFF);
}

test "the viewport's depth scale, offset and range reach the engine" {
    setUp();
    var b: Buffer = .{};
    try b.paint(.{ 0, 0, 0, 0 });
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(all);

    // Depth as it is (scale 1, offset 0), range 0 to 1: a triangle at
    // -0.5 is before the range and is not drawn.
    Plain.depth(-0.5);
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0), at(10, 10));
    // Depth halved and moved up by a half (clip space from -1 to 1): the
    // same triangle is at 0.25 and is drawn.
    b.scene(state.SWAP.STANDARD);
    _ = b.w.setRegisters(.cx, CX.VPORT_XSCALE_0 + 4, &.{ bitsOf(0.5), bitsOf(0.5) }).?;
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0xFF_FFFF), at(10, 10));
    // A range that ends at 0.2 leaves it out again.
    try b.paint(.{ 0, 0, 0, 0 });
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.depth(-0.5);
    b.scene(state.SWAP.STANDARD);
    _ = b.w.setRegisters(.cx, CX.VPORT_XSCALE_0 + 4, &.{ bitsOf(0.5), bitsOf(0.5) }).?;
    _ = b.w.setRegisters(.cx, CX.VPORT_ZMIN_0, &.{ bitsOf(0), bitsOf(0.2) }).?;
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0), at(10, 10));
}

test "depth: cleared by the game, tested, written; a target that is not what the game drew is not tested against" {
    setUp();
    var b: Buffer = .{};
    try b.paint(.{ 0, 0, 0, 0 });

    // Before the game has cleared its depth target, a test against it is
    // against nothing the game drew: left out.
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(all);
    Plain.depth(0.25);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(1, true);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.depth_unknown));
    try look();
    try testing.expectEqual(@as(u32, 0), at(20, 20));

    // Cleared to the farthest. Green at 0.25 with "less": drawn.
    try b.clearDepth(1.0);
    try testing.expectEqual(@as(u64, 1), stats.cleared);
    Plain.color(.{ 0, 1, 0, 1 });
    Plain.corners(all);
    Plain.depth(0.25);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(1, true);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FF00), at(20, 20));
    // Red at 0.75: behind, not drawn. With "greater": drawn.
    Plain.color(.{ 1, 0, 0, 1 });
    Plain.depth(0.75);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(1, true);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FF00), at(20, 20));
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, false);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0xFF_0000), at(20, 20));

    // Depth the other way round, as games have it: cleared to 0, nearer
    // is greater. Blue at 0.5 is drawn; green at 0.25, farther, is not.
    try b.clearDepth(0.0);
    Plain.color(.{ 0, 0, 1, 1 });
    Plain.corners(all);
    Plain.depth(0.5);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.draw(3);
    try b.run();
    Plain.color(.{ 0, 1, 0, 1 });
    Plain.depth(0.25);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_00FF), at(20, 20));

    // A pass into depth alone (colour off), then colour where the depth
    // is equal: the corner triangle's depth is laid down at 0.75 over the
    // 0.5 everywhere, and white drawn all over at 0.75 with "equal"
    // shows in the corner triangle only.
    Plain.corners(corner);
    Plain.depth(0.75);
    b.scene(state.SWAP.STANDARD);
    b.colourOff();
    b.depthTest(4, true);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.depth_only);
    try testing.expect(Plain.last.depth_only);
    try look();
    try testing.expectEqual(@as(u32, 0x00_00FF), at(2, 2));
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(all);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(2, false);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0xFF_FFFF), at(2, 2));
    try testing.expectEqual(@as(u32, 0x00_00FF), at(20, 20));

    // A draw that was to write depth is left out (its primitive is one
    // the engine has none for): what the target holds is no longer what
    // the game drew, and the next test against it is left out too, until
    // the game clears it.
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.uc(agcdriver.UC.PRIMITIVE_TYPE, PRIMITIVE.RECTANGLES);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.primitive));
    const unknown = stats.leftOut(.depth_unknown);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.draw(3);
    try b.run();
    try testing.expectEqual(unknown + 1, stats.leftOut(.depth_unknown));
    try b.clearDepth(0.0);
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.draw(3);
    try b.run();
    try testing.expectEqual(unknown + 1, stats.leftOut(.depth_unknown));

    // A clear of part of the target (a scissor) does not make the whole
    // of it the game's again; a depth target of another height than the
    // colour target, a biased draw and a bounds test are left out.
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.uc(agcdriver.UC.PRIMITIVE_TYPE, PRIMITIVE.RECTANGLES);
    b.draw(3);
    try b.run();
    Plain.corners(all);
    b.scene(state.SWAP.STANDARD);
    b.colourOff();
    b.depthTarget();
    b.cx(CX.DB_RENDER_CONTROL, 1);
    b.cx(CX.GENERIC_SCISSOR_BR, 8 | (8 << 16));
    b.draw(3);
    try b.run();
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.draw(3);
    try b.run();
    try testing.expectEqual(unknown + 2, stats.leftOut(.depth_unknown));
    try b.clearDepth(0.0);

    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, true);
    b.cx(CX.DB_DEPTH_SIZE, (W - 1) | ((2 * H - 1) << 16));
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.depth_target));
    b.scene(state.SWAP.STANDARD);
    b.depthTest(4, false);
    b.cx(CX.SU_SC_MODE_CNTL, 1 << 11);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.depth_bias));
    b.scene(state.SWAP.STANDARD);
    b.depthTarget();
    b.cx(CX.DB_DEPTH_CONTROL, (1 << 1) | (1 << 3) | (4 << 4));
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.depth_bounds));
    // A clear that is to draw colour too.
    b.scene(state.SWAP.STANDARD);
    b.depthTarget();
    b.cx(CX.DB_RENDER_CONTROL, 1);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.clear_with_color));
}
