// Action — discrete app-level commands, source-agnostic
// Layer 0: Core
//
// Any input device (keyboard, MCP, scripting, etc.) produces Actions.
// The app layer consumes them — no coupling to Win32 or any platform.

const oes = @import("../trading/order_entry_state.zig");

/// Raw click coordinates within a panel (local space).
pub const ClickCoords = struct {
    px: f32,
    py: f32,
    w: f32,
    h: f32,
};

/// A field + value pair for setting an order entry field's content directly.
pub const FieldValue = struct {
    field: oes.EditField,
    buf: [24]u8 = [_]u8{0} ** 24,
    len: u8 = 0,
};

pub const Action = union(enum) {
    // ── Chart navigation ────────────────────────────────────
    scroll_left,
    scroll_right,
    zoom_in,
    zoom_out,
    reset_view,
    toggle_crosshair,

    // ── Overlays ────────────────────────────────────────────
    open_settings,
    close_settings,
    toggle_debug,
    close_debug,

    // ── Settings navigation ─────────────────────────────────
    settings_nav_up,
    settings_nav_down,
    settings_cycle_prev,
    settings_cycle_next,
    settings_confirm,
    settings_begin_edit,
    settings_backspace,
    settings_type: u8,
    settings_filter_clear,
    settings_filter_confirm,
    settings_filter_backspace,
    settings_filter_type: u8,

    // ── Order entry ─────────────────────────────────────────
    order_type_cycle_next,
    order_type_cycle_prev,
    order_type_tab: oes.OrderType,
    order_side_buy,
    order_side_sell,
    order_field_click: oes.EditField,
    order_type_char: u8,
    order_backspace,
    order_set_field: FieldValue, // set a field's entire value at once
    order_submit,
    order_toggle_reduce_only,
    order_toggle_post_only,
    order_leverage: f64,
    order_cancel: usize, // index into open orders list

    // ── Raw panel clicks (resolved by app layer) ────────────
    order_entry_click: ClickCoords,
    open_orders_click: ClickCoords,

    // ── App lifecycle ────────────────────────────────────────
    apply_settings,
    debug_scroll: i32,
    screenshot,
    /// MCP request-response: take screenshot and write path to response slot
    screenshot_req: u64,
};

/// Fixed-size action queue — no allocator needed.
/// Producers append; consumer drains each frame.
pub const QUEUE_CAP = 32;

pub const ActionQueue = struct {
    buf: [QUEUE_CAP]Action = undefined,
    len: usize = 0,

    pub fn push(self: *ActionQueue, a: Action) void {
        if (self.len < QUEUE_CAP) {
            self.buf[self.len] = a;
            self.len += 1;
        }
    }

    pub fn drain(self: *ActionQueue) []const Action {
        const slice = self.buf[0..self.len];
        self.len = 0;
        return slice;
    }
};
