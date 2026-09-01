// screencap — cross-platform window enumeration, capture, and synthetic click.
// Layer 1: Platform. General-purpose primitives for UI automation and screen
// analysis on every OS that has a display server.
//
// The public API here is OS-independent. The real work is done by a backend
// selected at comptime from `builtin.os.tag`:
//
//   windows  -> screencap/windows.sig  (Win32 GDI + SendInput)
//   macos    -> screencap/macos.sig    (CoreGraphics + CGEvent)
//   linux    -> screencap/x11.sig      (Xlib + XTest)
//   other    -> screencap/stub.sig     (headless: compiles, reports no display)
//
// Every backend exposes the same three entry points — enumerate, captureWindow,
// clickAt — plus sleepMs. Buffers are caller-provided; nothing is heap
// allocated. Window handles are opaque `usize` values interpreted only by the
// backend that produced them; titles are UTF-8.

const builtin = @import("builtin");

pub const MAX_TITLE = 256;

/// A single top-level window discovered by `enumerate`. OS-independent:
/// `handle` is an opaque backend token (HWND / CGWindowID / X11 Window).
pub const WindowInfo = struct {
    handle: usize = 0,
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// UTF-8 title, `title_len` bytes valid.
    title: [MAX_TITLE]u8 = @splat(0),
    title_len: usize = 0,

    pub fn titleSlice(self: *const WindowInfo) []const u8 {
        return self.title[0..self.title_len];
    }
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

pub const EnumOptions = struct {
    visible_only: bool = true,
    min_width: i32 = 64,
    min_height: i32 = 32,
};

pub const Capture = struct {
    /// Tightly packed RGBA, row-major, top-left origin. Points into the
    /// caller-provided buffer.
    pixels: []u8,
    width: u32,
    height: u32,
    ok: bool,
};

/// Backend selected once, at comptime, for the target OS.
///
///   windows -> Win32 GDI + SendInput
///   macos   -> CoreGraphics + CGEvent
///   linux   -> Xlib + XTest
///   sb0     -> Nexus compositor client (userspace on SB0S/SB0X)
///   other   -> headless stub (compiles, reports no display)
const backend = switch (builtin.os.tag) {
    .windows => @import("screencap/windows.sig"),
    .macos => @import("screencap/macos.sig"),
    .linux => @import("screencap/x11.sig"),
    .sb0 => @import("screencap/sb0.sig"),
    else => @import("screencap/stub.sig"),
};

/// Whether the current target has a real, working capture backend.
///
/// SB0 is intentionally excluded here: the SB0 userspace ABI currently exposes
/// only a single write-only surface (acquire/present) and read-only input, with
/// no cross-window enumeration, screen read-back, or synthetic input. The SB0
/// backend therefore compiles and links but reports "no display" until the
/// Nexus compositor gains capture/enumerate/inject device ops. See
/// screencap/sb0.sig for the exact ABI hooks it will use once they exist.
pub const supported: bool = switch (builtin.os.tag) {
    .windows, .macos, .linux => true,
    else => false,
};

/// Enumerate top-level windows into `list`. Returns the number collected.
pub fn enumerate(comptime capacity: usize, list: *WindowList(capacity), opts: EnumOptions) usize {
    return backend.enumerate(capacity, list, opts);
}

/// Capture a window's full content into `out` as RGBA. `out` must be at least
/// `width*height*4` bytes for the window's current size.
pub fn captureWindow(win: WindowInfo, out: []u8) Capture {
    return backend.captureWindow(win, out);
}

/// Synthetically click at an absolute screen coordinate. Returns true if the
/// click was injected.
pub fn clickAt(screen_x: i32, screen_y: i32) bool {
    return backend.clickAt(screen_x, screen_y);
}

/// Sleep for `ms` milliseconds (used between click and verification capture).
pub fn sleepMs(ms: u32) void {
    backend.sleepMs(ms);
}

/// Helper shared by all backends: mark a capture as failed.
pub fn captureFail(out: []u8) Capture {
    return .{ .pixels = out[0..0], .width = 0, .height = 0, .ok = false };
}
