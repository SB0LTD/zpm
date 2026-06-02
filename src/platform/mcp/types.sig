// MCP tool definitions and JSON schemas
// Layer 1: Platform

pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
    schema: []const u8,
};

pub const NO_PARAMS =
    \\{"type":"object","additionalProperties":false}
;
const SCHEMA_CHAR =
    \\{"type":"object","properties":{"char":{"type":"string","description":"Single ASCII character"}},"required":["char"],"additionalProperties":false}
;
const SCHEMA_ORDER_TYPE =
    \\{"type":"object","properties":{"order_type":{"type":"string","enum":["market","limit","stop_market","stop_limit","take_profit_market","take_profit_limit","trailing_stop"]}},"required":["order_type"],"additionalProperties":false}
;
const SCHEMA_FIELD =
    \\{"type":"object","properties":{"field":{"type":"string","enum":["price","qty","stop_price","tp_price","sl_price"]}},"required":["field"],"additionalProperties":false}
;
const SCHEMA_SET_FIELD =
    \\{"type":"object","properties":{"field":{"type":"string","enum":["price","qty","stop_price","tp_price","sl_price"]},"value":{"type":"string","description":"Numeric value (digits, dot, minus)"}},"required":["field","value"],"additionalProperties":false}
;
const SCHEMA_LEVERAGE =
    \\{"type":"object","properties":{"value":{"type":"number","minimum":0,"maximum":1}},"required":["value"],"additionalProperties":false}
;
const SCHEMA_INDEX =
    \\{"type":"object","properties":{"index":{"type":"integer","minimum":0}},"required":["index"],"additionalProperties":false}
;
const SCHEMA_DELTA =
    \\{"type":"object","properties":{"delta":{"type":"integer"}},"required":["delta"],"additionalProperties":false}
;
const SCHEMA_LOGS =
    \\{"type":"object","properties":{"lines":{"type":"integer","description":"Number of recent lines to return (default 50, max 256)","minimum":1,"maximum":256}},"additionalProperties":false}
;

pub const TOOLS = [_]ToolDef{
    // Chart navigation
    .{ .name = "scroll_left", .desc = "Scroll chart left (back in time)", .schema = NO_PARAMS },
    .{ .name = "scroll_right", .desc = "Scroll chart right (forward in time)", .schema = NO_PARAMS },
    .{ .name = "zoom_in", .desc = "Zoom into the chart", .schema = NO_PARAMS },
    .{ .name = "zoom_out", .desc = "Zoom out of the chart", .schema = NO_PARAMS },
    .{ .name = "reset_view", .desc = "Reset chart to default zoom and scroll", .schema = NO_PARAMS },
    .{ .name = "toggle_crosshair", .desc = "Toggle crosshair cursor", .schema = NO_PARAMS },
    // Overlays
    .{ .name = "open_settings", .desc = "Open settings overlay", .schema = NO_PARAMS },
    .{ .name = "close_settings", .desc = "Close settings overlay", .schema = NO_PARAMS },
    .{ .name = "toggle_debug", .desc = "Toggle debug console", .schema = NO_PARAMS },
    .{ .name = "close_debug", .desc = "Close debug console", .schema = NO_PARAMS },
    .{ .name = "screenshot", .desc = "Take a screenshot", .schema = NO_PARAMS },
    // Settings
    .{ .name = "settings_nav_up", .desc = "Move selection up in settings", .schema = NO_PARAMS },
    .{ .name = "settings_nav_down", .desc = "Move selection down in settings", .schema = NO_PARAMS },
    .{ .name = "settings_cycle_prev", .desc = "Cycle setting to previous value", .schema = NO_PARAMS },
    .{ .name = "settings_cycle_next", .desc = "Cycle setting to next value", .schema = NO_PARAMS },
    .{ .name = "settings_confirm", .desc = "Confirm current settings edit", .schema = NO_PARAMS },
    .{ .name = "settings_begin_edit", .desc = "Begin editing selected field", .schema = NO_PARAMS },
    .{ .name = "settings_backspace", .desc = "Delete last char in settings field", .schema = NO_PARAMS },
    .{ .name = "apply_settings", .desc = "Apply settings and restart display slot", .schema = NO_PARAMS },
    .{ .name = "settings_type", .desc = "Type a character into settings field", .schema = SCHEMA_CHAR },
    .{ .name = "settings_filter_clear", .desc = "Clear settings symbol filter", .schema = NO_PARAMS },
    .{ .name = "settings_filter_confirm", .desc = "Confirm settings symbol filter selection", .schema = NO_PARAMS },
    .{ .name = "settings_filter_backspace", .desc = "Delete last char in settings filter", .schema = NO_PARAMS },
    .{ .name = "settings_filter_type", .desc = "Type a character into settings symbol filter", .schema = SCHEMA_CHAR },
    // Order entry
    .{ .name = "order_type_cycle_next", .desc = "Cycle to next order type", .schema = NO_PARAMS },
    .{ .name = "order_type_cycle_prev", .desc = "Cycle to previous order type", .schema = NO_PARAMS },
    .{ .name = "order_side_buy", .desc = "Set order side to Buy/Long", .schema = NO_PARAMS },
    .{ .name = "order_side_sell", .desc = "Set order side to Sell/Short", .schema = NO_PARAMS },
    .{ .name = "order_backspace", .desc = "Delete last char in order field", .schema = NO_PARAMS },
    .{ .name = "order_submit", .desc = "Submit the current order", .schema = NO_PARAMS },
    .{ .name = "order_toggle_reduce_only", .desc = "Toggle Reduce-Only flag", .schema = NO_PARAMS },
    .{ .name = "order_toggle_post_only", .desc = "Toggle Post-Only flag", .schema = NO_PARAMS },
    .{ .name = "order_set_type", .desc = "Set order type", .schema = SCHEMA_ORDER_TYPE },
    .{ .name = "order_focus_field", .desc = "Focus an order entry field", .schema = SCHEMA_FIELD },
    .{ .name = "order_set_field", .desc = "Set an order entry field value directly", .schema = SCHEMA_SET_FIELD },
    .{ .name = "order_type_char", .desc = "Type a character into order field", .schema = SCHEMA_CHAR },
    .{ .name = "order_set_leverage", .desc = "Set leverage (0.0=min, 1.0=max)", .schema = SCHEMA_LEVERAGE },
    .{ .name = "order_cancel", .desc = "Cancel open order by index", .schema = SCHEMA_INDEX },
    // Debug
    .{ .name = "debug_scroll", .desc = "Scroll debug console", .schema = SCHEMA_DELTA },
    // Query tools (read-only)
    .{ .name = "get_status", .desc = "Get current app status: source, symbol, timeframe, price, connection, overlays", .schema = NO_PARAMS },
    .{ .name = "get_logs", .desc = "Get recent log entries from the in-memory ring buffer", .schema = SCHEMA_LOGS },
};
