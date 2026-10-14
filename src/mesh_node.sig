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

const builtin = @import("builtin");
const mesh_transport = @import("mesh_transport");
const conn = @import("conn");
const streams = @import("streams");
const w32 = @import("win32");

// ── Config (edit for the target role/addresses; defaults = loopback client) ──

const Role = enum { server, client };

const role: Role = .client;
const bind_port: u16 = 0; // 0 = OS-assigned ephemeral local port
const peer_addr_be: u32 = 0x0100007F; // 127.0.0.1 (little-endian host 1.0.0.127 wire)
const peer_port: u16 = 46000;
const max_exchanges: u32 = 8; // exit after this many sent/received payloads
const tick_budget: u32 = 20_000; // tick cap (timeout stand-in) if idle

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

pub fn main() void {
    writeOut("mesh-node: start\n");

    // Build the connection for the selected role, bound via UDP.
    const peer = w32.sockaddr_in{
        .sin_port = w32.htons(peer_port),
        .sin_addr = peer_addr_be,
    };
    switch (role) {
        .server => {
            node_conn = conn.Connection.initServer(&node_stream_storage, bind_port);
            writeOut("mesh-node: role=server\n");
        },
        .client => {
            node_conn = conn.Connection.initClient(&node_stream_storage, peer, bind_port);
            writeOut("mesh-node: role=client\n");
        },
    }
    defer node_conn.socket.deinit();

    var mesh = mesh_transport.Mesh.init(&node_conn, .{});

    var exchanges: u32 = 0;
    var ticks: u32 = 0;
    while (exchanges < max_exchanges and ticks < tick_budget) : (ticks += 1) {
        _ = mesh.tick();

        switch (role) {
            .client => {
                // Periodically broadcast a small known payload.
                if (ticks % 64 == 0) {
                    mesh.broadcastGossip(gossip_payload) catch |e| switch (e) {
                        error.StreamUnavailable => {}, // queue momentarily full — retry next loop
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
