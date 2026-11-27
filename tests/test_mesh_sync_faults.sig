//! Real durable/sync code over a deterministic lossy authenticated-channel model.
const std = @import("std");
const history = @import("mesh_history");
const sync = @import("mesh_sync");
const fixture = @import("mesh_test_records.sig");
const Core = history.Journal(2, 2, 8, fixture.Counter);
const Backend = struct {
    pub var selected: usize = 0;
    pub var lengths: [2]usize = @splat(0);
    pub var files: [2][Core.image_capacity]u8 = undefined;
    pub var fault: enum { none, before, after } = .none;
    pub fn load(out: []u8) !?usize {
        const size = lengths[selected];
        if (size == 0) return null;
        @memcpy(out[0..size], files[selected][0..size]);
        return size;
    }
    pub fn save(bytes: []const u8) !void {
        if (fault == .before) return error.InjectedIo;
        @memcpy(files[selected][0..bytes.len], bytes);
        lengths[selected] = bytes.len;
        if (fault == .after) return error.InjectedIo;
    }
};
const Durable = Core.Durable(Backend);
const Session = sync.Session(Durable);
var stores: [2]Durable = undefined;
var sessions: [2]Session = undefined;
const Packet = struct { used: bool = false, from: usize = 0, to: usize = 0, created: u64 = 0, due: u64 = 0, len: usize = 0, body: [sync.capacity]u8 = undefined };
var packets: [64]Packet = @splat(.{});
var rng: u64 = 1;
var checks: usize = 0;
var drops: usize = 0;
var snapshots: u64 = 0;
fn random() u64 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
fn check(ok: bool) !void {
    checks += 1;
    if (!ok) return error.SyncFaultContractFailed;
}
fn queue(from: usize, to: usize, body: []const u8, tick: u64) void {
    if (random() % 10 < 3) {
        drops += 1;
        return;
    }
    for (&packets) |*packet| if (!packet.used) {
        packet.* = .{};
        packet.used = true;
        packet.from = from;
        packet.to = to;
        packet.created = tick;
        packet.due = tick + random() % 7;
        packet.len = body.len;
        @memcpy(packet.body[0..body.len], body);
        return;
    };
    drops += 1;
}
pub fn main() !void {
    const keys = [_]history.Identity{ try history.Identity.generateDeterministic(@splat(151)), try history.Identity.generateDeterministic(@splat(152)) };
    const origins = [_]history.Key{ keys[0].public_key.toBytes(), keys[1].public_key.toBytes() };
    for (1..129) |trial| {
        rng = trial;
        packets = @splat(.{});
        Backend.lengths = @splat(0);
        Backend.fault = .none;
        for (&stores, 0..) |*store, i| {
            Backend.selected = i;
            try store.init(@splat(72), origins[i], origins, true);
            sessions[i] = try Session.init(1);
        }
        var injected = false;
        var requests: [sync.capacity]u8 = undefined;
        var response: [sync.capacity]u8 = undefined;
        for (0..260) |tick| {
            if (tick == 80) {
                Backend.selected = 1;
                try stores[1].init(@splat(72), origins[1], origins, false);
                sessions[1] = try Session.init(2);
            }
            for (0..2) |node| {
                if (node == 1 and tick >= 10 and tick < 80) continue;
                Backend.selected = node;
                if (tick % 2 == 0 and history.get(u64, &stores[node].live.streams[node].state) < 12) {
                    if (node == 0 and tick == 6 and !injected) {
                        Backend.fault = if (trial % 2 == 0) .before else .after;
                        injected = true;
                    }
                    stores[node].append(&keys[node], &fixture.delta(1)) catch |err| {
                        try check(err == error.InjectedIo and stores[node].poisoned);
                        Backend.fault = .none;
                        try stores[node].init(@splat(72), origins[node], origins, false);
                    };
                    Backend.fault = .none;
                }
                if (tick % 3 == 0) {
                    const n = try sessions[node].request(&stores[node], @as(u64, @intCast(tick)) * 1000, &requests);
                    queue(node, 1 - node, requests[0..n], tick);
                    if (random() % 5 == 0) queue(node, 1 - node, requests[0..n], tick);
                }
            }
            for (&packets) |*packet| {
                if (!packet.used or packet.due > tick) continue;
                const sender = packet.from;
                const receiver = packet.to;
                packet.used = false;
                if ((packet.to == 1 and tick >= 10 and tick < 80) or tick - packet.created >= 30) {
                    drops += 1;
                    continue;
                }
                Backend.selected = packet.to;
                const before = stores[packet.to].live.fingerprint();
                const reply = sessions[packet.to].receive(&stores[packet.to], origins[packet.from], packet.body[0..packet.len], &response) catch |err| {
                    try check(err == error.UnsolicitedReply or err == error.BadSignature or err == error.InvalidFrame);
                    try check(std.mem.eql(u8, &before, &stores[packet.to].live.fingerprint()));
                    continue;
                };
                if (reply) |n| {
                    queue(receiver, sender, response[0..n], tick);
                    if (random() % 5 == 0) queue(receiver, sender, response[0..n], tick);
                }
            }
        }
        for (&stores) |*store| for (store.live.streams) |stream| try check(stream.cursor == 12 and history.get(u64, &stream.state) == 12);
        try check(std.mem.eql(u8, &stores[0].live.fingerprint(), &stores[1].live.fingerprint()));
        for (sessions) |session| snapshots += session.stats.snapshots;
    }
    try check(drops > 0 and snapshots > 0);
    std.debug.print("Mesh sync faults PASS: {d} assertions; schedules=128 lost={d} snapshots={d} outage=70 simulated seconds; duplicate/reorder/restart and before/after-commit faults\n", .{ checks, drops, snapshots });
}
