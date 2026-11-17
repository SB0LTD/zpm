//! Integer domain DDL, cast, snapshot, recovery, and PostgreSQL wire contracts.
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const Store = @import("db_store").Store(DB);
const DB = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 4, .work_rows = 512, .text_bytes = 64, .transactions = 4 });
const Session = pg.Session(Store.Connection);

var source: DB = .{};
var restored: DB = .{};
var scratch: DB.ReplayScratch = .{};
var result: DB.Result = .{};
var association: Store = .{};
var output: [Session.responseCapacity()]u8 = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("domain contract failed at assertion {d}\n", .{assertions});
        return error.DomainContractFailed;
    }
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn expectError(db: *DB, command: []const u8, wanted: anyerror) !void {
    db.execute(command, &result) catch |err| {
        if (err != wanted) {
            std.debug.print("{s}: got {s}, wanted {s}\n", .{ command, @errorName(err), @errorName(wanted) });
            return err;
        }
        return check(true);
    };
    return error.MissingDomainError;
}

fn oldRoleRecord() !void {
    // The original kind-1 create layout has no typed addendum.
    const zero = "\x00\x00\x00\x00";
    const record = "\x01\x00\x00\x00\x01\x00\x00\x00" ++
        "\x46\x01\x00\x40\x00\x00" ++ zero ** 6 ++ "\x08old_role" ++ zero ++ "\x00";
    try source.applyChangeRecord(record, &scratch);
    try restored.applyChangeRecord(record, &scratch);
    try source.execute("SELECT rolname FROM pg_roles WHERE rolname = 'old_role'", &result);
    try check(result.row_count == 1 and equal(result.rows[0].cells[0].text.slice(), "old_role"));
}

fn durable(command: []const u8) !void {
    var record: [1024]u8 = undefined;
    var used: usize = 0;
    try source.executeChanges(command, &result, &record, &used, null, null);
    try restored.applyChangeRecord(record[0..used], &scratch);
}

fn catalogIdentity(db: *DB) ![2]i64 {
    try db.execute("SELECT oid, typarray, typbasetype, typnotnull FROM pg_type WHERE typname = 'positive' AND typtype = 'd'", &result);
    try check(result.row_count == 1 and result.rows[0].cells[2].integer == 23 and !result.rows[0].cells[3].boolean);
    const domain = result.rows[0].cells[0].integer;
    const array = result.rows[0].cells[1].integer;
    try check(domain >= sql.change_records.first_oid and array > domain);
    try db.execute("SELECT oid, typelem FROM pg_type WHERE typname = '_positive' AND typcategory = 'A'", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == array and result.rows[0].cells[1].integer == domain);
    return .{ domain, array };
}

fn sqlContracts() !void {
    try oldRoleRecord();
    try durable("CREATE SCHEMA checked");
    try durable("CREATE DOMAIN checked.positive AS INT CHECK (VALUE > 0)");
    const original = try catalogIdentity(&source);
    const replayed = try catalogIdentity(&restored);
    try check(original[0] == replayed[0] and original[1] == replayed[1]);
    try check(source.oid_counter == restored.oid_counter);

    for ([_]*DB{ &source, &restored }) |db| {
        try db.describe("SELECT CAST(1 AS checked.positive)", &result);
        try check(result.column_count == 1 and result.column_types[0] == .integer32 and result.column_typmods[0] == -1);
        try check(equal(result.column_names[0].slice(), "positive"));
        try db.execute("SELECT CAST('812' AS checked.positive), NULL::checked.positive", &result);
        try check(result.row_count == 1 and result.rows[0].cells[0].integer == 812 and result.rows[0].cells[1] == .null_value);
        try expectError(db, "SELECT (-1)::checked.positive", error.CheckViolation);
        try expectError(db, "SELECT '2147483648'::checked.positive", error.IntegerOverflow);
        try expectError(db, "SELECT 'invalid'::checked.positive", error.InvalidTextRepresentation);
        try expectError(db, "CREATE TABLE incompatible (i checked.positive)", error.UnsupportedStatement);
        try expectError(db, "CREATE DOMAIN nested AS checked.positive", error.UnsupportedStatement);
        try expectError(db, "SELECT 1::checked.positive + 2", error.UnsupportedStatement);
        try expectError(db, "SELECT '1'::checked._positive", error.UnsupportedStatement);
        try expectError(db, "CREATE DOMAIN checked.positive AS INT", error.DuplicateObject);
        try expectError(db, "CREATE TABLE checked.positive (i INT)", error.DuplicateObject);
        try expectError(db, "DROP SCHEMA checked RESTRICT", error.DependentObjects);
    }

    var record: [1024]u8 = undefined;
    var used: usize = 0;
    try source.executeChanges("CREATE DOMAIN short_only AS SMALLINT NOT NULL CHECK (-2 <= VALUE)", &result, &record, &used, null, null);
    try check(used > 12);
    const version_index = used - 12;
    try check(record[version_index] == 1);
    record[version_index] = 2;
    if (restored.applyChangeRecord(record[0..used], &scratch)) |_| return error.AcceptedUnknownDomainVersion else |err| try check(err == error.UnsupportedLogVersion);
    try expectError(&restored, "SELECT 1::short_only", error.UndefinedObject);
    record[version_index] = 1;
    try restored.applyChangeRecord(record[0..used], &scratch);
    for ([_]*DB{ &source, &restored }) |db| {
        try db.execute("SELECT (-2)::short_only", &result);
        try check(result.column_types[0] == .smallint and result.rows[0].cells[0].integer == -2);
        try expectError(db, "SELECT NULL::short_only", error.NotNullViolation);
        try expectError(db, "SELECT (-3)::short_only", error.CheckViolation);
    }
    try durable("CREATE DOMAIN huge AS BIGINT CHECK (VALUE >= -9223372036854775808)");
    try restored.execute("SELECT 9223372036854775807::huge", &result);
    try check(result.column_types[0] == .integer and result.rows[0].cells[0].integer == 9223372036854775807);

    const slot = try source.begin();
    try source.statement(slot, "CREATE DOMAIN transient AS INT", &result, .{});
    try source.statement(slot, "SELECT 2::transient", &result, .{});
    try check(result.rows[0].cells[0].integer == 2);
    try expectError(&source, "SELECT 2::transient", error.UndefinedObject);
    source.abort(slot);
    try expectError(&source, "SELECT 2::transient", error.UndefinedObject);

    try durable("CREATE ROLE typeowner SUPERUSER");
    try source.execute("SET ROLE typeowner", &result);
    try durable("CREATE DOMAIN owned AS INT");
    try source.execute("RESET ROLE", &result);
    try expectError(&source, "DROP ROLE typeowner", error.DependentObjects);
    try expectError(&restored, "DROP ROLE typeowner", error.DependentObjects);
    try durable("DROP DOMAIN owned");
    try durable("DROP ROLE typeowner");

    try durable("DROP SCHEMA checked CASCADE");
    try expectError(&restored, "SELECT 1::checked.positive", error.UndefinedSchema);
    try restored.execute("SELECT oid FROM pg_type WHERE typname IN ('positive','_positive')", &result);
    try check(result.row_count == 0);
}

fn read16(input: []const u8) u16 {
    return (@as(u16, input[0]) << 8) | input[1];
}

fn read32(input: []const u8) u32 {
    return (@as(u32, read16(input[0..2])) << 16) | read16(input[2..4]);
}

fn frame(bytes: []const u8, tag: u8) ![]const u8 {
    var cursor = bytes;
    while (cursor.len >= 5) {
        const len: usize = read32(cursor[1..5]);
        if (len < 4 or len + 1 > cursor.len) break;
        if (cursor[0] == tag) return cursor[5..len + 1];
        cursor = cursor[len + 1..];
    }
    return error.MissingDomainFrame;
}

fn wireQuery(session: *Session, connection: *Store.Connection, command: []const u8) ![]const u8 {
    var packet: [256]u8 = undefined;
    packet[0] = 'Q';
    const length = command.len + 5;
    packet[1..5].* = .{ 0, 0, 0, @intCast(length) };
    @memcpy(packet[5..][0..command.len], command);
    packet[length] = 0;
    const reply = try session.handle(connection, packet[0..length + 1], &output);
    try check(reply.consumed == length + 1 and !reply.close and !reply.blocked);
    return output[0..reply.written];
}

fn wireContracts() !void {
    var connection: Store.Connection = .{ .store = &association, .id = 1 };
    var session: Session = .{};
    const startup = "\x00\x00\x00\x15\x00\x03\x00\x00user\x00ramsql\x00\x00";
    const initiated = try session.handle(&connection, startup, &output);
    try check(initiated.consumed == startup.len and session.startup);
    const created = try wireQuery(&session, &connection, "CREATE DOMAIN positive AS INT CHECK (VALUE > 0)");
    try check(equal(try frame(created, 'C'), "CREATE DOMAIN\x00"));
    const selected = try wireQuery(&session, &connection, "SELECT 12::positive");
    const description = try frame(selected, 'T');
    try check(read16(description[0..2]) == 1 and equal(description[2..11], "positive\x00"));
    try check(read32(description[17..21]) == 23 and read16(description[21..23]) == 4 and read32(description[23..27]) == 0xffffffff);
    try check(equal(try frame(selected, 'D'), "\x00\x01\x00\x00\x00\x0212"));
    const invalid = try wireQuery(&session, &connection, "SELECT 0::positive");
    try check(std.mem.indexOf(u8, try frame(invalid, 'E'), "C23514\x00") != null);
    const dropped = try wireQuery(&session, &connection, "DROP DOMAIN positive");
    try check(equal(try frame(dropped, 'C'), "DROP DOMAIN\x00"));
}

pub fn main(init: std.process.Init) !void {
    sqlContracts() catch |err| {
        std.debug.print("SQL/recovery domain contract stopped after {d} assertions\n", .{assertions});
        return err;
    };
    wireContracts() catch |err| {
        std.debug.print("Wire domain contract stopped after {d} assertions\n", .{assertions});
        return err;
    };
    var report: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&report, "{{\"suite\":\"pg-domain\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
