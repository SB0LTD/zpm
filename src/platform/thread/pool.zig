// Thread pool primitives — chunk ranges, launch, join
// Layer 1: Platform

const w32 = @import("win32");
const MAX_WORKERS = @import("workers.zig").MAX_WORKERS;

/// A non-overlapping range for a single worker to process.
pub const ChunkRange = struct {
    start: i64, // inclusive
    end: i64, // exclusive
};

/// Divide a range [start, end) into N non-overlapping chunks.
/// Returns actual chunk count (may be less than N if range is tiny).
pub fn divideRange(
    start: i64,
    end: i64,
    n: usize,
    out: *[MAX_WORKERS]ChunkRange,
) usize {
    if (n == 0 or start >= end) return 0;
    const count = @min(n, MAX_WORKERS);
    const total = end - start;
    const chunk_size = @divTrunc(total, @as(i64, @intCast(count)));
    if (chunk_size <= 0) {
        out[0] = .{ .start = start, .end = end };
        return 1;
    }
    var actual: usize = 0;
    var cursor = start;
    while (actual < count and cursor < end) {
        const chunk_end = if (actual == count - 1) end else cursor + chunk_size;
        out[actual] = .{ .start = cursor, .end = chunk_end };
        cursor = chunk_end;
        actual += 1;
    }
    return actual;
}

/// Launch `count` threads, each calling `entry` with the corresponding element of `contexts`.
/// Thread handles are written to `handles`. Returns number of threads actually launched.
pub fn launchThreads(
    count: usize,
    entry: *const fn (?*anyopaque) callconv(.c) w32.DWORD,
    contexts: [*]*anyopaque,
    handles: *[MAX_WORKERS]w32.THREAD_HANDLE,
) usize {
    var launched: usize = 0;
    while (launched < count) : (launched += 1) {
        handles[launched] = w32.CreateThread(
            null,
            0,
            entry,
            contexts[launched],
            0,
            null,
        );
        if (handles[launched] == null) break;
    }
    return launched;
}

/// Wait for all threads to complete (with timeout in ms), then close handles.
pub fn joinAll(handles: *[MAX_WORKERS]w32.THREAD_HANDLE, count: usize, timeout_ms: u32) void {
    if (count > 0) {
        _ = w32.WaitForMultipleObjects(
            @intCast(count),
            @ptrCast(handles),
            1, // wait all
            timeout_ms,
        );
    }
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (handles[i]) |t| {
            _ = w32.CloseHandle(@ptrCast(t));
            handles[i] = null;
        }
    }
}
