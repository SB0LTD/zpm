//! Pure machine-budget calculation and caller-owned memory-grant accounting.
//! No OS probing, heap allocation, row limit or per-table reservation lives here.
const std = @import("std");
pub const Error = error{ InvalidObservation, InvalidPolicy, ArithmeticOverflow, InvalidStorage, AlreadyInitialized, InvalidRequest, BudgetExceeded, TokenCapacity, InvalidToken };
pub const Machine = struct {
    usable_cpus: u32,
    cpu_quota_milli: ?u64 = null,
    physical_total: u64,
    available_physical: u64,
    process_resident: u64 = 0,
    process_committed: u64 = 0,
    available_commit: ?u64 = null,
    scope_limit: ?u64 = null,
    scope_used: ?u64 = null,
};
pub const Policy = struct {
    hard_process_bytes: ?u64 = null,
    headroom_bytes: ?u64 = null,
    fixed_bytes: u64 = 0,
    recovery_bytes: u64 = 64 * 1024 * 1024,
    execution_percent: u8 = 25,
    minimum_task_bytes: u64 = 128 * 1024,
    max_workers: ?u32 = null,
};
pub const Plan = struct {
    process_bytes: u64,
    shared_pool_bytes: u64,
    preferred_storage_bytes: u64,
    preferred_execution_bytes: u64,
    new_commit_bytes: u64,
    headroom_bytes: u64,
    cpu_workers: u32,
    admitted_tasks: u32,
    pressure: bool,
};
fn add(a: u64,b: u64) Error!u64 {
    const result=@addWithOverflow(a,b);
    if(result[1]!=0) return error.ArithmeticOverflow;
    return result[0];
}

/// Resource observations are supplied by a platform implementation. Existing
/// process ownership is included once; host and container availability are not
/// added together. A shrinking budget never implies that live memory is free.
pub fn plan(machine: Machine, policy: Policy) Error!Plan {
    if(machine.usable_cpus==0 or machine.physical_total==0 or machine.available_physical>machine.physical_total or
        machine.process_resident>machine.physical_total or (machine.scope_limit==null)!=(machine.scope_used==null) or
        (machine.cpu_quota_milli!=null and machine.cpu_quota_milli.?==0)) return error.InvalidObservation;
    if(policy.execution_percent>100 or policy.minimum_task_bytes==0 or
        (policy.max_workers!=null and policy.max_workers.?==0) or
        (policy.hard_process_bytes!=null and policy.hard_process_bytes.?==0)) return error.InvalidPolicy;
    // A small container on a large host must not inherit host-sized headroom.
    // Scope/operator limits constrain the capacity from which defaults derive.
    var capacity=machine.physical_total;
    if(machine.scope_limit) |limit| capacity=@min(capacity,limit);
    if(policy.hard_process_bytes) |limit| capacity=@min(capacity,limit);
    const headroom=policy.headroom_bytes orelse @min(capacity/4,@max(256*1024*1024,capacity/16));
    var budget=@min(machine.physical_total,try add(machine.process_resident,machine.available_physical -| headroom));
    if(machine.available_commit) |available| budget=@min(budget,try add(machine.process_committed,available -| headroom));
    if(machine.scope_limit) |limit| {
        const available=limit -| machine.scope_used.?;
        budget=@min(budget,@min(limit,try add(machine.process_resident,available -| headroom)));
    }
    if(policy.hard_process_bytes) |hard| budget=@min(budget,hard);
    const overhead=try add(policy.fixed_bytes,policy.recovery_bytes);
    const pool=budget -| overhead;
    const execution: u64=@intCast(@as(u128,pool)*policy.execution_percent/100);
    var workers=machine.usable_cpus;
    if(machine.cpu_quota_milli) |quota| {
        const rounded=quota/1000+@intFromBool(quota%1000!=0);
        workers=@intCast(@min(workers,rounded));
    }
    if(policy.max_workers) |maximum| workers=@min(workers,maximum);
    return .{ .process_bytes=budget,.shared_pool_bytes=pool,.preferred_storage_bytes=pool-execution,
        .preferred_execution_bytes=execution,.new_commit_bytes=budget -| machine.process_committed,
        .headroom_bytes=headroom,.cpu_workers=workers,
        .admitted_tasks=@intCast(@min(workers,execution/policy.minimum_task_bytes)),
        .pressure=machine.process_committed>budget };
}

/// A slot is metadata for one live grant, not a fixed-sized data allocation.
/// Slots and Ledger must have stable, disjoint addresses until grants drain.
pub const Slot = struct { bytes:u64=0, generation:u64=1, live:bool=false, retired:bool=false };
pub const Token = struct { owner:usize, index:usize, generation:u64 };
pub const Stats = struct { limit:u64, used:u64, free:u64, active:usize, pressure:bool };
pub const Ledger = struct {
    guard:std.atomic.Value(u32)=.init(0),
    initialized:bool=false,
    slots:[]Slot=&.{},
    limit:u64=0,
    used:u64=0,
    active:usize=0,
    cursor:usize=0,

    fn lock(self:*Ledger) void {
        while(self.guard.cmpxchgWeak(0,1,.acquire,.monotonic)!=null) {
            while(self.guard.load(.monotonic)!=0) std.atomic.spinLoopHint();
        }
    }
    fn unlock(self:*Ledger) void { self.guard.store(0,.release); }
    pub fn bind(self:*Ledger,slots:[]Slot,limit:u64) Error!void {
        if(slots.len==0) return error.InvalidStorage;
        const size=@mulWithOverflow(slots.len,@sizeOf(Slot));
        const end=@addWithOverflow(@intFromPtr(slots.ptr),size[0]);
        const own_end=@addWithOverflow(@intFromPtr(self),@sizeOf(Ledger));
        if(size[1]!=0 or end[1]!=0 or own_end[1]!=0 or
            (@intFromPtr(slots.ptr)<own_end[0] and @intFromPtr(self)<end[0])) return error.InvalidStorage;
        self.lock(); defer self.unlock();
        if(self.initialized) return error.AlreadyInitialized;
        for(slots) |*slot| slot.*=.{};
        self.slots=slots;self.limit=limit;self.initialized=true;
    }
    pub fn acquire(self:*Ledger,bytes:u64) Error!Token {
        self.lock();defer self.unlock();
        if(!self.initialized) return error.InvalidStorage;
        if(bytes==0) return error.InvalidRequest;
        if(self.used>self.limit or bytes>self.limit-self.used) return error.BudgetExceeded;
        for(0..self.slots.len) |offset| {
            const index=(self.cursor+offset)%self.slots.len;
            const slot=&self.slots[index];
            if(slot.live or slot.retired) continue;
            slot.bytes=bytes;slot.live=true;self.used+=bytes;self.active+=1;
            self.cursor=if(index+1==self.slots.len) 0 else index+1;
            return .{.owner=@intFromPtr(self),.index=index,.generation=slot.generation};
        }
        return error.TokenCapacity;
    }
    pub fn release(self:*Ledger,token:Token) Error!void {
        self.lock();defer self.unlock();
        if(!self.initialized or token.owner!=@intFromPtr(self) or token.index>=self.slots.len) return error.InvalidToken;
        const slot=&self.slots[token.index];
        if(!slot.live or slot.retired or slot.generation!=token.generation) return error.InvalidToken;
        if(slot.bytes>self.used or self.active==0) return error.InvalidStorage;
        self.used-=slot.bytes;self.active-=1;slot.bytes=0;slot.live=false;
        // Never wrap a generation and turn an ancient token into an owner.
        if(slot.generation==std.math.maxInt(u64)) slot.retired=true else slot.generation+=1;
    }
    /// Existing grants remain valid under pressure; only new admission stops.
    pub fn resize(self:*Ledger,limit:u64) Error!void {
        self.lock();defer self.unlock();
        if(!self.initialized) return error.InvalidStorage;
        self.limit=limit;
    }
    pub fn stats(self:*Ledger) Stats {
        self.lock();defer self.unlock();
        return .{.limit=self.limit,.used=self.used,.free=self.limit -| self.used,
            .active=self.active,.pressure=self.used>self.limit};
    }
};
