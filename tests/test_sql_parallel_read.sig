//! Real SQL execution with private contexts over one shared immutable database.
const std=@import("std");
const sql=@import("sql");
const workers=@import("worker_thread");
const stores=@import("db_store");
const cfg:sql.Config=.{.external_storage=true,.external_workspace=true,.external_results=true,.tables=2,.columns=4,
    .rows_per_table=128,.work_rows=512,.result_rows=32,.text_bytes=24,.expr_nodes=256,.tx_writes=256,.compact_integral_scans=true};
const DB=sql.Database(cfg);
const main_bytes=DB.backingBytes(512,1024,8192) catch unreachable;
const scratch_bytes=DB.ReadContext.backingBytes(512) catch unreachable;
var backing:[main_bytes]u8 align(16)=undefined;
var main_scratch:[512*8]DB.Cell=undefined;
const Store=stores.Store(DB);
var store:Store=.{};
const db=&store.database;
var main_result:DB.Result=.{};
var main_output:[32*@sizeOf(DB.Row)]u8 align(16)=undefined;
var contexts:[8]DB.ReadContext=@splat(.{});
var scratch:[8][scratch_bytes]u8 align(16)=undefined;
var results:[8]DB.Result=@splat(.{});
var output:[8][32*@sizeOf(DB.Row)]u8 align(16)=undefined;
var failed:std.atomic.Value(bool)=.init(false);
var completed:std.atomic.Value(u32)=.init(0);
var snapshot:DB.Snapshot=.{.csn=0};
var assertions:usize=0;
var arrivals:std.atomic.Value(u32)=.init(0);
var controls:[8]DB.ExecutionControl=@splat(.{});
fn insideExecution(raw:?*anyopaque) DB.SqlError!void {
    const index:u5=@intCast(@intFromPtr(raw.?)-1);
    _=arrivals.fetchOr(@as(u32,1)<<index,.acq_rel);
    while(arrivals.load(.acquire)!=255) std.atomic.spinLoopHint();
}
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.ParallelReadContract;}
fn rejected(comptime expected:anyerror,actual:anytype) !void {
    if(actual) |_| return error.ExpectedFailure else |err| try check(err==expected);
}
fn queries(index:usize) !void {
    const context=&contexts[index];const result=&results[index];var text:[512]u8=undefined;
    for(0..50) |trial| {
        const id=(index*17+trial)%128;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT amount FROM points WHERE id={d}",.{id}),snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[0].integer!=@as(i64,@intCast(id))*7-23) return error.ParallelReadContract;
        const category=(index+trial)%8;
        var total:i64=0;for(0..16) |row| total+=@as(i64,@intCast(category+row*8))*7-23;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT COUNT(*),SUM(amount) FROM points WHERE cat={d}",.{category}),snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[0].integer!=16 or result.rows[0].cells[1].integer!=total) return error.ParallelReadContract;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT p.cat,COUNT(*),SUM(p.amount*q.unit) FROM points p JOIN products q ON q.id=p.cat WHERE p.cat={d} GROUP BY p.cat",.{category}),snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[1].integer!=16 or result.rows[0].cells[2].integer!=total*@as(i64,@intCast(10+category))) return error.ParallelReadContract;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT id FROM points WHERE cat={d} ORDER BY amount DESC,id LIMIT 3",.{category}),snapshot,result);
        if(result.row_count!=3) return error.ParallelReadContract;
        for(0..3) |row| if(result.rows[row].cells[0].integer!=category+(15-row)*8) return error.ParallelReadContract;
        try context.execute(db,"SELECT COUNT(*) FROM points p WHERE p.id IN(SELECT q.id FROM products q)",snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[0].integer!=8) return error.ParallelReadContract;
        _=completed.fetchAdd(5,.monotonic);
    }
}
fn entry(raw:?*anyopaque) void {
    const index:usize=@intFromPtr(raw.?)-1;
    queries(index) catch {failed.store(true,.release);};
}
pub fn main(init:std.process.Init) !void {
    try db.bindMemory(&backing,512,1024,8192);try db.bindWorkspace(&main_scratch);
    try main_result.bindMemory(&main_output,32);
    try db.execute("CREATE TABLE points(id INT PRIMARY KEY,cat INT,amount INT)",&main_result);
    try db.execute("CREATE TABLE products(id INT PRIMARY KEY,unit INT)",&main_result);
    var text:[256]u8=undefined;
    for(0..128) |id| try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO points VALUES({d},{d},{d})",.{id,id%8,@as(i64,@intCast(id))*7-23}),&main_result);
    for(0..8) |id| try db.execute(try std.fmt.bufPrint(&text,"INSERT INTO products VALUES({d},{d})",.{id,10+id}),&main_result);
    for(&contexts,0..) |*context,index| {
        try context.bindMemory(&scratch[index],512);try results[index].bindMemory(&output[index],32);
        controls[index]=.{.context=@ptrFromInt(index+1),.poll=insideExecution};
        context.session.control=&controls[index];
    }
    snapshot=.{.csn=db.csn};
    const original_csn=db.csn;const original_nodes=db.workspace.nodes.len;const original_epoch=db.epoch;
    if(workers.available) {
        var threads:[8]workers.Thread=@splat(.{});var started:usize=0;
        defer {arrivals.store(255,.release);for(threads[0..started]) |*thread| thread.join() catch @panic("live SQL read owner");}
        for(&threads,0..) |*thread,index| {try thread.start(entry,@ptrFromInt(index+1));started+=1;}
        for(&threads) |*thread| try thread.join();started=0;
    } else {arrivals.store(255,.release);for(0..8) |index| try queries(index);}
    try check(!failed.load(.acquire) and completed.load(.acquire)==2000);
    try check(db.csn==original_csn and db.epoch==original_epoch and db.workspace.nodes.len==original_nodes);
    const context=&contexts[0];const result=&results[0];
    for([_] []const u8{"INSERT INTO points VALUES(200,0,1)","DELETE FROM points","SELECT id FROM points FOR UPDATE","SELECT nextval('unowned')"}) |statement| {
        if(context.execute(db,statement,snapshot,result)) |_| return error.UnsafeReadAccepted else |_| {}
    }
    try check(db.csn==original_csn and db.epoch==original_epoch);
    const nodes_before=context.workspace.nodes.len;
    const alias_text="SELECT 1";
    @memcpy(scratch[0][0..alias_text.len],alias_text);
    try rejected(error.InvalidParameterValue,context.execute(db,scratch[0][0..alias_text.len],snapshot,result));
    try check(context.workspace.nodes.len==nodes_before);
    try result.bindMemory(scratch[0][0..32*@sizeOf(DB.Row)],32);
    try rejected(error.InvalidParameterValue,context.execute(db,"SELECT 1",snapshot,result));
    try result.bindMemory(&output[0],32);
    try context.bindMemory(backing[0..scratch_bytes],512);
    try rejected(error.InvalidParameterValue,context.execute(db,"SELECT 1",snapshot,result));
    try context.bindMemory(&scratch[0],512);
    try context.execute(db,"SELECT COUNT(*) FROM points",snapshot,result);
    try check(result.rows[0].cells[0].integer==128);
    try context.execute(db,"SELECT COUNT(*) FROM pg_class",snapshot,result);
    try check(result.rows[0].cells[0].integer==4);
    try context.execute(db,"SELECT COUNT(*) FROM points",snapshot,result);
    var connection:Store.Connection=.{.store=&store,.id=7,.read_context=context};
    try connection.execute("SELECT COUNT(*) FROM points",result);
    try check(result.rows[0].cells[0].integer==128 and connection.valueSession()==&context.session);
    connection.in_transaction=true;
    try rejected(error.InvalidParameterValue,connection.execute("SELECT COUNT(*) FROM points",result));
    connection.in_transaction=false;connection.read_context=null;
    try check(connection.detachedReadEligible());
    var limited:DB.ExecutionControl=.{};limited.reset(1);context.session.control=&limited;
    try rejected(error.QueryWorkLimit,context.execute(db,"SELECT SUM(amount+1) FROM points",snapshot,result));
    context.session.control=null;
    const slot=try db.begin();
    try db.statement(slot,"INSERT INTO points VALUES(200,0,42)",&main_result,.{});
    try context.execute(db,"SELECT COUNT(*) FROM points",.{.csn=db.csn},result);
    try check(result.rows[0].cells[0].integer==128);
    try context.execute(db,"SELECT COUNT(*) FROM points",.{.csn=db.csn,.slot=slot,.epoch=db.txs[slot].epoch,.cid=db.txs[slot].cid+1},result);
    try check(result.rows[0].cells[0].integer==129);
    db.abort(slot);
    try db.execute("CREATE SEQUENCE read_sequence",&main_result);
    if(context.execute(db,"SELECT nextval('read_sequence')",.{.csn=db.csn},result)) |_| return error.SequenceMutationAccepted else |_| {}
    try db.execute("SELECT nextval('read_sequence')",&main_result);
    try check(main_result.rows[0].cells[0].integer==1);
    const message=try std.fmt.bufPrint(&text,"PASS isolated SQL read contexts: {d} assertions, {d} real queries, native_threads={s}; server integration not claimed\n",
        .{assertions,completed.load(.acquire),if(workers.available) "8" else "0"});
    try std.Io.File.stdout().writeStreamingAll(init.io,message);
}
