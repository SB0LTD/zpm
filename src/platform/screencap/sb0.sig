// screencap SB0 backend — Nexus compositor client (userspace on SB0S/SB0X).
// Selected at comptime by screencap.sig for `-target aarch64-sb0`.
//
// STATUS: compiles and links for SB0 userspace, but reports "no display" at
// runtime today. This is deliberate and honest — the current SB0 userspace ABI
// (src/abi/sb0_v0.sig in the Nexus repo) does NOT expose the operations a
// screen-capture tool needs:
//
//   • Window/surface ENUMERATION — none. The display device has no "list
//     surfaces with geometry/title" query; DeviceIoOp.query only returns the
//     single whole-screen DisplayMode + FrameStatistics.
//   • Pixel CAPTURE / read-back — none. The surface is WRITE-ONLY: a userspace
//     app acquires one staging surface (DeviceIoOp.acquire_surface) and blits
//     into the scanout (DeviceIoOp.present). The composited screen pixels live
//     only in the kernel scanout buffer (ramfb.framebuffer), unreadable from EL0.
//   • Synthetic INPUT injection — none. The input device is read-only
//     (DeviceIoOp.query_state / read_events); there is no post/inject op.
//
// To make this backend real, Nexus must add compositor-side (EL1) device ops,
// e.g. a `DeviceIoOp.capture_surface` (read scanout / a named surface into a
// user buffer), a surface-enumeration selector on the display device that
// returns per-surface geometry + app-id, and an input `inject` op that feeds
// sb0.InputQueueEvent into the same pipeline read_events drains. When those land
// in src/abi/sb0_v0.sig + src/kernel/sb0_devices.sig, wire them here via the
// io_uring-style device queue (queueCreate/queueMap/queueSubmit/queueWait), the
// same handshake apps/icy_native/personality.sig uses to acquire+present a
// surface. Pixel format on SB0 is BGRX8888 (pitch = width*4), so a real capture
// path swaps B<->R to produce the RGBA this module's callers expect.
//
// Until then, behave exactly like the headless stub so the whole suite still
// cross-compiles to SB0 and runs without pretending to see windows it cannot.

const api = @import("../screencap.sig");

const WindowInfo = api.WindowInfo;
const Capture = api.Capture;
const EnumOptions = api.EnumOptions;

pub fn enumerate(comptime capacity: usize, list: *api.WindowList(capacity), opts: EnumOptions) usize {
    _ = opts;
    list.len = 0;
    return 0;
}

pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    _ = win;
    return api.captureFail(out);
}

pub fn clickAt(screen_x: i32, screen_y: i32) bool {
    _ = screen_x;
    _ = screen_y;
    return false;
}

pub fn sleepMs(ms: u32) void {
    // No hosted timer syscall wired here yet; a real backend would use the SB0
    // time_now / sleep trap (see apps/icy_native/abi_client.sig timeNow/sleep).
    _ = ms;
}
