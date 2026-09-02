// screencap macOS backend — CoreGraphics capture + CGEvent synthetic click.
// Selected at comptime by screencap.sig on macOS targets.
//
// CoreGraphics / CoreFoundation are loaded at RUNTIME via std.DynLib (dlopen of
// the framework binaries), not linked at build time — so the suite
// cross-compiles to macOS from any host without the SDK frameworks present, and
// degrades gracefully when they are unavailable. Screen capture on macOS also
// requires the user to grant Screen Recording permission; without it the OS
// returns empty images, which this backend reports as capture failure.

const std = @import("std");
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
const CGImageRef = ?*anyopaque;
const CGDataProviderRef = ?*anyopaque;
const CFDataRef = ?*anyopaque;
const CGEventRef = ?*anyopaque;

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
const kCFStringEncodingUTF8: u32 = 0x08000100;

// ── Function-pointer signatures ──
const FnWindowListCopyInfo = *const fn (CGWindowListOption, CGWindowID) callconv(.c) CFArrayRef;
const FnArrayGetCount = *const fn (CFArrayRef) callconv(.c) c_long;
const FnArrayGetValueAtIndex = *const fn (CFArrayRef, c_long) callconv(.c) ?*anyopaque;
const FnDictionaryGetValue = *const fn (CFDictionaryRef, ?*anyopaque) callconv(.c) ?*anyopaque;
const FnNumberGetValue = *const fn (CFTypeRef, c_long, ?*anyopaque) callconv(.c) u8;
const FnStringGetCString = *const fn (CFStringRef, [*]u8, c_long, u32) callconv(.c) u8;
const FnRelease = *const fn (CFTypeRef) callconv(.c) void;
const FnRectFromDict = *const fn (CFDictionaryRef, *CGRect) callconv(.c) u8;

const FnWindowListCreateImage = *const fn (CGRect, CGWindowListOption, CGWindowID, u32) callconv(.c) CGImageRef;
const FnImageGetWidth = *const fn (CGImageRef) callconv(.c) usize;
const FnImageGetHeight = *const fn (CGImageRef) callconv(.c) usize;
const FnImageGetBytesPerRow = *const fn (CGImageRef) callconv(.c) usize;
const FnImageGetBitsPerPixel = *const fn (CGImageRef) callconv(.c) usize;
const FnImageGetDataProvider = *const fn (CGImageRef) callconv(.c) CGDataProviderRef;
const FnDataProviderCopyData = *const fn (CGDataProviderRef) callconv(.c) CFDataRef;
const FnDataGetBytePtr = *const fn (CFDataRef) callconv(.c) ?[*]const u8;
const FnImageRelease = *const fn (CGImageRef) callconv(.c) void;

const FnEventCreateMouse = *const fn (?*anyopaque, u32, CGPoint, u32) callconv(.c) CGEventRef;
const FnEventPost = *const fn (u32, CGEventRef) callconv(.c) void;

const Cg = struct {
    windowListCopyInfo: FnWindowListCopyInfo,
    arrayGetCount: FnArrayGetCount,
    arrayGetValueAtIndex: FnArrayGetValueAtIndex,
    dictionaryGetValue: FnDictionaryGetValue,
    numberGetValue: FnNumberGetValue,
    stringGetCString: FnStringGetCString,
    release: FnRelease,
    rectFromDict: FnRectFromDict,
    windowListCreateImage: FnWindowListCreateImage,
    imageGetWidth: FnImageGetWidth,
    imageGetHeight: FnImageGetHeight,
    imageGetBytesPerRow: FnImageGetBytesPerRow,
    imageGetBitsPerPixel: FnImageGetBitsPerPixel,
    imageGetDataProvider: FnImageGetDataProvider,
    dataProviderCopyData: FnDataProviderCopyData,
    dataGetBytePtr: FnDataGetBytePtr,
    imageRelease: FnImageRelease,
    eventCreateMouse: FnEventCreateMouse,
    eventPost: FnEventPost,
    // Exported CFStringRef key symbols (data, dereferenced once at load).
    keyWindowNumber: CFStringRef,
    keyWindowName: CFStringRef,
    keyWindowBounds: CFStringRef,
};

var g_cg: ?Cg = null;
var g_attempted: bool = false;

const CG_PATH = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
const CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

fn deref(lib: *std.DynLib, name: [:0]const u8) CFStringRef {
    const p = lib.lookup(*CFStringRef, name) orelse return null;
    return p.*;
}

fn cg() ?*const Cg {
    if (g_attempted) return if (g_cg) |*c| c else null;
    g_attempted = true;

    var cgl = std.DynLib.open(CG_PATH) catch return null;
    var cfl = std.DynLib.open(CF_PATH) catch {
        cgl.close();
        return null;
    };

    g_cg = .{
        .windowListCopyInfo = cgl.lookup(FnWindowListCopyInfo, "CGWindowListCopyWindowInfo") orelse return null,
        .arrayGetCount = cfl.lookup(FnArrayGetCount, "CFArrayGetCount") orelse return null,
        .arrayGetValueAtIndex = cfl.lookup(FnArrayGetValueAtIndex, "CFArrayGetValueAtIndex") orelse return null,
        .dictionaryGetValue = cfl.lookup(FnDictionaryGetValue, "CFDictionaryGetValue") orelse return null,
        .numberGetValue = cfl.lookup(FnNumberGetValue, "CFNumberGetValue") orelse return null,
        .stringGetCString = cfl.lookup(FnStringGetCString, "CFStringGetCString") orelse return null,
        .release = cfl.lookup(FnRelease, "CFRelease") orelse return null,
        .rectFromDict = cgl.lookup(FnRectFromDict, "CGRectMakeWithDictionaryRepresentation") orelse return null,
        .windowListCreateImage = cgl.lookup(FnWindowListCreateImage, "CGWindowListCreateImage") orelse return null,
        .imageGetWidth = cgl.lookup(FnImageGetWidth, "CGImageGetWidth") orelse return null,
        .imageGetHeight = cgl.lookup(FnImageGetHeight, "CGImageGetHeight") orelse return null,
        .imageGetBytesPerRow = cgl.lookup(FnImageGetBytesPerRow, "CGImageGetBytesPerRow") orelse return null,
        .imageGetBitsPerPixel = cgl.lookup(FnImageGetBitsPerPixel, "CGImageGetBitsPerPixel") orelse return null,
        .imageGetDataProvider = cgl.lookup(FnImageGetDataProvider, "CGImageGetDataProvider") orelse return null,
        .dataProviderCopyData = cgl.lookup(FnDataProviderCopyData, "CGDataProviderCopyData") orelse return null,
        .dataGetBytePtr = cfl.lookup(FnDataGetBytePtr, "CFDataGetBytePtr") orelse return null,
        .imageRelease = cgl.lookup(FnImageRelease, "CGImageRelease") orelse return null,
        .eventCreateMouse = cgl.lookup(FnEventCreateMouse, "CGEventCreateMouseEvent") orelse return null,
        .eventPost = cgl.lookup(FnEventPost, "CGEventPost") orelse return null,
        .keyWindowNumber = deref(&cgl, "kCGWindowNumber") orelse return null,
        .keyWindowName = deref(&cgl, "kCGWindowName") orelse return null,
        .keyWindowBounds = deref(&cgl, "kCGWindowBounds") orelse return null,
    };
    return if (g_cg) |*c| c else null;
}

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
    list.len = 0;
    const c = cg() orelse return 0;
    const options = kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
    const arr = c.windowListCopyInfo(options, kCGNullWindowID) orelse return 0;
    defer c.release(arr);

    const n = c.arrayGetCount(arr);
    var count: usize = 0;
    var idx: c_long = 0;
    while (idx < n and count < capacity) : (idx += 1) {
        const dict = c.arrayGetValueAtIndex(arr, idx) orelse continue;

        var wid: c_int = 0;
        const num = c.dictionaryGetValue(dict, c.keyWindowNumber);
        if (num != null) _ = c.numberGetValue(num, kCFNumberIntType, &wid);

        var rect: CGRect = .{};
        const bounds = c.dictionaryGetValue(dict, c.keyWindowBounds);
        if (bounds != null) _ = c.rectFromDict(bounds, &rect);
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

        const name = c.dictionaryGetValue(dict, c.keyWindowName);
        if (name != null) {
            if (c.stringGetCString(name, &info.title, MAX_TITLE, kCFStringEncodingUTF8) != 0) {
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

    const c = cg() orelse return api.captureFail(out);
    const wid: CGWindowID = @intCast(win.handle);
    const img = c.windowListCreateImage(
        .{ .x = @floatFromInt(win.left), .y = @floatFromInt(win.top), .w = @floatFromInt(win.width), .h = @floatFromInt(win.height) },
        kCGWindowListOptionOnScreenOnly,
        wid,
        kCGWindowImageDefault,
    ) orelse return api.captureFail(out);
    defer c.imageRelease(img);

    const img_w = c.imageGetWidth(img);
    const img_h = c.imageGetHeight(img);
    const stride = c.imageGetBytesPerRow(img);
    const bpp = @divTrunc(c.imageGetBitsPerPixel(img), 8);
    if (bpp < 3) return api.captureFail(out);

    const provider = c.imageGetDataProvider(img) orelse return api.captureFail(out);
    const cfdata = c.dataProviderCopyData(provider) orelse return api.captureFail(out);
    defer c.release(cfdata);
    const src = c.dataGetBytePtr(cfdata) orelse return api.captureFail(out);

    const cw = @min(@as(usize, width), img_w);
    const ch = @min(@as(usize, height), img_h);

    // CoreGraphics gives BGRA; normalize to RGBA.
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
    const c = cg() orelse return false;
    const pt = CGPoint{ .x = @floatFromInt(screen_x), .y = @floatFromInt(screen_y) };
    const down = c.eventCreateMouse(null, kCGEventLeftMouseDown, pt, kCGMouseButtonLeft) orelse return false;
    defer c.release(down);
    const up = c.eventCreateMouse(null, kCGEventLeftMouseUp, pt, kCGMouseButtonLeft) orelse return false;
    defer c.release(up);
    c.eventPost(kCGHIDEventTap, down);
    c.eventPost(kCGHIDEventTap, up);
    return true;
}

extern "c" fn usleep(u32) callconv(.c) c_int;

pub fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}
