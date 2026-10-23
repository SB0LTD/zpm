const std = @import("std");
const sql = @import("sql");
const store_module = @import("db_store");
const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 8, .text_bytes = 32 });
const Store = store_module.Store(DB);
var assertions: usize = 0;
var replay_scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("store contract failed at assertion {d}\n", .{assertions});
        return error.StoreContractFailed;
    }
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn count(connection: *Store.Connection, expected: usize) !void {
    var result: DB.Result = .{};
    try connection.execute("SELECT * FROM t", &result);
    try check(result.row_count == expected);
}

fn label(connection: *Store.Connection, query: []const u8, expected: []const u8) !void {
    var result: DB.Result = .{};
    try connection.execute(query, &result);
    try check(result.row_count == 1 and equal(result.rows[0].cells[1].text.slice(), expected));
}

/// No transaction, lock or uncommitted version survives.
fn quiescent(store: *const Store) !void {
    const usage = store.database.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0 and usage.pending_versions == 0);
}

fn blocks(connection: *Store.Connection, source: []const u8, result: *DB.Result) !void {
    if (connection.execute(source, result)) |_| return error.ExpectedBlock else |err| try check(err == error.WouldBlock);
    try check(connection.blocked());
}

fn transactions() !void {
    var store: Store = .{};
    var a: Store.Connection = .{ .store = &store, .id = 1 };
    var b: Store.Connection = .{ .store = &store, .id = 2 };
    var reader: Store.Connection = .{ .store = &store, .id = 3 };
    var out: DB.Result = .{};
    try a.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out);
    const created_csn = store.database.csn;
    try a.beginTransaction();
    try a.execute("INSERT INTO t VALUES (1, 'rollback')", &out);
    try count(&a, 1);
    try count(&b, 0);
    try count(&reader, 0);
    try check(a.transactionStatus() == 'T' and b.transactionStatus() == 'I');
    try a.rollbackTransaction();
    try check(store.database.csn == created_csn);
    try count(&b, 0);
    try a.execute("BEGIN", &out);
    try a.execute("INSERT INTO t VALUES (1, 'commit')", &out);
    try a.execute("COMMIT", &out);
    try count(&b, 1);
    try check(store.database.csn == created_csn + 1);
    try a.beginTransaction();
    try a.execute("UPDATE t SET value = 'gone'", &out);
    a.failTransaction();
    try check(a.transactionStatus() == 'E');
    // failTransaction already released the block's work and locks.
    try label(&b, "SELECT * FROM t WHERE id = 1", "commit");
    if (a.execute("SELECT * FROM t", &out)) |_| return error.AbortIgnored else |err| try check(err == error.TransactionFailed);
    try a.commitTransaction();
    try b.execute("SELECT * FROM t", &out);
    try check(equal(out.rows[0].cells[1].text.slice(), "commit"));
    try a.setAutocommit(false);
    try a.execute("DELETE FROM t", &out);
    try check(a.transactionStatus() == 'T');
    try count(&b, 1);
    a.disconnect();
    try count(&b, 1);
    try check(a.transactionStatus() == 'I' and a.tx == null);
    try quiescent(&store);
    try b.execute("SELECT 1", &out);
    try check(out.rows[0].cells[0].integer == 1);
    if (b.execute("SET unknown = 1", &out)) |_| return error.UnknownSettingAccepted else |err| try check(err == error.UndefinedSetting);
    var invalid: Store.Connection = .{ .store = &store, .id = 0, .failed = true };
    invalid.disconnect();
    try check(invalid.transactionStatus() == 'I');
    if (invalid.commitTransaction()) |_| return error.InvalidConnectionAccepted else |err| try check(err == error.InvalidConnection);
    if (invalid.execute("SELECT 1", &out)) |_| return error.InvalidConnectionAccepted else |err| try check(err == error.InvalidConnection);
    try count(&b, 1);
    if (b.execute("B E G I N", &out)) |_| return error.InvalidCommandAccepted else |_| {}
    if (b.execute("BEGIN; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    try b.execute("CREATE TABLE bools (id INTEGER PRIMARY KEY, flag BOOLEAN)", &out);
    // Integer 0/1 into BOOLEAN is a MySQL/TDS assignment rule only (N1).
    if (b.execute("INSERT INTO bools VALUES (1, 0)", &out)) |_| return error.DialectLeaked else |err| try check(err == error.TypeMismatch);
    b.dialect = .mysql;
    try b.execute("INSERT INTO bools VALUES (1, 0)", &out);
    try b.execute("SELECT * FROM bools WHERE flag = FALSE", &out);
    try check(out.row_count == 1 and !out.rows[0].cells[1].boolean);
    // Expression typing never coerces integers to booleans, in any dialect.
    if (b.execute("SELECT * FROM bools WHERE flag = 0", &out)) |_| return error.DialectLeaked else |err| try check(err == error.UndefinedFunction);
    try b.execute("UPDATE bools SET flag = 1 WHERE id = 1", &out);
    try b.execute("SELECT * FROM bools WHERE flag = TRUE", &out);
    try check(out.row_count == 1 and out.rows[0].cells[1].boolean);
    if (b.execute("UPDATE bools SET flag = 2", &out)) |_| return error.InvalidBooleanAccepted else |err| try check(err == error.TypeMismatch);
    b.dialect = .postgres;

    // READ COMMITTED (replaces the copy model's SerializationFailure): each
    // statement sees every commit; writers on different rows both commit.
    try a.setAutocommit(true);
    try a.beginTransaction();
    try b.beginTransaction();
    try a.execute("INSERT INTO t VALUES (2, 'a')", &out);
    try b.execute("INSERT INTO t VALUES (3, 'b')", &out);
    try count(&reader, 1);
    try count(&a, 2);
    try count(&b, 2);
    try a.commitTransaction();
    try count(&reader, 2);
    // The next statement in b sees a's commit (a new snapshot per statement).
    try count(&b, 3);
    try b.execute("SELECT * FROM t WHERE id = 2", &out);
    try check(out.row_count == 1);
    try b.commitTransaction();
    try check(b.transactionStatus() == 'I');
    try count(&reader, 3);
    try b.execute("DELETE FROM t WHERE id = 3", &out);
    try count(&reader, 2);

    // Read-only transactions commit without advancing the commit sequence.
    try a.beginTransaction();
    try count(&a, 2);
    try b.execute("INSERT INTO t VALUES (3, 'published')", &out);
    try count(&a, 3);
    const read_csn = store.database.csn;
    try a.commitTransaction();
    try check(store.database.csn == read_csn);
    try count(&a, 3);
    try a.beginTransaction();
    try a.beginTransaction();
    if (a.execute("INSERT INTO missing VALUES (1)", &out)) |_| return error.InvalidTableAccepted else |err| try check(err == error.TableNotFound);
    try check(a.transactionStatus() == 'E');
    try a.execute("ROLLBACK", &out);
    try count(&a, 3);

    // A same-row writer waits for the deleter; after the delete commits the
    // re-delivered UPDATE re-checks the row (EvalPlanQual) and finds nothing.
    try a.beginTransaction();
    try a.execute("DELETE FROM t WHERE id = 1", &out);
    try blocks(&b, "UPDATE t SET value = 'outside' WHERE id = 1", &out);
    try check(b.wakeReady() == false);
    try a.commitTransaction();
    try check(b.wakeReady());
    try b.execute("UPDATE t SET value = 'outside' WHERE id = 1", &out);
    try check(out.affected_rows == 0 and !b.blocked());
    try b.execute("SELECT * FROM t WHERE id = 1", &out);
    try check(out.row_count == 0);
    try quiescent(&store);

    // Nested control syntax, readonly-looking batches and malformed SQL never write.
    const csn = store.database.csn;
    if (reader.execute("SELECT * FROM t; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    if (reader.execute("SELECTED DELETE FROM t", &out)) |_| return error.InvalidCommandAccepted else |_| {}
    try reader.execute("-- DELETE FROM t\n  SeLeCt * FROM t", &out);
    try check(out.row_count == 2 and store.database.csn == csn);
    var padded: [300]u8 = @splat(' ');
    const select = "SELECT * FROM t";
    @memcpy(padded[padded.len - select.len ..], select);
    try reader.execute(&padded, &out);
    try check(out.row_count == 2 and store.database.csn == csn);
    // Transaction slots are bounded (Config.transactions = 8 here).
    var many: [8]Store.Connection = undefined;
    for (&many, 0..) |*connection, index| {
        connection.* = .{ .store = &store, .id = 100 + index };
        try connection.beginTransaction();
    }
    if (reader.beginTransaction()) |_| return error.TransactionCapacityIgnored else |err| try check(err == error.TransactionCapacity);
    for (&many) |*connection| connection.disconnect();
    try quiescent(&store);
    try count(&reader, 2);
}

const Probe = struct {
    store: *Store,
    durable: DB = .{},
    scratch: DB = .{},
    calls: usize = 0,
    records: usize = 0,
    /// Rows a fresh snapshot sees while the record is being persisted.
    observed: ?usize = null,
    fail_after: ?usize = null,
    last_batch: [4096]u8 = undefined,
    last_length: usize = 0,

    fn commit(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(context orelse return error.MissingContext));
        self.calls += 1;
        // No publish before flush: another snapshot still sees the old state.
        if (self.observed) |rows| {
            var out: DB.Result = .{};
            try self.store.database.execute("SELECT * FROM t", &out);
            try check(out.row_count == rows);
        }
        self.last_length = bytes.len;
        if (bytes.len > self.last_batch.len) return error.TestBatchCapacity;
        @memcpy(self.last_batch[0..bytes.len], bytes);
        // sql.Database stores persist kind-3 change records, one op per row
        // or DDL change; replay applies the whole record atomically.
        const ops = try DB.changeRecordOps(bytes);
        if (self.fail_after) |limit| if (ops > limit) return error.InjectedStorageFailure;
        if (ops == 0) return error.EmptyDurableCommit;
        self.scratch.copyFrom(&self.durable);
        try self.scratch.applyChangeRecord(bytes, &replay_scratch);
        self.records += ops;
        self.durable.copyFrom(&self.scratch);
    }
};

fn durability() !void {
    var encode: [1024]u8 = undefined;
    var store: Store = .{ .durability_required = true, .encode_buffer = &encode };
    var connection: Store.Connection = .{ .store = &store, .id = 1 };
    var observer: Store.Connection = .{ .store = &store, .id = 2 };
    var out: DB.Result = .{};
    out.affected_rows = 73;
    if (connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out)) |_| return error.UnloggedWrite else |err| try check(err == error.StorageUnavailable);
    try check(store.database.csn == 0 and out.affected_rows == 73);
    try quiescent(&store);
    var probe: Probe = .{ .store = &store };
    store.commit_ctx = &probe;
    store.commit_fn = Probe.commit;
    try connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out);
    try check(probe.calls == 1 and probe.records == 1 and store.database.csn == 1);
    try count(&observer, 0);
    probe.observed = 0;
    try connection.execute("INSERT INTO t VALUES (1, 'one')", &out);
    try check(probe.calls == 2 and probe.records == 2 and store.database.csn == 2);
    try connection.beginTransaction();
    try connection.execute("INSERT INTO t VALUES (2, 'a;\nb')", &out);
    try connection.execute("UPDATE t SET value = 'changed' WHERE id = 1", &out);
    try count(&connection, 2);
    try count(&observer, 1);
    try check(probe.calls == 2);
    probe.observed = 1;
    try connection.commitTransaction();
    try check(probe.calls == 3 and probe.records == 4 and store.database.csn == 3);
    try count(&observer, 2);
    try probe.durable.execute("SELECT * FROM t WHERE id = 2", &out);
    try check(equal(out.rows[0].cells[1].text.slice(), "a;\nb"));
    // The COMMIT record carries both completed statements' row ops.
    try check(try DB.changeRecordOps(probe.last_batch[0..probe.last_length]) == 2);
    try probe.durable.execute("SELECT * FROM t WHERE id = 1", &out);
    try check(equal(out.rows[0].cells[1].text.slice(), "changed"));
    try check(connection.tx == null);

    const calls = probe.calls;
    const csn = store.database.csn;
    // Read-only test (§4.6): a statement with no write never reaches the
    // hook, whether autocommit or in an explicit transaction; neither do
    // malformed or failed statements.
    try observer.execute("-- leading comment\n SELECT * FROM t", &out);
    try check(out.row_count == 2 and probe.calls == calls);
    try observer.beginTransaction();
    try count(&observer, 2);
    try observer.commitTransaction();
    try check(probe.calls == calls and store.database.csn == csn);
    if (connection.execute("INSERT INTO t VALUES (1, 'duplicate')", &out)) |_| return error.DuplicateAccepted else |err| try check(err == error.PrimaryKeyViolation);
    if (connection.execute("SELECT * FROM t; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    try check(probe.calls == calls and store.database.csn == csn);
    try connection.beginTransaction();
    try connection.execute("DELETE FROM t", &out);
    connection.disconnect();
    try count(&observer, 2);
    try check(probe.calls == calls);
    try quiescent(&store);
    // A mutation that matched no row has an empty write set: read-only too.
    try connection.execute("UPDATE t SET value = 'none' WHERE id = 99", &out);
    try check(probe.calls == calls and out.affected_rows == 0);

    // The hook runs before publication. Its error leaves both the public
    // database and caller result untouched, and poisons further writes.
    out.affected_rows = 91;
    probe.fail_after = 0;
    probe.observed = 2;
    if (connection.execute("DELETE FROM t", &out)) |_| return error.FailedWriteAcknowledged else |err| try check(err == error.InjectedStorageFailure);
    try check(store.storage_failed and store.database.csn == csn and out.affected_rows == 91);
    try count(&observer, 2);
    try quiescent(&store);
    const failed_calls = probe.calls;
    if (connection.execute("DELETE FROM t", &out)) |_| return error.PoisonedWriteAcknowledged else |err| try check(err == error.StorageUnavailable);
    try check(probe.calls == failed_calls);
    try count(&observer, 2);
    // Reads still work while storage is unavailable.
    try label(&observer, "SELECT * FROM t WHERE id = 1", "changed");
    // Recovery is the owner's responsibility; this test restores its fake sink.
    store.storage_failed = false;
    probe.fail_after = 1;
    try connection.beginTransaction();
    try connection.execute("INSERT INTO t VALUES (3, 'three')", &out);
    try connection.execute("DELETE FROM t WHERE id = 1", &out);
    if (connection.commitTransaction()) |_| return error.FailedTransactionAcknowledged else |err| try check(err == error.InjectedStorageFailure);
    // A failed COMMIT ends the transaction (rolled back), as in PostgreSQL.
    try check(connection.transactionStatus() == 'I' and store.storage_failed and store.database.csn == csn);
    try count(&observer, 2);
    try probe.durable.execute("SELECT * FROM t", &out);
    try check(out.row_count == 2);
    try quiescent(&store);

    // The encode buffer (transaction-bytes) bounds a record: overflow is
    // TransactionLogCapacity (53200) and nothing changes.
    store.storage_failed = false;
    probe.fail_after = null;
    store.encode_buffer = encode[0..16];
    if (connection.execute("UPDATE t SET value = 'too long for sixteen bytes'", &out)) |_| return error.LogCapacityIgnored else |err| try check(err == error.TransactionLogCapacity);
    try check(probe.calls == failed_calls + 1 and !store.storage_failed);
    try label(&observer, "SELECT * FROM t WHERE id = 1", "changed");
    store.encode_buffer = &encode;
    try connection.beginTransaction();
    try count(&connection, 2);
    try connection.commitTransaction();
    try check(store.database.csn == csn);
    try quiescent(&store);
}

// Two transactions update the same row: the second waits, then applies its
// change to the first one's committed version (no lost update).
fn interleavings() !void {
    var store: Store = .{};
    var a = Store.Connection{ .store = &store, .id = 1 };
    var b = Store.Connection{ .store = &store, .id = 2 };
    var observer = Store.Connection{ .store = &store, .id = 3 };
    var out: DB.Result = .{};
    try observer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT, n BIGINT)", &out);
    try observer.execute("INSERT INTO t VALUES (1, 'b', 0)", &out);
    for (0..256) |iteration| {
        // The second (waiting) writer always wins; its value alternates.
        const winner: []const u8 = if (iteration % 2 == 0) "b" else "a";
        const previous: []const u8 = if (iteration == 0 or iteration % 2 == 1) "b" else "a";
        const first_value: []const u8 = if (iteration % 2 == 0) "a" else "b";
        const first = if (iteration % 2 == 0) &a else &b;
        const second = if (iteration % 2 == 0) &b else &a;
        const first_sql = if (iteration % 2 == 0) "UPDATE t SET value = 'a', n = n + 1 WHERE id = 1" else "UPDATE t SET value = 'b', n = n + 1 WHERE id = 1";
        const second_sql = if (iteration % 2 == 0) "UPDATE t SET value = 'b', n = n + 1 WHERE id = 1" else "UPDATE t SET value = 'a', n = n + 1 WHERE id = 1";
        try first.beginTransaction();
        try second.beginTransaction();
        try first.execute(first_sql, &out);
        try blocks(second, second_sql, &out);
        try check(second.transactionStatus() == 'T');
        try observer.execute("SELECT * FROM t", &out);
        try check(out.row_count == 1 and equal(out.rows[0].cells[1].text.slice(), previous));
        // The writer sees its own change; the waiter is still parked.
        try first.execute("SELECT * FROM t", &out);
        try check(equal(out.rows[0].cells[1].text.slice(), first_value) and second.blocked());
        const csn = store.database.csn;
        try first.commitTransaction();
        try check(store.database.csn == csn + 1 and second.wakeReady());
        try second.execute(second_sql, &out);
        try check(out.affected_rows == 1 and !second.blocked());
        try second.commitTransaction();
        try check(first.transactionStatus() == 'I' and second.transactionStatus() == 'I');
        try observer.execute("SELECT * FROM t", &out);
        try check(out.row_count == 1 and equal(out.rows[0].cells[1].text.slice(), winner));
        try check(out.rows[0].cells[2].integer == @as(i64, @intCast(2 * (iteration + 1))));
        try check(store.database.csn == csn + 2);
    }
    try quiescent(&store);
}

fn framing() !void {
    const malformed = [_][]const u8{
        &.{1},
        &.{ 1, 0 },
        &.{ 1, 0, 0 },
        &.{ 0, 0, 0, 0 },
        &.{ 1, 0, 0, 0 },
        &.{ 255, 255, 255, 255, 1 },
        &.{ 1, 0, 1, 0, 1 },
    };
    for (malformed) |bytes| {
        var iterator = store_module.BatchIterator{ .bytes = bytes };
        if (iterator.next()) |_| return error.MalformedBatchAccepted else |err| try check(err == error.InvalidCommitBatch);
    }
    var empty = store_module.BatchIterator{ .bytes = &.{} };
    try check((try empty.next()) == null);
    var valid = store_module.BatchIterator{ .bytes = &.{ 1, 0, 0, 0, 'a', 2, 0, 0, 0, 'b', 'c' } };
    try check(equal((try valid.next()).?, "a"));
    try check(equal((try valid.next()).?, "bc"));
    try check((try valid.next()) == null);
    var invalid_tail = store_module.BatchIterator{ .bytes = &.{ 1, 0, 0, 0, 'a', 1 } };
    try check(equal((try invalid_tail.next()).?, "a"));
    if (invalid_tail.next()) |_| return error.MalformedTailAccepted else |err| try check(err == error.InvalidCommitBatch);
}

const CountingSink = struct {
    calls: usize = 0,
    fail: bool = false,

    fn commit(context: ?*anyopaque, record: []const u8) anyerror!void {
        const self: *CountingSink = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.fail) return error.InjectedStorageFailure;
        _ = try DB.changeRecordOps(record);
    }
};

// Durable point writes persist one record each with no database copy (the
// store holds exactly one Raw; connections hold none).
fn mutationBoundaryStore() !void {
    var encode: [1024]u8 = undefined;
    var sink: CountingSink = .{};
    var store: Store = .{ .durability_required = true, .commit_ctx = &sink, .commit_fn = CountingSink.commit, .encode_buffer = &encode };
    var connection = Store.Connection{ .store = &store, .id = 1 };
    var result: DB.Result = .{};
    try check(@sizeOf(Store.Connection) < DB.storageBytes() / 4);
    try connection.execute("CREATE TABLE t (id INT PRIMARY KEY, value TEXT)", &result);
    try connection.execute("INSERT INTO t VALUES (1, 'one')", &result);
    try connection.execute("UPDATE t SET value = 'two' WHERE id = 1", &result);
    try connection.execute("SELECT * FROM t WHERE id = 1", &result);
    try check(result.row_count == 1 and equal(result.rows[0].cells[1].text.slice(), "two"));
    try check(sink.calls == 3 and store.database.csn == 3);
    if (connection.execute("INSERT INTO t VALUES (1, 'duplicate')", &result)) |_| return error.InvalidMutationPersisted else |err| try check(err == error.PrimaryKeyViolation);
    if (connection.execute("DELETE FROM t trailing", &result)) |_| return error.InvalidMutationPersisted else |err| try check(err == error.Syntax);
    try check(sink.calls == 3 and !store.storage_failed);
    sink.fail = true;
    result.affected_rows = 91;
    if (connection.execute("DELETE FROM t", &result)) |_| return error.CommitFailureIgnored else |err| try check(err == error.InjectedStorageFailure);
    try check(store.storage_failed and store.database.csn == 3 and result.affected_rows == 91);
    try connection.execute("SELECT * FROM t WHERE id = 1", &result);
    try check(result.row_count == 1 and equal(result.rows[0].cells[1].text.slice(), "two"));
    try check(sink.calls == 4);
    store.storage_failed = false;
    sink.fail = false;
    try connection.beginTransaction();
    try connection.execute("INSERT INTO t VALUES (2, 'private')", &result);
    try connection.commitTransaction();
    try check(store.database.csn == 4 and sink.calls == 5);
    try quiescent(&store);
}

fn setup(store: *Store, connection: *Store.Connection) !void {
    var out: DB.Result = .{};
    _ = store;
    try connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT, n BIGINT)", &out);
    try connection.execute("INSERT INTO t VALUES (1, 'one', 0)", &out);
    try connection.execute("INSERT INTO t VALUES (2, 'two', 0)", &out);
    try connection.execute("INSERT INTO t VALUES (3, 'three', 0)", &out);
}

// §4.4/§4.5 contracts: park-then-cancel and park-and-re-deliver.
fn parking() !void {
    var store: Store = .{};
    var a = Store.Connection{ .store = &store, .id = 1 };
    var b = Store.Connection{ .store = &store, .id = 2 };
    var observer = Store.Connection{ .store = &store, .id = 3 };
    var out: DB.Result = .{};
    try setup(&store, &observer);
    const base = store.database.usage();
    try check(base.pending_versions == 0);

    // Park-and-re-deliver: B updates row 1, parks on row 2 (held by A), A
    // commits, the same bytes resume: three rows, UPDATE 3, row 2 re-read.
    try a.beginTransaction();
    try a.execute("UPDATE t SET n = 9 WHERE id = 2", &out);
    try blocks(&b, "UPDATE t SET n = n + 1", &out);
    // A's new version and mark, plus B's applied row 1 (version and mark).
    try check(store.database.usage().pending_versions == 4);
    try check(store.database.usage().transactions == 2);
    try a.commitTransaction();
    try b.execute("UPDATE t SET n = n + 1", &out);
    try check(out.affected_rows == 3 and out.command == .update);
    try observer.execute("SELECT n FROM t ORDER BY id", &out);
    try check(out.row_count == 3 and out.rows[0].cells[0].integer == 1 and out.rows[1].cells[0].integer == 10 and out.rows[2].cells[0].integer == 1);
    try quiescent(&store);

    // Park-then-cancel inside a block: the statement had applied row 1. The
    // engine aborts exactly the statement subtransaction (test_sql_mvcc
    // checks the transaction keeps its earlier insert); the store then
    // applies PostgreSQL's error rule: the block fails (status E) and its
    // work and locks are released at error time, so waiters proceed.
    try b.beginTransaction();
    try b.execute("INSERT INTO t VALUES (4, 'four', 0)", &out);
    try a.beginTransaction();
    try a.execute("UPDATE t SET n = 50 WHERE id = 2", &out);
    const before = store.database.usage();
    try blocks(&b, "UPDATE t SET n = n + 1 WHERE id < 4", &out);
    try check(store.database.usage().pending_versions == before.pending_versions + 2);
    b.requestCancel();
    try check(b.wakeReady());
    if (b.execute("UPDATE t SET n = n + 1 WHERE id < 4", &out)) |_| return error.CancelIgnored else |err| try check(err == error.QueryCanceled);
    try check(b.transactionStatus() == 'E' and !b.blocked());
    // The failed block released everything; a's work is untouched.
    try check(store.database.usage().pending_versions == before.pending_versions - 1);
    try a.commitTransaction();
    try b.rollbackTransaction();
    try observer.execute("SELECT n FROM t ORDER BY id", &out);
    try check(out.row_count == 3 and out.rows[0].cells[0].integer == 1 and out.rows[1].cells[0].integer == 50);
    try quiescent(&store);

    // Park-then-cancel in autocommit: status I, nothing left behind.
    try a.beginTransaction();
    try a.execute("UPDATE t SET n = 60 WHERE id = 3", &out);
    try blocks(&b, "UPDATE t SET n = 0", &out);
    try check(b.transactionStatus() == 'I');
    b.requestCancel();
    if (b.execute("UPDATE t SET n = 0", &out)) |_| return error.CancelIgnored else |err| try check(err == error.QueryCanceled);
    try check(b.transactionStatus() == 'I' and b.tx == null);
    try a.commitTransaction();
    try observer.execute("SELECT n FROM t ORDER BY id", &out);
    try check(out.rows[0].cells[0].integer == 1 and out.rows[2].cells[0].integer == 60);
    try quiescent(&store);

    // Disconnect while parked aborts the statement and releases its locks.
    try a.beginTransaction();
    try a.execute("DELETE FROM t WHERE id = 1", &out);
    try blocks(&b, "UPDATE t SET n = 7 WHERE id = 1", &out);
    b.disconnect();
    try check(!b.blocked());
    try a.rollbackTransaction();
    try quiescent(&store);

    // Unique-key race: an INSERT of a key held by a live inserter waits;
    // commit -> 23505, rollback -> INSERT succeeds.
    try a.beginTransaction();
    try a.execute("INSERT INTO t VALUES (5, 'a', 0)", &out);
    try blocks(&b, "INSERT INTO t VALUES (5, 'b', 0)", &out);
    try a.commitTransaction();
    if (b.execute("INSERT INTO t VALUES (5, 'b', 0)", &out)) |_| return error.DuplicateAccepted else |err| try check(err == error.PrimaryKeyViolation);
    try a.beginTransaction();
    try a.execute("INSERT INTO t VALUES (6, 'a', 0)", &out);
    try blocks(&b, "INSERT INTO t VALUES (6, 'b', 0)", &out);
    try a.rollbackTransaction();
    try b.execute("INSERT INTO t VALUES (6, 'b', 0)", &out);
    try check(out.affected_rows == 1);
    try label(&observer, "SELECT * FROM t WHERE id = 6", "b");
    try quiescent(&store);

    // A re-delivered statement must be the parked one.
    try a.beginTransaction();
    try a.execute("UPDATE t SET n = 1 WHERE id = 1", &out);
    try blocks(&b, "UPDATE t SET n = 2 WHERE id = 1", &out);
    if (b.execute("UPDATE t SET n = 3 WHERE id = 1", &out)) |_| return error.FingerprintIgnored else |err| try check(err == error.QueryCanceled);
    try a.rollbackTransaction();
    try quiescent(&store);
}

fn timers() !void {
    var store: Store = .{};
    var a = Store.Connection{ .store = &store, .id = 1 };
    var b = Store.Connection{ .store = &store, .id = 2 };
    var observer = Store.Connection{ .store = &store, .id = 3 };
    var out: DB.Result = .{};
    try setup(&store, &observer);
    const ms: i64 = 1000000;

    // lock_timeout -> 55P03 once its deadline passes while still blocked.
    try b.execute("SET lock_timeout = '200ms'", &out);
    try check(out.command == .set);
    try b.execute("SHOW lock_timeout", &out);
    try check(out.row_count == 1 and equal(out.rows[0].cells[0].text.slice(), "200ms") and equal(out.column_names[0].slice(), "lock_timeout"));
    try a.beginTransaction();
    try a.execute("UPDATE t SET n = 1 WHERE id = 1", &out);
    store.now_ns = 1000 * ms;
    try blocks(&b, "UPDATE t SET n = 2 WHERE id = 1", &out);
    try check(b.nextDeadline().? == 1200 * ms and !b.wakeReady());
    store.now_ns = 1199 * ms;
    try check(!b.wakeReady());
    store.now_ns = 1200 * ms;
    try check(b.wakeReady());
    if (b.execute("UPDATE t SET n = 2 WHERE id = 1", &out)) |_| return error.TimeoutIgnored else |err| try check(err == error.LockNotAvailable);
    try b.execute("RESET lock_timeout", &out);
    try b.execute("SHOW lock_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "0"));

    // statement_timeout -> 57014.
    try b.execute("SET statement_timeout TO 1000", &out);
    try b.execute("SHOW statement_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "1s"));
    try blocks(&b, "UPDATE t SET n = 3 WHERE id = 1", &out);
    store.now_ns += 1000 * ms;
    if (b.execute("UPDATE t SET n = 3 WHERE id = 1", &out)) |_| return error.TimeoutIgnored else |err| try check(err == error.QueryCanceled);
    try b.execute("SET statement_timeout = 0", &out);

    // NOWAIT and SKIP LOCKED.
    if (b.execute("SELECT id FROM t WHERE id = 1 FOR UPDATE NOWAIT", &out)) |_| return error.NowaitIgnored else |err| try check(err == error.LockNotAvailable);
    try b.execute("SELECT id FROM t ORDER BY id FOR UPDATE SKIP LOCKED", &out);
    try check(out.row_count == 2 and out.rows[0].cells[0].integer == 2);
    try a.commitTransaction();
    try quiescent(&store);

    // Deadlock: A waits for B, then B waits for A; A's one-time check after
    // deadlock_timeout finds the cycle and A is the victim (40P01).
    try a.beginTransaction();
    try b.beginTransaction();
    try a.execute("UPDATE t SET n = 10 WHERE id = 1", &out);
    try b.execute("UPDATE t SET n = 20 WHERE id = 2", &out);
    store.now_ns = 5000 * ms;
    try blocks(&a, "UPDATE t SET n = 11 WHERE id = 2", &out);
    store.now_ns = 5300 * ms;
    try blocks(&b, "UPDATE t SET n = 21 WHERE id = 1", &out);
    try check(a.nextDeadline().? == 6000 * ms);
    store.now_ns = 6000 * ms;
    try check(a.wakeReady() and !b.wakeReady());
    if (a.execute("UPDATE t SET n = 11 WHERE id = 2", &out)) |_| return error.DeadlockIgnored else |err| try check(err == error.DeadlockDetected);
    try check(a.transactionStatus() == 'E');
    // The victim's locks are gone, so the survivor proceeds and commits.
    try check(b.wakeReady());
    try b.execute("UPDATE t SET n = 21 WHERE id = 1", &out);
    try check(out.affected_rows == 1);
    try b.commitTransaction();
    try a.rollbackTransaction();
    try observer.execute("SELECT n FROM t ORDER BY id", &out);
    try check(out.rows[0].cells[0].integer == 21 and out.rows[1].cells[0].integer == 20);
    try quiescent(&store);

    // FOR SHARE is shared; FOR UPDATE and writers wait for it.
    try a.beginTransaction();
    try b.beginTransaction();
    try a.execute("SELECT id FROM t WHERE id = 1 FOR SHARE", &out);
    try b.execute("SELECT id FROM t WHERE id = 1 FOR SHARE", &out);
    try check(out.row_count == 1 and store.database.usage().row_locks == 1);
    try blocks(&observer, "UPDATE t SET n = 0 WHERE id = 1", &out);
    try a.commitTransaction();
    try blocks(&observer, "UPDATE t SET n = 0 WHERE id = 1", &out);
    try b.commitTransaction();
    try observer.execute("UPDATE t SET n = 0 WHERE id = 1", &out);
    try check(out.affected_rows == 1);
    try quiescent(&store);

    // SET LOCAL ends with the transaction; ROLLBACK reverts SET.
    try b.beginTransaction();
    try b.execute("SET LOCAL lock_timeout = '5s'", &out);
    try b.execute("SHOW lock_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "5s"));
    try b.commitTransaction();
    try b.execute("SHOW lock_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "0"));
    try b.beginTransaction();
    try b.execute("SET lock_timeout = 300", &out);
    try b.rollbackTransaction();
    try b.execute("SHOW lock_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "0"));
    try b.execute("SHOW transaction_isolation", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "read committed"));
    if (b.execute("BEGIN ISOLATION LEVEL SERIALIZABLE", &out)) |_| return error.IsolationAccepted else |err| try check(err == error.UnsupportedStatement);
    if (b.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", &out)) |_| return error.IsolationAccepted else |err| try check(err == error.UnsupportedStatement);
    try check(b.transactionStatus() == 'I');
    var startup: Store.Connection = .{ .store = &store, .id = 9 };
    try startup.startupParameter("options", "-c statement_timeout=1000 -c lock_timeout=2s");
    try startup.execute("SHOW statement_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "1s"));
    try startup.execute("SET statement_timeout = 5", &out);
    try startup.execute("RESET ALL", &out);
    try startup.execute("SHOW lock_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "2s"));
}

fn savepoints() !void {
    var store: Store = .{};
    var a = Store.Connection{ .store = &store, .id = 1 };
    var b = Store.Connection{ .store = &store, .id = 2 };
    var out: DB.Result = .{};
    try setup(&store, &a);
    if (a.execute("SAVEPOINT s", &out)) |_| return error.SavepointOutsideBlock else |err| try check(err == error.NoActiveTransaction);
    try a.beginTransaction();
    try a.execute("SAVEPOINT s1", &out);
    try check(out.command == .savepoint);
    try a.execute("UPDATE t SET value = 'x' WHERE id = 1", &out);
    try a.execute("SAVEPOINT s2", &out);
    try a.execute("UPDATE t SET value = 'y' WHERE id = 2", &out);
    try a.execute("ROLLBACK TO SAVEPOINT s1", &out);
    try check(out.command == .rollback);
    try label(&a, "SELECT * FROM t WHERE id = 1", "one");
    // The row lock taken after s1 is gone: another writer proceeds.
    try b.execute("UPDATE t SET value = 'b' WHERE id = 1", &out);
    try check(out.affected_rows == 1);
    // Repeated names: the newest wins; RELEASE then ROLLBACK TO -> 3B001.
    try a.execute("SAVEPOINT r", &out);
    try a.execute("UPDATE t SET value = 'r1' WHERE id = 3", &out);
    try a.execute("SAVEPOINT r", &out);
    try a.execute("UPDATE t SET value = 'r2' WHERE id = 3", &out);
    try a.execute("ROLLBACK TO r", &out);
    try label(&a, "SELECT * FROM t WHERE id = 3", "r1");
    try a.execute("RELEASE SAVEPOINT r", &out);
    try check(out.command == .release);
    try a.execute("RELEASE r", &out);
    if (a.execute("ROLLBACK TO r", &out)) |_| return error.ReleasedSavepoint else |err| try check(err == error.SavepointNotFound);
    try check(a.transactionStatus() == 'E');
    try a.execute("ROLLBACK TO s1", &out);
    try check(a.transactionStatus() == 'T');
    // A statement error then ROLLBACK TO returns to T with the earlier data.
    try a.execute("UPDATE t SET value = 'kept' WHERE id = 2", &out);
    try a.execute("SAVEPOINT e", &out);
    try a.execute("UPDATE t SET value = 'lost' WHERE id = 2", &out);
    if (a.execute("INSERT INTO t VALUES (1, 'dup', 0)", &out)) |_| return error.DuplicateAccepted else |err| try check(err == error.PrimaryKeyViolation);
    try check(a.transactionStatus() == 'E');
    if (a.execute("SELECT * FROM t", &out)) |_| return error.FailedBlockRead else |err| try check(err == error.TransactionFailed);
    try a.execute("ROLLBACK TO SAVEPOINT e", &out);
    try check(a.transactionStatus() == 'T');
    try label(&a, "SELECT * FROM t WHERE id = 2", "kept");
    // DDL inside a rolled-back savepoint disappears; settings revert too.
    try a.execute("SAVEPOINT ddl", &out);
    try a.execute("SET lock_timeout = 900", &out);
    try a.execute("CREATE TABLE u (id INTEGER)", &out);
    try a.execute("INSERT INTO u VALUES (1)", &out);
    try a.execute("ROLLBACK TO ddl", &out);
    try a.execute("SHOW lock_timeout", &out);
    try check(equal(out.rows[0].cells[0].text.slice(), "0"));
    if (a.execute("SELECT * FROM u", &out)) |_| return error.TableSurvived else |err| try check(err == error.TableNotFound);
    try check(a.transactionStatus() == 'E');
    try a.execute("ROLLBACK TO ddl", &out);
    try a.commitTransaction();
    try label(&b, "SELECT * FROM t WHERE id = 2", "kept");
    try label(&b, "SELECT * FROM t WHERE id = 1", "b");
    try quiescent(&store);

    // Transactional DDL across sessions: an uncommitted CREATE is invisible,
    // ROLLBACK removes it, ROLLBACK of DROP restores the table and rows.
    try a.beginTransaction();
    try a.execute("CREATE TABLE u (id INTEGER PRIMARY KEY)", &out);
    try a.execute("INSERT INTO u VALUES (1)", &out);
    if (b.execute("SELECT * FROM u", &out)) |_| return error.UncommittedTableVisible else |err| try check(err == error.TableNotFound);
    try a.rollbackTransaction();
    if (b.execute("SELECT * FROM u", &out)) |_| return error.RolledBackTableVisible else |err| try check(err == error.TableNotFound);
    try a.beginTransaction();
    try a.execute("DROP TABLE t", &out);
    // The dropper no longer resolves the name (describe never fails the block).
    if (a.describe("SELECT * FROM t", &out)) |_| return error.DroppedTableVisible else |err| try check(err == error.TableNotFound);
    try blocks(&b, "SELECT * FROM t", &out);
    try a.rollbackTransaction();
    try b.execute("SELECT * FROM t", &out);
    try check(out.row_count == 3);
    try quiescent(&store);
}

pub fn main() !void {
    try transactions();
    try durability();
    try interleavings();
    try framing();
    try mutationBoundaryStore();
    try parking();
    try timers();
    try savepoints();
    try check(assertions >= 2177);
    std.debug.print("store: {d} assertions passed\n", .{assertions});
}
