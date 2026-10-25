//! Input cardinality must not determine scratch for eligible aggregates.
//! Caller buffers contain 100K rows but only 1024 query handles. Results use
//! independent integer models; failure paths preserve the previous result.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .external_storage = true, .tables = 1, .columns = 4,
    .rows_per_table = 4, .text_bytes = 32, .integer_bits = 32,
    .work_rows = 128, .result_rows = 128 });
const count = 100000;
var rows: [count]DB.StorageRowSlot = undefined;
var versions: [count * 2]DB.StorageVersion = undefined;
var row_index: [262144]u32 = undefined;
var key_index: [524288]u32 = undefined;
var refs: [1024]u32 = undefined;
var db: DB = .{};
var result: DB.Result = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) { std.debug.print("stream-group assertion {d} failed\n", .{assertions}); return error.StreamGroupContractFailed; }
}

fn grouped(n: usize) !void {
    try db.execute("SELECT g, COUNT(*), SUM(n) FROM data GROUP BY g ORDER BY g", &result);
    try check(result.row_count == 64);
    for (0..64) |g| {
        const size = (n - 1 - g) / 64 + 1;
        const sum = size * g + 64 * size * (size - 1) / 2;
        try check(result.rows[g].cells[0].integer == g);
        try check(result.rows[g].cells[1].integer == size);
        try check(result.rows[g].cells[2].integer == sum);
    }
    try check(db.workspace.query.stream_stats.rows == n);
    try check(db.workspace.query.stream_stats.groups == 64);
    try check(db.workspace.query.stream_stats.probes > n); // real bucket collisions
}

fn rejected(source: []const u8, expected: sql.Error) !void {
    const before = result;
    if (db.execute(source, &result)) |_| return error.FailureExpected else |err| try check(err == expected);
    try check(result.row_count == before.row_count and result.column_count == before.column_count);
    for (0..before.row_count) |r| for (0..before.column_count) |c| {
        try check(DB.compareCells(&result.rows[r].cells[c], &before.rows[r].cells[c]) == 0);
    };
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.pending_versions == 0);
}

const Cancel = struct {
    calls: usize = 0,
    fn poll(context: ?*anyopaque) sql.Error!void {
        const self: *Cancel = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls == 25) return error.QueryCanceled;
    }
};

fn large() !void {
    try db.bindStorage(.{.{ .rows = &rows, .versions = &versions,
        .row_index = &row_index, .key_index = &key_index }}, &refs);
    try db.execute("CREATE TABLE data (id INT PRIMARY KEY, g INT, n INT, label TEXT)", &result);
    try db.execute("SELECT COUNT(*), SUM(n), MIN(n) FROM data", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 0 and result.rows[0].cells[1] == .null_value and result.rows[0].cells[2] == .null_value);
    try db.execute("SELECT g, COUNT(*) FROM data GROUP BY g", &result);
    try check(result.row_count == 0);
    var text: [192]u8 = undefined;
    for (0..512) |i| try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO data VALUES ({d},{d},{d},'value')", .{i,i%64,i}), &result);
    try grouped(512);
    const small_stats = db.workspace.query.stream_stats;
    for (512..count) |i| try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO data VALUES ({d},{d},{d},'value')", .{i,i%64,i}), &result);
    try grouped(count);
    try check(db.workspace.query.stream_stats.scratch_cells == small_stats.scratch_cells);
    try check(db.workspace.query.stream_stats.scratch_refs == small_stats.scratch_refs);
    try check(db.workspace.query.stream_stats.scratch_refs <= refs.len);
    try db.execute("SELECT COUNT(*), SUM(n), MIN(n), MAX(n) FROM data", &result);
    try check(result.rows[0].cells[0].integer == count and result.rows[0].cells[1].integer == @as(i64, count)*(count-1)/2 and result.rows[0].cells[2].integer == 0 and result.rows[0].cells[3].integer == count-1);
    try check(db.workspace.query.stream_stats.scratch_refs == 0);
    try db.execute("SELECT g, label, COUNT(*) FROM data GROUP BY g, label ORDER BY g", &result);
    try check(result.row_count == 64 and result.rows[7].cells[1] == .text and result.rows[7].cells[2].integer == (count-1-7)/64+1);
    try db.execute("SELECT g FROM data WHERE id < 256 GROUP BY g HAVING SUM(n) >= 0 ORDER BY g DESC LIMIT 4", &result);
    try check(result.row_count == 4 and result.rows[0].cells[0].integer == 63 and result.rows[3].cells[0].integer == 60);
    try db.execute("SELECT g, SUM(n) FROM data WHERE id < 0 GROUP BY g", &result);
    try check(result.row_count == 0 and db.workspace.query.stream_stats.groups == 0);
    try db.execute("SELECT COUNT(*), SUM(n) FROM data WHERE id < 0", &result);
    try check(result.rows[0].cells[0].integer == 0 and result.rows[0].cells[1] == .null_value);
    try db.execute("SELECT g, COUNT(*) FILTER (WHERE n % 2 = 0) FROM data WHERE id < 256 GROUP BY g HAVING COUNT(*) > 0 ORDER BY g DESC LIMIT 3 OFFSET 1", &result);
    try check(result.row_count == 3 and result.rows[0].cells[0].integer == 62 and result.rows[0].cells[1].integer == 4 and result.rows[1].cells[0].integer == 61 and result.rows[1].cells[1].integer == 0);
    try rejected("SELECT id, COUNT(*) FROM data GROUP BY id ORDER BY id", error.WorkspaceCapacity);
    try rejected("SELECT SUM(n * 100000) FROM data", error.IntegerOverflow);
    // Cancel after group state exists; also exercise budget cancellation on
    // the scalar scan. Successful re-execution must not read poisoned state.
    var cancel: Cancel = .{};
    var control: sql.ExecutionControl = .{ .context = &cancel, .poll = &Cancel.poll, .poll_interval = 1 };
    db.session.control = &control;
    try rejected("SELECT g, SUM(n) FROM data GROUP BY g ORDER BY g", error.QueryCanceled);
    db.session.control = null;
    try check(cancel.calls == 25);
    control = .{ .max_work = 100 };
    db.session.control = &control;
    try rejected("SELECT COUNT(*), SUM(n) FROM data", error.QueryWorkLimit);
    db.session.control = null;
    @memset(&db.workspace.query.cells, .{ .integer = 0x55555555 });
    @memset(&refs, 0xaaaaaaaa);
    try grouped(count);
    // Reader must ignore the other transaction's pending version, while the
    // writer's aggregate sees its own update. Abort restores subsequent reads.
    const writer = try db.begin();
    try db.statement(writer, "UPDATE data SET n = -1, g = NULL WHERE id = 0", &result, .{});
    const reader = try db.begin();
    try db.statement(reader, "SELECT SUM(n) FROM data", &result, .{});
    try check(result.rows[0].cells[0].integer == @as(i64,count)*(count-1)/2);
    try db.statement(writer, "SELECT g, COUNT(*), SUM(n) FROM data WHERE id = 0 GROUP BY g", &result, .{});
    try check(result.row_count == 1 and result.rows[0].cells[0] == .null_value and result.rows[0].cells[1].integer == 1 and result.rows[0].cells[2].integer == -1);
    db.abort(reader); db.abort(writer);
    try grouped(count);
}

const Small = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 16,
    .text_bytes = 64, .work_rows = 64, .result_rows = 32, .integer_bits = 32 });
var small: Small = .{};
var sr: Small.Result = .{};
fn equivalent(source: []const u8) !void {
    try small.execute(source, &sr);
    try check(sr.row_count == 1 and sr.rows[0].cells[1].integer == 2);
}
fn equality() !void {
    try small.execute("CREATE TABLE numbers (n NUMERIC)", &sr);
    try small.execute("INSERT INTO numbers VALUES (1), (1.00)", &sr);
    try equivalent("SELECT n, COUNT(*) FROM numbers GROUP BY n");
    try small.execute("CREATE TABLE floats (n DOUBLE PRECISION)", &sr);
    try small.execute("INSERT INTO floats VALUES ('0'), ('-0')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM floats GROUP BY n");
    try small.execute("DELETE FROM floats", &sr);
    try small.execute("INSERT INTO floats VALUES ('NaN'), ('NaN')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM floats GROUP BY n");
    try small.execute("CREATE TABLE spans (n INTERVAL)", &sr);
    try small.execute("INSERT INTO spans VALUES ('1 day'), ('24 hours')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM spans GROUP BY n");
    try small.execute("CREATE TABLE documents (n JSONB)", &sr);
    try small.execute("INSERT INTO documents VALUES ('{\"x\":1}'), ('{\"x\":1.0}')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM documents GROUP BY n");
    // The independent DISTINCT aggregate path retains exact semantics.
    try small.execute("SELECT COUNT(DISTINCT n) FROM numbers", &sr);
    try check(sr.rows[0].cells[0].integer == 1 and small.workspace.query.stream_stats.rows == 0);
    try small.execute("SELECT n, COUNT(*) FROM numbers GROUP BY n ORDER BY n LIMIT 0", &sr);
    try check(sr.row_count == 0 and small.workspace.query.stream_stats.rows == 2);
}

pub fn main() !void {
    try large();
    try equality();
    std.debug.print("{{\"suite\":\"sql-stream-group\",\"pass\":true,\"assertions\":{d},\"rows\":{d},\"query_refs\":{d}}}\n", .{assertions,count,refs.len});
}
