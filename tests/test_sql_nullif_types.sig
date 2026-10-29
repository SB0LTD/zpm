//! NULLIF must return the selected equality operator's first argument type.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=1,.columns=4,.rows_per_table=8,.text_bytes=128});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.NullifTypeContractFailed;}
fn row(source:[]const u8,oid:u32,wanted:?[]const u8) !void {
    try db.execute(source,&result);
    try check(result.row_count==1 and result.column_count==1);
    if(sql.typeOid(result.column_types[0])!=oid)std.debug.print("{s}: type {d}, expected {d}\n",.{source,sql.typeOid(result.column_types[0]),oid});
    try check(sql.typeOid(result.column_types[0])==oid);
    const cell=&result.rows[0].cells[0];
    if(wanted)|text| {
        try check(switch(oid){21,23,20,26=>cell.*==.integer,700=>cell.*==.float4,701=>cell.*==.float8,1700=>cell.*==.numeric,19,25=>cell.*==.text,1082=>cell.*==.date,1114=>cell.*==.timestamp,1184=>cell.*==.timestamptz,else=>false});
        var buffer:[DB.Io.format_bytes]u8=undefined;
        const actual=try DB.Io.format(cell,false,&db.session,&buffer);
        if(!std.mem.eql(u8,text,actual))std.debug.print("{s}: {s}, expected {s}\n",.{source,actual,text});
        try check(std.mem.eql(u8,text,actual));
    } else try check(cell.*==.null_value);
}
pub fn main(init:std.process.Init) !void {
    try row("SELECT NULLIF(1::real,2::double precision)",700,"1");
    try row("SELECT NULLIF(1::real,1::double precision)",700,null);
    try row("SELECT NULLIF(1,2.0)",1700,"1");
    try row("SELECT NULLIF(1,1.0)",1700,null);
    try row("SELECT NULLIF(1,2::real)",701,"1");
    try row("SELECT NULLIF(1::numeric,2::real)",701,"1");
    try row("SELECT NULLIF(1::smallint,2::bigint)",21,"1");
    try row("SELECT NULLIF(1::int4,2::oid)",26,"1");
    try row("SELECT NULLIF('a'::name,'b'::text)",19,"a");
    try row("SELECT NULLIF('a'::text,'b'::name)",25,"a");
    try row("SELECT NULLIF(DATE '2025-01-01',TIMESTAMP '2025-01-02 00:00:00')",1082,"2025-01-01");
    try row("SELECT NULLIF(TIMESTAMP '2025-01-01 12:00:00',TIMESTAMPTZ '2025-01-02 00:00:00+00')",1114,"2025-01-01 12:00:00");
    try row("SELECT NULLIF(NULL,NULL)",25,null);
    try row("SELECT NULLIF('1',2)",23,"1");
    try db.execute("CREATE SEQUENCE nt",&result);
    try row("SELECT NULLIF(nextval('nt')::real,0::float8)",700,"1");
    try row("SELECT currval('nt')",20,"1");
    try row("SELECT NULLIF(nextval('nt')::real,nextval('nt')::float8)",700,"2");
    try row("SELECT currval('nt')",20,"3");
    try row("SELECT NULLIF(nextval('nt')::real,4::float8)",700,null);
    try db.execute("CREATE TABLE nt_values(id INT PRIMARY KEY,v REAL)",&result);
    try db.execute("INSERT INTO nt_values VALUES(1,1)",&result);
    try row("SELECT NULLIF(v,0::float8) FROM nt_values",700,"1");
    try row("SELECT NULLIF(MAX(v),0::float8) FROM nt_values",700,"1");
    try db.execute("INSERT INTO nt_values VALUES(2,NULL)",&result);
    try row("SELECT NULLIF(v,nextval('nt')::float8) FROM nt_values WHERE id=2",700,null);
    try row("SELECT currval('nt')",20,"5");
    try row("SELECT 17",23,"17");
    const before=result;
    if(db.execute("SELECT NULLIF(1::real,1/0::float8)",&result)) |_|return error.ErrorSuppressed else |err|try check(err==error.DivisionByZero);
    try check(result.row_count==before.row_count and result.column_types[0]==before.column_types[0] and result.rows[0].cells[0].integer==17);
    var buffer:[128]u8=undefined;
    const report=try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-nullif-types\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
