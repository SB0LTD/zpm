//! Advanced PostgreSQL type contract (conformance lane B11 "advanced
//! types"): pg_lsn/xid8 catalog identifiers, arrays, ranges, network,
//! geometric and XML values, and user-defined enum/domain/composite types.
//! Every section checks exact values and result metadata (type OID,
//! typmod), NULLs, ordering and hash consistency (GROUP BY/DISTINCT), casts,
//! rejected input with its exact error (SQLSTATE), statement atomicity, the
//! wire representation (pg_types) and change-record replay compared with
//! sameDatabase/sameCatalog.
//!
//! Expected values follow PostgreSQL 18.3. Fixtures that are also in
//! tests/sql_conformance/postgres18_oracle.json are marked "oracle"; every
//! other expectation is derived from the PostgreSQL 18 documentation and
//! source and is pending native verification (no PostgreSQL server was
//! available when this contract was written).
const std = @import("std");
const sql = @import("sql");
const pg_types = @import("pg_types");

const DB = sql.Database(.{ .tables = 4, .columns = 8, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 160, .integer_bits = 32, .nulls_first_ascending = false, .work_rows = 128, .result_rows = 48 });
const Io = DB.Io;
const Wire = pg_types.Types(DB.Result);
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SqlTypesAdvancedContractFailed;
}

fn exec(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// Every row of a query, columns joined by '|' and rows by ';' (NULL as NULL).
fn rows(source: []const u8, expected: []const u8) !void {
    try exec(source);
    try shown(source, expected);
}

/// The current result rendered as in rows().
fn shown(source: []const u8, expected: []const u8) !void {
    var out: [4096]u8 = undefined;
    var at: usize = 0;
    for (0..result.row_count) |index| {
        if (index != 0) {
            out[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                out[at] = '|';
                at += 1;
            }
            const cell = &result.rows[index].cells[column];
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, &db.session, &buffer);
            @memcpy(out[at..][0..text.len], text);
            at += text.len;
        }
    }
    if (!std.mem.eql(u8, out[0..at], expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, out[0..at], expected });
    try check(std.mem.eql(u8, out[0..at], expected));
}

/// Result column `index` has this PostgreSQL type OID and typmod.
fn meta(index: usize, oid: u32, typmod: i32) !void {
    const got_oid = sql.typeOid(result.column_types[index]);
    if (got_oid != oid or result.column_typmods[index] != typmod)
        std.debug.print("column {d}: got oid {d} typmod {d}, expected {d} {d}\n", .{ index, got_oid, result.column_typmods[index], oid, typmod });
    try check(got_oid == oid and result.column_typmods[index] == typmod);
}

/// Result column `index` is named `name`.
fn named(index: usize, name: []const u8) !void {
    const got = result.column_names[index].slice();
    if (!std.mem.eql(u8, got, name)) std.debug.print("column {d}: named {s}, expected {s}\n", .{ index, got, name });
    try check(std.mem.eql(u8, got, name));
}

fn rejects(source: []const u8, wanted: anyerror) !void {
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    // Statement atomicity: nothing pending after a failed statement.
    try check(db.usage().pending_versions == 0 and db.usage().transactions == 0);
}

/// SQLSTATEs of the errors this contract expects, as src/db/postgres.sig
/// knownSqlstate maps them (test_postgres checks that every engine error is
/// mapped; this pins the exact codes).
fn sqlstate(err: anyerror, wanted: []const u8) !void {
    const table = [_]struct { name: []const u8, state: []const u8 }{
        .{ .name = "InvalidTextRepresentation", .state = "22P02" },
        .{ .name = "InvalidParameterValue", .state = "22023" },
        .{ .name = "NumericValueOutOfRange", .state = "22003" },
        .{ .name = "UndefinedFunction", .state = "42883" },
        .{ .name = "CannotCoerce", .state = "42846" },
        .{ .name = "TypeMismatch", .state = "42804" },
        .{ .name = "UnsupportedStatement", .state = "0A000" },
    };
    var state: []const u8 = "?";
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, @errorName(err))) state = entry.state;
    }
    if (!std.mem.eql(u8, state, wanted)) std.debug.print("{s}: SQLSTATE {s}, expected {s}\n", .{ @errorName(err), state, wanted });
    try check(std.mem.eql(u8, state, wanted));
}

fn sendText(cell: *const DB.Cell, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.sendText(cell, &db.session, &out);
    if (!std.mem.eql(u8, out[0..length], expected)) std.debug.print("text got {s}\n  expected {s}\n", .{ out[0..length], expected });
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn sendBinary(cell: *const DB.Cell, data_type: sql.DataType, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.sendBinary(cell, data_type, &db.session, &out);
    if (!std.mem.eql(u8, out[0..length], expected)) std.debug.print("binary got {any}\n  expected {any}\n", .{ out[0..length], expected });
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn literal(bytes: []const u8, oid: u32, format: u16, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.literal(bytes, oid, format, &out);
    if (!std.mem.eql(u8, out[0..length], expected)) std.debug.print("literal got {s}\n  expected {s}\n", .{ out[0..length], expected });
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn receive(bytes: []const u8, data_type: sql.DataType, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const text = try Wire.receiveText(bytes, data_type, &out);
    if (!std.mem.eql(u8, text, expected)) std.debug.print("receive got {s}\n  expected {s}\n", .{ text, expected });
    try check(std.mem.eql(u8, text, expected));
}

fn sameResult(a: *const DB.Result, b: *const DB.Result, a_db: *DB, b_db: *DB) !bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or a.column_typmods[column] != b.column_typmods[column] or
            !std.mem.eql(u8, a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |index| for (0..a.column_count) |column| {
        const x = &a.rows[index].cells[column];
        const y = &b.rows[index].cells[column];
        if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*) or DB.compareCells(x, y) != 0) return false;
        if (x.* == .null_value) continue;
        var p: [Io.format_bytes]u8 = undefined;
        var q: [Io.format_bytes]u8 = undefined;
        if (!std.mem.eql(u8, try Io.format(x, false, &a_db.session, &p), try Io.format(y, false, &b_db.session, &q))) return false;
    };
    return true;
}

fn sameQuery(a: *DB, b: *DB, source: []const u8) !bool {
    var x: DB.Result = .{};
    var y: DB.Result = .{};
    try a.execute(source, &x);
    try b.execute(source, &y);
    return sameResult(&x, &y, a, b);
}

/// Logical equality of two databases over the tables named `tables`:
/// table count, OID counter, live rows, next rowids and every row (scan
/// order, cell tags, btree equality and text form).
fn sameDatabase(a: *DB, b: *DB, tables: []const []const u8) !bool {
    if (a.tableCount() != b.tableCount() or a.oid_counter != b.oid_counter) return false;
    for (tables) |name| {
        const left = a.storageStats(name);
        const right = b.storageStats(name);
        if ((left == null) != (right == null)) return false;
        if (left == null) continue;
        if (left.?.live_rows != right.?.live_rows or left.?.next_rowid != right.?.next_rowid) return false;
        var query: [64]u8 = undefined;
        if (!try sameQuery(a, b, try std.fmt.bufPrint(&query, "SELECT * FROM {s}", .{name}))) return false;
    }
    return true;
}

/// Relation OIDs, column types/typmods and the type catalog agree.
fn sameCatalog(a: *DB, b: *DB) !bool {
    for ([_][]const u8{
        "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
        "SELECT attrelid, attname, atttypid FROM pg_attribute WHERE attrelid >= 16384 ORDER BY attrelid, attnum",
        "SELECT attrelid, attnum, atttypmod FROM pg_attribute WHERE attrelid >= 16384 ORDER BY attrelid, attnum",
        "SELECT COUNT(*), SUM(oid::int8), SUM(typarray::int8) FROM pg_type",
    }) |source| if (!try sameQuery(a, b, source)) {
        std.debug.print("catalog differs: {s}\n", .{source});
        return false;
    };
    return true;
}

/// Replays `statements` from a fresh primary into a replica through kind-3
/// change records; both must hold the same database and catalog and answer
/// `query` identically (types, typmods, cell tags and text).
fn replay(statements: []const []const u8, tables: []const []const u8, query: []const u8) !void {
    var primary: DB = .{};
    var replica: DB = .{};
    var r: DB.Result = .{};
    var record: [4096]u8 = undefined;
    for (statements) |source| {
        var used: usize = 0;
        primary.executeChanges(source, &r, &record, &used, null, null) catch |err| {
            std.debug.print("replay source failed: {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        try replica.applyChangeRecord(record[0..used], &scratch);
    }
    try check(try sameDatabase(&primary, &replica, tables));
    try check(try sameCatalog(&primary, &replica));
    var expected: DB.Result = .{};
    try primary.execute(query, &expected);
    try replica.execute(query, &result);
    try check(try sameResult(&expected, &result, &primary, &replica));
}

// ---- pg_lsn / xid8 -----------------------------------------------------------

fn catalogIds() !void {
    // oracle: PG.TYPE.CATALOG_IDS.
    try rows("SELECT '0/16B6C50'::pg_lsn,'1'::xid8", "0/16B6C50|1");
    try meta(0, 3220, -1);
    try meta(1, 5069, -1);
    try named(0, "pg_lsn");
    try named(1, "xid8");

    // pg_lsn input: one to eight hex digits on each side of '/', any case.
    try rows("SELECT 'ffffffff/ffffffff'::pg_lsn, '00000001/0000000a'::pg_lsn, '0/0'::pg_lsn, PG_LSN 'A/b'", "FFFFFFFF/FFFFFFFF|1/A|0/0|A/B");
    for ([_][]const u8{
        "SELECT '0/'::pg_lsn",              "SELECT '/1'::pg_lsn",
        "SELECT '123456789/0'::pg_lsn",     "SELECT '0/123456789'::pg_lsn",
        "SELECT ' 0/1'::pg_lsn",            "SELECT '0/1 '::pg_lsn",
        "SELECT 'G/0'::pg_lsn",             "SELECT '0-1'::pg_lsn",
        "SELECT ''::pg_lsn",                "SELECT '0/1/2'::pg_lsn",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    try sqlstate(error.InvalidTextRepresentation, "22P02");

    // xid8 input is strtou64 with base 0 and surrounding whitespace.
    try rows("SELECT '42'::xid8, ' 42 '::xid8, '0x1F'::xid8, '017'::xid8, '18446744073709551615'::xid8, '-1'::xid8, '+7'::xid8",
        "42|42|31|15|18446744073709551615|18446744073709551615|7");
    try rejects("SELECT '18446744073709551616'::xid8", error.NumericValueOutOfRange);
    try sqlstate(error.NumericValueOutOfRange, "22003");
    for ([_][]const u8{ "SELECT 'abc'::xid8", "SELECT ''::xid8", "SELECT '1a'::xid8", "SELECT '08'::xid8", "SELECT '0x'::xid8", "SELECT '1 2'::xid8" }) |source|
        try rejects(source, error.InvalidTextRepresentation);

    // Columns, NULLs, unsigned ordering and hash consistency.
    try exec("CREATE TABLE ids(id INT PRIMARY KEY, l PG_LSN, x XID8)");
    try exec("INSERT INTO ids VALUES(1, '1/0', '18446744073709551615'), (2, '0/10', '1'), (3, NULL, NULL), (4, 'FFFFFFFF/0', '9223372036854775808'), (5, '0/10', '1')");
    try rows("SELECT l FROM ids ORDER BY l NULLS LAST", "0/10;0/10;1/0;FFFFFFFF/0;NULL");
    try rows("SELECT x FROM ids ORDER BY x DESC NULLS LAST", "18446744073709551615;9223372036854775808;1;1;NULL");
    try rows("SELECT l, COUNT(*) FROM ids GROUP BY l ORDER BY l", "0/10|2;1/0|1;FFFFFFFF/0|1;NULL|1");
    try rows("SELECT COUNT(DISTINCT x), COUNT(DISTINCT l) FROM ids", "3|3");
    try rows("SELECT MIN(l), MAX(l), MIN(x), MAX(x) FROM ids", "0/10|FFFFFFFF/0|1|18446744073709551615");
    try meta(0, 3220, -1);
    try meta(2, 5069, -1);
    try rows("SELECT id FROM ids WHERE l = '0/10' ORDER BY id", "2;5");
    try rows("SELECT id FROM ids WHERE x > '9223372036854775807' ORDER BY id", "1;4");
    try rows("SELECT id FROM ids WHERE l >= '1/0' AND l <> 'FFFFFFFF/0'", "1");
    try rows("SELECT a.id, b.id FROM ids a JOIN ids b ON a.l = b.l AND a.id < b.id", "2|5");

    // Operators: pg_lsn - pg_lsn is numeric; pg_lsn +- numeric is pg_lsn
    // (numeric_pg_lsn rounds and range-checks).
    try rows("SELECT '1/0'::pg_lsn - '0/10'::pg_lsn, '0/10'::pg_lsn - '1/0'::pg_lsn", "4294967280|-4294967280");
    try meta(0, 1700, -1);
    try rows("SELECT '0/10'::pg_lsn + 16, 16 + '0/10'::pg_lsn, '0/10'::pg_lsn - 16, '0/10'::pg_lsn + 1.5, '1/0'::pg_lsn - 1", "0/20|0/20|0/0|0/12|0/FFFFFFFF");
    try meta(0, 3220, -1);
    try meta(3, 3220, -1);
    try rows("SELECT l - '0/0' FROM ids WHERE id = 1", "4294967296");
    try rejects("SELECT '0/10'::pg_lsn - 17", error.NumericValueOutOfRange);
    try rejects("SELECT 'FFFFFFFF/FFFFFFFF'::pg_lsn + 1", error.NumericValueOutOfRange);
    try rejects("SELECT '0/10'::pg_lsn + 'NaN'::numeric", error.InvalidParameterValue);
    try sqlstate(error.InvalidParameterValue, "22023");
    try rejects("SELECT '0/10'::pg_lsn + 'Infinity'::numeric", error.UnsupportedStatement);
    try sqlstate(error.UnsupportedStatement, "0A000");
    try rejects("SELECT '0/10'::pg_lsn + '0/10'::pg_lsn", error.UndefinedFunction);
    try rejects("SELECT 16 - '0/10'::pg_lsn", error.UndefinedFunction);
    try rejects("SELECT '0/10'::pg_lsn + 1.5::float8", error.UndefinedFunction);
    try rejects("SELECT '1'::xid8 + 1", error.UndefinedFunction);
    try rejects("SELECT l = x FROM ids", error.UndefinedFunction);
    try sqlstate(error.UndefinedFunction, "42883");

    // Casts: to text by assignment or explicitly, from text explicitly only;
    // no numeric casts.
    try rows("SELECT l::text, CAST(x AS VARCHAR(3)), '0/1'::text::pg_lsn FROM ids WHERE id = 2", "0/10|1|0/1");
    try meta(0, 25, -1);
    try rejects("SELECT 1::pg_lsn", error.CannotCoerce);
    try rejects("SELECT '1'::xid8::int8", error.CannotCoerce);
    try sqlstate(error.CannotCoerce, "42846");
    try rejects("INSERT INTO ids(id, l) VALUES(6, '0/1'::text)", error.TypeMismatch);
    try sqlstate(error.TypeMismatch, "42804");
    // Atomicity: one bad row undoes the statement.
    try rejects("INSERT INTO ids(id, l) VALUES(6, '0/1'), (7, 'bad')", error.InvalidTextRepresentation);
    try rejects("UPDATE ids SET l = l + 4294967296 WHERE id <> 3", error.NumericValueOutOfRange);
    try rows("SELECT COUNT(*), MAX(l) FROM ids", "5|FFFFFFFF/0");
    try rows("SELECT format_type(3220, NULL), format_type(5069, -1), 'pg_lsn'::regtype::text, 'xid8'::regtype::oid", "pg_lsn|xid8|pg_lsn|5069");
    try rows("SELECT typname, typlen, typcategory, typarray, typinput FROM pg_type WHERE oid IN (3220, 5069) ORDER BY oid", "pg_lsn|8|U|3221|pg_lsn_in;xid8|8|U|271|xid8in");
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'ids' ORDER BY ordinal_position", "integer;pg_lsn;xid8");
    try exec("DROP TABLE ids");

    // Wire: both are big-endian 64-bit integers.
    try check(Wire.oid(.pg_lsn) == 3220 and Wire.length(.pg_lsn) == 8 and Wire.oid(.xid8) == 5069 and Wire.length(.xid8) == 8);
    try exec("SELECT '1/16B6C50'::pg_lsn, '18446744073709551615'::xid8");
    const lsn = [_]u8{ 0, 0, 0, 1, 0x01, 0x6b, 0x6c, 0x50 };
    const xid = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try sendText(&result.rows[0].cells[0], "1/16B6C50");
    try sendBinary(&result.rows[0].cells[0], .pg_lsn, &lsn);
    try sendBinary(&result.rows[0].cells[1], .xid8, &xid);
    try receive(&lsn, .pg_lsn, "1/16B6C50");
    try receive(&xid, .xid8, "18446744073709551615");
    try literal(&lsn, 3220, 1, "'1/16B6C50'::pg_lsn");
    try literal("0/1", 3220, 0, "'0/1'::pg_lsn");
    try literal(&xid, 5069, 1, "'18446744073709551615'::xid8");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(lsn[0..7], .pg_lsn, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .xid8, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability: change-record tags 19 (pg_lsn) and 20 (xid8).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, l PG_LSN, x XID8)",
        "INSERT INTO r VALUES(1, 'FFFFFFFF/FFFFFFFF', '18446744073709551615'), (2, NULL, NULL), (3, '0/1', '0')",
        "UPDATE r SET l = l + 15, x = '7' WHERE id = 3",
        "DELETE FROM r WHERE id = 2",
    }, &.{"r"}, "SELECT * FROM r ORDER BY l");
    try shown("replica", "3|0/10|7;1|FFFFFFFF/FFFFFFFF|18446744073709551615");
    try meta(1, 3220, -1);
    try meta(2, 5069, -1);
}

pub fn main(init: std.process.Init) !void {
    try catalogIds();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types-advanced\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
