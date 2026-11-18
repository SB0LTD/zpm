//! Caller-owned medium cache with a bounded small-cache budget and exact scan results.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .external_storage = true, .external_workspace = true, .external_results = true,
    .tables = 1, .columns = 4, .rows_per_table = 4, .work_rows = 1024, .result_rows = 512,
    .text_bytes = 32, .compact_integral_scans = true });
const Cache = DB.ReadResultCache;
const rows = 720;
const budget = 4 * 1024 * 1024;
const layout = Cache.tieredLayoutForBytes(budget, 1024, 128, 512) catch unreachable;
const medium = layout.projected orelse unreachable;
var backing: [DB.backingBytes(rows, rows * 3, 4096) catch unreachable]u8 align(16) = undefined;
var workspace: [1024 * 8]DB.Cell = undefined;
var scratch: [DB.ReadContext.backingBytes(1024) catch unreachable]u8 align(16) = undefined;
var ordinary_output: [512 * @sizeOf(DB.Row)]u8 align(16) = undefined;
var cached_output: [512 * @sizeOf(DB.Row)]u8 align(16) = undefined;
var region: [layout.bytes]u8 align(16) = undefined;
var db: DB = .{};
var context: DB.ReadContext = .{};
var cache: Cache = undefined;
var ordinary: DB.Result = .{};
var result: DB.Result = .{};
var assertions: usize = 0;
const scan = "SELECT id AS k, n FROM projected WHERE band=1 AND n>100";
const small = "SELECT band, count(*) FROM projected GROUP BY band ORDER BY band";

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("projected cache assertion {d} failed\n", .{assertions});
        return error.ProjectedCacheContract;
    }
}

fn read(source: []const u8, csn: u64, reused: bool) !void {
    try context.prepare(&db, source, .{ .csn = csn });
    try context.runCached(&result, &cache);
    try check(context.last_result_reused == reused);
}

fn compare(expected: usize) !void {
    try db.execute(scan, &ordinary);
    try check(result.column_count == 2 and ordinary.column_count == 2);
    try check(expected == ordinary.row_count and expected == result.row_count);
    try check(std.mem.eql(u8, result.column_names[0].slice(), "k"));
    try check(result.column_types[0] == .integer32 and result.column_types[1] == .integer);
    for (0..expected) |index| {
        try check(result.rows[index].cells[0].integer == ordinary.rows[index].cells[0].integer);
        try check(result.rows[index].cells[1].integer == ordinary.rows[index].cells[1].integer);
    }
}

fn canceled(_: ?*anyopaque) DB.SqlError!void { return error.QueryCanceled; }

pub fn main() !void {
    try check(layout.bytes <= budget and medium.bytes <= budget / 8);
    try check(layout.small_offset >= medium.bytes and layout.small.entries > medium.entries);
    try check((try Cache.tieredLayoutForBytes(64 * 1024, 512, 4, 512)).projected == null);
    try db.bindMemory(&backing, rows, rows * 3, 4096);
    try db.bindWorkspace(&workspace);
    try context.bindMemory(&scratch, 1024);
    try ordinary.bindMemory(&ordinary_output, 512);
    try result.bindMemory(&cached_output, 512);
    try cache.bindMemory(&db, region[layout.small_offset..], layout.small.entries, 1024, 128);
    if (cache.bindProjectedMemory(region[layout.small_offset..], 512, 512)) |_| return error.AliasAccepted
    else |err| try check(err == error.InvalidParameterValue);
    try cache.bindProjectedMemory(region[0..medium.bytes], 512, 512);
    var alias: DB.Result = .{};
    try alias.bindMemory(region[0..medium.bytes], 1);
    try context.prepare(&db, "SELECT 1", .{.csn=db.csn});
    if (context.runCached(&alias, &cache)) |_| return error.AliasAccepted
    else |err| try check(err == error.InvalidParameterValue);

    try db.execute("CREATE TABLE projected (id INTEGER PRIMARY KEY, band INTEGER NOT NULL, n BIGINT NOT NULL, nullable BIGINT)", &ordinary);
    var statement: [160]u8 = undefined;
    for (0..rows) |i| {
        try db.execute(try std.fmt.bufPrint(&statement, "INSERT INTO projected VALUES ({d},{d},{d},NULL)", .{i,i%2,i}), &ordinary);
    }
    try read(scan, db.csn, false);
    try compare(310);
    try check(cache.projectedStats().publications == 0);
    try read(scan, db.csn, false);
    try check(cache.projectedStats().publications == 1);
    try read(scan, db.csn, true);
    try compare(310);
    try check(cache.projectedStats().hits == 1 and cache.stats().hits == 0);

    try read(small, db.csn, false);
    try read(small, db.csn, true);
    const before = cache.projectedStats();
    for (0..3) |_| {
        try read("SELECT id FROM projected WHERE id=9", db.csn, false);
        try read("SELECT nullable FROM projected WHERE band=1", db.csn, false);
        try read("SELECT id FROM projected WHERE band=1 AND n>700", db.csn, false);
    }
    try check(before.publications == cache.projectedStats().publications and before.hits == cache.projectedStats().hits);
    try check(cache.stats().hits == 1);

    try context.prepare(&db, scan, .{.csn=db.csn});
    var control: DB.ExecutionControl = .{ .poll = canceled };
    context.session.control = &control;
    if (context.runCached(&result, &cache)) |_| return error.CancelIgnored
    else |err| try check(err == error.QueryCanceled);
    control = .{.max_work=20};
    if (context.runCached(&result, &cache)) |_| return error.WorkLimitIgnored
    else |err| try check(err == error.QueryWorkLimit);
    context.session.control = null;
    try check(cache.projectedStats().hits == before.hits);
    const old_csn = db.csn;
    const old_reader = try db.begin();
    try db.beginModes(old_reader, .{.isolation=.repeatable_read});
    try db.statement(old_reader, scan, &ordinary, .{});
    try db.execute("UPDATE projected SET n=-1 WHERE id=501", &ordinary);
    try read(scan, db.csn, false);
    try compare(309);
    try read(scan, db.csn, false);
    try read(scan, db.csn, true);
    try compare(309);
    try read(scan, old_csn, false);
    try check(result.row_count == 310);
    db.abort(old_reader);
    const lock_holder = try db.begin();
    try db.statement(lock_holder, "LOCK TABLE projected IN ACCESS EXCLUSIVE MODE", &ordinary, .{});
    if (context.prepare(&db, scan, .{.csn=db.csn})) |_| return error.LockIgnored
    else |err| try check(err == error.UnsupportedStatement);
    db.abort(lock_holder);
    try read(scan, db.csn, true);
    std.debug.print("PASS packed projected cache: {d} assertions\n", .{assertions});
}
