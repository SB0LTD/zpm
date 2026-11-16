//! @zpm/gfxapi libgbm — the C ABI of GBM: libgbm.so.1's functions under
//! Mesa 25's names and signatures (gbm.h), over gbm.sig. Part of
//! libgalaxy-gl.so (libgalaxy_gl.sig imports it), which Galaxy installs as
//! libgbm.so.1 too: what Xwayland's glamor links against finds the
//! driver its EGL is.
//!
//! The opaque handles are gbm.sig's tables' entries: struct gbm_device's
//! first word is gbm_create_device's address, as Mesa's (EGL's platform
//! detection reads it); nothing else of a handle is the caller's to read.

const std = @import("std");
const gfxapi = @import("gfxapi");
const gbm = gfxapi.gbm;
const abi = @import("abi.sig");

/// union gbm_bo_handle (returned by value: a register's worth).
pub const Handle = extern union {
    ptr: ?*anyopaque,
    s32: i32,
    u32: u32,
    s64: i64,
    u64: u64,
};

const DestroyUserData = ?*const fn (?*gbm.Bo, ?*anyopaque) callconv(.c) void;

fn dev(p: ?*anyopaque) ?*gbm.Device {
    return gbm.deviceOf(p);
}
fn bo(p: ?*anyopaque) ?*gbm.Bo {
    return gbm.boOf(p);
}
fn surf(p: ?*anyopaque) ?*gbm.Surface {
    return gbm.surfaceOf(p);
}
fn list(modifiers: ?[*]const u64, count: c_uint) ?[]const u64 {
    const m = modifiers orelse return if (count == 0) &.{} else null;
    return m[0..count];
}

// ── Devices ────────────────────────────────────────────────────────────────

pub export fn gbm_create_device(fd: c_int) callconv(.c) ?*gbm.Device {
    return gbm.createDevice(fd, @ptrCast(&gbm_create_device));
}

pub export fn gbm_device_destroy(d: ?*anyopaque) callconv(.c) void {
    if (dev(d)) |x| gbm.destroyDevice(x);
}

pub export fn gbm_device_get_fd(d: ?*anyopaque) callconv(.c) c_int {
    const x = dev(d) orelse return -1;
    return x.fd;
}

/// "drm", as Mesa's own backend is named (Xwayland then names no GLX
/// vendor of its own).
pub export fn gbm_device_get_backend_name(d: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    _ = dev(d) orelse return null;
    return "drm";
}

pub export fn gbm_device_is_format_supported(d: ?*anyopaque, format: u32, usage: u32) callconv(.c) c_int {
    _ = dev(d) orelse return 0;
    return @intFromBool(gbm.formatSupported(format, usage));
}

pub export fn gbm_device_get_format_modifier_plane_count(d: ?*anyopaque, format: u32, modifier: u64) callconv(.c) c_int {
    _ = dev(d) orelse return -1;
    return gbm.modifierPlanes(format, modifier);
}

// ── Buffers ────────────────────────────────────────────────────────────────

pub export fn gbm_bo_create(d: ?*anyopaque, width: u32, height: u32, format: u32, flags: u32) callconv(.c) ?*gbm.Bo {
    const x = dev(d) orelse return null;
    return gbm.createBo(x, width, height, format, flags, null);
}

pub export fn gbm_bo_create_with_modifiers(d: ?*anyopaque, width: u32, height: u32, format: u32, modifiers: ?[*]const u64, count: c_uint) callconv(.c) ?*gbm.Bo {
    const x = dev(d) orelse return null;
    // (Mesa's: rendering is the use with modifiers)
    return gbm.createBo(x, width, height, format, gbm.BO_USE_RENDERING | gbm.BO_USE_SCANOUT, list(modifiers, count) orelse return null);
}

pub export fn gbm_bo_create_with_modifiers2(d: ?*anyopaque, width: u32, height: u32, format: u32, modifiers: ?[*]const u64, count: c_uint, flags: u32) callconv(.c) ?*gbm.Bo {
    const x = dev(d) orelse return null;
    return gbm.createBo(x, width, height, format, flags, list(modifiers, count) orelse return null);
}

pub export fn gbm_bo_import(d: ?*anyopaque, kind: u32, buffer: ?*anyopaque, flags: u32) callconv(.c) ?*gbm.Bo {
    const x = dev(d) orelse return null;
    return gbm.importBo(x, kind, buffer, flags);
}

pub export fn gbm_bo_destroy(b: ?*anyopaque) callconv(.c) void {
    if (bo(b)) |x| gbm.destroyBo(x);
}

pub export fn gbm_bo_get_width(b: ?*anyopaque) callconv(.c) u32 {
    return if (bo(b)) |x| x.width else 0;
}
pub export fn gbm_bo_get_height(b: ?*anyopaque) callconv(.c) u32 {
    return if (bo(b)) |x| x.height else 0;
}
pub export fn gbm_bo_get_stride(b: ?*anyopaque) callconv(.c) u32 {
    return if (bo(b)) |x| x.stride else 0;
}
pub export fn gbm_bo_get_stride_for_plane(b: ?*anyopaque, plane: c_int) callconv(.c) u32 {
    const x = bo(b) orelse return 0;
    return if (plane == 0) x.stride else 0;
}
pub export fn gbm_bo_get_format(b: ?*anyopaque) callconv(.c) u32 {
    return if (bo(b)) |x| x.format else 0;
}
pub export fn gbm_bo_get_bpp(b: ?*anyopaque) callconv(.c) u32 {
    return if (bo(b) != null) 32 else 0;
}
pub export fn gbm_bo_get_offset(b: ?*anyopaque, plane: c_int) callconv(.c) u32 {
    const x = bo(b) orelse return 0;
    return if (plane == 0) x.offset else 0;
}
pub export fn gbm_bo_get_device(b: ?*anyopaque) callconv(.c) ?*gbm.Device {
    const x = bo(b) orelse return null;
    return x.device;
}
pub export fn gbm_bo_get_modifier(b: ?*anyopaque) callconv(.c) u64 {
    return if (bo(b)) |x| x.modifier else gbm.MOD_INVALID;
}
pub export fn gbm_bo_get_plane_count(b: ?*anyopaque) callconv(.c) c_int {
    return if (bo(b) != null) 1 else 0;
}

/// The buffer's handle: not a GEM handle of the caller's fd (the memory
/// is this driver's), but one per buffer, as callers compare them (the
/// planes of one buffer: the same).
pub export fn gbm_bo_get_handle(b: ?*anyopaque) callconv(.c) Handle {
    return gbm_bo_get_handle_for_plane(b, 0);
}
pub export fn gbm_bo_get_handle_for_plane(b: ?*anyopaque, plane: c_int) callconv(.c) Handle {
    const x = bo(b) orelse return .{ .s64 = -1 };
    if (plane != 0) return .{ .s64 = -1 };
    return .{ .u64 = gbm.handleOf(x) };
}

pub export fn gbm_bo_get_fd(b: ?*anyopaque) callconv(.c) c_int {
    const x = bo(b) orelse return -1;
    return gbm.boFd(x);
}
pub export fn gbm_bo_get_fd_for_plane(b: ?*anyopaque, plane: c_int) callconv(.c) c_int {
    const x = bo(b) orelse return -1;
    if (plane != 0) return -1;
    return gbm.boFd(x);
}

pub export fn gbm_bo_map(b: ?*anyopaque, x: u32, y: u32, width: u32, height: u32, flags: u32, stride: ?*u32, map_data: ?*?*anyopaque) callconv(.c) ?*anyopaque {
    const o = bo(b) orelse return null;
    const s = stride orelse return null;
    const md = map_data orelse return null;
    const p = gbm.mapBo(o, x, y, width, height, flags, s) orelse return null;
    md.* = @ptrCast(o);
    return @ptrCast(p);
}

pub export fn gbm_bo_unmap(b: ?*anyopaque, map_data: ?*anyopaque) callconv(.c) void {
    _ = map_data;
    if (bo(b)) |x| gbm.unmapBo(x);
}

pub export fn gbm_bo_write(b: ?*anyopaque, buf: ?[*]const u8, count: usize) callconv(.c) c_int {
    const x = bo(b) orelse return -1;
    const p = buf orelse return -1;
    return if (gbm.writeBo(x, p[0..count])) 0 else -1;
}

pub export fn gbm_bo_set_user_data(b: ?*anyopaque, data: ?*anyopaque, destroy: DestroyUserData) callconv(.c) void {
    const x = bo(b) orelse return;
    x.user_data = data;
    x.destroy_user_data = destroy;
}

pub export fn gbm_bo_get_user_data(b: ?*anyopaque) callconv(.c) ?*anyopaque {
    const x = bo(b) orelse return null;
    return x.user_data;
}

// ── Surfaces ───────────────────────────────────────────────────────────────

pub export fn gbm_surface_create(d: ?*anyopaque, width: u32, height: u32, format: u32, flags: u32) callconv(.c) ?*gbm.Surface {
    const x = dev(d) orelse return null;
    return gbm.createSurface(x, width, height, format, flags, null);
}

pub export fn gbm_surface_create_with_modifiers(d: ?*anyopaque, width: u32, height: u32, format: u32, modifiers: ?[*]const u64, count: c_uint) callconv(.c) ?*gbm.Surface {
    const x = dev(d) orelse return null;
    return gbm.createSurface(x, width, height, format, gbm.BO_USE_RENDERING | gbm.BO_USE_SCANOUT, list(modifiers, count) orelse return null);
}

pub export fn gbm_surface_create_with_modifiers2(d: ?*anyopaque, width: u32, height: u32, format: u32, modifiers: ?[*]const u64, count: c_uint, flags: u32) callconv(.c) ?*gbm.Surface {
    const x = dev(d) orelse return null;
    return gbm.createSurface(x, width, height, format, flags, list(modifiers, count) orelse return null);
}

pub export fn gbm_surface_destroy(s: ?*anyopaque) callconv(.c) void {
    if (surf(s)) |x| gbm.destroySurface(x);
}

pub export fn gbm_surface_lock_front_buffer(s: ?*anyopaque) callconv(.c) ?*gbm.Bo {
    const x = surf(s) orelse return null;
    return gbm.lockFront(x);
}

pub export fn gbm_surface_release_buffer(s: ?*anyopaque, b: ?*anyopaque) callconv(.c) void {
    const x = surf(s) orelse return;
    const o = gbm.boOf(b) orelse return;
    gbm.release(x, o);
}

pub export fn gbm_surface_has_free_buffers(s: ?*anyopaque) callconv(.c) c_int {
    const x = surf(s) orelse return 0;
    return @intFromBool(gbm.hasFree(x));
}

comptime {
    // (gbm_format_get_name is abi.sig's)
    _ = abi;
}
