//! PS5 shaders drawn on the CPU engine (KIR's interpreter on the images'
//! memory): the vertex side and pixel shaders of shader_fixtures.sig
//! (assembled by LLVM), analysed and evaluated by recompile.sig against a
//! fake game address space, emitted into the raster's kernels; each
//! draw's pixels checked against what the shaders compute, worked out
//! here by hand.
//!
//! The scene: one triangle over the whole 32 x 32 target, its vertices at
//! window (0, 0), (64, 0) and (0, 64), so a pixel's centre (x, y) has the
//! barycentric weights 1 - x/64 - y/64, x/64 and y/64. The vertex
//! positions are given in the matrix's own space: a rotation by a
//! quarter turn and a translation (a matrix neither symmetric nor
//! without translation, so a transposed one draws elsewhere) bring them
//! to the corners. Each vertex record is (x, y, z, scale), the scale a
//! second attribute at byte 12 of the same record, multiplying the
//! colour (not its alpha).

const std = @import("std");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const raster = gfxapi.raster;
const rc = @import("recompile.sig");
const state = rc.state;
const fx = @import("shader_fixtures.sig");
const ut = @import("recompile_test.sig");
const FakeMemory = ut.FakeMemory;

const W = 32;
const H = 32;

var pool_mem: [8 << 20]u8 align(64) = undefined;
var cpu_work: [4 << 20]u8 align(64) = undefined;
var eng: engine.Engine = undefined;
var eng_ready = false;

fn engineCpu() *engine.Engine {
    if (!eng_ready) {
        eng.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
        eng_ready = true;
    }
    return &eng;
}

// ── The fake game memory ────────────────────────────────────────────────────

const BASE: u64 = 0x7_0000_0000;
/// The vertex buffer table (a V# a slot), the attribute words, the
/// matrices, the vertex buffers.
const T_VB = 0x000;
const T_ATTR = 0x100;
const T_CB = 0x200;
const T_CB2 = 0x280;
const T_POS = 0x300;
const T_POS2 = 0x380;
const T_COL = 0x400;
const T_COL2 = 0x480;
const SCENE = 0x800;

var scene: [SCENE]u8 align(16) = [_]u8{0} ** SCENE;

fn put(at: usize, w: u32) void {
    std.mem.writeInt(u32, scene[at..][0..4], w, .little);
}
fn putf(at: usize, x: f32) void {
    put(at, @bitCast(x));
}

fn vsharp(addr: u64, stride: u32, records: u32, format: u8) [4]u32 {
    return ut.vsharp(addr, stride, records, format, ut.IDENTITY_SEL);
}

fn putV(at: usize, v: [4]u32) void {
    for (0..4) |j| put(at + 4 * j, v[j]);
}

/// An attribute word: its vertex buffer slot, byte offset, and whether the
/// instance index fetches it.
fn attrWord(slot: u32, offset: u32, by_instance: bool) u32 {
    return slot | (offset << 14) | (@as(u32, @intFromBool(by_instance)) << 26);
}

/// A column-major 4 x 4 matrix (m[column * 4 + row]) at `at`.
fn putMatrix(at: usize, m: [16]f32) void {
    for (0..16) |j| putf(at + 4 * j, m[j]);
}

/// A quarter turn and a translation: x' = 0.25 - y, y' = x + 0.5.
const rot_a = [16]f32{ 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0.25, 0.5, 0, 1 };
/// The other quarter turn and another translation: x' = y - 0.5,
/// y' = 0.125 - x.
const rot_b = [16]f32{ 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, -0.5, 0.125, 0, 1 };

/// The triangle's corners in clip space (window (0,0), (64,0), (0,64)).
const corners = [3][3]f32{ .{ -1, -1, 0.5 }, .{ 3, -1, 0.5 }, .{ -1, 3, 0.5 } };

/// The point matrix `m` (rot_a or rot_b) takes to `c`.
fn before(m: *const [16]f32, c: [3]f32) [3]f32 {
    const tx = m[12];
    const ty = m[13];
    // x' = m[4] y + tx, y' = m[1] x + ty (m[4], m[1]: 1 or -1)
    return .{ (c[1] - ty) / m[1], (c[0] - tx) / m[4], c[2] };
}

/// Vertex records (x, y, z, scale) at `at`: `p` as matrix `m` would take
/// them back from (null: as they are).
fn putVertices(at: usize, m: ?*const [16]f32, p: []const [3]f32, scale: []const f32) void {
    for (p, 0..) |v0, j| {
        const v = if (m) |mm| before(mm, v0) else v0;
        for (0..3) |c| putf(at + 16 * j + 4 * c, v[c]);
        putf(at + 16 * j + 12, scale[j]);
    }
}

fn putColors8(at: usize, c: []const [4]u8) void {
    for (c, 0..) |v, j| @memcpy(scene[at + 4 * j ..][0..4], &v);
}

fn putColorsF(at: usize, c: []const [4]f32) void {
    for (c, 0..) |v, j| {
        for (0..4) |k| putf(at + 16 * j + 4 * k, v[k]);
    }
}

/// The vertex side's user data: s[8:9] the V# table, s[10:11] the
/// attribute words, s[12:15] the matrix's V#.
fn vsUser(cb: usize) [8]u32 {
    const vb = BASE + T_VB;
    const at = BASE + T_ATTR;
    const v = vsharp(BASE + cb, 0, 64, 22);
    return .{ @truncate(vb), @truncate(vb >> 32), @truncate(at), @truncate(at >> 32), v[0], v[1], v[2], v[3] };
}

/// The vertex buffer table: slot 0 the positions, 1 the colours, 2 the
/// scales (the positions' records again, read as one float from byte 12).
fn putTable(pos: usize, records: u32, col: usize, col_stride: u32, col_records: u32, col_format: u8) void {
    putV(T_VB, vsharp(BASE + pos, 16, records, 74));
    putV(T_VB + 16, vsharp(BASE + col, col_stride, col_records, col_format));
    putV(T_VB + 32, vsharp(BASE + pos, 16, records, 22));
}

const ones = [_]f32{ 1, 1, 1, 1, 1, 1 };

/// The usual scene: vertices through rot_a with scales, unorm8 colours.
fn usualScene(colors: []const [4]u8, color_records: u32, scale: []const f32) void {
    @memset(&scene, 0);
    putTable(T_POS, 3, T_COL, 4, color_records, 56);
    put(T_ATTR, attrWord(0, 0, false));
    put(T_ATTR + 4, attrWord(1, 0, false));
    put(T_ATTR + 8, attrWord(2, 12, false));
    putMatrix(T_CB, rot_a);
    putVertices(T_POS, &rot_a, &corners, scale);
    putColors8(T_COL, colors);
}

// ── Drawing ─────────────────────────────────────────────────────────────────

var pair: rc.Pair = .{};
var pair2: rc.Pair = .{};

fn setupOf(enabled: u16, inputs: u8, color_formats: u32) state.PixelSetup {
    return .{ .inputs = inputs, .lanes = 32, .enabled = enabled, .placed = enabled, .color_formats = color_formats, .may_kill = false, .writes_depth = false };
}

fn smooth(slot: u5) state.PixelInput {
    return .{ .slot = slot, .flat = false, .default = 0, .halves = false };
}

/// Draws `pipe` (made from `pr`) with its last evaluation: the target
/// cleared, the windows copied from the scene into buffers.
fn draw(pr: *const rc.Pair, pipe: *raster.Pipeline, base_vertex: u32, first_instance: u32, instances: u32, px: *[W * H * 4]u8) !void {
    return drawExtra(pr, pipe, base_vertex, first_instance, instances, 0, px);
}

/// As draw, each buffer `extra` bytes longer than its window, with the
/// scene's bytes past the window in them (as a runtime that maps more of
/// the game's memory than a window would give).
fn drawExtra(pr: *const rc.Pair, pipe: *raster.Pipeline, base_vertex: u32, first_instance: u32, instances: u32, extra: u32, px: *[W * H * 4]u8) !void {
    const e = engineCpu();
    var target = e.newImage(W, H, .rgba8) orelse return error.NoImage;
    defer e.freeImage(&target);
    e.fill(&target, .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H }, 0, 0);
    var uni: [512]u32 = undefined;
    const nu = pr.uniformWords();
    pr.fillUniforms(base_vertex, first_instance, H, uni[0..nu]);
    var d = raster.Draw{
        .pipe = pipe,
        .color = &target,
        .count = 3,
        .instances = instances,
        .center = .{ W / 2, H / 2 },
        .half = .{ W / 2, H / 2 },
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H },
        .uniforms = uni[0..nu],
    };
    var bufs: [raster.MAX_BUFFERS]engine.Image = undefined;
    var nb: usize = 0;
    defer for (bufs[0..nb]) |*b| e.freeImage(b);
    for (0..pr.bufferCount()) |b| {
        const w = pr.window(@intCast(b)) orelse continue;
        const off: usize = @intCast(w.address - BASE);
        const len = @min(@as(usize, w.bytes) + extra, SCENE - off);
        bufs[nb] = e.newBuffer(len) orelse return error.NoBuffer;
        e.writeBytes(&bufs[nb], 0, scene[off..][0..len]);
        d.buffers[b] = &bufs[nb];
        nb += 1;
    }
    e.trap = .{};
    if (!e.draw(&d)) return error.DrawRefused;
    e.finish();
    if (e.trap.what != .none) {
        std.debug.print("trap: {s} at {d}, binding {d} offset {d}\n", .{ @tagName(e.trap.what), e.trap.pc, e.trap.binding, e.trap.offset });
        return error.Trapped;
    }
    e.read(&target, 0, 0, W, H, px, W * 4, .rgba8);
}

fn evaluate(pr: *rc.Pair, vs_user: []const u32, ps_user: []const u32) !u64 {
    var log = rc.Log{};
    var fake = FakeMemory{ .base = BASE, .bytes = &scene };
    return pr.evaluate(vs_user, 0x1_0000, ps_user, 0x2_0000, fake.memory(), &log) catch |err| {
        std.debug.print("{s}\n", .{log.text()});
        return err;
    };
}

fn init(pr: *rc.Pair, ps: []align(1) const u32, setup: state.PixelSetup, inputs: []const state.PixelInput) !void {
    var log = rc.Log{};
    pr.init(&fx.vs_fetch, 32, ps, setup, inputs, false, &log) catch |err| {
        std.debug.print("{s}\n", .{log.text()});
        return err;
    };
}

/// The barycentric weights at pixel (x, y)'s centre.
fn weights(x: usize, y: usize) [3]f32 {
    const b1 = (@as(f32, @floatFromInt(x)) + 0.5) / 64;
    const b2 = (@as(f32, @floatFromInt(y)) + 0.5) / 64;
    return .{ 1 - b1 - b2, b1, b2 };
}

/// The three vertices' values interpolated at pixel (x, y), 0..255.
fn mix(c: [3][4]f32, x: usize, y: usize) [4]f32 {
    const b = weights(x, y);
    var o: [4]f32 = undefined;
    for (0..4) |k| o[k] = 255 * (c[0][k] * b[0] + c[1][k] * b[1] + c[2][k] * b[2]);
    return o;
}

/// Colours as the shader exports them: unorm8 to 0..1, the colour (not
/// its alpha) times the vertex's scale.
fn unorm(c: []const [4]u8, scale: []const f32) [3][4]f32 {
    var o: [3][4]f32 = undefined;
    for (0..3) |j| {
        for (0..4) |k| {
            const v: f32 = if (j < c.len) @as(f32, @floatFromInt(c[j][k])) / 255 else 0;
            o[j][k] = if (k < 3) v * scale[j] else v;
        }
    }
    return o;
}

fn near(px: *const [W * H * 4]u8, x: usize, y: usize, want: [4]f32) !void {
    const at = (y * W + x) * 4;
    for (0..4) |k| {
        const d = @as(f32, @floatFromInt(px[at + k])) - want[k];
        if (@abs(d) > 1.0) {
            std.debug.print("pixel ({d}, {d}): got {any}, want {any}\n", .{ x, y, px[at..][0..4].*, want });
            return error.TestExpectedEqual;
        }
    }
}

const sample_points = [_][2]usize{ .{ 0, 0 }, .{ 31, 0 }, .{ 0, 31 }, .{ 16, 16 }, .{ 5, 20 }, .{ 25, 3 }, .{ 31, 31 } };

const rgb = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 } };
const scales = [_]f32{ 1, 0.5, 0.25 };

test "PS5 draw: fetched attributes times a matrix, interpolated; a second draw through the same pipeline" {
    usualScene(&rgb, 3, &scales);
    try init(&pair, &fx.ps_interp, setupOf(0x2, 1, 9), &.{smooth(0)});
    const vu = vsUser(T_CB);
    const pu = [_]u32{0};
    const key1 = try evaluate(&pair, &vu, &pu);
    var pipe = raster.Pipeline.init(pair.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    try draw(&pair, &pipe, 0, 0, 1, &px);
    const c1 = unorm(&rgb, &scales);
    for (sample_points) |p| try near(&px, p[0], p[1], mix(c1, p[0], p[1]));

    // Draw 2: other buffers, another matrix (the other quarter turn, its
    // own translation), other colours and scales: the same key, the same
    // pipeline, the new values through the uniforms and windows.
    putTable(T_POS2, 3, T_COL2, 4, 3, 56);
    putMatrix(T_CB2, rot_b);
    const scales2 = [_]f32{ 0.5, 1, 0.75 };
    putVertices(T_POS2, &rot_b, &corners, &scales2);
    const rgb2 = [_][4]u8{ .{ 0, 0, 0, 255 }, .{ 255, 255, 0, 128 }, .{ 51, 102, 204, 255 } };
    putColors8(T_COL2, &rgb2);
    const vu2 = vsUser(T_CB2);
    const key2 = try evaluate(&pair, &vu2, &pu);
    try std.testing.expectEqual(key1, key2);
    try std.testing.expectEqual(BASE + T_POS2, pair.window(0).?.address);
    try draw(&pair, &pipe, 0, 0, 1, &px);
    const c2 = unorm(&rgb2, &scales2);
    for (sample_points) |p| try near(&px, p[0], p[1], mix(c2, p[0], p[1]));
}

test "PS5 draw: a tint from user data, a flat input, a default input, a compare and select, packed halves" {
    const cols = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 153, 0, 255, 255 } };
    usualScene(&cols, 3, &ones);
    const flat1 = state.PixelInput{ .slot = 1, .flat = true, .default = 0, .halves = false };
    const none = state.PixelInput{ .slot = null, .flat = false, .default = 3, .halves = false };
    try init(&pair, &fx.ps_tint, setupOf(0x302, 3, 4), &.{ smooth(0), flat1, none });
    try std.testing.expectEqual(@as(u64, 0xf0), pair.shaders().flat);
    try std.testing.expect(pair.flat());
    const vu = vsUser(T_CB);
    const pu = [_]u32{ @bitCast(@as(f32, 0.5)), @bitCast(@as(f32, 0.75)), 0, @bitCast(@as(f32, 0.8)), 0 };
    _ = try evaluate(&pair, &vu, &pu);
    var pipe = raster.Pipeline.init(pair.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    try draw(&pair, &pipe, 0, 0, 1, &px);
    const c = unorm(&cols, &ones);
    for (sample_points) |p| {
        const m = mix(c, p[0], p[1]);
        // right of x = 16: the default input's w (1); left: the flat
        // input, the provoking (last) vertex's red, 0.6
        const blue: f32 = if (@as(f32, @floatFromInt(p[0])) + 0.5 > 16) 255 else 153;
        try near(&px, p[0], p[1], .{ 0.5 * m[0], 0.75 * m[1], blue, 0.8 * 255 });
    }
}

test "PS5 draw: a V# with too few records reads zeros past its end, and nothing traps" {
    // (the third colour is in memory, past the V#'s two records)
    usualScene(&rgb, 2, &ones);
    try init(&pair, &fx.ps_interp, setupOf(0x2, 1, 9), &.{smooth(0)});
    const vu = vsUser(T_CB);
    const pu = [_]u32{0};
    _ = try evaluate(&pair, &vu, &pu);
    // the colours' window: two records of four bytes
    try std.testing.expectEqual(@as(u32, 8), pair.window(1).?.bytes);
    var pipe = raster.Pipeline.init(pair.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    // the third vertex's colour is (0, 0, 0, 0), though the buffer bound
    // holds the third colour past the window: the load's own range check
    // gives the zeros
    try drawExtra(&pair, &pipe, 0, 0, 1, 64, &px);
    const c = unorm(rgb[0..2], &ones);
    for (sample_points) |p| try near(&px, p[0], p[1], mix(c, p[0], p[1]));
}

test "PS5 draw: the base vertex and the first instance, an attribute fetched by instance" {
    @memset(&scene, 0);
    putTable(T_POS, 6, T_COL, 4, 3, 56);
    put(T_ATTR, attrWord(0, 0, false));
    put(T_ATTR + 4, attrWord(1, 0, true));
    put(T_ATTR + 8, attrWord(2, 12, false));
    putMatrix(T_CB, rot_a);
    // three vertices nothing draws (all at one point), then the triangle
    const pos = [6][3]f32{ .{ 0, 0, 0.5 }, .{ 0, 0, 0.5 }, .{ 0, 0, 0.5 }, corners[0], corners[1], corners[2] };
    putVertices(T_POS, &rot_a, &pos, &ones);
    putColors8(T_COL, &rgb);
    try init(&pair, &fx.ps_interp, setupOf(0x2, 1, 9), &.{smooth(0)});
    const vu = vsUser(T_CB);
    const pu = [_]u32{0};
    _ = try evaluate(&pair, &vu, &pu);
    var pipe = raster.Pipeline.init(pair.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    // one instance from 0: the triangle (vertices 3..5) in colour 0
    try draw(&pair, &pipe, 3, 0, 1, &px);
    for (sample_points) |p| try near(&px, p[0], p[1], .{ 255, 0, 0, 255 });
    // two instances from 1: colours 1 then 2, the last one drawn on top
    try draw(&pair, &pipe, 3, 1, 2, &px);
    for (sample_points) |p| try near(&px, p[0], p[1], .{ 0, 0, 255, 255 });
    // no base vertex: the three vertices at one point draw nothing
    try draw(&pair, &pipe, 0, 0, 1, &px);
    for (sample_points) |p| try near(&px, p[0], p[1], .{ 0, 0, 0, 0 });
}

test "PS5 draw: float colours in place of unorm8 change the key, and draw the same" {
    usualScene(&rgb, 3, &scales);
    try init(&pair, &fx.ps_interp, setupOf(0x2, 1, 9), &.{smooth(0)});
    const vu = vsUser(T_CB);
    const pu = [_]u32{0};
    const key8 = try evaluate(&pair, &vu, &pu);
    // the same colours as 32_32_32_32 floats, 16 bytes a vertex
    const fl = [_][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 0, 0, 1, 1 } };
    putColorsF(T_COL, &fl);
    putV(T_VB + 16, vsharp(BASE + T_COL, 16, 3, 77));
    try init(&pair2, &fx.ps_interp, setupOf(0x2, 1, 9), &.{smooth(0)});
    const keyf = try evaluate(&pair2, &vu, &pu);
    try std.testing.expect(key8 != keyf);
    try std.testing.expectEqual(@as(u8, 77), pair2.vs_ev.format[1]);
    var pipe = raster.Pipeline.init(pair2.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    try draw(&pair2, &pipe, 0, 0, 1, &px);
    const c = unorm(&rgb, &scales);
    for (sample_points) |p| try near(&px, p[0], p[1], mix(c, p[0], p[1]));
}

test "PS5 draw: the pixel's y counts from the target's top" {
    usualScene(&rgb, 3, &ones);
    try init(&pair, &fx.ps_posy, setupOf(0x200, 0, 9), &.{});
    _ = try evaluate(&pair, &vsUser(T_CB), &.{});
    var pipe = raster.Pipeline.init(pair.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    try draw(&pair, &pipe, 0, 0, 1, &px);
    // The engine's row 0 is its bottom: the console's row 31, y 31.5; its
    // row 31 the console's top row, y 0.5 (colour y / 32).
    const bottom: f32 = 31.5 / 32.0 * 255;
    const top: f32 = 0.5 / 32.0 * 255;
    for ([_]usize{ 0, 7, 20 }) |x| {
        try near(&px, x, 0, .{ bottom, bottom, bottom, bottom });
        try near(&px, x, 31, .{ top, top, top, top });
    }
}

test "PS5 draw: an input from a slot the vertex side does not export reads its default" {
    usualScene(&rgb, 3, &ones);
    // slot 5: never exported; the default (0, 0, 0, 1)
    const in0 = state.PixelInput{ .slot = 5, .flat = false, .default = 1, .halves = false };
    try init(&pair, &fx.ps_interp, setupOf(0x2, 1, 9), &.{in0});
    _ = try evaluate(&pair, &vsUser(T_CB), &[_]u32{0});
    var pipe = raster.Pipeline.init(pair.shaders());
    defer engineCpu().unloadPipeline(&pipe);
    var px: [W * H * 4]u8 = undefined;
    try draw(&pair, &pipe, 0, 0, 1, &px);
    for (sample_points) |p| try near(&px, p[0], p[1], .{ 0, 0, 0, 255 });
}
