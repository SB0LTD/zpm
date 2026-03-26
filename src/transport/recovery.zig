// Layer 1 — Loss detection and congestion control.
//
// Implements RFC 9002 NewReno congestion control and loss detection.
// Pure state machine — no I/O. All time values stored as QPC ticks,
// converted to microseconds via qpc_freq for RTT calculations.
// Zero allocator usage.

const packet = @import("packet");
const AckRange = packet.AckRange;

/// Maximum number of tracked sent packets per packet number space.
pub const max_sent_packets: u16 = 256;

/// MSS (Maximum Segment Size) for congestion control calculations.
const mss: u64 = 1472;

/// Default max ACK delay in microseconds (25ms per RFC 9002).
const max_ack_delay_us: u64 = 25000;

/// Minimum time threshold for loss detection in microseconds (1ms).
const min_time_threshold_us: u64 = 1000;

/// Packet number spaces — local definition since conn.zig doesn't exist yet.
pub const PktNumSpace = enum(u2) {
    initial = 0,
    handshake = 1,
    application = 2,
};

/// Metadata for a sent packet, used for loss detection and retransmission.
pub const SentPacketInfo = struct {
    pkt_number: u64 = 0,
    sent_tick: u64 = 0,
    size: u16 = 0,
    ack_eliciting: bool = false,
    in_flight: bool = false,
    has_stream: bool = false,
    has_crypto: bool = false,
    has_datagram: bool = false,
    stream_id: u64 = 0,
    stream_offset: u64 = 0,
    stream_len: u16 = 0,
    crypto_offset: u64 = 0,
    crypto_len: u16 = 0,
};

/// Result of ACK processing — lists newly acked and lost packets.
pub const AckResult = struct {
    acked_count: u16 = 0,
    lost_count: u16 = 0,
    acked: [64]u64 = [_]u64{0} ** 64,
    lost: [64]SentPacketInfo = [_]SentPacketInfo{.{}} ** 64,
};

const max_u64 = @as(u64, 0xFFFFFFFFFFFFFFFF);

const us_per_sec: u64 = 1_000_000;

/// Convert QPC ticks to microseconds. Avoids u128 by dividing first when possible.
fn ticksToUs(qpc_freq: u64, ticks: u64) u64 {
    if (qpc_freq == 0) return 0;
    // For typical QPC frequencies (1-100MHz), we can simplify:
    // ticks * 1_000_000 / freq = ticks / (freq / 1_000_000) when freq >= 1_000_000
    // Otherwise use the safe path with overflow check
    if (qpc_freq >= us_per_sec) {
        const divisor = qpc_freq / us_per_sec;
        if (divisor == 0) return ticks * us_per_sec;
        return ticks / divisor;
    }
    // freq < 1_000_000: multiply first (won't overflow for reasonable tick values)
    return (ticks * us_per_sec) / qpc_freq;
}

/// Convert microseconds to QPC ticks.
fn usToTicks(qpc_freq: u64, us: u64) u64 {
    if (us == 0) return 0;
    if (qpc_freq >= us_per_sec) {
        const multiplier = qpc_freq / us_per_sec;
        return us * multiplier;
    }
    return (us * qpc_freq) / us_per_sec;
}

/// Loss detection and congestion control engine per RFC 9002.
pub const RecoveryEngine = struct {
    // QPC frequency for tick→microsecond conversion (placed first for reliable access)
    qpc_freq: u64,

    // RTT estimation (microseconds)
    smoothed_rtt: u64,
    rtt_var: u64,
    min_rtt: u64,
    latest_rtt: u64,

    // Congestion control (NewReno)
    cwnd: u64,
    ssthresh: u64,
    bytes_in_flight: u64,
    congestion_recovery_start: u64,

    // Loss detection
    loss_time: [3]u64,
    pto_count: u8,

    // Internal: tracks whether first RTT sample has been taken
    has_rtt_sample: bool,

    // Largest packet number sent (across all spaces)
    largest_sent_pkt: u64,

    // Sent packet tracking (per PktNumSpace)
    sent: [3][max_sent_packets]SentPacketInfo,
    sent_count: [3]u16,
    largest_acked: [3]u64,

    /// Initialize in-place with RFC 9002 defaults.
    pub fn initInPlace(self: *RecoveryEngine, qpc_freq: u64) void {
        self.smoothed_rtt = 333000;
        self.rtt_var = 166000;
        self.min_rtt = max_u64;
        self.latest_rtt = 0;
        self.cwnd = 14720;
        self.ssthresh = max_u64;
        self.bytes_in_flight = 0;
        self.congestion_recovery_start = 0;
        self.loss_time = [3]u64{ 0, 0, 0 };
        self.pto_count = 0;
        self.has_rtt_sample = false;
        self.largest_sent_pkt = 0;
        self.sent_count = [3]u16{ 0, 0, 0 };
        self.largest_acked = [3]u64{ 0, 0, 0 };
        // Zero out sent arrays
        for (0..3) |s| {
            for (0..max_sent_packets) |i| {
                self.sent[s][i] = .{};
            }
        }
        // Set qpc_freq LAST to ensure nothing overwrites it
        self.qpc_freq = qpc_freq;
    }

    /// Initialize with RFC 9002 defaults (returns by value).
    pub fn init(qpc_freq: u64) RecoveryEngine {
        return .{
            .qpc_freq = qpc_freq,
            .smoothed_rtt = 333000,
            .rtt_var = 166000,
            .min_rtt = max_u64,
            .latest_rtt = 0,
            .cwnd = 14720,
            .ssthresh = max_u64,
            .bytes_in_flight = 0,
            .congestion_recovery_start = 0,
            .loss_time = [3]u64{ 0, 0, 0 },
            .pto_count = 0,
            .has_rtt_sample = false,
            .largest_sent_pkt = 0,
            .sent = [3][max_sent_packets]SentPacketInfo{
                [_]SentPacketInfo{.{}} ** max_sent_packets,
                [_]SentPacketInfo{.{}} ** max_sent_packets,
                [_]SentPacketInfo{.{}} ** max_sent_packets,
            },
            .sent_count = [3]u16{ 0, 0, 0 },
            .largest_acked = [3]u64{ 0, 0, 0 },
        };
    }

    /// Record a sent packet for tracking.
    pub fn onPacketSent(self: *RecoveryEngine, space: PktNumSpace, info: SentPacketInfo) void {
        const s = @intFromEnum(space);
        const idx: usize = @intCast(self.sent_count[s] % max_sent_packets);

        // Evict oldest if ring is full
        if (self.sent_count[s] >= max_sent_packets) {
            const old = &self.sent[s][idx];
            if (old.in_flight and old.size > 0) {
                self.bytes_in_flight -|= old.size;
            }
        }

        self.sent[s][idx] = info;
        self.sent_count[s] +|= 1;

        if (info.pkt_number > self.largest_sent_pkt) {
            self.largest_sent_pkt = info.pkt_number;
        }

        if (info.in_flight) {
            self.bytes_in_flight += info.size;
        }
    }

    /// Process an ACK frame. Returns lists of newly acked and lost packets.
    pub fn onAckReceived(
        self: *RecoveryEngine,
        space: PktNumSpace,
        largest: u64,
        ack_delay_us_param: u64,
        ranges: []const AckRange,
        range_count: u16,
        first_range: u64,
        now_tick: u64,
    ) AckResult {
        const s = @intFromEnum(space);
        var result: AckResult = .{};

        // Update largest_acked
        if (largest > self.largest_acked[s]) {
            self.largest_acked[s] = largest;
        }

        // Reset PTO count on ACK
        self.pto_count = 0;

        // Mark acked packets: first range covers [largest - first_range, largest]
        var acked_bytes: u64 = 0;
        var largest_sent_tick: u64 = 0;
        var ack_low: u64 = largest -| first_range;
        var ack_high: u64 = largest;

        self.markAckedRange(s, ack_low, ack_high, &result, &acked_bytes, largest, &largest_sent_tick);

        // Process additional ACK ranges
        var ri: u16 = 0;
        while (ri < range_count) : (ri += 1) {
            const r = ranges[ri];
            const gap_size = r.gap + 1;
            if (ack_low <= gap_size) break;
            ack_high = ack_low - gap_size - 1;
            ack_low = ack_high -| r.length;
            self.markAckedRange(s, ack_low, ack_high, &result, &acked_bytes, largest, &largest_sent_tick);
        }

        // Update RTT from the largest acked packet
        if (largest_sent_tick > 0 and now_tick > largest_sent_tick) {
            self.updateRtt(now_tick - largest_sent_tick, ack_delay_us_param);
        }

        // Detect lost packets
        self.detectLoss(s, now_tick, &result);

        // NewReno congestion control: increase cwnd for acked data
        if (acked_bytes > 0) {
            self.congestionOnAck(acked_bytes);
        }

        // NewReno congestion control: reduce cwnd on loss
        if (result.lost_count > 0) {
            self.congestionOnLoss(&result);
        }

        return result;
    }

    /// Mark packets in [low, high] as acked, accumulate acked bytes.
    /// Also captures sent_tick for the packet matching largest_pn for RTT.
    fn markAckedRange(
        self: *RecoveryEngine,
        s: usize,
        low: u64,
        high: u64,
        result: *AckResult,
        acked_bytes: *u64,
        largest_pn: u64,
        largest_sent_tick: *u64,
    ) void {
        const limit: usize = if (self.sent_count[s] >= max_sent_packets)
            @as(usize, max_sent_packets)
        else
            @intCast(self.sent_count[s]);

        for (0..limit) |i| {
            const p = &self.sent[s][i];
            if (p.size == 0) continue;
            if (p.pkt_number >= low and p.pkt_number <= high) {
                // Capture sent_tick for RTT calculation before clearing
                if (p.pkt_number == largest_pn) {
                    largest_sent_tick.* = p.sent_tick;
                }
                if (result.acked_count < 64) {
                    result.acked[result.acked_count] = p.pkt_number;
                    result.acked_count += 1;
                }
                if (p.in_flight) {
                    acked_bytes.* += p.size;
                    self.bytes_in_flight -|= p.size;
                }
                p.* = .{};
            }
        }
    }

    /// Update RTT estimates per RFC 9002 §5.
    pub noinline fn updateRtt(self: *RecoveryEngine, rtt_ticks: u64, ack_delay_us_param: u64) void {
        self.latest_rtt = ticksToUs(self.qpc_freq, rtt_ticks);
        if (self.latest_rtt == 0) return;

        // Update min_rtt
        if (self.latest_rtt < self.min_rtt) {
            self.min_rtt = self.latest_rtt;
        }

        // Compute adjusted_rtt
        var adjusted_rtt = self.latest_rtt;
        const capped_delay = @min(ack_delay_us_param, max_ack_delay_us);
        if (adjusted_rtt > self.min_rtt and adjusted_rtt > capped_delay) {
            adjusted_rtt -= capped_delay;
        }

        // First RTT sample
        if (!self.has_rtt_sample) {
            self.smoothed_rtt = adjusted_rtt;
            self.rtt_var = adjusted_rtt / 2;
            self.has_rtt_sample = true;
        } else {
            const abs_diff = if (self.smoothed_rtt > adjusted_rtt)
                self.smoothed_rtt - adjusted_rtt
            else
                adjusted_rtt - self.smoothed_rtt;
            self.rtt_var = (3 * self.rtt_var + abs_diff) / 4;
            self.smoothed_rtt = (7 * self.smoothed_rtt + adjusted_rtt) / 8;
        }
    }

    /// Detect lost packets using time and packet thresholds per RFC 9002 §6.1.
    fn detectLoss(self: *RecoveryEngine, s: usize, now_tick: u64, result: *AckResult) void {
        const la = self.largest_acked[s];
        if (la == 0) return;

        // Time threshold: max(9/8 * latest_rtt, 1ms)
        var loss_delay_us = (self.latest_rtt * 9) / 8;
        if (loss_delay_us < min_time_threshold_us) {
            loss_delay_us = min_time_threshold_us;
        }
        const loss_delay_ticks = usToTicks(self.qpc_freq, loss_delay_us);

        const pkt_threshold: u64 = 3;
        const limit: usize = if (self.sent_count[s] >= max_sent_packets)
            @as(usize, max_sent_packets)
        else
            @intCast(self.sent_count[s]);

        for (0..limit) |i| {
            const p = &self.sent[s][i];
            if (p.size == 0) continue;
            if (p.pkt_number >= la) continue;

            var is_lost = false;

            // Time-based loss
            if (loss_delay_ticks > 0 and now_tick >= p.sent_tick + loss_delay_ticks) {
                is_lost = true;
            }

            // Packet-number-based loss
            if (la >= pkt_threshold and p.pkt_number <= la - pkt_threshold) {
                is_lost = true;
            }

            if (is_lost) {
                if (result.lost_count < 64) {
                    result.lost[result.lost_count] = p.*;
                    result.lost_count += 1;
                }
                if (p.in_flight) {
                    self.bytes_in_flight -|= p.size;
                }
                p.* = .{};
            }
        }
    }

    /// NewReno: increase cwnd on ACK of new data per RFC 9002 §7.3.
    fn congestionOnAck(self: *RecoveryEngine, acked_bytes: u64) void {
        if (self.cwnd < self.ssthresh) {
            // Slow start: cwnd += acked_bytes
            self.cwnd += acked_bytes;
        } else {
            // Congestion avoidance: cwnd += MSS * acked_bytes / cwnd
            const inc = (mss * acked_bytes) / self.cwnd;
            self.cwnd += if (inc > 0) inc else 1;
        }
    }

    /// NewReno: reduce cwnd on loss per RFC 9002 §7.3.2.
    fn congestionOnLoss(self: *RecoveryEngine, result: *const AckResult) void {
        // Find the largest lost packet number
        var largest_lost: u64 = 0;
        for (0..result.lost_count) |i| {
            if (result.lost[i].pkt_number > largest_lost) {
                largest_lost = result.lost[i].pkt_number;
            }
        }

        // No double-reduction during recovery
        if (largest_lost <= self.congestion_recovery_start) return;

        // Enter recovery: set recovery start to largest sent packet
        self.congestion_recovery_start = self.largest_sent_pkt;
        self.ssthresh = @max(self.cwnd / 2, 2 * mss);
        self.cwnd = self.ssthresh;
    }

    /// Get PTO duration in QPC ticks per RFC 9002 §6.2.
    /// PTO = smoothed_rtt + max(4 * rtt_var, 1ms) + max_ack_delay
    /// Doubles on each consecutive expiration via pto_count.
    pub fn getPto(self: *const RecoveryEngine) u64 {
        var pto_us = self.smoothed_rtt + @max(4 * self.rtt_var, min_time_threshold_us) + max_ack_delay_us;

        // Double for each consecutive PTO expiration
        var i: u8 = 0;
        while (i < self.pto_count) : (i += 1) {
            pto_us = pto_us *| 2;
        }

        return usToTicks(self.qpc_freq, pto_us);
    }

    /// Check if persistent congestion is detected per RFC 9002 §7.6.
    /// Returns true if the time span of consecutive lost packets exceeds
    /// (smoothed_rtt + max(4 * rtt_var, 1ms) + max_ack_delay) * 3.
    pub fn isPersistentCongestion(self: *RecoveryEngine, lost_range_start: u64, lost_range_end: u64) bool {
        if (lost_range_end <= lost_range_start) return false;

        const pc_threshold_us = (self.smoothed_rtt + @max(4 * self.rtt_var, min_time_threshold_us) + max_ack_delay_us) * 3;
        const span_us = ticksToUs(self.qpc_freq, lost_range_end - lost_range_start);

        if (span_us > pc_threshold_us) {
            // Reset cwnd to minimum per RFC 9002 §7.6
            self.cwnd = 2 * mss;
            return true;
        }
        return false;
    }

    /// Check if the congestion window allows sending the given number of bytes.
    pub fn canSend(self: *const RecoveryEngine, bytes: u64) bool {
        return self.bytes_in_flight + bytes <= self.cwnd;
    }
};

// ── Tests ──

const testing = @import("std").testing;

/// Module-level test engine to avoid large struct on stack.
var test_re: RecoveryEngine = undefined;

/// Helper: initialize the module-level test engine with 1MHz QPC.
fn initTestEngine() *RecoveryEngine {
    test_re.initInPlace(1_000_000);
    return &test_re;
}

/// Helper: create a basic SentPacketInfo.
fn testPkt(pkt_num: u64, sent_tick: u64, size: u16) SentPacketInfo {
    return .{
        .pkt_number = pkt_num,
        .sent_tick = sent_tick,
        .size = size,
        .ack_eliciting = true,
        .in_flight = true,
    };
}

// ── 9.2: init and RTT estimation ──

test "init defaults" {
    const re = initTestEngine();
    try testing.expectEqual(@as(u64, 14720), re.cwnd);
    try testing.expectEqual(@as(u64, 333000), re.smoothed_rtt);
    try testing.expectEqual(@as(u64, 166000), re.rtt_var);
    try testing.expectEqual(max_u64, re.min_rtt);
    try testing.expectEqual(max_u64, re.ssthresh);
    try testing.expectEqual(@as(u64, 0), re.bytes_in_flight);
    try testing.expectEqual(@as(u8, 0), re.pto_count);
}

test "RTT first sample sets smoothed_rtt directly" {
    const re = initTestEngine();
    re.onPacketSent(.initial, testPkt(1, 100_000, 100));
    const no_ranges = [_]AckRange{};
    _ = re.onAckReceived(.initial, 1, 0, &no_ranges, 0, 0, 200_000);
    try testing.expectEqual(@as(u64, 100_000), re.smoothed_rtt);
    try testing.expectEqual(@as(u64, 50_000), re.rtt_var);
    try testing.expectEqual(@as(u64, 100_000), re.min_rtt);
}

test "RTT converges toward actual RTT" {
    const re = initTestEngine();
    var tick: u64 = 1_000_000;
    var pn: u64 = 1;
    const no_ranges = [_]AckRange{};
    while (pn <= 10) : (pn += 1) {
        re.onPacketSent(.application, testPkt(pn, tick, 100));
        _ = re.onAckReceived(.application, pn, 0, &no_ranges, 0, 0, tick + 50_000);
        tick += 100_000;
    }
    try testing.expect(re.smoothed_rtt >= 49_000 and re.smoothed_rtt <= 51_000);
}

test "min_rtt tracks minimum" {
    const re = initTestEngine();
    const no_ranges = [_]AckRange{};
    re.onPacketSent(.initial, testPkt(1, 1_000_000, 100));
    _ = re.onAckReceived(.initial, 1, 0, &no_ranges, 0, 0, 1_100_000);
    try testing.expectEqual(@as(u64, 100_000), re.min_rtt);
    re.onPacketSent(.initial, testPkt(2, 2_000_000, 100));
    _ = re.onAckReceived(.initial, 2, 0, &no_ranges, 0, 0, 2_050_000);
    try testing.expectEqual(@as(u64, 50_000), re.min_rtt);
    re.onPacketSent(.initial, testPkt(3, 3_000_000, 100));
    _ = re.onAckReceived(.initial, 3, 0, &no_ranges, 0, 0, 3_080_000);
    try testing.expectEqual(@as(u64, 50_000), re.min_rtt);
}

test "ack_delay subtracted only when adjusted_rtt > min_rtt" {
    const re = initTestEngine();
    const no_ranges = [_]AckRange{};
    re.onPacketSent(.initial, testPkt(1, 1_000_000, 100));
    _ = re.onAckReceived(.initial, 1, 0, &no_ranges, 0, 0, 1_100_000);
    re.onPacketSent(.initial, testPkt(2, 2_000_000, 100));
    _ = re.onAckReceived(.initial, 2, 10_000, &no_ranges, 0, 0, 2_100_000);
    try testing.expect(re.smoothed_rtt >= 99_000 and re.smoothed_rtt <= 101_000);
    re.onPacketSent(.initial, testPkt(3, 3_000_000, 100));
    _ = re.onAckReceived(.initial, 3, 10_000, &no_ranges, 0, 0, 3_120_000);
    try testing.expect(re.smoothed_rtt > 100_000);
}

// ── 9.3: sent packet tracking ──

test "onPacketSent tracks bytes_in_flight" {
    const re = initTestEngine();
    re.onPacketSent(.initial, testPkt(1, 1000, 500));
    try testing.expectEqual(@as(u64, 500), re.bytes_in_flight);
    re.onPacketSent(.initial, testPkt(2, 2000, 300));
    try testing.expectEqual(@as(u64, 800), re.bytes_in_flight);
}

test "onPacketSent evicts oldest when full" {
    const re = initTestEngine();
    var i: u64 = 0;
    while (i < max_sent_packets) : (i += 1) {
        re.onPacketSent(.initial, testPkt(i, i * 1000, 100));
    }
    try testing.expectEqual(@as(u64, @as(u64, max_sent_packets) * 100), re.bytes_in_flight);
    re.onPacketSent(.initial, testPkt(max_sent_packets, 999_000, 200));
    try testing.expectEqual(@as(u64, @as(u64, max_sent_packets) * 100 - 100 + 200), re.bytes_in_flight);
}

// ── 9.4: ACK processing and loss detection ──

test "ack marks packets and reduces bytes_in_flight" {
    const re = initTestEngine();
    re.onPacketSent(.application, testPkt(1, 1_000_000, 500));
    re.onPacketSent(.application, testPkt(2, 1_001_000, 300));
    try testing.expectEqual(@as(u64, 800), re.bytes_in_flight);
    const no_ranges = [_]AckRange{};
    const result = re.onAckReceived(.application, 2, 0, &no_ranges, 0, 1, 1_100_000);
    try testing.expectEqual(@as(u16, 2), result.acked_count);
    try testing.expectEqual(@as(u64, 0), re.bytes_in_flight);
}

test "time-based loss detection" {
    const re = initTestEngine();
    re.onPacketSent(.application, testPkt(1, 1_000_000, 100));
    re.onPacketSent(.application, testPkt(5, 1_500_000, 100));
    const no_ranges = [_]AckRange{};
    const result = re.onAckReceived(.application, 5, 0, &no_ranges, 0, 0, 2_000_000);
    try testing.expectEqual(@as(u16, 1), result.acked_count);
    try testing.expectEqual(@as(u16, 1), result.lost_count);
    try testing.expectEqual(@as(u64, 1), result.lost[0].pkt_number);
}

test "packet-threshold loss detection" {
    const re = initTestEngine();
    var pn: u64 = 1;
    while (pn <= 6) : (pn += 1) {
        re.onPacketSent(.application, testPkt(pn, 1_000_000 + pn * 1000, 100));
    }
    const no_ranges = [_]AckRange{};
    const result = re.onAckReceived(.application, 6, 0, &no_ranges, 0, 0, 2_000_000);
    try testing.expectEqual(@as(u16, 1), result.acked_count);
    try testing.expect(result.lost_count >= 3);
}

test "no false positives for recent packets" {
    const re = initTestEngine();
    re.onPacketSent(.application, testPkt(1, 1_000_000, 100));
    re.onPacketSent(.application, testPkt(2, 1_000_100, 100));
    re.onPacketSent(.application, testPkt(3, 1_000_200, 100));
    re.onPacketSent(.application, testPkt(4, 1_000_300, 100));
    const no_ranges = [_]AckRange{};
    const result = re.onAckReceived(.application, 4, 0, &no_ranges, 0, 0, 1_000_400);
    try testing.expectEqual(@as(u16, 1), result.lost_count);
    try testing.expectEqual(@as(u64, 1), result.lost[0].pkt_number);
}

test "lost packets contain correct SentPacketInfo" {
    const re = initTestEngine();
    const info = SentPacketInfo{
        .pkt_number = 1, .sent_tick = 1_000_000, .size = 500,
        .ack_eliciting = true, .in_flight = true, .has_stream = true,
        .stream_id = 42, .stream_offset = 100, .stream_len = 200,
    };
    re.onPacketSent(.application, info);
    re.onPacketSent(.application, testPkt(5, 1_500_000, 100));
    const no_ranges = [_]AckRange{};
    const result = re.onAckReceived(.application, 5, 0, &no_ranges, 0, 0, 3_000_000);
    try testing.expect(result.lost_count >= 1);
    try testing.expectEqual(@as(u64, 1), result.lost[0].pkt_number);
    try testing.expectEqual(@as(u16, 500), result.lost[0].size);
    try testing.expect(result.lost[0].has_stream);
    try testing.expectEqual(@as(u64, 42), result.lost[0].stream_id);
}

// ── 9.5: NewReno congestion control ──

test "slow start increases cwnd by acked bytes" {
    const re = initTestEngine();
    const initial_cwnd = re.cwnd;
    re.onPacketSent(.application, testPkt(1, 1_000_000, 1000));
    const no_ranges = [_]AckRange{};
    _ = re.onAckReceived(.application, 1, 0, &no_ranges, 0, 0, 1_100_000);
    try testing.expectEqual(initial_cwnd + 1000, re.cwnd);
}

test "congestion avoidance increases cwnd slowly" {
    const re = initTestEngine();
    re.ssthresh = 10000;
    re.cwnd = 10000;
    re.onPacketSent(.application, testPkt(1, 1_000_000, 1000));
    const no_ranges = [_]AckRange{};
    _ = re.onAckReceived(.application, 1, 0, &no_ranges, 0, 0, 1_100_000);
    try testing.expect(re.cwnd > 10000 and re.cwnd <= 10200);
}

test "loss halves cwnd and enters recovery" {
    const re = initTestEngine();
    re.cwnd = 20000;
    re.ssthresh = max_u64;
    re.onPacketSent(.application, testPkt(1, 1_000_000, 1000));
    re.onPacketSent(.application, testPkt(5, 1_500_000, 1000));
    const no_ranges = [_]AckRange{};
    _ = re.onAckReceived(.application, 5, 0, &no_ranges, 0, 0, 3_000_000);
    try testing.expectEqual(re.cwnd, re.ssthresh);
    try testing.expect(re.cwnd >= 2 * mss);
}

test "no double-reduction during recovery" {
    const re = initTestEngine();
    re.cwnd = 20000;
    re.onPacketSent(.application, testPkt(1, 1_000_000, 1000));
    re.onPacketSent(.application, testPkt(5, 1_500_000, 1000));
    const no_ranges = [_]AckRange{};
    _ = re.onAckReceived(.application, 5, 0, &no_ranges, 0, 0, 3_000_000);
    const cwnd_after_first_loss = re.cwnd;
    re.onPacketSent(.application, testPkt(2, 4_000_000, 1000));
    re.onPacketSent(.application, testPkt(4, 4_500_000, 1000));
    _ = re.onAckReceived(.application, 4, 0, &no_ranges, 0, 0, 6_000_000);
    try testing.expect(re.cwnd >= cwnd_after_first_loss);
}

test "persistent congestion resets cwnd to minimum" {
    const re = initTestEngine();
    re.cwnd = 50000;
    re.smoothed_rtt = 100_000;
    re.rtt_var = 25_000;
    re.has_rtt_sample = true;
    const is_pc = re.isPersistentCongestion(1_000_000, 2_000_000);
    try testing.expect(is_pc);
    try testing.expectEqual(2 * mss, re.cwnd);
}

test "canSend respects congestion window" {
    const re = initTestEngine();
    re.cwnd = 10000;
    re.bytes_in_flight = 9000;
    try testing.expect(re.canSend(1000));
    try testing.expect(!re.canSend(1001));
    try testing.expect(re.canSend(0));
}

// ── 9.6: PTO ──

test "PTO matches formula" {
    const re = initTestEngine();
    re.smoothed_rtt = 100_000;
    re.rtt_var = 25_000;
    re.has_rtt_sample = true;
    const pto_ticks = re.getPto();
    const pto_us = ticksToUs(re.qpc_freq, pto_ticks);
    try testing.expectEqual(@as(u64, 225_000), pto_us);
}

test "PTO doubles on consecutive expirations" {
    const re = initTestEngine();
    re.smoothed_rtt = 100_000;
    re.rtt_var = 25_000;
    re.has_rtt_sample = true;
    const base_pto = ticksToUs(re.qpc_freq, re.getPto());
    re.pto_count = 1;
    const doubled = ticksToUs(re.qpc_freq, re.getPto());
    try testing.expectEqual(base_pto * 2, doubled);
    re.pto_count = 2;
    const quadrupled = ticksToUs(re.qpc_freq, re.getPto());
    try testing.expectEqual(base_pto * 4, quadrupled);
}

test "PTO resets on ACK" {
    const re = initTestEngine();
    re.pto_count = 3;
    re.onPacketSent(.application, testPkt(1, 1_000_000, 100));
    const no_ranges = [_]AckRange{};
    _ = re.onAckReceived(.application, 1, 0, &no_ranges, 0, 0, 1_100_000);
    try testing.expectEqual(@as(u8, 0), re.pto_count);
}
