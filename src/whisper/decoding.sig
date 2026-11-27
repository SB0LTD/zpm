//! Deterministic Whisper token policy and timestamp assembly. This layer never
//! invents word timings: intervals come from emitted 20 ms timestamp tokens, or
//! are explicitly marked as a whole-window bound when the model omits them.
const std = @import("std");
const model = @import("model.sig");
const tokenizer = @import("tokenizer.sig");

pub const Error = tokenizer.Error || error{
    Shape, InvalidLogit, NoCandidate, TimestampOrder, TimestampOutOfRange, SegmentCapacity, InvalidUtf8,
};
pub const Options = struct {
    timestamps: bool = true,
    max_initial_timestamp_ms: u32 = 1000,
    max_timestamp_ms: u32 = 30000,
    suppress_blank: bool = true,
};
pub const Choice = struct { id: u32, log_probability: f32 };

/// Mutates only the borrowed logits. Generated excludes the transcription
/// prefix. Explicit suppression is caller-configurable and applied by ID.
pub fn choose(logits: []f32, special: tokenizer.Special, generated: []const u32,
    options: Options, suppressed: []const u32, space_token: ?u32) Error!Choice
{
    if (logits.len != special.n_vocab) return error.Shape;
    for (logits) |value| if (!std.math.isFinite(value)) return error.InvalidLogit;
    const neg = -std.math.inf(f32);
    // Lexical data and EOT are the only non-timestamp outputs. The otherwise
    // empty multilingual lexical token is suppressed by the caller's policy.
    @memset(logits[special.eot + 1 .. special.timestamp_begin], neg);
    if (generated.len == 0 and options.suppress_blank) {
        logits[special.eot] = neg;
        if (space_token) |id| { if (id >= special.eot) return error.InvalidToken; logits[id] = neg; }
    }
    for (suppressed) |id| {
        if (id >= special.n_vocab) return error.InvalidToken;
        logits[id] = neg;
    }
    if (!options.timestamps) {
        @memset(logits[special.timestamp_begin..], neg);
    } else {
        const last_allowed = @min(special.n_vocab, special.timestamp_begin + options.max_timestamp_ms / 20 + 1);
        @memset(logits[last_allowed..], neg);
        const last_ts = generated.len > 0 and generated[generated.len - 1] >= special.timestamp_begin;
        const previous_ts = generated.len < 2 or generated[generated.len - 2] >= special.timestamp_begin;
        if (last_ts) {
            if (previous_ts) @memset(logits[special.timestamp_begin..], neg)
            else @memset(logits[0..special.eot], neg);
        }
        var minimum: u32 = special.timestamp_begin;
        for (generated) |id| {
            if (id >= special.n_vocab) return error.InvalidToken;
            if (id >= special.timestamp_begin) minimum = @max(minimum, id);
        }
        @memset(logits[special.timestamp_begin..minimum], neg);
        if (generated.len == 0) {
            const maximum = @min(special.n_vocab, special.timestamp_begin + options.max_initial_timestamp_ms / 20 + 1);
            @memset(logits[maximum..], neg);
        }
        var max_timestamp: f32 = neg;
        var max_text: f32 = neg;
        for (logits[special.timestamp_begin..]) |value| max_timestamp = @max(max_timestamp, value);
        for (logits[0..special.timestamp_begin]) |value| max_text = @max(max_text, value);
        if (std.math.isFinite(max_timestamp)) {
            var sum: f32 = 0;
            for (logits[special.timestamp_begin..]) |value| sum += @exp(value - max_timestamp);
            if (max_timestamp + @log(sum) > max_text) @memset(logits[0..special.timestamp_begin], neg);
        }
    }
    var best: usize = 0;
    for (logits, 0..) |value, index| if (value > logits[best]) { best = index; };
    if (!std.math.isFinite(logits[best])) return error.NoCandidate;
    var denominator: f32 = 0;
    for (logits) |value| denominator += @exp(value - logits[best]);
    return .{ .id = @intCast(best), .log_probability = -@log(denominator) };
}

pub fn probability(logits: []const f32, id: u32) Error!f32 {
    if (id >= logits.len or logits.len == 0) return error.InvalidToken;
    var maximum: f32 = -std.math.inf(f32);
    for (logits) |value| {
        if (!std.math.isFinite(value)) return error.InvalidLogit;
        maximum = @max(maximum, value);
    }
    var denominator: f32 = 0;
    for (logits) |value| denominator += @exp(value - maximum);
    return @exp(logits[id] - maximum) / denominator;
}

pub const Timing = enum { timestamp_tokens, audio_window };
pub const Segment = struct {
    start_ms: u32, end_ms: u32, text: []const u8,
    first_token: usize, end_token: usize,
    timing: Timing,
};
pub const Assembly = struct {
    segments: []const Segment,
    text: []const u8,
    /// Last completed interval. A long recording may resume here and decode
    /// trailing uncommitted audio again rather than dropping the window tail.
    last_complete_ms: u32,
    trailing_text: bool,

    /// Return complete interval evidence covered by an advance in 16 kHz
    /// samples. A final partial millisecond has the same ceil bound used by
    /// assemble(), so a whole-window trailing utterance cannot be dropped.
    pub fn committed(self: Assembly, advance_samples: usize) []const Segment {
        const through_ms = advance_samples / 16 + @intFromBool(advance_samples % 16 != 0);
        var count: usize = 0;
        while (count < self.segments.len and self.segments[count].end_ms <= through_ms) count += 1;
        return self.segments[0..count];
    }
};

pub fn assemble(m: *const model.Model, ids: []const u32, duration_ms: u32,
    text: []u8, segments: []Segment) Error!Assembly
{
    const special = try tokenizer.special(m.hparams.n_vocab);
    // Validate every token and required byte capacity before writing.
    var bytes: usize = 0;
    var previous_time: u32 = 0;
    for (ids) |id| {
        if (try tokenizer.rawToken(m, id)) |raw| {
            if (raw.len > text.len - bytes) return error.OutputCapacity;
            bytes += raw.len;
        }
        if (special.timestampMs(id)) |time| {
            if (time > duration_ms) return error.TimestampOutOfRange;
            if (time < previous_time) return error.TimestampOrder;
            previous_time = time;
        }
    }
    var used: usize = 0;
    var n_segments: usize = 0;
    var start_byte: usize = 0;
    var start_token: usize = 0;
    var start_ms: u32 = 0;
    var timed_start = false;
    var last_complete_ms: u32 = 0;
    for (ids, 0..) |id, index| {
        if (try tokenizer.rawToken(m, id)) |raw| {
            @memcpy(text[used..][0..raw.len], raw);
            used += raw.len;
        }
        if (special.timestampMs(id)) |raw_ms| {
            const ms = raw_ms;
            if (used > start_byte) {
                if (n_segments == segments.len) return error.SegmentCapacity;
                if (!std.unicode.utf8ValidateSlice(text[start_byte..used])) return error.InvalidUtf8;
                segments[n_segments] = .{ .start_ms = start_ms, .end_ms = ms,
                    .text = text[start_byte..used], .first_token = start_token, .end_token = index,
                    .timing = if (timed_start) .timestamp_tokens else .audio_window };
                n_segments += 1;
                last_complete_ms = ms;
            }
            start_byte = used;
            start_token = index + 1;
            start_ms = ms;
            timed_start = true;
        }
    }
    const trailing_text = used > start_byte;
    if (trailing_text) {
        if (n_segments == segments.len) return error.SegmentCapacity;
        if (!std.unicode.utf8ValidateSlice(text[start_byte..used])) return error.InvalidUtf8;
        segments[n_segments] = .{ .start_ms = start_ms, .end_ms = duration_ms,
            .text = text[start_byte..used], .first_token = start_token, .end_token = ids.len,
            .timing = .audio_window };
        n_segments += 1;
    }
    return .{ .segments = segments[0..n_segments], .text = text[0..used],
        .last_complete_ms = last_complete_ms, .trailing_text = trailing_text };
}

test "Whisper timestamp constraints preserve pairs and monotonicity" {
    const testing = std.testing;
    const special = try tokenizer.special(51866);
    var logits: [51866]f32 = @splat(-100);
    logits[10] = 2;
    logits[special.timestamp_begin + 100] = 20; // forbidden initial >1 second
    logits[special.timestamp_begin] = 4;
    try testing.expectEqual(special.timestamp_begin, (try choose(&logits, special, &.{}, .{}, &.{}, null)).id);
    logits = @splat(-100);
    logits[10] = 4; logits[special.timestamp_begin] = 20;
    try testing.expectEqual(@as(u32, 10), (try choose(&logits, special, &.{special.timestamp_begin}, .{}, &.{}, null)).id);
    logits = @splat(-100);
    logits[10] = 30; logits[special.timestamp_begin + 20] = 4;
    try testing.expectEqual(special.timestamp_begin + 20, (try choose(&logits, special, &.{ special.timestamp_begin, 10, special.timestamp_begin + 10 }, .{}, &.{}, null)).id);
}

test "Whisper assembly preserves lexical bytes and reports actual interval evidence" {
    const testing = std.testing;
    const vocab = [_]model.Token{ .{ .bytes = "hi" }, .{ .bytes = " there" } };
    var m: model.Model = .{ .hparams = undefined, .filters = undefined, .tensors = &.{}, .vocabulary = &vocab };
    m.hparams.n_vocab = 51866;
    var bytes: [64]u8 = undefined;
    var segments: [4]Segment = undefined;
    const result = try assemble(&m, &.{ 50365, 0, 50375, 50380, 1, 50257 }, 1000, &bytes, &segments);
    try testing.expectEqual(@as(usize, 2), result.segments.len);
    try testing.expectEqualStrings("hi there", result.text);
    try testing.expectEqual(@as(u32, 200), result.segments[0].end_ms);
    try testing.expectEqual(Timing.timestamp_tokens, result.segments[0].timing);
    try testing.expectEqual(@as(u32, 300), result.segments[1].start_ms);
    try testing.expectEqual(Timing.audio_window, result.segments[1].timing);
    try testing.expect(result.trailing_text);
    try testing.expectError(error.TimestampOrder, assemble(&m, &.{ 50380, 0, 50370 }, 1000, &bytes, &segments));
    const final = try assemble(&m, &.{ 50365, 0, 50257 }, 1001, &bytes, &segments);
    try testing.expectEqual(@as(usize, 1), final.committed(16001).len);
    try testing.expectEqualStrings("hi", final.committed(16001)[0].text);
    try testing.expectEqual(@as(usize, 0), final.committed(16000).len);
}
