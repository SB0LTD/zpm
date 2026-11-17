//! Real SQL execution with private contexts over one shared immutable database.
const std=@import("std");
const sql=@import("sql");
const workers=@import("worker_thread");
const stores=@import("db_store");
const cfg:sql.Config=.{.external_storage=true,.external_workspace=true,.external_results=true,.tables=3,.columns=4,
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
const Cache = DB.ReadResultCache;
var cache: Cache = undefined;
var cache_entries: [16]Cache.Entry = undefined;
var cache_keys: [16 * 512]u8 = undefined;
var cache_rows: [16 * 16]DB.Row = undefined;
const one_cache_layout = Cache.layout(1, 512, 16) catch unreachable;
var cache_memory: [one_cache_layout.bytes + 1]u8 align(16) = undefined;
const grouped = "SELECT cat AS category, COUNT(DISTINCT amount) AS samples, SUM(amount) AS total FROM points GROUP BY cat ORDER BY cat";
const concurrent_grouped = "SELECT cat, COUNT(*), SUM(amount * 2) AS weighted FROM points GROUP BY cat ORDER BY cat";
fn insideExecution(raw:?*anyopaque) DB.SqlError!void {
    const index:u5=@intCast(@intFromPtr(raw.?)-1);
    _=arrivals.fetchOr(@as(u32,1)<<index,.acq_rel);
    while(arrivals.load(.acquire)!=255) std.atomic.spinLoopHint();
}
fn canceled(_: ?*anyopaque) DB.SqlError!void {return error.QueryCanceled;}
fn check(ok:bool) !void {assertions+=1;if(!ok) {std.debug.print("parallel assertion {d} failed\n",.{assertions});return error.ParallelReadContract;}}
fn rejected(comptime expected:anyerror,actual:anytype) !void {
    if(actual) |_| return error.ExpectedFailure else |err| {if(err!=expected) std.debug.print("expected {s}, got {s}\n",.{@errorName(expected),@errorName(err)});try check(err==expected);}
}
fn queries(index:usize) !void {
    const context=&contexts[index];const result=&results[index];var text:[512]u8=undefined;
    for(0..50) |trial| {
        const id=(index*17+trial)%128;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT amount FROM points WHERE id={d}",.{id}),snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[0].integer!=@as(i64,@intCast(id))*7-23) return error.ParallelReadContract;
        const category=(index+trial)%8;
        var total:i64=0;for(0..16) |row| total+=@as(i64,@intCast(category+row*8))*7-23;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT COUNT(DISTINCT amount),SUM(amount) FROM points WHERE cat={d}",.{category}),snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[0].integer!=16 or result.rows[0].cells[1].integer!=total) return error.ParallelReadContract;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT p.cat,COUNT(*),SUM(p.amount*q.unit) FROM points p JOIN products q ON q.id=p.cat WHERE p.cat={d} GROUP BY p.cat",.{category}),snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[1].integer!=16 or result.rows[0].cells[2].integer!=total*@as(i64,@intCast(10+category))) return error.ParallelReadContract;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT id FROM points WHERE cat={d} ORDER BY amount DESC,id LIMIT 3",.{category}),snapshot,result);
        if(result.row_count!=3) return error.ParallelReadContract;
        for(0..3) |row| if(result.rows[row].cells[0].integer!=category+(15-row)*8) return error.ParallelReadContract;
        try context.execute(db,try std.fmt.bufPrint(&text,"SELECT id,amount FROM points WHERE cat={d} AND amount>0",.{category}),snapshot,result);
        var expected_rows:usize=0;
        for(0..128) |candidate| {
            const amount=@as(i64,@intCast(candidate))*7-23;
            if(candidate%8!=category or amount<=0) continue;
            if(result.rows[expected_rows].cells[0].integer!=candidate or result.rows[expected_rows].cells[1].integer!=amount) return error.ParallelReadContract;
            expected_rows+=1;
        }
        if(result.row_count!=expected_rows or context.workspace.query.read_stats.projected_filter_scans!=1) return error.ParallelReadContract;
        try context.execute(db,"SELECT COUNT(*) FROM points p WHERE p.id IN(SELECT q.id FROM products q)",snapshot,result);
        if(result.row_count!=1 or result.rows[0].cells[0].integer!=8) return error.ParallelReadContract;
        _=completed.fetchAdd(6,.monotonic);
    }
}
fn entry(raw:?*anyopaque) void {
    const index:usize=@intFromPtr(raw.?)-1;
    queries(index) catch {failed.store(true,.release);};
}

fn cachedRead(context: *DB.ReadContext, result: *DB.Result, source: []const u8) !void {
    try context.prepare(db, source, .{ .csn = db.csn });
    try context.runCached(result, &cache);
}

fn cacheReader(raw: ?*anyopaque) void {
    const index = @intFromPtr(raw.?) - 1;
    const context = &contexts[index];
    const result = &results[index];
    context.session = .{};
    for (0..24) |_| {
        cachedRead(context, result, concurrent_grouped) catch {
            failed.store(true, .release);
            return;
        };
        if (result.row_count != 8 or result.column_count != 3) {
            failed.store(true, .release);
            return;
        }
        for (result.rows[0..result.row_count], 0..) |*row, category| {
            if (row.cells[0] != .integer or row.cells[0].integer != category or row.cells[1] != .integer or
                row.cells[1].integer != (if (category == 0) @as(i64, 17) else 16) or row.cells[2] != .integer) {
                failed.store(true, .release);
                return;
            }
        }
    }
}

fn resultCacheContracts() !void {
    const context = &contexts[0];
    const result = &results[0];
    context.session = .{};
    try rejected(error.InvalidParameterValue, cache.init(db, &cache_entries, backing[0..cache_keys.len], &cache_rows, 16));
    try cache.init(db, &cache_entries, &cache_keys, &cache_rows, 16);
    store.read_result_cache = &cache;
    defer store.read_result_cache = null;

    // The cache owns key bytes and copies the same typed rows/metadata into
    // separate result backing. A cold run still executes and produces rows.
    var query_bytes: [grouped.len]u8 = undefined;
    @memcpy(&query_bytes, grouped);
    try cachedRead(context, result, &query_bytes);
    try check(!context.last_result_reused and result.row_count == 8 and result.column_count == 3);
    @memset(&query_bytes, ' ');
    const first_sum = result.rows[0].cells[2].integer;
    var connection: Store.Connection = .{ .store = &store, .id = 72, .read_context = context };
    try context.prepare(db, grouped, .{ .csn = db.csn });
    try connection.execute(grouped, result);
    try check(context.last_result_reused and result.rows[0].cells[2].integer == first_sum);
    try check(result.column_types[2] == .integer and result.column_typmods[2] == -1 and std.mem.eql(u8, result.column_names[0].slice(), "category"));
    try cachedRead(&contexts[1], &results[1], grouped);
    try check(contexts[1].last_result_reused and results[1].rows[0].cells[2].integer == first_sum);
    results[1].rows[0].cells[2] = .{ .integer = -1 };
    try cachedRead(context, result, grouped);
    try check(context.last_result_reused and result.rows[0].cells[2].integer == first_sum);
    context.session.database = "another_database";
    try cachedRead(context, result, grouped);
    try check(!context.last_result_reused);
    context.session.database = "postgres";
    try cachedRead(context, result, grouped);
    try check(context.last_result_reused);

    // A hit must not elide real cancellation or change a smaller scratch or
    // result limit into success. Ordinary failure leaves the entry usable.
    var cancel: DB.ExecutionControl = .{ .poll = canceled };
    context.session.control = &cancel;
    try rejected(error.QueryCanceled, context.runCached(result, &cache));
    try check(!context.last_result_reused and result.rows[0].cells[2].integer == first_sum);
    var limited: DB.ExecutionControl = .{ .max_work = 1 };
    context.session.control = &limited;
    try rejected(error.QueryWorkLimit, context.runCached(result, &cache));
    try check(!context.last_result_reused);
    context.session.control = null;
    try result.bindMemory(&output[0], 1);
    try rejected(error.RowCapacity, context.runCached(result, &cache));
    try check(!context.last_result_reused);
    try result.bindMemory(&output[0], 32);

    context.session.zone = .{ .kind = .fixed, .offset = 3600 };
    try cachedRead(context, result, grouped);
    try check(!context.last_result_reused);
    context.session.zone = .{};
    connection.settings.statement_timeout_ms = 100;
    try connection.execute(grouped, result);
    try check(!context.last_result_reused);
    connection.settings.statement_timeout_ms = 0;
    try connection.engine_session.values.search_path.set("public");
    try connection.execute(grouped, result);
    try check(!context.last_result_reused);
    connection.engine_session.values = .{};

    const clock_query = "SELECT COUNT(*), statement_timestamp() FROM points";
    context.session.statement_us = 1000;
    try cachedRead(context, result, clock_query);
    try check(!context.last_result_reused and result.rows[0].cells[1].timestamptz == 1000);
    context.session.statement_us = 2000;
    try cachedRead(context, result, clock_query);
    try check(!context.last_result_reused and result.rows[0].cells[1].timestamptz == 2000);

    try db.execute("UPDATE points SET amount=0 WHERE id=0", &main_result);
    try cachedRead(context, result, grouped);
    try check(!context.last_result_reused and result.rows[0].cells[2].integer == first_sum + 23);
    try cachedRead(context, result, grouped);
    try check(context.last_result_reused);
    try db.execute("CREATE ROLE cache_reader", &main_result);
    try cachedRead(context, result, grouped);
    try check(!context.last_result_reused);
    try cachedRead(context, result, grouped);
    try check(context.last_result_reused);
    connection.engine_session.session_role = db.catalog_objects.roleByName("cache_reader", .{ .csn = db.csn }).?;
    try rejected(error.InvalidParameterValue, connection.execute(grouped, result));
    connection.read_context = null;
    try check(!connection.detachedReadEligible());
    try rejected(error.InsufficientPrivilege, connection.execute(grouped, result));
    connection.disconnect();
    db.session_state = null;
    try db.execute("GRANT SELECT ON points TO cache_reader", &main_result);
    try cachedRead(context, result, grouped);
    try check(!context.last_result_reused);
    try cachedRead(context, result, grouped);
    try check(context.last_result_reused);

    try db.execute("ALTER TABLE points ADD COLUMN report_day DATE DEFAULT DATE '2025-04-11'", &main_result);
    try cachedRead(context, result, grouped);
    try check(!context.last_result_reused);
    const calendar = "SELECT to_char(report_day,'YYYY-MM'), COUNT(*) FROM points WHERE report_day BETWEEN DATE '2025-04-01' AND DATE '2025-04-30' GROUP BY 1 ORDER BY 1";
    try cachedRead(context, result, calendar);
    try check(!context.last_result_reused and result.row_count == 1 and result.rows[0].cells[1].integer == 129);
    try cachedRead(context, result, calendar);
    try check(context.last_result_reused and std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "2025-04"));
    const window = "WITH amounts AS (SELECT cat, SUM(amount) AS total FROM points GROUP BY cat) SELECT cat, RANK() OVER (ORDER BY total DESC), ROUND(AVG(total) OVER (),2) FROM amounts ORDER BY cat";
    try cachedRead(context, result, window);
    try check(!context.last_result_reused and result.row_count == 8);
    try cachedRead(context, result, window);
    try check(context.last_result_reused and result.column_types[2] == .numeric);
    try cachedRead(context, result, "SELECT COUNT(*) FROM pg_class");
    try cachedRead(context, result, "SELECT COUNT(*) FROM pg_class");
    try check(!context.last_result_reused);

    if (workers.available) {
        var threads: [8]workers.Thread = @splat(.{});
        var started: usize = 0;
        defer for (threads[0..started]) |*thread| thread.join() catch @panic("live cache reader");
        for (&threads, 0..) |*thread, index| {
            try thread.start(cacheReader, @ptrFromInt(index + 1));
            started += 1;
        }
        for (&threads) |*thread| try thread.join();
        started = 0;
    } else for (0..8) |index| cacheReader(@ptrFromInt(index + 1));
    try check(!failed.load(.acquire));
    try cachedRead(context, result, concurrent_grouped);
    try check(context.last_result_reused);

    try rejected(error.WorkspaceCapacity, Cache.layoutForBytes(one_cache_layout.bytes - 1, 512, 16));
    const selected = try Cache.layoutForBytes(one_cache_layout.bytes + 1, 512, 16);
    try check(selected.entries == 1 and selected.bytes == one_cache_layout.bytes);
    try rejected(error.InvalidParameterValue, Cache.layout(~@as(usize, 0), 512, 16));
    try rejected(error.WorkspaceCapacity, cache.bindMemory(db, cache_memory[0 .. selected.bytes - 1], selected.entries, 512, 16));
    try rejected(error.InvalidParameterValue, cache.bindMemory(db, cache_memory[1..], selected.entries, 512, 16));
    try cache.bindMemory(db, &cache_memory, selected.entries, 512, 16);
    const by_store = "SELECT COUNT(*), SUM(amount) FROM points WHERE cat=0";
    try cachedRead(context, result, by_store);
    try check(!context.last_result_reused and result.rows[0].cells[0].integer == 17);
    try cachedRead(context, result, by_store);
    try check(context.last_result_reused);
    try cachedRead(context, result, "SELECT COUNT(*), SUM(amount) FROM points WHERE cat=1");
    try check(!context.last_result_reused and result.rows[0].cells[0].integer == 16);
    try cachedRead(context, result, by_store);
    try check(!context.last_result_reused and result.rows[0].cells[0].integer == 17);
    const stats = cache.stats();
    try check(stats.hits == 1 and stats.misses == 3 and stats.publications == 3 and stats.contention == 0);
}

pub fn main(init:std.process.Init) !void {
    inline for(.{"SELECT 1","\t\x0bselect 1","-- reviewer\r\n SELECT 1","/* outer /* nested */ tail */ WITH q AS(SELECT 1) SELECT * FROM q"}) |source| try check(DB.queryCandidate(source));
    inline for(.{"","-- only comment","/* unfinished","/* x */ UPDATE points SET amount=0","\"select\"","SELECTOR","BEGIN","'SELECT 1'"}) |source| try check(!DB.queryCandidate(source));
    try db.bindMemory(&backing,512,1024,8192);try db.bindWorkspace(&main_scratch);
    try main_result.bindMemory(&main_output,32);
    try db.execute("CREATE TABLE points(id INT PRIMARY KEY,cat INT NOT NULL,amount INT NOT NULL)",&main_result);
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
    try check(!failed.load(.acquire) and completed.load(.acquire)==2400);
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
    try result.bindMemory(backing[0..32*@sizeOf(DB.Row)],32);
    try rejected(error.InvalidParameterValue,context.execute(db,"SELECT 1",snapshot,result));
    try result.bindMemory(&output[0],32);
    try context.execute(db,"SELECT COUNT(*) FROM points",snapshot,result);
    try check(result.rows[0].cells[0].integer==128);
    try context.execute(db,"SELECT COUNT(*) FROM pg_class",snapshot,result);
    try check(result.rows[0].cells[0].integer==4);
    for ([_][]const u8{
        "SELECT to_regclass('points')",
        "SELECT 'points'::regclass",
        "SELECT 1259::regclass::text",
        "SELECT pg_get_serial_sequence('points','id')",
        "SELECT (SELECT to_regclass('points'))",
        "WITH names AS (SELECT 'points'::regclass AS relation) SELECT relation FROM names",
        "SELECT current_setting('TimeZone')",
        "SELECT set_config('application_name','detached',false)",
        "SELECT pg_backend_pid()",
        "SELECT pg_try_advisory_lock(91)",
    }) |statement| {
        try context.describe(db, statement, snapshot, result);
        try check(result.row_count == 0 and result.column_count == 1);
        try rejected(error.InvalidParameterValue, context.run(result));
        try rejected(error.UnsupportedStatement, context.prepare(db, statement, snapshot));
    }
    try context.execute(db, "SELECT 'integer'::regtype::text", snapshot, result);
    try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "integer"));
    try context.execute(db,"SELECT COUNT(*) FROM points",snapshot,result);
    var connection:Store.Connection=.{.store=&store,.id=7,.read_context=context};
    try connection.execute("SELECT COUNT(*) FROM points",result);
    try check(result.rows[0].cells[0].integer==128 and connection.valueSession()==&context.session);
    const shared_nodes=db.workspace.nodes.len;
    try connection.describe("SELECT id AS identity, amount FROM points",result);
    try check(result.row_count==0 and result.column_count==2 and std.mem.eql(u8,result.column_names[0].slice(),"identity"));
    try check(db.workspace.nodes.len==shared_nodes);
    try connection.describe("SELECT 1/0 AS unevaluated",result);
    try check(result.row_count==0 and result.column_count==1);
    try rejected(error.DivisionByZero,connection.execute("SELECT 1/0 AS unevaluated",result));
    try connection.describe("SELECT sqrt(-1::numeric) WHERE FALSE",result);
    try check(result.row_count==0 and result.column_count==1 and result.column_types[0]==.numeric);
    try rejected(error.InvalidParameterValue,context.run(result));
    try rejected(error.InvalidArgumentForPowerFunction,connection.execute("SELECT sqrt(-1::numeric) WHERE FALSE",result));
    try rejected(error.ColumnNotFound,connection.describe("SELECT 1/0,missing FROM points",result));
    try connection.describe("SELECT 1 AS reusable",result);
    try check(result.row_count==0 and result.column_count==1);
    try connection.execute("SELECT 1 AS reusable",result);
    try check(result.row_count==1 and result.rows[0].cells[0].integer==1);

    try connection.describe("WITH p AS(SELECT id,amount FROM points) SELECT id,amount FROM p",result);
    try check(result.row_count==0 and result.column_count==2);
    try rejected(error.UnsupportedStatement,connection.describe("DELETE FROM points",result));
    connection.in_transaction=true;
    try rejected(error.InvalidParameterValue,connection.execute("SELECT COUNT(*) FROM points",result));
    connection.in_transaction=false;connection.read_context=null;
    try check(connection.detachedReadEligible());
    var limited:DB.ExecutionControl=.{};limited.reset(1);context.session.control=&limited;
    try rejected(error.QueryWorkLimit,context.execute(db,"SELECT SUM(amount+1) FROM points",snapshot,result));
    var cancel:DB.ExecutionControl=.{.poll=canceled};context.session.control=&cancel;
    try rejected(error.QueryCanceled,context.prepare(db,"SELECT COUNT(*) FROM points",snapshot));
    connection.read_context=context;
    try rejected(error.QueryCanceled,connection.execute("SELECT COUNT(*) FROM points",result));
    try rejected(error.QueryCanceled,connection.describe("SELECT COUNT(*) FROM points",result));
    connection.read_context=null;
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
    const before_insert=db.csn;
    try context.execute(db,"SELECT SUM(amount*2) FROM points",.{.csn=before_insert},result);
    try check(result.rows[0].cells[0].integer==107904 and context.workspace.query.stream_stats.gathered_rows==128);
    try db.execute("INSERT INTO points VALUES(200,0,42)",&main_result);
    try context.execute(db,"SELECT SUM(amount*2) FROM points",.{.csn=before_insert},result);
    try check(result.rows[0].cells[0].integer==107904 and context.workspace.query.stream_stats.gathered_rows==0);
    try context.execute(db,"SELECT SUM(amount*2) FROM points",.{.csn=db.csn},result);
    try check(result.rows[0].cells[0].integer==107988 and context.workspace.query.stream_stats.gathered_rows==129);
    try resultCacheContracts();
    const message=try std.fmt.bufPrint(&text,"PASS isolated SQL read contexts: {d} assertions, {d} real queries, native_threads={s}; server integration not claimed\n",
        .{assertions,completed.load(.acquire),if(workers.available) "8" else "0"});
    try std.Io.File.stdout().writeStreamingAll(init.io,message);
}
