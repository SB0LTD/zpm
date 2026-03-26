// DataManager — virtualized candle view over cache + live tail
// Layer 0: Foundation
//
// The cache file on disk IS the primary data store. DataManager reads
// only the visible window on demand (seek + read), then appends any
// unflushed live candles from a small ring buffer.
//
// For display TF > 1m, the visible 1m range is read from cache and
// aggregated on the fly. Only the rendered candles exist in memory.
//
// Total candle count (for scroll clamping) is computed from:
//   cache_count (disk, at display TF) + live_count (in-memory ring)

const ChartState = @import("../types.zig").ChartState;
const t = @import("types.zig");
const OHLCV = t.OHLCV;
const cache_reader = @import("cache_reader.zig");

// Re-export public types and constants
pub const MAX_VISIBLE = t.MAX_VISIBLE;
pub const LIVE_CAP = t.LIVE_CAP;
pub const ReadFn = t.ReadFn;

pub const DataManager = struct {
    // ── Cache-backed storage ────────────────────────────────
    cache_path: [128]u16 = [_]u16{0} ** 128,
    cache_valid: bool = false,
    cache_1m_count: usize = 0,
    period_secs: i64 = 60,
    cache_display_count: usize = 0,

    // ── Live ring buffer (unflushed candles) ────────────
    live: [LIVE_CAP]OHLCV = undefined,
    live_head: usize = 0,
    live_len: usize = 0,

    // ── Extraction buffer ────────────────────────────────────
    visible: [MAX_VISIBLE]OHLCV = undefined,

    // ── Cache read function pointer (keeps Layer 0 pure) ────
    read_fn: ?ReadFn = null,

    /// Total candles at display timeframe (cache + live)
    pub fn totalCandles(self: *const DataManager) usize {
        return self.cache_display_count + self.live_len;
    }

    /// Push a completed display-TF candle into the live ring.
    pub fn pushCandle(self: *DataManager, candle: OHLCV) void {
        self.live[self.live_head] = candle;
        self.live_head = (self.live_head + 1) % LIVE_CAP;
        if (self.live_len < LIVE_CAP) self.live_len += 1;
    }

    /// Update the most recent candle in-place (live in-progress candle).
    pub fn updateLast(self: *DataManager, candle: OHLCV) void {
        if (self.live_len == 0) {
            self.pushCandle(candle);
            return;
        }
        const idx = if (self.live_head == 0) LIVE_CAP - 1 else self.live_head - 1;
        self.live[idx] = candle;
    }

    /// Push a batch of display-TF candles into the live ring.
    pub fn pushBatch(self: *DataManager, batch: []const OHLCV) void {
        for (batch) |c| self.pushCandle(c);
    }

    /// Get a candle from the live ring at logical index (0 = oldest).
    fn liveGet(self: *const DataManager, idx: usize) OHLCV {
        if (idx >= self.live_len) return .{};
        const actual = if (self.live_len < LIVE_CAP)
            idx
        else
            (self.live_head + idx) % LIVE_CAP;
        return self.live[actual];
    }

    /// Last candle's close price (from live ring, or 0).
    pub fn lastPrice(self: *const DataManager) f64 {
        if (self.live_len > 0) {
            return self.liveGet(self.live_len - 1).close;
        }
        if (self.cache_valid and self.cache_1m_count > 0) {
            if (self.read_fn) |readRange| {
                var buf: [1]OHLCV = undefined;
                const n = readRange(&self.cache_path, self.cache_1m_count - 1, &buf);
                if (n > 0) return buf[0].close;
            }
        }
        return 0;
    }

    /// Extract the visible slice for rendering. Reads from cache on demand.
    /// This is the hot path — called once per frame.
    pub fn sliceVisible(self: *DataManager, state: *ChartState) []const OHLCV {
        const total = self.totalCandles();
        state.clampScroll(total);
        const range = state.visibleRange(total);
        if (range.count == 0) return self.visible[0..0];

        var out_count: usize = 0;

        const cache_end = self.cache_display_count;
        const vis_start = range.start;
        const vis_end = range.start + range.count;

        // Part 1: candles from cache
        if (vis_start < cache_end) {
            const cache_vis_end = @min(vis_end, cache_end);
            const cache_vis_count = cache_vis_end - vis_start;
            if (self.read_fn) |rf| {
                out_count = cache_reader.readCacheWindow(
                    &self.visible,
                    rf,
                    &self.cache_path,
                    self.cache_1m_count,
                    self.period_secs,
                    vis_start,
                    cache_vis_count,
                );
            }
        }

        // Part 2: candles from live ring
        if (vis_end > cache_end) {
            const live_start = if (vis_start > cache_end) vis_start - cache_end else 0;
            const live_end = vis_end - cache_end;
            const live_count = @min(live_end - live_start, MAX_VISIBLE - out_count);
            var i: usize = 0;
            while (i < live_count) : (i += 1) {
                self.visible[out_count] = self.liveGet(live_start + i);
                out_count += 1;
            }
        }

        return self.visible[0..out_count];
    }

    /// Recompute cache_display_count from cache_1m_count and period.
    pub fn refreshCacheCounts(self: *DataManager) void {
        if (self.period_secs <= 60) {
            self.cache_display_count = self.cache_1m_count;
        } else {
            const mins_per: usize = @intCast(@divTrunc(self.period_secs, 60));
            self.cache_display_count = if (mins_per > 0) (self.cache_1m_count + mins_per - 1) / mins_per else self.cache_1m_count;
        }
    }

    /// Bind a cache file. Called by slot on startup/restart.
    pub fn bindCache(self: *DataManager, path: *const [128]u16, read_fn: ReadFn) void {
        @memcpy(&self.cache_path, path);
        self.cache_valid = true;
        self.read_fn = read_fn;
        self.reloadCacheCount();
    }

    /// Re-read the total 1m count from disk and recompute display count.
    pub fn reloadCacheCount(self: *DataManager) void {
        if (!self.cache_valid) return;
        self.refreshCacheCounts();
    }

    /// Return visible 1m candles for inner-candle rendering (when display TF > 1m).
    /// Caller provides the output buffer (avoids embedding a large buffer in every DataManager).
    pub fn visibleRaw1m(self: *DataManager, state: *const ChartState, out: []OHLCV) []const OHLCV {
        if (self.period_secs <= 60) return out[0..0];
        const readRange = self.read_fn orelse return out[0..0];
        if (!self.cache_valid or self.cache_1m_count == 0) return out[0..0];

        const total = self.totalCandles();
        const range = state.visibleRange(total);
        if (range.count == 0) return out[0..0];

        const cache_end = self.cache_display_count;
        if (range.start >= cache_end) return out[0..0];

        const vis_cache_end = @min(range.start + range.count, cache_end);
        const mins_per: usize = @intCast(@divTrunc(self.period_secs, 60));
        const m1_start = range.start * mins_per;
        const m1_count = @min((vis_cache_end - range.start) * mins_per, out.len);
        const m1_capped = @min(m1_count, self.cache_1m_count -| m1_start);

        return out[0..readRange(&self.cache_path, m1_start, out[0..m1_capped])];
    }

    pub fn clear(self: *DataManager) void {
        self.live_head = 0;
        self.live_len = 0;
        self.cache_1m_count = 0;
        self.cache_display_count = 0;
    }
};
