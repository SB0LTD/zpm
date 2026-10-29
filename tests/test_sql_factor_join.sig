//! Real SQL executor contract: factor-first execution versus the unchanged
//! executor, plus an independent scalar model and visibility/error boundaries.
const std=@import("std");
const sql=@import("sql");
pub const sparse_test=if(@hasDecl(@import("root"),"test_sparse_factor")) @import("root").test_sparse_factor else false;
fn config(comptime factor:bool) sql.Config {return .{.external_storage=true,.tables=3,.columns=6,.rows_per_table=2,.text_bytes=16,.name_bytes=16,
    .integer_bits=32,.work_rows=128,.result_rows=16,.tx_writes=1024,.compact_integral_scans=true,.factorized_aggregates=factor,.block_presence_filters=factor and sparse_test,.sparse_factor_predicates=factor and sparse_test,.nulls_first_ascending=false};}
const Fast=sql.Database(config(true));const Slow=sql.Database(config(false));
const Small=sql.Database(blk:{var c=config(true);c.numeric_digits=8;break :blk c;});
const n=513;
var fast:Fast=.{};var slow:Slow=.{};
var fr:Fast.Result=.{};var sr:Slow.Result=.{};
var twin:Fast=.{};var tr:Fast.Result=.{};
var memory:[3][2097152]u8 align(64)=undefined;
var old_refs:[4096]u32=undefined;
var constrained:Fast.ReadContext=.{};var short_refs:[128]u32=undefined;
var assertions:usize=0;
var small:Small=.{};var small_result:Small.Result=.{};var small_memory:[131072]u8 align(64)=undefined;
fn check(ok:bool) !void {assertions+=1;if(!ok) {std.debug.print("factor assertion {d}\n",.{assertions});return error.FactorJoinContract;}}
fn same() !void {
    try check(fr.row_count==sr.row_count and fr.column_count==sr.column_count);
    for(fr.rows[0..fr.row_count],sr.rows[0..sr.row_count]) |a,b| for(0..fr.column_count) |column| {
        const x=a.cells[column];const y=b.cells[column];try check(std.meta.activeTag(x)==std.meta.activeTag(y));
        switch(x) {
            .null_value=>{},.integer=>|v| try check(v==y.integer),.text=>|v| try check(std.mem.eql(u8,v.slice(),y.text.slice())),
            .numeric=>|v| try check(v.coef()==y.numeric.coef() and v.dscale==y.numeric.dscale and v.negative==y.numeric.negative and v.special==y.numeric.special),
            else=>return error.UnexpectedTestValue,
        }
    };
}
fn execute(source:[]const u8) !void {
    fast.execute(source,&fr) catch |err| {std.debug.print("factor execution {s}: {s}\n",.{@errorName(err),source});return err;};
    slow.execute(source,&sr) catch |err| {std.debug.print("canonical execution {s}: {s}\n",.{@errorName(err),source});return err;};
    try same();
}
fn sameTwin() !void {
    try check(fr.row_count==tr.row_count and fr.column_count==tr.column_count);
    for(fr.rows[0..fr.row_count],tr.rows[0..tr.row_count]) |a,b| for(0..fr.column_count) |column| {
        try check(std.meta.activeTag(a.cells[column])==std.meta.activeTag(b.cells[column]));
        try check(Fast.compareCells(&a.cells[column],&b.cells[column])==0);
    };
}
fn reject(source:[]const u8,wanted:sql.Error) !void {
    const before=fr;
    if(fast.execute(source,&fr)) |_| return error.ExpectedFailure else |err| try check(err==wanted);
    try check(fr.row_count==before.row_count and fr.column_count==before.column_count);
    for(fr.rows[0..fr.row_count],before.rows[0..before.row_count]) |a,b| for(0..fr.column_count) |column| try check(Fast.compareCells(&a.cells[column],&b.cells[column])==0);
}
fn init() !void {
    @memset(std.mem.asBytes(&memory),0xa5);
    try fast.bindMemory(&memory[0],n+1,(n+1)*2,4096);try slow.bindMemory(&memory[1],n+1,(n+1)*2,4096);
    try execute("CREATE TABLE facts(id INT PRIMARY KEY,product INT,store INT,day DATE,quantity INT,amount BIGINT)");
    try execute("CREATE TABLE products(id INT PRIMARY KEY,category INT,flag INT)");
    try execute("CREATE TABLE categories(id INT PRIMARY KEY,label TEXT)");
    try execute("INSERT INTO categories VALUES(0,'a'),(1,'b'),(2,NULL)");
    var text:[256]u8=undefined;
    for(0..17) |i| {
        var category:[16]u8=undefined;const c=if(i%11==0) "NULL" else try std.fmt.bufPrint(&category,"{d}",.{i%5});
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO products VALUES({d},{s},{d})",.{i,c,i%2}));
    }
    for(0..n) |i| {
        var p:[16]u8=undefined;var s:[16]u8=undefined;var q:[16]u8=undefined;var a:[24]u8=undefined;
        const product=if(i%17==0) "NULL" else try std.fmt.bufPrint(&p,"{d}",.{i%31});
        const store=if(i%19==0) "NULL" else try std.fmt.bufPrint(&s,"{d}",.{i%5});
        const quantity=if(i%13==0) "NULL" else try std.fmt.bufPrint(&q,"{d}",.{i%7});
        const amount=if(i%23==0) "NULL" else try std.fmt.bufPrint(&a,"{d}",.{@as(i64,@intCast(i))-200});
        try execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},{s},{s},DATE '2025-{d:0>2}-15',{s},{s})",.{i,product,store,i%12+1,quantity,amount}));
    }
}
const query="SELECT c.label,COUNT(*),COUNT(f.quantity),SUM(f.quantity),SUM(f.amount),AVG(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store={d} AND f.day BETWEEN DATE '2025-03-01' AND DATE '2025-08-31' GROUP BY c.label ORDER BY c.label";
fn model(store:usize) !void {
    var rows:[3]i64=@splat(0);var nonnull:[3]i64=@splat(0);var quantity:[3]i64=@splat(0);var amounts:[3]i64=@splat(0);var amount_count:[3]i64=@splat(0);
    for(0..n) |i| {
        const product=i%31;const category=product%5;
        if(i%17==0 or product>=17 or product%11==0 or category>=3 or i%19==0 or i%5!=store or i%12<2 or i%12>7) continue;
        rows[category]+=1;if(i%13!=0) {nonnull[category]+=1;quantity[category]+=@intCast(i%7);}
        if(i%23!=0) {amount_count[category]+=1;amounts[category]+=@as(i64,@intCast(i))-200;}
    }
    var row_index:usize=0;
    for(0..3) |group| {
        if(rows[group]==0) continue;
        const cells=&fr.rows[row_index].cells;row_index+=1;
        if(group==2) try check(cells[0]==.null_value) else try check(std.mem.eql(u8,cells[0].text.slice(),if(group==0) "a" else "b"));
        try check(cells[1].integer==rows[group] and cells[2].integer==nonnull[group]);
        if(nonnull[group]==0) try check(cells[3]==.null_value) else try check(cells[3].integer==quantity[group]);
        if(amount_count[group]==0) try check(cells[4]==.null_value) else {
            try check(cells[4]==.numeric and cells[4].numeric.dscale==0);
            const magnitude:u64=@intCast(if(amounts[group]<0) -amounts[group] else amounts[group]);
            try check(cells[4].numeric.coef()==magnitude and cells[4].numeric.negative==(amounts[group]<0));
        }
    }
    try check(fr.row_count==row_index);
}
fn failFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {return error.InjectedFlushFailure;}
fn smallPrecision() !void {
    try small.bindMemory(&small_memory,8,16,512);
    try small.execute("CREATE TABLE f(id INT PRIMARY KEY,k INT,v BIGINT)",&small_result);
    try small.execute("CREATE TABLE d(id INT PRIMARY KEY,label TEXT)",&small_result);
    try small.execute("INSERT INTO f VALUES(0,1,200000000),(1,1,200000000)",&small_result);
    try small.execute("INSERT INTO d VALUES(1,'x')",&small_result);try small.execute("SELECT 9",&small_result);
    if(small.execute("SELECT d.label,SUM(f.v) FROM f JOIN d ON d.id=f.k GROUP BY d.label",&small_result)) |_| return error.ExpectedNumericCapacity else |err| try check(err==error.NumericCapacity);
    try check(small_result.row_count==1 and small_result.rows[0].cells[0].integer==9 and small.workspace.query.stream_stats.factor_plans==0);
}
const Cancel=struct {
    calls:usize=0,
    fn poll(raw:?*anyopaque) sql.Error!void {
        const self:*Cancel=@ptrCast(@alignCast(raw.?));self.calls+=1;
        if(fast.workspace.query.stream_stats.factor_selected_rows>0) return error.QueryCanceled;
    }
};
pub fn main() !void {
    try init();var text:[2048]u8=undefined;
    for(0..5) |store| {
        const source=try std.fmt.bufPrint(&text,query,.{store});try execute(source);try model(store);
        const stats=fast.workspace.query.stream_stats;
        try check(stats.factor_plans==1 and stats.gathered_rows==0 and stats.factor_keys>0);
        try check(stats.dimension_probes<=2*stats.factor_keys and stats.factor_selected_rows>stats.factor_keys);
    }
    try execute("SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product AND p.flag=1 JOIN categories c ON c.id=p.category GROUP BY c.label HAVING COUNT(*)>1 ORDER BY c.label");
    try check(fast.workspace.query.stream_stats.factor_plans==1);
    if(sparse_test) {
        try execute("SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store=0 AND f.quantity=1 AND f.day BETWEEN DATE '2025-03-01' AND DATE '2025-08-31' GROUP BY c.label ORDER BY c.label");
        try check(fast.workspace.query.stream_stats.sparse_factor_masks>0);
    }
    for([_][]const u8{"=","<>","<","<=",">",">="}) |op| {
        const source=try std.fmt.bufPrint(&text,"SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store<>2 AND DATE '2025-06-15'{s}f.day GROUP BY c.label ORDER BY c.label",.{op});
        try execute(source);try check(fast.workspace.query.stream_stats.factor_plans==1);
    }
    try execute("SELECT c.label,COUNT(*) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store=99 GROUP BY c.label");
    try check(fr.row_count==0 and fast.workspace.query.stream_stats.factor_plans==1);
    // A fact-dependent extra ON cannot be evaluated once per join key.
    try execute("SELECT c.label,COUNT(*) FROM facts f JOIN products p ON p.id=f.product AND p.flag=f.store JOIN categories c ON c.id=p.category GROUP BY c.label ORDER BY c.label");
    try check(fast.workspace.query.stream_stats.factor_plans==0);
    const q0=try std.fmt.bufPrint(&text,query,.{0});try execute(q0);
    try reject("SELECT c.label,COUNT(*) FROM facts f JOIN products p ON p.id=f.product AND 1/(p.flag-p.flag)=0 JOIN categories c ON c.id=p.category WHERE f.store=99 GROUP BY c.label",error.DivisionByZero);
    try check(fast.workspace.query.stream_stats.factor_plans==0);
    try reject("SELECT c.label,COUNT(*) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store=99 AND f.day>DATE 'invalid' GROUP BY c.label",error.InvalidDatetimeFormat);
    try reject("SELECT c.label,COUNT(*) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store=99 AND f.day>CAST(CAST('invalid' AS TEXT) AS DATE) GROUP BY c.label",error.InvalidDatetimeFormat);
    try execute("SELECT c.label,COUNT(*) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store IS NOT NULL AND f.store=99 AND f.day>CAST(CAST('invalid' AS TEXT) AS DATE) GROUP BY c.label");
    try check(fr.row_count==0 and fast.workspace.query.stream_stats.factor_plans==0);try execute(q0);
    // Private writes retain canonical evaluation.
    const ft=try fast.begin();const st=try slow.begin();
    try fast.statement(ft,"UPDATE facts SET amount=777 WHERE id=4",&fr,.{});try slow.statement(st,"UPDATE facts SET amount=777 WHERE id=4",&sr,.{});
    try fast.statement(ft,q0,&fr,.{});try slow.statement(st,q0,&sr,.{});try same();
    try check(fast.workspace.query.stream_stats.factor_plans==0);fast.abort(ft);slow.abort(st);
    try execute(q0);try model(0);
    // Pin old visibility while publication changes the current fact projection.
    const pin=try fast.begin();const snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[pin].pin=snapshot;
    try fast.execute("UPDATE facts SET store=99 WHERE id=5",&fr);
    var reader:Fast.ReadContext=.{};reader.workspace.query.refs=&old_refs;
    try reader.execute(&fast,q0,snapshot,&fr);try slow.execute(q0,&sr);try same();try model(0);
    try check(reader.workspace.query.stream_stats.factor_plans==0);fast.abort(pin);
    try slow.execute("UPDATE facts SET store=99 WHERE id=5",&sr);try execute(q0);
    const dim_pin=try fast.begin();const dim_snapshot:Fast.Snapshot=.{.csn=fast.csn};fast.txs[dim_pin].pin=dim_snapshot;
    try fast.execute("UPDATE products SET id=40 WHERE id=1",&fr);
    try reader.execute(&fast,q0,dim_snapshot,&fr);try slow.execute(q0,&sr);try same();
    try check(reader.workspace.query.stream_stats.factor_plans==1);fast.abort(dim_pin);
    try slow.execute("UPDATE products SET id=40 WHERE id=1",&sr);try execute(q0);
    var record:[65536]u8=undefined;var used:usize=0;
    if(fast.executeChanges("UPDATE facts SET amount=999 WHERE id=7",&fr,&record,&used,null,failFlush)) |_| return error.ExpectedFlushFailure else |err| try check(err==error.InjectedFlushFailure);
    try check(used==0);try execute(q0);
    try twin.bindMemory(&memory[2],n+1,(n+1)*2,4096);try twin.copyFromInto(&fast);
    try twin.execute(q0,&tr);try sameTwin();try check(twin.workspace.query.stream_stats.factor_plans==1);
    const update="UPDATE facts SET amount=2020,quantity=NULL WHERE id=100";
    used=0;try fast.executeChanges(update,&fr,&record,&used,null,null);try slow.execute(update,&sr);
    var replay:Fast.ReplayScratch=.{};try twin.applyChangeRecord(record[0..used],&replay);
    try execute(q0);try twin.execute(q0,&tr);try sameTwin();
    var control:sql.ExecutionControl=.{.max_work=100};fast.session.control=&control;
    try reject(q0,error.QueryWorkLimit);fast.session.control=null;
    var cancel:Cancel=.{};control=.{.context=&cancel,.poll=Cancel.poll,.poll_interval=1};
    fast.workspace.query.stream_stats=.{};fast.session.control=&control;
    try reject(q0,error.QueryCanceled);fast.session.control=null;
    try check(cancel.calls>0 and fast.workspace.query.stream_stats.factor_selected_rows>0);
    @memset(&fast.workspace.query.cells,.{.integer=0x55555555});try execute(q0);
    try execute("DELETE FROM facts WHERE id=100");try execute(q0);
    try check(fast.workspace.query.stream_stats.factor_plans==1 and fast.workspace.query.stream_stats.rows==n-1);
    try execute("INSERT INTO facts VALUES(100,7,0,DATE '2025-06-15',5,-9223372036854775808)");
    try execute("UPDATE facts SET product=12,store=0,day=DATE '2025-07-15',quantity=1,amount=-9223372036854775808 WHERE id=101");
    try execute(q0);try check(fast.workspace.query.stream_stats.factor_plans==1);
    var wider=false;for(fr.rows[0..fr.row_count]) |row| if(row.cells[4]==.numeric and row.cells[4].numeric.negative and row.cells[4].numeric.coef()>9223372036854775808) {wider=true;};try check(wider);
    constrained.workspace.query.refs=&short_refs;
    try constrained.execute(&fast,q0,.{.csn=fast.csn},&fr);try slow.execute(q0,&sr);try same();
    try check(constrained.workspace.query.stream_stats.factor_plans==0);
    try execute("SELECT c.label,COUNT(DISTINCT f.store) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category GROUP BY c.label ORDER BY c.label");
    try check(fast.workspace.query.stream_stats.factor_plans==0);
    try execute(q0);
    try reject("SELECT c.label,SUM(f.amount/(f.amount-f.amount)) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store=0 GROUP BY c.label",error.DivisionByZero);
    // All-null measures still produce groups, COUNT(*) and NULL SUM/AVG.
    try execute("UPDATE facts SET quantity=NULL,amount=NULL");try execute(q0);
    try check(fr.row_count>0 and fast.workspace.query.stream_stats.factor_plans==1);
    for(fr.rows[0..fr.row_count]) |row| try check(row.cells[1].integer>0 and row.cells[2].integer==0 and row.cells[3]==.null_value and row.cells[4]==.null_value and row.cells[5]==.null_value);
    // An aborted extreme widens metadata: decline dense state, never SQL rows.
    const wide=try fast.begin();try fast.statement(wide,"UPDATE facts SET product=2000000000 WHERE id=4",&fr,.{});fast.abort(wide);
    try execute(q0);try check(fast.workspace.query.stream_stats.factor_plans==0);
    // A non-unique dimension retains exact SQL bag multiplicity in fallback.
    fast=.{};slow=.{};try fast.bindMemory(&memory[0],n+1,(n+1)*2,4096);try slow.bindMemory(&memory[1],n+1,(n+1)*2,4096);
    try execute("CREATE TABLE facts(id INT PRIMARY KEY,product INT,amount BIGINT)");
    try execute("CREATE TABLE products(id INT,category INT)");try execute("CREATE TABLE categories(id INT PRIMARY KEY,label TEXT)");
    try execute("INSERT INTO facts VALUES(0,1,2),(1,1,3)");try execute("INSERT INTO products VALUES(1,0),(1,1)");try execute("INSERT INTO categories VALUES(0,'x'),(1,'x')");
    try execute("SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category GROUP BY c.label");
    try check(fast.workspace.query.stream_stats.factor_plans==0 and fr.row_count==1 and fr.rows[0].cells[1].integer==4 and fr.rows[0].cells[2].numeric.coef()==10);
    try smallPrecision();
    std.debug.print("PASS SQL factor join: {d} assertions, actual executor, scalar model, canonical equivalence, visibility and failure atomicity\n",.{assertions});
}
