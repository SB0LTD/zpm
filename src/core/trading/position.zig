// Position types — open futures positions and portfolio aggregation
// Layer 0: Foundation — pure data, no I/O
//
// Position represents a single open futures position from any exchange.
// PortfolioState aggregates positions + balances across all active slots
// into a unified view for the UI.

/// Max open positions per source
pub const MAX_POSITIONS = 32;

/// Max positions across all sources in the portfolio
pub const MAX_PORTFOLIO_POSITIONS = 64;

/// Max balance entries in the portfolio
pub const MAX_PORTFOLIO_BALANCES = 32;

pub const PositionSide = enum(u8) {
    long = 0,
    short = 1,
    both = 2, // hedge mode "BOTH"
};

pub const MarginMode = enum(u8) {
    cross = 0,
    isolated = 1,
};

/// A single open futures position from any exchange
pub const Position = struct {
    symbol: [20]u8 = [_]u8{0} ** 20,
    symbol_len: u8 = 0,
    side: PositionSide = .long,
    margin_mode: MarginMode = .cross,
    size: f64 = 0, // absolute position size (always positive)
    entry_price: f64 = 0,
    mark_price: f64 = 0,
    unrealized_pnl: f64 = 0,
    leverage: f64 = 1,
    liquidation_price: f64 = 0,
    notional: f64 = 0, // position value in quote currency

    pub fn symbolSlice(self: *const Position) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    pub fn setSymbol(self: *Position, s: []const u8) void {
        const n = @min(s.len, 20);
        @memcpy(self.symbol[0..n], s[0..n]);
        self.symbol_len = @intCast(n);
    }

    /// True if this position has meaningful size
    pub fn isOpen(self: *const Position) bool {
        return self.size > 0.0000001 or self.size < -0.0000001;
    }
};
