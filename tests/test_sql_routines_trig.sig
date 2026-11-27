//! Routine and trigger contracts (conformance lane B11, wave 5,
//! routines-trig lane, docs/SQL_ROUTINES.md "Wave 5"): SQL-schema
//! statements in SQL and PL/pgSQL routines (T651, T653) with dynamic
//! EXECUTE, void functions in expressions, PL/pgSQL's I/O assignment
//! conversion, search-path resolution of routines and types with
//! pg_catalog's place honoured (S071), user-defined casts (S211), routine
//! security (T323), the routine context diagnostics, transition tables and
//! constraint triggers (T212), referential actions and COPY FROM firing user
//! triggers, and the remaining rule actions. Each section checks values
//! (PostgreSQL 18 text output), command tags, exact errors (SQLSTATE through
//! the error name), atomicity after a failure and replay: every committed
//! record is applied to a replica that must answer every probe exactly like
//! the primary. Expected values were checked against native PostgreSQL
//! 18.7. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 16, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 96, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 4, .expr_nodes = 512, .routines = 24, .triggers = 12, .rules = 8, .routine_depth = 32, .nested_statements = 8, .work_rows = 256, .schemas = 6 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("routines-trig contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.RoutinesTrigContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
var query_values: [DB.Result.value_bytes]u8 = undefined;
var result_slot: DB.Result = .{};
var other_slot: DB.Result = .{};

/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
fn render(result: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
    for (0..result.row_count) |row| {
        if (row != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &result.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn query(target: *DB, source: []const u8) ![]const u8 {
    const result = &result_slot;
    result.* = .{};
    result.bindValueMemory(&query_values);
    target.execute(source, result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !*DB.Result {
    const result = &result_slot;
    result.* = .{};
    result.bindValueMemory(&query_values);
    var used: usize = 0;
    db.executeChanges(source, result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (used != 0) {
        replica.applyChangeRecord(record[0..used], &scratch) catch |err| {
            std.debug.print("replay of {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        records_applied += 1;
    }
    return result;
}

fn run(source: []const u8) !void {
    _ = try replicate(source);
}

/// The replicated statement returns these rows.
fn returns(source: []const u8, wanted: []const u8) !void {
    try same(try render(try replicate(source)), wanted);
}

/// The result's column `index` has this type OID.
fn columnType(source: []const u8, index: usize, oid: u32) !void {
    const result = try replicate(source);
    try check(index < result.column_count);
    const got = sql.typeOid(result.column_types[index]);
    if (got != oid) std.debug.print("{s}: column {d} type {d} (wanted {d})\n", .{ source, index, got, oid });
    try check(got == oid);
}

/// The statement completes with this command tag and affected count.
fn completes(source: []const u8, tag: sql.CommandTag, affected: usize) !void {
    const result = try replicate(source);
    if (result.command != tag or result.affected_rows != affected) std.debug.print("{s}: {s} {d}\n", .{ source, @tagName(result.command), result.affected_rows });
    try check(result.command == tag and result.affected_rows == affected);
}

/// The autocommit statement fails with `wanted`; the probe answers
/// `unchanged` afterwards (atomicity) on primary and replica.
fn rejects(source: []const u8, wanted: anyerror, probe: []const u8, unchanged: []const u8) !void {
    const result = &other_slot;
    result.* = .{};
    var used: usize = 0;
    if (db.executeChanges(source, result, &record, &used, null, null)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(used == 0);
    try same(try query(&db, probe), unchanged);
    try same(try query(&replica, probe), unchanged);
    try idle();
}

fn fails(source: []const u8, wanted: anyerror) !void {
    try rejects(source, wanted, "SELECT 1", "1");
}

fn statement(slot: u16, source: []const u8) !void {
    const result = &other_slot;
    result.* = .{};
    db.statement(slot, source, result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rows(slot: u16, source: []const u8) ![]const u8 {
    const result = &other_slot;
    result.* = .{};
    db.statement(slot, source, result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(result);
}

fn statementFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    const result = &other_slot;
    result.* = .{};
    if (db.statement(slot, source, result, .{})) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

/// Encodes, replays and publishes a transaction (Store.commit order).
fn commit(slot: u16) !void {
    if (!db.readOnly(slot)) {
        const payload = db.prepareCommit(slot, &record) catch |err| {
            std.debug.print("commit of slot {d} after assertion {d}: {s}\n", .{ slot, assertions, @errorName(err) });
            return err;
        };
        try replica.applyChangeRecord(payload, &scratch);
        records_applied += 1;
    }
    db.publishCommit(slot);
}

var copy_buffer: [16384]u8 = undefined;

/// Every probe answers identically on the primary and the replay.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const left = try query(&db, probe);
        @memcpy(copy_buffer[0..left.len], left);
        const right = try query(&replica, probe);
        if (!std.mem.eql(u8, copy_buffer[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy_buffer[0..left.len], right });
        try check(std.mem.eql(u8, copy_buffer[0..left.len], right));
    }
    try check(db.tableCount() == replica.tableCount());
    try check(db.oid_counter == replica.oid_counter);
}

fn reset() void {
    db = .{};
    replica = .{};
}

fn idle() !void {
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0);
}

// ---- T651 / T653: SQL-schema statements in routines ------------------------------

/// DDL in SQL and PL/pgSQL functions called from expressions (nested
/// statements) and in procedures; void functions in expressions (NULL from
/// SQL, an empty value from PL/pgSQL); DDL on a table the calling statement
/// uses is 55006, atomically; SQL bodies are analyzed past utility
/// statements (42P01 for a table an earlier statement would create).
fn schemaStatements() !void {
    reset();
    try run("CREATE FUNCTION mk() RETURNS VOID LANGUAGE SQL AS $$CREATE TABLE made(a INT)$$");
    try returns("SELECT mk()", "NULL");
    try run("INSERT INTO made VALUES (1)");
    try expect("SELECT a FROM made", "1");
    try run("CREATE PROCEDURE drop_it() LANGUAGE SQL AS $$DROP TABLE made$$");
    try completes("CALL drop_it()", .call, 0);
    try expect("SELECT count(*) FROM information_schema.tables WHERE table_name = 'made'", "0");
    // void: NULL from SQL, an empty non-NULL value from PL/pgSQL, also in FROM.
    try run("CREATE FUNCTION pv() RETURNS VOID LANGUAGE plpgsql AS $$BEGIN END$$");
    try run("CREATE FUNCTION sv() RETURNS VOID LANGUAGE SQL AS $$SELECT 1$$");
    try returns("SELECT pv(), pv() IS NULL, sv() IS NULL, pg_typeof(pv())", "|f|t|void");
    try columnType("SELECT sv()", 0, 2278);
    try returns("SELECT p IS NULL, p::text = '' FROM pv() AS p", "f|t");
    // Analysis continues past a utility statement (PostgreSQL 18).
    try fails("CREATE FUNCTION bad() RETURNS VOID LANGUAGE SQL AS $$CREATE TABLE x(a INT); INSERT INTO x VALUES (1)$$", error.TableNotFound);
    try fails("CREATE FUNCTION bad() RETURNS INT LANGUAGE SQL AS $$CREATE TABLE x(a INT); SELECT 'abc'$$", error.InvalidFunctionDefinition);
    try run("CREATE FUNCTION later() RETURNS VOID LANGUAGE SQL AS $$DROP TABLE nosuch$$");
    // DDL on a table the calling statement uses: 55006, nothing changes.
    try run("CREATE TABLE u(a INT)");
    try run("INSERT INTO u VALUES (1), (2)");
    try run("CREATE FUNCTION dropu() RETURNS INT LANGUAGE SQL AS $$DROP TABLE u; SELECT 1$$");
    try rejects("SELECT dropu() FROM u", error.ObjectInUse, "SELECT count(*) FROM u", "2");
    try run("CREATE FUNCTION altu() RETURNS INT LANGUAGE plpgsql AS $$BEGIN ALTER TABLE u ADD COLUMN b INT; RETURN 1; END$$");
    try rejects("SELECT altu() FROM u", error.ObjectInUse, "SELECT count(*) FROM u", "2");
    try run("CREATE FUNCTION truncu() RETURNS INT LANGUAGE plpgsql AS $$BEGIN TRUNCATE u; RETURN 1; END$$");
    try rejects("SELECT truncu() FROM u", error.ObjectInUse, "SELECT count(*) FROM u", "2");
    try run("CREATE FUNCTION idxu() RETURNS INT LANGUAGE plpgsql AS $$BEGIN CREATE INDEX ON u(a); RETURN 1; END$$");
    try rejects("SELECT idxu() FROM u", error.ObjectInUse, "SELECT count(*) FROM u", "2");
    try run("CREATE TABLE log(n INT)");
    try run("CREATE FUNCTION ins_drop() RETURNS INT LANGUAGE plpgsql AS $$BEGIN DROP TABLE log; RETURN 1; END$$");
    try rejects("INSERT INTO log SELECT ins_drop()", error.ObjectInUse, "SELECT count(*) FROM log", "0");
    // Without a use, the same function changes the schema; atomic on error.
    try returns("SELECT altu()", "1");
    try expect("SELECT a, b FROM u ORDER BY a", "1|NULL;2|NULL");
    try run("CREATE FUNCTION mk_then_fail() RETURNS INT LANGUAGE plpgsql AS $$BEGIN CREATE TABLE gone(a INT); RETURN 1 / 0; END$$");
    try rejects("SELECT mk_then_fail()", error.DivisionByZero, "SELECT count(*) FROM information_schema.tables WHERE table_name = 'gone'", "0");
    // Routine DDL inside a running statement.
    try run("CREATE FUNCTION mkf() RETURNS INT LANGUAGE plpgsql AS $$BEGIN CREATE FUNCTION inner1() RETURNS INT LANGUAGE SQL AS 'SELECT 7'; RETURN inner1(); END$$");
    try returns("SELECT mkf()", "7");
    try returns("SELECT inner1()", "7");
    // A non-volatile function runs no DDL (0A000).
    try run("CREATE FUNCTION smk() RETURNS INT STABLE LANGUAGE plpgsql AS $$BEGIN CREATE TABLE s(a INT); RETURN 1; END$$");
    try fails("SELECT smk()", error.UnsupportedStatement);
    try sameState(&.{ "SELECT a, b FROM u ORDER BY a", "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'", "SELECT inner1()" });
    try idle();
}

/// PL/pgSQL EXECUTE: the string runs as statements of the routine (also
/// DDL, inside a running statement), INTO [STRICT] takes the last
/// statement's first row, USING values are $1..$n and the routine's
/// variables are not visible; ROW_COUNT changes, FOUND does not.
fn dynamicStatements() !void {
    reset();
    try run("CREATE FUNCTION mk(n TEXT) RETURNS VOID LANGUAGE plpgsql AS $$BEGIN EXECUTE 'CREATE TABLE ' || quote_ident(n) || '(a INT)'; CREATE TABLE fixed(b INT); END$$");
    try returns("SELECT mk('dyn')", "");
    try expect("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY 1", "dyn;fixed");
    try run("INSERT INTO dyn VALUES (1)");
    try run("CREATE FUNCTION cnt(n TEXT) RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT count(*) FROM ' || quote_ident(n) INTO r; RETURN r; END$$");
    try returns("SELECT cnt('dyn'), cnt('fixed')", "1|0");
    try run("CREATE FUNCTION addp(v INT) RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT $1 + $2' INTO STRICT r USING v, 10; RETURN r; END$$");
    try returns("SELECT addp(5)", "15");
    try run("CREATE FUNCTION rc() RETURNS BIGINT LANGUAGE plpgsql AS $$DECLARE r BIGINT; BEGIN EXECUTE 'INSERT INTO dyn VALUES (5), (6)'; GET DIAGNOSTICS r = ROW_COUNT; RETURN r * 10 + (CASE WHEN FOUND THEN 1 ELSE 0 END); END$$");
    try returns("SELECT rc()", "20");
    try run("CREATE FUNCTION nullexec() RETURNS INT LANGUAGE plpgsql AS $$BEGIN EXECUTE NULL; RETURN 1; END$$");
    try fails("SELECT nullexec()", error.NullValueNotAllowed);
    try run("CREATE FUNCTION intonone() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'CREATE TABLE z(a INT)' INTO r; RETURN r; END$$");
    try rejects("SELECT intonone()", error.Syntax, "SELECT count(*) FROM information_schema.tables WHERE table_name = 'z'", "0");
    try run("CREATE FUNCTION strict0() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT a FROM dyn WHERE a > 100' INTO STRICT r; RETURN r; END$$");
    try fails("SELECT strict0()", error.NoDataFound);
    try run("CREATE FUNCTION strict2() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT a FROM dyn' INTO STRICT r; RETURN r; END$$");
    try fails("SELECT strict2()", error.TooManyRows);
    try run("CREATE FUNCTION novars() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT := 3; BEGIN EXECUTE 'SELECT r' INTO r; RETURN r; END$$");
    try fails("SELECT novars()", error.ColumnNotFound);
    try run("CREATE FUNCTION noparam() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT $2' INTO r USING 1; RETURN r; END$$");
    try fails("SELECT noparam()", error.UndefinedParameter);
    try run("CREATE FUNCTION several() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT 1; SELECT 2' INTO r; RETURN r; END$$");
    try returns("SELECT several()", "2");
    try run("CREATE FUNCTION trailing() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT 42;' USING 1 INTO r; RETURN r; END$$");
    try returns("SELECT trailing()", "42");
    try run("CREATE FUNCTION pair() RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE a INT; b TEXT; BEGIN EXECUTE 'SELECT 1, ''x''' INTO a, b; RETURN a || b; END$$");
    try returns("SELECT pair()", "1x");
    try run("CREATE FUNCTION utype() RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE r TEXT; BEGIN EXECUTE 'SELECT pg_typeof($1)::text' INTO r USING 'abc'; RETURN r; END$$");
    try returns("SELECT utype()", "text");
    try run("CREATE FUNCTION badint() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN EXECUTE 'SELECT $1' INTO r USING 'abc'; RETURN 1; END$$");
    try fails("SELECT badint()", error.InvalidTextRepresentation);
    try run("CREATE FUNCTION rq() RETURNS SETOF INT LANGUAGE plpgsql AS $$BEGIN RETURN QUERY EXECUTE 'SELECT a FROM dyn WHERE a > $1 ORDER BY a' USING 1; END$$");
    try returns("SELECT * FROM rq()", "5;6");
    try run("DO $$BEGIN EXECUTE 'CREATE TABLE fromdo(a INT)'; END$$");
    try expect("SELECT count(*) FROM fromdo", "0");
    try fails("CREATE FUNCTION nointo() RETURNS INT LANGUAGE plpgsql AS $$BEGIN EXECUTE 'SELECT 1' INTO; RETURN 1; END$$", error.Syntax);
    try sameState(&.{ "SELECT a FROM dyn ORDER BY a", "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY 1" });
    try idle();
}

/// PL/pgSQL assignment converts through the text forms when no assignment
/// cast exists (PostgreSQL's exec_cast_value I/O coercion).
fn assignmentConversion() !void {
    reset();
    try run("CREATE FUNCTION c1() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN SELECT '12'::text INTO r; RETURN r; END$$");
    try returns("SELECT c1()", "12");
    try run("CREATE FUNCTION c2() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN SELECT 'abc'::text INTO r; RETURN r; END$$");
    try fails("SELECT c2()", error.InvalidTextRepresentation);
    try run("CREATE FUNCTION c3() RETURNS BOOLEAN LANGUAGE plpgsql AS $$DECLARE r BOOLEAN; BEGIN SELECT 1 INTO r; RETURN r; END$$");
    try returns("SELECT c3()", "t");
    try run("CREATE FUNCTION c4() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN r := '7'::text; RETURN r; END$$");
    try returns("SELECT c4()", "7");
    try run("CREATE FUNCTION c5() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT; BEGIN r := true; RETURN r; END$$");
    try fails("SELECT c5()", error.InvalidTextRepresentation);
    try run("CREATE FUNCTION c6() RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE r TEXT; BEGIN SELECT 1.50 INTO r; RETURN r; END$$");
    try returns("SELECT c6()", "1.50");
    try run("CREATE FUNCTION c7() RETURNS DATE LANGUAGE plpgsql AS $$DECLARE r DATE; BEGIN SELECT 5 INTO r; RETURN r; END$$");
    try fails("SELECT c7()", error.InvalidDatetimeFormat);
    try run("CREATE FUNCTION c8() RETURNS INT LANGUAGE plpgsql AS $$DECLARE r INT := '41'::text; BEGIN RETURN r + 1; END$$");
    try returns("SELECT c8()", "42");
    try idle();
}

pub fn main() !void {
    try schemaStatements();
    try dynamicStatements();
    try assignmentConversion();
    std.debug.print("routines-trig: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
