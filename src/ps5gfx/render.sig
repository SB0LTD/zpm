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
//! A draw this cannot carry out is left out, counted by its reason, and
//! the reason said once. Nothing is guessed at: a frame with a draw
//! missing shows what is not done, a frame with a draw done wrongly
//! hides it. Left out so far: draws with a geometry or hull stage, with
//! multisampling, with stencil, with colour writes off, of rectangles
//! and quads, into targets that are not four bytes a pixel, and the
//! second and later colour targets of a draw (the first is drawn).
//!
//! One engine, used by the driver's worker (draws) and by the display's
//! thread (frames): a lock is held around every use.
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
};

/// A draw's shaders as the engine takes them, and what they read. The
/// images named are whoever answered's, and stay as they are until it is
/// asked again.
pub const Shading = struct {
    pipe: *const raster.Pipeline,
    uniforms: []const u32 = &.{},
    buffers: [raster.MAX_BUFFERS]?*engine.Image = [_]?*engine.Image{null} ** raster.MAX_BUFFERS,
    textures: [texture.MAX_TEX]?*engine.Image = [_]?*engine.Image{null} ** texture.MAX_TEX,
};

/// Null: these shaders cannot be made (the draw is left out).
pub const Shade = *const fn (e: *Engine, r: Request) ?Shading;

pub var shade: ?Shade = null;

// ── Counts ──────────────────────────────────────────────────────────────────

/// Why a draw was left out.
pub const Why = enum(u8) {
    no_renderer,
    no_shaders,
    shaders,
    stages,
    color_off,
    color_mode,
    no_target,
    target_layout,
    samples,
    primitive,
    polygon_mode,
    viewport,
    window_offset,
    stencil,
    depth_target,
    blend,
    engine,

    fn text(w: Why) []const u8 {
        return switch (w) {
            .no_renderer => "the renderer was not set up",
            .no_shaders => "nothing makes shaders yet",
            .shaders => "its shaders could not be made",
            .stages => "it has a geometry or hull stage",
            .color_off => "colour writes are off (a depth-only draw)",
            .color_mode => "the colour path is in a mode that is not drawing",
            .no_target => "it has no colour target",
            .target_layout => "its target is not four bytes a pixel, or there is no memory for it",
            .samples => "it is multisampled",
            .primitive => "its primitive is one the engine does not draw (rectangles, quads, patches)",
            .polygon_mode => "its triangles are to be lines or points",
            .viewport => "its viewport's transform is on in part",
            .window_offset => "its vertices are moved by a window offset",
            .stencil => "it tests stencil",
            .depth_target => "its depth target is smaller than its colour target, or there is no memory for it",
            .blend => "its blending uses a second colour or a rule the engine has none for",
            .engine => "the engine refused it",
        };
    }
};

const REASONS = @typeInfo(Why).@"enum".field_names.len;

pub const stats = struct {
    /// Draws handed to the engine.
    pub var drawn: u64 = 0;
    /// Draws with nothing to draw: no vertices, a scissor that holds no
    /// pixel, a draw marked as not reaching the rasteriser.
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
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[ps5] gfx: " ++ prefix ++ "{s} (said once)\n", .{text}) catch return;
    _ = ps5.sys.call(ps5.abi.Sys.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
}

fn leave(w: Why) void {
    const i = @intFromEnum(w);
    stats.left_out[i] += 1;
    if (!said[i]) say("a draw is left out: ", w.text());
    said[i] = true;
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
/// requests for frames. Once; a second call changes nothing.
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

fn onDraw(s: *const State, d: agcdriver.Draw) void {
    lock.lock();
    defer lock.unlock();
    if (!ready) return leave(.no_renderer);
    if (drawOne(s, d)) |why| leave(why);
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

/// Memory at a game's address as an image the engine reads words from
/// (an index buffer: the engine reads what is there when the draw runs,
/// as the GPU would; the driver has every draw finished before a game
/// hears that the GPU passed it). The engine reads whole words, so the
/// length is taken up to one: as many as three bytes past what the game
/// named may be read (and are never used).
fn memory(address: u64, bytes: usize) engine.Image {
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(address)));
    const whole = std.mem.alignForward(usize, bytes, 4);
    return engine.wrap(.{ .cpu = p[0..whole], .bytes = whole }, 1, 1, 4, .r32ui, false);
}

/// One draw. Null: drawn, or there was nothing to draw.
fn drawOne(s: *const State, d: agcdriver.Draw) ?Why {
    if (d.count == 0 or d.instances == 0) {
        stats.empty += 1;
        return null;
    }
    const mode = state.raster(s);
    if (mode.kill) {
        stats.empty += 1;
        return null;
    }
    switch (state.colorMode(s)) {
        .off => return .color_off,
        .other => return .color_mode,
        .normal => {},
    }
    const stages = state.stages(s);
    if (stages.geometry() or stages.hull()) return .stages;
    if (!mode.fill) return .polygon_mode;
    if (mode.vertices_offset) {
        const by = state.windowOffset(s);
        if (by[0] != 0 or by[1] != 0) return .window_offset;
    }

    const t = state.target(s, 0) orelse return .no_target;
    if (t.samples_log2 != 0 or mode.samples_log2 != 0) return .samples;
    const topology = convert.topology(state.primitive(s)) orelse return .primitive;
    const vp = convert.viewport(state.viewport(s, 0) orelse return .viewport, t.height);
    const rect = convert.rect(state.scissor(s, t.width, t.height, 0), t.width, t.height) orelse {
        stats.empty += 1;
        return null;
    };
    const dz = state.depth(s);
    if (dz.stencil_on) return .stencil;
    var blend: ?raster.Blend = null;
    if (state.blend(s, 0)) |b| blend = convert.blend(b) orelse return .blend;

    const color = targets.color(&eng, t) orelse return .target_layout;
    var depth: ?*engine.Image = null;
    if (dz.test_on) {
        // (a depth test with no target to test against passes everything)
        if (dz.format != 0) {
            if (dz.width < t.width or dz.height < t.height) return .depth_target;
            depth = targets.depth(&eng, dz) orelse return .depth_target;
        }
    }

    const indexed = d.index_size != 0;
    const make = shade orelse return .no_shaders;
    const sh = make(&eng, .{
        .state = s,
        .add_vertex = if (indexed) d.base_vertex else 0,
        .add_instance = d.first_instance,
    }) orelse return .shaders;

    var rd = raster.Draw{ .pipe = sh.pipe, .color = color };
    rd.uniforms = sh.uniforms;
    rd.buffers = sh.buffers;
    rd.textures = sh.textures;
    rd.topology = topology;
    rd.count = d.count;
    rd.instances = d.instances;
    var indices: engine.Image = undefined;
    if (indexed) {
        indices = memory(d.index_address, @as(usize, d.count) * d.index_size);
        rd.index = &indices;
        rd.index_size = d.index_size;
    } else {
        rd.first = @bitCast(d.base_vertex);
    }
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
    rd.blend = blend;
    rd.keep = convert.keep(color.format, t.write);

    for (1..state.TARGETS) |n| {
        if (state.target(s, @intCast(n)) == null) continue;
        stats.targets_dropped += 1;
        if (!said_targets) say("", "a draw has more than one colour target: only the first is drawn");
        said_targets = true;
        break;
    }
    if (!eng.draw(&rd)) return .engine;
    stats.drawn += 1;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const kir = @import("gpu").kir;
const pm4 = ps5.pm4;
const CX = state.CX;
const PRIMITIVE = ps5.agc.shader.PRIMITIVE;

/// Shaders of the test's own: three corners from the uniform words (x, y
/// in clip space, from word 4), one colour for every pixel (words 0 to
/// 3).
const Plain = struct {
    var words = [_]u32{0} ** 10;
    var pipe: raster.Pipeline = undefined;
    var made = false;
    var asked: u32 = 0;
    var last: Request = undefined;

    fn vertex(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        const off = k.op2(.iadd, .u32, kir.r(k.op2(.shl, .u32, kir.r(io.vertex_id), kir.u(3))), kir.u(16));
        const m = kir.global(io.uniforms, 32);
        io.position = .{
            k.load(.f32, m, kir.r(off)),
            k.load(.f32, m, kir.r(k.op2(.iadd, .u32, kir.r(off), kir.u(4)))),
            k.mov(.f32, kir.f(0.5)),
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
        return .{ .pipe = &pipe, .uniforms = &words };
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
};

const Host = struct {
    var pool: [8 << 20]u8 align(64) = undefined;
    var work: [4 << 20]u8 align(64) = undefined;
};

const W = 32;
const H = 32;
/// Where the test's target "is" (the address a game would name; its
/// bytes are never touched).
const TARGET: u64 = 0x7_1234_5600;

fn bitsOf(x: f32) u32 {
    return @bitCast(x);
}

/// A command buffer in the making.
const Buffer = struct {
    words: [512]u32 = undefined,
    w: pm4.Writer = undefined,

    fn begin(b: *Buffer) void {
        b.w = .{ .words = &b.words };
    }

    fn cx(b: *Buffer, reg: u32, value: u32) void {
        _ = b.w.setRegisters(.cx, reg, &.{value}).?;
    }

    /// A 32 x 32 target of four bytes at TARGET, the whole of clip space
    /// on it (y up), triangles; and every other register a test here
    /// changes put back to what a queue starts with (the queue's registers
    /// stay as the last buffer left them, from test to test).
    fn scene(b: *Buffer, swap: u32) void {
        b.begin();
        b.cx(CX.SHADER_STAGES_EN, 0);
        b.cx(CX.CB_COLOR_CONTROL, 0x00CC_0010);
        b.cx(CX.CB_TARGET_MASK, 0xFFFF_FFFF);
        b.cx(CX.CB_COLOR0_INFO + CX.CB_STRIDE, 0);
        b.cx(CX.BLEND0_CONTROL, 0x2001_0001);
        b.cx(CX.SU_SC_MODE_CNTL, 0);
        b.cx(CX.AA_CONFIG, 0);
        b.cx(CX.GENERIC_SCISSOR_TL, 0x8000_0000);
        b.cx(CX.GENERIC_SCISSOR_BR, 0x4000_4000);
        b.cx(CX.DB_DEPTH_CONTROL, 0);
        b.cx(CX.DB_Z_INFO, 0);
        b.cx(CX.DB_STENCIL_INFO, 0);
        _ = b.w.setRegisters(.uc, agcdriver.UC.INDEX_OFFSET, &.{0}).?;
        b.cx(CX.CB_COLOR0_BASE, @truncate(TARGET >> 8));
        b.cx(CX.CB_COLOR0_BASE_EXT, @truncate(TARGET >> 40));
        b.cx(CX.CB_COLOR0_INFO, (state.COLOR.RGBA8 << 2) | (state.NUMBER.UNORM << 8) | (swap << 11));
        b.cx(CX.CB_COLOR0_ATTRIB2, (H - 1) | ((W - 1) << 14));
        b.cx(CX.CB_COLOR0_ATTRIB3, 1 << 24);
        b.cx(CX.VTE_CNTL, 0x43F);
        _ = b.w.setRegisters(.cx, CX.VPORT_XSCALE_0, &.{ bitsOf(W / 2), bitsOf(W / 2), bitsOf(-H / 2), bitsOf(H / 2), bitsOf(1), bitsOf(0) }).?;
        _ = b.w.setRegisters(.cx, CX.VPORT_ZMIN_0, &.{ bitsOf(0), bitsOf(1) }).?;
        b.cx(CX.CLIP_CNTL, 1 << 19);
        _ = b.w.setRegisters(.uc, agcdriver.UC.PRIMITIVE_TYPE, &.{PRIMITIVE.TRIANGLES}).?;
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
};

fn setUp() void {
    install(.{ .pool = &Host.pool, .cpu_work = &Host.work });
    shade = Plain.make;
    stats.clear();
    Plain.asked = 0;
}

var shot: [W * H]u32 = undefined;

/// The frame at TARGET, and one of its pixels (x from the left, y from
/// the top) without its alpha.
fn look() !void {
    @memset(&shot, 0xDEAD_BEEF);
    try testing.expect(frame(TARGET, W, H, &shot));
}

fn at(x: usize, y: usize) u32 {
    return shot[y * W + x] & 0x00FF_FFFF;
}

/// A triangle in the top left corner of the screen, its corners in the
/// order that goes round clockwise there: top left, top right, bottom
/// left of a 16-pixel square.
const corner = [3][2]f32{ .{ -1, 1 }, .{ 0, 1 }, .{ -1, 0 } };

test "a triangle from a game's command buffer lands where the console would put it" {
    setUp();
    Plain.color(.{ 1, 0.5, 0.25, 1 });
    Plain.corners(corner);
    var b: Buffer = .{};
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.drawn);
    try testing.expectEqual(@as(u32, 1), Plain.asked);
    try testing.expectEqual(@as(i32, 0), Plain.last.add_vertex);

    try look();
    // Inside: near the top left corner, and just inside the long edge.
    const orange: u32 = 0xFF_8040;
    try testing.expectEqual(orange, at(2, 2));
    try testing.expectEqual(orange, at(12, 2));
    try testing.expectEqual(orange, at(2, 12));
    // Outside: past the long edge, and the other three corners (a picture
    // upside down would have the bottom left painted).
    try testing.expectEqual(@as(u32, 0), at(10, 10));
    try testing.expectEqual(@as(u32, 0), at(2, 29));
    try testing.expectEqual(@as(u32, 0), at(29, 2));
    try testing.expectEqual(@as(u32, 0), at(29, 29));

    // Blue first in the target's memory: the display's frame is the same.
    setUp();
    b.scene(state.SWAP.ALTERNATE);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(orange, at(2, 2));
    try testing.expectEqual(@as(u32, 0), at(2, 29));
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
        Plain.color(.{ 1, 1, 1, 1 });
        Plain.corners(corner);
        var b: Buffer = .{};
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
        // (the target is the same one for every case: black over all of
        // it for the next, with nothing dropped)
        Plain.color(.{ 0, 0, 0, 0 });
        Plain.corners(.{ .{ -1, 1 }, .{ 3, 1 }, .{ -1, -3 } });
        b.scene(state.SWAP.STANDARD);
        b.draw(3);
        try b.run();
        try look();
        try testing.expectEqual(@as(u32, 0), at(2, 2));
    }
}

test "the scissor, the write mask and blending reach the engine" {
    setUp();
    var b: Buffer = .{};
    // Black over everything first (the target is kept from test to test).
    Plain.color(.{ 0, 0, 0, 0 });
    Plain.corners(.{ .{ -1, 1 }, .{ 3, 1 }, .{ -1, -3 } });
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();

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
    const mixed = at(2, 2);
    // (red 0.5, green and blue 0.5 of 1: within one step of 0x80)
    for ([_]u5{ 16, 8, 0 }) |shift| {
        const ch: i32 = @intCast((mixed >> shift) & 0xFF);
        try testing.expect(@abs(ch - 0x80) <= 1);
    }
    // Where the first triangle was cut away there is half red over black.
    const plain = at(12, 2);
    try testing.expect(@abs(@as(i32, @intCast((plain >> 16) & 0xFF)) - 0x80) <= 1);
    try testing.expectEqual(@as(u32, 0), plain & 0xFFFF);
    try testing.expectEqual(@as(u64, 3), stats.drawn);
}

test "indices are read from the game's memory; an indexed draw's base vertex is the shaders' to add" {
    setUp();
    var b: Buffer = .{};
    Plain.color(.{ 0, 0, 0, 0 });
    Plain.corners(.{ .{ -1, 1 }, .{ 3, 1 }, .{ -1, -3 } });
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();

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
        _ = b.w.setRegisters(.uc, agcdriver.UC.INDEX_OFFSET, &.{7}).?;
        const addr = @intFromPtr(c.list);
        _ = b.w.put(pm4.OP.INDEX_TYPE, 0, &.{0}).?;
        _ = b.w.put(pm4.OP.DRAW_INDEX_2, 0, &.{ 3, @truncate(addr), @truncate(addr >> 32), 3, 0 }).?;
        try b.run();
        try look();
        try testing.expectEqual(c.shown, at(2, 2) != 0);
    }
    try testing.expectEqual(@as(i32, 7), Plain.last.add_vertex);
}

test "draws that cannot be carried out are left out and counted by their reason" {
    setUp();
    var b: Buffer = .{};
    Plain.color(.{ 1, 1, 1, 1 });
    Plain.corners(corner);

    const cases = [_]struct { why: Why, reg: u32, value: u32 }{
        .{ .why = .stages, .reg = CX.SHADER_STAGES_EN, .value = 0x20 },
        .{ .why = .stages, .reg = CX.SHADER_STAGES_EN, .value = 0x04 },
        .{ .why = .color_off, .reg = CX.CB_COLOR_CONTROL, .value = 0x00CC_0000 },
        .{ .why = .color_mode, .reg = CX.CB_COLOR_CONTROL, .value = 0x00CC_0040 },
        .{ .why = .polygon_mode, .reg = CX.SU_SC_MODE_CNTL, .value = (1 << 3) | (1 << 5) | (1 << 8) },
        .{ .why = .samples, .reg = CX.AA_CONFIG, .value = 2 },
        .{ .why = .viewport, .reg = CX.VTE_CNTL, .value = 0x03F },
        .{ .why = .blend, .reg = CX.BLEND0_CONTROL, .value = (1 << 30) | state.FACTOR.SRC1_COLOR },
        .{ .why = .target_layout, .reg = CX.CB_COLOR0_INFO, .value = (state.COLOR.RGBA16 << 2) | (state.NUMBER.FLOAT << 8) },
        .{ .why = .no_target, .reg = CX.CB_COLOR0_INFO, .value = 0 },
    };
    for (cases) |c| {
        const before = stats.leftOut(c.why);
        b.scene(state.SWAP.STANDARD);
        b.cx(c.reg, c.value);
        b.draw(3);
        try b.run();
        if (stats.leftOut(c.why) != before + 1) {
            std.debug.print("{s}: not counted\n", .{@tagName(c.why)});
            return error.TestExpectedEqual;
        }
    }
    try testing.expectEqual(@as(u64, 0), stats.drawn);

    // A primitive the engine has none for; stencil.
    b.scene(state.SWAP.STANDARD);
    _ = b.w.setRegisters(.uc, agcdriver.UC.PRIMITIVE_TYPE, &.{PRIMITIVE.RECTANGLES}).?;
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.primitive));
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.DB_Z_INFO, 3);
    b.cx(CX.DB_STENCIL_INFO, 1);
    b.cx(CX.DB_DEPTH_CONTROL, 1);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.stencil));

    // Nothing makes shaders.
    shade = null;
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.leftOut(.no_shaders));
    shade = Plain.make;

    // Nothing to draw is not a draw left out: a scissor with no pixel in
    // it, a draw kept from the rasteriser. (A draw of no vertices does not
    // leave the driver.)
    b.scene(state.SWAP.STANDARD);
    b.draw(0);
    b.cx(CX.GENERIC_SCISSOR_BR, 0);
    b.draw(3);
    b.cx(CX.GENERIC_SCISSOR_BR, 0x4000_4000);
    b.cx(CX.CLIP_CNTL, (1 << 19) | (1 << 22));
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 2), stats.empty);
    try testing.expectEqual(@as(u64, 0), stats.drawn);
    for (0..REASONS) |i| {
        if (i != @intFromEnum(Why.no_shaders)) continue;
        try testing.expectEqual(@as(u64, 1), stats.left_out[i]);
    }

    // A second colour target: the draw is drawn, into the first.
    b.scene(state.SWAP.STANDARD);
    b.cx(CX.CB_COLOR0_INFO + CX.CB_STRIDE, state.COLOR.RGBA8 << 2);
    b.draw(3);
    try b.run();
    try testing.expectEqual(@as(u64, 1), stats.drawn);
    try testing.expectEqual(@as(u64, 1), stats.targets_dropped);
}

test "depth: a nearer triangle hides a farther one drawn after it" {
    setUp();
    var b: Buffer = .{};
    const DEPTH: u64 = 0x7_2000_0000;
    const Deep = struct {
        /// The same shaders with the depth from uniform word 10.
        var words = [_]u32{0} ** 11;
        var pipe: raster.Pipeline = undefined;
        var made = false;

        fn vertex(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
            Plain.vertex(null, k, io);
            io.position[2] = raster.uniform(k, .f32, io.uniforms, 10);
        }
        fn make(_: *Engine, _: Request) ?Shading {
            if (!made) pipe = raster.Pipeline.init(.{ .vertex = vertex, .fragment = Plain.fragment });
            made = true;
            @memcpy(words[0..10], &Plain.words);
            return .{ .pipe = &pipe, .uniforms = &words };
        }
    };
    shade = Deep.make;
    const all = [3][2]f32{ .{ -1, 1 }, .{ 3, 1 }, .{ -1, -3 } };

    // Black, with no depth test: the depth target is not touched.
    Plain.color(.{ 0, 0, 0, 0 });
    Plain.corners(all);
    b.scene(state.SWAP.STANDARD);
    b.draw(3);
    try b.run();

    const depthOn = struct {
        fn set(buf: *Buffer, func: u32) void {
            buf.cx(CX.DB_Z_INFO, 3);
            buf.cx(CX.DB_Z_WRITE_BASE, @truncate(DEPTH >> 8));
            buf.cx(CX.DB_Z_WRITE_BASE_HI, @truncate(DEPTH >> 40));
            buf.cx(CX.DB_DEPTH_SIZE, (W - 1) | ((H - 1) << 16));
            buf.cx(CX.DB_DEPTH_CONTROL, (1 << 1) | (1 << 2) | (func << 4));
        }
    }.set;

    // Green over everything at depth 0.25, "less" against a target that
    // starts at the farthest: drawn.
    Plain.color(.{ 0, 1, 0, 1 });
    Deep.words[10] = bitsOf(0.25);
    b.scene(state.SWAP.STANDARD);
    depthOn(&b, 1);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FF00), at(20, 20));

    // Red over everything at depth 0.75: behind, not drawn.
    Plain.color(.{ 1, 0, 0, 1 });
    Deep.words[10] = bitsOf(0.75);
    b.scene(state.SWAP.STANDARD);
    depthOn(&b, 1);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0x00_FF00), at(20, 20));

    // The same red with "greater": drawn.
    b.scene(state.SWAP.STANDARD);
    depthOn(&b, 4);
    b.draw(3);
    try b.run();
    try look();
    try testing.expectEqual(@as(u32, 0xFF_0000), at(20, 20));
    try testing.expectEqual(@as(u64, 4), stats.drawn);
}
