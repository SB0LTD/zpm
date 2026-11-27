//! Streaming bandlimited mono resampler with exact rational sample cadence.
//! A 96-tap Kaiser-windowed sinc suppresses aliasing before downsampling.
//! Coefficients, history and counters are caller-owned; no per-sample trig,
//! allocation, accumulated floating-point clock drift, or host APIs are used.
const std = @import("std");
pub const TAPS: usize = 96;
pub const PHASES: usize = 256;
const HALF: usize = TAPS / 2;
const RING: usize = 256;
pub const Error = error{ InvalidRate, InvalidSample, Finished, CounterOverflow };
pub const Result = struct { consumed: usize, produced: usize };

pub const Resampler = struct {
    coefficients: [PHASES + 1][TAPS]f32 = undefined,
    history: [RING]f32 = @splat(0),
    input_rate: u32 = 0,
    output_rate: u32 = 0,
    received: u64 = 0,
    emitted: u64 = 0,
    finishing: bool = false,

    pub fn init(self: *Resampler, input_rate: u32, output_rate: u32) Error!void {
        if (input_rate < 8000 or input_rate > 192000 or output_rate < 8000 or output_rate > 192000)
            return error.InvalidRate;
        self.input_rate = input_rate;
        self.output_rate = output_rate;
        self.received = 0;
        self.emitted = 0;
        self.finishing = false;
        @memset(&self.history, 0);
        const cutoff = 0.94 * @min(@as(f64, 1), @as(f64, @floatFromInt(output_rate)) / @as(f64, @floatFromInt(input_rate)));
        const denominator = besselI0(8.6);
        for (&self.coefficients, 0..) |*phase, p| {
            const fraction = @as(f64, @floatFromInt(p)) / PHASES;
            var sum: f64 = 0;
            for (phase, 0..) |*coefficient, i| {
                const x = @as(f64, @floatFromInt(i)) - (HALF - 1) - fraction;
                const position = x / HALF;
                const window = if (@abs(position) < 1) besselI0(8.6 * @sqrt(1 - position * position)) / denominator else 0;
                const angle = std.math.pi * x * cutoff;
                const value = cutoff * (if (@abs(angle) < 1.0e-12) @as(f64, 1) else @sin(angle) / angle) * window;
                coefficient.* = @floatCast(value);
                sum += value;
            }
            for (phase) |*coefficient| coefficient.* /= @as(f32, @floatCast(sum));
        }
    }

    pub fn process(self: *Resampler, input: []const f32, output: []f32) Error!Result {
        if (self.input_rate == 0) return error.InvalidRate;
        if (self.finishing) return error.Finished;
        if (self.input_rate == self.output_rate) {
            const count = @min(input.len, output.len);
            if (count > std.math.maxInt(u64) / 192000 - self.received) return error.CounterOverflow;
            for (input[0..count]) |sample| if (!std.math.isFinite(sample)) return error.InvalidSample;
            @memcpy(output[0..count], input[0..count]);
            self.received += count;
            self.emitted += count;
            return .{ .consumed = count, .produced = count };
        }
        var result: Result = .{ .consumed = 0, .produced = 0 };
        while (result.produced < output.len) {
            if (self.canEmit(false)) {
                output[result.produced] = self.emit();
                result.produced += 1;
            } else {
                if (result.consumed == input.len) break;
                const sample = input[result.consumed];
                if (!std.math.isFinite(sample)) return error.InvalidSample;
                if (self.received == std.math.maxInt(u64) / 192000) return error.CounterOverflow;
                self.history[@intCast(self.received % RING)] = sample;
                self.received += 1;
                result.consumed += 1;
            }
        }
        return result;
    }

    /// Drain the centered filter's right tail using zero padding. Total output
    /// is ceil(total_input*output_rate/input_rate), with no extra delay samples.
    pub fn finish(self: *Resampler, output: []f32) Error!usize {
        if (self.input_rate == 0) return error.InvalidRate;
        self.finishing = true;
        var produced: usize = 0;
        while (produced < output.len and self.canEmit(true)) : (produced += 1)
            output[produced] = self.emit();
        return produced;
    }

    fn canEmit(self: *const Resampler, ending: bool) bool {
        if (ending) return self.emitted < (self.received * self.output_rate + self.input_rate - 1) / self.input_rate;
        const center = self.emitted * self.input_rate / self.output_rate;
        return center + HALF < self.received;
    }

    fn emit(self: *Resampler) f32 {
        const numerator = self.emitted * self.input_rate;
        const center = numerator / self.output_rate;
        const fractional = @as(f64, @floatFromInt(numerator % self.output_rate)) * PHASES / @as(f64, @floatFromInt(self.output_rate));
        const phase: usize = @intFromFloat(fractional);
        const alpha: f32 = @floatCast(fractional - @as(f64, @floatFromInt(phase)));
        var sum: @Vector(8, f32) = @splat(0);
        for (0..TAPS / 8) |block| {
            var values: @Vector(8, f32) = undefined;
            const a: @Vector(8, f32) = self.coefficients[phase][block * 8 ..][0..8].*;
            const b: @Vector(8, f32) = self.coefficients[phase + 1][block * 8 ..][0..8].*;
            inline for (0..8) |lane| {
                const index: i128 = @as(i128, center) + block * 8 + lane - (HALF - 1);
                values[lane] = if (index < 0 or index >= self.received) 0 else self.history[@intCast(@mod(index, RING))];
            }
            sum += values * (a + (b - a) * @as(@Vector(8, f32), @splat(alpha)));
        }
        self.emitted += 1;
        return @reduce(.Add, sum);
    }
};

fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    for (1..32) |i| {
        const k: f64 = @floatFromInt(i);
        term *= x * x / (4 * k * k);
        sum += term;
        if (term < sum * 1.0e-16) break;
    }
    return sum;
}

test "resampling is chunk-invariant with exact44100to16000 sample count" {
    var first: Resampler = undefined;
    var second: Resampler = undefined;
    try first.init(44100, 16000);
    try second.init(44100, 16000);
    var input: [4410]f32 = undefined;
    for (&input, 0..) |*value, index| value.* = @sin(2 * std.math.pi * 1000 * @as(f32, @floatFromInt(index)) / 44100);
    var expected: [1700]f32 = undefined;
    var actual: [1700]f32 = undefined;
    const complete = try first.process(&input, &expected);
    const count = complete.produced + try first.finish(expected[complete.produced..]);
    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < input.len) {
        const result = try second.process(input[consumed..@min(input.len, consumed + 17)], actual[produced..@min(actual.len, produced + 9)]);
        consumed += result.consumed;
        produced += result.produced;
    }
    produced += try second.finish(actual[produced..]);
    try std.testing.expectEqual(@as(usize, 1600), count);
    try std.testing.expectEqual(count, produced);
    try std.testing.expectEqualSlices(f32, expected[0..count], actual[0..produced]);
}

test "resampling suppresses12000Hz alias while preserving1000Hz" {
    var resampler: Resampler = undefined;
    var input: [4800]f32 = undefined;
    var output: [1700]f32 = undefined;
    var energies: [2]f64 = undefined;
    for ([_]f32{ 1000, 12000 }, 0..) |frequency, trial| {
        try resampler.init(48000, 16000);
        for (&input, 0..) |*value, index| value.* = @sin(2 * std.math.pi * frequency * @as(f32, @floatFromInt(index)) / 48000);
        const result = try resampler.process(&input, &output);
        const count = result.produced + try resampler.finish(output[result.produced..]);
        var energy: f64 = 0;
        for (output[64 .. count - 64]) |value| energy += @as(f64, value) * value;
        energies[trial] = energy / @as(f64, @floatFromInt(count - 128));
    }
    try std.testing.expect(energies[0] > 0.49 and energies[0] < 0.51);
    try std.testing.expect(energies[1] < 0.000001);
}

test "identity resampling is exact and tail finish adds no samples" {
    var resampler: Resampler = undefined;
    try resampler.init(16000, 16000);
    const input = [_]f32{ 0, 0.5, -0.75, 1, -1, 0.001 };
    var output: [8]f32 = @splat(99);
    const first = try resampler.process(&input, output[0..3]);
    try std.testing.expectEqual(@as(usize, 3), first.consumed);
    const second = try resampler.process(input[3..], output[3..]);
    try std.testing.expectEqual(@as(usize, 3), second.produced);
    try std.testing.expectEqualSlices(f32, &input, output[0..6]);
    try std.testing.expectEqual(@as(usize, 0), try resampler.finish(output[6..]));
    try std.testing.expectEqual(@as(f32, 99), output[6]);
    try std.testing.expectError(error.Finished, resampler.process(&input, &output));
}
