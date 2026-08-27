//! Token Sampling Strategies — allocation-free.
//!
//! Operates on the logits buffer in-place. All strategies compose:
//!   1. Apply repetition/frequency/presence penalties
//!   2. Temperature scaling
//!   3. Top-K filtering
//!   4. Top-P (nucleus) filtering
//!   5. Softmax normalization
//!   6. Sample from distribution (or argmax for greedy)
//!
//! Uses xoshiro256** PRNG — fast, high-quality, deterministic from seed.
//! Zero allocation. All state in caller-owned structs.

const math = @import("sig_math.sig");

// ══════════════════════════════════════════════════════════════════════════════
// Configuration
// ══════════════════════════════════════════════════════════════════════════════

pub const Config = struct {
    temperature: f32 = 1.0, // 0.0 = greedy, >1.0 = more random
    top_k: u32 = 40, // 0 = disabled, N = keep top N
    top_p: f32 = 0.95, // 0.0 = disabled, 0.95 = nucleus
    repetition_penalty: f32 = 1.0, // 1.0 = disabled, >1.0 = penalize repeats
    frequency_penalty: f32 = 0.0, // 0.0 = disabled, additive penalty per occurrence
    presence_penalty: f32 = 0.0, // 0.0 = disabled, additive penalty if token appeared
    min_p: f32 = 0.0, // 0.0 = disabled, minimum probability relative to max

    pub const GREEDY = Config{ .temperature = 0.0 };
    pub const CREATIVE = Config{ .temperature = 0.8, .top_p = 0.95, .top_k = 50 };
    pub const BALANCED = Config{ .temperature = 0.6, .top_p = 0.9, .top_k = 40 };
};

// ══════════════════════════════════════════════════════════════════════════════
// PRNG (xoshiro256**)
// ══════════════════════════════════════════════════════════════════════════════

pub const Rng = struct {
    s: [4]u64,

    pub fn init(seed: u64) Rng {
        // SplitMix64 to expand seed into 4 state words
        var z = seed;
        var state: [4]u64 = undefined;
        inline for (0..4) |i| {
            z +%= 0x9e3779b97f4a7c15;
            var x = z;
            x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
            x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
            state[i] = x ^ (x >> 31);
        }
        return .{ .s = state };
    }

    /// Generate next u64.
    pub fn next(self: *Rng) u64 {
        const result = math.rotl(u64, self.s[1] *% 5, 7) *% 9;
        const t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = math.rotl(u64, self.s[3], 45);
        return result;
    }

    /// Generate uniform f32 in [0, 1).
    pub fn float(self: *Rng) f32 {
        const bits = self.next() >> 40; // 24 bits of mantissa
        return @as(f32, @floatFromInt(bits)) / 16777216.0; // 2^24
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Core Sampling Function
// ══════════════════════════════════════════════════════════════════════════════

/// Apply full sampling pipeline to logits and return selected token index.
/// `context` contains the recent token history for repetition penalties.
/// `logits` is modified in-place.
pub fn sample(
    logits: []f32,
    config: Config,
    rng: *Rng,
    context_tokens: []const u32,
) usize {
    // 1. Repetition / frequency / presence penalties
    if (config.repetition_penalty != 1.0 or config.frequency_penalty != 0.0 or config.presence_penalty != 0.0) {
        applyRepetitionPenalty(logits, context_tokens, config.repetition_penalty, config.frequency_penalty, config.presence_penalty);
    }

    // 2. Temperature
    if (config.temperature <= 0.0) {
        // Greedy: just return argmax
        return argmax(logits);
    }
    if (config.temperature != 1.0) {
        applyTemperature(logits, config.temperature);
    }

    // 3. Softmax to get probabilities
    softmax(logits);

    // 4. Min-P filtering
    if (config.min_p > 0.0) {
        applyMinP(logits, config.min_p);
    }

    // 5. Top-K filtering
    if (config.top_k > 0 and config.top_k < logits.len) {
        applyTopK(logits, config.top_k);
    }

    // 6. Top-P (nucleus) filtering
    if (config.top_p > 0.0 and config.top_p < 1.0) {
        applyTopP(logits, config.top_p);
    }

    // 7. Re-normalize after filtering
    renormalize(logits);

    // 8. Sample from distribution
    return sampleFromDistribution(logits, rng);
}

// ══════════════════════════════════════════════════════════════════════════════
// Penalty Application
// ══════════════════════════════════════════════════════════════════════════════

fn applyRepetitionPenalty(
    logits: []f32,
    context_tokens: []const u32,
    rep_penalty: f32,
    freq_penalty: f32,
    presence_penalty: f32,
) void {
    // Count occurrences of each token in context
    for (context_tokens) |token| {
        if (token >= logits.len) continue;
        const idx: usize = token;

        // Repetition penalty (multiplicative)
        if (rep_penalty != 1.0) {
            if (logits[idx] > 0) {
                logits[idx] /= rep_penalty;
            } else {
                logits[idx] *= rep_penalty;
            }
        }

        // Frequency penalty (additive, proportional to count)
        if (freq_penalty != 0.0) {
            logits[idx] -= freq_penalty;
        }

        // Presence penalty (additive, once per unique token)
        if (presence_penalty != 0.0) {
            logits[idx] -= presence_penalty;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Temperature
// ══════════════════════════════════════════════════════════════════════════════

fn applyTemperature(logits: []f32, temperature: f32) void {
    const inv_temp = 1.0 / temperature;
    for (logits) |*l| l.* *= inv_temp;
}

// ══════════════════════════════════════════════════════════════════════════════
// Softmax (numerically stable)
// ══════════════════════════════════════════════════════════════════════════════

fn softmax(logits: []f32) void {
    if (logits.len == 0) return;
    var max_val = logits[0];
    for (logits[1..]) |l| if (l > max_val) { max_val = l; };
    var sum: f64 = 0;
    for (logits) |*l| {
        l.* = @exp(l.* - max_val);
        sum += l.*;
    }
    if (sum <= 0) return;
    const inv: f32 = @floatCast(1.0 / sum);
    for (logits) |*l| l.* *= inv;
}

// ══════════════════════════════════════════════════════════════════════════════
// Min-P Filtering
// ══════════════════════════════════════════════════════════════════════════════

fn applyMinP(probs: []f32, min_p: f32) void {
    // Find max probability
    var max_prob: f32 = 0;
    for (probs) |p| if (p > max_prob) { max_prob = p; };
    // Zero out anything below min_p * max_prob
    const threshold = min_p * max_prob;
    for (probs) |*p| if (p.* < threshold) { p.* = 0; };
}

// ══════════════════════════════════════════════════════════════════════════════
// Top-K Filtering (partial selection, O(n*k) for small k)
// ══════════════════════════════════════════════════════════════════════════════

fn applyTopK(probs: []f32, k: u32) void {
    // Find the k-th largest value using partial selection
    // For typical k (40-100) and vocab (32k-152k), this is fast enough
    const target_k: usize = k;

    // Find k-th threshold by repeated min-of-maxes
    // Simpler approach: find k-th value via partial sort of indices
    var threshold: f32 = 0;
    var count_above: usize = 0;

    // Binary-search-like: find threshold where exactly k elements are above
    // Start by finding max and using it to narrow
    var max_val: f32 = 0;
    var min_val: f32 = probs[0];
    for (probs) |p| {
        if (p > max_val) max_val = p;
        if (p < min_val and p > 0) min_val = p;
    }

    // Iterative threshold search (converges in ~20 iterations for f32)
    var lo = min_val;
    var hi = max_val;
    var iterations: u8 = 0;
    while (iterations < 30) : (iterations += 1) {
        threshold = (lo + hi) / 2.0;
        count_above = 0;
        for (probs) |p| if (p >= threshold) { count_above += 1; };
        if (count_above == target_k) break;
        if (count_above > target_k) {
            lo = threshold;
        } else {
            hi = threshold;
        }
    }

    // Zero out everything below threshold
    for (probs) |*p| if (p.* < threshold) { p.* = 0; };
}

// ══════════════════════════════════════════════════════════════════════════════
// Top-P (Nucleus) Filtering
// ══════════════════════════════════════════════════════════════════════════════

fn applyTopP(probs: []f32, p: f32) void {
    // Need cumulative sum in descending probability order.
    // Since we can't sort without allocation, use iterative threshold approach:
    // Find the smallest probability threshold such that the sum of probs >= threshold
    // is at least p.
    var total: f64 = 0;
    for (probs) |prob| total += prob;
    if (total <= 0) return;

    const target_mass = @as(f64, p) * total;

    // Find threshold by binary search
    var max_val: f32 = 0;
    for (probs) |prob| if (prob > max_val) { max_val = prob; };

    var lo: f32 = 0;
    var hi = max_val;
    var iterations: u8 = 0;
    while (iterations < 30) : (iterations += 1) {
        const mid = (lo + hi) / 2.0;
        var mass: f64 = 0;
        for (probs) |prob| if (prob >= mid) { mass += prob; };
        if (mass >= target_mass) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    // Zero below threshold
    for (probs) |*prob| if (prob.* < lo) { prob.* = 0; };
}

// ══════════════════════════════════════════════════════════════════════════════
// Renormalize
// ══════════════════════════════════════════════════════════════════════════════

fn renormalize(probs: []f32) void {
    var sum: f64 = 0;
    for (probs) |p| sum += p;
    if (sum <= 0) return;
    const inv: f32 = @floatCast(1.0 / sum);
    for (probs) |*p| p.* *= inv;
}

// ══════════════════════════════════════════════════════════════════════════════
// Distribution Sampling
// ══════════════════════════════════════════════════════════════════════════════

fn sampleFromDistribution(probs: []f32, rng: *Rng) usize {
    const r = rng.float();
    var cumulative: f32 = 0;
    for (probs, 0..) |p, i| {
        cumulative += p;
        if (cumulative > r) return i;
    }
    // Fallback: return last non-zero
    var last: usize = 0;
    for (probs, 0..) |p, i| if (p > 0) { last = i; };
    return last;
}

// ══════════════════════════════════════════════════════════════════════════════
// Argmax (Greedy)
// ══════════════════════════════════════════════════════════════════════════════

fn argmax(logits: []const f32) usize {
    if (logits.len == 0) return 0;
    var best: usize = 0;
    var best_val = logits[0];
    for (logits[1..], 1..) |l, i| {
        if (l > best_val) { best_val = l; best = i; }
    }
    return best;
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "greedy sampling returns argmax" {
    var logits = [_]f32{ 1.0, 5.0, 3.0, 2.0 };
    var rng = Rng.init(42);
    const result = sample(&logits, Config.GREEDY, &rng, &.{});
    if (result != 1) return error.TestUnexpectedResult;
}

test "temperature 0 is greedy" {
    var logits = [_]f32{ -1.0, 10.0, -5.0, 0.0 };
    var rng = Rng.init(123);
    const result = sample(&logits, .{ .temperature = 0.0 }, &rng, &.{});
    if (result != 1) return error.TestUnexpectedResult;
}

test "repetition penalty reduces repeated token logit" {
    var logits = [_]f32{ 5.0, 5.0, 5.0, 5.0 };
    const context = [_]u32{ 1, 1, 1 }; // Token 1 repeated 3 times
    applyRepetitionPenalty(&logits, &context, 1.5, 0.0, 0.0);
    // Token 1 should be penalized (divided by 1.5 since positive)
    if (logits[1] >= 5.0) return error.TestUnexpectedResult;
    // Others unchanged
    if (logits[0] != 5.0) return error.TestUnexpectedResult;
    if (logits[2] != 5.0) return error.TestUnexpectedResult;
}

test "RNG produces different values" {
    var rng = Rng.init(0xDEADBEEF);
    const a = rng.next();
    const b = rng.next();
    if (a == b) return error.TestUnexpectedResult;
    const f1 = rng.float();
    const f2 = rng.float();
    if (f1 < 0 or f1 >= 1.0) return error.TestUnexpectedResult;
    if (f2 < 0 or f2 >= 1.0) return error.TestUnexpectedResult;
}

test "softmax normalizes to sum 1" {
    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    softmax(&logits);
    var sum: f32 = 0;
    for (logits) |p| sum += p;
    if (@abs(sum - 1.0) > 0.0001) return error.TestUnexpectedResult;
    // Monotonically increasing (higher logit = higher prob)
    if (logits[3] <= logits[2]) return error.TestUnexpectedResult;
    if (logits[2] <= logits[1]) return error.TestUnexpectedResult;
}
