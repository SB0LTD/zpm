//! Secondary indexes on caller-provided memory (external_storage, B11 wave
//! 3 index-storage lane). Index entry hashes are slices bound inside the
//! external region (Config.external_indexes runs per table, or any count
//! per table through Backing.index_slots), sized from each table's runtime
//! version budget, so an index never caps a table that has version room.
//! Checks: exact memory plans; CREATE [UNIQUE] INDEX with index probes equal
//! to scans; 23505 and atomicity; rollback and savepoint rollback with no
//! stale entry; version reclamation and a full version arena (53200, never
//! 54000); a unique-index race; ON CONFLICT through a unique index; DROP
//! INDEX; ALTER TABLE and TRUNCATE; copyFromInto; replay into a second
//! external database and recovery into a third with a different version
//! budget; and capacity edges (54000 per table slot, ChangeRecordConflict on
//! replay into too little index storage, invalid bindings). Expectations
//! are the PostgreSQL 18 behaviour already verified by the schema-objects
//! lane on inline storage; the memory numbers are ZPM's own.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

fn profile(comptime indexes: usize) sql.Config {
    return .{ .external_storage = true, .tables = 4, .columns = 4, .rows_per_table = 4, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .work_rows = 64, .result_rows = 64, .tx_writes = 128, .compact_integral_scans = true, .table_indexes = 3, .external_indexes = indexes };
}
/// Two bound index runs per table, three index definitions per table.
const DB = sql.Database(profile(2));
/// The same profile with no bound index storage.
const Bare = sql.Database(profile(0));
/// RAMSQL's server Config (ramsql src/server.sig) with every index bound.
const Ram = sql.Database(.{ .external_storage = true, .external_workspace = true, .external_results = true, .tables = 8, .columns = 8, .result_rows = 8192, .row_locks = 256, .predicates = 8, .expr_nodes = 8192, .relations = 4, .rows_per_table = 4096, .name_bytes = 63, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .versions_per_table = 8192, .tx_writes = 4096, .transactions = 62, .work_rows = 4096, .summary_groups = 64, .compact_integral_scans = true, .table_indexes = 4, .external_indexes = 4 });

const rows_budget = 32;
const versions_budget = 64;
const refs_count = 2048;

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var recovered: DB = .{};
var copy: DB = .{};
var unbindable: DB = .{};
var odd: DB = .{};
var odd_bare: Bare = .{};
var empty: DB = .{};
var recovery: DB.ReplayScratch = .{};
var bare: Bare = .{};
var scratch: DB.ReplayScratch = .{};
var bare_scratch: Bare.ReplayScratch = .{};
var record: [65536]u8 = undefined;
/// Every committed record of `db`, in commit order (the WAL).
var log_bytes: [262144]u8 = undefined;
var log_ends: [512]usize = undefined;
var log_count: usize = 0;
/// Log position of the first record that creates a secondary index.
var first_index_record: ?usize = null;

var primary_region: [1 << 20]u8 align(@alignOf(DB.StorageVersion)) = undefined;
var replica_region: [1 << 20]u8 align(@alignOf(DB.StorageVersion)) = undefined;
var recovered_region: [1 << 20]u8 align(@alignOf(DB.StorageVersion)) = undefined;
var copy_region: [1 << 20]u8 align(@alignOf(DB.StorageVersion)) = undefined;
var bare_region: [1 << 20]u8 align(@alignOf(Bare.StorageVersion)) = undefined;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("index-external contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.IndexExternalContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
fn render(comptime T: type, result: *const T.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [T.Io.format_bytes]u8 = undefined;
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
            const text = if (cell.* == .null_value) "NULL" else try T.Io.format(cell, false, T.Result.default_session, &cell_buffer);
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

fn query(target: anytype, source: []const u8) ![]const u8 {
    const T = @TypeOf(target.*);
    var result: T.Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(T, &result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

fn logRecord(payload: []const u8) !void {
    const start = if (log_count == 0) 0 else log_ends[log_count - 1];
    try check(start + payload.len <= log_bytes.len and log_count < log_ends.len);
    @memcpy(log_bytes[start..][0..payload.len], payload);
    log_ends[log_count] = start + payload.len;
    log_count += 1;
}

fn logged(position: usize) []const u8 {
    const start = if (position == 0) 0 else log_ends[position - 1];
    return log_bytes[start..log_ends[position]];
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica and appended to the log.
fn replicate(source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    var used: usize = 0;
    db.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (used != 0) {
        try replica.applyChangeRecord(record[0..used], &scratch);
        try logRecord(record[0..used]);
    }
    return result;
}

fn run(source: []const u8) !void {
    _ = try replicate(source);
}

/// Like run(), remembering the first record that defines an index.
fn runIndex(source: []const u8) !void {
    const position = log_count;
    try run(source);
    if (first_index_record == null and log_count > position) first_index_record = position;
}

fn clean(target: anytype) !void {
    const usage = target.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0 and usage.row_locks == 0);
}

/// The autocommit statement fails with `wanted`, writes no record, and the
/// probe answers `unchanged` afterwards on primary and replica.
fn rejects(source: []const u8, wanted: anyerror, probe: []const u8, unchanged: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    const oids = db.oid_counter;
    if (db.executeChanges(source, &result, &record, &used, null, null)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(used == 0 and db.oid_counter == oids);
    try same(try query(&db, probe), unchanged);
    try same(try query(&replica, probe), unchanged);
    try clean(&db);
}

fn statement(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
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

fn resumed(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{ .@"resume" = true });
}

fn resumeFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{ .@"resume" = true })) |_| {
        return error.InvalidStatementAccepted;
    } else |err| try check(err == wanted);
}

/// Encodes, replays, logs and publishes a transaction (Store.commit order).
fn commit(slot: u16) !void {
    if (!db.readOnly(slot)) {
        const payload = try db.prepareCommit(slot, &record);
        try replica.applyChangeRecord(payload, &scratch);
        try logRecord(payload);
    }
    db.publishCommit(slot);
}

/// Every probe answers identically on the primary and `other`.
fn sameAs(other: anytype, questions: []const []const u8) !void {
    for (questions) |probe| {
        const left = try query(&db, probe);
        var saved: [16384]u8 = undefined;
        @memcpy(saved[0..left.len], left);
        const right = try query(other, probe);
        if (!std.mem.eql(u8, saved[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  other   {s}\n", .{ probe, saved[0..left.len], right });
        try check(std.mem.eql(u8, saved[0..left.len], right));
    }
    try check(db.tableCount() == other.tableCount());
    try check(db.oid_counter == other.oid_counter);
}

fn probeCount(target: anytype, table: []const u8, index: []const u8, key: []const DB.Cell, probe: bool) !usize {
    return target.indexMatches(table, index, key, probe) orelse {
        std.debug.print("index {s} of {s} not found (assertion {d})\n", .{ index, table, assertions });
        return error.IndexNotFound;
    };
}

/// Index path = scan path for every key in `keys` and NULL, and every
/// secondary index of the table holds exactly its allocated versions.
fn indexAgrees(target: anytype, table: []const u8, index: []const u8, keys: []const i64) !void {
    for (keys) |value| {
        const key = [_]DB.Cell{.{ .integer = value }};
        try check(try probeCount(target, table, index, &key, true) == try probeCount(target, table, index, &key, false));
    }
    const nulls = [_]DB.Cell{.null_value};
    try check(try probeCount(target, table, index, &nulls, true) == try probeCount(target, table, index, &nulls, false));
    try check(target.indexConsistent(table).?);
}

fn hits(target: anytype, table: []const u8, index: []const u8, value: i64) !usize {
    const key = [_]DB.Cell{.{ .integer = value }};
    return probeCount(target, table, index, &key, true);
}

const g_keys = [_]i64{ 0, 1, 2, 3, 4, 5, 6 };
const v_keys = [_]i64{ 0, 10, 20, 30, 50, 90, 120, 150, 190, 200, 900, 901, 999 };

fn budgets(comptime T: type, rows: usize, versions: usize) [4]T.TableBudget {
    return @splat(.{ .rows = rows, .versions = versions });
}

fn bind(target: anytype, region: []u8, rows: usize, versions: usize) !void {
    const T = @TypeOf(target.*);
    const plan = budgets(T, rows, versions);
    const required = try T.backingBytesFor(plan, refs_count);
    try check(required <= region.len);
    try target.bindMemoryFor(region[0..required], plan, refs_count);
}

// ---- memory plans -----------------------------------------------------------

/// Index bytes per table per index at `versions` runtime versions: the
/// bound plan minus the plan without index storage, over tables x runs.
fn perIndex(rows: usize, versions: usize) !usize {
    const with = try DB.backingBytesFor(budgets(DB, rows, versions), refs_count);
    const without = try Bare.backingBytesFor(budgets(Bare, rows, versions), refs_count);
    try check(with > without and (with - without) % (4 * 2) == 0);
    return (with - without) / (4 * 2);
}

var report_1k: usize = 0;
var report_8k: usize = 0;
var report_1m: usize = 0;
var ram_version_bytes: usize = 0;
var ram_plan_bytes: usize = 0;

fn layout() !void {
    // pow2(2 x versions) u32 slots per index: the key-index size.
    try check(try perIndex(rows_budget, versions_budget) == 128 * 4);
    report_1k = try perIndex(512, 1024);
    try check(report_1k == 2048 * 4);
    report_8k = try perIndex(4096, 8192);
    try check(report_8k == 16384 * 4);
    report_1m = try perIndex(524288, 1048576);
    try check(report_1m == 2097152 * 4);
    try check(try perIndex(500000, 1000000) == 2097152 * 4);
    // Just above a power of two the hash doubles (load 25%..50%).
    try check(try perIndex(600, 1025) == 4096 * 4);
    ram_version_bytes = @sizeOf(Ram.StorageVersion);
    ram_plan_bytes = try Ram.backingBytesFor(@splat(.{ .rows = 4096, .versions = 8192 }), try Ram.queryReferenceCount(4096));
    // Binding: two runs of key_index.len slots per table; none when unbound.
    const probe = &unbindable;
    const required = try DB.backingBytesFor(budgets(DB, rows_budget, versions_budget), refs_count);
    if (probe.bindMemoryFor(copy_region[0 .. required - 1], budgets(DB, rows_budget, versions_budget), refs_count)) |_| return error.SmallRegionAccepted else |err| try check(err == error.WorkspaceCapacity);
    try check(probe.tables[0].index_slots.len == 0);
    // Odd row counts leave the compact scan bytes unaligned: both plans bind.
    try bind(&odd_bare, &mirror_region, 33, 67);
    try bind(&odd, &copy_region, 33, 67);
    try check(odd_bare.tables[3].index_slots.len == 0 and odd.tables[3].index_slots.len == 2 * 256);
    // Caller memory is not zeroed: nothing may read it before writing it.
    for ([_][]u8{ &primary_region, &replica_region, &copy_region, &recovered_region, &bare_region }) |region| @memset(region, 0xaa);
    try bind(&db, &primary_region, rows_budget, versions_budget);
    try bind(&replica, &replica_region, rows_budget, versions_budget);
    try bind(&copy, &copy_region, rows_budget, versions_budget);
    try bind(&recovered, &recovered_region, 48, 128);
    try bind(&bare, &bare_region, 48, 128);
    for (&db.tables, &recovered.tables, &bare.tables) |*table, *large, *unbound| {
        try check(table.key_index.len == 128 and table.index_slots.len == 2 * 128);
        try check(large.key_index.len == 256 and large.index_slots.len == 2 * 256);
        try check(unbound.index_slots.len == 0);
    }
    // Index slots sit inside the region, after their table's key index.
    const start = @intFromPtr(&primary_region);
    for (&db.tables) |*table| {
        const at = @intFromPtr(table.index_slots.ptr);
        try check(at >= start and at + table.index_slots.len * 4 <= start + required);
        try check(at >= @intFromPtr(table.key_index.ptr) + table.key_index.len * 4);
    }
}

// ---- secondary indexes on external storage ----------------------------------

const probes = [_][]const u8{
    "SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename, indexname",
    "SELECT c.relname, i.indisunique, i.indkey FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid ORDER BY c.relname",
    "SELECT id, g, v FROM t ORDER BY id",
};

fn secondary() !void {
    try run("CREATE TABLE t (id INT PRIMARY KEY, g INT, v INT)");
    // More rows than the inline profile (rows_per_table = 4) could hold.
    try run("INSERT INTO t VALUES (1, 1, 10), (2, 2, 20), (3, 3, 30), (4, 4, NULL), (5, 0, 50), (6, 1, NULL), (7, 2, 70), (8, 3, 80), (9, 4, 90), (10, 0, 100)");
    try run("INSERT INTO t VALUES (11, 1, 110), (12, 2, 120), (13, 3, 130), (14, 4, 140), (15, 0, 150), (16, 1, 160), (17, 2, 170), (18, 3, 180), (19, 4, 190), (20, 0, 200)");
    const created = try replicate("CREATE INDEX t_g ON t (g)");
    try check(created.command == .create_index and created.affected_rows == 0 and created.column_count == 0);
    if (first_index_record == null) first_index_record = log_count - 1;
    try expect("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 't' ORDER BY indexname", "t_g|CREATE INDEX t_g ON public.t USING btree (g);t_pkey|CREATE UNIQUE INDEX t_pkey ON public.t USING btree (id)");
    try indexAgrees(&db, "t", "t_g", &g_keys);
    try check(try hits(&db, "t", "t_g", 1) == 4 and try hits(&db, "t", "t_g", 0) == 4);
    // Existing duplicates: 23505, no index is created and no OID is used.
    try rejects("CREATE UNIQUE INDEX t_g_key ON t (g)", error.PrimaryKeyViolation, "SELECT indexname FROM pg_indexes WHERE tablename = 't' ORDER BY indexname", "t_g;t_pkey");
    try runIndex("CREATE UNIQUE INDEX t_v ON t (v)");
    try expect("SELECT i.indisprimary, i.indisunique, i.indkey FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = 't_v'", "f|t|3");
    try indexAgrees(&db, "t", "t_v", &v_keys);
    const nulls = [_]DB.Cell{.null_value};
    try check(try probeCount(&db, "t", "t_v", &nulls, true) == 2);
    // DML keeps index path = scan path.
    try run("INSERT INTO t VALUES (21, 5, NULL), (22, 6, 220)");
    try run("UPDATE t SET g = 6 WHERE id <= 2");
    try run("UPDATE t SET v = 999 WHERE id = 3");
    try run("DELETE FROM t WHERE id = 4");
    try indexAgrees(&db, "t", "t_g", &g_keys);
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try check(try hits(&db, "t", "t_g", 6) == 3 and try hits(&db, "t", "t_v", 30) == 0 and try hits(&db, "t", "t_v", 999) == 1);
    try sameAs(&replica, &probes);
    try indexAgrees(&replica, "t", "t_g", &g_keys);
    try indexAgrees(&replica, "t", "t_v", &v_keys);
}

/// CREATE TABLE LIKE INCLUDING INDEXES installs indexes on a slot of dirty
/// memory; its record replays the definition with its indexes.
fn likeIndexes() !void {
    try run("CREATE TABLE t2 (LIKE t INCLUDING INDEXES)");
    try expect("SELECT COUNT(*) FROM pg_indexes WHERE tablename = 't2'", "3");
    try run("INSERT INTO t2 VALUES (1, 1, 10), (2, 1, 20), (3, 2, NULL), (4, 2, NULL), (5, 3, 50)");
    try rejects("INSERT INTO t2 VALUES (6, 3, 50)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM t2", "5");
    try run("UPDATE t2 SET v = 30 WHERE id = 3");
    const listed = try query(&db, "SELECT indexname FROM pg_indexes WHERE tablename = 't2' AND indexname <> 't2_pkey' ORDER BY indexname");
    var names: [256]u8 = undefined;
    @memcpy(names[0..listed.len], listed);
    var parts = std.mem.splitScalar(u8, names[0..listed.len], ';');
    var count: usize = 0;
    while (parts.next()) |name| : (count += 1) {
        try indexAgrees(&db, "t2", name, &v_keys);
        try indexAgrees(&db, "t2", name, &g_keys);
        try indexAgrees(&replica, "t2", name, &v_keys);
    }
    try check(count == 2);
    try sameAs(&replica, &[_][]const u8{ probes[0], "SELECT id, g, v FROM t2 ORDER BY id" });
    try run("DROP TABLE t2");
    _ = db.vacuum();
}

fn uniqueViolations() !void {
    const names = "SELECT indexname FROM pg_indexes WHERE tablename = 't' ORDER BY indexname";
    const count = "SELECT COUNT(*), SUM(v) FROM t";
    const before = "21|3189";
    try expect(count, before);
    try rejects("INSERT INTO t VALUES (30, 0, 50)", error.PrimaryKeyViolation, count, before);
    try rejects("UPDATE t SET v = 50 WHERE id = 6", error.PrimaryKeyViolation, count, before);
    // The first row is inserted, the second conflicts: nothing stays.
    try rejects("INSERT INTO t VALUES (31, 0, 31), (32, 0, 999)", error.PrimaryKeyViolation, count, before);
    try rejects("UPDATE t SET v = 7 WHERE id IN (7, 8)", error.PrimaryKeyViolation, count, before);
    // Both bound runs are in use: 54000 before the duplicate check.
    try rejects("CREATE UNIQUE INDEX t_g_key ON t (g)", error.IndexCapacity, names, "t_g;t_pkey;t_v");
    try check(db.indexConsistent("t").? and replica.indexConsistent("t").?);
    try indexAgrees(&db, "t", "t_v", &v_keys);
    // NULLs stay distinct; an unchanged key is not a conflict.
    try run("INSERT INTO t VALUES (23, 0, NULL)");
    try run("UPDATE t SET v = v WHERE id = 5");
    try indexAgrees(&db, "t", "t_v", &v_keys);
}

fn rollbacks() !void {
    const stats = db.storageStats("t").?;
    const writer = try db.begin();
    try statement(writer, "INSERT INTO t VALUES (40, 4, 400), (41, 4, 410)");
    try statement(writer, "UPDATE t SET g = 4, v = 401 WHERE id = 5");
    try statement(writer, "DELETE FROM t WHERE id = 6");
    // Inside the transaction its own writes are indexed.
    try check(db.indexConsistent("t").? and db.storageStats("t").?.versions == stats.versions + 3);
    db.abort(writer);
    try check(db.storageStats("t").?.versions == stats.versions);
    try indexAgrees(&db, "t", "t_g", &g_keys);
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try check(try hits(&db, "t", "t_v", 400) == 0 and try hits(&db, "t", "t_v", 401) == 0 and try hits(&db, "t", "t_v", 50) == 1);
    try clean(&db);
    // ROLLBACK TO SAVEPOINT removes exactly the inner entries.
    const saver = try db.begin();
    try statement(saver, "INSERT INTO t VALUES (42, 5, 420)");
    try db.savepoint(saver, "s");
    try statement(saver, "INSERT INTO t VALUES (43, 5, 430)");
    try statement(saver, "UPDATE t SET v = 421 WHERE id = 42");
    _ = try db.rollbackTo(saver, "s");
    try check(db.indexConsistent("t").?);
    try statement(saver, "INSERT INTO t VALUES (44, 5, 440)");
    try commit(saver);
    try expect("SELECT id, v FROM t WHERE g = 5 ORDER BY id", "21|NULL;42|420;44|440");
    try check(try hits(&db, "t", "t_v", 430) == 0 and try hits(&db, "t", "t_v", 421) == 0);
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try sameAs(&replica, &probes);
    try clean(&db);
}

fn uniqueRace() !void {
    // The second inserter waits for the first, then fails after its commit
    // or inserts after its abort.
    const first = try db.begin();
    const second = try db.begin();
    try statement(first, "INSERT INTO t VALUES (50, 0, 900)");
    try parks(second, "INSERT INTO t VALUES (51, 0, 900)");
    try commit(first);
    try resumeFails(second, "INSERT INTO t VALUES (51, 0, 900)", error.PrimaryKeyViolation);
    db.abort(second);
    const third = try db.begin();
    const fourth = try db.begin();
    try statement(third, "INSERT INTO t VALUES (52, 0, 901)");
    try parks(fourth, "INSERT INTO t VALUES (53, 0, 901)");
    db.abort(third);
    try resumed(fourth, "INSERT INTO t VALUES (53, 0, 901)");
    try commit(fourth);
    try expect("SELECT id FROM t WHERE v >= 900 AND v < 999 ORDER BY id", "50;53");
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try clean(&db);
}

fn reclamation() !void {
    // Many more versions than the arena holds pass through the index; every
    // superseded version leaves both hashes when it is reclaimed.
    var text: [128]u8 = undefined;
    for (0..160) |step| {
        const id = 7 + step % 12;
        try run(try std.fmt.bufPrint(&text, "UPDATE t SET g = {d} WHERE id = {d}", .{ step % 5, id }));
        try check(db.indexConsistent("t").?);
    }
    _ = db.vacuum();
    try indexAgrees(&db, "t", "t_g", &g_keys);
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try sameAs(&replica, &probes);
    // One transaction can use every version slot: the indexes never cap it
    // first. The next version is 53200 (VersionCapacity), not 54000.
    const stats = db.storageStats("t").?;
    try check(stats.pending == 0 and stats.versions < versions_budget);
    const filler = try db.begin();
    var added: usize = 0;
    while (true) {
        var result: DB.Result = .{};
        db.statement(filler, "UPDATE t SET g = g WHERE id = 1", &result, .{}) catch |err| {
            try check(err == error.VersionCapacity);
            break;
        };
        added += 1;
        try check(added <= versions_budget);
    }
    try check(stats.versions + added == versions_budget);
    try check(db.storageStats("t").?.versions == versions_budget and db.indexConsistent("t").?);
    db.abort(filler);
    try check(db.storageStats("t").?.versions == stats.versions);
    try indexAgrees(&db, "t", "t_g", &g_keys);
    try clean(&db);
}

fn upsert() !void {
    // ON CONFLICT (v) infers the unique index as its arbiter.
    const updated = try replicate("INSERT INTO t VALUES (60, 3, 10) ON CONFLICT (v) DO UPDATE SET g = EXCLUDED.g RETURNING id, g, v");
    try check(updated.command == .insert and updated.affected_rows == 1);
    try same(try render(DB, &updated), "1|3|10");
    const skipped = try replicate("INSERT INTO t VALUES (61, 3, 20) ON CONFLICT (v) DO NOTHING");
    try check(skipped.affected_rows == 0);
    try run("INSERT INTO t VALUES (63, 3, 630) ON CONFLICT (v) DO NOTHING");
    try run("INSERT INTO t VALUES (64, 3, 630) ON CONFLICT (v) DO UPDATE SET v = t.v + 1");
    try expect("SELECT id, g, v FROM t WHERE id IN (1, 2, 60, 61, 63, 64) ORDER BY id", "1|3|10;2|6|20;63|3|631");
    try check(try hits(&db, "t", "t_v", 630) == 0 and try hits(&db, "t", "t_v", 631) == 1);
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try indexAgrees(&db, "t", "t_g", &g_keys);
    try sameAs(&replica, &probes);
}

fn dropAndAlter() !void {
    const names = "SELECT indexname FROM pg_indexes WHERE tablename = 't' ORDER BY indexname";
    try run("DROP INDEX t_g");
    try expect(names, "t_pkey;t_v");
    try check(db.indexMatches("t", "t_g", &[_]DB.Cell{.{ .integer = 1 }}, true) == null);
    // A composite index reuses the freed run.
    try runIndex("CREATE INDEX t_gv ON t (g, v)");
    try expect(names, "t_gv;t_pkey;t_v");
    for (0..7) |g| for ([_]i64{ 10, 20, 50, 160 }) |v| {
        const key = [_]DB.Cell{ .{ .integer = @intCast(g) }, .{ .integer = v } };
        try check(try probeCount(&db, "t", "t_gv", &key, true) == try probeCount(&db, "t", "t_gv", &key, false));
    };
    try check(try probeCount(&db, "t", "t_gv", &.{ .{ .integer = 3 }, .{ .integer = 10 } }, true) == 1);
    // Both runs are in use; the third definition has no storage: 54000.
    try rejects("CREATE INDEX t_third ON t (id)", error.IndexCapacity, names, "t_gv;t_pkey;t_v");
    // ALTER TABLE copies into another slot and rehashes there.
    try run("ALTER TABLE t ADD COLUMN w INT");
    try run("UPDATE t SET w = id WHERE id < 10");
    try expect(names, "t_gv;t_pkey;t_v");
    try indexAgrees(&db, "t", "t_v", &v_keys);
    try check(db.indexConsistent("t").?);
    try sameAs(&replica, &[_][]const u8{ probes[0], probes[1], "SELECT id, g, v, w FROM t ORDER BY id" });
    try indexAgrees(&replica, "t", "t_v", &v_keys);
    // A NULLS NOT DISTINCT unique index over duplicates: 23505.
    try run("CREATE TABLE u (id INT PRIMARY KEY, k INT)");
    try run("INSERT INTO u VALUES (1, 1), (2, 1), (3, 2)");
    try rejects("CREATE UNIQUE INDEX u_k ON u (k) NULLS NOT DISTINCT", error.PrimaryKeyViolation, "SELECT indexname FROM pg_indexes WHERE tablename = 'u'", "u_pkey");
}

fn truncation() !void {
    // TRUNCATE frees every version and its entries; NULLs then conflict.
    try run("TRUNCATE u");
    try runIndex("CREATE UNIQUE INDEX u_k ON u (k) NULLS NOT DISTINCT");
    try run("INSERT INTO u VALUES (1, 1), (2, NULL)");
    try rejects("INSERT INTO u VALUES (3, NULL)", error.PrimaryKeyViolation, "SELECT COUNT(*) FROM u", "2");
    try run("TRUNCATE u");
    _ = db.vacuum();
    try check(db.storageStats("u").?.versions == 0 and db.indexConsistent("u").?);
    try run("INSERT INTO u VALUES (4, 1)");
    try indexAgrees(&db, "u", "u_k", &.{ 0, 1, 2 });
    try sameAs(&replica, &[_][]const u8{ probes[0], "SELECT id, k FROM u ORDER BY id" });
}

// ---- replay -----------------------------------------------------------------

fn replay() !void {
    // Recovery: the whole log into a fresh external database whose tables
    // have twice the version budget (and so twice the index slots).
    for (0..log_count) |position| try recovered.applyChangeRecord(logged(position), &recovery);
    const state = [_][]const u8{ probes[0], probes[1], "SELECT id, g, v, w FROM t ORDER BY id", "SELECT id, k FROM u ORDER BY id" };
    try sameAs(&recovered, &state);
    try sameAs(&replica, &state);
    for ([_]*DB{ &replica, &recovered }) |target| {
        try indexAgrees(target, "t", "t_v", &v_keys);
        try indexAgrees(target, "u", "u_k", &.{ 0, 1, 2 });
        try check(try probeCount(target, "t", "t_gv", &.{ .{ .integer = 3 }, .{ .integer = 10 } }, true) == 1);
        try check(target.indexConsistent("t").?);
    }
    // The recovered copy keeps working: unique checks run through its index.
    var result: DB.Result = .{};
    try check(recovered.execute("INSERT INTO t (id, g, v) VALUES (70, 0, 10)", &result) == error.PrimaryKeyViolation);
    try recovered.execute("INSERT INTO t (id, g, v) VALUES (70, 0, 700)", &result);
    try check(try hits(&recovered, "t", "t_v", 700) == 1 and recovered.indexConsistent("t").?);
    // No index storage: the first index record is refused whole
    // (ChangeRecordConflict) and the replica keeps its prior state.
    const refused = first_index_record.?;
    for (0..refused) |position| try bare.applyChangeRecord(logged(position), &bare_scratch);
    const rows_before = try query(&bare, "SELECT COUNT(*) FROM t");
    try same(rows_before, "20");
    try check(bare.applyChangeRecord(logged(refused), &bare_scratch) == error.ChangeRecordConflict);
    try same(try query(&bare, "SELECT indexname FROM pg_indexes WHERE tablename = 't'"), "t_pkey");
    try same(try query(&bare, "SELECT COUNT(*) FROM t"), "20");
    try clean(&bare);
    // Without storage CREATE INDEX itself is 54000 and changes nothing.
    const oids = bare.oid_counter;
    var unbound_result: Bare.Result = .{};
    try check(bare.execute("CREATE INDEX b_g ON t (g)", &unbound_result) == error.IndexCapacity);
    try check(bare.oid_counter == oids);
    try same(try query(&bare, "SELECT COUNT(*) FROM pg_indexes WHERE tablename = 't'"), "1");
}

fn copies() !void {
    // copyFromInto rehashes every index for the destination's masks.
    try copy.copyFromInto(&db);
    try indexAgrees(&copy, "t", "t_v", &v_keys);
    try indexAgrees(&copy, "u", "u_k", &.{ 0, 1, 2 });
    try sameAs(&copy, &[_][]const u8{ probes[0], "SELECT id, g, v, w FROM t ORDER BY id" });
    var result: DB.Result = .{};
    try check(copy.execute("INSERT INTO t (id, g, v) VALUES (71, 0, 10)", &result) == error.PrimaryKeyViolation);
    try check(copy.indexConsistent("t").?);
}

// ---- per-slot bindings (bindStorage) ----------------------------------------

const Manual = struct {
    rows: [4][16]DB.StorageRowSlot = undefined,
    versions: [4][32]DB.StorageVersion = undefined,
    row_index: [4][32]u32 = undefined,
    key_index: [4][64]u32 = undefined,
    index_slots: [4][3 * 64]u32 = undefined,
    refs: [2048]u32 = undefined,
    scan_values: [4][16 * 4]i64 = undefined,
    scan_nonnull: [4][16]u64 = undefined,
    scan_live: [4][16]u8 = undefined,

    fn backings(self: *Manual, runs: [4]usize) [4]DB.StorageBacking {
        var out: [4]DB.StorageBacking = undefined;
        for (&out, 0..) |*backing, i| backing.* = .{
            .rows = &self.rows[i],
            .versions = &self.versions[i],
            .row_index = &self.row_index[i],
            .key_index = &self.key_index[i],
            .scan_values = &self.scan_values[i],
            .scan_nonnull = &self.scan_nonnull[i],
            .scan_live = &self.scan_live[i],
            .index_slots = self.index_slots[i][0 .. runs[i] * 64],
        };
        return out;
    }
};
var manual: Manual = undefined;
var unindexed: Manual = undefined;
var sliced: DB = .{};
var mirror: DB = .{};
var mirror_region: [1 << 20]u8 align(@alignOf(DB.StorageVersion)) = undefined;
var mirror_scratch: DB.ReplayScratch = .{};

fn slicedRun(source: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    sliced.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (used != 0) try mirror.applyChangeRecord(record[0..used], &mirror_scratch);
}

fn perSlot() !void {
    @memset(std.mem.asBytes(&manual), 0xaa);
    @memset(&mirror_region, 0xaa);
    // Invalid bindings change nothing.
    var bad = manual.backings(.{ 2, 0, 3, 1 });
    bad[0].index_slots = manual.index_slots[0][0..100];
    if (sliced.bindStorage(bad, &manual.refs)) |_| return error.PartialRunAccepted else |err| try check(err == error.InvalidParameterValue);
    bad = manual.backings(.{ 2, 0, 3, 1 });
    bad[1].index_slots = manual.index_slots[2][0..];
    if (sliced.bindStorage(bad, &manual.refs)) |_| return error.AliasingAccepted else |err| try check(err == error.InvalidParameterValue);
    bad = manual.backings(.{ 2, 0, 3, 1 });
    bad[3].index_slots = @as([*]u32, @ptrCast(@alignCast(&manual.versions[3])))[0..64];
    if (sliced.bindStorage(bad, &manual.refs)) |_| return error.AliasingAccepted else |err| try check(err == error.InvalidParameterValue);
    try check(sliced.tables[0].rows.len == 0 and sliced.tables[0].index_slots.len == 0);
    // Slots 0..3 carry 2, 0, 3 and 1 index runs.
    try sliced.bindStorage(manual.backings(.{ 2, 0, 3, 1 }), &manual.refs);
    try check(sliced.tables[2].index_slots.len == 3 * 64);
    try mirror.bindMemoryFor(&mirror_region, budgets(DB, 16, 32), refs_count);
    try slicedRun("CREATE TABLE a (id INT PRIMARY KEY, g INT, v INT, w INT)");
    try slicedRun("INSERT INTO a VALUES (1, 1, 1, 1), (2, 1, 2, 2), (3, 2, 3, 3)");
    // CREATE INDEX copies the table into the first free slot (1), which has
    // no index storage: 54000, nothing changed, no OID used.
    const oids = sliced.oid_counter;
    var result: DB.Result = .{};
    try check(sliced.execute("CREATE INDEX a_g ON a (g)", &result) == error.IndexCapacity);
    try check(sliced.oid_counter == oids);
    try same(try query(&sliced, "SELECT COUNT(*) FROM pg_indexes WHERE tablename = 'a'"), "1");
    try clean(&sliced);
    // With slot 1 taken, the copy lands in slot 2 (three runs).
    try slicedRun("CREATE TABLE f (id INT PRIMARY KEY)");
    try slicedRun("CREATE INDEX a_g ON a (g)");
    _ = sliced.vacuum();
    try check(sliced.tables[2].live and sliced.tables[2].index_count == 1 and !sliced.tables[0].live);
    try slicedRun("CREATE INDEX a_v ON a (v)");
    _ = sliced.vacuum();
    try check(sliced.tables[0].live and sliced.tables[0].index_count == 2);
    // The mirror's slot has two runs: the third index record is refused
    // whole (ChangeRecordConflict) and the mirror keeps two indexes.
    var used: usize = 0;
    try sliced.executeChanges("CREATE INDEX a_w ON a (w)", &result, &record, &used, null, null);
    try check(used != 0);
    try check(mirror.applyChangeRecord(record[0..used], &mirror_scratch) == error.ChangeRecordConflict);
    try clean(&mirror);
    _ = sliced.vacuum();
    try check(sliced.tables[2].live and sliced.tables[2].index_count == 3);
    for ([_][]const u8{ "a_g", "a_v", "a_w" }) |name| try indexAgrees(&sliced, "a", name, &.{ 0, 1, 2, 3 });
    try same(try query(&mirror, "SELECT indexname FROM pg_indexes WHERE tablename = 'a' ORDER BY indexname"), "a_g;a_pkey;a_v");
    try indexAgrees(&mirror, "a", "a_v", &.{ 0, 1, 2, 3 });
    // Every definition slot is in use: 54000.
    try check(sliced.execute("CREATE INDEX a_id ON a (id)", &result) == error.IndexCapacity);
    // copyFromInto into tables without index storage: refused before any change.
    try empty.bindStorage(unindexed.backings(.{ 0, 0, 0, 0 }), &unindexed.refs);
    if (empty.copyFromInto(&sliced)) |_| return error.SmallCopyAccepted else |err| try check(err == error.WorkspaceCapacity);
    try check(empty.tableCount() == 0);
}

pub fn main() !void {
    try layout();
    try secondary();
    try likeIndexes();
    try uniqueViolations();
    try rollbacks();
    try uniqueRace();
    try reclamation();
    try upsert();
    try dropAndAlter();
    try truncation();
    try replay();
    try copies();
    try perSlot();
    var buffer: [512]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-index-external\",\"pass\":true,\"assertions\":{d},\"log_records\":{d},\"index_bytes_per_table_per_index\":{{\"versions_1024\":{d},\"versions_8192\":{d},\"versions_1048576\":{d}}},\"ramsql_version_bytes\":{d},\"ramsql_plan_bytes_4_indexes\":{d}}}\n", .{ assertions, log_count, report_1k, report_8k, report_1m, ram_version_bytes, ram_plan_bytes });
    std.debug.print("{s}", .{report});
}
