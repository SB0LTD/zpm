//! Routine signature and execution contracts (conformance lane B11, wave 4,
//! routines-sig lane, docs/SQL_ROUTINES.md): exception diagnostics
//! (SQLSTATE, SQLERRM, GET STACKED DIAGNOSTICS, ASSERT), schema-qualified
//! routines and search_path resolution, parameter modes (OUT, INOUT,
//! VARIADIC), DEFAULT values and named arguments, set-returning routines,
//! SECURITY DEFINER and SET clauses, and transaction control in procedures.
//! Each section checks values (PostgreSQL text output), column names and
//! type OIDs, exact errors (SQLSTATE through the error name), atomicity
//! after a failure and replay: every committed record is applied to a
//! replica that must answer every probe exactly like the primary. Every
//! expectation was checked against native PostgreSQL 18.7.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 6, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 2, .expr_nodes = 1024, .routines = 24, .triggers = 2, .rules = 1, .routine_args = 6, .routine_bytes = 768, .schemas = 4, .work_rows = 512 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("routines-sig contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.RoutinesSigContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
var query_values: [DB.Result.value_bytes]u8 = undefined;
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
    var result: DB.Result = .{};
    result.bindValueMemory(&query_values);
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(&result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// Column names (`a,b`) and type OIDs of a query, then its rows.
fn expectColumns(source: []const u8, names: []const u8, oids: []const u32, wanted: []const u8) !void {
    var result: DB.Result = .{};
    result.bindValueMemory(&query_values);
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    var joined: [256]u8 = undefined;
    var at: usize = 0;
    for (0..result.column_count) |column| {
        if (column != 0) {
            joined[at] = ',';
            at += 1;
        }
        const name = result.column_names[column].slice();
        @memcpy(joined[at..][0..name.len], name);
        at += name.len;
    }
    try same(joined[0..at], names);
    try check(result.column_count == oids.len);
    for (oids, 0..) |oid, column| {
        if (sql.typeOid(result.column_types[column]) != oid) std.debug.print("{s}: column {d} type {d}\n", .{ source, column, sql.typeOid(result.column_types[column]) });
        try check(sql.typeOid(result.column_types[column]) == oid);
    }
    try same(try render(&result), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    result.bindValueMemory(&query_values);
    var used: usize = 0;
    db.executeChanges(source, &result, &record, &used, null, null) catch |err| {
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

/// A replicated statement and its rendered result rows.
fn runRows(source: []const u8, wanted: []const u8) !void {
    const result = try replicate(source);
    try same(try render(&result), wanted);
}

/// The autocommit statement fails with `wanted`; the probe answers
/// `unchanged` afterwards (atomicity) on primary and replica.
fn rejects(source: []const u8, wanted: anyerror, probe: []const u8, unchanged: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    if (db.executeChanges(source, &result, &record, &used, null, null)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(used == 0);
    try same(try query(&db, probe), unchanged);
    try same(try query(&replica, probe), unchanged);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0);
}

fn fails(source: []const u8, wanted: anyerror) !void {
    try rejects(source, wanted, "SELECT 1", "1");
}

fn statement(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rows(slot: u16, source: []const u8) ![]const u8 {
    var result: DB.Result = .{};
    result.bindValueMemory(&query_values);
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(&result);
}

fn statementFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{})) |_| {
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

/// Every probe answers identically on the primary and the replay.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const left = try query(&db, probe);
        var copy: [16384]u8 = undefined;
        @memcpy(copy[0..left.len], left);
        const right = try query(&replica, probe);
        if (!std.mem.eql(u8, copy[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy[0..left.len], right });
        try check(std.mem.eql(u8, copy[0..left.len], right));
    }
    try check(db.oid_counter == replica.oid_counter);
}

// ---- exception diagnostics ---------------------------------------------

fn diagnostics() !void {
    try run("CREATE TABLE log7 (id INT, v TEXT)");
    try run(
        \\CREATE FUNCTION diag(x INT) RETURNS TEXT LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  PERFORM 1 / x;
        \\  RETURN 'ok';
        \\EXCEPTION WHEN OTHERS THEN
        \\  RETURN sqlstate || '|' || sqlerrm;
        \\END$$
    );
    try expect("SELECT diag(0), diag(1)", "22012|division by zero|ok");
    try run(
        \\CREATE FUNCTION stacked() RETURNS TEXT LANGUAGE plpgsql AS $$
        \\DECLARE s TEXT; m TEXT; d TEXT; h TEXT; c TEXT; t TEXT;
        \\BEGIN
        \\  RAISE EXCEPTION 'bad %, %%', 42 USING DETAIL = 'dd', HINT = 'hh', COLUMN = 'cc', TABLE = 'tt';
        \\EXCEPTION WHEN raise_exception THEN
        \\  GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT, c = COLUMN_NAME, t = TABLE_NAME;
        \\  RETURN s || '|' || m || '|' || d || '|' || h || '|' || c || '|' || t;
        \\END$$
    );
    try expect("SELECT stacked()", "P0001|bad 42, %|dd|hh|cc|tt");
    try run(
        \\CREATE FUNCTION codes(k INT) RETURNS TEXT LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  IF k = 1 THEN RAISE division_by_zero; END IF;
        \\  IF k = 2 THEN RAISE SQLSTATE '22003'; END IF;
        \\  IF k = 3 THEN RAISE EXCEPTION USING ERRCODE = 'unique_violation', MESSAGE = 'dup'; END IF;
        \\  IF k = 4 THEN RAISE EXCEPTION 'plain'; END IF;
        \\  IF k = 5 THEN RAISE EXCEPTION USING ERRCODE = '22012'; END IF;
        \\  IF k = 6 THEN ASSERT k = 0, 'k is ' || k; END IF;
        \\  IF k = 7 THEN ASSERT false; END IF;
        \\  RETURN 'none';
        \\EXCEPTION
        \\  WHEN data_exception THEN RETURN 'class 22: ' || sqlstate || '|' || sqlerrm;
        \\  WHEN assert_failure THEN RETURN 'assert: ' || sqlstate || '|' || sqlerrm;
        \\  WHEN OTHERS THEN RETURN 'others: ' || sqlstate || '|' || sqlerrm;
        \\END$$
    );
    try expect("SELECT k, codes(k) FROM generate_series(1, 8) k",
        "1|class 22: 22012|division_by_zero;2|class 22: 22003|22003;3|others: 23505|dup;4|others: P0001|plain;" ++
        "5|class 22: 22012|22012;6|assert: P0004|k is 6;7|assert: P0004|assertion failed;8|none");
    // OTHERS does not catch ASSERT_FAILURE (P0004 reaches the client).
    try run("CREATE FUNCTION others_assert() RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN ASSERT 1 = 2; RETURN 'no'; EXCEPTION WHEN OTHERS THEN RETURN 'caught'; END$$");
    try fails("SELECT others_assert()", error.AssertFailure);
    try fails("DO $$BEGIN ASSERT NULL; END$$", error.AssertFailure);
    try run(
        \\CREATE FUNCTION nested_diag() RETURNS TEXT LANGUAGE plpgsql AS $$
        \\DECLARE r TEXT := '';
        \\BEGIN
        \\  BEGIN
        \\    PERFORM 1 / 0;
        \\  EXCEPTION WHEN OTHERS THEN
        \\    BEGIN
        \\      RAISE EXCEPTION 'inner';
        \\    EXCEPTION WHEN OTHERS THEN
        \\      r := r || sqlstate || ':' || sqlerrm || ';';
        \\    END;
        \\    r := r || sqlstate || ':' || sqlerrm;
        \\  END;
        \\  RETURN r;
        \\END$$
    );
    try expect("SELECT nested_diag()", "P0001:inner;22012:division by zero");
    try run(
        \\CREATE FUNCTION reraise() RETURNS TEXT LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  BEGIN
        \\    RAISE EXCEPTION 'first' USING HINT = 'h1';
        \\  EXCEPTION WHEN OTHERS THEN
        \\    RAISE;
        \\  END;
        \\EXCEPTION WHEN OTHERS THEN
        \\  DECLARE h TEXT; BEGIN GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT; RETURN sqlerrm || '|' || h; END;
        \\END$$
    );
    try expect("SELECT reraise()", "first|h1");
    try run("CREATE FUNCTION outside() RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE s TEXT; BEGIN GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE; RETURN s; END$$");
    try fails("SELECT outside()", error.StackedDiagnosticsAccessedWithoutActiveHandler);
    try run("CREATE FUNCTION nullmsg() RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION USING MESSAGE = NULL; END$$");
    try fails("SELECT nullmsg()", error.NullValueNotAllowed);
    // Definition errors (PostgreSQL compiles the body at CREATE).
    try fails("CREATE FUNCTION usemsg() RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'x' USING MESSAGE = 'y'; END$$", error.Syntax);
    try fails("CREATE FUNCTION unk() RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION USING ERRCODE = 'no_such_condition'; END$$", error.UndefinedObject);
    try fails("CREATE FUNCTION many() RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'a %%', 1; END$$", error.Syntax);
    // SQLSTATE / SQLERRM exist only inside a handler (42703).
    try fails("DO $$DECLARE x TEXT; BEGIN x := sqlstate; END$$", error.ColumnNotFound);
    // A procedure's handler sees the statement error and its writes roll back.
    try run(
        \\CREATE PROCEDURE logged(k INT) LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  INSERT INTO log7 VALUES (k, 'before');
        \\  BEGIN
        \\    INSERT INTO log7 VALUES (k, 'inside');
        \\    PERFORM k / 0;
        \\  EXCEPTION WHEN division_by_zero THEN
        \\    INSERT INTO log7 VALUES (k, sqlstate || ' ' || sqlerrm);
        \\  END;
        \\END$$
    );
    try run("CALL logged(5)");
    try expect("SELECT id, v FROM log7 ORDER BY v", "5|22012 division by zero;5|before");
    try sameState(&.{ "SELECT id, v FROM log7 ORDER BY v", "SELECT diag(0), codes(3)" });
}

// ---- schema-qualified routines -----------------------------------------

fn schemas() !void {
    try run("CREATE SCHEMA s1");
    try run("CREATE SCHEMA s2");
    try run("CREATE TABLE s1.t (id INT)");
    try run("INSERT INTO s1.t VALUES (1)");
    try run("CREATE FUNCTION s1.f(a INT) RETURNS INT LANGUAGE sql AS 'SELECT a + 1'");
    try run("CREATE FUNCTION s2.f(a INT) RETURNS INT LANGUAGE sql AS 'SELECT a + 2'");
    try run("CREATE FUNCTION s2.f(a TEXT) RETURNS TEXT LANGUAGE sql AS $$SELECT a || '!'$$");
    try expect("SELECT s1.f(1), s2.f(1), s2.f('x')", "2|3|x!");
    // Neither schema is on the search path; a missing schema is 3F000.
    try fails("SELECT f(1)", error.UndefinedFunction);
    try fails("SELECT s9.f(1)", error.UndefinedSchema);
    try fails("CREATE FUNCTION s3.f(a INT) RETURNS INT LANGUAGE sql AS 'SELECT 1'", error.UndefinedSchema);
    try fails("CREATE FUNCTION s1.f(a INT) RETURNS INT LANGUAGE sql AS 'SELECT 0'", error.DuplicateFunction);
    try run("CREATE OR REPLACE FUNCTION s1.f(a INT) RETURNS INT LANGUAGE sql AS 'SELECT a + 10'");
    try expect("SELECT s1.f(1)", "11");
    try run("CREATE PROCEDURE s2.p(x INT) LANGUAGE plpgsql AS $$BEGIN INSERT INTO s1.t VALUES (x); END$$");
    try run("CALL s2.p(5)");
    try fails("CALL p(1)", error.UndefinedFunction);
    try fails("CALL s9.p(1)", error.UndefinedSchema);
    try expect("SELECT id FROM s1.t ORDER BY id", "1;5");
    try expect("SELECT (SELECT nspname FROM pg_namespace n WHERE n.oid = p.pronamespace), prokind FROM pg_proc p WHERE proname = 'f' ORDER BY 1, oid", "s1|f;s2|f;s2|f");
    try expect("SELECT (SELECT nspname FROM pg_namespace n WHERE n.oid = p.pronamespace), prokind FROM pg_proc p WHERE proname = 'p'", "s2|p");
    try sameState(&.{ "SELECT s1.f(1), s2.f(1), s2.f('x')", "SELECT id FROM s1.t ORDER BY id" });
    // DROP with signatures, IF EXISTS and an ambiguous name.
    try run("DROP FUNCTION s1.f(int)");
    try fails("DROP FUNCTION s1.f(int)", error.UndefinedFunction);
    try run("DROP FUNCTION IF EXISTS s1.f(int)");
    try run("DROP FUNCTION IF EXISTS s9.f(int)");
    try fails("DROP FUNCTION s9.f(int)", error.UndefinedSchema);
    try fails("DROP FUNCTION s2.f", error.AmbiguousFunction);
    try run("DROP FUNCTION s2.f(text)");
    try run("DROP FUNCTION s2.f");
    try fails("SELECT s2.f(1)", error.UndefinedFunction);
    // DROP SCHEMA: RESTRICT keeps routines (2BP01), CASCADE drops them first.
    try rejects("DROP SCHEMA s2", error.DependentObjects, "SELECT count(*) FROM pg_proc WHERE proname = 'p'", "1");
    try run("DROP SCHEMA s2 CASCADE");
    try expect("SELECT count(*) FROM pg_proc WHERE proname = 'f' OR proname = 'p'", "0");
    try sameState(&.{"SELECT count(*) FROM pg_proc WHERE proname = 'f' OR proname = 'p'"});
    // "$user" precedes public in the default search_path.
    try run("CREATE FUNCTION k() RETURNS TEXT LANGUAGE sql AS $$SELECT 'public'$$");
    try run("CREATE SCHEMA ramsql");
    try expect("SELECT k()", "public");
    try run("CREATE FUNCTION ramsql.k() RETURNS TEXT LANGUAGE sql AS $$SELECT 'user'$$");
    try expect("SELECT k(), public.k(), ramsql.k()", "user|public|user");
    try run("CREATE FUNCTION k2(a INT) RETURNS TEXT LANGUAGE sql AS $$SELECT 'k2'$$");
    try expect("SELECT (SELECT nspname FROM pg_namespace n WHERE n.oid = p.pronamespace) FROM pg_proc p WHERE proname = 'k2'", "ramsql");
    try run("DROP FUNCTION k");
    try expect("SELECT k()", "public");
    try run("DROP FUNCTION k");
    try fails("SELECT k()", error.UndefinedFunction);
    try run("DROP SCHEMA ramsql CASCADE");
    try expect("SELECT count(*) FROM pg_proc WHERE proname = 'k' OR proname = 'k2'", "0");
    // A trigger function in a schema; DROP SCHEMA CASCADE drops the trigger.
    try run("CREATE SCHEMA s1b");
    try run("CREATE TABLE tt (a INT)");
    try run("CREATE FUNCTION s1b.tf() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN NEW.a := NEW.a * 2; RETURN NEW; END$$");
    try run("CREATE TRIGGER tg BEFORE INSERT ON tt FOR EACH ROW EXECUTE FUNCTION s1b.tf()");
    try run("INSERT INTO tt VALUES (4)");
    try expect("SELECT a FROM tt", "8");
    try rejects("DROP SCHEMA s1b", error.DependentObjects, "SELECT count(*) FROM pg_trigger", "1");
    try run("DROP SCHEMA s1b CASCADE");
    try run("INSERT INTO tt VALUES (4)");
    try expect("SELECT a FROM tt ORDER BY a", "4;8");
    try sameState(&.{ "SELECT a FROM tt ORDER BY a", "SELECT count(*) FROM pg_trigger", "SELECT count(*) FROM pg_proc WHERE proname = 'tf'" });
    try run("DROP TABLE tt");
    try run("DROP TABLE s1.t");
    try run("DROP SCHEMA s1");
}

pub fn main() !void {
    try diagnostics();
    try schemas();
    std.debug.print("routines-sig: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
