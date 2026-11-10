//! @zpm/adreno draw — rectangles drawn by the Adreno's graphics pipeline,
//! over any Device (Galaxy's kernel driver, or EmuDevice in the tests).
//!
//! What a compositor draws with: a solid color, an image (a texture times a
//! color), a mask (an 8-bit coverage texture times a color), each a
//! rectangle in window pixels, replacing the target's pixels or blended
//! over them (premultiplied alpha), inside a scissor; and the same with a
//! rounded rectangle's coverage worked out per pixel (a filled one, a
//! stroked one, an image inside one). The rasterizer walks
//! the rectangle, the texture unit filters, the render backend blends: no
//! compute kernel, no per-pixel command lists.
//!
//! One pass is one command stream: begin(target), the rectangles in order,
//! then submit. The programs are four small pieces of ir3 (a vertex program
//! for a rectangle's two corners, a fragment program per kind), assembled
//! at init.
//!
//! Colors are premultiplied, four floats (r, g, b, a) in [0, 1]. The
//! hardware rounds to the target's 8 bits; a blend's result is the
//! blender's own arithmetic, within a step of 255 of the exact value.
//!
//! Allocation-free: three device buffers (the programs, the textures'
//! descriptors, the stream), sized at init.

const std = @import("std");
const ir3 = @import("ir3.sig");
const ir3_asm = @import("ir3_asm.sig");
const a7xx = @import("a7xx.sig");
const dr = @import("a7xx_draw.sig");
const device = @import("device.sig");

pub const Device = device.Device;
pub const Buffer = device.Buffer;
pub const Fence = device.Fence;
pub const Target = dr.Target;
pub const Texture = dr.Texture;
pub const Format = dr.Format;
pub const Filter = dr.Filter;
pub const Blend = dr.Blend;

pub const Error = device.Error || ir3_asm.Error || error{
    /// The pass's rectangles did not fit the stream.
    StreamFull,
    /// Its textures' descriptors did not fit their buffer.
    StateFull,
    BadKernel,
    /// A rectangle before begin(), or begin() twice.
    NoPass,
};

/// What a rectangle's pixels are.
pub const Kind = enum(u8) { solid, image, mask, rrect, ring, image_rr, mask_grad, glow, shadow };
const KINDS = 9;

/// A rectangle's corners: x0, y0, x1, y1 (pixels; x1 and y1 past the end).
pub const Rect = [4]f32;

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

/// Just under half a step of 255. gfx blends some things (a glow, a scrim)
/// dropping the fraction, where the blender rounds to the nearest step: a
/// source color this much lower blends to what gfx has (a whole step
/// stays where it is). Without it every such layer is half a step up on
/// gfx, and layers add up.
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
    b: Color,
    /// (two stops: `b` is halfway between them at a `mid` of a half)
    c: Color,
    mid: f32 = 0.5,

    /// The color at pixel (px, py): the program's arithmetic, for tests.
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

/// A rounded rectangle as the coverage programs take it: its centre, its
/// half size less the radius, the radius.
pub const Shape = struct {
    cx: f32,
    cy: f32,
    kx: f32,
    ky: f32,
    rad: f32,

    /// The rectangle (x, y, w, h) with corners of `radius`, the radius
    /// held to half the smaller side as gfx.sdRoundRect holds it.
    pub fn of(x: f32, y: f32, w: f32, h: f32, radius: f32) Shape {
        const hw = w / 2;
        const hh = h / 2;
        const rad = @min(radius, @min(hw, hh));
        return .{ .cx = x + hw, .cy = y + hh, .kx = hw - rad, .ky = hh - rad, .rad = rad };
    }

    /// The signed distance at (px, py): the programs' arithmetic, for tests.
    pub fn distance(s: Shape, px: f32, py: f32) f32 {
        const qx = @abs(px - s.cx) - s.kx;
        const qy = @abs(py - s.cy) - s.ky;
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - s.rad;
    }

    pub fn coverage(s: Shape, px: f32, py: f32) f32 {
        return std.math.clamp(0.5 - s.distance(px, py), 0, 1);
    }
};
/// Premultiplied r, g, b, a.
pub const Color = [4]f32;

// ── The programs ────────────────────────────────────────────────────────────
// They are the programs turnip's own clears and blits run (Mesa compiled
// them; the tests hold the words here to its): the vertex's index arrives
// in r0.x; the position leaves in r0.yzw and r1.x, the varyings (the
// texture coordinates) in r1.yz. A fragment's barycentrics arrive in
// r0.xy, and where it has a texture the pipeline has already sampled it
// at the varyings into r0.zw and r1.xy (a prefetch: the program has no
// sample instruction and reads the result through (sy)). Its color leaves
// in r0 (solid) or from r1.z.

/// c0: the first corner (x, y, u, v); c1: the second. Vertex 0 gets c0 and
/// vertex 1 gets c1; z is 0 and w is 1.
const VS =
    \\@out r0.y, 4
    \\@out r1.y, 2
    \\mov.u32u32 r0.w, 0
    \\mov.u32u32 r1.x, 0x3f800000
    \\(rpt1)sel.b32 r0.y, (r)c1.x, r0.x, (r)c0.x
    \\(rpt1)sel.b32 r1.y, (r)c1.z, r0.x, (r)c0.z
    \\end
;

/// c0: the color.
const FS_SOLID =
    \\@threadsize 128
    \\@out r0.x, 4
    \\mov.u32u32 r0.x, c0.x
    \\mov.u32u32 r0.y, c0.y
    \\mov.u32u32 r0.z, c0.z
    \\mov.u32u32 r0.w, c0.w
    \\end
;

/// The prefetched texel times c0.
const FS_IMAGE =
    \\@threadsize 128
    \\@out r1.z, 4
    \\bary.f (ei)r63.x, 0, (last)r0.x
    \\(sy)(rpt3)mul.f r1.z, (last)(r)r0.z, (r)c0.x
    \\end
;

/// The prefetched texel's first channel (coverage) times c0.
const FS_MASK =
    \\@threadsize 128
    \\@out r1.z, 4
    \\bary.f (ei)r63.x, 0, (last)r0.x
    \\(sy)(rpt3)mul.f r1.z, r0.z, (r)c0.x
    \\end
;

// The coverage programs (Galaxy's own: turnip has none like them). A
// rounded rectangle's signed distance at the pixel, as gfx.sdRoundRect:
// q = |p - centre| - k (k: the half size less the radius), then
// length(max(q, 0)) + min(max(q.x, q.y), 0) - radius; the coverage is
// 0.5 less that, between 0 and 1. The constants hold the negated values,
// so every step is an add.

/// A filled rounded rectangle. The varyings are the pixel's position.
/// c0: the color; c1: -centre x, y, -k x, y; c2.x: -radius.
const FS_RRECT =
    \\@threadsize 128
    \\@out r4.x, 4
    \\(rpt1)bary.f (ei)r2.x, (r)0, r0.x
    \\(rpt1)add.f r2.x, (r)r2.x, (r)c1.x
    \\absneg.f r2.x, (abs)r2.x
    \\absneg.f r2.y, (abs)r2.y
    \\(rpt1)add.f r2.x, (r)r2.x, (r)c1.z
    \\(rpt1)max.f r2.z, (r)r2.x, (0.0)
    \\mul.f r3.x, r2.z, r2.z
    \\mul.f r3.y, r2.w, r2.w
    \\add.f r3.x, r3.x, r3.y
    \\sqrt r3.x, r3.x
    \\max.f r3.y, r2.x, r2.y
    \\min.f r3.y, r3.y, (0.0)
    \\add.f r3.x, r3.x, r3.y
    \\add.f r3.x, r3.x, c2.x
    \\add.f (sat)r3.x, (neg)r3.x, (0.5)
    \\(rpt3)mul.f r4.x, (r)c0.x, r3.x
    \\end
;

/// A stroked rounded rectangle: the outer shape's coverage less the
/// inner's (the same centre), not below 0.
/// c0: the color; c1: -centre, -k (outer); c2.x, c2.y: -radius outer,
/// inner; c3.zw: -k (inner).
const FS_RING =
    \\@threadsize 128
    \\@out r4.x, 4
    \\(rpt1)bary.f (ei)r2.x, (r)0, r0.x
    \\(rpt1)add.f r2.x, (r)r2.x, (r)c1.x
    \\absneg.f r2.x, (abs)r2.x
    \\absneg.f r2.y, (abs)r2.y
    \\(rpt1)add.f r5.x, (r)r2.x, (r)c1.z
    \\(rpt1)max.f r5.z, (r)r5.x, (0.0)
    \\mul.f r3.x, r5.z, r5.z
    \\mul.f r3.y, r5.w, r5.w
    \\add.f r3.x, r3.x, r3.y
    \\sqrt r3.x, r3.x
    \\max.f r3.y, r5.x, r5.y
    \\min.f r3.y, r3.y, (0.0)
    \\add.f r3.x, r3.x, r3.y
    \\add.f r3.x, r3.x, c2.x
    \\add.f (sat)r3.x, (neg)r3.x, (0.5)
    \\(rpt1)add.f r6.x, (r)r2.x, (r)c3.z
    \\(rpt1)max.f r6.z, (r)r6.x, (0.0)
    \\mul.f r3.z, r6.z, r6.z
    \\mul.f r3.w, r6.w, r6.w
    \\add.f r3.z, r3.z, r3.w
    \\sqrt r3.z, r3.z
    \\max.f r3.w, r6.x, r6.y
    \\min.f r3.w, r3.w, (0.0)
    \\add.f r3.z, r3.z, r3.w
    \\add.f r3.z, r3.z, c2.y
    \\add.f (sat)r3.z, (neg)r3.z, (0.5)
    \\add.f r3.x, r3.x, (neg)r3.z
    \\max.f r3.x, r3.x, (0.0)
    \\(rpt3)mul.f r4.x, (r)c0.x, r3.x
    \\end
;

/// The prefetched texel times c0 times a rounded rectangle's coverage.
/// The varyings are the texture coordinates; the pixel's position less
/// the centre is theirs scaled and moved.
/// c0: the tint; c1: the scale x, y, then the offset x, y; c2: -k x, y,
/// then -radius.
const FS_IMAGE_RR =
    \\@threadsize 128
    \\@out r4.x, 4
    \\(rpt1)bary.f (ei)r2.x, (r)0, r0.x
    \\(rpt1)mul.f r2.x, (r)r2.x, (r)c1.x
    \\(rpt1)add.f r2.x, (r)r2.x, (r)c1.z
    \\absneg.f r2.x, (abs)r2.x
    \\absneg.f r2.y, (abs)r2.y
    \\(rpt1)add.f r2.x, (r)r2.x, (r)c2.x
    \\(rpt1)max.f r2.z, (r)r2.x, (0.0)
    \\mul.f r3.x, r2.z, r2.z
    \\mul.f r3.y, r2.w, r2.w
    \\add.f r3.x, r3.x, r3.y
    \\sqrt r3.x, r3.x
    \\max.f r3.y, r2.x, r2.y
    \\min.f r3.y, r3.y, (0.0)
    \\add.f r3.x, r3.x, r3.y
    \\add.f r3.x, r3.x, c2.z
    \\add.f (sat)r3.x, (neg)r3.x, (0.5)
    \\(sy)(rpt3)mul.f r4.x, (r)r0.z, (r)c0.x
    \\(rpt3)mul.f r4.x, (r)r4.x, r3.x
    \\end
;

/// The prefetched coverage times a gradient: a path filled with a paint.
/// The varyings are the mask's texture coordinates, one a pixel. With
/// q1 and q2 two lines in them, t is |(q1, q2)| times R plus q1 times L,
/// held to [0, 1] (L one for a gradient along a line, R one for one
/// around a point); the color is a, then b - a by t up to the middle
/// stop, then c - b by the rest. Colors are straight here, and leave
/// premultiplied.
/// c0: q1's x, y, constant, then L; c1: q2's, then R; c2: 1 / mid,
/// -mid / (1 - mid), 1 / (1 - mid), the opacity; c3: a; c4: b - a;
/// c5: c - b.
const FS_MASK_GRAD =
    \\@threadsize 128
    \\@out r6.x, 4
    \\(rpt1)bary.f (ei)r2.x, (r)0, r0.x
    \\mul.f r2.z, r2.x, c0.x
    \\mul.f r2.w, r2.y, c0.y
    \\add.f r2.z, r2.z, r2.w
    \\add.f r2.z, r2.z, c0.z
    \\mul.f r3.x, r2.x, c1.x
    \\mul.f r3.y, r2.y, c1.y
    \\add.f r3.x, r3.x, r3.y
    \\add.f r3.x, r3.x, c1.z
    \\mul.f r3.y, r2.z, r2.z
    \\mul.f r3.z, r3.x, r3.x
    \\add.f r3.y, r3.y, r3.z
    \\sqrt r3.y, r3.y
    \\mul.f r3.y, r3.y, c1.w
    \\mul.f r3.z, r2.z, c0.w
    \\add.f (sat)r3.y, r3.y, r3.z
    \\mul.f (sat)r3.z, r3.y, c2.x
    \\mul.f r3.w, r3.y, c2.z
    \\add.f (sat)r3.w, r3.w, c2.y
    \\(rpt3)mul.f r4.x, (r)c4.x, r3.z
    \\(rpt3)add.f r4.x, (r)r4.x, (r)c3.x
    \\(rpt3)mul.f r5.x, (r)c5.x, r3.w
    \\(rpt3)add.f r4.x, (r)r4.x, (r)r5.x
    \\(sy)mul.f r3.x, r0.z, c2.w
    \\mul.f r3.x, r3.x, r4.w
    \\(rpt2)mul.f r6.x, (r)r4.x, r3.x
    \\mov.f32f32 r6.w, r3.x
    \\end
;

/// A soft disc, as gfx.radialGlow: full inside `inner`, falling by a
/// smooth step to nothing at `outer`, with gfx's 4 x 4 ordered dither
/// (9 of 255 wide) so the fall does not band. The varyings are the
/// pixel's position.
/// c0: the color (straight), then its alpha; c1: -centre x, y, inner,
/// 1 / (outer - inner); c2: the dither's step and offset, 3, outer
/// squared; c3.x: what the blended color is taken down by (gfx's blend
/// drops the fraction where the blender rounds).
const FS_GLOW =
    \\@threadsize 128
    \\@out r6.x, 4
    \\(rpt1)bary.f (ei)r2.x, (r)0, r0.x
    \\(rpt1)add.f r2.z, (r)r2.x, (r)c1.x
    \\mul.f r3.x, r2.z, r2.z
    \\mul.f r3.y, r2.w, r2.w
    \\add.f r3.x, r3.x, r3.y
    \\sqrt r3.y, r3.x
    \\add.f r3.z, (neg)r3.y, c1.z
    \\mul.f r3.z, r3.z, c1.w
    \\add.f (sat)r3.z, r3.z, (1.0)
    \\mul.f r3.w, r3.z, r3.z
    \\add.f r4.x, r3.z, r3.z
    \\add.f r4.x, (neg)r4.x, c2.z
    \\mul.f r3.w, r3.w, r4.x
    \\mul.f r3.w, r3.w, c0.w
    \\cov.f32u32 r4.y, r2.x
    \\cov.f32u32 r4.z, r2.y
    \\xor.b r4.w, r4.y, r4.z
    \\and.b r5.x, r4.w, 1
    \\shl.b r5.x, r5.x, 3
    \\and.b r5.y, r4.z, 1
    \\shl.b r5.y, r5.y, 2
    \\or.b r5.x, r5.x, r5.y
    \\and.b r5.y, r4.w, 2
    \\or.b r5.x, r5.x, r5.y
    \\and.b r5.y, r4.z, 2
    \\shr.b r5.y, r5.y, 1
    \\or.b r5.x, r5.x, r5.y
    \\cov.u32f32 r5.x, r5.x
    \\mul.f r5.x, r5.x, c2.x
    \\add.f r5.x, r5.x, c2.y
    \\add.f (sat)r3.w, r3.w, r5.x
    \\cmps.f.lt r5.y, r3.x, c2.w
    \\cov.u32f32 r5.y, r5.y
    \\mul.f r3.w, r3.w, r5.y
    \\(rpt2)mul.f r6.x, (r)c0.x, r3.w
    \\(rpt2)add.f r6.x, (r)r6.x, c3.x
    \\mov.f32f32 r6.w, r3.w
    \\end
;

/// A rounded rectangle's soft shadow, as gfx.shadowRoundRect: the color
/// times gaussEdge of the signed distance (FS_RRECT's), nothing deeper
/// than three sigmas inside but for Deep's pixels. The varyings are the
/// pixel's position.
/// c0: the color (straight), then what the blended color is taken down
/// by; c1: -centre x, y, -(half size less radius) x, y; c2: -radius,
/// -3 sigma, 1 / (sigma sqrt 2), the alpha; c3: Deep's from_x, above,
/// below, and the alpha drawn there; c4, c5: erf's constants, then
/// -log2(e) and -1; c6: 3 sigma, 1 / Deep's step (0: none), the step;
/// c7: Deep's left, right, and what the coverage is taken down by; c8:
/// the run's column as the distance takes it (its x less the half size
/// less the radius, and that squared where it is past the corner's
/// centre), Deep's run_from and run_end.
const FS_SHADOW =
    \\@threadsize 128
    \\@out r6.x, 4
    \\(rpt1)bary.f (ei)r5.x, (r)0, r0.x
    \\(rpt1)add.f r2.x, (r)r5.x, (r)c1.x
    \\absneg.f r2.x, (abs)r2.x
    \\absneg.f r2.y, (abs)r2.y
    \\(rpt1)add.f r2.x, (r)r2.x, (r)c1.z
    \\(rpt1)max.f r2.z, (r)r2.x, (0.0)
    \\mul.f r3.x, r2.z, r2.z
    \\mul.f r3.y, r2.w, r2.w
    \\add.f r3.x, r3.x, r3.y
    \\sqrt r3.x, r3.x
    \\max.f r3.y, r2.x, r2.y
    \\min.f r3.y, r3.y, (0.0)
    \\add.f r3.x, r3.x, r3.y
    \\add.f r3.x, r3.x, c2.x
    \\cmps.f.lt r7.x, r5.y, c3.y
    \\cmps.f.gt r7.y, r5.y, c3.z
    \\or.b r7.x, r7.x, r7.y
    \\mul.f r8.x, r2.w, r2.w
    \\add.f r8.x, r8.x, c8.y
    \\sqrt r8.x, r8.x
    \\max.f r8.y, r2.y, c8.x
    \\min.f r8.y, r8.y, (0.0)
    \\add.f r8.x, r8.x, r8.y
    \\add.f r8.x, r8.x, c2.x
    \\cmps.f.lt r8.x, r8.x, c2.y
    \\cmps.f.gt r8.y, r5.x, c8.z
    \\and.b r8.x, r8.x, r8.y
    \\cmps.f.lt r8.y, r5.x, c8.w
    \\and.b r8.x, r8.x, r8.y
    \\and.b r8.x, r8.x, r7.x
    \\cov.u32f32 r8.x, r8.x
    \\add.f r8.x, (neg)r8.x, (1.0)
    \\cmps.f.lt r7.y, r5.x, c7.x
    \\cmps.f.gt r7.z, r5.x, c7.y
    \\or.b r7.y, r7.y, r7.z
    \\and.b r7.y, r7.y, r7.x
    \\cov.u32f32 r7.y, r7.y
    \\add.f r4.x, r3.x, c6.x
    \\mul.f r4.x, r4.x, c6.y
    \\add.f r4.x, r4.x, (0.5)
    \\floor.f r4.x, r4.x
    \\mul.f r4.x, r4.x, c6.z
    \\add.f r4.x, r4.x, c2.y
    \\add.f r7.z, (neg)r3.x, r4.x
    \\mul.f r7.z, r7.z, r7.y
    \\add.f r7.z, r7.z, r3.x
    \\mul.f r3.y, r7.z, c2.z
    \\absneg.f r3.z, (abs)r3.y
    \\mul.f r3.w, r3.z, c4.x
    \\add.f r3.w, r3.w, (1.0)
    \\rcp r3.w, r3.w
    \\mul.f r4.x, r3.w, c4.y
    \\add.f r4.x, r4.x, c4.z
    \\mul.f r4.x, r4.x, r3.w
    \\add.f r4.x, r4.x, c4.w
    \\mul.f r4.x, r4.x, r3.w
    \\add.f r4.x, r4.x, c5.x
    \\mul.f r4.x, r4.x, r3.w
    \\add.f r4.x, r4.x, c5.y
    \\mul.f r4.x, r4.x, r3.w
    \\mul.f r4.y, r3.y, r3.y
    \\mul.f r4.y, r4.y, c5.z
    \\exp2 r4.y, r4.y
    \\mul.f r4.x, r4.x, r4.y
    \\mul.f r4.x, r4.x, (0.5)
    \\cmps.f.ge r4.z, r3.y, (0.0)
    \\cov.u32f32 r4.z, r4.z
    \\add.f r4.w, r4.x, r4.x
    \\add.f r4.w, r4.w, c5.w
    \\mul.f r4.w, r4.w, r4.z
    \\add.f r5.z, (neg)r4.x, (1.0)
    \\add.f r4.w, r4.w, r5.z
    \\add.f (sat)r4.w, r4.w, c7.z
    \\mul.f r4.w, r4.w, c2.w
    \\cmps.f.lt r5.z, r3.x, c2.y
    \\cov.u32f32 r5.z, r5.z
    \\cmps.f.gt r5.w, r5.x, c3.x
    \\and.b r5.w, r5.w, r7.x
    \\cov.u32f32 r5.w, r5.w
    \\mul.f r5.w, r5.w, c3.w
    \\add.f r5.w, (neg)r4.w, r5.w
    \\mul.f r5.w, r5.w, r5.z
    \\add.f r4.w, r4.w, r5.w
    \\mul.f r4.w, r4.w, r8.x
    \\(rpt2)mul.f r6.x, (r)c0.x, r4.w
    \\(rpt2)add.f r6.x, (r)r6.x, c0.w
    \\mov.f32f32 r6.w, r4.w
    \\end
;

const SOURCES = [1 + KINDS][]const u8{ VS, FS_SOLID, FS_IMAGE, FS_MASK, FS_RRECT, FS_RING, FS_IMAGE_RR, FS_MASK_GRAD, FS_GLOW, FS_SHADOW };

/// How each kind's fragment program is wired: whether it reads the
/// varyings, whether the pipeline prefetches its texel, where its color is.
const Wiring = struct { varyings: bool, prefetch: bool, color_reg: u8 };
const WIRING = [KINDS]Wiring{
    .{ .varyings = false, .prefetch = false, .color_reg = 0 },
    .{ .varyings = true, .prefetch = true, .color_reg = 6 },
    .{ .varyings = true, .prefetch = true, .color_reg = 6 },
    .{ .varyings = true, .prefetch = false, .color_reg = 16 },
    .{ .varyings = true, .prefetch = false, .color_reg = 16 },
    .{ .varyings = true, .prefetch = true, .color_reg = 16 },
    .{ .varyings = true, .prefetch = true, .color_reg = 24 },
    .{ .varyings = true, .prefetch = false, .color_reg = 24 },
    .{ .varyings = true, .prefetch = false, .color_reg = 24 },
};

/// Instruction words a program may take (with its padding), and its bytes
/// in the code buffer.
const WORDS = 128;
const SLOT = WORDS * 8;
const CODE_BYTES = 16384;
/// Where the border colors' zeros are in the code buffer.
const BORDER_AT = CODE_BYTES - 256;
/// Bytes a texture's descriptors take in the state buffer.
const BINDING = 128;

pub const Options = struct {
    /// Bytes of command stream a pass may take (24 dwords a rectangle,
    /// more where the kind, the blend or the texture changes).
    stream_bytes: usize = 256 * 1024,
    /// Bytes of texture descriptors a pass may take (BINDING a change of
    /// texture).
    state_bytes: usize = 64 * 1024,
};

pub const Stats = struct {
    rects: u32 = 0,
    /// Changes of program, and of texture.
    programs: u32 = 0,
    bindings: u32 = 0,
    stream_dwords: u32 = 0,
};

/// The renderer: at a fixed address once init has run (its programs point
/// into it).
pub const Renderer = struct {
    dev: Device,
    code: Buffer,
    state: Buffer,
    ib: Buffer,
    kernels: [1 + KINDS]ir3_asm.Kernel,
    words: [1 + KINDS][WORDS]u64,
    progs: [KINDS]dr.Program,
    // The pass being recorded.
    s: dr.Stream,
    in_pass: bool,
    state_used: usize,
    state_full: bool,
    /// A texture of the pass was one the hardware would not read as given.
    bad_texture: bool,
    kind: ?Kind,
    blend: ?Blend,
    tex: ?Texture,
    stats: Stats,

    /// Assemble the programs and take the buffers. `work` is scratch.
    pub fn init(r: *Renderer, dev: Device, work: *ir3_asm.Work, opts: Options) Error!void {
        r.dev = dev;
        r.in_pass = false;
        r.stats = .{};
        for (SOURCES, 0..) |src, i| {
            r.kernels[i] = try ir3_asm.assemble(ir3.A7XX, src, work, &r.words[i]);
            if (r.kernels[i].code.len > WORDS) return error.BadKernel;
        }
        r.code = try dev.alloc(CODE_BYTES);
        errdefer dev.free(r.code);
        r.state = try dev.alloc(opts.state_bytes);
        errdefer dev.free(r.state);
        r.ib = try dev.alloc(opts.stream_bytes);
        @memset(r.code.cpu, 0);
        for (r.kernels, 0..) |k, i| {
            const dst: []u64 = @alignCast(std.mem.bytesAsSlice(u64, r.code.cpu[i * SLOT ..][0..SLOT]));
            @memcpy(dst[0..k.code.len], k.code);
        }
        dev.toDevice(r.code, 0, CODE_BYTES);
        const vs_va = r.code.va;
        for (0..KINDS) |k| {
            const w = WIRING[k];
            r.progs[k] = .{
                .vs = &r.kernels[0],
                .vs_va = vs_va,
                .fs = &r.kernels[1 + k],
                .fs_va = r.code.va + (1 + k) * SLOT,
                .vertexid_reg = 0,
                .pos_reg = 1,
                .vary_reg = if (w.varyings) 5 else ir3_asm.INVALID_REG,
                .varyings = if (w.varyings) 2 else 0,
                .ij_reg = if (w.varyings) 0 else ir3_asm.INVALID_REG,
                .color_reg = w.color_reg,
                .textures = if (w.prefetch) 1 else 0,
                .prefetch_reg = if (w.prefetch) 2 else ir3_asm.INVALID_REG,
            };
        }
    }

    pub fn deinit(r: *Renderer) void {
        r.dev.free(r.ib);
        r.dev.free(r.state);
        r.dev.free(r.code);
    }

    /// Start a pass on `t`: its pixels as they are, the scissor the whole
    /// target.
    pub fn begin(r: *Renderer, t: Target) void {
        r.s = .{ .buf = r.ib.words() };
        r.in_pass = true;
        r.state_used = 0;
        r.state_full = false;
        r.bad_texture = false;
        r.kind = null;
        r.blend = null;
        r.tex = null;
        r.stats = .{};
        dr.setup(&r.s, r.code.va + BORDER_AT);
        dr.begin(&r.s, t);
    }

    /// Draw only inside [x0, x1) x [y0, y1) from here on.
    pub fn scissor(r: *Renderer, x0: u32, y0: u32, x1: u32, y1: u32) void {
        if (!r.in_pass) return;
        dr.scissor(&r.s, x0, y0, x1, y1);
    }

    fn use(r: *Renderer, kind: Kind, b: Blend) void {
        if (r.kind == null or r.kind.? != kind) {
            // (the programs were checked at init: this cannot fail)
            dr.program(&r.s, &r.progs[@intFromEnum(kind)]) catch unreachable;
            r.kind = kind;
            r.tex = null;
            r.stats.programs += 1;
        }
        if (r.blend == null or r.blend.? != b) {
            dr.blend(&r.s, b);
            r.blend = b;
        }
    }

    fn bind(r: *Renderer, t: Texture) void {
        if (r.tex) |cur| if (std.meta.eql(cur, t)) return;
        // (rows not a multiple of 64 bytes apart: the pass is refused)
        if (!dr.textureFits(t)) r.bad_texture = true;
        if (r.state_used + BINDING > r.state.cpu.len) {
            r.state_full = true;
            return;
        }
        const at = r.state_used;
        const out: []u32 = @alignCast(std.mem.bytesAsSlice(u32, r.state.cpu[at..][0..BINDING]));
        dr.descriptors(&.{t}, out);
        dr.textures(&r.s, 1, r.state.va + at);
        r.state_used += BINDING;
        r.tex = t;
        r.stats.bindings += 1;
    }

    fn corners(r: *Renderer, rc: Rect, uv: [4]f32, color: Color) void {
        r.cornersWith(rc, uv, &color);
    }

    /// The rectangle with the fragment program's constants from c0.
    fn cornersWith(r: *Renderer, rc: Rect, uv: [4]f32, fs: []const f32) void {
        const v = [8]f32{ rc[0], rc[1], uv[0], uv[1], rc[2], rc[3], uv[2], uv[3] };
        dr.vsConstants(&r.s, @ptrCast(&v));
        dr.fsConstants(&r.s, @ptrCast(fs));
        dr.rect(&r.s);
        r.stats.rects += 1;
    }

    /// `color` times the coverage of the rounded rectangle `s`, over the
    /// pixels of `rc` (s's bounds, or less).
    pub fn rrect(r: *Renderer, rc: Rect, s: Shape, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.rrect, b);
        const c = [12]f32{ color[0], color[1], color[2], color[3], -s.cx, -s.cy, -s.kx, -s.ky, -s.rad, 0, 0, 0 };
        r.cornersWith(rc, rc, &c);
    }

    /// `color` times the coverage of `outer` less that of `inner` (the
    /// same centre; null: nothing taken out): a stroke.
    pub fn ring(r: *Renderer, rc: Rect, outer: Shape, inner: ?Shape, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.ring, b);
        // (no inner shape: one no pixel is inside)
        const in = inner orelse Shape{ .cx = outer.cx, .cy = outer.cy, .kx = -1e9, .ky = -1e9, .rad = 0 };
        const c = [16]f32{ color[0], color[1], color[2], color[3], -outer.cx, -outer.cy, -outer.kx, -outer.ky, -outer.rad, -in.rad, 0, 0, 0, 0, -in.kx, -in.ky };
        r.cornersWith(rc, rc, &c);
    }

    /// image, times the coverage of the rounded rectangle `s` (in window
    /// pixels, as `rc`).
    pub fn imageRR(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, s: Shape, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        if (!(uv[2] != uv[0] and uv[3] != uv[1])) return;
        r.use(.image_rr, b);
        r.bind(t);
        // the pixel's position from the texture coordinates, less the centre
        const sx = (rc[2] - rc[0]) / (uv[2] - uv[0]);
        const sy = (rc[3] - rc[1]) / (uv[3] - uv[1]);
        const c = [12]f32{ tint[0], tint[1], tint[2], tint[3], sx, sy, rc[0] - uv[0] * sx - s.cx, rc[1] - uv[1] * sy - s.cy, -s.kx, -s.ky, -s.rad, 0 };
        r.cornersWith(rc, uv, &c);
    }

    /// A rectangle of one color.
    pub fn fill(r: *Renderer, rc: Rect, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.solid, b);
        r.corners(rc, .{ 0, 0, 0, 0 }, color);
    }

    /// `t`'s texels from (uv[0], uv[1]) to (uv[2], uv[3]) across the
    /// rectangle, each times `tint`.
    pub fn image(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.image, b);
        r.bind(t);
        r.corners(rc, uv, tint);
    }

    /// `color` times the coverage in `t` (an r8 texture), as text is drawn.
    pub fn mask(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.mask, b);
        r.bind(t);
        r.corners(rc, uv, color);
    }

    /// `g`'s color times the coverage in `t` (an r8 texture, one texel a
    /// pixel) times `opacity`: a path filled with a gradient.
    pub fn maskGradient(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, g: Gradient, opacity: f32, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.mask_grad, b);
        r.bind(t);
        // the lines in texture coordinates: a pixel's position is its
        // coordinate plus where the mask lies
        const ox = rc[0] - uv[0];
        const oy = rc[1] - uv[1];
        const c = [24]f32{
            g.q1[0], g.q1[1], g.q1[2] + g.q1[0] * ox + g.q1[1] * oy, g.along,
            g.q2[0], g.q2[1], g.q2[2] + g.q2[0] * ox + g.q2[1] * oy, g.around,
            1 / g.mid, -g.mid / (1 - g.mid), 1 / (1 - g.mid), opacity,
            g.a[0], g.a[1], g.a[2], g.a[3],
            g.b[0] - g.a[0], g.b[1] - g.a[1], g.b[2] - g.a[2], g.b[3] - g.a[3],
            g.c[0] - g.b[0], g.c[1] - g.b[1], g.c[2] - g.b[2], g.c[3] - g.b[3],
        };
        r.cornersWith(rc, uv, &c);
    }

    /// A soft disc at (cx, cy): `color` (straight, its alpha last) full
    /// inside `inner`, falling smoothly to nothing at `outer`, dithered.
    /// (Half a step of 255 under gfx's sum: gfx takes the alpha down to a
    /// whole step, and this is the middle of what that loses. And the
    /// blended color is DROP lower, for gfx's blend of a glow.)
    pub fn glow(r: *Renderer, rc: Rect, cx: f32, cy: f32, inner: f32, outer: f32, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1]) or !(outer > 0)) return;
        r.use(.glow, b);
        const span = @max(outer - inner, 1e-6);
        const c = [16]f32{
            color[0], color[1], color[2], color[3],
            -cx, -cy, inner, 1 / span,
            9.0 / (16.0 * 255.0), (0.5 / 16.0 - 0.5) * 9.0 / 255.0 - 0.5 / 255.0, 3, outer * outer,
            -DROP, 0, 0, 0,
        };
        r.cornersWith(rc, rc, &c);
    }

    /// The soft shadow of the rounded rectangle `s`: `color` (straight,
    /// its alpha last) at shadowAlpha, the blended color DROP lower (gfx
    /// blends a shadow as it does a glow). `rc` is the shape's bounds and
    /// three sigmas around, or less.
    pub fn shadow(r: *Renderer, rc: Rect, s: Shape, sigma: f32, color: Color, deep: Deep, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1]) or !(sigma > 0)) return;
        r.use(.shadow, b);
        // (no step: no corner is gfx's)
        const stepped = deep.step > 0;
        const qxm = @abs(deep.run_from + 0.5 - s.cx) - s.kx;
        const oxm = @max(qxm, 0);
        const c = [36]f32{
            color[0], color[1], color[2], -DROP,
            -s.cx, -s.cy, -s.kx, -s.ky,
            -s.rad, -3 * sigma, 1 / (sigma * 1.41421356), color[3],
            deep.from_x, deep.above, deep.below, color[3] * (254.0 / 255.0),
            0.3275911, 1.061405429, -1.453152027, 1.421413741,
            -0.284496736, 0.254829592, -1.44269504, -1,
            3 * sigma, if (stepped) 1 / deep.step else 0, if (stepped) deep.step else 0, 0,
            if (stepped) deep.left else -1e30, if (stepped) deep.right else 1e30, -0.5 / 255.0, 0,
            qxm, oxm * oxm, deep.run_from, deep.run_end,
        };
        r.cornersWith(rc, rc, &c);
    }

    /// End the pass and hand it to the GPU. The target's pixels are in
    /// memory once the fence is done (fromDevice them before the CPU reads).
    pub fn submit(r: *Renderer) Error!Fence {
        if (!r.in_pass) return error.NoPass;
        r.in_pass = false;
        dr.end(&r.s);
        if (r.state_full) return error.StateFull;
        if (r.bad_texture) return error.BadStream;
        r.s.check() catch return error.StreamFull;
        r.stats.stream_dwords = @intCast(r.s.len);
        if (r.state_used != 0) r.dev.toDevice(r.state, 0, r.state_used);
        r.dev.toDevice(r.ib, 0, r.s.len * 4);
        return r.dev.submit(r.ib, @intCast(r.s.len));
    }

    /// The pass submit() ended, handed over again (the device refused it:
    /// its ring was busy with another context's work).
    pub fn resubmit(r: *Renderer) Error!Fence {
        if (r.in_pass or r.stats.stream_dwords == 0) return error.NoPass;
        return r.dev.submit(r.ib, r.stats.stream_dwords);
    }

    /// submit, and wait for it.
    pub fn run(r: *Renderer, timeout_us: u64) Error!void {
        const f = try r.submit();
        try r.dev.wait(f, timeout_us);
    }
};

// ── Tests: the streams on the emulated device ───────────────────────────────

const T = struct {
    var arena: [8 << 20]u8 align(4096) = undefined;
    var gpu_view: [8 << 20]u8 align(4096) = undefined;
    var dev: device.EmuDevice = undefined;
    var asm_work: ir3_asm.Work = .{};
    var r: Renderer = undefined;
    const W = 64;
    const H = 32;
    var target: Buffer = undefined;

    fn log(line: []const u8) void {
        std.debug.print("emu: {s}\n", .{line});
    }

    fn start() !Target {
        dev = .{ .arena = &arena, .gpu_view = &gpu_view, .log = &log };
        const d = dev.device();
        try r.init(d, &asm_work, .{ .stream_bytes = 64 * 1024, .state_bytes = 4096 });
        target = try d.alloc(W * H * 4);
        return .{ .va = target.va, .width = W, .height = H, .pitch = W * 4, .format = .bgra8 };
    }

    fn pixels() []const u32 {
        dev.device().fromDevice(target, 0, W * H * 4);
        return @alignCast(std.mem.bytesAsSlice(u32, target.cpu));
    }

    fn at(x: u32, y: u32) u32 {
        return pixels()[y * W + x];
    }
};

fn near(want: u32, got: u32, tol: i32) bool {
    for (0..4) |c| {
        const a: i32 = @intCast((want >> @intCast(8 * c)) & 0xff);
        const b: i32 = @intCast((got >> @intCast(8 * c)) & 0xff);
        if (@abs(a - b) > tol) return false;
    }
    return true;
}

fn expectNear(want: u32, got: u32, tol: i32) !void {
    if (!near(want, got, tol)) {
        std.debug.print("pixel: want {x:0>8}, got {x:0>8}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

test "the programs are turnip's, word for word" {
    _ = try T.start();
    defer T.r.deinit();
    // (from its X1-45 streams: the 3D blit's vertex program without the
    // layer coordinate, the clear's fragment program, and the fragment
    // program of a textured draw whose texel is prefetched)
    const vs = [_]u64{ 0x204cc003_00000000, 0x204cc004_3f800000, 0x64800901_30001004, 0x64800905_30021006, 0x03000000_00000000 };
    const solid = [_]u64{ 0x202cc000_00000000, 0x202cc001_00000001, 0x202cc002_00000002, 0x202cc003_00000003, 0x03000000_00000000 };
    const image = [_]u64{ 0x473080fc_04002000, 0x50780b06_10000402, 0x03000000_00000000 };
    try std.testing.expectEqualSlices(u64, &vs, T.r.kernels[0].code[0..vs.len]);
    try std.testing.expectEqualSlices(u64, &solid, T.r.kernels[1].code[0..solid.len]);
    try std.testing.expectEqualSlices(u64, &image, T.r.kernels[2].code[0..image.len]);
    for (T.r.kernels[0..4]) |k| try std.testing.expect(k.instrlen == 1);
    // footprints as Mesa counts them: the vertex program's two full
    // registers, the solid program's one, the image program's three (its
    // color ends in r2.y), no half registers
    try std.testing.expectEqual(@as(u8, 2), T.r.kernels[0].full_regs);
    try std.testing.expectEqual(@as(u8, 1), T.r.kernels[1].full_regs);
    try std.testing.expectEqual(@as(u8, 3), T.r.kernels[2].full_regs);
    try std.testing.expectEqual(@as(u8, 0), T.r.kernels[0].half_regs);
}

test "solid rectangles: where the rasterizer puts them, the scissor, the blend" {
    const t = try T.start();
    defer T.r.deinit();
    T.r.begin(t);
    // the whole target dark blue (0xAARRGGBB words: bytes B, G, R, A)
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0.5, 1 }, .replace);
    // an opaque red rectangle, [4, 20) x [2, 10)
    T.r.fill(.{ 4, 2, 20, 10 }, .{ 1, 0, 0, 1 }, .replace);
    // half-transparent green over both, [10, 30) x [6, 16) (premultiplied)
    T.r.fill(.{ 10, 6, 30, 16 }, .{ 0, 0.5, 0, 0.5 }, .over);
    // white, but only inside the scissor [40, 50) x [20, 30)
    T.r.scissor(40, 20, 50, 30);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 1, 1, 1, 1 }, .replace);
    try T.r.run(1_000_000);
    try std.testing.expectEqual(@as(u32, 4), T.dev.draws);
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(63, 31));
    // the red rectangle's corners, inside and just outside
    try std.testing.expectEqual(@as(u32, 0xffff0000), T.at(4, 2));
    try std.testing.expectEqual(@as(u32, 0xffff0000), T.at(9, 5));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(3, 2));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(4, 1));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(20, 5));
    // green over red: red halves, green half, alpha stays one
    try expectNear(0xff808000, T.at(10, 6), 1);
    try expectNear(0xff808000, T.at(19, 9), 1);
    // green over blue
    try expectNear(0xff008040, T.at(25, 12), 1);
    // the scissored white
    try std.testing.expectEqual(@as(u32, 0xffffffff), T.at(40, 20));
    try std.testing.expectEqual(@as(u32, 0xffffffff), T.at(49, 29));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(39, 20));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(50, 29));
}

test "an image: copied texel for texel, stretched with the bilinear filter, tinted and blended" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    // an 8 x 4 texture: red rises with x, green with y, opaque
    // (rows of 64 bytes: 16 texels a row, the first 8 the picture)
    const tex_buf = try d.alloc(4 * 64);
    const tw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, tex_buf.cpu));
    for (0..4) |y| for (0..8) |x| {
        tw[y * 16 + x] = 0xff000000 | (@as(u32, @intCast(x * 32)) << 16) | (@as(u32, @intCast(y * 64)) << 8);
    };
    d.toDevice(tex_buf, 0, 4 * 64);
    const nearest = Texture{ .va = tex_buf.va, .width = 8, .height = 4, .pitch = 64, .format = .bgra8, .filter = .nearest };
    var linear = nearest;
    linear.filter = .linear;
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0, 1 }, .replace);
    // texel for texel at (2, 1)
    T.r.image(.{ 2, 1, 10, 5 }, nearest, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    // twice the size at (20, 4), filtered
    T.r.image(.{ 20, 4, 36, 12 }, linear, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    // at half opacity over the black, at (40, 20)
    T.r.image(.{ 40, 20, 48, 24 }, nearest, .{ 0, 0, 8, 4 }, .{ 0.5, 0.5, 0.5, 0.5 }, .over);
    try T.r.run(1_000_000);
    for (0..4) |y| for (0..8) |x| {
        try std.testing.expectEqual(tw[y * 16 + x], T.at(@intCast(2 + x), @intCast(1 + y)));
    };
    try std.testing.expectEqual(@as(u32, 0xff000000), T.at(10, 1));
    // stretched: pixel (20 + 2i + 1, 4 + 2j + 1)'s centre is at texel
    // (i + 0.75, j + 0.75): a quarter of the way from texel i to i + 1
    try expectNear(0xff000000 | (@as(u32, 32 * 3 + 8) << 16) | (@as(u32, 64 + 16) << 8), T.at(27, 7), 2);
    // (clamped at the edges: the first pixel is the first texel)
    try expectNear(tw[0], T.at(20, 4), 2);
    // half of texel (7, 3) over opaque black
    try expectNear(0xff000000 | (@as(u32, 7 * 32 / 2) << 16) | (@as(u32, 3 * 64 / 2) << 8), T.at(47, 23), 2);
    try std.testing.expectEqual(@as(u32, 3), T.r.stats.bindings);
}

test "a mask: coverage times a color, over what is there" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    // 4 x 2 coverage: 0, 85, 170, 255 in both rows
    const m_buf = try d.alloc(128);
    for (0..2) |y| for (0..4) |x| {
        m_buf.cpu[y * 64 + x] = @intCast(x * 85);
    };
    d.toDevice(m_buf, 0, 128);
    const m = Texture{ .va = m_buf.va, .width = 4, .height = 2, .pitch = 64, .format = .r8, .filter = .nearest };
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 1, 1 }, .replace);
    // white text over blue
    T.r.mask(.{ 8, 8, 12, 10 }, m, .{ 0, 0, 4, 2 }, .{ 1, 1, 1, 1 }, .over);
    try T.r.run(1_000_000);
    try expectNear(0xff0000ff, T.at(8, 8), 1);
    try expectNear(0xff5555ff, T.at(9, 8), 1);
    try expectNear(0xffaaaaff, T.at(10, 9), 1);
    try expectNear(0xffffffff, T.at(11, 9), 1);
}

test "a pass that does not fit says so; a wrong stream is refused by the emulated GPU" {
    const t = try T.start();
    defer T.r.deinit();
    try std.testing.expectError(error.NoPass, T.r.submit());
    T.r.begin(t);
    for (0..4000) |_| T.r.fill(.{ 0, 0, 4, 4 }, .{ 1, 1, 1, 1 }, .replace);
    try std.testing.expectError(error.StreamFull, T.r.submit());
    // a draw with no target marked for direct rendering
    const d = T.dev.device();
    T.dev.log = null;
    T.dev.marker = 0;
    var s = dr.Stream{ .buf = T.r.ib.words() };
    dr.rect(&s);
    try std.testing.expectError(error.DeviceLost, d.run(T.r.ib, @intCast(s.len), 1_000_000));
}

/// The last value a stream writes to each register (type-4 packets).
fn lastWrites(words: []const u32, out: *[0x10000]u32, seen: *[0x10000]bool) void {
    @memset(seen, false);
    var i: usize = 0;
    while (i < words.len) {
        const h = words[i];
        if (h >> 28 == 4) {
            const reg = (h >> 8) & 0x3ffff;
            const cnt = h & 0x7f;
            for (0..cnt) |k| if (reg + k < out.len and i + 1 + k < words.len) {
                out[reg + k] = words[i + 1 + k];
                seen[reg + k] = true;
            };
            i += 1 + cnt;
        } else i += 1 + (h & 0x3fff);
    }
}

test "the state is turnip's: the values its X1-45 streams carry for the same draws" {
    const t = try T.start();
    defer T.r.deinit();
    const S = struct {
        var regs: [0x10000]u32 = undefined;
        var seen: [0x10000]bool = undefined;
    };
    const d = T.dev.device();
    const tex_buf = try d.alloc(16 * 16 * 4);
    const tx = Texture{ .va = tex_buf.va, .width = 16, .height = 16, .pitch = 256, .format = .rgba8, .filter = .linear };
    T.r.begin(t);
    T.r.fill(.{ 16, 8, 80, 40 }, .{ 0.25, 0.5, 0.75, 1 }, .replace);
    const solid_end = T.r.s.len;
    lastWrites(T.r.s.words(), &S.regs, &S.seen);
    // Per stream (tu6_init_static_regs as the X1-45) and per pass
    // (tu6_sysmem_render_begin), then a rectangle of one color (its clear).
    const solid = [_][2]u32{
        .{ 0x8e07, 0x00000068 }, .{ 0xb600, 0x13100000 }, .{ 0xb602, 0x00040724 }, .{ 0xae03, 0x10001402 },
        .{ 0x8120, 0x09510840 }, .{ 0x8121, 0x00000a62 }, .{ 0xab00, 0x00000005 }, .{ 0xa009, 0x00000003 },
        .{ 0x8811, 0x00000010 }, .{ 0xb309, 0x000000a2 }, .{ 0x8e09, 0x00000007 }, .{ 0x9885, 0x00020000 },
        .{ 0x9886, 0x00002000 }, .{ 0x88e5, 0x60000000 },
        .{ 0x80a1, 0x03c00000 }, .{ 0x8800, 0x03c00000 }, .{ 0x8812, 0x000003ff }, .{ 0x88e4, 0x00000000 },
        .{ 0x8000, 0x00000381 }, .{ 0x80a0, 0x00000002 }, .{ 0x9108, 0x00000003 }, .{ 0x9809, 0x00000003 },
        .{ 0x9307, 0x00000003 }, .{ 0x80a3, 0x00000004 }, .{ 0x8803, 0x00000004 }, .{ 0x8891, 0x00000001 },
        .{ 0x8820, 0x00000780 }, .{ 0x8865, 0xffff0000 }, .{ 0x9208, 0x00000009 }, .{ 0x9212, 0xffffffff },
        .{ 0x9304, 0xff00ff00 }, .{ 0x910c, 0x00000006 }, .{ 0x9b07, 0x00000006 }, .{ 0xa008, 0x00000006 },
        .{ 0xa001, 0xfcfcfc00 }, .{ 0xa002, 0x0000fcfc }, .{ 0xa003, 0xfcfcfcfc }, .{ 0xa004, 0x000000fc },
        .{ 0xa005, 0x0000fcfc }, .{ 0xa800, 0x00100100 }, .{ 0xa980, 0x81100080 }, .{ 0xa99e, 0x01ff7fc8 },
        .{ 0xa9ae, 0x00000300 }, .{ 0xa9c6, 0x00000001 }, .{ 0xa9c7, 0x00000007 }, .{ 0xa9c8, 0xfcfcfcfc },
        .{ 0xa9c9, 0xfcfcfcfc }, .{ 0xa9ca, 0xfcfcfcfc }, .{ 0xa9cb, 0x0000fcfc }, .{ 0xa98c, 0xfcfcfc00 },
        .{ 0xa98e, 0x00000000 }, .{ 0xa98b, 0x0000000f }, .{ 0x880d, 0x0000000f }, .{ 0xab04, 0x00000100 },
        .{ 0xa823, 0x00000100 },
    };
    for (solid) |g| {
        if (!S.seen[g[0]] or S.regs[g[0]] != g[1]) {
            std.debug.print("register {x:0>4}: turnip {x:0>8}, here {x:0>8} (written: {})\n", .{ g[0], g[1], S.regs[g[0]], S.seen[g[0]] });
            return error.TestUnexpectedResult;
        }
    }
    // A textured rectangle blended over (its 3D blit's linkage and
    // prefetch; a blended draw's fragment state and blend).
    T.r.image(.{ 32, 16, 160, 80 }, tx, .{ 0, 0, 16, 16 }, .{ 1, 1, 1, 1 }, .over);
    lastWrites(T.r.s.words()[solid_end..], &S.regs, &S.seen);
    const image = [_][2]u32{
        .{ 0xa802, 0x00000002 }, .{ 0xa803, 0x0f010305 }, .{ 0xa813, 0x00000200 }, .{ 0x9301, 0x00ff0206 },
        .{ 0x9b01, 0x00000006 }, .{ 0x9304, 0xff01ff06 }, .{ 0x9212, 0xfffffffc }, .{ 0x9208, 0x00000009 },
        .{ 0x8005, 0x00000001 }, .{ 0x8809, 0x00000401 }, .{ 0xa9c9, 0xfcfcfc00 }, .{ 0xa9ae, 0x00000302 },
        .{ 0xa9c6, 0x00000003 }, .{ 0xa99e, 0x01ff7fd1 }, .{ 0xa99f, 0x04784000 }, .{ 0xa9a3, 0x00000000 },
        .{ 0xa980, 0x85500180 }, .{ 0xa98e, 0x00000006 }, .{ 0xa9a7, 0x00000001 }, .{ 0xab04, 0x00020300 },
        .{ 0x8820, 0x00000783 }, .{ 0x8821, 0x07010701 }, .{ 0x8865, 0xffff0101 }, .{ 0xa989, 0x00000101 },
    };
    for (image) |g| {
        if (!S.seen[g[0]] or S.regs[g[0]] != g[1]) {
            std.debug.print("register {x:0>4}: turnip {x:0>8}, here {x:0>8} (written: {})\n", .{ g[0], g[1], S.regs[g[0]], S.seen[g[0]] });
            return error.TestUnexpectedResult;
        }
    }
    // The texture's descriptor: a 16 x 16 RGBA8 linear image as turnip
    // describes it (its address apart).
    const desc: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, T.r.state.cpu[0..80]));
    try std.testing.expectEqual(@as(u32, 0x0006092a), desc[0]);
    try std.testing.expectEqual(@as(u32, 0x00000060), desc[1]);
    try std.testing.expectEqualSlices(u32, &.{ 0x0c006880, 0x00080010, 0x20008002, 0x00000001 }, desc[4..8]);
    try std.testing.expectEqual(@as(u32, 1 << 17), desc[9] & 0xfffe0000);
}

test "rounded rectangles: filled, stroked, and an image inside one, by the coverage at each pixel" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    const tex_buf = try d.alloc(16 * 16 * 4);
    const tw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, tex_buf.cpu));
    // (the fourth byte is not alpha here: an opaque texture reads it as one)
    for (tw, 0..) |*p, i| p.* = 0x00206080 + @as(u32, @intCast(i % 16)) * 0x00010000;
    d.toDevice(tex_buf, 0, 16 * 16 * 4);
    const tx = Texture{ .va = tex_buf.va, .width = 16, .height = 16, .pitch = 64, .format = .bgra8, .filter = .nearest, .no_alpha = true };
    const fill = Shape.of(4.5, 3.25, 24, 14, 5);
    const outer = Shape.of(34, 4, 26, 20, 6);
    const inner = Shape.of(36, 6, 22, 16, 4);
    const pic = Shape.of(8, 20, 16, 10, 4);
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0, 1 }, .replace);
    T.r.rrect(.{ 4, 3, 29, 18 }, fill, .{ 1, 1, 1, 1 }, .over);
    T.r.ring(.{ 34, 4, 60, 24 }, outer, inner, .{ 0, 1, 0, 1 }, .over);
    T.r.imageRR(.{ 8, 20, 24, 30 }, tx, .{ 0, 0, 16, 10 }, .{ 1, 1, 1, 1 }, pic, .over);
    try T.r.run(1_000_000);
    const px = T.pixels();
    for (0..T.H) |y| for (0..T.W) |x| {
        const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        var want: [3]f32 = .{ 0, 0, 0 };
        if (x >= 4 and x < 29 and y >= 3 and y < 18) {
            const c = fill.coverage(fx, fy);
            for (&want) |*v| v.* = c + v.* * (1 - c);
        }
        if (x >= 34 and x < 60 and y >= 4 and y < 24) {
            const c = @max(outer.coverage(fx, fy) - inner.coverage(fx, fy), 0);
            want = .{ want[0] * (1 - c), c + want[1] * (1 - c), want[2] * (1 - c) };
        }
        if (x >= 8 and x < 24 and y >= 20 and y < 30) {
            const c = pic.coverage(fx, fy);
            const texel = tw[(y - 20) * 16 + (x - 8)];
            const tc = [3]f32{ @floatFromInt((texel >> 16) & 0xff), @floatFromInt((texel >> 8) & 0xff), @floatFromInt(texel & 0xff) };
            for (&want, tc) |*v, s| v.* = s / 255.0 * c + v.* * (1 - c);
        }
        const w32 = 0xff000000 | (@as(u32, @intFromFloat(want[0] * 255 + 0.5)) << 16) | (@as(u32, @intFromFloat(want[1] * 255 + 0.5)) << 8) | @as(u32, @intFromFloat(want[2] * 255 + 0.5));
        if (!near(w32, px[y * T.W + x], 2)) {
            std.debug.print("pixel ({d}, {d}): want {x:0>8}, got {x:0>8}\n", .{ x, y, w32, px[y * T.W + x] });
            return error.TestUnexpectedResult;
        }
    };
    // a stroke with nothing taken out is the filled shape
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0, 1 }, .replace);
    T.r.ring(.{ 4, 3, 29, 18 }, fill, null, .{ 1, 1, 1, 1 }, .over);
    try T.r.run(1_000_000);
    try expectNear(0xffffffff, T.at(16, 10), 1);
    try expectNear(0xff000000, T.at(4, 3), 40);
}

test "a texture in rows the hardware would misread is refused: by the renderer, and by the emulated GPU" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    const buf = try d.alloc(256);
    // (rows of 32 bytes: the X1-45 read them 64 apart)
    const narrow = Texture{ .va = buf.va, .width = 8, .height = 4, .pitch = 32, .format = .bgra8, .filter = .nearest };
    T.r.begin(t);
    T.r.image(.{ 0, 0, 8, 4 }, narrow, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    try std.testing.expectError(error.BadStream, T.r.submit());
    // (past the renderer's own check: the emulated texture unit refuses it)
    T.dev.log = null;
    T.r.begin(t);
    T.r.image(.{ 0, 0, 8, 4 }, narrow, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    T.r.bad_texture = false;
    try std.testing.expectError(error.DeviceLost, T.r.run(1_000_000));
}

test "a mask times a gradient, and a glow: the programs against their own arithmetic at every pixel" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    // a 16 x 8 coverage mask in rows of 64: a ramp across, full in the middle rows
    const m_buf = try d.alloc(8 * 64);
    for (0..8) |y| for (0..16) |x| {
        m_buf.cpu[y * 64 + x] = if (y >= 2 and y < 6) 255 else @intCast(x * 17);
    };
    d.toDevice(m_buf, 0, 8 * 64);
    const m = Texture{ .va = m_buf.va, .width = 16, .height = 8, .pitch = 64, .format = .r8, .filter = .nearest };
    // along a line from (10, 4) to (26, 12), three stops; around (40, 20), two
    const dx: f32 = 16;
    const dy: f32 = 8;
    const len2 = dx * dx + dy * dy;
    const line = Gradient{ .q1 = .{ dx / len2, dy / len2, -(10 * dx + 4 * dy) / len2 }, .a = .{ 1, 0, 0, 1 }, .b = .{ 0, 1, 0, 0.5 }, .c = .{ 0, 0, 1, 1 }, .mid = 0.25 };
    const disc = Gradient{ .q1 = .{ 1.0 / 8.0, 0, -40.0 / 8.0 }, .q2 = .{ 0, 1.0 / 4.0, -20.0 / 4.0 }, .along = 0, .around = 1, .a = .{ 1, 1, 1, 1 }, .b = .{ 0.6, 0.7, 0.8, 0.9 }, .c = .{ 0.2, 0.4, 0.6, 0.8 } };
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0, 1 }, .replace);
    T.r.maskGradient(.{ 10, 4, 26, 12 }, m, .{ 0, 0, 16, 8 }, line, 0.9, .over);
    T.r.maskGradient(.{ 32, 16, 48, 24 }, m, .{ 0, 0, 16, 8 }, disc, 1, .over);
    T.r.glow(.{ 44, 0, 64, 16 }, 54.25, 7.5, 3, 8, .{ 1, 0.5, 0.25, 0.8 }, .over);
    try T.r.run(1_000_000);
    const px = T.pixels();
    const bayer = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    for (0..T.H) |y| for (0..T.W) |x| {
        const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        var want: [3]f32 = .{ 0, 0, 0 };
        const over = struct {
            fn f(w: *[3]f32, rgb: [3]f32, a: f32) void {
                for (w, rgb) |*v, s| v.* = s * a + v.* * (1 - a);
            }
        }.f;
        if (x >= 10 and x < 26 and y >= 4 and y < 12) {
            const c = line.at(fx, fy);
            const cov: f32 = @as(f32, @floatFromInt(m_buf.cpu[(y - 4) * 64 + (x - 10)])) / 255.0;
            over(&want, .{ c[0], c[1], c[2] }, c[3] * cov * 0.9);
        }
        if (x >= 32 and x < 48 and y >= 16 and y < 24) {
            const c = disc.at(fx, fy);
            const cov: f32 = @as(f32, @floatFromInt(m_buf.cpu[(y - 16) * 64 + (x - 32)])) / 255.0;
            over(&want, .{ c[0], c[1], c[2] }, c[3] * cov);
        }
        if (x >= 44 and y < 16) {
            const ddx = fx - 54.25;
            const ddy = fy - 7.5;
            const d2 = ddx * ddx + ddy * ddy;
            if (d2 < 64) {
                var tt = std.math.clamp(1 - (@sqrt(d2) - 3) / 5, 0, 1);
                tt = tt * tt * (3 - 2 * tt);
                const dither = ((bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16.0 - 0.5) * 9.0 / 255.0;
                over(&want, .{ 1, 0.5, 0.25 }, std.math.clamp(tt * 0.8 + dither - 0.5 / 255.0, 0, 1));
            }
            for (&want) |*v| v.* = @max(v.* - DROP, 0);
        }
        const w32 = 0xff000000 | (@as(u32, @intFromFloat(want[0] * 255 + 0.5)) << 16) | (@as(u32, @intFromFloat(want[1] * 255 + 0.5)) << 8) | @as(u32, @intFromFloat(want[2] * 255 + 0.5));
        if (!near(w32, px[y * T.W + x], 2)) {
            std.debug.print("pixel ({d}, {d}): want {x:0>8}, got {x:0>8}\n", .{ x, y, w32, px[y * T.W + x] });
            return error.TestUnexpectedResult;
        }
    };
}

test "a shadow: the program against its own arithmetic at every pixel, the deep pixels too" {
    const t = try T.start();
    defer T.r.deinit();
    const a = Shape.of(8.5, 6.25, 30, 18, 5);
    const b = Shape.of(44.25, 3, 14, 26, 2);
    const deep = Deep{ .from_x = 52, .above = 9, .below = 23, .left = 47, .right = 55, .step = 0.125, .run_from = 50, .run_end = 54 };
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 1, 1, 1, 1 }, .replace);
    T.r.shadow(.{ 2, 0, 44, 30 }, a, 1.5, .{ 0.1, 0.2, 0.4, 0.7 }, .{}, .over);
    T.r.shadow(.{ 40, 0, 64, 32 }, b, 1, .{ 0, 0, 0, 1 }, deep, .over);
    try T.r.run(1_000_000);
    const px = T.pixels();
    var deep_seen: u32 = 0;
    for (0..T.H) |y| for (0..T.W) |x| {
        var want: [3]f32 = .{ 1, 1, 1 };
        if (x >= 2 and x < 44 and y < 30) {
            const al = shadowAlpha(@intCast(x), @intCast(y), a, 1.5, 0.7, .{});
            for (&want, [3]f32{ 0.1, 0.2, 0.4 }) |*v, s| v.* = @max(s * al - DROP, 0) + v.* * (1 - al);
        }
        if (x >= 40) {
            const al = shadowAlpha(@intCast(x), @intCast(y), b, 1, 1, deep);
            if (al > 0.9 and b.distance(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5) < -3) deep_seen += 1;
            for (&want) |*v| v.* = v.* * (1 - al);
        }
        const w32 = 0xff000000 | (@as(u32, @intFromFloat(want[0] * 255 + 0.5)) << 16) | (@as(u32, @intFromFloat(want[1] * 255 + 0.5)) << 8) | @as(u32, @intFromFloat(want[2] * 255 + 0.5));
        if (!near(w32, px[y * T.W + x], 2)) {
            std.debug.print("pixel ({d}, {d}): want {x:0>8}, got {x:0>8}\n", .{ x, y, w32, px[y * T.W + x] });
            return error.TestUnexpectedResult;
        }
    };
    // (the second shadow has pixels of both kinds: left alone, and drawn whole)
    try std.testing.expect(deep_seen > 0);
    try std.testing.expectEqual(@as(u32, 0xffffffff), px[14 * T.W + 49]);
}

// ── The self-test: the pipeline on the real GPU ─────────────────────────────
// What the tests above check on the emulated device, drawn on any Device
// and compared with the values the arithmetic gives, case by case and each
// in a pass of its own, so the log names the first thing the hardware does
// differently (or the pass it does not finish). Then how fast it fills.

pub const SelfTest = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// A pass did not finish (the GPU hung or faulted): the cases after
    /// it did not run.
    lost: bool = false,
    /// The fill rate measured (megapixels a second; 0: not measured).
    mpx_per_s: u32 = 0,
};

const Probe = struct { x: u32, y: u32, want: u32, tol: i32 = 1 };

const Run = struct {
    r: *Renderer,
    dev: Device,
    target: Target,
    pixels: Buffer,
    log: *const fn (line: []const u8) void,
    res: SelfTest = .{},

    fn say(c: *Run, comptime fmt: []const u8, args: anytype) void {
        var buf: [240]u8 = undefined;
        c.log(std.fmt.bufPrint(&buf, fmt, args) catch "draw self-test: (a line too long)");
    }

    /// Run the pass recorded and compare the probes.
    fn check(c: *Run, name: []const u8, probes: []const Probe) void {
        if (c.res.lost) return;
        c.say("draw self-test: {s} ...", .{name});
        c.r.run(2_000_000) catch |e| {
            c.say("draw self-test: {s}: the pass did not finish ({s}, {d} dwords, {d} rectangles)", .{ name, @errorName(e), c.r.stats.stream_dwords, c.r.stats.rects });
            c.res.lost = e == error.Timeout or e == error.DeviceLost;
            c.res.failed += 1;
            return;
        };
        const bytes = c.target.pitch * c.target.height;
        c.dev.fromDevice(c.pixels, 0, bytes);
        const px: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, c.pixels.cpu[0..bytes]));
        const stride = c.target.pitch / 4;
        for (probes) |p| {
            const got = px[p.y * stride + p.x];
            if (!near(p.want, got, p.tol)) {
                c.say("draw self-test: {s}: pixel ({d}, {d}) is {x:0>8}, not {x:0>8}; the row starts {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ name, p.x, p.y, got, p.want, px[p.y * stride], px[p.y * stride + 1], px[p.y * stride + 2], px[p.y * stride + 3] });
                c.res.failed += 1;
                return;
            }
        }
        c.res.passed += 1;
    }
};

/// Draw the cases on `dev` and say what happened, a line a case. `r` is
/// the caller's storage for the renderer (not yet started) and `asm_work`
/// the assembler's scratch; `now_us` (a clock) lets the last case measure
/// the fill rate.
pub fn selfTest(dev: Device, r: *Renderer, asm_work: *ir3_asm.Work, log: *const fn (line: []const u8) void, now_us: ?*const fn () u64) SelfTest {
    const W = 64;
    const H = 32;
    r.init(dev, asm_work, .{ .stream_bytes = 64 * 1024, .state_bytes = 4096 }) catch |e| {
        var buf: [120]u8 = undefined;
        log(std.fmt.bufPrint(&buf, "draw self-test: the renderer did not start ({s})", .{@errorName(e)}) catch "draw self-test: the renderer did not start");
        return .{ .failed = 1 };
    };
    defer r.deinit();
    const pixels = dev.alloc(W * H * 4) catch return .{ .failed = 1 };
    defer dev.free(pixels);
    const tex_buf = dev.alloc(4096) catch return .{ .failed = 1 };
    defer dev.free(tex_buf);
    const t = Target{ .va = pixels.va, .width = W, .height = H, .pitch = W * 4, .format = .bgra8 };
    var c = Run{ .r = r, .dev = dev, .target = t, .pixels = pixels, .log = log };
    c.say("draw self-test: the graphics pipeline (rectangles, textures, blending), programs at 0x{x}, a {d} x {d} target at 0x{x}", .{ r.code.va, W, H, pixels.va });

    const BLUE = Color{ 0, 0, 0.5, 1 };
    const blue: u32 = 0xff000080;
    // An 8 x 4 texture (red rises with x, green with y) and, after it, a
    // 4 x 2 coverage mask (0, 85, 170, 255); both in rows of 64 bytes.
    const tw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, tex_buf.cpu[0 .. 4 * 64]));
    for (0..4) |y| for (0..8) |x| {
        tw[y * 16 + x] = 0xff000000 | (@as(u32, @intCast(x * 32)) << 16) | (@as(u32, @intCast(y * 64)) << 8);
    };
    for (0..2) |y| for (0..4) |x| {
        tex_buf.cpu[256 + y * 64 + x] = @intCast(x * 85);
    };
    dev.toDevice(tex_buf, 0, 4096);
    const nearest = Texture{ .va = tex_buf.va, .width = 8, .height = 4, .pitch = 64, .format = .bgra8, .filter = .nearest };
    var linear = nearest;
    linear.filter = .linear;
    const mask = Texture{ .va = tex_buf.va + 256, .width = 4, .height = 2, .pitch = 64, .format = .r8, .filter = .nearest };

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    c.check("one color over the whole target", &.{ .{ .x = 0, .y = 0, .want = blue }, .{ .x = 63, .y = 0, .want = blue }, .{ .x = 0, .y = 31, .want = blue }, .{ .x = 63, .y = 31, .want = blue }, .{ .x = 31, .y = 15, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    r.fill(.{ 4, 2, 20, 10 }, .{ 1, 0, 0, 1 }, .replace);
    c.check("a rectangle's edges", &.{ .{ .x = 4, .y = 2, .want = 0xffff0000 }, .{ .x = 19, .y = 9, .want = 0xffff0000 }, .{ .x = 3, .y = 2, .want = blue }, .{ .x = 4, .y = 1, .want = blue }, .{ .x = 20, .y = 9, .want = blue }, .{ .x = 19, .y = 10, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    r.scissor(40, 20, 50, 30);
    r.fill(.{ 0, 0, W, H }, .{ 1, 1, 1, 1 }, .replace);
    c.check("the scissor", &.{ .{ .x = 40, .y = 20, .want = 0xffffffff }, .{ .x = 49, .y = 29, .want = 0xffffffff }, .{ .x = 39, .y = 20, .want = blue }, .{ .x = 50, .y = 29, .want = blue }, .{ .x = 40, .y = 19, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    r.fill(.{ 4, 2, 20, 10 }, .{ 1, 0, 0, 1 }, .replace);
    r.fill(.{ 10, 6, 30, 16 }, .{ 0, 0.5, 0, 0.5 }, .over);
    c.check("a half-transparent color blended over", &.{ .{ .x = 10, .y = 6, .want = 0xff808000, .tol = 2 }, .{ .x = 25, .y = 12, .want = 0xff008040, .tol = 2 }, .{ .x = 9, .y = 6, .want = 0xffff0000 }, .{ .x = 30, .y = 12, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.image(.{ 2, 1, 10, 5 }, nearest, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    c.check("an image, texel for texel", &.{ .{ .x = 2, .y = 1, .want = tw[0] }, .{ .x = 9, .y = 1, .want = tw[7] }, .{ .x = 2, .y = 4, .want = tw[48] }, .{ .x = 9, .y = 4, .want = tw[55] }, .{ .x = 5, .y = 2, .want = tw[19] }, .{ .x = 10, .y = 1, .want = 0xff000000 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.image(.{ 20, 4, 36, 12 }, linear, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    c.check("an image stretched, filtered", &.{ .{ .x = 27, .y = 7, .want = 0xff000000 | (@as(u32, 32 * 3 + 8) << 16) | (@as(u32, 64 + 16) << 8), .tol = 3 }, .{ .x = 20, .y = 4, .want = tw[0], .tol = 3 }, .{ .x = 35, .y = 11, .want = tw[55], .tol = 3 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.image(.{ 40, 20, 48, 24 }, nearest, .{ 0, 0, 8, 4 }, .{ 0.5, 0.5, 0.5, 0.5 }, .over);
    c.check("an image at half opacity over", &.{ .{ .x = 47, .y = 23, .want = 0xff000000 | (@as(u32, 7 * 32 / 2) << 16) | (@as(u32, 3 * 64 / 2) << 8), .tol = 2 }, .{ .x = 40, .y = 20, .want = 0xff000000, .tol = 2 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 1, 1 }, .replace);
    r.mask(.{ 8, 8, 12, 10 }, mask, .{ 0, 0, 4, 2 }, .{ 1, 1, 1, 1 }, .over);
    c.check("a coverage mask (text)", &.{ .{ .x = 8, .y = 8, .want = 0xff0000ff, .tol = 2 }, .{ .x = 9, .y = 8, .want = 0xff5555ff, .tol = 2 }, .{ .x = 10, .y = 9, .want = 0xffaaaaff, .tol = 2 }, .{ .x = 11, .y = 9, .want = 0xffffffff, .tol = 2 } });

    // The coverage programs (Galaxy's own, where the ones above are
    // turnip's): a rounded rectangle filled, stroked, and around an image.
    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.rrect(.{ 4, 3, 28, 17 }, Shape.of(4, 3, 24, 14, 5), .{ 1, 1, 1, 1 }, .over);
    c.check("a filled rounded rectangle", &.{ .{ .x = 16, .y = 10, .want = 0xffffffff, .tol = 2 }, .{ .x = 4, .y = 10, .want = 0xffffffff, .tol = 2 }, .{ .x = 4, .y = 3, .want = 0xff000000, .tol = 2 }, .{ .x = 27, .y = 16, .want = 0xff000000, .tol = 2 }, .{ .x = 3, .y = 10, .want = 0xff000000 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.ring(.{ 34, 4, 60, 24 }, Shape.of(34, 4, 26, 20, 6), Shape.of(36, 6, 22, 16, 4), .{ 0, 1, 0, 1 }, .over);
    c.check("a stroked rounded rectangle", &.{ .{ .x = 34, .y = 14, .want = 0xff00ff00, .tol = 2 }, .{ .x = 47, .y = 4, .want = 0xff00ff00, .tol = 2 }, .{ .x = 47, .y = 14, .want = 0xff000000, .tol = 2 }, .{ .x = 34, .y = 4, .want = 0xff000000, .tol = 2 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.imageRR(.{ 8, 20, 16, 24 }, nearest, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, Shape.of(8, 20, 8, 4, 2), .over);
    c.check("an image inside a rounded rectangle", &.{ .{ .x = 12, .y = 22, .want = tw[2 * 16 + 4], .tol = 2 }, .{ .x = 11, .y = 21, .want = tw[16 + 3], .tol = 2 }, .{ .x = 8, .y = 20, .want = 0xff000000, .tol = 40 }, .{ .x = 16, .y = 22, .want = 0xff000000 } });

    // A path's paint and a glow (red to blue through the mask's 0, 85,
    // 170, 255; a white disc, whole at its centre, nothing past 12 pixels).
    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.maskGradient(.{ 8, 8, 12, 10 }, mask, .{ 0, 0, 4, 2 }, .{ .q1 = .{ 0.25, 0, -2 }, .a = .{ 1, 0, 0, 1 }, .b = .{ 0.5, 0, 0.5, 1 }, .c = .{ 0, 0, 1, 1 } }, 1, .over);
    c.check("a mask times a gradient", &.{ .{ .x = 11, .y = 9, .want = 0xff2000df, .tol = 2 }, .{ .x = 10, .y = 8, .want = 0xff40006a, .tol = 2 }, .{ .x = 9, .y = 9, .want = 0xff350020, .tol = 2 }, .{ .x = 8, .y = 8, .want = 0xff000000, .tol = 2 }, .{ .x = 12, .y = 9, .want = 0xff000000 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.glow(.{ 20, 4, 44, 28 }, 32, 16, 4, 12, .{ 1, 1, 1, 1 }, .over);
    c.check("a glow", &.{ .{ .x = 32, .y = 15, .want = 0xffffffff, .tol = 2 }, .{ .x = 39, .y = 16, .want = 0xff979797, .tol = 3 }, .{ .x = 22, .y = 6, .want = 0xff000000 }, .{ .x = 45, .y = 16, .want = 0xff000000 } });

    // A soft shadow (black, two pixels of sigma, under a 32 x 16 shape:
    // 40% at the edge, nothing deeper than six pixels inside).
    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 1, 1, 1, 1 }, .replace);
    r.shadow(.{ 10, 2, 54, 30 }, Shape.of(16, 8, 32, 16, 4), 2, .{ 0, 0, 0, 1 }, .{}, .over);
    c.check("a soft shadow", &.{ .{ .x = 32, .y = 7, .want = 0xff999999, .tol = 3 }, .{ .x = 32, .y = 10, .want = 0xff1b1b1b, .tol = 3 }, .{ .x = 32, .y = 16, .want = 0xffffffff }, .{ .x = 9, .y = 16, .want = 0xffffffff } });

    // How fast it fills: a 1024 x 1024 target, an image the same size over
    // it once and a half-transparent color 31 times (32 megapixels blended).
    if (!c.res.lost) speed: {
        const clock = now_us orelse break :speed;
        const N = 1024;
        const big = dev.alloc(N * N * 4) catch break :speed;
        defer dev.free(big);
        const src = dev.alloc(N * N * 4) catch break :speed;
        defer dev.free(src);
        const sw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, src.cpu));
        for (sw, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @truncate(i * 2654435761));
        dev.toDevice(src, 0, N * N * 4);
        const bt = Target{ .va = big.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8 };
        const st = Texture{ .va = src.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8, .filter = .linear };
        r.begin(bt);
        r.image(.{ 0, 0, N, N }, st, .{ 0, 0, N, N }, .{ 1, 1, 1, 1 }, .replace);
        for (0..31) |_| r.fill(.{ 0, 0, N, N }, .{ 0.01, 0.01, 0.01, 0.02 }, .over);
        c.say("draw self-test: the fill rate ...", .{});
        const t0 = clock();
        r.run(5_000_000) catch |e| {
            c.say("draw self-test: the fill rate: the pass did not finish ({s})", .{@errorName(e)});
            c.res.lost = true;
            c.res.failed += 1;
            break :speed;
        };
        const us = @max(clock() - t0, 1);
        c.res.mpx_per_s = @intCast(@min(@as(u64, 32) * N * N / us, std.math.maxInt(u32)));
        dev.fromDevice(big, 0, 16);
        const first: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, big.cpu[0..16]));
        c.say("draw self-test: 32 megapixels blended in {d} us: {d} megapixels a second (first pixel {x:0>8})", .{ us, c.res.mpx_per_s, first[0] });
    }
    c.say("draw self-test: {d} passed, {d} failed{s}", .{ c.res.passed, c.res.failed, if (c.res.lost) ", and the GPU did not finish a pass" else "" });
    return c.res;
}

fn testLog(line: []const u8) void {
    if (std.mem.indexOf(u8, line, " is ") != null or std.mem.indexOf(u8, line, "did not") != null) std.debug.print("{s}\n", .{line});
}

test "the self-test passes on the emulated device" {
    T.dev = .{ .arena = &T.arena, .gpu_view = &T.gpu_view, .log = &T.log };
    // (no clock: the fill-rate case's megapixels would take the emulator minutes)
    const res = selfTest(T.dev.device(), &T.r, &T.asm_work, &testLog, null);
    try std.testing.expectEqual(@as(u32, 14), res.passed);
    try std.testing.expectEqual(@as(u32, 0), res.failed);
    try std.testing.expect(!res.lost);
}
