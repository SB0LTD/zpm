//! @zpm/gfxapi host — what EGL asks of the process it is loaded into,
//! beyond the GPU itself: dma-bufs out (a window's frames) and in
//! (EGLImages), fence files (EGL_ANDROID_native_fence_sync), and a file
//! mapped (zwp_linux_dmabuf_v1's format table). The library's root gives
//! Linux's system calls and Galaxy's render node; tests give their own.

const gpu = @import("gpu");

pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// A buffer of GPU memory as a dma-buf fd, or -errno.
    exportFd: *const fn (?*anyopaque, gpu.Buffer) i64,
    /// A dma-buf mapped for the GPU and the CPU (the whole of it; the fd
    /// stays the caller's), or null. Freed as any of the device's buffers.
    importFd: *const fn (?*anyopaque, i32) ?gpu.Buffer,
    /// A sync_file of everything submitted so far, or -errno.
    fenceFd: *const fn (?*anyopaque) i64,
    close: *const fn (?*anyopaque, i32) void,
    /// A new fd for the same file (close-on-exec), or -errno.
    dup: *const fn (?*anyopaque, i32) i32,
    /// fd readable (a sync_file: signalled) within timeout_ms (-1: no
    /// limit): 1, 0 when it ran out, -errno.
    poll: *const fn (?*anyopaque, i32, i32) i32,
    /// `size` bytes of fd, mapped read only, or null.
    map: *const fn (?*anyopaque, i32, usize) ?[]const u8,
    unmap: *const fn (?*anyopaque, []const u8) void,
};
