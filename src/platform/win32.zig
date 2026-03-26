const std = @import("std");
const win = std.os.windows;

// ============================================================
// Type aliases
// ============================================================
pub const HWND = win.HWND;
pub const HINSTANCE = win.HINSTANCE;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HMENU = ?*opaque {};
pub const HICON = ?*opaque {};
pub const HCURSOR = ?*opaque {};
pub const HBRUSH = ?*opaque {};
pub const WPARAM = usize;
pub const LPARAM = win.LPARAM;
pub const LRESULT = isize;
pub const LPCWSTR = [*:0]const u16;
pub const BOOL = c_int;
pub const DWORD = win.DWORD;
pub const BYTE = u8;
pub const WORD = u16;

// ============================================================
// Constants
// ============================================================
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_POPUP: u32 = 0x80000000;
pub const WS_THICKFRAME: u32 = 0x00040000;
pub const WS_MINIMIZEBOX: u32 = 0x00020000;
pub const WS_MAXIMIZEBOX: u32 = 0x00010000;
pub const WS_SYSMENU: u32 = 0x00080000;
pub const WS_VISIBLE: u32 = 0x10000000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_RESTORE: i32 = 9;

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_NCHITTEST: u32 = 0x0084;
pub const WM_NCCALCSIZE: u32 = 0x0083;
pub const WM_GETMINMAXINFO: u32 = 0x0024;
pub const WM_NCACTIVATE: u32 = 0x0086;

// NCHITTEST return values
pub const HTCLIENT: i32 = 1;
pub const HTCAPTION: i32 = 2;
pub const HTLEFT: i32 = 10;
pub const HTRIGHT: i32 = 11;
pub const HTTOP: i32 = 12;
pub const HTTOPLEFT: i32 = 13;
pub const HTTOPRIGHT: i32 = 14;
pub const HTBOTTOM: i32 = 15;
pub const HTBOTTOMLEFT: i32 = 16;
pub const HTBOTTOMRIGHT: i32 = 17;
pub const HTCLOSE: i32 = 20;
pub const HTMAXBUTTON: i32 = 9;
pub const HTMINBUTTON: i32 = 8;

pub const CS_OWNDC: u32 = 0x0020;
pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_VREDRAW: u32 = 0x0001;

pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: BYTE = 0;
pub const PFD_MAIN_PLANE: BYTE = 0;

pub const SW_SHOW: i32 = 5;
pub const PM_REMOVE: u32 = 0x0001;
pub const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

// ============================================================
// Structs
// ============================================================
pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT = undefined,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR = undefined,
    hIconSm: HICON = null,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: WORD = 1,
    dwFlags: DWORD = 0,
    iPixelType: BYTE = 0,
    cColorBits: BYTE = 0,
    cRedBits: BYTE = 0,
    cRedShift: BYTE = 0,
    cGreenBits: BYTE = 0,
    cGreenShift: BYTE = 0,
    cBlueBits: BYTE = 0,
    cBlueShift: BYTE = 0,
    cAlphaBits: BYTE = 0,
    cAlphaShift: BYTE = 0,
    cAccumBits: BYTE = 0,
    cAccumRedBits: BYTE = 0,
    cAccumGreenBits: BYTE = 0,
    cAccumBlueBits: BYTE = 0,
    cAccumAlphaBits: BYTE = 0,
    cDepthBits: BYTE = 0,
    cStencilBits: BYTE = 0,
    cAuxBuffers: BYTE = 0,
    iLayerType: BYTE = 0,
    bReserved: BYTE = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

pub const POINT = extern struct { x: i32 = 0, y: i32 = 0 };

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

// ============================================================
// Extern functions
// ============================================================
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) u16;
pub extern "user32" fn CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, i32, i32, i32, i32, ?HWND, HMENU, ?HINSTANCE, ?*anyopaque) callconv(.c) ?HWND;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(.c) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.c) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.c) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.c) LRESULT;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(.c) void;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.c) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, LPCWSTR) callconv(.c) HCURSOR;
pub extern "user32" fn GetDC(?HWND) callconv(.c) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.c) i32;
pub extern "user32" fn GetKeyState(i32) callconv(.c) i16;
pub extern "user32" fn IsZoomed(HWND) callconv(.c) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.c) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.c) BOOL;
pub extern "user32" fn SetWindowPos(?HWND, ?HWND, i32, i32, i32, i32, u32) callconv(.c) BOOL;
pub extern "user32" fn GetSystemMetrics(i32) callconv(.c) i32;
pub const HMONITOR = *opaque {};
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.c) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(?HMONITOR, *MONITORINFO) callconv(.c) BOOL;

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT = .{},
    ptMaxSize: POINT = .{},
    ptMaxPosition: POINT = .{},
    ptMinTrackSize: POINT = .{},
    ptMaxTrackSize: POINT = .{},
};

pub const SWP_FRAMECHANGED: u32 = 0x0020;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;
pub const SM_CXFRAME: i32 = 32;
pub const SM_CYFRAME: i32 = 33;
pub const SM_CXPADDEDBORDER: i32 = 92;

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*anyopaque,
};

pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.c) i32;
pub extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.c) BOOL;
pub extern "gdi32" fn SwapBuffers(HDC) callconv(.c) BOOL;

pub extern "opengl32" fn wglCreateContext(HDC) callconv(.c) ?HGLRC;
pub extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.c) BOOL;
pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.c) BOOL;

pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.c) ?HINSTANCE;
pub extern "kernel32" fn QueryPerformanceCounter(*LARGE_INTEGER) callconv(.c) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(*LARGE_INTEGER) callconv(.c) BOOL;
pub extern "kernel32" fn Sleep(DWORD) callconv(.c) void;

pub const LARGE_INTEGER = extern struct {
    QuadPart: i64 = 0,
};

// File I/O
pub const HANDLE = *opaque {};
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const OPEN_EXISTING: DWORD = 3;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub extern "kernel32" fn CreateFileW(LPCWSTR, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(.c) HANDLE;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, *DWORD, ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn SetFilePointer(HANDLE, i32, ?*i32, DWORD) callconv(.c) DWORD;
pub const FILE_END: DWORD = 2;
pub const FILE_BEGIN: DWORD = 0;
pub extern "kernel32" fn GetFileSizeEx(HANDLE, *i64) callconv(.c) BOOL;
pub extern "kernel32" fn SetEndOfFile(HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn CreateDirectoryW(LPCWSTR, ?*anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn DeleteFileW(LPCWSTR) callconv(.c) BOOL;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.c) BOOL;

// GDI font/bitmap functions
pub const HFONT = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HBITMAP = *opaque {};
pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: WORD = 1,
    biBitCount: WORD = 0,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};
pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]DWORD = .{0},
};
pub const TEXTMETRICW = extern struct {
    tmHeight: i32 = 0,
    tmAscent: i32 = 0,
    tmDescent: i32 = 0,
    tmInternalLeading: i32 = 0,
    tmExternalLeading: i32 = 0,
    tmAveCharWidth: i32 = 0,
    tmMaxCharWidth: i32 = 0,
    tmWeight: i32 = 0,
    tmOverhang: i32 = 0,
    tmDigitizedAspectX: i32 = 0,
    tmDigitizedAspectY: i32 = 0,
    tmFirstChar: u16 = 0,
    tmLastChar: u16 = 0,
    tmDefaultChar: u16 = 0,
    tmBreakChar: u16 = 0,
    tmItalic: BYTE = 0,
    tmUnderlined: BYTE = 0,
    tmStruckOut: BYTE = 0,
    tmPitchAndFamily: BYTE = 0,
    tmCharSet: BYTE = 0,
};
pub const SIZE = extern struct { cx: i32 = 0, cy: i32 = 0 };
pub const ABC = extern struct { abcA: i32 = 0, abcB: u32 = 0, abcC: i32 = 0 };

pub const FW_NORMAL: i32 = 400;
pub const ANTIALIASED_QUALITY: DWORD = 4;
pub const CLEARTYPE_QUALITY: DWORD = 5;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const OUT_TT_PRECIS: DWORD = 4;
pub const CLIP_DEFAULT_PRECIS: DWORD = 0;
pub const TRANSPARENT: i32 = 1;
pub const DIB_RGB_COLORS: u32 = 0;
pub const BI_RGB: DWORD = 0;

pub extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, ?LPCWSTR) callconv(.c) ?HFONT;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.c) ?HDC;
pub extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFO, u32, *?*anyopaque, ?*anyopaque, DWORD) callconv(.c) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.c) ?HGDIOBJ;
pub extern "gdi32" fn SetTextColor(HDC, DWORD) callconv(.c) DWORD;
pub extern "gdi32" fn SetBkMode(HDC, i32) callconv(.c) i32;
pub extern "gdi32" fn GetTextMetricsW(HDC, *TEXTMETRICW) callconv(.c) BOOL;
pub extern "gdi32" fn GetCharABCWidthsW(HDC, u32, u32, [*]ABC) callconv(.c) BOOL;
pub extern "gdi32" fn TextOutW(HDC, i32, i32, [*]const u16, i32) callconv(.c) BOOL;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.c) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.c) BOOL;
pub extern "gdi32" fn GetTextExtentPoint32W(HDC, [*]const u16, i32, *SIZE) callconv(.c) BOOL;

// ============================================================
// Shell / Tray icon
// ============================================================
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const LWA_ALPHA: DWORD = 0x00000002;

pub const WM_APP: u32 = 0x8000;
pub const WM_TRAYICON: u32 = WM_APP + 1;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_RBUTTONUP: u32 = 0x0205;

pub const NIM_ADD: DWORD = 0x00000000;
pub const NIM_MODIFY: DWORD = 0x00000001;
pub const NIM_DELETE: DWORD = 0x00000002;

pub const NIF_MESSAGE: u32 = 0x00000001;
pub const NIF_ICON: u32 = 0x00000002;
pub const NIF_TIP: u32 = 0x00000004;

pub const WM_LBUTTONDBLCLK: u32 = 0x0203;

pub const SW_HIDE: i32 = 0;
pub const SW_MINIMIZE: i32 = 6;

pub const IMAGE_ICON: u32 = 1;
pub const LR_DEFAULTCOLOR: u32 = 0x00000000;
pub const LR_SHARED: u32 = 0x00008000;

// Popup menu constants
pub const MF_STRING: u32 = 0x00000000;
pub const MF_SEPARATOR: u32 = 0x00000800;
pub const TPM_RIGHTBUTTON: u32 = 0x0002;
pub const TPM_BOTTOMALIGN: u32 = 0x0020;

// Tray menu command IDs
pub const IDM_SHOW: u32 = 1001;
pub const IDM_CLOSE: u32 = 1002;

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: HICON = null,
    szTip: [128]u16 = [_]u16{0} ** 128,
};

pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(.c) BOOL;
pub extern "user32" fn LoadImageW(?HINSTANCE, LPCWSTR, u32, i32, i32, u32) callconv(.c) ?*opaque {};
pub extern "user32" fn IsWindowVisible(HWND) callconv(.c) BOOL;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.c) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, DWORD, BYTE, DWORD) callconv(.c) BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(.c) HMENU;
pub extern "user32" fn AppendMenuW(HMENU, u32, usize, ?LPCWSTR) callconv(.c) BOOL;
pub extern "user32" fn TrackPopupMenu(HMENU, u32, i32, i32, i32, HWND, ?*const RECT) callconv(.c) BOOL;
pub extern "user32" fn DestroyMenu(HMENU) callconv(.c) BOOL;
pub extern "user32" fn CreateIconFromResourceEx([*]const u8, DWORD, BOOL, DWORD, i32, i32, u32) callconv(.c) HICON;
pub extern "user32" fn DestroyIcon(HICON) callconv(.c) BOOL;
pub extern "user32" fn DrawIconEx(?HDC, i32, i32, HICON, i32, i32, u32, HBRUSH, u32) callconv(.c) BOOL;
pub const DI_NORMAL: u32 = 0x0003;
pub const LR_DEFAULTSIZE: u32 = 0x00000040;

// LookupIconIdFromDirectoryEx — finds the best icon in a .ico resource
pub extern "user32" fn LookupIconIdFromDirectoryEx([*]const u8, BOOL, i32, i32, u32) callconv(.c) i32;

// ============================================================
// Threading
// ============================================================
pub const THREAD_HANDLE = ?*opaque {};
pub extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.c) DWORD, ?*anyopaque, DWORD, ?*DWORD) callconv(.c) THREAD_HANDLE;
pub extern "kernel32" fn WaitForSingleObject(THREAD_HANDLE, DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(DWORD, [*]const THREAD_HANDLE, BOOL, DWORD) callconv(.c) DWORD;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: u16 = 0,
    wReserved: u16 = 0,
    dwPageSize: DWORD = 0,
    lpMinimumApplicationAddress: ?*anyopaque = null,
    lpMaximumApplicationAddress: ?*anyopaque = null,
    dwActiveProcessorMask: usize = 0,
    dwNumberOfProcessors: DWORD = 0,
    dwProcessorType: DWORD = 0,
    dwAllocationGranularity: DWORD = 0,
    wProcessorLevel: u16 = 0,
    wProcessorRevision: u16 = 0,
};
pub extern "kernel32" fn GetSystemInfo(*SYSTEM_INFO) callconv(.c) void;

// ============================================================
// WinHTTP — WebSocket support
// ============================================================
pub const HINTERNET = ?*opaque {};

pub const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: DWORD = 4;
pub const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
pub const WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET: DWORD = 114;

// WebSocket buffer types
pub const WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE: DWORD = 0;
pub const WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE: DWORD = 1;
pub const WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE: DWORD = 2;
pub const WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE: DWORD = 3;
pub const WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE: DWORD = 4;

pub extern "winhttp" fn WinHttpOpen(?LPCWSTR, DWORD, ?LPCWSTR, ?LPCWSTR, DWORD) callconv(.c) HINTERNET;
pub extern "winhttp" fn WinHttpConnect(HINTERNET, LPCWSTR, u16, DWORD) callconv(.c) HINTERNET;
pub extern "winhttp" fn WinHttpOpenRequest(HINTERNET, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?LPCWSTR, ?*?LPCWSTR, DWORD) callconv(.c) HINTERNET;
pub extern "winhttp" fn WinHttpSetOption(HINTERNET, DWORD, ?*const anyopaque, DWORD) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpSetTimeouts(HINTERNET, c_int, c_int, c_int, c_int) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpSendRequest(HINTERNET, ?LPCWSTR, DWORD, ?*anyopaque, DWORD, DWORD, usize) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpReceiveResponse(HINTERNET, ?*anyopaque) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpWebSocketCompleteUpgrade(HINTERNET, usize) callconv(.c) HINTERNET;
pub extern "winhttp" fn WinHttpWebSocketReceive(HINTERNET, [*]u8, DWORD, *DWORD, *DWORD) callconv(.c) DWORD;
pub extern "winhttp" fn WinHttpWebSocketSend(HINTERNET, DWORD, ?[*]const u8, DWORD) callconv(.c) DWORD;
pub extern "winhttp" fn WinHttpWebSocketClose(HINTERNET, u16, ?[*]const u8, DWORD) callconv(.c) DWORD;
pub extern "winhttp" fn WinHttpCloseHandle(HINTERNET) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpReadData(HINTERNET, [*]u8, DWORD, *DWORD) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpQueryDataAvailable(HINTERNET, *DWORD) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpAddRequestHeaders(HINTERNET, LPCWSTR, DWORD, DWORD) callconv(.c) BOOL;
pub extern "winhttp" fn WinHttpQueryHeaders(HINTERNET, DWORD, ?LPCWSTR, ?*anyopaque, *DWORD, ?*DWORD) callconv(.c) BOOL;

pub const WINHTTP_ADDREQ_FLAG_ADD: DWORD = 0x20000000;
pub const WINHTTP_QUERY_STATUS_CODE: DWORD = 19;
pub const WINHTTP_QUERY_FLAG_NUMBER: DWORD = 0x20000000;

// ============================================================
// Debug
// ============================================================
pub extern "kernel32" fn OutputDebugStringA(?[*:0]const u8) callconv(.c) void;
pub extern "kernel32" fn GetLastError() callconv(.c) DWORD;
pub extern "kernel32" fn GetCommandLineW() callconv(.c) LPCWSTR;

// ============================================================
// Helpers
// ============================================================
pub fn L(comptime s: []const u8) LPCWSTR {
    const w = comptime blk: {
        var buf: [s.len:0]u16 = .{0} ** s.len;
        for (s, 0..) |c, i| {
            buf[i] = c;
        }
        break :blk buf;
    };
    return &w;
}

// ============================================================
// BCrypt — HMAC-SHA256 for API request signing
// ============================================================
pub const BCRYPT_ALG_HANDLE = ?*opaque {};
pub const BCRYPT_HASH_HANDLE = ?*opaque {};
pub const NTSTATUS = i32;

pub const BCRYPT_HMAC_SHA256_ALG: LPCWSTR = L("SHA256");
pub const BCRYPT_ALG_HANDLE_HMAC_FLAG: u32 = 0x00000008;

pub extern "bcrypt" fn BCryptOpenAlgorithmProvider(*BCRYPT_ALG_HANDLE, LPCWSTR, ?LPCWSTR, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptCreateHash(BCRYPT_ALG_HANDLE, *BCRYPT_HASH_HANDLE, ?[*]u8, u32, ?[*]const u8, u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptHashData(BCRYPT_HASH_HANDLE, [*]const u8, u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptFinishHash(BCRYPT_HASH_HANDLE, [*]u8, u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptDestroyHash(BCRYPT_HASH_HANDLE) callconv(.c) NTSTATUS;

// ============================================================
// BCrypt — AES-GCM AEAD + key generation (QUIC transport)
// ============================================================
pub const BCRYPT_KEY_HANDLE = ?*opaque {};
pub const BCRYPT_AES_ALGORITHM: LPCWSTR = L("AES");
pub const BCRYPT_CHAIN_MODE_GCM: LPCWSTR = L("ChainingModeGCM");
pub const BCRYPT_CHAINING_MODE: LPCWSTR = L("ChainingMode");
pub const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 2;
pub const BCRYPT_INIT_AUTH_MODE_INFO_VERSION: u32 = 1;

pub const BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = extern struct {
    cbSize: u32 = @sizeOf(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO),
    dwInfoVersion: u32 = BCRYPT_INIT_AUTH_MODE_INFO_VERSION,
    pbNonce: ?[*]u8 = null,
    cbNonce: u32 = 0,
    pbAuthData: ?[*]const u8 = null,
    cbAuthData: u32 = 0,
    pbTag: ?[*]u8 = null,
    cbTag: u32 = 0,
    pbMacContext: ?[*]u8 = null,
    cbMacContext: u32 = 0,
    cbAAD: u32 = 0,
    cbData: u64 = 0,
    dwFlags: u32 = 0,
};

pub extern "bcrypt" fn BCryptGenerateSymmetricKey(BCRYPT_ALG_HANDLE, *BCRYPT_KEY_HANDLE, ?[*]u8, u32, [*]const u8, u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptEncrypt(BCRYPT_KEY_HANDLE, [*]const u8, u32, ?*BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO, ?[*]u8, u32, [*]u8, u32, *u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptDecrypt(BCRYPT_KEY_HANDLE, [*]const u8, u32, ?*BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO, ?[*]u8, u32, [*]u8, u32, *u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptDestroyKey(BCRYPT_KEY_HANDLE) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptSetProperty(BCRYPT_ALG_HANDLE, LPCWSTR, [*]const u8, u32, u32) callconv(.c) NTSTATUS;
pub extern "bcrypt" fn BCryptGenRandom(BCRYPT_ALG_HANDLE, [*]u8, u32, u32) callconv(.c) NTSTATUS;

// ============================================================
// System time — for API request timestamps
// ============================================================
pub const FILETIME = extern struct {
    dwLowDateTime: DWORD = 0,
    dwHighDateTime: DWORD = 0,
};

pub extern "kernel32" fn GetSystemTimeAsFileTime(*FILETIME) callconv(.c) void;

// ============================================================
// Winsock2 — TCP server for MCP
// ============================================================
pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
pub const SOCKET_ERROR: c_int = -1;

pub const AF_INET: c_int = 2;
pub const SOCK_STREAM: c_int = 1;
pub const IPPROTO_TCP: c_int = 6;
pub const SOL_SOCKET: c_int = 0xFFFF;
pub const SO_REUSEADDR: c_int = 0x0004;
pub const FIONBIO: c_long = @bitCast(@as(c_ulong, 0x8004667E));
pub const SD_BOTH: c_int = 2;

pub const WSADATA = extern struct {
    wVersion: u16 = 0,
    wHighVersion: u16 = 0,
    iMaxSockets: u16 = 0,
    iMaxUdpDg: u16 = 0,
    lpVendorInfo: ?[*]u8 = null,
    szDescription: [257]u8 = [_]u8{0} ** 257,
    szSystemStatus: [129]u8 = [_]u8{0} ** 129,
};

pub const sockaddr_in = extern struct {
    sin_family: i16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

pub const fd_set = extern struct {
    fd_count: u32 = 0,
    fd_array: [64]SOCKET = [_]SOCKET{0} ** 64,
};

pub const timeval = extern struct {
    tv_sec: c_long = 0,
    tv_usec: c_long = 0,
};

pub extern "ws2_32" fn WSAStartup(u16, *WSADATA) callconv(.c) c_int;
pub extern "ws2_32" fn WSACleanup() callconv(.c) c_int;
pub extern "ws2_32" fn socket(c_int, c_int, c_int) callconv(.c) SOCKET;
pub extern "ws2_32" fn bind(SOCKET, *const sockaddr_in, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn listen(SOCKET, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn accept(SOCKET, ?*sockaddr_in, ?*c_int) callconv(.c) SOCKET;
pub extern "ws2_32" fn recv(SOCKET, [*]u8, c_int, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn send(SOCKET, [*]const u8, c_int, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn closesocket(SOCKET) callconv(.c) c_int;
pub extern "ws2_32" fn shutdown(SOCKET, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn setsockopt(SOCKET, c_int, c_int, *const anyopaque, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn ioctlsocket(SOCKET, c_long, *c_ulong) callconv(.c) c_int;
pub extern "ws2_32" fn select(c_int, ?*fd_set, ?*fd_set, ?*fd_set, ?*const timeval) callconv(.c) c_int;
pub extern "ws2_32" fn WSAGetLastError() callconv(.c) c_int;

// UDP-specific constants and externs (QUIC transport)
pub const SOCK_DGRAM: c_int = 2;
pub const IPPROTO_UDP: c_int = 17;
pub const WSAEWOULDBLOCK: c_int = 10035;
pub const WSAECONNRESET: c_int = 10054;

pub extern "ws2_32" fn sendto(SOCKET, [*]const u8, c_int, c_int, *const sockaddr_in, c_int) callconv(.c) c_int;
pub extern "ws2_32" fn recvfrom(SOCKET, [*]u8, c_int, c_int, *sockaddr_in, *c_int) callconv(.c) c_int;
pub extern "ws2_32" fn htons(u16) callconv(.c) u16;
pub extern "ws2_32" fn ntohs(u16) callconv(.c) u16;
pub extern "ws2_32" fn getsockname(SOCKET, *sockaddr_in, *c_int) callconv(.c) c_int;

// ============================================================
// SChannel — TLS 1.3 handshake (QUIC transport)
// ============================================================
pub const CredHandle = extern struct { lower: usize = 0, upper: usize = 0 };
pub const CtxtHandle = extern struct { lower: usize = 0, upper: usize = 0 };

pub const SecBuffer = extern struct {
    cbBuffer: u32 = 0,
    BufferType: u32 = 0,
    pvBuffer: ?*anyopaque = null,
};

pub const SecBufferDesc = extern struct {
    ulVersion: u32 = 0,
    cBuffers: u32 = 0,
    pBuffers: ?*SecBuffer = null,
};

pub const SCHANNEL_CRED = extern struct {
    dwVersion: DWORD = 4, // SCHANNEL_CRED_VERSION
    cCreds: DWORD = 0,
    paCred: ?*anyopaque = null,
    hRootStore: ?*anyopaque = null,
    cMappers: DWORD = 0,
    aphMappers: ?*anyopaque = null,
    cSupportedAlgs: DWORD = 0,
    palgSupportedAlgs: ?*anyopaque = null,
    grbitEnabledProtocols: DWORD = 0,
    dwMinimumCipherStrength: DWORD = 0,
    dwMaximumCipherStrength: DWORD = 0,
    dwSessionLifespan: DWORD = 0,
    dwFlags: DWORD = 0,
    dwCredFormat: DWORD = 0,
};

pub const SCH_CREDENTIALS = extern struct {
    dwVersion: DWORD = 5, // SCH_CREDENTIALS_VERSION
    dwCredFormat: DWORD = 0,
    cTlsParameters: DWORD = 0,
    pTlsParameters: ?*TLS_PARAMETERS = null,
    cMappers: DWORD = 0,
    aphMappers: ?*anyopaque = null,
    dwSessionLifespan: DWORD = 0,
    dwFlags: DWORD = 0,
};

pub const TLS_PARAMETERS = extern struct {
    cAlpnIds: DWORD = 0,
    rgstrAlpnIds: ?*anyopaque = null,
    grbitDisabledProtocols: DWORD = 0,
    cDisabledCrypto: DWORD = 0,
    pDisabledCrypto: ?*anyopaque = null,
    dwFlags: DWORD = 0,
};

pub const SEC_APPLICATION_PROTOCOL_LIST = extern struct {
    ProtoNegoExt: u32 = 0, // SecApplicationProtocolNegotiationExt
    ProtocolListSize: u16 = 0,
    ProtocolList: [256]u8 = [_]u8{0} ** 256,
};

pub const SEC_APPLICATION_PROTOCOLS = extern struct {
    ProtocolListsSize: u32 = 0,
    ProtocolLists: SEC_APPLICATION_PROTOCOL_LIST = .{},
};

pub const SecApplicationProtocolNegotiationExt_ALPN: u32 = 2;

// SChannel constants
pub const UNISP_NAME_W: LPCWSTR = L("Microsoft Unified Security Protocol Provider");
pub const SECPKG_CRED_OUTBOUND: DWORD = 0x00000002;
pub const SECPKG_CRED_INBOUND: DWORD = 0x00000001;

// InitializeSecurityContext flags
pub const ISC_REQ_SEQUENCE_DETECT: DWORD = 0x00000008;
pub const ISC_REQ_REPLAY_DETECT: DWORD = 0x00000004;
pub const ISC_REQ_CONFIDENTIALITY: DWORD = 0x00000010;
pub const ISC_REQ_ALLOCATE_MEMORY: DWORD = 0x00000100;
pub const ISC_REQ_STREAM: DWORD = 0x00008000;
pub const ISC_REQ_USE_SUPPLIED_CREDS: DWORD = 0x00000080;
pub const ISC_REQ_MANUAL_CRED_VALIDATION: DWORD = 0x00080000;

// AcceptSecurityContext flags
pub const ASC_REQ_SEQUENCE_DETECT: DWORD = 0x00000008;
pub const ASC_REQ_REPLAY_DETECT: DWORD = 0x00000004;
pub const ASC_REQ_CONFIDENTIALITY: DWORD = 0x00000010;
pub const ASC_REQ_ALLOCATE_MEMORY: DWORD = 0x00000100;
pub const ASC_REQ_STREAM: DWORD = 0x00008000;

// SecBuffer types
pub const SECBUFFER_TOKEN: u32 = 2;
pub const SECBUFFER_EMPTY: u32 = 0;
pub const SECBUFFER_EXTRA: u32 = 5;
pub const SECBUFFER_ALERT: u32 = 17;
pub const SECBUFFER_APPLICATION_PROTOCOLS: u32 = 18;
pub const SECBUFFER_VERSION: u32 = 0;

// Security status codes
pub const SEC_E_OK: i32 = 0;
pub const SEC_I_CONTINUE_NEEDED: i32 = 0x00090312;
pub const SEC_E_INCOMPLETE_MESSAGE: i32 = @bitCast(@as(u32, 0x80090318));
pub const SEC_I_COMPLETE_AND_CONTINUE: i32 = 0x00090313;
pub const SEC_I_COMPLETE_NEEDED: i32 = 0x00090314;

// Query context attribute IDs
pub const SECPKG_ATTR_CONNECTION_INFO: DWORD = 0x5A;
pub const SECPKG_ATTR_APPLICATION_PROTOCOL: DWORD = 0x2E;

// Application protocol negotiation status
pub const SecApplicationProtocolNegotiationStatus_Success: u32 = 1;

pub const SecPkgContext_ApplicationProtocol = extern struct {
    ProtoNegoStatus: u32 = 0,
    ProtoNegoExt: u32 = 0,
    ProtocolIdSize: u8 = 0,
    ProtocolId: [255]u8 = [_]u8{0} ** 255,
};

// SChannel extern functions
pub extern "secur32" fn AcquireCredentialsHandleW(?LPCWSTR, LPCWSTR, DWORD, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, *CredHandle, ?*i64) callconv(.c) i32;
pub extern "secur32" fn InitializeSecurityContextW(*CredHandle, ?*CtxtHandle, ?LPCWSTR, DWORD, DWORD, DWORD, ?*SecBufferDesc, DWORD, ?*CtxtHandle, ?*SecBufferDesc, *DWORD, ?*i64) callconv(.c) i32;
pub extern "secur32" fn AcceptSecurityContext(*CredHandle, ?*CtxtHandle, ?*SecBufferDesc, DWORD, DWORD, ?*CtxtHandle, ?*SecBufferDesc, *DWORD, ?*i64) callconv(.c) i32;
pub extern "secur32" fn CompleteAuthToken(?*CtxtHandle, ?*SecBufferDesc) callconv(.c) i32;
pub extern "secur32" fn DeleteSecurityContext(*CtxtHandle) callconv(.c) i32;
pub extern "secur32" fn FreeCredentialsHandle(*CredHandle) callconv(.c) i32;
pub extern "secur32" fn QueryContextAttributesW(*CtxtHandle, DWORD, ?*anyopaque) callconv(.c) i32;
pub extern "secur32" fn FreeContextBuffer(?*anyopaque) callconv(.c) i32;

// SCH_CREDENTIALS flags
pub const SCH_CRED_NO_DEFAULT_CREDS: DWORD = 0x00000010;
pub const SCH_CRED_MANUAL_CRED_VALIDATION: DWORD = 0x00000008;
pub const SCH_CRED_AUTO_CRED_VALIDATION: DWORD = 0x00000020;
