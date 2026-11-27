// Thin CLI mesh-node harness over mesh_transport.Mesh.
//
// One small, dependency-light executable that serves as both the Windows and
// the Android arm64 mesh node (the role/addresses select which). It constructs
// a real conn.Connection bound to a UDP address (via the win32/linux_platform
// socket seam), wraps it in mesh_transport.Mesh, then loops mesh.tick():
//   - a client periodically broadcasts a small known gossip payload;
//   - a server polls for inbound gossip and prints received payloads to stdout.
// It exits cleanly after N exchanges or a tick budget (timeout stand-in).
//
// Configuration — the playbook permits hardcoded sensible defaults / compile-
// time constants for the first bring-up run (adb cannot tunnel UDP, so S1 runs
// both ends on the phone over 127.0.0.1 and S2 runs over the Wi-Fi LAN). These
// `const`s are the knobs; a later revision can parse --role/--bind/--peer args
// once a no-alloc argv path is wired. Override by editing before a build, e.g.
//   role = .server, bind_port = 46000                     (phone S1 server)
//   role = .client, peer_addr = 0x0100007F, peer_port=46000 (phone S1 client)
//   role = .client, peer_addr = 192.168.1.214, peer_port=46000 (PC->phone S2)
//
// Dependency-light: imports only mesh_transport, conn, streams and win32 (for
// the sockaddr type + byte-order helpers). No libc; stdout is written through a
// tiny platform-conditional seam so the same source links for Windows (kernel32
// WriteFile) and Android/Linux (raw write syscall).

const std = @import("std");
const builtin = @import("builtin");
const mesh_transport = @import("mesh_transport");
const conn = @import("conn");
const streams = @import("streams");
const w32 = @import("win32");

/// Deterministic loopback/LAN test certificate: a 32-byte ECDSA P-256 private
/// scalar and its 65-byte SEC1 public point. Mirrors makeMeshTestCert in the
/// mesh_transport M1 harness so a server mesh-node presents a cert the client
/// can verify (loopback/LAN trust). NOT a production PKI certificate.
fn makeMeshTestCert(cert_out: *[65]u8) [32]u8 {
    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(0x51 + i);
    const kp = EcdsaP256.KeyPair.generateDeterministic(seed) catch unreachable;
    const scalar = kp.secret_key.toBytes();
    cert_out.* = kp.public_key.toUncompressedSec1();
    return scalar;
}

// ── Config (edit for the target role/addresses; defaults = loopback client) ──

const Role = enum { server, client };

const role: Role = .client;
const bind_port: u16 = 0; // OS-assigned ephemeral local port
const peer_addr_be: u32 = 0xD601A8C0; // 192.168.1.214 (phone) network-order sin_addr
const peer_port: u16 = 46000;
const max_exchanges: u32 = 8; // exit after this many sent/received payloads
const tick_budget: u32 = 600_000; // tick cap; with ~1ms sleep/tick this is ~10 min
const tick_sleep_ns: u64 = 1_000_000; // 1ms between ticks so the loop doesn't busy-spin

// A small known gossip payload the client broadcasts and the server prints.
const gossip_payload = "minegrind-mesh-hello";

// StreamArray is ~8MB — must be a module-level static, never a stack local.
var node_stream_storage: streams.StreamArray = undefined;
var node_conn: conn.Connection = undefined;

// Inbound scratch for printing received gossip.
var recv_scratch: [1500]u8 = undefined;

// ── stdout seam (libc-free, cross-platform) ──

const win = struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.c) HANDLE;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.c) BOOL;
};

fn writeOut(s: []const u8) void {
    if (builtin.os.tag == .windows) {
        const h = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        var written: win.DWORD = 0;
        _ = win.WriteFile(h, s.ptr, @intCast(s.len), &written, null);
    } else {
        const linux = @import("std").os.linux;
        _ = linux.write(1, s.ptr, s.len);
    }
}

const kernel32 = struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
};

/// Sleep ~tick_sleep_ns so the tick loop paces itself (keeps a server alive for
/// a human-timescale client without busy-spinning through the tick budget).
fn sleepTick() void {
    if (builtin.os.tag == .windows) {
        kernel32.Sleep(@intCast(tick_sleep_ns / 1_000_000));
    } else {
        const linux = @import("std").os.linux;
        var ts = linux.timespec{ .sec = 0, .nsec = @intCast(tick_sleep_ns) };
        _ = linux.syscall2(.nanosleep, @intFromPtr(&ts), @intFromPtr(&ts));
    }
}

pub fn main() void {
    writeOut("mesh-node: start\n");

    // Build the connection for the selected role, bound via UDP.
    const peer = w32.sockaddr_in{
        .sin_port = w32.htons(peer_port),
        .sin_addr = peer_addr_be,
    };
    switch (role) {
        .server => {
            conn.Connection.initServerInPlace(&node_conn, &node_stream_storage, bind_port);
            // Load the server's test certificate + ECDSA P-256 key before its
            // first tick, so the client can verify CertificateVerify.
            var cert: [65]u8 = undefined;
            const scalar = makeMeshTestCert(&cert);
            _ = node_conn.loadTlsCertificate(&cert, &scalar);
            writeOut("mesh-node: role=server (cert loaded)\n");
        },
        .client => {
            conn.Connection.initClientInPlace(&node_conn, &node_stream_storage, peer, bind_port);
            writeOut("mesh-node: role=client\n");
        },
    }
    defer node_conn.socket.deinit();

    var mesh = mesh_transport.Mesh.init(&node_conn, .{});

    var exchanges: u32 = 0;
    var ticks: u32 = 0;
    while (exchanges < max_exchanges and ticks < tick_budget) : (ticks += 1) {
        _ = mesh.tick();
        sleepTick();

        switch (role) {
            .client => {
                // Only broadcast once the QUIC handshake has completed; before
                // then broadcastGossip returns NotConnected (by design). Over a
                // real network the handshake takes many ticks, so gate on state
                // and pace the sends.
                if (node_conn.state == .connected and ticks % 64 == 0) {
                    mesh.broadcastGossip(gossip_payload) catch |e| switch (e) {
                        error.NotConnected, error.StreamUnavailable => {}, // not ready / queue full — retry
                        else => {
                            writeOut("mesh-node: broadcast error\n");
                            return;
                        },
                    };
                    exchanges += 1;
                }
            },
            .server => {
                // Drain any inbound gossip and print it.
                while (mesh.pollGossip()) |payload| {
                    const n = @min(payload.len, recv_scratch.len);
                    @memcpy(recv_scratch[0..n], payload[0..n]);
                    writeOut("mesh-node: recv gossip: ");
                    writeOut(recv_scratch[0..n]);
                    writeOut("\n");
                    exchanges += 1;
                    if (exchanges >= max_exchanges) break;
                }
            },
        }
    }

    writeOut("mesh-node: done\n");
}
