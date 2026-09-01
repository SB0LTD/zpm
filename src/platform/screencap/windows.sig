// screencap Windows backend — Win32 GDI capture + SendInput click.
// Selected at comptime by screencap.sig on Windows targets.

const w32 = @import("win32");
const api = @import("../screencap.sig");

const WindowInfo = api.WindowInfo;
const Capture = api.Capture;
const EnumOptions = api.EnumOptions;
const MAX_TITLE = api.MAX_TITLE;

// EnumWindows uses a C callback with an LPARAM cookie; route it to a
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
        .handle = @intFromPtr(hwnd),
        .left = rect.left,
        .top = rect.top,
        .width = width,
        .height = height,
    };
    // Read the UTF-16 title, then transcode to UTF-8 into the public field.
    var wbuf: [MAX_TITLE]u16 = @splat(0);
    const n = w32.GetWindowTextW(hwnd, &wbuf, MAX_TITLE);
    if (n > 0) info.title_len = utf16ToUtf8(wbuf[0..@intCast(n)], &info.title);

    ctx.items[ctx.len] = info;
    ctx.len += 1;
    return 1;
}

/// Minimal UTF-16 -> UTF-8 for window titles. Handles the BMP + surrogate
/// pairs; drops anything that would overflow the destination.
fn utf16ToUtf8(src: []const u16, dst: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        var cp: u32 = src[i];
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < src.len) {
            const lo = src[i + 1];
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 1;
            }
        }
        if (cp < 0x80) {
            if (out + 1 > dst.len) break;
            dst[out] = @intCast(cp);
            out += 1;
        } else if (cp < 0x800) {
            if (out + 2 > dst.len) break;
            dst[out] = @intCast(0xC0 | (cp >> 6));
            dst[out + 1] = @intCast(0x80 | (cp & 0x3F));
            out += 2;
        } else if (cp < 0x10000) {
            if (out + 3 > dst.len) break;
            dst[out] = @intCast(0xE0 | (cp >> 12));
            dst[out + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            dst[out + 2] = @intCast(0x80 | (cp & 0x3F));
            out += 3;
        } else {
            if (out + 4 > dst.len) break;
            dst[out] = @intCast(0xF0 | (cp >> 18));
            dst[out + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            dst[out + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            dst[out + 3] = @intCast(0x80 | (cp & 0x3F));
            out += 4;
        }
    }
    return out;
}

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
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

pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    const width: u32 = @intCast(if (win.width > 0) win.width else 0);
    const height: u32 = @intCast(if (win.height > 0) win.height else 0);
    if (width == 0 or height == 0) return api.captureFail(out);
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < needed) return api.captureFail(out);

    const hwnd: w32.HWND = @ptrFromInt(win.handle);

    const screen_dc = w32.GetDC(null) orelse return api.captureFail(out);
    defer _ = w32.ReleaseDC(null, screen_dc);
    const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return api.captureFail(out);
    defer _ = w32.DeleteDC(mem_dc);
    const bitmap = w32.CreateCompatibleBitmap(screen_dc, win.width, win.height) orelse return api.captureFail(out);
    defer _ = w32.DeleteObject(@ptrCast(bitmap));
    const old = w32.SelectObject(mem_dc, @ptrCast(bitmap));
    defer _ = w32.SelectObject(mem_dc, old orelse @ptrCast(bitmap));

    // Prefer PrintWindow (captures unfocused windows); fall back to BitBlt.
    if (w32.PrintWindow(hwnd, mem_dc, w32.PW_RENDERFULLCONTENT) == 0) {
        if (w32.BitBlt(mem_dc, 0, 0, win.width, win.height, screen_dc, win.left, win.top, w32.SRCCOPY | w32.CAPTUREBLT) == 0) {
            return api.captureFail(out);
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
    if (rows == 0) return api.captureFail(out);

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

pub fn clickAt(screen_x: i32, screen_y: i32) bool {
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

pub fn sleepMs(ms: u32) void {
    w32.Sleep(ms);
}
