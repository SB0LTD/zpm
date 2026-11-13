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
    // VARCHAR(n) and CHAR(n) arguments (CHAR reads as text without padding,
    // except octet_length, which counts it).
    setup(&.{"CREATE TABLE chr_t(id INT PRIMARY KEY,c CHAR(4),v VARCHAR(5))","INSERT INTO chr_t VALUES(1,'ab','Ab c')"});
    shaped("SELECT upper(c),length(c),octet_length(c),upper(v),replace(v,' ','_'),concat(c,'|') FROM chr_t",
        &.{.{.name="upper",.oid=25},.{.name="length",.oid=23},.{.name="octet_length",.oid=23},.{.name="upper",.oid=25},.{.name="replace",.oid=25},.{.name="concat",.oid=25}},
        &.{"AB","2","4","AB C","Ab_c","ab  |"});
    value("SELECT lower('AB'::varchar(5))",25,"ab");
    value("SELECT position('b' IN 'ab'::char(3))",23,"2");
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
    // PostgreSQL's double-precision math can vary with the host math library.
    // The macOS result differs from this reference by one representable value.
    const tangent_query = "SELECT tan(1)";
    if (run(tangent_query)) {
        const shape = r.row_count == 1 and r.column_count == 1;
        check(tangent_query, shape);
        if (shape) {
            check(tangent_query, sql.typeOid(r.column_types[0]) == 701 and r.column_typmods[0] == -1);
            const cell = r.rows[0].cells[0];
            if (cell == .float8) {
                const expected: u64 = @bitCast(@as(f64, 1.5574077246549023));
                const actual: u64 = @bitCast(cell.float8);
                check(tangent_query, actual >= expected - 1 and actual <= expected + 1);
            } else {
                fail(tangent_query, "expected a float8 value", .{});
            }
        }
    }
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

// ---- PG.OP.BITWISE -----------------------------------------------------------

fn bitwise() void {
    const before=begin("bitwise");
    // Oracle fixture (PG.OP.BITWISE).
    shaped("SELECT 3&1,3|4,3#1,1<<2,8>>1",&.{.{.name="?column?",.oid=23},.{.name="?column?",.oid=23},.{.name="?column?",.oid=23},.{.name="?column?",.oid=23},.{.name="?column?",.oid=23}},&.{"1","7","2","4","4"});
    // PostgreSQL 18 documentation examples (functions-math.html, table 9.4).
    value("SELECT 91 & 15",23,"11");
    value("SELECT 32 | 3",23,"35");
    value("SELECT 17 # 5",23,"20");
    value("SELECT ~1",23,"-2");
    value("SELECT 1 << 4",23,"16");
    value("SELECT 8 >> 2",23,"2");
    // Types: common integer type; the shift count is int4.
    value("SELECT 3::int2 & 1::int2",21,"1");
    value("SELECT 3::int2 | 4",23,"7");
    value("SELECT 3::int8 # 1",20,"2");
    value("SELECT '6' & 3",23,"2");
    value("SELECT 1::int8 << 40",20,"1099511627776");
    value("SELECT 1::int2 << 2::int2",21,"4");
    value("SELECT ~0::int8",20,"-1");
    value("SELECT ~(-32768)::int2",21,"32767");
    // Precedence: like ||, lower than + and *; prefix ~ takes 1+2.
    value("SELECT 1 + 2 & 3",23,"3");
    value("SELECT 2 * 3 | 1",23,"7");
    value("SELECT 1 | 2 # 3",23,"0");
    value("SELECT ~1+2",23,"-4");
    value("SELECT (~1)+2",23,"0");
    value("SELECT 1 << 2 = 4",16,"t");
    // Shift counts wrap at the operand width (x86-64/AArch64 builds).
    value("SELECT 1 << 31",23,"-2147483648");
    value("SELECT 1 << 32",23,"1");
    value("SELECT 1 << 33",23,"2");
    value("SELECT -8 >> 1",23,"-4");
    value("SELECT 1::int8 << 63",20,"-9223372036854775808");
    value("SELECT 1::int8 << 64",20,"1");
    value("SELECT 1::int2 << 16",21,"0");
    value("SELECT (-1)::int2 >> 20",21,"-1");
    value("SELECT 5 << -1",23,"-2147483648");
    value("SELECT NULL::int & 1",23,null);
    value("SELECT 1 << NULL",23,null);
    setup(&.{"CREATE TABLE bit_t(id INT PRIMARY KEY,v INT)","INSERT INTO bit_t VALUES(1,12),(2,NULL),(3,5)"});
    rowsOf("SELECT v & 4 FROM bit_t ORDER BY id",23,&.{"4",null,"4"});
    rowsOf("SELECT id FROM bit_t WHERE v # 1 = 4",23,&.{"3"});
    // Errors.
    rejects("SELECT 1.5 & 1",error.UndefinedFunction);
    rejects("SELECT 1 & 1.5",error.UndefinedFunction);
    rejects("SELECT 1 << 2::int8",error.UndefinedFunction);
    rejects("SELECT 1.5 << 1",error.UndefinedFunction);
    rejects("SELECT ~1.5",error.UndefinedFunction);
    rejects("SELECT '1' & '1'",error.AmbiguousFunction);
    rejects("SELECT '1' << 2",error.AmbiguousFunction);
    rejects("SELECT ~'1'",error.AmbiguousFunction);
    rejects("SELECT 'x' & 1",error.InvalidTextRepresentation);
    rejects("SELECT TRUE & 1",error.UndefinedFunction);
    report("bitwise",before);
}

// ---- PG.FUNC.TEMPORAL --------------------------------------------------------

fn temporals() void {
    const before=begin("temporal");
    // Oracle fixture (PG.FUNC.TEMPORAL).
    shaped("SELECT extract(year FROM DATE '2025-03-01'),date_trunc('month',TIMESTAMP '2025-03-15 12:00:00'),age(DATE '2025-03-01',DATE '2024-03-01')",
        &.{.{.name="extract",.oid=1700},.{.name="date_trunc",.oid=1114},.{.name="age",.oid=1186}},&.{"2025","2025-03-01 00:00:00","1 year"});
    // PostgreSQL 18 documentation examples (functions-datetime.html).
    value("SELECT age(timestamp '2001-04-10',timestamp '1957-06-13')",1186,"43 years 9 mons 27 days");
    value("SELECT date_part('hour',timestamp '2001-02-16 20:38:40')",701,"20");
    value("SELECT date_part('month',interval '2 years 3 months')",701,"3");
    value("SELECT date_trunc('hour',timestamp '2001-02-16 20:38:40')",1114,"2001-02-16 20:00:00");
    value("SELECT date_trunc('hour',interval '2 days 3 hours 40 minutes')",1186,"2 days 03:00:00");
    value("SELECT extract(hour from timestamp '2001-02-16 20:38:40')",1700,"20");
    value("SELECT extract(month from interval '2 years 3 months')",1700,"3");
    value("SELECT extract(month from interval '2 years 13 months')",1700,"1");
    value("SELECT justify_days(interval '1 year 65 days')",1186,"1 year 2 mons 5 days");
    value("SELECT justify_hours(interval '50 hours 10 minutes')",1186,"2 days 02:10:00");
    value("SELECT justify_interval(interval '1 mon -1 hour')",1186,"29 days 23:00:00");
    value("SELECT make_date(2013,7,15)",1082,"2013-07-15");
    value("SELECT make_date(-44,3,15)",1082,"0044-03-15 BC");
    value("SELECT make_timestamp(2013,7,15,8,15,23.5)",1114,"2013-07-15 08:15:23.5");
    value("SELECT isfinite(date '2001-02-16')",16,"t");
    value("SELECT isfinite(timestamp 'infinity')",16,"f");
    value("SELECT EXTRACT(CENTURY FROM TIMESTAMP '2000-12-16 12:21:13')",1700,"20");
    value("SELECT EXTRACT(CENTURY FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"21");
    value("SELECT EXTRACT(DAY FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"16");
    value("SELECT EXTRACT(DAY FROM INTERVAL '40 days 1 minute')",1700,"40");
    value("SELECT EXTRACT(DECADE FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"200");
    value("SELECT EXTRACT(DOW FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"5");
    value("SELECT EXTRACT(DOY FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"47");
    value("SELECT EXTRACT(EPOCH FROM TIMESTAMP WITH TIME ZONE '2001-02-16 20:38:40.12-08')",1700,"982384720.120000");
    value("SELECT EXTRACT(EPOCH FROM TIMESTAMP '2001-02-16 20:38:40.12')",1700,"982355920.120000");
    value("SELECT EXTRACT(EPOCH FROM INTERVAL '5 days 3 hours')",1700,"442800.000000");
    value("SELECT EXTRACT(ISODOW FROM TIMESTAMP '2001-02-18 20:38:40')",1700,"7");
    value("SELECT EXTRACT(ISOYEAR FROM DATE '2006-01-01')",1700,"2005");
    value("SELECT EXTRACT(ISOYEAR FROM DATE '2006-01-02')",1700,"2006");
    value("SELECT EXTRACT(JULIAN FROM DATE '2006-01-01')",1700,"2453737");
    value("SELECT EXTRACT(JULIAN FROM TIMESTAMP '2006-01-01 12:00')",1700,"2453737.50000000000000000000");
    value("SELECT EXTRACT(MICROSECONDS FROM TIMESTAMP '2001-02-16 17:12:28.5')",1700,"28500000");
    value("SELECT EXTRACT(MILLENNIUM FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"3");
    value("SELECT EXTRACT(MILLISECONDS FROM TIMESTAMP '2001-02-16 17:12:28.5')",1700,"28500.000");
    value("SELECT EXTRACT(MINUTE FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"38");
    value("SELECT EXTRACT(MONTH FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"2");
    value("SELECT EXTRACT(QUARTER FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"1");
    value("SELECT EXTRACT(SECOND FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"40.000000");
    value("SELECT EXTRACT(SECOND FROM TIMESTAMP '2001-02-16 17:12:28.5')",1700,"28.500000");
    value("SELECT EXTRACT(WEEK FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"7");
    value("SELECT EXTRACT(YEAR FROM TIMESTAMP '2001-02-16 20:38:40')",1700,"2001");
    // Units are case-insensitive, aliases and 10-character prefixes count.
    value("SELECT extract('YEARS' FROM DATE '2025-03-01')",1700,"2025");
    value("SELECT extract(\"Year\" FROM DATE '2025-03-01')",1700,"2025");
    value("SELECT date_part('microsecondsxyz',timestamp '2001-02-16 17:12:28.5')",701,"28500000");
    value("SELECT date_part('mm',timestamp '2001-02-16 17:12:28.5')",701,"12");
    value("SELECT date_part('second',timestamp '2001-02-16 17:12:28.5')",701,"28.5");
    value("SELECT date_part('day',DATE '2001-02-16')",701,"16");
    value("SELECT date_part('epoch',DATE '1970-01-02')",701,"86400");
    value("SELECT extract(year from DATE '0001-01-01' - 1)",1700,"-1");
    value("SELECT extract(century from DATE '0001-12-31 BC')",1700,"-1");
    value("SELECT extract(timezone from TIMESTAMPTZ '2001-02-16 20:38:40+00')",1700,"0");
    value("SELECT extract(quarter from interval '-7 months')",1700,"-3");
    // Infinite inputs.
    value("SELECT extract(year from timestamp 'infinity')",1700,"Infinity");
    value("SELECT extract(day from date 'infinity')",1700,null);
    value("SELECT date_part('year',timestamp '-infinity')",701,"-Infinity");
    value("SELECT date_trunc('day',timestamp 'infinity')",1114,"infinity");
    // date_trunc over every unit; date and timestamptz use the session zone (UTC).
    value("SELECT date_trunc('week',timestamp '2001-02-16 20:38:40')",1114,"2001-02-12 00:00:00");
    value("SELECT date_trunc('week',timestamp '2005-01-01 10:00')",1114,"2004-12-27 00:00:00");
    value("SELECT date_trunc('quarter',timestamp '2001-08-16 20:38:40')",1114,"2001-07-01 00:00:00");
    value("SELECT date_trunc('year',timestamp '2001-08-16 20:38:40')",1114,"2001-01-01 00:00:00");
    value("SELECT date_trunc('decade',timestamp '2001-08-16 20:38:40')",1114,"2000-01-01 00:00:00");
    value("SELECT date_trunc('century',timestamp '2001-08-16 20:38:40')",1114,"2001-01-01 00:00:00");
    value("SELECT date_trunc('millennium',timestamp '2001-08-16 20:38:40')",1114,"2001-01-01 00:00:00");
    value("SELECT date_trunc('minute',timestamp '2001-08-16 20:38:40.5')",1114,"2001-08-16 20:38:00");
    value("SELECT date_trunc('second',timestamp '2001-08-16 20:38:40.5')",1114,"2001-08-16 20:38:40");
    value("SELECT date_trunc('milliseconds',timestamp '2001-08-16 20:38:40.123456')",1114,"2001-08-16 20:38:40.123");
    value("SELECT date_trunc('month',DATE '2001-08-16')",1184,"2001-08-01 00:00:00+00");
    value("SELECT date_trunc('day',TIMESTAMPTZ '2001-08-16 20:38:40+00')",1184,"2001-08-16 00:00:00+00");
    value("SELECT date_trunc('year',interval '3 years 5 months 2 days')",1186,"3 years");
    value("SELECT date_trunc('quarter',interval '3 years 5 months 2 days')",1186,"3 years 3 mons");
    // age(): month lengths of the earlier operand, sign symmetry.
    value("SELECT age(timestamp '2001-03-01',timestamp '2001-01-31')",1186,"1 mon 1 day");
    value("SELECT age(timestamp '2001-01-31',timestamp '2001-03-01')",1186,"-1 mons -1 days");
    value("SELECT age(timestamp '2001-01-01 10:00',timestamp '2001-01-01 12:30')",1186,"-02:30:00");
    value("SELECT age(NULL::timestamp,timestamp '2001-01-01')",1186,null);
    setup(&.{"CREATE TABLE tm_t(id INT PRIMARY KEY,d DATE,ts TIMESTAMP)","INSERT INTO tm_t VALUES(1,'2024-02-29','2024-02-29 10:00'),(2,NULL,NULL)"});
    rowsOf("SELECT extract(doy from d) FROM tm_t ORDER BY id",1700,&.{"60",null});
    rowsOf("SELECT date_trunc('month',ts) FROM tm_t ORDER BY id",1114,&.{"2024-02-01 00:00:00",null});
    // Errors.
    rejects("SELECT extract(foo from timestamp '2001-02-16')",error.InvalidParameterValue);
    rejects("SELECT extract(timezone from timestamp '2001-02-16')",error.UnsupportedStatement);
    rejects("SELECT extract(hour from date '2001-02-16')",error.UnsupportedStatement);
    rejects("SELECT extract(now from date '2001-02-16')",error.UnsupportedStatement);
    rejects("SELECT extract(dow from interval '1 day')",error.UnsupportedStatement);
    rejects("SELECT date_trunc('dow',timestamp '2001-02-16')",error.InvalidParameterValue);
    rejects("SELECT date_trunc('timezone',timestamp '2001-02-16')",error.UnsupportedStatement);
    rejects("SELECT date_trunc('week',interval '1 day')",error.UnsupportedStatement);
    rejects("SELECT date_trunc('foo',timestamp 'infinity')",error.InvalidParameterValue);
    rejects("SELECT extract(year from '2020-01-01')",error.AmbiguousFunction);
    rejects("SELECT extract(year from 1)",error.UndefinedFunction);
    rejects("SELECT extract(from from date '2001-02-16')",error.Syntax);
    rejects("SELECT make_date(2013,2,30)",error.DatetimeFieldOverflow);
    rejects("SELECT make_date(0,1,1)",error.DatetimeFieldOverflow);
    rejects("SELECT make_date(2013,13,1)",error.DatetimeFieldOverflow);
    rejects("SELECT make_timestamp(2013,7,15,25,0,0)",error.DatetimeFieldOverflow);
    rejects("SELECT make_timestamp(2013,7,15,24,0,0.5)",error.DatetimeFieldOverflow);
    rejects("SELECT age(timestamp 'infinity',timestamp '2001-01-01')",error.DatetimeFieldOverflow);
    rejects("SELECT age(timestamp '2001-01-01')",error.ClockUnavailable);
    rejects("SELECT justify_days(interval '2147483647 months 30 days')",error.DatetimeFieldOverflow);
    report("temporal",before);
}

// ---- PG.PRED.OVERLAPS --------------------------------------------------------

fn overlapsPredicate() void {
    const before=begin("overlaps");
    // Oracle fixture (PG.PRED.OVERLAPS).
    shaped("SELECT (DATE '2025-01-01',DATE '2025-02-01') OVERLAPS (DATE '2025-01-15',DATE '2025-03-01')",&.{.{.name="overlaps",.oid=16}},&.{"t"});
    // PostgreSQL 18 documentation examples (functions-datetime.html).
    value("SELECT (DATE '2001-02-16', DATE '2001-12-21') OVERLAPS (DATE '2001-10-30', DATE '2002-10-30')",16,"t");
    value("SELECT (DATE '2001-02-16', INTERVAL '100 days') OVERLAPS (DATE '2001-10-30', DATE '2002-10-30')",16,"f");
    value("SELECT (DATE '2001-10-29', DATE '2001-10-30') OVERLAPS (DATE '2001-10-30', DATE '2001-10-31')",16,"f");
    value("SELECT (DATE '2001-10-30', DATE '2001-10-30') OVERLAPS (DATE '2001-10-30', DATE '2001-10-31')",16,"t");
    // Endpoints in either order; ROW syntax; timestamp and interval forms.
    value("SELECT (DATE '2001-12-21', DATE '2001-02-16') OVERLAPS (DATE '2001-10-30', DATE '2002-10-30')",16,"t");
    value("SELECT ROW(TIMESTAMP '2001-01-01', TIMESTAMP '2001-01-03') OVERLAPS ROW(TIMESTAMP '2001-01-02', INTERVAL '1 day')",16,"t");
    value("SELECT (TIMESTAMP '2001-01-01 10:00', INTERVAL '1 hour') OVERLAPS (TIMESTAMP '2001-01-01 11:00', INTERVAL '1 hour')",16,"f");
    value("SELECT (TIMESTAMPTZ '2001-01-01 10:00+00', INTERVAL '2 hours') OVERLAPS (TIMESTAMPTZ '2001-01-01 11:00+00', TIMESTAMPTZ '2001-01-01 13:00+00')",16,"t");
    value("SELECT (DATE '2001-01-01', DATE '2001-01-05') OVERLAPS (DATE '2001-01-02', DATE '2001-01-03') AND TRUE",16,"t");
    value("SELECT NOT (DATE '2001-01-01', DATE '2001-01-05') OVERLAPS (DATE '2001-02-02', DATE '2001-02-03')",16,"t");
    // overlaps_timestamp NULL rules (not a strict function).
    value("SELECT (NULL::date, NULL::date) OVERLAPS (DATE '2001-01-02', DATE '2001-01-03')",16,null);
    value("SELECT (DATE '2001-01-01', NULL::date) OVERLAPS (DATE '2001-01-02', DATE '2001-01-03')",16,null);
    value("SELECT (DATE '2001-01-05', NULL::date) OVERLAPS (DATE '2001-01-02', DATE '2001-01-07')",16,"t");
    value("SELECT (NULL::date, DATE '2001-01-05') OVERLAPS (DATE '2001-01-02', DATE '2001-01-07')",16,"t");
    value("SELECT (DATE '2001-01-05', NULL) OVERLAPS (DATE '2001-01-06', DATE '2001-01-07')",16,null);
    value("SELECT (DATE '2001-01-05', DATE '2001-01-06') OVERLAPS (DATE '2001-01-05', NULL::date)",16,null);
    value("SELECT (DATE '2001-01-05', NULL::interval) OVERLAPS (DATE '2001-01-01', DATE '2001-01-02')",16,null);
    setup(&.{"CREATE TABLE ov_t(id INT PRIMARY KEY,s DATE,e DATE)","INSERT INTO ov_t VALUES(1,'2025-01-01','2025-01-10'),(2,'2025-02-01','2025-02-10'),(3,NULL,NULL)"});
    rowsOf("SELECT id FROM ov_t WHERE (s,e) OVERLAPS (DATE '2025-01-05',DATE '2025-01-06') ORDER BY id",23,&.{"1"});
    rowsOf("SELECT (s,e) OVERLAPS (DATE '2025-02-05',INTERVAL '1 day') FROM ov_t ORDER BY id",16,&.{"f","t",null});
    // Errors: row arity (42601) and types (42883/42725).
    rejects("SELECT (DATE '2001-01-01') OVERLAPS (DATE '2001-01-02', DATE '2001-01-03')",error.Syntax);
    rejects("SELECT (DATE '2001-01-01', DATE '2001-01-02', DATE '2001-01-03') OVERLAPS (DATE '2001-01-02', DATE '2001-01-03')",error.Syntax);
    rejects("SELECT (DATE '2001-01-01', DATE '2001-01-02') OVERLAPS ROW(DATE '2001-01-02')",error.Syntax);
    rejects("SELECT (DATE '2001-01-01', DATE '2001-01-02') OVERLAPS (DATE '2001-01-02')",error.Syntax);
    rejects("SELECT (1, 2) OVERLAPS (3, 4)",error.UndefinedFunction);
    rejects("SELECT (INTERVAL '1 day', DATE '2001-01-02') OVERLAPS (DATE '2001-01-02', DATE '2001-01-03')",error.UndefinedFunction);
    rejects("SELECT ('2001-01-01', '2001-02-01') OVERLAPS ('2001-01-15', '2001-03-01')",error.AmbiguousFunction);
    report("overlaps",before);
}

// ---- PG.FUNC.FORMAT ----------------------------------------------------------

fn formatting() void {
    const before=begin("format");
    // Oracle fixture (PG.FUNC.FORMAT).
    shaped("SELECT to_char(DATE '2025-03-15','YYYY-MM'),to_date('2025-03-15','YYYY-MM-DD'),to_number('12.3','99.9')",
        &.{.{.name="to_char",.oid=25},.{.name="to_date",.oid=1082},.{.name="to_number",.oid=1700}},&.{"2025-03","2025-03-15","12.3"});
    // PostgreSQL 18 documentation examples (functions-formatting.html).
    value("SELECT to_date('05 Dec 2000','DD Mon YYYY')",1082,"2000-12-05");
    value("SELECT to_number('12,454.8-','99G999D9S')",1700,"-12454.8");
    value("SELECT to_timestamp('05 Dec 2000','DD Mon YYYY')",1184,"2000-12-05 00:00:00+00");
    value("SELECT to_timestamp('2000    JUN','YYYY MON')",1184,"2000-06-01 00:00:00+00");
    value("SELECT to_timestamp('2000+JUN','YYYY/MON')",1184,"2000-06-01 00:00:00+00");
    value("SELECT to_date('20000-1130','YYYY-MMDD')",1082,"20000-11-30");
    value("SELECT to_timestamp(1284352323)",1184,"2010-09-13 04:32:03+00");
    // Field widths, separators, names, 12-hour clock, fractions, years.
    value("SELECT to_date('20250315','YYYYMMDD')",1082,"2025-03-15");
    value("SELECT to_date('2025-3-5','YYYY-MM-DDFM')",1082,"2025-03-05");
    value("SELECT to_date('15/03/2025','DD/MM/YYYY')",1082,"2025-03-15");
    value("SELECT to_date('March 15 2025','Month DD YYYY')",1082,"2025-03-15");
    value("SELECT to_date('95-01-03','YY-MM-DD')",1082,"1995-01-03");
    value("SELECT to_date('05-01-03','YY-MM-DD')",1082,"2005-01-03");
    value("SELECT to_date('2025 075','YYYY DDD')",1082,"2025-03-16");
    value("SELECT to_date('2451545','J')",1082,"2000-01-01");
    value("SELECT to_date('2025-03-15','YYYY-MM-DD HH24')",1082,"2025-03-15");
    // Fields after the end of the input keep their defaults (non-FX mode).
    value("SELECT to_date('2025','YYYYMMDD')",1082,"2025-01-01");
    value("SELECT to_date('Sat 2025-03-15','Dy YYYY-MM-DD')",1082,"2025-03-15");
    value("SELECT to_date('44-03-15 BC','YYYY-MM-DD BC')",1082,"0044-03-15 BC");
    value("SELECT to_timestamp('2011-12-18 11:38 PM','YYYY-MM-DD HH12:MI PM')",1184,"2011-12-18 23:38:00+00");
    value("SELECT to_timestamp('2011-12-18 12:05 a.m.','YYYY-MM-DD HH:MI a.m.')",1184,"2011-12-18 00:05:00+00");
    value("SELECT to_timestamp('2025-03-15 12:34:56.789','YYYY-MM-DD HH24:MI:SS.MS')",1184,"2025-03-15 12:34:56.789+00");
    value("SELECT to_timestamp('2025-03-15 12:34:56.5','YYYY-MM-DD HH24:MI:SS.US')",1184,"2025-03-15 12:34:56.5+00");
    value("SELECT to_timestamp(0)",1184,"1970-01-01 00:00:00+00");
    value("SELECT to_timestamp('Infinity'::float8)",1184,"infinity");
    value("SELECT to_date(NULL,'YYYY')",1082,null);
    // Number templates.
    value("SELECT to_number('-12.5','99.9')",1700,"-12.5");
    value("SELECT to_number('1,234','9,999')",1700,"1234");
    value("SELECT to_number('12.35','99.9')",1700,"12.3");
    value("SELECT to_number('$123','L999')",1700,"123");
    value("SELECT to_number('12-','99MI')",1700,"-12");
    value("SELECT to_number('+12','S99')",1700,"12");
    value("SELECT to_number('0012.50','0000.00')",1700,"12.50");
    value("SELECT to_number('5','')",1700,null);
    // Errors.
    rejects("SELECT to_date('2025-02-30','YYYY-MM-DD')",error.DatetimeFieldOverflow);
    rejects("SELECT to_date('2025-13-01','YYYY-MM-DD')",error.DatetimeFieldOverflow);
    rejects("SELECT to_date('abcd-01-01','YYYY-MM-DD')",error.InvalidDatetimeFormat);
    rejects("SELECT to_date('Foo 2025','Mon YYYY')",error.InvalidDatetimeFormat);
    rejects("SELECT to_date('2025-03-15','IYYY-MM-DD')",error.UnsupportedStatement);
    rejects("SELECT to_timestamp('13 PM','HH12 PM')",error.InvalidDatetimeFormat);
    rejects("SELECT to_timestamp('2000    JUN','FXYYYY MON')",error.InvalidDatetimeFormat);
    rejects("SELECT to_timestamp('12:61','HH24:MI')",error.DatetimeFieldOverflow);
    rejects("SELECT to_timestamp('NaN'::float8)",error.DatetimeFieldOverflow);
    rejects("SELECT to_number('123.4','99.9')",error.NumericValueOutOfRange);
    rejects("SELECT to_number('abc','999')",error.InvalidTextRepresentation);
    rejects("SELECT to_number('12','9.9.9')",error.Syntax);
    rejects("SELECT to_number('1e5','9EEEE')",error.UnsupportedStatement);
    rejects("SELECT to_date(20250315,'YYYYMMDD')",error.UndefinedFunction);
    report("format",before);
}

// ---- PG.AGG.STATISTICAL / PG.AGG.BITWISE / PG.AGG.INTERVAL --------------------

const base_fixture=[_][]const u8{"CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)","INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)"};

fn statistical() void {
    const before=begin("agg-statistical");
    setup(&base_fixture);
    // Oracle fixture (PG.AGG.STATISTICAL).
    shaped("SELECT STDDEV_POP(v),VAR_POP(v),CORR(id,v),COVAR_POP(id,v),REGR_COUNT(id,v) FROM tdd_a",
        &.{.{.name="stddev_pop",.oid=1700},.{.name="var_pop",.oid=1700},.{.name="corr",.oid=701},.{.name="covar_pop",.oid=701},.{.name="regr_count",.oid=20}},
        &.{"8.1649658092772603","66.6666666666666667","1","6.666666666666667","3"});
    // Sample forms and aliases (numeric_stddev_internal scales).
    shaped("SELECT stddev(v),stddev_samp(v),variance(v),var_samp(v) FROM tdd_a",
        &.{.{.name="stddev",.oid=1700},.{.name="stddev_samp",.oid=1700},.{.name="variance",.oid=1700},.{.name="var_samp",.oid=1700}},
        &.{"10.0000000000000000","10.0000000000000000","100.0000000000000000","100.0000000000000000"});
    rowsOf("SELECT stddev_samp(v) FROM tdd_a GROUP BY g ORDER BY g",1700,&.{"7.0710678118654752",null});
    rowsOf("SELECT var_pop(v) FROM tdd_a GROUP BY g ORDER BY g",1700,&.{"25.0000000000000000","0"});
    value("SELECT var_pop(v) FROM tdd_a WHERE id=1",1700,"0");
    value("SELECT var_samp(v) FROM tdd_a WHERE id=1",1700,null);
    value("SELECT stddev_pop(v) FROM tdd_a WHERE id>9",1700,null);
    // Double precision inputs use float8_accum.
    value("SELECT stddev_pop(v::float8) FROM tdd_a",701,"8.16496580927726");
    value("SELECT var_pop(v::float8) FROM tdd_a",701,"66.66666666666667");
    value("SELECT var_samp(v::real) FROM tdd_a",701,"100");
    value("SELECT stddev('1')",701,null);
    // Numeric inputs and NaN.
    setup(&.{"CREATE TABLE stat_n(id INT PRIMARY KEY,x NUMERIC)","INSERT INTO stat_n VALUES(1,1.5),(2,2.5)"});
    value("SELECT var_pop(x) FROM stat_n",1700,"0.25000000000000000000");
    value("SELECT stddev_pop(x) FROM stat_n",1700,"0.50000000000000000000");
    value("SELECT var_samp(x) FROM stat_n",1700,"0.50000000000000000000");
    _=run("INSERT INTO stat_n VALUES(3,'NaN')");
    value("SELECT var_pop(x) FROM stat_n",1700,"NaN");
    // Regression family over (Y=id, X=v).
    shaped("SELECT covar_samp(id,v),regr_sxx(id,v),regr_syy(id,v),regr_sxy(id,v),regr_avgx(id,v),regr_avgy(id,v) FROM tdd_a",
        &.{.{.name="covar_samp",.oid=701},.{.name="regr_sxx",.oid=701},.{.name="regr_syy",.oid=701},.{.name="regr_sxy",.oid=701},.{.name="regr_avgx",.oid=701},
            .{.name="regr_avgy",.oid=701}},&.{"10","200","2","20","20","2"});
    shaped("SELECT regr_slope(id,v),regr_intercept(id,v),regr_r2(id,v) FROM tdd_a",
        &.{.{.name="regr_slope",.oid=701},.{.name="regr_intercept",.oid=701},.{.name="regr_r2",.oid=701}},&.{"0.1","0","1"});
    rowsOf("SELECT regr_count(id,v) FROM tdd_a GROUP BY g ORDER BY g",20,&.{"2","1"});
    value("SELECT regr_count(id,v) FROM tdd_a WHERE id>9",20,"0");
    value("SELECT corr(id,v) FROM tdd_a WHERE id>9",701,null);
    value("SELECT corr(id,v) FROM tdd_a WHERE id=1",701,null);
    value("SELECT covar_samp(id,v) FROM tdd_a WHERE id=1",701,null);
    value("SELECT corr(id,v) FILTER (WHERE g=1) FROM tdd_a",701,"1");
    value("SELECT regr_slope(v,id)*2 FROM tdd_a",701,"20");
    // Errors.
    rejects("SELECT corr(v) FROM tdd_a",error.UndefinedFunction);
    rejects("SELECT corr(id,v,g) FROM tdd_a",error.UndefinedFunction);
    rejects("SELECT corr(id,'x') FROM tdd_a",error.InvalidTextRepresentation);
    rejects("SELECT corr(id,TRUE) FROM tdd_a",error.UndefinedFunction);
    rejects("SELECT corr(DISTINCT id,v) FROM tdd_a",error.UnsupportedStatement);
    rejects("SELECT stddev(TRUE) FROM tdd_a",error.UndefinedFunction);
    rejects("SELECT var_pop(v) FROM tdd_a WHERE stddev(v)>0",error.GroupingError);
    report("agg-statistical",before);
}

fn bitAggregates() void {
    const before=begin("agg-bitwise");
    setup(&base_fixture);
    // Oracle fixture (PG.AGG.BITWISE).
    shaped("SELECT BIT_AND(id),BIT_OR(id),BIT_XOR(id) FROM tdd_a",&.{.{.name="bit_and",.oid=23},.{.name="bit_or",.oid=23},.{.name="bit_xor",.oid=23}},&.{"0","7","4"});
    shaped("SELECT bit_and(v),bit_or(v),bit_xor(v) FROM tdd_a",&.{.{.name="bit_and",.oid=23},.{.name="bit_or",.oid=23},.{.name="bit_xor",.oid=23}},&.{"0","30","0"});
    value("SELECT bit_or(id::int8) FROM tdd_a",20,"7");
    value("SELECT bit_and(id::int2) FROM tdd_a WHERE id IN (1,3)",21,"1");
    value("SELECT bit_xor(id) FROM tdd_a WHERE id>9",23,null);
    rowsOf("SELECT bit_or(id) FROM tdd_a GROUP BY g ORDER BY g",23,&.{"3","7"});
    value("SELECT bit_and(-1)",23,"-1");
    rejects("SELECT bit_and(1.5)",error.UndefinedFunction);
    rejects("SELECT bit_or('1')",error.AmbiguousFunction);
    report("agg-bitwise",before);
}

fn intervalAggregates() void {
    const before=begin("agg-interval");
    setup(&base_fixture);
    // Oracle fixture (PG.AGG.INTERVAL).
    shaped("SELECT AVG(id*INTERVAL '1 day') FROM tdd_a",&.{.{.name="avg",.oid=1186}},&.{"2 days 12:00:00"});
    // interval * / double precision (interval_mul / interval_div).
    value("SELECT 2*INTERVAL '1 day'",1186,"2 days");
    value("SELECT INTERVAL '1 day'*1.5",1186,"1 day 12:00:00");
    value("SELECT INTERVAL '1 month'/2",1186,"15 days");
    value("SELECT INTERVAL '1 mon 1 day'*0.5",1186,"15 days 12:00:00");
    value("SELECT INTERVAL '1 hour'*'2'",1186,"02:00:00");
    value("SELECT '3'*INTERVAL '1 minute'",1186,"00:03:00");
    value("SELECT avg(v*INTERVAL '1 hour') FROM tdd_a",1186,"20:00:00");
    value("SELECT avg(INTERVAL '1 month') FROM tdd_a WHERE id<=3",1186,"1 mon");
    value("SELECT avg(id*INTERVAL '1 month') FROM tdd_a WHERE id<=2",1186,"1 mon 15 days");
    value("SELECT avg(id*INTERVAL '1 day') FROM tdd_a WHERE id>9",1186,null);
    rowsOf("SELECT avg(id*INTERVAL '1 day') FROM tdd_a GROUP BY g ORDER BY g",1186,&.{"1 day 12:00:00","3 days 12:00:00"});
    rejects("SELECT INTERVAL '1 day'/0",error.DivisionByZero);
    rejects("SELECT INTERVAL '1 day'*'NaN'::float8",error.DatetimeFieldOverflow);
    rejects("SELECT INTERVAL '2000000000 days'*2",error.DatetimeFieldOverflow);
    rejects("SELECT INTERVAL '1 day'*INTERVAL '1 day'",error.UndefinedFunction);
    rejects("SELECT 2/INTERVAL '1 day'",error.UndefinedFunction);
    report("agg-interval",before);
}

// ---- PG.TEXT.ENCODING --------------------------------------------------------

fn encoding() void {
    const before=begin("encoding");
    // Oracle fixture (PG.TEXT.ENCODING).
    shaped("SELECT char_length('\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d'),octet_length('\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d'),normalize('a',NFC)",
        &.{.{.name="char_length",.oid=23},.{.name="octet_length",.oid=23},.{.name="normalize",.oid=25}},&.{"4","8","a"});
    // Unicode 16.0 normalization (UAX #15).
    value("SELECT normalize('a')",25,"a");
    value("SELECT normalize(U&'\\0065\\0301',NFC)",25,"\xc3\xa9");
    value("SELECT normalize(U&'\\00E9',NFD)",25,"e\xcc\x81");
    value("SELECT normalize(U&'\\FB01',NFKC)",25,"fi");
    value("SELECT normalize(U&'\\2460',NFKD)",25,"1");
    value("SELECT normalize(U&'\\1100\\1161\\11A8',NFC)",25,"\xea\xb0\x81");
    value("SELECT normalize(U&'\\AC01',NFD)",25,"\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xa8");
    value("SELECT normalize(U&'\\0065\\0323\\0302',NFC)",25,"\xe1\xbb\x87");
    value("SELECT normalize(U&'\\0065\\0302\\0323',NFC)",25,"\xe1\xbb\x87");
    value("SELECT normalize(U&'\\1EC7',NFD)",25,"e\xcc\xa3\xcc\x82");
    value("SELECT normalize(U&'\\212B',NFC)",25,"\xc3\x85");
    value("SELECT normalize(U&'\\212B',NFD)",25,"A\xcc\x8a");
    value("SELECT normalize(U&'\\0061\\0301\\0301',NFC)",25,"\xc3\xa1\xcc\x81");
    value("SELECT length(normalize(U&'\\FDFA',NFKC))",23,"18");
    value("SELECT \"normalize\"('A\xcc\x8a','nfc')",25,"\xc3\x85");
    value("SELECT normalize(NULL,NFC)",25,null);
    shaped("SELECT U&'\\00E9' IS NFC NORMALIZED,U&'\\0065\\0301' IS NFC NORMALIZED,U&'\\0065\\0301' IS NFD NORMALIZED,'a' IS NOT NORMALIZED",
        &.{.{.name="is_normalized",.oid=16},.{.name="is_normalized",.oid=16},.{.name="is_normalized",.oid=16},.{.name="?column?",.oid=16}},&.{"t","f","t","f"});
    value("SELECT NULL::text IS NORMALIZED",16,null);
    value("SELECT octet_length(U&'\\+01F600')",23,"4");
    value("SELECT char_length(U&'\\+01F600x')",23,"2");
    // Errors.
    rejects("SELECT normalize('a',XYZ)",error.Syntax);
    rejects("SELECT normalize('a','NFC')",error.Syntax);
    rejects("SELECT \"normalize\"('a','xyz')",error.InvalidParameterValue);
    rejects("SELECT normalize(1)",error.UndefinedFunction);
    rejects("SELECT 'a' IS NFQ NORMALIZED",error.Syntax);
    report("encoding",before);
}

pub fn main(init:std.process.Init) !void {
    literals();
    strings();
    numerics();
    bitwise();
    temporals();
    overlapsPredicate();
    formatting();
    statistical();
    bitAggregates();
    intervalAggregates();
    encoding();
    var buffer:[160]u8=undefined;
    const line=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-functions-core\",\"pass\":{s},\"assertions\":{d},\"failures\":{d}}}\n",.{if(failures==0) "true" else "false",assertions,failures});
    try std.Io.File.stdout().writeStreamingAll(init.io,line);
    if(failures!=0) return error.FunctionsContractFailed;
}
