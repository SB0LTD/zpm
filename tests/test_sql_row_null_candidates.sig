//! Bare NULL record candidates retain binding dependencies without runtime effects.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=4,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var digest:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.RowNullCandidateContractFailed;}
fn truth(source:[]const u8,wanted:?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1 and r.column_types[0]==.boolean);
    const cell=r.rows[0].cells[0];if(wanted)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);
}
fn scalar(source:[]const u8,wanted:i64) !void {try db.execute(source,&r);try check(r.row_count==1 and r.rows[0].cells[0]==.integer and r.rows[0].cells[0].integer==wanted);}
fn booleans(source:[]const u8,wanted:[]const ?bool) !void {
    try db.execute(source,&r);try check(r.column_count==1 and r.row_count==wanted.len and r.column_types[0]==.boolean);
    for(wanted,0..)|value,index|{const cell=r.rows[index].cells[0];if(value)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);}
}
fn mutate(source:[]const u8,wanted:usize) !void {try db.execute(source,&r);try check(r.affected_rows==wanted);}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_| return error.InvalidMembershipAccepted else |err| {if(err!=wanted)std.debug.print("{s}: {s}\n",.{source,@errorName(err)});try check(err==wanted);}
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
    for(0..r.row_count)|row|for(0..r.column_count)|column|try check(std.meta.eql(r.rows[row].cells[column],before.rows[row].cells[column]));
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
pub fn main(init:std.process.Init) !void {
    try truth("SELECT ROW(1,2) IN (NULL)",null);
    try truth("SELECT ROW(1,2) NOT IN (NULL)",null);
    try truth("SELECT ROW(1,2) IN (NULL,ROW(1,2))",true);
    try truth("SELECT ROW(1,2) NOT IN (ROW(2,1),NULL)",null);
    try truth("SELECT ROW(NULL,2) IN (NULL,ROW(1,2))",null);
    try truth("SELECT ROW(1,2) IN (ROW(1,2),NULL,NULL)",true);
    try truth("SELECT ROW() IN(NULL)",null);
    try truth("SELECT ROW('{}'::json,2) IN(NULL)",null);
    try rejects("SELECT ROW(1/0,2) IN(NULL)",error.DivisionByZero);
    try rejects("SELECT ROW(jsonb_array_length('{}'::jsonb),2) IN(NULL)",error.InvalidParameterValue);
    try db.execute("CREATE SEQUENCE ns",&r);
    try truth("SELECT ROW(nextval('ns'),0) IN(NULL)",null);
    try scalar("SELECT nextval('ns')",1);
    try truth("SELECT ROW(nextval('ns'),0) IN(NULL,ROW(2,0))",true);
    try scalar("SELECT currval('ns')",2);
    try truth("SELECT ROW(nextval('ns'),0) NOT IN(NULL,ROW(3,0))",false);
    try scalar("SELECT currval('ns')",3);
    try rejects("SELECT ROW(nextval('ns')+1/0,0) IN(NULL)",error.DivisionByZero);
    try scalar("SELECT currval('ns')",3);
    try truth("SELECT ROW(CASE WHEN TRUE THEN nextval('ns') ELSE 1/0 END,0) IN(NULL)",null);
    try truth("SELECT ROW(CASE WHEN FALSE THEN 1/0 ELSE nextval('ns') END,0) IN(NULL)",null);
    try truth("SELECT ROW(CASE 1 WHEN 1 THEN nextval('ns') ELSE 1/0 END,0) IN(NULL)",null);
    try truth("SELECT ROW(COALESCE(1,nextval('ns')+1/0),0) IN(NULL)",null);
    try rejects("SELECT ROW(COALESCE(nextval('ns'),1/0),0) IN(NULL)",error.DivisionByZero);
    try scalar("SELECT currval('ns')",3);
    try db.execute("CREATE TABLE nt(id INT PRIMARY KEY,a INT,b INT)",&r);
    try db.execute("INSERT INTO nt VALUES(1,1,2),(2,NULL,2),(3,2,1),(4,NULL,NULL)",&r);
    try booleans("SELECT (a,b) IN(NULL,(1,2)) FROM nt ORDER BY id",&.{true,null,null,null});
    try scalar("SELECT COUNT(*) FROM nt WHERE (a,b) IN(NULL,(1,2))",1);
    try truth("SELECT ROW(10/(id-id),2) IN(NULL) FROM nt WHERE id=1",null);
    try truth("SELECT ROW(COUNT(*),SUM(id)) IN(NULL) FROM nt",null);
    try truth("SELECT ROW(SUM(1e308::float8),2) IN(NULL) FROM nt",null);
    try rejects("SELECT ROW(SUM(1/0),2) IN(NULL) FROM nt",error.DivisionByZero);
    try rejects("SELECT ROW(CASE WHEN a=1 THEN 1/0 ELSE nextval('ns') END,0) IN(NULL) FROM nt",error.DivisionByZero);
    try scalar("SELECT currval('ns')",3);
    try rejects("SELECT ROW(a,b) IN(NULL) FROM nt GROUP BY b",error.GroupingError);
    try rejects("SELECT ROW(a,1/0) IN(NULL) FROM nt GROUP BY b",error.GroupingError);
    try rejects("SELECT ROW(SUM(id),a) IN(NULL) FROM nt",error.GroupingError);
    try booleans("SELECT ROW(b,COUNT(*)) IN(NULL) FROM nt GROUP BY b ORDER BY 1",&.{null,null,null});
    try booleans("SELECT (a,b) IN(NULL) FROM nt GROUP BY (a,b) IN(NULL)",&.{null});
    try scalar("SELECT COUNT(*) FROM nt x WHERE EXISTS(SELECT 1 FROM nt y WHERE (x.id,y.a) IN(NULL,(1,1)))",1);
    try mutate("UPDATE nt SET b=9 WHERE (a,b) IN(NULL,(1,2))",1);
    try mutate("DELETE FROM nt WHERE (a,b) NOT IN(NULL,(1,9))",0);
    try rejects("SELECT ROW(missing,2) IN(NULL) FROM nt",error.ColumnNotFound);
    try rejects("SELECT ROW(SUM(SUM(id)),2) IN(NULL) FROM nt",error.GroupingError);
    try rejects("SELECT ROW(1,2) IN(NULL,ROW(1))",error.Syntax);
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,a INT,b INT,member BOOLEAN GENERATED ALWAYS AS((a,b) IN(NULL,(1,2))) STORED,absent BOOLEAN DEFAULT(ROW(1,2) NOT IN(NULL)))",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id,a,b) VALUES(1,1,2),(2,NULL,2)",&r);
    try replayed.execute("SELECT member,absent FROM g ORDER BY id",&r);
    try check(r.row_count==2 and r.rows[0].cells[0].boolean and r.rows[1].cells[0]==.null_value and r.rows[0].cells[1]==.null_value and r.rows[1].cells[1]==.null_value);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("SELECT (a,b) IN(NULL) FROM nt",error.QueryWorkLimit);
    var interrupt:sql.ExecutionControl=.{.poll=canceled,.poll_interval=1};db.session.control=&interrupt;
    try rejects("SELECT (a,b) NOT IN(NULL) FROM nt",error.QueryCanceled);db.session.control=null;
    var buffer:[160]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-row-null-candidates\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
