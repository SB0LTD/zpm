const std = @import("std");
const mesh = @import("mesh_overlay");
const Core = mesh.Overlay(3, 4, 2);
var count: usize = 0;
fn check(ok: bool) !void {
    count += 1;
    if (!ok) return error.ContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |err| try check(err == expected);
}
fn sign(key: *const mesh.Identity, kind: mesh.Kind, epoch: u64, seq: u64, body: []const u8, out: []u8) !usize {
    return mesh.encode(key, @splat(42), kind, epoch, seq, 30_001, body, out);
}
pub fn main() !void {
    const a = try mesh.Identity.generateDeterministic(@splat(1));
    const b = try mesh.Identity.generateDeterministic(@splat(2));
    const c = try mesh.Identity.generateDeterministic(@splat(3));
    const d = try mesh.Identity.generateDeterministic(@splat(4));
    const e = try mesh.Identity.generateDeterministic(@splat(5));
    var core = Core.init(@splat(42), .loopback, a.public_key.toBytes());
    var card: [mesh.card_size]u8 = undefined;
    const body = mesh.cardBody(.{ .port = 45000 });
    _ = try sign(&b, .card, 1, 1, &body, &card);
    const bi = try core.learn(&card, 1);
    try check(!core.peers[bi].connected);
    var data: [mesh.frame_capacity]u8 = undefined;
    const n = try sign(&b, .data, 1, 2, "record", &data);
    try rejects(error.UnknownPeer, core.receive(b.public_key.toBytes(), data[0..n], 1));
    try core.setConnected(b.public_key.toBytes(), true);
    try core.receive(b.public_key.toBytes(), data[0..n], 1);
    try rejects(error.Replay, core.receive(b.public_key.toBytes(), data[0..n], 1));
    _ = try sign(&b, .data, 1, 4, "four", &data);
    try core.receive(b.public_key.toBytes(), data[0 .. n - 2], 1);
    const three = try sign(&b, .data, 1, 3, "three", &data);
    try rejects(error.Backpressure, core.receive(b.public_key.toBytes(), data[0..three], 1));
    try check(core.peers[bi].high == 4);
    _ = core.poll();
    try core.receive(b.public_key.toBytes(), data[0..three], 1); // pressure did not mark it seen
    while (core.poll()) |_| {}
    const far = try sign(&b, .data, 1, 100, "far", &data);
    try core.receive(b.public_key.toBytes(), data[0..far], 1);
    _ = core.poll();
    const old = try sign(&b, .data, 1, 2, "old", &data);
    try rejects(error.Replay, core.receive(b.public_key.toBytes(), data[0..old], 1));
    _ = try sign(&b, .card, 2, 1, &body, &card);
    _ = try core.learn(&card, 1);
    try core.setConnected(b.public_key.toBytes(), true);
    try rejects(error.Replay, core.receive(b.public_key.toBytes(), data[0..old], 1));
    _ = try sign(&c, .card, 1, 1, &body, &card);
    _ = try core.learn(&card, 1);
    _ = try sign(&d, .card, 1, 1, &body, &card);
    _ = try core.learn(&card, 1);
    _ = try sign(&e, .card, 1, 1, &body, &card);
    try rejects(error.Capacity, core.learn(&card, 1));
    _ = try sign(&b, .card, 2, 2, &body, &card);
    for (0..card.len) |i| {
        var bad = card;
        bad[i] ^= 1;
        if (mesh.decode(&bad, @splat(42), 1, .loopback)) |_| return error.TamperAccepted else |_| count += 1;
    }
    for (0..card.len) |i| {
        if (mesh.decode(card[0..i], @splat(42), 1, .loopback)) |_| return error.TruncatedAccepted else |_| count += 1;
    }
    try rejects(error.Expired, mesh.decode(&card, @splat(42), 30_001, .loopback));
    // Independent device clocks need not be millisecond-identical. Bound only
    // the sender's clock lead; expired packets still receive no grace period.
    var ahead: [mesh.card_size]u8 = undefined;
    _ = try mesh.encode(&b, @splat(42), .card, 2, 3, 35_001, &body, &ahead);
    _ = try mesh.decode(&ahead, @splat(42), 1, .loopback);
    count += 1;
    try rejects(error.Expired, mesh.decode(&ahead, @splat(42), 0, .loopback));
    try rejects(error.Expired, mesh.decode(&ahead, @splat(42), 35_001, .loopback));
    try rejects(error.WrongRealm, mesh.decode(&card, @splat(43), 1, .loopback));
    const public = mesh.cardBody(.{ .address = .{ 8, 8, 8, 8 }, .port = 45000 });
    _ = try sign(&b, .card, 2, 3, &public, &card);
    try rejects(error.ScopeDenied, mesh.decode(&card, @splat(42), 1, .lan));
    const private = mesh.cardBody(.{ .address = .{ 192, 168, 1, 2 }, .port = 45000 });
    _ = try sign(&b, .card, 2, 4, &private, &card);
    try rejects(error.ScopeDenied, mesh.decode(&card, @splat(42), 1, .loopback));
    _ = try mesh.decode(&card, @splat(42), 1, .lan);
    count += 1;
    var attempts = Core.init(@splat(42), .loopback, a.public_key.toBytes());
    _ = try sign(&b, .card, 1, 1, &body, &card);
    _ = try attempts.learn(&card, 1);
    for (0..5) |i| try check(attempts.candidate(1 + i * 6000) != null);
    try check(attempts.candidate(30_001) == null and attempts.peers[0].exhausted);
    try attempts.retry(b.public_key.toBytes(),30_001);
    try check(!attempts.peers[0].exhausted and attempts.peers[0].attempts==0);
    try rejects(error.ClockRollback, core.learn(&card, 0));
    std.debug.print("Mesh overlay PASS: {d} assertions; bytes/core={d}\n", .{ count, @sizeOf(Core) });
}
