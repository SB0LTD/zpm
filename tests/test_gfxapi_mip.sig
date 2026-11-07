//! gfxapi's mipmaps, drawn three ways: on the CPU (KIR's interpreter), on
//! EmuDevice (memory not coherent), and on the emulated Adreno through
//! Galaxy's calls (ir3). Every run must give the same bytes, and the
//! texels GL says.
//!
//! A 16 x 16 texture whose levels are each one color (red, green, blue,
//! white, yellow) is drawn on quads of 16, 8, 4, 2 and 1 pixels: the
//! implicit level of detail (from the quad's derivatives) picks levels 0
//! to 4. Then: textureLod; trilinear filtering between two levels;
//! textureGrad; a bias; texelFetch and textureSize of a level; a base
//! level of 1; glGenerateMipmap of a checkerboard (gray below level 0);
//! a texture missing the levels its filter needs (incomplete: black); an
//! immutable texture's levels filled by glTexSubImage2D. The cases are
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

const W = 64;
const H = 32;

const vs: [:0]const u8 =
    \\#version 300 es
    \\in vec2 aPos;
    \\uniform vec4 uRect;
    \\out vec2 vUv;
    \\void main() {
    \\    vUv = aPos;
    \\    vec2 p = mix(uRect.xy, uRect.zw, aPos);
    \\    gl_Position = vec4(p.x / 32.0 - 1.0, p.y / 16.0 - 1.0, 0.0, 1.0);
    \\}
;

const fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uTex;
    \\uniform int uMode;
    \\uniform float uLod;
    \\in vec2 vUv;
    \\out vec4 o;
    \\void main() {
    \\    if (uMode == 0) o = texture(uTex, vUv);
    \\    else if (uMode == 1) o = textureLod(uTex, vUv, uLod);
    \\    else if (uMode == 2) o = textureGrad(uTex, vUv, vec2(uLod / 16.0, 0.0), vec2(0.0, uLod / 16.0));
    \\    else if (uMode == 3) o = texelFetch(uTex, ivec2(vUv * 4.0), 2);
    \\    else if (uMode == 4) {
    \\        ivec2 s = textureSize(uTex, 1);
    \\        o = vec4(float(s.x) / 255.0, float(s.y) / 255.0, 0.0, 1.0);
    \\    } else o = texture(uTex, vUv, uLod);
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

fn setI(cc: *gles.Context, l: i32, x: i32) void {
    const val = [_]i32{x};
    program.uniform(cc, l, 1, 1, .i, @ptrCast(&val));
}

fn setF(cc: *gles.Context, l: i32, xs: []const f32) void {
    program.uniform(cc, l, 1, @intCast(xs.len), .f, @ptrCast(xs.ptr));
}

const Loc = struct { rect: i32, mode: i32, lod: i32 };

fn quad(cc: *gles.Context, l: Loc, mode: i32, lod: f32, x0: f32, y0: f32, side: f32) void {
    setI(cc, l.mode, mode);
    setF(cc, l.lod, &.{lod});
    setF(cc, l.rect, &.{ x0, y0, x0 + side, y0 + side });
    cc.drawArrays(g.TRIANGLES, 0, 6, 1);
}

const red = [4]u8{ 255, 0, 0, 255 };
const green = [4]u8{ 0, 255, 0, 255 };
const blue = [4]u8{ 0, 0, 255, 255 };
const white = [4]u8{ 255, 255, 255, 255 };
const yellow = [4]u8{ 255, 255, 0, 255 };
const cyan = [4]u8{ 0, 255, 255, 255 };
const colors = [_][4]u8{ red, green, blue, white, yellow };

var level_px: [16 * 16 * 4]u8 = undefined;

/// A side x side level of one color.
fn solid(side: usize, col: [4]u8) []const u8 {
    for (0..side * side) |i| level_px[i * 4 ..][0..4].* = col;
    return level_px[0 .. side * side * 4];
}

fn newTex(c: *gles.Context) u32 {
    var t: [1]u32 = undefined;
    c.genTextures(&t);
    c.bindTexture(g.TEXTURE_2D, t[0]);
    return t[0];
}

fn filters(c: *gles.Context, min: u32, mag: u32) void {
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, @intCast(min));
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, @intCast(mag));
}

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
    const corners = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    c.bindBuffer(g.ARRAY_BUFFER, buf[0]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(corners)), &corners, g.STATIC_DRAW);
    c.vertexAttribPointer(0, 2, g.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(0, true);

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
    const l = Loc{ .rect = program.getUniformLocation(c, p, "uRect"), .mode = program.getUniformLocation(c, p, "uMode"), .lod = program.getUniformLocation(c, p, "uLod") };
    setI(c, program.getUniformLocation(c, p, "uTex"), 0);
    noErr(c, out);

    if (half == 1) return secondHalf(c, out, l, p, v, f);
    // A: levels 0..4, each a color
    _ = newTex(c);
    for (colors, 0..) |col, lv| {
        const side: i32 = @as(i32, 16) >> @intCast(lv);
        c.texImage2D(g.TEXTURE_2D, @intCast(lv), g.RGBA8, side, side, 0, g.RGBA, g.UNSIGNED_BYTE, solid(@intCast(side), col).ptr);
    }
    filters(c, g.NEAREST_MIPMAP_NEAREST, g.NEAREST);
    noErr(c, out);
    // a..e: quads of 16, 8, 4, 2 and 1 pixels: levels 0 to 4
    quad(c, l, 0, 0, 0, 0, 16);
    quad(c, l, 0, 0, 16, 0, 8);
    quad(c, l, 0, 0, 24, 0, 4);
    quad(c, l, 0, 0, 28, 0, 2);
    quad(c, l, 0, 0, 30, 0, 1);
    // f: textureLod 2
    quad(c, l, 1, 2, 32, 0, 8);
    // g: trilinear, λ = log2(16 / 6) between levels 1 and 2
    filters(c, g.LINEAR_MIPMAP_LINEAR, g.LINEAR);
    quad(c, l, 0, 0, 40, 0, 6);
    filters(c, g.NEAREST_MIPMAP_NEAREST, g.NEAREST);
    // h: textureGrad, ρ 4: level 2
    quad(c, l, 2, 4, 48, 0, 8);
    // i: a bias of 1 on a 16-pixel quad: level 1
    quad(c, l, 5, 1, 0, 16, 16);
    // j: texelFetch of level 2; textureSize of level 1 (8 x 8)
    quad(c, l, 3, 0, 56, 0, 4);
    quad(c, l, 4, 0, 60, 0, 4);
    // k: base level 1: an 8-pixel quad reads it at λ 0
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_BASE_LEVEL, 1);
    quad(c, l, 0, 0, 16, 16, 8);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_BASE_LEVEL, 0);
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

fn secondHalf(c: *gles.Context, out: *Out, l: Loc, p: u32, v: u32, f: u32) void {
    // l: a 1-texel checkerboard's mipmaps: gray (128) below level 0
    _ = newTex(c);
    for (0..16) |y| {
        for (0..16) |x| level_px[(y * 16 + x) * 4 ..][0..4].* = if ((x + y) % 2 == 0) [4]u8{ 0, 0, 0, 255 } else white;
    }
    c.texImage2D(g.TEXTURE_2D, 0, g.RGBA8, 16, 16, 0, g.RGBA, g.UNSIGNED_BYTE, &level_px);
    c.generateMipmap(g.TEXTURE_2D);
    filters(c, g.NEAREST_MIPMAP_NEAREST, g.NEAREST);
    quad(c, l, 1, 1, 32, 16, 8);
    noErr(c, out);
    // m: level 0 alone under a mipmap filter: incomplete, (0, 0, 0, 1)
    _ = newTex(c);
    c.texImage2D(g.TEXTURE_2D, 0, g.RGBA8, 16, 16, 0, g.RGBA, g.UNSIGNED_BYTE, solid(16, red).ptr);
    filters(c, g.LINEAR_MIPMAP_LINEAR, g.LINEAR);
    quad(c, l, 0, 0, 40, 16, 8);
    // n: an immutable texture's levels by glTexSubImage2D: level 2 cyan
    _ = newTex(c);
    c.texStorage2D(g.TEXTURE_2D, 5, g.RGBA8, 16, 16);
    for (0..5) |lv| {
        const side: i32 = @as(i32, 16) >> @intCast(lv);
        c.texSubImage2D(g.TEXTURE_2D, @intCast(lv), 0, 0, side, side, g.RGBA, g.UNSIGNED_BYTE, solid(@intCast(side), if (lv == 2) cyan else red).ptr);
    }
    filters(c, g.NEAREST_MIPMAP_NEAREST, g.NEAREST);
    quad(c, l, 1, 2, 48, 16, 8);
    noErr(c, out);
    // (a level the texture has not: an error)
    c.texSubImage2D(g.TEXTURE_2D, 6, 0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, solid(1, red).ptr);
    if (c.getError() == g.NO_ERROR) out.errors += 1;
    finishHalf(c, out, p, v, f);
}

fn px(o: []const u8, x: usize, y: usize) [4]u8 {
    return o[(y * W + x) * 4 ..][0..4].*;
}

fn near(a: [4]u8, b: [4]u8, tol: i32) bool {
    for (a, b) |x, y| {
        if (@abs(@as(i32, x) - y) > tol) return false;
    }
    return true;
}

fn check(o: *const Out) !void {
    if (o.log_len > 0) std.debug.print("{s}\n", .{o.log[0..o.log_len]});
    const E = std.testing.expectEqual;
    try E(@as(u32, 0), o.errors);
    // a..e: each quad its level's color
    try E(red, px(&o.fbo, 8, 8));
    try E(green, px(&o.fbo, 20, 4));
    try E(blue, px(&o.fbo, 26, 2));
    try E(white, px(&o.fbo, 29, 1));
    try E(yellow, px(&o.fbo, 30, 0));
    // f: textureLod 2
    try E(blue, px(&o.fbo, 36, 4));
    // g: trilinear: green and blue, blue's weight λ's fraction (0.415)
    const tri = px(&o.fbo, 43, 3);
    if (!near(tri, .{ 0, 149, 106, 255 }, 4)) std.debug.print("trilinear: {any}\n", .{tri});
    try std.testing.expect(near(tri, .{ 0, 149, 106, 255 }, 4));
    // h: textureGrad, ρ 4
    try E(blue, px(&o.fbo, 52, 4));
    // i: the bias
    try E(green, px(&o.fbo, 8, 24));
    // j: texelFetch of level 2; textureSize(1)
    try E(blue, px(&o.fbo, 58, 2));
    try E([4]u8{ 8, 8, 0, 255 }, px(&o.fbo, 62, 2));
    // k: base level 1
    try E(green, px(&o.fbo, 20, 20));
    // l: the generated level 1: gray
    try E([4]u8{ 128, 128, 128, 255 }, px(&o.fbo, 36, 20));
    // m: incomplete: black, opaque
    try E([4]u8{ 0, 0, 0, 255 }, px(&o.fbo, 44, 20));
    // n: the immutable texture's level 2
    try E(cyan, px(&o.fbo, 52, 20));
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
            if (eng_cpu.why_pipe) |e| std.debug.print("cpu draw: {s} at pc {d}\n", .{ @errorName(e), eng_cpu.trap.pc });
            try std.testing.expect(eng_cpu.why_pipe == null);
        }
        cpu_done = true;
    }
    return &out_cpu;
}

test "mipmaps: implicit, explicit and gradient LOD, trilinear, generated, on the CPU" {
    try check(try cpuOut());
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "mipmaps: on EmuDevice, the CPU's bytes" {
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
        try std.testing.expect(eng_emu.why_pipe == null and !eng_emu.lost);
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

test "mipmaps: on the emulated Adreno (ir3), the CPU's bytes" {
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
        if (eng_a.why) |e| std.debug.print("adreno lost: {s}\n", .{@errorName(e)});
        try std.testing.expect(eng_a.why_pipe == null and !eng_a.lost);
        eng_a.deinit();
        a_gpu.close();
    }
    try check(&out_a);
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_a.fbo);
}
