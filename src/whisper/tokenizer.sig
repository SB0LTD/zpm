//! Whisper lexical detokenization and architecture-defined control tokens.
//!
//! The GGML vocabulary already contains raw bytes, not GPT-2's display Unicode
//! alphabet. Individual tokens may split UTF-8 codepoints; concatenate them
//! before interpreting text. No normalization, removal of Hebrew marks, or
//! replacement of invalid bytes is performed here.
const std = @import("std");
const model_module = @import("model.sig");

pub const Error = error{
    UnsupportedVocabulary,
    InvalidToken,
    MissingLexicalToken,
    OutputCapacity,
    UnknownLanguage,
    PromptCapacity,
};

pub const Special = struct {
    n_vocab: u32,
    multilingual: bool,
    language_count: u32,
    eot: u32,
    sot: u32,
    translate: u32,
    transcribe: u32,
    speaker_turn: u32,
    previous: u32,
    no_speech: u32,
    no_timestamps: u32,
    timestamp_begin: u32,

    pub fn timestampMs(self: Special, id: u32) ?u32 {
        if (id < self.timestamp_begin or id >= self.n_vocab) return null;
        return (id - self.timestamp_begin) * 20;
    }

    pub fn language(self: Special, code: []const u8) Error!u32 {
        if (!self.multilingual) return error.UnknownLanguage;
        for (LANGUAGES[0..self.language_count], 0..) |candidate, index|
            if (std.mem.eql(u8, candidate, code)) return self.sot + 1 + @as(u32, @intCast(index));
        return error.UnknownLanguage;
    }
};

/// Whisper's English, 99-language and 100-language vocabularies. The language
/// extension shifts task and timestamp IDs; large-v3 must not use v2 constants.
pub fn special(n_vocab: u32) Error!Special {
    if (n_vocab < 51864 or n_vocab > 51866) return error.UnsupportedVocabulary;
    const multilingual = n_vocab >= 51865;
    const languages: u32 = if (multilingual) n_vocab - 51766 else 0;
    const offset: u32 = if (multilingual) languages - 98 else 0;
    return .{
        .n_vocab = n_vocab,
        .multilingual = multilingual,
        .language_count = languages,
        .eot = if (multilingual) 50257 else 50256,
        .sot = if (multilingual) 50258 else 50257,
        .translate = 50357 + offset,
        .transcribe = 50358 + offset,
        .speaker_turn = 50359 + offset,
        .previous = 50360 + offset,
        .no_speech = 50361 + offset,
        .no_timestamps = 50362 + offset,
        .timestamp_begin = 50363 + offset,
    };
}

/// Return lexical bytes, or null for controls and timestamp tokens.
pub fn rawToken(model: *const model_module.Model, id: u32) Error!?[]const u8 {
    const tokens = try special(model.hparams.n_vocab);
    if (id >= tokens.n_vocab) return error.InvalidToken;
    if (id >= tokens.eot) return null;
    if (id >= model.vocabulary.len) return error.MissingLexicalToken;
    return model.vocabulary[id].bytes;
}

/// Atomically detokenize lexical content. Errors leave output unchanged.
/// Controls and timestamps are reported through Special, never emitted as text.
pub fn decode(model: *const model_module.Model, ids: []const u32, output: []u8) Error!usize {
    var required: usize = 0;
    for (ids) |id| {
        if (try rawToken(model, id)) |bytes| {
            if (bytes.len > output.len - required) return error.OutputCapacity;
            required += bytes.len;
        }
    }
    var position: usize = 0;
    for (ids) |id| {
        if (try rawToken(model, id)) |bytes| {
            @memcpy(output[position..][0..bytes.len], bytes);
            position += bytes.len;
        }
    }
    return required;
}

/// Construct the standard transcription prefix into caller-owned token IDs.
pub fn transcriptionPrompt(n_vocab: u32, language_code: []const u8, timestamps: bool, output: []u32) Error!usize {
    const tokens = try special(n_vocab);
    const count: usize = (if (tokens.multilingual) @as(usize, 3) else 1) +
        (if (timestamps) @as(usize, 0) else 1);
    if (output.len < count) return error.PromptCapacity;
    const language_token: ?u32 = if (tokens.multilingual) try tokens.language(language_code) else null;
    if (!tokens.multilingual and !std.mem.eql(u8, language_code, "en")) return error.UnknownLanguage;
    output[0] = tokens.sot;
    var position: usize = 1;
    if (language_token) |id| {
        output[position] = id;
        output[position + 1] = tokens.transcribe;
        position += 2;
    }
    if (!timestamps) {
        output[position] = tokens.no_timestamps;
        position += 1;
    }
    return position;
}

pub const LANGUAGES = [_][]const u8{
    "en", "zh", "de", "es",  "ru", "ko", "fr", "ja", "pt", "tr",
    "pl", "ca", "nl", "ar",  "sv", "it", "id", "hi", "fi", "vi",
    "he", "uk", "el", "ms",  "cs", "ro", "da", "hu", "ta", "no",
    "th", "ur", "hr", "bg",  "lt", "la", "mi", "ml", "cy", "sk",
    "te", "fa", "lv", "bn",  "sr", "az", "sl", "kn", "et", "mk",
    "br", "eu", "is", "hy",  "ne", "mn", "bs", "kk", "sq", "sw",
    "gl", "mr", "pa", "si",  "km", "sn", "yo", "so", "af", "oc",
    "ka", "be", "tg", "sd",  "gu", "am", "yi", "lo", "uz", "fo",
    "ht", "ps", "tk", "nn",  "mt", "sa", "lb", "my", "bo", "tl",
    "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
};

test "Whisper v3 Hebrew task and timestamp IDs match the serialized vocabulary" {
    const testing = std.testing;
    const v3 = try special(51866);
    try testing.expectEqual(@as(u32, 50257), v3.eot);
    try testing.expectEqual(@as(u32, 50279), try v3.language("he"));
    try testing.expectEqual(@as(u32, 50360), v3.transcribe);
    try testing.expectEqual(@as(u32, 50364), v3.no_timestamps);
    try testing.expectEqual(@as(u32, 50365), v3.timestamp_begin);
    try testing.expectEqual(@as(u32, 30000), v3.timestampMs(51865).?);
    try testing.expectEqual(@as(?u32, null), v3.timestampMs(51866));
    try testing.expectEqual(@as(?u32, null), v3.timestampMs(v3.no_timestamps));
    const v2 = try special(51865);
    try testing.expectEqual(@as(u32, 50359), v2.transcribe);
    try testing.expectEqual(@as(u32, 50364), v2.timestamp_begin);
    try testing.expectError(error.UnknownLanguage, v2.language("yue"));
    try testing.expectError(error.UnsupportedVocabulary, special(51867));
}

test "Whisper transcription prompt validates before writing" {
    const testing = std.testing;
    var ids: [4]u32 = @splat(123);
    try testing.expectEqual(@as(usize, 4), try transcriptionPrompt(51866, "he", false, &ids));
    try testing.expectEqualSlices(u32, &.{ 50258, 50279, 50360, 50364 }, &ids);
    try testing.expectEqual(@as(usize, 3), try transcriptionPrompt(51866, "he", true, &ids));
    ids = @splat(123);
    try testing.expectError(error.UnknownLanguage, transcriptionPrompt(51866, "zz", true, &ids));
    try testing.expectEqual(@as(u32, 123), ids[0]);
    try testing.expectError(error.PromptCapacity, transcriptionPrompt(51866, "he", false, ids[0..3]));
    try testing.expectEqual(@as(usize, 2), try transcriptionPrompt(51864, "en", false, &ids));
    try testing.expectEqualSlices(u32, &.{ 50257, 50362 }, ids[0..2]);
    try testing.expectError(error.UnknownLanguage, transcriptionPrompt(51864, "he", true, &ids));
}

test "Whisper decoding preserves raw Hebrew byte fragments and omits controls" {
    const testing = std.testing;
    const vocabulary = [_]model_module.Token{
        .{ .bytes = "\xd7" }, .{ .bytes = "\xa9\xd7" }, .{ .bytes = "\x9c\xd7\x95\xd7\x9d" }, .{ .bytes = " " },
    };
    var model: model_module.Model = .{ .hparams = undefined, .filters = undefined, .tensors = &.{}, .vocabulary = &vocabulary };
    model.hparams.n_vocab = 51866;
    var output: [32]u8 = @splat(0xaa);
    const length = try decode(&model, &.{ 50258, 50279, 50360, 50365, 0, 1, 2, 50370, 50257 }, &output);
    try testing.expectEqualStrings("\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d", output[0..length]);
    try testing.expectEqual(@as(u8, 0xaa), output[length]);
    output = @splat(0xaa);
    try testing.expectError(error.OutputCapacity, decode(&model, &.{ 0, 1, 2 }, output[0..2]));
    try testing.expectEqual(@as(u8, 0xaa), output[0]);
    try testing.expectError(error.InvalidToken, decode(&model, &.{ 0, 51866 }, &output));
    try testing.expectEqual(@as(u8, 0xaa), output[0]);
    try testing.expectError(error.MissingLexicalToken, decode(&model, &.{100}, &output));
}
