// Core module root — re-exports all core subsystems
// Layer 0: Core
//
// Uses module imports (not relative @import) to avoid
// "file exists in multiple modules" when granular modules
// share the same source files.

pub const math = @import("math");
pub const json = @import("json");
pub const types = @import("types.zig");
pub const fmt = @import("fmt.zig");
pub const config = @import("config.zig");
pub const config_types = @import("config_types.zig");
pub const metadata = @import("metadata.zig");
pub const aggregator = @import("aggregator.zig");
pub const trading = struct {
    pub const order = @import("trading/order.zig");
    pub const order_entry_state = @import("trading/order_entry_state.zig");
    pub const orderbook = @import("trading/orderbook.zig");
    pub const position = @import("trading/position.zig");
};
pub const ui = struct {
    pub const action = @import("ui/action.zig");
    pub const debug_state = @import("ui/debug_state.zig");
    pub const settings_state = @import("ui/settings_state.zig");
    pub const frame_state = @import("ui/frame_state.zig");
    pub const ring_log = @import("ui/ring_log.zig");
};
pub const data = struct {
    pub const manager = @import("data/manager.zig");
    pub const data_types = @import("data/types.zig");
    pub const cache_reader = @import("data/cache_reader.zig");
};
