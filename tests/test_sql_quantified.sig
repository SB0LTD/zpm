//! PG.PRED.QUANTIFIED: ANY/SOME/ALL scalar-subquery truth tables.
const std=@import("std"); const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=8,.rows_per_table=16,.text_bytes=128,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;
var matrix_hash:u64=14695981039346656037;
fn check(ok:bool) !void {assertions+=1;if(!ok){std.debug.print("quantified assertion {d}\n",.{assertions});return error.QuantifiedContractFailed;}}
fn truth(source:[]const u8,wanted:?bool) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1);
    try check(r.column_types[0]==.boolean);
    const cell=r.rows[0].cells[0];
    if(wanted) |b| try check(cell==.boolean and cell.boolean==b) else try check(cell==.null_value);
}
fn scalar(source:[]const u8,wanted:i64) !void {
    try db.execute(source,&r);try check(r.row_count==1 and r.rows[0].cells[0]==.integer and r.rows[0].cells[0].integer==wanted);
}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_| return error.InvalidQuantifiedAccepted else |err| {if(err!=wanted)std.debug.print("{s}: {s}\n",.{source,@errorName(err)});try check(err==wanted);}
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
    for(0..r.row_count) |row| for(0..r.column_count) |column| {
        try check(std.meta.eql(r.rows[row].cells[column],before.rows[row].cells[column]));
    };
}
fn compare(op:usize,a:i64,b:i64) bool {
    return switch(op){0=>a==b,1=>a!=b,2=>a<b,3=>a<=b,4=>a>b,5=>a>=b,else=>unreachable};
}
fn hashByte(byte:u8) void {matrix_hash=(matrix_hash^byte)*%1099511628211;}
fn matrix() !void {
    const values=[_]?i64{null,-1,0,1};const words=[_][]const u8{"NULL","-1","0","1"};
    const ops=[_][]const u8{"=","<>","<","<=",">",">="};const quantifiers=[_][]const u8{"ANY","SOME","ALL"};
    var buffer:[512]u8=undefined;
    for(values,0..) |left,li| for(0..16) |mask| for(ops,0..) |op,oi| for(quantifiers,0..) |quantifier,qi| {
        const all=qi==2;var unknown=false;var decisive=false;
        for(values,0..) |right,ri| {
            if(mask&(@as(usize,1)<<@intCast(ri))==0)continue;
            if(left==null or right==null){unknown=true;continue;}
            if(compare(oi,left.?,right.?)!=all){decisive=true;break;}
        }
        const wanted:?bool=if(decisive) !all else if(unknown) null else all;
        const source=try std.fmt.bufPrint(&buffer,"SELECT {s} {s} {s}(SELECT v FROM t WHERE (id=0 AND {s}) OR (id=1 AND {s}) OR (id=2 AND {s}) OR (id=3 AND {s}))",
            .{words[li],op,quantifier,if(mask&1!=0) "true" else "false",if(mask&2!=0) "true" else "false",if(mask&4!=0) "true" else "false",if(mask&8!=0) "true" else "false"});
        for(source) |byte| hashByte(byte);
        hashByte(if(wanted) |b| @intFromBool(b) else 2);
        try truth(source,wanted);
    };
}
fn canceled(_: ?*anyopaque) sql.Error!void {return error.QueryCanceled;}
fn capacity() !void {
    const Narrow=sql.Database(.{.tables=1,.columns=2,.rows_per_table=16,.work_rows=1,.text_bytes=16});
    var narrow:Narrow=.{};var output:Narrow.Result=.{};
    try narrow.execute("CREATE TABLE t(v INT)",&output);
    try narrow.execute("INSERT INTO t VALUES(1),(2),(3),(4),(5),(6),(7),(8)",&output);
    try narrow.execute("SELECT 17",&output);
    if(narrow.execute("SELECT 1=ANY(SELECT v FROM t)",&output)) |_| return error.CapacityIgnored else |err| try check(err==error.WorkspaceCapacity);
    try check(output.row_count==1 and output.rows[0].cells[0].integer==17);
    try narrow.execute("SELECT 1=ALL(SELECT 1)",&output);
    try check(output.rows[0].cells[0].boolean);
}
pub fn main(init:std.process.Init) !void {
    try db.execute("CREATE TABLE t(id INT PRIMARY KEY,v INT)",&r);
    try db.execute("INSERT INTO t VALUES(0,NULL),(1,-1),(2,0),(3,1)",&r);
    try matrix();
    try truth("SELECT 1 != SOME(SELECT v FROM t)",true);
    try truth("SELECT NOT (1=ANY(SELECT v FROM t WHERE id=0))",null);
    try truth("SELECT 1=ANY((SELECT v FROM t WHERE id=3))",true);
    try truth("SELECT 1=ANY(WITH q AS(SELECT v FROM t) SELECT v FROM q)",true);
    try truth("SELECT 1=ANY(SELECT v FROM t) = TRUE",true);
    try truth("SELECT 1=ANY(SELECT 1)=ANY(SELECT TRUE)",true);
    try truth("SELECT 1=ANY(SELECT 1)::text='true'",true);
    try truth("SELECT 1=ANY(SELECT 1) || 'x' = 'truex'",true);
    try truth("SELECT 0.5>ALL(SELECT v FROM t WHERE id=1)",true);
    try truth("SELECT 0.5<ANY(SELECT v::double precision FROM t WHERE id=3)",true);
    // Operator overload resolution must not round an exact operand to REAL.
    try truth("SELECT 16777217=ANY(SELECT 16777216::real)",false);
    try truth("SELECT 16777217>ALL(SELECT 16777216::real)",true);
    try truth("SELECT 16777216::real<ANY(SELECT 16777217)",true);
    try truth("SELECT 0.1::numeric=ALL(SELECT 0.1::real)",false);
    try truth("SELECT 0.1::numeric<ANY(SELECT 0.1::real)",true);
    try truth("SELECT 16777217=16777216::real",false);
    try truth("SELECT 16777217 IS DISTINCT FROM 16777216::real",true);
    try truth("SELECT '1'=ANY(SELECT v FROM t WHERE id=3)",true);
    try truth("SELECT DATE '2025-01-01'<ALL(SELECT TIMESTAMP '2025-01-02 12:00:00')",true);
    try truth("SELECT '{\"a\":1}'::jsonb=ANY(SELECT '{\"a\":1}'::jsonb)",true);
    try truth("SELECT 'NaN'::double precision=ALL(SELECT 'NaN'::double precision)",true);
    try truth("SELECT COUNT(*)>ALL(SELECT v FROM t WHERE v IS NOT NULL) FROM t",true);
    try scalar("SELECT COUNT(*) FROM t o WHERE o.id>ANY(SELECT b.v FROM t b WHERE b.id<o.id)",2);
    try scalar("SELECT COUNT(*) FROM t o WHERE o.id>ALL(SELECT b.v FROM t b WHERE b.id<o.id)",1);
    try scalar("SELECT COUNT(*) FROM t a JOIN t b ON a.id=b.id AND a.v=ANY(SELECT v FROM t WHERE id=1)",1);
    try truth("SELECT 1=ANY(SELECT v FROM t WHERE id=3 UNION ALL SELECT v FROM t WHERE id=3)",true);
    try truth("SELECT 1<>ALL(SELECT v FROM t WHERE id=3 UNION ALL SELECT v FROM t WHERE id=3)",false);
    try db.execute("CREATE SEQUENCE s",&r);
    try truth("SELECT nextval('s')=ANY(SELECT v FROM t)",true);
    try scalar("SELECT currval('s')",1);
    try scalar("SELECT COUNT(*) FROM t WHERE nextval('s')>ALL(SELECT v FROM t WHERE id=3)",4);
    try scalar("SELECT currval('s')",5);
    try rejects("SELECT 1=ANY(SELECT id,v FROM t)",error.Syntax);
    try rejects("SELECT 1=ALL(SELECT TRUE)",error.UndefinedFunction);
    try rejects("SELECT '{}'::json=ANY(SELECT '{}'::json)",error.UndefinedFunction);
    try rejects("SELECT '{}'::json IN(SELECT '{}'::json)",error.UndefinedFunction);
    try rejects("SELECT 1=ANY(SELECT 1/0)",error.DivisionByZero);
    try rejects("SELECT 1=1=ANY(SELECT TRUE)",error.Syntax);
    try rejects("SELECT 1=ANY(SELECT 1)=TRUE=FALSE",error.Syntax);
    try rejects("SELECT 1=ANY(SELECT 1)+1",error.UndefinedFunction);
    try rejects("CREATE TABLE any(id INT)",error.Syntax);
    // Per-statement sublink caches must not hide committed or own updates.
    const tx=try db.begin();
    try db.statement(tx,"SELECT 1=ANY(SELECT v FROM t WHERE id=3)",&r,.{});
    try check(r.rows[0].cells[0].boolean);
    try db.execute("UPDATE t SET v=9 WHERE id=3",&r);
    try db.statement(tx,"SELECT 1=ANY(SELECT v FROM t WHERE id=3)",&r,.{});
    try check(!r.rows[0].cells[0].boolean);
    try db.statement(tx,"UPDATE t SET v=1 WHERE id=3",&r,.{});
    try db.statement(tx,"SELECT 1=ALL(SELECT v FROM t WHERE id=3)",&r,.{});
    try check(r.rows[0].cells[0].boolean);
    db.abort(tx);
    try truth("SELECT 1=ANY(SELECT v FROM t WHERE id=3)",false);
    // New reserved words must not change the frozen alpha replay language.
    try db.executeLegacy("CREATE TABLE any(id INTEGER)",&r);
    try db.executeLegacy("INSERT INTO any VALUES(7)",&r);
    try db.executeLegacy("SELECT id FROM any",&r);try check(r.rows[0].cells[0].integer==7);
    try db.executeLegacy("CREATE TABLE some(id INTEGER)",&r);
    try db.executeLegacy("INSERT INTO some VALUES(8)",&r);
    try db.executeLegacy("SELECT id FROM some",&r);try check(r.rows[0].cells[0].integer==8);
    try scalar("SELECT 17",17);
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("SELECT 1=ANY(SELECT v FROM t)",error.QueryWorkLimit);
    var interrupt:sql.ExecutionControl=.{.poll=canceled,.poll_interval=1};db.session.control=&interrupt;
    try rejects("SELECT 1=ALL(SELECT v FROM t)",error.QueryCanceled);
    db.session.control=null;
    try capacity();
    var buffer:[192]u8=undefined;
    const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-quantified\",\"pass\":true,\"assertions\":{d},\"matrix_queries\":1152,\"matrix_fnv64\":\"{x}\"}}\n",.{assertions,matrix_hash});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
