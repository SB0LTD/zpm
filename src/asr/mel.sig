//! Qwen3-ASR/Whisper 128-bin frontend: true 400-point STFT, periodic Hann,
//! centered reflection, Slaney area-normalized filters and model log scaling.
//! computeBounded owns no global state and uses caller-provided storage.
//! Reference: transformers v4.57.6 WhisperFeatureExtractor.
//! The older compute/computeFrame API returns uncentered natural-log energy;
//! existing prototype consumers normalize that output themselves.
const math = @import("std").math;
pub const SAMPLE_RATE: u32 = 16000;
pub const N_FFT: usize = 400;
pub const FFT_SIZE: usize = N_FFT;
pub const HOP_LENGTH: usize = 160;
pub const N_MELS: usize = 128;
pub const N_FREQ_BINS: usize = N_FFT / 2 + 1;
pub const FMIN: f32 = 0;
pub const FMAX: f32 = 8000;
pub const MAX_AUDIO_SAMPLES: usize = 30 * SAMPLE_RATE;
pub const MAX_FRAMES: usize = MAX_AUDIO_SAMPLES / HOP_LENGTH;
pub const Error = error{ AudioTooShort, AudioTooLong, OutputTooSmall, InvalidSample, AliasedBuffers };

const Complex = struct { re: f64 = 0, im: f64 = 0 };
pub const Workspace = struct {
    windowed: [N_FFT]f64 = @splat(0),
    spectrum: [N_FFT]Complex = @splat(.{}),
    power: [N_FREQ_BINS]f64 = @splat(0),
};

const window = blk: {
    @setEvalBranchQuota(10000);
    var result: [N_FFT]f64 = undefined;
    for (&result, 0..) |*value, i|
        value.* = 0.5 - 0.5 * @cos(2 * math.pi * @as(f64, @floatFromInt(i)) / N_FFT);
    break :blk result;
};
const twiddles = blk: {
    @setEvalBranchQuota(10000);
    var result: [N_FFT]Complex = undefined;
    for (&result, 0..) |*value, i| {
        const angle = -2 * math.pi * @as(f64, @floatFromInt(i)) / N_FFT;
        value.* = .{ .re = @cos(angle), .im = @sin(angle) };
    }
    break :blk result;
};
fn hzToMel(hz: f64) f64 {
    return if (hz < 1000) hz * 3 / 200 else 15 + @log(hz / 1000) * 27 / @log(@as(f64, 6.4));
}
fn melToHz(value: f64) f64 {
    return if (value < 15) value * 200 / 3 else 1000 * @exp((value - 15) * @log(@as(f64, 6.4)) / 27);
}
const filters = blk: {
    @setEvalBranchQuota(500000);
    var points: [N_MELS + 2]f64 = undefined;
    for (&points, 0..) |*point, i|
        point.* = melToHz(hzToMel(8000) * @as(f64, @floatFromInt(i)) / (N_MELS + 1));
    var result: [N_MELS][N_FREQ_BINS]f64 = undefined;
    for (&result, 0..) |*filter, m| {
        const left = points[m];
        const center = points[m + 1];
        const right = points[m + 2];
        const normalization = 2 / (right - left);
        for (filter, 0..) |*value, k| {
            const hz = @as(f64, @floatFromInt(k)) * SAMPLE_RATE / N_FFT;
            value.* = @max(0, @min((hz - left) / (center - left), (right - hz) / (right - center))) * normalization;
        }
    }
    break :blk result;
};

// Cooley-Tukey with fixed 5,5,2,2,2,2 radices. Comptime n bounds call depth
// to seven and all butterfly storage to at most five complex numbers.
fn transform(comptime n: usize, out: *[n]Complex, input: [*]const f64, stride: usize) void {
    if (n == 1) {
        out[0] = .{ .re = input[0] };
        return;
    }
    const radix = if (n % 5 == 0) 5 else 2;
    const part = n / radix;
    for (0..radix) |j|
        transform(part, @ptrCast(out[j * part ..][0..part]), input + j * stride, stride * radix);
    for (0..part) |k| {
        var values: [radix]Complex = undefined;
        for (&values, 0..) |*value, j| value.* = out[j * part + k];
        for (0..radix) |p| {
            var sum = Complex{};
            for (values, 0..) |value, j| {
                const factor = twiddles[(j * (k + p * part) * (N_FFT / n)) % N_FFT];
                sum.re += value.re * factor.re - value.im * factor.im;
                sum.im += value.re * factor.im + value.im * factor.re;
            }
            out[k + p * part] = sum;
        }
    }
}
fn energies(work: *Workspace, out: *[N_MELS]f32, log10: bool) void {
    transform(N_FFT, &work.spectrum, &work.windowed, 1);
    for (&work.power, 0..) |*power, k| {
        const value = work.spectrum[k];
        power.* = value.re * value.re + value.im * value.im;
    }
    for (out, 0..) |*value, m| {
        var energy: f64 = 0;
        for (work.power, filters[m]) |power, weight| energy += power * weight;
        const logarithm = @log(@max(energy, 1e-10));
        value.* = @floatCast(if (log10) logarithm / @log(@as(f64, 10)) else logarithm);
    }
}

/// Frame count for centered STFT with its final frame discarded.
pub fn boundedFrames(n_samples: usize) usize {
    return n_samples / HOP_LENGTH;
}

/// Output is frame-major [n_samples/160,128], fully normalized for the model.
/// Reject short reflect-padding inputs, nonfinite PCM and overlapping buffers
/// before writing output. Longer streams must use explicit bounded segments.
pub fn computeBounded(audio: []const f32, output: []f32, work: *Workspace) Error!usize {
    if (audio.len <= N_FFT / 2) return error.AudioTooShort;
    if (audio.len > MAX_AUDIO_SAMPLES) return error.AudioTooLong;
    const frames = boundedFrames(audio.len);
    const elements = frames * N_MELS;
    if (output.len < elements) return error.OutputTooSmall;
    const source = @intFromPtr(audio.ptr);
    const destination = @intFromPtr(output.ptr);
    if ((source <= destination and destination - source < audio.len * @sizeOf(f32)) or
        (destination < source and source - destination < elements * @sizeOf(f32))) return error.AliasedBuffers;
    for (audio) |sample| if (!math.isFinite(sample)) return error.InvalidSample;
    var maximum: f32 = -math.inf(f32);
    for (0..frames) |frame| {
        const center: isize = @intCast(frame * HOP_LENGTH);
        for (&work.windowed, 0..) |*value, i| {
            var position = center + @as(isize, @intCast(i)) - N_FFT / 2;
            if (position < 0) position = -position;
            if (position >= audio.len) position = 2 * @as(isize, @intCast(audio.len)) - 2 - position;
            value.* = @as(f64, audio[@intCast(position)]) * window[i];
        }
        const row: *[N_MELS]f32 = @ptrCast(output[frame * N_MELS ..][0..N_MELS]);
        energies(work, row, true);
        for (row) |value| maximum = @max(maximum, value);
    }
    for (output[0..elements]) |*value| value.* = (@max(value.*, maximum - 8) + 4) / 4;
    return frames;
}

// Legacy prototype API: natural log, no centering, externally sized output.
// New model consumers must use computeBounded rather than normalize twice.
var legacy_work: Workspace = .{};
pub fn numFrames(n_samples: usize) usize {
    return if (n_samples < N_FFT) 0 else (n_samples - N_FFT) / HOP_LENGTH + 1;
}
pub fn computeFrame(audio: [*]const f32, out: *[N_MELS]f32) void {
    for (&legacy_work.windowed, 0..) |*value, i| value.* = @as(f64, audio[i]) * window[i];
    energies(&legacy_work, out, false);
}
pub fn compute(audio: [*]const f32, n_samples: usize, out_mel: [*]f32) usize {
    const frames = numFrames(n_samples);
    for (0..frames) |frame|
        computeFrame(audio + frame * HOP_LENGTH, @ptrCast(out_mel + frame * N_MELS));
    return frames;
}
