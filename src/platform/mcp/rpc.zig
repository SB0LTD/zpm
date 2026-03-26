// JSON-RPC dispatch — initialize, tools/list, tools/call
// Layer 1: Platform

const w32 = @import("win32");
const json = @import("json");
const oes = @import("core").trading.order_entry_state;
const Action = @import("core").ui.action.Action;
const http = @import("http.zig");
const t = @import("types.zig");
const ring = @import("channel.zig");
const scr = @import("screenshot.zig");
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

    const args = json.findObject(params, "\"arguments\"");

    // Simple no-arg actions
    const simple_map = .{
        .{ "scroll_left", Action.scroll_left },
        .{ "scroll_right", Action.scroll_right },
        .{ "zoom_in", Action.zoom_in },
        .{ "zoom_out", Action.zoom_out },
        .{ "reset_view", Action.reset_view },
        .{ "toggle_crosshair", Action.toggle_crosshair },
        .{ "open_settings", Action.open_settings },
        .{ "close_settings", Action.close_settings },
        .{ "toggle_debug", Action.toggle_debug },
        .{ "close_debug", Action.close_debug },
        .{ "settings_nav_up", Action.settings_nav_up },
        .{ "settings_nav_down", Action.settings_nav_down },
        .{ "settings_cycle_prev", Action.settings_cycle_prev },
        .{ "settings_cycle_next", Action.settings_cycle_next },
        .{ "settings_confirm", Action.settings_confirm },
        .{ "settings_begin_edit", Action.settings_begin_edit },
        .{ "settings_backspace", Action.settings_backspace },
        .{ "apply_settings", Action.apply_settings },
        .{ "order_type_cycle_next", Action.order_type_cycle_next },
        .{ "order_type_cycle_prev", Action.order_type_cycle_prev },
        .{ "order_side_buy", Action.order_side_buy },
        .{ "order_side_sell", Action.order_side_sell },
        .{ "order_backspace", Action.order_backspace },
        .{ "order_submit", Action.order_submit },
        .{ "order_toggle_reduce_only", Action.order_toggle_reduce_only },
        .{ "order_toggle_post_only", Action.order_toggle_post_only },
        .{ "settings_filter_clear", Action.settings_filter_clear },
        .{ "settings_filter_confirm", Action.settings_filter_confirm },
        .{ "settings_filter_backspace", Action.settings_filter_backspace },
    };

    inline for (simple_map) |entry| {
        if (http.eql(name, entry[0])) {
            ring.ringPush(entry[1]);
            return fmtToolResult(buf, id, "ok", false);
        }
    }

    // Parameterized actions

    // ── Request-response actions ────────────────────────────
    if (http.eql(name, "settings_type")) {
        if (args) |a| {
            if (json.getString(a, "\"char\"")) |ch| {
                if (ch.len == 1 and ch[0] <= 127) {
                    ring.ringPush(.{ .settings_type = ch[0] });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: char must be single ASCII", true);
    }

    if (http.eql(name, "settings_filter_type")) {
        if (args) |a| {
            if (json.getString(a, "\"char\"")) |ch| {
                if (ch.len == 1 and ch[0] <= 127) {
                    ring.ringPush(.{ .settings_filter_type = ch[0] });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: char must be single ASCII", true);
    }

    if (http.eql(name, "order_set_type")) {
        if (args) |a| {
            if (json.getString(a, "\"order_type\"")) |ot| {
                if (parseOrderType(ot)) |otype| {
                    ring.ringPush(.{ .order_type_tab = otype });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: invalid order_type", true);
    }

    if (http.eql(name, "order_focus_field")) {
        if (args) |a| {
            if (json.getString(a, "\"field\"")) |f| {
                if (parseEditField(f)) |ef| {
                    ring.ringPush(.{ .order_field_click = ef });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: invalid field", true);
    }

    if (http.eql(name, "order_set_field")) {
        if (args) |a| {
            if (json.getString(a, "\"field\"")) |f| {
                if (parseEditField(f)) |ef| {
                    const val = json.getString(a, "\"value\"") orelse "";
                    var fv = @import("core").ui.action.FieldValue{ .field = ef };
                    const n = @min(val.len, 23);
                    for (0..n) |i| fv.buf[i] = val[i];
                    fv.len = @intCast(n);
                    ring.ringPush(.{ .order_set_field = fv });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: invalid field", true);
    }

    if (http.eql(name, "order_type_char")) {
        if (args) |a| {
            if (json.getString(a, "\"char\"")) |ch| {
                if (ch.len == 1 and ch[0] <= 127) {
                    ring.ringPush(.{ .order_type_char = ch[0] });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: char must be single ASCII", true);
    }

    if (http.eql(name, "order_set_leverage")) {
        if (args) |a| {
            if (json.getFloat(a, "\"value\"")) |v| {
                if (v >= 0.0 and v <= 1.0) {
                    ring.ringPush(.{ .order_leverage = v });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: value must be 0.0-1.0", true);
    }

    if (http.eql(name, "order_cancel")) {
        if (args) |a| {
            if (json.getInt(a, "\"index\"")) |idx| {
                if (idx >= 0) {
                    ring.ringPush(.{ .order_cancel = @intCast(idx) });
                    return fmtToolResult(buf, id, "ok", false);
                }
            }
        }
        return fmtToolResult(buf, id, "error: index must be non-negative", true);
    }

    if (http.eql(name, "debug_scroll")) {
        if (args) |a| {
            if (json.getInt(a, "\"delta\"")) |d| {
                ring.ringPush(.{ .debug_scroll = @truncate(d) });
                return fmtToolResult(buf, id, "ok", false);
            }
        }
        return fmtToolResult(buf, id, "error: delta required", true);
    }

    // ── Query tools (read-only) ─────────────────────────────
    if (http.eql(name, "get_status")) {
        return fmtStatusResult(buf, id);
    }

    if (http.eql(name, "get_logs")) {
        const count: usize = if (args) |a| blk: {
            const v = json.getInt(a, "\"lines\"") orelse 50;
            break :blk @intCast(@min(@max(v, 1), 256));
        } else 50;
        return fmtLogsResult(buf, id, count);
    }

    return fmtToolResult(buf, id, "error: unknown tool", true);
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
