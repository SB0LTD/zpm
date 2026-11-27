//! Durable synthetic counter streams over the real multi-peer QUIC service.
const std = @import("std");
const overlay = @import("mesh_overlay");
const network = @import("mesh_network");
const history = @import("mesh_history");
const sync = @import("mesh_sync");
const file = @import("mesh_file");
const records = @import("mesh_test_records");
const support = @import("mesh_lab_support");
const fixed = @import("fixed_journal");
const w = @import("win32");
const Net = network.NetworkWithBudget(16, 4, 32, @import("streams").mobile_budget);
const Core = history.Journal(4, 4, 8, records.Counter);
const Durable = Core.Durable(file.File("node-history.bin"));
var storage: Net.Storage = undefined;
var service: Net = undefined;
var store: Durable = undefined;
var identity: history.Identity = undefined;
pub fn main(init: std.process.Init) !void {
    const id = try support.option(init, "id", 0);
    const epoch = try support.option(init, "epoch", 0);
    const base = try support.option(init, "base", 47300);
    const seconds = try support.option(init, "seconds", 120);
    const create = try support.option(init, "create", 0) != 0;
    if (id >= 4 or epoch == 0 or base < 1024 or base + 4 > 65535 or seconds < 10 or seconds > 600) return error.BadArgument;
    identity = try history.Identity.generateDeterministic(@splat(@as(u8, @intCast(id + 151))));
    var origins: [4]history.Key = undefined;
    for (&origins, 0..) |*key, i| {
        const writer = try history.Identity.generateDeterministic(@splat(@as(u8, @intCast(i + 151))));
        key.* = writer.public_key.toBytes();
    }
    try store.init(@splat(72), identity.public_key.toBytes(), origins, create);
    std.debug.print("HISTORY start id={d} epoch={d} durable-generation={d} own-cursor={d}\n", .{ id, epoch, store.live.generation, store.live.streams[id].cursor });
    var session = try sync.Session(Durable).init(epoch);
    // IPv4 values use network-order notation (e.g. 192.168.1.2 = 3232235778).
    // Explicit LAN mode is fixture-only; public addresses remain rejected.
    const local_ip = try support.option(init, "address", 2130706433);
    const seed_ip = try support.option(init, "seed", 2130706433);
    const lan = try support.option(init, "lan", 0) != 0;
    const scope: overlay.Scope = if (lan) .lan else .loopback;
    if (local_ip > 0xffffffff or seed_ip > 0xffffffff) return error.BadArgument;
    const address = ipv4(@intCast(local_ip));
    var seeds = [_]overlay.Endpoint{.{ .address = ipv4(@intCast(seed_ip)), .port = @intCast(base) }};
    const start = support.nowMs();
    try service.init(&storage, .{ .realm = @splat(72), .identity = &identity, .epoch = epoch, .endpoint = .{ .address = address, .port = @intCast(base + id) }, .scope = scope, .seeds = if (id == 0) &.{} else &seeds }, start);
    defer service.stop();
    std.debug.print("HISTORY memory budget={d} default={d} stream-slots=4 buffer-bytes=16384\n", .{ @sizeOf(Net) + @sizeOf(Net.Storage), @sizeOf(network.Network(16, 4, 32)) + @sizeOf(network.Network(16, 4, 32).Storage) });
    var next_diagnostic: u64 = 0;
    var next_request: u64 = 0;
    var next_command: u64 = 0;
    var last_hash: history.Key = @splat(0);
    var last_links: usize = 99;
    var input: [sync.capacity]u8 = undefined;
    var output: [sync.capacity]u8 = undefined;
    var command: [1]u8 = undefined;
    while (support.nowMs() - start < seconds * 1000) {
        const now = support.nowMs();
        try service.tick(now);
        if (now >= next_diagnostic) {
            std.debug.print("HISTORY network id={d} now={d} sent={d} received={d} dropped={d} reconnects={d}\n", .{ id, now, service.bytes_sent, service.bytes_received, service.dropped, service.reconnects });
            next_diagnostic = now + 5000;
        }
        if (now >= next_command) {
            if (try fixed.load("command.bin", &command)) |size| {
                if (size != 1 or command[0] > 64) return error.BadCommand;
                if (history.get(u64, &store.live.streams[id].state) < command[0]) try store.append(&identity, &records.delta(1));
            }
            next_command = now + 100;
        }
        if (now >= next_request) {
            const size = try session.request(&store, now, &input);
            try service.broadcast(input[0..size], now);
            next_request = now + 250;
        }
        while (service.poll()) |envelope| {
            const view = overlay.decode(envelope, @splat(72), now, scope) catch continue;
            if (session.receive(&store, view.origin, view.body, &output)) |response| {
                if (response) |size| try service.broadcast(output[0..size], now);
            } else |err| switch (err) {
                error.UnsolicitedReply, error.Conflict, error.InvalidMessage, error.UntrustedWriter => {},
                else => return err,
            }
        }
        const hash = store.live.fingerprint();
        const links = service.connectedCount();
        if (!std.mem.eql(u8, &hash, &last_hash) or links != last_links) {
            std.debug.print("HISTORY view id={d} links={d} elapsed={d} state={x} cursors={d},{d},{d},{d} values={d},{d},{d},{d} snapshots={d} events={d} gaps={d}\n", .{ id, links, now - start, hash, store.live.streams[0].cursor, store.live.streams[1].cursor, store.live.streams[2].cursor, store.live.streams[3].cursor, history.get(u64, &store.live.streams[0].state), history.get(u64, &store.live.streams[1].state), history.get(u64, &store.live.streams[2].state), history.get(u64, &store.live.streams[3].state), session.stats.snapshots, session.stats.events, session.stats.gaps });
            last_hash = hash;
            last_links = links;
        }
        w.Sleep(1);
    }
}

fn ipv4(value: u32) [4]u8 {
    return .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}
