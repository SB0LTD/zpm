//! Synthetic infrastructure participant. Public deterministic identities, loopback only.
const std = @import("std");
const builtin = @import("builtin");
const mesh = @import("mesh_overlay");
const network = @import("mesh_network");
const w = @import("win32");
const Net = network.Network(16, 4, 32);
var storage: Net.Storage = undefined;
var service: Net = undefined;
var identity: mesh.Identity = undefined;
fn option(init: std.process.Init, comptime name: []const u8, default: u64) !u64 {
    if (builtin.os.tag == .windows) {
        const marker = std.unicode.utf8ToUtf16LeStringLiteral("--" ++ name ++ "=");
        if (std.mem.indexOf(u16, init.minimal.args.vector, marker)) |start| {
            var value: u64 = 0;
            var found = false;
            for (init.minimal.args.vector[start + marker.len ..]) |digit| {
                if (digit < '0' or digit > '9') break;
                found = true;
                value = try std.math.mul(u64, value, 10);
                value = try std.math.add(u64, value, digit - '0');
            }
            if (!found) return error.BadArgument;
            return value;
        }
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        while (args.next()) |arg| if (std.mem.startsWith(u8, arg, "--" ++ name ++ "=")) return std.fmt.parseInt(u64, arg[name.len + 3 ..], 10);
    }
    return default;
}
fn nowMs() u64 {
    if (builtin.os.tag == .windows) {
        var value: w.FILETIME = .{};
        w.GetSystemTimeAsFileTime(&value);
        const ticks = (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
        return ticks / 10000 - 11644473600000;
    } else {
        var time: std.os.linux.timespec = undefined;
        _ = std.os.linux.syscall2(.clock_gettime, 0, @intFromPtr(&time));
        return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1000000;
    }
}
pub fn main(init: std.process.Init) !void {
    const id = try option(init, "id", 0);
    const epoch = try option(init, "epoch", 0);
    const base = try option(init, "base", 47200);
    const count = try option(init, "count", 4);
    const seconds = try option(init, "seconds", 30);
    if (id >= count or count < 2 or count > 8 or epoch == 0 or base < 1024 or base + count > 65535 or seconds < 10 or seconds > 300) return error.BadArgument;
    identity = try mesh.Identity.generateDeterministic(@splat(@as(u8, @intCast(id + 101))));
    var seeds = [_]mesh.Endpoint{.{ .port = @intCast(base) }};
    const start = nowMs();
    try service.init(&storage, .{ .realm = @splat(71), .identity = &identity, .epoch = epoch, .endpoint = .{ .port = @intCast(base + id) }, .seeds = if (id == 0) &.{} else &seeds }, start);
    defer service.stop();
    var latest: [8]u64 = @splat(0);
    var next_publish: u64 = 0;
    var last_hash: [32]u8 = @splat(0);
    var last_links: usize = 99;
    std.debug.print("LAB start id={d} epoch={d} storage={d}\n", .{ id, epoch, @sizeOf(Net.Storage) + @sizeOf(Net) });
    while (nowMs() - start < seconds * 1000) {
        const now = nowMs();
        try service.tick(now);
        if (now >= next_publish) {
            var payload: [9]u8 = undefined;
            payload[0] = @intCast(id);
            const revision: u64 = if (now - start >= 10_000) 3 else 2;
            mesh.put(u64, payload[1..], revision);
            try service.broadcast(&payload, now);
            latest[id] = revision;
            next_publish = now + 5000;
        }
        while (service.poll()) |bytes| {
            const view = try mesh.decode(bytes, @splat(71), now, .loopback);
            if (view.body.len != 9 or view.body[0] >= count) continue;
            const sender = view.body[0];
            const expected = try mesh.Identity.generateDeterministic(@splat(sender + 101));
            if (!std.mem.eql(u8, &view.origin, &expected.public_key.toBytes())) continue;
            latest[sender] = @max(latest[sender], mesh.get(u64, view.body[1..9]));
        }
        var canonical: [64]u8 = @splat(0);
        for (latest, 0..) |value, i| mesh.put(u64, canonical[i * 8 ..][0..8], value);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical[0 .. count * 8], &hash, .{});
        const links = service.connectedCount();
        if (!std.mem.eql(u8, &hash, &last_hash) or links != last_links) {
            var complete = true;
            var known = true;
            for (latest[0..count]) |value| {
                if (value != 3) complete = false;
                if (value < 2) known = false;
            }
            std.debug.print("LAB view id={d} links={d} elapsed={d} known={} complete={} state={x}\n", .{ id, links, now - start, known, complete, hash });
            last_hash = hash;
            last_links = links;
        }
        w.Sleep(1);
    }
    var complete = true;
    for (latest[0..count]) |value| {
        if (value != 3) complete = false;
    }
    std.debug.print("LAB end id={d} complete={} sent={d} received={d} dropped={d} reconnects={d}\n", .{ id, complete, service.bytes_sent, service.bytes_received, service.dropped, service.reconnects });
    if (!complete) return error.NotConverged;
}
