//! Physical column correctness; no server SQL or comparative performance claim.
const std=@import("std");
const packed_int=@import("packed_integer");
var assertions:usize=0;
fn check(ok:bool) !void { assertions+=1;if(!ok) return error.PackedIntegerContract; }
fn rejected(comptime expected:anyerror,actual:anytype) !void {
    if(actual) |_| return error.ExpectedFailure else |err| try check(err==expected);
}
fn rehash(frame:[]u8) void {
    var hash=std.hash.Wyhash.init(0);hash.update(frame[0..72]);hash.update(frame[80..]);
    std.mem.writeInt(u64,frame[72..80],hash.final(),.little);
}
fn verify(values:[]const i64,mask:?[]const u8) !void {
    var bytes:[2048]u8=undefined;
    const encoded=try packed_int.encode(values,mask,&bytes);
    const decoded=try packed_int.parse(encoded.frame);
    try check(decoded.rows==values.len);
    var count:u64=0;var total:i128=0;
    for(values,0..) |expected,index| {
        const absent=if(mask) |bits| (bits[index/8]&(@as(u8,1)<<@as(u3,@intCast(index%8))))!=0 else false;
        const actual=try decoded.value(index);
        if(absent) try check(actual==null) else {
            try check(actual!=null and actual.?==expected);count+=1;total+=expected;
        }
    }
    const sum:?i128=if(count==0) null else total;
    try check(decoded.summary().nonnull==count and decoded.summary().sum==sum);
    try rejected(error.RowOutOfBounds,decoded.value(@intCast(values.len)));
}
pub fn main(init:std.process.Init) !void {
    try verify(&.{},null);try verify(&.{0},null);try verify(&.{-99,-99,-99},null);
    try verify(&.{std.math.minInt(i64),std.math.maxInt(i64)},null);
    try verify(&.{10,11,12},&.{2});try verify(&.{0,0,0},&.{255});
    try verify(&.{std.math.maxInt(i64),std.math.maxInt(i64)},null);
    // Exercise every packing width, including nine-byte straddles and tails.
    for(0..65) |width| {
        var span_values:[17]i64=undefined;
        const span:u64=if(width==64) std.math.maxInt(u64) else if(width==0) 0 else (@as(u64,1)<<@as(u6,@intCast(width)))-1;
        const base:i64=if(width==64) std.math.minInt(i64) else -17;
        for(&span_values,0..) |*value,index| value.*=@bitCast(@as(u64,@bitCast(base))+%(if(index==16) span else @as(u64,@intCast(index))&span));
        try verify(&span_values,null);
        try verify(&span_values,&.{0b10001010,0b10000000,0});
        var bytes:[2048]u8=undefined;
        const view=try packed_int.encode(&span_values,null,&bytes);
        try check(view.bits==width);
    }
    var values:[128]i64=undefined;var random:u64=811;
    for(0..1000) |trial| {
        var mask:[16]u8=@splat(0);
        const count=trial%129;
        for(values[0..count],0..) |*value,index| {
            random=random*%6364136223846793005+%1;
            value.*=switch(trial%4) {0=>@intCast(random%17),1=>@as(i64,@intCast(random%1000000))-500000,
                2=>@bitCast(random),else=>-8};
            if(random%7==0) mask[index/8]|=@as(u8,1)<<@as(u3,@intCast(index%8));
        }
        try verify(values[0..count],if(trial%2==0) &mask else null);
    }
    var tiny:[79]u8=@splat(0x5a);
    try rejected(error.OutputTooSmall,packed_int.encode(&.{1,2,3},null,&tiny));
    for(tiny) |byte| try check(byte==0x5a);
    var output:[2048]u8=@splat(0x5a);
    try rejected(error.InvalidNullMask,packed_int.encode(&.{1,2,3},&.{},&output));
    for(output) |byte| try check(byte==0x5a);
    var alias:[64]i64=@splat(7);
    try rejected(error.AliasedStorage,packed_int.encode(&alias,null,std.mem.sliceAsBytes(&alias)));
    for(alias) |value| try check(value==7);
    const valid=try packed_int.encode(&.{10,11,12},&.{2},&output);
    for(output[valid.frame.len..]) |byte| try check(byte==0x5a);
    var mask_alias:[256]u8=@splat(0);
    try rejected(error.AliasedStorage,packed_int.encode(&.{1,2,3},mask_alias[0..1],&mask_alias));
    var damaged:[2048]u8=undefined;
    @memcpy(damaged[0..valid.frame.len],valid.frame);
    damaged[valid.frame.len-1]^=1;
    try rejected(error.InvalidFrame,packed_int.parse(damaged[0..valid.frame.len]));
    @memcpy(damaged[0..valid.frame.len],valid.frame);
    damaged[56]^=1;rehash(damaged[0..valid.frame.len]);
    try rejected(error.InvalidFrame,packed_int.parse(damaged[0..valid.frame.len]));
    @memcpy(damaged[0..valid.frame.len],valid.frame);
    damaged[81]|=4;rehash(damaged[0..valid.frame.len]); // nonzero NULL delta
    try rejected(error.InvalidFrame,packed_int.parse(damaged[0..valid.frame.len]));
    @memcpy(damaged[0..valid.frame.len],valid.frame);
    damaged[11]=65;rehash(damaged[0..valid.frame.len]);
    try rejected(error.InvalidFrame,packed_int.parse(damaged[0..valid.frame.len]));
    @memcpy(damaged[0..valid.frame.len],valid.frame);
    damaged[80]|=128;rehash(damaged[0..valid.frame.len]); // unused bitmap bit
    try rejected(error.InvalidFrame,packed_int.parse(damaged[0..valid.frame.len]));
    @memcpy(damaged[0..valid.frame.len],valid.frame);
    damaged[valid.frame.len-1]|=128;rehash(damaged[0..valid.frame.len]); // unused data bit
    try rejected(error.InvalidFrame,packed_int.parse(damaged[0..valid.frame.len]));
    try rejected(error.InvalidFrame,packed_int.parse(valid.frame[0..valid.frame.len-1]));
    const constant=try packed_int.encode(&.{std.math.minInt(i64)},null,&output);
    try check(constant.frame.len==packed_int.header_bytes and constant.bits==0);
    // A constant physical column can describe a u64 count without a row array.
    // This checks format arithmetic; it is not a claim of a loaded SQL table.
    std.mem.writeInt(u64,output[16..24],std.math.maxInt(u64),.little);
    std.mem.writeInt(u64,output[48..56],std.math.maxInt(u64),.little);
    const total=@as(i128,std.math.minInt(i64))*@as(i128,std.math.maxInt(u64));
    std.mem.writeInt(i128,output[56..72],total,.little);rehash(output[0..80]);
    const enormous=try packed_int.parse(output[0..80]);
    try check(enormous.summary().sum.?==total);
    try check((try enormous.value(std.math.maxInt(u64)-1)).?==std.math.minInt(i64));
    try rejected(error.RowOutOfBounds,enormous.value(std.math.maxInt(u64)));
    var buffer:[160]u8=undefined;
    const message=try std.fmt.bufPrint(&buffer,"PASS packed integer physical columns: {d} assertions; SQL integration not claimed\n",.{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io,message);
}
