// layout — whitespace-projection layout segmentation.
// Layer 0: Core. Pure computation, no allocator (caller-provided region array).
//
// Segments a UI screenshot into a flat list of rectangular regions and
// classifies each. The algorithm:
//
//   1. Split the page vertically into horizontal BANDS separated by runs of
//      "empty" rows (rows whose ink count is below a small threshold).
//   2. Within each band, split horizontally into BLOCKS separated by runs of
//      empty columns, tightening each block to its ink bounds.
//   3. Classify each block by geometry + ink statistics into a RegionKind.
//
// This is deliberately simple and deterministic — it reconstructs the coarse
// structure (bars, text lines, buttons, image blocks) that maps cleanly onto
// Elementor containers/widgets. Fine typographic analysis lives in text_analyze.

const img_mod = @import("image");

const Image = img_mod.Image;
const Rgba = img_mod.Rgba;
const Rect = img_mod.Rect;

pub const RegionKind = enum {
    bar, // wide, short horizontal band (nav bar, footer)
    text_line, // a single line of text
    button, // small, solid-filled, rounded block with centered ink
    image_block, // dense/colorful rectangular block
    unknown,
};

pub const Region = struct {
    rect: Rect,
    kind: RegionKind = .unknown,
    ink_density_permille: u32 = 0,
    ink_color: Rgba = .{ .r = 0, .g = 0, .b = 0 },
    fill_color: Rgba = .{ .r = 255, .g = 255, .b = 255 },
};

pub const Params = struct {
    /// Ink threshold (summed channel distance from background).
    ink_threshold: u32 = 48,
    /// A row/column is "empty" if its ink count is at or below this.
    empty_ink: u32 = 0,
    /// Minimum run of empty rows to split bands (px).
    band_gap: u32 = 8,
    /// Minimum run of empty columns to split blocks (px).
    block_gap: u32 = 16,
    /// Ignore blocks smaller than this in either dimension (px).
    min_dim: u32 = 4,
};

/// Segment `img` into regions written to `out`. Returns the count.
/// `row_scratch` must hold at least `img.height` u32s; `col_scratch` at least
/// `img.width` u32s. No heap allocation.
pub fn segment(
    img: Image,
    bg: Rgba,
    params: Params,
    row_scratch: []u32,
    col_scratch: []u32,
    out: []Region,
) usize {
    if (img.width == 0 or img.height == 0) return 0;
    const full = Rect{ .x = 0, .y = 0, .w = img.width, .h = img.height };
    img_mod.rowInk(img, full, bg, params.ink_threshold, row_scratch);

    var count: usize = 0;
    // Find horizontal bands: maximal runs of non-empty rows.
    var y: u32 = 0;
    while (y < img.height) {
        // Skip empty rows.
        if (row_scratch[y] <= params.empty_ink) {
            y += 1;
            continue;
        }
        // Start of a band; extend while rows are non-empty or the empty gap is
        // shorter than band_gap (keeps a text block together across tiny gaps).
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
        count = segmentBand(img, bg, params, band, col_scratch, out, count);
        if (count >= out.len) break;
    }
    return count;
}

/// Split one horizontal band into blocks by empty columns, classify, append.
fn segmentBand(
    img: Image,
    bg: Rgba,
    params: Params,
    band: Rect,
    col_scratch: []u32,
    out: []Region,
    start_count: usize,
) usize {
    var count = start_count;
    img_mod.colInk(img, band, bg, params.ink_threshold, col_scratch[0..band.w]);

    var x: u32 = 0;
    while (x < band.w) {
        if (col_scratch[x] <= params.empty_ink) {
            x += 1;
            continue;
        }
        const block_start = x;
        var gap: u32 = 0;
        var block_end = x;
        while (x < band.w) : (x += 1) {
            if (col_scratch[x] > params.empty_ink) {
                block_end = x;
                gap = 0;
            } else {
                gap += 1;
                if (gap >= params.block_gap) break;
            }
        }
        const raw_block = Rect{
            .x = band.x + block_start,
            .y = band.y,
            .w = block_end - block_start + 1,
            .h = band.h,
        };
        // Tighten to actual ink bounds (removes band-height slack).
        const tight = img_mod.inkBounds(img, raw_block, bg, params.ink_threshold) orelse continue;
        if (tight.w < params.min_dim or tight.h < params.min_dim) continue;
        if (count >= out.len) break;
        out[count] = classify(img, bg, params, tight);
        count += 1;
    }
    return count;
}

/// Classify a tight region by geometry + ink/fill statistics.
fn classify(img: Image, bg: Rgba, params: Params, rect: Rect) Region {
    const density = img_mod.inkDensityPermille(img, rect, bg, params.ink_threshold);
    const ink = img_mod.inkColor(img, rect, bg, params.ink_threshold);
    const fill = img_mod.averageColor(img, rect);
    const aspect_x100 = if (rect.h > 0) (rect.w * 100) / rect.h else 0;

    var kind: RegionKind = .unknown;

    // A button is a SOLID fill: most of its pixels are a single non-background
    // color, so its ink density (pixels differing from the page bg) is very
    // high. Text is the opposite — mostly background with sparse ink strokes.
    // Density is therefore the primary discriminator; average color alone is
    // not (a black-on-white text line averages to grey and would falsely look
    // "filled").
    const fill_vs_bg = Rgba.dist(fill, bg);
    const is_solid_fill = fill_vs_bg > 40 and density >= 620;
    const compact = rect.h <= 96 and rect.w <= 520 and aspect_x100 >= 130 and aspect_x100 <= 1100;

    if (aspect_x100 >= 1200 and rect.h <= 60 and density >= 620) {
        // Very wide, short, and solidly filled: a bar (nav/footer/divider).
        kind = .bar;
    } else if (is_solid_fill and compact) {
        kind = .button;
    } else if (rect.h <= 96 and density < 620) {
        // Modest height with sparse ink: a line (or few lines) of text.
        kind = .text_line;
    } else if (density >= 620) {
        // Tall + densely filled: an image/photo block.
        kind = .image_block;
    } else {
        kind = .text_line;
    }

    return .{
        .rect = rect,
        .kind = kind,
        .ink_density_permille = density,
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

test "two stacked bands are separated" {
    const w: u32 = 64;
    const h: u32 = 64;
    var buf: [w * h * 4]u8 = @splat(255);
    // Band 1: black bar rows 4..8. Band 2: black bar rows 40..44.
    fillRect(&buf, w, 4, 4, 56, 4, 0, 0, 0);
    fillRect(&buf, w, 4, 40, 56, 4, 0, 0, 0);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var cols: [w]u32 = undefined;
    var regions: [16]Region = undefined;
    const n = segment(image, bg, .{}, &rows, &cols, &regions);
    try std.testing.expect(n >= 2);
    // First region should be near the top, second lower.
    try std.testing.expect(regions[0].rect.y < 20);
    try std.testing.expect(regions[1].rect.y > 30);
}

test "a wide short filled block classifies as bar" {
    const w: u32 = 200;
    const h: u32 = 40;
    var buf: [w * h * 4]u8 = @splat(255);
    // Thin wide black bar (aspect very high, short).
    fillRect(&buf, w, 0, 10, 200, 5, 0, 0, 0);
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
    const w: u32 = 200;
    const h: u32 = 80;
    var buf: [w * h * 4]u8 = @splat(255);
    // Solid dark rounded-ish block ~120x40 (fill differs from white, dense).
    fillRect(&buf, w, 30, 20, 120, 40, 20, 20, 20);
    const image = Image.init(&buf, w, h);
    const bg = image.backgroundColor();
    var rows: [h]u32 = undefined;
    var cols: [w]u32 = undefined;
    var regions: [8]Region = undefined;
    const n = segment(image, bg, .{}, &rows, &cols, &regions);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(RegionKind.button, regions[0].kind);
}
