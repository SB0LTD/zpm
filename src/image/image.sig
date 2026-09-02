// image — RGBA8 image view + analysis primitives.
// Layer 0: Core. Pure computation, no allocator, no platform deps.
//
// A lightweight non-owning view over a tightly packed RGBA8 buffer, plus the
// primitives the layout and text analyzers build on: color sampling, luminance,
// background detection, ink projections (row/column histograms of non-background
// pixels), dominant-color estimation, and bounding-box helpers.

pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn luma(self: Rgba) u8 {
        // Rec. 601 luma; integer approximation.
        const y = (@as(u32, self.r) * 77 + @as(u32, self.g) * 150 + @as(u32, self.b) * 29) >> 8;
        return @intCast(@min(y, 255));
    }

    pub fn dist(a: Rgba, b: Rgba) u32 {
        const dr = diff(a.r, b.r);
        const dg = diff(a.g, b.g);
        const db = diff(a.b, b.b);
        return @as(u32, dr) + dg + db;
    }
};

fn diff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn right(self: Rect) u32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) u32 {
        return self.y + self.h;
    }
    pub fn area(self: Rect) u32 {
        return self.w * self.h;
    }
    pub fn centerX(self: Rect) u32 {
        return self.x + self.w / 2;
    }
    pub fn centerY(self: Rect) u32 {
        return self.y + self.h / 2;
    }
};

pub const Image = struct {
    pixels: []const u8, // tightly packed RGBA8, row-major, top-left origin
    width: u32,
    height: u32,

    pub fn init(pixels: []const u8, width: u32, height: u32) Image {
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn at(self: Image, x: u32, y: u32) Rgba {
        const i = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        return .{ .r = self.pixels[i], .g = self.pixels[i + 1], .b = self.pixels[i + 2], .a = self.pixels[i + 3] };
    }

    pub fn lumaAt(self: Image, x: u32, y: u32) u8 {
        return self.at(x, y).luma();
    }

    /// Estimate the background color by sampling the four corners + edge
    /// midpoints and taking the most common. UI screenshots have a dominant
    /// page/section background, which these border points reliably hit.
    pub fn backgroundColor(self: Image) Rgba {
        if (self.width == 0 or self.height == 0) return .{ .r = 255, .g = 255, .b = 255 };
        const w = self.width;
        const h = self.height;
        const samples = [_]Rgba{
            self.at(0, 0),
            self.at(w - 1, 0),
            self.at(0, h - 1),
            self.at(w - 1, h - 1),
            self.at(w / 2, 0),
            self.at(w / 2, h - 1),
            self.at(0, h / 2),
            self.at(w - 1, h / 2),
        };
        // Cluster by nearness (threshold 24 total channel diff), pick largest.
        var best_idx: usize = 0;
        var best_count: usize = 0;
        for (samples, 0..) |c, i| {
            var count: usize = 0;
            for (samples) |d| {
                if (Rgba.dist(c, d) <= 24) count += 1;
            }
            if (count > best_count) {
                best_count = count;
                best_idx = i;
            }
        }
        return samples[best_idx];
    }

    /// A pixel is "ink" if it differs from `bg` by more than `threshold`
    /// (summed channel distance).
    pub fn isInk(self: Image, x: u32, y: u32, bg: Rgba, threshold: u32) bool {
        return Rgba.dist(self.at(x, y), bg) > threshold;
    }
};

/// Count ink pixels per row within `region`. `out` must have `region.h` entries.
pub fn rowInk(img: Image, region: Rect, bg: Rgba, threshold: u32, out: []u32) void {
    var yy: u32 = 0;
    while (yy < region.h and yy < out.len) : (yy += 1) {
        var count: u32 = 0;
        var xx: u32 = 0;
        while (xx < region.w) : (xx += 1) {
            if (img.isInk(region.x + xx, region.y + yy, bg, threshold)) count += 1;
        }
        out[yy] = count;
    }
}

/// Count ink pixels per column within `region`. `out` must have `region.w` entries.
pub fn colInk(img: Image, region: Rect, bg: Rgba, threshold: u32, out: []u32) void {
    var xx: u32 = 0;
    while (xx < region.w and xx < out.len) : (xx += 1) {
        var count: u32 = 0;
        var yy: u32 = 0;
        while (yy < region.h) : (yy += 1) {
            if (img.isInk(region.x + xx, region.y + yy, bg, threshold)) count += 1;
        }
        out[xx] = count;
    }
}

/// Tight bounding box of ink within `region`. Returns null if no ink found.
pub fn inkBounds(img: Image, region: Rect, bg: Rgba, threshold: u32) ?Rect {
    var min_x: u32 = region.right();
    var min_y: u32 = region.bottom();
    var max_x: u32 = region.x;
    var max_y: u32 = region.y;
    var found = false;
    var yy: u32 = 0;
    while (yy < region.h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < region.w) : (xx += 1) {
            const px = region.x + xx;
            const py = region.y + yy;
            if (img.isInk(px, py, bg, threshold)) {
                found = true;
                if (px < min_x) min_x = px;
                if (py < min_y) min_y = py;
                if (px > max_x) max_x = px;
                if (py > max_y) max_y = py;
            }
        }
    }
    if (!found) return null;
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x + 1, .h = max_y - min_y + 1 };
}

/// Average color of ink pixels in `region` (the dominant foreground/text color).
/// Falls back to the background color when there is no ink.
pub fn inkColor(img: Image, region: Rect, bg: Rgba, threshold: u32) Rgba {
    var sr: u64 = 0;
    var sg: u64 = 0;
    var sb: u64 = 0;
    var n: u64 = 0;
    var yy: u32 = 0;
    while (yy < region.h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < region.w) : (xx += 1) {
            const px = region.x + xx;
            const py = region.y + yy;
            if (img.isInk(px, py, bg, threshold)) {
                const c = img.at(px, py);
                sr += c.r;
                sg += c.g;
                sb += c.b;
                n += 1;
            }
        }
    }
    if (n == 0) return bg;
    return .{ .r = @intCast(sr / n), .g = @intCast(sg / n), .b = @intCast(sb / n) };
}

/// Average color of ALL pixels in `region` (its overall fill / block color).
pub fn averageColor(img: Image, region: Rect) Rgba {
    var sr: u64 = 0;
    var sg: u64 = 0;
    var sb: u64 = 0;
    var n: u64 = 0;
    var yy: u32 = 0;
    while (yy < region.h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < region.w) : (xx += 1) {
            const c = img.at(region.x + xx, region.y + yy);
            sr += c.r;
            sg += c.g;
            sb += c.b;
            n += 1;
        }
    }
    if (n == 0) return .{ .r = 255, .g = 255, .b = 255 };
    return .{ .r = @intCast(sr / n), .g = @intCast(sg / n), .b = @intCast(sb / n) };
}

/// Ink density of a region: fraction (per-mille) of pixels that are ink.
pub fn inkDensityPermille(img: Image, region: Rect, bg: Rgba, threshold: u32) u32 {
    if (region.area() == 0) return 0;
    var count: u64 = 0;
    var yy: u32 = 0;
    while (yy < region.h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < region.w) : (xx += 1) {
            if (img.isInk(region.x + xx, region.y + yy, bg, threshold)) count += 1;
        }
    }
    return @intCast((count * 1000) / region.area());
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");

fn testImage(comptime w: u32, comptime h: u32) [w * h * 4]u8 {
    return @splat(255); // white
}

fn setPx(buf: []u8, w: u32, x: u32, y: u32, r: u8, g: u8, b: u8) void {
    const i = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
    buf[i] = r;
    buf[i + 1] = g;
    buf[i + 2] = b;
    buf[i + 3] = 255;
}

test "luma of pure colors" {
    try std.testing.expectEqual(@as(u8, 0), (Rgba{ .r = 0, .g = 0, .b = 0 }).luma());
    try std.testing.expectEqual(@as(u8, 255), (Rgba{ .r = 255, .g = 255, .b = 255 }).luma());
    try std.testing.expect((Rgba{ .r = 0, .g = 255, .b = 0 }).luma() > (Rgba{ .r = 255, .g = 0, .b = 0 }).luma());
}

test "background detection on white canvas" {
    var buf = testImage(8, 8);
    const img = Image.init(&buf, 8, 8);
    const bg = img.backgroundColor();
    try std.testing.expectEqual(@as(u8, 255), bg.r);
}

test "ink bounds around a drawn box" {
    const w: u32 = 16;
    const h: u32 = 16;
    var buf = testImage(w, h);
    // Draw a black 4x3 box at (5,6).
    var y: u32 = 6;
    while (y < 9) : (y += 1) {
        var x: u32 = 5;
        while (x < 9) : (x += 1) setPx(&buf, w, x, y, 0, 0, 0);
    }
    const img = Image.init(&buf, w, h);
    const bg = img.backgroundColor();
    const b = inkBounds(img, .{ .x = 0, .y = 0, .w = w, .h = h }, bg, 64).?;
    try std.testing.expectEqual(@as(u32, 5), b.x);
    try std.testing.expectEqual(@as(u32, 6), b.y);
    try std.testing.expectEqual(@as(u32, 4), b.w);
    try std.testing.expectEqual(@as(u32, 3), b.h);
}

test "ink color of a black box is black-ish" {
    const w: u32 = 16;
    const h: u32 = 16;
    var buf = testImage(w, h);
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) setPx(&buf, w, x, y, 10, 10, 10);
    }
    const img = Image.init(&buf, w, h);
    const c = inkColor(img, .{ .x = 0, .y = 0, .w = w, .h = h }, .{ .r = 255, .g = 255, .b = 255 }, 64);
    try std.testing.expect(c.r < 30 and c.g < 30 and c.b < 30);
}

test "row projection counts ink rows" {
    const w: u32 = 8;
    const h: u32 = 8;
    var buf = testImage(w, h);
    // Fill row 3 with black.
    var x: u32 = 0;
    while (x < w) : (x += 1) setPx(&buf, w, x, 3, 0, 0, 0);
    const img = Image.init(&buf, w, h);
    var rows: [8]u32 = undefined;
    rowInk(img, .{ .x = 0, .y = 0, .w = w, .h = h }, .{ .r = 255, .g = 255, .b = 255 }, 64, &rows);
    try std.testing.expectEqual(@as(u32, 0), rows[2]);
    try std.testing.expectEqual(@as(u32, 8), rows[3]);
    try std.testing.expectEqual(@as(u32, 0), rows[4]);
}
