// Screenshot — capture OpenGL framebuffer to in-memory PNG
// Layer 1: Platform
//
// Thin wrapper around png/ encoder module. Reads the current framebuffer
// via glReadPixels, encodes PNG into a static buffer.

const png = @import("png");

/// Capture the current GL framebuffer into the static PNG buffer.
/// Must be called after rendering, before swap.
pub fn capture(width: i32, height: i32) void {
    png.capture(width, height);
}
