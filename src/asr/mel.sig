// @zpm/asr — Mel Spectrogram Module
// Computes log-mel spectrogram from 16kHz PCM audio.
//
// Architecture:
//   PCM f32 samples (16kHz)
//   → Windowed frames (25ms = 400 samples, 10ms hop = 160 samples)
//   → Hann window
//   → FFT (512-point, radix-2 Cooley-Tukey)
//   → Power spectrum (magnitude squared)
//   → Mel filterbank (128 triangular filters)
//   → Log energy (ln(max(energy, 1e-10)))
//
// Qwen3-ASR specific parameters:
//   - n_fft: 400 (padded to 512 for radix-2)
//   - hop_length: 160
//   - n_mels: 128
//   - sample_rate: 16000
//   - fmin: 0 Hz, fmax: 8000 Hz (Nyquist)
//
// Zero allocations. All buffers are comptime-sized statics.

const math = @import("std").math;

// ── Constants ──
pub const SAMPLE_RATE: u32 = 16000;
pub const N_FFT: usize = 400;
pub const FFT_SIZE: usize = 512; // Next power of 2 for radix-2
pub const HOP_LENGTH: usize = 160;
pub const N_MELS: usize = 128;
pub const FMIN: f32 = 0.0;
pub const FMAX: f32 = 8000.0; // Nyquist for 16kHz

/// Number of mel frames produced from n_samples of audio
pub fn numFrames(n_samples: usize) usize {
    if (n_samples < N_FFT) return 0;
    return (n_samples - N_FFT) / HOP_LENGTH + 1;
}

// ── Hann Window (comptime-generated) ──
const hann_window: [N_FFT]f32 = blk: {
    @setEvalBranchQuota(2000);
    var w: [N_FFT]f32 = undefined;
    for (0..N_FFT) |i| {
        const x = 2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N_FFT - 1));
        w[i] = 0.5 * (1.0 - @cos(x));
    }
    break :blk w;
};

// ── Mel Filterbank (comptime-generated) ──
// 128 triangular filters from 0Hz to 8000Hz in mel scale.
// Each filter is defined by center frequency; we store the filter weights
// as a 128 × 257 matrix (257 = FFT_SIZE/2 + 1 frequency bins).
const N_FREQ_BINS: usize = FFT_SIZE / 2 + 1; // 257

fn hzToMel(hz: f32) f32 {
    return 2595.0 * math.log10(1.0 + hz / 700.0);
}

fn melToHz(mel_val: f32) f32 {
    // 10^(mel_val/2595) using explicit formula to avoid comptime math.pow branch limits
    const x = mel_val / 2595.0;
    // 10^x = e^(x * ln10)
    return 700.0 * (@exp(x * 2.302585093) - 1.0);
}

// Mel filter centers (130 points: 128 filters + 2 boundary points)
const mel_points: [N_MELS + 2]f32 = blk: {
    @setEvalBranchQuota(5000);
    const mel_low = hzToMel(FMIN);
    const mel_high = hzToMel(FMAX);
    var pts: [N_MELS + 2]f32 = undefined;
    for (0..N_MELS + 2) |i| {
        const mel_val = mel_low + (mel_high - mel_low) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N_MELS + 1));
        pts[i] = melToHz(mel_val);
    }
    break :blk pts;
};

// Convert Hz to FFT bin index
fn hzToBin(hz: f32) f32 {
    return hz * @as(f32, FFT_SIZE) / @as(f32, SAMPLE_RATE);
}

// Mel filterbank weights [N_MELS][N_FREQ_BINS] — comptime-generated
const mel_filterbank: [N_MELS][N_FREQ_BINS]f32 = blk: {
    @setEvalBranchQuota(500000);
    var fb: [N_MELS][N_FREQ_BINS]f32 = undefined;
    for (0..N_MELS) |m| {
        const f_left = hzToBin(mel_points[m]);
        const f_center = hzToBin(mel_points[m + 1]);
        const f_right = hzToBin(mel_points[m + 2]);
        for (0..N_FREQ_BINS) |k| {
            const f_k = @as(f32, @floatFromInt(k));
            if (f_k < f_left or f_k > f_right) {
                fb[m][k] = 0.0;
            } else if (f_k <= f_center) {
                const denom = f_center - f_left;
                fb[m][k] = if (denom > 0.0) (f_k - f_left) / denom else 0.0;
            } else {
                const denom = f_right - f_center;
                fb[m][k] = if (denom > 0.0) (f_right - f_k) / denom else 0.0;
            }
        }
    }
    break :blk fb;
};

// ── FFT (Radix-2 Cooley-Tukey, in-place, 512-point) ──
// Twiddle factors are comptime-generated for maximum performance.

const twiddle_re: [FFT_SIZE / 2]f32 = blk: {
    @setEvalBranchQuota(2000);
    var tw: [FFT_SIZE / 2]f32 = undefined;
    for (0..FFT_SIZE / 2) |k| {
        tw[k] = @cos(-2.0 * math.pi * @as(f32, @floatFromInt(k)) / @as(f32, FFT_SIZE));
    }
    break :blk tw;
};

const twiddle_im: [FFT_SIZE / 2]f32 = blk: {
    @setEvalBranchQuota(2000);
    var tw: [FFT_SIZE / 2]f32 = undefined;
    for (0..FFT_SIZE / 2) |k| {
        tw[k] = @sin(-2.0 * math.pi * @as(f32, @floatFromInt(k)) / @as(f32, FFT_SIZE));
    }
    break :blk tw;
};

// Bit-reversal permutation table (comptime)
const bit_rev: [FFT_SIZE]u16 = blk: {
    @setEvalBranchQuota(50000);
    const log2n = 9; // log2(512)
    var rev: [FFT_SIZE]u16 = undefined;
    for (0..FFT_SIZE) |i| {
        var x: u16 = @intCast(i);
        var r: u16 = 0;
        for (0..log2n) |_| {
            r = (r << 1) | (x & 1);
            x >>= 1;
        }
        rev[i] = r;
    }
    break :blk rev;
};

/// Compute in-place FFT on re/im arrays of length FFT_SIZE.
fn fft512(re: *[FFT_SIZE]f32, im: *[FFT_SIZE]f32) void {
    // Bit-reversal permutation
    for (0..FFT_SIZE) |i| {
        const j: usize = bit_rev[i];
        if (i < j) {
            const tmp_r = re[i]; re[i] = re[j]; re[j] = tmp_r;
            const tmp_i = im[i]; im[i] = im[j]; im[j] = tmp_i;
        }
    }

    // Butterfly stages
    var stage_size: usize = 2;
    while (stage_size <= FFT_SIZE) : (stage_size *= 2) {
        const half = stage_size / 2;
        const tw_step = FFT_SIZE / stage_size;

        var group: usize = 0;
        while (group < FFT_SIZE) : (group += stage_size) {
            var k: usize = 0;
            while (k < half) : (k += 1) {
                const tw_idx = k * tw_step;
                const wr = twiddle_re[tw_idx];
                const wi = twiddle_im[tw_idx];

                const idx_a = group + k;
                const idx_b = group + k + half;

                const br = re[idx_b];
                const bi = im[idx_b];

                // Complex multiply: (br + bi*j) * (wr + wi*j)
                const tr = br * wr - bi * wi;
                const ti = br * wi + bi * wr;

                re[idx_b] = re[idx_a] - tr;
                im[idx_b] = im[idx_a] - ti;
                re[idx_a] = re[idx_a] + tr;
                im[idx_a] = im[idx_a] + ti;
            }
        }
    }
}

// ── Public API ──

/// Scratch buffers for mel computation (file-scope statics, zero-init).
/// One mel spectrogram computation can be in progress at a time.
var fft_re: [FFT_SIZE]f32 = @splat(0.0);
var fft_im: [FFT_SIZE]f32 = @splat(0.0);
var power_spectrum: [N_FREQ_BINS]f32 = @splat(0.0);

/// Compute one mel frame from audio samples.
/// Input: audio pointer starting at the frame's position.
/// Output: 128-element mel vector written to `out`.
pub fn computeFrame(audio: [*]const f32, out: *[N_MELS]f32) void {
    // Apply Hann window and zero-pad to FFT_SIZE
    for (0..FFT_SIZE) |i| {
        if (i < N_FFT) {
            fft_re[i] = audio[i] * hann_window[i];
        } else {
            fft_re[i] = 0.0;
        }
        fft_im[i] = 0.0;
    }

    // FFT
    fft512(&fft_re, &fft_im);

    // Power spectrum: |X[k]|^2 for k = 0..N_FREQ_BINS-1
    for (0..N_FREQ_BINS) |k| {
        power_spectrum[k] = fft_re[k] * fft_re[k] + fft_im[k] * fft_im[k];
    }

    // Apply mel filterbank and compute log energy
    for (0..N_MELS) |m| {
        var energy: f32 = 0.0;
        for (0..N_FREQ_BINS) |k| {
            energy += mel_filterbank[m][k] * power_spectrum[k];
        }
        // Log-mel energy with floor to avoid log(0)
        out[m] = @log(@max(energy, 1e-10));
    }
}

/// Compute full mel spectrogram for an audio buffer.
/// Writes `n_frames * N_MELS` f32 values into `out_mel`.
/// Returns the number of frames computed.
pub fn compute(audio: [*]const f32, n_samples: usize, out_mel: [*]f32) usize {
    const n_frames = numFrames(n_samples);
    var frame: usize = 0;
    while (frame < n_frames) : (frame += 1) {
        const offset = frame * HOP_LENGTH;
        const out_ptr: *[N_MELS]f32 = @ptrCast(@alignCast(out_mel + frame * N_MELS));
        computeFrame(audio + offset, out_ptr);
    }
    return n_frames;
}

// ── Tests ──
const testing = @import("std").testing;

test "numFrames basic" {
    // 16000 samples (1 second) → (16000 - 400) / 160 + 1 = 98 frames
    try testing.expectEqual(numFrames(16000), 98);
}

test "computeFrame silence" {
    // Silence should produce very low mel energies
    var silence: [N_FFT]f32 = @splat(0.0);
    var mel_out: [N_MELS]f32 = undefined;
    computeFrame(&silence, &mel_out);
    // All should be log(1e-10) ≈ -23.03
    for (0..N_MELS) |m| {
        try testing.expect(mel_out[m] < -20.0);
    }
}

test "computeFrame sine" {
    // 1kHz sine at 16kHz sample rate should excite specific mel bins
    var sine: [N_FFT]f32 = undefined;
    for (0..N_FFT) |i| {
        sine[i] = @sin(2.0 * math.pi * 1000.0 * @as(f32, @floatFromInt(i)) / 16000.0);
    }
    var mel_out: [N_MELS]f32 = undefined;
    computeFrame(&sine, &mel_out);
    // Find the peak bin — should be somewhere in the lower-mid range for 1kHz
    var max_val: f32 = mel_out[0];
    var max_bin: usize = 0;
    for (1..N_MELS) |m| {
        if (mel_out[m] > max_val) { max_val = mel_out[m]; max_bin = m; }
    }
    // 1kHz should peak around mel bin 30-50 (rough estimate)
    try testing.expect(max_bin > 20 and max_bin < 60);
}
