//! PostgreSQL enum catalog DDL, visibility, recovery and wire contracts.
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const DB = sql.Database(.{ .tables = 4, .columns = 8, .rows_per_table = 8, .work_rows = 512, .name_bytes = 64, .text_bytes = 128, .transactions = 4 });
const Store = @import("db_store").Store(DB);
const Session = pg.Session(Store.Connection);

var primary: DB = .{};
var restored: DB = .{};
var scratch: DB.ReplayScratch = .{};
var result: DB.Result = .{};
var store: Store = .{};
var response: [Session.responseCapacity()]u8 = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("enum contract assertion {d} failed\n", .{assertions});
        return error.EnumContractFailed;
    }
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn rejects(db: *DB, source: []const u8, wanted: anyerror) !void {
    db.execute(source, &result) catch |err| {
        if (err != wanted) {
            std.debug.print("{s}: expected {s}, got {s}\n", .{ source, @errorName(wanted), @errorName(err) });
            return err;
        }
        return check(true);
    };
    return error.ExpectedEnumError;
}

fn durable(source: []const u8) !void {
    var record: [4096]u8 = undefined;
    var used: usize = 0;
    try primary.executeChanges(source, &result, &record, &used, null, null);
    try restored.applyChangeRecord(record[0..used], &scratch);
}

fn catalog(db: *DB) ![4]i64 {
    try db.execute("SELECT oid,typarray,typowner,typnamespace,typlen,typcategory FROM pg_type WHERE typname='Mood' AND typtype='e'", &result);
    try check(result.row_count == 1 and result.rows[0].cells[4].integer == 4 and equal(result.rows[0].cells[5].text.slice(), "E"));
    const fields = &result.rows[0].cells;
    const identity = [4]i64{ fields[0].integer, fields[1].integer, fields[2].integer, fields[3].integer };
    try check(identity[0] >= sql.change_records.first_oid and identity[1] > identity[0] and identity[2] != 10 and identity[3] != 2200);
    const labels = [_][]const u8{ "z", " A ", "a", "A", "", "a'b", "\t" };
    try db.execute("SELECT oid,enumtypid,enumsortorder,enumlabel FROM pg_catalog.pg_enum ORDER BY enumsortorder", &result);
    try check(result.row_count == labels.len and result.column_types[2] == .real and result.column_types[3] == .name);
    for (labels, result.rows[0..labels.len], 1..) |label, *row, rank| {
        try check(row.cells[0].integer == identity[1] + @as(i64, @intCast(rank)));
        try check(row.cells[1].integer == identity[0] and row.cells[2].float4 == @as(f32, @floatFromInt(rank)));
        try check(equal(row.cells[3].text.slice(), label));
    }
    try db.execute("SELECT oid,typelem FROM pg_type WHERE typname='_Mood' AND typcategory='A'", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == identity[1] and result.rows[0].cells[1].integer == identity[0]);
    return identity;
}

fn rejectRecord(record: []const u8, wanted: anyerror) !void {
    const before_csn = restored.csn;
    const before_oid = restored.oid_counter;
    if (restored.applyChangeRecord(record, &scratch)) |_| return error.InvalidEnumRecordAccepted else |err| try check(err == wanted);
    try check(restored.csn == before_csn and restored.oid_counter == before_oid);
}

fn corruptRecords(existing_label_oid: u32) !void {
    var record: [4096]u8 = undefined;
    var used: usize = 0;
    try primary.executeChanges("CREATE TYPE second AS ENUM ('label')", &result, &record, &used, null, null);
    const version = used - 3;
    const label_start = version - 2 - "label".len;
    try check(record[version] == 1 and record[version+1] == 1);
    record[version] = 99;
    try rejectRecord(record[0..used], error.UnsupportedLogVersion);
    record[version] = 1;
    record[version+1] = 2;
    try rejectRecord(record[0..used], error.InvalidChangeRecord);
    record[version+1] = 1;
    record[label_start] = 0;
    try rejectRecord(record[0..used], error.InvalidChangeRecord);
    record[label_start] = 'l';
    const oid_offset = sql.change_records.header_size + 2;
    const original = record[oid_offset..][0..4].*;
    for (0..4) |i| record[oid_offset+i] = @truncate(existing_label_oid >> @intCast(i * 8));
    try rejectRecord(record[0..used], error.ChangeRecordConflict);
    record[oid_offset..][0..4].* = original;
    try restored.applyChangeRecord(record[0..used], &scratch);
    try durable("DROP TYPE second");
}

fn sqlContracts() !void {
    try durable("CREATE SCHEMA enums");
    try durable("CREATE ROLE enumowner SUPERUSER");
    try durable("CREATE DOMAIN old_domain AS INT CHECK (VALUE > 0)");
    try primary.execute("SET ROLE enumowner", &result);
    try durable("CREATE TYPE enums.\"Mood\" AS ENUM ('z', ' A ', 'a', 'A', '', 'a''b', E'\\t')");
    try check(result.command == .create_type);
    try primary.execute("RESET ROLE", &result);
    const original = try catalog(&primary);
    const replayed = try catalog(&restored);
    try check(std.mem.eql(i64, &original, &replayed));
    try check(primary.oid_counter == restored.oid_counter);
    try corruptRecords(@intCast(original[1] + 2));
    try check(std.mem.eql(i64, &original, &(try catalog(&restored))));

    try rejects(&primary, "CREATE TYPE duplicates AS ENUM ('x', 'x')", error.PrimaryKeyViolation);
    try rejects(&primary, "CREATE TYPE too_long AS ENUM ('0123456789012345678901234567890123456789012345678901234567890123')", error.InvalidName);
    try rejects(&primary, "CREATE TYPE enums.\"Mood\" AS ENUM ('q')", error.DuplicateObject);
    try rejects(&primary, "CREATE DOMAIN enums.\"Mood\" AS INT", error.DuplicateObject);
    try rejects(&primary, "CREATE TYPE old_domain AS ENUM ('q')", error.DuplicateObject);
    try rejects(&primary, "CREATE TABLE enums.\"Mood\" (i INTEGER)", error.DuplicateObject);
    try rejects(&primary, "CREATE TABLE unsupported (e enums.\"Mood\")", error.UnsupportedStatement);
    try rejects(&primary, "SELECT 'z'::enums.\"Mood\"", error.UnsupportedStatement);
    try rejects(&primary, "ALTER TYPE enums.\"Mood\" ADD VALUE 'q'", error.UnsupportedStatement);
    try rejects(&primary, "CREATE TYPE composites AS (a integer)", error.UnsupportedStatement);
    try rejects(&primary, "DROP DOMAIN enums.\"Mood\"", error.WrongObjectType);
    try rejects(&primary, "DROP ROLE enumowner", error.DependentObjects);
    try rejects(&primary, "DROP SCHEMA enums RESTRICT", error.DependentObjects);
    try restored.execute("SELECT 2::old_domain", &result);
    try check(result.rows[0].cells[0].integer == 2);

    const slot = try primary.begin();
    try primary.statement(slot, "CREATE TYPE transient AS ENUM ('only self')", &result, .{});
    const visibility = "SELECT enumlabel FROM pg_enum WHERE enumlabel='only self'";
    try primary.statement(slot, visibility, &result, .{});
    try check(result.row_count == 1);
    try primary.execute(visibility, &result);
    try check(result.row_count == 0);
    primary.abort(slot);
    try primary.execute(visibility, &result);
    try check(result.row_count == 0);

    const drop = try primary.begin();
    try primary.statement(drop, "DROP TYPE enums.\"Mood\"", &result, .{});
    try primary.statement(drop, "SELECT enumlabel FROM pg_enum", &result, .{});
    try check(result.row_count == 0);
    _ = try catalog(&primary);
    primary.abort(drop);
    _ = try catalog(&primary);

    try durable("CREATE TYPE empty_set AS ENUM ()");
    try restored.execute("SELECT oid FROM pg_type WHERE typname='empty_set' AND typtype='e'", &result);
    try check(result.row_count == 1);
    try durable("DROP TYPE IF EXISTS missing_type, empty_set, empty_set");
    try durable("DROP SCHEMA enums CASCADE");
    try durable("DROP ROLE enumowner");
    try durable("DROP TYPE old_domain");
    try restored.execute("SELECT enumlabel FROM pg_enum", &result);
    try check(result.row_count == 0 and restored.oid_counter == primary.oid_counter);
}

fn read32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

fn frame(bytes: []const u8, tag: u8) ![]const u8 {
    var cursor = bytes;
    while (cursor.len >= 5) {
        const length: usize = read32(cursor[1..5]);
        if (length < 4 or length + 1 > cursor.len) break;
        if (cursor[0] == tag) return cursor[5..length+1];
        cursor = cursor[length+1..];
    }
    return error.MissingEnumFrame;
}

fn wireQuery(session: *Session, connection: *Store.Connection, command: []const u8) ![]const u8 {
    var packet: [256]u8 = undefined;
    packet[0] = 'Q';
    const length = command.len + 5;
    packet[1..5].* = .{ 0, 0, 0, @intCast(length) };
    @memcpy(packet[5..][0..command.len], command);
    packet[length] = 0;
    const reply = try session.handle(connection, packet[0..length+1], &response);
    try check(reply.consumed == length+1 and !reply.close and !reply.blocked);
    return response[0..reply.written];
}

fn wireContracts() !void {
    var connection: Store.Connection = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    const startup = "\x00\x00\x00\x15\x00\x03\x00\x00user\x00ramsql\x00\x00";
    const initiated = try session.handle(&connection, startup, &response);
    try check(initiated.consumed == startup.len and session.startup);
    const created = try wireQuery(&session, &connection, "CREATE TYPE mood AS ENUM ('UP')");
    try check(equal(try frame(created, 'C'), "CREATE TYPE\x00"));
    const labels = try wireQuery(&session, &connection, "SELECT enumlabel FROM pg_enum");
    const description = try frame(labels, 'T');
    try check(equal(description[0..12], "\x00\x01enumlabel\x00") and read32(description[18..22]) == 19);
    try check(equal(try frame(labels, 'D'), "\x00\x01\x00\x00\x00\x02UP"));
    const duplicate = try wireQuery(&session, &connection, "CREATE TYPE bad AS ENUM ('x', 'x')");
    try check(std.mem.indexOf(u8, try frame(duplicate, 'E'), "C23505\x00") != null);
    const dropped = try wireQuery(&session, &connection, "DROP TYPE mood");
    try check(equal(try frame(dropped, 'C'), "DROP TYPE\x00"));
}

pub fn main(init: std.process.Init) !void {
    sqlContracts() catch |err| {
        std.debug.print("enum SQL and recovery stopped after {d} assertions\n", .{assertions});
        return err;
    };
    wireContracts() catch |err| {
        std.debug.print("enum wire stopped after {d} assertions\n", .{assertions});
        return err;
    };
    var report: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&report, "{{\"suite\":\"pg-enum\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
