const std = @import("std");
const pages = @import("page_region");
fn check(ok: bool) !void { if (!ok) return error.PageRegionFailed; }
pub fn main() !void {
    var region = try pages.reserve(1024 * 1024);
    defer region.close();
    const words = try region.view(u64, 0, 1024);
    for (words, 0..) |*word, i| word.* = i;
    const tail = try region.view(u8, region.bytes.len - 1, 1);
    tail[0] = 197;
    try check(words[999] == 999 and region.bytes[region.bytes.len - 1] == 197);
    if (region.view(u64, 1, 1)) |_| return error.AlignmentAccepted else |err| try check(err == error.InvalidCapacity);
    if (region.view(u64, region.bytes.len - 4, 1)) |_| return error.OverflowAccepted else |err| try check(err == error.InvalidCapacity);
    if (region.view(u8, 1, ~@as(usize, 0))) |_| return error.OverflowAccepted else |err| try check(err == error.InvalidCapacity);
    region.close(); region.close();
    try check(region.bytes.len == 0);
    std.debug.print("page-region: mapping, bounds, alignment and idempotent release passed\n", .{});
}
