//! Fixed-storage acoustic sampler matching the released Qwen3-TTS policy.
//!
//! The Talker uses temperature 0.9, top-k 50, repetition penalty 1.05, and
//! suppresses reserved codec ids except EOS. The predictor uses the same
//! top-k/temperature without Talker suppression. Entropy is explicit caller
//! state so boot tests are reproducible and hardware builds can seed it from
//! the admitted entropy service.

const std = @import("std");
const plan = @import("tts_talker_plan");

pub const MAX_TOP_K: usize = 50;

pub const Config = struct {
    top_k: u8 = 50,
    temperature: f32 = 0.9,
    repetition_penalty: f32 = 1.05,
    suppress_reserved: bool = false,
};

pub const Error = error{
    InvalidConfiguration,
    InvalidLogits,
    NoCandidate,
};

const Candidate = struct {
    token: u16 = 0,
    score: f32 = -std.math.inf(f32),
};

pub const Sampler = struct {
    state: u64,
    candidates: [MAX_TOP_K]Candidate = @splat(.{}),

    pub fn init(seed: u64) Sampler {
        return .{ .state = if (seed == 0) 0x9e3779b97f4a7c15 else seed };
    }

    pub fn sample(
        self: *Sampler,
        logits: []const f32,
        history: []const u16,
        config: Config,
    ) Error!u16 {
        if (logits.len == 0 or logits.len > std.math.maxInt(u16) or config.top_k == 0 or
            config.top_k > MAX_TOP_K or config.top_k > logits.len or
            !std.math.isFinite(config.temperature) or config.temperature <= 0 or
            !std.math.isFinite(config.repetition_penalty) or config.repetition_penalty < 1)
            return error.InvalidConfiguration;
        self.candidates = @splat(.{});
        const wanted: usize = config.top_k;
        var count: usize = 0;
        for (logits, 0..) |raw, token_index| {
            if (!std.math.isFinite(raw)) return error.InvalidLogits;
            const token: u16 = @intCast(token_index);
            if (config.suppress_reserved and token >= plan.ACOUSTIC_VOCABULARY and token != plan.CODEC_EOS)
                continue;
            var score = raw;
            if (contains(history, token)) score = if (score < 0)
                score * config.repetition_penalty
            else
                score / config.repetition_penalty;
            score /= config.temperature;
            if (!std.math.isFinite(score)) return error.InvalidLogits;
            insert(&self.candidates, &count, wanted, .{ .token = token, .score = score });
        }
        if (count == 0) return error.NoCandidate;

        const maximum = self.candidates[0].score;
        var total: f64 = 0;
        for (self.candidates[0..count]) |candidate|
            total += @exp(@as(f64, candidate.score - maximum));
        if (!std.math.isFinite(total) or total <= 0) return error.InvalidLogits;
        const threshold = self.uniform() * total;
        var cumulative: f64 = 0;
        for (self.candidates[0..count]) |candidate| {
            cumulative += @exp(@as(f64, candidate.score - maximum));
            if (threshold < cumulative) return candidate.token;
        }
        return self.candidates[count - 1].token;
    }

    fn uniform(self: *Sampler) f64 {
        var value = self.state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.state = value;
        const random = value *% 0x2545f4914f6cdd1d;
        return @as(f64, @floatFromInt(random >> 11)) * 0x1.0p-53;
    }
};

fn contains(values: []const u16, expected: u16) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

fn insert(storage: *[MAX_TOP_K]Candidate, count: *usize, limit: usize, value: Candidate) void {
    var position: usize = 0;
    while (position < count.* and storage[position].score >= value.score) : (position += 1) {}
    if (position >= limit) return;
    const new_count = @min(count.* + 1, limit);
    var cursor = new_count - 1;
    while (cursor > position) : (cursor -= 1) storage[cursor] = storage[cursor - 1];
    storage[position] = value;
    count.* = new_count;
}

test "sampling is deterministic for a receipt seed" {
    var logits: [64]f32 = @splat(-10);
    logits[7] = 2;
    logits[9] = 1.5;
    var first = Sampler.init(0x534230);
    var second = Sampler.init(0x534230);
    const config = Config{ .top_k = 2 };
    try std.testing.expectEqual(
        try first.sample(&logits, &.{}, config),
        try second.sample(&logits, &.{}, config),
    );
}

test "Talker suppression retains EOS and removes reserved ids" {
    var logits: [plan.CODEC_VOCABULARY]f32 = @splat(-100);
    logits[3000] = 100;
    logits[plan.CODEC_EOS] = 90;
    logits[17] = 80;
    var sampler = Sampler.init(1);
    const selected = try sampler.sample(&logits, &.{}, .{
        .top_k = 1,
        .suppress_reserved = true,
    });
    try std.testing.expectEqual(plan.CODEC_EOS, selected);
}

test "positive repetition logits are penalized" {
    var logits: [4]f32 = .{ 0, 3, 2.9, 0 };
    var sampler = Sampler.init(2);
    const selected = try sampler.sample(&logits, &.{1}, .{
        .top_k = 1,
        .repetition_penalty = 1.1,
    });
    try std.testing.expectEqual(@as(u16, 2), selected);
}
