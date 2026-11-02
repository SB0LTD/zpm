//! LFM3-Audio hearing front end: 16 kHz mono samples to 128-bin log-mel
//! frames, allocation-free and streamable.
//!
//! Numerics mirror llama.cpp's mtmd_audio_preprocessor_lfm3a: a periodic Hann
//! window over 400 samples every 160, no centering, the clip zero-padded on
//! the right so no sample is dropped, |FFT|^2 through Slaney-scale area-
//! normalized filters, log10 with a 1e-12 floor, then (x + 4) / 4. The FFT is
//! ggml's radix-2 recursion over a 400-entry f32 sine/cosine table with the
//! odd 25-point remainder done as a plain DFT, so frames agree to f32 rounding.
//! Tables are comptime constants; callers own every buffer.

const math = @import("std").math;

pub const SAMPLE_RATE: u32 = 16_000;
pub const WINDOW: usize = 400;
pub const HOP: usize = 160;
pub const MELS: usize = 128;
pub const BINS: usize = WINDOW / 2 + 1;

pub const Error = error{ InvalidLength, OutputTooSmall };

/// Frames of a clip of `samples` samples: the clip is padded with zeros so
/// the last frame ends on its last sample (a clip shorter than one window is
/// padded to one window).
pub fn frameCount(samples: usize) usize {
    if (samples == 0) return 0;
    return (paddedLength(samples) - WINDOW) / HOP + 1;
}

/// Samples after right padding: the first `samples` are the clip, the rest zero.
pub fn paddedLength(samples: usize) usize {
    if (samples <= WINDOW) return WINDOW;
    return samples + (HOP - (samples - WINDOW) % HOP) % HOP;
}

const sin_table = trig(true);
const cos_table = trig(false);

fn trig(comptime sine: bool) [WINDOW]f32 {
    @setEvalBranchQuota(100_000);
    var table: [WINDOW]f32 = undefined;
    for (&table, 0..) |*value, i| {
        // sinf((float) theta) with theta in double, as fill_sin_cos_table.
        const theta: f32 = @floatCast(2.0 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, WINDOW));
        value.* = if (sine) @sin(theta) else @cos(theta);
    }
    return table;
}

const hann = blk: {
    @setEvalBranchQuota(100_000);
    var table: [WINDOW]f32 = undefined;
    for (&table, 0..) |*value, i| {
        const angle: f32 = @floatCast(2.0 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, WINDOW));
        value.* = @floatCast(0.5 * (1.0 - @as(f64, @cos(angle))));
    }
    break :blk table;
};

fn hzToMel(hz: f64) f64 {
    const log_step = @log(6.4) / 27.0;
    return if (hz < 1000.0) hz * 3.0 / 200.0 else 15.0 + @log(hz / 1000.0) / log_step;
}

fn melToHz(mel: f64) f64 {
    const log_step = @log(6.4) / 27.0;
    return if (mel < 15.0) mel * 200.0 / 3.0 else 1000.0 * @exp((mel - 15.0) * log_step);
}

/// Slaney filters (fmin 0, fmax 8 kHz) in f64 then rounded to f32, as
/// fill_mel_filterbank_matrix computes them.
const filters = blk: {
    @setEvalBranchQuota(2_000_000);
    var points: [MELS + 2]f64 = undefined;
    const top = hzToMel(@as(f64, SAMPLE_RATE) / 2.0);
    for (&points, 0..) |*point, i| point.* = melToHz(top * @as(f64, @floatFromInt(i)) / @as(f64, MELS + 1));
    var table: [MELS][BINS]f32 = undefined;
    const bin_hz = @as(f64, SAMPLE_RATE) / @as(f64, WINDOW);
    for (&table, 0..) |*row, m| {
        const left = points[m];
        const center = points[m + 1];
        const right = points[m + 2];
        const norm = 2.0 / @max(1e-30, right - left);
        for (row, 0..) |*weight, k| {
            const f = @as(f64, @floatFromInt(k)) * bin_hz;
            var w: f64 = 0;
            if (f >= left and f <= center) {
                w = (f - left) / @max(1e-30, center - left);
            } else if (f > center and f <= right) {
                w = (right - f) / @max(1e-30, right - center);
            }
            weight.* = @floatCast(w * norm);
        }
    }
    break :blk table;
};

/// Scratch for one frame: the windowed input with ggml's recursion space and
/// the interleaved complex output.
pub const Workspace = struct {
    input: [WINDOW * 2]f32 = @splat(0),
    output: [WINDOW * 8]f32 = @splat(0),
};

/// One frame from exactly WINDOW samples (zero beyond the clip's end).
pub fn frame(samples: *const [WINDOW]f32, out: *[MELS]f32, work: *Workspace) void {
    for (work.input[0..WINDOW], samples, hann) |*value, sample, weight| value.* = weight * sample;
    fft(work.input[0..].ptr, WINDOW, work.output[0..].ptr);
    var power: [BINS]f32 = undefined;
    for (&power, 0..) |*value, j| {
        const re = work.output[2 * j];
        const im = work.output[2 * j + 1];
        value.* = re * re + im * im;
    }
    for (out, &filters) |*value, *row| {
        // Four products summed in f32 per step into an f64 total, as the
        // unrolled loop of log_mel_spectrogram_worker_thread.
        var sum: f64 = 0;
        var k: usize = 0;
        while (k < BINS - 3) : (k += 4) {
            sum += power[k] * row[k] + power[k + 1] * row[k + 1] + power[k + 2] * row[k + 2] + power[k + 3] * row[k + 3];
        }
        while (k < BINS) : (k += 1) sum += power[k] * row[k];
        sum = @max(sum, 1e-12);
        const level: f32 = @floatCast(@log10(sum));
        value.* = (level + 4.0) / 4.0;
    }
}

/// Every frame of a whole clip, frame-major: `out[f * MELS + m]`.
pub fn compute(samples: []const f32, out: []f32, work: *Workspace) Error!usize {
    const count = frameCount(samples.len);
    if (count == 0) return error.InvalidLength;
    if (out.len < count * MELS) return error.OutputTooSmall;
    var window: [WINDOW]f32 = undefined;
    for (0..count) |index| {
        const start = index * HOP;
        const available = if (start < samples.len) @min(WINDOW, samples.len - start) else 0;
        @memcpy(window[0..available], samples[start..][0..available]);
        @memset(window[available..], 0);
        frame(&window, out[index * MELS ..][0..MELS], work);
    }
    return count;
}

/// ggml's fft_impl<false, true>: real input `in` of length n (with n more
/// floats of scratch behind it), interleaved complex output with 6n floats of
/// recursion space behind the first 2n.
fn fft(in: [*]f32, n: usize, out: [*]f32) void {
    if (n == 1) {
        out[0] = in[0];
        out[1] = 0;
        return;
    }
    const half = n / 2;
    if (n % 2 == 1) return dft(in, n, out);
    const even = in + n;
    for (0..half) |i| even[i] = in[2 * i];
    const even_fft = out + 2 * n;
    fft(even, half, even_fft);
    const odd = even;
    for (0..half) |i| odd[i] = in[2 * i + 1];
    const odd_fft = even_fft + n;
    fft(odd, half, odd_fft);
    const step = WINDOW / n;
    for (0..half) |k| {
        const re = cos_table[k * step];
        const im = -sin_table[k * step];
        const re_odd = odd_fft[2 * k];
        const im_odd = odd_fft[2 * k + 1];
        out[2 * k] = even_fft[2 * k] + re * re_odd - im * im_odd;
        out[2 * k + 1] = even_fft[2 * k + 1] + re * im_odd + im * re_odd;
        out[2 * (k + half)] = even_fft[2 * k] - re * re_odd + im * im_odd;
        out[2 * (k + half) + 1] = even_fft[2 * k + 1] - re * im_odd - im * re_odd;
    }
}

/// dft_impl<false, true>: table index (k * n * step) mod WINDOW.
fn dft(in: [*]const f32, n: usize, out: [*]f32) void {
    const step = WINDOW / n;
    for (0..n) |k| {
        var re: f32 = 0;
        var im: f32 = 0;
        for (0..n) |j| {
            const index = (k * j * step) % WINDOW;
            re += in[j] * cos_table[index];
            im += -1.0 * in[j] * sin_table[index];
        }
        out[2 * k] = re;
        out[2 * k + 1] = im;
    }
}

const testing = @import("std").testing;

test "frame counts follow the right-padded clip" {
    try testing.expectEqual(@as(usize, 0), frameCount(0));
    try testing.expectEqual(@as(usize, 1), frameCount(1));
    try testing.expectEqual(@as(usize, 1), frameCount(400));
    try testing.expectEqual(@as(usize, 2), frameCount(401));
    try testing.expectEqual(@as(usize, 2), frameCount(560));
    try testing.expectEqual(@as(usize, 3), frameCount(561));
    // One second: 16000 samples pad to 16080, 99 frames.
    try testing.expectEqual(@as(usize, 16_080), paddedLength(16_000));
    try testing.expectEqual(@as(usize, 99), frameCount(16_000));
}

test "the mixed-radix FFT equals a direct f64 DFT" {
    var work = Workspace{};
    var state: u32 = 3;
    var reference: [WINDOW]f64 = undefined;
    for (work.input[0..WINDOW], &reference) |*value, *copy| {
        state = state *% 1664525 +% 1013904223;
        value.* = @as(f32, @floatFromInt(state >> 8)) / 16777216.0 - 0.5;
        copy.* = value.*;
    }
    fft(work.input[0..].ptr, WINDOW, work.output[0..].ptr);
    for (0..BINS) |k| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (reference, 0..) |value, j| {
            const angle = -2.0 * math.pi * @as(f64, @floatFromInt(k * j % WINDOW)) / WINDOW;
            re += value * @cos(angle);
            im += value * @sin(angle);
        }
        try testing.expect(@abs(work.output[2 * k] - re) < 2e-4);
        try testing.expect(@abs(work.output[2 * k + 1] - im) < 2e-4);
    }
}

test "a 1 kHz tone peaks in the filter around 1 kHz and silence hits the floor" {
    var samples: [1600]f32 = undefined;
    for (&samples, 0..) |*value, i| value.* = 0.5 * @sin(2.0 * math.pi * 1000.0 * @as(f32, @floatFromInt(i)) / SAMPLE_RATE);
    var work = Workspace{};
    var out: [10 * MELS]f32 = undefined;
    const count = try compute(&samples, &out, &work);
    try testing.expectEqual(@as(usize, 9), count);
    var best: usize = 0;
    for (out[3 * MELS ..][0..MELS], 0..) |value, m| {
        if (value > out[3 * MELS + best]) best = m;
    }
    // Filter centers near 1 kHz: Slaney mel 15 is 1000 Hz, mel bins are
    // spaced (mel(8 kHz) / 129) apart.
    const center = melToHz(hzToMel(8000.0) * @as(f64, @floatFromInt(best + 1)) / (MELS + 1));
    try testing.expect(@abs(center - 1000.0) < 80.0);
    @memset(&samples, 0);
    _ = try compute(&samples, &out, &work);
    for (out[0 .. count * MELS]) |value| try testing.expectEqual(@as(f32, (-12.0 + 4.0) / 4.0), value);
    try testing.expectError(error.OutputTooSmall, compute(&samples, out[0 .. 7 * MELS], &work));
}
