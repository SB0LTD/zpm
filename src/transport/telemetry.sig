// Layer 1 — Telemetry counters.
//
// Per-connection diagnostic counters for packets, bytes, RTT,
// congestion window, and connection state. All mutations use
// atomic RMW; snapshot reads use acquire-ordered atomic loads
// for lock-free access from `zpm doctor`. Zero allocator usage.

/// Per-connection telemetry counters.
///
/// All u64/u32/u8 counter fields are updated atomically so that
/// a concurrent `snapshot()` always sees a consistent value per
/// field without any locking.
pub const TelemetryCounters = struct {
    packets_sent: u64,
    packets_received: u64,
    packets_lost: u64,
    bytes_sent: u64,
    bytes_received: u64,
    handshake_duration_us: u64,
    smoothed_rtt_us: u64,
    cwnd: u64,
    conn_state: u8,
    negotiated_version: u32,

    /// Return a zeroed TelemetryCounters.
    pub fn init() TelemetryCounters {
        return .{
            .packets_sent = 0,
            .packets_received = 0,
            .packets_lost = 0,
            .bytes_sent = 0,
            .bytes_received = 0,
            .handshake_duration_us = 0,
            .smoothed_rtt_us = 0,
            .cwnd = 0,
            .conn_state = 0,
            .negotiated_version = 0,
        };
    }

    /// Record a sent packet: atomically increment packets_sent
    /// and add `bytes` to bytes_sent.
    pub fn recordSent(self: *TelemetryCounters, bytes: u16) void {
        _ = @atomicRmw(u64, &self.packets_sent, .Add, 1, .monotonic);
        _ = @atomicRmw(u64, &self.bytes_sent, .Add, @as(u64, bytes), .monotonic);
    }

    /// Record a received packet: atomically increment packets_received
    /// and add `bytes` to bytes_received.
    pub fn recordReceived(self: *TelemetryCounters, bytes: u16) void {
        _ = @atomicRmw(u64, &self.packets_received, .Add, 1, .monotonic);
        _ = @atomicRmw(u64, &self.bytes_received, .Add, @as(u64, bytes), .monotonic);
    }

    /// Record a lost packet: atomically increment packets_lost.
    pub fn recordLoss(self: *TelemetryCounters) void {
        _ = @atomicRmw(u64, &self.packets_lost, .Add, 1, .monotonic);
    }

    /// Return a snapshot with every field read via acquire-ordered
    /// atomic load, safe for lock-free cross-thread reads.
    pub fn snapshot(self: *const TelemetryCounters) TelemetryCounters {
        return .{
            .packets_sent = @atomicLoad(u64, &self.packets_sent, .acquire),
            .packets_received = @atomicLoad(u64, &self.packets_received, .acquire),
            .packets_lost = @atomicLoad(u64, &self.packets_lost, .acquire),
            .bytes_sent = @atomicLoad(u64, &self.bytes_sent, .acquire),
            .bytes_received = @atomicLoad(u64, &self.bytes_received, .acquire),
            .handshake_duration_us = @atomicLoad(u64, &self.handshake_duration_us, .acquire),
            .smoothed_rtt_us = @atomicLoad(u64, &self.smoothed_rtt_us, .acquire),
            .cwnd = @atomicLoad(u64, &self.cwnd, .acquire),
            .conn_state = @atomicLoad(u8, &self.conn_state, .acquire),
            .negotiated_version = @atomicLoad(u32, &self.negotiated_version, .acquire),
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────

const testing = @import("std").testing;

test "init: all counters zero" {
    const tc = TelemetryCounters.init();
    try testing.expectEqual(@as(u64, 0), tc.packets_sent);
    try testing.expectEqual(@as(u64, 0), tc.packets_received);
    try testing.expectEqual(@as(u64, 0), tc.packets_lost);
    try testing.expectEqual(@as(u64, 0), tc.bytes_sent);
    try testing.expectEqual(@as(u64, 0), tc.bytes_received);
    try testing.expectEqual(@as(u64, 0), tc.handshake_duration_us);
    try testing.expectEqual(@as(u64, 0), tc.smoothed_rtt_us);
    try testing.expectEqual(@as(u64, 0), tc.cwnd);
    try testing.expectEqual(@as(u8, 0), tc.conn_state);
    try testing.expectEqual(@as(u32, 0), tc.negotiated_version);
}

test "recordSent increments packets_sent and bytes_sent" {
    var tc = TelemetryCounters.init();
    tc.recordSent(100);
    try testing.expectEqual(@as(u64, 1), tc.packets_sent);
    try testing.expectEqual(@as(u64, 100), tc.bytes_sent);
}

test "recordReceived increments packets_received and bytes_received" {
    var tc = TelemetryCounters.init();
    tc.recordReceived(200);
    try testing.expectEqual(@as(u64, 1), tc.packets_received);
    try testing.expectEqual(@as(u64, 200), tc.bytes_received);
}

test "recordLoss increments packets_lost" {
    var tc = TelemetryCounters.init();
    tc.recordLoss();
    try testing.expectEqual(@as(u64, 1), tc.packets_lost);
}

test "snapshot returns consistent values" {
    var tc = TelemetryCounters.init();
    tc.recordSent(50);
    tc.recordSent(75);
    tc.recordReceived(120);
    tc.recordLoss();

    const snap = tc.snapshot();
    try testing.expectEqual(@as(u64, 2), snap.packets_sent);
    try testing.expectEqual(@as(u64, 125), snap.bytes_sent);
    try testing.expectEqual(@as(u64, 1), snap.packets_received);
    try testing.expectEqual(@as(u64, 120), snap.bytes_received);
    try testing.expectEqual(@as(u64, 1), snap.packets_lost);
}

test "multiple increments accumulate" {
    var tc = TelemetryCounters.init();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        tc.recordSent(100);
        tc.recordReceived(80);
        tc.recordLoss();
    }

    const snap = tc.snapshot();
    try testing.expectEqual(@as(u64, 10), snap.packets_sent);
    try testing.expectEqual(@as(u64, 1000), snap.bytes_sent);
    try testing.expectEqual(@as(u64, 10), snap.packets_received);
    try testing.expectEqual(@as(u64, 800), snap.bytes_received);
    try testing.expectEqual(@as(u64, 10), snap.packets_lost);
}
