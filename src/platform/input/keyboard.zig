// Keyboard → Action translation
// Layer 1: Platform

const w32 = @import("win32");
const log = @import("logging");
const state_mod = @import("state.zig");
const oes = @import("core").trading.order_entry_state;

// g_state is owned by wndproc.zig — accessed via pointer set at bind time
var g_state: *state_mod.AppState = undefined;

pub fn bind(s: *state_mod.AppState) void {
    g_state = s;
}

pub fn handleKeyDown(wparam: w32.WPARAM) void {
    const vk: u32 = @truncate(@as(usize, @bitCast(wparam)));
    log.info(.{ "key down: ", vkName(vk) });

    // Debug console — backtick toggles, ESC closes
    if (vk == 0xC0) {
        g_state.actions.push(.toggle_debug);
        return;
    }
    if (g_state.debug.open and vk == 0x1B) {
        g_state.actions.push(.close_debug);
        return;
    }

    // Settings panel
    if (g_state.settings.open) {
        translateSettingsKey(vk);
        return;
    }

    // Order entry field focused
    if (g_state.order_entry_snapshot.editing != .none) {
        switch (vk) {
            0x08 => g_state.actions.push(.order_backspace),
            0x0D => g_state.actions.push(.order_submit),
            0x1B => g_state.actions.push(.{ .order_field_click = .none }),
            0x09 => {
                // Tab cycles to next field based on current order type
                const next = nextEditField(g_state.order_entry_snapshot);
                g_state.actions.push(.{ .order_field_click = next });
            },
            else => {},
        }
        return;
    }

    // Chart / global
    switch (vk) {
        0x25 => g_state.actions.push(.scroll_left),
        0x27 => g_state.actions.push(.scroll_right),
        0x26 => g_state.actions.push(.zoom_in),
        0x28 => g_state.actions.push(.zoom_out),
        0xBB => g_state.actions.push(.zoom_in),
        0xBD => g_state.actions.push(.zoom_out),
        0x43 => g_state.actions.push(.toggle_crosshair),
        0x52 => g_state.actions.push(.reset_view),
        0x53 => g_state.actions.push(.open_settings),
        0x50 => g_state.actions.push(.screenshot),
        else => {},
    }
}

pub fn handleKeyUp(wparam: w32.WPARAM) void {
    const vk: u32 = @truncate(@as(usize, @bitCast(wparam)));
    log.info(.{ "key up: ", vkName(vk) });
}

pub fn handleChar(wparam: w32.WPARAM) void {
    const ch: u8 = @truncate(@as(usize, @bitCast(wparam)));
    if (ch < 32 or ch > 126) return;

    // Order entry field takes priority
    if (g_state.order_entry_snapshot.editing != .none) {
        g_state.actions.push(.{ .order_type_char = ch });
        return;
    }

    if (!g_state.settings.open) return;

    if (g_state.settings.selected == 1 and g_state.settings.hasMetadata()) {
        g_state.actions.push(.{ .settings_filter_type = ch });
        return;
    }

    if (g_state.settings.editing) {
        g_state.actions.push(.{ .settings_type = ch });
    }
}

fn translateSettingsKey(vk: u32) void {
    switch (vk) {
        0x1B => {
            if (g_state.settings.filter_active) {
                g_state.actions.push(.settings_filter_clear);
            } else {
                g_state.actions.push(.close_settings);
            }
        },
        0x26 => g_state.actions.push(.settings_nav_up),
        0x28 => g_state.actions.push(.settings_nav_down),
        0x25 => g_state.actions.push(.settings_cycle_prev),
        0x27 => g_state.actions.push(.settings_cycle_next),
        0x0D => {
            if (g_state.settings.filter_active) {
                g_state.actions.push(.settings_filter_confirm);
            } else if (g_state.settings.editing) {
                g_state.actions.push(.settings_confirm);
            } else {
                g_state.actions.push(.apply_settings);
            }
        },
        0x08 => {
            if (g_state.settings.selected == 1 and g_state.settings.filter_active) {
                g_state.actions.push(.settings_filter_backspace);
            } else {
                g_state.actions.push(.settings_backspace);
            }
        },
        0x46 => g_state.actions.push(.settings_begin_edit),
        0x53 => g_state.actions.push(.close_settings),
        else => {},
    }
}

/// Cycle to the next visible edit field based on current order type.
fn nextEditField(snap: oes.OrderEntryState) oes.EditField {
    // Build list of visible fields in layout order
    var fields: [5]oes.EditField = undefined;
    var count: usize = 0;
    if (snap.needsPrice()) {
        fields[count] = .price;
        count += 1;
    }
    if (snap.needsStop()) {
        fields[count] = .stop_price;
        count += 1;
    }
    fields[count] = .qty;
    count += 1;
    if (snap.needsTpSl()) {
        fields[count] = .tp_price;
        count += 1;
        fields[count] = .sl_price;
        count += 1;
    }
    // Find current and advance
    for (fields[0..count], 0..) |f, i| {
        if (f == snap.editing) {
            return fields[(i + 1) % count];
        }
    }
    return fields[0];
}

fn vkName(vk: u32) []const u8 {
    return switch (vk) {
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0x0D => "Enter",
        0x1B => "Escape",
        0x08 => "Backspace",
        0x09 => "Tab",
        0x20 => "Space",
        0x43 => "C",
        0x46 => "F",
        0x52 => "R",
        0x53 => "S",
        0x50 => "P",
        0xBB => "Plus",
        0xBD => "Minus",
        0xC0 => "Backtick",
        0x10 => "Shift",
        0x11 => "Ctrl",
        0x12 => "Alt",
        else => "?",
    };
}
