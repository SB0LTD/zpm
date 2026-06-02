const std = @import("std");

// Test various repetition patterns for 0.17 compatibility
// In Zig 0.17, use @splat for scalar fills, explicit init for structs
const a: [8]u8 = @splat(0);
const b: [4]bool = @splat(false);

const Foo = struct { x: u8 = 0 };
const c: [3]Foo = @splat(Foo{});
const d: [8]u8 = @splat(0);

test "syntax" {
    try std.testing.expect(a[0] == 0);
    try std.testing.expect(!b[0]);
    try std.testing.expect(c[0].x == 0);
    try std.testing.expect(d[7] == 0);
}
