//! Allocator-free C³ risk-sensitive achievement-capital estimator.
//! Costs must be contract-bounded and expressed in one stable numeraire.

const testing = @import("sig_testing");

pub const Error = error{EmptySample, InvalidRiskParameter, InvalidSample};

pub const Outcome = struct {
    execution_cost: f64,
    failed: bool,
    failure_penalty: f64,
};

/// Entropic certainty equivalent of execution costs plus the contractual loss.
/// Subtracting the maximum before exp keeps the finite sample computation stable.
pub fn capital(outcomes: []const Outcome, lambda: f64) Error!f64 {
    if (outcomes.len == 0) return error.EmptySample;
    if (lambda < 0) return error.InvalidRiskParameter;
    var maximum: f64 = -1.0e300;
    for (outcomes) |o| {
        if (o.execution_cost < 0 or o.failure_penalty < 0) return error.InvalidSample;
        const cost = o.execution_cost + if (o.failed) o.failure_penalty else 0;
        if (cost > maximum) maximum = cost;
    }
    if (lambda == 0) {
        var sum: f64 = 0;
        for (outcomes) |o| sum += o.execution_cost + if (o.failed) o.failure_penalty else 0;
        return sum / @as(f64, @floatFromInt(outcomes.len));
    }
    var exponential_sum: f64 = 0;
    for (outcomes) |o| {
        const cost = o.execution_cost + if (o.failed) o.failure_penalty else 0;
        exponential_sum += @exp(lambda * (cost - maximum));
    }
    const n: f64 = @floatFromInt(outcomes.len);
    return maximum + @log(exponential_sum / n) / lambda;
}

pub fn createdValue(baseline: f64, with_capability: f64) f64 {
    return baseline - with_capability;
}

test "entropic capital reduces to mean at lambda zero" {
    const xs = [_]Outcome{
        .{ .execution_cost = 10, .failed = false, .failure_penalty = 100 },
        .{ .execution_cost = 20, .failed = true, .failure_penalty = 100 },
    };
    try testing.expectApproxEqAbs(@as(f64, 65), try capital(&xs, 0), 1e-10);
}

test "entropic capital prices the failure tail" {
    const xs = [_]Outcome{
        .{ .execution_cost = 100, .failed = false, .failure_penalty = 300 },
        .{ .execution_cost = 100, .failed = false, .failure_penalty = 300 },
        .{ .execution_cost = 120, .failed = true, .failure_penalty = 300 },
    };
    const mean = try capital(&xs, 0);
    const tail_sensitive = try capital(&xs, 0.01);
    try testing.expect(tail_sensitive > mean);
}

test "achievement value is relative to a precommitted baseline" {
    try testing.expectEqual(@as(f64, 25), createdValue(100, 75));
    try testing.expectEqual(@as(f64, -5), createdValue(100, 105));
}
