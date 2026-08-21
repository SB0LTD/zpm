// canvas.sig — Software image buffer with compositing operations
// Layer 0: Pure computation
//
// Heap-allocated RGBA pixel buffer with drawing, blitting, scaling,
// and gradient primitives. No GPU, no platform — pure software.

const std = @import("std");
const pixel = @import("pixel.sig");
const RGBA = pixel.RGBA;
const lerpColor = pixel.lerpColor;

/// Software image buffer
pub const Image = struct {
    pixels: []RGBA,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    /// Create a new image buffer
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const pixels = try allocator.alloc(RGBA, @as(usize, width) * @as(usize, height));
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Free pixel memory
    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
    }

    /// Fill entire image with a solid color
    pub fn clear(self: *Image, color: RGBA) void {
        @memset(self.pixels, color);
    }

    /// Get pixel at (x, y) — returns transparent if out of bounds
    pub fn getPixel(self: *const Image, x: u32, y: u32) RGBA {
        if (x >= self.width or y >= self.height) return RGBA.transparent;
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    /// Set pixel at (x, y) — no-op if out of bounds
    pub fn setPixel(self: *Image, x: u32, y: u32, color: RGBA) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = color;
    }

    /// Alpha-blend a pixel onto (x, y)
    pub fn blendPixel(self: *Image, x: u32, y: u32, color: RGBA) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        self.pixels[idx] = RGBA.blend(self.pixels[idx], color);
    }

    /// Fill a rectangle with a solid color (alpha-blended)
    pub fn fillRect(self: *Image, x: u32, y: u32, w: u32, h: u32, color: RGBA) void {
        var dy: u32 = 0;
        while (dy < h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < w) : (dx += 1) {
                self.blendPixel(x + dx, y + dy, color);
            }
        }
    }

    /// Draw a horizontal gradient rectangle
    pub fn gradientH(self: *Image, x: u32, y: u32, w: u32, h: u32, from: RGBA, to: RGBA) void {
        if (w == 0) return;
        var dx: u32 = 0;
        while (dx < w) : (dx += 1) {
            const t: f32 = @as(f32, @floatFromInt(dx)) / @as(f32, @floatFromInt(w));
            const color = lerpColor(from, to, t);
            var dy: u32 = 0;
            while (dy < h) : (dy += 1) {
                self.blendPixel(x + dx, y + dy, color);
            }
        }
    }

    /// Draw a vertical gradient rectangle
    pub fn gradientV(self: *Image, x: u32, y: u32, w: u32, h: u32, from: RGBA, to: RGBA) void {
        if (h == 0) return;
        var dy: u32 = 0;
        while (dy < h) : (dy += 1) {
            const t: f32 = @as(f32, @floatFromInt(dy)) / @as(f32, @floatFromInt(h));
            const color = lerpColor(from, to, t);
            var dx: u32 = 0;
            while (dx < w) : (dx += 1) {
                self.blendPixel(x + dx, y + dy, color);
            }
        }
    }

    /// Blit (copy) another image onto this one at position (dx, dy) with alpha blending
    pub fn blit(self: *Image, src: *const Image, dx: i32, dy: i32) void {
        var sy: u32 = 0;
        while (sy < src.height) : (sy += 1) {
            const target_y = dy + @as(i32, @intCast(sy));
            if (target_y < 0) continue;
            if (target_y >= @as(i32, @intCast(self.height))) break;

            var sx: u32 = 0;
            while (sx < src.width) : (sx += 1) {
                const target_x = dx + @as(i32, @intCast(sx));
                if (target_x < 0) continue;
                if (target_x >= @as(i32, @intCast(self.width))) break;

                const px = src.getPixel(sx, sy);
                if (px.a > 0) {
                    self.blendPixel(@intCast(target_x), @intCast(target_y), px);
                }
            }
        }
    }

    /// Blit with nearest-neighbor scaling
    pub fn blitScaled(self: *Image, src: *const Image, dx: i32, dy: i32, dw: u32, dh: u32) void {
        if (dw == 0 or dh == 0) return;
        var target_y: u32 = 0;
        while (target_y < dh) : (target_y += 1) {
            const py = dy + @as(i32, @intCast(target_y));
            if (py < 0) continue;
            if (py >= @as(i32, @intCast(self.height))) break;

            const sy: u32 = @intCast(@as(u64, target_y) * @as(u64, src.height) / @as(u64, dh));

            var target_x: u32 = 0;
            while (target_x < dw) : (target_x += 1) {
                const px = dx + @as(i32, @intCast(target_x));
                if (px < 0) continue;
                if (px >= @as(i32, @intCast(self.width))) break;

                const sx: u32 = @intCast(@as(u64, target_x) * @as(u64, src.width) / @as(u64, dw));
                const p = src.getPixel(sx, sy);
                if (p.a > 0) self.blendPixel(@intCast(px), @intCast(py), p);
            }
        }
    }

    /// Blit with bilinear interpolation (higher quality)
    pub fn blitBilinear(self: *Image, src: *const Image, dx: i32, dy: i32, dw: u32, dh: u32) void {
        if (dw == 0 or dh == 0) return;
        var target_y: u32 = 0;
        while (target_y < dh) : (target_y += 1) {
            const py = dy + @as(i32, @intCast(target_y));
            if (py < 0) continue;
            if (py >= @as(i32, @intCast(self.height))) break;

            const src_y: f32 = @as(f32, @floatFromInt(target_y)) * @as(f32, @floatFromInt(src.height)) / @as(f32, @floatFromInt(dh));

            var target_x: u32 = 0;
            while (target_x < dw) : (target_x += 1) {
                const px = dx + @as(i32, @intCast(target_x));
                if (px < 0) continue;
                if (px >= @as(i32, @intCast(self.width))) break;

                const src_x: f32 = @as(f32, @floatFromInt(target_x)) * @as(f32, @floatFromInt(src.width)) / @as(f32, @floatFromInt(dw));
                const p = sampleBilinear(src, src_x, src_y);
                if (p.a > 0) self.blendPixel(@intCast(px), @intCast(py), p);
            }
        }
    }

    /// Adjust brightness of all pixels
    pub fn adjustBrightness(self: *Image, factor: f32) void {
        for (self.pixels) |*px| px.* = px.brighten(factor);
    }

    /// Adjust saturation of all pixels
    pub fn adjustSaturation(self: *Image, factor: f32) void {
        for (self.pixels) |*px| px.* = px.saturate(factor);
    }

    /// Remove near-white background (make transparent)
    pub fn removeWhiteBg(self: *Image, threshold: u8) void {
        for (self.pixels) |*px| {
            if (px.r > threshold and px.g > threshold and px.b > threshold) {
                px.a = 0;
            } else if (px.r > threshold -| 30 and px.g > threshold -| 30 and px.b > threshold -| 30) {
                // Gradual fade for anti-aliased edges
                const min_ch = @min(px.r, @min(px.g, px.b));
                if (min_ch > threshold -| 30) {
                    const range: u16 = 30;
                    const above: u16 = @as(u16, min_ch) -| @as(u16, threshold -| 30);
                    const fade: u8 = @intCast(255 -| (above * 255 / range));
                    px.a = fade;
                }
            }
        }
    }
};

/// Bilinear sampling at fractional coordinates
fn sampleBilinear(img: *const Image, x: f32, y: f32) RGBA {
    const x0: u32 = @intFromFloat(@max(0, @floor(x)));
    const y0: u32 = @intFromFloat(@max(0, @floor(y)));
    const x1: u32 = @min(x0 + 1, img.width -| 1);
    const y1: u32 = @min(y0 + 1, img.height -| 1);

    const fx = x - @floor(x);
    const fy = y - @floor(y);

    const tl = img.getPixel(x0, y0);
    const tr = img.getPixel(x1, y0);
    const bl = img.getPixel(x0, y1);
    const br = img.getPixel(x1, y1);

    const top = lerpColor(tl, tr, fx);
    const bot = lerpColor(bl, br, fx);
    return lerpColor(top, bot, fy);
}
