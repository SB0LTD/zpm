//! Typed producer/consumer aggregation must preserve the canonical SQL result.
const std=@import("std");
const sql=@import("sql");
fn config(comptime enabled:bool) sql.Config {return .{.external_storage=true,.tables=3,.columns=12,.rows_per_table=2,.text_bytes=16,.name_bytes=16,.integer_bits=32,.work_rows=512,.result_rows=32,.tx_writes=1024,.compact_integral_scans=true,.factorized_aggregates=enabled,.nulls_first_ascending=false};}
const Fast=sql.Database(config(true));const Slow=sql.Database(config(false));
var fast:Fast=.{};var slow:Slow=.{};var fr:Fast.Result=.{};var sr:Slow.Result=.{};
var memory:[3][4194304]u8 align(64)=undefined;var assertions:usize=0;
var twin:Fast=.{};var tr:Fast.Result=.{};var reader:Fast.ReadContext=.{};var old_refs:[8192]u32=undefined;
var constrained:Fast.ReadContext=.{};var short_refs:[256]u32=undefined;
fn check(ok:bool) !void {assertions+=1;if(!ok) {std.debug.print("nested assertion {d}\n",.{assertions});return error.NestedFactorContract;}}
fn same() !void {
    try check(fr.row_count==sr.row_count and fr.column_count==sr.column_count);
    for(fr.rows[0..fr.row_count],sr.rows[0..sr.row_count]) |a,b| for(0..fr.column_count) |column| {
        const x=a.cells[column];const y=b.cells[column];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x) {
            .null_value=>{},.integer=>|v| try check(v==y.integer),.text=>|v| try check(std.mem.eql(u8,v.slice(),y.text.slice())),
            .numeric=>|v| try check(v.coef()==y.numeric.coef() and v.dscale==y.numeric.dscale and v.negative==y.numeric.negative and v.special==y.numeric.special),
            else=>return error.UnexpectedValue,
        }
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("fast {s}: {s}\n",.{@errorName(err),source});return err;};
    slow.execute(source,&sr) catch |err| {std.debug.print("slow {s}: {s}\n",.{@errorName(err),source});return err;};try same();
}
fn reject(source:[]const u8,wanted:sql.Error) !void {
    const before=fr;
    if(fast.execute(source,&fr)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(fr.row_count==before.row_count and fr.column_count==before.column_count);
    for(fr.rows[0..fr.row_count],before.rows[0..before.row_count]) |a,b| for(0..fr.column_count) |column| try check(Fast.compareCells(&a.cells[column],&b.cells[column])==0);
}
const producer="WITH totals AS (SELECT k,COUNT(*) AS n,SUM(v) AS total FROM facts GROUP BY k) ";
const query=producer++"SELECT d.label,COUNT(*),SUM(t.n),SUM(t.total),MIN(t.total),MAX(t.total) FROM totals t JOIN dimensions d ON d.id=t.k WHERE t.total>={d} GROUP BY d.label ORDER BY d.label";
fn model(threshold:i64) !void {
    var counts:[19]i64=@splat(0);var totals:[19]i64=@splat(0);
    for(0..257) |i| {if(i%23==0) continue;counts[i%19]+=1;totals[i%19]+=@as(i64,@intCast(i%31))-15;}
    var row:usize=0;
    for(0..3) |g| {
        var customers:i64=0;var count:i64=0;var total:i64=0;var low:i64=std.math.maxInt(i64);var high:i64=std.math.minInt(i64);
        for(0..17) |k| if(k%3==g and totals[k]>=threshold) {customers+=1;count+=counts[k];total+=totals[k];low=@min(low,totals[k]);high=@max(high,totals[k]);};
        if(customers==0) continue;
        const cells=fr.rows[row].cells;row+=1;try check(cells[1].integer==customers);
        for([_]i64{count,total,low,high},2..) |v,c| {
            const x=cells[c];try check(x==.numeric and x.numeric.dscale==0 and x.numeric.negative==(v<0) and x.numeric.coef()==@as(u64,@intCast(if(v<0) -v else v)));
        }
    }
    try check(fr.row_count==row);
}
const Cancel=struct {fn poll(_: ?*anyopaque) sql.Error!void {if(fast.workspace.query.stream_stats.nested_factor_keys>0) return error.QueryCanceled;}};
fn failFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {return error.InjectedFlushFailure;}
pub fn main() !void {
    @memset(std.mem.asBytes(&memory),0xa5);try fast.bindMemory(&memory[0],300,600,8192);try slow.bindMemory(&memory[1],300,600,8192);
    try execute("CREATE TABLE facts(id INT PRIMARY KEY,k INT,v BIGINT)");try execute("CREATE TABLE dimensions(id INT PRIMARY KEY,label TEXT)");var text:[2048]u8=undefined;
    for(0..17) |i| try execute(try std.fmt.bufPrint(&text,"INSERT INTO dimensions VALUES({d},'{s}')",.{i,([_][]const u8{"a","b","c"})[i%3]}));
    for(0..257) |i| {
        var key:[16]u8=undefined;const k=if(i%23==0) "NULL" else try std.fmt.bufPrint(&key,"{d}",.{i%19});
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},{s},{d})",.{i,k,@as(i64,@intCast(i%31))-15}));
    }
    for([_]i64{-100,-1,0,1,10,100}) |threshold| {try execute(try std.fmt.bufPrint(&text,query,.{threshold}));try model(threshold);try check(fast.workspace.query.stream_stats.nested_factor_plans==1);}
    try execute(producer++"SELECT d.label,COUNT(t.total),AVG(t.total),MIN(t.n),MAX(t.k),SUM(t.k) FROM totals t JOIN dimensions d ON d.id=t.k WHERE 0<=t.total AND t.n>1 GROUP BY d.label HAVING COUNT(*)>1 ORDER BY d.label");
    try check(fast.workspace.query.stream_stats.nested_factor_plans==1);
    try execute("SELECT d.label,COUNT(*),SUM(t.total) FROM (SELECT k,SUM(v) AS total,COUNT(*) AS n FROM facts GROUP BY k) t JOIN dimensions d ON d.id=t.k GROUP BY d.label ORDER BY d.label");
    try check(fast.workspace.query.stream_stats.nested_factor_plans==1);
    try execute(producer++"SELECT d.label,COUNT(*),SUM(t.n),MAX(t.total),ROUND(AVG(t.total),2) FROM totals t JOIN dimensions d ON d.id=t.k WHERE t.total>0 GROUP BY d.label ORDER BY d.label");try check(fast.workspace.query.stream_stats.nested_factor_plans==1);
    // Computed predicates, producers with HAVING, and duplicate consumers retain
    // ordinary execution, including expression errors and SQL bag multiplicity.
    try execute(producer++"SELECT d.label,SUM(t.total) FROM totals t JOIN dimensions d ON d.id=t.k WHERE t.total+1>0 GROUP BY d.label ORDER BY d.label");try check(fast.workspace.query.stream_stats.nested_factor_plans==0);
    try execute("WITH totals AS (SELECT k,COUNT(*) AS n,SUM(v) AS total FROM facts GROUP BY k HAVING COUNT(*)>1) SELECT d.label,SUM(t.total) FROM totals t JOIN dimensions d ON d.id=t.k GROUP BY d.label ORDER BY d.label");try check(fast.workspace.query.stream_stats.nested_factor_plans==0);
    try execute(producer++"SELECT d.label,SUM(t.total),COUNT(*) FROM totals t JOIN dimensions d ON d.id=t.k JOIN totals u ON u.k=t.k GROUP BY d.label ORDER BY d.label");try check(fast.workspace.query.stream_stats.nested_factor_plans==0);
    try reject(producer++"SELECT d.label,SUM(t.total) FROM totals t JOIN dimensions d ON d.id=t.k WHERE 1/(t.n-t.n)=0 GROUP BY d.label",error.DivisionByZero);
    const q=try std.fmt.bufPrint(&text,query,.{-100});
    const ft=try fast.begin();const st=try slow.begin();
    try fast.statement(ft,"UPDATE facts SET v=777 WHERE id=4",&fr,.{});try slow.statement(st,"UPDATE facts SET v=777 WHERE id=4",&sr,.{});
    try fast.statement(ft,q,&fr,.{});try slow.statement(st,q,&sr,.{});try same();try check(fast.workspace.query.stream_stats.nested_factor_plans==0);fast.abort(ft);slow.abort(st);
    const pin=try fast.begin();const snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pin].pin=snapshot;
    try fast.execute("UPDATE facts SET v=42 WHERE id=4",&fr);reader.workspace.query.refs=&old_refs;
    try reader.execute(&fast,q,snapshot,&fr);try slow.execute(q,&sr);try same();try model(-100);try check(reader.workspace.query.stream_stats.nested_factor_plans==0);fast.abort(pin);
    try slow.execute("UPDATE facts SET v=42 WHERE id=4",&sr);try execute(q);
    const dim_pin=try fast.begin();const dim_snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[dim_pin].pin=dim_snapshot;
    try fast.execute("UPDATE dimensions SET id=40 WHERE id=1",&fr);
    try reader.execute(&fast,q,dim_snapshot,&fr);try slow.execute(q,&sr);try same();try check(reader.workspace.query.stream_stats.nested_factor_plans==1);fast.abort(dim_pin);
    try slow.execute("UPDATE dimensions SET id=40 WHERE id=1",&sr);try execute(q);
    var record:[65536]u8=undefined;var used:usize=0;
    if(fast.executeChanges("UPDATE facts SET v=999 WHERE id=7",&fr,&record,&used,null,failFlush)) |_| return error.ExpectedFlushFailure else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0);try execute(q);try twin.bindMemory(&memory[2],300,600,8192);try twin.copyFromInto(&fast);
    try fast.executeChanges("UPDATE facts SET v=500 WHERE id=9",&fr,&record,&used,null,null);try slow.execute("UPDATE facts SET v=500 WHERE id=9",&sr);
    var replay:Fast.ReplayScratch=.{};try twin.applyChangeRecord(record[0..used],&replay);try execute(q);try twin.execute(q,&tr);
    try check(fr.row_count==tr.row_count and fr.column_count==tr.column_count);
    for(fr.rows[0..fr.row_count],tr.rows[0..tr.row_count]) |a,b| for(0..fr.column_count) |c| try check(Fast.compareCells(&a.cells[c],&b.cells[c])==0);
    @memset(&fast.workspace.query.cells,.{.integer=0x55555555});try execute(q);try check(fast.workspace.query.stream_stats.nested_factor_plans==1);
    constrained.workspace.query.refs=&short_refs;try constrained.execute(&fast,q,.{.csn=fast.csn},&fr);try slow.execute(q,&sr);try same();try check(constrained.workspace.query.stream_stats.nested_factor_plans==0);
    var limited:sql.ExecutionControl=.{.max_work=100};fast.session.control=&limited;try reject(q,error.QueryWorkLimit);fast.session.control=null;
    try execute("SELECT 9");const before=fr;var control:sql.ExecutionControl=.{.poll=Cancel.poll,.poll_interval=1};
    fast.workspace.query.stream_stats=.{};fast.session.control=&control;
    try reject(producer++"SELECT d.label,SUM(t.total) FROM totals t JOIN dimensions d ON d.id=t.k GROUP BY d.label",error.QueryCanceled);fast.session.control=null;
    try check(fr.row_count==before.row_count and fr.rows[0].cells[0].integer==9);
    // A nullable SUM cannot silently become a zero total in the fused path.
    try execute("UPDATE facts SET v=NULL WHERE k=1");try execute(try std.fmt.bufPrint(&text,query,.{-100}));try check(fast.workspace.query.stream_stats.nested_factor_plans==0);
    try execute("UPDATE facts SET v=0");try execute("UPDATE facts SET v=-9223372036854775808 WHERE id=1 OR id=20");
    try execute(producer++"SELECT d.label,COUNT(*),SUM(t.total),MIN(t.total) FROM totals t JOIN dimensions d ON d.id=t.k GROUP BY d.label ORDER BY d.label");try check(fast.workspace.query.stream_stats.nested_factor_plans==0);
    try execute("DELETE FROM facts");try execute(producer++"SELECT d.label,COUNT(*),SUM(t.total) FROM totals t JOIN dimensions d ON d.id=t.k GROUP BY d.label");try check(fr.row_count==0);
    std.debug.print("PASS SQL nested factor: {d} assertions, canonical and scalar equivalence, fallback and failure atomicity\n",.{assertions});
}
