//! Deterministic packet scheduler: real signed overlay frames, simulated transport/time.
const std = @import("std");
const mesh = @import("mesh_overlay");
const nodes = 8;
const Core = mesh.Overlay(8, 32, 8);
var cores: [nodes]Core = undefined;
var keys: [nodes]mesh.Identity = undefined;
var cards: [nodes][mesh.card_size]u8 = undefined;
var records: [nodes][nodes]u64 = undefined;
const Packet = struct { used: bool = false, from: u8 = 0, to: u8 = 0, due: u64 = 0, len: usize = 0, bytes: [mesh.frame_capacity]u8 = undefined };
var packets: [256]Packet = @splat(.{});
var random: u64 = 1;
var checks: usize = 0;
var lost: u64 = 0;
var delivered: u64 = 0;
var duplicates: u64 = 0;
fn next() u64 {
    random ^= random << 13;
    random ^= random >> 7;
    random ^= random << 17;
    return random;
}
fn check(ok: bool) !void {
    checks += 1;
    if (!ok) return error.FaultContractFailed;
}
fn adjacent(a: usize, b: usize) bool {
    return (a + 1) % nodes == b or (b + 1) % nodes == a;
}
fn alive(i: usize, tick: usize) bool {
    return !(i == 3 and tick >= 20 and tick < 40);
}
fn partition(a: usize, b: usize, tick: usize) bool {
    return tick >= 15 and tick < 35 and (a < 4) != (b < 4);
}
fn queue(from: usize, to: usize, bytes: []const u8, now: u64) void {
    if (next() % 4 == 0) {
        lost += 1;
        return;
    }
    for (&packets) |*p| if (!p.used) {
        p.used = true;
        p.from = @intCast(from);
        p.to = @intCast(to);
        p.due = now + next() % 8;
        p.len = bytes.len;
        @memcpy(p.bytes[0..bytes.len], bytes);
        return;
    };
    lost += 1;
}
pub fn main() !void {
    for (&keys, 0..) |*key, i| key.* = try mesh.Identity.generateDeterministic(@splat(@as(u8, @intCast(i + 1))));
    // 128 independently seeded schedules: drops, duplicates, reordering, a
    // network partition and one volatile node restart per schedule.
    for (1..129) |trial| {
        random = trial;
        packets = @splat(.{});
        records = @splat(@splat(0));
        for (&cores, 0..) |*core, i| {
            core.* = Core.init(@splat(55), .loopback, keys[i].public_key.toBytes());
            _ = try mesh.encode(&keys[i], @splat(55), .card, 1, 1, 30_000, &mesh.cardBody(.{ .port = @intCast(46000 + i) }), &cards[i]);
        }
        for (&cores, 0..) |*core, i| for (0..nodes) |j| {
            if (adjacent(i, j)) {
                _ = try core.learn(&cards[j], 1);
                try core.setConnected(keys[j].public_key.toBytes(), true);
            }
        };
        for (0..600) |tick| {
            const now = 1 + @as(u64, @intCast(tick));
            if (tick == 40) {
                cores[3] = Core.init(@splat(55), .loopback, keys[3].public_key.toBytes());
                _ = try mesh.encode(&keys[3], @splat(55), .card, 2, 1, 30_000, &mesh.cardBody(.{ .port = 46003 }), &cards[3]);
            }
            for (&cores, 0..) |*core, i| {
                if (!alive(i, tick)) continue;
                for (0..nodes) |j| {
                    if (!adjacent(i, j)) continue;
                    _ = try core.learn(&cards[j], now);
                    try core.setConnected(keys[j].public_key.toBytes(), alive(j, tick) and !partition(i, j, tick));
                    // Membership propagates independently of data and is always signed.
                    if (alive(j, tick) and !partition(i, j, tick) and tick % 8 == 0) {
                        for (core.peers) |member| if (member.used) {
                            _ = cores[j].learn(member.card[0..member.card_len], now) catch continue;
                        };
                    }
                }
                if (tick == 0 or tick == 45 or tick == 60) {
                    var body: [9]u8 = undefined;
                    body[0] = @intCast(i);
                    const version: u64 = if (tick == 0) 1 else if (tick == 45) 2 else 3;
                    mesh.put(u64, body[1..], version);
                    records[i][i] = version;
                    var frame: [mesh.frame_capacity]u8 = undefined;
                    const size = try mesh.encode(&keys[i], @splat(55), .data, if (i == 3 and tick >= 40) 2 else 1, version + 1, 30_000, &body, &frame);
                    try core.retainOwn(frame[0..size], now);
                }
                for (0..nodes) |j| if (adjacent(i, j) and alive(j, tick) and !partition(i, j, tick)) {
                    const frame = &core.cache[(tick + i) % 32];
                    if (frame.len != 0) {
                        queue(i, j, frame.bytes[0..frame.len], now);
                        if (next() % 5 == 0) {
                            queue(i, j, frame.bytes[0..frame.len], now);
                            duplicates += 1;
                        }
                    }
                };
            }
            for (&packets) |*p| {
                if (!p.used or p.due > now) continue;
                p.used = false;
                if (!alive(p.to, tick) or !alive(p.from, tick) or partition(p.from, p.to, tick)) continue;
                cores[p.to].receive(keys[p.from].public_key.toBytes(), p.bytes[0..p.len], now) catch continue;
                delivered += 1;
            }
            for (&cores, 0..) |*core, i| {
                if (!alive(i, tick)) continue;
                while (core.poll()) |bytes| {
                    const view = try mesh.decode(bytes, @splat(55), now, .loopback);
                    const origin = view.body[0];
                    try check(std.mem.eql(u8, &view.origin, &keys[origin].public_key.toBytes()));
                    records[i][origin] = @max(records[i][origin], mesh.get(u64, view.body[1..9]));
                }
            }
        }
        for (records, 0..) |row, node| for (row, 0..) |version, origin| {
            if (version != 3) std.debug.print("trial={d} node={d} origin={d} observed={d}\n", .{ trial, node, origin, version });
            try check(version == 3);
        };
    }
    std.debug.print("Mesh faults PASS: {d} assertions; trials=128 nodes=8 delivered={d} lost={d} duplicate-injections={d} bounded-bytes={d}\n", .{ checks, delivered, lost, duplicates, @sizeOf(@TypeOf(cores)) + @sizeOf(@TypeOf(packets)) });
}
