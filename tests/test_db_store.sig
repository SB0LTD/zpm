const std = @import("std");
const sql = @import("sql");
const store_module = @import("db_store");
const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 8, .text_bytes = 32, .boolean_integers = true });
const Store = store_module.Store(DB);
var assertions: usize = 0;

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

fn transactions() !void {
    var store: Store = .{};
    var wa: DB = .{};
    var wb: DB = .{};
    var a: Store.Connection = .{ .store = &store, .id = 1, .transaction_workspace = &wa };
    var b: Store.Connection = .{ .store = &store, .id = 2, .transaction_workspace = &wb };
    var reader: Store.Connection = .{ .store = &store, .id = 3 };
    var out: DB.Result = .{};
    try a.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out);
    const created_generation = store.generation;
    try a.beginTransaction();
    try a.execute("INSERT INTO t VALUES (1, 'rollback')", &out);
    try count(&a, 1);
    try count(&b, 0);
    try count(&reader, 0);
    try check(a.transactionStatus() == 'T' and b.transactionStatus() == 'I');
    try a.rollbackTransaction();
    try check(store.generation == created_generation);
    try count(&b, 0);
    try a.execute("BEGIN", &out);
    try a.execute("INSERT INTO t VALUES (1, 'commit')", &out);
    try a.execute("COMMIT", &out);
    try count(&b, 1);
    try check(store.generation == created_generation + 1);
    try a.beginTransaction();
    try a.execute("UPDATE t SET value = 'gone'", &out);
    a.failTransaction();
    try check(a.transactionStatus() == 'E');
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
    try check(a.transactionStatus() == 'I' and !a.dirty and a.log_used == 0);
    try b.execute("SELECT 1", &out);
    try check(out.rows[0].cells[0].integer == 1);
    if (b.execute("SET unknown = 1", &out)) |_| return error.UnknownSettingAccepted else |_| {}
    var invalid: Store.Connection = .{ .store = &store, .id = 0, .failed = true };
    invalid.disconnect();
    try check(invalid.transactionStatus() == 'I');
    if (invalid.commitTransaction()) |_| return error.InvalidConnectionAccepted else |err| try check(err == error.InvalidConnection);
    if (invalid.execute("SELECT 1", &out)) |_| return error.InvalidConnectionAccepted else |err| try check(err == error.InvalidConnection);
    try count(&b, 1);
    if (b.execute("B E G I N", &out)) |_| return error.InvalidCommandAccepted else |_| {}
    if (b.execute("BEGIN; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    try b.execute("CREATE TABLE bools (id INTEGER PRIMARY KEY, flag BOOLEAN)", &out);
    try b.execute("INSERT INTO bools VALUES (1, 0)", &out);
    try b.execute("SELECT * FROM bools WHERE flag = 0", &out);
    try check(out.row_count == 1 and !out.rows[0].cells[1].boolean);
    try b.execute("UPDATE bools SET flag = 1 WHERE id = 1", &out);
    try b.execute("SELECT * FROM bools WHERE flag = 1", &out);
    try check(out.row_count == 1 and out.rows[0].cells[1].boolean);
    if (b.execute("UPDATE bools SET flag = 2", &out)) |_| return error.InvalidBooleanAccepted else |err| try check(err == error.TypeMismatch);

    // Independent repeatable snapshots remain readable during other commits.
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
    try count(&b, 2);
    try b.execute("SELECT * FROM t WHERE id = 2", &out);
    try check(out.row_count == 0);
    if (b.commitTransaction()) |_| return error.LostUpdate else |err| try check(err == error.SerializationFailure);
    try check(b.transactionStatus() == 'E');
    try b.rollbackTransaction();
    try count(&b, 2);
    try b.execute("SELECT * FROM t WHERE id = 3", &out);
    try check(out.row_count == 0);

    // Read-only transactions can commit after writes without serializing them.
    try a.beginTransaction();
    try count(&a, 2);
    try b.execute("INSERT INTO t VALUES (3, 'published')", &out);
    try count(&a, 2);
    const read_generation = store.generation;
    try a.commitTransaction();
    try check(store.generation == read_generation);
    try count(&a, 3);
    try a.beginTransaction();
    try a.beginTransaction();
    if (a.execute("INSERT INTO missing VALUES (1)", &out)) |_| return error.InvalidTableAccepted else |err| try check(err == error.TableNotFound);
    try check(a.transactionStatus() == 'E');
    try a.execute("ROLLBACK", &out);
    try count(&a, 3);

    // An autocommit writer invalidates a stale transaction without blocking.
    try a.beginTransaction();
    try a.execute("DELETE FROM t WHERE id = 1", &out);
    try b.execute("UPDATE t SET value = 'outside' WHERE id = 1", &out);
    if (a.commitTransaction()) |_| return error.StaleCommitAccepted else |err| try check(err == error.SerializationFailure);
    try a.execute("COMMIT", &out); // failed COMMIT is a rollback, like PostgreSQL.
    try check(a.transactionStatus() == 'I');
    try b.execute("SELECT * FROM t WHERE id = 1", &out);
    try check(out.row_count == 1 and equal(out.rows[0].cells[1].text.slice(), "outside"));
    if (reader.beginTransaction()) |_| return error.MissingWorkspaceAccepted else |err| try check(err == error.TransactionCapacity);
    reader.transaction_workspace = &store.database;
    if (reader.beginTransaction()) |_| return error.AliasedWorkspaceAccepted else |err| try check(err == error.InvalidWorkspace);
    reader.transaction_workspace = null;
    try count(&reader, 3);

    // Nested control syntax, readonly-looking batches and malformed SQL never write.
    const generation = store.generation;
    if (reader.execute("SELECT * FROM t; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    if (reader.execute("SELECTED DELETE FROM t", &out)) |_| return error.InvalidCommandAccepted else |_| {}
    try reader.execute("-- DELETE FROM t\n  SeLeCt * FROM t", &out);
    try check(out.row_count == 3 and store.generation == generation);
    var padded: [300]u8 = @splat(' ');
    const select = "SELECT * FROM t";
    @memcpy(padded[padded.len - select.len ..], select);
    try reader.execute(&padded, &out);
    try check(out.row_count == 3 and store.generation == generation);
    store.generation = 18446744073709551615;
    if (reader.execute("DELETE FROM t", &out)) |_| return error.GenerationWrapped else |err| try check(err == error.GenerationExhausted);
    try count(&reader, 3);
}

const Probe = struct {
    store: *Store,
    durable: DB = .{},
    scratch: DB = .{},
    result: DB.Result = .{},
    calls: usize = 0,
    records: usize = 0,
    expected_generation: u64 = 0,
    fail_after: ?usize = null,
    last_batch: [4096]u8 = undefined,
    last_length: usize = 0,

    fn commit(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(context orelse return error.MissingContext));
        self.calls += 1;
        try check(self.store.generation == self.expected_generation);
        self.last_length = bytes.len;
        if (bytes.len > self.last_batch.len) return error.TestBatchCapacity;
        @memcpy(self.last_batch[0..bytes.len], bytes);
        self.scratch = self.durable;
        var iterator = store_module.BatchIterator{ .bytes = bytes };
        var completed: usize = 0;
        while (try iterator.next()) |source| {
            if (self.fail_after != null and completed == self.fail_after.?) return error.InjectedStorageFailure;
            try self.scratch.execute(source, &self.result);
            completed += 1;
        }
        if (completed == 0) return error.EmptyDurableCommit;
        self.records += completed;
        self.durable = self.scratch;
    }
};

fn durability() !void {
    var candidate: DB = .{};
    var workspace: DB = .{};
    var log: [1024]u8 = undefined;
    var store: Store = .{ .autocommit_workspace = &candidate, .durability_required = true };
    var connection: Store.Connection = .{
        .store = &store,
        .id = 1,
        .transaction_workspace = &workspace,
        .transaction_log = &log,
    };
    var observer: Store.Connection = .{ .store = &store, .id = 2 };
    var out: DB.Result = .{};
    out.affected_rows = 73;
    if (connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out)) |_| return error.UnloggedWrite else |err| try check(err == error.StorageUnavailable);
    try check(store.generation == 0 and out.affected_rows == 73);
    var probe: Probe = .{ .store = &store };
    store.commit_ctx = &probe;
    store.commit_fn = Probe.commit;
    try connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out);
    try check(probe.calls == 1 and probe.records == 1 and store.generation == 1);
    try count(&observer, 0);
    probe.expected_generation = store.generation;
    try connection.execute("INSERT INTO t VALUES (1, 'one')", &out);
    try check(probe.calls == 2 and probe.records == 2 and store.generation == 2);
    try connection.beginTransaction();
    try connection.execute("INSERT INTO t VALUES (2, 'a;\nb')", &out);
    try connection.execute("UPDATE t SET value = 'changed' WHERE id = 1", &out);
    try count(&connection, 2);
    try count(&observer, 1);
    try check(probe.calls == 2 and connection.log_used > 0);
    probe.expected_generation = store.generation;
    try connection.commitTransaction();
    try check(probe.calls == 3 and probe.records == 4 and store.generation == 3);
    try count(&observer, 2);
    try probe.durable.execute("SELECT * FROM t WHERE id = 2", &out);
    try check(equal(out.rows[0].cells[1].text.slice(), "a;\nb"));
    var iterator: store_module.BatchIterator = .{ .bytes = probe.last_batch[0..probe.last_length] };
    try check(equal((try iterator.next()).?, "INSERT INTO t VALUES (2, 'a;\nb')"));
    try check(equal((try iterator.next()).?, "UPDATE t SET value = 'changed' WHERE id = 1"));
    try check((try iterator.next()) == null);
    try check(connection.log_used == 0 and !connection.logged);

    const calls = probe.calls;
    const generation = store.generation;
    // Read-only statements never need workspace copies or WAL/fsync, even with
    // a poisoned write path. Neither malformed nor failed SQL reaches the hook.
    candidate = .{};
    try observer.execute("-- leading comment\n SELECT * FROM t", &out);
    try check(out.row_count == 2 and probe.calls == calls);
    if (candidate.execute("SELECT * FROM t", &out)) |_| return error.ReadCopiedDatabase else |err| try check(err == error.TableNotFound);
    if (connection.execute("INSERT INTO t VALUES (1, 'duplicate')", &out)) |_| return error.DuplicateAccepted else |err| try check(err == error.PrimaryKeyViolation);
    if (connection.execute("SELECT * FROM t; DELETE FROM t", &out)) |_| return error.BatchCommandAccepted else |_| {}
    try check(probe.calls == calls and store.generation == generation);
    try connection.beginTransaction();
    try connection.execute("DELETE FROM t", &out);
    connection.disconnect();
    try count(&observer, 2);
    try check(probe.calls == calls and connection.log_used == 0);

    // The hook observes an unpublished candidate. Its error leaves both the
    // public database and caller result untouched, and poisons further writes.
    out.affected_rows = 91;
    probe.fail_after = 0;
    probe.expected_generation = generation;
    if (connection.execute("DELETE FROM t", &out)) |_| return error.FailedWriteAcknowledged else |err| try check(err == error.InjectedStorageFailure);
    try check(store.storage_failed and store.generation == generation and out.affected_rows == 91);
    try count(&observer, 2);
    const failed_calls = probe.calls;
    if (connection.execute("DELETE FROM t", &out)) |_| return error.PoisonedWriteAcknowledged else |err| try check(err == error.StorageUnavailable);
    try check(probe.calls == failed_calls);
    try count(&observer, 2);
    // Recovery is the owner's responsibility; this test restores its fake sink.
    store.storage_failed = false;
    probe.fail_after = 1;
    try connection.beginTransaction();
    try connection.execute("INSERT INTO t VALUES (3, 'three')", &out);
    try connection.execute("DELETE FROM t WHERE id = 1", &out);
    probe.expected_generation = store.generation;
    if (connection.commitTransaction()) |_| return error.FailedTransactionAcknowledged else |err| try check(err == error.InjectedStorageFailure);
    try check(connection.transactionStatus() == 'E' and store.storage_failed and store.generation == generation);
    try count(&observer, 2);
    try probe.durable.execute("SELECT * FROM t", &out);
    try check(out.row_count == 2);
    try connection.rollbackTransaction();
    try check(connection.log_used == 0 and connection.transactionStatus() == 'I');

    store.storage_failed = false;
    probe.fail_after = null;
    connection.transaction_log = log[0..8];
    try connection.beginTransaction();
    if (connection.execute("DELETE FROM t", &out)) |_| return error.LogCapacityIgnored else |err| try check(err == error.TransactionLogCapacity);
    try check(connection.transactionStatus() == 'E' and connection.log_used == 0 and !connection.dirty);
    try connection.rollbackTransaction();
    try count(&observer, 2);
    connection.transaction_log = &log;
    try connection.beginTransaction();
    try count(&connection, 2);
    try connection.commitTransaction();
    try check(store.generation == generation);

    // Log conflicts never reach persistence or overwrite newer commits.
    try connection.beginTransaction();
    try connection.execute("DELETE FROM t", &out);
    probe.expected_generation = store.generation;
    try observer.execute("UPDATE t SET value = 'other' WHERE id = 1", &out);
    const after_other = probe.calls;
    if (connection.commitTransaction()) |_| return error.StaleDurableCommit else |err| try check(err == error.SerializationFailure);
    try check(probe.calls == after_other and !store.storage_failed);
    try connection.rollbackTransaction();
    try observer.execute("SELECT * FROM t WHERE id = 1", &out);
    try check(equal(out.rows[0].cells[1].text.slice(), "other"));
    store.autocommit_workspace = &store.database;
    if (observer.execute("DELETE FROM t", &out)) |_| return error.AliasedAutocommitAccepted else |err| try check(err == error.InvalidWorkspace);
    store.autocommit_workspace = &candidate;
    observer.transaction_workspace = &candidate;
    if (observer.execute("DELETE FROM t", &out)) |_| return error.AliasedAutocommitAccepted else |err| try check(err == error.InvalidWorkspace);
    observer.transaction_workspace = null;
    if (observer.execute("DELETE FROM t", &store.autocommit_result)) |_| return error.AliasedResultAccepted else |err| try check(err == error.InvalidWorkspace);
}

fn interleavings() !void {
    var store: Store = .{};
    var wa: DB = .{};
    var wb: DB = .{};
    var a = Store.Connection{ .store = &store, .id = 1, .transaction_workspace = &wa };
    var b = Store.Connection{ .store = &store, .id = 2, .transaction_workspace = &wb };
    var observer = Store.Connection{ .store = &store, .id = 3 };
    var out: DB.Result = .{};
    try observer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)", &out);
    try observer.execute("INSERT INTO t VALUES (1, 'b')", &out);
    for (0..256) |iteration| {
        const previous: []const u8 = if (iteration % 2 == 0) "b" else "a";
        const winner: []const u8 = if (iteration % 2 == 0) "a" else "b";
        try a.beginTransaction();
        try b.beginTransaction();
        try a.execute("UPDATE t SET value = 'a' WHERE id = 1", &out);
        try b.execute("UPDATE t SET value = 'b' WHERE id = 1", &out);
        try observer.execute("SELECT * FROM t", &out);
        try check(out.row_count == 1 and equal(out.rows[0].cells[1].text.slice(), previous));
        try a.execute("SELECT * FROM t", &out);
        try check(equal(out.rows[0].cells[1].text.slice(), "a"));
        try b.execute("SELECT * FROM t", &out);
        try check(equal(out.rows[0].cells[1].text.slice(), "b"));
        const first = if (iteration % 2 == 0) &a else &b;
        const second = if (iteration % 2 == 0) &b else &a;
        const generation = store.generation;
        try first.commitTransaction();
        if (second.commitTransaction()) |_| return error.InterleavedLostUpdate else |err| try check(err == error.SerializationFailure);
        try check(first.transactionStatus() == 'I' and second.transactionStatus() == 'E');
        try second.commitTransaction();
        try check(second.transactionStatus() == 'I');
        try observer.execute("SELECT * FROM t", &out);
        try check(out.row_count == 1 and equal(out.rows[0].cells[1].text.slice(), winner));
        try check(store.generation == generation + 1);
    }
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

// This adapter counts the actual snapshot API calls. It prevents a regression
// that silently reintroduces whole-database copies on durable point writes.
const TrackedDB = struct {
    pub const Result = DB.Result;
    database: DB = .{},
    pub var copies: usize = 0;

    pub fn copyFrom(self: *@This(), source: *const @This()) void {
        copies += 1;
        self.database.copyFrom(&source.database);
    }

    pub fn execute(self: *@This(), source: []const u8, result: *Result) !void {
        try self.database.execute(source, result);
    }

    pub fn executeWithCommit(self: *@This(), source: []const u8, result: *Result, context: ?*anyopaque, commit: *const fn (?*anyopaque) anyerror!void) anyerror!void {
        try self.database.executeWithCommit(source, result, context, commit);
    }
};

// Existing non-SQL adapters must retain the candidate path. This deliberately
// does not provide executeWithCommit.
const LegacyDB = struct {
    pub const Result = DB.Result;
    database: DB = .{},

    pub fn copyFrom(self: *@This(), source: *const @This()) void {
        self.database.copyFrom(&source.database);
    }

    pub fn execute(self: *@This(), source: []const u8, result: *Result) !void {
        try self.database.execute(source, result);
    }
};

const CountingSink = struct {
    calls: usize = 0,
    statements: usize = 0,
    fail: bool = false,

    fn commit(context: ?*anyopaque, batch: []const u8) anyerror!void {
        const self: *CountingSink = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.fail) return error.InjectedStorageFailure;
        var iterator = store_module.BatchIterator{ .bytes = batch };
        while (try iterator.next()) |_| self.statements += 1;
    }
};

fn mutationBoundaryStore() !void {
    const TrackedStore = store_module.Store(TrackedDB);
    var sink: CountingSink = .{};
    var store: TrackedStore = .{ .durability_required = true, .commit_ctx = &sink, .commit_fn = CountingSink.commit };
    var connection = TrackedStore.Connection{ .store = &store, .id = 1 };
    var result: DB.Result = .{};
    TrackedDB.copies = 0;
    try connection.execute("CREATE TABLE t (id INT PRIMARY KEY, value TEXT)", &result);
    try connection.execute("INSERT INTO t VALUES (1, 'one')", &result);
    try connection.execute("UPDATE t SET value = 'two' WHERE id = 1", &result);
    try connection.execute("SELECT * FROM t WHERE id = 1", &result);
    try check(result.row_count == 1 and equal(result.rows[0].cells[1].text.slice(), "two"));
    try check(TrackedDB.copies == 0 and store.autocommit_workspace == null);
    try check(sink.calls == 3 and sink.statements == 3 and store.generation == 3);
    if (connection.execute("INSERT INTO t VALUES (1, 'duplicate')", &result)) |_| return error.InvalidMutationPersisted else |err| try check(err == error.PrimaryKeyViolation);
    if (connection.execute("DELETE FROM t trailing", &result)) |_| return error.InvalidMutationPersisted else |err| try check(err == error.Syntax);
    try check(sink.calls == 3 and !store.storage_failed and TrackedDB.copies == 0);
    sink.fail = true;
    result.affected_rows = 91;
    if (connection.execute("DELETE FROM t", &result)) |_| return error.CommitFailureIgnored else |err| try check(err == error.InjectedStorageFailure);
    try check(store.storage_failed and store.generation == 3 and result.affected_rows == 91);
    try connection.execute("SELECT * FROM t WHERE id = 1", &result);
    try check(result.row_count == 1 and equal(result.rows[0].cells[1].text.slice(), "two"));
    try check(TrackedDB.copies == 0 and sink.calls == 4);

    store.storage_failed = false;
    sink.fail = false;
    var workspace: TrackedDB = .{};
    var log: [1024]u8 = undefined;
    connection.transaction_workspace = &workspace;
    connection.transaction_log = &log;
    try connection.beginTransaction();
    try check(TrackedDB.copies == 1);
    try connection.execute("INSERT INTO t VALUES (2, 'private')", &result);
    try connection.commitTransaction();
    try check(TrackedDB.copies == 2 and store.generation == 4 and sink.calls == 5);

    const LegacyStore = store_module.Store(LegacyDB);
    var legacy: LegacyStore = .{ .durability_required = true, .commit_ctx = &sink, .commit_fn = CountingSink.commit };
    var legacy_connection = LegacyStore.Connection{ .store = &legacy, .id = 1 };
    if (legacy_connection.execute("CREATE TABLE t (id INT)", &result)) |_| return error.MissingCandidateAccepted else |err| try check(err == error.TransactionCapacity);
    var candidate: LegacyDB = .{};
    legacy.autocommit_workspace = &candidate;
    try legacy_connection.execute("CREATE TABLE t (id INT)", &result);
    try legacy_connection.execute("INSERT INTO t VALUES (7)", &result);
    try legacy_connection.execute("SELECT * FROM t", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 7);
    sink.fail = true;
    if (legacy_connection.execute("DELETE FROM t", &result)) |_| return error.LegacyFailureIgnored else |err| try check(err == error.InjectedStorageFailure);
    try legacy_connection.execute("SELECT * FROM t", &result);
    try check(result.row_count == 1 and legacy.storage_failed and legacy.generation == 2);
}

pub fn main() !void {
    try transactions();
    try durability();
    try interleavings();
    try framing();
    try mutationBoundaryStore();
    try check(assertions >= 2000);
    std.debug.print("store: {d} assertions passed\n", .{assertions});
}
