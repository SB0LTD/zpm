// DataManager types and constants — pure data definitions
// Layer 0: Foundation

pub const OHLCV = @import("../types.zig").OHLCV;

/// Max candles extractable for rendering in one frame
pub const MAX_VISIBLE = 512;

/// Live ring capacity — holds candles not yet flushed to cache.
/// At 1m resolution, 512 = ~8.5 hours of unflushed data.
pub const LIVE_CAP = 512;

/// Max raw 1m candles for inner-candle rendering.
/// 4096 × 48 bytes = 192KB — safe for stack.
pub const MAX_VISIBLE_1M = 4096;
/// 4096 records × 48 bytes = 192KB per chunk, safe for stack.
pub const CHUNK_SIZE = 4096;

/// Function pointer type for reading a range of records from cache.
/// Keeps Layer 0 pure — the actual implementation lives in sources/cache.zig.
pub const ReadFn = *const fn (path: *const [128]u16, start: usize, buf: []OHLCV) usize;
