//! Exhaustive valid scalars and short-byte/reference validation. No timings.
const std=@import("std");const expr=@import("expr");
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.ScalarEscapeValidation;}
fn verify(bytes:[]const u8) !void {
    const valid=bytes.len==0 or (bytes.len<=4 and std.unicode.utf8ValidateSlice(bytes) and
        (std.unicode.utf8ByteSequenceLength(bytes[0]) catch 0)==bytes.len);
    if(expr.likeEscape("","",bytes,false)) |matched| try check(valid and matched) else |err| try check(!valid and err==error.InvalidEscapeSequence);
}
pub fn main() !void {
    try verify("");try verify("abcde");try verify("ab");
    var bytes:[4]u8=undefined;
    for(0..0x110000) |point| {
        if(point>=0xd800 and point<=0xdfff) continue;
        const length=try std.unicode.utf8Encode(@intCast(point),&bytes);
        try verify(bytes[0..length]);
    }
    for(0..256) |first| {
        bytes[0]=@intCast(first);try verify(bytes[0..1]);
        for(0..256) |second| {bytes[1]=@intCast(second);try verify(bytes[0..2]);}
    }
    // Mutations around every UTF-8 width, surrogate and upper-bound boundary.
    const boundaries=[_][]const u8{"\xe0\xa0\x80","\xed\x9f\xbf","\xed\xa0\x80","\xef\xbf\xbf",
        "\xf0\x90\x80\x80","\xf4\x8f\xbf\xbf","\xf4\x90\x80\x80","\xf7\xbf\xbf\xbf"};
    for(boundaries) |seed| for(0..seed.len) |position| for(0..256) |value| {
        @memcpy(bytes[0..seed.len],seed);bytes[position]=@intCast(value);try verify(bytes[0..seed.len]);
    };
    for(boundaries) |seed| for(1..seed.len) |length| try verify(seed[0..length]);
    std.debug.print("PASS scalar LIKE escape validation: {d} assertions, all Unicode scalars and malformed boundaries\n",.{assertions});
}
