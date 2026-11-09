//! @zpm/gfxapi wayland — EGL's Wayland platform: a window's frames drawn on
//! the GPU and handed to the compositor (Galaxy's Wayland bridge) as
//! dma-bufs, zero-copy, through zwp_linux_dmabuf_v1.
//!
//! The app owns the connection (its wl_display) and EGL works through the
//! app's libwayland-client, as Mesa's does: `Client` is that library's
//! functions, found by name in the process (dl.sig) or a test's. EGL's own
//! events go to a queue of its own (a display wrapper set to it), so they
//! never run inside the app's dispatch, nor the app's inside EGL's.
//! Events arrive through libwayland's generic dispatcher
//! (wl_proxy_add_dispatcher): one Sig function per kind of object, its
//! arguments as wl_argument.
//!
//! - **The display:** the registry's zwp_linux_dmabuf_v1, bound at version
//!   4 where offered (else 3, else what there is). Version 4 tells its
//!   formats by the default feedback: a format table (a file, mapped) and
//!   tranches of indices into it. Versions 3 and below tell them by
//!   `modifier` (or `format`) events. EGL wants linear ARGB8888 and
//!   XRGB8888. Galaxy's bridge offers them only while the GPU runs and
//!   this driver is installed; without them EGL has no Wayland display,
//!   and the app draws in software.
//! - **A window** (libwayland-egl's wl_egl_window, version 3): up to
//!   MAX_BUFFERS buffers, each an engine image in GPU memory (top-down
//!   BGRA: DRM's ARGB8888 or XRGB8888, linear, rows width * 4 bytes), its
//!   dma-buf (PRIME) made a wl_buffer by create_immed. A swap flushes the
//!   engine and does not wait for the GPU: Galaxy's dma-buf fences cover
//!   the work (every submission of a context that uses Galaxy's calls
//!   counts as writing its buffers), and the compositor's GPU reads on the
//!   same ring. Then attach, damage (the app's rectangles, else all),
//!   frame, commit, flush. With swap interval 1 the next swap first waits
//!   for the frame callback. The next back buffer is one the compositor
//!   has released, else a new one; with all of them held, EGL waits for a
//!   release. A resize (wl_egl_window_resize) takes effect at the next
//!   frame; buffers of the old size go once released.
//! - **Buffer age** (EGL_EXT_buffer_age): frames since the back buffer was
//!   last shown, 0 for a new one.
//!
//! Allocation-free: fixed tables; the buffers' memory is the engine's.

const std = @import("std");
const report = @import("report.sig");
const gpu = @import("gpu");
const engine = @import("engine.sig");
const dl = @import("dl.sig");
const Host = @import("host.sig").Host;
const Engine = engine.Engine;
const Image = engine.Image;

// ── libwayland-client's ABI ────────────────────────────────────────────────

pub const Proxy = opaque {};
pub const Queue = opaque {};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const Interface,
};

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

pub const Array = extern struct { size: usize, alloc: usize, data: ?*anyopaque };

/// union wl_argument
pub const Arg = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*Proxy,
    n: u32,
    a: ?*const Array,
    h: i32,
};

pub const Dispatcher = *const fn (impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Arg) callconv(.c) c_int;

/// WL_MARSHAL_FLAG_DESTROY
pub const DESTROY: u32 = 1;

/// libwayland-client's functions and interfaces, as EGL uses them.
pub const Client = struct {
    create_queue: *const fn (*Proxy) callconv(.c) ?*Queue,
    queue_destroy: *const fn (*Queue) callconv(.c) void,
    create_wrapper: *const fn (*Proxy) callconv(.c) ?*Proxy,
    wrapper_destroy: *const fn (*Proxy) callconv(.c) void,
    set_queue: *const fn (*Proxy, ?*Queue) callconv(.c) void,
    /// wl_proxy_marshal_array_flags (wayland 1.20); else the two below
    marshal_flags: ?*const fn (*Proxy, u32, ?*const Interface, u32, u32, [*]Arg) callconv(.c) ?*Proxy,
    marshal_ctor: *const fn (*Proxy, u32, [*]Arg, *const Interface, u32) callconv(.c) ?*Proxy,
    marshal: *const fn (*Proxy, u32, [*]Arg) callconv(.c) void,
    add_dispatcher: *const fn (*Proxy, Dispatcher, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int,
    destroy: *const fn (*Proxy) callconv(.c) void,
    get_version: *const fn (*Proxy) callconv(.c) u32,
    roundtrip_queue: *const fn (*Proxy, *Queue) callconv(.c) c_int,
    dispatch_queue: *const fn (*Proxy, *Queue) callconv(.c) c_int,
    dispatch_pending: *const fn (*Proxy, *Queue) callconv(.c) c_int,
    flush: *const fn (*Proxy) callconv(.c) c_int,
    display_interface: *const Interface,
    registry_interface: *const Interface,
    buffer_interface: *const Interface,
    callback_interface: *const Interface,
    surface_interface: *const Interface,

    /// The host's libwayland-client (the app has it loaded), or null.
    pub fn load() ?Client {
        return .{
            .create_queue = dl.sym(@FieldType(Client, "create_queue"), "wl_display_create_queue") orelse return null,
            .queue_destroy = dl.sym(@FieldType(Client, "queue_destroy"), "wl_event_queue_destroy") orelse return null,
            .create_wrapper = dl.sym(@FieldType(Client, "create_wrapper"), "wl_proxy_create_wrapper") orelse return null,
            .wrapper_destroy = dl.sym(@FieldType(Client, "wrapper_destroy"), "wl_proxy_wrapper_destroy") orelse return null,
            .set_queue = dl.sym(@FieldType(Client, "set_queue"), "wl_proxy_set_queue") orelse return null,
            .marshal_flags = dl.sym(@typeInfo(@FieldType(Client, "marshal_flags")).optional.child, "wl_proxy_marshal_array_flags"),
            .marshal_ctor = dl.sym(@FieldType(Client, "marshal_ctor"), "wl_proxy_marshal_array_constructor_versioned") orelse return null,
            .marshal = dl.sym(@FieldType(Client, "marshal"), "wl_proxy_marshal_array") orelse return null,
            .add_dispatcher = dl.sym(@FieldType(Client, "add_dispatcher"), "wl_proxy_add_dispatcher") orelse return null,
            .destroy = dl.sym(@FieldType(Client, "destroy"), "wl_proxy_destroy") orelse return null,
            .get_version = dl.sym(@FieldType(Client, "get_version"), "wl_proxy_get_version") orelse return null,
            .roundtrip_queue = dl.sym(@FieldType(Client, "roundtrip_queue"), "wl_display_roundtrip_queue") orelse return null,
            .dispatch_queue = dl.sym(@FieldType(Client, "dispatch_queue"), "wl_display_dispatch_queue") orelse return null,
            .dispatch_pending = dl.sym(@FieldType(Client, "dispatch_pending"), "wl_display_dispatch_queue_pending") orelse return null,
            .flush = dl.sym(@FieldType(Client, "flush"), "wl_display_flush") orelse return null,
            .display_interface = dl.sym(*const Interface, "wl_display_interface") orelse return null,
            .registry_interface = dl.sym(*const Interface, "wl_registry_interface") orelse return null,
            .buffer_interface = dl.sym(*const Interface, "wl_buffer_interface") orelse return null,
            .callback_interface = dl.sym(*const Interface, "wl_callback_interface") orelse return null,
            .surface_interface = dl.sym(*const Interface, "wl_surface_interface") orelse return null,
        };
    }

    /// A request: its new object (or null). `version` is the new object's
    /// (null: the proxy's own).
    fn send(c: *const Client, p: *Proxy, opcode: u32, iface: ?*const Interface, version: ?u32, flags: u32, args: []Arg) ?*Proxy {
        const v = version orelse c.get_version(p);
        if (c.marshal_flags) |f| return f(p, opcode, iface, v, flags, args.ptr);
        var out: ?*Proxy = null;
        if (iface) |i| out = c.marshal_ctor(p, opcode, args.ptr, i, v) else c.marshal(p, opcode, args.ptr);
        if (flags & DESTROY != 0) c.destroy(p);
        return out;
    }

    /// Whether `native` is a wl_display (its proxy's interface is
    /// libwayland's wl_display_interface), as Mesa tells.
    pub fn isDisplay(c: *const Client, native: *const anyopaque) bool {
        const first: *const ?*const Interface = @ptrCast(@alignCast(native));
        return first.* == c.display_interface;
    }
};

// ── The protocol this platform adds (linux-dmabuf-unstable-v1) ────────────

var types_none = [_]?*const Interface{ null, null, null, null, null, null };
var types_params = [_]?*const Interface{&params_interface};
var types_feedback = [_]?*const Interface{&feedback_interface};
var types_feedback_surface = [_]?*const Interface{ &feedback_interface, null };
var types_created = [_]?*const Interface{null};
var types_immed = [_]?*const Interface{ null, null, null, null, null };

const dmabuf_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &types_none },
    .{ .name = "create_params", .signature = "n", .types = &types_params },
    .{ .name = "get_default_feedback", .signature = "4n", .types = &types_feedback },
    .{ .name = "get_surface_feedback", .signature = "4no", .types = &types_feedback_surface },
};
const dmabuf_events = [_]Message{
    .{ .name = "format", .signature = "u", .types = &types_none },
    .{ .name = "modifier", .signature = "3uuu", .types = &types_none },
};
pub var dmabuf_interface = Interface{ .name = "zwp_linux_dmabuf_v1", .version = 4, .method_count = dmabuf_requests.len, .methods = &dmabuf_requests, .event_count = dmabuf_events.len, .events = &dmabuf_events };

const params_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &types_none },
    .{ .name = "add", .signature = "huuuuu", .types = &types_none },
    .{ .name = "create", .signature = "iiuu", .types = &types_none },
    .{ .name = "create_immed", .signature = "2niiuu", .types = &types_immed },
};
const params_events = [_]Message{
    .{ .name = "created", .signature = "n", .types = &types_created },
    .{ .name = "failed", .signature = "", .types = &types_none },
};
pub var params_interface = Interface{ .name = "zwp_linux_buffer_params_v1", .version = 4, .method_count = params_requests.len, .methods = &params_requests, .event_count = params_events.len, .events = &params_events };

const feedback_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &types_none },
};
const feedback_events = [_]Message{
    .{ .name = "done", .signature = "", .types = &types_none },
    .{ .name = "format_table", .signature = "hu", .types = &types_none },
    .{ .name = "main_device", .signature = "a", .types = &types_none },
    .{ .name = "tranche_done", .signature = "", .types = &types_none },
    .{ .name = "tranche_target_device", .signature = "a", .types = &types_none },
    .{ .name = "tranche_formats", .signature = "a", .types = &types_none },
    .{ .name = "tranche_flags", .signature = "u", .types = &types_none },
};
pub var feedback_interface = Interface{ .name = "zwp_linux_dmabuf_feedback_v1", .version = 4, .method_count = feedback_requests.len, .methods = &feedback_requests, .event_count = feedback_events.len, .events = &feedback_events };

/// The interfaces above that name libwayland's own (wl_buffer,
/// wl_surface): filled from the client's.
fn linkProtocol(c: *const Client) void {
    types_created[0] = c.buffer_interface;
    types_immed[0] = c.buffer_interface;
    types_feedback_surface[1] = c.surface_interface;
}

pub const DRM_FORMAT_ARGB8888: u32 = 0x3432_5241;
pub const DRM_FORMAT_XRGB8888: u32 = 0x3432_5258;
const MOD_LINEAR: u64 = 0;

// wl_display, wl_registry, wl_surface, wl_buffer, wl_callback: their requests
const DISPLAY_GET_REGISTRY = 1;
const REGISTRY_BIND = 0;
const SURFACE_ATTACH = 1;
const SURFACE_DAMAGE = 2;
const SURFACE_FRAME = 3;
const SURFACE_COMMIT = 6;
const SURFACE_DAMAGE_BUFFER = 9;
const SURFACE_OFFSET = 10;
const BUFFER_DESTROY = 0;
const DMABUF_DESTROY = 0;
const DMABUF_CREATE_PARAMS = 1;
const DMABUF_GET_DEFAULT_FEEDBACK = 2;
const FEEDBACK_DESTROY = 0;
const PARAMS_DESTROY = 0;
const PARAMS_ADD = 1;
const PARAMS_CREATE_IMMED = 3;

// ── The display ────────────────────────────────────────────────────────────

pub const Display = struct {
    c: *const Client,
    host: Host,
    native: *Proxy,
    queue: ?*Queue = null,
    wrapper: ?*Proxy = null,
    registry: ?*Proxy = null,
    dmabuf: ?*Proxy = null,
    dmabuf_name: u32 = 0,
    dmabuf_version: u32 = 0,
    /// linear ARGB8888 and XRGB8888 are taken
    argb: bool = false,
    xrgb: bool = false,
    /// version 4's feedback: its format table, mapped, while it is read
    table: ?[]const u8 = null,

    /// The display in place (it stays at `d`: events find it there): its
    /// queue, the registry, zwp_linux_dmabuf_v1 and its formats. False
    /// when the compositor takes no linear ARGB or XRGB dma-bufs.
    pub fn init(d: *Display, c: *const Client, host: Host, native: *Proxy) bool {
        d.* = .{ .c = c, .host = host, .native = native };
        linkProtocol(c);
        d.queue = c.create_queue(native) orelse return false;
        d.wrapper = c.create_wrapper(native) orelse return d.fail();
        c.set_queue(d.wrapper.?, d.queue);
        var none = [_]Arg{.{ .o = null }};
        d.registry = c.send(d.wrapper.?, DISPLAY_GET_REGISTRY, c.registry_interface, null, 0, &none) orelse return d.fail();
        _ = c.add_dispatcher(d.registry.?, &onRegistry, d, null);
        if (c.roundtrip_queue(native, d.queue.?) < 0 or d.dmabuf_name == 0) return d.fail();
        const v = @min(d.dmabuf_version, 4);
        var bind = [_]Arg{ .{ .u = d.dmabuf_name }, .{ .s = dmabuf_interface.name }, .{ .u = v }, .{ .o = null } };
        d.dmabuf = c.send(d.registry.?, REGISTRY_BIND, &dmabuf_interface, v, 0, &bind) orelse return d.fail();
        _ = c.add_dispatcher(d.dmabuf.?, &onDmabuf, d, null);
        const feedback = if (v >= 4) c.send(d.dmabuf.?, DMABUF_GET_DEFAULT_FEEDBACK, &feedback_interface, null, 0, &none) else null;
        if (feedback) |f| _ = c.add_dispatcher(f, &onFeedback, d, null);
        const ok = c.roundtrip_queue(native, d.queue.?) >= 0;
        if (feedback) |f| _ = c.send(f, FEEDBACK_DESTROY, null, null, DESTROY, &none);
        d.dropTable();
        if (!ok) return d.fail();
        // (version 1 and 2 servers say formats only: linear was the rule)
        if (!d.argb and !d.xrgb) return d.fail();
        return true;
    }

    fn fail(d: *Display) bool {
        d.deinit();
        return false;
    }

    fn dropTable(d: *Display) void {
        if (d.table) |t| d.host.unmap(d.host.ctx, t);
        d.table = null;
    }

    /// A format and modifier from the table (version 4's): taken if linear
    /// ARGB8888 or XRGB8888.
    fn offered(d: *Display, format: u32, modifier: u64) void {
        if (modifier != MOD_LINEAR) return;
        if (format == DRM_FORMAT_ARGB8888) d.argb = true;
        if (format == DRM_FORMAT_XRGB8888) d.xrgb = true;
    }

    pub fn deinit(d: *Display) void {
        const c = d.c;
        if (d.dmabuf) |p| {
            var none = [_]Arg{.{ .o = null }};
            _ = c.send(p, DMABUF_DESTROY, null, null, DESTROY, &none);
        }
        if (d.registry) |p| c.destroy(p);
        if (d.wrapper) |p| c.wrapper_destroy(p);
        if (d.queue) |q| c.queue_destroy(q);
        d.dmabuf = null;
        d.registry = null;
        d.wrapper = null;
        d.queue = null;
    }

    /// The DRM format of a config's color: with alpha or without.
    pub fn takes(d: *const Display, alpha: bool) bool {
        return if (alpha) d.argb else d.xrgb;
    }

    /// Events for EGL's queue, waiting for at least one: false when the
    /// connection broke.
    fn waitEvents(d: *Display) bool {
        return d.c.dispatch_queue(d.native, d.queue.?) >= 0;
    }

    /// The events already read for EGL's queue (buffers released), without
    /// waiting.
    fn pendingEvents(d: *Display) void {
        _ = d.c.dispatch_pending(d.native, d.queue.?);
    }
};

fn selfOf(comptime T: type, impl: ?*const anyopaque) *T {
    return @ptrCast(@alignCast(@constCast(impl.?)));
}

fn onRegistry(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Arg) callconv(.c) c_int {
    _ = target;
    _ = msg;
    const d = selfOf(Display, impl);
    switch (opcode) {
        0 => { // global(name, interface, version)
            const name = std.mem.span(args[1].s orelse return 0);
            if (std.mem.eql(u8, name, "zwp_linux_dmabuf_v1")) {
                d.dmabuf_name = args[0].u;
                d.dmabuf_version = args[2].u;
            }
        },
        1 => if (args[0].u == d.dmabuf_name) { // global_remove
            d.argb = false;
            d.xrgb = false;
        },
        else => {},
    }
    return 0;
}

/// zwp_linux_dmabuf_feedback_v1 (the default one): format_table maps the
/// table (its fd closed), tranche_formats names entries of it. The devices
/// and flags do not change what EGL makes: linear buffers, any device.
fn onFeedback(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Arg) callconv(.c) c_int {
    _ = target;
    _ = msg;
    const d = selfOf(Display, impl);
    switch (opcode) {
        1 => { // format_table(fd, size)
            const fd = args[0].h;
            d.dropTable();
            d.table = d.host.map(d.host.ctx, fd, args[1].u);
            d.host.close(d.host.ctx, fd);
        },
        5 => { // tranche_formats(array of u16 indices)
            const t = d.table orelse return 0;
            const a = args[0].a orelse return 0;
            const data = a.data orelse return 0;
            const idx: [*]const u16 = @ptrCast(@alignCast(data));
            for (idx[0 .. a.size / 2]) |i| {
                const at = @as(usize, i) * 16;
                if (at + 16 > t.len) continue;
                d.offered(std.mem.readInt(u32, t[at..][0..4], .little), std.mem.readInt(u64, t[at + 8 ..][0..8], .little));
            }
        },
        else => {},
    }
    return 0;
}

fn onDmabuf(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Arg) callconv(.c) c_int {
    _ = target;
    _ = msg;
    const d = selfOf(Display, impl);
    const format = args[0].u;
    const linear = switch (opcode) {
        0 => true, // format (versions 1, 2)
        1 => (@as(u64, args[1].u) << 32 | args[2].u) == MOD_LINEAR, // modifier
        else => false,
    };
    if (!linear) return 0;
    if (format == DRM_FORMAT_ARGB8888) d.argb = true;
    if (format == DRM_FORMAT_XRGB8888) d.xrgb = true;
    return 0;
}

// ── Windows ────────────────────────────────────────────────────────────────

/// libwayland-egl's struct wl_egl_window (WL_EGL_WINDOW_VERSION 3).
pub const EglWindow = extern struct {
    version: isize,
    width: c_int,
    height: c_int,
    dx: c_int,
    dy: c_int,
    attached_width: c_int,
    attached_height: c_int,
    driver_private: ?*anyopaque,
    resize_callback: ?*const fn (*EglWindow, ?*anyopaque) callconv(.c) void,
    destroy_window_callback: ?*const fn (?*anyopaque) callconv(.c) void,
    surface: ?*Proxy,
};
pub const EGL_WINDOW_VERSION = 3;

pub const MAX_BUFFERS = 4;

pub const Buffer = struct {
    img: Image = .{},
    wl: ?*Proxy = null,
    /// the compositor holds it (attached, not released yet)
    busy: bool = false,
    /// of an old size: freed once released
    stale: bool = false,
    /// the frame it was last shown at (0: never)
    shown: u64 = 0,
    /// (back-pointer for its release event)
    win: ?*Window = null,
};

pub const Window = struct {
    d: *Display,
    eng: *Engine,
    native: ?*EglWindow,
    surface: ?*Proxy = null,
    alpha: bool,
    width: u32 = 0,
    height: u32 = 0,
    bufs: [MAX_BUFFERS]Buffer = [_]Buffer{.{}} ** MAX_BUFFERS,
    back: ?usize = null,
    frame_cb: ?*Proxy = null,
    interval: u32 = 1,
    /// frames shown
    frames: u64 = 0,
    /// the size changed since the back buffer was taken
    /// (wl_egl_window_resize, perhaps on another thread): GL takes a back
    /// buffer of the new size at its next drawing, as Mesa's does
    resized: std.atomic.Value(bool) = .init(false),
    stats: struct { swaps: u64 = 0, release_waits: u64 = 0, frame_waits: u64 = 0, made: u64 = 0 } = .{},

    /// A window in place over `native` (it stays at `w`: libwayland-egl
    /// and events find it there). False for an old wl_egl_window, one
    /// without a surface, or a format the compositor does not take.
    pub fn init(w: *Window, d: *Display, eng: *Engine, native: *EglWindow, alpha: bool) bool {
        if (native.version < EGL_WINDOW_VERSION or native.surface == null) return false;
        if (!d.takes(alpha)) return false;
        w.* = .{ .d = d, .eng = eng, .native = native, .alpha = alpha };
        w.surface = d.c.create_wrapper(native.surface.?) orelse return false;
        d.c.set_queue(w.surface.?, d.queue);
        native.driver_private = w;
        native.resize_callback = &onResize;
        native.destroy_window_callback = &onWindowGone;
        w.width = @intCast(@max(native.width, 1));
        w.height = @intCast(@max(native.height, 1));
        return true;
    }

    /// The wl_egl_window let go now (eglDestroySurface of a surface still
    /// current: its buffers stay until it is released, but the native
    /// window may have a new surface at once, as Firefox's second try at
    /// its compositor makes one). The window shows nothing more.
    pub fn detach(w: *Window) void {
        if (w.native) |n| {
            n.driver_private = null;
            n.resize_callback = null;
            n.destroy_window_callback = null;
        }
        w.native = null;
    }

    pub fn deinit(w: *Window) void {
        const c = w.d.c;
        if (w.frame_cb) |p| c.destroy(p);
        w.frame_cb = null;
        for (&w.bufs) |*b| w.drop(b);
        if (w.surface) |p| c.wrapper_destroy(p);
        w.surface = null;
        if (w.native) |n| {
            n.driver_private = null;
            n.resize_callback = null;
            n.destroy_window_callback = null;
        }
        w.native = null;
    }

    fn drop(w: *Window, b: *Buffer) void {
        if (b.wl) |p| {
            var none = [_]Arg{.{ .o = null }};
            _ = w.d.c.send(p, BUFFER_DESTROY, null, null, DESTROY, &none);
        }
        // (the compositor's mapping holds the pages: the dma-buf is its own)
        w.eng.freeImage(&b.img);
        b.* = .{};
    }

    /// The size the next frame has (the window's, as the app last set it).
    pub fn wanted(w: *const Window) [2]u32 {
        const n = w.native orelse return .{ w.width, w.height };
        return .{ @intCast(@max(n.width, 1)), @intCast(@max(n.height, 1)) };
    }

    /// The back buffer's image, taken now if need be: a released buffer of
    /// the window's size, else a new one; with all of them held, EGL waits
    /// for a release. Null when there is no memory or the connection broke.
    pub fn backImage(w: *Window) ?*Image {
        if (w.back) |i| return &w.bufs[i].img;
        // (buffers the compositor released meanwhile, first)
        w.d.pendingEvents();
        w.resized.store(false, .release);
        const size = w.wanted();
        if (size[0] != w.width or size[1] != w.height) {
            w.width = size[0];
            w.height = size[1];
            for (&w.bufs) |*b| {
                if (!b.img.live()) continue;
                if (b.busy) b.stale = true else w.drop(b);
            }
        }
        var retried_allocation = false;
        choose: while (true) {
            // a free one: the most recently shown (the smallest age)
            var pick: ?usize = null;
            for (&w.bufs, 0..) |*b, i| {
                if (!b.img.live() or b.busy or b.stale) continue;
                if (pick == null or b.shown > w.bufs[pick.?].shown) pick = i;
            }
            if (pick == null) {
                for (&w.bufs, 0..) |*b, i| {
                    if (!b.img.live() and !b.busy) {
                        if (!w.make(b)) {
                            if (retried_allocation) return null;
                            retried_allocation = true;
                            // Earlier commits may already have released a
                            // usable buffer or a stale buffer's storage.
                            if (w.d.c.roundtrip_queue(w.d.native, w.d.queue.?) < 0) return null;
                            continue :choose;
                        }
                        pick = i;
                        break;
                    }
                }
            }
            if (pick) |i| {
                w.back = i;
                return &w.bufs[i].img;
            }
            w.stats.release_waits += 1;
            if (!w.d.waitEvents()) return null;
        }
    }

    /// A new buffer of the window's size: GPU memory, its dma-buf, its
    /// wl_buffer.
    fn make(w: *Window, b: *Buffer) bool {
        b.* = .{ .win = w };
        var img = w.eng.newWindowImage(w.width, w.height, .bgra8) orelse {
            report.say(.egl_error, "could not allocate a {d}x{d} Wayland window buffer", .{ w.width, w.height });
            return false;
        };
        img.top_down = true;
        img.no_alpha = !w.alpha;
        b.img = img;
        const host = w.d.host;
        const fd = host.exportFd(host.ctx, img.buf);
        if (fd < 0) {
            report.say(.egl_error, "could not export a {d}x{d} Wayland window buffer: errno {d}, CPU storage {}", .{ w.width, w.height, -fd, img.pooled });
            w.eng.freeImage(&b.img);
            return false;
        }
        defer host.close(host.ctx, @intCast(fd));
        const c = w.d.c;
        var none = [_]Arg{.{ .o = null }};
        const params = c.send(w.d.dmabuf.?, DMABUF_CREATE_PARAMS, &params_interface, null, 0, &none) orelse {
            w.eng.freeImage(&b.img);
            return false;
        };
        var add = [_]Arg{ .{ .h = @intCast(fd) }, .{ .u = 0 }, .{ .u = 0 }, .{ .u = img.stride }, .{ .u = @intCast(MOD_LINEAR >> 32) }, .{ .u = @truncate(MOD_LINEAR) } };
        _ = c.send(params, PARAMS_ADD, null, null, 0, &add);
        const format = if (w.alpha) DRM_FORMAT_ARGB8888 else DRM_FORMAT_XRGB8888;
        var immed = [_]Arg{ .{ .o = null }, .{ .i = @intCast(w.width) }, .{ .i = @intCast(w.height) }, .{ .u = format }, .{ .u = 0 } };
        b.wl = c.send(params, PARAMS_CREATE_IMMED, c.buffer_interface, 1, 0, &immed);
        _ = c.send(params, PARAMS_DESTROY, null, null, DESTROY, &none);
        if (b.wl == null) {
            w.eng.freeImage(&b.img);
            return false;
        }
        _ = c.add_dispatcher(b.wl.?, &onBuffer, b, null);
        w.stats.made += 1;
        return true;
    }

    /// The back buffer, not shown yet, given up (a resize): the next one is
    /// taken afresh.
    pub fn dropBack(w: *Window) void {
        w.back = null;
    }

    /// EGL_EXT_buffer_age's answer for the back buffer.
    pub fn age(w: *Window) i32 {
        const img = w.backImage() orelse return 0;
        _ = img;
        const b = &w.bufs[w.back.?];
        if (b.shown == 0) return 0;
        return @intCast(@min(w.frames - b.shown + 1, std.math.maxInt(i32)));
    }

    /// The back buffer shown: `damage` (x, y, width, height from the
    /// bottom left, as EGL gives them; none: everything). False when the
    /// window or the connection is gone.
    pub fn swap(w: *Window, damage: []const [4]i32) bool {
        const c = w.d.c;
        const surface = w.surface orelse return false;
        if (w.native == null) return false;
        // (interval 1: one frame on the screen at a time)
        while (w.interval > 0 and w.frame_cb != null) {
            w.stats.frame_waits += 1;
            if (!w.d.waitEvents()) return false;
        }
        _ = w.backImage() orelse return false;
        const b = &w.bufs[w.back.?];
        // the GPU's work runs; the dma-buf's fence covers it
        w.eng.flush();
        var none = [_]Arg{.{ .o = null }};
        if (w.interval > 0) {
            w.frame_cb = c.send(surface, SURFACE_FRAME, c.callback_interface, null, 0, &none);
            if (w.frame_cb) |cb| _ = c.add_dispatcher(cb, &onFrame, w, null);
        }
        const n = w.native.?;
        const version = c.get_version(surface);
        if (version >= 5) {
            if (n.dx != 0 or n.dy != 0) {
                var off = [_]Arg{ .{ .i = n.dx }, .{ .i = n.dy } };
                _ = c.send(surface, SURFACE_OFFSET, null, null, 0, &off);
            }
            var at = [_]Arg{ .{ .o = b.wl }, .{ .i = 0 }, .{ .i = 0 } };
            _ = c.send(surface, SURFACE_ATTACH, null, null, 0, &at);
        } else {
            var at = [_]Arg{ .{ .o = b.wl }, .{ .i = n.dx }, .{ .i = n.dy } };
            _ = c.send(surface, SURFACE_ATTACH, null, null, 0, &at);
        }
        n.dx = 0;
        n.dy = 0;
        n.attached_width = @intCast(w.width);
        n.attached_height = @intCast(w.height);
        const op: u32 = if (version >= 4) SURFACE_DAMAGE_BUFFER else SURFACE_DAMAGE;
        if (damage.len == 0) {
            var all = [_]Arg{ .{ .i = 0 }, .{ .i = 0 }, .{ .i = std.math.maxInt(i32) }, .{ .i = std.math.maxInt(i32) } };
            _ = c.send(surface, op, null, null, 0, &all);
        } else for (damage) |r| {
            // (EGL's rectangles are from the bottom left; the buffer's rows from the top)
            const h: i32 = @intCast(w.height);
            var rect = [_]Arg{ .{ .i = r[0] }, .{ .i = h - r[1] - r[3] }, .{ .i = r[2] }, .{ .i = r[3] } };
            _ = c.send(surface, op, null, null, 0, &rect);
        }
        _ = c.send(surface, SURFACE_COMMIT, null, null, 0, &none);
        _ = c.flush(w.d.native);
        w.frames += 1;
        b.shown = w.frames;
        b.busy = true;
        w.back = null;
        w.stats.swaps += 1;
        return true;
    }
};

fn onBuffer(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Arg) callconv(.c) c_int {
    _ = target;
    _ = msg;
    _ = args;
    if (opcode != 0) return 0; // release
    const b = selfOf(Buffer, impl);
    b.busy = false;
    if (b.stale) {
        if (b.win) |w| w.drop(b);
    }
    return 0;
}

fn onFrame(impl: ?*const anyopaque, target: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Arg) callconv(.c) c_int {
    _ = msg;
    _ = args;
    if (opcode != 0) return 0; // done
    const w = selfOf(Window, impl);
    if (target) |t| w.d.c.destroy(@ptrCast(t));
    if (w.frame_cb == @as(?*Proxy, @ptrCast(target))) w.frame_cb = null;
    return 0;
}

fn onResize(native: *EglWindow, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const w: *Window = @ptrCast(@alignCast(native.driver_private orelse return));
    w.resized.store(true, .release);
}

fn onWindowGone(data: ?*anyopaque) callconv(.c) void {
    const w: *Window = @ptrCast(@alignCast(data orelse return));
    w.native = null;
}
