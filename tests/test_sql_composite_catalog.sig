//! PostgreSQL composite type DDL, catalog visibility and checked WAL replay.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 4, .columns = 8, .rows_per_table = 8, .work_rows = 512, .name_bytes = 64, .text_bytes = 128, .transactions = 4 });

var primary: DB = .{};
var restored: DB = .{};
var scratch: DB.ReplayScratch = .{};
var result: DB.Result = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("composite catalog assertion {d} failed\n", .{assertions});
        return error.CompositeCatalogContract;
    }
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn rejects(source: []const u8, wanted: sql.Error) !void {
    primary.execute(source, &result) catch |err| {
        if (err != wanted) {
            std.debug.print("{s}: expected {s}, got {s}\n", .{ source, @errorName(wanted), @errorName(err) });
            return err;
        }
        return check(true);
    };
    return error.ExpectedCompositeCatalogError;
}

fn durable(source: []const u8) !void {
    var record: [4096]u8 = undefined;
    var used: usize = 0;
    try primary.executeChanges(source, &result, &record, &used, null, null);
    try restored.applyChangeRecord(record[0..used], &scratch);
}

const point_relation = "SELECT oid,relkind,relnatts,relnamespace FROM pg_class WHERE relname='Point'";

fn catalog(db: *DB) ![5]i64 {
    try db.execute("SELECT oid,typarray,typrelid,typowner,typnamespace,typlen,typcategory,typinput FROM pg_type WHERE typname='Point' AND typtype='c'", &result);
    try check(result.row_count == 1 and result.column_count == 8 and result.rows[0].cells[5].integer == -1);
    const cells = &result.rows[0].cells;
    try check(equal(cells[6].text.slice(), "C") and equal(cells[7].text.slice(), "record_in"));
    const identity = [5]i64{ cells[0].integer, cells[1].integer, cells[2].integer, cells[3].integer, cells[4].integer };
    try check(identity[0] >= sql.change_records.first_oid and identity[1] > identity[0] and identity[2] > identity[1]);
    try check(identity[3] != 10 and identity[4] != 2200);
    try db.execute(point_relation, &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == identity[2]);
    try check(result.rows[0].cells[1] == .pg_internal_char and result.rows[0].cells[1].pg_internal_char == 'c' and result.rows[0].cells[2].integer == 6);
    try check(result.rows[0].cells[3].integer == identity[4]);
    try db.execute("SELECT oid,typelem,typrelid FROM pg_type WHERE typname='_Point'", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == identity[1]);
    try check(result.rows[0].cells[1].integer == identity[0] and result.rows[0].cells[2].integer == 0);

    var query: [256]u8 = undefined;
    try db.execute(try std.fmt.bufPrint(&query,
        "SELECT attname,atttypid,atttypmod,attnum,attnotnull,attisdropped FROM pg_attribute WHERE attrelid={d} ORDER BY attnum",
        .{identity[2]}), &result);
    const names = [_][]const u8{ "X", "x", "amount", "labels", "note", "stamp" };
    const oids = [_]i64{ 23, 21, 1700, 1009, 1043, 1114 };
    const typmods = [_]i64{ -1, -1, (9 << 16) + 2 + 4, -1, 9, 3 };
    try check(result.row_count == names.len);
    for (result.rows[0..names.len], names, oids, typmods, 1..) |*row, name, oid, typmod, ordinal| {
        try check(equal(row.cells[0].text.slice(), name) and row.cells[1].integer == oid);
        try check(row.cells[2].integer == typmod and row.cells[3].integer == @as(i64, @intCast(ordinal)));
        try check(!row.cells[4].boolean and !row.cells[5].boolean);
    }
    return identity;
}

fn rejectRecord(record: []const u8, wanted: sql.Error) !void {
    const before_csn = restored.csn;
    const before_oid = restored.oid_counter;
    if (restored.applyChangeRecord(record, &scratch)) |_| return error.InvalidCompositeRecordAccepted else |err| try check(err == wanted);
    try check(restored.csn == before_csn and restored.oid_counter == before_oid);
}

fn corruptRecords(existing_relation_oid: u32) !void {
    var record: [4096]u8 = undefined;
    var used: usize = 0;
    try primary.executeChanges("CREATE TYPE secondary AS (i INTEGER)", &result, &record, &used, null, null);
    const version = used - 3;
    const field_oid = version - 2 - 8;
    try check(record[version] == 1 and record[version+1] == 1 and record[field_oid] == 23);
    record[version] = 2;
    try rejectRecord(record[0..used], error.UnsupportedLogVersion);
    record[version] = 1;
    record[version+1] = 0;
    try rejectRecord(record[0..used], error.InvalidChangeRecord);
    record[version+1] = 1;
    record[field_oid] = 0;
    try rejectRecord(record[0..used], error.InvalidChangeRecord);
    record[field_oid] = 23;
    record[field_oid+4] = 0;
    try rejectRecord(record[0..used], error.InvalidChangeRecord);
    record[field_oid+4] = 0xff;
    const object_oid = sql.change_records.header_size + 2;
    const original = record[object_oid..][0..4].*;
    for (0..4) |i| record[object_oid+i] = @truncate(existing_relation_oid >> @intCast(i * 8));
    try rejectRecord(record[0..used], error.ChangeRecordConflict);
    record[object_oid..][0..4].* = original;
    try restored.applyChangeRecord(record[0..used], &scratch);
    try durable("DROP TYPE secondary");
}

fn recordText(db: *DB, statement: []const u8, expected: []const u8, name: []const u8) !void {
    try db.execute(statement, &result);
    try check(result.row_count == 1 and result.column_count == 1 and equal(result.column_names[0].slice(), name));
    const identity = result.nominalColumnType(0).?;
    try check(identity.oid >= sql.change_records.first_oid and identity.len == -1 and identity.representation == .flat_record);
    var out: [256]u8 = undefined;
    const len = (try result.formatNominalText(0, &result.rows[0].cells[0], &out)).?;
    try check(equal(out[0..len], expected));
}

fn flatRecordContracts() !void {
    try durable("CREATE TYPE pair AS (n INTEGER, label TEXT)");
    try durable("CREATE TYPE narrow_fields AS (s SMALLINT, l BIGINT, b BOOLEAN)");
    for ([_]*DB{ &primary, &restored }) |db| {
        try recordText(db, "SELECT ROW(1,'x')::pair", "(1,x)", "row");
        const binary =
            "\x00\x00\x00\x02" ++
            "\x00\x00\x00\x17\x00\x00\x00\x04\x00\x00\x00\x01" ++
            "\x00\x00\x00\x19\x00\x00\x00\x01x";
        try check(equal(result.rows[0].cells[0].bytea.slice(), binary));
        try recordText(db, "SELECT ROW(NULL,'')::pair", "(,\"\")", "row");
        try recordText(db, "SELECT ROW(-7,' a,b()\"\\ ')::pair", "(-7,\" a,b()\"\"\\\\ \")", "row");
        try recordText(db, "SELECT ROW(-32768,-9223372036854775808,TRUE)::narrow_fields", "(-32768,-9223372036854775808,t)", "row");
        try recordText(db, "SELECT ROW('003','nice')::pair", "(3,nice)", "row");
        try result.textify(DB.Result.default_session);
        try check(result.nominalColumnType(0) == null and result.column_types[0] == .text and equal(result.rows[0].cells[0].text.slice(), "(3,nice)"));
        try db.execute("SELECT CAST(NULL AS pair)", &result);
        try check(result.rows[0].cells[0] == .null_value and result.nominalColumnType(0).?.representation == .flat_record);
        try check(equal(result.column_names[0].slice(), "pair"));
        try db.execute("DECLARE records CURSOR WITH HOLD FOR SELECT ROW(1,'x')::pair", &result);
        try recordText(db, "FETCH NEXT FROM records", "(1,x)", "row");
        try db.execute("CLOSE records", &result);
    }
    try rejects("SELECT ROW(1)::pair", error.CannotCoerce);
    try rejects("SELECT ROW(1,'x',NULL)::pair", error.CannotCoerce);
    try rejects("SELECT ROW('invalid','x')::pair", error.InvalidTextRepresentation);
    try rejects("SELECT ROW(32768,1,TRUE)::narrow_fields", error.NumericValueOutOfRange);
    try rejects("SELECT ROW(1+2,'x')::pair", error.UnsupportedStatement);
    try rejects("SELECT ROW(1,'x')::pair::TEXT", error.UnsupportedStatement);
    try rejects("SELECT ROW(1,'x')::pair = ROW(1,'x')::pair", error.UnsupportedStatement);
}

fn contract() !void {
    // Replay must continue to decode the old domain and enum op layouts.
    try durable("CREATE DOMAIN old_domain AS INT");
    try durable("CREATE TYPE old_enum AS ENUM ('old')");
    try durable("CREATE SCHEMA coords");
    try durable("CREATE ROLE coordinates_owner SUPERUSER");
    try primary.execute("SET ROLE coordinates_owner", &result);
    try durable("CREATE TYPE coords.\"Point\" AS (\"X\" INTEGER, x SMALLINT, amount NUMERIC(9,2), labels TEXT[], note VARCHAR(5), stamp TIMESTAMP(3))");
    try check(result.command == .create_type);
    try primary.execute("RESET ROLE", &result);
    const original = try catalog(&primary);
    const replayed = try catalog(&restored);
    try check(std.mem.eql(i64, &original, &replayed));
    try check(primary.tableCount() == 0 and restored.tableCount() == 0);
    try corruptRecords(@intCast(original[2]));
    try check(primary.oid_counter == restored.oid_counter);
    try restored.execute("SELECT 'old'::old_enum, 7::old_domain", &result);
    try check(result.nominalColumnType(0) != null and result.rows[0].cells[1].integer == 7);

    try rejects("CREATE TYPE duplicate_fields AS (x INT, x TEXT)", error.DuplicateColumn);
    try rejects("CREATE TYPE trailing_comma AS (x INT,)", error.Syntax);
    try rejects("CREATE TYPE nested AS (x old_domain)", error.UnsupportedStatement);
    try rejects("CREATE TYPE collated AS (x TEXT COLLATE \"C\")", error.UnsupportedStatement);
    try rejects("CREATE DOMAIN coords.\"Point\" AS INT", error.DuplicateObject);
    try rejects("CREATE TABLE coords.\"Point\" (id INT)", error.DuplicateObject);
    try rejects("CREATE TABLE stored (p coords.\"Point\")", error.UnsupportedStatement);
    try rejects("SELECT ROW(1, 2, NULL, NULL, NULL, NULL)::coords.\"Point\"", error.UnsupportedStatement);
    try rejects("ALTER TYPE coords.\"Point\" ADD ATTRIBUTE note2 TEXT", error.UnsupportedStatement);
    try rejects("DROP DOMAIN coords.\"Point\"", error.WrongObjectType);
    try rejects("DROP ROLE coordinates_owner", error.DependentObjects);
    try rejects("DROP SCHEMA coords RESTRICT", error.DependentObjects);

    const slot = try primary.begin();
    try primary.statement(slot, "CREATE TYPE transient AS (val INTEGER)", &result, .{});
    const transient = "SELECT oid FROM pg_class WHERE relkind='c' AND relname='transient'";
    try primary.statement(slot, transient, &result, .{});
    try check(result.row_count == 1);
    try primary.execute(transient, &result);
    try check(result.row_count == 0);
    primary.abort(slot);
    try primary.execute(transient, &result);
    try check(result.row_count == 0);

    const drop = try primary.begin();
    try primary.statement(drop, "DROP TYPE coords.\"Point\"", &result, .{});
    try primary.statement(drop, point_relation, &result, .{});
    try check(result.row_count == 0);
    _ = try catalog(&primary);
    primary.abort(drop);
    _ = try catalog(&primary);

    try durable("CREATE SEQUENCE seq_conflict");
    try rejects("CREATE TYPE seq_conflict AS ()", error.TableExists);
    try durable("CREATE TYPE empty_shape AS ()");
    try rejects("CREATE SEQUENCE empty_shape", error.TableExists);
    try durable("CREATE SEQUENCE _empty_shape");
    try restored.execute("SELECT relnatts FROM pg_class WHERE relname='empty_shape' AND relkind='c'", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 0);
    try durable("DROP TYPE IF EXISTS absent, empty_shape");
    try check(result.command == .drop_type);
    try durable("DROP SCHEMA coords CASCADE");
    try durable("DROP ROLE coordinates_owner");
    try restored.execute(point_relation, &result);
    try check(result.row_count == 0);
    try restored.execute("SELECT oid FROM pg_type WHERE typname IN ('Point','_Point')", &result);
    try check(result.row_count == 0 and restored.oid_counter == primary.oid_counter);
    try flatRecordContracts();
}

pub fn main(init: std.process.Init) !void {
    contract() catch |err| {
        std.debug.print("composite catalog stopped after {d} assertions\n", .{assertions});
        return err;
    };
    var report: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&report, "{{\"suite\":\"sql-composite-catalog\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
