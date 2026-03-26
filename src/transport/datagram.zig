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

    /// Initialize with all fields zeroed, disabled.
    pub fn init() DatagramHandler {
        return .{
            .enabled = false,
            .max_size = 0,
            .peer_max_size = 0,
            .out_queue = [_]QueueSlot{.{
                .data = [_]u8{0} ** max_datagram_size,
                .len = 0,
                .valid = false,
            }} ** queue_capacity,
            .out_head = 0,
            .out_tail = 0,
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

    /// Called when a DATAGRAM frame is received. Returns the payload slice
    /// if enabled and within size limits, null otherwise.
    pub fn onReceive(self: *const DatagramHandler, data: []const u8) ?[]const u8 {
        if (!self.enabled) return null;
        if (data.len > self.max_size) return null;
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

    const big = [_]u8{0xAA} ** 11;
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
