//! @zpm/audio-dsp — allocation-free PCM and speech-synthesis primitives.
//!
//! The module owns no buffers and performs no I/O.  Callers provide storage,
//! sample cadence, and policy.  Coefficients are computed once per acoustic
//! segment; the sample loop is fixed work and suitable for freestanding SB0.

const math = @import("sig_math.sig");
const mem = @import("sig_mem.sig");
const testing = @import("sig_testing.sig");

pub const Error = error{
    InvalidRate,
    InvalidFrequency,
    InvalidBandwidth,
    NonFinite,
    DestinationTooSmall,
    SampleCountOverflow,
    InvalidTarget,
};

pub const PCM16_MIN: i32 = -32_768;
pub const PCM16_MAX: i32 = 32_767;

/// A stable second-order resonator.  `configure` is deliberately separate
/// from `process`: speech front ends change coefficients at phoneme cadence,
/// never at audio cadence.
pub const Resonator = struct {
    coefficient: f32 = 0,
    decay: f32 = 0,
    previous: f32 = 0,
    previous2: f32 = 0,

    pub fn configure(self: *Resonator, sample_rate: u32, frequency_hz: f32, bandwidth_hz: f32) Error!void {
        if (sample_rate < 8_000 or sample_rate > 384_000) return error.InvalidRate;
        if (!math.isFinite(frequency_hz) or frequency_hz <= 0 or
            frequency_hz >= @as(f32, @floatFromInt(sample_rate)) * 0.5)
            return error.InvalidFrequency;
        if (!math.isFinite(bandwidth_hz) or bandwidth_hz <= 0 or
            bandwidth_hz >= @as(f32, @floatFromInt(sample_rate)) * 0.5)
            return error.InvalidBandwidth;
        const rate: f32 = @floatFromInt(sample_rate);
        const radius = @exp(-math.pi * bandwidth_hz / rate);
        self.coefficient = 2.0 * radius * @cos(2.0 * math.pi * frequency_hz / rate);
        self.decay = radius * radius;
        if (!math.isFinite(self.coefficient) or !math.isFinite(self.decay))
            return error.NonFinite;
    }

    pub inline fn process(self: *Resonator, excitation: f32) f32 {
        const output = excitation + self.coefficient * self.previous - self.decay * self.previous2;
        self.previous2 = self.previous;
        self.previous = output;
        return output;
    }

    pub fn reset(self: *Resonator) void {
        self.previous = 0;
        self.previous2 = 0;
    }
};

/// Deterministic, non-cryptographic noise for unvoiced excitation.  A zero
/// seed is remapped so the generator cannot enter xorshift's locked state.
pub const Noise = struct {
    state: u32 = 0x6d2b_79f5,

    pub fn init(seed: u32) Noise {
        return .{ .state = if (seed == 0) 0x6d2b_79f5 else seed };
    }

    pub inline fn nextSigned(self: *Noise) f32 {
        var value = self.state;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        self.state = value;
        const centered = @as(i32, @bitCast(value)) >> 8;
        return @as(f32, @floatFromInt(centered)) * (1.0 / 8_388_608.0);
    }
};

pub const ClipStats = struct {
    samples: u64 = 0,
    clipped: u64 = 0,
    peak_q15: u16 = 0,
};

pub fn toPcm16(value: f32, stats: *ClipStats) Error!i16 {
    if (!math.isFinite(value)) return error.NonFinite;
    const scaled = value * 32_767.0;
    const rounded: i32 = @intFromFloat(@round(scaled));
    const bounded = @max(PCM16_MIN, @min(PCM16_MAX, rounded));
    stats.samples +|= 1;
    if (bounded != rounded) stats.clipped +|= 1;
    const magnitude: u32 = @intCast(@abs(bounded));
    stats.peak_q15 = @max(stats.peak_q15, @as(u16, @intCast(@min(magnitude, 32_767))));
    return @intCast(bounded);
}

/// Peak-normalize caller-owned PCM16 in place using integer arithmetic.
///
/// A preliminary peak scan makes the gain independent of render order, then
/// one bounded pass applies symmetric rounding. `target_peak` reserves the
/// caller-selected headroom; no sample can clip when it is at most 32767.
/// Silence remains silence. No scratch buffer, allocator, or floating-point
/// state is needed at the output boundary.
pub fn normalizePcm16(samples: []i16, target_peak: u16) Error!ClipStats {
    if (target_peak == 0 or target_peak > PCM16_MAX) return error.InvalidTarget;
    var source_peak: u32 = 0;
    for (samples) |sample| {
        const magnitude: u32 = @intCast(@abs(@as(i32, sample)));
        source_peak = @max(source_peak, magnitude);
    }
    var stats = ClipStats{ .samples = samples.len };
    if (source_peak == 0) return stats;

    const divisor: i64 = source_peak;
    const half: i64 = @divTrunc(divisor, 2);
    for (samples) |*sample| {
        const product = @as(i64, sample.*) * @as(i64, target_peak);
        const rounded = if (product >= 0)
            @divTrunc(product + half, divisor)
        else
            @divTrunc(product - half, divisor);
        const bounded = @max(@as(i64, PCM16_MIN), @min(@as(i64, PCM16_MAX), rounded));
        if (bounded != rounded) stats.clipped +|= 1;
        sample.* = @intCast(bounded);
        const magnitude: u32 = @intCast(@abs(@as(i32, sample.*)));
        stats.peak_q15 = @max(stats.peak_q15, @as(u16, @intCast(@min(magnitude, 32_767))));
    }
    return stats;
}

/// Raised-cosine edge envelope.  The envelope is exactly zero at both segment
/// boundaries, removing clicks without retaining cross-segment sample state.
pub fn edgeEnvelope(index: usize, length: usize, edge_samples: usize) f32 {
    if (length == 0) return 0;
    const edge = @min(edge_samples, length / 2);
    if (edge == 0) return 1;
    if (index < edge) {
        const phase = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(edge));
        return 0.5 - 0.5 * @cos(math.pi * phase);
    }
    const remaining = length - 1 - @min(index, length - 1);
    if (remaining < edge) {
        const phase = @as(f32, @floatFromInt(remaining)) / @as(f32, @floatFromInt(edge));
        return 0.5 - 0.5 * @cos(math.pi * phase);
    }
    return 1;
}

pub const WavPcm16 = struct {
    pub const HEADER_BYTES: usize = 44;

    pub fn encodeHeader(destination: []u8, sample_rate: u32, channels: u16, samples_per_channel: u32) Error!void {
        if (destination.len < HEADER_BYTES) return error.DestinationTooSmall;
        if (sample_rate < 8_000 or sample_rate > 384_000 or channels == 0 or channels > 8)
            return error.InvalidRate;
        const data_product = @mulWithOverflow(@as(u64, samples_per_channel), @as(u64, channels) * 2);
        if (data_product[1] != 0 or data_product[0] > math.maxInt(u32) - 36)
            return error.SampleCountOverflow;
        const data_bytes: u32 = @intCast(data_product[0]);
        @memset(destination[0..HEADER_BYTES], 0);
        destination[0..4].* = "RIFF".*;
        put32(destination, 4, 36 + data_bytes);
        destination[8..12].* = "WAVE".*;
        destination[12..16].* = "fmt ".*;
        put32(destination, 16, 16);
        put16(destination, 20, 1);
        put16(destination, 22, channels);
        put32(destination, 24, sample_rate);
        const byte_rate = @as(u64, sample_rate) * channels * 2;
        if (byte_rate > math.maxInt(u32)) return error.SampleCountOverflow;
        put32(destination, 28, @intCast(byte_rate));
        put16(destination, 32, channels * 2);
        put16(destination, 34, 16);
        destination[36..40].* = "data".*;
        put32(destination, 40, data_bytes);
    }
};

fn put16(destination: []u8, offset: usize, value: u16) void {
    destination[offset] = @truncate(value);
    destination[offset + 1] = @truncate(value >> 8);
}

fn put32(destination: []u8, offset: usize, value: u32) void {
    destination[offset] = @truncate(value);
    destination[offset + 1] = @truncate(value >> 8);
    destination[offset + 2] = @truncate(value >> 16);
    destination[offset + 3] = @truncate(value >> 24);
}



test "resonator remains finite and deterministic" {
    var left = Resonator{};
    var right = Resonator{};
    try left.configure(24_000, 700, 90);
    try right.configure(24_000, 700, 90);
    for (0..4_800) |index| {
        const excitation: f32 = if (index % 171 == 0) 0.01 else 0;
        const a = left.process(excitation);
        const b = right.process(excitation);
        try testing.expect(math.isFinite(a));
        if (b != a) return error.TestUnexpectedResult;
    }
}

test "noise is reproducible and zero seed is live" {
    var left = Noise.init(0);
    var right = Noise.init(0);
    var nonzero = false;
    for (0..64) |_| {
        const a = left.nextSigned();
        try testing.expectEqual(a, right.nextSigned());
        nonzero = nonzero or a != 0;
    }
    if (!(nonzero)) return error.TestUnexpectedResult;
}

test "PCM clipping is explicit and counted" {
    var stats = ClipStats{};
    try testing.expectEqual(@as(i16, 16_384), try toPcm16(0.5, &stats));
    try testing.expectEqual(@as(i16, 32_767), try toPcm16(2.0, &stats));
    if (stats.clipped != 1) return error.TestUnexpectedResult;
}

test "PCM peak normalization is exact bounded and silence preserving" {
    var samples = [_]i16{ -100, 50, 0, 100 };
    const stats = try normalizePcm16(&samples, 1_000);
    try testing.expectEqualSlices(i16, &.{ -1_000, 500, 0, 1_000 }, &samples);
    if (stats.samples != samples.len) return error.TestUnexpectedResult;
    if (stats.clipped != 0) return error.TestUnexpectedResult;
    if (stats.peak_q15 != 1_000) return error.TestUnexpectedResult;

    var silence: [8]i16 = @splat(0);
    const silent = try normalizePcm16(&silence, 24_576);
    if (silent.peak_q15 != 0) return error.TestUnexpectedResult;
    try testing.expectError(error.InvalidTarget, normalizePcm16(&samples, 0));
}

test "canonical PCM16 WAV header has exact byte rates" {
    var header: [WavPcm16.HEADER_BYTES]u8 = undefined;
    try WavPcm16.encodeHeader(&header, 24_000, 1, 24_000);
    if (!mem.eql(u8, "RIFF", header[0..4])) return error.TestUnexpectedResult;
    if (!mem.eql(u8, "WAVE", header[8..12])) return error.TestUnexpectedResult;
    if (header[28] != 0x80) return error.TestUnexpectedResult;
    if (header[29] != 0xbb) return error.TestUnexpectedResult;
    if (header[30] != 0x00) return error.TestUnexpectedResult;
    if (header[31] != 0x00) return error.TestUnexpectedResult;
    if (!mem.eql(u8, "data", header[36..40])) return error.TestUnexpectedResult;
}
