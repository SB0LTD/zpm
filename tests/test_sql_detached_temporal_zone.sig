//! Detached routing must retain the serialized resolver for textual inputs.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{
    .external_storage = true, .external_workspace = true, .external_results = true,
    .tables = 1, .columns = 8, .rows_per_table = 2, .text_bytes = 256,
    .work_rows = 32, .result_rows = 4,
});
var db: DB = .{};
var storage: [DB.backingBytes(8, 16, 1024) catch unreachable]u8 align(16) = undefined;
var workspace: [DB.queryWorkspaceBytes(32) catch unreachable]u8 align(16) = undefined;
var read_workspace: [DB.ReadContext.backingBytes(32) catch unreachable]u8 align(16) = undefined;
var context: DB.ReadContext = .{};
var read_result: DB.Result = .{};
var serial_result: DB.Result = .{};
var read_rows: [4 * @sizeOf(DB.Row)]u8 align(16) = undefined;
var serial_rows: [4 * @sizeOf(DB.Row)]u8 align(16) = undefined;
var resolved: usize = 0;

fn resolve(_: ?*anyopaque, name: []const u8, zone: *sql.Zone) sql.Error!void {
    if (!std.mem.eql(u8, name, "Test/Plus2")) return error.InvalidParameterValue;
    resolved += 1;
    zone.* = .{ .kind = .fixed, .offset = 7200 };
}

fn checkRoute(source: []const u8, wants_resolver: bool) !void {
    try context.prepare(&db, source, .{ .csn = db.csn });
    if (context.needsZoneResolver() != wants_resolver) {
        std.debug.print("wrong resolver route: {s}\n", .{source});
        return error.TemporalResolverRoute;
    }
}

fn expectSerialized(source: []const u8, expected: DB.Cell) !void {
    try checkRoute(source, true);
    const before = resolved;
    try db.execute(source, &serial_result);
    try std.testing.expect(resolved > before);
    try std.testing.expectEqual(@as(usize, 1), serial_result.row_count);
    try std.testing.expect(DB.compareCells(&serial_result.rows[0].cells[0], &expected) == 0);
}

fn expectDetached(source: []const u8) !void {
    try checkRoute(source, false);
    try context.run(&read_result);
    try db.execute(source, &serial_result);
    try std.testing.expectEqual(@as(usize, 1), read_result.row_count);
    try std.testing.expect(DB.compareCells(&read_result.rows[0].cells[0], &serial_result.rows[0].cells[0]) == 0);
}

pub fn main() !void {
    try db.bindMemory(&storage, 8, 16, 1024);
    try db.bindWorkspaceMemory(&workspace, 32);
    try context.bindMemory(&read_workspace, 32);
    try read_result.bindMemory(&read_rows, 4);
    try serial_result.bindMemory(&serial_rows, 4);
    db.session.resolver = .{ .lookup = &resolve };
    try db.execute("CREATE TABLE datetimes (id INT PRIMARY KEY, v VARCHAR, c CHAR(48), a TEXT[], r TEXT, s TIMESTAMP, z TIMESTAMPTZ, t TIMESTAMP[])", &serial_result);
    try db.execute(
        "INSERT INTO datetimes VALUES (1,'2000-01-15 12:00:00 Test/Plus2','2000-01-15 12:00:00 Test/Plus2'," ++
        "ARRAY['2000-01-15 12:00:00 Test/Plus2'::text]," ++
        "'[\"2000-01-15 12:00:00 Test/Plus2\",\"2000-01-15 13:00:00 Test/Plus2\")'," ++
        "'2000-01-15 12:00:00','2000-01-15 10:00:00+00',ARRAY[TIMESTAMP '2000-01-15 12:00:00'])", &serial_result);

    const hour = 3600000000;
    const midnight = @as(i64, sql.temporal.dateOf(2000, 1, 15)) * 24 * hour;
    const zoned: DB.Cell = .{ .timestamptz = midnight + 10 * hour };
    const local: DB.Cell = .{ .timestamp = midnight + 12 * hour };
    try expectSerialized("SELECT v::timestamptz FROM datetimes", zoned);
    try expectSerialized("SELECT c::timestamp FROM datetimes", local);
    try expectSerialized("SELECT (SELECT dt.v::timestamptz) FROM datetimes dt", zoned);
    try expectSerialized("SELECT (a::timestamptz[])[1] FROM datetimes", zoned);
    try expectSerialized("SELECT lower(r::tstzrange) FROM datetimes", zoned);
    try expectSerialized("SELECT v::timetz FROM datetimes", .{ .timetz = .{ .us = 12 * hour, .zone = -7200 } });
    try expectSerialized(
        "SELECT v FROM JSON_TABLE('\"2000-01-15 12:00:00 Test/Plus2\"', '$' COLUMNS (v TIMESTAMPTZ PATH '$')) AS jt",
        zoned);
    try checkRoute("SELECT TIMETZ '12:00+02'", true);
    try checkRoute("SELECT s AT TIME ZONE 'UTC' FROM datetimes", true);
    try expectDetached("SELECT s::timestamptz FROM datetimes");
    try expectDetached("SELECT z::timestamp FROM datetimes");
    try expectDetached("SELECT z::time FROM datetimes");
    try expectDetached("SELECT (t::timestamptz[])[1] FROM datetimes");
    try expectDetached("SELECT to_timestamp(0)");
    try expectDetached("SELECT v FROM JSON_TABLE('1', '$' COLUMNS (v INT PATH '$')) AS jt");
    std.debug.print("PASS detached temporal resolver eligibility and typed conversions\n", .{});
}
