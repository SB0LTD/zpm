//! B11 functions/operators lane: PostgreSQL 18 literal forms, scalar string,
//! numeric, bitwise, temporal and formatting functions, OVERLAPS, Unicode
//! text functions and the statistical/bitwise/interval aggregates.
//!
//! Each section runs independently and reports its own failures, so a red
//! run shows exactly which families are missing. Expected values come from
//! the PostgreSQL 18 documentation and sources (REL_18_3) and from
//! tests/sql_conformance/postgres18_oracle.json. Fixtures outside that oracle
//! are pending native PostgreSQL 18 verification (see the lane report).
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=4,.columns=8,.rows_per_table=32,.text_bytes=256,.expr_nodes=1024,.work_rows=64,.result_rows=64,.nulls_first_ascending=false});
var db:DB=.{};var r:DB.Result=.{};
var assertions:usize=0;var failures:usize=0;var section:[]const u8="";

fn fail(source:[]const u8,comptime fmt:[]const u8,args:anytype) void {
    failures+=1;
    std.debug.print("[{s}] {s}: ",.{section,source});
    std.debug.print(fmt++"\n",args);
}
fn check(source:[]const u8,ok:bool) void {
    assertions+=1;
    if(!ok) fail(source,"assertion failed",.{});
}
fn run(source:[]const u8) bool {
    db.execute(source,&r) catch |err| {fail(source,"{s}",.{@errorName(err)});return false;};
    return true;
}
fn formatted(cell:*const DB.Cell,buffer:[]u8) ![]const u8 {
    return DB.Io.format(cell,false,&db.session,buffer);
}
/// One row, one column: type OID and formatted value (null for SQL NULL).
fn value(source:[]const u8,oid:u32,wanted:?[]const u8) void {
    if(!run(source)) return;
    assertions+=1;
    if(r.row_count!=1 or r.column_count!=1) return fail(source,"shape {d}x{d}",.{r.row_count,r.column_count});
    assertions+=1;
    if(sql.typeOid(r.column_types[0])!=oid) return fail(source,"type oid {d}, expected {d}",.{sql.typeOid(r.column_types[0]),oid});
    assertions+=1;
    if(r.column_typmods[0]!=-1) return fail(source,"typmod {d}",.{r.column_typmods[0]});
    cellIs(source,0,0,wanted);
}
fn cellIs(source:[]const u8,row_index:usize,column:usize,wanted:?[]const u8) void {
    assertions+=1;
    const cell=&r.rows[row_index].cells[column];
    if(wanted) |text| {
        if(cell.*==.null_value) return fail(source,"NULL, expected {s}",.{text});
        var buffer:[DB.Io.format_bytes]u8=undefined;
        const actual=formatted(cell,&buffer) catch |err| return fail(source,"format {s}",.{@errorName(err)});
        if(!std.mem.eql(u8,text,actual)) fail(source,"column {d}: '{s}', expected '{s}'",.{column,actual,text});
    } else if(cell.*!=.null_value) {
        var buffer:[DB.Io.format_bytes]u8=undefined;
        fail(source,"expected NULL, got '{s}'",.{formatted(cell,&buffer) catch ""});
    }
}
const Col=struct{name:[]const u8,oid:u32};
/// One row with named, typed columns.
fn shaped(source:[]const u8,columns:[]const Col,values:[]const ?[]const u8) void {
    if(!run(source)) return;
    assertions+=1;
    if(r.row_count!=1 or r.column_count!=columns.len) return fail(source,"shape {d}x{d}",.{r.row_count,r.column_count});
    for(columns,0..) |column,index| {
        assertions+=1;
        if(!std.mem.eql(u8,r.column_names[index].slice(),column.name) or sql.typeOid(r.column_types[index])!=column.oid)
            fail(source,"column {d} is {s}/{d}, expected {s}/{d}",.{index,r.column_names[index].slice(),sql.typeOid(r.column_types[index]),column.name,column.oid});
    }
    for(values,0..) |wanted,index| cellIs(source,0,index,wanted);
}
/// The statement fails with `wanted` and leaves the previous result intact.
fn rejects(source:[]const u8,wanted:anyerror) void {
    const rows=r.row_count;const columns=r.column_count;
    assertions+=1;
    if(db.execute(source,&r)) |_| {
        var buffer:[DB.Io.format_bytes]u8=undefined;
        const shown=if(r.row_count!=0 and r.column_count!=0) formatted(&r.rows[0].cells[0],&buffer) catch "" else "";
        return fail(source,"accepted ('{s}'), expected {s}",.{shown,@errorName(wanted)});
    } else |err| if(err!=wanted) return fail(source,"{s}, expected {s}",.{@errorName(err),@errorName(wanted)});
    assertions+=1;
    if(r.row_count!=rows or r.column_count!=columns) fail(source,"result changed on error",.{});
}
/// One column over several rows in order.
fn rowsOf(source:[]const u8,oid:u32,wanted:[]const ?[]const u8) void {
    if(!run(source)) return;
    assertions+=1;
    if(r.row_count!=wanted.len or r.column_count!=1) return fail(source,"shape {d}x{d}",.{r.row_count,r.column_count});
    assertions+=1;
    if(sql.typeOid(r.column_types[0])!=oid) return fail(source,"type oid {d}, expected {d}",.{sql.typeOid(r.column_types[0]),oid});
    for(wanted,0..) |text,index| cellIs(source,index,0,text);
}
/// The statement stops at the configured work budget (cancellation
/// checkpoints inside input-sized loops), then succeeds without a budget.
fn budgeted(source:[]const u8,limit:u64) void {
    var control:sql.ExecutionControl=.{.max_work=limit};
    db.session.control=&control;
    rejects(source,error.QueryWorkLimit);
    db.session.control=null;
    _=run(source);
}
fn setup(statements:[]const []const u8) void {
    for(statements) |statement| _=run(statement);
}
fn begin(name:[]const u8) usize {
    section=name;db=.{};r=.{};
    return failures;
}
fn report(name:[]const u8,before:usize) void {
    std.debug.print("section {s}: {s}\n",.{name,if(failures==before) "pass" else "FAIL"});
}

// ---- PG.TEXT.LITERALS ------------------------------------------------------

fn literals() void {
    const before=begin("literals");
    // Oracle fixture (postgres18_oracle.json PG.TEXT.LITERALS).
    shaped("SELECT E'a\\nb',$q$abc$q$,U&'d\\0061t'",&.{.{.name="?column?",.oid=25},.{.name="?column?",.oid=25},.{.name="?column?",.oid=25}},&.{"a\nb","abc","dat"});
    // Escape strings (scan.l xe state).
    value("SELECT e'x'",25,"x");
    value("SELECT E'\\t\\b\\f\\r\\v'",25,"\t\x08\x0c\r\x0b");
    value("SELECT E'\\101\\x41\\u0041\\U00000041'",25,"AAAA");
    value("SELECT E'it\\'s'",25,"it's");
    value("SELECT E'it''s'",25,"it's");
    value("SELECT E'\\q\\\\'",25,"q\\");
    value("SELECT E'\\xg'",25,"xg");
    value("SELECT E'\\0101'",25,"\x081");
    value("SELECT E'\\x4a\\x4'",25,"J\x04");
    value("SELECT E'\\303\\251'",25,"\xc3\xa9");
    value("SELECT E'\\u00e9'",25,"\xc3\xa9");
    value("SELECT E'\\uD83D\\uDE00'",25,"\xf0\x9f\x98\x80");
    value("SELECT E'\\U0001F600'",25,"\xf0\x9f\x98\x80");
    value("SELECT E''",25,"");
    value("SELECT E'12'::int+1",23,"13");
    // Dollar quoting: verbatim, case-sensitive tags, nested other tags.
    value("SELECT $$a\\nb$$",25,"a\\nb");
    value("SELECT $q$a'b$$c$q$",25,"a'b$$c");
    value("SELECT $q$$q$",25,"");
    value("SELECT $Q_1$x$q_1$y$Q_1$",25,"x$q_1$y");
    value("SELECT $\xc3\xa9$x$\xc3\xa9$",25,"x");
    value("SELECT 'a'||$$b$$||E'c'",25,"abc");
    value("SELECT $a$x$ab$y$a$",25,"x$ab$y");
    // Unicode escapes, UESCAPE, doubled quotes and escapes.
    value("SELECT u&'x'",25,"x");
    value("SELECT U&'\\+01F600'",25,"\xf0\x9f\x98\x80");
    value("SELECT U&'\\D83D\\DE00'",25,"\xf0\x9f\x98\x80");
    value("SELECT U&'d!0061t' UESCAPE '!'",25,"dat");
    value("SELECT U&'d!0061t' uescape   '!'",25,"dat");
    value("SELECT U&'a\\\\b'",25,"a\\b");
    value("SELECT U&'it''s'",25,"it's");
    value("SELECT U&'d!!t' UESCAPE '!'",25,"d!t");
    // Literal text in predicates, DEFAULT and generated source text.
    setup(&.{"CREATE TABLE lit_t(id INT PRIMARY KEY,s TEXT DEFAULT E'x\\ty',d TEXT DEFAULT $$a'b$$)","INSERT INTO lit_t(id) VALUES(1)"});
    shaped("SELECT s,d FROM lit_t WHERE s=E'x\\ty'",&.{.{.name="s",.oid=25},.{.name="d",.oid=25}},&.{"x\ty","a'b"});
    // Errors: malformed \u (22025), invalid code points/pairs (42601),
    // invalid UTF-8 or NUL from escapes (22021), unterminated forms (42601).
    rejects("SELECT E'\\u12'",error.InvalidEscapeSequence);
    rejects("SELECT E'\\u'",error.InvalidEscapeSequence);
    rejects("SELECT E'\\U0001F60'",error.InvalidEscapeSequence);
    rejects("SELECT E'\\uD83D\\u12'",error.InvalidEscapeSequence);
    rejects("SELECT E'\\u0000'",error.Syntax);
    rejects("SELECT E'\\uD800'",error.Syntax);
    rejects("SELECT E'\\uDC00'",error.Syntax);
    rejects("SELECT E'\\uD83Dx'",error.Syntax);
    rejects("SELECT E'\\U00110000'",error.Syntax);
    rejects("SELECT E'\\xff'",error.CharacterNotInRepertoire);
    rejects("SELECT E'\\0'",error.CharacterNotInRepertoire);
    rejects("SELECT E'\\x00'",error.CharacterNotInRepertoire);
    rejects("SELECT E'\\303'",error.CharacterNotInRepertoire);
    rejects("SELECT E'\\355\\240\\200'",error.CharacterNotInRepertoire);
    rejects("SELECT E'abc",error.Syntax);
    rejects("SELECT E'abc\\'",error.Syntax);
    rejects("SELECT $$abc",error.Syntax);
    rejects("SELECT $a$abc$b$",error.Syntax);
    rejects("SELECT $abc",error.Syntax);
    rejects("SELECT U&'\\006'",error.Syntax);
    rejects("SELECT U&'\\0000'",error.Syntax);
    rejects("SELECT U&'\\D800'",error.Syntax);
    rejects("SELECT U&'\\DE00'",error.Syntax);
    rejects("SELECT U&'\\D83Dx'",error.Syntax);
    rejects("SELECT U&'\\+110000'",error.Syntax);
    rejects("SELECT U&'x\\'",error.Syntax);
    rejects("SELECT U&'x' UESCAPE 'ab'",error.Syntax);
    rejects("SELECT U&'x' UESCAPE '+'",error.Syntax);
    rejects("SELECT U&'x' UESCAPE 'a'",error.Syntax);
    rejects("SELECT U&'x' UESCAPE ' '",error.Syntax);
    rejects("SELECT U&'x' UESCAPE 1",error.Syntax);
    rejects("SELECT U&'x' UESCAPE U&'!'",error.Syntax);
    rejects("SELECT U&'abc",error.Syntax);
    // Decoded capacity (54000), not raw source length.
    var long:[300]u8=undefined;
    const text=std.fmt.bufPrint(&long,"SELECT E'{s}'",.{"\\x41" ** 64}) catch unreachable;
    value(text,25,"A" ** 64);
    const over=std.fmt.bufPrint(&long,"SELECT $$" ++ ("x" ** 257) ++ "$$",.{}) catch unreachable;
    rejects(over,error.TextCapacity);
    report("literals",before);
}

// ---- PG.FUNC.STRING ----------------------------------------------------------

fn strings() void {
    const before=begin("strings");
    // Oracle fixture (PG.FUNC.STRING): names, types and values.
    shaped("SELECT lower('ABC'),upper('abc'),length('abcd'),substring('abcd' FROM 2 FOR 2),trim(' x '),position('b' IN 'abc'),replace('abc','b','x')",
        &.{.{.name="lower",.oid=25},.{.name="upper",.oid=25},.{.name="length",.oid=23},.{.name="substring",.oid=25},.{.name="btrim",.oid=25},.{.name="position",.oid=23},.{.name="replace",.oid=25}},
        &.{"abc","ABC","4","bc","x","2","axc"});
    // PostgreSQL 18 documentation examples (functions-string.html).
    value("SELECT initcap('hi THOMAS')",25,"Hi Thomas");
    value("SELECT initcap('a1b c_d')",25,"A1b C_D");
    value("SELECT upper('abc-xyz 09')",25,"ABC-XYZ 09");
    value("SELECT char_length('jose')",23,"4");
    value("SELECT character_length('')",23,"0");
    value("SELECT octet_length('jose')",23,"4");
    value("SELECT bit_length('jose')",23,"32");
    value("SELECT length(NULL)",23,null);
    value("SELECT lower(NULL)",25,null);
    value("SELECT substring('Thomas' FROM 2 FOR 3)",25,"hom");
    value("SELECT substring('Thomas' FROM 3)",25,"omas");
    value("SELECT substring('Thomas' FOR 2)",25,"Th");
    value("SELECT substring('Thomas' FOR 2 FROM 2)",25,"ho");
    value("SELECT substr('alphabet',3)",25,"phabet");
    value("SELECT substr('alphabet',3,2)",25,"ph");
    value("SELECT substring('abc' FROM 0 FOR 2)",25,"a");
    value("SELECT substring('abc' FROM -5 FOR 3)",25,"");
    value("SELECT substring('abc',2,2147483647)",25,"bc");
    value("SELECT substring('h\xc3\xa9llo',2,2)",25,"\xc3\xa9l");
    value("SELECT substring('abc',2::smallint)",25,"bc");
    value("SELECT substring('abc',NULL)",25,null);
    value("SELECT trim(both 'xyz' from 'yxTomxx')",25,"Tom");
    shaped("SELECT trim(leading 'xyz' from 'yxTomxx'),trim(trailing 'xyz' from 'yxTomxx'),trim(BOTH FROM '  a  ')",
        &.{.{.name="ltrim",.oid=25},.{.name="rtrim",.oid=25},.{.name="btrim",.oid=25}},&.{"Tomxx","yxTom","a"});
    value("SELECT btrim('xyxtrimyyx','xyz')",25,"trim");
    value("SELECT ltrim('zzzytest','xyz')",25,"test");
    value("SELECT rtrim('testxxzx','xyz')",25,"test");
    value("SELECT ltrim('  x ')",25,"x ");
    value("SELECT rtrim('  x ')",25,"  x");
    value("SELECT trim(E'\\tx ')",25,"\tx");
    value("SELECT trim(FROM ' x ')",25,"x");
    value("SELECT trim('x' FROM 'xxaxx')",25,"a");
    value("SELECT trim('a\xc3\xa9' FROM '\xc3\xa9a\xc3\xa9b\xc3\xa9')",25,"b");
    value("SELECT btrim('xx','x')",25,"");
    value("SELECT btrim('abc','')",25,"abc");
    value("SELECT position('om' IN 'Thomas')",23,"3");
    value("SELECT position('' IN 'abc')",23,"1");
    value("SELECT position('z' IN 'abc')",23,"0");
    value("SELECT position('\xc3\xa9' IN 'a\xc3\xa9b')",23,"2");
    value("SELECT position(NULL IN 'a')",23,null);
    value("SELECT strpos('high','ig')",23,"2");
    value("SELECT replace('abcdefabcdef','cd','XX')",25,"abXXefabXXef");
    value("SELECT replace('aaa','aa','b')",25,"ba");
    value("SELECT replace('abc','','x')",25,"abc");
    value("SELECT left('abcde',2)",25,"ab");
    value("SELECT left('abcde',-2)",25,"abc");
    value("SELECT left('abc',10)",25,"abc");
    value("SELECT left('abc',-10)",25,"");
    value("SELECT right('abcde',2)",25,"de");
    value("SELECT right('abcde',-2)",25,"cde");
    value("SELECT right('abc',-10)",25,"");
    value("SELECT right('a\xc3\xa9',1)",25,"\xc3\xa9");
    value("SELECT repeat('Pg',4)",25,"PgPgPgPg");
    value("SELECT repeat('x',-1)",25,"");
    value("SELECT reverse('abcde')",25,"edcba");
    value("SELECT reverse('a\xc3\xa9b')",25,"b\xc3\xa9a");
    value("SELECT lpad('hi',5,'xy')",25,"xyxhi");
    value("SELECT rpad('hi',5,'xy')",25,"hixyx");
    value("SELECT lpad('hello',2)",25,"he");
    value("SELECT lpad('hi',5)",25,"   hi");
    value("SELECT lpad('hi',-1,'x')",25,"");
    value("SELECT lpad('hi',5,'')",25,"hi");
    value("SELECT rpad('\xc3\xa9',3,'\xc3\xbc')",25,"\xc3\xa9\xc3\xbc\xc3\xbc");
    value("SELECT split_part('abc~@~def~@~ghi','~@~',2)",25,"def");
    value("SELECT split_part('abc,def,ghi,jkl',',',-2)",25,"ghi");
    value("SELECT split_part('abc,def,ghi,jkl',',',-1)",25,"jkl");
    value("SELECT split_part('a,b',',',5)",25,"");
    value("SELECT split_part('a,b',',',-5)",25,"");
    value("SELECT split_part('',',',1)",25,"");
    value("SELECT split_part('abc','',1)",25,"abc");
    value("SELECT split_part('abc','',2)",25,"");
    value("SELECT split_part('abc',',',-1)",25,"abc");
    value("SELECT starts_with('alphabet','alph')",16,"t");
    value("SELECT starts_with('a','ab')",16,"f");
    value("SELECT ascii('x')",23,"120");
    value("SELECT ascii('')",23,"0");
    value("SELECT ascii('\xc3\xa9')",23,"233");
    value("SELECT ascii('\xf0\x9f\x98\x80')",23,"128512");
    value("SELECT chr(65)",25,"A");
    value("SELECT chr(233)",25,"\xc3\xa9");
    value("SELECT chr(128512)",25,"\xf0\x9f\x98\x80");
    value("SELECT translate('12345','143','ax')",25,"a2x5");
    value("SELECT translate('abc','ab','')",25,"c");
    value("SELECT translate('a\xc3\xa9b','\xc3\xa9','e')",25,"aeb");
    value("SELECT concat('abcde',2,NULL,22)",25,"abcde222");
    value("SELECT concat_ws(',','abcde',2,NULL,22)",25,"abcde,2,22");
    value("SELECT concat(true,1.50,DATE '2025-03-01')",25,"t1.502025-03-01");
    value("SELECT concat(NULL)",25,"");
    value("SELECT concat_ws(NULL,'a')",25,null);
    value("SELECT overlay('Txxxxas' placing 'hom' from 2 for 4)",25,"Thomas");
    value("SELECT overlay('Txxxxas' placing 'hom' from 2)",25,"Thomxas");
    value("SELECT overlay('abc','x',2,1)",25,"axc");
    value("SELECT to_hex(2147483647)",25,"7fffffff");
    value("SELECT to_hex(-1)",25,"ffffffff");
    value("SELECT to_hex(-1::bigint)",25,"ffffffffffffffff");
    value("SELECT to_hex(255::smallint)",25,"ff");
    value("SELECT \"position\"('abc','c')",23,"3");
    // Columns, WHERE and GROUP BY use the same kernels.
    setup(&.{"CREATE TABLE str_t(id INT PRIMARY KEY,t TEXT,n INT)","INSERT INTO str_t VALUES(1,'Ab',2),(2,NULL,1),(3,'cD',NULL)"});
    rowsOf("SELECT upper(t) FROM str_t ORDER BY id",25,&.{"AB",null,"CD"});
    rowsOf("SELECT left(t,n) FROM str_t ORDER BY id",25,&.{"Ab",null,null});
    rowsOf("SELECT id FROM str_t WHERE lower(t)='cd'",23,&.{"3"});
    rowsOf("SELECT length(t) FROM str_t GROUP BY length(t) ORDER BY 1",23,&.{"2",null});
    // Errors and overload resolution.
    rejects("SELECT substring('abc' FROM 2 FOR -1)",error.SubstringError);
    rejects("SELECT overlay('abc' placing 'x' from 0)",error.SubstringError);
    rejects("SELECT overlay('abc' placing 'x' from 2147483647 for 1)",error.NumericValueOutOfRange);
    rejects("SELECT split_part('a,b',',',0)",error.InvalidParameterValue);
    rejects("SELECT chr(0)",error.ProgramLimitExceeded);
    rejects("SELECT chr(-1)",error.InvalidParameterValue);
    rejects("SELECT chr(1114112)",error.ProgramLimitExceeded);
    rejects("SELECT chr(55296)",error.ProgramLimitExceeded);
    rejects("SELECT repeat('ab',200)",error.TextCapacity);
    rejects("SELECT lpad('a',300)",error.TextCapacity);
    rejects("SELECT lower(1)",error.UndefinedFunction);
    rejects("SELECT length(true)",error.UndefinedFunction);
    rejects("SELECT repeat('a',2.5)",error.UndefinedFunction);
    rejects("SELECT lpad('a',3::bigint)",error.UndefinedFunction);
    rejects("SELECT substring('abc',2::bigint)",error.UndefinedFunction);
    rejects("SELECT upper('a','b')",error.UndefinedFunction);
    rejects("SELECT concat()",error.UndefinedFunction);
    rejects("SELECT concat_ws(',')",error.UndefinedFunction);
    rejects("SELECT substring()",error.UndefinedFunction);
    rejects("SELECT position('a','b')",error.Syntax);
    rejects("SELECT trim(leading)",error.Syntax);
    rejects("SELECT repeat('a',(1/0)::int)",error.DivisionByZero);
    // A strict call with a syntactic NULL still validates constant arguments.
    rejects("SELECT substring('abc',NULL,1/0)",error.DivisionByZero);
    rejects("SELECT substring('abc','b')",error.UnsupportedStatement);
    // Input-sized loops honour the statement work budget.
    budgeted("SELECT length(repeat('x',200))",40);
    budgeted("SELECT reverse(repeat('ab',100))",40);
    budgeted("SELECT position('y' IN repeat('x',200))",40);
    report("strings",before);
}

// ---- PG.FUNC.NUMERIC ---------------------------------------------------------

fn numerics() void {
    const before=begin("numeric");
    // Oracle fixture (PG.FUNC.NUMERIC).
    shaped("SELECT abs(-2),ceil(1.2),floor(1.8),trunc(1.8),sqrt(4.0),power(2,3),ln(1.0)",
        &.{.{.name="abs",.oid=23},.{.name="ceil",.oid=1700},.{.name="floor",.oid=1700},.{.name="trunc",.oid=1700},.{.name="sqrt",.oid=1700},.{.name="power",.oid=701},.{.name="ln",.oid=1700}},
        &.{"2","2","1","1","2.000000000000000","8","0.0000000000000000"});
    // PostgreSQL 18 documentation examples (functions-math.html).
    value("SELECT cbrt(64.0)",701,"4");
    value("SELECT degrees(0.5)",701,"28.64788975654116");
    value("SELECT div(9,4)",1700,"2");
    value("SELECT exp(1.0)",1700,"2.7182818284590452");
    value("SELECT gcd(1071,462)",23,"21");
    value("SELECT lcm(1071,462)",23,"23562");
    value("SELECT ln(2.0)",1700,"0.6931471805599453");
    value("SELECT log(100)",701,"2");
    value("SELECT log10(1000)",701,"3");
    value("SELECT log(2,64.0)",1700,"6.0000000000000000");
    value("SELECT min_scale(8.4100)",23,"2");
    value("SELECT mod(9,4)",23,"1");
    value("SELECT pi()",701,"3.141592653589793");
    value("SELECT power(9,3)",701,"729");
    value("SELECT radians(45.0)",701,"0.7853981633974483");
    value("SELECT scale(8.4100)",23,"4");
    value("SELECT trim_scale(8.4100)",1700,"8.41");
    value("SELECT sin(1)",701,"0.8414709848078965");
    value("SELECT cos(0)",701,"1");
    value("SELECT tan(1)",701,"1.5574077246549023");
    value("SELECT cot(0.5)",701,"1.830487721712452");
    value("SELECT asin(1)",701,"1.5707963267948966");
    value("SELECT acos(1)",701,"0");
    value("SELECT atan(1)",701,"0.7853981633974483");
    value("SELECT atan2(1,0)",701,"1.5707963267948966");
    // numeric result scales (numeric.c ln_var/exp_var/power_var/log_var).
    value("SELECT ln(10.0)",1700,"2.3025850929940457");
    value("SELECT ln(1.5)",1700,"0.4054651081081644");
    value("SELECT ln(1.01)",1700,"0.009950330853168083");
    value("SELECT ln('Infinity'::numeric)",1700,"Infinity");
    value("SELECT ln('NaN'::numeric)",1700,"NaN");
    value("SELECT exp(0.0)",1700,"1.0000000000000000");
    value("SELECT exp(-1.0)",1700,"0.3678794411714423");
    value("SELECT exp(10.0)",1700,"22026.465794806717");
    value("SELECT exp('-Infinity'::numeric)",1700,"0");
    value("SELECT log(100.0)",1700,"2.0000000000000000");
    value("SELECT log10(100.0)",1700,"2.0000000000000000");
    value("SELECT power(2.0,3)",1700,"8.0000000000000000");
    value("SELECT power(-2.0,3)",1700,"-8.0000000000000000");
    value("SELECT power(2.0,-2)",1700,"0.2500000000000000");
    value("SELECT power(0.0,0)",1700,"1.0000000000000000");
    value("SELECT power(10.0,20)",1700,"100000000000000000000.0");
    value("SELECT power(2.0,0.5)",1700,"1.4142135623730950");
    value("SELECT power(1.1,100)",1700,"13780.612339822270");
    value("SELECT power('NaN'::numeric,0)",1700,"1");
    value("SELECT power(1,'NaN'::numeric)",1700,"1");
    value("SELECT power(2.0,'Infinity'::numeric)",1700,"Infinity");
    value("SELECT power(0.5,'Infinity'::numeric)",1700,"0");
    // double precision: dpow/dexp/dlog special cases.
    value("SELECT power(2::float8,0.5)",701,"1.4142135623730951");
    value("SELECT power('NaN'::float8,0)",701,"1");
    value("SELECT power(1::float8,'NaN')",701,"1");
    value("SELECT power(0.5::float8,'Infinity')",701,"0");
    value("SELECT power('-Infinity'::float8,3)",701,"-Infinity");
    value("SELECT ln(2)",701,"0.6931471805599453");
    value("SELECT exp(1)",701,"2.718281828459045");
    value("SELECT exp('-Infinity'::float8)",701,"0");
    value("SELECT cbrt(-27)",701,"-3");
    value("SELECT sin('NaN'::float8)",701,"NaN");
    value("SELECT ln(NULL)",701,null);
    value("SELECT power(NULL,2.0)",1700,null);
    // Exact integer/numeric mod, div, gcd, lcm and scale functions.
    value("SELECT mod(-9,4)",23,"-1");
    value("SELECT mod(9,-4)",23,"1");
    value("SELECT mod(10.5,3)",1700,"1.5");
    value("SELECT mod('7',4)",23,"3");
    value("SELECT mod(5::int2,3::int2)",21,"2");
    value("SELECT mod(2147483648,7)",20,"2");
    value("SELECT mod(-2147483648,-1)",23,"0");
    value("SELECT div(-9,4)",1700,"-2");
    value("SELECT div(9.5,2)",1700,"4");
    value("SELECT gcd(0,0)",23,"0");
    value("SELECT gcd(-12,18)",23,"6");
    value("SELECT gcd(1.5,2.25)",1700,"0.75");
    value("SELECT lcm(1.5,2.25)",1700,"4.50");
    value("SELECT lcm(0,5)",23,"0");
    value("SELECT scale('NaN'::numeric)",23,null);
    value("SELECT trim_scale(0.000)",1700,"0");
    // Errors (2201E, 2201F, 22003, 22012) and overload resolution.
    rejects("SELECT ln(0)",error.InvalidArgumentForLogarithm);
    rejects("SELECT ln(-1)",error.InvalidArgumentForLogarithm);
    rejects("SELECT ln(0.0)",error.InvalidArgumentForLogarithm);
    rejects("SELECT ln('-Infinity'::numeric)",error.InvalidArgumentForLogarithm);
    rejects("SELECT log(0,10)",error.InvalidArgumentForLogarithm);
    rejects("SELECT log(1,10)",error.DivisionByZero);
    rejects("SELECT power(0::float8,-1)",error.InvalidArgumentForPowerFunction);
    rejects("SELECT power(-1::float8,0.5)",error.InvalidArgumentForPowerFunction);
    rejects("SELECT power(0.0,-1)",error.InvalidArgumentForPowerFunction);
    rejects("SELECT power(-8.0,0.5)",error.InvalidArgumentForPowerFunction);
    rejects("SELECT power(10::float8,400)",error.NumericValueOutOfRange);
    rejects("SELECT power(10::float8,-400)",error.NumericValueOutOfRange);
    rejects("SELECT exp(1000)",error.NumericValueOutOfRange);
    rejects("SELECT exp(-1000)",error.NumericValueOutOfRange);
    rejects("SELECT asin(2)",error.NumericValueOutOfRange);
    rejects("SELECT sin('Infinity'::float8)",error.NumericValueOutOfRange);
    rejects("SELECT mod(5,0)",error.DivisionByZero);
    rejects("SELECT mod(5.0,0)",error.DivisionByZero);
    rejects("SELECT div(1,0)",error.DivisionByZero);
    rejects("SELECT gcd(-2147483648,-2147483648)",error.IntegerOverflow);
    rejects("SELECT gcd(-2147483648,0)",error.IntegerOverflow);
    rejects("SELECT lcm(2147483647,2)",error.IntegerOverflow);
    rejects("SELECT mod('7','4')",error.AmbiguousFunction);
    rejects("SELECT mod(1.5::float8,1)",error.UndefinedFunction);
    rejects("SELECT log(2::float8,8)",error.UndefinedFunction);
    rejects("SELECT ln('a'::text)",error.UndefinedFunction);
    rejects("SELECT pi(1)",error.UndefinedFunction);
    rejects("SELECT ln(1.0,2)",error.UndefinedFunction);
    // Column inputs, NULL rows and the work budget in series loops.
    setup(&.{"CREATE TABLE num_t(id INT PRIMARY KEY,x NUMERIC,f FLOAT8)","INSERT INTO num_t VALUES(1,2.0,4),(2,NULL,NULL),(3,10.0,0.25)"});
    rowsOf("SELECT ln(x) FROM num_t ORDER BY id",1700,&.{"0.6931471805599453",null,"2.3025850929940457"});
    rowsOf("SELECT power(f,0.5) FROM num_t ORDER BY id",701,&.{"2",null,"0.5"});
    budgeted("SELECT ln(2.0)",8);
    report("numeric",before);
}

pub fn main(init:std.process.Init) !void {
    literals();
    strings();
    numerics();
    var buffer:[160]u8=undefined;
    const line=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-functions-core\",\"pass\":{s},\"assertions\":{d},\"failures\":{d}}}\n",.{if(failures==0) "true" else "false",assertions,failures});
    try std.Io.File.stdout().writeStreamingAll(init.io,line);
    if(failures!=0) return error.FunctionsContractFailed;
}
