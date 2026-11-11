//! @zpm/gfxapi x11 — EGL's X11 platform: a window's frames drawn on the
//! GPU and shown on an X server (Galaxy's Xwayland), the X11 protocol
//! spoken by EGL itself over a connection of its own, in Sig: no Xlib, no
//! XCB, no Mesa.
//!
//! - **The connection.** The app's Display* (Xlib's struct, read for its
//!   display name only: its fd and sequence numbers stay Xlib's), or
//!   $DISPLAY for EGL_DEFAULT_DISPLAY, names the server; EGL opens a
//!   Unix socket of its own to it (/tmp/.X11-unix/XN, then the abstract
//!   one) and speaks the protocol there, little endian, without
//!   authorization (Galaxy's Xwayland asks for none). Windows are the
//!   server's, so a window the app made on its connection is drawn on
//!   from EGL's. The socket is the library root's (`Wire`: Linux's
//!   socket calls, sendmsg with SCM_RIGHTS for fds); tests give a fake
//!   server.
//! - **Visuals.** The setup reply's screen: its TrueColor visuals of depth
//!   24 (the root's, where it is one) and 32 are the configs' native
//!   visuals (XRGB and ARGB), as Firefox matches them with XGetVisualInfo.
//! - **Frames, three ways**, chosen per window when it is made:
//!   - *DRI3 and Present* (a server that imports dma-bufs: Xwayland with
//!     glamor): up to MAX_BUFFERS engine images in GPU memory (top-down
//!     BGRA, linear, the window's depth, 32 bits a pixel), each a pixmap
//!     made from its dma-buf (DRI3 1.2's PixmapFromBuffers with the linear
//!     modifier, so Xwayland can hand the buffer itself to its compositor;
//!     DRI3 1.0's PixmapFromBuffer on an older server; the fd passed with
//!     SCM_RIGHTS) and shown with PresentPixmap, as Mesa's DRI3 loader
//!     does. The swap's damage (EGL_KHR_swap_buffers_with_damage) goes as
//!     Present's update region (an XFixes region, where the server has
//!     XFIXES 2), so Xwayland copies and damages only what changed. A pixmap is the server's until its IdleNotify; with all of
//!     them held, EGL waits for one. Swap interval 1 waits for the last
//!     frame's CompleteNotify first (the frame clock); 0 presents Async.
//!     Present's ConfigureNotify marks the window resized. A server that
//!     refuses the first dma-buf turns the window to the next way.
//!   - *MIT-SHM* (no DRI3, MIT-SHM 1.2: Galaxy's Xwayland, which runs
//!     with -glamor off): one image, read back to the CPU at a swap, its
//!     damaged rectangles (EGL_KHR_swap_buffers_with_damage) copied into
//!     a shared memory file (a memfd the server maps: ShmAttachFd) and
//!     shown with ShmPutImage, then a round trip (the server has read the
//!     memory before the next frame writes it; errors seen; the app paced
//!     by the server). The image is kept, so its age is 1. A server that
//!     refuses the memory turns the window to the last way.
//!   - *PutImage* (none of those): the same, the rows sent over the
//!     socket as ZPixmap PutImage requests in strips that fit the
//!     server's request length.
//! - **Sizes.** GetGeometry when a back buffer is taken (after every
//!   swap, at the first drawing of the next frame), so a window the app
//!   resized is drawn at its new size; a pixmap of an old size goes once
//!   idle.
//! - **Errors.** An X error for a request of a window's (the window gone:
//!   BadWindow, BadDrawable) fails the swap (EGL_BAD_NATIVE_WINDOW). A
//!   broken connection fails every window of it.
//!
//! Allocation-free: fixed tables and buffers in this file's memory and the
//! display's; images are the engine's.

const std = @import("std");
const report = @import("report.sig");
const engine = @import("engine.sig");
const Host = @import("host.sig").Host;
const Engine = engine.Engine;
const Image = engine.Image;

// ── The socket (the library's root gives Linux's; tests a fake server) ────

pub const Wire = struct {
    ctx: ?*anyopaque = null,
    /// A stream socket connected to the Unix socket at `path` (in the
    /// abstract namespace with `abstract`), or -errno.
    connect: *const fn (?*anyopaque, path: []const u8, abstract: bool) i32,
    /// `bytes` out, `fds` with them (SCM_RIGHTS, on the first byte): the
    /// bytes written, or -errno (never SIGPIPE).
    send: *const fn (?*anyopaque, fd: i32, bytes: []const u8, fds: []const i32) isize,
    /// Bytes in, waiting for at least one: how many, 0 at the end, -errno.
    recv: *const fn (?*anyopaque, fd: i32, buf: []u8) isize,
    /// fd readable within timeout_ms: 1, 0, or -errno.
    poll: *const fn (?*anyopaque, fd: i32, timeout_ms: i32) i32,
    close: *const fn (?*anyopaque, fd: i32) void,
    /// The process's $DISPLAY, or null.
    display_env: *const fn (?*anyopaque) ?[]const u8,
    /// A shared memory file of `size` bytes (a memfd), mapped read-write,
    /// for MIT-SHM; null: none (then no MIT-SHM).
    shm_create: ?*const fn (?*anyopaque, size: usize) ?Shm = null,
    shm_destroy: ?*const fn (?*anyopaque, Shm) void = null,
};

/// Shared memory: its fd (the caller's) and its bytes, mapped.
pub const Shm = struct { fd: i32, mem: []u8 };

// ── Xlib's Display (read, never written) ───────────────────────────────────

/// The head of Xlib's struct _XDisplay (Xlib.h's _XPrivDisplay, a public
/// layout: its ConnectionNumber and DisplayString macros read it).
pub const XlibDisplay = extern struct {
    ext_data: ?*anyopaque,
    private1: ?*anyopaque,
    fd: c_int,
    private2: c_int,
    proto_major_version: c_int,
    proto_minor_version: c_int,
    vendor: ?[*:0]const u8,
    private3: c_ulong,
    private4: c_ulong,
    private5: c_ulong,
    private6: c_int,
    resource_alloc: ?*const anyopaque,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_pad: c_int,
    bitmap_bit_order: c_int,
    nformats: c_int,
    pixmap_format: ?*anyopaque,
    private8: c_int,
    release: c_int,
    private9: ?*anyopaque,
    private10: ?*anyopaque,
    qlen: c_int,
    last_request_read: c_ulong,
    request: c_ulong,
    private11: ?*anyopaque,
    private12: ?*anyopaque,
    private13: ?*anyopaque,
    private14: ?*anyopaque,
    max_request_size: c_uint,
    db: ?*anyopaque,
    private15: ?*const anyopaque,
    display_name: ?[*:0]const u8,
    default_screen: c_int,
    nscreens: c_int,
    screens: ?*anyopaque,
};

/// Whether `native` reads as an Xlib Display of protocol 11 with a name
/// (what EGL takes from it).
pub fn isXlibDisplay(native: *const anyopaque) bool {
    const x: *const XlibDisplay = @ptrCast(@alignCast(native));
    return x.proto_major_version == 11 and x.fd >= 0 and x.display_name != null and x.nscreens > 0;
}

/// The Display's name (DisplayString) and default screen.
pub fn xlibName(native: *const anyopaque) struct { name: []const u8, screen: u32 } {
    const x: *const XlibDisplay = @ptrCast(@alignCast(native));
    return .{ .name = std.mem.span(x.display_name.?), .screen = @intCast(@max(x.default_screen, 0)) };
}

// ── Display names ──────────────────────────────────────────────────────────

pub const Address = struct {
    path: [108]u8 = undefined,
    len: usize = 0,
    /// the abstract socket of the same name may be tried too (a display
    /// number's, as XCB does on Linux)
    abstract: bool = false,
    screen: u32 = 0,

    pub fn slice(a: *const Address) []const u8 {
        return a.path[0..a.len];
    }
};

/// The Unix socket of a display name: ":N[.S]" and "unix:N[.S]" are
/// /tmp/.X11-unix/XN; "/path[:N[.S]]" is that path (a launcher's socket).
/// Null for a remote one (TCP: "host:N") or nonsense.
pub fn parseName(name: []const u8) ?Address {
    var a = Address{};
    if (name.len == 0) return null;
    if (name[0] == '/') {
        // (the path up to a ":N[.S]" after its last slash)
        const slash = std.mem.lastIndexOfScalar(u8, name, '/').?;
        const colon = std.mem.indexOfScalarPos(u8, name, slash, ':');
        const p = name[0 .. colon orelse name.len];
        if (colon) |c| a.screen = screenOf(name[c + 1 ..]) orelse return null;
        if (p.len >= a.path.len) return null;
        @memcpy(a.path[0..p.len], p);
        a.len = p.len;
        return a;
    }
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return null;
    const host = name[0..colon];
    if (host.len != 0 and !std.mem.eql(u8, host, "unix")) return null;
    const rest = name[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const num = rest[0 .. dot orelse rest.len];
    if (num.len == 0) return null;
    const n = std.fmt.parseInt(u32, num, 10) catch return null;
    if (dot) |d| a.screen = std.fmt.parseInt(u32, rest[d + 1 ..], 10) catch return null;
    const p = std.fmt.bufPrint(&a.path, "/tmp/.X11-unix/X{d}", .{n}) catch return null;
    a.len = p.len;
    a.abstract = true;
    return a;
}

fn screenOf(s: []const u8) ?u32 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse {
        _ = std.fmt.parseInt(u32, s, 10) catch return null;
        return 0;
    };
    _ = std.fmt.parseInt(u32, s[0..dot], 10) catch return null;
    return std.fmt.parseInt(u32, s[dot + 1 ..], 10) catch null;
}

// ── The protocol's bytes ───────────────────────────────────────────────────

pub fn put16(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .little);
}
pub fn put32(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .little);
}
pub fn put64(b: []u8, v: u64) void {
    std.mem.writeInt(u64, b[0..8], v, .little);
}
pub fn get16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}
pub fn get32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}
pub fn get64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

// core requests
pub const OP_GET_GEOMETRY = 14;
pub const OP_GET_INPUT_FOCUS = 43;
pub const OP_FREE_PIXMAP = 54;
pub const OP_CREATE_GC = 55;
pub const OP_FREE_GC = 60;
pub const OP_PUT_IMAGE = 72;
pub const OP_QUERY_EXTENSION = 98;
// DRI3's
pub const DRI3_QUERY_VERSION = 0;
pub const DRI3_PIXMAP_FROM_BUFFER = 2;
pub const DRI3_PIXMAP_FROM_BUFFERS = 7;
// XFIXES' (2.0: regions)
pub const XFIXES_QUERY_VERSION = 0;
pub const XFIXES_CREATE_REGION = 5;
pub const XFIXES_DESTROY_REGION = 10;
pub const XFIXES_SET_REGION = 11;
/// DRM_FORMAT_MOD_LINEAR
pub const MOD_LINEAR: u64 = 0;
// MIT-SHM's
pub const SHM_QUERY_VERSION = 0;
pub const SHM_DETACH = 2;
pub const SHM_PUT_IMAGE = 3;
pub const SHM_ATTACH_FD = 6;
// Present's
pub const PRESENT_QUERY_VERSION = 0;
pub const PRESENT_PIXMAP = 1;
pub const PRESENT_SELECT_INPUT = 3;
pub const PRESENT_CONFIGURE_NOTIFY = 0;
pub const PRESENT_COMPLETE_NOTIFY = 1;
pub const PRESENT_IDLE_NOTIFY = 2;
pub const PRESENT_MASK_CONFIGURE: u32 = 1;
pub const PRESENT_MASK_COMPLETE: u32 = 2;
pub const PRESENT_MASK_IDLE: u32 = 4;
pub const PRESENT_OPTION_ASYNC: u32 = 1;
pub const GENERIC_EVENT = 35;
pub const Z_PIXMAP = 2;
/// errors a window gone gives
pub const BAD_WINDOW = 3;
pub const BAD_PIXMAP = 4;
pub const BAD_MATCH = 8;
pub const BAD_DRAWABLE = 9;
pub const BAD_ALLOC = 11;
pub const BAD_IMPLEMENTATION = 17;

/// The connection setup request: little endian, protocol 11.0, no
/// authorization.
pub fn setupRequest() [12]u8 {
    return .{ 'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}

pub const TRUE_COLOR = 4;

/// What EGL takes from the setup reply.
pub const Setup = struct {
    xid_base: u32 = 0,
    xid_mask: u32 = 0,
    /// the longest request, in 4-byte units
    max_request_words: u32 = 0,
    /// images sent least significant byte first (what EGL's BGRA rows are)
    lsb_images: bool = true,
    /// bits per pixel of depth 24's and 32's images (0: no such format)
    bpp24: u8 = 0,
    bpp32: u8 = 0,
    root: u32 = 0,
    root_visual: u32 = 0,
    root_depth: u8 = 0,
    width: u16 = 0,
    height: u16 = 0,
    /// TrueColor visuals with 8 bits of red, green, blue (0: none)
    visual24: u32 = 0,
    visual32: u32 = 0,
};

/// The setup reply's body (after its 8 bytes), for `screen`: null when it
/// is too short or has no such screen.
pub fn parseSetup(body: []const u8, screen: u32) ?Setup {
    if (body.len < 32) return null;
    var s = Setup{
        .xid_base = get32(body[4..]),
        .xid_mask = get32(body[8..]),
        .max_request_words = get16(body[18..]),
        .lsb_images = body[22] == 0,
    };
    if (s.xid_mask == 0) return null;
    const vendor_len: usize = get16(body[16..]);
    const nscreens: usize = body[20];
    const nformats: usize = body[21];
    var off = 32 + pad4(vendor_len);
    if (off + nformats * 8 > body.len) return null;
    for (0..nformats) |i| {
        const f = body[off + i * 8 ..];
        if (f[0] == 24) s.bpp24 = f[1];
        if (f[0] == 32) s.bpp32 = f[1];
    }
    off += nformats * 8;
    if (screen >= nscreens) return null;
    var k: usize = 0;
    while (true) : (k += 1) {
        if (off + 40 > body.len) return null;
        const scr = body[off..];
        const ndepths: usize = scr[39];
        if (k == screen) {
            s.root = get32(scr[0..]);
            s.width = get16(scr[20..]);
            s.height = get16(scr[22..]);
            s.root_visual = get32(scr[32..]);
            s.root_depth = scr[38];
        }
        off += 40;
        for (0..ndepths) |_| {
            if (off + 8 > body.len) return null;
            const depth = body[off];
            const nvisuals: usize = get16(body[off + 2 ..]);
            off += 8;
            if (off + nvisuals * 24 > body.len) return null;
            if (k == screen) {
                for (0..nvisuals) |v| {
                    const vis = body[off + v * 24 ..];
                    const id = get32(vis[0..]);
                    const rgb = vis[4] == TRUE_COLOR and get32(vis[8..]) == 0xff0000 and get32(vis[12..]) == 0xff00 and get32(vis[16..]) == 0xff;
                    if (!rgb) continue;
                    if (depth == 24 and (s.visual24 == 0 or id == s.root_visual)) s.visual24 = id;
                    if (depth == 32 and s.visual32 == 0) s.visual32 = id;
                }
            }
            off += nvisuals * 24;
        }
        if (k == screen) return s;
    }
}

/// An X error (what the server said of one request).
pub const XError = struct { code: u8, seq: u32, value: u32, major: u8, minor: u16 };

// ── The connection ─────────────────────────────────────────────────────────

pub const MAX_WINDOWS = 16;
/// Damage rectangles a swap sends apart (more: the whole window).
pub const MAX_RECTS = 64;
pub const MAX_BUFFERS = 4;
const OUT_BYTES = 4096;
const EXTRA_BYTES = 256;
const MAX_ERRORS = 8;
/// The setup reply is read here (its length is 16 bits of words).
var setup_body: [0xffff * 4]u8 = undefined;
/// PutImage's rows, packed (every connection's: the driver lock is held).
var staging: [STAGE_BYTES]u8 = undefined;
/// The largest PutImage request: what the core protocol allows without
/// BIG-REQUESTS, or the server's maximum if smaller.
pub const STAGE_BYTES = 0xffff * 4;

pub const Ext = struct { opcode: u8, first_event: u8 };

pub const Conn = struct {
    wire: *const Wire = undefined,
    fd: i32 = -1,
    setup: Setup = .{},
    /// requests sent (their low 16 bits are the server's sequence numbers)
    sent: u32 = 0,
    xid_next: u32 = 0,
    out: [OUT_BYTES]u8 = undefined,
    out_len: usize = 0,
    dri3: ?Ext = null,
    /// DRI3's minor version as the server answered (2: PixmapFromBuffers)
    dri3_minor: u32 = 0,
    present: ?Ext = null,
    /// XFIXES 2 (regions: Present's update), where Present is
    xfixes: ?Ext = null,
    /// MIT-SHM 1.2 (ShmAttachFd), where the Wire has shared memory
    shm: ?Ext = null,
    /// errors for requests no reply waited for (the last MAX_ERRORS)
    errors: [MAX_ERRORS]XError = undefined,
    n_errors: usize = 0,
    windows: [MAX_WINDOWS]?*Window = [_]?*Window{null} ** MAX_WINDOWS,
    broken: bool = false,
    extra: [EXTRA_BYTES]u8 = undefined,
    stats: struct { round_trips: u64 = 0, events: u64 = 0, bytes_out: u64 = 0, errors: u64 = 0 } = .{},

    pub fn live(c: *const Conn) bool {
        return c.fd >= 0 and !c.broken;
    }

    /// The connection to display `name`: its socket, the setup (for
    /// `screen`, or the name's), DRI3 and Present looked up. False when
    /// there is no such server, it refuses, or its screen draws no 32-bit
    /// pixels.
    pub fn open(c: *Conn, wire: *const Wire, name: []const u8, screen: ?u32) bool {
        c.* = .{ .wire = wire };
        const addr = parseName(name) orelse {
            report.say(.egl_error, "X11: display \"{s}\" is not a local one (only Unix sockets are spoken)", .{name});
            return false;
        };
        var fd = wire.connect(wire.ctx, addr.slice(), false);
        if (fd < 0 and addr.abstract) fd = wire.connect(wire.ctx, addr.slice(), true);
        if (fd < 0) {
            report.say(.egl_error, "X11: no server at {s} (errno {d})", .{ addr.slice(), -fd });
            return false;
        }
        c.fd = fd;
        if (!c.handshake(screen orelse addr.screen)) {
            c.close();
            return false;
        }
        c.dri3 = c.queryExtension("DRI3");
        c.present = c.queryExtension("Present");
        if (c.broken) {
            c.close();
            return false;
        }
        // (DRI3 1.2's PixmapFromBuffers, else 1.0's PixmapFromBuffer, and
        // Present 1.0's PresentPixmap are all EGL asks; the versions are
        // said so the server enables them)
        if (c.dri3) |e| {
            if (c.queryVersion(e, DRI3_QUERY_VERSION, 1, 2)) |minor| {
                c.dri3_minor = minor;
            } else c.dri3 = null;
        }
        if (c.present) |e| {
            if (c.queryVersion(e, PRESENT_QUERY_VERSION, 1, 0) == null) c.present = null;
        }
        // (a frame's damage as Present's update region)
        if (c.present != null) {
            c.xfixes = c.queryExtension("XFIXES");
            if (c.xfixes) |e| {
                const r = c.begin(e.opcode, XFIXES_QUERY_VERSION, 3);
                if (r) |q| {
                    put32(q.b[4..], 5);
                    put32(q.b[8..], 0);
                    const rep = c.wait(q.seq);
                    if (rep == null or get32(rep.?[8..]) < 2) c.xfixes = null;
                } else c.xfixes = null;
            }
        }
        if (wire.shm_create != null and wire.shm_destroy != null) {
            c.shm = c.queryExtension("MIT-SHM");
            if (c.shm) |e| {
                if (!c.shmVersion(e)) c.shm = null;
            }
        }
        if (c.broken) {
            c.close();
            return false;
        }
        report.say(.device, "X11: {s} {d}x{d}, depth {d}; DRI3 {s}, Present {s}, XFIXES {s}, MIT-SHM {s}", .{ name, c.setup.width, c.setup.height, c.setup.root_depth, if (c.dri3 == null) "no" else if (c.dri3_minor >= 2) "1.2" else "1.0", if (c.present != null) "yes" else "no", if (c.xfixes != null) "yes" else "no", if (c.shm != null) "yes" else "no" });
        return true;
    }

    fn handshake(c: *Conn, screen: u32) bool {
        const req = setupRequest();
        if (!c.sendAll(&req, &.{})) return false;
        var head: [8]u8 = undefined;
        if (!c.readAll(&head)) return false;
        const len = @as(usize, get16(head[6..])) * 4;
        if (!c.readAll(setup_body[0..len])) return false;
        if (head[0] != 1) {
            const why_len: usize = head[1];
            report.say(.egl_error, "X11: the server refused the connection: {s}", .{if (head[0] == 0) setup_body[0..@min(why_len, len)] else "it asks for authorization"});
            return false;
        }
        c.setup = parseSetup(setup_body[0..len], screen) orelse {
            report.say(.egl_error, "X11: the server's setup has no screen {d}", .{screen});
            return false;
        };
        return true;
    }

    pub fn close(c: *Conn) void {
        if (c.fd >= 0) {
            _ = c.flush();
            c.wire.close(c.wire.ctx, c.fd);
        }
        c.fd = -1;
    }

    /// A new resource id, or null when the range is spent.
    pub fn newXid(c: *Conn) ?u32 {
        const mask = c.setup.xid_mask;
        const inc = mask & (~mask +% 1);
        if (c.xid_next > mask - inc) return null;
        c.xid_next += inc;
        return c.setup.xid_base | c.xid_next;
    }

    fn sendAll(c: *Conn, bytes: []const u8, fds: []const i32) bool {
        if (c.broken or c.fd < 0) return false;
        var rest = bytes;
        var first = true;
        while (rest.len > 0) {
            const r = c.wire.send(c.wire.ctx, c.fd, rest, if (first) fds else &.{});
            if (r <= 0) {
                c.lost("sending", r);
                return false;
            }
            first = false;
            rest = rest[@intCast(r)..];
            c.stats.bytes_out += @intCast(r);
        }
        return true;
    }

    fn readAll(c: *Conn, buf: []u8) bool {
        if (c.broken or c.fd < 0) return false;
        var got: usize = 0;
        while (got < buf.len) {
            const r = c.wire.recv(c.wire.ctx, c.fd, buf[got..]);
            if (r <= 0) {
                c.lost("reading", r);
                return false;
            }
            got += @intCast(r);
        }
        return true;
    }

    fn lost(c: *Conn, what: []const u8, r: isize) void {
        if (!c.broken) report.say(.egl_error, "X11: the connection broke {s} (errno {d})", .{ what, -r });
        c.broken = true;
    }

    /// The requests written so far, sent.
    pub fn flush(c: *Conn) bool {
        if (c.out_len == 0) return !c.broken;
        const n = c.out_len;
        c.out_len = 0;
        return c.sendAll(c.out[0..n], &.{});
    }

    /// A request of `words` 4-byte units (its first byte `op`, its second
    /// `data`, its length set): its bytes, zeroed, to fill in, and its
    /// number. Null when the connection is broken.
    fn begin(c: *Conn, op: u8, data: u8, words: usize) ?struct { b: []u8, seq: u32 } {
        const n = words * 4;
        std.debug.assert(n <= OUT_BYTES and words <= 0xffff);
        if (c.out_len + n > OUT_BYTES and !c.flush()) return null;
        if (c.broken) return null;
        const b = c.out[c.out_len..][0..n];
        @memset(b, 0);
        b[0] = op;
        b[1] = data;
        put16(b[2..], @intCast(words));
        c.out_len += n;
        c.sent +%= 1;
        return .{ .b = b, .seq = c.sent };
    }

    /// A request sent with fds (the ones written before it go first).
    fn sendWithFds(c: *Conn, req: []const u8, fds: []const i32) ?u32 {
        if (!c.flush()) return null;
        c.sent +%= 1;
        if (!c.sendAll(req, fds)) return null;
        return c.sent;
    }

    /// One packet from the server: its 32 bytes, and what follows them
    /// (a reply's or a generic event's), kept up to EXTRA_BYTES.
    fn next(c: *Conn, head: *[32]u8) ?[]const u8 {
        if (!c.readAll(head)) return null;
        const more: usize = if (head[0] == 1 or (head[0] & 0x7f) == GENERIC_EVENT) @as(usize, get32(head[4..])) * 4 else 0;
        const keep = @min(more, c.extra.len);
        if (!c.readAll(c.extra[0..keep])) return null;
        var left = more - keep;
        var junk: [256]u8 = undefined;
        while (left > 0) {
            const k = @min(left, junk.len);
            if (!c.readAll(junk[0..k])) return null;
            left -= k;
        }
        return c.extra[0..keep];
    }

    /// The full number of the request a packet's 16-bit sequence names
    /// (the latest sent with those bits).
    fn seqOf(c: *const Conn, s16: u16) u32 {
        var full = (c.sent & ~@as(u32, 0xffff)) | s16;
        if (full > c.sent) full -%= 0x10000;
        return full;
    }

    /// The reply to request `seq` (flushed first): its 32 bytes, the rest
    /// in c.extra. Null when the server answered with an error (kept) or
    /// the connection broke. Events and other errors on the way are
    /// handled.
    pub fn wait(c: *Conn, seq: u32) ?[32]u8 {
        if (!c.flush()) return null;
        c.stats.round_trips += 1;
        while (true) {
            var head: [32]u8 = undefined;
            const extra = c.next(&head) orelse return null;
            const s = c.seqOf(get16(head[2..]));
            if (head[0] == 1 and s == seq) return head;
            if (head[0] == 0) {
                c.keepError(&head);
                if (s == seq) return null;
                continue;
            }
            if (head[0] == 1) continue; // (a reply nobody waits for)
            c.event(&head, extra);
        }
    }

    /// What has arrived, handled, without waiting; with `block`, waiting
    /// for at least one packet. False when the connection broke.
    pub fn pump(c: *Conn, block: bool) bool {
        if (!c.flush()) return false;
        var first = block;
        while (true) {
            if (!first) {
                const r = c.wire.poll(c.wire.ctx, c.fd, 0);
                if (r < 0) {
                    c.lost("polling", r);
                    return false;
                }
                if (r == 0) return true;
            }
            first = false;
            var head: [32]u8 = undefined;
            const extra = c.next(&head) orelse return false;
            if (head[0] == 0) c.keepError(&head) else if (head[0] != 1) c.event(&head, extra);
        }
    }

    /// A round trip (GetInputFocus): every request before it answered,
    /// its errors kept. False when the connection broke.
    pub fn sync(c: *Conn) bool {
        const r = c.begin(OP_GET_INPUT_FOCUS, 0, 1) orelse return false;
        return c.wait(r.seq) != null;
    }

    fn keepError(c: *Conn, head: *const [32]u8) void {
        const e = XError{ .code = head[1], .seq = c.seqOf(get16(head[2..])), .value = get32(head[4..]), .minor = get16(head[8..]), .major = head[10] };
        c.errors[c.n_errors % MAX_ERRORS] = e;
        c.n_errors += 1;
        c.stats.errors += 1;
    }

    /// The error the server gave request `seq`, if one is kept.
    pub fn errorOf(c: *const Conn, seq: u32) ?XError {
        const n = @min(c.n_errors, MAX_ERRORS);
        for (0..n) |i| {
            const e = c.errors[(c.n_errors - 1 - i) % MAX_ERRORS];
            if (e.seq == seq) return e;
        }
        return null;
    }

    /// An error for any request in [from, to].
    pub fn errorIn(c: *const Conn, from: u32, to: u32) ?XError {
        const n = @min(c.n_errors, MAX_ERRORS);
        for (0..n) |i| {
            const e = c.errors[(c.n_errors - 1 - i) % MAX_ERRORS];
            if (e.seq -% from <= to -% from) return e;
        }
        return null;
    }

    fn event(c: *Conn, head: *const [32]u8, extra: []const u8) void {
        c.stats.events += 1;
        const p = c.present orelse return;
        if ((head[0] & 0x7f) != GENERIC_EVENT or head[1] != p.opcode) return;
        // (a Present event: 32 bytes and its extra, as one)
        var ev: [64]u8 = [_]u8{0} ** 64;
        @memcpy(ev[0..32], head);
        const k = @min(extra.len, 32);
        @memcpy(ev[32..][0..k], extra[0..k]);
        const evtype = get16(ev[8..]);
        const eid = get32(ev[12..]);
        for (c.windows) |wp| {
            const w = wp orelse continue;
            if (w.eid == eid) {
                w.onPresent(evtype, &ev);
                return;
            }
        }
    }

    // ── requests ──

    /// QueryExtension: the extension's major opcode and first event, or
    /// null when the server has none.
    pub fn queryExtension(c: *Conn, name: []const u8) ?Ext {
        const r = c.begin(OP_QUERY_EXTENSION, 0, 2 + pad4(name.len) / 4) orelse return null;
        put16(r.b[4..], @intCast(name.len));
        @memcpy(r.b[8..][0..name.len], name);
        const rep = c.wait(r.seq) orelse return null;
        if (rep[8] == 0) return null;
        return .{ .opcode = rep[9], .first_event = rep[10] };
    }

    /// An extension's QueryVersion: the server's minor version when its
    /// major is `major` or later, else null.
    fn queryVersion(c: *Conn, e: Ext, minor_op: u8, major: u32, minor: u32) ?u32 {
        const r = c.begin(e.opcode, minor_op, 3) orelse return null;
        put32(r.b[4..], major);
        put32(r.b[8..], minor);
        const rep = c.wait(r.seq) orelse return null;
        if (get32(rep[8..]) < major) return null;
        return if (get32(rep[8..]) > major) 0xffff else get32(rep[12..]);
    }

    /// MIT-SHM's QueryVersion: 1.2 or later (ShmAttachFd).
    fn shmVersion(c: *Conn, e: Ext) bool {
        const r = c.begin(e.opcode, SHM_QUERY_VERSION, 1) orelse return false;
        const rep = c.wait(r.seq) orelse return false;
        const major = get16(rep[8..]);
        const minor = get16(rep[10..]);
        return major > 1 or (major == 1 and minor >= 2);
    }

    /// ShmAttachFd: segment `seg` over the shared memory file `fd` (sent
    /// with it), read only for the server.
    fn shmAttachFd(c: *Conn, seg: u32, fd: i32) ?u32 {
        const e = c.shm orelse return null;
        var req = [_]u8{0} ** 12;
        req[0] = e.opcode;
        req[1] = SHM_ATTACH_FD;
        put16(req[2..], 3);
        put32(req[4..], seg);
        req[8] = 1; // read only
        return c.sendWithFds(&req, &.{fd});
    }

    fn shmDetach(c: *Conn, seg: u32) void {
        const e = c.shm orelse return;
        const r = c.begin(e.opcode, SHM_DETACH, 2) orelse return;
        put32(r.b[4..], seg);
    }

    /// ShmPutImage (ZPixmap) of the rectangle (x, y, w, h) of an image of
    /// total_w x total_h at `offset` in segment `seg`, to the same place
    /// of `drawable`.
    fn shmPutImage(c: *Conn, drawable: u32, gc: u32, total_w: u32, total_h: u32, x: u32, y: u32, w: u32, h: u32, depth: u8, seg: u32, offset: u32) ?u32 {
        const e = c.shm orelse return null;
        const r = c.begin(e.opcode, SHM_PUT_IMAGE, 10) orelse return null;
        put32(r.b[4..], drawable);
        put32(r.b[8..], gc);
        put16(r.b[12..], @intCast(total_w));
        put16(r.b[14..], @intCast(total_h));
        put16(r.b[16..], @intCast(x));
        put16(r.b[18..], @intCast(y));
        put16(r.b[20..], @intCast(w));
        put16(r.b[22..], @intCast(h));
        put16(r.b[24..], @intCast(x));
        put16(r.b[26..], @intCast(y));
        r.b[28] = depth;
        r.b[29] = Z_PIXMAP;
        r.b[30] = 0; // no completion event: the round trip after says it
        put32(r.b[32..], seg);
        put32(r.b[36..], offset);
        return r.seq;
    }

    pub const Geometry = struct { depth: u8, width: u32, height: u32 };

    /// GetGeometry of a drawable, or null (an error: it is gone).
    pub fn geometry(c: *Conn, drawable: u32) ?Geometry {
        const r = c.begin(OP_GET_GEOMETRY, 0, 2) orelse return null;
        put32(r.b[4..], drawable);
        const rep = c.wait(r.seq) orelse return null;
        return .{ .depth = rep[1], .width = get16(rep[16..]), .height = get16(rep[18..]) };
    }

    fn createGc(c: *Conn, gc: u32, drawable: u32) ?u32 {
        const r = c.begin(OP_CREATE_GC, 0, 4) orelse return null;
        put32(r.b[4..], gc);
        put32(r.b[8..], drawable);
        put32(r.b[12..], 0); // (no values)
        return r.seq;
    }

    fn freeGc(c: *Conn, gc: u32) void {
        const r = c.begin(OP_FREE_GC, 0, 2) orelse return;
        put32(r.b[4..], gc);
    }

    fn freePixmap(c: *Conn, pixmap: u32) void {
        const r = c.begin(OP_FREE_PIXMAP, 0, 2) orelse return;
        put32(r.b[4..], pixmap);
    }

    /// PutImage (ZPixmap) of `rows` (rows of w * 4 bytes, packed) at
    /// (x, y) of `drawable`: its number.
    fn putImage(c: *Conn, drawable: u32, gc: u32, depth: u8, x: u32, y: u32, w: u32, h: u32, rows: []const u8) ?u32 {
        var head = [_]u8{0} ** 24;
        head[0] = OP_PUT_IMAGE;
        head[1] = Z_PIXMAP;
        put16(head[2..], @intCast((24 + rows.len) / 4));
        put32(head[4..], drawable);
        put32(head[8..], gc);
        put16(head[12..], @intCast(w));
        put16(head[14..], @intCast(h));
        put16(head[16..], @intCast(x));
        put16(head[18..], @intCast(y));
        head[20] = 0; // left pad
        head[21] = depth;
        if (!c.flush()) return null;
        c.sent +%= 1;
        if (!c.sendAll(&head, &.{}) or !c.sendAll(rows, &.{})) return null;
        return c.sent;
    }

    /// DRI3 PixmapFromBuffer: `pixmap` made from the dma-buf `fd` (sent
    /// with it; the caller keeps its own).
    fn pixmapFromBuffer(c: *Conn, pixmap: u32, drawable: u32, fd: i32, size: u32, w: u32, h: u32, stride: u32, depth: u8) ?u32 {
        const e = c.dri3 orelse return null;
        var req = [_]u8{0} ** 24;
        req[0] = e.opcode;
        req[1] = DRI3_PIXMAP_FROM_BUFFER;
        put16(req[2..], 6);
        put32(req[4..], pixmap);
        put32(req[8..], drawable);
        put32(req[12..], size);
        put16(req[16..], @intCast(w));
        put16(req[18..], @intCast(h));
        put16(req[20..], @intCast(stride));
        req[22] = depth;
        req[23] = 32;
        return c.sendWithFds(&req, &.{fd});
    }

    /// DRI3 1.2 PixmapFromBuffers: `pixmap` made from the one-plane dma-buf
    /// `fd` (sent with it; the caller keeps its own) with `modifier`.
    fn pixmapFromBuffers(c: *Conn, pixmap: u32, window: u32, fd: i32, w: u32, h: u32, stride: u32, depth: u8, modifier: u64) ?u32 {
        const e = c.dri3 orelse return null;
        var req = [_]u8{0} ** 64;
        req[0] = e.opcode;
        req[1] = DRI3_PIXMAP_FROM_BUFFERS;
        put16(req[2..], 16);
        put32(req[4..], pixmap);
        put32(req[8..], window);
        req[12] = 1; // one buffer
        put16(req[16..], @intCast(w));
        put16(req[18..], @intCast(h));
        put32(req[20..], stride); // stride0, offset0 (0); the other planes 0
        req[52] = depth;
        req[53] = 32;
        put64(req[56..], modifier);
        return c.sendWithFds(&req, &.{fd});
    }

    /// XFIXES CreateRegion (`op` XFIXES_CREATE_REGION) or SetRegion
    /// (XFIXES_SET_REGION) of `region` from rectangles (x, y, w, h).
    fn region(c: *Conn, op: u8, id: u32, rects: []const [4]u32) ?u32 {
        const e = c.xfixes orelse return null;
        const r = c.begin(e.opcode, op, 2 + 2 * rects.len) orelse return null;
        put32(r.b[4..], id);
        for (rects, 0..) |q, i| {
            const at = r.b[8 + 8 * i ..];
            put16(at[0..], @intCast(q[0]));
            put16(at[2..], @intCast(q[1]));
            put16(at[4..], @intCast(q[2]));
            put16(at[6..], @intCast(q[3]));
        }
        return r.seq;
    }

    fn destroyRegion(c: *Conn, id: u32) void {
        const e = c.xfixes orelse return;
        const r = c.begin(e.opcode, XFIXES_DESTROY_REGION, 2) orelse return;
        put32(r.b[4..], id);
    }

    fn presentSelectInput(c: *Conn, eid: u32, window: u32, mask: u32) ?u32 {
        const e = c.present orelse return null;
        const r = c.begin(e.opcode, PRESENT_SELECT_INPUT, 4) orelse return null;
        put32(r.b[4..], eid);
        put32(r.b[8..], window);
        put32(r.b[12..], mask);
        return r.seq;
    }

    /// PresentPixmap: `update` the region that changed (None: all of it).
    fn presentPixmap(c: *Conn, window: u32, pixmap: u32, serial: u32, update: u32, options: u32) ?u32 {
        const e = c.present orelse return null;
        const r = c.begin(e.opcode, PRESENT_PIXMAP, 18) orelse return null;
        put32(r.b[4..], window);
        put32(r.b[8..], pixmap);
        put32(r.b[12..], serial);
        // valid: None (all of it, so Xwayland may flip); x_off, y_off 0;
        // target_crtc, wait_fence, idle_fence None (the dma-buf's
        // implicit fences)
        put32(r.b[20..], update);
        put32(r.b[40..], options);
        // target_msc, divisor, remainder 0: the next frame
        return r.seq;
    }
};

// ── Windows ────────────────────────────────────────────────────────────────

pub const Mode = enum { present, shm, put_image };

pub const Buffer = struct {
    img: Image = .{},
    /// its pixmap (Present's way), 0: none
    pixmap: u32 = 0,
    /// the server holds it (presented, not idle yet)
    busy: bool = false,
    /// of an old size: freed once idle
    stale: bool = false,
    /// the frame it was last shown at (0: never)
    shown: u64 = 0,
};

pub const Window = struct {
    conn: *Conn,
    eng: *Engine,
    host: Host,
    xid: u32,
    alpha: bool,
    mode: Mode = .put_image,
    depth: u8 = 24,
    width: u32 = 0,
    height: u32 = 0,
    bufs: [MAX_BUFFERS]Buffer = [_]Buffer{.{}} ** MAX_BUFFERS,
    back: ?usize = null,
    interval: u32 = 1,
    frames: u64 = 0,
    /// Present's: the event id, the last serial presented and whether its
    /// CompleteNotify is still to come
    eid: u32 = 0,
    serial: u32 = 0,
    completing: bool = false,
    /// PutImage's and MIT-SHM's graphics context
    gc: u32 = 0,
    /// Present's update region (XFIXES), 0: none made yet
    region: u32 = 0,
    /// the last frame's update was a region (0: the whole window)
    last_update: u32 = 0,
    /// MIT-SHM's segment (0: none yet) and its memory
    seg: u32 = 0,
    shm: ?Shm = null,
    /// eglDestroySurface'd while current: shows nothing more
    gone: bool = false,
    /// the size may have changed (a swap, or Present's ConfigureNotify):
    /// GL takes a back buffer afresh at its next drawing (egl.sig's
    /// revalidate, which clears it as it binds)
    resized: std.atomic.Value(bool) = .init(false),
    stats: struct { swaps: u64 = 0, idle_waits: u64 = 0, complete_waits: u64 = 0, made: u64 = 0, put_bytes: u64 = 0, put_requests: u64 = 0, geometry: u64 = 0, partial: u64 = 0 } = .{},

    /// A window in place over X window `xid` (it stays at `w`: events find
    /// it there). False when the window is not the server's, its depth is
    /// not one EGL draws (24 or 32, 32 bits a pixel), or no window slot is
    /// free.
    pub fn init(w: *Window, conn: *Conn, eng: *Engine, host: Host, xid: u32, alpha: bool) bool {
        w.* = .{ .conn = conn, .eng = eng, .host = host, .xid = xid, .alpha = alpha };
        if (!conn.live()) return false;
        const g = conn.geometry(xid) orelse {
            report.say(.egl_error, "X11: window 0x{x} is not the server's", .{xid});
            return false;
        };
        const bpp = switch (g.depth) {
            24 => conn.setup.bpp24,
            32 => conn.setup.bpp32,
            else => 0,
        };
        if (bpp != 32 or !conn.setup.lsb_images) {
            report.say(.egl_error, "X11: window 0x{x} has depth {d} ({d} bits a pixel): EGL draws 24 and 32 in 32", .{ xid, g.depth, bpp });
            return false;
        }
        w.depth = g.depth;
        w.width = @max(g.width, 1);
        w.height = @max(g.height, 1);
        const slot = for (&conn.windows) |*s| {
            if (s.* == null) break s;
        } else return false;
        w.mode = if (conn.dri3 != null and conn.present != null) .present else if (conn.shm != null) .shm else .put_image;
        if (w.mode == .present) {
            w.eid = conn.newXid() orelse return false;
            _ = conn.presentSelectInput(w.eid, xid, PRESENT_MASK_CONFIGURE | PRESENT_MASK_COMPLETE | PRESENT_MASK_IDLE) orelse return false;
        } else if (!w.makeGc()) return false;
        slot.* = w;
        _ = conn.flush();
        return true;
    }

    fn makeGc(w: *Window) bool {
        w.gc = w.conn.newXid() orelse return false;
        _ = w.conn.createGc(w.gc, w.xid) orelse return false;
        return true;
    }

    /// The window shows nothing more (eglDestroySurface of a surface still
    /// current); its buffers stay until deinit.
    pub fn detach(w: *Window) void {
        w.gone = true;
    }

    pub fn deinit(w: *Window) void {
        const c = w.conn;
        for (&w.bufs) |*b| w.drop(b);
        w.dropSegment();
        if (c.live()) {
            if (w.eid != 0) _ = c.presentSelectInput(w.eid, w.xid, 0);
            if (w.region != 0) c.destroyRegion(w.region);
            if (w.gc != 0) c.freeGc(w.gc);
            _ = c.flush();
        }
        for (&c.windows) |*s| {
            if (s.* == w) s.* = null;
        }
        w.eid = 0;
        w.gc = 0;
        w.region = 0;
    }

    /// MIT-SHM's segment detached and its memory let go.
    fn dropSegment(w: *Window) void {
        const c = w.conn;
        if (w.seg != 0 and c.live()) c.shmDetach(w.seg);
        w.seg = 0;
        if (w.shm) |m| c.wire.shm_destroy.?(c.wire.ctx, m);
        w.shm = null;
    }

    /// A segment of at least `size` bytes, attached (a new one when the
    /// window grew). False when there is no memory or the server refused
    /// it (the window is then turned to PutImage).
    fn segment(w: *Window, size: usize) bool {
        const c = w.conn;
        if (w.shm) |m| {
            if (m.mem.len >= size) return true;
        }
        w.dropSegment();
        const m = c.wire.shm_create.?(c.wire.ctx, size) orelse {
            report.say(.egl_error, "X11: no shared memory of {d} bytes for MIT-SHM: PutImage instead", .{size});
            w.mode = .put_image;
            return false;
        };
        w.shm = m;
        w.seg = c.newXid() orelse {
            w.dropSegment();
            return false;
        };
        const seq = c.shmAttachFd(w.seg, m.fd) orelse return false;
        if (!c.sync()) return false;
        if (c.errorOf(seq)) |e| {
            report.say(.egl_error, "X11: the server refused shared memory (error {d}): PutImage instead", .{e.code});
            w.seg = 0;
            w.dropSegment();
            w.mode = .put_image;
            return false;
        }
        return true;
    }

    fn drop(w: *Window, b: *Buffer) void {
        if (b.pixmap != 0 and w.conn.live()) w.conn.freePixmap(b.pixmap);
        w.eng.freeImage(&b.img);
        b.* = .{};
    }

    /// The size the next frame has, as last seen.
    pub fn wanted(w: *const Window) [2]u32 {
        return .{ w.width, w.height };
    }

    /// The back buffer's image, taken now if need be (the window's size
    /// asked first): an idle buffer of that size, else a new one; with all
    /// of them held, EGL waits for one to be idle. Null when the window is
    /// gone, there is no memory, or the connection broke.
    pub fn backImage(w: *Window) ?*Image {
        if (w.back) |i| return &w.bufs[i].img;
        const c = w.conn;
        // (Present's events that arrived meanwhile: idle buffers, sizes)
        if (!c.pump(false)) return null;
        const g = c.geometry(w.xid) orelse return null;
        w.stats.geometry += 1;
        const width = @max(g.width, 1);
        const height = @max(g.height, 1);
        if (width != w.width or height != w.height) {
            w.width = width;
            w.height = height;
            for (&w.bufs) |*b| {
                if (!b.img.live()) continue;
                if (b.busy) b.stale = true else w.drop(b);
            }
        }
        choose: while (true) {
            // an idle one: the most recently shown (the smallest age)
            var pick: ?usize = null;
            for (&w.bufs, 0..) |*b, i| {
                if (!b.img.live() or b.busy or b.stale) continue;
                if (pick == null or b.shown > w.bufs[pick.?].shown) pick = i;
            }
            if (pick == null) {
                for (&w.bufs, 0..) |*b, i| {
                    if (b.img.live() or b.busy) continue;
                    if (!w.make(b)) {
                        // (the server refused the dma-buf: MIT-SHM or
                        // PutImage from now)
                        if (w.mode != .present and w.gc == 0) {
                            if (!w.makeGc()) return null;
                            continue :choose;
                        }
                        return null;
                    }
                    pick = i;
                    break;
                }
            }
            if (pick) |i| {
                w.back = i;
                return &w.bufs[i].img;
            }
            w.stats.idle_waits += 1;
            if (!c.pump(true)) return null;
        }
    }

    /// A new buffer of the window's size: GPU memory and, Present's way,
    /// its pixmap. False with no memory, or when the server refused the
    /// dma-buf (the window is turned to PutImage: the buffer is not made).
    fn make(w: *Window, b: *Buffer) bool {
        b.* = .{};
        var img = w.eng.newWindowImage(w.width, w.height, .bgra8) orelse {
            report.say(.egl_error, "X11: could not allocate a {d}x{d} window buffer", .{ w.width, w.height });
            return false;
        };
        img.top_down = true;
        img.no_alpha = !w.alpha;
        b.img = img;
        if (w.mode != .present) {
            w.stats.made += 1;
            return true;
        }
        const c = w.conn;
        const fd = if (img.stride <= 0xffff) w.host.exportFd(w.host.ctx, img.buf) else -22;
        if (fd < 0) {
            report.say(.egl_error, "X11: could not export a {d}x{d} window buffer (errno {d}): PutImage instead", .{ w.width, w.height, -fd });
            w.eng.freeImage(&b.img);
            w.toPutImage();
            return false;
        }
        defer w.host.close(w.host.ctx, @intCast(fd));
        const pixmap = c.newXid() orelse {
            w.eng.freeImage(&b.img);
            return false;
        };
        const seq = (if (c.dri3_minor >= 2)
            c.pixmapFromBuffers(pixmap, w.xid, @intCast(fd), img.width, img.height, img.stride, w.depth, MOD_LINEAR)
        else
            c.pixmapFromBuffer(pixmap, w.xid, @intCast(fd), img.stride * img.height, img.width, img.height, img.stride, w.depth)) orelse {
            w.eng.freeImage(&b.img);
            return false;
        };
        // (whether the server took it: a round trip, once a buffer)
        if (!c.sync()) {
            w.eng.freeImage(&b.img);
            return false;
        }
        if (c.errorOf(seq)) |e| {
            report.say(.egl_error, "X11: the server refused a {d}x{d} dma-buf (error {d}): PutImage instead", .{ w.width, w.height, e.code });
            w.eng.freeImage(&b.img);
            w.toPutImage();
            return false;
        }
        b.pixmap = pixmap;
        w.stats.made += 1;
        return true;
    }

    /// Present's way given up for good (the server takes no dma-buf of
    /// ours): MIT-SHM's from now, else PutImage's; idle pixmaps go, busy
    /// ones once idle.
    fn toPutImage(w: *Window) void {
        w.mode = if (w.conn.shm != null) .shm else .put_image;
        for (&w.bufs) |*b| {
            if (!b.img.live()) continue;
            if (b.busy) b.stale = true else w.drop(b);
        }
    }

    /// The back buffer, not shown yet, given up (the window may have been
    /// resized): the next one is taken afresh.
    pub fn dropBack(w: *Window) void {
        w.back = null;
    }

    /// EGL_EXT_buffer_age's answer for the back buffer.
    pub fn age(w: *Window) i32 {
        _ = w.backImage() orelse return 0;
        const b = &w.bufs[w.back.?];
        if (b.shown == 0) return 0;
        return @intCast(@min(w.frames - b.shown + 1, std.math.maxInt(i32)));
    }

    /// The back buffer shown: `damage` (x, y, width, height from the
    /// bottom left, as EGL gives them; none: everything). False when the
    /// window is gone (an X error for it) or the connection broke.
    pub fn swap(w: *Window, damage: []const [4]i32) bool {
        if (w.gone) return false;
        _ = w.backImage() orelse return false;
        const ok = switch (w.mode) {
            .present => w.swapPresent(damage),
            .shm => w.swapShm(damage) or (w.mode == .put_image and w.swapPutImage(damage)),
            .put_image => w.swapPutImage(damage),
        };
        if (!ok) return false;
        w.stats.swaps += 1;
        // (the next frame's size is asked at its first drawing)
        w.resized.store(true, .release);
        return true;
    }

    fn swapPresent(w: *Window, damage: []const [4]i32) bool {
        const c = w.conn;
        // (interval 1: one frame on the screen at a time)
        while (w.interval > 0 and w.completing) {
            w.stats.complete_waits += 1;
            if (!c.pump(true)) return false;
        }
        const b = &w.bufs[w.back.?];
        // the GPU's work runs; the dma-buf's fence covers it
        w.eng.flush();
        w.serial +%= 1;
        const update = w.updateRegion(&b.img, damage);
        const seq = c.presentPixmap(w.xid, b.pixmap, w.serial, update, if (w.interval == 0) PRESENT_OPTION_ASYNC else 0) orelse return false;
        if (!c.flush()) return false;
        if (c.errorOf(seq)) |_| return false;
        w.completing = true;
        w.frames += 1;
        b.shown = w.frames;
        b.busy = true;
        w.back = null;
        return true;
    }

    /// Present's update region for a frame's damage: the window's region
    /// set to its rectangles (made at the first), or None (0: all of it)
    /// without damage, without XFIXES, or when it covers the whole image.
    fn updateRegion(w: *Window, img: *const Image, damage: []const [4]i32) u32 {
        const c = w.conn;
        if (c.xfixes == null or damage.len == 0 or damage.len > MAX_RECTS) return 0;
        var rb: [MAX_RECTS][4]u32 = undefined;
        const rects = rectsOf(img, damage, &rb);
        if (rects.len == 1 and rects[0][0] == 0 and rects[0][1] == 0 and rects[0][2] == img.width and rects[0][3] == img.height) return 0;
        if (w.region == 0) {
            const id = c.newXid() orelse return 0;
            _ = c.region(XFIXES_CREATE_REGION, id, rects) orelse return 0;
            w.region = id;
        } else {
            _ = c.region(XFIXES_SET_REGION, w.region, rects) orelse return 0;
        }
        w.stats.partial += 1;
        return w.region;
    }

    /// The damaged rectangles (top-down rows, clamped to the image) of
    /// EGL's (from the bottom left; none: everything), into `out`.
    fn rectsOf(img: *const Image, damage: []const [4]i32, out: *[MAX_RECTS][4]u32) []const [4]u32 {
        if (damage.len == 0 or damage.len > MAX_RECTS) {
            out[0] = .{ 0, 0, img.width, img.height };
            return out[0..1];
        }
        var n: usize = 0;
        for (damage) |r| {
            const x0: i64 = std.math.clamp(@as(i64, r[0]), 0, img.width);
            const x1: i64 = std.math.clamp(@as(i64, r[0]) + r[2], 0, img.width);
            const y1: i64 = std.math.clamp(@as(i64, img.height) - r[1], 0, img.height);
            const y0: i64 = std.math.clamp(@as(i64, img.height) - r[1] - r[3], 0, img.height);
            if (x1 <= x0 or y1 <= y0) continue;
            out[n] = .{ @intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0) };
            n += 1;
        }
        return out[0..n];
    }

    fn swapShm(w: *Window, damage: []const [4]i32) bool {
        const c = w.conn;
        const b = &w.bufs[w.back.?];
        const img = &b.img;
        const size = @as(usize, img.stride) * img.height;
        if (!w.segment(size)) return false;
        const mem = w.shm.?.mem;
        w.eng.flush();
        const all = w.eng.hostView(img, 0, size);
        const first = c.sent +% 1;
        var rb: [MAX_RECTS][4]u32 = undefined;
        for (rectsOf(img, damage, &rb)) |r| {
            // (the rows into the shared memory, where the image has them)
            for (0..r[3]) |j| {
                const at = (@as(usize, r[1]) + j) * img.stride + @as(usize, r[0]) * 4;
                const dst = mem[at..][0 .. @as(usize, r[2]) * 4];
                @memcpy(dst, all[at..][0..dst.len]);
                if (!w.alpha and w.depth == 32) opaqueRow(dst);
            }
            _ = c.shmPutImage(w.xid, w.gc, img.width, img.height, r[0], r[1], r[2], r[3], w.depth, w.seg, 0) orelse return false;
            w.stats.put_requests += 1;
            w.stats.put_bytes += @as(u64, r[2]) * r[3] * 4;
        }
        // (the server has read the memory before the next frame writes it;
        // its errors seen; the app paced by the server)
        if (!c.sync()) return false;
        if (c.errorIn(first, c.sent)) |e| {
            report.say(.egl_error, "X11: window 0x{x}: error {d} for its image (request {d}.{d}): it is gone", .{ w.xid, e.code, e.major, e.minor });
            return false;
        }
        w.frames += 1;
        b.shown = w.frames;
        return true;
    }

    fn swapPutImage(w: *Window, damage: []const [4]i32) bool {
        const c = w.conn;
        const b = &w.bufs[w.back.?];
        const img = &b.img;
        w.eng.flush();
        const all = w.eng.hostView(img, 0, @as(usize, img.stride) * img.height);
        const first = c.sent +% 1;
        var rb: [MAX_RECTS][4]u32 = undefined;
        for (rectsOf(img, damage, &rb)) |r| {
            if (!w.putRect(all, img.stride, r[0], r[1], r[2], r[3])) return false;
        }
        // (every strip taken, its errors seen: and the app waits for the
        // server, as a frame clock would make it)
        if (!c.sync()) return false;
        if (c.errorIn(first, c.sent)) |e| {
            report.say(.egl_error, "X11: window 0x{x}: error {d} for its image (request {d}.{d}): it is gone", .{ w.xid, e.code, e.major, e.minor });
            return false;
        }
        w.frames += 1;
        b.shown = w.frames;
        // (the image is kept: the next frame draws on it again)
        return true;
    }

    /// The rows of (x, y, rw, rh) (top-down) as PutImage strips that fit
    /// the server's longest request.
    fn putRect(w: *Window, all: []const u8, stride: u32, x: u32, y: u32, rw: u32, rh: u32) bool {
        const c = w.conn;
        const max_bytes = @min(@as(usize, c.setup.max_request_words) * 4, STAGE_BYTES);
        const row_bytes = @as(usize, rw) * 4;
        if (max_bytes < 24 + row_bytes) {
            // (a row longer than a request: column strips)
            const cols: u32 = @intCast((max_bytes - 24) / 4);
            if (cols == 0) return false;
            var cx: u32 = 0;
            while (cx < rw) : (cx += cols) {
                if (!w.putRect(all, stride, x + cx, y, @min(cols, rw - cx), rh)) return false;
            }
            return true;
        }
        const per: u32 = @intCast(@min((max_bytes - 24) / row_bytes, rh));
        var row: u32 = 0;
        while (row < rh) : (row += per) {
            const n = @min(per, rh - row);
            const out = staging[0 .. row_bytes * n];
            for (0..n) |j| {
                const src = all[(@as(usize, y + row) + j) * stride + @as(usize, x) * 4 ..][0..row_bytes];
                const dst = out[j * row_bytes ..][0..row_bytes];
                @memcpy(dst, src);
                if (!w.alpha and w.depth == 32) opaqueRow(dst);
            }
            _ = c.putImage(w.xid, w.gc, w.depth, x, y + row, rw, n, out) orelse return false;
            w.stats.put_requests += 1;
            w.stats.put_bytes += out.len;
        }
        return true;
    }

    /// No alpha: what a depth-32 window reads as alpha is opaque.
    fn opaqueRow(row: []u8) void {
        var k: usize = 3;
        while (k < row.len) : (k += 4) row[k] = 0xff;
    }

    /// A Present event of this window's.
    fn onPresent(w: *Window, evtype: u16, ev: *const [64]u8) void {
        switch (evtype) {
            PRESENT_CONFIGURE_NOTIFY => {
                const width: u32 = get16(ev[24..]);
                const height: u32 = get16(ev[26..]);
                if (width != w.width or height != w.height) w.resized.store(true, .release);
            },
            PRESENT_COMPLETE_NOTIFY => {
                if (get32(ev[20..]) == w.serial) w.completing = false;
            },
            PRESENT_IDLE_NOTIFY => {
                const pixmap = get32(ev[24..]);
                for (&w.bufs) |*b| {
                    if (b.pixmap != pixmap or !b.busy) continue;
                    b.busy = false;
                    if (b.stale) w.drop(b);
                }
            },
            else => {},
        }
    }
};

// ── Tests: the bytes ───────────────────────────────────────────────────────

const testing = std.testing;

test "x11: display names" {
    var a = parseName(":1").?;
    try testing.expectEqualStrings("/tmp/.X11-unix/X1", a.slice());
    try testing.expect(a.abstract);
    try testing.expectEqual(@as(u32, 0), a.screen);
    a = parseName("unix:12.1").?;
    try testing.expectEqualStrings("/tmp/.X11-unix/X12", a.slice());
    try testing.expectEqual(@as(u32, 1), a.screen);
    a = parseName("/run/user/1000/xsock:0.2").?;
    try testing.expectEqualStrings("/run/user/1000/xsock", a.slice());
    try testing.expect(!a.abstract);
    try testing.expectEqual(@as(u32, 2), a.screen);
    a = parseName("/tmp/.X11-unix/X3").?;
    try testing.expectEqualStrings("/tmp/.X11-unix/X3", a.slice());
    // remote ones (TCP), and nonsense: none
    for ([_][]const u8{ "localhost:0", "example.org:1.0", "", ":", ":x", ":1.y", "unix" }) |n| {
        try testing.expect(parseName(n) == null);
    }
}

/// A setup reply's body as Xwayland's reads: a vendor, formats (depths 1,
/// 24 and 32, the last two 32 bits a pixel), one or two screens, each
/// with depth 24's TrueColor visuals (one not 8-8-8) and depth 32's.
pub fn fakeSetup(buf: []u8, nscreens: u8, max_words: u16) []u8 {
    @memset(buf, 0);
    const vendor = "The X.Org Foundation";
    put32(buf[0..], 12_101_011); // release
    put32(buf[4..], 0x0020_0000); // resource id base
    put32(buf[8..], 0x001f_ffff); // mask
    put16(buf[16..], vendor.len);
    put16(buf[18..], max_words);
    buf[20] = nscreens;
    buf[21] = 3;
    buf[22] = 0; // LSBFirst images
    @memcpy(buf[32..][0..vendor.len], vendor);
    var off: usize = 32 + pad4(vendor.len);
    for ([_][2]u8{ .{ 1, 1 }, .{ 24, 32 }, .{ 32, 32 } }) |f| {
        buf[off] = f[0];
        buf[off + 1] = f[1];
        buf[off + 2] = 32;
        off += 8;
    }
    for (0..nscreens) |k| {
        const base: u32 = @intCast(k * 0x100);
        put32(buf[off..], 0x3ab + base); // root
        put16(buf[off + 20 ..], 1280);
        put16(buf[off + 22 ..], 800);
        put32(buf[off + 32 ..], 0x21 + base); // root visual
        buf[off + 38] = 24;
        buf[off + 39] = 2; // depths
        off += 40;
        // depth 24: a 5-6-5 one first, then the root's
        buf[off] = 24;
        put16(buf[off + 2 ..], 2);
        off += 8;
        put32(buf[off..], 0x20 + base);
        buf[off + 4] = TRUE_COLOR;
        put32(buf[off + 8 ..], 0xf800);
        put32(buf[off + 12 ..], 0x7e0);
        put32(buf[off + 16 ..], 0x1f);
        off += 24;
        put32(buf[off..], 0x21 + base);
        buf[off + 4] = TRUE_COLOR;
        put32(buf[off + 8 ..], 0xff0000);
        put32(buf[off + 12 ..], 0xff00);
        put32(buf[off + 16 ..], 0xff);
        off += 24;
        buf[off] = 32;
        put16(buf[off + 2 ..], 1);
        off += 8;
        put32(buf[off..], 0x41 + base);
        buf[off + 4] = TRUE_COLOR;
        put32(buf[off + 8 ..], 0xff0000);
        put32(buf[off + 12 ..], 0xff00);
        put32(buf[off + 16 ..], 0xff);
        off += 24;
    }
    return buf[0..off];
}

test "x11: the setup reply: ids, request length, formats, the screen's visuals" {
    try testing.expectEqualSlices(u8, &.{ 'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &setupRequest());
    var b: [1024]u8 = undefined;
    const body = fakeSetup(&b, 2, 0xffff);
    const s = parseSetup(body, 0).?;
    try testing.expectEqual(@as(u32, 0x0020_0000), s.xid_base);
    try testing.expectEqual(@as(u32, 0x001f_ffff), s.xid_mask);
    try testing.expectEqual(@as(u32, 0xffff), s.max_request_words);
    try testing.expect(s.lsb_images);
    try testing.expectEqual(@as(u8, 32), s.bpp24);
    try testing.expectEqual(@as(u8, 32), s.bpp32);
    try testing.expectEqual(@as(u32, 0x3ab), s.root);
    try testing.expectEqual(@as(u16, 1280), s.width);
    try testing.expectEqual(@as(u16, 800), s.height);
    try testing.expectEqual(@as(u8, 24), s.root_depth);
    // (the 5-6-5 visual is not 8 bits a channel: the root's is taken)
    try testing.expectEqual(@as(u32, 0x21), s.visual24);
    try testing.expectEqual(@as(u32, 0x41), s.visual32);
    const s1 = parseSetup(body, 1).?;
    try testing.expectEqual(@as(u32, 0x4ab), s1.root);
    try testing.expectEqual(@as(u32, 0x141), s1.visual32);
    // no third screen; cut short anywhere: none (never a read past the end)
    try testing.expect(parseSetup(body, 2) == null);
    var n: usize = 0;
    while (n < body.len) : (n += 7) try testing.expect(parseSetup(body[0..n], 1) == null);
}

/// A Conn over a byte script: what it sends is kept, what it reads is the
/// script's (one test at a time).
const Script = struct {
    var out: [8192]u8 = undefined;
    var out_len: usize = 0;
    var fds: [8]i32 = undefined;
    var n_fds: usize = 0;
    var in: [4096]u8 = undefined;
    var in_len: usize = 0;
    var in_at: usize = 0;

    fn reset() void {
        out_len = 0;
        n_fds = 0;
        in_len = 0;
        in_at = 0;
    }
    fn feed(b: []const u8) void {
        @memcpy(in[in_len..][0..b.len], b);
        in_len += b.len;
    }
    fn connect(_: ?*anyopaque, _: []const u8, _: bool) i32 {
        return 7;
    }
    fn send(_: ?*anyopaque, _: i32, b: []const u8, f: []const i32) isize {
        @memcpy(out[out_len..][0..b.len], b);
        out_len += b.len;
        for (f) |x| {
            fds[n_fds] = x;
            n_fds += 1;
        }
        return @intCast(b.len);
    }
    fn recv(_: ?*anyopaque, _: i32, b: []u8) isize {
        if (in_at == in_len) return -11; // (the script is out: no hang)
        const k = @min(b.len, in_len - in_at);
        @memcpy(b[0..k], in[in_at..][0..k]);
        in_at += k;
        return @intCast(k);
    }
    fn poll(_: ?*anyopaque, _: i32, _: i32) i32 {
        return @intFromBool(in_at < in_len);
    }
    fn close(_: ?*anyopaque, _: i32) void {}
    fn env(_: ?*anyopaque) ?[]const u8 {
        return ":1";
    }
    const wire = Wire{ .connect = connect, .send = send, .recv = recv, .poll = poll, .close = close, .display_env = env };
};

/// A reply to request `seq`: its byte 1, and bytes from 8 on.
pub fn reply(seq: u32, b1: u8, body: []const u8) [32]u8 {
    var r = [_]u8{0} ** 32;
    r[0] = 1;
    r[1] = b1;
    put16(r[2..], @truncate(seq));
    @memcpy(r[8..][0..body.len], body);
    return r;
}

/// A GetGeometry reply: depth, root, x, y, width, height.
pub fn geometryReply(seq: u32, depth: u8, w: u16, h: u16) [32]u8 {
    var body = [_]u8{0} ** 12;
    put32(body[0..], 0x3ab);
    put16(body[8..], w);
    put16(body[10..], h);
    return reply(seq, depth, &body);
}

/// A version reply (DRI3's, Present's).
pub fn versionReply(seq: u32, major: u32, minor: u32) [32]u8 {
    var body = [_]u8{0} ** 8;
    put32(body[0..], major);
    put32(body[4..], minor);
    return reply(seq, 0, &body);
}

test "x11: the connection: setup, extensions, versions; requests as bytes" {
    Script.reset();
    var sb: [1024]u8 = undefined;
    const body = fakeSetup(&sb, 1, 0xffff);
    var head = [_]u8{ 1, 0, 11, 0, 0, 0, 0, 0 };
    put16(head[6..], @intCast(body.len / 4));
    Script.feed(&head);
    Script.feed(body);
    // QueryExtension DRI3 (present, opcode 149), Present (148, first event 0)
    Script.feed(&reply(1, 0, &.{ 1, 149, 0, 0 }));
    Script.feed(&reply(2, 0, &.{ 1, 148, 0, 0 }));
    Script.feed(&versionReply(3, 1, 2)); // DRI3 1.2
    Script.feed(&versionReply(4, 1, 4)); // Present 1.4
    Script.feed(&reply(5, 0, &.{ 1, 150, 0, 0 })); // XFIXES (150)
    Script.feed(&versionReply(6, 6, 0)); // XFIXES 6.0
    var c: Conn = undefined;
    try testing.expect(c.open(&Script.wire, ":1", null));
    try testing.expectEqual(@as(u8, 149), c.dri3.?.opcode);
    try testing.expectEqual(@as(u32, 2), c.dri3_minor);
    try testing.expectEqual(@as(u8, 148), c.present.?.opcode);
    try testing.expectEqual(@as(u8, 150), c.xfixes.?.opcode);
    try testing.expectEqual(@as(u32, 6), c.sent);
    const sent = Script.out[0..Script.out_len];
    try testing.expectEqualSlices(u8, &setupRequest(), sent[0..12]);
    // QueryExtension "DRI3": opcode 98, length 3, name length 4
    try testing.expectEqualSlices(u8, &.{ 98, 0, 3, 0, 4, 0, 0, 0, 'D', 'R', 'I', '3' }, sent[12..24]);
    try testing.expectEqualSlices(u8, &.{ 98, 0, 4, 0, 7, 0, 0, 0, 'P', 'r', 'e', 's', 'e', 'n', 't', 0 }, sent[24..40]);
    // (DRI3 asked for 1.2, Present for 1.0, XFIXES for 5.0)
    try testing.expectEqualSlices(u8, &.{ 149, 0, 3, 0, 1, 0, 0, 0, 2, 0, 0, 0 }, sent[40..52]);
    try testing.expectEqualSlices(u8, &.{ 148, 0, 3, 0, 1, 0, 0, 0, 0, 0, 0, 0 }, sent[52..64]);
    try testing.expectEqualSlices(u8, &.{ 98, 0, 4, 0, 6, 0, 0, 0, 'X', 'F', 'I', 'X', 'E', 'S', 0, 0 }, sent[64..80]);
    try testing.expectEqualSlices(u8, &.{ 150, 0, 3, 0, 5, 0, 0, 0, 0, 0, 0, 0 }, sent[80..92]);

    // ids: base | n * (the mask's lowest bit)
    try testing.expectEqual(@as(u32, 0x0020_0001), c.newXid().?);
    try testing.expectEqual(@as(u32, 0x0020_0002), c.newXid().?);

    // PresentPixmap: 72 bytes, the window, pixmap, serial and options
    Script.out_len = 0;
    _ = c.presentPixmap(0x400001, 0x200002, 7, 0, PRESENT_OPTION_ASYNC).?;
    _ = c.flush();
    const pp = Script.out[0..Script.out_len];
    try testing.expectEqual(@as(usize, 72), pp.len);
    try testing.expectEqualSlices(u8, &.{ 148, 1, 18, 0 }, pp[0..4]);
    try testing.expectEqual(@as(u32, 0x400001), get32(pp[4..]));
    try testing.expectEqual(@as(u32, 0x200002), get32(pp[8..]));
    try testing.expectEqual(@as(u32, 7), get32(pp[12..]));
    try testing.expectEqual(@as(u32, 1), get32(pp[40..]));
    for (pp[16..40]) |x| try testing.expectEqual(@as(u8, 0), x);
    for (pp[44..72]) |x| try testing.expectEqual(@as(u8, 0), x);

    // DRI3 PixmapFromBuffer: 24 bytes and the fd with them
    Script.out_len = 0;
    _ = c.pixmapFromBuffer(0x200003, 0x400001, 42, 64 * 4 * 16, 64, 16, 256, 24).?;
    try testing.expectEqualSlices(u8, &.{ 149, 2, 6, 0, 0x03, 0, 0x20, 0, 0x01, 0, 0x40, 0, 0x00, 0x10, 0, 0, 64, 0, 16, 0, 0, 1, 24, 32 }, Script.out[0..Script.out_len]);
    try testing.expectEqual(@as(usize, 1), Script.n_fds);
    try testing.expectEqual(@as(i32, 42), Script.fds[0]);

    // DRI3 1.2 PixmapFromBuffers: 64 bytes, one plane, the linear modifier
    Script.out_len = 0;
    _ = c.pixmapFromBuffers(0x200003, 0x400001, 43, 64, 16, 256, 24, MOD_LINEAR).?;
    const pb = Script.out[0..Script.out_len];
    try testing.expectEqual(@as(usize, 64), pb.len);
    try testing.expectEqualSlices(u8, &.{ 149, 7, 16, 0, 0x03, 0, 0x20, 0, 0x01, 0, 0x40, 0, 1, 0, 0, 0, 64, 0, 16, 0, 0, 1, 0, 0 }, pb[0..24]);
    try testing.expectEqualSlices(u8, &.{ 24, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, pb[52..64]);
    try testing.expectEqual(@as(i32, 43), Script.fds[1]);

    // XFIXES SetRegion: the region and its rectangles (x, y, w, h)
    Script.out_len = 0;
    _ = c.region(XFIXES_SET_REGION, 0x200005, &.{ .{ 1, 2, 3, 4 }, .{ 10, 20, 30, 40 } }).?;
    _ = c.flush();
    try testing.expectEqualSlices(u8, &.{ 150, 11, 6, 0, 0x05, 0, 0x20, 0, 1, 0, 2, 0, 3, 0, 4, 0, 10, 0, 20, 0, 30, 0, 40, 0 }, Script.out[0..Script.out_len]);

    // PutImage: header and rows
    Script.out_len = 0;
    const rows = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = c.putImage(0x400001, 0x200004, 24, 3, 5, 2, 1, &rows).?;
    try testing.expectEqualSlices(u8, &.{ 72, 2, 8, 0, 0x01, 0, 0x40, 0, 0x04, 0, 0x20, 0, 2, 0, 1, 0, 3, 0, 5, 0, 0, 24, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 }, Script.out[0..Script.out_len]);

    // GetGeometry: the reply's depth and size; an error for it: none
    Script.out_len = 0;
    Script.feed(&geometryReply(c.sent + 1, 32, 300, 200));
    const geo = c.geometry(0x400001).?;
    try testing.expectEqual(@as(u8, 32), geo.depth);
    try testing.expectEqual(@as(u32, 300), geo.width);
    try testing.expectEqual(@as(u32, 200), geo.height);
    try testing.expectEqualSlices(u8, &.{ 14, 0, 2, 0, 0x01, 0, 0x40, 0 }, Script.out[0..8]);
    var e = [_]u8{0} ** 32;
    e[1] = BAD_DRAWABLE;
    put16(e[2..], @truncate(c.sent + 1));
    put32(e[4..], 0x400009);
    e[10] = OP_GET_GEOMETRY;
    Script.feed(&e);
    try testing.expect(c.geometry(0x400009) == null);
    try testing.expectEqual(@as(u8, BAD_DRAWABLE), c.errorOf(c.sent).?.code);
    try testing.expect(!c.broken);
    // the server gone: the connection is broken, every call after fails
    try testing.expect(c.geometry(0x400001) == null);
    try testing.expect(c.broken);
    try testing.expect(!c.sync());
}

test "x11: Xlib's Display read for its name" {
    var name = "unix:4.0".*;
    var xd = std.mem.zeroes(XlibDisplay);
    xd.fd = 9;
    xd.proto_major_version = 11;
    xd.display_name = @ptrCast(&name);
    xd.default_screen = 0;
    xd.nscreens = 1;
    try testing.expect(isXlibDisplay(&xd));
    try testing.expectEqualStrings("unix:4.0", xlibName(&xd).name);
    // (C's layout on LP64: the name after 26 words of fields)
    if (@sizeOf(usize) == 8) try testing.expectEqual(@as(usize, 216), @offsetOf(XlibDisplay, "display_name"));
    xd.proto_major_version = 0;
    try testing.expect(!isXlibDisplay(&xd));
}
