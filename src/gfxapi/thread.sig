//! @zpm/gfxapi thread — what EGL and GL keep per thread: the current
//! context and surfaces, EGL's last error, the bound API.
//!
//! A fixed table keyed by the thread pointer (TPIDR_EL0 on AArch64, the
//! TCB at %fs:0 on x86-64; the thread id elsewhere): no thread-local
//! storage, so the library works whichever C library loaded it, and a GL
//! call finds its context in a few loads. A thread's slot stays its own
//! once taken (MAX_THREADS threads may ever use EGL); only that thread
//! writes it.

const std = @import("std");
const builtin = @import("builtin");
const gles = @import("gles.sig");

pub const MAX_THREADS = 256;

/// EGL's EGL_SUCCESS and EGL_OPENGL_ES_API (egl.sig has the rest).
const EGL_SUCCESS: i32 = 0x3000;
const EGL_OPENGL_ES_API: u32 = 0x30A0;

pub const Thread = struct {
    /// GL's current context (what every gl* call works on)
    gl: ?*gles.Context = null,
    /// EGL's: the current context, its draw and read surfaces, their
    /// display (egl.sig's objects)
    context: ?*anyopaque = null,
    draw: ?*anyopaque = null,
    read: ?*anyopaque = null,
    display: ?*anyopaque = null,
    /// eglGetError's (EGL_SUCCESS after each call that succeeds)
    egl_error: i32 = EGL_SUCCESS,
    api: u32 = EGL_OPENGL_ES_API,
};

var keys: [MAX_THREADS]std.atomic.Value(usize) = [_]std.atomic.Value(usize){.init(0)} ** MAX_THREADS;
var threads: [MAX_THREADS]Thread = [_]Thread{.{}} ** MAX_THREADS;

/// The calling thread's key: never 0 (bit 0 set; thread pointers are
/// aligned).
pub fn key() usize {
    const on_linux = comptime builtin.os.tag == .linux;
    if (comptime on_linux and builtin.cpu.arch == .aarch64) {
        return asm volatile ("mrs %[r], tpidr_el0"
            : [r] "=r" (-> usize),
        ) | 1;
    } else if (comptime on_linux and builtin.cpu.arch == .x86_64) {
        return asm volatile ("movq %%fs:0, %[r]"
            : [r] "=r" (-> usize),
        ) | 1;
    } else {
        return (@as(usize, std.Thread.getCurrentId()) << 1) | 1;
    }
}

/// The slot of key `k` (taken now with `claim`), or null.
fn slotOf(k: usize, claim: bool) ?usize {
    var i = (k >> 4) % MAX_THREADS;
    for (0..MAX_THREADS) |_| {
        const have = keys[i].load(.acquire);
        if (have == k) return i;
        if (have == 0) {
            if (!claim) return null;
            // (only this thread takes its own key: a lost race is another
            // thread's key, and the probe goes on)
            if (keys[i].cmpxchgStrong(0, k, .acq_rel, .acquire) == null) return i;
        }
        i = (i + 1) % MAX_THREADS;
    }
    return null;
}

/// The calling thread's state, if it has any yet.
pub fn get() ?*Thread {
    const i = slotOf(key(), false) orelse return null;
    return &threads[i];
}

/// The calling thread's state, taken now if need be; null only when
/// MAX_THREADS threads have slots (EGL_BAD_ALLOC).
pub fn mine() ?*Thread {
    const i = slotOf(key(), true) orelse return null;
    return &threads[i];
}

/// GL's current context on this thread.
pub inline fn gl() ?*gles.Context {
    const t = get() orelse return null;
    return t.gl;
}

test "thread: each thread's slot is its own" {
    const a: usize = 0x7000_1001;
    const b: usize = a + (MAX_THREADS << 4); // (the same first slot)
    const sa = slotOf(a, true).?;
    const sb = slotOf(b, true).?;
    try std.testing.expect(sa != sb);
    try std.testing.expectEqual(sa, slotOf(a, false).?);
    try std.testing.expectEqual(sb, slotOf(b, false).?);
    try std.testing.expect(slotOf(0x5555_0001, false) == null);
    try std.testing.expect(key() & 1 == 1);
    const t = mine().?;
    try std.testing.expectEqual(t, get().?);
    try std.testing.expectEqual(EGL_SUCCESS, t.egl_error);
}
