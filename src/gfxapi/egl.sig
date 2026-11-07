//! @zpm/gfxapi egl — EGL 1.5 for OpenGL ES, over the engine: displays
//! (Wayland, and Mesa's surfaceless platform), configs, contexts with
//! share groups, window surfaces (wayland.sig) and pbuffers, the current
//! context per thread (thread.sig), swaps, and fence syncs. What
//! libgalaxy_gl.sig's egl* entry points call.
//!
//! - **The driver.** The process's GPU and engine, opened by the library's
//!   root at the first eglInitialize (`Driver.open`). Without a GPU, or
//!   once it is lost, eglInitialize fails (EGL_NOT_INITIALIZED), so an app
//!   draws in software instead (Firefox's SWGL, Chromium's SwiftShader),
//!   which beats GL done on the CPU.
//! - **Displays.** EGL_DEFAULT_DISPLAY and EGL_PLATFORM_SURFACELESS_MESA
//!   are the surfaceless display (pbuffers, surfaceless contexts). A
//!   wl_display (eglGetDisplay of one, or EGL_PLATFORM_WAYLAND_KHR) is a
//!   Wayland display: window surfaces of wl_egl_windows.
//! - **Configs.** Four: ARGB8888 and XRGB8888 (DRM's fourcc is the native
//!   visual), each with and without depth 24 + stencil 8; windows and
//!   pbuffers; OpenGL ES 2 and 3. eglChooseConfig matches and sorts as
//!   EGL 1.5's 3.4.1 says.
//! - **Contexts.** OpenGL ES 2.0 and 3.0 (ES 3.0 either way, as Mesa
//!   gives); robustness attributes taken (the engine reports a lost GPU as
//!   a reset); EGL_KHR_no_config_context; share groups.
//! - **Syncs.** EGL_KHR_fence_sync and EGL 1.5's: a fence is the engine's
//!   mark (its work flushed), waited for on the CPU. eglWaitSync waits for
//!   nothing: one in-order GPU ring already orders it.
//!   EGL_ANDROID_native_fence_sync: a fence of this process's GPU work
//!   handed out as a sync_file (Galaxy's G_FENCE_FD), or one handed in (a
//!   sync_file fd, polled; owned and closed with the sync).
//! - **Images.** EGL_KHR_image_base with EGL_EXT_image_dma_buf_import
//!   (and _modifiers): a single-plane linear ARGB8888, XRGB8888, ABGR8888
//!   or XBGR8888 dma-buf, imported into this context (PRIME), as GL's
//!   textures and renderbuffers (gles: OES_EGL_image) name it, the memory
//!   shared and freed with its last name.
//!
//! EGL's calls take one lock (its tables are the process's); GL calls take
//! none.
//!
//! Allocation-free: fixed tables (MAX_*), in this file's memory.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.sig");
const gles = @import("gles.sig");
const report = @import("report.sig");
const thread = @import("thread.sig");
const wayland = @import("wayland.sig");
const Host = @import("host.sig").Host;
const Engine = engine.Engine;
const Image = engine.Image;

// ── EGL's values ───────────────────────────────────────────────────────────

pub const FALSE: u32 = 0;
pub const TRUE: u32 = 1;
pub const DONT_CARE: i32 = -1;
pub const NONE: i32 = 0x3038;

pub const SUCCESS: i32 = 0x3000;
pub const NOT_INITIALIZED: i32 = 0x3001;
pub const BAD_ACCESS: i32 = 0x3002;
pub const BAD_ALLOC: i32 = 0x3003;
pub const BAD_ATTRIBUTE: i32 = 0x3004;
pub const BAD_CONFIG: i32 = 0x3005;
pub const BAD_CONTEXT: i32 = 0x3006;
pub const BAD_CURRENT_SURFACE: i32 = 0x3007;
pub const BAD_DISPLAY: i32 = 0x3008;
pub const BAD_MATCH: i32 = 0x3009;
pub const BAD_NATIVE_PIXMAP: i32 = 0x300A;
pub const BAD_NATIVE_WINDOW: i32 = 0x300B;
pub const BAD_PARAMETER: i32 = 0x300C;
pub const BAD_SURFACE: i32 = 0x300D;
pub const CONTEXT_LOST: i32 = 0x300E;
pub const BAD_DEVICE_EXT: i32 = 0x322B;

// config attributes
pub const BUFFER_SIZE: i32 = 0x3020;
pub const ALPHA_SIZE: i32 = 0x3021;
pub const BLUE_SIZE: i32 = 0x3022;
pub const GREEN_SIZE: i32 = 0x3023;
pub const RED_SIZE: i32 = 0x3024;
pub const DEPTH_SIZE: i32 = 0x3025;
pub const STENCIL_SIZE: i32 = 0x3026;
pub const CONFIG_CAVEAT: i32 = 0x3027;
pub const CONFIG_ID: i32 = 0x3028;
pub const LEVEL: i32 = 0x3029;
pub const MAX_PBUFFER_HEIGHT: i32 = 0x302A;
pub const MAX_PBUFFER_PIXELS: i32 = 0x302B;
pub const MAX_PBUFFER_WIDTH: i32 = 0x302C;
pub const NATIVE_RENDERABLE: i32 = 0x302D;
pub const NATIVE_VISUAL_ID: i32 = 0x302E;
pub const NATIVE_VISUAL_TYPE: i32 = 0x302F;
pub const SAMPLES: i32 = 0x3031;
pub const SAMPLE_BUFFERS: i32 = 0x3032;
pub const SURFACE_TYPE: i32 = 0x3033;
pub const TRANSPARENT_TYPE: i32 = 0x3034;
pub const TRANSPARENT_BLUE_VALUE: i32 = 0x3035;
pub const TRANSPARENT_GREEN_VALUE: i32 = 0x3036;
pub const TRANSPARENT_RED_VALUE: i32 = 0x3037;
pub const BIND_TO_TEXTURE_RGB: i32 = 0x3039;
pub const BIND_TO_TEXTURE_RGBA: i32 = 0x303A;
pub const MIN_SWAP_INTERVAL: i32 = 0x303B;
pub const MAX_SWAP_INTERVAL: i32 = 0x303C;
pub const LUMINANCE_SIZE: i32 = 0x303D;
pub const ALPHA_MASK_SIZE: i32 = 0x303E;
pub const COLOR_BUFFER_TYPE: i32 = 0x303F;
pub const RENDERABLE_TYPE: i32 = 0x3040;
pub const MATCH_NATIVE_PIXMAP: i32 = 0x3041;
pub const CONFORMANT: i32 = 0x3042;
pub const RECORDABLE_ANDROID: i32 = 0x3142;
pub const RGB_BUFFER: i32 = 0x308E;
pub const SLOW_CONFIG: i32 = 0x3050;
pub const NON_CONFORMANT_CONFIG: i32 = 0x3051;

pub const PBUFFER_BIT: i32 = 0x0001;
pub const WINDOW_BIT: i32 = 0x0004;
pub const OPENGL_ES_BIT: i32 = 0x0001;
pub const OPENGL_ES2_BIT: i32 = 0x0004;
pub const OPENGL_ES3_BIT: i32 = 0x0040;

// surfaces
pub const HEIGHT: i32 = 0x3056;
pub const WIDTH: i32 = 0x3057;
pub const LARGEST_PBUFFER: i32 = 0x3058;
pub const TEXTURE_FORMAT: i32 = 0x3080;
pub const TEXTURE_TARGET: i32 = 0x3081;
pub const MIPMAP_TEXTURE: i32 = 0x3082;
pub const MIPMAP_LEVEL: i32 = 0x3083;
pub const NO_TEXTURE: i32 = 0x305C;
pub const RENDER_BUFFER: i32 = 0x3086;
pub const BACK_BUFFER: i32 = 0x3084;
pub const SINGLE_BUFFER: i32 = 0x3085;
pub const SWAP_BEHAVIOR: i32 = 0x3093;
pub const BUFFER_PRESERVED: i32 = 0x3094;
pub const BUFFER_DESTROYED: i32 = 0x3095;
pub const MULTISAMPLE_RESOLVE: i32 = 0x3099;
pub const MULTISAMPLE_RESOLVE_DEFAULT: i32 = 0x309A;
pub const HORIZONTAL_RESOLUTION: i32 = 0x3090;
pub const VERTICAL_RESOLUTION: i32 = 0x3091;
pub const PIXEL_ASPECT_RATIO: i32 = 0x3092;
pub const UNKNOWN: i32 = -1;
pub const GL_COLORSPACE: i32 = 0x309D;
pub const GL_COLORSPACE_LINEAR: i32 = 0x308A;
pub const BUFFER_AGE_EXT: i32 = 0x313D;
pub const DRAW: i32 = 0x3059;
pub const READ: i32 = 0x305A;

// contexts
pub const CONTEXT_CLIENT_TYPE: i32 = 0x3097;
pub const CONTEXT_CLIENT_VERSION: i32 = 0x3098;
pub const CONTEXT_MAJOR_VERSION: i32 = 0x3098;
pub const CONTEXT_MINOR_VERSION: i32 = 0x30FB;
pub const CONTEXT_FLAGS_KHR: i32 = 0x30FC;
pub const CONTEXT_OPENGL_PROFILE_MASK: i32 = 0x30FD;
pub const CONTEXT_OPENGL_DEBUG: i32 = 0x31B0;
pub const CONTEXT_OPENGL_FORWARD_COMPATIBLE: i32 = 0x31B1;
pub const CONTEXT_OPENGL_ROBUST_ACCESS: i32 = 0x31B2;
pub const CONTEXT_OPENGL_NO_ERROR_KHR: i32 = 0x31B3;
pub const CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY: i32 = 0x31BD;
pub const CONTEXT_OPENGL_ROBUST_ACCESS_EXT: i32 = 0x30BF;
pub const CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT: i32 = 0x3138;
pub const NO_RESET_NOTIFICATION: i32 = 0x31BE;
pub const LOSE_CONTEXT_ON_RESET: i32 = 0x31BF;
pub const CONTEXT_PRIORITY_LEVEL_IMG: i32 = 0x3100;
pub const OPENGL_ES_API: u32 = 0x30A0;

// display queries, platforms
pub const VENDOR: i32 = 0x3053;
pub const VERSION: i32 = 0x3054;
pub const EXTENSIONS: i32 = 0x3055;
pub const CLIENT_APIS: i32 = 0x308D;
pub const PLATFORM_WAYLAND_KHR: u32 = 0x31D8;
pub const PLATFORM_SURFACELESS_MESA: u32 = 0x31DD;

// syncs
pub const SYNC_FENCE: u32 = 0x30F9;
pub const SYNC_TYPE: i32 = 0x30F7;
pub const SYNC_STATUS: i32 = 0x30F1;
pub const SYNC_CONDITION: i32 = 0x30F8;
pub const SIGNALED: i32 = 0x30F2;
pub const UNSIGNALED: i32 = 0x30F3;
pub const SYNC_PRIOR_COMMANDS_COMPLETE: i32 = 0x30F0;
pub const SYNC_FLUSH_COMMANDS_BIT: i32 = 0x0001;
pub const CONDITION_SATISFIED: i32 = 0x30F6;
pub const TIMEOUT_EXPIRED: i32 = 0x30F5;
pub const FOREVER: u64 = 0xFFFF_FFFF_FFFF_FFFF;
pub const SYNC_NATIVE_FENCE_ANDROID: u32 = 0x3144;
pub const SYNC_NATIVE_FENCE_FD_ANDROID: i32 = 0x3145;
pub const SYNC_NATIVE_FENCE_SIGNALED_ANDROID: i32 = 0x3146;
pub const NO_NATIVE_FENCE_FD_ANDROID: i32 = -1;

// images (EGL_KHR_image_base, EGL_EXT_image_dma_buf_import)
pub const LINUX_DMA_BUF_EXT: u32 = 0x3270;
pub const LINUX_DRM_FOURCC_EXT: i32 = 0x3271;
pub const DMA_BUF_PLANE0_FD_EXT: i32 = 0x3272;
pub const DMA_BUF_PLANE0_OFFSET_EXT: i32 = 0x3273;
pub const DMA_BUF_PLANE0_PITCH_EXT: i32 = 0x3274;
pub const DMA_BUF_PLANE0_MODIFIER_LO_EXT: i32 = 0x3443;
pub const DMA_BUF_PLANE0_MODIFIER_HI_EXT: i32 = 0x3444;
pub const IMAGE_PRESERVED_KHR: i32 = 0x30D2;
/// DRM_FORMAT_MOD_INVALID: no modifier said (the buffer's own layout: linear here)
const MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;
pub const DRM_FORMAT_ABGR8888: u32 = 0x3432_4241;
pub const DRM_FORMAT_XBGR8888: u32 = 0x3432_4258;
pub const dma_buf_formats = [_]u32{ wayland.DRM_FORMAT_ARGB8888, wayland.DRM_FORMAT_XRGB8888, DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888 };

pub const VERSION_STRING: [:0]const u8 = "1.5 Galaxy";
pub const CLIENT_EXTENSIONS: [:0]const u8 = "EGL_EXT_client_extensions EGL_EXT_device_base EGL_EXT_device_enumeration EGL_EXT_device_query EGL_EXT_platform_base EGL_EXT_platform_wayland EGL_KHR_client_get_all_proc_addresses EGL_KHR_platform_wayland EGL_MESA_platform_surfaceless";
/// The one device's extensions (eglQueryDeviceStringEXT's EXTENSIONS).
pub const DEVICE_EXTENSIONS: [:0]const u8 = "EGL_EXT_device_drm EGL_EXT_device_drm_render_node";
pub const DEVICE_EXT: i32 = 0x322C;
pub const DRM_DEVICE_FILE_EXT: i32 = 0x3233;
pub const DRM_RENDER_NODE_FILE_EXT: i32 = 0x3377;
/// The render node every display draws through.
pub const RENDER_NODE: [:0]const u8 = "/dev/dri/renderD128";
pub const DISPLAY_EXTENSIONS: [:0]const u8 = "EGL_ANDROID_native_fence_sync EGL_EXT_buffer_age EGL_EXT_create_context_robustness EGL_EXT_image_dma_buf_import EGL_EXT_image_dma_buf_import_modifiers EGL_EXT_swap_buffers_with_damage EGL_KHR_create_context EGL_KHR_fence_sync EGL_KHR_get_all_proc_addresses EGL_KHR_image_base EGL_KHR_no_config_context EGL_KHR_surfaceless_context EGL_KHR_swap_buffers_with_damage EGL_KHR_wait_sync";

pub const MAX_DISPLAYS = 8;
pub const MAX_CONTEXTS = 32;
pub const MAX_SHARE = 16;
pub const MAX_SURFACES = 32;
pub const MAX_SYNCS = 64;
pub const MAX_IMAGES = 64;
pub const MAX_SIZE = gles.MAX_SIZE;

// ── The driver (the library's root, or a test, gives it) ──────────────────

pub const Driver = struct {
    /// The GPU's engine, opened at the first eglInitialize (null: no GPU,
    /// or it is lost).
    open: *const fn () ?*Engine,
    host: Host,
    /// libwayland-client (null: not in this process).
    wayland: *const fn () ?*const wayland.Client,
};

const root = @import("root");

/// The library root's (libgalaxy_gl.sig: `egl_driver`), until a test sets
/// its own.
var driver: ?Driver = if (@hasDecl(root, "egl_driver")) root.egl_driver else null;

pub fn setDriver(d: Driver) void {
    driver = d;
}

// ── The lock ───────────────────────────────────────────────────────────────

var lock_word = std.atomic.Value(u32).init(0);

/// The tables are filled at the first EGL call (under the lock): left
/// undefined, they take no room in the library's file (its .bss), where
/// their defaults would take hundreds of KiB of .data.
var tables_ready = false;

fn fillTables() void {
    for (&displays) |*d| d.* = .{};
    for (&contexts) |*c| c.* = .{};
    for (&surfaces) |*s| s.* = .{};
    for (&syncs) |*s| s.* = .{};
    for (&eimages) |*m| m.* = .{};
    gles.egl_image = resolveImage;
    tables_ready = true;
}

fn lock() void {
    take();
    if (!tables_ready) fillTables();
}

/// A futex mutex (0 free, 1 held, 2 held with waiters): once a thread has
/// waited it takes the lock by swapping in 2, so the unlock that follows
/// always wakes the next.
fn take() void {
    if (lock_word.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
    while (lock_word.swap(2, .acquire) != 0) {
        if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.syscall4(.futex, @intFromPtr(&lock_word.raw), 128, 2, 0); // FUTEX_WAIT_PRIVATE
        } else std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    if (lock_word.swap(0, .release) == 2 and comptime builtin.os.tag == .linux) {
        _ = std.os.linux.syscall3(.futex, @intFromPtr(&lock_word.raw), 129, 1); // FUTEX_WAKE_PRIVATE
    }
}

// ── Errors (per thread) ────────────────────────────────────────────────────

fn setError(e: i32) void {
    if (thread.mine()) |t| t.egl_error = e;
}

/// An EGL call's error: set, and its failure value returned.
fn fail(comptime T: type, e: i32, v: T) T {
    return failWhy(T, e, v, "");
}

/// An EGL error, said on the app's stderr with the call it came from
/// (`calling`) and why, where the reason is not the code's own: an app
/// such as Firefox reads eglGetError only after later calls have reset it.
fn failWhy(comptime T: type, e: i32, v: T, why: []const u8) T {
    setError(e);
    report.say(.egl_error, "{s}: {s} (0x{x}){s}{s}", .{ calling_name, errorName(e), e, if (why.len != 0) ": " else "", why });
    return v;
}

/// The EGL entry point running (set by libgalaxy_gl's exports; what a
/// failure is said to come from).
pub var calling_name: []const u8 = "egl";

pub fn calling(name: []const u8) void {
    calling_name = name;
}

fn errorName(e: i32) []const u8 {
    const names = [_][]const u8{ "SUCCESS", "NOT_INITIALIZED", "BAD_ACCESS", "BAD_ALLOC", "BAD_ATTRIBUTE", "BAD_CONFIG", "BAD_CONTEXT", "BAD_CURRENT_SURFACE", "BAD_DISPLAY", "BAD_MATCH", "BAD_NATIVE_PIXMAP", "BAD_NATIVE_WINDOW", "BAD_PARAMETER", "BAD_SURFACE", "CONTEXT_LOST" };
    const i = e - SUCCESS;
    return if (i >= 0 and i < names.len) names[@intCast(i)] else "error";
}

fn ok(comptime T: type, v: T) T {
    setError(SUCCESS);
    return v;
}

/// An entry point EGL has but this driver does not do: its error.
pub fn noSuch(e: i32) void {
    setError(e);
}

pub fn getError() i32 {
    const t = thread.mine() orelse return BAD_ALLOC;
    const e = t.egl_error;
    t.egl_error = SUCCESS;
    return e;
}

// ── Configs ────────────────────────────────────────────────────────────────

pub const Config = struct {
    id: i32,
    alpha: bool,
    depth: bool,

    pub fn attrib(c: *const Config, a: i32) ?i32 {
        return switch (a) {
            BUFFER_SIZE => if (c.alpha) 32 else 24,
            RED_SIZE, GREEN_SIZE, BLUE_SIZE => 8,
            ALPHA_SIZE => if (c.alpha) 8 else 0,
            DEPTH_SIZE => if (c.depth) 24 else 0,
            STENCIL_SIZE => if (c.depth) 8 else 0,
            CONFIG_ID => c.id,
            CONFIG_CAVEAT, TRANSPARENT_TYPE => NONE,
            COLOR_BUFFER_TYPE => RGB_BUFFER,
            SURFACE_TYPE => WINDOW_BIT | PBUFFER_BIT,
            RENDERABLE_TYPE, CONFORMANT => OPENGL_ES2_BIT | OPENGL_ES3_BIT,
            NATIVE_VISUAL_ID => @bitCast(if (c.alpha) wayland.DRM_FORMAT_ARGB8888 else wayland.DRM_FORMAT_XRGB8888),
            NATIVE_VISUAL_TYPE => NONE,
            NATIVE_RENDERABLE, BIND_TO_TEXTURE_RGB, BIND_TO_TEXTURE_RGBA, RECORDABLE_ANDROID => 0,
            MAX_PBUFFER_WIDTH, MAX_PBUFFER_HEIGHT => MAX_SIZE,
            MAX_PBUFFER_PIXELS => MAX_SIZE * MAX_SIZE,
            MIN_SWAP_INTERVAL => 0,
            MAX_SWAP_INTERVAL => 1,
            LEVEL, SAMPLES, SAMPLE_BUFFERS, LUMINANCE_SIZE, ALPHA_MASK_SIZE, TRANSPARENT_RED_VALUE, TRANSPARENT_GREEN_VALUE, TRANSPARENT_BLUE_VALUE => 0,
            else => null,
        };
    }
};

pub const configs = [_]Config{
    .{ .id = 1, .alpha = true, .depth = true },
    .{ .id = 2, .alpha = true, .depth = false },
    .{ .id = 3, .alpha = false, .depth = true },
    .{ .id = 4, .alpha = false, .depth = false },
};

const Match = enum { at_least, exact, mask };

/// How eglChooseConfig compares attribute `a`, and its default (EGL 1.5,
/// table 3.4); null: not an attribute it takes.
fn rule(a: i32) ?struct { how: Match, default: i32 } {
    return switch (a) {
        BUFFER_SIZE, RED_SIZE, GREEN_SIZE, BLUE_SIZE, ALPHA_SIZE, DEPTH_SIZE, STENCIL_SIZE, SAMPLES, SAMPLE_BUFFERS, LUMINANCE_SIZE, ALPHA_MASK_SIZE => .{ .how = .at_least, .default = 0 },
        CONFIG_ID, NATIVE_RENDERABLE, CONFIG_CAVEAT, MIN_SWAP_INTERVAL, MAX_SWAP_INTERVAL, BIND_TO_TEXTURE_RGB, BIND_TO_TEXTURE_RGBA, NATIVE_VISUAL_TYPE, RECORDABLE_ANDROID => .{ .how = .exact, .default = DONT_CARE },
        COLOR_BUFFER_TYPE => .{ .how = .exact, .default = RGB_BUFFER },
        LEVEL => .{ .how = .exact, .default = 0 },
        TRANSPARENT_TYPE => .{ .how = .exact, .default = NONE },
        TRANSPARENT_RED_VALUE, TRANSPARENT_GREEN_VALUE, TRANSPARENT_BLUE_VALUE => .{ .how = .exact, .default = DONT_CARE },
        SURFACE_TYPE => .{ .how = .mask, .default = WINDOW_BIT },
        RENDERABLE_TYPE => .{ .how = .mask, .default = OPENGL_ES_BIT },
        CONFORMANT => .{ .how = .mask, .default = 0 },
        // (ignored when choosing)
        NATIVE_VISUAL_ID, MAX_PBUFFER_WIDTH, MAX_PBUFFER_HEIGHT, MAX_PBUFFER_PIXELS, MATCH_NATIVE_PIXMAP => .{ .how = .exact, .default = DONT_CARE },
        else => null,
    };
}

fn ignoredWhenChoosing(a: i32) bool {
    return a == NATIVE_VISUAL_ID or a == MAX_PBUFFER_WIDTH or a == MAX_PBUFFER_HEIGHT or a == MAX_PBUFFER_PIXELS or a == MATCH_NATIVE_PIXMAP;
}

/// eglChooseConfig: the matching configs, best first, into `out` (or only
/// counted, without `out`). Null with an error.
pub fn chooseConfigs(attribs: ?[*]const i32, out: ?[]*const Config) ?usize {
    // the request: each attribute's wanted value (defaults, then the list)
    const Want = struct { a: i32, v: i32 };
    var want: [64]Want = undefined;
    var n: usize = 0;
    var config_id: i32 = DONT_CARE;
    const defaults = [_]i32{ BUFFER_SIZE, RED_SIZE, GREEN_SIZE, BLUE_SIZE, ALPHA_SIZE, DEPTH_SIZE, STENCIL_SIZE, SAMPLES, SAMPLE_BUFFERS, LUMINANCE_SIZE, ALPHA_MASK_SIZE, COLOR_BUFFER_TYPE, LEVEL, TRANSPARENT_TYPE, SURFACE_TYPE, RENDERABLE_TYPE, CONFORMANT };
    for (defaults) |a| {
        want[n] = .{ .a = a, .v = rule(a).?.default };
        n += 1;
    }
    if (attribs) |list| {
        var i: usize = 0;
        while (list[i] != NONE) : (i += 2) {
            const a = list[i];
            const v = list[i + 1];
            if (rule(a) == null) return fail(?usize, BAD_ATTRIBUTE, null);
            if (a == CONFIG_ID) config_id = v;
            if (ignoredWhenChoosing(a)) continue;
            const slot = for (want[0..n], 0..) |w, j| {
                if (w.a == a) break j;
            } else blk: {
                if (n == want.len) return fail(?usize, BAD_ATTRIBUTE, null);
                n += 1;
                break :blk n - 1;
            };
            want[slot] = .{ .a = a, .v = v };
        }
    }
    var picked: [configs.len]*const Config = undefined;
    var np: usize = 0;
    for (&configs) |*c| {
        // (EGL_CONFIG_ID given: that config, every other attribute ignored)
        const fits = if (config_id != DONT_CARE) c.id == config_id else for (want[0..n]) |w| {
            if (w.v == DONT_CARE) continue;
            const have = c.attrib(w.a) orelse 0;
            const good = switch (rule(w.a).?.how) {
                .at_least => have >= w.v,
                .exact => have == w.v,
                .mask => have & w.v == w.v,
            };
            if (!good) break false;
        } else true;
        if (fits) {
            picked[np] = c;
            np += 1;
        }
    }
    // the order: more of the color asked for first, then the smaller
    // buffer, depth, stencil, id
    const Sort = struct {
        red: bool,
        green: bool,
        blue: bool,
        alpha: bool,
        fn colorBits(s: @This(), c: *const Config) i32 {
            var t: i32 = 0;
            if (s.red) t += 8;
            if (s.green) t += 8;
            if (s.blue) t += 8;
            if (s.alpha) t += c.attrib(ALPHA_SIZE).?;
            return t;
        }
        fn less(s: @This(), a: *const Config, b: *const Config) bool {
            const ca = s.colorBits(a);
            const cb = s.colorBits(b);
            if (ca != cb) return ca > cb;
            inline for (.{ BUFFER_SIZE, DEPTH_SIZE, STENCIL_SIZE, CONFIG_ID }) |k| {
                const x = a.attrib(k).?;
                const y = b.attrib(k).?;
                if (x != y) return x < y;
            }
            return false;
        }
    };
    var s = Sort{ .red = false, .green = false, .blue = false, .alpha = false };
    for (want[0..n]) |w| {
        const asked = w.v != 0 and w.v != DONT_CARE;
        switch (w.a) {
            RED_SIZE => s.red = asked,
            GREEN_SIZE => s.green = asked,
            BLUE_SIZE => s.blue = asked,
            ALPHA_SIZE => s.alpha = asked,
            else => {},
        }
    }
    std.mem.sort(*const Config, picked[0..np], s, Sort.less);
    const o = out orelse return np;
    const k = @min(np, o.len);
    @memcpy(o[0..k], picked[0..k]);
    return k;
}

pub fn configOf(handle: ?*const anyopaque) ?*const Config {
    const p = handle orelse return null;
    for (&configs) |*c| {
        if (@intFromPtr(c) == @intFromPtr(p)) return c;
    }
    return null;
}

// ── Displays ───────────────────────────────────────────────────────────────

pub const Platform = enum { surfaceless, wayland };

pub const Display = struct {
    used: bool = false,
    platform: Platform = .surfaceless,
    native: ?*anyopaque = null,
    initialized: bool = false,
    eng: ?*Engine = null,
    client: ?*const wayland.Client = null,
    wl: wayland.Display = undefined,
    /// terminated with objects still current: the Wayland state goes with the last
    terminating: bool = false,
};

var displays: [MAX_DISPLAYS]Display = undefined;

/// A display handle, valid (the address of one of the table's).
fn displayOf(handle: ?*anyopaque) ?*Display {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&displays[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(displays))) return null;
    if ((p - base) % @sizeOf(Display) != 0) return null;
    const d: *Display = @ptrFromInt(p);
    return if (d.used) d else null;
}

/// The display of (platform, native), made on first use.
fn displayFor(platform: Platform, native: ?*anyopaque) ?*Display {
    for (&displays) |*d| {
        if (d.used and d.platform == platform and d.native == native) return d;
    }
    for (&displays) |*d| {
        if (!d.used) {
            d.* = .{ .used = true, .platform = platform, .native = native };
            return d;
        }
    }
    return null;
}

/// eglGetDisplay: EGL_DEFAULT_DISPLAY is the surfaceless display, a
/// wl_display a Wayland one; anything else none.
pub fn getDisplay(native: ?*anyopaque) ?*Display {
    lock();
    defer unlock();
    const n = native orelse return ok(?*Display, displayFor(.surfaceless, null));
    const drv = driver orelse return ok(?*Display, null);
    const c = drv.wayland() orelse return ok(?*Display, null);
    if (!c.isDisplay(n)) return ok(?*Display, null);
    return ok(?*Display, displayFor(.wayland, n));
}

/// eglGetPlatformDisplay (and the EXT one).
pub fn getPlatformDisplay(platform: u32, native: ?*anyopaque) ?*Display {
    lock();
    defer unlock();
    switch (platform) {
        PLATFORM_SURFACELESS_MESA => {
            if (native != null) return fail(?*Display, BAD_PARAMETER, null);
            return ok(?*Display, displayFor(.surfaceless, null));
        },
        PLATFORM_WAYLAND_KHR => {
            // (EGL_DEFAULT_DISPLAY would mean a connection of EGL's own: not made)
            const n = native orelse return fail(?*Display, BAD_PARAMETER, null);
            return ok(?*Display, displayFor(.wayland, n));
        },
        else => return fail(?*Display, BAD_PARAMETER, null),
    }
}

pub fn initialize(handle: ?*anyopaque, major: ?*i32, minor: ?*i32) bool {
    lock();
    defer unlock();
    const d = displayOf(handle) orelse return fail(bool, BAD_DISPLAY, false);
    if (!d.initialized) {
        const drv = driver orelse return fail(bool, NOT_INITIALIZED, false);
        const eng = drv.open() orelse return failWhy(bool, NOT_INITIALIZED, false, "no GPU to draw on");
        // (terminated while a context of it was still current: its Wayland
        // state is still there, kept for that context, and taken up again)
        if (d.platform == .wayland and !d.terminating) {
            const c = drv.wayland() orelse return failWhy(bool, NOT_INITIALIZED, false, "no libwayland-client in the app");
            if (!c.isDisplay(d.native.?)) return failWhy(bool, BAD_DISPLAY, false, "not a wl_display");
            if (!d.wl.init(c, drv.host, @ptrCast(d.native.?))) return failWhy(bool, NOT_INITIALIZED, false, "the compositor offers no dma-bufs this driver can show");
            d.client = c;
        }
        d.terminating = false;
        d.eng = eng;
        d.initialized = true;
    }
    if (major) |p| p.* = 1;
    if (minor) |p| p.* = 5;
    return ok(bool, true);
}

/// eglTerminate: the display's objects go, those current somewhere once
/// they are released.
pub fn terminate(handle: ?*anyopaque) bool {
    lock();
    defer unlock();
    const d = displayOf(handle) orelse return fail(bool, BAD_DISPLAY, false);
    if (!d.initialized) return ok(bool, true);
    for (&surfaces) |*s| {
        if (s.used and s.display == d) {
            s.doomed = true;
            if (s.ctx == null) freeSurface(s);
        }
    }
    for (&contexts) |*c| {
        if (c.used and c.display == d) {
            c.doomed = true;
            if (c.thread_key == 0) freeContext(c);
        }
    }
    for (&syncs) |*s| {
        if (s.used and s.display == d) dropSync(s);
    }
    for (&eimages) |*m| {
        if (m.alive and m.display == d) dropImage(m);
    }
    d.initialized = false;
    d.terminating = d.platform == .wayland;
    reapDisplay(d);
    return ok(bool, true);
}

/// A terminated display's Wayland state goes once nothing of it is left.
fn reapDisplay(d: *Display) void {
    if (d.initialized or !d.terminating) return;
    for (&surfaces) |*s| {
        if (s.used and s.display == d) return;
    }
    for (&contexts) |*c| {
        if (c.used and c.display == d) return;
    }
    d.wl.deinit();
    d.terminating = false;
}

// ── The device (EGL_EXT_device_query, _enumeration, _drm) ─────────────────
//
// One device, the GPU the driver draws on: what Firefox's glxtest asks for
// (eglQueryDisplayAttribEXT's EGL_DEVICE_EXT, then the device's render node)
// before it calls the GL usable.

/// The device's handle (any address of ours; only compared).
pub var the_device: u8 = 0;

fn deviceOf(dev: ?*anyopaque) bool {
    return dev == @as(?*anyopaque, @ptrCast(&the_device));
}

/// eglQueryDevicesEXT: the one device, when there is a GPU to draw on.
pub fn queryDevices(max: i32, out: ?[*]?*anyopaque, num: ?*i32) bool {
    lock();
    defer unlock();
    const n = num orelse return fail(bool, BAD_PARAMETER, false);
    if (out != null and max <= 0) return fail(bool, BAD_PARAMETER, false);
    const have: i32 = if (driver) |drv| (if (drv.open() != null) 1 else 0) else 0;
    if (out) |o| {
        if (have > 0) o[0] = @ptrCast(&the_device);
        n.* = @min(have, max);
    } else n.* = have;
    return ok(bool, true);
}

/// eglQueryDeviceStringEXT: its extensions, and its render node (no
/// primary node: EGL_DRM_DEVICE_FILE_EXT is BAD_PARAMETER, as Mesa says
/// for a render-only device).
pub fn queryDeviceString(dev: ?*anyopaque, name: i32) ?[*:0]const u8 {
    if (!deviceOf(dev)) return fail(?[*:0]const u8, BAD_DEVICE_EXT, null);
    return switch (name) {
        EXTENSIONS => ok(?[*:0]const u8, DEVICE_EXTENSIONS.ptr),
        DRM_RENDER_NODE_FILE_EXT => ok(?[*:0]const u8, RENDER_NODE.ptr),
        else => fail(?[*:0]const u8, BAD_PARAMETER, null),
    };
}

/// eglQueryDeviceAttribEXT: none it has.
pub fn queryDeviceAttrib(dev: ?*anyopaque, attribute: i32, value: ?*isize) bool {
    _ = .{ attribute, value };
    if (!deviceOf(dev)) return fail(bool, BAD_DEVICE_EXT, false);
    return fail(bool, BAD_ATTRIBUTE, false);
}

/// eglQueryDisplayAttribEXT/KHR: EGL_DEVICE_EXT, the display's device.
pub fn queryDisplayAttrib(handle: ?*anyopaque, attribute: i32, value: ?*isize) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const v = value orelse return fail(bool, BAD_PARAMETER, false);
    if (attribute != DEVICE_EXT) return fail(bool, BAD_ATTRIBUTE, false);
    v.* = @bitCast(@intFromPtr(&the_device));
    return ok(bool, true);
}

pub fn queryString(handle: ?*anyopaque, name: i32) ?[*:0]const u8 {
    lock();
    defer unlock();
    if (handle == null and name == EXTENSIONS) return ok(?[*:0]const u8, CLIENT_EXTENSIONS.ptr);
    const d = displayOf(handle) orelse return fail(?[*:0]const u8, BAD_DISPLAY, null);
    if (!d.initialized) return fail(?[*:0]const u8, NOT_INITIALIZED, null);
    return switch (name) {
        VENDOR => ok(?[*:0]const u8, "Galaxy"),
        VERSION => ok(?[*:0]const u8, VERSION_STRING.ptr),
        CLIENT_APIS => ok(?[*:0]const u8, "OpenGL_ES"),
        EXTENSIONS => ok(?[*:0]const u8, DISPLAY_EXTENSIONS.ptr),
        else => fail(?[*:0]const u8, BAD_PARAMETER, null),
    };
}

fn ready(handle: ?*anyopaque) ?*Display {
    const d = displayOf(handle) orelse return fail(?*Display, BAD_DISPLAY, null);
    if (!d.initialized) return fail(?*Display, NOT_INITIALIZED, null);
    return d;
}

pub fn getConfigs(handle: ?*anyopaque, out: ?[*]?*const anyopaque, size: i32, num: ?*i32) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const n_out = num orelse return fail(bool, BAD_PARAMETER, false);
    if (out) |o| {
        const k: usize = @intCast(@max(@min(size, configs.len), 0));
        for (0..k) |i| o[i] = &configs[i];
        n_out.* = @intCast(k);
    } else n_out.* = configs.len;
    return ok(bool, true);
}

pub fn chooseConfig(handle: ?*anyopaque, attribs: ?[*]const i32, out: ?[*]?*const anyopaque, size: i32, num: ?*i32) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const n_out = num orelse return fail(bool, BAD_PARAMETER, false);
    var picked: [configs.len]*const Config = undefined;
    const n = chooseConfigs(attribs, &picked) orelse return false;
    if (out) |o| {
        const k: usize = @min(n, @as(usize, @intCast(@max(size, 0))));
        for (0..k) |i| o[i] = picked[i];
        n_out.* = @intCast(k);
    } else n_out.* = @intCast(n);
    return ok(bool, true);
}

pub fn getConfigAttrib(handle: ?*anyopaque, config: ?*const anyopaque, a: i32, value: ?*i32) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const c = configOf(config) orelse return fail(bool, BAD_CONFIG, false);
    const v = c.attrib(a) orelse return fail(bool, BAD_ATTRIBUTE, false);
    if (value) |p| p.* = v;
    return ok(bool, true);
}

// ── Contexts ───────────────────────────────────────────────────────────────

pub const Context = struct {
    used: bool = false,
    display: ?*Display = null,
    config: ?*const Config = null,
    share: usize = 0,
    major: i32 = 3,
    /// the thread it is current on (thread.key()), 0: none
    thread_key: usize = 0,
    draw: ?*Surface = null,
    read: ?*Surface = null,
    /// destroyed (or its display terminated) while current: it goes at release
    doomed: bool = false,
    gl: gles.Context = undefined,
};

var contexts: [MAX_CONTEXTS]Context = undefined;
var shares: [MAX_SHARE]gles.Objects = undefined;
var share_users: [MAX_SHARE]u32 = [_]u32{0} ** MAX_SHARE;

fn contextOf(handle: ?*anyopaque, d: *Display) ?*Context {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&contexts[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(contexts)) or (p - base) % @sizeOf(Context) != 0) return null;
    const c: *Context = @ptrFromInt(p);
    return if (c.used and !c.doomed and c.display == d) c else null;
}

pub fn bindApi(api: u32) bool {
    if (api != OPENGL_ES_API) return fail(bool, BAD_PARAMETER, false);
    const t = thread.mine() orelse return fail(bool, BAD_ALLOC, false);
    t.api = api;
    return ok(bool, true);
}

pub fn queryApi() u32 {
    const t = thread.mine() orelse return OPENGL_ES_API;
    return t.api;
}

pub fn createContext(handle: ?*anyopaque, config: ?*const anyopaque, share_ctx: ?*anyopaque, attribs: ?[*]const i32) ?*Context {
    lock();
    defer unlock();
    const d = ready(handle) orelse return null;
    const cfg: ?*const Config = if (config == null) null else (configOf(config) orelse return fail(?*Context, BAD_CONFIG, null));
    var major: i32 = 1;
    var minor: i32 = 0;
    var lose = false;
    if (attribs) |list| {
        var i: usize = 0;
        while (list[i] != NONE) : (i += 2) {
            const v = list[i + 1];
            switch (list[i]) {
                CONTEXT_MAJOR_VERSION => major = v,
                CONTEXT_MINOR_VERSION => minor = v,
                CONTEXT_FLAGS_KHR => if (v & ~@as(i32, 7) != 0) return fail(?*Context, BAD_ATTRIBUTE, null),
                CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY, CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT => {
                    if (v != NO_RESET_NOTIFICATION and v != LOSE_CONTEXT_ON_RESET) return fail(?*Context, BAD_ATTRIBUTE, null);
                    lose = v == LOSE_CONTEXT_ON_RESET;
                },
                CONTEXT_OPENGL_DEBUG, CONTEXT_OPENGL_ROBUST_ACCESS, CONTEXT_OPENGL_ROBUST_ACCESS_EXT, CONTEXT_OPENGL_NO_ERROR_KHR, CONTEXT_PRIORITY_LEVEL_IMG => {},
                else => return failWhy(?*Context, BAD_ATTRIBUTE, null, "an attribute this driver does not take"),
            }
        }
    }
    // (OpenGL ES 2.0 and 3.0; ES 3.0 is given either way)
    if (!((major == 2 and minor == 0) or (major == 3 and minor == 0))) return failWhy(?*Context, BAD_MATCH, null, "only OpenGL ES 2.0 and 3.0");
    const t = thread.mine() orelse return fail(?*Context, BAD_ALLOC, null);
    if (t.api != OPENGL_ES_API) return fail(?*Context, BAD_MATCH, null);
    const eng = d.eng.?;
    if (eng.lost) return failWhy(?*Context, BAD_ALLOC, null, "the GPU is lost");
    const share: usize = if (share_ctx) |sp| blk: {
        const sc = contextOf(sp, d) orelse return fail(?*Context, BAD_CONTEXT, null);
        break :blk sc.share;
    } else blk: {
        for (&share_users, 0..) |n, i| {
            if (n == 0) {
                shares[i].init();
                break :blk i;
            }
        }
        return failWhy(?*Context, BAD_ALLOC, null, "every share group is in use");
    };
    const c = for (&contexts) |*x| {
        if (!x.used) break x;
    } else return failWhy(?*Context, BAD_ALLOC, null, "every context slot is in use");
    c.* = .{ .used = true, .display = d, .config = cfg, .share = share, .major = major };
    c.gl.init(eng, &shares[share]);
    c.gl.lose_on_reset = lose;
    share_users[share] += 1;
    return ok(?*Context, c);
}

fn freeContext(c: *Context) void {
    c.gl.deinit();
    share_users[c.share] -= 1;
    const d = c.display;
    c.* = .{};
    if (d) |x| reapDisplay(x);
}

pub fn destroyContext(handle: ?*anyopaque, ctx: ?*anyopaque) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const c = contextOf(ctx, d) orelse return fail(bool, BAD_CONTEXT, false);
    c.doomed = true;
    if (c.thread_key == 0) freeContext(c);
    return ok(bool, true);
}

pub fn queryContext(handle: ?*anyopaque, ctx: ?*anyopaque, a: i32, value: ?*i32) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const c = contextOf(ctx, d) orelse return fail(bool, BAD_CONTEXT, false);
    const v: i32 = switch (a) {
        CONFIG_ID => if (c.config) |cfg| cfg.id else 0,
        CONTEXT_CLIENT_TYPE => @intCast(OPENGL_ES_API),
        CONTEXT_CLIENT_VERSION => 3,
        RENDER_BUFFER => if (c.draw != null) BACK_BUFFER else NONE,
        else => return fail(bool, BAD_ATTRIBUTE, false),
    };
    if (value) |p| p.* = v;
    return ok(bool, true);
}

// ── Surfaces ───────────────────────────────────────────────────────────────

pub const Surface = struct {
    used: bool = false,
    display: ?*Display = null,
    config: *const Config = &configs[0],
    kind: enum { window, pbuffer } = .pbuffer,
    win: wayland.Window = undefined,
    /// a pbuffer's color
    color: Image = .{},
    /// depth and stencil (configs with them), the size of the color
    depth: Image = .{},
    /// the context it is current with, if any
    ctx: ?*Context = null,
    doomed: bool = false,
    /// pbuffer size as asked
    width: u32 = 0,
    height: u32 = 0,
};

var surfaces: [MAX_SURFACES]Surface = undefined;

fn surfaceOf(handle: ?*anyopaque, d: *Display) ?*Surface {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&surfaces[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(surfaces)) or (p - base) % @sizeOf(Surface) != 0) return null;
    const s: *Surface = @ptrFromInt(p);
    return if (s.used and !s.doomed and s.display == d) s else null;
}

fn newSurface(d: *Display, cfg: *const Config) ?*Surface {
    for (&surfaces) |*s| {
        if (!s.used) {
            s.* = .{ .used = true, .display = d, .config = cfg };
            return s;
        }
    }
    return null;
}

/// Window surface attributes (EGLint or EGLAttrib lists): RENDER_BUFFER
/// (the back buffer) and GL_COLORSPACE (linear) are all there are.
fn windowAttribs(comptime T: type, attribs: ?[*]const T) bool {
    const list = attribs orelse return true;
    var i: usize = 0;
    while (list[i] != NONE) : (i += 2) {
        const v = list[i + 1];
        switch (@as(i32, @intCast(list[i]))) {
            RENDER_BUFFER => if (v != BACK_BUFFER) return false,
            GL_COLORSPACE => if (v != GL_COLORSPACE_LINEAR) return false,
            else => return false,
        }
    }
    return true;
}

/// eglCreateWindowSurface and eglCreatePlatformWindowSurface: `native` is
/// a wl_egl_window.
pub fn createWindowSurface(comptime T: type, handle: ?*anyopaque, config: ?*const anyopaque, native: ?*anyopaque, attribs: ?[*]const T) ?*Surface {
    lock();
    defer unlock();
    const d = ready(handle) orelse return null;
    const cfg = configOf(config) orelse return fail(?*Surface, BAD_CONFIG, null);
    if (!windowAttribs(T, attribs)) return fail(?*Surface, BAD_ATTRIBUTE, null);
    if (d.platform != .wayland) return fail(?*Surface, BAD_NATIVE_WINDOW, null);
    const n: *wayland.EglWindow = @ptrCast(@alignCast(native orelse return fail(?*Surface, BAD_NATIVE_WINDOW, null)));
    if (n.driver_private != null) return failWhy(?*Surface, BAD_ALLOC, null, "the wl_egl_window has a surface already");
    const s = newSurface(d, cfg) orelse return failWhy(?*Surface, BAD_ALLOC, null, "every surface slot is in use");
    s.kind = .window;
    if (!s.win.init(&d.wl, d.eng.?, n, cfg.alpha)) {
        s.* = .{};
        return failWhy(?*Surface, BAD_NATIVE_WINDOW, null, "the window's Wayland surface could not be set up");
    }
    return ok(?*Surface, s);
}

pub fn createPbufferSurface(handle: ?*anyopaque, config: ?*const anyopaque, attribs: ?[*]const i32) ?*Surface {
    lock();
    defer unlock();
    const d = ready(handle) orelse return null;
    const cfg = configOf(config) orelse return fail(?*Surface, BAD_CONFIG, null);
    var w: i32 = 0;
    var h: i32 = 0;
    if (attribs) |list| {
        var i: usize = 0;
        while (list[i] != NONE) : (i += 2) {
            const v = list[i + 1];
            switch (list[i]) {
                WIDTH => w = v,
                HEIGHT => h = v,
                LARGEST_PBUFFER, MIPMAP_TEXTURE => {},
                TEXTURE_FORMAT, TEXTURE_TARGET => if (v != NO_TEXTURE) return fail(?*Surface, BAD_MATCH, null),
                GL_COLORSPACE => if (v != GL_COLORSPACE_LINEAR) return fail(?*Surface, BAD_MATCH, null),
                else => return fail(?*Surface, BAD_ATTRIBUTE, null),
            }
        }
    }
    if (w < 0 or h < 0) return fail(?*Surface, BAD_PARAMETER, null);
    if (w > MAX_SIZE or h > MAX_SIZE) return fail(?*Surface, BAD_ALLOC, null);
    const s = newSurface(d, cfg) orelse return fail(?*Surface, BAD_ALLOC, null);
    s.kind = .pbuffer;
    s.width = @intCast(w);
    s.height = @intCast(h);
    const eng = d.eng.?;
    // (a 0 x 0 pbuffer has a pixel behind it: GL needs a framebuffer)
    s.color = eng.newImage(@max(s.width, 1), @max(s.height, 1), .rgba8) orelse {
        s.* = .{};
        return fail(?*Surface, BAD_ALLOC, null);
    };
    s.color.no_alpha = !cfg.alpha;
    if (cfg.depth) {
        s.depth = eng.newImage(@max(s.width, 1), @max(s.height, 1), .d24s8) orelse {
            eng.freeImage(&s.color);
            s.* = .{};
            return fail(?*Surface, BAD_ALLOC, null);
        };
    }
    return ok(?*Surface, s);
}

fn freeSurface(s: *Surface) void {
    const d = s.display.?;
    const eng = d.eng.?;
    if (s.kind == .window) s.win.deinit();
    eng.freeImage(&s.color);
    eng.freeImage(&s.depth);
    s.* = .{};
    reapDisplay(d);
}

pub fn destroySurface(handle: ?*anyopaque, surface: ?*anyopaque) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const s = surfaceOf(surface, d) orelse return fail(bool, BAD_SURFACE, false);
    s.doomed = true;
    if (s.ctx == null) freeSurface(s) else if (s.kind == .window) s.win.detach();
    return ok(bool, true);
}

/// The surface's color image to draw to now (a window's back buffer), and
/// its depth image (made or remade at the color's size).
fn images(s: *Surface) ?struct { color: *Image, depth: ?*Image } {
    const color: *Image = if (s.kind == .window) (s.win.backImage() orelse return null) else &s.color;
    if (!s.config.depth) return .{ .color = color, .depth = null };
    const eng = s.display.?.eng.?;
    if (s.depth.width != color.width or s.depth.height != color.height) {
        eng.freeImage(&s.depth);
        s.depth = eng.newImage(color.width, color.height, .d24s8) orelse return null;
        s.depth.top_down = color.top_down;
    }
    return .{ .color = color, .depth = &s.depth };
}

/// The context's default framebuffer from its surfaces, as they are now.
fn bindSurfaces(c: *Context) bool {
    const draw = c.draw orelse {
        c.gl.setSurface(null, null, null);
        c.gl.revalidate = null;
        return true;
    };
    c.gl.revalidate = if (draw.kind == .window) .{ .ctx = c, .f = revalidateWindow, .stale = &draw.win.resized } else null;
    const di = images(draw) orelse return false;
    var ri = di;
    if (c.read) |r| {
        if (r != draw) ri = images(r) orelse return false;
    }
    c.gl.setSurface(di.color, ri.color, di.depth);
    return true;
}

/// GL is about to reach the default framebuffer of a window that was
/// resized: the back buffer, not shown yet, gives way to one of the new
/// size (on the thread drawing; EGL's lock is not taken: the surface is
/// this thread's while current).
fn revalidateWindow(p: *anyopaque) void {
    const c: *Context = @ptrCast(@alignCast(p));
    const s = c.draw orelse return;
    if (s.kind != .window) return;
    s.win.dropBack();
    _ = bindSurfaces(c);
}

pub fn querySurface(handle: ?*anyopaque, surface: ?*anyopaque, a: i32, value: ?*i32) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const s = surfaceOf(surface, d) orelse return fail(bool, BAD_SURFACE, false);
    const v: i32 = switch (a) {
        WIDTH => @intCast(if (s.kind == .window) s.win.wanted()[0] else s.width),
        HEIGHT => @intCast(if (s.kind == .window) s.win.wanted()[1] else s.height),
        CONFIG_ID => s.config.id,
        RENDER_BUFFER => BACK_BUFFER,
        SWAP_BEHAVIOR => BUFFER_DESTROYED,
        MULTISAMPLE_RESOLVE => MULTISAMPLE_RESOLVE_DEFAULT,
        HORIZONTAL_RESOLUTION, VERTICAL_RESOLUTION, PIXEL_ASPECT_RATIO => UNKNOWN,
        TEXTURE_FORMAT, TEXTURE_TARGET => NO_TEXTURE,
        LARGEST_PBUFFER, MIPMAP_TEXTURE, MIPMAP_LEVEL => 0,
        GL_COLORSPACE => GL_COLORSPACE_LINEAR,
        BUFFER_AGE_EXT => blk: {
            // (the back buffer of the surface drawn on this thread)
            const t = thread.get() orelse return fail(bool, BAD_SURFACE, false);
            if (t.draw != @as(?*anyopaque, s)) return fail(bool, BAD_SURFACE, false);
            break :blk if (s.kind == .window) s.win.age() else 0;
        },
        else => return fail(bool, BAD_ATTRIBUTE, false),
    };
    if (value) |p| p.* = v;
    return ok(bool, true);
}

pub fn surfaceAttrib(handle: ?*anyopaque, surface: ?*anyopaque, a: i32, v: i32) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    _ = surfaceOf(surface, d) orelse return fail(bool, BAD_SURFACE, false);
    return switch (a) {
        SWAP_BEHAVIOR => if (v == BUFFER_DESTROYED) ok(bool, true) else fail(bool, BAD_MATCH, false),
        MULTISAMPLE_RESOLVE => if (v == MULTISAMPLE_RESOLVE_DEFAULT) ok(bool, true) else fail(bool, BAD_MATCH, false),
        MIPMAP_LEVEL => ok(bool, true),
        else => fail(bool, BAD_ATTRIBUTE, false),
    };
}

// ── Current ────────────────────────────────────────────────────────────────

/// The calling thread's current context let go (flushed; freed if it was
/// destroyed meanwhile, with its doomed surfaces).
fn release(t: *thread.Thread) void {
    const c: *Context = @ptrCast(@alignCast(t.context orelse return));
    c.gl.flush();
    for ([2]?*Surface{ c.draw, c.read }) |sp| {
        const s = sp orelse continue;
        s.ctx = null;
        if (s.doomed) freeSurface(s);
    }
    c.draw = null;
    c.read = null;
    c.thread_key = 0;
    t.context = null;
    t.draw = null;
    t.read = null;
    t.display = null;
    t.gl = null;
    if (c.doomed) freeContext(c);
}

pub fn makeCurrent(handle: ?*anyopaque, draw_h: ?*anyopaque, read_h: ?*anyopaque, ctx_h: ?*anyopaque) bool {
    lock();
    defer unlock();
    const t = thread.mine() orelse return fail(bool, BAD_ALLOC, false);
    if (ctx_h == null) {
        if (draw_h != null or read_h != null) return fail(bool, BAD_MATCH, false);
        // (releasing needs no live display: EGL_NO_DISPLAY is allowed)
        if (handle != null and displayOf(handle) == null) return fail(bool, BAD_DISPLAY, false);
        release(t);
        return ok(bool, true);
    }
    const d = ready(handle) orelse return false;
    const c = contextOf(ctx_h, d) orelse return fail(bool, BAD_CONTEXT, false);
    if ((draw_h == null) != (read_h == null)) return fail(bool, BAD_MATCH, false);
    const draw: ?*Surface = if (draw_h) |h| (surfaceOf(h, d) orelse return fail(bool, BAD_SURFACE, false)) else null;
    const read: ?*Surface = if (read_h) |h| (surfaceOf(h, d) orelse return fail(bool, BAD_SURFACE, false)) else null;
    const me = thread.key();
    if (c.thread_key != 0 and c.thread_key != me) return failWhy(bool, BAD_ACCESS, false, "the context is current on another thread");
    for ([2]?*Surface{ draw, read }) |sp| {
        const s = sp orelse continue;
        if (s.ctx) |other| {
            // (another context's, unless that one is this thread's, which
            // this call lets go)
            if (other != c and other.thread_key != me) return failWhy(bool, BAD_ACCESS, false, "a surface is another thread's context's");
        }
        if (c.config) |cfg| {
            if (cfg.alpha != s.config.alpha) return failWhy(bool, BAD_MATCH, false, "the context's config and the surface's differ in alpha");
        }
    }
    if (t.context != @as(?*anyopaque, c)) release(t) else {
        // (the same context, perhaps other surfaces: the old ones let go)
        for ([2]?*Surface{ c.draw, c.read }) |sp| {
            const s = sp orelse continue;
            if (s != draw and s != read) s.ctx = null;
        }
    }
    c.draw = draw;
    c.read = read;
    if (draw) |s| s.ctx = c;
    if (read) |s| s.ctx = c;
    c.thread_key = me;
    t.context = c;
    t.draw = draw;
    t.read = read;
    t.display = d;
    t.gl = &c.gl;
    if (!bindSurfaces(c)) {
        release(t);
        return failWhy(bool, BAD_ALLOC, false, "no memory for the surface's buffers");
    }
    return ok(bool, true);
}

pub fn getCurrentContext() ?*anyopaque {
    const t = thread.get() orelse return null;
    return t.context;
}

pub fn getCurrentSurface(which: i32) ?*anyopaque {
    const t = thread.get() orelse return null;
    return switch (which) {
        DRAW => ok(?*anyopaque, t.draw),
        READ => ok(?*anyopaque, t.read),
        else => fail(?*anyopaque, BAD_PARAMETER, null),
    };
}

pub fn getCurrentDisplay() ?*anyopaque {
    const t = thread.get() orelse return null;
    return t.display;
}

pub fn releaseThread() bool {
    lock();
    defer unlock();
    const t = thread.get() orelse return true;
    release(t);
    t.egl_error = SUCCESS;
    t.api = OPENGL_ES_API;
    return true;
}

/// eglWaitClient and eglWaitGL: the current context's work done.
pub fn waitClient() bool {
    const t = thread.get() orelse return ok(bool, true);
    if (t.gl) |g| g.finish();
    return ok(bool, true);
}

// ── Swaps ──────────────────────────────────────────────────────────────────

/// eglSwapBuffers (damage: none) and eglSwapBuffersWithDamage.
pub fn swapBuffers(handle: ?*anyopaque, surface: ?*anyopaque, damage: []const [4]i32) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const s = surfaceOf(surface, d) orelse return fail(bool, BAD_SURFACE, false);
    const t = thread.get() orelse return fail(bool, BAD_SURFACE, false);
    const c: *Context = @ptrCast(@alignCast(t.context orelse return fail(bool, BAD_SURFACE, false)));
    if (c.draw != s) return fail(bool, BAD_SURFACE, false);
    if (s.kind == .pbuffer) return ok(bool, true);
    if (!s.win.swap(damage)) return fail(bool, BAD_NATIVE_WINDOW, false);
    // the context draws on the next back buffer
    if (!bindSurfaces(c)) return fail(bool, BAD_ALLOC, false);
    return ok(bool, true);
}

pub fn swapInterval(handle: ?*anyopaque, interval: i32) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const t = thread.get() orelse return fail(bool, BAD_CONTEXT, false);
    const sp = t.draw orelse return fail(bool, BAD_SURFACE, false);
    const s: *Surface = @ptrCast(@alignCast(sp));
    if (s.kind == .window) s.win.interval = @intCast(std.math.clamp(interval, 0, 1));
    return ok(bool, true);
}

// ── Syncs ──────────────────────────────────────────────────────────────────

pub const Sync = struct {
    used: bool = false,
    display: ?*Display = null,
    native: bool = false,
    mark: u64 = 0,
    /// a native fence handed in: its sync_file (owned), else -1
    fd: i32 = -1,
};

fn dropSync(s: *Sync) void {
    if (s.fd >= 0) driver.?.host.close(driver.?.host.ctx, s.fd);
    s.* = .{};
}

/// A handed-in fence's file readable (signalled) within timeout_ms: 1, 0,
/// or -errno.
fn pollFence(fd: i32, timeout_ms: i32) i32 {
    const h = driver.?.host;
    return h.poll(h.ctx, fd, timeout_ms);
}

var syncs: [MAX_SYNCS]Sync = undefined;

fn syncOf(handle: ?*anyopaque, d: *Display) ?*Sync {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&syncs[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(syncs)) or (p - base) % @sizeOf(Sync) != 0) return null;
    const s: *Sync = @ptrFromInt(p);
    return if (s.used and s.display == d) s else null;
}

/// eglCreateSync and eglCreateSyncKHR: EGL_SYNC_FENCE, after the current
/// context's work (it is flushed); EGL_SYNC_NATIVE_FENCE_ANDROID, the same
/// as a sync_file to hand out, or a sync_file handed in
/// (EGL_SYNC_NATIVE_FENCE_FD_ANDROID: the sync owns it from now on).
pub fn createSync(comptime T: type, handle: ?*anyopaque, ty: u32, attribs: ?[*]const T) ?*Sync {
    lock();
    defer unlock();
    const d = ready(handle) orelse return null;
    if (ty != SYNC_FENCE and ty != SYNC_NATIVE_FENCE_ANDROID) return fail(?*Sync, BAD_ATTRIBUTE, null);
    var fd: i32 = NO_NATIVE_FENCE_FD_ANDROID;
    if (attribs) |list| {
        var i: usize = 0;
        while (list[i] != NONE) : (i += 2) {
            if (ty == SYNC_NATIVE_FENCE_ANDROID and list[i] == SYNC_NATIVE_FENCE_FD_ANDROID) {
                fd = @intCast(list[i + 1]);
            } else return fail(?*Sync, BAD_ATTRIBUTE, null);
        }
    }
    const t = thread.get() orelse return fail(?*Sync, BAD_MATCH, null);
    if (t.display != @as(?*anyopaque, d) or t.context == null) return fail(?*Sync, BAD_MATCH, null);
    const s = for (&syncs) |*x| {
        if (!x.used) break x;
    } else return fail(?*Sync, BAD_ALLOC, null);
    if (fd >= 0) {
        s.* = .{ .used = true, .display = d, .native = true, .fd = fd };
    } else {
        s.* = .{ .used = true, .display = d, .native = ty == SYNC_NATIVE_FENCE_ANDROID, .mark = d.eng.?.mark() };
    }
    return ok(?*Sync, s);
}

/// eglDupNativeFenceFDANDROID: a new sync_file of a native fence, or
/// EGL_NO_NATIVE_FENCE_FD_ANDROID.
pub fn dupNativeFenceFd(handle: ?*anyopaque, sync: ?*anyopaque) i32 {
    lock();
    defer unlock();
    const d = ready(handle) orelse return NO_NATIVE_FENCE_FD_ANDROID;
    const s = syncOf(sync, d) orelse return fail(i32, BAD_PARAMETER, NO_NATIVE_FENCE_FD_ANDROID);
    if (!s.native) return fail(i32, BAD_PARAMETER, NO_NATIVE_FENCE_FD_ANDROID);
    const h = driver.?.host;
    if (s.fd >= 0) {
        const nfd = h.dup(h.ctx, s.fd);
        return if (nfd < 0) fail(i32, BAD_PARAMETER, NO_NATIVE_FENCE_FD_ANDROID) else ok(i32, nfd);
    }
    // (the last submission's fence: at or after the sync's, one ring)
    _ = d.eng.?.mark();
    const nfd = h.fenceFd(h.ctx);
    return if (nfd < 0) fail(i32, BAD_PARAMETER, NO_NATIVE_FENCE_FD_ANDROID) else ok(i32, @intCast(nfd));
}

pub fn destroySync(handle: ?*anyopaque, sync: ?*anyopaque) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const s = syncOf(sync, d) orelse return fail(bool, BAD_PARAMETER, false);
    dropSync(s);
    return ok(bool, true);
}

/// eglClientWaitSync: CONDITION_SATISFIED, TIMEOUT_EXPIRED, or FALSE.
/// The lock is not held while waiting.
pub fn clientWaitSync(handle: ?*anyopaque, sync: ?*anyopaque, flags: i32, timeout_ns: u64) i32 {
    lock();
    const d = ready(handle) orelse {
        unlock();
        return @intCast(FALSE);
    };
    const s = syncOf(sync, d) orelse {
        unlock();
        return fail(i32, BAD_PARAMETER, @intCast(FALSE));
    };
    const m = s.mark;
    const fd = s.fd;
    const eng = d.eng.?;
    unlock();
    if (flags & SYNC_FLUSH_COMMANDS_BIT != 0) {
        if (thread.gl()) |g| g.flush();
    }
    if (fd >= 0) {
        const ms: i32 = if (timeout_ns == FOREVER) -1 else @intCast(@min(timeout_ns / 1_000_000, std.math.maxInt(i32)));
        const r = pollFence(fd, ms);
        if (r < 0) return fail(i32, BAD_PARAMETER, @intCast(FALSE));
        return ok(i32, if (r > 0) CONDITION_SATISFIED else TIMEOUT_EXPIRED);
    }
    const us: u64 = if (timeout_ns == FOREVER) std.math.maxInt(u64) else timeout_ns / 1000;
    return ok(i32, if (eng.waitMark(m, us)) CONDITION_SATISFIED else TIMEOUT_EXPIRED);
}

/// eglWaitSync: the GPU's next work after the fence. Galaxy's GPU runs a
/// process's work in order on one ring, so nothing is waited for.
pub fn waitSync(handle: ?*anyopaque, sync: ?*anyopaque, flags: i32) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    _ = syncOf(sync, d) orelse return fail(bool, BAD_PARAMETER, false);
    if (flags != 0) return fail(bool, BAD_PARAMETER, false);
    return ok(bool, true);
}

pub fn getSyncAttrib(handle: ?*anyopaque, sync: ?*anyopaque, a: i32) ?i32 {
    lock();
    defer unlock();
    const d = ready(handle) orelse return null;
    const s = syncOf(sync, d) orelse return fail(?i32, BAD_PARAMETER, null);
    return switch (a) {
        SYNC_TYPE => ok(?i32, @intCast(if (s.native) SYNC_NATIVE_FENCE_ANDROID else SYNC_FENCE)),
        SYNC_STATUS => blk: {
            const done = if (s.fd >= 0) pollFence(s.fd, 0) > 0 else d.eng.?.markDone(s.mark);
            break :blk ok(?i32, if (done) SIGNALED else UNSIGNALED);
        },
        SYNC_CONDITION => ok(?i32, if (s.fd >= 0) SYNC_NATIVE_FENCE_SIGNALED_ANDROID else SYNC_PRIOR_COMMANDS_COMPLETE),
        else => fail(?i32, BAD_ATTRIBUTE, null),
    };
}

// ── Images (EGL_KHR_image_base, EGL_EXT_image_dma_buf_import) ─────────────

pub const EImage = struct {
    /// its handle valid (its memory may outlive it: GL's names hold it)
    alive: bool = false,
    display: ?*Display = null,
    img: Image = .{},
    shared: engine.Shared = .{},
};

var eimages: [MAX_IMAGES]EImage = undefined;

fn imageOf(handle: ?*anyopaque, d: *Display) ?*EImage {
    const m = imageAt(handle) orelse return null;
    return if (m.display == d) m else null;
}

fn imageAt(handle: ?*anyopaque) ?*EImage {
    const p = @intFromPtr(handle orelse return null);
    const base = @intFromPtr(&eimages[0]);
    if (p < base or p >= base + @sizeOf(@TypeOf(eimages)) or (p - base) % @sizeOf(EImage) != 0) return null;
    const m: *EImage = @ptrFromInt(p);
    return if (m.alive) m else null;
}

/// gles' look-up of an EGLImage handle (glEGLImageTarget*).
fn resolveImage(handle: ?*anyopaque) ?*Image {
    const m = imageAt(handle) orelse return null;
    return &m.img;
}

fn dropImage(m: *EImage) void {
    m.alive = false;
    // (the memory goes with the last of GL's names too)
    m.display.?.eng.?.freeImage(&m.img);
}

/// A dma-buf fourcc as the engine's format, and whether it has alpha.
fn fourccOf(f: u32) ?struct { format: engine.Format, alpha: bool } {
    return switch (f) {
        wayland.DRM_FORMAT_ARGB8888 => .{ .format = .bgra8, .alpha = true },
        wayland.DRM_FORMAT_XRGB8888 => .{ .format = .bgra8, .alpha = false },
        DRM_FORMAT_ABGR8888 => .{ .format = .rgba8, .alpha = true },
        DRM_FORMAT_XBGR8888 => .{ .format = .rgba8, .alpha = false },
        else => null,
    };
}

/// eglCreateImage and eglCreateImageKHR: EGL_LINUX_DMA_BUF_EXT, one plane.
/// The fd stays the caller's (the buffer is imported, not the file kept).
pub fn createImage(comptime T: type, handle: ?*anyopaque, ctx: ?*anyopaque, target: u32, buffer: ?*anyopaque, attribs: ?[*]const T) ?*EImage {
    lock();
    defer unlock();
    const d = ready(handle) orelse return null;
    if (target != LINUX_DMA_BUF_EXT or ctx != null or buffer != null) return fail(?*EImage, BAD_PARAMETER, null);
    var width: i64 = -1;
    var height: i64 = -1;
    var fourcc: i64 = -1;
    var fd: i64 = -1;
    var offset: i64 = -1;
    var pitch: i64 = -1;
    var mod_lo: ?u32 = null;
    var mod_hi: ?u32 = null;
    const list = attribs orelse return fail(?*EImage, BAD_PARAMETER, null);
    var i: usize = 0;
    while (list[i] != NONE) : (i += 2) {
        const v: i64 = @intCast(list[i + 1]);
        switch (@as(i32, @intCast(list[i]))) {
            WIDTH => width = v,
            HEIGHT => height = v,
            LINUX_DRM_FOURCC_EXT => fourcc = v,
            DMA_BUF_PLANE0_FD_EXT => fd = v,
            DMA_BUF_PLANE0_OFFSET_EXT => offset = v,
            DMA_BUF_PLANE0_PITCH_EXT => pitch = v,
            DMA_BUF_PLANE0_MODIFIER_LO_EXT => mod_lo = @truncate(@as(u64, @bitCast(v))),
            DMA_BUF_PLANE0_MODIFIER_HI_EXT => mod_hi = @truncate(@as(u64, @bitCast(v))),
            // (colour-space and siting hints: for YUV, which is not had)
            0x327B, 0x327C, 0x327D, 0x327E, IMAGE_PRESERVED_KHR => {},
            else => return fail(?*EImage, BAD_ATTRIBUTE, null),
        }
    }
    if (width < 0 or height < 0 or fourcc < 0 or fd < 0 or offset < 0 or pitch < 0) return fail(?*EImage, BAD_PARAMETER, null);
    const f = fourccOf(@truncate(@as(u64, @bitCast(fourcc)))) orelse return fail(?*EImage, BAD_MATCH, null);
    if ((mod_lo == null) != (mod_hi == null)) return fail(?*EImage, BAD_PARAMETER, null);
    if (mod_lo) |lo| {
        const m = @as(u64, mod_hi.?) << 32 | lo;
        if (m != 0 and m != MOD_INVALID) return fail(?*EImage, BAD_MATCH, null);
    }
    if (width == 0 or height == 0 or width > MAX_SIZE or height > MAX_SIZE) return fail(?*EImage, BAD_PARAMETER, null);
    if (pitch < width * 4 or @mod(pitch, 4) != 0 or @mod(offset, 4) != 0) return fail(?*EImage, BAD_ACCESS, null);
    const slot = for (&eimages) |*x| {
        if (!x.alive and x.shared.refs == 0) break x;
    } else return fail(?*EImage, BAD_ALLOC, null);
    const h = driver.?.host;
    const whole = h.importFd(h.ctx, @intCast(fd)) orelse return fail(?*EImage, BAD_PARAMETER, null);
    slot.* = .{ .alive = true, .display = d };
    const need = offset + pitch * (height - 1) + width * 4;
    if (need > @as(i64, @intCast(whole.bytes))) {
        // (the import goes again: a picture larger than its buffer)
        slot.img = engine.adopt(&slot.shared, whole, 0, 1, 1, 4, f.format);
        dropImage(slot);
        return fail(?*EImage, BAD_ACCESS, null);
    }
    slot.img = engine.adopt(&slot.shared, whole, @intCast(offset), @intCast(width), @intCast(height), @intCast(pitch), f.format);
    slot.img.no_alpha = !f.alpha;
    return ok(?*EImage, slot);
}

pub fn destroyImage(handle: ?*anyopaque, image: ?*anyopaque) bool {
    lock();
    defer unlock();
    const d = ready(handle) orelse return false;
    const m = imageOf(image, d) orelse return fail(bool, BAD_PARAMETER, false);
    dropImage(m);
    return ok(bool, true);
}

/// eglQueryDmaBufFormatsEXT: the fourccs an image takes.
pub fn queryDmaBufFormats(handle: ?*anyopaque, max: i32, formats: ?[*]i32, num: ?*i32) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const n = num orelse return fail(bool, BAD_PARAMETER, false);
    if (max < 0 or (max > 0 and formats == null)) return fail(bool, BAD_PARAMETER, false);
    const k: usize = if (max == 0) dma_buf_formats.len else @min(dma_buf_formats.len, @as(usize, @intCast(max)));
    if (max > 0) {
        for (0..k) |i| formats.?[i] = @bitCast(dma_buf_formats[i]);
    }
    n.* = @intCast(k);
    return ok(bool, true);
}

/// eglQueryDmaBufModifiersEXT: linear only, for every format; none
/// external only.
pub fn queryDmaBufModifiers(handle: ?*anyopaque, format: i32, max: i32, modifiers: ?[*]u64, external_only: ?[*]u32, num: ?*i32) bool {
    lock();
    defer unlock();
    _ = ready(handle) orelse return false;
    const n = num orelse return fail(bool, BAD_PARAMETER, false);
    if (fourccOf(@bitCast(format)) == null) return fail(bool, BAD_PARAMETER, false);
    if (max < 0 or (max > 0 and modifiers == null)) return fail(bool, BAD_PARAMETER, false);
    if (max > 0) {
        modifiers.?[0] = 0;
        if (external_only) |e| e[0] = FALSE;
    }
    n.* = 1;
    return ok(bool, true);
}
