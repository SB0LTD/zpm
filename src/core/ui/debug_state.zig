// DebugState — pure data for the debug console overlay
// Layer 0: Foundation — no I/O, no rendering
//
// Embedded in AppState so platform/input.zig (Layer 1) can toggle it.
// The widget (Layer 3) reads this struct for rendering.

/// Per-slot stats snapshot, populated each frame by app.zig.
pub const SlotStats = struct {
    active: bool = false,
    source_name: [16]u8 = [_]u8{0} ** 16,
    source_len: u8 = 0,
    symbol_name: [16]u8 = [_]u8{0} ** 16,
    symbol_len: u8 = 0,
    candle_count: u32 = 0,
    candle_1m_count: u32 = 0,
    connected: bool = false,
    history_cached: bool = false,
    cache_valid: bool = false,
    display_tf_secs: i64 = 60,
    // Backfill stats
    backfill_active: bool = false,
    backfill_done: bool = false,
    backfill_candles: u32 = 0,
    backfill_expected: u32 = 0,
    backfill_speed: f32 = 0, // candles/sec (smoothed)
    backfill_eta_secs: u32 = 0,
    prev_backfill_candles: u32 = 0, // previous snapshot for speed EMA
    backfill_prev_sec: i64 = 0, // timestamp of previous speed sample
};

pub const MAX_DEBUG_SLOTS: usize = @import("../config_types.zig").MAX_SUBS;

pub const DebugState = struct {
    open: bool = false,
    scroll: i32 = 0,
    frame_time_us: u32 = 0,
    fps: u16 = 0,
    slot_stats: [MAX_DEBUG_SLOTS]SlotStats = [_]SlotStats{.{}} ** MAX_DEBUG_SLOTS,
    slot_count: u8 = 0,
};
