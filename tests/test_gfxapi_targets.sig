//! gfxapi's render targets other than RGBA8: R8 and RG8 (WebRender's
//! masks), drawn three ways: on the CPU (KIR's interpreter), on EmuDevice
//! (memory not coherent), and on the emulated Adreno through Galaxy's
//! calls (ir3). Every run must give the same bytes, and the values GL says.
//!
//! An R8 texture is cleared, drawn into with additive blending, drawn
//! into again under a color mask that keeps its red, and gets a corner
//! copied from an RGBA8 framebuffer's red (glCopyTexSubImage2D); it is
//! read back as RED and as RGBA. An RG8 texture is cleared and half drawn
//! over, and read back as RG. An RG8 renderbuffer is complete and says
//! its sizes. Last, a program samples both masks into an RGBA8 target.

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
    \\out vec2 vUv;
    \\void main() {
    \\    vUv = aPos;
    \\    gl_Position = vec4(mix(uRect.xy, uRect.zw, aPos) / 16.0 - 1.0, 0.0, 1.0);
    \\}
;

const fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uMask;
    \\uniform sampler2D uRG;
    \\uniform int uMode;
    \\uniform vec4 uColor;
    \\in vec2 vUv;
    \\out vec4 o;
    \\void main() {
    \\    if (uMode == 0) o = uColor;
    \\    else o = vec4(texture(uMask, vUv).r, texture(uRG, vUv).rg, 1.0);
    \\}
;

const Out = struct {
    mask: [W * H]u8 = undefined,
    mask_rgba: [8]u8 = undefined,
    rg: [W * H * 2]u8 = undefined,
    fbo: [W * H * 4]u8 = undefined,
    read_format: i32 = 0,
    rb_sizes: [4]i32 = .{ 0, 0, 0, 0 },
    rb_complete: bool = false,
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

fn rect(cc: *gles.Context, l: i32, x0: f32, y0: f32, x1: f32, y1: f32) void {
    setF(cc, l, &.{ x0, y0, x1, y1 });
    cc.drawArrays(g.TRIANGLES, 0, 6, 1);
}

/// A W x H texture of `internal` on unit `unit` and a framebuffer of it.
fn target(c: *gles.Context, unit: u32, internal: u32) struct { tex: u32, fb: u32 } {
    var t: [1]u32 = undefined;
    c.genTextures(&t);
    c.activeTexture(g.TEXTURE0 + unit);
    c.bindTexture(g.TEXTURE_2D, t[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, internal, W, H);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.NEAREST);
    c.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.NEAREST);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, t[0], 0);
    return .{ .tex = t[0], .fb = fb[0] };
}

fn scene(eng: *engine.Engine, out: *Out) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
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
    const uColor = program.getUniformLocation(c, p, "uColor");
    setI(c, program.getUniformLocation(c, p, "uMask"), 0);
    setI(c, program.getUniformLocation(c, p, "uRG"), 1);
    c.viewportSet(0, 0, W, H);
    noErr(c, out);

    // the R8 mask: cleared to 0.25 (64), 0.5 added on the left half
    const m = target(c, 0, g.R8);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.clearColor(0.25, 0.9, 0.9, 0.9);
    c.clear(g.COLOR_BUFFER_BIT);
    setI(c, uMode, 0);
    setF(c, uColor, &.{ 0.5, 1, 1, 1 });
    c.enable(g.BLEND, true);
    c.blendFunc(g.ONE, g.ONE, g.ONE, g.ONE);
    rect(c, uRect, 0, 0, 16, 32);
    c.enable(g.BLEND, false);
    // red masked off: the right half's bottom stays 64
    c.colorMask(false, true, true, true);
    setF(c, uColor, &.{ 1, 1, 1, 1 });
    rect(c, uRect, 16, 0, 32, 8);
    c.colorMask(true, true, true, true);
    noErr(c, out);

    // the RG8 texture: cleared to (0.5, 0.25), the top half (0.25, 1)
    const rg = target(c, 1, g.RG8);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.clearColor(0.5, 0.25, 0.9, 0.9);
    c.clear(g.COLOR_BUFFER_BIT);
    setF(c, uColor, &.{ 0.25, 1, 0, 0 });
    rect(c, uRect, 0, 16, 32, 32);
    c.readPixels(0, 0, W, H, g.RG, g.UNSIGNED_BYTE, &out.rg);
    noErr(c, out);

    // an RG8 renderbuffer: complete, red and green 8 bits
    var rb: [1]u32 = undefined;
    c.genRenderbuffers(&rb);
    c.bindRenderbuffer(g.RENDERBUFFER, rb[0]);
    c.renderbufferStorage(g.RENDERBUFFER, 0, g.RG8, W, H);
    var fb_rb: [1]u32 = undefined;
    c.genFramebuffers(&fb_rb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb_rb[0]);
    c.framebufferRenderbuffer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.RENDERBUFFER, rb[0]);
    out.rb_complete = c.checkFramebufferStatus(g.FRAMEBUFFER) == g.FRAMEBUFFER_COMPLETE;
    for (&out.rb_sizes, 0..) |*sz, n| sz.* = c.getRenderbufferParameter(g.RENDERBUFFER, g.RENDERBUFFER_RED_SIZE + @as(u32, @intCast(n))) orelse -1;
    noErr(c, out);

    // the RGBA8 target, cleared with red 0.75 (191): its red copied into
    // the mask's top right corner
    const main = target(c, 2, g.RGBA8);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.clearColor(0.75, 0.1, 0.2, 1);
    c.clear(g.COLOR_BUFFER_BIT);
    c.activeTexture(g.TEXTURE0);
    c.bindTexture(g.TEXTURE_2D, m.tex);
    c.copyTexSubImage2D(g.TEXTURE_2D, 0, 24, 24, 0, 0, 8, 8);
    noErr(c, out);

    // the mask read back: RED (its read format), and RGBA
    c.bindFramebuffer(g.FRAMEBUFFER, m.fb);
    var rf: [1]i32 = .{0};
    c.getIntegers(g.IMPLEMENTATION_COLOR_READ_FORMAT, &rf);
    out.read_format = rf[0];
    c.readPixels(0, 0, W, H, g.RED, g.UNSIGNED_BYTE, &out.mask);
    c.readPixels(0, 0, 2, 1, g.RGBA, g.UNSIGNED_BYTE, &out.mask_rgba);
    noErr(c, out);

    // both masks sampled into the RGBA8 target
    c.bindFramebuffer(g.FRAMEBUFFER, main.fb);
    c.activeTexture(g.TEXTURE0 + 1);
    c.bindTexture(g.TEXTURE_2D, rg.tex);
    setI(c, uMode, 1);
    rect(c, uRect, 0, 0, 32, 32);
    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &out.fbo);
    noErr(c, out);
    c.finish();
    program.useProgram(c, 0);
    program.deleteProgram(c, p);
    program.deleteShader(c, v);
    program.deleteShader(c, f);
}

fn near(a: u8, b: u8) bool {
    return @abs(@as(i32, a) - b) <= 1;
}

/// What the mask holds at (x, y).
fn maskAt(x: usize, y: usize) u8 {
    if (x >= 24 and y >= 24) return 191;
    return if (x < 16) 192 else 64;
}

fn check(o: *const Out) !void {
    if (o.log_len > 0) std.debug.print("{s}\n", .{o.log[0..o.log_len]});
    const E = std.testing.expectEqual;
    try E(@as(u32, 0), o.errors);
    try E(@as(i32, g.RED), o.read_format);
    try std.testing.expect(o.rb_complete);
    try E([4]i32{ 8, 8, 0, 0 }, o.rb_sizes);
    for (0..H) |y| {
        for (0..W) |x| {
            const want = maskAt(x, y);
            const got = o.mask[y * W + x];
            if (!near(want, got)) std.debug.print("mask ({d}, {d}): {d}, not {d}\n", .{ x, y, got, want });
            try std.testing.expect(near(want, got));
            const rgp = o.rg[(y * W + x) * 2 ..][0..2].*;
            try E(if (y < 16) [2]u8{ 128, 64 } else [2]u8{ 64, 255 }, rgp);
            const c = o.fbo[(y * W + x) * 4 ..][0..4].*;
            try E([4]u8{ got, rgp[0], rgp[1], 255 }, c);
        }
    }
    try E([8]u8{ o.mask[0], 0, 0, 255, o.mask[1], 0, 0, 255 }, o.mask_rgba);
}

// ── The three runs ─────────────────────────────────────────────────────────

var pool_mem: [8 << 20]u8 align(64) = undefined;
var cpu_work: [8 << 20]u8 align(64) = undefined;
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

fn same(a: *const Out, b: *const Out) !void {
    try std.testing.expectEqualSlices(u8, &a.mask, &b.mask);
    try std.testing.expectEqualSlices(u8, &a.mask_rgba, &b.mask_rgba);
    try std.testing.expectEqualSlices(u8, &a.rg, &b.rg);
    try std.testing.expectEqualSlices(u8, &a.fbo, &b.fbo);
}

test "targets: R8 and RG8 drawn, cleared, copied, read and sampled on the CPU" {
    try check(try cpuOut());
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "targets: on EmuDevice, the CPU's bytes" {
    const want = try cpuOut();
    var caps = gpu.interp_caps;
    caps.coherent = false;
    emu = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem, .cpu_work = &cpu_work });
    try std.testing.expect(eng_emu.onGpu());
    try scene(&eng_emu, &out_emu);
    if (eng_emu.why_pipe) |e| std.debug.print("emu pipeline: {s}\n", .{@errorName(e)});
    try std.testing.expect(eng_emu.why_pipe == null and !eng_emu.lost);
    eng_emu.deinit();
    try check(&out_emu);
    try same(want, &out_emu);
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

test "targets: on the emulated Adreno (ir3), the CPU's bytes" {
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
    try std.testing.expect(eng_a.why_pipe == null and !eng_a.lost);
    eng_a.deinit();
    a_gpu.close();
    try check(&out_a);
    try same(want, &out_a);
}
