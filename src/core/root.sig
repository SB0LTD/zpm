// Core module root — re-exports all core subsystems
// Layer 0: Core
//
// Uses module imports (not relative @import) to avoid
// "file exists in multiple modules" when granular modules
// share the same source files.

pub const math = @import("math");
pub const json = @import("json");
pub const sha256 = @import("sha256");
pub const jsonl = @import("jsonl");
pub const ai_core = @import("ai_core");
pub const quantized_linear = @import("quantized_linear");
pub const transformer_ops = @import("transformer_ops");
pub const vector_memory = @import("vector_memory");
pub const moment_activation = @import("moment_activation");
pub const agent_runtime = @import("agent_runtime");
pub const cognitive_receipt = @import("cognitive_receipt");
pub const model_observability = @import("model_observability");
pub const multimodal_now = @import("multimodal_now");
pub const types = @import("types.sig");
pub const fmt = @import("fmt.sig");
pub const config = @import("config.sig");
pub const config_types = @import("config_types.sig");
pub const metadata = @import("metadata.sig");
pub const aggregator = @import("aggregator.sig");
pub const trading = struct {
    pub const order = @import("trading/order.sig");
    pub const order_entry_state = @import("trading/order_entry_state.sig");
    pub const orderbook = @import("trading/orderbook.sig");
    pub const position = @import("trading/position.sig");
};
pub const ui = struct {
    pub const action = @import("ui/action.sig");
    pub const debug_state = @import("ui/debug_state.sig");
    pub const settings_state = @import("ui/settings_state.sig");
    pub const frame_state = @import("ui/frame_state.sig");
    pub const ring_log = @import("ui/ring_log.sig");
};
pub const data = struct {
    pub const manager = @import("data/manager.sig");
    pub const data_types = @import("data/types.sig");
    pub const cache_reader = @import("data/cache_reader.sig");
};
