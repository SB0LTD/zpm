//! Exact published summaries: independent oracle, own/other writes, old
//! snapshots, rollback, publication failure, copy, replay and row churn.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=8,.rows_per_table=64,.versions_per_table=256,
    .tx_writes=192,.work_rows=32,.result_rows=32,.text_bytes=64,.integer_bits=32});
const Item=struct {alive:bool=false,a:?i64=null,b:?i64=null,c:bool=false,d:bool=false};
const Rows=[64]Item;
const ddl="CREATE TABLE t (id INT PRIMARY KEY, a INT, b BIGINT, c TEXT, d BOOLEAN)";
const aggregate="SELECT COUNT(*), COUNT(a), SUM(a), SUM(b)::TEXT, COUNT(c), COUNT(d) FROM t";
const scan="SELECT COUNT(*), COUNT(a), SUM(a), SUM(b)::TEXT, COUNT(c), COUNT(d) FROM t WHERE id >= 0";
var db:DB=.{};var copied:DB=.{};var producer:DB=.{};var replay:DB=.{};
var result:DB.Result=.{};var model:Rows=@splat(.{});var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("summary assertion {d}\n",.{assertions});return error.SummaryContractFailed;}}
fn verify(database:*DB,rows:*const Rows,summary:bool) !void {
    var count:i64=0;var ca:i64=0;var cb:i64=0;var cc:i64=0;var cd:i64=0;
    var sa:i64=0;var sb:i128=0;
    for(rows)|item|if(item.alive){
        count+=1;if(item.a)|a|{ca+=1;sa+=a;}if(item.b)|b|{cb+=1;sb+=b;}
        cc+=@intFromBool(item.c);cd+=@intFromBool(item.d);
    };
    try check(result.row_count==1 and result.column_count==6);
    const cells=&result.rows[0].cells;
    try check(cells[0].integer==count and cells[1].integer==ca and cells[4].integer==cc and cells[5].integer==cd);
    if(ca==0) try check(cells[2]==.null_value) else try check(cells[2].integer==sa);
    if(cb==0) try check(cells[3]==.null_value) else {
        var text:[64]u8=undefined;
        try check(cells[3]==.text and std.mem.eql(u8,cells[3].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{sb})));
    }
    const stats=database.workspace.query.stream_stats;
    try check(stats.summary_plans==@intFromBool(summary));
    try check(stats.rows==if(summary) 0 else @as(usize,@intCast(count)));
    try check(stats.summary_rows==if(summary) @as(usize,@intCast(count)) else 0);
}
fn read(database:*DB,rows:*const Rows,summary:bool,slot:?u16) !void {
    const source=if(summary) aggregate else scan;
    if(slot)|s| try database.statement(s,source,&result,.{}) else try database.execute(source,&result);
    try verify(database,rows,summary);
}
fn insert(database:*DB,id:usize,item:Item) !void {
    var a:[32]u8=undefined;var b:[32]u8=undefined;var text:[256]u8=undefined;
    const av=if(item.a)|v|try std.fmt.bufPrint(&a,"{d}",.{v}) else "NULL";
    const bv=if(item.b)|v|try std.fmt.bufPrint(&b,"{d}",.{v}) else "NULL";
    try database.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d},{s},{s},{s},{s})",
        .{id,av,bv,if(item.c) "'x'" else "NULL",if(item.d) "TRUE" else "NULL"}),&result);
}
fn failure(_: ?*anyopaque,_:[]const u8) anyerror!void {
    var wanted:i64=0;for(model)|item|{wanted+=@intFromBool(item.alive);}
    try check(db.tables[0].summary.rows==wanted);
    return error.InjectedFlushFailure;
}
fn normal() !void {
    try db.execute(ddl,&result);try read(&db,&model,true,null);
    for(0..32)|i|{
        const item:Item=.{.alive=true,.a=if(i%5==0) null else @as(i64,@intCast(i))-17,
            .b=if(i%7==0) null else if(i%2==0) -9223372036854775807-1 else 9223372036854775807,
            .c=i%3!=0,.d=i%4!=0};
        try insert(&db,i,item);model[i]=item;
        try read(&db,&model,true,null);
    }
    try read(&db,&model,false,null);
    const before=result;
    if(db.execute("SELECT SUM(1 / (id - 7)) FROM t",&result)) |_| return error.ExpectedError
        else |err| try check(err==error.DivisionByZero);
    try check(result.row_count==before.row_count and DB.compareCells(&result.rows[0].cells[0],&before.rows[0].cells[0])==0);
    var record:[65536]u8=undefined;var used:usize=0;
    if(db.executeChanges("INSERT INTO t VALUES (63,1,1,'x',TRUE)",&result,&record,&used,null,failure)) |_| return error.ExpectedError
        else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0);try read(&db,&model,true,null);
    const writer=try db.begin();
    try db.statement(writer,"UPDATE t SET a = 7",&result,.{});
    var changed=model;for(&changed)|*item|if(item.alive){item.a=7;};
    // The reader may use published metadata while another writer is pending.
    try read(&db,&model,true,null);
    try db.statement(writer,aggregate,&result,.{});try verify(&db,&changed,false);
    try db.savepoint(writer,"s");
    try db.statement(writer,"UPDATE t SET a = 9",&result,.{});
    try db.statement(writer,"DELETE FROM t WHERE id = 0",&result,.{});
    _=try db.rollbackTo(writer,"s");
    try db.statement(writer,aggregate,&result,.{});try verify(&db,&changed,false);
    db.publishCommit(writer);model=changed;try read(&db,&model,true,null);
    // Create a real parked read, then deliberately retain its old CSN to
    // exercise the same-snapshot resume guard after another commit.
    const blocker=try db.begin();try db.statement(blocker,"DROP TABLE t",&result,.{});
    const reader=try db.begin();
    if(db.statement(reader,aggregate,&result,.{})) |_| return error.ExpectedPark
        else |err| try check(err==error.WouldBlock);
    db.txs[reader].fresh=false;
    db.abort(blocker);
    try db.execute("UPDATE t SET a = 11 WHERE id = 0",&result);
    try db.statement(reader,aggregate,&result,.{.@"resume"=true});try verify(&db,&model,false);
    db.abort(reader);model[0].a=11;try read(&db,&model,true,null);
    try copied.copyFromInto(&db);try read(&copied,&model,true,null);const copy_model=model;
    var rng:u64=1729;
    for(0..512)|step|{
        rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;
        const id:usize=@intCast(rng%64);var text:[256]u8=undefined;
        if(!model[id].alive){
            model[id]=.{.alive=true,.a=if(rng%3==0) null else @as(i64,@intCast(rng%1000))-500,
                .b=if(rng%5==0) null else @as(i64,@intCast(rng%100000))-50000,.c=rng%2==0,.d=rng%3==0};
            try insert(&db,id,model[id]);
        }else if(rng%3==0){
            try db.execute(try std.fmt.bufPrint(&text,"DELETE FROM t WHERE id = {d}",.{id}),&result);model[id]=.{};
        }else{
            const value=@as(i64,@intCast(rng%1000))-500;
            try db.execute(try std.fmt.bufPrint(&text,"UPDATE t SET a = {d}, b = {d} WHERE id = {d}",.{value,value*10000000000,id}),&result);
            model[id].a=value;model[id].b=value*10000000000;
        }
        try read(&db,&model,true,null);if(step%17==0)try read(&db,&model,false,null);
    }
    // Model copy is independent of subsequent mutations/reclamation.
    try read(&copied,&copy_model,true,null);
}
fn recovery() !void {
    var buffer:[65536]u8=undefined;var scratch:DB.ReplayScratch=.{};
    const statements=[_][]const u8{ddl,"INSERT INTO t VALUES (1,NULL,9223372036854775807,'x',TRUE),(2,5,-9223372036854775808,NULL,NULL)",
        "UPDATE t SET a = -7 WHERE id = 1","DELETE FROM t WHERE id = 2"};
    for(statements)|statement|{
        var used:usize=0;try producer.executeChanges(statement,&result,&buffer,&used,null,null);
        try replay.applyChangeRecord(buffer[0..used],&scratch);
        try producer.execute(aggregate,&result);const expected=result;
        try replay.execute(aggregate,&result);
        for(0..6)|i|try check(DB.compareCells(&expected.rows[0].cells[i],&result.rows[0].cells[i])==0);
        try check(replay.workspace.query.stream_stats.summary_plans==1);
    }
}
pub fn main() !void {
    try normal();try recovery();
    std.debug.print("{{\"suite\":\"sql-summary\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
