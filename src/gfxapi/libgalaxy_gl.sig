//! @zpm/gfxapi libgalaxy_gl — the root of libgalaxy-gl.so, Galaxy's GPU
//! driver for apps: EGL's entry points here and OpenGL ES's
//! (libgles.sig), under Khronos' names. Packaged as libEGL.so.1 and
//! libGLESv2.so.2, both links to this one file: the dynamic linker loads
//! a file once, whatever name finds it, so EGL and GL share their state.
//! Also packaged as libGL.so.1, libGLESv1_CM.so.1 and libgbm.so.1: every
//! other name Mesa's libraries export is answered here too (abi.sig), so
//! a program linked against Mesa loads against this file.
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
const report = gfxapi.report;
const Host = gfxapi.host.Host;
const libgles = @import("libgles.sig");
const abi = @import("abi.sig");

pub const panic = libgles.panic;

comptime {
    // (libgles' gl* entry points are this library's too)
    _ = libgles;
    // ...and every other name of Mesa's: what abi.sig answers itself, and
    // for the rest a call that does nothing (abi.Missing)
    _ = abi;
    @setEvalBranchQuota(1_000_000);
    for (abi.names) |name| {
        if (@hasDecl(@This(), name) or @hasDecl(libgles, name) or abi.answers(name)) continue;
        @export(&abi.Missing(name).call, .{ .name = name });
    }
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
/// KIR's interpreter's scratch, for what the CPU draws: a lost GPU, a
/// program the GPU does not take, a check (in .bss: no page is used until
/// touched).
var cpu_work: [16 << 20]u8 align(64) = undefined;
/// Images' memory when the GPU gives none (it is lost), and a check's
/// scratch: address space reserved at open, each page filled on first
/// touch.
const POOL_BYTES: usize = 512 << 20;
const CHECK_BYTES: usize = 64 << 20;
var opened = false;
var refused = false;
var wl_client: ?wayland.Client = null;
var driver_slabs: [16]engine.Slab = undefined;

fn openDriver() ?*engine.Engine {
    if (opened) return if (the_engine.lost) null else &the_engine;
    if (refused) return null;
    the_gpu = .{ .node = .{ .sys = .{} } };
    const d = the_gpu.open() catch |err| {
        report.say(.device, "no GPU ({s}): EGL has no display, and the app draws in software", .{@errorName(err)});
        refused = true;
        return null;
    };
    const check_px = checkAsked();
    the_engine.init(.{
        .dev = d,
        .compiler = G.compile,
        .work = &compile_work,
        .pool = anonymous(POOL_BYTES),
        .slabs = &driver_slabs,
        .cpu_work = &cpu_work,
        .check = if (check_px) |px| .{ .mem = anonymous(CHECK_BYTES), .max_px = px } else .{},
    });
    if (!the_engine.onGpu()) {
        // (the kernels did not load: no GPU drawing at all)
        report.say(.device, "the GPU's kernels did not load ({s}): EGL has no display, and the app draws in software", .{if (the_engine.why) |w| @errorName(w) else "?"});
        refused = true;
        return null;
    }
    opened = true;
    if (the_engine.check.mem.len != 0) {
        report.say(.device, "drawing on {s}; each kernel's first runs of up to {d} pixels checked against the CPU (GALAXY_GL_CHECK)", .{ d.caps.name, the_engine.check.max_px });
    } else report.say(.device, "drawing on {s}", .{d.caps.name});
    return &the_engine;
}

/// Read-write memory of `len` bytes, reserved (MAP_NORESERVE: each page
/// filled on first touch), or none.
fn anonymous(len: usize) []u8 {
    if (comptime !on_linux) return &.{};
    const r = sysResult(linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0));
    if (r < 0) return &.{};
    return @as([*]u8, @ptrFromInt(@as(usize, @intCast(r))))[0..len];
}

var env_buf: [64 * 1024]u8 = undefined;

/// GALAXY_GL_CHECK, from the process's environment (/proc/self/environ:
/// no C library to ask): "1" or "on", each kernel's first runs of up to
/// 128 x 128 pixels checked against the CPU; a larger number, that many
/// pixels; "0", "off" or none, no check.
fn checkAsked() ?u32 {
    if (comptime !on_linux) return null;
    const fd = sysResult(linux.openat(linux.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    var n: usize = 0;
    while (n < env_buf.len) {
        const r = sysResult(linux.read(@intCast(fd), env_buf[n..].ptr, env_buf.len - n));
        if (r <= 0) break;
        n += @intCast(r);
    }
    return checkOf(env_buf[0..n]);
}

/// GALAXY_GL_CHECK's pixels in an environment block (NUL-separated).
fn checkOf(block: []const u8) ?u32 {
    const key = "GALAXY_GL_CHECK=";
    var it = std.mem.splitScalar(u8, block, 0);
    while (it.next()) |kv| {
        if (!std.mem.startsWith(u8, kv, key)) continue;
        const v = std.mem.trim(u8, kv[key.len..], " ");
        if (v.len == 0 or std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return null;
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "on")) return 128 * 128;
        return std.fmt.parseInt(u32, v, 10) catch 128 * 128;
    }
    return null;
}

test "libgalaxy-gl: GALAXY_GL_CHECK from an environment block" {
    try std.testing.expectEqual(@as(?u32, null), checkOf("HOME=/home/galaxy\x00PATH=/bin\x00"));
    try std.testing.expectEqual(@as(?u32, 128 * 128), checkOf("A=1\x00GALAXY_GL_CHECK=1\x00B=2"));
    try std.testing.expectEqual(@as(?u32, 4096), checkOf("GALAXY_GL_CHECK=4096"));
    try std.testing.expectEqual(@as(?u32, null), checkOf("GALAXY_GL_CHECK=0\x00"));
    try std.testing.expectEqual(@as(?u32, null), checkOf("GALAXY_GL_CHECK=off"));
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

fn nativeInterop() bool {
    return the_gpu.node.kind == .adreno;
}
fn dmaImport() bool {
    return the_gpu.node.dma_import;
}

/// What egl.sig takes as its driver (a test build sets its own).
pub const egl_driver: ?egl.Driver = if (on_linux) .{
    .open = openDriver,
    .host = .{ .exportFd = exportFd, .importFd = importFd, .fenceFd = fenceFd, .close = closeFd, .dup = dupFd, .poll = pollFd, .map = mapFd, .unmap = unmapFd },
    .wayland = waylandClient,
    .native_interop = nativeInterop,
    .dma_import = dmaImport,
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
    egl.calling("eglGetDisplay");
    return h(egl.getDisplay(native));
}
pub export fn eglGetPlatformDisplay(platform: u32, native: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    egl.calling("eglGetPlatformDisplay");
    _ = attribs;
    return h(egl.getPlatformDisplay(platform, native));
}
pub export fn eglGetPlatformDisplayEXT(platform: u32, native: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglGetPlatformDisplayEXT");
    _ = attribs;
    return h(egl.getPlatformDisplay(platform, native));
}
pub export fn eglInitialize(dpy: ?*anyopaque, major: ?*i32, minor: ?*i32) callconv(.c) u32 {
    egl.calling("eglInitialize");
    return b(egl.initialize(dpy, major, minor));
}
pub export fn eglTerminate(dpy: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglTerminate");
    return b(egl.terminate(dpy));
}
pub export fn eglQueryString(dpy: ?*anyopaque, name: i32) callconv(.c) ?[*:0]const u8 {
    egl.calling("eglQueryString");
    return egl.queryString(dpy, name);
}
pub export fn eglGetConfigs(dpy: ?*anyopaque, configs: ?[*]?*const anyopaque, size: i32, num: ?*i32) callconv(.c) u32 {
    egl.calling("eglGetConfigs");
    return b(egl.getConfigs(dpy, configs, size, num));
}
pub export fn eglChooseConfig(dpy: ?*anyopaque, attribs: ?[*]const i32, configs: ?[*]?*const anyopaque, size: i32, num: ?*i32) callconv(.c) u32 {
    egl.calling("eglChooseConfig");
    return b(egl.chooseConfig(dpy, attribs, configs, size, num));
}
pub export fn eglGetConfigAttrib(dpy: ?*anyopaque, config: ?*const anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    egl.calling("eglGetConfigAttrib");
    return b(egl.getConfigAttrib(dpy, config, attribute, value));
}
pub export fn eglCreateWindowSurface(dpy: ?*anyopaque, config: ?*const anyopaque, win: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateWindowSurface");
    return h(egl.createWindowSurface(i32, dpy, config, win, attribs));
}
pub export fn eglCreatePlatformWindowSurface(dpy: ?*anyopaque, config: ?*const anyopaque, win: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    egl.calling("eglCreatePlatformWindowSurface");
    return h(egl.createWindowSurface(isize, dpy, config, win, attribs));
}
pub export fn eglCreatePlatformWindowSurfaceEXT(dpy: ?*anyopaque, config: ?*const anyopaque, win: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreatePlatformWindowSurfaceEXT");
    return h(egl.createWindowSurface(i32, dpy, config, win, attribs));
}
pub export fn eglCreatePbufferSurface(dpy: ?*anyopaque, config: ?*const anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreatePbufferSurface");
    return h(egl.createPbufferSurface(dpy, config, attribs));
}
pub export fn eglCreatePixmapSurface(dpy: ?*anyopaque, config: ?*const anyopaque, pixmap: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreatePixmapSurface");
    _ = .{ dpy, config, pixmap, attribs };
    egl.noSuch(egl.BAD_NATIVE_PIXMAP);
    return null;
}
pub export fn eglCreatePlatformPixmapSurface(dpy: ?*anyopaque, config: ?*const anyopaque, pixmap: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    egl.calling("eglCreatePlatformPixmapSurface");
    _ = .{ dpy, config, pixmap, attribs };
    egl.noSuch(egl.BAD_NATIVE_PIXMAP);
    return null;
}
pub export fn eglCreatePbufferFromClientBuffer(dpy: ?*anyopaque, buftype: u32, buffer: ?*anyopaque, config: ?*const anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreatePbufferFromClientBuffer");
    _ = .{ dpy, buftype, buffer, config, attribs };
    egl.noSuch(egl.BAD_PARAMETER);
    return null;
}
pub export fn eglDestroySurface(dpy: ?*anyopaque, surface: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroySurface");
    return b(egl.destroySurface(dpy, surface));
}
pub export fn eglQuerySurface(dpy: ?*anyopaque, surface: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    egl.calling("eglQuerySurface");
    return b(egl.querySurface(dpy, surface, attribute, value));
}
pub export fn eglQuerySurfacePointerANGLE(dpy: ?*anyopaque, surface: ?*anyopaque, attribute: i32, value: ?*?*anyopaque) callconv(.c) u32 {
    egl.calling("eglQuerySurfacePointerANGLE");
    return b(egl.querySurfacePointer(dpy, surface, attribute, value));
}

pub export fn eglGetNativeClientBufferANDROID(buffer: ?*const anyopaque) callconv(.c) ?*anyopaque {
    egl.calling("eglGetNativeClientBufferANDROID");
    return egl.androidClientBuffer(buffer);
}
pub export fn eglSurfaceAttrib(dpy: ?*anyopaque, surface: ?*anyopaque, attribute: i32, value: i32) callconv(.c) u32 {
    egl.calling("eglSurfaceAttrib");
    return b(egl.surfaceAttrib(dpy, surface, attribute, value));
}
pub export fn eglBindTexImage(dpy: ?*anyopaque, surface: ?*anyopaque, buffer: i32) callconv(.c) u32 {
    egl.calling("eglBindTexImage");
    _ = .{ dpy, surface, buffer };
    egl.noSuch(egl.BAD_MATCH);
    return 0;
}
pub export fn eglReleaseTexImage(dpy: ?*anyopaque, surface: ?*anyopaque, buffer: i32) callconv(.c) u32 {
    egl.calling("eglReleaseTexImage");
    _ = .{ dpy, surface, buffer };
    egl.noSuch(egl.BAD_MATCH);
    return 0;
}
pub export fn eglSwapInterval(dpy: ?*anyopaque, interval: i32) callconv(.c) u32 {
    egl.calling("eglSwapInterval");
    return b(egl.swapInterval(dpy, interval));
}
pub export fn eglBindAPI(api: u32) callconv(.c) u32 {
    egl.calling("eglBindAPI");
    return b(egl.bindApi(api));
}
pub export fn eglQueryAPI() callconv(.c) u32 {
    egl.calling("eglQueryAPI");
    return egl.queryApi();
}
pub export fn eglWaitClient() callconv(.c) u32 {
    egl.calling("eglWaitClient");
    return b(egl.waitClient());
}
pub export fn eglWaitGL() callconv(.c) u32 {
    egl.calling("eglWaitGL");
    return b(egl.waitClient());
}
pub export fn eglWaitNative(engine_id: i32) callconv(.c) u32 {
    egl.calling("eglWaitNative");
    _ = engine_id;
    return 1;
}
pub export fn eglReleaseThread() callconv(.c) u32 {
    egl.calling("eglReleaseThread");
    return b(egl.releaseThread());
}
pub export fn eglCreateContext(dpy: ?*anyopaque, config: ?*const anyopaque, share: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateContext");
    return h(egl.createContext(dpy, config, share, attribs));
}
pub export fn eglDestroyContext(dpy: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroyContext");
    return b(egl.destroyContext(dpy, ctx));
}
pub export fn eglMakeCurrent(dpy: ?*anyopaque, draw: ?*anyopaque, read: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglMakeCurrent");
    return b(egl.makeCurrent(dpy, draw, read, ctx));
}
pub export fn eglGetCurrentContext() callconv(.c) ?*anyopaque {
    egl.calling("eglGetCurrentContext");
    return egl.getCurrentContext();
}
pub export fn eglGetCurrentSurface(readdraw: i32) callconv(.c) ?*anyopaque {
    egl.calling("eglGetCurrentSurface");
    return egl.getCurrentSurface(readdraw);
}
pub export fn eglGetCurrentDisplay() callconv(.c) ?*anyopaque {
    egl.calling("eglGetCurrentDisplay");
    return egl.getCurrentDisplay();
}
pub export fn eglQueryContext(dpy: ?*anyopaque, ctx: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    egl.calling("eglQueryContext");
    return b(egl.queryContext(dpy, ctx, attribute, value));
}
pub export fn eglSwapBuffers(dpy: ?*anyopaque, surface: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglSwapBuffers");
    return b(egl.swapBuffers(dpy, surface, &.{}));
}
pub export fn eglSetDamageRegionKHR(dpy: ?*anyopaque, surface: ?*anyopaque, rects: ?[*]const i32, n: i32) callconv(.c) u32 {
    egl.calling("eglSetDamageRegionKHR");
    return b(egl.setDamageRegion(dpy, surface, rects, n));
}

pub export fn eglSwapBuffersWithDamageKHR(dpy: ?*anyopaque, surface: ?*anyopaque, rects: ?[*]const i32, n: i32) callconv(.c) u32 {
    egl.calling("eglSwapBuffersWithDamageKHR");
    if (n < 0) {
        egl.noSuch(egl.BAD_PARAMETER);
        return 0;
    }
    const list: []const [4]i32 = if (rects) |r| @as([*]const [4]i32, @ptrCast(r))[0..@intCast(n)] else &.{};
    return b(egl.swapBuffers(dpy, surface, list));
}
pub export fn eglSwapBuffersWithDamageEXT(dpy: ?*anyopaque, surface: ?*anyopaque, rects: ?[*]const i32, n: i32) callconv(.c) u32 {
    egl.calling("eglSwapBuffersWithDamageEXT");
    return eglSwapBuffersWithDamageKHR(dpy, surface, rects, n);
}
pub export fn eglCopyBuffers(dpy: ?*anyopaque, surface: ?*anyopaque, target: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglCopyBuffers");
    _ = .{ dpy, surface, target };
    egl.noSuch(egl.BAD_NATIVE_PIXMAP);
    return 0;
}
pub export fn eglCreateSync(dpy: ?*anyopaque, ty: u32, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateSync");
    return h(egl.createSync(isize, dpy, ty, attribs));
}
pub export fn eglCreateSyncKHR(dpy: ?*anyopaque, ty: u32, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateSyncKHR");
    return h(egl.createSync(i32, dpy, ty, attribs));
}
pub export fn eglDestroySync(dpy: ?*anyopaque, sync: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroySync");
    return b(egl.destroySync(dpy, sync));
}
pub export fn eglDestroySyncKHR(dpy: ?*anyopaque, sync: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroySyncKHR");
    return b(egl.destroySync(dpy, sync));
}
pub export fn eglClientWaitSync(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32, timeout: u64) callconv(.c) i32 {
    egl.calling("eglClientWaitSync");
    return egl.clientWaitSync(dpy, sync, flags, timeout);
}
pub export fn eglClientWaitSyncKHR(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32, timeout: u64) callconv(.c) i32 {
    egl.calling("eglClientWaitSyncKHR");
    return egl.clientWaitSync(dpy, sync, flags, timeout);
}
pub export fn eglWaitSync(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32) callconv(.c) u32 {
    egl.calling("eglWaitSync");
    return b(egl.waitSync(dpy, sync, flags));
}
pub export fn eglWaitSyncKHR(dpy: ?*anyopaque, sync: ?*anyopaque, flags: i32) callconv(.c) i32 {
    egl.calling("eglWaitSyncKHR");
    return @intCast(b(egl.waitSync(dpy, sync, flags)));
}
pub export fn eglGetSyncAttrib(dpy: ?*anyopaque, sync: ?*anyopaque, attribute: i32, value: ?*isize) callconv(.c) u32 {
    egl.calling("eglGetSyncAttrib");
    const v = egl.getSyncAttrib(dpy, sync, attribute) orelse return 0;
    if (value) |p| p.* = v;
    return 1;
}
pub export fn eglGetSyncAttribKHR(dpy: ?*anyopaque, sync: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    egl.calling("eglGetSyncAttribKHR");
    const v = egl.getSyncAttrib(dpy, sync, attribute) orelse return 0;
    if (value) |p| p.* = v;
    return 1;
}
pub export fn eglCreateImage(dpy: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateImage");
    return h(egl.createImage(isize, dpy, ctx, target, buffer, attribs));
}
pub export fn eglCreateImageKHR(dpy: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateImageKHR");
    return h(egl.createImage(i32, dpy, ctx, target, buffer, attribs));
}
pub export fn eglDestroyImage(dpy: ?*anyopaque, image: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroyImage");
    return b(egl.destroyImage(dpy, image));
}
pub export fn eglDestroyImageKHR(dpy: ?*anyopaque, image: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroyImageKHR");
    return b(egl.destroyImage(dpy, image));
}
pub export fn eglExportDMABUFImageQueryMESA(dpy: ?*anyopaque, image: ?*anyopaque, fourcc: ?*i32, planes: ?*i32, modifiers: ?*u64) callconv(.c) u32 {
    egl.calling("eglExportDMABUFImageQueryMESA");
    return b(egl.exportDmaBufQuery(dpy, image, fourcc, planes, modifiers));
}

pub export fn eglExportDMABUFImageMESA(dpy: ?*anyopaque, image: ?*anyopaque, fds: ?*i32, strides: ?*i32, offsets: ?*i32) callconv(.c) u32 {
    egl.calling("eglExportDMABUFImageMESA");
    return b(egl.exportDmaBuf(dpy, image, fds, strides, offsets));
}

pub export fn eglQueryDmaBufFormatsEXT(dpy: ?*anyopaque, max: i32, formats: ?[*]i32, num: ?*i32) callconv(.c) u32 {
    egl.calling("eglQueryDmaBufFormatsEXT");
    return b(egl.queryDmaBufFormats(dpy, max, formats, num));
}
pub export fn eglQueryDmaBufModifiersEXT(dpy: ?*anyopaque, format: i32, max: i32, modifiers: ?[*]u64, external_only: ?[*]u32, num: ?*i32) callconv(.c) u32 {
    egl.calling("eglQueryDmaBufModifiersEXT");
    return b(egl.queryDmaBufModifiers(dpy, format, max, modifiers, external_only, num));
}
pub export fn eglDupNativeFenceFDANDROID(dpy: ?*anyopaque, sync: ?*anyopaque) callconv(.c) i32 {
    egl.calling("eglDupNativeFenceFDANDROID");
    return egl.dupNativeFenceFd(dpy, sync);
}
pub export fn eglQueryDevicesEXT(max: i32, devices: ?[*]?*anyopaque, num: ?*i32) callconv(.c) u32 {
    egl.calling("eglQueryDevicesEXT");
    return b(egl.queryDevices(max, devices, num));
}
pub export fn eglQueryDeviceStringEXT(dev: ?*anyopaque, name: i32) callconv(.c) ?[*:0]const u8 {
    egl.calling("eglQueryDeviceStringEXT");
    return egl.queryDeviceString(dev, name);
}
pub export fn eglQueryDeviceAttribEXT(dev: ?*anyopaque, attribute: i32, value: ?*isize) callconv(.c) u32 {
    egl.calling("eglQueryDeviceAttribEXT");
    return b(egl.queryDeviceAttrib(dev, attribute, value));
}
pub export fn eglQueryDisplayAttribEXT(dpy: ?*anyopaque, attribute: i32, value: ?*isize) callconv(.c) u32 {
    egl.calling("eglQueryDisplayAttribEXT");
    return b(egl.queryDisplayAttrib(dpy, attribute, value));
}
pub export fn eglQueryDisplayAttribKHR(dpy: ?*anyopaque, attribute: i32, value: ?*isize) callconv(.c) u32 {
    egl.calling("eglQueryDisplayAttribKHR");
    return b(egl.queryDisplayAttrib(dpy, attribute, value));
}
pub export fn eglCreateStreamKHR(dpy: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateStreamKHR");
    return h(egl.createStream(dpy, attribs));
}
pub export fn eglDestroyStreamKHR(dpy: ?*anyopaque, stream: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglDestroyStreamKHR");
    return b(egl.destroyStream(dpy, stream));
}
pub export fn eglStreamAttribKHR(dpy: ?*anyopaque, stream: ?*anyopaque, attribute: i32, value: i32) callconv(.c) u32 {
    egl.calling("eglStreamAttribKHR");
    return b(egl.setStreamAttrib(dpy, stream, attribute, value));
}
pub export fn eglQueryStreamKHR(dpy: ?*anyopaque, stream: ?*anyopaque, attribute: i32, value: ?*i32) callconv(.c) u32 {
    egl.calling("eglQueryStreamKHR");
    return b(egl.queryStream(dpy, stream, attribute, value));
}
pub export fn eglQueryStreamu64KHR(dpy: ?*anyopaque, stream: ?*anyopaque, attribute: u32, value: ?*u64) callconv(.c) u32 {
    egl.calling("eglQueryStreamu64KHR");
    return b(egl.queryStreamU64(dpy, stream, attribute, value));
}
pub export fn eglCreateStreamProducerSurfaceKHR(dpy: ?*anyopaque, config: ?*const anyopaque, stream: ?*anyopaque, attribs: ?[*]const i32) callconv(.c) ?*anyopaque {
    egl.calling("eglCreateStreamProducerSurfaceKHR");
    return h(egl.createStreamProducerSurface(dpy, config, stream, attribs));
}
pub export fn eglStreamConsumerGLTextureExternalKHR(dpy: ?*anyopaque, stream: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglStreamConsumerGLTextureExternalKHR");
    return b(egl.connectStreamTexture(dpy, stream));
}
pub export fn eglStreamConsumerAcquireKHR(dpy: ?*anyopaque, stream: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglStreamConsumerAcquireKHR");
    return b(egl.consumeStream(dpy, stream, true));
}
pub export fn eglStreamConsumerReleaseKHR(dpy: ?*anyopaque, stream: ?*anyopaque) callconv(.c) u32 {
    egl.calling("eglStreamConsumerReleaseKHR");
    return b(egl.consumeStream(dpy, stream, false));
}
pub export fn eglGetProcAddress(name: ?[*:0]const u8) callconv(.c) ?*const anyopaque {
    const n = name orelse return null;
    const s = std.mem.span(n);
    for (entries) |e| {
        if (std.mem.eql(u8, s, e.name)) return e.ptr;
    }
    // Clients probe optional entry points before choosing a rendering
    // path. A null result is the EGL capability response.
    return libgles.getProcAddress(n);
}
/// GLX's (libGL.so.1): EGL's answer. There is no GLX context to call them
/// in (abi.sig), but a program may look its functions up all the same.
pub export fn glXGetProcAddress(name: ?[*:0]const u8) callconv(.c) ?*const anyopaque {
    return eglGetProcAddress(name);
}
pub export fn glXGetProcAddressARB(name: ?[*:0]const u8) callconv(.c) ?*const anyopaque {
    return eglGetProcAddress(name);
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

var lookup_test_messages: usize = 0;

fn countLookupTestMessage(_: []const u8) void {
    lookup_test_messages += 1;
}

test "libgalaxy_gl: optional Firefox lookups are silent and EGL call errors still report" {
    const sink = report.sink;
    report.sink = &countLookupTestMessage;
    defer report.sink = sink;
    lookup_test_messages = 0;

    try std.testing.expect(eglGetProcAddress("eglUnknownOptionalEntryPoint") == null);
    try std.testing.expect(eglGetProcAddress("eglSwapBuffersWithDamageKHR") != null);
    try std.testing.expect(eglGetProcAddress("glGetIntegerv") != null);
    try std.testing.expectEqual(@as(usize, 0), lookup_test_messages);
    try std.testing.expectEqual(egl.SUCCESS, eglGetError());

    try std.testing.expectEqual(egl.FALSE, eglBindAPI(0));
    try std.testing.expectEqual(egl.BAD_PARAMETER, eglGetError());
    try std.testing.expectEqual(@as(usize, 1), lookup_test_messages);
}

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

var test_android_object: u8 = 0;
var test_android_refs: usize = 0;
var test_android_fd: i32 = 72;
var test_android_pixels = [_]u8{ 1, 2, 3, 255 } ** 4;

fn testAndroidClient(buffer: *const anyopaque) ?*anyopaque {
    return if (buffer == @as(*const anyopaque, &test_android_object)) &test_android_object else null;
}

fn testAndroidRetain(client: *anyopaque) ?egl.AndroidBuffer {
    _ = testAndroidClient(client) orelse return null;
    test_android_refs += 1;
    return .{ .fd = test_android_fd, .width = 2, .height = 2, .fourcc = egl.DRM_FORMAT_ABGR8888, .pitch = 8 };
}

fn testAndroidRelease(client: *anyopaque) void {
    std.debug.assert(client == @as(*anyopaque, &test_android_object));
    test_android_refs -= 1;
}

fn testAndroidImport(_: ?*anyopaque, fd: i32) ?gpu.Buffer {
    if (fd != 72) return null;
    return .{ .cpu = &test_android_pixels, .bytes = test_android_pixels.len, .kind = .external };
}

fn testAnglePointer(surface: *const egl.Surface, attribute: i32) ?egl.SurfacePointer {
    if (attribute != 0x3200) return null;
    return .{ .value = if (surface.width == 2) @ptrFromInt(0x1234_5678_9ABC) else null };
}

test "libgalaxy_gl: native Android imports retain their client buffer and ANGLE returns full-width pointers" {
    t_eng.init(.{ .pool = &t_pool });
    var host = test_host;
    host.importFd = testAndroidImport;
    egl.setDriver(.{
        .open = testOpen,
        .host = host,
        .wayland = noWayland,
        .android = .{ .clientBuffer = testAndroidClient, .retain = testAndroidRetain, .release = testAndroidRelease },
        .surface_pointer = testAnglePointer,
    });
    const d = eglGetDisplay(null).?;
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    defer _ = eglTerminate(d);
    const ext = std.mem.span(eglQueryString(d, egl.EXTENSIONS).?);
    try std.testing.expect(std.mem.indexOf(u8, ext, "EGL_ANDROID_get_native_client_buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext, "EGL_ANGLE_query_surface_pointer") != null);

    const client = eglGetNativeClientBufferANDROID(&test_android_object).?;
    try std.testing.expectEqual(@as(usize, 0), test_android_refs);
    const image = eglCreateImageKHR(d, null, 0x3140, client, null).?;
    try std.testing.expectEqual(@as(usize, 1), test_android_refs);
    const internal: *egl.EImage = @ptrCast(@alignCast(image));
    try std.testing.expectEqualSlices(u8, &test_android_pixels, t_eng.hostView(&internal.img, 0, test_android_pixels.len));
    try std.testing.expectEqual(egl.TRUE, eglDestroyImageKHR(d, image));
    try std.testing.expectEqual(@as(usize, 0), test_android_refs);
    test_android_fd = 73;
    try std.testing.expect(eglCreateImageKHR(d, null, 0x3140, client, null) == null);
    test_android_fd = 72;
    try std.testing.expectEqual(egl.BAD_PARAMETER, eglGetError());
    try std.testing.expectEqual(@as(usize, 0), test_android_refs);
    try std.testing.expect(eglGetNativeClientBufferANDROID(null) == null);
    try std.testing.expectEqual(egl.BAD_PARAMETER, eglGetError());

    const surface = eglCreatePbufferSurface(d, &egl.configs[1], &.{ egl.WIDTH, 2, egl.HEIGHT, 2, egl.NONE }).?;
    var pointer: ?*anyopaque = null;
    try std.testing.expectEqual(egl.TRUE, eglQuerySurfacePointerANGLE(d, surface, 0x3200, &pointer));
    try std.testing.expectEqual(@as(usize, 0x1234_5678_9ABC), @intFromPtr(pointer.?));
    var scalar: i32 = 0;
    try std.testing.expectEqual(egl.FALSE, eglQuerySurface(d, surface, 0x3200, &scalar));
    try std.testing.expectEqual(egl.BAD_PARAMETER, eglGetError());
    try std.testing.expectEqual(egl.FALSE, eglQuerySurfacePointerANGLE(d, surface, egl.WIDTH, &pointer));
    try std.testing.expectEqual(egl.BAD_PARAMETER, eglGetError());
    try std.testing.expectEqual(egl.TRUE, eglDestroySurface(d, surface));
    try std.testing.expectEqual(egl.FALSE, eglQuerySurfacePointerANGLE(d, surface, 0x3200, &pointer));
    try std.testing.expectEqual(egl.BAD_SURFACE, eglGetError());
}

test "libgalaxy_gl: native Android buffers outlive EGLImage handles until the last GL sibling" {
    const g = gfxapi.glenum;
    t_eng.init(.{ .pool = &t_pool });
    var host = test_host;
    host.importFd = testAndroidImport;
    egl.setDriver(.{
        .open = testOpen,
        .host = host,
        .wayland = noWayland,
        .android = .{ .clientBuffer = testAndroidClient, .retain = testAndroidRetain, .release = testAndroidRelease },
    });
    const d = eglGetDisplay(null).?;
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    defer _ = eglTerminate(d);
    const ctx = eglCreateContext(d, &egl.configs[1], null, &.{ egl.CONTEXT_CLIENT_VERSION, 3, egl.NONE }).?;
    try std.testing.expectEqual(egl.TRUE, eglMakeCurrent(d, null, null, ctx));
    defer _ = eglMakeCurrent(d, null, null, null);
    const client = eglGetNativeClientBufferANDROID(&test_android_object).?;
    const image = eglCreateImageKHR(d, null, 0x3140, client, null).?;
    var name: [1]u32 = undefined;
    libgles.glGenTextures(1, &name);
    libgles.glBindTexture(g.TEXTURE_EXTERNAL_OES, name[0]);
    libgles.glEGLImageTargetTexture2DOES(g.TEXTURE_EXTERNAL_OES, image);
    try std.testing.expectEqual(g.NO_ERROR, libgles.glGetError());
    try std.testing.expectEqual(egl.TRUE, eglDestroyImageKHR(d, image));
    try std.testing.expectEqual(@as(usize, 1), test_android_refs);
    const sibling = thread.gl().?.streamTexture().?;
    try std.testing.expectEqualSlices(u8, &test_android_pixels, t_eng.hostView(&sibling.img, 0, test_android_pixels.len));
    const other = eglCreateImageKHR(d, null, 0x3140, client, null).?;
    try std.testing.expect(other != image);
    try std.testing.expectEqual(@as(usize, 2), test_android_refs);
    try std.testing.expectEqual(egl.TRUE, eglDestroyImageKHR(d, other));
    try std.testing.expectEqual(@as(usize, 1), test_android_refs);
    libgles.glDeleteTextures(1, &name);
    try std.testing.expectEqual(@as(usize, 0), test_android_refs);
}

test "libgalaxy_gl: EGLStream attributes, counters and lifetime through the C API" {
    t_eng.init(.{ .pool = &t_pool });
    egl.setDriver(.{ .open = testOpen, .host = test_host, .wayland = noWayland });
    const d = eglGetDisplay(null).?;
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    defer _ = eglTerminate(d);
    const extensions = std.mem.span(eglQueryString(d, egl.EXTENSIONS).?);
    try std.testing.expect(std.mem.indexOf(u8, extensions, "EGL_KHR_stream ") != null);
    try std.testing.expect(eglGetProcAddress("eglCreateStreamKHR") != null);
    try std.testing.expect(eglGetProcAddress("eglQueryStreamu64KHR") != null);
    try std.testing.expect(eglCreateStreamKHR(d, &.{ 0x3214, 0, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, eglGetError());

    const s = eglCreateStreamKHR(d, &.{ 0x3210, 25, egl.NONE }).?;
    var value: i32 = -1;
    try std.testing.expectEqual(egl.TRUE, eglQueryStreamKHR(d, s, 0x3214, &value));
    try std.testing.expectEqual(@as(i32, 0x3215), value);
    try std.testing.expectEqual(egl.TRUE, eglQueryStreamKHR(d, s, 0x3210, &value));
    try std.testing.expectEqual(@as(i32, 25), value);
    try std.testing.expectEqual(egl.TRUE, eglStreamAttribKHR(d, s, 0x3210, 50));
    try std.testing.expectEqual(egl.TRUE, eglQueryStreamKHR(d, s, 0x3210, &value));
    try std.testing.expectEqual(@as(i32, 50), value);
    var frame: u64 = 99;
    try std.testing.expectEqual(egl.TRUE, eglQueryStreamu64KHR(d, s, 0x3212, &frame));
    try std.testing.expectEqual(@as(u64, 0), frame);
    try std.testing.expectEqual(egl.TRUE, eglDestroyStreamKHR(d, s));
    try std.testing.expectEqual(egl.FALSE, eglQueryStreamKHR(d, s, 0x3214, &value));
    try std.testing.expectEqual(@as(i32, 0x321B), eglGetError());

    var live: [32]?*anyopaque = undefined;
    for (&live) |*entry| entry.* = eglCreateStreamKHR(d, null) orelse return error.StreamAllocationFailed;
    try std.testing.expect(eglCreateStreamKHR(d, null) == null);
    try std.testing.expectEqual(egl.BAD_ALLOC, eglGetError());
    try std.testing.expectEqual(egl.TRUE, eglDestroyStreamKHR(d, live[0]));
    const retired = eglCreateStreamKHR(d, null).?;
    try std.testing.expectEqual(egl.TRUE, eglTerminate(d));
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    try std.testing.expectEqual(egl.FALSE, eglDestroyStreamKHR(d, retired));
    try std.testing.expectEqual(@as(i32, 0x321B), eglGetError());
}

test "libgalaxy_gl: an EGLStream producer posts the newest image to an external texture" {
    const g = gfxapi.glenum;
    t_eng.init(.{ .pool = &t_pool });
    egl.setDriver(.{ .open = testOpen, .host = test_host, .wayland = noWayland });
    const d = eglGetDisplay(null).?;
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    defer _ = eglTerminate(d);
    const cfg = &egl.configs[1];
    const ctx = eglCreateContext(d, cfg, null, &.{ egl.CONTEXT_CLIENT_VERSION, 3, egl.NONE }).?;
    try std.testing.expectEqual(egl.TRUE, eglMakeCurrent(d, null, null, ctx));
    defer _ = eglMakeCurrent(d, null, null, null);
    var name: [1]u32 = undefined;
    libgles.glGenTextures(1, &name);
    libgles.glBindTexture(g.TEXTURE_EXTERNAL_OES, name[0]);
    const s = eglCreateStreamKHR(d, null).?;
    try std.testing.expectEqual(egl.TRUE, eglStreamConsumerGLTextureExternalKHR(d, s));
    const producer = eglCreateStreamProducerSurfaceKHR(d, cfg, s, &.{ egl.WIDTH, 4, egl.HEIGHT, 4, egl.NONE }).?;
    try std.testing.expectEqual(egl.TRUE, eglStreamAttribKHR(d, s, 0x321E, 1000));
    try std.testing.expectEqual(egl.FALSE, eglStreamConsumerAcquireKHR(d, s));
    try std.testing.expectEqual(@as(i32, 0x321C), eglGetError());
    try std.testing.expectEqual(egl.TRUE, eglStreamAttribKHR(d, s, 0x321E, 0));
    try std.testing.expectEqual(egl.TRUE, eglMakeCurrent(d, producer, producer, ctx));
    libgles.glClearColor(1, 0, 0, 1);
    libgles.glClear(g.COLOR_BUFFER_BIT);
    try std.testing.expectEqual(egl.TRUE, eglSwapBuffers(d, producer));
    libgles.glClearColor(0, 1, 0, 1);
    libgles.glClear(g.COLOR_BUFFER_BIT);
    try std.testing.expectEqual(egl.TRUE, eglSwapBuffers(d, producer));
    try std.testing.expectEqual(egl.TRUE, eglStreamConsumerAcquireKHR(d, s));
    const tex = thread.gl().?.streamTexture().?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, t_eng.hostView(&tex.img, 0, 4));
    var number: u64 = 0;
    try std.testing.expectEqual(egl.TRUE, eglQueryStreamu64KHR(d, s, 0x3213, &number));
    try std.testing.expectEqual(@as(u64, 2), number);
    try std.testing.expectEqual(egl.TRUE, eglStreamConsumerReleaseKHR(d, s));
    try std.testing.expect(!tex.img.live());
    try std.testing.expectEqual(egl.TRUE, eglStreamConsumerAcquireKHR(d, s));
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, t_eng.hostView(&tex.img, 0, 4));
    libgles.glDeleteTextures(1, &name);
    var state: i32 = 0;
    try std.testing.expectEqual(egl.TRUE, eglQueryStreamKHR(d, s, 0x3214, &state));
    try std.testing.expectEqual(@as(i32, 0x321A), state);
    try std.testing.expectEqual(egl.FALSE, eglSwapBuffers(d, producer));
    try std.testing.expectEqual(egl.BAD_CURRENT_SURFACE, eglGetError());
}

test "libgalaxy_gl: failed stream acquisition releases the previously acquired frame" {
    const g = gfxapi.glenum;
    t_eng.init(.{ .pool = &t_pool });
    egl.setDriver(.{ .open = testOpen, .host = test_host, .wayland = noWayland });
    const d = eglGetDisplay(null).?;
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    defer _ = eglTerminate(d);
    const cfg = &egl.configs[1];
    const ctx = eglCreateContext(d, cfg, null, &.{ egl.CONTEXT_CLIENT_VERSION, 3, egl.NONE }).?;
    try std.testing.expectEqual(egl.TRUE, eglMakeCurrent(d, null, null, ctx));
    defer _ = eglMakeCurrent(d, null, null, null);
    var name: [1]u32 = undefined;
    libgles.glGenTextures(1, &name);
    libgles.glBindTexture(g.TEXTURE_EXTERNAL_OES, name[0]);
    const stream = eglCreateStreamKHR(d, null).?;
    try std.testing.expectEqual(egl.TRUE, eglStreamConsumerGLTextureExternalKHR(d, stream));
    const producer = eglCreateStreamProducerSurfaceKHR(d, cfg, stream, &.{ egl.WIDTH, 4, egl.HEIGHT, 4, egl.NONE }).?;
    try std.testing.expectEqual(egl.TRUE, eglMakeCurrent(d, producer, producer, ctx));
    try std.testing.expectEqual(egl.TRUE, eglSwapBuffers(d, producer));
    try std.testing.expectEqual(egl.TRUE, eglStreamConsumerAcquireKHR(d, stream));
    const tex = thread.gl().?.streamTexture().?;
    try std.testing.expect(tex.img.live());
    try std.testing.expectEqual(egl.TRUE, eglMakeCurrent(d, null, null, ctx));
    try std.testing.expectEqual(egl.TRUE, eglDestroySurface(d, producer));
    try std.testing.expectEqual(egl.FALSE, eglStreamConsumerAcquireKHR(d, stream));
    try std.testing.expectEqual(@as(i32, 0x321C), eglGetError());
    try std.testing.expect(!tex.img.live());
    try std.testing.expectEqual(@as(u16, 0), tex.defined);
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
    const ctx_attribs = [_]i32{ egl.CONTEXT_CLIENT_VERSION, 3, egl.CONTEXT_OPENGL_DEBUG, 1, egl.NONE };
    const ctx = eglCreateContext(dpy, cfg[0], null, &ctx_attribs);
    try std.testing.expect(ctx != null);
    const pb_attribs = [_]i32{ egl.WIDTH, 8, egl.HEIGHT, 4, egl.NONE };
    const pb = eglCreatePbufferSurface(dpy, cfg[0], &pb_attribs);
    try std.testing.expect(pb != null);
    try std.testing.expectEqual(@as(u32, 1), eglMakeCurrent(dpy, pb, pb, ctx));
    try std.testing.expectEqual(ctx, eglGetCurrentContext());
    try std.testing.expectEqual(@as(u8, 1), libgles.glIsEnabled(0x92E0));
    try std.testing.expectEqual(@as(u32, 0), eglSetDamageRegionKHR(dpy, pb, null, 0));
    try std.testing.expectEqual(egl.BAD_MATCH, eglGetError());
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
    try std.testing.expectEqual(@as(i32, 8), nf); // (four RGB, four video planes)
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

test "libgalaxy_gl: GLX looks up what EGL does; Mesa's names are answered" {
    try std.testing.expect(glXGetProcAddressARB("glClear") == eglGetProcAddress("glClear"));
    try std.testing.expect(glXGetProcAddress("eglSwapBuffers") == eglGetProcAddress("eglSwapBuffers"));
    try std.testing.expect(glXGetProcAddressARB(null) == null);
    // (desktop GL's glBegin is abi.Missing's, not an entry point to hand out)
    try std.testing.expect(glXGetProcAddressARB("glBegin") == null);
    try std.testing.expect(@hasDecl(libgles, "glClear") and !abi.answers("glClear"));
}

var dma_export_pixels: [64]u8 = undefined;
var dma_export_closed: i32 = -1;

fn testDmaImport(_: ?*anyopaque, fd: i32) ?gpu.Buffer {
    if (fd != 10) return null;
    return .{ .cpu = &dma_export_pixels, .bytes = dma_export_pixels.len, .kind = .external };
}

fn testDmaClose(_: ?*anyopaque, fd: i32) void {
    dma_export_closed = fd;
}

test "libgalaxy_gl: MESA export preserves the plane and returns an independent fd" {
    t_eng.init(.{ .pool = &t_pool });
    var host = test_host;
    host.importFd = testDmaImport;
    host.close = testDmaClose;
    egl.setDriver(.{ .open = testOpen, .host = host, .wayland = noWayland });
    const dpy = eglGetDisplay(null);
    try std.testing.expectEqual(@as(u32, 1), eglInitialize(dpy, null, null));
    defer _ = eglTerminate(dpy);
    const format: i32 = @bitCast(wayland.DRM_FORMAT_ARGB8888);
    const attrs = [_]i32{
        egl.WIDTH,                 2,  egl.HEIGHT,                    2, egl.LINUX_DRM_FOURCC_EXT,     format,
        egl.DMA_BUF_PLANE0_FD_EXT, 10, egl.DMA_BUF_PLANE0_OFFSET_EXT, 4, egl.DMA_BUF_PLANE0_PITCH_EXT, 16,
        egl.NONE,
    };
    const image = eglCreateImageKHR(dpy, null, egl.LINUX_DMA_BUF_EXT, null, &attrs);
    try std.testing.expect(image != null);
    var fourcc: i32 = 0;
    var planes: i32 = 0;
    var modifier: u64 = 1;
    try std.testing.expectEqual(@as(u32, 1), eglExportDMABUFImageQueryMESA(dpy, image, &fourcc, &planes, &modifier));
    try std.testing.expectEqual([2]i32{ format, 1 }, .{ fourcc, planes });
    try std.testing.expectEqual(@as(u64, 0), modifier);
    var fd: i32 = 0;
    var stride: i32 = 0;
    var offset: i32 = 0;
    try std.testing.expectEqual(@as(u32, 1), eglExportDMABUFImageMESA(dpy, image, &fd, &stride, &offset));
    try std.testing.expectEqual([3]i32{ 12, 16, 4 }, .{ fd, stride, offset });
    try std.testing.expectEqual(@as(u32, 1), eglDestroyImageKHR(dpy, image));
    try std.testing.expectEqual(@as(i32, 11), dma_export_closed);
    try std.testing.expectEqual(@as(u32, 0), eglExportDMABUFImageMESA(dpy, image, null, null, null));
}

// ── Two threads drawing at once (the driver lock) ──────────────────────────

var mt_mem: [8 << 20]u8 align(4096) = undefined;
var mt_work: [4 << 20]u8 align(64) = undefined;
var mt_compile: [256 << 10]u8 align(64) = undefined;
var mt_emu: gpu.EmuDevice = undefined;
var mt_eng: engine.Engine = undefined;
/// The threads in at the start (each waits for the other, so their calls
/// meet).
var mt_started = std.atomic.Value(u32).init(0);

fn mtOpen() ?*engine.Engine {
    return &mt_eng;
}

const MT_THREADS = 2;
const MT_W = 16;
const MT_H = 16;
const MT_ROUNDS = 100;

/// A drawing thread's: its number, the display, and what it found.
const MtRun = struct {
    which: u32,
    dpy: ?*anyopaque,
    /// rounds whose every pixel was right, and those with one wrong
    right: u32 = 0,
    wrong: u32 = 0,
    /// the first wrong pixel: where, what was read, what was wanted
    first: ?struct { round: usize, x: usize, y: usize, got: [4]u8, want: [4]u8 } = null,
    /// a call that failed (no rounds drawn then)
    failed: ?[]const u8 = null,
};

/// A color of thread `which`'s, round `round`'s, clear (part 0) or draw
/// (part 1): no two threads' alike in a round, opaque.
fn mtColor(which: u32, round: usize, part: u32) [4]u8 {
    const k: u32 = @intCast(round);
    return .{ @truncate(which * 120 + part * 60 + k * 5 + 1), @truncate(which * 30 + part * 90 + k * 3), @truncate(250 - which * 70 - part * 40 - k), 255 };
}

fn mtFloat(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255.0;
}

fn mtShader(kind: u32, src: [*:0]const u8) u32 {
    const s = libgles.glCreateShader(kind);
    const parts = [_]?[*]const u8{src};
    libgles.glShaderSource(s, 1, &parts, null);
    libgles.glCompileShader(s);
    return s;
}

/// One thread's: a context and a pbuffer of its own, made current here,
/// then rounds of a clear and a draw over the left half, each in this
/// thread's colors of the round, read back and checked whole.
fn mtDraw(run: *MtRun) void {
    const g = gfxapi.glenum;
    _ = mt_started.fetchAdd(1, .acq_rel);
    while (mt_started.load(.acquire) < MT_THREADS) std.atomic.spinLoopHint();
    const d = run.dpy;
    const cfg = &egl.configs[1];
    const ctx = eglCreateContext(d, cfg, null, &.{ egl.CONTEXT_CLIENT_VERSION, 3, egl.NONE }) orelse {
        run.failed = "eglCreateContext";
        return;
    };
    defer _ = eglDestroyContext(d, ctx);
    const pb = eglCreatePbufferSurface(d, cfg, &.{ egl.WIDTH, MT_W, egl.HEIGHT, MT_H, egl.NONE }) orelse {
        run.failed = "eglCreatePbufferSurface";
        return;
    };
    defer _ = eglDestroySurface(d, pb);
    if (eglMakeCurrent(d, pb, pb, ctx) != egl.TRUE) {
        run.failed = "eglMakeCurrent";
        return;
    }
    defer _ = eglMakeCurrent(d, null, null, null);
    const vs = mtShader(g.VERTEX_SHADER, "#version 300 es\nin vec2 aPos;\nvoid main() { gl_Position = vec4(aPos, 0.0, 1.0); }\n");
    defer libgles.glDeleteShader(vs);
    const fs = mtShader(g.FRAGMENT_SHADER, "#version 300 es\nprecision mediump float;\nuniform vec4 uColor;\nout vec4 oColor;\nvoid main() { oColor = uColor; }\n");
    defer libgles.glDeleteShader(fs);
    const prog = libgles.glCreateProgram();
    defer libgles.glDeleteProgram(prog);
    libgles.glAttachShader(prog, vs);
    libgles.glAttachShader(prog, fs);
    libgles.glBindAttribLocation(prog, 0, "aPos");
    libgles.glLinkProgram(prog);
    var linked: i32 = 0;
    libgles.glGetProgramiv(prog, g.LINK_STATUS, @ptrCast(&linked));
    if (linked != 1) {
        run.failed = "glLinkProgram";
        return;
    }
    libgles.glUseProgram(prog);
    const loc = libgles.glGetUniformLocation(prog, "uColor");
    // the left half: two triangles over x in [-1, 0]
    const quad = [_]f32{ -1, -1, 0, -1, 0, 1, -1, -1, 0, 1, -1, 1 };
    var vbo: [1]u32 = undefined;
    libgles.glGenBuffers(1, &vbo);
    defer libgles.glDeleteBuffers(1, &vbo);
    libgles.glBindBuffer(g.ARRAY_BUFFER, vbo[0]);
    libgles.glBufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, g.STATIC_DRAW);
    libgles.glVertexAttribPointer(0, 2, g.FLOAT, 0, 0, null);
    libgles.glEnableVertexAttribArray(0);
    if (loc < 0 or libgles.glGetError() != g.NO_ERROR) {
        run.failed = "the program's setup";
        return;
    }
    var px: [MT_W * MT_H * 4]u8 = undefined;
    for (0..MT_ROUNDS) |r| {
        const back = mtColor(run.which, r, 0);
        const fore = mtColor(run.which, r, 1);
        libgles.glClearColor(mtFloat(back[0]), mtFloat(back[1]), mtFloat(back[2]), 1);
        libgles.glClear(g.COLOR_BUFFER_BIT);
        libgles.glUniform4f(loc, mtFloat(fore[0]), mtFloat(fore[1]), mtFloat(fore[2]), 1);
        libgles.glDrawArrays(g.TRIANGLES, 0, 6);
        @memset(&px, 0);
        libgles.glReadPixels(0, 0, MT_W, MT_H, g.RGBA, g.UNSIGNED_BYTE, &px);
        var right = true;
        for (0..MT_H) |y| {
            for (0..MT_W) |x| {
                const want = if (x < MT_W / 2) fore else back;
                const got = px[(y * MT_W + x) * 4 ..][0..4].*;
                if (std.mem.eql(u8, &got, &want)) continue;
                if (run.first == null) run.first = .{ .round = r, .x = x, .y = y, .got = got, .want = want };
                right = false;
            }
        }
        if (right) run.right += 1 else run.wrong += 1;
    }
    // (an entry point that calls another: the lock entered twice)
    if (libgles.glGetGraphicsResetStatusEXT() != g.NO_ERROR) run.failed = "glGetGraphicsResetStatusEXT";
    if (libgles.glGetError() != g.NO_ERROR) run.failed = "a GL call (glGetError)";
}

test "libgalaxy_gl: two threads draw at once, each in its own context, and each reads back only its own pixels" {
    mt_emu = gpu.EmuDevice.init(gpu.interp_caps, &mt_mem, &mt_work);
    mt_eng.init(.{ .dev = mt_emu.device(), .work = &mt_compile });
    egl.setDriver(.{ .open = mtOpen, .host = test_host, .wayland = noWayland });
    const d = eglGetDisplay(null).?;
    try std.testing.expectEqual(egl.TRUE, eglInitialize(d, null, null));
    defer _ = eglTerminate(d);
    // the lock: free between calls, re-entrant for its holder (EGL and GL
    // calls made while this thread holds it go through)
    try std.testing.expect(egl.driverFree());
    egl.driverEnter();
    egl.driverEnter();
    try std.testing.expect(!egl.driverFree());
    try std.testing.expectEqual(gfxapi.glenum.NO_ERROR, libgles.glGetError());
    try std.testing.expectEqual(egl.SUCCESS, eglGetError());
    try std.testing.expect(eglQueryString(d, egl.EXTENSIONS) != null);
    egl.driverLeave();
    try std.testing.expect(!egl.driverFree());
    egl.driverLeave();
    try std.testing.expect(egl.driverFree());
    mt_started.store(0, .release);
    var runs: [MT_THREADS]MtRun = undefined;
    for (&runs, 0..) |*r, i| r.* = .{ .which = @intCast(i), .dpy = d };
    var threads: [MT_THREADS]std.Thread = undefined;
    for (&threads, &runs) |*t, *r| t.* = try std.Thread.spawn(.{ .stack_size = 16 << 20 }, mtDraw, .{r});
    for (threads) |t| t.join();
    for (runs) |r| {
        if (r.failed) |what| std.debug.print("thread {d}: {s} failed\n", .{ r.which, what });
        if (r.first) |f| std.debug.print("thread {d}: {d} rounds wrong; the first at round {d}, ({d}, {d}): {any}, not {any}\n", .{ r.which, r.wrong, f.round, f.x, f.y, f.got, f.want });
    }
    for (runs) |r| {
        try std.testing.expect(r.failed == null);
        try std.testing.expectEqual(@as(u32, MT_ROUNDS), r.right);
    }
    // the lock let go by both, the device kept, every draw on it
    try std.testing.expect(egl.driverFree());
    try std.testing.expect(!mt_eng.lost);
    try std.testing.expect(mt_eng.stats.dispatches >= MT_THREADS * MT_ROUNDS * 3);
}
