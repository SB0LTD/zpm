// OpenGL bindings — constants and extern functions
// Layer 1: Platform

// Constants
pub const COLOR_BUFFER_BIT: u32 = 0x00004000;
pub const LINES: u32 = 0x0001;
pub const LINE_LOOP: u32 = 0x0002;
pub const LINE_STRIP: u32 = 0x0003;
pub const TRIANGLE_STRIP: u32 = 0x0005;
pub const TRIANGLE_FAN: u32 = 0x0006;
pub const QUADS: u32 = 0x0007;
pub const BLEND: u32 = 0x0BE2;
pub const SRC_ALPHA: u32 = 0x0302;
pub const ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
pub const LINE_SMOOTH: u32 = 0x0B20;
pub const PROJECTION: u32 = 0x1701;
pub const MODELVIEW: u32 = 0x1700;
pub const TEXTURE_2D: u32 = 0x0DE1;
pub const ALPHA: u32 = 0x1906;
pub const RGBA: u32 = 0x1908;
pub const BGRA: u32 = 0x80E1;
pub const UNSIGNED_BYTE: u32 = 0x1401;
pub const TEXTURE_MIN_FILTER: u32 = 0x2801;
pub const TEXTURE_MAG_FILTER: u32 = 0x2800;
pub const LINEAR: i32 = 0x2601;
pub const TEXTURE_WRAP_S: u32 = 0x2802;
pub const TEXTURE_WRAP_T: u32 = 0x2803;
pub const CLAMP_TO_EDGE: i32 = 0x812F;
pub const UNPACK_ALIGNMENT: u32 = 0x0CF5;

// Extern functions
pub extern "opengl32" fn glClearColor(f32, f32, f32, f32) callconv(.c) void;
pub extern "opengl32" fn glClear(u32) callconv(.c) void;
pub extern "opengl32" fn glViewport(i32, i32, i32, i32) callconv(.c) void;
pub extern "opengl32" fn glBegin(u32) callconv(.c) void;
pub extern "opengl32" fn glEnd() callconv(.c) void;
pub extern "opengl32" fn glVertex2f(f32, f32) callconv(.c) void;
pub extern "opengl32" fn glColor4f(f32, f32, f32, f32) callconv(.c) void;
pub extern "opengl32" fn glColor3f(f32, f32, f32) callconv(.c) void;
pub extern "opengl32" fn glEnable(u32) callconv(.c) void;
pub extern "opengl32" fn glBlendFunc(u32, u32) callconv(.c) void;
pub extern "opengl32" fn glLineWidth(f32) callconv(.c) void;
pub extern "opengl32" fn glMatrixMode(u32) callconv(.c) void;
pub extern "opengl32" fn glLoadIdentity() callconv(.c) void;
pub extern "opengl32" fn glOrtho(f64, f64, f64, f64, f64, f64) callconv(.c) void;
pub extern "opengl32" fn glGenTextures(i32, *u32) callconv(.c) void;
pub extern "opengl32" fn glBindTexture(u32, u32) callconv(.c) void;
pub extern "opengl32" fn glTexImage2D(u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void;
pub extern "opengl32" fn glTexParameteri(u32, u32, i32) callconv(.c) void;
pub extern "opengl32" fn glTexCoord2f(f32, f32) callconv(.c) void;
pub extern "opengl32" fn glDeleteTextures(i32, *const u32) callconv(.c) void;
pub extern "opengl32" fn glPixelStorei(u32, i32) callconv(.c) void;
pub extern "opengl32" fn glDisable(u32) callconv(.c) void;
pub extern "opengl32" fn glScissor(i32, i32, i32, i32) callconv(.c) void;
pub extern "opengl32" fn glReadPixels(i32, i32, i32, i32, u32, u32, [*]u8) callconv(.c) void;

pub const SCISSOR_TEST: u32 = 0x0C11;
pub const RGB: u32 = 0x1907;
pub const PACK_ALIGNMENT: u32 = 0x0D05;

/// Set up 2D orthographic projection for the given viewport size.
pub fn setupOrtho2D(width: i32, height: i32) void {
    glViewport(0, 0, width, height);
    glMatrixMode(PROJECTION);
    glLoadIdentity();
    glOrtho(0, @floatFromInt(width), 0, @floatFromInt(height), -1, 1);
    glMatrixMode(MODELVIEW);
    glLoadIdentity();
}

/// Enable standard alpha blending and line smoothing.
pub fn enableBlending() void {
    glEnable(BLEND);
    glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA);
    glEnable(LINE_SMOOTH);
}
