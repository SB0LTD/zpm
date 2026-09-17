// Mouse and window interaction — drag, hover, hit-testing
// Layer 1: Platform

const w32 = @import("win32");
const gl = @import("gl");
const state_mod = @import("state.sig");
const action_mod = @import("core").ui.action;

pub const TITLE_BAR_HEIGHT: i32 = 32;
pub const BUTTON_WIDTH: i32 = 46;

// ── Layout constants (must match app/run.sig) ───────────────────────
const SIDEBAR_W: f32 = 300;
const ORDERS_H: f32 = 160;
// MUST match OB_FRAC in the app's run.sig — the sidebar order-book/order-entry
// split drives order-entry hit-testing. If these desync, clicks miss the fields.
const OB_FRAC: f32 = 0.42;
const STATUS_BAR_H: f32 = 28;

var g_state: *state_mod.AppState = undefined;
var g_hwnd: w32.HWND = undefined;

pub fn bind(s: *state_mod.AppState) void {
    g_state = s;
}

pub fn setHwnd(hwnd: w32.HWND) void {
    g_hwnd = hwnd;
}

pub fn handleHitTest(hwnd: w32.HWND, lparam: w32.LPARAM) w32.LRESULT {
    var cursor = w32.POINT{
        .x = @as(i16, @bitCast(@as(u16, @truncate(@as(u32, @bitCast(@as(i32, @truncate(lparam)))) & 0xFFFF)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate((@as(u32, @bitCast(@as(i32, @truncate(lparam)))) >> 16) & 0xFFFF)))),
    };
    _ = w32.ScreenToClient(hwnd, &cursor);

    const w = g_state.width;
    const y = cursor.y;
    const x = cursor.x;

    if (y < TITLE_BAR_HEIGHT) {
        const btn_area_start = w - BUTTON_WIDTH * 3;
        if (x >= btn_area_start) return w32.HTCLIENT;
        return w32.HTCAPTION;
    }
    return w32.HTCLIENT;
}

pub fn handleMouseMove(hwnd: w32.HWND, lparam: w32.LPARAM) void {
    _ = hwnd;
    const mx = loword(lparam);
    const my_raw = hiword(lparam);

    g_state.chart.mouse_x = mx;
    g_state.chart.mouse_y = @as(f32, @floatFromInt(g_state.height)) - my_raw;

    const w_f: f32 = @floatFromInt(g_state.width);
    const btn_w: f32 = @floatFromInt(BUTTON_WIDTH);
    const tb_h: f32 = @floatFromInt(TITLE_BAR_HEIGHT);

    if (my_raw < tb_h) {
        if (mx >= w_f - btn_w) {
            g_state.title_hover = .close;
        } else if (mx >= w_f - btn_w * 2) {
            g_state.title_hover = .maximize;
        } else if (mx >= w_f - btn_w * 3) {
            g_state.title_hover = .minimize;
        } else {
            g_state.title_hover = .none;
        }
    } else {
        g_state.title_hover = .none;
    }

    if (g_state.chart.dragging) {
        const dx = mx - g_state.chart.drag_start_x;
        const cpp = g_state.chart.visible_count / @as(f64, @floatFromInt(g_state.width));
        g_state.chart.scroll_offset = g_state.chart.drag_start_offset + @as(f64, @floatCast(dx)) * cpp;
    }
}

pub fn handleTitleBarClick(hwnd: w32.HWND) void {
    switch (g_state.title_hover) {
        .close => w32.PostQuitMessage(0),
        .maximize => {
            if (g_state.maximized) {
                _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
            } else {
                _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
            }
        },
        .minimize => _ = w32.ShowWindow(hwnd, w32.SW_HIDE),
        .none => {},
    }
}

pub fn handleMouseDown(hwnd: w32.HWND, lparam: w32.LPARAM) void {
    _ = hwnd;
    if (g_state.title_hover != .none) return;

    const mx = loword(lparam);
    const my_raw = hiword(lparam);
    const win_w: f32 = @floatFromInt(g_state.width);
    const win_h: f32 = @floatFromInt(g_state.height);
    const titlebar_h: f32 = @floatFromInt(TITLE_BAR_HEIGHT);
    const my_gl = win_h - my_raw;

    // ── Strategy panel is modal — route all clicks to it while open ──
    if (g_state.strategy_open) {
        g_state.actions.push(.{ .strategy_click = .{
            .px = mx,
            .py = my_gl,
            .w = win_w,
            .h = win_h,
        } });
        return;
    }

    const bottom_strip = titlebar_h + STATUS_BAR_H + g_state.portfolio_h;
    const sidebar_x = win_w - SIDEBAR_W;

    // ── Portfolio panel (position Close / Market-Close buttons) ───────
    // Sits between the status bar and the open-orders panel:
    //   my_gl ∈ [titlebar_h + STATUS_BAR_H, bottom_strip). Pass ABSOLUTE
    //   coords — the widget records button rects in screen/GL space.
    const port_bottom_gl = titlebar_h + STATUS_BAR_H;
    if (g_state.portfolio_h > 0 and my_gl >= port_bottom_gl and my_gl < bottom_strip) {
        g_state.actions.push(.{ .order_field_click = .none });
        g_state.actions.push(.{ .portfolio_click = .{
            .px = mx,
            .py = my_gl,
            .w = win_w,
            .h = g_state.portfolio_h,
        } });
        return;
    }

    // ── Open orders panel ─────────────────────────────────────────────
    // The open-orders panel is drawn full-width (x=0..win_w) but the sidebar
    // (order book + order entry) is drawn ON TOP of its right SIDEBAR_W column.
    // So only treat clicks LEFT of the sidebar as open-orders — otherwise this
    // band would steal every sidebar field/button click in the same Y range
    // (that was the bug: order-entry fields below the buttons were unclickable).
    const oo_bottom_gl = bottom_strip;
    const oo_top_gl = oo_bottom_gl + ORDERS_H;
    if (mx < sidebar_x and my_gl >= oo_bottom_gl and my_gl < oo_top_gl) {
        // Clicking outside order entry clears field focus
        g_state.actions.push(.{ .order_field_click = .none });
        g_state.actions.push(.{ .open_orders_click = .{
            .px = mx,
            .py = my_gl - oo_bottom_gl,
            .w = win_w,
            .h = ORDERS_H,
        } });
        return;
    }

    // ── Right sidebar ─────────────────────────────────────────────────
    if (mx >= sidebar_x) {
        const sidebar_h = win_h - titlebar_h - bottom_strip;
        const ob_h = sidebar_h * OB_FRAC;
        const oe_h = sidebar_h - ob_h;
        const oe_bottom_gl = bottom_strip;

        if (my_gl >= oe_bottom_gl and my_gl < oe_bottom_gl + oe_h) {
            g_state.actions.push(.{ .order_entry_click = .{
                .px = mx - sidebar_x,
                .py = my_gl - oe_bottom_gl,
                .w = SIDEBAR_W,
                .h = oe_h,
            } });
        } else {
            // Clicked on order book area — clear field focus
            g_state.actions.push(.{ .order_field_click = .none });
        }
        return;
    }

    // ── Chart area — clear field focus ────────────────────────────────
    g_state.actions.push(.{ .order_field_click = .none });

    // ── Chart drag ────────────────────────────────────────────────────
    if (isShiftDown()) {
        g_state.chart.dragging = true;
        g_state.chart.drag_start_x = mx;
        g_state.chart.drag_start_offset = g_state.chart.scroll_offset;
    }
}

pub fn handleWheel(wparam: w32.WPARAM) void {
    const wheel_delta: i16 = @bitCast(@as(u16, @truncate((@as(u64, @bitCast(wparam)) >> 16) & 0xFFFF)));
    if (g_state.debug.open) {
        g_state.actions.push(.{ .debug_scroll = if (wheel_delta > 0) 3 else -3 });
        return;
    }
    if (isShiftDown()) {
        g_state.actions.push(if (wheel_delta > 0) .zoom_in else .zoom_out);
    } else {
        g_state.chart.scroll_offset += if (wheel_delta > 0) 3.0 else -3.0;
    }
}

pub fn handleResize(lparam: w32.LPARAM) void {
    const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
    g_state.width = @as(i32, @intCast(lp & 0xFFFF));
    g_state.height = @as(i32, @intCast((lp >> 16) & 0xFFFF));
    if (g_state.width > 0 and g_state.height > 0) {
        gl.glViewport(0, 0, g_state.width, g_state.height);
    }
}

pub fn isShiftDown() bool {
    const state = w32.GetKeyState(0x10);
    return (@as(u16, @bitCast(state)) & 0x8000) != 0;
}

pub fn loword(lp: w32.LPARAM) f32 {
    const lp32: u32 = @bitCast(@as(i32, @truncate(lp)));
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(lp32 & 0xFFFF)))));
}

pub fn hiword(lp: w32.LPARAM) f32 {
    const lp32: u32 = @bitCast(@as(i32, @truncate(lp)));
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate((lp32 >> 16) & 0xFFFF)))));
}
