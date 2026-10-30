//! Dimension-ID folding: actual SQL, canonical execution and scalar oracle.
const std=@import("std");const sql=@import("sql");
fn config(comptime ids:bool) sql.Config {return .{.external_storage=true,.tables=2,.columns=8,.rows_per_table=2,
    .text_bytes=32,.name_bytes=16,.integer_bits=32,.work_rows=256,.result_rows=64,.tx_writes=1024,
    .compact_integral_scans=true,.dimension_group_ids=ids,.nulls_first_ascending=false};}
const Fast=sql.Database(config(true));const Slow=sql.Database(config(false));
var fast:Fast=.{};var slow:Slow=.{};var twin:Fast=.{};
var fr:Fast.Result=.{};var sr:Slow.Result=.{};var tr:Fast.Result=.{};
var memory:[3][4194304]u8 align(64)=undefined;var old_refs:[8192]u32=undefined;var short_refs:[128]u32=undefined;
const Small=sql.Database(blk:{var c=config(true);c.numeric_digits=8;break :blk c;});
var small:Small=.{};var small_result:Small.Result=.{};var small_memory:[1048576]u8 align(64)=undefined;
var assertions:usize=0;const n=513;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("dimension IDs assertion {d}\n",.{assertions});return error.DimensionGroupContract;}}
fn same() !void {
    try check(fr.row_count==sr.row_count and fr.column_count==sr.column_count);
    for(fr.rows[0..fr.row_count],sr.rows[0..sr.row_count]) |a,b| for(0..fr.column_count) |i| {
        const x=a.cells[i];const y=b.cells[i];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x){.null_value=>{},.integer=>|v|try check(v==y.integer),.text=>|v|try check(std.mem.eql(u8,v.slice(),y.text.slice())),
            .numeric=>|v|try check(v.coef()==y.numeric.coef() and v.dscale==y.numeric.dscale and v.negative==y.numeric.negative and v.special==y.numeric.special),else=>return error.UnexpectedCell}
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("dimension fast {s}: {s}\n",.{@errorName(err),source});return err;};
    try slow.execute(source,&sr);try same();
}
fn reject(source:[]const u8,wanted:sql.Error) !void {
    const before=fr;
    if(fast.execute(source,&fr)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(fr.row_count==before.row_count and fr.column_count==before.column_count);
    for(fr.rows[0..fr.row_count],before.rows[0..before.row_count]) |a,b| for(0..fr.column_count) |i| try check(Fast.compareCells(&a.cells[i],&b.cells[i])==0);
}
const query="SELECT cu.segment,f.discount,COUNT(*),COUNT(f.quantity),SUM(f.quantity),CAST(SUM(f.amount) AS TEXT),COUNT(f.note) FROM fact f JOIN customers cu ON cu.id=f.customer GROUP BY cu.segment,f.discount ORDER BY cu.segment NULLS FIRST,f.discount NULLS FIRST";
fn amount(i:usize) i64 {return if(i==1) 9223372036854775807 else if(i==38) -9223372036854775808 else @as(i64,@intCast(i))-200;}
fn model() !void {
    var rows:[5][6]i64=@splat(@splat(0));var nq=rows;var na=rows;var nn=rows;var q=rows;var a:[5][6]i128=@splat(@splat(0));
    for(0..n) |i| {
        if(i%17==0 or i%37>=31) continue;const customer=i%37;
        const group:usize=if(customer%7==0) 0 else customer%4+1;const discount:usize=if(i%19==0) 0 else i%5+1;
        rows[group][discount]+=1;
        if(i%13!=0){nq[group][discount]+=1;q[group][discount]+=@intCast(i%7);}
        if(i%23!=0){na[group][discount]+=1;a[group][discount]+=amount(i);}
        if(i%11!=0) nn[group][discount]+=1;
    }
    var at:usize=0;var text:[128]u8=undefined;
    for(0..5) |group| for(0..6) |discount| {
        if(rows[group][discount]==0) continue;const c=fr.rows[at].cells;at+=1;
        if(group==0) try check(c[0]==.null_value) else try check(std.mem.eql(u8,c[0].text.slice(),switch(group){1=>"a",2=>"b",3=>"c",4=>"d",else=>unreachable}));
        if(discount==0) try check(c[1]==.null_value) else try check(c[1].integer==@as(i64,@intCast(discount))-3);
        try check(c[2].integer==rows[group][discount] and c[3].integer==nq[group][discount] and c[6].integer==nn[group][discount]);
        if(nq[group][discount]==0) try check(c[4]==.null_value) else try check(c[4].integer==q[group][discount]);
        if(na[group][discount]==0) try check(c[5]==.null_value) else try check(std.mem.eql(u8,c[5].text.slice(),try std.fmt.bufPrint(&text,"{d}",.{a[group][discount]})));
    };
    try check(fr.row_count==at);
}
fn failFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {return error.InjectedFlushFailure;}
const Cancel=struct {facts:bool=false,calls:usize=0,
    fn poll(raw:?*anyopaque) sql.Error!void {const self:*Cancel=@ptrCast(@alignCast(raw.?));self.calls+=1;
        if(if(self.facts) fast.workspace.query.stream_stats.rows>=64 else fast.workspace.query.stream_stats.dimension_group_keys>=4) return error.QueryCanceled;}
};
pub fn main() !void {
    @memset(std.mem.asBytes(&memory),0xa5);
    try fast.bindMemory(&memory[0],n+16,(n+16)*2,8192);try slow.bindMemory(&memory[1],n+16,(n+16)*2,8192);
    try execute("CREATE TABLE fact(id INT PRIMARY KEY,customer INT,discount BIGINT,amount BIGINT,quantity INT,note TEXT)");
    try execute("CREATE TABLE customers(id INT PRIMARY KEY,segment TEXT,enabled INT)");var text:[1024]u8=undefined;
    for(0..31) |i| try execute(try std.fmt.bufPrint(&text,"INSERT INTO customers VALUES({d},{s},{d})",.{i,if(i%7==0) "NULL" else switch(i%4){0=>"'a'",1=>"'b'",2=>"'c'",3=>"'d'",else=>unreachable},i%3}));
    for(0..n) |i| {
        var customer:[24]u8=undefined;var discount:[24]u8=undefined;var value:[32]u8=undefined;var quantity:[24]u8=undefined;
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO fact VALUES({d},{s},{s},{s},{s},{s})",.{i,
            if(i%17==0) "NULL" else try std.fmt.bufPrint(&customer,"{d}",.{i%37}),
            if(i%19==0) "NULL" else try std.fmt.bufPrint(&discount,"{d}",.{@as(i64,@intCast(i%5))-2}),
            if(i%23==0) "NULL" else try std.fmt.bufPrint(&value,"{d}",.{amount(i)}),
            if(i%13==0) "NULL" else try std.fmt.bufPrint(&quantity,"{d}",.{i%7}),if(i%11==0) "NULL" else "'x'"}));
    }
    try execute(query);try model();
    try check(fast.workspace.query.stream_stats.dimension_group_plans==1 and fast.workspace.query.stream_stats.dimension_group_ids==5);
    try check(fast.workspace.query.stream_stats.dimension_probes==37 and fast.workspace.query.stream_stats.gathered_rows==0);
    try execute("SELECT f.discount,cu.segment,SUM(f.amount),AVG(f.quantity) FROM fact f JOIN customers cu ON cu.id=f.customer GROUP BY f.discount,cu.segment HAVING COUNT(*)>1 ORDER BY f.discount DESC NULLS LAST,cu.segment LIMIT 12 OFFSET 1");
    try check(fast.workspace.query.stream_stats.dimension_group_plans==1);
    try execute("SELECT cu.segment,f.discount,SUM(f.amount),SUM(f.quantity) FROM fact f JOIN customers cu ON cu.id=f.customer AND cu.enabled>0 GROUP BY cu.segment,f.discount");
    try check(fast.workspace.query.stream_stats.dimension_group_plans==1);
    try execute("SELECT cu.segment,f.discount,SUM(f.amount) FROM fact f JOIN customers cu ON cu.id=f.customer AND cu.enabled<0 GROUP BY cu.segment,f.discount");
    try check(fr.row_count==0 and fast.workspace.query.stream_stats.dimension_group_plans==1 and fast.workspace.query.stream_stats.dimension_group_rows==0);
    try execute("SELECT cu.segment,f.discount,COUNT(*),SUM(f.quantity) FROM fact f LEFT JOIN customers cu ON cu.id=f.customer GROUP BY cu.segment,f.discount ORDER BY cu.segment,f.discount");
    try check(fast.workspace.query.stream_stats.dimension_group_plans==0);
    try execute("SELECT cu.segment,f.discount,COUNT(*),SUM(f.amount) FROM fact f JOIN customers cu ON cu.id=f.customer AND cu.enabled=f.discount GROUP BY cu.segment,f.discount");
    try check(fast.workspace.query.stream_stats.dimension_group_plans==0);
    try execute("SELECT cu.segment,f.discount,COUNT(DISTINCT f.customer),SUM(f.amount) FROM fact f JOIN customers cu ON cu.id=f.customer GROUP BY cu.segment,f.discount");try check(fast.workspace.query.stream_stats.dimension_group_plans==0);
    try execute("SELECT cu.segment,f.discount,SUM(f.amount) FROM fact f JOIN customers cu ON cu.id=f.customer WHERE f.id<100 GROUP BY cu.segment,f.discount");try check(fast.workspace.query.stream_stats.dimension_group_plans==0);
    try execute("SELECT cu.segment,f.discount,SUM(f.amount) FROM fact f JOIN customers cu ON cu.enabled=f.customer WHERE f.id<20 GROUP BY cu.segment,f.discount");try check(fast.workspace.query.stream_stats.dimension_group_plans==0);
    try execute(query);try reject("SELECT cu.segment,f.discount,SUM(f.amount) FROM fact f JOIN customers cu ON cu.id=f.customer AND 1/(cu.enabled-cu.enabled)=0 GROUP BY cu.segment,f.discount",error.DivisionByZero);
    try reject("SELECT cu.segment,f.discount,SUM(f.amount) FROM fact f JOIN customers cu ON cu.id=f.customer GROUP BY cu.segment,f.discount HAVING 1/(COUNT(*)-COUNT(*))>0",error.DivisionByZero);
    const ft=try fast.begin();const st=try slow.begin();
    try fast.statement(ft,"UPDATE customers SET segment='z' WHERE id=1",&fr,.{});try slow.statement(st,"UPDATE customers SET segment='z' WHERE id=1",&sr,.{});
    try fast.statement(ft,"UPDATE fact SET quantity=777 WHERE id=5",&fr,.{});try slow.statement(st,"UPDATE fact SET quantity=777 WHERE id=5",&sr,.{});
    try fast.statement(ft,query,&fr,.{});try slow.statement(st,query,&sr,.{});try same();try check(fast.workspace.query.stream_stats.dimension_group_plans==0);fast.abort(ft);slow.abort(st);
    const pin=try fast.begin();const snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pin].pin=snapshot;
    try fast.execute("UPDATE customers SET segment='z' WHERE id=1",&fr);
    var reader:Fast.ReadContext=.{};reader.workspace.query.refs=&old_refs;
    try reader.execute(&fast,query,snapshot,&fr);try slow.execute(query,&sr);try same();try check(reader.workspace.query.stream_stats.dimension_group_plans==1);fast.abort(pin);
    try slow.execute("UPDATE customers SET segment='z' WHERE id=1",&sr);try execute(query);
    const pk_pin=try fast.begin();const pk_snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pk_pin].pin=pk_snapshot;
    try fast.execute("UPDATE customers SET id=80 WHERE id=1",&fr);
    try reader.execute(&fast,query,pk_snapshot,&fr);try slow.execute(query,&sr);try same();try check(reader.workspace.query.stream_stats.dimension_group_plans==1);fast.abort(pk_pin);
    try slow.execute("UPDATE customers SET id=80 WHERE id=1",&sr);try execute(query);
    try execute("UPDATE customers SET id=1 WHERE id=80");try execute(query);
    const fp=try fast.begin();const old:Fast.Snapshot=.{.csn=fast.csn};fast.txs[fp].pin=old;
    try fast.execute("UPDATE fact SET quantity=99 WHERE id=4",&fr);
    try reader.execute(&fast,query,old,&fr);try slow.execute(query,&sr);try same();try check(reader.workspace.query.stream_stats.dimension_group_plans==0);fast.abort(fp);
    try slow.execute("UPDATE fact SET quantity=99 WHERE id=4",&sr);try execute(query);
    var record:[65536]u8=undefined;var used:usize=0;
    if(fast.executeChanges("UPDATE customers SET segment='bad' WHERE id=2",&fr,&record,&used,null,failFlush)) |_| return error.ExpectedFlushFailure else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0);try execute(query);
    try twin.bindMemory(&memory[2],n+16,(n+16)*2,8192);try twin.copyFromInto(&fast);
    used=0;try fast.executeChanges("UPDATE customers SET segment='a' WHERE id=1",&fr,&record,&used,null,null);try slow.execute("UPDATE customers SET segment='a' WHERE id=1",&sr);
    var replay:Fast.ReplayScratch=.{};try twin.applyChangeRecord(record[0..used],&replay);try execute(query);try twin.execute(query,&tr);
    try check(fr.row_count==tr.row_count);
    for(fr.rows[0..fr.row_count],tr.rows[0..tr.row_count]) |a,b| for(0..fr.column_count) |i| try check(Fast.compareCells(&a.cells[i],&b.cells[i])==0);
    var control:sql.ExecutionControl=.{.max_work=100};fast.session.control=&control;try reject(query,error.QueryWorkLimit);fast.session.control=null;
    for([_]bool{false,true}) |facts| {
        var cancel:Cancel=.{.facts=facts};control=.{.context=&cancel,.poll=Cancel.poll,.poll_interval=1};fast.workspace.query.stream_stats=.{};fast.session.control=&control;
        try reject(query,error.QueryCanceled);fast.session.control=null;try check(cancel.calls>0);
    }
    @memset(&fast.workspace.query.cells,.{.integer=0x55555555});try execute(query);
    try execute("UPDATE fact SET discount=0");try execute(query);
    var constrained:Fast.ReadContext=.{};constrained.workspace.query.refs=&short_refs;
    try constrained.execute(&fast,query,.{.csn=fast.csn},&fr);try slow.execute(query,&sr);try same();try check(constrained.workspace.query.stream_stats.dimension_group_plans==0);
    try execute("UPDATE fact SET discount=NULL,amount=NULL,quantity=NULL,note=NULL");try execute(query);
    for(fr.rows[0..fr.row_count]) |row| try check(row.cells[1]==.null_value and row.cells[2].integer>0 and row.cells[3].integer==0 and row.cells[4]==.null_value and row.cells[5]==.null_value and row.cells[6].integer==0);
    try check(fast.workspace.query.stream_stats.dimension_group_plans==1);
    try execute("DELETE FROM customers WHERE id=3");try execute(query);
    try execute("INSERT INTO customers VALUES(3,'a',1)");try execute(query);
    try execute("DELETE FROM fact");try execute(query);try check(fr.row_count==0);
    for([_][]const u8{"9223372036854775807","-9223372036854775808"}) |key| {
        try execute("DROP TABLE fact");try execute("DROP TABLE customers");
        try execute("CREATE TABLE fact(id INT PRIMARY KEY,customer BIGINT,discount BIGINT,amount BIGINT,quantity INT,note TEXT)");
        try execute("CREATE TABLE customers(id BIGINT PRIMARY KEY,segment TEXT,enabled INT)");
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO customers VALUES({s},'a',1)",.{key}));
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO fact VALUES(1,{s},{s},9223372036854775807,1,NULL),(2,{s},{s},9223372036854775807,1,NULL)",.{key,key,key,key}));
        try execute(query);try check(fast.workspace.query.stream_stats.dimension_group_plans==1 and fr.row_count==1);
        try check(std.mem.eql(u8,fr.rows[0].cells[5].text.slice(),"18446744073709551614"));
    }
    try execute("INSERT INTO customers VALUES(9223372036854775807,'b',NULL)");
    try execute("INSERT INTO fact VALUES(3,9223372036854775807,9223372036854775807,1,2,'x')");
    try execute(query);try check(fast.workspace.query.stream_stats.dimension_group_plans==0);
    try small.bindMemory(&small_memory,2,4,128);
    try small.execute("CREATE TABLE fact(id INT PRIMARY KEY,customer INT,discount BIGINT,amount BIGINT,quantity INT,note TEXT)",&small_result);
    try small.execute("CREATE TABLE customers(id INT PRIMARY KEY,segment TEXT,enabled INT)",&small_result);
    try small.execute("INSERT INTO customers VALUES(1,'a',1)",&small_result);
    try small.execute("INSERT INTO fact VALUES(1,1,0,2,3,'x')",&small_result);try small.execute(query,&small_result);
    try check(small_result.row_count==1 and small.workspace.query.stream_stats.dimension_group_plans==0);
    std.debug.print("PASS dimension group IDs: {d} assertions, scalar/canonical, visibility, replay and failure atomicity\n",.{assertions});
}
