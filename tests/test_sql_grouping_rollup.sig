const std=@import("std");const sql=@import("sql");
const Db=sql.Database(.{.tables=3,.columns=8,.rows_per_table=32,.work_rows=2048,.expr_nodes=4096,.expr_depth=64,.integer_bits=32,.nulls_first_ascending=false});
var db:Db=.{};var result:Db.Result=.{};var assertions:usize=0;
var reader:Db.ReadContext=.{};
const Small=sql.Database(.{.tables=1,.columns=4,.rows_per_table=8,.work_rows=1});
var small:Small=.{};var small_result:Small.Result=.{};
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.RollupContract;}
fn run(q:[]const u8) !void {db.execute(q,&result) catch |err| {std.debug.print("{s}: {s}\n",.{@errorName(err),q});return err;};}
fn fixture(q:[]const u8,expected:[]const u8) !void {
    try run(q);try result.textify(&db.session);
    if(expected.len==0){try check(result.row_count==0);return;}
    var rows=std.mem.splitScalar(u8,expected,0x1e);var row:usize=0;
    while(rows.next()) |line| {
        try check(row<result.row_count);var cells=std.mem.splitScalar(u8,line,0x1f);var col:usize=0;
        while(cells.next()) |value| {
            try check(col<result.column_count);const actual=result.rows[row].cells[col];var buffer:[64]u8=undefined;
            const got:[]const u8=switch(actual){.null_value=>"<NULL>",.integer=>|v|try std.fmt.bufPrint(&buffer,"{d}",.{v}),.text=>|v|v.slice(),else=>return error.UnexpectedCell};
            if(!std.mem.eql(u8,got,value)){std.debug.print("expected [{s}], got [{s}] row {d} column {d}: {s}\n",.{value,got,row,col,q});return error.RollupOracleMismatch;}
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

fn foldedRollup() !void {
    try run("CREATE TABLE measures(id INTEGER PRIMARY KEY, dim_id INTEGER, band INTEGER NOT NULL, amount BIGINT)");
    const select = "SELECT d.label,m.band,GROUPING(d.label,m.band),COUNT(*),COUNT(m.amount),SUM(m.amount),AVG(m.amount) FROM measures m JOIN dim d ON d.id=m.dim_id GROUP BY ";
    const order = " ORDER BY d.label NULLS LAST,m.band NULLS LAST,GROUPING(d.label,m.band)";
    const rollup = select ++ "ROLLUP(d.label,m.band)" ++ order;
    const sets = select ++ "GROUPING SETS ((d.label,m.band),(d.label),())" ++ order;
    try run(rollup);
    try check(result.row_count == 1 and result.rows[0].cells[3].integer == 0);
    try check(result.rows[0].cells[5] == .null_value and result.rows[0].cells[6] == .null_value);
    try run("INSERT INTO measures VALUES (1,1,9,9223372036854775807),(2,2,9,9223372036854775807),(3,2,10,-7),(4,1,10,NULL),(5,3,3,NULL),(6,4,3,8)");
    try run(rollup);
    try check(db.workspace.query.stream_stats.rollup_folded_leaves == 3);
    const folded = result;
    try run(sets);
    try check(result.row_count == folded.row_count and result.column_count == folded.column_count);
    for (result.rows[0..result.row_count], folded.rows[0..folded.row_count]) |*actual, *expected| {
        for (actual.cells[0..result.column_count], expected.cells[0..result.column_count]) |*a, *b| {
            try check(Db.compareCells(a, b) == 0);
        }
    }
    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    defer db.session.control = null;
    try run(rollup);
    const used = control.used;
    try check(used > 1);
    control.reset(used - 1);
    try reject(rollup, error.QueryWorkLimit);
    try check(control.used == used - 1);
    var cancel: Cancel = .{ .remaining = used - 1 };
    control.context = &cancel;
    control.poll = Cancel.poll;
    control.poll_interval = 1;
    control.reset(0);
    try reject(rollup, error.QueryCanceled);
}

pub fn main() !void {
    try run("CREATE TABLE fact(id INTEGER PRIMARY KEY,k INTEGER,v INTEGER)");
    try run("INSERT INTO fact VALUES(1,1,10),(2,1,10),(3,1,30),(4,2,5),(5,2,NULL),(6,NULL,7)");
    try run("CREATE TABLE dim(id INTEGER PRIMARY KEY,label TEXT NOT NULL)");
    try run("INSERT INTO dim VALUES(1,'north'),(2,'north'),(3,'south')");
    var fixtures=std.mem.splitScalar(u8,@embedFile("evidence/rollup-pg16.tsv"),'\n');
    while(fixtures.next()) |line| {if(line.len==0) continue;const tab=std.mem.indexOfScalar(u8,line,'\t') orelse return error.InvalidFixture;try fixture(line[0..tab],line[tab+1..]);}
    try foldedRollup();
    try run("SELECT k,v,COUNT(*),SUM(v),GROUPING(k,v) FROM fact GROUP BY ROLLUP(k,v) ORDER BY k NULLS LAST,v NULLS LAST,GROUPING(k,v)");
    try check(result.row_count==9);
    var total_count:i64=0;
    for(result.rows[0..result.row_count]) |row| {
        total_count+=row.cells[2].integer;
        if(row.cells[4].integer==3) try check(row.cells[2].integer==6 and row.cells[3].integer==62);
    }
    try check(total_count==18);
    try run("SELECT k,v,GROUPING(k,v),COUNT(*) FROM fact WHERE id<0 GROUP BY ROLLUP(k,v)");
    try check(result.row_count==1 and result.rows[0].cells[0]==.null_value and result.rows[0].cells[2].integer==3 and result.rows[0].cells[3].integer==0);
    try run("SELECT COUNT(*),SUM(v) FROM fact GROUP BY ()");try check(result.row_count==1 and result.rows[0].cells[0].integer==6);
    try run("SELECT k,GROUPING(k) FROM fact GROUP BY k ORDER BY k NULLS LAST");
    try check(result.row_count==3);for(result.rows[0..result.row_count]) |row| try check(row.cells[1].integer==0);
    try run("SELECT k,GROUPING(k),SUM(v),RANK() OVER (ORDER BY SUM(v) DESC) FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k),k NULLS LAST");
    try check(result.row_count==4 and result.rows[3].cells[1].integer==1 and result.rows[3].cells[3].integer==1);
    try reject("SELECT GROUPING(v),COUNT(*) FROM fact GROUP BY ROLLUP(k)",error.GroupingError);
    try reject("SELECT id FROM fact WHERE GROUPING(k)=0",error.GroupingError);
    try reject("SELECT COUNT(*) FROM fact GROUP BY ROLLUP()",error.Syntax);
    try reject("SELECT k,COUNT(DISTINCT v+1) FROM fact GROUP BY ROLLUP(k)",error.UnsupportedStatement);
    try reject("SELECT k,COUNT(*) FROM fact GROUP BY ROLLUP(k) HAVING 1/(COUNT(*)-COUNT(*))>0",error.DivisionByZero);
    // A volatile argument is evaluated once per input, shared across levels.
    try run("CREATE SEQUENCE s START 1");
    try run("SELECT GROUPING(k),SUM(nextval('s')) FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k)");
    try check(result.rows[result.row_count-1].cells[1].numeric.coef()==21);
    try run("SELECT currval('s')");try check(result.rows[0].cells[0].integer==6);
    const total="SELECT SUM(v) FROM fact GROUP BY ()";
    const tx=try db.begin();try db.statement(tx,"UPDATE fact SET v=100 WHERE id=1",&result,.{});
    try db.statement(tx,total,&result,.{});try check(result.rows[0].cells[0].integer==152);db.abort(tx);
    try run(total);try check(result.rows[0].cells[0].integer==62);
    const pin=try db.begin();const snapshot:Db.Snapshot=.{.csn=db.csn};db.txs[pin].pin=snapshot;
    try run("UPDATE fact SET v=11 WHERE id=1");try reader.execute(&db,total,snapshot,&result);try check(result.rows[0].cells[0].integer==62);db.abort(pin);
    try run(total);try check(result.rows[0].cells[0].integer==63);try run("UPDATE fact SET v=10 WHERE id=1");
    @memset(&db.workspace.query.cells,.{.integer=0x55555555});
    const q="SELECT k,v,GROUPING(k,v),COUNT(*),SUM(v) FROM fact GROUP BY ROLLUP(k,v) ORDER BY k NULLS LAST,v NULLS LAST,GROUPING(k,v)";
    var control:sql.ExecutionControl=.{};db.session.control=&control;try run(q);const used=control.used;try check(used>0);
    for(1..used) |limit| {control.reset(limit);try reject(q,error.QueryWorkLimit);try check(control.used==limit);}
    var cancel:Cancel=.{.remaining=0};control.context=&cancel;control.poll=Cancel.poll;control.poll_interval=1;
    for(0..used) |limit| {cancel.remaining=limit;control.reset(0);try reject(q,error.QueryCanceled);}
    db.session.control=null;try run(q);try check(result.row_count==9);
    try small.execute("CREATE TABLE t(id INTEGER PRIMARY KEY,k INTEGER)",&small_result);
    try small.execute("INSERT INTO t VALUES(1,1),(2,2),(3,3)",&small_result);try small.execute("SELECT 123",&small_result);
    if(small.execute("SELECT k,COUNT(*) FROM t GROUP BY ROLLUP(k)",&small_result)) |_| return error.ExpectedCapacity else |err| try check(err==error.WorkspaceCapacity);
    try check(small_result.row_count==1 and small_result.rows[0].cells[0].integer==123);
    std.debug.print("PASS SQL rollup: {d} assertions\n",.{assertions});
}
