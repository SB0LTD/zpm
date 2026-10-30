const std=@import("std");const fmt=@import("datetime_format");
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.DatetimeFormatContract;}
pub fn main() !void {
    var bytes:[64]u8=@splat(0xa5);
    const before=bytes;
    if(fmt.format(0,"YYYY-MM-DD",bytes[0..9])) |_| return error.ExpectedCapacity else |err| try check(err==error.TextCapacity);
    try check(std.mem.eql(u8,&bytes,&before));
    if(fmt.format(0,"YYYY IYYY",&bytes)) |_| return error.ExpectedUnsupported else |err| try check(err==error.UnsupportedStatement);
    try check(std.mem.eql(u8,&bytes,&before));
    if(fmt.format(-9223372036854775808,"YYYY",&bytes)) |_| return error.ExpectedRange else |err| try check(err==error.DatetimeFieldOverflow);
    try check(std.mem.eql(u8,&bytes,&before));
    @memcpy(bytes[0..4],"YYYY");const alias_before=bytes;
    if(fmt.format(0,bytes[0..4],bytes[1..])) |_| return error.ExpectedAlias else |err| try check(err==error.InvalidParameterValue);
    try check(std.mem.eql(u8,&bytes,&alias_before));
    const n=try fmt.format(0,"YYYY-MM-DD",&bytes);try check(n==10 and std.mem.eql(u8,bytes[0..n],"2000-01-01"));
    std.debug.print("PASS datetime template ownership: {d} assertions\n",.{assertions});
}
