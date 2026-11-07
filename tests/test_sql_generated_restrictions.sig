//! Stored generated-column dependencies, immutability and safe branch reduction.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=8,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var digest:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.GeneratedRestrictionContractFailed;}
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
var polls:usize=0;
fn cancelSecond(_: ?*anyopaque) sql.Error!void {polls+=1;if(polls==2)return error.QueryCanceled;}
pub fn main(init:std.process.Init) !void {
    errdefer std.debug.print("generated assertions={d}\n",.{assertions});
    try db.execute("CREATE SEQUENCE grseq",&r);
    try rejects("CREATE TABLE bad(id INT,g BIGINT GENERATED ALWAYS AS(nextval('grseq')) STORED)",error.InvalidObjectDefinition);
    try rejects("SELECT COUNT(*) FROM bad",error.TableNotFound);
    try scalar("SELECT nextval('grseq')",1);
    try rejects("CREATE TABLE bad(id INT,g TIMESTAMPTZ GENERATED ALWAYS AS(now()) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g TIMESTAMPTZ GENERATED ALWAYS AS(clock_timestamp()) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g DATE GENERATED ALWAYS AS(CURRENT_DATE) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g TEXT GENERATED ALWAYS AS(current_database()) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g NUMERIC GENERATED ALWAYS AS(round(nextval('grseq')::numeric)) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g BIGINT GENERATED ALWAYS AS(COALESCE(NULL,nextval('grseq'))) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g BIGINT GENERATED ALWAYS AS(NULLIF(nextval('grseq'),0)) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g BIGINT GENERATED ALWAYS AS(GREATEST(1,nextval('grseq'))) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g INT GENERATED ALWAYS AS(g+1) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g INT GENERATED ALWAYS AS(id+1) STORED,h INT GENERATED ALWAYS AS(g+1) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g INT GENERATED ALWAYS AS(h+1) STORED,h INT GENERATED ALWAYS AS(id+1) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g INT GENERATED ALWAYS AS(CASE WHEN FALSE THEN g ELSE 0 END) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g BOOLEAN GENERATED ALWAYS AS(ROW(g,1) IN(NULL)) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(id INT,g INT GENERATED ALWAYS AS((SELECT 1)) STORED)",error.UnsupportedStatement);
    try rejects("CREATE TABLE bad(id INT,g BOOLEAN GENERATED ALWAYS AS(EXISTS(SELECT 1)) STORED)",error.UnsupportedStatement);
    try rejects("CREATE TABLE bad(id INT,g BOOLEAN GENERATED ALWAYS AS(1=ANY(SELECT 1)) STORED)",error.UnsupportedStatement);
    try rejects("CREATE TABLE bad(id INT,g BIGINT GENERATED ALWAYS AS(SUM(id)) STORED)",error.GroupingError);
    try rejects("CREATE TABLE bad(x TEXT,g DATE GENERATED ALWAYS AS(x::date) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(x TEXT,g TIMESTAMP GENERATED ALWAYS AS(x::timestamp) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(x TIMESTAMP,g TIMESTAMPTZ GENERATED ALWAYS AS(x::timestamptz) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(x TIMESTAMPTZ,g DATE GENERATED ALWAYS AS(x::date) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(x DATE,g TEXT GENERATED ALWAYS AS(x::text) STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(x INT,g TIMESTAMPTZ GENERATED ALWAYS AS(TIMESTAMPTZ '2025-01-01 00:00:00+00'+INTERVAL '1 day') STORED)",error.InvalidObjectDefinition);
    try rejects("CREATE TABLE bad(x INT,g INT GENERATED ALWAYS AS(1/0) STORED)",error.DivisionByZero);
    try rejects("CREATE TABLE bad(x INT,g BIGINT GENERATED ALWAYS AS(CASE WHEN TRUE THEN 2147483647+1 ELSE 0::bigint END) STORED)",error.IntegerOverflow);
    try db.execute("CREATE TABLE good(id INT PRIMARY KEY,b INT,x TEXT,g INT GENERATED ALWAYS AS(x::int) STORED,n NUMERIC GENERATED ALWAYS AS(round(b::numeric+1.25,1)) STORED,j INT GENERATED ALWAYS AS(jsonb_array_length('[1,2]'::jsonb)) STORED)",&r);
    try mutate("INSERT INTO good(id,b,x) VALUES(1,2,'7')",1);
    try truth("SELECT g=7 AND n=3.3 AND j=2 FROM good",true);
    try mutate("UPDATE good SET b=3,x='8' WHERE id=1",1);
    try truth("SELECT g=8 AND n=4.3 AND j=2 FROM good",true);
    try db.execute("CREATE TABLE pruned(id INT PRIMARY KEY,a BIGINT GENERATED ALWAYS AS(CASE WHEN TRUE THEN 1 ELSE nextval('grseq') END) STORED,b BIGINT GENERATED ALWAYS AS(COALESCE(1,nextval('grseq'))) STORED,c BIGINT GENERATED ALWAYS AS(NULLIF(NULL,nextval('grseq'))) STORED,d BIGINT GENERATED ALWAYS AS(nextval(NULL)) STORED,e BOOLEAN GENERATED ALWAYS AS(nextval('grseq')>0 AND FALSE) STORED,f BOOLEAN GENERATED ALWAYS AS(nextval('grseq')>0 OR TRUE) STORED,g BOOLEAN GENERATED ALWAYS AS(ROW(nextval('grseq'),1) IN(NULL)) STORED)",&r);
    try mutate("INSERT INTO pruned(id) VALUES(1)",1);
    try truth("SELECT a+b=2 AND c IS NULL AND d IS NULL AND NOT e AND f AND g IS NULL FROM pruned",true);
    try scalar("SELECT nextval('grseq')",2);
    try mutate("UPDATE pruned SET id=2 WHERE id=1",1);
    try scalar("SELECT nextval('grseq')",3);
    try db.execute("CREATE TABLE nullclock(id INT PRIMARY KEY,g BOOLEAN GENERATED ALWAYS AS(ROW(now(),1) IN(NULL)) STORED)",&r);
    try mutate("INSERT INTO nullclock(id) VALUES(1)",1);
    try truth("SELECT g FROM nullclock",null);
    try db.execute("CREATE TABLE temporal(id INT PRIMARY KEY,g TIMESTAMP GENERATED ALWAYS AS(TIMESTAMP '2025-01-01 00:00:00'+INTERVAL '1 day') STORED)",&r);
    try mutate("INSERT INTO temporal(id) VALUES(1)",1);
    try truth("SELECT g=TIMESTAMP '2025-01-02 00:00:00' FROM temporal",true);
    try db.execute("DROP TABLE temporal",&r);
    try db.execute("CREATE TABLE normaldefault(id INT PRIMARY KEY,g BIGINT DEFAULT(nextval('grseq')))",&r);
    try mutate("INSERT INTO normaldefault(id) VALUES(1)",1);
    try scalar("SELECT g FROM normaldefault",4);
    try db.execute("CREATE TABLE nulldata(id INT PRIMARY KEY,x TEXT,g BOOLEAN GENERATED ALWAYS AS(ROW(x::date,1) IN(NULL)) STORED)",&r);
    try mutate("INSERT INTO nulldata(id,x) VALUES(1,'invalid date')",1);
    try truth("SELECT g FROM nulldata",null);
    try db.execute("CREATE TABLE widen(id INT PRIMARY KEY,x INT,g BIGINT GENERATED ALWAYS AS(CASE WHEN TRUE THEN x+1 ELSE 0::bigint END) STORED)",&r);
    try mutate("INSERT INTO widen(id,x) VALUES(1,1)",1);
    try rejects("UPDATE widen SET x=2147483647",error.IntegerOverflow);
    try scalar("SELECT g FROM widen",2);
    try db.execute("CREATE TABLE prune_err(id INT PRIMARY KEY,g BOOLEAN GENERATED ALWAYS AS(CASE WHEN TRUE THEN TRUE ELSE ROW(1/0,1) IN(NULL) END) STORED)",&r);
    try mutate("INSERT INTO prune_err(id) VALUES(1)",1);
    try truth("SELECT g FROM prune_err",true);
    try rejects("CREATE TABLE bad(id INT,g BIGINT GENERATED ALWAYS AS(CASE WHEN id=1 THEN nextval('grseq') ELSE 1 END) STORED)",error.InvalidObjectDefinition);
    try scalar("SELECT nextval('grseq')",5);
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,a INT GENERATED ALWAYS AS(CASE WHEN TRUE THEN id+1 ELSE nextval(NULL) END) STORED)",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id) VALUES(1)",&r);try replayed.execute("SELECT a FROM g",&r);
    try check(r.row_count==1 and r.rows[0].cells[0].integer==2);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("CREATE TABLE blocked(id INT PRIMARY KEY,g INT GENERATED ALWAYS AS(id+1) STORED)",error.QueryWorkLimit);
    try check(control.used==1);db.session.control=null;
    try rejects("SELECT COUNT(*) FROM blocked",error.TableNotFound);
    var interrupt:sql.ExecutionControl=.{.poll=cancelSecond,.poll_interval=1};db.session.control=&interrupt;
    try rejects("CREATE TABLE blocked(id INT PRIMARY KEY,g INT GENERATED ALWAYS AS(id+1) STORED)",error.QueryCanceled);
    try check(polls==2);db.session.control=null;
    try rejects("SELECT COUNT(*) FROM blocked",error.TableNotFound);
    try db.execute("CREATE TABLE blocked(id INT PRIMARY KEY,g INT GENERATED ALWAYS AS(id+1) STORED)",&r);
    try mutate("INSERT INTO blocked(id) VALUES(1)",1);
    try scalar("SELECT g FROM blocked",2);
    var buffer:[160]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-generated-restrictions\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
