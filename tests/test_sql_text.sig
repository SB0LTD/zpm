//! Text contract (conformance lane B11 "text"): discovery functions
//! (pg_typeof, pg_get_serial_sequence), COLLATE and collation derivation,
//! POSIX regular expressions (~, ~*, !~, !~*, SIMILAR TO, regexp_like) and
//! full text search (tsvector, tsquery, to_tsvector/to_tsquery and @@).
//! Every section checks values in PostgreSQL text output, result metadata
//! (type OID, typmod, column name), NULLs, exact errors (SQLSTATE through
//! the error name) with statement atomicity, the statement work budget and
//! cancellation checkpoints where evaluation can be long, the wire
//! representation of new types and change-record replay compared with
//! sameDatabase/sameCatalog.
//!
//! Fixtures copied from tests/sql_conformance/postgres18_oracle.json are
//! marked "oracle". Every other expectation follows PostgreSQL 18.3 and is
//! PENDING NATIVE VERIFICATION: it was checked by hand against a local
//! PostgreSQL 18.3 build (database LOCALE 'C', UTF8), which is not a
//! recorded oracle run.
const std = @import("std");
const sql = @import("sql");
const pg_types = @import("pg_types");

const DB = sql.Database(.{ .tables = 6, .columns = 8, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 256, .integer_bits = 32, .nulls_first_ascending = false, .sequences = 8, .expr_nodes = 1024, .work_rows = 128, .result_rows = 48 });
const Io = DB.Io;
const Wire = pg_types.Types(DB.Result);
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("text contract failed at assertion {d}\n", .{assertions});
        return error.SqlTextContractFailed;
    }
}

fn exec(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

var text_buffer: [8192]u8 = undefined;
/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
fn render(target: *const DB.Result, session: *const sql.Session) ![]const u8 {
    var at: usize = 0;
    for (0..target.row_count) |index| {
        if (index != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[index].cells[column];
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, session, &buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn shown(source: []const u8, expected: []const u8) !void {
    const got = try render(&result, &db.session);
    if (!std.mem.eql(u8, got, expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, got, expected });
    try check(std.mem.eql(u8, got, expected));
}

/// Every row of a query, columns joined by '|' and rows by ';'.
fn rows(source: []const u8, expected: []const u8) !void {
    try exec(source);
    try shown(source, expected);
}

/// Result column `index` has this type OID, typmod and name.
fn meta(index: usize, name: []const u8, oid: u32, typmod: i32) !void {
    const got_oid = sql.typeOid(result.column_types[index]);
    const got_name = result.column_names[index].slice();
    const ok = got_oid == oid and result.column_typmods[index] == typmod and std.mem.eql(u8, got_name, name);
    if (!ok) std.debug.print("column {d}: got {s} oid {d} typmod {d}, expected {s} {d} {d}\n", .{ index, got_name, got_oid, result.column_typmods[index], name, oid, typmod });
    try check(ok);
}

/// The statement fails with `wanted`; the previous result is untouched and
/// no transaction state leaks (statement atomicity).
fn rejects(source: []const u8, wanted: anyerror) !void {
    const saved = db.session.control;
    db.session.control = null;
    try exec("SELECT 4242");
    db.session.control = saved;
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(result.row_count == 1 and result.column_count == 1 and result.rows[0].cells[0].integer == 4242);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0 and usage.row_locks == 0);
}

/// SQLSTATEs of the errors this contract expects, as src/db/postgres.sig
/// knownSqlstate maps them (test_postgres checks that every engine error is
/// mapped; this pins the exact codes).
fn sqlstate(err: anyerror, wanted: []const u8) !void {
    const table = [_]struct { name: []const u8, state: []const u8 }{
        .{ .name = "InvalidTextRepresentation", .state = "22P02" },
        .{ .name = "NumericValueOutOfRange", .state = "22003" },
        .{ .name = "DivisionByZero", .state = "22012" },
        .{ .name = "UndefinedFunction", .state = "42883" },
        .{ .name = "UndefinedObject", .state = "42704" },
        .{ .name = "TableNotFound", .state = "42P01" },
        .{ .name = "ColumnNotFound", .state = "42703" },
        .{ .name = "TypeMismatch", .state = "42804" },
        .{ .name = "UnsupportedStatement", .state = "0A000" },
        .{ .name = "QueryWorkLimit", .state = "54000" },
        .{ .name = "QueryCanceled", .state = "57014" },
        .{ .name = "CollationMismatch", .state = "42P21" },
        .{ .name = "UndefinedSchema", .state = "3F000" },
    };
    var state: []const u8 = "?";
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, @errorName(err))) state = entry.state;
    }
    if (!std.mem.eql(u8, state, wanted)) std.debug.print("{s}: SQLSTATE {s}, expected {s}\n", .{ @errorName(err), state, wanted });
    try check(std.mem.eql(u8, state, wanted));
}

const Cancel = struct {
    remaining: usize,
    fn poll(raw: ?*anyopaque) sql.Error!void {
        const self: *Cancel = @ptrCast(@alignCast(raw.?));
        if (self.remaining == 0) return error.QueryCanceled;
        self.remaining -= 1;
    }
};

/// Every work budget below the statement's need fails with exactly
/// QueryWorkLimit (54000) at that budget, every cancellation point with
/// QueryCanceled (57014), and an unbudgeted rerun returns `wanted` again.
fn controlled(source: []const u8, wanted: []const u8) !void {
    try rows(source, wanted);
    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    defer db.session.control = null;
    try exec(source);
    const used = control.used;
    try check(used > 0);
    var limit: u64 = 1;
    while (limit < used) : (limit += @max(1, used / 97)) {
        control.reset(limit);
        try rejects(source, error.QueryWorkLimit);
        try check(control.used == limit);
    }
    var cancel: Cancel = .{ .remaining = 0 };
    control.context = &cancel;
    control.poll = Cancel.poll;
    control.poll_interval = 1;
    var point: usize = 0;
    while (point < used) : (point += @max(1, used / 61)) {
        cancel.remaining = point;
        control.reset(0);
        try rejects(source, error.QueryCanceled);
    }
    db.session.control = null;
    try rows(source, wanted);
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

/// Logical equality of two databases over `tables`: table count, OID
/// counter, live rows, next rowids and every row.
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

/// Replays `statements` from a fresh primary into a replica through change
/// records; both must hold the same database and catalog and answer
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
    const got = try render(&result, &replica.session);
    @memcpy(replayed[0..got.len], got);
    replayed_len = got.len;
}

var replayed: [8192]u8 = undefined;
var replayed_len: usize = 0;

/// The replica's answer of the last replay().
fn replicaShows(expected: []const u8) !void {
    const got = replayed[0..replayed_len];
    if (!std.mem.eql(u8, got, expected)) std.debug.print("replica\n  got:      {s}\n  expected: {s}\n", .{ got, expected });
    try check(std.mem.eql(u8, got, expected));
}

fn baseFixture() !void {
    // The conformance driver's `base` fixture (cases.json).
    try exec("CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)");
    try exec("INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)");
    try exec("CREATE TABLE tdd_b(id INT PRIMARY KEY,v INT)");
    try exec("INSERT INTO tdd_b VALUES(1,11),(3,33),(5,55)");
}

// ---- discovery functions ------------------------------------------------------

fn discovery() !void {
    // oracle: PG.FUNC.DISCOVERY.
    try rows("SELECT pg_typeof(1),pg_get_serial_sequence('tdd_a','id')", "integer|NULL");
    try meta(0, "pg_typeof", 2206, -1);
    try meta(1, "pg_get_serial_sequence", 25, -1);

    // pg_typeof reports the argument's declared type (format_type spelling);
    // untyped literals and NULL are unknown. It is not strict.
    try rows("SELECT pg_typeof(1), pg_typeof('a'), pg_typeof(NULL), pg_typeof(1.5), pg_typeof('a'::varchar(3)), pg_typeof(ARRAY[1]), pg_typeof('2020-01-01 00:00+00'::timestamptz), pg_typeof(pg_typeof(1))",
        "integer|unknown|unknown|numeric|character varying|integer[]|timestamp with time zone|regtype");
    try rows("SELECT pg_typeof('x'::text), pg_typeof('x'::name), pg_typeof(1::int2), pg_typeof(true), pg_typeof('1 day'::interval), pg_typeof(1.5::float4), pg_typeof('x'::bpchar), pg_typeof(NULL::int)",
        "text|name|smallint|boolean|interval|real|character|integer");
    try rows("SELECT pg_typeof(id), pg_typeof(v + 0.5), pg_typeof(COUNT(*)) FROM tdd_a GROUP BY id, v ORDER BY id LIMIT 1", "integer|numeric|bigint");
    // Its argument is evaluated.
    try rejects("SELECT pg_typeof(1/0)", error.DivisionByZero);
    try sqlstate(error.DivisionByZero, "22012");

    // regtype: oid's operators (binary coercible), so an untyped literal is
    // read as an oid; casts to oid/int4/int8 and text, regtype output of
    // OIDs without a type.
    try rows("SELECT pg_typeof(1)::text, pg_typeof(1)::oid, pg_typeof(1) = 23, pg_typeof(1) < pg_typeof(1::int8), pg_typeof(1) = pg_typeof(2), pg_typeof(1)::int4, pg_typeof(1)::int8", "integer|23|t|f|t|23|23");
    try meta(0, "pg_typeof", 25, -1);
    try rejects("SELECT pg_typeof(1) = 'integer'", error.InvalidTextRepresentation);
    try sqlstate(error.InvalidTextRepresentation, "22P02");
    try rows("SELECT (-1)::regtype::text, pg_typeof(1) IS NULL", "4294967295|f");
    try rows("SELECT pg_typeof(v), COUNT(*) FROM (VALUES (1), (2)) x(v) GROUP BY 1", "integer|2");
    try rows("SELECT t FROM (SELECT pg_typeof(1::int8) AS t UNION SELECT pg_typeof(1)) u ORDER BY t", "bigint;integer");

    // pg_get_serial_sequence: SERIAL and identity columns own a sequence;
    // the table is regclass text, the column an exact name.
    try exec("CREATE TABLE s1(id SERIAL, b BIGSERIAL, c INT GENERATED ALWAYS AS IDENTITY, \"MiX\" SERIAL, d INT)");
    try rows("SELECT pg_get_serial_sequence('s1','id'), pg_get_serial_sequence('s1','b'), pg_get_serial_sequence('S1','c'), pg_get_serial_sequence('s1','MiX'), pg_get_serial_sequence('s1','d'), pg_get_serial_sequence('public.s1','id')",
        "public.s1_id_seq|public.s1_b_seq|public.s1_c_seq|public.\"s1_MiX_seq\"|NULL|public.s1_id_seq");
    try rows("SELECT pg_get_serial_sequence(NULL,'id'), pg_get_serial_sequence('s1', NULL)", "NULL|NULL");
    try rejects("SELECT pg_get_serial_sequence('s1','ID')", error.ColumnNotFound);
    try sqlstate(error.ColumnNotFound, "42703");
    try rejects("SELECT pg_get_serial_sequence('nope','id')", error.TableNotFound);
    try rejects("SELECT pg_get_serial_sequence('\"S1\"','id')", error.TableNotFound);
    try sqlstate(error.TableNotFound, "42P01");
    try exec("CREATE TABLE \"Mx\"(id SERIAL)");
    try rows("SELECT pg_get_serial_sequence('\"Mx\"','id')", "public.\"Mx_id_seq\"");
    try exec("DROP TABLE \"Mx\"");
    try exec("DROP TABLE s1");

    // Wire: regtype is oidsend in binary and the type name in text.
    try exec("SELECT pg_typeof(1)");
    try check(Wire.oid(.regtype) == 2206 and Wire.length(.regtype) == 4);
    try sendText(&result.rows[0].cells[0], "integer");
    try sendBinary(&result.rows[0].cells[0], .regtype, &.{ 0, 0, 0, 23 });
    try receive(&.{ 0, 0, 0, 23 }, .regtype, "integer");

    // Durability: a regtype column (CREATE TABLE AS) uses value tag 30.
    try replay(&.{
        "CREATE TABLE rt AS SELECT pg_typeof(1) AS t, pg_typeof('a'::text) AS u",
        "INSERT INTO rt SELECT pg_typeof(1::int8), NULL",
    }, &.{"rt"}, "SELECT t, u, pg_typeof(t) FROM rt ORDER BY t");
    try replicaShows("bigint|NULL|regtype;integer|text|regtype");
}

// ---- collations -------------------------------------------------------------

fn collations() !void {
    // oracle: PG.TEXT.COLLATION.
    try rows("SELECT 'a' COLLATE \"C\" < 'b' COLLATE \"C\"", "t");
    try meta(0, "?column?", 16, -1);

    // The built-in collations this C database honours; an untyped literal
    // stays unknown under COLLATE and is text in the result.
    try rows("SELECT 'a' COLLATE pg_catalog.\"C\", 'a' COLLATE \"default\", 'a' COLLATE \"POSIX\", 'a' COLLATE ucs_basic, 'b' COLLATE \"C\" COLLATE \"POSIX\"", "a|a|a|a|b");
    try meta(0, "?column?", 25, -1);
    try rows("SELECT pg_typeof('a' COLLATE \"C\"), 'a' COLLATE \"C\" || 'b' COLLATE \"C\", pg_typeof('a' COLLATE \"C\" || 'b'), NULL COLLATE \"C\"", "unknown|ab|text|NULL");
    // A literal coerced to a non-collatable type drops the clause.
    try rows("SELECT '1' COLLATE \"C\" = 1, '1' COLLATE \"C\" + 1", "t|2");
    try rows("SELECT ARRAY['a'] COLLATE \"C\", ('a'::name) COLLATE \"POSIX\", 'a'::varchar COLLATE \"C\", 'a'::char(2) COLLATE \"C\"", "{a}|a|a|a ");
    try meta(1, "name", 19, -1);
    try meta(2, "varchar", 1043, -1);
    try meta(3, "bpchar", 1042, 6);
    try rows("SELECT x FROM (VALUES ('b'), ('B'), ('a')) v(x) ORDER BY x COLLATE \"C\"", "B;a;b");
    try rows("SELECT x FROM (VALUES ('b'), ('B'), ('a')) v(x) ORDER BY x COLLATE \"POSIX\" DESC", "b;a;B");
    try rows("SELECT max('a' COLLATE \"C\"), 'a' COLLATE \"C\" BETWEEN 'a' AND 'b', 'x' COLLATE \"C\" = 'x' COLLATE \"C\"", "a|t|t");
    try rows("SELECT 1 WHERE 'a' COLLATE \"C\" IN ('a', 'b' COLLATE \"C\")", "1");
    // Boolean results carry no collation: their operands may differ.
    try rows("SELECT ('a' COLLATE \"C\" = 'b') = ('a' COLLATE \"POSIX\" = 'b'), 'a' < 'b' COLLATE \"C\" COLLATE \"POSIX\"", "t|t");
    try rows("SELECT x FROM (SELECT 'a' COLLATE \"C\" AS x) s WHERE x < 'b' COLLATE \"POSIX\"", "a");

    // 42P21: different explicit collations meeting in one expression.
    for ([_][]const u8{
        "SELECT 'a' COLLATE \"default\" < 'b' COLLATE \"C\"",
        "SELECT ('a' COLLATE \"C\") < ('b' COLLATE \"POSIX\")",
        "SELECT CASE WHEN true THEN 'a' COLLATE \"C\" ELSE 'b' COLLATE \"POSIX\" END",
        "SELECT 'a' COLLATE \"C\" IN ('a' COLLATE \"POSIX\")",
        "SELECT COALESCE('a' COLLATE \"C\", 'b' COLLATE \"POSIX\")",
        "SELECT 'a' COLLATE \"C\" LIKE 'a' COLLATE \"POSIX\"",
        "SELECT GREATEST('a' COLLATE \"C\", 'b' COLLATE \"POSIX\")",
        "SELECT NULLIF('a' COLLATE \"C\", 'b' COLLATE \"POSIX\")",
        "SELECT 'a' COLLATE \"C\" = ANY(ARRAY['a' COLLATE \"POSIX\"])",
        "SELECT ('a' COLLATE \"C\" || 'b') || 'c' COLLATE ucs_basic",
    }) |source| try rejects(source, error.CollationMismatch);
    try sqlstate(error.CollationMismatch, "42P21");
    // 42804 (checked before the name), 42704, 3F000 and 0A000.
    try rejects("SELECT 1 COLLATE \"C\"", error.TypeMismatch);
    try rejects("SELECT 1 COLLATE \"nope\"", error.TypeMismatch);
    try rejects("SELECT -1 COLLATE \"C\"", error.TypeMismatch);
    try sqlstate(error.TypeMismatch, "42804");
    for ([_][]const u8{
        "SELECT 'a' COLLATE \"nope\"",          "SELECT 'a' COLLATE C",
        "SELECT 'a' COLLATE public.\"C\"",      "SELECT 'a' COLLATE \"nope\" COLLATE \"C\"",
        "SELECT ('a' COLLATE \"C\" || 'b' COLLATE \"POSIX\") COLLATE \"nope\"", "SELECT 'a' COLLATE \"nope\" < 'b'",
    }) |source| try rejects(source, error.UndefinedObject);
    try sqlstate(error.UndefinedObject, "42704");
    try rejects("SELECT 'a' COLLATE nope.\"C\"", error.UndefinedSchema);
    try sqlstate(error.UndefinedSchema, "3F000");
    try rejects("SELECT 'a' COLLATE pg_c_utf8", error.UnsupportedStatement);
    try rejects("SELECT 'a' COLLATE \"unicode\" < 'b'", error.UnsupportedStatement);
    try sqlstate(error.UnsupportedStatement, "0A000");
    // A BETWEEN lower bound is a b_expr: COLLATE cannot follow it.
    try rejects("SELECT 'a' BETWEEN 'a' COLLATE \"C\" AND 'b'", error.Syntax);

    // Column collations: only the database collation (the default).
    try rejects("CREATE TABLE ct(a TEXT COLLATE \"C\")", error.UnsupportedStatement);
    try rejects("CREATE TABLE ct(a INT COLLATE \"C\")", error.TypeMismatch);
    try rejects("CREATE TABLE ct(a TEXT COLLATE \"nope\")", error.UndefinedObject);
    // DEFAULT takes a b_expr, so this COLLATE is the column's.
    try rejects("CREATE TABLE ct(a TEXT DEFAULT 'x' COLLATE \"C\")", error.UnsupportedStatement);
    try exec("CREATE TABLE ct(id INT PRIMARY KEY, a TEXT COLLATE \"default\" DEFAULT ('q' COLLATE \"C\"))");
    try exec("INSERT INTO ct(id) VALUES (1)");
    try exec("INSERT INTO ct VALUES (2, 'b' COLLATE \"POSIX\")");
    try rows("SELECT id, a FROM ct ORDER BY a COLLATE \"C\" DESC", "1|q;2|b");
    try rows("SELECT column_default FROM information_schema.columns WHERE table_name = 'ct' AND column_name = 'a'", "('q'::text COLLATE \"C\")");
    try exec("DROP TABLE ct");

    // Durability: COLLATE lives in stored expression text only.
    try replay(&.{
        "CREATE TABLE cr(id INT PRIMARY KEY, a TEXT DEFAULT ('q' COLLATE \"C\"))",
        "INSERT INTO cr(id) VALUES (1)",
        "INSERT INTO cr VALUES (2, 'b' COLLATE \"POSIX\")",
    }, &.{"cr"}, "SELECT id, a FROM cr ORDER BY a COLLATE ucs_basic");
    try replicaShows("2|b;1|q");
}

pub fn main(init: std.process.Init) !void {
    try baseFixture();
    try discovery();
    try collations();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-text\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
