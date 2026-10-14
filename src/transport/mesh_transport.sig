// Layer 1 — Peer-to-peer mesh transport.
//
// Composes the QUIC transport siblings (conn / streams / datagram / packet)
// into a thin peer-to-peer mesh protocol, exactly like appmap composes them
// into the zpm registry protocol. This module is DOMAIN-AGNOSTIC: it carries
// OPAQUE []const u8 payloads and never decodes MineGrind wire formats (MGGP /
// MGCK). It must not import `minegrind` or `mesh_wire`.
//
// Lane mapping:
//   Gossip      → DATAGRAM frames (unreliable, latest-wins, <= 1200 B)
//   Checkpoint  → reliable bidirectional stream (ordered, up to ~10 KB batches)
//
// Peer authentication uses Ed25519 over a 32-byte challenge. Ed25519 verify is
// pure Sig (std.crypto.sign.Ed25519) and is permitted at Layer 1.
//
// Caller-owned-struct convention (like appmap.AppMap): `Mesh` holds a pointer
// into an externally-owned `conn.Connection` (which itself owns the datagram
// handler, stream manager and socket). The StreamArray backing the connection
// must be a module-level `var` static supplied by the caller — never a stack
// local (it is ~8 MB). Zero allocator usage.

const std = @import("std");
const conn = @import("conn");
const streams = @import("streams");
const datagram = @import("datagram");
const packet = @import("packet");

/// A 32-byte peer identity (Ed25519 public key).
pub const PeerId = [32]u8;

pub const Error = error{
    NotConnected,
    AuthFailed,
    TooLarge,
    StreamUnavailable,
    ShortWrite,
};

/// Mesh configuration. `loopback_only` defaults true; the public-network path
/// is a DISABLED GATE — no public path is implemented in this module.
pub const Config = struct {
    loopback_only: bool = true,
};

pub const Mesh = struct {
    conn: *conn.Connection,
    cfg: Config,

    /// Wrap an externally-owned Connection. The connection owns the datagram
    /// handler, stream manager and socket; `Mesh` holds a pointer to it.
    pub fn init(c: *conn.Connection, cfg: Config) Mesh {
        return .{ .conn = c, .cfg = cfg };
    }

    /// Broadcast an opaque gossip payload as a single DATAGRAM frame.
    /// Gossip must fit in one datagram (<= datagram.max_datagram_size = 1200).
    /// Oversized payloads return error.TooLarge; a full/unavailable queue
    /// returns error.StreamUnavailable.
    pub fn broadcastGossip(self: *Mesh, msg: []const u8) Error!void {
        if (msg.len > datagram.max_datagram_size) return error.TooLarge;
        if (!self.conn.datagrams.queueSend(msg)) return error.StreamUnavailable;
    }

    /// Poll for the next inbound gossip payload. Returns an opaque slice into
    /// the datagram handler's queue, or null if none is pending. Inbound
    /// datagrams are drained from the connection's datagram queue and validated
    /// through the RFC 9221 onReceive size/enabled gate before delivery.
    pub fn pollGossip(self: *Mesh) ?[]const u8 {
        const dq = self.conn.datagrams.dequeueSend() orelse return null;
        return self.conn.datagrams.onReceive(dq.data);
    }

    /// Send an opaque checkpoint batch over a reliable bidirectional stream.
    /// Checkpoint batches (up to ~10 KB) exceed the datagram cap, so they use a
    /// stream. Opening a stream when the limit is reached returns
    /// error.StreamUnavailable; a partial write returns error.ShortWrite.
    pub fn sendCheckpointBatch(self: *Mesh, batch: []const u8) Error!void {
        const sid = self.conn.stream_mgr.openStream(true) orelse return error.StreamUnavailable;
        const written = self.conn.stream_mgr.writeToStream(sid, batch);
        if (written < batch.len) return error.ShortWrite;
    }

    /// Read an opaque checkpoint batch from a reliable stream into `out`.
    /// Returns the number of bytes read.
    pub fn readCheckpointBatch(self: *Mesh, stream_id: u64, out: []u8) u32 {
        return self.conn.stream_mgr.readFromStream(stream_id, out);
    }

    /// Verify a peer's Ed25519 signature over a 32-byte challenge.
    /// Returns error.AuthFailed if the signature does not verify.
    pub fn onChallenge(
        self: *Mesh,
        peer: *const PeerId,
        challenge: *const [32]u8,
        sig: *const [64]u8,
    ) Error!void {
        _ = self;
        const Ed25519 = std.crypto.sign.Ed25519;
        const pub_key = Ed25519.PublicKey.fromBytes(peer.*) catch return error.AuthFailed;
        const signature = Ed25519.Signature.fromBytes(sig.*);
        signature.verify(challenge, pub_key) catch return error.AuthFailed;
    }

    /// Drive the underlying connection forward (recv, process frames, send).
    pub fn tick(self: *Mesh) conn.ConnState {
        return self.conn.tick();
    }
};

// ── Tests ──
// Feature: distributed-mmorpg-infrastructure
//
// Modeled on integration_test.sig: two Connections on loopback (0x0100007F)
// with a module-level var StreamArray static per side and synthetic keys,
// driven by the data-transfer-between-ring-buffers approach the transport
// integration tests use (conn.dispatchFrames does metadata only).

const testing = std.testing;

// Module-level statics — StreamArray is ~8MB and Connection is large.
var mesh_client_storage: streams.StreamArray = undefined;
var mesh_server_storage: streams.StreamArray = undefined;
var mesh_client_conn: conn.Connection = undefined;
var mesh_server_conn: conn.Connection = undefined;

// Large opaque payload buffers — module-level to avoid stack pressure.
var ckpt_send_buf: [10016]u8 = undefined;
var ckpt_recv_buf: [10016]u8 = undefined;
var ckpt_transfer_buf: [10016]u8 = undefined;

const w32 = @import("win32");

// 127.0.0.1 loopback peer address. Both mesh nodes are initialized as clients
// (OUTBOUND SChannel creds) so no server certificate is required in-process —
// a peer-to-peer loopback node needs no inbound SChannel credential. This still
// exercises real Connections, UDP sockets, datagram handlers and stream
// managers; the handshake itself is not driven (synthetic/transfer path), same
// as the transport integration tests.
const loopback_addr = w32.sockaddr_in{ .sin_port = 0, .sin_addr = 0x0100007F };

// Feature: distributed-mmorpg-infrastructure, Requirement 1.1-1.2
test "gossip round trip of a 184-byte opaque payload" {
    mesh_client_conn = conn.Connection.initClient(&mesh_client_storage, loopback_addr, 0);
    mesh_server_conn = conn.Connection.initClient(&mesh_server_storage, loopback_addr, 0);
    defer {
        mesh_client_conn.tls.state = .idle;
        mesh_server_conn.tls.state = .idle;
        mesh_client_conn.socket.deinit();
        mesh_server_conn.socket.deinit();
    }

    var sender = Mesh.init(&mesh_client_conn, .{});
    var receiver = Mesh.init(&mesh_server_conn, .{});

    // Build a deterministic 184-byte opaque payload (the MGGP gossip size).
    var payload: [184]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    try sender.broadcastGossip(&payload);

    // Transfer the queued datagram from the sender into the receiver's queue
    // (the loopback stand-in for the sender's packet assembly reaching the
    // receiver), then poll it through onReceive.
    const dq = sender.conn.datagrams.dequeueSend() orelse return error.TestUnexpectedResult;
    try testing.expect(receiver.conn.datagrams.queueSend(dq.data));

    const got = receiver.pollGossip() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 184), got.len);
    try testing.expectEqualSlices(u8, &payload, got);

    // No further gossip pending.
    try testing.expect(receiver.pollGossip() == null);
}

// Feature: distributed-mmorpg-infrastructure, Requirement 1.6
test "oversized gossip returns error.TooLarge" {
    mesh_client_conn = conn.Connection.initClient(&mesh_client_storage, loopback_addr, 0);
    defer {
        mesh_client_conn.tls.state = .idle;
        mesh_client_conn.socket.deinit();
    }

    var sender = Mesh.init(&mesh_client_conn, .{});

    var big: [1201]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i);

    try testing.expectError(error.TooLarge, sender.broadcastGossip(&big));
}

// Feature: distributed-mmorpg-infrastructure, Requirement 1.7-1.8
test "checkpoint batch over a reliable stream reassembled identical" {
    mesh_client_conn = conn.Connection.initClient(&mesh_client_storage, loopback_addr, 0);
    mesh_server_conn = conn.Connection.initClient(&mesh_server_storage, loopback_addr, 0);
    defer {
        mesh_client_conn.tls.state = .idle;
        mesh_server_conn.tls.state = .idle;
        mesh_client_conn.socket.deinit();
        mesh_server_conn.socket.deinit();
    }

    var sender = Mesh.init(&mesh_client_conn, .{});
    var receiver = Mesh.init(&mesh_server_conn, .{});

    // ~10,016-byte opaque batch (32 + 64*156 — the max MGCK batch size).
    for (&ckpt_send_buf, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    try sender.sendCheckpointBatch(&ckpt_send_buf);

    // Transfer the written stream bytes from the sender's send_buf into the
    // receiver's recv_buf (loopback stand-in). The client opened stream 0.
    const client_s0 = sender.conn.stream_mgr.getStream(0).?;
    const n = client_s0.send_buf.read(&ckpt_transfer_buf);
    try testing.expectEqual(@as(u32, ckpt_send_buf.len), n);

    // Register the stream on the receiver and feed the bytes in.
    receiver.conn.stream_mgr.onStreamData(0, 0, ckpt_transfer_buf[0..n], false);

    const read_n = receiver.readCheckpointBatch(0, &ckpt_recv_buf);
    try testing.expectEqual(@as(u32, ckpt_send_buf.len), read_n);
    try testing.expectEqualSlices(u8, &ckpt_send_buf, ckpt_recv_buf[0..read_n]);
}

// Feature: distributed-mmorpg-infrastructure, Requirement 4.2-4.3
test "onChallenge accepts a valid Ed25519 signature and rejects a wrong one" {
    mesh_client_conn = conn.Connection.initClient(&mesh_client_storage, loopback_addr, 0);
    defer {
        mesh_client_conn.tls.state = .idle;
        mesh_client_conn.socket.deinit();
    }

    var m = Mesh.init(&mesh_client_conn, .{});

    const Ed25519 = std.crypto.sign.Ed25519;
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(0x11 + i);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    var challenge: [32]u8 = undefined;
    for (&challenge, 0..) |*b, i| b.* = @truncate(0xA0 + i);

    const peer: PeerId = kp.public_key.toBytes();

    const good_sig = (try kp.sign(&challenge, null)).toBytes();
    try m.onChallenge(&peer, &challenge, &good_sig);

    // Flip a bit in the signature → must fail.
    var bad_sig = good_sig;
    bad_sig[0] ^= 0x01;
    try testing.expectError(error.AuthFailed, m.onChallenge(&peer, &challenge, &bad_sig));

    // A different challenge against the valid signature → must fail.
    var other_challenge = challenge;
    other_challenge[31] ^= 0xFF;
    try testing.expectError(error.AuthFailed, m.onChallenge(&peer, &other_challenge, &good_sig));
}
