// screencap — window enumeration, per-window capture, and synthetic click.
// Layer 1: Platform (Windows). General-purpose primitives for UI automation.
//
// This module is the reusable bridge between the OS window/GDI/input APIs and
// higher-level tools. It does no policy: it enumerates windows, hands back
// RGBA pixels for a given window, and clicks a screen coordinate. Callers
// decide what to capture and whether to click.
//
// Buffers are caller-provided; this module allocates nothing on the heap.

const builtin = @import("builtin");
const w32 = @import("win32");

pub const MAX_TITLE = 256;

/// A single top-level window discovered by `enumerate`.
pub const WindowInfo = struct {
    hwnd: w32.HWND,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    /// UTF-16 title, null-padded; `title_len` code units are valid.
    title: [MAX_TITLE]u16 = @splat(0),
    title_len: usize = 0,
};

/// Fixed-capacity list of enumerated windows (no heap).
pub fn WindowList(comptime capacity: usize) type {
    return struct {
        items: [capacity]WindowInfo = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *const Self) []const WindowInfo {
            return self.items[0..self.len];
        }
    };
}

// EnumWindows uses a C callback with an LPARAM cookie. We route it back to a
// file-scope collector because the callback cannot capture Sig closures.
const CollectCtx = struct {
    items: [*]WindowInfo,
    capacity: usize,
    len: usize,
    visible_only: bool,
    min_w: i32,
    min_h: i32,
};

var g_collect: ?*CollectCtx = null;

fn enumProc(hwnd: w32.HWND, _: w32.LPARAM) callconv(.c) w32.BOOL {
    const ctx = g_collect orelse return 1;
    if (ctx.len >= ctx.capacity) return 0; // stop; full

    if (ctx.visible_only and w32.IsWindowVisible(hwnd) == 0) return 1;
    if (w32.IsIconic(hwnd) != 0) return 1; // skip minimized

    var rect: w32.RECT = .{};
    if (w32.GetWindowRect(hwnd, &rect) == 0) return 1;
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width < ctx.min_w or height < ctx.min_h) return 1;

    var info: WindowInfo = .{
        .hwnd = hwnd,
        .left = rect.left,
        .top = rect.top,
        .width = width,
        .height = height,
    };
    const n = w32.GetWindowTextW(hwnd, &info.title, MAX_TITLE);
    info.title_len = if (n > 0) @intCast(n) else 0;

    ctx.items[ctx.len] = info;
    ctx.len += 1;
    return 1;
}

pub const EnumOptions = struct {
    visible_only: bool = true,
    min_width: i32 = 64,
    min_height: i32 = 32,
};

/// Enumerate top-level windows into `list`. Returns the number collected.
pub fn enumerate(comptime capacity: usize, list: *WindowList(capacity), opts: EnumOptions) usize {
    if (builtin.os.tag != .windows) return 0;
    var ctx: CollectCtx = .{
        .items = &list.items,
        .capacity = capacity,
        .len = 0,
        .visible_only = opts.visible_only,
        .min_w = opts.min_width,
        .min_h = opts.min_height,
    };
    g_collect = &ctx;
    _ = w32.EnumWindows(&enumProc, 0);
    g_collect = null;
    list.len = ctx.len;
    return ctx.len;
}

pub const Capture = struct {
    /// Tightly packed RGBA, row-major, top-left origin. Points into the
    /// caller-provided buffer.
    pixels: []u8,
    width: u32,
    height: u32,
    ok: bool,
};

/// Capture a window's full content into `out` as RGBA. `out` must be at least
/// `width*height*4` bytes for the window's current size. Uses PrintWindow so
/// occluded/background windows still capture correctly.
pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    if (builtin.os.tag != .windows) return .{ .pixels = out[0..0], .width = 0, .height = 0, .ok = false };
    const width: u32 = @intCast(if (win.width > 0) win.width else 0);
    const height: u32 = @intCast(if (win.height > 0) win.height else 0);
    if (width == 0 or height == 0) return fail(out);
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < needed) return fail(out);

    const screen_dc = w32.GetDC(null) orelse return fail(out);
    defer _ = w32.ReleaseDC(null, screen_dc);
    const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return fail(out);
    defer _ = w32.DeleteDC(mem_dc);
    const bitmap = w32.CreateCompatibleBitmap(screen_dc, win.width, win.height) orelse return fail(out);
    defer _ = w32.DeleteObject(@ptrCast(bitmap));
    const old = w32.SelectObject(mem_dc, @ptrCast(bitmap));
    defer _ = w32.SelectObject(mem_dc, old orelse @ptrCast(bitmap));

    // Prefer PrintWindow (captures unfocused windows); fall back to BitBlt.
    if (w32.PrintWindow(win.hwnd, mem_dc, w32.PW_RENDERFULLCONTENT) == 0) {
        if (w32.BitBlt(mem_dc, 0, 0, win.width, win.height, screen_dc, win.left, win.top, w32.SRCCOPY | w32.CAPTUREBLT) == 0) {
            return fail(out);
        }
    }

    // Read back as 32-bit top-down BGRA.
    var bmi: w32.BITMAPINFO = .{};
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = win.width;
    bmi.bmiHeader.biHeight = -win.height; // negative = top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = w32.BI_RGB_COMPRESSION;

    const rows = w32.GetDIBits(mem_dc, bitmap, 0, height, out.ptr, &bmi, w32.DIB_RGB_COLORS);
    if (rows == 0) return fail(out);

    // GDI gives BGRA; swap to RGBA in place.
    var i: usize = 0;
    while (i < needed) : (i += 4) {
        const b = out[i];
        out[i] = out[i + 2];
        out[i + 2] = b;
        out[i + 3] = 255;
    }

    return .{ .pixels = out[0..needed], .width = width, .height = height, .ok = true };
}

fn fail(out: []u8) Capture {
    return .{ .pixels = out[0..0], .width = 0, .height = 0, .ok = false };
}

/// Synthetically click at an absolute screen coordinate using SendInput.
/// Returns true if both the down and up events were injected.
pub fn clickAt(screen_x: i32, screen_y: i32) bool {
    if (builtin.os.tag != .windows) return false;

    // Map to the 0..65535 virtual-desktop coordinate space SendInput expects.
    const vx = w32.GetSystemMetrics(w32.SM_XVIRTUALSCREEN);
    const vy = w32.GetSystemMetrics(w32.SM_YVIRTUALSCREEN);
    const vw = w32.GetSystemMetrics(w32.SM_CXVIRTUALSCREEN);
    const vh = w32.GetSystemMetrics(w32.SM_CYVIRTUALSCREEN);
    if (vw <= 0 or vh <= 0) return false;

    const nx: i32 = @intCast(@divTrunc((@as(i64, screen_x - vx)) * 65535, vw));
    const ny: i32 = @intCast(@divTrunc((@as(i64, screen_y - vy)) * 65535, vh));

    const flags = w32.MOUSEEVENTF_MOVE | w32.MOUSEEVENTF_ABSOLUTE | w32.MOUSEEVENTF_VIRTUALDESK;
    const inputs = [_]w32.INPUT{
        .{ .type = w32.INPUT_MOUSE, .mi = .{ .dx = nx, .dy = ny, .dwFlags = flags | w32.MOUSEEVENTF_LEFTDOWN } },
        .{ .type = w32.INPUT_MOUSE, .mi = .{ .dx = nx, .dy = ny, .dwFlags = flags | w32.MOUSEEVENTF_LEFTUP } },
    };
    const sent = w32.SendInput(2, &inputs, @sizeOf(w32.INPUT));
    return sent == 2;
}

/// Sleep for `ms` milliseconds (used between click and verification capture).
pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) w32.Sleep(ms);
}
