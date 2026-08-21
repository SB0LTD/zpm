// ops.sig — High-level image operations
// Layer 0: Pure computation
//
// Resize, crop, fit modes, and format conversion utilities.

const std = @import("std");
const pixel = @import("pixel.sig");
const canvas = @import("canvas.sig");
const RGBA = pixel.RGBA;
const Image = canvas.Image;

/// How to fit a source image into target dimensions
pub const FitMode = enum {
    /// Scale to cover target, crop overflow (no letterboxing)
    cover,
    /// Scale to fit within target, letterbox with bg color
    contain,
    /// Stretch to fill target exactly (distorts aspect ratio)
    stretch,
};

/// Resize an image to target dimensions with the given fit mode.
/// Caller owns the returned Image and must call deinit().
pub fn resize(allocator: std.mem.Allocator, src: *const Image, target_w: u32, target_h: u32, fit: FitMode, bg: RGBA) !Image {
    var dst = try Image.init(allocator, target_w, target_h);
    errdefer dst.deinit();
    dst.clear(bg);

    switch (fit) {
        .stretch => {
            dst.blitBilinear(src, 0, 0, target_w, target_h);
        },
        .cover => {
            const scale_w: f32 = @as(f32, @floatFromInt(target_w)) / @as(f32, @floatFromInt(src.width));
            const scale_h: f32 = @as(f32, @floatFromInt(target_h)) / @as(f32, @floatFromInt(src.height));
            const scale = @max(scale_w, scale_h);
            const scaled_w: u32 = @intFromFloat(@as(f32, @floatFromInt(src.width)) * scale);
            const scaled_h: u32 = @intFromFloat(@as(f32, @floatFromInt(src.height)) * scale);
            const dx: i32 = @divTrunc(@as(i32, @intCast(target_w)) - @as(i32, @intCast(scaled_w)), 2);
            const dy: i32 = @divTrunc(@as(i32, @intCast(target_h)) - @as(i32, @intCast(scaled_h)), 2);
            dst.blitBilinear(src, dx, dy, scaled_w, scaled_h);
        },
        .contain => {
            const scale_w: f32 = @as(f32, @floatFromInt(target_w)) / @as(f32, @floatFromInt(src.width));
            const scale_h: f32 = @as(f32, @floatFromInt(target_h)) / @as(f32, @floatFromInt(src.height));
            const scale = @min(scale_w, scale_h);
            const scaled_w: u32 = @intFromFloat(@as(f32, @floatFromInt(src.width)) * scale);
            const scaled_h: u32 = @intFromFloat(@as(f32, @floatFromInt(src.height)) * scale);
            const dx: i32 = @divTrunc(@as(i32, @intCast(target_w)) - @as(i32, @intCast(scaled_w)), 2);
            const dy: i32 = @divTrunc(@as(i32, @intCast(target_h)) - @as(i32, @intCast(scaled_h)), 2);
            dst.blitBilinear(src, dx, dy, scaled_w, scaled_h);
        },
    }

    return dst;
}

/// Create a scaled copy of an image by a factor (e.g. 0.5 = half size)
pub fn scale(allocator: std.mem.Allocator, src: *const Image, factor: f32) !Image {
    const target_w: u32 = @intFromFloat(@as(f32, @floatFromInt(src.width)) * factor);
    const target_h: u32 = @intFromFloat(@as(f32, @floatFromInt(src.height)) * factor);
    return resize(allocator, src, target_w, target_h, .stretch, RGBA.transparent);
}

/// Crop a region from an image. Returns a new Image.
pub fn crop(allocator: std.mem.Allocator, src: *const Image, x: u32, y: u32, w: u32, h: u32) !Image {
    var dst = try Image.init(allocator, w, h);
    errdefer dst.deinit();

    var dy: u32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < w) : (dx += 1) {
            dst.setPixel(dx, dy, src.getPixel(x + dx, y + dy));
        }
    }

    return dst;
}
