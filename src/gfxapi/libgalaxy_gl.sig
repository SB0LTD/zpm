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
const report = gfxapi.report;
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
pub export fn eglGetProcAddress(name: ?[*:0]const u8) callconv(.c) ?*const anyopaque {
    const n = name orelse return null;
    const s = std.mem.span(n);
    for (entries) |e| {
        if (std.mem.eql(u8, s, e.name)) return e.ptr;
    }
    const p = libgles.getProcAddress(n);
    if (p == null) report.say(.missing, "eglGetProcAddress(\"{s}\"): not in this driver", .{s});
    return p;
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
