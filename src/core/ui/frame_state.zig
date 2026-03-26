// FrameState — single source of truth for all per-frame derived state
// Layer 0: Core
//
// Built once per tick by the app layer. Every consumer — widgets, bridges,
// MCP server, debug console — reads from this snapshot.
//
// All fields are plain data — no pointers, no slices, no allocator.
// Safe to copy across threads via SeqLock.

const ConfigStr = @import("../config_types.zig").ConfigStr;
const oes = @import("../trading/order_entry_state.zig");
const MAX_SUBS = @import("../config_types.zig").MAX_SUBS;

/// Per-slot summary — replaces duplicated reads in debug bridge, backfill bridge, MCP.
pub const SlotSummary = struct {
    active: bool = false,
    source_name: [16]u8 = [_]u8{0} ** 16,
    source_len: u8 = 0,
    symbol_name: [16]u8 = [_]u8{0} ** 16,
    symbol_len: u8 = 0,
    connected: bool = false,
    last_price: f64 = 0,
    candle_count: u32 = 0,
    candle_1m_count: u32 = 0,
    display_tf_secs: i64 = 60,
    history_cached: bool = false,
    cache_valid: bool = false,

    // Backfill progress
    backfill_active: bool = false,
    backfill_done: bool = false,
    backfill_candles: u32 = 0,
    backfill_expected: u32 = 0,
    backfill_speed: f32 = 0,
    backfill_eta_secs: u32 = 0,
};

/// Order entry snapshot — replaces McpState OE fields and AppState snapshot.
pub const OrderEntrySnapshot = struct {
    side: oes.OrderSide = .buy,
    order_type: oes.OrderType = .limit,
    editing: oes.EditField = .none,
    price_buf: [24]u8 = [_]u8{0} ** 24,
    price_len: u8 = 0,
    qty_buf: [24]u8 = [_]u8{0} ** 24,
    qty_len: u8 = 0,
    stop_buf: [24]u8 = [_]u8{0} ** 24,
    stop_len: u8 = 0,
    tp_buf: [24]u8 = [_]u8{0} ** 24,
    tp_len: u8 = 0,
    sl_buf: [24]u8 = [_]u8{0} ** 24,
    sl_len: u8 = 0,
    leverage: f64 = 10,
    reduce_only: bool = false,
    post_only: bool = false,
    submitting: bool = false,
};

pub const FrameState = struct {
    // ── Display slot info ───────────────────────────────────
    source: ConfigStr = .{},
    symbol: ConfigStr = .{},
    timeframe: ConfigStr = .{},
    connected: bool = false,
    last_price: f64 = 0,
    display_period_secs: i64 = 60,

    // ── Window ──────────────────────────────────────────────
    win_w: i32 = 0,
    win_h: i32 = 0,

    // ── Slots ───────────────────────────────────────────────
    display_idx: usize = 0,
    slot_count: usize = 0,
    slots: [MAX_SUBS]SlotSummary = [_]SlotSummary{.{}} ** MAX_SUBS,

    // ── UI toggles ──────────────────────────────────────────
    debug_open: bool = false,
    settings_open: bool = false,
    crosshair_on: bool = false,

    // ── Order entry ─────────────────────────────────────────
    order_entry: OrderEntrySnapshot = .{},

    // ── Frame timing ────────────────────────────────────────
    frame_time_us: u32 = 0,
    fps: u16 = 0,

    // ── Sequence number ─────────────────────────────────────
    frame_seq: u64 = 0,
};
