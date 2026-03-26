// wndProc — Win32 message dispatch
// Layer 1: Platform

const w32 = @import("win32");
const state_mod = @import("state.zig");
const mouse = @import("mouse.zig");
const keyboard = @import("keyboard.zig");

var g_state: *state_mod.AppState = undefined;
var g_hwnd: w32.HWND = undefined;

pub fn bind(s: *state_mod.AppState) void {
    g_state = s;
    mouse.bind(s);
    keyboard.bind(s);
}

pub fn setHwnd(hwnd: w32.HWND) void {
    g_hwnd = hwnd;
    mouse.setHwnd(hwnd);
}

pub fn wndProc(hwnd: w32.HWND, msg: u32, wparam: w32.WPARAM, lparam: w32.LPARAM) callconv(.c) w32.LRESULT {
    switch (msg) {
        w32.WM_NCHITTEST => return mouse.handleHitTest(hwnd, lparam),
        w32.WM_NCACTIVATE => return 1,
        w32.WM_GETMINMAXINFO => {
            const info: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
            if (monitor) |mon| {
                var mi = w32.MONITORINFO{};
                if (w32.GetMonitorInfoW(mon, &mi) != 0) {
                    const work = mi.rcWork;
                    info.ptMaxPosition.x = work.left;
                    info.ptMaxPosition.y = work.top;
                    info.ptMaxSize.x = work.right - work.left;
                    info.ptMaxSize.y = work.bottom - work.top;
                }
            }
            return 0;
        },
        w32.WM_SIZE => {
            const SIZE_MINIMIZED: u32 = 1;
            const size_type: u32 = @truncate(@as(usize, @bitCast(wparam)));
            if (size_type == SIZE_MINIMIZED) {
                _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
                return 0;
            }
            mouse.handleResize(lparam);
            g_state.maximized = w32.IsZoomed(hwnd) != 0;
        },
        w32.WM_TRAYICON => {
            const mouse_msg: u32 = @as(u32, @bitCast(@as(i32, @truncate(lparam))));
            if (mouse_msg == w32.WM_LBUTTONDBLCLK) {
                _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                _ = w32.SetForegroundWindow(hwnd);
            } else if (mouse_msg == w32.WM_RBUTTONUP) {
                var pt: w32.POINT = .{};
                _ = w32.GetCursorPos(&pt);
                const menu = w32.CreatePopupMenu();
                if (menu) |m| {
                    _ = w32.AppendMenuW(m, w32.MF_STRING, w32.IDM_SHOW, w32.L("Show"));
                    _ = w32.AppendMenuW(m, w32.MF_SEPARATOR, 0, null);
                    _ = w32.AppendMenuW(m, w32.MF_STRING, w32.IDM_CLOSE, w32.L("Close"));
                    _ = w32.SetForegroundWindow(hwnd);
                    _ = w32.TrackPopupMenu(m, w32.TPM_RIGHTBUTTON | w32.TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, null);
                    _ = w32.DestroyMenu(m);
                }
            }
            return 0;
        },
        w32.WM_COMMAND => {
            const cmd_id: u32 = @truncate(@as(usize, @bitCast(wparam)) & 0xFFFF);
            switch (cmd_id) {
                w32.IDM_SHOW => {
                    _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                    _ = w32.SetForegroundWindow(hwnd);
                },
                w32.IDM_CLOSE => w32.PostQuitMessage(0),
                else => {},
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => mouse.handleMouseMove(hwnd, lparam),
        w32.WM_LBUTTONDOWN => mouse.handleMouseDown(hwnd, lparam),
        w32.WM_LBUTTONUP => {
            g_state.chart.dragging = false;
            mouse.handleTitleBarClick(hwnd);
        },
        w32.WM_MOUSEWHEEL => mouse.handleWheel(wparam),
        w32.WM_KEYDOWN => keyboard.handleKeyDown(wparam),
        w32.WM_KEYUP => keyboard.handleKeyUp(wparam),
        w32.WM_CHAR => keyboard.handleChar(wparam),
        w32.WM_CLOSE, w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}
