//! Bounded projection and stable top-K over real unique-key inner joins.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{
    .external_storage = true,
    .tables = 3,
    .columns = 6,
    .rows_per_table = 4,
    .integer_bits = 32,
    .compact_integral_scans = true,
    .text_bytes = 16,
    .work_rows = 512,
    .result_rows = 64,
});
const fact_count = 521;
const narrow_ref_count = 256;
var db: DB = .{};
var result: DB.Result = .{};
var expected: DB.Result = .{};
var rows: [3][fact_count + 1]DB.StorageRowSlot = undefined;
var versions: [3][(fact_count + 1) * 2]DB.StorageVersion = undefined;
var row_indexes: [3][2048]u32 = undefined;
var key_indexes: [3][4096]u32 = undefined;
var scan_values: [3][(fact_count + 1) * 6]i64 = undefined;
var scan_nonnull: [3][fact_count + 1]u64 = undefined;
var scan_live: [3][fact_count + 1]u8 = undefined;
var refs: [8192]u32 = undefined;
var snapshot_refs: [narrow_ref_count]u32 = undefined;
var read: DB.ReadContext = .{};
var assertions: usize = 0;

const from = " FROM facts f JOIN products p ON p.id=f.product JOIN stores s ON s.id=f.store";
const select = "SELECT f.id,p.category,s.region,f.amount" ++ from;
const materialize = "SELECT CAST(f.id AS INT) AS id,p.category,s.region,f.amount" ++ from;
const order = " ORDER BY s.region DESC,f.amount DESC NULLS LAST LIMIT 20 OFFSET 4";
const all_best = select ++ order;
const narrow_where = " WHERE f.id>=393";

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("joined projection assertion {d} failed\n", .{assertions});
        return error.JoinedProjectionContract;
    }
}

fn same() !void {
    try check(result.command == expected.command and result.affected_rows == expected.affected_rows);
    try check(result.row_count == expected.row_count and result.column_count == expected.column_count);
    for (0..expected.column_count) |column| {
        try check(result.column_types[column] == expected.column_types[column]);
        try check(result.column_typmods[column] == expected.column_typmods[column]);
        try check(std.mem.eql(u8, result.column_names[column].slice(), expected.column_names[column].slice()));
    }
    for (0..expected.row_count) |row| for (0..expected.column_count) |column| {
        try check(DB.compareCells(&result.rows[row].cells[column], &expected.rows[row].cells[column]) == 0);
    };
}

fn reference(text: []const u8) !void {
    db.workspace.query.refs = &refs;
    try db.execute(text, &expected);
    try check(db.workspace.query.stream_stats.joined_projection_plans == 0);
    db.workspace.query.refs = refs[0..narrow_ref_count];
}

fn reject(text: []const u8, wanted: sql.Error) !void {
    if (db.execute(text, &result)) |_| return error.ExpectedFailure else |err| {
        if (err != wanted) std.debug.print("wanted {s}, got {s}\n", .{ @errorName(wanted), @errorName(err) });
        try check(err == wanted);
    }
}

pub fn main() !void {
    var banks: [3]DB.StorageBacking = undefined;
    for (&banks, 0..) |*bank, index| bank.* = .{
        .rows = &rows[index],
        .versions = &versions[index],
        .row_index = &row_indexes[index],
        .key_index = &key_indexes[index],
        .scan_values = &scan_values[index],
        .scan_nonnull = &scan_nonnull[index],
        .scan_live = &scan_live[index],
    };
    try db.bindStorage(banks, &refs);
    try db.execute("CREATE TABLE facts(id INT PRIMARY KEY, product INT, store INT, amount INT)", &result);
    try db.execute("CREATE TABLE products(id INT PRIMARY KEY, category TEXT)", &result);
    try db.execute("CREATE TABLE stores(id INT PRIMARY KEY, region TEXT)", &result);
    try db.execute("INSERT INTO products VALUES (0,'tea'),(1,'coffee'),(2,'cocoa')", &result);
    try db.execute("INSERT INTO stores VALUES (0,'east'),(1,'west'),(2,'north')", &result);
    var sql_text: [256]u8 = undefined;
    for (0..fact_count) |id| {
        var amount_text: [24]u8 = undefined;
        const amount = if (id % 7 == 0) "NULL" else try std.fmt.bufPrint(&amount_text, "{d}", .{id % 5});
        try db.execute(try std.fmt.bufPrint(&sql_text, "INSERT INTO facts VALUES ({d},{d},{d},{s})", .{ id, id % 4, (id / 2) % 4, amount }), &result);
    }
    try db.execute("UPDATE facts SET product=NULL WHERE id=2", &result);
    try db.execute("DELETE FROM facts WHERE id=4", &result);

    // The general operator needs at least one reference per fact even
    // when a selective WHERE would leave ample space for the output.
    try reference(materialize ++ narrow_where ++ order);
    try check(expected.row_count == 20);
    try reject(materialize ++ narrow_where ++ order, error.WorkspaceCapacity);
    try db.execute(select ++ narrow_where ++ order, &result);
    try same();
    try check(db.workspace.query.stream_stats.joined_topk_plans == 1);
    try check(db.workspace.query.stream_stats.prefix_rejected > 300);
    try check(db.workspace.query.stream_stats.dimension_probes <= 256);

    // Hundreds of candidates, ties, NULL keys and missed dimension joins.
    // A stable top-K must agree with a full projection and stable sort.
    try reference(materialize ++ order);
    try check(expected.row_count == 20);
    try db.execute(all_best, &result);
    try same();
    try check(db.workspace.query.stream_stats.joined_projection_plans == 1);
    try check(db.workspace.query.stream_stats.joined_topk_plans == 1);
    try check(db.workspace.query.cell_low <= 25 * 5);
    try check(db.workspace.query.ref_low <= 24);

    const nulls = " ORDER BY f.amount ASC NULLS FIRST LIMIT 9 OFFSET 3";
    try reference(materialize ++ nulls);
    try db.execute(select ++ nulls, &result);
    try same();
    for (result.rows[0..result.row_count]) |row| try check(row.cells[3] == .null_value);

    const hidden = " ORDER BY f.store DESC,f.id LIMIT 9";
    try reference(materialize ++ hidden);
    try db.execute(select ++ hidden, &result);
    try same();
    try check(db.workspace.query.stream_stats.joined_topk_plans == 1);

    const few = " WHERE f.id>=510 ORDER BY f.amount LIMIT 900";
    try reference(materialize ++ few);
    try db.execute(select ++ few, &result);
    try same();
    try check(db.workspace.query.stream_stats.joined_projection_plans == 1);
    try check(db.workspace.query.stream_stats.joined_topk_plans == 0);

    try reference(materialize ++ " LIMIT 5 OFFSET 2");
    try db.execute(select ++ " LIMIT 5 OFFSET 2", &result);
    try same();
    try check(db.workspace.query.stream_stats.rows < fact_count);
    try check(db.workspace.query.stream_stats.joined_topk_plans == 0);

    try db.execute("PREPARE joined(INT) AS " ++ select ++ " WHERE f.id=$1 ORDER BY f.amount LIMIT 1", &result);
    try db.execute("EXECUTE joined(17)", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 17);
    try check(db.workspace.query.stream_stats.joined_topk_plans == 1);
    try db.execute("EXECUTE joined(NULL)", &result);
    try check(result.row_count == 0);

    try reference(materialize ++ order);
    try db.execute(all_best, &result);
    var control: sql.ExecutionControl = .{ .max_work = 100 };
    db.session.control = &control;
    try reject(all_best, error.QueryWorkLimit);
    db.session.control = null;
    try same();

    const reader = try db.begin();
    const old: DB.Snapshot = .{ .csn = db.csn };
    db.txs[reader].pin = old;
    try db.execute("DELETE FROM stores WHERE id=1", &result);
    try db.execute("UPDATE facts SET amount=500 WHERE id=17", &result);
    read.workspace.query.refs = &snapshot_refs;
    try read.execute(&db, all_best, old, &result);
    try same();
    try check(read.workspace.query.stream_stats.joined_topk_plans == 1);
    try check(read.workspace.query.stream_stats.gathered_rows == 0);
    db.abort(reader);

    // Joins with outer preservation, DISTINCT or potentially failing
    // expressions retain the general operator and its error semantics.
    db.workspace.query.refs = &refs;
    try db.execute("SELECT f.id FROM facts f LEFT JOIN products p ON p.id=f.product WHERE f.id=2 ORDER BY f.id LIMIT 1", &result);
    try check(result.row_count == 1 and db.workspace.query.stream_stats.joined_projection_plans == 0);
    try db.execute("SELECT DISTINCT p.category" ++ from ++ " ORDER BY p.category LIMIT 3", &result);
    try check(result.row_count == 2 and db.workspace.query.stream_stats.joined_projection_plans == 0);
    try db.execute("SELECT p.category" ++ from ++ " WHERE f.id>=512 ORDER BY p.category FETCH FIRST ROW WITH TIES", &result);
    try check(result.row_count > 1 and db.workspace.query.stream_stats.joined_projection_plans == 0);
    try db.execute("CREATE SEQUENCE joined_seq", &result);
    try db.execute("SELECT nextval('joined_seq'),f.id" ++ from ++ " WHERE f.id=17 ORDER BY f.id LIMIT 1", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 1);
    try check(db.workspace.query.stream_stats.joined_projection_plans == 0);
    try reject("SELECT 10/(f.id-f.id)" ++ from ++ " WHERE f.id=17 LIMIT 1", error.DivisionByZero);
    try check(db.workspace.query.stream_stats.joined_projection_plans == 0);
    std.debug.print("PASS bounded joined projection: {d} assertions\n", .{assertions});
}
