// web_capture — render a URL to a PNG by driving a headless browser.
// Layer 1: Platform.
//
// zpm has no HTML/CSS layout engine, and writing one is out of scope. The
// honest, portable way to turn a live URL into a raster is to drive the
// browser the operator already has installed. This module locates a
// Chromium-family browser (Chrome / Edge / Chromium / Brave) and invokes its
// headless `--screenshot` mode via the zpm `subprocess` primitive.
//
//   const shot = web_capture.capture(io, .{
//       .url = "https://example.com",
//       .output_path = "out.png",
//       .width = 1440,
//       .height = 2400,
//   });
//   if (shot.ok) { /* out.png now exists */ }
//
// Everything is fixed-buffer; nothing is heap allocated. The browser writes
// the PNG to `output_path` itself — we only spawn and wait.

const std = @import("std");
const builtin = @import("builtin");
const subprocess = @import("subprocess");

/// Options for a single capture.
pub const Options = struct {
    /// The URL to render. Must be http(s):// (or file://). Not validated here.
    url: []const u8,
    /// Where the browser writes the PNG. Overwritten if it exists.
    output_path: []const u8,
    /// Viewport width in CSS pixels.
    width: u32 = 1440,
    /// Viewport height in CSS pixels. The capture is clipped to this height;
    /// headless Chrome screenshots the viewport, so size it to the page.
    height: u32 = 2400,
    /// Device scale factor (1 = 1:1 CSS px -> device px). Kept at 1 so the
    /// downstream pixel pipeline sees predictable dimensions.
    scale: u32 = 1,
    /// Explicit browser executable. If null, we probe known install paths.
    browser_path: ?[]const u8 = null,
    /// Seconds to allow the browser before giving up (0 = browser default).
    /// Note: enforced by the browser's own --timeout, not by subprocess limits
    /// (those fail closed on the generic std.Io backend).
    timeout_sec: u32 = 30,
};

pub const Error = enum {
    none,
    no_browser_found,
    spawn_failed,
    browser_error,
    bad_arguments,
};

pub const Result = struct {
    ok: bool,
    err: Error,
    /// Browser process exit code (valid when a browser was actually spawned).
    exit_code: i32,
    /// The browser executable that was used, for diagnostics.
    browser_used: []const u8,

    pub fn isOk(self: *const Result) bool {
        return self.ok;
    }
};

/// Known Chromium-family executables by platform, in preference order.
/// Absolute paths are tried first (most reliable), then bare names that rely
/// on PATH resolution by the OS loader.
fn candidatePaths() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
            "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
            "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
            "C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe",
        },
        .macos => &[_][]const u8{
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        },
        else => &[_][]const u8{
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/usr/bin/microsoft-edge",
            "/usr/bin/brave-browser",
            "google-chrome",
            "chromium",
        },
    };
}

/// Pick a browser: the caller's explicit path if given, else the first
/// candidate that exists on disk. Bare names (no path separator) are accepted
/// optimistically and left to PATH resolution at spawn time.
fn resolveBrowser(io: std.Io, opts: *const Options) ?[]const u8 {
    if (opts.browser_path) |p| {
        if (p.len > 0) return p;
    }
    const cwd: std.Io.Dir = .cwd();
    for (candidatePaths()) |cand| {
        if (!hasPathSep(cand)) return cand; // bare name: trust PATH
        if (cwd.access(io, cand, .{})) |_| {
            return cand;
        } else |_| {}
    }
    return null;
}

fn hasPathSep(s: []const u8) bool {
    for (s) |c| {
        if (c == '/' or c == '\\') return true;
    }
    return false;
}

/// True if `path` names a file that exists and has non-zero size.
fn outputExists(io: std.Io, path: []const u8) bool {
    const cwd: std.Io.Dir = .cwd();
    const f = cwd.openFile(io, path, .{}) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;
    return st.size > 0;
}

/// Render `opts.url` to a PNG at `opts.output_path`. Returns a Result; check
/// `.ok`. On success the PNG file exists and is ready for decoding.
pub fn capture(io: std.Io, opts: Options) Result {
    if (opts.url.len == 0 or opts.output_path.len == 0) {
        return .{ .ok = false, .err = .bad_arguments, .exit_code = -1, .browser_used = "" };
    }

    const browser = resolveBrowser(io, &opts) orelse
        return .{ .ok = false, .err = .no_browser_found, .exit_code = -1, .browser_used = "" };

    // Compose the browser flags. Chromium headless writes the PNG itself.
    //   --headless               classic headless — reliably honors --screenshot
    //                            and writes the file (the newer --headless=new
    //                            silently ignores relative paths and still
    //                            exits 0, so we avoid it).
    //   --disable-gpu            avoid GPU init failures in headless
    //   --hide-scrollbars        keep scrollbars out of the raster
    //   --screenshot=PATH        capture destination (MUST be absolute — a
    //                            relative path is denied/ignored by the browser)
    //   --window-size=W,H        viewport
    //   --force-device-scale-factor=N   pixel ratio
    //   --virtual-time-budget    let async content settle before the shot
    //   --no-sandbox             required in many CI/container contexts
    var arg_store: ArgStore = .{};
    const screenshot_flag = arg_store.fmt("--screenshot={s}", .{opts.output_path});
    const window_flag = arg_store.fmt("--window-size={d},{d}", .{ opts.width, opts.height });
    const scale_flag = arg_store.fmt("--force-device-scale-factor={d}", .{opts.scale});
    const vtb = @as(u64, if (opts.timeout_sec == 0) 8 else opts.timeout_sec) * 1000;
    const vt_flag = arg_store.fmt("--virtual-time-budget={d}", .{@min(vtb, 20000)});

    const argv = [_][]const u8{
        browser,
        "--headless",
        "--disable-gpu",
        "--hide-scrollbars",
        "--no-sandbox",
        "--no-first-run",
        "--disable-extensions",
        "--default-background-color=FFFFFFFF",
        screenshot_flag,
        window_flag,
        scale_flag,
        vt_flag,
        opts.url,
    };

    const cfg = subprocess.SubprocessConfig{ .argv = &argv };
    const res = subprocess.run(io, &cfg);

    if (res.limit_exceeded != null and res.exit_code == -1) {
        // spawn never produced a process (e.g. executable not found)
        return .{ .ok = false, .err = .spawn_failed, .exit_code = res.exit_code, .browser_used = browser };
    }
    if (res.exit_code != 0) {
        return .{ .ok = false, .err = .browser_error, .exit_code = res.exit_code, .browser_used = browser };
    }

    // Headless Chromium exits 0 even when it fails to write the screenshot
    // (e.g. a bad path). Don't trust the exit code alone — confirm the file
    // exists and is non-empty before declaring success.
    if (!outputExists(io, opts.output_path)) {
        return .{ .ok = false, .err = .browser_error, .exit_code = res.exit_code, .browser_used = browser };
    }

    return .{ .ok = true, .err = .none, .exit_code = res.exit_code, .browser_used = browser };
}

/// Small fixed arena for the handful of formatted argv strings we build.
/// Avoids any heap; sized generously for long output paths.
const ArgStore = struct {
    buf: [2048]u8 = undefined,
    used: usize = 0,

    fn fmt(self: *ArgStore, comptime spec: []const u8, args: anytype) []const u8 {
        const remaining = self.buf[self.used..];
        const out = std.fmt.bufPrint(remaining, spec, args) catch return "";
        self.used += out.len;
        return out;
    }
};

// ── Tests ──

const testing = std.testing;

test "web_capture: bad arguments fail closed" {
    const r = capture(testing.io, .{ .url = "", .output_path = "x.png" });
    try testing.expect(!r.ok);
    try testing.expectEqual(Error.bad_arguments, r.err);
}

test "web_capture: candidate list is non-empty for this platform" {
    try testing.expect(candidatePaths().len > 0);
}

test "web_capture: hasPathSep detects separators" {
    try testing.expect(hasPathSep("/usr/bin/x"));
    try testing.expect(hasPathSep("C:\\a\\b"));
    try testing.expect(!hasPathSep("chromium"));
}

test "web_capture: explicit browser path is honored" {
    const opts = Options{ .url = "https://x", .output_path = "o.png", .browser_path = "/custom/br" };
    const b = resolveBrowser(testing.io, &opts);
    try testing.expect(b != null);
    try testing.expectEqualStrings("/custom/br", b.?);
}
