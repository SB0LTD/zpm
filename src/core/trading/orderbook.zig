// Order book types — pure data, no I/O
// Layer 0: Foundation

pub const DEPTH = 50; // levels per side

/// A single price level in the order book
pub const Level = struct {
    price: f64 = 0,
    qty: f64 = 0,
};

/// Full order book snapshot — 50 bids + 50 asks
/// bids[0] = best bid (highest price), asks[0] = best ask (lowest price)
pub const OrderBook = struct {
    bids: [DEPTH]Level = [_]Level{.{}} ** DEPTH,
    asks: [DEPTH]Level = [_]Level{.{}} ** DEPTH,
    bid_count: u8 = 0,
    ask_count: u8 = 0,
    /// Sequence number / last update ID for delta merging
    last_update_id: i64 = 0,
    /// Timestamp of last update (ms)
    timestamp: i64 = 0,

    pub fn bestBid(self: *const OrderBook) f64 {
        return if (self.bid_count > 0) self.bids[0].price else 0;
    }
    pub fn bestAsk(self: *const OrderBook) f64 {
        return if (self.ask_count > 0) self.asks[0].price else 0;
    }
    pub fn spread(self: *const OrderBook) f64 {
        const b = self.bestBid();
        const a = self.bestAsk();
        return if (b > 0 and a > 0) a - b else 0;
    }
    pub fn midPrice(self: *const OrderBook) f64 {
        const b = self.bestBid();
        const a = self.bestAsk();
        return if (b > 0 and a > 0) (b + a) * 0.5 else 0;
    }
    /// Max qty across all visible levels (for depth bar scaling)
    pub fn maxQty(self: *const OrderBook) f64 {
        var m: f64 = 0;
        for (0..self.bid_count) |i| if (self.bids[i].qty > m) {
            m = self.bids[i].qty;
        };
        for (0..self.ask_count) |i| if (self.asks[i].qty > m) {
            m = self.asks[i].qty;
        };
        return m;
    }
    /// Cumulative bid qty up to level i (for depth visualization)
    pub fn cumBidQty(self: *const OrderBook, i: usize) f64 {
        var sum: f64 = 0;
        for (0..@min(i + 1, self.bid_count)) |j| sum += self.bids[j].qty;
        return sum;
    }
    /// Cumulative ask qty up to level i
    pub fn cumAskQty(self: *const OrderBook, i: usize) f64 {
        var sum: f64 = 0;
        for (0..@min(i + 1, self.ask_count)) |j| sum += self.asks[j].qty;
        return sum;
    }
};
