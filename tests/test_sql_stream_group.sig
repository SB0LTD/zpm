//! Input cardinality must not determine scratch for eligible aggregates.
//! Caller buffers contain 100K rows but only 1024 query handles. Results use
//! independent integer models; failure paths preserve the previous result.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .external_storage = true, .tables = 1, .columns = 4,
    .rows_per_table = 4, .text_bytes = 32, .integer_bits = 32,
    .work_rows = 128, .result_rows = 128 });
const count = 100000;
var rows: [count]DB.StorageRowSlot = undefined;
var versions: [count * 2]DB.StorageVersion = undefined;
var row_index: [262144]u32 = undefined;
var key_index: [524288]u32 = undefined;
var refs: [1024]u32 = undefined;
var db: DB = .{};
var result: DB.Result = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) { std.debug.print("stream-group assertion {d} failed\n", .{assertions}); return error.StreamGroupContractFailed; }
}

fn grouped(n: usize) !void {
    try db.execute("SELECT g, COUNT(*), SUM(n) FROM data GROUP BY g ORDER BY g", &result);
    try check(result.row_count == 64);
    for (0..64) |g| {
        const size = (n - 1 - g) / 64 + 1;
        const sum = size * g + 64 * size * (size - 1) / 2;
        try check(result.rows[g].cells[0].integer == g);
        try check(result.rows[g].cells[1].integer == size);
        try check(result.rows[g].cells[2].integer == sum);
    }
    try check(db.workspace.query.stream_stats.rows == n);
    try check(db.workspace.query.stream_stats.groups == 64);
    try check(db.workspace.query.stream_stats.probes == n and db.workspace.query.stream_stats.dense_plans == 1);
}

fn rejected(source: []const u8, expected: sql.Error) !void {
    const before = result;
    if (db.execute(source, &result)) |_| return error.FailureExpected else |err| try check(err == expected);
    try check(result.row_count == before.row_count and result.column_count == before.column_count);
    for (0..before.row_count) |r| for (0..before.column_count) |c| {
        try check(DB.compareCells(&result.rows[r].cells[c], &before.rows[r].cells[c]) == 0);
    };
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.pending_versions == 0);
}

const Cancel = struct {
    calls: usize = 0,
    fn poll(context: ?*anyopaque) sql.Error!void {
        const self: *Cancel = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls == 25) return error.QueryCanceled;
    }
};

fn large() !void {
    try db.bindStorage(.{.{ .rows = &rows, .versions = &versions,
        .row_index = &row_index, .key_index = &key_index }}, &refs);
    try db.execute("CREATE TABLE data (id INT PRIMARY KEY, g INT, n INT, label TEXT)", &result);
    try db.execute("SELECT COUNT(*), SUM(n), MIN(n) FROM data", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 0 and result.rows[0].cells[1] == .null_value and result.rows[0].cells[2] == .null_value);
    try db.execute("SELECT g, COUNT(*) FROM data GROUP BY g", &result);
    try check(result.row_count == 0);
    var text: [192]u8 = undefined;
    for (0..512) |i| try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO data VALUES ({d},{d},{d},'value')", .{i,i%64,i}), &result);
    try grouped(512);
    const small_stats = db.workspace.query.stream_stats;
    for (512..count) |i| try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO data VALUES ({d},{d},{d},'value')", .{i,i%64,i}), &result);
    try grouped(count);
    try check(db.workspace.query.stream_stats.scratch_cells == small_stats.scratch_cells);
    try check(db.workspace.query.stream_stats.scratch_refs == small_stats.scratch_refs);
    try check(db.workspace.query.stream_stats.scratch_refs <= refs.len);
    try db.execute("SELECT COUNT(*), SUM(n), MIN(n), MAX(n) FROM data", &result);
    try check(result.rows[0].cells[0].integer == count and result.rows[0].cells[1].integer == @as(i64, count)*(count-1)/2 and result.rows[0].cells[2].integer == 0 and result.rows[0].cells[3].integer == count-1);
    try check(db.workspace.query.stream_stats.scratch_refs == 0);
    try db.execute("SELECT COUNT(*) FROM data LIMIT 1", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == count and db.workspace.query.stream_stats.rows == 0 and db.workspace.query.stream_stats.summary_rows == count);
    try db.execute("SELECT COUNT(*) FROM data LIMIT 1 OFFSET 1", &result);
    try check(result.row_count == 0 and db.workspace.query.stream_stats.rows == 0 and db.workspace.query.stream_stats.summary_rows == count);
    try db.execute("SELECT g, label, COUNT(*) FROM data GROUP BY g, label ORDER BY g", &result);
    try check(result.row_count == 64 and result.rows[7].cells[1] == .text and result.rows[7].cells[2].integer == (count-1-7)/64+1);
    try db.execute("SELECT g FROM data WHERE id < 256 GROUP BY g HAVING SUM(n) >= 0 ORDER BY g DESC LIMIT 4", &result);
    try check(result.row_count == 4 and result.rows[0].cells[0].integer == 63 and result.rows[3].cells[0].integer == 60);
    try db.execute("SELECT g, SUM(n) FROM data WHERE id < 0 GROUP BY g", &result);
    try check(result.row_count == 0 and db.workspace.query.stream_stats.groups == 0);
    try db.execute("SELECT COUNT(*), SUM(n) FROM data WHERE id < 0", &result);
    try check(result.rows[0].cells[0].integer == 0 and result.rows[0].cells[1] == .null_value);
    try db.execute("SELECT g, COUNT(*) FILTER (WHERE n % 2 = 0) FROM data WHERE id < 256 GROUP BY g HAVING COUNT(*) > 0 ORDER BY g DESC LIMIT 3 OFFSET 1", &result);
    try check(result.row_count == 3 and result.rows[0].cells[0].integer == 62 and result.rows[0].cells[1].integer == 4 and result.rows[1].cells[0].integer == 61 and result.rows[1].cells[1].integer == 0);
    try rejected("SELECT id, COUNT(*) FROM data GROUP BY id ORDER BY id", error.WorkspaceCapacity);
    try rejected("SELECT SUM(n * 100000) FROM data", error.IntegerOverflow);
    // Cancel after group state exists; also exercise budget cancellation on
    // the scalar scan. Successful re-execution must not read poisoned state.
    var cancel: Cancel = .{};
    var control: sql.ExecutionControl = .{ .context = &cancel, .poll = &Cancel.poll, .poll_interval = 1 };
    db.session.control = &control;
    try rejected("SELECT g, SUM(n) FROM data GROUP BY g ORDER BY g", error.QueryCanceled);
    db.session.control = null;
    try check(cancel.calls == 25);
    control = .{ .max_work = 100 };
    db.session.control = &control;
    try rejected("SELECT COUNT(*), SUM(n) FROM data WHERE id >= 0", error.QueryWorkLimit);
    db.session.control = null;
    @memset(&db.workspace.query.cells, .{ .integer = 0x55555555 });
    @memset(&refs, 0xaaaaaaaa);
    try grouped(count);
    // Reader must ignore the other transaction's pending version, while the
    // writer's aggregate sees its own update. Abort restores subsequent reads.
    const writer = try db.begin();
    try db.statement(writer, "UPDATE data SET n = -1, g = NULL WHERE id = 0", &result, .{});
    const reader = try db.begin();
    try db.statement(reader, "SELECT SUM(n) FROM data", &result, .{});
    try check(result.rows[0].cells[0].integer == @as(i64,count)*(count-1)/2);
    try db.statement(writer, "SELECT g, COUNT(*), SUM(n) FROM data WHERE id = 0 GROUP BY g", &result, .{});
    try check(result.row_count == 1 and result.rows[0].cells[0] == .null_value and result.rows[0].cells[1].integer == 1 and result.rows[0].cells[2].integer == -1);
    db.abort(reader); db.abort(writer);
    try grouped(count);
}

const Small = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 16,
    .text_bytes = 64, .work_rows = 64, .result_rows = 32, .integer_bits = 32 });
var small: Small = .{};
var sr: Small.Result = .{};
fn equivalent(source: []const u8) !void {
    try small.execute(source, &sr);
    try check(sr.row_count == 1 and sr.rows[0].cells[1].integer == 2);
}
fn equality() !void {
    try small.execute("CREATE TABLE numbers (n NUMERIC)", &sr);
    try small.execute("INSERT INTO numbers VALUES (1), (1.00)", &sr);
    try equivalent("SELECT n, COUNT(*) FROM numbers GROUP BY n");
    try small.execute("CREATE TABLE floats (n DOUBLE PRECISION)", &sr);
    try small.execute("INSERT INTO floats VALUES ('0'), ('-0')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM floats GROUP BY n");
    try small.execute("DELETE FROM floats", &sr);
    try small.execute("INSERT INTO floats VALUES ('NaN'), ('NaN')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM floats GROUP BY n");
    try small.execute("CREATE TABLE spans (n INTERVAL)", &sr);
    try small.execute("INSERT INTO spans VALUES ('1 day'), ('24 hours')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM spans GROUP BY n");
    try small.execute("CREATE TABLE documents (n JSONB)", &sr);
    try small.execute("INSERT INTO documents VALUES ('{\"x\":1}'), ('{\"x\":1.0}')", &sr);
    try equivalent("SELECT n, COUNT(*) FROM documents GROUP BY n");
    // The independent DISTINCT aggregate path retains exact semantics.
    try small.execute("SELECT COUNT(DISTINCT n) FROM numbers", &sr);
    try check(sr.rows[0].cells[0].integer == 1 and small.workspace.query.stream_stats.rows == 0);
    try small.execute("SELECT n, COUNT(*) FROM numbers GROUP BY n ORDER BY n LIMIT 0", &sr);
    try check(sr.row_count == 0 and small.workspace.query.stream_stats.rows == 2);
}

// Many aggregate states can need more memory than sorted one-row runs. The
// optimized path must not reject a pure query that the old operator can fit.
const Dense = sql.Database(.{ .tables = 1, .columns = 8, .rows_per_table = 512,
    .work_rows = 512, .result_rows = 512, .integer_bits = 32 });
var dense: Dense = .{};
var dr: Dense.Result = .{};
fn highCardinalityFallback() !void {
    try dense.execute("CREATE TABLE t (id INT PRIMARY KEY, g INT, n INT)", &dr);
    var text: [128]u8 = undefined;
    for (0..350) |i| try dense.execute(try std.fmt.bufPrint(&text, "INSERT INTO t VALUES ({d},{d},{d})", .{i,i,350-i}), &dr);
    try dense.execute("SELECT g, COUNT(id), SUM(n), MIN(n), MAX(n), AVG(n), COUNT(n), SUM(g) FROM t GROUP BY g ORDER BY g", &dr);
    try check(dr.row_count == 350 and dense.workspace.query.stream_stats.rows == 0);
    for (0..350) |i| {
        try check(dr.rows[i].cells[0].integer == i and dr.rows[i].cells[1].integer == 1 and dr.rows[i].cells[2].integer == 350-i and dr.rows[i].cells[3].integer == 350-i and dr.rows[i].cells[4].integer == 350-i and dr.rows[i].cells[6].integer == 1 and dr.rows[i].cells[7].integer == i);
    }
    // Volatile evaluation must neither repeat on retry nor lose old capacity.
    // Conservative eligibility routes functions directly to the existing path.
    try dense.execute("CREATE SEQUENCE s", &dr);
    try dense.execute("SELECT g, COUNT(id), SUM(n), MIN(n), MAX(n), AVG(n), COUNT(n), SUM(g) FROM t WHERE nextval('s') > 0 GROUP BY g ORDER BY g", &dr);
    try check(dr.row_count == 350 and dense.workspace.query.stream_stats.rows == 0);
    try dense.execute("SELECT lastval()", &dr);
    try check(dr.rows[0].cells[0].integer == 350);
}

// A fact scan and two unique-key dimensions must not materialize N handles.
const Star=sql.Database(.{.external_storage=true,.tables=3,.columns=4,
    .rows_per_table=4,.text_bytes=16,.work_rows=128,.result_rows=128,.integer_bits=32,.compact_integral_scans=true});
var star:Star=.{};
var star_result:Star.Result=.{};
var fact_rows:[count]Star.StorageRowSlot=undefined;
var fact_versions:[count*2]Star.StorageVersion=undefined;
var fact_row_index:[262144]u32=undefined;
var fact_key_index:[524288]u32=undefined;
var fact_scan_values:[count*4]i64=undefined;
var fact_scan_nonnull:[count]u64=undefined;
var fact_scan_live:[count]u8=undefined;
var dim_rows:[2][32]Star.StorageRowSlot=undefined;
var dim_versions:[2][64]Star.StorageVersion=undefined;
var dim_row_index:[2][128]u32=undefined;
var dim_key_index:[2][256]u32=undefined;
var dim_scan_values:[2][32*4]i64=undefined;
var dim_scan_nonnull:[2][32]u64=undefined;
var dim_scan_live:[2][32]u8=undefined;
var star_refs:[512]u32=undefined;
const star_query="SELECT s.region,COUNT(*),SUM(f.amt*p.unit) FROM facts f JOIN shops s ON s.id=f.shop JOIN products p ON p.id=f.product GROUP BY s.region ORDER BY s.region NULLS LAST";
fn starRejected(source:[]const u8,expected:sql.Error) !void {
    const before=star_result;
    if(star.execute(source,&star_result)) |_| return error.FailureExpected else |err| try check(err==expected);
    try check(star_result.row_count==before.row_count and star_result.column_count==before.column_count);
    for(0..before.row_count) |row| for(0..before.column_count) |column| {
        try check(Star.compareCells(&star_result.rows[row].cells[column],&before.rows[row].cells[column])==0);
    };
    const usage=star.usage();
    try check(usage.transactions==0 and usage.row_locks==0 and usage.pending_versions==0);
}
fn starModel(n:usize) !void {
    try star.execute(star_query,&star_result);
    try check(star_result.row_count==5);
    var sizes:[5]i64=@splat(0);var sums:[5]i64=@splat(0);
    for(0..n) |id| {
        if(id%23==0 or id%17==0) continue;
        const group=if(id%16==7) 4 else id%4;
        sizes[group]+=1;
        if(id%19!=0) sums[group]+=(@as(i64,@intCast(id%97))-48)*@as(i64,@intCast(id%8+1));
    }
    for(0..5) |group| {
        if(group==4) try check(star_result.rows[group].cells[0]==.null_value)
        else try check(star_result.rows[group].cells[0].integer==group);
        try check(star_result.rows[group].cells[1].integer==sizes[group]);
        try check(star_result.rows[group].cells[2].integer==sums[group]);
    }
    try check(star.workspace.query.stream_stats.rows==n);
    try check(star.workspace.query.stream_stats.groups==5);
    try check(star.workspace.query.stream_stats.gathered_rows==n);
    try check(star.workspace.query.stream_stats.scratch_refs<=star_refs.len);
}
fn joinedGroups() !void {
    try star.bindStorage(.{
        .{.rows=&fact_rows,.versions=&fact_versions,.row_index=&fact_row_index,.key_index=&fact_key_index,
          .scan_values=&fact_scan_values,.scan_nonnull=&fact_scan_nonnull,.scan_live=&fact_scan_live},
        .{.rows=&dim_rows[0],.versions=&dim_versions[0],.row_index=&dim_row_index[0],.key_index=&dim_key_index[0],
          .scan_values=&dim_scan_values[0],.scan_nonnull=&dim_scan_nonnull[0],.scan_live=&dim_scan_live[0]},
        .{.rows=&dim_rows[1],.versions=&dim_versions[1],.row_index=&dim_row_index[1],.key_index=&dim_key_index[1],
          .scan_values=&dim_scan_values[1],.scan_nonnull=&dim_scan_nonnull[1],.scan_live=&dim_scan_live[1]},
    },&star_refs);
    try star.execute("CREATE TABLE facts(id INT PRIMARY KEY,shop INT,product INT,amt INT)",&star_result);
    try star.execute("CREATE TABLE shops(id INT PRIMARY KEY,region INT)",&star_result);
    try star.execute("CREATE TABLE products(id INT PRIMARY KEY,unit INT)",&star_result);
    var text:[192]u8=undefined;
    for(0..16) |id| try star.execute(try std.fmt.bufPrint(&text,"INSERT INTO shops VALUES({d},{s})",.{id,if(id==7) "NULL" else try std.fmt.bufPrint(text[128..],"{d}",.{id%4})}),&star_result);
    for(0..8) |id| try star.execute(try std.fmt.bufPrint(&text,"INSERT INTO products VALUES({d},{d})",.{id,id+1}),&star_result);
    var small_refs:usize=0;var small_cells:usize=0;
    for(0..count) |id| {
        var shop:[24]u8=undefined;var product:[24]u8=undefined;var amount:[24]u8=undefined;
        try star.execute(try std.fmt.bufPrint(&text,"INSERT INTO facts VALUES({d},{s},{s},{s})",.{id,
            try std.fmt.bufPrint(&shop,"{d}",.{if(id%23==0) @as(usize,999) else id%16}),
            if(id%17==0) "NULL" else try std.fmt.bufPrint(&product,"{d}",.{id%8}),
            if(id%19==0) "NULL" else try std.fmt.bufPrint(&amount,"{d}",.{@as(i64,@intCast(id%97))-48})}),&star_result);
        if(id==511) {
            try starModel(512);
            small_refs=star.workspace.query.stream_stats.scratch_refs;
            small_cells=star.workspace.query.stream_stats.scratch_cells;
        }
    }
    try starModel(count);
    try check(star.workspace.query.stream_stats.scratch_refs==small_refs);
    try check(star.workspace.query.stream_stats.scratch_cells==small_cells);
    var total:i64=0;var sum:i64=0;
    for(13..count) |id| {
        if(id%23==0 or id%17==0 or id%8+1<=4) continue;
        total+=1;
        if(id%19!=0) sum+=(@as(i64,@intCast(id%97))-48)*@as(i64,@intCast(id%8+1));
    }
    try star.execute("SELECT COUNT(*),SUM(f.amt*p.unit) FROM facts f JOIN shops s ON s.id=f.shop JOIN products p ON p.id=f.product WHERE f.id>=13 AND p.unit>4",&star_result);
    try check(star_result.rows[0].cells[0].integer==total and star_result.rows[0].cells[1].integer==sum);
    try check(star.workspace.query.stream_stats.scratch_refs==0 and star.workspace.query.stream_stats.summary_plans==0);
    // A later probe can depend on a preceding dimension, rather than the fact.
    var chained:[4]i64=@splat(0);
    for(0..count) |id| if(id%23!=0 and id%16!=7) {chained[id%4]+=1;};
    try star.execute("SELECT s.region,COUNT(*) FROM facts f JOIN shops s ON s.id=f.shop JOIN products p ON p.id=s.region GROUP BY s.region ORDER BY s.region",&star_result);
    try check(star_result.row_count==4);
    for(0..4) |region| try check(star_result.rows[region].cells[0].integer==region and star_result.rows[region].cells[1].integer==chained[region]);
    total=0;sum=0;
    for(0..count) |id| {
        const amount=@as(i64,@intCast(id%97))-48;
        if(id%23==0 or id%17==0 or id%19==0 or amount<=0) continue;
        total+=1;sum+=amount*@as(i64,@intCast(id%8+1));
    }
    try star.execute("SELECT COUNT(*),SUM(f.amt*p.unit) FROM facts f JOIN shops s ON s.id=f.shop JOIN products p ON p.id=f.product AND f.amt>0",&star_result);
    try check(star_result.rows[0].cells[0].integer==total and star_result.rows[0].cells[1].integer==sum);
    try star.execute("SELECT COUNT(*),SUM(f.amt*p.unit) FROM facts f JOIN shops s ON s.id=f.shop JOIN products p ON p.id=f.product WHERE f.id<0",&star_result);
    try check(star_result.rows[0].cells[0].integer==0 and star_result.rows[0].cells[1]==.null_value);
    // DISTINCT, outer joins, non-key joins and excessive groups retain bounded
    // failure/previous-result behavior rather than silently changing semantics.
    try starRejected("SELECT COUNT(DISTINCT f.amt) FROM facts f JOIN shops s ON s.id=f.shop",error.WorkspaceCapacity);
    try starRejected("SELECT COUNT(*) FROM facts f LEFT JOIN shops s ON s.id=f.shop",error.WorkspaceCapacity);
    try starRejected("SELECT COUNT(*) FROM facts f JOIN shops s ON s.region=f.shop",error.WorkspaceCapacity);
    try starRejected("SELECT f.id,COUNT(*) FROM facts f JOIN shops s ON s.id=f.shop GROUP BY f.id ORDER BY f.id",error.WorkspaceCapacity);
    var cancel:Cancel=.{};
    var control:sql.ExecutionControl=.{.context=&cancel,.poll=&Cancel.poll,.poll_interval=1};
    star.session.control=&control;
    try starRejected(star_query,error.QueryCanceled);
    star.session.control=null;
    try check(cancel.calls==25);
    control=.{.max_work=100};star.session.control=&control;
    try starRejected(star_query,error.QueryWorkLimit);star.session.control=null;
    @memset(&star_refs,0xaaaaaaaa);
    @memset(&star.workspace.query.cells,.{.integer=0x55555555});
    try starModel(count);
    // Pending dimension versions are visible only to the owning transaction.
    const writer=try star.begin();
    try star.statement(writer,"UPDATE products SET unit=100 WHERE id=0",&star_result,.{});
    try starModel(count);
    try star.statement(writer,star_query,&star_result,.{});
    try check(star.workspace.query.stream_stats.gathered_rows==0);
    var own_sum:i64=0;
    for(0..count) |id| {
        if(id%23==0 or id%17==0 or id%19==0 or id%4!=0) continue;
        const unit:i64=if(id%8==0) 100 else @intCast(id%8+1);
        own_sum+=(@as(i64,@intCast(id%97))-48)*unit;
    }
    try check(star_result.rows[0].cells[2].integer==own_sum);
    star.abort(writer);
    try starModel(count);
    const pending=try star.begin();
    try star.statement(pending,"UPDATE facts SET shop=0,product=0,amt=5 WHERE id=0",&star_result,.{});
    try starModel(count);
    try star.statement(pending,"SELECT COUNT(*),SUM(f.amt*p.unit) FROM facts f JOIN shops s ON s.id=f.shop JOIN products p ON p.id=f.product WHERE f.id=0",&star_result,.{});
    try check(star_result.rows[0].cells[0].integer==1 and star_result.rows[0].cells[1].integer==5);
    try check(star.workspace.query.stream_stats.gathered_rows==0);
    star.abort(pending);
    try starModel(count);
}

const Mixed=sql.Database(.{.external_storage=true,.compact_integral_scans=true,.tables=2,
    .columns=4,.rows_per_table=4,.text_bytes=32,.work_rows=32,.result_rows=16,.integer_bits=32});
const mixed_bytes=Mixed.backingBytes(16,32,512) catch unreachable;
var mixed_memory:[mixed_bytes]u8 align(16)=undefined;
var mixed:Mixed=.{};
var mixed_result:Mixed.Result=.{};
fn mixedInputs() !void {
    try mixed.bindMemory(&mixed_memory,16,32,512);
    try mixed.execute("CREATE TABLE f(id INT PRIMARY KEY,p INT,label TEXT,n NUMERIC)",&mixed_result);
    try mixed.execute("CREATE TABLE d(id INT PRIMARY KEY,m INT)",&mixed_result);
    try mixed.execute("INSERT INTO f VALUES(1,1,'a',1.5),(2,1,'bb',2.25),(3,2,NULL,NULL)",&mixed_result);
    try mixed.execute("INSERT INTO d VALUES(1,10),(2,20)",&mixed_result);
    const integral="SELECT d.m,COUNT(*),SUM(f.id) FROM f JOIN d ON d.id=f.p GROUP BY d.m ORDER BY d.m";
    try mixed.execute(integral,&mixed_result);
    try check(mixed_result.row_count==2 and mixed_result.rows[0].cells[1].integer==2 and mixed_result.rows[0].cells[2].integer==3);
    try check(mixed.workspace.query.stream_stats.gathered_rows==3);
    try mixed.execute("SELECT f.label,COUNT(*) FROM f JOIN d ON d.id=f.p GROUP BY f.label ORDER BY f.label NULLS LAST",&mixed_result);
    try check(mixed_result.row_count==3 and std.mem.eql(u8,mixed_result.rows[0].cells[0].text.slice(),"a") and
        std.mem.eql(u8,mixed_result.rows[1].cells[0].text.slice(),"bb") and mixed_result.rows[2].cells[0]==.null_value);
    try check(mixed.workspace.query.stream_stats.gathered_rows==0);
    try mixed.execute("SELECT COUNT(f.n),SUM(f.n*d.m)=37.5 FROM f JOIN d ON d.id=f.p",&mixed_result);
    try check(mixed_result.rows[0].cells[0].integer==2 and mixed_result.rows[0].cells[1].boolean);
    try check(mixed.workspace.query.stream_stats.gathered_rows==0);
    try mixed.execute("SELECT COUNT(*) FROM f JOIN d ON d.id=f.p WHERE f.label IS NULL",&mixed_result);
    try check(mixed_result.rows[0].cells[0].integer==1 and mixed.workspace.query.stream_stats.gathered_rows==0);
    try mixed.execute("DELETE FROM f WHERE id=1",&mixed_result);
    try mixed.execute(integral,&mixed_result);
    try check(mixed_result.row_count==2 and mixed_result.rows[0].cells[1].integer==1 and mixed_result.rows[0].cells[2].integer==2);
    try check(mixed.workspace.query.stream_stats.gathered_rows==2);
}

pub fn main() !void {
    try large();
    try equality();
    try highCardinalityFallback();
    try joinedGroups();
    try mixedInputs();
    std.debug.print("{{\"suite\":\"sql-stream-group\",\"pass\":true,\"assertions\":{d},\"rows\":{d},\"query_refs\":{d},\"joined_rows\":{d},\"joined_query_refs\":{d}}}\n", .{assertions,count,refs.len,count,star_refs.len});
}
