// text_analyze — typography estimation + best-effort glyph recognition.
// Layer 0: Core. Pure computation, no allocator (caller-provided buffers).
//
// Given a text region, this recovers the measurable typographic attributes that
// a design-reconstruction tool needs:
//
//   • line grouping        — split a multi-line block into baseline-aligned lines
//   • font size (px)        — from the tallest glyph / cap height per line
//   • weight (bold?)        — from stroke thickness vs glyph height
//   • color                 — average ink color
//   • alignment             — left / center / right from ink centroid vs region
//   • per-glyph segmentation — column-gap splitting into glyph boxes
//
// It also includes a compact, feature-based glyph CLASSIFIER for clean sans-serif
// UI text. Be clear-eyed about this: recovering exact characters from a flat
// raster is inherently lossy — no font metadata, antialiasing, kerning. The
// classifier scores each glyph on shape features (aspect, a 4x4 ink-zone
// histogram, enclosed-hole count, vertical/horizontal symmetry) against a small
// prototype table and returns a best guess + confidence. Callers should treat
// low-confidence output as a hint and keep the geometry, which is reliable.

const img_mod = @import("image");

const Image = img_mod.Image;
const Rgba = img_mod.Rgba;
const Rect = img_mod.Rect;

pub const Align = enum { left, center, right };

pub const TextStats = struct {
    line_count: u32 = 0,
    /// Estimated font size in pixels (cap/ascender height of the largest line).
    font_px: u32 = 0,
    /// True if strokes are thick relative to glyph height.
    bold: bool = false,
    color: Rgba = .{ .r = 0, .g = 0, .b = 0 },
    alignment: Align = .left,
};

pub const Line = struct {
    rect: Rect,
    glyph_count: u32 = 0,
};

pub const Glyph = struct {
    rect: Rect,
    /// Best-guess character (0 if unrecognized).
    ch: u8 = 0,
    /// 0..100 confidence in `ch`.
    confidence: u8 = 0,
};

// ── Line grouping ──────────────────────────────────────────────────

/// Split a text region into lines by runs of empty rows. Writes to `out`,
/// returns the count. `row_scratch` must hold >= region.h u32s.
pub fn findLines(img: Image, region: Rect, bg: Rgba, ink_threshold: u32, row_scratch: []u32, out: []Line) u32 {
    img_mod.rowInk(img, region, bg, ink_threshold, row_scratch[0..region.h]);
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < region.h) {
        if (row_scratch[y] == 0) {
            y += 1;
            continue;
        }
        const start = y;
        while (y < region.h and row_scratch[y] > 0) : (y += 1) {}
        const line_rect = Rect{ .x = region.x, .y = region.y + start, .w = region.w, .h = y - start };
        // Tighten horizontally to ink.
        const tight = img_mod.inkBounds(img, line_rect, bg, ink_threshold) orelse continue;
        if (count >= out.len) break;
        out[count] = .{ .rect = tight };
        count += 1;
    }
    return count;
}

// ── Glyph segmentation ─────────────────────────────────────────────

/// Split a single line into glyph boxes by column gaps. `col_scratch` must hold
/// >= line.w u32s. Returns glyph count. `space_gap` is the empty-column run that
/// separates glyphs (word spaces are larger; callers can infer spaces from gap).
pub fn findGlyphs(img: Image, line: Rect, bg: Rgba, ink_threshold: u32, space_gap: u32, col_scratch: []u32, out: []Glyph) u32 {
    img_mod.colInk(img, line, bg, ink_threshold, col_scratch[0..line.w]);
    var count: u32 = 0;
    var x: u32 = 0;
    while (x < line.w) {
        if (col_scratch[x] == 0) {
            x += 1;
            continue;
        }
        const start = x;
        var gap: u32 = 0;
        var end = x;
        while (x < line.w) : (x += 1) {
            if (col_scratch[x] > 0) {
                end = x;
                gap = 0;
            } else {
                gap += 1;
                if (gap >= space_gap) break;
            }
        }
        const gbox = Rect{ .x = line.x + start, .y = line.y, .w = end - start + 1, .h = line.h };
        const tight = img_mod.inkBounds(img, gbox, bg, ink_threshold) orelse continue;
        if (count >= out.len) break;
        out[count] = .{ .rect = tight };
        count += 1;
    }
    return count;
}

// ── Feature extraction ─────────────────────────────────────────────

const Features = struct {
    aspect_x100: u32, // width*100/height
    zones: [16]u8, // 4x4 ink density per zone, 0..100
    holes: u8, // enclosed background regions
    sym_v: u8, // vertical mirror symmetry, 0..100
};

fn extractFeatures(img: Image, g: Rect, bg: Rgba, ink_threshold: u32) Features {
    const aspect: u32 = if (g.h > 0) (g.w * 100) / g.h else 100;
    var zones: [16]u8 = @splat(0);
    var zi: usize = 0;
    var zy: u32 = 0;
    while (zy < 4) : (zy += 1) {
        var zx: u32 = 0;
        while (zx < 4) : (zx += 1) {
            const zx0 = g.x + (g.w * zx) / 4;
            const zx1 = g.x + (g.w * (zx + 1)) / 4;
            const zy0 = g.y + (g.h * zy) / 4;
            const zy1 = g.y + (g.h * (zy + 1)) / 4;
            var ink: u32 = 0;
            var total: u32 = 0;
            var yy = zy0;
            while (yy < zy1) : (yy += 1) {
                var xx = zx0;
                while (xx < zx1) : (xx += 1) {
                    total += 1;
                    if (img.isInk(xx, yy, bg, ink_threshold)) ink += 1;
                }
            }
            zones[zi] = if (total > 0) @intCast((ink * 100) / total) else 0;
            zi += 1;
        }
    }

    // Vertical symmetry: compare left half to mirrored right half by zone.
    var sym_match: u32 = 0;
    var sym_total: u32 = 0;
    var r: u32 = 0;
    while (r < 4) : (r += 1) {
        // columns 0<->3, 1<->2
        const pairs = [_][2]usize{ .{ r * 4 + 0, r * 4 + 3 }, .{ r * 4 + 1, r * 4 + 2 } };
        for (pairs) |p| {
            const a = zones[p[0]];
            const b = zones[p[1]];
            const d = if (a > b) a - b else b - a;
            sym_match += (100 - d);
            sym_total += 100;
        }
    }
    const sym_v: u8 = if (sym_total > 0) @intCast((sym_match * 100) / sym_total) else 0;

    return .{
        .aspect_x100 = aspect,
        .zones = zones,
        .holes = countHoles(img, g, bg, ink_threshold),
        .sym_v = sym_v,
    };
}

/// Count enclosed background regions (holes) inside the glyph bbox, e.g. 'o'/'a'
/// have 1, 'B'/'8' have 2, 'l'/'i' have 0. Flood-fill from the border marks the
/// exterior; remaining background pixels form holes. Uses a bounded scanline
/// approach over a small local grid; caps glyph size for the O(area) pass.
fn countHoles(img: Image, g: Rect, bg: Rgba, ink_threshold: u32) u8 {
    const MAXW = 64;
    const MAXH = 96;
    if (g.w > MAXW or g.h > MAXH or g.w == 0 or g.h == 0) return 0;
    // grid: 0 = background unvisited, 1 = ink, 2 = exterior-connected background
    var grid: [MAXH][MAXW]u8 = undefined;
    var yy: u32 = 0;
    while (yy < g.h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < g.w) : (xx += 1) {
            grid[yy][xx] = if (img.isInk(g.x + xx, g.y + yy, bg, ink_threshold)) 1 else 0;
        }
    }
    // Iterative border flood-fill of background (4-connectivity) using repeated
    // passes until stable — bounded and allocation-free.
    // Seed: mark all border background cells as exterior.
    var xx: u32 = 0;
    while (xx < g.w) : (xx += 1) {
        if (grid[0][xx] == 0) grid[0][xx] = 2;
        if (grid[g.h - 1][xx] == 0) grid[g.h - 1][xx] = 2;
    }
    yy = 0;
    while (yy < g.h) : (yy += 1) {
        if (grid[yy][0] == 0) grid[yy][0] = 2;
        if (grid[yy][g.w - 1] == 0) grid[yy][g.w - 1] = 2;
    }
    var changed = true;
    while (changed) {
        changed = false;
        yy = 1;
        while (yy < g.h - 1) : (yy += 1) {
            xx = 1;
            while (xx < g.w - 1) : (xx += 1) {
                if (grid[yy][xx] != 0) continue;
                if (grid[yy - 1][xx] == 2 or grid[yy + 1][xx] == 2 or
                    grid[yy][xx - 1] == 2 or grid[yy][xx + 1] == 2)
                {
                    grid[yy][xx] = 2;
                    changed = true;
                }
            }
        }
    }
    // Count connected components of remaining background (value 0) = holes.
    var holes: u8 = 0;
    yy = 0;
    while (yy < g.h) : (yy += 1) {
        xx = 0;
        while (xx < g.w) : (xx += 1) {
            if (grid[yy][xx] == 0) {
                holes +|= 1;
                // Erase this component so it is counted once (border fill).
                eraseComponent(&grid, g.w, g.h, xx, yy);
            }
        }
    }
    return holes;
}

fn eraseComponent(grid: *[96][64]u8, w: u32, h: u32, sx: u32, sy: u32) void {
    // Bounded iterative fill marking the component as 3 (counted).
    grid[sy][sx] = 3;
    var changed = true;
    while (changed) {
        changed = false;
        var yy: u32 = 0;
        while (yy < h) : (yy += 1) {
            var xx: u32 = 0;
            while (xx < w) : (xx += 1) {
                if (grid[yy][xx] != 0) continue;
                const up = yy > 0 and grid[yy - 1][xx] == 3;
                const dn = yy + 1 < h and grid[yy + 1][xx] == 3;
                const lf = xx > 0 and grid[yy][xx - 1] == 3;
                const rt = xx + 1 < w and grid[yy][xx + 1] == 3;
                if (up or dn or lf or rt) {
                    grid[yy][xx] = 3;
                    changed = true;
                }
            }
        }
    }
}

// ── Glyph classifier ───────────────────────────────────────────────
//
// Prototype table: for a small alphabet, a hand-authored feature signature.
// The classifier scores by weighted feature distance and returns best match.
// This is intentionally compact and tuned for clean sans UI text; it is a hint,
// not ground truth.

const Prototype = struct {
    ch: u8,
    holes: u8,
    aspect_lo: u32, // *100
    aspect_hi: u32,
    min_sym_v: u8,
};

const prototypes = [_]Prototype{
    // holes are the strongest discriminator; aspect + symmetry refine.
    .{ .ch = 'o', .holes = 1, .aspect_lo = 70, .aspect_hi = 130, .min_sym_v = 70 },
    .{ .ch = 'O', .holes = 1, .aspect_lo = 70, .aspect_hi = 130, .min_sym_v = 70 },
    .{ .ch = 'e', .holes = 1, .aspect_lo = 70, .aspect_hi = 120, .min_sym_v = 0 },
    .{ .ch = 'a', .holes = 1, .aspect_lo = 70, .aspect_hi = 120, .min_sym_v = 0 },
    .{ .ch = 'B', .holes = 2, .aspect_lo = 55, .aspect_hi = 100, .min_sym_v = 0 },
    .{ .ch = '8', .holes = 2, .aspect_lo = 55, .aspect_hi = 100, .min_sym_v = 60 },
    .{ .ch = 'i', .holes = 0, .aspect_lo = 10, .aspect_hi = 45, .min_sym_v = 0 },
    .{ .ch = 'l', .holes = 0, .aspect_lo = 10, .aspect_hi = 45, .min_sym_v = 0 },
    .{ .ch = 'I', .holes = 0, .aspect_lo = 10, .aspect_hi = 55, .min_sym_v = 0 },
    .{ .ch = 'H', .holes = 0, .aspect_lo = 70, .aspect_hi = 120, .min_sym_v = 60 },
    .{ .ch = 'n', .holes = 0, .aspect_lo = 70, .aspect_hi = 120, .min_sym_v = 0 },
    .{ .ch = 'm', .holes = 0, .aspect_lo = 130, .aspect_hi = 200, .min_sym_v = 0 },
};

/// Classify one glyph into a best-guess character + confidence (0..100).
pub fn classifyGlyph(img: Image, g: Rect, bg: Rgba, ink_threshold: u32) Glyph {
    const f = extractFeatures(img, g, bg, ink_threshold);
    var best_ch: u8 = 0;
    var best_score: u32 = 0;
    for (prototypes) |p| {
        var score: u32 = 0;
        // Holes match is worth the most.
        if (p.holes == f.holes) score += 50;
        // Aspect within range.
        if (f.aspect_x100 >= p.aspect_lo and f.aspect_x100 <= p.aspect_hi) score += 30;
        // Symmetry requirement.
        if (f.sym_v >= p.min_sym_v) score += 20;
        if (score > best_score) {
            best_score = score;
            best_ch = p.ch;
        }
    }
    return .{ .rect = g, .ch = best_ch, .confidence = @intCast(@min(best_score, 100)) };
}

// ── Aggregate typography estimate ──────────────────────────────────

/// Estimate typography for a text region. `row_scratch` >= region.h u32s.
pub fn estimateText(img: Image, region: Rect, bg: Rgba, ink_threshold: u32, row_scratch: []u32) TextStats {
    var lines_buf: [64]Line = undefined;
    const n = findLines(img, region, bg, ink_threshold, row_scratch, &lines_buf);
    if (n == 0) return .{};

    // Font size ≈ the tallest line's ink height.
    var max_h: u32 = 0;
    for (lines_buf[0..n]) |ln| {
        if (ln.rect.h > max_h) max_h = ln.rect.h;
    }

    const color = img_mod.inkColor(img, region, bg, ink_threshold);

    // Weight: stroke thickness proxy = ink density of the region. Bold text
    // fills more of its bbox. Threshold tuned for typical UI text.
    const density = img_mod.inkDensityPermille(img, region, bg, ink_threshold);
    const bold = density > 320;

    // Alignment: compare the ink centroid X to the region center.
    const text_align = estimateAlign(img, region, bg, ink_threshold);

    return .{
        .line_count = n,
        .font_px = max_h,
        .bold = bold,
        .color = color,
        .alignment = text_align,
    };
}

fn estimateAlign(img: Image, region: Rect, bg: Rgba, ink_threshold: u32) Align {
    var sum_x: u64 = 0;
    var n: u64 = 0;
    var yy: u32 = 0;
    while (yy < region.h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < region.w) : (xx += 1) {
            if (img.isInk(region.x + xx, region.y + yy, bg, ink_threshold)) {
                sum_x += xx;
                n += 1;
            }
        }
    }
    if (n == 0) return .left;
    const centroid = sum_x / n;
    const third = region.w / 3;
    if (centroid < third) return .left;
    if (centroid > third * 2) return .right;
    return .center;
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");

fn setPx(buf: []u8, w: u32, x: u32, y: u32, r: u8, g: u8, b: u8) void {
    const i = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
    buf[i] = r;
    buf[i + 1] = g;
    buf[i + 2] = b;
    buf[i + 3] = 255;
}

fn box(buf: []u8, w: u32, rx: u32, ry: u32, rw: u32, rh: u32) void {
    var y: u32 = ry;
    while (y < ry + rh) : (y += 1) {
        var x: u32 = rx;
        while (x < rx + rw) : (x += 1) setPx(buf, w, x, y, 0, 0, 0);
    }
}

fn ring(buf: []u8, w: u32, rx: u32, ry: u32, rw: u32, rh: u32, t: u32) void {
    // Draw a rectangular ring (outline) to create one enclosed hole.
    box(buf, w, rx, ry, rw, t); // top
    box(buf, w, rx, ry + rh - t, rw, t); // bottom
    box(buf, w, rx, ry, t, rh); // left
    box(buf, w, rx + rw - t, ry, t, rh); // right
}

test "findLines splits two text lines" {
    const w: u32 = 64;
    const h: u32 = 64;
    var buf: [w * h * 4]u8 = @splat(255);
    box(&buf, w, 4, 4, 40, 8); // line 1
    box(&buf, w, 4, 24, 30, 8); // line 2 (gap between)
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var lines: [8]Line = undefined;
    const n = findLines(image, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64, &rows, &lines);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expect(lines[0].rect.y < lines[1].rect.y);
}

test "findGlyphs splits three boxes" {
    const w: u32 = 64;
    const h: u32 = 16;
    var buf: [w * h * 4]u8 = @splat(255);
    box(&buf, w, 2, 4, 6, 8);
    box(&buf, w, 14, 4, 6, 8);
    box(&buf, w, 26, 4, 6, 8);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var cols: [w]u32 = undefined;
    var glyphs: [16]Glyph = undefined;
    const n = findGlyphs(image, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64, 3, &cols, &glyphs);
    try std.testing.expectEqual(@as(u32, 3), n);
}

test "countHoles: ring has one hole, solid box has none" {
    const w: u32 = 32;
    const h: u32 = 32;
    var buf: [w * h * 4]u8 = @splat(255);
    ring(&buf, w, 4, 4, 16, 16, 2);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    const g = img_mod.inkBounds(image, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64).?;
    try std.testing.expectEqual(@as(u8, 1), countHoles(image, g, bg, 64));

    var buf2: [w * h * 4]u8 = @splat(255);
    box(&buf2, w, 4, 4, 16, 16);
    const image2 = Image.init(&buf2, w, h);
    const g2 = img_mod.inkBounds(image2, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64).?;
    try std.testing.expectEqual(@as(u8, 0), countHoles(image2, g2, bg, 64));
}

test "estimateText reports line count and font size" {
    const w: u32 = 80;
    const h: u32 = 64;
    var buf: [w * h * 4]u8 = @splat(255);
    box(&buf, w, 4, 4, 60, 20); // one tall line, height ~20
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    const stats = estimateText(image, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64, &rows);
    try std.testing.expectEqual(@as(u32, 1), stats.line_count);
    try std.testing.expectEqual(@as(u32, 20), stats.font_px);
    try std.testing.expect(stats.color.r < 40); // black ink
}

test "alignment: left-anchored ink reads left" {
    const w: u32 = 90;
    const h: u32 = 20;
    var buf: [w * h * 4]u8 = @splat(255);
    box(&buf, w, 2, 4, 20, 8); // ink in the left third
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    try std.testing.expectEqual(Align.left, estimateAlign(image, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64));
}
