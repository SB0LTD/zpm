//! Actual SQL, scalar grouping oracle and canonical executor. No timings.
const std=@import("std");const sql=@import("sql");
fn config(comptime typed:bool) sql.Config {return .{.external_storage=true,.tables=1,.columns=8,.rows_per_table=2,
    .work_rows=256,.result_rows=32,.tx_writes=1024,.text_bytes=32,.integer_bits=32,
    .compact_integral_scans=true,.typed_grouped_aggregates=typed,.nulls_first_ascending=false};}
const Fast=sql.Database(config(true));const Slow=sql.Database(config(false));
var fast:Fast=.{};var slow:Slow=.{};var copy:Fast=.{};
var fr:Fast.Result=.{};var sr:Slow.Result=.{};var cr:Fast.Result=.{};
var memory:[3][4194304]u8 align(64)=undefined;var refs:[8192]u32=undefined;
var short_refs:[128]u32=undefined;
const Small=sql.Database(blk:{var c=config(true);c.numeric_digits=8;break :blk c;});
var small:Small=.{};var small_result:Small.Result=.{};var small_memory:[524288]u8 align(64)=undefined;
var assertions:usize=0;const n=257;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("typed multi assertion {d}\n",.{assertions});return error.TypedMultiContract;}}
fn same() !void {
    try check(fr.row_count==sr.row_count and fr.column_count==sr.column_count);
    for(fr.rows[0..fr.row_count],sr.rows[0..sr.row_count]) |a,b| for(0..fr.column_count) |i| {
        const x=a.cells[i];const y=b.cells[i];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x){.null_value=>{},.integer=>|v|try check(v==y.integer),.text=>|v|try check(std.mem.eql(u8,v.slice(),y.text.slice())),
            .numeric=>|v|try check(v.coef()==y.numeric.coef() and v.dscale==y.numeric.dscale and v.negative==y.numeric.negative and v.special==y.numeric.special),else=>return error.UnexpectedCell}
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("fast {s}: {s}\n",.{@errorName(err),source});return err;};
    try slow.execute(source,&sr);try same();
}
fn reject(source:[]const u8,wanted:sql.Error) !void {
    const before=fr;
    if(fast.execute(source,&fr)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(fr.row_count==before.row_count and fr.column_count==before.column_count);
    for(fr.rows[0..fr.row_count],before.rows[0..before.row_count]) |a,b| for(0..fr.column_count) |i| try check(Fast.compareCells(&a.cells[i],&b.cells[i])==0);
}
const query="SELECT k,COUNT(*),COUNT(c),SUM(b),CAST(SUM(a) AS TEXT),CAST(SUM(c) AS TEXT),COUNT(label) FROM fact GROUP BY k ORDER BY k NULLS FIRST";
fn aValue(i:usize) i64 {return if(i==1) -9223372036854775808 else if(i==12) 9223372036854775807 else @as(i64,@intCast(i))*@as(i64,@intCast(i))*(if(i%3==0) @as(i64,-1) else 1);}
fn model() !void {
    var rows:[12]i64=@splat(0);var nc:[12]i64=@splat(0);var nl:[12]i64=@splat(0);var na:[12]i64=@splat(0);
    var a:[12]i128=@splat(0);var b:[12]i128=@splat(0);var c:[12]i128=@splat(0);
    for(0..n) |i| {
        const key=if(i%17==0) 11 else i%11;rows[key]+=1;
        b[key]+=@as(i64,@intCast(i%31))-15;
        if(i%13!=0){a[key]+=aValue(i);na[key]+=1;}
        if(i%5!=0){c[key]+=@as(i64,@intCast(i*3))-300;nc[key]+=1;}
        if(i%7!=0) nl[key]+=1;
    }
    try check(fr.row_count==12);var text:[128]u8=undefined;
    for(0..12) |index| {
        const key=if(index==0) 11 else index-1;const cells=fr.rows[index].cells;
        if(key==11) try check(cells[0]==.null_value) else try check(cells[0].integer==@as(i64,@intCast(key))-5);
        try check(cells[1].integer==rows[key] and cells[2].integer==nc[key] and cells[3].integer==b[key] and cells[6].integer==nl[key]);
        if(na[key]==0) try check(cells[4]==.null_value) else try check(std.mem.eql(u8,cells[4].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{a[key]})));
        if(nc[key]==0) try check(cells[5]==.null_value) else try check(std.mem.eql(u8,cells[5].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{c[key]})));
    }
}
fn failFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {return error.InjectedFlushFailure;}
const Cancel=struct {
    calls:usize=0,
    fn poll(raw:?*anyopaque) sql.Error!void {const self:*Cancel=@ptrCast(@alignCast(raw.?));self.calls+=1;if(fast.workspace.query.stream_stats.rows>=64) return error.QueryCanceled;}
};
pub fn main() !void {
    @memset(std.mem.asBytes(&memory),0xa5);
    try fast.bindMemory(&memory[0],n+16,(n+16)*2,8192);try slow.bindMemory(&memory[1],n+16,(n+16)*2,8192);
    try execute("CREATE TABLE fact(id INT PRIMARY KEY,k BIGINT,a BIGINT,b INT,c BIGINT,label TEXT)");
    var text:[512]u8=undefined;
    for(0..n) |i| {
        var k:[24]u8=undefined;var a:[32]u8=undefined;var c:[24]u8=undefined;
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO fact VALUES({d},{s},{s},{d},{s},{s})",.{i,
            if(i%17==0) "NULL" else try std.fmt.bufPrint(&k,"{d}",.{@as(i64,@intCast(i%11))-5}),
            if(i%13==0) "NULL" else try std.fmt.bufPrint(&a,"{d}",.{aValue(i)}),@as(i64,@intCast(i%31))-15,
            if(i%5==0) "NULL" else try std.fmt.bufPrint(&c,"{d}",.{@as(i64,@intCast(i*3))-300}),if(i%7==0) "NULL" else "'x'"}));
    }
    try execute(query);try model();try check(fast.workspace.query.stream_stats.typed_group_plans==1 and fast.workspace.query.stream_stats.typed_group_channels==6);
    try check(fast.workspace.query.stream_stats.gathered_rows==0 and fast.workspace.query.stream_stats.rows==n);
    try execute("SELECT k,SUM(a),SUM(b),AVG(c),COUNT(label) FROM fact GROUP BY k HAVING COUNT(*)>4 ORDER BY k DESC NULLS LAST LIMIT 8 OFFSET 1");
    try check(fast.workspace.query.stream_stats.typed_group_plans==1);
    try execute("WITH totals AS (SELECT k,SUM(b) AS units,SUM(a) AS revenue FROM fact GROUP BY k) SELECT k,units,revenue FROM totals ORDER BY revenue DESC,k LIMIT 3");
    try check(fast.workspace.query.stream_stats.typed_group_plans==1);
    try execute("SELECT k,SUM(a),SUM(c) FROM fact WHERE id<100 GROUP BY k ORDER BY k");try check(fast.workspace.query.stream_stats.typed_group_plans==0);
    try execute("SELECT k,SUM(DISTINCT a),SUM(c) FROM fact GROUP BY k ORDER BY k");try check(fast.workspace.query.stream_stats.typed_group_plans==0);
    try execute("SELECT k,SUM(a+0),SUM(c) FROM fact GROUP BY k ORDER BY k");try check(fast.workspace.query.stream_stats.typed_group_plans==0);
    try reject("SELECT k,SUM(a+1),SUM(c) FROM fact GROUP BY k ORDER BY k",error.IntegerOverflow);
    try reject("SELECT k,SUM(a),SUM(c) FROM fact GROUP BY k HAVING 1/(COUNT(*)-COUNT(*))>0",error.DivisionByZero);
    try execute(query);
    const ft=try fast.begin();const st=try slow.begin();
    try fast.statement(ft,"UPDATE fact SET b=99 WHERE id=4",&fr,.{});try slow.statement(st,"UPDATE fact SET b=99 WHERE id=4",&sr,.{});
    try fast.statement(ft,query,&fr,.{});try slow.statement(st,query,&sr,.{});try same();try check(fast.workspace.query.stream_stats.typed_group_plans==0);
    fast.abort(ft);slow.abort(st);try execute(query);try model();
    try execute("INSERT INTO fact VALUES(300,99,NULL,NULL,NULL,NULL)");try execute(query);
    try check(fast.workspace.query.stream_stats.typed_group_plans==1);
    const all_null=fr.rows[fr.row_count-1].cells;
    try check(all_null[0].integer==99 and all_null[1].integer==1 and all_null[2].integer==0 and all_null[6].integer==0);
    try check(all_null[3]==.null_value and all_null[4]==.null_value and all_null[5]==.null_value);
    var constrained:Fast.ReadContext=.{};constrained.workspace.query.refs=&short_refs;
    try constrained.execute(&fast,query,.{.csn=fast.csn},&fr);try slow.execute(query,&sr);try same();
    try check(constrained.workspace.query.stream_stats.typed_group_plans==0);
    const pin=try fast.begin();const snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pin].pin=snapshot;
    try fast.execute("UPDATE fact SET b=101 WHERE id=5",&fr);
    var reader:Fast.ReadContext=.{};reader.workspace.query.refs=&refs;
    try reader.execute(&fast,query,snapshot,&fr);try slow.execute(query,&sr);try same();try check(reader.workspace.query.stream_stats.typed_group_plans==0);fast.abort(pin);
    try slow.execute("UPDATE fact SET b=101 WHERE id=5",&sr);try execute(query);
    var record:[65536]u8=undefined;var used:usize=0;
    if(fast.executeChanges("UPDATE fact SET b=999 WHERE id=7",&fr,&record,&used,null,failFlush)) |_| return error.ExpectedFlushFailure else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0);try execute(query);
    try copy.bindMemory(&memory[2],n+16,(n+16)*2,8192);try copy.copyFromInto(&fast);try copy.execute(query,&cr);
    try check(cr.row_count==fr.row_count and copy.workspace.query.stream_stats.typed_group_plans==1);
    for(cr.rows[0..cr.row_count],fr.rows[0..fr.row_count]) |x,y| for(0..fr.column_count) |i| try check(Fast.compareCells(&x.cells[i],&y.cells[i])==0);
    used=0;try fast.executeChanges("UPDATE fact SET a=2020,c=NULL WHERE id=100",&fr,&record,&used,null,null);try slow.execute("UPDATE fact SET a=2020,c=NULL WHERE id=100",&sr);
    var replay:Fast.ReplayScratch=.{};try copy.applyChangeRecord(record[0..used],&replay);try execute(query);try copy.execute(query,&cr);
    for(cr.rows[0..cr.row_count],fr.rows[0..fr.row_count]) |x,y| for(0..fr.column_count) |i| try check(Fast.compareCells(&x.cells[i],&y.cells[i])==0);
    var control:sql.ExecutionControl=.{.max_work=100};fast.session.control=&control;try reject(query,error.QueryWorkLimit);fast.session.control=null;
    var cancel:Cancel=.{};control=.{.context=&cancel,.poll=Cancel.poll,.poll_interval=1};fast.workspace.query.stream_stats=.{};fast.session.control=&control;
    try reject(query,error.QueryCanceled);fast.session.control=null;try check(cancel.calls>0 and fast.workspace.query.stream_stats.rows>=64);
    @memset(&fast.workspace.query.cells,.{.integer=0x55555555});try execute(query);
    try execute("INSERT INTO fact VALUES(301,999999999999,1,2,3,'z')");try execute(query);try check(fast.workspace.query.stream_stats.typed_group_plans==0);
    try execute("DELETE FROM fact WHERE id=301");try execute(query);
    for([_][]const u8{"9223372036854775807","-9223372036854775808"}) |key| {
        try execute("DROP TABLE fact");try execute("CREATE TABLE fact(id INT PRIMARY KEY,k BIGINT,a BIGINT,b INT,c BIGINT,label TEXT)");
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO fact VALUES(1,{s},9223372036854775807,1,NULL,NULL),(2,{s},9223372036854775807,1,NULL,NULL)",.{key,key}));
        try execute(query);try check(fast.workspace.query.stream_stats.typed_group_plans==1);
        try check(fr.row_count==1 and std.mem.eql(u8,fr.rows[0].cells[4].text.slice(),"18446744073709551614"));
        try execute("DELETE FROM fact");try execute(query);try check(fr.row_count==0);
    }
    try small.bindMemory(&small_memory,2,4,128);
    try small.execute("CREATE TABLE fact(id INT PRIMARY KEY,k BIGINT,a BIGINT,b INT,c BIGINT,label TEXT)",&small_result);
    try small.execute("INSERT INTO fact VALUES(1,0,10,20,30,'x'),(2,0,11,21,31,NULL)",&small_result);
    try small.execute(query,&small_result);
    try check(small.workspace.query.stream_stats.typed_group_plans==0 and small_result.row_count==1);
    try check(small_result.rows[0].cells[1].integer==2 and small_result.rows[0].cells[3].integer==41);
    std.debug.print("PASS SQL typed multi-group: {d} assertions, scalar/canonical results, snapshots and failure atomicity\n",.{assertions});
}
