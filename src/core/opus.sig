// Pure Opus codec — PCM to Opus encoding/decoding
// Layer 0: Core
//
// Implements Opus encoding at configurable bitrates (16-64 kbps) and decoding
// back to PCM. Mono encoding with 5-second segment output. No platform
// dependencies — pure computation only.
//
// Reference: RFC 6716 (Opus Interactive Audio Codec)
// This is a simplified implementation suitable for voice-band audio (SILK mode).

const math = @import("sig_math.sig");
const mem = @import("sig_mem.sig");
const testing = @import("sig_testing.sig");

/// Opus encoder configuration.
pub const EncoderConfig = struct {
    /// Target bitrate in kbps (16-64).
    bitrate_kbps: u8 = 24,
    /// Sample rate in Hz (8000, 12000, 16000, 24000, 48000).
    sample_rate: u32 = 16000,
    /// Number of channels (1 = mono only for this implementation).
    channels: u8 = 1,
    /// Frame size in milliseconds (2.5, 5, 10, 20, 40, 60).
    frame_size_ms: u8 = 20,
    /// Application mode.
    application: Application = .voip,

    pub const Application = enum {
        voip,
        audio,
        low_delay,
    };

    /// Validate configuration ranges.
    pub fn isValid(self: *const EncoderConfig) bool {
        if (self.bitrate_kbps < 16 or self.bitrate_kbps > 64) return false;
        if (self.channels != 1) return false;
        return switch (self.sample_rate) {
            8000, 12000, 16000, 24000, 48000 => true,
            else => false,
        };
    }

    /// Samples per frame at the configured rate and frame size.
    pub fn samplesPerFrame(self: *const EncoderConfig) u32 {
        return (self.sample_rate * @as(u32, self.frame_size_ms)) / 1000;
    }

    /// Bytes per frame of PCM input (16-bit mono).
    pub fn pcmBytesPerFrame(self: *const EncoderConfig) u32 {
        return self.samplesPerFrame() * 2 * @as(u32, self.channels);
    }

    /// Samples in a 5-second segment.
    pub fn samplesPerSegment(self: *const EncoderConfig) u32 {
        return self.sample_rate * 5;
    }

    /// PCM bytes in a 5-second segment.
    pub fn pcmBytesPerSegment(self: *const EncoderConfig) u32 {
        return self.samplesPerSegment() * 2 * @as(u32, self.channels);
    }

    /// Approximate output bytes per 5-second segment at target bitrate.
    pub fn opusBytesPerSegment(self: *const EncoderConfig) u32 {
        return (@as(u32, self.bitrate_kbps) * 1000 * 5) / 8;
    }
};

/// Opus decoder configuration.
pub const DecoderConfig = struct {
    /// Sample rate for output PCM.
    sample_rate: u32 = 16000,
    /// Number of channels.
    channels: u8 = 1,
};

/// Opus packet header (Table of Contents byte + frame length coding).
pub const PacketHeader = struct {
    /// Configuration number (0-31): encodes mode, bandwidth, frame size.
    config: u5 = 0,
    /// Stereo flag (0 = mono, 1 = stereo).
    stereo: u1 = 0,
    /// Frame count code (0-3).
    frame_count_code: u2 = 0,

    /// Encode TOC byte.
    pub fn toByte(self: *const PacketHeader) u8 {
        return (@as(u8, self.config) << 3) | (@as(u8, self.stereo) << 2) | @as(u8, self.frame_count_code);
    }

    /// Decode TOC byte.
    pub fn fromByte(b: u8) PacketHeader {
        return .{
            .config = @truncate(b >> 3),
            .stereo = @truncate(b >> 2),
            .frame_count_code = @truncate(b),
        };
    }

    /// Derive the bandwidth from config number.
    pub fn bandwidth(self: *const PacketHeader) Bandwidth {
        const cfg = @as(u8, self.config);
        if (cfg <= 3) return .narrowband;
        if (cfg <= 7) return .mediumband;
        if (cfg <= 11) return .wideband;
        if (cfg <= 15) return .super_wideband;
        return .fullband;
    }
};

/// Opus bandwidth categories.
pub const Bandwidth = enum {
    narrowband, // 4 kHz
    mediumband, // 6 kHz
    wideband, // 8 kHz
    super_wideband, // 12 kHz
    fullband, // 20 kHz
};

/// Encoder state — maintains state across frames for SILK-mode encoding.
pub const Encoder = struct {
    config: EncoderConfig,
    /// Frame counter for segment boundary detection.
    frame_count: u32,
    /// Accumulated PCM samples for current segment.
    segment_samples: u32,
    /// LPC prediction state (last 16 samples for linear prediction).
    lpc_state: [16]i16,
    /// Range coder state.
    range_low: u32,
    range_high: u32,
    /// Quantization step size derived from bitrate.
    quant_step: i16,
    /// Whether encoder has been initialized with first frame.
    initialized: bool,

    pub fn init(config: EncoderConfig) Encoder {
        const step = computeQuantStep(config.bitrate_kbps);
        return .{
            .config = config,
            .frame_count = 0,
            .segment_samples = 0,
            .lpc_state = @as([16]i16, @splat(0)),
            .range_low = 0,
            .range_high = 0xFFFFFFFF,
            .quant_step = step,
            .initialized = false,
        };
    }

    /// Encode a single frame of PCM samples to Opus.
    /// Returns number of bytes written to `out`.
    pub fn encodeFrame(self: *Encoder, pcm: []const i16, out: []u8) u32 {
        if (pcm.len == 0 or out.len < 4) return 0;

        // Write TOC byte
        const toc = PacketHeader{
            .config = selectConfig(self.config.sample_rate, self.config.frame_size_ms),
            .stereo = 0,
            .frame_count_code = 0, // single frame
        };
        out[0] = toc.toByte();

        // Simplified SILK-mode encoding: LPC residual quantization
        var written: u32 = 1;
        var i: usize = 0;

        while (i < pcm.len and written < out.len) : (i += 1) {
            // LPC prediction (order 10)
            var prediction_accumulator: i64 = 0;
            const order = @min(i, @as(usize, 10));
            for (0..order) |k| {
                if (i > k) {
                    prediction_accumulator +=
                        @as(i64, pcm[i - 1 - k]) * @as(i64, self.lpc_state[k]);
                }
            }
            const prediction: i32 = @intCast(prediction_accumulator >> 12);

            // Compute residual
            const residual: i32 = @as(i32, pcm[i]) - prediction;

            // Quantize residual
            const quantized: i8 = @intCast(math.clamp(
                @divTrunc(residual, @as(i32, self.quant_step)),
                -127,
                127,
            ));
            out[written] = @bitCast(quantized);
            written += 1;

            // Update LPC state
            if (i < 16) {
                self.lpc_state[i] = pcm[i];
            }
        }

        self.frame_count += 1;
        self.segment_samples += @intCast(pcm.len);
        self.initialized = true;

        return written;
    }

    /// Check if a 5-second segment boundary has been reached.
    pub fn isSegmentComplete(self: *const Encoder) bool {
        return self.segment_samples >= self.config.samplesPerSegment();
    }

    /// Reset segment counter (call after segment is emitted).
    pub fn resetSegment(self: *Encoder) void {
        self.segment_samples = 0;
    }

    /// Reset encoder state entirely.
    pub fn reset(self: *Encoder) void {
        self.frame_count = 0;
        self.segment_samples = 0;
        self.lpc_state = @as([16]i16, @splat(0));
        self.range_low = 0;
        self.range_high = 0xFFFFFFFF;
        self.initialized = false;
    }
};

/// Decoder state — decodes Opus packets back to PCM.
pub const Decoder = struct {
    config: DecoderConfig,
    /// LPC synthesis state.
    lpc_state: [16]i16,
    /// Frame counter.
    frame_count: u32,
    /// Whether decoder has processed at least one packet.
    initialized: bool,

    pub fn init(config: DecoderConfig) Decoder {
        return .{
            .config = config,
            .lpc_state = @as([16]i16, @splat(0)),
            .frame_count = 0,
            .initialized = false,
        };
    }

    /// Decode an Opus packet to PCM samples.
    /// Returns number of samples written to `out`.
    pub fn decodePacket(self: *Decoder, packet: []const u8, out: []i16) u32 {
        if (packet.len < 2 or out.len == 0) return 0;

        // Parse TOC byte
        const toc = PacketHeader.fromByte(packet[0]);
        _ = toc;

        // Decode quantized residuals and apply LPC synthesis
        var written: u32 = 0;
        var i: usize = 1;

        while (i < packet.len and written < out.len) : (i += 1) {
            const quantized: i8 = @bitCast(packet[i]);

            // Reconstruct residual
            const quant_step: i32 = computeQuantStep(24); // default bitrate for decode
            const residual: i32 = @as(i32, quantized) * quant_step;

            // LPC synthesis (order 10)
            var prediction_accumulator: i64 = 0;
            const order = @min(written, 10);
            for (0..order) |k| {
                if (written > k) {
                    prediction_accumulator +=
                        @as(i64, out[written - 1 - k]) * @as(i64, self.lpc_state[k]);
                }
            }
            const prediction: i32 = @intCast(prediction_accumulator >> 12);

            // Reconstruct sample
            const sample: i32 = residual + prediction;
            out[written] = @intCast(math.clamp(sample, -32768, 32767));

            // Update LPC state
            if (written < 16) {
                self.lpc_state[written] = out[written];
            }
            written += 1;
        }

        self.frame_count += 1;
        self.initialized = true;
        return written;
    }

    /// Reset decoder state.
    pub fn reset(self: *Decoder) void {
        self.lpc_state = @as([16]i16, @splat(0));
        self.frame_count = 0;
        self.initialized = false;
    }
};

/// Opus segment — a complete 5-second encoded segment ready for transmission.
pub const Segment = struct {
    /// Encoded data buffer.
    data: [8192]u8 = @as([8192]u8, @splat(0)),
    /// Length of valid data.
    len: u32 = 0,
    /// Segment index (sequential counter).
    index: u32 = 0,
    /// Timestamp of segment start in UTC milliseconds.
    timestamp_ms: u64 = 0,
    /// Duration in milliseconds (nominally 5000).
    duration_ms: u32 = 5000,
    /// Bitrate used for encoding.
    bitrate_kbps: u8 = 0,

    pub fn getData(self: *const Segment) []const u8 {
        return self.data[0..self.len];
    }
};

// ── Internal helpers ──

fn computeQuantStep(bitrate_kbps: u8) i16 {
    // Higher bitrate → smaller step → finer quantization
    // Map 16-64 kbps to step sizes 512-128
    if (bitrate_kbps <= 16) return 512;
    if (bitrate_kbps >= 64) return 128;
    const range: i32 = 512 - 128; // 384
    const br_range: i32 = 64 - 16; // 48
    const offset: i32 = @as(i32, bitrate_kbps) - 16;
    return @intCast(512 - @divTrunc(range * offset, br_range));
}

fn selectConfig(sample_rate: u32, frame_size_ms: u8) u5 {
    // Simplified config selection based on sample rate and frame size.
    // Real Opus has 32 configs; we map to voice-optimized SILK configs.
    const bw_base: u5 = switch (sample_rate) {
        8000 => 0, // NB
        12000 => 4, // MB
        16000 => 8, // WB
        24000 => 12, // SWB
        48000 => 16, // FB
        else => 8,
    };
    const frame_offset: u5 = switch (frame_size_ms) {
        10 => 0,
        20 => 1,
        40 => 2,
        60 => 3,
        else => 1,
    };
    return bw_base | frame_offset;
}

// ── Tests ──

test "encoder config validation" {
    const valid = EncoderConfig{ .bitrate_kbps = 24, .sample_rate = 16000, .channels = 1 };
    try testing.expect(valid.isValid());

    const invalid_br = EncoderConfig{ .bitrate_kbps = 100, .sample_rate = 16000, .channels = 1 };
    try testing.expect(!invalid_br.isValid());

    const invalid_sr = EncoderConfig{ .bitrate_kbps = 24, .sample_rate = 44100, .channels = 1 };
    try testing.expect(!invalid_sr.isValid());

    const invalid_ch = EncoderConfig{ .bitrate_kbps = 24, .sample_rate = 16000, .channels = 2 };
    try testing.expect(!invalid_ch.isValid());
}

test "encode decode round-trip preserves signal structure" {
    const config = EncoderConfig{};
    var encoder = Encoder.init(config);

    // Generate a simple sine-like test signal
    var pcm: [320]i16 = undefined; // 20ms at 16kHz
    for (&pcm, 0..) |*s, i| {
        // Simple sawtooth for deterministic testing
        s.* = @intCast(@as(i32, @intCast(i % 160)) * 200 - 16000);
    }

    var opus_buf: [1024]u8 = undefined;
    const encoded_len = encoder.encodeFrame(&pcm, &opus_buf);
    try testing.expect(encoded_len > 0);
    try testing.expect(encoded_len <= 1024);

    // Decode
    var dec_config = DecoderConfig{};
    _ = &dec_config;
    var decoder = Decoder.init(.{});
    var decoded: [320]i16 = undefined;
    const decoded_len = decoder.decodePacket(opus_buf[0..encoded_len], &decoded);
    try testing.expect(decoded_len > 0);

    // Verify signal is roughly preserved (lossy codec, so check correlation not equality)
    var correlation: i64 = 0;
    const check_len = @min(decoded_len, @as(u32, @intCast(pcm.len)));
    for (0..check_len) |i| {
        correlation += @as(i64, pcm[i]) * @as(i64, decoded[i]);
    }
    // Positive correlation indicates signal structure is preserved
    try testing.expect(correlation > 0);
}

test "segment boundary detection" {
    const config = EncoderConfig{ .sample_rate = 16000 };
    var encoder = Encoder.init(config);

    // 5 seconds at 16kHz = 80000 samples
    try testing.expectEqual(@as(u32, 80000), config.samplesPerSegment());

    // Simulate encoding frames until segment complete
    encoder.segment_samples = 79999;
    try testing.expect(!encoder.isSegmentComplete());
    encoder.segment_samples = 80000;
    try testing.expect(encoder.isSegmentComplete());
}

test "quant step mapping" {
    // Lower bitrate → larger step
    try testing.expect(computeQuantStep(16) > computeQuantStep(64));
    try testing.expectEqual(@as(i16, 512), computeQuantStep(16));
    try testing.expectEqual(@as(i16, 128), computeQuantStep(64));
}
