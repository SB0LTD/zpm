//! @zpm/gpu draw — rectangles drawn by a GPU's graphics pipeline, the same
//! on every GPU: what a compositor draws with.
//!
//! A rectangle in window pixels is a solid color, an image (a texture times
//! a color) or a mask (an 8-bit coverage texture times a color), replacing
//! the target's pixels or blended over them (premultiplied alpha), inside a
//! scissor; and the same with a rounded rectangle's coverage worked out per
//! pixel (a filled one, a stroked one, an image inside one), a mask times
//! a gradient (a path filled with a paint), a soft dithered disc (a glow)
//! and a rounded rectangle's soft shadow. One pass is begin(target), the rectangles in order, then submit.
//!
//! Three things live here, above every GPU's own pipeline (the Adreno's in
//! adreno/draw.sig, the RTX's in nvidia/draw.sig, each behind an adapter
//! beside this file):
//!
//! - the types and `Renderer`, the calls through a table of functions;
//! - `Reference`, the same calls worked out on the CPU: the arithmetic a
//!   GPU's result is held to, within 2 of 255 a channel;
//! - `cases`, the self-test's passes as data, and `selfTest`, which draws
//!   them on any Renderer and says what the hardware did differently.
//!
//! The rules. A rectangle covers the pixels whose centres are inside it
//! (x1 and y1 are past the end). Texture coordinates are unnormalized
//! texels with centres at halves, clamped to the texture's edge. Colors
//! are premultiplied, four floats (r, g, b, a) in [0, 1]; `over` is the
//! color plus the pixel times one less the color's alpha. A result is
//! clamped to [0, 1] and rounded to the target's 8 bits.
//!
//! Allocation-free: the Reference draws into memory the caller gives it.

const std = @import("std");

// ── The types ───────────────────────────────────────────────────────────────

pub const Format = enum(u8) {
    /// R, G, B, A.
    rgba8,
    /// B, G, R, A (a little-endian 0xAARRGGBB word).
    bgra8,
    /// One byte, read as (v, 0, 0, 1).
    r8,

    pub fn bytes(f: Format) u32 {
        return if (f == .r8) 1 else 4;
    }
};

/// What a pass draws to: `height` rows of `pitch` bytes at `va`.
pub const Target = struct {
    va: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: Format = .bgra8,
};

pub const Filter = enum(u8) { nearest = 0, linear = 1 };

/// A texture a rectangle samples, with unnormalized coordinates (texels),
/// clamped to its edge; one level, rows of `pitch` bytes.
pub const Texture = struct {
    va: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: Format = .bgra8,
    filter: Filter = .linear,
    /// Its alpha reads as one whatever its bytes hold (an opaque picture
    /// whose fourth byte is not kept).
    no_alpha: bool = false,
};

pub const Blend = enum(u8) {
    /// The color replaces the pixel.
    replace,
    /// Premultiplied source over: color + pixel * (1 - color's alpha).
    over,
};

/// What a rectangle's pixels are.
pub const Kind = enum(u8) { solid, image, mask, rrect, ring, image_rr, mask_grad, glow, shadow };

/// A rectangle's corners: x0, y0, x1, y1 (pixels; x1 and y1 past the end).
pub const Rect = [4]f32;

/// Premultiplied r, g, b, a.
pub const Color = [4]f32;

/// A rounded rectangle as the coverage programs take it: its centre, its
/// half size less the radius, the radius.
pub const Shape = struct {
    cx: f32,
    cy: f32,
    kx: f32,
    ky: f32,
    rad: f32,

    /// The rectangle (x, y, w, h) with corners of `radius`, the radius
    /// held to half the smaller side.
    pub fn of(x: f32, y: f32, w: f32, h: f32, radius: f32) Shape {
        const hw = w / 2;
        const hh = h / 2;
        const rad = @min(radius, @min(hw, hh));
        return .{ .cx = x + hw, .cy = y + hh, .kx = hw - rad, .ky = hh - rad, .rad = rad };
    }

    /// The signed distance at (px, py): the programs' arithmetic.
    pub fn distance(s: Shape, px: f32, py: f32) f32 {
        const qx = @abs(px - s.cx) - s.kx;
        const qy = @abs(py - s.cy) - s.ky;
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - s.rad;
    }

    /// How much of the pixel centred at (px, py) the shape covers: half
    /// less the distance, between 0 and 1.
    pub fn coverage(s: Shape, px: f32, py: f32) f32 {
        return std.math.clamp(0.5 - s.distance(px, py), 0, 1);
    }
};

/// Just under half a step of 255. A software compositor that blends in
/// 8-bit fixed point drops the fraction where a GPU's blender rounds to
/// the nearest step; a source color this much lower blends to what such a
/// compositor has (a whole step stays where it is). Without it every such
/// layer is half a step up, and layers add up. A glow has it built in.
pub const DROP: f32 = 0.49 / 255.0;

/// A paint that changes across a shape (maskGradient). With q1 and q2 two
/// lines in window pixels (x's and y's factors, then a constant), t is
/// |(q1, q2)| * around + q1 * along, held to [0, 1]. The color is `a` at 0,
/// `b` at `mid` and `c` at 1 (straight, not premultiplied: r, g, b, a).
pub const Gradient = struct {
    q1: [3]f32,
    q2: [3]f32 = .{ 0, 0, 0 },
    along: f32 = 1,
    around: f32 = 0,
    a: Color,
    /// (two stops: `b` is halfway between them at a `mid` of a half)
    b: Color,
    c: Color,
    mid: f32 = 0.5,

    /// The color at pixel (px, py): the programs' arithmetic.
    pub fn at(g: Gradient, px: f32, py: f32) Color {
        const v1 = g.q1[0] * px + g.q1[1] * py + g.q1[2];
        const v2 = g.q2[0] * px + g.q2[1] * py + g.q2[2];
        const t = std.math.clamp(@sqrt(v1 * v1 + v2 * v2) * g.around + v1 * g.along, 0, 1);
        const t1 = std.math.clamp(t / g.mid, 0, 1);
        const t2 = std.math.clamp((t - g.mid) / (1 - g.mid), 0, 1);
        var out: Color = undefined;
        for (0..4) |i| out[i] = g.a[i] + (g.b[i] - g.a[i]) * t1 + (g.c[i] - g.b[i]) * t2;
        return out;
    }
};

/// The 4 x 4 ordered dither a glow's fall is spread with, in [-0.5, 0.5):
/// the pixel's column and row, each from 0 to 3.
pub const bayer4 = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

/// A glow's alpha at the pixel (x, y), whose centre is half a pixel on:
/// `alpha` inside `inner`, falling by a smooth step to nothing at `outer`,
/// plus the dither (9 steps of 255 wide) less half a step, held to [0, 1];
/// nothing at or past `outer`. The programs' arithmetic.
pub fn glowAlpha(x: u32, y: u32, cx: f32, cy: f32, inner: f32, outer: f32, alpha: f32) f32 {
    const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
    const d2 = dx * dx + dy * dy;
    if (!(d2 < outer * outer)) return 0;
    var t = std.math.clamp((inner - @sqrt(d2)) / @max(outer - inner, 1e-6) + 1, 0, 1);
    t = t * t * (3 - 2 * t);
    const dither = ((bayer4[(y & 3) * 4 + (x & 3)] + 0.5) / 16.0 - 0.5) * 9.0 / 255.0;
    return std.math.clamp(t * alpha + dither - 0.5 / 255.0, 0, 1);
}

/// What a shadow leaves alone, and gfx's ways. Deeper than three sigmas
/// inside the shape nothing is drawn: what casts the shadow covers it.
/// gfx's shadow differs in two places that a frame compared with gfx's
/// must have too, both in its corner rows (those above `above` or from
/// `below` down):
/// - the pixels from column `from_x` right that are that deep are drawn
///   whole;
/// - left of column `left` and from `right` on (its corners), the
///   distance is taken to the nearest `step` (its table's), counted from
///   three sigmas inside;
/// - once a corner row has reached a pixel that deep, gfx skips on to
///   three sigmas from the right edge, over the right corner's shallower
///   pixels too: from column `run_from` (the row's deepest pixel right of
///   its straight part) up to `run_end`, nothing is drawn in a row whose
///   pixel at `run_from` is that deep.
/// The defaults have none of them.
pub const Deep = struct {
    from_x: f32 = 1e30,
    above: f32 = -1e30,
    below: f32 = 1e30,
    left: f32 = -1e30,
    right: f32 = 1e30,
    step: f32 = 0,
    run_from: f32 = 0,
    run_end: f32 = -1e30,
};

/// The part of a Gaussian of `sigma` beyond the distance `d` (gfx's
/// gaussEdge: Abramowitz and Stegun's erf): the programs' arithmetic.
pub fn gaussEdge(d: f32, sigma: f32) f32 {
    const x = d / (sigma * 1.41421356);
    const t = 1 / (1 + 0.3275911 * @abs(x));
    const h = 0.5 * (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp2(-x * x * 1.44269504);
    return if (x >= 0) h else 1 - h;
}

/// A shadow's alpha at the pixel (x, y): `alpha` times gaussEdge of the
/// signed distance to `s`, less half a step of 255 (gfx takes it down to a
/// whole step, and this is the middle of what that loses); deeper than
/// three sigmas inside, nothing, or `alpha` (254 of 255 of it) where
/// `deep` says so.
pub fn shadowAlpha(x: u32, y: u32, s: Shape, sigma: f32, alpha: f32, deep: Deep) f32 {
    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const ext = 3 * sigma;
    var d = s.distance(px, py);
    const corner_row = py < deep.above or py > deep.below;
    if (corner_row and px > deep.run_from and px < deep.run_end and s.distance(deep.run_from + 0.5, py) < -ext) return 0;
    if (d < -ext) return if (px > deep.from_x and corner_row) alpha * (254.0 / 255.0) else 0;
    if (deep.step > 0 and corner_row and (px < deep.left or px > deep.right)) {
        d = @floor((d + ext) / deep.step + 0.5) * deep.step - ext;
    }
    return alpha * @max(gaussEdge(d, sigma) - 0.5 / 255.0, 0);
}

pub const Error = error{
    OutOfMemory,
    SubmitFailed,
    Timeout,
    DeviceLost,
    BadStream,
    /// The pass's rectangles did not fit the stream.
    StreamFull,
    /// Its textures' descriptors did not fit their buffer.
    StateFull,
    BadKernel,
    /// A rectangle before begin(), or begin() twice.
    NoPass,
};

pub const Fence = u64;

/// Memory on the device: a target's pixels, a texture's texels.
pub const Buffer = struct {
    va: u64 = 0,
    cpu: []u8 = &.{},
    handle: u32 = 0,
};

pub const Stats = struct {
    rects: u32 = 0,
    /// Changes of program, and of texture.
    programs: u32 = 0,
    bindings: u32 = 0,
    stream_dwords: u32 = 0,
};

// ── The renderer ────────────────────────────────────────────────────────────

/// A GPU's pipeline, or the Reference: the calls of a pass, and the
/// device's memory for what a pass reads and draws to.
pub const Renderer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin: *const fn (ctx: *anyopaque, t: Target) void,
        scissor: *const fn (ctx: *anyopaque, x0: u32, y0: u32, x1: u32, y1: u32) void,
        fill: *const fn (ctx: *anyopaque, rc: Rect, color: Color, b: Blend) void,
        image: *const fn (ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, tint: Color, b: Blend) void,
        mask: *const fn (ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, color: Color, b: Blend) void,
        rrect: *const fn (ctx: *anyopaque, rc: Rect, s: Shape, color: Color, b: Blend) void,
        ring: *const fn (ctx: *anyopaque, rc: Rect, outer: Shape, inner: ?Shape, color: Color, b: Blend) void,
        imageRR: *const fn (ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, tint: Color, s: Shape, b: Blend) void,
        maskGradient: *const fn (ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, g: Gradient, opacity: f32, b: Blend) void,
        glow: *const fn (ctx: *anyopaque, rc: Rect, cx: f32, cy: f32, inner: f32, outer: f32, color: Color, b: Blend) void,
        shadow: *const fn (ctx: *anyopaque, rc: Rect, s: Shape, sigma: f32, color: Color, deep: Deep, b: Blend) void,
        submit: *const fn (ctx: *anyopaque) Error!Fence,
        resubmit: *const fn (ctx: *anyopaque) Error!Fence,
        wait: *const fn (ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void,
        stats: *const fn (ctx: *anyopaque) Stats,
        alloc: *const fn (ctx: *anyopaque, size: usize) ?Buffer,
        free: *const fn (ctx: *anyopaque, b: Buffer) void,
        toDevice: *const fn (ctx: *anyopaque, b: Buffer, offset: usize, len: usize) void,
        fromDevice: *const fn (ctx: *anyopaque, b: Buffer, offset: usize, len: usize) void,
    };

    /// Start a pass on `t`: its pixels as they are, the scissor the whole
    /// target.
    pub fn begin(r: Renderer, t: Target) void {
        r.vtable.begin(r.ctx, t);
    }

    /// Draw only inside [x0, x1) x [y0, y1) from here on.
    pub fn scissor(r: Renderer, x0: u32, y0: u32, x1: u32, y1: u32) void {
        r.vtable.scissor(r.ctx, x0, y0, x1, y1);
    }

    /// A rectangle of one color.
    pub fn fill(r: Renderer, rc: Rect, color: Color, b: Blend) void {
        r.vtable.fill(r.ctx, rc, color, b);
    }

    /// `t`'s texels from (uv[0], uv[1]) to (uv[2], uv[3]) across the
    /// rectangle, each times `tint`.
    pub fn image(r: Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, b: Blend) void {
        r.vtable.image(r.ctx, rc, t, uv, tint, b);
    }

    /// `color` times the coverage in `t` (an r8 texture), as text is drawn.
    pub fn mask(r: Renderer, rc: Rect, t: Texture, uv: [4]f32, color: Color, b: Blend) void {
        r.vtable.mask(r.ctx, rc, t, uv, color, b);
    }

    /// `color` times the coverage of the rounded rectangle `s`, over the
    /// pixels of `rc` (s's bounds, or less).
    pub fn rrect(r: Renderer, rc: Rect, s: Shape, color: Color, b: Blend) void {
        r.vtable.rrect(r.ctx, rc, s, color, b);
    }

    /// `color` times the coverage of `outer` less that of `inner` (the
    /// same centre; null: nothing taken out): a stroke.
    pub fn ring(r: Renderer, rc: Rect, outer: Shape, inner: ?Shape, color: Color, b: Blend) void {
        r.vtable.ring(r.ctx, rc, outer, inner, color, b);
    }

    /// image, times the coverage of the rounded rectangle `s` (in window
    /// pixels, as `rc`).
    pub fn imageRR(r: Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, s: Shape, b: Blend) void {
        r.vtable.imageRR(r.ctx, rc, t, uv, tint, s, b);
    }

    /// `g`'s color at each pixel times the coverage in `t` (an r8
    /// texture, a texel a pixel) times `opacity`: a path filled with a
    /// gradient. The gradient's colors are straight; what is blended is
    /// premultiplied.
    pub fn maskGradient(r: Renderer, rc: Rect, t: Texture, uv: [4]f32, g: Gradient, opacity: f32, b: Blend) void {
        r.vtable.maskGradient(r.ctx, rc, t, uv, g, opacity, b);
    }

    /// A soft disc at (cx, cy): `color` (straight r, g, b, and its alpha)
    /// at glowAlpha, less DROP once multiplied.
    pub fn glow(r: Renderer, rc: Rect, cx: f32, cy: f32, inner: f32, outer: f32, color: Color, b: Blend) void {
        r.vtable.glow(r.ctx, rc, cx, cy, inner, outer, color, b);
    }

    /// The soft shadow of the rounded rectangle `s`: `color` (straight
    /// r, g, b, and its alpha) at shadowAlpha, less DROP once multiplied.
    pub fn shadow(r: Renderer, rc: Rect, s: Shape, sigma: f32, color: Color, deep: Deep, b: Blend) void {
        r.vtable.shadow(r.ctx, rc, s, sigma, color, deep, b);
    }

    /// End the pass and hand it to the GPU. The target's pixels are in
    /// memory once the fence is done (fromDevice them before the CPU reads).
    pub fn submit(r: Renderer) Error!Fence {
        return r.vtable.submit(r.ctx);
    }

    /// The pass submit() ended, handed over again (the device refused it:
    /// its ring was busy with another context's work).
    pub fn resubmit(r: Renderer) Error!Fence {
        return r.vtable.resubmit(r.ctx);
    }

    pub fn wait(r: Renderer, f: Fence, timeout_us: u64) Error!void {
        return r.vtable.wait(r.ctx, f, timeout_us);
    }

    /// submit, and wait for it.
    pub fn run(r: Renderer, timeout_us: u64) Error!void {
        const f = try r.submit();
        try r.wait(f, timeout_us);
    }

    /// The pass last recorded: its rectangles and what they took.
    pub fn stats(r: Renderer) Stats {
        return r.vtable.stats(r.ctx);
    }

    pub fn alloc(r: Renderer, size: usize) ?Buffer {
        return r.vtable.alloc(r.ctx, size);
    }

    pub fn free(r: Renderer, b: Buffer) void {
        r.vtable.free(r.ctx, b);
    }

    /// The CPU wrote `b`'s bytes: the GPU reads them from here on.
    pub fn toDevice(r: Renderer, b: Buffer, offset: usize, len: usize) void {
        r.vtable.toDevice(r.ctx, b, offset, len);
    }

    /// The GPU wrote `b`'s bytes: the CPU reads them from here on.
    pub fn fromDevice(r: Renderer, b: Buffer, offset: usize, len: usize) void {
        r.vtable.fromDevice(r.ctx, b, offset, len);
    }
};

// ── The arithmetic ──────────────────────────────────────────────────────────
// What every pipeline is held to, and what the emulated GPUs do: the
// rasterizer's coverage, the texture unit's filter, the blender.

/// The pixels along one axis whose centres are in [a, b): from the first
/// to one past the last.
pub fn span(a: f32, b: f32, limit: u32) [2]u32 {
    const lo = std.math.clamp(@ceil(a - 0.5), 0, @as(f32, @floatFromInt(limit)));
    const hi = std.math.clamp(@ceil(b - 0.5), 0, @as(f32, @floatFromInt(limit)));
    return .{ @intFromFloat(lo), @intFromFloat(@max(hi, lo)) };
}

/// A texel's four floats: its bytes over 255, in r, g, b, a.
pub fn texel(bytes: []const u8, t: Texture, x: u32, y: u32) Color {
    const at = @as(usize, y) * t.pitch + @as(usize, x) * t.format.bytes();
    const one: f32 = 1.0 / 255.0;
    var c: Color = switch (t.format) {
        .r8 => .{ @as(f32, @floatFromInt(bytes[at])) * one, 0, 0, 1 },
        .rgba8 => .{
            @as(f32, @floatFromInt(bytes[at])) * one,
            @as(f32, @floatFromInt(bytes[at + 1])) * one,
            @as(f32, @floatFromInt(bytes[at + 2])) * one,
            @as(f32, @floatFromInt(bytes[at + 3])) * one,
        },
        .bgra8 => .{
            @as(f32, @floatFromInt(bytes[at + 2])) * one,
            @as(f32, @floatFromInt(bytes[at + 1])) * one,
            @as(f32, @floatFromInt(bytes[at])) * one,
            @as(f32, @floatFromInt(bytes[at + 3])) * one,
        },
    };
    if (t.no_alpha) c[3] = 1;
    return c;
}

fn clampTexel(v: f32, size: u32) u32 {
    const top: f32 = @floatFromInt(size - 1);
    return @intFromFloat(std.math.clamp(v, 0, top));
}

/// The texture at (u, v), in texels: the texel the point is in, or the
/// four around it weighed by how near their centres are; past the edge,
/// the edge's.
pub fn sample(bytes: []const u8, t: Texture, u: f32, v: f32) Color {
    if (t.filter == .nearest) return texel(bytes, t, clampTexel(@floor(u), t.width), clampTexel(@floor(v), t.height));
    const fu = u - 0.5;
    const fv = v - 0.5;
    const x0f = @floor(fu);
    const y0f = @floor(fv);
    const wx = fu - x0f;
    const wy = fv - y0f;
    const x0 = clampTexel(x0f, t.width);
    const x1 = clampTexel(x0f + 1, t.width);
    const y0 = clampTexel(y0f, t.height);
    const y1 = clampTexel(y0f + 1, t.height);
    const a = texel(bytes, t, x0, y0);
    const b = texel(bytes, t, x1, y0);
    const c = texel(bytes, t, x0, y1);
    const d = texel(bytes, t, x1, y1);
    var out: Color = undefined;
    for (&out, 0..) |*o, i| {
        const top = a[i] + (b[i] - a[i]) * wx;
        const bottom = c[i] + (d[i] - c[i]) * wx;
        o.* = top + (bottom - top) * wy;
    }
    return out;
}

/// A channel as the target keeps it: not a number is 0, then [0, 1], then
/// the nearest of 256 steps.
pub fn quantize(v: f32) u8 {
    if (v != v) return 0;
    return @intFromFloat(@floor(std.math.clamp(v, 0, 1) * 255 + 0.5));
}

/// The pixel at `at` in a target's bytes after `src` is drawn there.
pub fn blendInto(bytes: []u8, at: usize, format: Format, src: Color, b: Blend) void {
    const one: f32 = 1.0 / 255.0;
    // (where each of r, g, b, a is among the pixel's bytes)
    const order: [4]u8 = if (format == .bgra8) .{ 2, 1, 0, 3 } else .{ 0, 1, 2, 3 };
    if (format == .r8) {
        const dst = @as(f32, @floatFromInt(bytes[at])) * one;
        bytes[at] = quantize(if (b == .over) src[0] + dst * (1 - src[3]) else src[0]);
        return;
    }
    for (order, 0..) |byte, ch| {
        const dst = @as(f32, @floatFromInt(bytes[at + byte])) * one;
        bytes[at + byte] = quantize(if (b == .over) src[ch] + dst * (1 - src[3]) else src[ch]);
    }
}

/// Whether two pixels are within `tol` of 255 in each of their four bytes.
pub fn near(want: u32, got: u32, tol: i32) bool {
    inline for (.{ 0, 8, 16, 24 }) |sh| {
        const a: i32 = @intCast((want >> sh) & 0xff);
        const b: i32 = @intCast((got >> sh) & 0xff);
        if (@abs(a - b) > tol) return false;
    }
    return true;
}

// ── The reference: the calls on the CPU ─────────────────────────────────────

/// The same passes worked out on the CPU, each rectangle drawn as it is
/// asked for, into memory the caller gave: what a GPU's pixels are
/// compared with. Its buffers are handed out in order from `mem` and
/// returned only all together (reset).
pub const Reference = struct {
    mem: []u8,
    used: usize = 0,
    target: ?Target = null,
    /// The scissor: x0, y0, x1, y1.
    sc: [4]u32 = .{ 0, 0, 0, 0 },
    pass: Stats = .{},
    last: Stats = .{},
    fence: Fence = 0,
    /// A pass named memory that is not this model's.
    bad: bool = false,

    /// Where its buffers are, as a GPU's addresses would be.
    pub const BASE: u64 = 0x1000_0000;

    pub fn reset(m: *Reference) void {
        m.used = 0;
        m.target = null;
        m.bad = false;
    }

    pub fn renderer(m: *Reference) Renderer {
        return .{ .ctx = m, .vtable = &vtable };
    }

    const vtable = Renderer.VTable{
        .begin = &vBegin,
        .scissor = &vScissor,
        .fill = &vFill,
        .image = &vImage,
        .mask = &vMask,
        .rrect = &vRrect,
        .ring = &vRing,
        .imageRR = &vImageRR,
        .maskGradient = &vMaskGradient,
        .glow = &vGlow,
        .shadow = &vShadow,
        .submit = &vSubmit,
        .resubmit = &vResubmit,
        .wait = &vWait,
        .stats = &vStats,
        .alloc = &vAlloc,
        .free = &vFree,
        .toDevice = &vSync,
        .fromDevice = &vSync,
    };

    fn of(ctx: *anyopaque) *Reference {
        return @ptrCast(@alignCast(ctx));
    }

    /// The bytes at a buffer's address, if they are this model's.
    fn bytesAt(m: *Reference, va: u64, len: usize) ?[]u8 {
        if (va < BASE) return null;
        const off = va - BASE;
        if (off > m.used or len > m.used - off) return null;
        return m.mem[@intCast(off)..][0..len];
    }

    const Paint = struct {
        kind: Kind,
        color: Color,
        tex: ?Texture = null,
        uv: [4]f32 = .{ 0, 0, 0, 0 },
        shape: ?Shape = null,
        inner: ?Shape = null,
        grad: ?Gradient = null,
        /// mask_grad: the opacity. glow: its centre, inner and outer radius.
        /// shadow: its sigma.
        num: [4]f32 = .{ 0, 0, 0, 0 },
        deep: Deep = .{},
    };

    fn draw(m: *Reference, rc: Rect, p: Paint, b: Blend) void {
        const t = m.target orelse return;
        if (!(rc[2] > rc[0] and rc[3] > rc[1])) return;
        m.pass.rects += 1;
        const out = m.bytesAt(t.va, @as(usize, t.pitch) * t.height) orelse {
            m.bad = true;
            return;
        };
        var texels: []const u8 = &.{};
        if (p.tex) |tx| texels = m.bytesAt(tx.va, @as(usize, tx.pitch) * (tx.height - 1) + @as(usize, tx.width) * tx.format.bytes()) orelse {
            m.bad = true;
            return;
        };
        var xs = span(rc[0], rc[2], t.width);
        var ys = span(rc[1], rc[3], t.height);
        xs = .{ @max(xs[0], m.sc[0]), @min(xs[1], m.sc[2]) };
        ys = .{ @max(ys[0], m.sc[1]), @min(ys[1], m.sc[3]) };
        const du = (p.uv[2] - p.uv[0]) / (rc[2] - rc[0]);
        const dv = (p.uv[3] - p.uv[1]) / (rc[3] - rc[1]);
        var y = ys[0];
        while (y < ys[1]) : (y += 1) {
            var x = xs[0];
            while (x < xs[1]) : (x += 1) {
                // (the pixel's centre, and the texture coordinates there)
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const u = p.uv[0] + (px - rc[0]) * du;
                const v = p.uv[1] + (py - rc[1]) * dv;
                var c = p.color;
                switch (p.kind) {
                    .solid => {},
                    .image => {
                        const s = sample(texels, p.tex.?, u, v);
                        for (&c, s) |*o, sv| o.* *= sv;
                    },
                    .mask => {
                        const s = sample(texels, p.tex.?, u, v);
                        for (&c) |*o| o.* *= s[0];
                    },
                    .rrect => {
                        const cov = p.shape.?.coverage(px, py);
                        for (&c) |*o| o.* *= cov;
                    },
                    .ring => {
                        const outer = p.shape.?.coverage(px, py);
                        const inner = if (p.inner) |in| in.coverage(px, py) else 0;
                        const cov = @max(outer - inner, 0);
                        for (&c) |*o| o.* *= cov;
                    },
                    .image_rr => {
                        const s = sample(texels, p.tex.?, u, v);
                        const cov = p.shape.?.coverage(px, py);
                        for (&c, s) |*o, sv| o.* *= sv * cov;
                    },
                    .mask_grad => {
                        const s = sample(texels, p.tex.?, u, v);
                        const g = p.grad.?.at(px, py);
                        const al = g[3] * s[0] * p.num[0];
                        c = .{ g[0] * al, g[1] * al, g[2] * al, al };
                    },
                    .glow => {
                        const al = glowAlpha(x, y, p.num[0], p.num[1], p.num[2], p.num[3], p.color[3]);
                        for (c[0..3]) |*o| o.* = @max(o.* * al - DROP, 0);
                        c[3] = al;
                    },
                    .shadow => {
                        const al = shadowAlpha(x, y, p.shape.?, p.num[0], p.color[3], p.deep);
                        for (c[0..3]) |*o| o.* = @max(o.* * al - DROP, 0);
                        c[3] = al;
                    },
                }
                blendInto(out, @as(usize, y) * t.pitch + @as(usize, x) * t.format.bytes(), t.format, c, b);
            }
        }
    }

    fn vBegin(ctx: *anyopaque, t: Target) void {
        const m = of(ctx);
        m.target = t;
        m.sc = .{ 0, 0, t.width, t.height };
        m.pass = .{};
    }

    fn vScissor(ctx: *anyopaque, x0: u32, y0: u32, x1: u32, y1: u32) void {
        const m = of(ctx);
        const t = m.target orelse return;
        m.sc = .{ @min(x0, t.width), @min(y0, t.height), @min(x1, t.width), @min(y1, t.height) };
    }

    fn vFill(ctx: *anyopaque, rc: Rect, color: Color, b: Blend) void {
        of(ctx).draw(rc, .{ .kind = .solid, .color = color }, b);
    }

    fn vImage(ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, tint: Color, b: Blend) void {
        of(ctx).draw(rc, .{ .kind = .image, .color = tint, .tex = t, .uv = uv }, b);
    }

    fn vMask(ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, color: Color, b: Blend) void {
        of(ctx).draw(rc, .{ .kind = .mask, .color = color, .tex = t, .uv = uv }, b);
    }

    fn vRrect(ctx: *anyopaque, rc: Rect, s: Shape, color: Color, b: Blend) void {
        of(ctx).draw(rc, .{ .kind = .rrect, .color = color, .shape = s }, b);
    }

    fn vRing(ctx: *anyopaque, rc: Rect, outer: Shape, inner: ?Shape, color: Color, b: Blend) void {
        of(ctx).draw(rc, .{ .kind = .ring, .color = color, .shape = outer, .inner = inner }, b);
    }

    fn vImageRR(ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, tint: Color, s: Shape, b: Blend) void {
        if (!(uv[2] != uv[0] and uv[3] != uv[1])) return;
        of(ctx).draw(rc, .{ .kind = .image_rr, .color = tint, .tex = t, .uv = uv, .shape = s }, b);
    }

    fn vMaskGradient(ctx: *anyopaque, rc: Rect, t: Texture, uv: [4]f32, g: Gradient, opacity: f32, b: Blend) void {
        of(ctx).draw(rc, .{ .kind = .mask_grad, .color = .{ 0, 0, 0, 0 }, .tex = t, .uv = uv, .grad = g, .num = .{ opacity, 0, 0, 0 } }, b);
    }

    fn vGlow(ctx: *anyopaque, rc: Rect, cx: f32, cy: f32, inner: f32, outer: f32, color: Color, b: Blend) void {
        if (!(outer > 0)) return;
        of(ctx).draw(rc, .{ .kind = .glow, .color = color, .num = .{ cx, cy, inner, outer } }, b);
    }

    fn vShadow(ctx: *anyopaque, rc: Rect, s: Shape, sigma: f32, color: Color, deep: Deep, b: Blend) void {
        if (!(sigma > 0)) return;
        of(ctx).draw(rc, .{ .kind = .shadow, .color = color, .shape = s, .num = .{ sigma, 0, 0, 0 }, .deep = deep }, b);
    }

    fn vSubmit(ctx: *anyopaque) Error!Fence {
        const m = of(ctx);
        if (m.target == null) return error.NoPass;
        m.target = null;
        m.last = m.pass;
        if (m.bad) {
            m.bad = false;
            return error.BadStream;
        }
        m.fence += 1;
        return m.fence;
    }

    fn vResubmit(ctx: *anyopaque) Error!Fence {
        const m = of(ctx);
        if (m.target != null or m.fence == 0) return error.NoPass;
        return m.fence;
    }

    fn vWait(_: *anyopaque, _: Fence, _: u64) Error!void {}

    fn vStats(ctx: *anyopaque) Stats {
        return of(ctx).last;
    }

    fn vAlloc(ctx: *anyopaque, size: usize) ?Buffer {
        const m = of(ctx);
        const at = std.mem.alignForward(usize, m.used, 64);
        if (at > m.mem.len or size > m.mem.len - at) return null;
        m.used = at + size;
        @memset(m.mem[at..][0..size], 0);
        return .{ .va = BASE + at, .cpu = m.mem[at..][0..size] };
    }

    fn vFree(_: *anyopaque, _: Buffer) void {}

    fn vSync(_: *anyopaque, _: Buffer, _: usize, _: usize) void {}
};

// ── The cases ───────────────────────────────────────────────────────────────
// The self-test's passes as data: each a pass of its own, with the pixels
// it must leave. A GPU's pipeline, an emulated GPU and the Reference all
// draw the same ones.

/// The self-test's target.
pub const CASE_W = 64;
pub const CASE_H = 32;

/// The self-test's textures: an 8 x 4 picture (red rises with x, green
/// with y) read texel for texel or filtered, and a 4 x 2 coverage mask.
pub const CaseTexture = enum(u8) { nearest, linear, mask };

/// A texel of the 8 x 4 picture, as a bgra8 word.
pub fn caseTexel(x: u32, y: u32) u32 {
    return 0xff000000 | ((x * 32) << 16) | ((y * 64) << 8);
}

/// A byte of the 4 x 2 mask.
pub fn caseMask(x: u32) u8 {
    return @intCast(x * 85);
}

pub const Op = union(enum) {
    scissor: [4]u32,
    fill: struct { rc: Rect, color: Color, blend: Blend = .replace },
    image: struct { rc: Rect, tex: CaseTexture, uv: [4]f32, tint: Color, blend: Blend = .replace },
    mask: struct { rc: Rect, uv: [4]f32, color: Color, blend: Blend = .over },
    rrect: struct { rc: Rect, shape: Shape, color: Color, blend: Blend = .over },
    ring: struct { rc: Rect, outer: Shape, inner: ?Shape, color: Color, blend: Blend = .over },
    image_rr: struct { rc: Rect, tex: CaseTexture, uv: [4]f32, tint: Color, shape: Shape, blend: Blend = .over },
    mask_grad: struct { rc: Rect, uv: [4]f32, grad: Gradient, opacity: f32 = 1, blend: Blend = .over },
    glow: struct { rc: Rect, cx: f32, cy: f32, inner: f32, outer: f32, color: Color, blend: Blend = .over },
    shadow: struct { rc: Rect, shape: Shape, sigma: f32, color: Color, deep: Deep = .{}, blend: Blend = .over },
};

/// A pixel a case must leave: within `tol` of 255 a byte.
pub const Probe = struct { x: u32, y: u32, want: u32, tol: i32 = 1 };

pub const Case = struct {
    name: []const u8,
    ops: []const Op,
    probes: []const Probe,
};

const WHOLE = Rect{ 0, 0, CASE_W, CASE_H };
const BLUE = Color{ 0, 0, 0.5, 1 };
const BLACK = Color{ 0, 0, 0, 1 };
const WHITE = Color{ 1, 1, 1, 1 };
const blue: u32 = 0xff000080;
const black: u32 = 0xff000000;
const white: u32 = 0xffffffff;

pub const cases = [_]Case{
    .{
        .name = "one color over the whole target",
        .ops = &.{.{ .fill = .{ .rc = WHOLE, .color = BLUE } }},
        .probes = &.{ .{ .x = 0, .y = 0, .want = blue }, .{ .x = 63, .y = 0, .want = blue }, .{ .x = 0, .y = 31, .want = blue }, .{ .x = 63, .y = 31, .want = blue }, .{ .x = 31, .y = 15, .want = blue } },
    },
    .{
        .name = "a rectangle's edges",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLUE } }, .{ .fill = .{ .rc = .{ 4, 2, 20, 10 }, .color = .{ 1, 0, 0, 1 } } } },
        .probes = &.{ .{ .x = 4, .y = 2, .want = 0xffff0000 }, .{ .x = 19, .y = 9, .want = 0xffff0000 }, .{ .x = 3, .y = 2, .want = blue }, .{ .x = 4, .y = 1, .want = blue }, .{ .x = 20, .y = 9, .want = blue }, .{ .x = 19, .y = 10, .want = blue } },
    },
    .{
        .name = "the scissor",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLUE } }, .{ .scissor = .{ 40, 20, 50, 30 } }, .{ .fill = .{ .rc = WHOLE, .color = WHITE } } },
        .probes = &.{ .{ .x = 40, .y = 20, .want = white }, .{ .x = 49, .y = 29, .want = white }, .{ .x = 39, .y = 20, .want = blue }, .{ .x = 50, .y = 29, .want = blue }, .{ .x = 40, .y = 19, .want = blue } },
    },
    .{
        .name = "a half-transparent color blended over",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLUE } }, .{ .fill = .{ .rc = .{ 4, 2, 20, 10 }, .color = .{ 1, 0, 0, 1 } } }, .{ .fill = .{ .rc = .{ 10, 6, 30, 16 }, .color = .{ 0, 0.5, 0, 0.5 }, .blend = .over } } },
        .probes = &.{ .{ .x = 10, .y = 6, .want = 0xff808000, .tol = 2 }, .{ .x = 25, .y = 12, .want = 0xff008040, .tol = 2 }, .{ .x = 9, .y = 6, .want = 0xffff0000 }, .{ .x = 30, .y = 12, .want = blue } },
    },
    .{
        .name = "an image, texel for texel",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .image = .{ .rc = .{ 2, 1, 10, 5 }, .tex = .nearest, .uv = .{ 0, 0, 8, 4 }, .tint = WHITE } } },
        .probes = &.{ .{ .x = 2, .y = 1, .want = caseTexel(0, 0) }, .{ .x = 9, .y = 1, .want = caseTexel(7, 0) }, .{ .x = 2, .y = 4, .want = caseTexel(0, 3) }, .{ .x = 9, .y = 4, .want = caseTexel(7, 3) }, .{ .x = 5, .y = 2, .want = caseTexel(3, 1) }, .{ .x = 10, .y = 1, .want = black } },
    },
    .{
        .name = "an image stretched, filtered",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .image = .{ .rc = .{ 20, 4, 36, 12 }, .tex = .linear, .uv = .{ 0, 0, 8, 4 }, .tint = WHITE } } },
        .probes = &.{ .{ .x = 27, .y = 7, .want = 0xff000000 | ((32 * 3 + 8) << 16) | ((64 + 16) << 8), .tol = 3 }, .{ .x = 20, .y = 4, .want = caseTexel(0, 0), .tol = 3 }, .{ .x = 35, .y = 11, .want = caseTexel(7, 3), .tol = 3 } },
    },
    .{
        .name = "an image at half opacity over",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .image = .{ .rc = .{ 40, 20, 48, 24 }, .tex = .nearest, .uv = .{ 0, 0, 8, 4 }, .tint = .{ 0.5, 0.5, 0.5, 0.5 }, .blend = .over } } },
        .probes = &.{ .{ .x = 47, .y = 23, .want = 0xff000000 | ((7 * 32 / 2) << 16) | ((3 * 64 / 2) << 8), .tol = 2 }, .{ .x = 40, .y = 20, .want = black, .tol = 2 } },
    },
    .{
        .name = "a coverage mask (text)",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = .{ 0, 0, 1, 1 } } }, .{ .mask = .{ .rc = .{ 8, 8, 12, 10 }, .uv = .{ 0, 0, 4, 2 }, .color = WHITE } } },
        .probes = &.{ .{ .x = 8, .y = 8, .want = 0xff0000ff, .tol = 2 }, .{ .x = 9, .y = 8, .want = 0xff5555ff, .tol = 2 }, .{ .x = 10, .y = 9, .want = 0xffaaaaff, .tol = 2 }, .{ .x = 11, .y = 9, .want = white, .tol = 2 } },
    },
    .{
        .name = "a filled rounded rectangle",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .rrect = .{ .rc = .{ 4, 3, 28, 17 }, .shape = Shape.of(4, 3, 24, 14, 5), .color = WHITE } } },
        .probes = &.{ .{ .x = 16, .y = 10, .want = white, .tol = 2 }, .{ .x = 4, .y = 10, .want = white, .tol = 2 }, .{ .x = 4, .y = 3, .want = black, .tol = 2 }, .{ .x = 27, .y = 16, .want = black, .tol = 2 }, .{ .x = 3, .y = 10, .want = black } },
    },
    .{
        .name = "a stroked rounded rectangle",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .ring = .{ .rc = .{ 34, 4, 60, 24 }, .outer = Shape.of(34, 4, 26, 20, 6), .inner = Shape.of(36, 6, 22, 16, 4), .color = .{ 0, 1, 0, 1 } } } },
        .probes = &.{ .{ .x = 34, .y = 14, .want = 0xff00ff00, .tol = 2 }, .{ .x = 47, .y = 4, .want = 0xff00ff00, .tol = 2 }, .{ .x = 47, .y = 14, .want = black, .tol = 2 }, .{ .x = 34, .y = 4, .want = black, .tol = 2 } },
    },
    .{
        .name = "an image inside a rounded rectangle",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .image_rr = .{ .rc = .{ 8, 20, 16, 24 }, .tex = .nearest, .uv = .{ 0, 0, 8, 4 }, .tint = WHITE, .shape = Shape.of(8, 20, 8, 4, 2) } } },
        .probes = &.{ .{ .x = 12, .y = 22, .want = caseTexel(4, 2), .tol = 2 }, .{ .x = 11, .y = 21, .want = caseTexel(3, 1), .tol = 2 }, .{ .x = 8, .y = 20, .want = black, .tol = 40 }, .{ .x = 16, .y = 22, .want = black } },
    },
    .{
        // (red at the mask's left edge to blue at its right, through the
        // mask's 0, 85, 170, 255)
        .name = "a mask times a gradient",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .mask_grad = .{ .rc = .{ 8, 8, 12, 10 }, .uv = .{ 0, 0, 4, 2 }, .grad = .{ .q1 = .{ 0.25, 0, -2 }, .a = .{ 1, 0, 0, 1 }, .b = .{ 0.5, 0, 0.5, 1 }, .c = .{ 0, 0, 1, 1 } } } } },
        .probes = &.{ .{ .x = 11, .y = 9, .want = 0xff2000df, .tol = 2 }, .{ .x = 10, .y = 8, .want = 0xff40006a, .tol = 2 }, .{ .x = 9, .y = 9, .want = 0xff350020, .tol = 2 }, .{ .x = 8, .y = 8, .want = black, .tol = 2 }, .{ .x = 12, .y = 9, .want = black } },
    },
    .{
        // (white: whole at the centre, a smooth step out to 12 pixels,
        // dithered; nothing past that)
        .name = "a glow",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = BLACK } }, .{ .glow = .{ .rc = .{ 20, 4, 44, 28 }, .cx = 32, .cy = 16, .inner = 4, .outer = 12, .color = WHITE } } },
        .probes = &.{ .{ .x = 32, .y = 15, .want = 0xffffffff, .tol = 2 }, .{ .x = 39, .y = 16, .want = 0xff979797, .tol = 3 }, .{ .x = 22, .y = 6, .want = black }, .{ .x = 45, .y = 16, .want = black } },
    },
    .{
        // (black, two pixels of sigma, under a 32 x 16 shape: 40% at the
        // edge, nothing deeper than six pixels inside)
        .name = "a soft shadow",
        .ops = &.{ .{ .fill = .{ .rc = WHOLE, .color = WHITE } }, .{ .shadow = .{ .rc = .{ 10, 2, 54, 30 }, .shape = Shape.of(16, 8, 32, 16, 4), .sigma = 2, .color = .{ 0, 0, 0, 1 } } } },
        .probes = &.{ .{ .x = 32, .y = 7, .want = 0xff999999, .tol = 3 }, .{ .x = 32, .y = 10, .want = 0xff1b1b1b, .tol = 3 }, .{ .x = 32, .y = 16, .want = 0xffffffff }, .{ .x = 9, .y = 16, .want = 0xffffffff } },
    },
};

/// The self-test's textures on a device: the 8 x 4 picture at the start
/// of `buf`, the mask 256 bytes in, both in rows of 64 bytes (a GPU's
/// texture unit may not read narrower rows as given: the Adreno X1-45
/// read rows of 32 as 64).
pub const CaseTextures = struct {
    buf: Buffer,

    pub const BYTES = 4096;

    pub fn fill(buf: Buffer) CaseTextures {
        for (0..4) |y| for (0..8) |x| {
            std.mem.writeInt(u32, buf.cpu[y * 64 + x * 4 ..][0..4], caseTexel(@intCast(x), @intCast(y)), .little);
        };
        for (0..2) |y| for (0..4) |x| {
            buf.cpu[256 + y * 64 + x] = caseMask(@intCast(x));
        };
        return .{ .buf = buf };
    }

    pub fn get(c: CaseTextures, which: CaseTexture) Texture {
        return switch (which) {
            .nearest => .{ .va = c.buf.va, .width = 8, .height = 4, .pitch = 64, .format = .bgra8, .filter = .nearest },
            .linear => .{ .va = c.buf.va, .width = 8, .height = 4, .pitch = 64, .format = .bgra8, .filter = .linear },
            .mask => .{ .va = c.buf.va + 256, .width = 4, .height = 2, .pitch = 64, .format = .r8, .filter = .nearest },
        };
    }
};

/// Record one case's pass on `r` (begin to its last rectangle; the caller
/// submits).
pub fn record(r: Renderer, t: Target, tex: CaseTextures, c: Case) void {
    r.begin(t);
    for (c.ops) |op| switch (op) {
        .scissor => |s| r.scissor(s[0], s[1], s[2], s[3]),
        .fill => |f| r.fill(f.rc, f.color, f.blend),
        .image => |i| r.image(i.rc, tex.get(i.tex), i.uv, i.tint, i.blend),
        .mask => |m| r.mask(m.rc, tex.get(.mask), m.uv, m.color, m.blend),
        .rrect => |p| r.rrect(p.rc, p.shape, p.color, p.blend),
        .ring => |p| r.ring(p.rc, p.outer, p.inner, p.color, p.blend),
        .image_rr => |i| r.imageRR(i.rc, tex.get(i.tex), i.uv, i.tint, i.shape, i.blend),
        .mask_grad => |m| r.maskGradient(m.rc, tex.get(.mask), m.uv, m.grad, m.opacity, m.blend),
        .glow => |g| r.glow(g.rc, g.cx, g.cy, g.inner, g.outer, g.color, g.blend),
        .shadow => |s| r.shadow(s.rc, s.shape, s.sigma, s.color, s.deep, s.blend),
    };
}

// ── The self-test: the pipeline on the real GPU ─────────────────────────────
// The cases drawn on any Renderer and compared with the values the
// arithmetic gives, case by case and each in a pass of its own, so the log
// names the first thing the hardware does differently (or the pass it does
// not finish). Then how fast it fills.

pub const SelfTest = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// A pass did not finish (the GPU hung or faulted): the cases after
    /// it did not run.
    lost: bool = false,
    /// The fill rate measured (megapixels a second; 0: not measured).
    mpx_per_s: u32 = 0,
};

pub const Log = *const fn (line: []const u8) void;

fn say(log: Log, comptime fmt: []const u8, args: anytype) void {
    var buf: [240]u8 = undefined;
    log(std.fmt.bufPrint(&buf, fmt, args) catch "draw self-test: (a line too long)");
}

/// Draw the cases on `r` (a renderer already started) and say what
/// happened, a line a case; `now_us` (a clock) lets the last step measure
/// the fill rate.
pub fn selfTest(r: Renderer, log: Log, now_us: ?*const fn () u64) SelfTest {
    var res: SelfTest = .{};
    const pixels = r.alloc(CASE_W * CASE_H * 4) orelse return .{ .failed = 1 };
    defer r.free(pixels);
    const tex_buf = r.alloc(CaseTextures.BYTES) orelse return .{ .failed = 1 };
    defer r.free(tex_buf);
    const t = Target{ .va = pixels.va, .width = CASE_W, .height = CASE_H, .pitch = CASE_W * 4, .format = .bgra8 };
    const tex = CaseTextures.fill(tex_buf);
    r.toDevice(tex_buf, 0, CaseTextures.BYTES);
    say(log, "draw self-test: the graphics pipeline (rectangles, textures, blending, rounded shapes), a {d} x {d} target at 0x{x}", .{ CASE_W, CASE_H, pixels.va });

    for (cases) |c| {
        if (res.lost) break;
        say(log, "draw self-test: {s} ...", .{c.name});
        record(r, t, tex, c);
        r.run(2_000_000) catch |e| {
            const st = r.stats();
            say(log, "draw self-test: {s}: the pass did not finish ({s}, {d} dwords, {d} rectangles)", .{ c.name, @errorName(e), st.stream_dwords, st.rects });
            res.lost = e == error.Timeout or e == error.DeviceLost;
            res.failed += 1;
            continue;
        };
        const bytes = t.pitch * t.height;
        r.fromDevice(pixels, 0, bytes);
        const row = t.pitch;
        const ok = for (c.probes) |p| {
            const got = std.mem.readInt(u32, pixels.cpu[p.y * row + p.x * 4 ..][0..4], .little);
            if (!near(p.want, got, p.tol)) {
                const start = pixels.cpu[p.y * row ..];
                say(log, "draw self-test: {s}: pixel ({d}, {d}) is {x:0>8}, not {x:0>8}; the row starts {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
                    c.name,                                        p.x,                                            p.y,                                            got,                                             p.want,
                    std.mem.readInt(u32, start[0..4], .little), std.mem.readInt(u32, start[4..8], .little), std.mem.readInt(u32, start[8..12], .little), std.mem.readInt(u32, start[12..16], .little),
                });
                break false;
            }
        } else true;
        if (ok) res.passed += 1 else res.failed += 1;
    }

    // How fast it fills: a 1024 x 1024 target, an image the same size over
    // it once and a half-transparent color 31 times (32 megapixels blended).
    if (!res.lost and res.failed == 0) speed: {
        const clock = now_us orelse break :speed;
        const N = 1024;
        const big = r.alloc(N * N * 4) orelse break :speed;
        defer r.free(big);
        const src = r.alloc(N * N * 4) orelse break :speed;
        defer r.free(src);
        for (0..N * N) |i| std.mem.writeInt(u32, src.cpu[i * 4 ..][0..4], 0xff000000 | @as(u32, @truncate(i *% 2654435761)), .little);
        r.toDevice(src, 0, N * N * 4);
        const bt = Target{ .va = big.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8 };
        const st = Texture{ .va = src.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8, .filter = .linear };
        r.begin(bt);
        r.image(.{ 0, 0, N, N }, st, .{ 0, 0, N, N }, .{ 1, 1, 1, 1 }, .replace);
        for (0..31) |_| r.fill(.{ 0, 0, N, N }, .{ 0.01, 0.01, 0.01, 0.02 }, .over);
        say(log, "draw self-test: the fill rate ...", .{});
        const t0 = clock();
        r.run(5_000_000) catch |e| {
            say(log, "draw self-test: the fill rate: the pass did not finish ({s})", .{@errorName(e)});
            res.lost = true;
            res.failed += 1;
            break :speed;
        };
        const us = @max(clock() - t0, 1);
        res.mpx_per_s = @intCast(@min(@as(u64, 32) * N * N / us, std.math.maxInt(u32)));
        r.fromDevice(big, 0, 16);
        say(log, "draw self-test: 32 megapixels blended in {d} us: {d} megapixels a second (first pixel {x:0>8})", .{ us, res.mpx_per_s, std.mem.readInt(u32, big.cpu[0..4], .little) });
    }
    say(log, "draw self-test: {d} passed, {d} failed{s}", .{ res.passed, res.failed, if (res.lost) ", and the GPU did not finish a pass" else "" });
    return res;
}

/// The first pixel of two targets' bytes that differs by more than `tol`
/// of 255 in a byte (its index), or null: a GPU's pass against the
/// Reference's.
pub fn firstDifference(a: []const u8, b: []const u8, tol: u8) ?usize {
    for (a, b, 0..) |x, y, i| {
        const d = if (x > y) x - y else y - x;
        if (d > tol) return i / 4;
    }
    return null;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const T = struct {
    var mem: [64 * 1024]u8 = undefined;
    var model: Reference = .{ .mem = &mem };

    fn quiet(line: []const u8) void {
        if (std.mem.indexOf(u8, line, " is ") != null or std.mem.indexOf(u8, line, "did not") != null) std.debug.print("{s}\n", .{line});
    }
};

test "draw: the pixels a rectangle covers are those whose centres are inside" {
    try testing.expectEqual([2]u32{ 4, 20 }, span(4, 20, 64));
    // (a centre on the edge is inside at the start, outside at the end)
    try testing.expectEqual([2]u32{ 0, 2 }, span(0.5, 2.5, 64));
    try testing.expectEqual([2]u32{ 0, 2 }, span(0.4, 2.4, 64));
    try testing.expectEqual([2]u32{ 1, 3 }, span(0.6, 2.6, 64));
    try testing.expectEqual([2]u32{ 0, 64 }, span(-10, 100, 64));
    try testing.expectEqual([2]u32{ 5, 5 }, span(5.2, 5.4, 64));
}

test "draw: the texture unit: a texel's bytes, the nearest, the four around a point" {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 0xff204060, .little);
    std.mem.writeInt(u32, bytes[4..8], 0xff60a0e0, .little);
    std.mem.writeInt(u32, bytes[8..12], 0x80000000, .little);
    std.mem.writeInt(u32, bytes[12..16], 0x80000000, .little);
    var t = Texture{ .va = 0, .width = 2, .height = 2, .pitch = 8, .format = .bgra8, .filter = .nearest };
    const a = texel(&bytes, t, 0, 0);
    try testing.expectEqual(@as(u8, 0x20), quantize(a[0]));
    try testing.expectEqual(@as(u8, 0x40), quantize(a[1]));
    try testing.expectEqual(@as(u8, 0x60), quantize(a[2]));
    try testing.expectEqual(@as(u8, 0xff), quantize(a[3]));
    // nearest: the texel the point is in, the edge's past the edge
    try testing.expectEqual(@as(u8, 0x60), quantize(sample(&bytes, t, 1.2, 0.9)[0]));
    try testing.expectEqual(@as(u8, 0x60), quantize(sample(&bytes, t, 9, -3)[0]));
    // linear: half way between the two centres of the first row
    t.filter = .linear;
    try testing.expectEqual(@as(u8, 0x40), quantize(sample(&bytes, t, 1.0, 0.5)[0]));
    try testing.expectEqual(@as(u8, 0x20), quantize(sample(&bytes, t, 0.5, 0.5)[0]));
    // an opaque picture's alpha is one whatever its fourth byte holds
    t.no_alpha = true;
    try testing.expectEqual(@as(f32, 1), texel(&bytes, t, 0, 1)[3]);
    // one byte reads as (v, 0, 0, 1)
    const m = Texture{ .va = 0, .width = 4, .height = 1, .pitch = 4, .format = .r8, .filter = .nearest };
    const c = texel(&.{ 0, 85, 170, 255 }, m, 1, 0);
    try testing.expectEqual(@as(u8, 85), quantize(c[0]));
    try testing.expectEqual(@as(f32, 0), c[1]);
    try testing.expectEqual(@as(f32, 1), c[3]);
}

test "draw: the blender: replace, premultiplied over, both byte orders" {
    var px = [4]u8{ 0x80, 0x00, 0x00, 0xff }; // bgra8: blue 0x80
    blendInto(&px, 0, .bgra8, .{ 0, 0.5, 0, 0.5 }, .over);
    try testing.expect(near(0xff008040, std.mem.readInt(u32, &px, .little), 1));
    blendInto(&px, 0, .bgra8, .{ 1, 0, 0, 1 }, .replace);
    try testing.expectEqual(@as(u32, 0xffff0000), std.mem.readInt(u32, &px, .little));
    blendInto(&px, 0, .rgba8, .{ 1, 0, 0, 1 }, .replace);
    try testing.expectEqual([4]u8{ 0xff, 0, 0, 0xff }, px);
    // not a number is nothing; past one is one
    try testing.expectEqual(@as(u8, 0), quantize(std.math.nan(f32)));
    try testing.expectEqual(@as(u8, 255), quantize(7));
    try testing.expectEqual(@as(u8, 128), quantize(0.5));
}

test "draw: the reference passes every case" {
    T.model.reset();
    const res = selfTest(T.model.renderer(), &T.quiet, null);
    try testing.expectEqual(@as(u32, cases.len), res.passed);
    try testing.expectEqual(@as(u32, 0), res.failed);
    try testing.expect(!res.lost);
    try testing.expectEqual(@as(usize, 14), cases.len);
}

test "draw: a pass is a pass: nothing before begin, the scissor, memory that is not the model's" {
    T.model.reset();
    const r = T.model.renderer();
    try testing.expectError(error.NoPass, r.submit());
    const px = r.alloc(8 * 8 * 4).?;
    const t = Target{ .va = px.va, .width = 8, .height = 8, .pitch = 32 };
    // a rectangle outside a pass draws nothing
    r.fill(.{ 0, 0, 8, 8 }, .{ 1, 1, 1, 1 }, .replace);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, px.cpu[0..4], .little));
    r.begin(t);
    r.scissor(2, 2, 4, 4);
    r.fill(.{ 0, 0, 8, 8 }, .{ 1, 1, 1, 1 }, .replace);
    // (an empty rectangle is not one)
    r.fill(.{ 3, 3, 3, 9 }, .{ 1, 0, 0, 1 }, .replace);
    try r.run(0);
    try testing.expectEqual(@as(u32, 1), r.stats().rects);
    try testing.expectEqual(@as(u32, 0xffffffff), std.mem.readInt(u32, px.cpu[(2 * 8 + 2) * 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, px.cpu[(2 * 8 + 4) * 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, px.cpu[(1 * 8 + 2) * 4 ..][0..4], .little));
    // the pass again is the same fence; a target elsewhere is refused
    _ = try r.resubmit();
    r.begin(.{ .va = 0x42, .width = 8, .height = 8, .pitch = 32 });
    r.fill(.{ 0, 0, 8, 8 }, .{ 1, 1, 1, 1 }, .replace);
    try testing.expectError(error.BadStream, r.submit());
}

test "draw: a stroke with nothing taken out is the filled shape; two targets compared" {
    T.model.reset();
    const r = T.model.renderer();
    const a = r.alloc(32 * 24 * 4).?;
    const b = r.alloc(32 * 24 * 4).?;
    const s = Shape.of(4, 3, 24, 14, 5);
    r.begin(.{ .va = a.va, .width = 32, .height = 24, .pitch = 128 });
    r.fill(.{ 0, 0, 32, 24 }, .{ 0, 0, 0, 1 }, .replace);
    r.rrect(.{ 4, 3, 28, 17 }, s, .{ 1, 1, 1, 1 }, .over);
    try r.run(0);
    r.begin(.{ .va = b.va, .width = 32, .height = 24, .pitch = 128 });
    r.fill(.{ 0, 0, 32, 24 }, .{ 0, 0, 0, 1 }, .replace);
    r.ring(.{ 4, 3, 28, 17 }, s, null, .{ 1, 1, 1, 1 }, .over);
    try r.run(0);
    try testing.expectEqual(@as(?usize, null), firstDifference(a.cpu, b.cpu, 0));
    // the corner is rounded off, the middle whole
    try testing.expectEqual(@as(u32, 0xff000000), std.mem.readInt(u32, a.cpu[(3 * 32 + 4) * 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0xffffffff), std.mem.readInt(u32, a.cpu[(10 * 32 + 16) * 4 ..][0..4], .little));
    b.cpu[40] ^= 0x10;
    try testing.expectEqual(@as(?usize, 10), firstDifference(a.cpu, b.cpu, 2));
}
