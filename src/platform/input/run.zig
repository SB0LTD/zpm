// Input module entry point — re-exports public API
// Layer 1: Platform
//
// Keyboard produces Actions via ActionQueue — fully decoupled from app logic.
// Mouse/window state (drag, hover, resize) mutates AppState directly since
// those are continuous pointer/geometry concerns, not discrete commands.

const wndproc = @import("wndproc.zig");
const mouse = @import("mouse.zig");

pub const state_mod = @import("state.zig");
pub const AppState = state_mod.AppState;
pub const TitleBarHover = state_mod.TitleBarHover;
pub const Action = state_mod.Action;
pub const ActionQueue = state_mod.ActionQueue;

pub const TITLE_BAR_HEIGHT = mouse.TITLE_BAR_HEIGHT;
pub const BUTTON_WIDTH = mouse.BUTTON_WIDTH;

pub const wndProc = wndproc.wndProc;

pub fn bind(s: *AppState) void {
    wndproc.bind(s);
}

pub fn setHwnd(hwnd: @import("win32").HWND) void {
    wndproc.setHwnd(hwnd);
}
