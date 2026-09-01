// screencap stub backend — headless / no-display targets.
// Compiles on any target and reports "no display": enumerate finds nothing,
// capture fails, click is a no-op. Selected for freestanding / WASM / other.

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
    _ = ms;
}
