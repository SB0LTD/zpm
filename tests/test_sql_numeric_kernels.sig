//! Checked wide construction and numeric ordering against decimal input and
//! native signed arithmetic, including precision boundaries and special values.
const std=@import("std");const numeric=@import("numeric");
const N=numeric.Ops(76);var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.NumericKernelContract;}
fn converted(value:i128) !numeric.Numeric {
    var text:[64]u8=undefined;
    const expected=try N.parse(try std.fmt.bufPrint(&text,"{d}",.{value}));
    const actual=try N.fromWide(value);
    try check(std.meta.eql(actual,expected));return actual;
}
fn precision(comptime digits:usize,value:i128,accept:bool) !void {
    const Ops=numeric.Ops(digits);
    if(Ops.fromWide(value)) |number| {
        try check(accept);var text:[64]u8=undefined;
        try check(std.meta.eql(number,try Ops.parse(try std.fmt.bufPrint(&text,"{d}",.{value}))));
    } else |err| try check(!accept and err==error.NumericCapacity);
}
pub fn main() !void {
    const values=[_]i128{std.math.minInt(i128),std.math.minInt(i128)+1,-10000000000000000000,-9223372036854775808,-1,0,1,9223372036854775807,10000000000000000000,std.math.maxInt(i128)-1,std.math.maxInt(i128)};
    for(values) |a| for(values) |b| {
        const left=try converted(a);const right=try converted(b);
        const expected:i8=if(a<b) -1 else if(a>b) 1 else 0;
        try check(numeric.compareValues(&left,&right)==expected);
    };
    var state:u128=0x9e3779b97f4a7c15;
    for(0..8192) |_| {
        state=state*%0x5851f42d4c957f2d+%0x14057b7ef767814f;const a:i128=@bitCast(state);
        state=state*%0x5851f42d4c957f2d+%0x14057b7ef767814f;const b:i128=@bitCast(state);
        const left=try converted(a);const right=try converted(b);
        try check(numeric.compareValues(&left,&right)==if(a<b) @as(i8,-1) else if(a>b) @as(i8,1) else @as(i8,0));
    }
    try precision(1,9,true);try precision(1,-9,true);try precision(1,10,false);try precision(1,-10,false);
    try precision(18,999999999999999999,true);try precision(18,1000000000000000000,false);
    try precision(38,99999999999999999999999999999999999999,true);
    try precision(38,100000000000000000000000000000000000000,false);
    try precision(38,std.math.minInt(i128),false);try precision(39,std.math.minInt(i128),true);
    const pairs=[_][3][]const u8{.{"-0.000","0","="},.{"1.00","1","="},.{"-1.000","-1","="},.{"0.001","0.01","<"},.{"-0.001","-0.01",">"},.{"-Infinity","-1","<"},.{"Infinity","1",">"},.{"NaN","Infinity",">"},.{"NaN","NaN","="}};
    for(pairs) |pair| {
        const a=try N.parse(pair[0]);const b=try N.parse(pair[1]);const order=numeric.compareValues(&a,&b);
        try check(order==if(pair[2][0]=='=') @as(i8,0) else if(pair[2][0]=='<') @as(i8,-1) else @as(i8,1));
    }
    std.debug.print("PASS numeric kernels: {d} assertions, exact decimal differential, full signed i128 range, precision capacity, mixed scales and specials\n",.{assertions});
}
