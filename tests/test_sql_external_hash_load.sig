//! Deliberately colliding primary keys at 75% physical occupancy.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{
    .external_storage = true,
    .split_external_versions = true,
    .integral_external_versions = true,
    .compact_external_version_stamps = true,
    .tables = 1,
    .columns = 2,
    .rows_per_table = 5,
    .result_rows = 8,
    .work_rows = 16,
    .text_bytes = 16,
    .integer_bits = 32,
});
const refs = 96;
const ordinary: DB.TableBudget = .{
    .rows = 5, .versions = 6, .integral_row_words = 1, .omit_compact_scan = true, .secondary_hashes = 0,
};
var live: DB = .{};
var half_replay: DB = .{};
var packed_replay: DB = .{};
var memory: [3][4096]u8 align(64) = undefined;
var out: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};
var changes: [4096]u8 = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("external hash load assertion {d}\n", .{assertions});
        return error.ExternalHashLoadContract;
    }
}

fn bind(db: *DB, index: usize, load: sql.HashLoad) !void {
    var budget = ordinary;
    budget.hash_load = load;
    const bytes = try DB.backingBytesFor(.{budget}, refs);
    @memset(memory[index][0..bytes], 0xa5);
    try db.bindMemoryFor(memory[index][0..bytes], .{budget}, refs);
}

fn change(statement: []const u8) !void {
    var used: usize = 0;
    try live.executeChanges(statement, &out, &changes, &used, null, null);
    try half_replay.applyChangeRecord(changes[0..used], &scratch);
    try packed_replay.applyChangeRecord(changes[0..used], &scratch);
    try check(live.csn == half_replay.csn and live.csn == packed_replay.csn);
}

fn point(db: *DB, slot: ?u16, id: i64, value: ?i64) !void {
    var buffer: [64]u8 = undefined;
    const statement = try std.fmt.bufPrint(&buffer, "SELECT payload FROM t WHERE id={d}", .{id});
    if (slot) |tx| {
        try db.statement(tx, statement, &out, .{});
    } else {
        try db.execute(statement, &out);
    }
    if (value) |expected| {
        try check(out.row_count == 1 and out.rows[0].cells[0].integer == expected);
    } else {
        try check(out.row_count == 0);
    }
}

fn capacity() !void {
    try check(try sql.HashLoad.three_quarters.slotsFor(1) == 2);
    try check(try sql.HashLoad.three_quarters.slotsFor(2) == 4);
    try check(try sql.HashLoad.three_quarters.slotsFor(6) == 8);
    try check(try sql.HashLoad.three_quarters.slotsFor(7) == 16);
    try check(try sql.HashLoad.half.slotsFor(5) == 16);
    var budget = ordinary;
    budget.rows = 100_000_000;
    budget.versions = 100_065_536;
    const half = try DB.backingBytesFor(.{budget}, refs);
    budget.hash_load = .three_quarters;
    const higher = try DB.backingBytesFor(.{budget}, refs);
    try check(half == 7_750_105_088 + refs * 4);
    try check(higher == 6_676_363_264 + refs * 4);
    try check(half - higher == 1_073_741_824);

    var row: [5]DB.StorageRowSlot = undefined;
    var version: [6]DB.StorageVersion = undefined;
    var payload: [6]u64 = undefined;
    var row_hash: [8]u32 = undefined;
    var key_hash: [8]u32 = undefined;
    var backing: DB.StorageBacking = .{
        .rows = &row, .versions = &version,
        .integral_rows = &payload, .integral_row_words = 1,
        .row_index = &row_hash, .key_index = &key_hash, .omit_compact_scan = true,
    };
    try check(!backing.valid());
    backing.hash_load = .three_quarters;
    try check(backing.valid());
    backing.key_index = key_hash[0..4];
    try check(!backing.valid());
}

pub fn main() !void {
    try capacity();
    try bind(&live, 0, .three_quarters);
    try bind(&half_replay, 1, .half);
    try bind(&packed_replay, 2, .three_quarters);
    try check(live.tables[0].row_index.len == 8 and live.tables[0].key_index.len == 8);
    try check(half_replay.tables[0].row_index.len == 16 and half_replay.tables[0].key_index.len == 16);
    try change("CREATE TABLE t(id INTEGER PRIMARY KEY, payload SMALLINT NOT NULL)");
    // The integer key mixer puts all seven values in home slot 7 with an
    // eight-entry index. Wrapping through zero exercises backward-shift deletion.
    try change("INSERT INTO t VALUES (7,70),(15,150),(26,260),(42,420),(48,480)");
    for (0..5) |probe| try check(live.tables[0].key_index[(7 + probe) & 7] != 0);
    try check(live.tables[0].key_index[4] == 0 and live.tables[0].version_used == 5);
    for ([_]*DB{ &live, &half_replay, &packed_replay }) |db| {
        try point(db, null, 7, 70);
        try point(db, null, 48, 480);
        try point(db, null, 65, null);
    }

    const retained = try live.begin();
    try live.statement(retained, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", &out, .{});
    try point(&live, retained, 26, 260);
    try change("UPDATE t SET id=62,payload=620 WHERE id=26");
    try check(live.tables[0].version_used == 6 and live.tables[0].key_index[4] != 0);
    try point(&live, retained, 26, 260);
    try point(&live, retained, 62, null);
    try change("DELETE FROM t WHERE id=15");
    try point(&live, retained, 15, 150);
    for ([_]*DB{ &live, &half_replay, &packed_replay }) |db| {
        try point(db, null, 26, null);
        try point(db, null, 62, 620);
        try point(db, null, 15, null);
    }
    live.abort(retained);
    try change("INSERT INTO t VALUES (65,650)");
    for ([_]*DB{ &live, &half_replay, &packed_replay }) |db| {
        try point(db, null, 65, 650);
        try point(db, null, 48, 480);
        try point(db, null, 42, 420);
        try point(db, null, 15, null);
        try db.execute("SELECT id,payload FROM t ORDER BY id", &out);
        try check(out.row_count == 5 and out.rows[0].cells[0].integer == 7 and out.rows[4].cells[0].integer == 65);
    }
    std.debug.print("{{\"suite\":\"sql_external_hash_load\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
}
