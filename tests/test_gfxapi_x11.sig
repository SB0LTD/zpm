//! gfxapi's EGL on X11, through a fake X server behind the `Wire` EGL
//! speaks over: the server parses EGL's requests as Xwayland would read
//! them (setup, QueryExtension, GetGeometry, CreateGC, PutImage, DRI3's
//! QueryVersion and PixmapFromBuffer with its fd, Present's QueryVersion,
//! SelectInput and PresentPixmap, FreePixmap, FreeGC, GetInputFocus),
//! keeps its windows' pixels, and answers with replies, errors and
//! Present's events (CompleteNotify for each frame, IdleNotify for the
//! one before, ConfigureNotify when a window is resized). The engine runs
//! on EmuDevice.
//!
//! Checked:
//! - Firefox's start on X11 as gfx/gl does it: EGL_DEFAULT_DISPLAY, the
//!   configs' native visuals (the server's TrueColor visuals of depth 24
//!   and 32), a window surface of an X window's id, a context, a
//!   fallback pbuffer, and its GPU process's offscreen work (a context
//!   with no config and no surface, a pbuffer) on the same display;
//! - Galaxy's Xwayland as it runs (-glamor off: Present, no DRI3): frames
//!   sent as PutImage strips no longer than the server's longest
//!   request, only the damaged rows; buffer age 1; a resize; the window
//!   gone (EGL_BAD_NATIVE_WINDOW); everything given back;
//! - a server with DRI3 and Present (an Xlib Display, eglGetPlatformDisplay
//!   and eglCreatePlatformWindowSurface's Window*): each buffer a pixmap
//!   from its dma-buf, presented; interval 1 waits for CompleteNotify,
//!   idle buffers reused (age 2), interval 0 presents Async; a resize
//!   (ConfigureNotify) gives new pixmaps, the old freed once idle;
//! - Xwayland with glamor (DRI3 1.2, Present, XFIXES): pixmaps from
//!   PixmapFromBuffers with the linear modifier (Xwayland's GBM imports
//!   them and may hand them to its compositor), a swap's damage as
//!   Present's update region (top-down, the region made once and set
//!   after), none for the whole window; DRI3 1.0 servers: PixmapFromBuffer;
//! - a server that refuses our dma-buf: the window turns to PutImage;
//! - errors: no server, a window that is not the server's, one of depth
//!   16, a second surface for a window.

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const egl = gfxapi.egl;
const x11 = gfxapi.x11;
const wl = gfxapi.wayland;
const gl = gfxapi.glenum;
const thread = gfxapi.thread;

const testing = std.testing;
const put16 = x11.put16;
const put32 = x11.put32;
const get16 = x11.get16;
const get32 = x11.get32;

// ── The fake X server ──────────────────────────────────────────────────────

const DRI3_OP = 149;
const PRESENT_OP = 148;
const SHM_OP = 130;
const XFIXES_OP = 151;

const Win = struct {
    xid: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    depth: u8 = 24,
    fb: [64 * 64]u32 = undefined,
};

const Seg = struct { seg: u32 = 0, fd: i32 = -1 };

const Region = struct { id: u32 = 0, n: usize = 0, rects: [8][4]u16 = undefined };

const Pix = struct { xid: u32 = 0, fd: i32 = -1, w: u32 = 0, h: u32 = 0, stride: u32 = 0, depth: u8 = 0, size: u32 = 0 };

const Fake = struct {
    // what the server offers
    var dri3 = false;
    /// DRI3's minor version the server answers (2: PixmapFromBuffers)
    var dri3_minor: u32 = 2;
    var xfixes = false;
    /// XFIXES regions: id, rectangles
    var regions: [4]Region = undefined;
    var last_update: u32 = 0;
    var last_modifier: u64 = 0xff;
    var from_buffer: u32 = 0;
    var from_buffers: u32 = 0;
    var present = true;
    var refuse_dri3 = false;
    var refuse_connect = false;
    var shm = false;
    var refuse_shm = false;
    /// MIT-SHM's memory, as the Wire makes it (fd 70 + n), and the
    /// segments the server attached
    var shm_mem: [2][64 * 64 * 4]u8 = undefined;
    var shm_used = [2]bool{ false, false };
    var shm_creates: u32 = 0;
    var shm_destroys: u32 = 0;
    var segs: [4]Seg = undefined;
    var shm_puts: u32 = 0;
    var detaches: u32 = 0;
    /// CompleteNotify held back until EGL waits for it (the next vblank)
    var hold_complete = false;
    var held: [256]u8 = undefined;
    var held_len: usize = 0;
    var max_words: u16 = 0xffff;
    // the streams
    var in: [1 << 20]u8 = undefined;
    var in_len: usize = 0;
    var in_at: usize = 0;
    var out: [1 << 16]u8 = undefined;
    var out_len: usize = 0;
    var out_at: usize = 0;
    var fds: [16]i32 = undefined;
    var n_fds: usize = 0;
    var fds_used: usize = 0;
    var set_up = false;
    var seq: u32 = 0;
    var connected_path: [128]u8 = undefined;
    var connected_len: usize = 0;
    var closed = false;
    // the server's objects
    var wins: [4]Win = undefined;
    var pixmaps: [16]Pix = undefined;
    var gcs: [4]u32 = undefined;
    var eid: u32 = 0;
    var eid_window: u32 = 0;
    var eid_mask: u32 = 0;
    var last_presented: u32 = 0;
    var last_serial: u32 = 0;
    // counts
    var put_images: u32 = 0;
    var longest_request: usize = 0;
    var put_rows: u32 = 0;
    var presents: u32 = 0;
    var last_options: u32 = 0;
    var made_pixmaps: u32 = 0;
    var freed_pixmaps: u32 = 0;
    var freed_gcs: u32 = 0;
    var geometries: u32 = 0;
    var errors_sent: u32 = 0;
    var bad_requests: u32 = 0;

    fn reset() void {
        dri3 = false;
        dri3_minor = 2;
        xfixes = false;
        for (&regions) |*g| g.* = .{};
        last_update = 0;
        last_modifier = 0xff;
        from_buffer = 0;
        from_buffers = 0;
        present = true;
        refuse_dri3 = false;
        refuse_connect = false;
        shm = false;
        refuse_shm = false;
        shm_used = .{ false, false };
        shm_creates = 0;
        shm_destroys = 0;
        for (&segs) |*g| g.* = .{};
        shm_puts = 0;
        detaches = 0;
        hold_complete = false;
        held_len = 0;
        max_words = 0xffff;
        in_len = 0;
        in_at = 0;
        out_len = 0;
        out_at = 0;
        n_fds = 0;
        fds_used = 0;
        set_up = false;
        seq = 0;
        connected_len = 0;
        closed = false;
        for (&wins) |*w| w.* = .{};
        for (&pixmaps) |*p| p.* = .{};
        gcs = [_]u32{0} ** 4;
        eid = 0;
        eid_window = 0;
        eid_mask = 0;
        last_presented = 0;
        last_serial = 0;
        put_images = 0;
        longest_request = 0;
        put_rows = 0;
        presents = 0;
        last_options = 0;
        made_pixmaps = 0;
        freed_pixmaps = 0;
        freed_gcs = 0;
        geometries = 0;
        errors_sent = 0;
        bad_requests = 0;
    }

    fn addWindow(xid: u32, w: u32, h: u32, depth: u8) *Win {
        for (&wins) |*x| {
            if (x.xid == 0) {
                x.* = .{ .xid = xid, .w = w, .h = h, .depth = depth };
                @memset(&x.fb, 0);
                return x;
            }
        }
        unreachable;
    }

    fn win(xid: u32) ?*Win {
        for (&wins) |*x| {
            if (x.xid != 0 and x.xid == xid) return x;
        }
        return null;
    }

    fn region(id: u32) ?*Region {
        for (&regions) |*g| {
            if (g.id == id and id != 0) return g;
        }
        return null;
    }

    fn pixmap(xid: u32) ?*Pix {
        for (&pixmaps) |*p| {
            if (p.xid != 0 and p.xid == xid) return p;
        }
        return null;
    }

    fn livePixmaps() u32 {
        var n: u32 = 0;
        for (pixmaps) |p| n += @intFromBool(p.xid != 0);
        return n;
    }

    /// A window resized, as a window manager would: Present's
    /// ConfigureNotify for whoever selected it.
    fn resize(xid: u32, w: u32, h: u32) void {
        const x = win(xid).?;
        x.w = w;
        x.h = h;
        @memset(&x.fb, 0);
        if (eid != 0 and eid_window == xid and eid_mask & x11.PRESENT_MASK_CONFIGURE != 0) {
            var ev = presentEvent(x11.PRESENT_CONFIGURE_NOTIFY, 2);
            put32(ev[16..], xid);
            put16(ev[24..], @intCast(w));
            put16(ev[26..], @intCast(h));
            queue(ev[0..40]);
        }
    }

    fn pixel(xid: u32, x: u32, y: u32) u32 {
        const w = win(xid).?;
        return w.fb[y * w.w + x] & 0xffffff;
    }

    fn queue(b: []const u8) void {
        @memcpy(out[out_len..][0..b.len], b);
        out_len += b.len;
    }

    fn reply(b1: u8, body: []const u8) void {
        queue(&x11.reply(seq, b1, body));
    }

    fn sendError(code: u8, value: u32, major: u8, minor: u16) void {
        var e = [_]u8{0} ** 32;
        e[1] = code;
        put16(e[2..], @truncate(seq));
        put32(e[4..], value);
        put16(e[8..], minor);
        e[10] = major;
        queue(&e);
        errors_sent += 1;
    }

    fn presentEvent(evtype: u16, extra_words: u32) [64]u8 {
        var ev = [_]u8{0} ** 64;
        ev[0] = x11.GENERIC_EVENT;
        ev[1] = PRESENT_OP;
        put16(ev[2..], @truncate(seq));
        put32(ev[4..], extra_words);
        put16(ev[8..], evtype);
        put32(ev[12..], eid);
        return ev;
    }

    /// Everything EGL has sent, read as the server reads it.
    fn serve() void {
        while (true) {
            const avail = in[in_at..in_len];
            if (!set_up) {
                if (avail.len < 12) return;
                const n = 12 + pad4(get16(avail[6..])) + pad4(get16(avail[8..]));
                if (avail.len < n) return;
                std.debug.assert(avail[0] == 'l' and get16(avail[2..]) == 11);
                in_at += n;
                set_up = true;
                var sb: [1024]u8 = undefined;
                const body = x11.fakeSetup(&sb, 1, max_words);
                var head = [_]u8{ 1, 0, 11, 0, 0, 0, 0, 0 };
                put16(head[6..], @intCast(body.len / 4));
                queue(&head);
                queue(body);
                continue;
            }
            if (avail.len < 4) return;
            const n = @as(usize, get16(avail[2..])) * 4;
            std.debug.assert(n >= 4);
            if (avail.len < n) return;
            in_at += n;
            seq += 1;
            longest_request = @max(longest_request, n);
            request(avail[0..n]);
        }
    }

    fn request(r: []const u8) void {
        switch (r[0]) {
            x11.OP_QUERY_EXTENSION => {
                const name = r[8..][0..get16(r[4..])];
                if (std.mem.eql(u8, name, "DRI3") and dri3) {
                    reply(0, &.{ 1, DRI3_OP, 0, 0 });
                } else if (std.mem.eql(u8, name, "Present") and present) {
                    reply(0, &.{ 1, PRESENT_OP, 0, 0 });
                } else if (std.mem.eql(u8, name, "MIT-SHM") and shm) {
                    reply(0, &.{ 1, SHM_OP, 0, 0 });
                } else if (std.mem.eql(u8, name, "XFIXES") and xfixes) {
                    reply(0, &.{ 1, XFIXES_OP, 0, 0 });
                } else reply(0, &.{ 0, 0, 0, 0 });
            },
            x11.OP_GET_GEOMETRY => {
                geometries += 1;
                const w = win(get32(r[4..])) orelse return sendError(x11.BAD_DRAWABLE, get32(r[4..]), r[0], 0);
                queue(&x11.geometryReply(seq, w.depth, @intCast(w.w), @intCast(w.h)));
            },
            x11.OP_GET_INPUT_FOCUS => reply(1, &.{}),
            x11.OP_CREATE_GC => {
                for (&gcs) |*g| {
                    if (g.* == 0) {
                        g.* = get32(r[4..]);
                        return;
                    }
                }
            },
            x11.OP_FREE_GC => {
                for (&gcs) |*g| {
                    if (g.* == get32(r[4..])) g.* = 0;
                }
                freed_gcs += 1;
            },
            x11.OP_FREE_PIXMAP => {
                const p = pixmap(get32(r[4..])) orelse return sendError(x11.BAD_PIXMAP, get32(r[4..]), r[0], 0);
                p.* = .{};
                freed_pixmaps += 1;
            },
            x11.OP_PUT_IMAGE => {
                put_images += 1;
                const w = win(get32(r[4..])) orelse return sendError(x11.BAD_DRAWABLE, get32(r[4..]), r[0], 0);
                const iw: u32 = get16(r[12..]);
                const ih: u32 = get16(r[14..]);
                const x0: u32 = get16(r[16..]);
                const y0: u32 = get16(r[18..]);
                if (r[1] != x11.Z_PIXMAP or r[21] != w.depth or r.len != 24 + iw * ih * 4) return sendError(x11.BAD_MATCH, 0, r[0], 0);
                for (0..ih) |j| {
                    for (0..iw) |i| {
                        const x = x0 + i;
                        const y = y0 + j;
                        if (x >= w.w or y >= w.h) continue;
                        w.fb[y * w.w + x] = get32(r[24 + (j * iw + i) * 4 ..]);
                    }
                }
                put_rows += ih;
            },
            DRI3_OP => switch (r[1]) {
                x11.DRI3_QUERY_VERSION => queue(&x11.versionReply(seq, 1, dri3_minor)),
                x11.DRI3_PIXMAP_FROM_BUFFERS => {
                    std.debug.assert(dri3_minor >= 2);
                    std.debug.assert(fds_used < n_fds);
                    const fd = fds[fds_used];
                    fds_used += 1;
                    from_buffers += 1;
                    if (refuse_dri3) return sendError(x11.BAD_ALLOC, 0, DRI3_OP, x11.DRI3_PIXMAP_FROM_BUFFERS);
                    std.debug.assert(r.len == 64 and r[12] == 1 and r[53] == 32);
                    last_modifier = x11.get64(r[56..]);
                    for (&pixmaps) |*p| {
                        if (p.xid == 0) {
                            const stride = get32(r[20..]);
                            const h: u32 = get16(r[18..]);
                            p.* = .{ .xid = get32(r[4..]), .fd = fd, .size = stride * h, .w = get16(r[16..]), .h = h, .stride = stride, .depth = r[52] };
                            made_pixmaps += 1;
                            return;
                        }
                    }
                    unreachable;
                },
                x11.DRI3_PIXMAP_FROM_BUFFER => {
                    from_buffer += 1;
                    std.debug.assert(fds_used < n_fds);
                    const fd = fds[fds_used];
                    fds_used += 1;
                    if (refuse_dri3) return sendError(x11.BAD_ALLOC, 0, DRI3_OP, x11.DRI3_PIXMAP_FROM_BUFFER);
                    std.debug.assert(r[23] == 32);
                    for (&pixmaps) |*p| {
                        if (p.xid == 0) {
                            p.* = .{ .xid = get32(r[4..]), .fd = fd, .size = get32(r[12..]), .w = get16(r[16..]), .h = get16(r[18..]), .stride = get16(r[20..]), .depth = r[22] };
                            made_pixmaps += 1;
                            return;
                        }
                    }
                    unreachable;
                },
                else => {
                    bad_requests += 1;
                    sendError(1, 0, r[0], r[1]);
                },
            },
            SHM_OP => switch (r[1]) {
                // 1.2, shared pixmaps, ZPixmap
                x11.SHM_QUERY_VERSION => reply(1, &.{ 1, 0, 2, 0, 0, 0, 0, 0, 2, 0, 0, 0 }),
                x11.SHM_ATTACH_FD => {
                    std.debug.assert(fds_used < n_fds);
                    const fd = fds[fds_used];
                    fds_used += 1;
                    if (refuse_shm) return sendError(10, 0, SHM_OP, x11.SHM_ATTACH_FD); // BadAccess
                    std.debug.assert(r[8] == 1); // (read only)
                    for (&segs) |*g| {
                        if (g.seg == 0) {
                            g.* = .{ .seg = get32(r[4..]), .fd = fd };
                            return;
                        }
                    }
                    unreachable;
                },
                x11.SHM_DETACH => {
                    for (&segs) |*g| {
                        if (g.seg == get32(r[4..])) g.* = .{};
                    }
                    detaches += 1;
                },
                x11.SHM_PUT_IMAGE => {
                    shm_puts += 1;
                    const w = win(get32(r[4..])) orelse return sendError(x11.BAD_DRAWABLE, get32(r[4..]), r[0], r[1]);
                    const tw: u32 = get16(r[12..]);
                    const sx: u32 = get16(r[16..]);
                    const sy: u32 = get16(r[18..]);
                    const sw: u32 = get16(r[20..]);
                    const sh: u32 = get16(r[22..]);
                    const dx: u32 = get16(r[24..]);
                    const dy: u32 = get16(r[26..]);
                    if (r[28] != w.depth or r[29] != x11.Z_PIXMAP) return sendError(x11.BAD_MATCH, 0, r[0], r[1]);
                    const seg = get32(r[32..]);
                    const fd = for (segs) |g| {
                        if (g.seg == seg and seg != 0) break g.fd;
                    } else return sendError(128, seg, r[0], r[1]); // (BadShmSeg)
                    const mem = &shm_mem[@intCast(fd - 70)];
                    const off = get32(r[36..]);
                    for (0..sh) |j| {
                        for (0..sw) |i| {
                            const x = dx + i;
                            const y = dy + j;
                            if (x >= w.w or y >= w.h) continue;
                            w.fb[y * w.w + x] = get32(mem[off + ((sy + j) * tw + sx + i) * 4 ..]);
                        }
                    }
                    put_rows += sh;
                },
                else => {
                    bad_requests += 1;
                    sendError(1, 0, r[0], r[1]);
                },
            },
            XFIXES_OP => switch (r[1]) {
                x11.XFIXES_QUERY_VERSION => queue(&x11.versionReply(seq, 5, 0)),
                x11.XFIXES_CREATE_REGION, x11.XFIXES_SET_REGION => {
                    const id = get32(r[4..]);
                    const g = for (&regions) |*g| {
                        if (g.id == id) break g;
                    } else for (&regions) |*g| {
                        if (g.id == 0) break g;
                    } else unreachable;
                    if ((r[1] == x11.XFIXES_CREATE_REGION) != (g.id == 0)) return sendError(x11.BAD_MATCH, id, r[0], r[1]);
                    g.id = id;
                    g.n = (r.len - 8) / 8;
                    for (0..g.n) |i| {
                        const at = r[8 + 8 * i ..];
                        g.rects[i] = .{ get16(at[0..]), get16(at[2..]), get16(at[4..]), get16(at[6..]) };
                    }
                },
                x11.XFIXES_DESTROY_REGION => {
                    for (&regions) |*g| {
                        if (g.id == get32(r[4..])) g.* = .{};
                    }
                },
                else => {
                    bad_requests += 1;
                    sendError(1, 0, r[0], r[1]);
                },
            },
            PRESENT_OP => switch (r[1]) {
                x11.PRESENT_QUERY_VERSION => queue(&x11.versionReply(seq, 1, 2)),
                x11.PRESENT_SELECT_INPUT => {
                    eid = get32(r[4..]);
                    eid_window = get32(r[8..]);
                    eid_mask = get32(r[12..]);
                },
                x11.PRESENT_PIXMAP => {
                    const window = get32(r[4..]);
                    const pm = get32(r[8..]);
                    const serial = get32(r[12..]);
                    _ = win(window) orelse return sendError(x11.BAD_WINDOW, window, r[0], r[1]);
                    _ = pixmap(pm) orelse return sendError(x11.BAD_PIXMAP, pm, r[0], r[1]);
                    presents += 1;
                    last_options = get32(r[40..]);
                    last_update = get32(r[20..]);
                    if (last_update != 0 and region(last_update) == null) return sendError(140, last_update, r[0], r[1]); // (BadRegion)
                    // shown: this frame complete, the one before idle
                    var c = presentEvent(x11.PRESENT_COMPLETE_NOTIFY, 2);
                    put32(c[16..], window);
                    put32(c[20..], serial);
                    if (hold_complete) {
                        @memcpy(held[held_len..][0..40], c[0..40]);
                        held_len += 40;
                    } else queue(c[0..40]);
                    if (last_presented != 0 and last_presented != pm) {
                        var i = presentEvent(x11.PRESENT_IDLE_NOTIFY, 0);
                        put32(i[16..], window);
                        put32(i[20..], last_serial);
                        put32(i[24..], last_presented);
                        queue(i[0..32]);
                    }
                    last_presented = pm;
                    last_serial = serial;
                },
                else => {
                    bad_requests += 1;
                    sendError(1, 0, r[0], r[1]);
                },
            },
            else => {
                bad_requests += 1;
                sendError(1, 0, r[0], 0);
            },
        }
    }

    // ── the Wire ──

    fn connect(_: ?*anyopaque, path: []const u8, abstract: bool) i32 {
        if (refuse_connect) return -111; // ECONNREFUSED
        if (abstract) return -111;
        @memcpy(connected_path[0..path.len], path);
        connected_len = path.len;
        return 9;
    }
    fn send(_: ?*anyopaque, fd: i32, b: []const u8, f: []const i32) isize {
        std.debug.assert(fd == 9);
        // (short writes, as a socket may make them: EGL sends the rest)
        const k = @min(b.len, 4096);
        @memcpy(in[in_len..][0..k], b[0..k]);
        in_len += k;
        for (f) |x| {
            fds[n_fds] = x;
            n_fds += 1;
        }
        serve();
        return @intCast(k);
    }
    fn recv(_: ?*anyopaque, _: i32, b: []u8) isize {
        // (EGL waits: the vblank comes, with what was held for it)
        if (out_at == out_len and held_len > 0) {
            queue(held[0..held_len]);
            held_len = 0;
        }
        if (out_at == out_len) return -11; // (nothing to read: a test's bug, never a hang)
        const k = @min(b.len, out_len - out_at);
        @memcpy(b[0..k], out[out_at..][0..k]);
        out_at += k;
        if (out_at == out_len) {
            out_at = 0;
            out_len = 0;
        }
        return @intCast(k);
    }
    fn poll(_: ?*anyopaque, _: i32, _: i32) i32 {
        return @intFromBool(out_at < out_len);
    }
    fn close(_: ?*anyopaque, _: i32) void {
        closed = true;
    }
    var display_env: ?[]const u8 = ":7";
    fn env(_: ?*anyopaque) ?[]const u8 {
        return display_env;
    }
    fn shmCreate(_: ?*anyopaque, size: usize) ?x11.Shm {
        if (size > shm_mem[0].len) return null;
        for (&shm_used, 0..) |*u, i| {
            if (u.*) continue;
            u.* = true;
            shm_creates += 1;
            @memset(&shm_mem[i], 0xee);
            return .{ .fd = 70 + @as(i32, @intCast(i)), .mem = shm_mem[i][0..size] };
        }
        return null;
    }
    fn shmDestroy(_: ?*anyopaque, m: x11.Shm) void {
        shm_used[@intCast(m.fd - 70)] = false;
        shm_destroys += 1;
    }
    const wire = x11.Wire{ .connect = connect, .send = send, .recv = recv, .poll = poll, .close = close, .display_env = env, .shm_create = shmCreate, .shm_destroy = shmDestroy };
};

fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

// ── The driver: EmuDevice, fds that are its buffers' handles ──────────────

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng: engine.Engine = undefined;
var opened = false;
var exports: u32 = 0;
var closes: u32 = 0;

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
fn exportFd(_: ?*anyopaque, b: gpu.Buffer) i64 {
    exports += 1;
    return 200 + @as(i64, b.handle);
}
fn importFd(_: ?*anyopaque, _: i32) ?gpu.Buffer {
    return null;
}
fn fenceFd(_: ?*anyopaque) i64 {
    return -19;
}
fn closeFd(_: ?*anyopaque, _: i32) void {
    closes += 1;
}
fn dupFd(_: ?*anyopaque, fd: i32) i32 {
    return fd + 1000;
}
fn pollFd(_: ?*anyopaque, _: i32, _: i32) i32 {
    return 1;
}
fn mapFd(_: ?*anyopaque, _: i32, _: usize) ?[]const u8 {
    return null;
}
fn unmapFd(_: ?*anyopaque, _: []const u8) void {}
const host = gfxapi.host.Host{ .exportFd = exportFd, .importFd = importFd, .fenceFd = fenceFd, .close = closeFd, .dup = dupFd, .poll = pollFd, .map = mapFd, .unmap = unmapFd };
fn noWayland() ?*const wl.Client {
    return null;
}
fn wire() ?*const x11.Wire {
    return &Fake.wire;
}

fn useDriver() void {
    egl.setDriver(.{ .open = open, .host = host, .wayland = noWayland, .x11 = wire });
    exports = 0;
    closes = 0;
}

fn bgra(img: *engine.Image, x: u32, row: u32) u32 {
    const v = eng.hostView(img, @as(usize, row) * img.stride + @as(usize, x) * 4, 4);
    return std.mem.readInt(u32, v[0..4], .little) & 0xffffff;
}

const RED: u32 = 0xff0000;
const GREEN: u32 = 0x00ff00;
const BLUE: u32 = 0x0000ff;

/// Firefox's CreateConfig on X11: the attributes for a depth, the configs
/// whose channels fit, and among them the first whose native visual is of
/// that depth (XGetVisualInfo on the server's visuals: 0x21 is depth 24's,
/// 0x41 depth 32's).
fn firefoxConfig(d: *egl.Display, depth: i32) ?*const anyopaque {
    const rgb24 = [_]i32{ egl.SURFACE_TYPE, egl.WINDOW_BIT, egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 0, egl.RENDERABLE_TYPE, egl.OPENGL_ES2_BIT, egl.NONE, 0, 0, 0 };
    const rgba32 = [_]i32{ egl.SURFACE_TYPE, egl.WINDOW_BIT, egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 8, egl.RENDERABLE_TYPE, egl.OPENGL_ES2_BIT, egl.NONE, 0, 0, 0 };
    var cfgs: [64]?*const anyopaque = undefined;
    var n: i32 = 0;
    if (!egl.chooseConfig(d, if (depth == 24) &rgb24 else &rgba32, &cfgs, 64, &n) or n < 1) return null;
    for (cfgs[0..@intCast(n)]) |cf| {
        var a: i32 = 0;
        var vid: i32 = 0;
        if (!egl.getConfigAttrib(d, cf, egl.ALPHA_SIZE, &a)) continue;
        if ((depth == 24) != (a == 0)) continue;
        if (!egl.getConfigAttrib(d, cf, egl.NATIVE_VISUAL_ID, &vid)) continue;
        const visual_depth: i32 = switch (vid) {
            0x21 => 24,
            0x41 => 32,
            else => 0,
        };
        if (visual_depth == depth) return cf;
    }
    return null;
}

test "x11: Firefox's start through EGL_DEFAULT_DISPLAY on Galaxy's Xwayland (no DRI3): PutImage strips, damage, resize, the window gone" {
    useDriver();
    Fake.reset();
    // (a short longest request: every frame in several strips)
    Fake.max_words = 64;
    _ = Fake.addWindow(0x600001, 32, 16, 24);
    const d = egl.getDisplay(null).?;
    try testing.expect(egl.initialize(d, null, null));
    // (the default display connects to $DISPLAY at its first X need)
    try testing.expectEqual(@as(usize, 0), Fake.connected_len);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(egl.queryString(null, egl.EXTENSIONS).?), "EGL_KHR_platform_x11") != null);
    try testing.expect(egl.bindApi(egl.OPENGL_ES_API));
    const cfg = firefoxConfig(d, 24) orelse return error.NoConfig;
    try testing.expectEqualStrings("/tmp/.X11-unix/X7", Fake.connected_path[0..Fake.connected_len]);
    var vt: i32 = 0;
    try testing.expect(egl.getConfigAttrib(d, cfg, egl.NATIVE_VISUAL_TYPE, &vt));
    try testing.expectEqual(@as(i32, x11.TRUE_COLOR), vt);
    // (FindVisual: an ARGB config of depth 32's visual)
    try testing.expect(firefoxConfig(d, 32) != null);
    // CreateSurfaceFromNativeWindow: the X window's id as the pointer
    const s = egl.createWindowSurface(i32, d, cfg, @ptrFromInt(0x600001), null) orelse return error.WindowSurface;
    try testing.expectEqual(x11.Mode.put_image, s.xwin.mode);
    try testing.expect(Fake.gcs[0] != 0);
    // a second surface for the same window: refused
    try testing.expect(egl.createWindowSurface(i32, d, cfg, @ptrFromInt(0x600001), null) == null);
    try testing.expectEqual(egl.BAD_ALLOC, egl.getError());
    // GLContextEGL's fallback surface: a pbuffer of the window's config
    const fallback = egl.createPbufferSurface(d, cfg, &[_]i32{ egl.WIDTH, 16, egl.HEIGHT, 16, egl.NONE }) orelse return error.Pbuffer;
    const rbab = [_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY, egl.LOSE_CONTEXT_ON_RESET, egl.CONTEXT_FLAGS_KHR, 4, egl.NONE };
    const ctx = egl.createContext(d, cfg, null, &rbab) orelse return error.Context;
    try testing.expect(egl.makeCurrent(d, s, s, ctx));
    const c = thread.gl().?;
    var age: i32 = -1;
    try testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try testing.expectEqual(@as(i32, 0), age);

    // frame 1: red, all of it
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(RED, Fake.pixel(0x600001, 0, 0));
    try testing.expectEqual(RED, Fake.pixel(0x600001, 31, 15));
    // (64 words: 232 bytes of rows a request, one row of 128: 16 requests)
    try testing.expectEqual(@as(u32, 16), Fake.put_images);
    try testing.expectEqual(@as(u32, 16), Fake.put_rows);
    try testing.expect(Fake.longest_request <= 64 * 4);
    try testing.expectEqual(@as(u32, 0), Fake.errors_sent);
    try testing.expectEqual(@as(u32, 0), Fake.bad_requests);

    // frame 2: green in GL's bottom left 4 x 2 (the window's last rows),
    // only those sent; the image kept (age 1)
    try testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try testing.expectEqual(@as(i32, 1), age);
    c.enable(gl.SCISSOR_TEST, true);
    c.scissorSet(0, 0, 4, 2);
    c.clearColor(0, 1, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    c.enable(gl.SCISSOR_TEST, false);
    const rows = Fake.put_rows;
    try testing.expect(egl.swapBuffers(d, s, &.{.{ 0, 0, 4, 2 }}));
    try testing.expectEqual(rows + 2, Fake.put_rows);
    try testing.expectEqual(GREEN, Fake.pixel(0x600001, 0, 15));
    try testing.expectEqual(GREEN, Fake.pixel(0x600001, 3, 14));
    try testing.expectEqual(RED, Fake.pixel(0x600001, 4, 15));
    try testing.expectEqual(RED, Fake.pixel(0x600001, 0, 13));
    try testing.expectEqual(RED, Fake.pixel(0x600001, 31, 0));

    // the window resized: the next frame is drawn at its new size
    Fake.resize(0x600001, 48, 24);
    c.clearColor(0, 0, 1, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    var wq: i32 = 0;
    try testing.expect(egl.querySurface(d, s, egl.WIDTH, &wq));
    try testing.expectEqual(@as(i32, 48), wq);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(BLUE, Fake.pixel(0x600001, 47, 23));
    try testing.expectEqual(BLUE, Fake.pixel(0x600001, 0, 0));
    try testing.expectEqual(@as(u32, 0), Fake.errors_sent);

    // the GPU process's offscreen work on the same display: a context with
    // no config and no surface, and a pbuffer read back
    const off = egl.createContext(d, null, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }) orelse return error.OffscreenContext;
    try testing.expect(egl.makeCurrent(d, null, null, off));
    try testing.expect(egl.makeCurrent(d, fallback, fallback, ctx));
    const pc = thread.gl().?;
    pc.clearColor(0, 1, 0, 1);
    pc.clear(gl.COLOR_BUFFER_BIT);
    var px: [4]u8 = undefined;
    pc.readPixels(3, 3, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &px);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px);

    // the window gone: the swap fails (EGL_BAD_NATIVE_WINDOW)
    try testing.expect(egl.makeCurrent(d, s, s, ctx));
    Fake.win(0x600001).?.xid = 0;
    thread.gl().?.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(!egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(egl.BAD_NATIVE_WINDOW, egl.getError());

    // everything given back: the GC freed, the connection closed
    try testing.expect(egl.makeCurrent(d, null, null, null));
    try testing.expect(egl.destroySurface(d, s));
    try testing.expect(egl.destroySurface(d, fallback));
    try testing.expect(egl.destroyContext(d, ctx));
    try testing.expect(egl.destroyContext(d, off));
    try testing.expectEqual(@as(u32, 1), Fake.freed_gcs);
    try testing.expect(egl.terminate(d));
    try testing.expect(Fake.closed);
    try testing.expectEqual(@as(u32, 0), Fake.bad_requests);
    try testing.expectEqual(@as(u32, 0), exports);
}

test "x11: DRI3 and Present: dma-buf pixmaps presented, interval 1 waits for completion, idle buffers reused, a resize" {
    useDriver();
    Fake.reset();
    Fake.dri3 = true;
    Fake.hold_complete = true;
    _ = Fake.addWindow(0x600002, 32, 16, 24);
    // an Xlib Display (its name read, nothing else), by EGL_PLATFORM_X11_KHR
    var name = ":5".*;
    var xd = std.mem.zeroes(x11.XlibDisplay);
    xd.fd = 3;
    xd.proto_major_version = 11;
    xd.display_name = @ptrCast(&name);
    xd.nscreens = 1;
    const d = egl.getPlatformDisplay(egl.PLATFORM_X11_KHR, &xd).?;
    // (eglGetDisplay of the same Display: the same display)
    try testing.expectEqual(d, egl.getDisplay(&xd).?);
    try testing.expect(egl.initialize(d, null, null));
    try testing.expectEqualStrings("/tmp/.X11-unix/X5", Fake.connected_path[0..Fake.connected_len]);
    const cfg = firefoxConfig(d, 24) orelse return error.NoConfig;
    // eglCreatePlatformWindowSurface: a pointer to the Window
    var xid: c_ulong = 0x600002;
    const s = egl.createPlatformWindowSurface(isize, d, cfg, &xid, null) orelse return error.WindowSurface;
    try testing.expectEqual(x11.Mode.present, s.xwin.mode);
    try testing.expectEqual(@as(u32, 0x600002), Fake.eid_window);
    try testing.expectEqual(x11.PRESENT_MASK_CONFIGURE | x11.PRESENT_MASK_COMPLETE | x11.PRESENT_MASK_IDLE, Fake.eid_mask);
    const ctx = egl.createContext(d, cfg, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try testing.expect(egl.makeCurrent(d, s, s, ctx));
    const c = thread.gl().?;

    // frame 1: red; its buffer a pixmap from the dma-buf (the fd sent with
    // the request, EGL's own closed after)
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(@as(u32, 1), Fake.presents);
    try testing.expectEqual(@as(u32, 0), Fake.last_options);
    const p0 = Fake.pixmap(Fake.last_presented).?;
    try testing.expect(p0.fd >= 200);
    try testing.expectEqual(@as(u32, 32), p0.w);
    try testing.expectEqual(@as(u32, 16), p0.h);
    try testing.expectEqual(@as(u32, 128), p0.stride);
    try testing.expectEqual(@as(u32, 128 * 16), p0.size);
    try testing.expectEqual(@as(u8, 24), p0.depth);
    try testing.expectEqual(exports, closes);
    const b0 = &s.xwin.bufs[0];
    try testing.expectEqual(p0.xid, b0.pixmap);
    try testing.expectEqual(RED, bgra(&b0.img, 0, 0));
    try testing.expectEqual(RED, bgra(&b0.img, 31, 15));
    try testing.expect(s.xwin.completing);

    // frame 2: a second buffer (the first is the server's); interval 1
    // waited for frame 1's CompleteNotify
    c.clearColor(0, 1, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(@as(u32, 2), Fake.made_pixmaps);
    try testing.expectEqual(@as(u64, 1), s.xwin.stats.complete_waits);
    try testing.expect(Fake.last_presented != p0.xid);

    // frame 3: buffer 0 idle again (the server said so when frame 2 was
    // shown), reused: age 2, no new pixmap
    var age: i32 = 0;
    try testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try testing.expectEqual(@as(i32, 2), age);
    try testing.expectEqual(RED, bgra(&b0.img, 5, 5)); // (frame 1's, kept)
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(@as(u32, 2), Fake.made_pixmaps);
    try testing.expectEqual(p0.xid, Fake.last_presented);

    // interval 0: presented Async
    try testing.expect(egl.swapInterval(d, 0));
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(x11.PRESENT_OPTION_ASYNC, Fake.last_options);

    // a resize (ConfigureNotify): new pixmaps of the new size, the old
    // freed (once idle)
    Fake.resize(0x600002, 40, 20);
    c.clearColor(0, 0, 1, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    const p2 = Fake.pixmap(Fake.last_presented).?;
    try testing.expectEqual(@as(u32, 40), p2.w);
    try testing.expectEqual(@as(u32, 20), p2.h);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expect(Fake.freed_pixmaps >= 1);
    try testing.expectEqual(@as(u32, 0), Fake.errors_sent);
    try testing.expectEqual(@as(u32, 0), Fake.bad_requests);

    // everything given back: every pixmap freed, Present's events unselected
    try testing.expect(egl.makeCurrent(d, null, null, null));
    try testing.expect(egl.destroySurface(d, s));
    try testing.expectEqual(@as(u32, 0), Fake.livePixmaps());
    try testing.expectEqual(@as(u32, 0), Fake.eid_mask);
    try testing.expect(egl.destroyContext(d, ctx));
    try testing.expect(egl.terminate(d));
    try testing.expect(Fake.closed);
}

test "x11: Xwayland with glamor: PixmapFromBuffers (linear), damage as Present's update region" {
    useDriver();
    Fake.reset();
    Fake.dri3 = true;
    Fake.xfixes = true;
    _ = Fake.addWindow(0x600004, 32, 16, 24);
    const d = egl.getDisplay(null).?;
    try testing.expect(egl.initialize(d, null, null));
    const cfg = firefoxConfig(d, 24) orelse return error.NoConfig;
    const s = egl.createWindowSurface(i32, d, cfg, @ptrFromInt(0x600004), null) orelse return error.WindowSurface;
    try testing.expectEqual(x11.Mode.present, s.xwin.mode);
    try testing.expect(s.xwin.conn.xfixes != null);
    const ctx = egl.createContext(d, cfg, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try testing.expect(egl.makeCurrent(d, s, s, ctx));
    const c = thread.gl().?;
    // frame 1: everything (no damage): no update region; the pixmap from
    // PixmapFromBuffers, linear
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(@as(u32, 1), Fake.from_buffers);
    try testing.expectEqual(@as(u32, 0), Fake.from_buffer);
    try testing.expectEqual(@as(u64, 0), Fake.last_modifier);
    try testing.expectEqual(@as(u32, 128), Fake.pixmap(Fake.last_presented).?.stride);
    try testing.expectEqual(@as(u32, 0), Fake.last_update);
    // frame 2: two damaged rectangles (EGL's, from the bottom left): the
    // update region made with them, top-down
    var age: i32 = 0;
    try testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{ .{ 2, 0, 4, 3 }, .{ 0, 10, 32, 6 } }));
    const id = Fake.last_update;
    try testing.expect(id != 0);
    const g = Fake.region(id).?;
    try testing.expectEqual(@as(usize, 2), g.n);
    try testing.expectEqual([4]u16{ 2, 13, 4, 3 }, g.rects[0]);
    try testing.expectEqual([4]u16{ 0, 0, 32, 6 }, g.rects[1]);
    // frame 3: other damage: the same region, set
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{.{ 31, 15, 1, 1 }}));
    try testing.expectEqual(id, Fake.last_update);
    try testing.expectEqual(@as(usize, 1), g.n);
    try testing.expectEqual([4]u16{ 31, 0, 1, 1 }, g.rects[0]);
    try testing.expectEqual(@as(u64, 2), s.xwin.stats.partial);
    // frame 4: damage covering the whole window: no region
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{.{ 0, 0, 32, 16 }}));
    try testing.expectEqual(@as(u32, 0), Fake.last_update);
    try testing.expectEqual(@as(u32, 0), Fake.errors_sent);
    try testing.expectEqual(@as(u32, 0), Fake.bad_requests);
    // the region goes with the surface
    try testing.expect(egl.makeCurrent(d, null, null, null));
    try testing.expect(egl.destroySurface(d, s));
    try testing.expect(Fake.region(id) == null);
    try testing.expect(egl.destroyContext(d, ctx));
    try testing.expect(egl.terminate(d));

    // a DRI3 1.0 server: PixmapFromBuffer, as before
    useDriver();
    Fake.reset();
    Fake.dri3 = true;
    Fake.dri3_minor = 0;
    _ = Fake.addWindow(0x600006, 16, 16, 24);
    const d2 = egl.getDisplay(null).?;
    try testing.expect(egl.initialize(d2, null, null));
    const cfg2 = firefoxConfig(d2, 24) orelse return error.NoConfig;
    const s2 = egl.createWindowSurface(i32, d2, cfg2, @ptrFromInt(0x600006), null) orelse return error.WindowSurface;
    const ctx2 = egl.createContext(d2, cfg2, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try testing.expect(egl.makeCurrent(d2, s2, s2, ctx2));
    thread.gl().?.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d2, s2, &.{.{ 0, 0, 4, 4 }}));
    try testing.expectEqual(@as(u32, 1), Fake.from_buffer);
    try testing.expectEqual(@as(u32, 0), Fake.from_buffers);
    // (no XFIXES on this server: the whole window)
    try testing.expectEqual(@as(u32, 0), Fake.last_update);
    try testing.expect(egl.makeCurrent(d2, null, null, null));
    try testing.expect(egl.destroySurface(d2, s2));
    try testing.expect(egl.destroyContext(d2, ctx2));
    try testing.expect(egl.terminate(d2));
}

test "x11: MIT-SHM (Galaxy's Xwayland: Present and MIT-SHM, no DRI3): frames through shared memory, damage, resize, a refusal" {
    useDriver();
    Fake.reset();
    Fake.shm = true;
    _ = Fake.addWindow(0x600006, 24, 12, 24);
    const d = egl.getDisplay(null).?;
    try testing.expect(egl.initialize(d, null, null));
    const cfg = firefoxConfig(d, 24).?;
    const s = egl.createWindowSurface(i32, d, cfg, @ptrFromInt(0x600006), null).?;
    try testing.expectEqual(x11.Mode.shm, s.xwin.mode);
    const ctx = egl.createContext(d, cfg, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try testing.expect(egl.makeCurrent(d, s, s, ctx));
    const c = thread.gl().?;
    // frame 1: red; the memory made and attached (its fd sent), one ShmPutImage
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(@as(u32, 1), Fake.shm_creates);
    try testing.expectEqual(@as(i32, 70), Fake.segs[0].fd);
    try testing.expectEqual(@as(u32, 1), Fake.shm_puts);
    try testing.expectEqual(@as(u32, 0), Fake.put_images);
    try testing.expectEqual(RED, Fake.pixel(0x600006, 0, 0));
    try testing.expectEqual(RED, Fake.pixel(0x600006, 23, 11));
    // frame 2: green in GL's bottom left 4 x 2, only that rectangle sent
    var age: i32 = 0;
    try testing.expect(egl.querySurface(d, s, egl.BUFFER_AGE_EXT, &age));
    try testing.expectEqual(@as(i32, 1), age);
    c.enable(gl.SCISSOR_TEST, true);
    c.scissorSet(0, 0, 4, 2);
    c.clearColor(0, 1, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    c.enable(gl.SCISSOR_TEST, false);
    const rows = Fake.put_rows;
    try testing.expect(egl.swapBuffers(d, s, &.{.{ 0, 0, 4, 2 }}));
    try testing.expectEqual(rows + 2, Fake.put_rows);
    try testing.expectEqual(GREEN, Fake.pixel(0x600006, 3, 11));
    try testing.expectEqual(RED, Fake.pixel(0x600006, 4, 11));
    try testing.expectEqual(RED, Fake.pixel(0x600006, 0, 9));
    try testing.expectEqual(@as(u32, 1), Fake.shm_creates);
    // a bigger window: new memory, the old detached and let go
    Fake.resize(0x600006, 40, 20);
    c.clearColor(0, 0, 1, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(BLUE, Fake.pixel(0x600006, 39, 19));
    try testing.expectEqual(@as(u32, 2), Fake.shm_creates);
    try testing.expectEqual(@as(u32, 1), Fake.shm_destroys);
    try testing.expectEqual(@as(u32, 1), Fake.detaches);
    try testing.expectEqual(@as(u32, 0), Fake.errors_sent);
    try testing.expectEqual(@as(u32, 0), Fake.bad_requests);
    // given back: detached, let go, the GC freed
    try testing.expect(egl.makeCurrent(d, null, null, null));
    try testing.expect(egl.destroySurface(d, s));
    try testing.expectEqual(@as(u32, 2), Fake.detaches);
    try testing.expectEqual(Fake.shm_creates, Fake.shm_destroys);
    try testing.expectEqual(@as(u32, 1), Fake.freed_gcs);

    // a server that refuses the memory: PutImage, the same frame shown
    Fake.refuse_shm = true;
    _ = Fake.addWindow(0x600007, 16, 8, 24);
    const s2 = egl.createWindowSurface(i32, d, cfg, @ptrFromInt(0x600007), null).?;
    try testing.expect(egl.makeCurrent(d, s2, s2, ctx));
    thread.gl().?.clearColor(1, 0, 0, 1);
    thread.gl().?.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s2, &.{}));
    try testing.expectEqual(x11.Mode.put_image, s2.xwin.mode);
    try testing.expectEqual(RED, Fake.pixel(0x600007, 15, 7));
    try testing.expect(Fake.put_images >= 1);
    try testing.expectEqual(Fake.shm_creates, Fake.shm_destroys);
    try testing.expect(egl.makeCurrent(d, null, null, null));
    try testing.expect(egl.destroySurface(d, s2));
    try testing.expect(egl.destroyContext(d, ctx));
    try testing.expect(egl.terminate(d));
}

test "x11: a server that refuses our dma-buf: the window turns to PutImage" {
    useDriver();
    Fake.reset();
    Fake.dri3 = true;
    Fake.refuse_dri3 = true;
    _ = Fake.addWindow(0x600003, 16, 8, 24);
    const d = egl.getPlatformDisplay(egl.PLATFORM_X11_KHR, null).?;
    try testing.expect(egl.initialize(d, null, null));
    const cfg = firefoxConfig(d, 24).?;
    const s = egl.createWindowSurface(i32, d, cfg, @ptrFromInt(0x600003), null).?;
    const ctx = egl.createContext(d, cfg, null, &[_]i32{ egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE }).?;
    try testing.expect(egl.makeCurrent(d, s, s, ctx));
    try testing.expectEqual(x11.Mode.put_image, s.xwin.mode);
    const c = thread.gl().?;
    c.clearColor(1, 0, 0, 1);
    c.clear(gl.COLOR_BUFFER_BIT);
    try testing.expect(egl.swapBuffers(d, s, &.{}));
    try testing.expectEqual(RED, Fake.pixel(0x600003, 15, 7));
    try testing.expectEqual(@as(u32, 0), Fake.presents);
    try testing.expectEqual(@as(u32, 1), Fake.errors_sent); // (the refusal)
    try testing.expect(egl.makeCurrent(d, null, null, null));
    try testing.expect(egl.destroySurface(d, s));
    try testing.expect(egl.destroyContext(d, ctx));
    try testing.expect(egl.terminate(d));
}

test "x11: errors: no server, no DISPLAY, a window not the server's, depth 16, not a Display" {
    useDriver();
    Fake.reset();
    _ = Fake.addWindow(0x600004, 16, 8, 16);
    // no server: the X11 display does not initialize
    Fake.refuse_connect = true;
    const d = egl.getPlatformDisplay(egl.PLATFORM_X11_KHR, null).?;
    try testing.expect(!egl.initialize(d, null, null));
    try testing.expectEqual(egl.NOT_INITIALIZED, egl.getError());
    Fake.refuse_connect = false;
    // no DISPLAY: none either
    Fake.display_env = null;
    try testing.expect(!egl.initialize(d, null, null));
    Fake.display_env = ":7";
    // the default display without a server: pbuffers, no windows
    Fake.refuse_connect = true;
    const dd = egl.getDisplay(null).?;
    try testing.expect(egl.initialize(dd, null, null));
    try testing.expect(egl.createWindowSurface(i32, dd, &egl.configs[3], @ptrFromInt(0x600004), null) == null);
    try testing.expectEqual(egl.BAD_NATIVE_WINDOW, egl.getError());
    try testing.expect(egl.terminate(dd));
    Fake.refuse_connect = false;
    try testing.expect(egl.initialize(d, null, null));
    // a window the server does not have, and one of depth 16
    try testing.expect(egl.createWindowSurface(i32, d, &egl.configs[3], @ptrFromInt(0x6000ff), null) == null);
    try testing.expectEqual(egl.BAD_NATIVE_WINDOW, egl.getError());
    try testing.expect(egl.createWindowSurface(i32, d, &egl.configs[3], @ptrFromInt(0x600004), null) == null);
    try testing.expectEqual(egl.BAD_NATIVE_WINDOW, egl.getError());
    try testing.expect(egl.createWindowSurface(i32, d, &egl.configs[3], null, null) == null);
    try testing.expectEqual(egl.BAD_NATIVE_WINDOW, egl.getError());
    try testing.expect(egl.terminate(d));
    // a pointer that is no Xlib Display (nor a wl_display)
    var junk = [_]u64{0} ** 64;
    try testing.expect(egl.getDisplay(&junk) == null);
}
