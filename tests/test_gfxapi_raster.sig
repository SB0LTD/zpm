//! gfxapi's raster past triangles into one target: multisampling (2x, 4x,
//! 8x: each sample's coverage, depth and stencil, alpha to coverage, the
//! sample mask, resolves), points (gl_PointSize, gl_PointCoord), lines
//! (GL's and Vulkan's diamond-exit rule; multisampled lines as
//! rectangles), several colour targets in one pipeline, depth bias,
//! gl_FragDepth, clip distances, and the stencil tile kernel of a large
//! program on sm_120. Each scene runs on the CPU (KIR's interpreter) and on
//! the emulated RTX (kir_sm120's code in sm120_emu), the same bytes from
//! both, and the bytes a reference written here from the rules says:
//! coverage from exact edge functions at the sample positions, lines from
//! the diamond test in f64 with the ends nudged, points from the square.
//! The variants' kernels compile for the Adreno (ir3) too.

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const kir = gpu.kir;
const engine = gfxapi.engine;
const gles = gfxapi.gles;
const raster = gfxapi.raster;
const g = gfxapi.glenum;
const program = gfxapi.program;

const r = kir.r;
const f = kir.f;

// ── Engines: the CPU and the emulated RTX ──────────────────────────────────

var pool_mem: [16 << 20]u8 align(64) = undefined;
var cpu_work: [8 << 20]u8 align(64) = undefined;
/// the CPU's kernels kept between draws (every CPU test draws with them)
var cpu_kernels: [1 << 15]kir.Inst = undefined;

const Rtx = struct {
    const nvidia = @import("nvidia");
    var arena: [96 << 20]u8 align(4096) = undefined;
    var view: [96 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
    var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
    var slabs: [16]engine.Slab = undefined;
};

const Where = enum { cpu, rtx };

fn open(e: *engine.Engine, w: Where) !void {
    switch (w) {
        .cpu => e.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work, .cpu_kernels = &cpu_kernels }),
        .rtx => {
            Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
            e.init(.{ .dev = Rtx.dev.device(), .work = &Rtx.work, .cpu_work = &cpu_work, .cpu_kernels = &cpu_kernels, .slabs = &Rtx.slabs });
            try std.testing.expect(e.onGpu());
        },
    }
}

const all_pipes = [_]*raster.Pipeline{ &colored, &sized, &multi, &deep, &clipped };

/// The engine closed, its pipelines' programs let go first (the next
/// session's engine is at the same address).
fn close(e: *engine.Engine) void {
    for (all_pipes) |p| e.unloadPipeline(p);
    e.deinit();
}

/// The engine kept every draw on the GPU (RTX) and lost nothing.
fn clean(e: *engine.Engine, w: Where) !void {
    if (e.why_pipe) |err| std.debug.print("raster test: a kernel was refused: {s}\n", .{@errorName(err)});
    if (w == .rtx) {
        if (Rtx.dev.lastError()) |err| {
            var buf: [512]u8 = undefined;
            std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(err), Rtx.dev.explain(&buf) });
        }
        try std.testing.expectEqual(@as(u64, 0), e.stats.cpu_draws);
    }
    try std.testing.expect(e.why_pipe == null);
    try std.testing.expect(!e.lost);
}

// ── Shaders (KIR emitters) ─────────────────────────────────────────────────

fn fl(k: *kir.Kernel, x: kir.V) kir.V {
    return k.mov(.f32, r(x));
}

/// attribute 0: position (clip space), 1: color; 2.x: point size, 2.y: a
/// clip distance; varyings: the color
const Sh = struct {
    fn vertex(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        for (0..4) |c| io.position[c] = fl(k, io.attr[0][c]);
        for (0..4) |c| io.varying[c] = fl(k, io.attr[1][c]);
    }
    fn vertexSized(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        vertex(null, k, io);
        io.point_size = fl(k, io.attr[2][0]);
    }
    fn vertexClipped(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        vertex(null, k, io);
        io.clip[0] = fl(k, io.attr[2][1]);
    }
    fn fragment(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        _ = k;
        for (0..4) |c| io.color[c] = io.varying[c];
    }
    /// gl_PointCoord as red and green
    fn sprite(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        io.color = .{ io.point_coord[0], io.point_coord[1], k.mov(.f32, f(0)), k.mov(.f32, f(1)) };
    }
    /// output 0 the color, 1 its channels turned (b, r, g, a), 2 its
    /// green alone, 3 the color halved
    fn targets(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        for (0..4) |c| io.color[c] = io.varying[c];
        io.colors[1] = .{ io.varying[2], io.varying[0], io.varying[1], io.varying[3] };
        io.colors[2] = .{ io.varying[1], k.mov(.f32, f(0)), k.mov(.f32, f(0)), k.mov(.f32, f(1)) };
        for (0..4) |c| io.colors[3][c] = k.op2(.fmul, .f32, r(io.varying[c]), f(0.5));
    }
    /// gl_FragDepth: the color's alpha
    fn depth(_: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        fragment(null, k, io);
        io.depth = io.varying[3];
    }
};

var colored = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .vertex = Sh.vertex, .fragment = Sh.fragment });
var sized = raster.Pipeline.init(.{ .attrs = 3, .varyings = 4, .point_size = true, .point_coord = true, .vertex = Sh.vertexSized, .fragment = Sh.sprite });
var multi = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .vertex = Sh.vertex, .fragment = Sh.targets });
var deep = raster.Pipeline.init(.{ .attrs = 2, .varyings = 4, .frag_depth = true, .vertex = Sh.vertex, .fragment = Sh.depth });
var clipped = raster.Pipeline.init(.{ .attrs = 3, .varyings = 4, .clips = 1, .vertex = Sh.vertexClipped, .fragment = Sh.fragment });

// ── Scenes ─────────────────────────────────────────────────────────────────

const W = 32;
const H = 32;

const Vert = extern struct { x: f32, y: f32, z: f32, w: f32, r: f32, g: f32, b: f32, a: f32, s: f32 = 1, c: f32 = 0 };

/// A vertex at window (x, y) (pixels; multiples of 1/16 stay exact).
fn v(x: f32, y: f32, z: f32, col: [4]f32) Vert {
    return .{ .x = (x - W / 2) / (W / 2), .y = (y - H / 2) / (H / 2), .z = z, .w = 1, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
}

fn vbuf(e: *engine.Engine, verts: []const Vert) !engine.Image {
    var b = e.newBuffer(verts.len * @sizeOf(Vert)) orelse return error.OutOfMemory;
    e.writeBytes(&b, 0, std.mem.sliceAsBytes(verts));
    return b;
}

fn draw0(pipe: *const raster.Pipeline, color: *engine.Image, vb: *engine.Image, n: usize, topo: raster.Topology) raster.Draw {
    var d = raster.Draw{ .pipe = pipe, .color = color, .count = @intCast(n), .topology = topo };
    d.rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H };
    d.center = .{ W / 2, H / 2 };
    d.half = .{ W / 2, H / 2 };
    d.attrs[0] = .{ .buf = vb, .offset = 0, .stride = @sizeOf(Vert), .comps = 4 };
    d.attrs[1] = .{ .buf = vb, .offset = 16, .stride = @sizeOf(Vert), .comps = 4 };
    d.attrs[2] = .{ .buf = vb, .offset = 32, .stride = @sizeOf(Vert), .comps = 2 };
    return d;
}

fn words(e: *engine.Engine, img: *engine.Image) []const u32 {
    const b = e.hostView(img, 0, img.buf.cpu.len);
    return @alignCast(std.mem.bytesAsSlice(u32, b[0 .. @as(usize, img.stride) * img.height]));
}

/// The ones, quarter-transparent white (additive: a pixel's count of
/// draws in each channel's steps of 1/4... 64 a draw)
const add_blend = raster.Blend{ .src_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .src_a = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } } };

// ── The reference: coverage by the rules ───────────────────────────────────

/// Whether sample point (sx, sy) (1/16 pixel) is in triangle t (1/16
/// pixel), GL's tie rule: on an edge, in when A > 0 or A == 0 and B > 0.
fn inTri(t: [3][2]i64, sx: i64, sy: i64) bool {
    var p = t;
    const area = (p[1][0] - p[0][0]) * (p[2][1] - p[0][1]) - (p[2][0] - p[0][0]) * (p[1][1] - p[0][1]);
    if (area == 0) return false;
    if (area < 0) std.mem.swap([2]i64, &p[1], &p[2]);
    for (0..3) |e| {
        const a = p[e];
        const b = p[(e + 1) % 3];
        const A = a[1] - b[1];
        const B = b[0] - a[0];
        const bias: i64 = if (A > 0 or (A == 0 and B > 0)) 0 else -1;
        if (A * (sx - a[0]) + B * (sy - a[1]) + bias < 0) return false;
    }
    return true;
}

fn sub16(x: f32) i64 {
    return @intFromFloat(@round(x * 16));
}

/// GL's diamond-exit rule, as the specs put it, in f64: the ends nudged by
/// (1e-6, 1e-9) pixel; the line from a to b makes pixel (px, py) when it
/// meets the open diamond |x - cx| + |y - cy| < 1/2 and b is not in it.
fn lineMakes(ax: f64, ay: f64, bx: f64, by: f64, px: i64, py: i64) bool {
    const e1 = 1e-6;
    const e2 = 1e-9;
    const a = [2]f64{ ax + e1, ay + e2 };
    const b = [2]f64{ bx + e1, by + e2 };
    const cx = @as(f64, @floatFromInt(px)) + 0.5;
    const cy = @as(f64, @floatFromInt(py)) + 0.5;
    const uc = cx + cy;
    const vc = cx - cy;
    const ua = a[0] + a[1];
    const ub = b[0] + b[1];
    const va = a[0] - a[1];
    const vb = b[0] - b[1];
    if (@max(ua, ub) <= uc - 0.5 or @min(ua, ub) >= uc + 0.5) return false;
    if (@max(va, vb) <= vc - 0.5 or @min(va, vb) >= vc + 0.5) return false;
    const gOf = struct {
        fn f_(p: [2]f64, q: [2]f64, x: f64, y: f64) f64 {
            return (x - p[0]) * (q[1] - p[1]) - (y - p[1]) * (q[0] - p[0]);
        }
    }.f_;
    const corners = [4][2]f64{ .{ cx + 0.5, cy }, .{ cx - 0.5, cy }, .{ cx, cy + 0.5 }, .{ cx, cy - 0.5 } };
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (corners) |c| {
        const gc = gOf(a, b, c[0], c[1]);
        lo = @min(lo, gc);
        hi = @max(hi, gc);
    }
    if (!(lo < 0 and hi > 0)) return false;
    const b_in = @abs(ub - uc) < 0.5 and @abs(vb - vc) < 0.5;
    return !b_in;
}

// ── Multisampling ──────────────────────────────────────────────────────────

const RED = [4]f32{ 1, 0, 0, 1 };
const QUARTER = [4]f32{ 0.25, 0.25, 0.25, 0.25 };

/// Two triangles sharing an edge, off the grid, added (a sample covered by
/// both would show it), then resolved: every sample against inTri at the
/// sample positions, the resolve against each pixel's samples averaged.
fn msaaCoverage(e: *engine.Engine, ns: usize) !void {
    const tri = [2][3][2]f32{
        .{ .{ 3.25, 2.5 }, .{ 27.0625, 6.75 }, .{ 9.5, 29.1875 } },
        .{ .{ 27.0625, 6.75 }, .{ 30.5, 28.0 }, .{ 9.5, 29.1875 } },
    };
    var verts: [6]Vert = undefined;
    for (tri, 0..) |t, ti| {
        for (t, 0..) |p, j| verts[ti * 3 + j] = v(p[0], p[1], 0.5, QUARTER);
    }
    var vb = try vbuf(e, &verts);
    defer e.freeImage(&vb);
    var img = e.newImageSamples(W, H, .rgba8, @intCast(ns)) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    e.fill(&img, img.bounds(), 0, 0);
    var d = draw0(&colored, &img, &vb, 6, .triangles);
    d.blend = add_blend;
    try std.testing.expect(e.draw(&d));
    var res = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&res);
    try std.testing.expect(e.resolve(&img, &res, img.bounds()));
    const px = words(e, &img);
    const out = words(e, &res);
    const pos = raster.samplePositions(@intCast(ns));
    var t16: [2][3][2]i64 = undefined;
    for (tri, 0..) |t, ti| {
        for (t, 0..) |p, j| t16[ti][j] = .{ sub16(p[0]), sub16(p[1]) };
    }
    var mixed: usize = 0;
    for (0..H) |y| {
        for (0..W) |x| {
            var sum = [4]u32{ 0, 0, 0, 0 };
            var n_in: usize = 0;
            for (pos, 0..) |sp, s| {
                const sx: i64 = @as(i64, @intCast(x)) * 16 + sp[0];
                const sy: i64 = @as(i64, @intCast(y)) * 16 + sp[1];
                const hits = @as(u32, @intFromBool(inTri(t16[0], sx, sy))) + @intFromBool(inTri(t16[1], sx, sy));
                // (64 a quarter: no sample twice)
                const want: u32 = if (hits == 0) 0 else 0x4040_4040;
                try std.testing.expect(hits <= 1);
                const got = px[y * W * ns + x * ns + s];
                if (got != want) {
                    std.debug.print("{d}x: pixel ({d}, {d}) sample {d}: 0x{x}, want 0x{x}\n", .{ ns, x, y, s, got, want });
                    for (0..ns) |q| {
                        const qx: i64 = @as(i64, @intCast(x)) * 16 + pos[q][0];
                        const qy: i64 = @as(i64, @intCast(y)) * 16 + pos[q][1];
                        std.debug.print("  sample {d} at ({d}, {d}): 0x{x} in {}\n", .{ q, qx, qy, px[y * W * ns + x * ns + q], inTri(t16[0], qx, qy) or inTri(t16[1], qx, qy) });
                    }
                    return error.Coverage;
                }
                n_in += hits;
                for (0..4) |c| sum[c] += (got >> @intCast(8 * c)) & 0xff;
            }
            if (n_in != 0 and n_in != pos.len) mixed += 1;
            var want_r: u32 = 0;
            for (0..4) |c| want_r |= ((sum[c] + @as(u32, @intCast(ns / 2))) >> std.math.log2_int(u32, @intCast(ns))) << @intCast(8 * c);
            try std.testing.expectEqual(want_r, out[y * W + x]);
        }
    }
    // (the edges cut pixels)
    try std.testing.expect(mixed > 20);
}

/// Two triangles crossing in depth (a sample's own depth decides), alpha
/// to coverage at 1/2, the sample mask, a stencil written per sample.
fn msaaDepth(e: *engine.Engine, ns: usize, out: []u32) !void {
    const sloped = [_]Vert{ v(1, 1, -0.9, .{ 0, 1, 0, 1 }), v(31, 1, 0.9, .{ 0, 1, 0, 1 }), v(16, 31, 0.0, .{ 0, 1, 0, 1 }) };
    const level = [_]Vert{ v(2, 30, 0.1, .{ 0, 0, 1, 1 }), v(30, 30, 0.1, .{ 0, 0, 1, 1 }), v(16, 2, 0.1, .{ 0, 0, 1, 1 }) };
    const half = [_]Vert{ v(0, 0, -0.5, .{ 1, 1, 1, 0.5 }), v(32, 0, -0.5, .{ 1, 1, 1, 0.5 }), v(32, 8, -0.5, .{ 1, 1, 1, 0.5 }), v(0, 0, -0.5, .{ 1, 1, 1, 0.5 }), v(32, 8, -0.5, .{ 1, 1, 1, 0.5 }), v(0, 8, -0.5, .{ 1, 1, 1, 0.5 }) };
    var all: [12]Vert = undefined;
    @memcpy(all[0..3], &sloped);
    @memcpy(all[3..6], &level);
    @memcpy(all[6..12], &half);
    var vb = try vbuf(e, &all);
    defer e.freeImage(&vb);
    var img = e.newImageSamples(W, H, .rgba8, @intCast(ns)) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    var ds = e.newImageSamples(W, H, .d24s8, @intCast(ns)) orelse return error.OutOfMemory;
    defer e.freeImage(&ds);
    e.fill(&img, img.bounds(), 0xff00_0000, 0);
    e.fill(&ds, ds.bounds(), 0x00ff_ffff, 0);
    var d = draw0(&colored, &img, &vb, 3, .triangles);
    d.depth = &ds;
    d.depth_test = true;
    d.depth_write = true;
    d.stencil = &ds;
    d.stencil_front = .{ .func = 7, .reference = 1, .pass = .incr };
    d.stencil_back = d.stencil_front;
    try std.testing.expect(e.draw(&d));
    d.attrs[0].offset = 3 * @sizeOf(Vert);
    d.attrs[1].offset = 3 * @sizeOf(Vert) + 16;
    try std.testing.expect(e.draw(&d));
    // alpha to coverage (alpha 1/2: half the samples) under a mask
    d.attrs[0].offset = 6 * @sizeOf(Vert);
    d.attrs[1].offset = 6 * @sizeOf(Vert) + 16;
    d.count = 6;
    d.alpha_to_coverage = true;
    d.sample_mask = 0b1111_1101;
    try std.testing.expect(e.draw(&d));
    const px = words(e, &img);
    const dw = words(e, &ds);
    @memcpy(out[0 .. W * H * ns], px[0 .. W * H * ns]);
    @memcpy(out[W * H * ns ..][0 .. W * H * ns], dw[0 .. W * H * ns]);
    // the bottom rows, left of the triangles: samples 0 .. ns/2 - 1 but
    // sample 1 white (alpha to coverage's half, the mask's hole)
    for (0..ns) |s| {
        const want_white = s < ns / 2 and s != 1;
        const got = px[5 * W * ns + 0 * ns + s];
        try std.testing.expectEqual(want_white, got == 0x80ff_ffff);
    }
    // the triangles cross: pixels with green and blue samples both
    var crossed: usize = 0;
    for (0..W * H) |p| {
        var green = false;
        var blue = false;
        for (0..ns) |s| {
            green = green or px[p * ns + s] == 0xff00_ff00;
            blue = blue or px[p * ns + s] == 0xffff_0000;
        }
        if (green and blue) crossed += 1;
    }
    try std.testing.expect(crossed > 0);
}

// ── Points ─────────────────────────────────────────────────────────────────

const Point = struct { x: f32, y: f32, size: f32 };
const points = [_]Point{
    .{ .x = 4, .y = 4, .size = 4 },
    .{ .x = 12.5, .y = 5.5, .size = 1 },
    .{ .x = 20, .y = 6, .size = 8 },
    .{ .x = 6.5, .y = 20.5, .size = 3 },
    .{ .x = 22, .y = 22, .size = 2 },
    .{ .x = 31.5, .y = 16, .size = 4 },
};

fn pointScene(e: *engine.Engine, ns: usize, out: []u32) !void {
    var verts: [points.len]Vert = undefined;
    for (points, 0..) |p, j| {
        verts[j] = v(p.x, p.y, 0, .{ 1, 1, 1, 1 });
        verts[j].s = p.size;
    }
    var vb = try vbuf(e, &verts);
    defer e.freeImage(&vb);
    var img = e.newImageSamples(W, H, .rgba8, @intCast(ns)) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    e.fill(&img, img.bounds(), 0, 0);
    var d = draw0(&sized, &img, &vb, points.len, .points);
    try std.testing.expect(e.draw(&d));
    const px = words(e, &img);
    @memcpy(out[0 .. W * H * ns], px[0 .. W * H * ns]);
    if (ns != 1) return;
    // the squares, half-open; gl_PointCoord across each
    for (0..H) |y| {
        for (0..W) |x| {
            var want: u32 = 0;
            const cx: i64 = @as(i64, @intCast(x)) * 16 + 8;
            const cy: i64 = @as(i64, @intCast(y)) * 16 + 8;
            for (points) |p| {
                const h: i64 = @intFromFloat(@round(p.size * 8));
                const x0 = sub16(p.x) - h;
                const y0 = sub16(p.y) - h;
                if (cx < x0 or cx >= x0 + 2 * h or cy < y0 or cy >= y0 + 2 * h) continue;
                // (gl_PointCoord's planes as setup makes them, from the
                // sprite's first corner, each step an f32 operation)
                const X = @as(f32, @floatFromInt(x)) + 0.5;
                const Y = @as(f32, @floatFromInt(y)) + 0.5;
                const fx0 = @as(f32, @floatFromInt(x0)) * (1.0 / 16.0);
                const fy0 = @as(f32, @floatFromInt(y0)) * (1.0 / 16.0);
                const inv = 1 / p.size;
                const pcx = @as(f32, @floatFromInt(sub16(p.x))) * (1.0 / 16.0);
                const pcy = @as(f32, @floatFromInt(sub16(p.y))) * (1.0 / 16.0);
                const s0 = 0.5 + (fx0 - pcx) * inv;
                const t0 = 0.5 - (fy0 - pcy) * inv;
                const s = (s0 + inv * (X - fx0)) + 0 * (Y - fy0);
                const t_ = (t0 + 0 * (X - fx0)) + -inv * (Y - fy0);
                const b8 = struct {
                    // (the kernel's: times 255 in f32, to nearest even)
                    fn f_(c: f32) u32 {
                        const xv: f32 = std.math.clamp(c, 0, 1) * 255;
                        const fv = @floor(xv);
                        const n: u32 = @intFromFloat(fv);
                        if (xv - fv > 0.5) return n + 1;
                        if (xv - fv < 0.5) return n;
                        return n + (n & 1);
                    }
                }.f_;
                want = 0xff00_0000 | b8(t_) << 8 | b8(s);
            }
            const got = px[y * W + x];
            if (got != want) {
                std.debug.print("point pixel ({d}, {d}): 0x{x}, want 0x{x}\n", .{ x, y, got, want });
                return error.Points;
            }
        }
    }
}

// ── Lines ──────────────────────────────────────────────────────────────────

const Seg = [4]f32;
const segs = [_]Seg{
    // level and upright, on pixel centers and on the edges between rows
    .{ 1.5, 2.5, 9.5, 2.5 },   .{ 1.5, 4.0, 9.5, 4.0 },     .{ 9.5, 6.0, 1.5, 6.0 },
    .{ 12.0, 1.5, 12.0, 9.5 }, .{ 14.0, 9.5, 14.0, 1.5 },   .{ 16.5, 1.5, 16.5, 9.25 },
    // diagonals through centers, through corners, both ways
    .{ 1.5, 10.5, 9.5, 18.5 }, .{ 11.0, 10.0, 19.0, 18.0 }, .{ 28.0, 10.0, 20.0, 18.0 },
    .{ 9.5, 28.5, 1.5, 20.5 },
    // shallow and steep, off the grid
    .{ 2.25, 29.0625, 30.75, 24.3125 }, .{ 21.0625, 19.5, 23.9375, 30.875 }, .{ 30.6875, 1.125, 25.0, 9.9375 },
    // short: inside one pixel, one pixel's diamond edge to the next
    .{ 26.25, 12.25, 26.75, 12.5 },     .{ 27.5, 14.0, 28.5, 14.0 },
};

fn lineScene(e: *engine.Engine, ns: usize, out: []u32) !void {
    var verts: [2 * segs.len]Vert = undefined;
    for (segs, 0..) |s, j| {
        verts[2 * j] = v(s[0], s[1], 0, QUARTER);
        verts[2 * j + 1] = v(s[2], s[3], 0, QUARTER);
    }
    var vb = try vbuf(e, &verts);
    defer e.freeImage(&vb);
    var img = e.newImageSamples(W, H, .rgba8, @intCast(ns)) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    e.fill(&img, img.bounds(), 0, 0);
    var d = draw0(&colored, &img, &vb, verts.len, .lines);
    d.blend = add_blend;
    try std.testing.expect(e.draw(&d));
    const px = words(e, &img);
    @memcpy(out[0 .. W * H * ns], px[0 .. W * H * ns]);
    if (ns != 1) {
        // a rectangle a pixel wide (square ends): the level line at 2.5,
        // rows 2's samples left of the upright lines, by the two triangles
        const pos = raster.samplePositions(@intCast(ns));
        const a1 = [2]i64{ 24, 48 };
        const a2 = [2]i64{ 24, 32 };
        const b1 = [2]i64{ 152, 48 };
        const b2 = [2]i64{ 152, 32 };
        for (0..11) |x| {
            for (pos, 0..) |sp, s| {
                const sx: i64 = @as(i64, @intCast(x)) * 16 + sp[0];
                const sy: i64 = 2 * 16 + @as(i64, sp[1]);
                const in = inTri(.{ a1, a2, b2 }, sx, sy) or inTri(.{ a1, b2, b1 }, sx, sy);
                const px_ = px[2 * W * ns + x * ns + s];
                try std.testing.expectEqual(in, px_ == 0x4040_4040);
            }
        }
        return;
    }
    var made: usize = 0;
    for (0..H) |y| {
        for (0..W) |x| {
            var n: u32 = 0;
            for (segs) |s| n += @intFromBool(lineMakes(s[0], s[1], s[2], s[3], @intCast(x), @intCast(y)));
            const want: u32 = n * 0x4040_4040;
            const got = px[y * W + x];
            if (got != want) {
                std.debug.print("line pixel ({d}, {d}): 0x{x}, want 0x{x}\n", .{ x, y, got, want });
                return error.Lines;
            }
            made += n;
        }
    }
    try std.testing.expect(made > 100);
}

/// A strip and a loop: the vertices they share drawn once (the diamond
/// exit leaves a line's end to the next).
fn stripScene(e: *engine.Engine, out: []u32) !void {
    const pts = [_][2]f32{ .{ 2.5, 2.5 }, .{ 12.5, 4.5 }, .{ 20.5, 14.5 }, .{ 8.5, 22.5 }, .{ 3.0, 12.0 } };
    var verts: [pts.len]Vert = undefined;
    for (pts, 0..) |p, j| verts[j] = v(p[0], p[1], 0, QUARTER);
    var vb = try vbuf(e, &verts);
    defer e.freeImage(&vb);
    for ([_]raster.Topology{ .line_strip, .line_loop }, 0..) |topo, ti| {
        var img = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
        defer e.freeImage(&img);
        e.fill(&img, img.bounds(), 0, 0);
        var d = draw0(&colored, &img, &vb, pts.len, topo);
        d.blend = add_blend;
        try std.testing.expect(e.draw(&d));
        const px = words(e, &img);
        @memcpy(out[ti * W * H ..][0 .. W * H], px[0 .. W * H]);
        const nseg = if (topo == .line_loop) pts.len else pts.len - 1;
        for (0..H) |y| {
            for (0..W) |x| {
                var n: u32 = 0;
                for (0..nseg) |j| {
                    const a = pts[j];
                    const b = pts[(j + 1) % pts.len];
                    n += @intFromBool(lineMakes(a[0], a[1], b[0], b[1], @intCast(x), @intCast(y)));
                }
                try std.testing.expectEqual(n * 0x4040_4040, px[y * W + x]);
            }
        }
    }
}

// ── Several targets, depth bias, gl_FragDepth, clip distances ──────────────

/// Four targets of three formats from one pipeline: output i into target
/// i, a colour mask on target 3 and blending on target 1 only.
fn targetScene(e: *engine.Engine, ns: usize, out: []u32) !void {
    const col = [4]f32{ 1, 0.5, 0.25, 1 };
    const verts = [_]Vert{ v(0, 0, 0, col), v(32, 0, 0, col), v(32, 32, 0, col), v(0, 0, 0, col), v(32, 32, 0, col), v(0, 32, 0, col) };
    var vb = try vbuf(e, &verts);
    defer e.freeImage(&vb);
    const fmts = [_]engine.Format{ .rgba8, .bgra8, .r8, .rgba8 };
    var imgs: [4]engine.Image = undefined;
    for (&imgs, fmts) |*img, fm| {
        img.* = e.newImageSamples(W, H, fm, @intCast(ns)) orelse return error.OutOfMemory;
        e.fill(img, img.bounds(), if (fm == .r8) 0x10 else 0x1020_3040, 0);
    }
    defer for (&imgs) |*img| e.freeImage(img);
    var d = draw0(&multi, &imgs[0], &vb, 6, .triangles);
    // blending: dst + src (target 1 only)
    d.blend = .{ .src_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .src_a = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } } };
    d.targets[1] = .{ .img = &imgs[1], .blend = true };
    d.targets[2] = .{ .img = &imgs[2], .blend = false };
    // (target 3 keeps its red)
    d.targets[3] = .{ .img = &imgs[3], .keep = 0x0000_00ff, .blend = false };
    // (target 0 does not blend: its blend word off)
    var d0 = d;
    d0.targets[0] = null;
    _ = &d0;
    d.blend = null;
    for (&d.targets) |*t| {
        if (t.*) |*x| x.blend = false;
    }
    try std.testing.expect(e.draw(&d));
    // then blending into target 1 alone (target 0 as before: blend off)
    var d2 = draw0(&multi, &imgs[0], &vb, 6, .triangles);
    d2.color_off = true;
    d2.targets[1] = .{ .img = &imgs[1], .blend = true };
    d2.blend = .{ .src_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .dst_rgb = .{ .c = .{ 1, 1, 1, 1 } }, .src_a = .{ .c = .{ 1, 1, 1, 1 } }, .dst_a = .{ .c = .{ 1, 1, 1, 1 } } };
    try std.testing.expect(e.draw(&d2));
    // (1, .5, .25, 1): 255, 128, 64, 255
    const want = [4]u32{
        0xff40_80ff,
        // BGRA8 bytes b, g, r, a of (r, g, b, a) = (.25, 1, .5, 1), added
        // to itself: (.5, 1, 1, 1)
        0xff80_ffff,
        // R8: green
        0x80,
        // halved, red kept (0x40 of the clear)
        0x8020_4040,
    };
    for (&imgs, 0..) |*img, ti| {
        const bytes = e.hostView(img, 0, img.buf.cpu.len);
        for (0..H) |y| {
            for (0..W * ns) |xs| {
                const got: u32 = switch (fmts[ti]) {
                    .r8 => bytes[y * img.stride + xs],
                    else => std.mem.readInt(u32, bytes[y * img.stride + 4 * xs ..][0..4], .little),
                };
                if (got != want[ti]) {
                    std.debug.print("target {d} ({d}x) at ({d}, {d}): 0x{x}, want 0x{x}\n", .{ ti, ns, xs, y, got, want[ti] });
                    return error.Targets;
                }
            }
        }
        out[ti] = std.hash.Crc32.hash(bytes[0 .. img.stride * img.height]);
    }
}

/// Depth bias (units and slope), gl_FragDepth, a clip distance.
fn depthScene(e: *engine.Engine, out: []u32) !void {
    const col = [4]f32{ 0, 1, 0, 1 };
    const quad = [_]Vert{ v(0, 0, 0, col), v(32, 0, 0, col), v(32, 32, 0, col), v(0, 0, 0, col), v(32, 32, 0, col), v(0, 32, 0, col) };
    var vb = try vbuf(e, &quad);
    defer e.freeImage(&vb);
    var img = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&img);
    var ds = e.newImage(W, H, .d24s8) orelse return error.OutOfMemory;
    defer e.freeImage(&ds);
    e.fill(&img, img.bounds(), 0, 0);
    // the depth at 1/2 (z 0 through the default range)
    e.fill(&ds, ds.bounds(), 8388608, 0);
    var d = draw0(&colored, &img, &vb, 6, .triangles);
    d.depth = &ds;
    d.depth_test = true;
    // LESS: the same depth fails; two units nearer passes
    d.rect = .{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 32 };
    try std.testing.expect(e.draw(&d));
    d.rect = .{ .x0 = 16, .y0 = 0, .x1 = 32, .y1 = 32 };
    d.bias_units = -2;
    try std.testing.expect(e.draw(&d));
    const px = words(e, &img);
    try std.testing.expectEqual(@as(u32, 0), px[5 * W + 3]);
    try std.testing.expectEqual(@as(u32, 0xff00_ff00), px[5 * W + 20]);
    // gl_FragDepth (alpha: 1/4) written where the test passes
    const q = [4]f32{ 1, 0, 0, 0.25 };
    const qq = [_]Vert{ v(0, 0, 0.9, q), v(32, 0, 0.9, q), v(32, 32, 0.9, q), v(0, 0, 0.9, q), v(32, 32, 0.9, q), v(0, 32, 0.9, q) };
    var vb2 = try vbuf(e, &qq);
    defer e.freeImage(&vb2);
    var d2 = draw0(&deep, &img, &vb2, 6, .triangles);
    d2.depth = &ds;
    d2.depth_test = true;
    d2.depth_write = true;
    d2.rect = .{ .x0 = 0, .y0 = 0, .x1 = 32, .y1 = 8 };
    try std.testing.expect(e.draw(&d2));
    const dw = words(e, &ds);
    // (0.25 * (2^24 - 1), rounded)
    try std.testing.expectEqual(@as(u32, 4194304), dw[3 * W + 7] & 0xffffff);
    try std.testing.expectEqual(@as(u32, 0xff00_00ff) & 0x00ff_ffff, words(e, &img)[3 * W + 7] & 0x00ff_ffff);
    // a slope's bias: the CPU and the GPU alike
    const slope = [_]Vert{ v(0, 8, -0.5, col), v(32, 8, 0.5, col), v(16, 24, 0.0, col) };
    var vb3 = try vbuf(e, &slope);
    defer e.freeImage(&vb3);
    var d3 = draw0(&colored, &img, &vb3, 3, .triangles);
    d3.depth = &ds;
    d3.depth_test = true;
    d3.depth_write = true;
    d3.bias_factor = 1.5;
    d3.bias_units = 4;
    d3.bias_clamp = 0.01;
    try std.testing.expect(e.draw(&d3));
    // a clip distance: x (clip space) >= 0 kept, the left half clipped
    var cl: [6]Vert = undefined;
    for (&cl, quad) |*x, y| {
        x.* = y;
        x.c = y.x;
        x.r = 1;
        x.g = 0;
        x.b = 1;
    }
    var vb4 = try vbuf(e, &cl);
    defer e.freeImage(&vb4);
    var d4 = draw0(&clipped, &img, &vb4, 6, .triangles);
    d4.rect = .{ .x0 = 0, .y0 = 24, .x1 = 32, .y1 = 32 };
    try std.testing.expect(e.draw(&d4));
    const px2 = words(e, &img);
    for (0..W) |x| try std.testing.expectEqual(x >= 16, px2[28 * W + x] == 0xffff_00ff);
    @memcpy(out[0 .. W * H], px2[0 .. W * H]);
    @memcpy(out[W * H ..][0 .. W * H], words(e, &ds)[0 .. W * H]);
}

/// Primitive restart in a strip and a fan: after the restart index a new
/// one starts (its first triangle even, its fan's center the vertex after
/// the restart), back faces culled: the wrong winding would cull it.
fn restartScene(e: *engine.Engine, out: []u32) !void {
    const quads = [2][4]f32{ .{ 2, 2, 10, 10 }, .{ 14, 4, 30, 20 } };
    var verts: [8]Vert = undefined;
    for (quads, 0..) |q, j| {
        // (strip order: bottom left, bottom right, top left, top right)
        verts[4 * j + 0] = v(q[0], q[1], 0, QUARTER);
        verts[4 * j + 1] = v(q[2], q[1], 0, QUARTER);
        verts[4 * j + 2] = v(q[0], q[3], 0, QUARTER);
        verts[4 * j + 3] = v(q[2], q[3], 0, QUARTER);
    }
    var vb = try vbuf(e, &verts);
    defer e.freeImage(&vb);
    // a strip each, and a fan each (bottom left, bottom right, top
    // right, top left), the restart between
    const R = 0xffff;
    const idx = [_]u16{ 0, 1, 2, 3, R, 4, 5, 6, 7, 0, 1, 3, 2, R, 4, 5, 7, 6 };
    var ib = e.newBuffer(@sizeOf(@TypeOf(idx))) orelse return error.OutOfMemory;
    defer e.freeImage(&ib);
    e.writeBytes(&ib, 0, std.mem.sliceAsBytes(&idx));
    for ([_]raster.Topology{ .strip, .fan }, 0..) |topo, ti| {
        var img = e.newImage(W, H, .rgba8) orelse return error.OutOfMemory;
        defer e.freeImage(&img);
        e.fill(&img, img.bounds(), 0, 0);
        var d = draw0(&colored, &img, &vb, 9, topo);
        d.index = &ib;
        d.index_size = 2;
        d.index_offset = @intCast(ti * 9 * 2);
        d.restart = true;
        d.cull = 2;
        d.blend = add_blend;
        try std.testing.expect(e.draw(&d));
        const px = words(e, &img);
        @memcpy(out[ti * W * H ..][0 .. W * H], px[0 .. W * H]);
        for (0..H) |y| {
            for (0..W) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                var in = false;
                for (quads) |q| in = in or (fx >= q[0] and fx < q[2] and fy >= q[1] and fy < q[3]);
                const want: u32 = if (in) 0x4040_4040 else 0;
                if (px[y * W + x] != want) {
                    std.debug.print("restart ({s}) at ({d}, {d}): 0x{x}, want 0x{x}\n", .{ @tagName(topo), x, y, px[y * W + x], want });
                    return error.Restart;
                }
            }
        }
    }
}

// ── The tests ──────────────────────────────────────────────────────────────

var eng: engine.Engine = undefined;
var results: [2][8 * W * H * 2]u32 = undefined;

fn bothAlike(comptime scene: anytype, args: anytype) !void {
    for ([_]Where{ .cpu, .rtx }, 0..) |w, wi| {
        try open(&eng, w);
        defer close(&eng);
        @memset(&results[wi], 0);
        try @call(.auto, scene, .{&eng} ++ args ++ .{&results[wi]});
        try clean(&eng, w);
    }
    try std.testing.expectEqualSlices(u32, &results[0], &results[1]);
}

test "raster: multisampled coverage 2x, 4x, 8x against the sample positions, and the resolve" {
    for ([_]Where{ .cpu, .rtx }) |w| {
        for ([_]usize{ 2, 4, 8 }) |ns| {
            try open(&eng, w);
            defer close(&eng);
            try msaaCoverage(&eng, ns);
            try clean(&eng, w);
        }
    }
}

test "raster: multisampled depth, stencil, alpha to coverage and the sample mask, the CPU's bytes on the RTX" {
    for ([_]usize{ 2, 4, 8 }) |ns| try bothAlike(msaaDepth, .{ns});
}

test "raster: points (gl_PointSize, gl_PointCoord), single- and multisampled" {
    for ([_]usize{ 1, 4 }) |ns| try bothAlike(pointScene, .{ns});
}

test "raster: lines by the diamond-exit rule; multisampled lines as rectangles" {
    for ([_]usize{ 1, 4 }) |ns| try bothAlike(lineScene, .{ns});
}

test "raster: line strips and loops share their vertices' pixels once" {
    try bothAlike(stripScene, .{});
}

test "raster: four colour targets of three formats in one pipeline, single- and multisampled" {
    for ([_]usize{ 1, 4 }) |ns| try bothAlike(targetScene, .{ns});
}

test "raster: depth bias, gl_FragDepth and a clip distance" {
    try bothAlike(depthScene, .{});
}

test "raster: primitive restart starts a new strip and a new fan" {
    try bothAlike(restartScene, .{});
}

// ── The variants compile for the Adreno too ────────────────────────────────

var k_insts: [engine.MAX_KIR]kir.Inst = undefined;
var k_tys: [engine.MAX_KIR]kir.Ty = undefined;
var code: [engine.PIPE_CODE]u8 align(16) = undefined;
var work_mem: [@max(gpu.kir_ir3.WORK_BYTES, gpu.nvidia_device.kir_sm120.WORK_BYTES)]u8 align(64) = undefined;

test "raster: every variant's kernels compile for ir3 and sm_120" {
    const caps = [_]gpu.Caps{ gpu.adreno_device.x1_45_caps(1 << 30), gpu.nvidia_device.rtx5070(8 << 30) };
    const variants = [_]raster.Variant{
        .{ .samples = 2 },
        .{ .samples = 4, .stencil = true },
        .{ .samples = 8, .targets = 0b1111 },
        .{ .targets = 0b1011, .stencil = true },
        .{ .targets = 0 },
        .{ .lines = true },
        .{ .lines = true, .stencil = true },
    };
    const storage = kir.Storage{ .insts = &k_insts, .tys = &k_tys };
    for (caps) |c| {
        for ([_]*raster.Pipeline{ &colored, &multi, &deep, &sized }) |p| {
            for (variants) |vr| {
                var k = raster.rasterKernelFor(storage, p, vr);
                try k.finish();
                var w = gpu.Work.init(&work_mem);
                _ = gpu.compile(&k, c, &w, &code) catch |err| {
                    std.debug.print("{s}: {s} does not compile: {s}\n", .{ @tagName(c.target), k.name, @errorName(err) });
                    return err;
                };
            }
            for ([_]raster.SetupKind{ .triangles, .lines, .line_quads, .points }) |kind| {
                var k = raster.setupKernelFor(storage, p, kind);
                try k.finish();
                var w = gpu.Work.init(&work_mem);
                _ = gpu.compile(&k, c, &w, &code) catch |err| {
                    std.debug.print("{s}: {s} does not compile: {s}\n", .{ @tagName(c.target), k.name, @errorName(err) });
                    return err;
                };
            }
        }
    }
}

// ── GL: a large program's stencil draws on the RTX, multisampled
//    framebuffers, draw buffers, points and lines, polygon offset ─────────

var objs: gles.Objects = undefined;
var ctx: gles.Context = undefined;

fn compileShader(kind: u32, source: [:0]const u8) !u32 {
    const id = program.createShader(&ctx, kind);
    const parts = [_]?[*]const u8{source.ptr};
    program.shaderSource(&ctx, id, 1, &parts, null);
    program.compileShader(&ctx, id);
    var ok: i32 = 0;
    program.getShaderiv(&ctx, id, g.COMPILE_STATUS, &ok);
    if (ok != 1) {
        var log: [512]u8 = undefined;
        var len: i32 = 0;
        program.getShaderInfoLog(&ctx, id, log.len, &len, &log);
        std.debug.print("shader: {s}\n", .{log[0..@intCast(len)]});
        return error.Compile;
    }
    return id;
}

fn link(vs_src: [:0]const u8, fs_src: [:0]const u8) !u32 {
    const vs = try compileShader(g.VERTEX_SHADER, vs_src);
    defer program.deleteShader(&ctx, vs);
    const fs = try compileShader(g.FRAGMENT_SHADER, fs_src);
    defer program.deleteShader(&ctx, fs);
    const p = program.createProgram(&ctx);
    program.attachShader(&ctx, p, vs);
    program.attachShader(&ctx, p, fs);
    program.linkProgram(&ctx, p);
    var ok: i32 = 0;
    program.getProgramiv(&ctx, p, g.LINK_STATUS, &ok);
    if (ok != 1) return error.Link;
    return p;
}

/// A lit, textured program: its stencil tile kernel spills predicates on
/// sm_120 (an instruction reading three of them), which kir_sm120 refused
/// before (TooManyRegs: the stencil draws ran on the CPU).
const vs_lit: [:0]const u8 =
    \\#version 300 es
    \\layout(location=0) in vec4 pos;
    \\layout(location=1) in vec4 col;
    \\out vec4 vCol; out vec2 vUv; out vec3 vN;
    \\uniform mat4 uMvp;
    \\void main() { vCol = col; vUv = pos.xy; vN = vec3(pos.xy, 1.0); gl_Position = uMvp * pos; }
;
const fs_lit: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec4 vCol; in vec2 vUv; in vec3 vN;
    \\uniform sampler2D uTex; uniform sampler2D uTex2;
    \\uniform vec3 uLight[4]; uniform vec4 uTint;
    \\out vec4 o;
    \\void main() {
    \\  vec3 n = normalize(vN);
    \\  vec3 acc = vec3(0.0);
    \\  for (int i = 0; i < 4; i++) { acc += max(dot(n, normalize(uLight[i])), 0.0) * vec3(0.25); }
    \\  vec4 t = texture(uTex, vUv) * texture(uTex2, vUv * 2.0);
    \\  if (t.a < 0.1) discard;
    \\  o = vec4(acc, 1.0) * vCol * uTint + t * 0.125;
    \\}
;

/// GLSL ES 3.00 for points, lines and two draw buffers.
const vs_pts: [:0]const u8 =
    \\#version 300 es
    \\layout(location=0) in vec4 pos;
    \\layout(location=1) in vec4 col;
    \\out vec4 vCol;
    \\void main() { vCol = col; gl_PointSize = col.a * 8.0; gl_Position = pos; }
;
const fs_pts: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec4 vCol;
    \\layout(location=0) out vec4 o0;
    \\layout(location=1) out vec4 o1;
    \\void main() { o0 = vec4(gl_PointCoord, 0.0, 1.0); o1 = vCol; }
;
const fs_two: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec4 vCol;
    \\layout(location=0) out vec4 o0;
    \\layout(location=1) out vec4 o1;
    \\void main() { o0 = vCol; o1 = vCol.bgra; }
;

const GVert = extern struct { x: f32, y: f32, z: f32, w: f32, r: f32, g: f32, b: f32, a: f32 };

fn gv(x: f32, y: f32, z: f32, col: [4]f32) GVert {
    return .{ .x = (x - W / 2) / (W / 2), .y = (y - H / 2) / (H / 2), .z = z, .w = 1, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
}

fn glDraw(buf: u32, verts: []const GVert, mode: u32) void {
    ctx.bindBuffer(g.ARRAY_BUFFER, buf);
    ctx.bufferData(g.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(GVert)), verts.ptr, g.STREAM_DRAW);
    ctx.vertexAttribPointer(0, 4, g.FLOAT, false, @sizeOf(GVert), 0, false);
    ctx.vertexAttribPointer(1, 4, g.FLOAT, false, @sizeOf(GVert), 16, false);
    ctx.enableVertexAttribArray(0, true);
    ctx.enableVertexAttribArray(1, true);
    ctx.drawArrays(mode, 0, @intCast(verts.len), 1);
}

fn noErr() !void {
    const e = ctx.getError();
    if (e != g.NO_ERROR) std.debug.print("GL error 0x{x}\n", .{e});
    try std.testing.expectEqual(g.NO_ERROR, e);
}

fn rbuf(internal: u32, samples: i32) u32 {
    var n: [1]u32 = undefined;
    ctx.genRenderbuffers(&n);
    ctx.bindRenderbuffer(g.RENDERBUFFER, n[0]);
    ctx.renderbufferStorage(g.RENDERBUFFER, samples, internal, W, H);
    return n[0];
}

fn fbo() u32 {
    var n: [1]u32 = undefined;
    ctx.genFramebuffers(&n);
    ctx.bindFramebuffer(g.FRAMEBUFFER, n[0]);
    return n[0];
}

/// The GL scene: its pixels into out.
fn glScene(e: *engine.Engine, out: []u32) !void {
    objs.init();
    ctx.init(e, &objs);
    defer ctx.deinit();
    var bufs: [1]u32 = undefined;
    ctx.genBuffers(&bufs);
    const at = struct {
        var n: usize = 0;
    };
    at.n = 0;
    const keep = struct {
        fn px(o: []u32) void {
            var tmp: [W * H]u32 = undefined;
            ctx.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &tmp);
            @memcpy(o[at.n..][0 .. W * H], &tmp);
            at.n += W * H;
        }
    }.px;
    // 1. a multisampled framebuffer (4x colour, depth-stencil), the lit
    // program's stencil draws, resolved by a blit
    const ms_fb = fbo();
    const ms_color = rbuf(g.RGBA8, 4);
    const ms_ds = rbuf(g.DEPTH24_STENCIL8, 3);
    var samples: i32 = 0;
    ctx.bindRenderbuffer(g.RENDERBUFFER, ms_ds);
    samples = ctx.getRenderbufferParameter(g.RENDERBUFFER, g.RENDERBUFFER_SAMPLES).?;
    try std.testing.expectEqual(@as(i32, 4), samples);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.RENDERBUFFER, ms_color);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_STENCIL_ATTACHMENT, g.RENDERBUFFER, ms_ds);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, ctx.checkFramebufferStatus(g.FRAMEBUFFER));
    var iv: [4]i32 = undefined;
    ctx.getIntegers(g.SAMPLES, &iv);
    try std.testing.expectEqual(@as(i32, 4), iv[0]);
    ctx.viewportSet(0, 0, W, H);
    ctx.clearColor(0, 0, 0, 1);
    ctx.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT);
    const lit = try link(vs_lit, fs_lit);
    program.useProgram(&ctx, lit);
    const id = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    program.uniformMatrix(&ctx, program.getUniformLocation(&ctx, lit, "uMvp"), 1, false, 4, 4, @ptrCast(&id));
    const lights = [12]f32{ 0, 0, 1, 1, 0, 1, 0, 1, 1, -1, 0, 1 };
    program.uniform(&ctx, program.getUniformLocation(&ctx, lit, "uLight"), 4, 3, .f, @ptrCast(&lights));
    const tint = [4]f32{ 1, 0.75, 0.5, 1 };
    program.uniform(&ctx, program.getUniformLocation(&ctx, lit, "uTint"), 1, 4, .f, @ptrCast(&tint));
    try noErr();
    ctx.enable(g.STENCIL_TEST, true);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.ALWAYS, 1, 0xff);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.KEEP, g.KEEP, g.REPLACE);
    const tri = [_]GVert{ gv(2.25, 3.5, 0, .{ 1, 1, 1, 1 }), gv(29.75, 9.0625, 0, .{ 1, 0.5, 0.25, 1 }), gv(12.5, 28.875, 0, .{ 0.25, 0.5, 1, 1 }) };
    glDraw(bufs[0], &tri, g.TRIANGLES);
    ctx.stencilFuncSeparate(g.FRONT_AND_BACK, g.EQUAL, 0, 0xff);
    ctx.stencilOpSeparate(g.FRONT_AND_BACK, g.KEEP, g.KEEP, g.KEEP);
    const quad = [_]GVert{ gv(0, 0, 0.5, .{ 0, 1, 0, 1 }), gv(32, 0, 0.5, .{ 0, 1, 0, 1 }), gv(32, 32, 0.5, .{ 0, 1, 0, 1 }), gv(0, 0, 0.5, .{ 0, 1, 0, 1 }), gv(32, 32, 0.5, .{ 0, 1, 0, 1 }), gv(0, 32, 0.5, .{ 0, 1, 0, 1 }) };
    glDraw(bufs[0], &quad, g.TRIANGLES);
    ctx.enable(g.STENCIL_TEST, false);
    try noErr();
    // (a multisampled framebuffer is read through a resolve)
    var one: [4]u8 = undefined;
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &one);
    try std.testing.expectEqual(g.INVALID_OPERATION, ctx.getError());
    const ss_fb = fbo();
    const ss_color = rbuf(g.RGBA8, 0);
    const ss_two = rbuf(g.RGBA8, 0);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.RENDERBUFFER, ss_color);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0 + 1, g.RENDERBUFFER, ss_two);
    ctx.bindFramebuffer(g.READ_FRAMEBUFFER, ms_fb);
    ctx.bindFramebuffer(g.DRAW_FRAMEBUFFER, ss_fb);
    // (not 1:1: refused)
    ctx.blitFramebuffer(0, 0, W, H, 0, 0, W / 2, H / 2, g.COLOR_BUFFER_BIT, g.NEAREST);
    try std.testing.expectEqual(g.INVALID_OPERATION, ctx.getError());
    ctx.blitFramebuffer(0, 0, W, H, 0, 0, W, H, g.COLOR_BUFFER_BIT, g.NEAREST);
    try noErr();
    ctx.bindFramebuffer(g.FRAMEBUFFER, ss_fb);
    keep(out);
    // (the lit triangle's edge pixels mixed with the green: resolved)
    var mixed: usize = 0;
    for (out[0 .. W * H]) |p| {
        const gr = (p >> 8) & 0xff;
        if (gr != 0 and gr != 0xff and (p & 0xff) != 0) mixed += 1;
    }
    try std.testing.expect(mixed > 10);
    // 2. two draw buffers; points with gl_PointSize and gl_PointCoord
    const bufs2 = [_]u32{ g.COLOR_ATTACHMENT0, g.COLOR_ATTACHMENT0 + 1 };
    ctx.drawBuffers(&bufs2);
    ctx.clear(g.COLOR_BUFFER_BIT);
    const pts_prog = try link(vs_pts, fs_pts);
    program.useProgram(&ctx, pts_prog);
    const pts = [_]GVert{ gv(8, 8, 0, .{ 1, 0, 0, 0.5 }), gv(20, 12, 0, .{ 0, 1, 0, 1 }), gv(9.5, 24.5, 0, .{ 0, 0, 1, 0.375 }) };
    glDraw(bufs[0], &pts, g.POINTS);
    try noErr();
    keep(out);
    ctx.readBuffer(g.COLOR_ATTACHMENT0 + 1);
    keep(out);
    ctx.readBuffer(g.COLOR_ATTACHMENT0);
    // (a 4 x 4 sprite at (8, 8): gl_PointCoord (1/8, 7/8) at its corner
    // pixel (6, 6), the color in buffer 1)
    try std.testing.expectEqual(@as(u32, 0xff00_df20), out[W * H + 6 * W + 6]);
    try std.testing.expectEqual(@as(u32, 0x8000_00ff), out[2 * W * H + 6 * W + 6]);
    // 3. lines, a strip, a loop; polygon offset; two outputs
    ctx.clear(g.COLOR_BUFFER_BIT);
    const two = try link(vs_pts, fs_two);
    program.useProgram(&ctx, two);
    const lines = [_]GVert{ gv(1.5, 1.5, 0, .{ 1, 0, 0, 1 }), gv(30.5, 3.5, 0, .{ 1, 0, 0, 1 }), gv(3.0, 30.0, 0, .{ 0, 1, 0, 1 }), gv(28.0, 6.0, 0, .{ 0, 1, 0, 1 }) };
    glDraw(bufs[0], &lines, g.LINES);
    ctx.lineWidth(1);
    const strip = [_]GVert{ gv(5.5, 20.5, 0, .{ 0, 0, 1, 1 }), gv(15.5, 25.5, 0, .{ 0, 0, 1, 1 }), gv(25.5, 20.5, 0, .{ 0, 0, 1, 1 }), gv(15.5, 12.5, 0, .{ 0, 0, 1, 1 }) };
    glDraw(bufs[0], &strip, g.LINE_STRIP);
    glDraw(bufs[0], &strip, g.LINE_LOOP);
    try noErr();
    keep(out);
    ctx.readBuffer(g.COLOR_ATTACHMENT0 + 1);
    keep(out);
    ctx.readBuffer(g.COLOR_ATTACHMENT0);
    // polygon offset: the same quad again passes LEQUAL... LESS only with
    // the offset (a depth buffer on the single-sampled framebuffer)
    const ss_depth = rbuf(g.DEPTH_COMPONENT24, 0);
    ctx.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_ATTACHMENT, g.RENDERBUFFER, ss_depth);
    ctx.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT);
    ctx.enable(g.DEPTH_TEST, true);
    glDraw(bufs[0], &quad, g.TRIANGLES);
    const red = [_]GVert{ gv(0, 0, 0.5, RED), gv(32, 0, 0.5, RED), gv(32, 32, 0.5, RED), gv(0, 0, 0.5, RED), gv(32, 32, 0.5, RED), gv(0, 32, 0.5, RED) };
    glDraw(bufs[0], &red, g.TRIANGLES);
    var px1: [4]u8 = undefined;
    ctx.readPixels(4, 4, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &px1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &px1);
    ctx.enable(g.POLYGON_OFFSET_FILL, true);
    ctx.polygonOffset(0, -1);
    glDraw(bufs[0], &red, g.TRIANGLES);
    ctx.readPixels(4, 4, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &px1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &px1);
    try noErr();
    keep(out);
}

test "GL: a large program's stencil draws (sm_120), 4x framebuffers resolved, draw buffers, points, lines, polygon offset" {
    try bothAlike(glScene, .{});
}
