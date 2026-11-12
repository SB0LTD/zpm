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
//! handle goes, freed with the last name; the errors EGL gives. A video
//! picture's planes (NV12's R8 and GR88, P010's R16 and GR1616) imported
//! one by one at their offsets in one buffer, sampled by a program. A
//! texture as an EGLImage (EGL_KHR_gl_texture_2D_image), its dma-buf
//! exported (EGL_MESA_image_dma_buf_export) and imported again, drawn into
//! there and seen here (Firefox's dma-buf surfaces and WebGL on them). And
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
const program = gfxapi.program;
/// (zpm src/va's: the layout the VA driver's pictures are in)
const tiling = @import("va_tiling");

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
    var export_failures: u32 = 0;

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

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
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
    if (Fake.export_failures != 0) {
        Fake.export_failures -= 1;
        return -12;
    }
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
    Fake.export_failures = 0;
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

test "egl: a transient window export failure retries and a persistent failure drops the old draw target" {
    useDriver();
    world(32, 16);
    const session = try firefoxStart();
    const d = session.d;
    const s = session.s;
    const ctx = session.c;
    const c = thread.gl().?;
    defer {
        _ = egl.makeCurrent(d, null, null, null);
        _ = egl.destroySurface(d, s);
        _ = egl.destroyContext(d, ctx);
        _ = egl.terminate(d);
    }

    Fake.export_failures = 1;
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    try std.testing.expectEqual(@as(u32, 0), Fake.export_failures);
    try std.testing.expect(c.surf_draw != null);
    try std.testing.expect(c.surf_draw.? != &s.win.bufs[0].img);

    window.width = 48;
    window.height = 24;
    window.resize_callback.?(&window, window.driver_private);
    Fake.export_failures = 2;
    try std.testing.expect(!egl.swapBuffers(d, s, &.{}));
    try std.testing.expectEqual(egl.BAD_ALLOC, egl.getError());
    try std.testing.expect(c.surf_draw == null and c.surf_read == null);
    try std.testing.expectEqual(@as(u32, 0), Fake.export_failures);

    try std.testing.expect(egl.makeCurrent(d, s, s, ctx));
    try std.testing.expectEqual(@as(u32, 48), c.surf_draw.?.width);
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

var fake_us: u64 = 0;
fn fakeClock() u64 {
    return fake_us;
}

var said: [2048]u8 = undefined;
var said_len: usize = 0;
fn hear(line: []const u8) void {
    const n = @min(line.len, said.len - said_len);
    @memcpy(said[said_len..][0..n], line[0..n]);
    said_len += n;
}

test "egl: a context's swaps are in its usage line, one line in five seconds" {
    const report = gfxapi.report;
    useDriver();
    world(16, 8);
    const d = egl.getPlatformDisplay(egl.PLATFORM_WAYLAND_KHR, native_display).?;
    try std.testing.expect(egl.initialize(d, null, null));
    // (as Firefox asks for WebRender's context: ES 3, lost on a reset)
    const ctx = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT, egl.LOSE_CONTEXT_ON_RESET, egl.NONE }).?;
    const s = egl.createWindowSurface(i32, d, config(true), &window, null).?;
    try std.testing.expect(egl.makeCurrent(d, s, s, ctx));
    try std.testing.expect(egl.swapInterval(d, 0));
    const c = thread.gl().?;
    said_len = 0;
    report.sink = &hear;
    defer report.sink = null;
    const real_clock = report.clock;
    report.clock = &fakeClock;
    defer report.clock = real_clock;
    fake_us = 10_000_000;
    c.clearColor(1, 0, 0, 1);
    // the first swap begins the time counted; two more in the next four
    // seconds say nothing (the fake compositor keeps eight swaps' damage:
    // seven in all here)
    for (0..3) |_| {
        c.clear(gl.COLOR_BUFFER_BIT);
        try std.testing.expect(egl.swapBuffers(d, s, &.{}));
        fake_us += 1_300_000;
    }
    try std.testing.expectEqual(@as(usize, 0), said_len);
    // past five seconds: the line, with every swap so far
    fake_us = 15_100_000;
    c.clear(gl.COLOR_BUFFER_BIT);
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    const line = said[0..said_len];
    std.debug.print("{s}", .{line});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, " (ES 3 asked, robust) in 5.1 s on the GPU (") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "): 4 swaps (0 ms in them); 0 draws (") != null);
    // the swaps of the next four seconds: no second line
    for (0..2) |_| {
        fake_us += 2_000_000;
        c.clear(gl.COLOR_BUFFER_BIT);
        try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said[0..said_len], "\n"));
    // then the second, with those two and this one
    fake_us = 20_200_000;
    try std.testing.expect(egl.swapBuffers(d, s, &.{}));
    const both = said[0..said_len];
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, both, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, both[line.len..], " in 5.1 s on the GPU (") != null);
    try std.testing.expect(std.mem.indexOf(u8, both[line.len..], "): 3 swaps (") != null);
    report.sink = null;
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

fn noNativeInterop() bool {
    return false;
}

test "egl: a backend without native interop still exposes window buffers and EGL fences" {
    egl.setDriver(.{ .open = open, .host = host, .wayland = client, .native_interop = noNativeInterop });
    defer useDriver();
    world(32, 16);
    const session = try firefoxStart();
    const d = session.d;
    defer {
        _ = egl.makeCurrent(d, null, null, null);
        _ = egl.destroySurface(d, session.s);
        _ = egl.destroyContext(d, session.c);
        _ = egl.terminate(d);
    }
    const ext = std.mem.span(egl.queryString(d, egl.EXTENSIONS).?);
    for ([_][]const u8{ "EGL_ANDROID_native_fence_sync", "EGL_EXT_image_dma_buf_import", "EGL_MESA_image_dma_buf_export", "EGL_KHR_image_base" }) |name|
        try std.testing.expect(std.mem.indexOf(u8, ext, name) == null);
    try std.testing.expect(std.mem.indexOf(u8, ext, "EGL_KHR_fence_sync") != null);
    const fence = egl.createSync(i32, d, egl.SYNC_FENCE, null).?;
    try std.testing.expect(egl.destroySync(d, fence));
    try std.testing.expect(egl.createSync(i32, d, egl.SYNC_NATIVE_FENCE_ANDROID, null) == null);
    try std.testing.expectEqual(egl.BAD_ATTRIBUTE, egl.getError());
    var count: i32 = -1;
    try std.testing.expect(!egl.queryDmaBufFormats(d, 0, null, &count));
    try std.testing.expectEqual(egl.BAD_PARAMETER, egl.getError());
    try std.testing.expect(egl.swapBuffers(d, session.s, &.{}));
    try std.testing.expectEqual(@as(u32, 1), Fake.commits);
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
    try std.testing.expectEqual(@as(i32, 8), n);
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

// ── A video picture's planes; a texture's dma-buf out and in again ────────

const plane_vs: [:0]const u8 =
    \\#version 300 es
    \\in vec2 aPos;
    \\void main() { gl_Position = vec4(aPos * 2.0 - 1.0, 0.0, 1.0); }
;

const plane_fs: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uTex;
    \\uniform int uMode;
    \\out vec4 o;
    \\void main() {
    \\    ivec2 p = ivec2(gl_FragCoord.xy);
    \\    if (uMode == 0) {
    \\        o = texelFetch(uTex, p, 0);
    \\    } else {
    \\        o = texture(uTex, (vec2(p) + 0.5) / vec2(textureSize(uTex, 0)));
    \\    }
    \\}
;

/// The program drawing each texel of unit 0's texture once (a quad over
/// the viewport), in use, its quad bound.
fn planeProgram(c: *gfxapi.gles.Context) !u32 {
    const v = program.createShader(c, gl.VERTEX_SHADER);
    const f = program.createShader(c, gl.FRAGMENT_SHADER);
    for ([_]u32{ v, f }, [_][:0]const u8{ plane_vs, plane_fs }) |s, src| {
        const parts = [_]?[*]const u8{src.ptr};
        program.shaderSource(c, s, 1, &parts, null);
        program.compileShader(c, s);
    }
    const p = program.createProgram(c);
    program.attachShader(c, p, v);
    program.attachShader(c, p, f);
    program.linkProgram(c, p);
    var linked: i32 = 0;
    program.getProgramiv(c, p, gl.LINK_STATUS, &linked);
    if (linked != 1) {
        var log: [512]u8 = undefined;
        var len: i32 = 0;
        program.getProgramInfoLog(c, p, log.len, &len, &log);
        std.debug.print("plane program: {s}\n", .{log[0..@intCast(len)]});
        return error.Link;
    }
    program.useProgram(c, p);
    const unit0 = [_]i32{0};
    program.uniform(c, program.getUniformLocation(c, p, "uTex"), 1, 1, .i, @ptrCast(&unit0));
    var vao: [1]u32 = undefined;
    c.genVertexArrays(&vao);
    c.bindVertexArray(vao[0]);
    var buf: [1]u32 = undefined;
    c.genBuffers(&buf);
    const quad = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    c.bindBuffer(gl.ARRAY_BUFFER, buf[0]);
    c.bufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, gl.STATIC_DRAW);
    c.vertexAttribPointer(0, 2, gl.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(0, true);
    return p;
}

/// Unit 0's texture drawn texel for pixel into a w x h RGBA8 framebuffer
/// (mode 0: texelFetch; 1: texture(), nearest), read back as RGBA bytes.
fn drawPlane(c: *gfxapi.gles.Context, p: u32, mode: i32, w: i32, h: i32, out: []u8) !void {
    var color: [1]u32 = undefined;
    c.genTextures(&color);
    c.activeTexture(gl.TEXTURE0 + 1);
    c.bindTexture(gl.TEXTURE_2D, color[0]);
    c.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, w, h);
    c.activeTexture(gl.TEXTURE0);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(gl.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color[0], 0);
    if (c.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, w, h);
    const m = [_]i32{mode};
    program.uniform(c, program.getUniformLocation(c, p, "uMode"), 1, 1, .i, @ptrCast(&m));
    c.drawArrays(gl.TRIANGLES, 0, 6, 1);
    c.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, out.ptr);
    c.bindFramebuffer(gl.FRAMEBUFFER, 0);
    c.deleteFramebuffers(&fb);
    c.deleteTextures(&color);
}

/// A unorm16 as the unorm8 a draw writes of it (v / 65535, rounded).
fn to8(v: u16) u8 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * 255.0 / 65535.0));
}

/// 16-bit samples whose unorm8 is neither their high nor their low byte:
/// a plane read a byte a channel, or its bytes swapped, draws otherwise.
const y16 = [8]u16{ 0x12f0, 0x40ff, 0x00c8, 0xe000, 0xffff, 0x0000, 0x9d00, 0x2bd0 };
const uv16 = [4]u16{ 0x40ff, 0x12f0, 0xe000, 0x00c8 };

fn planeImage(d: *egl.Display, fourcc: u32, fd: i32, w: i32, h: i32, offset: i32) ?*egl.EImage {
    return egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]i32{
        egl.WIDTH,                          w,                egl.HEIGHT,                         h,
        egl.LINUX_DRM_FOURCC_EXT,           @bitCast(fourcc), egl.DMA_BUF_PLANE0_FD_EXT,          fd,
        egl.DMA_BUF_PLANE0_OFFSET_EXT,      offset,           egl.DMA_BUF_PLANE0_PITCH_EXT,       64,
        egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0,                egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0,
        egl.NONE,
    });
}

test "egl: a video picture's planes as EGLImages (NV12: R8 and GR88; P010: R16 and GR1616), sampled" {
    useDriver();
    Fake.reset();
    const d = egl.getDisplay(null).?;
    try std.testing.expect(egl.initialize(d, null, null));
    const ctx = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    const pb = egl.createPbufferSurface(d, config(true), &[_]i32{ egl.WIDTH, 8, egl.HEIGHT, 4, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, pb, pb, ctx));
    const c = thread.gl().?;
    const p = try planeProgram(c);

    // the decoder's surface: one buffer, rows of 64 bytes (a pitch-linear
    // VA surface), its planes at offsets: NV12's Y (8 x 4 bytes) at 0, its
    // UV (4 x 2 pairs) at 256; P010's Y (4 x 2 halves) at 384, its UV (2 x 1
    // pairs of halves) at 512
    var bytes = [_]u8{0} ** 640;
    for (0..4) |y| {
        for (0..8) |x| bytes[y * 64 + x] = @intCast(7 + 31 * x + 5 * y);
    }
    for (0..2) |y| {
        for (0..4) |x| {
            bytes[256 + y * 64 + x * 2] = @intCast(20 + 50 * x + 9 * y);
            bytes[256 + y * 64 + x * 2 + 1] = @intCast(240 - 45 * x - 13 * y);
        }
    }
    for (0..2) |y| {
        for (0..4) |x| std.mem.writeInt(u16, bytes[384 + y * 64 + x * 2 ..][0..2], y16[y * 4 + x], .little);
    }
    for (0..2) |i| {
        std.mem.writeInt(u16, bytes[512 + i * 4 ..][0..2], uv16[i * 2], .little);
        std.mem.writeInt(u16, bytes[512 + i * 4 + 2 ..][0..2], uv16[i * 2 + 1], .little);
    }
    var surf = eng.newWindowImage(16, 10, .bgra8).?;
    eng.write(&surf, 0, 0, 16, 10, &bytes, 64, .bgra8);
    const fd: i32 = @intCast(exportFd(null, surf.buf));
    const base = liveRegions();

    const y8 = planeImage(d, egl.DRM_FORMAT_R8, fd, 8, 4, 0).?;
    const uv8 = planeImage(d, egl.DRM_FORMAT_GR88, fd, 4, 2, 256).?;
    const y10 = planeImage(d, egl.DRM_FORMAT_R16, fd, 4, 2, 384).?;
    const uv10 = planeImage(d, egl.DRM_FORMAT_GR1616, fd, 2, 1, 512).?;
    try std.testing.expectEqual(base + 4, liveRegions());

    var tex: [4]u32 = undefined;
    c.genTextures(&tex);
    const planes = [_]*egl.EImage{ y8, uv8, y10, uv10 };
    const sizes = [_][2]i32{ .{ 8, 4 }, .{ 4, 2 }, .{ 4, 2 }, .{ 2, 1 } };
    var got: [8 * 4 * 4]u8 = undefined;
    for (planes, sizes, tex, 0..) |img, size, t, i| {
        c.activeTexture(gl.TEXTURE0);
        c.bindTexture(gl.TEXTURE_2D, t);
        c.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        c.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        c.eglImageTargetTexture2D(gl.TEXTURE_2D, img);
        try std.testing.expectEqual(gl.NO_ERROR, c.getError());
        for ([_]i32{ 0, 1 }) |mode| {
            const w: usize = @intCast(size[0]);
            const h: usize = @intCast(size[1]);
            try drawPlane(c, p, mode, size[0], size[1], got[0 .. w * h * 4]);
            try std.testing.expectEqual(gl.NO_ERROR, c.getError());
            for (0..h) |y| {
                for (0..w) |x| {
                    const want: [4]u8 = switch (i) {
                        0 => .{ bytes[y * 64 + x], 0, 0, 255 },
                        1 => .{ bytes[256 + y * 64 + x * 2], bytes[256 + y * 64 + x * 2 + 1], 0, 255 },
                        2 => .{ to8(y16[y * 4 + x]), 0, 0, 255 },
                        else => .{ to8(uv16[x * 2]), to8(uv16[x * 2 + 1]), 0, 255 },
                    };
                    const at = (y * w + x) * 4;
                    if (!std.mem.eql(u8, &want, got[at..][0..4])) {
                        std.debug.print("plane {d} mode {d} texel ({d}, {d}): {any}, not {any}\n", .{ i, mode, x, y, got[at..][0..4], want });
                        return error.Plane;
                    }
                }
            }
        }
    }

    // a unorm16 plane is sampled, never drawn into
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(gl.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex[2], 0);
    try std.testing.expect(c.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE);
    var rb: [1]u32 = undefined;
    c.genRenderbuffers(&rb);
    c.bindRenderbuffer(gl.RENDERBUFFER, rb[0]);
    c.eglImageTargetRenderbufferStorage(gl.RENDERBUFFER, y10);
    try std.testing.expectEqual(gl.INVALID_OPERATION, c.getError());
    c.bindFramebuffer(gl.FRAMEBUFFER, 0);
    c.deleteFramebuffers(&fb);
    c.deleteRenderbuffers(&rb);

    // the formats and their modifiers: linear, and NVIDIA's block-linear
    // GOB_2 ones (Turing's, GB20x's 8- and 16-bit sector layouts)
    var formats: [8]i32 = undefined;
    var n: i32 = 0;
    try std.testing.expect(egl.queryDmaBufFormats(d, 8, &formats, &n));
    try std.testing.expectEqual(@as(i32, 8), n);
    var mods: [4]u64 = undefined;
    try std.testing.expect(egl.queryDmaBufModifiers(d, @bitCast(egl.DRM_FORMAT_GR1616), 4, &mods, null, &n));
    try std.testing.expectEqual(@as(i32, 4), n);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0x0300_0000_0060_6011, 0x0300_0000_0420_6011, 0x0300_0000_0460_6011 }, &mods);
    try std.testing.expect(egl.queryDmaBufModifiers(d, @bitCast(egl.DRM_FORMAT_R8), 0, null, null, &n));
    try std.testing.expectEqual(@as(i32, 4), n);
    // what a plane's import refuses: a block-linear layout of Tegra's
    // (16Bx2: GOB kind 0, sector layout 0), rows short of the width (a
    // GR1616 row of 2 is 8 bytes), rows of part words
    try std.testing.expect(egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]i32{ egl.WIDTH, 4, egl.HEIGHT, 2, egl.LINUX_DRM_FOURCC_EXT, @bitCast(egl.DRM_FORMAT_R8), egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 64, egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0x14, egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0x0300_0000, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());
    try std.testing.expect(egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]i32{ egl.WIDTH, 2, egl.HEIGHT, 1, egl.LINUX_DRM_FOURCC_EXT, @bitCast(egl.DRM_FORMAT_GR1616), egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 4, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError());
    try std.testing.expect(egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]i32{ egl.WIDTH, 3, egl.HEIGHT, 1, egl.LINUX_DRM_FOURCC_EXT, @bitCast(egl.DRM_FORMAT_R8), egl.DMA_BUF_PLANE0_FD_EXT, fd, egl.DMA_BUF_PLANE0_OFFSET_EXT, 0, egl.DMA_BUF_PLANE0_PITCH_EXT, 3, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError());

    // every name gone: every import let go
    // (the draws' own buffers, the program's, stay with the context)
    c.finish();
    const live = liveRegions();
    c.deleteTextures(&tex);
    try std.testing.expectEqual(live, liveRegions()); // (the images hold them)
    for (planes) |img| try std.testing.expect(egl.destroyImage(d, img));
    c.finish();
    try std.testing.expectEqual(live - 4, liveRegions());
    eng.freeImage(&surf);
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(egl.destroySurface(d, pb));
    try std.testing.expect(egl.destroyContext(d, ctx));
    try std.testing.expect(egl.terminate(d));
}

/// One plane of a VA surface as Galaxy's VA driver exports it: block
/// linear, its modifier, `pitch` bytes across.
fn blockPlaneImage(d: *egl.Display, fourcc: u32, fd: i32, w: i32, h: i32, offset: i32, pitch: i32, modifier: u64) ?*egl.EImage {
    return egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]i32{
        egl.WIDTH,                          w,                                         egl.HEIGHT,                         h,
        egl.LINUX_DRM_FOURCC_EXT,           @bitCast(fourcc),                          egl.DMA_BUF_PLANE0_FD_EXT,          fd,
        egl.DMA_BUF_PLANE0_OFFSET_EXT,      offset,                                    egl.DMA_BUF_PLANE0_PITCH_EXT,       pitch,
        egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT, @bitCast(@as(u32, @truncate(modifier))), egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT, @bitCast(@as(u32, @truncate(modifier >> 32))),
        egl.NONE,
    });
}

var bl_bytes: [224 * 64]u8 = undefined;
var bl_got: [37 * 21 * 4]u8 = undefined;

test "egl: a VA surface's block-linear planes (NV12, P010) imported with NVIDIA's modifiers, sampled texel by texel" {
    useDriver();
    Fake.reset();
    const d = egl.getDisplay(null).?;
    try std.testing.expect(egl.initialize(d, null, null));
    const ctx = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    const pb = egl.createPbufferSurface(d, config(true), &[_]i32{ egl.WIDTH, 8, egl.HEIGHT, 4, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, pb, pb, ctx));
    const c = thread.gl().?;
    const p = try planeProgram(c);

    // A 37 x 21 picture, NV12 then P010, laid out as the VA driver's
    // surfaces are (va's tiling.Nv12: Y, then UV at a 4 KiB boundary) and
    // tiled by va's tiling.sig in GB20x's layouts (Y 8 bpp, UV 16; P010:
    // Y 16, UV 32 = Turing's), in one buffer: NV12 at 0, P010 at 8 KiB.
    const w = 37;
    const h = 21;
    const cw = 19;
    const ch = 11;
    @memset(&bl_bytes, 0);
    const nv = tiling.Nv12.of(w, h);
    const p10 = tiling.Nv12.p010(w, h);
    const p10_at: usize = 8192;
    var y8: [w * h]u8 = undefined;
    var uv8: [cw * 2 * ch]u8 = undefined;
    var y16b: [w * 2 * h]u8 = undefined;
    var uv16b: [cw * 4 * ch]u8 = undefined;
    for (&y8, 0..) |*b, i| b.* = @truncate(i * 7 + (i >> 3) * 13);
    for (&uv8, 0..) |*b, i| b.* = @truncate((i *% 11) ^ 0xff);
    for (0..w * h) |i| std.mem.writeInt(u16, y16b[i * 2 ..][0..2], @truncate(i * 0x9e3 + 0x10f), .little);
    for (0..cw * 2 * ch) |i| std.mem.writeInt(u16, uv16b[i * 2 ..][0..2], @truncate((i *% 0x7b1) ^ 0xffff), .little);
    const sw8 = nv.swizzles(.blackwell);
    const sw10 = p10.swizzles(.blackwell);
    tiling.tile(bl_bytes[0..], nv.luma, sw8[0], &y8, w, w, h);
    tiling.tile(bl_bytes[@intCast(nv.chroma_offset)..], nv.chroma, sw8[1], &uv8, cw * 2, cw * 2, ch);
    tiling.tile(bl_bytes[p10_at..], p10.luma, sw10[0], &y16b, w * 2, w * 2, h);
    tiling.tile(bl_bytes[p10_at + @as(usize, @intCast(p10.chroma_offset)) ..], p10.chroma, sw10[1], &uv16b, cw * 4, cw * 4, ch);
    try std.testing.expect(p10_at + p10.bytes <= bl_bytes.len);
    var surf = eng.newWindowImage(16, 224, .bgra8).?;
    eng.write(&surf, 0, 0, 16, 224, &bl_bytes, 64, .bgra8);
    const fd: i32 = @intCast(exportFd(null, surf.buf));

    const planes = [_]*egl.EImage{
        blockPlaneImage(d, egl.DRM_FORMAT_R8, fd, w, h, 0, @intCast(nv.luma.pitch), tiling.modifierOf(sw8[0])).?,
        blockPlaneImage(d, egl.DRM_FORMAT_GR88, fd, cw, ch, @intCast(nv.chroma_offset), @intCast(nv.chroma.pitch), tiling.modifierOf(sw8[1])).?,
        blockPlaneImage(d, egl.DRM_FORMAT_R16, fd, w, h, @intCast(p10_at), @intCast(p10.luma.pitch), tiling.modifierOf(sw10[0])).?,
        blockPlaneImage(d, egl.DRM_FORMAT_GR1616, fd, cw, ch, @intCast(p10_at + p10.chroma_offset), @intCast(p10.chroma.pitch), tiling.modifierOf(sw10[1])).?,
    };
    // (the modifier comes back out: EGL_MESA_image_dma_buf_export)
    var fourcc: i32 = 0;
    var np: i32 = 0;
    var m: u64 = 0;
    try std.testing.expect(egl.exportDmaBufQuery(d, planes[1], &fourcc, &np, &m));
    try std.testing.expectEqual(tiling.modifierOf(.blackwell16), m);
    const sizes = [_][2]usize{ .{ w, h }, .{ cw, ch }, .{ w, h }, .{ cw, ch } };
    var tex: [4]u32 = undefined;
    c.genTextures(&tex);
    for (planes, sizes, tex, 0..) |img, size, t, i| {
        c.activeTexture(gl.TEXTURE0);
        c.bindTexture(gl.TEXTURE_2D, t);
        c.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        c.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        c.eglImageTargetTexture2D(gl.TEXTURE_2D, img);
        try std.testing.expectEqual(gl.NO_ERROR, c.getError());
        for ([_]i32{ 0, 1 }) |mode| {
            const pw = size[0];
            const ph = size[1];
            try drawPlane(c, p, mode, @intCast(pw), @intCast(ph), bl_got[0 .. pw * ph * 4]);
            try std.testing.expectEqual(gl.NO_ERROR, c.getError());
            for (0..ph) |y| {
                for (0..pw) |x| {
                    const r16 = struct {
                        fn at(b: []const u8, k: usize) u16 {
                            return std.mem.readInt(u16, b[k * 2 ..][0..2], .little);
                        }
                    }.at;
                    const want: [4]u8 = switch (i) {
                        0 => .{ y8[y * w + x], 0, 0, 255 },
                        1 => .{ uv8[y * cw * 2 + x * 2], uv8[y * cw * 2 + x * 2 + 1], 0, 255 },
                        2 => .{ to8(r16(&y16b, y * w + x)), 0, 0, 255 },
                        else => .{ to8(r16(&uv16b, y * cw * 2 + x * 2)), to8(r16(&uv16b, y * cw * 2 + x * 2 + 1)), 0, 255 },
                    };
                    const at = (y * pw + x) * 4;
                    if (!std.mem.eql(u8, &want, bl_got[at..][0..4])) {
                        std.debug.print("block-linear plane {d} mode {d} texel ({d}, {d}): {any}, not {any}\n", .{ i, mode, x, y, bl_got[at..][0..4], want });
                        return error.Plane;
                    }
                }
            }
        }
    }

    // a block-linear plane is only sampled: not drawn into, not uploaded to
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(gl.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex[0], 0);
    try std.testing.expect(c.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE);
    c.bindFramebuffer(gl.FRAMEBUFFER, 0);
    c.deleteFramebuffers(&fb);
    c.bindTexture(gl.TEXTURE_2D, tex[0]);
    const one = [_]u8{0};
    c.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 1, 1, gl.RED, gl.UNSIGNED_BYTE, &one);
    try std.testing.expectEqual(gl.INVALID_OPERATION, c.getError());
    var rb: [1]u32 = undefined;
    c.genRenderbuffers(&rb);
    c.bindRenderbuffer(gl.RENDERBUFFER, rb[0]);
    c.eglImageTargetRenderbufferStorage(gl.RENDERBUFFER, planes[0]);
    try std.testing.expectEqual(gl.INVALID_OPERATION, c.getError());
    c.deleteRenderbuffers(&rb);
    // what the import refuses: a pitch of part GOBs, a plane past the
    // buffer (its whole blocks counted), a compressed modifier
    try std.testing.expect(blockPlaneImage(d, egl.DRM_FORMAT_R8, fd, w, h, 0, 96, tiling.modifierOf(.blackwell8)) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError());
    try std.testing.expect(blockPlaneImage(d, egl.DRM_FORMAT_R8, fd, w, 300, 0, 64, tiling.modifierOf(.blackwell8)) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError());
    try std.testing.expect(blockPlaneImage(d, egl.DRM_FORMAT_R8, fd, w, h, 0, 64, tiling.nvidiaBlockLinear2d(1, 2, 2, 0x06, 1)) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());

    c.finish();
    c.deleteTextures(&tex);
    for (planes) |img| try std.testing.expect(egl.destroyImage(d, img));
    c.finish();
    eng.freeImage(&surf);
    try std.testing.expect(egl.makeCurrent(d, null, null, null));
    try std.testing.expect(egl.destroySurface(d, pb));
    try std.testing.expect(egl.destroyContext(d, ctx));
    try std.testing.expect(egl.terminate(d));
}

var export_slabs: [1]engine.Slab = undefined;

test "egl: a texture as an EGLImage, its dma-buf exported and imported again (Firefox's dma-buf surfaces)" {
    useDriver();
    Fake.reset();
    const d = egl.getDisplay(null).?;
    try std.testing.expect(egl.initialize(d, null, null));
    const ctx = egl.createContext(d, config(true), null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    const pb = egl.createPbufferSurface(d, config(true), &[_]i32{ egl.WIDTH, 4, egl.HEIGHT, 4, egl.NONE }).?;
    try std.testing.expect(egl.makeCurrent(d, pb, pb, ctx));
    const c = thread.gl().?;
    // (slabs, as the library's engine has: a small texture is in one, so
    // its image moves it to a buffer of its own)
    eng.slabs = &export_slabs;
    for (&export_slabs) |*s| s.* = .{};
    defer {
        for (&export_slabs) |*s| if (s.buf.cpu.len != 0) emu.device().free(s.buf);
        eng.slabs = &.{};
    }

    // Firefox's DMABufSurfaceRGBA::CreateExport: a texture, then an image
    // of it (pixels here, to see them go with its memory)
    var px: [4 * 4 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    var tex: [5]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(gl.TEXTURE_2D, tex[0]);
    c.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 4, 4, 0, gl.RGBA, gl.UNSIGNED_BYTE, &px);
    const base = liveRegions();
    const img = egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[0]), &[_]i32{ egl.GL_TEXTURE_LEVEL_KHR, 0, egl.IMAGE_PRESERVED_KHR, 1, egl.NONE }).?;
    // (its memory moved out of the engine's slab: a buffer of its own)
    try std.testing.expectEqual(base + 1, liveRegions());
    var fourcc: i32 = 0;
    var nplanes: i32 = 0;
    var modifier: u64 = 7;
    try std.testing.expect(egl.exportDmaBufQuery(d, img, &fourcc, &nplanes, &modifier));
    try std.testing.expectEqual(@as(i32, @bitCast(egl.DRM_FORMAT_ABGR8888)), fourcc);
    try std.testing.expectEqual(@as(i32, 1), nplanes);
    try std.testing.expectEqual(@as(u64, 0), modifier); // (DRM_FORMAT_MOD_LINEAR)
    // the first export fails (the kernel out of memory), the next goes
    Fake.export_failures = 1;
    var fd: i32 = -1;
    var stride: i32 = 0;
    var offset: i32 = -1;
    try std.testing.expect(!egl.exportDmaBuf(d, img, &fd, &stride, &offset));
    try std.testing.expectEqual(egl.BAD_ALLOC, egl.getError());
    try std.testing.expect(egl.exportDmaBuf(d, img, &fd, &stride, &offset));
    try std.testing.expectEqual(@as(i32, 16), stride);
    try std.testing.expectEqual(@as(i32, 0), offset);

    // the compositor's side: the dma-buf imported (the fake's dup is the
    // fd + 1000), a texture of it in a framebuffer: the same pixels
    const in = egl.createImage(i32, d, null, egl.LINUX_DMA_BUF_EXT, null, &[_]i32{ egl.WIDTH, 4, egl.HEIGHT, 4, egl.LINUX_DRM_FOURCC_EXT, fourcc, egl.DMA_BUF_PLANE0_FD_EXT, fd - 1000, egl.DMA_BUF_PLANE0_OFFSET_EXT, offset, egl.DMA_BUF_PLANE0_PITCH_EXT, stride, egl.DMA_BUF_PLANE0_MODIFIER_LO_EXT, 0, egl.DMA_BUF_PLANE0_MODIFIER_HI_EXT, 0, egl.NONE }).?;
    try std.testing.expectEqual(base + 2, liveRegions());
    c.bindTexture(gl.TEXTURE_2D, tex[1]);
    c.eglImageTargetTexture2D(gl.TEXTURE_2D, in);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(gl.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex[1], 0);
    try std.testing.expectEqual(gl.FRAMEBUFFER_COMPLETE, c.checkFramebufferStatus(gl.FRAMEBUFFER));
    try std.testing.expectEqualSlices(u8, px[(1 * 4 + 2) * 4 ..][0..4], &rgbaAt(c, 2, 1));
    // drawn into there (WebGL's frames): the exporter's memory is the same
    // pages, so what the GPU wrote, once fetched for the CPU (pixel 1, 1:
    // the one read), is in the texture's own bytes (EmuDevice's memory is
    // not coherent: each side's GPU view is its own copy)
    c.enable(gl.SCISSOR_TEST, true);
    c.scissorSet(0, 0, 2, 2);
    c.clearColor(0, 1, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    c.enable(gl.SCISSOR_TEST, false);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(c, 1, 1));
    const mine = &c.objs.tex[tex[0] - 1].img;
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, mine.buf.cpu[1 * 16 + 1 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, px[(3 * 4 + 3) * 4 ..][0..4], mine.buf.cpu[3 * 16 + 3 * 4 ..][0..4]);
    try std.testing.expectEqual(gl.NO_ERROR, c.getError());

    // a video plane's texture (R8) is exported as R8; a float texture's
    // image is had, but no dma-buf has its layout
    c.bindTexture(gl.TEXTURE_2D, tex[2]);
    c.texImage2D(gl.TEXTURE_2D, 0, @bitCast(gl.R8), 8, 2, 0, gl.RED, gl.UNSIGNED_BYTE, null);
    const r8 = egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[2]), null).?;
    try std.testing.expect(egl.exportDmaBufQuery(d, r8, &fourcc, &nplanes, &modifier));
    try std.testing.expectEqual(@as(i32, @bitCast(egl.DRM_FORMAT_R8)), fourcc);
    c.bindTexture(gl.TEXTURE_2D, tex[3]);
    c.texImage2D(gl.TEXTURE_2D, 0, @bitCast(gl.RGBA32F), 1, 1, 0, gl.RGBA, gl.FLOAT, null);
    const f32img = egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[3]), null).?;
    try std.testing.expect(!egl.exportDmaBufQuery(d, f32img, &fourcc, &nplanes, &modifier));
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());

    // what EGL refuses: a texture already an image's, none, a texture with
    // no level 0, another level, no context
    try std.testing.expect(egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[0]), null) == null);
    try std.testing.expectEqual(egl.BAD_ACCESS, egl.getError());
    try std.testing.expect(egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, null, null) == null);
    try std.testing.expectEqual(egl.BAD_PARAMETER, egl.getError());
    try std.testing.expect(egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(9999), null) == null);
    try std.testing.expectEqual(egl.BAD_PARAMETER, egl.getError());
    c.bindTexture(gl.TEXTURE_2D, tex[4]);
    try std.testing.expect(egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[4]), null) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());
    c.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    try std.testing.expect(egl.createImage(i32, d, ctx, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[4]), &[_]i32{ egl.GL_TEXTURE_LEVEL_KHR, 1, egl.NONE }) == null);
    try std.testing.expectEqual(egl.BAD_MATCH, egl.getError());
    try std.testing.expect(egl.createImage(i32, d, null, egl.GL_TEXTURE_2D_KHR, @ptrFromInt(tex[4]), null) == null);
    try std.testing.expectEqual(egl.BAD_CONTEXT, egl.getError());

    // the texture goes; its image keeps the memory, then the image goes
    // and its fd is closed with it; every name gone, every buffer freed
    c.bindFramebuffer(gl.FRAMEBUFFER, 0);
    c.deleteFramebuffers(&fb);
    c.finish();
    const live = liveRegions();
    c.deleteTextures(tex[0..1]);
    try std.testing.expectEqual(live, liveRegions());
    const closes = Fake.closes;
    try std.testing.expect(egl.destroyImage(d, img));
    try std.testing.expectEqual(closes + 1, Fake.closes);
    c.deleteTextures(tex[1..]);
    for ([_]*egl.EImage{ in, r8, f32img }) |m| try std.testing.expect(egl.destroyImage(d, m));
    c.finish();
    // (the three textures' own buffers and the import; the draws' kernels
    // stay with the context)
    try std.testing.expectEqual(live - 4, liveRegions());
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
