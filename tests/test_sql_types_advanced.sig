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
        .{ .name = "ProgramLimitExceeded", .state = "54000" },
        .{ .name = "TextCapacity", .state = "54000" },
        .{ .name = "IndeterminateDatatype", .state = "42P18" },
        .{ .name = "ArraySubscriptError", .state = "2202E" },
        .{ .name = "DataException", .state = "22000" },
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

// ---- arrays ------------------------------------------------------------------

fn arrays() !void {
    // oracle: PG.TYPE.ARRAY.
    try exec("CREATE TABLE tdd_type(v INT[])");
    try exec("INSERT INTO tdd_type VALUES(ARRAY[1,2]),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "{1,2};NULL");
    try meta(0, 1007, -1);
    try named(0, "v");
    try exec("DROP TABLE tdd_type");

    // Declarations: every spelling names the same array type; declared sizes
    // and dimensions are ignored; the typmod applies to the elements.
    try exec("CREATE TABLE a(id INT PRIMARY KEY, i INTEGER ARRAY, t TEXT[], n NUMERIC(5,2)[], v VARCHAR(3)[], g INT[3][3], b BOOLEAN ARRAY[2])");
    try rows("SELECT atttypid, atttypmod FROM pg_attribute WHERE attrelid = 'a'::regclass ORDER BY attnum", "23|-1;1007|-1;1009|-1;1231|327686;1015|7;1007|-1;1000|-1");
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'a' AND column_name IN ('i', 'v') ORDER BY ordinal_position", "ARRAY;ARRAY");
    try rows("SELECT format_type(1007, NULL), format_type(1015, 7), format_type(1231, 327686), 'int4[]'::regtype::text, 'integer[]'::regtype::oid, '_text'::regtype::oid, 1009::regtype::text",
        "integer[]|character varying(3)[]|numeric(5,2)[]|integer[]|1007|1009|text[]");
    try rows("SELECT typname, typlen, typcategory, typarray, typinput FROM pg_type WHERE oid IN (23, 1007) ORDER BY oid", "int4|4|N|1007|int4in;_int4|-1|A|0|array_in");

    // array_in: quoting, NULL, escapes, whitespace, typmods per element.
    try exec("INSERT INTO a(id, i, t, n, v, b) VALUES(1, '{1,2,3}', '{a,\"b c\",NULL,\"NULL\",\"\"}', '{1.5,NULL}', '{x,yz}', '{t,f}')");
    try rows("SELECT i, t, n, v, b FROM a WHERE id = 1", "{1,2,3}|{a,\"b c\",NULL,\"NULL\",\"\"}|{1.50,NULL}|{x,yz}|{t,f}");
    try meta(1, 1009, -1);
    try meta(2, 1231, 327686);
    try meta(3, 1015, 7);
    try rows("SELECT '{ 1 , 2 }'::int[], '{{1,2},{3,4}}'::int[], '[0:1]={5,6}'::int[], '{}'::int[], '{NULL, null}'::int[], '{\"a\\\"b\",c\\,d, \" e \"}'::text[]",
        "{1,2}|{{1,2},{3,4}}|[0:1]={5,6}|{}|{NULL,NULL}|{\"a\\\"b\",\"c,d\",\" e \"}");
    for ([_][]const u8{
        "SELECT '{1,2'::int[]",           "SELECT '{1,{2}}'::int[]",     "SELECT '1,2'::int[]",
        "SELECT '{{1,2},{3}}'::int[]",    "SELECT '{1}x'::int[]",        "SELECT '{a}'::int[]",
        "SELECT '[1:3]={1,2}'::int[]",    "SELECT '{\"a}'::text[]",      "SELECT '{1,,2}'::int[]",
        "SELECT ''::int[]",               "SELECT '{{1},2}'::int[]",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    try rejects("SELECT '{{{{{{{1}}}}}}}'::int[]", error.ProgramLimitExceeded);
    try sqlstate(error.ProgramLimitExceeded, "54000");

    // ARRAY[...] constructors: common element type, nesting, empty arrays.
    try rows("SELECT ARRAY[1,2], ARRAY[[1,2],[3,4]], ARRAY[ARRAY[1],ARRAY[2]], ARRAY['a','b'], ARRAY[1,2.5], ARRAY[NULL,1], ARRAY[]::int[], ARRAY[NULL]",
        "{1,2}|{{1,2},{3,4}}|{{1},{2}}|{a,b}|{1,2.5}|{NULL,1}|{}|{NULL}");
    try meta(0, 1007, -1);
    try meta(3, 1009, -1);
    try meta(4, 1231, -1);
    try meta(7, 1009, -1);
    try named(0, "array");
    try rejects("SELECT ARRAY[]", error.IndeterminateDatatype);
    try sqlstate(error.IndeterminateDatatype, "42P18");
    try rejects("SELECT ARRAY[[1,2],[3]]", error.ArraySubscriptError);
    try sqlstate(error.ArraySubscriptError, "2202E");
    try rejects("SELECT ARRAY[1,true]", error.TypeMismatch);
    try rejects("SELECT ARRAY[1,'x']", error.InvalidTextRepresentation);

    // Subscripts and slices (out of range and NULL subscripts are NULL;
    // subscripts are assignment-cast to int4; slices restart at 1).
    try rows("SELECT i[1], i[3], i[4], i[0], i[2:3], i[:2], i[2:] FROM a WHERE id = 1", "1|3|NULL|NULL|{2,3}|{1,2}|{2,3}");
    try meta(0, 23, -1);
    try meta(4, 1007, -1);
    try named(0, "i");
    try rows("SELECT i[3:2], i[NULL], i[1.5], i[1][1], i[1:1][1] FROM a WHERE id = 1", "{}|NULL|2|NULL|{}");
    try rows("SELECT t[2], v[2], b[2] FROM a WHERE id = 1", "b c|yz|f");
    try meta(1, 1043, 7);
    try rows("SELECT ('{{1,2},{3,4}}'::int[])[2][1], ('{{1,2},{3,4}}'::int[])[2], ('{{1,2},{3,4}}'::int[])[1:2][2:2], ('{{1,2},{3,4}}'::int[])[2:2][1], ('[0:2]={7,8,9}'::int[])[0], ('[0:2]={7,8,9}'::int[])[0:1]",
        "3|NULL|{{2},{4}}|{{3}}|7|{7,8}");
    try rejects("SELECT id[1] FROM a", error.TypeMismatch);
    try sqlstate(error.TypeMismatch, "42804");
    try rejects("SELECT i['x'] FROM a", error.InvalidTextRepresentation);

    // Functions.
    try rows("SELECT array_length(i, 1), array_length(i, 2), cardinality(i), array_ndims(i), array_dims(i), array_lower(i, 1), array_upper(i, 1) FROM a WHERE id = 1", "3|NULL|3|1|[1:3]|1|3");
    try meta(0, 23, -1);
    try meta(4, 25, -1);
    try named(0, "array_length");
    try rows("SELECT array_length('{}'::int[], 1), cardinality('{}'::int[]), array_ndims('{}'::int[]), array_dims('{}'::int[]), cardinality(ARRAY[[1,2],[3,4]]), array_dims('[0:1]={1,2}'::int[]), array_upper(ARRAY[[1,2,3]], 2)",
        "NULL|0|NULL|NULL|4|[0:1]|3");
    try rows("SELECT array_to_string(ARRAY[1,NULL,3], ','), array_to_string(ARRAY[1,NULL,3], ',', '*'), array_to_string(ARRAY['a','b'], '')", "1,3|1,*,3|ab");

    // Concatenation (array_cat/array_append/array_prepend are not strict).
    try rows("SELECT ARRAY[1,2] || 3, 0 || ARRAY[1,2], ARRAY[1] || ARRAY[2,3], ARRAY[[1,2]] || ARRAY[3,4], array_append(ARRAY[1], 2), array_prepend(0, ARRAY[1]), array_cat(ARRAY[1], NULL), NULL::int[] || ARRAY[1]",
        "{1,2,3}|{0,1,2}|{1,2,3}|{{1,2},{3,4}}|{1,2}|{0,1}|{1}|{1}");
    try rows("SELECT '[0:0]={1}'::int[] || ARRAY[2], '[0:0]={1}'::int[] || 2, array_append('{}'::int[], 1), array_append(NULL::int[], 1), ARRAY[1,2] || ARRAY[[3,4]]",
        "[0:1]={1,2}|[0:1]={1,2}|{1}|{1}|{{1,2},{3,4}}");
    try rejects("SELECT ARRAY[1] || ARRAY[[2,3]]", error.ArraySubscriptError);

    // Comparison, containment and quantified comparisons.
    try rows("SELECT ARRAY[1,2] = ARRAY[1,2], ARRAY[1,2] <> '{1,3}', ARRAY[1,2] < ARRAY[1,2,3], ARRAY[1,NULL] > ARRAY[1,2], ARRAY[2] > ARRAY[1,9], '[0:1]={1,2}'::int[] = ARRAY[1,2], ARRAY[1,2] IN (ARRAY[1,2], ARRAY[3])",
        "t|t|t|t|t|f|t");
    try rows("SELECT ARRAY[1,4,3] @> ARRAY[3,1], ARRAY[1,2] <@ ARRAY[1], ARRAY[1,2] && ARRAY[2,5], ARRAY[1] && ARRAY[3], ARRAY[NULL::int] @> ARRAY[NULL::int], ARRAY[1] @> '{}', ARRAY[[1,2],[3,4]] @> ARRAY[4]",
        "t|f|t|f|f|t|t");
    try rows("SELECT 2 = ANY(ARRAY[1,2]), 3 = ANY(ARRAY[1,NULL]), 1 <> ALL(ARRAY[2,3]), 1 = ANY('{}'::int[]), 1 = ANY(NULL::int[]), 2 > ALL(ARRAY[1,1]), 2 = ANY(ARRAY[1.5,2]), NULL = ANY(ARRAY[1])",
        "t|NULL|t|f|NULL|t|t|NULL");
    try rows("SELECT id FROM a WHERE 2 = ANY(i)", "1");
    try rejects("SELECT ARRAY[1] = ARRAY[1::int8]", error.UndefinedFunction);
    try rejects("SELECT 1 = ANY(ARRAY['a'])", error.UndefinedFunction);
    try rejects("SELECT 1 = ANY(1)", error.WrongObjectType);

    // Ordering (array_cmp: NULL elements sort last, then length, then
    // dimensions), grouping and hash consistency.
    try exec("INSERT INTO a(id, i) VALUES(2, ARRAY[1,2]), (3, '{1,2}'), (4, '{1,NULL}'), (5, '{}'), (6, NULL)");
    try rows("SELECT i FROM a ORDER BY i NULLS LAST", "{};{1,2};{1,2};{1,2,3};{1,NULL};NULL");
    try rows("SELECT i FROM a ORDER BY i DESC NULLS LAST", "{1,NULL};{1,2,3};{1,2};{1,2};{};NULL");
    try rows("SELECT i, COUNT(*) FROM a GROUP BY i ORDER BY i", "{}|1;{1,2}|2;{1,2,3}|1;{1,NULL}|1;NULL|1");
    try rows("SELECT COUNT(DISTINCT i), MIN(i), MAX(i) FROM a", "4|{}|{1,NULL}");
    try meta(1, 1007, -1);
    try rows("SELECT x.id, y.id FROM a x JOIN a y ON x.i = y.i AND x.id < y.id", "2|3");
    try rows("SELECT i[1] FROM a WHERE id = 6", "NULL");
    try exec("CREATE TABLE h(x NUMERIC[])");
    try exec("INSERT INTO h VALUES('{1.0}'), ('{1.00}'), ('{1}'), ('{2}')");
    try rows("SELECT COUNT(DISTINCT x) FROM h", "2");
    try rows("SELECT COUNT(*) FROM h GROUP BY x ORDER BY 1", "1;3");
    try exec("DROP TABLE h");

    // Casts: element-wise between array types, I/O with strings.
    try rows("SELECT i::text, i::bigint[], i::text[], '{1,2}'::int[]::numeric[], ARRAY[1.6,2.4]::int[], CAST(i AS VARCHAR(5)), '{7}'::text::int[] FROM a WHERE id = 1",
        "{1,2,3}|{1,2,3}|{1,2,3}|{1,2}|{2,2}|{1,2,|{7}");
    try meta(1, 1016, -1);
    try meta(2, 1009, -1);
    try rows("SELECT '{1,2}'::int[], ARRAY[1]::text[]", "{1,2}|{1}");
    try named(0, "int4");
    try named(1, "array");
    try rejects("SELECT ARRAY['1','x']::int[]", error.InvalidTextRepresentation);
    try rejects("SELECT ARRAY[1]::int", error.CannotCoerce);
    try rejects("SELECT 1::int[]", error.CannotCoerce);
    try sqlstate(error.CannotCoerce, "42846");
    // Assignment: element casts must exist in assignment context.
    try rejects("INSERT INTO a(id, i) VALUES(7, ARRAY['1'])", error.TypeMismatch);
    try exec("INSERT INTO a(id, i) VALUES(7, ARRAY[1::int8])");
    try rejects("INSERT INTO a(id, i) VALUES(8, ARRAY[3000000000])", error.IntegerOverflow);
    try rejects("INSERT INTO a(id, v) VALUES(8, '{abcd}')", error.StringDataRightTruncation);
    try rejects("INSERT INTO a(id, v) VALUES(8, ARRAY['abcd'])", error.StringDataRightTruncation);
    try rejects("INSERT INTO a(id, i) VALUES(8, '{1}'), (9, '{x}')", error.InvalidTextRepresentation);
    try exec("UPDATE a SET i = i || 4 WHERE id = 2");
    try rows("SELECT COUNT(*), MAX(id) FROM a", "7|7");
    try rows("SELECT i FROM a WHERE id IN (2, 7) ORDER BY id", "{1,2,4};{1}");

    // Capacity: an array is bounded by the cell's byte budget (text_bytes
    // 160 here: a 12-byte header and 5 bytes per int4 element).
    try rows("SELECT cardinality('{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29}'::int[])", "29");
    try rejects("SELECT '{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30}'::int[]", error.TextCapacity);
    try rejects("SELECT ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30]", error.TextCapacity);
    try sqlstate(error.TextCapacity, "54000");
    try exec("DROP TABLE a");

    // Defaults, CHECK constraints and keys over arrays.
    try exec("CREATE TABLE d(id INT[] PRIMARY KEY, tags TEXT[] DEFAULT '{}', n INT[] DEFAULT ARRAY[1,2] CHECK (cardinality(n) < 3))");
    try exec("INSERT INTO d(id) VALUES('{1,2}'), ('[0:1]={1,2}')");
    try rows("SELECT id, tags, n FROM d ORDER BY id", "[0:1]={1,2}|{}|{1,2};{1,2}|{}|{1,2}");
    try rows("SELECT column_default FROM information_schema.columns WHERE table_name = 'd' AND column_name = 'tags'", "'{}'::text[]");
    try rejects("INSERT INTO d(id) VALUES(ARRAY[1,2])", error.PrimaryKeyViolation);
    try rejects("INSERT INTO d VALUES('{3}', '{a}', '{1,2,3}')", error.CheckViolation);
    try rejects("UPDATE d SET n = n || 9", error.CheckViolation);
    try rows("SELECT COUNT(*) FROM d WHERE id = '{1,2}' OR id = ARRAY[7]", "1");
    try exec("DROP TABLE d");

    // Wire: array_send / array_recv with element OIDs and lengths.
    try exec("SELECT ARRAY[1,NULL,3], ARRAY['ab','c']");
    const ints = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 23, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 4, 0, 0, 0, 3 };
    const texts = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 25, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 'a', 'b', 0, 0, 0, 1, 'c' };
    const int_array = result.column_types[0];
    const text_array = result.column_types[1];
    try check(Wire.oid(int_array) == 1007 and Wire.length(int_array) == -1 and Wire.oid(text_array) == 1009);
    try sendText(&result.rows[0].cells[0], "{1,NULL,3}");
    try sendBinary(&result.rows[0].cells[0], int_array, &ints);
    try sendBinary(&result.rows[0].cells[1], text_array, &texts);
    try receive(&ints, int_array, "{1,NULL,3}");
    try receive(&texts, text_array, "{ab,c}");
    try receive(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 23 }, int_array, "{}");
    try literal(&ints, 1007, 1, "'{1,NULL,3}'::int4[]");
    try literal("{1}", 1009, 0, "'{1}'::text[]");
    var out: [64]u8 = undefined;
    // Wrong element type, truncated element, negative length and too many dimensions.
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 1 }, int_array, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(ints[0..38], int_array, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 23, 0, 0, 0, 1, 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xfe }, int_array, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 23 }, int_array, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability: change-record value tag 21 (element OID, shape, elements).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, i INT[], t TEXT[], v VARCHAR(2)[])",
        "INSERT INTO r VALUES(1, '{1,NULL,3}', '{a,\"b c\"}', '{x}'), (2, NULL, '{}', NULL), (3, '[0:1][1:2]={{1,2},{3,4}}', NULL, NULL)",
        "UPDATE r SET i = i || 4 WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|{1,NULL,3,4}|{a,\"b c\"}|{x};2|NULL|{}|NULL;3|[0:1][1:2]={{1,2},{3,4}}|NULL|NULL");
    try meta(1, 1007, -1);
    try meta(3, 1015, 6);
}

// ---- ranges ------------------------------------------------------------------

fn ranges() !void {
    // oracle: PG.TYPE.RANGE.
    try exec("CREATE TABLE tdd_type(v INT4RANGE)");
    try exec("INSERT INTO tdd_type VALUES('[1,3)'),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "[1,3);NULL");
    try meta(0, 3904, -1);
    try exec("DROP TABLE tdd_type");

    // range_in forms; discrete subtypes canonicalize to [lower, upper).
    try rows("SELECT '[1,3]'::int4range, '(1,3)'::int4range, '(1,3]'::int4range, '[1,1)'::int4range, '[3,3]'::int4range, ' empty '::int4range, '(,5)'::int4range, '[,]'::int4range",
        "[1,4)|[2,3)|[2,4)|empty|[3,4)|empty|(,5)|(,)");
    try rows("SELECT '[1.5,2.5]'::numrange, '(1.5,1.5]'::numrange, '[2026-01-01,2026-01-03]'::daterange, '[ 1, 3)'::int4range, '[\"1\",\"3\")'::int8range",
        "[1.5,2.5]|empty|[2026-01-01,2026-01-04)|[1,3)|[1,3)");
    try rows("SELECT '[2026-01-01 10:00,2026-01-01 11:00)'::tsrange, '[2026-01-01 10:00+00,)'::tstzrange", "[\"2026-01-01 10:00:00\",\"2026-01-01 11:00:00\")|[\"2026-01-01 10:00:00+00\",)");
    try meta(0, 3908, -1);
    try meta(1, 3910, -1);
    for ([_][]const u8{
        "SELECT '1,3'::int4range",       "SELECT '[1,3'::int4range",     "SELECT '[1,3)x'::int4range",
        "SELECT '[1,2,3)'::int4range",   "SELECT '[a,3)'::int4range",    "SELECT ''::int4range",
        "SELECT 'emptyx'::int4range",    "SELECT '[1\"'::int4range",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    try rejects("SELECT '[3,1)'::int4range", error.DataException);
    try sqlstate(error.DataException, "22000");
    try rejects("SELECT '[1,2147483647]'::int4range", error.IntegerOverflow);

    // Constructors: (lower, upper [, bounds]), NULL bounds are infinite.
    try rows("SELECT int4range(1, 3), int4range(1, 3, '[]'), numrange(1.5, NULL, '()'), int8range(NULL, NULL), daterange('2026-01-01', '2026-01-02', '(]'), int4range(5, 5)",
        "[1,3)|[1,4)|(1.5,)|(,)|[2026-01-02,2026-01-03)|empty");
    try meta(0, 3904, -1);
    try meta(2, 3906, -1);
    try named(0, "int4range");
    try rejects("SELECT int4range(1, 3, 'x')", error.Syntax);
    try rejects("SELECT int4range(3, 1)", error.DataException);
    try rejects("SELECT int4range(1, 'x')", error.InvalidTextRepresentation);

    // Accessors.
    try rows("SELECT lower(int4range(1, 3)), upper(int4range(1, 3)), lower('(,3)'::int4range), isempty('empty'::int4range), lower_inc('[1,3)'::numrange), upper_inc('[1,3]'::numrange), lower_inf('(,3)'::int4range), upper_inf('empty'::int4range)",
        "1|3|NULL|t|t|t|t|f");
    try meta(0, 23, -1);
    try rows("SELECT upper('[1.5,2]'::numrange), lower('empty'::numrange)", "2|NULL");
    try meta(0, 1700, -1);

    // Operators.
    try rows("SELECT int4range(1, 5) @> 3, int4range(1, 5) @> 5, 3 <@ int4range(1, 5), int4range(1, 5) @> int4range(2, 3), int4range(2, 3) <@ int4range(1, 5), int4range(1, 5) @> 'empty'::int4range, 'empty'::int4range @> int4range(1, 2)",
        "t|f|t|t|t|t|f");
    try rows("SELECT int4range(1, 5) && int4range(4, 9), int4range(1, 5) && int4range(5, 9), int4range(1, 5) << int4range(5, 9), int4range(5, 9) >> int4range(1, 5), int4range(1, 5) -|- int4range(5, 9), numrange(1, 2) -|- numrange(2, 3, '()'), int4range(1, 5) &< int4range(1, 6), int4range(1, 5) &> int4range(0, 6)",
        "t|f|t|t|t|f|t|t");
    try rows("SELECT int4range(1, 5) + int4range(5, 9), int4range(1, 5) * int4range(3, 9), int4range(1, 9) - int4range(5, 12), int4range(1, 5) * int4range(6, 9), numrange(1, 5) - numrange(3, 9)",
        "[1,9)|[3,5)|[1,5)|empty|[1,3)");
    try rejects("SELECT int4range(1, 3) + int4range(5, 9)", error.DataException);
    try rejects("SELECT int4range(1, 9) - int4range(3, 5)", error.DataException);
    try rejects("SELECT int4range(1, 3) @> 'x'", error.InvalidTextRepresentation);
    try rejects("SELECT int4range(1, 3) = numrange(1, 3)", error.UndefinedFunction);

    // Ordering (empty first, then bounds), equality after canonicalization,
    // grouping and hash consistency.
    try exec("CREATE TABLE g(id INT PRIMARY KEY, r INT4RANGE, d DATERANGE)");
    try exec("INSERT INTO g VALUES(1, '[1,5)', '[2026-01-01,2026-02-01)'), (2, '[1,4]', NULL), (3, 'empty', 'empty'), (4, '(,3)', NULL), (5, '[1,3)', '(,)'), (6, NULL, NULL), (7, '[0,)', NULL)");
    try rows("SELECT r FROM g ORDER BY r NULLS LAST", "empty;(,3);[0,);[1,3);[1,5);[1,5);NULL");
    try rows("SELECT r, COUNT(*) FROM g GROUP BY r ORDER BY r", "empty|1;(,3)|1;[0,)|1;[1,3)|1;[1,5)|2;NULL|1");
    try rows("SELECT COUNT(DISTINCT r) FROM g", "5");
    try rows("SELECT id FROM g WHERE r = '[1,4]' ORDER BY id", "1;2");
    try rows("SELECT id FROM g WHERE r @> 4 ORDER BY id", "1;2;7");
    try rows("SELECT id FROM g WHERE d @> '2026-01-15'::date ORDER BY id", "1;5");
    try rows("SELECT x.id, y.id FROM g x JOIN g y ON x.r = y.r AND x.id < y.id", "1|2");
    try rows("SELECT d FROM g WHERE id IN (1, 3, 5) ORDER BY d", "empty;(,);[2026-01-01,2026-02-01)");
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'g' AND column_name = 'r'", "int4range");
    try rows("SELECT typname, typlen, typcategory, typarray, typinput FROM pg_type WHERE oid IN (3904, 3912) ORDER BY oid", "int4range|-1|R|3905|range_in;daterange|-1|R|3913|range_in");
    try rows("SELECT format_type(3906, NULL), 'tstzrange'::regtype::oid, 3926::regtype::text", "numrange|3910|int8range");
    // Assignment and atomicity.
    try rejects("INSERT INTO g(id, r) VALUES(8, '[1,3)'), (9, '[5,2)')", error.DataException);
    try rejects("INSERT INTO g(id, r) VALUES(8, numrange(1, 3))", error.TypeMismatch);
    try rejects("UPDATE g SET r = r + int4range(100, 101) WHERE id = 1", error.DataException);
    try rows("SELECT COUNT(*) FROM g", "7");
    try rows("SELECT r::text, '[1,2)'::text::int4range, ARRAY['[1,2)'::int4range, 'empty'] FROM g WHERE id = 1", "[1,5)|[1,2)|{\"[1,2)\",empty}");
    try rejects("SELECT 1::int4range", error.CannotCoerce);
    try exec("DROP TABLE g");

    // Wire: range_send (flags byte, then length-prefixed bound values).
    try exec("SELECT int4range(1, 3), 'empty'::int4range, numrange(NULL, 2.5, '(]')");
    const finite = [_]u8{ 0x02, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 3 };
    const int4range = result.column_types[0];
    try check(Wire.oid(int4range) == 3904 and Wire.length(int4range) == -1);
    try sendText(&result.rows[0].cells[0], "[1,3)");
    try sendBinary(&result.rows[0].cells[0], int4range, &finite);
    try sendBinary(&result.rows[0].cells[1], int4range, &.{0x01});
    try sendBinary(&result.rows[0].cells[2], result.column_types[2], &.{ 0x0c, 0, 0, 0, 12, 0, 2, 0, 0, 0, 0, 0, 1, 0, 2, 0x13, 0x88 });
    try receive(&finite, int4range, "[1,3)");
    try receive(&.{0x01}, int4range, "empty");
    try literal(&finite, 3904, 1, "'[1,3)'::int4range");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(finite[0..16], int4range, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(&.{ 0x02, 0, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 1 }, int4range, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability: change-record value tag 22.
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, a INT4RANGE, n NUMRANGE, t TSTZRANGE)",
        "INSERT INTO r VALUES(1, '[1,10]', '(1.5,)', '[2026-01-01 00:00+00,2026-01-02 00:00+00)'), (2, 'empty', NULL, '(,)'), (3, NULL, 'empty', NULL)",
        "UPDATE r SET a = a * int4range(5, 20) WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|[5,11)|(1.5,)|[\"2026-01-01 00:00:00+00\",\"2026-01-02 00:00:00+00\");2|empty|NULL|(,);3|NULL|empty|NULL");
    try meta(1, 3904, -1);
    try meta(2, 3906, -1);
}

// ---- inet / cidr / macaddr -------------------------------------------------------

fn network() !void {
    // oracle: PG.TYPE.NETWORK.
    try exec("CREATE TABLE tdd_type(v INET)");
    try exec("INSERT INTO tdd_type VALUES('192.0.2.1'),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "192.0.2.1;NULL");
    try meta(0, 869, -1);
    try exec("DROP TABLE tdd_type");

    // inet: a full-length netmask is not printed; IPv6 compresses zeros.
    try rows("SELECT '192.0.2.1/24'::inet, '10.1/16'::inet, '010.0.0.1'::inet, '::1'::inet, '2001:DB8::/32'::inet, '::ffff:1.2.3.4'::inet, '1:0:0:0:0:0:0:8'::inet, 'fe80::1:2/64'::inet",
        "192.0.2.1/24|10.1.0.0/16|10.0.0.1|::1|2001:db8::/32|::ffff:1.2.3.4|1::8|fe80::1:2/64");
    try meta(0, 869, -1);
    // cidr: always a netmask length; classful defaults; no bits right of it.
    try rows("SELECT '192.168.1.0/24'::cidr, '10'::cidr, '192.168.1'::cidr, '128.1'::cidr, '10.1.2.3/32'::cidr, '2001:db8::/32'::cidr, '224'::cidr, '::'::cidr",
        "192.168.1.0/24|10.0.0.0/8|192.168.1.0/24|128.1.0.0/16|10.1.2.3/32|2001:db8::/32|224.0.0.0/4|::/128");
    try meta(0, 650, -1);
    for ([_][]const u8{
        "SELECT '192.168.1.1/24'::cidr",  "SELECT '1.2.3'::inet",         "SELECT '256.0.0.1'::inet",
        "SELECT '1.2.3.4/33'::inet",      "SELECT '1::2::3'::inet",       "SELECT '::g'::inet",
        "SELECT ''::inet",                "SELECT '1.2.3.4 '::inet",      "SELECT '10.1/24'::inet",
        "SELECT '1:2:3:4:5:6:7:8:9'::inet", "SELECT '1.2.3.4/'::inet",    "SELECT 'x'::cidr",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    // macaddr: seven input layouts, lower-case colon output.
    try rows("SELECT '08:00:2b:01:02:03'::macaddr, '08-00-2B-01-02-03'::macaddr, '08002b:010203'::macaddr, '08002b-010203'::macaddr, '0800.2b01.0203'::macaddr, '0800-2b01-0203'::macaddr, '08002b010203'::macaddr",
        "08:00:2b:01:02:03|08:00:2b:01:02:03|08:00:2b:01:02:03|08:00:2b:01:02:03|08:00:2b:01:02:03|08:00:2b:01:02:03|08:00:2b:01:02:03");
    try meta(0, 829, -1);
    for ([_][]const u8{ "SELECT '08:00:2b:01:02'::macaddr", "SELECT '08:00:2b:01:02:0g'::macaddr", "SELECT '0800:2b01:0203'::macaddr", "SELECT ''::macaddr" }) |source|
        try rejects(source, error.InvalidTextRepresentation);

    // Functions and casts.
    try rows("SELECT host('192.0.2.1/24'::inet), masklen('192.0.2.1/24'::inet), family('::1'::inet), network('192.0.2.1/24'::inet), broadcast('192.0.2.1/24'::inet), netmask('192.0.2.1/24'::inet), '192.0.2.1'::inet::text, '10.0.0.1/8'::inet::cidr",
        "192.0.2.1|24|6|192.0.2.0/24|192.0.2.255/24|255.255.255.0|192.0.2.1/32|10.0.0.0/8");
    try meta(0, 25, -1);
    try meta(1, 23, -1);
    try meta(3, 650, -1);
    try meta(4, 869, -1);
    try meta(7, 650, -1);
    try rows("SELECT '10.0.0.0/8'::cidr::inet, host('::ffff:1.2.3.4/120'::inet), '08:00:2b:01:02:03'::macaddr::text", "10.0.0.0/8|::ffff:1.2.3.4|08:00:2b:01:02:03");
    try rejects("SELECT 1::inet", error.CannotCoerce);
    try rejects("SELECT '1.2.3.4'::inet = '1.2.3.4'::text", error.UndefinedFunction);
    try rejects("SELECT '1.2.3.4'::inet = '08:00:2b:01:02:03'::macaddr", error.UndefinedFunction);

    // Containment operators.
    try rows("SELECT '192.168.1.5'::inet << '192.168.1.0/24'::inet, '192.168.1.0/24'::inet << '192.168.1.0/24'::inet, '192.168.1.0/24'::inet <<= '192.168.1.0/24'::inet, '192.168.1.0/24'::cidr >> '192.168.1.5'::inet, '192.168.1.0/24'::inet >>= '192.168.1.0/24'::inet, '192.168.1.0/24'::inet && '192.168.0.0/16'::inet, '10.0.0.0/8'::inet && '192.168.0.0/16'::inet, '::1'::inet << '0.0.0.0/0'::inet",
        "t|f|t|t|t|t|f|f");

    // Ordering (IPv4 first, then the common prefix, then the length),
    // grouping, hash consistency and inet/cidr comparisons.
    try exec("CREATE TABLE n(id INT PRIMARY KEY, a INET, c CIDR, m MACADDR)");
    try exec("INSERT INTO n VALUES(1, '10.0.0.1', '10.0.0.0/8', '08:00:2b:01:02:03'), (2, '10.0.0.1/8', '10.0.0.0/16', '08:00:2b:01:02:04'), (3, '::1', '::/0', NULL), (4, '9.255.255.255', '10.0.0.0/8', '00:00:00:00:00:00'), (5, NULL, NULL, '08-00-2b-01-02-03')");
    try rows("SELECT a FROM n ORDER BY a NULLS LAST", "9.255.255.255;10.0.0.1/8;10.0.0.1;::1;NULL");
    try rows("SELECT c FROM n ORDER BY c NULLS LAST", "10.0.0.0/8;10.0.0.0/8;10.0.0.0/16;::/0;NULL");
    try rows("SELECT m, COUNT(*) FROM n GROUP BY m ORDER BY m", "00:00:00:00:00:00|1;08:00:2b:01:02:03|2;08:00:2b:01:02:04|1;NULL|1");
    try rows("SELECT COUNT(DISTINCT c), COUNT(DISTINCT a), MIN(a), MAX(a) FROM n", "3|4|9.255.255.255|::1");
    try rows("SELECT id FROM n WHERE a <<= c ORDER BY id", "1;3");
    try rows("SELECT id FROM n WHERE a = '10.0.0.1/32' OR c = '10.0.0.0/16'::inet ORDER BY id", "1;2");
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'n' ORDER BY ordinal_position", "integer;inet;cidr;macaddr");
    try rejects("INSERT INTO n(id, c) VALUES(6, '10.0.0.1/8')", error.InvalidTextRepresentation);
    try exec("INSERT INTO n(id, c) VALUES(6, '10.0.0.1/8'::inet)");
    try rows("SELECT c FROM n WHERE id = 6", "10.0.0.0/8");
    try rejects("INSERT INTO n(id, a) VALUES(7, '1.1.1.1'), (8, 'bad')", error.InvalidTextRepresentation);
    try rows("SELECT COUNT(*) FROM n", "6");
    try rows("SELECT typname, typlen, typcategory, typarray FROM pg_type WHERE oid IN (650, 829, 869) ORDER BY oid", "cidr|-1|I|651;macaddr|6|U|1040;inet|-1|I|1041");
    try exec("DROP TABLE n");

    // Wire: inet_send {family 2/3, bits, is_cidr, size, address}; macaddr 6 bytes.
    try exec("SELECT '192.0.2.1/24'::inet, '10.0.0.0/8'::cidr, '08:00:2b:01:02:03'::macaddr, '::1'::inet");
    const inet_bytes = [_]u8{ 2, 24, 0, 4, 192, 0, 2, 1 };
    const cidr_bytes = [_]u8{ 2, 8, 1, 4, 10, 0, 0, 0 };
    const mac_bytes = [_]u8{ 8, 0, 0x2b, 1, 2, 3 };
    const v6_bytes = [_]u8{ 3, 128, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try check(Wire.oid(.inet) == 869 and Wire.oid(.cidr) == 650 and Wire.oid(.macaddr) == 829 and Wire.length(.macaddr) == 6 and Wire.length(.inet) == -1);
    try sendBinary(&result.rows[0].cells[0], .inet, &inet_bytes);
    try sendBinary(&result.rows[0].cells[1], .cidr, &cidr_bytes);
    try sendBinary(&result.rows[0].cells[2], .macaddr, &mac_bytes);
    try sendBinary(&result.rows[0].cells[3], .inet, &v6_bytes);
    try receive(&inet_bytes, .inet, "192.0.2.1/24");
    try receive(&cidr_bytes, .cidr, "10.0.0.0/8");
    try receive(&mac_bytes, .macaddr, "08:00:2b:01:02:03");
    // receiveText renders the text(inet) cast form, which inet_in reads back.
    try receive(&v6_bytes, .inet, "::1/128");
    try literal(&inet_bytes, 869, 1, "'192.0.2.1/24'::inet");
    try literal("10/8", 650, 0, "'10/8'::cidr");
    var out: [64]u8 = undefined;
    for ([_][]const u8{ &.{ 2, 24, 0, 16, 192, 0, 2, 1 }, &.{ 4, 24, 0, 4, 192, 0, 2, 1 }, &.{ 2, 33, 0, 4, 192, 0, 2, 1 }, inet_bytes[0..7] }) |bad|
        try check(if (Wire.receiveText(bad, .inet, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(mac_bytes[0..5], .macaddr, &out)) |_| false else |err| err == error.ProtocolViolation);
    // A cidr value must not have bits set right of its mask; inet ignores the flag byte.
    try check(if (Wire.receiveText(&.{ 2, 8, 1, 4, 10, 0, 0, 1 }, .cidr, &out)) |_| false else |err| err == error.ProtocolViolation);
    try receive(&.{ 2, 8, 1, 4, 10, 0, 0, 1 }, .inet, "10.0.0.1/8");

    // Durability: change-record value tags 23 (inet/cidr) and 24 (macaddr).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, a INET, c CIDR, m MACADDR)",
        "INSERT INTO r VALUES(1, '2001:db8::1/64', '192.168.0.0/16', '08:00:2b:01:02:03'), (2, NULL, NULL, NULL), (3, '1.2.3.4', '::/0', 'ff:ff:ff:ff:ff:ff')",
        "UPDATE r SET a = broadcast(a) WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|2001:db8::ffff:ffff:ffff:ffff/64|192.168.0.0/16|08:00:2b:01:02:03;2|NULL|NULL|NULL;3|1.2.3.4|::/0|ff:ff:ff:ff:ff:ff");
    try meta(1, 869, -1);
    try meta(2, 650, -1);
    try meta(3, 829, -1);
}

pub fn main(init: std.process.Init) !void {
    try catalogIds();
    try arrays();
    try ranges();
    try network();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types-advanced\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
