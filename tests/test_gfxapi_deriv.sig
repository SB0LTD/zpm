//! gfxapi's derivatives (dFdx, dFdy, fwidth): a program that takes them
//! runs whole 2 x 2 quads (helper pixels), drawn three ways: on the CPU
//! (KIR's interpreter), on EmuDevice (memory not coherent), and on the
//! emulated Adreno through Galaxy's calls (ir3). Every run must give the
//! same bytes, and the values GL says.
//!
//! Four 16 x 16 quads, one a mode: a coordinate's step across and up (1
//! everywhere, at the triangles' shared diagonal too: helpers come from
//! the same triangle) and a product's fwidth (x + y); a circle's edge
//! antialiased over a pixel with fwidth, as WebRender's clip shaders do;
//! a derivative under an `if` on a value that differs between pixels (0:
//! GL leaves it undefined) and one after it (1 again); one after a
//! `discard` some pixels take (0, and no lane read that is not there).

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
    \\uniform int uMode;
    \\in vec2 vUv;
    \\out vec4 o;
    \\void main() {
    \\    vec2 p = vUv * 16.0;
    \\    if (uMode == 0) {
    \\        o = vec4(dFdx(p.x), dFdy(p.y), fwidth(p.x * p.y) / 32.0, 1.0);
    \\    } else if (uMode == 1) {
    \\        float d = length(p - 8.0) - 6.0;
    \\        float aa = fwidth(d);
    \\        o = vec4(1.0, 1.0, 1.0, clamp(0.5 - d / aa, 0.0, 1.0));
    \\    } else if (uMode == 2) {
    \\        o = vec4(0.0, 0.0, 0.0, 1.0);
    \\        if (p.x > 7.0) o.r = dFdx(p.x);
    \\        o.g = dFdx(p.x);
    \\    } else {
    \\        if (p.y < 3.0) discard;
    \\        o = vec4(dFdx(p.x), 0.0, 0.0, 1.0);
    \\    }
    \\}
;

const Out = struct {
    fbo: [W * H * 4]u8 = undefined,
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

fn scene(eng: *engine.Engine, out: *Out) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
    var t: [1]u32 = undefined;
    c.genTextures(&t);
    c.bindTexture(g.TEXTURE_2D, t[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, t[0], 0);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, W, H);
    c.clearColor(0.25, 0.5, 0.75, 1);
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
    noErr(c, out);
    for (0..4) |m| {
        const x0: f32 = @floatFromInt(16 * (m % 2));
        const y0: f32 = @floatFromInt(16 * (m / 2));
        setI(c, uMode, @intCast(m));
        setF(c, uRect, &.{ x0, y0, x0 + 16, y0 + 16 });
        c.drawArrays(g.TRIANGLES, 0, 6, 1);
    }
    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &out.fbo);
    noErr(c, out);
    c.finish();
    program.useProgram(c, 0);
    program.deleteProgram(c, p);
    program.deleteShader(c, v);
    program.deleteShader(c, f);
}

fn px(o: []const u8, x: usize, y: usize) [4]u8 {
    return o[(y * W + x) * 4 ..][0..4].*;
}

fn check(o: *const Out) !void {
    if (o.log_len > 0) std.debug.print("{s}\n", .{o.log[0..o.log_len]});
    const E = std.testing.expectEqual;
    try E(@as(u32, 0), o.errors);
    for (0..16) |y| {
        for (0..16) |x| {
            // 0: steps of 1 both ways; the product's fwidth x + y
            const a = px(&o.fbo, x, y);
            const sum: f32 = (@as(f32, @floatFromInt(x)) + 0.5 + @as(f32, @floatFromInt(y)) + 0.5) / 32.0 * 255.0;
            try E(@as(u8, 255), a[0]);
            try E(@as(u8, 255), a[1]);
            try std.testing.expect(@abs(@as(f32, @floatFromInt(a[2])) - sum) <= 1.0);
            // 2: under the `if`: 0; after it: 1
            try E([4]u8{ 0, 255, 0, 255 }, px(&o.fbo, x, y + 16));
            // 3: discarded below p.y 3 (the clear color); above, 0
            const d = px(&o.fbo, x + 16, y + 16);
            try E(if (y < 3) [4]u8{ 64, 128, 191, 255 } else [4]u8{ 0, 0, 0, 255 }, d);
        }
    }
    // 1: the circle: inside opaque, outside clear, its edge in between
    try E(@as(u8, 255), px(&o.fbo, 16 + 8, 8)[3]);
    try E(@as(u8, 0), px(&o.fbo, 16, 0)[3]);
    var between: usize = 0;
    for (0..16) |y| {
        for (0..16) |x| {
            const a = px(&o.fbo, 16 + x, y)[3];
            if (a > 20 and a < 235) between += 1;
        }
    }
    try std.testing.expect(between >= 16);
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
        try std.testing.expect(eng_cpu.why_pipe == null);
        cpu_done = true;
    }
    return &out_cpu;
}

test "derivatives: quads, helper pixels and flow that is not uniform on the CPU" {
    try check(try cpuOut());
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "derivatives: on EmuDevice, the CPU's bytes" {
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

test "derivatives: on the emulated Adreno (ir3), the CPU's bytes" {
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
    try std.testing.expectEqualSlices(u8, &want.fbo, &out_a.fbo);
}

// ── The emulated RTX's 3D engine: quads of pixels, helpers among them ───────

const Nv3 = struct {
    const nvidia = @import("nvidia");
    var arena: [32 << 20]u8 align(4096) = undefined;
    var view: [32 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
    var engine3d: nvidia.emu3d.Engine = .{};
    var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
    var slabs: [16]engine.Slab = undefined;
    var eng: engine.Engine = undefined;
    var out: Out = .{};
};

test "derivatives: through the emulated RTX's 3D engine (pixel warps of quads), the CPU's picture where GL defines it" {
    const want = try cpuOut();
    Nv3.dev.init(&Nv3.arena, &Nv3.view, &Nv3.emu_work);
    Nv3.dev.withEngine(&Nv3.engine3d);
    Nv3.eng.init(.{ .dev = Nv3.dev.device(), .work = &Nv3.work, .cpu_work = &cpu_work, .slabs = &Nv3.slabs, .graphics = true });
    try std.testing.expect(Nv3.eng.graphics);
    try scene(&Nv3.eng, &Nv3.out);
    if (Nv3.dev.lastError()) |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("sm120_emu: {s}: {s}; the 3D engine: {s}\n", .{ @errorName(e), Nv3.dev.explain(&buf), Nv3.engine3d.why });
    }
    try std.testing.expect(Nv3.eng.why_pipe == null and !Nv3.eng.lost);
    try std.testing.expectEqual(@as(u64, 4), Nv3.eng.stats.graphics_draws);
    Nv3.eng.deinit();
    // (GL's undefined, not compared: mode 2's derivative under divergent
    // flow, and mode 3's after a discard (the hardware's discarded pixels
    // run on as helpers and the derivative is taken, the tile kernel
    // gives 0): there only the discarded rows, the clear colour)
    var bad: u32 = 0;
    for (0..H) |y| for (0..W) |x| {
        if (x < 16 and y >= 16) continue;
        if (x >= 16 and y >= 19) continue;
        const a = px(&want.fbo, x, y);
        const b = px(&Nv3.out.fbo, x, y);
        for (0..4) |c| {
            const d = @as(i32, a[c]) - @as(i32, b[c]);
            if (@abs(d) > 2) {
                if (bad < 4) std.debug.print("pixel ({d}, {d}): the CPU {any}, the 3D engine {any}\n", .{ x, y, a, b });
                bad += 1;
            }
        }
    };
    try std.testing.expectEqual(@as(u32, 0), bad);
}
