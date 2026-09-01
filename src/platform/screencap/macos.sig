// screencap macOS backend — CoreGraphics capture + CGEvent synthetic click.
// Selected at comptime by screencap.sig on macOS targets.
//
// Uses the CoreGraphics window services: CGWindowListCopyWindowInfo to
// enumerate on-screen windows, CGWindowListCreateImage to capture one, and
// CGEvent to post a synthetic mouse click. Links the CoreGraphics /
// CoreFoundation frameworks (resolved by the linker for macOS targets).

const api = @import("../screencap.sig");

const WindowInfo = api.WindowInfo;
const Capture = api.Capture;
const EnumOptions = api.EnumOptions;
const MAX_TITLE = api.MAX_TITLE;

// ── CoreFoundation / CoreGraphics opaque types ──
const CFTypeRef = ?*anyopaque;
const CFArrayRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFNumberRef = ?*anyopaque;
const CGImageRef = ?*anyopaque;
const CGDataProviderRef = ?*anyopaque;
const CFDataRef = ?*anyopaque;
const CGEventRef = ?*anyopaque;
const CGEventSourceRef = ?*anyopaque;

const CGWindowID = u32;
const CGWindowListOption = u32;
const CGRect = extern struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 };
const CGPoint = extern struct { x: f64 = 0, y: f64 = 0 };

const kCGWindowListOptionOnScreenOnly: CGWindowListOption = 1 << 0;
const kCGWindowListExcludeDesktopElements: CGWindowListOption = 1 << 4;
const kCGNullWindowID: CGWindowID = 0;
const kCGWindowImageDefault: u32 = 0;

const kCGEventLeftMouseDown: u32 = 1;
const kCGEventLeftMouseUp: u32 = 2;
const kCGMouseButtonLeft: u32 = 0;
const kCGHIDEventTap: u32 = 0;

const kCFNumberIntType: c_long = 9;
const kCFNumberFloat64Type: c_long = 6;

extern "c" fn CGWindowListCopyWindowInfo(CGWindowListOption, CGWindowID) callconv(.c) CFArrayRef;
extern "c" fn CFArrayGetCount(CFArrayRef) callconv(.c) c_long;
extern "c" fn CFArrayGetValueAtIndex(CFArrayRef, c_long) callconv(.c) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(CFDictionaryRef, ?*anyopaque) callconv(.c) ?*anyopaque;
extern "c" fn CFNumberGetValue(CFNumberRef, c_long, ?*anyopaque) callconv(.c) u8;
extern "c" fn CFStringGetCString(CFStringRef, [*]u8, c_long, u32) callconv(.c) u8;
extern "c" fn CFRelease(CFTypeRef) callconv(.c) void;

extern "c" fn CGWindowListCreateImage(CGRect, CGWindowListOption, CGWindowID, u32) callconv(.c) CGImageRef;
extern "c" fn CGImageGetWidth(CGImageRef) callconv(.c) usize;
extern "c" fn CGImageGetHeight(CGImageRef) callconv(.c) usize;
extern "c" fn CGImageGetBytesPerRow(CGImageRef) callconv(.c) usize;
extern "c" fn CGImageGetBitsPerPixel(CGImageRef) callconv(.c) usize;
extern "c" fn CGImageGetDataProvider(CGImageRef) callconv(.c) CGDataProviderRef;
extern "c" fn CGDataProviderCopyData(CGDataProviderRef) callconv(.c) CFDataRef;
extern "c" fn CFDataGetLength(CFDataRef) callconv(.c) c_long;
extern "c" fn CFDataGetBytePtr(CFDataRef) callconv(.c) ?[*]const u8;
extern "c" fn CGImageRelease(CGImageRef) callconv(.c) void;

extern "c" fn CGEventCreateMouseEvent(CGEventSourceRef, u32, CGPoint, u32) callconv(.c) CGEventRef;
extern "c" fn CGEventPost(u32, CGEventRef) callconv(.c) void;
extern "c" fn CFRunLoopRunInMode(CFStringRef, f64, u8) callconv(.c) i32;

// The dictionary keys are exported CFStringRef symbols from CoreGraphics.
extern "c" const kCGWindowNumber: CFStringRef;
extern "c" const kCGWindowName: CFStringRef;
extern "c" const kCGWindowBounds: CFStringRef;

// CGRectMakeWithDictionaryRepresentation parses the bounds dictionary.
extern "c" fn CGRectMakeWithDictionaryRepresentation(CFDictionaryRef, *CGRect) callconv(.c) u8;

extern "c" fn usleep(u32) callconv(.c) c_int;

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
    list.len = 0;
    const options = kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
    const arr = CGWindowListCopyWindowInfo(options, kCGNullWindowID) orelse return 0;
    defer CFRelease(arr);

    const n = CFArrayGetCount(arr);
    var count: usize = 0;
    var idx: c_long = 0;
    while (idx < n and count < capacity) : (idx += 1) {
        const dict = CFArrayGetValueAtIndex(arr, idx) orelse continue;

        // Window id
        var wid: c_int = 0;
        const num = CFDictionaryGetValue(dict, kCGWindowNumber);
        if (num != null) _ = CFNumberGetValue(num, kCFNumberIntType, &wid);

        // Bounds
        var rect: CGRect = .{};
        const bounds = CFDictionaryGetValue(dict, kCGWindowBounds);
        if (bounds != null) _ = CGRectMakeWithDictionaryRepresentation(bounds, &rect);
        const width: i32 = @intFromFloat(rect.w);
        const height: i32 = @intFromFloat(rect.h);
        if (width < opts.min_width or height < opts.min_height) continue;

        var info: WindowInfo = .{
            .handle = @intCast(@as(u32, @bitCast(wid))),
            .left = @intFromFloat(rect.x),
            .top = @intFromFloat(rect.y),
            .width = width,
            .height = height,
        };

        // Title (optional)
        const name = CFDictionaryGetValue(dict, kCGWindowName);
        if (name != null) {
            if (CFStringGetCString(name, &info.title, MAX_TITLE, 0x08000100) != 0) { // kCFStringEncodingUTF8
                info.title_len = cstrLen(&info.title);
            }
        }

        list.items[count] = info;
        count += 1;
    }

    list.len = count;
    return count;
}

fn cstrLen(buf: []const u8) usize {
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) : (n += 1) {}
    return n;
}

pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    const width: u32 = @intCast(if (win.width > 0) win.width else 0);
    const height: u32 = @intCast(if (win.height > 0) win.height else 0);
    if (width == 0 or height == 0) return api.captureFail(out);
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < needed) return api.captureFail(out);

    const wid: CGWindowID = @intCast(win.handle);
    // Null rect => the window's own bounds.
    const null_rect = CGRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    _ = null_rect;
    const img = CGWindowListCreateImage(
        .{ .x = @floatFromInt(win.left), .y = @floatFromInt(win.top), .w = @floatFromInt(win.width), .h = @floatFromInt(win.height) },
        kCGWindowListOptionOnScreenOnly,
        wid,
        kCGWindowImageDefault,
    ) orelse return api.captureFail(out);
    defer CGImageRelease(img);

    const img_w = CGImageGetWidth(img);
    const img_h = CGImageGetHeight(img);
    const stride = CGImageGetBytesPerRow(img);
    const bpp = @divTrunc(CGImageGetBitsPerPixel(img), 8);
    if (bpp < 3) return api.captureFail(out);

    const provider = CGImageGetDataProvider(img) orelse return api.captureFail(out);
    const cfdata = CGDataProviderCopyData(provider) orelse return api.captureFail(out);
    defer CFRelease(cfdata);
    const src = CFDataGetBytePtr(cfdata) orelse return api.captureFail(out);

    const cw = @min(@as(usize, width), img_w);
    const ch = @min(@as(usize, height), img_h);

    // CoreGraphics gives BGRA (little-endian ARGB); normalize to RGBA.
    var y: usize = 0;
    while (y < ch) : (y += 1) {
        var x: usize = 0;
        const row = y * stride;
        while (x < cw) : (x += 1) {
            const s = row + x * bpp;
            const o = (y * width + x) * 4;
            out[o] = src[s + 2]; // R
            out[o + 1] = src[s + 1]; // G
            out[o + 2] = src[s]; // B
            out[o + 3] = 255;
        }
    }

    return .{ .pixels = out[0..needed], .width = width, .height = height, .ok = true };
}

pub fn clickAt(screen_x: i32, screen_y: i32) bool {
    const pt = CGPoint{ .x = @floatFromInt(screen_x), .y = @floatFromInt(screen_y) };
    const down = CGEventCreateMouseEvent(null, kCGEventLeftMouseDown, pt, kCGMouseButtonLeft) orelse return false;
    defer CFRelease(down);
    const up = CGEventCreateMouseEvent(null, kCGEventLeftMouseUp, pt, kCGMouseButtonLeft) orelse return false;
    defer CFRelease(up);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    return true;
}

pub fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}
