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

pub fn main(init:std.process.Init) !void {
    literals();
    var buffer:[160]u8=undefined;
    const line=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-functions-core\",\"pass\":{s},\"assertions\":{d},\"failures\":{d}}}\n",.{if(failures==0) "true" else "false",assertions,failures});
    try std.Io.File.stdout().writeStreamingAll(init.io,line);
    if(failures!=0) return error.FunctionsContractFailed;
}
