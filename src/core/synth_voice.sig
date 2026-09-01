//! @zpm/synth-voice — allocation-free additive harmonic oscillator bank.
//!
//! Layer 0: pure computation, no platform deps. Converts a musical root
//! frequency + per-partial amplitudes into a phase-continuous mono PCM16
//! stream via additive sine synthesis. The bank is always internally
//! consonant: every voice is a fixed just-intonation partial of a common
//! root, so no input can detune it.
//!
//! The module owns no buffers beyond the fixed-size oscillator array embedded
//! in `Bank`; callers provide the output slice and sample rate. Coefficients
//! (targets) are set at control cadence via `setHarmonicTargets`; the actual
//! oscillator state slews toward them once per render for click-free audio.

const math = @import("math");
const sig_math = @import("sig_math");

pub const OSCILLATOR_COUNT: usize = 8;

/// Just-intonation consonant ratios of the root. Every partial is always in
/// tune with every other regardless of input:
///   0 = fundamental, 1 = octave, 2 = octave+fifth (3rd harmonic),
///   3 = 2 octaves (4th harmonic), 4 = major third, 5 = perfect fifth,
///   6 = major sixth, 7 = octave.
pub const SCALE_RATIOS = [OSCILLATOR_COUNT]f32{
    1.0, 2.0, 3.0, 4.0, 5.0 / 4.0, 3.0 / 2.0, 5.0 / 3.0, 2.0,
};

/// Equal-tempered semitone multipliers over one octave (indices 0..12).
/// Indexing by a quantized pitch keeps the root on a chromatic grid — in tune.
pub const SEMITONE = [13]f32{
    1.0,      1.059463, 1.122462, 1.189207, 1.259921, 1.334840, 1.414214,
    1.498307, 1.587401, 1.681793, 1.781797, 1.887749, 2.0,
};

pub const Oscillator = struct {
    frequency_hz: f32 = 0,
    amplitude: f32 = 0,
    phase: f32 = 0,
    target_frequency_hz: f32 = 0,
    target_amplitude: f32 = 0,
};

pub const Bank = struct {
    oscillators: [OSCILLATOR_COUNT]Oscillator = @splat(.{}),
    master_amplitude: f32 = 0,

    /// Set each oscillator's target frequency to a consonant partial of the
    /// root (clamped below `nyquist_hz` to prevent aliasing) and its target
    /// amplitude from `amps[i]`. Actual state converges via `slew`.
    pub fn setHarmonicTargets(
        self: *Bank,
        root_hz: f32,
        nyquist_hz: f32,
        amps: *const [OSCILLATOR_COUNT]f32,
    ) void {
        var i: usize = 0;
        while (i < OSCILLATOR_COUNT) : (i += 1) {
            var target_f = root_hz * SCALE_RATIOS[i];
            if (target_f > nyquist_hz) target_f = nyquist_hz;
            if (target_f < 0) target_f = 0;
            self.oscillators[i].target_frequency_hz = target_f;
            self.oscillators[i].target_amplitude = amps[i];
        }
    }

    /// Move each oscillator's actual frequency/amplitude toward its target by
    /// the given per-call fractions. Smoothing at frame cadence removes clicks
    /// from instantaneous parameter jumps.
    pub fn slew(self: *Bank, freq_slew: f32, amp_slew: f32) void {
        for (&self.oscillators) |*osc| {
            osc.frequency_hz += (osc.target_frequency_hz - osc.frequency_hz) * freq_slew;
            osc.amplitude += (osc.target_amplitude - osc.amplitude) * amp_slew;
        }
    }

    /// Render one mono frame of additive sine synthesis into `out`. Phase is
    /// maintained in [0,1) across calls; `master_amplitude` scales the mix and
    /// `math.softClip` bounds it before bounded i16 conversion. Does not slew;
    /// callers invoke `slew` once per frame first.
    pub fn renderMonoFrame(self: *Bank, out: []i16, sample_rate: u32) void {
        if (sample_rate == 0) {
            for (out) |*s| s.* = 0;
            return;
        }
        const dt: f32 = 1.0 / @as(f32, @floatFromInt(sample_rate));
        var n: usize = 0;
        while (n < out.len) : (n += 1) {
            var mix: f32 = 0;
            for (&self.oscillators) |*osc| {
                if (osc.amplitude < 0.001) {
                    // Still advance phase so a re-activation is phase-continuous.
                    osc.phase += osc.frequency_hz * dt;
                    while (osc.phase >= 1.0) osc.phase -= 1.0;
                    continue;
                }
                // sinApprox expects radians; phase is [0,1) so scale by 2π.
                mix += math.sinApprox(osc.phase * 6.28318530) * osc.amplitude;
                osc.phase += osc.frequency_hz * dt;
                while (osc.phase >= 1.0) osc.phase -= 1.0;
            }
            mix = math.softClip(mix * self.master_amplitude);
            // Bounded conversion: softClip guarantees [-1,1] → [-32000,32000].
            out[n] = @intFromFloat(sig_math.clamp(mix, -1.0, 1.0) * 32000.0);
        }
    }

    /// Silence the bank immediately (zero amplitudes and targets, keep phase).
    pub fn silence(self: *Bank) void {
        for (&self.oscillators) |*osc| {
            osc.amplitude = 0;
            osc.target_amplitude = 0;
        }
        self.master_amplitude = 0;
    }
};

/// Quantize a base root frequency onto a chromatic semitone grid using a
/// normalized pitch in [0,1] (0 → root, 1 → one octave up). Keeps the root in
/// tune regardless of the continuous input driving it.
pub fn quantizeRoot(base_hz: f32, pitch_norm01: f32) f32 {
    const p = sig_math.clamp(pitch_norm01, 0.0, 1.0);
    const idx: usize = @intFromFloat(p * 12.0 + 0.5);
    return base_hz * SEMITONE[@min(idx, 12)];
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "harmonic ratios are set correctly and clamped below nyquist" {
    var bank = Bank{};
    const amps = [_]f32{ 0.5, 0.4, 0.3, 0.2, 0.1, 0.1, 0.1, 0.1 };
    const root: f32 = 220.0;
    const nyquist: f32 = 12000.0;
    bank.setHarmonicTargets(root, nyquist, &amps);
    var i: usize = 0;
    while (i < OSCILLATOR_COUNT) : (i += 1) {
        var expected = root * SCALE_RATIOS[i];
        if (expected > nyquist) expected = nyquist;
        const diff = expected - bank.oscillators[i].target_frequency_hz;
        const ad = if (diff < 0) -diff else diff;
        if (ad > 0.01) return error.TestUnexpectedResult;
        if (bank.oscillators[i].target_amplitude != amps[i]) return error.TestUnexpectedResult;
    }
    // A tiny nyquist forces clamping on the highest partials.
    bank.setHarmonicTargets(root, 300.0, &amps);
    for (bank.oscillators) |osc| {
        if (osc.target_frequency_hz > 300.0) return error.TestUnexpectedResult;
    }
}

test "phase stays in [0,1) across many frames" {
    var bank = Bank{};
    const amps: [OSCILLATOR_COUNT]f32 = @splat(0.5);
    bank.setHarmonicTargets(4000.0, 12000.0, &amps); // high freq stresses wrapping
    bank.master_amplitude = 0.5;
    var out: [480]i16 = undefined;
    var frame: usize = 0;
    while (frame < 50) : (frame += 1) {
        bank.slew(0.5, 0.5);
        bank.renderMonoFrame(&out, 24000);
        for (bank.oscillators) |osc| {
            if (osc.phase < 0.0 or osc.phase >= 1.0) return error.TestUnexpectedResult;
        }
    }
}

test "output is bounded to [-32000, 32000]" {
    var bank = Bank{};
    const amps: [OSCILLATOR_COUNT]f32 = @splat(1.0);
    bank.setHarmonicTargets(440.0, 12000.0, &amps);
    // Force full amplitude immediately.
    for (&bank.oscillators) |*osc| osc.amplitude = 1.0;
    bank.master_amplitude = 4.0; // deliberately drive hard into the limiter
    var out: [480]i16 = undefined;
    bank.renderMonoFrame(&out, 24000);
    for (out) |s| {
        if (s > 32000 or s < -32000) return error.TestUnexpectedResult;
    }
}

test "slew converges actual toward target" {
    var bank = Bank{};
    const amps: [OSCILLATOR_COUNT]f32 = @splat(0.6);
    bank.setHarmonicTargets(330.0, 12000.0, &amps);
    var i: usize = 0;
    while (i < 500) : (i += 1) bank.slew(0.2, 0.2);
    for (bank.oscillators) |osc| {
        const fd = osc.target_frequency_hz - osc.frequency_hz;
        const afd = if (fd < 0) -fd else fd;
        if (afd > 1.0) return error.TestUnexpectedResult;
        const ad = osc.target_amplitude - osc.amplitude;
        const aad = if (ad < 0) -ad else ad;
        if (aad > 0.01) return error.TestUnexpectedResult;
    }
}

test "silence produces zero output" {
    var bank = Bank{};
    const amps: [OSCILLATOR_COUNT]f32 = @splat(0.8);
    bank.setHarmonicTargets(220.0, 12000.0, &amps);
    for (&bank.oscillators) |*osc| osc.amplitude = 0.8;
    bank.master_amplitude = 0.7;
    bank.silence();
    var out: [480]i16 = undefined;
    bank.renderMonoFrame(&out, 24000);
    for (out) |s| {
        if (s != 0) return error.TestUnexpectedResult;
    }
}

test "quantizeRoot lands on chromatic grid" {
    // pitch 0 → root exactly.
    if (quantizeRoot(220.0, 0.0) != 220.0) return error.TestUnexpectedResult;
    // pitch 1 → one octave up (SEMITONE[12] = 2.0).
    const oct = quantizeRoot(220.0, 1.0);
    if (oct < 439.9 or oct > 440.1) return error.TestUnexpectedResult;
    // Clamps out-of-range input.
    if (quantizeRoot(220.0, 5.0) != quantizeRoot(220.0, 1.0)) return error.TestUnexpectedResult;
}
