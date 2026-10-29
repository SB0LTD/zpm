//! Flat constructor IN lists: exact three-valued semantics and replay.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=4,.columns=8,.rows_per_table=16,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var digest:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.RowMembershipContractFailed;}
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
fn equal(left:[2]?i64,right:[2]?i64) ?bool {
    var unknown=false;for(left,right)|a,b|{if(a==null or b==null)unknown=true else if(a.?!=b.?)return false;}return if(unknown)null else true;
}
fn membership(left:[2]?i64,first:[2]?i64,second:[2]?i64,negated:bool) ?bool {
    const a=equal(left,first);const b=equal(left,second);const result:?bool=if(a==true or b==true)true else if(a==null or b==null)null else false;
    return if(result)|v|v!=negated else null;
}
fn hashByte(byte:u8) void {digest=(digest^byte)*%1099511628211;}
fn matrix() !void {
    const values=[_]?i64{null,-1,1};const words=[_][]const u8{"NULL","-1","1"};var buffer:[256]u8=undefined;
    for([_][]const u8{"ROW",""})|prefix|for([_]bool{false,true})|negated| {
        for(values,0..)|a,ai|for(values,0..)|b,bi|for(values,0..)|c,ci|for(values,0..)|d,di|for(values,0..)|e,ei|for(values,0..)|f,fi| {
            const source=try std.fmt.bufPrint(&buffer,"SELECT {s}({s},{s}) {s}IN ({s}({s},{s}),{s}({s},{s}))",.{prefix,words[ai],words[bi],if(negated)"NOT " else "",prefix,words[ci],words[di],prefix,words[ei],words[fi]});
            const wanted=membership(.{a,b},.{c,d},.{e,f},negated);for(source)|byte|hashByte(byte);hashByte(if(wanted)|v|@intFromBool(v) else 2);try truth(source,wanted);
        };
    };
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn longList() !void {
    // More candidates than the expression-depth budget, with enough caller
    // storage for the explicitly expanded equality fields.
    const Wide=sql.Database(.{.tables=1,.columns=2,.rows_per_table=2,.expr_nodes=1024,.expr_depth=5,.text_bytes=16});
    var wide:Wide=.{};var output:Wide.Result=.{};var source:[1024]u8=undefined;
    const prefix="SELECT (1,2) IN (";@memcpy(source[0..prefix.len],prefix);var used=prefix.len;
    for(0..64)|index| {const part=if(index==63)"(1,2))" else "(0,0),";@memcpy(source[used..][0..part.len],part);used+=part.len;}
    try wide.execute(source[0..used],&output);try check(output.row_count==1 and output.rows[0].cells[0].boolean);
}
pub fn main(init:std.process.Init) !void {
    try matrix();
    try truth("SELECT ROW(1) IN (ROW(1))",true);
    try truth("SELECT ROW(1,2) NOT IN ((1,3),(2,2),(1,3))",true);
    try truth("SELECT ROW('1',2) IN (ROW(1,2),ROW('x'::text,2))",true);
    try truth("SELECT ROW(16777217,0) IN (ROW(16777216::real,0),ROW(16777217::bigint,0))",true);
    try truth("SELECT ROW('NaN'::double precision,1) IN (ROW('NaN'::double precision,1))",true);
    try truth("SELECT ROW(DATE '2025-01-01',2) IN (ROW(TIMESTAMP '2025-01-01 00:00:00',2))",true);
    try truth("SELECT ROW('{\"a\":1}'::jsonb,2) IN (ROW('{\"a\":1}'::jsonb,2))",true);
    try truth("SELECT ROW(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16) IN (ROW(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,17),ROW(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16))",true);
    try db.execute("CREATE SEQUENCE mi",&r);
    try truth("SELECT ROW(nextval('mi'),0) IN (ROW(0,0),ROW(2,0))",true);
    try scalar("SELECT currval('mi')",2);
    try truth("SELECT ROW(nextval('mi'),0) NOT IN (ROW(3,0),ROW(nextval('mi'),0))",false);
    try scalar("SELECT currval('mi')",3);
    try truth("SELECT ROW(nextval('mi'),0) IN (ROW(NULL,0),ROW(5,0))",null);
    try scalar("SELECT currval('mi')",4);
    try truth("SELECT ROW(9,nextval('mi')) IN (ROW(8,nextval('mi')),ROW(9,5))",true);
    try scalar("SELECT currval('mi')",5);
    try db.execute("CREATE TABLE mt(id INT PRIMARY KEY,a INT,b INT)",&r);
    try db.execute("INSERT INTO mt VALUES(1,1,2),(2,NULL,2),(3,2,1),(4,NULL,NULL)",&r);
    try truth("SELECT ROW(nextval('mi'),0) IN (ROW(a,0),ROW(7,0)) FROM mt WHERE id=2",true);
    try scalar("SELECT currval('mi')",7);
    try booleans("SELECT (a,b) IN ((1,2),(2,1)) FROM mt ORDER BY id",&.{true,null,true,null});
    try scalar("SELECT COUNT(*) FROM mt WHERE (a,b) IN ((1,2),(2,1))",2);
    try scalar("SELECT COUNT(*) FROM mt x JOIN mt y ON (x.a,y.b) IN ((1,2),(2,1))",3);
    try scalar("SELECT COUNT(*) FROM mt x WHERE EXISTS(SELECT 1 FROM mt y WHERE (x.id,x.a) IN ((y.id,y.a)))",2);
    try truth("SELECT (MAX(id),COUNT(*)) IN ((4,4),(9,9)) FROM mt",true);
    try booleans("SELECT (a,COUNT(*)) IN ((1,1),(2,1)) AS flag FROM mt GROUP BY a ORDER BY flag",&.{false,true,true});
    try booleans("SELECT (a,b) IN ((1,2),(2,1)) FROM mt GROUP BY (a,b) IN ((1,2),(2,1)) ORDER BY 1",&.{true,null});
    try truth("SELECT ROW((SELECT a FROM mt WHERE id=1),2) IN ((1,2),(2,1))",true);
    try truth("SELECT (id,10/(id-id)) IN ((9,0),(8,0)) FROM mt WHERE id=1",false);
    try scalar("SELECT 17",17);
    try rejects("SELECT (id,10/(id-id)) IN ((id,0),(8,0)) FROM mt WHERE id=1",error.DivisionByZero);
    try mutate("UPDATE mt SET b=9 WHERE (a,b) IN ((1,2),(2,1))",2);
    try scalar("SELECT SUM(b) FROM mt",20);
    try rejects("UPDATE mt SET b=b+1 WHERE (id,10/(b-2)) IN ((id,0))",error.DivisionByZero);
    try scalar("SELECT SUM(b) FROM mt",20);
    try mutate("DELETE FROM mt WHERE (id,b) IN ((3,9),(9,9))",1);
    try scalar("SELECT COUNT(*) FROM mt",3);
    try rejects("SELECT ROW(1) IN (ROW(1,2))",error.Syntax);
    try rejects("SELECT ROW(1) IN (1)",error.UndefinedFunction);
    try rejects("SELECT ROW(1,'{}'::json) IN (ROW(2,'{}'::json))",error.UndefinedFunction);
    try rejects("SELECT ROW(1,'x') IN (ROW(2,1))",error.InvalidTextRepresentation);
    try rejects("SELECT ROW() IN (ROW())",error.UnsupportedStatement);
    // Unqualified record payloads are rejected rather than misrepresented.
    try rejects("SELECT ROW(1,2) IN (NULL)",error.UnsupportedStatement);
    try rejects("SELECT ROW(ROW(1,2),3) IN (ROW(ROW(1,2),3))",error.UnsupportedStatement);
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,a INT,b INT,member BOOLEAN GENERATED ALWAYS AS((a,b) IN ((1,2),(2,1))) STORED,absent BOOLEAN DEFAULT(ROW(1,2) NOT IN (ROW(2,1))))",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id,a,b) VALUES(1,1,2),(2,NULL,2)",&r);
    try replayed.execute("SELECT member,absent FROM g ORDER BY id",&r);
    try check(r.row_count==2 and r.rows[0].cells[0].boolean and r.rows[1].cells[0]==.null_value and r.rows[0].cells[1].boolean and r.rows[1].cells[1].boolean);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("SELECT (a,b) IN ((1,2),(2,1)) FROM mt",error.QueryWorkLimit);
    var interrupt:sql.ExecutionControl=.{.poll=canceled,.poll_interval=1};db.session.control=&interrupt;
    try rejects("SELECT (a,b) NOT IN ((1,2),(2,1)) FROM mt",error.QueryCanceled);db.session.control=null;
    const Tiny=sql.Database(.{.tables=1,.columns=2,.rows_per_table=2,.expr_nodes=16,.text_bytes=16});var tiny:Tiny=.{};var output:Tiny.Result=.{};
    try tiny.execute("SELECT 17",&output);
    if(tiny.execute("SELECT (1,2) IN ((1,2),(2,1))",&output)) |_| return error.AstBudgetIgnored else |err|try check(err==error.StatementTooComplex);
    try check(output.row_count==1 and output.rows[0].cells[0].integer==17);
    try longList();
    var buffer:[192]u8=undefined;const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-row-membership\",\"pass\":true,\"assertions\":{d},\"matrix_queries\":2916,\"matrix_fnv64\":\"{x}\"}}\n",.{assertions,digest});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
