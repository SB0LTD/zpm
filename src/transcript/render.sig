//! A derived human-readable view. Raw segment text is copied byte-for-byte;
//! timestamp framing does not create word alignment or speaker identities.
const std = @import("std");
const t = @import("root.sig");
pub fn segment(value: t.Segment, output: []u8) t.Error![]const u8 {
    try value.validate();
    var pos: usize = 0;
    try t.append(output, &pos, "[");
    try time(value.start_ms, output, &pos);
    try t.append(output, &pos, " - ");
    try time(value.end_ms, output, &pos);
    try t.append(output, &pos, "]\n");
    try t.append(output, &pos, value.text);
    try t.append(output, &pos, "\n\n");
    return output[0..pos];
}
fn time(ms: u64, output: []u8, position: *usize) t.Error!void {
    var buffer: [64]u8 = undefined;
    const seconds = ms / 1000;
    const value = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
        .{ seconds / 3600, seconds / 60 % 60, seconds % 60, ms % 1000 }) catch return error.Capacity;
    try t.append(output, position, value);
}
test "readable transcript preserves text and precise segment bounds" {
    var buffer: [256]u8 = undefined;
    const value: t.Segment = .{ .id = 0, .start_ms = 299999, .end_ms = 3600001, .text = " שלום\nעולם?" };
    try std.testing.expectEqualStrings("[00:04:59.999 - 01:00:00.001]\n שלום\nעולם?\n\n", try segment(value, &buffer));
    try std.testing.expectError(error.Capacity, segment(value, buffer[0..5]));
}
