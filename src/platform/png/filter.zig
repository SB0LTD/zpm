// PNG row filters — adaptive per-row filter selection
// Layer 1: Platform (internal to png/ module)
//
// Implements all five PNG filter types (None, Sub, Up, Average, Paeth)
// and selects the best one per row using minimum sum of absolute values.

pub const FilterType = enum(u8) { none = 0, sub = 1, up = 2, average = 3, paeth = 4 };

fn paethPredictor(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = if (p > a) p - a else a - p;
    const pb = if (p > b) p - b else b - p;
    const pc = if (p > c) p - c else c - p;
    if (pa <= pb and pa <= pc) return @intCast(@as(u16, @bitCast(a)));
    if (pb <= pc) return @intCast(@as(u16, @bitCast(b)));
    return @intCast(@as(u16, @bitCast(c)));
}

/// Apply a filter to a row. `bpp` is bytes per pixel.
/// `raw` is the current row, `prev` is the previous row (or null for first row).
/// Result written to `out` (length = raw.len).
pub fn applyFilter(
    filter: FilterType,
    raw: []const u8,
    prev: ?[]const u8,
    bpp: usize,
    out: []u8,
) void {
    const n = raw.len;
    switch (filter) {
        .none => @memcpy(out[0..n], raw),
        .sub => {
            for (0..n) |i| {
                const a: u8 = if (i >= bpp) raw[i - bpp] else 0;
                out[i] = raw[i] -% a;
            }
        },
        .up => {
            for (0..n) |i| {
                const b: u8 = if (prev) |p| p[i] else 0;
                out[i] = raw[i] -% b;
            }
        },
        .average => {
            for (0..n) |i| {
                const a: u16 = if (i >= bpp) raw[i - bpp] else 0;
                const b: u16 = if (prev) |p| p[i] else 0;
                out[i] = raw[i] -% @as(u8, @intCast((a + b) / 2));
            }
        },
        .paeth => {
            for (0..n) |i| {
                const a: i16 = if (i >= bpp) raw[i - bpp] else 0;
                const b: i16 = if (prev) |p| p[i] else 0;
                const c: i16 = if (i >= bpp) (if (prev) |p| @as(i16, p[i - bpp]) else 0) else 0;
                out[i] = raw[i] -% paethPredictor(a, b, c);
            }
        },
    }
}

/// Select the best filter for a row using minimum sum of absolute values heuristic.
pub fn selectFilter(raw: []const u8, prev: ?[]const u8, bpp: usize, filtered: []u8) FilterType {
    const filters = [_]FilterType{ .none, .sub, .up, .average, .paeth };
    var best_filter: FilterType = .none;
    var best_sum: u64 = ~@as(u64, 0);
    var temp: [3840 * 3 + 4]u8 = undefined;

    for (filters) |f| {
        applyFilter(f, raw, prev, bpp, temp[0..raw.len]);
        var sum: u64 = 0;
        for (temp[0..raw.len]) |b| {
            const signed: i8 = @bitCast(b);
            sum += if (signed < 0) @as(u64, @intCast(-@as(i16, signed))) else @as(u64, @intCast(signed));
        }
        if (sum < best_sum) {
            best_sum = sum;
            best_filter = f;
        }
    }

    applyFilter(best_filter, raw, prev, bpp, filtered);
    return best_filter;
}
