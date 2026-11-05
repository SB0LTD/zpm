//! @zpm/gfxapi libgalaxy_gl — the root of libgalaxy-gl.so, Galaxy's GPU
//! driver for apps: EGL's entry points here and OpenGL ES's
//! (libgles.sig), under Khronos' names. Packaged as libEGL.so.1 and
//! libGLESv2.so.2, both links to this one file: the dynamic linker loads
//! a file once, whatever name finds it, so EGL and GL share their state.
//!
//! The driver behind EGL (egl.Driver): Galaxy's GPU through its render
//! node (node.Gpu over Linux, with this image's backend: ir3 on AArch64,
//! sm_120 on x86-64), the engine on it, the app's libwayland-client found
//! by name (dl.sig), and the process's side of things (host.Host): PRIME
//! out and in, sync_files (Galaxy's G_FENCE_FD), dup, poll, mmap. Opened at the
//! first eglInitialize; without a GPU EGL has no display and the app
//! draws in software.

const std = @import("std");
const builtin = @import("builtin");
const gfxapi = @import("gfxapi");
const gpu = @import("gpu");
const egl = gfxapi.egl;
const wayland = gfxapi.wayland;
const node = gfxapi.node;
const engine = gfxapi.engine;
const thread = gfxapi.thread;
const Host = gfxapi.host.Host;
const libgles = @import("libgles.sig");

pub const panic = libgles.panic;

comptime {
    // (libgles' gl* entry points are this library's too)
    _ = libgles;
}

// ── The driver ─────────────────────────────────────────────────────────────

const on_linux = builtin.os.tag == .linux;
const targets: []const gpu.Target = if (builtin.cpu.arch == .aarch64) &.{.ir3_a7xx} else &.{.sm_120};
const work_bytes = if (builtin.cpu.arch == .aarch64) gpu.kir_ir3.WORK_BYTES else gpu.nvidia_device.kir_sm120.WORK_BYTES;
const G = node.Gpu(node.Linux, targets);

/// (undefined until opened: its tables stay out of the file, in .bss)
var the_gpu: G = undefined;
var the_engine: engine.Engine = undefined;
var compile_work: [work_bytes]u8 align(64) = undefined;
var opened = false;
var refused = false;
var wl_client: ?wayland.Client = null;

fn openDriver() ?*engine.Engine {
    if (opened) return if (the_engine.lost) null else &the_engine;
    if (refused) return null;
    the_gpu = .{ .node = .{ .sys = .{} } };
    const d = the_gpu.open() catch {
        refused = true;
        return null;
    };
    the_engine.init(.{ .dev = d, .compiler = G.compile, .work = &compile_work });
    if (!the_engine.onGpu()) {
        // (the kernels did not load: no GPU drawing at all)
        refused = true;
        return null;
    }
    opened = true;
    return &the_engine;
}

const linux = std.os.linux;

fn sysResult(r: usize) i64 {
    return @as(isize, @bitCast(r));
}

fn exportFd(ctx: ?*anyopaque, buf: gpu.Buffer) i64 {
    _ = ctx;
    return the_gpu.exportFd(buf);
}

fn importFd(ctx: ?*anyopaque, fd: i32) ?gpu.Buffer {
    _ = ctx;
    if (!opened) return null;
    return the_gpu.importFd(fd);
}

fn fenceFd(ctx: ?*anyopaque) i64 {
    _ = ctx;
    if (!opened) return -19; // ENODEV
    return the_gpu.fenceFd();
}

fn closeFd(ctx: ?*anyopaque, fd: i32) void {
    _ = ctx;
    _ = linux.close(fd);
}

fn dupFd(ctx: ?*anyopaque, fd: i32) i32 {
    _ = ctx;
    return @intCast(sysResult(linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0)));
}

fn pollFd(ctx: ?*anyopaque, fd: i32, timeout_ms: i32) i32 {
    _ = ctx;
    var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const r = sysResult(linux.poll(&p, 1, timeout_ms));
        if (r == -4) continue; // EINTR
        if (r < 0) return @intCast(r);
        if (r == 0) return 0;
        // (a sync_file that errored is done, as Linux says: its status tells)
        return if (p[0].revents & (linux.POLL.IN | linux.POLL.ERR) != 0) 1 else -5;
    }
}

fn mapFd(ctx: ?*anyopaque, fd: i32, size: usize) ?[]const u8 {
    _ = ctx;
    if (size == 0) return null;
    const r = sysResult(linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0));
    if (r < 0) return null;
    return @as([*]const u8, @ptrFromInt(@as(usize, @intCast(r))))[0..size];
}

fn unmapFd(ctx: ?*anyopaque, s: []const u8) void {
    _ = ctx;
    _ = linux.munmap(s.ptr, s.len);
}

fn waylandClient() ?*const wayland.Client {
    if (wl_client == null) wl_client = wayland.Client.load();
    return if (wl_client) |*c| c else null;
}

/// What egl.sig takes as its driver (a test build sets its own).
pub const egl_driver: ?egl.Driver = if (on_linux) .{
    .open = openDriver,
    .host = .{ .exportFd = exportFd, .importFd = importFd, .fenceFd = fenceFd, .close = closeFd, .dup = dupFd, .poll = pollFd, .map = mapFd, .unmap = unmapFd },
    .wayland = waylandClient,
} else null;

// ── EGL's entry points ─────────────────────────────────────────────────────

fn h(p: anytype) ?*anyopaque {
    return @ptrCast(p);
}

fn b(x: bool) u32 {
    return @intFromBool(x);
}

pub export fn eglGetError() callconv(.c) i32 {
    return egl.getError();
}
pub export fn eglGetDisplay(native: ?*anyopaque) callconv(.c) ?*anyopaque {
    return h(egl.getDisplay(native));
}
pub export fn eglGetPlatformDisplay(platform: u32, native: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    _ = attribs;
    return h(egl.getPlatformDisplay(platform, native));
}
pub export fn eglGetPlatformDisplayEXT(platform: u32, native: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    _ = attribs;
    return h(egl.getPlatformDisplay(platform, native));
}
pub export fn eglInitialize(dpy: ?*anyopaque, major: ?*i32, minor: ?*i32) callconv(.c) u32 {
    return b(egl.initialize(dpy, major, minor));
}
pub export fn eglTerminate(dpy: ?*anyopaque) callconv(.c) u32 {
    return b(egl.terminate(dpy));
}
pub export fn eglQueryString(dpy: ?*anyopaque, name: i32) callconv(.c) ?[*:0]const u8 {
    return egl.queryString(dpy, name);
}
pub export fn eglGetConfigs(dpy: ?*anyopaque, configs: ?[*]?*const anyopaque, size: i32, num: ?*i32) callconv(.c) u32 {
    return b(egl.getConfigs(dpy, configs, size, num));
}
pub export fn eglChooseConfig(dpy: ?*anyopaque, attribs: ?[*]const i32, configs: ?[*]?*const anyopaque, size: i32, num: ?*i32) callconv(.c) u32 {
    return b(egl.chooseConfig(dpy, attribs, configs, size, num));
}
pub export fn eglGetConfigAttrib(dpy: ?*anyopaque, config: ?*const anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    return b(egl.getConfigAttrib(dpy, config, attribute, value));
}
pub export fn eglCreateWindowSurface(dpy: ?*anyopaque, config: ?*const anyopaque, win: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    return h(egl.createWindowSurface(i32, dpy, config, win, attribs));
}
pub export fn eglCreatePlatformWindowSurface(dpy: ?*anyopaque, config: ?*const anyopaque, win: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    return h(egl.createWindowSurface(isize, dpy, config, win, attribs));
}
pub export fn eglCreatePlatformWindowSurfaceEXT(dpy: ?*anyopaque, config: ?*const anyopaque, win: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    return h(egl.createWindowSurface(i32, dpy, config, win, attribs));
}
pub export fn eglCreatePbufferSurface(dpy: ?*anyopaque, config: ?*const anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    return h(egl.createPbufferSurface(dpy, config, attribs));
}
pub export fn eglCreatePixmapSurface(dpy: ?*anyopaque, config: ?*const anyopaque, pixmap: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    _ = .{ dpy, config, pixmap, attribs };
    egl.noSuch(egl.BAD_NATIVE_PIXMAP);
    return null;
}
pub export fn eglCreatePlatformPixmapSurface(dpy: ?*anyopaque, config: ?*const anyopaque, pixmap: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    _ = .{ dpy, config, pixmap, attribs };
    egl.noSuch(egl.BAD_NATIVE_PIXMAP);
    return null;
}
pub export fn eglCreatePbufferFromClientBuffer(dpy: ?*anyopaque, buftype: u32, buffer: ?*anyopaque, config: ?*const anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    _ = .{ dpy, buftype, buffer, config, attribs };
    egl.noSuch(egl.BAD_PARAMETER);
    return null;
}
pub export fn eglDestroySurface(dpy: ?*anyopaque, surface: ?*anyopaque) callconv(.c) u32 {
    return b(egl.destroySurface(dpy, surface));
}
pub export fn eglQuerySurface(dpy: ?*anyopaque, surface: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    return b(egl.querySurface(dpy, surface, attribute, value));
}
pub export fn eglSurfaceAttrib(dpy: ?*anyopaque, surface: ?*anyopaque, attribute: i32, value: i32) callconv(.c) u32 {
    return b(egl.surfaceAttrib(dpy, surface, attribute, value));
}
pub export fn eglBindTexImage(dpy: ?*anyopaque, surface: ?*anyopaque, buffer: i32) callconv(.c) u32 {
    _ = .{ dpy, surface, buffer };
    egl.noSuch(egl.BAD_MATCH);
    return 0;
}
pub export fn eglReleaseTexImage(dpy: ?*anyopaque, surface: ?*anyopaque, buffer: i32) callconv(.c) u32 {
    _ = .{ dpy, surface, buffer };
    egl.noSuch(egl.BAD_MATCH);
    return 0;
}
pub export fn eglSwapInterval(dpy: ?*anyopaque, interval: i32) callconv(.c) u32 {
    return b(egl.swapInterval(dpy, interval));
}
pub export fn eglBindAPI(api: u32) callconv(.c) u32 {
    return b(egl.bindApi(api));
}
pub export fn eglQueryAPI() callconv(.c) u32 {
    return egl.queryApi();
}
pub export fn eglWaitClient() callconv(.c) u32 {
    return b(egl.waitClient());
}
pub export fn eglWaitGL() callconv(.c) u32 {
    return b(egl.waitClient());
}
pub export fn eglWaitNative(engine_id: i32) callconv(.c) u32 {
    _ = engine_id;
    return 1;
}
pub export fn eglReleaseThread() callconv(.c) u32 {
    return b(egl.releaseThread());
}
pub export fn eglCreateContext(dpy: ?*anyopaque, config: ?*const anyopaque, share: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    return h(egl.createContext(dpy, config, share, attribs));
}
pub export fn eglDestroyContext(dpy: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) u32 {
    return b(egl.destroyContext(dpy, ctx));
}
pub export fn eglMakeCurrent(dpy: ?*anyopaque, draw: ?*anyopaque, read: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) u32 {
    return b(egl.makeCurrent(dpy, draw, read, ctx));
}
pub export fn eglGetCurrentContext() callconv(.c) ?*anyopaque {
    return egl.getCurrentContext();
}
pub export fn eglGetCurrentSurface(readdraw: i32) callconv(.c) ?*anyopaque {
    return egl.getCurrentSurface(readdraw);
}
pub export fn eglGetCurrentDisplay() callconv(.c) ?*anyopaque {
    return egl.getCurrentDisplay();
}
pub export fn eglQueryContext(dpy: ?*anyopaque, ctx: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    return b(egl.queryContext(dpy, ctx, attribute, value));
}
pub export fn eglSwapBuffers(dpy: ?*anyopaque, surface: ?*anyopaque) callconv(.c) u32 {
    return b(egl.swapBuffers(dpy, surface, &.{}));
}
pub export fn eglSwapBuffersWithDamageKHR(dpy: ?*anyopaque, surface: ?*anyopaque, rects: ?[*]const i32, n: i32) callconv(.c) u32 {
    if (n < 0) {
        egl.noSuch(egl.BAD_PARAMETER);
        return 0;
    }
    const list: []const [4]i32 = if (rects) |r| @as([*]const [4]i32, @ptrCast(r))[0..@intCast(n)] else &.{};
    return b(egl.swapBuffers(dpy, surface, list));
}
pub export fn eglSwapBuffersWithDamageEXT(dpy: ?*anyopaque, surface: ?*anyopaque, rects: ?[*]const i32, n: i32) callconv(.c) u32 {
    return eglSwapBuffersWithDamageKHR(dpy, surface, rects, n);
}
pub export fn eglCopyBuffers(dpy: ?*anyopaque, surface: ?*anyopaque, target: ?*anyopaque) callconv(.c) u32 {
    _ = .{ dpy, surface, target };
    egl.noSuch(egl.BAD_NATIVE_PIXMAP);
    return 0;
}
pub export fn eglCreateSync(dpy: ?*anyopaque, ty: u32, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    return h(egl.createSync(isize, dpy, ty, attribs));
}
pub export fn eglCreateSyncKHR(dpy: ?*anyopaque, ty: u32, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    return h(egl.createSync(i32, dpy, ty, attribs));
}
pub export fn eglDestroySync(dpy: ?*anyopaque, sync: ?*anyopaque) callconv(.c) u32 {
    return b(egl.destroySync(dpy, sync));
}
pub export fn eglDestroySyncKHR(dpy: ?*anyopaque, sync: ?*anyopaque) callconv(.c) u32 {
    return b(egl.destroySync(dpy, sync));
}
pub export fn eglClientWaitSync(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32, timeout: u64) callconv(.c) i32 {
    return egl.clientWaitSync(dpy, sync, flags, timeout);
}
pub export fn eglClientWaitSyncKHR(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32, timeout: u64) callconv(.c) i32 {
    return egl.clientWaitSync(dpy, sync, flags, timeout);
}
pub export fn eglWaitSync(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32) callconv(.c) u32 {
    return b(egl.waitSync(dpy, sync, flags));
}
pub export fn eglWaitSyncKHR(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32) callconv(.c) i32 {
    return @intCast(b(egl.waitSync(dpy, sync, flags)));
}
pub export fn eglGetSyncAttrib(dpy: ?*anyopaque, sync: ?*anyopaque, attribute: i32, value: ?*isize) callconv(.c) u32 {
    const v = egl.getSyncAttrib(dpy, sync, attribute) orelse return 0;
    if (value) |p| p.* = v;
    return 1;
}
pub export fn eglGetSyncAttribKHR(dpy: ?*anyopaque, sync: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    const v = egl.getSyncAttrib(dpy, sync, attribute) orelse return 0;
    if (value) |p| p.* = v;
    return 1;
}
pub export fn eglCreateImage(dpy: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    return h(egl.createImage(isize, dpy, ctx, target, buffer, attribs));
}
pub export fn eglCreateImageKHR(dpy: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    return h(egl.createImage(i32, dpy, ctx, target, buffer, attribs));
}
pub export fn eglDestroyImage(dpy: ?*anyopaque, image: ?*anyopaque) callconv(.c) u32 {
    return b(egl.destroyImage(dpy, image));
}
pub export fn eglDestroyImageKHR(dpy: ?*anyopaque, image: ?*anyopaque) callconv(.c) u32 {
    return b(egl.destroyImage(dpy, image));
}
pub export fn eglQueryDmaBufFormatsEXT(dpy: ?*anyopaque, max: i32, formats: ?[*]i32, num: ?*i32) callconv(.c) u32 {
    return b(egl.queryDmaBufFormats(dpy, max, formats, num));
}
pub export fn eglQueryDmaBufModifiersEXT(dpy: ?*anyopaque, format: i32, max: i32, modifiers: ?[*]u64, external_only: ?[*]u32, num: ?*i32) callconv(.c) u32 {
    return b(egl.queryDmaBufModifiers(dpy, format, max, modifiers, external_only, num));
}
pub export fn eglDupNativeFenceFDANDROID(dpy: ?*anyopaque, sync: ?*anyopaque) callconv(.c) i32 {
    return egl.dupNativeFenceFd(dpy, sync);
}
pub export fn eglGetProcAddress(name: ?[*:0]const u8) callconv(.c) ?*const anyopaque {
    const n = name orelse return null;
    const s = std.mem.span(n);
    for (entries) |e| {
        if (std.mem.eql(u8, s, e.name)) return e.ptr;
    }
    return libgles.getProcAddress(n);
}

const Entry = struct { name: []const u8, ptr: *const anyopaque };

/// Every egl* entry point above, by name.
const entries = blk: {
    @setEvalBranchQuota(100_000);
    const decls = @typeInfo(@This()).@"struct".decl_names;
    var list: [decls.len]Entry = undefined;
    var n: usize = 0;
    for (decls) |d| {
        if (d.len > 3 and std.mem.startsWith(u8, d, "egl") and std.ascii.isUpper(d[3])) {
            list[n] = .{ .name = d, .ptr = @ptrCast(&@field(@This(), d)) };
            n += 1;
        }
    }
    const final: [n]Entry = list[0..n].*;
    break :blk final;
};

// ── Tests (EGL through its C entry points, on the CPU's engine) ───────────

var t_pool: [1 << 20]u8 align(64) = undefined;
var t_eng: engine.Engine = undefined;

fn testOpen() ?*engine.Engine {
    return &t_eng;
}
fn testExport(ctx: ?*anyopaque, buf: gpu.Buffer) i64 {
    _ = ctx;
    _ = buf;
    return -1;
}
fn testImport(ctx: ?*anyopaque, fd: i32) ?gpu.Buffer {
    _ = ctx;
    _ = fd;
    return null;
}
fn testFence(ctx: ?*anyopaque) i64 {
    _ = ctx;
    return 42;
}
fn testClose(ctx: ?*anyopaque, fd: i32) void {
    _ = ctx;
    _ = fd;
}
fn testDup(ctx: ?*anyopaque, fd: i32) i32 {
    _ = ctx;
    return fd + 1;
}
fn testPoll(ctx: ?*anyopaque, fd: i32, ms: i32) i32 {
    _ = .{ ctx, fd, ms };
    return 1;
}
fn testMap(ctx: ?*anyopaque, fd: i32, size: usize) ?[]const u8 {
    _ = .{ ctx, fd, size };
    return null;
}
fn testUnmap(ctx: ?*anyopaque, s: []const u8) void {
    _ = .{ ctx, s };
}
const test_host = Host{ .exportFd = testExport, .importFd = testImport, .fenceFd = testFence, .close = testClose, .dup = testDup, .poll = testPoll, .map = testMap, .unmap = testUnmap };
fn noWayland() ?*const wayland.Client {
    return null;
}

test "libgalaxy_gl: EGL and GL through their C entry points (surfaceless, a pbuffer)" {
    t_eng.init(.{ .pool = &t_pool });
    egl.setDriver(.{ .open = testOpen, .host = test_host, .wayland = noWayland });
    const dpy = eglGetDisplay(null);
    try std.testing.expect(dpy != null);
    var major: i32 = 0;
    var minor: i32 = 0;
    try std.testing.expectEqual(@as(u32, 1), eglInitialize(dpy, &major, &minor));
    try std.testing.expectEqual([2]i32{ 1, 5 }, .{ major, minor });
    const attribs = [_]i32{ egl.RENDERABLE_TYPE, egl.OPENGL_ES3_BIT, egl.SURFACE_TYPE, egl.PBUFFER_BIT, egl.ALPHA_SIZE, 8, egl.NONE };
    var cfg: [4]?*const anyopaque = undefined;
    var n: i32 = 0;
    try std.testing.expectEqual(@as(u32, 1), eglChooseConfig(dpy, &attribs, &cfg, 4, &n));
    try std.testing.expectEqual(@as(i32, 2), n);
    var id: i32 = 0;
    _ = eglGetConfigAttrib(dpy, cfg[0], egl.CONFIG_ID, &id);
    try std.testing.expectEqual(@as(i32, 2), id); // (no depth: the smaller first)
    const ctx_attribs = [_]i32{ egl.CONTEXT_CLIENT_VERSION, 3, egl.NONE };
    const ctx = eglCreateContext(dpy, cfg[0], null, &ctx_attribs);
    try std.testing.expect(ctx != null);
    const pb_attribs = [_]i32{ egl.WIDTH, 8, egl.HEIGHT, 4, egl.NONE };
    const pb = eglCreatePbufferSurface(dpy, cfg[0], &pb_attribs);
    try std.testing.expect(pb != null);
    try std.testing.expectEqual(@as(u32, 1), eglMakeCurrent(dpy, pb, pb, ctx));
    try std.testing.expectEqual(ctx, eglGetCurrentContext());
    const clearColor: *const fn (f32, f32, f32, f32) callconv(.c) void = @ptrCast(eglGetProcAddress("glClearColor").?);
    const clear: *const fn (u32) callconv(.c) void = @ptrCast(eglGetProcAddress("glClear").?);
    clearColor(0, 0, 1, 1);
    clear(gfxapi.glenum.COLOR_BUFFER_BIT);
    var px: [4]u8 = undefined;
    libgles.glReadPixels(7, 3, 1, 1, gfxapi.glenum.RGBA, gfxapi.glenum.UNSIGNED_BYTE, &px);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &px);
    // a fence, done at once on the CPU
    const sync = eglCreateSyncKHR(dpy, egl.SYNC_FENCE, null);
    try std.testing.expect(sync != null);
    try std.testing.expectEqual(egl.CONDITION_SATISFIED, eglClientWaitSyncKHR(dpy, sync, egl.SYNC_FLUSH_COMMANDS_BIT, egl.FOREVER));
    try std.testing.expectEqual(@as(u32, 1), eglDestroySyncKHR(dpy, sync));
    // a native fence of the work so far: Galaxy's sync_file (the host's 42)
    const native = eglCreateSyncKHR(dpy, egl.SYNC_NATIVE_FENCE_ANDROID, null);
    try std.testing.expectEqual(@as(i32, 42), eglDupNativeFenceFDANDROID(dpy, native));
    try std.testing.expectEqual(@as(u32, 1), eglDestroySyncKHR(dpy, native));
    var nf: i32 = 0;
    try std.testing.expectEqual(@as(u32, 1), eglQueryDmaBufFormatsEXT(dpy, 0, null, &nf));
    try std.testing.expectEqual(@as(i32, 4), nf);
    try std.testing.expectEqual(@as(u32, 1), eglSwapBuffers(dpy, pb)); // (a pbuffer's: nothing)
    try std.testing.expectEqual(@as(u32, 1), eglMakeCurrent(dpy, null, null, null));
    try std.testing.expect(eglGetCurrentContext() == null);
    try std.testing.expectEqual(@as(u32, 1), eglDestroySurface(dpy, pb));
    try std.testing.expectEqual(@as(u32, 1), eglDestroyContext(dpy, ctx));
    try std.testing.expectEqual(@as(u32, 1), eglTerminate(dpy));
    try std.testing.expectEqual(@as(usize, 0), t_eng.pool.n);
    // errors: a display that is not one, ES 1, an attribute EGL lacks
    try std.testing.expectEqual(@as(u32, 0), eglInitialize(@ptrFromInt(0x1000), null, null));
    try std.testing.expectEqual(egl.BAD_DISPLAY, eglGetError());
    try std.testing.expectEqual(egl.SUCCESS, eglGetError());
    try std.testing.expect(eglGetProcAddress("eglSwapBuffersWithDamageKHR") != null);
    try std.testing.expect(eglGetProcAddress("eglNoSuchCall") == null);
    try std.testing.expect(entries.len >= 50);
}
