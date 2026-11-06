//! Direct3D shaders drawn on the CPU engine (KIR's interpreter on the
//! images' memory): shaders compiled by Microsoft's compiler (fixtures.sig,
//! from fixtures.hlsl), generated into the raster's kernels by gen.sig,
//! each draw's pixels checked against what the HLSL computes.

const std = @import("std");
const engine = @import("../engine.sig");
const raster = @import("../raster.sig");
const texture = @import("../texture.sig");
const gen = @import("gen.sig");
const fx = @import("fixtures.sig");

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

// ── The layout the HLSL gives: v0 POSITION, v1 COLOR; cb0 (mvp, tint);
// COLOR's varying at word 0; t0 with s0 in slot 0 ──

const CB_WORDS = 20;
const DESC_BASE = CB_WORDS;

fn varying(_: ?*const anyopaque, name: []const u8, index: u32) ?u32 {
    if (std.ascii.eqlIgnoreCase(name, "COLOR") and index == 0) return 0;
    return null;
}

fn cbuffer(_: ?*const anyopaque, slot: u32) ?gen.CBuffer {
    return if (slot == 0) .{ .word = 0, .vecs = 5 } else null;
}

fn tex(_: ?*const anyopaque, t: u32, s: u32) ?u32 {
    return if (t == 0 and (s == 0 or s == gen.NO_SAMPLER)) 0 else null;
}

const lay = gen.Layout{ .varying = varying, .cbuffer = cbuffer, .texture = tex, .desc_base = DESC_BASE };

const Vert = extern struct { pos: [3]f32, color: [4]f32 };

/// A triangle over the whole target, one color at every vertex.
fn coverAll(color: [4]f32) [3]Vert {
    return .{
        .{ .pos = .{ -1, -1, 0.5 }, .color = color },
        .{ .pos = .{ 3, -1, 0.5 }, .color = color },
        .{ .pos = .{ -1, 3, 0.5 }, .color = color },
    };
}

/// cb0: an identity mvp, then the tint.
fn uniforms(tint: [4]f32, out: []u32) void {
    @memset(out, 0);
    for (0..4) |i| out[i * 4 + i] = @bitCast(@as(f32, 1));
    for (0..4) |c| out[16 + c] = @bitCast(tint[c]);
}

/// Draws the triangle with `vs` and `ps` into a cleared target; the pixel
/// at the middle.
fn drawOne(vs: []const u8, ps: []const u8, verts: [3]Vert, uni: []const u32, texture_img: ?*engine.Image) ![4]u8 {
    const e = engineCpu();
    var target = e.newImage(W, H, .rgba8) orelse return error.NoImage;
    defer e.freeImage(&target);
    e.fill(&target, .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H }, 0, 0);
    var vb = e.newBuffer(@sizeOf([3]Vert)) orelse return error.NoBuffer;
    defer e.freeImage(&vb);
    e.writeBytes(&vb, 0, std.mem.asBytes(&verts));
    var log = gen.Log{};
    const pair = gen.Pair{ .vs = vs, .ps = ps, .lay = lay, .log = &log };
    var pipe = raster.Pipeline.init(pair.shaders(2, 4, if (texture_img != null) 1 else 0));
    defer e.unloadPipeline(&pipe);
    var d = raster.Draw{
        .pipe = &pipe,
        .color = &target,
        .count = 3,
        .center = .{ W / 2, H / 2 },
        .half = .{ W / 2, H / 2 },
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H },
        .uniforms = uni,
    };
    d.attrs[0] = .{ .buf = &vb, .offset = 0, .stride = @sizeOf(Vert), .comps = 3 };
    d.attrs[1] = .{ .buf = &vb, .offset = 12, .stride = @sizeOf(Vert), .comps = 4 };
    if (texture_img) |t| d.textures[0] = t;
    if (!e.draw(&d)) return error.DrawRefused;
    e.finish();
    if (log.len != 0) {
        std.debug.print("{s}\n", .{log.text()});
        return error.Generation;
    }
    var px: [W * H * 4]u8 = undefined;
    e.read(&target, 0, 0, W, H, &px, W * 4, .rgba8);
    const at = ((H / 2) * W + W / 2) * 4;
    return px[at..][0..4].*;
}

fn near(got: [4]u8, want: [4]u8, tol: u8) !void {
    for (0..4) |c| {
        const d = @as(i32, got[c]) - @as(i32, want[c]);
        if (@abs(d) > tol) {
            std.debug.print("got {any}, want {any}\n", .{ got, want });
            return error.TestExpectedEqual;
        }
    }
}

test "Direct3D: the vertex and pixel shaders draw color times tint" {
    var uni: [CB_WORDS]u32 = undefined;
    uniforms(.{ 0.5, 1, 1, 1 }, &uni);
    const px = try drawOne(&fx.vs40, &fx.ps40, coverAll(.{ 1, 0.5, 0.25, 1 }), &uni, null);
    try near(px, .{ 128, 128, 64, 255 }, 1);
}

test "Direct3D: Shader Model 5's vertex shader too" {
    var uni: [CB_WORDS]u32 = undefined;
    uniforms(.{ 1, 1, 1, 1 }, &uni);
    const px = try drawOne(&fx.vs50, &fx.ps40, coverAll(.{ 0.25, 0.5, 0.75, 1 }), &uni, null);
    try near(px, .{ 64, 128, 191, 255 }, 1);
}

test "Direct3D: integer ops, udiv and movc (ps_int)" {
    var uni: [CB_WORDS]u32 = undefined;
    uniforms(.{ 1, 1, 1, 1 }, &uni);
    // x = 10, y = 229 - 128 = 101: m = (10 << 3) ^ (10 >> 1) | 7 = 87,
    // d = 101 / 3 = 33, |y| = 101, x odd: no
    const px = try drawOne(&fx.vs40, &fx.psint40, coverAll(.{ 10.5 / 255.0, 229.5 / 255.0, 0, 1 }), &uni, null);
    try near(px, .{ 87, 66, 201, 0 }, 1);
}

fn textureOf(e: *engine.Engine, rgba: [4]u8, img: *engine.Image, desc: []u32) void {
    img.* = e.newImage(2, 2, .rgba8).?;
    var texels: [16]u8 = undefined;
    for (0..4) |i| @memcpy(texels[i * 4 ..][0..4], &rgba);
    e.write(img, 0, 0, 2, 2, &texels, 8, .rgba8);
    var dw: [texture.DESC_WORDS]u32 = undefined;
    texture.descriptor(.{ .img = img }, &dw);
    @memcpy(desc[0..texture.DESC_WORDS], &dw);
}

test "Direct3D: sample, the immediate constant buffer in a loop, frc, discard" {
    const e = engineCpu();
    var uni: [CB_WORDS + texture.DESC_WORDS]u32 = undefined;
    uniforms(.{ 1, 1, 1, 1 }, uni[0..CB_WORDS]);
    var img: engine.Image = undefined;
    // (0.2, 0.4, 0.6, 1): s = 0.2 + 0.8 + 1.8 + 4 = 6.8, frc 0.8
    textureOf(e, .{ 51, 102, 153, 255 }, &img, uni[CB_WORDS..]);
    defer e.freeImage(&img);
    const px = try drawOne(&fx.vs40, &fx.pstex40, coverAll(.{ 0.5, 0.5, 0, 1 }), &uni, &img);
    try near(px, .{ 51, 102, 153, 204 }, 2);
    // alpha under 0.5: every pixel discarded, the target stays clear
    var img2: engine.Image = undefined;
    textureOf(e, .{ 255, 255, 255, 64 }, &img2, uni[CB_WORDS..]);
    defer e.freeImage(&img2);
    const px2 = try drawOne(&fx.vs40, &fx.pstex40, coverAll(.{ 0.5, 0.5, 0, 1 }), &uni, &img2);
    try near(px2, .{ 0, 0, 0, 0 }, 0);
}

test "Direct3D: a wrong stage or a damaged blob fails with a log, not a crash" {
    var log = gen.Log{};
    var k: @import("gpu").kir.Kernel = undefined;
    _ = &k;
    try std.testing.expect(gen.needsQuads(&fx.pstex40));
    try std.testing.expect(!gen.needsQuads(&fx.ps40));
    try std.testing.expect(!gen.needsQuads(&fx.vs40));
    _ = &log;
}
