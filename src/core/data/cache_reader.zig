// Cache-backed reading with on-the-fly aggregation
// Layer 0: Foundation
//
// Reads display-TF candles from cache for the visible window.
// For 1m: direct read. For higher TF: streams 1m chunks and aggregates.

const t = @import("types.zig");
const OHLCV = t.OHLCV;
const aggregator = @import("../aggregator.zig");

/// Read display-TF candles from cache into `visible` buffer.
/// For 1m: direct read. For higher TF: stream 1m chunks and aggregate.
pub fn readCacheWindow(
    visible: []OHLCV,
    read_fn: t.ReadFn,
    cache_path: *const [128]u16,
    cache_1m_count: usize,
    period_secs: i64,
    start: usize,
    count: usize,
) usize {
    if (cache_1m_count == 0) return 0;

    const to_read = @min(count, t.MAX_VISIBLE);

    if (period_secs <= 60) {
        // 1m display — direct read from cache
        return read_fn(cache_path, start, visible[0..to_read]);
    }

    // Higher TF — stream 1m records in chunks and aggregate incrementally.
    // Each display candle spans (period_secs / 60) 1m records.
    const mins_per_candle: usize = @intCast(@divTrunc(period_secs, 60));
    const m1_start = start * mins_per_candle;
    const m1_total = @min(to_read * mins_per_candle, cache_1m_count -| m1_start);
    if (m1_total == 0) return 0;

    var out_count: usize = 0;
    var m1_offset: usize = 0;

    // Running aggregation state
    var cur: OHLCV = undefined;
    var cur_boundary: i64 = 0;
    var in_candle = false;

    while (m1_offset < m1_total and out_count < to_read) {
        var chunk: [t.CHUNK_SIZE]OHLCV = undefined;
        const want = @min(m1_total - m1_offset, t.CHUNK_SIZE);
        const got = read_fn(cache_path, m1_start + m1_offset, chunk[0..want]);
        if (got == 0) break;

        for (chunk[0..got]) |c| {
            const boundary = aggregator.alignTimestamp(c.timestamp, period_secs);
            if (!in_candle or boundary != cur_boundary) {
                if (in_candle and out_count < to_read) {
                    visible[out_count] = cur;
                    out_count += 1;
                }
                cur = .{
                    .timestamp = boundary,
                    .open = c.open,
                    .high = c.high,
                    .low = c.low,
                    .close = c.close,
                    .volume = c.volume,
                };
                cur_boundary = boundary;
                in_candle = true;
            } else {
                if (c.high > cur.high) cur.high = c.high;
                if (c.low < cur.low) cur.low = c.low;
                cur.close = c.close;
                cur.volume += c.volume;
            }
        }
        m1_offset += got;
    }

    // Emit last aggregated candle
    if (in_candle and out_count < to_read) {
        visible[out_count] = cur;
        out_count += 1;
    }

    return out_count;
}
