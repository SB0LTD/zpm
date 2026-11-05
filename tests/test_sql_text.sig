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
        .{ .name = "ProgramLimitExceeded", .state = "54000" },
        .{ .name = "InvalidRegularExpression", .state = "2201B" },
        .{ .name = "InvalidEscapeCharacterUse", .state = "2200C" },
        .{ .name = "InvalidEscapeSequence", .state = "22025" },
        .{ .name = "InvalidParameterValue", .state = "22023" },
        .{ .name = "CheckViolation", .state = "23514" },
        .{ .name = "Syntax", .state = "42601" },
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

// ---- regular expressions ---------------------------------------------------

/// SQLSTATE of an engine error as postgres.sig maps the ones used here.
fn stateOf(err: anyerror) []const u8 {
    const table = [_][2][]const u8{
        .{ "InvalidRegularExpression", "2201B" }, .{ "InvalidParameterValue", "22023" },     .{ "UnsupportedStatement", "0A000" },
        .{ "InvalidEscapeSequence", "22025" },    .{ "InvalidEscapeCharacterUse", "2200C" }, .{ "UndefinedFunction", "42883" },
        .{ "ProgramLimitExceeded", "54000" },     .{ "InvalidTextRepresentation", "22P02" },
        .{ "Syntax", "42601" },                   .{ "UndefinedObject", "42704" },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], @errorName(err))) return entry[1];
    return @errorName(err);
}

/// One single-value query: `want` is its text output, NULL, or `!` and
/// the five-character SQLSTATE of the error it raises (statement
/// atomicity checked).
fn single(source: []const u8, want: []const u8) !void {
    var state_marker = want.len == 6 and want[0] == '!';
    if (state_marker) for (want[1..]) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'A' and byte <= 'Z'))) state_marker = false;
    };
    if (!state_marker) return rows(source, want);
    try exec("SELECT 4242");
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        const state = stateOf(err);
        if (!std.mem.eql(u8, state, want[1..])) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), want[1..] });
        try check(std.mem.eql(u8, state, want[1..]));
    }
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 4242);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0);
}

/// Matched one by one against a local PostgreSQL 18.3 (LOCALE 'C'):
/// syntax, escapes, classes, brackets, bounds, constraints, lookaround,
/// options, errors, SIMILAR TO, similar_to_escape and regexp_like.
const regex_battery = [_][2][]const u8{
    .{ "SELECT 'abc' ~ '^a'", "t" },
    .{ "SELECT 'abc' ~ 'c$'", "t" },
    .{ "SELECT 'abc' ~ '^b'", "f" },
    .{ "SELECT 'abc' ~ 'b'", "t" },
    .{ "SELECT 'abc' ~ '^abc$'", "t" },
    .{ "SELECT 'abc' ~ '^ab$'", "f" },
    .{ "SELECT '' ~ '^$'", "t" },
    .{ "SELECT '' ~ ''", "t" },
    .{ "SELECT 'abc' ~ ''", "t" },
    .{ "SELECT 'abc' ~ 'a.c'", "t" },
    .{ "SELECT 'ac' ~ 'a.c'", "f" },
    .{ "SELECT 'abbbc' ~ 'ab*c'", "t" },
    .{ "SELECT 'ac' ~ 'ab*c'", "t" },
    .{ "SELECT 'ac' ~ 'ab+c'", "f" },
    .{ "SELECT 'abc' ~ 'ab?c'", "t" },
    .{ "SELECT 'abbc' ~ 'ab?c'", "f" },
    .{ "SELECT 'abc' ~ 'a|x'", "t" },
    .{ "SELECT 'xyz' ~ 'a|x'", "t" },
    .{ "SELECT 'xyz' ~ 'a|b|c'", "f" },
    .{ "SELECT 'b' ~ 'a|b|c'", "t" },
    .{ "SELECT 'abcabc' ~ '(abc){2}'", "t" },
    .{ "SELECT 'abcab' ~ '^(abc){2}$'", "f" },
    .{ "SELECT 'aaa' ~ '^a{3}$'", "t" },
    .{ "SELECT 'aaaa' ~ '^a{3}$'", "f" },
    .{ "SELECT 'aa' ~ '^a{2,3}$'", "t" },
    .{ "SELECT 'aaaa' ~ '^a{2,3}$'", "f" },
    .{ "SELECT 'a' ~ '^a{2,}$'", "f" },
    .{ "SELECT 'aaaaa' ~ '^a{2,}$'", "t" },
    .{ "SELECT '' ~ '^a{0}$'", "t" },
    .{ "SELECT 'a' ~ '^a{0,1}$'", "t" },
    .{ "SELECT 'b' ~ '^a{0}b$'", "t" },
    .{ "SELECT 'ab' ~ '^(a|b)+$'", "t" },
    .{ "SELECT 'abc' ~ '^(a|b)+$'", "f" },
    .{ "SELECT 'foo' ~ 'fo{1,2}'", "t" },
    .{ "SELECT 'f{' ~ 'f{'", "t" },
    .{ "SELECT 'f{x' ~ 'f{x'", "t" },
    .{ "SELECT 'f{,1}' ~ 'f{,1}'", "t" },
    .{ "SELECT 'a' ~ 'a{'", "f" },
    .{ "SELECT 'abc' ~ '[abc]'", "t" },
    .{ "SELECT 'd' ~ '[abc]'", "f" },
    .{ "SELECT 'd' ~ '[^abc]'", "t" },
    .{ "SELECT 'a' ~ '[^abc]'", "f" },
    .{ "SELECT 'b' ~ '[a-c]'", "t" },
    .{ "SELECT '-' ~ '[a-]'", "t" },
    .{ "SELECT '-' ~ '[-a]'", "t" },
    .{ "SELECT 'b' ~ '[]b]'", "t" },
    .{ "SELECT ']' ~ '[]b]'", "t" },
    .{ "SELECT '^' ~ '[\\^]'", "t" },
    .{ "SELECT '5' ~ '[[:digit:]]'", "t" },
    .{ "SELECT 'a' ~ '[[:digit:]]'", "f" },
    .{ "SELECT 'A' ~ '[[:upper:]]'", "t" },
    .{ "SELECT 'a' ~ '[[:upper:]]'", "f" },
    .{ "SELECT ' ' ~ '[[:space:]]'", "t" },
    .{ "SELECT '_' ~ '[[:word:]]'", "t" },
    .{ "SELECT '_' ~ '[[:alnum:]]'", "f" },
    .{ "SELECT '!' ~ '[[:punct:]]'", "t" },
    .{ "SELECT E'\\x09' ~ '[[:blank:]]'", "t" },
    .{ "SELECT 'f' ~ '[[:xdigit:]]'", "t" },
    .{ "SELECT 'g' ~ '[[:xdigit:]]'", "f" },
    .{ "SELECT 'a' ~ '[[.a.]]'", "t" },
    .{ "SELECT ' ' ~ '[[.space.]]'", "t" },
    .{ "SELECT '-' ~ '[[.hyphen.]]'", "t" },
    .{ "SELECT 'a' ~ '[[=a=]]'", "t" },
    .{ "SELECT 'b' ~ '[a[.-.]z]'", "f" },
    .{ "SELECT 'Ã©' ~ '[[:alpha:]]'", "f" },
    .{ "SELECT 'Ã©' ~ '.'", "t" },
    .{ "SELECT 'Ã©' ~ '^.$'", "f" },
    .{ "SELECT 'Ã©' ~ '[Ã©]'", "t" },
    .{ "SELECT 'Ã©' ~ '[Ã -Ã¼]'", "t" },
    .{ "SELECT 'x' ~ '[Ã -Ã¼]'", "f" },
    .{ "SELECT 'â‚¬' ~ '^[^a]$'", "f" },
    .{ "SELECT '' ~ '[[:cntrl:]]'", "t" },
    .{ "SELECT '5' ~ '\\d'", "t" },
    .{ "SELECT 'a' ~ '\\d'", "f" },
    .{ "SELECT 'a' ~ '\\D'", "t" },
    .{ "SELECT ' ' ~ '\\s'", "t" },
    .{ "SELECT 'a' ~ '\\S'", "t" },
    .{ "SELECT 'a' ~ '\\w'", "t" },
    .{ "SELECT '_' ~ '\\w'", "t" },
    .{ "SELECT '-' ~ '\\w'", "f" },
    .{ "SELECT '-' ~ '\\W'", "t" },
    .{ "SELECT '5' ~ '[\\d]'", "t" },
    .{ "SELECT 'a' ~ '[\\d]'", "f" },
    .{ "SELECT 'a' ~ '[\\D]'", "t" },
    .{ "SELECT '5' ~ '[\\D]'", "f" },
    .{ "SELECT 'a' ~ '[\\w-]'", "t" },
    .{ "SELECT '-' ~ '[\\w-]'", "t" },
    .{ "SELECT 'foo bar' ~ '\\mbar'", "t" },
    .{ "SELECT 'foobar' ~ '\\mbar'", "f" },
    .{ "SELECT 'foo bar' ~ 'foo\\M'", "t" },
    .{ "SELECT 'foobar' ~ 'foo\\M'", "f" },
    .{ "SELECT 'foo bar' ~ '\\yfoo\\y'", "t" },
    .{ "SELECT 'foobar' ~ '\\Ybar'", "t" },
    .{ "SELECT 'foo bar' ~ '\\Ybar'", "f" },
    .{ "SELECT 'foo bar' ~ '[[:<:]]bar'", "t" },
    .{ "SELECT 'foobar' ~ '[[:<:]]bar'", "f" },
    .{ "SELECT 'foo bar' ~ 'foo[[:>:]]'", "t" },
    .{ "SELECT 'abc' ~ '\\Aabc\\Z'", "t" },
    .{ "SELECT 'abc' ~ '\\Ab'", "f" },
    .{ "SELECT 'a.c' ~ 'a\\.c'", "t" },
    .{ "SELECT 'abc' ~ 'a\\.c'", "f" },
    .{ "SELECT 'a+c' ~ 'a\\+c'", "t" },
    .{ "SELECT 'a\\c' ~ 'a\\\\c'", "t" },
    .{ "SELECT E'a\\x0ab' ~ 'a.b'", "t" },
    .{ "SELECT E'a\\x0ab' ~ '(?n)a.b'", "f" },
    .{ "SELECT E'a\\x0ab' ~ '(?n)^b'", "t" },
    .{ "SELECT E'a\\x0ab' ~ '^b'", "f" },
    .{ "SELECT E'a\\x0ab' ~ '(?p)^b'", "f" },
    .{ "SELECT E'a\\x0ab' ~ '(?w)^b'", "t" },
    .{ "SELECT E'a\\x0ab' ~ '(?w)a.b'", "t" },
    .{ "SELECT E'a\\x0ab' ~ '(?p)a[^x]b'", "f" },
    .{ "SELECT E'a\\x0ab' ~ 'a[^x]b'", "t" },
    .{ "SELECT E'a\\x0ab' ~ '(?n)a$'", "t" },
    .{ "SELECT E'a\\x0ab' ~ 'a$'", "f" },
    .{ "SELECT E'a\\x0ab' ~ '(?n)a\\Z'", "f" },
    .{ "SELECT E'a\\x0ab' ~ '(?n)a\\W'", "t" },
    .{ "SELECT 'Ab' ~ '(?i)ab'", "t" },
    .{ "SELECT 'Ab' ~ '(?c)ab'", "f" },
    .{ "SELECT 'ab' ~ '***=a.'", "f" },
    .{ "SELECT 'a.' ~ '***=a.'", "t" },
    .{ "SELECT 'a' ~ '***:a'", "t" },
    .{ "SELECT 'abc' ~ '(?x)a b c'", "t" },
    .{ "SELECT 'a b c' ~ '(?x)a\\ b'", "t" },
    .{ "SELECT 'abc' ~ E'(?x)a#x\\x0abc'", "t" },
    .{ "SELECT 'aab' ~ '(?x)a { 2 } b'", "t" },
    .{ "SELECT 'abc' ~ 'a(?#comment)bc'", "t" },
    .{ "SELECT 'abc' ~ 'a(?#comment)*bc'", "t" },
    .{ "SELECT 'abc' ~ '(?:ab)c'", "t" },
    .{ "SELECT 'ab' ~ '(?=a)a'", "t" },
    .{ "SELECT 'b' ~ '(?=a)'", "f" },
    .{ "SELECT 'ab' ~ 'a(?=b)'", "t" },
    .{ "SELECT 'ac' ~ 'a(?=b)'", "f" },
    .{ "SELECT 'ac' ~ 'a(?!b)'", "t" },
    .{ "SELECT 'ab' ~ 'a(?!b)'", "f" },
    .{ "SELECT 'ab' ~ '(?<=a)b'", "t" },
    .{ "SELECT 'cb' ~ '(?<=a)b'", "f" },
    .{ "SELECT 'cb' ~ '(?<!a)b'", "t" },
    .{ "SELECT 'ab' ~ '(?<!a)b'", "f" },
    .{ "SELECT 'xab' ~ '(?<=xa)b'", "t" },
    .{ "SELECT 'ab' ~ '(?<=^a)b'", "t" },
    .{ "SELECT 'ab' ~ '(?<=a|xy)b'", "t" },
    .{ "SELECT 'xyb' ~ '(?<=a|xy)b'", "t" },
    .{ "SELECT 'ab' ~ 'a(?=(?=b))'", "t" },
    .{ "SELECT 'abc' ~ 'a(?=b(?!d))'", "t" },
    .{ "SELECT 'abd' ~ 'a(?=b(?!d))'", "f" },
    .{ "SELECT 'a' ~ '\\x61'", "t" },
    .{ "SELECT 'a' ~ '\\141'", "t" },
    .{ "SELECT 'a' ~ '\\u0061'", "t" },
    .{ "SELECT 'a' ~ '\\U00000061'", "t" },
    .{ "SELECT E'\\x0a' ~ '\\n'", "t" },
    .{ "SELECT E'\\x09' ~ '\\t'", "t" },
    .{ "SELECT 'a' ~ '\\0141'", "f" },
    .{ "SELECT E'\\x01' ~ '\\cA'", "t" },
    .{ "SELECT E'\\x1b' ~ '\\e'", "t" },
    .{ "SELECT E'\\x07' ~ '\\a'", "t" },
    .{ "SELECT '\\' ~ '\\B'", "t" },
    .{ "SELECT 'ab' ~ '(a)b'", "t" },
    .{ "SELECT 'aab' ~ '(a*)*b'", "t" },
    .{ "SELECT 'b' ~ '(a*)+b'", "t" },
    .{ "SELECT '' ~ '()'", "t" },
    .{ "SELECT 'a' ~ '()a'", "t" },
    .{ "SELECT 'a' ~ 'a|'", "t" },
    .{ "SELECT 'a' ~ '|a'", "t" },
    .{ "SELECT 'ab' ~ 'a()b'", "t" },
    .{ "SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab' ~ '^(a+)+$'", "f" },
    .{ "SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaab' ~ '^(a|aa)*c'", "f" },
    .{ "SELECT 'abc' ~ 'abc*?'", "t" },
    .{ "SELECT 'abc' ~ 'a+?'", "t" },
    .{ "SELECT 'abc' ~ 'a??'", "t" },
    .{ "SELECT 'abc' ~ 'a{1,2}?'", "t" },
    .{ "SELECT 'ABC' ~ 'abc'", "f" },
    .{ "SELECT 'ABC' ~* '^a'", "t" },
    .{ "SELECT 'abc' ~* '^A'", "t" },
    .{ "SELECT 'Ã‰' ~* 'Ã©'", "f" },
    .{ "SELECT 'X' ~* '[a-z]'", "t" },
    .{ "SELECT 'x' ~* '[A-Z]'", "t" },
    .{ "SELECT 'X' ~* '[[:lower:]]'", "t" },
    .{ "SELECT 'x' ~* '[[:upper:]]'", "t" },
    .{ "SELECT 'X' ~* '[^x]'", "f" },
    .{ "SELECT 'b' ~* '[^B]'", "f" },
    .{ "SELECT 'Ã€B' ~* '^.b$'", "f" },
    .{ "SELECT 'abc' !~ '^a'", "f" },
    .{ "SELECT 'abc' !~* '^a'", "f" },
    .{ "SELECT 'abc' !~ '^b'", "t" },
    .{ "SELECT 'abc' !~* '^b'", "t" },
    .{ "SELECT 'ABC' !~* '^b'", "t" },
    .{ "SELECT 'ABC' !~* '^a'", "f" },
    .{ "SELECT 'a' ~ '('", "!2201B" },
    .{ "SELECT 'a' ~ '(a'", "!2201B" },
    .{ "SELECT 'a' ~ ')'", "!2201B" },
    .{ "SELECT 'a' ~ 'a)'", "!2201B" },
    .{ "SELECT 'a' ~ '[a'", "!2201B" },
    .{ "SELECT 'a' ~ '['", "!2201B" },
    .{ "SELECT 'a' ~ '*a'", "!2201B" },
    .{ "SELECT 'a' ~ 'a**'", "!2201B" },
    .{ "SELECT 'a' ~ '+'", "!2201B" },
    .{ "SELECT 'a' ~ '?'", "!2201B" },
    .{ "SELECT 'a' ~ 'a{2,1}'", "!2201B" },
    .{ "SELECT 'a' ~ 'a{256}'", "!2201B" },
    .{ "SELECT 'a' ~ '{1}'", "!2201B" },
    .{ "SELECT 'a' ~ 'a\\'", "!2201B" },
    .{ "SELECT 'a' ~ '\\q'", "!2201B" },
    .{ "SELECT 'a' ~ '\\1'", "!2201B" },
    .{ "SELECT 'a' ~ '(a)\\2'", "!2201B" },
    .{ "SELECT 'a' ~ '(a\\1)'", "!2201B" },
    .{ "SELECT 'a' ~ '[b-a]'", "!2201B" },
    .{ "SELECT 'a' ~ '[[:foo:]]'", "!2201B" },
    .{ "SELECT 'a' ~ '[[.foo.]]'", "!2201B" },
    .{ "SELECT 'a' ~ '[[..]]'", "!2201B" },
    .{ "SELECT 'a' ~ '[a-[:digit:]]'", "!2201B" },
    .{ "SELECT 'a' ~ '[[:digit:]-z]'", "!2201B" },
    .{ "SELECT 'a' ~ '[a-c-e]'", "!2201B" },
    .{ "SELECT 'a' ~ '^*'", "!2201B" },
    .{ "SELECT 'a' ~ '$+'", "!2201B" },
    .{ "SELECT 'a' ~ '\\A*'", "!2201B" },
    .{ "SELECT 'a' ~ '(?=a)*'", "!2201B" },
    .{ "SELECT 'a' ~ '(?i'", "!2201B" },
    .{ "SELECT 'a' ~ '(?z)a'", "!2201B" },
    .{ "SELECT 'a' ~ 'a(?i)b'", "!2201B" },
    .{ "SELECT 'a' ~ '***?'", "!2201B" },
    .{ "SELECT 'a' ~ '***a'", "!2201B" },
    .{ "SELECT 'a' ~ '(?<a)'", "!2201B" },
    .{ "SELECT 'a' ~ '(?'", "!2201B" },
    .{ "SELECT 'a' ~ '\\x'", "!2201B" },
    .{ "SELECT 'a' ~ '\\u12'", "!2201B" },
    .{ "SELECT 'a' ~ '\\c'", "!2201B" },
    .{ "SELECT 'a' ~ '[\\m]'", "!2201B" },
    .{ "SELECT 'a' ~ '[\\1]'", "!2201B" },
    .{ "SELECT 'a' ~ '[\\A]'", "!2201B" },
    .{ "SELECT 'a' ~ 'a{1'", "!2201B" },
    .{ "SELECT 'a' ~ 'a{1,2'", "!2201B" },
    .{ "SELECT 'a' ~ 'a{x}'", "f" },
    .{ "SELECT 'a' ~ '(?<=a\\1)'", "!2201B" },
    .{ "SELECT 'a' ~ 'x{1,2,3}'", "!2201B" },
    .{ "SELECT 'a' ~ '\\8'", "!2201B" },
    .{ "SELECT 'a' ~ '\\U7fffffff'", "!2201B" },
    .{ "SELECT 'a' ~ '(?e)a{1}?'", "!2201B" },
    .{ "SELECT 'a' ~ '\\12'", "f" },
    .{ "SELECT E'\\x0a' ~ '\\12'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a%'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a_c'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'abc'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'ab'", "f" },
    .{ "SELECT 'abc' SIMILAR TO '%(b|x)%'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a(b|x)c'", "t" },
    .{ "SELECT 'ab' SIMILAR TO '(a|b)*'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a[bc]+'", "t" },
    .{ "SELECT 'a.c' SIMILAR TO 'a.c'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a.c'", "f" },
    .{ "SELECT 'a^c' SIMILAR TO 'a^c'", "t" },
    .{ "SELECT 'a$' SIMILAR TO 'a$'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a\\%'", "f" },
    .{ "SELECT 'a%' SIMILAR TO 'a\\%'", "t" },
    .{ "SELECT 'a_' SIMILAR TO 'a\\_'", "t" },
    .{ "SELECT 'ab' SIMILAR TO 'a\\_'", "f" },
    .{ "SELECT 'ABC' SIMILAR TO 'abc'", "f" },
    .{ "SELECT 'abc' SIMILAR TO 'abc|xyz'", "t" },
    .{ "SELECT 'xyz' SIMILAR TO 'abc|xyz'", "t" },
    .{ "SELECT 'aaa' SIMILAR TO 'a{3}'", "t" },
    .{ "SELECT 'aa' SIMILAR TO 'a{3}'", "f" },
    .{ "SELECT 'a' SIMILAR TO 'a*'", "t" },
    .{ "SELECT '' SIMILAR TO 'a*'", "t" },
    .{ "SELECT 'ab' SIMILAR TO 'a+b?'", "t" },
    .{ "SELECT 'a\\b' SIMILAR TO 'a\\\\b'", "t" },
    .{ "SELECT 'a[b' SIMILAR TO 'a[[]b'", "t" },
    .{ "SELECT 'abc' SIMILAR TO '[a-c]%'", "t" },
    .{ "SELECT 'abc' SIMILAR TO '%[^a]'", "t" },
    .{ "SELECT 'abc' SIMILAR TO '%\\\"b\\\"%'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a\\'", "f" },
    .{ "SELECT 'a' SIMILAR TO 'a\\'", "t" },
    .{ "SELECT 'a\\b' SIMILAR TO 'a\\b'", "f" },
    .{ "SELECT 'a(b' SIMILAR TO 'a\\(b'", "t" },
    .{ "SELECT 'a_c' SIMILAR TO 'a#_c' ESCAPE '#'", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a#_c' ESCAPE '#'", "f" },
    .{ "SELECT 'a%' SIMILAR TO 'a!%' ESCAPE '!'", "t" },
    .{ "SELECT 'a\\%' SIMILAR TO 'a\\%' ESCAPE ''", "t" },
    .{ "SELECT 'ab' SIMILAR TO 'a%' ESCAPE ''", "t" },
    .{ "SELECT 'abc' SIMILAR TO 'a#\"b#\"c' ESCAPE '#'", "t" },
    .{ "SELECT 'ab' SIMILAR TO 'ab' ESCAPE 'xy'", "!22025" },
    .{ "SELECT 'aÃ©' SIMILAR TO 'a%' ESCAPE 'Ã©'", "!22025" },
    .{ "SELECT 'abc' NOT SIMILAR TO 'a%'", "f" },
    .{ "SELECT 'abc' SIMILAR TO 'a%' ESCAPE NULL", "NULL" },
    .{ "SELECT 'abc' SIMILAR TO '%\\\"a\\\"%\\\"b\\\"%'", "!2200C" },
    .{ "SELECT 'abc' SIMILAR TO NULL", "NULL" },
    .{ "SELECT similar_to_escape('a%')", "^(?:a.*)$" },
    .{ "SELECT similar_to_escape('a_c')", "^(?:a.c)$" },
    .{ "SELECT similar_to_escape('a.b')", "^(?:a\\.b)$" },
    .{ "SELECT similar_to_escape('(a|b)')", "^(?:(?:a|b))$" },
    .{ "SELECT similar_to_escape('a\\%b')", "^(?:a\\%b)$" },
    .{ "SELECT similar_to_escape('a#%b', '#')", "^(?:a\\%b)$" },
    .{ "SELECT similar_to_escape('a%', '')", "^(?:a.*)$" },
    .{ "SELECT similar_to_escape('[a\\]]')", "^(?:[a\\]])$" },
    .{ "SELECT similar_to_escape('[^]a]')", "^(?:[^]a])$" },
    .{ "SELECT similar_to_escape('a\\\"b\\\"c')", "^(?:a){1,1}?(b){1,1}(?:c)$" },
    .{ "SELECT regexp_like('Abc','^a')", "f" },
    .{ "SELECT regexp_like('Abc','^a','i')", "t" },
    .{ "SELECT regexp_like('Abc','^a','c')", "f" },
    .{ "SELECT regexp_like(E'a\\x0ab','a.b','n')", "f" },
    .{ "SELECT regexp_like('a.b','a.b','q')", "t" },
    .{ "SELECT regexp_like('axb','a.b','q')", "f" },
    .{ "SELECT regexp_like('Abc','^a','g')", "!22023" },
    .{ "SELECT regexp_like('Abc','^a','z')", "!22023" },
    .{ "SELECT regexp_like('a b','a b','x')", "f" },
    .{ "SELECT regexp_like('a','a',NULL)", "NULL" },
    .{ "SELECT regexp_like(NULL,'a')", "NULL" },
    .{ "SELECT NULL ~ 'a'", "NULL" },
    .{ "SELECT 'a' ~ NULL", "NULL" },
    .{ "SELECT 'a  '::char(3) ~ 'a $'", "f" },
    .{ "SELECT 'a  '::char(3) ~ 'a$'", "f" },
    .{ "SELECT 'ab'::name ~ '^a'", "t" },
    .{ "SELECT 'ab'::varchar ~ 'b$'", "t" },
    .{ "SELECT 'a' ~ 'a'::char(3)", "t" },
    .{ "SELECT 1 ~ '1'", "!42883" },
    .{ "SELECT regexp_like('a','a','eq')", "t" },
    .{ "SELECT regexp_like('a','a','bg')", "!22023" },
    .{ "SELECT regexp_like('a','(?e)a{1}?')", "!2201B" },
    .{ "SELECT 'a' ~ '(?e)a\\d'", "f" },
    .{ "SELECT 'ad' ~ '(?e)a\\d'", "t" },
    .{ "SELECT 'a' ~ '(?e)[\\d]'", "f" },
    .{ "SELECT '\\' ~ '(?e)[\\d]'", "t" },
    .{ "SELECT 'a+' ~ '(?e)a\\+'", "t" },
    .{ "SELECT 'ab' ~ '(?e)(?:ab)'", "!2201B" },
    .{ "SELECT 'aaa' ~ 'a{255}'", "f" },
    .{ "SELECT 'x' ~ '[a-z]{0,200}x'", "t" },
    .{ "SELECT 'abc' ~ '(?x) a [ ] b c'", "f" },
    .{ "SELECT ' ' ~ '(?x)[ ]'", "t" },
    .{ "SELECT 'abc' ~ '(?xi)A B'", "t" },
    .{ "SELECT 'ab' ~ '(?q)a.'", "f" },
    .{ "SELECT 'a.' ~ '(?q)a.'", "t" },
    .{ "SELECT 'a.' ~* '(?q)A.'", "t" },
    .{ "SELECT 'Abc' ~* '***=a'", "t" },
    .{ "SELECT 'abc' ~ '(?n)c$'", "t" },
    .{ "SELECT '' ~ '$'", "t" },
    .{ "SELECT '' ~ '^'", "t" },
    .{ "SELECT 'a' ~ '(?=a)(?!b)a'", "t" },
    .{ "SELECT 'ba' ~ '(?<=b)(?<!c)a'", "t" },
    .{ "SELECT 'a' ~ '[[:alpha:][:digit:]]'", "t" },
    .{ "SELECT '5' ~ '[[:alpha:][:digit:]]'", "t" },
    .{ "SELECT '_' ~ '[^[:alnum:]]'", "t" },
    .{ "SELECT 'A' ~* '[[:lower:]]'", "t" },
    .{ "SELECT 'é' ~* 'É'", "f" },
    .{ "SELECT 'ab' ~ 'a(?=b(?=$))'", "t" },
    .{ "SELECT 'ab' ~ 'a(?=(?=(?=b)))'", "t" },
};

fn regularExpressions() !void {
    // oracle: PG.PRED.REGEX.
    try rows("SELECT 'abc' ~ '^a','ABC' ~* '^a','abc' SIMILAR TO 'a%'", "t|t|t");
    for (0..3) |index| try meta(index, "?column?", 16, -1);
    for (regex_battery) |case| try single(case[0], case[1]);

    // Not supported here (0A000), where PostgreSQL matches: back
    // references, BREs (embedded `b`; regexp_like options `b` and `e`,
    // which parse_re_flags turns into BREs) and lookarounds nested more
    // than three deep.
    for ([_][]const u8{
        "SELECT 'aa' ~ '(a)\\1'",              "SELECT 'aa' ~ '(a)(b)\\2'",
        "SELECT 'aa' ~ '(a)\\1*'",             "SELECT 'a' ~ '(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)\\12'",
        "SELECT 'a' ~ '(?b)a'",                "SELECT regexp_like('Abc','^a','b')",
        "SELECT regexp_like('a','a{1}?','e')", "SELECT regexp_like('a.','a.','qe')",
        "SELECT 'ab' ~ 'a(?=(?=(?=(?=b))))'",
    }) |source| try rejects(source, error.UnsupportedStatement);
    // A program beyond Config.regex_states instructions is 54000 (the
    // first one PostgreSQL also refuses, as too complex: 2201B).
    try rejects("SELECT 'aaa' ~ '(a{255}){255}'", error.ProgramLimitExceeded);
    try rejects("SELECT 'a' ~ 'a{255}a{255}a{255}'", error.ProgramLimitExceeded);
    try sqlstate(error.ProgramLimitExceeded, "54000");

    // Columns, NULLs and every operator form over a table.
    try exec("CREATE TABLE rx(id INT PRIMARY KEY, name TEXT, code CHAR(4), tag VARCHAR(8))");
    try exec("INSERT INTO rx VALUES (1, 'Berlin', 'DE1', 'eu'), (2, 'bern', 'CH2', NULL), (3, NULL, 'X', 'na'), (4, 'Boston', 'US03', 'na')");
    try rows("SELECT id FROM rx WHERE name ~ '^B' ORDER BY id", "1;4");
    try rows("SELECT id FROM rx WHERE name ~* '^b' ORDER BY id", "1;2;4");
    try rows("SELECT id FROM rx WHERE name !~ 'in$' ORDER BY id", "2;4");
    try rows("SELECT id FROM rx WHERE name !~* '^B' ORDER BY id", "");
    try rows("SELECT id, name ~ 'er', tag ~ 'a' FROM rx ORDER BY id", "1|t|f;2|t|NULL;3|NULL|t;4|f|t");
    // bpchar operands keep their padding (bpcharregexeq).
    try rows("SELECT id FROM rx WHERE code ~ '^[A-Z]{2}[0-9] $' ORDER BY id", "1;2");
    try rows("SELECT id FROM rx WHERE name SIMILAR TO 'B%n' OR tag NOT SIMILAR TO '(eu|na)' ORDER BY id", "1;4");
    try rows("SELECT id, regexp_like(name, 'ER', 'i') FROM rx ORDER BY id", "1|t;2|t;3|NULL;4|f");
    try rows("SELECT id FROM rx WHERE name ~ tag ORDER BY id", "");
    try rows("SELECT COUNT(*) FROM rx WHERE name ~ (SELECT '^' || 'B')", "2");
    try rejects("SELECT id FROM rx WHERE name ~ '('", error.InvalidRegularExpression);
    try sqlstate(error.InvalidRegularExpression, "2201B");
    try sqlstate(error.InvalidEscapeCharacterUse, "2200C");
    try rejects("SELECT id FROM rx WHERE id ~ '1'", error.UndefinedFunction);
    try sqlstate(error.UndefinedFunction, "42883");

    // A hostile pattern stays linear (Pike VM) and every text position is
    // a work-budget checkpoint and a cancellation point.
    try controlled("SELECT 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab' ~ '^(a|aa)*(a+)+c'", "f");
    try controlled("SELECT name FROM rx WHERE name ~* '(?<=b)e(?=r)' ORDER BY id", "Berlin;bern");
    try controlled("SELECT 'xxxxxxxxxxxxxxxxxxxxy' SIMILAR TO '%(x|xx)%y'", "t");

    // Stored expressions print as ruleutils does.
    try exec("CREATE TABLE rd(id INT PRIMARY KEY, a BOOLEAN DEFAULT ('x' ~ 'y'), b BOOLEAN DEFAULT ('x' !~* 'y'), c BOOLEAN DEFAULT ('x' SIMILAR TO 'y%'), d BOOLEAN DEFAULT ('x' NOT SIMILAR TO 'y' ESCAPE '#'), e TEXT DEFAULT similar_to_escape('a%'), f BOOLEAN DEFAULT regexp_like('a', 'b', 'i'))");
    try rows("SELECT column_default FROM information_schema.columns WHERE table_name = 'rd' AND column_default IS NOT NULL ORDER BY ordinal_position",
        "('x'::text ~ 'y'::text);('x'::text !~* 'y'::text);('x'::text ~ similar_to_escape('y%'::text));('x'::text !~ similar_to_escape('y'::text, '#'::text));similar_to_escape('a%'::text);regexp_like('a'::text, 'b'::text, 'i'::text)");
    try exec("INSERT INTO rd(id) VALUES (1)");
    try rows("SELECT a, b, c, d, e, f FROM rd", "f|t|f|t|^(?:a.*)$|f");
    try exec("DROP TABLE rd");

    // CHECK constraints and replay: the expression is stored text.
    try replay(&.{
        "CREATE TABLE rc(id INT PRIMARY KEY, code TEXT CHECK (code ~ '^[A-Z]{2}[0-9]+$'), city TEXT CHECK (city SIMILAR TO '[A-Z]%'))",
        "INSERT INTO rc VALUES (1, 'AB12', 'Bern'), (2, NULL, 'Oslo')",
        "UPDATE rc SET code = 'ZZ9' WHERE id = 2",
    }, &.{"rc"}, "SELECT * FROM rc ORDER BY id");
    try replicaShows("1|AB12|Bern;2|ZZ9|Oslo");
    try exec("CREATE TABLE rc(id INT PRIMARY KEY, code TEXT CHECK (code ~ '^[A-Z]{2}[0-9]+$'))");
    try rejects("INSERT INTO rc VALUES (1, 'AB1'), (2, 'ab12')", error.CheckViolation);
    try sqlstate(error.CheckViolation, "23514");
    try rows("SELECT COUNT(*) FROM rc", "0");
    try exec("DROP TABLE rc");
    try exec("DROP TABLE rx");
}

// ---- full text search ----------------------------------------------------------

/// Matched one by one against a local PostgreSQL 18.3 (LOCALE 'C'):
/// to_tsvector('simple') over every token type of the default parser,
/// tsvector and tsquery input/output, to_tsquery / plainto_tsquery /
/// phraseto_tsquery, configuration names and @@; then 120 generated
/// parser inputs.
const fts_battery = [_][2][]const u8{
    .{ "SELECT to_tsvector('simple', 'one two')", "'one':1 'two':2" },
    .{ "SELECT to_tsvector('simple', 'one two one')", "'one':1,3 'two':2" },
    .{ "SELECT to_tsvector('simple', 'Hello. World')", "'hello':1 'world':2" },
    .{ "SELECT to_tsvector('simple', 'foo_bar')", "'bar':2 'foo':1" },
    .{ "SELECT to_tsvector('simple', 'foo-bar')", "'bar':3 'foo':2 'foo-bar':1" },
    .{ "SELECT to_tsvector('simple', 'foo-bar-baz')", "'bar':3 'baz':4 'foo':2 'foo-bar-baz':1" },
    .{ "SELECT to_tsvector('simple', 'foo-123')", "'-123':2 'foo':1" },
    .{ "SELECT to_tsvector('simple', '123-456')", "'-456':2 '123':1" },
    .{ "SELECT to_tsvector('simple', '-5 +6 5.5 .5')", "'+6':2 '-5':1 '5':4 '5.5':3" },
    .{ "SELECT to_tsvector('simple', 'a.b')", "'a.b':1" },
    .{ "SELECT to_tsvector('simple', 'x@y.com')", "'x@y.com':1" },
    .{ "SELECT to_tsvector('simple', 'don''t stop')", "'don':1 'stop':3 't':2" },
    .{ "SELECT to_tsvector('simple', 'Café Über ÄÖ')", "'café':1 'ÄÖ':3 'Über':2" },
    .{ "SELECT to_tsvector('simple', 'abc123 123abc')", "'123abc':2 'abc123':1" },
    .{ "SELECT to_tsvector('simple', 'foo.bar baz@qux.com http://x.org/a/b <b>tag</b> &amp; -5 +6 1.5e3 1.2.3 /usr/bin ~/x.txt a_b')", "'+6':8 '-5':7 '/a/b':5 '/usr/bin':11 '/x.txt':12 '1.2.3':10 '1.5e3':9 'a':13 'b':14 'baz@qux.com':2 'foo.bar':1 'tag':6 'x.org':4 'x.org/a/b':3" },
    .{ "SELECT to_tsvector('simple', 'The quick brown fox')", "'brown':3 'fox':4 'quick':2 'the':1" },
    .{ "SELECT to_tsvector('simple', 'UPPER lower MiXeD')", "'lower':2 'mixed':3 'upper':1" },
    .{ "SELECT to_tsvector('simple', '')", "" },
    .{ "SELECT to_tsvector('simple', '   ')", "" },
    .{ "SELECT to_tsvector('simple', '!!!')", "" },
    .{ "SELECT to_tsvector('simple', 'a')", "'a':1" },
    .{ "SELECT to_tsvector('simple', 'é')", "'é':1" },
    .{ "SELECT to_tsvector('simple', E'x\\x0ay\\x09z')", "'x':1 'y':2 'z':3" },
    .{ "SELECT to_tsvector('simple', 'v1.2 1.2.3.4 192.168.0.1')", "'1.2.3.4':2 '192.168.0.1':3 'v1.2':1" },
    .{ "SELECT to_tsvector('simple', 'www.example.com/path?q=1')", "'/path?q=1':3 'www.example.com':2 'www.example.com/path?q=1':1" },
    .{ "SELECT to_tsvector('simple', 'mailto:me@x.org')", "'mailto':1 'me@x.org':2" },
    .{ "SELECT to_tsvector('simple', 'file.txt')", "'file.txt':1" },
    .{ "SELECT to_tsvector('simple', '/path/to/file.txt')", "'/path/to/file.txt':1" },
    .{ "SELECT to_tsvector('simple', 'ftp://ftp.x.org')", "'ftp.x.org':1" },
    .{ "SELECT to_tsvector('simple', '<script>hidden</script> shown')", "'shown':1" },
    .{ "SELECT to_tsvector('simple', '<!-- comment --> visible')", "'visible':1" },
    .{ "SELECT to_tsvector('simple', 'a-b-c-d')", "'a':2 'a-b-c-d':1 'b':3 'c':4 'd':5" },
    .{ "SELECT to_tsvector('simple', 'co-operate')", "'co':2 'co-operate':1 'operate':3" },
    .{ "SELECT to_tsvector('simple', 'self-service')", "'self':2 'self-service':1 'service':3" },
    .{ "SELECT to_tsvector('simple', 'e-mail')", "'e':2 'e-mail':1 'mail':3" },
    .{ "SELECT to_tsvector('simple', '3.14159')", "'3.14159':1" },
    .{ "SELECT to_tsvector('simple', '1e10')", "'1e10':1" },
    .{ "SELECT to_tsvector('simple', '-1.5e-3')", "'-1.5e-3':1" },
    .{ "SELECT to_tsvector('simple', '1,000')", "'000':2 '1':1" },
    .{ "SELECT to_tsvector('simple', '$100')", "'100':1" },
    .{ "SELECT to_tsvector('simple', '50%')", "'50':1" },
    .{ "SELECT to_tsvector('simple', 'C++ C#')", "'c':1,2" },
    .{ "SELECT to_tsvector('simple', 'foo--bar')", "'bar':2 'foo':1" },
    .{ "SELECT to_tsvector('simple', 'über-cool')", "'cool':3 'über':2 'über-cool':1" },
    .{ "SELECT to_tsvector('simple', 'naïve café')", "'café':2 'naïve':1" },
    .{ "SELECT to_tsvector('simple', 'Ελληνικά κείμενο')", "'Ελληνικά':1 'κείμενο':2" },
    .{ "SELECT to_tsvector('simple', '日本語 テキスト')", "'テキスト':2 '日本語':1" },
    .{ "SELECT to_tsvector('simple', 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')", "'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx':1" },
    .{ "SELECT to_tsvector('simple', 'w w w w w w w w w w w w w w w w w w w w w w w w w w w w w w')", "'w':1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30" },
    .{ "SELECT to_tsvector('simple', 'http://user@host.com:8080/x')", "'/x':2 'user@host.com:8080':1" },
    .{ "SELECT to_tsvector('simple', 'https://a.b.c/d.e?f=g#h')", "'a.b.c/d.e':1 'f':2 'g':3 'h':4" },
    .{ "SELECT to_tsvector('simple', 'a@b')", "'a':1 'b':2" },
    .{ "SELECT to_tsvector('simple', 'a.b.c@d.e')", "'a.b.c':1 'd.e':2" },
    .{ "SELECT to_tsvector('simple', '-')", "" },
    .{ "SELECT to_tsvector('simple', '--')", "" },
    .{ "SELECT to_tsvector('simple', '+')", "" },
    .{ "SELECT to_tsvector('simple', '<a href=\"x\">link</a>')", "'link':1" },
    .{ "SELECT to_tsvector('simple', '&#123; &x;')", "" },
    .{ "SELECT to_tsvector('simple', '&nbsp;x')", "'x':1" },
    .{ "SELECT 'a:1 b:2A'::tsvector", "'a':1 'b':2A" },
    .{ "SELECT 'b a a'::tsvector", "'a' 'b'" },
    .{ "SELECT '''a b'':1 c'::tsvector", "'a b':1 'c'" },
    .{ "SELECT '''it''''s'':3'::tsvector", "'it''s':3" },
    .{ "SELECT 'a:3,1,2'::tsvector", "'a':1,2,3" },
    .{ "SELECT 'a:1A,1B'::tsvector", "'a':1A" },
    .{ "SELECT 'a:1,1'::tsvector", "'a':1" },
    .{ "SELECT 'x:16383 y:20000'::tsvector", "'x':16383 'y':16383" },
    .{ "SELECT 'a:1C b:2D c:3*'::tsvector", "'a':1C 'b':2 'c':3A" },
    .{ "SELECT 'a\\ b'::tsvector", "'a b'" },
    .{ "SELECT '''a\\''b'''::tsvector", "'a''b'" },
    .{ "SELECT ''::tsvector", "" },
    .{ "SELECT '  '::tsvector", "" },
    .{ "SELECT 'a b:1'::tsvector", "'a' 'b':1" },
    .{ "SELECT 'a:1 a:2 a:1B'::tsvector", "'a':1B,2" },
    .{ "SELECT 'a:0'::tsvector", "!42601" },
    .{ "SELECT 'a:'::tsvector", "!42601" },
    .{ "SELECT ''''::tsvector", "!42601" },
    .{ "SELECT '''a'::tsvector", "!42601" },
    .{ "SELECT 'a:1x'::tsvector", "!42601" },
    .{ "SELECT 'a:1,'::tsvector", "!42601" },
    .{ "SELECT ':1'::tsvector", "':1'" },
    .{ "SELECT 'a :1'::tsvector", "':1' 'a'" },
    .{ "SELECT 'a:1AB'::tsvector", "!42601" },
    .{ "SELECT ''''''::tsvector", "!42601" },
    .{ "SELECT 'é:1 è:2'::tsvector", "'è':2 'é':1" },
    .{ "SELECT 'a'::tsquery", "'a'" },
    .{ "SELECT 'a & b'::tsquery", "'a' & 'b'" },
    .{ "SELECT 'a | b'::tsquery", "'a' | 'b'" },
    .{ "SELECT '!a'::tsquery", "!'a'" },
    .{ "SELECT 'a & b | c'::tsquery", "'a' & 'b' | 'c'" },
    .{ "SELECT 'a | b & c'::tsquery", "'a' | 'b' & 'c'" },
    .{ "SELECT '(a | b) & c'::tsquery", "( 'a' | 'b' ) & 'c'" },
    .{ "SELECT 'a <-> b'::tsquery", "'a' <-> 'b'" },
    .{ "SELECT 'a <2> b'::tsquery", "'a' <2> 'b'" },
    .{ "SELECT 'a <0> b'::tsquery", "'a' <0> 'b'" },
    .{ "SELECT 'a <-> (b | c)'::tsquery", "'a' <-> ( 'b' | 'c' )" },
    .{ "SELECT '(a <-> b) <-> c'::tsquery", "'a' <-> 'b' <-> 'c'" },
    .{ "SELECT 'a <-> (b <-> c)'::tsquery", "'a' <-> ( 'b' <-> 'c' )" },
    .{ "SELECT '!(a & b)'::tsquery", "!( 'a' & 'b' )" },
    .{ "SELECT '!a & !b'::tsquery", "!'a' & !'b'" },
    .{ "SELECT '!!a'::tsquery", "!!'a'" },
    .{ "SELECT 'a:*'::tsquery", "'a':*" },
    .{ "SELECT 'a:AB'::tsquery", "'a':AB" },
    .{ "SELECT 'a:*AB'::tsquery", "'a':*AB" },
    .{ "SELECT 'a:ab*'::tsquery", "'a':*AB" },
    .{ "SELECT '''a b'''::tsquery", "'a b'" },
    .{ "SELECT '''it''''s'''::tsquery", "'it''s'" },
    .{ "SELECT 'a & (b | (c & d))'::tsquery", "'a' & ( 'b' | 'c' & 'd' )" },
    .{ "SELECT 'a & b & c'::tsquery", "'a' & 'b' & 'c'" },
    .{ "SELECT 'a <-> b & c'::tsquery", "'a' <-> 'b' & 'c'" },
    .{ "SELECT '!a <-> b'::tsquery", "!'a' <-> 'b'" },
    .{ "SELECT '(a & b) <-> c'::tsquery", "( 'a' & 'b' ) <-> 'c'" },
    .{ "SELECT 'a | b <-> c'::tsquery", "'a' | 'b' <-> 'c'" },
    .{ "SELECT ''::tsquery", "" },
    .{ "SELECT ' '::tsquery", "" },
    .{ "SELECT 'a b'::tsquery", "!42601" },
    .{ "SELECT 'a &'::tsquery", "!42601" },
    .{ "SELECT '& a'::tsquery", "!42601" },
    .{ "SELECT '(a'::tsquery", "!42601" },
    .{ "SELECT 'a)'::tsquery", "!42601" },
    .{ "SELECT 'a <16385> b'::tsquery", "!22023" },
    .{ "SELECT 'a <-1> b'::tsquery", "!42601" },
    .{ "SELECT 'a <x> b'::tsquery", "!42601" },
    .{ "SELECT '()'::tsquery", "!42601" },
    .{ "SELECT 'a:z'::tsquery", "!42601" },
    .{ "SELECT '''a'':A'::tsquery", "'a':A" },
    .{ "SELECT 'a <16384> b'::tsquery", "'a' <16384> 'b'" },
    .{ "SELECT 'A & B'::tsquery", "'A' & 'B'" },
    .{ "SELECT to_tsquery('simple', 'one')", "'one'" },
    .{ "SELECT to_tsquery('simple', 'one & two')", "'one' & 'two'" },
    .{ "SELECT to_tsquery('simple', 'foo-bar')", "'foo-bar' <-> 'foo' <-> 'bar'" },
    .{ "SELECT to_tsquery('simple', 'The Fat Rats')", "!42601" },
    .{ "SELECT to_tsquery('simple', 'a:*')", "'a':*" },
    .{ "SELECT to_tsquery('simple', 'a & -')", "'a'" },
    .{ "SELECT to_tsquery('simple', '-')", "" },
    .{ "SELECT to_tsquery('simple', '')", "" },
    .{ "SELECT to_tsquery('simple', 'x@y.com')", "'x@y.com'" },
    .{ "SELECT to_tsquery('simple', 'one <-> two')", "'one' <-> 'two'" },
    .{ "SELECT to_tsquery('simple', '(a | b) & c')", "( 'a' | 'b' ) & 'c'" },
    .{ "SELECT to_tsquery('simple', 'a b')", "!42601" },
    .{ "SELECT to_tsquery('simple', 'a:B & b:*A')", "'a':B & 'b':*A" },
    .{ "SELECT to_tsquery('simple', 'Über alles')", "!42601" },
    .{ "SELECT to_tsquery('simple', 'a & - & b')", "'a' & 'b'" },
    .{ "SELECT to_tsquery('simple', 'a <-> - <-> b')", "'a' <2> 'b'" },
    .{ "SELECT to_tsquery('simple', '!-')", "" },
    .{ "SELECT to_tsquery('simple', 'a | (- & b)')", "'a' | 'b'" },
    .{ "SELECT plainto_tsquery('simple', 'one')", "'one'" },
    .{ "SELECT plainto_tsquery('simple', 'one & two')", "'one' & 'two'" },
    .{ "SELECT plainto_tsquery('simple', 'foo-bar')", "'foo-bar' & 'foo' & 'bar'" },
    .{ "SELECT plainto_tsquery('simple', 'The Fat Rats')", "'the' & 'fat' & 'rats'" },
    .{ "SELECT plainto_tsquery('simple', 'a:*')", "'a'" },
    .{ "SELECT plainto_tsquery('simple', 'a & -')", "'a'" },
    .{ "SELECT plainto_tsquery('simple', '-')", "" },
    .{ "SELECT plainto_tsquery('simple', '')", "" },
    .{ "SELECT plainto_tsquery('simple', 'x@y.com')", "'x@y.com'" },
    .{ "SELECT plainto_tsquery('simple', 'one <-> two')", "'one' & 'two'" },
    .{ "SELECT plainto_tsquery('simple', '(a | b) & c')", "'a' & 'b' & 'c'" },
    .{ "SELECT plainto_tsquery('simple', 'a b')", "'a' & 'b'" },
    .{ "SELECT plainto_tsquery('simple', 'a:B & b:*A')", "'a' & 'b' & 'b' & 'a'" },
    .{ "SELECT plainto_tsquery('simple', 'Über alles')", "'Über' & 'alles'" },
    .{ "SELECT plainto_tsquery('simple', 'a & - & b')", "'a' & 'b'" },
    .{ "SELECT plainto_tsquery('simple', 'a <-> - <-> b')", "'a' & 'b'" },
    .{ "SELECT plainto_tsquery('simple', '!-')", "" },
    .{ "SELECT plainto_tsquery('simple', 'a | (- & b)')", "'a' & 'b'" },
    .{ "SELECT phraseto_tsquery('simple', 'one')", "'one'" },
    .{ "SELECT phraseto_tsquery('simple', 'one & two')", "'one' <-> 'two'" },
    .{ "SELECT phraseto_tsquery('simple', 'foo-bar')", "'foo-bar' <-> 'foo' <-> 'bar'" },
    .{ "SELECT phraseto_tsquery('simple', 'The Fat Rats')", "'the' <-> 'fat' <-> 'rats'" },
    .{ "SELECT phraseto_tsquery('simple', 'a:*')", "'a'" },
    .{ "SELECT phraseto_tsquery('simple', 'a & -')", "'a'" },
    .{ "SELECT phraseto_tsquery('simple', '-')", "" },
    .{ "SELECT phraseto_tsquery('simple', '')", "" },
    .{ "SELECT phraseto_tsquery('simple', 'x@y.com')", "'x@y.com'" },
    .{ "SELECT phraseto_tsquery('simple', 'one <-> two')", "'one' <-> 'two'" },
    .{ "SELECT phraseto_tsquery('simple', '(a | b) & c')", "'a' <-> 'b' <-> 'c'" },
    .{ "SELECT phraseto_tsquery('simple', 'a b')", "'a' <-> 'b'" },
    .{ "SELECT phraseto_tsquery('simple', 'a:B & b:*A')", "'a' <-> 'b' <-> 'b' <-> 'a'" },
    .{ "SELECT phraseto_tsquery('simple', 'Über alles')", "'Über' <-> 'alles'" },
    .{ "SELECT phraseto_tsquery('simple', 'a & - & b')", "'a' <-> 'b'" },
    .{ "SELECT phraseto_tsquery('simple', 'a <-> - <-> b')", "'a' <-> 'b'" },
    .{ "SELECT phraseto_tsquery('simple', '!-')", "" },
    .{ "SELECT phraseto_tsquery('simple', 'a | (- & b)')", "'a' <-> 'b'" },
    .{ "SELECT to_tsvector('Simple', 'x')", "'x':1" },
    .{ "SELECT to_tsvector(' simple', 'x')", "'x':1" },
    .{ "SELECT to_tsvector('pg_catalog.simple', 'x')", "'x':1" },
    .{ "SELECT to_tsvector('PG_CATALOG.SIMPLE', 'x')", "'x':1" },
    .{ "SELECT to_tsvector('\"simple\"', 'x')", "'x':1" },
    .{ "SELECT to_tsvector('\"Simple\"', 'x')", "!42704" },
    .{ "SELECT to_tsvector('nope', 'x')", "!42704" },
    .{ "SELECT to_tsvector('public.simple', 'x')", "!42704" },
    .{ "SELECT to_tsvector('simple.x', 'x')", "!42704" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'three')", "f" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one & two')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one & three')", "f" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one | three')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', '!three')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', '!one')", "f" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one <-> two')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'two <-> one')", "f" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one <2> two')", "f" },
    .{ "SELECT to_tsvector('simple', 'one x two') @@ to_tsquery('simple', 'one <2> two')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'on:*')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'tw:* <-> o:*')", "f" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'one <0> one')", "t" },
    .{ "SELECT to_tsvector('simple', 'fat rat') @@ to_tsquery('simple', 'fat <-> !cat')", "t" },
    .{ "SELECT to_tsvector('simple', 'fat cat') @@ to_tsquery('simple', 'fat <-> !cat')", "f" },
    .{ "SELECT to_tsvector('simple', 'fat cat rat') @@ to_tsquery('simple', 'fat <-> (cat | rat)')", "t" },
    .{ "SELECT to_tsvector('simple', 'fat rat') @@ to_tsquery('simple', 'fat <-> (cat | rat)')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b c') @@ to_tsquery('simple', 'a <-> (b <-> c)')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b c') @@ to_tsquery('simple', '(a <-> b) <-> c')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b c') @@ to_tsquery('simple', 'a <2> c & b')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b c') @@ to_tsquery('simple', '!a <-> b')", "f" },
    .{ "SELECT to_tsvector('simple', 'x b c') @@ to_tsquery('simple', '!a <-> b')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b') @@ to_tsquery('simple', '(a & b) <-> b')", "f" },
    .{ "SELECT to_tsvector('simple', 'a a b') @@ to_tsquery('simple', 'a <-> a <-> b')", "t" },
    .{ "SELECT to_tsvector('simple', 'one two') @@ to_tsquery('simple', 'ONE')", "t" },
    .{ "SELECT to_tsvector('simple', 'foo-bar') @@ to_tsquery('simple', 'foo-bar')", "t" },
    .{ "SELECT to_tsvector('simple', 'foo-bar') @@ to_tsquery('simple', 'foo <-> bar')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b') @@ to_tsquery('simple', '!(a <-> c)')", "t" },
    .{ "SELECT to_tsvector('simple', 'a b') @@ to_tsquery('simple', '!(a <-> b)')", "f" },
    .{ "SELECT 'a:1A b:2'::tsvector @@ 'a:A'::tsquery", "t" },
    .{ "SELECT 'a:1A b:2'::tsvector @@ 'a:B'::tsquery", "f" },
    .{ "SELECT 'a:1A b:2'::tsvector @@ 'b:D'::tsquery", "t" },
    .{ "SELECT 'a b'::tsvector @@ 'a <-> b'::tsquery", "f" },
    .{ "SELECT 'a b'::tsvector @@ 'a & b'::tsquery", "t" },
    .{ "SELECT 'a b'::tsvector @@ 'a:A'::tsquery", "t" },
    .{ "SELECT 'a:1 b:3'::tsvector @@ 'a <2> b'::tsquery", "t" },
    .{ "SELECT 'a'::tsquery @@ 'a b'::tsvector", "t" },
    .{ "SELECT 'a'::tsvector @@ ''::tsquery", "f" },
    .{ "SELECT NULL::tsvector @@ 'a'::tsquery", "NULL" },
    .{ "SELECT 'abc:1 abd:2'::tsvector @@ 'ab:* <-> abd'::tsquery", "t" },
    .{ "SELECT 'abc:1 abd:3'::tsvector @@ 'ab:* <-> abd'::tsquery", "f" },
    .{ "SELECT 'x:1A y:2'::tsvector @@ 'x:A <-> y'::tsquery", "t" },
    .{ "SELECT 'x:1B y:2'::tsvector @@ 'x:A <-> y'::tsquery", "f" },
    .{ "SELECT to_tsvector('simple', 'a') @@ 'a'", "t" },
    .{ "SELECT 'a'::tsvector @@ 'a'::text", "!42883" },
    .{ "SELECT to_tsvector('simple', 'x')::text", "'x':1" },
    .{ "SELECT 'x y'::text::tsvector", "'x' 'y'" },
    .{ "SELECT pg_typeof('a'::tsvector)", "tsvector" },
    .{ "SELECT pg_typeof(plainto_tsquery('simple','a'))", "tsquery" },
    .{ "SELECT to_tsvector('simple', NULL)", "NULL" },
    .{ "SELECT to_tsquery(NULL, 'a')", "NULL" },
    .{ "SELECT to_tsvector('simple', '''-://.mailtowww?9日wwwx''-<z')", "'/.mailtowww':1 '9日wwwx':2 'z':3" },
    .{ "SELECT to_tsvector('simple', '%z&üyA<bawww?-~>%')", "'bawww':3 'z':1 'üya':2" },
    .{ "SELECT to_tsvector('simple', 'org--.-')", "'org':1" },
    .{ "SELECT to_tsvector('simple', '0=1.5a>btxtAscriptftpe3=comxv2')", "'0':1 '1.5':2 'a':3 'btxtascriptftpe3':4 'comxv2':5" },
    .{ "SELECT to_tsvector('simple', '0\"0.>/9-=zA://')", "'/9-':3 '0':1,2" },
    .{ "SELECT to_tsvector('simple', 'txté.y//y_y ')", "'/y_y':3 'txté':1 'y':2" },
    .{ "SELECT to_tsvector('simple', 'style日0script;日0b')", "'style日0script':1 '日0b':2" },
    .{ "SELECT to_tsvector('simple', '>by>yv20;\"%ba=azorg')", "'azorg':4 'ba':3 'by':1 'yv20':2" },
    .{ "SELECT to_tsvector('simple', ';''ω://com@Béa')", "'/com':2 'béa':3 'ω':1" },
    .{ "SELECT to_tsvector('simple', '-; /:1.5-=e3scriptc~')", "'1.5':1 'e3scriptc':2" },
    .{ "SELECT to_tsvector('simple', '//_=é c')", "'/_':1 'c':3 'é':2" },
    .{ "SELECT to_tsvector('simple', 'c~>b?b~scriptB')", "'b':2,3 'c':1 '~scriptb':4" },
    .{ "SELECT to_tsvector('simple', 'v2-//aω.v2日9@txt--httpü;')", "'/a':2 'httpü':6 'txt':5 'v2':1 'v2日9':4 'ω':3" },
    .{ "SELECT to_tsvector('simple', '_orgtxt>&bze3~bcomce30日')", "'bze3':2 'orgtxt':1 '~bcomce30':3 '日':4" },
    .{ "SELECT to_tsvector('simple', ' éz <9:=_1日éorg=www?B')", "'1日éorg':3 '9':2 'b':5 'www':4 'éz':1" },
    .{ "SELECT to_tsvector('simple', 'style--?\";\"Ahttp0bscriptmailto#//org:')", "'/org':3 'ahttp0bscriptmailto':2 'style':1" },
    .{ "SELECT to_tsvector('simple', '!1.59ω日scriptv2')", "'1.59':1 'ω日scriptv2':2" },
    .{ "SELECT to_tsvector('simple', '&-amp00:')", "'amp00':1" },
    .{ "SELECT to_tsvector('simple', '1.50httpv2+://;-\"wwwü\"style')", "'1.50':1 'httpv2':2 'style':4 'wwwü':3" },
    .{ "SELECT to_tsvector('simple', 'styleA0''')", "'stylea0':1" },
    .{ "SELECT to_tsvector('simple', '&!!')", "" },
    .{ "SELECT to_tsvector('simple', 'ac.+?9http')", "'9http':2 'ac':1" },
    .{ "SELECT to_tsvector('simple', '?-;:B9?e3+..')", "'b9':1 'e3':2" },
    .{ "SELECT to_tsvector('simple', '>ax')", "'ax':1" },
    .{ "SELECT to_tsvector('simple', '>?ω://_?borg')", "'/_':2 'borg':3 'ω':1" },
    .{ "SELECT to_tsvector('simple', '?-aftp;ü日A')", "'aftp':1 'ü日a':2" },
    .{ "SELECT to_tsvector('simple', 'yc99ωxé日><~<<x9')", "'x9':2 'yc99ωxé日':1" },
    .{ "SELECT to_tsvector('simple', '=e3x&x\"/org''xB1.5_#')", "'/org':3 'e3x':1 'x':2 'xb1.5_':4" },
    .{ "SELECT to_tsvector('simple', 'v2%:%日00org>#-/x-ca!')", "'/x-ca':3 'v2':1 '日00org':2" },
    .{ "SELECT to_tsvector('simple', 'A')", "'a':1" },
    .{ "SELECT to_tsvector('simple', 'y9+#e30y ')", "'e30y':2 'y9':1" },
    .{ "SELECT to_tsvector('simple', ':1&.+''z')", "'1':1 'z':2" },
    .{ "SELECT to_tsvector('simple', '//''aampzé&1e3B ~>@日v2b?')", "'1e3':2 'aampzé':1 'b':3 '日v2b':4" },
    .{ "SELECT to_tsvector('simple', '+ωstyle--<@ωmailto!mailtoz~&')", "'mailtoz':3 'ωmailto':2 'ωstyle':1" },
    .{ "SELECT to_tsvector('simple', 'script1.5x')", "'script1.5x':1" },
    .{ "SELECT to_tsvector('simple', '日'';;éyc#=''ba%1style=')", "'1style':4 'ba':3 'éyc':2 '日':1" },
    .{ "SELECT to_tsvector('simple', '=<xB1.')", "'xb1':1" },
    .{ "SELECT to_tsvector('simple', 'bc')", "'bc':1" },
    .{ "SELECT to_tsvector('simple', 'style/\"@~>\"é;z@')", "'style':1 'z':3 'é':2" },
    .{ "SELECT to_tsvector('simple', 'script=日x/\" %9&://ftpx')", "'/ftpx':4 '9':3 'script':1 '日x':2" },
    .{ "SELECT to_tsvector('simple', '.scriptz日//')", "'scriptz日':1" },
    .{ "SELECT to_tsvector('simple', '://-z 1.59>?mailtoy0txtBa\"')", "'1.59':2 'mailtoy0txtba':3 'z':1" },
    .{ "SELECT to_tsvector('simple', 'Ba_1=>?z')", "'1':2 'ba':1 'z':3" },
    .{ "SELECT to_tsvector('simple', 'txt;~;=script0.txt')", "'script0.txt':2 'txt':1" },
    .{ "SELECT to_tsvector('simple', 'zwww')", "'zwww':1" },
    .{ "SELECT to_tsvector('simple', '!y!01=')", "'01':2 'y':1" },
    .{ "SELECT to_tsvector('simple', '%?&/日e3mailtoA_<9ω@ü-日')", "'9ω':2 'ü':4 'ü-日':3 '日':5 '日e3mailtoa':1" },
    .{ "SELECT to_tsvector('simple', 'b-01.5;v2B')", "'-01.5':2 'b':1 'v2b':3" },
    .{ "SELECT to_tsvector('simple', '0com:e3Ba+v2.y?script=b1.5')", "'0com':1 'b1.5':5 'e3ba':2 'script':4 'v2.y':3" },
    .{ "SELECT to_tsvector('simple', '://?://x;www1é\"%é''%B日')", "'/x':1 'b日':4 'www1é':2 'é':3" },
    .{ "SELECT to_tsvector('simple', '!bx!&>y--txt\"日')", "'bx':1 'txt':3 'y':2 '日':4" },
    .{ "SELECT to_tsvector('simple', '?y+%91.5yscript')", "'91.5':2 'y':1 'yscript':3" },
    .{ "SELECT to_tsvector('simple', '''xby')", "'xby':1" },
    .{ "SELECT to_tsvector('simple', '日#@http&é//-xv2bamp/www>')", "'http':2 'xv2bamp/www':4 'é':3 '日':1" },
    .{ "SELECT to_tsvector('simple', '~0 9mailtoamp/<+日日')", "'9mailtoamp':2 '~0':1 '日日':3" },
    .{ "SELECT to_tsvector('simple', '.~comy日wwwmailto!')", "'comy日wwwmailto':1" },
    .{ "SELECT to_tsvector('simple', 'ampftpb')", "'ampftpb':1" },
    .{ "SELECT to_tsvector('simple', '1c=//com+')", "'/com':2 '1c':1" },
    .{ "SELECT to_tsvector('simple', 'cü日ωstyle1.5--:/ω//')", "'cü日ωstyle1.5--':1 'ω':2" },
    .{ "SELECT to_tsvector('simple', 'www.b!:bstyleω/')", "'bstyleω':2 'www.b':1" },
    .{ "SELECT to_tsvector('simple', '1.5e3日é://')", "'1.5e3':1 '日é':2" },
    .{ "SELECT to_tsvector('simple', '/--1.5_cscript')", "'-1.5':1 'cscript':2" },
    .{ "SELECT to_tsvector('simple', '日c1.51mailto')", "'日c1.51mailto':1" },
    .{ "SELECT to_tsvector('simple', 'y@B/z+_txtx.?_xv2style?')", "'b/z':2 'txtx':3 'xv2style':4 'y':1" },
    .{ "SELECT to_tsvector('simple', '>é._%ftp~')", "'ftp':2 'é':1" },
    .{ "SELECT to_tsvector('simple', ':')", "" },
    .{ "SELECT to_tsvector('simple', '_+v2xBe3 txt日>/-scriptmailto\"0:')", "'0':4 'scriptmailto':3 'txt日':2 'v2xbe3':1" },
    .{ "SELECT to_tsvector('simple', '=ampω?://@v2_http\">')", "'ampω':1 'http':3 'v2':2" },
    .{ "SELECT to_tsvector('simple', '_#+')", "" },
    .{ "SELECT to_tsvector('simple', ':1.5//txt<~txtstyle')", "'/txt':2 '1.5':1 'txtstyle':3" },
    .{ "SELECT to_tsvector('simple', '/;1:>bBy~//>&')", "'1':1 'bby':2" },
    .{ "SELECT to_tsvector('simple', 'www+:.=+ampx%')", "'ampx':2 'www':1" },
    .{ "SELECT to_tsvector('simple', 'com =script~+bamp:/ωa//z')", "'/z':5 'bamp':3 'com':1 'script':2 'ωa':4" },
    .{ "SELECT to_tsvector('simple', ';A&_99//<<ω/.0y>--\"1.5')", "'/.0y':4 '1.5':5 '99':2 'a':1 'ω':3" },
    .{ "SELECT to_tsvector('simple', 'ftp?:&amp0%0~0mailtostyle\"0~?')", "'0':3,5 'amp0':2 'ftp':1 '~0mailtostyle':4" },
    .{ "SELECT to_tsvector('simple', '0org-ωBb\"com<1.5=_1')", "'0org':2 '0org-ωbb':1 '1':6 '1.5':5 'com':4 'ωbb':3" },
    .{ "SELECT to_tsvector('simple', 'org:!e3~1?@amp:1mailtoa//amp')", "'/amp':6 '1mailtoa':5 'amp':4 'e3':2 'org':1 '~1':3" },
    .{ "SELECT to_tsvector('simple', '%?_:< xhttpωcomb>--amp')", "'amp':2 'xhttpωcomb':1" },
    .{ "SELECT to_tsvector('simple', 'a:é')", "'a':1 'é':2" },
    .{ "SELECT to_tsvector('simple', 'ωA\"%bscripttxtü+ ~e3:')", "'bscripttxtü':2 'e3':3 'ωa':1" },
    .{ "SELECT to_tsvector('simple', 'stylescript_orgv2!txt?ampstyleA')", "'ampstylea':4 'orgv2':2 'stylescript':1 'txt':3" },
    .{ "SELECT to_tsvector('simple', '@.y&#atxtxv2!B')", "'atxtxv2':2 'b':3 'y':1" },
    .{ "SELECT to_tsvector('simple', '''''==')", "" },
    .{ "SELECT to_tsvector('simple', 'ü日 c&--:&//?scriptéstyle1A:www:')", "'c':2 'scriptéstyle1a':3 'www':4 'ü日':1" },
    .{ "SELECT to_tsvector('simple', '''http-/--éyxy1.www@B=--y')", "'b':3 'http':1 'y':4 'éyxy1.www':2" },
    .{ "SELECT to_tsvector('simple', '_&-')", "" },
    .{ "SELECT to_tsvector('simple', '!;~_.9''ftpv2#a_+%com!%0')", "'0':5 '9':1 'a':3 'com':4 'ftpv2':2" },
    .{ "SELECT to_tsvector('simple', 'org%org<z''//% +<~a/v2ftp~')", "'a/v2ftp':4 'org':1,2 'z':3" },
    .{ "SELECT to_tsvector('simple', 'orgA_v2http#b1+://x')", "'/x':4 'b1':3 'orga':1 'v2http':2" },
    .{ "SELECT to_tsvector('simple', '?@By?__1')", "'1':2 'by':1" },
    .{ "SELECT to_tsvector('simple', 'zftp\"B1v2b1.5ωAüy0ü</1.5')", "'/1.5':4 'b1v2b1.5':2 'zftp':1 'ωaüy0ü':3" },
    .{ "SELECT to_tsvector('simple', 'amp9''orgü://orgaorg=://?mailtoωc')", "'/orgaorg':3 'amp9':1 'mailtoωc':4 'orgü':2" },
    .{ "SELECT to_tsvector('simple', 'zorg%éscriptüA>:com\"!B')", "'b':4 'com':3 'zorg':1 'éscriptüa':2" },
    .{ "SELECT to_tsvector('simple', '日://')", "'日':1" },
    .{ "SELECT to_tsvector('simple', '?Ac\"日é+Av2++_x')", "'ac':1 'av2':3 'x':4 '日é':2" },
    .{ "SELECT to_tsvector('simple', 'org#comftp!+<Ax;script')", "'ax':3 'comftp':2 'org':1 'script':4" },
    .{ "SELECT to_tsvector('simple', '<//com;b')", "'/com':1 'b':2" },
    .{ "SELECT to_tsvector('simple', 'a\"ycom0 B')", "'a':1 'b':3 'ycom0':2" },
    .{ "SELECT to_tsvector('simple', 'y#B?B_e3Bftpc=//=\"style')", "'b':2,3 'e3bftpc':4 'style':5 'y':1" },
    .{ "SELECT to_tsvector('simple', 'v2#日 ''1?éftp%:')", "'1':3 'v2':1 'éftp':4 '日':2" },
    .{ "SELECT to_tsvector('simple', ':_y')", "'y':1" },
    .{ "SELECT to_tsvector('simple', '1.5''Borgüc#é1#Ascriptamp#amp++mailto')", "'1.5':1 'amp':5 'ascriptamp':4 'borgüc':2 'mailto':6 'é1':3" },
    .{ "SELECT to_tsvector('simple', 'v2ftp<0y<ütxtscript')", "'0y':2 'v2ftp':1 'ütxtscript':3" },
    .{ "SELECT to_tsvector('simple', '9:!')", "'9':1" },
    .{ "SELECT to_tsvector('simple', 'ω--#ü#yByaorgv21')", "'ybyaorgv21':3 'ü':2 'ω':1" },
    .{ "SELECT to_tsvector('simple', 'y1.5')", "'y1.5':1" },
    .{ "SELECT to_tsvector('simple', '日!.v2-')", "'v2':2 '日':1" },
    .{ "SELECT to_tsvector('simple', 'é//commailto')", "'/commailto':2 'é':1" },
    .{ "SELECT to_tsvector('simple', '~ω1b&z9cmailto')", "'z9cmailto':2 'ω1b':1" },
    .{ "SELECT to_tsvector('simple', 'b1日zcom_@;txtx')", "'b1日zcom':1 'txtx':2" },
    .{ "SELECT to_tsvector('simple', 'v2;#/%script--;ftp')", "'ftp':3 'script':2 'v2':1" },
    .{ "SELECT to_tsvector('simple', 'bx://_/züampscript#com=%@_<y')", "'/z':1 'com':3 'y':4 'üampscript':2" },
    .{ "SELECT to_tsvector('simple', 'awwwy9amp//&0e3-x''B1y#')", "'0e3':2 'awwwy9amp':1 'b1y':4 'x':3" },
    .{ "SELECT to_tsvector('simple', 'e3org')", "'e3org':1" },
    .{ "SELECT to_tsvector('simple', 'ω 日zxmailtoüe3A')", "'ω':1 '日zxmailtoüe3a':2" },
    .{ "SELECT to_tsvector('simple', '''é-//b?<style_b')", "'/b':2 'b':4 'style':3 'é':1" },
    .{ "SELECT to_tsvector('simple', 'éy.9c+:&')", "'9c':2 'éy':1" },
    .{ "SELECT to_tsvector('simple', '%''éstyle<&')", "'éstyle':1" },
    .{ "SELECT to_tsvector('simple', '?e3AaBüa?')", "'e3aabüa':1" },
    .{ "SELECT to_tsvector('simple', '''e3\"script~xwwwtxt:')", "'e3':1 'script':2 '~xwwwtxt':3" },
};

fn textSearch() !void {
    // oracle: PG.TEXT.SEARCH.
    try rows("SELECT to_tsvector('simple','one two') @@ to_tsquery('simple','one')", "t");
    try meta(0, "?column?", 16, -1);
    try rows("SELECT to_tsvector('simple','one two'), to_tsquery('simple','one'), plainto_tsquery('simple','one two'), phraseto_tsquery('simple','one two')", "'one':1 'two':2|'one'|'one' & 'two'|'one' <-> 'two'");
    try meta(0, "to_tsvector", 3614, -1);
    try meta(1, "to_tsquery", 3615, -1);
    try meta(2, "plainto_tsquery", 3615, -1);
    try meta(3, "phraseto_tsquery", 3615, -1);
    try rows("SELECT 'a:1 b'::tsvector, 'a & b'::tsquery", "'a':1 'b'|'a' & 'b'");
    try meta(0, "tsvector", 3614, -1);
    try meta(1, "tsquery", 3615, -1);
    for (fts_battery) |case| try single(case[0], case[1]);

    // Not here (0A000): the Snowball configurations, and the forms that
    // use default_text_search_config (pg_catalog.english).
    for ([_][]const u8{
        "SELECT to_tsvector('english', 'x')",     "SELECT to_tsvector('x')",
        "SELECT to_tsquery('x')",                 "SELECT plainto_tsquery('x')",
        "SELECT 'a' @@ to_tsquery('simple', 'a')", "SELECT 'a b' @@ 'a b'",
    }) |source| try rejects(source, error.UnsupportedStatement);
    try rejects("SELECT to_tsvector('nope', 'x')", error.UndefinedObject);
    try rejects("SELECT 'a <16385> b'::tsquery", error.InvalidParameterValue);
    try rejects("SELECT 'a:0'::tsvector", error.Syntax);
    // A non-literal configuration has no regconfig to resolve.
    try rejects("SELECT to_tsvector(name, 'x') FROM (VALUES ('simple')) v(name)", error.UndefinedFunction);

    // No comparison, ordering or grouping operators here (42883).
    try exec("CREATE TABLE docs(id INT PRIMARY KEY, body TEXT, tsv TSVECTOR, q TSQUERY)");
    try exec("INSERT INTO docs VALUES (1, 'The fat cat', to_tsvector('simple', 'The fat cat'), 'fat & cat'), (2, 'A lean rat', to_tsvector('simple', 'A lean rat'), to_tsquery('simple', 'rat <-> !cat')), (3, NULL, NULL, NULL)");
    try rows("SELECT id, tsv FROM docs ORDER BY id", "1|'cat':3 'fat':2 'the':1;2|'a':1 'lean':2 'rat':3;3|NULL");
    try rows("SELECT id FROM docs WHERE tsv @@ to_tsquery('simple', 'fat | rat') ORDER BY id", "1;2");
    try rows("SELECT a.id, b.id FROM docs a, docs b WHERE a.tsv @@ b.q ORDER BY a.id, b.id", "1|1;2|2");
    try rows("SELECT id, q @@ tsv, to_tsvector('simple', body) @@ 'cat:*' FROM docs ORDER BY id", "1|t|t;2|t|f;3|NULL|NULL");
    try rows("SELECT tsv::text, q::text FROM docs WHERE id = 2", "'a':1 'lean':2 'rat':3|'rat' <-> !'cat'");
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'docs' AND column_name IN ('tsv', 'q') ORDER BY column_name", "tsquery;tsvector");
    try rows("SELECT typname, typlen, typcategory, typarray FROM pg_type WHERE oid IN (3614, 3615) ORDER BY oid", "tsvector|-1|U|3643;tsquery|-1|U|3645");
    try rejects("SELECT tsv FROM docs ORDER BY tsv", error.UndefinedFunction);
    try rejects("SELECT DISTINCT q FROM docs", error.UndefinedFunction);
    try rejects("SELECT tsv = tsv FROM docs", error.UndefinedFunction);
    try rejects("INSERT INTO docs VALUES (4, 'x', 'a:0', NULL)", error.Syntax);
    try rejects("INSERT INTO docs VALUES (4, 'x', NULL, 'a &'), (5, 'y', NULL, NULL)", error.Syntax);
    try rejects("INSERT INTO docs VALUES (4, 'x', 'a'::text, NULL)", error.TypeMismatch);
    try rows("SELECT COUNT(*) FROM docs", "3");

    // Parsing and matching are budgeted and cancellable.
    try controlled("SELECT to_tsvector('simple', 'alpha beta-gamma http://x.org/a 1.2.3 x@y.com') @@ to_tsquery('simple', 'beta <-> gamma | x.org')", "t");
    try controlled("SELECT id FROM docs WHERE tsv @@ to_tsquery('simple', '(fat & !rat) | (lean <-> rat)') ORDER BY id", "1;2");

    // Wire: text both ways; binary forms are not provided (0A000).
    try exec("SELECT 'a:1 b'::tsvector, 'a & b'::tsquery");
    try check(Wire.oid(.tsvector) == 3614 and Wire.oid(.tsquery) == 3615 and Wire.length(.tsvector) == -1);
    try sendText(&result.rows[0].cells[0], "'a':1 'b'");
    try sendText(&result.rows[0].cells[1], "'a' & 'b'");
    var out: [64]u8 = undefined;
    try check(if (Wire.sendBinary(&result.rows[0].cells[0], .tsvector, &db.session, &out)) |_| false else |err| err == error.UnsupportedBinaryType);

    // Durability: change-record value tags 28 (tsvector) and 29 (tsquery)
    // carry the canonical text, re-read on replay.
    try replay(&.{
        "CREATE TABLE ft(id INT PRIMARY KEY, tsv TSVECTOR, q TSQUERY)",
        "INSERT INTO ft VALUES (1, to_tsvector('simple', 'Hello world, hello'), to_tsquery('simple', 'hello & !bye')), (2, NULL, 'a:*B <2> b')",
        "UPDATE ft SET tsv = 'z:1A'::tsvector WHERE id = 2",
    }, &.{"ft"}, "SELECT id, tsv, q, tsv @@ q FROM ft ORDER BY id");
    try replicaShows("1|'hello':1,3 'world':2|'hello' & !'bye'|t;2|'z':1A|'a':*B <2> 'b'|f");
    try exec("DROP TABLE docs");
}

pub fn main(init: std.process.Init) !void {
    try baseFixture();
    try discovery();
    try collations();
    try regularExpressions();
    try textSearch();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-text\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
