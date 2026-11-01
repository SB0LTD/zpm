//! Integer-root definition checks, independent linear oracle and wide boundaries.
const std=@import("std");var assertions:usize=0;
// Adapter exposes the remainder implied by the standard kernel's result.
// Expected roots below come from an independent linear oracle/exact bounds.
fn rootAndRemainder(comptime T:type,value:T) struct{root:T,remainder:T} {
    const root:T=std.math.sqrt(value);return .{.root=root,.remainder=value-root*root};
}
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.IntegerSquareRootContractFailed;}
pub fn main() !void {
    var expected:u64=0;
    for(0..65537)|n| {
        while((expected+1)*(expected+1)<=n)expected+=1;
        const actual=rootAndRemainder(u64,@intCast(n));
        try check(actual.root==expected);
        try check(actual.remainder==n-expected*expected);
    }
    for(0..256)|n| {
        const actual=rootAndRemainder(u8,@intCast(n));
        const wide=rootAndRemainder(u64,@intCast(n));
        try check(actual.root==wide.root and actual.remainder==wide.remainder);
    }
    const zero=rootAndRemainder(u0,0);try check(zero.root==0 and zero.remainder==0);
    for(0..2)|n| {const actual=rootAndRemainder(u1,@intCast(n));try check(actual.root==n and actual.remainder==0);}
    for(0..4)|n| {const actual=rootAndRemainder(u2,@intCast(n));try check(actual.root==@as(u2,if(n==0)0 else 1) and actual.remainder==@as(u2,@intCast(if(n==0)0 else n-1)));}
    for(0..512)|bit| {
        const q:u1024=@as(u1024,1)<<@intCast(bit);const square=q*q;
        const before=rootAndRemainder(u1024,square-1);
        const exact=rootAndRemainder(u1024,square);
        const after=rootAndRemainder(u1024,square+1);
        try check(before.root==q-1 and before.remainder==2*q-2);
        try check(exact.root==q and exact.remainder==0);
        try check(after.root==q and after.remainder==1);
        const low=rootAndRemainder(u1024,square+q);
        const high=rootAndRemainder(u1024,square+q+1);
        try check(low.root==q and low.remainder==q);
        try check(high.root==q and high.remainder==q+1);
    }
    {const odd=rootAndRemainder(u3,~@as(u3,0));try check(odd.root==2 and odd.remainder==3);}
    {const odd=rootAndRemainder(u7,~@as(u7,0));try check(odd.root==11 and odd.remainder==6);}
    {const odd=rootAndRemainder(u9,~@as(u9,0));try check(odd.root==22 and odd.remainder==27);}
    {const odd=rootAndRemainder(u17,~@as(u17,0));try check(odd.root==362 and odd.remainder==27);}
    {const odd=rootAndRemainder(u65,~@as(u65,0));try check(odd.root==6074000999 and odd.remainder==11566105230);}
    {const odd=rootAndRemainder(u255,~@as(u255,0));try check(odd.root==240615969168004511545033772477625056927 and odd.remainder==55332404893129640328019711436574136638);}
    {const odd=rootAndRemainder(u1023,~@as(u1023,0));try check(odd.root==9480751908109176726832526455652159260084541744031329863792443335050652303478140824795455728407420733006933090614179782624068317238241310650437075740534632 and odd.remainder==15563669732087628378811019682754654595398600017404682423670714732803357176112513263249200023827109637373974631014667510261003780704158592181210470920693183);}
    const largest=rootAndRemainder(u1024,~@as(u1024,0));
    const root:u1024=(@as(u1024,1)<<512)-1;
    try check(largest.root==root and largest.remainder==2*root);
    std.debug.print("integer-square-root assertions {d}\n",.{assertions});
}
