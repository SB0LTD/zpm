//! @zpm/ps5gfx draw — a PS5 draw's state in the engine's terms.
//!
//! state.sig says what the registers mean, in the console's own terms.
//! gfxapi's engine takes a draw in its own (raster.Draw): GL's window,
//! whose rows count up from the bottom, blend factors as linear forms,
//! one mask of the bits a draw leaves alone. This file is the step
//! between, one small conversion at a time, each answering null where
//! the engine has nothing to match so that the renderer can leave the
//! draw out and say why.
//!
//! The picture is the same either way up: the engine's row y is the
//! console's row `height - y`, and an image over a target's memory is
//! told its first row is the top one. So what goes round clockwise on
//! the console's screen goes round clockwise in the engine's window too.
//!
//! Allocation-free; pure.

const std = @import("std");
const ps5 = @import("ps5");
const gfxapi = @import("gfxapi");
const state = @import("state.sig");

const raster = gfxapi.raster;
const engine = gfxapi.engine;
const PRIMITIVE = ps5.agc.shader.PRIMITIVE;

/// The engine's primitive for the console's; null: one the engine does
/// not draw (rectangles and quads, patches, the kinds with neighbours).
pub fn topology(kind: u32) ?raster.Topology {
    return switch (kind) {
        PRIMITIVE.POINTS => .points,
        PRIMITIVE.LINES => .lines,
        PRIMITIVE.LINE_STRIP => .line_strip,
        PRIMITIVE.LINE_LOOP => .line_loop,
        PRIMITIVE.TRIANGLES => .triangles,
        PRIMITIVE.TRIANGLE_STRIP => .strip,
        // (a polygon is drawn as a fan from its first corner)
        PRIMITIVE.TRIANGLE_FAN, PRIMITIVE.POLYGON => .fan,
        else => null,
    };
}

/// A viewport as the engine takes one: window = ndc * half + center, and
/// depth = ndc * scale + bias, kept to `zmin..zmax`.
pub const Viewport = struct {
    center: [2]f32,
    half: [2]f32,
    depth_scale: f32,
    depth_bias: f32,
    zmin: f32,
    zmax: f32,
};

/// `v` for a target `height` rows tall. The depth range a game set is
/// kept; one that holds nothing (as a queue starts: both ends 0) is taken
/// as 0 to 1.
pub fn viewport(v: state.Viewport, height: u32) Viewport {
    const h: f32 = @floatFromInt(height);
    const whole = !(v.zmax > v.zmin);
    return .{
        .center = .{ v.offset[0], h - v.offset[1] },
        .half = .{ v.scale[0], -v.scale[1] },
        .depth_scale = v.scale[2],
        .depth_bias = v.offset[2],
        .zmin = if (whole) 0 else v.zmin,
        .zmax = if (whole) 1 else v.zmax,
    };
}

/// The pixels a viewport covers, as the console counts them. Null when
/// the transform is off: the viewport is then no part of the target.
/// (The engine draws inside the viewport alone; the console goes on past
/// it as far as its guard band, which is not modelled here.)
pub fn box(v: state.Viewport) ?state.Rect {
    if (!v.transform) return null;
    // (kept to what a target can be before a float becomes an integer)
    const lim: f32 = 32768;
    const x0 = @floor(std.math.clamp(v.offset[0] - @abs(v.scale[0]), -lim, lim));
    const x1 = @ceil(std.math.clamp(v.offset[0] + @abs(v.scale[0]), -lim, lim));
    const y0 = @floor(std.math.clamp(v.offset[1] - @abs(v.scale[1]), -lim, lim));
    const y1 = @ceil(std.math.clamp(v.offset[1] + @abs(v.scale[1]), -lim, lim));
    if (!(x1 > x0) or !(y1 > y0)) return .{};
    return .{ .x0 = @intFromFloat(x0), .y0 = @intFromFloat(y0), .x1 = @intFromFloat(x1), .y1 = @intFromFloat(y1) };
}

/// A rectangle of the console's pixels (y down) as the engine's (rows
/// from the bottom of a target `height` tall). Null when it holds no
/// pixel of the target.
pub fn rect(r: state.Rect, width: u32, height: u32) ?engine.Rect {
    const all: state.Rect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(width), .y1 = @intCast(height) };
    const in = r.meet(all);
    if (in.empty()) return null;
    return .{
        .x0 = @intCast(in.x0),
        .y0 = height - @as(u32, @intCast(in.y1)),
        .x1 = @intCast(in.x1),
        .y1 = height - @as(u32, @intCast(in.y0)),
    };
}

/// Which faces are dropped (bit 0 front, bit 1 back) and which way a
/// front face goes round.
pub const Faces = struct {
    cull: u2,
    front_ccw: bool,
};

pub fn faces(r: state.Raster) Faces {
    return .{
        .cull = @as(u2, @intFromBool(r.cull_front)) | (@as(u2, @intFromBool(r.cull_back)) << 1),
        .front_ccw = !r.front_clockwise,
    };
}

/// The engine's image format for a colour target; null: a layout the
/// engine cannot draw into.
pub fn format(t: state.Target) ?engine.Format {
    return switch (t.bytes4() orelse return null) {
        .rgba => .rgba8,
        .bgra => .bgra8,
    };
}

/// The bits of a pixel a draw leaves as they are: the channels the
/// target's write mask has off (red is bit 0 of `write`).
pub fn keep(f: engine.Format, write: u4) u32 {
    // (the byte red, green, blue and alpha are at in the pixel's word)
    const at: [4]u5 = if (f == .bgra8) .{ 16, 8, 0, 24 } else .{ 0, 8, 16, 24 };
    var bits: u32 = 0;
    for (0..4) |c| {
        if (((write >> @intCast(c)) & 1) == 0) bits |= @as(u32, 0xFF) << at[c];
    }
    return bits;
}

const one = [4]f32{ 1, 1, 1, 1 };

const Made = struct { form: raster.Factor, gl: u32 };

/// A blend factor as the engine's linear form and GL's number for it.
/// Null: the two-colour factors (a second colour from the pixel shader),
/// which the engine has no blending for, and numbers that are no factor.
fn factor(code: u8, c: [4]f32, for_alpha: bool) ?Made {
    const F = state.FACTOR;
    return switch (code) {
        F.ZERO => .{ .form = .{}, .gl = 0 },
        F.ONE => .{ .form = .{ .c = one }, .gl = 1 },
        F.SRC_COLOR => .{ .form = .{ .ks = 1 }, .gl = 0x0300 },
        F.ONE_MINUS_SRC_COLOR => .{ .form = .{ .c = one, .ks = -1 }, .gl = 0x0301 },
        F.SRC_ALPHA => .{ .form = .{ .ksa = 1 }, .gl = 0x0302 },
        F.ONE_MINUS_SRC_ALPHA => .{ .form = .{ .c = one, .ksa = -1 }, .gl = 0x0303 },
        F.DST_ALPHA => .{ .form = .{ .kda = 1 }, .gl = 0x0304 },
        F.ONE_MINUS_DST_ALPHA => .{ .form = .{ .c = one, .kda = -1 }, .gl = 0x0305 },
        F.DST_COLOR => .{ .form = .{ .kd = 1 }, .gl = 0x0306 },
        F.ONE_MINUS_DST_COLOR => .{ .form = .{ .c = one, .kd = -1 }, .gl = 0x0307 },
        // (for colour the least of the shader's alpha and what the
        // target's leaves, which the engine does apart: Blend.saturate;
        // for alpha it is one)
        F.SRC_ALPHA_SATURATE => .{ .form = .{ .c = if (for_alpha) one else .{ 0, 0, 0, 0 } }, .gl = 0x0308 },
        F.CONSTANT_COLOR => .{ .form = .{ .c = c }, .gl = 0x8001 },
        F.ONE_MINUS_CONSTANT_COLOR => .{ .form = .{ .c = .{ 1 - c[0], 1 - c[1], 1 - c[2], 1 - c[3] } }, .gl = 0x8002 },
        F.CONSTANT_ALPHA => .{ .form = .{ .c = .{ c[3], c[3], c[3], c[3] } }, .gl = 0x8003 },
        F.ONE_MINUS_CONSTANT_ALPHA => .{ .form = .{ .c = .{ 1 - c[3], 1 - c[3], 1 - c[3], 1 - c[3] } }, .gl = 0x8004 },
        else => null,
    };
}

fn equation(code: u8) ?raster.Equation {
    const C = state.COMBINE;
    return switch (code) {
        C.ADD => .add,
        C.SUBTRACT => .subtract,
        C.MIN => .min,
        C.MAX => .max,
        C.REVERSE_SUBTRACT => .reverse_subtract,
        else => null,
    };
}

/// A target's blending as the engine's. Null: a factor or a rule the
/// engine has none for (the renderer leaves such a draw out).
pub fn blend(b: state.Blend) ?raster.Blend {
    const src_rgb = factor(b.color_src, b.constant, false) orelse return null;
    const dst_rgb = factor(b.color_dst, b.constant, false) orelse return null;
    const src_a = factor(b.alpha_src, b.constant, true) orelse return null;
    const dst_a = factor(b.alpha_dst, b.constant, true) orelse return null;
    // (the engine does "saturate" for the shader's colour alone)
    if (b.color_dst == state.FACTOR.SRC_ALPHA_SATURATE) return null;
    return .{
        .src_rgb = src_rgb.form,
        .dst_rgb = dst_rgb.form,
        .src_a = src_a.form,
        .dst_a = dst_a.form,
        .saturate = b.color_src == state.FACTOR.SRC_ALPHA_SATURATE,
        .eq_rgb = equation(b.color_op) orelse return null,
        .eq_a = equation(b.alpha_op) orelse return null,
        .gl = .{ src_rgb.gl, dst_rgb.gl, src_a.gl, dst_a.gl },
        .constant = b.constant,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "primitives the engine draws, and the ones it does not" {
    try testing.expectEqual(@as(?raster.Topology, .triangles), topology(PRIMITIVE.TRIANGLES));
    try testing.expectEqual(@as(?raster.Topology, .strip), topology(PRIMITIVE.TRIANGLE_STRIP));
    try testing.expectEqual(@as(?raster.Topology, .fan), topology(PRIMITIVE.TRIANGLE_FAN));
    try testing.expectEqual(@as(?raster.Topology, .fan), topology(PRIMITIVE.POLYGON));
    try testing.expectEqual(@as(?raster.Topology, .points), topology(PRIMITIVE.POINTS));
    try testing.expectEqual(@as(?raster.Topology, .lines), topology(PRIMITIVE.LINES));
    try testing.expectEqual(@as(?raster.Topology, .line_strip), topology(PRIMITIVE.LINE_STRIP));
    try testing.expectEqual(@as(?raster.Topology, .line_loop), topology(PRIMITIVE.LINE_LOOP));
    for ([_]u32{ PRIMITIVE.NONE, PRIMITIVE.RECTANGLES, PRIMITIVE.RECTANGLES_OLD, PRIMITIVE.QUADS, PRIMITIVE.QUAD_STRIP, PRIMITIVE.PATCHES, PRIMITIVE.TRIANGLES_ADJACENT, 8, 63 }) |k| {
        try testing.expectEqual(@as(?raster.Topology, null), topology(k));
    }
}

/// Where the engine's viewport puts a point of clip space (after the
/// divide), as a console's pixel: x, and y counted from the top.
fn onScreen(v: Viewport, height: u32, ndc: [2]f32) [2]f32 {
    const h: f32 = @floatFromInt(height);
    return .{ ndc[0] * v.half[0] + v.center[0], h - (ndc[1] * v.half[1] + v.center[1]) };
}

test "a viewport lands where the console's own arithmetic puts it" {
    // 1280 x 720, y up in clip space: the console's pixel is
    // ndc * scale + offset, with a negative y scale.
    const v: state.Viewport = .{ .scale = .{ 640, -360, 0.5 }, .offset = .{ 640, 360, 0.5 }, .zmin = 0.1, .zmax = 0.9, .zero_to_one = false, .depth_clamp = false };
    const e = viewport(v, 720);
    for ([_][2]f32{ .{ -1, 1 }, .{ 1, -1 }, .{ 0, 0 }, .{ 0.25, -0.5 } }) |p| {
        const want = [2]f32{ p[0] * v.scale[0] + v.offset[0], p[1] * v.scale[1] + v.offset[1] };
        try testing.expectEqual(want, onScreen(e, 720, p));
    }
    // (the top left of clip space is the top left pixel)
    try testing.expectEqual([2]f32{ 0, 0 }, onScreen(e, 720, .{ -1, 1 }));
    try testing.expectEqual(@as(f32, 0.5), e.depth_scale);
    try testing.expectEqual(@as(f32, 0.5), e.depth_bias);
    try testing.expectEqual(@as(f32, 0.1), e.zmin);
    try testing.expectEqual(@as(f32, 0.9), e.zmax);

    // A viewport that is part of the target, y down in clip space.
    const part: state.Viewport = .{ .scale = .{ 100, 50, 1 }, .offset = .{ 300, 200, 0 }, .zmin = 0, .zmax = 0, .zero_to_one = true, .depth_clamp = false };
    const p = viewport(part, 720);
    try testing.expectEqual([2]f32{ 200, 150 }, onScreen(p, 720, .{ -1, -1 }));
    try testing.expectEqual([2]f32{ 400, 250 }, onScreen(p, 720, .{ 1, 1 }));
    // (a depth range that holds nothing: 0 to 1)
    try testing.expectEqual(@as(f32, 0), p.zmin);
    try testing.expectEqual(@as(f32, 1), p.zmax);
    try testing.expectEqual(@as(f32, 1), p.depth_scale);
    try testing.expectEqual(@as(f32, 0), p.depth_bias);
}

test "a scissor's rows are counted from the bottom, and what is outside the target is cut" {
    try testing.expectEqual(engine.Rect{ .x0 = 10, .y0 = 720 - 100, .x1 = 200, .y1 = 720 - 20 }, rect(.{ .x0 = 10, .y0 = 20, .x1 = 200, .y1 = 100 }, 1280, 720).?);
    try testing.expectEqual(engine.Rect{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 }, rect(.{ .x0 = -5, .y0 = -5, .x1 = 16384, .y1 = 16384 }, 1280, 720).?);
    // (the top row alone is the engine's last row)
    try testing.expectEqual(engine.Rect{ .x0 = 0, .y0 = 719, .x1 = 1280, .y1 = 720 }, rect(.{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 1 }, 1280, 720).?);
    try testing.expect(rect(.{}, 1280, 720) == null);
    try testing.expect(rect(.{ .x0 = 1280, .y0 = 0, .x1 = 1400, .y1 = 10 }, 1280, 720) == null);
    try testing.expect(rect(.{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }, 0, 0) == null);
}

test "faces, the write mask, the target's format" {
    var r: state.Raster = .{ .cull_front = false, .cull_back = true, .front_clockwise = true, .fill = true, .provoke_last = false, .samples_log2 = 0 };
    try testing.expectEqual(Faces{ .cull = 2, .front_ccw = false }, faces(r));
    r = .{ .cull_front = true, .cull_back = false, .front_clockwise = false, .fill = true, .provoke_last = false, .samples_log2 = 0 };
    try testing.expectEqual(Faces{ .cull = 1, .front_ccw = true }, faces(r));

    // Every channel written: nothing kept. Red off: its byte kept, which
    // is the first byte or the third by the format.
    try testing.expectEqual(@as(u32, 0), keep(.rgba8, 0xF));
    try testing.expectEqual(@as(u32, 0x0000_00FF), keep(.rgba8, 0xE));
    try testing.expectEqual(@as(u32, 0x00FF_0000), keep(.bgra8, 0xE));
    try testing.expectEqual(@as(u32, 0xFF00_0000), keep(.rgba8, 0x7));
    try testing.expectEqual(@as(u32, 0xFF00_0000), keep(.bgra8, 0x7));
    try testing.expectEqual(@as(u32, 0x0000_FF00), keep(.bgra8, 0xD));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), keep(.rgba8, 0));

    var t: state.Target = .{
        .address = 0x1000,
        .width = 8,
        .height = 8,
        .format = state.COLOR.RGBA8,
        .number = state.NUMBER.UNORM,
        .swap = state.SWAP.STANDARD,
        .tiling = 0,
        .samples_log2 = 0,
        .mip = 0,
        .first_slice = 0,
        .last_slice = 0,
        .dimension = 1,
        .write = 0xF,
        .shader = 0xF,
    };
    try testing.expectEqual(@as(?engine.Format, .rgba8), format(t));
    t.swap = state.SWAP.ALTERNATE;
    try testing.expectEqual(@as(?engine.Format, .bgra8), format(t));
    t.format = state.COLOR.RGBA16;
    try testing.expectEqual(@as(?engine.Format, null), format(t));
}

/// What a blend gives for one channel, by the engine's own rule for a
/// factor: c + ks * s + kd * d + ksa * s.a + kda * d.a.
fn weigh(f: raster.Factor, ch: usize, s: [4]f32, d: [4]f32) f32 {
    return f.c[ch] + f.ks * s[ch] + f.kd * d[ch] + f.ksa * s[3] + f.kda * d[3];
}

test "blending: each factor as the engine's form gives the factor's own value" {
    const F = state.FACTOR;
    const s = [4]f32{ 0.5, 0.25, 0.125, 0.75 };
    const d = [4]f32{ 0.1, 0.2, 0.3, 0.4 };
    const c = [4]f32{ 0.9, 0.8, 0.7, 0.6 };
    // (red: channel 0)
    const cases = [_]struct { code: u8, want: f32, gl: u32 }{
        .{ .code = F.ZERO, .want = 0, .gl = 0 },
        .{ .code = F.ONE, .want = 1, .gl = 1 },
        .{ .code = F.SRC_COLOR, .want = 0.5, .gl = 0x0300 },
        .{ .code = F.ONE_MINUS_SRC_COLOR, .want = 0.5, .gl = 0x0301 },
        .{ .code = F.SRC_ALPHA, .want = 0.75, .gl = 0x0302 },
        .{ .code = F.ONE_MINUS_SRC_ALPHA, .want = 0.25, .gl = 0x0303 },
        .{ .code = F.DST_ALPHA, .want = 0.4, .gl = 0x0304 },
        .{ .code = F.ONE_MINUS_DST_ALPHA, .want = 0.6, .gl = 0x0305 },
        .{ .code = F.DST_COLOR, .want = 0.1, .gl = 0x0306 },
        .{ .code = F.ONE_MINUS_DST_COLOR, .want = 0.9, .gl = 0x0307 },
        .{ .code = F.CONSTANT_COLOR, .want = 0.9, .gl = 0x8001 },
        .{ .code = F.ONE_MINUS_CONSTANT_COLOR, .want = 1.0 - 0.9, .gl = 0x8002 },
        .{ .code = F.CONSTANT_ALPHA, .want = 0.6, .gl = 0x8003 },
        .{ .code = F.ONE_MINUS_CONSTANT_ALPHA, .want = 1.0 - 0.6, .gl = 0x8004 },
    };
    for (cases) |case| {
        const b = blend(.{ .color_src = case.code, .color_dst = F.ZERO, .color_op = 0, .alpha_src = F.ONE, .alpha_dst = F.ZERO, .alpha_op = 0, .constant = c }).?;
        try testing.expectApproxEqAbs(case.want, weigh(b.src_rgb, 0, s, d), 1e-6);
        try testing.expectEqual(case.gl, b.gl[0]);
        try testing.expect(!b.saturate);
        try testing.expectEqual(c, b.constant);
    }
    // (a colour factor differs by channel: green of "source colour")
    const sc = blend(.{ .color_src = F.SRC_COLOR, .color_dst = F.DST_COLOR, .color_op = 0, .alpha_src = F.SRC_ALPHA, .alpha_dst = F.ONE_MINUS_SRC_ALPHA, .alpha_op = 0, .constant = c }).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), weigh(sc.src_rgb, 1, s, d), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), weigh(sc.dst_rgb, 1, s, d), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), weigh(sc.src_a, 3, s, d), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), weigh(sc.dst_a, 3, s, d), 1e-6);
    try testing.expectEqual([4]u32{ 0x0300, 0x0306, 0x0302, 0x0303 }, sc.gl);

    // Saturate: the engine's own flag for colour, one for alpha.
    const sat = blend(.{ .color_src = F.SRC_ALPHA_SATURATE, .color_dst = F.ONE, .color_op = 0, .alpha_src = F.SRC_ALPHA_SATURATE, .alpha_dst = F.ZERO, .alpha_op = 0, .constant = c }).?;
    try testing.expect(sat.saturate);
    try testing.expectApproxEqAbs(@as(f32, 1), weigh(sat.src_a, 3, s, d), 1e-6);

    // The rules.
    const C = state.COMBINE;
    for ([_]struct { code: u8, want: raster.Equation }{
        .{ .code = C.ADD, .want = .add },
        .{ .code = C.SUBTRACT, .want = .subtract },
        .{ .code = C.MIN, .want = .min },
        .{ .code = C.MAX, .want = .max },
        .{ .code = C.REVERSE_SUBTRACT, .want = .reverse_subtract },
    }) |case| {
        const b = blend(.{ .color_src = F.ONE, .color_dst = F.ONE, .color_op = case.code, .alpha_src = F.ONE, .alpha_dst = F.ONE, .alpha_op = C.ADD, .constant = c }).?;
        try testing.expectEqual(case.want, b.eq_rgb);
        try testing.expectEqual(raster.Equation.add, b.eq_a);
    }

    // What the engine has no blending for.
    try testing.expect(blend(.{ .color_src = F.SRC1_COLOR, .color_dst = F.ZERO, .color_op = 0, .alpha_src = F.ONE, .alpha_dst = F.ZERO, .alpha_op = 0, .constant = c }) == null);
    try testing.expect(blend(.{ .color_src = F.ONE, .color_dst = F.ZERO, .color_op = 0, .alpha_src = F.ONE, .alpha_dst = F.ONE_MINUS_SRC1_ALPHA, .alpha_op = 0, .constant = c }) == null);
    try testing.expect(blend(.{ .color_src = F.ONE, .color_dst = F.SRC_ALPHA_SATURATE, .color_op = 0, .alpha_src = F.ONE, .alpha_dst = F.ZERO, .alpha_op = 0, .constant = c }) == null);
    try testing.expect(blend(.{ .color_src = 11, .color_dst = F.ZERO, .color_op = 0, .alpha_src = F.ONE, .alpha_dst = F.ZERO, .alpha_op = 0, .constant = c }) == null);
    try testing.expect(blend(.{ .color_src = F.ONE, .color_dst = F.ZERO, .color_op = 5, .alpha_src = F.ONE, .alpha_dst = F.ZERO, .alpha_op = 0, .constant = c }) == null);
}

test "the pixels a viewport covers" {
    const whole: state.Viewport = .{ .scale = .{ 640, -360, 1 }, .offset = .{ 640, 360, 0 }, .zmin = 0, .zmax = 1, .zero_to_one = true, .depth_clamp = false };
    try testing.expectEqual(state.Rect{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 }, box(whole).?);
    // A tile of an atlas, y down in clip space, on half pixels.
    const tile: state.Viewport = .{ .scale = .{ 50.5, 25, 1 }, .offset = .{ 300, 200, 0 }, .zmin = 0, .zmax = 1, .zero_to_one = true, .depth_clamp = false };
    try testing.expectEqual(state.Rect{ .x0 = 249, .y0 = 175, .x1 = 351, .y1 = 225 }, box(tile).?);
    // The transform off: no rectangle. A scale that is not a number, or
    // none at all: no pixels.
    var off = whole;
    off.transform = false;
    try testing.expect(box(off) == null);
    var bad = whole;
    bad.scale[0] = std.math.nan(f32);
    try testing.expect(box(bad).?.empty());
    bad.scale[0] = 0;
    try testing.expect(box(bad).?.empty());
    // Far outside what a target can be: kept in range, no overflow.
    var far = whole;
    far.offset = .{ 1e30, -1e30, 0 };
    try testing.expect(box(far).?.empty() or box(far).?.x0 >= 32768 - 1);
}
