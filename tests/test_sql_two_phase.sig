//! Store-owned prepared DML and logical replay with pending MVCC versions.
const std = @import("std");
const sql = @import("sql");
const Raw = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 32, .text_bytes = 32, .integer_bits = 32 });
const Store = @import("db_store").Store(Raw);
const Phase = Raw.PreparedWal;

const Journal = struct {
    const Record = struct { kind: u16, start: usize, end: usize };
    bytes: [65536]u8 = undefined,
    records: [64]Record = undefined,
    used: usize = 0,
    count: usize = 0,
    fail: bool = false,
    encode: [8192]u8 = undefined,

    fn attach(self: *Journal, store: *Store) void {
        store.commit_ctx = self;
        store.commit_fn = appendCommit;
        store.prepare_fn = appendPrepare;
        store.encode_buffer = &self.encode;
        store.prepared_limit = 3;
        store.wall_clock = now;
    }

    fn now() ?i64 {
        return 7123456;
    }

    fn appendCommit(context: ?*anyopaque, payload: []const u8) anyerror!void {
        const self: *Journal = @ptrCast(@alignCast(context.?));
        _ = try self.append(3, payload);
    }

    fn appendPrepare(context: ?*anyopaque, payload: []const u8) anyerror!u64 {
        const self: *Journal = @ptrCast(@alignCast(context.?));
        return self.append(Phase.wal_kind, payload);
    }

    fn append(self: *Journal, kind: u16, payload: []const u8) !u64 {
        if (self.fail) return error.InjectedFlushFailure;
        if (self.count == self.records.len or payload.len > self.bytes.len - self.used) return error.TestJournalFull;
        const end = self.used + payload.len;
        @memcpy(self.bytes[self.used..end], payload);
        self.records[self.count] = .{ .kind = kind, .start = self.used, .end = end };
        self.used = end;
        self.count += 1;
        return self.count;
    }

    fn recordBytes(self: *const Journal, index: usize) []const u8 {
        const record = self.records[index];
        return self.bytes[record.start..record.end];
    }

    fn restart(self: *Journal, store: *Store) !void {
        self.attach(store);
        var scratch: Raw.ReplayScratch = .{};
        for (self.records[0..self.count], 0..) |record, index| {
            const bytes = self.recordBytes(index);
            if (record.kind == 3) {
                try store.database.applyChangeRecord(bytes, &scratch);
                continue;
            }
            switch (try Phase.decode(bytes)) {
                .prepare => |prepared| _ = try store.rememberPrepared(prepared, index + 1),
                .decision => |decision| {
                    const entry = try store.recoveredDecisionIndex(decision);
                    if (decision.commit) {
                        const prepare = try Phase.decode(self.recordBytes(@intCast(decision.prepare_sequence - 1)));
                        try store.restorePreparedEntry(entry, prepare.prepare);
                    }
                    try store.resolveRecoveredPrepared(entry, decision.commit);
                },
            }
        }
        for (&store.prepared, 0..) |*entry, index| if (entry.used) {
            const record = try Phase.decode(self.recordBytes(@intCast(entry.sequence - 1)));
            try store.restorePreparedEntry(index, record.prepare);
        };
    }
};

var journal: Journal = .{};
var live: Store = .{};
var recovered: Store = .{};
var final: Store = .{};
var result: Raw.Result = .{};
var assertions: usize = 0;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) {
        std.debug.print("two-phase assertion {d} failed\n", .{assertions});
        return error.TwoPhaseContract;
    }
}

fn sqlCommand(session: *Store.Connection, source: []const u8) !void {
    session.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn reject(session: *Store.Connection, source: []const u8, expected: anyerror) !void {
    if (session.execute(source, &result)) |_| return error.ExpectedFailure else |err| {
        if (err != expected) std.debug.print("{s}: wanted {s}, got {s}\n", .{ source, @errorName(expected), @errorName(err) });
        try check(err == expected);
    }
}

fn amounts(session: *Store.Connection, expected: []const i64) !void {
    try sqlCommand(session, "SELECT amount FROM ledger ORDER BY id");
    try check(result.row_count == expected.len);
    for (result.rows[0..result.row_count], expected) |row, value| try check(row.cells[0].integer == value);
}

pub fn main() !void {
    journal.attach(&live);
    var admin: Store.Connection = .{ .store = &live, .id = 1 };
    var owner: Store.Connection = .{ .store = &live, .id = 2 };
    try sqlCommand(&admin, "CREATE TABLE ledger(id INT PRIMARY KEY, amount INT)");
    try sqlCommand(&admin, "INSERT INTO ledger VALUES(1,10),(2,20),(3,30),(5,50)");
    try sqlCommand(&admin, "CREATE ROLE tx_owner");
    try sqlCommand(&admin, "CREATE ROLE tx_guest");
    try sqlCommand(&admin, "GRANT SELECT, INSERT, UPDATE, DELETE ON ledger TO tx_owner");
    try sqlCommand(&owner, "SET ROLE tx_owner");
    try sqlCommand(&owner, "BEGIN");
    try sqlCommand(&owner, "SELECT id FROM ledger WHERE id=2 FOR SHARE");
    try sqlCommand(&owner, "UPDATE ledger SET amount=11 WHERE id=1");
    try sqlCommand(&owner, "UPDATE ledger SET amount=12 WHERE id=1");
    try sqlCommand(&owner, "DELETE FROM ledger WHERE id=3");
    try sqlCommand(&owner, "INSERT INTO ledger VALUES(4,40)");
    try sqlCommand(&owner, "PREPARE TRANSACTION 'Mixed''Case'");
    try check(result.command == .prepare_transaction and owner.transactionStatus() == 'I' and live.preparedCount() == 1);
    owner.disconnect();
    try amounts(&admin, &.{ 10, 20, 30, 50 });
    try reject(&admin, "SELECT id FROM ledger WHERE id=1 FOR UPDATE NOWAIT", error.LockNotAvailable);
    try sqlCommand(&admin, "UPDATE ledger SET amount=51 WHERE id=5");
    try sqlCommand(&admin, "BEGIN");
    try reject(&admin, "PREPARE TRANSACTION 'Mixed''Case'", error.DuplicateObject);
    try check(admin.transactionStatus() == 'I' and live.preparedCount() == 1);

    try journal.restart(&recovered);
    try check(recovered.preparedCount() == 1);
    var reader: Store.Connection = .{ .store = &recovered, .id = 1 };
    var resolver: Store.Connection = .{ .store = &recovered, .id = 2 };
    try amounts(&reader, &.{ 10, 20, 30, 51 });
    try reject(&reader, "SELECT id FROM ledger WHERE id=1 FOR UPDATE NOWAIT", error.LockNotAvailable);
    try reject(&reader, "SELECT id FROM ledger WHERE id=2 FOR UPDATE NOWAIT", error.LockNotAvailable);
    try reject(&reader, "COMMIT PREPARED 'mixed''case'", error.UndefinedObject);
    try sqlCommand(&resolver, "SET ROLE tx_guest");
    try reject(&resolver, "COMMIT PREPARED 'Mixed''Case'", error.InsufficientPrivilege);
    try sqlCommand(&resolver, "SET ROLE tx_owner");
    try sqlCommand(&resolver, "COMMIT PREPARED 'Mixed''Case'");
    try check(result.command == .commit_prepared and recovered.preparedCount() == 0);
    try amounts(&reader, &.{ 12, 20, 40, 51 });
    try sqlCommand(&reader, "SELECT id FROM ledger WHERE id=2 FOR UPDATE NOWAIT");

    var statement: [256]u8 = undefined;
    const gid: [199]u8 = @splat('x');
    try sqlCommand(&reader, "BEGIN");
    try sqlCommand(&reader, "INSERT INTO ledger VALUES(6,60)");
    try sqlCommand(&reader, try std.fmt.bufPrint(&statement, "PREPARE TRANSACTION '{s}'", .{&gid}));
    try sqlCommand(&reader, try std.fmt.bufPrint(&statement, "ROLLBACK PREPARED '{s}'", .{&gid}));
    try check(result.command == .rollback_prepared and recovered.preparedCount() == 0);
    try sqlCommand(&reader, "BEGIN");
    try reject(&reader, try std.fmt.bufPrint(&statement, "PREPARE TRANSACTION '{s}x'", .{&gid}), error.InvalidParameterValue);
    try check(reader.transactionStatus() == 'I');

    try journal.restart(&final);
    var resumed: Store.Connection = .{ .store = &final, .id = 1 };
    try check(final.preparedCount() == 0);
    try amounts(&resumed, &.{ 12, 20, 40, 51 });
    try sqlCommand(&resumed, "BEGIN");
    try sqlCommand(&resumed, "INSERT INTO ledger VALUES(7,70)");
    try sqlCommand(&resumed, "PREPARE TRANSACTION 'uncertain'");
    journal.fail = true;
    try reject(&resumed, "COMMIT PREPARED 'uncertain'", error.InjectedFlushFailure);
    try check(final.preparedCount() == 1 and final.storage_failed);
    try amounts(&resumed, &.{ 12, 20, 40, 51 });
    std.debug.print("PASS SQL two-phase: {d} assertions\n", .{assertions});
}
