// Layer 2 — Packet scheduler.
//
// Assembles outgoing packets by coalescing frames from multiple sources.
// Enforces priority ordering (ACK > CRYPTO > Control stream 0 > DATAGRAM > Bulk streams 4+)
// and pacing. Standalone utility — receives sub-component pointers rather than
// a *Connection to avoid circular imports with conn.zig.
// Zero allocator usage.

const packet = @import("packet");
const streams = @import("streams");
const datagram = @import("datagram");
const recovery = @import("recovery");
const transport_crypto = @import("transport_crypto");
const telemetry = @import("telemetry");

const Frame = packet.Frame;
const PacketHeader = packet.PacketHeader;
const SerializeResult = packet.SerializeResult;

/// Packet number space — local definition matching conn.PktNumSpace to avoid importing conn.
pub const PktNumSpace = enum(u2) {
    initial = 0,
    handshake = 1,
    application = 2,
};

/// Minimum QUIC packet size (path MTU floor per RFC 9000).
const min_mtu: u16 = 1200;

/// Default path MTU.
const default_mtu: u16 = 1200;

/// AEAD tag overhead (AES-128-GCM).
const aead_overhead: u16 = 16;

/// Default initial pacing rate: 10 × MSS / 333ms ≈ 44KB/s.
const default_pacing_rate: u64 = 44_000;

/// Microseconds per second.
const us_per_sec: u64 = 1_000_000;

/// Assembles outgoing packets by coalescing frames from multiple sources.
/// Enforces priority ordering and pacing.
pub const Scheduler = struct {
    // Pacing state
    next_send_tick: u64,
    pacing_rate: u64, // bytes per second

    // Pending frame flags (priority-ordered assembly)
    pending_acks: [3]bool, // per PktNumSpace
    pending_crypto: bool,
    pending_handshake_done: bool,

    /// Initialize with default values.
    pub fn init() Scheduler {
        return .{
            .next_send_tick = 0,
            .pacing_rate = default_pacing_rate,
            .pending_acks = [3]bool{ false, false, false },
            .pending_crypto = false,
            .pending_handshake_done = false,
        };
    }

    /// Check if pacing allows sending now.
    pub fn canSendNow(self: *const Scheduler, now_tick: u64) bool {
        return now_tick >= self.next_send_tick;
    }

    /// Update pacing rate based on congestion window and smoothed RTT.
    /// pacing_rate = cwnd * 1_000_000 / srtt_us (bytes per second).
    /// Computes next_send_tick from last packet size and pacing rate.
    pub fn updatePacing(self: *Scheduler, cwnd: u64, srtt_us: u64) void {
        if (srtt_us == 0 or cwnd == 0) {
            self.pacing_rate = default_pacing_rate;
            return;
        }
        // pacing_rate = cwnd / srtt_us * 1_000_000 = cwnd * 1_000_000 / srtt_us
        self.pacing_rate = (cwnd * us_per_sec) / srtt_us;
        if (self.pacing_rate == 0) self.pacing_rate = 1;
    }


    /// Assemble the next outgoing packet. Coalesces frames in priority order:
    /// 1. ACK frames
    /// 2. CRYPTO frames (handshake)
    /// 3. Control lane stream data (stream 0)
    /// 4. Hot lane DATAGRAM frames
    /// 5. Bulk lane stream data (streams 4+)
    ///
    /// Takes individual sub-component pointers (not *Connection) to avoid circular dependency.
    /// Returns bytes written to send_buf, or 0 if nothing to send.
    pub fn assemblePacket(
        self: *Scheduler,
        send_buf: []u8,
        tls: *transport_crypto.TlsEngine,
        recovery_eng: *recovery.RecoveryEngine,
        stream_mgr: *streams.StreamManager,
        dgrams: *datagram.DatagramHandler,
        telem: *telemetry.TelemetryCounters,
        ack_needed: *[3]bool,
        largest_recv_pkt: *const [3]u64,
        next_pkt_num: *[3]u64,
        space: PktNumSpace,
        now_tick: u64,
    ) u16 {
        const space_idx: usize = @intFromEnum(space);

        // Check if there's anything to send
        const has_ack = ack_needed[space_idx];
        const has_crypto = (tls.send_len > 0);
        var has_stream_data = false;
        for (0..stream_mgr.stream_count) |i| {
            const s = &stream_mgr.streams[i];
            if (s.send_buf.available() > 0 and
                (s.state == .open or s.state == .half_closed_remote))
            {
                has_stream_data = true;
                break;
            }
        }

        if (!has_ack and !has_crypto and !has_stream_data and !self.pending_handshake_done) {
            return 0;
        }

        // Check congestion window (allow ACK-only packets through)
        const cwnd_ok = recovery_eng.canSend(1);
        if (!cwnd_ok and !has_ack) return 0;

        var pos: u16 = 0;
        const mtu: u16 = default_mtu;

        // Build packet header
        var hdr = PacketHeader{};
        const is_handshake = (space == .initial or space == .handshake);
        if (is_handshake) {
            hdr.is_long = true;
            hdr.version = @intFromEnum(packet.Version.quic_v1);
            hdr.pkt_type = if (space == .initial) .initial else .handshake;
        } else {
            hdr.is_long = false;
        }
        hdr.payload_len = 0; // filled after frame assembly for long headers

        // Serialize header placeholder
        const hdr_result = packet.serializeHeader(&hdr, send_buf);
        if (hdr_result.err != .none) return 0;
        pos = hdr_result.len;

        // Packet number (1 byte for simplicity)
        if (pos >= send_buf.len) return 0;
        const pn: u8 = @truncate(next_pkt_num[space_idx]);
        send_buf[pos] = pn;
        send_buf[0] = (send_buf[0] & 0xFC); // pn_len = 1 (0b00)
        pos += 1;

        const payload_start = pos;
        var is_ack_eliciting = false;

        // ── Priority 1: ACK frames ──
        if (has_ack) {
            const ack_frame = Frame{ .ack = .{
                .largest_acked = largest_recv_pkt[space_idx],
                .ack_delay = 0,
                .range_count = 0,
                .first_range = 0,
            } };
            const fr = packet.serializeFrame(&ack_frame, send_buf[pos..]);
            if (fr.err == .none and fr.len > 0 and pos + fr.len <= mtu) {
                pos += fr.len;
                ack_needed[space_idx] = false;
            }
        }

        // ── Priority 2: CRYPTO frames ──
        if (has_crypto and tls.send_len > 0 and cwnd_ok) {
            const crypto_len = tls.send_len;
            const crypto_frame = Frame{ .crypto = .{
                .offset = 0,
                .data_offset = 0,
                .data_len = crypto_len,
            } };
            const fr = packet.serializeFrame(&crypto_frame, send_buf[pos..]);
            if (fr.err == .none and fr.len > 0 and pos + fr.len + crypto_len <= mtu) {
                pos += fr.len;
                @memcpy(send_buf[pos .. pos + crypto_len], tls.send_buf[0..crypto_len]);
                pos += crypto_len;
                tls.send_len = 0;
                is_ack_eliciting = true;
            }
        }

        // ── Priority 3: HANDSHAKE_DONE ──
        if (self.pending_handshake_done and cwnd_ok) {
            const hd_frame = Frame{ .handshake_done = {} };
            const fr = packet.serializeFrame(&hd_frame, send_buf[pos..]);
            if (fr.err == .none and fr.len > 0 and pos + fr.len <= mtu) {
                pos += fr.len;
                self.pending_handshake_done = false;
                is_ack_eliciting = true;
            }
        }

        // ── Priority 4: Control lane (stream 0) ──
        if (space == .application and cwnd_ok) {
            if (stream_mgr.getStream(0)) |s0| {
                if (s0.send_buf.available() > 0 and
                    (s0.state == .open or s0.state == .half_closed_remote))
                {
                    const avail = s0.send_buf.available();
                    const room = if (mtu > pos + 32) mtu - pos - 32 else 0;
                    const max_data: u32 = @intCast(@min(avail, room));
                    if (max_data > 0) {
                        var stream_data: [1200]u8 = undefined;
                        const read_n = s0.send_buf.read(stream_data[0..max_data]);
                        if (read_n > 0) {
                            const sf = Frame{ .stream = .{
                                .stream_id = 0,
                                .offset = s0.send_acked,
                                .data_offset = 0,
                                .data_len = @intCast(read_n),
                                .fin = false,
                            } };
                            const fr = packet.serializeFrame(&sf, send_buf[pos..]);
                            if (fr.err == .none and fr.len > 0 and pos + fr.len + read_n <= mtu) {
                                pos += fr.len;
                                @memcpy(send_buf[pos .. pos + read_n], stream_data[0..read_n]);
                                pos += @intCast(read_n);
                                s0.send_acked += read_n;
                                is_ack_eliciting = true;
                            }
                        }
                    }
                }
            }
        }

        // ── Priority 5: Hot lane (DATAGRAM) ──
        if (space == .application and cwnd_ok) {
            if (dgrams.dequeueSend()) |dg| {
                const dg_frame = Frame{ .datagram = .{
                    .data_offset = 0,
                    .data_len = @intCast(dg.data.len),
                } };
                const fr = packet.serializeFrame(&dg_frame, send_buf[pos..]);
                if (fr.err == .none and fr.len > 0 and pos + fr.len + dg.data.len <= mtu) {
                    pos += fr.len;
                    @memcpy(send_buf[pos .. pos + dg.data.len], dg.data);
                    pos += @intCast(dg.data.len);
                    is_ack_eliciting = true;
                }
            }
        }

        // ── Priority 6: Bulk lane (streams 4+) ──
        if (space == .application and cwnd_ok) {
            for (0..stream_mgr.stream_count) |i| {
                const s = &stream_mgr.streams[i];
                if (s.id == 0) continue; // skip control stream
                if (s.send_buf.available() == 0) continue;
                if (s.state != .open and s.state != .half_closed_remote) continue;
                if (pos + 32 >= mtu) break;

                const avail = s.send_buf.available();
                const remaining: u32 = @intCast(if (mtu > pos + 32) mtu - pos - 32 else 0);
                const to_send: u32 = @min(avail, remaining);
                if (to_send == 0) continue;

                var bulk_data: [1200]u8 = undefined;
                const read_n = s.send_buf.read(bulk_data[0..to_send]);
                if (read_n > 0) {
                    const sf = Frame{ .stream = .{
                        .stream_id = s.id,
                        .offset = s.send_acked,
                        .data_offset = 0,
                        .data_len = @intCast(read_n),
                        .fin = false,
                    } };
                    const fr = packet.serializeFrame(&sf, send_buf[pos..]);
                    if (fr.err == .none and fr.len > 0 and pos + fr.len + read_n <= mtu) {
                        pos += fr.len;
                        @memcpy(send_buf[pos .. pos + read_n], bulk_data[0..read_n]);
                        pos += @intCast(read_n);
                        s.send_acked += read_n;
                        is_ack_eliciting = true;
                    }
                }
            }
        }

        // Nothing was written to payload
        if (pos == payload_start) return 0;

        // Record sent packet
        const pkt_size = pos;
        recovery_eng.onPacketSent(
            @enumFromInt(@as(u2, @intCast(space_idx))),
            .{
                .pkt_number = next_pkt_num[space_idx],
                .sent_tick = now_tick,
                .size = pkt_size,
                .ack_eliciting = is_ack_eliciting,
                .in_flight = is_ack_eliciting,
            },
        );

        // Advance packet number
        next_pkt_num[space_idx] += 1;

        // Update telemetry
        telem.recordSent(pkt_size);

        // Update pacing: next_send_tick = now + packet_size / pacing_rate (in ticks)
        if (self.pacing_rate > 0) {
            // interval_us = pkt_size * 1_000_000 / pacing_rate
            const interval_us = (@as(u64, pkt_size) * us_per_sec) / self.pacing_rate;
            // Convert us to QPC ticks: ticks = us * freq / 1_000_000
            const freq = recovery_eng.qpc_freq;
            if (freq >= us_per_sec) {
                self.next_send_tick = now_tick + interval_us * (freq / us_per_sec);
            } else if (freq > 0) {
                self.next_send_tick = now_tick + (interval_us * freq) / us_per_sec;
            } else {
                self.next_send_tick = now_tick;
            }
        }

        return pos;
    }

    /// Generate a probe packet when PTO expires.
    /// Contains at least one ACK-eliciting frame (PING if nothing else pending).
    /// Returns bytes written to send_buf, or 0 on failure.
    pub fn assembleProbePacket(
        self: *Scheduler,
        send_buf: []u8,
        tls: *transport_crypto.TlsEngine,
        recovery_eng: *recovery.RecoveryEngine,
        stream_mgr: *streams.StreamManager,
        dgrams: *datagram.DatagramHandler,
        telem: *telemetry.TelemetryCounters,
        ack_needed: *[3]bool,
        largest_recv_pkt: *const [3]u64,
        next_pkt_num: *[3]u64,
        space: PktNumSpace,
        now_tick: u64,
    ) u16 {
        // Try normal assembly first — it may produce an ACK-eliciting packet
        const normal = self.assemblePacket(
            send_buf,
            tls,
            recovery_eng,
            stream_mgr,
            dgrams,
            telem,
            ack_needed,
            largest_recv_pkt,
            next_pkt_num,
            space,
            now_tick,
        );
        if (normal > 0) return normal;

        // Nothing pending — send a PING-only probe
        const space_idx: usize = @intFromEnum(space);
        var pos: u16 = 0;

        // Build header
        var hdr = PacketHeader{};
        const is_hs = (space == .initial or space == .handshake);
        if (is_hs) {
            hdr.is_long = true;
            hdr.version = @intFromEnum(packet.Version.quic_v1);
            hdr.pkt_type = if (space == .initial) .initial else .handshake;
        } else {
            hdr.is_long = false;
        }

        const hdr_result = packet.serializeHeader(&hdr, send_buf);
        if (hdr_result.err != .none) return 0;
        pos = hdr_result.len;

        // Packet number (1 byte)
        if (pos >= send_buf.len) return 0;
        send_buf[pos] = @truncate(next_pkt_num[space_idx]);
        send_buf[0] = (send_buf[0] & 0xFC);
        pos += 1;

        // PING frame (single byte 0x01)
        const ping_frame = Frame{ .ping = {} };
        const fr = packet.serializeFrame(&ping_frame, send_buf[pos..]);
        if (fr.err != .none or fr.len == 0) return 0;
        pos += fr.len;

        // Record sent packet
        recovery_eng.onPacketSent(
            @enumFromInt(@as(u2, @intCast(space_idx))),
            .{
                .pkt_number = next_pkt_num[space_idx],
                .sent_tick = now_tick,
                .size = pos,
                .ack_eliciting = true,
                .in_flight = true,
            },
        );

        next_pkt_num[space_idx] += 1;
        telem.recordSent(pos);

        // Increment PTO count
        recovery_eng.pto_count +|= 1;

        return pos;
    }
};

// ── Tests ──

const testing = @import("std").testing;

// Module-level test state to avoid large structs on stack.
var test_sched: Scheduler = undefined;
var test_recovery: recovery.RecoveryEngine = undefined;
var test_storage: streams.StreamArray = undefined;
var test_stream_mgr: streams.StreamManager = undefined;
var test_dgrams: datagram.DatagramHandler = undefined;
var test_tls: transport_crypto.TlsEngine = undefined;
var test_telem: telemetry.TelemetryCounters = undefined;
var test_ack_needed: [3]bool = undefined;
var test_largest_recv: [3]u64 = undefined;
var test_next_pkt_num: [3]u64 = undefined;
var test_send_buf: [1500]u8 = undefined;

fn initTestState() void {
    test_sched = Scheduler.init();
    test_recovery.initInPlace(1_000_000); // 1MHz QPC
    test_stream_mgr.init(&test_storage, false);
    test_dgrams = datagram.DatagramHandler.init();
    test_dgrams.enabled = true;
    test_dgrams.max_size = 1200;
    test_dgrams.peer_max_size = 1200;
    // Zero-init TLS engine without calling SChannel (avoids Win32 calls in tests)
    test_tls = @as(transport_crypto.TlsEngine, .{});
    test_tls.send_len = 0;
    test_telem = telemetry.TelemetryCounters.init();
    test_ack_needed = [3]bool{ false, false, false };
    test_largest_recv = [3]u64{ 0, 0, 0 };
    test_next_pkt_num = [3]u64{ 0, 0, 0 };
    @memset(&test_send_buf, 0);
}

/// Compute the payload start offset for a short header packet.
/// Short header = 1 byte first byte + dst_cid.len + 1 byte pn.
/// With default CID len 0: payload starts at byte 2.
fn shortHeaderPayloadStart() u16 {
    // 1 (first byte) + 0 (empty CID in tests) + 1 (pn) = 2
    return 2;
}

/// Helper: find a frame type byte in the assembled packet payload.
/// Returns the offset of the first occurrence, or null.
fn findFrameType(buf: []const u8, start: u16, end: u16, frame_type: u8) ?u16 {
    var off = start;
    while (off < end) {
        if (buf[off] == frame_type) return off;
        // Parse frame to skip past it
        const fr = packet.parseFrame(buf, off);
        if (fr.err != .none or fr.consumed == 0) break;
        off += fr.consumed;
    }
    return null;
}

/// Helper: collect frame type bytes in order from assembled packet payload.
/// parseFrame already consumes inline data for STREAM/CRYPTO/DATAGRAM frames,
/// so we just advance by fr.consumed each time.
fn collectFrameTypes(buf: []const u8, start: u16, end: u16, out: []u8) u16 {
    var off = start;
    var count: u16 = 0;
    while (off < end and count < out.len) {
        out[count] = buf[off];
        count += 1;
        const fr = packet.parseFrame(buf, off);
        if (fr.err != .none or fr.consumed == 0) break;
        off += fr.consumed;
    }
    return count;
}

// ── 19.7: Priority ordering tests ──

test "priority: ACK appears before stream data" {
    initTestState();

    // Set up: ACK needed + stream data pending
    test_ack_needed[2] = true; // application space
    test_largest_recv[2] = 5;
    _ = test_stream_mgr.openStream(true); // stream 0
    _ = test_stream_mgr.writeToStream(0, "hello");

    const written = test_sched.assemblePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    // Parse frames: first should be ACK (0x02), then STREAM (0x08-0x0f)
    // Short header with empty CID: 1 byte header + 1 byte pn = 2
    const payload_start = shortHeaderPayloadStart();
    var types: [8]u8 = undefined;
    const count = collectFrameTypes(&test_send_buf, payload_start, written, &types);
    try testing.expect(count >= 2);
    try testing.expectEqual(@as(u8, 0x02), types[0]); // ACK first
    try testing.expect(types[1] >= 0x08 and types[1] <= 0x0f); // STREAM second
}

test "priority: CRYPTO appears before stream data" {
    initTestState();

    // Set up: CRYPTO data pending + stream data
    test_tls.send_len = 5;
    @memcpy(test_tls.send_buf[0..5], "crypt");
    _ = test_stream_mgr.openStream(true); // stream 0
    _ = test_stream_mgr.writeToStream(0, "hello");

    const written = test_sched.assemblePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    const payload_start = shortHeaderPayloadStart();
    var types: [8]u8 = undefined;
    const count = collectFrameTypes(&test_send_buf, payload_start, written, &types);
    try testing.expect(count >= 2);
    try testing.expectEqual(@as(u8, 0x06), types[0]); // CRYPTO first
    try testing.expect(types[1] >= 0x08 and types[1] <= 0x0f); // STREAM second
}

test "priority: control stream 0 before DATAGRAM" {
    initTestState();

    // Set up: stream 0 data + datagram queued
    _ = test_stream_mgr.openStream(true); // stream 0
    _ = test_stream_mgr.writeToStream(0, "ctrl");
    try testing.expect(test_dgrams.queueSend("dgram"));

    const written = test_sched.assemblePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    const payload_start = shortHeaderPayloadStart();
    var types: [8]u8 = undefined;
    const count = collectFrameTypes(&test_send_buf, payload_start, written, &types);
    try testing.expect(count >= 2);
    // First should be STREAM (stream 0), then DATAGRAM
    try testing.expect(types[0] >= 0x08 and types[0] <= 0x0f); // STREAM
    try testing.expect(types[1] == 0x30 or types[1] == 0x31); // DATAGRAM
}

test "priority: DATAGRAM before bulk streams" {
    initTestState();

    // Set up: datagram + bulk stream 4 data
    _ = test_stream_mgr.openStream(true); // stream 0 (control)
    _ = test_stream_mgr.openStream(true); // stream 4 (bulk)
    _ = test_stream_mgr.writeToStream(4, "bulk");
    try testing.expect(test_dgrams.queueSend("dgram"));

    const written = test_sched.assemblePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    const payload_start = shortHeaderPayloadStart();
    var types: [8]u8 = undefined;
    const count = collectFrameTypes(&test_send_buf, payload_start, written, &types);
    try testing.expect(count >= 2);
    // DATAGRAM before bulk STREAM
    try testing.expect(types[0] == 0x30 or types[0] == 0x31); // DATAGRAM
    try testing.expect(types[1] >= 0x08 and types[1] <= 0x0f); // STREAM (bulk)
}

test "priority: packet does not exceed MTU" {
    initTestState();

    // Fill stream 0 with lots of data
    _ = test_stream_mgr.openStream(true); // stream 0
    var big_data: [1100]u8 = undefined;
    @memset(&big_data, 0xAA);
    _ = test_stream_mgr.writeToStream(0, &big_data);

    const written = test_sched.assemblePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);
    try testing.expect(written <= 1200);
}

// ── 19.8: Pacing tests ──

test "canSendNow returns false before next_send_tick" {
    var sched = Scheduler.init();
    sched.next_send_tick = 1000;
    try testing.expect(!sched.canSendNow(999));
}

test "canSendNow returns true at next_send_tick" {
    var sched = Scheduler.init();
    sched.next_send_tick = 1000;
    try testing.expect(sched.canSendNow(1000));
}

test "canSendNow returns true after next_send_tick" {
    var sched = Scheduler.init();
    sched.next_send_tick = 1000;
    try testing.expect(sched.canSendNow(1001));
}

test "updatePacing computes correct rate" {
    var sched = Scheduler.init();
    // cwnd = 14720, srtt = 100ms = 100_000us
    // rate = 14720 * 1_000_000 / 100_000 = 147_200 bytes/sec
    sched.updatePacing(14720, 100_000);
    try testing.expectEqual(@as(u64, 147_200), sched.pacing_rate);
}

test "updatePacing with zero srtt uses default" {
    var sched = Scheduler.init();
    sched.updatePacing(14720, 0);
    try testing.expectEqual(default_pacing_rate, sched.pacing_rate);
}

// ── 19.9: Probe packet tests ──

test "probe packet contains PING when no data pending" {
    initTestState();

    const written = test_sched.assembleProbePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    // Find PING (0x01) in payload
    const payload_start = shortHeaderPayloadStart();
    const found = findFrameType(&test_send_buf, payload_start, written, 0x01);
    try testing.expect(found != null);
}

test "probe packet contains stream data when available" {
    initTestState();

    _ = test_stream_mgr.openStream(true); // stream 0
    _ = test_stream_mgr.writeToStream(0, "probe data");

    const written = test_sched.assembleProbePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    // Should contain STREAM frame, not PING
    const payload_start = shortHeaderPayloadStart();
    var types: [8]u8 = undefined;
    const count = collectFrameTypes(&test_send_buf, payload_start, written, &types);
    try testing.expect(count >= 1);
    // First frame should be STREAM (ACK-eliciting)
    try testing.expect(types[0] >= 0x08 and types[0] <= 0x0f);
}

test "probe packet is ACK-eliciting" {
    initTestState();

    const written = test_sched.assembleProbePacket(
        &test_send_buf,
        &test_tls,
        &test_recovery,
        &test_stream_mgr,
        &test_dgrams,
        &test_telem,
        &test_ack_needed,
        &test_largest_recv,
        &test_next_pkt_num,
        .application,
        1_000_000,
    );
    try testing.expect(written > 0);

    // Verify the sent packet was recorded as ACK-eliciting
    // The recovery engine should have one sent packet
    try testing.expect(test_recovery.sent_count[2] >= 1);
    const idx: usize = @intCast((test_recovery.sent_count[2] - 1) % recovery.max_sent_packets);
    try testing.expect(test_recovery.sent[2][idx].ack_eliciting);
}
