//! Network Interface Abstraction
//!
//! Hardware-agnostic NIC interface that the network stack binds to.
//! Any driver (GVE, VirtIO, etc.) implements these function pointers
//! to provide frame-level send/recv to the upper layers.
//!
//! Also provides a static frame buffer pool for zero-allocation RX/TX.

// ══════════════════════════════════════════════════════════════════════════════
// NIC Interface
// ══════════════════════════════════════════════════════════════════════════════

/// Abstract network interface. A NIC driver populates this struct with
/// function pointers to its send/recv/query operations. The network stack
/// calls through this interface without knowing the underlying hardware.
pub const NetInterface = struct {
    /// Send a complete Ethernet frame (header + payload, max 1514 bytes).
    /// Returns true if the frame was successfully submitted to hardware.
    send_frame: *const fn (frame: []const u8) bool,

    /// Poll for a received Ethernet frame. Returns the frame data or null
    /// if no frame is available. The returned slice is valid until the next
    /// call to recv_frame (single-buffer semantics).
    recv_frame: *const fn () ?[]const u8,

    /// Get the interface MAC address (6 bytes).
    get_mac: *const fn () [6]u8,

    /// Get the interface MTU (maximum payload size, typically 1500).
    get_mtu: *const fn () u16,

    /// Query link state. Returns true if the physical link is up.
    link_up: *const fn () bool,

    /// Send a frame to the given interface. Convenience wrapper.
    pub fn send(self: *const NetInterface, frame: []const u8) bool {
        return self.send_frame(frame);
    }

    /// Receive a frame. Convenience wrapper.
    pub fn recv(self: *const NetInterface) ?[]const u8 {
        return self.recv_frame();
    }

    /// Get MAC. Convenience wrapper.
    pub fn mac(self: *const NetInterface) [6]u8 {
        return self.get_mac();
    }

    /// Get MTU. Convenience wrapper.
    pub fn mtu(self: *const NetInterface) u16 {
        return self.get_mtu();
    }

    /// Check link. Convenience wrapper.
    pub fn isLinkUp(self: *const NetInterface) bool {
        return self.link_up();
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Frame Buffer Pool
// ══════════════════════════════════════════════════════════════════════════════

/// Maximum Ethernet frame size (without FCS — NIC handles that).
const MAX_FRAME: usize = 1514;

/// Number of TX frame buffers in the static pool.
const TX_POOL_SIZE: usize = 16;

/// A single frame buffer with length tracking.
pub const FrameBuffer = struct {
    data: [MAX_FRAME]u8,
    len: u16,
    in_use: bool,

    pub fn slice(self: *const FrameBuffer) []const u8 {
        return self.data[0..self.len];
    }

    pub fn sliceMut(self: *FrameBuffer) []u8 {
        return &self.data;
    }
};

/// Static pool of TX frame buffers. Acquire before building a frame,
/// release after the NIC has consumed it (or immediately for sync sends).
var tx_pool: [TX_POOL_SIZE]FrameBuffer = blk: {
    var pool: [TX_POOL_SIZE]FrameBuffer = undefined;
    for (&pool) |*buf| {
        buf.data = @splat(0);
        buf.len = 0;
        buf.in_use = false;
    }
    break :blk pool;
};

/// Acquire a frame buffer from the TX pool.
/// Returns null if all buffers are in use (backpressure).
pub fn acquireBuffer() ?*FrameBuffer {
    for (&tx_pool) |*buf| {
        if (!buf.in_use) {
            buf.in_use = true;
            buf.len = 0;
            return buf;
        }
    }
    return null;
}

/// Release a frame buffer back to the TX pool.
pub fn releaseBuffer(buf: *FrameBuffer) void {
    buf.in_use = false;
    buf.len = 0;
}

/// Get the number of free buffers in the TX pool.
pub fn freeBufferCount() usize {
    var count: usize = 0;
    for (&tx_pool) |*buf| {
        if (!buf.in_use) count += 1;
    }
    return count;
}
