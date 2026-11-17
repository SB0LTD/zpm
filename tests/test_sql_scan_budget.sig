//! Per-table omission of the optional committed projection on typed banks.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{
    .external_storage = true,
    .split_external_versions = true,
    .integral_external_versions = true,
    .compact_integral_scans = true,
    .block_presence_filters = true,
    .factorized_aggregates = true,
    .dimension_group_ids = true,
    .dimension_distinct_groups = true,
    .typed_grouped_aggregates = true,
    .summary_groups = 8,
    .tables = 3,
    .columns = 8,
    .rows_per_table = 4,
    .work_rows = 32,
    .result_rows = 16,
    .tx_writes = 128,
    .text_bytes = 64,
    .integer_bits = 32,
});

const normal: [3]DB.TableBudget = .{
    .{ .rows = 128, .versions = 256, .integral_row_words = 6 },
    .{ .rows = 16, .versions = 32 },
    .{ .rows = 8, .versions = 16 },
};
const reduced = blk: {
    var banks = normal;
    banks[0].omit_compact_scan = true;
    break :blk banks;
};
const refs = 4096;
var memory: [4][262144]u8 align(64) = undefined;
var lean: DB = .{};
var backed: DB = .{};
var dense: DB = .{};
var dense_replay: DB = .{};
var left: DB.Result = .{};
var right: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};
var record: [8192]u8 = undefined;
var assertions: usize = 0;
var records: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("scan budget assertion {d}\n", .{assertions});
        return error.ScanBudgetContractFailed;
    }
}

fn execute(database: *DB, source: []const u8, result: *DB.Result) !void {
    database.execute(source, result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn change(source: []const u8) !void {
    return transfer(&lean, &backed, source);
}

fn transfer(primary: *DB, replica: *DB, source: []const u8) !void {
    var used: usize = 0;
    primary.executeChanges(source, &left, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try check(used != 0);
    try replica.applyChangeRecord(record[0..used], &scratch);
    records += 1;
}

fn relayout() !void {
    var banks: [3]DB.TableBudget = @splat(.{ .rows = 16, .versions = 32 });
    banks[0].omit_compact_scan = true;
    const needed = try DB.backingBytesFor(banks, refs);
    @memset(&memory[2], 0xa5);
    @memset(&memory[3], 0xa5);
    try dense.bindMemoryFor(memory[2][0..needed], banks, refs);
    try dense_replay.bindMemoryFor(memory[3][0..needed], banks, refs);
    try transfer(&dense, &dense_replay, "CREATE TABLE t (id INT PRIMARY KEY, v INT)");
    try transfer(&dense, &dense_replay, "INSERT INTO t VALUES (1,17),(2,20)");
    try transfer(&dense, &dense_replay, "ALTER TABLE t ADD COLUMN extra INT DEFAULT 3");
    // Live ALTER publishes a copied slot. Replay updates the original slot
    // while rebuilding summaries under its own projection budget.
    try check(dense.tables[1].live and dense.tables[1].scan_high == 2);
    try check(dense_replay.tables[0].live and dense_replay.tables[0].scan_high == 0);
    for ([_]*DB{ &dense, &dense_replay }) |database| {
        try execute(database, "SELECT SUM(extra),SUM(v) FROM t WHERE id>=1", &left);
        try check(left.rows[0].cells[0].integer == 6 and left.rows[0].cells[1].integer == 37);
    }
}

fn same(source: []const u8) !void {
    try execute(&lean, source, &left);
    try execute(&backed, source, &right);
    try check(left.row_count == right.row_count and left.column_count == right.column_count);
    for (left.rows[0..left.row_count], right.rows[0..right.row_count]) |a, b| {
        for (a.cells[0..left.column_count], b.cells[0..right.column_count]) |x, y| {
            try check(std.meta.activeTag(x) == std.meta.activeTag(y));
            try check(switch (x) {
                .null_value => true,
                .integer => x.integer == y.integer,
                .text => std.mem.eql(u8, x.text.slice(), y.text.slice()),
                .numeric => std.meta.eql(x.numeric, y.numeric),
                else => return error.UnexpectedCell,
            });
        }
    }
}

fn scanBudget() !void {
    const full_bytes = try DB.backingBytesFor(normal, refs);
    const lean_bytes = try DB.backingBytesFor(reduced, refs);
    try check(full_bytes - lean_bytes == 128 * (8 * 8 + 8 + 1) + 2 * 8 * 4 * 8);
    if (comptime @bitSizeOf(usize) >= 64) {
        var large = normal;
        large[0].rows = 100000000;
        large[0].versions = 100065536;
        const with_scan = try DB.backingBytesFor(large, refs);
        large[0].omit_compact_scan = true;
        const without_scan = try DB.backingBytesFor(large, refs);
        try check(with_scan - without_scan == 7700000000);
    }
    @memset(&memory[0], 0xa5);
    @memset(&memory[1], 0xa5);
    try lean.bindMemoryFor(memory[0][0..lean_bytes], reduced, refs);
    try backed.bindMemoryFor(memory[1][0..full_bytes], normal, refs);
    const fact = &lean.tables[0];
    try check(fact.scan_values.len == 0 and fact.scan_nonnull.len == 0 and fact.scan_live.len == 0 and fact.scan_presence.len == 0);
    try check(lean.tables[1].scan_values.len == 16 * 8 and lean.tables[1].scan_presence.len == 8 * 4);
    var manual: DB.StorageBacking = .{
        .rows = fact.rows, .versions = fact.versions, .version_rows = fact.version_rows,
        .integral_rows = fact.integral_rows, .integral_row_words = fact.integral_row_words,
        .row_index = fact.row_index, .key_index = fact.key_index,
    };
    try check(!manual.valid());
    manual.omit_compact_scan = true;
    try check(manual.valid());
    manual.scan_live = lean.tables[1].scan_live;
    try check(!manual.valid());
}

const filtered = "SELECT g,COUNT(*),SUM(v) FROM facts WHERE id>=0 GROUP BY g ORDER BY g";
const joined = "SELECT d.label,COUNT(*),SUM(f.v) FROM facts f JOIN dims d ON d.id=f.g WHERE f.g>=1 GROUP BY d.label ORDER BY d.label";

fn queries() !void {
    try same("SELECT COUNT(*) FROM dims WHERE id>=1");
    try check(lean.workspace.query.stream_stats.compact_plans == 1);
    try same("SELECT id FROM facts WHERE id>=125");
    try check(lean.workspace.query.read_stats.projected_filter_scans == 0);
    try check(backed.workspace.query.read_stats.projected_filter_scans == 1);
    try same("SELECT COUNT(*),SUM(v) FROM facts");
    try check(lean.workspace.query.stream_stats.summary_plans == 1);
    try same(filtered);
    try check(lean.workspace.query.stream_stats.compact_plans == 0 and backed.workspace.query.stream_stats.compact_plans == 1);
    try same(joined);
    try check(lean.workspace.query.stream_stats.factor_plans == 0 and backed.workspace.query.stream_stats.factor_plans == 1);
    try same("SELECT d.label,COUNT(*),SUM(f.v) FROM facts f JOIN dims d ON d.id=f.g WHERE f.day=DATE '2026-01-01' GROUP BY d.label ORDER BY d.label");
    try same("SELECT d.label,COUNT(DISTINCT f.customer),SUM(f.v) FROM facts f JOIN dims d ON d.id=f.g GROUP BY d.label ORDER BY d.label");
    try same("SELECT d.label,f.g,COUNT(*),SUM(f.v) FROM facts f JOIN dims d ON d.id=f.g GROUP BY d.label,f.g ORDER BY d.label,f.g");
    try same("WITH totals AS (SELECT g,COUNT(*) AS n,SUM(customer) AS total FROM facts GROUP BY g) SELECT d.label,SUM(t.n),SUM(t.total) FROM totals t JOIN dims d ON d.id=t.g WHERE t.total>0 GROUP BY d.label ORDER BY d.label");
    try check(lean.workspace.query.stream_stats.nested_factor_plans == 0 and backed.workspace.query.stream_stats.nested_factor_plans == 1);
}

pub fn main() !void {
    try scanBudget();
    try change("CREATE TABLE facts (id INT PRIMARY KEY,g INT NOT NULL,v INT,customer INT,day DATE)");
    try change("CREATE TABLE dims (id INT PRIMARY KEY,label TEXT)");
    try change("INSERT INTO dims VALUES (1,'a'),(2,'a'),(3,'b'),(4,'c')");
    var buffer: [128]u8 = undefined;
    for (0..128) |index| {
        var measure: [24]u8 = undefined;
        const amount = if (index % 7 == 0) "NULL" else try std.fmt.bufPrint(&measure, "{d}", .{index});
        const day = if (index % 2 == 0) "2025-01-01" else "2026-01-01";
        try change(try std.fmt.bufPrint(&buffer, "INSERT INTO facts VALUES ({d},{d},{s},{d},DATE '{s}')", .{ index, 1 + index % 4, amount, index % 9, day }));
    }
    try check(lean.tables[0].row_high == 128 and lean.tables[0].scan_high == 0);
    try queries();

    const reader = try lean.begin();
    try lean.statement(reader, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", &left, .{});
    try lean.statement(reader, "SELECT COUNT(*),SUM(v) FROM facts", &left, .{});
    const before = left.rows[0].cells[1].integer;
    try change("UPDATE facts SET v=-100 WHERE id=1");
    try lean.statement(reader, "SELECT COUNT(*),SUM(v) FROM facts", &left, .{});
    try check(left.rows[0].cells[1].integer == before and lean.workspace.query.stream_stats.summary_plans == 0);
    lean.abort(reader);
    try same("SELECT COUNT(*),SUM(v) FROM facts");
    try check(left.rows[0].cells[1].integer == before - 101);

    const uncommitted = try lean.begin();
    try lean.statement(uncommitted, "UPDATE facts SET v=777 WHERE id=2", &left, .{});
    try lean.statement(uncommitted, "SELECT v FROM facts WHERE id=2", &left, .{});
    try check(left.rows[0].cells[0].integer == 777);
    lean.abort(uncommitted);
    try same("SELECT v FROM facts WHERE id=2");
    try check(left.rows[0].cells[0].integer == 2);
    for (0..4) |index| try change(try std.fmt.bufPrint(&buffer, "DELETE FROM facts WHERE id={d}", .{index}));
    try change("INSERT INTO facts VALUES (130,1,10,3,DATE '2026-01-01')");
    try check(lean.tables[0].row_high < 128 and lean.tables[0].scan_high == 0);
    try queries();

    try backed.copyFromInto(&lean);
    try check(backed.tables[0].scan_high == lean.tables[0].row_high);
    try queries();
    try lean.copyFromInto(&backed);
    try check(lean.tables[0].scan_high == 0 and lean.tables[0].scan_values.len == 0);
    try queries();

    var control: sql.ExecutionControl = .{ .max_work = 10 };
    lean.session.control = &control;
    left.row_count = 7;
    try check(lean.execute(filtered, &left) == error.QueryWorkLimit and left.row_count == 7);
    lean.session.control = null;
    try relayout();
    std.debug.print("PASS SQL scan budget: {d} assertions, {d} logical WAL records\n", .{ assertions, records });
}
