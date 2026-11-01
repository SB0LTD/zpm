//! Both official named packages must coexist with one owner per source file.
const std=@import("std");const math=@import("math");const sql=@import("sql");
const DB=sql.Database(.{.tables=1,.columns=2,.rows_per_table=2});var db:DB=.{};var result:DB.Result=.{};
pub fn main() !void {
    if(math.lerp(2,4,0.5)!=3) return error.MathCompositionFailed;
    try db.execute("SELECT sqrt(4.0)",&result);
    if(result.row_count!=1 or result.column_count!=1 or sql.typeOid(result.column_types[0])!=1700) return error.MathCompositionFailed;
    var bytes:[DB.Io.format_bytes]u8=undefined;
    if(!std.mem.eql(u8,"2.000000000000000",try DB.Io.format(&result.rows[0].cells[0],false,&db.session,&bytes))) return error.MathCompositionFailed;
    std.debug.print("SQL/math composition3 assertions\n",.{});
}
