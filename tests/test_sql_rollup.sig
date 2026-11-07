//! Opt-in exact committed group synopses. The bounded metadata budget must
//! fall back without limiting SQL, and never expose an uncommitted transition.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=1,.columns=8,.rows_per_table=64,.tx_writes=192,
    .work_rows=128,.result_rows=64,.text_bytes=64,.integer_bits=32,.summary_groups=8});
const Item=struct {alive:bool=false,key:?i64=null,v:?i64=null,w:?i64=null,label:bool=false};
const Group=struct {key:?i64=null,count:i64=0,cv:i64=0,cw:i64=0,total:i64=0,wide:i128=0,labels:i64=0};
const Rows=[64]Item;
const ddl="CREATE TABLE t (id INT PRIMARY KEY, g INT, v INT, w BIGINT, label TEXT)";
const query="SELECT g,COUNT(*),COUNT(v),SUM(v),SUM(w)::TEXT,COUNT(label) FROM t GROUP BY g ORDER BY g NULLS FIRST";
const scan="SELECT g,COUNT(*),COUNT(v),SUM(v),SUM(w)::TEXT,COUNT(label) FROM t WHERE id >= 0 GROUP BY g ORDER BY g NULLS FIRST";
var db:DB=.{};var copy:DB=.{};var producer:DB=.{};var replay:DB=.{};
var result:DB.Result=.{};var model:Rows=@splat(.{});var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("rollup assertion {d}\n",.{assertions});return error.RollupContractFailed;}}
fn same(a:?i64,b:?i64)bool {return if(a)|x|if(b)|y|x==y else false else b==null;}
fn less(a:?i64,b:?i64)bool {return if(a)|x|if(b)|y|x<y else false else b!=null;}
fn verify(database:*DB,rows:*const Rows,metadata:bool) !void {
    var groups:[64]Group=undefined;var used:usize=0;var count:usize=0;
    for(rows)|item|if(item.alive){
        count+=1;var at:usize=0;while(at<used and !same(groups[at].key,item.key)) : (at+=1) {}
        if(at==used){groups[at]=.{.key=item.key};used+=1;}
        const g=&groups[at];g.count+=1;g.labels+=@intFromBool(item.label);
        if(item.v)|v|{g.cv+=1;g.total+=v;}if(item.w)|w|{g.cw+=1;g.wide+=w;}
    };
    if(used>1)for(1..used)|i|{var at=i;while(at>0 and less(groups[at].key,groups[at-1].key)) : (at-=1){const tmp=groups[at];groups[at]=groups[at-1];groups[at-1]=tmp;}};
    try check(result.row_count==used);
    for(groups[0..used],0..)|g,i|{
        const c=&result.rows[i].cells;
        if(g.key)|key|try check(c[0].integer==key) else try check(c[0]==.null_value);
        try check(c[1].integer==g.count and c[2].integer==g.cv and c[5].integer==g.labels);
        if(g.cv==0)try check(c[3]==.null_value) else try check(c[3].integer==g.total);
        if(g.cw==0)try check(c[4]==.null_value) else {var text:[64]u8=undefined;try check(std.mem.eql(u8,c[4].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{g.wide})));}
    }
    const s=database.workspace.query.stream_stats;
    try check(s.summary_plans==@intFromBool(metadata) and s.summary_rows==if(metadata) count else 0);
    try check(s.rows==if(metadata) @as(usize,0) else count);
}
fn read(database:*DB,rows:*const Rows,metadata:bool,slot:?u16) !void {
    if(slot)|s|try database.statement(s,query,&result,.{}) else try database.execute(query,&result);
    try verify(database,rows,metadata);
}
fn insert(database:*DB,id:usize,item:Item) !void {
    var text:[256]u8=undefined;var k:[32]u8=undefined;var v:[32]u8=undefined;var w:[32]u8=undefined;
    const key=if(item.key)|x|try std.fmt.bufPrint(&k,"{d}",.{x}) else "NULL";
    const val=if(item.v)|x|try std.fmt.bufPrint(&v,"{d}",.{x}) else "NULL";
    const wide=if(item.w)|x|try std.fmt.bufPrint(&w,"{d}",.{x}) else "NULL";
    try database.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d},{s},{s},{s},{s})",.{id,key,val,wide,if(item.label) "'x'" else "NULL"}),&result);
}
fn failedFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {try read(&db,&model,true,null);return error.InjectedFlushFailure;}
fn normal() !void {
    try db.execute(ddl,&result);try read(&db,&model,true,null);
    for(0..32)|i|{
        model[i]=.{.alive=true,.key=if(i%5==0)null else @as(i64,@intCast(i%3))-1,
            .v=if(i%7==0)null else @as(i64,@intCast(i))-17,
            .w=if(i%11==0)null else if(i%2==0) -9223372036854775807-1 else 9223372036854775807,.label=i%3!=0};
        try insert(&db,i,model[i]);try read(&db,&model,true,null);
    }
    try check(!db.tables[0].rollups[0].valid and db.tables[0].rollups[1].valid);
    try db.execute(scan,&result);try verify(&db,&model,false);
    var buffer:[65536]u8=undefined;var used:usize=0;
    if(db.executeChanges("UPDATE t SET v = 99 WHERE id = 0",&result,&buffer,&used,null,failedFlush)) |_| return error.ExpectedFailure
        else |err|try check(err==error.InjectedFlushFailure);
    try check(used==0);try read(&db,&model,true,null);
    const writer=try db.begin();try db.statement(writer,"UPDATE t SET v = 7",&result,.{});
    var changed=model;for(&changed)|*item|if(item.alive){item.v=7;};
    try read(&db,&model,true,null);try read(&db,&changed,false,writer);
    try db.savepoint(writer,"s");try db.statement(writer,"DELETE FROM t WHERE id < 8",&result,.{});
    _=try db.rollbackTo(writer,"s");try read(&db,&changed,false,writer);
    db.publishCommit(writer);model=changed;try read(&db,&model,true,null);
    // Retain a real parked read's old snapshot through a subsequent commit.
    const blocker=try db.begin();try db.statement(blocker,"DROP TABLE t",&result,.{});
    const reader=try db.begin();
    if(db.statement(reader,query,&result,.{})) |_|return error.ExpectedPark else |err|try check(err==error.WouldBlock);
    db.txs[reader].fresh=false;db.abort(blocker);
    try db.execute("UPDATE t SET g = 2, v = -11 WHERE id = 0",&result);
    try db.statement(reader,query,&result,.{.@"resume"=true});try verify(&db,&model,false);db.abort(reader);
    model[0].key=2;model[0].v=-11;try read(&db,&model,true,null);
    try copy.copyFromInto(&db);const copied_model=model;
    var rng:u64=271828;var text:[256]u8=undefined;
    for(0..256)|i|{
        rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;const id:usize=@intCast(rng%64);
        if(!model[id].alive){
            model[id]=.{.alive=true,.key=if(rng%5==0)null else @as(i64,@intCast(rng%3))-1,
                .v=if(rng%7==0)null else @as(i64,@intCast(rng%200))-100,.w=@as(i64,@intCast(rng%100000))-50000,.label=rng%2==0};
            try insert(&db,id,model[id]);
        }else if(rng%3==0){try db.execute(try std.fmt.bufPrint(&text,"DELETE FROM t WHERE id = {d}",.{id}),&result);model[id]=.{};}
        else {const value=@as(i64,@intCast(rng%200))-100;
            try db.execute(try std.fmt.bufPrint(&text,"UPDATE t SET g = {d}, v = {d} WHERE id = {d}",.{@as(i64,@intCast(rng%3))-1,value,id}),&result);
            model[id].key=@as(i64,@intCast(rng%3))-1;model[id].v=value;}
        try read(&db,&model,true,null);
        if(i%17==0){try db.execute(scan,&result);try verify(&db,&model,false);}
    }
    try read(&copy,&copied_model,true,null);
    try db.execute("SELECT g,AVG(v),AVG(w) FROM t GROUP BY g ORDER BY g",&result);const averages=result;
    try check(db.workspace.query.stream_stats.summary_plans==1);
    try db.execute("SELECT g,AVG(v),AVG(w) FROM t WHERE id >= 0 GROUP BY g ORDER BY g",&result);
    try check(result.row_count==averages.row_count and db.workspace.query.stream_stats.summary_plans==0);
    for(0..result.row_count)|r|for(0..3)|c|try check(DB.compareCells(&averages.rows[r].cells[c],&result.rows[r].cells[c])==0);
    // Budget overflow disables only the optimization, not SQL correctness.
    try db.execute("UPDATE t SET g = id",&result);for(&model,0..)|*item,i|if(item.alive){item.key=@intCast(i);};
    try check(!db.tables[0].rollups[1].valid);try read(&db,&model,false,null);
    try db.execute("DELETE FROM t",&result);model=@splat(.{});
    try check(db.tables[0].rollups[1].valid);try read(&db,&model,true,null);
    for(0..4)|i|{model[i]=.{.alive=true,.key=@intCast(i),.v=1,.w=2};try insert(&db,i,model[i]);}
    try read(&db,&model,true,null);
    try db.execute("DROP TABLE t",&result);model=@splat(.{});
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY,g BIGINT,v INT,w BIGINT,label TEXT)",&result);
    model[0]=.{.alive=true,.key=-9223372036854775807-1,.v=-2,.w=3};
    model[1]=.{.alive=true,.key=9223372036854775807,.v=5,.w=-7};
    model[2]=.{.alive=true,.key=null,.v=null,.w=null};
    for(0..3)|i|try insert(&db,i,model[i]);
    try read(&db,&model,true,null);
    // Text groups own their representative bytes; deleted/version-reclaimed
    // rows must not leave dangling keys. Numerically equal scale variants
    // retain the generic representative path instead.
    try db.execute("DROP TABLE t",&result);
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY,g TEXT,v INT,w BIGINT,label TEXT)",&result);
    try db.execute("INSERT INTO t VALUES (1,'a',2,3,'x'),(2,'a',4,5,NULL),(3,NULL,NULL,9,'y')",&result);
    try db.execute(query,&result);try check(db.workspace.query.stream_stats.summary_plans==1 and result.row_count==2);
    try check(result.rows[0].cells[0]==.null_value and result.rows[0].cells[1].integer==1 and result.rows[1].cells[1].integer==2 and result.rows[1].cells[3].integer==6);
    try db.execute("DELETE FROM t WHERE id = 1",&result);
    try db.execute(query,&result);try check(result.rows[1].cells[1].integer==1 and result.rows[1].cells[3].integer==4 and std.mem.eql(u8,result.rows[1].cells[0].text.slice(),"a"));
    try db.execute("DROP TABLE t",&result);
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY,g NUMERIC,v INT,w BIGINT,label TEXT)",&result);
    try db.execute("INSERT INTO t VALUES (1,1.0,2,3,'x'),(2,1.00,4,5,NULL)",&result);
    try db.execute("DELETE FROM t WHERE id = 1",&result);
    try db.execute("SELECT g::TEXT,COUNT(*) FROM t GROUP BY g",&result);
    try check(db.workspace.query.stream_stats.summary_plans==0 and result.rows[0].cells[1].integer==1 and std.mem.eql(u8,result.rows[0].cells[0].text.slice(),"1.00"));
}
fn recovery() !void {
    var buffer:[65536]u8=undefined;var scratch:DB.ReplayScratch=.{};
    const statements=[_][]const u8{ddl,"INSERT INTO t VALUES (1,NULL,1,9223372036854775807,'x'),(2,1,NULL,-9223372036854775808,NULL)",
        "UPDATE t SET g = 1, v = -7 WHERE id = 1","DELETE FROM t WHERE id = 2"};
    for(statements)|statement|{var used:usize=0;try producer.executeChanges(statement,&result,&buffer,&used,null,null);
        try replay.applyChangeRecord(buffer[0..used],&scratch);try producer.execute(query,&result);const expected=result;
        try replay.execute(query,&result);try check(result.row_count==expected.row_count);
        for(0..result.row_count)|r|for(0..6)|c|try check(DB.compareCells(&expected.rows[r].cells[c],&result.rows[r].cells[c])==0);
        try check(replay.workspace.query.stream_stats.summary_plans==1);
        try check(producer.tables[0].rollups[1].valid==replay.tables[0].rollups[1].valid and producer.tables[0].rollups[1].used==replay.tables[0].rollups[1].used);
    }
}
pub fn main() !void {try normal();try recovery();std.debug.print("{{\"suite\":\"sql-rollup\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});}
