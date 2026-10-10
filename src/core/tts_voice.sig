//! @zpm/tts-voice — allocation-free phoneme → PCM16 narrator synthesis.
//!
//! Layer 0: pure computation, no platform deps. Turns the phoneme stream from
//! `english_phonemes` into intelligible, audiobook-style speech audio using a
//! source-filter model: a glottal source (voiced pulse train for vowels and
//! voiced consonants, filtered noise for fricatives, closure for stops) shaped
//! by two formant resonators per phone. Prosody (pitch, rate, timbre) is
//! carried in a `Voice` so a higher layer — e.g. a Qwen custom-voice model —
//! can condition the delivery without this module knowing the model exists.
//!
//! This is a real, deterministic native synthesizer, not a neural vocoder: it
//! is designed to be clear and steady for long-form reading, and to run
//! anywhere with no model, no allocator, and no I/O. When a neural voice is
//! present the caller fills a `Voice` from it; when absent, the built-in
//! default voice reads on its own.
//!
//! The module owns no buffers: the caller provides the PCM16 output slice and
//! the phoneme input. Synthesis is streamed phone-by-phone with continuous
//! glottal phase and formant state, so there are no clicks between phones.

const math = @import("math");
const sig_math = @import("sig_math");
const phon = @import("english_phonemes");

pub const Phone = phon.Phone;

/// Prosody + timbre parameters for one narrator voice. Defaults describe a
/// calm, neutral audiobook reader at 24 kHz.
pub const Voice = struct {
    /// Output sample rate in Hz.
    sample_rate: u32 = 24_000,
    /// Base glottal pitch (fundamental frequency) in Hz. ~110 = adult male,
    /// ~200 = adult female. The default sits in a warm, easy-listening range.
    pitch_hz: f32 = 118.0,
    /// Overall speaking rate multiplier. 1.0 = nominal; <1 slows, >1 speeds.
    rate: f32 = 1.0,
    /// Pitch declination across a phrase, in Hz per second (falls toward the
    /// end of a sentence for a natural cadence). Reset at long pauses.
    declination_hz_per_s: f32 = 6.0,
    /// Peak amplitude 0..1 before the soft limiter.
    gain: f32 = 0.72,
    /// Formant frequency scale (vocal-tract length). 1.0 = neutral; <1 darker
    /// / larger, >1 brighter / smaller. A custom voice tunes this for timbre.
    formant_scale: f32 = 1.0,
};

/// Nominal per-phone duration in milliseconds at rate = 1.0. Vowels are long,
/// stops are short (closure + burst), pauses are punctuation-driven.
fn baseDurationMs(p: Phone) f32 {
    return switch (p) {
        .silence => 60,
        .short_pause => 110,
        .long_pause => 300,
        // Vowels / diphthongs.
        .aa, .ae, .ah, .ao, .aw, .ay, .eh, .er, .ey, .ih, .iy, .ow, .oy, .uh, .uw => 130,
        // Nasals + liquids + glides (voiced, sustained).
        .l, .m, .n, .ng, .r, .w, .y => 75,
        // Voiced fricatives.
        .v, .dh, .z, .zh, .jh => 80,
        // Voiceless fricatives / affricate.
        .f, .th, .s, .sh, .hh, .ch => 95,
        // Stops (short).
        .b, .d, .g, .k, .p, .t => 55,
    };
}

/// The two lowest formant center frequencies (Hz) for a phone, unscaled.
/// Vowels use canonical F1/F2; consonants use characteristic resonances.
fn formants(p: Phone) [2]f32 {
    return switch (p) {
        .iy => .{ 270, 2290 },
        .ih => .{ 390, 1990 },
        .eh => .{ 530, 1840 },
        .ae => .{ 660, 1720 },
        .aa => .{ 730, 1090 },
        .ao => .{ 570, 840 },
        .ah => .{ 640, 1190 },
        .uh => .{ 440, 1020 },
        .uw => .{ 300, 870 },
        .er => .{ 490, 1350 },
        .ow => .{ 480, 940 },
        .ey => .{ 460, 2100 },
        .ay => .{ 660, 1500 },
        .aw => .{ 640, 1200 },
        .oy => .{ 490, 1100 },
        // Nasals: low F1, damped.
        .m => .{ 250, 1100 },
        .n => .{ 250, 1500 },
        .ng => .{ 250, 2000 },
        // Liquids / glides.
        .l => .{ 360, 1300 },
        .r => .{ 420, 1300 },
        .w => .{ 300, 800 },
        .y => .{ 280, 2200 },
        // Fricatives: high-frequency energy.
        .s, .z => .{ 4000, 6500 },
        .sh, .zh, .ch, .jh => .{ 2200, 3500 },
        .f, .v => .{ 1200, 3800 },
        .th, .dh => .{ 1400, 4200 },
        .hh => .{ 500, 1500 },
        // Stops (burst spectrum).
        .p, .b => .{ 800, 1500 },
        .t, .d => .{ 2500, 4000 },
        .k, .g => .{ 1800, 2200 },
        else => .{ 500, 1500 },
    };
}

const Excite = enum { voiced, unvoiced, mixed, closure, quiet };

fn excitation(p: Phone) Excite {
    return switch (p) {
        .silence, .short_pause, .long_pause => .quiet,
        .aa, .ae, .ah, .ao, .aw, .ay, .eh, .er, .ey, .ih, .iy, .ow, .oy, .uh, .uw,
        .l, .m, .n, .ng, .r, .w, .y => .voiced,
        .v, .dh, .z, .zh => .mixed,
        .jh => .mixed,
        .f, .th, .s, .sh, .hh, .ch => .unvoiced,
        .b, .d, .g => .closure,
        .p, .t, .k => .closure,
    };
}

/// A single two-pole resonator (formant filter) driven by the source.
const Resonator = struct {
    a1: f32 = 0,
    a2: f32 = 0,
    b0: f32 = 0,
    y1: f32 = 0,
    y2: f32 = 0,

    fn tune(self: *Resonator, center_hz: f32, bandwidth_hz: f32, sample_rate: f32) void {
        const r = expNeg(3.14159265 * bandwidth_hz / sample_rate);
        const theta = 2.0 * 3.14159265 * center_hz / sample_rate;
        // cos(theta) via the available sine approximation: cos x = sin(x + π/2).
        self.a1 = 2.0 * r * math.sinApprox(theta + 1.57079633);
        self.a2 = -(r * r);
        self.b0 = (1.0 - r * r);
    }

    fn step(self: *Resonator, x: f32) f32 {
        const y = self.b0 * x + self.a1 * self.y1 + self.a2 * self.y2;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

/// Streaming synthesizer state. Construct with `init`, then call `render` once
/// per phone; glottal phase, formant memory, and pitch declination persist
/// across calls for click-free, continuous speech.
pub const Synth = struct {
    voice: Voice,
    glottal_phase: f32 = 0,
    noise_state: u32 = 0x1234_5678,
    f1: Resonator = .{},
    f2: Resonator = .{},
    pitch_now: f32,

    pub fn init(voice: Voice) Synth {
        return .{ .voice = voice, .pitch_now = voice.pitch_hz };
    }

    /// Number of PCM16 samples one phone will produce at the current rate.
    pub fn phoneSamples(self: *const Synth, p: Phone) usize {
        const sr: f32 = @floatFromInt(self.voice.sample_rate);
        const ms = baseDurationMs(p) / clampRate(self.voice.rate);
        const n = ms * sr / 1000.0;
        return @intFromFloat(@max(1.0, n));
    }

    /// Total sample count for a whole phoneme sequence (for buffer sizing).
    pub fn totalSamples(self: *const Synth, phones: []const Phone) usize {
        var total: usize = 0;
        for (phones) |p| total += self.phoneSamples(p);
        return total;
    }

    /// Render one phone into `out` (which must be ≥ phoneSamples(p)); returns
    /// the number of samples written. Advances internal state for continuity.
    pub fn render(self: *Synth, p: Phone, out: []i16) usize {
        const sr: f32 = @floatFromInt(self.voice.sample_rate);
        const count = @min(self.phoneSamples(p), out.len);
        const kind = excitation(p);

        // Reset declination and drop to base pitch at a full stop.
        if (p == .long_pause) self.pitch_now = self.voice.pitch_hz;

        const cf = formants(p);
        const scale = clampPos(self.voice.formant_scale);
        // Fricatives/stops get wider bandwidths (noisier), vowels narrower.
        const bw: f32 = switch (kind) {
            .voiced => 90,
            .mixed => 140,
            .unvoiced => 260,
            else => 200,
        };
        self.f1.tune(cf[0] * scale, bw, sr);
        self.f2.tune(cf[1] * scale, bw * 1.4, sr);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const env = window(i, count);
            var src: f32 = 0;
            switch (kind) {
                .quiet, .closure => src = 0,
                .voiced => src = self.glottalPulse(sr),
                .unvoiced => src = self.noise() * 0.5,
                .mixed => src = self.glottalPulse(sr) * 0.7 + self.noise() * 0.3,
            }
            // A brief burst at the release of a stop.
            if (kind == .closure and i * 5 >= count * 4) {
                src = self.noise() * 0.6;
            }
            var s = self.f1.step(src) * 0.7 + self.f2.step(src) * 0.5;
            s = math.softClip(s * self.voice.gain * env);
            out[i] = @intFromFloat(sig_math.clamp(s, -1.0, 1.0) * 31000.0);
        }

        // Gentle pitch declination across voiced material.
        if (kind == .voiced or kind == .mixed) {
            const dt = @as(f32, @floatFromInt(count)) / sr;
            self.pitch_now = @max(60.0, self.pitch_now - self.voice.declination_hz_per_s * dt);
        }
        return count;
    }

    /// Render an entire phoneme sequence into `out`, returning the written
    /// slice. Truncates to `out` if it cannot hold the whole utterance.
    pub fn renderSequence(self: *Synth, phones: []const Phone, out: []i16) []i16 {
        var off: usize = 0;
        for (phones) |p| {
            if (off >= out.len) break;
            off += self.render(p, out[off..]);
        }
        return out[0..off];
    }

    fn glottalPulse(self: *Synth, sr: f32) f32 {
        self.glottal_phase += self.pitch_now / sr;
        while (self.glottal_phase >= 1.0) self.glottal_phase -= 1.0;
        // A Rosenberg-style asymmetric pulse approximated with two sinusoids;
        // richer in harmonics than a pure sine, so formants have something to
        // shape.
        const ph = self.glottal_phase;
        const p1 = math.sinApprox(ph * 6.28318530);
        const p2 = math.sinApprox(ph * 12.5663706) * 0.35;
        return p1 + p2;
    }

    fn noise(self: *Synth) f32 {
        // xorshift32 white noise in [-1, 1).
        var x = self.noise_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.noise_state = x;
        const u: f32 = @floatFromInt(x & 0xffff);
        return u / 32768.0 - 1.0;
    }
};

/// Cosine-ish attack/decay envelope so each phone fades in and out (no clicks).
fn window(i: usize, count: usize) f32 {
    if (count < 2) return 1.0;
    const edge = @max(@as(usize, 1), count / 8);
    if (i < edge) {
        return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge));
    }
    if (i >= count - edge) {
        return @as(f32, @floatFromInt(count - i)) / @as(f32, @floatFromInt(edge));
    }
    return 1.0;
}

/// e^(-x) for x ≥ 0, used for the resonator pole radius (0 < result ≤ 1).
/// A short Taylor series is ample here: bandwidth/sr keeps x small (< ~0.1).
fn expNeg(x: f32) f32 {
    const t = sig_math.clamp(x, 0.0, 8.0);
    // e^-t = 1/e^t; e^t via truncated series with range reduction by halving.
    var n: f32 = t;
    var scale: f32 = 1.0;
    while (n > 0.5) : (n *= 0.5) scale *= 2.0;
    // e^n for small n.
    const en = 1.0 + n + n * n * 0.5 + n * n * n * (1.0 / 6.0) + n * n * n * n * (1.0 / 24.0);
    var et: f32 = en;
    var s = scale;
    while (s > 1.0) : (s *= 0.5) et *= et;
    return 1.0 / et;
}

fn clampRate(r: f32) f32 {
    return sig_math.clamp(r, 0.25, 4.0);
}
fn clampPos(v: f32) f32 {
    return sig_math.clamp(v, 0.25, 4.0);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const std = @import("std");

test "phoneSamples scales with rate" {
    var s = Synth.init(.{ .sample_rate = 24000, .rate = 1.0 });
    const n1 = s.phoneSamples(.aa);
    var s2 = Synth.init(.{ .sample_rate = 24000, .rate = 2.0 });
    const n2 = s2.phoneSamples(.aa);
    // Twice the rate → about half the samples.
    try std.testing.expect(n2 < n1);
    try std.testing.expect(n2 > 0);
}

test "voiced phone produces non-silent bounded audio" {
    var s = Synth.init(.{});
    var buf: [4096]i16 = undefined;
    const n = s.render(.iy, &buf);
    try std.testing.expect(n > 0);
    var peak: i16 = 0;
    for (buf[0..n]) |v| {
        try std.testing.expect(v <= 31000 and v >= -31000);
        const a: i16 = if (v < 0) -v else v;
        if (a > peak) peak = a;
    }
    try std.testing.expect(peak > 500); // actually made sound
}

test "pauses are (near) silent" {
    var s = Synth.init(.{});
    var buf: [8192]i16 = undefined;
    const n = s.render(.long_pause, &buf);
    try std.testing.expect(n > 0);
    for (buf[0..n]) |v| try std.testing.expectEqual(@as(i16, 0), v);
}

test "renderSequence fills and bounds output" {
    var s = Synth.init(.{});
    const phones = [_]Phone{ .hh, .eh, .l, .ow, .long_pause };
    var buf: [1 << 16]i16 = undefined;
    const wav = s.renderSequence(&phones, &buf);
    try std.testing.expect(wav.len == s.totalSamples(&phones));
}

test "phonemize then synthesize a word end to end" {
    var phones = phon.Phones{};
    try phon.phonemize("hello", &phones);
    var s = Synth.init(.{});
    var buf: [1 << 17]i16 = undefined;
    const wav = s.renderSequence(phones.values[0..phones.len], &buf);
    try std.testing.expect(wav.len > 0);
}
