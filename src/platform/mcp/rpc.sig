// JSON-RPC dispatch — initialize, tools/list, tools/call
// Layer 1: Platform

const w32 = @import("win32");
const json = @import("json");
const oes = @import("core").trading.order_entry_state;
const Action = @import("core").ui.action.Action;
const http = @import("http.sig");
const t = @import("types.sig");
const ring = @import("channel.sig");
const scr = @import("screenshot.sig");
const FrameState = @import("core").ui.frame_state.FrameState;
const ring_log = @import("core").ui.ring_log;

const RESP_SIZE: usize = 16384;

pub fn dispatch(sock: w32.SOCKET, body: []const u8) void {
    const method = json.getString(body, "\"method\"") orelse {
        http.sendResponse(sock, "202 Accepted", "application/json", "");
        return;
    };

    const id_val = json.getInt(body, "\"id\"");

    if (http.eql(method, "initialize")) {
        var resp: [RESP_SIZE]u8 = undefined;
        const len = fmtInitializeResponse(&resp, id_val orelse 0);
        http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
        return;
    }

    if (http.eql(method, "notifications/initialized")) {
        http.sendResponse(sock, "202 Accepted", "application/json", "");
        return;
    }

    if (http.eql(method, "ping")) {
        var resp: [256]u8 = undefined;
        const len = fmtPingResponse(&resp, id_val orelse 0);
        http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
        return;
    }

    if (http.eql(method, "tools/list")) {
        var resp: [RESP_SIZE]u8 = undefined;
        const len = fmtToolsList(&resp, id_val orelse 0);
        http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
        return;
    }

    if (http.eql(method, "tools/call")) {
        const params = json.findObject(body, "\"params\"") orelse {
            var resp: [RESP_SIZE]u8 = undefined;
            const len = fmtToolResult(&resp, id_val orelse 0, "error: missing params", true);
            http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
            return;
        };
        const tool_name = json.getString(params, "\"name\"") orelse {
            var resp: [RESP_SIZE]u8 = undefined;
            const len = fmtToolResult(&resp, id_val orelse 0, "error: missing tool name", true);
            http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
            return;
        };

        // Screenshot streams base64 image directly to socket (too large for buffer)
        if (http.eql(tool_name, "screenshot")) {
            scr.stream(sock, id_val orelse 0);
            return;
        }

        var resp: [RESP_SIZE]u8 = undefined;
        const len = handleToolCall(body, &resp, id_val orelse 0);
        http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
        return;
    }

    var resp: [512]u8 = undefined;
    const len = fmtError(&resp, id_val orelse 0, -32601, "Method not found");
    http.sendResponse(sock, "200 OK", "application/json", resp[0..len]);
}

// ── Response formatters ─────────────────────────────────────────────
fn fmtInitializeResponse(buf: *[RESP_SIZE]u8, id: i64) usize {
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos,
        \\{"jsonrpc":"2.0","id":
    );
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos,
        \\,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"sb0-trade","version":"1.0.0"},"instructions":"SB0 Trade MCP server — control chart, orders, and overlays"}}
    );
    return pos;
}

fn fmtPingResponse(buf: *[256]u8, id: i64) usize {
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{}}");
    return pos;
}

fn fmtError(buf: *[512]u8, id: i64, code: i64, msg: []const u8) usize {
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"error\":{\"code\":");
    pos = http.appendInt(buf, pos, code);
    pos = http.appendSlice(buf, pos, ",\"message\":\"");
    pos = http.appendSlice(buf, pos, msg);
    pos = http.appendSlice(buf, pos, "\"}}");
    return pos;
}

fn fmtToolsList(buf: *[RESP_SIZE]u8, id: i64) usize {
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"tools\":[");

    for (t.TOOLS, 0..) |tool, i| {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        pos = http.appendSlice(buf, pos, "{\"name\":\"");
        pos = http.appendSlice(buf, pos, tool.name);
        pos = http.appendSlice(buf, pos, "\",\"description\":\"");
        pos = http.appendSlice(buf, pos, tool.desc);
        pos = http.appendSlice(buf, pos, "\",\"inputSchema\":");
        pos = http.appendSlice(buf, pos, tool.schema);
        pos = http.appendSlice(buf, pos, "}");
    }

    pos = http.appendSlice(buf, pos, "]}}");
    return pos;
}

fn fmtToolResult(buf: *[RESP_SIZE]u8, id: i64, text: []const u8, is_err: bool) usize {
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    pos = http.appendSlice(buf, pos, text);
    pos = http.appendSlice(buf, pos, "\"}],\"isError\":");
    pos = http.appendSlice(buf, pos, if (is_err) "true" else "false");
    pos = http.appendSlice(buf, pos, "}}");
    return pos;
}

// ── Tool call handler ───────────────────────────────────────────────
fn handleToolCall(body: []const u8, buf: *[RESP_SIZE]u8, id: i64) usize {
    const params = json.findObject(body, "\"params\"") orelse {
        return fmtToolResult(buf, id, "error: missing params", true);
    };
    const name = json.getString(params, "\"name\"") orelse {
        return fmtToolResult(buf, id, "error: missing tool name", true);
    };

    const arguments = json.findObject(params, "\"arguments\"");
    // Payload lives in the nested freeform `args` map: {action, args:{...}}.
    // Fall back to `arguments` itself for backward-compatible flat calls.
    const payload: ?[]const u8 = if (arguments) |a| (json.findObject(a, "\"args\"") orelse a) else null;

    // ── Unified action-based tools ──────────────────────────
    // Each tool takes an `action` selector (read from `arguments`) plus a
    // freeform `args` payload map (passed to the handler). The routing below
    // maps (tool, action) onto the same underlying Action variants / staging /
    // query formatters as before. `action` is resolved inside each handler via
    // getAction(arguments); payload fields are read from `payload`.
    if (http.eql(name, "chart")) return handleChart(buf, id, arguments, payload);
    if (http.eql(name, "panel")) return handlePanel(buf, id, arguments, payload);
    if (http.eql(name, "settings")) return handleSettings(buf, id, arguments, payload);
    if (http.eql(name, "order")) return handleOrder(buf, id, arguments, payload);
    if (http.eql(name, "strategy")) return handleStrategy(buf, id, arguments, payload);

    // ── Standalone tools ────────────────────────────────────
    if (http.eql(name, "set_display")) {
        if (payload) |a| {
            if (json.getInt(a, "\"index\"")) |idx| {
                if (idx >= 0) {
                    ring.ringPush(.{ .set_display = @intCast(idx) });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: index must be non-negative", true);
    }

    if (http.eql(name, "get_status")) {
        return fmtStatusResult(buf, id);
    }

    if (http.eql(name, "get_logs")) {
        const count: usize = if (payload) |a| blk: {
            const v = json.getInt(a, "\"lines\"") orelse 50;
            break :blk @intCast(@min(@max(v, 1), 256));
        } else 50;
        return fmtLogsResult(buf, id, count);
    }

    return fmtToolResult(buf, id, "error: unknown tool", true);
}

// ── Unified tool action helpers ─────────────────────────────────────
// Handlers take `sel` (the arguments object, for reading `action`) and `pay`
// (the freeform args payload map, for reading per-action fields). In practice
// `pay` may equal `sel` for backward-compatible flat calls; both are scanned by
// key so reading is unambiguous.
fn getAction(sel: ?[]const u8) ?[]const u8 {
    const a = sel orelse return null;
    return json.getString(a, "\"action\"");
}

fn okPush(buf: *[RESP_SIZE]u8, id: i64, a: Action) usize {
    ring.ringPush(a);
    return fmtToolResult(buf, id, "ok", false);
}

/// chart — navigate the chart. action: scroll_left|scroll_right|zoom_in|
/// zoom_out|reset_view|toggle_crosshair.
fn handleChart(buf: *[RESP_SIZE]u8, id: i64, sel: ?[]const u8, pay: ?[]const u8) usize {
    _ = pay;
    const act = getAction(sel) orelse return fmtToolResult(buf, id, "error: action required", true);
    if (http.eql(act, "scroll_left")) return okPush(buf, id, .scroll_left);
    if (http.eql(act, "scroll_right")) return okPush(buf, id, .scroll_right);
    if (http.eql(act, "zoom_in")) return okPush(buf, id, .zoom_in);
    if (http.eql(act, "zoom_out")) return okPush(buf, id, .zoom_out);
    if (http.eql(act, "reset_view")) return okPush(buf, id, .reset_view);
    if (http.eql(act, "toggle_crosshair")) return okPush(buf, id, .toggle_crosshair);
    return fmtToolResult(buf, id, "error: chart action must be scroll_left|scroll_right|zoom_in|zoom_out|reset_view|toggle_crosshair", true);
}

/// panel — control an overlay. action: open|close|toggle|scroll.
/// target: settings|debug|strategy. scroll applies to the debug console (delta).
fn handlePanel(buf: *[RESP_SIZE]u8, id: i64, sel: ?[]const u8, pay: ?[]const u8) usize {
    const act = getAction(sel) orelse return fmtToolResult(buf, id, "error: action required", true);
    const target = if (pay) |a| (json.getString(a, "\"target\"") orelse "") else "";

    if (http.eql(act, "scroll")) {
        // debug console scroll
        if (pay) |a| {
            if (json.getInt(a, "\"delta\"")) |d| {
                return okPush(buf, id, .{ .debug_scroll = @truncate(d) });
            }
        }
        return fmtToolResult(buf, id, "error: scroll needs an integer delta", true);
    }

    if (http.eql(target, "settings")) {
        if (http.eql(act, "open")) return okPush(buf, id, .open_settings);
        if (http.eql(act, "close")) return okPush(buf, id, .close_settings);
        return fmtToolResult(buf, id, "error: settings panel supports open|close", true);
    }
    if (http.eql(target, "debug")) {
        if (http.eql(act, "open") or http.eql(act, "toggle")) return okPush(buf, id, .toggle_debug);
        if (http.eql(act, "close")) return okPush(buf, id, .close_debug);
        return fmtToolResult(buf, id, "error: debug panel supports open|toggle|close|scroll", true);
    }
    if (http.eql(target, "strategy")) {
        if (http.eql(act, "open")) return okPush(buf, id, .open_strategy);
        if (http.eql(act, "close")) return okPush(buf, id, .close_strategy);
        return fmtToolResult(buf, id, "error: strategy panel supports open|close", true);
    }
    return fmtToolResult(buf, id, "error: panel target must be settings|debug|strategy", true);
}

/// settings — drive the settings panel. See tool description for actions.
fn handleSettings(buf: *[RESP_SIZE]u8, id: i64, sel: ?[]const u8, pay: ?[]const u8) usize {
    const act = getAction(sel) orelse return fmtToolResult(buf, id, "error: action required", true);
    if (http.eql(act, "nav_up")) return okPush(buf, id, .settings_nav_up);
    if (http.eql(act, "nav_down")) return okPush(buf, id, .settings_nav_down);
    if (http.eql(act, "cycle_prev")) return okPush(buf, id, .settings_cycle_prev);
    if (http.eql(act, "cycle_next")) return okPush(buf, id, .settings_cycle_next);
    if (http.eql(act, "begin_edit")) return okPush(buf, id, .settings_begin_edit);
    if (http.eql(act, "confirm")) return okPush(buf, id, .settings_confirm);
    if (http.eql(act, "backspace")) return okPush(buf, id, .settings_backspace);
    if (http.eql(act, "apply")) return okPush(buf, id, .apply_settings);
    if (http.eql(act, "filter_clear")) return okPush(buf, id, .settings_filter_clear);
    if (http.eql(act, "filter_confirm")) return okPush(buf, id, .settings_filter_confirm);
    if (http.eql(act, "filter_backspace")) return okPush(buf, id, .settings_filter_backspace);
    if (http.eql(act, "type") or http.eql(act, "filter_type")) {
        if (getSingleChar(pay)) |ch| {
            if (http.eql(act, "type")) return okPush(buf, id, .{ .settings_type = ch });
            return okPush(buf, id, .{ .settings_filter_type = ch });
        }
        return fmtToolResult(buf, id, "error: char must be a single ASCII character", true);
    }
    return fmtToolResult(buf, id, "error: invalid settings action", true);
}

/// order — drive the order-entry form. See tool description for actions.
fn handleOrder(buf: *[RESP_SIZE]u8, id: i64, sel: ?[]const u8, pay: ?[]const u8) usize {
    const act = getAction(sel) orelse return fmtToolResult(buf, id, "error: action required", true);
    if (http.eql(act, "side_buy")) return okPush(buf, id, .order_side_buy);
    if (http.eql(act, "side_sell")) return okPush(buf, id, .order_side_sell);
    if (http.eql(act, "type_next")) return okPush(buf, id, .order_type_cycle_next);
    if (http.eql(act, "type_prev")) return okPush(buf, id, .order_type_cycle_prev);
    if (http.eql(act, "backspace")) return okPush(buf, id, .order_backspace);
    if (http.eql(act, "submit")) return okPush(buf, id, .order_submit);
    if (http.eql(act, "toggle_reduce_only")) return okPush(buf, id, .order_toggle_reduce_only);
    if (http.eql(act, "toggle_post_only")) return okPush(buf, id, .order_toggle_post_only);

    if (http.eql(act, "set_type")) {
        if (pay) |a| {
            if (json.getString(a, "\"order_type\"")) |ot| {
                if (parseOrderType(ot)) |otype| return okPush(buf, id, .{ .order_type_tab = otype });
            }
        }
        return fmtToolResult(buf, id, "error: set_type needs a valid order_type", true);
    }
    if (http.eql(act, "focus_field")) {
        if (pay) |a| {
            if (json.getString(a, "\"field\"")) |f| {
                if (parseEditField(f)) |ef| return okPush(buf, id, .{ .order_field_click = ef });
            }
        }
        return fmtToolResult(buf, id, "error: focus_field needs a valid field", true);
    }
    if (http.eql(act, "set_field")) {
        if (pay) |a| {
            if (json.getString(a, "\"field\"")) |f| {
                if (parseEditField(f)) |ef| {
                    const val = json.getString(a, "\"value\"") orelse "";
                    var fv = @import("core").ui.action.FieldValue{ .field = ef };
                    const n = @min(val.len, 23);
                    for (0..n) |i| fv.buf[i] = val[i];
                    fv.len = @intCast(n);
                    return okPush(buf, id, .{ .order_set_field = fv });
                }
            }
        }
        return fmtToolResult(buf, id, "error: set_field needs field + value", true);
    }
    if (http.eql(act, "type_char")) {
        if (getSingleChar(pay)) |ch| return okPush(buf, id, .{ .order_type_char = ch });
        return fmtToolResult(buf, id, "error: char must be a single ASCII character", true);
    }
    if (http.eql(act, "set_leverage")) {
        if (pay) |a| {
            if (json.getFloat(a, "\"value\"")) |v| {
                if (v >= 0.0 and v <= 1.0) return okPush(buf, id, .{ .order_leverage = v });
            }
        }
        return fmtToolResult(buf, id, "error: set_leverage value must be 0.0-1.0", true);
    }
    if (http.eql(act, "cancel")) {
        if (pay) |a| {
            if (json.getInt(a, "\"index\"")) |idx| {
                if (idx >= 0) return okPush(buf, id, .{ .order_cancel = @intCast(idx) });
            }
        }
        return fmtToolResult(buf, id, "error: cancel needs a non-negative index", true);
    }
    return fmtToolResult(buf, id, "error: invalid order action", true);
}

/// strategy — author, backtest, tune, arm. See tool description for actions.
fn handleStrategy(buf: *[RESP_SIZE]u8, id: i64, sel: ?[]const u8, pay: ?[]const u8) usize {
    const act = getAction(sel) orelse return fmtToolResult(buf, id, "error: action required", true);
    if (http.eql(act, "open")) return okPush(buf, id, .open_strategy);
    if (http.eql(act, "close")) return okPush(buf, id, .close_strategy);
    if (http.eql(act, "run")) return okPush(buf, id, .strategy_run_backtest);
    if (http.eql(act, "run_all")) return okPush(buf, id, .strategy_run_all);
    if (http.eql(act, "toggle_arm")) return okPush(buf, id, .strategy_toggle_arm);
    if (http.eql(act, "get_result")) return fmtStrategyResult(buf, id);
    if (http.eql(act, "get_params")) return fmtStrategyParams(buf, id);
    if (http.eql(act, "get_all")) return fmtBatchResult(buf, id);

    if (http.eql(act, "set_script")) {
        if (pay) |a| {
            var script_buf: [8192]u8 = undefined;
            if (json.getStringInto(a, "\"script\"", &script_buf)) |scriptv| {
                ring.stageScript(scriptv);
                ring.ringPush(.strategy_set_script);
                return fmtToolResult(buf, id, "script staged + compiling", false);
            }
        }
        return fmtToolResult(buf, id, "error: set_script needs a script string", true);
    }
    if (http.eql(act, "set_lookback")) {
        if (pay) |a| {
            if (json.getString(a, "\"window\"")) |wv| {
                if (parseLookback(wv)) |lb| return okPush(buf, id, .{ .strategy_set_lookback = lb });
            }
        }
        return fmtToolResult(buf, id, "error: set_lookback window must be 7d/30d/90d/1y/all", true);
    }
    if (http.eql(act, "set_window")) {
        // Either bars or offset (or both) may be given; missing → 0.
        var ws = @import("core").ui.action.WindowSpec{};
        if (pay) |a| {
            if (json.getInt(a, "\"bars\"")) |b| {
                if (b >= 0) ws.window_1m = @intCast(b);
            }
            if (json.getInt(a, "\"offset\"")) |o| {
                if (o >= 0) ws.offset_1m = @intCast(o);
            }
        }
        return okPush(buf, id, .{ .strategy_set_window = ws });
    }
    if (http.eql(act, "set_tf")) {
        var secs: i64 = 0;
        if (pay) |a| {
            if (json.getInt(a, "\"tf\"")) |v| {
                if (v >= 0) secs = v;
            }
        }
        return okPush(buf, id, .{ .strategy_set_tf = secs });
    }
    if (http.eql(act, "set_param")) {
        if (pay) |a| {
            if (json.getString(a, "\"name\"")) |pname| {
                if (json.getFloat(a, "\"value\"")) |pval| {
                    if (pname.len > 0 and pname.len <= 24) {
                        var ps = @import("core").ui.action.ParamSet{ .value = pval };
                        const n = @min(pname.len, ps.name.len);
                        for (0..n) |i| ps.name[i] = pname[i];
                        ps.name_len = @intCast(n);
                        return okPush(buf, id, .{ .strategy_set_param = ps });
                    }
                }
            }
        }
        return fmtToolResult(buf, id, "error: set_param needs name (string) + value (number)", true);
    }
    return fmtToolResult(buf, id, "error: invalid strategy action", true);
}

/// Extract a single ASCII character from the `char` argument, or null.
fn getSingleChar(args: ?[]const u8) ?u8 {
    const a = args orelse return null;
    const ch = json.getString(a, "\"char\"") orelse return null;
    if (ch.len == 1 and ch[0] <= 127) return ch[0];
    return null;
}

/// Format the last parallel batch backtest result as a tool response.
fn fmtBatchResult(buf: *[RESP_SIZE]u8, id: i64) usize {
    const batch = ring.stagedBatchResult();
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    pos = appendEscaped(buf, pos, batch);
    pos = http.appendSlice(buf, pos, "\"}],\"isError\":false}}");
    return pos;
}

// ── Parsers ─────────────────────────────────────────────────────────
fn parseOrderType(s: []const u8) ?oes.OrderType {
    if (http.eql(s, "market")) return .market;
    if (http.eql(s, "limit")) return .limit;
    if (http.eql(s, "stop_market")) return .stop_market;
    if (http.eql(s, "stop_limit")) return .stop_limit;
    if (http.eql(s, "take_profit_market")) return .take_profit_market;
    if (http.eql(s, "take_profit_limit")) return .take_profit_limit;
    if (http.eql(s, "trailing_stop")) return .trailing_stop;
    return null;
}

fn parseEditField(s: []const u8) ?oes.EditField {
    if (http.eql(s, "price")) return .price;
    if (http.eql(s, "qty")) return .qty;
    if (http.eql(s, "stop_price")) return .stop_price;
    if (http.eql(s, "tp_price")) return .tp_price;
    if (http.eql(s, "sl_price")) return .sl_price;
    return null;
}

const Lookback = @import("core").ui.strategy_state.Lookback;

fn parseLookback(s: []const u8) ?Lookback {
    if (http.eql(s, "7d")) return .d7;
    if (http.eql(s, "30d")) return .d30;
    if (http.eql(s, "90d")) return .d90;
    if (http.eql(s, "1y")) return .d365;
    if (http.eql(s, "all")) return .all;
    return null;
}

// ── Name helpers ────────────────────────────────────────────────────
fn orderTypeName(ot: oes.OrderType) []const u8 {
    return switch (ot) {
        .market => "market",
        .limit => "limit",
        .stop_market => "stop_market",
        .stop_limit => "stop_limit",
        .take_profit_market => "take_profit_market",
        .take_profit_limit => "take_profit_limit",
        .trailing_stop => "trailing_stop",
    };
}

fn editFieldName(ef: oes.EditField) []const u8 {
    return switch (ef) {
        .none => "none",
        .price => "price",
        .qty => "qty",
        .stop_price => "stop_price",
        .tp_price => "tp_price",
        .sl_price => "sl_price",
    };
}

// ── Status query formatter ──────────────────────────────────────────
fn fmtStatusResult(buf: *[RESP_SIZE]u8, id: i64) usize {
    const st = ring.loadFrameState() orelse {
        return fmtToolResult(buf, id, "state not available", true);
    };

    // Build a JSON text response with all status fields
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{");

    pos = http.appendSlice(buf, pos, "\\\"source\\\":\\\"");
    pos = http.appendSlice(buf, pos, st.source.slice());
    pos = http.appendSlice(buf, pos, "\\\",\\\"symbol\\\":\\\"");
    pos = http.appendSlice(buf, pos, st.symbol.slice());
    pos = http.appendSlice(buf, pos, "\\\",\\\"timeframe\\\":\\\"");
    pos = http.appendSlice(buf, pos, st.timeframe.slice());
    pos = http.appendSlice(buf, pos, "\\\",\\\"connected\\\":");
    pos = http.appendSlice(buf, pos, if (st.connected) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"last_price\\\":");
    pos = fmtFloat(buf, pos, st.last_price);
    pos = http.appendSlice(buf, pos, ",\\\"display_idx\\\":");
    pos = http.appendUint(buf, pos, st.display_idx);
    pos = http.appendSlice(buf, pos, ",\\\"slot_count\\\":");
    pos = http.appendUint(buf, pos, st.slot_count);
    pos = http.appendSlice(buf, pos, ",\\\"debug_open\\\":");
    pos = http.appendSlice(buf, pos, if (st.debug_open) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"settings_open\\\":");
    pos = http.appendSlice(buf, pos, if (st.settings_open) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"crosshair\\\":");
    pos = http.appendSlice(buf, pos, if (st.crosshair_on) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"window\\\":[");
    pos = http.appendInt(buf, pos, st.win_w);
    pos = http.appendSlice(buf, pos, ",");
    pos = http.appendInt(buf, pos, st.win_h);
    pos = http.appendSlice(buf, pos, "],\\\"order_entry\\\":{");

    // Order entry state from FrameState snapshot
    const oe = &st.order_entry;
    pos = http.appendSlice(buf, pos, "\\\"side\\\":\\\"");
    pos = http.appendSlice(buf, pos, if (oe.side == .buy or oe.side == .long) "buy" else "sell");
    pos = http.appendSlice(buf, pos, "\\\",\\\"order_type\\\":\\\"");
    pos = http.appendSlice(buf, pos, orderTypeName(oe.order_type));
    pos = http.appendSlice(buf, pos, "\\\",\\\"editing\\\":\\\"");
    pos = http.appendSlice(buf, pos, editFieldName(oe.editing));
    pos = http.appendSlice(buf, pos, "\\\",\\\"price\\\":\\\"");
    pos = http.appendSlice(buf, pos, oe.price_buf[0..oe.price_len]);
    pos = http.appendSlice(buf, pos, "\\\",\\\"qty\\\":\\\"");
    pos = http.appendSlice(buf, pos, oe.qty_buf[0..oe.qty_len]);
    pos = http.appendSlice(buf, pos, "\\\",\\\"stop\\\":\\\"");
    pos = http.appendSlice(buf, pos, oe.stop_buf[0..oe.stop_len]);
    pos = http.appendSlice(buf, pos, "\\\",\\\"tp\\\":\\\"");
    pos = http.appendSlice(buf, pos, oe.tp_buf[0..oe.tp_len]);
    pos = http.appendSlice(buf, pos, "\\\",\\\"sl\\\":\\\"");
    pos = http.appendSlice(buf, pos, oe.sl_buf[0..oe.sl_len]);
    pos = http.appendSlice(buf, pos, "\\\",\\\"leverage\\\":");
    pos = fmtFloat(buf, pos, oe.leverage);
    pos = http.appendSlice(buf, pos, ",\\\"reduce_only\\\":");
    pos = http.appendSlice(buf, pos, if (oe.reduce_only) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"post_only\\\":");
    pos = http.appendSlice(buf, pos, if (oe.post_only) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"submitting\\\":");
    pos = http.appendSlice(buf, pos, if (oe.submitting) "true" else "false");
    pos = http.appendSlice(buf, pos, "}}");

    pos = http.appendSlice(buf, pos, "\"}],\"isError\":false}}");
    return pos;
}

// ── Strategy result query formatter ─────────────────────────────────
const STRAT_STATUS = [4][]const u8{ "idle", "compile_error", "backtested", "live_running" };

fn fmtStrategyResult(buf: *[RESP_SIZE]u8, id: i64) usize {
    const st = ring.loadFrameState() orelse {
        return fmtToolResult(buf, id, "state not available", true);
    };
    const s = &st.strategy;

    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{");

    pos = http.appendSlice(buf, pos, "\\\"open\\\":");
    pos = http.appendSlice(buf, pos, if (s.open) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"status\\\":\\\"");
    pos = http.appendSlice(buf, pos, if (s.status < 4) STRAT_STATUS[s.status] else "?");
    pos = http.appendSlice(buf, pos, "\\\",\\\"live_armed\\\":");
    pos = http.appendSlice(buf, pos, if (s.live_armed) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"compiled\\\":");
    pos = http.appendSlice(buf, pos, if (s.compiled) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"script_len\\\":");
    pos = http.appendUint(buf, pos, s.script_len);
    pos = http.appendSlice(buf, pos, ",\\\"ran\\\":");
    pos = http.appendSlice(buf, pos, if (s.ran) "true" else "false");
    pos = http.appendSlice(buf, pos, ",\\\"bars\\\":");
    pos = http.appendUint(buf, pos, s.bars);
    pos = http.appendSlice(buf, pos, ",\\\"trades\\\":");
    pos = http.appendUint(buf, pos, s.trades);
    pos = http.appendSlice(buf, pos, ",\\\"wins\\\":");
    pos = http.appendUint(buf, pos, s.wins);
    pos = http.appendSlice(buf, pos, ",\\\"losses\\\":");
    pos = http.appendUint(buf, pos, s.losses);
    pos = http.appendSlice(buf, pos, ",\\\"pnl_pct\\\":");
    pos = fmtFloat(buf, pos, s.total_pnl_pct);
    pos = http.appendSlice(buf, pos, ",\\\"fees\\\":");
    pos = fmtFloat(buf, pos, s.total_fees);
    pos = http.appendSlice(buf, pos, ",\\\"win_rate\\\":");
    pos = fmtFloat(buf, pos, s.win_rate);
    pos = http.appendSlice(buf, pos, ",\\\"max_drawdown_pct\\\":");
    pos = fmtFloat(buf, pos, s.max_drawdown_pct);
    pos = http.appendSlice(buf, pos, ",\\\"message\\\":\\\"");
    pos = appendEscaped(buf, pos, s.msg[0..s.msg_len]);
    pos = http.appendSlice(buf, pos, "\\\",\\\"error\\\":\\\"");
    pos = appendEscaped(buf, pos, s.err[0..s.err_len]);
    pos = http.appendSlice(buf, pos, "\\\"}");

    pos = http.appendSlice(buf, pos, "\"}],\"isError\":false}}");
    return pos;
}

// ── Strategy params query formatter ─────────────────────────────────
fn fmtStrategyParams(buf: *[RESP_SIZE]u8, id: i64) usize {
    const st = ring.loadFrameState() orelse {
        return fmtToolResult(buf, id, "state not available", true);
    };
    const s = &st.strategy;

    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[");

    var i: usize = 0;
    while (i < s.param_count and i < s.params.len) : (i += 1) {
        const p = &s.params[i];
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        pos = http.appendSlice(buf, pos, "{\\\"name\\\":\\\"");
        pos = appendEscaped(buf, pos, p.name[0..p.name_len]);
        pos = http.appendSlice(buf, pos, "\\\",\\\"default\\\":");
        pos = fmtFloat(buf, pos, p.default);
        pos = http.appendSlice(buf, pos, ",\\\"value\\\":");
        pos = fmtFloat(buf, pos, p.value);
        pos = http.appendSlice(buf, pos, ",\\\"overridden\\\":");
        pos = http.appendSlice(buf, pos, if (p.overridden) "true" else "false");
        pos = http.appendSlice(buf, pos, "}");
    }

    pos = http.appendSlice(buf, pos, "]");
    pos = http.appendSlice(buf, pos, "\"}],\"isError\":false}}");
    return pos;
}

/// Append text with JSON-in-JSON escaping for the doubly-quoted text field.
fn appendEscaped(buf: *[RESP_SIZE]u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |c| {
        if (p + 3 >= buf.len) break;
        if (c == '"') {
            p = http.appendSlice(buf, p, "\\\\\\\"");
        } else if (c == '\\') {
            p = http.appendSlice(buf, p, "\\\\");
        } else if (c >= 0x20) {
            buf[p] = c;
            p += 1;
        }
    }
    return p;
}

/// Format a float with up to 8 decimal places (no allocator).
fn fmtFloat(buf: *[RESP_SIZE]u8, pos: usize, val: f64) usize {
    if (val == 0) {
        return http.appendSlice(buf, pos, "0");
    }
    var p = pos;
    var v = val;
    if (v < 0) {
        if (p >= buf.len) return p;
        buf[p] = '-';
        p += 1;
        v = -v;
    }
    // Integer part
    const int_part: u64 = @intFromFloat(v);
    p = http.appendUint(buf, p, int_part);
    // Fractional part (up to 8 digits)
    const frac = v - @as(f64, @floatFromInt(int_part));
    if (frac > 0.000000005) {
        if (p >= buf.len) return p;
        buf[p] = '.';
        p += 1;
        var f_val = frac;
        var digits: usize = 0;
        while (digits < 8 and f_val > 0.000000005) : (digits += 1) {
            f_val *= 10;
            const d: u8 = @intFromFloat(f_val);
            if (p >= buf.len) return p;
            buf[p] = '0' + d;
            p += 1;
            f_val -= @as(f64, @floatFromInt(d));
        }
    }
    return p;
}

// ── Log query formatter ─────────────────────────────────────────────
const LEVEL_NAMES = [5][]const u8{ "ERR", "WARN", "INFO", "DBG", "TRC" };

fn fmtLogsResult(buf: *[RESP_SIZE]u8, id: i64, count: usize) usize {
    const wp = @atomicLoad(u32, &ring_log.write_pos, .acquire);
    if (wp == 0) {
        return fmtToolResult(buf, id, "(no log entries)", false);
    }

    const total = @min(wp, ring_log.MAX_ENTRIES);
    const n = @min(count, total);

    // Build newline-separated log text inside the JSON text field
    var pos: usize = 0;
    pos = http.appendSlice(buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(buf, pos, id);
    pos = http.appendSlice(buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");

    // Walk from oldest to newest of the last `n` entries
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry_idx = (wp - n + i) % ring_log.MAX_ENTRIES;
        const entry = &ring_log.entries[entry_idx];
        const elen = @atomicLoad(u8, &entry.len, .acquire);
        if (elen == 0) continue;

        if (i > 0) {
            pos = http.appendSlice(buf, pos, "\\n");
        }

        // Level prefix
        const lvl = entry.level;
        if (lvl < 5) {
            pos = http.appendSlice(buf, pos, LEVEL_NAMES[lvl]);
        } else {
            pos = http.appendSlice(buf, pos, "???");
        }
        pos = http.appendSlice(buf, pos, " ");

        // Log text — escape quotes and backslashes for JSON
        const line = entry.buf[0..elen];
        for (line) |c| {
            if (pos + 2 >= buf.len) break;
            if (c == '"') {
                pos = http.appendSlice(buf, pos, "\\\"");
            } else if (c == '\\') {
                pos = http.appendSlice(buf, pos, "\\\\");
            } else if (c == '\n') {
                pos = http.appendSlice(buf, pos, "\\n");
            } else if (c >= 0x20) {
                buf[pos] = c;
                pos += 1;
            }
        }
    }

    pos = http.appendSlice(buf, pos, "\"}],\"isError\":false}}");
    return pos;
}
