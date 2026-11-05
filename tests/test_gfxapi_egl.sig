//! gfxapi's EGL on a fake Wayland compositor that answers as Galaxy's
//! bridge does (zwp_linux_dmabuf_v1 with linear ARGB8888 and XRGB8888 as
//! `modifier` events at version 3, create_immed, a buffer released when
//! the next one is shown, frame callbacks answered at the next dispatch),
//! behind the `Client` table EGL takes libwayland-client's functions in.
//! The engine runs on EmuDevice (KIR's interpreter, memory not coherent).
//!
//! Checked: the display's queue, registry and binding; a window's frames
//! (their dma-bufs' fds, strides and modifiers, create_immed's sizes and
//! formats, attach, damage, frame, commit, flush); the pixels in the
//! buffers, top-down; swap interval 1 waiting for the frame callback;
//! buffers reused once released, buffer age; damage rectangles flipped
//! to the buffer's rows; a resize; everything given back at the end; a
//! compositor without dma-bufs, refused.

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const egl = gfxapi.egl;
const wl = gfxapi.wayland;
const gl = gfxapi.glenum;
const thread = gfxapi.thread;

// ── The fake compositor ────────────────────────────────────────────────────

var display_iface = wl.Interface{ .name = "wl_display", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var registry_iface = wl.Interface{ .name = "wl_registry", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var buffer_iface = wl.Interface{ .name = "wl_buffer", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var callback_iface = wl.Interface{ .name = "wl_callback", .version = 1, .method_count = 0, .methods = null, .event_count = 0, .events = null };
var surface_iface = wl.Interface{ .name = "wl_surface", .version = 6, .method_count = 0, .methods = null, .event_count = 0, .events = null };

/// A proxy: its interface first, as a wl_display's is.
const P = extern struct {
    iface: ?*const wl.Interface = null,
    version: u32 = 0,
    used: bool = false,
    disp: ?wl.Dispatcher = null,
    impl: ?*const anyopaque = null,
    queue: ?*wl.Queue = null,
    /// a wrapper's object
    of: ?*P = null,
    /// a buffer's size and format; a buffer's or params' dma-buf
    w: i32 = 0,
    h: i32 = 0,
    format: u32 = 0,
    fd: i32 = -1,
    stride: u32 = 0,
    modifier: u64 = 0,
};

/// `later`: an event of the compositor's time (a frame callback's done),
/// which only a dispatch that waits sees; the others are read already
/// (a buffer's release, the registry's).
const Event = struct { p: *P, opcode: u32, args: [4]wl.Arg, later: bool };

const Fake = struct {
    var proxies: [64]P = undefined;
    var events: [64]Event = undefined;
    var n_events: usize = 0;
    var queue_mark: u8 = 0;
    var queues: u32 = 0;
    var dmabuf_offered = true;
    var bound_version: u32 = 0;
    var flushes: u32 = 0;
    var commits: u32 = 0;
    var frames: u32 = 0;
    var attached: ?*P = null;
    var shown: ?*P = null;
    var damage: [8][4]i32 = undefined;
    var n_damage: usize = 0;
    var last_commit_damage: usize = 0;
    var buffers_made: u32 = 0;
    var buffers_destroyed: u32 = 0;
    var closes: u32 = 0;

    fn reset() void {
        for (&proxies) |*p| p.* = .{};
        n_events = 0;
        queues = 0;
        dmabuf_offered = true;
        bound_version = 0;
        flushes = 0;
        commits = 0;
        frames = 0;
        attached = null;
        shown = null;
        n_damage = 0;
        buffers_made = 0;
        buffers_destroyed = 0;
        closes = 0;
    }

    fn new(iface: ?*const wl.Interface, version: u32, queue: ?*wl.Queue) *P {
        for (&proxies) |*p| {
            if (!p.used) {
                p.* = .{ .iface = iface, .version = version, .used = true, .queue = queue };
                return p;
            }
        }
        @panic("fake compositor: out of proxies");
    }

    fn live() usize {
        var n: usize = 0;
        for (&proxies) |*p| n += @intFromBool(p.used);
        return n;
    }

    fn of(p: *wl.Proxy) *P {
        const x: *P = @ptrCast(@alignCast(p));
        return x.of orelse x;
    }

    fn post(p: *P, opcode: u32, args: [4]wl.Arg) void {
        postAt(p, opcode, args, false);
    }

    fn postAt(p: *P, opcode: u32, args: [4]wl.Arg, later: bool) void {
        events[n_events] = .{ .p = p, .opcode = opcode, .args = args, .later = later };
        n_events += 1;
    }

    /// The queued events delivered (all of them, or those read already);
    /// how many.
    fn deliver(all: bool) c_int {
        var n: c_int = 0;
        var keep: usize = 0;
        var i: usize = 0;
        const end = n_events;
        while (i < end) : (i += 1) {
            var e = events[i];
            if (e.later and !all) {
                events[keep] = e;
                keep += 1;
                continue;
            }
            if (!e.p.used) continue;
            if (e.p.disp) |d| _ = d(e.p.impl, e.p, e.opcode, null, &e.args);
            n += 1;
        }
        // (events posted while delivering stay, after those kept)
        std.mem.copyForwards(Event, events[keep .. keep + (n_events - end)], events[end..n_events]);
        n_events = keep + (n_events - end);
        return n;
    }

    // the Client table
    fn createQueue(d: *wl.Proxy) callconv(.c) ?*wl.Queue {
        _ = d;
        queues += 1;
        return @ptrCast(&queue_mark);
    }
    fn queueDestroy(q: *wl.Queue) callconv(.c) void {
        _ = q;
        queues -= 1;
    }
    fn createWrapper(p: *wl.Proxy) callconv(.c) ?*wl.Proxy {
        const o = of(p);
        const x = new(o.iface, o.version, null);
        x.of = o;
        return @ptrCast(x);
    }
    fn wrapperDestroy(p: *wl.Proxy) callconv(.c) void {
        const x: *P = @ptrCast(@alignCast(p));
        x.used = false;
    }
    fn setQueue(p: *wl.Proxy, q: ?*wl.Queue) callconv(.c) void {
        const x: *P = @ptrCast(@alignCast(p));
        x.queue = q;
    }
    fn addDispatcher(p: *wl.Proxy, f: wl.Dispatcher, impl: ?*const anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        _ = data;
        const x: *P = @ptrCast(@alignCast(p));
        x.disp = f;
        x.impl = impl;
        return 0;
    }
    fn destroy(p: *wl.Proxy) callconv(.c) void {
        const x: *P = @ptrCast(@alignCast(p));
        x.used = false;
    }
    fn getVersion(p: *wl.Proxy) callconv(.c) u32 {
        const x: *P = @ptrCast(@alignCast(p));
        return x.version;
    }
    fn roundtrip(d: *wl.Proxy, q: *wl.Queue) callconv(.c) c_int {
        _ = d;
        _ = q;
        return deliver(true);
    }
    fn dispatch(d: *wl.Proxy, q: *wl.Queue) callconv(.c) c_int {
        _ = d;
        _ = q;
        // (nothing would ever come: a real one would block for ever)
        if (n_events == 0) return -1;
        return deliver(true);
    }
    fn dispatchPending(d: *wl.Proxy, q: *wl.Queue) callconv(.c) c_int {
        _ = d;
        _ = q;
        return deliver(false);
    }
    fn flush(d: *wl.Proxy) callconv(.c) c_int {
        _ = d;
        flushes += 1;
        return 0;
    }
    fn marshalCtor(p: *wl.Proxy, opcode: u32, args: [*]wl.Arg, iface: *const wl.Interface, version: u32) callconv(.c) ?*wl.Proxy {
        return marshalFlags(p, opcode, iface, version, 0, args);
    }
    fn marshal(p: *wl.Proxy, opcode: u32, args: [*]wl.Arg) callconv(.c) void {
        _ = marshalFlags(p, opcode, null, 0, 0, args);
    }

    /// A request, answered as Galaxy's bridge does.
    fn marshalFlags(pp: *wl.Proxy, opcode: u32, iface: ?*const wl.Interface, version: u32, flags: u32, args: [*]wl.Arg) callconv(.c) ?*wl.Proxy {
        const wrapper: *P = @ptrCast(@alignCast(pp));
        const p = of(pp);
        const q = wrapper.queue;
        var out: ?*P = null;
        if (iface) |i| out = new(i, version, q);
        const is = struct {
            fn f(x: *P, i: *const wl.Interface) bool {
                return x.iface == i;
            }
        }.f;
        if (is(p, &display_iface) and opcode == 1) { // get_registry
            post(out.?, 0, .{ .{ .u = 7 }, .{ .s = "wl_compositor" }, .{ .u = 6 }, .{ .u = 0 } });
            if (dmabuf_offered) post(out.?, 0, .{ .{ .u = 9 }, .{ .s = "zwp_linux_dmabuf_v1" }, .{ .u = 4 }, .{ .u = 0 } });
        } else if (is(p, &registry_iface) and opcode == 0) { // bind
            std.debug.assert(args[0].u == 9);
            bound_version = version;
            post(out.?, 1, .{ .{ .u = wl.DRM_FORMAT_ARGB8888 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } });
            post(out.?, 1, .{ .{ .u = wl.DRM_FORMAT_XRGB8888 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } });
            // (a format with a tiled modifier only: not a linear one)
            post(out.?, 1, .{ .{ .u = 0x3231_4752 }, .{ .u = 0x0100_0000 }, .{ .u = 1 }, .{ .u = 0 } });
        } else if (p.iface == &wl.params_interface) {
            switch (opcode) {
                1 => { // add
                    p.fd = args[0].h;
                    p.stride = args[3].u;
                    p.modifier = @as(u64, args[4].u) << 32 | args[5].u;
                },
                3 => { // create_immed
                    const b = out.?;
                    b.w = args[1].i;
                    b.h = args[2].i;
                    b.format = args[3].u;
                    b.fd = p.fd;
                    b.stride = p.stride;
                    b.modifier = p.modifier;
                    buffers_made += 1;
                },
                else => {},
            }
        } else if (is(p, &buffer_iface) and opcode == 0) {
            buffers_destroyed += 1;
        } else if (is(p, &surface_iface)) {
            switch (opcode) {
                1 => attached = @ptrCast(@alignCast(args[0].o)), // attach
                3 => { // frame: done at the next dispatch
                    frames += 1;
                    postAt(out.?, 0, .{ .{ .u = 1000 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }, true);
                },
                9 => { // damage_buffer
                    damage[n_damage] = .{ args[0].i, args[1].i, args[2].i, args[3].i };
                    n_damage += 1;
                },
                6 => { // commit: the attached buffer shown, the one before released
                    commits += 1;
                    last_commit_damage = n_damage;
                    if (shown) |old| {
                        if (old != attached) post(old, 0, .{ .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } });
                    }
                    shown = attached;
                },
                else => {},
            }
        }
        if (flags & wl.DESTROY != 0) p.used = false;
        return @ptrCast(out);
    }

    const client = wl.Client{
        .create_queue = createQueue,
        .queue_destroy = queueDestroy,
        .create_wrapper = createWrapper,
        .wrapper_destroy = wrapperDestroy,
        .set_queue = setQueue,
        .marshal_flags = marshalFlags,
        .marshal_ctor = marshalCtor,
        .marshal = marshal,
        .add_dispatcher = addDispatcher,
        .destroy = destroy,
        .get_version = getVersion,
        .roundtrip_queue = roundtrip,
        .dispatch_queue = dispatch,
        .dispatch_pending = dispatchPending,
        .flush = flush,
        .display_interface = &display_iface,
        .registry_interface = &registry_iface,
        .buffer_interface = &buffer_iface,
        .callback_interface = &callback_iface,
        .surface_interface = &surface_iface,
    };
};

// ── The driver: EmuDevice, fds that are its buffers' handles ──────────────

var emu_mem: [4 << 20]u8 align(4096) = undefined;
var emu_shadow: [8 << 20]u8 align(4096) = undefined;
var emu_work: [4 << 20]u8 align(64) = undefined;
var compile_mem: [64 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng: engine.Engine = undefined;
var opened = false;

fn open() ?*engine.Engine {
    if (!opened) {
        var c = gpu.interp_caps;
        c.coherent = false;
        emu = gpu.EmuDevice.init(c, &emu_mem, &emu_work);
        emu.shadow = &emu_shadow;
        eng.init(.{ .dev = emu.device(), .work = &compile_mem });
        opened = true;
    }
    return &eng;
}
fn exportFd(ctx: ?*anyopaque, b: gpu.Buffer) i64 {
    _ = ctx;
    return 200 + @as(i64, b.handle);
}
fn closeFd(ctx: ?*anyopaque, fd: i32) void {
    _ = ctx;
    _ = fd;
    Fake.closes += 1;
}
fn client() ?*const wl.Client {
    return &Fake.client;
}

fn useDriver() void {
    egl.setDriver(.{ .open = open, .exporter = .{ .exportFd = exportFd, .close = closeFd }, .wayland = client });
}

fn pixel(img: *engine.Image, x: u32, row: u32) [4]u8 {
    const v = eng.hostView(img, @as(usize, row) * img.stride + @as(usize, x) * 4, 4);
    return v[0..4].*;
}

/// The fake wl_display and wl_surface, and a wl_egl_window over it.
var native_display: *P = undefined;
var native_surface: *P = undefined;
var window: wl.EglWindow = undefined;

fn world(w: c_int, h: c_int) void {
    Fake.reset();
    native_display = Fake.new(&display_iface, 1, null);
    native_surface = Fake.new(&surface_iface, 6, null);
    window = .{ .version = wl.EGL_WINDOW_VERSION, .width = w, .height = h, .dx = 0, .dy = 0, .attached_width = 0, .attached_height = 0, .driver_private = null, .resize_callback = null, .destroy_window_callback = null, .surface = @ptrCast(native_surface) };
}

fn config(alpha: bool) *const anyopaque {
    return &egl.configs[if (alpha) 1 else 3];
}

test "egl: a Wayland window's frames go to the compositor as dma-bufs" {
    useDriver();
    world(32, 16);
    const base = Fake.live();
    const d = egl.getPlatformDisplay(egl.PLATFORM_WAYLAND_KHR, native_display).?;
    // (eglGetDisplay of the same wl_display: the same display)
    try std.testing.expectEqual(d, egl.getDisplay(native_display).?);
    try std.testing.expect(egl.initialize(d, null, null));
    try std.testing.expectEqual(@as(u32, 3), Fake.bound_version);
    try std.testing.expect(d.wl.argb and d.wl.xrgb);
    const ctx = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    const s = egl.createWindowSurface(i32, d, config(true), &window, null).?;
    try std.testing.expect(window.driver_private != null);
    try std.testing.expect(egl.makeCurrent(d, s, s, ctx));
    const c = thread.gl().?;
    var age: i32 = -1;
    try std.testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try std.testing.expectEqual(@as(i32, 0), age);

    // frame 1: red
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    // (the next back buffer is taken at once: frame 1's is held, so a
    // second is made)
    try std.testing.expectEqual(@as(u32, 2), Fake.buffers_made);
    try std.testing.expectEqual(@as(u32, 1), Fake.commits);
    try std.testing.expectEqual(@as(u32, 1), Fake.frames);
    try std.testing.expect(Fake.flushes >= 1);
    try std.testing.expectEqual(@as(u32, 2), Fake.closes); // (EGL's own fds, closed once sent)
    const b0 = Fake.shown.?;
    try std.testing.expectEqual(@as(i32, 32), b0.w);
    try std.testing.expectEqual(@as(i32, 16), b0.h);
    try std.testing.expectEqual(wl.DRM_FORMAT_ARGB8888, b0.format);
    try std.testing.expectEqual(@as(u32, 32 * 4), b0.stride);
    try std.testing.expectEqual(@as(u64, 0), b0.modifier);
    try std.testing.expect(b0.fd >= 200);
    // the whole buffer damaged; window's size attached
    try std.testing.expectEqual([4]i32{ 0, 0, std.math.maxInt(i32), std.math.maxInt(i32) }, Fake.damage[0]);
    try std.testing.expectEqual([2]c_int{ 32, 16 }, .{ window.attached_width, window.attached_height });
    // the buffer's pixels, top-down BGRA: red
    const w0 = &s.win.bufs[0];
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(&w0.img, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(&w0.img, 31, 15));

    // frame 2: green in the bottom left 4 x 2 (GL's rows 0, 1: the buffer's last)
    c.clearColor(0, 1, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try std.testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try std.testing.expectEqual(@as(i32, 0), age); // (a new buffer: frame 1's is held)
    try std.testing.expect(egl.swapBuffers(d, s, &.{.{ 0, 0, 4, 2 }}));
    // (interval 1: the swap waited for frame 1's callback)
    try std.testing.expectEqual(@as(u64, 1), s.win.stats.frame_waits);
    try std.testing.expectEqual(@as(u32, 2), Fake.buffers_made);
    try std.testing.expectEqual([4]i32{ 0, 14, 4, 2 }, Fake.damage[Fake.n_damage - 1]);
    try std.testing.expect(Fake.shown.? != b0);

    // frame 3: buffer 0 is back (released when frame 2 was shown), age 2
    try std.testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try std.testing.expectEqual(@as(i32, 2), age);
    try std.testing.expectEqual(@as(u32, 2), Fake.buffers_made);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(&w0.img, 0, 0)); // (frame 1's, kept)

    // interval 0: no frame callback asked, none waited for
    try std.testing.expect(egl.swapInterval(d, 0));
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    const frames = Fake.frames;
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    try std.testing.expectEqual(frames, Fake.frames);

    // a resize: the next frame's buffers are the new size
    window.width = 48;
    window.height = 24;
    window.resize_callback.?(&window, window.driver_private);
    var wq: i32 = 0;
    try std.testing.expect(egl.querySurface(d, s, egl.WIDTH, &wq));
    try std.testing.expectEqual(@as(i32, 48), wq);
    c.clearColor(0, 0, 1, 0.5);
    c.clear(gl.COLOR_BUFFER_BIT);
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    try std.testing.expectEqual(@as(i32, 48), Fake.shown.?.w);
    try std.testing.expectEqual(@as(i32, 24), Fake.shown.?.h);
    // (premultiplied as GL wrote it: blue 255, alpha 128)
    const shown_img = blk: {
        for (&s.win.bufs) |*b| {
            if (b.wl == @as(?*wl.Proxy, @ptrCast(Fake.shown.?))) break :blk &b.img;
        }
        unreachable;
    };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 128 }, pixel(shown_img, 47, 23));

    // everything given back
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(egl.destroySurface(d, s));
    try std.testing.expect(window.driver_private == null);
    try std.testing.expect(egl.destroyContext(d, ctx));
    try std.testing.expect(egl.terminate(d));
    try std.testing.expectEqual(Fake.buffers_made, Fake.buffers_destroyed);
    try std.testing.expectEqual(base, Fake.live());
    try std.testing.expectEqual(@as(u32, 0), Fake.queues);
}

test "egl: an XRGB window reads back opaque, and is made XRGB8888" {
    useDriver();
    world(8, 8);
    const d = egl.getPlatformDisplay(egl.PLATFORM_WAYLAND_KHR, native_display).?;
    try std.testing.expect(egl.initialize(d, null, null));
    const ctx = egl.createContext(d, config(false), null, &[_]i32{ egl.CONTEXT_CLIENT_VERSION, 2, egl.NONE }).?;
    const s = egl.createWindowSurface(isize, d, config(false), &window, &[_]isize{ egl.RENDER_BUFFER, egl.BACK_BUFFER, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, s, s, ctx));
    const c = thread.gl().?;
    c.clearColor(0.5, 0.5, 0.5, 0);
    c.clear(gl.COLOR_BUFFER_BIT);
    var px: [4]u8 = undefined;
    c.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &px);
    try std.testing.expectEqual(@as(u8, 255), px[3]);
    var bits: [1]i32 = undefined;
    c.getIntegers(gl.ALPHA_BITS, &bits);
    try std.testing.expectEqual(@as(i32, 0), bits[0]);
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    try std.testing.expectEqual(wl.DRM_FORMAT_XRGB8888, Fake.shown.?.format);
    // (a window surface for a wl_egl_window that has one already)
    try std.testing.expect(egl.createWindowSurface(i32, d, config(false), &window, null) == null);
    try std.testing.expectEqual(egl.BAD_ALLOC, egl.getError());
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(egl.destroySurface(d, s));
    try std.testing.expect(egl.destroyContext(d, ctx));
    try std.testing.expect(egl.terminate(d));
}

test "egl: a compositor without dma-bufs is no display (the app draws in software)" {
    useDriver();
    world(8, 8);
    Fake.dmabuf_offered = false;
    const d = egl.getPlatformDisplay(egl.PLATFORM_WAYLAND_KHR, native_display).?;
    try std.testing.expect(!egl.initialize(d, null, null));
    try std.testing.expectEqual(egl.NOT_INITIALIZED, egl.getError());
    try std.testing.expectEqual(@as(u32, 0), Fake.queues);
    try std.testing.expectEqual(@as(usize, 2), Fake.live()); // (the display and surface: the test's)
}

test "egl: configs, contexts, current, syncs and their errors" {
    useDriver();
    const d = egl.getDisplay(null).?;
    try std.testing.expect(egl.initialize(d, null, null));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(egl.queryString(null, egl.EXTENSIONS).?), "EGL_KHR_platform_wayland") != null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(egl.queryString(d, egl.EXTENSIONS).?), "EGL_EXT_buffer_age") != null);
    // config choice: nothing asked of color, a depth buffer: XRGB first (the smaller buffer)
    var picked: [4]*const egl.Config = undefined;
    const n = egl.chooseConfigs(&[_]i32{ egl.RENDERABLE_TYPE, egl.OPENGL_ES2_BIT, egl.DEPTH_SIZE, 16, egl.NONE }, &picked).?;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, 3), picked[0].id);
    try std.testing.expectEqual(@as(i32, 1), picked[1].id);
    // ES 1 is not had; an attribute EGL lacks; the default RENDERABLE_TYPE (ES 1): none
    try std.testing.expectEqual(@as(usize, 0), egl.chooseConfigs(null, &picked).?);
    try std.testing.expect(egl.chooseConfigs(&[_]i32{ 0x1234, 0, egl.NONE }, &picked) == null);
    try std.testing.expectEqual(egl.BAD_ATTRIBUTE, egl.getError());
    try std.testing.expectEqual(@as(usize, 1), egl.chooseConfigs(&[_]i32{ egl.CONFIG_ID, 4, egl.RENDERABLE_TYPE, egl.OPENGL_ES_BIT, egl.NONE }, &picked).?);
    try std.testing.expect(egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 1, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());
    try std.testing.expect(egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.CONTEXT_MINOR_VERSION, 1, egl.NONE }) == null);
    // a no-config context, sharing its objects with a second one
    const a = egl.createContext(d, null, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.CONTEXT_OPENGL_ROBUST_ACCESS, 1, egl.CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY, egl.LOSE_CONTEXT_ON_RESET, egl.NONE }).?;
    const b = egl.createContext(d, config(false), a, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 2, egl.NONE }).?;
    try std.testing.expectEqual(a.share, b.share);
    // surfaceless current, a texture made in one seen by the other
    try std.testing.expect(egl.makeCurrent(d, null, null, a));
    var tex: [1]u32 = undefined;
    thread.gl().?.genTextures(&tex);
    thread.gl().?.bindTexture(gl.TEXTURE_2D, tex[0]);
    try std.testing.expect(egl.makeCurrent(d, null, null, b));
    try std.testing.expect(thread.gl().?.isTexture(tex[0]));
    // a fence: the work before it, waited for
    const pb = egl.createPbufferSurface(d, config(false), &[_]i32{ egl.WIDTH, 64, egl.HEIGHT, 64, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, pb, pb, b));
    thread.gl().?.clearColor(1, 1, 0, 1);
    thread.gl().?.clear(gl.COLOR_BUFFER_BIT);
    const sync = egl.createSync(i32, d, egl.SYNC_FENCE, null).?;
    try std.testing.expectEqual(egl.CONDITION_SATISFIED, egl.clientWaitSync(d, sync, 0, egl.FOREVER));
    try std.testing.expectEqual(egl.SIGNALED, egl.getSyncAttrib(d, sync, egl.SYNC_STATUS).?);
    try std.testing.expect(egl.waitSync(d, sync, 0));
    try std.testing.expect(egl.destroySync(d, sync));
    try std.testing.expect(egl.createSync(i32, d, 0x1234, null) == null);
    // a context of another color format cannot draw on it
    const c3 = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try std.testing.expect(!egl.makeCurrent(d, pb, pb, c3));
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());
    try std.testing.expect(egl.destroyContext(d, c3));
    // destroyed while current: gone at release
    try std.testing.expect(egl.destroySurface(d, pb));
    try std.testing.expect(egl.destroyContext(d, b));
    try std.testing.expectEqual(@as(?*anyopaque, b), egl.getCurrentContext());
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(!b.used);
    try std.testing.expect(egl.destroyContext(d, a));
    try std.testing.expect(egl.terminate(d));
    try std.testing.expect(egl.queryString(d, egl.VENDOR) == null);
    try std.testing.expectEqual(egl.NOT_INITIALIZED, egl.getError());
}
