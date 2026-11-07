//! Stored expression source ownership and deferred constant validation.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=8,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var digest:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.ExpressionSourceContractFailed;}
fn truth(source:[]const u8,wanted:?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1 and r.column_types[0]==.boolean);
    const cell=r.rows[0].cells[0];if(wanted)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);
}
fn scalar(source:[]const u8,wanted:i64) !void {db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};try check(r.row_count==1 and r.rows[0].cells[0]==.integer and r.rows[0].cells[0].integer==wanted);}
fn booleans(source:[]const u8,wanted:[]const ?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};try check(r.column_count==1 and r.row_count==wanted.len and r.column_types[0]==.boolean);
    for(wanted,0..)|value,index|{const cell=r.rows[index].cells[0];if(value)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);}
}
fn mutate(source:[]const u8,wanted:usize) !void {db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};try check(r.affected_rows==wanted);}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_| return error.InvalidMembershipAccepted else |err| {if(err!=wanted)std.debug.print("{s}: {s}\n",.{source,@errorName(err)});try check(err==wanted);}
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
    for(0..r.row_count)|row|for(0..r.column_count)|column|try check(std.meta.eql(r.rows[row].cells[column],before.rows[row].cells[column]));
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn copySources() !void {
    var row:DB.Row=undefined;
    {
        const slot=try db.begin();defer db.abort(slot);
        const source="COPY ds(id) FROM STDIN";
        _=try db.copyBegin(slot,source,false);
        try db.copyBuild(slot,source,&.{"6"},&row);
        try check(row.cells[1]==.null_value and row.cells[2]==.null_value);
        try db.copyInsert(slot,&row);try check(try db.copyEnd(slot)==1);
    }
    {
        const slot=try db.begin();defer db.abort(slot);
        const source="COPY gs(id,v) FROM STDIN";
        _=try db.copyBegin(slot,source,false);
        try db.copyBuild(slot,source,&.{"3","copied"},&row);
        try check(row.cells[2]==.null_value and row.cells[3]==.null_value);
        try db.copyInsert(slot,&row);try check(try db.copyEnd(slot)==1);
    }
    {
        const slot=try db.begin();defer db.abort(slot);
        const source="COPY de(id,a) FROM STDIN";
        _=try db.copyBegin(slot,source,false);
        try db.copyBuild(slot,source,&.{"2","true"},&row);
        try check(row.cells[1]==.boolean and row.cells[1].boolean);
        try db.copyInsert(slot,&row);try check(try db.copyEnd(slot)==1);
    }
    {
        const slot=try db.begin();defer db.abort(slot);
        const source="COPY de(id) FROM STDIN";
        _=try db.copyBegin(slot,source,false);
        if(db.copyBuild(slot,source,&.{"2"},&row)) |_|return error.CopyDefaultErrorLost else |err|try check(err==error.DivisionByZero);
    }
}
pub fn main(init:std.process.Init) !void {
    errdefer std.debug.print("source contract assertions={d}\n",.{assertions});
    try db.execute("CREATE TABLE ds(id INT PRIMARY KEY,a BOOLEAN DEFAULT(ROW('10.5'::numeric,2) IN(NULL)),b BOOLEAN DEFAULT(ROW(20.25::float8,3) IN(NULL)))",&r);
    try mutate("INSERT INTO ds(id) VALUES(1)",1);
    try db.execute("SELECT a,b FROM ds WHERE id=1",&r);try check(r.row_count==1 and r.rows[0].cells[0]==.null_value and r.rows[0].cells[1]==.null_value);
    try mutate("INSERT INTO ds VALUES(2,TRUE,FALSE)",1);
    try mutate("INSERT INTO ds VALUES(3,DEFAULT,TRUE),(4,FALSE,DEFAULT)",2);
    try mutate("INSERT INTO ds(id) SELECT 5",1);
    try mutate("UPDATE ds SET a=DEFAULT,b=DEFAULT WHERE id=2",1);
    try mutate("INSERT INTO ds VALUES(1,TRUE,FALSE) ON CONFLICT(id) DO UPDATE SET a=DEFAULT,b=DEFAULT",1);
    try booleans("SELECT a FROM ds ORDER BY id",&.{null,null,null,false,null});
    try db.execute("CREATE TABLE gs(id INT PRIMARY KEY,v TEXT,a BOOLEAN GENERATED ALWAYS AS(ROW('10.5'::numeric,v) IN(NULL)) STORED,b BOOLEAN GENERATED ALWAYS AS(ROW(20.25::float8,v) BETWEEN NULL AND NULL) STORED)",&r);
    try mutate("INSERT INTO gs(id,v) VALUES(1,'first'),(2,'second')",2);
    try booleans("SELECT a FROM gs ORDER BY id",&.{null,null});
    try mutate("UPDATE gs SET v='changed' WHERE id=1",1);
    try truth("SELECT b FROM gs WHERE id=1",null);
    try db.execute("CREATE TABLE de(id INT PRIMARY KEY,a BOOLEAN DEFAULT(ROW(1/0,2) IN(NULL)))",&r);
    try mutate("INSERT INTO de VALUES(1,TRUE)",1);
    try rejects("INSERT INTO de(id) VALUES(2)",error.DivisionByZero);
    try rejects("INSERT INTO de VALUES(2,DEFAULT)",error.DivisionByZero);
    try mutate("UPDATE de SET a=FALSE WHERE id=1",1);
    try rejects("UPDATE de SET a=DEFAULT WHERE id=1",error.DivisionByZero);
    try truth("SELECT a FROM de WHERE id=1",false);
    try mutate("INSERT INTO de VALUES(1,TRUE) ON CONFLICT(id) DO NOTHING",0);
    try rejects("INSERT INTO de VALUES(1,TRUE) ON CONFLICT(id) DO UPDATE SET a=DEFAULT",error.DivisionByZero);
    try scalar("SELECT COUNT(*) FROM de",1);
    try rejects("CREATE TABLE ge(id INT PRIMARY KEY,a BOOLEAN GENERATED ALWAYS AS(ROW(1/0,2) IN(NULL)) STORED)",error.DivisionByZero);
    try rejects("SELECT COUNT(*) FROM ge",error.TableNotFound);
    try db.execute("CREATE TABLE ge(id INT PRIMARY KEY,a BOOLEAN GENERATED ALWAYS AS(ROW('30.75'::numeric,2) IN(NULL)) STORED)",&r);
    try mutate("INSERT INTO ge(id) VALUES(1)",1);
    try truth("SELECT a FROM ge",null);
    try rejects("CREATE TABLE gbad(id INT PRIMARY KEY,a BOOLEAN GENERATED ALWAYS AS(ROW(missing,2) IN(NULL)) STORED)",error.ColumnNotFound);
    try rejects("SELECT COUNT(*) FROM gbad",error.TableNotFound);
    try db.execute("CREATE SEQUENCE es",&r);
    try db.execute("CREATE TABLE vs(id INT PRIMARY KEY,a BOOLEAN DEFAULT(ROW(nextval('es'),1) IN(NULL)))",&r);
    try mutate("INSERT INTO vs(id) VALUES(1)",1);
    try scalar("SELECT nextval('es')",1);
    try truth("SELECT a FROM vs",null);
    try rejects("SELECT ROW('50'::int,1/0) IN(NULL)",error.DivisionByZero);
    // WAL replay owns copied schema text; later caller buffers are unrelated.
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE replayed(id INT PRIMARY KEY,v TEXT,a BOOLEAN DEFAULT(ROW('11.25'::numeric,2) IN(NULL)),b BOOLEAN GENERATED ALWAYS AS(ROW(22.5::float8,v) IN(NULL)) STORED)",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    @memset(&bytes,0xa5);
    try replayed.execute("INSERT INTO replayed(id,v) VALUES(1,'literal')",&r);
    try replayed.execute("SELECT a,b FROM replayed",&r);
    try check(r.row_count==1 and r.rows[0].cells[0]==.null_value and r.rows[0].cells[1]==.null_value);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("INSERT INTO ds(id) VALUES(6)",error.QueryWorkLimit);
    var interrupt:sql.ExecutionControl=.{.poll=canceled,.poll_interval=1};db.session.control=&interrupt;
    try rejects("INSERT INTO ds(id) VALUES(6)",error.QueryCanceled);db.session.control=null;
    try scalar("SELECT COUNT(*) FROM ds",5);
    try copySources();
    try scalar("SELECT COUNT(*) FROM ds",5);
    try scalar("SELECT COUNT(*) FROM gs",2);
    try scalar("SELECT COUNT(*) FROM de",1);
    var buffer:[160]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-expression-sources\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
