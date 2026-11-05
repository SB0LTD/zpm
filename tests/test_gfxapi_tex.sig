//! gfxapi's textures sampled by GLSL programs, drawn three ways: on the
//! CPU (KIR's interpreter), on EmuDevice (memory not coherent), and on
//! the emulated Adreno through Galaxy's calls (ir3). Every run must give
//! the same bytes, and the texels GL says.
//!
//! One program draws a quad per case into a 32 x 32 framebuffer: nearest
//! and bilinear reads (clamped at the edge), repeat and mirrored repeat,
//! LUMINANCE and ALPHA (swizzled R8), a BGRA texture, RGB565 unpacked
//! with a TEXTURE_SWIZZLE, an RGBA32F texelFetch, an RGBA32I integer
//! texture, textureSize, a unit with no texture, a sampler object's
//! filter over its texture's, and a quad whose corners its vertex shader
//! fetches from a float texture (vertex texture fetch). The cases are
//! drawn in two halves, each on a fresh device (the emulated Adreno's
//! memory is 64 buffers, never freed), into regions apart.

const std = @import("std");
const gpu = @import("gpu");
const adreno = @import("adreno");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const gles = gfxapi.gles;
const program = gfxapi.program;
const g = gfxapi.glenum;
const node = gfxapi.node;

const W = 32;
const H = 32;

const vs: [:0]const u8 =
    \\#version 300 es
    \\in vec2 aPos;
    \\uniform vec4 uRect;
    \\uniform highp sampler2D uVerts;
    \\uniform int uVtf;
    \\out vec2 vUv;
    \\void main() {
    \\    vec2 p = mix(uRect.xy, uRect.zw, aPos);
    \\    if (uVtf == 1) p = texelFetch(uVerts, ivec2(int(aPos.x) + 2 * int(aPos.y), 0), 0).xy;
    \\    vUv = aPos;
    \\    gl_Position = vec4(p / 16.0 - 1.0, 0.0, 1.0);
    \\}
;

const fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\precision highp isampler2D;
    \\uniform sampler2D uTex;
    \\uniform isampler2D uInts;
    \\uniform int uMode;
    \\uniform vec2 uScale;
    \\in vec2 vUv;
    \\out vec4 o;
    \\void main() {
    \\    if (uMode == 0) {
    \\        o = texture(uTex, vUv * uScale);
    \\    } else if (uMode == 1) {
    \\        o = texelFetch(uTex, ivec2(vUv * 4.0), 0) * 0.25 + 0.5;
    \\    } else if (uMode == 2) {
    \\        ivec4 v = texelFetch(uInts, ivec2(0, 0), 0);
    \\        o = vec4(v) / 255.0;
    \\    } else {
    \\        ivec2 sz = textureSize(uTex, 0);
    \\        o = vec4(float(sz.x) / 255.0, float(sz.y) / 255.0, 0.0, 1.0);
    \\    }
    \\}
;

const Out = struct {
    fbo: [W * H * 4]u8 = [_]u8{0} ** (W * H * 4),
    half: [W * H * 4]u8 = undefined,
    errors: u32 = 0,
    log: [512]u8 = undefined,
    log_len: usize = 0,
};

var objs: gles.Objects = undefined;
var ctx: gles.Context = undefined;

fn noErr(c: *gles.Context, out: *Out) void {
    if (c.getError() != g.NO_ERROR) out.errors += 1;
}

/// The 4 x 4 RGBA8 texture: texel (i, j) = (60 i, 60 j, 200, 255).
fn grid() [64]u8 {
    var out: [64]u8 = undefined;
    for (0..4) |j| {
        for (0..4) |i| out[(j * 4 + i) * 4 ..][0..4].* = .{ @intCast(60 * i), @intCast(60 * j), 200, 255 };
    }
    return out;
}

fn texel(i: usize, j: usize) [4]u8 {
    return .{ @intCast(60 * i), @intCast(60 * j), 200, 255 };
}

fn tex(c: *gles.Context, unit: u32, internal: u32, w: i32, h: i32, format: u32, ty: u32, data: ?*const anyopaque) u32 {
    var name: [1]u32 = undefined;
    c.genTextures(&name);
    c.activeTexture(g.TEXTURE0 + unit);
    c.bindTexture(g.TEXTURE_2D, name[0]);
    c.texImage2D(g.TEXTURE_2D, 0, @bitCast(internal), w, h, 0, format, ty, data);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.NEAREST);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.NEAREST);
    return name[0];
}

/// Half 0 draws cases A to H, half 1 cases I to N; out.fbo gets what
/// it drew (the other half's regions stay clear).
fn scene(eng: *engine.Engine, out: *Out, half: u1) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
    var color: [1]u32 = undefined;
    c.genTextures(&color);
    c.bindTexture(g.TEXTURE_2D, color[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, color[0], 0);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, W, H);
    c.clearColor(0, 0, 0, 0);
    c.clear(g.COLOR_BUFFER_BIT);
    var vao: [1]u32 = undefined;
    c.genVertexArrays(&vao);
    c.bindVertexArray(vao[0]);
    var buf: [1]u32 = undefined;
    c.genBuffers(&buf);
    const quad = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    c.bindBuffer(g.ARRAY_BUFFER, buf[0]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, g.STATIC_DRAW);
    c.vertexAttribPointer(0, 2, g.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(0, true);

    // the program
    const v = program.createShader(c, g.VERTEX_SHADER);
    const f = program.createShader(c, g.FRAGMENT_SHADER);
    for ([_]u32{ v, f }, [_][:0]const u8{ vs, fs }) |s, src| {
        const parts = [_]?[*]const u8{src.ptr};
        program.shaderSource(c, s, 1, &parts, null);
        program.compileShader(c, s);
    }
    const p = program.createProgram(c);
    program.attachShader(c, p, v);
    program.attachShader(c, p, f);
    program.linkProgram(c, p);
    var ok: i32 = 0;
    program.getProgramiv(c, p, g.LINK_STATUS, &ok);
    if (ok != 1) {
        var len: i32 = 0;
        program.getProgramInfoLog(c, p, out.log.len, &len, &out.log);
        out.log_len = @intCast(len);
        out.errors += 1;
        return;
    }
    program.useProgram(c, p);
    const uRect = program.getUniformLocation(c, p, "uRect");
    const uMode = program.getUniformLocation(c, p, "uMode");
    const uScale = program.getUniformLocation(c, p, "uScale");
    const uVtf = program.getUniformLocation(c, p, "uVtf");
    setI(c, program.getUniformLocation(c, p, "uTex"), 0);
    setI(c, program.getUniformLocation(c, p, "uInts"), 1);
    setI(c, program.getUniformLocation(c, p, "uVerts"), 2);
    setF(c, uScale, &.{ 1, 1 });
    noErr(c, out);

    // A: nearest, the 4 x 4 grid (2 x 2 pixels a texel)
    const gpx = grid();
    const t_grid = tex(c, 0, g.RGBA8, 4, 4, g.RGBA, g.UNSIGNED_BYTE, &gpx);
    if (half == 1) return secondHalf(c, out, t_grid, uRect, uMode, uVtf, p, v, f);
    draw(c, uRect, 0, 0);
    // B: bilinear, clamped at the edge
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.CLAMP_TO_EDGE);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.CLAMP_TO_EDGE);
    draw(c, uRect, 8, 0);
    // C: repeat, twice across; D: mirrored repeat
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.NEAREST);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.REPEAT);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.REPEAT);
    setF(c, uScale, &.{ 2, 2 });
    draw(c, uRect, 16, 0);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.MIRRORED_REPEAT);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.MIRRORED_REPEAT);
    draw(c, uRect, 24, 0);
    setF(c, uScale, &.{ 1, 1 });
    noErr(c, out);
    // E: LUMINANCE (50, then 200); F: ALPHA
    const lum = [_]u8{ 50, 200 };
    _ = tex(c, 0, g.LUMINANCE, 2, 1, g.LUMINANCE, g.UNSIGNED_BYTE, &lum);
    draw(c, uRect, 0, 8);
    const alpha = [_]u8{128};
    c.pixelStore(g.UNPACK_ALIGNMENT, 1);
    _ = tex(c, 0, g.ALPHA, 1, 1, g.ALPHA, g.UNSIGNED_BYTE, &alpha);
    draw(c, uRect, 8, 8);
    // G: BGRA bytes (B 10, G 20, R 30, A 40)
    const bgra = [_]u8{ 10, 20, 30, 40 };
    _ = tex(c, 0, g.BGRA_EXT, 1, 1, g.BGRA_EXT, g.UNSIGNED_BYTE, &bgra);
    draw(c, uRect, 16, 8);
    // H: RGB565 red, green swizzled from red
    const red565 = [_]u8{ 0x00, 0xf8 };
    _ = tex(c, 0, g.RGB, 1, 1, g.RGB, g.UNSIGNED_SHORT_5_6_5, &red565);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_SWIZZLE_G, g.RED);
    draw(c, uRect, 24, 8);
    noErr(c, out);
    finishHalf(c, out, p, v, f);
}

fn finishHalf(c: *gles.Context, out: *Out, p: u32, v: u32, f: u32) void {
    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &out.half);
    for (&out.fbo, out.half) |*a, b| a.* |= b;
    noErr(c, out);
    c.finish();
    program.useProgram(c, 0);
    program.deleteProgram(c, p);
    program.deleteShader(c, v);
    program.deleteShader(c, f);
}

fn setI(cc: *gles.Context, l: i32, x: i32) void {
    const val = [_]i32{x};
    program.uniform(cc, l, 1, 1, .i, @ptrCast(&val));
}

fn setF(cc: *gles.Context, l: i32, xs: []const f32) void {
    program.uniform(cc, l, 1, @intCast(xs.len), .f, @ptrCast(xs.ptr));
}

fn draw(cc: *gles.Context, l: i32, x0: f32, y0: f32) void {
    setF(cc, l, &.{ x0, y0, x0 + 8, y0 + 8 });
    cc.drawArrays(g.TRIANGLES, 0, 6, 1);
}

fn secondHalf(c: *gles.Context, out: *Out, t_grid: u32, uRect: i32, uMode: i32, uVtf: i32, p: u32, v: u32, f: u32) void {
    // I: RGBA32F texelFetch: texel (i, j) = (i - 2, j - 2, 0.5, 1)
    var fl: [64]f32 = undefined;
    for (0..4) |j| {
        for (0..4) |i| fl[(j * 4 + i) * 4 ..][0..4].* = .{ @as(f32, @floatFromInt(i)) - 2, @as(f32, @floatFromInt(j)) - 2, 0.5, 1 };
    }
    c.pixelStore(g.UNPACK_ALIGNMENT, 4);
    _ = tex(c, 0, g.RGBA32F, 4, 4, g.RGBA, g.FLOAT, &fl);
    setI(c, uMode, 1);
    draw(c, uRect, 0, 16);
    // J: RGBA32I on unit 1
    const ints = [_]i32{ 10, 20, 30, 255 };
    _ = tex(c, 1, g.RGBA32I, 1, 1, g.RGBA_INTEGER, g.INT, &ints);
    setI(c, uMode, 2);
    draw(c, uRect, 8, 16);
    // K: textureSize of a 5 x 7 texture
    var big: [5 * 7 * 4]u8 = undefined;
    @memset(&big, 7);
    _ = tex(c, 0, g.RGBA8, 5, 7, g.RGBA, g.UNSIGNED_BYTE, &big);
    setI(c, uMode, 3);
    draw(c, uRect, 16, 16);
    // L: no texture on the unit: (0, 0, 0, 1)
    c.activeTexture(g.TEXTURE0);
    c.bindTexture(g.TEXTURE_2D, 0);
    setI(c, uMode, 0);
    draw(c, uRect, 24, 16);
    noErr(c, out);
    // M: the grid (nearest) under a sampler object's bilinear, clamped
    c.bindTexture(g.TEXTURE_2D, t_grid);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.NEAREST);
    var smp: [1]u32 = undefined;
    c.genSamplers(&smp);
    c.samplerParameteri(smp[0], g.TEXTURE_MAG_FILTER, g.LINEAR);
    c.samplerParameteri(smp[0], g.TEXTURE_WRAP_S, g.CLAMP_TO_EDGE);
    c.samplerParameteri(smp[0], g.TEXTURE_WRAP_T, g.CLAMP_TO_EDGE);
    c.bindSampler(0, smp[0]);
    draw(c, uRect, 0, 24);
    c.bindSampler(0, 0);
    noErr(c, out);
    // N: the corners from a float texture (vertex texture fetch), on unit 2
    const corners = [_]f32{ 8, 24, 0, 0, 16, 24, 0, 0, 8, 32, 0, 0, 16, 32, 0, 0 };
    _ = tex(c, 2, g.RGBA32F, 4, 1, g.RGBA, g.FLOAT, &corners);
    c.activeTexture(g.TEXTURE0);
    setI(c, uVtf, 1);
    draw(c, uRect, 100, 100);
    setI(c, uVtf, 0);
    noErr(c, out);
    finishHalf(c, out, p, v, f);
}

fn px(o: []const u8, x: usize, y: usize) [4]u8 {
    return o[(y * W + x) * 4 ..][0..4].*;
}

fn near(a: [4]u8, b: [4]u8) bool {
    for (a, b) |x, y| {
        if (@abs(@as(i32, x) - y) > 1) return false;
    }
    return true;
}

fn check(o: *const Out) !void {
    if (o.log_len > 0) std.debug.print("{s}\n", .{o.log[0..o.log_len]});
    try std.testing.expectEqual(@as(u32, 0), o.errors);
    const E = std.testing.expectEqual;
    // A: nearest
    try E(texel(0, 0), px(&o.fbo, 0, 0));
    try E(texel(1, 2), px(&o.fbo, 2, 5));
    try E(texel(3, 3), px(&o.fbo, 7, 7));
    // B: bilinear: the corner clamped (the texel itself), between texels 1 and 2 a blend
    try E(texel(0, 0), px(&o.fbo, 8, 0));
    try std.testing.expect(near(.{ 105, 105, 200, 255 }, px(&o.fbo, 12, 4)));
    // C: repeat (texel 0 again at x 4); D: mirrored (texel 3 at x 4)
    try E(texel(0, 0), px(&o.fbo, 20, 0));
    try E(texel(2, 0), px(&o.fbo, 18, 0));
    try E(texel(3, 3), px(&o.fbo, 28, 4));
    // E: luminance; F: alpha
    try E([4]u8{ 50, 50, 50, 255 }, px(&o.fbo, 1, 8));
    try E([4]u8{ 200, 200, 200, 255 }, px(&o.fbo, 6, 8));
    try E([4]u8{ 0, 0, 0, 128 }, px(&o.fbo, 9, 9));
    // G: BGRA read as RGBA; H: RGB565 red, green = red
    try E([4]u8{ 30, 20, 10, 40 }, px(&o.fbo, 17, 9));
    try E([4]u8{ 255, 255, 0, 255 }, px(&o.fbo, 25, 9));
    // I: (-2, -2, 0.5, 1) * 0.25 + 0.5; (1, 1, ...) at texel (3, 3)
    try E([4]u8{ 0, 0, 159, 191 }, px(&o.fbo, 0, 16));
    try E([4]u8{ 191, 191, 159, 191 }, px(&o.fbo, 7, 23));
    // J: the ints; K: the size; L: nothing bound
    try E([4]u8{ 10, 20, 30, 255 }, px(&o.fbo, 9, 17));
    try E([4]u8{ 5, 7, 0, 255 }, px(&o.fbo, 17, 17));
    try E([4]u8{ 0, 0, 0, 255 }, px(&o.fbo, 25, 17));
    // M: the sampler's bilinear, as B
    try E(px(&o.fbo, 12, 4), px(&o.fbo, 4, 28));
    try E(texel(0, 0), px(&o.fbo, 0, 24));
    // N: the fetched corners put the quad at (8, 24) .. (16, 32)
    try E(texel(0, 0), px(&o.fbo, 8, 24));
    try E(texel(3, 3), px(&o.fbo, 15, 31));
}

// ── The three runs ─────────────────────────────────────────────────────────

var pool_mem: [8 << 20]u8 align(64) = undefined;
var cpu_work: [8 << 20]u8 align(64) = undefined;
var eng_cpu: engine.Engine = undefined;
var out_cpu: Out = .{};
var cpu_done = false;

fn cpuOut() !*const Out {
    if (!cpu_done) {
        for ([_]u1{ 0, 1 }) |half| {
            eng_cpu.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
            try scene(&eng_cpu, &out_cpu, half);
        }
        if (eng_cpu.why_pipe) |e| std.debug.print("cpu draw: {s} at pc {d}\n", .{ @errorName(e), eng_cpu.trap.pc });
        cpu_done = true;
    }
    return &out_cpu;
}

test "textures: sampled on the CPU" {
    try check(try cpuOut());
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "textures: on EmuDevice, the CPU's bytes" {
    const want = try cpuOut();
    for ([_]u1{ 0, 1 }) |half| {
        var caps = gpu.interp_caps;
        caps.coherent = false;
        emu = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
        emu.shadow = &emu_shadow;
        eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem, .cpu_work = &cpu_work });
        try std.testing.expect(eng_emu.onGpu());
        try scene(&eng_emu, &out_emu, half);
        if (eng_emu.why_pipe) |e| std.debug.print("emu pipeline: {s}\n", .{@errorName(e)});
        try std.testing.expect(eng_emu.why_pipe == null);
        try std.testing.expect(!eng_emu.lost);
        eng_emu.deinit();
    }
    try check(&out_emu);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_emu.fbo);
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

test "textures: on the emulated Adreno (ir3), the CPU's bytes" {
    const want = try cpuOut();
    for ([_]u1{ 0, 1 }) |half| {
        a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
        a_fake = .{ .emu = &a_emu };
        a_gpu = .{ .node = .{ .sys = &a_fake } };
        const d = try a_gpu.open();
        eng_a.init(.{ .dev = d, .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
        try std.testing.expect(eng_a.onGpu());
        try scene(&eng_a, &out_a, half);
        if (eng_a.why_pipe) |e| std.debug.print("adreno pipeline: {s}\n", .{@errorName(e)});
        if (a_emu.last_error) |e| std.debug.print("ir3_emu: {s}: {s}\n", .{ @errorName(e), a_emu.fault.text() });
        try std.testing.expect(eng_a.why_pipe == null);
        try std.testing.expect(!eng_a.lost);
        eng_a.deinit();
        a_gpu.close();
    }
    try check(&out_a);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_a.fbo);
}
