//! READ COMMITTED engine contracts (design §4.4-§4.5): snapshot visibility
//! matrix, statement subtransactions across parks, EvalPlanQual, savepoints,
//! transactional DDL, bitset deadlock detection, and empty lock/transaction
//! tables after commit, abort and every error path.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 3, .columns = 3, .rows_per_table = 16, .text_bytes = 16, .transactions = 6, .savepoints = 4, .row_locks = 8, .share_holders = 3 });
var assertions: usize = 0;
var db: DB = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("mvcc contract failed at assertion {d}\n", .{assertions});
        return error.MvccContractFailed;
    }
}

fn run(slot: u16, source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{});
    return result;
}

fn resumeRun(slot: u16, source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{ .@"resume" = true });
    return result;
}

fn rows(slot: u16, source: []const u8) !usize {
    return (try run(slot, source)).row_count;
}

fn value(slot: u16, source: []const u8) !i64 {
    const result = try run(slot, source);
    try check(result.row_count == 1);
    return result.rows[0].cells[0].integer;
}

fn parks(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{})) |_| return error.ExpectedPark else |err| try check(err == error.WouldBlock);
    try check(db.parked(slot));
}

fn empty() !void {
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0 and usage.pending_versions == 0);
}

fn commit(slot: u16) void {
    db.publishCommit(slot);
}

fn autocommit(source: []const u8) !void {
    var result: DB.Result = .{};
    try db.execute(source, &result);
}

fn visibility() !void {
    try autocommit("CREATE TABLE t (id INTEGER PRIMARY KEY, v BIGINT)");
    try autocommit("INSERT INTO t VALUES (1, 10)");
    const a = try db.begin();
    const b = try db.begin();
    // Own uncommitted writes are visible to later statements of the same
    // transaction only; never to others; a statement never sees its own.
    _ = try run(a, "INSERT INTO t VALUES (2, 20)");
    try check(try rows(a, "SELECT * FROM t") == 2);
    try check(try rows(b, "SELECT * FROM t") == 1);
    _ = try run(a, "UPDATE t SET v = v + 1");
    try check(try value(a, "SELECT v FROM t WHERE id = 2") == 21);
    try check(try value(b, "SELECT v FROM t WHERE id = 1") == 10);
    _ = try run(a, "DELETE FROM t WHERE id = 1");
    try check(try rows(a, "SELECT * FROM t") == 1);
    try check(try rows(b, "SELECT * FROM t") == 1);
    try check(try value(b, "SELECT v FROM t") == 10);
    // A new snapshot per statement: b sees a's commit at its next statement.
    commit(a);
    try check(try value(b, "SELECT v FROM t") == 21);
    try check(try value(b, "SELECT id FROM t") == 2);
    commit(b);
    // Halloween: a statement does not see the rows it inserts or updates.
    const c = try db.begin();
    try check((try run(c, "UPDATE t SET v = v * 2")).affected_rows == 1);
    try check(try value(c, "SELECT v FROM t") == 42);
    db.abort(c);
    try check(try fresh("SELECT v FROM t") == 21);
    try empty();
}

/// One statement in a fresh transaction that is then aborted.
fn fresh(source: []const u8) !i64 {
    const slot = try db.begin();
    defer db.abort(slot);
    return value(slot, source);
}

fn statementSubtransactions() !void {
    try autocommit("CREATE TABLE p (id INTEGER PRIMARY KEY, v BIGINT)");
    try autocommit("INSERT INTO p VALUES (1, 0)");
    try autocommit("INSERT INTO p VALUES (2, 0)");
    try autocommit("INSERT INTO p VALUES (3, 0)");
    const a = try db.begin();
    const b = try db.begin();
    _ = try run(a, "UPDATE p SET v = 9 WHERE id = 2");
    _ = try run(b, "INSERT INTO p VALUES (4, 0)");
    const held = db.usage();
    // b's statement applies row 1, then parks on row 2 (keeps its work).
    try parks(b, "UPDATE p SET v = v + 1 WHERE id < 4");
    try check(db.usage().pending_versions == held.pending_versions + 2);
    try check(db.waitingFor(b).has(a) and !db.deadlocked(b));
    // Park-then-cancel: the statement has zero versions and locks left and
    // b holds exactly what it held before it (its insert), still active.
    db.abortStatement(b);
    try check(!db.parked(b) and db.active(b));
    try check(db.usage().pending_versions == held.pending_versions);
    try check(try rows(b, "SELECT * FROM p WHERE id = 4") == 1);
    // Park-and-re-deliver: resume with the same snapshot; EvalPlanQual
    // re-reads row 2 at its newest committed version; the count is 3.
    try parks(b, "UPDATE p SET v = v + 1 WHERE id < 4");
    commit(a);
    const resumed = try resumeRun(b, "UPDATE p SET v = v + 1 WHERE id < 4");
    try check(resumed.affected_rows == 3 and resumed.command == .update);
    commit(b);
    try check(try fresh("SELECT v FROM p WHERE id = 2") == 10);
    // EvalPlanQual skips a row whose newest version no longer qualifies,
    // and never touches rows inserted after the snapshot.
    const x = try db.begin();
    const y = try db.begin();
    _ = try run(x, "UPDATE p SET v = 100 WHERE id = 1");
    try parks(y, "UPDATE p SET v = v + 1 WHERE v < 50");
    _ = try run(x, "INSERT INTO p VALUES (5, 0)");
    commit(x);
    const epq = try resumeRun(y, "UPDATE p SET v = v + 1 WHERE v < 50");
    try check(epq.affected_rows == 3);
    commit(y);
    try check(try fresh("SELECT v FROM p WHERE id = 1") == 100);
    try check(try fresh("SELECT v FROM p WHERE id = 5") == 0);
    try empty();
}

fn savepoints() !void {
    const a = try db.begin();
    _ = try run(a, "UPDATE p SET v = 1 WHERE id = 1");
    try db.savepoint(a, "s1");
    _ = try run(a, "UPDATE p SET v = 2 WHERE id = 1");
    _ = try run(a, "CREATE TABLE q (id INTEGER)");
    try db.savepoint(a, "s2");
    _ = try run(a, "SELECT id FROM p WHERE id = 3 FOR UPDATE");
    try check(db.usage().row_locks == 1);
    try check(try db.rollbackTo(a, "s1") == 0);
    // Catalog versions and row locks after s1 are gone; s1 stays.
    try check(db.usage().row_locks == 0);
    try check(try value(a, "SELECT v FROM p WHERE id = 1") == 1);
    if (run(a, "SELECT * FROM q")) |_| return error.TableSurvived else |err| try check(err == error.TableNotFound);
    try check(db.savepointDepth(a) == 1);
    try db.savepoint(a, "s1");
    try check(try db.release(a, "s1") == 1);
    try check(try db.release(a, "s1") == 0);
    if (db.release(a, "s1")) |_| return error.ReleasedTwice else |err| try check(err == error.SavepointNotFound);
    for (0..4) |_| try db.savepoint(a, "deep");
    if (db.savepoint(a, "deep")) |_| return error.SavepointCapacityIgnored else |err| try check(err == error.SavepointCapacity);
    db.abort(a);
    try check(try fresh("SELECT v FROM p WHERE id = 1") == 100);
    try empty();
}

fn ddl() !void {
    const a = try db.begin();
    const b = try db.begin();
    _ = try run(a, "CREATE TABLE d (id INTEGER PRIMARY KEY)");
    _ = try run(a, "INSERT INTO d VALUES (1)");
    if (run(b, "SELECT * FROM d")) |_| return error.UncommittedTable else |err| try check(err == error.TableNotFound);
    // A concurrent CREATE of the same name waits for the creator.
    try parks(b, "CREATE TABLE d (id INTEGER)");
    commit(a);
    if (resumeRun(b, "CREATE TABLE d (id INTEGER)")) |_| return error.DuplicateTable else |err| try check(err == error.TableExists);
    try check(try rows(b, "SELECT * FROM d") == 1);
    // DROP waits for every AccessShare holder; then readers wait for it.
    _ = try run(b, "SELECT * FROM d");
    const c = try db.begin();
    try parks(c, "DROP TABLE d");
    commit(b);
    _ = try resumeRun(c, "DROP TABLE d");
    const e = try db.begin();
    try parks(e, "SELECT * FROM d");
    db.abort(c);
    try check((try resumeRun(e, "SELECT * FROM d")).row_count == 1);
    commit(e);
    try autocommit("DROP TABLE d");
    if (autocommit("SELECT * FROM d")) |_| return error.DroppedTable else |err| try check(err == error.TableNotFound);
    // Catalog capacity: user tables hit TableCapacity first and roll back.
    try autocommit("CREATE TABLE d1 (id INTEGER)");
    if (autocommit("CREATE TABLE d2 (id INTEGER)")) |_| return error.TableCapacityIgnored else |err| try check(err == error.TableCapacity);
    try autocommit("DROP TABLE d1");
    try empty();
}

fn deadlocks() !void {
    // Multi-holder cycle (LK8): C waits for {A, B} (both FOR SHARE holders);
    // B waits for C. A single-edge graph through A would miss it.
    var waits: [6]DB.LockSet = @splat(.{});
    waits[2].add(0);
    waits[2].add(1);
    waits[1].add(2);
    try check(DB.waitCycle(&waits, 2) and DB.waitCycle(&waits, 1) and !DB.waitCycle(&waits, 0));
    // AccessExclusive versus many AccessShare: DROP (slot 5) waits for all
    // readers 0..3; reader 3 waits for the DROP -> cycle through one edge of four.
    waits = @splat(.{});
    for (0..4) |reader| waits[5].add(reader);
    try check(!DB.waitCycle(&waits, 5));
    waits[3].add(5);
    try check(DB.waitCycle(&waits, 5) and DB.waitCycle(&waits, 3) and !DB.waitCycle(&waits, 0));
    // Long chain without a cycle, then closed.
    waits = @splat(.{});
    for (0..5) |slot| waits[slot].add(slot + 1);
    try check(!DB.waitCycle(&waits, 0));
    waits[5].add(0);
    for (0..6) |slot| try check(DB.waitCycle(&waits, slot));

    // Through the engine: two-transaction row deadlock.
    const a = try db.begin();
    const b = try db.begin();
    _ = try run(a, "UPDATE p SET v = 1 WHERE id = 1");
    _ = try run(b, "UPDATE p SET v = 2 WHERE id = 2");
    try parks(a, "UPDATE p SET v = 1 WHERE id = 2");
    try check(!db.deadlocked(a));
    try parks(b, "UPDATE p SET v = 2 WHERE id = 1");
    try check(db.deadlocked(a) and db.deadlocked(b));
    db.abortStatement(a);
    db.abort(a);
    _ = try resumeRun(b, "UPDATE p SET v = 2 WHERE id = 1");
    commit(b);
    // FOR SHARE multi-holder deadlock through the engine.
    const s1 = try db.begin();
    const s2 = try db.begin();
    const s3 = try db.begin();
    _ = try run(s1, "SELECT id FROM p WHERE id = 1 FOR SHARE");
    _ = try run(s2, "SELECT id FROM p WHERE id = 1 FOR SHARE");
    _ = try run(s3, "SELECT id FROM p WHERE id = 2 FOR UPDATE");
    // Share holders are waited for one at a time in acquisition order (as
    // PostgreSQL's MultiXactIdWait): s3 waits for s1, then for s2.
    try parks(s3, "UPDATE p SET v = 3 WHERE id = 1");
    try check(db.waitingFor(s3).has(s1) and !db.waitingFor(s3).has(s2));
    try parks(s2, "UPDATE p SET v = 4 WHERE id = 2");
    try check(!db.deadlocked(s3) and !db.deadlocked(s2));
    commit(s1);
    if (resumeRun(s3, "UPDATE p SET v = 3 WHERE id = 1")) |_| return error.ExpectedPark else |err| try check(err == error.WouldBlock);
    try check(db.waitingFor(s3).has(s2) and db.deadlocked(s3) and db.deadlocked(s2));
    db.abort(s3);
    _ = try resumeRun(s2, "UPDATE p SET v = 4 WHERE id = 2");
    commit(s2);
    // Row-lock capacity (8 entries) is a terminal error that rolls back.
    try autocommit("DELETE FROM p");
    for (0..10) |index| {
        var buffer: [64]u8 = undefined;
        try autocommit(try std.fmt.bufPrint(&buffer, "INSERT INTO p VALUES ({d}, 0)", .{index + 10}));
    }
    const l = try db.begin();
    if (run(l, "SELECT id FROM p FOR SHARE")) |_| return error.LockCapacityIgnored else |err| try check(err == error.LockCapacity);
    try check(db.usage().row_locks == 0);
    db.abort(l);
    try empty();
}

fn errorPaths() !void {
    // Every terminal error leaves no lock, version or transaction behind.
    const failing = [_][]const u8{
        "INSERT INTO p VALUES (10, 0)", "UPDATE p SET v = 1 / 0", "SELECT * FROM missing",
        "UPDATE p SET id = 11 WHERE id = 10", "SELECT id FROM p FOR SHARE", "DROP TABLE missing",
    };
    for (failing) |source| {
        const slot = try db.begin();
        var result: DB.Result = .{};
        if (db.statement(slot, source, &result, .{})) |_| return error.ErrorExpected else |_| {}
        try check(!db.parked(slot));
        db.abort(slot);
        try empty();
        if (db.execute(source, &result)) |_| return error.ErrorExpected else |_| {}
        try empty();
    }
    // NOWAIT and SKIP LOCKED.
    const a = try db.begin();
    _ = try run(a, "SELECT id FROM p WHERE id = 10 FOR UPDATE");
    const b = try db.begin();
    if (run(b, "SELECT id FROM p WHERE id = 10 FOR UPDATE NOWAIT")) |_| return error.NowaitIgnored else |err| try check(err == error.LockNotAvailable);
    try check((try run(b, "SELECT id FROM p WHERE id < 13 ORDER BY id FOR UPDATE SKIP LOCKED")).row_count == 2);
    try check(db.usage().row_locks == 3);
    db.abort(b);
    db.abort(a);
    try empty();
    // Version/write-set capacity is a terminal error: the failing statement
    // rolls back, earlier statements of the transaction stay intact.
    const w = try db.begin();
    var failed = false;
    var completed: usize = 0;
    for (0..8) |_| {
        if (run(w, "UPDATE p SET v = v + 1")) |_| {
            completed += 1;
        } else |err| {
            try check(err == error.WriteSetCapacity or err == error.VersionCapacity);
            failed = true;
            break;
        }
    }
    try check(failed and completed > 0);
    try check(try value(w, "SELECT v FROM p WHERE id = 10") == @as(i64, @intCast(completed)));
    db.abort(w);
    try empty();
}

pub fn main() !void {
    try visibility();
    try statementSubtransactions();
    try savepoints();
    try ddl();
    try deadlocks();
    try errorPaths();
    try check(assertions > 0);
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-mvcc\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d}}}\n", .{ assertions, DB.storageBytes() });
    std.debug.print("{s}", .{report});
}
