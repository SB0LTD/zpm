//! DDL, constraint and DML contracts (conformance lane B11): TRUNCATE,
//! CHECK / UNIQUE / composite PRIMARY KEY, ALTER TABLE, sequence lifecycle
//! (CACHE, ALTER SEQUENCE, SERIAL), UPDATE ... FROM, DELETE ... USING, tuple
//! assignment and schemas. Each section checks values (PostgreSQL 18 text
//! output), exact errors (SQLSTATE through the error name), atomicity after
//! a failure, concurrency where a lock or a unique key decides, and replay:
//! every committed record is applied to a replica that must answer every
//! probe exactly like the primary (committed state = replay(WAL)).
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 8, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 96, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 1024 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [32768]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("ddl-core contract failed at assertion {d}\n", .{assertions});
        return error.DdlCoreContractFailed;
    }
}

var text_buffer: [8192]u8 = undefined;
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
        try replica.applyChangeRecord(record[0..used], &scratch);
        records_applied += 1;
    }
    return result;
}

fn run(source: []const u8) !void {
    _ = try replicate(source);
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
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0 and db.usage().table_locks == 0);
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
    try db.statement(slot, source, &result, .{});
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

/// Encodes, replays and publishes a transaction (Store.commit order).
fn commit(slot: u16) !void {
    if (!db.readOnly(slot)) {
        const payload = try db.prepareCommit(slot, &record);
        try replica.applyChangeRecord(payload, &scratch);
        records_applied += 1;
    }
    db.publishCommit(slot);
}

/// Every probe answers identically on the primary and the replay.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const left = try query(&db, probe);
        var copy: [8192]u8 = undefined;
        @memcpy(copy[0..left.len], left);
        const right = try query(&replica, probe);
        if (!std.mem.eql(u8, copy[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy[0..left.len], right });
        try check(std.mem.eql(u8, copy[0..left.len], right));
    }
    try check(db.tableCount() == replica.tableCount());
    try check(db.oid_counter == replica.oid_counter);
}

fn reset() void {
    db = .{};
    replica = .{};
}

// ---- TRUNCATE --------------------------------------------------------------

const truncate_probes = [_][]const u8{
    "SELECT id, v FROM t ORDER BY id",
    "SELECT COUNT(*), SUM(v) FROM t",
    "SELECT k FROM u ORDER BY k",
    "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
};

fn truncateTable() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)");
    try run("CREATE TABLE u (k INT)");
    try run("INSERT INTO u VALUES (5), (6)");
    try expect("SELECT COUNT(*), SUM(v) FROM t", "3|60");
    const result = try replicate("TRUNCATE t");
    try check(result.command == .truncate and result.affected_rows == 0 and result.column_count == 0);
    try expect("SELECT COUNT(*), SUM(v) FROM t", "0|NULL");
    try expect("SELECT k FROM u ORDER BY k", "5;6");
    // The keys are free again; the committed summary follows the rows.
    try run("INSERT INTO t VALUES (1, 11), (4, 40)");
    try expect("SELECT COUNT(*), SUM(v) FROM t", "2|51");
    try sameState(&truncate_probes);
    // TABLE, ONLY, a table list, CONTINUE IDENTITY and RESTRICT; a repeated
    // name is truncated once.
    try run("TRUNCATE TABLE ONLY t, u, t CONTINUE IDENTITY RESTRICT");
    try expect("SELECT COUNT(*) FROM t", "0");
    try expect("SELECT COUNT(*) FROM u", "0");
    try run("TRUNCATE u CASCADE");
    try run("INSERT INTO t VALUES (7, 70)");
    try run("INSERT INTO u VALUES (8)");
    try sameState(&truncate_probes);
    try check(db.storageStats("t").?.live_rows == 1);
    // Every dead version was reclaimed when the TRUNCATE published.
    try check(db.storageStats("u").?.versions == 1);
    try check(db.usage().pending_versions == 0 and db.usage().table_locks == 0);
}

fn truncateErrors() !void {
    // 42P01 for a missing table (the whole list fails), 42809 for a
    // sequence, 0A000 for RESTART IDENTITY, 42601 for bad syntax.
    try rejects("TRUNCATE missing", error.TableNotFound, "SELECT COUNT(*) FROM t", "1");
    try rejects("TRUNCATE t, missing", error.TableNotFound, "SELECT COUNT(*) FROM t", "1");
    try run("CREATE SEQUENCE trunc_seq");
    try rejects("TRUNCATE trunc_seq", error.WrongObjectType, "SELECT COUNT(*) FROM t", "1");
    try rejects("TRUNCATE t RESTART IDENTITY", error.UnsupportedStatement, "SELECT COUNT(*) FROM t", "1");
    try rejects("TRUNCATE", error.Syntax, "SELECT COUNT(*) FROM t", "1");
    try rejects("TRUNCATE t RESTART", error.Syntax, "SELECT COUNT(*) FROM t", "1");
}

fn truncateTransactions() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)");
    try run("CREATE TABLE u (k INT)");
    // Abort restores every row, including an own row written before.
    var slot = try db.begin();
    try statement(slot, "INSERT INTO t VALUES (4, 40)");
    try statement(slot, "TRUNCATE t");
    try same(try rows(slot, "SELECT COUNT(*) FROM t"), "0");
    try statement(slot, "INSERT INTO t VALUES (1, 100)");
    try same(try rows(slot, "SELECT id, v FROM t"), "1|100");
    db.abort(slot);
    try expect("SELECT id, v FROM t ORDER BY id", "1|10;2|20;3|30");
    try check(db.usage().pending_versions == 0);
    // ROLLBACK TO a savepoint before the TRUNCATE.
    slot = try db.begin();
    try statement(slot, "UPDATE t SET v = v + 1 WHERE id = 1");
    try db.savepoint(slot, "before");
    try statement(slot, "TRUNCATE t");
    try statement(slot, "INSERT INTO t VALUES (9, 90)");
    _ = try db.rollbackTo(slot, "before");
    try same(try rows(slot, "SELECT id, v FROM t ORDER BY id"), "1|11;2|20;3|30");
    try commit(slot);
    try sameState(&truncate_probes);
    // A failed statement after the TRUNCATE leaves the TRUNCATE in place.
    slot = try db.begin();
    try statement(slot, "INSERT INTO t VALUES (5, 50)");
    try statement(slot, "TRUNCATE t");
    try statement(slot, "INSERT INTO t VALUES (2, 21)");
    try statementFails(slot, "INSERT INTO t VALUES (2, 22)", error.PrimaryKeyViolation);
    try statementFails(slot, "INSERT INTO t VALUES (6, NULL), (NULL, 1)", error.NotNullViolation);
    try same(try rows(slot, "SELECT id, v FROM t ORDER BY id"), "2|21");
    try commit(slot);
    try expect("SELECT id, v FROM t ORDER BY id", "2|21");
    try sameState(&truncate_probes);
}

fn truncateLocks() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO t VALUES (1, 10), (2, 20)");
    try run("CREATE TABLE u (k INT)");
    // An uncommitted TRUNCATE holds AccessExclusive: readers wait, and the
    // committed view still holds every row until it publishes.
    const a = try db.begin();
    try statement(a, "TRUNCATE t");
    const b = try db.begin();
    try parks(b, "SELECT COUNT(*) FROM t");
    try check(db.waitingFor(b).has(a));
    try check(db.storageStats("t").?.live_rows == 2);
    try commit(a);
    try same(try resumed(b, "SELECT COUNT(*) FROM t"), "0");
    db.abort(b);
    // A reader's AccessShare blocks TRUNCATE until the reader ends.
    try run("INSERT INTO t VALUES (3, 30)");
    const reader = try db.begin();
    try same(try rows(reader, "SELECT COUNT(*) FROM t"), "1");
    const truncator = try db.begin();
    try parks(truncator, "TRUNCATE u, t");
    try check(db.waitingFor(truncator).has(reader));
    try commit(reader);
    _ = try resumed(truncator, "TRUNCATE u, t");
    try commit(truncator);
    try expect("SELECT COUNT(*) FROM t", "0");
    try sameState(&truncate_probes);
    // Inserters hold RowExclusive: TRUNCATE waits for them as well.
    const inserter = try db.begin();
    try statement(inserter, "INSERT INTO t VALUES (8, 80)");
    const second = try db.begin();
    try parks(second, "TRUNCATE t");
    db.abort(inserter);
    _ = try resumed(second, "TRUNCATE t");
    try commit(second);
    try check(db.usage().transactions == 0 and db.usage().table_locks == 0);
    try sameState(&truncate_probes);
}

// ---- CHECK -------------------------------------------------------------------

const check_probes = [_][]const u8{
    "SELECT v, w FROM c ORDER BY v NULLS FIRST",
    "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 'c' ORDER BY constraint_name",
    "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
};

fn copyRow(slot: u16, source: []const u8, fields: []const ?[]const u8) !void {
    var row: DB.Row = .{};
    try db.copyBuild(slot, source, fields, &row);
    try db.copyInsert(slot, &row);
}

fn checkConstraints() !void {
    reset();
    try run("CREATE TABLE c (v INT CHECK (v > 0), w INT, CONSTRAINT w_small CHECK (w < 100), CHECK (v < w))");
    try run("INSERT INTO c VALUES (1, 50)");
    // NULL satisfies a CHECK (only FALSE rejects).
    try run("INSERT INTO c VALUES (NULL, NULL), (2, NULL)");
    try expect(check_probes[0], "NULL|NULL;1|50;2|NULL");
    // PostgreSQL ChooseConstraintName: <table>_<column>_check for one
    // referenced column, <table>_check otherwise.
    try expect(check_probes[1], "c_check|CHECK;c_v_check|CHECK;w_small|CHECK");
    // 23514, and nothing of the statement survives (multi-row, UPDATE).
    try rejects("INSERT INTO c VALUES (0, 5)", error.CheckViolation, check_probes[0], "NULL|NULL;1|50;2|NULL");
    try rejects("INSERT INTO c VALUES (5, 200)", error.CheckViolation, check_probes[0], "NULL|NULL;1|50;2|NULL");
    try rejects("INSERT INTO c VALUES (3, 60), (10, 5)", error.CheckViolation, check_probes[0], "NULL|NULL;1|50;2|NULL");
    try rejects("UPDATE c SET v = v - 1", error.CheckViolation, check_probes[0], "NULL|NULL;1|50;2|NULL");
    try rejects("UPDATE c SET w = 1 WHERE v = 1", error.CheckViolation, check_probes[0], "NULL|NULL;1|50;2|NULL");
    try run("UPDATE c SET w = w + 1");
    try expect(check_probes[0], "NULL|NULL;1|51;2|NULL");
    try sameState(&check_probes);
    // The replica enforces the replayed constraints too.
    var result: DB.Result = .{};
    try check(replica.execute("INSERT INTO c VALUES (-1, 2)", &result) == error.CheckViolation);
    // NOT NULL is checked before CHECK (ExecConstraints order).
    try run("CREATE TABLE n (v INT NOT NULL CHECK (v > 0))");
    try rejects("INSERT INTO n VALUES (NULL)", error.NotNullViolation, "SELECT COUNT(*) FROM n", "0");
    try rejects("INSERT INTO n VALUES (-3)", error.CheckViolation, "SELECT COUNT(*) FROM n", "0");
    // Generated columns are computed before CHECK, ON CONFLICT DO UPDATE
    // re-checks the updated row, COPY checks every row.
    try run("CREATE TABLE k (id INT PRIMARY KEY, v INT CHECK (v >= 0), g INT GENERATED ALWAYS AS (v * 2) STORED CHECK (g < 100))");
    try run("INSERT INTO k (id, v) VALUES (1, 1)");
    try rejects("INSERT INTO k (id, v) VALUES (2, 60)", error.CheckViolation, "SELECT id, v, g FROM k", "1|1|2");
    try rejects("INSERT INTO k (id, v) VALUES (1, 3) ON CONFLICT (id) DO UPDATE SET v = -5", error.CheckViolation, "SELECT id, v, g FROM k", "1|1|2");
    try run("INSERT INTO k (id, v) VALUES (1, 3) ON CONFLICT (id) DO UPDATE SET v = excluded.v + 1");
    try expect("SELECT id, v, g FROM k", "1|4|8");
    const slot = try db.begin();
    _ = try db.copyBegin(slot, "COPY k (id, v) FROM STDIN", false);
    try copyRow(slot, "COPY k (id, v) FROM STDIN", &.{ "5", "5" });
    var row: DB.Row = .{};
    try check(db.copyBuild(slot, "COPY k (id, v) FROM STDIN", &.{ "6", "-6" }, &row) == error.CheckViolation);
    db.abort(slot);
    try expect("SELECT id, v, g FROM k", "1|4|8");
    // Definition errors: 42804 not boolean, 0A000 subquery, 42703 unknown
    // column, 42803 aggregate, 42710 duplicate name; nothing is created.
    try rejects("CREATE TABLE bad (v INT CHECK (v))", error.TypeMismatch, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (v INT CHECK (v > (SELECT 1)))", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (v INT CHECK (missing > 0))", error.ColumnNotFound, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (v INT CHECK (count(*) > 0))", error.GroupingError, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (v INT CONSTRAINT x CHECK (v > 0), CONSTRAINT x CHECK (v < 9))", error.DuplicateObject, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (v INT CHECK (v > 0) CHECK (v > 1) CHECK (v > 2) CHECK (v > 3) CHECK (v > 4) CHECK (v > 5) CHECK (v > 6) CHECK (v > 7) CHECK (v > 8))", error.ColumnCapacity, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    // Repeated generated names take a number (b_check, b_check1).
    try run("CREATE TABLE nm (a INT CHECK (a > 0), b INT CHECK (b > 0) CHECK (b < 9), CHECK (a < b), CHECK (a + b > 1) NO INHERIT)");
    try expect("SELECT constraint_name FROM information_schema.table_constraints WHERE table_name = 'nm' ORDER BY constraint_name", "nm_a_check;nm_b_check;nm_b_check1;nm_check;nm_check1");
    try sameState(&check_probes);
    try sameState(&.{"SELECT constraint_name, constraint_type FROM information_schema.table_constraints ORDER BY table_name, constraint_name"});
    // Transactions: a failed CHECK leaves earlier statements in place.
    const tx = try db.begin();
    try statement(tx, "INSERT INTO c VALUES (7, 70)");
    try statementFails(tx, "INSERT INTO c VALUES (8, 1)", error.CheckViolation);
    try commit(tx);
    try expect(check_probes[0], "NULL|NULL;1|51;2|NULL;7|70");
    try sameState(&check_probes);
}

// ---- UNIQUE ------------------------------------------------------------------

const unique_probes = [_][]const u8{
    "SELECT a, b, c FROM uq ORDER BY a NULLS FIRST, b, c",
    "SELECT a FROM und ORDER BY a NULLS FIRST",
    "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name IN ('uq', 'und', 'pu') AND constraint_type <> 'CHECK' ORDER BY constraint_name",
    "SELECT constraint_name, column_name, ordinal_position FROM information_schema.key_column_usage WHERE table_name IN ('uq', 'und', 'pu') ORDER BY constraint_name, ordinal_position",
};

fn uniqueConstraints() !void {
    reset();
    try run("CREATE TABLE uq (a INT UNIQUE, b INT, c INT, UNIQUE (b, c))");
    try run("INSERT INTO uq VALUES (1, 1, 1), (2, 1, 2), (NULL, 1, NULL), (NULL, 1, NULL)");
    try expect(unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;2|1|2");
    try expect(unique_probes[2], "uq_a_key|UNIQUE;uq_b_c_key|UNIQUE");
    try expect(unique_probes[3], "uq_a_key|a|1;uq_b_c_key|b|1;uq_b_c_key|c|2");
    // 23505 on INSERT, a duplicate inside one statement, UPDATE, and
    // PostgreSQL's immediate per-row check (a = a + 1 meets row 2 first).
    try rejects("INSERT INTO uq VALUES (1, 9, 9)", error.PrimaryKeyViolation, unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;2|1|2");
    try rejects("INSERT INTO uq VALUES (3, 1, 1)", error.PrimaryKeyViolation, unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;2|1|2");
    try rejects("INSERT INTO uq VALUES (5, 5, 5), (5, 6, 6)", error.PrimaryKeyViolation, unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;2|1|2");
    try rejects("UPDATE uq SET c = 1 WHERE a = 2", error.PrimaryKeyViolation, unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;2|1|2");
    try rejects("UPDATE uq SET a = a + 1", error.PrimaryKeyViolation, unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;2|1|2");
    // Keeping a key, or moving it to a free value, is fine.
    try run("UPDATE uq SET a = a + 10 WHERE a = 2");
    try run("UPDATE uq SET b = b WHERE a = 1");
    try expect(unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|1|1;12|1|2");
    // NULLS NOT DISTINCT: one NULL key only.
    try run("CREATE TABLE und (a INT UNIQUE NULLS NOT DISTINCT)");
    try run("INSERT INTO und VALUES (NULL), (1)");
    try rejects("INSERT INTO und VALUES (NULL)", error.PrimaryKeyViolation, unique_probes[1], "NULL;1");
    try sameState(&unique_probes);
    var result: DB.Result = .{};
    try check(replica.execute("INSERT INTO und VALUES (NULL)", &result) == error.PrimaryKeyViolation);
    // ON CONFLICT DO NOTHING without a target arbitrates every unique
    // index; with the primary key as target another unique key still fails.
    try run("CREATE TABLE pu (id INT PRIMARY KEY, e INT UNIQUE)");
    try run("INSERT INTO pu VALUES (1, 10)");
    const skipped = try replicate("INSERT INTO pu VALUES (2, 10) ON CONFLICT DO NOTHING");
    try check(skipped.affected_rows == 0);
    try rejects("INSERT INTO pu VALUES (2, 10) ON CONFLICT (id) DO NOTHING", error.PrimaryKeyViolation, "SELECT id, e FROM pu", "1|10");
    try run("INSERT INTO pu VALUES (2, 20)");
    try run("INSERT INTO pu VALUES (1, 11) ON CONFLICT (id) DO UPDATE SET e = 10, id = 3");
    try rejects("INSERT INTO pu VALUES (3, 11) ON CONFLICT (id) DO UPDATE SET e = 20", error.PrimaryKeyViolation, "SELECT id, e FROM pu ORDER BY id", "2|20;3|10");
    try rejects("CREATE TABLE bad (a INT CONSTRAINT dup UNIQUE, b INT CONSTRAINT dup UNIQUE)", error.DuplicateObject, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (a INT CONSTRAINT uq UNIQUE)", error.TableExists, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (a INT, UNIQUE (a, a))", error.DuplicateColumn, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (a INT, UNIQUE (z))", error.ColumnNotFound, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    // Own deletes free a key inside the transaction; ROLLBACK TO restores.
    var tx = try db.begin();
    try statement(tx, "DELETE FROM uq WHERE a = 1");
    try statement(tx, "INSERT INTO uq VALUES (1, 7, 7)");
    try db.savepoint(tx, "s");
    try statement(tx, "INSERT INTO uq VALUES (4, 8, 8)");
    _ = try db.rollbackTo(tx, "s");
    try statement(tx, "INSERT INTO uq VALUES (4, 9, 9)");
    try statementFails(tx, "INSERT INTO uq VALUES (4, 3, 3)", error.PrimaryKeyViolation);
    try commit(tx);
    try expect(unique_probes[0], "NULL|1|NULL;NULL|1|NULL;1|7|7;4|9|9;12|1|2");
    try sameState(&unique_probes);
    // COPY enforces the key.
    tx = try db.begin();
    _ = try db.copyBegin(tx, "COPY uq FROM STDIN", false);
    try copyRow(tx, "COPY uq FROM STDIN", &.{ "30", "30", "30" });
    var row: DB.Row = .{};
    try db.copyBuild(tx, "COPY uq FROM STDIN", &.{ "30", "31", "31" }, &row);
    try check(db.copyInsert(tx, &row) == error.PrimaryKeyViolation);
    db.abort(tx);
    try uniqueConcurrency("INSERT INTO uq VALUES (50, 50, 50)", "DELETE FROM uq WHERE a = 4", "INSERT INTO uq VALUES (4, 40, 40)");
    try sameState(&unique_probes);
}

/// Two transactions insert the same key: the second waits for the first
/// (dirty snapshot), then fails with 23505 when the first commits or
/// proceeds when it aborts; an uncommitted delete of a key is waited for too.
fn uniqueConcurrency(insert: []const u8, delete: []const u8, reinsert: []const u8) !void {
    for ([_]bool{ true, false }) |first_commits| {
        const first = try db.begin();
        try statement(first, insert);
        const second = try db.begin();
        try parks(second, insert);
        try check(db.waitingFor(second).has(first));
        if (first_commits) {
            try commit(first);
            var result: DB.Result = .{};
            try check(db.statement(second, insert, &result, .{ .@"resume" = true }) == error.PrimaryKeyViolation);
            db.abort(second);
        } else {
            db.abort(first);
            _ = try resumed(second, insert);
            try commit(second);
        }
        // Remove the row again for the next round.
        try run("DELETE FROM uq WHERE a = 50");
    }
    const deleter = try db.begin();
    try statement(deleter, delete);
    const inserter = try db.begin();
    try parks(inserter, reinsert);
    try commit(deleter);
    _ = try resumed(inserter, reinsert);
    try commit(inserter);
    try check(db.usage().transactions == 0 and db.usage().table_locks == 0);
}

// ---- composite PRIMARY KEY ---------------------------------------------------

const composite_probes = [_][]const u8{
    "SELECT a, b FROM tdd_pk ORDER BY a, b",
    "SELECT relname, relkind, relnatts FROM pg_class WHERE relname LIKE 'tdd_pk%' ORDER BY oid",
    "SELECT indisprimary, indisunique, indkey FROM pg_index WHERE indrelid = 'tdd_pk'::regclass",
    "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 'tdd_pk' AND constraint_type <> 'CHECK'",
    "SELECT constraint_name, column_name, ordinal_position FROM information_schema.key_column_usage WHERE table_name = 'tdd_pk' ORDER BY ordinal_position",
    "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'tdd_pk' ORDER BY ordinal_position",
    "SELECT oid, relname FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
};

fn compositeKeys() !void {
    reset();
    try run("CREATE TABLE tdd_pk (a INT, b INT, CONSTRAINT tdd_pk_pk PRIMARY KEY (a, b))");
    try run("INSERT INTO tdd_pk VALUES (1, 1), (1, 2)");
    try expect(composite_probes[0], "1|1;1|2");
    try expect(composite_probes[1], "tdd_pk|r|2;tdd_pk_pk|i|2");
    try expect(composite_probes[2], "t|t|1 2");
    try expect(composite_probes[3], "tdd_pk_pk|PRIMARY KEY");
    try expect(composite_probes[4], "tdd_pk_pk|a|1;tdd_pk_pk|b|2");
    try expect(composite_probes[5], "a|NO;b|NO");
    try rejects("INSERT INTO tdd_pk VALUES (1, 2)", error.PrimaryKeyViolation, composite_probes[0], "1|1;1|2");
    try rejects("INSERT INTO tdd_pk VALUES (2, NULL)", error.NotNullViolation, composite_probes[0], "1|1;1|2");
    try rejects("UPDATE tdd_pk SET b = 1", error.PrimaryKeyViolation, composite_probes[0], "1|1;1|2");
    try run("UPDATE tdd_pk SET b = b + 10 WHERE b = 2");
    // Engine OID scheme: the key index owns the OID after its table.
    const before = db.oid_counter;
    try run("CREATE TABLE after_pk (x INT, y INT, PRIMARY KEY (x, y))");
    try check(db.oid_counter == before + 2);
    try run("CREATE TABLE after_plain (x INT)");
    try check(db.oid_counter == before + 3);
    try sameState(&composite_probes);
    var result: DB.Result = .{};
    try check(replica.execute("INSERT INTO tdd_pk VALUES (1, 1)", &result) == error.PrimaryKeyViolation);
    // A named single-column key keeps the key index and its name.
    try run("CREATE TABLE np (id INT CONSTRAINT np_key PRIMARY KEY, v INT)");
    try run("INSERT INTO np VALUES (1, 1)");
    try run("INSERT INTO np VALUES (1, 2) ON CONFLICT ON CONSTRAINT np_key DO UPDATE SET v = excluded.v");
    try expect("SELECT id, v FROM np", "1|2");
    try expect("SELECT relname FROM pg_class WHERE relkind = 'i' AND relname LIKE 'np%'", "np_key");
    try run("CREATE TABLE tk (a INT, b TEXT, PRIMARY KEY (b))");
    try expect("SELECT relname FROM pg_class WHERE relkind = 'i' AND relname LIKE 'tk%'", "tk_pkey");
    try rejects("INSERT INTO tk VALUES (1, NULL)", error.NotNullViolation, "SELECT COUNT(*) FROM tk", "0");
    try rejects("CREATE TABLE bad (a INT PRIMARY KEY, b INT, PRIMARY KEY (b))", error.InvalidTableDefinition, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (a INT, b INT, PRIMARY KEY (a), PRIMARY KEY (b))", error.InvalidTableDefinition, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try sameState(&composite_probes);
    try sameState(&.{ "SELECT id, v FROM np", "SELECT a, b FROM tk", "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid" });
    // Concurrent inserts of the same composite key.
    const first = try db.begin();
    try statement(first, "INSERT INTO tdd_pk VALUES (7, 7)");
    const second = try db.begin();
    try parks(second, "INSERT INTO tdd_pk VALUES (7, 7)");
    try commit(first);
    try check(db.statement(second, "INSERT INTO tdd_pk VALUES (7, 7)", &result, .{ .@"resume" = true }) == error.PrimaryKeyViolation);
    db.abort(second);
    try sameState(&composite_probes);
}

pub fn main(init: std.process.Init) !void {
    try truncateTable();
    try truncateErrors();
    try truncateTransactions();
    try truncateLocks();
    try checkConstraints();
    try uniqueConstraints();
    try compositeKeys();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-ddl-core\",\"pass\":true,\"assertions\":{d},\"records\":{d},\"database_bytes\":{d}}}\n", .{ assertions, records_applied, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
