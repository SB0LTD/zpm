// Layer 1 — DATAGRAM frame handling.
//
// Implements RFC 9221 DATAGRAM frames for the Hot lane.
// Fixed-size outbound ring queue, no buffering on receive —
// immediate delivery. Zero allocator usage.

const packet = @import("packet");

/// Conservative default max datagram payload size.
pub const max_datagram_size: u16 = 1200;

/// Number of outbound queue slots.
const queue_capacity: u8 = 16;

/// A single outbound queue slot.
const QueueSlot = struct {
    data: [max_datagram_size]u8,
    len: u16,
    valid: bool,
};

/// Handles RFC 9221 DATAGRAM frames for unreliable, latest-wins delivery.
pub const DatagramHandler = struct {
    enabled: bool,
    max_size: u16,
    peer_max_size: u16,

    out_queue: [queue_capacity]QueueSlot,
    out_head: u8,
    out_tail: u8,

    // Inbound ring: received DATAGRAM payloads are COPIED here so they survive
    // the next socket recv (which overwrites conn.recv_buf). Drained by
    // dequeueReceived (e.g. mesh_transport.pollGossip).
    in_queue: [queue_capacity]QueueSlot,
    in_head: u8,
    in_tail: u8,

    /// Initialize with all fields zeroed, disabled.
    pub fn init() DatagramHandler {
        return .{
            .enabled = false,
            .max_size = 0,
            .peer_max_size = 0,
            .out_queue = @as([queue_capacity]QueueSlot, @splat(QueueSlot{
                .data = @as([max_datagram_size]u8, @splat(0)),
                .len = 0,
                .valid = false,
            })),
            .out_head = 0,
            .out_tail = 0,
            .in_queue = @as([queue_capacity]QueueSlot, @splat(QueueSlot{
                .data = @as([max_datagram_size]u8, @splat(0)),
                .len = 0,
                .valid = false,
            })),
            .in_head = 0,
            .in_tail = 0,
        };
    }

    /// Queue a datagram for sending. Returns false if queue full or data too large.
    pub fn queueSend(self: *DatagramHandler, data: []const u8) bool {
        if (data.len > self.peer_max_size) return false;
        if (data.len > max_datagram_size) return false;

        const slot = &self.out_queue[self.out_tail];
        if (slot.valid) return false; // queue full

        const len: u16 = @intCast(data.len);
        @memcpy(slot.data[0..len], data);
        slot.len = len;
        slot.valid = true;
        self.out_tail = (self.out_tail + 1) % queue_capacity;
        return true;
    }

    /// Dequeue the next datagram to include in an outgoing packet.
    pub fn dequeueSend(self: *DatagramHandler) ?struct { data: []const u8 } {
        const slot = &self.out_queue[self.out_head];
        if (!slot.valid) return null;

        const data: []const u8 = slot.data[0..slot.len];
        slot.valid = false;
        self.out_head = (self.out_head + 1) % queue_capacity;
        return .{ .data = data };
    }

    /// Peek at the next datagram without consuming it.
    pub fn peekSend(self: *const DatagramHandler) ?struct { data: []const u8 } {
        const slot = &self.out_queue[self.out_head];
        if (!slot.valid) return null;
        return .{ .data = slot.data[0..slot.len] };
    }

    /// Called when a DATAGRAM frame is received. Returns the payload slice
    /// if enabled and within size limits, null otherwise.
    pub fn onReceive(self: *const DatagramHandler, data: []const u8) ?[]const u8 {
        if (!self.enabled) return null;
        if (data.len > self.max_size) return null;
        return data;
    }

    /// Copy a received DATAGRAM payload into the inbound ring so it outlives
    /// the connection's recv_buf (overwritten by the next socket recv).
    /// Applies the same enabled/max_size gate as onReceive. Returns false if
    /// disabled, oversized, or the inbound ring is full (RFC 9221 datagrams are
    /// unreliable, so a full ring simply drops the datagram).
    pub fn enqueueReceived(self: *DatagramHandler, data: []const u8) bool {
        if (!self.enabled) return false;
        if (data.len > self.max_size) return false;
        if (data.len > max_datagram_size) return false;

        const slot = &self.in_queue[self.in_tail];
        if (slot.valid) return false; // ring full

        const len: u16 = @intCast(data.len);
        @memcpy(slot.data[0..len], data);
        slot.len = len;
        slot.valid = true;
        self.in_tail = (self.in_tail + 1) % queue_capacity;
        return true;
    }

    /// Dequeue the next inbound DATAGRAM payload (a slice into the owned ring
    /// slot), or null when the inbound ring is empty.
    pub fn dequeueReceived(self: *DatagramHandler) ?[]const u8 {
        const slot = &self.in_queue[self.in_head];
        if (!slot.valid) return null;

        const data: []const u8 = slot.data[0..slot.len];
        slot.valid = false;
        self.in_head = (self.in_head + 1) % queue_capacity;
        return data;
    }
};

// ── Tests ──

const testing = @import("std").testing;

test "queueSend + dequeueSend round-trip" {
    var h = DatagramHandler.init();
    h.peer_max_size = max_datagram_size;

    const payload = "hello datagram";
    try testing.expect(h.queueSend(payload));

    const result = h.dequeueSend() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, result.data);
}

test "queue full — 16 succeed, 17th fails" {
    var h = DatagramHandler.init();
    h.peer_max_size = max_datagram_size;

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try testing.expect(h.queueSend(&[_]u8{i}));
    }
    try testing.expect(!h.queueSend(&[_]u8{99}));
}

test "oversized datagram rejected" {
    var h = DatagramHandler.init();
    h.peer_max_size = 10;

    const big = @as([11]u8, @splat(0xAA));
    try testing.expect(!h.queueSend(&big));
}

test "empty queue returns null" {
    var h = DatagramHandler.init();
    try testing.expect(h.dequeueSend() == null);
}

test "onReceive returns data when enabled" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = max_datagram_size;

    const payload = "hot lane data";
    const result = h.onReceive(payload) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, result);
}

test "onReceive returns null when disabled" {
    var h = DatagramHandler.init();
    h.enabled = false;
    h.max_size = max_datagram_size;

    try testing.expect(h.onReceive("anything") == null);
}

test "onReceive rejects oversized" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = 5;

    const big = "too long for max_size";
    try testing.expect(h.onReceive(big) == null);
}

test "FIFO ordering" {
    var h = DatagramHandler.init();
    h.peer_max_size = max_datagram_size;

    try testing.expect(h.queueSend("first"));
    try testing.expect(h.queueSend("second"));
    try testing.expect(h.queueSend("third"));

    const r1 = h.dequeueSend() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, "first", r1.data);

    const r2 = h.dequeueSend() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, "second", r2.data);

    const r3 = h.dequeueSend() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, "third", r3.data);

    try testing.expect(h.dequeueSend() == null);
}

test "inbound ring: enqueueReceived + dequeueReceived round-trip" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = max_datagram_size;

    const payload = "inbound datagram payload";
    try testing.expect(h.enqueueReceived(payload));

    const got = h.dequeueReceived() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, got);

    // Drained — now empty.
    try testing.expect(h.dequeueReceived() == null);
}

test "inbound ring: payload is copied (survives source mutation)" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = max_datagram_size;

    var src: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expect(h.enqueueReceived(&src));
    // Overwrite the source after enqueue — simulates recv_buf being reused.
    @memset(&src, 0xFF);

    const got = h.dequeueReceived() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, got);
}

test "inbound ring: disabled rejects enqueue" {
    var h = DatagramHandler.init();
    h.enabled = false;
    h.max_size = max_datagram_size;
    try testing.expect(!h.enqueueReceived("x"));
}

test "inbound ring: oversized rejected" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = 4;
    try testing.expect(!h.enqueueReceived("too long"));
}

test "inbound ring: FIFO ordering" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = max_datagram_size;

    try testing.expect(h.enqueueReceived("a"));
    try testing.expect(h.enqueueReceived("bb"));
    try testing.expect(h.enqueueReceived("ccc"));

    try testing.expectEqualSlices(u8, "a", h.dequeueReceived().?);
    try testing.expectEqualSlices(u8, "bb", h.dequeueReceived().?);
    try testing.expectEqualSlices(u8, "ccc", h.dequeueReceived().?);
    try testing.expect(h.dequeueReceived() == null);
}

test "inbound ring: full ring drops (16 succeed, 17th fails)" {
    var h = DatagramHandler.init();
    h.enabled = true;
    h.max_size = max_datagram_size;

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try testing.expect(h.enqueueReceived(&[_]u8{i}));
    }
    try testing.expect(!h.enqueueReceived(&[_]u8{99}));
}
