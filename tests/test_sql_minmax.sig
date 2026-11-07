//! PG.FUNC.MINMAX: common typing, NULL exclusion and eager argument evaluation.
const std=@import("std"); const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=8,.rows_per_table=16,.text_bytes=128});
var db:DB=.{};var r:DB.Result=.{};var checks:usize=0;
fn check(ok:bool) !void {checks+=1;if(!ok){std.debug.print("minmax assertion {d}\n",.{checks});return error.MinmaxContractFailed;}}
fn value(source:[]const u8,wanted:?[]const u8,ty:sql.DataType) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1 and r.column_types[0]==ty);
    const cell=&r.rows[0].cells[0];
    if(wanted) |text| {var buffer:[DB.Io.format_bytes]u8=undefined;try check(cell.*!=.null_value and std.mem.eql(u8,text,try DB.Io.format(cell,false,&db.session,&buffer)));}
    else try check(cell.*==.null_value);
}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_| return error.InvalidMinmaxAccepted else |err| try check(err==wanted);
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
}
pub fn main(init:std.process.Init) !void {
    try value("SELECT GREATEST(1,NULL,3)","3",.integer32);
    try value("SELECT LEAST(1,NULL,3)","1",.integer32);
    try value("SELECT GREATEST(NULL,NULL)",null,.text);
    try value("SELECT LEAST(NULL::bigint,NULL)",null,.integer);
    try value("SELECT GREATEST(7)","7",.integer32);
    try value("SELECT LEAST(1::smallint,2::bigint)","1",.integer);
    try value("SELECT GREATEST(1,2.5)","2.5",.numeric);
    try value("SELECT GREATEST('9',2)","9",.integer32);
    try value("SELECT LEAST('9','10')","10",.text);
    try value("SELECT GREATEST(FALSE,TRUE)","t",.boolean);
    try value("SELECT LEAST('NaN'::double precision,2::double precision)","2",.double);
    try value("SELECT GREATEST('NaN'::double precision,2::double precision)","NaN",.double);
    try value("SELECT LEAST(DATE '2026-01-01',DATE '2025-01-01')","2025-01-01",.date);
    try value("SELECT GREATEST('{\"a\":1}'::jsonb,'{\"a\":2}'::jsonb)","{\"a\": 2}",.jsonb);
    try db.execute("CREATE TABLE t(id INT PRIMARY KEY,v INT)",&r);
    try db.execute("INSERT INTO t VALUES(1,NULL),(2,5)",&r);
    try value("SELECT GREATEST(SUM(v),3) FROM t","5",.integer);
    try value("SELECT COUNT(*) FROM t WHERE LEAST(v,3)=3","2",.integer);
    try db.execute("CREATE SEQUENCE s",&r);
    try value("SELECT GREATEST(nextval('s'),nextval('s'),nextval('s'))","3",.integer);
    try value("SELECT currval('s')","3",.integer);
    try rejects("SELECT GREATEST(NULL::int,1/0)",error.DivisionByZero);
    try rejects("SELECT GREATEST(1,TRUE)",error.TypeMismatch);
    try rejects("SELECT LEAST('{}'::json,'{}'::json)",error.UndefinedFunction);
    try rejects("SELECT GREATEST()",error.Syntax);
    try rejects("SELECT \"greatest\"(1,2)",error.UndefinedFunction);
    try rejects("SELECT GREATEST(v,1/(2-id)) FROM t ORDER BY id",error.DivisionByZero);
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var record:[16384]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE d(id INT PRIMARY KEY,v INT DEFAULT GREATEST(1,2),g INT GENERATED ALWAYS AS(LEAST(id,v)) STORED)",&r,&record,&used,null,null);
    try replayed.applyChangeRecord(record[0..used],&scratch);
    try replayed.execute("INSERT INTO d(id) VALUES(2)",&r);
    try replayed.execute("SELECT v,g FROM d",&r);
    try check(r.row_count==1 and r.rows[0].cells[0].integer==2 and r.rows[0].cells[1].integer==2);
    var buffer:[128]u8=undefined;
    const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-minmax\",\"pass\":true,\"assertions\":{d}}}\n",.{checks});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
