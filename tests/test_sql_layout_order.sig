//! Proven physical order may avoid scanning/sorting all rows. Proofs must
//! survive copy/replay/stable compaction, and invalidate before changed values
//! can be read by any snapshot. No proof is assumed from insertion IDs alone.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables=2,.columns=4,.rows_per_table=256,
    .work_rows=32,.result_rows=32,.tx_writes=64,.integer_bits=32 });
var db: DB=.{};var copy: DB=.{};var source: DB=.{};var replay: DB=.{};
var result: DB.Result=.{};var assertions: usize=0;
fn check(ok: bool) !void { assertions+=1;if(!ok) return error.LayoutOrderFailed; }
fn first(database: *DB,query: []const u8,wanted: i64) !void {
    try database.execute(query,&result);try check(result.row_count!=0 and result.rows[0].cells[0].integer==wanted);
}
fn bounded(database: *DB,query: []const u8,wanted: i64) !void {
    var control: sql.ExecutionControl=.{.max_work=512};database.session.control=&control;
    defer database.session.control=null;
    try first(database,query,wanted);try check(control.used<512);
}
fn sequence(database: *DB,query: []const u8,start: i64,step: i64) !void {
    try bounded(database,query,start);
    try check(result.row_count==16);
    for(result.rows[0..result.row_count],0..) |row,i|
        try check(row.cells[0].integer==start+step*@as(i64,@intCast(i)));
}
fn append(database: *DB,start: usize,end: usize) !void {
    var buffer: [192]u8=undefined;
    for(start..end)|i| try database.execute(try std.fmt.bufPrint(&buffer,"INSERT INTO t VALUES ({d},{d},{d})",.{i,@as(i64,192)-@as(i64,@intCast(i)),i%7}),&result);
}
fn normal() !void {
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, v INT, g INT)",&result);
    try append(&db,0,192);
    try check(db.tables[0].column_order[0].state==.increasing);
    try check(db.tables[0].column_order[1].state==.decreasing);
    try check(db.tables[0].column_order[2].state==.unordered);
    try sequence(&db,"SELECT id FROM t ORDER BY id LIMIT 16",0,1);
    try sequence(&db,"SELECT id FROM t ORDER BY id DESC LIMIT 16",191,-1);
    try sequence(&db,"SELECT id FROM t ORDER BY v,id LIMIT 16",191,-1);
    try sequence(&db,"SELECT id FROM t ORDER BY v DESC,id DESC LIMIT 16",0,1);
    try first(&db,"SELECT id FROM t WHERE id > 100 ORDER BY id LIMIT 16",101);
    try db.execute("SELECT id FROM t WHERE id < 0 ORDER BY id LIMIT 16",&result);try check(result.row_count==0);
    try db.execute("UPDATE t SET g = 99 WHERE id = 17",&result);
    try check(db.tables[0].column_order[0].state==.increasing and db.tables[0].column_order[1].state==.decreasing);
    try copy.copyFromInto(&db);
    try check(copy.tables[0].column_order[0].state==.increasing);
    try bounded(&copy,"SELECT id FROM t ORDER BY v,id LIMIT 16",191);
    // Reclaim directory holes, then append enough rows to force stable compaction.
    try db.execute("DELETE FROM t WHERE id < 40",&result);
    try db.execute("DELETE FROM t WHERE id >= 40 AND id < 80",&result);
    try append(&db,192,320);
    try check(db.tables[0].row_high<320 and db.tables[0].column_order[0].state==.increasing);
    try bounded(&db,"SELECT id FROM t ORDER BY id LIMIT 16",80);
    try bounded(&db,"SELECT id FROM t ORDER BY v,id LIMIT 16",319);
    try db.execute("UPDATE t SET id = 5000 WHERE id = 100",&result);
    try check(db.tables[0].column_order[0].state==.unordered and db.tables[0].column_order[1].state==.decreasing);
    try first(&db,"SELECT id FROM t ORDER BY id DESC LIMIT 16",5000);
    try bounded(&db,"SELECT id FROM t ORDER BY v,id LIMIT 16",319);
    const writer=try db.begin();const reader=try db.begin();
    try db.statement(writer,"UPDATE t SET v = -99999 WHERE id = 150",&result,.{});
    try check(db.tables[0].column_order[1].state==.unordered);
    try db.statement(reader,"SELECT id FROM t ORDER BY v,id LIMIT 16",&result,.{});
    try check(result.rows[0].cells[0].integer==319);
    try db.statement(writer,"SELECT id FROM t ORDER BY v,id LIMIT 16",&result,.{});
    try check(result.rows[0].cells[0].integer==150);
    db.abort(writer);db.abort(reader);
    try first(&db,"SELECT id FROM t ORDER BY v,id LIMIT 16",319);
    try check(db.tables[0].column_order[1].state==.unordered); // conservative after abort
    // No primary key: the same metadata is still maintained.
    try db.execute("CREATE TABLE u (v INT)",&result);
    try db.execute("INSERT INTO u VALUES (3),(2),(1)",&result);
    try check(db.tables[1].column_order[0].state==.decreasing);
    try first(&db,"SELECT v FROM u ORDER BY v LIMIT 1",1);
    // Ties and NULLs cannot claim strict leading-key order.
    try db.execute("INSERT INTO u VALUES (1)",&result);
    try check(db.tables[1].column_order[0].state==.unordered);
    try db.execute("INSERT INTO u VALUES (NULL)",&result);
    try db.execute("SELECT v FROM u ORDER BY v NULLS FIRST LIMIT 1",&result);try check(result.rows[0].cells[0]==.null_value);
}
fn recovery() !void {
    var buffer: [65536]u8=undefined;var used: usize=0;var scratch: DB.ReplayScratch=.{};
    const statements=[_] []const u8{"CREATE TABLE t (id INT PRIMARY KEY, v INT)","INSERT INTO t VALUES (1,10),(2,20),(3,30)","UPDATE t SET v = 1 WHERE id = 2"};
    for(statements)|statement| {
        used=0;
        try source.executeChanges(statement,&result,&buffer,&used,null,null);
        replay.applyChangeRecord(buffer[0..used],&scratch) catch |err| {
            std.debug.print("replay failed for {s}: {s}\n",.{statement,@errorName(err)});return err;
        };
    }
    try check(replay.tables[0].column_order[0].state==.increasing);
    try check(replay.tables[0].column_order[1].state==.unordered);
    try bounded(&replay,"SELECT id FROM t ORDER BY id DESC LIMIT 1",3);
    try first(&replay,"SELECT id FROM t ORDER BY v LIMIT 1",2);
}
pub fn main() !void {
    try normal();try recovery();
    std.debug.print("{{\"suite\":\"sql-layout-order\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
