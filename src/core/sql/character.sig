//! Caller-owned UTF-8 character-length coercion. No padding or collation rules.
const unicode=@import("std").unicode;
pub const Error=error{InvalidParameterValue,StringDataRightTruncation,CharacterNotInRepertoire};
pub const max_length=10485760;
pub fn encodeTypmod(length:i32) Error!i32 {
    if(length<1 or length>max_length)return error.InvalidParameterValue;
    return length+4;
}
pub fn validTypmod(typmod:i32) bool {return typmod == -1 or (typmod>=5 and typmod<=max_length+4);}
/// NAME has a byte budget; never split a multibyte scalar at that boundary.
pub fn bytePrefix(input:[]const u8,limit:usize) Error![]const u8 {
    _=try coerce(input,-1,false);
    var at:usize=0;
    while(at<input.len) {
        const width=unicode.utf8ByteSequenceLength(input[at]) catch return error.CharacterNotInRepertoire;
        if(width>limit-@min(limit,at))break;
        at+=width;
    }
    return input[0..at];
}
/// Explicit casts clip any excess; assignment/input clips only ASCII spaces.
/// Validate the complete input, including bytes beyond an explicit cut.
pub fn coerce(input:[]const u8,typmod:i32,explicit:bool) Error![]const u8 {
    if(!validTypmod(typmod))return error.InvalidParameterValue;
    const limit:usize=if(typmod<0) input.len else @intCast(typmod-4);
    var at:usize=0;var count:usize=0;var cut=input.len;
    while(at<input.len) {
        if(count==limit)cut=at;
        const width=unicode.utf8ByteSequenceLength(input[at]) catch return error.CharacterNotInRepertoire;
        if(width>input.len-at)return error.CharacterNotInRepertoire;
        const point=unicode.utf8Decode(input[at..][0..width]) catch return error.CharacterNotInRepertoire;
        if(point==0)return error.CharacterNotInRepertoire;
        at+=width;count+=1;
    }
    if(count>limit and !explicit) for(input[cut..]) |byte| {if(byte!=' ')return error.StringDataRightTruncation;};
    return input[0..cut];
}
