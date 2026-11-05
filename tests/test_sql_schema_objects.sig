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
const Small = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .table_indexes = 1, .index_entries = 6, .expansion_bytes = 160 });

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
    return target.indexMatches(table, index, key, probe) orelse {
        std.debug.print("index {s} of {s} not found (assertion {d})\n", .{ index, table, assertions });
        return error.IndexNotFound;
    };
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

// ---- views (PG.VIEW.ORDINARY) -----------------------------------------------

const view_probes = [_][]const u8{
    "SELECT * FROM v ORDER BY id",
    "SELECT * FROM labels ORDER BY id",
    "SELECT * FROM totals ORDER BY g",
    "SELECT viewname, definition FROM pg_views WHERE schemaname = 'public' ORDER BY viewname",
    "SELECT relname, relkind, relnatts FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
    "SELECT attname, atttypid FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 'labels' ORDER BY attnum",
};

var read_context: DB.ReadContext = .{};
var read_result: DB.Result = .{};

fn views() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    // The oracle program in one transaction.
    const tx = try db.begin();
    try statement(tx, "CREATE VIEW tdd_view AS SELECT id,v FROM a");
    try same(try rows(tx, "SELECT * FROM tdd_view ORDER BY id"), "1|10;2|20;3|30;4|NULL");
    const other = try db.begin();
    try statementFails(other, "SELECT * FROM tdd_view", error.TableNotFound);
    db.abort(other);
    db.abort(tx);
    try rejects("SELECT * FROM tdd_view", error.TableNotFound, "SELECT COUNT(*) FROM a", "4");
    const created = try replicate("CREATE VIEW v AS SELECT id, v FROM a WHERE v IS NOT NULL OR id = 4");
    try check(created.command == .create_view);
    try expect(view_probes[0], "1|10;2|20;3|30;4|NULL");
    // Views read the current rows; string literals, expressions, column
    // lists, aggregates, views over views, joins and subqueries.
    try run("CREATE VIEW labels (id, label) AS SELECT id, 'row ' || CAST(id AS TEXT) FROM v WHERE id < 4");
    try run("CREATE VIEW totals AS SELECT g, SUM(v) AS total, COUNT(*) AS n FROM a GROUP BY g");
    try run("INSERT INTO a VALUES (5, 3, 50)");
    try expect(view_probes[1], "1|row 1;2|row 2;3|row 3");
    try expect(view_probes[2], "1|30|2;2|30|2;3|50|1");
    try expect("SELECT l.label, t.total FROM labels l JOIN a ON a.id = l.id JOIN totals t ON t.g = a.g ORDER BY l.id", "row 1|30;row 2|30;row 3|30");
    try expect("SELECT COUNT(*) FROM a WHERE id IN (SELECT id FROM v WHERE v > 15)", "3");
    try expect("WITH w AS (SELECT * FROM labels) SELECT COUNT(*) FROM w", "3");
    try expect("SELECT id FROM v WHERE id > 3 ORDER BY id", "4;5");
    const inserted = try replicate("INSERT INTO a SELECT id + 10, 9, v FROM v WHERE id = 1 RETURNING id");
    try same(try render(&inserted), "11");
    try run("DELETE FROM a WHERE id = 11");
    try expect(view_probes[3], "labels|SELECT id, 'row ' || CAST(id AS TEXT) FROM v WHERE id < 4;totals|SELECT g, SUM(v) AS total, COUNT(*) AS n FROM a GROUP BY g;v|SELECT id, v FROM a WHERE v IS NOT NULL OR id = 4");
    try expect(view_probes[5], "id|23;label|25");
    try expect("SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name", "a|BASE TABLE;labels|VIEW;totals|VIEW;v|VIEW");
    // Detached reads expand views too.
    try read_context.execute(&db, "SELECT label FROM labels WHERE id = 2", .{ .csn = db.csn }, &read_result);
    try same(try render(&read_result), "row 2");
    try sameState(&view_probes);
    // Errors: 42P07, 42P01 inside the definition, 42701, 42809 for the
    // wrong DROP kind, 2BP01 for dependents, 0A000 for writes and renames.
    const names = "SELECT relname FROM pg_class WHERE relkind = 'v' ORDER BY relname";
    try rejects("CREATE VIEW v AS SELECT 1 AS one", error.TableExists, names, "labels;totals;v");
    try rejects("CREATE VIEW a AS SELECT 1 AS one", error.TableExists, names, "labels;totals;v");
    try rejects("CREATE VIEW w AS SELECT * FROM missing", error.TableNotFound, names, "labels;totals;v");
    try rejects("CREATE VIEW w AS SELECT id, v AS id FROM a", error.DuplicateColumn, names, "labels;totals;v");
    try rejects("CREATE VIEW w (x, y, z) AS SELECT id, v FROM a", error.Syntax, names, "labels;totals;v");
    try rejects("DROP TABLE v", error.WrongObjectType, names, "labels;totals;v");
    try rejects("DROP VIEW a", error.WrongObjectType, names, "labels;totals;v");
    try rejects("DROP VIEW v", error.DependentObjects, names, "labels;totals;v");
    try rejects("DROP TABLE a", error.DependentObjects, names, "labels;totals;v");
    try rejects("ALTER TABLE a DROP COLUMN v", error.DependentObjects, view_probes[0], "1|10;2|20;3|30;4|NULL;5|50");
    try rejects("ALTER TABLE a RENAME COLUMN v TO w", error.UnsupportedStatement, view_probes[0], "1|10;2|20;3|30;4|NULL;5|50");
    try rejects("INSERT INTO v VALUES (9, 9)", error.UnsupportedStatement, view_probes[0], "1|10;2|20;3|30;4|NULL;5|50");
    try rejects("DELETE FROM v", error.UnsupportedStatement, view_probes[0], "1|10;2|20;3|30;4|NULL;5|50");
    try rejects("DROP VIEW missing", error.TableNotFound, names, "labels;totals;v");
    _ = try replicate("DROP VIEW IF EXISTS missing");
    // CASCADE drops the dependent views; RESTRICT of a leaf view works.
    try run("DROP VIEW totals");
    try run("DROP VIEW v CASCADE");
    try expect(names, "");
    try run("ALTER TABLE a RENAME COLUMN v TO val");
    try run("CREATE VIEW v AS SELECT id, val FROM a WHERE id <= 2");
    try expect(view_probes[0], "1|10;2|20");
    // A concurrent DROP TABLE waits for the transaction that created a view
    // over it (AccessShare) and then fails on the committed dependent.
    const creator = try db.begin();
    try statement(creator, "CREATE VIEW late AS SELECT id FROM a");
    const dropper = try db.begin();
    try parks(dropper, "DROP TABLE a");
    try commit(creator);
    try resumeFails(dropper, "DROP TABLE a", error.DependentObjects);
    db.abort(dropper);
    try run("DROP TABLE a CASCADE");
    try expect(names, "");
    try check(db.tableCount() == 0);
    try sameState(&[_][]const u8{ view_probes[3], view_probes[4] });
}

/// Config.expansion_bytes bounds the statement plus its view texts.
fn viewCapacity() !void {
    var small: Small = .{};
    var result: Small.Result = .{};
    try small.execute("CREATE TABLE s (id INT PRIMARY KEY, v INT)", &result);
    try small.execute("CREATE VIEW sv AS SELECT id, v FROM s WHERE v IS NOT NULL", &result);
    try small.execute("INSERT INTO s VALUES (1, 1)", &result);
    try small.execute("SELECT COUNT(*) FROM sv", &result);
    try check(result.rows[0].cells[0].integer == 1);
    try check(small.execute("SELECT COUNT(*) FROM sv a JOIN sv b ON a.id = b.id JOIN sv c ON c.id = a.id", &result) == error.TextCapacity);
    try check(small.usage().transactions == 0);
}

// ---- materialized views (PG.VIEW.MATERIALIZED) ------------------------------

const matview_probes = [_][]const u8{
    "SELECT * FROM mv ORDER BY g",
    "SELECT matviewname, ispopulated, definition FROM pg_matviews ORDER BY matviewname",
    "SELECT relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
};

fn materializedViews() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    // The oracle program in one transaction.
    const tx = try db.begin();
    try statement(tx, "CREATE MATERIALIZED VIEW tdd_mv AS SELECT g,SUM(v) AS total FROM a GROUP BY g");
    try statement(tx, "REFRESH MATERIALIZED VIEW tdd_mv");
    try same(try rows(tx, "SELECT * FROM tdd_mv ORDER BY g"), "1|30;2|30");
    db.abort(tx);
    // The rows are stored: they change only at REFRESH.
    const created = try replicate("CREATE MATERIALIZED VIEW mv AS SELECT g, SUM(v) AS total, COUNT(*) AS n FROM a WHERE g < 9 GROUP BY g");
    try check(created.command == .create_materialized_view and created.affected_rows == 2);
    try expect(matview_probes[0], "1|30|2;2|30|2");
    try run("INSERT INTO a VALUES (5, 3, 50)");
    try run("UPDATE a SET v = 11 WHERE id = 1");
    try expect(matview_probes[0], "1|30|2;2|30|2");
    const refreshed = try replicate("REFRESH MATERIALIZED VIEW mv");
    try check(refreshed.command == .refresh_materialized_view);
    try expect(matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try expect("SELECT relkind FROM pg_class WHERE relname = 'mv'", "m");
    try expect(matview_probes[1], "mv|t|SELECT g, SUM(v) AS total, COUNT(*) AS n FROM a WHERE g < 9 GROUP BY g");
    try expect("SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'mv'", "0");
    try sameState(&matview_probes);
    // WITH NO DATA: unpopulated until REFRESH (55000); REFRESH WITH NO DATA
    // empties it again. Both change the durable definition.
    try run("CREATE MATERIALIZED VIEW later AS SELECT id FROM a WITH NO DATA");
    try rejects("SELECT * FROM later", error.ObjectNotInPrerequisiteState, matview_probes[1], "later|f|SELECT id FROM a;mv|t|SELECT g, SUM(v) AS total, COUNT(*) AS n FROM a WHERE g < 9 GROUP BY g");
    try run("REFRESH MATERIALIZED VIEW later");
    try expect("SELECT COUNT(*) FROM later", "5");
    try run("REFRESH MATERIALIZED VIEW later WITH NO DATA");
    try rejects("SELECT * FROM later", error.ObjectNotInPrerequisiteState, "SELECT COUNT(*) FROM a", "5");
    try sameState(&[_][]const u8{ matview_probes[0], matview_probes[1], matview_probes[2] });
    // Writes are 42809; REFRESH of a table 42809; dependents 2BP01.
    try rejects("INSERT INTO mv VALUES (9, 9, 9)", error.WrongObjectType, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("UPDATE mv SET n = 0", error.WrongObjectType, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("DELETE FROM mv", error.WrongObjectType, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("TRUNCATE mv", error.WrongObjectType, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("REFRESH MATERIALIZED VIEW a", error.WrongObjectType, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("REFRESH MATERIALIZED VIEW CONCURRENTLY mv", error.UnsupportedStatement, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("DROP TABLE a", error.DependentObjects, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try rejects("DROP VIEW mv", error.WrongObjectType, matview_probes[0], "1|31|2;2|30|2;3|50|1");
    // A view over a materialized view, and an index on one.
    try run("CREATE VIEW mvv AS SELECT g FROM mv WHERE n > 1");
    try expect("SELECT g FROM mvv ORDER BY g", "1;2");
    try rejects("DROP MATERIALIZED VIEW mv", error.DependentObjects, "SELECT g FROM mvv ORDER BY g", "1;2");
    try run("CREATE INDEX mv_g ON mv (g)");
    try run("REFRESH MATERIALIZED VIEW mv");
    try check(db.indexConsistent("mv").?);
    try sameState(&matview_probes);
    // REFRESH reads committed rows only: a live writer of the base table
    // neither blocks it nor shows up until the next REFRESH.
    const writer = try db.begin();
    try statement(writer, "INSERT INTO a VALUES (6, 1, 1)");
    const refresher = try db.begin();
    try statement(refresher, "REFRESH MATERIALIZED VIEW mv");
    try commit(refresher);
    try commit(writer);
    try expect(matview_probes[0], "1|31|2;2|30|2;3|50|1");
    try run("REFRESH MATERIALIZED VIEW mv");
    try expect(matview_probes[0], "1|32|3;2|30|2;3|50|1");
    try run("DROP MATERIALIZED VIEW mv CASCADE");
    try expect("SELECT relname FROM pg_class WHERE relkind IN ('m', 'v') ORDER BY relname", "later");
    try sameState(matview_probes[1..]);
}

// ---- CREATE TABLE variants (PG.DDL.CREATE_VARIANTS) -------------------------

fn createVariants() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT NOT NULL DEFAULT 7 CHECK (g > 0), v INT, label TEXT GENERATED ALWAYS AS ('v' || CAST(v AS TEXT)) STORED, UNIQUE (v))");
    try run("CREATE INDEX a_g ON a (g)");
    try run("INSERT INTO a (id, g, v) VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    // The oracle program in one transaction.
    const tx = try db.begin();
    try statement(tx, "CREATE TEMP TABLE tmp AS SELECT id FROM a");
    try statement(tx, "CREATE TABLE tdd_like (LIKE a INCLUDING ALL)");
    try same(try rows(tx, "SELECT * FROM tmp ORDER BY id"), "1;2;3;4");
    db.abort(tx);
    // CREATE TABLE AS: columns from the query (names, types, typmods), a
    // column list, WITH NO DATA; the rows are an ordinary insert.
    const copied = try replicate("CREATE TABLE ctas (k, doubled) AS SELECT id, v * 2 FROM a WHERE v IS NOT NULL");
    try check(copied.command == .create_table_as and copied.affected_rows == 3);
    try expect("SELECT k, doubled FROM ctas ORDER BY k", "1|20;2|40;3|60");
    try expect("SELECT attname, atttypid, attnotnull FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 'ctas' ORDER BY attnum", "k|23|f;doubled|23|f");
    try run("CREATE TABLE empty_copy AS SELECT id, label FROM a WITH NO DATA");
    try expect("SELECT COUNT(*) FROM empty_copy", "0");
    try run("CREATE TEMPORARY TABLE tmp AS SELECT id FROM a WHERE id > 2");
    try expect("SELECT * FROM tmp ORDER BY id", "3;4");
    try rejects("CREATE TABLE ctas AS SELECT 1 AS one", error.TableExists, "SELECT COUNT(*) FROM ctas", "3");
    try rejects("CREATE TABLE bad AS SELECT id, v AS id FROM a", error.DuplicateColumn, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (x, y, z) AS SELECT id FROM a", error.Syntax, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad AS SELECT id FROM missing", error.TableNotFound, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    // LIKE: columns and NOT NULL always; defaults, generation, CHECK,
    // primary key, UNIQUE and indexes with INCLUDING ALL (new names).
    try run("CREATE TABLE plain (LIKE a)");
    try expect("SELECT attname, attnotnull, atthasdef, attgenerated FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 'plain' ORDER BY attnum", "id|t|f|;g|t|f|;v|f|f|;label|f|f|");
    try expect("SELECT COUNT(*) FROM pg_indexes WHERE tablename = 'plain'", "0");
    try run("CREATE TABLE full_copy (extra INT, LIKE a INCLUDING ALL, tail TEXT)");
    try expect("SELECT attname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 'full_copy' ORDER BY attnum", "extra;id;g;v;label;tail");
    try expect("SELECT indexname FROM pg_indexes WHERE tablename = 'full_copy' ORDER BY indexname", "full_copy_g_idx;full_copy_pkey;full_copy_v_key");
    try run("INSERT INTO full_copy (extra, id, v) VALUES (0, 1, 5)");
    try expect("SELECT extra, id, g, v, label, tail FROM full_copy", "0|1|7|5|v5|NULL");
    try rejects("INSERT INTO full_copy (id, v) VALUES (1, 6)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM full_copy", "1");
    try rejects("INSERT INTO full_copy (id, g, v) VALUES (2, 0, 6)", error.CheckViolation, "SELECT COUNT(*) FROM full_copy", "1");
    try rejects("INSERT INTO full_copy (id, v) VALUES (2, 5)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM full_copy", "1");
    try rejects("CREATE TABLE bad (LIKE missing)", error.TableNotFound, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE TABLE bad (id INT, LIKE a)", error.DuplicateColumn, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try sameState(&[_][]const u8{
        "SELECT k, doubled FROM ctas ORDER BY k",
        "SELECT * FROM tmp ORDER BY id",
        "SELECT extra, id, g, v, label, tail FROM full_copy",
        "SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename, indexname",
        "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_schema = 'public' ORDER BY constraint_name",
        "SELECT relname, relnatts FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
    });
    // CREATE TABLE AS beside a live writer of its source (AccessShare and
    // RowExclusive are compatible) reads the committed rows only.
    const writer = try db.begin();
    try statement(writer, "INSERT INTO a (id, g, v) VALUES (9, 9, 90)");
    const reader = try db.begin();
    try statement(reader, "CREATE TABLE snap_copy AS SELECT id FROM a");
    try commit(writer);
    try commit(reader);
    try expect("SELECT COUNT(*) FROM snap_copy", "4");
    try sameState(&[_][]const u8{"SELECT id FROM snap_copy ORDER BY id"});
}

// ---- MERGE (PG.DML.MERGE) ---------------------------------------------------

const merge_probes = [_][]const u8{
    "SELECT id, g, v FROM a ORDER BY id",
    "SELECT id, v FROM b ORDER BY id",
};

fn mergeStatement() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    try run("CREATE TABLE b (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO b VALUES (1, 11), (3, 33), (5, 55)");
    // The oracle program.
    const merged = try replicate("MERGE INTO a a USING b b ON a.id=b.id WHEN MATCHED THEN UPDATE SET v=b.v WHEN NOT MATCHED THEN INSERT(id,g,v) VALUES(b.id,0,b.v)");
    try check(merged.command == .merge and merged.affected_rows == 3);
    try expect("SELECT id,v FROM a ORDER BY id", "1|11;2|20;3|33;4|NULL;5|55");
    // Conditions, DELETE, DO NOTHING, BY SOURCE and a subquery source.
    try run("INSERT INTO b VALUES (6, 66), (7, -1)");
    const second = try replicate("MERGE INTO a t USING (SELECT id, v FROM b WHERE id > 2) s ON t.id = s.id " ++
        "WHEN MATCHED AND s.v > 50 THEN DELETE WHEN MATCHED THEN UPDATE SET g = t.g + 10 " ++
        "WHEN NOT MATCHED AND s.v < 0 THEN DO NOTHING WHEN NOT MATCHED THEN INSERT VALUES (s.id, 6, s.v) " ++
        "WHEN NOT MATCHED BY SOURCE AND t.v IS NULL THEN UPDATE SET v = 0");
    try check(second.affected_rows == 4);
    try expect(merge_probes[0], "1|1|11;2|1|20;3|12|33;4|2|0;6|6|66");
    try run("MERGE INTO a USING b ON a.id = b.id WHEN NOT MATCHED BY SOURCE THEN DELETE");
    try expect(merge_probes[0], "1|1|11;3|12|33;6|6|66");
    // A target row matched twice is 21000; constraint violations roll the
    // whole MERGE back (23505, 23514, 23502).
    try run("CREATE TABLE dup (id INT, v INT)");
    try run("INSERT INTO dup VALUES (1, 100), (1, 200), (9, 9)");
    try rejects("MERGE INTO a USING dup ON a.id = dup.id WHEN MATCHED THEN UPDATE SET v = dup.v WHEN NOT MATCHED THEN INSERT VALUES (dup.id, 0, dup.v)", error.CardinalityViolation, merge_probes[0], "1|1|11;3|12|33;6|6|66");
    try run("MERGE INTO a USING dup ON a.id = dup.id WHEN MATCHED THEN DO NOTHING");
    try rejects("MERGE INTO a USING b ON a.id = b.id + 100 WHEN NOT MATCHED THEN INSERT VALUES (1, 0, b.v)", error.PrimaryKeyViolation, merge_probes[0], "1|1|11;3|12|33;6|6|66");
    try run("CREATE TABLE c (id INT PRIMARY KEY, v INT NOT NULL CHECK (v < 50))");
    try run("INSERT INTO c VALUES (1, 1), (5, 1)");
    try rejects("MERGE INTO c USING b ON c.id = b.id WHEN MATCHED THEN UPDATE SET v = b.v", error.CheckViolation, "SELECT id, v FROM c ORDER BY id", "1|1;5|1");
    try rejects("MERGE INTO c USING b ON c.id = b.id WHEN NOT MATCHED THEN INSERT (id) VALUES (b.id)", error.NotNullViolation, "SELECT id, v FROM c ORDER BY id", "1|1;5|1");
    // Names: 42703 for an unknown column, 42P01 for a missing source.
    try rejects("MERGE INTO a USING b ON a.id = b.id WHEN MATCHED THEN UPDATE SET missing = 1", error.ColumnNotFound, merge_probes[0], "1|1|11;3|12|33;6|6|66");
    try rejects("MERGE INTO a USING nope ON a.id = nope.id WHEN MATCHED THEN DELETE", error.TableNotFound, merge_probes[0], "1|1|11;3|12|33;6|6|66");
    try sameState(&merge_probes);
    // Concurrency: a matched row being updated by another transaction is
    // waited for and re-checked; the source table is AccessShare-locked, so
    // a DROP of it waits for the MERGE's transaction (STO-11).
    const writer = try db.begin();
    try statement(writer, "UPDATE a SET v = 1000 WHERE id = 1");
    const merger = try db.begin();
    try parks(merger, "MERGE INTO a USING b ON a.id = b.id WHEN MATCHED THEN UPDATE SET v = a.v + 1");
    try commit(writer);
    _ = try resumed(merger, "MERGE INTO a USING b ON a.id = b.id WHEN MATCHED THEN UPDATE SET v = a.v + 1");
    const dropper = try db.begin();
    try parks(dropper, "DROP TABLE b");
    try commit(merger);
    _ = try resumed(dropper, "DROP TABLE b");
    db.abort(dropper);
    try expect(merge_probes[0], "1|1|1001;3|12|34;6|6|67");
    try check(db.usage().transactions == 0 and db.usage().table_locks == 0);
    try sameState(&merge_probes);
}

// ---- composite, expression, partial and covering indexes (PG.INDEX.ADVANCED)

fn advancedIndexes() !void {
    reset();
    try run("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT)");
    try run("INSERT INTO a VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30), (4, 2, NULL)");
    // The oracle program in one transaction.
    const tx = try db.begin();
    try statement(tx, "CREATE INDEX tdd_adv ON a(g,(v+1)) INCLUDE(id) WHERE v IS NOT NULL");
    try same(try rows(tx, "SELECT indexname FROM pg_indexes WHERE indexname='tdd_adv'"), "tdd_adv");
    db.abort(tx);
    try run("CREATE INDEX a_adv ON a (g, (v + 1)) INCLUDE (id) WHERE v IS NOT NULL");
    try run("CREATE INDEX a_multi ON a (g DESC, v NULLS FIRST, id)");
    try run("CREATE INDEX ON a ((g * 2), (v - 1))");
    try expect("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'a' AND indexname <> 'a_pkey' ORDER BY indexname",
        "a_adv|CREATE INDEX a_adv ON public.a USING btree (g, (v + 1)) INCLUDE (id) WHERE (v IS NOT NULL);" ++
        "a_expr_expr1_idx|CREATE INDEX a_expr_expr1_idx ON public.a USING btree ((g * 2), (v - 1));" ++
        "a_multi|CREATE INDEX a_multi ON public.a USING btree (g DESC, v NULLS FIRST, id)");
    try expect("SELECT c.relname, c.relnatts, i.indkey FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname <> 'a_pkey' ORDER BY c.relname", "a_adv|3|2 0;a_expr_expr1_idx|2|0 0;a_multi|3|2 3 1");
    // Entries cover every version; probes over the plain key column g
    // equal scans through updates, deletes and an abort.
    try indexAgrees(&db, "a", "a_adv");
    try run("UPDATE a SET v = v + 1");
    try run("DELETE FROM a WHERE id = 2");
    const writer = try db.begin();
    try statement(writer, "INSERT INTO a VALUES (7, 1, 70)");
    db.abort(writer);
    try indexAgrees(&db, "a", "a_adv");
    const triple = [_]DB.Cell{ .{ .integer = 1 }, .{ .integer = 11 }, .{ .integer = 1 } };
    try check(try probeCount(&db, "a", "a_multi", &triple, true) == 1 and try probeCount(&db, "a", "a_multi", &triple, false) == 1);
    const absent = [_]DB.Cell{ .{ .integer = 2 }, .null_value, .{ .integer = 4 } };
    try check(try probeCount(&db, "a", "a_multi", &absent, true) == try probeCount(&db, "a", "a_multi", &absent, false));
    try indexAgrees(&db, "a", "a_expr_expr1_idx");
    // Expressions and predicates must be immutable (42P17), boolean
    // (42804) and name real columns (42703); subqueries are 0A000.
    const names = "SELECT indexname FROM pg_indexes WHERE tablename = 'a' ORDER BY indexname";
    const listed = "a_adv;a_expr_expr1_idx;a_multi;a_pkey";
    try rejects("CREATE INDEX bad ON a ((now()))", error.InvalidObjectDefinition, names, listed);
    try rejects("CREATE INDEX bad ON a (g) WHERE v", error.TypeMismatch, names, listed);
    try rejects("CREATE INDEX bad ON a ((missing + 1))", error.ColumnNotFound, names, listed);
    try rejects("CREATE INDEX bad ON a (g) INCLUDE (missing)", error.ColumnNotFound, names, listed);
    try rejects("CREATE INDEX bad ON a (g) INCLUDE (v, v)", error.DuplicateColumn, names, listed);
    try rejects("CREATE INDEX bad ON a (g) WHERE v IN (SELECT 1)", error.UnsupportedStatement, names, listed);
    try rejects("CREATE UNIQUE INDEX bad ON a (g) WHERE v > 0", error.UnsupportedStatement, names, listed);
    try sameState(&[_][]const u8{ "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY indexname", "SELECT id, g, v FROM a ORDER BY id" });
    try indexAgrees(&replica, "a", "a_adv");
    // Renames reach the stored texts; a dropped column drops its indexes.
    try run("ALTER TABLE a RENAME COLUMN v TO w");
    try expect("SELECT indexdef FROM pg_indexes WHERE indexname = 'a_adv'", "CREATE INDEX a_adv ON public.a USING btree (g, (w + 1)) INCLUDE (id) WHERE (w IS NOT NULL)");
    try run("ALTER TABLE a DROP COLUMN w");
    try expect(names, "a_pkey");
    try run("CREATE INDEX a_cover ON a (g) INCLUDE (id)");
    try sameState(&[_][]const u8{ "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY indexname", "SELECT relname, relnatts FROM pg_class WHERE relnamespace = 2200 ORDER BY oid" });
}

// ---- virtual generated columns (PG.DDL.VIRTUAL) -----------------------------

fn virtualColumns() !void {
    reset();
    // The oracle program in one transaction.
    const tx = try db.begin();
    try statement(tx, "CREATE TABLE tdd_vg(v INT,doubled INT GENERATED ALWAYS AS(v*2) VIRTUAL)");
    try statement(tx, "INSERT INTO tdd_vg(v) VALUES(3)");
    try same(try rows(tx, "SELECT * FROM tdd_vg"), "3|6");
    db.abort(tx);
    // VIRTUAL is PostgreSQL 18's default; STORED stays stored.
    try run("CREATE TABLE vg (v INT, doubled INT GENERATED ALWAYS AS (v * 2) VIRTUAL, tripled INT GENERATED ALWAYS AS (v * 3), kept INT GENERATED ALWAYS AS (v + 1) STORED)");
    try run("INSERT INTO vg (v) VALUES (3), (NULL)");
    try expect("SELECT v, doubled, tripled, kept FROM vg ORDER BY v", "3|6|9|4;NULL|NULL|NULL|NULL");
    try run("UPDATE vg SET v = 5 WHERE v = 3");
    try expect("SELECT doubled, tripled, kept FROM vg WHERE v = 5", "10|15|6");
    try expect("SELECT attname, attgenerated FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 'vg' ORDER BY attnum", "v|;doubled|v;tripled|v;kept|s");
    try expect("SELECT column_name, is_generated, generation_expression FROM information_schema.columns WHERE table_name = 'vg' AND is_generated = 'ALWAYS' ORDER BY ordinal_position", "doubled|ALWAYS|(v * 2);tripled|ALWAYS|(v * 3);kept|ALWAYS|(v + 1)");
    // Values cannot be written (428C9); expressions must be immutable and
    // reference no generated column; indexes on them are 0A000.
    try rejects("INSERT INTO vg (v, doubled) VALUES (1, 2)", error.GeneratedAlways, "SELECT COUNT(*) FROM vg", "2");
    try rejects("UPDATE vg SET doubled = 1", error.GeneratedAlways, "SELECT COUNT(*) FROM vg", "2");
    try rejects("CREATE TABLE bad (t TIMESTAMPTZ GENERATED ALWAYS AS (now()) VIRTUAL)", error.InvalidObjectDefinition, "SELECT COUNT(*) FROM pg_class WHERE relname = 'bad'", "0");
    try rejects("CREATE INDEX vg_doubled ON vg (doubled)", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_indexes WHERE tablename = 'vg'", "0");
    try sameState(&[_][]const u8{
        "SELECT v, doubled, tripled, kept FROM vg ORDER BY v",
        "SELECT attname, attgenerated FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 'vg' ORDER BY attnum",
    });
}

pub fn main() !void {
    try secondaryIndexes();
    try indexCapacity();
    try upsertUnique();
    try foreignKeys();
    try deferredConstraints();
    try views();
    try viewCapacity();
    try materializedViews();
    try createVariants();
    try mergeStatement();
    try advancedIndexes();
    try virtualColumns();
    std.debug.print("schema objects: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
