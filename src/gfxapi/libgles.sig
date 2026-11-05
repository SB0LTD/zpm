//! @zpm/gfxapi libgles — the C ABI of OpenGL ES: the entry points under
//! Khronos' names (as Mesa's libGLESv2.so.2 exports them, and as
//! eglGetProcAddress hands them out), each the current context's call.
//!
//! The root of the shared library (built as Galaxy builds its agent
//! library: no C library, no DT_NEEDED). EGL (the next stage) makes
//! contexts current with makeCurrent; a call with no current context does
//! nothing, as with Mesa's no-op table.
//!
//! The current context is per thread (thread.sig: a fixed table keyed by
//! the thread pointer, no thread-local storage).

const std = @import("std");
const builtin = @import("builtin");
const gfxapi = @import("gfxapi");
const gles = gfxapi.gles;
const g = gfxapi.glenum;
const thread = gfxapi.thread;
const Context = gles.Context;

/// A failed check in the driver (on Linux): one line on stderr, then the
/// program ends, as after a failed assertion in a C driver. No stack walk
/// and no thread-local state (std's default handler has both), so the
/// library needs nothing of the C library that loaded it.
pub const panic = if (builtin.os.tag == .linux) std.debug.FullPanic(stop) else std.debug.FullPanic(std.debug.defaultPanic);

fn stop(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    _ = ra;
    const linux = std.os.linux;
    const head = "libGLESv2 (Galaxy): ";
    _ = linux.write(2, head, head.len);
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
    linux.exit_group(134);
}

// ── The current context, per thread (thread.sig) ───────────────────────────

/// `c` becomes the calling thread's current GL context (null: none); EGL's
/// eglMakeCurrent does this. False when there is no room for the thread.
pub fn makeCurrent(c: ?*Context) bool {
    const t = (if (c != null) thread.mine() else thread.get()) orelse return c == null;
    t.gl = c;
    return true;
}

pub fn getCurrent() ?*Context {
    return thread.gl();
}

inline fn cur() ?*Context {
    return thread.gl();
}

/// eglGetProcAddress's answer for a GL name: the entry point, or null.
pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque {
    const s = std.mem.span(name);
    for (entries) |e| {
        if (std.mem.eql(u8, s, e.name)) return e.ptr;
    }
    return null;
}

const Entry = struct { name: []const u8, ptr: *const anyopaque };

/// Every gl* entry point below, by name.
const entries = blk: {
    @setEvalBranchQuota(200_000);
    const decls = @typeInfo(@This()).@"struct".decl_names;
    var list: [decls.len]Entry = undefined;
    var n: usize = 0;
    for (decls) |d| {
        if (d.len > 2 and d[0] == 'g' and d[1] == 'l' and std.ascii.isUpper(d[2])) {
            list[n] = .{ .name = d, .ptr = @ptrCast(&@field(@This(), d)) };
            n += 1;
        }
    }
    const final: [n]Entry = list[0..n].*;
    break :blk final;
};

fn b(x: u8) bool {
    return x != 0;
}

fn count(n: i32) ?usize {
    if (n < 0) {
        if (cur()) |c| {
            if (c.err == g.NO_ERROR) c.err = g.INVALID_VALUE;
        }
        return null;
    }
    return @intCast(n);
}

// ── The entry points ───────────────────────────────────────────────────────

pub export fn glGetError() callconv(.c) u32 {
    const c = cur() orelse return g.NO_ERROR;
    return c.getError();
}
pub export fn glGetGraphicsResetStatus() callconv(.c) u32 {
    const c = cur() orelse return g.NO_ERROR;
    return c.getGraphicsResetStatus();
}
pub export fn glGetGraphicsResetStatusEXT() callconv(.c) u32 {
    return glGetGraphicsResetStatus();
}
pub export fn glGetGraphicsResetStatusKHR() callconv(.c) u32 {
    return glGetGraphicsResetStatus();
}
pub export fn glGetString(name: u32) callconv(.c) ?[*:0]const u8 {
    const c = cur() orelse return null;
    return c.getString(name);
}
pub export fn glGetStringi(name: u32, index: u32) callconv(.c) ?[*:0]const u8 {
    const c = cur() orelse return null;
    return c.getStringi(name, index);
}
pub export fn glEnable(cap: u32) callconv(.c) void {
    if (cur()) |c| c.enable(cap, true);
}
pub export fn glDisable(cap: u32) callconv(.c) void {
    if (cur()) |c| c.enable(cap, false);
}
pub export fn glIsEnabled(cap: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isEnabled(cap));
}
pub export fn glHint(target: u32, mode: u32) callconv(.c) void {
    if (cur()) |c| c.hint(target, mode);
}
pub export fn glPixelStorei(pname: u32, param: i32) callconv(.c) void {
    if (cur()) |c| c.pixelStore(pname, param);
}
pub export fn glFlush() callconv(.c) void {
    if (cur()) |c| c.flush();
}
pub export fn glFinish() callconv(.c) void {
    if (cur()) |c| c.finish();
}
pub export fn glGetIntegerv(pname: u32, data: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const p = data orelse return;
    c.getIntegers(pname, p[0..4]);
}
pub export fn glGetInteger64v(pname: u32, data: ?[*]i64) callconv(.c) void {
    const c = cur() orelse return;
    const p = data orelse return;
    var v: [4]i32 = undefined;
    const x = c.get(pname) orelse {
        if (c.err == g.NO_ERROR) c.err = g.INVALID_ENUM;
        return;
    };
    if (x.kind == .int) {
        @memcpy(p[0..x.n], x.i[0..x.n]);
        return;
    }
    c.getIntegers(pname, &v);
    for (0..x.n) |i| p[i] = v[i];
}
pub export fn glGetFloatv(pname: u32, data: ?[*]f32) callconv(.c) void {
    const c = cur() orelse return;
    const p = data orelse return;
    c.getFloats(pname, p[0..4]);
}
pub export fn glGetBooleanv(pname: u32, data: ?[*]u8) callconv(.c) void {
    const c = cur() orelse return;
    const p = data orelse return;
    c.getBooleans(pname, p[0..4]);
}

pub export fn glClearColor(r: f32, gr: f32, bl: f32, a: f32) callconv(.c) void {
    if (cur()) |c| c.clearColor(r, gr, bl, a);
}
pub export fn glClearDepthf(d: f32) callconv(.c) void {
    if (cur()) |c| c.clearDepth(d);
}
pub export fn glClearStencil(s: i32) callconv(.c) void {
    if (cur()) |c| c.clearStencil(s);
}
pub export fn glColorMask(r: u8, gr: u8, bl: u8, a: u8) callconv(.c) void {
    if (cur()) |c| c.colorMask(b(r), b(gr), b(bl), b(a));
}
pub export fn glDepthMask(flag: u8) callconv(.c) void {
    if (cur()) |c| c.depthMask(b(flag));
}
pub export fn glStencilMask(mask: u32) callconv(.c) void {
    if (cur()) |c| c.stencilMaskSeparate(0x0408, mask);
}
pub export fn glStencilMaskSeparate(face: u32, mask: u32) callconv(.c) void {
    if (cur()) |c| c.stencilMaskSeparate(face, mask);
}
pub export fn glViewport(x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.viewportSet(x, y, w, h);
}
pub export fn glScissor(x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.scissorSet(x, y, w, h);
}
pub export fn glClear(mask: u32) callconv(.c) void {
    if (cur()) |c| c.clear(mask);
}
pub export fn glClearBufferfv(buffer: u32, drawbuffer: i32, value: ?[*]const f32) callconv(.c) void {
    const c = cur() orelse return;
    const v = value orelse return;
    c.clearBufferf(buffer, drawbuffer, v[0 .. if (buffer == g.COLOR) 4 else 1]);
}
pub export fn glClearBufferiv(buffer: u32, drawbuffer: i32, value: ?[*]const i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = value orelse return;
    c.clearBufferi(buffer, drawbuffer, v[0 .. if (buffer == g.COLOR) 4 else 1]);
}
pub export fn glClearBufferuiv(buffer: u32, drawbuffer: i32, value: ?[*]const u32) callconv(.c) void {
    _ = value;
    if (cur()) |c| c.clearBufferu(buffer, drawbuffer);
}
pub export fn glClearBufferfi(buffer: u32, drawbuffer: i32, depth: f32, stencil: i32) callconv(.c) void {
    if (cur()) |c| c.clearBufferfi(buffer, drawbuffer, depth, stencil);
}
pub export fn glReadPixels(x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, pixels: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.readPixels(x, y, w, h, format, ty, pixels);
}

pub export fn glGenTextures(n: i32, out: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (out) |p| c.genTextures(p[0..k]);
}
pub export fn glDeleteTextures(n: i32, names: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (names) |p| c.deleteTextures(p[0..k]);
}
pub export fn glIsTexture(name: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isTexture(name));
}
pub export fn glActiveTexture(unit: u32) callconv(.c) void {
    if (cur()) |c| c.activeTexture(unit);
}
pub export fn glBindTexture(target: u32, name: u32) callconv(.c) void {
    if (cur()) |c| c.bindTexture(target, name);
}
pub export fn glTexImage2D(target: u32, level: i32, internal: i32, w: i32, h: i32, border: i32, format: u32, ty: u32, pixels: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.texImage2D(target, level, internal, w, h, border, format, ty, pixels);
}
pub export fn glTexSubImage2D(target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, pixels: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.texSubImage2D(target, level, x, y, w, h, format, ty, pixels);
}
pub export fn glTexStorage2D(target: u32, levels: i32, internal: u32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.texStorage2D(target, levels, internal, w, h);
}
pub export fn glTexStorage2DEXT(target: u32, levels: i32, internal: u32, w: i32, h: i32) callconv(.c) void {
    glTexStorage2D(target, levels, internal, w, h);
}
pub export fn glTexParameteri(target: u32, pname: u32, param: i32) callconv(.c) void {
    if (cur()) |c| c.texParameteri(target, pname, param);
}
pub export fn glTexParameterf(target: u32, pname: u32, param: f32) callconv(.c) void {
    glTexParameteri(target, pname, @intFromFloat(std.math.clamp(@round(param), -2147483648.0, 2147483647.0)));
}
pub export fn glTexParameteriv(target: u32, pname: u32, params: ?[*]const i32) callconv(.c) void {
    if (params) |p| glTexParameteri(target, pname, p[0]);
}
pub export fn glTexParameterfv(target: u32, pname: u32, params: ?[*]const f32) callconv(.c) void {
    if (params) |p| glTexParameterf(target, pname, p[0]);
}
pub export fn glGetTexParameteriv(target: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getTexParameteri(target, pname) orelse return;
    if (params) |p| p[0] = v;
}
pub export fn glGetTexParameterfv(target: u32, pname: u32, params: ?[*]f32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getTexParameteri(target, pname) orelse return;
    if (params) |p| p[0] = @floatFromInt(v);
}
pub export fn glEGLImageTargetTexture2DOES(target: u32, image: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.eglImageTargetTexture2D(target, image);
}
pub export fn glEGLImageTargetRenderbufferStorageOES(target: u32, image: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.eglImageTargetRenderbufferStorage(target, image);
}
pub export fn glCopyTexSubImage2D(target: u32, level: i32, dx: i32, dy: i32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.copyTexSubImage2D(target, level, dx, dy, x, y, w, h);
}
pub export fn glCopyTexImage2D(target: u32, level: i32, internal: u32, x: i32, y: i32, w: i32, h: i32, border: i32) callconv(.c) void {
    if (cur()) |c| c.copyTexImage2D(target, level, internal, x, y, w, h, border);
}

pub export fn glGenBuffers(n: i32, out: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (out) |p| c.genBuffers(p[0..k]);
}
pub export fn glDeleteBuffers(n: i32, names: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (names) |p| c.deleteBuffers(p[0..k]);
}
pub export fn glIsBuffer(name: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isBuffer(name));
}
pub export fn glBindBuffer(target: u32, name: u32) callconv(.c) void {
    if (cur()) |c| c.bindBuffer(target, name);
}
pub export fn glBufferData(target: u32, size: isize, data: ?*const anyopaque, usage: u32) callconv(.c) void {
    if (cur()) |c| c.bufferData(target, size, data, usage);
}
pub export fn glBufferSubData(target: u32, offset: isize, size: isize, data: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.bufferSubData(target, offset, size, data);
}
pub export fn glGetBufferParameteriv(target: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getBufferParameter(target, pname) orelse return;
    if (params) |p| p[0] = @truncate(v);
}
pub export fn glGetBufferParameteri64v(target: u32, pname: u32, params: ?[*]i64) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getBufferParameter(target, pname) orelse return;
    if (params) |p| p[0] = v;
}

pub export fn glGenRenderbuffers(n: i32, out: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (out) |p| c.genRenderbuffers(p[0..k]);
}
pub export fn glDeleteRenderbuffers(n: i32, names: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (names) |p| c.deleteRenderbuffers(p[0..k]);
}
pub export fn glIsRenderbuffer(name: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isRenderbuffer(name));
}
pub export fn glBindRenderbuffer(target: u32, name: u32) callconv(.c) void {
    if (cur()) |c| c.bindRenderbuffer(target, name);
}
pub export fn glRenderbufferStorage(target: u32, internal: u32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.renderbufferStorage(target, 0, internal, w, h);
}
pub export fn glRenderbufferStorageMultisample(target: u32, samples: i32, internal: u32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.renderbufferStorage(target, samples, internal, w, h);
}
pub export fn glGetRenderbufferParameteriv(target: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getRenderbufferParameter(target, pname) orelse return;
    if (params) |p| p[0] = v;
}

pub export fn glGenFramebuffers(n: i32, out: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (out) |p| c.genFramebuffers(p[0..k]);
}
pub export fn glDeleteFramebuffers(n: i32, names: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (names) |p| c.deleteFramebuffers(p[0..k]);
}
pub export fn glIsFramebuffer(name: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isFramebuffer(name));
}
pub export fn glBindFramebuffer(target: u32, name: u32) callconv(.c) void {
    if (cur()) |c| c.bindFramebuffer(target, name);
}
pub export fn glFramebufferTexture2D(target: u32, attachment: u32, textarget: u32, name: u32, level: i32) callconv(.c) void {
    if (cur()) |c| c.framebufferTexture2D(target, attachment, textarget, name, level);
}
pub export fn glFramebufferRenderbuffer(target: u32, attachment: u32, rbtarget: u32, name: u32) callconv(.c) void {
    if (cur()) |c| c.framebufferRenderbuffer(target, attachment, rbtarget, name);
}
pub export fn glCheckFramebufferStatus(target: u32) callconv(.c) u32 {
    const c = cur() orelse return 0;
    return c.checkFramebufferStatus(target);
}
pub export fn glDrawBuffers(n: i32, bufs: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (bufs) |p| c.drawBuffers(p[0..k]) else if (k == 0) c.drawBuffers(&.{});
}
pub export fn glReadBuffer(src: u32) callconv(.c) void {
    if (cur()) |c| c.readBuffer(src);
}
pub export fn glInvalidateFramebuffer(target: u32, n: i32, attachments: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (attachments) |p| c.invalidateFramebuffer(target, p[0..k]);
}
pub export fn glInvalidateSubFramebuffer(target: u32, n: i32, attachments: ?[*]const u32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    _ = x;
    _ = y;
    const c = cur() orelse return;
    if (w < 0 or h < 0) {
        if (c.err == g.NO_ERROR) c.err = g.INVALID_VALUE;
        return;
    }
    const k = count(n) orelse return;
    if (attachments) |p| c.invalidateFramebuffer(target, p[0..k]);
}
pub export fn glGetFramebufferAttachmentParameteriv(target: u32, attachment: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getFramebufferAttachmentParameter(target, attachment, pname) orelse return;
    if (params) |p| p[0] = v;
}

// ── Tests ──────────────────────────────────────────────────────────────────

var t_pool: [1 << 20]u8 align(64) = undefined;
var t_eng: gfxapi.engine.Engine = undefined;
var t_objs: gles.Objects = undefined;
var t_ctx: Context = undefined;

test "libgles: GL through its C entry points, on the CPU" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    var win = t_eng.newImage(8, 8, .bgra8).?;
    win.top_down = true;
    defer t_eng.freeImage(&win);
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    try std.testing.expectEqual(@as(?*Context, &t_ctx), getCurrent());
    // (no surface yet: the default framebuffer is undefined)
    try std.testing.expectEqual(g.FRAMEBUFFER_UNDEFINED, glCheckFramebufferStatus(g.FRAMEBUFFER));
    glClear(g.COLOR_BUFFER_BIT);
    try std.testing.expectEqual(g.INVALID_FRAMEBUFFER_OPERATION, glGetError());
    t_ctx.setSurface(&win, &win, null);
    var vp: [4]i32 = undefined;
    glGetIntegerv(g.VIEWPORT, &vp);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 8, 8 }, &vp);
    glClearColor(1, 0, 0, 1);
    glClear(g.COLOR_BUFFER_BIT);
    var px: [4]u8 = undefined;
    glReadPixels(3, 3, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &px);
    glReadPixels(3, 3, 1, 1, g.BGRA_EXT, g.UNSIGNED_BYTE, &px);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &px);
    glReadPixels(0, 0, 1, 1, g.RGB, g.UNSIGNED_BYTE, &px);
    try std.testing.expectEqual(g.INVALID_OPERATION, glGetError());
    glReadPixels(0, 0, 1, 1, 0x1234, g.UNSIGNED_BYTE, &px);
    try std.testing.expectEqual(g.INVALID_ENUM, glGetError());
    // Mesa keeps the first error until it is read
    glEnable(0x1234);
    glClear(0x8000_0000);
    try std.testing.expectEqual(g.INVALID_ENUM, glGetError());
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    try std.testing.expectEqualStrings("OpenGL ES 3.0 Galaxy 0.1", std.mem.span(glGetString(g.VERSION).?));
    var n: i32 = 0;
    glGetIntegerv(g.NUM_EXTENSIONS, @ptrCast(&n));
    try std.testing.expectEqual(@as(i32, gles.EXTENSIONS.len), n);
    try std.testing.expectEqualStrings("GL_EXT_read_format_bgra", std.mem.span(glGetStringi(g.EXTENSIONS, 0).?));
}

test "libgles: getProcAddress finds every entry point, and nothing else" {
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glClear)), getProcAddress("glClear"));
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glTexStorage2DEXT)), getProcAddress("glTexStorage2DEXT"));
    try std.testing.expect(getProcAddress("glDrawArrays") == null);
    try std.testing.expect(getProcAddress("getProcAddress") == null);
    try std.testing.expect(entries.len > 70);
}
