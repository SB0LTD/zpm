//! Scalar and flat row BETWEEN: inclusive, asymmetric and symmetric ranges.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=4,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var digest:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.BetweenContractFailed;}
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
fn order(left:[2]?i64,right:[2]?i64) ?i8 {for(left,right)|a,b|{if(a==null or b==null)return null;if(a.?!=b.?)return if(a.?<b.?)-1 else 1;}return 0;}
fn and3(a:?bool,b:?bool) ?bool {return if(a==false or b==false)false else if(a==null or b==null)null else true;}
fn or3(a:?bool,b:?bool) ?bool {return if(a==true or b==true)true else if(a==null or b==null)null else false;}
fn inside(value:[2]?i64,low:[2]?i64,high:[2]?i64) ?bool {const a=order(value,low);const b=order(value,high);return and3(if(a)|v|v>=0 else null,if(b)|v|v<=0 else null);}
fn expected(value:[2]?i64,low:[2]?i64,high:[2]?i64,symmetric:bool,negated:bool) ?bool {const forward=inside(value,low,high);const result=if(symmetric)or3(forward,inside(value,high,low)) else forward;return if(result)|v|v!=negated else null;}
fn hashByte(byte:u8) void {digest=(digest^byte)*%1099511628211;}
fn record(source:[]const u8,wanted:?bool) !void {for(source)|byte|hashByte(byte);hashByte(if(wanted)|v|@intFromBool(v) else 2);try truth(source,wanted);}
fn matrix() !void {
    const values=[_]?i64{null,-1,1};const words=[_][]const u8{"NULL","-1","1"};const forms=[_][]const u8{"","ASYMMETRIC ","SYMMETRIC "};var buffer:[256]u8=undefined;
    for([_][]const u8{"ROW",""})|prefix|for([_]bool{false,true})|negated|for(forms,0..)|form,fi| {
        for(values,0..)|a,ai|for(values,0..)|b,bi|for(values,0..)|c,ci|for(values,0..)|d,di|for(values,0..)|e,ei|for(values,0..)|f,xi| {
            const source=try std.fmt.bufPrint(&buffer,"SELECT {s}({s},{s}) {s}BETWEEN {s}{s}({s},{s}) AND {s}({s},{s})",.{prefix,words[ai],words[bi],if(negated)"NOT " else "",form,prefix,words[ci],words[di],prefix,words[ei],words[xi]});
            try record(source,expected(.{a,b},.{c,d},.{e,f},fi==2,negated));
        };
    };
    for([_]bool{false,true})|negated|for(forms,0..)|form,fi|for(values,0..)|a,ai|for(values,0..)|b,bi|for(values,0..)|c,ci| {
        try record(try std.fmt.bufPrint(&buffer,"SELECT {s} {s}BETWEEN {s}{s} AND {s}",.{words[ai],if(negated)"NOT " else "",form,words[bi],words[ci]}),expected(.{a,0},.{b,0},.{c,0},fi==2,negated));
    };
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
pub fn main(init:std.process.Init) !void {
    try matrix();
    try truth("SELECT ROW(1) BETWEEN ROW(1) AND ROW(1)",true);
    try truth("SELECT (1,2) BETWEEN (1,2) AND (2,1)",true);
    try truth("SELECT (1,2) BETWEEN SYMMETRIC (2,1) AND (1,2)",true);
    try truth("SELECT ROW('1',2) BETWEEN ROW(1,2) AND ROW('2'::text,2)",true);
    try truth("SELECT '1' BETWEEN 1 AND '2'::text",true);
    try truth("SELECT 16777217 BETWEEN 16777217 AND 16777216::real",false);
    try truth("SELECT ROW(16777217,0) BETWEEN ROW(16777217,0) AND ROW(16777216::real,0)",false);
    try truth("SELECT DATE '2025-01-01' BETWEEN TIMESTAMP '2024-12-31 12:00:00' AND DATE '2025-01-01'",true);
    try truth("SELECT ROW('NaN'::float8,0) BETWEEN ROW(1::float8,0) AND ROW('NaN'::float8,0)",true);
    try truth("SELECT ROW(1,2) BETWEEN NULL AND ROW(2,1)",null);
    try truth("SELECT ROW(1,2) BETWEEN NULL AND ROW(0,0)",false);
    try truth("SELECT ROW(1,2) NOT BETWEEN ROW(0,0) AND NULL",null);
    try truth("SELECT NULL BETWEEN ROW(1,2) AND ROW(2,1)",null);
    try truth("SELECT ROW() BETWEEN NULL AND NULL",null);
    try truth("SELECT ROW('{}'::json,2) BETWEEN NULL AND NULL",null);
    try truth("SELECT ROW(1,2) BETWEEN SYMMETRIC NULL AND ROW(2,1)",null);
    try db.execute("CREATE SEQUENCE bs",&r);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT nextval('bs') BETWEEN 1 AND 1",false);
    try scalar("SELECT currval('bs')",2);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT ROW(nextval('bs'),0) BETWEEN ROW(1,0) AND ROW(1,0)",false);
    try scalar("SELECT currval('bs')",2);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT ROW(nextval('bs'),0) NOT BETWEEN ROW(2,0) AND ROW(3,0)",true);
    try scalar("SELECT currval('bs')",1);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT ROW(nextval('bs'),0) BETWEEN SYMMETRIC ROW(3,0) AND ROW(1,0)",true);
    try scalar("SELECT currval('bs')",3);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT ROW(nextval('bs'),0) NOT BETWEEN SYMMETRIC ROW(3,0) AND ROW(1,0)",false);
    try scalar("SELECT currval('bs')",3);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT ROW(2,0) BETWEEN ROW(nextval('bs'),0) AND ROW(nextval('bs'),0)",true);
    try scalar("SELECT currval('bs')",2);
    try scalar("SELECT setval('bs',1,true)",1);
    try truth("SELECT ROW(0,nextval('bs')) BETWEEN ROW(1,nextval('bs')) AND ROW(2,nextval('bs'))",false);
    try scalar("SELECT currval('bs')",1);
    try scalar("SELECT setval('bs',1,false)",1);
    try truth("SELECT ROW(nextval('bs'),0) BETWEEN NULL AND ROW(1,0)",null);
    try scalar("SELECT currval('bs')",1);
    try db.execute("CREATE TABLE bt(id INT PRIMARY KEY,a INT,b INT)",&r);
    try db.execute("INSERT INTO bt VALUES(1,1,2),(2,NULL,2),(3,2,1),(4,NULL,NULL)",&r);
    try booleans("SELECT (a,b) BETWEEN (1,2) AND (2,1) FROM bt ORDER BY id",&.{true,null,true,null});
    try scalar("SELECT COUNT(*) FROM bt WHERE (a,b) BETWEEN SYMMETRIC (2,1) AND (1,2)",2);
    try scalar("SELECT COUNT(*) FROM bt x JOIN bt y ON (x.a,y.b) BETWEEN (1,2) AND (1,2)",2);
    try scalar("SELECT COUNT(*) FROM bt x WHERE EXISTS(SELECT 1 FROM bt y WHERE (x.id,x.a) BETWEEN (y.id,y.a) AND (y.id,y.a))",2);
    try truth("SELECT ROW((SELECT a FROM bt WHERE id=1),2) BETWEEN (1,2) AND (2,1)",true);
    try truth("SELECT ROW(MAX(id),COUNT(*)) BETWEEN (4,4) AND (4,4) FROM bt",true);
    try booleans("SELECT ROW(a,COUNT(*)) BETWEEN (1,1) AND (2,1) AS flag FROM bt GROUP BY a ORDER BY flag",&.{true,true,null});
    try booleans("SELECT (a,b) BETWEEN (1,2) AND (2,1) FROM bt GROUP BY (a,b) BETWEEN (1,2) AND (2,1) ORDER BY 1",&.{true,null});
    try truth("SELECT ROW(id,10/(id-id)) BETWEEN (0,0) AND (0,9) FROM bt WHERE id=1",false);
    try rejects("SELECT ROW(id,10/(id-id)) BETWEEN (id,0) AND (id,9) FROM bt WHERE id=1",error.DivisionByZero);
    try mutate("UPDATE bt SET b=9 WHERE (a,b) BETWEEN (1,2) AND (2,1)",2);
    try scalar("SELECT SUM(b) FROM bt",20);
    try rejects("UPDATE bt SET b=b+1 WHERE (id,10/(b-2)) BETWEEN (id,0) AND (id,9)",error.DivisionByZero);
    try scalar("SELECT SUM(b) FROM bt",20);
    try mutate("DELETE FROM bt WHERE (id,b) BETWEEN (3,9) AND (3,9)",1);
    try rejects("SELECT ROW(1) BETWEEN ROW(1,2) AND ROW(1)",error.Syntax);
    try rejects("SELECT ROW(1) BETWEEN 1 AND 2",error.UndefinedFunction);
    try rejects("SELECT ROW('{}'::json,2) BETWEEN ROW('{}'::json,2) AND ROW('{}'::json,2)",error.UndefinedFunction);
    try rejects("SELECT ROW(1,'x') BETWEEN ROW(1,1) AND ROW(2,2)",error.InvalidTextRepresentation);
    try rejects("SELECT ROW() BETWEEN ROW() AND ROW()",error.UnsupportedStatement);
    try rejects("SELECT '{}'::json BETWEEN NULL AND NULL",error.UndefinedFunction);
    try rejects("SELECT (a,b) BETWEEN NULL AND NULL FROM bt GROUP BY b",error.GroupingError);
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,a INT,b INT,member BOOLEAN GENERATED ALWAYS AS((a,b) BETWEEN SYMMETRIC (2,1) AND (1,2)) STORED,absent BOOLEAN DEFAULT(ROW(1,2) NOT BETWEEN (2,1) AND (3,0)),in_range BOOLEAN DEFAULT(2 BETWEEN 1 AND 3))",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id,a,b) VALUES(1,1,2),(2,NULL,2)",&r);
    try replayed.execute("SELECT member,absent,in_range FROM g ORDER BY id",&r);
    try check(r.row_count==2 and r.rows[0].cells[0].boolean and r.rows[1].cells[0]==.null_value and r.rows[0].cells[1].boolean and r.rows[1].cells[1].boolean and r.rows[0].cells[2].boolean and r.rows[1].cells[2].boolean);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("SELECT (a,b) BETWEEN (1,2) AND (2,1) FROM bt",error.QueryWorkLimit);
    var interrupt:sql.ExecutionControl=.{.poll=canceled,.poll_interval=1};db.session.control=&interrupt;
    try rejects("SELECT (a,b) NOT BETWEEN SYMMETRIC (1,2) AND (2,1) FROM bt",error.QueryCanceled);db.session.control=null;
    const Tiny=sql.Database(.{.tables=1,.columns=2,.rows_per_table=2,.expr_nodes=20,.text_bytes=16});var tiny:Tiny=.{};var output:Tiny.Result=.{};
    try tiny.execute("SELECT 17",&output);
    if(tiny.execute("SELECT (1,2) BETWEEN SYMMETRIC (1,2) AND (2,1)",&output)) |_| return error.AstBudgetIgnored else |err|try check(err==error.StatementTooComplex);
    try check(output.row_count==1 and output.rows[0].cells[0].integer==17);
    var buffer:[192]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-between\",\"pass\":true,\"assertions\":{d},\"matrix_queries\":8910,\"matrix_fnv64\":\"{x}\"}}\n",.{assertions,digest});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
