// screencap Linux backend — Xlib capture + XTest synthetic click.
// Selected at comptime by screencap.sig on Linux targets.
//
// libX11 and libXtst are loaded at RUNTIME via std.DynLib (dlopen), not linked
// at build time. This is deliberate: it lets the whole suite cross-compile to
// Linux from any host without the X11 development libraries present, and it
// degrades gracefully (enumerate -> 0, capture -> fail) on a headless box where
// the libraries or an X display are unavailable.

const std = @import("std");
const api = @import("../screencap.sig");

const WindowInfo = api.WindowInfo;
const Capture = api.Capture;
const EnumOptions = api.EnumOptions;
const MAX_TITLE = api.MAX_TITLE;

// ── Xlib types (opaque where we don't need the layout) ──
const Display = anyopaque;
const Window = c_ulong;
const Bool = c_int;
const Status = c_int;

const XWindowAttributes = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
    border_width: c_int = 0,
    depth: c_int = 0,
    visual: ?*anyopaque = null,
    root: Window = 0,
    class: c_int = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: Bool = 0,
    colormap: c_ulong = 0,
    map_installed: Bool = 0,
    map_state: c_int = 0,
    all_event_masks: c_long = 0,
    your_event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: Bool = 0,
    screen: ?*anyopaque = null,
};

const XImage = extern struct {
    width: c_int = 0,
    height: c_int = 0,
    xoffset: c_int = 0,
    format: c_int = 0,
    data: ?[*]u8 = null,
    byte_order: c_int = 0,
    bitmap_unit: c_int = 0,
    bitmap_bit_order: c_int = 0,
    bitmap_pad: c_int = 0,
    depth: c_int = 0,
    bytes_per_line: c_int = 0,
    bits_per_pixel: c_int = 0,
    red_mask: c_ulong = 0,
    green_mask: c_ulong = 0,
    blue_mask: c_ulong = 0,
};

const IsViewable: c_int = 2; // map_state
const ZPixmap: c_int = 2;
const AllPlanes: c_ulong = ~@as(c_ulong, 0);

// ── Function-pointer signatures (resolved at runtime via dlsym) ──
const FnOpenDisplay = *const fn (?[*:0]const u8) callconv(.c) ?*Display;
const FnCloseDisplay = *const fn (*Display) callconv(.c) c_int;
const FnDefaultRootWindow = *const fn (*Display) callconv(.c) Window;
const FnQueryTree = *const fn (*Display, Window, *Window, *Window, *[*]Window, *c_uint) callconv(.c) Status;
const FnGetWindowAttributes = *const fn (*Display, Window, *XWindowAttributes) callconv(.c) Status;
const FnFetchName = *const fn (*Display, Window, *?[*:0]u8) callconv(.c) Status;
const FnGetImage = *const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_ulong, c_int) callconv(.c) ?*XImage;
const FnDestroyImage = *const fn (*XImage) callconv(.c) c_int;
const FnFree = *const fn (?*anyopaque) callconv(.c) c_int;
const FnTranslateCoordinates = *const fn (*Display, Window, Window, c_int, c_int, *c_int, *c_int, *Window) callconv(.c) Bool;
const FnSync = *const fn (*Display, Bool) callconv(.c) c_int;
const FnWarpPointer = *const fn (*Display, Window, Window, c_int, c_int, c_uint, c_uint, c_int, c_int) callconv(.c) c_int;
const FnTestFakeButtonEvent = *const fn (*Display, c_uint, Bool, c_ulong) callconv(.c) c_int;

const Xlib = struct {
    openDisplay: FnOpenDisplay,
    closeDisplay: FnCloseDisplay,
    defaultRootWindow: FnDefaultRootWindow,
    queryTree: FnQueryTree,
    getWindowAttributes: FnGetWindowAttributes,
    fetchName: FnFetchName,
    getImage: FnGetImage,
    destroyImage: FnDestroyImage,
    free: FnFree,
    translateCoordinates: FnTranslateCoordinates,
    sync: FnSync,
    warpPointer: FnWarpPointer,
    testFakeButtonEvent: FnTestFakeButtonEvent,
};

// Lazily-loaded singleton. `loaded` is tri-state: unattempted -> attempt once.
var g_xlib: ?Xlib = null;
var g_attempted: bool = false;

fn xlib() ?*const Xlib {
    if (g_attempted) return if (g_xlib) |*x| x else null;
    g_attempted = true;

    var x11 = std.DynLib.open("libX11.so.6") catch
        std.DynLib.open("libX11.so") catch return null;
    var xtst = std.DynLib.open("libXtst.so.6") catch
        std.DynLib.open("libXtst.so") catch {
        x11.close();
        return null;
    };

    g_xlib = .{
        .openDisplay = x11.lookup(FnOpenDisplay, "XOpenDisplay") orelse return null,
        .closeDisplay = x11.lookup(FnCloseDisplay, "XCloseDisplay") orelse return null,
        .defaultRootWindow = x11.lookup(FnDefaultRootWindow, "XDefaultRootWindow") orelse return null,
        .queryTree = x11.lookup(FnQueryTree, "XQueryTree") orelse return null,
        .getWindowAttributes = x11.lookup(FnGetWindowAttributes, "XGetWindowAttributes") orelse return null,
        .fetchName = x11.lookup(FnFetchName, "XFetchName") orelse return null,
        .getImage = x11.lookup(FnGetImage, "XGetImage") orelse return null,
        .destroyImage = x11.lookup(FnDestroyImage, "XDestroyImage") orelse return null,
        .free = x11.lookup(FnFree, "XFree") orelse return null,
        .translateCoordinates = x11.lookup(FnTranslateCoordinates, "XTranslateCoordinates") orelse return null,
        .sync = x11.lookup(FnSync, "XSync") orelse return null,
        .warpPointer = x11.lookup(FnWarpPointer, "XWarpPointer") orelse return null,
        .testFakeButtonEvent = xtst.lookup(FnTestFakeButtonEvent, "XTestFakeButtonEvent") orelse return null,
    };
    return if (g_xlib) |*x| x else null;
}

fn cstrLen(p: [*:0]const u8) usize {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return n;
}

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
    list.len = 0;
    const x = xlib() orelse return 0;
    const dpy = x.openDisplay(null) orelse return 0;
    defer _ = x.closeDisplay(dpy);

    const root = x.defaultRootWindow(dpy);
    var root_ret: Window = 0;
    var parent_ret: Window = 0;
    var children: [*]Window = undefined;
    var nchildren: c_uint = 0;
    if (x.queryTree(dpy, root, &root_ret, &parent_ret, &children, &nchildren) == 0) return 0;
    defer _ = x.free(@ptrCast(children));

    var count: usize = 0;
    var i: c_uint = 0;
    while (i < nchildren and count < capacity) : (i += 1) {
        const win = children[i];
        var attr: XWindowAttributes = .{};
        if (x.getWindowAttributes(dpy, win, &attr) == 0) continue;
        if (opts.visible_only and attr.map_state != IsViewable) continue;
        if (attr.width < opts.min_width or attr.height < opts.min_height) continue;

        var abs_x: c_int = 0;
        var abs_y: c_int = 0;
        var child_ret: Window = 0;
        _ = x.translateCoordinates(dpy, win, root, 0, 0, &abs_x, &abs_y, &child_ret);

        var info: WindowInfo = .{
            .handle = @intCast(win),
            .left = abs_x,
            .top = abs_y,
            .width = attr.width,
            .height = attr.height,
        };
        var name_ptr: ?[*:0]u8 = null;
        if (x.fetchName(dpy, win, &name_ptr) != 0) {
            if (name_ptr) |p| {
                const len = @min(cstrLen(p), MAX_TITLE);
                var k: usize = 0;
                while (k < len) : (k += 1) info.title[k] = p[k];
                info.title_len = len;
                _ = x.free(@ptrCast(p));
            }
        }

        list.items[count] = info;
        count += 1;
    }

    list.len = count;
    return count;
}

pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    const width: u32 = @intCast(if (win.width > 0) win.width else 0);
    const height: u32 = @intCast(if (win.height > 0) win.height else 0);
    if (width == 0 or height == 0) return api.captureFail(out);
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < needed) return api.captureFail(out);

    const x = xlib() orelse return api.captureFail(out);
    const dpy = x.openDisplay(null) orelse return api.captureFail(out);
    defer _ = x.closeDisplay(dpy);

    const img = x.getImage(dpy, @intCast(win.handle), 0, 0, width, height, AllPlanes, ZPixmap) orelse return api.captureFail(out);
    defer _ = x.destroyImage(img);

    const data = img.data orelse return api.captureFail(out);
    const bpp: usize = @intCast(@divTrunc(img.bits_per_pixel, 8));
    const stride: usize = @intCast(img.bytes_per_line);
    if (bpp < 3) return api.captureFail(out);

    const r_shift = maskShift(img.red_mask);
    const g_shift = maskShift(img.green_mask);
    const b_shift = maskShift(img.blue_mask);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var xx: usize = 0;
        const row = y * stride;
        while (xx < width) : (xx += 1) {
            const px_off = row + xx * bpp;
            var pixel: u32 = 0;
            var n: usize = 0;
            while (n < bpp and n < 4) : (n += 1) {
                pixel |= @as(u32, data[px_off + n]) << @intCast(n * 8);
            }
            const o = (y * width + xx) * 4;
            out[o] = @intCast((pixel >> r_shift) & 0xFF);
            out[o + 1] = @intCast((pixel >> g_shift) & 0xFF);
            out[o + 2] = @intCast((pixel >> b_shift) & 0xFF);
            out[o + 3] = 255;
        }
    }

    return .{ .pixels = out[0..needed], .width = width, .height = height, .ok = true };
}

fn maskShift(mask: c_ulong) u5 {
    if (mask == 0) return 0;
    var m = mask;
    var shift: u5 = 0;
    while (m & 1 == 0) : (m >>= 1) shift += 1;
    return shift;
}

pub fn clickAt(screen_x: i32, screen_y: i32) bool {
    const x = xlib() orelse return false;
    const dpy = x.openDisplay(null) orelse return false;
    defer _ = x.closeDisplay(dpy);

    _ = x.warpPointer(dpy, 0, x.defaultRootWindow(dpy), 0, 0, 0, 0, screen_x, screen_y);
    _ = x.sync(dpy, 0);
    const Button1: c_uint = 1;
    if (x.testFakeButtonEvent(dpy, Button1, 1, 0) == 0) return false; // press
    if (x.testFakeButtonEvent(dpy, Button1, 0, 0) == 0) return false; // release
    _ = x.sync(dpy, 0);
    return true;
}

const timespec = extern struct { tv_sec: c_long = 0, tv_nsec: c_long = 0 };
extern "c" fn nanosleep(*const timespec, ?*timespec) callconv(.c) c_int;

pub fn sleepMs(ms: u32) void {
    const ts = timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}
