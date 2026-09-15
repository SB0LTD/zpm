// Windows Graphics Capture (WGC) backend helper for screencap/windows.sig.
//
// Classic GDI capture (PrintWindow/BitBlt) cannot read GPU-composited windows —
// Electron/Chromium apps (VS Code, Kiro, Chrome, Discord) come back all-black
// or as a stale reflow. WGC is the supported Windows API that captures any
// window's true current framebuffer, including occluded and GPU-composited
// ones, at full resolution and without disturbing z-order.
//
// There are no WinRT/COM bindings for Sig, and the toolchain ships no import
// library for combase/d3d11, so every entry point is resolved at RUNTIME via
// LoadLibraryW + GetProcAddress (the same approach the macOS/x11 backends use),
// and every COM/WinRT interface is modeled as an extern struct of function
// pointers (a vtable) that we dispatch through explicitly.
//
// The public entry is `capture(hwnd, width, height, out) bool`: it captures the
// window into `out` as tightly-packed RGBA (width*height*4) and returns whether
// it succeeded. On any failure it returns false so the caller can fall back to
// the GDI path.

// ── Basic Win32 / COM types ──
const HWND = *opaque {};
const HRESULT = i32;
const ULONG = u32;
const HSTRING = ?*opaque {};
const HMODULE = *opaque {};

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };

const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const SizeInt32 = extern struct { width: i32, height: i32 };

// ── Runtime-loaded entry points ──
extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.c) ?HMODULE;
extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(.c) ?*anyopaque;
extern "kernel32" fn Sleep(u32) callconv(.c) void;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.c) i32;

const RO_INIT_MULTITHREADED: u32 = 1;

// Frame-arrival poll ceiling. Kept deliberately small so a window that never
// produces a frame can't hold a live WGC capture session open for long.
const FRAME_POLL_TRIES: u32 = 60;
const FRAME_POLL_MS: u32 = 8;

const PFN_RoInitialize = *const fn (u32) callconv(.c) HRESULT;
const PFN_WindowsCreateString = *const fn ([*]const u16, u32, *HSTRING) callconv(.c) HRESULT;
const PFN_WindowsDeleteString = *const fn (HSTRING) callconv(.c) HRESULT;
const PFN_RoGetActivationFactory = *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.c) HRESULT;
const PFN_D3D11CreateDevice = *const fn (?*anyopaque, u32, ?*anyopaque, u32, ?[*]const u32, u32, u32, *?*ID3D11Device, ?*u32, *?*ID3D11DeviceContext) callconv(.c) HRESULT;
const PFN_CreateDirect3D11DeviceFromDXGIDevice = *const fn (*IUnknown, *?*IInspectable) callconv(.c) HRESULT;

const Api = struct {
    RoInitialize: PFN_RoInitialize,
    WindowsCreateString: PFN_WindowsCreateString,
    WindowsDeleteString: PFN_WindowsDeleteString,
    RoGetActivationFactory: PFN_RoGetActivationFactory,
    D3D11CreateDevice: PFN_D3D11CreateDevice,
    CreateDirect3D11DeviceFromDXGIDevice: PFN_CreateDirect3D11DeviceFromDXGIDevice,
};

var g_api: ?Api = null;
var g_attempted: bool = false;
var g_ro_inited: bool = false;

// ── Cached GPU device (created once, reused across every capture) ──
//
// Creating a hardware D3D11 device is expensive and, when done on every frame
// in a watch loop (~2 captures/sec × N windows), churns the GPU driver and DWM
// hard enough to hang the graphics driver — which on Windows surfaces as a
// whole-system freeze + TDR reset. We create the device exactly once and reuse
// it. Only the cheap, per-window objects (capture item, frame pool, session,
// frame, staging texture) are created and torn down per call.
//
// `g_device_ready` gates use; on a device-lost failure we call releaseDevice()
// so the next capture rebuilds cleanly.
var g_device: ?*ID3D11Device = null;
var g_ctx: ?*ID3D11DeviceContext = null;
var g_dxgi_dev: ?*anyopaque = null;
var g_d3d_device: ?*IInspectable = null; // WinRT IDirect3DDevice
var g_device_ready: bool = false;

fn wstrz(comptime s: []const u8) [s.len:0]u16 {
    var arr: [s.len:0]u16 = undefined;
    for (s, 0..) |c, i| arr[i] = c;
    arr[s.len] = 0;
    return arr;
}

fn api() ?*const Api {
    if (g_attempted) return if (g_api) |*a| a else null;
    g_attempted = true;

    const combase_name = wstrz("combase.dll");
    const d3d11_name = wstrz("d3d11.dll");
    const combase = LoadLibraryW(&combase_name) orelse return null;
    const d3d11 = LoadLibraryW(&d3d11_name) orelse return null;

    // GetProcAddress returns *anyopaque (align 1); function pointers have a
    // larger alignment on some targets (e.g. aarch64-windows, align 4), so the
    // cast must @alignCast as well as @ptrCast.
    g_api = .{
        .RoInitialize = @ptrCast(@alignCast(GetProcAddress(combase, "RoInitialize") orelse return null)),
        .WindowsCreateString = @ptrCast(@alignCast(GetProcAddress(combase, "WindowsCreateString") orelse return null)),
        .WindowsDeleteString = @ptrCast(@alignCast(GetProcAddress(combase, "WindowsDeleteString") orelse return null)),
        .RoGetActivationFactory = @ptrCast(@alignCast(GetProcAddress(combase, "RoGetActivationFactory") orelse return null)),
        .D3D11CreateDevice = @ptrCast(@alignCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse return null)),
        .CreateDirect3D11DeviceFromDXGIDevice = @ptrCast(@alignCast(GetProcAddress(d3d11, "CreateDirect3D11DeviceFromDXGIDevice") orelse return null)),
    };
    return if (g_api) |*a| a else null;
}

// ── COM vtable scaffolding ──
const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) ULONG,
    Release: *const fn (*anyopaque) callconv(.c) ULONG,
};
const IUnknown = extern struct { vtbl: *const IUnknownVtbl };

fn release(obj: ?*anyopaque) void {
    if (obj) |o| {
        const u: *IUnknown = @ptrCast(@alignCast(o));
        _ = u.vtbl.Release(u);
    }
}

const IInspectable = extern struct { vtbl: *const anyopaque };

// IInspectable prelude (6 slots) shared by every WinRT interface below.
const Insp = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) ULONG,
    Release: *const fn (*anyopaque) callconv(.c) ULONG,
    GetIids: *const fn () callconv(.c) HRESULT,
    GetRuntimeClassName: *const fn () callconv(.c) HRESULT,
    GetTrustLevel: *const fn () callconv(.c) HRESULT,
};

// IGraphicsCaptureItem: Insp + get_DisplayName, get_Size. get_Size returns the
// item's true framebuffer size in PHYSICAL pixels (DPI-scaled), which is what
// WGC actually captures — GetWindowRect gives logical pixels and would clip.
const IGraphicsCaptureItemVtbl = extern struct {
    base: Insp,
    get_DisplayName: *const fn () callconv(.c) HRESULT,
    get_Size: *const fn (*anyopaque, *SizeInt32) callconv(.c) HRESULT,
};
const IGraphicsCaptureItem = extern struct { vtbl: *const IGraphicsCaptureItemVtbl };

const IGraphicsCaptureItemInteropVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) ULONG,
    Release: *const fn (*anyopaque) callconv(.c) ULONG,
    CreateForWindow: *const fn (*anyopaque, HWND, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    CreateForMonitor: *const fn (*anyopaque, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
};
const IGraphicsCaptureItemInterop = extern struct { vtbl: *const IGraphicsCaptureItemInteropVtbl };

const IFramePoolStaticsVtbl = extern struct {
    base: Insp,
    Create: *const fn (*anyopaque, *IInspectable, i32, i32, SizeInt32, *?*anyopaque) callconv(.c) HRESULT,
};
const IFramePoolStatics = extern struct { vtbl: *const IFramePoolStaticsVtbl };

const IFramePoolVtbl = extern struct {
    base: Insp,
    Recreate: *const fn () callconv(.c) HRESULT,
    TryGetNextFrame: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    add_FrameArrived: *const fn () callconv(.c) HRESULT,
    remove_FrameArrived: *const fn () callconv(.c) HRESULT,
    CreateCaptureSession: *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(.c) HRESULT,
};
const IFramePool = extern struct { vtbl: *const IFramePoolVtbl };

const ISessionVtbl = extern struct {
    base: Insp,
    StartCapture: *const fn (*anyopaque) callconv(.c) HRESULT,
};
const ISession = extern struct { vtbl: *const ISessionVtbl };

const IFrameVtbl = extern struct {
    base: Insp,
    get_Surface: *const fn (*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
    get_SystemRelativeTime: *const fn () callconv(.c) HRESULT,
    get_ContentSize: *const fn (*anyopaque, *SizeInt32) callconv(.c) HRESULT,
};
const IFrame = extern struct { vtbl: *const IFrameVtbl };

const IClosableVtbl = extern struct {
    base: Insp,
    Close: *const fn (*anyopaque) callconv(.c) HRESULT,
};
const IClosable = extern struct { vtbl: *const IClosableVtbl };

const IDirect3DDxgiInterfaceAccessVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) ULONG,
    Release: *const fn (*anyopaque) callconv(.c) ULONG,
    GetInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
};
const IDirect3DDxgiInterfaceAccess = extern struct { vtbl: *const IDirect3DDxgiInterfaceAccessVtbl };

// ── D3D11 ──
const ID3D11DeviceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) ULONG,
    Release: *const fn (*anyopaque) callconv(.c) ULONG,
    CreateBuffer: *const fn () callconv(.c) HRESULT,
    CreateTexture1D: *const fn () callconv(.c) HRESULT,
    CreateTexture2D: *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*anyopaque, *?*ID3D11Texture2D) callconv(.c) HRESULT,
};
const ID3D11Device = extern struct { vtbl: *const ID3D11DeviceVtbl };

// The device context vtbl is large; model it as a padded fn-ptr array and index
// the two methods we use (Map=14, Unmap=15, CopyResource=47).
const AnyFn = *const fn () callconv(.c) void;
const ID3D11DeviceContextVtbl = extern struct { methods: [48]AnyFn };
const ID3D11DeviceContext = extern struct { vtbl: *const ID3D11DeviceContextVtbl };

const PFN_Map = *const fn (*anyopaque, *anyopaque, u32, u32, u32, *D3D11_MAPPED_SUBRESOURCE) callconv(.c) HRESULT;
const PFN_Unmap = *const fn (*anyopaque, *anyopaque, u32) callconv(.c) void;
const PFN_CopyResource = *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void;
const CTX_MAP_INDEX = 14;
const CTX_UNMAP_INDEX = 15;
const CTX_COPYRESOURCE_INDEX = 47;

const ID3D11Texture2D = extern struct { vtbl: *const anyopaque };

const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: u32,
    SampleDesc_Count: u32,
    SampleDesc_Quality: u32,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};
const D3D11_MAPPED_SUBRESOURCE = extern struct { pData: ?[*]u8 = null, RowPitch: u32 = 0, DepthPitch: u32 = 0 };

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D11_SDK_VERSION: u32 = 7;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_USAGE_STAGING: u32 = 3;
const D3D11_CPU_ACCESS_READ: u32 = 0x20000;
const D3D11_MAP_READ: u32 = 1;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

// ── IIDs / runtime class names ──
const IID_IGraphicsCaptureItemInterop = GUID{ .data1 = 0x3628E81B, .data2 = 0x3CAC, .data3 = 0x4C60, .data4 = .{ 0xB7, 0xF4, 0x23, 0xCE, 0x0E, 0x0C, 0x33, 0x56 } };
const IID_IGraphicsCaptureItem = GUID{ .data1 = 0x79C3F95B, .data2 = 0x31F7, .data3 = 0x4EC2, .data4 = .{ 0xA4, 0x64, 0x63, 0x2E, 0xF5, 0xD3, 0x07, 0x60 } };
const IID_IFramePoolStatics = GUID{ .data1 = 0x7784056A, .data2 = 0x67AA, .data3 = 0x4D53, .data4 = .{ 0xAE, 0x54, 0x10, 0x88, 0xD5, 0xA8, 0xCA, 0x21 } };
const IID_IDirect3DDxgiInterfaceAccess = GUID{ .data1 = 0xA9B3D012, .data2 = 0x3DF2, .data3 = 0x4EE3, .data4 = .{ 0xB8, 0xD1, 0x86, 0x95, 0xF4, 0x57, 0xD3, 0xC1 } };
const IID_ID3D11Texture2D = GUID{ .data1 = 0x6F15AAF2, .data2 = 0xD208, .data3 = 0x4E89, .data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C } };
const IID_IClosable = GUID{ .data1 = 0x30D5A829, .data2 = 0x7FA4, .data3 = 0x4026, .data4 = .{ 0x83, 0xBB, 0xD7, 0x5B, 0xAE, 0x4E, 0xA9, 0x9E } };
const IID_IDXGIDevice = GUID{ .data1 = 0x54EC77FA, .data2 = 0x1377, .data3 = 0x44E6, .data4 = .{ 0x8C, 0x32, 0x88, 0xFD, 0x5F, 0x44, 0xC8, 0x4C } };

const RUNTIMECLASS_GraphicsCaptureItem = "Windows.Graphics.Capture.GraphicsCaptureItem";
const RUNTIMECLASS_Direct3D11CaptureFramePool = "Windows.Graphics.Capture.Direct3D11CaptureFramePool";

fn makeHString(a: *const Api, comptime s: []const u8) HSTRING {
    const u16s = comptime blk: {
        var arr: [s.len]u16 = undefined;
        for (s, 0..) |c, i| arr[i] = c;
        break :blk arr;
    };
    var hs: HSTRING = null;
    _ = a.WindowsCreateString(&u16s, s.len, &hs);
    return hs;
}

/// Close a capture session (via IClosable QI) to stop capture, then release the
/// session itself. Single entry point so close-before-release ordering is
/// guaranteed regardless of defer scheduling.
fn closeAndRelease(obj: ?*anyopaque) void {
    const o = obj orelse return;
    const u: *IUnknown = @ptrCast(@alignCast(o));
    var closable: ?*anyopaque = null;
    if (ok(u.vtbl.QueryInterface(u, &IID_IClosable, &closable))) {
        if (closable) |c_raw| {
            const c: *IClosable = @ptrCast(@alignCast(c_raw));
            _ = c.vtbl.Close(c);
            release(c_raw);
        }
    }
    release(o);
}

/// Release the cached D3D11 device and its derived WinRT/DXGI wrappers, in
/// reverse creation order. Called on device-lost so the next capture rebuilds.
/// Idempotent: safe to call when nothing is initialized.
fn releaseDevice() void {
    if (g_d3d_device) |d| {
        release(d);
        g_d3d_device = null;
    }
    if (g_dxgi_dev) |d| {
        release(d);
        g_dxgi_dev = null;
    }
    if (g_ctx) |c| {
        release(c);
        g_ctx = null;
    }
    if (g_device) |d| {
        release(d);
        g_device = null;
    }
    g_device_ready = false;
}

/// Create the D3D11 hardware device + immediate context ONCE and wrap it as a
/// WinRT IDirect3DDevice for the frame pool. Cached in file-scope statics and
/// reused by every capture. Returns false on failure (caller falls back to
/// GDI); leaves partial state cleaned up.
fn ensureDevice(a: *const Api) bool {
    if (g_device_ready) return true;

    var device: ?*ID3D11Device = null;
    var ctx: ?*ID3D11DeviceContext = null;
    if (!ok(a.D3D11CreateDevice(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &ctx)) or device == null or ctx == null) {
        release(device);
        release(ctx);
        return false;
    }

    const dev_unknown: *IUnknown = @ptrCast(@alignCast(device.?));
    var dxgi_dev: ?*anyopaque = null;
    if (!ok(dev_unknown.vtbl.QueryInterface(dev_unknown, &IID_IDXGIDevice, &dxgi_dev)) or dxgi_dev == null) {
        release(device);
        release(ctx);
        return false;
    }

    var d3d_device: ?*IInspectable = null;
    if (!ok(a.CreateDirect3D11DeviceFromDXGIDevice(@ptrCast(@alignCast(dxgi_dev.?)), &d3d_device)) or d3d_device == null) {
        release(dxgi_dev);
        release(device);
        release(ctx);
        return false;
    }

    g_device = device;
    g_ctx = ctx;
    g_dxgi_dev = dxgi_dev;
    g_d3d_device = d3d_device;
    g_device_ready = true;
    return true;
}

/// Result of a WGC capture: whether it succeeded and the ACTUAL pixel size
/// written into `out` (physical pixels — may exceed the logical window size on
/// DPI-scaled displays). The caller reports these dims and scales any detected
/// coordinates back to logical window space for clicking.
pub const CaptureResult = struct {
    ok: bool = false,
    width: u32 = 0,
    height: u32 = 0,
};

/// Capture `hwnd` into `out` as tightly-packed RGBA at the window's true
/// (physical) framebuffer size. `out` must be large enough for that physical
/// size (width*height*4). Returns the actual dimensions produced. On any
/// failure returns `.ok = false` so the caller falls back to GDI.
pub fn capture(hwnd_raw: usize, out: []u8) CaptureResult {
    const fail = CaptureResult{ .ok = false };

    const a = api() orelse return fail;
    const hwnd: HWND = @ptrFromInt(hwnd_raw);

    if (!g_ro_inited) {
        _ = a.RoInitialize(RO_INIT_MULTITHREADED);
        g_ro_inited = true; // benign if RPC_E_CHANGED_MODE; calls still work
    }

    // Create the GPU device ONCE and reuse it. This is the single most
    // important robustness fix: it stops per-frame D3D11 device creation from
    // hammering the graphics driver in watch mode.
    if (!ensureDevice(a)) return fail;

    // GraphicsCaptureItem for the window via the interop factory.
    const cls_item = makeHString(a, RUNTIMECLASS_GraphicsCaptureItem);
    defer _ = a.WindowsDeleteString(cls_item);
    var interop_raw: ?*anyopaque = null;
    if (!ok(a.RoGetActivationFactory(cls_item, &IID_IGraphicsCaptureItemInterop, &interop_raw)) or interop_raw == null) return fail;
    const interop: *IGraphicsCaptureItemInterop = @ptrCast(@alignCast(interop_raw.?));
    defer release(interop_raw);

    var item_raw: ?*anyopaque = null;
    if (!ok(interop.vtbl.CreateForWindow(interop, hwnd, &IID_IGraphicsCaptureItem, &item_raw)) or item_raw == null) return fail;
    defer release(item_raw);

    // The item's Size is the true framebuffer size in PHYSICAL pixels — use it
    // to size the frame pool/staging texture so nothing is clipped on
    // DPI-scaled displays (GetWindowRect's logical size would crop the window).
    const item: *IGraphicsCaptureItem = @ptrCast(@alignCast(item_raw.?));
    var item_size: SizeInt32 = .{ .width = 0, .height = 0 };
    if (!ok(item.vtbl.get_Size(item, &item_size)) or item_size.width <= 0 or item_size.height <= 0) return fail;
    const width: u32 = @intCast(item_size.width);
    const height: u32 = @intCast(item_size.height);
    const needed = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < needed) return fail;

    // Reuse the cached GPU device + WinRT wrapper (created once by ensureDevice).
    // These are NOT released per call — they live for the process lifetime.
    const device: *ID3D11Device = g_device.?;
    const d3d_device: *IInspectable = g_d3d_device.?;

    // Frame pool + session.
    const cls_pool = makeHString(a, RUNTIMECLASS_Direct3D11CaptureFramePool);
    defer _ = a.WindowsDeleteString(cls_pool);
    var fps_raw: ?*anyopaque = null;
    if (!ok(a.RoGetActivationFactory(cls_pool, &IID_IFramePoolStatics, &fps_raw)) or fps_raw == null) return fail;
    const fps: *IFramePoolStatics = @ptrCast(@alignCast(fps_raw.?));
    defer release(fps_raw);

    var pool_raw: ?*anyopaque = null;
    if (!ok(fps.vtbl.Create(fps, d3d_device, @bitCast(DXGI_FORMAT_B8G8R8A8_UNORM), 2, item_size, &pool_raw)) or pool_raw == null) return fail;
    const pool: *IFramePool = @ptrCast(@alignCast(pool_raw.?));
    defer release(pool_raw);

    var sess_raw: ?*anyopaque = null;
    if (!ok(pool.vtbl.CreateCaptureSession(pool, item_raw.?, &sess_raw)) or sess_raw == null) return fail;
    const sess: *ISession = @ptrCast(@alignCast(sess_raw.?));
    // Close the session (stops capture) THEN release. A single defer keeps the
    // order correct — two separate defers run LIFO, which would release first
    // and then Close a freed pointer (heap corruption).
    defer closeAndRelease(sess_raw);

    if (!ok(sess.vtbl.StartCapture(sess))) return fail;

    // Frames arrive asynchronously; poll briefly. With the cached device the
    // first frame is ready within a poll cycle or two, so keep the ceiling
    // tight: a stuck/occluded window must NOT hold a live capture session open
    // for seconds (that pins DWM/GPU work). Worst case here is
    // FRAME_POLL_TRIES * FRAME_POLL_MS = 480ms, then we bail to GDI fallback.
    var frame_raw: ?*anyopaque = null;
    var tries: u32 = 0;
    while (tries < FRAME_POLL_TRIES) : (tries += 1) {
        _ = pool.vtbl.TryGetNextFrame(pool, &frame_raw);
        if (frame_raw != null) break;
        Sleep(FRAME_POLL_MS);
    }
    if (frame_raw == null) return fail;
    const frame: *IFrame = @ptrCast(@alignCast(frame_raw.?));
    defer release(frame_raw);

    // Frame surface -> ID3D11Texture2D.
    var surface_raw: ?*anyopaque = null;
    if (!ok(frame.vtbl.get_Surface(frame, &surface_raw)) or surface_raw == null) return fail;
    defer release(surface_raw);
    const surf_unknown: *IUnknown = @ptrCast(@alignCast(surface_raw.?));
    var iface_access: ?*anyopaque = null;
    if (!ok(surf_unknown.vtbl.QueryInterface(surf_unknown, &IID_IDirect3DDxgiInterfaceAccess, &iface_access)) or iface_access == null) return fail;
    defer release(iface_access);
    const ifa: *IDirect3DDxgiInterfaceAccess = @ptrCast(@alignCast(iface_access.?));
    var tex_raw: ?*anyopaque = null;
    if (!ok(ifa.vtbl.GetInterface(ifa, &IID_ID3D11Texture2D, &tex_raw)) or tex_raw == null) return fail;
    defer release(tex_raw);

    // Staging texture (CPU-readable) + CopyResource. Uses the cached device.
    const dev: *ID3D11Device = device;
    var desc = D3D11_TEXTURE2D_DESC{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = DXGI_FORMAT_B8G8R8A8_UNORM,
        .SampleDesc_Count = 1,
        .SampleDesc_Quality = 0,
        .Usage = D3D11_USAGE_STAGING,
        .BindFlags = 0,
        .CPUAccessFlags = D3D11_CPU_ACCESS_READ,
        .MiscFlags = 0,
    };
    var staging: ?*ID3D11Texture2D = null;
    if (!ok(dev.vtbl.CreateTexture2D(dev, &desc, null, &staging)) or staging == null) {
        // Allocating from the device failed — most likely the device was lost
        // (driver reset, GPU removed). Drop the cached device so the next
        // capture rebuilds it instead of failing forever.
        releaseDevice();
        return fail;
    }
    defer release(staging);

    const ctxp: *ID3D11DeviceContext = g_ctx.?;
    const copyResource: PFN_CopyResource = @ptrCast(ctxp.vtbl.methods[CTX_COPYRESOURCE_INDEX]);
    copyResource(ctxp, @ptrCast(staging.?), @ptrCast(tex_raw.?));

    const mapFn: PFN_Map = @ptrCast(ctxp.vtbl.methods[CTX_MAP_INDEX]);
    const unmapFn: PFN_Unmap = @ptrCast(ctxp.vtbl.methods[CTX_UNMAP_INDEX]);
    var mapped: D3D11_MAPPED_SUBRESOURCE = .{};
    if (!ok(mapFn(ctxp, @ptrCast(staging.?), 0, D3D11_MAP_READ, 0, &mapped)) or mapped.pData == null) {
        releaseDevice(); // map failure also indicates a lost device
        return fail;
    }

    // Copy BGRA rows (honoring RowPitch) into tightly-packed RGBA `out`.
    const src = mapped.pData.?;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const srow = y * mapped.RowPitch;
        const drow = y * width * 4;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const s = srow + x * 4;
            const d = drow + x * 4;
            out[d] = src[s + 2]; // R <- B
            out[d + 1] = src[s + 1]; // G
            out[d + 2] = src[s]; // B <- R
            out[d + 3] = 255;
        }
    }
    unmapFn(ctxp, @ptrCast(staging.?), 0);

    return .{ .ok = true, .width = width, .height = height };
}
