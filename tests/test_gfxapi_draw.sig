//! gfxapi's draws: one GL scene of triangles drawn three ways, on the CPU
//! (KIR's interpreter running the draw kernels on the images' memory), on
//! EmuDevice (the interpreter as a GPU, its memory not coherent), and on
//! the emulated Adreno through Galaxy's calls (the kernels compiled to
//! ir3, run by ir3_emu). Every run must give the same bytes.
//!
//! The scene: GL's fill rule (two triangles of a quad drawn with additive
//! blending: no pixel twice, none missed), a strip's interpolated colors,
//! the depth test, culling by winding, indexed and instanced quads with a
//! per-instance attribute, scissor and color mask, flat shading, a fan on
//! the window's top-down buffer. The shaders are KIR emitters, as the
//! GLSL compiler will make them.
//!
//! A second scene is larger than a bin (raster.BIN): blended triangles all
//! over, big ones across bins under a scissor, a thin strip. Binned, not
//! binned, and binned with lists that run over must give the same bytes.

const std = @import("std");
const gpu = @import("gpu");
const adreno = @import("adreno");
const gfxapi = @import("gfxapi");
const kir = gpu.kir;
const engine = gfxapi.engine;
const gles = gfxapi.gles;
const raster = gfxapi.raster;
const g = gfxapi.glenum;
const node = gfxapi.node;

const r = kir.r;

// ── The shaders ────────────────────────────────────────────────────────────

fn fl(k: *kir.Kernel, x: kir.V) kir.V {
    return k.mov(.f32, r(x));
}

/// attribute 0: position (clip space), 1: color, 2: an offset per instance
/// (x, y); varyings: the color
const Colored = struct {
    fn vertex(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        for (0..4) |c| io.position[c] = fl(k, io.attr[0][c]);
        for (0..4) |c| io.varying[c] = fl(k, io.attr[1][c]);
    }
    fn instanced(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        vertex(null, k, io);
        io.position[0] = k.op2(.fadd, .f32, r(io.position[0]), r(fl(k, io.attr[2][0])));
        io.position[1] = k.op2(.fadd, .f32, r(io.position[1]), r(fl(k, io.attr[2][1])));
    }
    fn fragment(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        _ = k;
        for (0..4) |c| io.color[c] = io.varying[c];
    }
};

/// the color from uniforms 0..3
const Uniform = struct {
    fn vertex(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        for (0..4) |c| io.position[c] = fl(k, io.attr[0][c]);
    }
    fn fragment(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        for (0..4) |c| io.color[c] = raster.uniform(k, .f32, io.uniforms, @intCast(c));
    }
};

var colored = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .vertex = Colored.vertex, .fragment = Colored.fragment });
var flat = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .flat = 0xf, .vertex = Colored.vertex, .fragment = Colored.fragment });
var instanced = raster.Pipeline.init(.{ .attrs = 3, .varyings = 4, .vertex = Colored.instanced, .fragment = Colored.fragment });
var solid = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .vertex = Uniform.vertex, .fragment = Uniform.fragment });
const pipes = [_]*raster.Pipeline{ &colored, &flat, &instanced, &solid };

// ── The scene ──────────────────────────────────────────────────────────────

const W = 64;
const H = 32;
const WW = 32;
const WH = 16;

const Out = struct {
    fbo: [W * H * 4]u8 = undefined,
    win: [WW * WH * 4]u8 = undefined,
    errors: u32 = 0,
};

var objs: gles.Objects = undefined;
var ctx: gles.Context = undefined;

/// Pixel x (of w) as NDC.
fn nx(x: f32, w: f32) f32 {
    return 2 * x / w - 1;
}

const Vert = extern struct { x: f32, y: f32, z: f32, w: f32, r: f32, g: f32, b: f32, a: f32 };

fn v(x: f32, y: f32, z: f32, col: [4]f32) Vert {
    return .{ .x = nx(x, W), .y = nx(y, H), .z = z, .w = 1, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
}

/// The quad [x0, x1) x [y0, y1) as two triangles (counter-clockwise).
fn quad(x0: f32, y0: f32, x1: f32, y1: f32, z: f32, col: [4]f32) [6]Vert {
    return .{ v(x0, y0, z, col), v(x1, y0, z, col), v(x1, y1, z, col), v(x0, y0, z, col), v(x1, y1, z, col), v(x0, y1, z, col) };
}

fn noErr(c: *gles.Context, out: anytype) void {
    if (c.getError() != g.NO_ERROR) out.errors += 1;
}

/// The vertices in buffer `name` at attributes 0 (position) and 1 (color),
/// then a draw.
fn drawVerts(c: *gles.Context, buf: u32, verts: []const Vert, mode: u32) void {
    c.bindBuffer(g.ARRAY_BUFFER, buf);
    c.bufferData(g.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(Vert)), verts.ptr, g.STREAM_DRAW);
    c.vertexAttribPointer(0, 4, g.FLOAT, false, @sizeOf(Vert), 0, false);
    c.vertexAttribPointer(1, 4, g.FLOAT, false, @sizeOf(Vert), 16, false);
    c.enableVertexAttribArray(0, true);
    c.enableVertexAttribArray(1, true);
    c.drawArrays(mode, 0, @intCast(verts.len), 1);
}

fn scene(eng: *engine.Engine, out: *Out) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
    defer for (pipes) |p| eng.unloadPipeline(p);
    // a framebuffer object: RGBA8 and depth-stencil
    var tex: [1]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(g.TEXTURE_2D, tex[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    var rb: [1]u32 = undefined;
    c.genRenderbuffers(&rb);
    c.bindRenderbuffer(g.RENDERBUFFER, rb[0]);
    c.renderbufferStorage(g.RENDERBUFFER, 0, g.DEPTH24_STENCIL8, W, H);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    c.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_STENCIL_ATTACHMENT, g.RENDERBUFFER, rb[0]);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, W, H);
    c.clearColor(0, 0, 0, 0);
    c.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT);
    var vao: [1]u32 = undefined;
    c.genVertexArrays(&vao);
    c.bindVertexArray(vao[0]);
    var bufs: [4]u32 = undefined;
    c.genBuffers(&bufs);
    noErr(c, out);

    // 1. the fill rule: a square's two triangles, added: no pixel twice,
    // none missed (its diagonal runs through pixel centers: the tie rule)
    c.usePipeline(&colored, &.{});
    c.enable(g.BLEND, true);
    c.blendFunc(g.ONE, g.ONE, g.ONE, g.ONE);
    drawVerts(c, bufs[0], &quad(0, 0, 16, 16, 0, .{ 0.25, 0.5, 0.125, 0.5 }), g.TRIANGLES);
    c.enable(g.BLEND, false);
    noErr(c, out);

    // 2. a strip, red on the left to blue on the right
    const red = [4]f32{ 1, 0, 0, 1 };
    const blue = [4]f32{ 0, 0, 1, 1 };
    drawVerts(c, bufs[0], &.{ v(32, 0, 0, red), v(64, 0, 0, blue), v(32, 16, 0, red), v(64, 16, 0, blue) }, g.TRIANGLE_STRIP);
    noErr(c, out);

    // 3. depth: near green first, far red after: green stays (LESS)
    c.enable(g.DEPTH_TEST, true);
    drawVerts(c, bufs[0], &quad(40, 16, 56, 32, -0.5, .{ 0, 1, 0, 1 }), g.TRIANGLES);
    drawVerts(c, bufs[0], &quad(36, 20, 60, 28, 0.5, red), g.TRIANGLES);
    c.enable(g.DEPTH_TEST, false);
    noErr(c, out);

    // 4. culling: back faces off; a clockwise triangle is not drawn
    c.enable(g.CULL_FACE, true);
    c.cullFace(g.BACK);
    drawVerts(c, bufs[0], &.{ v(0, 24, 0, red), v(0, 32, 0, red), v(8, 24, 0, red), v(8, 24, 0, blue), v(16, 24, 0, blue), v(8, 32, 0, blue) }, g.TRIANGLES);
    c.enable(g.CULL_FACE, false);
    noErr(c, out);

    // 5. indexed, instanced: a 4 x 4 quad three times, 6 pixels apart
    c.usePipeline(&instanced, &.{});
    const qv = [_]Vert{ v(0, 16, 0, .{ 1, 1, 0, 1 }), v(4, 16, 0, .{ 1, 1, 0, 1 }), v(0, 20, 0, .{ 0, 1, 1, 1 }), v(4, 20, 0, .{ 0, 1, 1, 1 }) };
    c.bindBuffer(g.ARRAY_BUFFER, bufs[1]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(qv)), &qv, g.STATIC_DRAW);
    c.vertexAttribPointer(0, 4, g.FLOAT, false, @sizeOf(Vert), 0, false);
    c.vertexAttribPointer(1, 4, g.FLOAT, false, @sizeOf(Vert), 16, false);
    const offs = [_]f32{ 0, 0, 2.0 * 6.0 / @as(f32, W), 0, 2.0 * 12.0 / @as(f32, W), 0 };
    c.bindBuffer(g.ARRAY_BUFFER, bufs[2]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(offs)), &offs, g.STATIC_DRAW);
    c.vertexAttribPointer(2, 2, g.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(2, true);
    c.vertexAttribDivisor(2, 1);
    const idx = [_]u16{ 0, 1, 3, 0, 3, 2 };
    c.bindBuffer(g.ELEMENT_ARRAY_BUFFER, bufs[3]);
    c.bufferData(g.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, g.STATIC_DRAW);
    c.drawElements(g.TRIANGLES, 6, g.UNSIGNED_SHORT, 0, 3);
    c.enableVertexAttribArray(2, false);
    c.vertexAttribDivisor(2, 0);
    noErr(c, out);

    // 6. scissor and color mask: a white quad over everything, red only,
    // in a corner
    c.usePipeline(&solid, &white_uniforms);
    c.enable(g.SCISSOR_TEST, true);
    c.scissorSet(24, 16, 8, 8);
    c.colorMask(true, false, false, false);
    c.enableVertexAttribArray(1, false);
    drawVerts1(c, bufs[0], &quad(0, 0, 64, 32, 0, .{ 0, 0, 0, 0 }));
    c.colorMask(true, true, true, true);
    c.enable(g.SCISSOR_TEST, false);
    noErr(c, out);

    // 7. flat shading: the provoking (last) vertex's color for the whole triangle
    c.usePipeline(&flat, &.{});
    drawVerts(c, bufs[0], &.{ v(16, 0, 0, red), v(30, 0, 0, red), v(16, 3, 0, blue) }, g.TRIANGLES);
    noErr(c, out);

    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &out.fbo);
    noErr(c, out);

    // 8. the window (top-down BGRA): a fan
    var win = eng.newImage(WW, WH, .bgra8) orelse return error.OutOfMemory;
    win.top_down = true;
    defer eng.freeImage(&win);
    c.setSurface(&win, &win, null);
    c.bindFramebuffer(g.FRAMEBUFFER, 0);
    c.viewportSet(0, 0, WW, WH);
    c.clearColor(0.25, 0.25, 0.25, 1);
    c.clear(g.COLOR_BUFFER_BIT);
    c.usePipeline(&colored, &.{});
    const fan = [_]Vert{
        winv(16, 8, .{ 1, 1, 1, 1 }), winv(4, 2, red),  winv(28, 2, blue),
        winv(28, 14, .{ 0, 1, 0, 1 }), winv(4, 14, red),
    };
    drawVerts(c, bufs[0], &fan, g.TRIANGLE_FAN);
    c.readPixels(0, 0, WW, WH, g.RGBA, g.UNSIGNED_BYTE, &out.win);
    noErr(c, out);
    c.finish();
}

fn winv(x: f32, y: f32, col: [4]f32) Vert {
    return .{ .x = nx(x, WW), .y = nx(y, WH), .z = 0, .w = 1, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
}

const white_uniforms = [_]u32{ @bitCast(@as(f32, 1)), @bitCast(@as(f32, 1)), @bitCast(@as(f32, 1)), @bitCast(@as(f32, 1)) };

/// Positions only (attribute 0).
fn drawVerts1(c: *gles.Context, buf: u32, verts: []const Vert) void {
    c.bindBuffer(g.ARRAY_BUFFER, buf);
    c.bufferData(g.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(Vert)), verts.ptr, g.STREAM_DRAW);
    c.vertexAttribPointer(0, 4, g.FLOAT, false, @sizeOf(Vert), 0, false);
    c.enableVertexAttribArray(0, true);
    c.drawArrays(g.TRIANGLES, 0, @intCast(verts.len), 1);
}

fn px(o: []const u8, w: usize, x: usize, y: usize) [4]u8 {
    return o[(y * w + x) * 4 ..][0..4].*;
}

fn check(o: *const Out) !void {
    try std.testing.expectEqual(@as(u32, 0), o.errors);
    // 1. every pixel of the square exactly once (64, 128, 32, 128; twice
    // would be 128, 255, 64, 255), the diagonal's too; next to it, nothing
    for (0..16) |y| {
        for (0..16) |x| try std.testing.expectEqual([4]u8{ 64, 128, 32, 128 }, px(&o.fbo, W, x, y));
    }
    for ([_][2]usize{ .{ 16, 8 }, .{ 5, 16 } }) |p| {
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(&o.fbo, W, p[0], p[1]));
    }
    // 2. the strip: red at the left, blue at the right, between in between
    const l = px(&o.fbo, W, 32, 8);
    const m = px(&o.fbo, W, 48, 8);
    const rt = px(&o.fbo, W, 63, 8);
    try std.testing.expect(l[0] > 240 and l[2] < 16);
    try std.testing.expect(rt[2] > 240 and rt[0] < 16);
    try std.testing.expect(m[0] > 100 and m[0] < 156 and m[2] > 100 and m[2] < 156);
    try std.testing.expectEqual(@as(u8, 255), m[3]);
    // 3. depth: green where both are, red where only the far one is
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px(&o.fbo, W, 48, 24));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(&o.fbo, W, 37, 24));
    // 4. culling: the clockwise (red) triangle not drawn, the other (blue) drawn
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(&o.fbo, W, 1, 25));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(&o.fbo, W, 9, 25));
    // 5. three instances of the 4 x 4 quad: yellow below, cyan above
    for ([_]usize{ 0, 6, 12 }) |x0| {
        try std.testing.expect(px(&o.fbo, W, x0 + 1, 16)[0] > 200 and px(&o.fbo, W, x0 + 1, 16)[1] > 200);
        try std.testing.expect(px(&o.fbo, W, x0 + 2, 19)[1] > 200 and px(&o.fbo, W, x0 + 2, 19)[2] > 100);
    }
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(&o.fbo, W, 4, 17));
    // 6. the scissored square: red written, the other channels kept;
    // beside it nothing
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 0 }, px(&o.fbo, W, 28, 20));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(&o.fbo, W, 33, 20));
    // 7. flat: blue (the last vertex) all over its triangle
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(&o.fbo, W, 17, 0));
    // 8. the fan: the backdrop at the corner, colors inside
    try std.testing.expectEqual([4]u8{ 64, 64, 64, 255 }, px(&o.win, WW, 0, 0));
    try std.testing.expect(px(&o.win, WW, 16, 8)[0] > 150);
}

// ── The three runs ─────────────────────────────────────────────────────────

var pool_mem: [8 << 20]u8 align(64) = undefined;
var cpu_work: [4 << 20]u8 align(64) = undefined;
var eng_cpu: engine.Engine = undefined;
var out_cpu: Out = .{};
var cpu_done = false;

fn cpuOut() !*const Out {
    if (!cpu_done) {
        eng_cpu.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
        try scene(&eng_cpu, &out_cpu);
        if (eng_cpu.why_pipe) |e| std.debug.print("cpu draw: {s} at pc {d}\n", .{ @errorName(e), eng_cpu.trap.pc });
        cpu_done = true;
    }
    return &out_cpu;
}

test "draw: the scene on the CPU (the interpreter on the images' memory)" {
    const o = try cpuOut();
    try check(o);
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [8 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "draw: the scene on EmuDevice gives the CPU's bytes" {
    const want = try cpuOut();
    var caps = gpu.interp_caps;
    caps.coherent = false;
    emu = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem, .cpu_work = &cpu_work });
    try std.testing.expect(eng_emu.onGpu());
    try scene(&eng_emu, &out_emu);
    if (eng_emu.why_pipe) |e| std.debug.print("emu pipeline: {s}\n", .{@errorName(e)});
    try std.testing.expect(eng_emu.why_pipe == null);
    try std.testing.expect(!eng_emu.lost);
    try check(&out_emu);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_emu.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_emu.win);
    // (three dispatches a draw, on the GPU)
    try std.testing.expect(eng_emu.stats.dispatches >= 3 * 9);
    eng_emu.deinit();
}

var a_arena: [32 << 20]u8 align(4096) = undefined;
var a_view: [32 << 20]u8 align(4096) = undefined;
var a_emu: adreno.device.EmuDevice = undefined;
var a_fake: node.Fake = undefined;
const AGpu = node.Gpu(*node.Fake, &.{.ir3_a7xx});
var a_gpu: AGpu = undefined;
var ir3_work: [gpu.kir_ir3.WORK_BYTES]u8 align(64) = undefined;
var eng_a: engine.Engine = undefined;
var out_a: Out = .{};

test "draw: the scene on the emulated Adreno (ir3) gives the CPU's bytes" {
    const want = try cpuOut();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    const d = try a_gpu.open();
    eng_a.init(.{ .dev = d, .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try std.testing.expect(eng_a.onGpu());
    try scene(&eng_a, &out_a);
    if (eng_a.why_pipe) |e| std.debug.print("adreno pipeline: {s}\n", .{@errorName(e)});
    if (a_emu.last_error) |e| std.debug.print("ir3_emu: {s}: {s}\n", .{ @errorName(e), a_emu.fault.text() });
    try std.testing.expect(eng_a.why_pipe == null);
    try std.testing.expect(!eng_a.lost);
    try check(&out_a);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_a.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_a.win);
    // (every draw's three kernels ran on the GPU, compiled to ir3)
    try std.testing.expect(eng_a.stats.dispatches >= 3 * 9);
    eng_a.deinit();
    a_gpu.close();
}

// ── Bins: a target of several bins ─────────────────────────────────────────

const BW = 200;
const BH = 136;

const BinOut = struct {
    fbo: [BW * BH * 4]u8 = undefined,
    errors: u32 = 0,
};

fn bv(x: f32, y: f32, col: [4]f32) Vert {
    return .{ .x = nx(x, BW), .y = nx(y, BH), .z = 0, .w = 1, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
}

const N_SMALL = 256;
var bin_verts: [3 * N_SMALL]Vert = undefined;

/// A number in [0, n) from the generator's state.
fn rnd(state: *u32, n: u32) f32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return @floatFromInt((state.* >> 8) % n);
}

fn binScene(eng: *engine.Engine, out: *BinOut) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
    defer eng.unloadPipeline(&colored);
    var tex: [1]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(g.TEXTURE_2D, tex[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, BW, BH);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, BW, BH);
    c.clearColor(0.1, 0.2, 0.3, 1);
    c.clear(g.COLOR_BUFFER_BIT);
    var vao: [1]u32 = undefined;
    c.genVertexArrays(&vao);
    c.bindVertexArray(vao[0]);
    var bufs: [1]u32 = undefined;
    c.genBuffers(&bufs);
    c.usePipeline(&colored, &.{});
    c.enable(g.BLEND, true);
    c.blendFunc(g.SRC_ALPHA, g.ONE_MINUS_SRC_ALPHA, g.ONE, g.ONE_MINUS_SRC_ALPHA);
    // 1. small triangles all over, half transparent, each over the ones
    // before it (their order shows)
    var state: u32 = 12345;
    for (0..N_SMALL) |n| {
        const x = rnd(&state, BW);
        const y = rnd(&state, BH);
        const size = 3 + rnd(&state, 18);
        const col = [4]f32{ rnd(&state, 256) / 255, rnd(&state, 256) / 255, rnd(&state, 256) / 255, 0.5 };
        bin_verts[3 * n] = bv(x, y, col);
        bin_verts[3 * n + 1] = bv(x + size, y + rnd(&state, 7), col);
        bin_verts[3 * n + 2] = bv(x + rnd(&state, 9), y + size, col);
    }
    drawVerts(c, bufs[0], &bin_verts, g.TRIANGLES);
    noErr(c, out);
    // 2. big triangles across bins, under a scissor box off the bins'
    // grid (the bins start at its corner)
    c.enable(g.SCISSOR_TEST, true);
    c.scissorSet(13, 7, 150, 120);
    const a = [4]f32{ 1, 0.5, 0, 0.5 };
    const b = [4]f32{ 0, 0.5, 1, 0.75 };
    drawVerts(c, bufs[0], &.{ bv(-20, -10, a), bv(220, 40, b), bv(90, 150, a), bv(0, 130, b), bv(10, 0, a), bv(200, 70, b) }, g.TRIANGLES);
    c.enable(g.SCISSOR_TEST, false);
    noErr(c, out);
    // 3. a thin strip across the whole width
    drawVerts(c, bufs[0], &.{ bv(0, 60, a), bv(0, 63, b), bv(200, 61, a), bv(200, 64.5, b) }, g.TRIANGLE_STRIP);
    c.readPixels(0, 0, BW, BH, g.RGBA, g.UNSIGNED_BYTE, &out.fbo);
    noErr(c, out);
    c.finish();
}

var bins_pool: [8 << 20]u8 align(64) = undefined;
var eng_bins: engine.Engine = undefined;
/// on the CPU: unbinned, binned, binned with lists of 24 at most
var bins_cpu: [3]BinOut = .{ .{}, .{}, .{} };
var bins_done = false;

fn binsCpu() !*const [3]BinOut {
    if (!bins_done) {
        for (&bins_cpu, 0..) |*o, m| {
            eng_bins.init(.{ .pool = &bins_pool, .cpu_work = &cpu_work });
            eng_bins.binning = m != 0;
            if (m == 2) eng_bins.bin_cap = 24;
            try binScene(&eng_bins, o);
            if (eng_bins.why_pipe) |e| std.debug.print("cpu bins: {s} at pc {d}\n", .{ @errorName(e), eng_bins.trap.pc });
            eng_bins.deinit();
        }
        bins_done = true;
    }
    return &bins_cpu;
}

fn checkBins(o: *const BinOut) !void {
    try std.testing.expectEqual(@as(u32, 0), o.errors);
    // drawn over in places, the clear color left in others
    const clear_px = [4]u8{ 26, 51, 77, 255 };
    var drawn: usize = 0;
    var bare: usize = 0;
    for (0..BH) |y| {
        for (0..BW) |x| {
            if (std.mem.eql(u8, &px(&o.fbo, BW, x, y), &clear_px)) bare += 1 else drawn += 1;
        }
    }
    try std.testing.expect(drawn > BW * BH / 4 and bare > BW * BH / 10);
}

test "draw: bins: binned, unbinned, and lists that run over give the same bytes on the CPU" {
    const o = try binsCpu();
    try std.testing.expectEqualSlices(u8, &o[0].fbo, &o[1].fbo);
    try std.testing.expectEqualSlices(u8, &o[0].fbo, &o[2].fbo);
    try checkBins(&o[0]);
}

test "draw: bins on EmuDevice (lists that run over) give the CPU's bytes" {
    const want = try binsCpu();
    var caps = gpu.interp_caps;
    caps.coherent = false;
    emu = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem, .cpu_work = &cpu_work });
    eng_emu.bin_cap = 24;
    try std.testing.expect(eng_emu.onGpu());
    var out: BinOut = .{};
    try binScene(&eng_emu, &out);
    if (eng_emu.why_pipe) |e| std.debug.print("emu pipeline: {s}\n", .{@errorName(e)});
    try std.testing.expect(eng_emu.why_pipe == null and !eng_emu.lost);
    try std.testing.expectEqualSlices(u8, &want[0].fbo, &out.fbo);
    // (four dispatches a binned draw)
    try std.testing.expect(eng_emu.stats.dispatches >= 4 * 3);
    eng_emu.deinit();
}

test "draw: bins on the emulated Adreno (ir3) give the CPU's bytes" {
    const want = try binsCpu();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    const d = try a_gpu.open();
    eng_a.init(.{ .dev = d, .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try std.testing.expect(eng_a.onGpu());
    var out: BinOut = .{};
    try binScene(&eng_a, &out);
    if (eng_a.why_pipe) |e| std.debug.print("adreno pipeline: {s}\n", .{@errorName(e)});
    if (a_emu.last_error) |e| std.debug.print("ir3_emu: {s}: {s}\n", .{ @errorName(e), a_emu.fault.text() });
    try std.testing.expect(eng_a.why_pipe == null and !eng_a.lost);
    try std.testing.expectEqualSlices(u8, &want[0].fbo, &out.fbo);
    try std.testing.expect(eng_a.stats.dispatches >= 4 * 3);
    eng_a.deinit();
    a_gpu.close();
}
