// RingLog — fixed-size in-memory log ring buffer
// Layer 0: Foundation — pure data, no I/O, no rendering
//
// Lock-free MPSC ring buffer. Multiple threads push entries via
// atomic index increment. The debug console reads with tolerance
// for partially-written entries (len written last as commit).
//
// This is a sink — log.zig formats once, then calls push().

pub const MAX_ENTRIES = 256;
pub const MAX_LINE = 128;

pub const Entry = struct {
    buf: [MAX_LINE]u8 = [_]u8{0} ** MAX_LINE,
    /// Written last — acts as commit flag. Reader skips if 0.
    len: u8 = 0,
    level: u8 = 0,
};

/// Global ring buffer — written by log.zig, read by debug console.
pub var entries: [MAX_ENTRIES]Entry = [_]Entry{.{}} ** MAX_ENTRIES;

/// Monotonic write cursor. Always increments; readers use modulo.
pub var write_pos: u32 = 0;

/// Push a formatted log line into the ring buffer.
/// Thread-safe: each caller atomically claims a slot, writes payload,
/// then commits by storing len last with release semantics.
pub fn push(level: u8, line: []const u8) void {
    const idx = @atomicRmw(u32, &write_pos, .Add, 1, .acq_rel);
    const slot = idx % MAX_ENTRIES;
    const n: u8 = @intCast(@min(line.len, MAX_LINE));
    // Zero len first to mark slot as in-progress for any concurrent reader
    @atomicStore(u8, &entries[slot].len, 0, .release);
    entries[slot].level = level;
    @memcpy(entries[slot].buf[0..n], line[0..n]);
    // Commit: store len last so readers see complete data
    @atomicStore(u8, &entries[slot].len, n, .release);
}
