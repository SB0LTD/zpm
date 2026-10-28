//! Exact low-byte equality: independent row model, signed wrap boundaries,
//! width-256 collisions, nullable slots and conservative aborted-write bounds.
const std=@import("std");
const sql=@import("sql");
const DB=sql.Database(.{.tables=1,.columns=2,.rows_per_table=2,.text_bytes=8,.external_storage=true,
    .integer_bits=64,.compact_integral_scans=true,.work_rows=512,.result_rows=4});
var db:DB=.{};
var result:DB.Result=.{};
var assertions:usize=0;
var model:[260]?i64=@splat(null);
var used:usize=0;
var memory:[2097152]u8 align(64)=undefined;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.ByteDomainContract;}
fn count(wanted:i64) !void {
    var source:[160]u8=undefined;var expected:i64=0;
    for(model[0..used]) |item| if(item) |value| {expected+=@intFromBool(value==wanted);};
    try db.execute(try std.fmt.bufPrint(&source,"SELECT COUNT(*) FROM t WHERE v={d}",.{wanted}),&result);
    try check(result.row_count==1 and result.rows[0].cells[0].integer==expected);
    var nonnull:i64=0;for(model[0..used]) |item| {nonnull+=@intFromBool(item!=null);}
    try db.execute(try std.fmt.bufPrint(&source,"SELECT COUNT(*) FROM t WHERE v<>{d}",.{wanted}),&result);
    try check(result.rows[0].cells[0].integer==nonnull-expected);
}
fn fixture(low:i64,width:usize) !void {
    db=.{};model=@splat(null);used=0;
    @memset(&memory,0xa5);try db.bindMemory(&memory,260,600,4096);
    try check(db.tables[0].scan_fingerprints.len>=520);
    try db.execute("CREATE TABLE t(id BIGINT PRIMARY KEY,v BIGINT)",&result);
    var source:[160]u8=undefined;
    for(0..width+1) |i| {
        const value:i64=@intCast(@as(i128,low)+i);model[used]=value;used+=1;
        try db.execute(try std.fmt.bufPrint(&source,"INSERT INTO t VALUES({d},{d})",.{i,value}),&result);
    }
    try check(db.tables[0].integer_bounds[1].known);
    try check(db.tables[0].integer_bounds[1].low==low and db.tables[0].integer_bounds[1].high==@as(i128,low)+width);
    // Exercise both proven non-null and nullable paths, including byte zero.
    for(0..width+1) |i| try count(@intCast(@as(i128,low)+i));
    try db.execute(try std.fmt.bufPrint(&source,"INSERT INTO t VALUES({d},NULL)",.{used}),&result);used+=1;
    for(0..width+1) |i| try count(@intCast(@as(i128,low)+i));
    for([_]i128{-256,-1,@as(i128,@intCast(width))+1,@as(i128,@intCast(width))+256}) |delta| {
        const value=@as(i128,low)+delta;
        if(value>=-9223372036854775808 and value<=9223372036854775807) try count(@intCast(value));
    }
    // Failed/aborted extrema may widen the proof domain but cannot narrow it.
    if(low==-128 and width==255) {
        const tx=try db.begin();
        try db.statement(tx,"INSERT INTO t VALUES(259,512)",&result,.{});db.abort(tx);
        try count(0);try count(256);try count(512);
        try db.execute("UPDATE t SET v=257 WHERE id=129",&result);model[129]=257;
        try count(1);try count(257);try count(-255);
        try db.execute("DELETE FROM t WHERE id=128",&result);model[128]=null;
        try count(0);try count(256);
    }
}
pub fn main() !void {
    try fixture(-128,255);
    try fixture(-128,256);
    try fixture(-9223372036854775808,255);
    try fixture(9223372036854775552,255);
    std.debug.print("PASS exact byte domains: {d} independent equality/inequality assertions\n",.{assertions});
}
