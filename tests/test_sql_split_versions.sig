//! External metadata and dense payloads use distinct caller-owned spans.
const std = @import("std");
const sql = @import("sql");

fn config(comptime split: bool) sql.Config {
    return .{
        .external_storage = true,
        .external_workspace = true,
        .split_external_versions = split,
        .compact_integral_scans = true,
        .block_presence_filters = true,
        .external_indexes = 1,
        .tables = 2,
        .columns = 4,
        .text_bytes = 32,
        .rows_per_table = 4,
        .work_rows = 64,
        .result_rows = 16,
        .tx_writes = 32,
    };
}

const DB = sql.Database(config(true));
const InlinePayloadDB = sql.Database(config(false));
const budgets: [2]DB.TableBudget = .{ .{ .rows = 8, .versions = 16 }, .{ .rows = 16, .versions = 24 } };
const refs = 4096;
var storage: [3][131072]u8 align(64) = undefined;
var workspace: [3][512]DB.Cell = undefined;
var db: DB = .{};
var recovered: DB = .{};
var copied: DB = .{};
var rejected: DB = .{};
var read_context: DB.ReadContext = .{};
var result: DB.Result = .{};
var replay: DB.ReplayScratch = .{};
var record: [8192]u8 = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("split versions assertion {d}\n", .{assertions});
        return error.SplitVersionsFailed;
    }
}

fn bind(database: *DB, index: usize) !void {
    @memset(&storage[index], 0xa5);
    const required = try DB.backingBytesFor(budgets, refs);
    try database.bindMemoryFor(storage[index][0..required], budgets, refs);
    try database.bindWorkspace(&workspace[index]);
}

fn descriptors() [2]DB.StorageBacking {
    var banks: [2]DB.StorageBacking = undefined;
    for (&banks, &db.tables) |*bank, *table| bank.* = .{
        .rows = table.rows,
        .versions = table.versions,
        .version_rows = table.version_rows,
        .row_index = table.row_index,
        .key_index = table.key_index,
        .scan_values = table.scan_values,
        .scan_nonnull = table.scan_nonnull,
        .scan_live = table.scan_live,
        .scan_presence = table.scan_presence,
        .index_slots = table.index_slots,
    };
    return banks;
}

fn rejectAliases() !void {
    const memory = &storage[0];
    const required = try DB.backingBytesFor(budgets, refs);
    try check(@sizeOf(DB.StorageVersion) + @sizeOf(DB.StorageVersionRow) == @sizeOf(InlinePayloadDB.StorageVersion));
    if (rejected.bindMemoryFor(memory[0 .. required - 1], budgets, refs)) |_| return error.ShortBackingAccepted else |err| try check(err == error.WorkspaceCapacity);
    if (rejected.bindMemoryFor(memory[1 .. required + 1], budgets, refs)) |_| return error.UnalignedBackingAccepted else |err| try check(err == error.InvalidParameterValue);

    const original = descriptors();
    var invalid = original;
    invalid[0].version_rows = invalid[0].version_rows[0 .. budgets[0].versions - 1];
    if (rejected.bindStorage(invalid, db.workspace.query.refs)) |_| return error.ShortPayloadAccepted else |err| try check(err == error.InvalidParameterValue);
    invalid = original;
    invalid[0].version_rows = invalid[1].version_rows[0..budgets[0].versions];
    if (rejected.bindStorage(invalid, db.workspace.query.refs)) |_| return error.PayloadAliasAccepted else |err| try check(err == error.InvalidParameterValue);
    try check(rejected.tables[0].versions.len == 0 and rejected.tables[0].version_rows.len == 0);

    const cells: [*]DB.Cell = @ptrCast(original[0].version_rows.ptr);
    const alias = cells[0..16];
    if (db.bindWorkspace(alias)) |_| return error.WorkspaceAliasAccepted else |err| try check(err == error.InvalidParameterValue);
    try rejected.bindWorkspace(alias);
    if (rejected.bindStorage(original, db.workspace.query.refs)) |_| return error.StorageAliasAccepted else |err| try check(err == error.InvalidParameterValue);
    read_context.workspace.query.cells = alias;
    read_context.workspace.query.refs = db.workspace.query.refs;
    if (read_context.prepare(&db, "SELECT 1", .{ .csn = 0 })) |_| return error.ReadAliasAccepted else |err| try check(err == error.InvalidParameterValue);
}

fn change(statement: []const u8) !void {
    var used: usize = 0;
    try db.executeChanges(statement, &result, &record, &used, null, null);
    try check(used > 0);
    try recovered.applyChangeRecord(record[0..used], &replay);
}

fn values(database: *DB, query: []const u8, expected: []const i64) !void {
    try database.execute(query, &result);
    try check(result.row_count == expected.len and result.column_count == 1);
    for (result.rows[0..result.row_count], expected) |row, value| {
        try check(row.cells[0] == .integer and row.cells[0].integer == value);
    }
}

pub fn main() !void {
    try bind(&db, 0);
    try bind(&recovered, 1);
    try bind(&copied, 2);
    try rejectAliases();

    try change("CREATE TABLE t (id INT PRIMARY KEY, v INT, label TEXT)");
    try change("INSERT INTO t VALUES (1,10,'a'),(2,20,'b'),(3,30,'c'),(4,40,'d'),(5,50,'e'),(6,60,'f'),(7,70,'g'),(8,80,'h')");
    try change("UPDATE t SET v=33,label='updated' WHERE id=3");
    try change("DELETE FROM t WHERE id=2 OR id=6");
    try change("INSERT INTO t VALUES (9,90,'i'),(10,100,'j')");
    // The first bank was full. Inserting again reclaimed and compacted its
    // row slots, while the values stayed keyed by version index.
    try check(db.tables[0].row_high == 8 and db.tables[0].rows[1].rowid == 3);
    try values(&db, "SELECT v FROM t ORDER BY id", &.{ 10, 33, 40, 50, 70, 80, 90, 100 });
    try change("CREATE INDEX t_v ON t(v)");
    try values(&recovered, "SELECT id FROM t WHERE v=33 AND label='updated'", &.{3});

    try change("ALTER TABLE t ADD COLUMN added INT DEFAULT 17 NOT NULL");
    try values(&db, "SELECT added FROM t WHERE id=3", &.{17});
    try values(&recovered, "SELECT added FROM t WHERE id=3", &.{17});
    try change("UPDATE t SET added=42 WHERE id=10");
    try change("ALTER TABLE t DROP COLUMN label");
    try change("CREATE MATERIALIZED VIEW t_copy AS SELECT id,v FROM t WHERE id>=7");
    try change("UPDATE t SET v=101 WHERE id=10");
    try change("REFRESH MATERIALIZED VIEW t_copy");
    try copied.copyFromInto(&db);
    for ([_]*DB{ &db, &recovered, &copied }) |database| {
        try values(database, "SELECT v FROM t ORDER BY id", &.{ 10, 33, 40, 50, 70, 80, 90, 101 });
        try values(database, "SELECT added FROM t WHERE id=10", &.{42});
        try values(database, "SELECT id FROM t WHERE v=33", &.{3});
        try values(database, "SELECT v FROM t_copy WHERE id=10", &.{101});
    }
    std.debug.print("{{\"suite\":\"sql-split-versions\",\"pass\":true,\"assertions\":{d},\"header_bytes\":{d},\"payload_bytes\":{d}}}\n",
        .{ assertions, @sizeOf(DB.StorageVersion), @sizeOf(DB.StorageVersionRow) });
}
