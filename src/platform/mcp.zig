// MCP server — public API (delegates to mcp/ directory module)
// Layer 1: Platform

const r = @import("mcp/run.zig");
pub const FrameState = @import("core").ui.frame_state.FrameState;
pub const SeqLock = @import("seqlock").SeqLock;

pub const init = r.init;
pub const deinit = r.deinit;
pub const poll = r.poll;
