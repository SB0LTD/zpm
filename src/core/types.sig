// Core trading data types — pure data, no I/O, no rendering
// Layer 0: Foundation

/// A single OHLCV candlestick
pub const OHLCV = struct {
    timestamp: i64 = 0,
    open: f64 = 0,
    high: f64 = 0,
    low: f64 = 0,
    close: f64 = 0,
    volume: f64 = 0,

    pub fn isBullish(self: *const OHLCV) bool {
        return self.close > self.open;
    }

    pub fn bodyHigh(self: *const OHLCV) f64 {
        return @max(self.open, self.close);
    }

    pub fn bodyLow(self: *const OHLCV) f64 {
        return @min(self.open, self.close);
    }

    pub fn range(self: *const OHLCV) f64 {
        return self.high - self.low;
    }
};

/// Timeframe for candle aggregation
pub const TimeFrame = enum {
    m1,
    m5,
    m15,
    m30,
    h1,
    h4,
    d1,
    w1,
};

/// Trade side
pub const Side = enum { buy, sell };

/// A single trade/tick
pub const Tick = struct {
    timestamp: i64,
    price: f64,
    quantity: f64,
    side: Side,
};

/// Strategy signal
pub const Signal = enum { long, short, close, hold };

/// Viewport region in pixel coordinates
pub const Viewport = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn right(self: *const Viewport) f32 {
        return self.x + self.width;
    }

    pub fn top(self: *const Viewport) f32 {
        return self.y + self.height;
    }
};

/// Interactive chart state — pan, zoom, visible data range
pub const ChartState = struct {
    /// Index offset: how many candles scrolled from the right edge
    scroll_offset: f64 = 0,
    /// Candles visible in the viewport
    visible_count: f64 = 60,
    /// Min visible candles (max zoom in)
    min_visible: f64 = 10,
    /// Max visible candles (max zoom out)
    max_visible: f64 = 500,
    /// Mouse state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    dragging: bool = false,
    drag_start_x: f32 = 0,
    drag_start_offset: f64 = 0,
    /// Crosshair enabled
    crosshair: bool = true,

    pub fn zoom(self: *ChartState, delta: f64) void {
        const factor: f64 = if (delta > 0) 0.9 else 1.1;
        self.visible_count = @max(self.min_visible, @min(self.max_visible, self.visible_count * factor));
    }

    pub fn clampScroll(self: *ChartState, total_candles: usize) void {
        const max_scroll: f64 = @max(0, @as(f64, @floatFromInt(total_candles)) - self.visible_count);
        self.scroll_offset = @max(0, @min(max_scroll, self.scroll_offset));
    }

    /// Get the start index and count of visible candles
    pub fn visibleRange(self: *const ChartState, total: usize) struct { start: usize, count: usize } {
        const ftotal: f64 = @floatFromInt(total);
        const end_f: f64 = ftotal - self.scroll_offset;
        const start_f: f64 = @max(0, end_f - self.visible_count);
        const start: usize = @intFromFloat(@max(0, start_f));
        const end: usize = @intFromFloat(@min(ftotal, @max(0, end_f)));
        return .{ .start = start, .count = if (end > start) end - start else 0 };
    }
};

/// Ring buffer for candle storage — fixed capacity, overwrites oldest
pub fn CandleBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        data: [capacity]OHLCV = undefined,
        head: usize = 0, // next write position
        len: usize = 0,

        pub fn push(self: *Self, candle: OHLCV) void {
            self.data[self.head] = candle;
            self.head = (self.head + 1) % capacity;
            if (self.len < capacity) self.len += 1;
        }

        /// Get candle at logical index (0 = oldest)
        pub fn get(self: *const Self, idx: usize) OHLCV {
            if (idx >= self.len) return .{};
            const actual = if (self.len < capacity)
                idx
            else
                (self.head + idx) % capacity;
            return self.data[actual];
        }

        /// Copy visible range into a contiguous slice for rendering
        pub fn sliceInto(self: *const Self, out: []OHLCV, start: usize, count: usize) usize {
            var written: usize = 0;
            var i: usize = start;
            while (i < start + count and i < self.len and written < out.len) : ({
                i += 1;
                written += 1;
            }) {
                out[written] = self.get(i);
            }
            return written;
        }
    };
}
