//! Compact MVCC stamps, full-width versions and logical WAL compatibility.
const std = @import("std");
const sql = @import("sql");

fn config(compact: bool) sql.Config {
    return .{
        .external_storage = true,
        .split_external_versions = true,
        .integral_external_versions = true,
        .compact_external_version_stamps = compact,
        .tables = 1,
        .columns = 2,
        .rows_per_table = 8,
        .work_rows = 16,
        .result_rows = 16,
        .text_bytes = 32,
        .integer_bits = 32,
    };
}

const Compact = sql.Database(config(true));
const Standard = sql.Database(config(false));
const compact_banks: [1]Compact.TableBudget = .{.{ .rows = 8, .versions = 12, .integral_row_words = 2 }};
const standard_banks: [1]Standard.TableBudget = .{.{ .rows = 8, .versions = 12, .integral_row_words = 2 }};
const refs = 64;

var live: Compact = .{};
var replay: Standard = .{};
var live_memory: [8192]u8 align(64) = undefined;
var replay_memory: [8192]u8 align(64) = undefined;
var live_result: Compact.Result = .{};
var replay_result: Standard.Result = .{};
var replay_scratch: Standard.ReplayScratch = .{};
var changes: [8192]u8 = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("compact version stamp assertion {d} failed\n", .{assertions});
        return error.CompactVersionStampContract;
    }
}

fn change(statement: []const u8) !void {
    var used: usize = 0;
    try live.executeChanges(statement, &live_result, &changes, &used, null, null);
    try replay.applyChangeRecord(changes[0..used], &replay_scratch);
}

fn exactRows() !void {
    const source = "SELECT id,amount FROM ledger ORDER BY id";
    try live.execute(source, &live_result);
    try replay.execute(source, &replay_result);
    try check(live_result.row_count == replay_result.row_count);
    for (live_result.rows[0..live_result.row_count], replay_result.rows[0..replay_result.row_count]) |left, right| {
        try check(left.cells[0].integer == right.cells[0].integer);
        try check((left.cells[1] == .null_value and right.cells[1] == .null_value) or
            (left.cells[1] == .integer and right.cells[1] == .integer and left.cells[1].integer == right.cells[1].integer));
    }
}

fn fullWidthStamps() !void {
    var version: Compact.StorageVersion = .{};
    const max_csn = ~@as(u64, 0);
    const max_cid = ~@as(u32, 0);
    version.markDeletion(.{ .slot = 0xffff, .epoch = 0xffffffff, .sub = 0xffff }, max_cid);
    const pending = version.pendingDeletion() orelse return error.MissingPendingDeletion;
    try check(pending.tx.slot == 0xffff and pending.tx.epoch == 0xffffffff and pending.tx.sub == 0xffff and pending.cid == max_cid);
    try check(version.deletionCsn() == 0 and version.hasDeletion());
    version.publishCreation(max_csn);
    version.publishDeletion(max_csn);
    try check(version.creationCsn() == max_csn and version.deletionCsn() == max_csn);
    try check(version.pendingCreation() == null and version.pendingDeletion() == null);
    try check(version.rowLink() == 0);
    version.clearDeletion();
    try check(version.deletionCsn() == 0 and !version.hasDeletion());
    try check(version.creationCsn() == max_csn and version.rowLink() == 0);
}

fn oldSnapshotTruncate() !void {
    const reader = try live.begin();
    defer live.abort(reader);
    try live.statement(reader, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", &live_result, .{});
    try live.statement(reader, "SELECT 1", &live_result, .{});
    const version = live.tables[0].rows[0].newest - 1;
    try change("DELETE FROM ledger WHERE id = 1");
    try check(live.tables[0].versions[version].deletionCsn() == live.csn);
    const committed = live.tables[0].versions[version].deletionCsn();
    try live.statement(reader, "SELECT id FROM ledger WHERE id = 1", &live_result, .{});
    try check(live_result.row_count == 1 and live_result.rows[0].cells[0].integer == 1);
    try live.statement(reader, "TRUNCATE ledger", &live_result, .{});
    const retired = &live.tables[0].versions[version];
    try check(retired.rowLink() != 0 and retired.deletionCsn() == committed and retired.pendingDeletion() == null);
}

pub fn main() !void {
    try fullWidthStamps();
    try check(@sizeOf(Compact.StorageVersion) == 32 and @sizeOf(Standard.StorageVersion) == 48);
    const compact_size = try Compact.backingBytesFor(compact_banks, refs);
    const standard_size = try Standard.backingBytesFor(standard_banks, refs);
    try check(standard_size - compact_size == 16 * 12);
    @memset(&live_memory, 0xa5);
    @memset(&replay_memory, 0x5a);
    try live.bindMemoryFor(live_memory[0..compact_size], compact_banks, refs);
    try replay.bindMemoryFor(replay_memory[0..standard_size], standard_banks, refs);

    try change("CREATE TABLE ledger(id INT PRIMARY KEY, amount BIGINT)");
    try change("INSERT INTO ledger VALUES (1,10),(2,20),(4,NULL)");
    try change("UPDATE ledger SET amount=21 WHERE id=2");
    try change("UPDATE ledger SET id=3 WHERE id=2");
    try exactRows();
    try oldSnapshotTruncate();
    try exactRows();
    try change("TRUNCATE ledger");
    try exactRows();
    try check(live_result.row_count == 0);
    try change("INSERT INTO ledger VALUES (-1,-10),(3,NULL),(4,40),(5,50),(6,60),(7,70),(8,80),(9,90)");
    try exactRows();
    try check(live_result.row_count == 8);
    std.debug.print("PASS SQL compact version stamps: {d} assertions\n", .{assertions});
}
