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
//!
//! On the emulated Adreno and RTX too: a video picture's unorm16 planes
//! (P010's R16 and GR1616, as EGLImages give them) sampled exactly.

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
const program = gfxapi.program;
/// (zpm src/va's: the layout the VA driver's pictures are in)
const tiling = @import("va_tiling");

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
    fn discard(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        fragment(null, k, io);
        io.discard = k.mov(.pred, kir.u(1));
    }
};

var colored = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .vertex = Colored.vertex, .fragment = Colored.fragment });
var flat = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .flat = 0xf, .vertex = Colored.vertex, .fragment = Colored.fragment });
var instanced = raster.Pipeline.init(.{ .attrs = 3, .varyings = 4, .vertex = Colored.instanced, .fragment = Colored.fragment });
var solid = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .vertex = Uniform.vertex, .fragment = Uniform.fragment });
var discarded = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .vertex = Uniform.vertex, .fragment = Uniform.discard });
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
        winv(16, 8, .{ 1, 1, 1, 1 }),  winv(4, 2, red),  winv(28, 2, blue),
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

fn stencilValue(eng: *engine.Engine, rb: u32) u32 {
    // (pixel (2, 2) as d24s8's word, whatever the image's form: rows,
    // block linear, or float depth with its S8 plane)
    const img = &ctx.objs.rbs[rb - 1].img;
    var word: [4]u8 = undefined;
    eng.read(img, 2, 2, 1, 1, &word, 4, .d24s8);
    return std.mem.readInt(u32, &word, .little);
}

fn stencilScene(eng: *engine.Engine, separate: bool) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    defer eng.unloadPipeline(&solid);
    defer eng.unloadPipeline(&discarded);
    var tex: [1]u32 = undefined;
    ctx.genTextures(&tex);
    ctx.bindTexture(g.TEXTURE_2D, tex[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 4, 4);
    var rb: [2]u32 = undefined;
    ctx.genRenderbuffers(&rb);
    ctx.bindRenderbuffer(g.RENDERBUFFER, rb[0]);
    ctx.renderbufferStorage(g.RENDERBUFFER, 0, if (separate) g.DEPTH_COMPONENT24 else g.DEPTH24_STENCIL8, 4, 4);
    const stencil_rb = if (separate) rb[1] else rb[0];
    if (separate) {
        ctx.bindRenderbuffer(g.RENDERBUFFER, stencil_rb);
        ctx.renderbufferStorage(g.RENDERBUFFER, 0, g.STENCIL_INDEX8, 4, 4);
    }
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_ATTACHMENT, g.RENDERBUFFER, rb[0]);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.STENCIL_ATTACHMENT, g.RENDERBUFFER, stencil_rb);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    ctx.viewportSet(0, 0, 4, 4);
    ctx.clearDepth(1);
    ctx.clearStencil(7);
    ctx.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT);
    var buffer: [1]u32 = undefined;
    ctx.genBuffers(&buffer);
    const triangle = [_]f32{ -1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1 };
    ctx.bindBuffer(g.ARRAY_BUFFER, buffer[0]);
    ctx.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(triangle)), &triangle, g.STATIC_DRAW);
    ctx.vertexAttribPointer(0, 4, g.FLOAT, false, 16, 0, false);
    ctx.enableVertexAttribArray(0, true);
    const red = [_]u32{ @bitCast(@as(f32, 1)), 0, 0, @bitCast(@as(f32, 1)) };
    ctx.usePipeline(&solid, &red);
    ctx.enable(g.STENCIL_TEST, true);
    ctx.enable(g.DEPTH_TEST, true);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.ALWAYS, 9, 0xff);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.KEEP, g.KEEP, g.REPLACE);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    try std.testing.expectEqual(@as(u32, 9), stencilValue(eng, stencil_rb) >> 24);
    const depth = stencilValue(eng, rb[0]) & 0xffffff;
    try std.testing.expectEqual(@as(u32, 0x800000), depth);
    ctx.colorMask(false, false, false, false);
    ctx.stencilMaskSeparate(g.FRONT_AND_BACK, 0x0f);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.NEVER, 0xa5, 0xff);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.REPLACE, g.KEEP, g.KEEP);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 5), stencilValue(eng, stencil_rb) >> 24);
    try std.testing.expectEqual(depth, stencilValue(eng, rb[0]) & 0xffffff);
    ctx.stencilMaskSeparate(g.FRONT_AND_BACK, 0xff);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.ALWAYS, 0, 0xff);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.KEEP, g.INCR, g.DECR);
    ctx.depthFunc(g.NEVER);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 6), stencilValue(eng, stencil_rb) >> 24);
    ctx.depthFunc(g.ALWAYS);
    ctx.frontFace(g.CW);
    ctx.stencilFuncSeparate(g.BACK, g.ALWAYS, 0x44, 0xff);
    ctx.stencilMaskSeparate(g.BACK, 0xf0);
    ctx.stencilOpSeparate(g.BACK, g.KEEP, g.KEEP, g.REPLACE);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 0x46), stencilValue(eng, stencil_rb) >> 24);
    ctx.frontFace(g.CCW);
    ctx.usePipeline(&discarded, &red);
    ctx.stencilFuncSeparate(g.FRONT, g.NEVER, 0x77, 0xff);
    ctx.stencilOpSeparate(g.FRONT, g.REPLACE, g.REPLACE, g.REPLACE);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 0x46), stencilValue(eng, stencil_rb) >> 24);
    ctx.usePipeline(&solid, &red);
    ctx.stencilMaskSeparate(g.FRONT_AND_BACK, 0xff);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.ALWAYS, 5, 0xff);
    ctx.clearStencil(254);
    ctx.clear(g.STENCIL_BUFFER_BIT);
    const operations = [_]u32{ g.INCR, g.INCR, g.INCR_WRAP, g.DECR, g.DECR_WRAP, g.INVERT, g.ZERO, g.REPLACE, g.KEEP };
    const results = [_]u32{ 255, 255, 0, 0, 255, 0, 0, 5, 5 };
    for (operations, results) |op, expected| {
        ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.KEEP, g.KEEP, op);
        ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
        try std.testing.expectEqual(expected, stencilValue(eng, stencil_rb) >> 24);
        try std.testing.expectEqual(depth, stencilValue(eng, rb[0]) & 0xffffff);
    }
    const comparisons = [_]u32{ g.NEVER, g.LESS, g.EQUAL, g.LEQUAL, g.GREATER, g.NOTEQUAL, g.GEQUAL, g.ALWAYS };
    for (comparisons) |comparison| {
        for ([_]u8{ 4, 5, 6 }) |reference| {
            ctx.clearStencil(5);
            ctx.clear(g.STENCIL_BUFFER_BIT);
            ctx.stencilFuncSeparate(g.FRONT_AND_BACK, comparison, reference, 0xff);
            ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.INVERT, g.ZERO, g.KEEP);
            ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
            const passes = switch (comparison) {
                g.NEVER => false,
                g.LESS => reference < 5,
                g.EQUAL => reference == 5,
                g.LEQUAL => reference <= 5,
                g.GREATER => reference > 5,
                g.NOTEQUAL => reference != 5,
                g.GEQUAL => reference >= 5,
                g.ALWAYS => true,
                else => unreachable,
            };
            const actual = stencilValue(eng, stencil_rb) >> 24;
            if (actual != @as(u32, if (passes) 5 else 250)) {
                std.debug.print("stencil comparison 0x{x}, reference {d}, separate {}, GPU {}, GL error 0x{x}, pipeline {?s}\n", .{ comparison, reference, separate, eng.onGpu(), ctx.err, if (eng.why_pipe) |err| @errorName(err) else null });
            }
            try std.testing.expectEqual(@as(u32, if (passes) 5 else 250), actual);
        }
    }
    ctx.clearStencil(5);
    ctx.clear(g.STENCIL_BUFFER_BIT);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.LESS, 0x14, 0x0f);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.INVERT, g.INVERT, g.INCR);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 6), stencilValue(eng, stencil_rb) >> 24);
    ctx.stencilMaskSeparate(g.FRONT_AND_BACK, 0);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 6), stencilValue(eng, stencil_rb) >> 24);
    ctx.stencilMaskSeparate(g.FRONT_AND_BACK, 0xff);
    ctx.enable(g.DEPTH_TEST, false);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.ALWAYS, 0, 0xff);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.INVERT, g.INVERT, g.INCR);
    ctx.drawArrays(g.TRIANGLES, 0, 3, 1);
    try std.testing.expectEqual(@as(u32, 7), stencilValue(eng, stencil_rb) >> 24);
    try std.testing.expectEqual(depth, stencilValue(eng, rb[0]) & 0xffffff);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
}

test "draw: stencil operations, discard and packed or separate attachments on the CPU" {
    eng_cpu.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
    try stencilScene(&eng_cpu, false);
    try stencilScene(&eng_cpu, true);
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

fn layeredCopy(eng: *engine.Engine) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    var names: [2]u32 = undefined;
    ctx.genTextures(&names);
    ctx.bindTexture(g.TEXTURE_2D_ARRAY, names[0]);
    ctx.texStorage3D(g.TEXTURE_2D_ARRAY, 1, g.RGBA8, 1, 1, 2);
    ctx.bindTexture(g.TEXTURE_CUBE_MAP, names[1]);
    ctx.texStorage2D(g.TEXTURE_CUBE_MAP, 1, g.RGBA8, 1, 1);
    const pixels = [_]u8{ 11, 22, 33, 44, 55, 66, 77, 88 };
    ctx.texSubImage3D(g.TEXTURE_2D_ARRAY, 0, 0, 0, 0, 1, 1, 2, g.RGBA, g.UNSIGNED_BYTE, &pixels);
    ctx.copyImageSubData(names[0], g.TEXTURE_2D_ARRAY, 0, 0, 0, 0, names[1], g.TEXTURE_CUBE_MAP, 0, 0, 0, 0, 1, 1, 1);
    ctx.copyImageSubData(names[0], g.TEXTURE_2D_ARRAY, 0, 0, 0, 1, names[1], g.TEXTURE_CUBE_MAP, 0, 0, 0, 1, 1, 1, 1);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    try std.testing.expectEqualSlices(u8, &pixels, eng.hostView(&objs.tex[names[1] - 1].img, 0, pixels.len));
    const before_clear = eng.stats.dispatches;
    var framebuffers: [1]u32 = undefined;
    ctx.genFramebuffers(&framebuffers);
    ctx.bindFramebuffer(g.FRAMEBUFFER, framebuffers[0]);
    ctx.framebufferTextureLayer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, names[0], 0, 1);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    ctx.clearColor(1, 0, 0, 1);
    ctx.clear(g.COLOR_BUFFER_BIT);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_CUBE_MAP_POSITIVE_X + 1, names[1], 0);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    ctx.clearColor(0, 1, 0, 1);
    ctx.clear(g.COLOR_BUFFER_BIT);
    var pixel: [4]u8 = undefined;
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pixel);
    try std.testing.expectEqualSlices(u8, &.{ 11, 22, 33, 44, 255, 0, 0, 255 }, eng.hostView(&objs.tex[names[0] - 1].img, 0, pixels.len));
    try std.testing.expectEqualSlices(u8, &.{ 11, 22, 33, 44, 0, 255, 0, 255 }, eng.hostView(&objs.tex[names[1] - 1].img, 0, pixels.len));
    try std.testing.expect(eng.stats.dispatches >= before_clear + 2);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    ctx.texParameteri(g.TEXTURE_2D_ARRAY, g.TEXTURE_MIN_FILTER, g.NEAREST);
    ctx.texParameteri(g.TEXTURE_2D_ARRAY, g.TEXTURE_MAG_FILTER, g.NEAREST);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp sampler2DArray tex; out vec4 color;" ++
        "void main() { ivec3 size = textureSize(tex, 0); " ++
        "color = textureLod(tex, vec3(0.5, 0.5, 0.75), 0.0) + texelFetch(tex, ivec3(0, 0, 0), 0); " ++
        "color.b = float(size.z) * 0.25; }", .{ 255, 22, 128, 255 });
    var volume: [1]u32 = undefined;
    ctx.genTextures(&volume);
    ctx.bindTexture(g.TEXTURE_3D, volume[0]);
    ctx.texStorage3D(g.TEXTURE_3D, 2, g.RGBA8, 1, 1, 2);
    const slices = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    ctx.texSubImage3D(g.TEXTURE_3D, 0, 0, 0, 0, 1, 1, 2, g.RGBA, g.UNSIGNED_BYTE, &slices);
    const mip = [_]u8{ 0, 0, 255, 255 };
    ctx.texSubImage3D(g.TEXTURE_3D, 1, 0, 0, 0, 1, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &mip);
    ctx.texParameteri(g.TEXTURE_3D, g.TEXTURE_MIN_FILTER, g.LINEAR);
    ctx.texParameteri(g.TEXTURE_3D, g.TEXTURE_MAG_FILTER, g.LINEAR);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp sampler3D tex; out vec4 color;" ++
        "void main() { color = textureLod(tex, vec3(0.5), 0.0); " ++
        "color.b = min(texelFetchOffset(tex, ivec3(0), 0, ivec3(0, 0, 1)).g, texelFetch(tex, ivec3(0), 1).b); }", .{ 128, 128, 255, 255 });
    const before_mips = eng.stats.dispatches;
    ctx.generateMipmap(g.TEXTURE_3D);
    ctx.framebufferTextureLayer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, volume[0], 1, 0);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 0, 255 }, &pixel);
    try std.testing.expect(eng.stats.dispatches > before_mips);
    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    ctx.texSubImage2D(g.TEXTURE_CUBE_MAP_POSITIVE_X, 0, 0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &red);
    ctx.texSubImage2D(g.TEXTURE_CUBE_MAP_POSITIVE_X + 4, 0, 0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &blue);
    ctx.framebufferTextureLayer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, names[0], 0, 1);
    ctx.texParameteri(g.TEXTURE_CUBE_MAP, g.TEXTURE_MIN_FILTER, g.LINEAR);
    ctx.texParameteri(g.TEXTURE_CUBE_MAP, g.TEXTURE_MAG_FILTER, g.LINEAR);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp samplerCube tex; out vec4 color;" ++
        "void main() { color = textureLod(tex, vec3(1.0, 0.0, 1.0), 0.0); }", .{ 128, 0, 128, 255 });
    var depth_tex: [1]u32 = undefined;
    ctx.genTextures(&depth_tex);
    ctx.bindTexture(g.TEXTURE_2D, depth_tex[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.DEPTH_COMPONENT24, 2, 1);
    const depths = [_]u32{ 0, 0xffff_ffff };
    ctx.texSubImage2D(g.TEXTURE_2D, 0, 0, 0, 2, 1, g.DEPTH_COMPONENT, g.UNSIGNED_INT, &depths);
    ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.LINEAR);
    ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
    ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_COMPARE_MODE, g.COMPARE_REF_TO_TEXTURE);
    ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_COMPARE_FUNC, g.LEQUAL);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp sampler2DShadow tex; out vec4 color;" ++
        "void main() { color = vec4(texture(tex, vec3(0.5, 0.5, 0.5)), 0.0, 0.0, 1.0); }", .{ 128, 0, 0, 255 });
    var detached: [1]u32 = undefined;
    ctx.genTextures(&detached);
    ctx.bindTexture(g.TEXTURE_2D_ARRAY, detached[0]);
    const independent = [_]u8{ 25, 50, 75, 255, 100, 125, 150, 255 };
    ctx.texImage3D(g.TEXTURE_2D_ARRAY, 2, g.RGBA8, 1, 1, 2, 0, g.RGBA, g.UNSIGNED_BYTE, &independent);
    ctx.texParameteri(g.TEXTURE_2D_ARRAY, g.TEXTURE_BASE_LEVEL, 2);
    ctx.texParameteri(g.TEXTURE_2D_ARRAY, g.TEXTURE_MIN_FILTER, g.NEAREST);
    ctx.texParameteri(g.TEXTURE_2D_ARRAY, g.TEXTURE_MAG_FILTER, g.NEAREST);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp sampler2DArray tex; out vec4 color;" ++
        "void main() { color = texelFetch(tex, ivec3(0, 0, 1), 0); }", .{ 100, 125, 150, 255 });
    ctx.texImage3D(g.TEXTURE_2D_ARRAY, 2, g.RGBA8, 2, 1, 2, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    ctx.texImage3D(g.TEXTURE_2D_ARRAY, 3, g.RGBA8, 1, 1, 2, 0, g.RGBA, g.UNSIGNED_BYTE, &independent);
    ctx.texParameteri(g.TEXTURE_2D_ARRAY, g.TEXTURE_MIN_FILTER, g.NEAREST_MIPMAP_NEAREST);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp sampler2DArray tex; out vec4 color;" ++
        "void main() { color = textureLod(tex, vec3(0.5, 0.5, 1.0), 1.0); }", .{ 100, 125, 150, 255 });
    try std.testing.expect(!eng.lost);
}

fn mutableCubeDraw(eng: *engine.Engine) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    var textures: [2]u32 = undefined;
    ctx.genTextures(&textures);
    ctx.bindTexture(g.TEXTURE_2D, textures[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 1, 1);
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, textures[0], 0);
    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    ctx.bindTexture(g.TEXTURE_CUBE_MAP, textures[1]);
    ctx.texStorage2D(g.TEXTURE_CUBE_MAP, 1, g.RGBA8, 1, 1);
    ctx.texSubImage2D(g.TEXTURE_CUBE_MAP_POSITIVE_X + 4, 0, 0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &blue);
    var mutable_cube: [1]u32 = undefined;
    ctx.genTextures(&mutable_cube);
    ctx.bindTexture(g.TEXTURE_CUBE_MAP, mutable_cube[0]);
    for (0..6) |face| {
        const target = g.TEXTURE_CUBE_MAP_POSITIVE_X + @as(u32, @intCast(face));
        ctx.texImage2D(target, 1, g.RGBA8, 1, 1, 0, g.RGBA, g.UNSIGNED_BYTE, &red);
        ctx.texImage2D(target, 0, g.RGBA8, 2, 2, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    }
    ctx.copyImageSubData(textures[1], g.TEXTURE_CUBE_MAP, 0, 0, 0, 4, mutable_cube[0], g.TEXTURE_CUBE_MAP, 1, 0, 0, 4, 1, 1, 1);
    ctx.texParameteri(g.TEXTURE_CUBE_MAP, g.TEXTURE_MIN_FILTER, g.NEAREST_MIPMAP_NEAREST);
    ctx.texParameteri(g.TEXTURE_CUBE_MAP, g.TEXTURE_MAG_FILTER, g.NEAREST);
    try sampleLayerTexture("#version 300 es\nprecision highp float; uniform highp samplerCube tex; out vec4 color;" ++
        "void main() { color = textureLod(tex, vec3(0.0, 0.0, 1.0), 1.0); }", .{ 0, 0, 255, 255 });
    const red_face = red ** 4;
    const blue_face = blue ** 4;
    for (0..6) |face| {
        const target = g.TEXTURE_CUBE_MAP_POSITIVE_X + @as(u32, @intCast(face));
        ctx.texSubImage2D(target, 0, 0, 0, 2, 2, g.RGBA, g.UNSIGNED_BYTE, if (face == 0) &blue_face else &red_face);
    }
    ctx.generateMipmap(g.TEXTURE_CUBE_MAP);
    var pixel: [4]u8 = undefined;
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_CUBE_MAP_POSITIVE_X, mutable_cube[0], 1);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &blue, &pixel);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_CUBE_MAP_POSITIVE_X + 4, mutable_cube[0], 1);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &red, &pixel);
    var array: [1]u32 = undefined;
    ctx.genTextures(&array);
    ctx.bindTexture(g.TEXTURE_2D_ARRAY, array[0]);
    const array_pixels = blue_face ++ red_face;
    ctx.texImage3D(g.TEXTURE_2D_ARRAY, 0, g.RGBA8, 2, 2, 2, 0, g.RGBA, g.UNSIGNED_BYTE, &array_pixels);
    ctx.generateMipmap(g.TEXTURE_2D_ARRAY);
    ctx.framebufferTextureLayer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, array[0], 1, 0);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &blue, &pixel);
    ctx.framebufferTextureLayer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, array[0], 1, 1);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &red, &pixel);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    try std.testing.expect(!eng.lost);
}

/// A video picture's unorm16 planes (P010's: R16, GR1616) as EGLImages
/// give them (the engine's memory, shared; moved out of a slab first
/// where the engine has slabs), sampled by texelFetch and a bilinear
/// texture(): the unorm8 GL says (v / 65535), the same on every GPU.
const Plane = struct {
    fn resolve(handle: ?*anyopaque) ?*engine.Image {
        return @ptrCast(@alignCast(handle orelse return null));
    }
    fn to8(x: u16) u8 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(x)) * 255.0 / 65535.0));
    }
};

fn planeSample(eng: *engine.Engine) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    const saved = gles.egl_image;
    gles.egl_image = Plane.resolve;
    defer gles.egl_image = saved;
    // R16 4 x 1, GR1616 2 x 1: each sample's unorm8 is neither of its
    // bytes (a plane read a byte a channel, or byte-swapped, differs)
    const y16 = [4]u16{ 0x12f0, 0x40ff, 0x00c8, 0xe000 };
    const uv16 = [4]u16{ 0x40ff, 0x12f0, 0xe000, 0x00c8 };
    var y_bytes: [8]u8 = undefined;
    var uv_bytes: [8]u8 = undefined;
    for (y16, uv16, 0..) |a, b, i| {
        std.mem.writeInt(u16, y_bytes[i * 2 ..][0..2], a, .little);
        std.mem.writeInt(u16, uv_bytes[i * 2 ..][0..2], b, .little);
    }
    var y_sh: engine.Shared = .{};
    var uv_sh: engine.Shared = .{};
    var y = eng.newImage(4, 1, .r16) orelse return error.OutOfMemory;
    var uv = eng.newImage(2, 1, .rg16) orelse return error.OutOfMemory;
    try std.testing.expect(eng.shareOwn(&y, &y_sh));
    try std.testing.expect(eng.shareOwn(&uv, &uv_sh));
    defer eng.freeImage(&y);
    defer eng.freeImage(&uv);
    eng.write(&y, 0, 0, 4, 1, &y_bytes, 8, .r16);
    eng.write(&uv, 0, 0, 2, 1, &uv_bytes, 8, .rg16);

    var names: [3]u32 = undefined;
    ctx.genTextures(&names);
    defer ctx.deleteTextures(&names);
    ctx.bindTexture(g.TEXTURE_2D, names[2]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 1, 1);
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    defer ctx.deleteFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, names[2], 0);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    for ([_]u32{ names[0], names[1] }, [_]*engine.Image{ &y, &uv }) |t, img| {
        ctx.bindTexture(g.TEXTURE_2D, t);
        ctx.eglImageTargetTexture2D(g.TEXTURE_2D, img);
        ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.NEAREST);
        ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.NEAREST);
    }
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    const P = "#version 300 es\nprecision highp float; uniform highp sampler2D tex; out vec4 color; void main() { ";
    // R16: texel 1 (the high half of word 0), texel 2 (the low half of word 1)
    ctx.bindTexture(g.TEXTURE_2D, names[0]);
    try sampleLayerTexture(P ++ "color = texelFetch(tex, ivec2(1, 0), 0); }", .{ Plane.to8(y16[1]), 0, 0, 255 });
    try sampleLayerTexture(P ++ "color = texelFetch(tex, ivec2(2, 0), 0); }", .{ Plane.to8(y16[2]), 0, 0, 255 });
    // bilinear, half way between texels 1 and 2: (16639 + 200) / 2 / 257
    ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
    try sampleLayerTexture(P ++ "color = texture(tex, vec2(0.5, 0.5)); }", .{ 33, 0, 0, 255 });
    // GR1616: texel 1's R (bytes 0..1) and G (bytes 2..3)
    ctx.bindTexture(g.TEXTURE_2D, names[1]);
    try sampleLayerTexture(P ++ "color = texelFetch(tex, ivec2(1, 0), 0); }", .{ Plane.to8(uv16[2]), Plane.to8(uv16[3]), 0, 255 });
    ctx.bindFramebuffer(g.FRAMEBUFFER, 0);
}

/// A video decoder's planes as the VA driver exports them (block linear,
/// NVIDIA's GOBs, each swizzle: GB20x's 8- and 16-bit, Turing's), as
/// EGLImages give them, sampled by texelFetch at every texel: each against
/// va's tiling.sig (the layout's CPU reference) — the texel's bytes where
/// tiling.tile put them.
fn blockPlaneSample(eng: *engine.Engine) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    const saved = gles.egl_image;
    gles.egl_image = Plane.resolve;
    defer gles.egl_image = saved;
    const pw = 37;
    const ph = 21;
    const Case = struct { format: engine.Format, swizzle: tiling.Swizzle };
    const cases = [_]Case{
        .{ .format = .rg16, .swizzle = .turing2d }, // P010's UV
        .{ .format = .r8, .swizzle = .blackwell8 }, // NV12's Y
        .{ .format = .rg8, .swizzle = .blackwell16 }, // NV12's UV
        .{ .format = .r16, .swizzle = .blackwell16 }, // P010's Y
        .{ .format = .r8, .swizzle = .turing2d }, // GALAXY_VA_GOB=turing
        .{ .format = .rg8, .swizzle = .blackwell8 },
    };
    var names: [1]u32 = undefined;
    ctx.genTextures(&names);
    defer ctx.deleteTextures(&names);
    var target: [1]u32 = undefined;
    ctx.genTextures(&target);
    defer ctx.deleteTextures(&target);
    ctx.bindTexture(g.TEXTURE_2D, target[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, pw, ph);
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    defer ctx.deleteFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, target[0], 0);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    const vs = try compileLayerShader(g.VERTEX_SHADER, "#version 300 es\nlayout(location=0) in vec4 pos; void main() { gl_Position=pos; }");
    defer program.deleteShader(&ctx, vs);
    const fs = try compileLayerShader(g.FRAGMENT_SHADER, "#version 300 es\nprecision highp float; uniform highp sampler2D tex; out vec4 color; void main() { color = texelFetch(tex, ivec2(gl_FragCoord.xy), 0); }");
    defer program.deleteShader(&ctx, fs);
    const prog = program.createProgram(&ctx);
    defer program.deleteProgram(&ctx, prog);
    program.attachShader(&ctx, prog, vs);
    program.attachShader(&ctx, prog, fs);
    program.linkProgram(&ctx, prog);
    program.useProgram(&ctx, prog);
    defer program.useProgram(&ctx, 0);
    var vbuf: [1]u32 = undefined;
    ctx.genBuffers(&vbuf);
    for (cases) |cs| {
        const bpp = cs.format.bytes();
        const plane = tiling.Plane.of(pw * bpp, ph);
        // the plane's memory: an image of whole GOB rows, filled with
        // tiling.tile's bytes, then named as the block-linear picture
        var img = eng.newImage(plane.pitch / bpp, plane.rows, cs.format) orelse return error.OutOfMemory;
        var sh: engine.Shared = .{};
        try std.testing.expect(eng.shareOwn(&img, &sh));
        try std.testing.expectEqual(plane.pitch, img.stride);
        var linear: [pw * 4 * ph]u8 = undefined;
        for (&linear, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 11);
        var tiled: [8192]u8 = undefined;
        @memset(&tiled, 0);
        tiling.tile(&tiled, plane, cs.swizzle, &linear, pw * bpp, pw * bpp, ph);
        eng.write(&img, 0, 0, plane.pitch / bpp, plane.rows, tiled[0..plane.bytes()], plane.pitch, cs.format);
        const whole_w = img.width;
        const whole_h = img.height;
        img.width = pw;
        img.height = ph;
        img.layout = .{ .block = true, .swizzle = @enumFromInt(@intFromEnum(cs.swizzle)), .gobs_log2 = tiling.BLOCK_GOBS_LOG2 };
        ctx.bindTexture(g.TEXTURE_2D, names[0]);
        ctx.eglImageTargetTexture2D(g.TEXTURE_2D, &img);
        ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.NEAREST);
        ctx.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.NEAREST);
        try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
        ctx.viewportSet(0, 0, pw, ph);
        const vertices = quad(0, 0, W, H, 0, .{ 0, 0, 0, 0 });
        drawVerts(&ctx, vbuf[0], &vertices, g.TRIANGLES);
        var got: [pw * ph * 4]u8 = undefined;
        ctx.readPixels(0, 0, pw, ph, g.RGBA, g.UNSIGNED_BYTE, &got);
        const err = ctx.getError();
        if (err != g.NO_ERROR) std.debug.print("block-linear {s} {s}: GL {x}, pipeline {?s}, GPU {?s}\n", .{ @tagName(cs.format), @tagName(cs.swizzle), err, if (ctx.eng.why_pipe) |why| @errorName(why) else null, if (ctx.eng.why) |why| @errorName(why) else null });
        try std.testing.expectEqual(g.NO_ERROR, err);
        for (0..ph) |y| {
            for (0..pw) |x| {
                const row = linear[y * pw * bpp ..];
                const want: [4]u8 = switch (cs.format) {
                    .r8 => .{ row[x], 0, 0, 255 },
                    .rg8 => .{ row[x * 2], row[x * 2 + 1], 0, 255 },
                    .r16 => .{ Plane.to8(std.mem.readInt(u16, row[x * 2 ..][0..2], .little)), 0, 0, 255 },
                    else => .{ Plane.to8(std.mem.readInt(u16, row[x * 4 ..][0..2], .little)), Plane.to8(std.mem.readInt(u16, row[x * 4 + 2 ..][0..2], .little)), 0, 255 },
                };
                const have = got[(y * pw + x) * 4 ..][0..4];
                if (!std.mem.eql(u8, &want, have)) {
                    std.debug.print("block-linear {s} {s} texel ({d}, {d}): {any}, not {any}\n", .{ @tagName(cs.format), @tagName(cs.swizzle), x, y, have, want });
                    return error.BlockLinear;
                }
            }
        }
        // (unbound, and the GPU done with it, before the image goes)
        ctx.finish();
        ctx.bindTexture(g.TEXTURE_2D, 0);
        ctx.deleteTextures(&names);
        ctx.genTextures(&names);
        img.width = whole_w;
        img.height = whole_h;
        eng.freeImage(&img);
    }
    ctx.deleteBuffers(&vbuf);
    ctx.bindFramebuffer(g.FRAMEBUFFER, 0);
}

// ── Uniform blocks (std140) ────────────────────────────────────────────────

const block_vs: [:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec4 pos;
    \\layout(std140) uniform Scene { vec4 tint; mat3 m; float scale[2]; } scene;
    \\void main() { gl_Position = pos + vec4(0.0, 0.0, 0.0, scene.scale[0]); }
;

// (the fragment shader names Scene's instance otherwise; Light is
// anonymous, its matrix row-major, its bool any non-zero word)
const block_fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\layout(std140) uniform Scene { vec4 tint; mat3 m; float scale[2]; } s;
    \\layout(std140) uniform Light { layout(row_major) mat2 r; vec3 dir; bool on; };
    \\out vec4 color;
    \\void main() {
    \\    vec3 v = s.m * vec3(1.0, 0.0, 0.0);
    \\    color = vec4(s.tint.x * s.scale[1], v.y, (r * vec2(0.0, 1.0)).x + dir.z, on ? 1.0 : 0.0);
    \\}
;

fn putF(bytes: []u8, at: usize, x: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(x), .little);
}

/// Two uniform blocks: GL's names, std140 offsets and strides as the
/// queries give them, binding points, and a draw reading the members
/// from buffer ranges (one at an offset), each pixel byte one only the
/// right layout gives.
fn uniformBlocks(eng: *engine.Engine) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    const vs = try compileLayerShader(g.VERTEX_SHADER, block_vs);
    defer program.deleteShader(&ctx, vs);
    const fs = try compileLayerShader(g.FRAGMENT_SHADER, block_fs);
    defer program.deleteShader(&ctx, fs);
    const p = program.createProgram(&ctx);
    defer program.deleteProgram(&ctx, p);
    program.attachShader(&ctx, p, vs);
    program.attachShader(&ctx, p, fs);
    program.linkProgram(&ctx, p);
    var ok: i32 = 0;
    program.getProgramiv(&ctx, p, g.LINK_STATUS, &ok);
    if (ok != 1) {
        var log: [512]u8 = undefined;
        var len: i32 = 0;
        program.getProgramInfoLog(&ctx, p, log.len, &len, &log);
        std.debug.print("block program: {s}\n", .{log[0..@intCast(len)]});
        return error.Link;
    }
    // the blocks, their sizes, who reads them
    var n: i32 = 0;
    program.getProgramiv(&ctx, p, g.ACTIVE_UNIFORM_BLOCKS, &n);
    try std.testing.expectEqual(@as(i32, 2), n);
    const scene_ix = program.getUniformBlockIndex(&ctx, p, "Scene");
    const light_ix = program.getUniformBlockIndex(&ctx, p, "Light");
    try std.testing.expect(scene_ix != g.INVALID_INDEX and light_ix != g.INVALID_INDEX and scene_ix != light_ix);
    try std.testing.expectEqual(g.INVALID_INDEX, program.getUniformBlockIndex(&ctx, p, "s"));
    var iv: [8]i32 = undefined;
    program.getActiveUniformBlockiv(&ctx, p, scene_ix, g.UNIFORM_BLOCK_DATA_SIZE, &iv);
    try std.testing.expectEqual(@as(i32, 96), iv[0]); // tint 16, m 48, scale 2 x 16
    program.getActiveUniformBlockiv(&ctx, p, light_ix, g.UNIFORM_BLOCK_DATA_SIZE, &iv);
    try std.testing.expectEqual(@as(i32, 48), iv[0]); // r 32, dir 12, on 4
    program.getActiveUniformBlockiv(&ctx, p, scene_ix, g.UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER, &iv);
    try std.testing.expectEqual(@as(i32, 1), iv[0]);
    program.getActiveUniformBlockiv(&ctx, p, light_ix, g.UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER, &iv);
    try std.testing.expectEqual(@as(i32, 0), iv[0]);
    program.getActiveUniformBlockiv(&ctx, p, scene_ix, g.UNIFORM_BLOCK_ACTIVE_UNIFORMS, &iv);
    try std.testing.expectEqual(@as(i32, 3), iv[0]);
    var name: [32]u8 = undefined;
    var len: i32 = 0;
    program.getActiveUniformBlockName(&ctx, p, light_ix, name.len, &len, &name);
    try std.testing.expectEqualStrings("Light", name[0..@intCast(len)]);
    // the members by GL's names: offsets, strides, layouts; no locations
    const names = [_][*:0]const u8{ "Scene.tint", "Scene.m", "Scene.scale[0]", "r", "dir", "on" };
    var idx: [names.len]u32 = undefined;
    program.getUniformIndices(&ctx, p, names.len, &names, &idx);
    for (idx) |ix| try std.testing.expect(ix != g.INVALID_INDEX);
    var offsets: [names.len]i32 = undefined;
    program.getActiveUniformsiv(&ctx, p, names.len, &idx, g.UNIFORM_OFFSET, &offsets);
    try std.testing.expectEqualSlices(i32, &.{ 0, 16, 64, 0, 32, 44 }, &offsets);
    var strides: [names.len]i32 = undefined;
    program.getActiveUniformsiv(&ctx, p, names.len, &idx, g.UNIFORM_ARRAY_STRIDE, &strides);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 16, 0, 0, 0 }, &strides);
    program.getActiveUniformsiv(&ctx, p, names.len, &idx, g.UNIFORM_MATRIX_STRIDE, &strides);
    try std.testing.expectEqualSlices(i32, &.{ 0, 16, 0, 16, 0, 0 }, &strides);
    var row_major: [names.len]i32 = undefined;
    program.getActiveUniformsiv(&ctx, p, names.len, &idx, g.UNIFORM_IS_ROW_MAJOR, &row_major);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 1, 0, 0 }, &row_major);
    var blocks: [names.len]i32 = undefined;
    program.getActiveUniformsiv(&ctx, p, names.len, &idx, g.UNIFORM_BLOCK_INDEX, &blocks);
    try std.testing.expectEqual(@as(i32, @intCast(scene_ix)), blocks[0]);
    try std.testing.expectEqual(@as(i32, @intCast(light_ix)), blocks[5]);
    try std.testing.expectEqual(@as(i32, -1), program.getUniformLocation(&ctx, p, "Scene.tint"));
    try std.testing.expectEqual(@as(i32, -1), program.getUniformLocation(&ctx, p, "r"));
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());

    // the buffers: Scene at binding 3, 256 bytes into its buffer (a
    // range), Light at binding 1 (the whole buffer)
    var scene_bytes = [_]u8{0} ** (256 + 96);
    putF(&scene_bytes, 256 + 0, 0.1); // tint.x
    putF(&scene_bytes, 256 + 16 + 4, 0.6); // m[0].y
    putF(&scene_bytes, 256 + 16 + 16, 9.0); // m[1].x (a wrong layout's)
    putF(&scene_bytes, 256 + 64, 0.0); // scale[0]
    putF(&scene_bytes, 256 + 80, 2.0); // scale[1]
    var light_bytes = [_]u8{0} ** 48;
    putF(&light_bytes, 0, 0.3); // row 0: (0.3, 0.4)
    putF(&light_bytes, 4, 0.4);
    putF(&light_bytes, 16, 0.8); // row 1: (0.8, 0.9): column-major would read 0.8
    putF(&light_bytes, 20, 0.9);
    putF(&light_bytes, 32 + 8, 0.0); // dir.z
    std.mem.writeInt(u32, light_bytes[44..][0..4], 7, .little); // on (true)
    var bufs: [3]u32 = undefined;
    ctx.genBuffers(&bufs);
    ctx.bindBuffer(g.UNIFORM_BUFFER, bufs[0]);
    ctx.bufferData(g.UNIFORM_BUFFER, scene_bytes.len, &scene_bytes, g.STATIC_DRAW);
    ctx.bindBuffer(g.UNIFORM_BUFFER, bufs[1]);
    ctx.bufferData(g.UNIFORM_BUFFER, light_bytes.len, &light_bytes, g.STATIC_DRAW);
    program.uniformBlockBinding(&ctx, p, scene_ix, 3);
    program.uniformBlockBinding(&ctx, p, light_ix, 1);
    ctx.bindBufferRange(g.UNIFORM_BUFFER, 3, bufs[0], 256, 96, true);
    ctx.bindBufferRange(g.UNIFORM_BUFFER, 1, bufs[1], 0, 0, false);
    try std.testing.expectEqual(@as(?i64, bufs[0]), ctx.getIndexed(g.UNIFORM_BUFFER_BINDING, 3));
    try std.testing.expectEqual(@as(?i64, 256), ctx.getIndexed(g.UNIFORM_BUFFER_START, 3));
    try std.testing.expectEqual(@as(?i64, 96), ctx.getIndexed(g.UNIFORM_BUFFER_SIZE, 3));
    program.getActiveUniformBlockiv(&ctx, p, scene_ix, g.UNIFORM_BLOCK_BINDING, &iv);
    try std.testing.expectEqual(@as(i32, 3), iv[0]);
    // what GL refuses: a range off the alignment, a binding point past the last
    ctx.bindBufferRange(g.UNIFORM_BUFFER, 3, bufs[0], 4, 96, true);
    try std.testing.expectEqual(g.INVALID_VALUE, ctx.getError());
    ctx.bindBufferRange(g.UNIFORM_BUFFER, program.MAX_UNIFORM_BUFFER_BINDINGS, bufs[0], 0, 0, false);
    try std.testing.expectEqual(g.INVALID_VALUE, ctx.getError());
    program.uniformBlockBinding(&ctx, p, scene_ix, program.MAX_UNIFORM_BUFFER_BINDINGS);
    try std.testing.expectEqual(g.INVALID_VALUE, ctx.getError());

    // the draw: r = tint.x * scale[1] = 0.2, g = m[0].y = 0.6, b = the
    // row-major r's (0, 1) product's x = 0.4, a = on
    var tex: [1]u32 = undefined;
    ctx.genTextures(&tex);
    defer ctx.deleteTextures(&tex);
    ctx.bindTexture(g.TEXTURE_2D, tex[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 1, 1);
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    defer ctx.deleteFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    program.useProgram(&ctx, p);
    defer program.useProgram(&ctx, 0);
    ctx.viewportSet(0, 0, 1, 1);
    var vb: [1]u32 = undefined;
    ctx.genBuffers(&vb);
    const vertices = quad(0, 0, W, H, 0, .{ 0, 0, 0, 0 });
    drawVerts(&ctx, vb[0], &vertices, g.TRIANGLES);
    var pixel: [4]u8 = undefined;
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    try std.testing.expectEqualSlices(u8, &.{ 51, 153, 102, 255 }, &pixel);
    // a block's buffer written again: the next draw reads the new bytes
    putF(&light_bytes, 4, 0.0);
    std.mem.writeInt(u32, light_bytes[44..][0..4], 0, .little);
    ctx.bindBuffer(g.UNIFORM_BUFFER, bufs[1]);
    ctx.bufferSubData(g.UNIFORM_BUFFER, 0, light_bytes.len, &light_bytes);
    drawVerts(&ctx, vb[0], &vertices, g.TRIANGLES);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, &.{ 51, 153, 0, 0 }, &pixel);
    // the buffer gone: its binding points let go
    ctx.deleteBuffers(&bufs);
    try std.testing.expectEqual(@as(?i64, 0), ctx.getIndexed(g.UNIFORM_BUFFER_BINDING, 3));
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    ctx.bindFramebuffer(g.FRAMEBUFFER, 0);
}

// ── Transform feedback, occlusion queries, primitive restart ──────────────

const xfb_vs: [:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec4 pos;
    \\out vec4 vColor;
    \\out float vExtra;
    \\flat out int vId;
    \\void main() {
    \\    gl_Position = pos * 2.0;
    \\    vColor = pos + vec4(1.0);
    \\    vExtra = pos.x * 10.0;
    \\    vId = gl_VertexID;
    \\}
;

const xfb_fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec4 vColor;
    \\out vec4 color;
    \\void main() { color = vec4(0.0, 1.0, 0.0, 1.0); }
;

const plain_vs: [:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec4 pos;
    \\void main() { gl_Position = pos; }
;

const plain_fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\out vec4 color;
    \\void main() { color = vec4(1.0, 0.0, 1.0, 1.0); }
;

/// A program of two sources, linked (transform feedback's names before).
fn linkPair(vs_src: [:0]const u8, fs_src: [:0]const u8, xfb: []const [*:0]const u8, mode: u32) !u32 {
    const vs = try compileLayerShader(g.VERTEX_SHADER, vs_src);
    defer program.deleteShader(&ctx, vs);
    const fs = try compileLayerShader(g.FRAGMENT_SHADER, fs_src);
    defer program.deleteShader(&ctx, fs);
    const p = program.createProgram(&ctx);
    program.attachShader(&ctx, p, vs);
    program.attachShader(&ctx, p, fs);
    if (xfb.len > 0) program.transformFeedbackVaryings(&ctx, p, @intCast(xfb.len), xfb.ptr, mode);
    program.linkProgram(&ctx, p);
    var ok: i32 = 0;
    program.getProgramiv(&ctx, p, g.LINK_STATUS, &ok);
    if (ok != 1) {
        var log: [512]u8 = undefined;
        var len: i32 = 0;
        program.getProgramInfoLog(&ctx, p, log.len, &len, &log);
        std.debug.print("program: {s}\n", .{log[0..@intCast(len)]});
        return error.Link;
    }
    return p;
}

fn bufWords(eng: *engine.Engine, name: u32, n: usize) []const u32 {
    const b = &objs.bufs[name - 1];
    return std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(eng.hostView(&b.store, 0, n * 4))));
}

fn fbits(x: f32) u32 {
    return @bitCast(x);
}

/// Transform feedback (interleaved: gl_Position, an output the fragment
/// shader does not read, a flat int; separate buffers at an offset;
/// points captured, not drawn; rasterizer discard; pause; GL's errors),
/// its primitives query, an occlusion query (a quad behind the depth
/// buffer: none passed; in front: some), and primitive restart.
fn feedbackAndQueries(eng: *engine.Engine) !void {
    objs.init();
    ctx.init(eng, &objs);
    defer ctx.deinit();
    var tex: [1]u32 = undefined;
    ctx.genTextures(&tex);
    defer ctx.deleteTextures(&tex);
    ctx.bindTexture(g.TEXTURE_2D, tex[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 4, 4);
    var rb: [1]u32 = undefined;
    ctx.genRenderbuffers(&rb);
    defer ctx.deleteRenderbuffers(&rb);
    ctx.bindRenderbuffer(g.RENDERBUFFER, rb[0]);
    ctx.renderbufferStorage(g.RENDERBUFFER, 0, g.DEPTH_COMPONENT16, 4, 4);
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    defer ctx.deleteFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_ATTACHMENT, g.RENDERBUFFER, rb[0]);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    ctx.viewportSet(0, 0, 4, 4);
    ctx.clearColor(0, 0, 0, 0);
    ctx.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT);
    var vb: [1]u32 = undefined;
    ctx.genBuffers(&vb);

    // ── interleaved: gl_Position (4), vExtra (1), vId (1): 6 words a vertex
    const names = [_][*:0]const u8{ "gl_Position", "vExtra", "vId" };
    const p = try linkPair(xfb_vs, xfb_fs, &names, g.INTERLEAVED_ATTRIBS);
    defer program.deleteProgram(&ctx, p);
    var n: i32 = 0;
    program.getProgramiv(&ctx, p, g.TRANSFORM_FEEDBACK_VARYINGS, &n);
    try std.testing.expectEqual(@as(i32, 3), n);
    var vname: [32]u8 = undefined;
    var len: i32 = 0;
    var vsize: i32 = 0;
    var vkind: u32 = 0;
    program.getTransformFeedbackVarying(&ctx, p, 2, vname.len, &len, &vsize, &vkind, &vname);
    try std.testing.expectEqualStrings("vId", vname[0..@intCast(len)]);
    try std.testing.expectEqual(@as(u32, 0x1404), vkind); // INT
    var out: [2]u32 = undefined;
    ctx.genBuffers(&out);
    ctx.bindBuffer(g.TRANSFORM_FEEDBACK_BUFFER, out[0]);
    ctx.bufferData(g.TRANSFORM_FEEDBACK_BUFFER, 6 * 4 * 6, null, g.STATIC_READ);
    var xfb: [1]u32 = undefined;
    ctx.genTransformFeedbacks(&xfb);
    ctx.bindTransformFeedback(g.TRANSFORM_FEEDBACK, xfb[0]);
    ctx.bindBufferRange(g.TRANSFORM_FEEDBACK_BUFFER, 0, out[0], 0, 0, false);
    var q: [2]u32 = undefined;
    ctx.genTimerQueries(&q);
    program.useProgram(&ctx, p);
    ctx.beginQuery(g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, q[0]);
    ctx.beginTransformFeedback(g.TRIANGLES);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    // (no other program, no strip, while it runs)
    program.useProgram(&ctx, 0);
    try std.testing.expectEqual(g.INVALID_OPERATION, ctx.getError());
    const tri = [_]Vert{ v(0, 0, 0, .{ 0, 0, 0, 0 }), v(W, 0, 0, .{ 0, 0, 0, 0 }), v(0, H, 0, .{ 0, 0, 0, 0 }) };
    drawVerts(&ctx, vb[0], &tri, g.TRIANGLE_STRIP);
    try std.testing.expectEqual(g.INVALID_OPERATION, ctx.getError());
    // one triangle, drawn and captured; a second, rasterizer discard on:
    // captured after it, nothing drawn
    drawVerts(&ctx, vb[0], &tri, g.TRIANGLES);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    var pix: [4]u8 = undefined;
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pix);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &pix);
    ctx.clear(g.COLOR_BUFFER_BIT);
    ctx.enable(g.RASTERIZER_DISCARD, true);
    drawVerts(&ctx, vb[0], &tri, g.TRIANGLES);
    ctx.enable(g.RASTERIZER_DISCARD, false);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pix);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &pix);
    // paused: a draw captures nothing; the buffer has room for 6 vertices
    // and 6 are captured: a seventh is too many
    ctx.pauseTransformFeedback();
    drawVerts(&ctx, vb[0], &tri, g.TRIANGLES);
    ctx.resumeTransformFeedback();
    drawVerts(&ctx, vb[0], &tri, g.TRIANGLES);
    try std.testing.expectEqual(g.INVALID_OPERATION, ctx.getError());
    ctx.endTransformFeedback();
    ctx.endQuery(g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    try std.testing.expectEqual(@as(?u64, 2), ctx.queryResult(q[0], g.QUERY_RESULT));
    const words = bufWords(eng, out[0], 6 * 6);
    for (0..6) |k| {
        const vtx = tri[k % 3];
        const rec = words[k * 6 ..][0..6];
        const want = [6]u32{ fbits(vtx.x * 2), fbits(vtx.y * 2), fbits(vtx.z * 2), fbits(vtx.w * 2), fbits(vtx.x * 10), @intCast(k % 3) };
        if (!std.mem.eql(u32, &want, rec)) {
            std.debug.print("vertex {d}: {any}, not {any}\n", .{ k, rec, want });
            return error.Capture;
        }
    }

    // ── separate: vExtra into buffer 0, gl_Position into buffer 1 (64
    // bytes in); points: captured, not drawn
    const sep = [_][*:0]const u8{ "vExtra", "gl_Position" };
    const p2 = try linkPair(xfb_vs, xfb_fs, &sep, g.SEPARATE_ATTRIBS);
    defer program.deleteProgram(&ctx, p2);
    ctx.bindBuffer(g.TRANSFORM_FEEDBACK_BUFFER, out[1]);
    ctx.bufferData(g.TRANSFORM_FEEDBACK_BUFFER, 64 + 4 * 4 * 2, null, g.STATIC_READ);
    ctx.bindBufferRange(g.TRANSFORM_FEEDBACK_BUFFER, 0, out[0], 0, 8, true);
    ctx.bindBufferRange(g.TRANSFORM_FEEDBACK_BUFFER, 1, out[1], 64, 32, true);
    program.useProgram(&ctx, p2);
    ctx.beginTransformFeedback(g.POINTS);
    const pts = [_]Vert{ v(W / 2, 0, 0.5, .{ 0, 0, 0, 0 }), v(0, H / 2, 0.25, .{ 0, 0, 0, 0 }) };
    drawVerts(&ctx, vb[0], &pts, g.POINTS);
    ctx.endTransformFeedback();
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    const w0 = bufWords(eng, out[0], 2);
    try std.testing.expectEqualSlices(u32, &.{ fbits(pts[0].x * 10), fbits(pts[1].x * 10) }, w0);
    const w1 = bufWords(eng, out[1], 16 + 8);
    try std.testing.expectEqualSlices(u32, &.{ fbits(pts[0].x * 2), fbits(pts[0].y * 2), fbits(pts[0].z * 2), fbits(2), fbits(pts[1].x * 2), fbits(pts[1].y * 2), fbits(pts[1].z * 2), fbits(2) }, w1[16..]);
    ctx.bindTransformFeedback(g.TRANSFORM_FEEDBACK, 0);
    ctx.deleteTransformFeedbacks(&xfb);
    try std.testing.expect(!ctx.isTransformFeedback(xfb[0]));
    ctx.deleteBuffers(&out);

    // ── an occlusion query: the depth buffer at 0.5, a quad behind it
    // (none passes), then one in front (some pass)
    const p3 = try linkPair(plain_vs, plain_fs, &.{}, 0);
    defer program.deleteProgram(&ctx, p3);
    program.useProgram(&ctx, p3);
    ctx.enable(g.DEPTH_TEST, true);
    ctx.depthFunc(g.LESS);
    const mid = quad(0, 0, W, H, 0.0, .{ 0, 0, 0, 0 });
    drawVerts(&ctx, vb[0], &mid, g.TRIANGLES);
    ctx.beginQuery(g.ANY_SAMPLES_PASSED, q[1]);
    try std.testing.expectEqual(@as(?i32, @intCast(q[1])), ctx.queryState(g.ANY_SAMPLES_PASSED, g.CURRENT_QUERY));
    const behind = quad(0, 0, W, H, 0.5, .{ 0, 0, 0, 0 });
    drawVerts(&ctx, vb[0], &behind, g.TRIANGLES);
    ctx.endQuery(g.ANY_SAMPLES_PASSED);
    try std.testing.expectEqual(@as(?u64, 0), ctx.queryResult(q[1], g.QUERY_RESULT));
    try std.testing.expectEqual(@as(?u64, 1), ctx.queryResult(q[1], g.QUERY_RESULT_AVAILABLE));
    ctx.beginQuery(g.ANY_SAMPLES_PASSED_CONSERVATIVE, q[1]);
    try std.testing.expectEqual(g.INVALID_OPERATION, ctx.getError()); // (one name, one target)
    ctx.beginQuery(g.ANY_SAMPLES_PASSED, q[1]);
    const front = quad(0, 0, W / 2, H, -0.5, .{ 0, 0, 0, 0 });
    drawVerts(&ctx, vb[0], &front, g.TRIANGLES);
    ctx.endQuery(g.ANY_SAMPLES_PASSED);
    try std.testing.expectEqual(@as(?u64, 1), ctx.queryResult(q[1], g.QUERY_RESULT));
    ctx.enable(g.DEPTH_TEST, false);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());

    // ── primitive restart (fixed index): a triangle with the restart
    // index is not drawn; a strip goes on after it
    ctx.clear(g.COLOR_BUFFER_BIT);
    ctx.enable(g.PRIMITIVE_RESTART_FIXED_INDEX, true);
    const four = [_]Vert{ v(0, 0, 0, .{ 0, 0, 0, 0 }), v(W, 0, 0, .{ 0, 0, 0, 0 }), v(0, H, 0, .{ 0, 0, 0, 0 }), v(W, H, 0, .{ 0, 0, 0, 0 }) };
    ctx.bindBuffer(g.ARRAY_BUFFER, vb[0]);
    ctx.bufferData(g.ARRAY_BUFFER, @intCast(four.len * @sizeOf(Vert)), &four, g.STATIC_DRAW);
    var ib: [1]u32 = undefined;
    ctx.genBuffers(&ib);
    ctx.bindBuffer(g.ELEMENT_ARRAY_BUFFER, ib[0]);
    const idx = [_]u16{ 0, 1, 0xffff, 3, 2, 1 };
    ctx.bufferData(g.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, g.STATIC_DRAW);
    ctx.drawElements(g.TRIANGLES, 3, g.UNSIGNED_SHORT, 0, 1);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pix);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &pix);
    ctx.drawElements(g.TRIANGLES, 3, g.UNSIGNED_SHORT, 6, 1);
    ctx.readPixels(3, 3, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pix);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255 }, &pix);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    ctx.deleteBuffers(&ib);
    ctx.deleteBuffers(&vb);
    ctx.deleteTimerQueries(&q);
    program.useProgram(&ctx, 0);
    ctx.bindFramebuffer(g.FRAMEBUFFER, 0);
}

fn compileLayerShader(kind: u32, source: [:0]const u8) !u32 {
    const id = program.createShader(&ctx, kind);
    errdefer program.deleteShader(&ctx, id);
    const parts = [_]?[*]const u8{source.ptr};
    program.shaderSource(&ctx, id, 1, &parts, null);
    program.compileShader(&ctx, id);
    var ok: i32 = 0;
    program.getShaderiv(&ctx, id, g.COMPILE_STATUS, &ok);
    try std.testing.expectEqual(@as(i32, 1), ok);
    return id;
}

fn sampleLayerTexture(source: [:0]const u8, expected: [4]u8) !void {
    const vs = try compileLayerShader(g.VERTEX_SHADER, "#version 300 es\nlayout(location=0) in vec4 pos; void main() { gl_Position=pos; }");
    defer program.deleteShader(&ctx, vs);
    const fs = try compileLayerShader(g.FRAGMENT_SHADER, source);
    defer program.deleteShader(&ctx, fs);
    const p = program.createProgram(&ctx);
    defer program.deleteProgram(&ctx, p);
    program.attachShader(&ctx, p, vs);
    program.attachShader(&ctx, p, fs);
    program.linkProgram(&ctx, p);
    var ok: i32 = 0;
    program.getProgramiv(&ctx, p, g.LINK_STATUS, &ok);
    try std.testing.expectEqual(@as(i32, 1), ok);
    program.useProgram(&ctx, p);
    defer program.useProgram(&ctx, 0);
    ctx.viewportSet(0, 0, 1, 1);
    var buf: [1]u32 = undefined;
    ctx.genBuffers(&buf);
    const vertices = quad(0, 0, W, H, 0, .{ 0, 0, 0, 0 });
    drawVerts(&ctx, buf[0], &vertices, g.TRIANGLES);
    var pixel: [4]u8 = undefined;
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    const err = ctx.getError();
    if (err != g.NO_ERROR) std.debug.print("layer sample: GL {x}, pipeline {?s}, GPU {?s}\n", .{ err, if (ctx.eng.why_pipe) |why| @errorName(why) else null, if (ctx.eng.why) |why| @errorName(why) else null });
    try std.testing.expectEqual(g.NO_ERROR, err);
    try std.testing.expectEqualSlices(u8, &expected, &pixel);
}

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
    // The fake render node uses a bump arena. Give the independent
    // texture scene a fresh device after the larger draw scene.
    eng_a.deinit();
    a_gpu.close();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try layeredCopy(&eng_a);
    eng_a.deinit();
    a_gpu.close();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try mutableCubeDraw(&eng_a);
    eng_a.deinit();
    a_gpu.close();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try planeSample(&eng_a);
    eng_a.deinit();
    a_gpu.close();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try uniformBlocks(&eng_a);
    eng_a.deinit();
    a_gpu.close();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try feedbackAndQueries(&eng_a);
    eng_a.deinit();
    a_gpu.close();
}

/// The emulated RTX (kir_sm120's code in sm120_emu, hazard checks on;
/// discrete memory, as the PC's), the PC's GL device.
const Rtx = struct {
    const nvidia = @import("nvidia");
    // (the emulator's memory is bump-allocated: a scene's draws use more
    // than they keep)
    var arena: [128 << 20]u8 align(4096) = undefined;
    var view: [128 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
    var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
};
var eng_rtx: engine.Engine = undefined;
var rtx_slabs: [16]engine.Slab = undefined;
var stencil_adreno_slabs: [16]engine.Slab = undefined;
var out_rtx: Out = .{};

test "draw: Adreno suballocations preserve the scene and accelerate copies within one allocation" {
    const want = try cpuOut();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work, .slabs = &stencil_adreno_slabs });
    defer a_gpu.close();
    defer eng_a.deinit();
    try scene(&eng_a, &out_a);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_a.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_a.win);
    objs.init();
    ctx.init(&eng_a, &objs);
    defer ctx.deinit();
    var names: [2]u32 = undefined;
    ctx.genTextures(&names);
    for (names) |name| {
        ctx.bindTexture(g.TEXTURE_2D, name);
        ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 2, 2);
    }
    const src = &objs.tex[names[0] - 1].img;
    const dst = &objs.tex[names[1] - 1].img;
    try std.testing.expectEqual(src.buf.handle, dst.buf.handle);
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    eng_a.writeBytes(src, 0, &pixels);
    const before = eng_a.stats.cpu_ops;
    ctx.copyImageSubData(names[0], g.TEXTURE_2D, 0, 0, 0, 0, names[1], g.TEXTURE_2D, 0, 0, 0, 0, 2, 2, 1);
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    try std.testing.expectEqual(before, eng_a.stats.cpu_ops);
    try std.testing.expectEqualSlices(u8, &pixels, eng_a.hostView(dst, 0, pixels.len));
    try std.testing.expect(eng_a.why_pipe == null and !eng_a.lost);
}

test "draw: stencil operations on emulated Adreno and RTX with separate and packed attachments" {
    for ([_]bool{ false, true }) |separate| {
        a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
        a_fake = .{ .emu = &a_emu };
        a_gpu = .{ .node = .{ .sys = &a_fake } };
        eng_a.init(.{ .dev = try a_gpu.open(), .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work, .slabs = &stencil_adreno_slabs });
        defer a_gpu.close();
        defer eng_a.deinit();
        try stencilScene(&eng_a, separate);
        try std.testing.expect(eng_a.why_pipe == null);
        try std.testing.expect(!eng_a.lost);
        try std.testing.expect(eng_a.stats.dispatches >= 3 * 13);
    }
    for ([_]bool{ false, true }) |separate| {
        Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
        eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs });
        defer eng_rtx.deinit();
        try stencilScene(&eng_rtx, separate);
        try std.testing.expect(eng_rtx.why_pipe == null);
        try std.testing.expect(!eng_rtx.lost);
        try std.testing.expect(eng_rtx.stats.dispatches >= 3 * 13);
    }
}

test "draw: stencil operations with the emulated RTX's 3D engine on: the framebuffer's texture made block linear, its float depth-stencil (packed or separate renderbuffers) drawn by the 3D engine, the CPU's bytes" {
    for ([_]bool{ false, true }) |separate| {
        Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
        Rtx.dev.withEngine(&Rtx3d.engine3d);
        eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
        defer eng_rtx.deinit();
        stencilScene(&eng_rtx, separate) catch |e| {
            std.debug.print("stencil scene (separate {}): {s}; the 3D engine: {s}\n", .{ separate, @errorName(e), Rtx3d.engine3d.why });
            return e;
        };
        try std.testing.expect(eng_rtx.why_pipe == null);
        try std.testing.expect(!eng_rtx.lost);
        std.debug.print("stencil scene (separate {}): {d} draws through the 3D engine, {d} on the compute kernels\n", .{ separate, eng_rtx.stats.graphics_draws, eng_rtx.stats.compute_draws });
        for (eng_rtx.said_compute) |w| if (w.len != 0) std.debug.print("stencil scene: on the compute kernels: {s}\n", .{w});
        // (the texture made block linear at the first depth draw, so the
        // engine takes every draw (RT_LINEAR_WITH_ZETA beside rows lost the
        // Legion's channel: Xid 69, pc-all); the renderbuffers float depth
        // with their S8 planes)
        try std.testing.expectEqual(@as(u32, 1), eng_rtx.stats.promoted);
        try std.testing.expect(eng_rtx.stats.graphics_draws > 0);
        try std.testing.expectEqual(@as(u64, 0), eng_rtx.stats.compute_draws);
    }
}

test "draw: the scene on the emulated RTX (sm_120, discrete memory) gives the CPU's bytes" {
    const want = try cpuOut();
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs });
    try std.testing.expect(eng_rtx.onGpu());
    // Firefox exhausted the 256-entry render node with small allocations.
    var small: [400]engine.Image = undefined;
    for (&small, 0..) |*img, i| {
        img.* = eng_rtx.newBuffer(80) orelse return error.OutOfMemory;
        try std.testing.expectEqual(small[0].buf.handle, img.buf.handle);
        try std.testing.expectEqual(small[0].buf.gpu + i * 128, img.buf.gpu);
    }
    var exported = eng_rtx.newWindowImage(32, 16, .bgra8) orelse return error.OutOfMemory;
    try std.testing.expect(exported.buf.handle != small[0].buf.handle);
    eng_rtx.freeImage(&exported);
    const first_va = small[0].buf.gpu;
    for (&small) |*img| eng_rtx.freeImage(img);
    var reused = eng_rtx.newBuffer(80) orelse return error.OutOfMemory;
    try std.testing.expectEqual(first_va, reused.buf.gpu);
    eng_rtx.freeImage(&reused);
    scene(&eng_rtx, &out_rtx) catch |e| {
        std.debug.print("rtx scene: {s}; the emulator's memory used {d} KiB of {d}, regions {d}; the engine lost the GPU {} ({?s}), its pipeline error {?s}\n", .{ @errorName(e), Rtx.dev.raw.used >> 10, Rtx.arena.len >> 10, Rtx.dev.raw.n_regions, eng_rtx.lost, if (eng_rtx.why) |w| @errorName(w) else null, if (eng_rtx.why_pipe) |w| @errorName(w) else null });
        if (Rtx.dev.lastError()) |le| {
            var buf: [512]u8 = undefined;
            std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(le), Rtx.dev.explain(&buf) });
        }
        return e;
    };
    if (eng_rtx.why_pipe) |e| std.debug.print("rtx pipeline: {s}\n", .{@errorName(e)});
    if (Rtx.dev.lastError()) |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(e), Rtx.dev.explain(&buf) });
    }
    try std.testing.expect(eng_rtx.why_pipe == null);
    try std.testing.expect(!eng_rtx.lost);
    try check(&out_rtx);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_rtx.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_rtx.win);
    // (every draw's three kernels ran on the RTX, compiled to sm_120)
    try std.testing.expect(eng_rtx.stats.dispatches >= 3 * 9);
    try layeredCopy(&eng_rtx);
    try mutableCubeDraw(&eng_rtx);
    try planeSample(&eng_rtx);
    try blockPlaneSample(&eng_rtx);
    try uniformBlocks(&eng_rtx);
    try feedbackAndQueries(&eng_rtx);
    eng_rtx.deinit();
}

// ── The emulated RTX's 3D engine (Config.graphics) ─────────────────────────

/// Pixels of two outputs more than `tol` apart in a channel: how many, the
/// first, the largest difference.
fn apart(want: []const u8, got: []const u8, width: usize, tol: u8, what: []const u8) u32 {
    var n: u32 = 0;
    var most: u8 = 0;
    var i: usize = 0;
    while (i < want.len) : (i += 4) {
        var worst: u8 = 0;
        for (0..4) |c| worst = @max(worst, if (want[i + c] > got[i + c]) want[i + c] - got[i + c] else got[i + c] - want[i + c]);
        most = @max(most, worst);
        if (worst <= tol) continue;
        if (n < 4) std.debug.print("{s}: pixel ({d}, {d}): the CPU {any}, the 3D engine {any}\n", .{ what, (i / 4) % width, (i / 4) / width, want[i..][0..4], got[i..][0..4] });
        n += 1;
    }
    std.debug.print("{s}: {d} pixels more than {d} apart (the most {d})\n", .{ what, n, tol, most });
    return n;
}

const Rtx3d = struct {
    var engine3d: @import("nvidia").emu3d.Engine = .{};
};
var out_rtx3d: Out = .{};

test "draw: the scene through the emulated RTX's 3D engine where it draws, the compute kernels the rest: the CPU's picture" {
    const want = try cpuOut();
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
    try std.testing.expect(eng_rtx.onGpu() and eng_rtx.graphics);
    scene(&eng_rtx, &out_rtx3d) catch |e| {
        std.debug.print("rtx 3D scene: {s}; the engine lost the GPU {} ({?s}), its pipeline error {?s}; the 3D engine: {s}\n", .{ @errorName(e), eng_rtx.lost, if (eng_rtx.why) |w| @errorName(w) else null, if (eng_rtx.why_pipe) |w| @errorName(w) else null, Rtx3d.engine3d.why });
        return e;
    };
    if (Rtx.dev.lastError()) |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("sm120_emu: {s}: {s}; the 3D engine: {s}\n", .{ @errorName(e), Rtx.dev.explain(&buf), Rtx3d.engine3d.why });
    }
    std.debug.print("3D engine: draws {d} through it, {d} on the compute kernels; the emulated engine drew {d}, {d} pixels\n", .{ eng_rtx.stats.graphics_draws, eng_rtx.stats.compute_draws, Rtx3d.engine3d.draws, Rtx3d.engine3d.pixels });
    for (eng_rtx.said_compute) |w| if (w.len != 0) std.debug.print("3D engine: a draw on the compute kernels: {s}\n", .{w});
    if (eng_rtx.why_pipe) |w| std.debug.print("3D engine: a pipeline refused: {s}\n", .{@errorName(w)});
    try std.testing.expect(eng_rtx.why_pipe == null);
    try std.testing.expect(!eng_rtx.lost);
    try std.testing.expect(eng_rtx.stats.graphics_draws > 0);
    try std.testing.expectEqual(eng_rtx.stats.graphics_draws, Rtx3d.engine3d.draws);
    // (the hardware's blending and interpolation are not KIR's exact
    // arithmetic: within a step or two of 255)
    try std.testing.expectEqual(@as(u32, 0), apart(&want.fbo, &out_rtx3d.fbo, W, 2, "fbo"));
    try std.testing.expectEqual(@as(u32, 0), apart(&want.win, &out_rtx3d.win, WW, 2, "window"));
    eng_rtx.deinit();
}

/// Two triangles sharing an edge (their corners' depths apart: a sloped
/// plane each), added (ONE, ONE) into a cleared target twice: first each
/// on the 3D engine or on the compute kernels as `on3d` says, the depth
/// tested LESS and written; then each on the other rasterizer, the depth
/// tested EQUAL. A pixel of the pair is hit by both passes (128) when
/// the two rasterizers cover it alike and give it the same depth bits;
/// once (64), or twice in a pass, is a crack, a double hit or z-fighting.
/// (GL's colour images are rows, and the 3D engine takes a depth target
/// only beside block-linear colour (RT_LINEAR_WITH_ZETA: the Legion lost
/// its channel to it, Xid 69), so the engine keeps every one of these
/// draws on the compute kernels however `on3d` asks: none may reach the
/// 3D engine. nvidia_draw's steps 4c and 4d hold the 3D engine's depth to
/// the compute path's, with block-linear colour.)
fn sharedEdge(e: *engine.Engine, img: *engine.Image, depth: *engine.Image, ab: *engine.Image, pts: [4][2]f32, on3d: [2]bool, out: []u8) !void {
    e.fill(img, img.bounds(), 0, 0);
    e.fill(depth, depth.bounds(), 0x00ff_ffff, 0xff00_0000);
    var verts: [6][4]f32 = undefined;
    const tris = [2][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    const zs = [4]f32{ -0.3, 0.2117, 0.7, 0.0931 };
    for (tris, 0..) |t, n| {
        for (t, 0..) |c, j| verts[n * 3 + j] = .{ nx(pts[c][0], W), nx(pts[c][1], H), zs[c], 1 };
    }
    e.writeBytes(ab, 0, std.mem.sliceAsBytes(&verts));
    const quarter = [_]u32{ @bitCast(@as(f32, 0.25)), 0, 0, 0 };
    const add = raster.Blend{ .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } }, .gl = .{ g.ONE, g.ONE, g.ONE, g.ONE } };
    for (0..2) |pass| {
        for (0..2) |n| {
            const hw = on3d[n] == (pass == 0);
            e.compute_only = !hw;
            const before = e.stats.graphics_draws;
            var d = raster.Draw{ .pipe = &solid, .color = img, .depth = depth, .depth_test = true, .depth_write = pass == 0, .depth_func = if (pass == 0) 0b001 else 0b010, .rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H }, .count = 3, .first = @intCast(n * 3), .center = .{ W / 2, H / 2 }, .half = .{ W / 2, H / 2 }, .uniforms = &quarter, .blend = add };
            d.attrs[0] = .{ .buf = ab, .stride = 16, .comps = 4 };
            if (!e.draw(&d)) return error.NotDrawn;
            e.finish();
            if (e.lost or e.why_pipe != null) return error.EngineLost;
            if (e.stats.graphics_draws != before) {
                for (e.said_compute) |w| if (w.len != 0) std.debug.print("shared edge: on the compute kernels: {s}\n", .{w});
                return error.WrongRasterizer;
            }
        }
    }
    e.compute_only = false;
    e.read(img, 0, 0, W, H, out, W * 4, .rgba8);
}

/// A pixel's red as hits: 0, 1 (64), 2 (128), else 3.
fn hits(red: u8) u8 {
    if (red == 0) return 0;
    if (red >= 62 and red <= 66) return 1;
    if (red >= 126 and red <= 130) return 2;
    return 3;
}

test "draw: two triangles sharing an edge with depth, the RTX's 3D engine on: every draw kept on the compute kernels (RT_LINEAR_WITH_ZETA), no gap, no pixel twice, the same depth" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
    defer eng_rtx.deinit();
    defer eng_rtx.unloadPipeline(&solid);
    const e = &eng_rtx;
    var img = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    var depth = e.newImageSamples(W, H, .d24s8, 1) orelse return error.OutOfMemory;
    defer e.freeImage(&depth);
    try std.testing.expect(depth.layout.block);
    var ab = e.newBuffer(6 * 16) orelse return error.OutOfMemory;
    defer e.freeImage(&ab);
    // (a 45-degree edge through pixel centers: the tie rule decides each;
    // corners off any grid coarser than 1/256: the snapping decides)
    const shapes = [_][4][2]f32{
        .{ .{ 8, 4 }, .{ 32, 4 }, .{ 32, 28 }, .{ 8, 28 } },
        .{ .{ 5.37, 3.11 }, .{ 58.93, 6.71 }, .{ 52.18, 29.42 }, .{ 9.66, 26.05 } },
        .{ .{ 40.5, 2.25 }, .{ 61.0078125, 30.0039 }, .{ 12.25, 30.5 }, .{ 3.1, 1.9 } },
    };
    const combos = [_][2]bool{ .{ true, true }, .{ false, false }, .{ true, false }, .{ false, true } };
    var pics: [combos.len][W * H * 4]u8 = undefined;
    for ([_]bool{ false, true }) |top_down| {
        img.top_down = top_down;
        depth.top_down = top_down;
        for (shapes, 0..) |s, si| {
            for (combos, 0..) |c, ci| sharedEdge(e, &img, &depth, &ab, s, c, &pics[ci]) catch |err| {
                std.debug.print("shared edge: shape {d} ({any}, top down {}): {s}; the 3D engine: {s}\n", .{ si, c, top_down, @errorName(err), Rtx3d.engine3d.why });
                return err;
            };
            var count: [4]u32 = @splat(0);
            for (0..W * H) |p| count[hits(pics[0][p * 4])] += 1;
            var differ: [combos.len]u32 = @splat(0);
            for (1..combos.len) |ci| {
                for (0..W * H) |p| differ[ci] += @intFromBool(hits(pics[0][p * 4]) != hits(pics[ci][p * 4]));
            }
            std.debug.print("shared edge: shape {d} (top down {}): {d} pixels hit by both passes, {d} by one, {d} otherwise; pixels apart from both-first-on-3D: both first on compute {d}, split {d} and {d}\n", .{ si, top_down, count[2], count[1], count[3], differ[1], differ[2], differ[3] });
            try std.testing.expectEqual(@as(u32, 0), count[1]);
            try std.testing.expectEqual(@as(u32, 0), count[3]);
            try std.testing.expect(count[2] > 0);
            if (si == 0) try std.testing.expectEqual(@as(u32, 24 * 24), count[2]);
            for (1..combos.len) |ci| try std.testing.expectEqual(@as(u32, 0), differ[ci]);
        }
    }
}

const HwTest = struct {
    var over: gpu.nvidia_draw.Over = undefined;
    var kst: gpu.nvidia_device.kir_sm120.State = .{};
    var mem: [64 * 1024]u8 = undefined;
    var model: gpu.draw.Reference = .{ .mem = &mem };
    var ticks: u64 = 0;
    fn clock() u64 {
        ticks += 7;
        return ticks;
    }
    fn say(line: []const u8) void {
        if (std.mem.indexOf(u8, line, "edges") != null or std.mem.indexOf(u8, line, "step 5") != null or std.mem.indexOf(u8, line, "FAILED") != null) std.debug.print("[nv] {s}\n", .{line});
    }
};

test "draw: the drawtest boot's hardware test on the emulated RTX, step 4 (edges) too: the 3D engine's edges and depth are the compute path's, exactly" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    const gd = Rtx.dev.device();
    const res = gpu.nvidia_draw.hardwareTest(Rtx.dev.raw.device(), gd, &HwTest.over, &HwTest.kst, &HwTest.model, &HwTest.say, &HwTest.clock);
    try std.testing.expect(res.started and res.object and res.state and !res.lost);
    try std.testing.expectEqual(@as(u32, 0), res.failed);
    try std.testing.expect(!res.edge_skipped);
    try std.testing.expectEqual(gpu.nvidia_draw.EDGE_RUNS, res.edge_scenes);
    // (step 4g, the Z24 probe: every pixel drawn and every id where
    // Blackwell's Z24 GOBs put it: the emulated engine keeps 24-bit depths
    // in that layout (emu3d.z24Bytes, pc-full4's probe), not Turing2D's, so
    // a step that read or wrote a 24-bit plane as Turing2D's fails here as
    // pc-full3 did on the RTX; 4f compares through it)
    try std.testing.expectEqual(@as(u32, gpu.nvidia_draw.EW * gpu.nvidia_draw.EH), res.z24_drawn);
    try std.testing.expectEqual(@as(u32, gpu.nvidia_draw.EW * gpu.nvidia_draw.EH), res.z24_placed);
    try std.testing.expectEqual(@as(u32, gpu.nvidia_draw.EW * gpu.nvidia_draw.EH / 16), res.z24_split_placed);
    try std.testing.expectEqual(@as(u32, 0), res.edge_depth_within);
    try std.testing.expectEqual(@as(u32, 0), res.edge_cover_apart);
    try std.testing.expectEqual(@as(u32, 0), res.edge_depth_apart);
    try std.testing.expectEqual(@as(u32, 0), res.edge_equal_apart);
    // (step 5: every feature scene drawn, each the model's)
    try std.testing.expect(!res.feature_skipped);
    try std.testing.expectEqual(@as(u32, gpu.nvidia_draw.FEATURE_SCENES), res.feature_scenes);
    try std.testing.expectEqual(@as(u32, 0), res.feature_apart);
}

// ── The drawtest's steps 4 and 5: a lost group, the pc-all stream ─────────

/// A raw device over the emulated RTX that loses the channel (its wait
/// says DeviceLost) at the first push selecting a depth target, once, as
/// the Legion's RTX did at pc-all's first triangle; adapters over it.
const Lossy = struct {
    const nv = @import("nvidia");
    const nd = gpu.nvidia_draw;
    var inner: nv.device.Device = undefined;
    var armed = false;
    var lose_next = false;
    var lost: u32 = 0;
    var tag: u8 = 0;
    var adapters: [2]gpu.nvidia_device.Adapter = .{ .{}, .{} };
    var next: usize = 0;
    const vt = nv.device.Device.VTable{ .alloc = alloc, .free = free, .submit = submit, .wait = wait, .toDevice = toDev, .fromDevice = fromDev };

    fn device() nv.device.Device {
        return .{ .ctx = @ptrCast(&tag), .vtable = &vt };
    }
    fn alloc(_: *anyopaque, size: usize) ?nv.device.Buffer {
        return inner.vtable.alloc(inner.ctx, size);
    }
    fn free(_: *anyopaque, b: nv.device.Buffer) void {
        inner.vtable.free(inner.ctx, b);
    }
    fn submit(_: *anyopaque, pb: nv.device.Buffer, dwords: u32) nv.device.Error!nv.device.Fence {
        const zt = nv.push.headerImmd(nv.draw.SUBCH, nv.draw.SET_ZT_SELECT, 1);
        if (armed and std.mem.indexOfScalar(u32, pb.words()[0..dwords], zt) != null) {
            armed = false;
            lose_next = true;
        }
        return inner.vtable.submit(inner.ctx, pb, dwords);
    }
    fn wait(_: *anyopaque, f: nv.device.Fence, t: u64) nv.device.Error!void {
        if (lose_next) {
            lose_next = false;
            lost += 1;
            return error.DeviceLost;
        }
        return inner.vtable.wait(inner.ctx, f, t);
    }
    fn toDev(_: *anyopaque, b: nv.device.Buffer, o: usize, l: usize) void {
        inner.vtable.toDevice(inner.ctx, b, o, l);
    }
    fn fromDev(_: *anyopaque, b: nv.device.Buffer, o: usize, l: usize) void {
        inner.vtable.fromDevice(inner.ctx, b, o, l);
    }
    /// The emulated RTX with its 3D engine, afresh, under it.
    fn fresh() void {
        Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
        Rtx3d.engine3d = .{};
        Rtx.dev.withEngine(&Rtx3d.engine3d);
        inner = Rtx.dev.raw.device();
        next = 0;
        armed = false;
    }
    /// gpu/nvidia_device's adapter over it (a fresh one each time; the one
    /// before released: its channel lost).
    fn adapter() gpu.Device {
        if (next != 0) adapters[(next - 1) % adapters.len].release();
        const a = &adapters[next % adapters.len];
        next += 1;
        a.* = .{};
        return gpu.nvidia_device.over(a, device(), null, gpu.nvidia_device.withGraphics(gpu.nvidia_device.rtx5070(0)));
    }
    fn last() *gpu.nvidia_device.Adapter {
        return &adapters[(next - 1) % adapters.len];
    }
    fn reopen() ?gpu.Device {
        return adapter();
    }
    var said_lost: bool = false;
    var said_fresh: bool = false;
    fn say(line: []const u8) void {
        if (std.mem.indexOf(u8, line, "step 4c") != null and std.mem.indexOf(u8, line, "FAILED") != null) said_lost = true;
        if (std.mem.indexOf(u8, line, "runs on a fresh one") != null) said_fresh = true;
        if (std.mem.indexOf(u8, line, "APART") != null or std.mem.indexOf(u8, line, "lost") != null) std.debug.print("[nv] {s}\n", .{line});
    }
    fn silent(_: []const u8) void {}
};

test "draw: the drawtest's lost group is named, and with a fresh channel the groups after it run (step 4c lost as pc-all's first triangle was)" {
    const nd = gpu.nvidia_draw;
    Lossy.fresh();
    Lossy.armed = true;
    Lossy.lost = 0;
    Lossy.said_lost = false;
    Lossy.said_fresh = false;
    const res = nd.hardwareTestWith(Lossy.device(), Lossy.adapter(), &HwTest.over, &HwTest.kst, &HwTest.model, &Lossy.say, &HwTest.clock, .{ .reopen = &Lossy.reopen });
    try std.testing.expectEqual(@as(u32, 1), Lossy.lost);
    try std.testing.expect(Lossy.said_lost and Lossy.said_fresh);
    try std.testing.expect(!res.lost);
    try std.testing.expectEqual(@as(u32, 1), res.groups_lost);
    try std.testing.expectEqualStrings("4c", res.lost_group);
    // (4a and 4b ran before it; 4d and step 5 after it, on the fresh one)
    try std.testing.expect(res.edge_scenes > 0 and res.edge_scenes < nd.EDGE_RUNS);
    try std.testing.expectEqual(@as(u32, 0), res.edge_cover_apart + res.edge_depth_apart + res.edge_equal_apart);
    try std.testing.expectEqual(@as(u32, nd.FEATURE_SCENES), res.feature_scenes);
    try std.testing.expectEqual(@as(u32, 0), res.feature_apart);
    // (without reopen the test ends at the lost group)
    Lossy.fresh();
    Lossy.armed = true;
    const end = nd.hardwareTest(Lossy.device(), Lossy.adapter(), &HwTest.over, &HwTest.kst, &HwTest.model, &Lossy.silent, &HwTest.clock);
    try std.testing.expect(end.lost);
    try std.testing.expectEqualStrings("4c", end.lost_group);
    try std.testing.expectEqual(@as(u32, 0), end.feature_scenes);
}

const PcAll = struct {
    var insts: [256]kir.Inst = undefined;
    var tys: [512]kir.Ty = undefined;
    var vcode: [16 * 1024]u8 align(16) = undefined;
    var pcode: [16 * 1024]u8 align(16) = undefined;
};

test "draw: the pc-all and pc-full2 streams (depth beside a pitch colour target; a combined depth-stencil format) are refused by the adapter before they are sent, and by the emulated engine; block linear with X8Z24 is drawn" {
    const nv = @import("nvidia");
    const nd = gpu.nvidia_draw;
    const gl = gpu.nvidia_gl;
    Lossy.fresh();
    const d = Lossy.adapter();
    const st = &HwTest.kst;
    var vk = kir.Kernel.init(.{ .insts = &PcAll.insts, .tys = &PcAll.tys }, "edges_vs", .{ 1, 1, 1 });
    nd.edgeVertex(&vk);
    try vk.finish();
    st.asm_work.sched = .{};
    const vbin = try gl.compileStage(&vk, d.caps, st, .vertex, 0, &PcAll.vcode);
    var pk = kir.Kernel.init(.{ .insts = &PcAll.insts, .tys = &PcAll.tys }, "edges_ps", .{ 1, 1, 1 });
    nd.edgePixel(&pk);
    try pk.finish();
    st.asm_work.sched = .{};
    const pbin = try gl.compileStage(&pk, d.caps, st, .pixel, 0, &PcAll.pcode);
    const vp = try d.load(&vbin);
    defer d.unload(&vp);
    const pp = try d.load(&pbin);
    defer d.unload(&pp);
    const vb = try d.alloc(6 * 16, .host);
    defer d.free(vb);
    const target = try d.alloc(nd.E_DEPTH_BYTES, .host);
    defer d.free(target);
    const depth = try d.alloc(nd.E_DEPTH_BYTES, .host);
    defer d.free(depth);
    var gr = gpu.Graphics{
        .vertex = &vp,
        .va = target.gpu,
        .width = nd.EW,
        .height = nd.EH,
        .stride = nd.E_PITCH,
        .format = .rgba8,
        .scale = .{ nd.EW / 2, nd.EH / 2, 0.5 },
        .offset = .{ nd.EW / 2, nd.EH / 2, 0.5 },
        .scissor = .{ 0, 0, nd.EW, nd.EH },
        .count = 6,
        .depth = .{ .va = depth.gpu, .width = nd.EW, .height = nd.EH, .gobs_log2 = nd.E_GOBS, .tested = true, .write = true },
    };
    const runs = Lossy.last().runs;
    try std.testing.expectError(error.Unsupported, d.run(&.{.{ .prog = &pp, .groups = .{ 1, 1, 1 }, .buffers = &.{ vb, vb }, .params = &.{}, .graphics = &gr }}));
    try std.testing.expectEqual(runs, Lossy.last().runs);
    try std.testing.expect(std.mem.indexOf(u8, Lossy.last().refused.?, "RT_LINEAR_WITH_ZETA") != null);
    // (block linear: drawn)
    gr.gobs_log2 = nd.E_GOBS;
    const f = try d.run(&.{.{ .prog = &pp, .groups = .{ 1, 1, 1 }, .buffers = &.{ vb, vb }, .params = &.{}, .graphics = &gr }});
    try d.wait(f, nd.STEP_US);
    // (the same stream sent raw, past the adapter: the emulated engine
    // refuses it, as the hardware did)
    var buf: [nv.gl3d.MAX_DWORDS]u32 = undefined;
    var p = nv.push.Push{ .buf = &buf };
    nv.gl3d.emit(&p, &.{
        .vertex = .{ .va = vp.code.gpu, .registers = 16, .bytes = vbin.code.len },
        .pixel = .{ .va = pp.code.gpu, .registers = 16, .bytes = pbin.code.len },
        .cb_va = target.gpu,
        .cb_bytes = 0x400,
        .zero_va = target.gpu,
        .target = .{ .va = target.gpu, .width = nd.EW, .height = nd.EH, .pitch = nd.E_PITCH },
        .format = .rgba8,
        .scale = .{ nd.EW / 2, nd.EH / 2, 0.5 },
        .offset = .{ nd.EW / 2, nd.EH / 2, 0.5 },
        .scissor = .{ 0, 0, nd.EW, nd.EH },
        .count = 6,
        .depth = .{ .va = depth.gpu, .width = nd.EW, .height = nd.EH, .gobs_log2 = nd.E_GOBS, .tested = true, .write = true },
    });
    try p.check();
    const raw = Lossy.inner;
    const pb = try raw.alloc(nv.gl3d.MAX_DWORDS * 4);
    defer raw.free(pb);
    @memcpy(pb.words()[0..p.len], p.words());
    try std.testing.expect(std.meta.isError(raw.run(pb, @intCast(p.len), nd.STEP_US)));
    try std.testing.expect(std.mem.startsWith(u8, Rtx3d.engine3d.why, "RT_LINEAR_WITH_ZETA"));
    // (pc-full2's stream: block-linear colour, but the combined Z24S8 depth
    // format pc-all and pc-full2 sent: refused as the RTX refused it, class
    // error 0x13 at the draw; X8Z24 in its place is drawn)
    // (a whole-target quad in clip space, the bindings' constant buffer
    // as the adapter lays it out: so the programs run and pixels reach the
    // depth target)
    const whole = [6][4]f32{ .{ -1, -1, 0, 1 }, .{ 1, -1, 0, 1 }, .{ 1, 1, 0, 1 }, .{ -1, -1, 0, 1 }, .{ 1, 1, 0, 1 }, .{ -1, 1, 0, 1 } };
    @memcpy(vb.cpu[0 .. 6 * 16], std.mem.sliceAsBytes(&whole));
    d.toDevice(vb, 0, 6 * 16);
    const cbb = try raw.alloc(nv.qmd.CBUF0_MAX_BYTES);
    defer raw.free(cbb);
    var params: [16]u8 = undefined;
    std.mem.writeInt(u64, params[0..8], vb.gpu, .little);
    std.mem.writeInt(u64, params[8..16], vb.gpu, .little);
    _ = try nv.qmd.cbuf0Into(@alignCast(std.mem.bytesAsSlice(u32, cbb.cpu[0..nv.qmd.CBUF0_MAX_BYTES])), .{ 1, 1, 1 }, .{ 1, 1, 1 }, &params);
    raw.toDevice(cbb, 0, nv.qmd.CBUF0_MAX_BYTES);
    var dr = nv.gl3d.Draw{
        .vertex = .{ .va = vp.code.gpu, .registers = 16, .bytes = vbin.code.len },
        .pixel = .{ .va = pp.code.gpu, .registers = 16, .bytes = pbin.code.len },
        .cb_va = cbb.va,
        .cb_bytes = nv.qmd.cbuf0Bytes(16),
        .zero_va = target.gpu,
        .target = .{ .va = target.gpu, .width = nd.EW, .height = nd.EH, .pitch = nd.E_PITCH },
        .format = .rgba8,
        .color_gobs = nd.E_GOBS,
        .scale = .{ nd.EW / 2, nd.EH / 2, 0.5 },
        .offset = .{ nd.EW / 2, nd.EH / 2, 0.5 },
        .scissor = .{ 0, 0, nd.EW, nd.EH },
        .count = 6,
        .depth = .{ .va = depth.gpu, .width = nd.EW, .height = nd.EH, .gobs_log2 = nd.E_GOBS, .tested = true, .write = true },
    };
    for ([_]u32{ nv.gl3d.ZT_Z24S8, nv.gl3d.ZT_S8Z24, nv.gl3d.ZT_X8Z24 }) |fmt| {
        p = nv.push.Push{ .buf = &buf };
        nv.gl3d.emit(&p, &dr);
        try p.check();
        const zt = std.mem.indexOfScalar(u32, p.words(), nv.push.header(nv.draw.SUBCH, nv.gl3d.SET_ZT_A, 5)).?;
        try std.testing.expectEqual(nv.gl3d.ZT_X8Z24, p.buf[zt + 3]);
        p.buf[zt + 3] = fmt;
        @memcpy(pb.words()[0..p.len], p.words());
        const ran = raw.run(pb, @intCast(p.len), nd.STEP_US);
        if (fmt == nv.gl3d.ZT_X8Z24) {
            ran catch |e| {
                std.debug.print("X8Z24 raw: {s}: {s}\n", .{ @errorName(e), Rtx3d.engine3d.why });
                return e;
            };
        } else {
            if (std.mem.indexOf(u8, Rtx3d.engine3d.why, "stencil shares its words") == null) std.debug.print("format {x}: the engine: {s}\n", .{ fmt, Rtx3d.engine3d.why });
            try std.testing.expect(std.meta.isError(ran));
            try std.testing.expect(std.mem.indexOf(u8, Rtx3d.engine3d.why, "stencil shares its words") != null);
        }
    }
}

// ── What the 3D engine draws beyond the scene, each against the CPU ───────

const Feat = struct {
    /// gl_FragDepth: x / 64 + y / 128 at the pixel's centre (exact in
    /// f32: no rounding for an FFMA to differ in), the colour the
    /// uniforms'.
    fn fragDepth(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        Uniform.fragment(null, k, io);
        const x = k.op2(.fmul, .f32, r(io.frag_coord[0]), kir.f(1.0 / 64.0));
        const y = k.op2(.fmul, .f32, r(io.frag_coord[1]), kir.f(1.0 / 128.0));
        io.depth = k.op2(.fadd, .f32, r(x), r(y));
    }

    /// Several colour targets: output 0 the uniforms', output 1 across x,
    /// output 3 up y (output 2 not written: draw buffer 2 is NONE).
    fn mrt(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        Uniform.fragment(null, k, io);
        const x = k.op2(.fmul, .f32, r(io.frag_coord[0]), kir.f(1.0 / 64.0));
        const y = k.op2(.fmul, .f32, r(io.frag_coord[1]), kir.f(1.0 / 32.0));
        io.colors[1] = .{ x, k.mov(.f32, kir.f(0.25)), k.mov(.f32, kir.f(0)), k.mov(.f32, kir.f(1)) };
        io.colors[3] = .{ k.mov(.f32, kir.f(0.5)), y, .none, .none };
    }

    /// gl_FrontFacing: red for a front face, green for a back one.
    fn facing(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        io.color = .{ k.sel(.f32, r(io.front_facing), kir.f(1), kir.f(0)), k.sel(.f32, r(io.front_facing), kir.f(0), kir.f(1)), k.mov(.f32, kir.f(0)), k.mov(.f32, kir.f(1)) };
    }
};

var frag_depth_pipe = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .frag_depth = true, .vertex = Uniform.vertex, .fragment = Feat.fragDepth });
var facing_pipe = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .front_facing = true, .vertex = Uniform.vertex, .fragment = Feat.facing });
var mrt_pipe = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .vertex = Uniform.vertex, .fragment = Feat.mrt });
/// (solid's own copy: a pipeline keeps the programs it was loaded with on
/// the engine that drew it last, and the tests before re-make that engine)
var feat_solid = raster.Pipeline.init(.{ .attrs = 1, .varyings = 0, .vertex = Uniform.vertex, .fragment = Uniform.fragment });
const feat_pipes = [_]*raster.Pipeline{ &frag_depth_pipe, &feat_solid, &facing_pipe, &mrt_pipe };

/// The features, a scene each.
const Feature = enum { frag_depth, front_facing, two_sided_stencil, mrt, restart };
const all_features = [_]Feature{ .frag_depth, .front_facing, .two_sided_stencil, .mrt, .restart };
/// A feature scene's pictures: target 0 (RGBA8), then for `mrt` targets
/// 1 (BGRA8) and 3 (RG8) as their bytes.
const FEAT_PIC = W * H * 4;

fn rgba(c: [4]f32) [4]u32 {
    return .{ @bitCast(c[0]), @bitCast(c[1]), @bitCast(c[2]), @bitCast(c[3]) };
}

/// A triangle list's vertices (x, y in pixels; z clip) into `ab`, drawn
/// with `d0`'s state; finished before the next.
fn featDraw(e: *engine.Engine, d0: raster.Draw, ab: *engine.Image, pts: []const [3]f32) !void {
    var verts: [12][4]f32 = undefined;
    for (pts, 0..) |p, n| verts[n] = .{ nx(p[0], W), nx(p[1], H), p[2], 1 };
    e.writeBytes(ab, 0, std.mem.sliceAsBytes(verts[0..pts.len]));
    var d = d0;
    d.rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H };
    d.count = @intCast(pts.len);
    d.center = .{ W / 2, H / 2 };
    d.half = .{ W / 2, H / 2 };
    d.attrs[0] = .{ .buf = ab, .stride = 16, .comps = 4 };
    if (!e.draw(&d)) return error.NotDrawn;
    e.finish();
    if (e.lost or e.why_pipe != null) return error.EngineLost;
}

/// The whole target as two triangles at clip depth z.
fn fullQuad(z: f32) [6][3]f32 {
    return .{ .{ 0, 0, z }, .{ W, 0, z }, .{ W, H, z }, .{ 0, 0, z }, .{ W, H, z }, .{ 0, H, z } };
}

/// A feature's scene into `img` (with `depth`, packed depth-stencil),
/// read into `out`; the draws the 3D engine took.
fn featureScene(e: *engine.Engine, f: Feature, img: *engine.Image, depth: *engine.Image, ab: *engine.Image, out: []u8) !u64 {
    e.fill(img, img.bounds(), 0, 0);
    e.fill(depth, depth.bounds(), 0x00ff_ffff, 0xff00_0000);
    @memset(out, 0);
    const before = e.stats.graphics_draws;
    const red = rgba(.{ 1, 0, 0, 1 });
    const green = rgba(.{ 0, 1, 0, 1 });
    switch (f) {
        // gl_FragDepth written LESS over 1; then a plane at window depth
        // 0.6, LESS: green where the written depth is above it (a slanted
        // line across the target: each pixel's word decides)
        .frag_depth => {
            const q = fullQuad(0.9);
            try featDraw(e, .{ .pipe = &frag_depth_pipe, .color = img, .depth = depth, .depth_test = true, .depth_write = true, .uniforms = &red }, ab, &q);
            const p = fullQuad(0.2);
            try featDraw(e, .{ .pipe = &feat_solid, .color = img, .depth = depth, .depth_test = true, .depth_write = true, .uniforms = &green }, ab, &p);
            // (and EQUAL against the words gl_FragDepth wrote: the same
            // pixels again, blue added where the depth is the program's)
            const blue_add = raster.Blend{ .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } }, .gl = .{ g.ONE, g.ONE, g.ONE, g.ONE } };
            const blue = rgba(.{ 0, 0, 1, 0 });
            try featDraw(e, .{ .pipe = &frag_depth_pipe, .color = img, .depth = depth, .depth_test = true, .depth_func = 0b010, .uniforms = &blue, .blend = blue_add }, ab, &q);
        },
        // gl_FrontFacing: a counter-clockwise triangle and a clockwise one
        // sharing an off-grid edge; then front faces clockwise
        .front_facing => {
            const pts = [_][3]f32{ .{ 2.3, 1.7, 0 }, .{ 30.61, 3.2, 0 }, .{ 9.9, 30.4, 0 }, .{ 30.61, 3.2, 0 }, .{ 9.9, 30.4, 0 }, .{ 61.2, 29.05, 0 } };
            try featDraw(e, .{ .pipe = &facing_pipe, .color = img }, ab, &pts);
            const lower = [_][3]f32{ .{ 33, 1, 0 }, .{ 62, 1, 0 }, .{ 62, 12, 0 }, .{ 33, 1, 0 }, .{ 33, 12, 0 }, .{ 62, 12, 0 } };
            try featDraw(e, .{ .pipe = &facing_pipe, .color = img, .front_ccw = false }, ab, &lower);
        },
        // two-sided stencil: the whole target (front: INCR_WRAP), a
        // clockwise triangle over it (back: EQUAL 1 under 0x0f, INVERT
        // written under 0xf0) in the same draw; then each stencil value
        // made a colour (EQUAL against 1, 0xf1 and 0xf0... drawn in turn)
        .two_sided_stencil => {
            const add = raster.Blend{ .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } }, .gl = .{ g.ONE, g.ONE, g.ONE, g.ONE } };
            const quarter = rgba(.{ 0.25, 0, 0, 0 });
            const front = raster.Stencil{ .func = 7, .pass = .incr_wrap };
            const back = raster.Stencil{ .func = 2, .reference = 1, .value_mask = 0x0f, .write_mask = 0xf0, .pass = .invert };
            var pts: [9][3]f32 = undefined;
            const q = fullQuad(0);
            @memcpy(pts[0..6], &q);
            pts[6] = .{ 6.4, 4.1, 0 };
            pts[7] = .{ 27.3, 29.6, 0 };
            pts[8] = .{ 57.75, 2.5, 0 };
            try featDraw(e, .{ .pipe = &feat_solid, .color = img, .depth = depth, .stencil = depth, .stencil_front = front, .stencil_back = back, .uniforms = &quarter, .blend = add }, ab, &pts);
            const looks = [_]struct { u8, [4]f32 }{ .{ 0x01, .{ 0, 0.5, 0, 0 } }, .{ 0xf1, .{ 0, 0, 0.5, 0 } } };
            for (looks) |lk| {
                const col = rgba(lk[1]);
                const eq = raster.Stencil{ .func = 2, .reference = lk[0] };
                try featDraw(e, .{ .pipe = &feat_solid, .color = img, .depth = depth, .stencil = depth, .stencil_front = eq, .stencil_back = eq, .uniforms = &col, .blend = add }, ab, &q);
            }
        },
        // several colour targets: 0 (RGBA8, replaced), 1 (BGRA8, added
        // over a grey), 2 none, 3 (RG8, green kept, not blended); a
        // triangle over part of them, then the whole target
        .mrt => {
            var t1 = e.newImage(W, H, .bgra8) orelse return error.OutOfMemory;
            defer e.freeImage(&t1);
            var t3 = e.newImage(W, H, .rg8) orelse return error.OutOfMemory;
            defer e.freeImage(&t3);
            t1.top_down = img.top_down;
            t3.top_down = img.top_down;
            e.fill(&t1, t1.bounds(), 0x4040_4040, 0);
            e.fill(&t3, t3.bounds(), 0x0000_8020, 0);
            const add = raster.Blend{ .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } }, .gl = .{ g.ONE, g.ONE, g.ONE, g.ONE } };
            const col = rgba(.{ 0.25, 0.5, 0.75, 1 });
            var d = raster.Draw{ .pipe = &mrt_pipe, .color = img, .uniforms = &col, .blend = add };
            d.targets[1] = .{ .img = &t1 };
            d.targets[3] = .{ .img = &t3, .keep = 0x0000_ff00, .blend = false };
            const tri = [_][3]f32{ .{ 3.5, 2.25, 0 }, .{ 50.2, 9.9, 0 }, .{ 20.75, 30.1, 0 } };
            try featDraw(e, d, ab, &tri);
            const q = fullQuad(0);
            try featDraw(e, d, ab, &q);
            e.read(&t1, 0, 0, W, H, out[FEAT_PIC..][0..FEAT_PIC], W * 4, .bgra8);
            e.read(&t3, 0, 0, W, H, out[2 * FEAT_PIC ..][0 .. W * H * 2], W * 2, .rg8);
        },
        // indexed (the engine's index buffer) with primitive restart: two
        // strips in one draw (the second begun at an odd place: its
        // winding starts anew), two fans in another; red front, green back
        .restart => {
            const pts = [_][2]f32{
                .{ 2, 2 },   .{ 4, 14 },  .{ 12, 3 },  .{ 14, 15 },
                .{ 20, 2 },  .{ 22, 14 }, .{ 30, 3 },  .{ 31, 16 },
                .{ 38, 4 },  .{ 50, 8 },  .{ 60, 2 },  .{ 62, 10 },
                .{ 56, 16 }, .{ 46, 20 }, .{ 58, 22 }, .{ 52, 30 },
                .{ 40, 30 },
            };
            var verts: [pts.len][4]f32 = undefined;
            for (pts, 0..) |p, n| verts[n] = .{ nx(p[0], W), nx(p[1], H), 0, 1 };
            e.writeBytes(ab, 0, std.mem.sliceAsBytes(&verts));
            const R = 0xffff;
            const idx = [_]u16{ 7, 0, 1, 2, 3, R, 4, 5, 6, 7, 8, 9, 10, 11, 12, R, 13, 14, 15, 16 };
            var ib = e.newBuffer(@sizeOf(@TypeOf(idx))) orelse return error.OutOfMemory;
            defer e.freeImage(&ib);
            e.writeBytes(&ib, 0, std.mem.sliceAsBytes(&idx));
            for ([_]struct { raster.Topology, u32, u32 }{ .{ .strip, 2, 10 }, .{ .fan, 22, 9 } }) |dr| {
                var d = raster.Draw{ .pipe = &facing_pipe, .color = img, .index = &ib, .index_size = 2, .index_offset = dr[1], .topology = dr[0], .restart = true, .count = dr[2] };
                d.rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H };
                d.center = .{ W / 2, H / 2 };
                d.half = .{ W / 2, H / 2 };
                d.attrs[0] = .{ .buf = ab, .stride = 16, .comps = 4 };
                if (!e.draw(&d)) return error.NotDrawn;
                e.finish();
                if (e.lost or e.why_pipe != null) return error.EngineLost;
            }
        },
    }
    e.read(img, 0, 0, W, H, out[0..FEAT_PIC], W * 4, .rgba8);
    return e.stats.graphics_draws - before;
}

var fpool_mem: [8 << 20]u8 align(64) = undefined;
var eng_fcpu: engine.Engine = undefined;

test "draw: features through the emulated RTX's 3D engine (gl_FragDepth, gl_FrontFacing, two-sided stencil, several colour targets, indexed with primitive restart): every draw without depth on the engine, the depth ones on the compute kernels (RT_LINEAR_WITH_ZETA), the CPU's bytes" {
    Rtx3d.engine3d = .{};
    eng_fcpu.init(.{ .pool = &fpool_mem, .cpu_work = &cpu_work });
    defer eng_fcpu.deinit();
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
    defer eng_rtx.deinit();
    defer for (feat_pipes) |p| {
        eng_rtx.unloadPipeline(p);
        eng_fcpu.unloadPipeline(p);
    };
    var imgs: [2][3]engine.Image = undefined;
    for ([_]*engine.Engine{ &eng_fcpu, &eng_rtx }, 0..) |e, n| {
        imgs[n][0] = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
        imgs[n][1] = e.newImageSamples(W, H, .d24s8, 1) orelse return error.OutOfMemory;
        imgs[n][2] = e.newBuffer(20 * 16) orelse return error.OutOfMemory;
    }
    try std.testing.expect(imgs[1][1].layout.block);
    var pics: [2][3 * FEAT_PIC]u8 = undefined;
    for (all_features) |f| {
        for ([_]bool{ false, true }) |top_down| {
            var on3d: [2]u64 = undefined;
            for ([_]*engine.Engine{ &eng_fcpu, &eng_rtx }, 0..) |e, n| {
                imgs[n][0].top_down = top_down;
                imgs[n][1].top_down = top_down;
                on3d[n] = featureScene(e, f, &imgs[n][0], &imgs[n][1], &imgs[n][2], &pics[n]) catch |err| {
                    std.debug.print("feature {s} (top down {}): {s}; the 3D engine: {s}\n", .{ @tagName(f), top_down, @errorName(err), Rtx3d.engine3d.why });
                    return err;
                };
            }
            for (eng_rtx.said_compute) |w| if (w.len != 0) std.debug.print("feature {s}: a draw on the compute kernels: {s}\n", .{ @tagName(f), w });
            var drawn: u32 = 0;
            for (0..W * H) |p| drawn += @intFromBool(!std.mem.allEqual(u8, pics[0][p * 4 ..][0..4], 0));
            std.debug.print("feature {s} (top down {}): {d} draws on the 3D engine, {d} pixels drawn\n", .{ @tagName(f), top_down, on3d[1], drawn });
            // (a scene with a depth-stencil image stays on the compute
            // kernels: RT_LINEAR_WITH_ZETA beside GL's colour rows)
            const with_depth = f == .frag_depth or f == .two_sided_stencil;
            try std.testing.expect(drawn > 0);
            if (with_depth) try std.testing.expectEqual(@as(u64, 0), on3d[1]) else try std.testing.expect(on3d[1] > 0);
            // (blending in floats: within 1 of 255)
            try std.testing.expectEqual(@as(u32, 0), apart(&pics[0], &pics[1], W, if (f == .mrt) 1 else 0, @tagName(f)));
        }
        // (every draw the engine took reached the emulated engine; the
        // compute kernels drew only the depth scenes)
        try std.testing.expectEqual(eng_rtx.stats.graphics_draws, Rtx3d.engine3d.draws);
    }
}

test "draw: block-linear colour targets: the compute raster and the RTX's 3D engine draw into one as into rows, fills and reads see the same pixels" {
    Rtx3d.engine3d = .{};
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
    defer eng_rtx.deinit();
    defer eng_rtx.unloadPipeline(&feat_solid);
    const e = &eng_rtx;
    var rows = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&rows);
    var block = e.newBlockImage(W, H, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&block);
    try std.testing.expect(block.layout.block and !rows.layout.block);
    var ab = e.newBuffer(16 * 16) orelse return error.OutOfMemory;
    defer e.freeImage(&ab);
    const add = raster.Blend{ .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } }, .gl = .{ g.ONE, g.ONE, g.ONE, g.ONE } };
    const col = rgba(.{ 0.25, 0.5, 0.125, 0.25 });
    const pts = [_][3]f32{ .{ 2.3, 1.7, 0 }, .{ 40.61, 3.2, 0 }, .{ 9.9, 30.4, 0 }, .{ 40.61, 3.2, 0 }, .{ 9.9, 30.4, 0 }, .{ 61.2, 29.05, 0 } };
    var pics: [2][2][W * H * 4]u8 = undefined;
    for ([_]bool{ true, false }, 0..) |compute, ci| {
        for ([_]*engine.Image{ &rows, &block }, 0..) |img, n| {
            for ([_]bool{ false, true }) |top_down| {
                img.top_down = top_down;
                e.compute_only = compute;
                e.fill(img, img.bounds(), 0x2010_3040, 0);
                // (a fill of part of it too: the fill kernel's layout)
                e.fill(img, .{ .x0 = 5, .y0 = 3, .x1 = 37, .y1 = 19 }, 0x0405_0607, 0);
                const before = e.stats.graphics_draws;
                try featDraw(e, .{ .pipe = &feat_solid, .color = img, .uniforms = &col, .blend = add }, &ab, &pts);
                // (the 3D engine draws into either layout; compute_only keeps
                // the draw on the compute raster)
                if (e.stats.graphics_draws - before != @intFromBool(!compute)) {
                    for (e.said_compute) |w| if (w.len != 0) std.debug.print("block-linear targets: on the compute kernels: {s}\n", .{w});
                    std.debug.print("block-linear targets: the 3D engine: {s}\n", .{Rtx3d.engine3d.why});
                }
                try std.testing.expectEqual(@as(u64, @intFromBool(!compute)), e.stats.graphics_draws - before);
                e.read(img, 0, 0, W, H, &pics[ci][n], W * 4, .rgba8);
            }
        }
        // (the block-linear target's pixels are the rows')
        try std.testing.expectEqual(@as(u32, 0), apart(&pics[ci][0], &pics[ci][1], W, 0, if (compute) "block linear, compute" else "block linear, 3D engine"));
    }
    // (and the compute raster's are the engine's, within a step)
    try std.testing.expectEqual(@as(u32, 0), apart(&pics[0][1], &pics[1][1], W, 1, "block linear, compute against the 3D engine"));
    e.compute_only = false;
}

// ── Float depth (ZF32 + S8): depth and stencil on the 3D engine ───────────

var eng_zcpu: engine.Engine = undefined;
var zpool_mem: [8 << 20]u8 align(64) = undefined;

/// A float depth image (ZF32 + S8) from an engine without the 3D engine
/// (the CPU's): the same form, which its compute raster draws as the
/// RTX's does.
fn floatDepthOn(e: *engine.Engine, w: u32, h: u32) ?engine.Image {
    const was = e.depth_float;
    e.depth_float = true;
    defer e.depth_float = was;
    return e.newDepthImage(w, h);
}

test "draw: depth- and stencil-tested draws into block-linear colour with a float depth image (ZF32 + S8) go to the RTX's 3D engine; the compute raster's float form and the CPU's give the same bytes" {
    Rtx3d.engine3d = .{};
    eng_zcpu.init(.{ .pool = &zpool_mem, .cpu_work = &cpu_work });
    defer eng_zcpu.deinit();
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
    defer eng_rtx.deinit();
    defer for (feat_pipes) |p| {
        eng_rtx.unloadPipeline(p);
        eng_zcpu.unloadPipeline(p);
    };
    try std.testing.expect(eng_rtx.depth_float);
    // [0] the CPU (rows of colour, a float depth image), [1] the RTX's
    // compute raster and [2] its 3D engine (block-linear colour, the
    // engine's float depth image)
    var imgs: [3][3]engine.Image = undefined;
    imgs[0] = .{ eng_zcpu.newImage(W, H, .rgba8) orelse return error.OutOfMemory, floatDepthOn(&eng_zcpu, W, H) orelse return error.OutOfMemory, eng_zcpu.newBuffer(20 * 16) orelse return error.OutOfMemory };
    for (1..3) |n| imgs[n] = .{ eng_rtx.newBlockImage(W, H, .rgba8) orelse return error.OutOfMemory, eng_rtx.newImageSamples(W, H, .d24s8, 1) orelse return error.OutOfMemory, eng_rtx.newBuffer(20 * 16) orelse return error.OutOfMemory };
    defer {
        for (&imgs[0]) |*im| eng_zcpu.freeImage(im);
        for (imgs[1..]) |*row| for (row) |*im| eng_rtx.freeImage(im);
    }
    for (imgs) |row| try std.testing.expect(row[1].depth_float and row[1].layout.block and row[1].s8_at % 512 == 0);
    const depth_va = imgs[2][1].buf.gpu;
    var pics: [3][3 * FEAT_PIC]u8 = undefined;
    for ([_]Feature{ .frag_depth, .two_sided_stencil }) |f| {
        for ([_]bool{ false, true }) |top_down| {
            var on3d: [3]u64 = undefined;
            for (0..3) |n| {
                const e = if (n == 0) &eng_zcpu else &eng_rtx;
                e.compute_only = n == 1;
                imgs[n][0].top_down = top_down;
                imgs[n][1].top_down = top_down;
                const compute_before = e.stats.compute_draws;
                on3d[n] = featureScene(e, f, &imgs[n][0], &imgs[n][1], &imgs[n][2], &pics[n]) catch |err| {
                    std.debug.print("float depth: feature {s} (top down {}, run {d}): {s}; the 3D engine: {s}\n", .{ @tagName(f), top_down, n, @errorName(err), Rtx3d.engine3d.why });
                    return err;
                };
                if (n == 2 and e.stats.compute_draws != compute_before) {
                    for (e.said_compute) |w| if (w.len != 0) std.debug.print("float depth: on the compute kernels: {s}\n", .{w});
                    return error.WrongRasterizer;
                }
            }
            eng_rtx.compute_only = false;
            std.debug.print("float depth: feature {s} (top down {}): {d} draws on the 3D engine\n", .{ @tagName(f), top_down, on3d[2] });
            // (every draw of the scene on the engine: its depth tests, its
            // gl_FragDepth, its two-sided stencil in the S8 plane)
            try std.testing.expectEqual(@as(u64, 0), on3d[1]);
            try std.testing.expectEqual(@as(u64, 3), on3d[2]);
            try std.testing.expectEqual(@as(u32, 0), apart(pics[0][0..FEAT_PIC], pics[1][0..FEAT_PIC], W, 0, "float depth: the CPU against the RTX's compute raster"));
            try std.testing.expectEqual(@as(u32, 0), apart(pics[1][0..FEAT_PIC], pics[2][0..FEAT_PIC], W, 1, "float depth: the compute raster against the 3D engine"));
        }
    }
    // (the engine's depth image stayed where it was made, in its one form:
    // nothing moved it between layouts)
    try std.testing.expectEqual(depth_va, imgs[2][1].buf.gpu);
    try std.testing.expect(imgs[2][1].depth_float and imgs[2][1].layout.block);
    try std.testing.expectEqual(eng_rtx.stats.graphics_draws, Rtx3d.engine3d.draws);
}

/// Two triangles with sloped depths (a plane each, corners apart in z)
/// drawn LESS (the depth written, a quarter added) into `img` and the
/// float depth image `depth`, then EQUAL (another quarter where the
/// depth is the pass's own): all on the 3D engine or all on the compute
/// raster, as `engine3d` says.
fn slopedPasses(e: *engine.Engine, img: *engine.Image, depth: *engine.Image, ab: *engine.Image, pts: [4][2]f32, engine3d: bool) !void {
    e.fill(img, img.bounds(), 0, 0);
    e.fillDepth(depth, depth.bounds(), 1.0, 0, 0xff);
    var verts: [6][4]f32 = undefined;
    const tris = [2][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    const zs = [4]f32{ -0.3, 0.2117, 0.7, 0.0931 };
    for (tris, 0..) |t, n| {
        for (t, 0..) |c, j| verts[n * 3 + j] = .{ nx(pts[c][0], W), nx(pts[c][1], H), zs[c], 1 };
    }
    e.writeBytes(ab, 0, std.mem.sliceAsBytes(&verts));
    const quarter = [_]u32{ @bitCast(@as(f32, 0.25)), 0, 0, 0 };
    const add = raster.Blend{ .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } }, .gl = .{ g.ONE, g.ONE, g.ONE, g.ONE } };
    e.compute_only = !engine3d;
    defer e.compute_only = false;
    for (0..2) |pass| {
        const before = e.stats.graphics_draws;
        var d = raster.Draw{ .pipe = &solid, .color = img, .depth = depth, .depth_test = true, .depth_write = pass == 0, .depth_func = if (pass == 0) 0b001 else 0b010, .rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H }, .count = 6, .center = .{ W / 2, H / 2 }, .half = .{ W / 2, H / 2 }, .uniforms = &quarter, .blend = add };
        d.attrs[0] = .{ .buf = ab, .stride = 16, .comps = 4 };
        if (!e.draw(&d)) return error.NotDrawn;
        e.finish();
        if (e.lost or e.why_pipe != null) return error.EngineLost;
        if (e.stats.graphics_draws - before != @intFromBool(engine3d)) {
            for (e.said_compute) |w| if (w.len != 0) std.debug.print("sloped passes: on the compute kernels: {s}\n", .{w});
            return error.WrongRasterizer;
        }
    }
}

test "draw: the compute raster's float depth is the 3D engine's within 3 ulps (pc-full4's spread), over the same pixels; each path's EQUAL pass meets its own LESS pass's depths" {
    Rtx3d.engine3d = .{};
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.dev.withEngine(&Rtx3d.engine3d);
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
    defer eng_rtx.deinit();
    defer eng_rtx.unloadPipeline(&solid);
    const e = &eng_rtx;
    var img = e.newBlockImage(W, H, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    var zd: [2]engine.Image = undefined;
    for (&zd) |*z| z.* = e.newImageSamples(W, H, .d24s8, 1) orelse return error.OutOfMemory;
    defer for (&zd) |*z| e.freeImage(z);
    var ab = e.newBuffer(6 * 16) orelse return error.OutOfMemory;
    defer e.freeImage(&ab);
    const shapes = [_][4][2]f32{
        .{ .{ 8, 4 }, .{ 32, 4 }, .{ 32, 28 }, .{ 8, 28 } },
        .{ .{ 5.37, 3.11 }, .{ 58.93, 6.71 }, .{ 52.18, 29.42 }, .{ 9.66, 26.05 } },
        .{ .{ 40.5, 2.25 }, .{ 61.0078125, 30.0039 }, .{ 12.25, 30.5 }, .{ 3.1, 1.9 } },
    };
    var words: [2][W * H]u32 = undefined;
    var pic: [W * H * 4]u8 = undefined;
    const one: u32 = @bitCast(@as(f32, 1.0));
    for ([_]bool{ false, true }) |top_down| {
        img.top_down = top_down;
        for (&zd) |*z| z.top_down = top_down;
        for (shapes, 0..) |s, si| {
            for (0..2) |n| {
                slopedPasses(e, &img, &zd[n], &ab, s, n == 1) catch |err| {
                    std.debug.print("float depth ulps: shape {d} (top down {}, engine {}): {s}; the 3D engine: {s}\n", .{ si, top_down, n == 1, @errorName(err), Rtx3d.engine3d.why });
                    if (e.why_pipe) |w| std.debug.print("float depth ulps: the engine's pipeline: {s}, lost {}\n", .{ @errorName(w), e.lost });
                    return err;
                };
                e.readDepthBits(&zd[n], 0, 0, W, H, &words[n], null);
                // (every pixel the LESS pass wrote met by the EQUAL pass on
                // the same path: hit twice, 128)
                e.read(&img, 0, 0, W, H, &pic, W * 4, .rgba8);
                var covered: u32 = 0;
                for (0..W * H) |p| {
                    if (words[n][p] == one) continue;
                    covered += 1;
                    try std.testing.expectEqual(@as(u32, 2), hits(pic[p * 4]));
                }
                try std.testing.expect(covered > 0);
            }
            var most: u32 = 0;
            var differ: u32 = 0;
            for (0..W * H) |p| {
                const a = words[0][p];
                const b = words[1][p];
                // (the same pixels covered: GL's rule on both)
                try std.testing.expectEqual(a == one, b == one);
                const ulps = if (a > b) a - b else b - a;
                most = @max(most, ulps);
                differ += @intFromBool(ulps != 0);
            }
            std.debug.print("float depth ulps: shape {d} (top down {}): {d} pixels apart, at most {d} ulps\n", .{ si, top_down, differ, most });
            try std.testing.expect(most <= 3);
        }
    }
}

// ── GALAXY_GL_CHECK: the GPU's work against the CPU's ──────────────────────

var check_mem: [4 << 20]u8 align(64) = undefined;
var idle_pool: [8 << 20]u8 align(64) = undefined;
var c_mem: [8 << 20]u8 align(4096) = undefined;
var c_shadow: [16 << 20]u8 align(4096) = undefined;
var c_work: [8 << 20]u8 align(64) = undefined;
var c_emu: gpu.EmuDevice = undefined;
var eng_check: engine.Engine = undefined;
var out_check: Out = .{};

fn checkedEmu() gpu.Device {
    var caps = gpu.interp_caps;
    caps.coherent = false;
    c_emu = gpu.EmuDevice.init(caps, &c_mem, &c_work);
    c_emu.shadow = &c_shadow;
    return c_emu.device();
}

test "draw: the scene on EmuDevice, every op checked against the CPU: the same, the GPU kept" {
    const want = try cpuOut();
    eng_check.init(.{ .dev = checkedEmu(), .work = &compile_mem, .cpu_work = &cpu_work, .check = .{ .mem = &check_mem, .max_px = 1 << 20, .times = 255, .tolerance = 0 } });
    try std.testing.expect(eng_check.onGpu());
    try scene(&eng_check, &out_check);
    try std.testing.expect(eng_check.stats.checks >= 9);
    try std.testing.expectEqual(@as(u32, 0), eng_check.stats.check_diffs);
    try std.testing.expect(!eng_check.lost);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_check.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_check.win);
    eng_check.deinit();
}

/// A GPU that takes every batch and does none of it (as the real Adreno's
/// compiled kernels were seen to: every pixel left as it was).
const Idle = struct {
    var inner: gpu.Device = undefined;
    var vt: gpu.Device.VTable = undefined;
    fn run(dev: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        _ = ds;
        return inner.vtable.run(dev, &.{});
    }
    fn of(base: gpu.Device) gpu.Device {
        inner = base;
        vt = base.vtable.*;
        vt.run = run;
        return .{ .ctx = base.ctx, .vtable = &vt, .caps = base.caps };
    }
};

var said: [4096]u8 = undefined;
var said_len: usize = 0;
fn hear(line: []const u8) void {
    const n = @min(line.len, said.len - said_len);
    @memcpy(said[said_len..][0..n], line[0..n]);
    said_len += n;
}

test "draw: a GPU that does nothing is caught by the check; the CPU draws, and its bytes stand" {
    const want = try cpuOut();
    said_len = 0;
    gfxapi.report.sink = &hear;
    defer gfxapi.report.sink = null;
    // (every run checked: a check that finds the GPU's result the same as
    // the CPU's, a clear of zeros to zeros, says nothing of the next; and
    // images made after the GPU is lost come from the pool)
    eng_check.init(.{ .dev = Idle.of(checkedEmu()), .work = &compile_mem, .cpu_work = &cpu_work, .pool = &idle_pool, .check = .{ .mem = &check_mem, .max_px = 1 << 20, .times = 255 } });
    try std.testing.expect(eng_check.onGpu());
    try scene(&eng_check, &out_check);
    // (the first op checked differed: the GPU was called lost, and GL
    // reports a reset)
    try std.testing.expectEqual(@as(u32, 1), eng_check.stats.check_diffs);
    try std.testing.expect(eng_check.lost);
    try std.testing.expectEqualStrings("GpuDiffersFromCpu", @errorName(eng_check.why.?));
    // what the app's stderr says: the op, where, both values; then the loss
    const text = said[0..said_len];
    std.debug.print("{s}", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "the GPU's result differs from the CPU's") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "the GPU is lost (GpuDiffersFromCpu): drawing goes on on the CPU") != null);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_check.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_check.win);
    eng_check.deinit();
}

/// A GPU that does a draw's vertices and triangles but not its pixels: a
/// batch of three dispatches or more runs without its last (a checked
/// draw's batch is the draw alone).
const NoTiles = struct {
    var inner: gpu.Device = undefined;
    var vt: gpu.Device.VTable = undefined;
    fn run(dev: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        return inner.vtable.run(dev, if (ds.len >= 3) ds[0 .. ds.len - 1] else ds);
    }
    fn of(base: gpu.Device) gpu.Device {
        inner = base;
        vt = base.vtable.*;
        vt.run = run;
        return .{ .ctx = base.ctx, .vtable = &vt, .caps = base.caps };
    }
};

test "draw: a check names the kernel that differs: the tile kernel, the others agreeing" {
    const want = try cpuOut();
    said_len = 0;
    gfxapi.report.sink = &hear;
    defer gfxapi.report.sink = null;
    eng_check.init(.{ .dev = NoTiles.of(checkedEmu()), .work = &compile_mem, .cpu_work = &cpu_work, .pool = &idle_pool, .check = .{ .mem = &check_mem, .max_px = 1 << 20, .times = 255 } });
    try scene(&eng_check, &out_check);
    try std.testing.expect(eng_check.lost);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_check.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out_check.win);
    const text = said[0..said_len];
    std.debug.print("{s}", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "a draw: the GPU's result differs from the CPU's") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kernels agree)") != null);
    eng_check.deinit();
}

test "draw: checks off when there is no room for them; the scene as before" {
    const want = try cpuOut();
    var tiny: [64]u8 align(64) = undefined;
    eng_check.init(.{ .dev = checkedEmu(), .work = &compile_mem, .cpu_work = &cpu_work, .check = .{ .mem = &tiny, .max_px = 1 << 20 } });
    try scene(&eng_check, &out_check);
    try std.testing.expectEqual(@as(u32, 0), eng_check.stats.checks);
    try std.testing.expect(!eng_check.lost);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_check.fbo);
    eng_check.deinit();
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

fn rtxBins(cap: ?u32) !void {
    return rtxBinsOrder(cap, false);
}

fn rtxBinsOrder(cap: ?u32, reverse: bool) !void {
    const want = try binsCpu();
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.emu_work.reverse_warps = reverse;
    defer Rtx.emu_work.reverse_warps = false;
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs });
    if (cap) |c| eng_rtx.bin_cap = c;
    try std.testing.expect(eng_rtx.onGpu());
    var out: BinOut = .{};
    const ran = binScene(&eng_rtx, &out);
    if (eng_rtx.why_pipe) |e| std.debug.print("rtx pipeline: {s}\n", .{@errorName(e)});
    if (Rtx.dev.lastError()) |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(e), Rtx.dev.explain(&buf) });
    }
    try ran;
    try std.testing.expect(eng_rtx.why_pipe == null and !eng_rtx.lost);
    try std.testing.expectEqualSlices(u8, &want[0].fbo, &out.fbo);
    try std.testing.expect(eng_rtx.stats.dispatches >= 4 * 3);
    eng_rtx.deinit();
}

test "draw: bins on the emulated RTX (sm_120) give the CPU's bytes" {
    try rtxBins(null);
}

test "draw: bins on the emulated RTX (sm_120, lists that run over) give the CPU's bytes" {
    try rtxBins(24);
}

test "draw: bins on the emulated RTX with each CTA's warps in reverse order give the CPU's bytes" {
    try rtxBinsOrder(null, true);
    try rtxBinsOrder(24, true);
}

test "draw: the scene on the emulated RTX with each CTA's warps in reverse order gives the CPU's bytes" {
    const want = try cpuOut();
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Rtx.emu_work.reverse_warps = true;
    defer Rtx.emu_work.reverse_warps = false;
    eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs });
    try std.testing.expect(eng_rtx.onGpu());
    var out: Out = .{};
    const ran = scene(&eng_rtx, &out);
    if (eng_rtx.why_pipe) |e| std.debug.print("rtx pipeline: {s}\n", .{@errorName(e)});
    if (Rtx.dev.lastError()) |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(e), Rtx.dev.explain(&buf) });
    }
    try ran;
    try std.testing.expect(eng_rtx.why_pipe == null and !eng_rtx.lost);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out.fbo);
    try std.testing.expectEqualSlices(u8, &want.win, &out.win);
    eng_rtx.deinit();
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

// ── GL's render targets made block linear once (Engine.promote) ────────────

/// Frames of a framebuffer object (an RGBA8 texture, a DEPTH24_STENCIL8
/// renderbuffer) through GL: each cleared, a red quad at depth 0.5, a
/// green triangle in front of it, a blue quad behind (LESS: hidden);
/// after frame `upload_at` a texSubImage2D into the target (an op that
/// takes rows). The last frame's pixels read into `out`.
fn depthFrames(frames: u32, upload_at: ?u32, out: []u8) !struct { tex: *engine.Image, depth: *engine.Image } {
    var tex: [1]u32 = undefined;
    ctx.genTextures(&tex);
    ctx.bindTexture(g.TEXTURE_2D, tex[0]);
    ctx.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    var rb: [1]u32 = undefined;
    ctx.genRenderbuffers(&rb);
    ctx.bindRenderbuffer(g.RENDERBUFFER, rb[0]);
    ctx.renderbufferStorage(g.RENDERBUFFER, 0, g.DEPTH24_STENCIL8, W, H);
    var fb: [1]u32 = undefined;
    ctx.genFramebuffers(&fb);
    ctx.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    ctx.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_STENCIL_ATTACHMENT, g.RENDERBUFFER, rb[0]);
    if (ctx.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    ctx.viewportSet(0, 0, W, H);
    var buffer: [1]u32 = undefined;
    ctx.genBuffers(&buffer);
    const quads = [_]f32{
        // red: the whole target at z 0 (window 0.5)
        -1, -1, 0,   1, 1,  -1, 0,   1, 1,  1,  0,   1, -1, -1, 0,   1, 1,  1,  0,   1, -1, 1,  0,   1,
        // green: a triangle in front (z -0.5)
        -0.8, -0.8, -0.5, 1, 0.6, -0.7, -0.5, 1, -0.2, 0.9, -0.5, 1,
        // blue: the whole target behind (z 0.6)
        -1, -1, 0.6, 1, 1,  -1, 0.6, 1, 1,  1,  0.6, 1, -1, -1, 0.6, 1, 1,  1,  0.6, 1, -1, 1,  0.6, 1,
    };
    ctx.bindBuffer(g.ARRAY_BUFFER, buffer[0]);
    ctx.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(quads)), &quads, g.STATIC_DRAW);
    ctx.vertexAttribPointer(0, 4, g.FLOAT, false, 16, 0, false);
    ctx.enableVertexAttribArray(0, true);
    const cols = [3][4]u32{ rgba(.{ 1, 0, 0, 1 }), rgba(.{ 0, 1, 0, 1 }), rgba(.{ 0, 0, 1, 1 }) };
    const firsts = [3]i32{ 0, 6, 9 };
    const counts = [3]i32{ 6, 3, 6 };
    const grey = [_]u8{0x80} ** (4 * 4 * 4);
    for (0..frames) |fi| {
        ctx.clearColor(0, 0, 0, 1);
        ctx.clearDepth(1);
        ctx.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT);
        ctx.enable(g.DEPTH_TEST, true);
        ctx.depthFunc(g.LESS);
        for (cols, firsts, counts) |col, first, count| {
            ctx.usePipeline(&solid, &col);
            ctx.drawArrays(g.TRIANGLES, first, count, 1);
        }
        if (upload_at) |at| if (fi == at) {
            ctx.bindTexture(g.TEXTURE_2D, tex[0]);
            ctx.texSubImage2D(g.TEXTURE_2D, 0, 0, 0, 4, 4, g.RGBA, g.UNSIGNED_BYTE, &grey);
        };
        try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    }
    ctx.enable(g.DEPTH_TEST, false);
    ctx.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, @ptrCast(out.ptr));
    try std.testing.expectEqual(g.NO_ERROR, ctx.getError());
    return .{ .tex = &objs.tex[tex[0] - 1].img, .depth = &objs.rbs[rb[0] - 1].img };
}

/// The frames' pixels as GL draws them: red, green over it, no blue.
fn checkDepthFrame(out: []const u8) !void {
    var red: u32 = 0;
    var green: u32 = 0;
    for (0..W * H) |p| {
        const px_ = out[p * 4 ..][0..4];
        if (px_[2] != 0) return error.BlueShowed;
        red += @intFromBool(px_[0] == 255 and px_[1] == 0);
        green += @intFromBool(px_[1] == 255 and px_[0] == 0);
    }
    try std.testing.expect(green > 100 and red > 100 and red + green == W * H);
}

var eng_gcpu: engine.Engine = undefined;

test "draw: GL's depth-tested frames into a framebuffer object on the RTX: its texture made block linear once, its depth float, every depth draw on the 3D engine, nothing moved between layouts frame by frame; an upload moves it back to rows once and for good" {
    // (the CPU's frames: the picture each run must give)
    var want: [W * H * 4]u8 = undefined;
    eng_gcpu.init(.{ .pool = &zpool_mem, .cpu_work = &cpu_work });
    {
        objs.init();
        ctx.init(&eng_gcpu, &objs);
        defer ctx.deinit();
        defer eng_gcpu.unloadPipeline(&solid);
        _ = try depthFrames(1, null, &want);
    }
    eng_gcpu.deinit();
    try checkDepthFrame(&want);
    for ([_]?u32{ null, 1 }) |upload_at| {
        Rtx3d.engine3d = .{};
        Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
        Rtx.dev.withEngine(&Rtx3d.engine3d);
        eng_rtx.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .slabs = &rtx_slabs, .graphics = true });
        defer eng_rtx.deinit();
        objs.init();
        ctx.init(&eng_rtx, &objs);
        defer ctx.deinit();
        defer eng_rtx.unloadPipeline(&solid);
        const frames = 4;
        var got: [W * H * 4]u8 = undefined;
        const imgs = depthFrames(frames, upload_at, &got) catch |err| {
            std.debug.print("GL frames (upload at {?d}): {s}; the 3D engine: {s}\n", .{ upload_at, @errorName(err), Rtx3d.engine3d.why });
            return err;
        };
        const s = eng_rtx.stats;
        std.debug.print("GL frames (upload at {?d}): {d} draws on the 3D engine, {d} on the compute kernels; promoted {d}, back to rows {d}\n", .{ upload_at, s.graphics_draws, s.compute_draws, s.promoted, s.demoted });
        for (eng_rtx.said_compute) |w| if (w.len != 0) std.debug.print("GL frames: on the compute kernels: {s}\n", .{w});
        try std.testing.expect(imgs.depth.depth_float);
        // (made block linear at the first depth draw, never again)
        try std.testing.expectEqual(@as(u32, 1), s.promoted);
        if (upload_at) |at| {
            // (the upload moved it back once; its frames after it on the
            // compute kernels, the ones before on the engine)
            try std.testing.expectEqual(@as(u32, 1), s.demoted);
            try std.testing.expect(!imgs.tex.layout.block and imgs.tex.no_block);
            try std.testing.expectEqual(@as(u64, 3 * (at + 1)), s.graphics_draws);
            try std.testing.expectEqual(@as(u64, 3 * (frames - at - 1)), s.compute_draws);
        } else {
            try std.testing.expectEqual(@as(u32, 0), s.demoted);
            try std.testing.expect(imgs.tex.layout.block);
            try std.testing.expectEqual(@as(u64, 3 * frames), s.graphics_draws);
            try std.testing.expectEqual(@as(u64, 0), s.compute_draws);
        }
        try std.testing.expectEqual(@as(u32, 0), apart(&want, &got, W, 0, "GL frames: the CPU against the RTX"));
    }
}
