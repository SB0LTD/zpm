// Input — public re-export shim
// Callers import this file; implementation lives in input/
const run = @import("input/run.zig");
pub const AppState = run.AppState;
pub const TitleBarHover = run.TitleBarHover;
pub const Action = run.Action;
pub const ActionQueue = run.ActionQueue;
pub const TITLE_BAR_HEIGHT = run.TITLE_BAR_HEIGHT;
pub const BUTTON_WIDTH = run.BUTTON_WIDTH;
pub const wndProc = run.wndProc;
pub const bind = run.bind;
pub const setHwnd = run.setHwnd;
