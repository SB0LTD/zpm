const std = @import("std");
const date_format = @import("date_format");
const dimension_group = @import("dimension_group");
const grouping_rollup = @import("grouping_rollup");
const date_storage = @import("date_storage");

pub fn main(init: std.process.Init) !void {
    try date_format.main();
    try dimension_group.main();
    try grouping_rollup.main();
    try date_storage.main(init);
}
