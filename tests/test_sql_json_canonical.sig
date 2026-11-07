//! Large JSONB canonicalization is bounded by document capacity, not depth times capacity.
const std = @import("std");
const builtin = @import("builtin");
const jsonb = @import("jsonb");
const J = jsonb.Jsonb(65535, 64, 38);
var source: [131072]u8 = undefined;
var a: J.Buffer = .{};
var b: J.Buffer = .{};
var rendered: [131072]u8 = undefined;
var assertions: usize = 0;
var failure: ?anyerror = null;
fn check(ok: bool) !void { assertions += 1; if (!ok) return error.JsonCanonicalContractFailed; }
fn append(at: *usize, text: []const u8) void { @memcpy(source[at.*..][0..text.len],text);at.*+=text.len; }
fn run() !void {
    // Reverse order forces quadratic insertion sort in the old implementation.
    var at: usize = 0;
    append(&at,"{");
    var index: usize = 4096;
    while(index != 0) { index-=1; var temp:[64]u8=undefined;
        append(&at,try std.fmt.bufPrint(&temp,"\"k{d:0>4}\":{d}{s}",.{index,index,if(index==0) "" else ","}));
    }
    append(&at,"}");
    try J.parse(source[0..at],&a);
    try check(jsonb.validBinary(a.bytes[0..a.len],64,38));
    try check(jsonb.countAt(a.bytes[0..a.len],0)==4096);
    for(0..4096) |i| {var temp:[16]u8=undefined;const key=try std.fmt.bufPrint(&temp,"k{d:0>4}",.{i});
        const pos=J.field(a.bytes[0..a.len],key) orelse return error.KeyMissing;
        try check(jsonb.numberAt(a.bytes[0..a.len],pos).coef()==i);
    }
    // Nested containers must not each reserve a full key array on the stack.
    at=0;
    for(0..63) |_| append(&at,"{\"z\":0,\"a\":");
    append(&at,"{\"x\":1,\"x\":2}");
    for(0..63) |_| append(&at,"}");
    try J.parse(source[0..at],&a);
    try check(jsonb.validBinary(a.bytes[0..a.len],64,38));
    var text:J.Text=.{.bytes=&rendered};
    try J.render(a.bytes[0..a.len],0,&text);
    const output=rendered[0..text.len];
    try J.parse(output,&b);
    try check(std.mem.eql(u8,a.bytes[0..a.len],b.bytes[0..b.len]));
    // Vary key order, duplicate distribution and nested key-pool lifetimes.
    var state:u64=19;
    for(0..120) |_| {
        at=0;append(&at,"{");var expected:[32]usize=@splat(0);var seen:[32]bool=@splat(false);
        for(0..200) |i| {
            state=state*%6364136223846793005+%1;const key:usize=@intCast((state>>32)%32);expected[key]=i;seen[key]=true;
            var temp:[100]u8=undefined;
            append(&at,try std.fmt.bufPrint(&temp,"\"k{d}\":{{\"b\":0,\"a\":{d},\"b\":2}}{s}",.{key,i,if(i==199) "" else ","}));
        }
        append(&at,"}");try J.parse(source[0..at],&a);
        try check(jsonb.validBinary(a.bytes[0..a.len],64,38));
        for(expected,0..) |value,i| {if(!seen[i]) continue;var temp:[16]u8=undefined;const key=try std.fmt.bufPrint(&temp,"k{d}",.{i});
            const pos=J.field(a.bytes[0..a.len],key) orelse return error.KeyMissing;
            // Canonical child object starts at pos; field accepts a whole value.
            const bytes=a.bytes[pos..][0..jsonb.sizeAt(a.bytes[0..a.len],pos)];
            const child=J.field(bytes,"a") orelse return error.KeyMissing;
            try check(jsonb.numberAt(bytes,child).coef()==value);
        }
    }
}
fn worker() void { run() catch |err| {failure=err;}; }
pub fn main() !void {
    // Sig0.6.4's Linux libc Thread.join panics in this wrapper in hosted CI.
    // Execute the identical workload on the main stack there; no assertions
    // are skipped. Native no-libc Linux and the other hosts retain the worker.
    if (comptime builtin.os.tag == .linux and builtin.link_libc) {
        try run();
    } else {
        const thread=try std.Thread.spawn(.{.stack_size=256*1024},worker,.{});thread.join();
        if(failure) |err| return err;
    }
    std.debug.print("{{\"suite\":\"json-canonical\",\"pass\":true,\"assertions\":{d}}}\n",.{assertions});
}
