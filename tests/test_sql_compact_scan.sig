//! Independent model + forced MVCC-scan differential; caller-backed only.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.external_storage=true,.compact_integral_scans=true,.tables=1,.columns=4,
    .rows_per_table=4,.work_rows=64,.result_rows=64,.tx_writes=128,.text_bytes=64,.integer_bits=32,.nulls_first_ascending=false});
var db:DB=.{};var copy:DB=.{};var producer:DB=.{};var replay:DB=.{};
var larger:DB=.{};
var buffers:[5][262144]u8 align(64)=undefined;
var result:DB.Result=.{};var wide:DB.Result=.{};
var assertions:usize=0;
const Item=struct{alive:bool=false,g:?i64=null,v:?i64=null};
var items:[128]Item=@splat(.{});
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("compact assertion {d}\n",.{assertions});return error.CompactScanFailed;}}
fn bind(database:*DB,index:usize) !void {@memset(&buffers[index],0xa5);try database.bindMemory(&buffers[index],128,256,4096);}
fn equal() !void {
    try check(result.row_count==wide.row_count and result.column_count==wide.column_count);
    for(result.rows[0..result.row_count],wide.rows[0..wide.row_count]) |a,b| for(a.cells[0..result.column_count],b.cells[0..wide.column_count]) |x,y| {
        if(x==.null_value) try check(y==.null_value)
        else if(x==.integer) try check(y==.integer and x.integer==y.integer)
        else if(x==.text) try check(y==.text and std.mem.eql(u8,x.text.slice(),y.text.slice()))
        else if(x==.numeric) try check(y==.numeric and std.meta.eql(x.numeric,y.numeric))
        else return error.UnexpectedCell;
    };
}
fn paired(database:*DB,source:[]const u8,compact:bool) !void {
    try database.execute(source,&result);
    try check(database.workspace.query.stream_stats.compact_plans==@intFromBool(compact));
    const valid=database.tables[0].summary.valid;database.tables[0].summary.valid=false;
    defer database.tables[0].summary.valid=valid;
    try database.execute(source,&wide);try check(database.workspace.query.stream_stats.compact_plans==0);try equal();
}
fn model() !void {
    try paired(&db,"SELECT g,COUNT(*),SUM(v),COUNT(v) FROM t WHERE id>=0 GROUP BY g ORDER BY g",true);
    var expected_groups:usize=0;
    // PostgreSQL's default ascending order places NULL after integral keys.
    for(0..18) |key| {
        var count:i64=0;var nn:i64=0;var sum:i64=0;
        for(items) |item| if(item.alive and (if(key==17) item.g==null else item.g!=null and item.g.?==key)) {
            count+=1;if(item.v) |v| {nn+=1;sum+=v;}
        };
        if(count==0) continue;
        const cells=&result.rows[expected_groups].cells;
        if(key==17) try check(cells[0]==.null_value) else try check(cells[0].integer==key);
        try check(cells[1].integer==count and cells[3].integer==nn);
        if(nn==0) try check(cells[2]==.null_value) else try check(cells[2].integer==sum);
        expected_groups+=1;
    }
    try check(result.row_count==expected_groups);
    try paired(&db,"SELECT COUNT(*),SUM(v) FROM t WHERE g>=7 AND g<14",true);
    try paired(&db,"SELECT COUNT(*),SUM(v) FROM t WHERE 7<=g AND 14>g",true);
    try paired(&db,"SELECT COUNT(*),SUM(v) FROM t WHERE g=7 OR g=8",false);
    try paired(&db,"SELECT COUNT(*),SUM(v) FROM t WHERE id+0>=0",false);
}
fn insert(id:usize,item:Item) !void {
    var a:[32]u8=undefined;var b:[32]u8=undefined;var text:[256]u8=undefined;
    const g=if(item.g) |value| try std.fmt.bufPrint(&a,"{d}",.{value}) else "NULL";
    const v=if(item.v) |value| try std.fmt.bufPrint(&b,"{d}",.{value}) else "NULL";
    try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES ({d},{s},{s},'owned')",.{id,g,v}),&result);
}
var before_hash:u64=0;
fn cacheHash() u64 {
    const t=&db.tables[0];var h:u64=1;
    for(0..t.scan_high) |slot| {
        h=h*%1099511628211 ^ t.scan_live[slot];h=h*%1099511628211 ^ t.scan_nonnull[slot];
        for(0..4) |column| h=h*%1099511628211 ^ @as(u64,@bitCast(t.scan_values[column*t.rows.len+slot]));
    }
    return h;
}
fn rejected(_: ?*anyopaque,_:[]const u8) anyerror!void {try check(cacheHash()==before_hash);return error.InjectedFlushFailure;}
pub fn main() !void {
    try bind(&db,0);try bind(&copy,1);try bind(&producer,2);try bind(&replay,3);
    try db.execute("CREATE TABLE t(id INT PRIMARY KEY,g INT,v INT,label TEXT)",&result);
    for(0..96) |i| {
        items[i]=.{.alive=true,.g=if(i%13==0) null else @intCast(i%17),.v=if(i%7==0) null else @as(i64,@intCast(i))-47};
        try insert(i,items[i]);
    }
    try model();
    try db.execute("UPDATE t SET v=-2147483648 WHERE id=1",&result);items[1].v=-2147483648;
    try db.execute("UPDATE t SET v=2147483647 WHERE id=2",&result);items[2].v=2147483647;try model();
    // Publication can skip an earlier directory slot owned by another writer.
    const gap=try db.begin();
    try db.statement(gap,"INSERT INTO t VALUES(126,1,1,'private')",&result,.{});
    try insert(127,.{.alive=true,.g=2,.v=17});items[127]=.{.alive=true,.g=2,.v=17};
    try model();db.abort(gap);try model();
    try paired(&db,"SELECT COUNT(*),COUNT(label),SUM(v) FROM t WHERE id>=0",true);
    try paired(&db,"SELECT g,AVG(v)::TEXT FROM t WHERE id>=0 GROUP BY g ORDER BY g",true);
    const writer=try db.begin();
    try db.statement(writer,"UPDATE t SET v=101 WHERE id=1",&result,.{});
    try db.statement(writer,"SELECT COUNT(*),SUM(v) FROM t WHERE id>=0",&result,.{});
    try check(db.workspace.query.stream_stats.compact_plans==0);
    try model(); // other readers still observe the published projection
    db.abort(writer);try model();
    const saved=try db.begin();
    try db.statement(saved,"UPDATE t SET v=71 WHERE id=1",&result,.{});try db.savepoint(saved,"s");
    try db.statement(saved,"UPDATE t SET v=99 WHERE id=1",&result,.{});
    _=try db.rollbackTo(saved,"s");db.publishCommit(saved);items[1].v=71;try model();
    const twice=try db.begin();
    try db.statement(twice,"UPDATE t SET v=30 WHERE id=1",&result,.{});
    try db.statement(twice,"UPDATE t SET v=31 WHERE id=1",&result,.{});
    db.publishCommit(twice);items[1].v=31;try model();
    before_hash=cacheHash();var record:[65536]u8=undefined;var used:usize=0;
    if(db.executeChanges("UPDATE t SET v=999 WHERE id=1",&result,&record,&used,null,rejected)) |_| return error.ExpectedFlushFailure
        else |err| try check(err==error.InjectedFlushFailure);
    try check(cacheHash()==before_hash and used==0);
    const blocker=try db.begin();try db.statement(blocker,"DROP TABLE t",&result,.{});
    const reader=try db.begin();
    if(db.statement(reader,"SELECT COUNT(*),SUM(v) FROM t WHERE id>=0",&result,.{})) |_| return error.ExpectedPark
        else |err| try check(err==error.WouldBlock);
    db.txs[reader].fresh=false;db.abort(blocker);
    try db.execute("UPDATE t SET v=123 WHERE id=1",&result);
    try db.statement(reader,"SELECT COUNT(*),SUM(v) FROM t WHERE id>=0",&result,.{.@"resume"=true});
    try check(db.workspace.query.stream_stats.compact_plans==0);db.abort(reader);items[1].v=123;
    try copy.copyFromInto(&db);try paired(&copy,"SELECT g,COUNT(*),SUM(v) FROM t WHERE id>=0 GROUP BY g ORDER BY g",true);
    @memset(&buffers[4],0xa5);try larger.bindMemory(&buffers[4],256,512,8192);
    try larger.copyFromInto(&db);
    try paired(&larger,"SELECT g,COUNT(*),SUM(v) FROM t WHERE id>=0 GROUP BY g ORDER BY g",true);
    // Compact a directory whose last slot has never been published. The
    // projection must initialize that slot rather than copy uninitialized data.
    try copy.execute("DELETE FROM t WHERE id<32",&result);
    var compact_text:[128]u8=undefined;
    for(200..229) |i| try copy.execute(try std.fmt.bufPrint(&compact_text,"INSERT INTO t VALUES({d},1,1,'x')",.{i}),&result);
    try check(copy.tables[0].row_high==127 and copy.tables[0].scan_high==127);
    const pending=try copy.begin();
    try copy.statement(pending,"INSERT INTO t VALUES(500,1,1,'private')",&result,.{});
    try check(copy.tables[0].row_high==128 and copy.tables[0].scan_high==127);
    try copy.execute("INSERT INTO t VALUES(501,1,1,'x')",&result);
    try check(copy.tables[0].row_high<128);
    try paired(&copy,"SELECT COUNT(*),SUM(v) FROM t WHERE id>=0",true);
    copy.publishCommit(pending);try paired(&copy,"SELECT COUNT(*),SUM(v) FROM t WHERE id>=0",true);
    var rng:u64=1729;
    for(0..384) |step| {
        rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;
        const id:usize=@intCast(rng%128);var text:[256]u8=undefined;
        if(!items[id].alive) {
            items[id]=.{.alive=true,.g=if(rng%5==0) null else @intCast(rng%17),.v=if(rng%7==0) null else @as(i64,@intCast(rng%2000))-1000};
            try insert(id,items[id]);
        } else if(rng%3==0) {
            try db.execute(try std.fmt.bufPrint(&text,"DELETE FROM t WHERE id={d}",.{id}),&result);items[id]=.{};
        } else {
            const value=@as(i64,@intCast(rng%2000))-1000;
            try db.execute(try std.fmt.bufPrint(&text,"UPDATE t SET v={d},g={d} WHERE id={d}",.{value,rng%17,id}),&result);
            items[id].v=value;items[id].g=@intCast(rng%17);
        }
        if(step%3==0) try model();
    }
    // Reconstruct through validated change records, not a metadata copy.
    var scratch:DB.ReplayScratch=.{};
    const statements=[_] []const u8{"CREATE TABLE t(id INT PRIMARY KEY,g INT,v INT,label TEXT)","INSERT INTO t VALUES(1,2,3,'a'),(2,NULL,NULL,NULL)","UPDATE t SET v=7 WHERE id=1","DELETE FROM t WHERE id=2"};
    for(statements) |source| {
        used=0;try producer.executeChanges(source,&result,&record,&used,null,null);
        try replay.applyChangeRecord(record[0..used],&scratch);
    }
    try paired(&replay,"SELECT g,COUNT(*),SUM(v) FROM t WHERE id>=0 GROUP BY g ORDER BY g",true);
    var invalid:DB=.{};const t=&db.tables[0];
    const aliased:DB.StorageBacking=.{.rows=t.rows,.versions=t.versions,.row_index=t.row_index,.key_index=t.key_index,
        .scan_values=@as([*]i64,@ptrCast(@alignCast(t.rows.ptr)))[0..t.rows.len*4],.scan_nonnull=t.scan_nonnull,.scan_live=t.scan_live};
    if(invalid.bindStorage(.{aliased},db.workspace.query.refs)) |_| return error.AliasAccepted
        else |err| try check(err==error.InvalidParameterValue);
    try check(invalid.tables[0].rows.len==0 and invalid.tables[0].scan_values.len==0);
    var control:sql.ExecutionControl=.{.max_work=10};db.session.control=&control;
    result.row_count=37;
    if(db.execute("SELECT COUNT(*),SUM(v) FROM t WHERE id>=0",&result)) |_| return error.ExpectedLimit
        else |err| try check(err==error.QueryWorkLimit);
    try check(result.row_count==37);db.session.control=null;
    std.debug.print("{{\"suite\":\"sql-compact-scan\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
