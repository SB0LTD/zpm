//! Local integration oracle for real downloaded media. No production entrypoint.
const std = @import("std");
const mp4 = @import("mp4.sig");
const aac = @import("aac_spectral.sig");
const filterbank = @import("aac_filterbank.sig");
const Handle = *anyopaque;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileSizeEx(Handle, *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(Handle, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn MapViewOfFile(Handle, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;

var decoder: aac.Decoder = undefined;
var banks: [2]filterbank.State = @splat(.{});
var pcm: [2][1024]f32 = undefined;
var interleaved: [2048]f32 = undefined;

pub fn main() !void {
    const path = std.unicode.utf8ToUtf16LeStringLiteral("C:/Just-Things/Projects/gotliv/.gotliv/efficiency-public-audio.m4a");
    const file = CreateFileW(path, 0x80000000, 1, null, 3, 0x80, null);
    if (@intFromPtr(file) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(file);
    var size: i64 = 0;
    if (GetFileSizeEx(file, &size) == 0 or size <= 0) return error.SizeFailed;
    const mapping = CreateFileMappingW(file, null, 2, 0, 0, null) orelse return error.MappingFailed;
    defer _ = CloseHandle(mapping);
    const address = MapViewOfFile(mapping, 4, 0, 0, 0) orelse return error.MappingFailed;
    defer _ = UnmapViewOfFile(address);
    const bytes = @as([*]const u8, @ptrCast(address))[0..@intCast(size)];
    var demux = try mp4.Demux.open(bytes);
    // The first complete fragment boundary must not masquerade as the full
    // declared track. This was a real partial-download shape in earlier work.
    var truncated = try mp4.Demux.open(bytes[0..167444]);
    var boundary_rejected = false;
    while (true) {
        const next = truncated.next() catch |err| {
            if (err != error.InvalidDuration) return err;
            boundary_rejected = true;
            break;
        };
        if (next == null) break;
    }
    if (!boundary_rejected) return error.AcceptedTruncatedTrack;
    decoder = try aac.Decoder.init(demux.config);
    const output = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("C:/Just-Things/Projects/gotliv/.gotliv/aac-native-first30s.f32"), 0x40000000, 1, null, 2, 0x80, null);
    if (@intFromPtr(output) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(output);
    const metadata = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("C:/Just-Things/Projects/gotliv/.gotliv/aac-native-frames.csv"), 0x40000000, 1, null, 2, 0x80, null);
    if (@intFromPtr(metadata) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(metadata);
    var count: u64 = 0;
    var payload_bytes: u64 = 0;
    var duration: u64 = 0;
    var hash: u64 = 0xcbf29ce484222325;
    while (try demux.next()) |packet| {
        if (count < 1300) {
            decoder.decode(packet.bytes) catch |err| {
                std.debug.print("AAC ERROR packet={d} dts={d} size={d} stage={s} bit={d}: {s}\n", .{ count, packet.dts, packet.bytes.len, @tagName(decoder.stage), decoder.failure_bit, @errorName(err) });
                return err;
            };
            for (0..demux.config.channels) |channel| {
                const frame = &decoder.channels[channel];
                try banks[channel].process(&frame.spectrum, frame.info.window_sequence, frame.info.window_shape, &pcm[channel]);
            }
            var noise_bands: usize = 0;
            var intensity_bands: usize = 0;
            var tns_filters: usize = 0;
            for (decoder.channels[0..demux.config.channels]) |channel| {
                for (channel.codebooks) |group| for (group) |codebook| {
                    if (codebook == 13) noise_bands += 1;
                    if (codebook >= 14) intensity_bands += 1;
                };
                for (channel.tns.count) |filters| tns_filters += filters;
            }
            var line_buffer: [256]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buffer, "{d},{d},{d},{d},{d},{d}\n", .{ count, decoder.channels[0].info.window_sequence, decoder.channels[0].info.window_shape, noise_bands, intensity_bands, tns_filters });
            var meta_written: u32 = 0;
            if (WriteFile(metadata, line.ptr, @intCast(line.len), &meta_written, null) == 0 or meta_written != line.len) return error.WriteFailed;
            for (0..1024) |i| for (0..demux.config.channels) |channel| {
                interleaved[i * demux.config.channels + channel] = pcm[channel][i];
            };
            const data = std.mem.sliceAsBytes(interleaved[0 .. 1024 * @as(usize, demux.config.channels)]);
            var written: u32 = 0;
            if (WriteFile(output, data.ptr, @intCast(data.len), &written, null) == 0 or written != data.len) return error.WriteFailed;
        }
        if (packet.index != count or packet.dts != duration) return error.TimestampMismatch;
        count += 1;
        duration += packet.duration;
        payload_bytes += packet.bytes.len;
        for (packet.bytes) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
    }
    std.debug.print("rate={d} channels={d} packets={d} payload_bytes={d} duration_samples={d} fnv64={x}\n", .{ demux.config.sample_rate, demux.config.channels, count, payload_bytes, duration, hash });
}
