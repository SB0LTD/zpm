// AppState — shared mutable state between wndProc and render thread
// Layer 1: Platform

const core = @import("core");
const types = core.types;
const ChartState = types.ChartState;
const SettingsState = core.ui.settings_state.SettingsState;
const DebugState = core.ui.debug_state.DebugState;
const action_mod = core.ui.action;
const oes = core.trading.order_entry_state;

pub const Action = action_mod.Action;
pub const ActionQueue = action_mod.ActionQueue;

/// Title bar button hover state
pub const TitleBarHover = enum { none, close, maximize, minimize };

pub const AppState = struct {
    width: i32 = 1280,
    height: i32 = 720,
    chart: ChartState = .{},
    /// Which title bar button is hovered (for rendering)
    title_hover: TitleBarHover = .none,
    /// Is the window maximized
    maximized: bool = false,
    /// Settings overlay state
    settings: SettingsState = .{},
    /// Debug console state
    debug: DebugState = .{},
    /// Pending actions for the app layer to consume
    actions: ActionQueue = .{},
    /// Snapshot of order entry state for hit-testing (updated each frame by app)
    order_entry_snapshot: oes.OrderEntryState = .{},
    /// Portfolio panel height for hit-testing (updated each frame by app)
    portfolio_h: f32 = 0,
};
