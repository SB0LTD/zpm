//! Schema-object contracts (conformance lane B11, wave 2): secondary and
//! advanced indexes, UNIQUE upsert arbiters, FOREIGN KEY actions, deferred
//! constraints, views, materialized views, CREATE TABLE variants, MERGE,
//! virtual generated columns, exclusion constraints, inheritance and
//! partitioning. Each section checks values (PostgreSQL 18 text output),
//! exact errors (SQLSTATE through the error name), atomicity after a failure,
//! concurrency where a lock or a key decides, and replay: every committed
//! record is applied to a replica that must answer every probe exactly like
//! the primary (committed state = replay(WAL)). Expectations outside the
//! frozen postgres18_oracle.json programs are pending native verification.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 8, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 1024 });
/// One secondary index per table holding at most six entries.
const Small = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .table_indexes = 1, .index_entries = 6 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("schema-objects contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.SchemaObjectsContractFailed;
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
        var copy: [16384]u8 = undefined;
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

// ---- secondary indexes (PG.INDEX.SECONDARY) ---------------------------------

const index_probes = [_][]const u8{
    "SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename, indexname",
    "SELECT relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
    "SELECT c.relname, i.indisunique, i.indkey FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid ORDER BY c.relname",
    "SELECT id, g, v FROM t ORDER BY id",
};

fn probeCount(target: *DB, table: []const u8, index: []const u8, key: []const DB.Cell, probe: bool) !usize {
    return target.indexMatches(table, index, key, probe) orelse error.IndexNotFound;
}

/// Index path = scan path for every key value 0..6 and NULL.
fn indexAgrees(target: *DB, table: []const u8, index: []const u8) !void {
    for (0..7) |value| {
        const key = [_]DB.Cell{.{ .integer = @intCast(value) }};
        try check(try probeCount(target, table, index, &key, true) == try probeCount(target, table, index, &key, false));
    }
    const nulls = [_]DB.Cell{.null_value};
    try check(try probeCount(target, table, index, &nulls, true) == try probeCount(target, table, index, &nulls, false));
    try check(target.indexConsistent(table).?);
}

fn secondaryIndexes() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO t VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    // The oracle program: CREATE INDEX then pg_indexes in one transaction.
    const tx = try db.begin();
    try statement(tx, "CREATE INDEX t_ix ON t(v)");
    try same(try rows(tx, "SELECT indexname FROM pg_indexes WHERE indexname='t_ix'"), "t_ix");
    db.abort(tx);
    try expect("SELECT COUNT(*) FROM pg_indexes WHERE indexname = 't_ix'", "0");
    const created = try replicate("CREATE INDEX t_ix ON t(v)");
    try check(created.command == .create_index and created.affected_rows == 0 and created.column_count == 0);
    try expect("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 't' ORDER BY indexname", "t_ix|CREATE INDEX t_ix ON public.t USING btree (v);t_pkey|CREATE UNIQUE INDEX t_pkey ON public.t USING btree (id)");
    // Default names follow ChooseIndexName (numbered when taken).
    try run("CREATE INDEX ON t (g)");
    try run("CREATE INDEX ON t (g DESC)");
    try expect("SELECT indexname FROM pg_indexes WHERE tablename = 't' ORDER BY indexname", "t_g_idx;t_g_idx1;t_ix;t_pkey");
    try expect("SELECT indexdef FROM pg_indexes WHERE indexname = 't_g_idx1'", "CREATE INDEX t_g_idx1 ON public.t USING btree (g DESC)");
    try expect("SELECT relkind, relnatts FROM pg_class WHERE relname = 't_ix'", "i|1");
    try expect("SELECT i.indisprimary, i.indisunique, i.indkey FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 't_ix'", "f|f|3");
    // Every visible row is found through the index, before and after DML.
    try indexAgrees(&db, "t", "t_ix");
    try run("INSERT INTO t VALUES (5, 3, 20), (6, 3, NULL)");
    try run("UPDATE t SET v = 40 WHERE id = 1");
    try run("DELETE FROM t WHERE id = 2");
    try indexAgrees(&db, "t", "t_ix");
    try indexAgrees(&db, "t", "t_g_idx");
    const twenty = [_]DB.Cell{.{ .integer = 20 }};
    try check(try probeCount(&db, "t", "t_ix", &twenty, true) == 1);
    const nulls = [_]DB.Cell{.null_value};
    try check(try probeCount(&db, "t", "t_ix", &nulls, true) == 2);
    // Rollback leaves no entry behind; the table answers as before.
    const writer = try db.begin();
    try statement(writer, "INSERT INTO t VALUES (7, 4, 20)");
    try statement(writer, "UPDATE t SET v = 20 WHERE id = 3");
    try statement(writer, "DELETE FROM t WHERE id = 4");
    db.abort(writer);
    try indexAgrees(&db, "t", "t_ix");
    try check(try probeCount(&db, "t", "t_ix", &twenty, true) == 1);
    _ = db.vacuum();
    try indexAgrees(&db, "t", "t_ix");
    // Errors: 42P07 (name of a relation or index), 42703, 42P01, 42704,
    // 2BP01 for a constraint's index; each leaves nothing behind.
    const names = "SELECT indexname FROM pg_indexes WHERE tablename = 't' ORDER BY indexname";
    const listed = "t_g_idx;t_g_idx1;t_ix;t_pkey";
    try rejects("CREATE INDEX t_ix ON t (g)", error.TableExists, names, listed);
    try rejects("CREATE INDEX t ON t (g)", error.TableExists, names, listed);
    try rejects("CREATE INDEX t_pkey ON t (g)", error.TableExists, names, listed);
    try rejects("CREATE INDEX t_bad ON t (missing)", error.ColumnNotFound, names, listed);
    try rejects("CREATE INDEX t_bad ON missing (g)", error.TableNotFound, names, listed);
    try rejects("DROP INDEX t_missing", error.UndefinedObject, names, listed);
    try rejects("DROP INDEX t_pkey", error.DependentObjects, names, listed);
    try rejects("CREATE INDEX t_bad ON t USING gin (g)", error.UnsupportedStatement, names, listed);
    const noop = try replicate("CREATE INDEX IF NOT EXISTS t_ix ON t (g)");
    try check(noop.command == .create_index);
    _ = try replicate("DROP INDEX IF EXISTS t_missing");
    try sameState(&index_probes);
    try run("DROP INDEX t_g_idx1");
    try expect(names, "t_g_idx;t_ix;t_pkey");
    // UNIQUE: existing duplicates are 23505 and atomic; later writes are
    // checked through the index; NULLs are distinct unless NULLS NOT DISTINCT.
    try rejects("CREATE UNIQUE INDEX t_g_key ON t (g)", error.PrimaryKeyViolation, names, "t_g_idx;t_ix;t_pkey");
    try run("CREATE UNIQUE INDEX t_v_key ON t (v)");
    try rejects("INSERT INTO t VALUES (8, 9, 30)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM t", "5");
    try rejects("UPDATE t SET v = 30 WHERE id = 5", error.PrimaryKeyViolation, "SELECT v FROM t WHERE id = 5", "20");
    try run("INSERT INTO t VALUES (8, 9, NULL)");
    try run("UPDATE t SET v = v WHERE id = 3");
    try rejects("CREATE UNIQUE INDEX t_n_key ON t (v) NULLS NOT DISTINCT", error.PrimaryKeyViolation, names, "t_g_idx;t_ix;t_pkey;t_v_key");
    try rejects("CREATE UNIQUE INDEX t_e_key ON t ((v + 1))", error.UnsupportedStatement, names, "t_g_idx;t_ix;t_pkey;t_v_key");
    try indexAgrees(&db, "t", "t_v_key");
    // A unique index race: the second inserter waits for the first and
    // fails after its commit, or inserts after its abort.
    const first = try db.begin();
    const second = try db.begin();
    try statement(first, "INSERT INTO t VALUES (9, 9, 90)");
    try parks(second, "INSERT INTO t VALUES (10, 9, 90)");
    try commit(first);
    try resumeFails(second, "INSERT INTO t VALUES (10, 9, 90)", error.PrimaryKeyViolation);
    db.abort(second);
    const third = try db.begin();
    const fourth = try db.begin();
    try statement(third, "INSERT INTO t VALUES (11, 9, 91)");
    try parks(fourth, "INSERT INTO t VALUES (12, 9, 91)");
    db.abort(third);
    _ = try resumed(fourth, "INSERT INTO t VALUES (12, 9, 91)");
    try commit(fourth);
    try expect("SELECT id FROM t WHERE v >= 90 ORDER BY id", "9;12");
    // CREATE INDEX waits for a live writer of the table (AccessExclusive).
    const live = try db.begin();
    try statement(live, "INSERT INTO t VALUES (13, 1, 13)");
    const builder = try db.begin();
    try parks(builder, "CREATE INDEX t_late ON t (g)");
    try commit(live);
    _ = try resumed(builder, "CREATE INDEX t_late ON t (g)");
    try commit(builder);
    try indexAgrees(&db, "t", "t_late");
    // DROP INDEX, then the same name again; replay keeps every OID.
    try run("DROP INDEX t_late");
    try run("CREATE INDEX t_late ON t (v, g)");
    try expect(names, "t_g_idx;t_ix;t_late;t_pkey;t_v_key");
    try sameState(&index_probes);
    try indexAgrees(&replica, "t", "t_ix");
    try indexAgrees(&replica, "t", "t_v_key");
    // ALTER TABLE keeps indexes; a dropped key column drops its index.
    try run("ALTER TABLE t ADD COLUMN w INT");
    try run("ALTER TABLE t DROP COLUMN g");
    try expect(names, "t_ix;t_pkey;t_v_key");
    try run("ALTER TABLE t RENAME COLUMN v TO val");
    try expect("SELECT indexdef FROM pg_indexes WHERE indexname = 't_ix'", "CREATE INDEX t_ix ON public.t USING btree (val)");
    try sameState(&[_][]const u8{ index_probes[0], index_probes[1], "SELECT id, val, w FROM t ORDER BY id" });
    try indexAgrees(&replica, "t", "t_ix");
    try check(records_applied != 0);
}

/// Config.table_indexes and Config.index_entries: 54000 with no change.
fn indexCapacity() !void {
    var small: Small = .{};
    var result: Small.Result = .{};
    try small.execute("CREATE TABLE s (id INT PRIMARY KEY, v INT)", &result);
    try small.execute("INSERT INTO s VALUES (1, 1), (2, 2), (3, 3), (4, 4)", &result);
    try small.execute("CREATE INDEX s_v ON s (v)", &result);
    try check(small.execute("CREATE INDEX s_w ON s (id)", &result) == error.IndexCapacity);
    try small.execute("INSERT INTO s VALUES (5, 5), (6, 6)", &result);
    // A seventh version does not fit the index: the statement rolls back.
    try check(small.execute("INSERT INTO s VALUES (7, 7)", &result) == error.IndexCapacity);
    try check(small.execute("UPDATE s SET v = 0 WHERE id = 1", &result) == error.IndexCapacity);
    try small.execute("SELECT COUNT(*), SUM(v) FROM s", &result);
    try check(result.rows[0].cells[0].integer == 6 and result.rows[0].cells[1].integer == 21);
    try check(small.usage().pending_versions == 0 and small.indexConsistent("s").?);
    // Deleted versions are reclaimed, after which the index has room again.
    try small.execute("DELETE FROM s WHERE id > 4", &result);
    _ = small.vacuum();
    try small.execute("INSERT INTO s VALUES (7, 7)", &result);
    try check(small.indexConsistent("s").?);
    // Too many rows for a new index: 54000 before anything changes.
    try small.execute("DROP INDEX s_v", &result);
    try small.execute("INSERT INTO s VALUES (8, 8), (9, 9)", &result);
    try check(small.execute("CREATE INDEX s_v ON s (v)", &result) == error.IndexCapacity);
    try small.execute("SELECT COUNT(*) FROM pg_indexes WHERE tablename = 's'", &result);
    try check(result.rows[0].cells[0].integer == 1);
}

pub fn main() !void {
    try secondaryIndexes();
    try indexCapacity();
    std.debug.print("schema objects: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
