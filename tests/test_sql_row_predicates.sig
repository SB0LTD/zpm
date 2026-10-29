//! Flat row-constructor predicates: comparison, NULL tests, visits and replay.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=4,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;
var matrix_hash:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("row assertion {d}\n",.{assertions});return error.RowPredicateContractFailed;}}
fn truth(source:[]const u8,wanted:?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1 and r.column_types[0]==.boolean);
    const cell=r.rows[0].cells[0];
    if(wanted)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);
}
fn scalar(source:[]const u8,wanted:i64) !void {
    try db.execute(source,&r);try check(r.row_count==1 and r.rows[0].cells[0]==.integer and r.rows[0].cells[0].integer==wanted);
}
fn booleans(source:[]const u8,wanted:[]const ?bool) !void {
    try db.execute(source,&r);try check(r.column_count==1 and r.row_count==wanted.len and r.column_types[0]==.boolean);
    for(wanted,0..) |value,index| {const cell=r.rows[index].cells[0];if(value)|b|try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);}
}
fn mutate(source:[]const u8,wanted:usize) !void {try db.execute(source,&r);try check(r.affected_rows==wanted);}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_| return error.InvalidRowAccepted else |err| {if(err!=wanted)std.debug.print("{s}: {s}\n",.{source,@errorName(err)});try check(err==wanted);}
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
    for(0..r.row_count)|row|for(0..r.column_count)|column|try check(std.meta.eql(r.rows[row].cells[column],before.rows[row].cells[column]));
}
fn unsupported(source:[]const u8) !void {try rejects(source,error.UnsupportedStatement);}
fn hashByte(byte:u8) void {matrix_hash=(matrix_hash^byte)*%1099511628211;}
fn record(source:[]const u8,wanted:?bool) !void {for(source)|byte|hashByte(byte);hashByte(if(wanted)|b|@intFromBool(b) else 2);try truth(source,wanted);}
fn expected(op:usize,left:[2]?i64,right:[2]?i64) ?bool {
    if(op==6 or op==7){var different=false;for(left,right)|a,b|{if(a==null or b==null){if((a==null)!=(b==null))different=true;}else if(a.?!=b.?)different=true;}return if(op==6)different else !different;}
    if(op==0 or op==1){var unknown=false;for(left,right)|a,b|{if(a==null or b==null)unknown=true else if(a.?!=b.?)return op==1;}return if(unknown)null else op==0;}
    for(left,right)|a,b|{if(a==null or b==null)return null;if(a.?!=b.?)return if(op==2 or op==3)a.?<b.? else a.?>b.?;}
    return op==3 or op==5;
}
fn matrix() !void {
    const values=[_]?i64{null,-1,0,1};const words=[_][]const u8{"NULL","-1","0","1"};
    const ops=[_][]const u8{"=","<>","<","<=",">",">=","IS DISTINCT FROM","IS NOT DISTINCT FROM"};
    var buffer:[256]u8=undefined;
    for([_][]const u8{"ROW",""})|prefix| {
        for(values,0..)|a,ai|for(values,0..)|b,bi|for(values,0..)|c,ci|for(values,0..)|d,di|for(ops,0..)|op,oi| {
            const source=try std.fmt.bufPrint(&buffer,"SELECT {s}({s},{s}) {s} {s}({s},{s})",.{prefix,words[ai],words[bi],op,prefix,words[ci],words[di]});
            try record(source,expected(oi,.{a,b},.{c,d}));
        };
        for(values,0..)|a,ai|for(values,0..)|b,bi|for([_][]const u8{"IS NULL","IS NOT NULL"},0..)|predicate,ti| {
            const wanted=if(ti==0)a==null and b==null else a!=null and b!=null;
            try record(try std.fmt.bufPrint(&buffer,"SELECT {s}({s},{s}) {s}",.{prefix,words[ai],words[bi],predicate}),wanted);
        };
    }
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn astBudget() !void {
    const Tiny=sql.Database(.{.tables=1,.columns=2,.rows_per_table=2,.expr_nodes=8,.text_bytes=16});
    var tiny:Tiny=.{};var output:Tiny.Result=.{};
    try tiny.execute("SELECT 17",&output);
    if(tiny.execute("SELECT ROW(1,2)=ROW(1,2)",&output)) |_| return error.AstBudgetIgnored else |err|try check(err==error.StatementTooComplex);
    try check(output.row_count==1 and output.rows[0].cells[0].integer==17);
    try tiny.execute("SELECT ROW(1)=ROW(1)",&output);
    try check(output.rows[0].cells[0].boolean);
}
pub fn main(init:std.process.Init) !void {
    try matrix();
    try truth("SELECT ROW(1,2)=(1,2)",true);
    try truth("SELECT (1,2)=ROW(1,2)",true);
    try truth("SELECT ROW(1)=ROW(1)",true);
    try truth("SELECT ROW() IS DISTINCT FROM ROW()",false);
    try truth("SELECT ROW() IS NOT DISTINCT FROM ROW()",true);
    try truth("SELECT ROW() IS NULL",true);
    try truth("SELECT ROW() IS NOT NULL",true);
    try truth("SELECT ROW(1+2,4)=ROW(3,4)",true);
    try truth("SELECT ROW(16777217,0)>ROW(16777216::real,9)",true);
    try truth("SELECT ROW('1',NULL)=ROW(1,NULL)",null);
    try truth("SELECT ROW('NaN'::double precision,1)=ROW('NaN'::double precision,1)",true);
    try truth("SELECT ROW(DATE '2025-01-01',2)<ROW(TIMESTAMP '2025-01-02 12:00:00',0)",true);
    try truth("SELECT ROW('{\"a\":1}'::jsonb,2)<ROW('{\"a\":2}'::jsonb,0)",true);
    try truth("SELECT ROW((SELECT 1),2)=ROW(1,2)",true);
    try truth("SELECT ROW(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)<ROW(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,17)",true);
    try db.execute("CREATE TABLE rt(id INT PRIMARY KEY,a INT,b INT)",&r);
    try db.execute("INSERT INTO rt VALUES(1,1,2),(2,NULL,2),(3,NULL,NULL),(4,2,1)",&r);
    try db.execute("CREATE SEQUENCE rs",&r);
    try scalar("SELECT setval('rs',100,true)",100);
    try truth("SELECT ROW(a,nextval('rs')) IS NULL FROM rt WHERE id=1",false);
    try scalar("SELECT currval('rs')",100);
    try truth("SELECT ROW(a,nextval('rs')) IS NOT NULL FROM rt WHERE id=2",false);
    try scalar("SELECT currval('rs')",100);
    try truth("SELECT ROW(a,nextval('rs'))<ROW(b,nextval('rs')) FROM rt WHERE id=1",true);
    try scalar("SELECT currval('rs')",100);
    try truth("SELECT ROW(a,nextval('rs'))=ROW(b,nextval('rs')) FROM rt WHERE id=3",false);
    try scalar("SELECT currval('rs')",102);
    try truth("SELECT ROW(a,nextval('rs')) IS NULL FROM rt WHERE id=3",false);
    try scalar("SELECT currval('rs')",103);
    try truth("SELECT ROW(a,nextval('rs')) IS NOT NULL FROM rt WHERE id=1",true);
    try scalar("SELECT currval('rs')",104);
    try scalar("SELECT COUNT(*) FROM rt x JOIN rt y ON ROW(x.id,x.a)=ROW(y.id,y.a)",2);
    try scalar("SELECT COUNT(*) FROM rt o WHERE EXISTS(SELECT 1 FROM rt x WHERE ROW(o.id,o.a)=ROW(x.id,x.a))",2);
    try mutate("UPDATE rt SET b=9 WHERE ROW(a,b)>ROW(1,1)",2);
    try scalar("SELECT SUM(b) FROM rt",20);
    try scalar("SELECT 17",17);
    try rejects("UPDATE rt SET b=b+1 WHERE ROW(id,10/(b-2))>=ROW(id,0)",error.DivisionByZero);
    try scalar("SELECT SUM(b) FROM rt",20);
    try mutate("DELETE FROM rt WHERE ROW(id,b)=ROW(4,9)",1);
    try truth("SELECT ROW(COUNT(*),SUM(b))=ROW(3,11) FROM rt",true);
    try booleans("SELECT ROW(a,COUNT(*))>ROW(0,0) AS flag FROM rt GROUP BY a ORDER BY flag",&.{true,null});
    try booleans("SELECT ROW(a,b) IS NULL FROM rt GROUP BY ROW(a,b) IS NULL ORDER BY 1",&.{false,true});
    try booleans("SELECT ROW(a,b)>ROW(0,0) FROM rt GROUP BY ROW(a,b)>ROW(0,0) ORDER BY 1",&.{true,null});
    try scalar("SELECT COUNT(*) FROM rt r WHERE ROW(r.id,(SELECT b FROM rt x WHERE x.id=r.id)) IS NOT NULL",2);
    try scalar("SELECT 17",17);
    try rejects("SELECT ROW(1)=ROW(1,2)",error.Syntax);
    try rejects("SELECT ROW(1)=1",error.UndefinedFunction);
    try rejects("SELECT ROW(1,'{}'::json)<ROW(2,'{}'::json)",error.UndefinedFunction);
    try rejects("SELECT ROW(1,'x')=ROW(2,1)",error.InvalidTextRepresentation);
    try rejects("SELECT ROW()=ROW()",error.UnsupportedStatement);
    try rejects("SELECT ROW(1) IS TRUE",error.TypeMismatch);
    try rejects("SELECT \"row\"(1,2)=\"row\"(1,2)",error.UndefinedFunction);
    // Record payloads and nested records remain explicit unsupported scopes.
    try unsupported("SELECT ROW(1,2)");
    try unsupported("SELECT ROW(ROW(1,2),3)=ROW(ROW(1,2),3)");
    // Source-based schema metadata must round-trip without a record value type.
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,a INT,b INT,same BOOLEAN GENERATED ALWAYS AS(ROW(a,b) IS NOT DISTINCT FROM ROW(1,2)) STORED,all_null BOOLEAN DEFAULT(ROW(NULL,NULL) IS NULL))",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id,a,b) VALUES(1,1,2),(2,NULL,2)",&r);
    try replayed.execute("SELECT same,all_null FROM g ORDER BY id",&r);
    try check(r.row_count==2 and r.rows[0].cells[0].boolean and !r.rows[1].cells[0].boolean and r.rows[0].cells[1].boolean and r.rows[1].cells[1].boolean);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("SELECT ROW(a,b)=ROW(1,2) FROM rt",error.QueryWorkLimit);
    var interrupt:sql.ExecutionControl=.{.poll=canceled,.poll_interval=1};db.session.control=&interrupt;
    try rejects("SELECT ROW(a,b)<ROW(1,2) FROM rt",error.QueryCanceled);
    db.session.control=null;
    try astBudget();
    var buffer:[192]u8=undefined;
    const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-row-predicates\",\"pass\":true,\"assertions\":{d},\"matrix_queries\":4160,\"matrix_fnv64\":\"{x}\"}}\n",.{assertions,matrix_hash});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
