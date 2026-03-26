// Window creation and OpenGL context management
// Layer 1: Platform

const w32 = @import("win32");
const gl = @import("gl");

pub const WindowError = error{
    ClassRegistrationFailed,
    CreationFailed,
    GetDCFailed,
    PixelFormatFailed,
    SetPixelFormatFailed,
    GLContextFailed,
    GLMakeCurrentFailed,
};

pub const Window = struct {
    hwnd: w32.HWND,
    hdc: w32.HDC,
    gl_ctx: w32.HGLRC,
    width: i32,
    height: i32,
    running: bool,
    tray_icon: w32.NOTIFYICONDATAW = .{},

    pub fn init(
        title: w32.LPCWSTR,
        width: i32,
        height: i32,
        wnd_proc: *const fn (w32.HWND, u32, w32.WPARAM, w32.LPARAM) callconv(.c) w32.LRESULT,
        icon_data: ?[]const u8,
    ) WindowError!Window {
        return initWithConfig(title, width, height, wnd_proc, 230, icon_data);
    }

    pub fn initWithConfig(
        title: w32.LPCWSTR,
        width: i32,
        height: i32,
        wnd_proc: *const fn (w32.HWND, u32, w32.WPARAM, w32.LPARAM) callconv(.c) w32.LRESULT,
        opacity: u8,
        icon_data: ?[]const u8,
    ) WindowError!Window {
        const hInstance = w32.GetModuleHandleW(null);
        const class_name = w32.L("ZigTradingWindow");

        // Load app icon from caller-provided icon data
        var app_icon: w32.HICON = null;
        var app_icon_sm: w32.HICON = null;
        if (icon_data) |ico_data| {
            const offset_lg = w32.LookupIconIdFromDirectoryEx(ico_data.ptr, 1, 32, 32, 0);
            if (offset_lg > 0) {
                const off: usize = @intCast(offset_lg);
                app_icon = @ptrCast(w32.CreateIconFromResourceEx(
                    ico_data.ptr + off,
                    @intCast(ico_data.len - off),
                    1,
                    0x00030000,
                    32,
                    32,
                    0,
                ));
            }
            const offset_sm = w32.LookupIconIdFromDirectoryEx(ico_data.ptr, 1, 16, 16, 0);
            if (offset_sm > 0) {
                const off: usize = @intCast(offset_sm);
                app_icon_sm = @ptrCast(w32.CreateIconFromResourceEx(
                    ico_data.ptr + off,
                    @intCast(ico_data.len - off),
                    1,
                    0x00030000,
                    16,
                    16,
                    0,
                ));
            }
        }

        const wc = w32.WNDCLASSEXW{
            .style = w32.CS_OWNDC | w32.CS_HREDRAW | w32.CS_VREDRAW,
            .lpfnWndProc = wnd_proc,
            .hInstance = hInstance,
            .hIcon = app_icon,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .lpszClassName = class_name,
            .hIconSm = app_icon_sm,
        };

        if (w32.RegisterClassExW(&wc) == 0) return WindowError.ClassRegistrationFailed;

        // Center the window on screen (CW_USEDEFAULT doesn't work with WS_POPUP)
        const screen_w = w32.GetSystemMetrics(w32.SM_CXSCREEN);
        const screen_h = w32.GetSystemMetrics(w32.SM_CYSCREEN);
        const x = @divTrunc(screen_w - width, 2);
        const y = @divTrunc(screen_h - height, 2);

        const hwnd = w32.CreateWindowExW(
            w32.WS_EX_APPWINDOW | w32.WS_EX_LAYERED,
            class_name,
            title,
            w32.WS_POPUP | w32.WS_MINIMIZEBOX | w32.WS_MAXIMIZEBOX | w32.WS_SYSMENU | w32.WS_VISIBLE,
            x,
            y,
            width,
            height,
            null,
            null,
            hInstance,
            null,
        ) orelse return WindowError.CreationFailed;

        // Make window translucent (configurable opacity)
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, opacity, w32.LWA_ALPHA);

        const hdc = w32.GetDC(hwnd) orelse return WindowError.GetDCFailed;

        // Set up OpenGL pixel format
        var pfd = w32.PIXELFORMATDESCRIPTOR{
            .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
            .iPixelType = w32.PFD_TYPE_RGBA,
            .cColorBits = 32,
            .cDepthBits = 24,
            .cStencilBits = 8,
            .iLayerType = w32.PFD_MAIN_PLANE,
        };

        const pf = w32.ChoosePixelFormat(hdc, &pfd);
        if (pf == 0) return WindowError.PixelFormatFailed;
        if (w32.SetPixelFormat(hdc, pf, &pfd) == 0) return WindowError.SetPixelFormatFailed;

        const gl_ctx = w32.wglCreateContext(hdc) orelse return WindowError.GLContextFailed;
        if (w32.wglMakeCurrent(hdc, gl_ctx) == 0) return WindowError.GLMakeCurrentFailed;

        _ = w32.ShowWindow(hwnd, w32.SW_SHOW);

        // Set up system tray icon reusing the loaded app icon
        var nid = w32.NOTIFYICONDATAW{
            .hWnd = hwnd,
            .uID = 1,
            .uFlags = w32.NIF_MESSAGE | w32.NIF_ICON | w32.NIF_TIP,
            .uCallbackMessage = w32.WM_TRAYICON,
            .hIcon = app_icon,
        };
        // Set tooltip: "SB0 Trade"
        const tip = comptime blk: {
            const s = "SB0 Trade";
            var buf: [128]u16 = [_]u16{0} ** 128;
            for (s, 0..) |c, i| {
                buf[i] = c;
            }
            break :blk buf;
        };
        nid.szTip = tip;
        _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);

        return .{
            .hwnd = hwnd,
            .hdc = hdc,
            .gl_ctx = gl_ctx,
            .width = width,
            .height = height,
            .running = true,
            .tray_icon = nid,
        };
    }

    pub fn pollEvents(self: *Window) void {
        var msg: w32.MSG = .{};
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            if (msg.message == w32.WM_QUIT) {
                self.running = false;
                return;
            }
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
    }

    pub fn swap(self: *const Window) void {
        _ = w32.SwapBuffers(self.hdc);
    }

    pub fn deinit(self: *Window) void {
        // Remove tray icon
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &self.tray_icon);
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(self.gl_ctx);
        _ = w32.ReleaseDC(self.hwnd, self.hdc);
    }
};
