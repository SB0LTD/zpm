//! Strict borrowed RIFF/WAVE PCM reader. No codecs or host audio APIs.
const std = @import("std");
pub const Error = error{ InvalidContainer, UnexpectedEof, UnsupportedFormat, InvalidFormat, InvalidSample, OutputCapacity };
pub const Encoding = enum { integer, float };
pub const Wav = struct {
    data: []const u8,
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    block_align: u16,
    encoding: Encoding,

    pub fn open(bytes: []const u8) Error!Wav {
        if (bytes.len < 12) return error.UnexpectedEof;
        if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE"))
            return error.InvalidContainer;
        const end = @as(u64, le32(bytes[4..8])) + 8;
        if (end > bytes.len or end < 12) return error.UnexpectedEof;
        var format: ?Wav = null;
        var data: ?[]const u8 = null;
        var at: usize = 12;
        while (at < end) {
            if (end - at < 8) return error.UnexpectedEof;
            const length = le32(bytes[at + 4 ..][0..4]);
            const kind = bytes[at..][0..4];
            at += 8;
            if (length > end - at) return error.UnexpectedEof;
            const payload = bytes[at..][0..length];
            at += length;
            if (length & 1 != 0) {
                if (at == end) return error.UnexpectedEof;
                at += 1;
            }
            if (std.mem.eql(u8, kind, "fmt ")) {
                if (format != null) return error.InvalidFormat;
                format = try parseFormat(payload);
            } else if (std.mem.eql(u8, kind, "data")) {
                if (data != null) return error.UnsupportedFormat;
                data = payload;
            }
        }
        var result = format orelse return error.InvalidFormat;
        result.data = data orelse return error.InvalidContainer;
        if (result.data.len % result.block_align != 0) return error.InvalidSample;
        return result;
    }

    pub fn frames(self: Wav) usize {
        return self.data.len / self.block_align;
    }

    /// Arithmetic mono downmix with unity full-scale bounds for finite PCM.
    pub fn mono(self: Wav, index: usize) Error!f32 {
        if (index >= self.frames()) return error.UnexpectedEof;
        const bytes_per_sample: usize = self.bits_per_sample / 8;
        var sum: f64 = 0;
        for (0..self.channels) |channel| {
            const at = index * self.block_align + channel * bytes_per_sample;
            const bytes = self.data[at..][0..bytes_per_sample];
            const value: f64 = switch (self.encoding) {
                .integer => switch (self.bits_per_sample) {
                    8 => (@as(f64, @floatFromInt(bytes[0])) - 128) / 128,
                    16 => @as(f64, @floatFromInt(@as(i16, @bitCast(le16(bytes))))) / 32768,
                    24 => blk: {
                        const raw = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
                        const signed: i32 = @as(i32, @bitCast(raw << 8)) >> 8;
                        break :blk @as(f64, @floatFromInt(signed)) / 8388608;
                    },
                    32 => @as(f64, @floatFromInt(@as(i32, @bitCast(le32(bytes))))) / 2147483648,
                    else => unreachable,
                },
                .float => if (self.bits_per_sample == 32) @as(f32, @bitCast(le32(bytes))) else @as(f64, @bitCast(le64(bytes))),
            };
            if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.InvalidSample;
            sum += value;
        }
        return @floatCast(sum / @as(f64, @floatFromInt(self.channels)));
    }

    pub fn readMono(self: Wav, start: usize, output: []f32) Error!usize {
        if (start > self.frames()) return error.UnexpectedEof;
        const count = @min(output.len, self.frames() - start);
        for (output[0..count], 0..) |*value, index| value.* = try self.mono(start + index);
        return count;
    }
};

fn parseFormat(bytes: []const u8) Error!Wav {
    if (bytes.len < 16) return error.InvalidFormat;
    var kind = le16(bytes[0..2]);
    const channels = le16(bytes[2..4]);
    const rate = le32(bytes[4..8]);
    const byte_rate = le32(bytes[8..12]);
    const alignment = le16(bytes[12..14]);
    const bits = le16(bytes[14..16]);
    if (kind == 0xfffe) {
        if (bytes.len < 40 or le16(bytes[16..18]) < 22 or le16(bytes[18..20]) != bits or
            !std.mem.eql(u8, bytes[26..40], &.{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 }))
            return error.UnsupportedFormat;
        kind = le16(bytes[24..26]);
    }
    const encoding: Encoding = switch (kind) {
        1 => .integer,
        3 => .float,
        else => return error.UnsupportedFormat,
    };
    if (channels == 0 or channels > 8 or rate < 8000 or rate > 384000 or
        bits == 0 or bits % 8 != 0 or alignment != channels * (bits / 8) or
        @as(u64, rate) * alignment != byte_rate) return error.InvalidFormat;
    if ((encoding == .integer and bits != 8 and bits != 16 and bits != 24 and bits != 32) or
        (encoding == .float and bits != 32 and bits != 64)) return error.UnsupportedFormat;
    return .{ .data = &.{}, .sample_rate = rate, .channels = channels, .bits_per_sample = bits, .block_align = alignment, .encoding = encoding };
}
fn le16(bytes: []const u8) u16 {
    return bytes[0] | (@as(u16, bytes[1]) << 8);
}
fn le32(bytes: []const u8) u32 {
    return le16(bytes[0..2]) | (@as(u32, le16(bytes[2..4])) << 16);
}
fn le64(bytes: []const u8) u64 {
    return le32(bytes[0..4]) | (@as(u64, le32(bytes[4..8])) << 32);
}

test "WAV stereo PCM16 downmixes samples and respects odd unknown chunks" {
    const bytes = "RIFF\x32\x00\x00\x00WAVEJUNK\x01\x00\x00\x00x\x00" ++
        "fmt \x10\x00\x00\x00\x01\x00\x02\x00\x80\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x10\x00" ++
        "data\x04\x00\x00\x00\x00\x40\x00\xc0";
    const wav = try Wav.open(bytes);
    try std.testing.expectEqual(@as(u32, 48000), wav.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), wav.frames());
    try std.testing.expectEqual(@as(f32, 0), try wav.mono(0));
    for (0..bytes.len) |length| {
        if (Wav.open(bytes[0..length])) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "WAV native integer24 and float32 decoding rejects nonfinite samples" {
    const pcm: Wav = .{ .data = &.{ 0, 0, 0x80, 0xff, 0xff, 0x7f }, .sample_rate = 16000, .channels = 1, .bits_per_sample = 24, .block_align = 3, .encoding = .integer };
    try std.testing.expectEqual(@as(f32, -1), try pcm.mono(0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), try pcm.mono(1), 0.000001);
    const floating: Wav = .{ .data = &.{ 0, 0, 0, 0x3f, 0, 0, 0x80, 0x7f }, .sample_rate = 16000, .channels = 1, .bits_per_sample = 32, .block_align = 4, .encoding = .float };
    try std.testing.expectEqual(@as(f32, 0.5), try floating.mono(0));
    try std.testing.expectError(error.InvalidSample, floating.mono(1));
}
