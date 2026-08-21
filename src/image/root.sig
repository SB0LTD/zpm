// @zpm/image — Software image processing
// Layer 0: Core (pure computation, no platform dependencies)
//
// Provides:
//   - RGBA pixel type with blending, brightness, saturation
//   - Image buffer with compositing, gradients, scaling
//   - Bilinear interpolation
//   - Background removal
//   - Color utilities
//
// Usage:
//   const image = @import("image");
//   var img = try image.Image.init(allocator, 1200, 630);
//   defer img.deinit();
//   img.clear(image.RGBA.rgb(20, 20, 20));
//   img.blitBilinear(&src, 0, 0, 600, 630);
//   img.gradientH(500, 0, 700, 630, from, to);

pub const RGBA = @import("pixel.sig").RGBA;
pub const Image = @import("canvas.sig").Image;
pub const lerpColor = @import("pixel.sig").lerpColor;
pub const ops = @import("ops.sig");
