//! @zpm/moment-activation — bounded latent NOW update and deterministic agency.
//!
//! The latent state is explicitly non-authoritative: it predicts and ranks;
//! canonical events, capabilities, and policies remain the source of truth.
//! All storage is fixed at compile time and every transition emits a receipt.

const math = @import("sig_math.sig");
const mem = @import("sig_mem.sig");
const testing = @import("sig_testing.sig");

pub const Error = error{
    InvalidClass,
    InvalidCoefficient,
    NonFinite,
    InvalidTick,
};

pub const UpdateReceipt = struct {
    multiplications: usize = 0,
    additions: usize = 0,
    state_l2_before: f32 = 0,
    state_l2_after: f32 = 0,
    prediction_mse: f32 = 0,
    uncertainty_q16: u16 = 0,

    pub fn macEquivalent(self: UpdateReceipt) usize {
        return @max(self.multiplications, self.additions);
    }

    pub fn arithmeticOperations(self: UpdateReceipt) usize {
        return self.multiplications + self.additions;
    }
};

/// Diagonal + low-rank state-space update:
/// z' = normalize(d_k .* z + U_k(V_k^T x) + B g).
///
/// For D=256, F=64, R=16, G=4 the learned core costs exactly
/// D + F*R + D*R + D*G = 6,400 multiplications per event.  Omitting goals
/// gives 5,376; the low-rank contextual term alone is 5,120 MAC-equivalents.
pub fn MomentModel(
    comptime state_dimension: usize,
    comptime feature_dimension: usize,
    comptime rank: usize,
    comptime goal_dimension: usize,
    comptime class_count: usize,
) type {
    if (state_dimension == 0 or feature_dimension == 0 or rank == 0 or class_count == 0)
        @compileError("moment model dimensions must be non-zero");
    if (feature_dimension > state_dimension)
        @compileError("feature dimension must not exceed state dimension for bounded prediction");

    return struct {
        const Self = @This();

        decay: [class_count][state_dimension]f32 = @splat(@splat(1)),
        left: [class_count][state_dimension][rank]f32 = @splat(@splat(@splat(0))),
        right: [class_count][feature_dimension][rank]f32 = @splat(@splat(@splat(0))),
        goal: [state_dimension][goal_dimension]f32 = @splat(@splat(0)),

        pub fn staticBytes() usize {
            return @sizeOf(Self);
        }

        pub fn learnedCoreMacs() usize {
            return feature_dimension * rank + state_dimension * rank;
        }

        pub fn totalLinearMultiplications() usize {
            return state_dimension + learnedCoreMacs() + state_dimension * goal_dimension;
        }
    };
}

pub fn MomentState(
    comptime state_dimension: usize,
    comptime feature_dimension: usize,
    comptime rank: usize,
    comptime goal_dimension: usize,
    comptime class_count: usize,
) type {
    const Model = MomentModel(state_dimension, feature_dimension, rank, goal_dimension, class_count);
    return struct {
        const Self = @This();

        state: [state_dimension]f32 = @splat(0),
        uncertainty_q16: u16 = 0,
        updates: u64 = 0,

        pub fn staticBytes() usize {
            return @sizeOf(Self);
        }

        /// Fail-atomic update: candidate state and all receipts are computed in
        /// stack scratch, then committed only after complete finite validation.
        pub fn update(
            self: *Self,
            model: *const Model,
            event_class: usize,
            features: *const [feature_dimension]f32,
            goals: *const [goal_dimension]f32,
        ) Error!UpdateReceipt {
            if (event_class >= class_count) return error.InvalidClass;
            var receipt = UpdateReceipt{};
            var before_squared: f64 = 0;
            var prediction_error: f64 = 0;

            for (self.state, 0..) |value, lane| {
                if (!math.isFinite(value)) return error.NonFinite;
                before_squared += @as(f64, value) * @as(f64, value);
                receipt.multiplications += 1;
                receipt.additions += 1;
                if (lane < feature_dimension) {
                    const observed = features[lane];
                    if (!math.isFinite(observed)) return error.NonFinite;
                    const difference = observed - value;
                    prediction_error += @as(f64, difference) * @as(f64, difference);
                    receipt.additions += 1;
                    receipt.multiplications += 1;
                    receipt.additions += 1;
                }
            }
            for (features) |value| if (!math.isFinite(value)) return error.NonFinite;
            for (goals) |value| if (!math.isFinite(value)) return error.NonFinite;

            var compressed: [rank]f32 = @splat(0);
            for (0..feature_dimension) |feature| {
                for (0..rank) |component| {
                    const coefficient = model.right[event_class][feature][component];
                    if (!math.isFinite(coefficient)) return error.InvalidCoefficient;
                    compressed[component] += coefficient * features[feature];
                    receipt.multiplications += 1;
                    receipt.additions += 1;
                }
            }

            var candidate: [state_dimension]f32 = undefined;
            var candidate_squared: f64 = 0;
            for (0..state_dimension) |lane| {
                const decay = model.decay[event_class][lane];
                if (!math.isFinite(decay) or @abs(decay) > 1) return error.InvalidCoefficient;
                var value = decay * self.state[lane];
                receipt.multiplications += 1;
                for (0..rank) |component| {
                    const coefficient = model.left[event_class][lane][component];
                    if (!math.isFinite(coefficient)) return error.InvalidCoefficient;
                    value += coefficient * compressed[component];
                    receipt.multiplications += 1;
                    receipt.additions += 1;
                }
                for (0..goal_dimension) |goal_index| {
                    const coefficient = model.goal[lane][goal_index];
                    if (!math.isFinite(coefficient)) return error.InvalidCoefficient;
                    value += coefficient * goals[goal_index];
                    receipt.multiplications += 1;
                    receipt.additions += 1;
                }
                if (!math.isFinite(value)) return error.NonFinite;
                candidate[lane] = value;
                candidate_squared += @as(f64, value) * @as(f64, value);
                receipt.multiplications += 1;
                receipt.additions += 1;
            }
            if (!math.isFiniteF64(candidate_squared)) return error.NonFinite;

            if (candidate_squared > 0) {
                const inverse: f32 = @floatCast(1.0 / @sqrt(candidate_squared));
                for (&candidate) |*value| {
                    value.* *= inverse;
                    receipt.multiplications += 1;
                }
                receipt.state_l2_after = 1;
            } else {
                receipt.state_l2_after = 0;
            }
            receipt.state_l2_before = @floatCast(@sqrt(before_squared));
            receipt.prediction_mse = @floatCast(prediction_error / @as(f64, @floatFromInt(feature_dimension)));
            const bounded_uncertainty = receipt.prediction_mse / (1.0 + receipt.prediction_mse);
            const instant: u16 = @intFromFloat(@round(@min(@as(f32, 1), bounded_uncertainty) * 65_535.0));
            // Exact rational EMA: 7/8 prior + 1/8 current, integer deterministic.
            const blended = (@as(u32, self.uncertainty_q16) * 7 + instant + 4) / 8;
            receipt.uncertainty_q16 = @intCast(blended);

            self.state = candidate;
            self.uncertainty_q16 = receipt.uncertainty_q16;
            self.updates +|= 1;
            return receipt;
        }
    };
}

pub const AutonomyLevel = enum(u3) {
    silent = 0,
    answer = 1,
    suggest = 2,
    reversible = 3,
    delegated = 4,
    supervised = 5,
};

pub const ActivationClass = enum(u3) {
    safety,
    answer,
    observe,
    plan,
    act,
    background,
    none,
};

pub const Signal = struct {
    hazard: u16 = 0,
    explicit_request: u16 = 0,
    goal_relevance: u16 = 0,
    opportunity: u16 = 0,
    interruption_cost: u16 = 0,
    uncertainty: u16 = 0,

    pub fn values(self: Signal) [6]u16 {
        return .{ self.hazard, self.explicit_request, self.goal_relevance, self.opportunity, self.interruption_cost, self.uncertainty };
    }
};

pub const TokenBucket = struct {
    capacity: u16 = 0,
    tokens: u16 = 0,
    refill_per_tick: u16 = 0,
    last_tick: u64 = 0,

    pub fn refill(self: *TokenBucket, tick: u64) Error!void {
        if (tick < self.last_tick) return error.InvalidTick;
        const elapsed = tick - self.last_tick;
        const added = @min(
            @as(u64, self.capacity),
            elapsed *| @as(u64, self.refill_per_tick),
        );
        self.tokens = @intCast(@min(@as(u64, self.capacity), @as(u64, self.tokens) + added));
        self.last_tick = tick;
    }

    pub fn spend(self: *TokenBucket, amount: u16) bool {
        if (self.tokens < amount) return false;
        self.tokens -= amount;
        return true;
    }
};

const actionable_class_count = 6;

pub const ActivationPolicy = struct {
    autonomy: AutonomyLevel = .silent,
    // Q1.15 weights over Q0.16 signals; rows follow ActivationClass 0..5.
    weights: [actionable_class_count][6]i16 = @splat(@splat(0)),
    bias_q16: [actionable_class_count]i32 = @splat(0),
    enter_q16: [actionable_class_count]u16 = @splat(49_152),
    release_q16: [actionable_class_count]u16 = @splat(32_768),
    cooldown_ticks: [actionable_class_count]u32 = @splat(0),
    token_cost: [actionable_class_count]u16 = @splat(1),
    compute_cost: [actionable_class_count]u16 = @splat(0),
    interruption_cost: [actionable_class_count]u16 = @splat(0),
};

pub const ActivationDecision = struct {
    selected: ActivationClass = .none,
    scores_q16: [actionable_class_count]u16 = @splat(0),
    policy_rejections: u8 = 0,
    cooldown_rejections: u8 = 0,
    budget_rejections: u8 = 0,
    tokens_remaining: u16 = 0,
    compute_tokens_remaining: u16 = 0,
    interruption_tokens_remaining: u16 = 0,
};

pub const ActivationEngine = struct {
    active: [actionable_class_count]bool = @splat(false),
    last_fire: [actionable_class_count]u64 = @splat(0),
    has_fired: [actionable_class_count]bool = @splat(false),
    buckets: [actionable_class_count]TokenBucket = @splat(.{}),
    compute_bucket: TokenBucket = .{},
    interruption_bucket: TokenBucket = .{},

    pub fn staticBytes() usize {
        return @sizeOf(ActivationEngine);
    }

    pub fn evaluate(self: *ActivationEngine, policy: *const ActivationPolicy, signal: Signal, tick: u64) Error!ActivationDecision {
        var decision = ActivationDecision{};
        const values = signal.values();
        var best_score: u16 = 0;
        var selected_index: ?usize = null;
        try self.compute_bucket.refill(tick);
        try self.interruption_bucket.refill(tick);

        for (0..actionable_class_count) |class_index| {
            try self.buckets[class_index].refill(tick);
            const score = fixedScore(policy.weights[class_index], policy.bias_q16[class_index], values);
            decision.scores_q16[class_index] = score;
            const threshold = if (self.active[class_index]) policy.release_q16[class_index] else policy.enter_q16[class_index];
            self.active[class_index] = score >= threshold;
            if (!self.active[class_index]) continue;
            if (@intFromEnum(policy.autonomy) < requiredAutonomy(class_index)) {
                decision.policy_rejections +|= 1;
                continue;
            }
            if (self.has_fired[class_index] and tick - self.last_fire[class_index] < policy.cooldown_ticks[class_index]) {
                decision.cooldown_rejections +|= 1;
                continue;
            }
            if (self.buckets[class_index].tokens < policy.token_cost[class_index]) {
                decision.budget_rejections +|= 1;
                continue;
            }
            if (self.compute_bucket.tokens < policy.compute_cost[class_index] or
                self.interruption_bucket.tokens < policy.interruption_cost[class_index]) {
                decision.budget_rejections +|= 1;
                continue;
            }
            if (selected_index == null or score > best_score) {
                selected_index = class_index;
                best_score = score;
            }
        }

        if (selected_index) |index| {
            _ = self.buckets[index].spend(policy.token_cost[index]);
            _ = self.compute_bucket.spend(policy.compute_cost[index]);
            _ = self.interruption_bucket.spend(policy.interruption_cost[index]);
            self.last_fire[index] = tick;
            self.has_fired[index] = true;
            decision.selected = @enumFromInt(index);
            decision.tokens_remaining = self.buckets[index].tokens;
        }
        decision.compute_tokens_remaining = self.compute_bucket.tokens;
        decision.interruption_tokens_remaining = self.interruption_bucket.tokens;
        return decision;
    }
};

fn fixedScore(weights: [6]i16, bias_q16: i32, values: [6]u16) u16 {
    var accumulator: i64 = @as(i64, bias_q16) * 32_767;
    for (weights, values) |weight, value| accumulator += @as(i64, weight) * @as(i64, value);
    const scaled = @divTrunc(accumulator, 32_767);
    return @intCast(math.clamp(scaled, 0, 65_535));
}

fn requiredAutonomy(class_index: usize) u3 {
    return switch (@as(ActivationClass, @enumFromInt(class_index))) {
        .safety => 0,
        .answer, .observe => 1,
        .plan, .background => 2,
        .act => 3,
        .none => unreachable,
    };
}



test "low-rank NOW update is normalized and operation count is exact" {
    const Model = MomentModel(4, 2, 1, 1, 1);
    const State = MomentState(4, 2, 1, 1, 1);
    var model = Model{};
    model.right[0][0][0] = 1;
    model.left[0][0][0] = 1;
    model.goal[1][0] = 1;
    var state = State{};
    const features = [2]f32{ 2, 0 };
    const goals = [1]f32{1};
    const receipt = try state.update(&model, 0, &features, &goals);
    if (@abs(receipt.state_l2_after - @as(f32, 1)) > 0.00001) return error.TestUnexpectedResult;
    try testing.expectEqual(Model.learnedCoreMacs(), @as(usize, 2 * 1 + 4 * 1));
    try testing.expect(receipt.multiplications >= Model.totalLinearMultiplications());
    if (state.updates != 1) return error.TestUnexpectedResult;
}

test "invalid coefficients cannot partially mutate NOW" {
    const Model = MomentModel(2, 1, 1, 0, 1);
    const State = MomentState(2, 1, 1, 0, 1);
    var model = Model{};
    model.decay[0][1] = 2;
    var state = State{ .state = .{ 1, 0 } };
    const before = state.state;
    const features = [1]f32{1};
    const goals = [0]f32{};
    try testing.expectError(error.InvalidCoefficient, state.update(&model, 0, &features, &goals));
    if (!mem.eql(f32, &state.state, &before)) return error.TestUnexpectedResult;
    if (state.updates != 0) return error.TestUnexpectedResult;
}

fn testPolicy(level: AutonomyLevel) ActivationPolicy {
    var policy = ActivationPolicy{ .autonomy = level };
    // answer score is exactly explicit_request; act score is goal_relevance.
    policy.weights[@intFromEnum(ActivationClass.answer)][1] = 32_767;
    policy.weights[@intFromEnum(ActivationClass.act)][2] = 32_767;
    policy.enter_q16 = @splat(40_000);
    policy.release_q16 = @splat(20_000);
    return policy;
}

test "activation obeys autonomy and token budgets" {
    var engine = ActivationEngine{};
    engine.buckets[@intFromEnum(ActivationClass.answer)] = .{ .capacity = 2, .tokens = 2, .refill_per_tick = 0 };
    engine.buckets[@intFromEnum(ActivationClass.act)] = .{ .capacity = 2, .tokens = 2, .refill_per_tick = 0 };
    var policy = testPolicy(.answer);
    const decision = try engine.evaluate(&policy, .{ .explicit_request = 60_000, .goal_relevance = 65_535 }, 1);
    if (decision.selected != ActivationClass.answer) return error.TestUnexpectedResult;
    if (!(decision.policy_rejections >= 1)) return error.TestUnexpectedResult;
    policy.autonomy = .reversible;
    const act = try engine.evaluate(&policy, .{ .goal_relevance = 65_535 }, 2);
    if (act.selected != ActivationClass.act) return error.TestUnexpectedResult;
}

test "hysteresis prevents threshold chatter and cooldown is exact" {
    var engine = ActivationEngine{};
    const answer = @intFromEnum(ActivationClass.answer);
    engine.buckets[answer] = .{ .capacity = 3, .tokens = 3, .refill_per_tick = 0 };
    var policy = testPolicy(.answer);
    policy.cooldown_ticks[answer] = 3;
    const first = try engine.evaluate(&policy, .{ .explicit_request = 50_000 }, 10);
    if (first.selected != ActivationClass.answer) return error.TestUnexpectedResult;
    // Below enter but above release: class remains active; cooldown blocks fire.
    const held = try engine.evaluate(&policy, .{ .explicit_request = 30_000 }, 11);
    if (held.selected != ActivationClass.none) return error.TestUnexpectedResult;
    if (!(held.cooldown_rejections >= 1)) return error.TestUnexpectedResult;
    const after = try engine.evaluate(&policy, .{ .explicit_request = 30_000 }, 13);
    if (after.selected != ActivationClass.answer) return error.TestUnexpectedResult;
    const released = try engine.evaluate(&policy, .{ .explicit_request = 10_000 }, 16);
    if (released.selected != ActivationClass.none) return error.TestUnexpectedResult;
}

test "token refill saturates without wraparound" {
    var bucket = TokenBucket{ .capacity = 10, .tokens = 1, .refill_per_tick = 4, .last_tick = 2 };
    try bucket.refill(math.maxInt(u64));
    if (bucket.tokens != 10) return error.TestUnexpectedResult;
    try testing.expectError(error.InvalidTick, bucket.refill(1));
}

test "compute and interruption budgets are independent hard bounds" {
    var engine = ActivationEngine{};
    const answer = @intFromEnum(ActivationClass.answer);
    engine.buckets[answer] = .{ .capacity = 4, .tokens = 4 };
    engine.compute_bucket = .{ .capacity = 4, .tokens = 4 };
    engine.interruption_bucket = .{ .capacity = 1, .tokens = 1 };
    var policy = testPolicy(.answer);
    policy.compute_cost[answer] = 2;
    policy.interruption_cost[answer] = 1;
    const first = try engine.evaluate(&policy, .{ .explicit_request = 60_000 }, 1);
    if (first.selected != ActivationClass.answer) return error.TestUnexpectedResult;
    if (first.compute_tokens_remaining != 2) return error.TestUnexpectedResult;
    if (first.interruption_tokens_remaining != 0) return error.TestUnexpectedResult;
    const denied = try engine.evaluate(&policy, .{ .explicit_request = 60_000 }, 2);
    if (denied.selected != ActivationClass.none) return error.TestUnexpectedResult;
    if (!(denied.budget_rejections >= 1)) return error.TestUnexpectedResult;
    // A denied interruption cannot drain the still-available compute bucket.
    if (denied.compute_tokens_remaining != 2) return error.TestUnexpectedResult;
}
