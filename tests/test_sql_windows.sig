const std=@import("std");const sql=@import("sql");
const Db=sql.Database(.{.tables=2,.columns=8,.rows_per_table=32,.work_rows=2048,.expr_nodes=4096,.expr_depth=64,.integer_bits=32,.nulls_first_ascending=false});
var db:Db=.{};var result:Db.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.WindowContract;}
fn run(q:[]const u8) !void {db.execute(q,&result) catch |err| {std.debug.print("{s}: {s}\n",.{@errorName(err),q});return err;};}
fn fixture(q:[]const u8,expected:[]const u8) !void {
    try run(q);try result.textify(&db.session);
    if(expected.len==0){try check(result.row_count==0);return;}
    var rows=std.mem.splitScalar(u8,expected,0x1e);var row:usize=0;
    while(rows.next()) |line| {
        try check(row<result.row_count);var cells=std.mem.splitScalar(u8,line,0x1f);var col:usize=0;
        while(cells.next()) |value| {
            try check(col<result.column_count);
            const actual=result.rows[row].cells[col];
            var buffer:[64]u8=undefined;
            const got:[]const u8=switch(actual){.null_value=>"<NULL>",.integer=>|v|try std.fmt.bufPrint(&buffer,"{d}",.{v}),.text=>|v|v.slice(),else=>return error.UnexpectedCell};
            if(!std.mem.eql(u8,got,value)) {std.debug.print("expected [{s}], got [{s}] row {d} column {d}: {s}\n",.{value,got,row,col,q});return error.WindowOracleMismatch;}
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
pub fn main() !void {
    try run("CREATE TABLE fact(id INTEGER PRIMARY KEY,k INTEGER,v INTEGER)");
    try run("INSERT INTO fact VALUES(1,1,10),(2,1,10),(3,1,30),(4,2,5),(5,2,NULL),(6,NULL,7)");
    var fixtures=std.mem.splitScalar(u8,@embedFile("evidence/windows-pg16.tsv"),'\n');
    while(fixtures.next()) |line| {
        if(line.len==0) continue;const tab=std.mem.indexOfScalar(u8,line,'\t') orelse return error.InvalidFixture;
        try fixture(line[0..tab],line[tab+1..]);
    }
    try run("SELECT id,RANK() OVER (ORDER BY v DESC NULLS LAST) FROM fact ORDER BY id");
    const ranks=[_]i64{2,2,1,5,6,4};try check(result.row_count==6);
    for(ranks,0..) |rank,i| try check(result.rows[i].cells[1].integer==rank);
    try run("SELECT id,SUM(v) OVER () FROM fact ORDER BY id LIMIT 2");
    try check(result.row_count==2 and result.rows[0].cells[1].integer==62 and result.rows[1].cells[1].integer==62);
    try run("SELECT k,SUM(v),RANK() OVER (ORDER BY SUM(v) DESC) FROM fact GROUP BY k ORDER BY k NULLS LAST");
    try check(result.row_count==3 and result.rows[0].cells[2].integer==1 and result.rows[1].cells[2].integer==3 and result.rows[2].cells[2].integer==2);
    try run("WITH revenue AS (SELECT k,SUM(v) AS revenue FROM fact GROUP BY k) SELECT k,revenue,ROUND(100.0*revenue/SUM(revenue) OVER (),4) FROM revenue ORDER BY revenue DESC LIMIT 2");
    try check(result.row_count==2 and result.rows[0].cells[2]==.numeric);
    try run("SELECT id,RANK() OVER (PARTITION BY k ORDER BY v),DENSE_RANK() OVER (PARTITION BY k ORDER BY v),ROW_NUMBER() OVER (PARTITION BY k ORDER BY v,id) FROM fact ORDER BY id");
    try check(result.rows[0].cells[1].integer==1 and result.rows[1].cells[1].integer==1 and result.rows[2].cells[1].integer==3);
    try check(result.rows[2].cells[2].integer==2 and result.rows[2].cells[3].integer==3);
    try run("SELECT id,SUM(v) OVER (PARTITION BY k ORDER BY v),SUM(v) OVER (PARTITION BY k ORDER BY v,id ROWS UNBOUNDED PRECEDING) FROM fact ORDER BY id");
    try check(result.rows[0].cells[1].integer==20 and result.rows[1].cells[1].integer==20 and result.rows[2].cells[1].integer==50);
    try check(result.rows[0].cells[2].integer==10 and result.rows[1].cells[2].integer==20 and result.rows[2].cells[2].integer==50);
    try reject("SELECT id FROM fact WHERE RANK() OVER ()>1",error.WindowingError);
    try reject("SELECT RANK() OVER () FROM fact GROUP BY RANK() OVER ()",error.WindowingError);
    try reject("SELECT RANK() OVER () FROM fact HAVING RANK() OVER ()>1",error.WindowingError);
    try reject("SELECT SUM(RANK() OVER ()) FROM fact",error.GroupingError);
    try reject("SELECT COUNT(*) FILTER (WHERE RANK() OVER ()>0) FROM fact",error.WindowingError);
    try reject("SELECT RANK() OVER (ORDER BY SUM(RANK() OVER ())) FROM fact",error.WindowingError);
    try reject("SELECT SUM(RANK() OVER ()) OVER () FROM fact",error.WindowingError);
    try reject("SELECT RANK() OVER (ORDER BY ROW_NUMBER() OVER ()) FROM fact",error.WindowingError);
    try reject("SELECT SUM(DISTINCT v) OVER () FROM fact",error.UnsupportedStatement);
    try reject("SELECT SUM(v) FILTER (WHERE id>1) OVER () FROM fact",error.UnsupportedStatement);
    try reject("SELECT SUM(v) OVER (ORDER BY v RANGE UNBOUNDED PRECEDING) FROM fact",error.UnsupportedStatement);
    try reject("SELECT id,SUM(v) OVER ()/(id-3) FROM fact ORDER BY id",error.DivisionByZero);
    const q="SELECT id,SUM(v) OVER (PARTITION BY k ORDER BY v),RANK() OVER (ORDER BY v DESC) FROM fact ORDER BY id";
    var control:sql.ExecutionControl=.{};db.session.control=&control;try run(q);const used=control.used;
    try check(used>0);
    for(1..used) |limit| {control.reset(limit);try reject(q,error.QueryWorkLimit);try check(control.used==limit);}
    var cancel:Cancel=.{.remaining=0};control.context=&cancel;control.poll=Cancel.poll;control.poll_interval=1;
    for(0..used) |limit| {cancel.remaining=limit;control.reset(0);try reject(q,error.QueryCanceled);}
    db.session.control=null;try run(q);try check(result.row_count==6);
    std.debug.print("PASS SQL windows: {d} assertions\n",.{assertions});
}
