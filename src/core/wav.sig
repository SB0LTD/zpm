//! @zpm/wav — allocation-free RIFF/WAVE (PCM) container writer.
//!
//! Layer 0: pure computation, no platform deps. Turns a mono or stereo PCM16
//! sample stream into a canonical 44-byte-header WAVE file. The module owns no
//! buffers: the caller provides the output slice and the sample data, and the
//! writer only serializes little-endian integers into it.
//!
//! A WAVE file is a RIFF container with two chunks — `fmt ` (16-byte PCM
//! format block) and `data` (the raw interleaved PCM16 samples):
//!
//!   "RIFF" <u32 riff_size> "WAVE"
//!   "fmt " <u32 16> <u16 1=PCM> <u16 channels> <u32 sample_rate>
//!          <u32 byte_rate> <u16 block_align> <u16 bits=16>
//!   "data" <u32 data_size> <pcm16 samples...>
//!
//! Everything here is deterministic and bounded; there is no I/O.

pub const HEADER_BYTES: usize = 44;

pub const Error = error{
    /// The output slice cannot hold the 44-byte header plus the sample data.
    OutputTooSmall,
    /// channels must be 1 (mono) or 2 (stereo).
    InvalidChannels,
    /// sample_rate must be non-zero.
    InvalidSampleRate,
};

pub const Format = struct {
    sample_rate: u32,
    channels: u16 = 1,
    /// Bits per sample. This writer emits PCM16 only.
    pub const bits_per_sample: u16 = 16;
};

/// Total bytes a finished WAVE file will occupy for `sample_count` PCM16
/// samples (samples are per-channel-interleaved frames × channels, i.e. the
/// length of the `samples` slice passed to `write`).
pub fn fileSize(sample_count: usize) usize {
    return HEADER_BYTES + sample_count * @sizeOf(i16);
}

/// Serialize a complete WAVE file into `out` and return the written slice.
/// `samples` is the interleaved PCM16 stream (for stereo: L,R,L,R,...).
pub fn write(out: []u8, format: Format, samples: []const i16) Error![]u8 {
    if (format.channels != 1 and format.channels != 2) return error.InvalidChannels;
    if (format.sample_rate == 0) return error.InvalidSampleRate;

    const data_bytes: usize = samples.len * @sizeOf(i16);
    const total = HEADER_BYTES + data_bytes;
    if (out.len < total) return error.OutputTooSmall;

    const block_align: u16 = format.channels * (Format.bits_per_sample / 8);
    const byte_rate: u32 = format.sample_rate * block_align;

    var o: usize = 0;
    o = putBytes(out, o, "RIFF");
    o = putU32(out, o, @intCast(36 + data_bytes)); // RIFF chunk size = file - 8
    o = putBytes(out, o, "WAVE");

    o = putBytes(out, o, "fmt ");
    o = putU32(out, o, 16); // PCM fmt chunk body size
    o = putU16(out, o, 1); // audio format 1 = PCM
    o = putU16(out, o, format.channels);
    o = putU32(out, o, format.sample_rate);
    o = putU32(out, o, byte_rate);
    o = putU16(out, o, block_align);
    o = putU16(out, o, Format.bits_per_sample);

    o = putBytes(out, o, "data");
    o = putU32(out, o, @intCast(data_bytes));

    for (samples) |s| o = putI16(out, o, s);

    return out[0..o];
}

/// Write just the 44-byte header for a stream of `sample_count` samples into
/// `out` (must be ≥ HEADER_BYTES). Useful when the PCM body is streamed to a
/// file separately rather than held in one contiguous slice.
pub fn writeHeader(out: []u8, format: Format, sample_count: usize) Error![]u8 {
    if (format.channels != 1 and format.channels != 2) return error.InvalidChannels;
    if (format.sample_rate == 0) return error.InvalidSampleRate;
    if (out.len < HEADER_BYTES) return error.OutputTooSmall;

    const data_bytes: usize = sample_count * @sizeOf(i16);
    const block_align: u16 = format.channels * (Format.bits_per_sample / 8);
    const byte_rate: u32 = format.sample_rate * block_align;

    var o: usize = 0;
    o = putBytes(out, o, "RIFF");
    o = putU32(out, o, @intCast(36 + data_bytes));
    o = putBytes(out, o, "WAVE");
    o = putBytes(out, o, "fmt ");
    o = putU32(out, o, 16);
    o = putU16(out, o, 1);
    o = putU16(out, o, format.channels);
    o = putU32(out, o, format.sample_rate);
    o = putU32(out, o, byte_rate);
    o = putU16(out, o, block_align);
    o = putU16(out, o, Format.bits_per_sample);
    o = putBytes(out, o, "data");
    o = putU32(out, o, @intCast(data_bytes));
    return out[0..HEADER_BYTES];
}

// ── Little-endian serialization helpers ──

fn putBytes(out: []u8, off: usize, s: []const u8) usize {
    @memcpy(out[off..][0..s.len], s);
    return off + s.len;
}

fn putU16(out: []u8, off: usize, v: u16) usize {
    out[off] = @intCast(v & 0xff);
    out[off + 1] = @intCast((v >> 8) & 0xff);
    return off + 2;
}

fn putU32(out: []u8, off: usize, v: u32) usize {
    out[off] = @intCast(v & 0xff);
    out[off + 1] = @intCast((v >> 8) & 0xff);
    out[off + 2] = @intCast((v >> 16) & 0xff);
    out[off + 3] = @intCast((v >> 24) & 0xff);
    return off + 4;
}

fn putI16(out: []u8, off: usize, v: i16) usize {
    return putU16(out, off, @bitCast(v));
}

// ── Tests ──────────────────────────────────────────────────────────────────

const std = @import("std");

test "header fields are correct for mono 24 kHz" {
    var buf: [HEADER_BYTES + 8]u8 = undefined;
    const samples = [_]i16{ 0, 1000, -1000, 32000 };
    const wav = try write(&buf, .{ .sample_rate = 24000, .channels = 1 }, &samples);

    try std.testing.expectEqual(fileSize(samples.len), wav.len);
    try std.testing.expectEqualSlices(u8, "RIFF", wav[0..4]);
    try std.testing.expectEqualSlices(u8, "WAVE", wav[8..12]);
    try std.testing.expectEqualSlices(u8, "fmt ", wav[12..16]);
    try std.testing.expectEqualSlices(u8, "data", wav[36..40]);

    // channels=1, sample_rate=24000, bits=16 -> byte_rate=48000, block_align=2.
    try std.testing.expectEqual(@as(u8, 1), wav[22]); // channels lo
    try std.testing.expectEqual(@as(u8, 0), wav[23]);
    // data size = 4 samples * 2 bytes = 8.
    try std.testing.expectEqual(@as(u8, 8), wav[40]);

    // First sample round-trips as little-endian i16.
    try std.testing.expectEqual(@as(u8, 0), wav[44]);
    try std.testing.expectEqual(@as(u8, 0), wav[45]);
    // 1000 = 0x03E8.
    try std.testing.expectEqual(@as(u8, 0xE8), wav[46]);
    try std.testing.expectEqual(@as(u8, 0x03), wav[47]);
}

test "riff size is file length minus 8" {
    var buf: [HEADER_BYTES + 4]u8 = undefined;
    const samples = [_]i16{ 5, -5 };
    const wav = try write(&buf, .{ .sample_rate = 16000 }, &samples);
    const riff_size = @as(u32, wav[4]) | (@as(u32, wav[5]) << 8) |
        (@as(u32, wav[6]) << 16) | (@as(u32, wav[7]) << 24);
    try std.testing.expectEqual(@as(u32, @intCast(wav.len - 8)), riff_size);
}

test "invalid params are rejected" {
    var buf: [HEADER_BYTES + 4]u8 = undefined;
    const s = [_]i16{0};
    try std.testing.expectError(error.InvalidChannels, write(&buf, .{ .sample_rate = 8000, .channels = 3 }, &s));
    try std.testing.expectError(error.InvalidSampleRate, write(&buf, .{ .sample_rate = 0 }, &s));
}

test "output too small is rejected" {
    var tiny: [10]u8 = undefined;
    const s = [_]i16{ 1, 2, 3 };
    try std.testing.expectError(error.OutputTooSmall, write(&tiny, .{ .sample_rate = 8000 }, &s));
}

test "writeHeader matches write's header bytes" {
    var full: [HEADER_BYTES + 6]u8 = undefined;
    var hdr: [HEADER_BYTES]u8 = undefined;
    const s = [_]i16{ 1, 2, 3 };
    const w = try write(&full, .{ .sample_rate = 22050, .channels = 1 }, &s);
    const h = try writeHeader(&hdr, .{ .sample_rate = 22050, .channels = 1 }, s.len);
    try std.testing.expectEqualSlices(u8, w[0..HEADER_BYTES], h);
}
