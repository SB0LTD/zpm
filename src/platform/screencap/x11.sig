// screencap Linux backend — Xlib capture + XTest synthetic click.
// Selected at comptime by screencap.sig on Linux targets.
//
// Links against libX11 and libXtst (resolved by the linker via the `extern`
// library names when building for Linux). Enumerates top-level windows under
// the root, captures each with XGetImage, and clicks with XTestFakeButtonEvent.

const api = @import("../screencap.sig");

const WindowInfo = api.WindowInfo;
const Capture = api.Capture;
const EnumOptions = api.EnumOptions;
const MAX_TITLE = api.MAX_TITLE;

// ── Xlib types (opaque where we don't need the layout) ──
const Display = opaque {};
const Window = c_ulong;
const Atom = c_ulong;
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
    // remaining fields (obdata, functions) omitted — not accessed.
};

const IsViewable: c_int = 2; // map_state
const ZPixmap: c_int = 2;
const AllPlanes: c_ulong = ~@as(c_ulong, 0);

extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
extern "X11" fn XCloseDisplay(*Display) callconv(.c) c_int;
extern "X11" fn XDefaultRootWindow(*Display) callconv(.c) Window;
extern "X11" fn XQueryTree(*Display, Window, *Window, *Window, *[*]Window, *c_uint) callconv(.c) Status;
extern "X11" fn XGetWindowAttributes(*Display, Window, *XWindowAttributes) callconv(.c) Status;
extern "X11" fn XFetchName(*Display, Window, *?[*:0]u8) callconv(.c) Status;
extern "X11" fn XGetImage(*Display, Window, c_int, c_int, c_uint, c_uint, c_ulong, c_int) callconv(.c) ?*XImage;
extern "X11" fn XDestroyImage(*XImage) callconv(.c) c_int;
extern "X11" fn XFree(?*anyopaque) callconv(.c) c_int;
extern "X11" fn XTranslateCoordinates(*Display, Window, Window, c_int, c_int, *c_int, *c_int, *Window) callconv(.c) Bool;
extern "X11" fn XSync(*Display, Bool) callconv(.c) c_int;
extern "X11" fn XWarpPointer(*Display, Window, Window, c_int, c_int, c_uint, c_uint, c_int, c_int) callconv(.c) c_int;

extern "Xtst" fn XTestFakeButtonEvent(*Display, c_uint, Bool, c_ulong) callconv(.c) c_int;
extern "Xtst" fn XTestFakeMotionEvent(*Display, c_int, c_int, c_int, c_ulong) callconv(.c) c_int;

extern "c" fn nanosleep(*const timespec, ?*timespec) callconv(.c) c_int;
const timespec = extern struct { tv_sec: c_long = 0, tv_nsec: c_long = 0 };

fn cstrLen(p: [*:0]const u8) usize {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return n;
}

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
    list.len = 0;
    const dpy = XOpenDisplay(null) orelse return 0;
    defer _ = XCloseDisplay(dpy);

    const root = XDefaultRootWindow(dpy);
    var root_ret: Window = 0;
    var parent_ret: Window = 0;
    var children: [*]Window = undefined;
    var nchildren: c_uint = 0;
    if (XQueryTree(dpy, root, &root_ret, &parent_ret, &children, &nchildren) == 0) return 0;
    defer _ = XFree(@ptrCast(children));

    var count: usize = 0;
    var i: c_uint = 0;
    while (i < nchildren and count < capacity) : (i += 1) {
        const win = children[i];
        var attr: XWindowAttributes = .{};
        if (XGetWindowAttributes(dpy, win, &attr) == 0) continue;
        if (opts.visible_only and attr.map_state != IsViewable) continue;
        if (attr.width < opts.min_width or attr.height < opts.min_height) continue;

        // Translate the window origin to absolute root (screen) coordinates.
        var abs_x: c_int = 0;
        var abs_y: c_int = 0;
        var child_ret: Window = 0;
        _ = XTranslateCoordinates(dpy, win, root, 0, 0, &abs_x, &abs_y, &child_ret);

        var info: WindowInfo = .{
            .handle = @intCast(win),
            .left = abs_x,
            .top = abs_y,
            .width = attr.width,
            .height = attr.height,
        };
        var name_ptr: ?[*:0]u8 = null;
        if (XFetchName(dpy, win, &name_ptr) != 0) {
            if (name_ptr) |p| {
                const len = @min(cstrLen(p), MAX_TITLE);
                var k: usize = 0;
                while (k < len) : (k += 1) info.title[k] = p[k];
                info.title_len = len;
                _ = XFree(@ptrCast(p));
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

    const dpy = XOpenDisplay(null) orelse return api.captureFail(out);
    defer _ = XCloseDisplay(dpy);

    const img = XGetImage(dpy, @intCast(win.handle), 0, 0, width, height, AllPlanes, ZPixmap) orelse return api.captureFail(out);
    defer _ = XDestroyImage(img);

    const data = img.data orelse return api.captureFail(out);
    const bpp: usize = @intCast(@divTrunc(img.bits_per_pixel, 8));
    const stride: usize = @intCast(img.bytes_per_line);
    if (bpp < 3) return api.captureFail(out);

    // X11 default visual is typically BGRX (blue in the low byte). Normalize to
    // RGBA using the image's channel masks so we are endian/visual correct.
    const r_shift = maskShift(img.red_mask);
    const g_shift = maskShift(img.green_mask);
    const b_shift = maskShift(img.blue_mask);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        const row = y * stride;
        while (x < width) : (x += 1) {
            const px_off = row + x * bpp;
            // Read up to 4 bytes little-endian into a u32 pixel.
            var pixel: u32 = 0;
            var n: usize = 0;
            while (n < bpp and n < 4) : (n += 1) {
                pixel |= @as(u32, data[px_off + n]) << @intCast(n * 8);
            }
            const o = (y * width + x) * 4;
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
    const dpy = XOpenDisplay(null) orelse return false;
    defer _ = XCloseDisplay(dpy);

    _ = XWarpPointer(dpy, 0, XDefaultRootWindow(dpy), 0, 0, 0, 0, screen_x, screen_y);
    _ = XSync(dpy, 0);
    const Button1: c_uint = 1;
    if (XTestFakeButtonEvent(dpy, Button1, 1, 0) == 0) return false; // press
    if (XTestFakeButtonEvent(dpy, Button1, 0, 0) == 0) return false; // release
    _ = XSync(dpy, 0);
    return true;
}

pub fn sleepMs(ms: u32) void {
    const ts = timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}
