//! Allocator-free AAC-LC access-unit decoder with a normalized mono boundary.
//! Container demuxing and resampling remain independent reusable components.
const spectral = @import("aac_spectral.sig");
const filterbank = @import("aac_filterbank.sig");
const mp4 = @import("mp4.sig");
pub const Error = spectral.Error || filterbank.Error || error{ OutputCapacity, DecoderFailed };
pub const FRAME_SAMPLES: usize = 1024;

pub const Decoder = struct {
    spectral: spectral.Decoder,
    filterbanks: [2]filterbank.State = @splat(.{}),
    channel_pcm: [2][FRAME_SAMPLES]f32 = undefined,
    failed: bool = false,

    pub fn init(config: mp4.Config) Error!Decoder {
        return .{ .spectral = try spectral.Decoder.init(config) };
    }

    /// Decode one AAC-LC raw_data_block, averaging stereo into mono f32.
    /// Capacity failures do not consume the packet. Corrupt/unsupported packets
    /// poison this contiguous stream until reset; partial PCM is never emitted.
    pub fn decode(self: *Decoder, packet: []const u8, output: []f32) Error!usize {
        if (output.len < FRAME_SAMPLES) return error.OutputCapacity;
        if (self.failed) return error.DecoderFailed;
        errdefer self.failed = true;
        try self.spectral.decode(packet);
        for (0..self.spectral.config.channels) |channel| {
            const frame = &self.spectral.channels[channel];
            try self.filterbanks[channel].process(&frame.spectrum, frame.info.window_sequence, frame.info.window_shape, &self.channel_pcm[channel]);
        }
        if (self.spectral.config.channels == 1) {
            @memcpy(output[0..FRAME_SAMPLES], &self.channel_pcm[0]);
        } else {
            for (output[0..FRAME_SAMPLES], 0..) |*sample, index|
                sample.* = self.channel_pcm[0][index] * 0.5 + self.channel_pcm[1][index] * 0.5;
        }
        return FRAME_SAMPLES;
    }

    /// Begin a fresh independently encoded stream with the same configuration.
    /// Random packet seeking requires decoding the preceding overlap frame.
    pub fn reset(self: *Decoder) void {
        const config = self.spectral.config;
        self.spectral = spectral.Decoder.init(config) catch unreachable;
        for (&self.filterbanks) |*bank| bank.reset();
        self.failed = false;
    }
};

test "AAC decoder capacity failure is retryable and corrupt stream is terminal until reset" {
    const testing = @import("std").testing;
    var decoder = try Decoder.init(.{ .sample_rate = 44100, .channels = 2, .object_type = 2, .frequency_index = 4 });
    var output: [FRAME_SAMPLES]f32 = @splat(0.125);
    try testing.expectError(error.OutputCapacity, decoder.decode(&.{}, output[0..1]));
    try testing.expect(!decoder.failed);
    try testing.expectError(error.InvalidData, decoder.decode(&.{}, &output));
    try testing.expect(decoder.failed);
    try testing.expectError(error.DecoderFailed, decoder.decode(&.{0}, &output));
    try testing.expectEqual(@as(f32, 0.125), output[0]);
    decoder.reset();
    try testing.expect(!decoder.failed);
    try testing.expectEqual(@as(u64, 0), decoder.spectral.frames);
}
