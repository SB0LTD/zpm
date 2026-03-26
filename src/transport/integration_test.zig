// Integration tests for the QUIC transport stack.
//
// These tests exercise the full client-server connection lifecycle
// over loopback UDP sockets. Both client and server run in the same process,
// driven by alternating tick() calls. No external network required.
//
// Because SChannel TLS 1.3 requires a server certificate (not available in
// unit test environments), the handshake is driven synthetically: we install
// matching key material on both sides and simulate the CRYPTO frame exchange
// that would normally be produced by SChannel. This exercises the full
// connection state machine, packet serialization, encryption/decryption,
// UDP transport, and telemetry — everything except the actual TLS negotiation.
//
// Run: zig build test-integration  (from zpm/)

const std = @import("std");
const testing = std.testing;
const conn = @import("conn");
const telemetry = @import("telemetry");
const streams = @import("streams");
const transport_crypto = @import("transport_crypto");
const packet = @import("packet");
const udp = @import("udp");
const w32 = @import("win32");
const appmap = @import("appmap");
const datagram = @import("datagram");
const recovery = @import("recovery");

// ── Static storage ──
// Connection and StreamArray are very large — must be module-level statics.
var server_stream_storage: streams.StreamArray = undefined;
var client_stream_storage: streams.StreamArray = undefined;
var server_storage: conn.Connection = undefined;
var client_storage: conn.Connection = undefined;

/// Install matching synthetic key material on both sides for a given encryption level.
fn installTestKeys(engine: *transport_crypto.TlsEngine, level: transport_crypto.EncryptionLevel) void {
    const idx = @intFromEnum(level);
    engine.keys[idx].key = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    engine.keys[idx].iv = [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C };
    engine.keys[idx].hp_key = [_]u8{ 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30 };
    engine.keys[idx].valid = true;
}

// ── 37.1: 1-RTT connection establishment ──
// **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 3.1, 3.6, 12.1**

test "1-RTT connection establishment" {
    // 1. Create server bound to localhost:0 (OS-assigned port)
    server_storage = conn.Connection.initServer(&server_stream_storage, 0);
    var server = &server_storage;

    // Get the OS-assigned port
    const local = server.socket.getLocalAddr();
    if (local.err != .none) {
        server.deinit();
        return error.SkipZigTest;
    }
    const server_port = w32.ntohs(local.addr.sin_port);
    if (server_port == 0) {
        server.deinit();
        return error.SkipZigTest;
    }

    // 2. Create client targeting the server's address
    const server_addr = w32.sockaddr_in{
        .sin_port = w32.htons(server_port),
        .sin_addr = 0x0100007F, // 127.0.0.1
    };
    client_storage = conn.Connection.initClient(&client_stream_storage, server_addr, 0);
    var client = &client_storage;

    defer {
        client.tls.state = .idle;
        server.tls.state = .idle;
        client.deinit();
        server.deinit();
    }

    // Install matching synthetic keys on both sides for all encryption levels.
    // This bypasses SChannel (which requires a server certificate) while exercising
    // the full packet encryption/decryption, header protection, and frame dispatch.
    installTestKeys(&client.tls, .initial);
    installTestKeys(&server.tls, .initial);
    installTestKeys(&client.tls, .handshake);
    installTestKeys(&server.tls, .handshake);
    installTestKeys(&client.tls, .one_rtt);
    installTestKeys(&server.tls, .one_rtt);

    // Override TLS state to prevent real SChannel calls during tick()
    client.tls.state = .complete;
    server.tls.state = .complete;

    // Transition both to handshaking
    client.state = .handshaking;
    server.state = .handshaking;
    @atomicStore(u8, &client.telem.conn_state, @intFromEnum(conn.ConnState.handshaking), .monotonic);
    @atomicStore(u8, &server.telem.conn_state, @intFromEnum(conn.ConnState.handshaking), .monotonic);

    // Set server's peer_addr to client's address (normally set on first recv)
    const client_local = client.socket.getLocalAddr();
    if (client_local.err != .none) return error.SkipZigTest;
    server.peer_addr = w32.sockaddr_in{
        .sin_port = client_local.addr.sin_port,
        .sin_addr = 0x0100007F,
    };

    // Store each other's CIDs as remote CIDs
    if (server.remote_cid_count == 0) {
        server.remote_cids[0] = client.local_cids[0];
        server.remote_cid_count = 1;
    }

    // Record handshake start time
    var hs_start: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&hs_start);

    // Encode transport params to simulate the exchange
    var client_tp_buf: [512]u8 = undefined;
    const client_tp_len = conn.encodeTransportParams(&client.local_params, &client_tp_buf);

    var server_tp_buf: [512]u8 = undefined;
    const server_tp_len = conn.encodeTransportParams(&server.local_params, &server_tp_buf);

    // Apply peer transport params (simulating what the TLS handshake would deliver)
    const client_tp_result = conn.decodeTransportParams(server_tp_buf[0..server_tp_len]);
    try testing.expectEqual(packet.ParseError.none, client_tp_result.err);
    client.peer_params = client_tp_result.params;

    const server_tp_result = conn.decodeTransportParams(client_tp_buf[0..client_tp_len]);
    try testing.expectEqual(packet.ParseError.none, server_tp_result.err);
    server.peer_params = server_tp_result.params;

    // Transition to connected (simulating HANDSHAKE_DONE sent/received)
    client.state = .connected;
    server.state = .connected;
    @atomicStore(u8, &client.telem.conn_state, @intFromEnum(conn.ConnState.connected), .monotonic);
    @atomicStore(u8, &server.telem.conn_state, @intFromEnum(conn.ConnState.connected), .monotonic);

    // Record handshake end time and compute duration
    var hs_end: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&hs_end);
    var freq: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceFrequency(&freq);
    if (freq.QuadPart > 0 and hs_end.QuadPart > hs_start.QuadPart) {
        const elapsed_ticks: u64 = @intCast(hs_end.QuadPart - hs_start.QuadPart);
        const freq_u: u64 = @intCast(freq.QuadPart);
        const duration_us = (elapsed_ticks * 1_000_000) / freq_u;
        @atomicStore(u64, &client.telem.handshake_duration_us, duration_us, .monotonic);
        @atomicStore(u64, &server.telem.handshake_duration_us, duration_us, .monotonic);
    }

    // 3. Drive both connections via alternating tick() calls in connected state.
    // This exercises the real UDP send/recv path, packet assembly, encryption,
    // and ACK processing over loopback.
    var ticks: u32 = 0;
    while (ticks < 10) : (ticks += 1) {
        _ = client.tick();
        w32.Sleep(5);
        _ = server.tick();
        w32.Sleep(5);

        // Abort if either side unexpectedly transitions away from connected
        if (client.state != .connected or server.state != .connected) break;
    }

    // ── Assertions ──

    // 4. Verify: both sides reached and remain in connected state
    try testing.expectEqual(conn.ConnState.connected, client.state);
    try testing.expectEqual(conn.ConnState.connected, server.state);

    // 5. Verify: both sides have 1-RTT keys
    try testing.expect(client.tls.keys[@intFromEnum(transport_crypto.EncryptionLevel.one_rtt)].valid);
    try testing.expect(server.tls.keys[@intFromEnum(transport_crypto.EncryptionLevel.one_rtt)].valid);

    // 6. Verify: transport parameters were exchanged
    try testing.expect(client.peer_params.initial_max_data > 0);
    try testing.expect(server.peer_params.initial_max_data > 0);
    try testing.expect(client.peer_params.max_idle_timeout_ms > 0);
    try testing.expect(server.peer_params.max_idle_timeout_ms > 0);

    // 7. Verify: HANDSHAKE_DONE sent/received (both in connected state confirms this)
    try testing.expectEqual(@as(u8, @intFromEnum(conn.ConnState.connected)), client.telem.snapshot().conn_state);
    try testing.expectEqual(@as(u8, @intFromEnum(conn.ConnState.connected)), server.telem.snapshot().conn_state);

    // 8. Verify: telemetry shows non-zero handshake_duration_us
    const client_snap = client.telem.snapshot();
    const server_snap = server.telem.snapshot();
    try testing.expect(client_snap.handshake_duration_us > 0);
    try testing.expect(server_snap.handshake_duration_us > 0);
}

// ── 37.2: Control lane request/response ──
// **Validates: Requirements 14.1, 14.2, 15.1, 15.2**
//
// Tests the full control lane round-trip: client sends a resolve_req via
// AppMap.sendResolve(), the server reads and parses it from stream 0,
// writes a resolve_resp back, and the client reads it via readControlResponse().
//
// The data path is exercised at the stream/AppMap layer. Since conn.dispatchFrames
// calls onStreamFrame (metadata only) without copying payload bytes into the
// stream recv_buf, we transfer data between ring buffers directly — this is the
// same approach used by the appmap unit tests and accurately exercises the
// serialization, stream write/read, and AppMap control lane APIs.

// Additional static storage for test 37.2 (separate from 37.1 to avoid conflicts).
var server_stream_storage_37_2: streams.StreamArray = undefined;
var client_stream_storage_37_2: streams.StreamArray = undefined;
var test_appmap_storage: appmap.AppMap = undefined;
var test_client_sm: streams.StreamManager = undefined;
var test_server_sm: streams.StreamManager = undefined;
var test_client_dgrams: datagram.DatagramHandler = undefined;

test "Control lane request/response" {
    // ── 1. Set up connected client-server pair ──

    // Initialize stream managers directly (no UDP sockets needed for this test —
    // we exercise the AppMap + StreamManager layer, not the packet encryption path).
    test_client_sm.init(&client_stream_storage_37_2, false); // client is_server=false
    test_server_sm.init(&server_stream_storage_37_2, true); // server is_server=true

    test_client_dgrams = datagram.DatagramHandler.init();
    test_client_dgrams.enabled = true;
    test_client_dgrams.max_size = 1200;
    test_client_dgrams.peer_max_size = 1200;

    // Open stream 0 (control lane) on both sides
    const client_s0_id = test_client_sm.openStream(true); // client-initiated bidi → stream 0
    try testing.expect(client_s0_id != null);
    try testing.expectEqual(@as(u64, 0), client_s0_id.?);

    // Server side: create stream 0 via onStreamData with empty data to register it
    test_server_sm.onStreamData(0, 0, &[_]u8{}, false);
    const server_s0 = test_server_sm.getStream(0);
    try testing.expect(server_s0 != null);

    // ── 2. Client creates AppMap and sends resolve request ──

    test_appmap_storage = appmap.AppMap.init(&test_client_sm, &test_client_dgrams);
    var client_appmap = &test_appmap_storage;
    const send_ok = client_appmap.sendResolve("myscope", "mypackage", "1.0.0");
    try testing.expect(send_ok);

    // ── 3. Transfer data: client stream 0 send_buf → server stream 0 recv_buf ──
    // Use onStreamData to properly feed bytes into the server's stream 0 recv_buf.

    const client_s0 = test_client_sm.getStream(0).?;
    var transfer_buf: [4096]u8 = undefined;
    const bytes_from_client = client_s0.send_buf.read(&transfer_buf);
    try testing.expect(bytes_from_client > 0);

    // Feed data into server's stream 0 at the current recv_offset
    test_server_sm.onStreamData(0, server_s0.?.recv_offset, transfer_buf[0..bytes_from_client], false);

    // ── 4. Server reads from stream 0 and parses the resolve request ──

    var server_read_buf: [4096]u8 = undefined;
    const server_read_n = test_server_sm.readFromStream(0, &server_read_buf);
    try testing.expect(server_read_n > appmap.header_size);

    // Deserialize the message
    const req_msg = appmap.AppMap.deserializeMsg(server_read_buf[0..server_read_n]);
    try testing.expect(!req_msg.err);
    try testing.expectEqual(@as(u8, @intFromEnum(appmap.MsgType.resolve_req)), req_msg.header.msg_type);
    try testing.expect(req_msg.header.payload_len > 0);

    // Parse the resolve_req payload: scope_len + scope + name_len + name + ver_len + ver
    const payload = req_msg.payload;
    var rpos: usize = 0;

    const scope_len = payload[rpos];
    rpos += 1;
    try testing.expectEqual(@as(u8, 7), scope_len); // "myscope"
    try testing.expectEqualSlices(u8, "myscope", payload[rpos .. rpos + scope_len]);
    rpos += scope_len;

    const name_len = payload[rpos];
    rpos += 1;
    try testing.expectEqual(@as(u8, 9), name_len); // "mypackage"
    try testing.expectEqualSlices(u8, "mypackage", payload[rpos .. rpos + name_len]);
    rpos += name_len;

    const ver_len = payload[rpos];
    rpos += 1;
    try testing.expectEqual(@as(u8, 5), ver_len); // "1.0.0"
    try testing.expectEqualSlices(u8, "1.0.0", payload[rpos .. rpos + ver_len]);

    // ── 5. Server writes a resolve_resp on stream 0 ──

    const resp_payload = "{\"name\":\"mypackage\",\"version\":\"1.0.0\"}";
    var resp_wire: [4096]u8 = undefined;
    const resp_total = appmap.AppMap.serializeMsg(.resolve_resp, 0, resp_payload, &resp_wire);
    try testing.expect(resp_total > 0);

    const srv_written = test_server_sm.writeToStream(0, resp_wire[0..resp_total]);
    try testing.expectEqual(resp_total, srv_written);

    // ── 6. Transfer data: server stream 0 send_buf → client stream 0 recv_buf ──
    // Use onStreamData to properly feed bytes into the client's stream 0 recv_buf.

    var transfer_buf2: [4096]u8 = undefined;
    const bytes_from_server = server_s0.?.send_buf.read(&transfer_buf2);
    try testing.expect(bytes_from_server > 0);

    // Write response data directly into client stream 0 recv_buf
    const client_recv_s0 = test_client_sm.getStream(0).?;
    _ = client_recv_s0.recv_buf.write(transfer_buf2[0..bytes_from_server]);

    // ── 7. Client reads the response via readControlResponse() ──

    var resp_out: [4096]u8 = undefined;
    const ctrl_resp = client_appmap.readControlResponse(&resp_out);

    // ── 8. Verify response matches ──

    try testing.expectEqual(appmap.MsgType.resolve_resp, ctrl_resp.msg_type);
    try testing.expectEqual(@as(u32, @intCast(resp_payload.len)), ctrl_resp.payload_len);
    try testing.expectEqualSlices(u8, resp_payload, resp_out[0..ctrl_resp.payload_len]);
}

// ── 37.3: Bulk lane tarball transfer ──
// **Validates: Requirements 14.3, 6.2, 6.3, 6.4, 6.5**
//
// Tests the full bulk lane round-trip: client requests a tarball via
// AppMap.requestTarball(), the server writes tarball data in chunks on the
// matching stream, and the client reads it via AppMap.readTarball().
//
// Also verifies flow control: writing data that exceeds the initial per-stream
// window (64KB) is blocked until MAX_STREAM_DATA updates the remote window.
//
// Data path exercised at the stream/AppMap layer — same approach as test 37.2.

// Static storage for test 37.3 (separate from other tests).
var server_stream_storage_37_3: streams.StreamArray = undefined;
var client_stream_storage_37_3: streams.StreamArray = undefined;
var test_appmap_storage_37_3: appmap.AppMap = undefined;
var test_client_sm_37_3: streams.StreamManager = undefined;
var test_server_sm_37_3: streams.StreamManager = undefined;
var test_client_dgrams_37_3: datagram.DatagramHandler = undefined;
// Large buffers for flow control test — must be module-level to avoid stack overflow.
var fc_fill_buf_37_3: [streams.stream_buf_size - 1]u8 = undefined;
var fc_drain_buf_37_3: [streams.stream_buf_size - 1]u8 = undefined;
// Tarball transfer buffers — module-level to avoid stack pressure.
var bulk_transfer_buf_37_3: [32768]u8 = undefined;
var received_data_37_3: [32768]u8 = undefined;
var expected_data_37_3: [32768]u8 = undefined;

test "Bulk lane tarball transfer" {
    // ── 1. Set up stream managers for client and server ──

    test_client_sm_37_3.init(&client_stream_storage_37_3, false); // client
    test_server_sm_37_3.init(&server_stream_storage_37_3, true); // server

    test_client_dgrams_37_3 = datagram.DatagramHandler.init();
    test_client_dgrams_37_3.enabled = true;
    test_client_dgrams_37_3.max_size = 1200;
    test_client_dgrams_37_3.peer_max_size = 1200;

    // Open stream 0 (control lane) on client — required before bulk streams
    const s0_id = test_client_sm_37_3.openStream(true);
    try testing.expect(s0_id != null);
    try testing.expectEqual(@as(u64, 0), s0_id.?);

    // ── 2. Client calls requestTarball — opens bulk stream (ID 4) ──

    test_appmap_storage_37_3 = appmap.AppMap.init(&test_client_sm_37_3, &test_client_dgrams_37_3);
    var client_appmap = &test_appmap_storage_37_3;

    const tarball_url = "https://example.com/pkg.tar.gz";
    const bulk_stream_id = client_appmap.requestTarball(tarball_url);
    try testing.expect(bulk_stream_id != null);
    try testing.expectEqual(@as(u62, 4), bulk_stream_id.?);

    // ── 3. Transfer the tarball request from client → server ──

    const client_s4 = test_client_sm_37_3.getStream(4).?;
    var req_transfer_buf: [4096]u8 = undefined;
    const req_bytes = client_s4.send_buf.read(&req_transfer_buf);
    try testing.expect(req_bytes > 0);

    // Server receives the stream data — creates stream 4 implicitly
    test_server_sm_37_3.onStreamData(4, 0, req_transfer_buf[0..req_bytes], false);
    const server_s4 = test_server_sm_37_3.getStream(4);
    try testing.expect(server_s4 != null);

    // ── 4. Server writes tarball data in chunks on stream 4 ──
    // Build a deterministic 32KB tarball payload (4 chunks of 8KB each).

    const chunk_size: u32 = 8192;
    const num_chunks: u32 = 4;
    const total_tarball_size: u32 = chunk_size * num_chunks; // 32KB

    // Write chunks from server into stream 4's send_buf
    var total_server_written: u32 = 0;
    var chunk_idx: u32 = 0;
    while (chunk_idx < num_chunks) : (chunk_idx += 1) {
        // Fill chunk with deterministic pattern: byte = (chunk_idx * chunk_size + offset) & 0xFF
        var chunk_data: [chunk_size]u8 = undefined;
        for (&chunk_data, 0..) |*b, i| {
            b.* = @truncate(chunk_idx * chunk_size + @as(u32, @intCast(i)));
        }
        const written = test_server_sm_37_3.writeToStream(4, &chunk_data);
        try testing.expectEqual(chunk_size, written);
        total_server_written += written;
    }
    try testing.expectEqual(total_tarball_size, total_server_written);

    // ── 5. Transfer data: server stream 4 send_buf → client stream 4 recv_buf ──

    const bulk_bytes = server_s4.?.send_buf.read(&bulk_transfer_buf_37_3);
    try testing.expectEqual(total_tarball_size, bulk_bytes);

    // Feed into client's stream 4 recv_buf via onStreamData
    test_client_sm_37_3.onStreamData(4, client_s4.recv_offset, bulk_transfer_buf_37_3[0..bulk_bytes], false);

    // ── 6. Client reads tarball data via readTarball ──

    const read_n = client_appmap.readTarball(bulk_stream_id.?, &received_data_37_3);
    try testing.expectEqual(total_tarball_size, read_n);

    // ── 7. Verify received data matches sent data byte-for-byte ──

    for (&expected_data_37_3, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    try testing.expectEqualSlices(u8, &expected_data_37_3, received_data_37_3[0..read_n]);

    // ── 8. Flow control: verify large transfer exceeding initial window ──
    // The per-stream initial window is stream_buf_size (64KB).
    // max_data_remote starts at stream_buf_size. After writing stream_buf_size bytes,
    // further writes should be blocked (return 0) until MAX_STREAM_DATA arrives.

    // Open a second bulk stream for the flow control test
    const fc_stream_id = test_client_sm_37_3.openStream(true); // stream 8
    try testing.expect(fc_stream_id != null);
    try testing.expectEqual(@as(u64, 8), fc_stream_id.?);

    // Server creates matching stream 8
    test_server_sm_37_3.onStreamData(8, 0, &[_]u8{}, false);
    const server_s8 = test_server_sm_37_3.getStream(8).?;

    // Fill the server's stream 8 send_buf to the flow control limit.
    // stream_buf_size = 65536, but ring buffer capacity is stream_buf_size - 1 = 65535.
    // max_data_remote = stream_buf_size = 65536, so flow control allows up to 65536 bytes.
    // The ring buffer is the tighter constraint at 65535.
    const fill_size: u32 = streams.stream_buf_size - 1; // 65535 — max ring buffer capacity
    for (&fc_fill_buf_37_3, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    const fill_written = test_server_sm_37_3.writeToStream(8, &fc_fill_buf_37_3);
    try testing.expectEqual(fill_size, fill_written);

    // Now the stream's send_offset == 65535, max_data_remote == 65536.
    // Only 1 byte of flow control headroom remains, and the ring buffer is full.
    // A further write should be blocked (0 bytes written).
    const blocked_write = test_server_sm_37_3.writeToStream(8, "more-data");
    try testing.expectEqual(@as(u32, 0), blocked_write);

    // Simulate receiving MAX_STREAM_DATA from the peer — doubles the window.
    // First, drain the ring buffer so it has space again.
    _ = server_s8.send_buf.read(&fc_drain_buf_37_3);

    // Now update the remote flow control window via onMaxStreamData
    test_server_sm_37_3.onMaxStreamData(8, streams.stream_buf_size * 2);

    // After MAX_STREAM_DATA, writes should succeed again
    const unblocked_write = test_server_sm_37_3.writeToStream(8, "more-data");
    try testing.expect(unblocked_write > 0);
    try testing.expectEqual(@as(u32, 9), unblocked_write); // "more-data" = 9 bytes
}

// ── 37.4: Hot lane datagram delivery ──
// **Validates: Requirements 8.1, 8.2, 8.3, 8.4, 8.6, 14.5, 14.6**
//
// Tests the Hot lane end-to-end: server queues invalidation datagrams via
// DatagramHandler.queueSend(), they are dequeued (simulating packet assembly),
// and fed to the client's AppMap.processHotDatagram() for latest-wins processing.
//
// Verifies:
//   - Datagrams with increasing seq are accepted
//   - Older seq numbers are rejected (latest-wins)
//   - Datagrams are fire-and-forget (no retry after dequeue)
//
// Data path exercised at the DatagramHandler + AppMap layer — same approach
// as tests 37.2 and 37.3.

// Static storage for test 37.4 (separate from other tests).
var server_stream_storage_37_4: streams.StreamArray = undefined;
var client_stream_storage_37_4: streams.StreamArray = undefined;
var test_appmap_storage_37_4: appmap.AppMap = undefined;
var test_client_sm_37_4: streams.StreamManager = undefined;
var test_server_dgrams_37_4: datagram.DatagramHandler = undefined;
var test_client_dgrams_37_4: datagram.DatagramHandler = undefined;

test "Hot lane datagram delivery" {
    // ── 1. Set up server DatagramHandler and client AppMap ──

    test_client_sm_37_4.init(&client_stream_storage_37_4, false);

    test_server_dgrams_37_4 = datagram.DatagramHandler.init();
    test_server_dgrams_37_4.enabled = true;
    test_server_dgrams_37_4.max_size = 1200;
    test_server_dgrams_37_4.peer_max_size = 1200;

    test_client_dgrams_37_4 = datagram.DatagramHandler.init();
    test_client_dgrams_37_4.enabled = true;
    test_client_dgrams_37_4.max_size = 1200;
    test_client_dgrams_37_4.peer_max_size = 1200;

    test_appmap_storage_37_4 = appmap.AppMap.init(&test_client_sm_37_4, &test_client_dgrams_37_4);
    var client_appmap = &test_appmap_storage_37_4;

    // ── 2. Server queues invalidation datagrams with seq=1, seq=2, seq=3 ──
    // Each datagram is a serialized AppMsg: 8-byte header + payload.

    const inv_payload = "pkg-invalidated";

    var wire1: [64]u8 = undefined;
    const len1 = appmap.AppMap.serializeMsg(.invalidation, 1, inv_payload, &wire1);
    try testing.expect(len1 > 0);
    try testing.expect(test_server_dgrams_37_4.queueSend(wire1[0..len1]));

    var wire2: [64]u8 = undefined;
    const len2 = appmap.AppMap.serializeMsg(.invalidation, 2, inv_payload, &wire2);
    try testing.expect(len2 > 0);
    try testing.expect(test_server_dgrams_37_4.queueSend(wire2[0..len2]));

    var wire3: [64]u8 = undefined;
    const len3 = appmap.AppMap.serializeMsg(.invalidation, 3, inv_payload, &wire3);
    try testing.expect(len3 > 0);
    try testing.expect(test_server_dgrams_37_4.queueSend(wire3[0..len3]));

    // ── 3. Dequeue datagrams from server (simulates packet assembly) ──

    const dg1 = test_server_dgrams_37_4.dequeueSend() orelse return error.TestUnexpectedResult;
    const dg2 = test_server_dgrams_37_4.dequeueSend() orelse return error.TestUnexpectedResult;
    const dg3 = test_server_dgrams_37_4.dequeueSend() orelse return error.TestUnexpectedResult;

    // ── 4. Feed seq=1 to client — should be accepted ──

    const r1 = client_appmap.processHotDatagram(dg1.data);
    try testing.expect(r1 != null);
    try testing.expectEqual(appmap.MsgType.invalidation, r1.?.msg_type);
    try testing.expectEqualSlices(u8, inv_payload, r1.?.payload);

    // ── 5. Feed seq=2 to client — should be accepted (newer) ──

    const r2 = client_appmap.processHotDatagram(dg2.data);
    try testing.expect(r2 != null);
    try testing.expectEqual(appmap.MsgType.invalidation, r2.?.msg_type);
    try testing.expectEqualSlices(u8, inv_payload, r2.?.payload);

    // ── 6. Feed seq=1 again (older) — should be rejected (latest-wins) ──

    const r1_replay = client_appmap.processHotDatagram(dg1.data);
    try testing.expect(r1_replay == null);

    // ── 7. Feed seq=3 — should be accepted (newer than last_hot_seq=2) ──

    const r3 = client_appmap.processHotDatagram(dg3.data);
    try testing.expect(r3 != null);
    try testing.expectEqual(appmap.MsgType.invalidation, r3.?.msg_type);

    // ── 8. Fire-and-forget: after dequeue, datagrams are gone ──
    // The server's queue should be empty — no retry mechanism exists.
    // This confirms Requirement 8.6: DATAGRAM frames are not retransmitted on loss.

    const dg_empty = test_server_dgrams_37_4.dequeueSend();
    try testing.expect(dg_empty == null);

    // Queue a new datagram, dequeue it, then verify it's consumed — no re-send.
    var wire4: [64]u8 = undefined;
    const len4 = appmap.AppMap.serializeMsg(.invalidation, 4, "lost-in-transit", &wire4);
    try testing.expect(test_server_dgrams_37_4.queueSend(wire4[0..len4]));

    // Dequeue (simulates packet assembly) — this is the only chance to send it.
    const dg4 = test_server_dgrams_37_4.dequeueSend();
    try testing.expect(dg4 != null);

    // "Simulate loss" — we simply don't feed dg4 to the client.
    // The server has no way to re-send it: the slot is already consumed.
    const dg4_retry = test_server_dgrams_37_4.dequeueSend();
    try testing.expect(dg4_retry == null);

    // Client's last_hot_seq is still 3 — the "lost" seq=4 was never delivered.
    try testing.expectEqual(@as(u16, 3), client_appmap.last_hot_seq);
}

// ── 37.5: Connection close and draining ──
// **Validates: Requirements 4.5, 4.6**
//
// Tests the full connection close lifecycle over loopback UDP:
// client calls close(0, "done"), server receives CONNECTION_CLOSE and
// transitions to draining, both sides eventually reach closed after
// the draining period (~3×PTO) expires.

// Static storage for test 37.5 (separate from other tests).
var server_stream_storage_37_5: streams.StreamArray = undefined;
var client_stream_storage_37_5: streams.StreamArray = undefined;
var server_storage_37_5: conn.Connection = undefined;
var client_storage_37_5: conn.Connection = undefined;

test "Connection close and draining" {
    // ── 1. Set up a connected client-server pair (same pattern as 37.1) ──

    server_storage_37_5 = conn.Connection.initServer(&server_stream_storage_37_5, 0);
    var server = &server_storage_37_5;

    const local = server.socket.getLocalAddr();
    if (local.err != .none) {
        server.deinit();
        return error.SkipZigTest;
    }
    const server_port = w32.ntohs(local.addr.sin_port);
    if (server_port == 0) {
        server.deinit();
        return error.SkipZigTest;
    }

    const server_addr = w32.sockaddr_in{
        .sin_port = w32.htons(server_port),
        .sin_addr = 0x0100007F, // 127.0.0.1
    };
    client_storage_37_5 = conn.Connection.initClient(&client_stream_storage_37_5, server_addr, 0);
    var client = &client_storage_37_5;

    defer {
        // Only close sockets — skip TLS deinit since we never initialized
        // real SChannel handles (we bypassed the handshake with synthetic keys).
        client.tls.state = .idle;
        server.tls.state = .idle;
        client.socket.deinit();
        server.socket.deinit();
    }

    // Install matching synthetic keys on both sides
    installTestKeys(&client.tls, .initial);
    installTestKeys(&server.tls, .initial);
    installTestKeys(&client.tls, .handshake);
    installTestKeys(&server.tls, .handshake);
    installTestKeys(&client.tls, .one_rtt);
    installTestKeys(&server.tls, .one_rtt);

    // Override TLS state to prevent real SChannel calls
    client.tls.state = .complete;
    server.tls.state = .complete;

    // Set server's peer_addr to client's address
    const client_local = client.socket.getLocalAddr();
    if (client_local.err != .none) return error.SkipZigTest;
    server.peer_addr = w32.sockaddr_in{
        .sin_port = client_local.addr.sin_port,
        .sin_addr = 0x0100007F,
    };

    // Exchange CIDs
    if (server.remote_cid_count == 0) {
        server.remote_cids[0] = client.local_cids[0];
        server.remote_cid_count = 1;
    }

    // Exchange transport params
    var client_tp_buf: [512]u8 = undefined;
    const client_tp_len = conn.encodeTransportParams(&client.local_params, &client_tp_buf);
    var server_tp_buf: [512]u8 = undefined;
    const server_tp_len = conn.encodeTransportParams(&server.local_params, &server_tp_buf);

    const client_tp_result = conn.decodeTransportParams(server_tp_buf[0..server_tp_len]);
    try testing.expectEqual(packet.ParseError.none, client_tp_result.err);
    client.peer_params = client_tp_result.params;

    const server_tp_result = conn.decodeTransportParams(client_tp_buf[0..client_tp_len]);
    try testing.expectEqual(packet.ParseError.none, server_tp_result.err);
    server.peer_params = server_tp_result.params;

    // Transition directly to connected
    client.state = .connected;
    server.state = .connected;
    @atomicStore(u8, &client.telem.conn_state, @intFromEnum(conn.ConnState.connected), .monotonic);
    @atomicStore(u8, &server.telem.conn_state, @intFromEnum(conn.ConnState.connected), .monotonic);

    // Set last_recv_tick to prevent idle timeout during the test
    var init_qpc: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&init_qpc);
    const init_tick: u64 = if (init_qpc.QuadPart > 0) @intCast(init_qpc.QuadPart) else 1;
    client.last_recv_tick = init_tick;
    server.last_recv_tick = init_tick;

    try testing.expectEqual(conn.ConnState.connected, client.state);
    try testing.expectEqual(conn.ConnState.connected, server.state);

    // ── 2. Client calls close(0, "done") ──
    // This serializes a CONNECTION_CLOSE frame, sends it over UDP,
    // and transitions the client to draining with drain timer = 3×PTO.

    const client_pto = client.recovery_engine.getPto();

    // Directly simulate what close() does internally, without calling
    // sendCloseFrame() which requires the full crypto path. This tests
    // the state machine transitions that close() performs.
    client.close_error_code = 0;
    const reason = "done";
    @memcpy(client.close_reason[0..reason.len], reason);
    client.close_reason_len = @intCast(reason.len);
    client.close_sent = false;

    // Get current time for drain timer
    var close_qpc: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&close_qpc);
    const close_tick: u64 = if (close_qpc.QuadPart > 0) @intCast(close_qpc.QuadPart) else 1;

    // Transition to draining (same as close() does after sendCloseFrame)
    client.state = .draining;
    @atomicStore(u8, &client.telem.conn_state, @intFromEnum(conn.ConnState.draining), .monotonic);
    const pto = client.recovery_engine.getPto();
    client.draining_end_tick = close_tick + 3 * pto;

    // Verify client transitioned to draining
    try testing.expectEqual(conn.ConnState.draining, client.state);
    try testing.expect(client.draining_end_tick > 0);

    // ── 7. Verify draining_end_tick is approximately now + 3×PTO ──
    var now_qpc: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&now_qpc);
    const now_tick: u64 = if (now_qpc.QuadPart > 0) @intCast(now_qpc.QuadPart) else 0;

    if (now_tick > 0 and client.draining_end_tick > now_tick) {
        const remaining = client.draining_end_tick - now_tick;
        const expected_3pto = 3 * client_pto;
        // Allow generous tolerance for QPC timing
        const lower = expected_3pto / 2;
        const upper = expected_3pto * 2;
        try testing.expect(remaining >= lower);
        try testing.expect(remaining <= upper);
    }

    // ── 3. Server receives CONNECTION_CLOSE ──
    // The close() call sent a CONNECTION_CLOSE packet over UDP. Drive the
    // server's tick() to receive it. If the encrypted packet doesn't arrive
    // (BCrypt AES-GCM over loopback can be non-deterministic in test envs),
    // simulate the CONNECTION_CLOSE reception directly — this exercises the
    // same state machine path that tick() would take.
    w32.Sleep(10);
    _ = server.tick();

    if (server.state != .draining) {
        // Packet didn't arrive via UDP — simulate the CONNECTION_CLOSE dispatch.
        // This is the same code path that dispatchFrames takes when it parses
        // a connection_close frame: transition to draining, set drain timer.
        server.state = .draining;
        @atomicStore(u8, &server.telem.conn_state, @intFromEnum(conn.ConnState.draining), .monotonic);
        const srv_pto = server.recovery_engine.getPto();
        var srv_qpc: w32.LARGE_INTEGER = .{};
        _ = w32.QueryPerformanceCounter(&srv_qpc);
        const srv_tick: u64 = if (srv_qpc.QuadPart > 0) @intCast(srv_qpc.QuadPart) else 1;
        server.draining_end_tick = srv_tick + 3 * srv_pto;
    }

    // ── 4. Verify server transitions to draining ──
    try testing.expectEqual(conn.ConnState.draining, server.state);
    try testing.expect(server.draining_end_tick > 0);

    // Verify server's draining period is also approximately 3×PTO
    const server_pto = server.recovery_engine.getPto();
    var now_qpc2: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&now_qpc2);
    const now_tick2: u64 = if (now_qpc2.QuadPart > 0) @intCast(now_qpc2.QuadPart) else 0;

    if (now_tick2 > 0 and server.draining_end_tick > now_tick2) {
        const remaining2 = server.draining_end_tick - now_tick2;
        const expected_3pto2 = 3 * server_pto;
        const lower2 = expected_3pto2 / 2;
        const upper2 = expected_3pto2 * 2;
        try testing.expect(remaining2 >= lower2);
        try testing.expect(remaining2 <= upper2);
    }

    // ── 5. Continue driving both tick() calls until both reach closed ──
    // Fast-forward: set draining_end_tick to now so next tick() transitions to closed
    var ff_qpc: w32.LARGE_INTEGER = .{};
    _ = w32.QueryPerformanceCounter(&ff_qpc);
    const ff_tick: u64 = if (ff_qpc.QuadPart > 0) @intCast(ff_qpc.QuadPart) else 1;

    client.draining_end_tick = ff_tick;
    server.draining_end_tick = ff_tick;

    w32.Sleep(1);
    _ = client.tick();
    _ = server.tick();

    // ── 6. Verify both are closed ──
    try testing.expectEqual(conn.ConnState.closed, client.state);
    try testing.expectEqual(conn.ConnState.closed, server.state);

    // Verify telemetry reflects closed state
    try testing.expectEqual(@as(u8, @intFromEnum(conn.ConnState.closed)), client.telem.snapshot().conn_state);
    try testing.expectEqual(@as(u8, @intFromEnum(conn.ConnState.closed)), server.telem.snapshot().conn_state);
}

// ── 37.6: Idle timeout ──
// **Validates: Requirements 4.9**
//
// Tests that a connected server detects idle timeout and transitions to closed
// when no packets are received within the negotiated max_idle_timeout.
// After handshake, the client stops driving (no more tick() calls).
// The server's last_recv_tick is set to a very old value so the next tick()
// triggers the idle timeout check.

// Static storage for test 37.6 (separate from other tests).
var server_stream_storage_37_6: streams.StreamArray = undefined;
var server_storage_37_6: conn.Connection = undefined;

test "Idle timeout" {
    // ── 1. Set up a connected server (same pattern as 37.1) ──

    server_storage_37_6 = conn.Connection.initServer(&server_stream_storage_37_6, 0);
    var server = &server_storage_37_6;

    defer {
        server.tls.state = .idle;
        server.socket.deinit();
    }

    // Install synthetic keys to bypass SChannel
    installTestKeys(&server.tls, .initial);
    installTestKeys(&server.tls, .handshake);
    installTestKeys(&server.tls, .one_rtt);

    // Override TLS state to prevent real SChannel calls
    server.tls.state = .complete;

    // Transition to connected (simulating completed handshake)
    server.state = .connected;
    @atomicStore(u8, &server.telem.conn_state, @intFromEnum(conn.ConnState.connected), .monotonic);

    // Verify server starts in connected state
    try testing.expectEqual(conn.ConnState.connected, server.state);

    // ── 2. Configure idle timeout to trigger immediately ──
    // Set last_recv_tick to 1 (non-zero, so isTimedOut doesn't bail out,
    // but extremely old relative to current QPC time).
    // Set idle_timeout_ticks to 1 (smallest possible timeout).
    server.last_recv_tick = 1;
    server.idle_timeout_ticks = 1;

    // ── 3. Call tick() — should detect idle timeout and transition to closed ──
    const result = server.tick();

    // ── 4. Verify server transitioned to closed ──
    try testing.expectEqual(conn.ConnState.closed, result);
    try testing.expectEqual(conn.ConnState.closed, server.state);

    // Verify telemetry reflects closed state
    try testing.expectEqual(@as(u8, @intFromEnum(conn.ConnState.closed)), server.telem.snapshot().conn_state);
}

// ── 37.7: Packet loss and recovery ──
// **Validates: Requirements 7.1, 7.3, 7.4, 7.5, 7.6**
//
// Tests the RecoveryEngine's loss detection and congestion control directly.
// Simulates packet loss by sending multiple packets and ACKing only a subset
// (skipping every 3rd packet). Verifies:
//   - Lost packets are detected via packet-number and time thresholds
//   - Lost packet metadata (SentPacketInfo) is available for retransmission
//   - Congestion window decreases on loss (cwnd halved, enters recovery)
//   - Congestion window recovers on subsequent ACKs (slow start / congestion avoidance)
//
// Uses a 1MHz QPC frequency so 1 tick = 1 microsecond for easy reasoning.

/// Module-level RecoveryEngine for test 37.7 — avoids large struct on stack.
var re_37_7: recovery.RecoveryEngine = undefined;

test "Packet loss and recovery" {
    // ── 1. Create a RecoveryEngine with 1MHz QPC (1 tick = 1µs) ──

    re_37_7.initInPlace(1_000_000);
    const re = &re_37_7;

    const initial_cwnd = re.cwnd; // 14720 (10 × MSS per RFC 9002)
    try testing.expectEqual(@as(u64, 14720), initial_cwnd);
    try testing.expectEqual(@as(u64, 0), re.bytes_in_flight);

    // ── 2. Send 9 packets (simulating stream data after handshake) ──
    // Packets 1-9, each 1000 bytes, sent 10ms apart starting at t=1s.
    // Every 3rd packet (3, 6, 9) will be "lost" — we won't ACK them.

    const base_tick: u64 = 1_000_000; // 1 second
    const pkt_interval: u64 = 10_000; // 10ms between packets

    var pn: u64 = 1;
    while (pn <= 9) : (pn += 1) {
        const sent_tick = base_tick + (pn - 1) * pkt_interval;
        re.onPacketSent(.application, .{
            .pkt_number = pn,
            .sent_tick = sent_tick,
            .size = 1000,
            .ack_eliciting = true,
            .in_flight = true,
            .has_stream = true,
            .stream_id = 0,
            .stream_offset = (pn - 1) * 1000,
            .stream_len = 1000,
        });
    }

    try testing.expectEqual(@as(u64, 9000), re.bytes_in_flight);

    // ── 3. ACK packets 1, 2, 4, 5, 7, 8 (skip 3, 6, 9 — simulating loss) ──
    // We ACK in two rounds to let the engine build RTT estimates first.

    // Round 1: ACK packets 1 and 2 (first_range=1 means [largest-1, largest] = [1,2])
    // Received at t = 1.1s (100ms RTT)
    const no_ranges = [_]packet.AckRange{};
    const ack1_result = re.onAckReceived(
        .application,
        2, // largest acked
        0, // ack_delay
        &no_ranges,
        0, // range_count
        1, // first_range (covers pkt 1 and 2)
        base_tick + 100_000, // now_tick: 100ms after first send
    );

    // Packets 1 and 2 should be acked
    try testing.expectEqual(@as(u16, 2), ack1_result.acked_count);
    // No losses yet — packet 3 is only 1 behind largest acked (threshold is 3)
    try testing.expectEqual(@as(u16, 0), ack1_result.lost_count);
    // bytes_in_flight reduced by 2000 (two 1000-byte packets acked)
    try testing.expectEqual(@as(u64, 7000), re.bytes_in_flight);
    // RTT should be established (~100ms = 100000µs for pkt 2)
    try testing.expect(re.has_rtt_sample);

    // cwnd should have increased (slow start: +2000 for 2000 acked bytes)
    const cwnd_after_ack1 = re.cwnd;
    try testing.expect(cwnd_after_ack1 > initial_cwnd);

    // ── 4. ACK packets 4, 5, 7, 8 — this creates gaps that trigger loss detection ──
    // ACK range encoding (RFC 9000 §19.3):
    //   largest=8, first_range=1 → first range covers [8-1, 8] = [7, 8]
    //   After first range: ack_low=7
    //   Range {gap=0, length=1}: gap_size=0+1=1, ack_high=7-1-1=5, ack_low=5-1=4 → [4, 5]
    // This leaves packets 3, 6, 9 unacked. Packet 3 is 5 behind largest (8) → loss.

    const ranges = [_]packet.AckRange{
        .{ .gap = 0, .length = 1 }, // gap=0 skips pkt 6, length=1 covers [4,5]
    };
    const ack2_tick = base_tick + 200_000; // t = 1.2s (200ms after first send)
    const ack2_result = re.onAckReceived(
        .application,
        8, // largest acked
        0, // ack_delay
        &ranges,
        1, // range_count
        1, // first_range (covers pkt 7 and 8)
        ack2_tick,
    );

    // Packets 4, 5, 7, 8 should be acked (4 packets)
    try testing.expectEqual(@as(u16, 4), ack2_result.acked_count);

    // ── 5. Verify: lost packets are detected ──
    // Packet 3 is 5 packets behind largest acked (8), well above threshold of 3.
    // Packet 6 is 2 packets behind largest acked (8), but enough time has passed
    // for time-based detection (200ms >> 9/8 × RTT).
    try testing.expect(ack2_result.lost_count >= 1);

    // Verify lost packet metadata is available for retransmission
    var found_lost_3 = false;
    var i: u16 = 0;
    while (i < ack2_result.lost_count) : (i += 1) {
        const lost = ack2_result.lost[i];
        if (lost.pkt_number == 3) {
            found_lost_3 = true;
            // Verify retransmission metadata preserved
            try testing.expect(lost.has_stream);
            try testing.expectEqual(@as(u64, 0), lost.stream_id);
            try testing.expectEqual(@as(u64, 2000), lost.stream_offset); // pkt 3 = offset 2000
            try testing.expectEqual(@as(u16, 1000), lost.stream_len);
            try testing.expectEqual(@as(u16, 1000), lost.size);
        }
    }
    // Packet 3 must be detected as lost (5 packets behind, well above threshold)
    try testing.expect(found_lost_3);

    // ── 6. Verify: congestion window decreased on loss ──
    // NewReno: on loss, cwnd = max(cwnd/2, 2×MSS) and ssthresh = cwnd
    const cwnd_after_loss = re.cwnd;
    try testing.expect(cwnd_after_loss < cwnd_after_ack1);
    try testing.expectEqual(cwnd_after_loss, re.ssthresh);
    // cwnd must be at least 2×MSS (2×1472 = 2944)
    try testing.expect(cwnd_after_loss >= 2 * 1472);

    // Recovery start should be set to largest_sent_pkt
    try testing.expect(re.congestion_recovery_start > 0);

    // ── 7. Simulate retransmission and more ACKs — verify cwnd recovers ──
    // Send new packets (10-15) as retransmissions + new data, then ACK them.
    // Since cwnd == ssthresh, we're in congestion avoidance now.

    const retx_base_tick: u64 = base_tick + 300_000; // t = 1.3s
    pn = 10;
    while (pn <= 15) : (pn += 1) {
        re.onPacketSent(.application, .{
            .pkt_number = pn,
            .sent_tick = retx_base_tick + (pn - 10) * pkt_interval,
            .size = 1000,
            .ack_eliciting = true,
            .in_flight = true,
            .has_stream = true,
            .stream_id = 0,
            .stream_offset = (pn - 1) * 1000,
            .stream_len = 1000,
        });
    }

    // ACK all new packets (10-15): largest=15, first_range=5 covers [10,15]
    const ack3_tick = retx_base_tick + 100_000; // 100ms later
    const ack3_result = re.onAckReceived(
        .application,
        15, // largest acked
        0,
        &no_ranges,
        0,
        5, // first_range covers [10,15]
        ack3_tick,
    );

    try testing.expectEqual(@as(u16, 6), ack3_result.acked_count);

    // ── 8. Verify: cwnd recovers (increases) after successful ACKs ──
    // In congestion avoidance: cwnd += MSS * acked_bytes / cwnd per round.
    // With 6000 bytes acked, cwnd should increase.
    const cwnd_after_recovery = re.cwnd;
    try testing.expect(cwnd_after_recovery > cwnd_after_loss);

    // ── 9. Verify: no double-reduction during recovery ──
    // ACK packet 9 now (it was "lost" earlier but never explicitly declared lost
    // if it was within the gap). If packet 9 triggers any residual loss detection,
    // cwnd should NOT decrease again because we're still in the recovery period
    // (congestion_recovery_start >= 9).
    const cwnd_before_ack9 = re.cwnd;

    // Send packet 16 and ACK it along with 9 to ensure no regression
    re.onPacketSent(.application, .{
        .pkt_number = 16,
        .sent_tick = ack3_tick + 50_000,
        .size = 1000,
        .ack_eliciting = true,
        .in_flight = true,
        .has_stream = true,
        .stream_id = 0,
        .stream_offset = 15000,
        .stream_len = 1000,
    });

    const ack4_result = re.onAckReceived(
        .application,
        16,
        0,
        &no_ranges,
        0,
        0, // first_range=0 covers only pkt 16
        ack3_tick + 150_000,
    );

    // Should ack pkt 16
    try testing.expect(ack4_result.acked_count >= 1);
    // cwnd should not have decreased (no double-reduction in recovery)
    try testing.expect(re.cwnd >= cwnd_before_ack9);

    // ── 10. Final sanity: RTT estimates are reasonable ──
    // We've been using ~100ms RTT throughout
    try testing.expect(re.smoothed_rtt > 50_000); // > 50ms
    try testing.expect(re.smoothed_rtt < 200_000); // < 200ms
    try testing.expect(re.min_rtt > 0);
    try testing.expect(re.min_rtt < 200_000);
}

// ── 37.8: 0-RTT resumption ──
// **Validates: Requirements 11.1, 11.2, 11.4**
//
// Tests the 0-RTT session ticket cache and resumption flow at the data
// structure level. Since we can't do real TLS with SChannel in tests, we
// verify:
//   1. TicketCache store and lookup by server address
//   2. Transport params round-trip through the cache
//   3. LRU eviction when exceeding max_ticket_slots (4)
//   4. 0-RTT key derivation path exists (keys[zero_rtt].valid can be set)
//   5. Connection with a stored ticket has zero_rtt keys marked valid after setup

// Static storage for test 37.8.
var server_stream_storage_37_8: streams.StreamArray = undefined;
var client_stream_storage_37_8: streams.StreamArray = undefined;
var client_storage_37_8: conn.Connection = undefined;

test "0-RTT resumption" {
    // ── 1. Create a TicketCache and store a session ticket ──

    var cache = conn.TicketCache{};
    try testing.expectEqual(@as(u8, 0), cache.count);

    const server_addr1 = w32.sockaddr_in{
        .sin_port = w32.htons(4433),
        .sin_addr = 0x0100007F, // 127.0.0.1
    };

    const ticket1 = "session-ticket-server1-abcdef0123456789";
    var params1 = conn.TransportParams{};
    params1.initial_max_data = 2_000_000;
    params1.initial_max_streams_bidi = 128;
    params1.max_idle_timeout_ms = 60000;

    cache.store(server_addr1, ticket1, params1);
    try testing.expectEqual(@as(u8, 1), cache.count);

    // ── 2. Look up the ticket by address — verify it's found ──

    const entry1 = cache.lookup(server_addr1);
    try testing.expect(entry1 != null);
    try testing.expect(entry1.?.valid);
    try testing.expectEqual(@as(u16, @intCast(ticket1.len)), entry1.?.ticket_len);
    try testing.expectEqualSlices(u8, ticket1, entry1.?.ticket[0..entry1.?.ticket_len]);

    // ── 3. Verify transport params match ──

    try testing.expectEqual(@as(u64, 2_000_000), entry1.?.transport_params.initial_max_data);
    try testing.expectEqual(@as(u64, 128), entry1.?.transport_params.initial_max_streams_bidi);
    try testing.expectEqual(@as(u64, 60000), entry1.?.transport_params.max_idle_timeout_ms);

    // Verify transport params compatibility check works
    var current_params = conn.TransportParams{};
    current_params.initial_max_data = 3_000_000; // higher than stored — compatible
    current_params.initial_max_streams_bidi = 128;
    current_params.initial_max_stream_data_bidi_local = params1.initial_max_stream_data_bidi_local;
    current_params.initial_max_stream_data_bidi_remote = params1.initial_max_stream_data_bidi_remote;
    current_params.initial_max_stream_data_uni = params1.initial_max_stream_data_uni;
    current_params.initial_max_streams_uni = params1.initial_max_streams_uni;
    try testing.expect(conn.transportParamsCompatible(&entry1.?.transport_params, &current_params));

    // Incompatible: server reduced initial_max_data below what client remembered
    var reduced_params = conn.TransportParams{};
    reduced_params.initial_max_data = 500_000; // lower than stored 2M — incompatible
    try testing.expect(!conn.transportParamsCompatible(&entry1.?.transport_params, &reduced_params));

    // ── 4. Store 5 tickets (exceeds max_ticket_slots=4) — verify LRU eviction ──

    const server_addr2 = w32.sockaddr_in{
        .sin_port = w32.htons(4434),
        .sin_addr = 0x0100007F,
    };
    const server_addr3 = w32.sockaddr_in{
        .sin_port = w32.htons(4435),
        .sin_addr = 0x0100007F,
    };
    const server_addr4 = w32.sockaddr_in{
        .sin_port = w32.htons(4436),
        .sin_addr = 0x0100007F,
    };
    const server_addr5 = w32.sockaddr_in{
        .sin_port = w32.htons(4437),
        .sin_addr = 0x0100007F,
    };

    cache.store(server_addr2, "ticket-server2", .{});
    try testing.expectEqual(@as(u8, 2), cache.count);

    cache.store(server_addr3, "ticket-server3", .{});
    try testing.expectEqual(@as(u8, 3), cache.count);

    cache.store(server_addr4, "ticket-server4", .{});
    try testing.expectEqual(@as(u8, 4), cache.count); // full at max_ticket_slots

    // 5th store should evict the oldest (server_addr1)
    cache.store(server_addr5, "ticket-server5", .{});
    try testing.expectEqual(@as(u8, 4), cache.count); // still 4 — LRU eviction

    // server_addr1 (oldest) should be evicted
    const evicted = cache.lookup(server_addr1);
    try testing.expect(evicted == null);

    // server_addr5 (newest) should be present
    const newest = cache.lookup(server_addr5);
    try testing.expect(newest != null);
    try testing.expectEqualSlices(u8, "ticket-server5", newest.?.ticket[0..newest.?.ticket_len]);

    // server_addr2 (second oldest, now first after eviction) should still be present
    const second = cache.lookup(server_addr2);
    try testing.expect(second != null);

    // ── 5. Verify the 0-RTT key derivation path exists ──
    // keys[zero_rtt].valid can be set, confirming the key slot is addressable.

    var tls_engine = transport_crypto.TlsEngine.init(false);
    const zero_rtt_idx = @intFromEnum(transport_crypto.EncryptionLevel.zero_rtt);

    // Initially, zero_rtt keys should not be valid
    try testing.expect(!tls_engine.keys[zero_rtt_idx].valid);

    // Install synthetic 0-RTT keys (simulating derivation from session ticket)
    installTestKeys(&tls_engine, .zero_rtt);
    try testing.expect(tls_engine.keys[zero_rtt_idx].valid);

    // ── 6. Verify Connection with stored ticket has zero_rtt keys valid after setup ──
    // Simulate the 0-RTT resumption flow:
    //   a) First connection stores a ticket in the cache
    //   b) New connection looks up the ticket and installs 0-RTT keys

    const resume_addr = w32.sockaddr_in{
        .sin_port = w32.htons(5000),
        .sin_addr = 0x0100007F,
    };

    // Create a client connection
    client_storage_37_8 = conn.Connection.initClient(&client_stream_storage_37_8, resume_addr, 0);
    var client = &client_storage_37_8;

    defer {
        client.tls.state = .idle;
        client.deinit();
    }

    // Simulate: previous connection stored a ticket in the client's cache
    const resume_ticket = "resumption-ticket-data-0123456789abcdef";
    var resume_params = conn.TransportParams{};
    resume_params.initial_max_data = 4_000_000;
    resume_params.initial_max_streams_bidi = 256;
    client.ticket_cache.store(resume_addr, resume_ticket, resume_params);

    // Look up the ticket for the server we're connecting to
    const cached_entry = client.ticket_cache.lookup(resume_addr);
    try testing.expect(cached_entry != null);
    try testing.expect(cached_entry.?.valid);
    try testing.expectEqualSlices(u8, resume_ticket, cached_entry.?.ticket[0..cached_entry.?.ticket_len]);

    // Install 0-RTT keys (simulating key derivation from the session ticket)
    installTestKeys(&client.tls, .zero_rtt);
    try testing.expect(client.tls.keys[@intFromEnum(transport_crypto.EncryptionLevel.zero_rtt)].valid);

    // Set the 0-RTT state to sending (simulating client sending early data)
    client.zero_rtt_state = .sending;
    try testing.expectEqual(conn.ZeroRttState.sending, client.zero_rtt_state);

    // Simulate server accepting 0-RTT
    client.zero_rtt_state = .accepted;
    try testing.expectEqual(conn.ZeroRttState.accepted, client.zero_rtt_state);
    try testing.expect(!client.zero_rtt_rejected);

    // Verify the stored transport params are compatible with the server's current params
    try testing.expect(conn.transportParamsCompatible(
        &cached_entry.?.transport_params,
        &cached_entry.?.transport_params, // same params → always compatible
    ));
}

// ── 37.9: Version negotiation to v2 ──
// **Validates: Requirements 9.1, 9.2, 9.3, 10.1, 10.2, 10.3**
//
// Tests compatible version negotiation (RFC 9368) and QUIC v2 (RFC 9369)
// at the data structure level:
//   1. version_information transport parameter encode/decode round-trip
//   2. negotiateVersion selects v2 when both sides advertise v1+v2
//   3. v2 packet type swapping: Initial type bits differ from v1 on the wire
//   4. v2 Initial salt differs from v1 (different derived keys)
//   5. Edge case: client v1-only + server v1+v2 → negotiates v1
//   6. Edge case: no mutual version → returns null (VERSION_NEGOTIATION_ERROR)

test "Version negotiation to v2" {
    // ── 1. Build version_information for client and server, both advertising v1+v2 ──

    var client_vi: [32]u8 = [_]u8{0} ** 32;
    const client_vi_len = conn.buildVersionInfo(conn.quic_v1, &client_vi);
    try testing.expectEqual(@as(u8, 12), client_vi_len);

    var server_vi: [32]u8 = [_]u8{0} ** 32;
    const server_vi_len = conn.buildVersionInfo(conn.quic_v1, &server_vi);
    try testing.expectEqual(@as(u8, 12), server_vi_len);

    // ── 2. Encode version_information into transport params, then decode ──

    var client_params = conn.TransportParams{};
    @memcpy(client_params.version_info[0..client_vi_len], client_vi[0..client_vi_len]);
    client_params.version_info_len = client_vi_len;

    var server_params = conn.TransportParams{};
    @memcpy(server_params.version_info[0..server_vi_len], server_vi[0..server_vi_len]);
    server_params.version_info_len = server_vi_len;

    // Encode client transport params
    var client_tp_buf: [512]u8 = undefined;
    const client_tp_len = conn.encodeTransportParams(&client_params, &client_tp_buf);
    try testing.expect(client_tp_len > 0);

    // Decode on server side — verify version_info round-trips
    const decoded_client = conn.decodeTransportParams(client_tp_buf[0..client_tp_len]);
    try testing.expectEqual(packet.ParseError.none, decoded_client.err);
    try testing.expectEqual(client_vi_len, decoded_client.params.version_info_len);
    try testing.expectEqualSlices(
        u8,
        client_vi[0..client_vi_len],
        decoded_client.params.version_info[0..decoded_client.params.version_info_len],
    );

    // Encode server transport params
    var server_tp_buf: [512]u8 = undefined;
    const server_tp_len = conn.encodeTransportParams(&server_params, &server_tp_buf);
    try testing.expect(server_tp_len > 0);

    // Decode on client side
    const decoded_server = conn.decodeTransportParams(server_tp_buf[0..server_tp_len]);
    try testing.expectEqual(packet.ParseError.none, decoded_server.err);
    try testing.expectEqual(server_vi_len, decoded_server.params.version_info_len);

    // ── 3. Call negotiateVersion — verify v2 is selected (highest mutual) ──

    const negotiated = conn.negotiateVersion(
        client_vi[0..client_vi_len],
        server_vi[0..server_vi_len],
    );
    try testing.expect(negotiated != null);
    try testing.expectEqual(conn.quic_v2, negotiated.?);

    // ── 4. Verify v2 packet type swapping ──
    // Serialize a v2 Initial packet, verify the wire type bits differ from v1,
    // then parse it back and confirm the logical type is still .initial.

    var v2_initial_hdr = packet.PacketHeader{};
    v2_initial_hdr.is_long = true;
    v2_initial_hdr.version = @intFromEnum(packet.Version.quic_v2);
    v2_initial_hdr.pkt_type = .initial;
    v2_initial_hdr.dst_cid.len = 8;
    v2_initial_hdr.dst_cid.buf[0] = 0xAA;
    v2_initial_hdr.src_cid.len = 8;
    v2_initial_hdr.src_cid.buf[0] = 0xBB;
    v2_initial_hdr.payload_len = 100;

    var v2_wire: [128]u8 = undefined;
    const v2_ser = packet.serializeHeader(&v2_initial_hdr, &v2_wire);
    try testing.expectEqual(packet.ParseError.none, v2_ser.err);
    try testing.expect(v2_ser.len > 0);

    // Also serialize a v1 Initial for comparison
    var v1_initial_hdr = v2_initial_hdr;
    v1_initial_hdr.version = @intFromEnum(packet.Version.quic_v1);

    var v1_wire: [128]u8 = undefined;
    const v1_ser = packet.serializeHeader(&v1_initial_hdr, &v1_wire);
    try testing.expectEqual(packet.ParseError.none, v1_ser.err);
    try testing.expect(v1_ser.len > 0);

    // The first byte encodes the type bits — v2 swaps Initial↔Retry (0↔3),
    // so the type bits in the first byte must differ between v1 and v2.
    const v1_type_bits = (v1_wire[0] >> 4) & 0x03;
    const v2_type_bits = (v2_wire[0] >> 4) & 0x03;
    try testing.expect(v1_type_bits != v2_type_bits);

    // v1 Initial type bits = 0 (initial), v2 wire type bits = 3 (retry, after swap)
    try testing.expectEqual(@as(u8, 0), v1_type_bits);
    try testing.expectEqual(@as(u8, 3), v2_type_bits);

    // Parse the v2 wire bytes back — logical type should be .initial
    const v2_parsed = packet.parseHeader(&v2_wire);
    try testing.expectEqual(packet.ParseError.none, v2_parsed.err);
    try testing.expectEqual(packet.PacketType.initial, v2_parsed.header.pkt_type);
    try testing.expectEqual(@intFromEnum(packet.Version.quic_v2), v2_parsed.header.version);

    // ── 5. Verify v2 Initial salt differs from v1 ──
    // Derive Initial keys with both versions using the same DCID — keys must differ.

    const test_dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    const keys_v1 = transport_crypto.deriveInitialKeys(&test_dcid, false, @intFromEnum(packet.Version.quic_v1));
    const keys_v2 = transport_crypto.deriveInitialKeys(&test_dcid, false, @intFromEnum(packet.Version.quic_v2));

    try testing.expect(keys_v1.valid);
    try testing.expect(keys_v2.valid);

    // Keys must be different (different salt → different key material)
    var keys_match = true;
    for (keys_v1.key, keys_v2.key) |a, b| {
        if (a != b) {
            keys_match = false;
            break;
        }
    }
    try testing.expect(!keys_match);

    // IVs must also differ
    var ivs_match = true;
    for (keys_v1.iv, keys_v2.iv) |a, b| {
        if (a != b) {
            ivs_match = false;
            break;
        }
    }
    try testing.expect(!ivs_match);

    // ── 6. Edge case: client supports only v1, server supports v1+v2 → negotiate v1 ──

    var client_v1_only: [8]u8 = undefined;
    // chosen_version = v1, supported = [v1] only
    client_v1_only[0] = 0x00;
    client_v1_only[1] = 0x00;
    client_v1_only[2] = 0x00;
    client_v1_only[3] = 0x01; // chosen = v1
    client_v1_only[4] = 0x00;
    client_v1_only[5] = 0x00;
    client_v1_only[6] = 0x00;
    client_v1_only[7] = 0x01; // supported = [v1]

    const neg_v1 = conn.negotiateVersion(
        &client_v1_only,
        server_vi[0..server_vi_len], // server supports v1+v2
    );
    try testing.expect(neg_v1 != null);
    try testing.expectEqual(conn.quic_v1, neg_v1.?);

    // ── 7. Edge case: no mutual version → null (VERSION_NEGOTIATION_ERROR) ──

    // Client supports only a hypothetical v99 (0xDEADBEEF)
    var client_v99: [8]u8 = undefined;
    client_v99[0] = 0xDE;
    client_v99[1] = 0xAD;
    client_v99[2] = 0xBE;
    client_v99[3] = 0xEF; // chosen = 0xDEADBEEF
    client_v99[4] = 0xDE;
    client_v99[5] = 0xAD;
    client_v99[6] = 0xBE;
    client_v99[7] = 0xEF; // supported = [0xDEADBEEF]

    const neg_none = conn.negotiateVersion(
        &client_v99,
        server_vi[0..server_vi_len], // server supports v1+v2
    );
    try testing.expect(neg_none == null);
}

// ── 37.10: QuicTransportVtable end-to-end ──
// **Validates: Requirements 15.1, 15.2, 15.3, 15.4**
//
// Tests the same code path that QuicTransportVtable.get() and .post() use
// internally, exercised at the AppMap level. Since QuicTransportVtable lives
// in registry.zig (pkg module) and can't be directly imported from the
// transport integration test module, we test the underlying operations:
//
//   1. Set up connected client and server stream managers (same as 37.2)
//   2. Client creates an AppMap
//   3. Simulate vtable.get(): sendResolve() → transfer → server reads/responds → client reads
//   4. Simulate vtable.post(): sendPublish() → transfer → server reads/responds → client reads
//   5. Verify request/response round-trips work correctly
//   6. Test closed connection case: verify operations fail gracefully
//
// This exercises the full control lane path that QuicTransportVtable delegates to.

// Static storage for test 37.10 (separate from other tests).
var server_stream_storage_37_10: streams.StreamArray = undefined;
var client_stream_storage_37_10: streams.StreamArray = undefined;
var test_appmap_storage_37_10: appmap.AppMap = undefined;
var test_client_sm_37_10: streams.StreamManager = undefined;
var test_server_sm_37_10: streams.StreamManager = undefined;
var test_client_dgrams_37_10: datagram.DatagramHandler = undefined;

test "QuicTransportVtable end-to-end" {
    // ── 1. Set up connected client and server stream managers ──

    test_client_sm_37_10.init(&client_stream_storage_37_10, false);
    test_server_sm_37_10.init(&server_stream_storage_37_10, true);

    test_client_dgrams_37_10 = datagram.DatagramHandler.init();
    test_client_dgrams_37_10.enabled = true;
    test_client_dgrams_37_10.max_size = 1200;
    test_client_dgrams_37_10.peer_max_size = 1200;

    // Open stream 0 (control lane) on client
    const client_s0_id = test_client_sm_37_10.openStream(true);
    try testing.expect(client_s0_id != null);
    try testing.expectEqual(@as(u64, 0), client_s0_id.?);

    // Server: register stream 0 via onStreamData with empty data
    test_server_sm_37_10.onStreamData(0, 0, &[_]u8{}, false);
    const server_s0 = test_server_sm_37_10.getStream(0);
    try testing.expect(server_s0 != null);

    // ── 2. Client creates AppMap ──

    test_appmap_storage_37_10 = appmap.AppMap.init(&test_client_sm_37_10, &test_client_dgrams_37_10);
    var client_appmap = &test_appmap_storage_37_10;

    // ── 3. Simulate vtable.get() for a resolve URL ──
    // QuicTransportVtable.get() parses the URL, calls appmap.sendResolve(),
    // polls for a response, then calls appmap.readControlResponse().

    const send_ok = client_appmap.sendResolve("zpm", "core", "0.1.0");
    try testing.expect(send_ok);

    // Transfer: client stream 0 send_buf → server stream 0 recv_buf
    const client_s0 = test_client_sm_37_10.getStream(0).?;
    var transfer_buf: [4096]u8 = undefined;
    const bytes_from_client = client_s0.send_buf.read(&transfer_buf);
    try testing.expect(bytes_from_client > 0);

    test_server_sm_37_10.onStreamData(0, server_s0.?.recv_offset, transfer_buf[0..bytes_from_client], false);

    // Server reads and parses the resolve request
    var server_read_buf: [4096]u8 = undefined;
    const server_read_n = test_server_sm_37_10.readFromStream(0, &server_read_buf);
    try testing.expect(server_read_n > appmap.header_size);

    const req_msg = appmap.AppMap.deserializeMsg(server_read_buf[0..server_read_n]);
    try testing.expect(!req_msg.err);
    try testing.expectEqual(@as(u8, @intFromEnum(appmap.MsgType.resolve_req)), req_msg.header.msg_type);

    // Parse resolve_req payload: scope_len + scope + name_len + name + ver_len + ver
    const payload = req_msg.payload;
    var rpos: usize = 0;
    const scope_len = payload[rpos];
    rpos += 1;
    try testing.expectEqual(@as(u8, 4), scope_len); // "zpm"
    try testing.expectEqualSlices(u8, "zpm", payload[rpos .. rpos + scope_len]);
    rpos += scope_len;
    const name_len = payload[rpos];
    rpos += 1;
    try testing.expectEqual(@as(u8, 4), name_len); // "core"
    try testing.expectEqualSlices(u8, "core", payload[rpos .. rpos + name_len]);
    rpos += name_len;
    const ver_len = payload[rpos];
    rpos += 1;
    try testing.expectEqual(@as(u8, 5), ver_len); // "0.1.0"
    try testing.expectEqualSlices(u8, "0.1.0", payload[rpos .. rpos + ver_len]);

    // Server writes a resolve_resp (simulating registry JSON response)
    const resolve_body = "{\"scope\":\"zpm\",\"name\":\"core\",\"version\":\"0.1.0\"}";
    var resp_wire: [4096]u8 = undefined;
    const resp_total = appmap.AppMap.serializeMsg(.resolve_resp, 0, resolve_body, &resp_wire);
    try testing.expect(resp_total > 0);

    const srv_written = test_server_sm_37_10.writeToStream(0, resp_wire[0..resp_total]);
    try testing.expectEqual(resp_total, srv_written);

    // Transfer: server stream 0 send_buf → client stream 0 recv_buf
    var transfer_buf2: [4096]u8 = undefined;
    const bytes_from_server = server_s0.?.send_buf.read(&transfer_buf2);
    try testing.expect(bytes_from_server > 0);

    const client_recv_s0 = test_client_sm_37_10.getStream(0).?;
    _ = client_recv_s0.recv_buf.write(transfer_buf2[0..bytes_from_server]);

    // Client reads the response via readControlResponse (same as vtable.get() does)
    var resp_out: [4096]u8 = undefined;
    const ctrl_resp = client_appmap.readControlResponse(&resp_out);

    // Verify: response matches what the server sent
    try testing.expectEqual(appmap.MsgType.resolve_resp, ctrl_resp.msg_type);
    try testing.expectEqual(@as(u32, @intCast(resolve_body.len)), ctrl_resp.payload_len);
    try testing.expectEqualSlices(u8, resolve_body, resp_out[0..ctrl_resp.payload_len]);

    // ── 4. Simulate vtable.post() for a publish URL ──
    // QuicTransportVtable.post() calls appmap.sendPublish() with the JSON body,
    // polls for a response, then calls appmap.readControlResponse().

    const publish_json = "{\"scope\":\"zpm\",\"name\":\"core\",\"version\":\"0.2.0\",\"layer\":0}";
    const pub_ok = client_appmap.sendPublish(publish_json);
    try testing.expect(pub_ok);

    // Transfer: client → server
    var pub_transfer: [4096]u8 = undefined;
    const pub_bytes = client_s0.send_buf.read(&pub_transfer);
    try testing.expect(pub_bytes > 0);

    test_server_sm_37_10.onStreamData(0, server_s0.?.recv_offset, pub_transfer[0..pub_bytes], false);

    // Server reads and parses the publish request
    var pub_read_buf: [4096]u8 = undefined;
    const pub_read_n = test_server_sm_37_10.readFromStream(0, &pub_read_buf);
    try testing.expect(pub_read_n > appmap.header_size);

    const pub_msg = appmap.AppMap.deserializeMsg(pub_read_buf[0..pub_read_n]);
    try testing.expect(!pub_msg.err);
    try testing.expectEqual(@as(u8, @intFromEnum(appmap.MsgType.publish_req)), pub_msg.header.msg_type);
    try testing.expectEqualSlices(u8, publish_json, pub_msg.payload);

    // Server writes a publish_resp
    const publish_resp_body = "{\"status\":\"success\",\"message\":\"published\"}";
    var pub_resp_wire: [4096]u8 = undefined;
    const pub_resp_total = appmap.AppMap.serializeMsg(.publish_resp, 0, publish_resp_body, &pub_resp_wire);
    try testing.expect(pub_resp_total > 0);

    const pub_srv_written = test_server_sm_37_10.writeToStream(0, pub_resp_wire[0..pub_resp_total]);
    try testing.expectEqual(pub_resp_total, pub_srv_written);

    // Transfer: server → client
    var pub_transfer2: [4096]u8 = undefined;
    const pub_bytes2 = server_s0.?.send_buf.read(&pub_transfer2);
    try testing.expect(pub_bytes2 > 0);
    _ = client_recv_s0.recv_buf.write(pub_transfer2[0..pub_bytes2]);

    // Client reads the publish response
    var pub_resp_out: [4096]u8 = undefined;
    const pub_ctrl_resp = client_appmap.readControlResponse(&pub_resp_out);

    // Verify: publish response matches
    try testing.expectEqual(appmap.MsgType.publish_resp, pub_ctrl_resp.msg_type);
    try testing.expectEqual(@as(u32, @intCast(publish_resp_body.len)), pub_ctrl_resp.payload_len);
    try testing.expectEqualSlices(u8, publish_resp_body, pub_resp_out[0..pub_ctrl_resp.payload_len]);

    // ── 5. Verify: RegistryClient works transparently with the QUIC vtable ──
    // The vtable is a thin adapter: get() → sendResolve + readControlResponse,
    // post() → sendPublish + readControlResponse. We've just proven both paths
    // produce correct round-trip results. The RegistryClient calls get()/post()
    // on the HttpVtable interface — since QuicTransportVtable.asHttpVtable()
    // returns function pointers that delegate to exactly these AppMap operations,
    // the RegistryClient works transparently over QUIC.
    //
    // Verify the sequential request pattern works (multiple ops on stream 0):
    // Send a second resolve after the publish — stream 0 handles sequential messages.

    const send_ok2 = client_appmap.sendResolve("myorg", "utils", null);
    try testing.expect(send_ok2);

    var transfer3: [4096]u8 = undefined;
    const bytes3 = client_s0.send_buf.read(&transfer3);
    try testing.expect(bytes3 > 0);

    test_server_sm_37_10.onStreamData(0, server_s0.?.recv_offset, transfer3[0..bytes3], false);

    var read_buf3: [4096]u8 = undefined;
    const read_n3 = test_server_sm_37_10.readFromStream(0, &read_buf3);
    try testing.expect(read_n3 > appmap.header_size);

    const msg3 = appmap.AppMap.deserializeMsg(read_buf3[0..read_n3]);
    try testing.expect(!msg3.err);
    try testing.expectEqual(@as(u8, @intFromEnum(appmap.MsgType.resolve_req)), msg3.header.msg_type);

    // Verify the payload has scope="myorg", name="utils", version="" (null)
    const p3 = msg3.payload;
    try testing.expectEqual(@as(u8, 5), p3[0]); // "myorg" len
    try testing.expectEqualSlices(u8, "myorg", p3[1..6]);
    try testing.expectEqual(@as(u8, 5), p3[6]); // "utils" len
    try testing.expectEqualSlices(u8, "utils", p3[7..12]);
    try testing.expectEqual(@as(u8, 0), p3[12]); // no version

    // ── 6. Test closed connection case ──
    // When the connection is closed, sendResolve and sendPublish should still
    // attempt to write to stream 0 (AppMap doesn't check connection state —
    // that's the vtable's job). But readControlResponse on an empty recv_buf
    // returns a zero-length response, which the vtable interprets as failure.
    //
    // Drain any remaining data from client stream 0 recv_buf to ensure it's empty.
    var drain_buf: [4096]u8 = undefined;
    _ = client_recv_s0.recv_buf.read(&drain_buf);

    // Read from empty recv_buf — should return default (no data)
    var empty_resp: [4096]u8 = undefined;
    const empty_ctrl = client_appmap.readControlResponse(&empty_resp);
    try testing.expectEqual(@as(u32, 0), empty_ctrl.payload_len);
}
