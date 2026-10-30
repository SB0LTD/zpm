//! Typed DISTINCT after unique dimension chains; independent scalar model.
const std=@import("std");const sql=@import("sql");
fn config(comptime distinct:bool) sql.Config {return .{.external_storage=true,.tables=3,.columns=8,.rows_per_table=2,
    .text_bytes=32,.name_bytes=16,.integer_bits=32,.work_rows=256,.result_rows=32,.tx_writes=1024,
    .compact_integral_scans=true,.dimension_group_ids=true,.dimension_distinct_groups=distinct,.nulls_first_ascending=false};}
const Fast=sql.Database(config(true));const Slow=sql.Database(config(false));
var fast:Fast=.{};var slow:Slow=.{};var twin:Fast=.{};
var fr:Fast.Result=.{};var sr:Slow.Result=.{};var tr:Fast.Result=.{};
var memory:[3][8388608]u8 align(64)=undefined;var old_refs:[8192]u32=undefined;var short_refs:[48]u32=undefined;
const Small=sql.Database(blk:{var c=config(true);c.numeric_digits=8;break :blk c;});
var small:Small=.{};var small_result:Small.Result=.{};var small_memory:[1048576]u8 align(64)=undefined;
var assertions:usize=0;const n=513;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("dimension DISTINCT assertion {d}\n",.{assertions});return error.DimensionDistinctContract;}}
fn same() !void {
    try check(fr.row_count==sr.row_count and fr.column_count==sr.column_count);
    for(fr.rows[0..fr.row_count],sr.rows[0..sr.row_count]) |a,b| for(0..fr.column_count) |i| {
        const x=a.cells[i];const y=b.cells[i];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x){.null_value=>{},.integer=>|v|try check(v==y.integer),.text=>|v|try check(std.mem.eql(u8,v.slice(),y.text.slice())),
            .numeric=>|v|try check(v.coef()==y.numeric.coef() and v.dscale==y.numeric.dscale and v.negative==y.numeric.negative and v.special==y.numeric.special),else=>return error.UnexpectedCell}
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("distinct fast {s}: {s}\n",.{@errorName(err),source});return err;};
    try slow.execute(source,&sr);try same();
}
fn reject(source:[]const u8,wanted:sql.Error) !void {
    const before=fr;
    if(fast.execute(source,&fr)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(fr.row_count==before.row_count and fr.column_count==before.column_count);
    for(fr.rows[0..fr.row_count],before.rows[0..before.row_count]) |a,b| for(0..fr.column_count) |i| try check(Fast.compareCells(&a.cells[i],&b.cells[i])==0);
}
const query="SELECT c.label,COUNT(*),COUNT(DISTINCT f.customer),COUNT(DISTINCT f.other),SUM(f.quantity),CAST(SUM(f.amount) AS TEXT) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category GROUP BY c.label ORDER BY c.label NULLS FIRST";
fn amount(i:usize) i64 {return if(i==1) -9223372036854775808 else if(i==32) 9223372036854775807 else @as(i64,@intCast(i))-200;}
fn customerValue(i:usize) i64 {
    const category=(i%31)%7;
    return if(category==2) @as(i64,@intCast(i%7))-3 else if(category==0 or category==3) @as(i64,@intCast(i%9))-11 else @intCast(i%12);
}
fn otherValue(i:usize) usize {return (i%31)%7;}
fn model() !void {
    var rows:[3]i64=@splat(0);var nq=rows;var na=rows;var qty=rows;var distinct=rows;var other=rows;
    var seen:[3][23]bool=@splat(@splat(false));var seen_other:[3][7]bool=@splat(@splat(false));var total:[3]i128=@splat(0);
    for(0..n) |i| {
        const product=i%31;if(i%17==0 or product>=17 or product%11==0 or product%7>=5) continue;
        const category=product%7;const group:usize=if(category==2) 0 else if(category==0 or category==3) 1 else 2;
        rows[group]+=1;
        const customer:usize=@intCast(customerValue(i)+11);const other_value=otherValue(i);
        if(i%13!=0 and !seen[group][customer]){seen[group][customer]=true;distinct[group]+=1;}
        if(i%29!=0 and !seen_other[group][other_value]){seen_other[group][other_value]=true;other[group]+=1;}
        if(i%5!=0){nq[group]+=1;qty[group]+=@intCast(i%9);}
        if(i%19!=0){na[group]+=1;total[group]+=amount(i);}
    }
    try check(fr.row_count==3);var text:[128]u8=undefined;
    try check(distinct[0]!=distinct[1] and distinct[1]!=distinct[2] and other[0]!=other[1]);
    for(0..3) |group| {
        const c=fr.rows[group].cells;
        if(group==0) try check(c[0]==.null_value) else try check(std.mem.eql(u8,c[0].text.slice(),if(group==1) "a" else "b"));
        try check(c[1].integer==rows[group] and c[2].integer==distinct[group] and c[3].integer==other[group]);
        if(nq[group]==0) try check(c[4]==.null_value) else try check(c[4].integer==qty[group]);
        if(na[group]==0) try check(c[5]==.null_value) else try check(std.mem.eql(u8,c[5].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{total[group]})));
    }
}
fn failFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {return error.InjectedFlushFailure;}
const Cancel=struct {facts:bool=false,calls:usize=0,
    fn poll(raw:?*anyopaque) sql.Error!void {const self:*Cancel=@ptrCast(@alignCast(raw.?));self.calls+=1;
        if(if(self.facts) fast.workspace.query.stream_stats.rows>=64 else fast.workspace.query.stream_stats.dimension_group_keys>=4) return error.QueryCanceled;}
};
pub fn main() !void {
    @memset(std.mem.asBytes(&memory),0xa5);
    try fast.bindMemory(&memory[0],n+16,(n+16)*2,8192);try slow.bindMemory(&memory[1],n+16,(n+16)*2,8192);
    try execute("CREATE TABLE fact(id INT PRIMARY KEY,product INT,customer BIGINT,amount BIGINT,quantity INT,other INT)");
    try execute("CREATE TABLE products(id INT PRIMARY KEY,category INT,flag INT)");try execute("CREATE TABLE categories(id INT PRIMARY KEY,label TEXT)");
    try execute("INSERT INTO categories VALUES(0,'a'),(1,'b'),(2,NULL),(3,'a'),(4,'b')");var text:[1024]u8=undefined;
    for(0..17) |i| {var category:[24]u8=undefined;try execute(try std.fmt.bufPrint(&text,"INSERT INTO products VALUES({d},{s},{d})",.{i,if(i%11==0) "NULL" else try std.fmt.bufPrint(&category,"{d}",.{i%7}),i%3}));}
    for(0..n) |i| {
        var product:[24]u8=undefined;var customer:[24]u8=undefined;var value:[32]u8=undefined;var quantity:[24]u8=undefined;var other:[24]u8=undefined;
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO fact VALUES({d},{s},{s},{s},{s},{s})",.{i,
            if(i%17==0) "NULL" else try std.fmt.bufPrint(&product,"{d}",.{i%31}),
            if(i%13==0) "NULL" else try std.fmt.bufPrint(&customer,"{d}",.{customerValue(i)}),
            if(i%19==0) "NULL" else try std.fmt.bufPrint(&value,"{d}",.{amount(i)}),
            if(i%5==0) "NULL" else try std.fmt.bufPrint(&quantity,"{d}",.{i%9}),
            if(i%29==0) "NULL" else try std.fmt.bufPrint(&other,"{d}",.{otherValue(i)})}));
    }
    try execute(query);try model();
    try check(fast.workspace.query.stream_stats.dimension_distinct_plans==1 and fast.workspace.query.stream_stats.dimension_group_ids==3);
    try check(fast.workspace.query.stream_stats.dimension_group_keys==31 and fast.workspace.query.stream_stats.gathered_rows==0 and fast.workspace.query.stream_stats.distinct_bitmap_bytes==48);
    // Cross word boundaries in two independent bitmaps owned by the same
    // final label, then delete the rows while retaining conservative bounds.
    for([_]usize{0,63,64,65,127,128,255,256},0..) |value,index| {
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO fact VALUES({d},2,{d},1,2,{d})",.{600+index,@as(i64,@intCast(value))-11,value}));
    }
    try execute(query);try check(fr.rows[0].cells[0]==.null_value and fr.rows[0].cells[2].integer==15 and fr.rows[0].cells[3].integer==9);
    try check(fast.workspace.query.stream_stats.dimension_distinct_plans==1 and fast.workspace.query.stream_stats.distinct_bitmap_bytes==240);
    try execute("DELETE FROM fact WHERE id>=600");try execute(query);try model();
    try execute("SELECT c.label,COUNT(DISTINCT f.customer),AVG(f.amount),SUM(f.quantity) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category AND p.flag>0 GROUP BY c.label HAVING COUNT(*)>1 ORDER BY c.label DESC NULLS LAST LIMIT 2");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==1);
    try execute("SELECT p.category,COUNT(DISTINCT f.customer),COUNT(*),SUM(f.amount) FROM fact f JOIN products p ON p.id=f.product GROUP BY p.category");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==1);
    try execute("SELECT c.label,COUNT(DISTINCT f.customer) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.customer>=0 GROUP BY c.label");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("SELECT c.label,SUM(DISTINCT f.quantity) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category GROUP BY c.label");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("SELECT c.label,COUNT(DISTINCT p.flag) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category GROUP BY c.label");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("SELECT c.label,COUNT(DISTINCT f.customer) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category AND p.flag=f.other GROUP BY c.label");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("SELECT c.label,COUNT(DISTINCT f.customer) FROM fact f JOIN products p ON p.flag=f.product JOIN categories c ON c.id=p.category WHERE f.id<16 GROUP BY c.label");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("SELECT c.label,COUNT(DISTINCT f.customer) FROM fact f LEFT JOIN products p ON p.id=f.product LEFT JOIN categories c ON c.id=p.category GROUP BY c.label");try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute(query);try reject("SELECT c.label,COUNT(DISTINCT f.customer) FROM fact f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category AND 1/(p.flag-p.flag)=0 GROUP BY c.label",error.DivisionByZero);
    const ft=try fast.begin();const st=try slow.begin();
    try fast.statement(ft,"UPDATE fact SET customer=11 WHERE id=3",&fr,.{});try slow.statement(st,"UPDATE fact SET customer=11 WHERE id=3",&sr,.{});
    try fast.statement(ft,query,&fr,.{});try slow.statement(st,query,&sr,.{});try same();try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);fast.abort(ft);slow.abort(st);try execute(query);try model();
    const pin=try fast.begin();const snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pin].pin=snapshot;
    try fast.execute("UPDATE products SET category=3 WHERE id=2",&fr);
    var reader:Fast.ReadContext=.{};reader.workspace.query.refs=&old_refs;
    try reader.execute(&fast,query,snapshot,&fr);try slow.execute(query,&sr);try same();try check(reader.workspace.query.stream_stats.dimension_distinct_plans==1);fast.abort(pin);
    try slow.execute("UPDATE products SET category=3 WHERE id=2",&sr);try execute(query);
    const fp=try fast.begin();const old:Fast.Snapshot=.{.csn=fast.csn};fast.txs[fp].pin=old;
    try fast.execute("UPDATE fact SET customer=11 WHERE id=9",&fr);
    try reader.execute(&fast,query,old,&fr);try slow.execute(query,&sr);try same();try check(reader.workspace.query.stream_stats.dimension_distinct_plans==0);fast.abort(fp);
    try slow.execute("UPDATE fact SET customer=11 WHERE id=9",&sr);try execute(query);
    var record:[65536]u8=undefined;var used:usize=0;
    if(fast.executeChanges("UPDATE categories SET label='bad' WHERE id=3",&fr,&record,&used,null,failFlush)) |_| return error.ExpectedFlushFailure else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0);try execute(query);
    try twin.bindMemory(&memory[2],n+16,(n+16)*2,8192);try twin.copyFromInto(&fast);
    used=0;try fast.executeChanges("UPDATE categories SET label='b' WHERE id=3",&fr,&record,&used,null,null);try slow.execute("UPDATE categories SET label='b' WHERE id=3",&sr);
    var replay:Fast.ReplayScratch=.{};try twin.applyChangeRecord(record[0..used],&replay);try execute(query);try twin.execute(query,&tr);
    try check(fr.row_count==tr.row_count);
    for(fr.rows[0..fr.row_count],tr.rows[0..tr.row_count]) |a,b| for(0..fr.column_count) |i| try check(Fast.compareCells(&a.cells[i],&b.cells[i])==0);
    var control:sql.ExecutionControl=.{.max_work=100};fast.session.control=&control;try reject(query,error.QueryWorkLimit);fast.session.control=null;
    for([_]bool{false,true}) |facts| {var cancel:Cancel=.{.facts=facts};control=.{.context=&cancel,.poll=Cancel.poll,.poll_interval=1};fast.workspace.query.stream_stats=.{};fast.session.control=&control;try reject(query,error.QueryCanceled);fast.session.control=null;try check(cancel.calls>0);}
    @memset(&fast.workspace.query.cells,.{.integer=0x55555555});try execute(query);
    var constrained:Fast.ReadContext=.{};constrained.workspace.query.refs=&short_refs;
    try constrained.execute(&fast,query,.{.csn=fast.csn},&fr);try slow.execute(query,&sr);try same();try check(constrained.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("UPDATE fact SET customer=NULL,other=NULL");try execute(query);
    for(fr.rows[0..fr.row_count]) |row| try check(row.cells[1].integer>0 and row.cells[2].integer==0 and row.cells[3].integer==0);
    try check(fast.workspace.query.stream_stats.dimension_distinct_plans==1);
    try execute("INSERT INTO fact VALUES(700,2,9223372036854775807,1,2,1),(701,9,-9223372036854775808,2,3,2)");try execute(query);try check(fast.workspace.query.stream_stats.dimension_distinct_plans==0);
    try execute("DELETE FROM fact");try execute(query);try check(fr.row_count==0);
    try execute("DROP TABLE fact");try execute("CREATE TABLE fact(id INT PRIMARY KEY,product INT,customer BIGINT,amount BIGINT,quantity INT,other INT)");
    try execute("INSERT INTO fact VALUES(1,2,NULL,1,2,NULL)");try execute(query);
    try check(fr.row_count==1 and fr.rows[0].cells[2].integer==0 and fr.rows[0].cells[3].integer==0);
    try check(fast.workspace.query.stream_stats.dimension_distinct_plans==1 and fast.workspace.query.stream_stats.distinct_bitmap_bytes==0);
    try small.bindMemory(&small_memory,2,4,128);
    try small.execute("CREATE TABLE fact(id INT PRIMARY KEY,product INT,customer BIGINT,amount BIGINT,quantity INT,other INT)",&small_result);
    try small.execute("CREATE TABLE products(id INT PRIMARY KEY,category INT,flag INT)",&small_result);try small.execute("CREATE TABLE categories(id INT PRIMARY KEY,label TEXT)",&small_result);
    try small.execute("INSERT INTO categories VALUES(1,'a')",&small_result);try small.execute("INSERT INTO products VALUES(1,1,1)",&small_result);try small.execute("INSERT INTO fact VALUES(1,1,2,3,4,5)",&small_result);try small.execute(query,&small_result);
    try check(small_result.row_count==1 and small.workspace.query.stream_stats.dimension_distinct_plans==0);
    std.debug.print("PASS dimension DISTINCT: {d} assertions, scalar/canonical, shared-label membership, snapshots and failure atomicity\n",.{assertions});
}
