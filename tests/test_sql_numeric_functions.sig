//! PostgreSQL numeric functions: overloads, exact decimals and strict evaluation.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=6,.rows_per_table=16,.text_bytes=256});
var db:DB=.{};var r:DB.Result=.{};var assertions:usize=0;var matrix_queries:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.NumericFunctionContractFailed;}
fn row(source:[]const u8,oid:u32,wanted:?[]const u8) !void {
    db.execute(source,&r) catch |err| {std.debug.print("{s}: {s}\n",.{source,@errorName(err)});return err;};
    try check(r.row_count==1 and r.column_count==1);
    try check(sql.typeOid(r.column_types[0])==oid);
    try check(r.column_typmods[0]==-1);
    const cell=&r.rows[0].cells[0];
    if(wanted)|text| {
        var buffer:[DB.Io.format_bytes]u8=undefined;
        const actual=try DB.Io.format(cell,false,&db.session,&buffer);
        if(!std.mem.eql(u8,text,actual))std.debug.print("{s}: {s}, expected {s}\n",.{source,actual,text});
        try check(std.mem.eql(u8,text,actual));
    } else try check(cell.*==.null_value);
}
fn rejects(source:[]const u8,wanted:anyerror) !void {
    const before=r;
    if(db.execute(source,&r)) |_|return error.InvalidNumericCallAccepted else |err| {if(err!=wanted)std.debug.print("{s}: {s}\n",.{source,@errorName(err)});try check(err==wanted);}
    try check(r.row_count==before.row_count and r.column_count==before.column_count);
    for(0..r.row_count)|i|for(0..r.column_count)|j|try check(std.meta.eql(r.rows[i].cells[j],before.rows[i].cells[j]));
}
fn decimal(buffer:[]u8,coefficient:i64,scale:usize) ![]const u8 {
    const magnitude:u64=@intCast(if(coefficient<0)-coefficient else coefficient);
    var unit:u64=1;for(0..scale)|_|unit*=10;
    if(scale==0)return std.fmt.bufPrint(buffer,"{d}",.{coefficient});
    const head=try std.fmt.bufPrint(buffer,"{s}{d}.",.{if(coefficient<0) "-" else "",magnitude/unit});
    var rest=magnitude%unit;var place=unit/10;
    for(0..scale)|i|{buffer[head.len+i]=@as(u8,@intCast(rest/place))+'0';rest%=place;place/=10;}
    return buffer[0..head.len+scale];
}
fn matrix() !void {
    const values=[_]i64{-12345,-10001,-9999,-101,-100,-99,-10,-1,0,1,10,99,100,101,9999,10001,12345};
    for(values)|n| {
        var input:[40]u8=undefined;const text=try decimal(&input,n,2);
        for([_] []const u8{"abs","ceil","floor","sign","trunc"},0..)|name,kind| {
            const coefficient=switch(kind){0=>if(n<0)-n else n,1=>-@divFloor(-n,100),2=>@divFloor(n,100),3=>@as(i64,if(n<0)-1 else if(n>0)1 else 0),else=>@divTrunc(n,100)};
            var expected:[40]u8=undefined;const wanted=try decimal(&expected,coefficient,if(kind==0)2 else 0);
            var query:[128]u8=undefined;try row(try std.fmt.bufPrint(&query,"SELECT {s}({s}::numeric)",.{name,text}),1700,wanted);matrix_queries+=1;
        }
        for([_]i32{-3,-2,-1,0,1,2,3})|scale| {
            var coefficient=n;
            if(scale>=2){var k:i32=2;while(k<scale):(k+=1)coefficient*=10;} else {
                var unit:i64=1;var k=scale;while(k<2):(k+=1)unit*=10;
                coefficient=@divTrunc(n,unit);k=scale;while(k<0):(k+=1)coefficient*=10;
            }
            var expected:[40]u8=undefined;const wanted=try decimal(&expected,coefficient,@intCast(@max(scale,0)));
            var query:[128]u8=undefined;try row(try std.fmt.bufPrint(&query,"SELECT trunc({s}::numeric,{d})",.{text,scale}),1700,wanted);matrix_queries+=1;
        }
    }
}
pub fn main(init:std.process.Init) !void {
    errdefer std.debug.print("numeric-function assertions={d}\n",.{assertions});
    try row("SELECT abs(-17)",23,"17");
    try matrix();
    try row("SELECT abs('-32767'::int2)",21,"32767");
    try row("SELECT abs('-2147483647'::int4)",23,"2147483647");
    try row("SELECT abs('-9223372036854775807'::int8)",20,"9223372036854775807");
    try row("SELECT abs(-1.25::real)",700,"1.25");
    try row("SELECT abs(-1.25::float8)",701,"1.25");
    try row("SELECT abs(-1.2300::numeric)",1700,"1.2300");
    try row("SELECT abs('-0'::float8)",701,"0");
    try row("SELECT abs('-0'::real)",700,"0");
    try row("SELECT abs('-Infinity'::numeric)",1700,"Infinity");
    try row("SELECT abs('-Infinity'::float8)",701,"Infinity");
    try row("SELECT abs('-Infinity'::real)",700,"Infinity");
    try row("SELECT abs('NaN'::numeric)",1700,"NaN");
    try row("SELECT abs('NaN'::float8)",701,"NaN");
    try row("SELECT abs('NaN'::real)",700,"NaN");
    try row("SELECT abs(NULL)",701,null);
    try row("SELECT abs(NULL::int2)",21,null);
    try row("SELECT abs(NULL::numeric)",1700,null);
    try row("SELECT abs('-1.25')",701,"1.25");
    try row("SELECT ceil(17)",701,"17");
    try row("SELECT ceiling(-1.25)",1700,"-1");
    try row("SELECT floor(-1.25::real)",701,"-2");
    try row("SELECT trunc(-1.25::real)",701,"-1");
    try row("SELECT sign(-1::int2)",701,"-1");
    try row("SELECT ceil('1.25')",701,"2");
    try row("SELECT ceil('-0.1'::float8)",701,"-0");
    try row("SELECT ceil('-0'::float8)",701,"-0");
    try row("SELECT floor('0'::float8)",701,"0");
    try row("SELECT floor('-0'::float8)",701,"-0");
    try row("SELECT trunc('-0.1'::float8)",701,"-0");
    try row("SELECT trunc('-0'::float8)",701,"-0");
    try row("SELECT sign('-0'::float8)",701,"0");
    try row("SELECT sign('NaN'::float8)",701,"0");
    try row("SELECT sign('NaN'::numeric)",1700,"NaN");
    try row("SELECT sign('-Infinity'::numeric)",1700,"-1");
    try row("SELECT sign('Infinity'::float8)",701,"1");
    try row("SELECT ceil('NaN'::float8)",701,"NaN");
    try row("SELECT floor('-Infinity'::numeric)",1700,"-Infinity");
    try row("SELECT trunc('Infinity'::float8)",701,"Infinity");
    try row("SELECT trunc('NaN'::numeric,-2147483648)",1700,"NaN");
    try row("SELECT trunc(-123.45,-2147483648)",1700,"0");
    try row("SELECT trunc(12,2)",1700,"12.00");
    try row("SELECT trunc('1.234',2::int2)",1700,"1.23");
    try row("SELECT trunc(1.23,NULL)",1700,null);
    try row("SELECT trunc(NULL,2)",1700,null);
    try row("SELECT ceil(NULL)",701,null);
    try row("SELECT floor(NULL::numeric)",1700,null);
    try row("SELECT sign(NULL::float8)",701,null);
    // Native TRUNC also has MACADDR overloads, so unknown is ambiguous.
    try rejects("SELECT trunc(NULL)",error.AmbiguousFunction);
    try rejects("SELECT abs()",error.UndefinedFunction);
    try rejects("SELECT abs(1,2)",error.UndefinedFunction);
    try rejects("SELECT abs('a'::text)",error.UndefinedFunction);
    try rejects("SELECT abs(TRUE)",error.UndefinedFunction);
    try rejects("SELECT abs(1::oid)",error.UndefinedFunction);
    try rejects("SELECT ceil(1,2)",error.UndefinedFunction);
    try rejects("SELECT floor(TRUE)",error.UndefinedFunction);
    try rejects("SELECT sign()",error.UndefinedFunction);
    try rejects("SELECT trunc(1.2::float8,2)",error.UndefinedFunction);
    try rejects("SELECT trunc(1.2,2::int8)",error.UndefinedFunction);
    try rejects("SELECT abs('not a number')",error.InvalidTextRepresentation);
    try rejects("SELECT abs('-32768'::int2)",error.NumericValueOutOfRange);
    try rejects("SELECT abs('-2147483648'::int4)",error.IntegerOverflow);
    try rejects("SELECT abs('-9223372036854775808'::int8)",error.IntegerOverflow);
    try db.execute("CREATE SEQUENCE nf_seq",&r);
    try row("SELECT abs(-nextval('nf_seq'))",20,"1");
    try row("SELECT currval('nf_seq')",20,"1");
    try row("SELECT trunc(NULL::numeric,nextval('nf_seq')::int4)",1700,null);
    // A known NULL argument lets the planner eliminate the strict call.
    try row("SELECT currval('nf_seq')",20,"1");
    try row("SELECT CASE WHEN FALSE THEN abs('-2147483648'::int4) ELSE 7 END",23,"7");
    try db.execute("CREATE TABLE nf(id INT PRIMARY KEY,v INT,n NUMERIC,g INT GENERATED ALWAYS AS(abs(v)) STORED)",&r);
    try db.execute("INSERT INTO nf(id,v,n) VALUES(1,-3,-1.25),(2,4,2.75),(3,NULL,NULL)",&r);
    // Literal NULL is a planning fact; a NULL row value is not.
    try row("SELECT trunc(n,nextval('nf_seq')::int4) FROM nf WHERE id=3",1700,null);
    try row("SELECT currval('nf_seq')",20,"2");
    try row("SELECT trunc(NULL::numeric,sum(nextval('nf_seq'))::int4) FROM nf",1700,null);
    try row("SELECT currval('nf_seq')",20,"2");
    try row("SELECT trunc(NULL::numeric,sum(nextval('nf_seq')) OVER()::int4) FROM nf WHERE id=1",1700,null);
    try row("SELECT currval('nf_seq')",20,"2");
    try row("SELECT trunc(nextval('nf_seq')::numeric,NULL::int4)",1700,null);
    try row("SELECT currval('nf_seq')",20,"2");
    try rejects("SELECT trunc(NULL::numeric,(1/0)::int4)",error.DivisionByZero);
    try row("SELECT CASE WHEN FALSE THEN trunc(NULL::numeric,(1/0)::int4) ELSE 7 END",1700,"7");
    try row("SELECT CASE WHEN FALSE THEN CASE WHEN 1/0=0 THEN trunc(NULL::numeric,2) ELSE 8 END ELSE 7 END",1700,"7");
    try row("SELECT COALESCE(7::numeric,trunc(NULL::numeric,(1/0)::int4))",1700,"7");
    try rejects("SELECT trunc(NULL::numeric,v),sum(id) FROM nf",error.GroupingError);
    try rejects("SELECT DISTINCT trunc(NULL::numeric,nextval('nf_seq')::int4) FROM nf ORDER BY id",error.InvalidColumnReference);
    try row("SELECT currval('nf_seq')",20,"2");
    try rejects("SELECT trunc(NULL::numeric,grouping(v)) FROM nf GROUP BY id",error.GroupingError);
    try rejects("SELECT trunc(NULL::numeric,sum(v) OVER(ORDER BY id)::int4),count(*) FROM nf",error.GroupingError);
    try row("SELECT trunc(NULL::numeric,grouping(id)) FROM nf GROUP BY id HAVING id=1",1700,null);
    try row("SELECT trunc(NULL::numeric,2)+(row_number() OVER())::numeric FROM nf WHERE id=1",1700,null);
    try row("SELECT abs(trunc(NULL::numeric,nextval('nf_seq')::int4))",1700,null);
    try row("SELECT currval('nf_seq')",20,"2");
    try row("SELECT trunc(nextval('nf_seq')::numeric,v) FROM nf WHERE id=3",1700,null);
    try row("SELECT currval('nf_seq')",20,"3");
    try rejects("SELECT trunc(n,(1/0)::int4) FROM nf WHERE id=3",error.DivisionByZero);
    try row("SELECT ceil('999999999999999999999999999999999999999999999999999999999999999.9'::numeric)",1700,"1000000000000000000000000000000000000000000000000000000000000000");
    try row("SELECT floor('-999999999999999999999999999999999999999999999999999999999999999.9'::numeric)",1700,"-1000000000000000000000000000000000000000000000000000000000000000");
    try db.execute("CREATE TABLE nd(id INT PRIMARY KEY,n NUMERIC DEFAULT trunc(NULL::numeric,nextval('nf_seq')::int4))",&r);
    try db.execute("INSERT INTO nd(id) VALUES(1)",&r);
    try row("SELECT n FROM nd",1700,null);
    try row("SELECT currval('nf_seq')",20,"3");
    try db.execute("UPDATE nd SET n=trunc(NULL::numeric,nextval('nf_seq')::int4)",&r);
    try row("SELECT currval('nf_seq')",20,"3");
    try row("SELECT trunc(NULL::numeric,(SELECT trunc(NULL::numeric,(1/0)::int4))::int4)",1700,null);
    try row("SELECT (SELECT trunc(NULL::numeric,nextval('nf_seq')::int4))",1700,null);
    try row("SELECT currval('nf_seq')",20,"3");
    try rejects("SELECT row_number() OVER(ROWS BETWEEN trunc(NULL::numeric,(1/0)::int4)::int8 PRECEDING AND CURRENT ROW) FROM nf",error.DivisionByZero);
    try rejects("SELECT trunc(NULL::numeric,row_number() OVER(ROWS BETWEEN trunc(NULL::numeric,(1/0)::int4)::int8 PRECEDING AND CURRENT ROW)::int4) FROM nf",error.DivisionByZero);
    try rejects("SELECT row_number() OVER(ROWS BETWEEN CURRENT ROW AND trunc(NULL::numeric,(1/0)::int4)::int8 FOLLOWING) FROM nf",error.DivisionByZero);
    try row("SELECT CASE WHEN FALSE THEN SUM(trunc(NULL::numeric,(1/0)::int4)) ELSE 7 END FROM nf",1700,"7");
    try row("SELECT CASE WHEN FALSE THEN FIRST_VALUE(trunc(NULL::numeric,(1/0)::int4)) OVER() ELSE 7 END FROM nf WHERE id=1",1700,"7");
    try rejects("SELECT CASE WHEN FALSE THEN row_number() OVER(ROWS BETWEEN trunc(NULL::numeric,(1/0)::int4)::int8 PRECEDING AND CURRENT ROW) ELSE 7 END FROM nf",error.DivisionByZero);
    try rejects("SELECT 7 FROM nf WINDOW w AS(ROWS BETWEEN trunc(NULL::numeric,(1/0)::int4)::int8 PRECEDING AND CURRENT ROW)",error.DivisionByZero);
    try rejects("SELECT 7 FROM nf WINDOW w AS(ORDER BY trunc(NULL::numeric,(1/0)::int4))",error.DivisionByZero);
    try row("SELECT SUM(abs(v)) FROM nf",20,"7");
    try row("SELECT SUM(ceil(n)) FROM nf",1700,"2");
    try row("SELECT COUNT(*) FROM nf WHERE floor(n)<0",20,"1");
    try row("SELECT g FROM nf WHERE id=1",23,"3");
    try rejects("UPDATE nf SET v=CASE WHEN id=2 THEN '-2147483648'::int4 ELSE -8 END",error.IntegerOverflow);
    try row("SELECT SUM(g) FROM nf",20,"7");
    try rejects("INSERT INTO nf(id,v) VALUES(4,-8),(5,'-2147483648'::int4)",error.IntegerOverflow);
    try row("SELECT COUNT(*) FROM nf",20,"3");
    var primary:DB=.{};var replayed:DB=.{};var scratch:DB.ReplayScratch=.{};
    var bytes:[32768]u8=undefined;var used:usize=0;
    try primary.executeChanges("CREATE TABLE replay(id INT PRIMARY KEY,v NUMERIC,g NUMERIC GENERATED ALWAYS AS(trunc(abs(v),1)) STORED)",&r,&bytes,&used,null,null);
    try replayed.applyChangeRecord(bytes[0..used],&scratch);
    @memset(&bytes,0xa5);
    try replayed.execute("INSERT INTO replay(id,v) VALUES(1,-1.29)",&r);try replayed.execute("SELECT g FROM replay",&r);
    var format:[DB.Io.format_bytes]u8=undefined;try check(std.mem.eql(u8,"1.2",try DB.Io.format(&r.rows[0].cells[0],false,&replayed.session,&format)));
    try row("SELECT 17",23,"17");
    var control:sql.ExecutionControl=.{.max_work=1};db.session.control=&control;
    try rejects("UPDATE nf SET v=-abs(v)",error.QueryWorkLimit);db.session.control=null;
    try row("SELECT SUM(g) FROM nf",20,"7");
    try rejects("SELECT trunc(1.2,121)",error.NumericCapacity);
    var out:[192]u8=undefined;const report=try std.fmt.bufPrint(&out,"{{\"suite\":\"sql-numeric-functions\",\"pass\":true,\"assertions\":{d},\"matrix_queries\":{d}}}\n",.{assertions,matrix_queries});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
