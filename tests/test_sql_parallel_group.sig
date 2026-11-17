//! Fold real committed integral columns using caller-owned joined scan tasks.
const std = @import("std");
const sql = @import("sql");
const native = @import("task_team");
const NativeTeam = native.Team(sql.ExecutionControl.ScanTask, 3);

const rows = 65536 + 13;
const key_count = 11;
const query = "SELECT k,COUNT(*),COUNT(a),SUM(a),SUM(b),AVG(a) FROM fact GROUP BY k ORDER BY k";
const DB = sql.Database(.{
    .external_storage = true, .tables = 1, .columns = 6, .rows_per_table = 2,
    .work_rows = 512, .result_rows = 32, .tx_writes = 256, .text_bytes = 32,
    .integer_bits = 32, .compact_integral_scans = true, .typed_grouped_aggregates = true,
});
var db: DB = .{};
var serial: DB.Result = .{};
var result: DB.Result = .{};
var storage: [DB.backingBytes(rows + 2, (rows + 2) * 2, 4096) catch unreachable]u8 align(64) = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("parallel group assertion {d}\n", .{assertions});
        return error.ParallelGroupContract;
    }
}

const Team = struct {
    native_team: *NativeTeam,
    batches: usize = 0,
    native_tasks: usize = 0,
    cancel: bool = false,

    fn dispatch(raw: ?*anyopaque, tasks: []const sql.ExecutionControl.ScanTask) sql.Error!void {
        const team: *Team = @ptrCast(@alignCast(raw.?));
        team.batches += 1;
        if (team.native_team.tryDispatch(tasks)) {
            team.native_tasks += tasks.len - 1;
            return;
        }
        var index = tasks.len;
        while (index != 0) {
            index -= 1;
            const task = tasks[index];
            task.run(task.context);
        }
    }

    fn poll(raw: ?*anyopaque) sql.Error!void {
        const team: *Team = @ptrCast(@alignCast(raw.?));
        if (team.cancel and team.batches != 0) return error.QueryCanceled;
    }
};

fn same() !void {
    try check(serial.row_count == result.row_count and serial.column_count == result.column_count);
    for (serial.rows[0..serial.row_count], result.rows[0..result.row_count]) |*expected, *actual| {
        for (expected.cells[0..serial.column_count], actual.cells[0..result.column_count]) |*left, *right| {
            try check(std.meta.activeTag(left.*) == std.meta.activeTag(right.*) and DB.compareCells(left, right) == 0);
        }
    }
}

pub fn main() !void {
    try db.bindMemory(&storage, rows + 2, (rows + 2) * 2, 4096);
    try db.execute("CREATE TABLE fact (id INT PRIMARY KEY,k BIGINT,a BIGINT,b INT)", &result);
    var insertion: [256]u8 = undefined;
    var start: usize = 0;
    while (start < rows) {
        const end = @min(start + 64, rows);
        try db.execute(try std.fmt.bufPrint(&insertion,
            "INSERT INTO fact SELECT n,(n % 11)-5,2*((n % 31)-15),(n % 17)-8 FROM generate_series({d},{d}) AS g(n)",
            .{ start, end - 1 }), &result);
        start = end;
    }

    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    try db.execute(query, &serial);
    try check(db.workspace.query.stream_stats.narrow_typed_group_plans == 1);
    try check(db.workspace.query.stream_stats.parallel_typed_group_plans == 0);
    const exact_work = control.used;
    var pool: NativeTeam = .{};
    if (native.available) try pool.start(3);
    defer pool.stop() catch @panic("test scan workers did not join");
    var team: Team = .{ .native_team = &pool };
    control = .{
        .context = &team, .poll = &Team.poll,
        .parallel_scan = .{ .context = &team, .participants = 4, .dispatch = &Team.dispatch },
    };
    try db.execute(query, &result);
    try same();
    try check(control.used == exact_work);
    try check(result.row_count == key_count);
    try check(team.batches == 5 and db.workspace.query.stream_stats.parallel_typed_group_batches == 5);
    try check(db.workspace.query.stream_stats.parallel_typed_group_plans == 1);
    if (native.available) try check(team.native_tasks == 15);

    var counts: [key_count]i64 = @splat(0);
    var first: [key_count]i64 = @splat(0);
    var second: [key_count]i64 = @splat(0);
    for (0..rows) |index| {
        const key = index % key_count;
        counts[key] += 1;
        first[key] += 2 * (@as(i64, @intCast(index % 31)) - 15);
        second[key] += @as(i64, @intCast(index % 17)) - 8;
    }
    for (result.rows[0..result.row_count], 0..) |*row, key| {
        try check(row.cells[0].integer == @as(i64, @intCast(key)) - 5);
        try check(row.cells[1].integer == counts[key] and row.cells[2].integer == counts[key]);
        try check(row.cells[3].numeric.coef() == @abs(first[key]) and row.cells[3].numeric.negative == (first[key] < 0));
        try check(row.cells[4].integer == second[key]);
    }

    team = .{ .native_team = &pool, .cancel = true };
    control.reset(0);
    if (db.execute(query, &result)) |_| return error.ExpectedCancellation else |err| try check(err == error.QueryCanceled);
    try check(team.batches == 1);
    try same();

    team = .{ .native_team = &pool };
    control.reset(1);
    if (db.execute(query, &result)) |_| return error.ExpectedWorkLimit else |err| try check(err == error.QueryWorkLimit);
    try check(team.batches == 0 and control.used == 1);
    try same();

    control.reset(0);
    try db.execute("UPDATE fact SET a=NULL WHERE id=0", &result);
    try db.execute(query, &result);
    try check(team.batches == 0 and db.workspace.query.stream_stats.parallel_typed_group_plans == 0);
    try check(result.rows[0].cells[1].integer == counts[0] and result.rows[0].cells[2].integer == counts[0] - 1);

    try db.execute("UPDATE fact SET a=-30 WHERE id=0", &result);
    // BIGINT SUM/AVG share one measure. COUNT(*) plus both projections
    // bypasses the older two-aggregate and INT-only dense kernels.
    const one_measure = "SELECT k,SUM(a),AVG(a),COUNT(*) FROM fact GROUP BY k ORDER BY k";
    control.parallel_scan.?.participants = 1;
    try db.execute(one_measure, &serial);
    try check(team.batches == 0);
    control.parallel_scan.?.participants = 2;
    try db.execute(one_measure, &result);
    try same();
    try check(team.batches == 5 and db.workspace.query.stream_stats.parallel_typed_group_plans == 1);

    if (native.available) {
        try pool.stop();
        try pool.start(1);
        team = .{ .native_team = &pool };
        control.parallel_scan.?.participants = 4;
        try db.execute(one_measure, &result);
        try same();
        try check(team.batches == 5 and team.native_tasks == 0);
        control.parallel_scan.?.participants = 2;
        try db.execute(one_measure, &result);
        try same();
        try check(team.batches == 10 and team.native_tasks == 5);
    }

    std.debug.print("PASS partitioned integral grouping: {d} assertions\n", .{assertions});
}
