//! Actual UDP/QUIC/TLS, shared listeners and peer discovery. No forced session keys.
const std = @import("std");
const mesh = @import("mesh_overlay");
const network = @import("mesh_network");
const w = @import("win32");
const udp = @import("udp");
const Net = network.Network(8, 2, 16);
var storage: [3]Net.Storage = undefined;
var services: [3]Net = undefined;
var keys: [3]mesh.Identity = undefined;
var checks: usize = 0;
fn check(ok: bool) !void {
    checks += 1;
    if (!ok) return error.NetworkContractFailed;
}
fn nowMs() u64 {
    var now: w.LARGE_INTEGER = .{};
    var frequency: w.LARGE_INTEGER = .{};
    _ = w.QueryPerformanceCounter(&now);
    _ = w.QueryPerformanceFrequency(&frequency);
    return @intCast(@divTrunc(now.QuadPart, @divTrunc(frequency.QuadPart, 1000)));
}
fn pump(duration: u64) !void {
    const deadline = nowMs() + duration;
    while (nowMs() < deadline) {
        for (&services) |*service| try service.tick(nowMs());
        w.Sleep(1);
    }
}
pub fn main() !void {
    // A borrowed receiver cannot drain the owner or close its handle.
    var socket = udp.UdpSocket.init();
    defer socket.deinit();
    try check(socket.bind(.{ .sin_addr = 0x0100007f }) == .none);
    var inbox: udp.Inbox = .{};
    var borrowed = socket.borrow(&inbox);
    try check(inbox.push("hello", .{ .sin_port = 1234 }));
    var buf: [8]u8 = undefined;
    const received = borrowed.recv(&buf);
    try check(received.bytes_read == 5 and received.src_addr.sin_port == 1234);
    borrowed.deinit();
    try check(socket.getLocalAddr().err == .none);
    var endpoints: [3]mesh.Endpoint = undefined;
    // Reserve ephemeral ports without relying on globally fixed test ports.
    var reservations: [3]udp.UdpSocket = undefined;
    for (&reservations, 0..) |*reservation, i| {
        reservation.* = udp.UdpSocket.init();
        try check(reservation.bind(.{ .sin_addr = 0x0100007f }) == .none);
        endpoints[i] = .{ .port = w.ntohs(reservation.getLocalAddr().addr.sin_port) };
        keys[i] = try mesh.Identity.generateDeterministic(@splat(@as(u8, @intCast(i + 11))));
    }
    for (&reservations) |*reservation| reservation.deinit();
    var seeds = [_]mesh.Endpoint{endpoints[0]};
    for (&services, 0..) |*service, i| {
        try service.init(&storage[i], .{ .realm = @splat(66), .identity = &keys[i], .epoch = 1, .endpoint = endpoints[i], .seeds = if (i == 0) &.{} else &seeds }, nowMs());
    }
    defer for (&services) |*service| service.stop();
    const connect_deadline = nowMs() + 15_000;
    while (nowMs() < connect_deadline) {
        try pump(10);
        if (services[0].connectedCount() == 2 and services[1].connectedCount() == 2 and services[2].connectedCount() == 2) break;
    }
    for (&services) |*service| {
        std.debug.print("connected={d} dropped={d}\n", .{ service.connectedCount(), service.dropped });
        try check(service.connectedCount() == 2);
    }
    try services[0].broadcast("synthetic-record-v1", nowMs());
    var seen: [2]bool = @splat(false);
    const deadline = nowMs() + 5000;
    while (nowMs() < deadline and !(seen[0] and seen[1])) {
        try pump(10);
        for (1..3) |i| while (services[i].poll()) |bytes| {
            const view = try mesh.decode(bytes, @splat(66), nowMs(), .loopback);
            if (std.mem.eql(u8, view.body, "synthetic-record-v1")) seen[i - 1] = true;
        };
    }
    try check(seen[0] and seen[1]);
    // Stop one process incarnation, keep the others running past liveness expiry.
    services[2].stop();
    const until = nowMs() + 6500;
    while (nowMs() < until) {
        try services[0].tick(nowMs());
        try services[1].tick(nowMs());
        w.Sleep(1);
    }
    try check(services[0].connectedCount() == 1 and services[1].connectedCount() == 1);
    try services[2].init(&storage[2], .{ .realm = @splat(66), .identity = &keys[2], .epoch = 2, .endpoint = endpoints[2], .seeds = &seeds }, nowMs());
    const recovery_deadline = nowMs() + 15_000;
    while (nowMs() < recovery_deadline) {
        try pump(10);
        if (services[2].connectedCount() == 2) break;
    }
    // Let both neighbors consume the restarted peer's own signed card, then
    // require the sessions to remain connected at its new incarnation.
    try pump(500);
    for (0..2) |i| {
        const member = services[i].core.find(keys[2].public_key.toBytes()) orelse return error.MissingRestartedPeer;
        try check(services[i].core.peers[member].epoch == 2 and services[i].connectedCount() == 2);
    }
    for (&services, 0..) |*service, i| {
        std.debug.print("recovery node={d} connected={d} dropped={d} retries={d}\n", .{ i, service.connectedCount(), service.dropped, service.reconnects });
        for (service.core.peers) |peer| if (peer.used) std.debug.print(" peer={x} epoch={d} connected={} attempts={d} exhausted={}\n", .{ peer.key[0..4], peer.epoch, peer.connected, peer.attempts, peer.exhausted });
    }
    try check(services[2].connectedCount() == 2);
    // The bounded cache repairs missed data after reconnect, without re-signing it.
    var recovered = false;
    const sync_deadline = nowMs() + 5000;
    while (nowMs() < sync_deadline and !recovered) {
        try pump(10);
        while (services[2].poll()) |bytes| {
            const view = try mesh.decode(bytes, @splat(66), nowMs(), .loopback);
            if (std.mem.eql(u8, view.body, "synthetic-record-v1")) recovered = true;
        }
    }
    try check(recovered);
    std.debug.print("Mesh network PASS: {d} assertions; nodes=3 links/node=2 discovery+reconnect+cache-repair real QUIC; storage/node={d}\n", .{ checks, @sizeOf(Net.Storage) + @sizeOf(Net) });
}
