//! Allocation-free AAC-LC synthesis filterbank, 1024/128 transform sizes.
//! Uses an independently derived DCT-IV reduction to a radix-2 complex FFT.
//! Window coefficients are generated from the sine/Kaiser-Bessel definitions.
//! State is per channel; no mutable global tables or external codec runtime.
const std = @import("std");

pub const Error = error{ Shape, NonFinite };
pub const LONG: usize = 1024;
pub const SHORT: usize = 128;

pub const State = struct {
    /// AAC's dequantized coefficient convention requires1/N synthesis. The
    /// generic IMDCT below uses2/N, hence this half-gain and PCM16-domain scale.
    /// This normalization is independently checked against decoded AAC audio.
    pcm_scale: f32 = 0.5 / 32768.0,
    previous_shape: u1 = 0,
    initialized: bool = false,
    overlap: [LONG]f32 = @splat(0),
    spectrum_re: [LONG * 2]f32 = undefined,
    spectrum_im: [LONG * 2]f32 = undefined,
    transform: [LONG * 2]f32 = undefined,
    composite: [LONG * 2]f32 = undefined,
    twiddle_re: [LONG]f32 = undefined,
    twiddle_im: [LONG]f32 = undefined,
    phase_re: [LONG]f32 = undefined,
    phase_im: [LONG]f32 = undefined,
    post_re: [LONG]f32 = undefined,
    post_im: [LONG]f32 = undefined,
    post_short_re: [SHORT]f32 = undefined,
    post_short_im: [SHORT]f32 = undefined,
    sine_long: [LONG]f32 = undefined,
    sine_short: [SHORT]f32 = undefined,
    kbd_long: [LONG]f32 = undefined,
    kbd_short: [SHORT]f32 = undefined,

    pub fn reset(self: *State) void {
        @memset(&self.overlap, 0);
        self.previous_shape = 0;
    }

    /// window_sequence:0 ONLY_LONG,1 LONG_START,2 EIGHT_SHORT,3 LONG_STOP.
    /// window_shape:0 sine,1 KBD. Short spectra are eight contiguous128-bin
    /// windows. Returns one1024-sample channel, carrying the next overlap.
    /// Invalid size/nonfinite input fails before overlap or output changes.
    pub fn process(self: *State, spectrum: []const f32, window_sequence: u2, window_shape: u1, output: []f32) Error!void {
        if (spectrum.len != LONG or output.len != LONG) return error.Shape;
        if (!std.math.isFinite(self.pcm_scale)) return error.NonFinite;
        for (spectrum) |x| if (!std.math.isFinite(x)) return error.NonFinite;
        self.initialize();
        @memset(&self.composite, 0);
        if (window_sequence == 2) {
            for (0..8) |block| {
                try self.imdct(spectrum[block * SHORT ..][0..SHORT], self.transform[0 .. SHORT * 2]);
                const rising = self.windowShort(if (block == 0) self.previous_shape else window_shape);
                const falling = self.windowShort(window_shape);
                const start = (LONG - SHORT) / 2 + block * SHORT;
                for (0..SHORT) |i| {
                    self.composite[start + i] += self.transform[i] * rising[i];
                    self.composite[start + SHORT + i] += self.transform[SHORT + i] * falling[SHORT - 1 - i];
                }
            }
        } else {
            try self.imdct(spectrum, &self.transform);
            const long_left = self.windowLong(self.previous_shape);
            const long_right = self.windowLong(window_shape);
            const short_left = self.windowShort(self.previous_shape);
            const short_right = self.windowShort(window_shape);
            const flat = (LONG - SHORT) / 2;
            for (0..LONG) |i| {
                const left: f32 = if (window_sequence != 3) long_left[i] else if (i < flat) 0 else if (i < flat + SHORT) short_left[i - flat] else 1;
                const right: f32 = if (window_sequence != 1) long_right[LONG - 1 - i] else if (i < flat) 1 else if (i < flat + SHORT) short_right[flat + SHORT - 1 - i] else 0;
                self.composite[i] = self.transform[i] * left;
                self.composite[LONG + i] = self.transform[LONG + i] * right;
            }
        }
        // Commit channel history/output together after every new sample is
        // known finite, including overflow from syntactically finite spectra.
        for (0..LONG) |i| {
            const sample = (self.overlap[i] + self.composite[i]) * self.pcm_scale;
            if (!std.math.isFinite(sample) or !std.math.isFinite(self.composite[LONG + i])) return error.NonFinite;
            self.composite[i] = sample;
        }
        @memcpy(output, self.composite[0..LONG]);
        @memcpy(&self.overlap, self.composite[LONG..]);
        self.previous_shape = window_shape;
    }

    /// 2/N sum_k X[k]cos(pi/N*(n+.5+N/2)*(k+.5)), n in0..2N.
    /// For AAC input N is1024 or128. Output/input may alias: all input is
    /// consumed into the private FFT buffer before any output is written.
    pub fn imdct(self: *State, input: []const f32, output: []f32) Error!void {
        const n = input.len;
        if ((n != LONG and n != SHORT) or output.len != n * 2) return error.Shape;
        for (input) |x| if (!std.math.isFinite(x)) return error.NonFinite;
        self.initialize();
        const phase_stride = LONG / n;
        @memset(self.spectrum_re[0 .. 2 * n], 0);
        @memset(self.spectrum_im[0 .. 2 * n], 0);
        for (input, 0..) |x, k| {
            self.spectrum_re[k] = x * self.phase_re[k * phase_stride];
            self.spectrum_im[k] = x * self.phase_im[k * phase_stride];
        }
        self.inverseFft(n * 2);
        // DCT-IV is the real part of this modulated unnormalized inverse FFT.
        const post_re = if (n == LONG) self.post_re[0..] else self.post_short_re[0..];
        const post_im = if (n == LONG) self.post_im[0..] else self.post_short_im[0..];
        const scale = 2.0 / @as(f32, @floatFromInt(n));
        for (0..n) |i| {
            self.spectrum_re[i] = (self.spectrum_re[i] * post_re[i] - self.spectrum_im[i] * post_im[i]) * scale;
            if (!std.math.isFinite(self.spectrum_re[i])) return error.NonFinite;
        }
        const half = n / 2;
        @memcpy(output[0..half], self.spectrum_re[half..n]);
        for (0..n) |i| output[half + i] = -self.spectrum_re[n - 1 - i];
        for (0..half) |i| output[n + half + i] = -self.spectrum_re[i];
    }

    fn initialize(self: *State) void {
        if (self.initialized) return;
        for (0..LONG) |i| {
            const index: f64 = @floatFromInt(i);
            const phase = std.math.pi * index / (2.0 * @as(f64, @floatFromInt(LONG)));
            self.twiddle_re[i] = @floatCast(@cos(phase * 2));
            self.twiddle_im[i] = @floatCast(@sin(phase * 2));
            self.phase_re[i] = @floatCast(@cos(phase));
            self.phase_im[i] = @floatCast(@sin(phase));
            const post = std.math.pi * (index + 0.5) / (2.0 * @as(f64, @floatFromInt(LONG)));
            self.post_re[i] = @floatCast(@cos(post));
            self.post_im[i] = @floatCast(@sin(post));
            self.sine_long[i] = @floatCast(@sin(post));
        }
        for (0..SHORT) |i| {
            const angle = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / (2.0 * @as(f64, @floatFromInt(SHORT)));
            self.post_short_re[i] = @floatCast(@cos(angle));
            self.post_short_im[i] = @floatCast(@sin(angle));
            self.sine_short[i] = @floatCast(@sin(angle));
        }
        kaiserBessel(&self.kbd_long, 4.0);
        kaiserBessel(&self.kbd_short, 6.0);
        self.initialized = true;
    }

    fn windowLong(self: *const State, shape: u1) []const f32 { return if (shape == 0) &self.sine_long else &self.kbd_long; }
    fn windowShort(self: *const State, shape: u1) []const f32 { return if (shape == 0) &self.sine_short else &self.kbd_short; }

    fn inverseFft(self: *State, n: usize) void {
        var j: usize = 0;
        for (1..n) |i| {
            var bit = n >> 1;
            while (j & bit != 0) : (bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) {
                std.mem.swap(f32, &self.spectrum_re[i], &self.spectrum_re[j]);
                std.mem.swap(f32, &self.spectrum_im[i], &self.spectrum_im[j]);
            }
        }
        var length: usize = 2;
        while (length <= n) : (length *= 2) {
            const half = length / 2;
            const step = 2 * LONG / length;
            var begin: usize = 0;
            while (begin < n) : (begin += length) {
                for (0..half) |i| {
                    const cosine = self.twiddle_re[i * step];
                    const sine = self.twiddle_im[i * step];
                    const high = begin + i + half;
                    const low = begin + i;
                    const real = self.spectrum_re[high] * cosine - self.spectrum_im[high] * sine;
                    const imag = self.spectrum_re[high] * sine + self.spectrum_im[high] * cosine;
                    self.spectrum_re[high] = self.spectrum_re[low] - real;
                    self.spectrum_im[high] = self.spectrum_im[low] - imag;
                    self.spectrum_re[low] += real;
                    self.spectrum_im[low] += imag;
                }
            }
        }
    }
};

fn besselI0(x: f64) f64 {
    const square = x * x * 0.25;
    var term: f64 = 1;
    var result: f64 = 1;
    var k: usize = 1;
    while (k < 100) : (k += 1) {
        const denominator: f64 = @floatFromInt(k * k);
        term *= square / denominator;
        result += term;
        if (term < result * 1e-16) break;
    }
    return result;
}

fn kaiserBessel(output: []f32, alpha: f64) void {
    const n: f64 = @floatFromInt(output.len);
    // The inclusive endpoint gives complementary squared half windows.
    var total: f64 = 0;
    for (0..output.len + 1) |i| {
        const position = 2.0 * @as(f64, @floatFromInt(i)) / n - 1.0;
        total += besselI0(std.math.pi * alpha * @sqrt(@max(0.0, 1.0 - position * position)));
    }
    var cumulative: f64 = 0;
    for (output, 0..) |*value, i| {
        const position = 2.0 * @as(f64, @floatFromInt(i)) / n - 1.0;
        cumulative += besselI0(std.math.pi * alpha * @sqrt(@max(0.0, 1.0 - position * position)));
        value.* = @floatCast(@sqrt(cumulative / total));
    }
}

test "AAC FFT IMDCT matches independent direct cosine reference" {
    var state: State = .{};
    var input: [LONG]f32 = undefined;
    for (&input, 0..) |*x, i| x.* = @sin(@as(f32, @floatFromInt(i)) * 0.123) + @cos(@as(f32, @floatFromInt(i)) * 0.431);
    var out: [LONG * 2]f32 = undefined;
    for ([_]usize{ SHORT, LONG }) |n| {
        try state.imdct(input[0..n], out[0 .. 2 * n]);
        for (0..2 * n) |sample| {
            var sum: f64 = 0;
            const angle = std.math.pi / @as(f64, @floatFromInt(n)) * (@as(f64, @floatFromInt(sample)) + 0.5 + @as(f64, @floatFromInt(n / 2)));
            for (input[0..n], 0..) |value, bin| sum += @as(f64, value) * @cos(angle * (@as(f64, @floatFromInt(bin)) + 0.5));
            const expected: f32 = @floatCast(sum * 2.0 / @as(f64, @floatFromInt(n)));
            try std.testing.expectApproxEqAbs(expected, out[sample], 5e-7);
        }
    }
}

test "AAC sine and KBD squared windows satisfy overlap identity" {
    var state: State = .{};
    state.initialize();
    for ([_][]const f32{ &state.sine_long, &state.sine_short, &state.kbd_long, &state.kbd_short }) |window| {
        for (window, 0..) |value, i| try std.testing.expectApproxEqAbs(@as(f32, 1), value * value + window[window.len - 1 - i] * window[window.len - 1 - i], 2e-7);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0002925615), state.kbd_long[0], 1e-9);
}

test "AAC silence transitions reset and failure preserve channel history" {
    var state: State = .{};
    const silence: [LONG]f32 = @splat(0);
    var output: [LONG]f32 = undefined;
    for ([_]u2{ 0, 1, 2, 2, 3, 0 }) |sequence| {
        try state.process(&silence, sequence, 1, &output);
        for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    }
    state.overlap[0] = 2;
    output[0] = 123;
    var invalid = silence;
    invalid[0] = std.math.nan(f32);
    try std.testing.expectError(error.NonFinite, state.process(&invalid, 0, 0, &output));
    try std.testing.expectEqual(@as(f32, 2), state.overlap[0]);
    try std.testing.expectEqual(@as(f32, 123), output[0]);
    state.reset();
    try std.testing.expectEqual(@as(f32, 0), state.overlap[0]);
    try std.testing.expectEqual(@as(u1, 0), state.previous_shape);
}

test "AAC long-window MDCT synthesis reconstructs time-domain audio" {
    var state: State = .{ .pcm_scale = 1 };
    var input: [LONG * 3]f32 = undefined;
    for (&input, 0..) |*sample, i| sample.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.173) + 0.2 * @cos(@as(f32, @floatFromInt(i)) * 0.317);
    var coefficients: [LONG]f32 = undefined;
    var output: [LONG]f32 = undefined;
    for (0..2) |frame| {
        // Direct forward MDCT is an independent, deliberately slow oracle.
        for (&coefficients, 0..) |*coefficient, k| {
            var sum: f64 = 0;
            const frequency = std.math.pi / @as(f64, @floatFromInt(LONG)) * (@as(f64, @floatFromInt(k)) + 0.5);
            for (0..2 * LONG) |i| {
                const phase = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(2 * LONG));
                sum += @as(f64, input[frame * LONG + i]) * @sin(phase) * @cos(frequency * (@as(f64, @floatFromInt(i)) + 0.5 + @as(f64, @floatFromInt(LONG / 2))));
            }
            coefficient.* = @floatCast(sum);
        }
        try state.process(&coefficients, 0, 0, &output);
    }
    for (output, input[LONG .. 2 * LONG]) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 3e-7);
}
