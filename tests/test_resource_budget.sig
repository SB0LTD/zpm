//! Synthetic machine observations test arithmetic; they are not machine probes.
const std=@import("std");
const budget=@import("resource_budget");
const workers=@import("worker_thread");
const GiB:u64=1024*1024*1024;
var assertions:usize=0;
fn check(ok:bool) !void { assertions+=1;if(!ok) return error.ResourceBudgetContract; }
fn rejected(comptime expected:anyerror,actual:anytype) !void {
    if(actual) |_| return error.ExpectedFailure else |err| try check(err==expected);
}
const base:budget.Machine=.{.usable_cpus=32,.physical_total=64*GiB,.available_physical=32*GiB,
    .process_resident=8*GiB,.process_committed=8*GiB,.available_commit=48*GiB};
fn plans() !void {
    const p=try budget.plan(base,.{.fixed_bytes=GiB,.recovery_bytes=GiB});
    try check(p.process_bytes==36*GiB and p.shared_pool_bytes==34*GiB);
    try check(p.cpu_workers==32 and p.admitted_tasks==32);
    try check(p.new_commit_bytes==28*GiB and !p.pressure);
    var m=base;m.usable_cpus=256;
    try check((try budget.plan(m,.{})).cpu_workers==256);
    m.cpu_quota_milli=1500;
    try check((try budget.plan(m,.{})).cpu_workers==2);
    try check((try budget.plan(m,.{.max_workers=1})).cpu_workers==1);
    m=base;m.scope_limit=16*GiB;m.scope_used=12*GiB;
    const scoped=try budget.plan(m,.{.fixed_bytes=GiB,.recovery_bytes=GiB});
    try check(scoped.process_bytes==8*GiB and scoped.new_commit_bytes==0);
    m.scope_limit=0;
    const pressure=try budget.plan(m,.{});
    try check(pressure.process_bytes==0 and pressure.pressure and pressure.admitted_tasks==0);
    m=base;m.available_physical=0;m.process_resident=GiB;m.process_committed=2*GiB;
    try check((try budget.plan(m,.{})).pressure);
    try check((try budget.plan(base,.{.hard_process_bytes=10*GiB})).process_bytes==10*GiB);
    m=base;m.usable_cpus=0;try rejected(error.InvalidObservation,budget.plan(m,.{}));
    m=base;m.scope_limit=1;try rejected(error.InvalidObservation,budget.plan(m,.{}));
    m=base;m.available_physical=m.physical_total+1;try rejected(error.InvalidObservation,budget.plan(m,.{}));
    m=base;m.available_commit=std.math.maxInt(u64);
    try rejected(error.ArithmeticOverflow,budget.plan(m,.{.headroom_bytes=0}));
    try rejected(error.InvalidPolicy,budget.plan(base,.{.minimum_task_bytes=0}));
    try rejected(error.InvalidPolicy,budget.plan(base,.{.execution_percent=101}));
    try rejected(error.InvalidPolicy,budget.plan(base,.{.max_workers=0}));
    var random:u64=1707;
    for(0..5000) |_| {
        random=random*%6364136223846793005+%1;
        const total=(1+random%256)*GiB;
        const resident=(random>>8)%total;
        const available=(random>>17)%(total-resident+1);
        const machine:budget.Machine=.{.usable_cpus=@intCast(1+random%512),.physical_total=total,
            .available_physical=available,.process_resident=resident,.process_committed=resident+available/2,
            .available_commit=total*2};
        const result=try budget.plan(machine,.{});
        try check(result.process_bytes<=total);
        try check(result.preferred_storage_bytes+result.preferred_execution_bytes==result.shared_pool_bytes);
        try check(result.cpu_workers==machine.usable_cpus and result.admitted_tasks<=result.cpu_workers);
        try check(@as(u64,result.admitted_tasks)*128*1024<=result.preferred_execution_bytes);
        try check(result.new_commit_bytes==result.process_bytes -| machine.process_committed);
    }
}
fn ledgers() !void {
    var slots:[2]budget.Slot=undefined;
    var ledger:budget.Ledger=.{};
    try rejected(error.InvalidStorage,ledger.acquire(1));
    try ledger.bind(&slots,100);
    try rejected(error.AlreadyInitialized,ledger.bind(&slots,100));
    try rejected(error.InvalidRequest,ledger.acquire(0));
    const first=try ledger.acquire(60);const second=try ledger.acquire(40);
    try check(ledger.stats().used==100 and ledger.stats().active==2);
    try rejected(error.BudgetExceeded,ledger.acquire(1));
    try ledger.resize(50);
    try check(ledger.stats().pressure and ledger.stats().free==0);
    try rejected(error.BudgetExceeded,ledger.acquire(1));
    try ledger.release(first);
    try check(ledger.stats().used==40 and !ledger.stats().pressure);
    const replacement=try ledger.acquire(10);
    try rejected(error.InvalidToken,ledger.release(first));
    var foreign:budget.Ledger=.{};var foreign_slots:[1]budget.Slot=undefined;
    try foreign.bind(&foreign_slots,100);
    try rejected(error.InvalidToken,foreign.release(replacement));
    try ledger.release(replacement);try ledger.release(second);
    try check(ledger.stats().used==0 and ledger.stats().active==0);
    try ledger.resize(1000);
    const one=try ledger.acquire(1);const two=try ledger.acquire(1);
    try rejected(error.TokenCapacity,ledger.acquire(1));
    try ledger.release(one);try ledger.release(two);
    // Inject the representational endpoint to prove generations never wrap.
    foreign_slots[0].generation=std.math.maxInt(u64);
    const last=try foreign.acquire(1);try foreign.release(last);
    try check(foreign_slots[0].retired);
    try rejected(error.TokenCapacity,foreign.acquire(1));
    var overlapping:[1024]u8 align(@max(@alignOf(budget.Ledger),@alignOf(budget.Slot)))=undefined;
    const alias:*budget.Ledger=@ptrCast(@alignCast(&overlapping));alias.*=.{};
    const span:[*]budget.Slot=@ptrCast(@alignCast(&overlapping));
    try rejected(error.InvalidStorage,alias.bind(span[0..8],100));
    var wide:budget.Ledger=.{};var wide_slots:[1]budget.Slot=undefined;
    try wide.bind(&wide_slots,std.math.maxInt(u64));
    const maximum=try wide.acquire(std.math.maxInt(u64));
    try check(wide.stats().used==std.math.maxInt(u64));
    try rejected(error.BudgetExceeded,wide.acquire(1));
    try wide.resize(0);try check(wide.stats().pressure);
    try wide.release(maximum);try check(wide.stats().used==0);
}
var shared:budget.Ledger=.{};
var shared_slots:[16]budget.Slot=undefined;
var markers:[16]std.atomic.Value(u32)=@splat(.init(0));
var failed:std.atomic.Value(bool)=.init(false);
var completed:std.atomic.Value(u32)=.init(0);
fn acquire32() ?budget.Token {
    while(true) {
        if(shared.acquire(32)) |token| return token else |err| {
            if(err==error.BudgetExceeded) { std.atomic.spinLoopHint();continue; }
            failed.store(true,.release);return null;
        }
    }
}
fn entry(_: ?*anyopaque) void {
    for(0..10000) |_| {
        const token=acquire32() orelse return;
        if(markers[token.index].swap(1,.acq_rel)!=0) failed.store(true,.release);
        if(shared.stats().used>256) failed.store(true,.release);
        markers[token.index].store(0,.release);
        shared.release(token) catch { failed.store(true,.release);return; };
        _=completed.fetchAdd(1,.release);
    }
}
fn resizeEntry(_: ?*anyopaque) void {
    const limits=[_]u64{256,128,0,192};
    for(0..20000) |index| shared.resize(limits[index%limits.len]) catch { failed.store(true,.release);return; };
    shared.resize(256) catch { failed.store(true,.release); };
}
pub fn main(init:std.process.Init) !void {
    try plans();try ledgers();
    if(workers.available) {
        try shared.bind(&shared_slots,256);
        var threads:[9]workers.Thread=@splat(.{});var started:usize=0;
        defer for(threads[0..started]) |*thread| thread.join() catch @panic("cannot release live worker ownership");
        for(&threads,0..) |*thread,index| { try thread.start(if(index==8) &resizeEntry else &entry,null);started+=1; }
        for(&threads) |*thread| try thread.join();started=0;
        try check(!failed.load(.acquire) and completed.load(.acquire)==80000);
        try check(shared.stats().used==0 and shared.stats().active==0);
    }
    var buffer:[256]u8=undefined;
    const message=try std.fmt.bufPrint(&buffer,"PASS resource budgets: {d} assertions; synthetic observations; native concurrent grants={d}\n",
        .{assertions,completed.load(.acquire)});
    try std.Io.File.stdout().writeStreamingAll(init.io,message);
}
