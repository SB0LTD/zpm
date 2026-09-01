// ui_detect — pure color-signature element detection.
// Layer 0: Core. No platform deps, no I/O, no allocation.
//
// General-purpose building block for visual UI automation and image analysis:
// given an RGBA pixel buffer and a target color (with tolerance), find the
// largest connected-ish region of matching pixels and report its bounding box
// and centroid. Callers decide what to do with the result.
//
// The algorithm is a single-pass row-scan accumulator: for every pixel within
// the color tolerance we grow a bounding box and count hits, then require the
// hit count to meet a minimum area and fill ratio. This is intentionally simple
// and allocation-free (O(width*height) time, O(1) space) so it runs in a tight
// daemon loop without a heap.

/// An 8-bit RGB target with a per-channel tolerance.
pub const ColorSignature = struct {
    r: u8,
    g: u8,
    b: u8,
    /// Max absolute per-channel difference for a pixel to count as a match.
    tolerance: u8 = 24,

    pub fn matches(self: ColorSignature, r: u8, g: u8, b: u8) bool {
        return absDiff(self.r, r) <= self.tolerance and
            absDiff(self.g, g) <= self.tolerance and
            absDiff(self.b, b) <= self.tolerance;
    }
};

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Constraints a candidate region must satisfy to be reported as a match.
pub const DetectParams = struct {
    signature: ColorSignature,
    /// Minimum number of matching pixels for the region to be considered real.
    min_area: u32 = 400,
    /// Minimum fraction (0..1000 per-mille) of the bounding box that must be
    /// matching pixels — filters out sparse noise scattered across the image.
    min_fill_permille: u32 = 500,
};

pub const Match = struct {
    found: bool = false,
    /// Centroid of matching pixels (buffer-local coordinates, top-left origin).
    center_x: u32 = 0,
    center_y: u32 = 0,
    /// Bounding box of matching pixels.
    min_x: u32 = 0,
    min_y: u32 = 0,
    max_x: u32 = 0,
    max_y: u32 = 0,
    /// Number of matching pixels.
    area: u32 = 0,
};

/// Scan a tightly-packed RGBA buffer (`width*height*4` bytes, row-major,
/// top-left origin) for the configured color signature.
///
/// Returns the centroid + bounding box of all matching pixels when the region
/// satisfies `min_area` and `min_fill_permille`, otherwise `found = false`.
pub fn detect(pixels: []const u8, width: u32, height: u32, params: DetectParams) Match {
    if (width == 0 or height == 0) return .{};
    if (pixels.len < @as(usize, width) * @as(usize, height) * 4) return .{};

    var count: u32 = 0;
    var sum_x: u64 = 0;
    var sum_y: u64 = 0;
    var min_x: u32 = width;
    var min_y: u32 = height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        const row_base: usize = @as(usize, y) * @as(usize, width) * 4;
        while (x < width) : (x += 1) {
            const i = row_base + @as(usize, x) * 4;
            const r = pixels[i];
            const g = pixels[i + 1];
            const b = pixels[i + 2];
            if (params.signature.matches(r, g, b)) {
                count += 1;
                sum_x += x;
                sum_y += y;
                if (x < min_x) min_x = x;
                if (y < min_y) min_y = y;
                if (x > max_x) max_x = x;
                if (y > max_y) max_y = y;
            }
        }
    }

    if (count < params.min_area) return .{};

    const bbox_w = max_x - min_x + 1;
    const bbox_h = max_y - min_y + 1;
    const bbox_area: u64 = @as(u64, bbox_w) * @as(u64, bbox_h);
    if (bbox_area == 0) return .{};

    // fill ratio in per-mille = count * 1000 / bbox_area
    const fill_permille: u64 = (@as(u64, count) * 1000) / bbox_area;
    if (fill_permille < params.min_fill_permille) return .{};

    return .{
        .found = true,
        .center_x = @intCast(sum_x / count),
        .center_y = @intCast(sum_y / count),
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
        .area = count,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");

fn setPixel(buf: []u8, width: u32, x: u32, y: u32, r: u8, g: u8, b: u8) void {
    const i = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
    buf[i] = r;
    buf[i + 1] = g;
    buf[i + 2] = b;
    buf[i + 3] = 255;
}

test "empty buffer yields no match" {
    const m = detect(&.{}, 0, 0, .{ .signature = .{ .r = 128, .g = 100, .b = 220 } });
    try std.testing.expect(!m.found);
}

test "solid purple block is detected with correct centroid" {
    const w: u32 = 40;
    const h: u32 = 20;
    var buf: [w * h * 4]u8 = @splat(0);
    // Fill a 10x8 purple rectangle at (15,6)..(24,13).
    var y: u32 = 6;
    while (y <= 13) : (y += 1) {
        var x: u32 = 15;
        while (x <= 24) : (x += 1) setPixel(&buf, w, x, y, 124, 92, 219);
    }
    const m = detect(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 50,
        .min_fill_permille = 800,
    });
    try std.testing.expect(m.found);
    // centroid of 15..24 = 19.5 -> 19 (integer), 6..13 = 9.5 -> 9
    try std.testing.expectEqual(@as(u32, 19), m.center_x);
    try std.testing.expectEqual(@as(u32, 9), m.center_y);
    try std.testing.expectEqual(@as(u32, 80), m.area);
}

test "color outside tolerance is rejected" {
    const w: u32 = 16;
    const h: u32 = 16;
    var buf: [w * h * 4]u8 = @splat(0);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) setPixel(&buf, w, x, y, 10, 200, 10); // green
    }
    const m = detect(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 10,
    });
    try std.testing.expect(!m.found);
}

test "sparse scattered matches fail the fill ratio" {
    const w: u32 = 32;
    const h: u32 = 32;
    var buf: [w * h * 4]u8 = @splat(0);
    // Two far-apart purple pixels: large bbox, tiny fill.
    setPixel(&buf, w, 1, 1, 124, 92, 219);
    setPixel(&buf, w, 30, 30, 124, 92, 219);
    const m = detect(&buf, w, h, .{
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 20 },
        .min_area = 2,
        .min_fill_permille = 500,
    });
    try std.testing.expect(!m.found);
}
