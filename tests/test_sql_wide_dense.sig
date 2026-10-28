//! Caller-backed wide grouping versus an independent i128 model and MVCC.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.external_storage=true,.compact_integral_scans=true,.tables=1,.columns=3,
    .rows_per_table=4,.work_rows=16384,.result_rows=8192,.text_bytes=16,.tx_writes=2048});
const n=12011;const domain=5003;const base=-2501;
var db:DB=.{};var result:DB.Result=.{};var saved:DB.Result=.{};
var backing:[8388608]u8 align(64)=undefined;
var old_read:DB.ReadContext=.{};var old_refs:[65536]u32=undefined;
const Item=struct{alive:bool=true,key:?i64=null,value:?i64=null};
var items:[n]Item=undefined;
var counts:[domain+1]i64=undefined;var nonnull:[domain+1]i64=undefined;var sums:[domain+1]i128=undefined;
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("wide dense assertion {d}\n",.{assertions});return error.WideDenseContract;}}
const query="SELECT g,COUNT(*),SUM(v) FROM t GROUP BY g ORDER BY g NULLS FIRST";
fn equal() !void {
    try check(result.row_count==saved.row_count and result.column_count==saved.column_count);
    for(0..saved.row_count) |r| for(0..saved.column_count) |c| try check(DB.compareCells(&result.rows[r].cells[c],&saved.rows[r].cells[c])==0);
}
fn model(swapped:bool) !void {
    @memset(&counts,0);@memset(&nonnull,0);@memset(&sums,0);
    for(items) |item| if(item.alive) {
        const bucket:usize=if(item.key) |key| @intCast(key-base) else domain;
        counts[bucket]+=1;if(item.value) |value| {nonnull[bucket]+=1;sums[bucket]+=value;}
    };
    var row:usize=0;
    for(0..domain+1) |i| {
        const bucket=if(i==0) domain else i-1;if(counts[bucket]==0) continue;
        try check(row<result.row_count);
        const cells=&result.rows[row].cells;
        if(bucket==domain) try check(cells[0]==.null_value) else try check(cells[0].integer==@as(i64,@intCast(bucket))+base);
        try check(cells[if(swapped) 2 else 1].integer==counts[bucket]);
        const sum=&cells[if(swapped) 1 else 2];
        if(nonnull[bucket]==0) try check(sum.*==.null_value) else {
            const expected=sums[bucket];const magnitude:u128=@intCast(if(expected<0) -expected else expected);
            try check(sum.*==.numeric and sum.numeric.coef()==magnitude and sum.numeric.negative==(expected<0) and sum.numeric.dscale==0);
        }
        row+=1;
    }
    try check(row==result.row_count);
}
fn paired(expected_path:bool) !void {
    try db.execute(query,&result);try model(false);
    try check(db.workspace.query.stream_stats.wide_dense_plans==@intFromBool(expected_path));
    saved=result;
    const valid=db.tables[0].summary.valid;db.tables[0].summary.valid=false;
    defer db.tables[0].summary.valid=valid;
    try db.execute(query,&result);try check(db.workspace.query.stream_stats.wide_dense_plans==0);try equal();
}
pub fn main() !void {
    @memset(&backing,0xa5);try db.bindMemory(&backing,n+4,(n+4)*2,65536);
    try db.execute("CREATE TABLE t(id INT PRIMARY KEY,g BIGINT,v BIGINT)",&result);
    var text:[256]u8=undefined;var key_buffer:[32]u8=undefined;var value_buffer:[32]u8=undefined;
    for(0..n) |i| {
        const value:i64=if(i%3==0) 9223372036854775807 else if(i%3==1) -9223372036854775808 else @as(i64,@intCast(i))-6000;
        items[i]=.{.key=if(i%17==0) null else @as(i64,@intCast(i%domain))+base,.value=if(i%13==0) null else value};
        const key=if(items[i].key) |v| try std.fmt.bufPrint(&key_buffer,"{d}",.{v}) else "NULL";
        const input=if(items[i].value) |v| try std.fmt.bufPrint(&value_buffer,"{d}",.{v}) else "NULL";
        try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES({d},{s},{s})",.{i,key,input}),&result);
    }
    try paired(true);
    try db.execute("SELECT g,SUM(v),COUNT(*) FROM t GROUP BY g ORDER BY g NULLS FIRST",&result);try model(true);
    try check(db.workspace.query.stream_stats.wide_dense_plans==1);
    // AVG uses the same exact wide total and non-null count, then the existing
    // numeric finalizer. Compare full decimal values to canonical evaluation.
    const average="SELECT g,COUNT(*),AVG(v) FROM t GROUP BY g ORDER BY g NULLS FIRST";
    try db.execute(average,&result);saved=result;try check(db.workspace.query.stream_stats.wide_dense_plans==1);
    db.tables[0].summary.valid=false;try db.execute(average,&result);db.tables[0].summary.valid=true;try equal();
    try db.execute(query,&result);saved=result;
    const reader=try db.begin();const snapshot:DB.Snapshot=.{.csn=db.csn};db.txs[reader].pin=snapshot;
    try db.execute("UPDATE t SET v=77 WHERE id=1",&result);items[1].value=77;
    try db.execute("DELETE FROM t WHERE id=2",&result);items[2].alive=false;
    old_read.workspace.query.refs=&old_refs;try old_read.execute(&db,query,snapshot,&result);try equal();
    try check(old_read.workspace.query.stream_stats.wide_dense_plans==0);
    try paired(true);db.abort(reader);try paired(true);
    const writer=try db.begin();try db.statement(writer,"UPDATE t SET v=123 WHERE id=3",&result,.{});
    const previous=items[3].value;items[3].value=123;
    try db.statement(writer,query,&result,.{});try model(false);try check(db.workspace.query.stream_stats.wide_dense_plans==0);
    db.abort(writer);items[3].value=previous;try paired(true);
    saved=result;var control:sql.ExecutionControl=.{.max_work=10};db.session.control=&control;
    if(db.execute(query,&result)) |_| return error.ExpectedWorkLimit else |err| try check(err==error.QueryWorkLimit);
    db.session.control=null;try equal();try paired(true);
    // Exercise both metadata-proven non-null loops on the large domain too.
    try db.execute("UPDATE t SET v=0 WHERE v IS NULL",&result);
    for(&items) |*item| if(item.alive and item.value==null) {item.value=0;};
    try paired(true);
    try db.execute("UPDATE t SET g=0 WHERE g IS NULL",&result);
    for(&items) |*item| if(item.alive and item.key==null) {item.key=0;};
    try paired(true);
    // Conservative bounds widened by an aborted write force safe fallback.
    const widened=try db.begin();try db.statement(widened,"UPDATE t SET g=9223372036854775807 WHERE id=3",&result,.{});db.abort(widened);
    try paired(false);
    for([_][]const u8{"9223372036854775807","-9223372036854775808"}) |key| {
        try db.execute("DROP TABLE t",&result);try db.execute("CREATE TABLE t(id INT PRIMARY KEY,g BIGINT,v BIGINT)",&result);
        try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO t VALUES(1,{s},9223372036854775807),(2,{s},9223372036854775807)",.{key,key}),&result);
        try db.execute(query,&result);try check(db.workspace.query.stream_stats.wide_dense_plans==1);
        try check(result.row_count==1 and result.rows[0].cells[1].integer==2);
        try check(result.rows[0].cells[2].numeric.coef()==@as(i128,9223372036854775807)*2);
        try db.execute("DELETE FROM t",&result);try db.execute(query,&result);try check(result.row_count==0);
    }
    std.debug.print("PASS wide dense: {d} assertions, 5003-key domain, exact wide sums/averages, NULLs, snapshots, aborts, cancellation and extreme keys\n",.{assertions});
}
