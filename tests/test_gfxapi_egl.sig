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
//! compositor without dma-bufs, refused; zwp_linux_dmabuf_v1 version 4's
//! feedback (the format table mapped, its tranches read) and version 3's
//! events.
//!
//! Then EGLImages: a dma-buf of another program (an EmuDevice buffer,
//! imported zero-copy as the kernel's PRIME does) as a GL texture, an
//! external texture and a renderbuffer, read and drawn on the GPU, the
//! producer seeing the consumer's pixels; the image kept by GL after its
//! handle goes, freed with the last name; the errors EGL gives. And
//! native fences: one of the GPU work handed out, one handed in (polled,
//! owned, closed).

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
    var offered_version: u32 = 4;
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
    var feedbacks: u32 = 0;
    var table_closes: u32 = 0;
    var maps: u32 = 0;
    var unmaps: u32 = 0;
    var last_closed: i32 = -1;
    var fence_fds: u32 = 0;
    var fence_signaled = false;
    var imports: u32 = 0;

    // version 4's feedback: a format table (format, pad, modifier), the
    // render node 226:128, one tranche of all of it
    const TABLE_FD: i32 = 55;
    var table: [48]u8 = undefined;
    var dev_bytes = [8]u8{ 0x80, 0xe2, 0, 0, 0, 0, 0, 0 };
    var dev_array = wl.Array{ .size = 8, .alloc = 8, .data = &dev_bytes };
    var idx = [3]u16{ 0, 1, 2 };
    var idx_array = wl.Array{ .size = 6, .alloc = 6, .data = &idx };

    fn tableFill() void {
        const rows = [3]struct { u32, u64 }{ .{ wl.DRM_FORMAT_ARGB8888, 0 }, .{ wl.DRM_FORMAT_XRGB8888, 0 }, .{ wl.DRM_FORMAT_ARGB8888, 0x0100_0000_0000_0001 } };
        @memset(&table, 0);
        for (rows, 0..) |r, i| {
            std.mem.writeInt(u32, table[i * 16 ..][0..4], r[0], .little);
            std.mem.writeInt(u64, table[i * 16 + 8 ..][0..8], r[1], .little);
        }
    }

    fn reset() void {
        for (&proxies) |*p| p.* = .{};
        n_events = 0;
        queues = 0;
        dmabuf_offered = true;
        offered_version = 4;
        bound_version = 0;
        tableFill();
        flushes = 0;
        commits = 0;
        frames = 0;
        attached = null;
        shown = null;
        n_damage = 0;
        buffers_made = 0;
        buffers_destroyed = 0;
        closes = 0;
        feedbacks = 0;
        table_closes = 0;
        maps = 0;
        unmaps = 0;
        last_closed = -1;
        fence_fds = 0;
        fence_signaled = false;
        imports = 0;
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
            if (dmabuf_offered) post(out.?, 0, .{ .{ .u = 9 }, .{ .s = "zwp_linux_dmabuf_v1" }, .{ .u = offered_version }, .{ .u = 0 } });
        } else if (is(p, &registry_iface) and opcode == 0) { // bind
            std.debug.assert(args[0].u == 9);
            bound_version = version;
            // (version 4 tells its formats by feedback only, as Galaxy's bridge)
            if (version < 4) {
                post(out.?, 1, .{ .{ .u = wl.DRM_FORMAT_ARGB8888 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } });
                post(out.?, 1, .{ .{ .u = wl.DRM_FORMAT_XRGB8888 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } });
                // (a format with a tiled modifier only: not a linear one)
                post(out.?, 1, .{ .{ .u = 0x3231_4752 }, .{ .u = 0x0100_0000 }, .{ .u = 1 }, .{ .u = 0 } });
            }
        } else if (p.iface == &wl.dmabuf_interface and opcode == 2) { // get_default_feedback
            const f = out.?;
            post(f, 1, .{ .{ .h = TABLE_FD }, .{ .u = table.len }, .{ .u = 0 }, .{ .u = 0 } }); // format_table
            post(f, 2, .{ .{ .a = &dev_array }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }); // main_device
            post(f, 4, .{ .{ .a = &dev_array }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }); // tranche_target_device
            post(f, 5, .{ .{ .a = &idx_array }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }); // tranche_formats
            post(f, 6, .{ .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }); // tranche_flags
            post(f, 3, .{ .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }); // tranche_done
            post(f, 0, .{ .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = 0 } }); // done
            feedbacks += 1;
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
/// A dma-buf in: the EmuDevice buffer behind fd (200 + its handle),
/// mapped again for the GPU, zero-copy (as another program's PRIME import
/// would be: the same pages, a buffer of this context's).
fn importFd(ctx: ?*anyopaque, fd: i32) ?gpu.Buffer {
    _ = ctx;
    if (fd < 201 or fd - 201 >= emu.n_regions) return null;
    const rg = &emu.regions[@intCast(fd - 201)];
    if (!rg.live or rg.cpu.len == 0) return null;
    Fake.imports += 1;
    return emu.device().import(rg.cpu);
}
fn fenceFd(ctx: ?*anyopaque) i64 {
    _ = ctx;
    Fake.fence_fds += 1;
    return 400 + @as(i64, Fake.fence_fds);
}
fn closeFd(ctx: ?*anyopaque, fd: i32) void {
    _ = ctx;
    Fake.last_closed = fd;
    if (fd == Fake.TABLE_FD) Fake.table_closes += 1 else Fake.closes += 1;
}
fn dupFd(ctx: ?*anyopaque, fd: i32) i32 {
    _ = ctx;
    return fd + 1000;
}
fn pollFd(ctx: ?*anyopaque, fd: i32, ms: i32) i32 {
    _ = .{ ctx, fd, ms };
    return @intFromBool(Fake.fence_signaled);
}
fn mapFd(ctx: ?*anyopaque, fd: i32, size: usize) ?[]const u8 {
    _ = ctx;
    if (fd != Fake.TABLE_FD or size > Fake.table.len) return null;
    Fake.maps += 1;
    return Fake.table[0..size];
}
fn unmapFd(ctx: ?*anyopaque, s: []const u8) void {
    _ = .{ ctx, s };
    Fake.unmaps += 1;
}
const host = gfxapi.host.Host{ .exportFd = exportFd, .importFd = importFd, .fenceFd = fenceFd, .close = closeFd, .dup = dupFd, .poll = pollFd, .map = mapFd, .unmap = unmapFd };
fn client() ?*const wl.Client {
    return &Fake.client;
}

fn useDriver() void {
    egl.setDriver(.{ .open = open, .host = host, .wayland = client });
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
    // (version 4: the formats from the feedback's table, mapped, its fd
    // closed, the table let go and the feedback destroyed after)
    try std.testing.expectEqual(@as(u32, 4), Fake.bound_version);
    try std.testing.expect(d.wl.argb and d.wl.xrgb);
    try std.testing.expectEqual(@as(u32, 1), Fake.feedbacks);
    try std.testing.expectEqual(@as(u32, 1), Fake.maps);
    try std.testing.expectEqual(@as(u32, 1), Fake.unmaps);
    try std.testing.expectEqual(@as(u32, 1), Fake.table_closes);
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

/// Firefox's WebRender start on Wayland, as gfx/gl does it
/// (GLContextProviderEGL: CreateConfig, CreateSurfaceFromNativeWindow,
/// CreateGLContext with the robustness attributes first, GLContext::Init),
/// then its teardown when something fails (the context destroyed while
/// current, the display's last reference terminating it) and the second
/// try on the same wl_display.
fn firefoxStart() !struct { d: *egl.Display, s: *egl.Surface, c: *egl.Context } {
    const d = egl.getDisplay(native_display) orelse return error.NoDisplay;
    if (!egl.initialize(d, null, null)) return error.Initialize;
    if (!egl.bindApi(egl.OPENGL_ES_API)) return error.BindApi;
    // CreateConfig(32 bpp): RGBA 8888, a window, ES2; NONE, 0, 0, 0
    const attribs = [_]i32{ egl.SURFACE_TYPE, egl.WINDOW_BIT, egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 8, egl.RENDERABLE_TYPE, egl.OPENGL_ES2_BIT, egl.NONE, 0, 0, 0 };
    var cfgs: [64]?*const anyopaque = undefined;
    var n: i32 = 0;
    if (!egl.chooseConfig(d, &attribs, &cfgs, 64, &n) or n < 1) return error.ChooseConfig;
    var cfg: ?*const anyopaque = null;
    for (cfgs[0..@intCast(n)]) |cf| {
        var a: i32 = 0;
        if (egl.getConfigAttrib(d, cf, egl.ALPHA_SIZE, &a) and a == 8) {
            cfg = cf;
            break;
        }
    }
    const config_ = cfg orelse return error.NoRgba;
    const s = egl.createWindowSurface(i32, d, config_, &window, null) orelse return error.WindowSurface;
    // khr_rbab: ES 3, LOSE_CONTEXT_ON_RESET, the robust-access flag
    const rbab = [_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY, egl.LOSE_CONTEXT_ON_RESET, egl.CONTEXT_FLAGS_KHR, 4, egl.NONE, 0, 0, 0 };
    const c = egl.createContext(d, config_, null, &rbab) orelse return error.CreateContext;
    // GLContext::InitImpl: current, then no GL error pending, and the strings
    if (!egl.makeCurrent(d, s, s, c)) return error.MakeCurrent;
    const g = thread.gl() orelse return error.NotCurrent;
    if (g.getError() != gl.NO_ERROR) return error.PendingGlError;
    if (g.getString(gl.VERSION) == null or g.getString(gl.SHADING_LANGUAGE_VERSION) == null) return error.NoStrings;
    return .{ .d = d, .s = s, .c = c };
}

test "egl: Firefox's start on Wayland, its teardown while current, and its second try" {
    useDriver();
    world(64, 32);
    const base = Fake.live();
    const first = try firefoxStart();
    // glxtest's device query: the display's device, its render node
    var dev: isize = 0;
    try std.testing.expect(egl.queryDisplayAttrib(first.d, egl.DEVICE_EXT, &dev));
    const device: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(dev)));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(egl.queryDeviceString(device, egl.EXTENSIONS).?), "EGL_EXT_device_drm_render_node") != null);
    try std.testing.expectEqualStrings("/dev/dri/renderD128", std.mem.span(egl.queryDeviceString(device, egl.DRM_RENDER_NODE_FILE_EXT).?));
    try std.testing.expect(egl.queryDeviceString(device, egl.DRM_DEVICE_FILE_EXT) == null);
    var ndev: i32 = 0;
    try std.testing.expect(egl.queryDevices(0, null, &ndev));
    try std.testing.expectEqual(@as(i32, 1), ndev);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(egl.queryString(null, egl.EXTENSIONS).?), "EGL_EXT_device_query") != null);
    // the teardown after a failure: the context destroyed while still
    // current, the surface, then eglTerminate (the display's last ref)
    try std.testing.expect(egl.destroyContext(first.d, first.c));
    try std.testing.expect(egl.destroySurface(first.d, first.s));
    try std.testing.expect(egl.terminate(first.d));
    // the second try: the same wl_display, a new EGL display reference
    const second = try firefoxStart();
    try std.testing.expect(egl.makeCurrent(second.d, null, null, null));
    try std.testing.expect(egl.destroySurface(second.d, second.s));
    try std.testing.expect(egl.destroyContext(second.d, second.c));
    try std.testing.expect(egl.terminate(second.d));
    try std.testing.expectEqual(base, Fake.live());
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

test "egl: a version 3 compositor tells its formats by modifier events" {
    useDriver();
    world(8, 8);
    Fake.offered_version = 3;
    const d = egl.getPlatformDisplay(egl.PLATFORM_WAYLAND_KHR, native_display).?;
    try std.testing.expect(egl.initialize(d, null, null));
    try std.testing.expectEqual(@as(u32, 3), Fake.bound_version);
    try std.testing.expect(d.wl.argb and d.wl.xrgb);
    try std.testing.expectEqual(@as(u32, 0), Fake.feedbacks);
    try std.testing.expect(egl.terminate(d));
}

fn liveRegions() usize {
    var n: usize = 0;
    for (emu.regions[0..emu.n_regions]) |rg| n += @intFromBool(rg.live);
    return n;
}

fn rgbaAt(c: *gfxapi.gles.Context, x: i32, y: i32) [4]u8 {
    var px: [4]u8 = undefined;
    c.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &px);
    return px;
}

test "egl: a dma-buf as an EGLImage: a texture, an external texture, a renderbuffer, shared and freed with its last name" {
    useDriver();
    Fake.reset();
    const d = egl.getDisplay(null).?;
    try std.testing.expect(egl.initialize(d, null, null));
    const ctx = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    const pb = egl.createPbufferSurface(d, config(true), &[_]i32{ egl.WIDTH, 4, egl.HEIGHT, 4, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, pb, pb, ctx));
    const c = thread.gl().?;
    // another program's picture: 16 x 8 BGRA (ARGB8888), a pattern
    var prod = eng.newImage(16, 8, .bgra8).?;
    var src: [16 * 8 * 4]u8 = undefined;
    for (&src, 0..) |*p, i| p.* = @truncate(i * 5 + 1);
    eng.write(&prod, 0, 0, 16, 8, &src, 64, .bgra8);
    const fd: i32 = @intCast(exportFd(null, prod.buf));
    const base = liveRegions();
    const argb: i32 = @bitCast(wl.DRM_FORMAT_ARGB8888);
    const attribs = [_]i32{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0, egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0, egl.NONE };
    const img = egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &attribs).?;
    try std.testing.expectEqual(@as(u32, 1), Fake.imports);
    try std.testing.expectEqual(base + 1, liveRegions());

    // as a texture, in a framebuffer object: read, then drawn on the GPU
    var tex: [2]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(gl.TEXTURE_2D, tex[0]);
    c.eglImageTargetTexture2D(gl.TEXTURE_2D, img);
    try std.testing.expectEqual(gl.NO_ERROR, c.getError());
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(gl.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex[0], 0);
    try std.testing.expectEqual(gl.FRAMEBUFFER_COMPLETE, c.checkFramebufferStatus(gl.FRAMEBUFFER));
    // (GL row 2 is the buffer's row 2: B, G, R, A in memory, read as RGBA)
    const at = (2 * 16 + 3) * 4;
    try std.testing.expectEqual([4]u8{ src[at + 2], src[at + 1], src[at], src[at + 3] }, rgbaAt(c, 3, 2));
    c.enable(gl.SCISSOR_TEST, true);
    c.scissorSet(0, 0, 4, 4);
    c.clearColor(0, 1, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    c.enable(gl.SCISSOR_TEST, false);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(c, 1, 1));
    // the producer's memory is the same pages: what the GPU wrote, once
    // fetched for the CPU (pixel 1, 1: the one read), is in it
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, prod.buf.cpu[(1 * 16 + 1) * 4 ..][0..4]);

    // the handle goes; the texture keeps the memory
    try std.testing.expect(egl.destroyImage(d, img));
    try std.testing.expectEqual(base + 1, liveRegions());
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(c, 2, 3));
    c.bindTexture(gl.TEXTURE_EXTERNAL_OES, tex[1]);
    c.eglImageTargetTexture2D(gl.TEXTURE_EXTERNAL_OES, img);
    try std.testing.expectEqual(gl.INVALID_VALUE, c.getError()); // (a handle destroyed)

    // a second image of it: an external texture, a renderbuffer
    const img2 = egl.createImage(isize, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]isize{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.NONE }).?;
    c.eglImageTargetTexture2D(gl.TEXTURE_EXTERNAL_OES, img2);
    try std.testing.expectEqual(gl.NO_ERROR, c.getError());
    var ib: [1]i32 = undefined;
    c.getIntegers(gl.TEXTURE_BINDING_EXTERNAL_OES, &ib);
    try std.testing.expectEqual(@as(i32, @intCast(tex[1])), ib[0]);
    c.texImage2D(gl.TEXTURE_EXTERNAL_OES, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    try std.testing.expectEqual(gl.INVALID_ENUM, c.getError());
    c.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex[1], 0);
    try std.testing.expectEqual(gl.INVALID_OPERATION, c.getError());
    var rb: [1]u32 = undefined;
    c.genRenderbuffers(&rb);
    c.bindRenderbuffer(gl.RENDERBUFFER, rb[0]);
    c.eglImageTargetRenderbufferStorage(gl.RENDERBUFFER, img2);
    c.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, rb[0]);
    try std.testing.expectEqual(gl.FRAMEBUFFER_COMPLETE, c.checkFramebufferStatus(gl.FRAMEBUFFER));
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, rgbaAt(c, 15, 7));
    try std.testing.expectEqual(gl.NO_ERROR, c.getError());

    // every name gone: both imports freed
    try std.testing.expectEqual(base + 2, liveRegions());
    c.deleteFramebuffers(&fb);
    c.deleteRenderbuffers(&rb);
    c.deleteTextures(&tex);
    try std.testing.expectEqual(base + 1, liveRegions()); // (img2's handle holds it yet)
    try std.testing.expect(egl.destroyImage(d, img2));
    c.finish();
    try std.testing.expectEqual(base, liveRegions());

    // what EGL refuses
    const Bad = struct {
        fn image(dd: *egl.Display, list: []const i32) ?*egl.EImage {
            return egl.createImage(i32, dd, null, egl.LINUX_DMA_BUF_EXT, null, list.ptr);
        }
    };
    try std.testing.expect(egl.createImage(i32, d, ctx, egl.LINUX_DMA_BUF_EXT, null, &attribs) == null);
    try std.testing.expectEqual(egl.BAD_PARAMETER, egl.getError());
    try std.testing.expect(Bad.image(d, &.{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_PARAMETER, egl.getError()); // (no fd)
    try std.testing.expect(Bad.image(d, &.{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, 0x3231_564e, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError()); // (NV12)
    try std.testing.expect(Bad.image(d, &.{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT, 1, egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0x0100_0000, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError()); // (tiled)
    try std.testing.expect(Bad.image(d, &.{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 32, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError()); // (rows shorter than the width)
    try std.testing.expect(Bad.image(d, &.{ egl.WIDTH, 16, egl.HEIGHT, 4000, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError()); // (larger than the buffer)
    try std.testing.expectEqual(base, liveRegions()); // (its import let go)
    try std.testing.expect(Bad.image(d, &.{ egl.WIDTH, 16, egl.HEIGHT, 8, egl.LINUX_DRM_FOURCC_EXT, argb, egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, 0x3275, fd, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ATTRIBUTE, egl.getError()); // (a second plane)

    // the formats and modifiers it takes
    var formats: [8]i32 = undefined;
    var n: i32 = 0;
    try std.testing.expect(egl.queryDmaBufFormats(d, 8, &formats, &n));
    try std.testing.expectEqual(@as(i32, 4), n);
    var mods: [4]u64 = undefined;
    var ext: [4]u32 = undefined;
    try std.testing.expect(egl.queryDmaBufModifiers(d, argb, 4, &mods, &ext, &n));
    try std.testing.expectEqual(@as(i32, 1), n);
    try std.testing.expectEqual(@as(u64, 0), mods[0]);
    try std.testing.expectEqual(egl.FALSE, ext[0]);
    try std.testing.expect(!egl.queryDmaBufModifiers(d, 0x3231_564e, 4, &mods, &ext, &n));

    eng.freeImage(&prod);
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(egl.destroySurface(d, pb));
    try std.testing.expect(egl.destroyContext(d, ctx));
    try std.testing.expect(egl.terminate(d));
}

test "egl: native fences: one of the GPU's work handed out, one handed in" {
    useDriver();
    Fake.reset();
    const d = egl.getDisplay(null).?;
    try std.testing.expect(egl.initialize(d, null, null));
    const ctx = egl.createContext(d, null, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, null, null, ctx));
    // out: a sync_file of the work so far, each dup a new one
    const out = egl.createSync(i32, d, egl.SYNC_NATIVE_FENCE_ANDROID, null).?;
    try std.testing.expectEqual(@as(i32, 401), egl.dupNativeFenceFd(d, out));
    try std.testing.expectEqual(@as(i32, 402), egl.dupNativeFenceFd(d, out));
    try std.testing.expectEqual(@as(i32, @intCast(egl.SYNC_NATIVE_FENCE_ANDROID)), egl.getSyncAttrib(d, out, egl.SYNC_TYPE).?);
    try std.testing.expectEqual(egl.CONDITION_SATISFIED, egl.clientWaitSync(d, out, 0, egl.FOREVER));
    try std.testing.expect(egl.destroySync(d, out));
    // in: a sync_file, owned by the sync, polled, closed with it
    const in = egl.createSync(isize, d, egl.SYNC_NATIVE_FENCE_ANDROID, &[_]isize{ egl.SYNC_NATIVE_FENCE_FD_ANDROID, 77, egl.NONE }).?;
    try std.testing.expectEqual(egl.SYNC_NATIVE_FENCE_SIGNALED_ANDROID, egl.getSyncAttrib(d, in, egl.SYNC_CONDITION).?);
    try std.testing.expectEqual(egl.UNSIGNALED, egl.getSyncAttrib(d, in, egl.SYNC_STATUS).?);
    try std.testing.expectEqual(egl.TIMEOUT_EXPIRED, egl.clientWaitSync(d, in, 0, 0));
    Fake.fence_signaled = true;
    try std.testing.expectEqual(egl.CONDITION_SATISFIED, egl.clientWaitSync(d, in, 0, egl.FOREVER));
    try std.testing.expectEqual(egl.SIGNALED, egl.getSyncAttrib(d, in, egl.SYNC_STATUS).?);
    try std.testing.expect(egl.waitSync(d, in, 0));
    try std.testing.expectEqual(@as(i32, 1077), egl.dupNativeFenceFd(d, in));
    try std.testing.expect(egl.destroySync(d, in));
    try std.testing.expectEqual(@as(i32, 77), Fake.last_closed);
    // a plain fence is no file; a native fd on a plain fence is no attribute
    const plain = egl.createSync(i32, d, egl.SYNC_FENCE, null).?;
    try std.testing.expectEqual(egl.NO_NATIVE_FENCE_FD_ANDROID, egl.dupNativeFenceFd(d, plain));
    try std.testing.expectEqual(egl.BAD_PARAMETER, egl.getError());
    try std.testing.expect(egl.destroySync(d, plain));
    try std.testing.expect(egl.createSync(i32, d, egl.SYNC_FENCE, &[_]i32{ egl.SYNC_NATIVE_FENCE_FD_ANDROID, 3, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ATTRIBUTE, egl.getError());
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(egl.destroyContext(d, ctx));
    try std.testing.expect(egl.terminate(d));
}
