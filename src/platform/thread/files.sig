// Temp file helpers and time utilities for background workers
// Layer 1: Platform

const w32 = @import("win32");

/// Build a temp file path: cache/_bf{slot_id}_{worker_id}.tmp as UTF-16.
/// Slot ID isolates concurrent backfills; worker ID isolates threads within a job.
/// Returns length of the path (excluding null terminator).
pub fn buildTempPath(out: *[64]u16, slot_id: u8, worker_id: usize) usize {
    const prefix = "cache/_bf";
    const ext = ".tmp";
    var pos: usize = 0;
    for (prefix) |c| {
        out[pos] = c;
        pos += 1;
    }
    out[pos] = '0' + slot_id;
    pos += 1;
    out[pos] = '_';
    pos += 1;
    if (worker_id < 10) {
        out[pos] = @intCast('0' + worker_id);
        pos += 1;
    } else {
        out[pos] = @intCast('0' + worker_id / 10);
        pos += 1;
        out[pos] = @intCast('0' + worker_id % 10);
        pos += 1;
    }
    for (ext) |c| {
        out[pos] = c;
        pos += 1;
    }
    out[pos] = 0;
    return pos;
}

/// Create a temp file for read/write. Returns INVALID_HANDLE_VALUE on failure.
pub fn createTempFile(slot_id: u8, worker_id: usize) w32.HANDLE {
    var path: [64]u16 = undefined;
    const len = buildTempPath(&path, slot_id, worker_id);
    if (len == 0) return w32.INVALID_HANDLE_VALUE;
    return w32.CreateFileW(
        @ptrCast(path[0..len :0]),
        w32.GENERIC_READ | w32.GENERIC_WRITE,
        0,
        null,
        w32.CREATE_ALWAYS,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
}

/// Delete temp files for workers 0..count-1.
pub fn deleteTempFiles(slot_id: u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var path: [64]u16 = undefined;
        const len = buildTempPath(&path, slot_id, i);
        if (len > 0) _ = w32.DeleteFileW(@ptrCast(path[0..len :0]));
    }
}

/// Get current time in milliseconds (Unix epoch).
pub fn currentTimeMs() i64 {
    var ft: w32.FILETIME = .{};
    w32.GetSystemTimeAsFileTime(&ft);
    const ft64: u64 = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
    const unix_100ns = ft64 -% 116444736000000000;
    return @intCast(unix_100ns / 10000);
}

/// Get current time in seconds (Unix epoch).
pub fn currentTimeSec() i64 {
    var ft: w32.FILETIME = .{};
    w32.GetSystemTimeAsFileTime(&ft);
    const ft64: u64 = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
    const unix_100ns = ft64 -% 116444736000000000;
    return @intCast(unix_100ns / 10000000);
}
