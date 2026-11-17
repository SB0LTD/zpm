const std = @import("std");
const sql = @import("sql");
const registry = @import("database_registry");
const TestStore = struct { value: u32 };
const Registry = registry.Registry(TestStore, 12);

fn ownerOnly(_: ?*anyopaque, principal: u32, db: Registry.Metadata) bool {
    return principal == db.owner;
}

fn admit(principal: u32) Registry.Admission {
    return .{ .principal = principal, .allowed = &ownerOnly };
}

fn clusterGrammar() !void {
    const Raw = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 2 });
    try std.testing.expectEqualStrings("mydb", (try Raw.parseDatabaseCommand("/* owned */ CREATE DATABASE MyDB;", .{})).?.create.slice());
    const drop = (try Raw.parseDatabaseCommand("DROP DATABASE IF EXISTS \"Two\"\"Words\"", .{})).?.drop;
    try std.testing.expect(drop.if_exists);
    try std.testing.expectEqualStrings("Two\"Words", drop.name.slice());
    try std.testing.expect((try Raw.parseDatabaseCommand("DROP TABLE data", .{})) == null);
    try std.testing.expect((try Raw.parseDatabaseCommand("CREATE DATABASE alpha", .{ .dialect = .mysql })) == null);
    try std.testing.expect((try Raw.parseDatabaseCommand("CREATE DATABASE alpha", .{ .mode = .legacy_alpha })) == null);
    try std.testing.expectError(error.Syntax, Raw.parseDatabaseCommand("CREATE DATABASE alpha; SELECT 1", .{}));
    try std.testing.expectError(error.Syntax, Raw.parseDatabaseCommand("DROP DATABASE IF alpha", .{}));
    try std.testing.expectError(error.UnsupportedStatement, Raw.parseDatabaseCommand("CREATE DATABASE alpha OWNER bob", .{}));
}

pub fn main() !void {
    try clusterGrammar();
    var entries: [2]Registry.Entry = undefined;
    var tokens: [2]Registry.LeaseEntry = undefined;
    var cluster = Registry.init(&entries, &tokens);
    var alpha: TestStore = .{ .value = 10 };
    var beta: TestStore = .{ .value = 20 };
    const old = try cluster.reserve("alpha", 5, 10);
    try std.testing.expect(cluster.lookup("alpha") == null);
    try std.testing.expectError(error.AdmissionDenied, cluster.attach("alpha", admit(0)));
    try std.testing.expectError(error.DatabaseNotFound, cluster.attach("alpha", admit(10)));
    try std.testing.expectError(error.DuplicateDatabase, cluster.reserve("alpha", 6, 10));
    try std.testing.expectError(error.StoreNotStaged, cluster.publish(old));
    try cluster.stageStore(old, &alpha);
    try std.testing.expect(cluster.lookup("alpha") == null);
    try cluster.publish(old);
    const other = try cluster.reserve("beta", 6, 11);
    try std.testing.expectError(error.StoreAlreadyRegistered, cluster.stageStore(other, &alpha));
    try cluster.stageStore(other, &beta);
    try cluster.publish(other);
    try std.testing.expectEqual(@as(u32, 5), cluster.lookup("alpha").?.oid);
    try std.testing.expectError(error.AdmissionDenied, cluster.attach("alpha", admit(11)));
    const first = try cluster.attach("alpha", admit(10));
    const second = try cluster.attach("beta", admit(11));
    try std.testing.expectEqual(@as(u32, 10), first.store.value);
    try std.testing.expectEqual(@as(u32, 20), second.store.value);
    try std.testing.expectError(error.DatabaseBusy, cluster.beginDrop(old));
    try std.testing.expectError(error.LeaseCapacity, cluster.attach("alpha", admit(10)));
    try cluster.release(first.lease);
    const replacement = try cluster.attach("alpha", admit(10));
    try std.testing.expectError(error.StaleLease, cluster.release(first.lease));
    try std.testing.expectError(error.DatabaseBusy, cluster.beginDrop(old));
    try cluster.release(replacement.lease);
    try cluster.beginDrop(old);
    try std.testing.expect(cluster.lookup("alpha") == null);
    try std.testing.expectError(error.DatabaseNotFound, cluster.attach("alpha", admit(10)));
    try cluster.cancelDrop(old);
    try std.testing.expectEqual(@as(u32, 5), cluster.lookup("alpha").?.oid);
    try cluster.beginDrop(old);
    try std.testing.expectEqual(&alpha, try cluster.finishDrop(old));
    try std.testing.expectError(error.StaleDatabase, cluster.finishDrop(old));
    try std.testing.expectError(error.InvalidDatabaseIdentity, cluster.reserve("alpha", 5, 10));
    const newer = try cluster.reserve("alpha", 7, 10);
    try std.testing.expect(old.index == newer.index and old.generation != newer.generation);
    try std.testing.expectError(error.StaleDatabase, cluster.stageStore(old, &alpha));
    try cluster.stageStore(newer, &alpha);
    try std.testing.expectEqual(&alpha, (try cluster.abortReservation(newer)).?);
    try std.testing.expectError(error.InvalidDatabaseIdentity, cluster.reserve("alpha", 7, 10));
    try std.testing.expectError(error.InvalidDatabaseName, cluster.reserve("bad\x00name", 8, 10));
    try std.testing.expectError(error.InvalidDatabaseName, cluster.reserve("bad\xff", 8, 10));
    try cluster.release(second.lease);
    std.debug.print("PASS database registry: route, ownership, quiescence and stale handles\n", .{});
}
