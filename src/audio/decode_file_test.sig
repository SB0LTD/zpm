//! Local end-to-end native AAC/fMP4→mono16kWAV validation and speed harness.
//! The hardcoded source is a complete downloaded lesson, not an ASR fixture.
const std = @import("std");
const mp4 = @import("mp4.sig");
const aac = @import("aac.sig");
const resample = @import("resample.sig");
const Handle = *anyopaque;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileSizeEx(Handle, *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(Handle, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn MapViewOfFile(Handle, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn SetFilePointerEx(Handle, i64, ?*i64, u32) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
var decoder: aac.Decoder = undefined;
var resampler: resample.Resampler = undefined;
var mono: [1024]f32 = undefined;
var converted: [2048]f32 = undefined;

fn write(file: Handle, bytes: []const u8) !void {
    var written: u32 = 0;
    if (WriteFile(file, bytes.ptr, @intCast(bytes.len), &written, null) == 0 or written != bytes.len) return error.WriteFailed;
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    for (0..4) |i| bytes[offset + i] = @truncate(value >> @as(u5, @intCast(i * 8)));
}
pub fn main() !void {
    const started = GetTickCount64();
    const input = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("C:/Just-Things/Projects/gotliv/.gotliv/efficiency-public-audio.m4a"), 0x80000000, 1, null, 3, 0x80, null);
    if (@intFromPtr(input) == std.math.maxInt(usize)) return error.OpenFailed;
    defer _ = CloseHandle(input);
    var size: i64 = 0;
    if (GetFileSizeEx(input, &size) == 0 or size <= 0) return error.SizeFailed;
    const mapping = CreateFileMappingW(input, null, 2, 0, 0, null) orelse return error.MappingFailed;
    defer _ = CloseHandle(mapping);
    const address = MapViewOfFile(mapping, 4, 0, 0, 0) orelse return error.MappingFailed;
    defer _ = UnmapViewOfFile(address);
    const bytes = @as([*]const u8, @ptrCast(address))[0..@intCast(size)];
    var demux = try mp4.Demux.open(bytes);
    decoder = try aac.Decoder.init(demux.config);
    try resampler.init(demux.config.sample_rate, 16000);
    const partial = std.unicode.utf8ToUtf16LeStringLiteral("C:/Just-Things/Projects/gotliv/.gotliv/aac-native-complete-mono16k.wav.part");
    const final = std.unicode.utf8ToUtf16LeStringLiteral("C:/Just-Things/Projects/gotliv/.gotliv/aac-native-complete-mono16k.wav");
    const output = CreateFileW(partial, 0x40000000, 1, null, 2, 0x80, null);
    if (@intFromPtr(output) == std.math.maxInt(usize)) return error.OpenFailed;
    var output_open = true;
    defer if (output_open) {
        _ = CloseHandle(output);
    };
    var header: [44]u8 = @splat(0);
    try write(output, &header);
    var packets: u64 = 0;
    var samples: u64 = 0;
    var noise_frames: u64 = 0;
    var tns_frames: u64 = 0;
    while (try demux.next()) |packet| {
        if (packet.duration != 1024 or packet.dts != packets * 1024) return error.InvalidTimestamp;
        const count = decoder.decode(packet.bytes, &mono) catch |err| {
            std.debug.print("AAC failure packet={d} bit={d} stage={s}: {s}\n", .{ packets, decoder.spectral.failure_bit, @tagName(decoder.spectral.stage), @errorName(err) });
            return err;
        };
        var noise = false;
        var tns = false;
        for (decoder.spectral.channels[0..demux.config.channels]) |channel| {
            for (channel.codebooks) |group| for (group) |book| {
                noise = noise or book == 13;
            };
            for (channel.tns.count) |filters| tns = tns or filters != 0;
        }
        if (noise) noise_frames += 1;
        if (tns) tns_frames += 1;
        var used: usize = 0;
        while (used < count) {
            const result = try resampler.process(mono[used..count], &converted);
            used += result.consumed;
            samples += result.produced;
            try write(output, std.mem.sliceAsBytes(converted[0..result.produced]));
        }
        packets += 1;
        if (packets % 20000 == 0) std.debug.print("decoded {d} packets, {d}ms\n", .{ packets, GetTickCount64() - started });
    }
    while (true) {
        const count = try resampler.finish(&converted);
        if (count == 0) break;
        samples += count;
        try write(output, std.mem.sliceAsBytes(converted[0..count]));
    }
    const expected = (packets * 1024 * 16000 + demux.config.sample_rate - 1) / demux.config.sample_rate;
    if (samples != expected or samples > std.math.maxInt(u32) / 4 - 36) return error.InvalidSampleCount;
    header[0..4].* = "RIFF".*;
    put32(&header, 4, @intCast(36 + samples * 4));
    header[8..12].* = "WAVE".*;
    header[12..16].* = "fmt ".*;
    put32(&header, 16, 16);
    header[20] = 3;
    header[22] = 1;
    put32(&header, 24, 16000);
    put32(&header, 28, 64000);
    header[32] = 4;
    header[34] = 32;
    header[36..40].* = "data".*;
    put32(&header, 40, @intCast(samples * 4));
    if (SetFilePointerEx(output, 0, null, 0) == 0) return error.SeekFailed;
    try write(output, &header);
    if (CloseHandle(output) == 0) return error.CloseFailed;
    output_open = false;
    if (MoveFileExW(partial, final, 1) == 0) return error.PublishFailed;
    std.debug.print("PASS native AAC→mono16k: packets={d} samples={d} pns_frames={d} tns_frames={d} elapsed_ms={d}\n", .{ packets, samples, noise_frames, tns_frames, GetTickCount64() - started });
}
