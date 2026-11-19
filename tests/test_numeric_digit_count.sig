//! Exact magnitude boundaries for all supported u512 widths.
const std = @import("std");
const numeric = @import("numeric");
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.NumericDigitCountContractFailed;
}

fn referenceDigitCount(input: u512) usize {
    var value = input;
    var count: usize = 0;
    while (value != 0) : (count += 1) value /= 10;
    return count;
}

fn digitCountBoundaries() !void {
    try check(numeric.digitCount(0) == 0);
    for (0..512) |bit| {
        const power = @as(u512, 1) << @as(u9, @intCast(bit));
        for ([_]u512{ power - 1, power, power + 1 }) |value| {
            try check(numeric.digitCount(value) == referenceDigitCount(value));
        }
    }
    var power: u512 = 1;
    for (1..155) |digits| {
        power *= 10;
        try check(numeric.digitCount(power - 1) == digits);
        try check(numeric.digitCount(power) == digits + 1);
        try check(numeric.digitCount(power + 1) == digits + 1);
    }
    try check(numeric.digitCount(std.math.maxInt(u512)) == 155);
}

pub fn main() !void {
    try digitCountBoundaries();
    std.debug.print("numeric-digit-count assertions={d} passed\n", .{assertions});
}
