//! Original-style selective three-way joins: exact scalar row model, bounded
//! workspace, typed DATE residuals, error ordering and snapshot fallbacks.
const std=@import("std");
const sql=@import("sql");
const DB=sql.Database(.{.external_storage=true,.tables=3,.columns=5,.rows_per_table=4,
    .text_bytes=16,.integer_bits=32,.work_rows=32,.result_rows=16,.compact_integral_scans=true});
const n=257;
var database:DB=.{};
var result:DB.Result=.{};
var rows:[3][n+1]DB.StorageRowSlot=undefined;
var versions:[3][(n+1)*2]DB.StorageVersion=undefined;
var row_indices:[3][1024]u32=undefined;
var key_indices:[3][2048]u32=undefined;
var values:[3][(n+1)*5]i64=undefined;
var nonnull:[3][n+1]u64=undefined;
var live:[3][n+1]u8=undefined;
var refs:[1024]u32=undefined;
var old_refs:[512]u32=undefined;
var assertions:usize=0;
var removed:?usize=null;
var copied:DB=.{};
var copy_memory:[1048576]u8 align(64)=undefined;
var change_record:[65536]u8=undefined;
var date_before_flush:i64=0;
fn rejectDateFlush(_: ?*anyopaque,_:[]const u8) anyerror!void {
    try check(database.tables[0].scan_values[3*database.tables[0].rows.len+4]==date_before_flush);
    return error.InjectedDateFlushFailure;
}
fn check(ok:bool) !void {assertions+=1;if(!ok) {std.debug.print("prefix assertion {d} failed\n",.{assertions});return error.StreamPrefixContract;}}
const query="SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store={d} AND f.day BETWEEN DATE '2025-03-01' AND DATE '2025-08-31' GROUP BY c.label ORDER BY c.label";
const Op=enum{eq,ne,lt,le,gt,ge};
fn matches(actual:i64,wanted:i64,op:Op) bool {return switch(op){.eq=>actual==wanted,.ne=>actual!=wanted,.lt=>actual<wanted,.le=>actual<=wanted,.gt=>actual>wanted,.ge=>actual>=wanted};}
fn model(store:i64,changed:bool,own:bool,op:Op) !void {
    var counts:[4]i64=@splat(0);var sums:[4]i64=@splat(0);
    for(0..n) |i| {
        if(removed!=null and removed.?==i) continue;
        const actual_store:i64=if((changed and i==3) or (own and i==4)) 99 else @intCast(i%8);
        if(!matches(actual_store,store,op) or i%17==0 or i%31==0) continue;
        const month=i%12+1;if(month<3 or month>8) continue;
        const group=(i%16)/4;counts[group]+=1;sums[group]+=@as(i64,@intCast(i))-128;
    }
    var at:usize=0;var label:[16]u8=undefined;
    for(0..4) |group| {
        if(counts[group]==0) continue;
        try check(at<result.row_count);
        try check(std.mem.eql(u8,result.rows[at].cells[0].text.slice(),try std.fmt.bufPrint(&label,"c{d}",.{group})));
        try check(result.rows[at].cells[1].integer==counts[group]);
        try check(result.rows[at].cells[2].integer==sums[group]);at+=1;
    }
    try check(result.row_count==at);
}
const Cancel=struct {
    calls:usize=0,
    fn poll(raw:?*anyopaque) sql.Error!void {
        const self:*Cancel=@ptrCast(@alignCast(raw.?));self.calls+=1;
        if(self.calls==10) return error.QueryCanceled;
    }
};
fn rejected(text:[]const u8,expected:sql.Error) !void {
    const before=result;
    if(database.execute(text,&result)) |_| return error.ExpectedFailure else |err| {
        if(err!=expected) std.debug.print("wanted {s}, got {s}\n",.{@errorName(expected),@errorName(err)});
        try check(err==expected);
    }
    try check(result.row_count==before.row_count and result.column_count==before.column_count);
    for(0..before.row_count) |row| for(0..before.column_count) |column| try check(DB.compareCells(&before.rows[row].cells[column],&result.rows[row].cells[column])==0);
}
const date_query="SELECT id-id,MIN(day),MAX(day),COUNT(day),COUNT(*) FROM facts GROUP BY id-id";
fn equalResult(expected:*const DB.Result) !void {
    try check(result.row_count==expected.row_count and result.column_count==expected.column_count);
    for(0..expected.row_count) |row| for(0..expected.column_count) |column|
        try check(DB.compareCells(&expected.rows[row].cells[column],&result.rows[row].cells[column])==0);
}
fn dateProjection(expected_gathered:usize) !void {
    try database.execute(date_query,&result);
    try check(database.workspace.query.stream_stats.gathered_rows==expected_gathered);
    try check(result.rows[0].cells[1]==.date and result.rows[0].cells[2]==.date);
    const expected=result;
    const valid=database.tables[0].summary.valid;database.tables[0].summary.valid=false;
    defer database.tables[0].summary.valid=valid;
    try database.execute(date_query,&result);try check(database.workspace.query.stream_stats.gathered_rows==0);
    try equalResult(&expected);
}
pub fn main() !void {
    var banks:[3]DB.StorageBacking=undefined;
    for(&banks,0..) |*bank,i| bank.*=.{.rows=&rows[i],.versions=&versions[i],.row_index=&row_indices[i],.key_index=&key_indices[i],.scan_values=&values[i],.scan_nonnull=&nonnull[i],.scan_live=&live[i]};
    try database.bindStorage(banks,&refs);
    try database.execute("CREATE TABLE facts(id INT PRIMARY KEY,store INT,product INT,day DATE,amount INT)",&result);
    try database.execute("CREATE TABLE products(id INT PRIMARY KEY,category INT)",&result);
    try database.execute("CREATE TABLE categories(id INT PRIMARY KEY,label TEXT)",&result);
    var buffer:[512]u8=undefined;
    for(0..4) |i| try database.execute(try std.fmt.bufPrint(&buffer,"INSERT INTO categories VALUES({d},'c{d}')",.{i,i}),&result);
    for(0..16) |i| try database.execute(try std.fmt.bufPrint(&buffer,"INSERT INTO products VALUES({d},{d})",.{i,i/4}),&result);
    for(0..n) |i| {
        var key:[24]u8=undefined;
        const product=if(i%17==0) "NULL" else try std.fmt.bufPrint(&key,"{d}",.{if(i%31==0) @as(usize,99) else i%16});
        try database.execute(try std.fmt.bufPrint(&buffer,"INSERT INTO facts VALUES({d},{d},{s},DATE '2025-{d:0>2}-15',{d})",.{i,i%8,product,i%12+1,@as(i64,@intCast(i))-128}),&result);
    }
    try dateProjection(n);const initial_dates=result;
    for(0..8) |store| {
        try database.execute(try std.fmt.bufPrint(&buffer,query,.{store}),&result);
        try model(@intCast(store),false,false,.eq);
        const stats=database.workspace.query.stream_stats;
        try check(stats.rows==n);
        std.debug.print("prefix store={d} dimension_probes={d} rejected={d}\n",.{store,stats.dimension_probes,stats.prefix_rejected});
        const selected:usize=n/8+@as(usize,@intFromBool(store<n%8));
        try check(stats.prefix_rejected==n-selected);
        try check(stats.dimension_probes<=2*selected);
    }
    const symbols=[_] []const u8{"=","<>","<","<=",">",">="};
    for([_]Op{.eq,.ne,.lt,.le,.gt,.ge},0..) |op,index| {
        const source=try std.fmt.bufPrint(&buffer,"SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store{s}3 AND f.day BETWEEN DATE '2025-03-01' AND DATE '2025-08-31' GROUP BY c.label ORDER BY c.label",.{symbols[index]});
        try database.execute(source,&result);try model(3,false,false,op);
        var selected:usize=0;for(0..n) |i| selected+=@intFromBool(matches(@intCast(i%8),3,op));
        try check(database.workspace.query.stream_stats.prefix_rejected==n-selected);
    }
    try database.execute("SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE 3<f.store AND f.day BETWEEN DATE '2025-03-01' AND DATE '2025-08-31' GROUP BY c.label ORDER BY c.label",&result);
    try model(3,false,false,.gt);try check(database.workspace.query.stream_stats.prefix_rejected>0);
    try database.execute("SELECT c.label,COUNT(*),SUM(f.amount) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store>=0 AND f.day BETWEEN DATE '2025-03-01' AND DATE '2025-08-31' GROUP BY c.label ORDER BY c.label",&result);
    try model(0,false,false,.ge);try check(database.workspace.query.stream_stats.prefix_rejected==0);
    // A rejected leading conjunct must retain SQL's error short-circuit. A
    // computed leading operand must never be moved past a later false guard.
    const protected="SELECT COUNT(*) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE f.store=99 AND 10/(f.amount-f.amount)>0";
    try database.execute(protected,&result);try check(result.rows[0].cells[0].integer==0);
    try check(database.workspace.query.stream_stats.dimension_probes==0);
    try rejected("SELECT COUNT(*) FROM facts f JOIN products p ON p.id=f.product JOIN categories c ON c.id=p.category WHERE 10/(f.amount-f.amount)>0 AND f.store=99",error.DivisionByZero);
    try rejected("SELECT COUNT(*) FROM facts f JOIN products p ON p.id=f.product AND 10/(f.amount-f.amount)>0 JOIN categories c ON c.id=p.category WHERE f.store=88 AND f.day>DATE '2025-03-01'",error.DivisionByZero);
    try check(database.workspace.query.stream_stats.prefix_rejected==0);
    try rejected("SELECT COUNT(*) FROM facts f JOIN products p ON p.id=10/(f.amount-f.amount) JOIN categories c ON c.id=p.category WHERE f.store=88 AND f.day>DATE '2025-03-01'",error.DivisionByZero);
    try check(database.workspace.query.stream_stats.prefix_rejected==0);
    try rejected("SELECT COUNT(*) FROM facts f JOIN products p ON p.id=f.product AND 10/(f.amount-f.amount)>0 WHERE f.store=88",error.DivisionByZero);
    try rejected("SELECT f.id FROM facts f JOIN products p ON p.id=f.product AND 10/(f.amount-f.amount)>0 WHERE f.store=88",error.DivisionByZero);
    // Old snapshots must ignore the newer committed projection.
    const reader=try database.begin();
    const old_snapshot:DB.Snapshot=.{.csn=database.csn};
    // Hold the same MVCC pin used by a parked statement. Idle READ COMMITTED
    // transactions deliberately do not retain their begin-time snapshot.
    database.txs[reader].pin=old_snapshot;
    try database.execute("UPDATE facts SET store=99 WHERE id=3",&result);
    try database.execute("UPDATE facts SET day=DATE '1900-01-01' WHERE id=0",&result);
    try database.execute("DELETE FROM facts WHERE id=16",&result);removed=16;
    const dense_hole=try std.fmt.bufPrint(&buffer,query,.{0});
    try database.execute(dense_hole,&result);try model(0,true,false,.eq);
    try check(database.workspace.query.stream_stats.rows==n-1 and database.workspace.query.stream_stats.prefix_rejected>0);
    const q3=try std.fmt.bufPrint(&buffer,query,.{3});
    var old_read:DB.ReadContext=.{};old_read.workspace.query.refs=&old_refs;
    try old_read.execute(&database,q3,old_snapshot,&result);try model(3,false,false,.eq);
    try check(old_read.workspace.query.stream_stats.prefix_rejected==0);
    try old_read.execute(&database,date_query,old_snapshot,&result);try equalResult(&initial_dates);
    try check(old_read.workspace.query.stream_stats.gathered_rows==0);
    try dateProjection(n-1);
    database.abort(reader);
    try database.execute(q3,&result);try model(3,true,false,.eq);
    try check(database.workspace.query.stream_stats.prefix_rejected>0);
    const writer=try database.begin();
    try database.statement(writer,"UPDATE facts SET store=99 WHERE id=4",&result,.{});
    const q99=try std.fmt.bufPrint(&buffer,query,.{99});
    try database.statement(writer,q99,&result,.{});try model(99,true,true,.eq);
    try check(database.workspace.query.stream_stats.prefix_rejected==0);
    database.abort(writer);
    try database.execute(q99,&result);try model(99,true,false,.eq);
    // Cancellation/work limits still fail before result publication; poisoned
    // scratch cannot become a selection mask in a later statement.
    var cancel:Cancel=.{};var control:sql.ExecutionControl=.{.context=&cancel,.poll=&Cancel.poll,.poll_interval=1};
    database.session.control=&control;
    try rejected(q99,error.QueryCanceled);database.session.control=null;try check(cancel.calls==10);
    control=.{.max_work=100};database.session.control=&control;
    try rejected(q99,error.QueryWorkLimit);database.session.control=null;
    @memset(&refs,0xaaaaaaaa);@memset(&database.workspace.query.cells,.{.integer=0x55555555});
    try database.execute(q99,&result);try model(99,true,false,.eq);
    const q0=try std.fmt.bufPrint(&buffer,query,.{0});
    try database.execute(q0,&result);try model(0,true,false,.eq);
    try check(database.workspace.query.stream_stats.rows==n-1);
    // NULL cannot be rejected like FALSE before a potentially throwing RHS.
    try database.execute("UPDATE facts SET store=NULL WHERE id=1",&result);
    try rejected(protected,error.DivisionByZero);
    try check(database.workspace.query.stream_stats.prefix_rejected==0);
    const usage=database.usage();try check(usage.transactions==0 and usage.row_locks==0 and usage.pending_versions==0);
    // An outer table's TEXT column must not disable an integral fact scan in
    // a different CTE plan sharing the expression pool. The computed key keeps
    // this on the general streaming path rather than a small dense rollup.
    try database.execute("WITH totals AS (SELECT store+0 AS k,COUNT(*) AS n,SUM(amount) AS total FROM facts GROUP BY store+0) SELECT c.label,SUM(t.n),SUM(t.total) FROM categories c JOIN totals t ON t.k%4=c.id GROUP BY c.label ORDER BY c.label",&result);
    var expected_counts:[4]i64=@splat(0);var expected_sums:[4]i64=@splat(0);
    for(0..n) |i| {
        if(i==1 or i==16) continue;
        expected_counts[i%4]+=1;expected_sums[i%4]+=@as(i64,@intCast(i))-128;
    }
    try check(result.row_count==4);
    for(0..4) |i| {
        try check(result.rows[i].cells[1]==.numeric and result.rows[i].cells[2]==.numeric);
        try check(result.rows[i].cells[1].numeric.coef()==expected_counts[i]);
        try check(result.rows[i].cells[2].numeric.coef()==expected_sums[i]);
    }
    std.debug.print("plan-local gathered={d} expected={d}\n",.{database.workspace.query.stream_stats.gathered_rows,n-1});
    try check(database.workspace.query.stream_stats.gathered_rows==n-1);
    // Walk every branch of nested expressions and aggregate FILTER roots.
    // Poisoned projection scratch must never substitute an uncollected column.
    @memset(&database.workspace.query.cells,.{.integer=0x44444444});
    try database.execute("WITH totals AS (SELECT id-id AS k,SUM(CASE WHEN store IN(0,1,99) THEN COALESCE(amount,0) ELSE -amount END) AS total,SUM(amount) FILTER(WHERE product IS NULL OR product BETWEEN 0 AND 3) AS chosen FROM facts GROUP BY id-id) SELECT c.label,t.total,t.chosen FROM categories c JOIN totals t ON c.id=t.k",&result);
    var signed_sum:i64=0;var filtered_sum:i64=0;
    for(0..n) |i| {
        if(i==16) continue;
        const amount=@as(i64,@intCast(i))-128;
        const positive=i!=1 and (i==3 or i%8==0 or i%8==1);
        signed_sum+=if(positive) amount else -amount;
        if(i%17==0 or (i%31!=0 and i%16<=3)) filtered_sum+=amount;
    }
    try check(result.row_count==1 and std.mem.eql(u8,result.rows[0].cells[0].text.slice(),"c0"));
    try check(result.rows[0].cells[1].integer==signed_sum and result.rows[0].cells[2].integer==filtered_sum);
    try check(database.workspace.query.stream_stats.gathered_rows==n-1);
    // DATE projection reconstructs the exact typed Cell, rather than returning
    // an integer with the same payload or fetching a full inline version.
    try database.execute(q0,&result);try model(0,true,false,.eq);
    try check(database.workspace.query.stream_stats.gathered_rows>0);
    // Nullable dates, pre-epoch values and private/aborted writes preserve both
    // the exact payload and its DATE tag. Publication alone updates projection.
    try database.execute("UPDATE facts SET day=NULL WHERE id=2",&result);
    try dateProjection(n-1);const committed_dates=result;
    const date_writer=try database.begin();
    try database.statement(date_writer,"UPDATE facts SET day=DATE '2200-12-31' WHERE id=4",&result,.{});
    try database.statement(date_writer,date_query,&result,.{});
    try check(database.workspace.query.stream_stats.gathered_rows==0 and DB.compareCells(&result.rows[0].cells[2],&committed_dates.rows[0].cells[2])>0);
    database.abort(date_writer);try dateProjection(n-1);try equalResult(&committed_dates);
    date_before_flush=database.tables[0].scan_values[3*database.tables[0].rows.len+4];
    var used:usize=0;
    if(database.executeChanges("UPDATE facts SET day=DATE '2200-12-31' WHERE id=4",&result,&change_record,&used,null,rejectDateFlush)) |_| return error.ExpectedFlushFailure
        else |err| try check(err==error.InjectedDateFlushFailure);
    try check(used==0);try dateProjection(n-1);try equalResult(&committed_dates);
    @memset(&copy_memory,0xa5);try copied.bindMemory(&copy_memory,n+1,(n+1)*2,2048);
    try copied.copyFromInto(&database);try copied.execute(date_query,&result);
    try equalResult(&committed_dates);try check(copied.workspace.query.stream_stats.gathered_rows==n-1);
    var replay_scratch:DB.ReplayScratch=.{};
    for([_][]const u8{"UPDATE facts SET day=DATE '-infinity' WHERE id=0","UPDATE facts SET day=DATE 'infinity' WHERE id=4","UPDATE facts SET day=DATE '0001-01-01 BC' WHERE id=3","DELETE FROM facts WHERE id=5"}) |statement| {
        used=0;try database.executeChanges(statement,&result,&change_record,&used,null,null);
        try copied.applyChangeRecord(change_record[0..used],&replay_scratch);
        const remaining:usize=if(std.mem.startsWith(u8,statement,"DELETE")) n-2 else n-1;
        try dateProjection(remaining);const expected=result;
        try copied.execute(date_query,&result);try equalResult(&expected);
        try check(copied.workspace.query.stream_stats.gathered_rows==remaining);
    }
    std.debug.print("PASS stream prefix: {d} assertions, typed dates, exact independent row model, partial blocks, snapshots, NULL/error ordering and cancellation\n",.{assertions});
}
