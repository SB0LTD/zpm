// MCP tool definitions and JSON schemas
// Layer 1: Platform
//
// Tools are consolidated into a handful of EXTENSIVE, action-based tools rather
// than dozens of single-purpose verbs. Each tool takes an `action` selector plus
// whatever payload that action needs. To keep the surface uniform, every
// action-based tool advertises the SAME schema — one superset object where only
// `action` is required and every other field is optional. The handler reads only
// the fields relevant to the chosen action.

pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
    schema: []const u8,
};

pub const NO_PARAMS =
    \\{"type":"object","additionalProperties":false}
;

const SCHEMA_LOGS =
    \\{"type":"object","properties":{"lines":{"type":"integer","description":"Number of recent lines to return (default 50, max 256)","minimum":1,"maximum":256}},"additionalProperties":false}
;

const SCHEMA_DISPLAY =
    \\{"type":"object","properties":{"index":{"type":"integer","minimum":0,"description":"Subscription slot index to display"}},"required":["index"],"additionalProperties":false}
;

// One schema shared by every action-based tool: an `action` selector plus a
// freeform `args` map. `args` is an OPEN object — any payload key an action
// needs (target, value, name, char, field, order_type, index, delta, script,
// window, bars, offset, tf, ...) goes inside it and is read by name in the
// handler. Because `args` allows additional properties, adding a NEW payload
// field never requires touching this schema — only the handler + the tool's
// description (which documents the keys each action reads).
const SCHEMA_UNIFIED =
    \\{"type":"object","properties":{"action":{"type":"string","description":"Which operation to perform (see the tool description for valid actions)"},"args":{"type":"object","description":"Action payload. Keys depend on the action — see the tool description. Examples: {\"target\":\"strategy\"}, {\"field\":\"qty\",\"value\":\"1.5\"}, {\"name\":\"sep_k\",\"value\":1.5}, {\"bars\":55000,\"offset\":0}, {\"tf\":300}, {\"script\":\"...\"}.","additionalProperties":true}},"required":["action"],"additionalProperties":false}
;

pub const TOOLS = [_]ToolDef{
    // ── Chart navigation ────────────────────────────────────────────
    .{ .name = "chart", .desc =
        \\Navigate the chart. action: scroll_left | scroll_right | zoom_in | zoom_out | reset_view | toggle_crosshair
    , .schema = SCHEMA_UNIFIED },

    // ── Overlays / panels ───────────────────────────────────────────
    .{ .name = "panel", .desc =
        \\Control an overlay panel. Payload goes in `args`. action: open | close | toggle | scroll (scroll applies to the debug console, using args.delta). args.target: settings | debug | strategy. Example: {action:open, args:{target:strategy}} opens the strategy panel; {action:scroll, args:{target:debug, delta:-3}} scrolls the debug console.
    , .schema = SCHEMA_UNIFIED },

    // ── Settings panel ──────────────────────────────────────────────
    .{ .name = "settings", .desc =
        \\Drive the settings panel. Payload goes in `args`. action: nav_up | nav_down | cycle_prev | cycle_next | begin_edit | confirm | backspace | type (args.char) | apply | filter_type (args.char) | filter_backspace | filter_clear | filter_confirm.
    , .schema = SCHEMA_UNIFIED },

    // ── Order entry ─────────────────────────────────────────────────
    .{ .name = "order", .desc =
        \\Drive the order-entry form. Payload goes in `args`. action: side_buy | side_sell | type_next | type_prev | set_type (args.order_type) | focus_field (args.field) | set_field (args.field+args.value) | type_char (args.char) | backspace | set_leverage (args.value 0..1) | toggle_reduce_only | toggle_post_only | submit | cancel (args.index).
    , .schema = SCHEMA_UNIFIED },

    // ── Strategy panel ──────────────────────────────────────────────
    .{ .name = "strategy", .desc =
        \\Strategy panel: author, backtest, tune, and arm. Payload goes in `args`. action: open | close | set_script (args.script) | set_lookback (args.window) | set_window (args.bars and/or args.offset in 1m bars, for walk-forward over earlier periods) | set_tf (args.tf seconds: 60=1m,300=5m,900=15m,3600=1h; 0=slot default) | run (backtest the display slot) | run_all (parallel backtest all cached slots) | get_all (last batch results JSON) | get_result (panel status + last result) | get_params (declared input() params JSON) | set_param (args.name + args.value) | toggle_arm (LIVE order execution safety gate).
    , .schema = SCHEMA_UNIFIED },

    // ── Standalone tools (already single-purpose) ───────────────────
    .{ .name = "set_display", .desc = "Switch the displayed subscription slot by index (instant, no re-backfill) — changes which symbol backtests run against", .schema = SCHEMA_DISPLAY },
    .{ .name = "screenshot", .desc = "Capture the GL framebuffer and return it as a base64 PNG", .schema = NO_PARAMS },
    .{ .name = "get_status", .desc = "Get current app status: source, symbol, timeframe, price, connection, overlays, order entry", .schema = NO_PARAMS },
    .{ .name = "get_logs", .desc = "Get recent log entries from the in-memory ring buffer", .schema = SCHEMA_LOGS },
};
