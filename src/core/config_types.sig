// Configuration types — fixed-size value types for runtime config
// Layer 0: Foundation — pure data, no I/O
//
// These types are used by Config for parsing and by other modules
// that need to reference config values without pulling in the parser.

const std = @import("std");

/// Max length for any single config string value
pub const MAX_VAL = 256;

/// Max subscriptions (source+symbol+timeframe combos)
pub const MAX_SUBS = 10;

/// A fixed-capacity string buffer for config values
pub const ConfigStr = struct {
    buf: [MAX_VAL]u8 = [_]u8{0} ** MAX_VAL,
    len: usize = 0,

    pub fn slice(self: *const ConfigStr) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: *const ConfigStr, other: []const u8) bool {
        return self.len == other.len and std.mem.eql(u8, self.slice(), other);
    }

    pub fn set(self: *ConfigStr, val: []const u8) void {
        const n = @min(val.len, MAX_VAL);
        @memcpy(self.buf[0..n], val[0..n]);
        self.len = n;
    }

    /// Comptime initializer for default values
    pub fn init(comptime s: []const u8) ConfigStr {
        var cs = ConfigStr{};
        @memcpy(cs.buf[0..s.len], s);
        cs.len = s.len;
        return cs;
    }
};

/// Per-source API credentials
pub const SourceCreds = struct {
    api_key: ConfigStr = .{},
    api_secret: ConfigStr = .{},
    api_passphrase: ConfigStr = .{},
};

/// Market type — determines which API surface (host, endpoints, symbol format) to use.
///   spot    — Binance spot / KuCoin spot
///   linear  — Binance USD-M futures (fapi/fstream) / KuCoin futures (api-futures)
///   inverse — Binance COIN-M futures (dapi/dstream) — not applicable to KuCoin
pub const MarketType = enum(u8) {
    spot = 0,
    linear = 1,
    inverse = 2,

    pub fn isFutures(self: MarketType) bool {
        return self != .spot;
    }

    pub fn label(self: MarketType) []const u8 {
        return switch (self) {
            .spot => "spot",
            .linear => "linear",
            .inverse => "inverse",
        };
    }

    pub fn fromString(s: []const u8) MarketType {
        if (s.len == 6 and s[0] == 'l' and s[1] == 'i') return .linear;
        if (s.len == 7 and s[0] == 'i' and s[1] == 'n') return .inverse;
        return .spot;
    }
};

/// A single data subscription: source + symbol + timeframe + history count.
/// Each subscription gets its own SourceSlot at runtime.
pub const Subscription = struct {
    source: ConfigStr = ConfigStr.init("binance"),
    symbol: ConfigStr = ConfigStr.init("BTCUSDT"),
    timeframe: ConfigStr = ConfigStr.init("1m"),
    history: usize = 500,
    market: MarketType = .spot,
};
