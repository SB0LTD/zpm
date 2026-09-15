// layout — whitespace-projection layout segmentation (gradient-aware, 2D).
// Layer 0: Core. Pure computation, no allocator (caller-provided region array).
//
// Segments a UI screenshot into a flat list of rectangular regions and
// classifies each. The algorithm:
//
//   1. Build a gradient-aware background model (handles soft page gradients).
//   2. Split the page vertically into horizontal BANDS separated by runs of
//      "empty" rows (rows whose ink count is below a small threshold).
//   3. Within each band, split horizontally into COLUMN GROUPS separated by
//      runs of empty columns. This is what separates a left text column from a
//      right-hand photo that share the same rows.
//   4. Within each column group, split again into vertical LINES/blocks and
//      classify each by geometry + ink/fill statistics into a RegionKind.
//
// The two-level (band -> column -> block) split is deliberately recursive so a
// hero section (headline column beside a photo) decomposes correctly instead of
// collapsing into one giant region. Fine typographic analysis lives in
// text_analyze; this module produces the coarse structure that maps onto
// Elementor containers/widgets.

const img_mod = @import("image");

const Image = img_mod.Image;
const Rgba = img_mod.Rgba;
const Rect = img_mod.Rect;
const BgModel = img_mod.BgModel;

pub const RegionKind = enum {
    bar, // wide, short horizontal band (nav bar, footer)
    eyebrow, // small all-caps / label text above a heading
    heading, // large prominent text (one or few lines)
    text_line, // ordinary single line of text
    body_text, // a multi-line paragraph of small text
    button, // small, solid-filled, rounded block with centered ink
    image_block, // dense/colorful rectangular block (photo)
    unknown,
};

pub const Region = struct {
    rect: Rect,
    kind: RegionKind = .unknown,
    ink_density_permille: u32 = 0,
    line_count: u32 = 1,
    /// Estimated dominant text/ink height in px (per line), 0 if not text.
    text_height: u32 = 0,
    ink_color: Rgba = .{ .r = 0, .g = 0, .b = 0 },
    fill_color: Rgba = .{ .r = 255, .g = 255, .b = 255 },
};

pub const Params = struct {
    /// Ink threshold (summed channel distance from background). Set high enough
    /// to ignore soft decorative tints/glows (which are large low-contrast
    /// areas that would otherwise read as one giant merged region) while still
    /// catching real content: dark text, photos, and solid buttons.
    ink_threshold: u32 = 72,
    /// A row/column is "empty" if its ink count is at or below this. A small
    /// non-zero value tolerates stray anti-aliased pixels.
    empty_ink: u32 = 2,
    /// Minimum run of empty rows to split bands (px).
    band_gap: u32 = 14,
    /// Minimum run of empty columns to split a band into columns (px).
    column_gap: u32 = 40,
    /// Minimum run of empty columns to split a column group into blocks (px).
    block_gap: u32 = 18,
    /// Minimum run of empty rows to split a column block into lines (px).
    line_gap: u32 = 10,
    /// Ignore blocks smaller than this in either dimension (px).
    min_dim: u32 = 6,
};

/// Segment `img` into regions written to `out`. Returns the count.
/// `row_scratch` must hold at least `img.height` u32s; `col_scratch` at least
/// `img.width` u32s. No heap allocation.
pub fn segment(
    img: Image,
    bg_flat: Rgba,
    params: Params,
    row_scratch: []u32,
    col_scratch: []u32,
    out: []Region,
) usize {
    _ = bg_flat; // kept for API compatibility; we build a richer model below.
    if (img.width == 0 or img.height == 0) return 0;
    const bg = img_mod.backgroundModel(img);

    const full = Rect{ .x = 0, .y = 0, .w = img.width, .h = img.height };
    img_mod.rowInkBg(img, full, bg, params.ink_threshold, row_scratch);

    var count: usize = 0;
    var y: u32 = 0;
    while (y < img.height) {
        if (row_scratch[y] <= params.empty_ink) {
            y += 1;
            continue;
        }
        const band_start = y;
        var gap: u32 = 0;
        var band_end = y;
        while (y < img.height) : (y += 1) {
            if (row_scratch[y] > params.empty_ink) {
                band_end = y;
                gap = 0;
            } else {
                gap += 1;
                if (gap >= params.band_gap) break;
            }
        }
        const band = Rect{ .x = 0, .y = band_start, .w = img.width, .h = band_end - band_start + 1 };
        count = segmentBandColumns(img, bg, params, band, col_scratch, row_scratch, out, count);
        if (count >= out.len) break;
    }
    return count;
}

/// Split one horizontal band into column groups (wide empty-column gaps), then
/// recurse into each column group. This is the step that separates side-by-side
/// content (e.g. a text column and a photo) that shares the same rows.
fn segmentBandColumns(
    img: Image,
    bg: BgModel,
    params: Params,
    band: Rect,
    col_scratch: []u32,
    row_scratch: []u32,
    out: []Region,
    start_count: usize,
) usize {
    var count = start_count;
    img_mod.colInkBg(img, band, bg, params.ink_threshold, col_scratch[0..band.w]);

    var x: u32 = 0;
    while (x < band.w) {
        if (col_scratch[x] <= params.empty_ink) {
            x += 1;
            continue;
        }
        const col_start = x;
        var gap: u32 = 0;
        var col_end = x;
        while (x < band.w) : (x += 1) {
            if (col_scratch[x] > params.empty_ink) {
                col_end = x;
                gap = 0;
            } else {
                gap += 1;
                if (gap >= params.column_gap) break;
            }
        }
        const col_rect = Rect{
            .x = band.x + col_start,
            .y = band.y,
            .w = col_end - col_start + 1,
            .h = band.h,
        };
        const tight = img_mod.inkBoundsBg(img, col_rect, bg, params.ink_threshold) orelse continue;
        if (tight.w < params.min_dim or tight.h < params.min_dim) continue;
        count = segmentColumn(img, bg, params, tight, col_scratch, row_scratch, out, count);
        if (count >= out.len) break;
    }
    return count;
}

/// A column group may be a single photo, a stack of text lines, or a row of
/// buttons. Decide: if it is one dense block, keep it whole (photo/button).
/// Otherwise split it into vertical lines and classify each.
fn segmentColumn(
    img: Image,
    bg: BgModel,
    params: Params,
    col: Rect,
    col_scratch: []u32,
    row_scratch: []u32,
    out: []Region,
    start_count: usize,
) usize {
    var count = start_count;

    // A large, dense block is a photo/graphic — do not shred it into lines.
    const col_density = img_mod.inkDensityPermilleBg(img, col, bg, params.ink_threshold);
    const big = col.w >= 120 and col.h >= 120;
    if (big and col_density >= 600) {
        if (count < out.len) {
            out[count] = classify(img, bg, params, col, 1, col.h);
            count += 1;
        }
        return count;
    }

    // Split the column into horizontal lines by empty rows (relative to band).
    img_mod.rowInkBg(img, col, bg, params.ink_threshold, row_scratch[0..col.h]);
    var y: u32 = 0;
    while (y < col.h) {
        if (row_scratch[y] <= params.empty_ink) {
            y += 1;
            continue;
        }
        const start = y;
        var gap: u32 = 0;
        var end = y;
        while (y < col.h) : (y += 1) {
            if (row_scratch[y] > params.empty_ink) {
                end = y;
                gap = 0;
            } else {
                gap += 1;
                if (gap >= params.line_gap) break;
            }
        }
        const line_band = Rect{ .x = col.x, .y = col.y + start, .w = col.w, .h = end - start + 1 };
        // Within a line band, split into blocks by empty columns (separates
        // side-by-side buttons, or icon+label).
        count = splitLineBlocks(img, bg, params, line_band, col_scratch, row_scratch, out, count);
        if (count >= out.len) break;
    }
    return count;
}

fn splitLineBlocks(
    img: Image,
    bg: BgModel,
    params: Params,
    line_band: Rect,
    col_scratch: []u32,
    row_scratch: []u32,
    out: []Region,
    start_count: usize,
) usize {
    var count = start_count;
    img_mod.colInkBg(img, line_band, bg, params.ink_threshold, col_scratch[0..line_band.w]);

    var x: u32 = 0;
    while (x < line_band.w) {
        if (col_scratch[x] <= params.empty_ink) {
            x += 1;
            continue;
        }
        const bstart = x;
        var gap: u32 = 0;
        var bend = x;
        while (x < line_band.w) : (x += 1) {
            if (col_scratch[x] > params.empty_ink) {
                bend = x;
                gap = 0;
            } else {
                gap += 1;
                if (gap >= params.block_gap) break;
            }
        }
        const raw = Rect{ .x = line_band.x + bstart, .y = line_band.y, .w = bend - bstart + 1, .h = line_band.h };
        const tight = img_mod.inkBoundsBg(img, raw, bg, params.ink_threshold) orelse continue;
        if (tight.w < params.min_dim or tight.h < params.min_dim) continue;
        if (count >= out.len) break;
        // Estimate line count within this block for text height.
        const lc = countLines(img, bg, params, tight, row_scratch);
        const th = if (lc > 0) tight.h / lc else tight.h;
        out[count] = classify(img, bg, params, tight, lc, th);
        count += 1;
    }
    return count;
}

/// Count text lines in a block by empty-row runs (tolerant threshold).
fn countLines(img: Image, bg: BgModel, params: Params, rect: Rect, row_scratch: []u32) u32 {
    img_mod.rowInkBg(img, rect, bg, params.ink_threshold, row_scratch[0..rect.h]);
    var lines: u32 = 0;
    var y: u32 = 0;
    while (y < rect.h) {
        if (row_scratch[y] <= params.empty_ink) {
            y += 1;
            continue;
        }
        lines += 1;
        var gap: u32 = 0;
        while (y < rect.h) : (y += 1) {
            if (row_scratch[y] > params.empty_ink) {
                gap = 0;
            } else {
                gap += 1;
                if (gap >= params.line_gap) break;
            }
        }
    }
    return if (lines == 0) 1 else lines;
}

/// Classify a tight region by geometry + ink/fill statistics.
fn classify(img: Image, bg: BgModel, params: Params, rect: Rect, line_count: u32, text_height: u32) Region {
    const density = img_mod.inkDensityPermilleBg(img, rect, bg, params.ink_threshold);
    const ink = img_mod.inkColorBg(img, rect, bg, params.ink_threshold);
    const fill = img_mod.averageColor(img, rect);
    const local_bg = bg.at(rect.centerX(), rect.centerY());
    const aspect_x100 = if (rect.h > 0) (rect.w * 100) / rect.h else 0;

    // A solid fill: most pixels are a single non-background color (density
    // high). Text is the opposite — mostly background with sparse strokes.
    const fill_vs_bg = Rgba.dist(fill, local_bg);
    const is_solid_fill = fill_vs_bg > 30 and density >= 560;
    const compact_button = rect.h >= 20 and rect.h <= 110 and rect.w >= 60 and rect.w <= 560 and
        aspect_x100 >= 130 and aspect_x100 <= 1200;

    var kind: RegionKind = .unknown;

    // A photo/graphic must be reasonably large in BOTH dimensions; a thin dense
    // sliver (e.g. a single bold glyph or a decorative rule) is not an image.
    const image_like = is_solid_fill and rect.w >= 96 and rect.h >= 96 and
        aspect_x100 >= 25 and aspect_x100 <= 400;

    if (aspect_x100 >= 1200 and rect.h <= 64 and density >= 500) {
        kind = .bar; // very wide, short, filled: nav/footer/divider
    } else if (is_solid_fill and compact_button) {
        kind = .button;
    } else if (image_like) {
        kind = .image_block; // large dense photo/graphic
    } else if (line_count >= 3 and text_height <= 40) {
        kind = .body_text; // paragraph of small text
    } else if (text_height >= 44 and line_count <= 4) {
        kind = .heading; // large prominent text
    } else if (text_height <= 22 and aspect_x100 >= 300 and density < 300) {
        kind = .eyebrow; // small, wide, sparse label (e.g. all-caps eyebrow)
    } else if (rect.h <= 160 and density < 560) {
        kind = .text_line;
    } else if (density >= 560 and rect.w >= 96 and rect.h >= 96) {
        kind = .image_block;
    } else {
        kind = .text_line;
    }

    return .{
        .rect = rect,
        .kind = kind,
        .ink_density_permille = density,
        .line_count = line_count,
        .text_height = if (kind == .image_block or kind == .button or kind == .bar) 0 else text_height,
        .ink_color = ink,
        .fill_color = fill,
    };
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

fn fillRect(buf: []u8, w: u32, rx: u32, ry: u32, rw: u32, rh: u32, r: u8, g: u8, b: u8) void {
    var y: u32 = ry;
    while (y < ry + rh) : (y += 1) {
        var x: u32 = rx;
        while (x < rx + rw) : (x += 1) setPx(buf, w, x, y, r, g, b);
    }
}

/// Draw a sparse "text line": thin vertical strokes every few px, so the region
/// has low ink density like real glyphs (and classifies as text, not a bar).
fn textLine(buf: []u8, w: u32, rx: u32, ry: u32, rw: u32, rh: u32) void {
    var x: u32 = rx;
    while (x < rx + rw) : (x += 6) {
        var y: u32 = ry;
        while (y < ry + rh) : (y += 1) setPx(buf, w, x, y, 20, 20, 20);
    }
}

test "two stacked bands are separated" {
    const w: u32 = 200;
    const h: u32 = 200;
    var buf: [w * h * 4]u8 = @splat(255);
    // Two text-like bars, each tall enough to clear min_dim, separated by a gap
    // larger than band_gap.
    fillRect(&buf, w, 10, 10, 180, 12, 0, 0, 0);
    fillRect(&buf, w, 10, 120, 180, 12, 0, 0, 0);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var cols: [w]u32 = undefined;
    var regions: [16]Region = undefined;
    const n = segment(image, bg, .{}, &rows, &cols, &regions);
    try std.testing.expect(n >= 2);
    try std.testing.expect(regions[0].rect.y < 60);
    try std.testing.expect(regions[1].rect.y > 100);
}

test "a wide short filled block classifies as bar" {
    const w: u32 = 300;
    const h: u32 = 60;
    var buf: [w * h * 4]u8 = @splat(255);
    fillRect(&buf, w, 0, 20, 300, 8, 0, 0, 0);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var cols: [w]u32 = undefined;
    var regions: [8]Region = undefined;
    const n = segment(image, bg, .{}, &rows, &cols, &regions);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(RegionKind.bar, regions[0].kind);
}

test "a solid dark compact block classifies as button" {
    const w: u32 = 300;
    const h: u32 = 120;
    var buf: [w * h * 4]u8 = @splat(255);
    fillRect(&buf, w, 40, 40, 160, 48, 20, 20, 20);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var cols: [w]u32 = undefined;
    var regions: [8]Region = undefined;
    const n = segment(image, bg, .{}, &rows, &cols, &regions);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(RegionKind.button, regions[0].kind);
}

test "left text column and right photo are separated" {
    const w: u32 = 800;
    const h: u32 = 480;
    var buf: [w * h * 4]u8 = @splat(255);
    // Left: a few short lines of "text" — sparse vertical strokes (low density,
    // like real glyphs), NOT solid fills, so they classify as text not bars.
    textLine(&buf, w, 40, 80, 280, 20);
    textLine(&buf, w, 40, 140, 240, 20);
    textLine(&buf, w, 40, 200, 260, 20);
    // Right: a big solid photo block around x=480..760 (gap > column_gap).
    fillRect(&buf, w, 480, 60, 280, 360, 60, 120, 160);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var cols: [w]u32 = undefined;
    var regions: [32]Region = undefined;
    const n = segment(image, bg, .{}, &rows, &cols, &regions);
    // Expect at least one text region on the left and one image block on the right.
    var saw_left_text = false;
    var saw_right_image = false;
    for (regions[0..n]) |rg| {
        if (rg.rect.x < 400 and (rg.kind == .text_line or rg.kind == .heading or rg.kind == .body_text or rg.kind == .eyebrow)) saw_left_text = true;
        if (rg.rect.x >= 400 and rg.kind == .image_block) saw_right_image = true;
    }
    try std.testing.expect(saw_left_text);
    try std.testing.expect(saw_right_image);
}
