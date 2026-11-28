//! DDL / DML contracts (conformance lane B11, wave 4, ddl-dml): TRUNCATE
//! ONLY, UPDATE / DELETE through inheritance parents and partitioned tables
//! (row movement), INHERITS column merging, ATTACH / DETACH PARTITION,
//! PRIMARY KEY / UNIQUE / ON CONFLICT on partitioned tables and foreign
//! keys checked as their statement ends. Each section checks values
//! (PostgreSQL 18 text output), exact errors (SQLSTATE through the error
//! name), atomicity after a failure, concurrency where a lock decides, and
//! replay: every committed record is applied to a replica that must answer
//! every probe exactly like the primary. Expectations were checked against
//! native PostgreSQL 18.7 (row order only where PostgreSQL defines it).
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 16, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 1024 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("ddl-dml contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.DdlDmlContractFailed;
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

/// The statement's command count and rendered RETURNING rows.
fn affects(source: []const u8, count: usize, returned: []const u8) !void {
    const result = try replicate(source);
    if (result.affected_rows != count) std.debug.print("{s}: affected {d}, wanted {d}\n", .{ source, result.affected_rows, count });
    try check(result.affected_rows == count);
    try same(try render(&result), returned);
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

fn resumed(slot: u16, source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{ .@"resume" = true });
    return result;
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

// ---- TRUNCATE ONLY -----------------------------------------------------------

fn truncateOnly() !void {
    reset();
    try run("CREATE TABLE tp (id INT, v TEXT)");
    try run("CREATE TABLE tc (extra INT) INHERITS (tp)");
    try run("CREATE TABLE tg () INHERITS (tc)");
    const fill = "INSERT INTO tp VALUES (1, 'p')";
    try run(fill);
    try run("INSERT INTO tc VALUES (2, 'c', 20)");
    try run("INSERT INTO tg VALUES (3, 'g', 30)");
    const all = "SELECT id FROM tp ORDER BY id";
    // ONLY keeps the children; a listed child keeps its own children.
    try run("TRUNCATE ONLY tp");
    try expect(all, "2;3");
    try run(fill);
    try run("TRUNCATE ONLY tc");
    try expect(all, "1;3");
    try sameState(&.{all});
    // A child named with ONLY is still reached through a parent without it.
    try run("INSERT INTO tc VALUES (2, 'c', 20)");
    try run("TRUNCATE TABLE ONLY tc, tp");
    try expect(all, "");
    try run(fill);
    try run("INSERT INTO tg VALUES (3, 'g', 30)");
    // `name *` is the whole family, as without ONLY.
    try run("TRUNCATE ONLY tp, tc *");
    try expect(all, "");
    // A partitioned table holds no rows: ONLY is 42809.
    try run("CREATE TABLE pt (k INT) PARTITION BY LIST (k)");
    try run("CREATE TABLE pt1 PARTITION OF pt FOR VALUES IN (1)");
    try run("INSERT INTO pt VALUES (1)");
    try rejects("TRUNCATE ONLY pt", error.WrongObjectType, "SELECT k FROM pt", "1");
    try run("TRUNCATE ONLY pt1");
    try expect("SELECT COUNT(*) FROM pt", "0");
    try sameState(&.{ all, "SELECT k FROM pt" });
}

// ---- UPDATE / DELETE through an inheritance parent ---------------------------

const family_probes = [_][]const u8{
    "SELECT id, v FROM fa ORDER BY id",
    "SELECT id, v FROM ONLY fa ORDER BY id",
    "SELECT id, v, w FROM fb ORDER BY id",
};

fn familyWrites() !void {
    reset();
    try run("CREATE TABLE fa (id INT PRIMARY KEY, v INT CHECK (v < 100))");
    try run("CREATE TABLE fb (w INT) INHERITS (fa)");
    try run("CREATE TABLE fc () INHERITS (fb)");
    try run("INSERT INTO fa VALUES (1, 10), (2, 20)");
    try run("INSERT INTO fb VALUES (3, 30, 1), (4, 40, 2)");
    try run("INSERT INTO fc VALUES (5, 50, 3)");
    // Every member's rows, through grandchildren; ONLY keeps the parent's.
    try affects("UPDATE fa SET v = v + 1 WHERE id % 2 = 1", 3, "");
    try expect(family_probes[0], "1|11;2|20;3|31;4|40;5|51");
    // RETURNING reads the parent's columns of every member's row; the
    // statement's name (or alias) qualifies the columns of each member.
    try affects("UPDATE fa SET v = fa.v * 2 WHERE fa.id = 3 RETURNING *", 1, "3|62");
    try affects("UPDATE fa AS x SET v = x.v - 1 WHERE x.id = 5 RETURNING x.id, x.v", 1, "5|50");
    try affects("UPDATE ONLY fa SET v = 0", 2, "");
    try expect(family_probes[0], "1|0;2|0;3|62;4|40;5|50");
    // UPDATE ... FROM joins each member.
    try affects("UPDATE fa SET v = s.n FROM (VALUES (4, 7), (5, 8)) AS s (id, n) WHERE fa.id = s.id", 2, "");
    try expect(family_probes[0], "1|0;2|0;3|62;4|7;5|8");
    // A member's own CHECK fails the whole statement (23514), as does an
    // inherited one; nothing changes in any member.
    try run("ALTER TABLE fb ADD CONSTRAINT fb_v CHECK (v <> 99)");
    try rejects("UPDATE fa SET v = 99", error.CheckViolation, family_probes[0], "1|0;2|0;3|62;4|7;5|8");
    try rejects("UPDATE fa SET v = 100 WHERE id = 5", error.CheckViolation, family_probes[0], "1|0;2|0;3|62;4|7;5|8");
    try expect(family_probes[2], "3|62|1;4|7|2;5|8|3");
    try sameState(&family_probes);
    // DELETE through a parent, USING, RETURNING and ONLY.
    try affects("DELETE FROM fa USING (VALUES (4)) AS s (id) WHERE fa.id = s.id", 1, "");
    try affects("DELETE FROM fb WHERE v > 7 RETURNING id", 2, "3;5");
    try affects("DELETE FROM ONLY fb", 0, "");
    try affects("DELETE FROM fa RETURNING id, v", 2, "1|0;2|0");
    try expect("SELECT COUNT(*) FROM fa", "0");
    try sameState(&family_probes);
    // Privileges are the parent's (a child needs its own for direct access).
    try run("INSERT INTO fa VALUES (1, 1)");
    try run("INSERT INTO fc VALUES (2, 2, 2)");
    try run("CREATE ROLE fr");
    try run("GRANT SELECT, UPDATE ON fa TO fr");
    try run("SET ROLE fr");
    try affects("UPDATE fa SET v = 5 WHERE id = 2", 1, "");
    try rejects("UPDATE fc SET v = 6", error.InsufficientPrivilege, "SELECT v FROM fa ORDER BY id", "1;5");
    try rejects("DELETE FROM fa", error.InsufficientPrivilege, "SELECT v FROM fa ORDER BY id", "1;5");
    try run("RESET ROLE");
    // A member's row another transaction is updating: the parent's UPDATE
    // waits for it and then sees the committed row (READ COMMITTED).
    const writer = try db.begin();
    try statement(writer, "UPDATE fc SET v = 30 WHERE id = 2");
    const reader = try db.begin();
    try parks(reader, "UPDATE fa SET v = v * 2");
    try commit(writer);
    const done = try resumed(reader, "UPDATE fa SET v = v * 2");
    try check(done.affected_rows == 2);
    try same(try rows(reader, family_probes[0]), "1|2;2|60");
    try commit(reader);
    try expect(family_probes[0], "1|2;2|60");
    // A failed member statement inside a transaction leaves earlier ones.
    const tx = try db.begin();
    try statement(tx, "UPDATE fa SET v = 1");
    try statementFails(tx, "UPDATE fa SET v = 100", error.CheckViolation);
    try same(try rows(tx, family_probes[0]), "1|1;2|1");
    try commit(tx);
    try sameState(&family_probes);
}

// ---- UPDATE / DELETE through a partitioned table: row movement ---------------

const movement_probes = [_][]const u8{
    "SELECT id, k, v FROM r ORDER BY id",
    "SELECT id FROM r1 ORDER BY id",
    "SELECT id FROM r2 ORDER BY id",
    "SELECT id, k FROM rd ORDER BY id",
};

fn rowMovement() !void {
    reset();
    try run("CREATE TABLE r (id INT, k INT, v TEXT) PARTITION BY RANGE (k)");
    try run("CREATE TABLE r1 PARTITION OF r FOR VALUES FROM (0) TO (10)");
    try run("CREATE TABLE r2 PARTITION OF r FOR VALUES FROM (10) TO (20)");
    try run("CREATE TABLE rd PARTITION OF r DEFAULT");
    try run("ALTER TABLE r2 ADD CONSTRAINT r2_v CHECK (v <> 'no')");
    try run("INSERT INTO r VALUES (1, 5, 'a'), (2, 15, 'b'), (3, 25, 'c')");
    // A new key outside the row's partition moves the row; RETURNING
    // reports it once, with its new values.
    try affects("UPDATE r SET k = 12 WHERE id = 1 RETURNING id, k, v", 1, "1|12|a");
    try expect(movement_probes[1], "");
    try expect(movement_probes[2], "1;2");
    try affects("UPDATE r SET k = k + 10 WHERE k < 20", 2, "");
    try expect(movement_probes[3], "1|22;2|25;3|25");
    try sameState(&movement_probes);
    // The destination's constraints apply, not the source's.
    try affects("UPDATE r SET k = 5, v = 'no' WHERE id = 1", 1, "");
    try expect("SELECT id, k, v FROM r1", "1|5|no");
    try rejects("UPDATE r SET k = 15 WHERE id = 1", error.CheckViolation, movement_probes[0], "1|5|no;2|25|b;3|25|c");
    // A partition's own UPDATE keeps its bound (no movement): 23514.
    try rejects("UPDATE r1 SET k = 15", error.CheckViolation, movement_probes[0], "1|5|no;2|25|b;3|25|c");
    // A NULL key moves to the DEFAULT partition.
    try affects("UPDATE r SET k = NULL WHERE id = 2 RETURNING id, k", 1, "2|NULL");
    try expect(movement_probes[3], "2|NULL;3|25");
    try affects("UPDATE r SET v = 'z' WHERE id IN (1, 3)", 2, "");
    try expect(movement_probes[0], "1|5|z;2|NULL|b;3|25|z");
    try affects("DELETE FROM r WHERE k IS NULL OR k < 10 RETURNING id", 2, "1;2");
    try affects("UPDATE r SET k = 2, v = 'm' WHERE id = 3", 1, "");
    try expect("SELECT id, k, v FROM r1 ORDER BY id", "3|2|m");
    try sameState(&movement_probes);
    // Rows trade partitions in one statement: each moves once.
    try run("CREATE TABLE q (id INT, k INT) PARTITION BY LIST (k)");
    try run("CREATE TABLE q1 PARTITION OF q FOR VALUES IN (1)");
    try run("CREATE TABLE q2 PARTITION OF q FOR VALUES IN (2)");
    try run("INSERT INTO q VALUES (1, 1), (2, 2)");
    try affects("UPDATE q SET k = 3 - k", 2, "");
    try expect("SELECT id, k FROM q1", "2|1");
    try expect("SELECT id, k FROM q2", "1|2");
    // No partition for the new key: 23514 and nothing moved.
    try rejects("UPDATE q SET k = 3", error.CheckViolation, "SELECT id, k FROM q ORDER BY id", "1|2;2|1");
    try rejects("UPDATE q2 SET k = 1", error.CheckViolation, "SELECT id, k FROM q ORDER BY id", "1|2;2|1");
    try sameState(&.{ "SELECT id, k FROM q1", "SELECT id, k FROM q2" });
    // A moving row waits for another writer of it; the moved row is the
    // committed version, rerouted.
    const writer = try db.begin();
    try statement(writer, "UPDATE q1 SET id = 20");
    const mover = try db.begin();
    try parks(mover, "UPDATE q SET k = 2 WHERE k = 1");
    try commit(writer);
    const moved = try resumed(mover, "UPDATE q SET k = 2 WHERE k = 1");
    try check(moved.affected_rows == 1);
    try commit(mover);
    try expect("SELECT id, k FROM q2 ORDER BY id", "1|2;20|2");
    try expect("SELECT COUNT(*) FROM q1", "0");
    try sameState(&.{ "SELECT id, k FROM q1", "SELECT id, k FROM q2" });
}

// ---- INHERITS merges same-named columns --------------------------------------

fn inheritsMerge() !void {
    reset();
    try run("CREATE TABLE m (id INT NOT NULL, v TEXT DEFAULT 'pv', w INT CHECK (w > 0))");
    // A local column named like a parent column merges into the parent's
    // position: NOT NULL from either, the local DEFAULT wins.
    try run("CREATE TABLE mc (z INT, v TEXT DEFAULT 'cv', id INT) INHERITS (m)");
    const columns = "SELECT column_name, is_nullable, column_default FROM information_schema.columns WHERE table_name = 'mc' ORDER BY ordinal_position";
    try expect(columns, "id|NO|NULL;v|YES|'cv'::text;w|YES|NULL;z|YES|NULL");
    try run("INSERT INTO mc (id) VALUES (1)");
    try expect("SELECT * FROM mc", "1|cv|NULL|NULL");
    try expect("SELECT id, v FROM m", "1|cv");
    try rejects("INSERT INTO mc (id, w) VALUES (2, 0)", error.CheckViolation, "SELECT COUNT(*) FROM mc", "1");
    try run("CREATE TABLE mc4 (w INT NOT NULL CHECK (w < 10)) INHERITS (m)");
    // PostgreSQL 18 NOT NULL constraints (ddl-alter): an inherited one keeps
    // the parent's name.
    try expect("SELECT conname FROM pg_constraint WHERE conrelid = 'mc4'::regclass ORDER BY 1", "m_id_not_null;m_w_check;mc4_w_check;mc4_w_not_null");
    try rejects("INSERT INTO mc4 (id, w) VALUES (1, NULL)", error.NotNullViolation, "SELECT COUNT(*) FROM mc4", "0");
    try rejects("INSERT INTO mc4 (id, w) VALUES (1, 10)", error.CheckViolation, "SELECT COUNT(*) FROM mc4", "0");
    // An empty element list inherits every column.
    try run("CREATE TABLE me () INHERITS (m)");
    try expect("SELECT column_name FROM information_schema.columns WHERE table_name = 'me' ORDER BY ordinal_position", "id;v;w");
    const names = "SELECT relname FROM pg_class WHERE relname LIKE 'm%' AND relkind = 'r' ORDER BY relname";
    // Type (and typmod) conflicts are 42804; merging identity or generated
    // columns is outside the subset (0A000).
    try rejects("CREATE TABLE bad (id BIGINT) INHERITS (m)", error.TypeMismatch, names, "m;mc;mc4;me");
    try rejects("CREATE TABLE bad (v VARCHAR(3)) INHERITS (m)", error.TypeMismatch, names, "m;mc;mc4;me");
    try rejects("CREATE TABLE bad (id INT GENERATED ALWAYS AS IDENTITY) INHERITS (m)", error.UnsupportedStatement, names, "m;mc;mc4;me");
    // Neither a partitioned table nor a partition can be a parent (42809).
    try run("CREATE TABLE pa (a INT) PARTITION BY LIST (a)");
    try run("CREATE TABLE pa1 PARTITION OF pa FOR VALUES IN (1)");
    try rejects("CREATE TABLE bad () INHERITS (pa)", error.WrongObjectType, names, "m;mc;mc4;me");
    try rejects("CREATE TABLE bad () INHERITS (pa1)", error.WrongObjectType, names, "m;mc;mc4;me");
    try rejects("CREATE TABLE bad ()", error.UnsupportedStatement, names, "m;mc;mc4;me");
    try sameState(&.{ columns, "SELECT * FROM m ORDER BY id", names });
}

// ---- ATTACH / DETACH PARTITION -------------------------------------------------

const attach_probes = [_][]const u8{
    "SELECT id, k, v FROM al ORDER BY id",
    "SELECT inhrelid::regclass::text, inhparent::regclass::text FROM pg_inherits ORDER BY 1",
    "SELECT relname, relispartition FROM pg_class WHERE relname LIKE 'x%' ORDER BY relname",
};

fn attachDetach() !void {
    reset();
    try run("CREATE TABLE al (id INT, k INT NOT NULL, v TEXT) PARTITION BY LIST (k)");
    try run("CREATE TABLE al1 PARTITION OF al FOR VALUES IN (1)");
    try run("CREATE TABLE x1 (id INT, k INT NOT NULL, v TEXT)");
    try run("INSERT INTO x1 VALUES (1, 2, 'a')");
    // Rows outside the bound (23514) and overlapping bounds (42P17).
    try rejects("ALTER TABLE al ATTACH PARTITION x1 FOR VALUES IN (3)", error.CheckViolation, attach_probes[0], "");
    try rejects("ALTER TABLE al ATTACH PARTITION x1 FOR VALUES IN (1)", error.InvalidObjectDefinition, attach_probes[0], "");
    const attached = try replicate("ALTER TABLE al ATTACH PARTITION x1 FOR VALUES IN (2)");
    try check(attached.command == .alter_table and attached.affected_rows == 0);
    try expect(attach_probes[0], "1|2|a");
    try expect(attach_probes[1], "al1|al;x1|al");
    // The attached partition keeps its bound for direct writes and routes.
    try run("INSERT INTO al VALUES (2, 2, 'b')");
    try rejects("INSERT INTO x1 VALUES (3, 1, 'c')", error.CheckViolation, attach_probes[0], "1|2|a;2|2|b");
    try rejects("ALTER TABLE al ATTACH PARTITION x1 FOR VALUES IN (4)", error.WrongObjectType, attach_probes[0], "1|2|a;2|2|b");
    try sameState(&attach_probes);
    // DETACH: a standalone table again, keeping its rows.
    try run("ALTER TABLE al DETACH PARTITION x1");
    try expect(attach_probes[0], "");
    try expect("SELECT id FROM x1 ORDER BY id", "1;2");
    try run("INSERT INTO x1 VALUES (3, 9, 'free')");
    try rejects("ALTER TABLE al DETACH PARTITION x1", error.TableNotFound, attach_probes[1], "al1|al");
    // Column checks (42804), reordered columns (0A000), an inheritance
    // child (42809), a table that is not partitioned (42809).
    try run("CREATE TABLE x2 (id INT, k INT, v TEXT)");
    try rejects("ALTER TABLE al ATTACH PARTITION x2 FOR VALUES IN (5)", error.TypeMismatch, attach_probes[1], "al1|al");
    try run("CREATE TABLE x3 (id INT, k INT NOT NULL, v TEXT, z INT)");
    try rejects("ALTER TABLE al ATTACH PARTITION x3 FOR VALUES IN (5)", error.TypeMismatch, attach_probes[1], "al1|al");
    try run("CREATE TABLE x4 (id BIGINT, k INT NOT NULL, v TEXT)");
    try rejects("ALTER TABLE al ATTACH PARTITION x4 FOR VALUES IN (5)", error.TypeMismatch, attach_probes[1], "al1|al");
    try run("CREATE TABLE x6 (id INT, k INT NOT NULL)");
    try rejects("ALTER TABLE al ATTACH PARTITION x6 FOR VALUES IN (6)", error.TypeMismatch, attach_probes[1], "al1|al");
    try run("CREATE TABLE x5 (k INT NOT NULL, id INT, v TEXT)");
    try rejects("ALTER TABLE al ATTACH PARTITION x5 FOR VALUES IN (5)", error.UnsupportedStatement, attach_probes[1], "al1|al");
    try run("CREATE TABLE xp (id INT, k INT NOT NULL, v TEXT)");
    try run("CREATE TABLE xc () INHERITS (xp)");
    try rejects("ALTER TABLE al ATTACH PARTITION xc FOR VALUES IN (8)", error.WrongObjectType, attach_probes[1], "al1|al;xc|xp");
    try rejects("ALTER TABLE al ATTACH PARTITION xp FOR VALUES IN (8)", error.WrongObjectType, attach_probes[1], "al1|al;xc|xp");
    try rejects("ALTER TABLE x1 ATTACH PARTITION x2 FOR VALUES IN (7)", error.WrongObjectType, attach_probes[1], "al1|al;xc|xp");
    try rejects("ALTER TABLE al DETACH PARTITION al1 FINALIZE", error.UnsupportedStatement, attach_probes[1], "al1|al;xc|xp");
    // A DEFAULT partition gives up the attached bound: its rows are checked.
    try run("CREATE TABLE ald PARTITION OF al DEFAULT");
    try run("INSERT INTO al VALUES (7, 7, 'd')");
    try run("CREATE TABLE x7 (id INT, k INT NOT NULL, v TEXT)");
    try rejects("ALTER TABLE al ATTACH PARTITION x7 FOR VALUES IN (7)", error.CheckViolation, attach_probes[1], "al1|al;ald|al;xc|xp");
    try rejects("ALTER TABLE al ATTACH PARTITION x7 DEFAULT", error.InvalidObjectDefinition, attach_probes[1], "al1|al;ald|al;xc|xp");
    try run("ALTER TABLE al ATTACH PARTITION x7 FOR VALUES IN (8)");
    try run("INSERT INTO al VALUES (8, 8, 'e')");
    try expect("SELECT id FROM x7", "8");
    // CONCURRENTLY detaches like the plain form here.
    try run("ALTER TABLE al DETACH PARTITION al1 CONCURRENTLY");
    try expect(attach_probes[1], "ald|al;x7|al;xc|xp");
    try run("INSERT INTO al VALUES (9, 1, 'f')");
    try expect("SELECT id FROM ald ORDER BY id", "7;9");
    try sameState(&attach_probes);
    // ATTACH waits behind a reader of the attached table (AccessExclusive)
    // and does not block a reader of the partitioned table's other rows
    // (SHARE UPDATE EXCLUSIVE on the parent).
    const reader = try db.begin();
    try same(try rows(reader, "SELECT COUNT(*) FROM x1"), "3");
    const attacher = try db.begin();
    try parks(attacher, "ALTER TABLE al ATTACH PARTITION x1 FOR VALUES IN (2, 3, 9)");
    try commit(reader);
    try check((try resumed(attacher, "ALTER TABLE al ATTACH PARTITION x1 FOR VALUES IN (2, 3, 9)")).command == .alter_table);
    try commit(attacher);
    try expect(attach_probes[0], "1|2|a;2|2|b;3|9|free;7|7|d;8|8|e;9|1|f");
    try sameState(&attach_probes);
}

// ---- PRIMARY KEY / UNIQUE / ON CONFLICT on partitioned tables --------------

fn partitionKeys() !void {
    reset();
    const names = "SELECT tablename FROM pg_tables WHERE tablename LIKE 'pk%' ORDER BY 1";
    // The key must include the partition key (0A000).
    try rejects("CREATE TABLE pk (id INT PRIMARY KEY, k INT) PARTITION BY RANGE (k)", error.UnsupportedStatement, names, "");
    try rejects("CREATE TABLE pk (id INT, k INT, UNIQUE (id)) PARTITION BY LIST (k)", error.UnsupportedStatement, names, "");
    try run("CREATE TABLE pk2 (id INT, k INT, PRIMARY KEY (id, k)) PARTITION BY RANGE (k)");
    try run("CREATE TABLE pk2a PARTITION OF pk2 FOR VALUES FROM (0) TO (10)");
    try run("CREATE TABLE pk2b PARTITION OF pk2 FOR VALUES FROM (10) TO (20)");
    try expect("SELECT conname, contype FROM pg_constraint WHERE conrelid IN ('pk2'::regclass, 'pk2a'::regclass) AND contype <> 'n' ORDER BY 1", "pk2_pkey|p;pk2a_pkey|p");
    const all = "SELECT id, k FROM pk2 ORDER BY 1, 2";
    try run("INSERT INTO pk2 VALUES (1, 1)");
    try rejects("INSERT INTO pk2 VALUES (1, 1)", error.PrimaryKeyViolation, all, "1|1");
    try run("INSERT INTO pk2 VALUES (1, 11)");
    // ON CONFLICT arbitrates with the routed partition's key.
    try affects("INSERT INTO pk2 VALUES (1, 1) ON CONFLICT DO NOTHING", 0, "");
    try affects("INSERT INTO pk2 VALUES (1, 1) ON CONFLICT (id, k) DO UPDATE SET id = 7 RETURNING *", 1, "7|1");
    // DO UPDATE never moves a row across partitions (0A000); an arbiter
    // that is not a key is 42P10.
    try rejects("INSERT INTO pk2 VALUES (7, 1) ON CONFLICT (id, k) DO UPDATE SET k = 15", error.UnsupportedStatement, all, "1|11;7|1");
    try rejects("INSERT INTO pk2 VALUES (2, 2) ON CONFLICT (id) DO NOTHING", error.InvalidColumnReference, all, "1|11;7|1");
    try affects("INSERT INTO pk2 VALUES (7, 1), (8, 12) ON CONFLICT ON CONSTRAINT pk2_pkey DO UPDATE SET id = excluded.id * 10 RETURNING *", 2, "70|1;8|12");
    try expect(all, "1|11;8|12;70|1");
    // Row movement keeps the keys (here into a free key).
    try affects("UPDATE pk2 SET k = 11 WHERE id = 70", 1, "");
    try expect(all, "1|11;8|12;70|11");
    try sameState(&.{ all, names });
    // NULLS NOT DISTINCT and a single-column key equal to the partition key.
    try run("CREATE TABLE pk4 (id INT, k INT, UNIQUE NULLS NOT DISTINCT (id, k)) PARTITION BY LIST (k)");
    try run("CREATE TABLE pk4a PARTITION OF pk4 FOR VALUES IN (1)");
    try rejects("INSERT INTO pk4 VALUES (NULL, 1), (NULL, 1)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM pk4", "0");
    try run("CREATE TABLE pks (k INT PRIMARY KEY, v TEXT) PARTITION BY LIST (k)");
    try run("CREATE TABLE pks1 PARTITION OF pks FOR VALUES IN (1, 2)");
    try run("CREATE TABLE pks2 PARTITION OF pks FOR VALUES IN (3)");
    try run("INSERT INTO pks VALUES (1, 'a'), (3, 'c')");
    try affects("INSERT INTO pks VALUES (1, 'b') ON CONFLICT (k) DO UPDATE SET v = excluded.v RETURNING *", 1, "1|b");
    try rejects("INSERT INTO pks VALUES (3, 'z') ON CONFLICT (k) DO UPDATE SET k = 2", error.UnsupportedStatement, "SELECT k, v FROM pks ORDER BY k", "1|b;3|c");
    // ATTACH gives the partition the parent's key, checked over its rows.
    try run("CREATE TABLE pk5 (id INT, k INT, PRIMARY KEY (id, k)) PARTITION BY LIST (k)");
    try run("CREATE TABLE pkx (id INT NOT NULL, k INT NOT NULL)");
    try run("INSERT INTO pkx VALUES (1, 3), (1, 3)");
    try rejects("ALTER TABLE pk5 ATTACH PARTITION pkx FOR VALUES IN (3)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM pk5", "0");
    try run("DELETE FROM pkx WHERE id = 1");
    try run("INSERT INTO pkx VALUES (1, 3), (2, 3)");
    try run("ALTER TABLE pk5 ATTACH PARTITION pkx FOR VALUES IN (3)");
    try expect("SELECT conname FROM pg_constraint WHERE conrelid = 'pkx'::regclass AND contype <> 'n'", "pkx_pkey");
    try rejects("INSERT INTO pk5 VALUES (2, 3)", error.PrimaryKeyViolation, "SELECT id FROM pk5 ORDER BY id", "1;2");
    try run("CREATE TABLE pky (id INT, k INT)");
    try rejects("ALTER TABLE pk5 ATTACH PARTITION pky FOR VALUES IN (4)", error.TypeMismatch, "SELECT COUNT(*) FROM pg_inherits", "6");
    try run("CREATE TABLE pkz (k INT NOT NULL, v TEXT)");
    try run("INSERT INTO pkz VALUES (5, 'e')");
    try run("ALTER TABLE pks ATTACH PARTITION pkz FOR VALUES IN (5)");
    try rejects("INSERT INTO pks VALUES (5, 'f')", error.PrimaryKeyViolation, "SELECT k, v FROM pks ORDER BY k", "1|b;3|c;5|e");
    try sameState(&.{ all, names, "SELECT k, v FROM pks ORDER BY k", "SELECT id, k FROM pk5 ORDER BY id" });
}

// ---- foreign keys checked as the statement ends ----------------------------

fn foreignKeyTiming() !void {
    reset();
    // A row may reference one inserted later in the same statement.
    try run("CREATE TABLE t (id INT PRIMARY KEY, parent INT REFERENCES t)");
    try affects("INSERT INTO t VALUES (1, 2), (2, 1)", 2, "");
    try expect("SELECT id, parent FROM t ORDER BY id", "1|2;2|1");
    // Deleting every row of a self-referencing table is consistent at the
    // end of the statement (NO ACTION and RESTRICT alike).
    try affects("DELETE FROM t", 2, "");
    try run("CREATE TABLE tr (id INT PRIMARY KEY, parent INT REFERENCES tr ON DELETE RESTRICT)");
    try run("INSERT INTO tr VALUES (1, NULL), (2, 1)");
    try affects("DELETE FROM tr", 2, "");
    // A foreign key added by ALTER TABLE may reference its own table.
    try run("CREATE TABLE s (id INT PRIMARY KEY, ref INT)");
    try run("ALTER TABLE s ADD FOREIGN KEY (ref) REFERENCES s");
    try run("INSERT INTO s VALUES (1, 1)");
    try affects("UPDATE s SET id = 2, ref = 2", 1, "");
    try expect("SELECT id, ref FROM s", "2|2");
    try rejects("INSERT INTO s VALUES (3, 4)", error.ForeignKeyViolation, "SELECT id, ref FROM s", "2|2");
    // NO ACTION: a removed key that is live again by the end is fine;
    // RESTRICT fails whenever a changed key is referenced (23001).
    try run("CREATE TABLE p (id INT PRIMARY KEY, v INT UNIQUE)");
    try run("CREATE TABLE c (pid INT REFERENCES p (v))");
    try run("INSERT INTO p VALUES (1, 10), (2, 20)");
    try run("INSERT INTO c VALUES (10)");
    try affects("UPDATE p SET v = CASE v WHEN 10 THEN 30 WHEN 20 THEN 10 END", 2, "");
    try expect("SELECT id, v FROM p ORDER BY id", "1|30;2|10");
    try run("CREATE TABLE cr (pid INT REFERENCES p (v) ON UPDATE RESTRICT ON DELETE RESTRICT)");
    try run("INSERT INTO cr VALUES (30)");
    try rejects("UPDATE p SET v = CASE v WHEN 30 THEN 15 WHEN 10 THEN 30 END WHERE id >= 1", error.RestrictViolation, "SELECT id, v FROM p ORDER BY id", "1|30;2|10");
    try rejects("DELETE FROM p WHERE id = 1", error.RestrictViolation, "SELECT id, v FROM p ORDER BY id", "1|30;2|10");
    try affects("UPDATE p SET id = id + 5", 2, "");
    try rejects("DELETE FROM p WHERE id = 7", error.ForeignKeyViolation, "SELECT id, v FROM p ORDER BY id", "6|30;7|10");
    try rejects("INSERT INTO c VALUES (5)", error.ForeignKeyViolation, "SELECT pid FROM c", "10");
    // A deferrable RESTRICT constraint is still checked when the statement
    // ends, not at COMMIT.
    try run("CREATE TABLE cd (pid INT REFERENCES p (v) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED)");
    try run("INSERT INTO cd VALUES (10)");
    try run("DELETE FROM c");
    const tx = try db.begin();
    try statementFails(tx, "DELETE FROM p WHERE id = 7", error.RestrictViolation);
    try same(try rows(tx, "SELECT id FROM p ORDER BY id"), "6;7");
    try commit(tx);
    // Within a transaction: a statement that fails its end check rolls
    // back alone; a later statement may make the earlier ones consistent.
    try run("DELETE FROM cd");
    const tx2 = try db.begin();
    try statement(tx2, "INSERT INTO c VALUES (10)");
    try statementFails(tx2, "DELETE FROM p WHERE id = 7", error.ForeignKeyViolation);
    try statement(tx2, "DELETE FROM c");
    try statement(tx2, "DELETE FROM p WHERE id = 7");
    try commit(tx2);
    try expect("SELECT id, v FROM p ORDER BY id", "6|30");
    try sameState(&.{ "SELECT id, v FROM p ORDER BY id", "SELECT pid FROM c", "SELECT pid FROM cr", "SELECT id, ref FROM s" });
}

// ---- NOT VALID / VALIDATE, RENAME CONSTRAINT, INDEX CONCURRENTLY ---------

fn constraintCommands() !void {
    reset();
    try run("CREATE TABLE nvt (id INT PRIMARY KEY, a INT, b INT CONSTRAINT nvt_b_key UNIQUE)");
    try run("INSERT INTO nvt VALUES (1, -1, 5), (2, 3, 6)");
    const checks = "SELECT conname, convalidated, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'nvt'::regclass AND contype = 'c' ORDER BY 1";
    try rejects("ALTER TABLE nvt ADD CONSTRAINT a_pos CHECK (a > 0)", error.CheckViolation, checks, "");
    // NOT VALID skips the existing rows (definition format 7 on the WAL):
    // a crafted later version or a NOT VALID key fails closed.
    var result: DB.Result = .{};
    var used: usize = 0;
    try db.executeChanges("ALTER TABLE nvt ADD CONSTRAINT a_pos CHECK (a > 0) NOT VALID", &result, &record, &used, null, null);
    const valid = record[0..used];
    const version_at = (std.mem.indexOf(u8, valid, &[_]u8{ 3, 'n', 'v', 't', 7, 0 }) orelse return error.DefinitionVersionNotFound) + 4;
    @memcpy(crafted[0..used], valid);
    // Version 8 is the ddl-alter lane's column-extension format (wave 5).
    crafted[version_at] = 9;
    try check(replica.applyChangeRecord(crafted[0..used], &scratch) == error.UnsupportedLogVersion);
    const unique_at = (std.mem.indexOf(u8, valid, &[_]u8{ 2, 9, 'n', 'v', 't', '_', 'b', '_', 'k', 'e', 'y' }) orelse return error.ConstraintNotFound) + 11;
    @memcpy(crafted[0..used], valid);
    crafted[unique_at] |= 8;
    try check(replica.applyChangeRecord(crafted[0..used], &scratch) == error.InvalidChangeRecord);
    try replica.applyChangeRecord(valid, &scratch);
    records_applied += 1;
    try expect(checks, "a_pos|f|CHECK ((a > 0)) NOT VALID");
    try rejects("INSERT INTO nvt VALUES (3, -5, 1)", error.CheckViolation, "SELECT COUNT(*) FROM nvt", "2");
    try run("INSERT INTO nvt VALUES (3, 5, 1)");
    // An UPDATE checks the whole new row, also an unchanged invalid value.
    try rejects("UPDATE nvt SET b = 7 WHERE id = 1", error.CheckViolation, "SELECT id, a, b FROM nvt ORDER BY id", "1|-1|5;2|3|6;3|5|1");
    try rejects("ALTER TABLE nvt VALIDATE CONSTRAINT a_pos", error.CheckViolation, checks, "a_pos|f|CHECK ((a > 0)) NOT VALID");
    try run("UPDATE nvt SET a = 1 WHERE id = 1");
    try run("ALTER TABLE nvt VALIDATE CONSTRAINT a_pos");
    try expect(checks, "a_pos|t|CHECK ((a > 0))");
    try run("ALTER TABLE nvt VALIDATE CONSTRAINT a_pos");
    try rejects("ALTER TABLE nvt VALIDATE CONSTRAINT nope", error.UndefinedObject, checks, "a_pos|t|CHECK ((a > 0))");
    try rejects("ALTER TABLE nvt VALIDATE CONSTRAINT nvt_pkey", error.WrongObjectType, checks, "a_pos|t|CHECK ((a > 0))");
    try rejects("ALTER TABLE nvt ADD CONSTRAINT b_u UNIQUE (b) NOT VALID", error.UnsupportedStatement, checks, "a_pos|t|CHECK ((a > 0))");
    // FOREIGN KEY NOT VALID; NOT VALID in CREATE TABLE is ignored.
    try run("CREATE TABLE nvp (id INT PRIMARY KEY)");
    try run("INSERT INTO nvp VALUES (5), (6)");
    try run("CREATE TABLE nvc (pid INT, x INT)");
    try run("INSERT INTO nvc VALUES (9, 1)");
    try run("ALTER TABLE nvc ADD CONSTRAINT nvc_fk FOREIGN KEY (pid) REFERENCES nvp NOT VALID");
    const fk = "SELECT conname, convalidated, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'nvc'::regclass";
    try expect(fk, "nvc_fk|f|FOREIGN KEY (pid) REFERENCES nvp(id) NOT VALID");
    try rejects("INSERT INTO nvc VALUES (8, 1)", error.ForeignKeyViolation, "SELECT pid FROM nvc", "9");
    try run("UPDATE nvc SET x = 2");
    try rejects("ALTER TABLE nvc VALIDATE CONSTRAINT nvc_fk", error.ForeignKeyViolation, fk, "nvc_fk|f|FOREIGN KEY (pid) REFERENCES nvp(id) NOT VALID");
    try run("DELETE FROM nvc WHERE pid = 9");
    try run("ALTER TABLE nvc VALIDATE CONSTRAINT nvc_fk");
    try expect(fk, "nvc_fk|t|FOREIGN KEY (pid) REFERENCES nvp(id)");
    try run("CREATE TABLE nvn (a INT, CONSTRAINT nvn_chk CHECK (a > 0) NOT VALID)");
    try expect("SELECT convalidated FROM pg_constraint WHERE conname = 'nvn_chk'", "t");
    try sameState(&.{ checks, fk, "SELECT id, a, b FROM nvt ORDER BY id" });
    // RENAME CONSTRAINT: 42704, 42710, and 42P07 for an index-backed
    // constraint whose new name is a relation; indexes follow the name.
    try run("CREATE TABLE other (x INT)");
    try run("CREATE INDEX other_idx ON other (x)");
    const names = "SELECT conname, contype FROM pg_constraint WHERE conrelid = 'nvt'::regclass AND contype <> 'n' ORDER BY 1";
    try run("ALTER TABLE nvt RENAME CONSTRAINT a_pos TO a_positive");
    try rejects("ALTER TABLE nvt RENAME CONSTRAINT nope TO x", error.UndefinedObject, names, "a_positive|c;nvt_b_key|u;nvt_pkey|p");
    try rejects("ALTER TABLE nvt RENAME CONSTRAINT a_positive TO nvt_b_key", error.DuplicateObject, names, "a_positive|c;nvt_b_key|u;nvt_pkey|p");
    try rejects("ALTER TABLE nvt RENAME CONSTRAINT nvt_b_key TO other_idx", error.TableExists, names, "a_positive|c;nvt_b_key|u;nvt_pkey|p");
    try run("ALTER TABLE nvt RENAME CONSTRAINT nvt_b_key TO b_unique");
    try run("ALTER TABLE nvt RENAME CONSTRAINT nvt_pkey TO nvt_key");
    try expect(names, "a_positive|c;b_unique|u;nvt_key|p");
    const index_names = "SELECT indexname FROM pg_indexes WHERE tablename = 'nvt' ORDER BY 1";
    try expect(index_names, "b_unique;nvt_key");
    try rejects("INSERT INTO nvt VALUES (3, 1, 6)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM nvt", "3");
    try sameState(&.{ names, index_names });
    // CREATE / DROP INDEX CONCURRENTLY: never inside a transaction block.
    const tx = try db.begin();
    try statementFails(tx, "CREATE INDEX CONCURRENTLY nvt_a ON nvt (a)", error.ActiveSqlTransaction);
    db.abort(tx);
    try run("CREATE INDEX CONCURRENTLY nvt_a ON nvt (a)");
    try expect("SELECT indexdef FROM pg_indexes WHERE indexname = 'nvt_a'", "CREATE INDEX nvt_a ON public.nvt USING btree (a)");
    const drop = try db.begin();
    try statementFails(drop, "DROP INDEX CONCURRENTLY nvt_a", error.ActiveSqlTransaction);
    db.abort(drop);
    try run("DROP INDEX CONCURRENTLY nvt_a");
    try expect("SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'nvt_a'", "0");
    try sameState(&.{index_names});
}

var crafted: [65536]u8 = undefined;

// ---- row lock strength: NO KEY UPDATE, FOR KEY SHARE; LOCK on views -------

fn rowLockStrength() !void {
    reset();
    try run("CREATE TABLE p (id INT PRIMARY KEY, note TEXT, u INT UNIQUE)");
    try run("CREATE TABLE c (pid INT REFERENCES p)");
    try run("INSERT INTO p VALUES (1, 'a', 10), (2, 'b', 20)");
    // An UPDATE that keeps every key column is FOR NO KEY UPDATE: FOR KEY
    // SHARE (and a foreign key check) does not wait for it; FOR SHARE does.
    const updater = try db.begin();
    try statement(updater, "UPDATE p SET note = 'x' WHERE id = 1");
    const sharer = try db.begin();
    try same(try rows(sharer, "SELECT id, note FROM p WHERE id = 1 FOR KEY SHARE"), "1|a");
    try statement(sharer, "INSERT INTO c VALUES (1)");
    try parks(sharer, "SELECT id FROM p WHERE id = 1 FOR SHARE");
    try commit(updater);
    const shared = try resumed(sharer, "SELECT id FROM p WHERE id = 1 FOR SHARE");
    try same(try render(&shared), "1");
    try commit(sharer);
    // A key change is FOR UPDATE strength: it waits for FOR KEY SHARE.
    const holder = try db.begin();
    try same(try rows(holder, "SELECT id FROM p WHERE id = 2 FOR KEY SHARE"), "2");
    const writer = try db.begin();
    try statement(writer, "UPDATE p SET note = 'y' WHERE id = 2");
    try parks(writer, "UPDATE p SET u = 21 WHERE id = 2");
    try commit(holder);
    try check((try resumed(writer, "UPDATE p SET u = 21 WHERE id = 2")).affected_rows == 1);
    try commit(writer);
    // A referencing row's FOR KEY SHARE holds off a DELETE of its key.
    const inserter = try db.begin();
    try statement(inserter, "INSERT INTO c VALUES (2)");
    const remover = try db.begin();
    try parks(remover, "DELETE FROM p WHERE id = 2");
    db.abort(remover);
    try commit(inserter);
    try expect("SELECT id, note, u FROM p ORDER BY id", "1|x|10;2|y|21");
    try sameState(&.{ "SELECT id, note, u FROM p ORDER BY id", "SELECT pid FROM c ORDER BY pid" });
    // LOCK on a view locks the relations its query reads, recursively.
    try run("CREATE TABLE lt (id INT)");
    try run("CREATE TABLE lu (id INT)");
    try run("CREATE VIEW lv AS SELECT lt.id FROM lt JOIN lu USING (id)");
    try run("CREATE VIEW lvv AS SELECT * FROM lv");
    try run("CREATE MATERIALIZED VIEW lm AS SELECT * FROM lt");
    const locker = try db.begin();
    try statement(locker, "LOCK TABLE ONLY lvv IN EXCLUSIVE MODE");
    const blocked = try db.begin();
    try parks(blocked, "INSERT INTO lu VALUES (1)");
    try commit(locker);
    _ = try resumed(blocked, "INSERT INTO lu VALUES (1)");
    try statementFails(blocked, "LOCK TABLE lm", error.WrongObjectType);
    try commit(blocked);
    try expect("SELECT COUNT(*) FROM lu", "1");
    try sameState(&.{"SELECT COUNT(*) FROM lu"});
}

// ---- row security: families, SELECT policies on new rows, check order -----

fn rowSecurity() !void {
    reset();
    try run("CREATE TABLE r (id INT PRIMARY KEY, owner TEXT, v INT CHECK (v > 0) NOT NULL)");
    try run("CREATE TABLE rc (extra INT) INHERITS (r)");
    try run("CREATE ROLE ru");
    try run("GRANT SELECT, INSERT, UPDATE, DELETE ON r TO ru");
    try run("GRANT SELECT, INSERT, UPDATE, DELETE ON rc TO ru");
    try run("ALTER TABLE r ENABLE ROW LEVEL SECURITY");
    try run("CREATE POLICY r_sel ON r FOR SELECT USING (owner = 'ru')");
    try run("CREATE POLICY r_ins ON r FOR INSERT WITH CHECK (v < 100)");
    try run("CREATE POLICY r_upd ON r FOR UPDATE USING (owner = 'ru') WITH CHECK (v < 50)");
    try run("CREATE POLICY r_del ON r FOR DELETE USING (true)");
    try run("INSERT INTO r VALUES (1, 'ru', 10), (2, 'x', 20)");
    try run("INSERT INTO rc VALUES (3, 'ru', 30, 0), (4, 'x', 40, 0)");
    const all = "SELECT id, owner, v FROM r ORDER BY id";
    try run("SET ROLE ru");
    // Reads through the parent filter every member's rows by the parent's
    // policies; a child read on its own uses the child's (none here).
    try expect("SELECT id FROM r ORDER BY id", "1;3");
    try expect("SELECT id FROM ONLY r ORDER BY id", "1");
    try expect("SELECT id FROM rc ORDER BY id", "3;4");
    // WITH CHECK runs before NOT NULL and CHECK constraints (42501 first).
    try rejects("INSERT INTO r VALUES (5, 'x', 200)", error.InsufficientPrivilege, "SELECT COUNT(*) FROM rc", "2");
    try rejects("INSERT INTO r VALUES (5, 'x', -1)", error.CheckViolation, "SELECT COUNT(*) FROM rc", "2");
    try rejects("INSERT INTO r VALUES (5, 'x', NULL)", error.InsufficientPrivilege, "SELECT COUNT(*) FROM rc", "2");
    try run("INSERT INTO r VALUES (5, 'x', 5)");
    // A new row the statement returns must also pass the SELECT policies.
    try rejects("INSERT INTO r VALUES (6, 'x', 6) RETURNING id", error.InsufficientPrivilege, "SELECT COUNT(*) FROM rc", "2");
    try affects("INSERT INTO r VALUES (6, 'ru', 6) RETURNING id", 1, "6");
    try rejects("UPDATE r SET v = 60 WHERE id = 1", error.InsufficientPrivilege, "SELECT COUNT(*) FROM rc", "2");
    try expect("SELECT id, v FROM r ORDER BY id", "1|10;3|30;6|6");
    try rejects("UPDATE r SET v = -1 WHERE id = 1", error.CheckViolation, "SELECT COUNT(*) FROM rc", "2");
    try expect("SELECT id, v FROM r ORDER BY id", "1|10;3|30;6|6");
    // UPDATE / DELETE through the parent reach the visible child rows.
    try affects("UPDATE r SET v = v + 1 WHERE id >= 1", 3, "");
    try expect("SELECT id, v FROM r ORDER BY id", "1|11;3|31;6|7");
    try rejects("UPDATE r SET owner = 'x' WHERE id = 3 RETURNING id", error.InsufficientPrivilege, "SELECT COUNT(*) FROM rc", "2");
    try expect("SELECT id, v FROM r ORDER BY id", "1|11;3|31;6|7");
    try affects("DELETE FROM r WHERE id = 3 RETURNING id", 1, "3");
    try affects("DELETE FROM r WHERE id = 2", 0, "");
    try run("RESET ROLE");
    try expect(all, "1|ru|11;2|x|20;4|x|40;5|x|5;6|ru|7");
    try sameState(&.{all});
}

pub fn main() !void {
    try truncateOnly();
    try familyWrites();
    try rowMovement();
    try inheritsMerge();
    try attachDetach();
    try partitionKeys();
    try foreignKeyTiming();
    try constraintCommands();
    try rowLockStrength();
    try rowSecurity();
    try columnCommands();
    try searchPath();
    std.debug.print("ddl-dml: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}

// ---- identity / generated columns, NOT ENFORCED, TRUNCATE CASCADE, small
// ---- grammar gaps (feature probes F171, F200, F384-F386, F492, E141-03, S111,
// ---- T178, T201)

fn columnCommands() !void {
    reset();
    try run("CREATE TABLE t (id INT GENERATED BY DEFAULT AS IDENTITY, v INT, g INT GENERATED ALWAYS AS (v * 2) STORED, w INT GENERATED ALWAYS AS (v + 1))");
    try run("INSERT INTO t (v) VALUES (1)");
    const all = "SELECT id, v, g FROM t ORDER BY v";
    // DROP IDENTITY / SET GENERATED / RESTART need an identity column (55000).
    try rejects("ALTER TABLE t ALTER COLUMN v DROP IDENTITY", error.ObjectNotInPrerequisiteState, all, "1|1|2");
    try run("ALTER TABLE t ALTER COLUMN v DROP IDENTITY IF EXISTS");
    try run("ALTER TABLE t ALTER COLUMN id SET GENERATED ALWAYS");
    try rejects("INSERT INTO t (id, v) VALUES (5, 2)", error.GeneratedAlways, all, "1|1|2");
    try run("ALTER TABLE t ALTER COLUMN id SET GENERATED BY DEFAULT");
    try rejects("ALTER TABLE t ALTER COLUMN v SET GENERATED ALWAYS", error.ObjectNotInPrerequisiteState, all, "1|1|2");
    try run("ALTER TABLE t ALTER COLUMN id RESTART WITH 50");
    try run("INSERT INTO t (v) VALUES (3)");
    try run("ALTER TABLE t ALTER COLUMN id RESTART");
    try run("INSERT INTO t (v) VALUES (4)");
    try rejects("ALTER TABLE t ALTER COLUMN v RESTART", error.ObjectNotInPrerequisiteState, all, "1|1|2;50|3|6;1|4|8");
    const sequences = "SELECT COUNT(*) FROM pg_class WHERE relkind = 'S'";
    try expect(sequences, "1");
    // DROP IDENTITY drops the sequence; the column keeps NOT NULL.
    try run("ALTER TABLE t ALTER COLUMN id DROP IDENTITY");
    try expect(sequences, "0");
    try rejects("INSERT INTO t (v) VALUES (5)", error.NotNullViolation, all, "1|1|2;50|3|6;1|4|8");
    // DROP EXPRESSION keeps a stored column's values (a virtual one: 0A000).
    try run("ALTER TABLE t ALTER COLUMN g DROP EXPRESSION");
    try rejects("ALTER TABLE t ALTER COLUMN g DROP EXPRESSION", error.ObjectNotInPrerequisiteState, all, "1|1|2;50|3|6;1|4|8");
    try run("ALTER TABLE t ALTER COLUMN g DROP EXPRESSION IF EXISTS");
    try rejects("ALTER TABLE t ALTER COLUMN w DROP EXPRESSION", error.UnsupportedStatement, all, "1|1|2;50|3|6;1|4|8");
    try run("INSERT INTO t (id, v, g) VALUES (9, 9, 9)");
    try expect(all, "1|1|2;50|3|6;1|4|8;9|9|9");
    const columns = "SELECT column_name, is_identity, is_generated FROM information_schema.columns WHERE table_name = 't' ORDER BY 1";
    try expect(columns, "g|NO|NEVER;id|NO|NEVER;v|NO|NEVER;w|NO|ALWAYS");
    try sameState(&.{ all, columns, sequences });
    // NOT ENFORCED CHECK / FOREIGN KEY (PostgreSQL 18): never checked;
    // only a foreign key's enforceability can change (42809 otherwise).
    try run("CREATE TABLE ne (a INT, CONSTRAINT a_pos CHECK (a > 0) NOT ENFORCED)");
    try run("INSERT INTO ne VALUES (-1)");
    const enforced = "SELECT conname, conenforced, convalidated, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid IN ('ne'::regclass, 'nec'::regclass) ORDER BY 1";
    try run("CREATE TABLE nep (id INT PRIMARY KEY)");
    try run("CREATE TABLE nec (pid INT REFERENCES nep NOT ENFORCED)");
    try run("INSERT INTO nec VALUES (5)");
    try expect(enforced, "a_pos|f|f|CHECK ((a > 0)) NOT ENFORCED;nec_pid_fkey|f|f|FOREIGN KEY (pid) REFERENCES nep(id) NOT ENFORCED");
    try rejects("ALTER TABLE ne ALTER CONSTRAINT a_pos ENFORCED", error.WrongObjectType, "SELECT a FROM ne", "-1");
    try rejects("ALTER TABLE ne VALIDATE CONSTRAINT a_pos", error.ObjectNotInPrerequisiteState, "SELECT a FROM ne", "-1");
    try rejects("ALTER TABLE nec ALTER CONSTRAINT nec_pid_fkey ENFORCED", error.ForeignKeyViolation, "SELECT pid FROM nec", "5");
    try run("DELETE FROM nec");
    try run("ALTER TABLE nec ALTER CONSTRAINT nec_pid_fkey ENFORCED");
    try rejects("INSERT INTO nec VALUES (6)", error.ForeignKeyViolation, "SELECT COUNT(*) FROM nec", "0");
    try run("ALTER TABLE nec ALTER CONSTRAINT nec_pid_fkey NOT ENFORCED");
    try run("INSERT INTO nec VALUES (6)");
    try run("ALTER TABLE ne ADD CONSTRAINT b CHECK (a < 10) ENFORCED NOT VALID");
    try rejects("CREATE TABLE neu (a INT UNIQUE NOT ENFORCED)", error.Syntax, "SELECT COUNT(*) FROM nec", "1");
    try expect(enforced, "a_pos|f|f|CHECK ((a > 0)) NOT ENFORCED;b|t|f|CHECK ((a < 10)) NOT VALID;nec_pid_fkey|f|f|FOREIGN KEY (pid) REFERENCES nep(id) NOT ENFORCED");
    try sameState(&.{enforced});
    // TRUNCATE ... CASCADE also empties the referencing tables (only them).
    try run("CREATE TABLE tp (id INT PRIMARY KEY)");
    try run("CREATE TABLE tc (id INT REFERENCES tp)");
    try run("CREATE TABLE tc2 (x INT REFERENCES tp)");
    try run("INSERT INTO tp VALUES (1)");
    try run("INSERT INTO tc VALUES (1)");
    try run("INSERT INTO tc2 VALUES (1)");
    const counts = "SELECT (SELECT COUNT(*) FROM tp), (SELECT COUNT(*) FROM tc), (SELECT COUNT(*) FROM tc2)";
    try rejects("TRUNCATE tp", error.UnsupportedStatement, counts, "1|1|1");
    try run("TRUNCATE tp CASCADE");
    try expect(counts, "0|0|0");
    try sameState(&.{counts});
    // Foreign keys between text and varchar (and integer widths).
    try run("CREATE TABLE fp (id BIGINT PRIMARY KEY, code VARCHAR(10) UNIQUE)");
    try run("CREATE TABLE fc (pid INT REFERENCES fp, pcode TEXT REFERENCES fp (code))");
    try run("INSERT INTO fp VALUES (1, 'a')");
    try run("INSERT INTO fc VALUES (1, 'a')");
    try rejects("INSERT INTO fc VALUES (1, 'b')", error.ForeignKeyViolation, "SELECT COUNT(*) FROM fc", "1");
    try rejects("DELETE FROM fp", error.ForeignKeyViolation, "SELECT COUNT(*) FROM fc", "1");
    try rejects("CREATE TABLE fbad (pid DATE REFERENCES fp)", error.TypeMismatch, "SELECT COUNT(*) FROM fc", "1");
    // Two primary keys: 42P16. FROM ONLY (name). An unknown statement
    // word: 42601. CREATE SCHEMA ... AUTHORIZATION.
    try rejects("CREATE TABLE two (a INT PRIMARY KEY, b INT PRIMARY KEY)", error.InvalidTableDefinition, "SELECT COUNT(*) FROM fc", "1");
    try run("CREATE TABLE parent (a INT)");
    try run("CREATE TABLE child (b INT) INHERITS (parent)");
    try run("INSERT INTO parent VALUES (1)");
    try run("INSERT INTO child VALUES (2, 3)");
    try expect("SELECT a FROM ONLY (parent)", "1");
    try expect("SELECT x.a FROM ONLY (public.parent) AS x", "1");
    try rejects("SELEC 1", error.Syntax, "SELECT COUNT(*) FROM fc", "1");
    try run("CREATE ROLE so");
    try run("CREATE SCHEMA s1 AUTHORIZATION so");
    try run("CREATE SCHEMA AUTHORIZATION so");
    try run("CREATE SCHEMA s2 AUTHORIZATION CURRENT_USER");
    const owners = "SELECT nspname, pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname IN ('s1', 's2', 'so') ORDER BY 1";
    try expect(owners, "s1|so;s2|ramsql;so|so");
    try rejects("CREATE SCHEMA s3 AUTHORIZATION public", error.UndefinedObject, owners, "s1|so;s2|ramsql;so|so");
    try rejects("CREATE SCHEMA s3 AUTHORIZATION nobody", error.UndefinedObject, owners, "s1|so;s2|ramsql;so|so");
    try sameState(&.{owners});
}

// ---- search_path over user schemas (the shared resolver) -------------------

fn searchPath() !void {
    reset();
    try run("CREATE SCHEMA s1");
    try run("CREATE SCHEMA s2");
    try run("CREATE TABLE s1.t (a INT PRIMARY KEY)");
    try run("CREATE TABLE s2.t (a INT)");
    try run("CREATE TABLE public.t (a INT)");
    try run("CREATE TABLE public.p (b INT)");
    try run("INSERT INTO s1.t VALUES (1)");
    try run("INSERT INTO s2.t VALUES (2)");
    try run("INSERT INTO public.t VALUES (0)");
    try run("INSERT INTO p VALUES (5)");
    // Unqualified names resolve in the path's order; CREATE uses its first
    // existing schema; missing schemas are skipped.
    try run("SET search_path = s2, s1");
    try expect("SHOW search_path", "s2, s1");
    try expect("SELECT a FROM t", "2");
    try affects("INSERT INTO t VALUES (22)", 1, "");
    try affects("UPDATE t SET a = a + 100", 2, "");
    try expect("SELECT a FROM s2.t ORDER BY a", "102;122");
    try run("CREATE TABLE u (b INT)");
    const homes = "SELECT tablename, schemaname FROM pg_tables WHERE tablename IN ('u', 'v1', 'w') ORDER BY 1";
    try expect(homes, "u|s2");
    try expect("SELECT current_schema(), current_schemas(false)", "s2|{s2,s1}");
    try run("SET search_path = nosuch, s1");
    try expect("SELECT a FROM t", "1");
    try run("CREATE TABLE v1 (c INT)");
    try expect(homes, "u|s2;v1|s1");
    try run("SET search_path = nosuch");
    try rejects("CREATE TABLE w (c INT)", error.UndefinedSchema, homes, "u|s2;v1|s1");
    try rejects("SELECT a FROM t", error.TableNotFound, homes, "u|s2;v1|s1");
    try expect("SELECT current_schema() IS NULL", "t");
    // DDL, sequences, regclass and routines through the same path.
    try run("SET search_path = s1, public");
    try expect("SELECT t.a, p.b FROM t, p ORDER BY 1", "1|5");
    try run("ALTER TABLE t ADD COLUMN c INT");
    try expect("SELECT 't'::regclass::text, 'p'::regclass::text", "t|p");
    try run("CREATE INDEX t_c ON t (c)");
    try run("DROP INDEX t_c");
    try run("CREATE SEQUENCE sq");
    try expect("SELECT nextval('sq'), nextval('s1.sq')", "1|2");
    try run("CREATE FUNCTION f() RETURNS INT LANGUAGE sql AS 'SELECT 42'");
    try expect("SELECT f()", "42");
    // A view stores its text: an unqualified name outside public is stored
    // with its schema (ddl-alter, wave 5; 0A000 before).
    try run("CREATE VIEW v AS SELECT a FROM t");
    try expect("SELECT definition FROM pg_views WHERE viewname = 'v'", "SELECT a FROM s1.t");
    try run("DROP VIEW v");
    try run("CREATE VIEW v2 AS SELECT a FROM s1.t");
    try expect("SELECT * FROM v2", "1");
    try run("TRUNCATE t");
    try expect("SELECT COUNT(*) FROM t", "0");
    const tx = try db.begin();
    try statement(tx, "LOCK TABLE t");
    try commit(tx);
    try run("DROP TABLE t CASCADE");
    try expect("SELECT a FROM t", "0");
    try run("SET search_path TO DEFAULT");
    try expect("SHOW search_path", "\"$user\", public");
    try rejects("SELECT f()", error.UndefinedFunction, homes, "u|s2;v1|s1");
    try expect("SELECT s1.f()", "42");
    try run("SET SCHEMA 's1'");
    try expect("SHOW search_path", "s1");
    try expect("SELECT f()", "42");
    try run("RESET search_path");
    try sameState(&.{ homes, "SELECT a FROM s2.t ORDER BY a", "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 's1'" });
}
