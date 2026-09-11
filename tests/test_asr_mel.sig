//! Numerical parity against the model's actual Hugging Face frontend.
const std = @import("std");
const mel = @import("asr_mel");
var work: mel.Workspace = .{};
var input: [mel.MAX_AUDIO_SAMPLES + 1]f32 = undefined;
var output: [mel.MAX_FRAMES * mel.N_MELS + 1]f32 = undefined;
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.AsrMelContractFailed;
}
fn float(bytes: []const u8, i: usize) f32 {
    const value = bytes[i * 4 ..][0..4];
    return @bitCast(@as(u32, value[0]) | (@as(u32, value[1]) << 8) | (@as(u32, value[2]) << 16) | (@as(u32, value[3]) << 24));
}
pub fn main(init: std.process.Init) !void {
    var maximum_error: f32 = 0;
    inline for (.{ "silence", "short-dc", "impulses", "tones", "noise", "quiet", "ramp" }) |name| {
        const audio = @embedFile("fixtures/asr-mel/" ++ name ++ ".pcm");
        const expected = @embedFile("fixtures/asr-mel/" ++ name ++ ".mel");
        const samples = audio.len / 4;
        const elements = expected.len / 4;
        for (0..samples) |i| input[i] = float(audio, i);
        output[elements] = 12345;
        const frames = try mel.computeBounded(input[0..samples], output[0..elements], &work);
        try check(frames * mel.N_MELS == elements);
        try check(output[elements] == 12345);
        for (output[0..elements], 0..) |actual, i| {
            const delta = @abs(actual - float(expected, i));
            maximum_error = @max(maximum_error, delta);
            if (delta > 0.00002) {
                var message: [192]u8 = undefined;
                const line = try std.fmt.bufPrint(&message, "FAIL {s} element={d} actual={d} expected={d} delta={d}\n", .{ name, i, actual, float(expected, i), delta });
                try std.Io.File.stderr().writeStreamingAll(init.io, line);
            }
            try check(std.math.isFinite(actual) and delta <= 0.00002);
        }
    }
    @memset(input[0..321], 0);
    output[0] = 12345;
    if (mel.computeBounded(input[0..200], &output, &work)) |_| return error.ShortInputAccepted else |err| try check(err == error.AudioTooShort);
    if (mel.computeBounded(&input, &output, &work)) |_| return error.LongInputAccepted else |err| try check(err == error.AudioTooLong);
    if (mel.computeBounded(input[0..321], output[0..255], &work)) |_| return error.ShortOutputAccepted else |err| try check(err == error.OutputTooSmall);
    try check(output[0] == 12345);
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |invalid| {
        input[320] = invalid;
        if (mel.computeBounded(input[0..321], &output, &work)) |_| return error.InvalidSampleAccepted else |err| try check(err == error.InvalidSample);
        try check(output[0] == 12345);
    }
    input[320] = 0;
    if (mel.computeBounded(input[0..321], input[0..256], &work)) |_| return error.AliasAccepted else |err| try check(err == error.AliasedBuffers);
    try check(@sizeOf(mel.Workspace) < 12000);
    var message: [192]u8 = undefined;
    const line = try std.fmt.bufPrint(&message, "PASS ASR mel: {d} assertions, maximum reference error={d}, workspace={d}\n", .{ assertions, maximum_error, @sizeOf(mel.Workspace) });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
