//! Native observations into caller-owned scratch. No language allocator.
//! Linux cgroup/affinity parsing is also executable against injected file reads.
const std=@import("std");
const builtin=@import("builtin");
const facts=@import("resource_observation");
const budget=@import("resource_budget");
pub const Error=facts.Error || error{ProbeFailed,UnsupportedPlatform,UnsupportedControlGroupVersion,ChangedDuringProbe};
pub const Source=struct {
    context:?*anyopaque=null,
    /// null means ENOENT only. Permissions, I/O and truncated reads are errors.
    read:*const fn(?*anyopaque,[]const u8,[]u8) Error!?[]const u8,
    fn required(self:Source,path:[]const u8,output:[]u8) Error![]const u8 {
        return (try self.read(self.context,path,output)) orelse error.ProbeFailed;
    }
};
pub const Buffers=struct {
    file:[]u8,mounts:[]u8,member:[]u8,root:[]u8,mount:[]u8,path:[]u8,
    pub fn partition(bytes:[]u8) Error!Buffers {
        if(@intFromPtr(bytes.ptr)%16!=0) return error.InvalidObservation;
        const stride=std.mem.alignBackward(usize,bytes.len/6,16);
        if(stride==0) return error.BufferTooSmall;
        return .{.file=bytes[0..stride],.mounts=bytes[stride..2*stride],.member=bytes[2*stride..3*stride],
            .root=bytes[3*stride..4*stride],.mount=bytes[4*stride..5*stride],.path=bytes[5*stride..6*stride]};
    }
    fn validate(self:Buffers) Error!void {
        const spans=[_] []u8{self.file,self.mounts,self.member,self.root,self.mount,self.path};
        for(spans,0..) |a,index| {
            if(a.len==0) return error.BufferTooSmall;
            const end=@addWithOverflow(@intFromPtr(a.ptr),a.len);
            if(end[1]!=0) return error.InvalidObservation;
            for(spans[0..index]) |b| {
                const other=@addWithOverflow(@intFromPtr(b.ptr),b.len);
                if(other[1]!=0 or (@intFromPtr(a.ptr)<other[0] and @intFromPtr(b.ptr)<end[0])) return error.InvalidObservation;
            }
        }
    }
};
pub const Observation=struct {
    machine:budget.Machine,
    /// Only visible ancestors can be inspected in a cgroup namespace.
    visible_scope_levels:usize=0,
    mount_root_is_slash:bool=false,
    commit_source:enum{os,caller_owned,not_enforced}=.not_enforced,
    physical_cores:?u32=null,
    numa_localities:?u32=null,
    /// Windows exposes the immediate job, not a list of ancestor job handles.
    immediate_job:bool=false,
    available_kind:enum{os_estimate,free_and_file_cache}=.os_estimate,
    process_virtual_bytes:u64=0,
};
fn copy(input:[]const u8,output:[]u8) Error![]const u8 {
    if(input.len>output.len) return error.BufferTooSmall;
    @memcpy(output[0..input.len],input);return output[0..input.len];
}
fn membership(input:[]const u8) Error!?[]const u8 {
    var lines=std.mem.splitScalar(u8,input,'\n');var result:?[]const u8=null;
    while(lines.next()) |line| {
        if(line.len==0) continue;
        if(!std.mem.startsWith(u8,line,"0::")) return error.UnsupportedControlGroupVersion;
        if(result!=null) return error.InvalidObservation;
        const path=line[3..];try facts.absolutePath(path);result=path;
    }
    return result;
}
fn mountFor(input:[]const u8,member:[]const u8,b:Buffers) Error!struct{root:[]const u8,mount:[]const u8} {
    var lines=std.mem.splitScalar(u8,input,'\n');var best_root:usize=std.math.maxInt(usize);var mount_len:usize=0;
    while(lines.next()) |line| {
        const separator=std.mem.indexOf(u8,line," - ") orelse continue;
        var fs=std.mem.tokenizeScalar(u8,line[separator+3..],' ');
        if(!std.mem.eql(u8,fs.next() orelse continue,"cgroup2")) continue;
        var fields=std.mem.tokenizeScalar(u8,line[0..separator],' ');
        _=fields.next() orelse return error.InvalidObservation;
        _=fields.next() orelse return error.InvalidObservation;
        _=fields.next() orelse return error.InvalidObservation;
        const encoded_root=fields.next() orelse return error.InvalidObservation;
        const encoded_mount=fields.next() orelse return error.InvalidObservation;
        const root=try facts.mountPath(encoded_root,b.path);
        if(!facts.within(member,root) or root.len>=best_root) continue;
        _=try copy(root,b.root);best_root=root.len;
        const mount=try facts.mountPath(encoded_mount,b.path);
        mount_len=(try copy(mount,b.mount)).len;
    }
    if(best_root==std.math.maxInt(usize)) return error.ProbeFailed;
    return .{.root=b.root[0..best_root],.mount=b.mount[0..mount_len]};
}
fn directoryFile(source:Source,b:Buffers,directory:usize,name:[]const u8) Error!?[]const u8 {
    const slash:usize=if(directory==1 and b.path[0]=='/') 0 else 1;
    if(directory>b.path.len or slash+name.len>b.path.len-directory) return error.BufferTooSmall;
    if(slash!=0) b.path[directory]='/';
    @memcpy(b.path[directory+slash..][0..name.len],name);
    return source.read(source.context,b.path[0..directory+slash+name.len],b.file);
}
pub fn collectLinux(source:Source,b:Buffers,owned_commit_bytes:u64) Error!Observation {
    try b.validate();
    const status=try source.required("/proc/self/status",b.file);
    const cpus=try facts.cpuCount(try facts.field(status,"Cpus_allowed_list"));
    const resident=try facts.kilobytes(status,"VmRSS");
    const virtual=try facts.kilobytes(status,"VmSize");
    const mem=try source.required("/proc/meminfo",b.file);
    const total=try facts.kilobytes(mem,"MemTotal");
    const available=try facts.kilobytes(mem,"MemAvailable");
    const commit_limit=try facts.kilobytes(mem,"CommitLimit");
    const committed=try facts.kilobytes(mem,"Committed_AS");
    const mode=try facts.number(try source.required("/proc/sys/vm/overcommit_memory",b.file));
    if(mode>2 or total==0 or available>total or resident>total) return error.InvalidObservation;
    var observation:Observation=.{.machine=.{.usable_cpus=cpus,.physical_total=total,.available_physical=available,
        .process_resident=resident,.process_committed=owned_commit_bytes,
        .available_commit=if(mode==2) commit_limit -| committed else null},
        .commit_source=if(mode==2) .caller_owned else .not_enforced,.process_virtual_bytes=virtual};
    const group_data=try source.required("/proc/self/cgroup",b.file);
    const group=try membership(group_data) orelse return observation;
    const member=try copy(group,b.member);
    const mounts=try source.required("/proc/self/mountinfo",b.mounts);
    const location=try mountFor(mounts,member,b);
    const suffix=if(location.root.len==1) member[1..] else std.mem.trimStart(u8,member[location.root.len..],"/");
    var directory=(try copy(location.mount,b.path)).len;
    if(suffix.len!=0) {
        const slash:usize=if(directory==1) 0 else 1;
        if(slash+suffix.len>b.path.len-directory) return error.BufferTooSmall;
        if(slash!=0) b.path[directory]='/';
        @memcpy(b.path[directory+slash..][0..suffix.len],suffix);directory+=slash+suffix.len;
    }
    var scopes:facts.Scopes=.{};
    while(true) {
        observation.visible_scope_levels+=1;
        var memory_limit:?u64=null;
        if(try directoryFile(source,b,directory,"memory.max")) |value| memory_limit=try facts.limit(value);
        // memory.high is a throttle boundary: avoid planning sustained resident
        // growth into reclaim pressure even when the hard maximum is larger.
        if(try directoryFile(source,b,directory,"memory.high")) |value| {
            if(try facts.limit(value)) |high| memory_limit=@min(memory_limit orelse high,high);
        }
        if(memory_limit) |maximum| {
            const current=(try directoryFile(source,b,directory,"memory.current")) orelse return error.ProbeFailed;
            scopes.memory(maximum,try facts.number(current));
        }
        if(try directoryFile(source,b,directory,"cpu.max")) |value| {
            if(try facts.quota(value)) |quota| scopes.cpuQuota(quota);
        }
        if(directory==location.mount.len) break;
        const slash=std.mem.lastIndexOfScalar(u8,b.path[0..directory],'/') orelse return error.InvalidPath;
        directory=@max(location.mount.len,slash);
    }
    // Migration during observation must be retried, never silently combined.
    const final_group=try membership(try source.required("/proc/self/cgroup",b.file)) orelse return error.ChangedDuringProbe;
    if(!std.mem.eql(u8,member,final_group)) return error.ChangedDuringProbe;
    const final_status=try source.required("/proc/self/status",b.file);
    if(try facts.cpuCount(try facts.field(final_status,"Cpus_allowed_list"))!=cpus) return error.ChangedDuringProbe;
    observation.machine.scope_limit=scopes.capacity;observation.machine.scope_used=scopes.used();
    observation.machine.cpu_quota_milli=if(scopes.cpu) |quota| try quota.milli() else null;
    observation.mount_root_is_slash=std.mem.eql(u8,location.root,"/");
    return observation;
}
fn linuxRead(_: ?*anyopaque,path:[]const u8,output:[]u8) Error!?[]const u8 {
    const linux=std.os.linux;
    // Linux pathname syscall limit, not a database/machine capacity setting.
    var terminated:[4096]u8=undefined;
    if(path.len>=terminated.len or std.mem.indexOfScalar(u8,path,0)!=null) return error.InvalidPath;
    @memcpy(terminated[0..path.len],path);terminated[path.len]=0;
    const opened=linux.openat(linux.AT.FDCWD,@ptrCast(&terminated),.{.ACCMODE=.RDONLY,.CLOEXEC=true},0);
    switch(linux.errno(opened)) {.SUCCESS=>{},.NOENT=>return null,else=>return error.ProbeFailed}
    const fd:linux.fd_t=@intCast(opened);defer _=linux.close(fd);
    var used:usize=0;
    while(true) {
        var extra:[1]u8=undefined;
        const target=if(used==output.len) &extra else output[used..];
        const count=linux.read(fd,target.ptr,target.len);
        switch(linux.errno(count)) {.SUCCESS=>{},.INTR=>continue,else=>return error.ProbeFailed}
        if(count==0) return output[0..used];
        if(used==output.len) return error.BufferTooSmall;
        used+=count;
    }
}
pub fn observe(b:Buffers,owned_commit_bytes:u64) Error!Observation {
    if(builtin.os.tag==.linux) {
        var result=try collectLinux(.{.read=linuxRead},b,owned_commit_bytes);
        var limits:std.os.linux.rlimit=undefined;
        if(std.os.linux.errno(std.os.linux.prlimit(0,.AS,null,&limits))!=.SUCCESS) return error.ProbeFailed;
        if(limits.cur!=std.os.linux.RLIM.INFINITY) result.machine.available_address_space=limits.cur -| result.process_virtual_bytes;
        return result;
    }
    if(builtin.os.tag==.windows) return observeWindows(b);
    if(builtin.os.tag==.macos) return observeMac(b,owned_commit_bytes);
    return error.UnsupportedPlatform;
}
const Mac=struct {
    extern "c" fn sysctlbyname([*:0]const u8,?*anyopaque,?*usize,?*anyopaque,usize) c_int;
    extern "c" fn mach_host_self() u32;
    extern "c" fn host_statistics64(u32,c_int,*anyopaque,*u32) c_int;
    extern "c" fn mach_port_deallocate(u32,u32) c_int;
    extern "c" fn os_proc_available_memory() usize;
    fn scalar(comptime T:type,name:[*:0]const u8) Error!T {
        var value:T=0;var size:usize=@sizeOf(T);
        if(sysctlbyname(name,&value,&size,null,0)!=0 or size!=@sizeOf(T)) return error.ProbeFailed;
        return value;
    }
};
fn observeMac(b:Buffers,owned_commit_bytes:u64) Error!Observation {
    try b.validate();
    const total=try Mac.scalar(u64,"hw.memsize");
    const cpus=try Mac.scalar(u32,"hw.logicalcpu");
    const cores=try Mac.scalar(u32,"hw.physicalcpu");
    const page_size=try Mac.scalar(u32,"hw.pagesize");
    const task=std.c.mach_task_self();
    if(task==0 or total==0 or cpus==0 or page_size==0) return error.InvalidObservation;
    const host=Mac.mach_host_self();if(host==0) return error.ProbeFailed;
    defer _=Mac.mach_port_deallocate(task,host);
    // HOST_VM_INFO64 revision 1, expressed in 32-bit natural_t units. Request
    // the file-backed counters: free/purgeable alone excludes reclaimable cache
    // and can incorrectly starve a database on an otherwise idle machine.
    var vm:extern struct {free:u32=0,active:u32=0,inactive:u32=0,wired:u32=0,counters:[9]u64=@splat(0),purgeable:u32=0,speculative:u32=0,
        decompressions:u64=0,compressions:u64=0,swapins:u64=0,swapouts:u64=0,compressor:u32=0,throttled:u32=0,external:u32=0,internal:u32=0,uncompressed:u64=0}=.{};
    var vm_count:u32=@sizeOf(@TypeOf(vm))/4;
    if(Mac.host_statistics64(host,4,&vm,&vm_count)!=0 or vm_count<@sizeOf(@TypeOf(vm))/4) return error.ProbeFailed;
    var process:std.c.task_vm_info_data_t=std.mem.zeroes(std.c.task_vm_info_data_t);
    var process_count=std.c.TASK.VM.INFO_COUNT;
    if(std.c.task_info(task,std.c.TASK.VM.INFO,@ptrCast(&process),&process_count)!=0 or
        process_count*4<@offsetOf(std.c.task_vm_info_data_t,"resident_size")+8) return error.ProbeFailed;
    const own_external=if(process_count*4>=@offsetOf(std.c.task_vm_info_data_t,"external")+8) process.external else 0;
    const available_bytes=try facts.macAvailableBytes(vm.free,vm.purgeable,vm.external,vm.speculative,page_size,own_external);
    var result:Observation=.{.machine=.{.usable_cpus=cpus,.physical_total=total,.available_physical=@min(total,available_bytes),
        .process_resident=process.resident_size,.process_committed=owned_commit_bytes},
        .physical_cores=cores,.available_kind=.free_and_file_cache,.process_virtual_bytes=process.virtual_size};
    const app_available=Mac.os_proc_available_memory();
    if(app_available!=0) {
        const owned=if(process_count*4>=@offsetOf(std.c.task_vm_info_data_t,"phys_footprint")+8) process.phys_footprint else process.resident_size;
        const ceiling=@addWithOverflow(owned,app_available);if(ceiling[1]!=0) return error.ArithmeticOverflow;
        result.machine.scope_limit=ceiling[0];result.machine.scope_used=owned;
    }
    return result;
}
const Win=struct {
    const Memory=extern struct {length:u32=@sizeOf(Memory),load:u32=0,total:u64=0,available:u64=0,total_page:u64=0,available_page:u64=0,total_virtual:u64=0,available_virtual:u64=0,extended:u64=0};
    const App=extern struct {available:u64=0,private:u64=0,peak:u64=0,total:u64=0};
    const Process=extern struct {size:u32=@sizeOf(Process),faults:u32=0,peak_ws:usize=0,ws:usize=0,peak_paged:usize=0,paged:usize=0,peak_nonpaged:usize=0,nonpaged:usize=0,pagefile:usize=0,peak_pagefile:usize=0,private:usize=0};
    const Basic=extern struct {process_time:i64=0,job_time:i64=0,flags:u32=0,min_ws:usize=0,max_ws:usize=0,active:u32=0,affinity:usize=0,priority:u32=0,scheduling:u32=0};
    const Job=extern struct {basic:Basic=.{},io:[6]u64=@splat(0),process_memory:usize=0,job_memory:usize=0,peak_process:usize=0,peak_job:usize=0};
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GlobalMemoryStatusEx(*Memory) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessInformation(*anyopaque,u32,*anyopaque,u32) callconv(.winapi) c_int;
    extern "kernel32" fn K32GetProcessMemoryInfo(*anyopaque,*Process,u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessGroupAffinity(*anyopaque,*u16,[*]u16) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessAffinityMask(*anyopaque,*usize,*usize) callconv(.winapi) c_int;
    extern "kernel32" fn GetSystemCpuSetInformation(?*anyopaque,u32,*u32,*anyopaque,u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessDefaultCpuSets(*anyopaque,?[*]u32,u32,*u32) callconv(.winapi) c_int;
    extern "kernel32" fn IsProcessInJob(*anyopaque,?*anyopaque,*c_int) callconv(.winapi) c_int;
    extern "kernel32" fn QueryInformationJobObject(?*anyopaque,u32,*anyopaque,u32,?*u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetActiveProcessorCount(u16) callconv(.winapi) u32;
};
fn winError() Error {
    return if(Win.GetLastError()==122) error.BufferTooSmall else error.ProbeFailed;
}
fn observeWindows(b:Buffers) Error!Observation {
    try b.validate();
    if(@sizeOf(usize)!=8) return error.UnsupportedPlatform;
    if(@intFromPtr(b.file.ptr)%8!=0 or @intFromPtr(b.root.ptr)%8!=0 or @intFromPtr(b.mounts.ptr)%4!=0 or @intFromPtr(b.member.ptr)%2!=0) return error.InvalidObservation;
    const process=Win.GetCurrentProcess();
    var memory:Win.Memory=.{};var app:Win.App=.{};var counters:Win.Process=.{};
    if(Win.GlobalMemoryStatusEx(&memory)==0 or Win.GetProcessInformation(process,2,&app,@sizeOf(Win.App))==0 or
        Win.K32GetProcessMemoryInfo(process,&counters,@sizeOf(Win.Process))==0) return error.ProbeFailed;
    if(memory.total==0 or memory.available>memory.total or counters.ws>memory.total) return error.InvalidObservation;
    var group_count:u16=@intCast(@min(b.member.len/2,std.math.maxInt(u16)));
    if(group_count==0) return error.BufferTooSmall;
    const groups:[*]u16=@ptrCast(@alignCast(b.member.ptr));
    if(Win.GetProcessGroupAffinity(process,&group_count,groups)==0) return winError();
    var cpu_bytes:u32=0;
    if(Win.GetSystemCpuSetInformation(b.file.ptr,@intCast(@min(b.file.len,std.math.maxInt(u32))),&cpu_bytes,process,0)==0) return winError();
    if(cpu_bytes>b.file.len) return error.ProbeFailed;
    var default_count:u32=0;
    const defaults:[*]u32=@ptrCast(@alignCast(b.mounts.ptr));
    if(Win.GetProcessDefaultCpuSets(process,defaults,@intCast(@min(b.mounts.len/4,std.math.maxInt(u32))),&default_count)==0) return winError();
    if(default_count>b.mounts.len/4 or group_count>b.member.len/2) return error.ProbeFailed;
    var process_mask:usize=0;var system_mask:usize=0;
    if(group_count==1 and Win.GetProcessAffinityMask(process,&process_mask,&system_mask)==0) return error.ProbeFailed;
    var in_job:c_int=0;
    if(Win.IsProcessInJob(process,null,&in_job)==0) return error.ProbeFailed;
    var job_mask_bytes:u32=0;
    if(in_job!=0 and Win.QueryInformationJobObject(null,14,b.root.ptr,@intCast(@min(b.root.len,std.math.maxInt(u32))),&job_mask_bytes)==0) return winError();
    if(job_mask_bytes>b.root.len or job_mask_bytes%@sizeOf(facts.GroupMask)!=0) return error.InvalidObservation;
    const job_masks:[*]const facts.GroupMask=@ptrCast(@alignCast(b.root.ptr));
    const job_affinity=job_masks[0..job_mask_bytes/@sizeOf(facts.GroupMask)];
    const topology=try facts.windowsCpuSets(b.file[0..cpu_bytes],.{.groups=groups[0..group_count],.defaults=defaults[0..default_count],
        .single_group_mask=if(group_count==1) process_mask else null,.group_masks=job_affinity});
    const commit_ceiling=@addWithOverflow(app.total,app.available);if(commit_ceiling[1]!=0) return error.ArithmeticOverflow;
    var observation:Observation=.{.machine=.{.usable_cpus=topology.logical,.physical_total=memory.total,.available_physical=memory.available,
        .process_resident=counters.ws,.process_committed=app.total,.available_commit=app.available,
        .available_address_space=memory.available_virtual,
        .scope_limit=commit_ceiling[0],.scope_used=app.total},.commit_source=.os,.physical_cores=topology.cores,.numa_localities=topology.numa_localities};
    if(in_job!=0) {
        observation.immediate_job=true;
        var job:Win.Job=.{};
        if(Win.QueryInformationJobObject(null,9,&job,@sizeOf(Win.Job),null)==0) return error.ProbeFailed;
        var scopes:facts.Scopes=.{};
        scopes.memory(commit_ceiling[0],app.total);
        if(job.basic.flags&0x100!=0) scopes.memory(job.process_memory,app.private);
        if(job.basic.flags&0x200!=0) {
            // Same current-usage query as Microsoft's HCS container shim.
            // Notification/violation snapshots and peaks are not current usage.
            var usage:extern struct{current:u64=0,peak:u64=0}=.{};
            if(Win.QueryInformationJobObject(null,28,&usage,@sizeOf(@TypeOf(usage)),null)==0) return error.ProbeFailed;
            scopes.memory(job.job_memory,usage.current);
        }
        observation.machine.scope_limit=scopes.capacity;observation.machine.scope_used=scopes.used();
        observation.machine.available_commit=@min(app.available,scopes.available.?);
        var rate:extern struct{flags:u32=0,value:u32=0}=.{};
        if(Win.QueryInformationJobObject(null,15,&rate,@sizeOf(@TypeOf(rate)),null)==0) return error.ProbeFailed;
        if(rate.flags&1!=0 and rate.flags&2==0) {
            const cap=if(rate.flags&16!=0) rate.value>>16 else if(rate.flags&4!=0) rate.value else 10000;
            if(cap==0 or cap>10000) return error.InvalidObservation;
            var active:u64=Win.GetActiveProcessorCount(0xffff);
            if(job_affinity.len!=0) {active=0;for(job_affinity) |mask| active+=@popCount(mask.mask);}
            if(active==0) return error.ProbeFailed;
            observation.machine.cpu_quota_milli=(@as(u64,active)*cap+9)/10;
        }
    }
    return observation;
}
