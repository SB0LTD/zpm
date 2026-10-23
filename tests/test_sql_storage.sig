//! Versioned storage contracts: directory and arena exhaustion and reuse,
//! stale references, statement-failure undo and bounded reclamation.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const Small = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 4, .name_bytes = 16, .text_bytes = 16 });
const Tight = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 4, .versions_per_table = 5, .text_bytes = 16 });
const Wide = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 128, .text_bytes = 16 });
const Complex = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 4, .expr_nodes = 3, .expr_depth = 2, .predicates = 8 });
/// RAMSQL's default server profile (src/server.sig) for the memory report.
const ServerProfile = sql.Database(.{ .tables = 8, .columns = 8, .rows_per_table = 512, .name_bytes = 63, .text_bytes = 128, .boolean_integers = true, .nulls_first_ascending = false, .integer_bits = 32 });

var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.StorageContractFailed;
}

fn ids(db: anytype, result: anytype, expected: []const i64) !void {
    try db.execute("SELECT id FROM t", result);
    try check(result.row_count == expected.len);
    for (expected, 0..) |id, row| try check(result.rows[row].cells[0].integer == id);
}

fn directory() !void {
    var db: Small = .{};
    var result: Small.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, label TEXT)", &result);
    try check(result.command == .create_table);
    for ([_][]const u8{ "INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')", "INSERT INTO t VALUES (3, 'c')", "INSERT INTO t VALUES (4, 'd')" }) |source| try db.execute(source, &result);
    try check(result.command == .insert and result.affected_rows == 1);
    var stats = db.storageStats("t").?;
    try check(stats.live_rows == 4 and stats.row_slots == 4 and stats.versions == 4 and stats.pending == 0 and stats.next_rowid == 5);
    if (db.execute("INSERT INTO t VALUES (5, 'e')", &result)) |_| return error.RowCapacityIgnored else |err| try check(err == error.RowCapacity);
    stats = db.storageStats("t").?;
    // A rejected insert consumes neither a rowid nor a slot.
    try check(stats.row_slots == 4 and stats.versions == 4 and stats.pending == 0 and stats.next_rowid == 5);
    try db.execute("DELETE FROM t WHERE id <= 2", &result);
    try check(result.command == .delete and result.affected_rows == 2);
    stats = db.storageStats("t").?;
    // Opportunistic reclamation frees both versions and both row slots.
    try check(stats.live_rows == 2 and stats.row_slots == 2 and stats.versions == 2 and stats.row_high == 4);
    try db.execute("INSERT INTO t VALUES (5, 'e')", &result);
    try db.execute("INSERT INTO t VALUES (6, 'f')", &result);
    stats = db.storageStats("t").?;
    // Directory compaction keeps rowid (insertion) order for unordered scans.
    try check(stats.row_slots == 4 and stats.row_high == 4 and stats.next_rowid == 7);
    try ids(&db, &result, &.{ 3, 4, 5, 6 });
    for (0..64) |cycle| {
        try db.execute("DELETE FROM t", &result);
        try check(result.affected_rows == 4);
        for (0..4) |row| {
            var text: [64]u8 = undefined;
            try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO t VALUES ({d}, 'x')", .{cycle * 4 + row}), &result);
        }
        stats = db.storageStats("t").?;
        try check(stats.live_rows == 4 and stats.versions == 4 and stats.row_slots == 4);
    }
    try ids(&db, &result, &.{ 252, 253, 254, 255 });
    try db.execute("SELECT label FROM t WHERE id = 253", &result);
    try check(result.row_count == 1 and std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "x"));
}

fn arena() !void {
    var db: Tight = .{};
    var result: Tight.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, value INT)", &result);
    for (0..4) |row| {
        var text: [64]u8 = undefined;
        try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO t VALUES ({d}, 0)", .{row}), &result);
    }
    try check(Tight.versions_per_table == 5);
    // Four new versions cannot fit next to four live ones in five slots.
    if (db.execute("UPDATE t SET value = 9", &result)) |_| return error.VersionCapacityIgnored else |err| try check(err == error.VersionCapacity);
    var stats = db.storageStats("t").?;
    try check(stats.versions == 4 and stats.pending == 0 and stats.live_rows == 4);
    try db.execute("SELECT * FROM t WHERE value = 9", &result);
    try check(result.row_count == 0);
    // Single-row updates reuse arena slots indefinitely.
    for (0..200) |step| {
        var text: [64]u8 = undefined;
        try db.execute(try std.fmt.bufPrint(&text, "UPDATE t SET value = {d} WHERE id = {d}", .{ step, step % 4 }), &result);
        try check(result.affected_rows == 1 and result.command == .update);
        stats = db.storageStats("t").?;
        try check(stats.versions == 4 and stats.live_rows == 4);
    }
    try db.execute("SELECT value FROM t WHERE id = 3", &result);
    try check(result.rows[0].cells[0].integer == 199);
    // Primary-key changes keep the multi-entry index consistent.
    try db.execute("UPDATE t SET id = 10 WHERE id = 0", &result);
    try db.execute("SELECT value FROM t WHERE id = 10", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 196);
    try db.execute("SELECT value FROM t WHERE id = 0", &result);
    try check(result.row_count == 0);
    // The old key is free again once its row moved to key 10.
    try db.execute("DELETE FROM t WHERE id = 1", &result);
    try db.execute("INSERT INTO t VALUES (0, 7)", &result);
    if (db.execute("INSERT INTO t VALUES (11, 7)", &result)) |_| return error.RowCapacityIgnored else |err| try check(err == error.RowCapacity);
    // Updates keep row identity, so scans stay in rowid order.
    try ids(&db, &result, &.{ 10, 2, 3, 0 });
    stats = db.storageStats("t").?;
    try check(stats.versions == 4 and stats.next_rowid == 6);
}

fn twoFullUpdates() !void {
    var db: Wide = .{};
    var result: Wide.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, value INT)", &result);
    for (0..128) |row| {
        var text: [64]u8 = undefined;
        try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO t VALUES ({d}, 0)", .{row}), &result);
    }
    try check(Wide.versions_per_table == 256);
    try db.execute("UPDATE t SET value = 1", &result);
    try check(result.affected_rows == 128);
    var stats = db.storageStats("t").?;
    // At most 64 superseded versions are reclaimed opportunistically.
    try check(stats.versions == 128 + 64 and stats.pending == 0);
    // The second full-table UPDATE reclaims the rest on demand and fits.
    try db.execute("UPDATE t SET value = 2", &result);
    try check(result.affected_rows == 128);
    stats = db.storageStats("t").?;
    try check(stats.versions == 128 + 64 and stats.live_rows == 128);
    try db.execute("SELECT * FROM t WHERE value = 2", &result);
    try check(result.row_count == 128);
    try check(db.vacuum() == 64);
    stats = db.storageStats("t").?;
    try check(stats.versions == 128);
}

fn staleReferences() !void {
    var db: Small = .{};
    var result: Small.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, label TEXT)", &result);
    for ([_][]const u8{ "INSERT INTO t VALUES (1, 'a')", "INSERT INTO t VALUES (2, 'b')", "INSERT INTO t VALUES (3, 'c')", "INSERT INTO t VALUES (4, 'd')" }) |source| try db.execute(source, &result);
    const first = db.rowRef("t", 1).?;
    const third = db.rowRef("t", 3).?;
    try check(db.resolveRowRef("t", first).? == 1 and db.resolveRowRef("t", third).? == 3);
    // An update keeps the row's identity and slot.
    try db.execute("UPDATE t SET label = 'z' WHERE id = 3", &result);
    try check(db.resolveRowRef("t", third).? == 3);
    try db.execute("DELETE FROM t WHERE id = 1", &result);
    try check(db.resolveRowRef("t", first) == null and db.rowRef("t", 1) == null);
    // Compaction moves rowid 3 to a new slot generation: the old ref is stale.
    try db.execute("INSERT INTO t VALUES (5, 'e')", &result);
    try check(db.resolveRowRef("t", third) == null);
    const moved = db.rowRef("t", 3).?;
    try check(moved.slot != third.slot and db.resolveRowRef("t", moved).? == 3);
    // A forged generation never resolves.
    try check(db.resolveRowRef("t", .{ .slot = moved.slot, .generation = moved.generation +% 1 }) == null);
    try check(db.resolveRowRef("t", .{ .slot = 99, .generation = moved.generation }) == null);
    try db.execute("DROP TABLE t", &result);
    try check(db.resolveRowRef("t", moved) == null and db.storageStats("t") == null);
}

const Failing = struct {
    calls: usize = 0,
    db: *Small,
    seen_pending: usize = 0,
    seen_versions: usize = 0,

    fn commit(context: ?*anyopaque, record: []const u8) anyerror!void {
        const self: *Failing = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        try check(record.len >= sql.change_records.header_size);
        if (self.db.storageStats("t")) |stats| {
            self.seen_pending = stats.pending;
            self.seen_versions = stats.versions;
        }
        return error.InjectedCommitFailure;
    }
};

fn statementUndo() !void {
    var db: Small = .{};
    var result: Small.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, label TEXT)", &result);
    try db.execute("INSERT INTO t VALUES (1, 'a')", &result);
    try db.execute("INSERT INTO t VALUES (2, 'b')", &result);
    try db.execute("INSERT INTO t VALUES (3, 'c')", &result);
    const before = db.storageStats("t").?;
    var failing: Failing = .{ .db = &db };
    var record: [512]u8 = undefined;
    var used: usize = 0;
    result.affected_rows = 77;
    // UPDATE: three versions created and three xmax marks set, then undone.
    if (db.executeChanges("UPDATE t SET label = 'changed'", &result, &record, &used, &failing, Failing.commit)) |_| return error.FailureIgnored else |err| try check(err == error.InjectedCommitFailure);
    try check(failing.seen_pending == 6 and failing.seen_versions == 6);
    var after = db.storageStats("t").?;
    try check(after.versions == before.versions and after.pending == 0 and after.live_rows == 3 and used == 0 and result.affected_rows == 77);
    try db.execute("SELECT * FROM t WHERE label = 'changed'", &result);
    try check(result.row_count == 0);
    // DELETE: xmax marks only; all are cleared.
    if (db.executeChanges("DELETE FROM t", &result, &record, &used, &failing, Failing.commit)) |_| return error.FailureIgnored else |err| try check(err == error.InjectedCommitFailure);
    try check(failing.seen_pending == 3);
    after = db.storageStats("t").?;
    try check(after.pending == 0 and after.live_rows == 3 and after.row_slots == 3);
    // INSERT: version, row slot and rowid are all released.
    if (db.executeChanges("INSERT INTO t VALUES (4, 'd')", &result, &record, &used, &failing, Failing.commit)) |_| return error.FailureIgnored else |err| try check(err == error.InjectedCommitFailure);
    after = db.storageStats("t").?;
    try check(after.pending == 0 and after.live_rows == 3 and after.row_slots == 3 and after.next_rowid == before.next_rowid);
    try db.execute("INSERT INTO t VALUES (4, 'd')", &result);
    try check(db.rowRef("t", before.next_rowid) != null);
    // DDL: a failed CREATE is not visible and its OID is not consumed.
    if (db.executeChanges("CREATE TABLE u (id INT)", &result, &record, &used, &failing, Failing.commit)) |_| return error.FailureIgnored else |err| try check(err == error.InjectedCommitFailure);
    try check(db.tableCount() == 1 and db.storageStats("u") == null);
    // A record that does not fit fails the statement with no state change.
    var tiny: [12]u8 = undefined;
    if (db.executeChanges("UPDATE t SET label = 'big'", &result, &tiny, &used, null, null)) |_| return error.OverflowIgnored else |err| try check(err == error.TransactionLogCapacity);
    after = db.storageStats("t").?;
    try check(used == 0 and after.pending == 0 and after.live_rows == 4);
    try db.execute("SELECT * FROM t WHERE label = 'big'", &result);
    try check(result.row_count == 0);
    // Transaction-style appends grow one record across completed statements.
    try db.executeChanges("UPDATE t SET label = 'one' WHERE id = 1", &result, &record, &used, null, null);
    const first_length = used;
    try check(try Small.changeRecordOps(record[0..used]) == 1);
    if (db.executeChanges("INSERT INTO t VALUES (1, 'dup')", &result, &record, &used, null, null)) |_| return error.DuplicateAccepted else |err| try check(err == error.PrimaryKeyViolation);
    try check(used == first_length);
    try db.executeChanges("DELETE FROM t WHERE id = 2", &result, &record, &used, null, null);
    try check(try Small.changeRecordOps(record[0..used]) == 2 and used > first_length);
    try db.executeChanges("SELECT * FROM t", &result, &record, &used, null, null);
    try check(try Small.changeRecordOps(record[0..used]) == 2 and result.command == .select);
}

fn complexity() !void {
    var db: Complex = .{};
    var result: Complex.Result = .{};
    try db.execute("CREATE TABLE t (a INT, b INT)", &result);
    try db.execute("SELECT * FROM t WHERE a = 1 AND b = 2", &result);
    if (db.execute("SELECT * FROM t WHERE a = 1 AND b = 2 AND a = 3", &result)) |_| return error.ComplexityIgnored else |err| try check(err == error.StatementTooComplex);
    if (db.execute("DELETE FROM t WHERE a = 1 AND b = 2 AND a = 3", &result)) |_| return error.ComplexityIgnored else |err| try check(err == error.StatementTooComplex);
}

fn describe() !void {
    var db: Small = .{};
    var result: Small.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, label TEXT)", &result);
    try db.execute("INSERT INTO t VALUES (1, 'a')", &result);
    const before = db.storageStats("t").?;
    try db.describe("SELECT label, id FROM t WHERE id = 1", &result);
    try check(result.command == .select and result.column_count == 2 and result.row_count == 0);
    try check(std.mem.eql(u8, result.column_names[0].slice(), "label") and result.column_types[0] == .text and result.column_types[1] == .integer);
    try db.describe("DELETE FROM t", &result);
    try check(result.command == .delete and result.column_count == 0);
    try db.describe("INSERT INTO t VALUES (2, 'b')", &result);
    try check(result.command == .insert);
    try db.describe("BEGIN", &result);
    try check(result.command == .begin);
    const after = db.storageStats("t").?;
    try check(after.live_rows == before.live_rows and after.versions == before.versions and after.next_rowid == before.next_rowid);
    result.affected_rows = 5;
    if (db.describe("SELECT missing FROM t", &result)) |_| return error.DescribeAccepted else |err| try check(err == error.ColumnNotFound);
    try check(result.affected_rows == 5);
    if (db.execute("BEGIN", &result)) |_| return error.ControlExecuted else |err| try check(err == error.UnsupportedStatement);
}

fn legacy() !void {
    var db: Small = .{};
    var result: Small.Result = .{};
    try db.executeLegacy("CREATE TABLE t (id INT PRIMARY KEY, flag BOOLEAN)", &result);
    // Alpha replay coerces integer booleans even when the config does not.
    try db.executeLegacy("INSERT INTO t VALUES (1, 1)", &result);
    if (db.execute("INSERT INTO t VALUES (2, 1)", &result)) |_| return error.CoercionLeaked else |err| try check(err == error.TypeMismatch);
    try db.execute("SELECT flag FROM t WHERE id = 1", &result);
    try check(result.rows[0].cells[0] == .boolean and result.rows[0].cells[0].boolean);
    for ([_][]const u8{ "DELETE FROM t WHERE id = 1 OR id = 2", "SELECT COUNT(*) FROM t", "VACUUM", "UPDATE t SET id = 1 WHERE" }) |source| {
        if (db.executeLegacy(source, &result)) |_| return error.LegacyAccepted else |err| try check(err == error.UnsupportedLogVersion);
    }
    if (db.executeLegacy("INSERT INTO t VALUES (1, 0)", &result)) |_| return error.LegacyAccepted else |err| try check(err == error.PrimaryKeyViolation);
}

pub fn main(init: std.process.Init) !void {
    try directory();
    try arena();
    try twoFullUpdates();
    try staleReferences();
    try statementUndo();
    try complexity();
    try describe();
    try legacy();
    var buffer: [320]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-storage\",\"pass\":true,\"assertions\":{d},\"small_bytes\":{d},\"server_profile_bytes\":{d},\"server_versions_per_table\":{d}}}\n", .{ assertions, Small.storageBytes(), ServerProfile.storageBytes(), ServerProfile.versions_per_table });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
