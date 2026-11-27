const std = @import("std");
const history = @import("mesh_history");
const sync = @import("mesh_sync");
const fixture = @import("mesh_test_records.sig");
const Core = history.Journal(2, 4, 8, fixture.Counter);
fn Memory(comptime tag: u8) type {
    return struct {
        pub const identity = tag;
        pub var bytes: [Core.image_capacity]u8 = undefined;
        pub var length: usize = 0;
        pub var mode: enum { normal, before, after } = .normal;
        pub fn load(out: []u8) !?usize {
            if (length == 0) return null;
            @memcpy(out[0..length], bytes[0..length]);
            return length;
        }
        pub fn save(input: []const u8) !void {
            if (mode == .before) return error.InjectedIo;
            @memcpy(bytes[0..input.len], input);
            length = input.len;
            if (mode == .after) return error.InjectedIo;
        }
    };
}
var checks: usize = 0;
test "durable streams, signed snapshots and persistent cursor recovery" {
    try main();
}
test "durable cursor synchronization under lossy schedules" {
    try @import("test_mesh_sync_faults.sig").main();
}
fn check(ok: bool) !void {
    checks += 1;
    if (!ok) return error.HistoryContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |err| try check(err == expected);
}
pub fn main() !void {
    const a = try history.Identity.generateDeterministic(@splat(151));
    const b = try history.Identity.generateDeterministic(@splat(152));
    const stranger = try history.Identity.generateDeterministic(@splat(153));
    const origins = [_]history.Key{ a.public_key.toBytes(), b.public_key.toBytes() };
    const realm: history.Key = @splat(72);
    const A = Core.Durable(Memory(1));
    const B = Core.Durable(Memory(2));
    var source: A = undefined;
    var target: B = undefined;
    try source.init(realm, origins[0], origins, true);
    try target.init(realm, origins[1], origins, true);
    for (0..3) |_| {
        try source.append(&a, &fixture.delta(1));
        const stream = &target.live.streams[0];
        const frame = (try source.live.after(origins[0], stream.cursor, stream.head, false)).?;
        try check(try target.accept(frame) == .changed);
        const generation = target.live.generation;
        try check(try target.accept(frame) == .duplicate);
        try check(target.live.generation == generation);
    }
    try check(history.get(u64, &target.live.streams[0].state) == 3);
    // Force a receiver's proof-retention boundary, then negotiate a checkpoint.
    try source.append(&a, &fixture.delta(1));
    const fourth = (try source.live.after(origins[0], 3, target.live.streams[0].head, false)).?;
    _ = try target.accept(fourth);
    try source.append(&a, &fixture.delta(1));
    try source.append(&a, &fixture.delta(1));
    var client = try sync.Session(B).init(8);
    var server = try sync.Session(A).init(7);
    var request: [sync.capacity]u8 = undefined;
    var reply: [sync.capacity]u8 = undefined;
    var size = try client.request(&target, 1, &request);
    var response = (try server.receive(&source, origins[1], request[0..size], &reply)).?;
    try check((try client.receive(&target, origins[0], reply[0..response], &request)) == null);
    try check(target.live.streams[0].cursor == 4 and client.pending[0].force);
    _ = try client.request(&target, 2, &request);
    size = try client.request(&target, 3, &request);
    try check(request[5] == 3);
    response = (try server.receive(&source, origins[1], request[0..size], &reply)).?;
    var bad = reply;
    bad[8] ^= 1;
    try rejects(error.UnsolicitedReply, client.receive(&target, origins[0], bad[0..response], &request));
    bad = reply;
    bad[80] ^= 128;
    try rejects(error.UnsolicitedReply, client.receive(&target, origins[0], bad[0..response], &request));
    bad = reply;
    bad[72] ^= 1;
    try rejects(error.UnsolicitedReply, client.receive(&target, origins[0], bad[0..response], &request));
    _ = try client.receive(&target, origins[0], reply[0..response], &request);
    try check(target.live.streams[0].cursor == 6 and history.get(u64, &target.live.streams[0].state) == 6 and client.stats.snapshots == 1);
    try rejects(error.UnsolicitedReply, client.receive(&target, origins[0], reply[0..response], &request));
    for (0..6) |_| try source.append(&a, &fixture.delta(1));
    // More history than retention: historical signatures have no transport TTL.
    const checkpoint = (try source.live.after(origins[0], 6, target.live.streams[0].head, false)).?;
    try check((try history.decode(checkpoint, realm)).kind == .snapshot);
    _ = try target.accept(checkpoint);
    try check(target.live.streams[0].cursor == 12 and target.live.streams[0].count == 0);
    const digest = target.live.fingerprint();
    var recovered: B = undefined;
    try recovered.init(realm, origins[1], origins, false);
    try check(std.mem.eql(u8, &digest, &recovered.live.fingerprint()));
    // Invalid signatures, schemas and chain predecessors cannot change a cursor.
    var frame: [history.frame_capacity]u8 = undefined;
    const foreign = try history.encode(&stranger, realm, .event, 1, @splat(0), &fixture.delta(1), &frame);
    try rejects(error.UntrustedWriter, target.accept(frame[0..foreign]));
    const gap = try history.encode(&a, realm, .event, 14, source.live.streams[0].head, &fixture.delta(1), &frame);
    try rejects(error.HistoryGap, target.accept(frame[0..gap]));
    const fork = try history.encode(&a, realm, .event, 13, @splat(9), &fixture.delta(1), &frame);
    try rejects(error.Conflict, target.accept(frame[0..fork]));
    try rejects(error.InvalidCounter, source.append(&a, &fixture.delta(0)));
    for (0..checkpoint.len) |i| {
        var forged: [history.frame_capacity]u8 = undefined;
        @memcpy(forged[0..checkpoint.len], checkpoint);
        forged[i] ^= 1;
        if (target.accept(forged[0..checkpoint.len])) |_| return error.TamperAccepted else |_| checks += 1;
    }
    try check(target.live.streams[0].cursor == 12);
    {
        const W = Core.Durable(Memory(4));
        const R = Core.Durable(Memory(5));
        const C = Core.Durable(Memory(6));
        var writer: W = undefined;
        var relay: R = undefined;
        var reader: C = undefined;
        try writer.init(realm, origins[0], origins, true);
        try relay.init(realm, origins[1], origins, true);
        try reader.init(realm, stranger.public_key.toBytes(), origins, true);
        try writer.append(&a, &fixture.delta(1));
        const anchor = writer.live.streams[0].anchor;
        _ = try relay.accept(anchor.bytes[0..anchor.len]);
        _ = try reader.accept(anchor.bytes[0..anchor.len]);
        try writer.append(&a, &fixture.delta(1));
        const event = (try writer.live.after(origins[0], 1, reader.live.streams[0].head, false)).?;
        _ = try relay.accept(event);
        var reader_sync = try sync.Session(C).init(12);
        reader_sync.pending[0].force = true;
        var relay_sync = try sync.Session(R).init(13);
        var writer_sync = try sync.Session(W).init(14);
        var query: [sync.capacity]u8 = undefined;
        var answer: [sync.capacity]u8 = undefined;
        var ignored: [sync.capacity]u8 = undefined;
        const q = try reader_sync.request(&reader, 0, &query);
        const unavailable = (try relay_sync.receive(&relay, reader.live.owner, query[0..q], &answer)).?;
        try check(answer[5] == 4);
        _ = try reader_sync.receive(&reader, relay.live.owner, answer[0..unavailable], &ignored);
        try check(reader.live.streams[0].cursor == 1 and reader_sync.stats.unavailable == 1 and reader_sync.pending[0].active);
        var replay = answer;
        @memcpy(replay[sync.prefix_size..][0..anchor.len], anchor.bytes[0..anchor.len]);
        replay[5] = 2;
        try rejects(error.UnsolicitedReply, reader_sync.receive(&reader, relay.live.owner, replay[0 .. sync.prefix_size + anchor.len], &ignored));
        try check(reader_sync.pending[0].active);
        const available = (try writer_sync.receive(&writer, reader.live.owner, query[0..q], &answer)).?;
        _ = try reader_sync.receive(&reader, writer.live.owner, answer[0..available], &ignored);
        try check(reader.live.streams[0].cursor == 2);
    }
    // A failed save may have happened before OR after atomic replacement.
    Memory(1).mode = .before;
    try rejects(error.InjectedIo, source.append(&a, &fixture.delta(1)));
    try check(source.poisoned and source.live.streams[0].cursor == 12);
    try rejects(error.Poisoned, source.append(&a, &fixture.delta(1)));
    Memory(1).mode = .normal;
    try source.init(realm, origins[0], origins, false);
    try check(source.live.streams[0].cursor == 12);
    Memory(1).mode = .after;
    try rejects(error.InjectedIo, source.append(&a, &fixture.delta(1)));
    try check(source.poisoned and source.live.streams[0].cursor == 12);
    Memory(1).mode = .normal;
    try source.init(realm, origins[0], origins, false);
    try check(source.live.streams[0].cursor == 13 and history.get(u64, &source.live.streams[0].state) == 13);
    // Verify every damaged image and every truncated prefix fails closed.
    const saved = Memory(1).bytes;
    const length = Memory(1).length;
    for (0..length) |i| {
        Memory(1).bytes = saved;
        Memory(1).bytes[i] ^= 1;
        if (source.init(realm, origins[0], origins, false)) |_| return error.CorruptionAccepted else |_| checks += 1;
        try check(source.poisoned);
    }
    Memory(1).bytes = saved;
    for (1..length) |i| {
        Memory(1).length = i;
        if (source.init(realm, origins[0], origins, false)) |_| return error.TruncationAccepted else |_| checks += 1;
    }
    Memory(1).length = length;
    Memory(1).bytes = saved;
    // Recomputed container checksum cannot hide a fabricated persistent cursor.
    Memory(1).bytes[88 + 32] ^= 1;
    @memcpy(Memory(1).bytes[length - 32 ..][0..32], &history.hash(Memory(1).bytes[0 .. length - 32]));
    if (source.init(realm, origins[0], origins, false)) |_| return error.CursorForgeryAccepted else |_| checks += 1;
    Memory(1).length = 0;
    try rejects(error.MissingJournal, source.init(realm, origins[0], origins, false));
    try rejects(error.Poisoned, source.append(&a, &fixture.delta(1)));
    std.debug.print("Mesh durable history PASS: {d} assertions; image-capacity={d}; gap resync, atomic cursor/state recovery, corruption and save ambiguity\n", .{ checks, Core.image_capacity });
}
