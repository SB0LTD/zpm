//! Dense-key proof, bounded retry, residual/range predicates, signed extremes
//! and non-NULL sort proofs across own writes and retained snapshots.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=1,.columns=4,.rows_per_table=128,.work_rows=32,.result_rows=32,.ordered_probe_rows=64,.integer_bits=32});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("ordered probe assertion {d}\n",.{assertions});return error.OrderedProbeFailed;}}
fn ids(source:[]const u8,wanted:[]const i64,slot:?u16) !void {
    if(slot)|s|try db.statement(s,source,&result,.{}) else try db.execute(source,&result);
    try check(result.row_count==wanted.len);
    for(wanted,0..)|value,i|try check(result.rows[i].cells[0].integer==value);
}
fn parked(source:[]const u8) !u16 {
    const blocker=try db.begin();try db.statement(blocker,"DROP TABLE t",&result,.{});
    const reader=try db.begin();
    if(db.statement(reader,source,&result,.{})) |_|return error.ExpectedPark else |err|try check(err==error.WouldBlock);
    db.txs[reader].fresh=false;db.abort(blocker);return reader;
}
fn resumed(reader:u16,source:[]const u8,wanted:[]const i64) !void {
    try db.statement(reader,source,&result,.{.@"resume"=true});try check(result.row_count==wanted.len);
    for(wanted,0..)|value,i|try check(result.rows[i].cells[0].integer==value);
}
pub fn main() !void {
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY,g INT,v INT)",&result);
    var text:[256]u8=undefined;
    for(0..96)|slot|{const id=slot*37%96;try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d},{d},{d})",.{id,id%4,96-id}),&result);}
    try check(db.tables[0].column_order[0].state==.unordered);
    try ids("SELECT id FROM t WHERE g = 3 ORDER BY id LIMIT 8",&.{3,7,11,15,19,23,27,31},null);
    try check(db.workspace.query.read_stats.key_successes==1 and db.workspace.query.read_stats.key_probes==32);
    const pending=try db.begin();try db.statement(pending,"INSERT INTO t VALUES (1000000000,3,1)",&result,.{});
    try ids("SELECT id FROM t WHERE g = 3 ORDER BY id LIMIT 8",&.{3,7,11,15,19,23,27,31},null);
    try check(db.workspace.query.read_stats.key_successes==1);db.abort(pending);
    try ids("SELECT id FROM t WHERE g = 3 ORDER BY id LIMIT 8",&.{3,7,11,15,19,23,27,31},null);
    try check(db.workspace.query.read_stats.key_successes==1);
    try ids("SELECT id FROM t WHERE g = 3 ORDER BY id DESC,v LIMIT 8",&.{95,91,87,83,79,75,71,67},null);
    try check(db.workspace.query.read_stats.key_successes==1);
    try ids("SELECT id FROM t WHERE id > 80 AND g = 3 ORDER BY id LIMIT 8",&.{83,87,91,95},null);
    try check(db.workspace.query.read_stats.key_probes==15);
    try ids("SELECT id FROM t WHERE 80 < id AND id < 92 ORDER BY id DESC LIMIT 8",&.{91,90,89,88,87,86,85,84},null);
    try check(db.workspace.query.read_stats.key_probes==8);
    try ids("SELECT id FROM t WHERE g = 3 AND id + 1 > 90 ORDER BY id LIMIT 8",&.{91,95},null);
    try check(db.workspace.query.read_stats.key_walks==1 and db.workspace.query.read_stats.key_fallbacks==1 and db.workspace.query.read_stats.key_probes==64);
    try ids("SELECT id FROM t WHERE id > 2147483647 ORDER BY id LIMIT 8",&.{},null);
    try ids("SELECT id FROM t ORDER BY id LIMIT 0",&.{},null);
    try check(db.workspace.query.read_stats.key_probes==0);
    try db.execute("DELETE FROM t WHERE id = 5",&result);
    try ids("SELECT id FROM t ORDER BY id LIMIT 8",&.{0,1,2,3,4,6,7,8},null);
    try check(db.workspace.query.read_stats.key_walks==0);
    try db.execute("INSERT INTO t VALUES (5,1,91)",&result);
    const writer=try db.begin();try db.statement(writer,"DELETE FROM t WHERE id = 5",&result,.{});
    try ids("SELECT id FROM t ORDER BY id LIMIT 8",&.{0,1,2,3,4,5,6,7},null);
    try check(db.workspace.query.read_stats.key_successes==1);
    try ids("SELECT id FROM t ORDER BY id LIMIT 8",&.{0,1,2,3,4,6,7,8},writer);
    try check(db.workspace.query.read_stats.key_walks==0);db.abort(writer);
    const sort="SELECT id FROM t ORDER BY v NULLS FIRST,id LIMIT 8";
    try ids(sort,&.{95,94,93,92,91,90,89,88},null);
    try check(db.workspace.query.read_stats.nonnull_sort_keys==2);
    const updater=try db.begin();try db.statement(updater,"UPDATE t SET v = NULL WHERE id = 0",&result,.{});
    try ids(sort,&.{0,95,94,93,92,91,90,89},updater);
    try check(db.workspace.query.read_stats.nonnull_sort_keys==1);
    try ids(sort,&.{95,94,93,92,91,90,89,88},null);
    try check(db.workspace.query.read_stats.nonnull_sort_keys==2);
    db.publishCommit(updater);
    try ids(sort,&.{0,95,94,93,92,91,90,89},null);
    try check(db.workspace.query.read_stats.nonnull_sort_keys==1);
    const reader=try parked(sort);
    try db.execute("UPDATE t SET v = 96 WHERE id = 0",&result);
    try resumed(reader,sort,&.{0,95,94,93,92,91,90,89});
    try check(db.workspace.query.read_stats.nonnull_sort_keys==1);db.abort(reader);
    try ids(sort,&.{95,94,93,92,91,90,89,88},null);
    try check(db.workspace.query.read_stats.nonnull_sort_keys==2);
    // LockRows keeps its existing scan/lock behavior.
    try ids("SELECT id FROM t WHERE g = 3 ORDER BY id LIMIT 8 FOR UPDATE",&.{3,7,11,15,19,23,27,31},null);
    try check(db.workspace.query.read_stats.key_walks==0);
    const before=result;var control:sql.ExecutionControl=.{.max_work=8};db.session.control=&control;
    if(db.execute("SELECT id FROM t WHERE g = 3 ORDER BY id LIMIT 8",&result)) |_|return error.ExpectedCancellation
        else |err|try check(err==error.QueryWorkLimit);
    db.session.control=null;
    try check(result.row_count==before.row_count);
    for(0..result.row_count)|i|try check(result.rows[i].cells[0].integer==before.rows[i].cells[0].integer);
    // i128 interval arithmetic must not wrap at either signed endpoint.
    try db.execute("DROP TABLE t",&result);try db.execute("CREATE TABLE t (id BIGINT PRIMARY KEY)",&result);
    for([_]i64{-9223372036854775806,-9223372036854775808,-9223372036854775805,-9223372036854775807})|id|
        try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d})",.{id}),&result);
    try ids("SELECT id FROM t ORDER BY id DESC LIMIT 3",&.{-9223372036854775805,-9223372036854775806,-9223372036854775807},null);
    try check(db.workspace.query.read_stats.key_successes==1);
    try ids("SELECT id FROM t WHERE id > -9223372036854775807 ORDER BY id LIMIT 8",&.{-9223372036854775806,-9223372036854775805},null);
    try db.execute("DROP TABLE t",&result);try db.execute("CREATE TABLE t (id BIGINT PRIMARY KEY)",&result);
    for([_]i64{9223372036854775806,9223372036854775804,9223372036854775807,9223372036854775805})|id|
        try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d})",.{id}),&result);
    try ids("SELECT id FROM t WHERE id < 9223372036854775807 ORDER BY id DESC LIMIT 8",&.{9223372036854775806,9223372036854775805,9223372036854775804},null);
    try check(db.workspace.query.read_stats.key_successes==1);
    std.debug.print("{{\"suite\":\"sql-ordered-probes\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
