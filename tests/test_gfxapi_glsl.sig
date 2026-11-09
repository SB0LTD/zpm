//! gfxapi's GLSL programs drawn: two programs (GLSL ES 3.00 and 1.00),
//! compiled, linked and drawn through GL's shader and program objects,
//! three ways: on the CPU (KIR's interpreter), on EmuDevice (memory not
//! coherent), and on the emulated Adreno through Galaxy's calls (the
//! kernels, the shaders' code in them, compiled to ir3). Every run must
//! give the same bytes, and the pixels GLSL says.
//!
//! The 3.00 program has a mat4 uniform times a vec4, a uniform array
//! indexed by gl_VertexID / 3 (integer division by 3: the long one), a
//! swizzle assigned (gl_Position.xy +=), a flat int varying, a struct
//! uniform array read in a loop with an early return, a switch with a
//! default, a local array indexed by a varying, a function with out
//! parameters, for / do / while loops with continue and break, % by 7,
//! discard, ?: and mix/step/clamp. The 1.00 program, as WebGL 1 writes
//! them: attribute, varying, gl_FragColor, a bool uniform, a return from
//! main.

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

const vs_a: [:0]const u8 =
    \\#version 300 es
    \\in vec2 aPos;
    \\in vec4 aColor;
    \\uniform mat4 uProj;
    \\uniform float uScale;
    \\uniform vec2 uNudge[2];
    \\out vec4 vColor;
    \\out vec2 vPix;
    \\flat out int vSide;
    \\void main() {
    \\    vColor = aColor * uScale;
    \\    vPix = aPos;
    \\    vSide = gl_VertexID / 3;
    \\    gl_Position = uProj * vec4(aPos, 0.0, 1.0);
    \\    gl_Position.xy += uNudge[vSide];
    \\}
;

const fs_a: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\struct Band { vec4 color; float edge; };
    \\uniform Band uBands[2];
    \\uniform vec4 uTint[3];
    \\uniform int uMode;
    \\in vec4 vColor;
    \\in vec2 vPix;
    \\flat in int vSide;
    \\out vec4 oColor;
    \\
    \\float band(float y) {
    \\    for (int i = 0; i < 2; ++i) {
    \\        if (y < uBands[i].edge) return float(i);
    \\    }
    \\    return 2.0;
    \\}
    \\
    \\vec4 pick(int i) {
    \\    vec4 table[3] = vec4[3](uTint[0], uTint[1], uTint[2]);
    \\    return table[i];
    \\}
    \\
    \\void split(vec4 c, out vec3 rgb, out float a) {
    \\    rgb = c.rgb;
    \\    a = c.a;
    \\}
    \\
    \\void main() {
    \\    ivec2 p = ivec2(gl_FragCoord.xy);
    \\    if ((p.x + p.y) % 7 == 3) discard;
    \\    int b = int(band(vPix.y));
    \\    vec4 c;
    \\    switch (b) {
    \\        case 0: c = uBands[0].color; break;
    \\        case 1: c = uBands[1].color; break;
    \\        default: c = pick(vSide + 1);
    \\    }
    \\    float t = clamp(vPix.x / 32.0, 0.0, 1.0);
    \\    vec4 grad = mix(vColor, c, step(0.5, t));
    \\    vec3 rgb;
    \\    float al;
    \\    split(grad, rgb, al);
    \\    // loops: odd i summed (continue), a do-while, a while left by break
    \\    int n = 0;
    \\    for (int i = 0; i < 8; i++) {
    \\        if (i % 2 == 0) continue;
    \\        n += i;
    \\    }
    \\    int m = 0;
    \\    do { m += 2; } while (m < 9);
    \\    int w = 0;
    \\    while (true) { w++; if (w == 5) break; }
    \\    bool ok = n == 16 && m == 10 && w == 5;
    \\    oColor = (uMode == 1 && ok) ? vec4(rgb, al) : vec4(1.0, 0.0, 1.0, 1.0);
    \\}
;

const vs_b: [:0]const u8 =
    \\attribute vec2 position;
    \\uniform vec2 uOffset;
    \\varying vec2 vUv;
    \\void main() {
    \\    vUv = position / 32.0;
    \\    gl_Position = vec4((position + uOffset) / 16.0 - 1.0, 0.0, 1.0);
    \\}
;

const fs_b: [:0]const u8 =
    \\precision mediump float;
    \\varying vec2 vUv;
    \\uniform vec4 uColor;
    \\uniform bool uInvert;
    \\vec3 f(vec3 c) { return uInvert ? vec3(1.0) - c : c; }
    \\void main() {
    \\    vec3 c = f(uColor.rgb);
    \\    if (vUv.x > 0.75) {
    \\        gl_FragColor = vec4(c.bgr, 1.0);
    \\        return;
    \\    }
    \\    gl_FragColor = vec4(c, uColor.a);
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

fn shader(c: *gles.Context, kind: u32, src: [:0]const u8, out: *Out) u32 {
    const s = program.createShader(c, kind);
    const parts = [_]?[*]const u8{src.ptr};
    program.shaderSource(c, s, 1, &parts, null);
    program.compileShader(c, s);
    var ok: i32 = 0;
    program.getShaderiv(c, s, g.COMPILE_STATUS, &ok);
    if (ok != 1) {
        var len: i32 = 0;
        program.getShaderInfoLog(c, s, out.log.len, &len, &out.log);
        out.log_len = @intCast(len);
        out.errors += 1;
    }
    return s;
}

fn link(c: *gles.Context, vs: u32, fs: u32, out: *Out) u32 {
    const p = program.createProgram(c);
    program.attachShader(c, p, vs);
    program.attachShader(c, p, fs);
    program.bindAttribLocation(c, p, 0, "aPos");
    program.bindAttribLocation(c, p, 1, "aColor");
    program.linkProgram(c, p);
    var ok: i32 = 0;
    program.getProgramiv(c, p, g.LINK_STATUS, &ok);
    if (ok != 1) {
        var len: i32 = 0;
        program.getProgramInfoLog(c, p, out.log.len, &len, &out.log);
        out.log_len = @intCast(len);
        out.errors += 1;
    }
    return p;
}

fn loc(c: *gles.Context, p: u32, name: [*:0]const u8) i32 {
    return program.getUniformLocation(c, p, name);
}

fn setf(c: *gles.Context, l: i32, vals: []const f32) void {
    program.uniform(c, l, 1, @intCast(vals.len), .f, @ptrCast(vals.ptr));
}

fn seti(c: *gles.Context, l: i32, x: i32) void {
    const v = [_]i32{x};
    program.uniform(c, l, 1, 1, .i, @ptrCast(&v));
}

fn noErr(c: *gles.Context, out: *Out) void {
    if (c.getError() != g.NO_ERROR) out.errors += 1;
}

fn scene(eng: *engine.Engine, out: *Out) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
    // a framebuffer object
    var tex: [1]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(g.TEXTURE_2D, tex[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, W, H);
    c.clearColor(0, 0, 0, 0);
    c.clear(g.COLOR_BUFFER_BIT);
    var vao: [1]u32 = undefined;
    c.genVertexArrays(&vao);
    c.bindVertexArray(vao[0]);
    var bufs: [2]u32 = undefined;
    c.genBuffers(&bufs);
    noErr(c, out);

    // A: the 3.00 program over the whole framebuffer (two triangles:
    // below the diagonal, then above it)
    const va = shader(c, g.VERTEX_SHADER, vs_a, out);
    const fa = shader(c, g.FRAGMENT_SHADER, fs_a, out);
    const pa = link(c, va, fa, out);
    if (out.errors != 0) return;
    program.useProgram(c, pa);
    const proj = [16]f32{ 1.0 / 16.0, 0, 0, 0, 0, 1.0 / 16.0, 0, 0, 0, 0, 1, 0, -1, -1, 0, 1 };
    program.uniformMatrix(c, loc(c, pa, "uProj"), 1, false, 4, 4, @ptrCast(&proj));
    setf(c, loc(c, pa, "uScale"), &.{1});
    setf(c, loc(c, pa, "uBands[0].color"), &.{ 1, 0, 0, 1 });
    setf(c, loc(c, pa, "uBands[0].edge"), &.{10});
    setf(c, loc(c, pa, "uBands[1].color"), &.{ 0, 1, 0, 1 });
    setf(c, loc(c, pa, "uBands[1].edge"), &.{20});
    const tints = [_]f32{ 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1 };
    program.uniform(c, loc(c, pa, "uTint"), 3, 4, .f, @ptrCast(&tints));
    seti(c, loc(c, pa, "uMode"), 1);
    noErr(c, out);
    const col = [4]f32{ 0.5, 0.25, 1, 1 };
    const V6 = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32, a: f32 };
    const vv = struct {
        fn f(x: f32, y: f32, k: [4]f32) V6 {
            return .{ .x = x, .y = y, .r = k[0], .g = k[1], .b = k[2], .a = k[3] };
        }
    }.f;
    const verts = [_]V6{ vv(0, 0, col), vv(32, 0, col), vv(32, 32, col), vv(0, 0, col), vv(32, 32, col), vv(0, 32, col) };
    c.bindBuffer(g.ARRAY_BUFFER, bufs[0]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, g.STATIC_DRAW);
    c.vertexAttribPointer(0, 2, g.FLOAT, false, @sizeOf(V6), 0, false);
    c.vertexAttribPointer(1, 4, g.FLOAT, false, @sizeOf(V6), 8, false);
    c.enableVertexAttribArray(0, true);
    c.enableVertexAttribArray(1, true);
    c.drawArrays(g.TRIANGLES, 0, 6, 1);
    noErr(c, out);

    // B: the 1.00 program on a quad (16..32, 0..8)
    const vb = shader(c, g.VERTEX_SHADER, vs_b, out);
    const fb_ = shader(c, g.FRAGMENT_SHADER, fs_b, out);
    const pb = link(c, vb, fb_, out);
    if (out.errors != 0) return;
    program.useProgram(c, pb);
    setf(c, loc(c, pb, "uOffset"), &.{ 0, 0 });
    setf(c, loc(c, pb, "uColor"), &.{ 1, 0.5, 0, 1 });
    seti(c, loc(c, pb, "uInvert"), 1);
    const quad = [_]f32{ 16, 0, 32, 0, 32, 8, 16, 0, 32, 8, 16, 8 };
    c.bindBuffer(g.ARRAY_BUFFER, bufs[1]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, g.STATIC_DRAW);
    c.vertexAttribPointer(0, 2, g.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(1, false);
    c.drawArrays(g.TRIANGLES, 0, 6, 1);
    noErr(c, out);

    // C: the math program on the corner (0..4, 28..32): a bit per check
    const vc = shader(c, g.VERTEX_SHADER, vs_c, out);
    const fc = shader(c, g.FRAGMENT_SHADER, fs_c, out);
    const pc = link(c, vc, fc, out);
    if (out.errors != 0) return;
    program.useProgram(c, pc);
    seti(c, loc(c, pc, "uA"), 100);
    seti(c, loc(c, pc, "uB"), 7);
    const corner = [_]f32{ 0, 28, 4, 28, 4, 32, 0, 28, 4, 32, 0, 32 };
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(corner)), &corner, g.STATIC_DRAW);
    c.drawArrays(g.TRIANGLES, 0, 6, 1);
    noErr(c, out);

    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &out.fbo);
    noErr(c, out);
    c.finish();
    program.useProgram(c, 0);
    for ([_]u32{ pa, pb, pc }) |p| program.deleteProgram(c, p);
    for ([_]u32{ va, fa, vb, fb_, vc, fc }) |s| program.deleteShader(c, s);
}

const vs_c: [:0]const u8 =
    \\#version 300 es
    \\in vec2 aPos;
    \\void main() { gl_Position = vec4(aPos / 16.0 - 1.0, 0.0, 1.0); }
;

/// Each CHECK sets the next bit of m when it holds; the color is m's bytes.
const fs_c: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform int uA;
    \\uniform int uB;
    \\out vec4 oColor;
    \\struct S { vec2 v; float w; };
    \\#define CHECK(c) if (c) m |= bit; bit <<= 1;
    \\int find(int t) {
    \\    for (int i = 0; i < 4; i++) {
    \\        for (int j = 0; j < 4; j++) {
    \\            if (i * 4 + j == t) return i * 10 + j;
    \\        }
    \\    }
    \\    return -1;
    \\}
    \\void bump(inout int x) { x += 3; }
    \\bool near(float a, float b, float e) { return abs(a - b) <= e; }
    \\void main() {
    \\    int m = 0;
    \\    int bit = 1;
    \\    CHECK(inverse(mat2(2.0, 0.0, 0.0, 4.0)) == mat2(0.5, 0.0, 0.0, 0.25))
    \\    CHECK(determinant(mat3(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 1.0, 0.0, 4.0)) == 24.0)
    \\    CHECK(transpose(mat2(1.0, 2.0, 3.0, 4.0)) == mat2(1.0, 3.0, 2.0, 4.0))
    \\    S a = S(vec2(1.0, 2.0), 3.0);
    \\    S b = a;
    \\    b.v.x = 5.0;
    \\    CHECK(a.v.x == 1.0 && b.v.x == 5.0 && b.w == 3.0 && a != b)
    \\    float arr[4];
    \\    for (int i = 0; i < 4; i++) arr[i] = float(i * i);
    \\    int k2 = uA / 50;
    \\    CHECK(arr[k2] == 4.0 && arr[3] == 9.0)
    \\    CHECK(-7 / 2 == -3 && 1 << 4 == 16 && ~0 == -1 && (0xF0 & 0x3C) == 0x30)
    \\    CHECK(uA / uB == 14 && -uA / uB == -14 && uA % uB == 2 && uint(uA) / 7u == 14u)
    \\    CHECK(abs(sin(0.0)) < 1e-6 && near(cos(0.0), 1.0, 1e-4))
    \\    CHECK(near(pow(2.0, 10.0), 1024.0, 0.5) && sqrt(16.0) == 4.0)
    \\    CHECK(near(atan(1.0), 0.785398, 1e-3) && near(atan(-1.0, -1.0), -2.356194, 1e-3))
    \\    CHECK(near(exp(1.0), 2.718282, 1e-3) && near(log(2.718282), 1.0, 1e-3))
    \\    CHECK(length(vec2(3.0, 4.0)) == 5.0 && cross(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0)) == vec3(0.0, 0.0, 1.0))
    \\    CHECK(mod(7.5, 2.0) == 1.5 && fract(-0.25) == 0.75 && floor(-1.5) == -2.0 && sign(-3.0) == -1.0)
    \\    CHECK(smoothstep(0.0, 1.0, 0.5) == 0.5 && mix(0.0, 10.0, 0.25) == 2.5 && clamp(5, 0, 3) == 3)
    \\    CHECK(unpackHalf2x16(packHalf2x16(vec2(1.5, -0.25))) == vec2(1.5, -0.25) && packHalf2x16(vec2(1.0, 0.0)) == 0x3c00u)
    \\    CHECK(packUnorm2x16(vec2(1.0, 0.0)) == 0xffffu && unpackSnorm2x16(0x7fffu).x == 1.0)
    \\    CHECK(floatBitsToUint(1.0) == 0x3f800000u && intBitsToFloat(0x40000000) == 2.0)
    \\    int s = 0;
    \\    int q = (s == 0) ? (s = 5) : (s = 7);
    \\    CHECK(q == 5 && s == 5)
    \\    int z = 0;
    \\    bool bb = false && (++z > 0);
    \\    bool cc = true || (++z > 0);
    \\    CHECK(z == 0 && !bb && cc)
    \\    int y = 1;
    \\    bump(y);
    \\    CHECK(y == 4 && find(6) == 12 && find(15) == 33 && find(99) == -1)
    \\    int sw = 0;
    \\    switch (uB - 5) { case 1: sw += 1; case 2: sw += 2; case 3: sw += 4; break; default: sw += 8; }
    \\    CHECK(sw == 6)
    \\    int cnt = 0;
    \\    for (int i = 0; i < 4; i++) { switch (i) { case 1: continue; default: break; } cnt++; }
    \\    CHECK(cnt == 3)
    \\    CHECK(all(lessThan(vec3(1.0, 2.0, 3.0), vec3(2.0, 3.0, 4.0))) && any(equal(ivec2(1, 2), ivec2(0, 2))) && not(bvec2(true, false)) == bvec2(false, true))
    \\    CHECK(mat2(1.0, 2.0, 3.0, 4.0) * mat2(5.0, 6.0, 7.0, 8.0) == mat2(23.0, 34.0, 31.0, 46.0) && vec2(1.0, 1.0) * mat2(1.0, 2.0, 3.0, 4.0) == vec2(3.0, 7.0))
    \\    CHECK(mat3(mat2(2.0))[2][2] == 1.0 && vec4(ivec2(1, 2), 3, true) == vec4(1.0, 2.0, 3.0, 1.0))
    \\    CHECK(outerProduct(vec2(1.0, 2.0), vec3(3.0, 4.0, 5.0))[2][1] == 10.0)
    \\    CHECK(int(3.7) == 3 && int(-3.7) == -3 && float(7u) == 7.0 && !bool(0.0))
    \\    CHECK(isinf(1.0 / 0.0) && isnan(0.0 / 0.0) == true)
    \\    float arr2[4] = arr;
    \\    arr2[0] = 7.0;
    \\    CHECK(arr[0] == 0.0 && arr2[0] == 7.0)
    \\    int f2 = 0;
    \\    for (int i = 0; i < 10; i++) { if (i == 3) break; f2 += 1; }
    \\    CHECK(f2 == 3)
    \\    oColor = vec4(float(m & 255), float((m >> 8) & 255), float((m >> 16) & 255), float((m >> 24) & 255)) / 255.0;
    \\}
;

fn px(o: []const u8, x: usize, y: usize) [4]u8 {
    return o[(y * W + x) * 4 ..][0..4].*;
}

fn check(o: *const Out) !void {
    if (o.log_len > 0) std.debug.print("{s}\n", .{o.log[0..o.log_len]});
    try std.testing.expectEqual(@as(u32, 0), o.errors);
    const E = std.testing.expectEqual;
    // discarded: (x + y) % 7 == 3 keeps the clear color
    try E([4]u8{ 0, 0, 0, 0 }, px(&o.fbo, 1, 2));
    try E([4]u8{ 0, 0, 0, 0 }, px(&o.fbo, 30, 22));
    // band 0 (y < 10): the varying color left of x = 16, red right of it
    try E([4]u8{ 128, 64, 255, 255 }, px(&o.fbo, 5, 6));
    try E([4]u8{ 255, 0, 0, 255 }, px(&o.fbo, 20, 8));
    // band 1: green right of x = 16
    try E([4]u8{ 0, 255, 0, 255 }, px(&o.fbo, 20, 15));
    // band 2: uTint[vSide + 1]: blue below the diagonal (triangle 0),
    // yellow above it (triangle 1); the varying color left of x = 16
    try E([4]u8{ 0, 0, 255, 255 }, px(&o.fbo, 30, 23));
    try E([4]u8{ 255, 255, 0, 255 }, px(&o.fbo, 20, 28));
    try E([4]u8{ 128, 64, 255, 255 }, px(&o.fbo, 10, 25));
    // B over band 0: uColor inverted (0, .5, 1), its alpha; past
    // vUv.x = 0.75 the same reversed (bgr), opaque
    try E([4]u8{ 0, 128, 255, 255 }, px(&o.fbo, 20, 3));
    try E([4]u8{ 255, 128, 0, 255 }, px(&o.fbo, 28, 3));
    // C: all 30 checks held (m = 2^30 - 1); a failed one's bit names it
    const mc = px(&o.fbo, 1, 29);
    const mask = @as(u32, mc[0]) | @as(u32, mc[1]) << 8 | @as(u32, mc[2]) << 16 | @as(u32, mc[3]) << 24;
    if (mask != (1 << 30) - 1) std.debug.print("math checks failed: {b:0>30}\n", .{~mask & ((1 << 30) - 1)});
    try E(@as(u32, (1 << 30) - 1), mask);
    // nowhere magenta (the loops' sums held everywhere drawn)
    for (0..H) |y| {
        for (0..W) |x| try std.testing.expect(!std.mem.eql(u8, &px(&o.fbo, x, y), &[4]u8{ 255, 0, 255, 255 }));
    }
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

test "glsl draw: two programs on the CPU" {
    const o = try cpuOut();
    try check(o);
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "glsl draw: on EmuDevice, the CPU's bytes" {
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
    try std.testing.expect(eng_emu.stats.dispatches >= 3 * 2);
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

test "glsl draw: on the emulated Adreno (ir3), the CPU's bytes" {
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
    try std.testing.expect(eng_a.stats.dispatches >= 3 * 2);
    eng_a.deinit();
    a_gpu.close();
}

// ── What a context says of its use (report.Usage) ──────────────────────────

/// A program with two of WebRender's sampler names, drawn as WebRender
/// draws: a quad of six indices, once per instance.
const vs_w: [:0]const u8 =
    \\#version 300 es
    \\in vec2 aPos;
    \\in vec4 aColor;
    \\uniform mat4 uTransform;
    \\void main() { gl_Position = uTransform * vec4(aPos + aColor.xy, 0.0, 1.0); }
;

const fs_w: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D sColor0;
    \\uniform sampler2D sGpuCache;
    \\out vec4 oColor;
    \\void main() { oColor = texelFetch(sColor0, ivec2(0, 0), 0) + texelFetch(sGpuCache, ivec2(1, 1), 0); }
;

var fake_us: u64 = 0;
fn fakeClock() u64 {
    return fake_us;
}

var said: [4096]u8 = undefined;
var said_len: usize = 0;
fn hear(line: []const u8) void {
    const n = @min(line.len, said.len - said_len);
    @memcpy(said[said_len..][0..n], line[0..n]);
    said_len += n;
}

fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "usage: a context's draws, uploads and programs, said once in five seconds" {
    const report = gfxapi.report;
    said_len = 0;
    report.sink = &hear;
    defer report.sink = null;
    const real_clock = report.clock;
    report.clock = &fakeClock;
    defer report.clock = real_clock;
    fake_us = 50_000_000;

    var caps = gpu.interp_caps;
    caps.coherent = false;
    emu = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem, .cpu_work = &cpu_work });
    defer eng_emu.deinit();
    try std.testing.expect(eng_emu.onGpu());
    objs.init();
    const c = &ctx;
    c.init(&eng_emu, &objs);
    defer c.deinit();
    c.usage.id = 7;
    c.usage.es = 3;
    var out: Out = .{};

    var tex: [2]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(g.TEXTURE_2D, tex[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, c.checkFramebufferStatus(g.FRAMEBUFFER));
    c.viewportSet(0, 0, W, H);
    c.clearColor(0, 0, 0, 0);
    c.clear(g.COLOR_BUFFER_BIT);
    // the first flush begins the time counted: nothing is said
    c.flush();
    try std.testing.expectEqual(@as(usize, 0), said_len);

    // a program linked, a texture uploaded (16 x 16 RGBA8: 1 kB), one
    // indexed draw of three instances (six triangles)
    const vw = shader(c, g.VERTEX_SHADER, vs_w, &out);
    const fw = shader(c, g.FRAGMENT_SHADER, fs_w, &out);
    const pw = link(c, vw, fw, &out);
    if (out.log_len > 0) std.debug.print("{s}\n", .{out.log[0..out.log_len]});
    try std.testing.expectEqual(@as(u32, 0), out.errors);
    program.useProgram(c, pw);
    const proj = [16]f32{ 1.0 / 16.0, 0, 0, 0, 0, 1.0 / 16.0, 0, 0, 0, 0, 1, 0, -1, -1, 0, 1 };
    program.uniformMatrix(c, loc(c, pw, "uTransform"), 1, false, 4, 4, @ptrCast(&proj));
    c.bindTexture(g.TEXTURE_2D, tex[1]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, 16, 16);
    const texels: [16 * 16 * 4]u8 = @splat(0x40);
    c.texSubImage2D(g.TEXTURE_2D, 0, 0, 0, 16, 16, g.RGBA, g.UNSIGNED_BYTE, &texels);
    var vao: [1]u32 = undefined;
    c.genVertexArrays(&vao);
    c.bindVertexArray(vao[0]);
    var bufs: [3]u32 = undefined;
    c.genBuffers(&bufs);
    const quad = [_]f32{ 0, 0, 4, 0, 0, 4, 4, 4 };
    c.bindBuffer(g.ARRAY_BUFFER, bufs[0]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, g.STATIC_DRAW);
    c.vertexAttribPointer(0, 2, g.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(0, true);
    const shifts = [_]f32{ 0, 0, 0, 0, 8, 0, 0, 0, 16, 0, 0, 0 };
    c.bindBuffer(g.ARRAY_BUFFER, bufs[1]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(shifts)), &shifts, g.STATIC_DRAW);
    c.vertexAttribPointer(1, 4, g.FLOAT, false, 16, 0, false);
    c.enableVertexAttribArray(1, true);
    c.vertexAttribDivisor(1, 1);
    const idx = [_]u16{ 0, 1, 3, 0, 3, 2 };
    c.bindBuffer(g.ELEMENT_ARRAY_BUFFER, bufs[2]);
    c.bufferData(g.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, g.STATIC_DRAW);
    c.drawElements(g.TRIANGLES, 6, g.UNSIGNED_SHORT, 0, 3);
    try std.testing.expectEqual(g.NO_ERROR, c.getError());
    try std.testing.expect(eng_emu.why_pipe == null);
    // (drawn: the texel's 0x40 twice over, at the third instance's quad)
    var px4: [4]u8 = undefined;
    c.readPixels(17, 1, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &px4);
    try std.testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0x80 }, px4);

    // two seconds on, then four: nothing yet, however often it is asked
    fake_us += 2_000_000;
    c.flush();
    fake_us += 2_000_000;
    for (0..100) |_| c.finish();
    try std.testing.expectEqual(@as(usize, 0), said_len);
    // five and a half: the line
    fake_us += 1_500_000;
    c.finish();
    const line = said[0..said_len];
    std.debug.print("{s}", .{line});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try std.testing.expect(has(line, "]: context 7 (ES 3 asked) in 5.5 s on the GPU ("));
    try std.testing.expect(has(line, "): 0 swaps (0 ms in them); 1 draws (1 indexed, 3 instances, 6 triangles, 0 on the CPU); 1 uploads, 1 kB; programs: 1 linked, 1 WebRender's, 0 the layers compositor's, names seen: sColor0 sGpuCache; GPU: "));
    try std.testing.expect(!has(line, "GPU: 0 batches"));
    // at once again, and four seconds later: no second line
    c.finish();
    fake_us += 4_000_000;
    c.drawElements(g.TRIANGLES, 6, g.UNSIGNED_SHORT, 0, 2);
    c.finish();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said[0..said_len], "\n"));
    // a second and a bit later: the second line, of what was done since
    // the first (the program is still the context's one)
    fake_us += 1_200_000;
    c.flush();
    const both = said[0..said_len];
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, both, "\n"));
    try std.testing.expect(has(both[line.len..], " in 5.2 s on the GPU ("));
    try std.testing.expect(has(both[line.len..], "1 draws (1 indexed, 2 instances, 4 triangles, 0 on the CPU); 0 uploads, 0 kB; programs: 1 linked, 1 WebRender's"));
    // a stretch in which the context does nothing: nothing said
    fake_us += 30_000_000;
    c.finish();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, said[0..said_len], "\n"));

    program.useProgram(c, 0);
    program.deleteProgram(c, pw);
    program.deleteShader(c, vw);
    program.deleteShader(c, fw);
}
