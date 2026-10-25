//! Caller-owned storage must exceed the compiled inline profile without aliasing.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .external_storage = true, .tables = 1, .columns = 3,
    .rows_per_table = 4, .text_bytes = 32, .work_rows = 64, .result_rows = 32, .tx_writes = 64 });
const count = 100000;
var rows: [count]DB.StorageRowSlot = undefined;
var versions: [count * 2]DB.StorageVersion = undefined;
var row_index: [262144]u32 = undefined;
var key_index: [524288]u32 = undefined;
var refs: [count * 4]u32 = undefined;
var small_rows: [16]DB.StorageRowSlot = undefined;
var small_versions: [32]DB.StorageVersion = undefined;
var small_row_index: [32]u32 = undefined;
var small_key_index: [64]u32 = undefined;
var small_refs: [256]u32 = undefined;
var assertions: usize = 0;
fn check(ok: bool) !void { assertions += 1; if (!ok) return error.ExternalStorageFailed; }
fn backing() DB.StorageBacking {
    return .{ .rows = &rows, .versions = &versions, .row_index = &row_index, .key_index = &key_index };
}
pub fn main() !void {
    var bytes: [65536]u8 align(@alignOf(DB.StorageVersion)) = undefined;
    var checked: DB = .{};
    const required = try DB.backingBytes(16,32,256);
    if (checked.bindMemory(bytes[0..required-1],16,32,256)) |_| return error.SmallRegionAccepted else |err| try check(err == error.WorkspaceCapacity);
    if (checked.bindMemory(bytes[1..],16,32,256)) |_| return error.UnalignedRegionAccepted else |err| try check(err == error.InvalidParameterValue);
    try checked.bindMemory(bytes[0..required],16,32,256);
    try check(checked.tables[0].rows.len == 16);
    if (DB.backingBytes(~@as(usize,0),32,256)) |_| return error.LayoutOverflowAccepted else |err| try check(err == error.InvalidParameterValue);
    var db: DB = .{};
    var result: DB.Result = .{};
    if (db.execute("SELECT 1", &result)) |_| return error.UnboundStorageAccepted else |err| try check(err == error.InvalidParameterValue);
    var invalid = backing();
    invalid.row_index = key_index[0..262144];
    if (db.bindStorage(.{invalid}, &refs)) |_| return error.AliasingAccepted else |err| try check(err == error.InvalidParameterValue);
    try check(db.tables[0].rows.len == 0 and db.workspace.query.refs.len == 0);
    try db.bindStorage(.{backing()}, &refs);
    try db.execute("CREATE TABLE large (id INT PRIMARY KEY, value INT, label TEXT)", &result);
    var text: [128]u8 = undefined;
    for (0..count) |i| {
        const source = try std.fmt.bufPrint(&text, "INSERT INTO large VALUES ({d}, {d}, 'stored')", .{i, count - i});
        try db.execute(source, &result);
    }
    try db.execute("SELECT COUNT(*) FROM large", &result);
    try check(result.rows[0].cells[0].integer == count);
    try db.execute("SELECT value FROM large WHERE id = 99999", &result);
    try check(result.rows[0].cells[0].integer == 1);
    try db.execute("UPDATE large SET value = 17 WHERE id = 65536", &result);
    try db.execute("SELECT value FROM large WHERE id = 65536", &result);
    try check(result.rows[0].cells[0].integer == 17);
    try db.execute("SELECT id FROM large ORDER BY value LIMIT 10", &result);
    try check(result.row_count == 10 and result.rows[0].cells[0].integer == 99999);
    try db.execute("SELECT id FROM large ORDER BY value LIMIT 17", &result);
    try check(result.row_count == 17 and result.rows[16].cells[0].integer == 65536);
    try check(@sizeOf(DB) < 2000000);
    const before = result;
    if (db.execute("INSERT INTO large VALUES (100000, 0, 'full')", &result)) |_| return error.FullStorageAccepted else |err| try check(err == error.RowCapacity);
    try check(result.row_count == before.row_count and result.rows[0].cells[0].integer == before.rows[0].cells[0].integer);
    if (db.bindStorage(.{backing()}, &refs)) |_| return error.LiveRebindAccepted else |err| try check(err == error.InvalidParameterValue);
    var small: DB = .{};
    try small.bindStorage(.{.{ .rows = &small_rows, .versions = &small_versions,
        .row_index = &small_row_index, .key_index = &small_key_index }}, &small_refs);
    if (small.copyFromInto(&db)) |_| return error.SmallCopyAccepted else |err| try check(err == error.WorkspaceCapacity);
    try check(small.tableCount() == 0);
    try db.execute("DELETE FROM large WHERE id = 99999", &result);
    try db.execute("SELECT id FROM large WHERE id = 99999", &result);
    try check(result.row_count == 0);
    try small.execute("CREATE TABLE copied (id INT PRIMARY KEY, value INT, label TEXT)", &result);
    try small.execute("INSERT INTO copied VALUES (1, 10, 'one'), (2, 20, 'two')", &result);
    try db.copyFromInto(&small);
    try db.execute("SELECT value FROM copied WHERE id = 2", &result);
    try check(result.rows[0].cells[0].integer == 20 and db.workspace.query.refs.len == refs.len);
    var record: [8192]u8 = undefined;
    var used: usize = 0;
    try small.executeChanges("INSERT INTO copied VALUES (3, 30, 'x'), (4, 40, 'x'), (5, 50, 'x'), (6, 60, 'x'), (7, 70, 'x'), (8, 80, 'x'), (9, 90, 'x'), (10, 100, 'x'), (11, 110, 'x'), (12, 120, 'x'), (13, 130, 'x'), (14, 140, 'x')", &result, &record, &used, null, null);
    var replay: DB.ReplayScratch = .{};
    try db.applyChangeRecord(record[0..used], &replay);
    try db.execute("SELECT COUNT(*) FROM copied", &result);
    try check(result.rows[0].cells[0].integer == 14);
    std.debug.print("external-storage: {d} rows, {d} assertions, database metadata {d} bytes\n", .{ count, assertions, @sizeOf(DB) });
}
