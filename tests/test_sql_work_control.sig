//! Batched control must match the existing scalar observable state exactly.
const std=@import("std");
const sql=@import("sql");
const Control=sql.ExecutionControl;
const Probe=struct {
    control:*Control,fail_at:usize,mutate:bool=false,calls:usize=0,trace:[512]u64=undefined,
    fn poll(raw:?*anyopaque) sql.Error!void {
        const self:*Probe=@ptrCast(@alignCast(raw.?));
        self.trace[self.calls]=self.control.used;self.calls+=1;
        if(self.calls==self.fail_at) return error.QueryCanceled;
        if(self.mutate and self.calls==2) {self.control.poll_interval=1;self.control.max_work=self.control.used+|3;}
    }
};
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) return error.WorkControlContract;}
pub fn main() !void {
    const maximum=std.math.maxInt(u64);
    for([_]u64{0,1,5,63,64,65,255,256,257,maximum}) |limit|
    for([_]u32{0,1,7,256,std.math.maxInt(u32)}) |interval|
    for([_]usize{0,1,2,63,64,65,255,511}) |count|
    for([_]u64{0,1,maximum-2,maximum}) |initial|
    for([_]u32{0,1,17}) |until|
    for([_]usize{0,1,3,257}) |fail_at|
    for([_]bool{false,true}) |mutate| {
        var scalar:Control=.{.max_work=limit,.used=initial,.poll_interval=interval,.until_poll=until,.poll=Probe.poll};
        var batched=scalar;
        var a:Probe=.{.control=&scalar,.fail_at=fail_at,.mutate=mutate};var b:Probe=.{.control=&batched,.fail_at=fail_at,.mutate=mutate};
        scalar.context=&a;batched.context=&b;
        var scalar_error:?anyerror=null;
        for(0..count) |_| scalar.checkpoint() catch |err| {scalar_error=err;break;};
        var batch_error:?anyerror=null;batched.advance(count) catch |err| {batch_error=err;};
        try check(scalar_error==batch_error and scalar.used==batched.used and scalar.until_poll==batched.until_poll and
            scalar.max_work==batched.max_work and scalar.poll_interval==batched.poll_interval);
        try check(a.calls==b.calls and std.mem.eql(u64,a.trace[0..a.calls],b.trace[0..b.calls]));
    };
    // Zero interval means polling every operation, including batched calls.
    var c:Control=.{.poll_interval=0};var probe:Probe=.{.control=&c,.fail_at=0};c.context=&probe;c.poll=Probe.poll;
    try c.advance(511);try check(c.used==511 and probe.calls==511);
    std.debug.print("PASS exact batched work control: {d} assertions\n",.{assertions});
}
