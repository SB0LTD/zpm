//! Fixed-sample paired-ablation bound for one predeclared family of interfaces.
//! This is not an anytime-valid confidence sequence or a radial-allocation bound.
const testing = @import("sig_testing");

pub const Error = error{NoObservations, InvalidRange, InvalidConfidence, TooManyInterfaces};
pub const MAX_INTERFACES: usize = 64;
pub const Bounds = struct { estimate: f64, lower: f64, upper: f64, confidence_delta: f64 };

/// Each paired effect lies in [-range, +range]. Uses a two-sided Hoeffding
/// radius with a Bonferroni union allocation over `family_size` fixed claims.
pub fn pairedHoeffding(
    effects: []const f64,
    range: f64,
    confidence_delta: f64,
    family_size: usize,
) Error!Bounds {
    if (effects.len == 0) return error.NoObservations;
    if (range <= 0) return error.InvalidRange;
    if (confidence_delta <= 0 or confidence_delta >= 1) return error.InvalidConfidence;
    if (family_size == 0 or family_size > MAX_INTERFACES) return error.TooManyInterfaces;
    var total: f64 = 0;
    for (effects) |effect| {
        if (effect < -range or effect > range) return error.InvalidRange;
        total += effect;
    }
    const n: f64 = @floatFromInt(effects.len);
    const m: f64 = @floatFromInt(family_size);
    const radius = range * @sqrt(2.0 * @log(2.0 * m / confidence_delta) / n);
    const estimate = total / n;
    return .{ .estimate = estimate, .lower = estimate - radius, .upper = estimate + radius, .confidence_delta = confidence_delta };
}

test "paired audit interval narrows with more observations" {
    const few = [_]f64{ 1, 1, 0, 1, 0, 1, 1, 0 };
    const many = [_]f64{ 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0 };
    const a = try pairedHoeffding(&few, 1, 0.05, 2);
    const b = try pairedHoeffding(&many, 1, 0.05, 2);
    try testing.expect(a.upper - a.lower > b.upper - b.lower);
}
