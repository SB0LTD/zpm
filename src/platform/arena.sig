//! arena — a single OS-backed bump arena (Layer 1: platform).
//!
//! This is NOT a general-purpose allocator. It is a ONE-SHOT reservation of a
//! fixed region of pages from the OS (VirtualAlloc), handed out as fixed,
//! aligned sub-slices by a monotonic bump pointer. Nothing is ever individually
//! freed — the whole region is released at shutdown (deinit). That is exactly
//! the "reserve fixed storage up front, no per-object lifetime management"
//! discipline used everywhere else; the only thing it changes is WHERE the
//! bytes live: committed heap pages instead of the executable's .bss image.
//!
//! Why it exists: large fixed scratch buffers (e.g. per-worker candle windows,
//! tens of MB each × many workers) baked into static .bss make the PE image so
//! large the Windows loader refuses to start it ("not a valid Win32
//! application"). The same buffers carved from an arena keep the exe small and
//! impose no size ceiling beyond available RAM.
//!
//! Usage:
//!   var a = arena.reserve(total_bytes) orelse return error.OutOfMemory;
//!   defer a.deinit();
//!   const buf: []OHLCV = a.alloc(OHLCV, 1_200_000) orelse return error....;

const w32 = @import("win32");

pub const Arena = struct {
    base: [*]u8 = undefined,
    cap: usize = 0,
    used: usize = 0,

    /// Bump-allocate `n` values of type `T`, aligned to @alignOf(T). Returns a
    /// slice into the arena, or null if the reservation is exhausted. The memory
    /// is zeroed (VirtualAlloc/MEM_COMMIT pages start zeroed) on first use.
    pub fn alloc(self: *Arena, comptime T: type, n: usize) ?[]T {
        const a = @alignOf(T);
        const start = alignUp(self.used, a);
        const bytes = n * @sizeOf(T);
        if (start + bytes > self.cap) return null;
        self.used = start + bytes;
        const ptr: [*]T = @ptrCast(@alignCast(self.base + start));
        return ptr[0..n];
    }

    /// Bytes still available for further allocations.
    pub fn remaining(self: *const Arena) usize {
        return self.cap - self.used;
    }

    /// Release the entire reservation back to the OS. All slices handed out by
    /// this arena become invalid.
    pub fn deinit(self: *Arena) void {
        if (self.cap != 0) {
            _ = w32.VirtualFree(@ptrCast(self.base), 0, w32.MEM_RELEASE);
            self.base = undefined;
            self.cap = 0;
            self.used = 0;
        }
    }
};

/// Reserve and commit `bytes` of zeroed pages from the OS. Returns null if the
/// OS can't satisfy the request. The region is owned by the returned Arena and
/// must be released with deinit().
pub fn reserve(bytes: usize) ?Arena {
    if (bytes == 0) return Arena{};
    const p = w32.VirtualAlloc(null, bytes, w32.MEM_COMMIT | w32.MEM_RESERVE, w32.PAGE_READWRITE) orelse return null;
    return Arena{ .base = @ptrCast(p), .cap = bytes, .used = 0 };
}

fn alignUp(addr: usize, alignment: usize) usize {
    if (alignment <= 1) return addr;
    return (addr + alignment - 1) & ~(alignment - 1);
}
