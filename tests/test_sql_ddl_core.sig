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
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
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

// ---- ALTER TABLE -------------------------------------------------------------

const alter_probes = [_][]const u8{
    "SELECT * FROM a ORDER BY id",
    "SELECT COUNT(*), SUM(id) FROM a",
    "SELECT column_name, ordinal_position, column_default, is_nullable, data_type FROM information_schema.columns WHERE table_name = 'a' ORDER BY ordinal_position",
    "SELECT attname, attnum, attnotnull FROM pg_attribute WHERE attrelid = 'a'::regclass ORDER BY attnum",
    "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 'a' AND constraint_type <> 'CHECK' ORDER BY constraint_name",
    "SELECT oid, relname, relkind, relnatts FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
};

fn alterValues() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    const altered = try replicate("ALTER TABLE a ADD COLUMN extra INT DEFAULT 7");
    try check(altered.command == .alter_table);
    try run("ALTER TABLE a RENAME COLUMN extra TO renamed");
    try expect("SELECT renamed FROM a ORDER BY id", "7;7;7;7");
    try run("INSERT INTO a (id, g, v) VALUES (5, 3, 50)");
    try expect("SELECT id, renamed FROM a WHERE id = 5", "5|7");
    // NULL fill, IF NOT EXISTS, several actions in one statement.
    try run("ALTER TABLE a ADD COLUMN note TEXT, ADD COLUMN IF NOT EXISTS g INT");
    try expect(alter_probes[0], "1|1|10|7|NULL;2|1|20|7|NULL;3|2|30|7|NULL;4|2|NULL|7|NULL;5|3|50|7|NULL");
    try run("ALTER TABLE a DROP COLUMN g");
    try expect(alter_probes[0], "1|10|7|NULL;2|20|7|NULL;3|30|7|NULL;4|NULL|7|NULL;5|50|7|NULL");
    try expect(alter_probes[2], "id|1|NULL|NO|integer;v|2|NULL|YES|integer;renamed|3|7|YES|integer;note|4|NULL|YES|text");
    try sameState(&alter_probes);
    // Defaults and NOT NULL.
    try run("ALTER TABLE a ALTER COLUMN v SET DEFAULT 99");
    try run("INSERT INTO a (id) VALUES (6)");
    try expect("SELECT v, renamed FROM a WHERE id = 6", "99|7");
    try run("ALTER TABLE a ALTER v DROP DEFAULT, ALTER COLUMN renamed DROP DEFAULT");
    try run("INSERT INTO a (id) VALUES (7)");
    try expect("SELECT v, renamed FROM a WHERE id = 7", "NULL|NULL");
    try rejects("ALTER TABLE a ALTER COLUMN v SET NOT NULL", error.NotNullViolation, alter_probes[2], "id|1|NULL|NO|integer;v|2|NULL|YES|integer;renamed|3|NULL|YES|integer;note|4|NULL|YES|text");
    try run("DELETE FROM a WHERE v IS NULL");
    try run("ALTER TABLE a ALTER COLUMN v SET NOT NULL");
    try rejects("INSERT INTO a (id) VALUES (8)", error.NotNullViolation, "SELECT COUNT(*) FROM a", "5");
    try run("ALTER TABLE a ALTER COLUMN v DROP NOT NULL");
    try rejects("ALTER TABLE a ALTER COLUMN id DROP NOT NULL", error.InvalidTableDefinition, "SELECT COUNT(*) FROM a", "5");
    // The primary key still holds and still probes after the relayout.
    try rejects("INSERT INTO a (id, v) VALUES (1, 1)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM a", "5");
    try expect("SELECT v FROM a WHERE id = 6", "99");
    try expect(alter_probes[1], "5|17");
    try sameState(&alter_probes);
    // A primary key that moves left keeps its index.
    try run("CREATE TABLE b (x INT, id INT PRIMARY KEY, w TEXT)");
    try run("INSERT INTO b VALUES (1, 10, 'a'), (2, 20, 'b')");
    try run("ALTER TABLE b DROP COLUMN x");
    try expect("SELECT w FROM b WHERE id = 20", "b");
    try rejects("INSERT INTO b VALUES (10, 'c')", error.PrimaryKeyViolation, "SELECT id, w FROM b ORDER BY id", "10|a;20|b");
    try sameState(&.{ "SELECT * FROM b ORDER BY id", "SELECT attname, attnum FROM pg_attribute WHERE attrelid = 'b'::regclass ORDER BY attnum" });
    // NOT NULL without a default needs an empty table.
    try rejects("ALTER TABLE b ADD COLUMN must INT NOT NULL", error.NotNullViolation, "SELECT * FROM b ORDER BY id", "10|a;20|b");
    try run("CREATE TABLE e (k INT)");
    try run("ALTER TABLE e ADD COLUMN must INT NOT NULL");
    try rejects("INSERT INTO e VALUES (1, NULL)", error.NotNullViolation, "SELECT COUNT(*) FROM e", "0");
    try sameState(&.{"SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'e' ORDER BY ordinal_position"});
    // RENAME TO keeps the index name (PostgreSQL does not rename it).
    try run("ALTER TABLE b RENAME TO b2");
    try expect("SELECT id, w FROM b2 ORDER BY id", "10|a;20|b");
    try expect("SELECT relname, relkind FROM pg_class WHERE relname LIKE 'b%' ORDER BY relname", "b2|r;b_pkey|i");
    try rejects("SELECT * FROM b", error.TableNotFound, "SELECT COUNT(*) FROM b2", "2");
    try sameState(&.{ "SELECT relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY relname", "SELECT id, w FROM b2 ORDER BY id" });
}

fn alterConstraints() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, v INT, w INT GENERATED ALWAYS AS (v * 2) STORED)");
    try run("INSERT INTO a (id, v) VALUES (1, 10), (2, -20), (3, 30)");
    // ADD CONSTRAINT validates existing rows.
    try rejects("ALTER TABLE a ADD CONSTRAINT v_pos CHECK (v > 0)", error.CheckViolation, "SELECT constraint_name FROM information_schema.table_constraints WHERE table_name = 'a' AND constraint_type = 'CHECK' AND constraint_name LIKE 'v%'", "");
    try run("UPDATE a SET v = 10 WHERE id = 2");
    try run("ALTER TABLE a ADD CONSTRAINT v_pos CHECK (v > 0)");
    try rejects("INSERT INTO a (id, v) VALUES (4, -1)", error.CheckViolation, "SELECT COUNT(*) FROM a", "3");
    try rejects("ALTER TABLE a ADD UNIQUE (v)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM a", "3");
    try run("UPDATE a SET v = 25 WHERE id = 2");
    try run("ALTER TABLE a ADD UNIQUE (v)");
    try rejects("INSERT INTO a (id, v) VALUES (4, 10)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM a", "3");
    try expect(alter_probes[4], "a_pkey|PRIMARY KEY;a_v_key|UNIQUE");
    // Renames rewrite stored CHECK and generation texts.
    try run("ALTER TABLE a RENAME COLUMN v TO val");
    try rejects("INSERT INTO a (id, val) VALUES (4, -1)", error.CheckViolation, "SELECT COUNT(*) FROM a", "3");
    try run("INSERT INTO a (id, val) VALUES (4, 4)");
    try expect("SELECT id, val, w FROM a ORDER BY id", "1|10|20;2|25|50;3|30|60;4|4|8");
    try expect("SELECT generation_expression FROM information_schema.columns WHERE table_name = 'a' AND column_name = 'w'", "(val * 2)");
    try sameState(&.{ "SELECT id, val, w FROM a ORDER BY id", alter_probes[4] });
    // Dropping a column used by a generated column is 2BP01; dropping a
    // column drops the constraints over it.
    try rejects("ALTER TABLE a DROP COLUMN val", error.DependentObjects, "SELECT COUNT(*) FROM a", "4");
    try run("ALTER TABLE a DROP COLUMN w");
    try run("ALTER TABLE a DROP COLUMN val");
    try expect(alter_probes[4], "a_pkey|PRIMARY KEY");
    try expect("SELECT * FROM a ORDER BY id", "1;2;3;4");
    // DROP CONSTRAINT, IF EXISTS, 42704.
    try run("ALTER TABLE a ADD COLUMN q INT CHECK (q < 5) UNIQUE");
    try expect("SELECT constraint_name FROM information_schema.table_constraints WHERE table_name = 'a' AND constraint_type <> 'PRIMARY KEY' AND constraint_name LIKE 'a_q%' ORDER BY constraint_name", "a_q_check;a_q_key");
    try rejects("UPDATE a SET q = 9", error.CheckViolation, "SELECT COUNT(*) FROM a WHERE q IS NULL", "4");
    try run("ALTER TABLE a DROP CONSTRAINT a_q_check");
    try run("UPDATE a SET q = 9 WHERE id = 1");
    try rejects("UPDATE a SET q = 9 WHERE id = 2", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM a WHERE q IS NULL", "3");
    try rejects("ALTER TABLE a DROP CONSTRAINT nothing_here", error.UndefinedObject, "SELECT COUNT(*) FROM a", "4");
    try run("ALTER TABLE a DROP CONSTRAINT IF EXISTS nothing_here");
    // Dropping the primary key frees the key.
    try run("ALTER TABLE a DROP CONSTRAINT a_pkey");
    try run("INSERT INTO a VALUES (1, NULL)");
    try expect("SELECT COUNT(*) FROM a WHERE id = 1", "2");
    try sameState(&.{ "SELECT * FROM a ORDER BY id, q", "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid", "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 'a' ORDER BY constraint_name" });
}

fn alterErrors() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO a VALUES (1, 1)");
    try run("CREATE SEQUENCE s");
    try run("CREATE TABLE ident (id INT GENERATED ALWAYS AS IDENTITY, x INT, y INT)");
    const probe = "SELECT column_name FROM information_schema.columns WHERE table_name = 'a' ORDER BY ordinal_position";
    try rejects("ALTER TABLE missing ADD COLUMN x INT", error.TableNotFound, probe, "id;v");
    try run("ALTER TABLE IF EXISTS missing ADD COLUMN x INT");
    try rejects("ALTER TABLE s ADD COLUMN x INT", error.WrongObjectType, probe, "id;v");
    try rejects("ALTER TABLE a ADD COLUMN v INT", error.DuplicateColumn, probe, "id;v");
    try rejects("ALTER TABLE a DROP COLUMN nope", error.ColumnNotFound, probe, "id;v");
    try run("ALTER TABLE a DROP COLUMN IF EXISTS nope");
    try rejects("ALTER TABLE a RENAME COLUMN nope TO x", error.ColumnNotFound, probe, "id;v");
    try rejects("ALTER TABLE a RENAME COLUMN v TO id", error.DuplicateColumn, probe, "id;v");
    try rejects("ALTER TABLE a RENAME TO s", error.TableExists, probe, "id;v");
    // A failing later action leaves nothing of the earlier ones.
    try rejects("ALTER TABLE a ADD COLUMN x INT, DROP COLUMN nope", error.ColumnNotFound, probe, "id;v");
    try rejects("ALTER TABLE a ADD COLUMN x INT DEFAULT nextval('s')", error.UnsupportedStatement, probe, "id;v");
    try rejects("ALTER TABLE a ADD COLUMN x INT PRIMARY KEY", error.UnsupportedStatement, probe, "id;v");
    try rejects("ALTER TABLE a ALTER COLUMN v TYPE BIGINT", error.UnsupportedStatement, probe, "id;v");
    try rejects("ALTER TABLE a ADD COLUMN x INT DEFAULT 'text'", error.InvalidTextRepresentation, probe, "id;v");
    try rejects("ALTER TABLE ident DROP COLUMN id", error.UnsupportedStatement, "SELECT COUNT(*) FROM ident", "0");
    try rejects("ALTER TABLE ident ALTER COLUMN id SET DEFAULT 1", error.Syntax, "SELECT COUNT(*) FROM ident", "0");
    // An identity column after the dropped one keeps its position: refused.
    try run("ALTER TABLE ident DROP COLUMN y");
    try run("INSERT INTO ident (x) VALUES (5)");
    try expect("SELECT id, x FROM ident", "1|5");
    try sameState(&.{ "SELECT id, x FROM ident", probe });
}

fn alterTransactions() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO a VALUES (1, 10), (2, 20)");
    // Abort restores the old definition and rows, including own rows.
    var tx = try db.begin();
    try statement(tx, "INSERT INTO a VALUES (3, 30)");
    try statement(tx, "ALTER TABLE a ADD COLUMN extra INT DEFAULT 5");
    try statement(tx, "UPDATE a SET extra = id WHERE id = 3");
    try same(try rows(tx, "SELECT * FROM a ORDER BY id"), "1|10|5;2|20|5;3|30|3");
    db.abort(tx);
    try expect("SELECT * FROM a ORDER BY id", "1|10;2|20");
    try check(db.usage().pending_versions == 0);
    // ROLLBACK TO a savepoint between two ALTERs.
    tx = try db.begin();
    try statement(tx, "ALTER TABLE a ADD COLUMN one INT DEFAULT 1");
    try db.savepoint(tx, "s");
    try statement(tx, "ALTER TABLE a DROP COLUMN v");
    try statement(tx, "INSERT INTO a VALUES (9, 9)");
    _ = try db.rollbackTo(tx, "s");
    try same(try rows(tx, "SELECT * FROM a ORDER BY id"), "1|10|1;2|20|1");
    try statement(tx, "INSERT INTO a VALUES (3, 30, 3)");
    try commit(tx);
    try expect("SELECT * FROM a ORDER BY id", "1|10|1;2|20|1;3|30|3");
    try sameState(&alter_probes);
    // CREATE, rows, TRUNCATE and ALTER in one transaction replay in order.
    tx = try db.begin();
    try statement(tx, "CREATE TABLE fresh (k INT PRIMARY KEY, a INT, b INT)");
    try statement(tx, "INSERT INTO fresh VALUES (1, 1, 1)");
    try statement(tx, "ALTER TABLE fresh DROP COLUMN a");
    try statement(tx, "INSERT INTO fresh VALUES (2, 2)");
    try statement(tx, "ALTER TABLE fresh ADD COLUMN c TEXT DEFAULT 'c'");
    try statement(tx, "INSERT INTO fresh VALUES (3, 3, 'x')");
    try statement(tx, "TRUNCATE a");
    try statement(tx, "ALTER TABLE a ADD COLUMN z INT DEFAULT 0");
    try statement(tx, "INSERT INTO a VALUES (5, 50, 5, 5)");
    try commit(tx);
    try expect("SELECT * FROM fresh ORDER BY k", "1|1|c;2|2|c;3|3|x");
    try expect("SELECT * FROM a ORDER BY id", "5|50|5|5");
    try sameState(&.{ "SELECT * FROM fresh ORDER BY k", "SELECT * FROM a ORDER BY id", "SELECT COUNT(*), SUM(k) FROM fresh", alter_probes[3], alter_probes[5] });
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0);
    // The old slot is reclaimed after commit: repeated ALTERs do not run
    // out of table slots.
    for (0..12) |_| {
        try run("ALTER TABLE fresh ADD COLUMN t INT DEFAULT 1");
        try run("ALTER TABLE fresh DROP COLUMN t");
    }
    try sameState(&.{ "SELECT * FROM fresh ORDER BY k", "SELECT COUNT(*) FROM pg_class" });
}

fn alterIsolation() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO a VALUES (1, 10)");
    // An uncommitted ALTER is invisible: readers wait for its lock, and
    // the committed catalog keeps the old definition and rows.
    const alterer = try db.begin();
    try statement(alterer, "ALTER TABLE a ADD COLUMN extra INT DEFAULT 3");
    const reader = try db.begin();
    try parks(reader, "SELECT * FROM a");
    try check(db.waitingFor(reader).has(alterer));
    try check(db.storageStats("a").?.live_rows == 1);
    var described: DB.Result = .{};
    try db.describe("SELECT * FROM a", &described);
    try check(described.column_count == 2);
    try commit(alterer);
    try same(try resumed(reader, "SELECT * FROM a"), "1|10|3");
    try commit(reader);
    // A reader's AccessShare lock makes ALTER wait.
    const holder = try db.begin();
    try same(try rows(holder, "SELECT COUNT(*) FROM a"), "1");
    const second = try db.begin();
    try parks(second, "ALTER TABLE a DROP COLUMN v");
    try check(db.waitingFor(second).has(holder));
    try commit(holder);
    _ = try resumed(second, "ALTER TABLE a DROP COLUMN v");
    try commit(second);
    try expect("SELECT * FROM a", "1|3");
    try sameState(&alter_probes);
    try check(db.usage().transactions == 0 and db.usage().table_locks == 0);
}

// ---- sequences: SERIAL, CACHE, ALTER SEQUENCE ----------------------------------

const sequence_probes = [_][]const u8{
    "SELECT relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY relname",
    "SELECT seqtypid, seqstart, seqincrement, seqmax, seqmin, seqcache, seqcycle FROM pg_sequence ORDER BY seqrelid",
    "SELECT table_name, column_name, column_default, is_nullable, data_type FROM information_schema.columns WHERE column_default IS NOT NULL ORDER BY table_name, ordinal_position",
};

fn int(target: *DB, source: []const u8) !i64 {
    var result: DB.Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return result.rows[0].cells[0].integer;
}

fn serialColumns() !void {
    reset();
    try run("CREATE TABLE tdd_serial (id SERIAL PRIMARY KEY, label TEXT)");
    try run("INSERT INTO tdd_serial (label) VALUES ('a'), ('b')");
    try run("INSERT INTO tdd_serial VALUES (10, 'explicit')");
    try run("INSERT INTO tdd_serial (label) VALUES ('c')");
    try expect("SELECT id, label FROM tdd_serial ORDER BY id", "1|a;2|b;3|c;10|explicit");
    try expect(sequence_probes[0], "tdd_serial|r;tdd_serial_id_seq|S;tdd_serial_pkey|i");
    try expect(sequence_probes[2], "tdd_serial|id|nextval('tdd_serial_id_seq'::regclass)|NO|integer");
    try expect(sequence_probes[1], "23|1|1|2147483647|1|1|f");
    try run("CREATE TABLE big (b BIGSERIAL, s SMALLSERIAL, x SERIAL4)");
    try run("INSERT INTO big DEFAULT VALUES");
    try expect("SELECT b, s, x FROM big", "1|1|1");
    try expect("SELECT data_type FROM information_schema.columns WHERE table_name = 'big' ORDER BY ordinal_position", "bigint;smallint;integer");
    try expect("SELECT seqtypid, seqmax FROM pg_sequence WHERE seqrelid = 'big_s_seq'::regclass", "21|32767");
    // A taken name gets a number (ChooseRelationName).
    try run("CREATE SEQUENCE clash_id_seq");
    try run("CREATE TABLE clash (id SERIAL)");
    try expect("SELECT column_default FROM information_schema.columns WHERE table_name = 'clash'", "nextval('clash_id_seq1'::regclass)");
    try rejects("CREATE TABLE bad (id SERIAL DEFAULT 1)", error.Syntax, sequence_probes[0], "big|r;big_b_seq|S;big_s_seq|S;big_x_seq|S;clash|r;clash_id_seq|S;clash_id_seq1|S;tdd_serial|r;tdd_serial_id_seq|S;tdd_serial_pkey|i");
    try rejects("DROP SEQUENCE tdd_serial_id_seq", error.DependentObjects, "SELECT COUNT(*) FROM tdd_serial", "4");
    try rejects("INSERT INTO tdd_serial (id) VALUES (NULL)", error.NotNullViolation, "SELECT COUNT(*) FROM tdd_serial", "4");
    try sameState(&sequence_probes);
    try sameState(&.{"SELECT id, label FROM tdd_serial ORDER BY id"});
    // The replica continues beyond every value the primary handed out.
    try check(try int(&replica, "SELECT nextval('tdd_serial_id_seq')") > 3);
    try run("DROP TABLE tdd_serial");
    try expect("SELECT COUNT(*) FROM pg_class WHERE relname = 'tdd_serial_id_seq'", "0");
    try sameState(&sequence_probes);
}

var session_a: DB.SequenceSession = .{};
var session_b: DB.SequenceSession = .{};

/// A replicated statement in one session (Store.Connection installs each
/// connection's own sequence state the same way).
fn sessionValue(session: *DB.SequenceSession, source: []const u8) !i64 {
    db.sequence_session = session;
    defer db.sequence_session = null;
    const result = try replicate(source);
    return result.rows[0].cells[0].integer;
}

/// The primary's value from a replicated statement.
fn primaryValue(source: []const u8) !i64 {
    const result = try replicate(source);
    return result.rows[0].cells[0].integer;
}

fn sequenceCache() !void {
    reset();
    session_a = .{};
    session_b = .{};
    try run("CREATE SEQUENCE tdd_seq CACHE 4");
    try expect("SELECT seqcache FROM pg_sequence", "4");
    // PostgreSQL: each session preallocates CACHE values.
    try check(try sessionValue(&session_a, "SELECT nextval('tdd_seq')") == 1);
    try check(try sessionValue(&session_b, "SELECT nextval('tdd_seq')") == 5);
    try check(try sessionValue(&session_a, "SELECT nextval('tdd_seq')") == 2);
    try check(try sessionValue(&session_b, "SELECT nextval('tdd_seq')") == 6);
    try check(try sessionValue(&session_a, "SELECT nextval('tdd_seq')") == 3);
    try check(try sessionValue(&session_a, "SELECT nextval('tdd_seq')") == 4);
    try check(try sessionValue(&session_a, "SELECT nextval('tdd_seq')") == 9);
    try check(try sessionValue(&session_a, "SELECT currval('tdd_seq')") == 9);
    // setval forgets the session's preallocated values.
    try check(try sessionValue(&session_b, "SELECT setval('tdd_seq', 100)") == 100);
    try check(try sessionValue(&session_b, "SELECT nextval('tdd_seq')") == 101);
    try check(try sessionValue(&session_a, "SELECT nextval('tdd_seq')") == 10);
    // Durable watermark: the replica starts beyond every fetched value.
    _ = try replicate("SELECT nextval('tdd_seq')");
    try check(try int(&replica, "SELECT nextval('tdd_seq')") > 104);
    try rejects("CREATE SEQUENCE bad CACHE 0", error.InvalidParameterValue, "SELECT COUNT(*) FROM pg_sequence", "1");
    try sameState(&sequence_probes);
    // A cached identity sequence.
    try run("CREATE TABLE ci (id INT GENERATED ALWAYS AS IDENTITY (CACHE 3), v INT)");
    try run("INSERT INTO ci (v) VALUES (1), (2)");
    try expect("SELECT id FROM ci ORDER BY id", "1;2");
    try sameState(&.{ "SELECT id, v FROM ci ORDER BY id", sequence_probes[1] });
}

fn alterSequences() !void {
    reset();
    try run("CREATE TABLE tdd_serial (id SERIAL PRIMARY KEY)");
    try run("CREATE SEQUENCE tdd_seq CACHE 4");
    const altered = try replicate("ALTER SEQUENCE tdd_seq RESTART WITH 9");
    try check(altered.command == .alter_sequence);
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 9);
    try run("ALTER SEQUENCE tdd_seq INCREMENT BY 5 CACHE 1 MAXVALUE 40 NO CYCLE");
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 17);
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 22);
    try expect("SELECT seqstart, seqincrement, seqmax, seqcache, seqcycle FROM pg_sequence WHERE seqrelid = 'tdd_seq'::regclass", "1|5|40|1|f");
    try run("ALTER SEQUENCE tdd_seq RESTART");
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 1);
    try run("ALTER SEQUENCE tdd_seq START WITH 3 RESTART CYCLE");
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 3);
    try run("ALTER SEQUENCE IF EXISTS missing RESTART");
    // 22023 when the current value leaves the new bounds; 42P01, 42809,
    // 0A000 for OWNED BY / RENAME; nothing changes.
    try run("ALTER SEQUENCE tdd_seq RESTART WITH 30");
    try rejects("ALTER SEQUENCE tdd_seq MAXVALUE 20", error.InvalidParameterValue, "SELECT seqmax FROM pg_sequence WHERE seqrelid = 'tdd_seq'::regclass", "40");
    try rejects("ALTER SEQUENCE tdd_seq RESTART WITH 41", error.InvalidParameterValue, "SELECT seqmax FROM pg_sequence WHERE seqrelid = 'tdd_seq'::regclass", "40");
    try rejects("ALTER SEQUENCE missing RESTART", error.TableNotFound, "SELECT COUNT(*) FROM pg_sequence", "2");
    try rejects("ALTER SEQUENCE tdd_serial RESTART", error.WrongObjectType, "SELECT COUNT(*) FROM pg_sequence", "2");
    try rejects("ALTER SEQUENCE tdd_seq OWNED BY NONE", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_sequence", "2");
    try rejects("ALTER SEQUENCE tdd_seq INCREMENT BY 0", error.InvalidParameterValue, "SELECT seqincrement FROM pg_sequence WHERE seqrelid = 'tdd_seq'::regclass", "5");
    try sameState(&sequence_probes);
    try check(try int(&replica, "SELECT nextval('tdd_seq')") == 30);
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 30);
    // Transactional: abort and ROLLBACK TO restore the previous sequence.
    var tx = try db.begin();
    try statement(tx, "ALTER SEQUENCE tdd_seq RESTART WITH 2");
    try same(try rows(tx, "SELECT nextval('tdd_seq')"), "2");
    db.abort(tx);
    try check(try primaryValue("SELECT nextval('tdd_seq')") == 35);
    tx = try db.begin();
    try db.savepoint(tx, "s");
    try statement(tx, "ALTER SEQUENCE tdd_seq INCREMENT BY -1");
    _ = try db.rollbackTo(tx, "s");
    try same(try rows(tx, "SELECT nextval('tdd_seq')"), "40");
    try commit(tx);
    // Another session's nextval waits for an uncommitted ALTER SEQUENCE.
    const alterer = try db.begin();
    try statement(alterer, "ALTER SEQUENCE tdd_seq RESTART WITH 7 INCREMENT BY 1 MAXVALUE 100");
    const consumer = try db.begin();
    try parks(consumer, "SELECT nextval('tdd_seq')");
    try check(db.waitingFor(consumer).has(alterer));
    try commit(alterer);
    try same(try resumed(consumer, "SELECT nextval('tdd_seq')"), "7");
    try commit(consumer);
    try sameState(&sequence_probes);
    // An identity sequence, and TRUNCATE ... RESTART IDENTITY.
    try run("CREATE TABLE ident (id INT GENERATED ALWAYS AS IDENTITY, v INT)");
    try run("INSERT INTO ident (v) VALUES (1), (2), (3)");
    try run("ALTER SEQUENCE ident_id_seq RESTART WITH 50");
    try run("INSERT INTO ident (v) VALUES (4)");
    try expect("SELECT id FROM ident ORDER BY id", "1;2;3;50");
    tx = try db.begin();
    try statement(tx, "TRUNCATE ident RESTART IDENTITY");
    try statement(tx, "INSERT INTO ident (v) VALUES (5)");
    try same(try rows(tx, "SELECT id, v FROM ident"), "1|5");
    db.abort(tx);
    try run("INSERT INTO ident (v) VALUES (6)");
    try expect("SELECT id FROM ident ORDER BY id", "1;2;3;50;51");
    try run("TRUNCATE ident, tdd_serial RESTART IDENTITY");
    try run("INSERT INTO ident (v) VALUES (7)");
    try run("INSERT INTO tdd_serial DEFAULT VALUES");
    try expect("SELECT id, v FROM ident", "1|7");
    try expect("SELECT id FROM tdd_serial", "1");
    try sameState(&sequence_probes);
    try sameState(&.{ "SELECT id, v FROM ident", "SELECT id FROM tdd_serial" });
    try check(try int(&replica, "SELECT nextval('ident_id_seq')") > 1);
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0);
}

// ---- UPDATE ... FROM, DELETE ... USING, tuple assignment ----------------------

const join_probes = [_][]const u8{
    "SELECT id, g, v FROM tdd_a ORDER BY id",
    "SELECT id, v FROM tdd_b ORDER BY id",
};

fn joinFixture() !void {
    reset();
    try run("CREATE TABLE tdd_a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO tdd_a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    try run("CREATE TABLE tdd_b (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO tdd_b VALUES (1, 11), (3, 33), (5, 55)");
}

fn updateFrom() !void {
    try joinFixture();
    const result = try replicate("UPDATE tdd_a a SET v = b.v FROM tdd_b b WHERE a.id = b.id");
    try check(result.command == .update and result.affected_rows == 2);
    try expect(join_probes[0], "1|1|11;2|1|20;3|2|33;4|2|NULL");
    try sameState(&join_probes);
    // A target row joined to several source rows is updated once.
    try run("CREATE TABLE m (id INT, w INT)");
    try run("INSERT INTO m VALUES (1, 100), (1, 200), (9, 900)");
    const once = try replicate("UPDATE tdd_a SET v = m.w FROM m WHERE tdd_a.id = m.id");
    try check(once.affected_rows == 1);
    try expect("SELECT COUNT(*) FROM tdd_a WHERE id = 1 AND v IN (100, 200)", "1");
    // Several items, a derived table, an unmatched join, AS aliases.
    try run("UPDATE tdd_a AS t SET g = b.v + m.w FROM tdd_b AS b, m WHERE t.id = b.id AND m.id = 9");
    try expect(join_probes[0] ++ "", "1|911|100;2|1|20;3|933|33;4|2|NULL");
    try run("UPDATE tdd_a SET v = s.dv FROM (SELECT id, v * 2 AS dv FROM tdd_b) AS s WHERE tdd_a.id = s.id");
    try expect(join_probes[0], "1|911|22;2|1|20;3|933|66;4|2|NULL");
    const none_matched = try replicate("UPDATE tdd_a SET v = 0 FROM tdd_b WHERE tdd_a.id = tdd_b.id AND tdd_b.v > 1000");
    try check(none_matched.affected_rows == 0);
    try same(try render(&(try replicate("UPDATE tdd_a a SET v = b.v FROM tdd_b b WHERE a.id = b.id AND b.id = 3 RETURNING a.id, a.v"))), "3|33");
    try sameState(&join_probes);
    // 42702 for an unqualified name of both, 42P01 / 42703 for bad names,
    // constraint failures leave nothing.
    try rejects("UPDATE tdd_a SET g = v FROM tdd_b WHERE tdd_a.id = tdd_b.id", error.AmbiguousColumn, join_probes[0], "1|911|22;2|1|20;3|933|33;4|2|NULL");
    try rejects("UPDATE tdd_a SET g = 1 FROM missing WHERE true", error.TableNotFound, join_probes[0], "1|911|22;2|1|20;3|933|33;4|2|NULL");
    try rejects("UPDATE tdd_a SET g = b.nope FROM tdd_b b", error.ColumnNotFound, join_probes[0], "1|911|22;2|1|20;3|933|33;4|2|NULL");
    try run("CREATE TABLE ck (id INT PRIMARY KEY, v INT CHECK (v < 50))");
    try run("INSERT INTO ck VALUES (1, 1), (3, 3)");
    try rejects("UPDATE ck SET v = b.v * 2 FROM tdd_b b WHERE ck.id = b.id", error.CheckViolation, "SELECT id, v FROM ck ORDER BY id", "1|1;3|3");
    try rejects("UPDATE ck SET id = b.id + 2 FROM tdd_b b WHERE ck.id = b.id", error.PrimaryKeyViolation, "SELECT id, v FROM ck ORDER BY id", "1|1;3|3");
    try sameState(&join_probes);
}

fn updateFromConcurrency() !void {
    try joinFixture();
    // A concurrent update of a target row: the joined update waits, then
    // re-checks the join on the newest version (EvalPlanQual).
    const writer = try db.begin();
    try statement(writer, "UPDATE tdd_a SET g = 7 WHERE id = 1");
    const joiner = try db.begin();
    try parks(joiner, "UPDATE tdd_a a SET v = b.v FROM tdd_b b WHERE a.id = b.id");
    try commit(writer);
    _ = try resumed(joiner, "UPDATE tdd_a a SET v = b.v FROM tdd_b b WHERE a.id = b.id");
    try commit(joiner);
    try expect(join_probes[0], "1|7|11;2|1|20;3|2|33;4|2|NULL");
    // The FROM table is read under AccessShare: TRUNCATE of it waits.
    const reader = try db.begin();
    try statement(reader, "UPDATE tdd_a a SET g = 0 FROM tdd_b b WHERE a.id = b.id");
    const truncator = try db.begin();
    try parks(truncator, "TRUNCATE tdd_b");
    try check(db.waitingFor(truncator).has(reader));
    db.abort(reader);
    _ = try resumed(truncator, "TRUNCATE tdd_b");
    db.abort(truncator);
    try sameState(&join_probes);
    try check(db.usage().transactions == 0 and db.usage().table_locks == 0);
}

pub fn main(init: std.process.Init) !void {
    try truncateTable();
    try truncateErrors();
    try truncateTransactions();
    try truncateLocks();
    try checkConstraints();
    try uniqueConstraints();
    try compositeKeys();
    try alterValues();
    try alterConstraints();
    try alterErrors();
    try alterTransactions();
    try alterIsolation();
    try serialColumns();
    try sequenceCache();
    try alterSequences();
    try updateFrom();
    try updateFromConcurrency();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-ddl-core\",\"pass\":true,\"assertions\":{d},\"records\":{d},\"database_bytes\":{d}}}\n", .{ assertions, records_applied, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
