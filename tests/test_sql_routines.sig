//! Routine contracts (conformance lane B11, wave 3): SQL and PL/pgSQL
//! functions, procedures and CALL, DO blocks, triggers (BEFORE / AFTER, ROW
//! / STATEMENT, WHEN, UPDATE OF) and DO [ALSO | INSTEAD] NOTHING rules.
//! Each section checks values (PostgreSQL 18 text output), column names and
//! type OIDs, command tags, exact errors (SQLSTATE through the error name),
//! atomicity after a failure, concurrency where a lock or a pending catalog
//! object decides, work control, and replay: every committed record is
//! applied to a replica that must answer every probe exactly like the
//! primary (committed state = replay(WAL)). Only the four PG.ROUTINE.*
//! programs of postgres18_oracle.json are native-verified; every other
//! expectation is pending native verification (docs/SQL_ROUTINES.md).
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 8, .columns = 12, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 4, .expr_nodes = 1024, .routines = 16, .triggers = 8, .rules = 4 });
/// Two routine slots and a shallow routine depth.
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .routines = 2, .triggers = 1, .rules = 1, .routine_depth = 3, .routine_bytes = 256 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("routines contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.RoutinesContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
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
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(&result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// One column: its name, type OID and the rendered rows.
fn expectColumn(source: []const u8, name: []const u8, oid: u32, wanted: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try check(result.column_count == 1);
    try same(result.column_names[0].slice(), name);
    try check(sql.typeOid(result.column_types[0]) == oid and result.column_typmods[0] == -1);
    try same(try render(&result), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !DB.Result {
    var result: DB.Result = .{};
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

/// The statement completes with this command tag and affected count.
fn completes(source: []const u8, tag: sql.CommandTag, affected: usize) !void {
    const result = try replicate(source);
    if (result.command != tag or result.affected_rows != affected) std.debug.print("{s}: {s} {d}\n", .{ source, @tagName(result.command), result.affected_rows });
    try check(result.command == tag and result.affected_rows == affected);
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

fn parks(slot: u16, source: []const u8) !void {
    try statementFails(slot, source, error.WouldBlock);
    try check(db.parked(slot));
}

fn resumed(slot: u16, source: []const u8) ![]const u8 {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{ .@"resume" = true });
    return render(&result);
}

fn resumeFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{ .@"resume" = true })) |_| {
        std.debug.print("resumed: {s}\n", .{source});
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
    try check(db.tableCount() == replica.tableCount());
    try check(db.oid_counter == replica.oid_counter);
}

/// The same statement on the primary and the replica (not replicated)
/// gives the same result: replayed triggers and rules behave alike.
fn sameEffect(source: []const u8) !void {
    var left: DB.Result = .{};
    var right: DB.Result = .{};
    db.execute(source, &left) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    replica.execute(source, &right) catch |err| {
        std.debug.print("replica {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try check(left.command == right.command and left.affected_rows == right.affected_rows);
}

fn reset() void {
    db = .{};
    replica = .{};
}

const proc_probe = "SELECT oid, proname, prokind, prolang, provolatile, proisstrict, pronargs, prorettype, proargtypes FROM pg_proc ORDER BY oid";
const trigger_probe = "SELECT oid, tgrelid, tgname, tgfoid, tgtype, tgenabled, tgnargs FROM pg_trigger ORDER BY oid";
const rule_probe = "SELECT r.oid, r.rulename, r.ev_type, r.is_instead, p.definition FROM pg_rewrite r JOIN pg_rules p ON p.rulename = r.rulename ORDER BY r.oid";

// ---- the four oracle programs (PG.ROUTINE.*) --------------------------------

fn base() !void {
    reset();
    try run("CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)");
    try run("INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)");
    try run("CREATE TABLE tdd_b(id INT PRIMARY KEY,v INT)");
    try run("INSERT INTO tdd_b VALUES(1,11),(3,33),(5,55)");
}

fn oraclePrograms() !void {
    try base();
    try completes("CREATE FUNCTION tdd_fn(x INT) RETURNS INT LANGUAGE SQL IMMUTABLE AS 'SELECT x+1'", .create_function, 0);
    try expectColumn("SELECT tdd_fn(2)", "tdd_fn", 23, "3");
    try completes("CREATE PROCEDURE tdd_proc() LANGUAGE SQL AS 'SELECT 1'", .create_procedure, 0);
    try completes("CALL tdd_proc()", .call, 0);
    try completes("DO $$BEGIN NULL; END$$", .do_block, 0);
    try completes("CREATE FUNCTION tdd_trigger_fn() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN NEW.v:=42; RETURN NEW; END$$", .create_function, 0);
    try completes("CREATE TRIGGER tdd_trigger BEFORE INSERT ON tdd_a FOR EACH ROW EXECUTE FUNCTION tdd_trigger_fn()", .create_trigger, 0);
    try completes("INSERT INTO tdd_a VALUES(5,1,1)", .insert, 1);
    try expectColumn("SELECT v FROM tdd_a WHERE id=5", "v", 23, "42");
    try completes("CREATE RULE tdd_rule AS ON DELETE TO tdd_a DO INSTEAD NOTHING", .create_rule, 0);
    try completes("DELETE FROM tdd_a WHERE id=1", .delete, 0);
    try expectColumn("SELECT id FROM tdd_a ORDER BY id", "id", 23, "1;2;3;4;5");
    try expect(proc_probe, "16388|tdd_fn|f|sql|i|f|1|23|23;16389|tdd_proc|p|sql|v|f|0|2278|;16390|tdd_trigger_fn|f|plpgsql|v|f|0|2279|");
    try expect(trigger_probe, "16391|16384|tdd_trigger|16390|7|O|0");
    try expect("SELECT schemaname, tablename, rulename, definition FROM pg_rules", "public|tdd_a|tdd_rule|CREATE RULE tdd_rule AS\n    ON DELETE TO public.tdd_a DO INSTEAD NOTHING;");
    try sameState(&.{ proc_probe, trigger_probe, rule_probe, "SELECT id, g, v FROM tdd_a ORDER BY id", "SELECT tdd_fn(41)" });
    // The replica fires the replayed trigger and rule the same way.
    try sameEffect("INSERT INTO tdd_a VALUES(6,1,7)");
    try sameEffect("DELETE FROM tdd_a");
    try same(try query(&replica, "SELECT id, v FROM tdd_a WHERE id = 6"), "6|42");
}

// ---- SQL functions ----------------------------------------------------------

fn sqlFunctions() !void {
    try base();
    try run("CREATE FUNCTION add1(x INT) RETURNS INT LANGUAGE SQL IMMUTABLE AS 'SELECT x+1'");
    try expectColumn("SELECT add1(v) FROM tdd_a ORDER BY id", "add1", 23, "11;21;31;NULL");
    try expect("SELECT id, add1(add1(id)) FROM tdd_a WHERE add1(g) = 2 ORDER BY id", "1|3;2|4");
    try run("CREATE FUNCTION twice(INT) RETURNS INT LANGUAGE SQL AS 'SELECT $1 * 2'");
    try expectColumn("SELECT twice(21)", "twice", 23, "42");
    try run("CREATE FUNCTION qualified(n INT) RETURNS BIGINT LANGUAGE SQL AS $$SELECT qualified.n + 100$$");
    try expectColumn("SELECT qualified(1)", "qualified", 20, "101");
    // STRICT: a NULL argument is NULL without running the body.
    try run("CREATE FUNCTION seven(x INT) RETURNS INT LANGUAGE SQL STRICT AS 'SELECT 7'");
    try expect("SELECT seven(NULL), seven(1)", "NULL|7");
    try run("CREATE FUNCTION lazy(x INT) RETURNS INT LANGUAGE SQL CALLED ON NULL INPUT AS 'SELECT 7'");
    try expect("SELECT lazy(NULL)", "7");
    // Overloads by argument type; an untyped literal prefers text.
    try run("CREATE FUNCTION over(x INT) RETURNS TEXT LANGUAGE SQL AS 'SELECT ''int'''");
    try run("CREATE FUNCTION over(x TEXT) RETURNS TEXT LANGUAGE SQL AS 'SELECT ''text'''");
    try expect("SELECT over(1), over('a'::text), over('a')", "int|text|text");
    try rejects("SELECT over(1.5)", error.UndefinedFunction, "SELECT add1(1)", "2");
    try fails("SELECT nosuch(1)", error.UndefinedFunction);
    try fails("SELECT add1(1, 2)", error.UndefinedFunction);
    // Assignment-coercible results; the declared type wins.
    try run("CREATE FUNCTION wide() RETURNS NUMERIC LANGUAGE SQL AS 'SELECT 2'");
    try expectColumn("SELECT wide()", "wide", 1700, "2");
    // Definitions are validated at CREATE (check_function_bodies).
    try fails("CREATE FUNCTION add1(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT 1'", error.DuplicateFunction);
    try fails("CREATE FUNCTION bad1() RETURNS INT LANGUAGE SQL AS 'SELECT ''a''::text'", error.InvalidFunctionDefinition);
    try fails("CREATE FUNCTION bad2() RETURNS INT LANGUAGE SQL AS 'SELECT 1, 2'", error.InvalidFunctionDefinition);
    try fails("CREATE FUNCTION bad3() RETURNS INT LANGUAGE SQL AS 'SELECT nosuch FROM tdd_a'", error.ColumnNotFound);
    try fails("CREATE FUNCTION bad4() RETURNS INT LANGUAGE SQL AS 'SELECT 1 +'", error.Syntax);
    try fails("CREATE FUNCTION bad5() RETURNS INT AS 'SELECT 1'", error.InvalidFunctionDefinition);
    try fails("CREATE FUNCTION bad6() RETURNS INT LANGUAGE plperl AS 'return 1'", error.UndefinedObject);
    try fails("CREATE FUNCTION bad7() RETURNS trigger LANGUAGE SQL AS 'SELECT 1'", error.InvalidFunctionDefinition);
    try fails("CREATE FUNCTION bad8() RETURNS INT LANGUAGE SQL AS 'COMMIT'", error.UnsupportedStatement);
    try fails("CREATE FUNCTION bad9(OUT x INT) LANGUAGE SQL AS 'SELECT 1'", error.UnsupportedStatement);
    try fails("CREATE FUNCTION bad10(x INT DEFAULT 1) RETURNS INT LANGUAGE SQL AS 'SELECT x'", error.UnsupportedStatement);
    try fails("CREATE FUNCTION bad11() RETURNS SETOF INT LANGUAGE SQL AS 'SELECT 1'", error.UnsupportedStatement);
    try fails("CREATE FUNCTION bad12() RETURNS INT LANGUAGE SQL STRICT STRICT AS 'SELECT 1'", error.Syntax);
    // OR REPLACE keeps the OID; the result type and names cannot change.
    try expect("SELECT oid FROM pg_proc WHERE proname = 'add1'", "16388");
    try run("CREATE OR REPLACE FUNCTION add1(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x+2'");
    try expect("SELECT add1(2), oid, provolatile FROM pg_proc WHERE proname = 'add1'", "4|16388|v");
    try fails("CREATE OR REPLACE FUNCTION add1(x INT) RETURNS BIGINT LANGUAGE SQL AS 'SELECT 1'", error.InvalidFunctionDefinition);
    try fails("CREATE OR REPLACE FUNCTION add1(y INT) RETURNS INT LANGUAGE SQL AS 'SELECT y'", error.InvalidFunctionDefinition);
    try fails("CREATE OR REPLACE PROCEDURE add1(x INT) LANGUAGE SQL AS 'SELECT 1'", error.WrongObjectType);
    // Bodies other than one SELECT of an expression are 0A000 when called
    // from an expression (pending: general SQL function execution).
    try run("CREATE FUNCTION counted() RETURNS BIGINT LANGUAGE SQL AS 'SELECT count(*) FROM tdd_a'");
    try fails("SELECT counted()", error.UnsupportedStatement);
    // Procedures are CALLed; functions are not.
    try run("CREATE PROCEDURE noop() LANGUAGE SQL AS 'SELECT 1'");
    try fails("SELECT noop()", error.WrongObjectType);
    try fails("CALL add1(1)", error.WrongObjectType);
    try fails("CALL nosuch()", error.UndefinedFunction);
    // DROP by signature or unique name.
    try fails("DROP FUNCTION over", error.AmbiguousFunction);
    try fails("DROP PROCEDURE add1(INT)", error.WrongObjectType);
    try fails("DROP FUNCTION noop()", error.WrongObjectType);
    try fails("DROP FUNCTION nosuch(INT)", error.UndefinedFunction);
    try completes("DROP FUNCTION IF EXISTS nosuch(INT)", .drop_function, 0);
    try completes("DROP FUNCTION over(TEXT)", .drop_function, 0);
    try expect("SELECT over('1')", "int");
    try fails("SELECT over('a')", error.InvalidTextRepresentation);
    try completes("DROP FUNCTION twice", .drop_function, 0);
    try completes("DROP PROCEDURE noop", .drop_procedure, 0);
    try fails("SELECT twice(1)", error.UndefinedFunction);
    try sameState(&.{ proc_probe, "SELECT add1(id), qualified(id), seven(v), over(id) FROM tdd_a ORDER BY id" });
}

// ---- PL/pgSQL functions -------------------------------------------------------

fn plpgsqlFunctions() !void {
    try base();
    try run(
        \\CREATE FUNCTION fact(n INT) RETURNS BIGINT LANGUAGE plpgsql AS $$
        \\DECLARE r BIGINT := 1; i INT;
        \\BEGIN
        \\  IF n < 0 THEN RAISE EXCEPTION 'negative %', n; END IF;
        \\  FOR i IN 1..n LOOP r := r * i; END LOOP;
        \\  RETURN r;
        \\END $$
    );
    try expectColumn("SELECT fact(5)", "fact", 20, "120");
    try expect("SELECT fact(0), fact(1), fact(g) FROM tdd_a ORDER BY id", "1|1|1;1|1|1;1|1|2;1|1|2");
    try fails("SELECT fact(-1)", error.RaiseException);
    try fails("SELECT fact(NULL)", error.NullValueNotAllowed);
    try run(
        \\CREATE FUNCTION classify(x INT) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
        \\DECLARE s TEXT := '';
        \\BEGIN
        \\  CASE WHEN x IS NULL THEN RETURN 'null';
        \\       WHEN x < 0 THEN s := 'neg';
        \\       ELSE s := 'pos';
        \\  END CASE;
        \\  CASE x WHEN 1, 2 THEN s := s || '-small'; ELSE NULL; END CASE;
        \\  RETURN s;
        \\END $$
    );
    try expect("SELECT classify(1), classify(-5), classify(NULL), classify(9)", "pos-small|neg|null|pos");
    try run(
        \\CREATE FUNCTION loops(n INT) RETURNS INT LANGUAGE plpgsql AS $$
        \\DECLARE total INT := 0; i INT := 0;
        \\BEGIN
        \\  <<outer>> LOOP
        \\    i := i + 1;
        \\    EXIT outer WHEN i > n;
        \\    CONTINUE WHEN i % 2 = 0;
        \\    total := total + i;
        \\  END LOOP outer;
        \\  WHILE total > 10 LOOP total := total - 10; END LOOP;
        \\  FOR i IN REVERSE 10..1 BY 4 LOOP total := total * 10 + i; END LOOP;
        \\  RETURN total;
        \\END $$
    );
    // 1+3+5 = 9, then 10, 6 and 2 (REVERSE ... BY 4): 100, 1006, 10062.
    try expect("SELECT loops(5), loops(7)", "10062|7062");
    try run(
        \\CREATE FUNCTION safe_div(a INT, b INT) RETURNS INT LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  RETURN a / b;
        \\EXCEPTION WHEN division_by_zero THEN RETURN -1;
        \\END $$
    );
    try expect("SELECT safe_div(7, 2), safe_div(1, 0)", "3|-1");
    try run(
        \\CREATE FUNCTION nested(x INT) RETURNS TEXT LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  BEGIN
        \\    PERFORM 1 / x;
        \\    RETURN 'ok';
        \\  EXCEPTION WHEN SQLSTATE '22012' OR raise_exception THEN
        \\    BEGIN RAISE; EXCEPTION WHEN OTHERS THEN RETURN 'caught again'; END;
        \\  END;
        \\END $$
    );
    try expect("SELECT nested(1), nested(0)", "ok|caught again");
    try run("CREATE FUNCTION nr(x INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN IF x > 0 THEN RETURN x; END IF; END$$");
    try expect("SELECT nr(3)", "3");
    try fails("SELECT nr(-1)", error.FunctionExecutedNoReturn);
    try run("CREATE FUNCTION nn() RETURNS INT LANGUAGE plpgsql AS $$DECLARE k INT NOT NULL := 1; BEGIN k := NULL; RETURN k; END$$");
    try fails("SELECT nn()", error.NullValueNotAllowed);
    try run("CREATE FUNCTION unknown_name() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN zz; END$$");
    try fails("SELECT unknown_name()", error.ColumnNotFound);
    try run("CREATE FUNCTION case_gap(x INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN CASE x WHEN 1 THEN RETURN 1; END CASE; RETURN 0; END$$");
    try fails("SELECT case_gap(2)", error.CaseNotFound);
    try run("CREATE FUNCTION asserted(x INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN ASSERT x > 0, 'positive'; RETURN x; END$$");
    try fails("SELECT asserted(0)", error.RaiseException);
    try run("CREATE FUNCTION raises(x INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN IF x = 1 THEN RAISE division_by_zero; END IF; RAISE NOTICE 'x is %', x; RAISE EXCEPTION USING ERRCODE = 'unique_violation'; END$$");
    try fails("SELECT raises(1)", error.DivisionByZero);
    try fails("SELECT raises(2)", error.PrimaryKeyViolation);
    // Recursion is bounded by Config.routine_depth (54001).
    try run("CREATE FUNCTION depth(n INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN IF n <= 0 THEN RETURN 0; END IF; RETURN depth(n - 1) + 1; END$$");
    try expect("SELECT depth(10)", "10");
    try fails("SELECT depth(100)", error.StackDepthExceeded);
    // Statements are not run inside an expression (0A000), atomically.
    try run("CREATE FUNCTION writes() RETURNS INT LANGUAGE plpgsql AS $$BEGIN INSERT INTO tdd_b VALUES (9, 9); RETURN 1; END$$");
    try rejects("SELECT writes()", error.UnsupportedStatement, "SELECT count(*) FROM tdd_b", "3");
    // Compile errors at CREATE (42601, 22005, 22004, 42704).
    try fails("CREATE FUNCTION e1() RETURNS INT LANGUAGE plpgsql AS $$BEGIN x := ; RETURN 1; END$$", error.Syntax);
    try fails("CREATE FUNCTION e2() RETURNS INT LANGUAGE plpgsql AS $$BEGIN y := 1; RETURN 1; END$$", error.Syntax);
    try fails("CREATE FUNCTION e3() RETURNS INT LANGUAGE plpgsql AS $$DECLARE k CONSTANT INT := 1; BEGIN k := 2; RETURN k; END$$", error.ErrorInAssignment);
    try fails("CREATE FUNCTION e4() RETURNS INT LANGUAGE plpgsql AS $$DECLARE k INT NOT NULL; BEGIN RETURN 1; END$$", error.NullValueNotAllowed);
    try fails("CREATE FUNCTION e5() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN 1; EXCEPTION WHEN no_such_condition THEN RETURN 2; END$$", error.UndefinedObject);
    try fails("CREATE FUNCTION e6() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RAISE NOTICE 'a % b %', 1; RETURN 1; END$$", error.Syntax);
    try fails("CREATE FUNCTION e7() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN 1; END IF; END$$", error.Syntax);
    try fails("CREATE FUNCTION e8() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN; END$$", error.Syntax);
    try fails("CREATE FUNCTION e9(x INT) RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$", error.InvalidFunctionDefinition);
    try fails("CREATE FUNCTION e10() RETURNS VOID LANGUAGE plpgsql AS $$BEGIN RETURN 1; END$$", error.TypeMismatch);
    try sameState(&.{ proc_probe, "SELECT fact(id), classify(v), loops(id), safe_div(v, g - 1), depth(id) FROM tdd_a ORDER BY id" });
}

// ---- procedures, CALL and DO --------------------------------------------------

fn proceduresAndDo() !void {
    try base();
    try run("CREATE TABLE u(id INT PRIMARY KEY, sq INT)");
    try run("CREATE PROCEDURE addrow(i INT, w INT) LANGUAGE SQL AS 'INSERT INTO u VALUES (i, w); INSERT INTO u VALUES (i + 100, w)'");
    try completes("CALL addrow(5, 50)", .call, 0);
    try expect("SELECT id, sq FROM u ORDER BY id", "5|50;105|50");
    // A failing statement undoes the whole CALL.
    try run("INSERT INTO u VALUES (106, 0)");
    try rejects("CALL addrow(6, 60)", error.PrimaryKeyViolation, "SELECT id FROM u ORDER BY id", "5;105;106");
    try rejects("CALL addrow('x', 1)", error.InvalidTextRepresentation, "SELECT id FROM u ORDER BY id", "5;105;106");
    try run("DELETE FROM u");
    try run(
        \\CREATE PROCEDURE fill(n INT) LANGUAGE plpgsql AS $$
        \\DECLARE i INT; m INT;
        \\BEGIN
        \\  FOR i IN 1..n LOOP INSERT INTO u VALUES (i, i * i); END LOOP;
        \\  SELECT max(sq) INTO m FROM u;
        \\  INSERT INTO u VALUES (0, m);
        \\END $$
    );
    try completes("CALL fill(3)", .call, 0);
    try expect("SELECT id, sq FROM u ORDER BY id", "0|9;1|1;2|4;3|9");
    try completes("DO $$BEGIN NULL; END$$", .do_block, 0);
    try completes("DO LANGUAGE plpgsql $$DECLARE c INT; BEGIN SELECT count(*) INTO c FROM u; IF c <> 4 THEN RAISE EXCEPTION 'count %', c; END IF; END$$", .do_block, 0);
    // EXCEPTION blocks roll their writes back.
    try run("DO $$BEGIN INSERT INTO u VALUES (50, 1); INSERT INTO u VALUES (50, 2); EXCEPTION WHEN unique_violation THEN INSERT INTO u VALUES (51, 3); END$$");
    try expect("SELECT id, sq FROM u WHERE id >= 50 ORDER BY id", "51|3");
    try rejects("DO $$BEGIN INSERT INTO u VALUES (60, 1); RAISE EXCEPTION 'stop'; END$$", error.RaiseException, "SELECT count(*) FROM u", "5");
    try rejects("DO $$DECLARE x INT; BEGIN SELECT id INTO STRICT x FROM u WHERE id > 1000; END$$", error.NoDataFound, "SELECT count(*) FROM u", "5");
    try rejects("DO $$DECLARE x INT; BEGIN SELECT id INTO STRICT x FROM u; END$$", error.TooManyRows, "SELECT count(*) FROM u", "5");
    try run("DO $$DECLARE x INT := 7; BEGIN SELECT id INTO x FROM u WHERE id > 1000; IF x IS NOT NULL OR FOUND THEN RAISE EXCEPTION 'x %', x; END IF; END$$");
    try run(
        \\DO $$DECLARE n INT; BEGIN
        \\  UPDATE u SET sq = sq + 1 WHERE id < 3;
        \\  GET DIAGNOSTICS n = ROW_COUNT;
        \\  IF NOT FOUND OR n <> 3 THEN RAISE EXCEPTION 'n %', n; END IF;
        \\  INSERT INTO u VALUES (70, 1) RETURNING sq * 10 INTO n;
        \\  INSERT INTO u VALUES (71, n);
        \\END$$
    );
    try expect("SELECT id, sq FROM u ORDER BY id", "0|10;1|2;2|5;3|9;51|3;70|1;71|10");
    // plpgsql variables and columns of the same name are ambiguous (42702).
    try rejects("DO $$DECLARE id INT := 1; BEGIN UPDATE u SET sq = 0 WHERE id = id; END$$", error.AmbiguousColumn, "SELECT sum(sq) FROM u", "40");
    try fails("DO $$BEGIN SELECT 1; END$$", error.Syntax);
    try fails("DO $$BEGIN COMMIT; END$$", error.UnsupportedStatement);
    try fails("DO LANGUAGE sql $$SELECT 1$$", error.UnsupportedStatement);
    try fails("DO LANGUAGE plperl $$1$$", error.UndefinedObject);
    try fails("DO $$BEGIN IF true THEN NULL; END$$", error.Syntax);
    // Nested CALL and DO statements run inside a DO block.
    try run("DO $$BEGIN CALL addrow(200, 1); END$$");
    try expect("SELECT count(*) FROM u WHERE id >= 200", "2");
    try sameState(&.{ proc_probe, "SELECT id, sq FROM u ORDER BY id" });
}

// ---- triggers ---------------------------------------------------------------------

fn triggers() !void {
    reset();
    try run("CREATE TABLE a(id INT PRIMARY KEY, v INT NOT NULL, note TEXT)");
    try run("CREATE FUNCTION set_v() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.v IS NULL THEN NEW.v := 42; END IF; NEW.note := TG_OP || ':' || TG_WHEN || ':' || TG_LEVEL || ':' || TG_TABLE_NAME; RETURN NEW; END$$");
    try fails("SELECT set_v()", error.UnsupportedStatement);
    try completes("CREATE TRIGGER a_bi BEFORE INSERT OR UPDATE ON a FOR EACH ROW EXECUTE FUNCTION set_v()", .create_trigger, 0);
    // NOT NULL is checked after BEFORE ROW triggers.
    try completes("INSERT INTO a(id) VALUES (1)", .insert, 1);
    try expect("SELECT id, v, note FROM a", "1|42|INSERT:BEFORE:ROW:a");
    try completes("UPDATE a SET v = NULL WHERE id = 1", .update, 1);
    try expect("SELECT id, v, note FROM a", "1|42|UPDATE:BEFORE:ROW:a");
    // RETURN NULL skips the row; triggers fire in name order.
    try run("CREATE FUNCTION skip_neg() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.v < 0 THEN RETURN NULL; END IF; RETURN NEW; END$$");
    try run("CREATE TRIGGER a_skip BEFORE INSERT ON a FOR EACH ROW EXECUTE FUNCTION skip_neg()");
    try completes("INSERT INTO a VALUES (2, -5, 'x'), (3, 5, 'y')", .insert, 1);
    try expect("SELECT id, v, note FROM a ORDER BY id", "1|42|UPDATE:BEFORE:ROW:a;3|5|INSERT:BEFORE:ROW:a");
    try run("CREATE FUNCTION keep_one() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF OLD.id = 1 THEN RETURN NULL; END IF; RETURN OLD; END$$");
    try run("CREATE TRIGGER a_bd BEFORE DELETE ON a FOR EACH ROW EXECUTE FUNCTION keep_one()");
    try completes("DELETE FROM a", .delete, 1);
    try expect("SELECT id FROM a", "1");
    // AFTER ROW triggers run at statement end; an error undoes the statement.
    try run("CREATE FUNCTION guard() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.v > 100 THEN RAISE EXCEPTION 'too big %', NEW.v; END IF; RETURN NULL; END$$");
    try run("CREATE TRIGGER a_ai AFTER INSERT ON a FOR EACH ROW WHEN (NEW.v > 50) EXECUTE FUNCTION guard()");
    try rejects("INSERT INTO a VALUES (4, 10, ''), (5, 200, '')", error.RaiseException, "SELECT id FROM a ORDER BY id", "1");
    try completes("INSERT INTO a VALUES (6, 60, '')", .insert, 1);
    // UPDATE OF: only when the column is a SET target.
    try run("CREATE FUNCTION bump() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN NEW.note := 'bumped'; RETURN NEW; END$$");
    try run("CREATE TRIGGER a_bu BEFORE UPDATE OF v ON a FOR EACH ROW EXECUTE FUNCTION bump()");
    try completes("UPDATE a SET note = 'n' WHERE id = 6", .update, 1);
    try expect("SELECT note FROM a WHERE id = 6", "UPDATE:BEFORE:ROW:a");
    try completes("UPDATE a SET v = 61 WHERE id = 6", .update, 1);
    try expect("SELECT v, note FROM a WHERE id = 6", "61|bumped");
    // Statement triggers fire even when no row qualifies.
    try run("CREATE FUNCTION refuse() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'refused %', TG_OP; END$$");
    try run("CREATE TABLE b(id INT PRIMARY KEY)");
    try run("INSERT INTO b VALUES (1), (2)");
    try run("CREATE TRIGGER b_bs BEFORE DELETE OR TRUNCATE ON b FOR EACH STATEMENT EXECUTE FUNCTION refuse()");
    try rejects("DELETE FROM b WHERE false", error.RaiseException, "SELECT count(*) FROM b", "2");
    try rejects("TRUNCATE b", error.RaiseException, "SELECT count(*) FROM b", "2");
    try completes("UPDATE b SET id = id + 10", .update, 2);
    try expect(trigger_probe, "16387|16384|a_bi|16386|23|O|0;16389|16384|a_skip|16388|7|O|0;16391|16384|a_bd|16390|11|O|0;16393|16384|a_ai|16392|5|O|0;16395|16384|a_bu|16394|19|O|0;16399|16397|b_bs|16396|42|O|0");
    // Definition errors.
    try fails("CREATE TRIGGER x AFTER INSERT ON a FOR EACH ROW EXECUTE FUNCTION nosuch()", error.UndefinedFunction);
    try run("CREATE FUNCTION plain() RETURNS INT LANGUAGE SQL AS 'SELECT 1'");
    try fails("CREATE TRIGGER x AFTER INSERT ON a FOR EACH ROW EXECUTE FUNCTION plain()", error.InvalidObjectDefinition);
    try fails("CREATE TRIGGER a_bi AFTER INSERT ON a FOR EACH ROW EXECUTE FUNCTION guard()", error.DuplicateObject);
    try fails("CREATE TRIGGER x AFTER INSERT ON a FOR EACH ROW WHEN (OLD.v > 1) EXECUTE FUNCTION guard()", error.InvalidObjectDefinition);
    try fails("CREATE TRIGGER x AFTER DELETE ON a FOR EACH ROW WHEN (NEW.v > 1) EXECUTE FUNCTION guard()", error.InvalidObjectDefinition);
    try fails("CREATE TRIGGER x AFTER INSERT ON a FOR EACH STATEMENT WHEN (NEW.v > 1) EXECUTE FUNCTION guard()", error.InvalidObjectDefinition);
    try fails("CREATE TRIGGER x AFTER INSERT ON a FOR EACH ROW WHEN ((SELECT 1) = 1) EXECUTE FUNCTION guard()", error.UnsupportedStatement);
    try fails("CREATE TRIGGER x AFTER INSERT ON a FOR EACH ROW WHEN (NEW.nosuch > 1) EXECUTE FUNCTION guard()", error.ColumnNotFound);
    try fails("CREATE TRIGGER x BEFORE TRUNCATE ON a FOR EACH ROW EXECUTE FUNCTION guard()", error.UnsupportedStatement);
    try fails("CREATE TRIGGER x AFTER UPDATE OF nosuch ON a FOR EACH ROW EXECUTE FUNCTION guard()", error.ColumnNotFound);
    try fails("CREATE TRIGGER x AFTER INSERT ON nosuch FOR EACH ROW EXECUTE FUNCTION guard()", error.TableNotFound);
    try fails("CREATE TRIGGER x INSTEAD OF INSERT ON a FOR EACH ROW EXECUTE FUNCTION guard()", error.UnsupportedStatement);
    try fails("DROP TRIGGER nosuch ON a", error.UndefinedObject);
    try completes("DROP TRIGGER IF EXISTS nosuch ON a", .drop_trigger, 0);
    // A function used by a trigger needs CASCADE; DROP TABLE takes its triggers.
    try fails("DROP FUNCTION set_v()", error.DependentObjects);
    try completes("DROP FUNCTION set_v() CASCADE", .drop_function, 0);
    try rejects("INSERT INTO a(id) VALUES (7)", error.NotNullViolation, "SELECT count(*) FROM a", "2");
    try completes("CREATE OR REPLACE TRIGGER a_ai AFTER INSERT ON a FOR EACH ROW WHEN (NEW.v > 500) EXECUTE FUNCTION guard()", .create_trigger, 0);
    try completes("INSERT INTO a VALUES (8, 200, '')", .insert, 1);
    try completes("DROP TRIGGER a_skip ON a", .drop_trigger, 0);
    try completes("INSERT INTO a VALUES (9, -1, '')", .insert, 1);
    try sameState(&.{ trigger_probe, proc_probe, "SELECT id, v, note FROM a ORDER BY id", "SELECT id FROM b ORDER BY id" });
    try sameEffect("DELETE FROM a WHERE id < 9");
    try sameEffect("UPDATE a SET v = 7");
    try same(try query(&replica, "SELECT id, v, note FROM a ORDER BY id"), "1|7|bumped;9|7|bumped");
    try completes("DROP TABLE a", .drop_table, 0);
    try expect("SELECT tgname FROM pg_trigger ORDER BY tgname", "b_bs");
    try sameState(&.{ trigger_probe, proc_probe });
}

// ---- rules ----------------------------------------------------------------------

fn rules() !void {
    reset();
    try run("CREATE TABLE r(id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO r VALUES (1, 10), (2, 20), (3, 30)");
    try completes("CREATE RULE r_protect AS ON DELETE TO r WHERE OLD.id < 3 DO INSTEAD NOTHING", .create_rule, 0);
    try completes("DELETE FROM r", .delete, 1);
    try expect("SELECT id FROM r ORDER BY id", "1;2");
    try run("CREATE RULE r_noins AS ON INSERT TO r DO INSTEAD NOTHING");
    try completes("INSERT INTO r VALUES (9, 9)", .insert, 0);
    try rejects("INSERT INTO r VALUES (9, 9) RETURNING id", error.UnsupportedStatement, "SELECT count(*) FROM r", "2");
    try run("CREATE RULE r_also AS ON UPDATE TO r DO ALSO NOTHING");
    try completes("UPDATE r SET v = v + 1", .update, 2);
    try expect("SELECT id, v FROM r ORDER BY id", "1|11;2|21");
    try fails("CREATE RULE r_noins AS ON INSERT TO r DO INSTEAD NOTHING", error.DuplicateObject);
    try completes("CREATE OR REPLACE RULE r_noins AS ON INSERT TO r WHERE NEW.v > 100 DO INSTEAD NOTHING", .create_rule, 0);
    try completes("INSERT INTO r VALUES (10, 5), (11, 500)", .insert, 1);
    try fails("CREATE RULE x AS ON INSERT TO r WHERE OLD.id > 1 DO INSTEAD NOTHING", error.InvalidObjectDefinition);
    try fails("CREATE RULE x AS ON DELETE TO r WHERE NEW.id > 1 DO INSTEAD NOTHING", error.InvalidObjectDefinition);
    try fails("CREATE RULE x AS ON DELETE TO r DO INSTEAD DELETE FROM r", error.UnsupportedStatement);
    try fails("CREATE RULE x AS ON SELECT TO r DO INSTEAD NOTHING", error.UnsupportedStatement);
    try fails("MERGE INTO r USING (SELECT 1 AS id) s ON r.id = s.id WHEN MATCHED THEN DELETE", error.UnsupportedStatement);
    try fails("INSERT INTO r VALUES (1, 1) ON CONFLICT DO NOTHING", error.UnsupportedStatement);
    try fails("WITH d AS (DELETE FROM r RETURNING id) SELECT count(*) FROM d", error.UnsupportedStatement);
    try fails("DROP RULE nosuch ON r", error.UndefinedObject);
    // PostgreSQL deparses the qualification (`(old.id < 3)`); it is shown
    // as written here (pending native verification).
    try expect(rule_probe,
        \\16386|r_protect|4|t|CREATE RULE r_protect AS
        \\    ON DELETE TO public.r
        \\   WHERE (OLD.id < 3) DO INSTEAD NOTHING;;16387|r_noins|3|t|CREATE RULE r_noins AS
        \\    ON INSERT TO public.r
        \\   WHERE (NEW.v > 100) DO INSTEAD NOTHING;;16388|r_also|2|f|CREATE RULE r_also AS
        \\    ON UPDATE TO public.r DO NOTHING;
    );
    try sameState(&.{ rule_probe, "SELECT id, v FROM r ORDER BY id" });
    try sameEffect("DELETE FROM r");
    try completes("DROP RULE r_noins ON r", .drop_rule, 0);
    try completes("INSERT INTO r VALUES (12, 500)", .insert, 1);
    try completes("DROP TABLE r", .drop_table, 0);
    try expect("SELECT count(*) FROM pg_rewrite", "0");
    try sameState(&.{rule_probe});
}

// ---- concurrency -------------------------------------------------------------------

fn concurrency() !void {
    try base();
    // A function another transaction creates is invisible until commit; a
    // concurrent CREATE of the same signature waits, then is 42723.
    const t1 = try db.begin();
    const t2 = try db.begin();
    try statement(t1, "CREATE FUNCTION cf(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x * 3'");
    try same(try rows(t1, "SELECT cf(2)"), "6");
    try statementFails(t2, "SELECT cf(2)", error.UndefinedFunction);
    try parks(t2, "CREATE FUNCTION cf(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x'");
    try commit(t1);
    try resumeFails(t2, "CREATE FUNCTION cf(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x'", error.DuplicateFunction);
    db.abort(t2);
    // DROP is transactional: the old version serves other snapshots.
    const t3 = try db.begin();
    const t4 = try db.begin();
    try statement(t3, "DROP FUNCTION cf(INT)");
    try statementFails(t3, "SELECT cf(1)", error.UndefinedFunction);
    try same(try rows(t4, "SELECT cf(1)"), "3");
    db.abort(t3);
    try same(try rows(t4, "SELECT cf(2)"), "6");
    try commit(t4);
    // CREATE TRIGGER holds AccessExclusive: a writer waits, then fires it.
    try run("CREATE FUNCTION mark() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN NEW.v := -1; RETURN NEW; END$$");
    const t5 = try db.begin();
    const t6 = try db.begin();
    try statement(t5, "CREATE TRIGGER mk BEFORE INSERT ON tdd_b FOR EACH ROW EXECUTE FUNCTION mark()");
    // Another table is not locked.
    try statement(t6, "INSERT INTO tdd_a VALUES (7, 7, 7)");
    try parks(t6, "INSERT INTO tdd_b VALUES (7, 7)");
    try commit(t5);
    _ = try resumed(t6, "INSERT INTO tdd_b VALUES (7, 7)");
    try commit(t6);
    try expect("SELECT id, v FROM tdd_b ORDER BY id", "1|11;3|33;5|55;7|-1");
    // A DO block that must wait undoes its work, parks and runs again.
    try run("CREATE TABLE k(id INT PRIMARY KEY)");
    const t7 = try db.begin();
    const t8 = try db.begin();
    try statement(t7, "UPDATE tdd_a SET v = 1 WHERE id = 1");
    const block = "DO $$BEGIN INSERT INTO k VALUES (1); UPDATE tdd_a SET v = v + 100 WHERE id = 1; END$$";
    try parks(t8, block);
    try same(try rows(t7, "SELECT count(*) FROM k"), "0");
    try commit(t7);
    _ = try resumed(t8, block);
    try same(try rows(t8, "SELECT id FROM k"), "1");
    try commit(t8);
    try expect("SELECT v FROM tdd_a WHERE id = 1", "101");
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0);
    try sameState(&.{ proc_probe, trigger_probe, "SELECT id, g, v FROM tdd_a ORDER BY id", "SELECT id FROM k", "SELECT cf(id) FROM tdd_b ORDER BY id" });
}

// ---- work control, capacity and durability -----------------------------------------

const Interrupt = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    fn poll(context: ?*anyopaque) sql.Error!void {
        const self: *Interrupt = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls >= self.fail_at) return error.QueryCanceled;
    }
};

/// The statement under `control` fails with `wanted` (the work budget or
/// a cancel never reaches an EXCEPTION handler) and changes nothing.
fn limited(control: *sql.ExecutionControl, source: []const u8, wanted: anyerror) !void {
    db.session.control = control;
    var result: DB.Result = .{};
    const outcome = db.execute(source, &result);
    db.session.control = null;
    if (outcome) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try expect("SELECT id FROM tdd_b ORDER BY id", "1;3;5");
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0);
}

fn workControl() !void {
    try base();
    try run("CREATE FUNCTION spin() RETURNS INT LANGUAGE plpgsql AS $$BEGIN LOOP BEGIN NULL; EXCEPTION WHEN OTHERS THEN NULL; END; END LOOP; END$$");
    var control: sql.ExecutionControl = .{ .max_work = 5000 };
    try limited(&control, "SELECT spin()", error.QueryWorkLimit);
    control = .{ .max_work = 5000 };
    try limited(&control, "DO $$DECLARE x INT := 0; BEGIN INSERT INTO tdd_b VALUES (100, 1); LOOP x := x + 1; END LOOP; END$$", error.QueryWorkLimit);
    var interrupt: Interrupt = .{ .fail_at = 3 };
    control = .{ .poll = Interrupt.poll, .context = &interrupt, .poll_interval = 64 };
    try limited(&control, "DO $$DECLARE i INT := 0; BEGIN INSERT INTO tdd_b VALUES (9, 9); WHILE true LOOP i := i + 1; END LOOP; EXCEPTION WHEN OTHERS THEN NULL; END$$", error.QueryCanceled);
    try check(interrupt.calls == 3);
    // A bounded loop finishes within its budget.
    control = .{ .max_work = 100000 };
    db.session.control = &control;
    var done: DB.Result = .{};
    try db.execute("DO $$DECLARE i INT := 0; BEGIN WHILE i < 100 LOOP i := i + 1; END LOOP; END$$", &done);
    try check(done.command == .do_block and control.used > 100 and control.used < 100000);
    db.session.control = null;
}

var small: Small = .{};

fn capacity() !void {
    small = .{};
    var result: Small.Result = .{};
    try small.execute("CREATE TABLE t(id INT PRIMARY KEY)", &result);
    try small.execute("CREATE FUNCTION f1() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN f2(); END$$", &result);
    try small.execute("CREATE FUNCTION f2() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN 1; END$$", &result);
    if (small.execute("CREATE FUNCTION f3() RETURNS INT LANGUAGE SQL AS 'SELECT 1'", &result)) |_| try check(false) else |err| try check(err == error.TableCapacity);
    try small.execute("SELECT f1()", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 1);
    // Replacing needs a free slot for the new version (54000 without one).
    if (small.execute("CREATE OR REPLACE FUNCTION f2() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN 2; END$$", &result)) |_| try check(false) else |err| try check(err == error.TableCapacity);
    try small.execute("DROP FUNCTION f1", &result);
    try small.execute("CREATE OR REPLACE FUNCTION f2() RETURNS INT LANGUAGE plpgsql AS $$BEGIN RETURN 2; END$$", &result);
    try small.execute("SELECT f2()", &result);
    try check(result.rows[0].cells[0].integer == 2);
    // Config.routine_bytes bounds a body (54000).
    var long: [400]u8 = undefined;
    const head = "CREATE FUNCTION f4() RETURNS INT LANGUAGE SQL AS '";
    @memcpy(long[0..head.len], head);
    @memset(long[head.len .. long.len - 2], ' ');
    long[long.len - 2] = '\'';
    long[long.len - 1] = ' ';
    if (small.execute(&long, &result)) |_| try check(false) else |err| try check(err == error.TextCapacity);
    // Config.routine_depth (3) bounds nesting (54001).
    try small.execute("DROP FUNCTION f2", &result);
    try small.execute("CREATE FUNCTION d(n INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN IF n = 0 THEN RETURN 0; END IF; RETURN d(n - 1); END$$", &result);
    try small.execute("SELECT d(2)", &result);
    if (small.execute("SELECT d(3)", &result)) |_| try check(false) else |err| try check(err == error.StackDepthExceeded);
    // One trigger and one rule slot.
    try small.execute("CREATE FUNCTION tg() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$", &result);
    try small.execute("CREATE TRIGGER t1 BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION tg()", &result);
    if (small.execute("CREATE TRIGGER t2 BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION tg()", &result)) |_| try check(false) else |err| try check(err == error.TableCapacity);
    try small.execute("CREATE RULE r1 AS ON DELETE TO t DO INSTEAD NOTHING", &result);
    if (small.execute("CREATE RULE r2 AS ON UPDATE TO t DO INSTEAD NOTHING", &result)) |_| try check(false) else |err| try check(err == error.TableCapacity);
    try check(small.usage().pending_versions == 0);
}

/// Crafted object ops: every malformed payload is InvalidChangeRecord,
/// every unknown reference ChangeRecordConflict, and nothing applies.
fn changeRecords() !void {
    try base();
    var result: DB.Result = .{};
    var used: usize = 0;
    try db.executeChanges("CREATE FUNCTION rf(x INT) RETURNS INT LANGUAGE SQL AS 'SELECT x'", &result, &record, &used, null, null);
    var good: [512]u8 = undefined;
    @memcpy(good[0..used], record[0..used]);
    const length = used;
    try check(good[8] == 60);
    var fresh: DB = .{};
    var copy: [512]u8 = undefined;
    // Truncated payload, flipped kind, bad language, unknown type OID.
    for ([_]usize{ 13, 14, 20 }) |cut| {
        @memcpy(copy[0..length], good[0..length]);
        if (fresh.applyChangeRecord(copy[0..cut], &scratch)) |_| try check(false) else |err| try check(err == error.InvalidChangeRecord);
    }
    const name_len = good[13 + 8];
    const kind_at = 13 + 8 + 1 + name_len;
    for ([_]usize{ kind_at, kind_at + 1, kind_at + 2, kind_at + 3, kind_at + 4 }) |at| {
        @memcpy(copy[0..length], good[0..length]);
        copy[at] = 0x77;
        if (fresh.applyChangeRecord(copy[0..length], &scratch)) |_| try check(false) else |err| try check(err == error.InvalidChangeRecord);
    }
    // The argument type OID (after its name).
    @memcpy(copy[0..length], good[0..length]);
    const type_at = kind_at + 5 + 1 + good[kind_at + 5];
    copy[type_at] = 0xee;
    if (fresh.applyChangeRecord(copy[0..length], &scratch)) |_| try check(false) else |err| try check(err == error.InvalidChangeRecord);
    // Trailing payload bytes.
    @memcpy(copy[0..length], good[0..length]);
    copy[9] +%= 1;
    copy[length] = 0;
    if (fresh.applyChangeRecord(copy[0 .. length + 1], &scratch)) |_| try check(false) else |err| try check(err == error.InvalidChangeRecord);
    // An OID below 16384, a drop of an unknown OID, a duplicate signature.
    @memcpy(copy[0..length], good[0..length]);
    copy[13] = 1;
    copy[14] = 0;
    copy[15] = 0;
    copy[16] = 0;
    if (fresh.applyChangeRecord(copy[0..length], &scratch)) |_| try check(false) else |err| try check(err == error.ChangeRecordConflict);
    const drop = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 61, 4, 0, 0, 0, 0x99, 0x99, 0, 0 };
    if (fresh.applyChangeRecord(&drop, &scratch)) |_| try check(false) else |err| try check(err == error.ChangeRecordConflict);
    try check(fresh.oid_counter == 0);
    try fresh.applyChangeRecord(good[0..length], &scratch);
    if (fresh.applyChangeRecord(good[0..length], &scratch)) |_| try check(false) else |err| try check(err == error.ChangeRecordConflict);
    var fresh_result: DB.Result = .{};
    try fresh.execute("SELECT rf(5)", &fresh_result);
    try check(fresh_result.rows[0].cells[0].integer == 5);
    // A trigger naming an unknown function or table conflicts.
    used = 0;
    try db.executeChanges("CREATE FUNCTION rt() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$", &result, &record, &used, null, null);
    used = 0;
    try db.executeChanges("CREATE TRIGGER rtt BEFORE INSERT ON tdd_a FOR EACH ROW EXECUTE FUNCTION rt()", &result, &record, &used, null, null);
    var empty: DB = .{};
    if (empty.applyChangeRecord(record[0..used], &scratch)) |_| try check(false) else |err| try check(err == error.ChangeRecordConflict);
    try check(empty.tableCount() == 0 and empty.oid_counter == 0);
}

pub fn main() !void {
    try oraclePrograms();
    try sqlFunctions();
    try plpgsqlFunctions();
    try proceduresAndDo();
    try triggers();
    try rules();
    try concurrency();
    try workControl();
    try capacity();
    try changeRecords();
    std.debug.print("routines: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
