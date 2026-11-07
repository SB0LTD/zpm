//! Immutable frame-of-reference integer columns in caller-owned byte spans.
//! Persistent little-endian format; NULLs and exact i128 SUM are preserved.
//! This is a storage primitive, not a SQL engine or a machine capacity claim.
const std=@import("std");
pub const header_bytes=80;
const magic="ZPMI0001";
pub const Error=error{ InvalidNullMask, OutputTooSmall, ArithmeticOverflow, AliasedStorage, InvalidFrame, RowOutOfBounds };
pub const Summary=struct { rows:u64, nonnull:u64, sum:?i128 };
pub const View=struct {
    frame:[]const u8,
    rows:u64,
    nonnull:u64,
    base:i64,
    bits:u8,
    flags:u8,
    total:i128,
    nulls:[]const u8,
    data:[]const u8,

    fn isNull(self:View,row:u64) bool {
        if(self.flags==2) return true;
        return self.nulls.len!=0 and (self.nulls[@intCast(row/8)] & (@as(u8,1)<<@as(u3,@intCast(row%8))))!=0;
    }
    fn delta(self:View,row:u64) u64 {
        if(self.bits==0) return 0;
        const bit=@as(u128,row)*self.bits;
        const first:usize=@intCast(bit/8);
        const remaining=self.data.len-first;
        var word:u128=0;
        if(remaining>=8) {
            word=std.mem.readInt(u64,self.data[first..][0..8],.little);
            if(remaining>=9) word|=@as(u128,self.data[first+8])<<64;
        } else {
            for(0..remaining) |index| { word|=@as(u128,self.data[first+index])<<@as(u7,@intCast(index*8)); }
        }
        const mask:u128=(@as(u128,1)<<@as(u7,@intCast(self.bits)))-1;
        return @intCast((word>>@as(u7,@intCast(bit%8)))&mask);
    }
    fn decoded(self:View,row:u64) i64 { return @bitCast(@as(u64,@bitCast(self.base))+%self.delta(row)); }
    pub fn value(self:View,row:u64) Error!?i64 {
        if(row>=self.rows) return error.RowOutOfBounds;
        if(self.isNull(row)) return null;
        return self.decoded(row);
    }
    /// The exact summary is computed during encoding and verified on parsing.
    /// It is immutable metadata, not a query-specific result/cache shortcut.
    pub fn summary(self:View) Summary { return .{.rows=self.rows,.nonnull=self.nonnull,.sum=if(self.nonnull==0) null else self.total}; }
};

fn bitmapBytes(rows:u64) u64 { return rows/8+@intFromBool(rows%8!=0); }
fn layout(rows:u64,bits:u8,flags:u8) Error!struct{nulls:usize,data:usize,total:usize} {
    const nulls:u128=if(flags==1) bitmapBytes(rows) else 0;
    const data=(@as(u128,rows)*bits+7)/8;
    const total=header_bytes+nulls+data;
    if(total>std.math.maxInt(usize)) return error.ArithmeticOverflow;
    return .{.nulls=@intCast(nulls),.data=@intCast(data),.total=@intCast(total)};
}
fn inputNull(mask:?[]const u8,row:usize) bool {
    return if(mask) |bytes| (bytes[row/8]&(@as(u8,1)<<@as(u3,@intCast(row%8))))!=0 else false;
}
fn overlaps(a:[]const u8,b:[]const u8) bool {
    if(a.len==0 or b.len==0) return false;
    // Real borrowed spans must be addressable; checked bounds also reject
    // fabricated wrapped ranges before any output byte is touched.
    const ae=@addWithOverflow(@intFromPtr(a.ptr),a.len);
    const be=@addWithOverflow(@intFromPtr(b.ptr),b.len);
    return ae[1]!=0 or be[1]!=0 or (@intFromPtr(a.ptr)<be[0] and @intFromPtr(b.ptr)<ae[0]);
}
fn checksum(frame:[]const u8) u64 {
    var hash=std.hash.Wyhash.init(0);
    hash.update(frame[0..72]);hash.update(frame[header_bytes..]);
    return hash.final();
}
fn makeView(frame:[]const u8,shape:anytype) View {
    return .{.frame=frame,.rows=std.mem.readInt(u64,frame[16..24],.little),
        .nonnull=std.mem.readInt(u64,frame[48..56],.little),.base=std.mem.readInt(i64,frame[24..32],.little),
        .bits=frame[11],.flags=frame[10],.total=std.mem.readInt(i128,frame[56..72],.little),
        .nulls=frame[header_bytes..][0..shape.nulls],.data=frame[header_bytes+shape.nulls..]};
}

/// Output remains untouched on validation/capacity/alias errors. The source
/// values/mask must be immutable for this call. NULL value slots need not be read.
/// The returned view borrows output, which must remain immutable and owned.
pub fn encode(values:[]const i64,null_mask:?[]const u8,output:[]u8) Error!View {
    const rows:u64=@intCast(values.len);
    const mask_bytes=bitmapBytes(rows);
    if(null_mask) |mask| if(mask.len<mask_bytes) return error.InvalidNullMask;
    var nonnull:u64=0;var low:i64=0;var high:i64=0;var total:i128=0;
    for(values,0..) |_,index| {
        if(inputNull(null_mask,index)) continue;
        const value=values[index];
        if(nonnull==0) {low=value;high=value;} else {low=@min(low,value);high=@max(high,value);}
        nonnull+=1;total+=value;
    }
    const span=@as(u64,@bitCast(high))-%@as(u64,@bitCast(low));
    const bits:u8=if(nonnull==0 or span==0) 0 else @intCast(64-@clz(span));
    const flags:u8=if(rows!=0 and nonnull==0) 2 else if(nonnull<rows) 1 else 0;
    const shape=try layout(rows,bits,flags);
    if(output.len<shape.total) return error.OutputTooSmall;
    if(overlaps(std.mem.sliceAsBytes(values),output) or (null_mask!=null and overlaps(null_mask.?,output))) return error.AliasedStorage;
    const frame=output[0..shape.total];
    @memset(frame[0..header_bytes],0);@memcpy(frame[0..8],magic);
    std.mem.writeInt(u16,frame[8..10],1,.little);frame[10]=flags;frame[11]=bits;
    std.mem.writeInt(u64,frame[16..24],rows,.little);
    std.mem.writeInt(i64,frame[24..32],low,.little);
    std.mem.writeInt(u64,frame[32..40],@intCast(shape.nulls),.little);
    std.mem.writeInt(u64,frame[40..48],@intCast(shape.data),.little);
    std.mem.writeInt(u64,frame[48..56],nonnull,.little);
    std.mem.writeInt(i128,frame[56..72],total,.little);
    if(shape.nulls!=0) {
        const destination=frame[header_bytes..][0..shape.nulls];
        @memcpy(destination,null_mask.?[0..shape.nulls]);
        if(rows%8!=0) destination[destination.len-1]&=(@as(u8,1)<<@as(u3,@intCast(rows%8)))-1;
    }
    const data=frame[header_bytes+shape.nulls..];
    if(bits!=0) {
        var accumulator:u128=0;var filled:u8=0;var used:usize=0;
        for(0..values.len) |index| {
            const delta:u64=if(inputNull(null_mask,index)) 0 else @as(u64,@bitCast(values[index]))-%@as(u64,@bitCast(low));
            accumulator|=@as(u128,delta)<<@as(u7,@intCast(filled));filled+=bits;
            if(filled>=64) {
                std.mem.writeInt(u64,data[used..][0..8],@truncate(accumulator),.little);
                used+=8;accumulator>>=64;filled-=64;
            }
        }
        while(filled!=0) {
            data[used]=@truncate(accumulator);used+=1;accumulator>>=8;
            filled=if(filled>8) filled-8 else 0;
        }
    }
    std.mem.writeInt(u64,frame[72..80],checksum(frame),.little);
    return makeView(frame,shape);
}

/// Validate framing, integrity, canonical NULL payloads and the exact summary.
/// The checksum detects corruption; it is not cryptographic authentication.
pub fn parse(frame:[]const u8) Error!View {
    if(frame.len<header_bytes or !std.mem.eql(u8,frame[0..8],magic) or
        std.mem.readInt(u16,frame[8..10],.little)!=1 or frame[10]>2 or frame[11]>64 or
        std.mem.readInt(u32,frame[12..16],.little)!=0) return error.InvalidFrame;
    const rows=std.mem.readInt(u64,frame[16..24],.little);
    const shape=layout(rows,frame[11],frame[10]) catch return error.InvalidFrame;
    if(frame.len!=shape.total or std.mem.readInt(u64,frame[32..40],.little)!=shape.nulls or
        std.mem.readInt(u64,frame[40..48],.little)!=shape.data or
        std.mem.readInt(u64,frame[72..80],.little)!=checksum(frame)) return error.InvalidFrame;
    const view=makeView(frame,shape);
    if(view.nonnull>rows) return error.InvalidFrame;
    if(view.flags==2) {
        if(rows==0 or view.nonnull!=0 or view.base!=0 or view.bits!=0 or view.total!=0) return error.InvalidFrame;
    } else if(view.flags==0) {
        if(view.nonnull!=rows or (rows==0 and (view.base!=0 or view.bits!=0 or view.total!=0))) return error.InvalidFrame;
    } else {
        if(view.nonnull==0 or view.nonnull==rows) return error.InvalidFrame;
        if(rows%8!=0 and view.nulls[view.nulls.len-1]>>@as(u3,@intCast(rows%8))!=0) return error.InvalidFrame;
        var nulls:u64=0;for(view.nulls) |byte| nulls+=@popCount(byte);
        if(rows-nulls!=view.nonnull) return error.InvalidFrame;
    }
    const remainder:u3=@intCast((@as(u128,rows)*view.bits)%8);
    if(remainder!=0 and view.data[view.data.len-1]>>remainder!=0) return error.InvalidFrame;
    if(view.bits==0) {
        if(@as(i128,view.base)*@as(i128,view.nonnull)!=view.total) return error.InvalidFrame;
    } else {
        var total:i128=0;var row:u64=0;
        while(row<rows) : (row+=1) {
            if(view.isNull(row)) {if(view.delta(row)!=0) return error.InvalidFrame;continue;}
            const value=view.decoded(row);
            if(value<view.base) return error.InvalidFrame;
            total+=value;
        }
        if(total!=view.total) return error.InvalidFrame;
    }
    return view;
}
