// Candle aggregation — derive any timeframe from 1m candles
// Layer 0: Foundation — pure math, no I/O, no platform deps
//
// Takes a chronologically sorted slice of 1m OHLCV candles and a target
// period in minutes. Groups candles by aligned time boundaries and merges
// each group into one output candle:
//   open  = first candle's open
//   high  = max of all highs
//   low   = min of all lows
//   close = last candle's close
//   volume = sum of all volumes
//   timestamp = period boundary (floored)
//
// This is lossless — higher timeframes are mathematically exact
// reconstructions from 1m data.

const OHLCV = @import("types.zig").OHLCV;

/// Max output candles from a single aggregation call
pub const MAX_OUT = 4096;

/// Convert a canonical timeframe string to period in seconds.
/// Returns 0 for unrecognized timeframes.
pub fn timeframeSecs(tf: []const u8) i64 {
    if (tf.len == 0) return 0;
    // Parse number prefix
    var num: i64 = 0;
    var i: usize = 0;
    while (i < tf.len and tf[i] >= '0' and tf[i] <= '9') : (i += 1) {
        num = num * 10 + (tf[i] - '0');
    }
    if (num == 0) num = 1;
    if (i >= tf.len) return 0;
    return switch (tf[i]) {
        'm' => num * 60,
        'h' => num * 3600,
        'd' => num * 86400,
        'w' => num * 604800,
        'M' => num * 2592000, // ~30 days, approximate
        else => 0,
    };
}

/// Aggregate 1m candles into a target timeframe.
///
/// `src` must be chronologically sorted 1m candles.
/// `period_secs` is the target candle duration in seconds (e.g. 300 for 5m).
/// Writes aggregated candles into `out`, returns the count written.
///
/// If period_secs <= 60 (1m or less), copies src directly (no aggregation needed).
pub fn aggregate(src: []const OHLCV, period_secs: i64, out: []OHLCV) usize {
    if (src.len == 0) return 0;
    if (period_secs <= 60) {
        // 1m or sub-minute — just copy
        const n = @min(src.len, out.len);
        for (src[0..n], 0..) |c, idx| {
            out[idx] = c;
        }
        return n;
    }

    var count: usize = 0;
    var cur: OHLCV = undefined;
    var cur_boundary: i64 = 0;
    var in_candle = false;

    for (src) |c| {
        const boundary = alignTimestamp(c.timestamp, period_secs);

        if (!in_candle or boundary != cur_boundary) {
            // Emit previous candle
            if (in_candle and count < out.len) {
                out[count] = cur;
                count += 1;
            }
            // Start new candle
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
            // Merge into current candle
            if (c.high > cur.high) cur.high = c.high;
            if (c.low < cur.low) cur.low = c.low;
            cur.close = c.close;
            cur.volume += c.volume;
        }
    }

    // Emit last candle
    if (in_candle and count < out.len) {
        out[count] = cur;
        count += 1;
    }

    return count;
}

/// Align a timestamp to the start of its period boundary.
/// E.g. for 5m (300s): timestamp 1000 → 900, timestamp 1200 → 1200.
pub fn alignTimestamp(ts: i64, period_secs: i64) i64 {
    if (period_secs <= 0) return ts;
    return @divTrunc(ts, period_secs) * period_secs;
}
