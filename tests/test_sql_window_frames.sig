const std=@import("std");const sql=@import("sql");
const Db=sql.Database(.{.tables=2,.columns=8,.rows_per_table=128,.work_rows=4096,.result_rows=128,.expr_nodes=8192,.expr_depth=64,.integer_bits=32,.nulls_first_ascending=false});
var db:Db=.{};var result:Db.Result=.{};var assertions:usize=0;
var reader:Db.ReadContext=.{};
const Shared=sql.Database(.{.tables=1,.columns=8,.external_storage=true,.rows_per_table=2,.work_rows=256,.result_rows=128,.integer_bits=32,.nulls_first_ascending=false});
var shared:Shared=.{};var shared_result:Shared.Result=.{};var constrained:Shared.ReadContext=.{};
var shared_memory:[4194304]u8 align(64)=undefined;var short_refs:[384]u32=undefined;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.WindowFrameContract;}
fn run(q:[]const u8) !void {db.execute(q,&result) catch |err| {std.debug.print("{s}: {s}\n",.{@errorName(err),q});return err;};}
fn fixture(q:[]const u8,expected:[]const u8) !void {
    try run(q);try result.textify(&db.session);
    if(expected.len==0){try check(result.row_count==0);return;}
    var rows=std.mem.splitScalar(u8,expected,0x1e);var row:usize=0;
    while(rows.next()) |line| {
        try check(row<result.row_count);var cells=std.mem.splitScalar(u8,line,0x1f);var col:usize=0;
        while(cells.next()) |value| {
            try check(col<result.column_count);const actual=result.rows[row].cells[col];var buffer:[64]u8=undefined;
            const got:[]const u8=switch(actual){.null_value=>"<NULL>",.integer=>|v|try std.fmt.bufPrint(&buffer,"{d}",.{v}),.boolean=>|v|if(v) "t" else "f",.text=>|v|v.slice(),else=>return error.UnexpectedCell};
            if(!std.mem.eql(u8,got,value)){std.debug.print("expected [{s}], got [{s}] row {d} column {d}: {s}\n",.{value,got,row,col,q});return error.WindowFrameOracleMismatch;}
            try check(true);col+=1;
        }
        try check(col==result.column_count);row+=1;
    }
    try check(row==result.row_count);
}
fn reject(q:[]const u8,wanted:sql.Error) !void {
    const saved=result;
    if(db.execute(q,&result)) |_| return error.ExpectedFailure else |err| {
        if(err!=wanted){std.debug.print("expected {s}, got {s}: {s}\n",.{@errorName(wanted),@errorName(err),q});return err;}
    }
    try check(result.row_count==saved.row_count and result.column_count==saved.column_count);
    for(result.rows[0..result.row_count],saved.rows[0..saved.row_count]) |a,b| for(0..result.column_count) |i| try check(Db.compareCells(&a.cells[i],&b.cells[i])==0);
}
const Cancel=struct {remaining:usize,fn poll(raw:?*anyopaque) sql.Error!void {
    const self:*Cancel=@ptrCast(@alignCast(raw.?));if(self.remaining==0) return error.QueryCanceled;self.remaining-=1;
}};
fn dataValue(i:usize) ?i64 {return if(i%13==0) null else @as(i64,@intCast(i*97%211))-100;}
pub fn main() !void {
    try run("CREATE TABLE fact(id INTEGER PRIMARY KEY,k INTEGER,v INTEGER)");
    try run("INSERT INTO fact VALUES(1,1,10),(2,1,10),(3,1,30),(4,2,5),(5,2,NULL),(6,NULL,7),(7,3,NULL),(8,3,NULL)");
    var fixtures=std.mem.splitScalar(u8,@embedFile("evidence/window-frames-pg16.tsv"),'\n');
    while(fixtures.next()) |line| {if(line.len==0) continue;const tab=std.mem.indexOfScalar(u8,line,'\t') orelse return error.InvalidFixture;try fixture(line[0..tab],line[tab+1..]);}
    try reject("SELECT SUM(v) OVER (ROWS -1 PRECEDING) FROM fact",error.InvalidWindowFrameOffset);
    try reject("SELECT SUM(v) OVER (ROWS NULL PRECEDING) FROM fact",error.NullWindowFrameOffset);
    try reject("SELECT SUM(v) OVER (ROWS -1 PRECEDING) FROM fact WHERE FALSE",error.InvalidWindowFrameOffset);
    try reject("SELECT SUM(v) OVER (ROWS v PRECEDING) FROM fact",error.InvalidColumnReference);
    try reject("SELECT SUM(v) OVER (ROWS TRUE PRECEDING) FROM fact",error.TypeMismatch);
    try reject("SELECT SUM(v) OVER (ROWS COUNT(*) PRECEDING) FROM fact",error.GroupingError);
    try reject("SELECT SUM(v) OVER (ROWS SUM(v) OVER () PRECEDING) FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) OVER (ROWS UNBOUNDED FOLLOWING) FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) OVER (ROWS BETWEEN CURRENT ROW AND UNBOUNDED PRECEDING) FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) OVER (GROUPS 1 PRECEDING) FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) OVER (RANGE 1 PRECEDING) FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) OVER (ORDER BY id,v RANGE 1 PRECEDING) FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) OVER (ORDER BY v RANGE -1 PRECEDING) FROM fact",error.InvalidWindowFrameOffset);
    try reject("SELECT SUM(v) OVER (ORDER BY v RANGE NULL PRECEDING) FROM fact",error.NullWindowFrameOffset);
    try reject("SELECT SUM(1/0) FILTER (WHERE FALSE) OVER () FROM fact",error.DivisionByZero);
    try reject("SELECT 1/0,SUM(v) OVER () FROM fact LIMIT 0",error.DivisionByZero);
    try reject("SELECT SUM(v) FILTER (WHERE COUNT(*)>1) OVER () FROM fact",error.GroupingError);
    try reject("SELECT SUM(v) FILTER (WHERE ROW_NUMBER() OVER ()>1) OVER () FROM fact",error.WindowingError);
    try reject("SELECT SUM(v) FILTER (WHERE 1) OVER () FROM fact",error.TypeMismatch);
    try reject("SELECT RANK() FILTER (WHERE TRUE) OVER () FROM fact",error.UnsupportedStatement);
    try reject("SELECT COUNT(DISTINCT v) OVER () FROM fact",error.UnsupportedStatement);
    try reject("SELECT SUM(v) FILTER (WHERE 10/(id-id)>0) OVER (ROWS 1 PRECEDING) FROM fact",error.DivisionByZero);
    try run("SELECT id,BOOL_AND(flag) OVER (ORDER BY id ROWS 2 PRECEDING),BOOL_OR(flag) OVER (ORDER BY id ROWS 2 PRECEDING) FROM (SELECT id,v>7 AS flag FROM fact) s ORDER BY id");
    try check(db.workspace.query.stream_stats.window_prefix_rows==16 and db.workspace.query.stream_stats.window_scalar_visits==0);
    try run("CREATE SEQUENCE offsets START 1");
    try run("SELECT id,SUM(v) OVER (PARTITION BY k ORDER BY id ROWS nextval('offsets') PRECEDING) FROM fact ORDER BY id");
    try run("SELECT currval('offsets')");try check(result.rows[0].cells[0].integer==1);
    try run("SELECT id,RANK() OVER (ORDER BY id ROWS nextval('offsets') PRECEDING) FROM fact ORDER BY id");
    try run("SELECT currval('offsets')");try check(result.rows[0].cells[0].integer==1);
    try reject("SELECT SUM(nextval('offsets')) OVER (ORDER BY id ROWS 1 PRECEDING) FROM fact",error.UnsupportedStatement);
    try reject("SELECT SUM(v) FILTER (WHERE nextval('offsets')>0) OVER (ORDER BY id ROWS 1 PRECEDING) FROM fact",error.UnsupportedStatement);
    try run("CREATE SEQUENCE arguments START 1");
    try run("SELECT COUNT(nextval('arguments')) OVER (),COUNT(nextval('arguments')) OVER () FROM fact");
    try check(result.row_count==8 and result.rows[0].cells[0].integer==8 and result.rows[0].cells[1].integer==8);
    try run("SELECT currval('arguments')");try check(result.rows[0].cells[0].integer==16);
    try run("CREATE SEQUENCE filtered_calls START 1");
    try run("SELECT COUNT(*) FILTER (WHERE nextval('filtered_calls')>0) OVER () FROM fact");
    try check(result.row_count==8 and result.rows[0].cells[0].integer==8);
    try run("SELECT currval('filtered_calls')");try check(result.rows[0].cells[0].integer==8);
    try run("CREATE SEQUENCE returned_calls START 1");
    try run("SELECT id,nextval('returned_calls'),SUM(v) OVER () FROM fact ORDER BY id DESC LIMIT 2");
    try check(result.row_count==2 and result.rows[0].cells[0].integer==8 and result.rows[0].cells[1].integer==1 and result.rows[1].cells[1].integer==2);
    try run("SELECT currval('returned_calls')");try check(result.rows[0].cells[0].integer==2);
    try run("CREATE SEQUENCE sort_calls START 1");
    try run("SELECT id,nextval('sort_calls') AS marker,SUM(v) OVER () FROM fact ORDER BY marker DESC LIMIT 2");
    try check(result.row_count==2 and result.rows[0].cells[0].integer==8 and result.rows[0].cells[1].integer==8 and result.rows[1].cells[1].integer==7);
    try run("SELECT currval('sort_calls')");try check(result.rows[0].cells[0].integer==8);
    try run("CREATE SEQUENCE mixed_calls START 1");
    try run("SELECT id,id+SUM(v) OVER () AS amount,nextval('mixed_calls') FROM fact ORDER BY id DESC LIMIT 2");
    try check(result.row_count==2 and result.rows[0].cells[0].integer==8 and result.rows[0].cells[1].integer==70 and result.rows[0].cells[2].integer==1 and result.rows[1].cells[2].integer==2);
    try run("SELECT currval('mixed_calls')");try check(result.rows[0].cells[0].integer==2);
    try run("SELECT id,10/(id-1),SUM(v) OVER () FROM fact LIMIT 1 OFFSET 1");
    try check(result.row_count==1 and result.rows[0].cells[0].integer==2 and result.rows[0].cells[1].integer==10);
    const rolling="SELECT id,SUM(v) OVER (ORDER BY id ROWS 1 PRECEDING) FROM fact ORDER BY id";
    const tx=try db.begin();try db.statement(tx,"UPDATE fact SET v=100 WHERE id=1",&result,.{});
    try db.statement(tx,rolling,&result,.{});try check(result.rows[0].cells[1].integer==100);db.abort(tx);
    const pin=try db.begin();const snapshot:Db.Snapshot=.{.csn=db.csn};db.txs[pin].pin=snapshot;
    try run("UPDATE fact SET v=100 WHERE id=1");try reader.execute(&db,rolling,snapshot,&result);try check(result.rows[0].cells[1].integer==10);db.abort(pin);
    try run(rolling);try check(result.rows[0].cells[1].integer==100);try run("UPDATE fact SET v=10 WHERE id=1");
    @memset(&db.workspace.query.cells,.{.integer=0x55555555});
    const guarded="SELECT id,SUM(v) OVER (ORDER BY id ROWS 1 PRECEDING),MIN(v) OVER (ORDER BY v GROUPS 1 PRECEDING EXCLUDE TIES),SUM(CAST(v AS NUMERIC)/3) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING),COUNT(*) FILTER (WHERE id<>3 AND 10/(id-3)>0) OVER (ORDER BY id ROWS 1 PRECEDING) FROM fact ORDER BY id";
    var control:sql.ExecutionControl=.{};db.session.control=&control;try run(guarded);const used=control.used;try check(used>0);
    for(1..used) |limit| {control.reset(limit);try reject(guarded,error.QueryWorkLimit);try check(control.used==limit);}
    var cancel:Cancel=.{.remaining=0};control.context=&cancel;control.poll=Cancel.poll;control.poll_interval=1;
    for(0..used) |limit| {cancel.remaining=limit;control.reset(0);try reject(guarded,error.QueryCanceled);}
    db.session.control=null;try run(guarded);try check(result.row_count==8);
    try run("CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER)");
    try shared.bindMemory(&shared_memory,80,160,1024);
    try shared.execute("CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER)",&shared_result);
    var query:[192]u8=undefined;
    for(0..65) |i| {
        const source=if(dataValue(i)) |v| try std.fmt.bufPrint(&query,"INSERT INTO t VALUES({d},{d})",.{i,v}) else try std.fmt.bufPrint(&query,"INSERT INTO t VALUES({d},NULL)",.{i});
        try run(source);try shared.execute(source,&shared_result);
    }
    try run("SELECT id,SUM(v) OVER (ORDER BY id ROWS BETWEEN 32 PRECEDING AND 32 FOLLOWING),MIN(v) OVER (ORDER BY id ROWS BETWEEN 32 PRECEDING AND 32 FOLLOWING),MAX(v) OVER (ORDER BY id ROWS BETWEEN 32 PRECEDING AND 32 FOLLOWING) FROM t ORDER BY id");
    try check(result.row_count==65);
    for(0..65) |i| {
        var total:i64=0;var low:?i64=null;var high:?i64=null;
        for(i-|32..@min(@as(usize,65),i+33)) |j| if(dataValue(j)) |v| {total+=v;low=if(low) |old| @min(old,v) else v;high=if(high) |old| @max(old,v) else v;};
        try check(result.rows[i].cells[1].integer==total and result.rows[i].cells[2].integer==low.? and result.rows[i].cells[3].integer==high.?);
    }
    const stats=db.workspace.query.stream_stats;
    try check(stats.window_prefix_rows==65 and stats.window_frame_rows==195 and stats.window_scalar_visits==0);
    try check(stats.window_tree_builds>0 and stats.window_tree_builds<=260 and stats.window_tree_visits<2080);
    try run("SELECT id,SUM(v) FILTER (WHERE v>0) OVER (ORDER BY id ROWS BETWEEN 32 PRECEDING AND 32 FOLLOWING),MIN(v) FILTER (WHERE v>0) OVER (ORDER BY id ROWS BETWEEN 32 PRECEDING AND 32 FOLLOWING),COUNT(*) FILTER (WHERE v>0) OVER (ORDER BY id ROWS BETWEEN 32 PRECEDING AND 32 FOLLOWING) FROM t ORDER BY id");
    for(0..65) |i| {
        var total:i64=0;var low:?i64=null;var count:i64=0;
        for(i-|32..@min(@as(usize,65),i+33)) |j| if(dataValue(j)) |v| {if(v>0){total+=v;count+=1;low=if(low) |old| @min(old,v) else v;}};
        try check(result.rows[i].cells[1].integer==total and result.rows[i].cells[2].integer==low.? and result.rows[i].cells[3].integer==count);
    }
    try check(db.workspace.query.stream_stats.window_prefix_rows==130 and db.workspace.query.stream_stats.window_tree_builds>0 and db.workspace.query.stream_stats.window_scalar_visits==0);
    constrained.workspace.query.refs=&short_refs;
    try constrained.execute(&shared,"SELECT id,MIN(v) OVER (ORDER BY id ROWS 64 PRECEDING) FROM t ORDER BY id",.{.csn=shared.csn},&shared_result);
    try check(shared_result.row_count==65 and constrained.workspace.query.stream_stats.window_tree_builds==0 and constrained.workspace.query.stream_stats.window_scalar_visits>0);
    var low:?i64=null;
    for(0..65) |i| {
        if(dataValue(i)) |v| low=if(low) |old| @min(old,v) else v;
        if(low) |v| try check(shared_result.rows[i].cells[1].integer==v) else try check(shared_result.rows[i].cells[1]==.null_value);
    }
    std.debug.print("PASS SQL window frames: {d} assertions\n",.{assertions});
}
