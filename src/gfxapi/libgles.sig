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
const program = gfxapi.program;
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
    const x = c.get(pname) orelse return c.invalidEnum("glGetInteger64v", pname);
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
pub export fn glStencilFunc(func: u32, reference: i32, mask: u32) callconv(.c) void {
    if (cur()) |c| c.stencilFuncSeparate(g.FRONT_AND_BACK, func, reference, mask);
}
pub export fn glStencilFuncSeparate(face: u32, func: u32, reference: i32, mask: u32) callconv(.c) void {
    if (cur()) |c| c.stencilFuncSeparate(face, func, reference, mask);
}
pub export fn glStencilOp(fail: u32, depth_fail: u32, pass: u32) callconv(.c) void {
    if (cur()) |c| c.stencilOpSeparate(g.FRONT_AND_BACK, fail, depth_fail, pass);
}
pub export fn glStencilOpSeparate(face: u32, fail: u32, depth_fail: u32, pass: u32) callconv(.c) void {
    if (cur()) |c| c.stencilOpSeparate(face, fail, depth_fail, pass);
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
    c.clearBufferf(buffer, drawbuffer, v[0..if (buffer == g.COLOR) 4 else 1]);
}
pub export fn glClearBufferiv(buffer: u32, drawbuffer: i32, value: ?[*]const i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = value orelse return;
    c.clearBufferi(buffer, drawbuffer, v[0..if (buffer == g.COLOR) 4 else 1]);
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
pub export fn glReadnPixels(x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, buf_size: i32, pixels: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.readnPixels(x, y, w, h, format, ty, buf_size, pixels);
}
pub export fn glReadnPixelsEXT(x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, buf_size: i32, pixels: ?*anyopaque) callconv(.c) void {
    glReadnPixels(x, y, w, h, format, ty, buf_size, pixels);
}
pub export fn glReadnPixelsKHR(x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, buf_size: i32, pixels: ?*anyopaque) callconv(.c) void {
    glReadnPixels(x, y, w, h, format, ty, buf_size, pixels);
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
pub export fn glTexStorage3D(target: u32, levels: i32, internal: u32, w: i32, h: i32, depth: i32) callconv(.c) void {
    if (cur()) |c| c.texStorage3D(target, levels, internal, w, h, depth);
}
pub export fn glTexStorage3DEXT(target: u32, levels: i32, internal: u32, w: i32, h: i32, depth: i32) callconv(.c) void {
    glTexStorage3D(target, levels, internal, w, h, depth);
}
pub export fn glTexSubImage3D(target: u32, level: i32, x: i32, y: i32, z: i32, w: i32, h: i32, depth: i32, format: u32, ty: u32, pixels: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.texSubImage3D(target, level, x, y, z, w, h, depth, format, ty, pixels);
}
pub export fn glTexImage3D(target: u32, level: i32, internal: i32, w: i32, h: i32, depth: i32, border: i32, format: u32, ty: u32, pixels: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.texImage3D(target, level, internal, w, h, depth, border, format, ty, pixels);
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
pub export fn glGenerateMipmap(target: u32) callconv(.c) void {
    if (cur()) |c| c.generateMipmap(target);
}
pub export fn glGenSamplers(n: i32, out: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (out) |p| c.genSamplers(p[0..k]);
}
pub export fn glDeleteSamplers(n: i32, names: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (names) |p| c.deleteSamplers(p[0..k]);
}
pub export fn glIsSampler(name: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isSampler(name));
}
pub export fn glBindSampler(unit: u32, name: u32) callconv(.c) void {
    if (cur()) |c| c.bindSampler(unit, name);
}
pub export fn glSamplerParameteri(name: u32, pname: u32, param: i32) callconv(.c) void {
    if (cur()) |c| c.samplerParameteri(name, pname, param);
}
pub export fn glSamplerParameterf(name: u32, pname: u32, param: f32) callconv(.c) void {
    glSamplerParameteri(name, pname, @intFromFloat(std.math.clamp(@round(param), -2147483648.0, 2147483520.0)));
}
pub export fn glSamplerParameteriv(name: u32, pname: u32, params: ?[*]const i32) callconv(.c) void {
    if (params) |p| glSamplerParameteri(name, pname, p[0]);
}
pub export fn glSamplerParameterfv(name: u32, pname: u32, params: ?[*]const f32) callconv(.c) void {
    if (params) |p| glSamplerParameterf(name, pname, p[0]);
}
pub export fn glGetSamplerParameteriv(name: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getSamplerParameteri(name, pname) orelse return;
    if (params) |p| p[0] = v;
}
pub export fn glGetSamplerParameterfv(name: u32, pname: u32, params: ?[*]f32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getSamplerParameteri(name, pname) orelse return;
    if (params) |p| p[0] = @floatFromInt(v);
}
pub export fn glEGLImageTargetTexture2DOES(target: u32, image: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.eglImageTargetTexture2D(target, image);
}
pub export fn glEGLImageTargetRenderbufferStorageOES(target: u32, image: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.eglImageTargetRenderbufferStorage(target, image);
}
pub export fn glCopyImageSubDataEXT(sn: u32, st: u32, sl: i32, sx: i32, sy: i32, sz: i32, dn: u32, dt: u32, dl: i32, dx: i32, dy: i32, dz: i32, w: i32, h: i32, depth: i32) callconv(.c) void {
    if (cur()) |c| c.copyImageSubData(sn, st, sl, sx, sy, sz, dn, dt, dl, dx, dy, dz, w, h, depth);
}

pub export fn glCopyTexSubImage2D(target: u32, level: i32, dx: i32, dy: i32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.copyTexSubImage2D(target, level, dx, dy, x, y, w, h);
}
pub export fn glCopyTexSubImage3D(target: u32, level: i32, dx: i32, dy: i32, dz: i32, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    if (cur()) |c| c.copyTexSubImage3D(target, level, dx, dy, dz, x, y, w, h);
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
pub export fn glCopyBufferSubData(read_target: u32, write_target: u32, read_offset: isize, write_offset: isize, size: isize) callconv(.c) void {
    if (cur()) |c| c.copyBufferSubData(read_target, write_target, read_offset, write_offset, size);
}
pub export fn glGenQueriesEXT(n: i32, ids: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (ids) |p| c.genTimerQueries(p[0..k]);
}
pub export fn glDeleteQueriesEXT(n: i32, ids: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (ids) |p| c.deleteTimerQueries(p[0..k]);
}
pub export fn glIsQueryEXT(id: u32) callconv(.c) u8 {
    const c = cur() orelse return 0;
    return @intFromBool(c.isTimerQuery(id));
}
pub export fn glBeginQueryEXT(target: u32, id: u32) callconv(.c) void {
    if (cur()) |c| c.beginTimer(target, id);
}
pub export fn glEndQueryEXT(target: u32) callconv(.c) void {
    if (cur()) |c| c.endTimer(target);
}
pub export fn glQueryCounterEXT(id: u32, target: u32) callconv(.c) void {
    if (cur()) |c| c.timerCounter(id, target);
}
pub export fn glGetQueryivEXT(target: u32, pname: u32, out: ?*i32) callconv(.c) void {
    const c = cur() orelse return;
    if (c.timerState(target, pname)) |v| {
        if (out) |p| p.* = v;
    }
}
fn getTimerResult(comptime T: type, id: u32, pname: u32, out: ?*T) void {
    const c = cur() orelse return;
    if (c.timerResult(id, pname)) |v| {
        if (out) |p| p.* = @intCast(@min(v, std.math.maxInt(T)));
    }
}
pub export fn glGetQueryObjectivEXT(id: u32, pname: u32, out: ?*i32) callconv(.c) void {
    getTimerResult(i32, id, pname, out);
}
pub export fn glGetQueryObjectuivEXT(id: u32, pname: u32, out: ?*u32) callconv(.c) void {
    getTimerResult(u32, id, pname, out);
}
pub export fn glGetQueryObjecti64vEXT(id: u32, pname: u32, out: ?*i64) callconv(.c) void {
    getTimerResult(i64, id, pname, out);
}
pub export fn glGetQueryObjectui64vEXT(id: u32, pname: u32, out: ?*u64) callconv(.c) void {
    getTimerResult(u64, id, pname, out);
}

pub export fn glDebugMessageCallbackKHR(callback: ?gles.debug_output.Callback, user: ?*const anyopaque) callconv(.c) void {
    const c = cur() orelse return;
    c.debug.callback = callback;
    c.debug.user = user;
}

pub export fn glDebugMessageControlKHR(src: u32, kind: u32, sev: u32, n: i32, ids: ?[*]const u32, enabled: u8) callconv(.c) void {
    const c = cur() orelse return;
    const dbg = gles.debug_output;
    if ((src != dbg.ANY and !dbg.source(src)) or (kind != dbg.ANY and !dbg.msgType(kind)) or
        (sev != dbg.ANY and !dbg.severity(sev))) return c.fail(g.INVALID_ENUM);
    if (n < 0 or (n > 0 and ids == null)) return c.fail(g.INVALID_VALUE);
    if (n > 0 and (src == dbg.ANY or kind == dbg.ANY or sev != dbg.ANY))
        return c.fail(g.INVALID_OPERATION);
    const list: []const u32 = if (n == 0) &.{} else ids.?[0..@intCast(n)];
    if (!c.debug.control(src, kind, sev, list, enabled != 0)) c.fail(g.OUT_OF_MEMORY);
}

pub export fn glDebugMessageInsertKHR(src: u32, kind: u32, id: u32, sev: u32, length: i32, text: ?[*]const u8) callconv(.c) void {
    const c = cur() orelse return;
    const dbg = gles.debug_output;
    if (src != dbg.APPLICATION and src != dbg.THIRD_PARTY) return c.fail(g.INVALID_ENUM);
    if (!dbg.msgType(kind) or kind == 0x8269 or kind == 0x826A or !dbg.severity(sev)) return c.fail(g.INVALID_ENUM);
    const p = text orelse return c.fail(g.INVALID_VALUE);
    var n: usize = if (length < 0) 0 else @intCast(length);
    if (length < 0) {
        while (n < dbg.MAX_TEXT and p[n] != 0) n += 1;
    }
    if (n >= dbg.MAX_TEXT) return c.fail(g.INVALID_VALUE);
    c.debug.emit(src, kind, id, sev, p[0..n]);
}

pub export fn glGetDebugMessageLogKHR(n: u32, size: i32, sources: ?[*]u32, types: ?[*]u32, ids: ?[*]u32, severities: ?[*]u32, lengths: ?[*]i32, text: ?[*]u8) callconv(.c) u32 {
    const c = cur() orelse return 0;
    if (size < 0 and text != null) {
        c.fail(g.INVALID_VALUE);
        return 0;
    }
    return c.debug.read(n, @intCast(@max(size, 0)), sources, types, ids, severities, lengths, text);
}

pub export fn glPushDebugGroupKHR(src: u32, id: u32, length: i32, text: ?[*]const u8) callconv(.c) void {
    const c = cur() orelse return;
    const dbg = gles.debug_output;
    if (src != dbg.APPLICATION and src != dbg.THIRD_PARTY) return c.fail(g.INVALID_ENUM);
    const p = text orelse return c.fail(g.INVALID_VALUE);
    var n: usize = if (length < 0) 0 else @intCast(length);
    if (length < 0) {
        while (n < dbg.MAX_TEXT and p[n] != 0) n += 1;
    }
    if (n >= dbg.MAX_TEXT) return c.fail(g.INVALID_VALUE);
    if (!c.debug.push(src, id, p[0..n])) c.fail(0x0503); // STACK_OVERFLOW
}

pub export fn glPopDebugGroupKHR() callconv(.c) void {
    const c = cur() orelse return;
    if (!c.debug.pop()) c.fail(0x0504); // STACK_UNDERFLOW
}

fn setObjectLabel(c: *Context, label: *gles.debug_output.Label, length: i32, text: ?[*]const u8) void {
    const p = text orelse {
        label.set(&.{});
        return;
    };
    const max = gles.debug_output.MAX_LABEL_LENGTH;
    var n: usize = if (length < 0) 0 else @intCast(length);
    if (length < 0) {
        while (n < max and p[n] != 0) n += 1;
    }
    if (n >= max) return c.fail(g.INVALID_VALUE);
    label.set(p[0..n]);
}

pub export fn glObjectLabelKHR(identifier: u32, name: u32, length: i32, text: ?[*]const u8) callconv(.c) void {
    const c = cur() orelse return;
    const label = c.objectLabel(identifier, name) orelse return;
    setObjectLabel(c, label, length, text);
}

pub export fn glGetObjectLabelKHR(identifier: u32, name: u32, size: i32, length: ?*i32, text: ?[*]u8) callconv(.c) void {
    const c = cur() orelse return;
    if (size < 0) return c.fail(g.INVALID_VALUE);
    const label = c.objectLabel(identifier, name) orelse return;
    label.get(size, length, text);
}

pub export fn glObjectPtrLabelKHR(ptr: ?*const anyopaque, length: i32, text: ?[*]const u8) callconv(.c) void {
    const c = cur() orelse return;
    const label = c.pointerLabel(ptr) orelse return;
    setObjectLabel(c, label, length, text);
}

pub export fn glGetObjectPtrLabelKHR(ptr: ?*const anyopaque, size: i32, length: ?*i32, text: ?[*]u8) callconv(.c) void {
    const c = cur() orelse return;
    if (size < 0) return c.fail(g.INVALID_VALUE);
    const label = c.pointerLabel(ptr) orelse return;
    label.get(size, length, text);
}

pub export fn glGetPointervKHR(pname: u32, out: ?*?*const anyopaque) callconv(.c) void {
    const c = cur() orelse return;
    const p = out orelse return;
    p.* = switch (pname) {
        0x8244 => if (c.debug.callback) |cb| @ptrCast(cb) else null,
        0x8245 => c.debug.user,
        else => return c.fail(g.INVALID_ENUM),
    };
}

pub export fn glInsertEventMarkerEXT(length: i32, marker: ?[*]const u8) callconv(.c) void {
    if (cur()) |c| c.debugMarker(.event, length, marker);
}

pub export fn glPushGroupMarkerEXT(length: i32, marker: ?[*]const u8) callconv(.c) void {
    if (cur()) |c| c.debugMarker(.push, length, marker);
}

pub export fn glPopGroupMarkerEXT() callconv(.c) void {
    if (cur()) |c| c.debugMarker(.pop, 0, null);
}

pub export fn glMemoryBarrier(barriers: u32) callconv(.c) void {
    if (cur()) |c| c.clientMappedBarrier(barriers);
}

pub export fn glBufferStorageEXT(target: u32, size: isize, data: ?*const anyopaque, flags: u32) callconv(.c) void {
    if (cur()) |c| c.bufferStorage(target, size, data, flags);
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
pub export fn glMapBufferRange(target: u32, offset: isize, length: isize, access: u32) callconv(.c) ?*anyopaque {
    const c = cur() orelse return null;
    return c.mapBufferRange(target, offset, length, access);
}
pub export fn glUnmapBuffer(target: u32) callconv(.c) u8 {
    const c = cur() orelse return 0;
    return @intFromBool(c.unmapBuffer(target));
}
pub export fn glFlushMappedBufferRange(target: u32, offset: isize, length: isize) callconv(.c) void {
    if (cur()) |c| c.flushMappedBufferRange(target, offset, length);
}
pub export fn glGetBufferPointerv(target: u32, pname: u32, params: ?*?*anyopaque) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getBufferPointer(target, pname);
    if (params) |p| p.* = v;
}

pub export fn glBlitFramebuffer(src_x0: i32, src_y0: i32, src_x1: i32, src_y1: i32, dst_x0: i32, dst_y0: i32, dst_x1: i32, dst_y1: i32, mask: u32, filter: u32) callconv(.c) void {
    if (cur()) |c| c.blitFramebuffer(src_x0, src_y0, src_x1, src_y1, dst_x0, dst_y0, dst_x1, dst_y1, mask, filter);
}

pub export fn glFenceSync(condition: u32, flags: u32) callconv(.c) ?*anyopaque {
    const c = cur() orelse return null;
    return c.fenceSync(condition, flags);
}
pub export fn glClientWaitSync(sync: ?*anyopaque, flags: u32, timeout: u64) callconv(.c) u32 {
    const c = cur() orelse return g.WAIT_FAILED;
    return c.clientWaitSync(sync, flags, timeout);
}
pub export fn glWaitSync(sync: ?*anyopaque, flags: u32, timeout: u64) callconv(.c) void {
    if (cur()) |c| c.waitSync(sync, flags, timeout);
}
pub export fn glDeleteSync(sync: ?*anyopaque) callconv(.c) void {
    if (cur()) |c| c.deleteSync(sync);
}
pub export fn glIsSync(sync: ?*anyopaque) callconv(.c) u8 {
    const c = cur() orelse return 0;
    return @intFromBool(c.isSync(sync));
}
pub export fn glGetSynciv(sync: ?*anyopaque, pname: u32, buf_size: i32, length: ?*i32, values: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const v = c.getSync(sync, pname) orelse return;
    if (buf_size < 1) return;
    if (values) |p| p[0] = v;
    if (length) |l| l.* = 1;
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
pub export fn glFramebufferTextureLayer(target: u32, attachment: u32, name: u32, level: i32, layer: i32) callconv(.c) void {
    if (cur()) |c| c.framebufferTextureLayer(target, attachment, name, level, layer);
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

pub export fn glGenVertexArrays(n: i32, out: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (out) |p| c.genVertexArrays(p[0..k]);
}
pub export fn glDeleteVertexArrays(n: i32, names: ?[*]const u32) callconv(.c) void {
    const c = cur() orelse return;
    const k = count(n) orelse return;
    if (names) |p| c.deleteVertexArrays(p[0..k]);
}
pub export fn glBindVertexArray(name: u32) callconv(.c) void {
    if (cur()) |c| c.bindVertexArray(name);
}
pub export fn glIsVertexArray(name: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(c.isVertexArray(name));
}
pub export fn glVertexAttribPointer(index: u32, size: i32, ty: u32, normalized: u8, stride: i32, pointer: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.vertexAttribPointer(index, size, ty, b(normalized), stride, @intFromPtr(pointer), false);
}
pub export fn glVertexAttribIPointer(index: u32, size: i32, ty: u32, stride: i32, pointer: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.vertexAttribPointer(index, size, ty, false, stride, @intFromPtr(pointer), true);
}
pub export fn glEnableVertexAttribArray(index: u32) callconv(.c) void {
    if (cur()) |c| c.enableVertexAttribArray(index, true);
}
pub export fn glDisableVertexAttribArray(index: u32) callconv(.c) void {
    if (cur()) |c| c.enableVertexAttribArray(index, false);
}
pub export fn glVertexAttribDivisor(index: u32, divisor: u32) callconv(.c) void {
    if (cur()) |c| c.vertexAttribDivisor(index, divisor);
}
fn fattr(index: u32, x: f32, y: f32, z: f32, w: f32) void {
    if (cur()) |c| c.vertexAttrib(index, .{ @bitCast(x), @bitCast(y), @bitCast(z), @bitCast(w) }, false);
}
pub export fn glVertexAttrib1f(index: u32, x: f32) callconv(.c) void {
    fattr(index, x, 0, 0, 1);
}
pub export fn glVertexAttrib2f(index: u32, x: f32, y: f32) callconv(.c) void {
    fattr(index, x, y, 0, 1);
}
pub export fn glVertexAttrib3f(index: u32, x: f32, y: f32, z: f32) callconv(.c) void {
    fattr(index, x, y, z, 1);
}
pub export fn glVertexAttrib4f(index: u32, x: f32, y: f32, z: f32, w: f32) callconv(.c) void {
    fattr(index, x, y, z, w);
}
pub export fn glVertexAttrib1fv(index: u32, v: ?[*]const f32) callconv(.c) void {
    if (v) |p| fattr(index, p[0], 0, 0, 1);
}
pub export fn glVertexAttrib2fv(index: u32, v: ?[*]const f32) callconv(.c) void {
    if (v) |p| fattr(index, p[0], p[1], 0, 1);
}
pub export fn glVertexAttrib3fv(index: u32, v: ?[*]const f32) callconv(.c) void {
    if (v) |p| fattr(index, p[0], p[1], p[2], 1);
}
pub export fn glVertexAttrib4fv(index: u32, v: ?[*]const f32) callconv(.c) void {
    if (v) |p| fattr(index, p[0], p[1], p[2], p[3]);
}
pub export fn glVertexAttribI4i(index: u32, x: i32, y: i32, z: i32, w: i32) callconv(.c) void {
    if (cur()) |c| c.vertexAttrib(index, .{ @bitCast(x), @bitCast(y), @bitCast(z), @bitCast(w) }, true);
}
pub export fn glVertexAttribI4ui(index: u32, x: u32, y: u32, z: u32, w: u32) callconv(.c) void {
    if (cur()) |c| c.vertexAttribUnsigned(index, .{ x, y, z, w });
}
pub export fn glVertexAttribI4iv(index: u32, v: ?[*]const i32) callconv(.c) void {
    if (v) |p| glVertexAttribI4i(index, p[0], p[1], p[2], p[3]);
}
pub export fn glVertexAttribI4uiv(index: u32, v: ?[*]const u32) callconv(.c) void {
    if (v) |p| glVertexAttribI4ui(index, p[0], p[1], p[2], p[3]);
}
pub export fn glGetVertexAttribiv(index: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    if (params) |p| c.vertexAttribValues(i32, index, pname, p);
}
pub export fn glGetVertexAttribfv(index: u32, pname: u32, params: ?[*]f32) callconv(.c) void {
    const c = cur() orelse return;
    if (params) |p| c.vertexAttribValues(f32, index, pname, p);
}
pub export fn glGetVertexAttribIiv(index: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    if (params) |p| c.vertexAttribValues(i32, index, pname, p);
}
pub export fn glGetVertexAttribIuiv(index: u32, pname: u32, params: ?[*]u32) callconv(.c) void {
    const c = cur() orelse return;
    if (params) |p| c.vertexAttribValues(u32, index, pname, p);
}
pub export fn glGetVertexAttribPointerv(index: u32, pname: u32, params: ?*?*anyopaque) callconv(.c) void {
    const c = cur() orelse return;
    const pointer = c.vertexAttribPointerValue(index, pname) orelse return;
    if (params) |p| p.* = @ptrFromInt(pointer);
}
pub export fn glDrawArrays(mode: u32, first: i32, n: i32) callconv(.c) void {
    if (cur()) |c| c.drawArrays(mode, first, n, 1);
}
pub export fn glDrawArraysInstanced(mode: u32, first: i32, n: i32, instances: i32) callconv(.c) void {
    if (cur()) |c| c.drawArrays(mode, first, n, instances);
}
pub export fn glDrawElements(mode: u32, n: i32, ty: u32, indices: ?*const anyopaque) callconv(.c) void {
    if (cur()) |c| c.drawElements(mode, n, ty, @intFromPtr(indices), 1);
}
pub export fn glDrawElementsInstanced(mode: u32, n: i32, ty: u32, indices: ?*const anyopaque, instances: i32) callconv(.c) void {
    if (cur()) |c| c.drawElements(mode, n, ty, @intFromPtr(indices), instances);
}
pub export fn glDrawRangeElements(mode: u32, start: u32, end: u32, n: i32, ty: u32, indices: ?*const anyopaque) callconv(.c) void {
    const c = cur() orelse return;
    if (end < start) {
        if (c.err == g.NO_ERROR) c.err = g.INVALID_VALUE;
        return;
    }
    c.drawElements(mode, n, ty, @intFromPtr(indices), 1);
}
pub export fn glBlendFunc(src: u32, dst: u32) callconv(.c) void {
    if (cur()) |c| c.blendFunc(src, dst, src, dst);
}
pub export fn glBlendFuncSeparate(src_rgb: u32, dst_rgb: u32, src_a: u32, dst_a: u32) callconv(.c) void {
    if (cur()) |c| c.blendFunc(src_rgb, dst_rgb, src_a, dst_a);
}
pub export fn glBlendEquation(mode: u32) callconv(.c) void {
    if (cur()) |c| c.blendEquation(mode, mode);
}
pub export fn glBlendEquationSeparate(rgb: u32, a: u32) callconv(.c) void {
    if (cur()) |c| c.blendEquation(rgb, a);
}
pub export fn glBlendColor(r: f32, gr: f32, bl: f32, a: f32) callconv(.c) void {
    if (cur()) |c| c.blendColor(r, gr, bl, a);
}
pub export fn glDepthFunc(func: u32) callconv(.c) void {
    if (cur()) |c| c.depthFunc(func);
}
pub export fn glDepthRangef(n: f32, f_: f32) callconv(.c) void {
    if (cur()) |c| c.depthRange(n, f_);
}
pub export fn glCullFace(mode: u32) callconv(.c) void {
    if (cur()) |c| c.cullFace(mode);
}
pub export fn glFrontFace(mode: u32) callconv(.c) void {
    if (cur()) |c| c.frontFace(mode);
}

// ── Shaders and programs (program.sig) ─────────────────────────────────────

pub export fn glCreateShader(kind: u32) callconv(.c) u32 {
    const c = cur() orelse return 0;
    return program.createShader(c, kind);
}
pub export fn glDeleteShader(shader: u32) callconv(.c) void {
    if (cur()) |c| program.deleteShader(c, shader);
}
pub export fn glIsShader(shader: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(program.isShader(c, shader));
}
pub export fn glShaderSource(shader: u32, n: i32, strings: ?[*]const ?[*]const u8, lengths: ?[*]const i32) callconv(.c) void {
    if (cur()) |c| program.shaderSource(c, shader, n, strings, lengths);
}
pub export fn glCompileShader(shader: u32) callconv(.c) void {
    if (cur()) |c| program.compileShader(c, shader);
}
pub export fn glGetShaderiv(shader: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const out = params orelse return;
    program.getShaderiv(c, shader, pname, &out[0]);
}
pub export fn glGetShaderInfoLog(shader: u32, buf_size: i32, length: ?*i32, log: ?[*]u8) callconv(.c) void {
    if (cur()) |c| program.getShaderInfoLog(c, shader, buf_size, length, log);
}
pub export fn glGetShaderSource(shader: u32, buf_size: i32, length: ?*i32, source: ?[*]u8) callconv(.c) void {
    if (cur()) |c| program.getShaderSource(c, shader, buf_size, length, source);
}
pub export fn glGetShaderPrecisionFormat(shader_type: u32, precision_type: u32, range: ?*[2]i32, precision: ?*i32) callconv(.c) void {
    if (cur()) |c| program.getShaderPrecisionFormat(c, shader_type, precision_type, range, precision);
}
pub export fn glReleaseShaderCompiler() callconv(.c) void {}
pub export fn glShaderBinary(n: i32, shaders: ?[*]const u32, format: u32, binary: ?*const anyopaque, length: i32) callconv(.c) void {
    _ = .{ n, shaders, format, binary, length };
    // (no binary formats)
    if (cur()) |c| c.fail(g.INVALID_ENUM);
}
pub export fn glCreateProgram() callconv(.c) u32 {
    const c = cur() orelse return 0;
    return program.createProgram(c);
}
pub export fn glDeleteProgram(prog: u32) callconv(.c) void {
    if (cur()) |c| program.deleteProgram(c, prog);
}
pub export fn glIsProgram(prog: u32) callconv(.c) u8 {
    const c = cur() orelse return g.FALSE;
    return @intFromBool(program.isProgram(c, prog));
}
pub export fn glAttachShader(prog: u32, shader: u32) callconv(.c) void {
    if (cur()) |c| program.attachShader(c, prog, shader);
}
pub export fn glDetachShader(prog: u32, shader: u32) callconv(.c) void {
    if (cur()) |c| program.detachShader(c, prog, shader);
}
pub export fn glGetAttachedShaders(prog: u32, max_count: i32, n: ?*i32, shaders: ?[*]u32) callconv(.c) void {
    if (cur()) |c| program.getAttachedShaders(c, prog, max_count, n, shaders);
}
pub export fn glLinkProgram(prog: u32) callconv(.c) void {
    if (cur()) |c| program.linkProgram(c, prog);
}
pub export fn glValidateProgram(prog: u32) callconv(.c) void {
    if (cur()) |c| program.validateProgram(c, prog);
}
pub export fn glUseProgram(prog: u32) callconv(.c) void {
    if (cur()) |c| program.useProgram(c, prog);
}
pub export fn glProgramParameteri(prog: u32, pname: u32, value: i32) callconv(.c) void {
    if (cur()) |c| program.programParameteri(c, prog, pname, value);
}
pub export fn glGetProgramiv(prog: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    const c = cur() orelse return;
    const out = params orelse return;
    program.getProgramiv(c, prog, pname, &out[0]);
}
pub export fn glGetProgramInfoLog(prog: u32, buf_size: i32, length: ?*i32, log: ?[*]u8) callconv(.c) void {
    if (cur()) |c| program.getProgramInfoLog(c, prog, buf_size, length, log);
}
pub export fn glGetProgramBinary(prog: u32, buf_size: i32, length: ?*i32, format: ?*u32, binary: ?*anyopaque) callconv(.c) void {
    _ = .{ prog, buf_size, format, binary };
    if (length) |l| l.* = 0;
    // (no binary formats)
    if (cur()) |c| c.fail(g.INVALID_OPERATION);
}
pub export fn glProgramBinary(prog: u32, format: u32, binary: ?*const anyopaque, length: i32) callconv(.c) void {
    _ = .{ prog, format, binary, length };
    if (cur()) |c| c.fail(g.INVALID_ENUM);
}
pub export fn glBindAttribLocation(prog: u32, index: u32, name: [*:0]const u8) callconv(.c) void {
    if (cur()) |c| program.bindAttribLocation(c, prog, index, name);
}
pub export fn glGetAttribLocation(prog: u32, name: [*:0]const u8) callconv(.c) i32 {
    const c = cur() orelse return -1;
    return program.getAttribLocation(c, prog, name);
}
pub export fn glGetActiveAttrib(prog: u32, index: u32, buf_size: i32, length: ?*i32, size: ?*i32, kind: ?*u32, name: ?[*]u8) callconv(.c) void {
    if (cur()) |c| program.getActiveAttrib(c, prog, index, buf_size, length, size, kind, name);
}
pub export fn glGetUniformLocation(prog: u32, name: [*:0]const u8) callconv(.c) i32 {
    const c = cur() orelse return -1;
    return program.getUniformLocation(c, prog, name);
}
pub export fn glGetActiveUniform(prog: u32, index: u32, buf_size: i32, length: ?*i32, size: ?*i32, kind: ?*u32, name: ?[*]u8) callconv(.c) void {
    if (cur()) |c| program.getActiveUniform(c, prog, index, buf_size, length, size, kind, name);
}
pub export fn glGetActiveUniformsiv(prog: u32, n: i32, indices: [*]const u32, pname: u32, params: [*]i32) callconv(.c) void {
    if (cur()) |c| program.getActiveUniformsiv(c, prog, n, indices, pname, params);
}
pub export fn glGetUniformIndices(prog: u32, n: i32, names: [*]const [*:0]const u8, indices: [*]u32) callconv(.c) void {
    if (cur()) |c| program.getUniformIndices(c, prog, n, names, indices);
}
pub export fn glGetFragDataLocation(prog: u32, name: [*:0]const u8) callconv(.c) i32 {
    const c = cur() orelse return -1;
    return program.getFragDataLocation(c, prog, name);
}
// (uniform blocks: none yet, so no index names one)
pub export fn glGetUniformBlockIndex(prog: u32, name: [*:0]const u8) callconv(.c) u32 {
    _ = .{ prog, name };
    return g.INVALID_INDEX;
}
pub export fn glUniformBlockBinding(prog: u32, index: u32, binding: u32) callconv(.c) void {
    _ = .{ prog, index, binding };
    if (cur()) |c| c.fail(g.INVALID_VALUE);
}
pub export fn glGetActiveUniformBlockiv(prog: u32, index: u32, pname: u32, params: ?[*]i32) callconv(.c) void {
    _ = .{ prog, index, pname, params };
    if (cur()) |c| c.fail(g.INVALID_VALUE);
}
pub export fn glGetActiveUniformBlockName(prog: u32, index: u32, buf_size: i32, length: ?*i32, name: ?[*]u8) callconv(.c) void {
    _ = .{ prog, index, buf_size, length, name };
    if (cur()) |c| c.fail(g.INVALID_VALUE);
}
pub export fn glGetUniformfv(prog: u32, loc: i32, params: [*]f32) callconv(.c) void {
    if (cur()) |c| program.getUniform(c, prog, loc, .f, std.math.maxInt(usize), @ptrCast(params));
}
pub export fn glGetUniformiv(prog: u32, loc: i32, params: [*]i32) callconv(.c) void {
    if (cur()) |c| program.getUniform(c, prog, loc, .i, std.math.maxInt(usize), @ptrCast(params));
}
pub export fn glGetUniformuiv(prog: u32, loc: i32, params: [*]u32) callconv(.c) void {
    if (cur()) |c| program.getUniform(c, prog, loc, .u, std.math.maxInt(usize), params);
}

// robustness: the n-forms write at most buf_size bytes
fn getnUniform(prog: u32, loc: i32, want: program.Data, buf_size: i32, params: [*]u32) void {
    const c = cur() orelse return;
    if (buf_size < 0) return c.fail(g.INVALID_VALUE);
    program.getUniform(c, prog, loc, want, @intCast(buf_size), params);
}
pub export fn glGetnUniformfv(prog: u32, loc: i32, buf_size: i32, params: [*]f32) callconv(.c) void {
    getnUniform(prog, loc, .f, buf_size, @ptrCast(params));
}
pub export fn glGetnUniformfvEXT(prog: u32, loc: i32, buf_size: i32, params: [*]f32) callconv(.c) void {
    getnUniform(prog, loc, .f, buf_size, @ptrCast(params));
}
pub export fn glGetnUniformfvKHR(prog: u32, loc: i32, buf_size: i32, params: [*]f32) callconv(.c) void {
    getnUniform(prog, loc, .f, buf_size, @ptrCast(params));
}
pub export fn glGetnUniformiv(prog: u32, loc: i32, buf_size: i32, params: [*]i32) callconv(.c) void {
    getnUniform(prog, loc, .i, buf_size, @ptrCast(params));
}
pub export fn glGetnUniformivEXT(prog: u32, loc: i32, buf_size: i32, params: [*]i32) callconv(.c) void {
    getnUniform(prog, loc, .i, buf_size, @ptrCast(params));
}
pub export fn glGetnUniformivKHR(prog: u32, loc: i32, buf_size: i32, params: [*]i32) callconv(.c) void {
    getnUniform(prog, loc, .i, buf_size, @ptrCast(params));
}
pub export fn glGetnUniformuiv(prog: u32, loc: i32, buf_size: i32, params: [*]u32) callconv(.c) void {
    getnUniform(prog, loc, .u, buf_size, params);
}
pub export fn glGetnUniformuivKHR(prog: u32, loc: i32, buf_size: i32, params: [*]u32) callconv(.c) void {
    getnUniform(prog, loc, .u, buf_size, params);
}

fn uni(loc: i32, n: i32, comps: u32, kind: program.Data, data: ?*const anyopaque) void {
    const c = cur() orelse return;
    const d: [*]const u32 = @ptrCast(@alignCast(data orelse {
        if (n < 0) c.fail(g.INVALID_VALUE);
        return;
    }));
    program.uniform(c, loc, n, comps, kind, d);
}

fn uniMat(loc: i32, n: i32, transpose: u8, cols: u32, rows: u32, data: ?[*]const f32) void {
    const c = cur() orelse return;
    const d = data orelse {
        if (n < 0) c.fail(g.INVALID_VALUE);
        return;
    };
    program.uniformMatrix(c, loc, n, transpose != 0, cols, rows, @ptrCast(d));
}
pub export fn glUniform1f(loc: i32, x: f32) callconv(.c) void {
    const v = [1]u32{@bitCast(x)};
    uni(loc, 1, 1, .f, &v);
}
pub export fn glUniform1fv(loc: i32, n: i32, v: ?[*]const f32) callconv(.c) void {
    uni(loc, n, 1, .f, v);
}
pub export fn glUniform1i(loc: i32, x: i32) callconv(.c) void {
    const v = [1]u32{@bitCast(x)};
    uni(loc, 1, 1, .i, &v);
}
pub export fn glUniform1iv(loc: i32, n: i32, v: ?[*]const i32) callconv(.c) void {
    uni(loc, n, 1, .i, v);
}
pub export fn glUniform1ui(loc: i32, x: u32) callconv(.c) void {
    const v = [1]u32{x};
    uni(loc, 1, 1, .u, &v);
}
pub export fn glUniform1uiv(loc: i32, n: i32, v: ?[*]const u32) callconv(.c) void {
    uni(loc, n, 1, .u, v);
}
pub export fn glUniform2f(loc: i32, x: f32, y: f32) callconv(.c) void {
    const v = [2]u32{ @bitCast(x), @bitCast(y) };
    uni(loc, 1, 2, .f, &v);
}
pub export fn glUniform2fv(loc: i32, n: i32, v: ?[*]const f32) callconv(.c) void {
    uni(loc, n, 2, .f, v);
}
pub export fn glUniform2i(loc: i32, x: i32, y: i32) callconv(.c) void {
    const v = [2]u32{ @bitCast(x), @bitCast(y) };
    uni(loc, 1, 2, .i, &v);
}
pub export fn glUniform2iv(loc: i32, n: i32, v: ?[*]const i32) callconv(.c) void {
    uni(loc, n, 2, .i, v);
}
pub export fn glUniform2ui(loc: i32, x: u32, y: u32) callconv(.c) void {
    const v = [2]u32{ x, y };
    uni(loc, 1, 2, .u, &v);
}
pub export fn glUniform2uiv(loc: i32, n: i32, v: ?[*]const u32) callconv(.c) void {
    uni(loc, n, 2, .u, v);
}
pub export fn glUniform3f(loc: i32, x: f32, y: f32, z: f32) callconv(.c) void {
    const v = [3]u32{ @bitCast(x), @bitCast(y), @bitCast(z) };
    uni(loc, 1, 3, .f, &v);
}
pub export fn glUniform3fv(loc: i32, n: i32, v: ?[*]const f32) callconv(.c) void {
    uni(loc, n, 3, .f, v);
}
pub export fn glUniform3i(loc: i32, x: i32, y: i32, z: i32) callconv(.c) void {
    const v = [3]u32{ @bitCast(x), @bitCast(y), @bitCast(z) };
    uni(loc, 1, 3, .i, &v);
}
pub export fn glUniform3iv(loc: i32, n: i32, v: ?[*]const i32) callconv(.c) void {
    uni(loc, n, 3, .i, v);
}
pub export fn glUniform3ui(loc: i32, x: u32, y: u32, z: u32) callconv(.c) void {
    const v = [3]u32{ x, y, z };
    uni(loc, 1, 3, .u, &v);
}
pub export fn glUniform3uiv(loc: i32, n: i32, v: ?[*]const u32) callconv(.c) void {
    uni(loc, n, 3, .u, v);
}
pub export fn glUniform4f(loc: i32, x: f32, y: f32, z: f32, w: f32) callconv(.c) void {
    const v = [4]u32{ @bitCast(x), @bitCast(y), @bitCast(z), @bitCast(w) };
    uni(loc, 1, 4, .f, &v);
}
pub export fn glUniform4fv(loc: i32, n: i32, v: ?[*]const f32) callconv(.c) void {
    uni(loc, n, 4, .f, v);
}
pub export fn glUniform4i(loc: i32, x: i32, y: i32, z: i32, w: i32) callconv(.c) void {
    const v = [4]u32{ @bitCast(x), @bitCast(y), @bitCast(z), @bitCast(w) };
    uni(loc, 1, 4, .i, &v);
}
pub export fn glUniform4iv(loc: i32, n: i32, v: ?[*]const i32) callconv(.c) void {
    uni(loc, n, 4, .i, v);
}
pub export fn glUniform4ui(loc: i32, x: u32, y: u32, z: u32, w: u32) callconv(.c) void {
    const v = [4]u32{ x, y, z, w };
    uni(loc, 1, 4, .u, &v);
}
pub export fn glUniform4uiv(loc: i32, n: i32, v: ?[*]const u32) callconv(.c) void {
    uni(loc, n, 4, .u, v);
}
pub export fn glUniformMatrix2fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 2, 2, v);
}
pub export fn glUniformMatrix3fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 3, 3, v);
}
pub export fn glUniformMatrix4fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 4, 4, v);
}
pub export fn glUniformMatrix2x3fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 2, 3, v);
}
pub export fn glUniformMatrix3x2fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 3, 2, v);
}
pub export fn glUniformMatrix2x4fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 2, 4, v);
}
pub export fn glUniformMatrix4x2fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 4, 2, v);
}
pub export fn glUniformMatrix3x4fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 3, 4, v);
}
pub export fn glUniformMatrix4x3fv(loc: i32, n: i32, transpose: u8, v: ?[*]const f32) callconv(.c) void {
    uniMat(loc, n, transpose, 4, 3, v);
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
    glPopGroupMarkerEXT();
    glPushGroupMarkerEXT(0, "outer");
    glPushGroupMarkerEXT(0, null);
    glInsertEventMarkerEXT(2, "hi");
    try std.testing.expectEqual(@as(u32, 2), t_ctx.marker_depth);
    glPopGroupMarkerEXT();
    glPopGroupMarkerEXT();
    glPopGroupMarkerEXT();
    try std.testing.expectEqual(@as(u32, 0), t_ctx.marker_depth);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
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

test "libgles: robustness: the extensions, the strategy, a reset told once, the n-forms" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    var win = t_eng.newImage(4, 4, .rgba8).?;
    defer t_eng.freeImage(&win);
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    t_ctx.setSurface(&win, &win, null);
    // named, as Firefox asks (its feature "robustness" comes only from them)
    const ext = std.mem.span(glGetString(g.EXTENSIONS).?);
    try std.testing.expect(std.mem.indexOf(u8, ext, "GL_EXT_robustness") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext, "GL_KHR_robustness") != null);
    var v: [4]i32 = undefined;
    glGetIntegerv(g.RESET_NOTIFICATION_STRATEGY, &v);
    try std.testing.expectEqual(@as(i32, g.NO_RESET_NOTIFICATION), v[0]);
    glGetIntegerv(g.CONTEXT_ROBUST_ACCESS, &v);
    try std.testing.expectEqual(@as(i32, 0), v[0]);
    // EGL's LOSE_CONTEXT_ON_RESET
    t_ctx.lose_on_reset = true;
    glGetIntegerv(g.RESET_NOTIFICATION_STRATEGY, &v);
    try std.testing.expectEqual(@as(i32, g.LOSE_CONTEXT_ON_RESET), v[0]);
    try std.testing.expectEqual(g.NO_ERROR, glGetGraphicsResetStatusEXT());
    // the n-forms: a buffer too small is refused, nothing written
    var px = [_]u8{0xaa} ** 8;
    glReadnPixelsEXT(0, 0, 2, 1, g.RGBA, g.UNSIGNED_BYTE, 4, &px);
    try std.testing.expectEqual(g.INVALID_OPERATION, glGetError());
    try std.testing.expectEqual(@as(u8, 0xaa), px[0]);
    glClearColor(0, 1, 0, 1);
    glClear(g.COLOR_BUFFER_BIT);
    glReadnPixelsKHR(0, 0, 2, 1, g.RGBA, g.UNSIGNED_BYTE, 8, &px);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255, 0, 255, 0, 255 }, &px);
    glReadnPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, -1, &px);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    // a lost GPU: a reset told once, CONTEXT_LOST once, then work goes on
    t_eng.lost = true;
    try std.testing.expectEqual(g.CONTEXT_LOST, glGetError());
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    try std.testing.expectEqual(g.UNKNOWN_CONTEXT_RESET, glGetGraphicsResetStatusKHR());
    try std.testing.expectEqual(g.NO_ERROR, glGetGraphicsResetStatus());
    glClear(g.COLOR_BUFFER_BIT);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    // NO_RESET_NOTIFICATION says nothing of it
    t_ctx.lose_on_reset = false;
    t_ctx.reset_told = false;
    try std.testing.expectEqual(g.NO_ERROR, glGetGraphicsResetStatus());
}

test "libgles: framebuffer copies reach the selected array or volume mip and layer" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var source = t_eng.newImage(4, 4, .rgba8).?;
    defer t_eng.freeImage(&source);
    t_ctx.setSurface(&source, &source, null);
    glClearColor(0, 1, 0, 1);
    glClear(g.COLOR_BUFFER_BIT);
    var names: [2]u32 = undefined;
    glGenTextures(2, &names);
    glBindTexture(g.TEXTURE_2D_ARRAY, names[0]);
    glTexStorage3D(g.TEXTURE_2D_ARRAY, 2, g.RGBA8, 4, 4, 3);
    glCopyTexSubImage3D(g.TEXTURE_2D_ARRAY, 1, 0, 0, 2, -1, 0, 2, 2);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    var framebuffer: [1]u32 = undefined;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(g.READ_FRAMEBUFFER, framebuffer[0]);
    glFramebufferTextureLayer(g.READ_FRAMEBUFFER, g.COLOR_ATTACHMENT0, names[0], 1, 2);
    var pixels: [16]u8 = undefined;
    glReadPixels(0, 0, 2, 2, g.RGBA, g.UNSIGNED_BYTE, &pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0, 0, 0, 255, 0, 255 }, &pixels);
    glFramebufferTextureLayer(g.READ_FRAMEBUFFER, g.COLOR_ATTACHMENT0, names[0], 1, 1);
    glReadPixels(0, 0, 2, 2, g.RGBA, g.UNSIGNED_BYTE, &pixels);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0))), &pixels);
    glBindFramebuffer(g.READ_FRAMEBUFFER, 0);
    glCopyTexSubImage3D(g.TEXTURE_2D_ARRAY, 1, 0, 0, 3, 0, 0, 2, 2);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    glBindTexture(g.TEXTURE_3D, names[1]);
    glTexStorage3D(g.TEXTURE_3D, 3, g.RGBA8, 4, 4, 4);
    glCopyTexSubImage3D(g.TEXTURE_3D, 1, 0, 0, 1, 0, 0, 2, 2);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    glBindFramebuffer(g.READ_FRAMEBUFFER, framebuffer[0]);
    glFramebufferTextureLayer(g.READ_FRAMEBUFFER, g.COLOR_ATTACHMENT0, names[1], 1, 1);
    glReadPixels(0, 0, 2, 2, g.RGBA, g.UNSIGNED_BYTE, &pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255 }, &pixels);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

test "libgles: buffer copies preserve bindings, reject overlap and respect maps" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var names: [2]u32 = undefined;
    glGenBuffers(2, &names);
    glBindBuffer(g.COPY_READ_BUFFER, names[0]);
    const bytes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    glBufferData(g.COPY_READ_BUFFER, bytes.len, &bytes, g.STATIC_DRAW);
    glBindBuffer(g.COPY_WRITE_BUFFER, names[1]);
    glBufferData(g.COPY_WRITE_BUFFER, bytes.len, null, g.STATIC_DRAW);
    glCopyBufferSubData(g.COPY_READ_BUFFER, g.COPY_WRITE_BUFFER, 2, 3, 4);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    const mapped = glMapBufferRange(g.COPY_WRITE_BUFFER, 0, bytes.len, 1).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 3, 4, 5, 0 }, @as([*]const u8, @ptrCast(mapped))[0..bytes.len]);
    glCopyBufferSubData(g.COPY_READ_BUFFER, g.COPY_WRITE_BUFFER, 0, 0, 1);
    try std.testing.expectEqual(g.INVALID_OPERATION, glGetError());
    try std.testing.expectEqual(@as(u8, 1), glUnmapBuffer(g.COPY_WRITE_BUFFER));
    glBindBuffer(g.COPY_WRITE_BUFFER, names[0]);
    glCopyBufferSubData(g.COPY_READ_BUFFER, g.COPY_WRITE_BUFFER, 0, 2, 4);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    glCopyBufferSubData(g.COPY_READ_BUFFER, g.COPY_WRITE_BUFFER, 0, 4, 4);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    const copied = glMapBufferRange(g.COPY_READ_BUFFER, 0, bytes.len, 1).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 0, 1, 2, 3 }, @as([*]const u8, @ptrCast(copied))[0..bytes.len]);
    try std.testing.expectEqual(@as(u8, 1), glUnmapBuffer(g.COPY_READ_BUFFER));
    glCopyBufferSubData(g.COPY_READ_BUFFER, g.COPY_WRITE_BUFFER, std.math.maxInt(isize), 0, 1);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    var binding: i32 = 0;
    glGetIntegerv(g.COPY_READ_BUFFER, @ptrCast(&binding));
    try std.testing.expectEqual(@as(i32, @intCast(names[0])), binding);
}

test "libgles: vertex attribute queries keep vector types, VAO offsets and untouched outputs on errors" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var floats: [4]f32 = undefined;
    var ints: [4]i32 = undefined;
    var uints: [4]u32 = undefined;
    glGetVertexAttribfv(3, g.CURRENT_VERTEX_ATTRIB, &floats);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1 }, &floats);
    glVertexAttrib4f(3, 0.5, -1.5, 2.5, 1);
    glGetVertexAttribfv(3, g.CURRENT_VERTEX_ATTRIB, &floats);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -1.5, 2.5, 1 }, &floats);
    glGetVertexAttribiv(3, g.CURRENT_VERTEX_ATTRIB, &ints);
    try std.testing.expectEqualSlices(i32, &.{ 1, -2, 3, 1 }, &ints);
    glVertexAttribI4i(3, -5, 6, -7, 8);
    glGetVertexAttribIiv(3, g.CURRENT_VERTEX_ATTRIB, &ints);
    try std.testing.expectEqualSlices(i32, &.{ -5, 6, -7, 8 }, &ints);
    glGetVertexAttribfv(3, g.CURRENT_VERTEX_ATTRIB, &floats);
    try std.testing.expectEqualSlices(f32, &.{ -5, 6, -7, 8 }, &floats);
    glVertexAttribI4ui(3, 0xffffffff, 0x80000000, 2, 3);
    glGetVertexAttribIuiv(3, g.CURRENT_VERTEX_ATTRIB, &uints);
    try std.testing.expectEqualSlices(u32, &.{ 0xffffffff, 0x80000000, 2, 3 }, &uints);
    glGetVertexAttribfv(3, g.CURRENT_VERTEX_ATTRIB, &floats);
    try std.testing.expect(floats[0] > 4e9 and floats[1] > 2e9);
    const offset: usize = if (@sizeOf(usize) == 8) 0x123456789 else 0x12345;
    glVertexAttribPointer(3, 2, g.FLOAT, 0, 16, @ptrFromInt(offset));
    var pointer: ?*anyopaque = null;
    glGetVertexAttribPointerv(3, g.VERTEX_ATTRIB_ARRAY_POINTER, &pointer);
    try std.testing.expectEqual(offset, @intFromPtr(pointer));
    glGetVertexAttribPointerv(3, g.FLOAT, &pointer);
    try std.testing.expectEqual(g.INVALID_ENUM, glGetError());
    try std.testing.expectEqual(offset, @intFromPtr(pointer));
    uints = @splat(99);
    glGetVertexAttribIuiv(gles.MAX_ATTRS, g.CURRENT_VERTEX_ATTRIB, &uints);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    try std.testing.expectEqualSlices(u32, &.{ 99, 99, 99, 99 }, &uints);
}

test "libgles: getProcAddress finds every entry point, and nothing else" {
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glClear)), getProcAddress("glClear"));
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glTexStorage2DEXT)), getProcAddress("glTexStorage2DEXT"));
    try std.testing.expect(getProcAddress("glBeginTransformFeedback") == null);
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glUniformMatrix4x3fv)), getProcAddress("glUniformMatrix4x3fv"));
    try std.testing.expect(getProcAddress("getProcAddress") == null);
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glReadnPixelsEXT)), getProcAddress("glReadnPixelsEXT"));
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&glGetnUniformfvKHR)), getProcAddress("glGetnUniformfvKHR"));
    try std.testing.expect(entries.len > 70);
}

fn shaderOk(s: u32) !void {
    var ok: i32 = 0;
    glGetShaderiv(s, g.COMPILE_STATUS, @ptrCast(&ok));
    if (ok != 1) {
        var buf: [1024]u8 = undefined;
        var len: i32 = 0;
        glGetShaderInfoLog(s, buf.len, &len, &buf);
        std.debug.print("{s}\n", .{buf[0..@intCast(len)]});
        return error.TestUnexpectedResult;
    }
}

fn linkOk(p: u32) !void {
    var ok: i32 = 0;
    glGetProgramiv(p, g.LINK_STATUS, @ptrCast(&ok));
    if (ok != 1) {
        var buf: [1024]u8 = undefined;
        var len: i32 = 0;
        glGetProgramInfoLog(p, buf.len, &len, &buf);
        std.debug.print("{s}\n", .{buf[0..@intCast(len)]});
        return error.TestUnexpectedResult;
    }
}

fn newShader(kind: u32, src: [:0]const u8) u32 {
    const s = glCreateShader(kind);
    const parts = [_]?[*]const u8{src.ptr};
    glShaderSource(s, 1, &parts, null);
    glCompileShader(s);
    return s;
}

test "libgles: shaders, programs and uniforms through the C entry points" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    const E = std.testing.expectEqual;
    const vs_src =
        \\#version 300 es
        \\in vec2 aPos;
        \\in vec4 aColor;
        \\in float aUnused;
        \\uniform mat4 uTransform;
        \\uniform vec4 uTint[3];
        \\out vec4 vColor;
        \\flat out int vLayer;
        \\void main() {
        \\    vColor = aColor * uTint[2];
        \\    vLayer = 1;
        \\    gl_Position = uTransform * vec4(aPos, 0.0, 1.0);
        \\}
    ;
    const vs = glCreateShader(g.VERTEX_SHADER);
    const vparts = [_]?[*]const u8{vs_src.ptr};
    const vlens = [_]i32{@intCast(vs_src.len)};
    glShaderSource(vs, 1, &vparts, &vlens);
    glCompileShader(vs);
    try shaderOk(vs);
    var n: i32 = 0;
    glGetShaderiv(vs, g.SHADER_SOURCE_LENGTH, @ptrCast(&n));
    try E(@as(i32, @intCast(vs_src.len + 1)), n);
    // the fragment shader in two parts, each NUL-terminated
    const fparts = [_]?[*]const u8{
        "#version 300 es\nprecision mediump float;\n",
        \\uniform sampler2D sColor;
        \\uniform bool uOn;
        \\in vec4 vColor;
        \\flat in int vLayer;
        \\layout(location = 0) out vec4 oColor;
        \\void main() { oColor = uOn ? texture(sColor, vec2(0.5)) * vColor : vColor * float(vLayer); }
    };
    const fs = glCreateShader(g.FRAGMENT_SHADER);
    glShaderSource(fs, 2, &fparts, null);
    glCompileShader(fs);
    try shaderOk(fs);
    const prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glAttachShader(prog, vs);
    try E(g.INVALID_OPERATION, glGetError());
    glBindAttribLocation(prog, 5, "aColor");
    glLinkProgram(prog);
    try linkOk(prog);
    try E(g.NO_ERROR, glGetError());
    glGetProgramiv(prog, g.ACTIVE_ATTRIBUTES, @ptrCast(&n));
    try E(@as(i32, 2), n);
    try E(@as(i32, 0), glGetAttribLocation(prog, "aPos"));
    try E(@as(i32, 5), glGetAttribLocation(prog, "aColor"));
    try E(@as(i32, -1), glGetAttribLocation(prog, "aUnused"));
    glGetProgramiv(prog, g.ACTIVE_UNIFORMS, @ptrCast(&n));
    try E(@as(i32, 4), n);
    const l_transform = glGetUniformLocation(prog, "uTransform");
    const l_tint = glGetUniformLocation(prog, "uTint");
    const l_tint2 = glGetUniformLocation(prog, "uTint[2]");
    const l_color = glGetUniformLocation(prog, "sColor");
    const l_on = glGetUniformLocation(prog, "uOn");
    try E(@as(i32, 0), l_transform);
    try E(@as(i32, 1), l_tint);
    try E(l_tint + 2, l_tint2);
    try E(@as(i32, -1), glGetUniformLocation(prog, "uTint[3]"));
    try E(@as(i32, -1), glGetUniformLocation(prog, "uTint[02]"));
    try std.testing.expect(l_color >= 0 and l_on >= 0);
    var name: [32]u8 = undefined;
    var len: i32 = 0;
    var size: i32 = 0;
    var kind: u32 = 0;
    glGetActiveUniform(prog, 1, name.len, &len, &size, &kind, &name);
    try std.testing.expectEqualStrings("uTint[0]", name[0..@intCast(len)]);
    try E(@as(i32, 3), size);
    try E(@as(u32, 0x8B52), kind); // GL_FLOAT_VEC4
    glGetActiveAttrib(prog, 1, name.len, &len, &size, &kind, &name);
    try std.testing.expectEqualStrings("aColor", name[0..@intCast(len)]);
    try E(@as(i32, 0), glGetFragDataLocation(prog, "oColor"));
    // values
    glUniform4f(l_tint, 1, 1, 1, 1);
    try E(g.INVALID_OPERATION, glGetError()); // (no program in use)
    glUseProgram(prog);
    glGetIntegerv(g.CURRENT_PROGRAM, @ptrCast(&n));
    try E(@as(i32, @intCast(prog)), n);
    glUniform4f(l_tint2, 1, 2, 3, 4);
    const two = [_]f32{ 5, 6, 7, 8, 9, 10, 11, 12 };
    glUniform4fv(l_tint, 2, &two);
    var f: [16]f32 = undefined;
    glGetUniformfv(prog, l_tint2, &f);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, f[0..4]);
    glGetUniformfv(prog, l_tint + 1, &f);
    try std.testing.expectEqualSlices(f32, &.{ 9, 10, 11, 12 }, f[0..4]);
    glUniform1i(l_color, 3);
    var iv: [4]i32 = undefined;
    glGetUniformiv(prog, l_color, &iv);
    try E(@as(i32, 3), iv[0]);
    glUniform1f(l_color, 1.0);
    try E(g.INVALID_OPERATION, glGetError());
    glUniform1i(l_color, 99);
    try E(g.INVALID_VALUE, glGetError());
    glUniform3f(l_tint, 1, 2, 3);
    try E(g.INVALID_OPERATION, glGetError());
    glUniform1i(-1, 0);
    try E(g.NO_ERROR, glGetError());
    glUniform1i(l_on, 7);
    glGetUniformfv(prog, l_on, &f);
    try E(@as(f32, 1), f[0]);
    // a matrix, given row by row
    var m: [16]f32 = undefined;
    for (&m, 0..) |*x, k| x.* = @floatFromInt(k);
    glUniformMatrix4fv(l_transform, 1, g.TRUE, &m);
    glGetUniformfv(prog, l_transform, &f);
    try E(@as(f32, 4), f[1]); // column 0, row 1: the source's row 1, column 0
    try E(@as(f32, 1), f[4]);
    glUniformMatrix3fv(l_transform, 1, g.FALSE, &m);
    try E(g.INVALID_OPERATION, glGetError());
    // what goes wrong: a compile's log, a link's
    const bad = newShader(g.VERTEX_SHADER, "#version 300 es\nvoid main() { gl_Position = 1.0; }");
    glGetShaderiv(bad, g.COMPILE_STATUS, @ptrCast(&n));
    try E(@as(i32, 0), n);
    glGetShaderInfoLog(bad, name.len, &len, &name);
    try std.testing.expect(std.mem.startsWith(u8, name[0..@intCast(len)], "0:2: error: "));
    try E(@as(i32, 31), len); // (cut to the buffer, its NUL)
    const fs2 = newShader(g.FRAGMENT_SHADER, "#version 300 es\nprecision mediump float;\nin vec3 vNormal;\nout vec4 o;\nvoid main() { o = vec4(vNormal, 1.0); }");
    try shaderOk(fs2);
    const prog2 = glCreateProgram();
    glAttachShader(prog2, vs);
    glAttachShader(prog2, fs2);
    glLinkProgram(prog2);
    glGetProgramiv(prog2, g.LINK_STATUS, @ptrCast(&n));
    try E(@as(i32, 0), n);
    var log: [256]u8 = undefined;
    glGetProgramInfoLog(prog2, log.len, &len, &log);
    try std.testing.expect(std.mem.indexOf(u8, log[0..@intCast(len)], "`vNormal` is not an output of the vertex shader") != null);
    glUseProgram(prog2);
    try E(g.INVALID_OPERATION, glGetError());
    // deleting: a shader stays while attached, a program while in use
    glDeleteShader(vs);
    try E(g.TRUE, glIsShader(vs));
    glGetShaderiv(vs, g.DELETE_STATUS, @ptrCast(&n));
    try E(@as(i32, 1), n);
    glDeleteProgram(prog2);
    try E(g.TRUE, glIsShader(vs)); // (still prog's)
    glDetachShader(prog, vs);
    try E(g.FALSE, glIsShader(vs));
    glDeleteProgram(prog);
    try E(g.TRUE, glIsProgram(prog));
    glUseProgram(0);
    try E(g.FALSE, glIsProgram(prog));
    try E(g.FALSE, glIsProgram(fs));
    glUseProgram(fs);
    try E(g.INVALID_OPERATION, glGetError());
    glUseProgram(12345);
    try E(g.INVALID_VALUE, glGetError());
    glDeleteShader(fs);
    glDeleteShader(fs2);
    glDeleteShader(bad);
}

test "libgles: a GLSL ES 1.00 program, as WebGL 1 writes them" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    const vs = newShader(g.VERTEX_SHADER,
        \\attribute vec3 position;
        \\attribute vec2 uv;
        \\uniform mat4 mvp;
        \\varying vec2 vUv;
        \\void main() { vUv = uv; gl_Position = mvp * vec4(position, 1.0); }
    );
    const fs = newShader(g.FRAGMENT_SHADER,
        \\#ifdef GL_FRAGMENT_PRECISION_HIGH
        \\precision highp float;
        \\#else
        \\precision mediump float;
        \\#endif
        \\uniform sampler2D tex;
        \\varying vec2 vUv;
        \\void main() { gl_FragColor = texture2D(tex, vUv); }
    );
    try shaderOk(vs);
    try shaderOk(fs);
    const p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glLinkProgram(p);
    try linkOk(p);
    try std.testing.expectEqual(@as(i32, 0), glGetAttribLocation(p, "position"));
    try std.testing.expectEqual(@as(i32, 1), glGetAttribLocation(p, "uv"));
    var range: [2]i32 = undefined;
    var precision: i32 = 0;
    glGetShaderPrecisionFormat(g.FRAGMENT_SHADER, g.HIGH_FLOAT, &range, &precision);
    try std.testing.expectEqual(@as(i32, 23), precision);
    glDeleteProgram(p);
    glDeleteShader(vs);
    glDeleteShader(fs);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

test "libgles: texture formats and sampler objects through the C entry points" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    const E = std.testing.expectEqual;
    var t: [1]u32 = undefined;
    glGenTextures(1, &t);
    glBindTexture(g.TEXTURE_2D, t[0]);
    // R8, then RGBA16F from halves, then integers: as GL ES 3.0 takes them
    const r8 = [_]u8{ 1, 2, 3, 4 };
    glTexImage2D(g.TEXTURE_2D, 0, @intCast(g.R8), 4, 1, 0, g.RED, g.UNSIGNED_BYTE, &r8);
    try E(g.NO_ERROR, glGetError());
    try E(gfxapi.engine.Format.r8, t_objs.tex[t[0] - 1].img.format);
    const halves = [_]u16{ 0x3c00, 0, 0, 0x3c00 };
    glTexImage2D(g.TEXTURE_2D, 0, @intCast(g.RGBA16F), 1, 1, 0, g.RGBA, g.HALF_FLOAT, &halves);
    try E(g.NO_ERROR, glGetError());
    try E(gfxapi.engine.Format.rgba32f, t_objs.tex[t[0] - 1].img.format);
    // a format the internal format does not take; an unknown internal format
    glTexImage2D(g.TEXTURE_2D, 0, @intCast(g.RGBA8), 1, 1, 0, g.RGB, g.UNSIGNED_BYTE, &r8);
    try E(g.INVALID_OPERATION, glGetError());
    glTexImage2D(g.TEXTURE_2D, 0, 0x1234, 1, 1, 0, g.RGBA, g.UNSIGNED_BYTE, &r8);
    try E(g.INVALID_VALUE, glGetError());
    // a level past a 1 x 1 texture's: taken, not stored; mipmaps of a
    // float texture: refused (ES 3.0 makes them for what it renders, and
    // floats are not rendered here)
    glTexImage2D(g.TEXTURE_2D, 1, @intCast(g.RGBA8), 1, 1, 0, g.RGBA, g.UNSIGNED_BYTE, &r8);
    try E(g.NO_ERROR, glGetError());
    glGenerateMipmap(g.TEXTURE_2D);
    try E(g.INVALID_OPERATION, glGetError());
    glTexParameteri(g.TEXTURE_2D, g.TEXTURE_SWIZZLE_A, @intCast(g.ONE));
    var v: i32 = 0;
    glGetTexParameteriv(g.TEXTURE_2D, g.TEXTURE_SWIZZLE_A, @ptrCast(&v));
    try E(@as(i32, @intCast(g.ONE)), v);
    // samplers: named at once, bound per unit, their own state
    var s: [2]u32 = undefined;
    glGenSamplers(2, &s);
    try E(g.TRUE, glIsSampler(s[0]));
    glSamplerParameteri(s[0], g.TEXTURE_MAG_FILTER, @intCast(g.NEAREST));
    glGetSamplerParameteriv(s[0], g.TEXTURE_MAG_FILTER, @ptrCast(&v));
    try E(@as(i32, @intCast(g.NEAREST)), v);
    glSamplerParameteri(s[0], g.TEXTURE_SWIZZLE_R, @intCast(g.GREEN));
    try E(g.INVALID_ENUM, glGetError());
    glActiveTexture(g.TEXTURE0 + 3);
    glBindSampler(3, s[1]);
    glGetIntegerv(g.SAMPLER_BINDING, @ptrCast(&v));
    try E(@as(i32, @intCast(s[1])), v);
    glBindSampler(3, 777);
    try E(g.INVALID_OPERATION, glGetError());
    glDeleteSamplers(2, &s);
    glGetIntegerv(g.SAMPLER_BINDING, @ptrCast(&v));
    try E(@as(i32, 0), v);
    try E(g.FALSE, glIsSampler(s[0]));
    try E(g.NO_ERROR, glGetError());
}

test "libgles: CopyImageSubDataEXT copies a texture subrectangle without changing bindings" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var names: [2]u32 = undefined;
    glGenTextures(2, &names);
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    glBindTexture(g.TEXTURE_2D, names[0]);
    glTexImage2D(g.TEXTURE_2D, 0, @intCast(g.RGBA8), 2, 1, 0, g.RGBA, g.UNSIGNED_BYTE, &pixels);
    glBindTexture(g.TEXTURE_2D, names[1]);
    glTexImage2D(g.TEXTURE_2D, 0, @intCast(g.RGBA8), 2, 1, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    glCopyImageSubDataEXT(names[0], g.TEXTURE_2D, 0, 1, 0, 0, names[1], g.TEXTURE_2D, 0, 0, 0, 0, 1, 1, 1);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    var fb: [1]u32 = undefined;
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(g.FRAMEBUFFER, fb[0]);
    glFramebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, names[1], 0);
    var result: [8]u8 = undefined;
    glReadPixels(0, 0, 2, 1, g.RGBA, g.UNSIGNED_BYTE, &result);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 0, 0, 0, 0 }, &result);
    glCopyImageSubDataEXT(names[0], g.TEXTURE_2D, 0, 1, 0, 0, names[1], g.TEXTURE_2D, 0, 0, 0, 0, 2, 1, 1);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
}

test "libgles: immutable buffer storage enforces update and mapping flags" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var name: [1]u32 = undefined;
    glGenBuffers(1, &name);
    glBindBuffer(g.ARRAY_BUFFER, name[0]);
    const bytes = [_]u8{ 3, 2, 1, 0 };
    glBufferStorageEXT(g.ARRAY_BUFFER, bytes.len, &bytes, 1);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    var imm: [1]i32 = undefined;
    glGetBufferParameteriv(g.ARRAY_BUFFER, 0x821F, &imm);
    try std.testing.expectEqual(@as(i32, 1), imm[0]);
    glBufferSubData(g.ARRAY_BUFFER, 0, bytes.len, &bytes);
    try std.testing.expectEqual(g.INVALID_OPERATION, glGetError());
    glBufferData(g.ARRAY_BUFFER, bytes.len, null, g.STATIC_DRAW);
    try std.testing.expectEqual(g.INVALID_OPERATION, glGetError());
    try std.testing.expect(glMapBufferRange(g.ARRAY_BUFFER, 0, bytes.len, 2) == null);
    try std.testing.expectEqual(g.INVALID_OPERATION, glGetError());
    const mapped: [*]const u8 = @ptrCast(glMapBufferRange(g.ARRAY_BUFFER, 0, bytes.len, 1).?);
    try std.testing.expectEqualSlices(u8, &bytes, mapped[0..bytes.len]);
    try std.testing.expectEqual(@as(u8, 1), glUnmapBuffer(g.ARRAY_BUFFER));
}

test "libgles: persistent buffer mapping survives a server update and barrier" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var name: [1]u32 = undefined;
    glGenBuffers(1, &name);
    glBindBuffer(g.ARRAY_BUFFER, name[0]);
    const read_persistent: u32 = 0x41;
    glBufferStorageEXT(g.ARRAY_BUFFER, 8, null, read_persistent | 0x100);
    const ptr: [*]const u8 = @ptrCast(glMapBufferRange(g.ARRAY_BUFFER, 0, 8, read_persistent).?);
    const bytes = [_]u8{ 4, 3, 2, 1 };
    glBufferSubData(g.ARRAY_BUFFER, 2, bytes.len, &bytes);
    glMemoryBarrier(0x4000);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    try std.testing.expectEqualSlices(u8, &bytes, ptr[2..6]);
    try std.testing.expectEqual(@as(u8, 1), glUnmapBuffer(g.ARRAY_BUFFER));
}

test "libgles: cube-map size queries and storage obey the same limit" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);

    const query = 0x851C; // GL_MAX_CUBE_MAP_TEXTURE_SIZE
    var limit = [_]i32{ -1, -1, -1, -1 };
    var wide = [_]i64{ -1, -1, -1, -1 };
    var float = [_]f32{ -1, -1, -1, -1 };
    var boolean = [_]u8{ 2, 2, 2, 2 };
    glGetIntegerv(query, &limit);
    glGetInteger64v(query, &wide);
    glGetFloatv(query, &float);
    glGetBooleanv(query, &boolean);
    try std.testing.expectEqual([4]i32{ gles.MAX_SIZE, -1, -1, -1 }, limit);
    try std.testing.expectEqual([4]i64{ gles.MAX_SIZE, -1, -1, -1 }, wide);
    try std.testing.expectEqual([4]f32{ gles.MAX_SIZE, -1, -1, -1 }, float);
    try std.testing.expectEqual([4]u8{ 1, 2, 2, 2 }, boolean);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());

    var names: [2]u32 = undefined;
    glGenTextures(names.len, &names);
    glBindTexture(g.TEXTURE_CUBE_MAP, names[0]);
    const face = g.TEXTURE_CUBE_MAP_POSITIVE_X;
    const oversized = limit[0] + 1;
    glTexImage2D(face, 0, g.RGBA8, oversized, oversized, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    // The test pool is too small for a maximum-sized image. Allocation
    // failure here confirms that the exact boundary passed validation.
    glTexImage2D(face, 0, g.RGBA8, limit[0], limit[0], 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.OUT_OF_MEMORY, glGetError());
    glTexImage2D(face, 0, g.RGBA8, 2, 1, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    const last = std.math.log2_int(u32, @intCast(limit[0]));
    glTexImage2D(face, last, g.RGBA8, 2, 2, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    glTexImage2D(face, last, g.RGBA8, 1, 1, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());

    glBindTexture(g.TEXTURE_CUBE_MAP, names[1]);
    glTexStorage2D(g.TEXTURE_CUBE_MAP, 1, g.RGBA8, oversized, oversized);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    glTexStorage2D(g.TEXTURE_CUBE_MAP, 1, g.RGBA8, limit[0], limit[0]);
    try std.testing.expectEqual(g.OUT_OF_MEMORY, glGetError());
    glTexStorage2D(g.TEXTURE_CUBE_MAP, 1, g.RGBA8, 2, 1);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
    glTexStorage2D(g.TEXTURE_CUBE_MAP, 2, g.RGBA8, 2, 2);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

test "libgles: copy array slices to cube faces and volume mips" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var names: [3]u32 = undefined;
    glGenTextures(names.len, &names);
    glBindTexture(g.TEXTURE_2D_ARRAY, names[0]);
    glTexStorage3D(g.TEXTURE_2D_ARRAY, 2, g.RGBA8, 2, 2, 3);
    glBindTexture(g.TEXTURE_CUBE_MAP, names[1]);
    glTexStorage2D(g.TEXTURE_CUBE_MAP, 2, g.RGBA8, 2, 2);
    glBindTexture(g.TEXTURE_3D, names[2]);
    glTexStorage3D(g.TEXTURE_3D, 2, g.RGBA8, 2, 2, 4);
    const pixels = [_]u8{ 99, 99, 99, 99, 1, 2, 3, 4, 5, 6, 7, 8 };
    glPixelStorei(g.UNPACK_SKIP_IMAGES, 1);
    glTexSubImage3D(g.TEXTURE_2D_ARRAY, 1, 0, 0, 1, 1, 1, 2, g.RGBA, g.UNSIGNED_BYTE, &pixels);
    glPixelStorei(g.UNPACK_SKIP_IMAGES, 0);
    glCopyImageSubDataEXT(names[0], g.TEXTURE_2D_ARRAY, 1, 0, 0, 1, names[1], g.TEXTURE_CUBE_MAP, 1, 0, 0, 4, 1, 1, 2);
    glCopyImageSubDataEXT(names[1], g.TEXTURE_CUBE_MAP, 1, 0, 0, 4, names[2], g.TEXTURE_3D, 1, 0, 0, 0, 1, 1, 2);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    const volume = &t_objs.tex[names[2] - 1].img;
    try std.testing.expectEqualSlices(u8, pixels[4..], t_eng.hostView(volume, volume.level_at[1], 8));
    glCopyImageSubDataEXT(names[1], g.TEXTURE_CUBE_MAP, 1, 0, 0, 4, names[2], g.TEXTURE_3D, 1, 0, 0, 1, 1, 1, 2);
    try std.testing.expectEqual(g.INVALID_VALUE, glGetError());
}

test "libgles: mutable array definitions preserve compatible mips" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var names: [1]u32 = undefined;
    glGenTextures(1, &names);
    glBindTexture(g.TEXTURE_2D_ARRAY, names[0]);
    const mip = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    glTexImage3D(g.TEXTURE_2D_ARRAY, 0, g.RGBA8, 2, 2, 2, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    glTexImage3D(g.TEXTURE_2D_ARRAY, 1, g.RGBA8, 1, 1, 2, 0, g.RGBA, g.UNSIGNED_BYTE, &mip);
    glTexImage3D(g.TEXTURE_2D_ARRAY, 0, g.RGBA8, 2, 2, 2, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    const tex = &t_objs.tex[names[0] - 1];
    try std.testing.expectEqualSlices(u8, &mip, t_eng.hostView(&tex.img, tex.img.level_at[1], mip.len));
    glTexImage3D(g.TEXTURE_2D_ARRAY, 0, g.RGBA8, 4, 4, 2, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
    glTexSubImage3D(g.TEXTURE_2D_ARRAY, 1, 0, 0, 0, 1, 1, 2, g.RGBA, g.UNSIGNED_BYTE, &mip);
    var fb: [1]u32 = undefined;
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(g.FRAMEBUFFER, fb[0]);
    glFramebufferTextureLayer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, names[0], 1, 1);
    try std.testing.expectEqual(g.FRAMEBUFFER_COMPLETE, glCheckFramebufferStatus(g.FRAMEBUFFER));
    var pixel: [4]u8 = undefined;
    glReadPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &pixel);
    try std.testing.expectEqualSlices(u8, mip[4..], &pixel);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

test "libgles: a non-base mip can be defined before level zero with its own format" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var names: [2]u32 = undefined;
    glGenTextures(2, &names);
    glPixelStorei(g.UNPACK_ALIGNMENT, 1);
    glBindTexture(g.TEXTURE_2D, names[0]);
    const red = [_]u8{ 13, 42, 81 };
    glTexImage2D(g.TEXTURE_2D, 2, g.R8, 3, 1, 0, g.RED, g.UNSIGNED_BYTE, &red);
    glTexImage2D(g.TEXTURE_2D, 0, g.RGBA8, 4, 4, 0, g.RGBA, g.UNSIGNED_BYTE, null);
    glBindTexture(g.TEXTURE_2D, names[1]);
    glTexStorage2D(g.TEXTURE_2D, 1, g.R8, 3, 1);
    glCopyImageSubDataEXT(names[0], g.TEXTURE_2D, 2, 0, 0, 0, names[1], g.TEXTURE_2D, 0, 0, 0, 0, 3, 1, 1);
    const dst = &t_objs.tex[names[1] - 1].img;
    try std.testing.expectEqualSlices(u8, &red, t_eng.hostView(dst, 0, red.len));
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

test "libgles: KHR debug logs a message and restores filters on group pop" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    const dbg = gles.debug_output;
    glEnable(dbg.OUTPUT);
    glPushDebugGroupKHR(dbg.APPLICATION, 1, -1, "group");
    glDebugMessageControlKHR(dbg.APPLICATION, dbg.ERROR, dbg.ANY, 0, null, 0);
    glDebugMessageInsertKHR(dbg.APPLICATION, dbg.ERROR, 2, dbg.HIGH, -1, "hidden");
    glPopDebugGroupKHR();
    glDebugMessageInsertKHR(dbg.APPLICATION, dbg.ERROR, 3, dbg.HIGH, -1, "visible");
    var ids: [4]u32 = undefined;
    var text: [64]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 3), glGetDebugMessageLogKHR(4, text.len, null, null, &ids, null, null, &text));
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 3 }, ids[0..3]);
    try std.testing.expectEqualSlices(u8, "group\x00group\x00visible\x00", text[0..20]);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

test "libgles: KHR labels are truncated on read and cleared on object reuse" {
    t_eng.init(.{ .pool = &t_pool });
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var name: [1]u32 = undefined;
    glGenBuffers(1, &name);
    glBindBuffer(g.ARRAY_BUFFER, name[0]);
    glObjectLabelKHR(0x82E0, name[0], -1, "vertex data");
    var text: [7]u8 = undefined;
    var len: i32 = 0;
    glGetObjectLabelKHR(0x82E0, name[0], text.len, &len, &text);
    try std.testing.expectEqual(@as(i32, 6), len);
    try std.testing.expectEqualStrings("vertex", std.mem.sliceTo(&text, 0));
    glDeleteBuffers(1, &name);
    glBindBuffer(g.ARRAY_BUFFER, name[0]);
    glGetObjectLabelKHR(0x82E0, name[0], text.len, &len, &text);
    try std.testing.expectEqual(@as(i32, 0), len);
    const sync = glFenceSync(g.SYNC_GPU_COMMANDS_COMPLETE, 0);
    try std.testing.expect(sync != null);
    glObjectPtrLabelKHR(sync, -1, "fence");
    glGetObjectPtrLabelKHR(sync, text.len, &len, &text);
    try std.testing.expectEqualStrings("fence", std.mem.sliceTo(&text, 0));
    glDeleteSync(sync);
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}

const TestTimerDev = @typeInfo(@TypeOf(t_eng.dev)).optional.child;
var test_timer_tick: u64 = 0;

fn testTimerSample(_: *anyopaque, _: u64) error{ OutOfMemory, SubmitFailed, Timeout, DeviceLost, BadProgram, Unsupported }!u64 {
    test_timer_tick += 100;
    return test_timer_tick;
}

test "libgles: timer query lifecycle, 64-bit timestamp and elapsed results" {
    t_eng.init(.{ .pool = &t_pool });
    var vt: TestTimerDev.VTable = undefined;
    vt.timestampNs = testTimerSample;
    t_eng.dev = .{ .ctx = &test_timer_tick, .vtable = &vt, .caps = undefined };
    test_timer_tick = 0x1_0000_0000;
    t_objs.init();
    t_ctx.init(&t_eng, &t_objs);
    defer t_ctx.deinit();
    try std.testing.expect(makeCurrent(&t_ctx));
    defer _ = makeCurrent(null);
    var ids: [2]u32 = undefined;
    glGenQueriesEXT(2, &ids);
    try std.testing.expectEqual(@as(u8, 0), glIsQueryEXT(ids[0]));
    glBeginQueryEXT(gles.TIME_ELAPSED_EXT, ids[0]);
    try std.testing.expectEqual(@as(u8, 1), glIsQueryEXT(ids[0]));
    glEndQueryEXT(gles.TIME_ELAPSED_EXT);
    var value: u64 = 0;
    glGetQueryObjectui64vEXT(ids[0], 0x8866, &value);
    try std.testing.expectEqual(@as(u64, 100), value);
    glQueryCounterEXT(ids[1], gles.TIMESTAMP_EXT);
    glGetQueryObjectui64vEXT(ids[1], 0x8866, &value);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000 + 300), value);
    var now: [1]i64 = undefined;
    glGetInteger64v(gles.TIMESTAMP_EXT, &now);
    try std.testing.expectEqual(@as(i64, 0x1_0000_0000 + 400), now[0]);
    glDeleteQueriesEXT(2, &ids);
    try std.testing.expectEqual(@as(u8, 0), glIsQueryEXT(ids[0]));
    try std.testing.expectEqual(g.NO_ERROR, glGetError());
}
