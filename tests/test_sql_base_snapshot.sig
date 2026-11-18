const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{
    .external_storage = true,
    .split_external_versions = true,
    .integral_external_versions = true,
    .compact_integral_scans = true,
    .tables = 3,
    .columns = 8,
    .text_bytes = 64,
    .rows_per_table = 4,
    .work_rows = 128,
    .result_rows = 16,
    .tx_writes = 32,
    .integer_bits = 32,
});
const budgets: [3]DB.TableBudget = .{
    .{ .rows = 8, .versions = 16, .integral_row_words = 6 },
    .{ .rows = 8, .versions = 16 },
    .{ .rows = 4, .versions = 8, .integral_row_words = 1 },
};
var backing: [2][131072]u8 align(64) = undefined;
var live: DB = .{};
var restored: DB = .{};
var result: DB.Result = .{};
var replay: DB.ReplayScratch = .{};
var assertions: usize = 0;

const Image = struct {
    bytes: [4096]u8 = undefined,
    used: usize = 0,

    pub fn appendAll(self: *Image, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.used) return error.ImageFixtureCapacity;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    pub fn length(self: *const Image) !u64 {
        return self.used;
    }

    pub fn readAt(self: *const Image, offset: u64, bytes: []u8) !usize {
        if (offset >= self.used) return 0;
        const start: usize = @intCast(offset);
        const count = @min(bytes.len, self.used - start, 17);
        @memcpy(bytes[0..count], self.bytes[start..][0..count]);
        return count;
    }
};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("base snapshot assertion {d}\n", .{assertions});
        return error.BaseSnapshotFailed;
    }
}

fn reset(db: *DB, i: usize) !void {
    db.* = .{};
    const refs = 4096;
    const bytes = try DB.backingBytesFor(budgets, refs);
    @memset(backing[i][0..bytes], 0xa5);
    try db.bindMemoryFor(backing[i][0..bytes], budgets, refs);
}

fn exercise(integral: bool) !void {
    try reset(&live, 0);
    try reset(&restored, 1);
    try live.execute("CREATE TABLE old (id INT)", &result);
    try live.execute("DROP TABLE old", &result);
    try live.execute(if (integral)
        "CREATE TABLE ledger (id INT PRIMARY KEY, amount BIGINT, detail DATE)"
    else
        "CREATE TABLE ledger (id INT PRIMARY KEY, amount BIGINT, detail TEXT)", &result);
    try live.execute(if (integral)
        "INSERT INTO ledger VALUES (1,10,DATE '2000-01-01'),(2,20,NULL),(3,30,NULL),(4,NULL,DATE 'infinity'),(5,-50,NULL),(6,60,NULL)"
    else
        "INSERT INTO ledger VALUES (1,10,'alpha'),(2,20,NULL),(3,30,NULL),(4,NULL,'delta'),(5,-50,NULL),(6,60,NULL)", &result);
    try live.execute("UPDATE ledger SET id=8 WHERE id=3", &result);
    try live.execute("DELETE FROM ledger WHERE id=6", &result);
    const bank: usize = if (integral) 0 else 1;
    const csn = live.csn;
    try check(live.tables[bank].live and live.tables[bank].next_rowid == 7);
    var scratch: [96]u8 = undefined;
    var image: Image = .{};
    const active = try live.begin();
    if (DB.BaseSnapshot.write(&live, &image, &scratch)) |_| return error.ActiveImageAccepted else |err| try check(err == error.SnapshotUnsupportedState);
    live.abort(active);
    try check(image.used == 0);
    try DB.BaseSnapshot.write(&live, &image, &scratch);
    try check(image.used > scratch.len);
    if (DB.BaseSnapshot.restore(&restored, &image, csn + 1, &scratch, &replay)) |_| return error.WrongCsnAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try check(restored.csn == 0 and restored.tableCount() == 0);
    var wrong_bank = image;
    wrong_bank.bytes[16] = @intCast((bank + 1) % budgets.len);
    if (DB.BaseSnapshot.restore(&restored, &wrong_bank, csn, &scratch, &replay)) |_| return error.WrongBankAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(restored.csn == 0 and restored.tableCount() == 0);
    var trailing = image;
    try trailing.appendAll("old");
    if (DB.BaseSnapshot.restore(&restored, &trailing, csn, &scratch, &replay)) |_| return error.TrailingImageAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try reset(&restored, 1);
    try DB.BaseSnapshot.restore(&restored, &image, csn, &scratch, &replay);
    try check(restored.csn == csn and restored.oid_counter == live.oid_counter);
    try check(restored.tables[bank].oid == live.tables[bank].oid and restored.tables[bank].next_rowid == 7);
    try check(restored.tables[bank].version_used == 5 and restored.tables[bank].summary.rows == 5);
    try restored.execute("SELECT id,amount,CAST(detail AS TEXT) FROM ledger ORDER BY id", &result);
    try check(result.row_count == 5 and result.rows[4].cells[0].integer == 8);
    try check(result.rows[4].cells[1].integer == 30 and result.rows[1].cells[2] == .null_value);
    try check(std.mem.eql(u8, result.rows[0].cells[2].text.slice(), if (integral) "2000-01-01" else "alpha"));

    var record: [2048]u8 = undefined;
    const slot = try live.begin();
    try live.statement(slot, "UPDATE ledger SET amount=amount+2 WHERE id=2", &result, .{});
    try live.statement(slot, "DELETE FROM ledger WHERE id=1", &result, .{});
    try live.statement(slot, "INSERT INTO ledger VALUES (9,90,NULL)", &result, .{});
    const changes = try live.prepareCommit(slot, &record);
    live.publishCommit(slot);
    try restored.applyChangeRecord(changes, &replay);
    try check(restored.csn == live.csn and restored.tables[bank].next_rowid == live.tables[bank].next_rowid);
    for ([_]*DB{ &live, &restored }) |db| {
        try db.execute("SELECT id,amount FROM ledger ORDER BY id", &result);
        try check(result.row_count == 5 and result.rows[0].cells[0].integer == 2 and result.rows[0].cells[1].integer == 22);
        try check(result.rows[4].cells[0].integer == 9 and result.rows[4].cells[1].integer == 90);
        try db.execute("SELECT COUNT(*),SUM(amount) FROM ledger", &result);
        try check(result.rows[0].cells[0].integer == 5);
    }

    var truncated = image;
    truncated.used -= 1;
    try reset(&restored, 1);
    if (DB.BaseSnapshot.restore(&restored, &truncated, csn, &scratch, &replay)) |_| return error.TruncatedImageAccepted else |err| try check(err == error.InvalidSnapshotImage);
}

pub fn main() !void {
    try exercise(true);
    try exercise(false);
    try live.execute("CREATE ROLE image_reader", &result);
    var image: Image = .{};
    var scratch: [96]u8 = undefined;
    if (DB.BaseSnapshot.write(&live, &image, &scratch)) |_| return error.CatalogImageAccepted else |err| try check(err == error.SnapshotUnsupportedState);
    try check(image.used == 0);
    std.debug.print("{{\"suite\":\"sql_base_snapshot\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
}
