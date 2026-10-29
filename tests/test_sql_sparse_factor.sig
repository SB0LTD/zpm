//! Sparse survivor evaluation versus the vector factor kernel and a row model.
const std=@import("std");const sql=@import("sql");
fn config(comptime sparse:bool) sql.Config {return .{.external_storage=true,.compact_integral_scans=true,.factorized_aggregates=true,.block_presence_filters=true,.sparse_factor_predicates=sparse,
    .tables=2,.columns=6,.rows_per_table=2,.work_rows=128,.result_rows=16,.tx_writes=2048,.text_bytes=16,.name_bytes=16,.integer_bits=32};}
const Fast=sql.Database(config(true));const Vector=sql.Database(config(false));
var fast:Fast=.{};var vector:Vector=.{};var fr:Fast.Result=.{};var vr:Vector.Result=.{};var memory:[2][4194304]u8 align(64)=undefined;
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("sparse assertion {d}\n",.{assertions});return error.SparseFactorContract;}}
fn equal() !void {
    try check(fr.row_count==vr.row_count and fr.column_count==vr.column_count);
    for(fr.rows[0..fr.row_count],vr.rows[0..vr.row_count]) |a,b| for(0..fr.column_count) |c| {
        const x=a.cells[c];const y=b.cells[c];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x){.null_value=>{},.integer=>|v|try check(v==y.integer),.numeric=>|v|try check(std.meta.eql(v,y.numeric)),else=>return error.UnexpectedValue}
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("sparse fast {s}: {s}\n",.{@errorName(err),source});return err;};
    vector.execute(source,&vr) catch |err| {std.debug.print("sparse vector {s}: {s}\n",.{@errorName(err),source});return err;};try equal();
}
const n=1025;
fn passes(value:i64,op:[]const u8) bool {
    if(std.mem.eql(u8,op,"=")) return value==0;if(std.mem.eql(u8,op,"<>")) return value!=0;
    if(std.mem.eql(u8,op,"<")) return value<0;if(std.mem.eql(u8,op,"<=")) return value<=0;
    if(std.mem.eql(u8,op,">")) return value>0;return value>=0;
}
fn model(key:usize,op:[]const u8) !void {
    var counts:[7]i64=@splat(0);var sums:[7]i64=@splat(0);var amount:[7]i64=@splat(0);var nonnull:[7]i64=@splat(0);
    for(0..n) |i| {
        const v=@as(i64,@intCast(i%11))-5;
        if(i%19==0 or i%257!=key or i%17==0 or i%12<2 or i%12>7 or i%13==0 or !passes(v,op)) continue;
        const g=i%7;counts[g]+=1;sums[g]+=v;if(i%23!=0) {amount[g]+=@as(i64,@intCast(i))-300;nonnull[g]+=1;}
    }
    var row:usize=0;for(0..7) |g| {
        if(counts[g]==0) continue;const c=fr.rows[row].cells;row+=1;
        try check(c[0].integer==g and c[1].integer==counts[g] and c[2].integer==counts[g] and c[3].integer==sums[g]);
        if(nonnull[g]==0) try check(c[4]==.null_value and c[5]==.null_value) else {
            const total=amount[g];try check(c[4]==.numeric and c[4].numeric.dscale==0 and c[4].numeric.negative==(total<0) and c[4].numeric.coef()==@as(u64,@intCast(if(total<0) -total else total)) and c[5]==.numeric);
        }
    }try check(row==fr.row_count);
}
pub fn main() !void {
    @memset(std.mem.asBytes(&memory),0xa5);try fast.bindMemory(&memory[0],1100,2200,8192);try vector.bindMemory(&memory[1],1100,2200,8192);
    try execute("CREATE TABLE facts(id INT PRIMARY KEY,k INT,g INT,v INT,a BIGINT,d DATE)");try execute("CREATE TABLE dims(id INT PRIMARY KEY)");try execute("INSERT INTO dims VALUES(0),(1),(2),(3),(4),(5),(6)");
    var text:[1024]u8=undefined;
    for(0..n) |i| {
        var kb:[32]u8=undefined;var vb:[32]u8=undefined;var ab:[32]u8=undefined;var db:[32]u8=undefined;
        const k=if(i%19==0) "NULL" else try std.fmt.bufPrint(&kb,"{d}",.{i%257});
        const v=if(i%13==0) "NULL" else try std.fmt.bufPrint(&vb,"{d}",.{@as(i64,@intCast(i%11))-5});
        const a=if(i%23==0) "NULL" else try std.fmt.bufPrint(&ab,"{d}",.{@as(i64,@intCast(i))-300});
        const d=if(i%17==0) "NULL" else try std.fmt.bufPrint(&db,"DATE '2025-{d:0>2}-15'",.{i%12+1});
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},{s},{d},{s},{s},{s})",.{i,k,i%7,v,a,d}));
    }
    var seen:usize=0;
    for([_]usize{0,1,17,128,200,256}) |key| for([_][]const u8{"=","<>","<","<=",">",">="}) |op| {
        const source=try std.fmt.bufPrint(&text,"SELECT d.id,COUNT(*),COUNT(f.v),SUM(f.v),SUM(f.a),AVG(f.a) FROM facts f JOIN dims d ON d.id=f.g WHERE f.k={d} AND DATE '2025-03-01'<=f.d AND f.d<=DATE '2025-08-31' AND f.v{s}0 GROUP BY d.id ORDER BY d.id",.{key,op});
        var fc:sql.ExecutionControl=.{};var vc:sql.ExecutionControl=.{};fast.session.control=&fc;vector.session.control=&vc;
        try execute(source);fast.session.control=null;vector.session.control=null;try model(key,op);
        try check(fc.used==vc.used and fast.workspace.query.stream_stats.factor_plans==1 and vector.workspace.query.stream_stats.factor_plans==1 and vector.workspace.query.stream_stats.sparse_factor_masks==0);
        seen+=fast.workspace.query.stream_stats.sparse_factor_masks;try check(fast.workspace.query.stream_stats.sparse_factor_rows<=64);
    };
    try check(seen>0);
    try execute("UPDATE facts SET a=-9223372036854775808 WHERE id=1");try execute("UPDATE facts SET a=9223372036854775807 WHERE id=258");
    try execute("SELECT d.id,COUNT(*),SUM(f.a) FROM facts f JOIN dims d ON d.id=f.g WHERE f.k=1 AND f.d>=DATE '2025-01-01' AND f.a>=0 GROUP BY d.id ORDER BY d.id");
    try check(fr.row_count==3 and fast.workspace.query.stream_stats.factor_plans==1 and fast.workspace.query.stream_stats.sparse_factor_masks>0);
    // Computed/throwing predicates retain canonical evaluation and atomicity.
    try execute("SELECT 9");const before=fr;
    const bad="SELECT d.id,COUNT(*) FROM facts f JOIN dims d ON d.id=f.g WHERE f.k=1 AND 1/(f.v-f.v)=0 GROUP BY d.id";
    if(fast.execute(bad,&fr)) |_| return error.ExpectedDivisionByZero else |err| try check(err==error.DivisionByZero);
    if(vector.execute(bad,&vr)) |_| return error.ExpectedDivisionByZero else |err| try check(err==error.DivisionByZero);
    try check(fr.row_count==before.row_count and fr.rows[0].cells[0].integer==9);
    std.debug.print("PASS SQL sparse factor predicates: {d} assertions, scalar/vector equivalence, nullable DATE/measure masks, all comparisons and identical work totals\n",.{assertions});
}
