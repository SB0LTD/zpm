// MCP server — public API (delegates to mcp/ directory module)
// Layer 1: Platform

const r = @import("mcp/run.sig");
pub const FrameState = @import("core").ui.frame_state.FrameState;
pub const SeqLock = @import("seqlock").SeqLock;

pub const init = r.init;
pub const deinit = r.deinit;
pub const poll = r.poll;
pub const writeResponse = r.writeResponse;
pub const ringPush = r.ringPush;
pub const ringRequest = r.ringRequest;
pub const nextSeq = r.nextSeq;
pub const loadFrameState = r.loadFrameState;
