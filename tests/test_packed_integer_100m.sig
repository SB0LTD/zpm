//! Explicit large physical-column qualification, not a RAMSQL SQL benchmark.
//! Every value is generated, encoded, parsed and checked; no synthetic row count.
const std=@import("std");
const column=@import("packed_integer");
const pages=@import("page_region");
const rows:usize=100_000_000;
const mask_bytes=(rows+7)/8;
const output_bytes=column.header_bytes+mask_bytes+(rows*27+7)/8;
fn check(ok:bool) !void { if(!ok) return error.LargeColumnContract; }
pub fn main(init:std.process.Init) !void {
    var source=try pages.reserve(rows*@sizeOf(i64));defer source.close();
    var encoded=try pages.reserve(output_bytes);defer encoded.close();
    var bitmap=try pages.reserve(mask_bytes);defer bitmap.close();
    const values=try source.view(i64,0,rows);
    for(values,0..) |*value,index| value.*=@as(i64,@intCast(index))-50_000_000;
    @memset(bitmap.bytes,0);
    var buffer:[1024]u8=undefined;
    for(0..2) |pass| {
        const nullable=pass==1;
        var expected_count:u64=0;var expected_sum:i128=0;
        for(values,0..) |value,index| {
            if(nullable and index%17==0) {
                bitmap.bytes[index/8]|=@as(u8,1)<<@as(u3,@intCast(index%8));
            } else {expected_count+=1;expected_sum+=value;}
        }
        const view=try column.encode(values,if(nullable) bitmap.bytes else null,encoded.bytes);
        try check(view.bits==27 and view.rows==rows);
        const parsed=try column.parse(view.frame);
        const summary=parsed.summary();
        try check(summary.nonnull==expected_count and summary.sum.?==expected_sum);
        var actual_count:u64=0;var actual_sum:i128=0;
        for(values,0..) |expected,index| {
            const actual=try parsed.value(index);
            if(nullable and index%17==0) try check(actual==null) else {
                try check(actual!=null and actual.?==expected);
                actual_count+=1;actual_sum+=actual.?;
            }
        }
        try check(actual_count==expected_count and actual_sum==expected_sum);
        const message=try std.fmt.bufPrint(&buffer,
            "{{\"scope\":\"physical_column_only\",\"rows\":{d},\"nullable\":{s},\"frame_bytes\":{d},\"nonnull\":{d},\"sum\":{d},\"checked_values\":{d},\"passed\":true}}\n",
            .{rows,if(nullable) "true" else "false",view.frame.len,actual_count,actual_sum,rows});
        try std.Io.File.stdout().writeStreamingAll(init.io,message);
    }
}
