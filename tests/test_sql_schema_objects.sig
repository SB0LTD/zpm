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

const DB = sql.Database(.{ .tables = 16, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 1024 });
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

// ---- ON CONFLICT on non-primary unique keys (PG.DML.UPSERT_UNIQUE) ----------

const upsert_probes = [_][]const u8{
    "SELECT id, v, n FROM up ORDER BY id",
    "SELECT a, b, c FROM pair ORDER BY a, b, c",
};

fn upsertUnique() !void {
    reset();
    try run("CREATE TABLE up (id INT PRIMARY KEY, v INT UNIQUE, n INT)");
    try run("INSERT INTO up VALUES (1, 2, 0)");
    // The oracle program: the UNIQUE (v) arbiter updates the PRIMARY KEY.
    const result = try replicate("INSERT INTO up (id, v) VALUES (3, 2) ON CONFLICT (v) DO UPDATE SET id = EXCLUDED.id RETURNING id, v");
    try check(result.command == .insert and result.affected_rows == 1);
    try same(try render(&result), "3|2");
    try expect("SELECT id, v FROM up", "3|2");
    // Named arbiter; DO NOTHING; an unconflicted row inserts.
    try run("INSERT INTO up VALUES (4, 2, 1) ON CONFLICT ON CONSTRAINT up_v_key DO UPDATE SET n = up.n + EXCLUDED.n");
    try run("INSERT INTO up VALUES (5, 2, 9) ON CONFLICT (v) DO NOTHING");
    try run("INSERT INTO up VALUES (6, 6, 6) ON CONFLICT (v) DO NOTHING");
    try expect("SELECT id, v, n FROM up ORDER BY id", "3|2|1;6|6|6");
    // A conflict on another unique index is still 23505, and a WHERE that
    // fails leaves the row; 21000 when one statement hits a row twice.
    try rejects("INSERT INTO up VALUES (3, 7, 0) ON CONFLICT (v) DO NOTHING", error.PrimaryKeyViolation, upsert_probes[0], "3|2|1;6|6|6");
    try run("INSERT INTO up VALUES (8, 6, 0) ON CONFLICT (v) DO UPDATE SET n = 99 WHERE up.n > 100");
    try rejects("INSERT INTO up VALUES (9, 2, 0), (10, 2, 0) ON CONFLICT (v) DO UPDATE SET n = 5", error.CardinalityViolation, upsert_probes[0], "3|2|1;6|6|6");
    // Arbiter inference: 42P10 without a matching unique index, 42704 for
    // an unknown name, 42601 for DO UPDATE without a target.
    try rejects("INSERT INTO up VALUES (9, 9, 9) ON CONFLICT (n) DO NOTHING", error.InvalidColumnReference, upsert_probes[0], "3|2|1;6|6|6");
    try rejects("INSERT INTO up VALUES (9, 9, 9) ON CONFLICT (v, n) DO NOTHING", error.InvalidColumnReference, upsert_probes[0], "3|2|1;6|6|6");
    try rejects("INSERT INTO up VALUES (9, 9, 9) ON CONFLICT ON CONSTRAINT nope DO NOTHING", error.UndefinedObject, upsert_probes[0], "3|2|1;6|6|6");
    try rejects("INSERT INTO up VALUES (9, 9, 9) ON CONFLICT DO UPDATE SET n = 1", error.Syntax, upsert_probes[0], "3|2|1;6|6|6");
    // Composite UNIQUE and a UNIQUE index are arbiters too; NULL keys never
    // conflict (NULLS DISTINCT).
    try run("CREATE TABLE pair (a INT, b INT, c INT, UNIQUE (a, b))");
    try run("INSERT INTO pair VALUES (1, 1, 0), (1, NULL, 0)");
    try run("INSERT INTO pair VALUES (1, 1, 5) ON CONFLICT (b, a) DO UPDATE SET c = EXCLUDED.c");
    try run("INSERT INTO pair VALUES (1, NULL, 7) ON CONFLICT (a, b) DO UPDATE SET c = EXCLUDED.c");
    try run("CREATE UNIQUE INDEX pair_c ON pair (c)");
    try run("INSERT INTO pair VALUES (2, 2, 5) ON CONFLICT (c) DO UPDATE SET a = 3");
    try run("INSERT INTO pair VALUES (4, 4, 7) ON CONFLICT ON CONSTRAINT pair_c DO NOTHING");
    try expect("SELECT a, b, c FROM pair ORDER BY a, b, c", "1|NULL|0;1|NULL|7;3|1|5");
    // A deferrable constraint is not an arbiter (42809).
    try run("CREATE TABLE late (k INT UNIQUE DEFERRABLE)");
    try rejects("INSERT INTO late VALUES (1) ON CONFLICT (k) DO NOTHING", error.WrongObjectType, "SELECT COUNT(*) FROM late", "0");
    try sameState(&upsert_probes);
    // Races: the second upsert waits for the first writer of the key, then
    // updates its committed row, or inserts after its abort.
    const first = try db.begin();
    const second = try db.begin();
    try statement(first, "INSERT INTO up VALUES (20, 7, 1) ON CONFLICT (v) DO UPDATE SET n = up.n + 1");
    try parks(second, "INSERT INTO up VALUES (21, 7, 1) ON CONFLICT (v) DO UPDATE SET n = up.n + 10");
    try commit(first);
    try same(try resumed(second, "INSERT INTO up VALUES (21, 7, 1) ON CONFLICT (v) DO UPDATE SET n = up.n + 10"), "");
    try commit(second);
    try expect("SELECT id, v, n FROM up WHERE v = 7", "20|7|11");
    const third = try db.begin();
    const fourth = try db.begin();
    try statement(third, "INSERT INTO up VALUES (30, 8, 1) ON CONFLICT (v) DO NOTHING");
    try parks(fourth, "INSERT INTO up VALUES (31, 8, 2) ON CONFLICT (v) DO NOTHING");
    db.abort(third);
    _ = try resumed(fourth, "INSERT INTO up VALUES (31, 8, 2) ON CONFLICT (v) DO NOTHING");
    try commit(fourth);
    try expect("SELECT id, v, n FROM up WHERE v = 8", "31|8|2");
    // A conflicting row deleted by a live transaction is waited for too.
    const deleter = try db.begin();
    try statement(deleter, "DELETE FROM up WHERE v = 6");
    const upserter = try db.begin();
    try parks(upserter, "INSERT INTO up VALUES (40, 6, 4) ON CONFLICT (v) DO UPDATE SET n = 0");
    try commit(deleter);
    _ = try resumed(upserter, "INSERT INTO up VALUES (40, 6, 4) ON CONFLICT (v) DO UPDATE SET n = 0");
    try commit(upserter);
    try expect("SELECT id, v, n FROM up WHERE v = 6", "40|6|4");
    try sameState(&upsert_probes);
}

// ---- FOREIGN KEY actions (PG.CONSTRAINT.FK) ---------------------------------

const fk_probes = [_][]const u8{
    "SELECT id, g FROM p ORDER BY id",
    "SELECT id, pid FROM c ORDER BY id",
    "SELECT id, pid, note FROM n ORDER BY id",
    "SELECT id, parent FROM tree ORDER BY id",
    "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_schema = 'public' ORDER BY constraint_name",
};

fn foreignKeys() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    // The oracle program in one transaction: ON DELETE CASCADE.
    const tx = try db.begin();
    try statement(tx, "CREATE TABLE fk (id INT REFERENCES a(id) ON DELETE CASCADE)");
    try statement(tx, "INSERT INTO fk VALUES (1)");
    try statement(tx, "DELETE FROM a WHERE id = 1");
    try same(try rows(tx, "SELECT COUNT(*) FROM fk"), "0");
    db.abort(tx);
    try expect("SELECT COUNT(*) FROM a", "4");
    // NO ACTION (default) and RESTRICT: 23503 on both sides, atomically.
    try run("CREATE TABLE p (id INT PRIMARY KEY, g INT UNIQUE)");
    try run("INSERT INTO p VALUES (1, 10), (2, 20), (3, 30)");
    try run("CREATE TABLE c (id INT PRIMARY KEY, pid INT REFERENCES p)");
    try expect("SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 'c' ORDER BY constraint_name", "c_pid_fkey|FOREIGN KEY;c_pkey|PRIMARY KEY");
    try run("INSERT INTO c VALUES (1, 1), (2, NULL), (3, 3)");
    try rejects("INSERT INTO c VALUES (4, 9)", error.ForeignKeyViolation, fk_probes[1], "1|1;2|NULL;3|3");
    try rejects("UPDATE c SET pid = 9 WHERE id = 1", error.ForeignKeyViolation, fk_probes[1], "1|1;2|NULL;3|3");
    try rejects("DELETE FROM p WHERE id = 1", error.ForeignKeyViolation, fk_probes[0], "1|10;2|20;3|30");
    try rejects("UPDATE p SET id = 7 WHERE id = 3", error.ForeignKeyViolation, fk_probes[0], "1|10;2|20;3|30");
    try run("UPDATE p SET g = 11 WHERE id = 1");
    try run("DELETE FROM p WHERE id = 2");
    try run("UPDATE c SET pid = NULL WHERE id = 3");
    try run("DELETE FROM p WHERE id = 3");
    // A missing referenced table, column set or type: 42P01, 42830, 42804.
    try rejects("CREATE TABLE bad (x INT REFERENCES missing)", error.TableNotFound, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (x INT REFERENCES a(g))", error.InvalidForeignKey, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (x TEXT REFERENCES a)", error.TypeMismatch, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (x INT, y INT, FOREIGN KEY (x, y) REFERENCES a)", error.InvalidForeignKey, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    // Actions: CASCADE (delete and update), SET NULL, SET DEFAULT, RESTRICT.
    try run("INSERT INTO p VALUES (2, 20), (3, 30), (4, 40)");
    try run("CREATE TABLE n (id INT PRIMARY KEY, pid INT DEFAULT 4, note TEXT, CONSTRAINT n_cascade FOREIGN KEY (pid) REFERENCES p (id) ON DELETE CASCADE ON UPDATE CASCADE)");
    try run("CREATE TABLE s (id INT PRIMARY KEY, pid INT REFERENCES p ON DELETE SET NULL ON UPDATE SET DEFAULT, g INT REFERENCES p (g) ON DELETE SET DEFAULT ON UPDATE RESTRICT)");
    try run("INSERT INTO n VALUES (1, 2, 'two'), (2, 2, 'two again'), (3, 3, 'three')");
    try run("INSERT INTO s VALUES (1, 2, 20), (2, 3, 30)");
    try run("UPDATE p SET id = 5 WHERE id = 2");
    try expect("SELECT id, pid, note FROM n ORDER BY id", "1|5|two;2|5|two again;3|3|three");
    try expect("SELECT id, pid, g FROM s ORDER BY id", "1|NULL|20;2|3|30");
    try rejects("UPDATE p SET g = 31 WHERE id = 3", error.ForeignKeyViolation, "SELECT id, g FROM p ORDER BY id", "1|11;3|30;4|40;5|20");
    try run("DELETE FROM p WHERE id = 3");
    try expect("SELECT id, pid, note FROM n ORDER BY id", "1|5|two;2|5|two again");
    try expect("SELECT id, pid, g FROM s ORDER BY id", "1|NULL|20;2|NULL|NULL");
    // SET DEFAULT needs the default key to exist (23503) and NOT NULL
    // columns cannot be SET NULL (23502); both roll back the statement.
    try run("CREATE TABLE d (id INT PRIMARY KEY, pid INT DEFAULT 99 REFERENCES p ON DELETE SET DEFAULT)");
    try run("INSERT INTO d VALUES (1, 4)");
    try rejects("DELETE FROM p WHERE id = 4", error.ForeignKeyViolation, "SELECT id, pid FROM d", "1|4");
    try run("CREATE TABLE z (id INT PRIMARY KEY, pid INT NOT NULL REFERENCES p ON DELETE SET NULL)");
    try run("INSERT INTO z VALUES (1, 5)");
    try rejects("DELETE FROM p WHERE id = 5", error.NotNullViolation, "SELECT id, pid, note FROM n ORDER BY id", "1|5|two;2|5|two again");
    try run("DROP TABLE z");
    try run("DROP TABLE d");
    // A self-referencing tree: a row may reference itself, CASCADE recurses.
    try run("CREATE TABLE tree (id INT PRIMARY KEY, parent INT REFERENCES tree ON DELETE CASCADE)");
    try run("INSERT INTO tree VALUES (1, 1), (2, 1), (3, 2), (4, 3), (5, NULL)");
    try rejects("INSERT INTO tree VALUES (6, 9)", error.ForeignKeyViolation, fk_probes[3], "1|1;2|1;3|2;4|3;5|NULL");
    const removed = try replicate("DELETE FROM tree WHERE id = 2");
    try check(removed.affected_rows == 1);
    try expect("SELECT id, parent FROM tree ORDER BY id", "1|1;5|NULL");
    try sameState(&fk_probes);
    // DROP and TRUNCATE of a referenced table: 2BP01 / 0A000; CASCADE
    // removes the foreign key from the referencing table.
    try rejects("DROP TABLE p", error.DependentObjects, fk_probes[0], "1|11;4|40;5|20");
    try rejects("TRUNCATE p", error.UnsupportedStatement, fk_probes[0], "1|11;4|40;5|20");
    try run("TRUNCATE p, c, n, s");
    try run("INSERT INTO p VALUES (1, 10)");
    try run("INSERT INTO c VALUES (1, 1)");
    // ALTER TABLE ADD FOREIGN KEY checks existing rows.
    try run("CREATE TABLE late (id INT PRIMARY KEY, pid INT)");
    try run("INSERT INTO late VALUES (1, 1), (2, 7)");
    try rejects("ALTER TABLE late ADD CONSTRAINT late_fk FOREIGN KEY (pid) REFERENCES p", error.ForeignKeyViolation, "SELECT COUNT(*) FROM information_schema.table_constraints WHERE table_name = 'late'", "1");
    try run("DELETE FROM late WHERE id = 2");
    try run("ALTER TABLE late ADD CONSTRAINT late_fk FOREIGN KEY (pid) REFERENCES p");
    try rejects("INSERT INTO late VALUES (3, 8)", error.ForeignKeyViolation, "SELECT COUNT(*) FROM late", "1");
    try run("DROP TABLE p CASCADE");
    try expect("SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type = 'FOREIGN KEY' AND table_name IN ('c', 'n', 's', 'late')", "0");
    try run("INSERT INTO c VALUES (2, 77)");
    try sameState(&[_][]const u8{ fk_probes[1], fk_probes[4], "SELECT id, pid FROM late" });
    // Concurrency: a referencing insert share-locks its parent row, so a
    // parent DELETE waits and then fails; a parent DELETE in progress makes
    // the referencing insert wait and then fail.
    try run("CREATE TABLE p (id INT PRIMARY KEY)");
    try run("CREATE TABLE r (id INT PRIMARY KEY, pid INT REFERENCES p)");
    try run("INSERT INTO p VALUES (1), (2)");
    const child = try db.begin();
    try statement(child, "INSERT INTO r VALUES (1, 1)");
    const remover = try db.begin();
    try parks(remover, "DELETE FROM p WHERE id = 1");
    try commit(child);
    try resumeFails(remover, "DELETE FROM p WHERE id = 1", error.ForeignKeyViolation);
    db.abort(remover);
    const deleter = try db.begin();
    try statement(deleter, "DELETE FROM p WHERE id = 2");
    const inserter = try db.begin();
    try parks(inserter, "INSERT INTO r VALUES (2, 2)");
    try commit(deleter);
    try resumeFails(inserter, "INSERT INTO r VALUES (2, 2)", error.ForeignKeyViolation);
    db.abort(inserter);
    // An uncommitted parent row is invisible to another transaction.
    const creator = try db.begin();
    try statement(creator, "INSERT INTO p VALUES (3)");
    const early = try db.begin();
    try statementFails(early, "INSERT INTO r VALUES (3, 3)", error.ForeignKeyViolation);
    db.abort(early);
    try statement(creator, "INSERT INTO r VALUES (3, 3)");
    try commit(creator);
    try expect("SELECT id, pid FROM r ORDER BY id", "1|1;3|3");
    try check(db.usage().row_locks == 0 and db.usage().transactions == 0);
    try sameState(&[_][]const u8{ "SELECT id FROM p ORDER BY id", "SELECT id, pid FROM r ORDER BY id" });
}

// ---- deferred constraints (PG.CONSTRAINT.DEFERRED) --------------------------

fn commitFails(slot: u16, wanted: anyerror) !void {
    if (db.prepareCommit(slot, &record)) |_| {
        std.debug.print("commit accepted\n", .{});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("commit: {s} (wanted {s})\n", .{ @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    db.abort(slot);
}

const deferred_probes = [_][]const u8{
    "SELECT v FROM du ORDER BY v",
    "SELECT k FROM di ORDER BY k",
    "SELECT id FROM dp ORDER BY id",
    "SELECT id, pid FROM dc ORDER BY id",
};

fn deferredConstraints() !void {
    reset();
    // The oracle program: duplicates while deferred, resolved before the
    // explicit IMMEDIATE check.
    try run("CREATE TABLE du (v INT UNIQUE DEFERRABLE INITIALLY DEFERRED)");
    const tx = try db.begin();
    try statement(tx, "INSERT INTO du VALUES (1), (1)");
    try same(try rows(tx, "SELECT COUNT(*) FROM du"), "2");
    try statement(tx, "DELETE FROM du");
    try statement(tx, "SET CONSTRAINTS ALL IMMEDIATE");
    try statement(tx, "INSERT INTO du VALUES (2)");
    try statementFails(tx, "INSERT INTO du VALUES (2)", error.PrimaryKeyViolation);
    try commit(tx);
    try expect(deferred_probes[0], "2");
    // A violation still present at COMMIT aborts the transaction (23505).
    const late = try db.begin();
    try statement(late, "INSERT INTO du VALUES (3), (3)");
    try commitFails(late, error.PrimaryKeyViolation);
    try expect(deferred_probes[0], "2");
    // SET CONSTRAINTS ... IMMEDIATE checks the outstanding rows at once.
    const set = try db.begin();
    try statement(set, "INSERT INTO du VALUES (2)");
    try statementFails(set, "SET CONSTRAINTS du_v_key IMMEDIATE", error.PrimaryKeyViolation);
    db.abort(set);
    // Fixed before commit: the duplicates are removed and one added back.
    const fixed = try db.begin();
    try statement(fixed, "INSERT INTO du VALUES (5), (5)");
    try statement(fixed, "DELETE FROM du WHERE v = 5");
    try statement(fixed, "INSERT INTO du VALUES (5)");
    try commit(fixed);
    try expect(deferred_probes[0], "2;5");
    // Autocommit: the statement's own commit check fails it atomically.
    try rejects("INSERT INTO du VALUES (6), (6)", error.PrimaryKeyViolation, deferred_probes[0], "2;5");
    // DEFERRABLE INITIALLY IMMEDIATE is checked at the end of each
    // statement (a shifting UPDATE passes), unless deferred.
    try run("CREATE TABLE di (k INT, CONSTRAINT di_k UNIQUE (k) DEFERRABLE)");
    try run("INSERT INTO di VALUES (1), (2)");
    try run("UPDATE di SET k = k + 1");
    try expect(deferred_probes[1], "2;3");
    try rejects("UPDATE di SET k = 3 WHERE k = 2", error.PrimaryKeyViolation, deferred_probes[1], "2;3");
    const swap = try db.begin();
    try statement(swap, "SET CONSTRAINTS di_k DEFERRED");
    try statement(swap, "UPDATE di SET k = 3 WHERE k = 2");
    try same(try rows(swap, "SELECT k FROM di ORDER BY k"), "3;3");
    try statement(swap, "DELETE FROM di WHERE k = 3");
    try statement(swap, "INSERT INTO di VALUES (3), (4)");
    try commit(swap);
    try expect(deferred_probes[1], "3;4");
    // Names: 42704 when missing, 42809 when not deferrable.
    try run("CREATE TABLE fixed (k INT CONSTRAINT fixed_k UNIQUE)");
    try rejects("SET CONSTRAINTS nope IMMEDIATE", error.UndefinedObject, deferred_probes[1], "3;4");
    try rejects("SET CONSTRAINTS fixed_k DEFERRED", error.WrongObjectType, deferred_probes[1], "3;4");
    // Deferred FOREIGN KEY: a child before its parent, a parent removed and
    // added back; still missing at COMMIT is 23503.
    try run("CREATE TABLE dp (id INT PRIMARY KEY)");
    try run("CREATE TABLE dc (id INT PRIMARY KEY, pid INT REFERENCES dp DEFERRABLE INITIALLY DEFERRED)");
    const order = try db.begin();
    try statement(order, "INSERT INTO dc VALUES (1, 10)");
    try statement(order, "INSERT INTO dp VALUES (10)");
    try commit(order);
    const missing = try db.begin();
    try statement(missing, "INSERT INTO dc VALUES (2, 20)");
    try commitFails(missing, error.ForeignKeyViolation);
    const readd = try db.begin();
    try statement(readd, "DELETE FROM dp WHERE id = 10");
    try statement(readd, "INSERT INTO dp VALUES (10)");
    try commit(readd);
    const orphan = try db.begin();
    try statement(orphan, "DELETE FROM dp WHERE id = 10");
    try statementFails(orphan, "SET CONSTRAINTS ALL IMMEDIATE", error.ForeignKeyViolation);
    db.abort(orphan);
    try expect(deferred_probes[3], "1|10");
    // Concurrency: two deferred inserts of one key both succeed until the
    // second commit, which fails; the end-of-statement check leaves another
    // live writer's version to that writer's own check (no wait).
    const first = try db.begin();
    const second = try db.begin();
    try statement(first, "INSERT INTO du VALUES (7)");
    try statement(second, "INSERT INTO du VALUES (7)");
    try commit(first);
    try commitFails(second, error.PrimaryKeyViolation);
    const holder = try db.begin();
    try statement(holder, "INSERT INTO du VALUES (8)");
    const strict = try db.begin();
    try statement(strict, "SET CONSTRAINTS ALL IMMEDIATE");
    try statement(strict, "INSERT INTO du VALUES (8)");
    try commit(holder);
    try commitFails(strict, error.PrimaryKeyViolation);
    try expect(deferred_probes[0], "2;5;7;8");
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0);
    try sameState(&deferred_probes);
    try sameState(&[_][]const u8{"SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_schema = 'public' ORDER BY constraint_name"});
}

pub fn main() !void {
    try secondaryIndexes();
    try indexCapacity();
    try upsertUnique();
    try foreignKeys();
    try deferredConstraints();
    std.debug.print("schema objects: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
