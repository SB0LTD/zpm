// MCP channel — thread-safe action ring and request-response protocol
// Layer 1: Platform (internal to mcp/ module)
//
// SPSC ring buffer for fire-and-forget actions (MCP thread → main thread).
// Request-response channel for actions that need a result (e.g. screenshot).
// Uses atomics for cross-thread synchronization, no allocator.

const w32 = @import("win32");
const Action = @import("core").ui.action.Action;
const ActionQueue = @import("core").ui.action.ActionQueue;
const FrameState = @import("core").ui.frame_state.FrameState;
const SeqLock = @import("seqlock").SeqLock;

// ── Thread-safe action ring (SPSC) ─────────────────────────────────

const RING_CAP = 64;
var g_ring: [RING_CAP]Action = undefined;
var g_ring_head: usize = 0;
var g_ring_tail: usize = 0;

pub fn ringPush(a: Action) void {
    const head = @atomicLoad(usize, &g_ring_head, .acquire);
    const tail = @atomicLoad(usize, &g_ring_tail, .acquire);
    const next = (head + 1) % RING_CAP;
    if (next == tail) return;
    g_ring[head] = a;
    @atomicStore(usize, &g_ring_head, next, .release);
}

/// Drain pending actions from MCP thread into the main-thread queue.
pub fn poll(queue: *ActionQueue) void {
    while (true) {
        const head = @atomicLoad(usize, &g_ring_head, .acquire);
        const tail = @atomicLoad(usize, &g_ring_tail, .acquire);
        if (tail == head) break;
        queue.push(g_ring[tail]);
        @atomicStore(usize, &g_ring_tail, (tail + 1) % RING_CAP, .release);
    }
}

// ── Request-response channel ────────────────────────────────────────

const RESP_BUF: usize = 256;

var g_req_seq: u64 = 0;
var g_resp_seq: u64 = 0;
var g_resp_buf: [RESP_BUF]u8 = undefined;
var g_resp_len: usize = 0;

/// Push an action and wait for the main thread to respond.
/// Returns the response payload, or empty slice on timeout.
pub fn ringRequest(a: Action) []const u8 {
    g_req_seq +%= 1;
    ringPush(a);

    var attempts: u32 = 0;
    while (attempts < 3000) : (attempts += 1) {
        if (@atomicLoad(u64, &g_resp_seq, .acquire) == g_req_seq) {
            return g_resp_buf[0..g_resp_len];
        }
        w32.Sleep(1);
    }
    return &[_]u8{};
}

/// Called by the main thread to deliver a response for a request.
pub fn writeResponse(seq: u64, data: []const u8) void {
    const n = @min(data.len, RESP_BUF);
    @memcpy(g_resp_buf[0..n], data[0..n]);
    g_resp_len = n;
    @atomicStore(u64, &g_resp_seq, seq, .release);
}

/// Get the current request sequence number (for building request actions).
pub fn nextSeq() u64 {
    return g_req_seq +% 1;
}

// ── Shared state accessor ───────────────────────────────────────────

var g_state: ?*const SeqLock(FrameState) = null;

pub fn setState(state: *const SeqLock(FrameState)) void {
    g_state = state;
}

/// Read a consistent FrameState snapshot (retries on torn read).
pub fn loadFrameState() ?FrameState {
    const sl = g_state orelse return null;
    return sl.load();
}
