//! Minimal allocation-free assertions for pure-Sig module tests.
//!
//! Production compilation may analyze test declarations even when it does not
//! execute them. Keeping these helpers freestanding avoids making core ZPM
//! packages depend on allocator-backed `std.testing` merely to type-check.

pub const Error = error{
    TestUnexpectedResult,
    TestExpectedError,
    TestUnexpectedError,
};

pub fn expect(condition: bool) Error!void {
    if (!condition) return error.TestUnexpectedResult;
}

pub fn expectEqual(expected: anytype, actual: anytype) Error!void {
    if (actual != expected) return error.TestUnexpectedResult;
}

pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) Error!void {
    if (expected.len != actual.len) return error.TestUnexpectedResult;
    for (expected, actual) |left, right|
        if (left != right) return error.TestUnexpectedResult;
}

pub fn expectApproxEqAbs(expected: anytype, actual: @TypeOf(expected), tolerance: @TypeOf(expected)) Error!void {
    const difference = if (actual >= expected) actual - expected else expected - actual;
    if (difference > tolerance) return error.TestUnexpectedResult;
}

pub fn expectError(expected: anyerror, result: anytype) Error!void {
    if (result) |_| {
        return error.TestExpectedError;
    } else |actual| {
        if (actual != expected) return error.TestUnexpectedError;
    }
}

test "pure assertions cover equality slices approximation and errors" {
    try expect(true);
    try expectEqual(@as(u32, 7), @as(u32, 7));
    try expectEqualSlices(u8, "sb0", "sb0");
    try expectApproxEqAbs(@as(f32, 1.0), @as(f32, 1.001), @as(f32, 0.01));
    try expectError(error.Sample, @as(error{Sample}!void, error.Sample));
}
