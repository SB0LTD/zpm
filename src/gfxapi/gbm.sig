//! @zpm/gfxapi gbm — GBM (libgbm.so.1's interface) on Galaxy's GPU, in
//! Sig: what Xwayland's glamor (xwayland-glamor-gbm.c) and other GBM
//! users ask of Mesa's libgbm, answered by the same driver as EGL and GL.
//! libgbm.sig gives it Mesa's C names; libgalaxy-gl.so is installed as
//! libgbm.so.1 too.
//!
//! - **A device** (gbm_create_device) is the render node the caller
//!   opened: its fd is kept (gbm_device_get_fd) and nothing is asked of
//!   it; the memory is this process's driver's (the engine EGL draws
//!   with, opened here as eglInitialize opens it). No GPU: no device, and
//!   the caller takes its other path (Xwayland: no glamor, wl_shm).
//!   EGL_PLATFORM_GBM_KHR takes a device as its native display.
//! - **Buffers** (gbm_bo) are linear, one plane, 32 bits a pixel:
//!   ARGB8888 and XRGB8888 (the engine's BGRA), ABGR8888 and XBGR8888
//!   (its RGBA), GBM's two old codes for the first two. Made
//!   (gbm_bo_create, _with_modifiers, _with_modifiers2: a list without
//!   DRM_FORMAT_MOD_LINEAR, nor INVALID, makes none) as engine images in
//!   GPU memory a dma-buf can export (the window buffers' kind), rows
//!   from the top; or imported (GBM_BO_IMPORT_FD and _FD_MODIFIER, a
//!   linear modifier or none), the fd duplicated and the memory imported
//!   at its first use here (gbm_bo_map, an EGLImage of the buffer).
//!   gbm_bo_get_fd and _for_plane hand out a new fd of its dma-buf each
//!   call (a made buffer's exported at the first). The modifier is LINEAR
//!   for a made buffer, what was given for an imported one (INVALID for
//!   GBM_BO_IMPORT_FD). EGL_KHR_image_pixmap's EGL_NATIVE_PIXMAP_KHR
//!   takes a buffer: its memory itself, no dma-buf between.
//! - **Surfaces** (gbm_surface) are up to MAX_SURFACE_BOS buffers an EGL
//!   window surface draws into in turn: eglSwapBuffers queues the back
//!   one, gbm_surface_lock_front_buffer takes the newest queued (the
//!   caller's until gbm_surface_release_buffer), and a buffer neither
//!   queued nor locked is drawn into again (EGL_EXT_buffer_age counts
//!   from its last swap).
//!
//! Every call holds the driver lock (egl.driverEnter), as EGL's and GL's
//! do. Allocation-free: fixed tables (MAX_*).

const std = @import("std");
const engine = @import("engine.sig");
const egl = @import("egl.sig");
const report = @import("report.sig");
const Host = @import("host.sig").Host;
const Engine = engine.Engine;
const Image = engine.Image;

pub const MAX_DEVICES = 8;
pub const MAX_BOS = 512;
pub const MAX_SURFACES = 16;
pub const MAX_SURFACE_BOS = 4;

// ── GBM's numbers (Mesa's gbm.h) ────────────────────────────────────────────

pub const BO_USE_SCANOUT: u32 = 1 << 0;
pub const BO_USE_CURSOR: u32 = 1 << 1;
pub const BO_USE_RENDERING: u32 = 1 << 2;
pub const BO_USE_WRITE: u32 = 1 << 3;
pub const BO_USE_LINEAR: u32 = 1 << 4;
pub const BO_USE_PROTECTED: u32 = 1 << 5;
pub const BO_USE_FRONT_RENDERING: u32 = 1 << 6;

pub const BO_IMPORT_WL_BUFFER: u32 = 0x5501;
pub const BO_IMPORT_EGL_IMAGE: u32 = 0x5502;
pub const BO_IMPORT_FD: u32 = 0x5503;
pub const BO_IMPORT_FD_MODIFIER: u32 = 0x5504;

pub const BO_TRANSFER_READ: u32 = 1 << 0;
pub const BO_TRANSFER_WRITE: u32 = 1 << 1;

pub const MAX_PLANES = 4;

pub const BO_FORMAT_XRGB8888: u32 = 0;
pub const BO_FORMAT_ARGB8888: u32 = 1;
pub const FORMAT_ARGB8888: u32 = 0x3432_5241; // 'AR24'
pub const FORMAT_XRGB8888: u32 = 0x3432_5258; // 'XR24'
pub const FORMAT_ABGR8888: u32 = 0x3432_4241; // 'AB24'
pub const FORMAT_XBGR8888: u32 = 0x3432_4258; // 'XB24'

pub const MOD_LINEAR: u64 = 0;
pub const MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;

/// struct gbm_import_fd_data
pub const ImportFd = extern struct {
    fd: c_int,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
};

/// struct gbm_import_fd_modifier_data
pub const ImportFdModifier = extern struct {
    width: u32,
    height: u32,
    format: u32,
    num_fds: u32,
    fds: [MAX_PLANES]c_int,
    strides: [MAX_PLANES]c_int,
    offsets: [MAX_PLANES]c_int,
    modifier: u64,
};

/// A GBM fourcc (or GBM's old code) as the engine's format: BGRA bytes
/// (DRM's ARGB8888, XRGB8888) or RGBA (ABGR8888, XBGR8888), and whether
/// the top byte is alpha. Null: not a format here.
pub fn formatOf(fourcc: u32) ?struct { code: u32, format: engine.Format, alpha: bool } {
    return switch (fourcc) {
        FORMAT_ARGB8888, BO_FORMAT_ARGB8888 => .{ .code = FORMAT_ARGB8888, .format = .bgra8, .alpha = true },
        FORMAT_XRGB8888, BO_FORMAT_XRGB8888 => .{ .code = FORMAT_XRGB8888, .format = .bgra8, .alpha = false },
        FORMAT_ABGR8888 => .{ .code = FORMAT_ABGR8888, .format = .rgba8, .alpha = true },
        FORMAT_XBGR8888 => .{ .code = FORMAT_XBGR8888, .format = .rgba8, .alpha = false },
        else => null,
    };
}

// ── Devices ────────────────────────────────────────────────────────────────

/// struct gbm_device, as far as anyone outside reads it: Mesa's first
/// word is gbm_create_device itself (how EGL's platform detection knows
/// a GBM device among native displays); the rest is ours.
pub const Device = extern struct {
    create_device: ?*const anyopaque = null,
    used: bool = false,
    fd: c_int = -1,
};

var devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES;

/// A device handle, valid (the address of one of the table's, in use).
pub fn deviceOf(handle: ?*const anyopaque) ?*Device {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&devices[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(devices)) or (p - base) % @sizeOf(Device) != 0) return null;
    const d: *Device = @ptrFromInt(p);
    return if (d.used) d else null;
}

/// gbm_create_device: a device over render node `fd` (the caller's,
/// kept), when this process can draw on the GPU; null else.
/// `create_device` is gbm_create_device's address (Mesa's first word).
pub fn createDevice(fd: c_int, create_device: ?*const anyopaque) ?*Device {
    egl.driverEnter();
    defer egl.driverLeave();
    if (fd < 0) return null;
    _ = egl.gbmEngine() orelse {
        report.say(.device, "gbm_create_device: no GPU to draw on: no GBM device", .{});
        return null;
    };
    for (&devices) |*d| {
        if (!d.used) {
            d.* = .{ .create_device = create_device, .used = true, .fd = fd };
            return d;
        }
    }
    report.say(.egl_error, "gbm_create_device: every device slot is in use", .{});
    return null;
}

/// gbm_device_destroy: the device goes (its buffers and surfaces stay
/// usable until destroyed, as Mesa's do until then).
pub fn destroyDevice(d: *Device) void {
    egl.driverEnter();
    defer egl.driverLeave();
    d.used = false;
}

/// gbm_device_is_format_supported: the formats here, for any use but
/// protected memory.
pub fn formatSupported(fourcc: u32, usage: u32) bool {
    if (usage & BO_USE_PROTECTED != 0) return false;
    return formatOf(fourcc) != null;
}

/// gbm_device_get_format_modifier_plane_count: one plane for a format
/// here, linear (or no modifier); -1 else.
pub fn modifierPlanes(fourcc: u32, modifier: u64) c_int {
    if (formatOf(fourcc) == null) return -1;
    return if (modifier == MOD_LINEAR or modifier == MOD_INVALID) 1 else -1;
}

// ── Buffers ────────────────────────────────────────────────────────────────

pub const Bo = struct {
    /// its handle valid (its memory may outlive it: EGLImages and GL's
    /// names hold it through `sh`)
    used: bool = false,
    device: ?*Device = null,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    offset: u32 = 0,
    /// its DRM fourcc (the old GBM codes made fourccs)
    format: u32 = 0,
    modifier: u64 = MOD_LINEAR,
    usage: u32 = 0,
    alpha: bool = true,
    /// its memory (an imported buffer's once imported here), held by `sh`
    img: Image = .{},
    sh: engine.Shared = .{},
    /// its dma-buf: a made buffer's once exported, an imported one's
    /// duplicate (-1: none yet)
    fd: c_int = -1,
    user_data: ?*anyopaque = null,
    destroy_user_data: ?*const fn (?*Bo, ?*anyopaque) callconv(.c) void = null,
    /// the surface it is a buffer of, if any
    surface: ?*Surface = null,
    /// gbm_bo_map's: mapped for writing (handed to the GPU at the unmap)
    mapped_write: bool = false,
    mapped: bool = false,
};

var bos: [MAX_BOS]Bo = [_]Bo{.{}} ** MAX_BOS;

/// A buffer handle, valid.
pub fn boOf(handle: ?*const anyopaque) ?*Bo {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&bos[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(bos)) or (p - base) % @sizeOf(Bo) != 0) return null;
    const b: *Bo = @ptrFromInt(p);
    return if (b.used) b else null;
}

/// A buffer's handle number (gbm_bo_get_handle): its slot, from 1.
pub fn handleOf(b: *const Bo) u64 {
    return (@intFromPtr(b) - @intFromPtr(&bos[0])) / @sizeOf(Bo) + 1;
}

/// A free buffer slot: not in use, its memory let go by every name.
fn freeBo() ?*Bo {
    for (&bos) |*b| {
        if (!b.used and b.sh.refs == 0) return b;
    }
    report.say(.egl_error, "gbm: every buffer slot is in use", .{});
    return null;
}

/// Whether a modifier list allows a linear buffer (an empty list: no).
fn linearAllowed(modifiers: []const u64) bool {
    for (modifiers) |m| {
        if (m == MOD_LINEAR or m == MOD_INVALID) return true;
    }
    return false;
}

/// gbm_bo_create, and the _with_modifiers ones (`modifiers` given): a
/// buffer of width x height in `fourcc`, in GPU memory a dma-buf exports.
pub fn createBo(d: *Device, width: u32, height: u32, fourcc: u32, usage: u32, modifiers: ?[]const u64) ?*Bo {
    egl.driverEnter();
    defer egl.driverLeave();
    if (!d.used) return null;
    return makeBo(d, width, height, fourcc, usage, modifiers);
}

fn makeBo(d: *Device, width: u32, height: u32, fourcc: u32, usage: u32, modifiers: ?[]const u64) ?*Bo {
    const f = formatOf(fourcc) orelse return null;
    if (width == 0 or height == 0 or width > egl.MAX_SIZE or height > egl.MAX_SIZE) return null;
    if (usage & BO_USE_PROTECTED != 0) return null;
    if (modifiers) |list| {
        if (!linearAllowed(list)) return null;
    }
    const eng = egl.gbmEngine() orelse return null;
    const b = freeBo() orelse return null;
    var img = eng.newWindowImage(width, height, f.format) orelse {
        report.say(.egl_error, "gbm_bo_create: no memory for a {d}x{d} buffer", .{ width, height });
        return null;
    };
    img.no_alpha = !f.alpha;
    b.* = .{ .used = true, .device = d, .width = width, .height = height, .stride = img.stride, .format = f.code, .usage = usage, .alpha = f.alpha, .modifier = MOD_LINEAR };
    share(b, img);
    return b;
}

/// The buffer's memory held by its Shared: what EGLImages alias.
fn share(b: *Bo, img: Image) void {
    b.img = img;
    b.sh = .{ .refs = 1, .buf = img.buf, .pooled = img.pooled, .track = img.track };
    b.img.share = &b.sh;
}

/// gbm_bo_import: GBM_BO_IMPORT_FD (struct gbm_import_fd_data) or
/// GBM_BO_IMPORT_FD_MODIFIER (struct gbm_import_fd_modifier_data: one
/// plane, linear or no modifier). The fd stays the caller's.
pub fn importBo(d: *Device, kind: u32, buffer: ?*const anyopaque, usage: u32) ?*Bo {
    egl.driverEnter();
    defer egl.driverLeave();
    if (!d.used) return null;
    const p = buffer orelse return null;
    var fd: c_int = -1;
    var width: u32 = 0;
    var height: u32 = 0;
    var stride: u32 = 0;
    var offset: u32 = 0;
    var fourcc: u32 = 0;
    var modifier: u64 = MOD_INVALID;
    switch (kind) {
        BO_IMPORT_FD => {
            const data: *const ImportFd = @ptrCast(@alignCast(p));
            fd = data.fd;
            width = data.width;
            height = data.height;
            stride = data.stride;
            fourcc = data.format;
        },
        BO_IMPORT_FD_MODIFIER => {
            const data: *const ImportFdModifier = @ptrCast(@alignCast(p));
            if (data.num_fds != 1) return null;
            if (data.modifier != MOD_LINEAR and data.modifier != MOD_INVALID) return null;
            if (data.strides[0] <= 0 or data.offsets[0] < 0) return null;
            fd = data.fds[0];
            width = data.width;
            height = data.height;
            stride = @intCast(data.strides[0]);
            offset = @intCast(data.offsets[0]);
            fourcc = data.format;
            modifier = data.modifier;
        },
        else => {
            report.say(.egl_error, "gbm_bo_import: import type 0x{x} is not taken (only dma-bufs)", .{kind});
            return null;
        },
    }
    const f = formatOf(fourcc) orelse return null;
    if (fd < 0 or width == 0 or height == 0 or width > egl.MAX_SIZE or height > egl.MAX_SIZE) return null;
    // (rows of whole words, at least a row's pixels: as EGL imports them)
    if (stride < width * 4 or stride % 4 != 0 or offset % 4 != 0) return null;
    const h = egl.gbmHost() orelse return null;
    const b = freeBo() orelse return null;
    const own = h.dup(h.ctx, fd);
    if (own < 0) return null;
    b.* = .{ .used = true, .device = d, .width = width, .height = height, .stride = stride, .offset = offset, .format = f.code, .modifier = modifier, .usage = usage, .alpha = f.alpha, .fd = own };
    return b;
}

/// The buffer's memory for this process: a made buffer's, or an imported
/// one's imported now (null: the dma-buf cannot be imported, or is
/// smaller than the picture).
pub fn memory(b: *Bo) ?*Image {
    if (b.img.live()) return &b.img;
    if (b.fd < 0) return null;
    const h = egl.gbmHost() orelse return null;
    const f = formatOf(b.format) orelse return null;
    const whole = h.importFd(h.ctx, b.fd) orelse return null;
    const need = @as(u64, b.offset) + @as(u64, b.stride) * (b.height - 1) + @as(u64, b.width) * 4;
    if (need > whole.bytes or need > whole.cpu.len) {
        // (the import goes again: a picture larger than its buffer)
        var img = engine.adopt(&b.sh, whole, 0, 1, 1, 4, f.format);
        if (egl.gbmEngine()) |eng| eng.freeImage(&img);
        return null;
    }
    b.img = engine.adopt(&b.sh, whole, b.offset, b.width, b.height, b.stride, f.format);
    b.img.no_alpha = !b.alpha;
    return &b.img;
}

/// gbm_bo_get_fd (and _for_plane 0): a new fd of the buffer's dma-buf
/// (the caller's), or -1.
pub fn boFd(b: *Bo) c_int {
    egl.driverEnter();
    defer egl.driverLeave();
    const h = egl.gbmHost() orelse return -1;
    if (b.fd < 0) {
        if (!b.img.live()) return -1;
        const got = h.exportFd(h.ctx, b.sh.buf);
        if (got < 0) {
            report.say(.egl_error, "gbm_bo_get_fd: the {d}x{d} buffer could not be exported (errno {d})", .{ b.width, b.height, -got });
            return -1;
        }
        b.fd = @intCast(got);
    }
    const copy = h.dup(h.ctx, b.fd);
    return if (copy < 0) -1 else copy;
}

/// gbm_bo_destroy: the user data's destructor called, the handle gone,
/// the memory let go once no EGLImage or GL name holds it.
pub fn destroyBo(b: *Bo) void {
    if (b.destroy_user_data) |cb| cb(b, b.user_data);
    egl.driverEnter();
    defer egl.driverLeave();
    dropBo(b);
}

fn dropBo(b: *Bo) void {
    if (egl.gbmHost()) |h| {
        if (b.fd >= 0) h.close(h.ctx, b.fd);
    }
    b.fd = -1;
    b.used = false;
    b.user_data = null;
    b.destroy_user_data = null;
    b.surface = null;
    if (b.img.share != null) {
        if (egl.gbmEngine()) |eng| eng.freeImage(&b.img) else b.sh.refs -= 1;
    }
    b.img = .{};
}

/// gbm_bo_map: the rectangle (x, y, w, h) for the CPU (the GPU's work on
/// it done first), its row stride; one map at a time. Null: out of the
/// buffer, or no memory for this process.
pub fn mapBo(b: *Bo, x: u32, y: u32, w: u32, h: u32, flags: u32, stride: *u32) ?[*]u8 {
    egl.driverEnter();
    defer egl.driverLeave();
    if (b.mapped or w == 0 or h == 0) return null;
    if (@as(u64, x) + w > b.width or @as(u64, y) + h > b.height) return null;
    const eng = egl.gbmEngine() orelse return null;
    const img = memory(b) orelse return null;
    const all = eng.hostView(img, 0, @as(usize, img.stride) * img.height);
    b.mapped = true;
    b.mapped_write = flags & BO_TRANSFER_WRITE != 0;
    stride.* = img.stride;
    return all.ptr + @as(usize, y) * img.stride + @as(usize, x) * 4;
}

/// gbm_bo_unmap: what the CPU wrote handed to the GPU.
pub fn unmapBo(b: *Bo) void {
    egl.driverEnter();
    defer egl.driverLeave();
    if (!b.mapped) return;
    b.mapped = false;
    if (b.mapped_write) {
        if (egl.gbmEngine()) |eng| eng.wrote(&b.img, 0, @as(usize, b.img.stride) * b.img.height);
    }
    b.mapped_write = false;
}

/// gbm_bo_write: `bytes` into the buffer from its first byte (a cursor's
/// rows); false when they do not fit or the buffer has no memory here.
pub fn writeBo(b: *Bo, bytes: []const u8) bool {
    egl.driverEnter();
    defer egl.driverLeave();
    const eng = egl.gbmEngine() orelse return false;
    const img = memory(b) orelse return false;
    if (bytes.len > @as(usize, img.stride) * img.height) return false;
    eng.writeBytes(img, 0, bytes);
    return true;
}

// ── Surfaces ───────────────────────────────────────────────────────────────

pub const Slot = struct {
    bo: ?*Bo = null,
    state: enum { free, back, queued, locked } = .free,
    /// the swap that queued it last (0: never shown)
    shown: u64 = 0,
};

pub const Surface = struct {
    used: bool = false,
    device: ?*Device = null,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    usage: u32 = 0,
    slots: [MAX_SURFACE_BOS]Slot = [_]Slot{.{}} ** MAX_SURFACE_BOS,
    swaps: u64 = 0,
    /// an EGL window surface draws into it
    egl_bound: bool = false,
    /// swapped since EGL took its back buffer: GL takes the next one at
    /// its next drawing (egl.sig's revalidate clears it)
    stale: std.atomic.Value(bool) = .init(false),
};

var surfaces: [MAX_SURFACES]Surface = [_]Surface{.{}} ** MAX_SURFACES;

pub fn surfaceOf(handle: ?*const anyopaque) ?*Surface {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&surfaces[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(surfaces)) or (p - base) % @sizeOf(Surface) != 0) return null;
    const s: *Surface = @ptrFromInt(p);
    return if (s.used) s else null;
}

/// gbm_surface_create and the _with_modifiers ones.
pub fn createSurface(d: *Device, width: u32, height: u32, fourcc: u32, usage: u32, modifiers: ?[]const u64) ?*Surface {
    egl.driverEnter();
    defer egl.driverLeave();
    if (!d.used) return null;
    const f = formatOf(fourcc) orelse return null;
    if (width == 0 or height == 0 or width > egl.MAX_SIZE or height > egl.MAX_SIZE) return null;
    if (modifiers) |list| {
        if (!linearAllowed(list)) return null;
    }
    for (&surfaces) |*s| {
        if (!s.used) {
            s.* = .{ .used = true, .device = d, .width = width, .height = height, .format = f.code, .usage = usage };
            return s;
        }
    }
    return null;
}

/// gbm_surface_destroy: its buffers go (a locked one too: Mesa's
/// destroys them all).
pub fn destroySurface(s: *Surface) void {
    egl.driverEnter();
    defer egl.driverLeave();
    for (&s.slots) |*sl| {
        if (sl.bo) |b| {
            if (b.destroy_user_data) |cb| cb(b, b.user_data);
            dropBo(b);
        }
        sl.* = .{};
    }
    s.used = false;
}

/// The back buffer EGL draws into: the one taken already, else a free
/// buffer (made if need be), the most recently shown first. Null when
/// every buffer is queued or locked (the caller released none), or there
/// is no memory. (Under the driver lock: EGL's.)
pub fn backImage(s: *Surface) ?*Image {
    for (&s.slots) |*sl| {
        if (sl.state == .back) return &sl.bo.?.img;
    }
    var pick: ?*Slot = null;
    for (&s.slots) |*sl| {
        if (sl.state != .free or sl.bo == null) continue;
        if (pick == null or sl.shown > pick.?.shown) pick = sl;
    }
    if (pick == null) {
        for (&s.slots) |*sl| {
            if (sl.bo != null) continue;
            const d = s.device orelse return null;
            const b = makeBo(d, s.width, s.height, s.format, s.usage, null) orelse return null;
            b.surface = s;
            b.img.top_down = true;
            sl.* = .{ .bo = b };
            pick = sl;
            break;
        }
    }
    const sl = pick orelse {
        report.say(.egl_error, "gbm surface: every buffer is queued or locked: release one (gbm_surface_release_buffer)", .{});
        return null;
    };
    sl.state = .back;
    return &sl.bo.?.img;
}

/// EGL_EXT_buffer_age of the back buffer (taken now if need be).
pub fn age(s: *Surface) i32 {
    _ = backImage(s) orelse return 0;
    for (&s.slots) |*sl| {
        if (sl.state != .back) continue;
        if (sl.shown == 0) return 0;
        return @intCast(@min(s.swaps - sl.shown + 1, std.math.maxInt(i32)));
    }
    return 0;
}

/// eglSwapBuffers: the back buffer queued for lock_front_buffer.
pub fn swap(s: *Surface) bool {
    for (&s.slots) |*sl| {
        if (sl.state != .back) continue;
        s.swaps += 1;
        sl.state = .queued;
        sl.shown = s.swaps;
        s.stale.store(true, .release);
        return true;
    }
    return false;
}

/// Its EGL surface gone: a back buffer not shown is free again.
pub fn unbind(s: *Surface) void {
    s.egl_bound = false;
    for (&s.slots) |*sl| {
        if (sl.state == .back) sl.state = .free;
    }
}

/// gbm_surface_lock_front_buffer: the newest queued buffer, the caller's
/// until released (older queued ones are free again: never shown).
pub fn lockFront(s: *Surface) ?*Bo {
    egl.driverEnter();
    defer egl.driverLeave();
    var newest: ?*Slot = null;
    for (&s.slots) |*sl| {
        if (sl.state == .queued and (newest == null or sl.shown > newest.?.shown)) newest = sl;
    }
    const n = newest orelse return null;
    for (&s.slots) |*sl| {
        if (sl.state == .queued and sl != n) sl.state = .free;
    }
    n.state = .locked;
    return n.bo;
}

/// gbm_surface_release_buffer: a locked buffer drawn into again.
pub fn release(s: *Surface, b: *Bo) void {
    egl.driverEnter();
    defer egl.driverLeave();
    for (&s.slots) |*sl| {
        if (sl.bo == b and sl.state == .locked) sl.state = .free;
    }
}

/// gbm_surface_has_free_buffers: a buffer is (or can be made) neither
/// queued nor locked.
pub fn hasFree(s: *Surface) bool {
    egl.driverEnter();
    defer egl.driverLeave();
    for (&s.slots) |*sl| {
        if (sl.bo == null or sl.state == .free or sl.state == .back) return true;
    }
    return false;
}

/// Every table back to empty (a test's start).
pub fn resetForTest() void {
    for (&bos) |*b| b.* = .{};
    for (&devices) |*d| d.* = .{};
    for (&surfaces) |*s| s.* = .{};
}
