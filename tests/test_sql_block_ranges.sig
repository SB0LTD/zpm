//! Conservative signed block ranges on caller-backed integral version banks.
const std = @import("std");
const sql = @import("sql");

fn config(comptime enabled: bool) sql.Config {
    return .{
        .external_storage = true,
        .split_external_versions = true,
        .integral_external_versions = true,
        .compact_integral_scans = true,
        .block_range_filters = enabled,
        .block_presence_filters = true,
        .tables = 1,
        .columns = 4,
        .work_rows = 128,
        .result_rows = 128,
        .rows_per_table = 4,
        .tx_writes = 512,
        .integer_bits = 32,
    };
}

const Fast = sql.Database(config(true));
const Slow = sql.Database(config(false));
const row_capacity = 400;
const refs_capacity = 4096;
const range_count = ((row_capacity + 63) / 64) * 4;
const q = "SELECT id,v FROM facts WHERE g=3 AND v>1700";
const scan_cases = [_][]const u8{
    "SELECT id,v FROM facts WHERE g=3 AND v<0",
    "SELECT id,v FROM facts WHERE g=3 AND v<=0",
    "SELECT id,v FROM facts WHERE g=3 AND v>0",
    "SELECT id,v FROM facts WHERE g=3 AND v>=0",
    q,
};

var fast: Fast = .{};
var slow: Slow = .{};
var twin: Fast = .{};
var fr: Fast.Result = .{};
var sr: Slow.Result = .{};
var tr: Fast.Result = .{};
var reader: Fast.ReadContext = .{};
var reader_refs: [refs_capacity]u32 = undefined;
var arenas: [3][1048576]u8 align(64) = undefined;
var wal: [65536]u8 = undefined;
var replay: Fast.ReplayScratch = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("block range assertion {d} failed\n", .{assertions});
        return error.BlockRangeContract;
    }
}

fn equal(left: *const Fast.Result, right: anytype) !void {
    try check(left.command == right.command and left.row_count == right.row_count and left.column_count == right.column_count);
    for (left.rows[0..left.row_count], right.rows[0..right.row_count]) |a, b| for (0..left.column_count) |column| {
        const x = a.cells[column];
        const y = b.cells[column];
        try check(std.meta.activeTag(x) == std.meta.activeTag(y));
        switch (x) {
            .null_value => {},
            .integer => |value| try check(value == y.integer),
            else => return error.UnexpectedValue,
        }
    };
}

fn execute(source: []const u8) !void {
    try fast.execute(source, &fr);
    try slow.execute(source, &sr);
    try equal(&fr, &sr);
}

fn rejectFlush(_: ?*anyopaque, _: []const u8) anyerror!void {
    return error.InjectedFlushFailure;
}

fn rangeContainsLiveRows() !void {
    const table = &fast.tables[0];
    const blocks = (table.rows.len + 63) / 64;
    for (0..table.scan_high) |slot| {
        if (table.scan_live[slot] == 0) continue;
        for (0..table.column_count) |column| {
            if ((table.scan_nonnull[slot] & (@as(u64, 1) << @intCast(column))) == 0) continue;
            const value = table.scan_values[column * table.rows.len + slot];
            const range = table.scan_ranges[column * blocks + slot / 64];
            try check(range.low <= value and value <= range.high);
        }
    }
}

pub fn main() !void {
    const fast_bank = [1]Fast.TableBudget{.{ .rows = row_capacity, .versions = 1024, .integral_row_words = 4 }};
    const slow_bank = [1]Slow.TableBudget{.{ .rows = row_capacity, .versions = 1024, .integral_row_words = 4 }};
    const twin_bank = [1]Fast.TableBudget{.{ .rows = 512, .versions = 1200, .integral_row_words = 4 }};
    @memset(std.mem.asBytes(&arenas), 0xa5);
    const fast_bytes = try Fast.backingBytesFor(fast_bank, refs_capacity);
    const slow_bytes = try Slow.backingBytesFor(slow_bank, refs_capacity);
    try check(fast_bytes - slow_bytes == range_count * @sizeOf(Fast.StorageBlockRange));
    try fast.bindMemoryFor(arenas[0][0..fast_bytes], fast_bank, refs_capacity);
    try slow.bindMemoryFor(&arenas[1], slow_bank, refs_capacity);
    try execute("CREATE TABLE facts(id INT PRIMARY KEY,g INT NOT NULL,v BIGINT NOT NULL,k BIGINT)");
    var query: [256]u8 = undefined;
    for (0..385) |id| {
        const value = (@as(i64, @intCast(id / 64)) - 3) * 1000;
        var text: [32]u8 = undefined;
        const nullable = if (id / 64 == 1 or id % 7 == 0) "NULL" else try std.fmt.bufPrint(&text, "{d}", .{value});
        try execute(try std.fmt.bufPrint(&query, "INSERT INTO facts VALUES({d},{d},{d},{s})", .{ id, id % 10, value, nullable }));
    }
    try rangeContainsLiveRows();
    const empty = fast.tables[0].scan_ranges[((row_capacity + 63) / 64) * 3 + 1];
    try check(empty.low > empty.high);
    for (scan_cases) |source| {
        var fast_control: sql.ExecutionControl = .{};
        var slow_control: sql.ExecutionControl = .{};
        fast.session.control = &fast_control;
        slow.session.control = &slow_control;
        try execute(source);
        fast.session.control = null;
        slow.session.control = null;
        try check(fast_control.used == slow_control.used);
        try check(fast.workspace.query.read_stats.projected_filter_scans == 1 and fast.workspace.query.read_stats.range_rejected_blocks > 0);
    }
    try execute("SELECT COUNT(*) FROM facts WHERE k<0");
    try check(fast.workspace.query.stream_stats.range_rejected_blocks > 0);

    const pinned = try fast.begin();
    const snapshot: Fast.Snapshot = .{ .csn = fast.csn };
    fast.txs[pinned].pin = snapshot;
    try fast.execute("UPDATE facts SET v=9223372036854775807 WHERE id=3", &fr);
    reader.workspace.query.refs = &reader_refs;
    try reader.execute(&fast, q, snapshot, &fr);
    try slow.execute(q, &sr);
    try equal(&fr, &sr);
    try check(reader.workspace.query.read_stats.projected_filter_scans == 0);
    fast.abort(pinned);
    try slow.execute("UPDATE facts SET v=9223372036854775807 WHERE id=3", &sr);
    try execute("UPDATE facts SET v=-9223372036854775808 WHERE id=13");
    try rangeContainsLiveRows();
    try execute("SELECT id,v FROM facts WHERE g=3 AND v<=-9223372036854775808");
    try check(fr.row_count == 1 and fr.rows[0].cells[0].integer == 13);
    try execute("SELECT id,v FROM facts WHERE g=3 AND v>=9223372036854775807");
    try check(fr.row_count == 1 and fr.rows[0].cells[0].integer == 3);

    const own = try fast.begin();
    try fast.statement(own, "UPDATE facts SET v=8321 WHERE id=23", &fr, .{});
    try fast.statement(own, "SELECT id FROM facts WHERE g=3 AND v>8000", &fr, .{});
    try check(fr.row_count == 2 and fast.workspace.query.read_stats.range_rejected_blocks == 0);
    fast.abort(own);
    const current = fast.tables[0].scan_ranges;
    var before: [range_count]Fast.StorageBlockRange = undefined;
    @memcpy(&before, current);
    var used: usize = 0;
    if (fast.executeChanges("UPDATE facts SET v=9999999 WHERE id=23", &fr, &wal, &used, null, rejectFlush)) |_| {
        return error.ExpectedFailure;
    } else |err| try check(err == error.InjectedFlushFailure and used == 0);
    for (current, before) |a, b| try check(std.meta.eql(a, b));

    try twin.bindMemoryFor(&arenas[2], twin_bank, refs_capacity);
    try twin.copyFromInto(&fast);
    const update = "UPDATE facts SET v=4200 WHERE id=23";
    try fast.executeChanges(update, &fr, &wal, &used, null, null);
    try slow.execute(update, &sr);
    try twin.applyChangeRecord(wal[0..used], &replay);
    try execute(q);
    try twin.execute(q, &tr);
    try equal(&fr, &tr);
    try check(twin.workspace.query.read_stats.range_rejected_blocks > 0);

    const alias: [*]u32 = @ptrCast(fast.tables[0].scan_ranges.ptr);
    reader.workspace.query.refs = alias[0 .. range_count * (@sizeOf(Fast.StorageBlockRange) / @sizeOf(u32))];
    if (reader.execute(&fast, q, .{ .csn = fast.csn }, &tr)) |_| return error.ExpectedAliasRejection else |err| {
        try check(err == error.InvalidParameterValue);
    }
    reader.workspace.query.refs = &reader_refs;

    try execute("DELETE FROM facts WHERE id>=250 OR id=3");
    try execute(q);
    try rangeContainsLiveRows();
    for (0..40) |offset| try execute(try std.fmt.bufPrint(&query, "INSERT INTO facts VALUES({d},3,4600,NULL)", .{500 + offset}));
    try check(fast.tables[0].row_high < 385);
    try rangeContainsLiveRows();
    try execute(q);
    try check(fast.workspace.query.read_stats.range_rejected_blocks > 0);
    std.debug.print("PASS SQL block ranges: {d} assertions\n", .{assertions});
}
