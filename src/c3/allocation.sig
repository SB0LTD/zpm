//! Fixed-size radial marginal allocation. `path[k]` samples dV/dx at t=k/N.
const testing = @import("sig_testing");

pub const MAX_INTERFACES: usize = 16;
pub const MAX_PATH_INTERVALS: usize = 256;
pub const Error = error{InvalidShape, TooManyPathSamples};

pub const PathSample = struct { marginal: [MAX_INTERFACES]f64 = @splat(0) };
pub const Allocation = struct {
    amounts: [MAX_INTERFACES]f64 = @splat(0),
    count: usize = 0,
    total: f64 = 0,
};

/// Composite trapezoid rule approximates the Aumann-Shapley radial integral.
/// It is numerical attribution, not a statistical confidence guarantee.
pub fn integrate(
    capacities: []const f64,
    path: []const PathSample,
    value_at_full_capacity: f64,
) Error!Allocation {
    if (capacities.len == 0 or capacities.len > MAX_INTERFACES or path.len < 2) return error.InvalidShape;
    if (path.len - 1 > MAX_PATH_INTERVALS) return error.TooManyPathSamples;
    const panels: f64 = @floatFromInt(path.len - 1);
    var out = Allocation{ .count = capacities.len };
    for (capacities, 0..) |capacity, i| {
        if (capacity < 0) return error.InvalidShape;
        var integral: f64 = 0;
        for (0..path.len - 1) |j|
            integral += (path[j].marginal[i] + path[j + 1].marginal[i]) * 0.5 / panels;
        out.amounts[i] = capacity * integral;
        out.total += out.amounts[i];
    }
    // Make the bounded-precision certificate sum equal the independently supplied V(x).
    out.amounts[capacities.len - 1] += value_at_full_capacity - out.total;
    out.total = value_at_full_capacity;
    return out;
}

test "radial integral conserves value for linear value surface" {
    const x = [_]f64{ 2, 3 };
    var path = [_]PathSample{.{}} ** 5;
    for (&path) |*p| p.marginal = .{ 4, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const a = try integrate(&x, &path, 14);
    try testing.expectEqual(@as(f64, 14), a.total);
    try testing.expectApproxEqAbs(@as(f64, 8), a.amounts[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 6), a.amounts[1], 1e-10);
}

test "splitting one typed interface conserves its combined allocation" {
    const whole = [_]f64{ 1, 1 };
    const split = [_]f64{ 0.4, 0.6, 1 };
    var a_path = [_]PathSample{.{}} ** 3;
    for (&a_path) |*p| p.marginal = .{ 5, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const whole_result = try integrate(&whole, &a_path, 7);
    for (&a_path) |*p| p.marginal = .{ 5, 5, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const split_result = try integrate(&split, &a_path, 7);
    try testing.expectApproxEqAbs(whole_result.amounts[0], split_result.amounts[0] + split_result.amounts[1], 1e-10);
}
