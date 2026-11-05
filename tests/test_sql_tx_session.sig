//! Transaction and session contracts (conformance lane B11, tx-session):
//! isolation levels (READ COMMITTED, REPEATABLE READ, SERIALIZABLE), READ
//! ONLY / DEFERRABLE and their 25001 check hooks, engine settings (SET /
//! SET LOCAL / SHOW / RESET, search_path, default_transaction_*,
//! placeholders, current_setting / set_config), cursors (DECLARE / FETCH /
//! MOVE / CLOSE, SCROLL, WITH HOLD), SQL PREPARE / EXECUTE / DEALLOCATE,
//! LOCK TABLE modes and NOWAIT, row-lock strengths and OF, advisory locks,
//! LISTEN / NOTIFY / UNLISTEN through two store connections and the
//! PostgreSQL wire (NotificationResponse), capacities (54000) and replay of
//! RR / SERIALIZABLE commits on a replica.
//!
//! Fixtures copied from tests/sql_conformance/postgres18_oracle.json are
//! marked "oracle". Every other expectation is derived from the PostgreSQL
//! 18 documentation and source and is PENDING NATIVE VERIFICATION.
//! Concurrency runs as interleaved transactions (engine slots or store
//! connections) on one database. The assertion counter proves the suite ran.
const std = @import("std");
const sql = @import("sql");
const store_module = @import("db_store");
const pg = @import("postgres");

const DB = sql.Database(.{ .tables = 8, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 6, .sequences = 4, .expr_nodes = 1024, .work_rows = 64, .result_rows = 32 });
const Small = sql.Database(.{ .tables = 2, .columns = 2, .rows_per_table = 8, .text_bytes = 32, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .result_rows = 8, .cursors = 1, .cursor_rows = 4, .notify_queue = 2, .notify_pending = 2, .listeners = 2, .serializable_transactions = 1, .prepared_statements = 1, .custom_settings = 1, .advisory_locks = 1, .setting_snapshots = 1 });
const Store = store_module.Store(DB);
const Session = pg.Session(Store.Connection);

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var result: DB.Result = .{};
var small: Small = .{};
var small_result: Small.Result = .{};
var session_a: DB.SessionState = .{};
var session_b: DB.SessionState = .{};
var store: Store = .{};
var wire: Session = .{};
var wire_output: [Session.responseCapacity()]u8 = undefined;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("tx-session contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.TxSessionContractFailed;
    }
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

var text_buffer: [8192]u8 = undefined;
/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
fn render(target: anytype) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
    for (0..target.row_count) |row| {
        if (row != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

var meta_buffer: [512]u8 = undefined;
/// Column metadata as `name:oid:typmod,...`.
fn meta(target: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    for (0..target.column_count) |column| {
        const piece = try std.fmt.bufPrint(meta_buffer[at..], "{s}{s}:{d}:{d}", .{ if (column == 0) "" else ",", target.column_names[column].slice(), sql.typeOid(target.column_types[column]), target.column_typmods[column] });
        at += piece.len;
    }
    return meta_buffer[0..at];
}

fn run(slot: u16, source: []const u8) ![]const u8 {
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s} (assertion {d})\n", .{ source, @errorName(err), assertions });
        return err;
    };
    return render(&result);
}

fn expect(slot: u16, source: []const u8, wanted: []const u8) !void {
    const got = try run(slot, source);
    if (!same(got, wanted)) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ source, got, wanted });
    try check(same(got, wanted));
}

fn expectMeta(slot: u16, source: []const u8, rows: []const u8, columns: []const u8) !void {
    try expect(slot, source, rows);
    const got = try meta(&result);
    if (!same(got, columns)) std.debug.print("{s}\n  meta {s}\n  want {s}\n", .{ source, got, columns });
    try check(same(got, columns));
}

/// The statement fails with `wanted` and leaves the result untouched.
fn fails(slot: u16, source: []const u8, wanted: anyerror) !void {
    result.row_count = 7;
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(result.row_count == 7);
    result.row_count = 0;
}

fn blocks(slot: u16, source: []const u8) !void {
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("did not block: {s}\n", .{source});
        return error.ExpectedBlock;
    } else |err| try check(err == error.WouldBlock);
    try check(db.parked(slot));
}

fn resumed(slot: u16, source: []const u8) ![]const u8 {
    try db.statement(slot, source, &result, .{ .@"resume" = true });
    return render(&result);
}

fn resumeFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    if (db.statement(slot, source, &result, .{ .@"resume" = true })) |_| return error.InvalidStatementAccepted else |err| {
        if (err != wanted) std.debug.print("resume {s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

/// Store.commit order: deferred checks (and SERIALIZABLE), record, replay,
/// publication.
fn commit(slot: u16) !void {
    try db.deferredViolation(slot);
    if (!db.readOnly(slot)) {
        const payload = try db.prepareCommit(slot, &record);
        try replica.applyChangeRecord(payload, &scratch);
    }
    db.publishCommit(slot);
}

fn commitFails(slot: u16, wanted: anyerror) !void {
    if (db.deferredViolation(slot)) |_| return error.CommitAccepted else |err| try check(err == wanted);
    db.abort(slot);
}

fn autocommit(source: []const u8) !void {
    const slot = try db.begin();
    _ = run(slot, source) catch |err| {
        db.abort(slot);
        return err;
    };
    try commit(slot);
}

fn fixture() !void {
    db = .{};
    replica = .{};
    db.session_state = null;
    for ([_][]const u8{
        "CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)",
        "INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)",
        "CREATE TABLE tdd_b(id INT PRIMARY KEY,v INT)",
        "INSERT INTO tdd_b VALUES(1,11),(3,33),(5,55)",
    }) |source| try autocommit(source);
}

/// Every probe answers identically on the primary and the replica.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const slot = try db.begin();
        const left = try run(slot, probe);
        var copy: [8192]u8 = undefined;
        @memcpy(copy[0..left.len], left);
        db.abort(slot);
        const other = try replica.begin();
        try replica.statement(other, probe, &result, .{});
        replica.abort(other);
        const right = try render(&result);
        if (!same(copy[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy[0..left.len], right });
        try check(same(copy[0..left.len], right));
    }
}

// ---- oracle programs (one transaction each, as the driver runs them) -----

fn oraclePrograms() !void {
    // oracle PG.TX.ISOLATION
    db = .{};
    var tx = try db.begin();
    try expectMeta(tx, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "", "");
    try expectMeta(tx, "SHOW transaction_isolation", "serializable", "transaction_isolation:25:-1");
    db.abort(tx);
    // oracle PG.TX.CHARACTERISTICS
    tx = try db.begin();
    try expectMeta(tx, "SET TRANSACTION READ ONLY", "", "");
    try expectMeta(tx, "SHOW transaction_read_only", "on", "transaction_read_only:25:-1");
    db.abort(tx);
    try fixture();
    // oracle PG.TX.LOCK_MODES
    tx = try db.begin();
    try expectMeta(tx, "SELECT id FROM tdd_a FOR NO KEY UPDATE OF tdd_a", "1;2;3;4", "id:23:-1");
    db.abort(tx);
    // oracle PG.TX.TABLE_LOCK
    tx = try db.begin();
    try expectMeta(tx, "LOCK TABLE tdd_a IN SHARE MODE", "", "");
    try expectMeta(tx, "SELECT pg_try_advisory_xact_lock(123)", "t", "pg_try_advisory_xact_lock:16:-1");
    db.abort(tx);
    // oracle PG.CURSOR
    tx = try db.begin();
    try expectMeta(tx, "DECLARE tdd_c SCROLL CURSOR FOR SELECT id FROM tdd_a ORDER BY id", "", "");
    try expectMeta(tx, "FETCH NEXT FROM tdd_c", "1", "id:23:-1");
    try expectMeta(tx, "MOVE BACKWARD 1 FROM tdd_c", "", "");
    try check(result.affected_rows == 0 and result.command == .move);
    try expectMeta(tx, "CLOSE tdd_c", "", "");
    db.abort(tx);
    // oracle PG.SQL_PREPARE
    tx = try db.begin();
    try expectMeta(tx, "PREPARE tdd_stmt(INT) AS SELECT $1+1", "", "");
    try expectMeta(tx, "EXECUTE tdd_stmt(2)", "3", "?column?:23:-1");
    try expectMeta(tx, "DEALLOCATE tdd_stmt", "", "");
    db.abort(tx);
    // oracle PG.SESSION.SETTINGS
    tx = try db.begin();
    try expectMeta(tx, "SET LOCAL search_path TO public", "", "");
    try expectMeta(tx, "SHOW search_path", "public", "search_path:25:-1");
    db.abort(tx);
    // oracle PG.SESSION.NOTIFY
    tx = try db.begin();
    try expectMeta(tx, "LISTEN tdd_channel", "", "");
    try expectMeta(tx, "NOTIFY tdd_channel,'x'", "", "");
    try expectMeta(tx, "UNLISTEN tdd_channel", "", "");
    db.abort(tx);
    try check(db.sessionUsage().pending_notifications == 0 and db.sessionUsage().listeners == 0);
}

// ---- transaction modes ---------------------------------------------------

fn transactionModes() !void {
    try fixture();
    var tx = try db.begin();
    try expect(tx, "SHOW transaction_isolation", "read committed");
    try expect(tx, "SHOW transaction_deferrable", "off");
    try expect(tx, "SELECT 1", "1");
    // After the first query (25001); the same level is no change.
    try fails(tx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", error.ActiveSqlTransaction);
    try expect(tx, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED", "");
    try fails(tx, "SET TRANSACTION DEFERRABLE", error.ActiveSqlTransaction);
    try expect(tx, "SET TRANSACTION READ ONLY", "");
    try fails(tx, "SET TRANSACTION READ WRITE", error.ActiveSqlTransaction);
    db.abort(tx);
    // SET, SHOW and LOCK TABLE take no snapshot.
    tx = try db.begin();
    try expect(tx, "SHOW transaction_read_only", "off");
    try expect(tx, "LOCK TABLE tdd_a IN ACCESS SHARE MODE", "");
    try expect(tx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY, DEFERRABLE", "");
    try expect(tx, "SHOW transaction_isolation", "repeatable read");
    try expect(tx, "SHOW transaction_deferrable", "on");
    try expect(tx, "SET transaction_isolation = 'read uncommitted'", "");
    try expect(tx, "SHOW TRANSACTION ISOLATION LEVEL", "read uncommitted");
    try fails(tx, "SET transaction_read_only = maybe", error.InvalidSettingValue);
    try expect(tx, "BEGIN", "");
    db.abort(tx);
    // Inside a subtransaction (25001).
    tx = try db.begin();
    try db.savepoint(tx, "s");
    try fails(tx, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", error.ActiveSqlTransaction);
    try fails(tx, "SET TRANSACTION NOT DEFERRABLE", error.ActiveSqlTransaction);
    try expect(tx, "SET TRANSACTION READ ONLY", "");
    db.abort(tx);
    // READ ONLY: 25006 before anything runs; the table is unchanged.
    try autocommit("CREATE SEQUENCE tdd_s");
    tx = try db.begin();
    try expect(tx, "SET TRANSACTION READ ONLY", "");
    try fails(tx, "INSERT INTO tdd_a VALUES(9,9,9)", error.ReadOnlyTransaction);
    try fails(tx, "UPDATE tdd_a SET v = 0 WHERE false", error.ReadOnlyTransaction);
    try fails(tx, "CREATE TABLE tdd_z(x INT)", error.ReadOnlyTransaction);
    try fails(tx, "SELECT id FROM tdd_a WHERE id = 1 FOR UPDATE", error.ReadOnlyTransaction);
    try fails(tx, "SELECT nextval('tdd_s')", error.ReadOnlyTransaction);
    try fails(tx, "WITH d AS (DELETE FROM tdd_b RETURNING id) SELECT count(*) FROM d", error.ReadOnlyTransaction);
    try fails(tx, "LOCK TABLE tdd_a IN EXCLUSIVE MODE", error.ReadOnlyTransaction);
    try expect(tx, "LOCK TABLE tdd_a IN ROW EXCLUSIVE MODE", "");
    try expect(tx, "SELECT count(*) FROM tdd_a", "4");
    try expect(tx, "NOTIFY tdd_ro", "");
    try check(db.readOnly(tx));
    db.abort(tx);
    // SET SESSION CHARACTERISTICS and default_transaction_*.
    tx = try db.begin();
    try expect(tx, "SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", "");
    try expect(tx, "SHOW default_transaction_isolation", "repeatable read");
    try expect(tx, "SHOW transaction_isolation", "read committed");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "SHOW transaction_isolation", "repeatable read");
    try expect(tx, "SHOW transaction_read_only", "on");
    try fails(tx, "SET default_transaction_isolation = 'bogus'", error.InvalidSettingValue);
    try expect(tx, "SET default_transaction_read_only = off", "");
    try expect(tx, "RESET default_transaction_isolation", "");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "SHOW transaction_isolation", "read committed");
    try expect(tx, "SHOW transaction_read_only", "off");
    try expect(tx, "SHOW default_transaction_deferrable", "off");
    db.abort(tx);
}

// ---- REPEATABLE READ / SERIALIZABLE --------------------------------------

fn isolation() !void {
    try fixture();
    // REPEATABLE READ keeps the first query's snapshot; a concurrent
    // update of the target row is 40001.
    const t1 = try db.begin();
    try expect(t1, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "");
    const t2 = try db.begin();
    try expect(t1, "SELECT v FROM tdd_a WHERE id = 1", "10");
    try expect(t2, "UPDATE tdd_a SET v = 11 WHERE id = 1", "");
    try commit(t2);
    try expect(t1, "SELECT v FROM tdd_a WHERE id = 1", "10");
    try expect(t1, "SELECT count(*) FROM tdd_a WHERE v > 10", "2");
    try fails(t1, "UPDATE tdd_a SET v = 12 WHERE id = 1", error.SerializationFailure);
    try fails(t1, "DELETE FROM tdd_a WHERE id = 1", error.SerializationFailure);
    try fails(t1, "SELECT id FROM tdd_a WHERE id = 1 FOR SHARE", error.SerializationFailure);
    // Rows nobody changed stay writable, and its own writes are visible.
    try expect(t1, "UPDATE tdd_a SET v = 21 WHERE id = 2", "");
    try expect(t1, "SELECT v FROM tdd_a WHERE id IN (1, 2) ORDER BY id", "10;21");
    try commit(t1);
    // READ COMMITTED sees each commit and re-checks the newest version.
    const t3 = try db.begin();
    const t4 = try db.begin();
    try expect(t3, "SELECT v FROM tdd_a WHERE id = 1", "11");
    try expect(t4, "UPDATE tdd_a SET v = 13 WHERE id = 1", "");
    try commit(t4);
    try expect(t3, "SELECT v FROM tdd_a WHERE id = 1", "13");
    try expect(t3, "UPDATE tdd_a SET v = v + 1 WHERE id = 1", "");
    try commit(t3);
    // The snapshot is taken by the first query, not by BEGIN.
    const t5 = try db.begin();
    try expect(t5, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "");
    try autocommit("UPDATE tdd_a SET v = 15 WHERE id = 1");
    try expect(t5, "SELECT v FROM tdd_a WHERE id = 1", "15");
    // A live writer: the update waits, then fails when the writer commits.
    const t6 = try db.begin();
    try expect(t6, "UPDATE tdd_a SET v = 31 WHERE id = 3", "");
    try blocks(t5, "UPDATE tdd_a SET v = 32 WHERE id = 3");
    try commit(t6);
    try resumeFails(t5, "UPDATE tdd_a SET v = 32 WHERE id = 3", error.SerializationFailure);
    // ... and proceeds when the writer aborts.
    const t7 = try db.begin();
    try expect(t7, "UPDATE tdd_a SET v = 41 WHERE id = 4", "");
    try blocks(t5, "UPDATE tdd_a SET v = 42 WHERE id = 4");
    db.abort(t7);
    _ = try resumed(t5, "UPDATE tdd_a SET v = 42 WHERE id = 4");
    try check(result.affected_rows == 1);
    try commit(t5);
    // A concurrent delete is 40001 too.
    const t8 = try db.begin();
    try expect(t8, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "");
    try expect(t8, "SELECT count(*) FROM tdd_b", "3");
    try autocommit("DELETE FROM tdd_b WHERE id = 5");
    try expect(t8, "SELECT count(*) FROM tdd_b", "3");
    try fails(t8, "UPDATE tdd_b SET v = 0 WHERE id = 5", error.SerializationFailure);
    db.abort(t8);
    try sameState(&.{ "SELECT id, g, v FROM tdd_a ORDER BY id", "SELECT id, v FROM tdd_b ORDER BY id" });

    // SERIALIZABLE write skew: one of the two fails with 40001 and stays
    // doomed (COMMIT fails too); the other commits.
    try fixture();
    const s1 = try db.begin();
    const s2 = try db.begin();
    try expect(s1, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s2, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s1, "SELECT count(*) FROM tdd_a WHERE g = 1", "2");
    try expect(s2, "SELECT count(*) FROM tdd_a WHERE g = 1", "2");
    try expect(s1, "UPDATE tdd_a SET g = 2 WHERE id = 1", "");
    try db.savepoint(s2, "before");
    try fails(s2, "UPDATE tdd_a SET g = 2 WHERE id = 2", error.SerializationFailure);
    _ = try db.rollbackTo(s2, "before");
    try commitFails(s2, error.SerializationFailure);
    try commit(s1);
    try check(db.sessionUsage().serializable_records == 0);
    // Disjoint tables: no rw-conflict, both commit.
    const s3 = try db.begin();
    const s4 = try db.begin();
    try expect(s3, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s4, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s3, "SELECT count(*) FROM tdd_a", "4");
    try expect(s4, "SELECT count(*) FROM tdd_b", "3");
    try expect(s3, "UPDATE tdd_a SET v = 0 WHERE id = 4", "");
    try expect(s4, "UPDATE tdd_b SET v = 0 WHERE id = 5", "");
    try commit(s3);
    try commit(s4);
    // A reader of a table a committed concurrent writer changed, which in
    // turn read what the reader writes: the second edge dooms it.
    const s5 = try db.begin();
    const s6 = try db.begin();
    try expect(s5, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s6, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s5, "SELECT count(*) FROM tdd_b", "3");
    try expect(s6, "SELECT count(*) FROM tdd_a", "4");
    try expect(s6, "UPDATE tdd_b SET v = 1 WHERE id = 1", "");
    try commit(s6);
    try fails(s5, "UPDATE tdd_a SET v = 1 WHERE id = 1", error.SerializationFailure);
    db.abort(s5);
    // READ ONLY DEFERRABLE waits for a safe snapshot, then runs untracked.
    const s7 = try db.begin();
    try expect(s7, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "");
    try expect(s7, "SELECT count(*) FROM tdd_a", "4");
    const s8 = try db.begin();
    try expect(s8, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ ONLY, DEFERRABLE", "");
    try blocks(s8, "SELECT v FROM tdd_a WHERE id = 4");
    try expect(s7, "UPDATE tdd_a SET v = 44 WHERE id = 4", "");
    try commit(s7);
    try check(same(try resumed(s8, "SELECT v FROM tdd_a WHERE id = 4"), "44"));
    try check(db.txs[s8].ssi == null);
    try commit(s8);
    try sameState(&.{ "SELECT id, g, v FROM tdd_a ORDER BY id", "SELECT id, v FROM tdd_b ORDER BY id" });

    // Capacity: one SERIALIZABLE record (54000).
    small = .{};
    const c1 = try small.begin();
    const c2 = try small.begin();
    try small.statement(c1, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", &small_result, .{});
    try small.statement(c2, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", &small_result, .{});
    try small.statement(c1, "SELECT 1", &small_result, .{});
    if (small.statement(c2, "SELECT 1", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    small.abort(c1);
    try small.statement(c2, "SELECT 1", &small_result, .{});
    small.abort(c2);
}

// ---- settings ------------------------------------------------------------

fn settings() !void {
    try fixture();
    var tx = try db.begin();
    try expect(tx, "SHOW search_path", "\"$user\", public");
    try expect(tx, "SET LOCAL search_path TO public", "");
    try expect(tx, "SHOW search_path", "public");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "SHOW search_path", "\"$user\", public");
    try expect(tx, "SET search_path TO \"$user\", PUBLIC, pg_catalog", "");
    try expect(tx, "SHOW search_path", "\"$user\", public, pg_catalog");
    try expect(tx, "SET search_path = 'public'", "");
    try expect(tx, "SHOW search_path", "public");
    // Other schemas would change name resolution here (0A000).
    try fails(tx, "SET search_path TO tdd_schema, public", error.UnsupportedStatement);
    try expect(tx, "SHOW search_path", "public");
    // Placeholders, current_setting and set_config.
    try expect(tx, "SET tdd.mode = 'fast'", "");
    try expectMeta(tx, "SHOW tdd.mode", "fast", "tdd.mode:25:-1");
    try expectMeta(tx, "SELECT current_setting('tdd.mode')", "fast", "current_setting:25:-1");
    try expect(tx, "SELECT current_setting('tdd.missing', true)", "NULL");
    try fails(tx, "SELECT current_setting('tdd.missing')", error.UndefinedSetting);
    try fails(tx, "SHOW nosuch", error.UndefinedSetting);
    try fails(tx, "SET nosuch = 1", error.UndefinedSetting);
    try expectMeta(tx, "SELECT set_config('tdd.level', '3', false)", "3", "set_config:25:-1");
    try expect(tx, "SELECT current_setting('search_path'), current_setting('transaction_isolation')", "public|read committed");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "SHOW tdd.level", "3");
    try expect(tx, "SET tdd.level = 4", "");
    db.abort(tx);
    tx = try db.begin();
    try expect(tx, "SHOW tdd.level", "3");
    try expect(tx, "SET LOCAL tdd.mode = slow", "");
    try expect(tx, "SHOW tdd.mode", "slow");
    try expect(tx, "SELECT set_config('tdd.mode', 'local', true)", "local");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "SHOW tdd.mode", "fast");
    // A failed statement undoes its set_config.
    try fails(tx, "SELECT set_config('tdd.mode', 'oops', false), 1/0", error.DivisionByZero);
    try expect(tx, "SHOW tdd.mode", "fast");
    // Savepoints: ROLLBACK TO restores, RELEASE keeps.
    try db.savepoint(tx, "s1");
    try expect(tx, "SET tdd.mode = 'sp'", "");
    _ = try db.rollbackTo(tx, "s1");
    try expect(tx, "SHOW tdd.mode", "fast");
    try expect(tx, "SET tdd.mode = 'kept'", "");
    _ = try db.release(tx, "s1");
    try expect(tx, "SHOW tdd.mode", "kept");
    // An error in a block reverts to the innermost savepoint.
    try db.savepoint(tx, "s2");
    try expect(tx, "SET tdd.mode = 'doomed'", "");
    db.failScope(tx);
    try expect(tx, "SHOW tdd.mode", "kept");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "SHOW tdd.mode", "kept");
    try expect(tx, "RESET tdd.mode", "");
    try expect(tx, "SHOW tdd.mode", "");
    try expect(tx, "RESET ALL", "");
    try expect(tx, "SHOW search_path", "\"$user\", public");
    try fails(tx, "SET TIME ZONE 'UTC'", error.UnsupportedStatement);
    db.abort(tx);
    // Capacities: one placeholder, one savepoint level with settings.
    small = .{};
    const c = try small.begin();
    try small.statement(c, "SET a.one = 1", &small_result, .{});
    if (small.statement(c, "SET a.two = 2", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    try small.savepoint(c, "x");
    try small.statement(c, "SET a.one = 3", &small_result, .{});
    try small.savepoint(c, "y");
    if (small.statement(c, "SET a.one = 4", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    try small.statement(c, "SHOW a.one", &small_result, .{});
    try check(same(small_result.rows[0].cells[0].text.slice(), "3"));
    small.abort(c);
}

// ---- cursors -------------------------------------------------------------

fn cursors() !void {
    try fixture();
    var tx = try db.begin();
    try expect(tx, "DECLARE c SCROLL CURSOR FOR SELECT id, v FROM tdd_a ORDER BY id", "");
    try check(result.command == .declare_cursor);
    try expectMeta(tx, "FETCH NEXT FROM c", "1|10", "id:23:-1,v:23:-1");
    try check(result.command == .fetch);
    try expect(tx, "FETCH FORWARD 2 FROM c", "2|20;3|30");
    try expect(tx, "FETCH PRIOR FROM c", "2|20");
    try expect(tx, "FETCH LAST IN c", "4|NULL");
    try expectMeta(tx, "FETCH c", "", "id:23:-1,v:23:-1");
    try expect(tx, "FETCH BACKWARD 2 FROM c", "4|NULL;3|30");
    try expect(tx, "FETCH ABSOLUTE -2 FROM c", "3|30");
    try expect(tx, "FETCH RELATIVE -1 FROM c", "2|20");
    try expect(tx, "FETCH RELATIVE 0 FROM c", "2|20");
    try expect(tx, "FETCH FIRST FROM c", "1|10");
    try expect(tx, "FETCH ABSOLUTE 0 FROM c", "");
    try expect(tx, "FETCH ALL FROM c", "1|10;2|20;3|30;4|NULL");
    try expect(tx, "MOVE BACKWARD ALL FROM c", "");
    try check(result.affected_rows == 4 and result.command == .move);
    try expect(tx, "FETCH ABSOLUTE 9 FROM c", "");
    try expect(tx, "MOVE ABSOLUTE 2 FROM c", "");
    try check(result.affected_rows == 1);
    try expect(tx, "FETCH 1 FROM c", "3|30");
    try expect(tx, "FETCH -1 FROM c", "2|20");
    try expect(tx, "FETCH BACKWARD ALL FROM c", "1|10");
    try expect(tx, "FETCH FORWARD 0 FROM c", "");
    // Snapshot of DECLARE: later writes are not seen.
    try expect(tx, "DECLARE later CURSOR FOR SELECT count(*) FROM tdd_b", "");
    try expect(tx, "INSERT INTO tdd_b VALUES(7, 77)", "");
    try expect(tx, "FETCH ALL FROM later", "3");
    // Errors leave everything as it was.
    try fails(tx, "DECLARE c CURSOR FOR SELECT 1", error.DuplicatePortal);
    try fails(tx, "FETCH NEXT FROM nosuch", error.PortalNotFound);
    try fails(tx, "DECLARE b BINARY CURSOR FOR SELECT 1", error.UnsupportedStatement);
    try fails(tx, "DECLARE u SCROLL CURSOR FOR SELECT id FROM tdd_a FOR UPDATE", error.UnsupportedStatement);
    try fails(tx, "DECLARE m CURSOR FOR SELECT id FROM missing", error.TableNotFound);
    try expect(tx, "DECLARE n NO SCROLL CURSOR FOR SELECT id FROM tdd_a ORDER BY id", "");
    try expect(tx, "FETCH NEXT FROM n", "1");
    try fails(tx, "FETCH PRIOR FROM n", error.ObjectNotInPrerequisiteState);
    try fails(tx, "FETCH ABSOLUTE 1 FROM n", error.ObjectNotInPrerequisiteState);
    try fails(tx, "FETCH RELATIVE 0 FROM n", error.ObjectNotInPrerequisiteState);
    try expect(tx, "FETCH FORWARD 2 FROM n", "2;3");
    try expect(tx, "CLOSE n", "");
    try check(result.command == .close_cursor);
    try fails(tx, "FETCH NEXT FROM n", error.PortalNotFound);
    // WITH HOLD survives COMMIT; other cursors end with the transaction.
    try expect(tx, "DECLARE h CURSOR WITH HOLD FOR SELECT id FROM tdd_a ORDER BY id DESC", "");
    try expect(tx, "FETCH NEXT FROM h", "4");
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "FETCH NEXT FROM h", "3");
    try fails(tx, "FETCH NEXT FROM c", error.PortalNotFound);
    // Declared in a rolled-back (sub)transaction: dropped.
    try expect(tx, "DECLARE gone CURSOR WITH HOLD FOR SELECT 1", "");
    try db.savepoint(tx, "s");
    try expect(tx, "DECLARE inner_cursor CURSOR FOR SELECT 2", "");
    _ = try db.rollbackTo(tx, "s");
    try fails(tx, "FETCH NEXT FROM inner_cursor", error.PortalNotFound);
    db.abort(tx);
    tx = try db.begin();
    try fails(tx, "FETCH NEXT FROM gone", error.PortalNotFound);
    try expect(tx, "FETCH ALL FROM h", "2;1");
    try expect(tx, "CLOSE ALL", "");
    try check(db.sessionUsage().cursors == 0 and db.sessionUsage().cursor_rows == 0);
    // Cursors belong to their session.
    db.session_state = &session_a;
    try expect(tx, "DECLARE mine CURSOR FOR SELECT 1", "");
    db.session_state = &session_b;
    try fails(tx, "FETCH NEXT FROM mine", error.PortalNotFound);
    db.session_state = &session_a;
    try expect(tx, "FETCH NEXT FROM mine", "1");
    db.session_state = null;
    db.abort(tx);
    // Outside a block only WITH HOLD cursors exist (25P01).
    tx = try db.begin();
    if (db.statement(tx, "DECLARE x CURSOR FOR SELECT 1", &result, .{ .implicit = true })) |_| return error.InvalidStatementAccepted else |err| try check(err == error.NoActiveTransaction);
    try db.statement(tx, "DECLARE x CURSOR WITH HOLD FOR SELECT 1", &result, .{ .implicit = true });
    try commit(tx);
    tx = try db.begin();
    try expect(tx, "FETCH ALL FROM x", "1");
    try expect(tx, "CLOSE x", "");
    db.abort(tx);
    // Capacities: one cursor, four rows.
    small = .{};
    const c = try small.begin();
    try small.statement(c, "CREATE TABLE t(a INT)", &small_result, .{});
    try small.statement(c, "INSERT INTO t VALUES(1),(2),(3),(4),(5)", &small_result, .{});
    if (small.statement(c, "DECLARE big CURSOR FOR SELECT a FROM t", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    try small.statement(c, "DECLARE one CURSOR FOR SELECT a FROM t WHERE a < 5", &small_result, .{});
    if (small.statement(c, "DECLARE two CURSOR FOR SELECT 1", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    small.abort(c);
}

// ---- PREPARE / EXECUTE / DEALLOCATE --------------------------------------

fn prepared() !void {
    try fixture();
    var tx = try db.begin();
    try expect(tx, "PREPARE p1(INT, TEXT) AS SELECT $1 + 1, $2 || 'x', $1", "");
    try check(result.command == .prepare);
    try expectMeta(tx, "EXECUTE p1(41, 'a')", "42|ax|41", "?column?:23:-1,?column?:25:-1,?column?:23:-1");
    try expect(tx, "EXECUTE p1('7', 'b')", "8|bx|7");
    try expect(tx, "EXECUTE p1(NULL, NULL)", "NULL|NULL|NULL");
    try expect(tx, "EXECUTE p1(2.6, 'c')", "4|cx|3");
    try fails(tx, "EXECUTE p1(1)", error.Syntax);
    try fails(tx, "EXECUTE p1(true, 'd')", error.TypeMismatch);
    try fails(tx, "EXECUTE nosuch", error.StatementNotFound);
    try fails(tx, "PREPARE p1 AS SELECT 1", error.DuplicateStatement);
    try fails(tx, "PREPARE bad AS SELECT * FROM missing", error.TableNotFound);
    try fails(tx, "EXECUTE bad", error.StatementNotFound);
    try fails(tx, "PREPARE extra(INT) AS SELECT $2", error.IndeterminateDatatype);
    try expect(tx, "PREPARE ins(INT, INT) AS INSERT INTO tdd_b VALUES ($1, $2)", "");
    try expect(tx, "EXECUTE ins(7, 77)", "");
    try check(result.affected_rows == 1 and result.command == .insert);
    try fails(tx, "EXECUTE ins(7, 78)", error.PrimaryKeyViolation);
    try expect(tx, "PREPARE q(INT) AS SELECT v FROM tdd_a WHERE id = $1", "");
    try expect(tx, "EXECUTE q(2)", "20");
    try expect(tx, "EXECUTE q(NULL)", "");
    try commit(tx);
    // Prepared statements are not transactional.
    tx = try db.begin();
    try expect(tx, "PREPARE r AS VALUES (1), (2)", "");
    db.abort(tx);
    tx = try db.begin();
    try expect(tx, "EXECUTE r", "1;2");
    try expect(tx, "EXECUTE q(7)", "");
    try expect(tx, "SELECT v FROM tdd_b WHERE id = 7", "77");
    try expect(tx, "DEALLOCATE PREPARE q", "");
    try check(result.command == .deallocate);
    try fails(tx, "EXECUTE q(1)", error.StatementNotFound);
    try fails(tx, "DEALLOCATE q", error.StatementNotFound);
    try expect(tx, "DEALLOCATE ALL", "");
    try fails(tx, "EXECUTE r", error.StatementNotFound);
    db.abort(tx);
    try sameState(&.{"SELECT id, v FROM tdd_b ORDER BY id"});
    small = .{};
    const c = try small.begin();
    try small.statement(c, "PREPARE a AS SELECT 1", &small_result, .{});
    if (small.statement(c, "PREPARE b AS SELECT 2", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    small.abort(c);
}

// ---- LOCK TABLE, row-lock strengths, advisory locks ----------------------

fn locking() !void {
    try fixture();
    try autocommit("CREATE VIEW tdd_v AS SELECT id FROM tdd_a");
    // SHARE blocks writers, not readers; NOWAIT is 55P03.
    const t1 = try db.begin();
    const t2 = try db.begin();
    const t3 = try db.begin();
    try expect(t1, "LOCK TABLE tdd_a IN SHARE MODE", "");
    try check(result.command == .lock_table);
    try expect(t2, "SELECT v FROM tdd_a WHERE id = 1", "10");
    try blocks(t2, "INSERT INTO tdd_a VALUES(9,9,9)");
    try fails(t3, "LOCK TABLE tdd_a IN EXCLUSIVE MODE NOWAIT", error.LockNotAvailable);
    try expect(t3, "LOCK TABLE ONLY tdd_a IN ROW SHARE MODE NOWAIT", "");
    try commit(t1);
    _ = try resumed(t2, "INSERT INTO tdd_a VALUES(9,9,9)");
    try commit(t2);
    db.abort(t3);
    // ACCESS EXCLUSIVE (the default) blocks plain reads.
    const t4 = try db.begin();
    const t5 = try db.begin();
    try expect(t4, "LOCK tdd_b", "");
    try blocks(t5, "SELECT count(*) FROM tdd_b");
    db.abort(t4);
    try check(same(try resumed(t5, "SELECT count(*) FROM tdd_b"), "3"));
    db.abort(t5);
    // SELECT FOR UPDATE holds ROW SHARE: EXCLUSIVE conflicts, SHARE not.
    const t6 = try db.begin();
    const t7 = try db.begin();
    try expect(t6, "SELECT id FROM tdd_a WHERE id = 1 FOR UPDATE", "1");
    try fails(t7, "LOCK TABLE tdd_a IN EXCLUSIVE MODE NOWAIT", error.LockNotAvailable);
    try expect(t7, "LOCK TABLE tdd_a IN SHARE MODE NOWAIT", "");
    db.abort(t6);
    db.abort(t7);
    // Errors.
    const t8 = try db.begin();
    try fails(t8, "LOCK TABLE missing", error.TableNotFound);
    try fails(t8, "LOCK TABLE tdd_v", error.UnsupportedStatement);
    try fails(t8, "LOCK TABLE nosuch.tdd_a", error.UndefinedSchema);
    try fails(t8, "LOCK TABLE tdd_a IN SHARE", error.Syntax);
    if (db.statement(t8, "LOCK TABLE tdd_a", &result, .{ .implicit = true })) |_| return error.InvalidStatementAccepted else |err| try check(err == error.NoActiveTransaction);
    db.abort(t8);
    try check(db.usage().table_locks == 0);

    // Row-lock strengths (PostgreSQL's matrix) and OF.
    const r1 = try db.begin();
    const r2 = try db.begin();
    const r3 = try db.begin();
    try expect(r1, "SELECT id FROM tdd_a WHERE id = 1 FOR KEY SHARE", "1");
    try expect(r2, "SELECT id FROM tdd_a WHERE id = 1 FOR NO KEY UPDATE NOWAIT", "1");
    try fails(r3, "SELECT id FROM tdd_a WHERE id = 1 FOR UPDATE NOWAIT", error.LockNotAvailable);
    try fails(r3, "SELECT id FROM tdd_a WHERE id = 1 FOR SHARE NOWAIT", error.LockNotAvailable);
    try expect(r3, "SELECT id FROM tdd_a WHERE id = 1 FOR KEY SHARE NOWAIT", "1");
    try expect(r3, "SELECT id FROM tdd_a WHERE id = 2 FOR SHARE", "2");
    try fails(r2, "SELECT id FROM tdd_a WHERE id = 2 FOR NO KEY UPDATE NOWAIT", error.LockNotAvailable);
    try expect(r2, "SELECT id FROM tdd_a WHERE id = 2 FOR KEY SHARE SKIP LOCKED", "2");
    try fails(r1, "SELECT id FROM tdd_a FOR UPDATE OF tdd_b", error.TableNotFound);
    try fails(r1, "SELECT id FROM tdd_a a FOR UPDATE OF a, tdd_b", error.TableNotFound);
    try expect(r1, "SELECT id FROM tdd_a a WHERE id = 3 FOR NO KEY UPDATE OF a, a", "3");
    // Its own weaker lock upgrades in place; the upgrade is undone with
    // the subtransaction.
    try db.savepoint(r3, "s");
    try fails(r3, "SELECT id FROM tdd_a WHERE id = 2 FOR UPDATE NOWAIT", error.LockNotAvailable);
    _ = try db.rollbackTo(r3, "s");
    db.abort(r1);
    db.abort(r2);
    try expect(r3, "SELECT id FROM tdd_a WHERE id = 1 FOR UPDATE", "1");
    db.abort(r3);
    try check(db.usage().row_locks == 0);

    // Advisory locks: transaction-level, session-level, shared.
    session_a = .{};
    session_b = .{};
    db.session_state = &session_a;
    const a1 = try db.begin();
    db.session_state = &session_b;
    const b1 = try db.begin();
    db.session_state = &session_a;
    session_a.pid = 4242;
    try expect(a1, "SELECT pg_backend_pid()", "4242");
    try expect(a1, "SELECT pg_try_advisory_xact_lock(123)", "t");
    try expect(a1, "SELECT pg_try_advisory_xact_lock(123)", "t");
    db.session_state = &session_b;
    try expect(b1, "SELECT pg_try_advisory_xact_lock(123), pg_try_advisory_xact_lock_shared(123)", "f|f");
    try expect(b1, "SELECT pg_try_advisory_xact_lock(NULL)", "NULL");
    db.session_state = &session_a;
    try commit(a1);
    db.session_state = &session_b;
    try expect(b1, "SELECT pg_try_advisory_xact_lock(123)", "t");
    try commit(b1);
    db.session_state = &session_a;
    var a2 = try db.begin();
    try expect(a2, "SELECT pg_try_advisory_lock(1, 2), pg_try_advisory_lock_shared(7)", "t|t");
    db.abort(a2); // session-level locks survive the rollback
    db.session_state = &session_b;
    const b2 = try db.begin();
    try expect(b2, "SELECT pg_try_advisory_lock(1, 2), pg_try_advisory_lock(1), pg_try_advisory_lock_shared(7), pg_try_advisory_lock(7)", "f|t|t|f");
    try expect(b2, "SELECT pg_advisory_unlock(1, 2)", "f");
    db.session_state = &session_a;
    a2 = try db.begin();
    try expect(a2, "SELECT pg_advisory_unlock(1, 2), pg_advisory_unlock(1, 2), pg_advisory_unlock_shared(7)", "t|f|t");
    try db.savepoint(a2, "s");
    try expect(a2, "SELECT pg_try_advisory_xact_lock(9)", "t");
    _ = try db.rollbackTo(a2, "s");
    db.session_state = &session_b;
    try expect(b2, "SELECT pg_try_advisory_lock(1, 2), pg_try_advisory_xact_lock(9), pg_try_advisory_lock(7)", "t|t|t");
    db.abort(b2);
    db.session_state = &session_a;
    try expect(a2, "SELECT pg_try_advisory_lock(7)", "f");
    db.abort(a2);
    // Session end releases its session-level locks.
    db.session_state = &session_b;
    db.endSession();
    db.session_state = &session_a;
    a2 = try db.begin();
    try expect(a2, "SELECT pg_try_advisory_lock(7), pg_try_advisory_lock(1, 2)", "t|t");
    db.abort(a2);
    db.endSession();
    db.session_state = null;
    try check(db.sessionUsage().advisory_locks == 0);
    small = .{};
    const c = try small.begin();
    try small.statement(c, "SELECT pg_try_advisory_xact_lock(1)", &small_result, .{});
    if (small.statement(c, "SELECT pg_try_advisory_xact_lock(2)", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    small.abort(c);
    try check(small.locks.advisoryUsed() == 0);
}

// ---- LISTEN / NOTIFY through two store connections and the wire ----------

fn take(connection: *Store.Connection, channel: []const u8, payload: []const u8, pid: u32) !void {
    var note: DB.Notification = undefined;
    try check(connection.takeNotification(&note));
    if (!same(note.channel.slice(), channel) or !same(note.payloadSlice(), payload)) std.debug.print("notification {s}/{s}\n", .{ note.channel.slice(), note.payloadSlice() });
    try check(same(note.channel.slice(), channel) and same(note.payloadSlice(), payload) and note.pid == pid);
}

fn none(connection: *Store.Connection) !void {
    var note: DB.Notification = undefined;
    try check(!connection.takeNotification(&note));
}

fn exec(connection: *Store.Connection, source: []const u8) !void {
    connection.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

var conn_a: Store.Connection = undefined;
var conn_b: Store.Connection = undefined;
var conn_c: Store.Connection = undefined;

fn notifications() !void {
    store = .{};
    conn_a = .{ .store = &store, .id = 1 };
    conn_b = .{ .store = &store, .id = 2 };
    conn_c = .{ .store = &store, .id = 3 };
    conn_b.setBackendPid(77);
    conn_a.setBackendPid(66);
    try exec(&conn_a, "LISTEN tdd_channel");
    try check(result.command == .listen);
    try exec(&conn_b, "BEGIN");
    try exec(&conn_b, "NOTIFY tdd_channel, 'x'");
    try check(result.command == .notify);
    try none(&conn_a);
    try exec(&conn_b, "COMMIT");
    try take(&conn_a, "tdd_channel", "x", 77);
    try none(&conn_a);
    try none(&conn_b);
    // Autocommit, no payload; duplicates within a transaction fold; order.
    try exec(&conn_b, "NOTIFY tdd_channel");
    try take(&conn_a, "tdd_channel", "", 77);
    try exec(&conn_b, "BEGIN");
    try exec(&conn_b, "NOTIFY tdd_channel, 'y'");
    try exec(&conn_b, "NOTIFY tdd_channel, 'y'");
    try exec(&conn_b, "NOTIFY tdd_channel, 'z'");
    try exec(&conn_b, "NOTIFY other_channel, 'unheard'");
    try exec(&conn_b, "COMMIT");
    try take(&conn_a, "tdd_channel", "y", 77);
    try take(&conn_a, "tdd_channel", "z", 77);
    try none(&conn_a);
    // Rollback and ROLLBACK TO discard pending notifications.
    try exec(&conn_b, "BEGIN");
    try exec(&conn_b, "NOTIFY tdd_channel, 'r'");
    try exec(&conn_b, "ROLLBACK");
    try none(&conn_a);
    try exec(&conn_b, "BEGIN");
    try exec(&conn_b, "NOTIFY tdd_channel, 'k'");
    try exec(&conn_b, "SAVEPOINT s");
    try exec(&conn_b, "NOTIFY tdd_channel, 'd'");
    try exec(&conn_b, "ROLLBACK TO s");
    try exec(&conn_b, "COMMIT");
    try take(&conn_a, "tdd_channel", "k", 77);
    try none(&conn_a);
    // A listener inside a transaction gets them after it ends.
    try exec(&conn_a, "BEGIN");
    try exec(&conn_b, "SELECT 1");
    try exec(&conn_b, "NOTIFY tdd_channel, 'w'");
    try none(&conn_a);
    try exec(&conn_a, "COMMIT");
    try take(&conn_a, "tdd_channel", "w", 77);
    // Its own notifications, LISTEN in the same transaction.
    try exec(&conn_a, "BEGIN");
    try exec(&conn_a, "LISTEN self_channel");
    try exec(&conn_a, "NOTIFY self_channel, 'me'");
    try exec(&conn_a, "COMMIT");
    try take(&conn_a, "self_channel", "me", 66);
    // A rolled-back LISTEN never registers; UNLISTEN takes effect at commit.
    try exec(&conn_c, "BEGIN");
    try exec(&conn_c, "LISTEN tdd_channel");
    try exec(&conn_c, "ROLLBACK");
    try exec(&conn_a, "UNLISTEN tdd_channel");
    try check(result.command == .unlisten);
    try exec(&conn_b, "NOTIFY tdd_channel, 'nobody'");
    try exec(&conn_b, "NOTIFY self_channel, 'still'");
    try none(&conn_c);
    try take(&conn_a, "self_channel", "still", 77);
    try none(&conn_a);
    try exec(&conn_a, "UNLISTEN *");
    try exec(&conn_b, "NOTIFY self_channel, 'gone'");
    try none(&conn_a);
    try check(store.database.sessionUsage().listeners == 0 and store.database.sessionUsage().queued_notifications == 0);
    // Session state through the store: settings, cursors, prepared.
    try exec(&conn_a, "SET search_path TO public");
    try exec(&conn_a, "SHOW search_path");
    try check(same(try render(&result), "public"));
    try exec(&conn_b, "SHOW search_path");
    try check(same(try render(&result), "\"$user\", public"));
    try exec(&conn_a, "SELECT current_setting('TimeZone'), set_config('statement_timeout', '5s', false)");
    try check(same(try render(&result), "UTC|5s"));
    try exec(&conn_a, "SHOW statement_timeout");
    try check(same(try render(&result), "5s"));
    try exec(&conn_a, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
    try exec(&conn_a, "SHOW transaction_isolation");
    try check(same(try render(&result), "repeatable read"));
    if (conn_a.execute("CREATE TABLE ro(x INT)", &result)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.ReadOnlyTransaction);
    try check(conn_a.transactionStatus() == 'E');
    try exec(&conn_a, "ROLLBACK");
    try exec(&conn_a, "BEGIN");
    try exec(&conn_a, "SET tdd.x = 'a'");
    try exec(&conn_a, "SAVEPOINT s");
    try exec(&conn_a, "SET tdd.x = 'b'");
    try exec(&conn_a, "ROLLBACK TO s");
    try exec(&conn_a, "SHOW tdd.x");
    try check(same(try render(&result), "a"));
    try exec(&conn_a, "COMMIT");
    try exec(&conn_a, "SHOW tdd.x");
    try check(same(try render(&result), "a"));
    if (conn_a.execute("DECLARE outside CURSOR FOR SELECT 1", &result)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.NoActiveTransaction);
    try exec(&conn_a, "DECLARE held CURSOR WITH HOLD FOR VALUES (1), (2)");
    try exec(&conn_a, "FETCH NEXT FROM held");
    try check(same(try render(&result), "1"));
    if (conn_b.execute("FETCH NEXT FROM held", &result)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.PortalNotFound);
    try exec(&conn_a, "PREPARE two AS SELECT 2");
    try exec(&conn_a, "EXECUTE two");
    try check(same(try render(&result), "2"));
    if (conn_a.execute("LOCK TABLE nosuch", &result)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.NoActiveTransaction);
    // Two-connection REPEATABLE READ through the store.
    try exec(&conn_a, "CREATE TABLE tdd_t(id INT PRIMARY KEY, v INT)");
    try exec(&conn_a, "INSERT INTO tdd_t VALUES (1, 1)");
    try exec(&conn_a, "BEGIN ISOLATION LEVEL REPEATABLE READ");
    try exec(&conn_a, "SELECT v FROM tdd_t");
    try exec(&conn_b, "UPDATE tdd_t SET v = 2");
    try exec(&conn_a, "SELECT v FROM tdd_t");
    try check(same(try render(&result), "1"));
    if (conn_a.execute("UPDATE tdd_t SET v = 3", &result)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.SerializationFailure);
    try exec(&conn_a, "ROLLBACK");
    try exec(&conn_a, "SELECT v FROM tdd_t");
    try check(same(try render(&result), "2"));
    // LOCK TABLE between connections parks the other and wakes it.
    try exec(&conn_a, "BEGIN");
    try exec(&conn_a, "LOCK TABLE tdd_t IN EXCLUSIVE MODE");
    if (conn_b.execute("UPDATE tdd_t SET v = 5", &result)) |_| return error.ExpectedBlock else |err| try check(err == error.WouldBlock);
    try check(conn_b.blocked() and !conn_b.wakeReady());
    try exec(&conn_a, "COMMIT");
    try check(conn_b.wakeReady());
    try exec(&conn_b, "UPDATE tdd_t SET v = 5");
    try check(result.affected_rows == 1);
    // Disconnect ends the session state.
    try exec(&conn_a, "LISTEN tdd_channel");
    try check(store.database.sessionUsage().listeners == 1 and store.database.sessionUsage().cursors == 1);
    conn_a.disconnect();
    try check(store.database.sessionUsage().listeners == 0 and store.database.sessionUsage().cursors == 0);
    try check(store.database.usage().transactions == 0);

    // The wire: NotificationResponse precedes ReadyForQuery.
    conn_c.setBackendPid(5);
    wire = .{};
    wire.configureBackendKey(5, 99);
    try startupWire();
    _ = try wireQuery("LISTEN wire_channel");
    try exec(&conn_b, "NOTIFY wire_channel, 'hello'");
    const reply = try wireQuery("SELECT 1");
    try check(wireHas(reply, 'A', "wire_channel"));
    try check(frameOrder(reply, 'A', 'Z'));
    try check(!wireHas(try wireQuery("SELECT 1"), 'A', "wire_channel"));
    try exec(&conn_b, "NOTIFY wire_channel, 'idle'");
    const idle = try wire.notifications(&conn_c, &wire_output);
    try check(wireHas(wire_output[0..idle], 'A', "idle"));
    try check(sqlstate(try wireQuery("LOCK TABLE tdd_t"), "25P01"));
    try check(commandTag(try wireQuery("PREPARE wp AS SELECT 1"), "PREPARE"));
    try check(commandTag(try wireQuery("DEALLOCATE ALL"), "DEALLOCATE ALL"));
    try check(commandTag(try wireQuery("UNLISTEN *"), "UNLISTEN"));
    try check(commandTag(try wireQuery("NOTIFY wire_channel"), "NOTIFY"));
    _ = try wireQuery("BEGIN");
    try check(commandTag(try wireQuery("LOCK TABLE tdd_t IN SHARE MODE"), "LOCK TABLE"));
    try check(commandTag(try wireQuery("DECLARE w CURSOR FOR VALUES (1),(2),(3)"), "DECLARE CURSOR"));
    try check(commandTag(try wireQuery("FETCH 2 FROM w"), "FETCH 2"));
    try check(commandTag(try wireQuery("MOVE BACKWARD 1 FROM w"), "MOVE 1"));
    try check(commandTag(try wireQuery("CLOSE w"), "CLOSE CURSOR"));
    try check(commandTag(try wireQuery("SET TRANSACTION READ ONLY"), "SET"));
    try check(commandTag(try wireQuery("COMMIT"), "COMMIT"));
    _ = try wireQuery("BEGIN");
    _ = try wireQuery("SELECT 1");
    try check(sqlstate(try wireQuery("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"), "25001"));
    _ = try wireQuery("ROLLBACK");
    try check(sqlstate(try wireQuery("FETCH NEXT FROM nosuch"), "34000"));
    try check(sqlstate(try wireQuery("EXECUTE nosuch"), "26000"));
    conn_b.disconnect();
    conn_c.disconnect();

    // NOTIFY queue capacity (54000): a slow listener holds the ring.
    small = .{};
    var listener: Small.SessionState = .{};
    var sender: Small.SessionState = .{};
    small.session_state = &listener;
    var tx = try small.begin();
    try small.statement(tx, "LISTEN q", &small_result, .{});
    small.publishCommit(tx);
    small.session_state = &sender;
    for ([_][]const u8{ "NOTIFY q, '1'", "NOTIFY q, '2'" }) |source| {
        tx = try small.begin();
        try small.statement(tx, source, &small_result, .{});
        small.publishCommit(tx);
    }
    tx = try small.begin();
    if (small.statement(tx, "NOTIFY q, '3'", &small_result, .{})) |_| return error.CapacityAccepted else |err| try check(err == error.SessionCapacity);
    small.session_state = &listener;
    var note: Small.Notification = undefined;
    try check(small.takeNotification(&note) and same(note.payloadSlice(), "1"));
    small.session_state = &sender;
    try small.statement(tx, "NOTIFY q, '3'", &small_result, .{});
    small.publishCommit(tx);
    small.session_state = &listener;
    try check(small.takeNotification(&note) and same(note.payloadSlice(), "2"));
    try check(small.takeNotification(&note) and same(note.payloadSlice(), "3"));
    try check(!small.takeNotification(&note));
}

// ---- wire helpers --------------------------------------------------------

fn put32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

fn get32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

var packet: [4096]u8 = undefined;

fn startupWire() !void {
    var at: usize = 4;
    put32(packet[at..], 196608);
    at += 4;
    for ([_][]const u8{ "user", "ramsql", "database", "test" }) |item| {
        @memcpy(packet[at..][0..item.len], item);
        at += item.len;
        packet[at] = 0;
        at += 1;
    }
    packet[at] = 0;
    at += 1;
    put32(packet[0..4], @intCast(at));
    const reply = try wire.handle(&conn_c, packet[0..at], &wire_output);
    try check(reply.consumed == at and wire.startup);
}

fn wireQuery(source: []const u8) ![]const u8 {
    packet[0] = 'Q';
    @memcpy(packet[5..][0..source.len], source);
    packet[5 + source.len] = 0;
    const length = 4 + source.len + 1;
    put32(packet[1..5], @intCast(length));
    const reply = try wire.handle(&conn_c, packet[0 .. 1 + length], &wire_output);
    try check(reply.consumed == 1 + length and !reply.blocked);
    return wire_output[0..reply.written];
}

/// A frame `tag` whose body contains `needle`.
fn wireHas(bytes: []const u8, tag: u8, needle: []const u8) bool {
    var at: usize = 0;
    while (at + 5 <= bytes.len) {
        const length = get32(bytes[at + 1 ..][0..4]);
        const body = bytes[at + 5 .. at + 1 + length];
        if (bytes[at] == tag and std.mem.indexOf(u8, body, needle) != null) return true;
        at += 1 + length;
    }
    return false;
}

fn frameOrder(bytes: []const u8, first: u8, second: u8) bool {
    var at: usize = 0;
    var seen = false;
    while (at + 5 <= bytes.len) {
        if (bytes[at] == first) seen = true;
        if (bytes[at] == second) return seen;
        at += 1 + get32(bytes[at + 1 ..][0..4]);
    }
    return false;
}

/// The (last) CommandComplete tag equals `wanted`.
fn commandTag(bytes: []const u8, wanted: []const u8) bool {
    var at: usize = 0;
    var found: ?[]const u8 = null;
    while (at + 5 <= bytes.len) {
        const length = get32(bytes[at + 1 ..][0..4]);
        if (bytes[at] == 'C') found = bytes[at + 5 .. at + length];
        at += 1 + length;
    }
    const tag = found orelse return false;
    return same(tag, wanted);
}

/// An ErrorResponse with SQLSTATE `wanted`.
fn sqlstate(bytes: []const u8, wanted: []const u8) bool {
    var at: usize = 0;
    while (at + 5 <= bytes.len) {
        const length = get32(bytes[at + 1 ..][0..4]);
        if (bytes[at] == 'E') {
            const body = bytes[at + 5 .. at + 1 + length];
            var i: usize = 0;
            while (i < body.len and body[i] != 0) {
                const kind = body[i];
                const start = i + 1;
                var end = start;
                while (end < body.len and body[end] != 0) end += 1;
                if (kind == 'C') return same(body[start..end], wanted);
                i = end + 1;
            }
        }
        at += 1 + length;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    try oraclePrograms();
    try transactionModes();
    try isolation();
    try settings();
    try cursors();
    try prepared();
    try locking();
    try notifications();
    var buffer: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-tx-session\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
