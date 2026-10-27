//! Checked parsers for OS resource facts. No I/O, heap or machine-size ceiling.
const std=@import("std");
pub const Error=error{InvalidObservation,ArithmeticOverflow,BufferTooSmall,InvalidPath};
pub fn trim(input:[]const u8) []const u8 { return std.mem.trim(u8,input," \t\r\n"); }
pub fn number(input:[]const u8) Error!u64 {
    const value=trim(input);if(value.len==0) return error.InvalidObservation;
    var result:u64=0;
    for(value) |byte| {
        if(byte<'0' or byte>'9') return error.InvalidObservation;
        const product=@mulWithOverflow(result,10);
        const sum=@addWithOverflow(product[0],byte-'0');
        if(product[1]!=0 or sum[1]!=0) return error.ArithmeticOverflow;
        result=sum[0];
    }
    return result;
}
pub fn limit(input:[]const u8) Error!?u64 {
    return if(std.mem.eql(u8,trim(input),"max")) null else try number(input);
}
/// Sorted, disjoint Linux CPU lists; reject overlap rather than double count.
pub fn cpuCount(input:[]const u8) Error!u32 {
    var ranges=std.mem.splitScalar(u8,trim(input),',');
    var previous:?u64=null;var total:u64=0;
    while(ranges.next()) |range| {
        var parts=std.mem.splitScalar(u8,range,'-');
        const first=try number(parts.next().?);
        const last=if(parts.next()) |end| try number(end) else first;
        if(parts.next()!=null or first>last or last>std.math.maxInt(u32) or
            (previous!=null and first<=previous.?)) return error.InvalidObservation;
        total+=last-first+1;
        if(total>std.math.maxInt(u32)) return error.ArithmeticOverflow;
        previous=last;
    }
    if(total==0) return error.InvalidObservation;
    return @intCast(total);
}
pub fn field(input:[]const u8,key:[]const u8) Error![]const u8 {
    var lines=std.mem.splitScalar(u8,input,'\n');var result:?[]const u8=null;
    while(lines.next()) |line| {
        const colon=std.mem.indexOfScalar(u8,line,':') orelse continue;
        if(!std.mem.eql(u8,line[0..colon],key)) continue;
        if(result!=null) return error.InvalidObservation;
        result=trim(line[colon+1..]);
    }
    return result orelse error.InvalidObservation;
}
pub fn kilobytes(input:[]const u8,key:[]const u8) Error!u64 {
    var words=std.mem.tokenizeAny(u8,try field(input,key)," \t");
    const value=try number(words.next() orelse return error.InvalidObservation);
    if(!std.mem.eql(u8,words.next() orelse return error.InvalidObservation,"kB") or words.next()!=null) return error.InvalidObservation;
    const bytes=@mulWithOverflow(value,1024);if(bytes[1]!=0) return error.ArithmeticOverflow;
    return bytes[0];
}
pub const Quota=struct {
    amount:u64, period:u64,
    pub fn tighter(self:Quota,other:Quota) bool { return @as(u128,self.amount)*other.period<@as(u128,other.amount)*self.period; }
    pub fn milli(self:Quota) Error!u64 {
        const scaled=@as(u128,self.amount)*1000;
        const rounded=scaled/self.period+@intFromBool(scaled%self.period!=0);
        if(rounded>std.math.maxInt(u64)) return error.ArithmeticOverflow;
        return @intCast(rounded);
    }
};
pub fn quota(input:[]const u8) Error!?Quota {
    var words=std.mem.tokenizeAny(u8,trim(input)," \t");
    const amount=try limit(words.next() orelse return error.InvalidObservation);
    const period=try number(words.next() orelse return error.InvalidObservation);
    if(period==0 or words.next()!=null or (amount!=null and amount.?==0)) return error.InvalidObservation;
    return if(amount) |n| .{.amount=n,.period=period} else null;
}
/// Combine independently constrained ancestors without pairing one ancestor's
/// capacity with another's usage counter. The resulting pair is a conservative
/// effective constraint, not a claim of a single observed cgroup counter.
pub const Scopes=struct {
    capacity:?u64=null, available:?u64=null, cpu:?Quota=null,
    pub fn memory(self:*Scopes,capacity:u64,consumed:u64) void {
        self.capacity=@min(self.capacity orelse capacity,capacity);
        const available=capacity -| consumed;
        self.available=@min(self.available orelse available,available);
    }
    pub fn cpuQuota(self:*Scopes,value:Quota) void {
        if(self.cpu==null or value.tighter(self.cpu.?)) self.cpu=value;
    }
    pub fn used(self:Scopes) ?u64 {
        return if(self.capacity) |capacity| capacity-@min(capacity,self.available.?) else null;
    }
};
/// Decode the kernel mountinfo escapes only; reject ambiguous/malformed input.
pub fn mountPath(input:[]const u8,output:[]u8) Error![]const u8 {
    var used:usize=0;var index:usize=0;
    while(index<input.len) {
        var byte=input[index];index+=1;
        if(byte=='\\') {
            if(input.len-index<3) return error.InvalidPath;
            const escaped=input[index..][0..3];index+=3;
            byte=if(std.mem.eql(u8,escaped,"040")) ' ' else if(std.mem.eql(u8,escaped,"011")) '\t'
                else if(std.mem.eql(u8,escaped,"012")) '\n' else if(std.mem.eql(u8,escaped,"134")) '\\' else return error.InvalidPath;
        }
        if(byte==0) return error.InvalidPath;
        if(used==output.len) return error.BufferTooSmall;
        output[used]=byte;used+=1;
    }
    const result=output[0..used];try absolutePath(result);return result;
}
pub fn absolutePath(path:[]const u8) Error!void {
    if(path.len==0 or path[0]!='/' or std.mem.indexOfScalar(u8,path,0)!=null) return error.InvalidPath;
    var parts=std.mem.splitScalar(u8,path,'/');_ = parts.next();
    while(parts.next()) |part| {
        if(std.mem.eql(u8,part,".") or std.mem.eql(u8,part,"..") or (part.len==0 and path.len>1)) return error.InvalidPath;
    }
}
pub fn within(path:[]const u8,root:[]const u8) bool {
    return std.mem.eql(u8,root,"/") or (std.mem.startsWith(u8,path,root) and
        (path.len==root.len or path[root.len]=='/'));
}
/// Mach free pages already include speculative pages. File-backed cache can be
/// reclaimed without counting anonymous RAM or compressed/swap contents. Use
/// the larger cache/purgeable estimate, not their potentially overlapping sum,
/// and exclude the process's own external footprint from the added allowance.
pub fn macAvailableBytes(free:u64,purgeable:u64,external:u64,speculative:u64,page:u64,owned_external:u64) Error!u64 {
    if(page==0 or !std.math.isPowerOfTwo(page)) return error.InvalidObservation;
    const free_bytes=@mulWithOverflow(free,page);
    const reclaimable=@mulWithOverflow(@max(purgeable,external -| speculative),page);
    if(free_bytes[1]!=0 or reclaimable[1]!=0) return error.ArithmeticOverflow;
    const result=@addWithOverflow(free_bytes[0],reclaimable[0] -| owned_external);
    if(result[1]!=0) return error.ArithmeticOverflow;
    return result[0];
}
pub const GroupMask=extern struct {mask:u64,group:u16,reserved:[3]u16=@splat(0)};
pub const CpuFilter=struct {
    groups:[]const u16,
    defaults:[]const u32=&.{},
    single_group_mask:?u64=null,
    group_masks:[]const GroupMask=&.{},
};
fn cpuAllowed(record:[]const u8,filter:CpuFilter) bool {
    const group=std.mem.readInt(u16,record[12..14],.little);
    const id=std.mem.readInt(u32,record[8..12],.little);
    if(std.mem.indexOfScalar(u16,filter.groups,group)==null or (record[19]&2!=0 and record[19]&4==0)) return false;
    if(filter.defaults.len!=0 and std.mem.indexOfScalar(u32,filter.defaults,id)==null) return false;
    if(filter.group_masks.len!=0) {
        var permitted=false;
        for(filter.group_masks) |mask| if(mask.group==group and mask.mask&(@as(u64,1)<<@as(u6,@intCast(record[14])))!=0) {permitted=true;break;};
        if(!permitted) return false;
    }
    if(filter.single_group_mask) |mask| if(mask&(@as(u64,1)<<@as(u6,@intCast(record[14])))==0) return false;
    return true;
}
pub const CpuTopology=struct {logical:u32=0,cores:u32=0,numa_localities:u32=0};
/// Variable-size Windows CPU-set records. Unknown record types are skipped.
/// Processor/group/core indices are OS identities, not bounded array indices.
pub fn windowsCpuSets(bytes:[]const u8,filter:CpuFilter) Error!CpuTopology {
    if(filter.groups.len==0 or (filter.single_group_mask!=null and filter.groups.len!=1)) return error.InvalidObservation;
    var result:CpuTopology=.{};var position:usize=0;
    while(position<bytes.len) {
        if(bytes.len-position<8) return error.InvalidObservation;
        const size=std.mem.readInt(u32,bytes[position..][0..4],.little);
        if(size<8 or size>bytes.len-position) return error.InvalidObservation;
        const record=bytes[position..][0..size];
        position+=size;
        if(std.mem.readInt(u32,record[4..8],.little)!=0) continue;
        if(size<32 or record[14]>=64) return error.InvalidObservation;
        if(!cpuAllowed(record,filter)) continue;
        var core_seen=false;var locality_seen=false;var earlier:usize=0;
        while(earlier<position-size) {
            const previous_size=std.mem.readInt(u32,bytes[earlier..][0..4],.little);
            const previous=bytes[earlier..][0..previous_size];earlier+=previous_size;
            if(std.mem.readInt(u32,previous[4..8],.little)!=0 or !cpuAllowed(previous,filter)) continue;
            const same_group=std.mem.eql(u8,record[12..14],previous[12..14]);
            if(std.mem.eql(u8,record[8..12],previous[8..12]) or (same_group and record[14]==previous[14])) return error.InvalidObservation;
            core_seen=core_seen or (same_group and record[15]==previous[15]);
            locality_seen=locality_seen or (same_group and record[17]==previous[17]);
        }
        const next=@addWithOverflow(result.logical,1);if(next[1]!=0) return error.ArithmeticOverflow;
        result.logical=next[0];result.cores+=@intFromBool(!core_seen);result.numa_localities+=@intFromBool(!locality_seen);
    }
    if(result.logical==0) return error.InvalidObservation;
    return result;
}
