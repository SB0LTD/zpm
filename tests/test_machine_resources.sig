const std=@import("std");
const builtin=@import("builtin");
const facts=@import("resource_observation");
const resources=@import("machine_resources");
const budget=@import("resource_budget");
var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok) {std.debug.print("FAILED resource observation assertion {d}\n",.{assertions});return error.ResourceObservationContract;}}
fn rejected(comptime expected:anyerror,actual:anytype) !void {
    if(actual) |_| return error.ExpectedFailure else |err| try check(err==expected);
}
const Entry=struct{path:[]const u8,value:[]const u8};
const Fixture=struct {
    entries:[]const Entry,
    denied:?[]const u8=null,
    migrate:bool=false,
    group_reads:usize=0,
    fn read(raw:?*anyopaque,path:[]const u8,out:[]u8) resources.Error!?[]const u8 {
        const self:*Fixture=@ptrCast(@alignCast(raw.?));
        if(self.denied) |denied| if(std.mem.eql(u8,path,denied)) return error.ProbeFailed;
        if(std.mem.eql(u8,path,"/proc/self/cgroup")) {
            self.group_reads+=1;
            if(self.migrate and self.group_reads>1) {
                const changed="0::/different\n";
                if(out.len<changed.len) return error.BufferTooSmall;
                @memcpy(out[0..changed.len],changed);return out[0..changed.len];
            }
        }
        for(self.entries) |entry| if(std.mem.eql(u8,path,entry.path)) {
            if(out.len<entry.value.len) return error.BufferTooSmall;
            @memcpy(out[0..entry.value.len],entry.value);return out[0..entry.value.len];
        };
        return null;
    }
};
const entries=[_]Entry{
    .{.path="/proc/self/status",.value="VmRSS:\t1024 kB\nVmSize:\t2048 kB\nCpus_allowed_list:\t0-127,256-383\n"},
    .{.path="/proc/meminfo",.value="MemTotal: 67108864 kB\nMemAvailable: 33554432 kB\nCommitLimit: 134217728 kB\nCommitted_AS: 67108864 kB\n"},
    .{.path="/proc/sys/vm/overcommit_memory",.value="2\n"},
    .{.path="/proc/self/cgroup",.value="0::/parent/child\n"},
    .{.path="/proc/self/mountinfo",.value="20 1 0:20 /parent /narrow rw - cgroup2 cgroup rw\n21 1 0:20 / /control\\040group rw - cgroup2 cgroup rw\n"},
    .{.path="/control group/parent/child/memory.max",.value="8589934592\n"},
    .{.path="/control group/parent/child/memory.high",.value="max\n"},
    .{.path="/control group/parent/child/memory.current",.value="1073741824\n"},
    .{.path="/control group/parent/child/cpu.max",.value="200000 100000\n"},
    .{.path="/control group/parent/memory.max",.value="17179869184\n"},
    .{.path="/control group/parent/memory.current",.value="16106127360\n"},
    .{.path="/control group/parent/cpu.max",.value="150000 100000\n"},
    .{.path="/control group/cpu.max",.value="max 100000\n"},
};
var scratch:[6][65536]u8 align(16)=undefined;
fn buffers() resources.Buffers {
    return .{.file=&scratch[0],.mounts=&scratch[1],.member=&scratch[2],.root=&scratch[3],.mount=&scratch[4],.path=&scratch[5]};
}
fn parsers() !void {
    try check(try facts.macAvailableBytes(10,3,100,2,4096,4096)==107*4096);
    try check(try facts.macAvailableBytes(10,3,0,2,4096,0)==13*4096);
    try check(try facts.macAvailableBytes(10,3,100,200,4096,0)==13*4096);
    try rejected(error.InvalidObservation,facts.macAvailableBytes(1,1,1,0,0,0));
    try rejected(error.ArithmeticOverflow,facts.macAvailableBytes(std.math.maxInt(u64),0,0,0,4096,0));
    try check(try facts.cpuCount("0-127,256-383\n")==256);
    try check(try facts.cpuCount("0-1000000")==1000001);
    for([_] []const u8{"","-1","0-","2-1","0,0","0-2,1-3","1,,3","4294967296","1-2-3"}) |bad| try rejected(error.InvalidObservation,facts.cpuCount(bad));
    try rejected(error.ArithmeticOverflow,facts.cpuCount("0-4294967295"));
    try rejected(error.ArithmeticOverflow,facts.number("18446744073709551616"));
    try rejected(error.InvalidObservation,facts.number("+1"));
    try check((try facts.quota("max 100000"))==null);
    try check(try (try facts.quota("100001 100000")).?.milli()==1001);
    try rejected(error.InvalidObservation,facts.quota("1 0"));
    try rejected(error.InvalidObservation,facts.quota("0 100000"));
    try rejected(error.InvalidObservation,facts.quota("1 2 trailing"));
    try rejected(error.InvalidObservation,facts.kilobytes("X: 12 MB\n","X"));
    try rejected(error.InvalidObservation,facts.field("X: 1\nX: 2\n","X"));
    var path:[128]u8=undefined;
    try check(std.mem.eql(u8,try facts.mountPath("/a\\040b\\134c",&path),"/a b\\c"));
    for([_] []const u8{"relative","/a/../b","/a/./b","/a//b","/a/","/\\999"}) |bad| try rejected(error.InvalidPath,facts.mountPath(bad,&path));
    try check(facts.within("/parent/child","/parent") and !facts.within("/parented","/parent"));
    var random:u64=18;
    for(0..10000) |_| {
        random=random*%6364136223846793005+%1;
        const count=1+random%1000000;
        var text:[80]u8=undefined;
        const value=try std.fmt.bufPrint(&text,"0-{d}",.{count-1});
        try check(try facts.cpuCount(value)==count);
        var scopes:facts.Scopes=.{};
        const a=1+random%1000000000;const b=1+(random>>19)%1000000000;
        const used_a=random%a;const used_b=(random>>9)%b;
        scopes.memory(a,used_a);scopes.memory(b,used_b);
        try check(scopes.capacity.?==@min(a,b));
        try check(scopes.capacity.?-scopes.used().?==@min(a-used_a,b-used_b));
    }
}
fn fixtures() !void {
    var fixture:Fixture=.{.entries=&entries};
    const source:resources.Source=.{.context=&fixture,.read=Fixture.read};
    const found=try resources.collectLinux(source,buffers(),2*1024*1024);
    try check(found.machine.usable_cpus==256 and found.machine.cpu_quota_milli.?==1500);
    try check(found.machine.physical_total==64*1024*1024*1024 and found.machine.process_resident==1024*1024);
    try check(found.machine.available_commit.?==64*1024*1024*1024);
    try check(found.machine.scope_limit.?==8*1024*1024*1024 and found.machine.scope_used.?==7*1024*1024*1024);
    try check(found.visible_scope_levels==3);
    const planned=try budget.plan(found.machine,.{});
    try check(planned.cpu_workers==2 and planned.process_bytes==513*1024*1024);
    fixture.denied="/control group/parent/memory.max";
    try rejected(error.ProbeFailed,resources.collectLinux(source,buffers(),0));fixture.denied=null;
    fixture.migrate=true;fixture.group_reads=0;
    try rejected(error.ChangedDuringProbe,resources.collectLinux(source,buffers(),0));fixture.migrate=false;
    var alias=buffers();alias.path=alias.member;
    try rejected(error.InvalidObservation,resources.collectLinux(source,alias,0));
    var tiny=buffers();tiny.file=tiny.file[0..16];
    try rejected(error.BufferTooSmall,resources.collectLinux(source,tiny,0));
    var mutable=entries;
    fixture.entries=&mutable;
    mutable[3].value="2:memory:/legacy\n";
    try rejected(error.UnsupportedControlGroupVersion,resources.collectLinux(source,buffers(),0));
    mutable[3]=entries[3];mutable[10].value="18000000000\n";
    const pressure=try resources.collectLinux(source,buffers(),0);
    try check(pressure.machine.scope_used.?==pressure.machine.scope_limit.?);
}
fn cpuSets() !void {
    var records:[256*32]u8=@splat(0);
    for(0..256) |index| {
        const record=records[index*32..][0..32];
        std.mem.writeInt(u32,record[0..4],32,.little);
        std.mem.writeInt(u32,record[8..12],@intCast(1000+index),.little);
        std.mem.writeInt(u16,record[12..14],@intCast(index/64),.little);
        record[14]=@intCast(index%64);record[15]=@intCast((index%64)/2);
    }
    const all=try facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3}});
    try check(all.logical==256 and all.cores==128 and all.numa_localities==4);
    const limited=try facts.windowsCpuSets(&records,.{.groups=&.{3},.single_group_mask=0b10101});
    try check(limited.logical==3 and limited.cores==3 and limited.numa_localities==1);
    const selected=try facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3},.defaults=&.{1001,1065,1199}});
    try check(selected.logical==3 and selected.cores==3 and selected.numa_localities==3);
    const job=try facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3},.group_masks=&.{.{.group=1,.mask=3},.{.group=3,.mask=1}}});
    try check(job.logical==3 and job.cores==2 and job.numa_localities==2);
    records[19]=2; // Reserved for another process, not usable by this process.
    try check((try facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3}})).logical==255);
    records[19]=6; // Allocated to the target process remains usable.
    try check((try facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3}})).logical==256);
    records[19]=1; // Parked is power policy, not a permanent capacity loss.
    try check((try facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3}})).logical==256);
    try rejected(error.InvalidObservation,facts.windowsCpuSets(records[0..records.len-1],.{.groups=&.{0,1,2,3}}));
    records[32+14]=0;
    try rejected(error.InvalidObservation,facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3}}));records[32+14]=1;
    std.mem.writeInt(u32,records[0..4],7,.little);
    try rejected(error.InvalidObservation,facts.windowsCpuSets(&records,.{.groups=&.{0,1,2,3}}));
}
const WindowsTest=struct {
    const Basic=extern struct {process_time:i64=0,job_time:i64=0,flags:u32=0,min_ws:usize=0,max_ws:usize=0,active:u32=0,affinity:usize=0,priority:u32=0,scheduling:u32=0};
    const Job=extern struct {basic:Basic=.{},io:[6]u64=@splat(0),process_memory:usize=0,job_memory:usize=0,peak_process:usize=0,peak_job:usize=0};
    extern "kernel32" fn CreateJobObjectW(?*anyopaque,?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SetInformationJobObject(*anyopaque,u32,*const anyopaque,u32) callconv(.winapi) c_int;
    extern "kernel32" fn AssignProcessToJobObject(*anyopaque,*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn GetProcessAffinityMask(*anyopaque,*usize,*usize) callconv(.winapi) c_int;
    extern "kernel32" fn SetProcessAffinityMask(*anyopaque,usize) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) c_int;
    fn constrained() !void {
        const process=GetCurrentProcess();var affinity:usize=0;var system:usize=0;
        if(GetProcessAffinityMask(process,&affinity,&system)==0 or affinity==0) return error.AffinityTestUnavailable;
        const first=affinity & (~affinity+%1);
        try check(SetProcessAffinityMask(process,first)!=0);
        defer _=SetProcessAffinityMask(process,affinity);
        const single=try resources.observe(buffers(),0);
        try check(single.machine.usable_cpus==1);
        const job=CreateJobObjectW(null,null) orelse return error.JobTestUnavailable;
        defer _=CloseHandle(job);
        var limits:Job=.{.basic=.{.flags=0x100},.process_memory=256*1024*1024};
        try check(@sizeOf(Job)==144);
        try check(SetInformationJobObject(job,9,&limits,@sizeOf(Job))!=0);
        try check(AssignProcessToJobObject(job,process)!=0);
        const restricted=try resources.observe(buffers(),0);
        const plan=try budget.plan(restricted.machine,.{});
        try check(restricted.immediate_job);
        try check(restricted.machine.available_commit.?<=256*1024*1024);
        try check(plan.process_bytes<=256*1024*1024);
        limits.basic.flags=0x300;limits.job_memory=192*1024*1024;
        try check(SetInformationJobObject(job,9,&limits,@sizeOf(Job))!=0);
        const job_restricted=try resources.observe(buffers(),0);
        try check(job_restricted.machine.scope_limit.?<=192*1024*1024);
        try check((try budget.plan(job_restricted.machine,.{})).process_bytes<=192*1024*1024);
    }
};
fn linuxConstraints() !void {
    const linux=std.os.linux;
    var saved:[65536]u8 align(16)=@splat(0);var one:[65536]u8 align(16)=@splat(0);
    const size=linux.syscall3(.sched_getaffinity,0,saved.len,@intFromPtr(&saved));
    try check(linux.errno(size)==.SUCCESS and size>0 and size<=saved.len);
    for(saved[0..size],0..) |byte,index| if(byte!=0) {one[index]=byte&(~byte+%1);break;};
    try check(linux.errno(linux.syscall3(.sched_setaffinity,0,size,@intFromPtr(&one)))==.SUCCESS);
    defer _=linux.syscall3(.sched_setaffinity,0,size,@intFromPtr(&saved));
    const single=try resources.observe(buffers(),0);
    try check(single.machine.usable_cpus==1);
    var original:linux.rlimit=undefined;
    try check(linux.errno(linux.prlimit(0,.AS,null,&original))==.SUCCESS);
    const new_limit:linux.rlimit=.{.cur=@min(original.cur,single.process_virtual_bytes+64*1024*1024),.max=original.max};
    try check(linux.errno(linux.prlimit(0,.AS,&new_limit,null))==.SUCCESS);
    defer _=linux.prlimit(0,.AS,&original,null);
    const restricted=try resources.observe(buffers(),0);
    try check(restricted.machine.available_address_space.?<=64*1024*1024);
    try check((try budget.plan(restricted.machine,.{})).process_bytes<=64*1024*1024);
}
pub fn main(init:std.process.Init) !void {
    try parsers();try fixtures();try cpuSets();
    if(builtin.os.tag==.linux or builtin.os.tag==.windows or builtin.os.tag==.macos) {
        const observed=try resources.observe(buffers(),0);
        const plan=try budget.plan(observed.machine,.{});
        try check(observed.machine.usable_cpus>0 and observed.machine.physical_total>0);
        try check(plan.process_bytes<=observed.machine.physical_total);
    }
    if(builtin.os.tag==.windows) try WindowsTest.constrained();
    if(builtin.os.tag==.linux) try linuxConstraints();
    var text:[200]u8=undefined;
    const message=try std.fmt.bufPrint(&text,"PASS native resource observations: {d} assertions; native={s}\n",.{assertions,@tagName(builtin.os.tag)});
    try std.Io.File.stdout().writeStreamingAll(init.io,message);
}
