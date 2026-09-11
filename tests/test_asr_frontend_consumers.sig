//! Ensure prototype consumers use caller storage and reject before inference.
const std = @import("std");
const asr = @import("asr");
var audio: [320]f32 = @splat(0);
var features: [256]f32 = @splat(12345);
var scratch: asr.mel.Workspace = .{};
pub fn main(init: std.process.Init) !void {
    var model = asr.Model.empty(.v0_6b);
    var result: [64]u8 = @splat(77);
    if (model.transcribe(&audio, audio.len, &result, result.len, &features, &scratch) != 0)
        return error.UnloadedModelRan;
    for (result) |byte| if (byte != 77) return error.UnloadedModelWroteOutput;
    var stream = asr.StreamState.init(&audio, audio.len, .{});
    var cache: asr.decoder.KVCache = undefined;
    const encoded: asr.encoder.EncoderWeights = undefined;
    const decoded: asr.decoder.DecoderWeights = undefined;
    const tokens = stream.processChunk(&encoded, &asr.encoder.CONFIG_0_6B, &decoded, &asr.decoder.DECODER_0_6B, &cache, &features, &scratch);
    if (tokens.len != 0 or stream.chunk_num != 0) return error.EmptyInputChangedState;
    stream.audio_len = audio.len;
    if (stream.processChunk(&encoded, &asr.encoder.CONFIG_0_6B, &decoded, &asr.decoder.DECODER_0_6B, &cache, features[0..255], &scratch).len != 0 or stream.chunk_num != 0)
        return error.InsufficientFeaturesChangedState;
    for (features) |value| if (value != 12345) return error.RejectedInputWroteFeatures;
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS ASR frontend consumers: unloaded model, empty input and insufficient caller storage rejected before inference\n");
}
